import SwiftUI
import AuthenticationServices
import UIKit
import WebKit
import CryptoKit

// MARK: Вкладка «Манга»

struct MangaTab: View {
    @ObservedObject var manga = MangaStore.shared
    var body: some View {
        NavigationStack(path: $manga.path) {
            MangaHomeView()
                .navigationDestination(for: MangaItem.self) { MangaTitleView(item: $0) }
                .background(NightBackground())
                .toolbarBackground(Night.bg.opacity(0.92), for: .navigationBar)
        }
    }
}

// «Моё» и «Загрузки»: одна вкладка, сверху переключатель Аниме/Манга (выбор запоминается).
struct SplitSection<A: View, M: View>: View {
    let title: String
    let anime: A
    let manga: M
    @AppStorage var mangaSide: Bool
    init(title: String, @ViewBuilder anime: () -> A, @ViewBuilder manga: () -> M) {
        self.title = title; self.anime = anime(); self.manga = manga(); _mangaSide = AppStorage(wrappedValue: false, "split-\(title)")
    }
    var body: some View {
        Group { if mangaSide { manga } else { anime } }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker(title, selection: $mangaSide) { Text("Аниме").tag(false); Text("Манга").tag(true) }.pickerStyle(.segmented).frame(width: 220)
                }
            }
    }
}

struct MangaLibraryView: View {
    @ObservedObject var manga = MangaStore.shared
    var body: some View {
        ScrollView {
            if manga.recent.isEmpty {
                EmptyState(icon: "book", title: "Вы ещё ничего не читали", text: "Открытая манга появится здесь и на полке «Продолжить чтение»").padding(.top, 40)
            } else {
                let g = Metrics.grid
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(g.width), spacing: 12, alignment: .top), count: g.count), alignment: .leading, spacing: 18) {
                    ForEach(manga.recent) { item in
                        NavigationLink(value: item) { MangaCard(item: item, caption: manga.positions[item.id].map { "\($0.title) · стр. \($0.page + 1)" }, badge: item.source.title, width: g.width) }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 18).padding(.vertical, 12)
            }
        }
        .navigationTitle("Моё").toolbarTitleDisplayMode(.inline)
    }
}

struct MangaDownloadsView: View {
    @ObservedObject var downloads = MangaDownloads.shared
    @EnvironmentObject var store: AnimeStore
    var body: some View {
        List {
            if downloads.titles.isEmpty {
                VStack(spacing: 14) {
                    EmptyState(icon: "arrow.down.circle", title: "Скачанной манги нет", text: "Нажмите ↓ рядом с главой, чтобы читать её без интернета")
                    Button("Найти мангу") { store.tab = 4 }.buttonStyle(PillStyle(primary: true))
                }.frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            ForEach(downloads.titles, id: \.item.id) { d in
                NavigationLink(value: d.item) {
                    HStack(spacing: 12) {
                        CachedPoster(url: d.item.cover, fill: true).frame(width: 40, height: 60).background(Night.raised).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(d.item.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Night.text).lineLimit(2)
                            Text("\(d.item.source.title) · \(downloads.count(d.item)) гл. · \(DownloadCenter.size(downloads.size(d.item)))").font(.system(size: 12)).foregroundStyle(Night.muted)
                        }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) { Button(role: .destructive) { downloads.deleteTitle(d.item) } label: { Label("Удалить", systemImage: "trash") }.tint(.red) }
                .contextMenu { Button("Удалить все главы", systemImage: "trash", role: .destructive) { downloads.deleteTitle(d.item) } }
                .listRowBackground(Night.surface.opacity(0.6))
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Загрузки").toolbarTitleDisplayMode(.inline)
    }
}

struct MangaCard: View {
    let item: MangaItem
    var caption: String? = nil
    var badge: String? = nil
    var width: CGFloat = Metrics.poster.width
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                Night.surface
                if item.cover.isEmpty { Image(systemName: "book.closed").font(.system(size: 30)).foregroundStyle(Night.muted) }
                CachedPoster(url: item.cover, fill: true)
            }
            .frame(width: width, height: width * 1.5).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topTrailing) { if let badge { Text(badge).font(.system(size: 10, weight: .heavy)).foregroundStyle(Night.onAccent).padding(.horizontal, 6).padding(.vertical, 3).background(Night.accent, in: Capsule()).padding(6) } }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Night.stroke))
            Text(item.title).font(.system(size: 13, weight: .bold)).foregroundStyle(Night.text).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                if caption == nil, let sc = Shikimori.shared.mangaScore(item), sc.score > 0 { ScoreChip.score(sc.score, "Shiki") }
                Text(caption ?? item.meta).foregroundStyle(Night.muted)
            }.font(.system(size: 12)).lineLimit(1)
        }
        .frame(width: width).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

struct MangaHomeView: View {
    @EnvironmentObject var store: AnimeStore
    @ObservedObject var manga = MangaStore.shared
    @ObservedObject var downloads = MangaDownloads.shared
    @ObservedObject var accounts = MangaAccounts.shared
    @State var query = ""
    @State var items: [MangaItem] = []
    @State var page = 1
    @State var more = false
    @State var loading = false
    @State var error = ""
    @State var showAccounts = false
    @State var generation = 0
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                Picker("Источник", selection: $manga.source) { ForEach(MangaSource.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).padding(.horizontal, 18)
                if query.isEmpty {
                    if !manga.recent.isEmpty {
                        ShelfRow(title: "Продолжить чтение") {
                            ForEach(manga.recent) { item in
                                NavigationLink(value: item) { MangaCard(item: item, caption: manga.positions[item.id].map { "\($0.title) · стр. \($0.page + 1)" }) }.buttonStyle(.plain)
                            }
                        }
                    }
                    if !downloads.titles.isEmpty {
                        ShelfRow(title: "Скачанная манга") {
                            ForEach(downloads.titles, id: \.item.id) { d in
                                NavigationLink(value: d.item) { MangaCard(item: d.item, caption: "Скачано: \(downloads.count(d.item)) гл.", badge: d.item.source.title) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                Text(query.isEmpty ? (manga.source == .mangalib ? "Популярное на MangaLib" : "Манга на Com-X") : "Найдено на \(manga.source.title)")
                    .font(.system(size: 19, weight: .bold)).foregroundStyle(Night.text).padding(.horizontal, 18)
                let g = Metrics.grid
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(g.width), spacing: 12, alignment: .top), count: g.count), alignment: .leading, spacing: 18) {
                    ForEach(items) { item in
                        NavigationLink(value: item) { MangaCard(item: item, width: g.width) }.buttonStyle(.plain)
                            .onAppear { if item.id == items.last?.id, more, !loading { Task { await load(reset: false) } } }
                    }
                }.padding(.horizontal, 18)
                if loading { ProgressView().tint(Night.text).frame(maxWidth: .infinity).padding(.vertical, 20) }
                if !error.isEmpty {
                    VStack(spacing: 12) {
                        EmptyState(icon: "wifi.slash", title: "\(manga.source.title) не ответил", text: error)
                        Button("Повторить") { Task { await load(reset: true) } }.buttonStyle(PillStyle(primary: true))
                    }.frame(maxWidth: .infinity)
                } else if !loading && items.isEmpty && !query.isEmpty {
                    EmptyState(icon: "magnifyingglass", title: "Ничего не нашлось", text: "Попробуйте другое название или другой источник.")
                }
            }.padding(.vertical, 12)
        }
        .navigationTitle("Манга")
        .toolbar {
            // Поиск манги — общий, во вкладке «Поиск».
            ToolbarItem(placement: .topBarTrailing) {
                Button { store.tab = 5 } label: { Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .semibold)) }.accessibilityLabel("Поиск")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAccounts = true } label: { Image(systemName: accounts.libLogged || accounts.comxLogged ? "person.crop.circle.fill" : "person.crop.circle.badge.plus").font(.system(size: 20)) }
                    .accessibilityLabel("Аккаунты")
            }
        }
        .sheet(isPresented: $showAccounts) { MangaAccountsView() }
        .task(id: "\(manga.source.rawValue)|\(query)") {
            if !query.isEmpty { try? await Task.sleep(nanoseconds: 450_000_000); if Task.isCancelled { return } }
            await load(reset: true)
        }
        .refreshable { await load(reset: true) }
        .onAppear {
            #if DEBUG
            if QA.has("--manga-accounts") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showAccounts = true } }
            if let q = QA.value("--manga-query"), query.isEmpty { query = q }
            #endif
        }
    }
    func load(reset: Bool) async {
        if reset { generation += 1; page = 1; more = false; error = "" }
        let gen = generation, source = manga.source, q = query.trimmingCharacters(in: .whitespaces)
        loading = true
        do {
            let (list, next) = try await MangaAPI.search(source, q, page: page)
            guard gen == generation else { return }
            items = reset ? list : items + list.filter { x in !items.contains(x) }
            more = next && !list.isEmpty; page += 1
        } catch {
            guard gen == generation else { return }
            if reset { items = [] }
            self.error = error.localizedDescription
        }
        loading = false
    }
}

// MARK: Карточка тайтла

struct ReaderStart: Identifiable { let id = UUID(); let details: MangaDetails; let index: Int; let page: Int }

struct MangaTitleView: View {
    let item: MangaItem
    @ObservedObject var shiki = Shikimori.shared
    @ObservedObject var manga = MangaStore.shared
    @ObservedObject var downloads = MangaDownloads.shared
    @State var details: MangaDetails?
    @State var offline = false
    @State var error = ""
    @State var newestFirst = false
    @State var reading: ReaderStart?
    @State var expanded = false
    @State var autoOpened = false
    var current: MangaItem { details?.item ?? item }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let details { info(details); chapters(details) }
                else if !error.isEmpty {
                    VStack(spacing: 12) {
                        EmptyState(icon: "exclamationmark.triangle", title: "Не удалось открыть", text: error)
                        Button("Повторить") { Task { await load() } }.buttonStyle(PillStyle(primary: true))
                    }.frame(maxWidth: .infinity)
                } else { ProgressView().tint(Night.text).frame(maxWidth: .infinity).padding(.top, 30) }
            }.padding(.vertical, 12)
        }
        .background(NightBackground())
        .navigationTitle(current.title).navigationBarTitleDisplayMode(.inline)
        .task { if details == nil { await load() } }
        .task(id: current.title + "|" + current.subtitle) { await shiki.loadManga(current) }
        .fullScreenCover(item: $reading) { MangaReaderView(start: $0) }
    }
    var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack { Night.surface; CachedPoster(url: current.cover, fill: true) }
                .frame(width: Metrics.regular ? 170 : 124, height: Metrics.regular ? 255 : 186).clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Night.stroke))
            VStack(alignment: .leading, spacing: 6) {
                Text(current.title).font(.system(size: 21, weight: .heavy)).foregroundStyle(Night.text).fixedSize(horizontal: false, vertical: true)
                if !current.subtitle.isEmpty { Text(current.subtitle).font(.system(size: 14)).foregroundStyle(Night.muted).lineLimit(2) }
                Text(([current.source.title, current.meta].filter { !$0.isEmpty }).joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(Night.meta).lineLimit(2)
                // Оценка Шикимори, если тайтл там есть; нажатие открывает его страницу.
                if let sc = shiki.mangaScore(current), sc.score > 0, let url = Shikimori.mangaURL(current) {
                    Link(destination: url) { ScoreBox(label: "Shikimori ↗", value: sc.score) }.padding(.top, 2)
                }
                if offline { Label("Без сети — показаны скачанные главы", systemImage: "wifi.slash").font(.system(size: 12, weight: .semibold)).foregroundStyle(Night.fresh) }
            }
        }.padding(.horizontal, 18)
    }
    func info(_ d: MangaDetails) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button { openContinue(d) } label: { Label(continueTitle(d), systemImage: "book.fill").frame(maxWidth: .infinity) }.buttonStyle(PillStyle(primary: true)).disabled(d.chapters.isEmpty)
                Menu {
                    Button { downloads.download(d, d.chapters.filter { !manga.isRead(current, $0) }) } label: { Label("Скачать непрочитанные", systemImage: "arrow.down.circle") }
                    Button { downloads.download(d, nextChapters(d, 5)) } label: { Label("Скачать следующие 5 глав", systemImage: "arrow.down.to.line") }
                    Button { downloads.download(d, d.chapters) } label: { Label("Скачать все главы (\(d.chapters.count))", systemImage: "square.and.arrow.down.on.square") }
                    if downloads.count(current) > 0 { Button(role: .destructive) { downloads.deleteTitle(current) } label: { Label("Удалить скачанное", systemImage: "trash") } }
                } label: { Label(downloads.count(current) > 0 ? "\(downloads.count(current)) гл." : "Скачать", systemImage: "arrow.down.circle") }.buttonStyle(PillStyle())
            }
            if !d.info.isEmpty { Text(d.info.joined(separator: "\n")).font(.system(size: 13)).foregroundStyle(Night.muted) }
            if !d.summary.isEmpty {
                Text(d.summary).font(.system(size: 15)).foregroundStyle(Night.text.opacity(0.9)).lineLimit(expanded ? nil : 4)
                    .onTapGesture { withAnimation { expanded.toggle() } }
            }
            if !d.tags.isEmpty { FlowLayout(spacing: 6) { ForEach(d.tags.prefix(14), id: \.self) { Text($0).font(.system(size: 12, weight: .semibold)).foregroundStyle(Night.text).padding(.horizontal, 10).frame(height: 28).background(Night.raised, in: Capsule()) } } }
        }.padding(.horizontal, 18)
    }
    func chapters(_ d: MangaDetails) -> some View {
        let list = Array(d.chapters.enumerated())
        let shown = newestFirst ? list.reversed() : list
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Главы · \(d.chapters.count)").font(.system(size: 19, weight: .bold)).foregroundStyle(Night.text)
                Spacer()
                Button { newestFirst.toggle() } label: { Label(newestFirst ? "Сначала новые" : "По порядку", systemImage: "arrow.up.arrow.down").font(.system(size: 14, weight: .semibold)) }.foregroundStyle(Night.muted)
            }.padding(.horizontal, 18).padding(.bottom, 8)
            if d.chapters.isEmpty { EmptyState(icon: "book.closed", title: "Глав пока нет", text: "Источник ещё не выложил главы этого тайтла.") }
            LazyVStack(spacing: 0) {
                ForEach(shown, id: \.element.id) { i, ch in
                    ChapterRow(item: current, chapter: ch, details: d) { reading = ReaderStart(details: d, index: i, page: manga.isRead(current, ch) && manga.positions[current.id]?.chapter != ch.id ? 0 : manga.page(current, ch)) }
                    Divider().overlay(Night.stroke).padding(.leading, 18)
                }
            }
        }
    }
    func continueTitle(_ d: MangaDetails) -> String {
        guard let p = manga.positions[current.id], d.chapters.contains(where: { $0.id == p.chapter }) else { return "Читать с начала" }
        return "Продолжить · \(p.title)"
    }
    func openContinue(_ d: MangaDetails) {
        if let p = manga.positions[current.id], let i = d.chapters.firstIndex(where: { $0.id == p.chapter }) { reading = ReaderStart(details: d, index: i, page: p.page) }
        else if !d.chapters.isEmpty { reading = ReaderStart(details: d, index: 0, page: 0) }
    }
    func nextChapters(_ d: MangaDetails, _ n: Int) -> [MangaChapter] {
        let start = manga.positions[current.id].flatMap { p in d.chapters.firstIndex { $0.id == p.chapter } } ?? 0
        return Array(d.chapters[start..<min(d.chapters.count, start + n)])
    }
    func load() async {
        error = ""
        do { details = try await MangaAPI.details(item); offline = false }
        catch {
            if let local = downloads.local(item) { details = local; offline = true } else { self.error = error.localizedDescription }
        }
        #if DEBUG
        if QA.has("--manga-read"), !autoOpened, let d = details { autoOpened = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { openContinue(d) } }
        #endif
    }
}

struct ChapterRow: View {
    let item: MangaItem; let chapter: MangaChapter; let details: MangaDetails; let open: () -> Void
    @ObservedObject var manga = MangaStore.shared
    @ObservedObject var downloads = MangaDownloads.shared
    var body: some View {
        let key = MangaDownloads.key(item, chapter), read = manga.isRead(item, chapter)
        let current = manga.positions[item.id]?.chapter == chapter.id
        HStack(spacing: 12) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(chapter.title).font(.system(size: 15, weight: current ? .bold : .medium)).foregroundStyle(read && !current ? Night.muted : Night.text).lineLimit(2).multilineTextAlignment(.leading)
                    if current, let p = manga.positions[item.id] { Text("Вы здесь · стр. \(p.page + 1) из \(max(p.count, p.page + 1))").font(.system(size: 12, weight: .semibold)).foregroundStyle(Night.progress) }
                    else if read { Text("Прочитано").font(.system(size: 12)).foregroundStyle(Night.muted) }
                    if let f = downloads.failed[key] { Text(f).font(.system(size: 12)).foregroundStyle(Night.danger).lineLimit(2) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Group {
                if downloads.done.contains(key) {
                    Menu { Button(role: .destructive) { downloads.delete(item, chapter) } label: { Label("Удалить с устройства", systemImage: "trash") } } label: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Night.scoreHigh) }
                        .accessibilityLabel("Скачано")
                } else if let p = downloads.progress[key] {
                    Button { downloads.cancel(item, chapter) } label: {
                        ZStack { Circle().stroke(Night.stroke, lineWidth: 3); Circle().trim(from: 0, to: max(0.03, p)).stroke(Night.progress, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90)); Image(systemName: "stop.fill").font(.system(size: 8)) }
                            .frame(width: 22, height: 22)
                    }.accessibilityLabel("Остановить загрузку")
                } else {
                    Button { downloads.download(details, [chapter]) } label: { Image(systemName: "arrow.down.circle") }.accessibilityLabel("Скачать главу")
                }
            }.font(.system(size: 22)).foregroundStyle(Night.text).frame(width: 44, height: 44)
        }
        .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 4)
        .contextMenu {
            Button { manga.toggleRead(item, chapter) } label: { Label(read ? "Отметить непрочитанной" : "Отметить прочитанной", systemImage: read ? "circle" : "checkmark.circle") }
        }
    }
}

// MARK: Аккаунты

struct MangaAccountsView: View {
    @EnvironmentObject var store: AnimeStore
    @ObservedObject var accounts = MangaAccounts.shared
    @Environment(\.dismiss) var dismiss
    @State var anime = false
    @State var lib = false
    @State var libProvider: String? = nil
    @State var comx = false
    @ObservedObject var yoru = YoruAccount.shared
    @ObservedObject var shiki = ShikiAccount.shared
    @Environment(\.webAuthenticationSession) var webAuth
    @State var leave: String?
    @State var shikiSheet = false
    @State private var showServices = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("Аккаунты").font(.system(size: 22, weight: .bold)).foregroundStyle(.white); Spacer(); Button("Закрыть") { dismiss() }.buttonStyle(NightButtonStyle()) }
                YoruAccountCard()
                DisclosureGroup(isExpanded: $showServices) {
                    serviceAccounts.padding(.top, 10)
                } label: {
                    Text("Аккаунты сервисов").font(.system(size: 17, weight: .semibold))
                }
                .padding(14).background(Night.panel, in: RoundedRectangle(cornerRadius: 16))
                .tint(Night.text).foregroundStyle(Night.text)
            }.padding(20)
        }
        .background(NightBackground()).presentationDetents([.large])
        .task { await accounts.refreshComx(); await accounts.refreshLibName() }
        .sheet(isPresented: $anime) { LoginView() }
        .sheet(isPresented: $shikiSheet) { ShikiConnectView() }
        .sheet(isPresented: $lib) { MangaLibLoginView(provider: libProvider) }
        .sheet(isPresented: $comx, onDismiss: { Task { await accounts.refreshComx() } }) { ComxLoginView() }
        .confirmationDialog("Выйти из сервиса?", isPresented: Binding(get: { leave != nil }, set: { if !$0 { leave = nil } }), titleVisibility: .visible, presenting: leave) { svc in
            Button("Только на этом устройстве") { Task { await signOut(svc) } }
            Button("На всех устройствах аккаунта", role: .destructive) { yoru.forgetEverywhere(svc); Task { await signOut(svc) } }
        } message: { _ in Text("Вход сохранён в аккаунте Yoru. Выход на всех устройствах удалит его из аккаунта.") }
    }
    private var serviceAccounts: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Anime 365", icon: "play.tv.fill", status: store.token.isEmpty ? "Не выполнен вход · без входа видео не играет" : (store.account.isEmpty ? "Вход выполнен" : store.account), logged: !store.token.isEmpty, login: { anime = true }, logout: nil)
            row("MangaLib", icon: "book.fill", status: accounts.libLogged ? (accounts.libName.isEmpty ? "Вход выполнен" : accounts.libName) : "Не выполнен вход · без входа скрыты тайтлы 18+", logged: accounts.libLogged, login: { libProvider = nil; lib = true }, logout: { if yoru.logged { leave = "mangalib" } else { accounts.libLogout() } },
                alt: [("Через VK", { libProvider = "vkontakte"; lib = true }), ("Через Яндекс", { libProvider = "yandex"; lib = true })])
            row("Com-X", icon: "books.vertical.fill", status: accounts.comxLogged ? "Вход выполнен" : "Не выполнен вход · читать можно и без него", logged: accounts.comxLogged, login: { comx = true }, logout: { if yoru.logged { leave = "comx" } else { Task { await accounts.comxLogout() } } })
            row("Шикимори", icon: "star.bubble.fill", status: shiki.signedIn ? "\(shiki.nickname) · оценки и просмотренные серии уходят в ваш список" : "Не выполнен вход · оценки и список просмотренного",
                logged: shiki.signedIn, login: { shikiSheet = true }, logout: { shiki.signOut() })
        }
    }
    func signOut(_ svc: String) async {
        switch svc {
        case "anime365": store.logout()
        case "mangalib": accounts.libLogout()
        default: await accounts.comxLogout()
        }
    }
    func row(_ title: String, icon: String, status: String, logged: Bool, login: @escaping () -> Void, logout: (() -> Void)?, alt: [(String, () -> Void)] = []) -> some View {
        VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(logged ? Night.scoreHigh : Night.muted).frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(Night.text)
                Text(status).font(.system(size: 13)).foregroundStyle(Night.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if logged, let logout { Button("Выйти", action: logout).buttonStyle(PillStyle()) }
            else { Button(logged ? "Открыть" : "Войти", action: login).buttonStyle(PillStyle(primary: !logged)) }
        }
        // Другие способы входа (VK, Яндекс) — отдельной строкой под основной кнопкой.
        if !logged && !alt.isEmpty {
            HStack(spacing: 8) { ForEach(alt.indices, id: \.self) { i in Button(alt[i].0, action: alt[i].1).buttonStyle(PillStyle()) } }.padding(.leading, 48)
        }
        }
        .padding(14).background(Night.panel, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Night.stroke))
    }
}

// Страница сайта в листе: вход вводится на самом сайте, приложение видит только адреса переходов.
struct WebPage: UIViewRepresentable {
    let url: URL
    var decide: (URL) -> Bool = { _ in true }
    var finished: (WKWebView) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration(); c.websiteDataStore = .default()
        let w = WKWebView(frame: .zero, configuration: c); w.navigationDelegate = context.coordinator; w.uiDelegate = context.coordinator; w.allowsBackForwardNavigationGestures = true
        w.isOpaque = false; w.backgroundColor = UIColor(Night.bg)
        w.load(URLRequest(url: url)); return w
    }
    func updateUIView(_ w: WKWebView, context: Context) { context.coordinator.page = self }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var page: WebPage
        init(_ p: WebPage) { page = p }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let u = action.request.url else { return decisionHandler(.allow) }
            decisionHandler(page.decide(u) ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { page.finished(webView) }
        // Кнопки «Войти через ВКонтакте / Яндекс / …» открывают вход отдельным окном (window.open), и сайт ждёт
        // ответа из него. Без этого WKWebView окно молча теряет — показываем его поверх, окно закроется само.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let popup = WKWebView(frame: webView.bounds, configuration: configuration)
            popup.autoresizingMask = [.flexibleWidth, .flexibleHeight]; popup.navigationDelegate = self; popup.uiDelegate = self
            popup.isOpaque = false; popup.backgroundColor = UIColor(Night.bg)
            let close = UIButton(type: .close, primaryAction: UIAction { [weak popup] _ in popup?.removeFromSuperview() })
            close.frame = CGRect(x: popup.bounds.width - 52, y: 8, width: 44, height: 44); close.autoresizingMask = [.flexibleLeftMargin]
            close.accessibilityLabel = "Закрыть окно входа"
            popup.addSubview(close); webView.addSubview(popup)
            return popup
        }
        func webViewDidClose(_ webView: WKWebView) { if webView.superview is WKWebView { webView.removeFromSuperview() } }
    }
}

struct MangaLibLoginView: View {
    // "vkontakte" или "yandex": со страницы входа MangaLib окно сразу переходит на вход в этот сервис,
    // а после него сайт сам возвращается к выдаче кода.
    var provider: String? = nil
    @State var socialPending = true
    @ObservedObject var accounts = MangaAccounts.shared
    @Environment(\.dismiss) var dismiss
    @State var verifier = MangaLibLoginView.random(128)
    @State var state = MangaLibLoginView.random(40)
    @State var busy = false
    @State var error = ""
    static func random(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }
    var challenge: String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Вход в MangaLib").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                Spacer()
                if busy { ProgressView().tint(.white) }
                Button("Закрыть") { dismiss() }.buttonStyle(NightButtonStyle())
            }.padding(14)
            if !error.isEmpty { Text(error).font(.system(size: 13)).foregroundStyle(.orange).padding(.horizontal, 14).padding(.bottom, 8) }
            WebPage(url: MangaLib.authorizeURL(state: state, challenge: challenge), decide: { u in
                guard u.absoluteString.hasPrefix(MangaLib.redirect) else { return true }
                let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard let code = q.first(where: { $0.name == "code" })?.value, q.first(where: { $0.name == "state" })?.value == state else {
                    error = "Вход отменён. Попробуйте ещё раз."; return false
                }
                busy = true
                Task { do { try await accounts.libExchange(code: code, verifier: verifier); dismiss() } catch { self.error = error.localizedDescription }; busy = false }
                return false
            }, finished: { w in
                guard socialPending, let p = provider, w.url?.absoluteString.hasPrefix("https://auth.lib.social/auth/login") == true,
                      let next = URL(string: "https://auth.lib.social/auth/oauth/redirect/\(p)?intent=login") else { return }
                socialPending = false
                w.load(URLRequest(url: next))
            })
        }.background(NightBackground())
    }
}

struct ComxLoginView: View {
    @ObservedObject var accounts = MangaAccounts.shared
    @Environment(\.dismiss) var dismiss
    @State var was: Bool?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Вход в Com-X").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                    Text(accounts.comxLogged ? "Вход выполнен" : "Нажмите «Вход» на сайте").font(.system(size: 12)).foregroundStyle(accounts.comxLogged ? Night.scoreHigh : Night.meta)
                }
                Spacer()
                Button(accounts.comxLogged ? "Готово" : "Закрыть") { dismiss() }.buttonStyle(NightButtonStyle(selected: accounts.comxLogged))
            }.padding(14)
            WebPage(url: Comx.base, finished: { _ in
                Task {
                    await accounts.refreshComx()
                    if was == false && accounts.comxLogged { Comx.shared.reset(); YoruAccount.shared.vaultChanged("comx"); dismiss() }
                    if was == nil { was = accounts.comxLogged }
                }
            })
        }.background(NightBackground())
    }
}

// MARK: Подключение Шикимори
// Вход через сайт Шикимори (OAuth). Ключи приложения в публичный репозиторий не попадают: если сборка без них,
// их один раз вводят здесь — они хранятся в Связке ключей iPhone.
struct ShikiConnectView: View {
    @ObservedObject var shiki = ShikiAccount.shared
    @EnvironmentObject var store: AnimeStore
    @Environment(\.dismiss) var dismiss
    @Environment(\.webAuthenticationSession) var webAuth
    @Environment(\.openURL) var openURL
    @State var id = ""
    @State var secret = ""
    @State var busy = false
    @State var editing = false
    @State var leaving = false
    @ObservedObject var yoru = YoruAccount.shared
    func field<F: View>(_ f: F) -> some View { f.font(.system(size: 16)).foregroundStyle(.white).padding(.horizontal, 14).frame(height: 48).background(Night.panel, in: RoundedRectangle(cornerRadius: 12)) }
    func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(Night.text).frame(width: 22, height: 22).background(Night.panel, in: Circle())
            Text(text).font(.system(size: 14)).foregroundStyle(Night.text.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("Шикимори").font(.system(size: 22, weight: .bold)).foregroundStyle(.white); Spacer(); Button("Закрыть") { dismiss() }.buttonStyle(NightButtonStyle()) }
                Text("Оценки, «Смотрю» и «Просмотрено» уходят в ваш список на Шикимори, а список просмотренного виден в «Моё». Вход хранится в аккаунте Yoru — на других устройствах входить не нужно.")
                    .font(.system(size: 14)).foregroundStyle(Night.meta)
                if shiki.signedIn {
                    Text("Вход выполнен: \(shiki.nickname)").font(.system(size: 16, weight: .semibold)).foregroundStyle(Night.scoreHigh)
                    Button(shiki.syncing ? (shiki.syncStep.isEmpty ? "Синхронизирую…" : shiki.syncStep) : "Синхронизировать просмотренное") { Task { await shiki.syncBoth(store, report: true) } }
                        .buttonStyle(NightButtonStyle(selected: true)).disabled(shiki.syncing)
                    Text("Работает в обе стороны: отмеченное на Шикимори становится просмотренным в Yoru, а просмотренное в Yoru уходит на Шикимори. Также при каждом запуске.").font(.system(size: 12)).foregroundStyle(Night.meta)
                    Button("Выйти из Шикимори") { if yoru.logged { leaving = true } else { shiki.signOut() } }.buttonStyle(NightButtonStyle())
                        .confirmationDialog("Выйти из Шикимори?", isPresented: $leaving, titleVisibility: .visible) {
                            Button("Только на этом iPhone") { shiki.signOut() }
                            Button("На всех устройствах аккаунта", role: .destructive) { yoru.forgetEverywhere("shikimori"); shiki.signOut() }
                            Button("Отмена", role: .cancel) {}
                        } message: { Text("Вход сохранён в аккаунте Yoru. Выход на всех устройствах удалит его из аккаунта.") }
                } else if shiki.configured && !editing {
                    Button(busy ? "Открываю Шикимори…" : "Войти через Шикимори") { Task { await signIn() } }
                        .buttonStyle(NightButtonStyle(selected: true)).disabled(busy)
                    if !shiki.builtIn { Button("Изменить ключи приложения") { editing = true }.font(.system(size: 14)).foregroundStyle(Night.muted) }
                } else {
                    Text("Один раз нужно создать приложение на Шикимори — так сайт разрешает Yoru менять ваш список.")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Night.text)
                    step(1, "Откройте «Приложения» на сайте (нужно войти) и нажмите «создать» справа от заголовка.")
                    Button("Открыть shikimori.io ↗") { openURL(URL(string: Shikimori.site + "/oauth/applications")!) }.buttonStyle(NightButtonStyle())
                    step(2, "Название — Yoru. В «Redirect URI» вставьте адрес ниже, отметьте право user_rates и сохраните.")
                    Button("Скопировать yoru://shikimori") { UIPasteboard.general.string = ShikiAccount.redirect; shiki.message = "Адрес скопирован" }.buttonStyle(NightButtonStyle())
                    step(3, "Скопируйте сюда Client ID и Client Secret со страницы приложения.")
                    field(TextField("", text: $id, prompt: Text("Client ID").foregroundStyle(Night.rgb(0x9c9eaf))).textInputAutocapitalization(.never).autocorrectionDisabled())
                    field(SecureField("", text: $secret, prompt: Text("Client Secret").foregroundStyle(Night.rgb(0x9c9eaf))))
                    Button(busy ? "Открываю Шикимори…" : "Сохранить и войти") {
                        shiki.setAppKeys(id: id.trimmingCharacters(in: .whitespacesAndNewlines), secret: secret.trimmingCharacters(in: .whitespacesAndNewlines))
                        secret = ""; editing = false
                        Task { await signIn() }
                    }.buttonStyle(NightButtonStyle(selected: true)).disabled(busy || id.trimmingCharacters(in: .whitespaces).isEmpty || secret.trimmingCharacters(in: .whitespaces).isEmpty)
                    Text("Ключи хранятся только в Связке ключей этого iPhone.").font(.system(size: 12)).foregroundStyle(Night.meta)
                }
                if !shiki.message.isEmpty { Text(shiki.message).font(.system(size: 13)).foregroundStyle(Night.fresh) }
            }.padding(20)
        }
        .background(NightBackground()).presentationDetents([.large])
        .onAppear { shiki.message = "" }
    }
    func signIn() async {
        guard let url = shiki.authorizeURL else { return }
        busy = true; shiki.message = ""
        defer { busy = false }
        do {
            let back = try await webAuth.authenticate(using: url, callbackURLScheme: "yoru", preferredBrowserSession: .shared)
            try await shiki.finish(back)
            await shiki.syncBoth(store, report: true)
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin { shiki.message = error.localizedDescription }
        }
    }
}
