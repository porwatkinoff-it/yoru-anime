import SwiftUI
import UIKit

// MARK: Навигация

struct Shelf: Hashable { let title: String; let params: [String: String] }
enum Route: Hashable { case title(AnimeItem, resume: Bool = false), shelf(Shelf), schedule, search, manga(MangaItem) }

// Подборки главной: как у Netflix и Кинопоиска — ряды по теме, внутри по рейтингу.
enum Shelves {
    static var year: Int { Calendar.current.component(.year, from: Date()) }
    static let airing = Shelf(title: "Сейчас выходят", params: ["isAiring": "1", "fields": AnimeStore.cardFields + ",descriptions"])
    static var home: [Shelf] {
        [Shelf(title: "Лучшее \(year) года", params: ["year": "\(year)"]), Shelf(title: "Фильмы", params: ["type": "movie"]),
         genre(1, "Экшен"), genre(22, "Романтика"), Shelf(title: "Лучшее \(year - 1) года", params: ["year": "\(year - 1)"]),
         genre(4, "Комедия"), genre(62, "Исекай"), genre(36, "Повседневность"), genre(10, "Фэнтези"), genre(7, "Детективы")]
    }
    static func genre(_ id: Int, _ title: String) -> Shelf { Shelf(title: title, params: ["genres": "\(id)"]) }
    static let genres: [Genre] = [(1, "Экшен"), (2, "Приключения"), (4, "Комедия"), (8, "Драма"), (10, "Фэнтези"), (22, "Романтика"), (24, "Фантастика"), (36, "Повседневность"),
                                  (62, "Исекай"), (7, "Детектив"), (37, "Сверхъестественное"), (23, "Школа"), (30, "Спорт"), (18, "Меха"), (40, "Психологическое"), (41, "Триллер"),
                                  (13, "Исторический"), (19, "Музыка"), (63, "Ияшикей"), (76, "Выживание")].map { Genre(id: $0.0, title: $0.1) }
}

struct RootView: View {
    @EnvironmentObject var store: AnimeStore
    @Environment(\.scenePhase) var phase
    @Environment(\.openURL) var openURL
    @State var update: AppRelease?
    @State var wasBackground = false
    var body: some View {
        TabView(selection: $store.tab) {
            // Два раздела — аниме и манга; «Моё» и «Загрузки» общие, внутри переключатель Аниме/Манга.
            NavigationStack(path: $store.homePath) { HomeView().routes() }.tabItem { Label("Аниме", systemImage: "play.tv.fill") }.tag(0)
            MangaTab().tabItem { Label("Манга", systemImage: "book.fill") }.tag(4)
            // Один поиск на всё: аниме, манга MangaLib, комиксы Com-X и ссылки Шикимори.
            NavigationStack(path: $store.searchPath) { SearchView().routes() }.tabItem { Label("Поиск", systemImage: "magnifyingglass") }.tag(5)
            NavigationStack { SplitSection(title: "Моё") { LibraryView() } manga: { MangaLibraryView() }.routes() }.tabItem { Label("Моё", systemImage: "heart.fill") }.tag(2)
            NavigationStack { SplitSection(title: "Загрузки") { DownloadsView() } manga: { MangaDownloadsView() }.routes() }.tabItem { Label("Загрузки", systemImage: "arrow.down.circle.fill") }.tag(3)
        }
        // Запуск: аккаунт и телевизор — по очереди (синхронизация зависит от входа), остальное параллельно и не ждёт поиска приставки.
        .task {
            DownloadCenter.shared.store = store
            await store.refreshAccount(); await store.sync()
            async let finished: Void = store.refreshFinished()
            async let fresh: Void = store.checkNewEpisodes()
            _ = await (finished, fresh)
            await Servers.autoCheck(store)
        }
        .task { await ShikiAccount.shared.syncBoth(store) }
        // Перенос с Шикимори виден на любом экране, а не только в меню аккаунта.
        .overlay(alignment: .bottom) { ShikiSyncBanner().padding(.bottom, 62) }
        .task { if Updater.due { update = try? await Updater.check() } }
        // Новая версия на GitHub: iPhone не ставит IPA сам — открываем страницу релиза.
        .alert(update.map { "Доступна Yoru \($0.version)" } ?? "", isPresented: Binding(get: { update != nil }, set: { if !$0 { update = nil } }), presenting: update) { r in
            Button("Скачать на GitHub") { openURL(r.page) }
            Button("Позже", role: .cancel) {}
        } message: { r in Text("Сейчас установлена \(Updater.current).\(r.notes.isEmpty ? "" : "\n\n" + String(r.notes.prefix(600)))") }
        // Синхронизация с телевизором — только после настоящего возврата в приложение: Пункт управления, уведомления
        // и первый показ при запуске тоже дают .active, но ради них поиск приставки в сети (до 6 с) не запускается.
        .onChange(of: phase) {
            if phase == .background {
                wasBackground = true
                // Перед уходом в фон отдаём изменения в аккаунт Yoru — вдруг приложение потом удалят.
                if YoruAccount.shared.logged {
                    let id = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
                    Task { await YoruAccount.shared.sync(); UIApplication.shared.endBackgroundTask(id) }
                }
            }
            else if phase == .active && wasBackground { wasBackground = false; Task { await store.sync(); await store.refreshFinished() } }
        }
        .onAppear {
            #if DEBUG
            if let t = QA.value("--tab").flatMap(Int.init) { store.tab = t }
            if QA.has("--open-schedule") { store.homePath = [.schedule] }
            if QA.value("--search") != nil { store.tab = 5 }
            // Проверка загрузок и Live Activity: две тестовые серии по ссылке из --qa-download-url.
            if QA.has("--qa-enqueue"), QA.value("--qa-download-url") != nil, DownloadCenter.shared.items.isEmpty {
                let series = AnimeItem(["id": 1, "titles": ["ru": "Тестовое аниме"]])
                Task { for n in 1...2 { try? await DownloadCenter.shared.enqueue(Translation(["id": 1, "type": "voiceRu", "authorsSummary": "Тест"]), Episode(["id": 900000 + n, "episodeFull": "\(n) серия", "episodeInt": n]), series, store: store) } }
            }
            if let m = QA.value("--manga-open") {
                let parts = m.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2, let source = MangaSource(rawValue: parts[0]) { store.tab = 4; MangaStore.shared.source = source; MangaStore.shared.path = [MangaItem(source: source, key: parts[1], title: "Манга")] }
            }
            if let id = QA.value("--open-id").flatMap(Int.init) { store.homePath = [.title(AnimeItem(["id": id]))] }
            if QA.has("--open-first") { Task { await store.loadShelf(Shelves.airing); if let f = store.shelves[Shelves.airing]?.first { store.homePath = [.title(f, resume: QA.has("--resume"))] } } }
            #endif
        }
    }
}
extension View {
    func routes() -> some View {
        navigationDestination(for: Route.self) { r in
            switch r {
            case .title(let item, let resume): TitleView(item: item, autoResume: resume)
            case .shelf(let s): ShelfGridView(shelf: s)
            case .schedule: ScheduleView()
            case .search: SearchView()
            case .manga(let m): MangaTitleView(item: m)
            }
        }
        .navigationDestination(for: MangaItem.self) { MangaTitleView(item: $0) }
        .background(NightBackground())
        .toolbarBackground(Night.bg.opacity(0.92), for: .navigationBar)
    }
}

// MARK: Общие элементы

enum Metrics {
    static var regular: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    static var poster: CGSize { regular ? CGSize(width: 150, height: 225) : CGSize(width: 112, height: 168) }
    // Ширина карточки в сетке: столько колонок, сколько помещается (на iPhone — три), без пустых зазоров.
    static var grid: (count: Int, width: CGFloat) {
        let w = UIScreen.main.bounds.width - 36
        let count = max(3, Int((w + 12) / (poster.width + 12)))
        return (count, floor((w - 12 * CGFloat(count - 1)) / CGFloat(count)))
    }
}
// Две оценки, как Кинопоиск и IMDb: Anime 365 (365) и Шикимори (Shiki).
struct ScoreChip: View {
    @ObservedObject var shiki = Shikimori.shared
    let item: AnimeItem
    var body: some View {
        let s = shiki.score(item) ?? 0
        HStack(spacing: 7) {
            Color.clear.frame(width: 0, height: 0)
            if item.score > 0 { Self.score(item.score, "365") }
            if s > 0 { Self.score(s, "Shiki") }
        }.onAppear { shiki.want(item) }
    }
    static func color(_ v: Double) -> Color { v >= 8 ? Night.scoreHigh : v >= 6.5 ? Night.scoreMid : Night.scoreLow }
    static func text(_ v: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",") }
    static func score(_ v: Double, _ label: String) -> some View {
        HStack(spacing: 2) {
            Text(label).font(.system(size: 9, weight: .heavy)).foregroundStyle(Night.muted)
            Text(text(v)).font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(color(v))
        }.accessibilityElement(children: .combine)
    }
}
// Подпись карточки: две оценки; год — только если для него осталось место (одна оценка или ни одной).
struct CardMeta: View {
    @ObservedObject var shiki = Shikimori.shared
    let item: AnimeItem
    var body: some View {
        let both = item.score > 0 && (shiki.score(item) ?? 0) > 0
        ScoreChip(item: item).layoutPriority(1)
        if !both { Text(item.year > 0 ? "\(item.year)" : item.kind).foregroundStyle(Night.muted) }
    }
}
// Крупная оценка на странице аниме и манги.
struct ScoreBox: View {
    let label: String
    let value: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ScoreChip.text(value, 2)).font(.system(size: 17, weight: .heavy)).monospacedDigit().foregroundStyle(ScoreChip.color(value))
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Night.muted)
        }.padding(.horizontal, 9).padding(.vertical, 5).background(Night.raised, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Night.stroke))
        .accessibilityElement(children: .combine)
    }
}
struct UHDBadge: View {
    var body: some View {
        Text("4K").font(.system(size: 10, weight: .heavy)).foregroundStyle(Night.onAccent).padding(.horizontal, 5).padding(.vertical, 2)
            .background(Night.accent, in: RoundedRectangle(cornerRadius: 5)).accessibilityLabel("Есть 4K")
    }
}
struct ProgressLine: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) { Capsule().fill(Color.white.opacity(0.22)); Capsule().fill(Night.progress).frame(width: max(3, g.size.width * min(1, value))) }
        }.frame(height: 3)
    }
}
struct PosterCard: View {
    @EnvironmentObject var store: AnimeStore
    @EnvironmentObject var downloads: DownloadCenter
    @ObservedObject var uhd = UHD.shared
    let item: AnimeItem
    var progress: Double? = nil
    var caption: String? = nil
    var width: CGFloat = Metrics.poster.width
    var body: some View {
        let h = width * 1.5
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottom) {
                CachedPoster(url: item.posterSmall, fill: true).frame(width: width, height: h).background(Night.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                if let progress { ProgressLine(value: progress).padding(.horizontal, 8).padding(.bottom, 8) }
            }
            .overlay(alignment: .topLeading) {
                if store.hasNew(item) { Text("НОВАЯ СЕРИЯ").font(.system(size: 9, weight: .heavy)).foregroundStyle(Night.onAccent).padding(.horizontal, 6).padding(.vertical, 3).background(Night.fresh, in: Capsule()).padding(6) }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    if uhd.has(item) { UHDBadge() }
                    if downloads.items.contains(where: { $0.seriesId == item.id && $0.state == .done }) { Image(systemName: "arrow.down.circle.fill").font(.system(size: 17)).foregroundStyle(.white, Night.bg.opacity(0.7)) }
                }.padding(6)
            }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Night.stroke))
            Text(item.title).font(.system(size: 13, weight: .bold)).foregroundStyle(Night.text).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                if let caption { Text(caption).foregroundStyle(Night.muted) } else { CardMeta(item: item) }
            }.font(.system(size: 12)).lineLimit(1)
        }
        .frame(width: width).contentShape(Rectangle())
        .onAppear { uhd.want(item, store: store) }
        .accessibilityElement(children: .combine)
    }
}
struct ShelfRow<Content: View>: View {
    let title: String
    var more: Route? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 19, weight: .bold)).foregroundStyle(Night.text)
                Spacer()
                if let more { NavigationLink(value: more) { Text("Все").font(.system(size: 14, weight: .semibold)).foregroundStyle(Night.muted) } }
            }.padding(.horizontal, 18)
            ScrollView(.horizontal, showsIndicators: false) { LazyHStack(alignment: .top, spacing: 12) { content }.padding(.horizontal, 18) }
        }
    }
}
// Полка, которая сама загружает свою подборку с сайта и держит её в памяти до перезапуска.
struct RemoteShelf: View {
    @EnvironmentObject var store: AnimeStore
    let shelf: Shelf
    var exclude: Int = 0
    var body: some View {
        let items = (store.shelves[shelf] ?? []).filter { $0.id != exclude }
        Group {
            if store.shelves[shelf] == nil {
                ShelfRow(title: shelf.title) { ForEach(0..<6, id: \.self) { _ in RoundedRectangle(cornerRadius: 12).fill(Night.surface).frame(width: Metrics.poster.width, height: Metrics.poster.height + 44) } }
            } else if !items.isEmpty {
                ShelfRow(title: shelf.title, more: .shelf(shelf)) { ForEach(items) { item in NavigationLink(value: Route.title(item)) { PosterCard(item: item) }.buttonStyle(.plain) } }
            }
        }
        .task { await store.loadShelf(shelf) }
    }
}
struct PillStyle: ButtonStyle {
    var primary = false
    // Действие выполняется: спиннер слева от надписи, повторные нажатия не проходят.
    var busy = false
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) { if busy { ProgressView().tint(primary ? Night.onAccent : Night.text).controlSize(.small) }; configuration.label }
            .allowsHitTesting(!busy)
            .font(.system(size: 15, weight: .semibold)).lineLimit(1).padding(.horizontal, 16).frame(minHeight: 46)
            .foregroundStyle(primary ? Night.onAccent : Night.text)
            .background(primary ? Night.accent : Night.raised, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(primary ? .clear : Night.stroke))
            .opacity(configuration.isPressed ? 0.8 : 1).scaleEffect(configuration.isPressed ? 0.97 : 1).animation(.easeOut(duration: 0.13), value: configuration.isPressed)
    }
}
struct Chip: View {
    let title: String; var selected = false
    var body: some View {
        Text(title).font(.system(size: 14, weight: .semibold)).padding(.horizontal, 14).frame(height: 36)
            .foregroundStyle(selected ? Night.onAccent : Night.text).background(selected ? Night.accent : Night.raised, in: Capsule()).overlay(Capsule().stroke(Night.stroke))
    }
}
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { arrange(proposal.width ?? 360, subviews).size }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, p) in arrange(b.width, subviews).points.enumerated() { subviews[i].place(at: CGPoint(x: b.minX + p.x, y: b.minY + p.y), proposal: .unspecified) }
    }
    func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, points: [CGPoint] = []
        for s in subviews { let size = s.sizeThatFits(.unspecified); if x + size.width > width, x > 0 { x = 0; y += line + spacing; line = 0 }; points.append(CGPoint(x: x, y: y)); x += size.width + spacing; line = max(line, size.height) }
        return (CGSize(width: width, height: y + line), points)
    }
}
struct PosterGrid: View {
    let items: [AnimeItem]
    var onLast: (() -> Void)? = nil
    var body: some View {
        let g = Metrics.grid
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(g.width), spacing: 12, alignment: .top), count: g.count), alignment: .leading, spacing: 18) {
            ForEach(items) { item in
                NavigationLink(value: Route.title(item)) { PosterCard(item: item, width: g.width) }.buttonStyle(.plain)
                    .contextMenu { if let u = Shikimori.url(item) { Link(destination: u) { Label("Открыть на Шикимори", systemImage: "arrow.up.right") } } }
                    .onAppear { if item.id == items.last?.id { onLast?() } }
            }
        }.padding(.horizontal, 18)
    }
}
struct EmptyState: View {
    let icon: String; let title: String; let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40, weight: .light)).foregroundStyle(Night.muted)
            Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(Night.text)
            Text(text).font(.system(size: 14)).foregroundStyle(Night.muted).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 30)
    }
}

// MARK: Главная

struct HomeView: View {
    @EnvironmentObject var store: AnimeStore
    @State var login = false
    @State var accounts = false
    var continueItems: [AnimeItem] { store.history.filter { store.lastEpisode($0) != 0 && !store.finished($0) }.prefix(15).map { $0 } }
    var fresh: [AnimeItem] { store.favorites.filter { store.hasNew($0) } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                HStack {
                    Text("Аниме").font(.system(size: 24, weight: .heavy)).foregroundStyle(Night.text)
                    Spacer()
                    Button { accounts = true } label: { Image(systemName: store.token.isEmpty ? "person.crop.circle.badge.plus" : "person.crop.circle.fill").font(.system(size: 26)).foregroundStyle(Night.text) }
                        .accessibilityLabel("Аккаунты")
                }.padding(.horizontal, 18)
                Hero()
                HStack(spacing: 10) {
                    NavigationLink(value: Route.schedule) { Label("Расписание", systemImage: "calendar") }.buttonStyle(PillStyle())
                    NavigationLink(value: Route.shelf(Shelves.airing)) { Label("Онгоинги", systemImage: "dot.radiowaves.left.and.right") }.buttonStyle(PillStyle())
                }.padding(.horizontal, 18)
                if !continueItems.isEmpty {
                    ShelfRow(title: "Продолжить просмотр") {
                        ForEach(continueItems) { item in
                            NavigationLink(value: Route.title(item)) { PosterCard(item: item, progress: max(0.02, store.fraction(store.lastEpisode(item))), caption: store.lastEpisodeTitle(item) ?? "Продолжить") }.buttonStyle(.plain)
                        }
                    }
                }
                if !fresh.isEmpty { ShelfRow(title: "Новые серии в избранном") { ForEach(fresh) { item in NavigationLink(value: Route.title(item)) { PosterCard(item: item) }.buttonStyle(.plain) } } }
                RemoteShelf(shelf: Shelves.airing)
                if !store.favorites.isEmpty { ShelfRow(title: "Мой список") { ForEach(store.favorites.prefix(20)) { item in NavigationLink(value: Route.title(item)) { PosterCard(item: item) }.buttonStyle(.plain) } } }
                ForEach(Shelves.home, id: \.self) { RemoteShelf(shelf: $0) }
            }.padding(.vertical, 12)
        }
        .refreshable { store.shelves = [:]; await store.loadShelf(Shelves.airing) }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $login) { LoginView() }
        .sheet(isPresented: $accounts) { MangaAccountsView() }
        .onAppear {
            #if DEBUG
            if QA.has("--accounts") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { accounts = true } }
            if QA.has("--login") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { login = true } }
            #endif
        }
    }
}
// Баннер на главной убран: здесь остаётся только сообщение «нет связи».
struct Hero: View {
    @EnvironmentObject var store: AnimeStore
    var body: some View {
        if store.shelfErrors[Shelves.airing] != nil {
            VStack(spacing: 12) {
                EmptyState(icon: "wifi.slash", title: "Нет связи с Anime 365", text: store.shelfErrors[Shelves.airing] ?? "")
                HStack(spacing: 10) {
                    Button("Повторить") { Task { store.shelfErrors[Shelves.airing] = nil; await store.loadShelf(Shelves.airing) } }.buttonStyle(PillStyle(primary: true))
                    Button("Мои загрузки") { store.tab = 3 }.buttonStyle(PillStyle())
                }
            }.frame(maxWidth: .infinity)
        }
    }
}

// MARK: Поиск

struct SearchView: View {
    @EnvironmentObject var store: AnimeStore
    @State var query = ""
    @State var genre: Genre?
    @State var items: [AnimeItem] = []
    @State var busy = false
    @State var message = ""
    @State var exhausted = false
    @State var manga: [MangaItem] = []
    @State var mangaBusy = false
    @State var opening = false
    @FocusState var focused: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Night.muted)
                    TextField("", text: $query, prompt: Text("Аниме, манга, комиксы").foregroundStyle(Night.muted)).font(.system(size: 17)).foregroundStyle(Night.text)
                        .submitLabel(.search).autocorrectionDisabled().focused($focused)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Night.muted) }.accessibilityLabel("Очистить") }
                }
                .padding(.horizontal, 14).frame(height: 50).background(Night.raised, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Night.stroke)).padding(.horizontal, 18)
                if query.isEmpty {
                    FlowLayout {
                        ForEach(Shelves.genres) { g in Button { genre = genre == g ? nil : g; focused = false } label: { Chip(title: g.title, selected: genre == g) }.buttonStyle(.plain) }
                    }.padding(.horizontal, 18)
                    Text(header).font(.system(size: 19, weight: .bold)).foregroundStyle(Night.text).padding(.horizontal, 18)
                    if !message.isEmpty { Text(message).foregroundStyle(Night.muted).padding(.horizontal, 18); Button("Повторить") { Task { await load(reset: true) } }.buttonStyle(PillStyle()).padding(.horizontal, 18) }
                    PosterGrid(items: items) { Task { await load(reset: false) } }
                    if busy { ProgressView().frame(maxWidth: .infinity).padding() }
                } else {
                    // Общий поиск: аниме, манга MangaLib и комиксы Com-X — каждый своим рядом.
                    if busy || !items.isEmpty {
                        ShelfRow(title: "Аниме") {
                            if busy && items.isEmpty { placeholders }
                            ForEach(items) { item in NavigationLink(value: Route.title(item)) { PosterCard(item: item) }.buttonStyle(.plain).onAppear { if item.id == items.last?.id { Task { await load(reset: false) } } } }
                        }
                    }
                    if !message.isEmpty { Text(message).foregroundStyle(Night.muted).padding(.horizontal, 18); Button("Повторить") { Task { await load(reset: true) } }.buttonStyle(PillStyle()).padding(.horizontal, 18) }
                    ForEach(MangaSource.allCases) { src in
                        let list = manga.filter { $0.source == src }
                        if mangaBusy || !list.isEmpty {
                            ShelfRow(title: src == .mangalib ? "Манга · MangaLib" : "Комиксы · Com-X") {
                                if mangaBusy && list.isEmpty { placeholders }
                                ForEach(list) { m in NavigationLink(value: m) { MangaCard(item: m) }.buttonStyle(.plain) }
                            }
                        }
                    }
                    if items.isEmpty && manga.isEmpty && !busy && !mangaBusy && message.isEmpty { EmptyState(icon: "sparkle.magnifyingglass", title: "Ничего не нашлось", text: "Попробуйте другое название") }
                }
                if !query.isEmpty, !busy, let url = Shikimori.search(query) {
                    Link(destination: url) { Label("Найти «\(query)» на Шикимори", systemImage: "arrow.up.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Night.progress) }.padding(.horizontal, 18)
                }
            }.padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Поиск").toolbarTitleDisplayMode(.inline)
        .onChange(of: store.tab) { if store.tab == 5 && query.isEmpty { focused = true } }
        .onAppear {
            #if DEBUG
            if let q = QA.value("--search"), query.isEmpty, items.isEmpty { query = q; return }
            #endif
            if items.isEmpty && query.isEmpty { focused = true }
        }
        .task(id: "\(query)|\(genre?.id ?? 0)") { do { try await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 350)); await load(reset: true) } catch {} }
        .task(id: query) {
            if let link = Shikimori.link(query) { await open(link); return }
            do { try await Task.sleep(for: .milliseconds(450)); await searchManga() } catch {}
        }
        .overlay { if opening { VStack(spacing: 10) { ProgressView().tint(Night.text); Text("Открываю ссылку Шикимори…").font(.system(size: 14, weight: .semibold)).foregroundStyle(Night.text) }.padding(20).background(Night.raised.opacity(0.96), in: RoundedRectangle(cornerRadius: 16)) } }
    }
    // Оба источника параллельно; ошибки молча пропускаем — это дополнение к аниме, не основной результат.
    // Вставили ссылку Шикимори — сразу открываем это аниме или мангу; не нашлось у нас — ищем по названию.
    func open(_ link: Shikimori.Link) async {
        opening = true; defer { opening = false }
        focused = false
        do {
            switch try await Shikimori.resolve(link, store: store) {
            case .anime(let item)?: query = ""; store.searchPath.append(.title(item))
            case .manga(let m)?: query = ""; store.searchPath.append(.manga(m))
            case .title(let t)?: query = t
            case nil: message = "Шикимори не знает такую страницу"
            }
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
    }
    var placeholders: some View { ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 12).fill(Night.surface).frame(width: Metrics.poster.width, height: Metrics.poster.width * 1.5).overlay(ProgressView()) } }
    func searchManga() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { manga = []; mangaBusy = false; return }
        mangaBusy = true; manga = []
        async let a = try? MangaAPI.search(.mangalib, q, page: 1)
        async let b = try? MangaAPI.search(.comx, q, page: 1)
        let (x, y) = await (a, b)
        guard q == query.trimmingCharacters(in: .whitespaces), !Task.isCancelled else { return }
        manga = Array((x?.0 ?? []).prefix(12)) + Array((y?.0 ?? []).prefix(8))
        mangaBusy = false
    }
    var header: String { !query.isEmpty ? "Аниме" + (genre.map { " · " + $0.title } ?? "") : genre?.title ?? "Популярное сейчас" }
    var params: [String: String] { var p: [String: String] = [:]; if !query.isEmpty, Shikimori.link(query) == nil { p["query"] = query }; if let genre, query.isEmpty { p["genres"] = "\(genre.id)" }; if p.isEmpty { p["isAiring"] = "1" }; return p }
    func load(reset: Bool) async {
        if busy && !reset { return }
        if !reset && exhausted { return }
        let p = params; busy = true; message = ""
        do {
            let a = try await store.shelf(p, offset: reset ? 0 : items.count)
            guard p == params else { return }
            if reset { items = a } else { let ids = Set(items.map(\.id)); items += a.filter { !ids.contains($0.id) } }
            exhausted = a.count < 24
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
        busy = false
    }
}
struct ShelfGridView: View {
    @EnvironmentObject var store: AnimeStore
    let shelf: Shelf
    @State var items: [AnimeItem] = []
    @State var busy = false
    @State var exhausted = false
    var body: some View {
        ScrollView { PosterGrid(items: items) { Task { await more() } }.padding(.vertical, 12); if busy { ProgressView().padding() } }
            .navigationTitle(shelf.title).toolbarTitleDisplayMode(.inline)
            .task { if items.isEmpty { items = store.shelves[shelf] ?? []; if items.isEmpty { await more() } } }
    }
    func more() async {
        guard !busy, !exhausted else { return }
        busy = true
        if let a = try? await store.shelf(shelf.params, offset: items.count) { let ids = Set(items.map(\.id)); items += a.filter { !ids.contains($0.id) }; exhausted = a.count < 24 }
        busy = false
    }
}

// MARK: Моё

struct LibraryView: View {
    @EnvironmentObject var store: AnimeStore
    @ObservedObject var shiki = ShikiAccount.shared
    @State var section = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Раздел", selection: $section) { Text("Мой список").tag(0); Text("История").tag(1); if shiki.signedIn { Text("Шикимори").tag(2) } }.pickerStyle(.segmented).padding(.horizontal, 18)
                if section == 2 { ShikiListView() } else {
                let items = section == 0 ? store.favorites : store.history
                if items.isEmpty {
                    EmptyState(icon: section == 0 ? "heart" : "clock", title: section == 0 ? "Список пуст" : "Вы ещё ничего не смотрели",
                               text: section == 0 ? "Нажмите «Мой список» на странице аниме — оно появится здесь и на телевизоре" : "Начатые серии появятся здесь и на полке «Продолжить просмотр»")
                } else { PosterGrid(items: items) }
                }
            }.padding(.vertical, 12)
        }
        .refreshable { if section == 2 { await shiki.refresh() } }
        .onChange(of: shiki.signedIn) { if !shiki.signedIn && section == 2 { section = 0 } }
        .onAppear {
            #if DEBUG
            if QA.has("--shiki-demo") && QA.value("--tab") == "2" { section = 2 }
            #endif
        }
        .navigationTitle("Моё").toolbarTitleDisplayMode(.inline)
    }
}

// MARK: Шикимори: оценка на странице аниме и список пользователя

struct ShikiSyncBanner: View {
    @ObservedObject var shiki = ShikiAccount.shared
    var body: some View {
        Group {
            if shiki.reporting || !shiki.syncResult.isEmpty {
                HStack(spacing: 10) {
                    if shiki.reporting { ProgressView().tint(Night.text) } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Night.scoreHigh) }
                    Text(shiki.reporting ? shiki.syncStep : shiki.syncResult).font(.system(size: 14, weight: .semibold)).foregroundStyle(Night.text).lineLimit(2)
                }
                .padding(.horizontal, 16).padding(.vertical, 12).background(Night.raised.opacity(0.98), in: Capsule()).overlay(Capsule().stroke(Night.stroke))
                .padding(.horizontal, 18).onTapGesture { if !shiki.reporting { shiki.syncResult = "" } }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: shiki.reporting)
        .animation(.easeOut(duration: 0.2), value: shiki.syncResult)
        .task(id: shiki.syncResult) { guard !shiki.syncResult.isEmpty else { return }; try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { shiki.syncResult = "" } }
    }
}

struct ShikiRateRow: View {
    let item: AnimeItem
    let watched: Int
    @ObservedObject var shiki = ShikiAccount.shared
    @State var busy = false
    var body: some View {
        if shiki.signedIn && item.malId > 0 {
            let r = shiki.rate(item), score = r?.score ?? 0
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(score > 0 ? "Моя оценка · \(score)" : "Моя оценка").font(.system(size: 14, weight: .semibold)).foregroundStyle(Night.text)
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Menu {
                        ForEach(ShikiRate.statuses, id: \.0) { s in Button { change { await shiki.setStatus(s.0, for: item) } } label: { if r?.status == s.0 { Label(s.1, systemImage: "checkmark") } else { Text(s.1) } } }
                    } label: {
                        HStack(spacing: 4) { Text(r.map { ShikiRate.statusTitle($0.status) + ($0.episodes > 0 && $0.status != "completed" ? " · \($0.episodes) сер." : "") } ?? "Не в списке"); Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)) }
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Night.progress)
                    }
                }
                HStack(spacing: 0) {
                    ForEach(1...10, id: \.self) { n in
                        Button { change { await shiki.setScore(score == n ? 0 : n, for: item, watched: watched) } } label: {
                            Image(systemName: n <= score ? "star.fill" : "star").font(.system(size: 19)).foregroundStyle(n <= score ? Color.yellow : Night.muted)
                                .frame(maxWidth: .infinity, minHeight: 34).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Оценка \(n)")
                    }
                }
                if !shiki.message.isEmpty { Text(shiki.message).font(.system(size: 12)).foregroundStyle(Night.fresh) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10).background(Night.raised, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Night.stroke))
            .disabled(busy)
        } else if item.malId > 0 {
            // Без входа — приглашение: оценки и статусы будут уходить на Шикимори.
            Button { connect = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "star.bubble").font(.system(size: 15))
                    Text("Оценить и отмечать просмотренное на Шикимори").font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                }.foregroundStyle(Night.text).padding(.horizontal, 14).padding(.vertical, 12)
                .background(Night.raised, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Night.stroke))
            }.buttonStyle(.plain)
            .sheet(isPresented: $connect) { ShikiConnectView() }
        }
    }
    @State var connect = false
    func change(_ work: @escaping () async -> Void) { busy = true; Task { await work(); busy = false } }
}

struct ShikiListView: View {
    @ObservedObject var shiki = ShikiAccount.shared
    @State var filter = "all"
    var body: some View {
        let all = shiki.list
        let shown = filter == "all" ? all : all.filter { $0.status == filter }
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { filter = "all" } label: { Chip(title: "Все · \(all.count)", selected: filter == "all") }.buttonStyle(.plain)
                    ForEach(ShikiRate.statuses, id: \.0) { s in
                        let n = all.filter { $0.status == s.0 }.count
                        if n > 0 { Button { filter = s.0 } label: { Chip(title: "\(s.1) · \(n)", selected: filter == s.0) }.buttonStyle(.plain) }
                    }
                }.padding(.horizontal, 18)
            }
            if shiki.loading && all.isEmpty { ProgressView().frame(maxWidth: .infinity).padding() }
            if !shiki.message.isEmpty { Text(shiki.message).font(.system(size: 13)).foregroundStyle(Night.fresh).padding(.horizontal, 18) }
            if !shiki.loading && all.isEmpty { EmptyState(icon: "star", title: "Список на Шикимори пуст", text: "Поставьте оценку на странице аниме или досмотрите серию — оно появится здесь") }
            LazyVStack(spacing: 10) {
                ForEach(shown) { r in
                    NavigationLink { ShikiOpenView(rate: r) } label: {
                        HStack(spacing: 12) {
                            CachedPoster(url: r.poster, fill: true).frame(width: 52, height: 78).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(r.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Night.text).lineLimit(2).multilineTextAlignment(.leading)
                                Text(ShikiRate.statusTitle(r.status) + (r.episodes > 0 ? " · \(r.episodes)" + (r.total > 0 ? " из \(r.total)" : "") + " сер." : "")).font(.system(size: 13)).foregroundStyle(Night.muted)
                                if r.siteScore > 0 { ScoreChip.score(r.siteScore, "Shiki") }
                            }
                            Spacer(minLength: 0)
                            if r.score > 0 {
                                VStack(spacing: 0) { Text("\(r.score)").font(.system(size: 20, weight: .bold)).foregroundStyle(Color.yellow); Text("моя").font(.system(size: 10)).foregroundStyle(Night.muted) }
                            }
                        }.padding(10).background(Night.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 18)
        }
        .task { if shiki.list.isEmpty || !shiki.loading { await shiki.refresh() } }
    }
}

// Запись со Шикимори → тот же тайтл на Anime 365 (по id MyAnimeList).
struct ShikiOpenView: View {
    let rate: ShikiRate
    @EnvironmentObject var store: AnimeStore
    @State var item: AnimeItem?
    @State var failed = false
    var body: some View {
        Group {
            if let item { TitleView(item: item) }
            else if failed {
                VStack(spacing: 14) {
                    EmptyState(icon: "questionmark.folder", title: "Нет на Anime 365", text: "«\(rate.title)» не нашлось в каталоге")
                    if let u = URL(string: Shikimori.site + "/animes/\(rate.malId)") { Link("Открыть на Шикимори", destination: u).buttonStyle(PillStyle()) }
                }
            } else { ProgressView() }
        }
        .task {
            guard item == nil else { return }
            if let found = try? await store.shelf(["myAnimeListId": "\(rate.malId)"], limit: 1).first { item = found } else { failed = true }
        }
    }
}

// MARK: Расписание

struct ScheduleView: View {
    @EnvironmentObject var store: AnimeStore
    @State var days: [(weekday: Int, items: [(AnimeItem, Episode)])] = []
    @State var message = ""
    var body: some View {
        List {
            if days.isEmpty && message.isEmpty { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
            if !message.isEmpty { Text(message).foregroundStyle(Night.muted).listRowBackground(Color.clear) }
            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                Section {
                    ForEach(day.items, id: \.0.id) { item, ep in
                        NavigationLink(value: Route.title(item)) {
                            HStack(spacing: 12) {
                                CachedPoster(url: item.posterSmall, fill: true).frame(width: 46, height: 69).clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Night.text).lineLimit(2)
                                    Text("\(ep.title) · \(ep.uploaded.map { Self.day.string(from: $0) } ?? "")").font(.system(size: 13)).foregroundStyle(store.hasNew(item) ? Night.fresh : Night.muted)
                                }
                                Spacer(minLength: 0)
                                ScoreChip(item: item)
                            }
                        }.listRowBackground(Night.surface.opacity(0.6))
                    }
                } header: { Text(title(day.weekday, i)).font(.system(size: 15, weight: .bold)).foregroundStyle(Night.text).textCase(nil) }
            }
            Text("Дни посчитаны по выходу последних серий на Anime 365 — перевод может появиться чуть позже.").font(.system(size: 12)).foregroundStyle(Night.muted).listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Расписание").toolbarTitleDisplayMode(.inline)
        .task { do { days = try await store.schedule() } catch { message = error.localizedDescription } }
    }
    static let day: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM, HH:mm"; return f }()
    func title(_ weekday: Int, _ index: Int) -> String {
        let name = Calendar(identifier: .gregorian).standaloneWeekdaySymbols(ru: true)[weekday - 1]
        return index == 0 && weekday == Calendar.current.component(.weekday, from: Date()) ? "Сегодня · \(name)" : name.capitalized
    }
}
extension Calendar { func standaloneWeekdaySymbols(ru: Bool) -> [String] { var c = self; c.locale = Locale(identifier: "ru_RU"); return c.standaloneWeekdaySymbols } }

// MARK: Загрузки

struct DownloadsView: View {
    @EnvironmentObject var store: AnimeStore
    @EnvironmentObject var downloads: DownloadCenter
    @State var playback: Playback?
    // Следующая серия открывается только после того, как экран прошлой полностью закрылся:
    // раньше скачанная серия стартовала поверх ещё закрывающегося плеера, и он зависал.
    @State var upNext: (() -> Void)?
    var groups: [(AnimeItem, [DownloadItem])] {
        Dictionary(grouping: downloads.items, by: \.seriesId).values.map { ($0[0].item, $0.sorted { $0.episodeNumber < $1.episodeNumber }) }.sorted { $0.1.map(\.created).max()! > $1.1.map(\.created).max()! }
    }
    var body: some View {
        List {
            if !downloads.missing.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("В аккаунте Yoru есть загрузки, которых нет на этом устройстве: \(downloads.missing.count) \(plural(downloads.missing.count)).").font(.system(size: 14)).foregroundStyle(Night.text)
                    HStack {
                        Button("Восстановить загрузки (\(downloads.missing.count))") { downloads.restore(store: store) }.buttonStyle(PillStyle(primary: true))
                        Button("Скрыть") { downloads.hideMissing() }.buttonStyle(PillStyle())
                    }
                }.padding(.vertical, 6).listRowBackground(Night.surface.opacity(0.6))
            }
            let running = downloads.items.filter { $0.state == .running }.count
            if running > 0 {
                HStack(spacing: 10) {
                    ProgressView().tint(Night.progress)
                    Text("Качается: \(running) \(plural(running))").font(.system(size: 14, weight: .semibold)).foregroundStyle(Night.text)
                    Spacer()
                    if downloads.totalRate > 1024 { Text(DownloadCenter.speed(downloads.totalRate)).font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(Night.progress) }
                }.listRowBackground(Night.surface.opacity(0.6))
            }
            if downloads.items.isEmpty && downloads.missing.isEmpty {
                VStack(spacing: 14) {
                    EmptyState(icon: "arrow.down.circle", title: "Здесь будут ваши загрузки", text: "Нажмите ↓ рядом с серией, чтобы смотреть её без интернета — в дороге, в самолёте, где угодно")
                    Button("Найти, что скачать") { store.tab = 0 }.buttonStyle(PillStyle(primary: true))
                }.frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.0.id) { item, list in
                Section {
                    ForEach(list) { d in
                        Button { play(d, in: list) } label: { DownloadRow(d: d) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) { Button(role: .destructive) { downloads.remove(d.id) } label: { Label("Удалить", systemImage: "trash") }.tint(.red) }
                            .contextMenu { if d.state == .failed { Button("Повторить", systemImage: "arrow.clockwise") { downloads.retry(d.id, store: store) } }; Button("Удалить", systemImage: "trash", role: .destructive) { downloads.remove(d.id) } }
                            .listRowBackground(Night.surface.opacity(0.6))
                    }
                } header: {
                    NavigationLink(value: Route.title(item)) {
                        HStack(spacing: 10) {
                            CachedPoster(url: item.posterSmall, fill: true).frame(width: 34, height: 51).clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Night.text).lineLimit(1)
                                Text("\(list.count) \(plural(list.count)) · \(DownloadCenter.size(list.reduce(0) { $0 + max($1.total, $1.bytes) }))").font(.system(size: 12)).foregroundStyle(Night.muted)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Night.muted)
                        }
                    }.textCase(nil)
                }
            }
            Section {
                Picker("Качество", selection: $downloads.quality) { Text("Наилучшее").tag(DownloadCenter.best); Text("1080p").tag(1080); Text("720p").tag(720); Text("480p").tag(480) }
                Toggle("Только по Wi‑Fi", isOn: $downloads.wifiOnly)
                Toggle("Удалять просмотренные", isOn: $downloads.autoDelete)
            } header: { Text("Настройки загрузок").textCase(nil) } footer: {
                Text("Занято \(DownloadCenter.size(downloads.usedBytes)) · свободно \(DownloadCenter.size(downloads.freeBytes)). Серии хранятся внутри приложения и удаляются вместе с ним.")
            }.listRowBackground(Night.surface.opacity(0.6))
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Загрузки").toolbarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playback, onDismiss: runUpNext) { value in NativePlayerView(playback: value) { done, next in finished(value, done: done, next: next) }.ignoresSafeArea() }
        .onAppear {
            #if DEBUG
            if QA.has("--play-download"), let d = downloads.items.first(where: { $0.state == .done }) { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { play(d, in: [d]) } }
            #endif
        }
    }
    func plural(_ n: Int) -> String { n % 10 == 1 && n % 100 != 11 ? "серия" : (2...4).contains(n % 10) && !(12...14).contains(n % 100) ? "серии" : "серий" }
    func play(_ d: DownloadItem, in list: [DownloadItem]) {
        guard d.state == .done else { if d.state == .failed { downloads.retry(d.id, store: store) }; return }
        let next = list.first { $0.episodeNumber > d.episodeNumber && $0.state == .done }
        playback = downloads.playback(d, hasNext: next != nil, store: store)
    }
    func runUpNext() { guard let f = upNext else { return }; upNext = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: f) }
    func finished(_ value: Playback, done: Bool, next: Bool) {
        // Серию запоминаем до «Удалять просмотренные»: после удаления её уже не найти в списке.
        let current = downloads.items.first(where: { $0.id == value.episodeId })
        if done { store.markDone(value.episodeId); downloads.watched(value.episodeId)
            if let d = current { let item = d.item, n = Int(d.episodeNumber); Task { await ShikiAccount.shared.episodeDone(item, number: n) } } }
        Task { await store.sync() }
        guard next, let current else { return }
        let list = downloads.items.filter { $0.seriesId == current.seriesId && $0.state == .done }.sorted { $0.episodeNumber < $1.episodeNumber }
        if let n = list.first(where: { $0.episodeNumber > current.episodeNumber }) { upNext = { playback = downloads.playback(n, hasNext: list.contains { $0.episodeNumber > n.episodeNumber }, store: store) } }
    }
}
struct DownloadRow: View {
    @EnvironmentObject var store: AnimeStore
    @EnvironmentObject var downloads: DownloadCenter
    let d: DownloadItem
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Night.raised).frame(width: 40, height: 40)
                switch d.state {
                case .done: Image(systemName: "play.fill").foregroundStyle(Night.text)
                case .failed: Image(systemName: "arrow.clockwise").foregroundStyle(Night.danger)
                default: ProgressRing(value: d.progress).frame(width: 26, height: 26)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(d.episodeTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(Night.text)
                Text(status).font(.system(size: 12)).foregroundStyle(d.state == .failed ? Night.danger : Night.muted).lineLimit(1)
                if d.state == .done, store.fraction(d.id) > 0, store.fraction(d.id) < 1 { ProgressLine(value: store.fraction(d.id)).frame(maxWidth: 160) }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 2)
    }
    var status: String {
        switch d.state {
        case .done: return "\(DownloadCenter.label(d.height)) · \(DownloadCenter.size(d.total)) · \(d.translationTitle)"
        case .failed: return (d.error ?? "Ошибка") + " · нажмите, чтобы повторить"
        default:
            guard d.total > 0 else { return d.state == .queued ? (d.error ?? "В очереди") : "Подготовка…" }
            let rate = downloads.rate(d.id)
            return "\(Int(d.progress * 100))% · \(DownloadCenter.size(d.bytes)) из \(DownloadCenter.size(d.total))" + (rate > 1024 ? " · \(DownloadCenter.speed(rate))" : "")
        }
    }
}
struct ProgressRing: View {
    let value: Double
    var body: some View { ZStack { Circle().stroke(Color.white.opacity(0.2), lineWidth: 3); Circle().trim(from: 0, to: max(0.03, value)).stroke(Night.progress, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90)) } }
}

// MARK: Страница аниме

// Переход между сезонами меняет тайтл на месте, а «Назад» ведёт туда, откуда пришли — как на сайте Anime 365.
struct TitleView: View {
    @State var item: AnimeItem
    var autoResume = false
    var body: some View { DetailView(item: item, autoResume: autoResume) { item = $0 }.id(item.id) }
}
struct DetailView: View {
    let item: AnimeItem
    var autoResume = false
    var switchSeason: (AnimeItem) -> Void = { _ in }
    @State var seasons: [Season] = []
    @EnvironmentObject var store: AnimeStore
    @EnvironmentObject var downloads: DownloadCenter
    @State var full: AnimeItem?
    @State var episodes: [Episode] = []
    @State var chooser: Chooser?
    @State var translations: [Translation] = []
    @State var playback: Playback?
    // Следующая серия открывается только после того, как экран прошлой полностью закрылся:
    // раньше скачанная серия стартовала поверх ещё закрывающегося плеера, и он зависал.
    @State var upNext: (() -> Void)?
    @State var busy = true
    @State var status = ""
    @State var login = false
    @State var expanded = false
    @State var started = false
    @State var working = false
    @State var uhd = false
    // Серия, для которой сейчас грузятся переводы или видео: на ней и на главной кнопке — спиннер вместо ▶︎.
    @State var pending: Int?
    @ObservedObject var shiki = Shikimori.shared
    struct Chooser: Identifiable { let episode: Episode; var download = false; var all = false; var id: String { "\(episode.id)-\(download)-\(all)" } }
    var shown: AnimeItem { full ?? item }
    // Описание с Шикимори (короче и без спойлеров на пол-экрана), пока его нет — с Anime 365.
    var summary: String { shiki.text(shown) ?? shown.summary }
    var favorite: Bool { store.favorites.contains(item) }
    var resume: Episode? { store.resumeEpisode(item, in: episodes) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actions.padding(.horizontal, 18)
                shikiLink.padding(.horizontal, 18)
                ShikiRateRow(item: shown, watched: episodes.filter { store.isDone($0.id) }.count).padding(.horizontal, 18)
                if !status.isEmpty { Text(status).font(.system(size: 13)).foregroundStyle(Night.muted).padding(.horizontal, 18) }
                if !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(summary).font(.system(size: 14)).foregroundStyle(Night.text.opacity(0.9)).lineLimit(expanded ? nil : 3)
                        Button(expanded ? "Свернуть" : "Ещё") { withAnimation { expanded.toggle() } }.font(.system(size: 14, weight: .semibold)).foregroundStyle(Night.muted)
                    }.padding(.horizontal, 18)
                }
                if !shown.genres.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { ForEach(shown.genres) { g in NavigationLink(value: Route.shelf(Shelves.genre(g.id, g.title))) { Chip(title: g.title) }.buttonStyle(.plain) } }.padding(.horizontal, 18) }
                }
                if !seasons.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Сезоны").font(.system(size: 19, weight: .bold)).foregroundStyle(Night.text).padding(.horizontal, 18)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) { ForEach(seasons) { s in Button { if !s.current { switchSeason(s.item) } } label: { Chip(title: s.label, selected: s.current) }.buttonStyle(.plain).accessibilityLabel(s.item.title) } }.padding(.horizontal, 18)
                        }
                    }
                }
                episodeList
                if let g = shown.genres.first { RemoteShelf(shelf: Shelf(title: "Похожие", params: ["genres": shown.genres.prefix(2).map { "\($0.id)" }.joined(separator: ",")]), exclude: item.id).id(g.id) }
            }.padding(.bottom, 24)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { if episodes.isEmpty { await load() } }
        .task { seasons = await store.seasons(item) }
        .task(id: shown.malId) { shiki.want(shown); await shiki.loadText(shown) }
        .sheet(item: $chooser) { c in
            TranslationSheet(episode: c.episode, translations: $translations, remembered: store.rememberedTranslation(item), needsLogin: store.token.isEmpty, status: $status, download: c.download, all: c.all, quality: downloads.quality) { t in
                Task { if c.download { await download(t, c.episode, all: c.all) } else { await play(t, c.episode) } }
            } login: { login = true } close: { chooser = nil }
            .sheet(isPresented: $login) { LoginView() }
        }
        .sheet(isPresented: $login) { LoginView() }
        .fullScreenCover(item: $playback, onDismiss: runUpNext) { value in NativePlayerView(playback: value) { done, wantsNext in finished(value, done: done, next: wantsNext) }.ignoresSafeArea() }
        .overlay(alignment: .bottom) {
            if working && !status.isEmpty && chooser == nil {
                HStack(spacing: 10) { ProgressView().tint(Night.text); Text(status).font(.system(size: 14, weight: .semibold)).foregroundStyle(Night.text).lineLimit(2) }
                    .padding(.horizontal, 16).padding(.vertical, 12).background(Night.raised.opacity(0.96), in: Capsule()).overlay(Capsule().stroke(Night.stroke))
                    .padding(.bottom, 14).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: working)
    }
    var header: some View {
        ZStack(alignment: .bottomLeading) {
            BlurredBackdrop(url: shown.posterSmall, radius: 24).frame(height: 330).frame(maxWidth: .infinity).opacity(0.6)
            LinearGradient(colors: [Night.bg.opacity(0.2), Night.bg.opacity(0.7), Night.bg], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 16) {
                CachedPoster(url: shown.poster, fill: true).frame(width: Metrics.regular ? 170 : 124, height: Metrics.regular ? 255 : 186).clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Night.stroke)).shadow(color: .black.opacity(0.45), radius: 14, y: 8)
                VStack(alignment: .leading, spacing: 7) {
                    Text(shown.title).font(.system(size: Metrics.regular ? 30 : 22, weight: .heavy)).foregroundStyle(Night.text).lineLimit(4).minimumScaleFactor(0.8)
                    HStack(spacing: 8) {
                        if shown.score > 0 { ScoreBox(label: "Anime 365", value: shown.score) }
                        if let s = shiki.score(shown), s > 0 { ScoreBox(label: "Shikimori", value: s) }
                        if uhd { UHDBadge() }
                    }
                    Text([shown.kind, shown.year > 0 ? "\(shown.year)" : ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(Night.muted)
                    if !shown.season.isEmpty || !episodes.isEmpty { Text([shown.season, episodes.isEmpty ? "" : "\(Episode.regular(episodes).count) эп."].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(Night.muted) }
                }
            }.padding(.horizontal, 18)
        }.frame(height: 330)
    }
    // Страница на Шикимори: оценка, отзывы, похожие. Открывается в Safari.
    @ViewBuilder var shikiLink: some View {
        if let url = Shikimori.url(shown) {
            Link(destination: url) {
                HStack(spacing: 8) {
                    Text("Открыть на Шикимори").foregroundStyle(Night.text)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right").foregroundStyle(Night.muted)
                }.font(.system(size: 14, weight: .semibold)).padding(.horizontal, 14).frame(height: 40).background(Night.raised, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Night.stroke))
            }.accessibilityLabel("Открыть на Шикимори")
        }
    }
    // Есть ли 4K: смотрим переводы последней вышедшей серии (новые обычно выходят в лучшем качестве). Ответ кэшируется на сутки.
    func checkUHD() async {
        let key = "uhd-\(item.id)", d = UserDefaults.standard
        if UHD.shared.has(item) { uhd = true }
        if let v = d.array(forKey: key) as? [Double], v.count == 2, Date().timeIntervalSince1970 - v[1] < 86400 { uhd = v[0] > 0 || uhd; if uhd { UHD.shared.set(item.id, true) }; return }
        let reg = Episode.regular(episodes)
        guard let e = episodes.last(where: { reg.contains($0.id) }) ?? episodes.last, let t = try? await store.translations(e, for: item) else { return }
        uhd = t.contains { $0.height >= 2160 } || UHD.shared.has(item)
        d.set([uhd ? 1 : 0, Date().timeIntervalSince1970], forKey: key)
        UHD.shared.set(item.id, uhd)
    }
    var actions: some View {
        VStack(spacing: 10) {
            Button { if let e = resume { start(e) } } label: {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        if pending != nil && pending == resume?.id { ProgressView().tint(Night.onAccent) } else { Image(systemName: "play.fill") }
                        Text(primaryTitle)
                    }.frame(maxWidth: .infinity)
                    if let e = resume, store.fraction(e.id) > 0, store.fraction(e.id) < 1 { ProgressLine(value: store.fraction(e.id)).padding(.horizontal, 30) }
                }
            }.buttonStyle(PillStyle(primary: true)).disabled(resume == nil)
            if let label = rememberedLabel {
                Button { if let e = resume ?? episodes.first { choose(e, pick: true) } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "captions.bubble").foregroundStyle(Night.muted)
                        Text(label).foregroundStyle(Night.text).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("Сменить").foregroundStyle(Night.progress)
                    }.font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity)
                }.buttonStyle(PillStyle()).disabled(episodes.isEmpty).accessibilityLabel("Перевод: \(label). Сменить")
            }
            HStack(spacing: 10) {
                Button { store.favorite(item) } label: { Label(favorite ? "В списке" : "Мой список", systemImage: favorite ? "checkmark" : "plus").frame(maxWidth: .infinity) }.buttonStyle(PillStyle())
                Button { downloadAll() } label: { Label(downloadedCount > 0 ? "Скачано \(downloadedCount)" : "Скачать все", systemImage: downloadedCount == episodes.count && !episodes.isEmpty ? "checkmark.circle" : "arrow.down.circle").frame(maxWidth: .infinity) }
                    .buttonStyle(PillStyle()).disabled(episodes.isEmpty)
            }
        }
    }
    // Перевод, выбранный для этого аниме раньше: дальше серии включаются с ним сразу, без листа выбора.
    var rememberedLabel: String? {
        let parts = store.rememberedTranslation(item).split(separator: "|", maxSplits: 1).map(String.init)
        guard let kind = parts.first, !kind.isEmpty else { return nil }
        let group = Translation.groups[kind] ?? (kind.hasPrefix("sub") ? "Субтитры" : kind.hasPrefix("voice") ? "Озвучка" : "Оригинал")
        let authors = (parts.count > 1 ? parts[1] : "").trimmingCharacters(in: CharacterSet(charactersIn: " -–"))
        return authors.isEmpty || authors == "Original" ? group : "\(group) · \(authors)"
    }
    var downloadedCount: Int { episodes.filter { downloads.item($0.id) != nil }.count }
    var primaryTitle: String {
        guard let e = resume else { return busy ? "Загрузка серий…" : "Нет серий" }
        let last = store.lastEpisode(item); if last == 0 || (last != e.id && !store.isDone(last)) { return "Смотреть · \(e.title)" }
        return store.isDone(e.id) ? "Пересмотреть · \(e.title)" : "Продолжить · \(e.title)"
    }
    var episodeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            let regular = Episode.regular(episodes)
            Text(regular.isEmpty ? "Серии" : "Серии · \(regular.count)").font(.system(size: 19, weight: .bold)).foregroundStyle(Night.text)
            if busy && episodes.isEmpty { ProgressView().frame(maxWidth: .infinity).padding() }
            if !busy && episodes.isEmpty { Button("Повторить") { Task { await load() } }.buttonStyle(PillStyle()) }
            // Трейлеры и спецвыпуски — отдельным блоком после серий.
            LazyVStack(alignment: .leading, spacing: 6) { ForEach(episodes) { ep in
                if !regular.isEmpty, !regular.contains(ep.id), ep.id == episodes.first(where: { !regular.contains($0.id) })?.id { Text("Трейлеры и спецвыпуски").font(.system(size: 17, weight: .bold)).foregroundStyle(Night.text).padding(.top, 10) }
                EpisodeRow(ep: ep, current: ep.id == resume?.id && store.lastEpisode(item) != 0, loading: pending == ep.id, open: { start(ep) }, download: { downloadTapped(ep) }, pick: { choose(ep, pick: true) }) } }
        }.padding(.horizontal, 18)
    }
    func next(after id: Int) -> Episode? { guard let i = episodes.firstIndex(where: { $0.id == id }), i + 1 < episodes.count else { return nil }; return episodes[i + 1] }
    func load() async {
        busy = true
        do {
            let (detailed, list) = try await store.details(item); full = detailed; episodes = list; store.seen(item, count: list.count)
            markAlmostWatched(list)
            status = list.isEmpty ? "На сайте пока нет серий этого аниме" : ""
        } catch { status = error.localizedDescription }
        busy = false
        Task { await checkUHD() }
        #if DEBUG
        if QA.has("--demo-progress"), episodes.count > 2 { store.markDone(episodes[0].id); UserDefaults.standard.set(episodes[1].id, forKey: "last-\(item.id)"); UserDefaults.standard.set(0.4, forKey: "watch-\(episodes[1].id)") }
        if QA.has("--choose-first"), let first = episodes.first { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { start(first) } }
        if QA.has("--download-first"), let first = episodes.first { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { downloadTapped(first) } }
        #endif
        if autoResume && !started, let e = resume { started = true; start(e, auto: true) }
    }
    // Серия скачана — играем файл сразу, как Netflix; иначе выбираем перевод.
    func start(_ ep: Episode, auto: Bool = false) {
        if let d = downloads.item(ep.id), d.state == .done { playback = downloads.playback(d, hasNext: next(after: ep.id) != nil, store: store); return }
        choose(ep, auto: auto)
    }
    // Перевод уже выбирали для этого аниме — серия включается (или скачивается) с ним сразу. Лист выбора — только
    // в первый раз, когда у серии нет этого перевода, или по кнопке «Сменить» / долгому нажатию на серию.
    func choose(_ ep: Episode, auto: Bool = false, download: Bool = false, all: Bool = false, pick: Bool = false) {
        let remembered = store.rememberedTranslation(item)
        let direct = !pick && (auto || !remembered.isEmpty)
        Task {
            pending = ep.id; defer { pending = nil }
            translations = []; status = direct ? "\(ep.title) — загрузка переводов…" : ""; working = direct
            if !direct { chooser = Chooser(episode: ep, download: download, all: all) }
            do {
                translations = try await store.translations(ep, for: item)
                status = translations.isEmpty ? "Нет доступных переводов" : ""
                if direct, !remembered.isEmpty, let t = translations.first(where: { $0.signature == remembered }) {
                    if download { await self.download(t, ep, all: all) } else { await play(t, ep) }
                } else if direct { working = false; chooser = Chooser(episode: ep, download: download, all: all) }
            } catch { status = error.localizedDescription }
            working = false
        }
    }
    func play(_ t: Translation, _ ep: Episode) async {
        guard !store.token.isEmpty else { login = true; return }
        status = "Подготовка видео и субтитров…"; working = true; pending = ep.id
        defer { working = false; pending = nil }
        do {
            var value = try await store.playback(t, ep, item); value.hasNext = next(after: ep.id) != nil
            status = ""
            if chooser != nil { chooser = nil; try? await Task.sleep(for: .milliseconds(400)) }
            playback = value
        } catch { status = error.localizedDescription }
    }
    // Серии, досмотренные до титров по старому правилу (≥ 90%), но не засчитанные, — засчитываем.
    func markAlmostWatched(_ list: [Episode]) {
        let almost = list.filter { !store.isDone($0.id) && UserDefaults.standard.double(forKey: "watch-\($0.id)") >= 0.9 }
        for e in almost { store.markDone(e.id) }
        if let top = almost.map({ Int($0.number) }).max() { let it = shown; Task { await ShikiAccount.shared.episodeDone(it, number: top); await store.sync() } }
    }
    func finished(_ value: Playback, done: Bool, next wantsNext: Bool) {
        if done { store.markDone(value.episodeId); downloads.watched(value.episodeId)
            if let ep = episodes.first(where: { $0.id == value.episodeId }) { let item = shown; Task { await ShikiAccount.shared.episodeDone(item, number: Int(ep.number)) } } }
        Task { await store.sync() }
        guard wantsNext, let ep = next(after: value.episodeId) else { return }
        upNext = { start(ep, auto: true) }
    }
    func runUpNext() { guard let f = upNext else { return }; upNext = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: f) }
    // MARK: Загрузки
    func downloadTapped(_ ep: Episode) {
        if let d = downloads.item(ep.id) { if d.state == .failed { downloads.retry(ep.id, store: store) }; return }
        choose(ep, download: true)
    }
    func downloadAll() {
        guard let first = episodes.first(where: { downloads.item($0.id) == nil }) else { return }
        choose(first, download: true, all: true)
    }
    func download(_ t: Translation, _ ep: Episode, all: Bool) async {
        var needsLogin = store.token.isEmpty
        #if DEBUG
        if QA.value("--qa-download-url") != nil { needsLogin = false }
        #endif
        guard !needsLogin else { login = true; return }
        chooser = nil; working = true; pending = ep.id
        defer { working = false; pending = nil }
        do {
            status = "Ставлю в очередь: \(ep.title)…"
            try await downloads.enqueue(t, ep, item, store: store)
            if all {
                // Остальные серии — тем же переводом (у каждой серии свои id переводов, совпадают команда и тип).
                let rest = episodes.filter { downloads.item($0.id) == nil }
                for (n, e) in rest.enumerated() {
                    status = "Ставлю в очередь: \(n + 1) из \(rest.count)…"
                    guard let list = try? await store.translations(e, for: item), let match = list.first(where: { $0.signature == t.signature }) ?? list.first(where: { $0.kind == t.kind }) else { continue }
                    try? await downloads.enqueue(match, e, item, store: store)
                }
            }
            status = "Загрузка идёт — следите во вкладке «Загрузки»"
        } catch { status = error.localizedDescription }
    }
}
struct EpisodeRow: View {
    @EnvironmentObject var store: AnimeStore
    @EnvironmentObject var downloads: DownloadCenter
    let ep: Episode
    let current: Bool
    var loading = false
    let open: () -> Void
    let download: () -> Void
    var pick: (() -> Void)? = nil
    var body: some View {
        let done = store.isDone(ep.id), f = store.fraction(ep.id), d = downloads.item(ep.id)
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(current ? Night.accent : Night.raised).frame(width: 44, height: 44)
                        if loading { ProgressView().tint(current ? Night.onAccent : Night.text) }
                        else if done && !current { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Night.muted) }
                        else { Image(systemName: "play.fill").font(.system(size: 14)).foregroundStyle(current ? Night.onAccent : Night.text) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ep.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(done && !current ? Night.muted : Night.text).lineLimit(1)
                        Text(caption(done: done, d: d)).font(.system(size: 12)).foregroundStyle(current ? Night.progress : Night.muted).lineLimit(1)
                        if f > 0 && f < 1 { ProgressLine(value: f).frame(maxWidth: 180) }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            .contextMenu { if let pick { Button("Выбрать перевод", systemImage: "captions.bubble", action: pick) } }
            Button(action: download) {
                Group {
                    switch d?.state {
                    case .done?: Image(systemName: "checkmark.circle.fill").foregroundStyle(Night.progress)
                    case .failed?: Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(Night.danger)
                    case .running?, .queued?: ProgressRing(value: d?.progress ?? 0).frame(width: 22, height: 22)
                    case nil: Image(systemName: "arrow.down.circle").foregroundStyle(Night.text)
                    }
                }.font(.system(size: 22)).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(d == nil ? "Скачать \(ep.title)" : d?.state == .done ? "Скачано" : "Загрузка")
            .contextMenu { if d != nil { Button("Удалить загрузку", systemImage: "trash", role: .destructive) { downloads.remove(ep.id) } } }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(current ? Night.surface : Night.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(current ? Night.accent.opacity(0.35) : Night.stroke))
    }
    func caption(done: Bool, d: DownloadItem?) -> String {
        var parts: [String] = []
        if current { parts.append("Продолжить") } else if done { parts.append("Просмотрено") }
        if let date = ep.uploaded { parts.append(EpisodeRow.date.string(from: date)) }
        if d?.state == .done { parts.append("на устройстве") }
        return parts.joined(separator: " · ")
    }
    static let date: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMM yyyy"; return f }()
}
struct TranslationSheet: View {
    let episode: Episode; @Binding var translations: [Translation]; let remembered: String; let needsLogin: Bool; @Binding var status: String
    var download = false; var all = false; var quality = 720
    @State var showOthers = false
    @State var picked: Int?
    let pick: (Translation) -> Void; let login: () -> Void; let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(download ? (all ? "Скачать все серии" : "Скачать · \(episode.title)") : episode.title).font(.system(size: 20, weight: .bold)).foregroundStyle(Night.text)
                    Text(download ? "Выберите перевод · " + (quality >= DownloadCenter.best ? "наилучшее качество" : "качество до \(quality)p") : "Выберите перевод").font(.system(size: 13)).foregroundStyle(Night.muted)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).frame(width: 36, height: 36).background(Night.raised, in: Circle()) }.foregroundStyle(Night.text).accessibilityLabel("Закрыть")
            }
            if needsLogin { Button("Войти в Anime 365", action: login).buttonStyle(PillStyle(primary: true)) }
            if translations.isEmpty { Text(status.isEmpty ? "Загрузка переводов…" : status).font(.system(size: 14)).foregroundStyle(Night.muted); ProgressView().frame(maxWidth: .infinity).padding() }
            else if picked != nil, !status.isEmpty { Text(status).font(.system(size: 13)).foregroundStyle(Night.muted).lineLimit(2) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(groups.filter { $0.1.first?.main ?? false || $0.1.contains { $0.signature == remembered } }, id: \.0) { title, list in section(title, list) }
                    let others = groups.filter { !($0.1.first?.main ?? false) && !$0.1.contains { $0.signature == remembered } }
                    if !others.isEmpty {
                        Button { withAnimation { showOthers.toggle() } } label: {
                            HStack { Text("Другие языки · \(others.reduce(0) { $0 + $1.1.count })"); Spacer(); Image(systemName: showOthers ? "chevron.up" : "chevron.down") }
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Night.muted).padding(.top, 10)
                        }.buttonStyle(.plain)
                        if showOthers { ForEach(others, id: \.0) { title, list in section(title, list) } }
                    }
                }
            }
        }.padding(18).background(NightBackground()).presentationDetents([.medium, .large])
        // Не получилось (ошибка сети, нет видео) — снимаем спиннер, можно выбрать другой перевод.
        .onChange(of: status) { _, v in if picked != nil, !v.isEmpty, !v.hasPrefix("Подготовка"), !v.hasPrefix("Ставлю") { picked = nil } }
        .task(id: translations.count) {
            #if DEBUG
            if QA.has("--pick-first"), let t = translations.first { pick(t) }
            #endif
        }
    }
    @ViewBuilder func section(_ title: String, _ list: [Translation]) -> some View {
        Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(Night.muted).padding(.top, 6)
        ForEach(list) { t in
            Button { guard picked == nil else { return }; picked = t.id; pick(t) } label: {
                HStack {
                    if picked == t.id { ProgressView().tint(Night.text) }
                    Text(t.name.isEmpty ? (t.kind == "raw" ? "Японская дорожка без перевода" : "Без названия") : t.name).multilineTextAlignment(.leading).lineLimit(2)
                    Spacer()
                    if t.bd { Text("BD").font(.system(size: 11, weight: .heavy)).foregroundStyle(Night.onAccent).padding(.horizontal, 5).padding(.vertical, 2).background(Night.progress, in: RoundedRectangle(cornerRadius: 4)).accessibilityLabel("Blu-ray") }
                    if t.height >= 2160 { Text("4K").font(.system(size: 11, weight: .heavy)).padding(.horizontal, 5).padding(.vertical, 2).overlay(RoundedRectangle(cornerRadius: 4).stroke(Night.muted)) }
                    if picked == nil, t.signature == remembered { Image(systemName: "star.fill").foregroundStyle(Night.fresh).accessibilityLabel("Вы смотрели с этим переводом") }
                }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(PillStyle())
        }
    }
    var groups: [(String, [Translation])] {
        // Порядок разделов — как в списке после очистки: запомненный перевод, русские субтитры, озвучка, оригинал, остальное.
        var order: [String] = []; for t in translations where !order.contains(t.group) { order.append(t.group) }
        let g = Dictionary(grouping: translations, by: \.group)
        var out = order.compactMap { k in g[k].map { (k, $0) } }
        if let i = out.firstIndex(where: { $0.1.contains { $0.signature == remembered } }), i > 0 { out.insert(out.remove(at: i), at: 0) }
        return out
    }
}
