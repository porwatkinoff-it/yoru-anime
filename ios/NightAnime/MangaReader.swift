import SwiftUI
import UIKit

// MARK: Читалка

// Перелистывание как в Книгах: системный UIPageViewController с загибом страницы (или сдвигом), касание у края
// листает, по центру — показывает панели. Место в главе сохраняется на каждой странице.
enum TurnStyle: String, CaseIterable { case curl, slide; var title: String { self == .curl ? "Загиб страницы" : "Сдвиг" } }

struct MangaReaderView: View {
    let details: MangaDetails
    @State var index: Int
    @State var page: Int
    @State var pages: [URL] = []
    @State var loading = true
    @State var error = ""
    @State var chrome = true
    @State var toast = ""
    @State var chapterList = false
    @State var generation = 0
    @State var loaded = ""
    @AppStorage("manga-turn") var turnRaw = TurnStyle.curl.rawValue
    @Environment(\.dismiss) var dismiss
    init(start: ReaderStart) { details = start.details; _index = State(initialValue: start.index); _page = State(initialValue: start.page) }
    var chapter: MangaChapter { details.chapters[index] }
    var turn: TurnStyle { TurnStyle(rawValue: turnRaw) ?? .curl }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !pages.isEmpty {
                PageTurner(pages: pages, turn: turn, page: $page, edge: edge, center: { withAnimation(.easeOut(duration: 0.2)) { chrome.toggle() } })
                    .id("\(chapter.id)|\(turn.rawValue)|\(generation)").ignoresSafeArea()
            } else if loading { ProgressView().tint(.white) }
            else {
                VStack(spacing: 14) {
                    EmptyState(icon: "exclamationmark.triangle", title: "Глава не открылась", text: error)
                    Button("Повторить") { Task { await load() } }.buttonStyle(PillStyle(primary: true))
                }
            }
            if chrome { bars.transition(.opacity) }
            if !toast.isEmpty {
                Text(toast).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.75), in: Capsule()).transition(.opacity).allowsHitTesting(false)
            }
        }
        .statusBarHidden(!chrome)
        .persistentSystemOverlays(chrome ? .automatic : .hidden)
        .task(id: chapter.id) { await load() }
        .onChange(of: page) { save() }
        .sheet(isPresented: $chapterList) { chapters }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            #if DEBUG
            if QA.has("--manga-hide-chrome") { chrome = false }
            #endif
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
    var bars: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).frame(width: 40, height: 40) }.accessibilityLabel("Закрыть")
                VStack(alignment: .leading, spacing: 1) {
                    Text(details.item.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Text(chapter.title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer()
                Button { chapterList = true } label: { Image(systemName: "list.bullet").font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40) }.accessibilityLabel("Главы")
                Menu {
                    Picker("Перелистывание", selection: $turnRaw) { ForEach(TurnStyle.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }
                } label: { Image(systemName: "textformat.size").font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40) }.accessibilityLabel("Настройки чтения")
            }
            .padding(.horizontal, 10).padding(.vertical, 6).foregroundStyle(.white)
            .background(.ultraThinMaterial.opacity(0.95)).environment(\.colorScheme, .dark)
            Spacer()
            if pages.count > 1 {
                VStack(spacing: 6) {
                    Slider(value: Binding(get: { Double(page) }, set: { page = Int($0.rounded()) }), in: 0...Double(pages.count - 1), step: 1).tint(.white)
                    HStack {
                        Button { go(-1, last: false) } label: { Label("Пред. глава", systemImage: "chevron.left") }.disabled(index == 0)
                        Spacer()
                        Text("\(page + 1) из \(pages.count)").monospacedDigit()
                        Spacer()
                        Button { go(1, last: false) } label: { Label("След. глава", systemImage: "chevron.right").labelStyle(TrailingIcon()) }.disabled(index >= details.chapters.count - 1)
                    }.font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 16).padding(.vertical, 10).foregroundStyle(.white)
                .background(.ultraThinMaterial.opacity(0.95)).environment(\.colorScheme, .dark)
            }
        }
    }
    var chapters: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(Array(details.chapters.enumerated()), id: \.element.id) { i, ch in
                    Button { chapterList = false; if i != index { index = i; page = 0 } } label: {
                        HStack {
                            Text(ch.title).foregroundStyle(i == index ? Night.accent : Night.text).fontWeight(i == index ? .bold : .regular)
                            Spacer()
                            if MangaDownloads.shared.done.contains(MangaDownloads.key(details.item, ch)) { Image(systemName: "arrow.down.circle.fill").foregroundStyle(Night.muted) }
                            if MangaStore.shared.isRead(details.item, ch) { Image(systemName: "checkmark").foregroundStyle(Night.muted) }
                        }
                    }.id(ch.id).listRowBackground(Night.surface)
                }
                .scrollContentBackground(.hidden).background(NightBackground())
                .onAppear { proxy.scrollTo(chapter.id, anchor: .center) }
            }
            .navigationTitle("Главы").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { chapterList = false } } }
        }.presentationDetents([.medium, .large]).preferredColorScheme(.dark)
    }
    func load() async {
        loading = true; error = ""; pages = []; loaded = ""
        let item = details.item, ch = chapter
        do {
            let list: [URL]
            if let local = MangaDownloads.shared.localPages(item, ch) { list = local } else { list = try await MangaAPI.pages(item, ch) }
            guard ch.id == chapter.id else { return }
            if page < 0 || page >= list.count { page = page < 0 ? list.count - 1 : 0 }
            pages = list; loaded = ch.id; generation += 1; save()
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    func save() { guard !pages.isEmpty, loaded == chapter.id, page >= 0 else { return }; MangaStore.shared.remember(details.item, chapter, page: min(page, pages.count - 1), count: pages.count) }
    // Касание за краем главы открывает соседнюю: вперёд — с первой страницы, назад — с последней.
    func edge(_ direction: Int) { go(direction, last: direction < 0) }
    func go(_ direction: Int, last: Bool) {
        let next = index + direction
        guard details.chapters.indices.contains(next) else { show(direction > 0 ? "Это последняя глава" : "Это первая глава"); return }
        page = last ? -1 : 0; index = next
        show(details.chapters[next].title)
    }
    func show(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if toast == text { withAnimation { toast = "" } } }
    }
}
struct TrailingIcon: LabelStyle { func makeBody(configuration: Configuration) -> some View { HStack(spacing: 4) { configuration.title; configuration.icon } } }

struct PageTurner: UIViewControllerRepresentable {
    let pages: [URL]
    let turn: TurnStyle
    @Binding var page: Int
    let edge: (Int) -> Void
    let center: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let options: [UIPageViewController.OptionsKey: Any] = turn == .curl ? [.spineLocation: UIPageViewController.SpineLocation.min.rawValue] : [.interPageSpacing: 14]
        let pvc = UIPageViewController(transitionStyle: turn == .curl ? .pageCurl : .scroll, navigationOrientation: .horizontal, options: options)
        pvc.view.backgroundColor = .black
        pvc.dataSource = context.coordinator; pvc.delegate = context.coordinator
        if turn == .curl { pvc.isDoubleSided = false }
        let c = context.coordinator
        c.controller = pvc
        pvc.setViewControllers([c.make(min(max(0, page), pages.count - 1))], direction: .forward, animated: false)
        // Свои касания вместо встроенных: левый и правый края листают (и за краем главы открывают соседнюю), центр — панели.
        pvc.gestureRecognizers.filter { $0 is UITapGestureRecognizer }.forEach { $0.isEnabled = false }
        // Края листают сразу, без ожидания второго касания (как в Книгах); центр ждёт — двойное касание там приближает.
        let edgeTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        edgeTap.delegate = c; pvc.view.addGestureRecognizer(edgeTap); c.edgeTap = edgeTap
        let centerTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        centerTap.delegate = c; pvc.view.addGestureRecognizer(centerTap)
        c.prefetch(page)
        #if DEBUG
        if let s = QA.value("--manga-auto-turn").flatMap(Double.init) {
            Timer.scheduledTimer(withTimeInterval: s, repeats: true) { [weak c] _ in c?.turn(1) }
        }
        #endif
        return pvc
    }
    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let c = context.coordinator; c.parent = self
        // Ползунок внизу перескакивает на страницу без анимации.
        if page != c.current, pages.indices.contains(page), !c.animating {
            pvc.setViewControllers([c.make(page)], direction: page > c.current ? .forward : .reverse, animated: false)
            c.current = page; c.prefetch(page)
        }
    }
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: PageTurner
        weak var controller: UIPageViewController?
        var current: Int
        var animating = false
        var queued: Int?
        weak var edgeTap: UITapGestureRecognizer?
        init(_ p: PageTurner) { parent = p; current = min(max(0, p.page), p.pages.count - 1) }
        func make(_ i: Int) -> PageController { PageController(index: i, url: parent.pages[i]) }
        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let i = (vc as? PageController)?.index, i > 0 else { return nil }; return make(i - 1)
        }
        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let i = (vc as? PageController)?.index, i + 1 < parent.pages.count else { return nil }; return make(i + 1)
        }
        func pageViewController(_ pvc: UIPageViewController, willTransitionTo pending: [UIViewController]) { animating = true }
        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            animating = false
            guard completed, let i = (pvc.viewControllers?.first as? PageController)?.index else { return }
            settle(i)
        }
        func settle(_ i: Int) { current = i; if parent.page != i { parent.page = i }; prefetch(i) }
        func prefetch(_ i: Int) {
            for j in [i + 1, i + 2, i - 1] where parent.pages.indices.contains(j) { let u = parent.pages[j]; Task.detached(priority: .utility) { _ = try? await MangaImages.fetch(u) } }
        }
        func turn(_ d: Int) {
            guard let pvc = controller else { return }
            // Быстрые касания подряд: прошлый загиб ещё идёт — новый начинается сразу после него, касание не теряется.
            if animating { queued = d; return }
            let next = current + d
            guard parent.pages.indices.contains(next) else { parent.edge(d); return }
            animating = true
            pvc.setViewControllers([make(next)], direction: d > 0 ? .forward : .reverse, animated: true) { [weak self] _ in
                guard let self else { return }
                self.animating = false; self.settle(next)
                if let q = self.queued { self.queued = nil; DispatchQueue.main.async { self.turn(q) } }
            }
        }
        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let v = g.view else { return }
            let x = g.location(in: v).x / max(1, v.bounds.width)
            let z = Self.zone(x); if z != 0 { turn(z) } else { parent.center() }
        }
        static func zone(_ x: CGFloat) -> Int { x < 0.3 ? -1 : x > 0.7 ? 1 : 0 }
        // Касание у края ловит только «краевой» распознаватель, в центре — только «центральный».
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let v = g.view, g.view === controller?.view, g is UITapGestureRecognizer else { return true }
            let edge = Self.zone(touch.location(in: v).x / max(1, v.bounds.width)) != 0
            return (g === edgeTap) == edge
        }
        // В центре одиночное касание ждёт, не будет ли второго (двойное приближает страницу); у краёв не ждёт.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            g !== edgeTap && (other as? UITapGestureRecognizer)?.numberOfTapsRequired == 2
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

// Одна страница: картинка вписана в экран, длинная лента манхвы — по ширине с прокруткой вниз; щипок и двойное касание приближают.
final class PageController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let index: Int
    let url: URL
    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failed = UILabel()
    private var task: Task<Void, Never>?
    init(index: Int, url: URL) { self.index = index; self.url = url; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scroll.frame = view.bounds; scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self; scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 4
        scroll.showsHorizontalScrollIndicator = false; scroll.contentInsetAdjustmentBehavior = .never; scroll.backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        scroll.addSubview(imageView); view.addSubview(scroll)
        spinner.color = .white; spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY); spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        spinner.startAnimating(); view.addSubview(spinner)
        failed.textColor = .lightGray; failed.font = .systemFont(ofSize: 14); failed.numberOfLines = 0; failed.textAlignment = .center; failed.isHidden = true
        failed.frame = view.bounds.insetBy(dx: 30, dy: 0); failed.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(failed)
        let double = UITapGestureRecognizer(target: self, action: #selector(zoom(_:))); double.numberOfTapsRequired = 2; double.delegate = self
        scroll.addGestureRecognizer(double)
        let width = UIScreen.main.bounds.width * UIScreen.main.scale, url = url
        task = Task { [weak self] in
            do {
                let data = try await MangaImages.fetch(url)
                let image = await Task.detached(priority: .userInitiated) { MangaImages.decode(data, width: width) }.value
                guard let self, !Task.isCancelled else { return }
                self.spinner.stopAnimating()
                if let image { self.imageView.image = image; self.layout() } else { self.fail("Не удалось показать страницу") }
            } catch { self?.fail(error.localizedDescription) }
        }
    }
    deinit { task?.cancel() }
    func fail(_ text: String) { spinner.stopAnimating(); failed.text = "Страница \(index + 1) не загрузилась\n\(text)"; failed.isHidden = false }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); if scroll.zoomScale == 1 { layout() } }
    func layout() {
        guard let image = imageView.image, image.size.width > 0 else { return }
        let b = view.bounds.size, ratio = image.size.height / image.size.width
        // Лента намного выше экрана — показываем по ширине и прокручиваем.
        let tall = ratio > b.height / b.width * 1.6
        let size = tall ? CGSize(width: b.width, height: b.width * ratio) : (ratio > b.height / b.width ? CGSize(width: b.height / ratio, height: b.height) : CGSize(width: b.width, height: b.width * ratio))
        imageView.frame = CGRect(origin: .zero, size: size)
        scroll.contentSize = size
        center()
    }
    func center() {
        let b = scroll.bounds.size, s = imageView.frame.size
        scroll.contentInset = UIEdgeInsets(top: max(0, (b.height - s.height) / 2), left: max(0, (b.width - s.width) / 2), bottom: 0, right: 0)
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    // Двойное касание приближает только в центре: у краёв касания листают.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        scroll.zoomScale > 1 || PageTurner.Coordinator.zone(touch.location(in: view).x / max(1, view.bounds.width)) == 0
    }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }
    @objc func zoom(_ g: UITapGestureRecognizer) {
        if scroll.zoomScale > 1 { scroll.setZoomScale(1, animated: true); return }
        let p = g.location(in: imageView), w = scroll.bounds.width / 2.5, h = scroll.bounds.height / 2.5
        scroll.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
    }
}
