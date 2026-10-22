import SwiftUI
import UIKit
import MobileVLCKit

struct NativePlayerView: UIViewControllerRepresentable {
    let playback: Playback
    var onFinish: ((_ done: Bool, _ next: Bool) -> Void)? = nil
    @Environment(\.dismiss) var dismiss
    func makeUIViewController(context: Context) -> PlayerController { let c = PlayerController(playback); c.onClose = { done, next in onFinish?(done, next); dismiss() }; return c }
    func updateUIViewController(_ c: PlayerController, context: Context) {}
}

// Плеер в духе стриминговых сервисов: видео на весь экран, затемнения сверху и снизу,
// крупные кнопки по центру, полоса прогресса с оставшимся временем и ряд действий.
// «Пропустить опенинг» — в этом ряду: опенинг в каждом аниме в своём месте, пропуск по нажатию.
final class PlayerController: UIViewController, VLCMediaPlayerDelegate {
    static let skipStep: Int32 = 88_000          // типичная длина опенинга
    static let creditsWindow: Int32 = 90_000     // «Следующая серия» за полторы минуты до конца
    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]

    let playback: Playback
    let vlc = VLCMediaPlayer(options: ["--no-video-title-show", "--network-caching=1800", "--freetype-font=Arial", "--subsdec-encoding=UTF-8"])
    let surface = UIView(), chrome = UIView(), loading = UIActivityIndicatorView(style: .large)
    let topShade = GradientView(top: true), bottomShade = GradientView(top: false)
    let titleLabel = UILabel(), episodeLabel = UILabel(), elapsedLabel = UILabel(), remainingLabel = UILabel(), stateLabel = UILabel(), seekHint = UILabel()
    let slider = UISlider()
    var playButton: UIButton!, rewindButton: UIButton!, forwardButton: UIButton!
    var speedButton: UIButton!, subButton: UIButton!, qualityButton: UIButton!, nextButton: UIButton?
    var upNextButton: UIButton!
    var timer: Timer?, hideWork: DispatchWorkItem?, subtitleFile: URL?
    var subAttached = false, resumed = false, dragging = false
    var selected = 0, sourceIndex = 0, pendingTime: Int32 = 0, onClose: ((Bool, Bool) -> Void)?, isClosing = false
    var waitingForFrame = true, frameBaseline: Int32 = -1, waitStarted = Date(), ticks = 0
    var ended = false, countdown = 0, countdownTimer: Timer?
    var compact: Bool { traitCollection.horizontalSizeClass == .compact || traitCollection.verticalSizeClass == .compact }

    init(_ p: Playback) { playback = p; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { UIDevice.current.userInterfaceIdiom == .phone ? .landscape : .all }

    // MARK: Building blocks
    func pin(_ v: UIView, to p: UIView) { v.translatesAutoresizingMaskIntoConstraints = false; p.addSubview(v); NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: p.leadingAnchor), v.trailingAnchor.constraint(equalTo: p.trailingAnchor), v.topAnchor.constraint(equalTo: p.topAnchor), v.bottomAnchor.constraint(equalTo: p.bottomAnchor)]) }
    func iconButton(_ symbol: String, size: CGFloat, label: String, _ action: @escaping () -> Void) -> UIButton {
        var c = UIButton.Configuration.plain()
        c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))
        c.baseForegroundColor = .white
        let b = UIButton(configuration: c, primaryAction: UIAction { _ in action() })
        b.accessibilityLabel = label
        b.layer.shadowColor = UIColor.black.cgColor; b.layer.shadowOpacity = 0.5; b.layer.shadowRadius = 8; b.layer.shadowOffset = .zero
        return b
    }
    func actionButton(_ symbol: String, _ title: String, _ action: (() -> Void)? = nil) -> UIButton {
        var c = UIButton.Configuration.plain()
        c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        c.imagePadding = 5; c.title = title; c.baseForegroundColor = .white
        c.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 6)
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { var a = $0; a.font = .systemFont(ofSize: 14, weight: .semibold); return a }
        c.titleLineBreakMode = .byTruncatingTail
        let b = action.map { a in UIButton(configuration: c, primaryAction: UIAction { _ in a() }) } ?? UIButton(configuration: c)
        b.setContentCompressionResistancePriority(.required, for: .horizontal); b.titleLabel?.numberOfLines = 1
        b.configurationUpdateHandler = { b in b.alpha = b.isHighlighted ? 0.6 : 1 }
        return b
    }
    // Белая «пилюля» как у Skip Intro: заметная, но не мешает смотреть.
    func pillButton(_ title: String, _ action: @escaping () -> Void) -> UIButton {
        var c = UIButton.Configuration.filled()
        c.title = title; c.baseBackgroundColor = UIColor(white: 1, alpha: 0.95); c.baseForegroundColor = UIColor(red: 0.04, green: 0.07, blue: 0.12, alpha: 1)
        c.cornerStyle = .capsule; c.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 22, bottom: 12, trailing: 22)
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { var a = $0; a.font = .systemFont(ofSize: 15, weight: .bold); return a }
        let b = UIButton(configuration: c, primaryAction: UIAction { _ in action() })
        b.layer.shadowColor = UIColor.black.cgColor; b.layer.shadowOpacity = 0.45; b.layer.shadowRadius = 14; b.layer.shadowOffset = CGSize(width: 0, height: 4)
        b.isHidden = true
        return b
    }

    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black; surface.backgroundColor = .black
        pin(surface, to: view)
        let tap = UITapGestureRecognizer(target: self, action: #selector(togglePanel)); surface.addGestureRecognizer(tap)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapSeek(_:))); doubleTap.numberOfTapsRequired = 2; surface.addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)

        // Затемнения и всё управление живут в chrome, который плавно скрывается.
        pin(chrome, to: view); chrome.isUserInteractionEnabled = true
        for v in [topShade, bottomShade] { v.translatesAutoresizingMaskIntoConstraints = false; v.isUserInteractionEnabled = false; chrome.addSubview(v) }
        NSLayoutConstraint.activate([
            topShade.leadingAnchor.constraint(equalTo: chrome.leadingAnchor), topShade.trailingAnchor.constraint(equalTo: chrome.trailingAnchor), topShade.topAnchor.constraint(equalTo: chrome.topAnchor), topShade.heightAnchor.constraint(equalTo: chrome.heightAnchor, multiplier: 0.32),
            bottomShade.leadingAnchor.constraint(equalTo: chrome.leadingAnchor), bottomShade.trailingAnchor.constraint(equalTo: chrome.trailingAnchor), bottomShade.bottomAnchor.constraint(equalTo: chrome.bottomAnchor), bottomShade.heightAnchor.constraint(equalTo: chrome.heightAnchor, multiplier: 0.45)])
        let scrimTap = UIView(); pin(scrimTap, to: chrome); scrimTap.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(togglePanel)))
        chrome.sendSubviewToBack(scrimTap)

        let guide = view.safeAreaLayoutGuide, side: CGFloat = 20

        // Верх: закрыть, название аниме и серия.
        let close = iconButton("chevron.left", size: 22, label: "Закрыть") { [weak self] in self?.closePlayer() }
        let parts = playback.title.components(separatedBy: " · ")
        titleLabel.text = parts.count > 1 ? parts.dropLast().joined(separator: " · ") : playback.title
        episodeLabel.text = parts.count > 1 ? parts.last : nil
        titleLabel.font = .systemFont(ofSize: 17, weight: .bold); titleLabel.textColor = .white; titleLabel.textAlignment = .center; titleLabel.lineBreakMode = .byTruncatingTail
        episodeLabel.font = .systemFont(ofSize: 13, weight: .medium); episodeLabel.textColor = UIColor(white: 1, alpha: 0.72); episodeLabel.textAlignment = .center
        let titles = UIStackView(arrangedSubviews: [titleLabel, episodeLabel]); titles.axis = .vertical; titles.spacing = 2
        for v in [close, titles] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false; chrome.addSubview(v) }
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: side - 10), close.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            titles.centerXAnchor.constraint(equalTo: chrome.centerXAnchor), titles.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            titles.leadingAnchor.constraint(greaterThanOrEqualTo: close.trailingAnchor, constant: 12), titles.widthAnchor.constraint(lessThanOrEqualTo: guide.widthAnchor, multiplier: 0.7)])

        // Центр: −10, пауза, +10.
        rewindButton = iconButton("gobackward.10", size: 34, label: "Назад на 10 секунд") { [weak self] in self?.seek(by: -10_000) }
        playButton = iconButton("pause.fill", size: 50, label: "Пауза") { [weak self] in self?.playPause() }
        forwardButton = iconButton("goforward.10", size: 34, label: "Вперёд на 10 секунд") { [weak self] in self?.seek(by: 10_000) }
        let center = UIStackView(arrangedSubviews: [rewindButton, playButton, forwardButton]); center.axis = .horizontal; center.alignment = .center; center.spacing = 56
        center.translatesAutoresizingMaskIntoConstraints = false; chrome.addSubview(center)
        NSLayoutConstraint.activate([center.centerXAnchor.constraint(equalTo: chrome.centerXAnchor), center.centerYAnchor.constraint(equalTo: chrome.centerYAnchor)])

        // Низ: прогресс со временем и ряд действий.
        slider.minimumTrackTintColor = UIColor(red: 0.93, green: 0.96, blue: 1, alpha: 1); slider.maximumTrackTintColor = UIColor(white: 1, alpha: 0.28)
        slider.setThumbImage(thumb(14), for: .normal); slider.setThumbImage(thumb(20), for: .highlighted)
        slider.addTarget(self, action: #selector(seekStart), for: .touchDown); slider.addTarget(self, action: #selector(seekMove), for: .valueChanged); slider.addTarget(self, action: #selector(seekEnd), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        for l in [elapsedLabel, remainingLabel] { l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold); l.textColor = .white; l.setContentHuggingPriority(.required, for: .horizontal); l.setContentCompressionResistancePriority(.required, for: .horizontal) }
        let progress = UIStackView(arrangedSubviews: [elapsedLabel, slider, remainingLabel]); progress.axis = .horizontal; progress.alignment = .center; progress.spacing = 12

        speedButton = actionButton("gauge.with.needle", "Скорость 1×"); speedButton.showsMenuAsPrimaryAction = true
        subButton = actionButton("captions.bubble", "Субтитры"); subButton.showsMenuAsPrimaryAction = true
        qualityButton = actionButton("sparkles.tv", "Качество"); qualityButton.showsMenuAsPrimaryAction = true
        qualityButton.menu = UIMenu(title: "Качество", children: playback.options.enumerated().map { i, v in UIAction(title: label(v.height)) { [weak self] _ in self?.switchQuality(i) } })
        speedButton.menu = speedMenu()
        let skip = actionButton("forward.fill", "Пропустить опенинг") { [weak self] in self?.skipIntro() }
        var actions: [UIView] = [skip, speedButton, subButton, qualityButton]
        if playback.hasNext { let b = actionButton("forward.end.fill", "Следующая") { [weak self] in self?.closePlayer(next: true) }; b.accessibilityLabel = "Следующая серия"; nextButton = b; actions.append(b) }
        stateLabel.font = .systemFont(ofSize: 12, weight: .medium); stateLabel.textColor = UIColor(white: 1, alpha: 0.65)
        let row = UIStackView(arrangedSubviews: actions + [UIView(), stateLabel]); row.axis = .horizontal; row.alignment = .center; row.spacing = 2
        let bottom = UIStackView(arrangedSubviews: [progress, row]); bottom.axis = .vertical; bottom.spacing = 6
        bottom.translatesAutoresizingMaskIntoConstraints = false; chrome.addSubview(bottom)
        NSLayoutConstraint.activate([bottom.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: side), bottom.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -side), bottom.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -6)])

        // «Следующая серия» на финальных титрах — видна и при скрытом управлении.
        upNextButton = pillButton("Следующая серия") { [weak self] in self?.closePlayer(next: true) }
        upNextButton.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(upNextButton)
        NSLayoutConstraint.activate([upNextButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -side), upNextButton.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -14)])

        seekHint.font = .systemFont(ofSize: 22, weight: .bold); seekHint.textColor = .white; seekHint.alpha = 0; seekHint.textAlignment = .center
        seekHint.layer.shadowColor = UIColor.black.cgColor; seekHint.layer.shadowOpacity = 0.6; seekHint.layer.shadowRadius = 8; seekHint.layer.shadowOffset = .zero
        loading.color = .white; loading.startAnimating()
        for v in [seekHint, loading] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        NSLayoutConstraint.activate([loading.centerXAnchor.constraint(equalTo: view.centerXAnchor), loading.centerYAnchor.constraint(equalTo: view.centerYAnchor), seekHint.centerYAnchor.constraint(equalTo: view.centerYAnchor), seekHint.centerXAnchor.constraint(equalTo: view.centerXAnchor)])

        vlc.drawable = surface; vlc.delegate = self
        UIApplication.shared.isIdleTimerDisabled = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        Task { await prepare() }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // На iPhone видео смотрят горизонтально — поворачиваем экран сами, как стриминговые сервисы.
        if UIDevice.current.userInterfaceIdiom == .phone, let scene = view.window?.windowScene { setNeedsUpdateOfSupportedInterfaceOrientations(); scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) }
    }
    func thumb(_ d: CGFloat) -> UIImage { UIGraphicsImageRenderer(size: CGSize(width: d, height: d)).image { _ in UIColor.white.setFill(); UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: d, height: d)).fill() } }
    func label(_ h: Int) -> String { h >= 2160 ? "4K UHD" : h > 0 ? "\(h)p" : "Авто" }
    func speedMenu() -> UIMenu { UIMenu(title: "Скорость", children: Self.rates.map { r in UIAction(title: rateText(r), state: abs(vlc.rate - r) < 0.01 ? .on : .off) { [weak self] _ in self?.setRate(r) } }) }
    func rateText(_ r: Float) -> String { (r == 1 ? "1" : String(format: "%g", r).replacingOccurrences(of: ".", with: ",")) + "×" }
    func setRate(_ r: Float) { vlc.rate = r; speedButton.configuration?.title = "Скорость " + rateText(r); speedButton.menu = speedMenu(); scheduleHide() }

    // MARK: Playback
    func prepare() async {
        if let url = playback.subtitles {
            do {
                let data: Data
                if url.isFileURL { data = try Data(contentsOf: url) } else {
                    var req = URLRequest(url: url); req.setValue("NightAnime/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
                    let (d, response) = try await URLSession(configuration: .ephemeral).data(for: req)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError(message: "Субтитры недоступны") }; data = d
                }
                guard data.count < 8_000_000, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251), text.contains("[Events]") || text.contains("-->") else { throw APIError(message: "Не удалось прочитать субтитры") }
                let ext = text.contains("[Events]") ? "ass" : text.hasPrefix("WEBVTT") ? "vtt" : "srt"
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("night-sub-\(UUID().uuidString).\(ext)")
                try text.write(to: file, atomically: true, encoding: .utf8); subtitleFile = file
            } catch { showError("Субтитры не загрузились. Повторите запуск или выберите другой перевод."); return }
        }
        start()
    }
    func start() {
        guard !isClosing else { return }
        vlc.stop(); subAttached = false; resumed = false; ended = false
        let option = playback.options[selected]
        let sources = [option.url] + option.alternatives
        let media = VLCMedia(url: sources[min(sourceIndex, sources.count - 1)])
        media.addOption(":http-user-agent=NightAnime/1.0")
        media.addOption(":network-caching=1800")
        vlc.media = media; waitForFrame(); vlc.play()
        scheduleHide()
    }
    // Звук включается только после первого показанного кадра — так же, как на ТВ.
    func waitForFrame() { waitingForFrame = true; frameBaseline = vlc.time.intValue; waitStarted = Date(); loading.startAnimating(); loading.isHidden = false; vlc.audio?.volume = 0 }
    func switchQuality(_ i: Int) { pendingTime = vlc.time.intValue; selected = i; sourceIndex = 0; start() }
    func seek(by delta: Int32) { seek(to: vlc.time.intValue + delta); flash(delta > 0 ? "+10 с" : "−10 с") }
    func seek(to position: Int32) {
        let length = vlc.media?.length.intValue ?? 0
        guard length > 0, vlc.isSeekable else { stateLabel.text = "Перемотка будет доступна после загрузки"; return }
        let target = max(0, min(length - 1000, position))
        resumed = true; pendingTime = 0; waitForFrame(); vlc.time = VLCTime(int: target)
        HistoryState.savePosition(playback.key, Int(target)); scheduleHide()
    }
    func skipIntro() { seek(to: vlc.time.intValue + Self.skipStep); flash("Опенинг пропущен") }
    func flash(_ text: String) {
        seekHint.text = text; seekHint.layer.removeAllAnimations(); seekHint.alpha = 1
        UIView.animate(withDuration: 0.4, delay: 0.7, options: [.beginFromCurrentState]) { self.seekHint.alpha = 0 }
    }
    func tick() {
        guard !isClosing else { return }
        ticks += 1
        let length = vlc.media?.length.intValue ?? 0, now = max(0, vlc.time.intValue)
        if vlc.isPlaying {
            if !resumed && length > 0 {
                resumed = true
                let saved = pendingTime > 0 ? pendingTime : Int32(UserDefaults.standard.integer(forKey: playback.key))
                if saved > 0 && saved < length - 60_000 { seek(to: saved) }; pendingTime = 0
            }
            if let file = subtitleFile, !subAttached { subAttached = vlc.addPlaybackSlave(file, type: .subtitle, enforce: true) == 0 }
            if ticks % 10 == 0 && !ended { HistoryState.savePosition(playback.key, Int(now)); saveFraction(now, length) }
        }
        if waitingForFrame && ((vlc.isPlaying && vlc.hasVideoOut && vlc.time.intValue != frameBaseline) || Date().timeIntervalSince(waitStarted) > 12) {
            waitingForFrame = false; loading.stopAnimating(); loading.isHidden = true; vlc.audio?.volume = 100
        }
        if !dragging && length > 0 { slider.value = vlc.position }
        if !dragging { elapsedLabel.text = clock(now / 1000); remainingLabel.text = "−" + clock(max(0, length - now) / 1000) }
        let playing = vlc.isPlaying
        playButton.configuration?.image = UIImage(systemName: playing ? "pause.fill" : "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 50, weight: .semibold))
        playButton.accessibilityLabel = playing ? "Пауза" : "Продолжить"
        let h = playback.options[selected].height
        qualityButton.configuration?.title = label(h)
        if !(stateLabel.text ?? "").hasPrefix("Перемотка") || ticks % 6 == 0 {
            stateLabel.text = subtitleFile == nil ? "" : (subAttached ? "" : "Загрузка субтитров…")
        }
        // «Следующая серия»: на титрах в конце и с отсчётом после окончания.
        setFloating(upNextButton, visible: playback.hasNext && length > 0 && (ended || length - now < Self.creditsWindow))
        rebuildSubMenu()
        if vlc.state == .ended && !ended { finishedEpisode() }
        if vlc.state == .error {
            if sourceIndex < playback.options[selected].alternatives.count { sourceIndex += 1; pendingTime = max(pendingTime, vlc.time.intValue); start() }
            else { showError("Не удалось воспроизвести этот источник. Выберите другой перевод или качество.") }
        }
    }
    // Доля просмотренного — для полосок прогресса в списке серий и на полке «Продолжить».
    func saveFraction(_ t: Int32, _ length: Int32) { guard playback.episodeId != 0, length > 0 else { return }; UserDefaults.standard.set(min(1, Double(t) / Double(length)), forKey: "watch-\(playback.episodeId)") }
    func setFloating(_ b: UIButton, visible: Bool) {
        guard b.isHidden == visible else { return }
        if visible { b.alpha = 0; b.isHidden = false; UIView.animate(withDuration: 0.25) { b.alpha = 1 } }
        else { UIView.animate(withDuration: 0.25, animations: { b.alpha = 0 }) { _ in b.isHidden = true } }
    }
    // Конец серии: показать управление и, если есть следующая, через 10 секунд перейти к ней.
    func finishedEpisode() {
        ended = true; HistoryState.savePosition(playback.key, 0)
        hideWork?.cancel(); showPanel()
        guard playback.hasNext else { return }
        countdown = 10; upNextButton.configuration?.title = "Следующая серия · \(countdown)"
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self, !self.isClosing, self.countdown > 0 else { t.invalidate(); return }
            self.countdown -= 1
            if self.countdown <= 0 { t.invalidate(); self.closePlayer(next: true) } else { self.upNextButton.configuration?.title = "Следующая серия · \(self.countdown)" }
        }
    }
    func cancelCountdown() { guard countdown > 0 else { return }; countdown = 0; countdownTimer?.invalidate(); upNextButton.configuration?.title = "Следующая серия" }
    func clock(_ s: Int32) -> String { s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60) }
    func rebuildSubMenu() {
        let ids = vlc.videoSubTitlesIndexes as? [NSNumber] ?? []
        let names = vlc.videoSubTitlesNames as? [String] ?? []
        var tracks = ids.enumerated().map { i, id in UIAction(title: id.intValue < 0 ? "Выключить" : (i < names.count ? names[i] : "Субтитры"), state: vlc.currentVideoSubTitleIndex == id.int32Value ? .on : .off) { [weak self] _ in self?.vlc.currentVideoSubTitleIndex = id.int32Value } }
        if tracks.isEmpty { tracks = [UIAction(title: "Нет дорожек", attributes: .disabled) { _ in }] }
        let delay = String(format: "%+.1f с", Double(vlc.currentVideoSubTitleDelay) / 1e6).replacingOccurrences(of: ".", with: ",")
        let timing = UIMenu(title: "Задержка · \(delay)", options: .displayInline, children: [UIAction(title: "Раньше на 0,5 с") { [weak self] _ in self?.vlc.currentVideoSubTitleDelay -= 500_000 }, UIAction(title: "Позже на 0,5 с") { [weak self] _ in self?.vlc.currentVideoSubTitleDelay += 500_000 }, UIAction(title: "Сбросить задержку") { [weak self] _ in self?.vlc.currentVideoSubTitleDelay = 0 }])
        subButton.menu = UIMenu(title: "Субтитры", children: [UIMenu(options: .displayInline, children: tracks), timing])
    }
    func showError(_ message: String) { guard presentedViewController == nil, !isClosing else { return }; vlc.pause(); let alert = UIAlertController(title: "Yoru Anime", message: message, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "Закрыть", style: .default) { [weak self] _ in self?.closePlayer() }); present(alert, animated: true) }

    // MARK: Chrome
    func showPanel() { hideWork?.cancel(); guard chrome.alpha < 1 else { return }; chrome.isHidden = false; UIView.animate(withDuration: 0.2) { self.chrome.alpha = 1 } }
    func hidePanel() { UIView.animate(withDuration: 0.3, animations: { self.chrome.alpha = 0 }) { _ in if self.chrome.alpha == 0 { self.chrome.isHidden = true } } }
    func scheduleHide() { hideWork?.cancel(); let w = DispatchWorkItem { [weak self] in guard let self, !self.isClosing, self.vlc.isPlaying, !self.dragging else { return }; self.hidePanel() }; hideWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w) }
    func playPause() {
        cancelCountdown()
        if vlc.isPlaying { vlc.pause(); showPanel() }
        else if vlc.state == .ended || ended { pendingTime = 0; HistoryState.savePosition(playback.key, 0); start() }
        else { vlc.play(); scheduleHide() }
    }
    @objc func seekStart() { dragging = true; cancelCountdown(); hideWork?.cancel() }
    @objc func seekMove() { let length = vlc.media?.length.intValue ?? 0; let t = Int32(Float(length) * slider.value); elapsedLabel.text = clock(t / 1000); remainingLabel.text = "−" + clock(max(0, length - t) / 1000) }
    @objc func seekEnd() { let length = vlc.media?.length.intValue ?? 0; dragging = false; seek(to: Int32(Float(length) * slider.value)) }
    @objc func togglePanel() { cancelCountdown(); if chrome.isHidden || chrome.alpha < 1 { showPanel(); scheduleHide() } else { hidePanel() } }
    @objc func doubleTapSeek(_ g: UITapGestureRecognizer) { cancelCountdown(); seek(by: g.location(in: view).x < view.bounds.midX ? -10_000 : 10_000) }
    func closePlayer(next: Bool = false) {
        guard !isClosing else { return }
        let t = vlc.time.intValue, l = vlc.media?.length.intValue ?? 0
        let done = next || ended || (l > 0 && t > 0 && (Double(t) > Double(l) * 0.93 || l - t < 120_000))
        if resumed && !ended && t > 0 { HistoryState.savePosition(playback.key, Int(t)); saveFraction(t, l) }
        isClosing = true; timer?.invalidate(); countdownTimer?.invalidate(); hideWork?.cancel(); vlc.stop(); vlc.drawable = nil
        UIApplication.shared.isIdleTimerDisabled = false; if let file = subtitleFile { try? FileManager.default.removeItem(at: file) }
        if UIDevice.current.userInterfaceIdiom == .phone, let scene = view.window?.windowScene { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
        onClose?(done, next)
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); if !isClosing { closePlayer() } }
    deinit { timer?.invalidate(); countdownTimer?.invalidate() }
}

// Мягкое затемнение для читаемости кнопок поверх светлого видео.
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    init(top: Bool) {
        super.init(frame: .zero)
        let g = layer as! CAGradientLayer
        g.colors = [UIColor(red: 0.02, green: 0.04, blue: 0.08, alpha: 0.85).cgColor, UIColor(red: 0.02, green: 0.04, blue: 0.08, alpha: 0).cgColor]
        g.startPoint = CGPoint(x: 0.5, y: top ? 0 : 1); g.endPoint = CGPoint(x: 0.5, y: top ? 1 : 0)
    }
    required init?(coder: NSCoder) { fatalError() }
}
