import SwiftUI
import UIKit
import CryptoKit
import ImageIO
import CoreImage.CIFilterBuiltins

@main struct NightAnimeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AnimeStore()
    @StateObject private var downloads = DownloadCenter.shared
    init() {
        let tab = UITabBarAppearance(); tab.configureWithOpaqueBackground(); tab.backgroundColor = UIColor(red: 0.03, green: 0.05, blue: 0.09, alpha: 0.96)
        UITabBar.appearance().standardAppearance = tab; UITabBar.appearance().scrollEdgeAppearance = tab
    }
    var body: some Scene { WindowGroup {
        if let qa = qaPlayback { NativePlayerView(playback: qa).ignoresSafeArea() }
        else if ProcessInfo.processInfo.arguments.contains("--subtitle-test"), let video = Bundle.main.url(forResource: "probe", withExtension: "mp4"), let subs = Bundle.main.url(forResource: "subtitles", withExtension: "ass") {
            NativePlayerView(playback: Playback(options: [VideoOption(id: "test", url: video, height: 720)], subtitles: subs, title: "Проверка ASS-субтитров", key: "subtitle-test")).ignoresSafeArea()
        } else { RootView().environmentObject(store).environmentObject(downloads).preferredColorScheme(.dark).tint(Night.accent) }
    } }
    // Отладочный запуск плеера с локальным файлом: --player-file=/path.mp4 [--player-subs=/path.ass].
    var qaPlayback: Playback? {
        #if DEBUG
        guard let file = QA.value("--player-file") else { return nil }
        return Playback(options: [VideoOption(id: "qa", url: URL(fileURLWithPath: file), height: 1080)], subtitles: QA.value("--player-subs").map { URL(fileURLWithPath: $0) }, title: "Проверка плеера · ONA 1 серия", key: "qa-player", hasNext: true)
        #else
        return nil
        #endif
    }
}

#if DEBUG
// Параметры запуска для проверки экранов в симуляторе; в Release их нет.
enum QA {
    static func has(_ name: String) -> Bool { ProcessInfo.processInfo.arguments.contains(name) }
    static func value(_ name: String) -> String? { ProcessInfo.processInfo.arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) } }
}
#endif

// Палитра и элементы оформления Night TV — те же цвета, что в Android-версии.
enum Night {
    static func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color { Color(red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255).opacity(alpha) }
    static let bg = rgb(0x0a101c)
    static let panel = rgb(0x202c3e, 0.63)
    static let card = rgb(0x172335, 0.31)
    static let accent = rgb(0xedf4ff)
    static let muted = rgb(0xa9a9bd)
    static let meta = rgb(0xaaaabd)
    static let stroke = Color.white.opacity(0.13)
    // Роли из replica/design/tokens.json.
    static let text = rgb(0xf2f5fb)
    static let surface = rgb(0x172335)
    static let raised = rgb(0x202c3e, 0.85)
    static let onAccent = rgb(0x0f1a2a)
    static let fresh = rgb(0xffcc80)
    static let scoreHigh = rgb(0x6fdc8c)
    static let scoreMid = rgb(0xc9d1e0)
    static let scoreLow = rgb(0xff8a80)
    static let progress = rgb(0x7fb2ff)
    static let danger = rgb(0xff8a80)
}
struct NightBackground: View {
    var body: some View {
        // Ровный ночной фон без фотографии: глубокий синий с лёгким переходом сверху вниз.
        LinearGradient(colors: [Night.rgb(0x0e1626), Night.rgb(0x0a101c), Night.rgb(0x070b14)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
    }
}
struct NightButtonStyle: ButtonStyle {
    var selected = false
    var wide = false
    func makeBody(configuration: Configuration) -> some View {
        let lit = selected || configuration.isPressed
        configuration.label.font(.system(size: 15, weight: .medium)).lineLimit(wide ? 2 : 1).multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, wide ? 8 : 0).frame(minHeight: wide ? 56 : 46).frame(maxWidth: wide ? .infinity : nil)
            .foregroundStyle(lit ? Night.rgb(0x111d2d) : Night.rgb(0xeeeeff))
            .background(lit ? Night.rgb(0xedf3fa) : Night.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Night.stroke, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1).animation(.easeOut(duration: 0.13), value: configuration.isPressed)
    }
}
// Постеры уменьшаются до размера карточки и держатся в памяти, чтобы каталог открывался мгновенно. Скачанные файлы
// лежат и на диске: при следующем запуске их не нужно качать заново. Свежим файл считается 30 дней, без сети
// годится и старый. Папка — не больше 40 МБ: раз за запуск удаляем самые старые файлы.
enum PosterCache {
    static let images: NSCache<NSString, UIImage> = { let c = NSCache<NSString, UIImage>(); c.totalCostLimit = 24 * 1024 * 1024; return c }()
    static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("posters", isDirectory: true)
    // Своя сессия без URLCache: файл и так сохраняется в папку постеров, вторая копия в кэше системы не нужна.
    static let session: URLSession = { let c = URLSessionConfiguration.default; c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData; return URLSession(configuration: c) }()
    static func cost(_ image: UIImage) -> Int { Int(image.size.width * image.size.height * image.scale * image.scale * 4) }
    static func image(_ url: String) async -> UIImage? {
        if let image = images.object(forKey: url as NSString) { return image }
        return await PosterLoads.shared.image(url)
    }
    static func load(_ url: String) async -> UIImage? {
        guard let u = URL(string: url) else { return nil }
        if u.isFileURL { return (try? Data(contentsOf: u)).flatMap(thumbnail) }
        let file = folder.appendingPathComponent(Insecure.SHA1.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined())
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, -modified.timeIntervalSinceNow < 30 * 86400, let image = decode(file) { return image }
        guard let (data, _) = try? await session.data(from: u), let image = thumbnail(data) else { return modified == nil ? nil : decode(file) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return image
    }
    // Битый файл удаляется, чтобы постер скачался заново.
    static func decode(_ file: URL) -> UIImage? {
        if let image = (try? Data(contentsOf: file)).flatMap(thumbnail) { return image }
        try? FileManager.default.removeItem(at: file); return nil
    }
    // ImageIO сразу декодирует картинку высотой не больше 430 пикселей, не разворачивая в памяти весь постер.
    static func thumbnail(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var w = p[kCGImagePropertyPixelWidth] as? Double, var h = p[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0 else { return nil }
        if (p[kCGImagePropertyOrientation] as? UInt32 ?? 1) >= 5 { swap(&w, &h) }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
                       kCGImageSourceThumbnailMaxPixelSize: (max(w, h) * min(1, 430 / h)).rounded(.up)] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let image = UIImage(cgImage: cg)
        return image.preparingForDisplay() ?? image
    }
    static func trim() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { return }
        var total = 0
        for (file, date, size) in files.map({ f in let v = try? f.resourceValues(forKeys: keys); return (f, v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0) }).sorted(by: { $0.1 > $1.1 }) {
            total += size
            if -date.timeIntervalSinceNow > 90 * 86400 || total > 40 << 20 { try? FileManager.default.removeItem(at: file) }
        }
    }

    // Размытый фон баннера и шапки аниме: постер заполняет рамку и размывается один раз в четверть размера точек —
    // после размытия мелких деталей всё равно нет. Края прозрачные, как у .blur; fade — маска баннера, прозрачная
    // сверху и снизу, всё лишнее обрезано рамкой. Без fade сияние выходит за рамку на 3σ, как у .blur без обрезки.
    static let blurContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    static func backdrop(_ url: String, key: String, size: CGSize, radius: CGFloat, fade: Bool) async -> UIImage? {
        if let image = images.object(forKey: key as NSString) { return image }
        guard let poster = await image(url), let cg = poster.cgImage else { return nil }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let bleed = fade ? 0 : 3 * radius, k = 0.25
            let canvas = CGRect(x: 0, y: 0, width: ((size.width + 2 * bleed) * k).rounded(.up), height: ((size.height + 2 * bleed) * k).rounded(.up))
            let sx = canvas.width / (size.width + 2 * bleed), sy = canvas.height / (size.height + 2 * bleed)
            let frame = CGRect(x: bleed * sx, y: bleed * sy, width: size.width * sx, height: size.height * sy)
            var img = CIImage(cgImage: cg)
            let scale = max(frame.width / img.extent.width, frame.height / img.extent.height)
            img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            img = img.transformed(by: CGAffineTransform(translationX: frame.midX - img.extent.midX, y: frame.midY - img.extent.midY)).cropped(to: frame)
            img = img.applyingGaussianBlur(sigma: radius * (sx + sy) / 2).cropped(to: canvas)
            if fade {
                let top = CIFilter.linearGradient(), bottom = CIFilter.linearGradient()
                top.point0 = CGPoint(x: 0, y: frame.maxY); top.point1 = CGPoint(x: 0, y: frame.maxY - frame.height / 3); top.color0 = .clear; top.color1 = .white
                bottom.point0 = CGPoint(x: 0, y: frame.minY); bottom.point1 = CGPoint(x: 0, y: frame.minY + frame.height / 3); bottom.color0 = .clear; bottom.color1 = .white
                if let a = top.outputImage, let b = bottom.outputImage {
                    img = img.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: a.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: b])])
                }
            }
            return blurContext.createCGImage(img, from: canvas, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)).map { UIImage(cgImage: $0) }
        }.value
        if let image { images.setObject(image, forKey: key as NSString, cost: cost(image)) }
        return image
    }
}
// Одновременные запросы одного постера — карточка и фон баннера — ждут одну загрузку.
actor PosterLoads {
    static let shared = PosterLoads()
    private var running: [String: Task<UIImage?, Never>] = [:]
    private var trimmed = false
    func image(_ url: String) async -> UIImage? {
        if let task = running[url] { return await task.value }
        if !trimmed { trimmed = true; Task.detached(priority: .background) { PosterCache.trim() } }
        let task = Task.detached(priority: .userInitiated) { await PosterCache.load(url) }
        running[url] = task
        let image = await task.value
        running[url] = nil
        if let image { PosterCache.images.setObject(image, forKey: url as NSString, cost: PosterCache.cost(image)) }
        return image
    }
}
struct CachedPoster: View {
    let url: String
    var fill = false
    // Картинка хранится вместе со своим адресом: если вид останется тем же, а аниме сменится, старый постер не задержится.
    @State private var loaded: (url: String, image: UIImage)?
    init(url: String, fill: Bool = false) { self.url = url; self.fill = fill; _loaded = State(initialValue: PosterCache.images.object(forKey: url as NSString).map { (url, $0) }) }
    var body: some View {
        let image = loaded?.url == url ? loaded?.image : PosterCache.images.object(forKey: url as NSString)
        Group { if let image { if fill { Color.clear.overlay(Image(uiImage: image).resizable().scaledToFill()).clipped() } else { Image(uiImage: image).resizable().scaledToFit() } } else { Color.clear } }
        .task(id: url) { if loaded?.url != url, let image = await PosterCache.image(url) { loaded = (url, image) } }
    }
}
// Живой .blur видеокарта пересчитывала бы в каждом кадре прокрутки, а готовая маленькая картинка просто растягивается.
struct BlurredBackdrop: View {
    let url: String
    let radius: CGFloat
    var fade = false
    // Пока фон пересчитывается под новый размер (поворот iPad), растягивается прежний фон того же аниме.
    @State private var loaded: (url: String, key: String, image: UIImage)?
    var body: some View {
        GeometryReader { geo in
            let size = geo.size, key = "blur|\(url)|\(Int(size.width))x\(Int(size.height))|\(radius)|\(fade)"
            let image = loaded?.key == key ? loaded?.image : PosterCache.images.object(forKey: key as NSString) ?? (loaded?.url == url ? loaded?.image : nil)
            Group { if let image { Image(uiImage: image).resizable() } else { Color.clear } }
                .padding(fade ? 0 : -3 * radius)
                .task(id: key) { if loaded?.key != key, size.width >= 1, size.height >= 1, let image = await PosterCache.backdrop(url, key: key, size: size, radius: radius, fade: fade) { loaded = (url, key, image) } }
        }.allowsHitTesting(false)
    }
}

struct LoginView: View {
    @EnvironmentObject var store: AnimeStore
    @Environment(\.dismiss) var dismiss
    @State var email = ""; @State var password = ""; @State var busy = false; @State var error = ""
    func field<F: View>(_ f: F) -> some View { f.font(.system(size: 17)).foregroundStyle(.white).padding(.horizontal, 16).frame(height: 52).background(Night.panel, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Night.stroke)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(store.token.isEmpty ? "Вход в Anime 365" : "Аккаунт Anime 365").font(.system(size: 22, weight: .bold)).foregroundStyle(.white); Spacer(); Button("Закрыть") { dismiss() }.buttonStyle(NightButtonStyle()) }
            if !store.token.isEmpty {
                ScrollView { AccountPanel(); UpdatePanel().padding(.top, 12) }
                Button("Выйти") { store.logout(); dismiss() }.buttonStyle(NightButtonStyle())
            } else {
                field(TextField("", text: $email, prompt: Text("E-mail").foregroundStyle(Night.rgb(0x9c9eaf))).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled())
                field(SecureField("", text: $password, prompt: Text("Пароль").foregroundStyle(Night.rgb(0x9c9eaf))))
                Text(error.isEmpty ? "Пароль отправляется только Anime 365. Токен хранится в Связке ключей iPhone, пароль не сохраняется." : error).font(.system(size: 13)).foregroundStyle(error.isEmpty ? Night.meta : .orange)
                Button(busy ? "Вход…" : "Войти") { Task { busy = true; error = ""; do { try await store.login(email.trimmingCharacters(in: .whitespaces), password, "universal"); password = ""; dismiss() } catch { self.error = error.localizedDescription }; busy = false } }
                    .buttonStyle(NightButtonStyle(selected: true)).disabled(busy || email.isEmpty || password.isEmpty)
            }
            Spacer()
            Text("Yoru Anime \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.system(size: 12)).foregroundStyle(Night.meta).frame(maxWidth: .infinity)
        }.padding(20).background(NightBackground()).presentationDetents([.medium, .large])
    }
}
