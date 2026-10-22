import SwiftUI
import UIKit

// MARK: Навигация

struct Shelf: Hashable { let title: String; let params: [String: String] }
enum Route: Hashable { case title(AnimeItem, resume: Bool = false), shelf(Shelf), schedule }

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
    var body: some View {
        TabView(selection: $store.tab) {
            NavigationStack(path: $store.homePath) { HomeView().routes() }.tabItem { Label("Главная", systemImage: "house.fill") }.tag(0)
            NavigationStack { SearchView().routes() }.tabItem { Label("Поиск", systemImage: "magnifyingglass") }.tag(1)
            NavigationStack { LibraryView().routes() }.tabItem { Label("Моё", systemImage: "heart.fill") }.tag(2)
            NavigationStack { DownloadsView().routes() }.tabItem { Label("Загрузки", systemImage: "arrow.down.circle.fill") }.tag(3)
        }
        .task { await store.refreshAccount(); await store.sync(); await store.checkNewEpisodes(); if Updater.due { update = try? await Updater.check() } }
        // Новая версия на GitHub: iPhone не ставит IPA сам — открываем страницу релиза.
        .alert(update.map { "Доступна Yoru Anime \($0.version)" } ?? "", isPresented: Binding(get: { update != nil }, set: { if !$0 { update = nil } }), presenting: update) { r in
            Button("Скачать на GitHub") { openURL(r.page) }
            Button("Позже", role: .cancel) {}
        } message: { r in Text("Сейчас установлена \(Updater.current).\(r.notes.isEmpty ? "" : "\n\n" + String(r.notes.prefix(600)))") }
        .onChange(of: phase) { if phase == .active { Task { await store.sync() } } }
        .onAppear {
            #if DEBUG
            if let t = QA.value("--tab").flatMap(Int.init) { store.tab = t }
            if QA.has("--open-schedule") { store.homePath = [.schedule] }
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
            }
        }
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
struct ScoreChip: View {
    let item: AnimeItem
    var body: some View {
        if item.score > 0 {
            // Цвет оценки как у Кинопоиска: высокая — зелёная, средняя — нейтральная, низкая — красная.
            Text("★ " + item.scoreText).font(.system(size: 12, weight: .bold)).monospacedDigit()
                .foregroundStyle(item.score >= 8 ? Night.scoreHigh : item.score >= 6.5 ? Night.scoreMid : Night.scoreLow)
        }
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
                if downloads.items.contains(where: { $0.seriesId == item.id && $0.state == .done }) { Image(systemName: "arrow.down.circle.fill").font(.system(size: 17)).foregroundStyle(.white, Night.bg.opacity(0.7)).padding(6) }
            }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Night.stroke))
            Text(item.title).font(.system(size: 13, weight: .bold)).foregroundStyle(Night.text).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                if let caption { Text(caption).foregroundStyle(Night.muted) } else { ScoreChip(item: item); Text(item.year > 0 ? "\(item.year)" : item.kind).foregroundStyle(Night.muted) }
            }.font(.system(size: 12)).lineLimit(1)
        }
        .frame(width: width).contentShape(Rectangle())
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold)).lineLimit(1).padding(.horizontal, 16).frame(minHeight: 46)
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
    var continueItems: [AnimeItem] { store.history.filter { store.lastEpisode($0) != 0 && !store.finished($0) }.prefix(15).map { $0 } }
    var fresh: [AnimeItem] { store.favorites.filter { store.hasNew($0) } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                HStack {
                    Text("Yoru Anime").font(.system(size: 24, weight: .heavy)).foregroundStyle(Night.text)
                    Spacer()
                    Button { login = true } label: { Image(systemName: store.token.isEmpty ? "person.crop.circle.badge.plus" : "person.crop.circle.fill").font(.system(size: 26)).foregroundStyle(Night.text) }
                        .accessibilityLabel(store.token.isEmpty ? "Войти" : "Аккаунт")
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
        .onAppear {
            #if DEBUG
            if QA.has("--login") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { login = true } }
            #endif
        }
    }
}
// Большой баннер наверху главной: одно из лучших аниме, которые сейчас выходят.
struct Hero: View {
    @EnvironmentObject var store: AnimeStore
    var item: AnimeItem? { let a = store.shelves[Shelves.airing] ?? []; return a.isEmpty ? nil : a[min(store.heroPick, a.count - 1)] }
    var body: some View {
        if let item {
            let favorite = store.favorites.contains(item)
            ZStack(alignment: .bottom) {
                CachedPoster(url: item.posterSmall, fill: true).frame(height: 560).frame(maxWidth: .infinity).clipped().blur(radius: 26).opacity(0.55)
                    .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .top, endPoint: .bottom))
                LinearGradient(colors: [Night.bg.opacity(0), Night.bg.opacity(0.65), Night.bg], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 14) {
                    NavigationLink(value: Route.title(item)) {
                        CachedPoster(url: item.poster, fill: true).frame(width: Metrics.regular ? 210 : 196, height: Metrics.regular ? 315 : 294).clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Night.stroke)).shadow(color: .black.opacity(0.5), radius: 18, y: 10)
                    }.buttonStyle(.plain)
                    Text(item.title).font(.system(size: 22, weight: .heavy)).foregroundStyle(Night.text).multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 24)
                    HStack(spacing: 8) { ScoreChip(item: item); Text(([item.kind, item.year > 0 ? "\(item.year)" : ""] + item.genres.prefix(2).map(\.title)).filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(Night.muted) }
                        .font(.system(size: 13)).lineLimit(1).padding(.horizontal, 18)
                    HStack(spacing: 10) {
                        NavigationLink(value: Route.title(item)) { Label(store.lastEpisode(item) != 0 ? "Продолжить" : "Смотреть", systemImage: "play.fill").frame(minWidth: 130) }.buttonStyle(PillStyle(primary: true))
                        Button { store.favorite(item) } label: { Label(favorite ? "В списке" : "Мой список", systemImage: favorite ? "checkmark" : "plus").frame(minWidth: 130) }.buttonStyle(PillStyle())
                    }
                }.padding(.bottom, 6)
            }
            .frame(height: Metrics.regular ? 560 : 560)
        } else if store.shelfErrors[Shelves.airing] != nil {
            VStack(spacing: 12) {
                EmptyState(icon: "wifi.slash", title: "Нет связи с Anime 365", text: store.shelfErrors[Shelves.airing] ?? "")
                HStack(spacing: 10) {
                    Button("Повторить") { Task { store.shelfErrors[Shelves.airing] = nil; await store.loadShelf(Shelves.airing) } }.buttonStyle(PillStyle(primary: true))
                    Button("Мои загрузки") { store.tab = 3 }.buttonStyle(PillStyle())
                }
            }.frame(maxWidth: .infinity)
        } else {
            RoundedRectangle(cornerRadius: 16).fill(Night.surface).frame(width: 196, height: 294).frame(maxWidth: .infinity).frame(height: 420)
                .task { await store.loadShelf(Shelves.airing) }
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
    @FocusState var focused: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Night.muted)
                    TextField("", text: $query, prompt: Text("Название аниме").foregroundStyle(Night.muted)).font(.system(size: 17)).foregroundStyle(Night.text)
                        .submitLabel(.search).autocorrectionDisabled().focused($focused)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Night.muted) }.accessibilityLabel("Очистить") }
                }
                .padding(.horizontal, 14).frame(height: 50).background(Night.raised, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Night.stroke)).padding(.horizontal, 18)
                FlowLayout {
                    ForEach(Shelves.genres) { g in Button { genre = genre == g ? nil : g; focused = false } label: { Chip(title: g.title, selected: genre == g) }.buttonStyle(.plain) }
                }.padding(.horizontal, 18)
                Text(header).font(.system(size: 19, weight: .bold)).foregroundStyle(Night.text).padding(.horizontal, 18)
                if !message.isEmpty { Text(message).foregroundStyle(Night.muted).padding(.horizontal, 18); Button("Повторить") { Task { await load(reset: true) } }.buttonStyle(PillStyle()).padding(.horizontal, 18) }
                if items.isEmpty && !busy && message.isEmpty { EmptyState(icon: "sparkle.magnifyingglass", title: "Ничего не нашлось", text: "Попробуйте другое название или жанр") }
                PosterGrid(items: items) { Task { await load(reset: false) } }
                if busy { ProgressView().frame(maxWidth: .infinity).padding() }
            }.padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Поиск").toolbarTitleDisplayMode(.inline)
        .task(id: "\(query)|\(genre?.id ?? 0)") { do { try await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 350)); await load(reset: true) } catch {} }
    }
    var header: String { !query.isEmpty ? "Результаты" + (genre.map { " · " + $0.title } ?? "") : genre?.title ?? "Популярное сейчас" }
    var params: [String: String] { var p: [String: String] = [:]; if !query.isEmpty { p["query"] = query }; if let genre { p["genres"] = "\(genre.id)" }; if p.isEmpty { p["isAiring"] = "1" }; return p }
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
    @State var section = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Раздел", selection: $section) { Text("Мой список").tag(0); Text("История").tag(1) }.pickerStyle(.segmented).padding(.horizontal, 18)
                let items = section == 0 ? store.favorites : store.history
                if items.isEmpty {
                    EmptyState(icon: section == 0 ? "heart" : "clock", title: section == 0 ? "Список пуст" : "Вы ещё ничего не смотрели",
                               text: section == 0 ? "Нажмите «Мой список» на странице аниме — оно появится здесь и на телевизоре" : "Начатые серии появятся здесь и на полке «Продолжить просмотр»")
                } else { PosterGrid(items: items) }
            }.padding(.vertical, 12)
        }
        .navigationTitle("Моё").toolbarTitleDisplayMode(.inline)
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
    var groups: [(AnimeItem, [DownloadItem])] {
        Dictionary(grouping: downloads.items, by: \.seriesId).values.map { ($0[0].item, $0.sorted { $0.episodeNumber < $1.episodeNumber }) }.sorted { $0.1.map(\.created).max()! > $1.1.map(\.created).max()! }
    }
    var body: some View {
        List {
            if downloads.items.isEmpty {
                VStack(spacing: 14) {
                    EmptyState(icon: "arrow.down.circle", title: "Здесь будут ваши загрузки", text: "Нажмите ↓ рядом с серией, чтобы смотреть её без интернета — в дороге, в самолёте, где угодно")
                    Button("Найти, что скачать") { store.tab = 0 }.buttonStyle(PillStyle(primary: true))
                }.frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.0.id) { item, list in
                Section {
                    ForEach(list) { d in
                        Button { play(d, in: list) } label: { DownloadRow(d: d) }
                            .swipeActions { Button("Удалить", role: .destructive) { downloads.remove(d.id) } }
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
        .fullScreenCover(item: $playback) { value in NativePlayerView(playback: value) { done, next in finished(value, done: done, next: next) }.ignoresSafeArea() }
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
    func finished(_ value: Playback, done: Bool, next: Bool) {
        if done { store.markDone(value.episodeId); downloads.watched(value.episodeId) }
        Task { await store.sync() }
        guard next, let current = downloads.items.first(where: { $0.id == value.episodeId }) ?? downloads.items.first(where: { $0.seriesId == downloads.items.first?.seriesId }) else { return }
        let list = downloads.items.filter { $0.seriesId == current.seriesId && $0.state == .done }.sorted { $0.episodeNumber < $1.episodeNumber }
        if let n = list.first(where: { $0.episodeNumber > current.episodeNumber }) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { playback = downloads.playback(n, hasNext: list.contains { $0.episodeNumber > n.episodeNumber }, store: store) } }
    }
}
struct DownloadRow: View {
    @EnvironmentObject var store: AnimeStore
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
        default: return d.total > 0 ? "\(Int(d.progress * 100))% · \(DownloadCenter.size(d.bytes)) из \(DownloadCenter.size(d.total))" : "Подготовка…"
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
    @State var busy = true
    @State var status = ""
    @State var login = false
    @State var expanded = false
    @State var started = false
    struct Chooser: Identifiable { let episode: Episode; var download = false; var all = false; var id: String { "\(episode.id)-\(download)-\(all)" } }
    var shown: AnimeItem { full ?? item }
    var favorite: Bool { store.favorites.contains(item) }
    var resume: Episode? { store.resumeEpisode(item, in: episodes) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actions.padding(.horizontal, 18)
                if !status.isEmpty { Text(status).font(.system(size: 13)).foregroundStyle(Night.muted).padding(.horizontal, 18) }
                if !shown.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(shown.summary).font(.system(size: 14)).foregroundStyle(Night.text.opacity(0.9)).lineLimit(expanded ? nil : 3)
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
        .sheet(item: $chooser) { c in
            TranslationSheet(episode: c.episode, translations: $translations, remembered: store.rememberedTranslation(item), needsLogin: store.token.isEmpty, status: $status, download: c.download, all: c.all, quality: downloads.quality) { t in
                Task { if c.download { await download(t, c.episode, all: c.all) } else { await play(t, c.episode) } }
            } login: { login = true } close: { chooser = nil }
            .sheet(isPresented: $login) { LoginView() }
        }
        .sheet(isPresented: $login) { LoginView() }
        .fullScreenCover(item: $playback) { value in NativePlayerView(playback: value) { done, wantsNext in finished(value, done: done, next: wantsNext) }.ignoresSafeArea() }
    }
    var header: some View {
        ZStack(alignment: .bottomLeading) {
            CachedPoster(url: shown.posterSmall, fill: true).frame(height: 330).frame(maxWidth: .infinity).clipped().blur(radius: 24).opacity(0.6)
            LinearGradient(colors: [Night.bg.opacity(0.2), Night.bg.opacity(0.7), Night.bg], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 16) {
                CachedPoster(url: shown.poster, fill: true).frame(width: Metrics.regular ? 170 : 124, height: Metrics.regular ? 255 : 186).clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Night.stroke)).shadow(color: .black.opacity(0.45), radius: 14, y: 8)
                VStack(alignment: .leading, spacing: 7) {
                    Text(shown.title).font(.system(size: Metrics.regular ? 30 : 22, weight: .heavy)).foregroundStyle(Night.text).lineLimit(4).minimumScaleFactor(0.8)
                    HStack(spacing: 8) { ScoreChip(item: shown); Text([shown.kind, shown.year > 0 ? "\(shown.year)" : ""].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(Night.muted) }.font(.system(size: 13))
                    if !shown.season.isEmpty || !episodes.isEmpty { Text([shown.season, episodes.isEmpty ? "" : "\(episodes.count) эп."].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(Night.muted) }
                }
            }.padding(.horizontal, 18)
        }.frame(height: 330)
    }
    var actions: some View {
        VStack(spacing: 10) {
            Button { if let e = resume { start(e) } } label: {
                VStack(spacing: 6) {
                    Label(primaryTitle, systemImage: "play.fill").frame(maxWidth: .infinity)
                    if let e = resume, store.fraction(e.id) > 0, store.fraction(e.id) < 1 { ProgressLine(value: store.fraction(e.id)).padding(.horizontal, 30) }
                }
            }.buttonStyle(PillStyle(primary: true)).disabled(resume == nil)
            HStack(spacing: 10) {
                Button { store.favorite(item) } label: { Label(favorite ? "В списке" : "Мой список", systemImage: favorite ? "checkmark" : "plus").frame(maxWidth: .infinity) }.buttonStyle(PillStyle())
                Button { downloadAll() } label: { Label(downloadedCount > 0 ? "Скачано \(downloadedCount)" : "Скачать все", systemImage: downloadedCount == episodes.count && !episodes.isEmpty ? "checkmark.circle" : "arrow.down.circle").frame(maxWidth: .infinity) }
                    .buttonStyle(PillStyle()).disabled(episodes.isEmpty)
            }
        }
    }
    var downloadedCount: Int { episodes.filter { downloads.item($0.id) != nil }.count }
    var primaryTitle: String {
        guard let e = resume else { return busy ? "Загрузка серий…" : "Нет серий" }
        let last = store.lastEpisode(item); if last == 0 || (last != e.id && !store.isDone(last)) { return "Смотреть · \(e.title)" }
        return store.isDone(e.id) ? "Пересмотреть · \(e.title)" : "Продолжить · \(e.title)"
    }
    var episodeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(episodes.isEmpty ? "Серии" : "Серии · \(episodes.count)").font(.system(size: 19, weight: .bold)).foregroundStyle(Night.text)
            if busy && episodes.isEmpty { ProgressView().frame(maxWidth: .infinity).padding() }
            if !busy && episodes.isEmpty { Button("Повторить") { Task { await load() } }.buttonStyle(PillStyle()) }
            LazyVStack(spacing: 6) { ForEach(episodes) { ep in EpisodeRow(ep: ep, current: ep.id == resume?.id && store.lastEpisode(item) != 0, open: { start(ep) }, download: { downloadTapped(ep) }) } }
        }.padding(.horizontal, 18)
    }
    func next(after id: Int) -> Episode? { guard let i = episodes.firstIndex(where: { $0.id == id }), i + 1 < episodes.count else { return nil }; return episodes[i + 1] }
    func load() async {
        busy = true
        do {
            let (detailed, list) = try await store.details(item); full = detailed; episodes = list; store.seen(item, count: list.count)
            status = list.isEmpty ? "На сайте пока нет серий этого аниме" : ""
        } catch { status = error.localizedDescription }
        busy = false
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
    func choose(_ ep: Episode, auto: Bool = false, download: Bool = false, all: Bool = false) {
        Task {
            translations = []; status = auto ? "\(ep.title) — загрузка переводов…" : ""
            if !auto { chooser = Chooser(episode: ep, download: download, all: all) }
            do {
                translations = try await store.translations(ep, for: item)
                status = translations.isEmpty ? "Нет доступных переводов" : ""
                let remembered = store.rememberedTranslation(item)
                if auto, let first = translations.first, !remembered.isEmpty, first.signature == remembered { await play(first, ep) }
                else if auto { chooser = Chooser(episode: ep) }
            } catch { status = error.localizedDescription }
        }
    }
    func play(_ t: Translation, _ ep: Episode) async {
        guard !store.token.isEmpty else { login = true; return }
        status = "Подготовка видео и субтитров…"
        do {
            var value = try await store.playback(t, ep, item); value.hasNext = next(after: ep.id) != nil
            status = ""
            if chooser != nil { chooser = nil; try? await Task.sleep(for: .milliseconds(400)) }
            playback = value
        } catch { status = error.localizedDescription }
    }
    func finished(_ value: Playback, done: Bool, next wantsNext: Bool) {
        if done { store.markDone(value.episodeId); downloads.watched(value.episodeId) }
        Task { await store.sync() }
        guard wantsNext, let ep = next(after: value.episodeId) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { start(ep, auto: true) }
    }
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
        chooser = nil
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
    let open: () -> Void
    let download: () -> Void
    var body: some View {
        let done = store.isDone(ep.id), f = store.fraction(ep.id), d = downloads.item(ep.id)
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(current ? Night.accent : Night.raised).frame(width: 44, height: 44)
                        if done && !current { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Night.muted) }
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
        .task(id: translations.count) {
            #if DEBUG
            if QA.has("--pick-first"), let t = translations.first { pick(t) }
            #endif
        }
    }
    @ViewBuilder func section(_ title: String, _ list: [Translation]) -> some View {
        Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(Night.muted).padding(.top, 6)
        ForEach(list) { t in
            Button { pick(t) } label: {
                HStack {
                    Text(t.name.isEmpty ? (t.kind == "raw" ? "Японская дорожка без перевода" : "Без названия") : t.name).multilineTextAlignment(.leading).lineLimit(2)
                    Spacer()
                    if t.bd { Text("BD").font(.system(size: 11, weight: .heavy)).foregroundStyle(Night.onAccent).padding(.horizontal, 5).padding(.vertical, 2).background(Night.progress, in: RoundedRectangle(cornerRadius: 4)).accessibilityLabel("Blu-ray") }
                    if t.height >= 2160 { Text("4K").font(.system(size: 11, weight: .heavy)).padding(.horizontal, 5).padding(.vertical, 2).overlay(RoundedRectangle(cornerRadius: 4).stroke(Night.muted)) }
                    if t.signature == remembered { Image(systemName: "star.fill").foregroundStyle(Night.fresh).accessibilityLabel("Вы смотрели с этим переводом") }
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
