import AVFoundation
import AVKit
import CoreMedia
import MobileVLCKit
import UIKit

// «Картинка в картинке», как в YouTube: свернули приложение — серия продолжается в маленьком окне.
// В MobileVLCKit 3 нет своего PiP, поэтому кадры VLC (уже с наложенными субтитрами) забираются через
// libvlc vmem в CVPixelBuffer и показываются в AVSampleBufferDisplayLayer — этот же слой и в плеере,
// и в системном окне PiP. Если libvlc-функции недоступны, плеер рисует как раньше (vlc.drawable).
private typealias FormatCB = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> UInt32
private typealias CleanupCB = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias LockCB = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer?
private typealias UnlockCB = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafePointer<UnsafeMutableRawPointer?>?) -> Void
private typealias DisplayCB = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
private typealias SetFormat = @convention(c) (OpaquePointer, FormatCB?, CleanupCB?) -> Void
private typealias SetCallbacks = @convention(c) (OpaquePointer, LockCB?, UnlockCB?, DisplayCB?, UnsafeMutableRawPointer?) -> Void
private typealias PlayerGetter = @convention(c) (AnyObject, Selector) -> OpaquePointer?

private final class Frame { var buffer: CVPixelBuffer?; var locked = false, shown = false, busy = false }

final class PiPVideo: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    let layer = AVSampleBufferDisplayLayer()
    private(set) var pip: AVPictureInPictureController?
    private(set) var active = false
    private var restored = false
    private let timebase: CMTimebase?
    // Состояние кадров меняется в потоке вывода VLC.
    private let mutex = NSLock()
    private var pool: CVPixelBufferPool?, frames: [Frame] = [], scratch: UnsafeMutableRawPointer?, scratchPlane = 0, height709 = false

    var isPaused: () -> Bool = { true }
    var setPlaying: (Bool) -> Void = { _ in }
    var skip: (Double) -> Void = { _ in }
    var duration: () -> Double = { 0 }
    var stopped: (_ restored: Bool) -> Void = { _ in }
    var started: () -> Void = {}

    init?(player: VLCMediaPlayer) {
        let sel = NSSelectorFromString("libVLCMediaPlayer")
        let any = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard player.responds(to: sel), let imp = player.method(for: sel),
              let mp = unsafeBitCast(imp, to: PlayerGetter.self)(player, sel),
              let f = dlsym(any, "libvlc_video_set_format_callbacks"), let c = dlsym(any, "libvlc_video_set_callbacks") else { return nil }
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        timebase = tb
        super.init()
        layer.videoGravity = .resizeAspect; layer.backgroundColor = UIColor.black.cgColor
        if let tb { CMTimebaseSetTime(tb, time: .zero); CMTimebaseSetRate(tb, rate: 0); layer.controlTimebase = tb }
        let me = Unmanaged.passUnretained(self).toOpaque()
        unsafeBitCast(f, to: SetFormat.self)(mp, pipFormat, pipCleanup)
        unsafeBitCast(c, to: SetCallbacks.self)(mp, pipLock, pipUnlock, pipDisplay, me)
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self))
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            controller.requiresLinearPlayback = false
            controller.delegate = self
            pip = controller
        }
    }
    deinit { free(scratch) }

    // MARK: Кадры VLC (поток вывода)
    fileprivate func configure(width: Int, height: Int) -> (UInt32, UInt32)? {
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                                    kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        var newPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary, attrs as CFDictionary, &newPool) == kCVReturnSuccess, let newPool else { return nil }
        var probe: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, newPool, &probe) == kCVReturnSuccess, let probe, CVPixelBufferGetPlaneCount(probe) == 2 else { return nil }
        let p0 = CVPixelBufferGetBytesPerRowOfPlane(probe, 0), p1 = CVPixelBufferGetBytesPerRowOfPlane(probe, 1)
        mutex.lock(); defer { mutex.unlock() }
        pool = newPool; dropIdleBuffers(); height709 = height >= 600
        free(scratch); scratchPlane = p0 * height; scratch = malloc(scratchPlane + p1 * (height / 2 + 1))
        return (UInt32(p0), UInt32(p1))
    }
    // Кадры не освобождаются: VLC может держать их id до закрытия вывода; отпускаются только буферы.
    fileprivate func reset() { mutex.lock(); pool = nil; dropIdleBuffers(); mutex.unlock() }
    private func dropIdleBuffers() { for f in frames where !f.busy { f.buffer = nil } }
    fileprivate func lockFrame(_ planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer? {
        mutex.lock(); defer { mutex.unlock() }
        let frame = frames.first { !$0.busy } ?? { let f = Frame(); frames.append(f); return f }()
        frame.busy = true; frame.locked = true; frame.shown = false; frame.buffer = nil
        var buffer: CVPixelBuffer?
        if let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess, let buffer,
           CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess,
           let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            frame.buffer = buffer; planes[0] = y; planes[1] = uv
        } else if let scratch {
            // Пул не отдал буфер — VLC пишет во временную память, кадр просто не показываем.
            planes[0] = scratch; planes[1] = scratch + scratchPlane
        } else { return nil }
        return Unmanaged.passUnretained(frame).toOpaque()
    }
    fileprivate func unlockFrame(_ id: UnsafeMutableRawPointer) {
        let frame = Unmanaged<Frame>.fromOpaque(id).takeUnretainedValue()
        mutex.lock()
        if let b = frame.buffer, frame.locked { CVPixelBufferUnlockBaseAddress(b, []) }
        frame.locked = false; frame.busy = false
        let ready = frame.shown ? frame.buffer : nil
        mutex.unlock()
        if let ready { show(ready) }
    }
    fileprivate func displayFrame(_ id: UnsafeMutableRawPointer) {
        let frame = Unmanaged<Frame>.fromOpaque(id).takeUnretainedValue()
        mutex.lock()
        // libvlc 3: lock → display → unlock, кадр уходит на экран при unlock. На случай обратного порядка — показываем сразу.
        let ready = frame.locked ? nil : frame.buffer
        if frame.locked { frame.shown = true }
        mutex.unlock()
        if let ready { show(ready) }
    }
    private func show(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, height709 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr, let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: timebase.map { CMTimebaseGetTime($0) } ?? .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let list = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(list) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(list, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        DispatchQueue.main.async { [weak self] in
            guard let renderer = self?.layer.sampleBufferRenderer else { return }
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sample)
        }
    }

    // MARK: Управление из плеера (главный поток)
    func sync(timeMs: Int32, playing: Bool, rate: Float) {
        guard let timebase else { return }
        CMTimebaseSetTime(timebase, time: CMTime(value: CMTimeValue(max(0, timeMs)), timescale: 1000))
        CMTimebaseSetRate(timebase, rate: playing ? Float64(rate) : 0)
    }
    func invalidate() { pip?.invalidatePlaybackState() }
    func stop() { if active { pip?.stopPictureInPicture() } }
    func clear() { layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil) }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) { onMain { self.setPlaying(playing); self.invalidate() } }
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        let d = duration()
        return d > 0 ? CMTimeRange(start: .zero, duration: CMTime(seconds: d, preferredTimescale: 1000)) : CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { isPaused() }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        onMain { self.skip(skipInterval.seconds); completionHandler() }
    }

    // MARK: AVPictureInPictureControllerDelegate
    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) { active = true; restored = false; started() }
    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { active = false }
    func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { restored = true; completionHandler(true) }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { active = false; stopped(restored || UIApplication.shared.applicationState == .active) }
    private func onMain(_ f: @escaping () -> Void) { if Thread.isMainThread { f() } else { DispatchQueue.main.async(execute: f) } }
}

// Колбэки libvlc — обычные C-функции без захвата контекста; объект приходит через opaque.
private let pipFormat: FormatCB = { opaque, chroma, width, height, pitches, lines in
    guard let opaque, let ctx = opaque.pointee, let chroma, let width, let height, let pitches, let lines else { return 0 }
    let ref = Unmanaged<PiPVideo>.fromOpaque(ctx)
    let w = (width.pointee + 1) & ~1, h = (height.pointee + 1) & ~1
    guard w > 0, h > 0, w <= 8192, h <= 8192, let (p0, p1) = ref.takeUnretainedValue().configure(width: Int(w), height: Int(h)) else { return 0 }
    _ = ref.retain() // отпускается в pipCleanup, когда VLC закроет вывод
    for (i, c) in "NV12".utf8.enumerated() { chroma[i] = CChar(bitPattern: c) }
    width.pointee = w; height.pointee = h
    pitches[0] = p0; pitches[1] = p1; lines[0] = h; lines[1] = h / 2
    return 3
}
private let pipCleanup: CleanupCB = { ctx in
    guard let ctx else { return }
    let ref = Unmanaged<PiPVideo>.fromOpaque(ctx)
    ref.takeUnretainedValue().reset(); ref.release()
}
private let pipLock: LockCB = { ctx, planes in
    guard let ctx, let planes else { return nil }
    return Unmanaged<PiPVideo>.fromOpaque(ctx).takeUnretainedValue().lockFrame(planes)
}
private let pipUnlock: UnlockCB = { ctx, picture, _ in
    guard let ctx, let picture else { return }
    Unmanaged<PiPVideo>.fromOpaque(ctx).takeUnretainedValue().unlockFrame(picture)
}
private let pipDisplay: DisplayCB = { ctx, picture in
    guard let ctx, let picture else { return }
    Unmanaged<PiPVideo>.fromOpaque(ctx).takeUnretainedValue().displayFrame(picture)
}
