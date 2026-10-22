import Foundation
import Security

struct AnimeItem: Identifiable, Hashable {
    let id: Int
    let title: String
    let subtitle: String
    let poster: String
    let posterSmall: String
    let year: Int
    let kind: String
    let season: String
    let score: Double
    let genres: [Genre]
    let summary: String
    let raw: Data
    init(_ value: [String: Any]) {
        id = (value["id"] as? NSNumber)?.intValue ?? 0
        let titles = value["titles"] as? [String: String] ?? [:]
        title = titles["ru"] ?? titles["romaji"] ?? value["title"] as? String ?? "Аниме"
        year = (value["year"] as? NSNumber)?.intValue ?? 0
        kind = value["typeTitle"] as? String ?? ""
        subtitle = [kind.isEmpty ? nil : kind, year > 0 ? "\(year)" : nil].compactMap { $0 }.joined(separator: " · ")
        poster = value["posterUrl"] as? String ?? value["posterUrlSmall"] as? String ?? ""
        posterSmall = value["posterUrlSmall"] as? String ?? poster
        season = value["season"] as? String ?? ""
        score = (value["myAnimeListScore"] as? NSNumber)?.doubleValue ?? 0
        genres = (value["genres"] as? [[String: Any]] ?? []).compactMap { g in (g["id"] as? NSNumber).map { Genre(id: $0.intValue, title: g["title"] as? String ?? "") } }
        // Описания с Шикимори размечены BB-кодами вида [character=1]Имя[/character] — оставляем только текст.
        let text = (value["descriptions"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String }.first ?? ""
        summary = text.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        raw = (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
    }
    var object: [String: Any] { (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:] }
    var scoreText: String { score > 0 ? String(format: "%.1f", score).replacingOccurrences(of: ".", with: ",") : "" }
    static func == (a: AnimeItem, b: AnimeItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}
struct Season: Identifiable { let id: Int; let label: String; let current: Bool; let item: AnimeItem }
struct Genre: Hashable, Identifiable { let id: Int; let title: String }
struct Episode: Identifiable, Hashable {
    let id: Int; let title: String; let number: Double; let uploaded: Date?; let trailer: Bool; let kind: String
    init(_ d: [String: Any]) {
        kind = d["episodeType"] as? String ?? ""; trailer = kind == "preview"
        id = (d["id"] as? NSNumber)?.intValue ?? 0; title = d["episodeFull"] as? String ?? "Серия"; number = (d["episodeInt"] as? NSNumber)?.doubleValue ?? 0
        uploaded = (d["firstUploadedDateTime"] as? String).flatMap { Episode.dates.date(from: $0) }
    }
    // «Серии» без трейлеров и спецвыпусков (SP): только они считаются в «Серии · N» и в досмотренности.
    static func regular(_ list: [Episode]) -> Set<Int> {
        let tv = list.contains { $0.kind == "tv" }
        return Set(list.filter { tv ? $0.kind == "tv" : $0.kind != "preview" && $0.kind != "special" }.map(\.id))
    }
    // Время на сайте — московское.
    static let dates: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Europe/Moscow"); return f }()
}
struct Translation: Identifiable {
    let id: Int; let title: String; let kind: String; let signature: String
    let group: String; let name: String; let height: Int; let priority: Int
    // BD — перевод сделан с Blu-ray диска (обычно чище картинка, без логотипов канала).
    let bd: Bool
    // Русские субтитры, русская озвучка и оригинал — основные; остальные языки прячутся в «Другие языки».
    var main: Bool { ["subRu", "voiceRu", "raw"].contains(kind) }
    static let groups = ["subRu": "Русские субтитры", "voiceRu": "Русская озвучка", "raw": "Оригинал", "subEn": "Английские субтитры", "subJa": "Японские субтитры",
                         "subUk": "Украинские субтитры", "voiceEn": "Английская озвучка", "voiceJa": "Японская озвучка", "voiceUk": "Украинская озвучка"]
    init(_ d: [String: Any]) {
        id = (d["id"] as? NSNumber)?.intValue ?? 0
        kind = d["type"] as? String ?? ""
        signature = kind + "|" + (d["authorsSummary"] as? String ?? "")
        height = (d["height"] as? NSNumber)?.intValue ?? 0
        priority = (d["priority"] as? NSNumber)?.intValue ?? 0
        bd = d["qualityType"] as? String == "bd"
        group = Translation.groups[kind] ?? (kind.hasPrefix("sub") ? "Субтитры на другом языке" : kind.hasPrefix("voice") ? "Озвучка на другом языке" : "Оригинал")
        // Сайт иногда пишет в авторах «- Opus 2.0» или пустую строку — чистим.
        let authors = (d["authorsSummary"] as? String ?? (d["authorsList"] as? [String])?.joined(separator: ", ") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " -–"))
        name = authors == "Original" ? "" : authors
        title = [group, name, bd ? "BD" : "", height >= 2160 ? "4K" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    // Только настоящие варианты: без безымянных дублей, одна строка на команду и вид перевода (в лучшем качестве),
    // один «Оригинал»; выбранный раньше перевод — первым.
    static func clean(_ list: [Translation], remembered: String) -> [Translation] {
        func better(_ a: Translation, _ b: Translation) -> Bool { (a.height, a.priority) > (b.height, b.priority) }
        var best: [String: Translation] = [:]
        for t in list where t.kind == "raw" || !t.name.isEmpty || t.signature == remembered {
            // ТВ- и BD-версии одной команды — разные варианты, обе остаются.
            let key = (t.kind == "raw" && t.signature != remembered ? "raw" : t.signature) + (t.bd ? "|bd" : "")
            if best[key].map({ better(t, $0) }) ?? true { best[key] = t }
        }
        let order = ["subRu", "voiceRu", "raw"]
        func rank(_ t: Translation) -> Int { t.signature == remembered ? -1 : order.firstIndex(of: t.kind) ?? 3 }
        return best.values.sorted { (rank($0), $0.bd ? 0 : 1, -$0.priority, $0.id) < (rank($1), $1.bd ? 0 : 1, -$1.priority, $1.id) }
    }
}
struct VideoOption: Identifiable { let id: String; let url: URL; let height: Int; var alternatives: [URL] = [] }
struct Playback: Identifiable { let id = UUID(); let options: [VideoOption]; let subtitles: URL?; let title: String; let key: String; var episodeId = 0; var hasNext = false; var offline = false }
struct APIError: LocalizedError { let message: String; var errorDescription: String? { message } }
enum Vault {
    static let service = "com.resvvt.nightanime"
    static func get() -> String {
        var result: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "token", kSecReturnData as String: true]
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ token: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "token"]
        SecItemDelete(q as CFDictionary)
        guard !token.isEmpty else { return }
        var add = q; add[kSecValueData as String] = token.data(using: .utf8); add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
@MainActor final class AnimeStore: ObservableObject {
    @Published var token = Vault.get()
    @Published var favorites: [AnimeItem] = []
    @Published var history: [AnimeItem] = []
    @Published var account = "Войти"
    // Подписка Anime 365 из /api/me: isPremium и premiumUntil.
    @Published var premium: Bool?
    @Published var premiumUntil: Date?
    // Состояние интерфейса: вкладка, путь на главной и загруженные полки (живут до перезапуска).
    @Published var tab = 0
    @Published var homePath: [Route] = []
    @Published var shelves: [Shelf: [AnimeItem]] = [:]
    @Published var shelfErrors: [Shelf: String] = [:]
    let heroPick = Int.random(in: 0..<5)
    private var loading: Set<Shelf> = []
    func loadShelf(_ s: Shelf) async {
        guard shelves[s] == nil, !loading.contains(s) else { return }
        loading.insert(s); defer { loading.remove(s) }
        do { shelves[s] = try await shelf(s.params); shelfErrors[s] = nil } catch { shelfErrors[s] = error.localizedDescription }
    }
    let session: URLSession = { let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 25; c.urlCache = nil; return URLSession(configuration: c) }()
    let base = "https://smotret-anime.app"
    var seasonCache: [Int: [Season]] = [:]
    init() { favorites = restore("favorites"); history = restore("history") }
    func restore(_ key: String) -> [AnimeItem] { guard let a = UserDefaults.standard.array(forKey: key) as? [Data] else { return [] }; return a.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }.map(AnimeItem.init) }
    func save(_ key: String, _ items: [AnimeItem]) { UserDefaults.standard.set(items.map(\.raw), forKey: key); UserDefaults.standard.set(HistoryState.now(), forKey: "t-" + key) }
    func favorite(_ item: AnimeItem) { if favorites.contains(where: { $0.id == item.id }) { favorites.removeAll { $0.id == item.id } } else { favorites.insert(item, at: 0) }; save("favorites", favorites) }
    func watched(_ item: AnimeItem) { history.removeAll { $0.id == item.id }; history.insert(item, at: 0); history = Array(history.prefix(50)); save("history", history) }
    func request(_ path: String, _ params: [String: String] = [:], authenticated: Bool = false) async throws -> Any {
        var c = URLComponents(string: base + "/api/" + path)!
        var p = params; if authenticated { guard !token.isEmpty else { throw APIError(message: "Войдите в аккаунт Anime 365") }; p["access_token"] = token }
        c.queryItems = (c.queryItems ?? []) + p.map { URLQueryItem(name: $0.key, value: $0.value) }
        var r = URLRequest(url: c.url!); r.setValue("NightAnime/1.0 (iOS)", forHTTPHeaderField: "User-Agent"); r.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data
        do { (data, _) = try await session.data(for: r) } catch { throw APIError(message: "Не удалось подключиться к Anime 365. Проверьте интернет и повторите.") }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError(message: "Сайт вернул неожиданный ответ. Повторите позже.") }
        if let e = j["error"] as? [String: Any] { throw APIError(message: e["message"] as? String ?? "Ошибка Anime 365") }
        guard let result = j["data"] else { throw APIError(message: "Пустой ответ Anime 365") }; return result
    }
    func login(_ email: String, _ password: String, _ app: String) async throws {
        let d = try await request("login", ["email": email, "password": password, "app": app]) as? [String: Any]
        guard let t = d?["access_token"] as? String, !t.isEmpty else { throw APIError(message: "Не удалось выполнить вход") }
        token = t; Vault.save(t); await refreshAccount()
    }
    func refreshAccount() async {
        guard !token.isEmpty, let d = try? await request("me", authenticated: true) as? [String: Any] else { return }
        account = d["name"] as? String ?? "Аккаунт"
        premium = (d["isPremium"] as? NSNumber)?.boolValue ?? (d["isPremium"] as? Bool)
        premiumUntil = (d["premiumUntil"] as? String).flatMap { Episode.dates.date(from: $0) }
    }
    func logout() { token = ""; account = "Войти"; premium = nil; premiumUntil = nil; Vault.save("") }
    // Образец для проверки серверов: последняя включённая серия (её ссылка 720p или ближайшая).
    func serverSample() async throws -> URL {
        guard let t = HistoryState.loadJSON("lp-translation") as? [String: Any], let id = (t["id"] as? NSNumber)?.intValue, id > 0 else { throw APIError(message: "Сначала включите любую серию — по ней проверяются серверы") }
        let d = try await embed(Translation(["id": id]))
        let streams = (d["stream"] as? [[String: Any]] ?? []).compactMap { o -> (Int, URL)? in guard let s = (o["urls"] as? [String])?.first, let u = makeURL(s) else { return nil }; return ((o["height"] as? NSNumber)?.intValue ?? 0, u) }
        Servers.remember(streams.map(\.1))
        guard let pick = streams.min(by: { abs($0.0 - 720) < abs($1.0 - 720) }) else { throw APIError(message: "Сайт не дал ссылку на видео — проверьте подписку") }
        return pick.1
    }
    func list(_ query: String, offset: Int = 0) async throws -> [AnimeItem] {
        #if DEBUG
        if let dir = QA.value("--fixtures") { return offset > 0 ? [] : Fixtures.items(dir) }
        #endif
        var p = ["limit": "24", "offset": "\(offset)", "isActive": "1"]
        if query.isEmpty { p["isAiring"] = "1" } else { p["query"] = query }
        let a = try await request("series", p) as? [[String: Any]] ?? []
        return a.filter { ($0["isHentai"] as? Int ?? 0) == 0 }.map(AnimeItem.init)
    }
    // Полки главной и поиска: те же фильтры, что у сайта (год, тип, жанр); сайт сортирует по рейтингу.
    nonisolated static let cardFields = "id,titles,posterUrl,posterUrlSmall,typeTitle,year,myAnimeListScore,season,genres,isHentai"
    func shelf(_ params: [String: String], offset: Int = 0, limit: Int = 24) async throws -> [AnimeItem] {
        #if DEBUG
        if let dir = QA.value("--fixtures") { return offset > 0 ? [] : Fixtures.items(dir).shuffled(seed: params.description) }
        #endif
        var p = params; p["limit"] = "\(limit)"; p["offset"] = "\(offset)"; p["isActive"] = "1"
        if p["fields"] == nil { p["fields"] = Self.cardFields }
        let a = try await request("series", p) as? [[String: Any]] ?? []
        return a.filter { ($0["isHentai"] as? Int ?? 0) == 0 }.map(AnimeItem.init)
    }
    // Полная карточка аниме: описание, жанры и список серий.
    func details(_ item: AnimeItem) async throws -> (AnimeItem, [Episode]) {
        #if DEBUG
        if QA.value("--fixtures") != nil { return (Fixtures.detailed(item), Fixtures.episodes()) }
        #endif
        let d = try await request("series/\(item.id)") as? [String: Any] ?? [:]
        let all = (d["episodes"] as? [[String: Any]] ?? []).filter { ($0["isActive"] as? Int ?? 0) == 1 }.map(Episode.init)
        let regular = Episode.regular(all)
        let episodes = all.sorted { (regular.contains($0.id) ? 0 : 1, $0.number) < (regular.contains($1.id) ? 0 : 1, $1.number) }  // трейлеры и спецвыпуски — в конце
        if !d.isEmpty { rememberEpisodes(item.id, episodes) }
        return (d.isEmpty ? item : AnimeItem(d), episodes)
    }
    // «Серии» без трейлеров и спецвыпусков (SP). Досмотренным считается аниме, у которого просмотрена
    // последняя из вышедших серий — пропущенные в начале не мешают. Тогда оно уходит из «Продолжить просмотр».
    func rememberEpisodes(_ id: Int, _ episodes: [Episode]) {
        let regular = Episode.regular(episodes)
        let last = episodes.last { regular.contains($0.id) }
        UserDefaults.standard.set(last?.id ?? 0, forKey: "final-\(id)"); UserDefaults.standard.set(Date(), forKey: "final-ts-\(id)")
    }
    func finished(_ item: AnimeItem) -> Bool { let f = UserDefaults.standard.integer(forKey: "final-\(item.id)"); return f != 0 && isDone(f) }
    // Список серий старше 12 часов перечитывается: у онгоинга могла выйти новая серия, и аниме вернётся на полку.
    func refreshFinished() async {
        let stale = history.filter { lastEpisode($0) != 0 && Date().timeIntervalSince(UserDefaults.standard.object(forKey: "final-ts-\($0.id)") as? Date ?? .distantPast) > 12 * 3600 }.prefix(20)
        var changed = false
        for item in stale { let was = finished(item); if let list = try? await episodes(item) { changed = changed || was != finished(item); _ = list } }
        if changed { objectWillChange.send() }
    }
    // Сезоны франшизы, как в блоке связанных частей на странице аниме на сайте Anime 365.
    // В API этого блока нет: читаем открытую страницу каталога и берём ТВ-сериалы основной линии.
    func seasons(_ item: AnimeItem) async -> [Season] {
        if let cached = seasonCache[item.id] { return cached }
        #if DEBUG
        if QA.value("--fixtures") != nil { return [] }
        #endif
        var r = URLRequest(url: URL(string: "https://smotret-anime.co/catalog/\(item.id)")!); r.setValue("NightAnime/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: r), let html = String(data: data, encoding: .utf8) else { return [] }
        let pattern = #"<li class="m-connections-list__item( m-connections-list__item_current)?"><a href="/catalog/[^"]*?-(\d+)">.*?</a>\s*<span class="m-connections-list__type">(.*?)</span>[^<]*(?:<span class="m-connections-list__type">(.*?)</span>,\s*)?<span class="m-connections-list__year">(\d*)</span>"#
        guard let rx = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return [] }
        let ns = html as NSString; var order: [Int] = [], years: [Int: Int] = [:], current = 0
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        for m in rx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let cur = group(m, 1) != nil, rel = group(m, 4)
            guard group(m, 3) == "ТВ сериал", cur || rel == nil || ["основная история", "продолжение", "предыстория"].contains(rel!), let sid = Int(group(m, 2) ?? "") else { continue }
            if cur { current = sid }
            if years[sid] == nil { order.append(sid); years[sid] = Int(group(m, 5) ?? "") ?? 0 }
        }
        guard order.count > 1, current != 0 else { seasonCache[item.id] = []; return [] }
        let query = "series?fields=" + Self.cardFields + ",descriptions" + order.map { "&id[]=\($0)" }.joined()
        guard let list = try? await request(query) as? [[String: Any]] else { return [] }
        let items = Dictionary(list.map { (($0["id"] as? NSNumber)?.intValue ?? 0, AnimeItem($0)) }, uniquingKeysWith: { a, _ in a })
        // Порядок как на сайте, но по годам выхода: сайт показывает дерево, а не хронологию.
        let sorted = order.filter { items[$0] != nil }.enumerated().sorted { (years[$0.1] == 0 ? Int.max : years[$0.1]!, $0.0) < (years[$1.1] == 0 ? Int.max : years[$1.1]!, $1.0) }.map(\.1)
        let result = sorted.enumerated().map { i, sid -> Season in
            let a = items[sid]!; let n = a.title.range(of: #"(\d+)\s*сезон"#, options: .regularExpression).map { String(a.title[$0]).components(separatedBy: CharacterSet.decimalDigits.inverted).joined() }
            return Season(id: sid, label: n.map { "\($0) сезон" } ?? (i == 0 ? "1 сезон" : a.title), current: sid == current, item: a)
        }
        let out = result.count > 1 ? result : []
        seasonCache[item.id] = out; return out
    }
    func episodes(_ item: AnimeItem) async throws -> [Episode] { try await details(item).1 }
    // Расписание: аниме, которые сейчас выходят, по дню недели последней вышедшей серии.
    func schedule() async throws -> [(weekday: Int, items: [(AnimeItem, Episode)])] {
        var raw: [[String: Any]]
        #if DEBUG
        if let dir = QA.value("--fixtures") { raw = Fixtures.items(dir).enumerated().map { i, item in var o = item.object; o["episodes"] = [["id": 1, "episodeFull": "\(i + 3) серия", "episodeInt": i + 3, "isActive": 1, "firstUploadedDateTime": Episode.dates.string(from: Date().addingTimeInterval(Double(-i) * 86400 * 1.3))]]; return o } } else { raw = [] }
        if QA.value("--fixtures") == nil { raw = try await request("series", ["isAiring": "1", "isActive": "1", "limit": "60", "fields": Self.cardFields + ",episodes"]) as? [[String: Any]] ?? [] }
        #else
        raw = try await request("series", ["isAiring": "1", "isActive": "1", "limit": "60", "fields": Self.cardFields + ",episodes"]) as? [[String: Any]] ?? []
        #endif
        let calendar = Calendar.current
        var days: [Int: [(AnimeItem, Episode)]] = [:]
        for o in raw where (o["isHentai"] as? Int ?? 0) == 0 {
            let eps = (o["episodes"] as? [[String: Any]] ?? []).map(Episode.init).filter { $0.uploaded != nil }
            guard let last = eps.max(by: { $0.uploaded! < $1.uploaded! }), last.uploaded! > Date().addingTimeInterval(-21 * 86400) else { continue }
            days[calendar.component(.weekday, from: last.uploaded!), default: []].append((AnimeItem(o), last))
        }
        let today = calendar.component(.weekday, from: Date())
        return (0..<7).map { (today - 1 + $0) % 7 + 1 }.compactMap { d in days[d].map { (d, $0.sorted { $0.1.uploaded! > $1.1.uploaded! }) } }
    }
    // Прогресс серий и выбранный перевод — те же ключи и правила, что в Android-версии.
    func lastEpisode(_ item: AnimeItem) -> Int { UserDefaults.standard.integer(forKey: "last-\(item.id)") }
    func isDone(_ episode: Int) -> Bool { UserDefaults.standard.bool(forKey: "done-\(episode)") }
    func markDone(_ episode: Int) { UserDefaults.standard.set(true, forKey: "done-\(episode)"); objectWillChange.send() }
    func lastEpisodeTitle(_ item: AnimeItem) -> String? { guard lastEpisode(item) != 0, let o = HistoryState.loadJSON("lp-episode") as? [String: Any], (o["id"] as? NSNumber)?.intValue == lastEpisode(item) else { return nil }; return o["episodeFull"] as? String }
    // Новые серии в избранном: count — сколько серий на сайте, known — сколько было при последнем открытии аниме.
    func hasNew(_ item: AnimeItem) -> Bool { let d = UserDefaults.standard; guard d.object(forKey: "known-\(item.id)") != nil else { return false }; return d.integer(forKey: "count-\(item.id)") > d.integer(forKey: "known-\(item.id)") }
    func seen(_ item: AnimeItem, count: Int) { UserDefaults.standard.set(count, forKey: "count-\(item.id)"); UserDefaults.standard.set(count, forKey: "known-\(item.id)") }
    func checkNewEpisodes() async {
        let d = UserDefaults.standard
        guard HistoryState.now() - HistoryState.int64("checked") > 3_600_000 else { return }
        d.set(HistoryState.now(), forKey: "checked")
        for item in favorites.prefix(30) {
            guard let n = try? await episodes(item).count else { continue }
            d.set(n, forKey: "count-\(item.id)"); if d.object(forKey: "known-\(item.id)") == nil { d.set(n, forKey: "known-\(item.id)") }
        }
        objectWillChange.send()
    }
    func sync() async { await TVSync.run(self) }
    func rememberedTranslation(_ item: AnimeItem) -> String { UserDefaults.standard.string(forKey: "tr-\(item.id)") ?? "" }
    func translations(_ episode: Episode, for item: AnimeItem) async throws -> [Translation] {
        #if DEBUG
        if QA.value("--fixtures") != nil { return Fixtures.translations() }
        #endif
        let a = try await request("translations", ["episodeId": "\(episode.id)", "isActive": "1", "limit": "100"]) as? [[String: Any]] ?? []
        return Translation.clean(a.map(Translation.init), remembered: rememberedTranslation(item))
    }
    func embed(_ t: Translation) async throws -> [String: Any] { try await request("translations/embed/\(t.id)", authenticated: true) as? [String: Any] ?? [:] }
    func makeURL(_ s: String) -> URL? { guard let u = URL(string: s, relativeTo: URL(string: base))?.absoluteURL, ["https", "http"].contains(u.scheme) else { return nil }; return u }
    // Прогресс серии для полосок «досмотрено на …»: доля от 0 до 1, пишет плеер.
    func fraction(_ episode: Int) -> Double { isDone(episode) ? 1 : UserDefaults.standard.double(forKey: "watch-\(episode)") }
    // Серия, с которой продолжать: последняя начатая, а если она досмотрена — следующая.
    func resumeEpisode(_ item: AnimeItem, in episodes: [Episode]) -> Episode? {
        let last = lastEpisode(item)
        guard let i = episodes.firstIndex(where: { $0.id == last && !$0.trailer }) else { return episodes.first }
        return isDone(last) && i + 1 < episodes.count && !episodes[i + 1].trailer ? episodes[i + 1] : episodes[i]
    }
    // Запоминает начатую серию: по этим ключам работают «Продолжить», синхронизация и плитка на ТВ.
    func remember(_ t: Translation, _ e: Episode, _ item: AnimeItem) {
        watched(item)
        let defaults = UserDefaults.standard
        defaults.set(e.id, forKey: "last-\(item.id)"); defaults.set(t.signature, forKey: "tr-\(item.id)"); defaults.set(HistoryState.now(), forKey: "stamp-\(item.id)")
        defaults.set(item.raw, forKey: "lp-item"); HistoryState.storeJSON(["id": e.id, "episodeFull": e.title, "episodeInt": e.number], "lp-episode")
        HistoryState.storeJSON(["id": t.id, "type": t.kind, "authorsSummary": String(t.signature.split(separator: "|", maxSplits: 1).last ?? "")], "lp-translation"); defaults.set(HistoryState.now(), forKey: "lp-t")
    }
    func playback(_ t: Translation, _ e: Episode, _ item: AnimeItem) async throws -> Playback {
        let d = try await embed(t)
        var options: [VideoOption] = []
        for stream in d["stream"] as? [[String: Any]] ?? [] {
            let h = (stream["height"] as? NSNumber)?.intValue ?? 0
            let sources = (stream["urls"] as? [String] ?? []).compactMap(makeURL)
            Servers.remember(sources)
            // Самый быстрый сервер первым, ссылки сайта — запасные.
            let ordered = sources.flatMap(Servers.preferred)
            if let first = ordered.first { options.append(VideoOption(id: "stream-\(h)", url: first, height: h, alternatives: Array(ordered.dropFirst()))) }
        }
        for stream in d["download"] as? [[String: Any]] ?? [] {
            if let s = stream["url"] as? String, let u = makeURL(s) {
                let h = (stream["height"] as? NSNumber)?.intValue ?? 0
                if let i = options.firstIndex(where: { $0.height == h }) { options[i].alternatives.append(u) }
                else { options.append(VideoOption(id: "direct-\(h)", url: u, height: h)) }
            }
        }
        guard !options.isEmpty else { throw APIError(message: "Сайт не вернул видео для этого перевода. Проверьте подписку или выберите другой перевод.") }
        options.sort { $0.height > $1.height }
        let sub = (d["subtitlesUrl"] as? String).flatMap(makeURL)
        if t.kind.hasPrefix("sub") && sub == nil { throw APIError(message: "Для этого перевода нет ссылки на субтитры. Выберите другой перевод.") }
        remember(t, e, item)
        return Playback(options: options, subtitles: sub, title: "\(item.title) · \(e.title)", key: "position-\(t.id)", episodeId: e.id)
    }
}

#if DEBUG
// Тестовые данные для проверки вёрстки без сети: --fixtures=<папка с poster1…5.png и poster-wide.png>.
enum Fixtures {
    static let titles = ["Тикава", "Невероятное приключение ДжоДжо: Гонка «Стальной шар»", "Блич: Тысячелетняя кровавая война — Бедствие", "Ван-Пис", "Монолог фармацевта 3 сезон", "Хололайв: Альтернатива", "Боевой континент 2: Непревзойдённый клан Тан", "Детектив Конан", "Расколотая битвой синева небес 5", "Ао Аси 2 сезон"]
    static func items(_ dir: String) -> [AnimeItem] {
        titles.enumerated().map { i, t in
            let poster = i == 5 ? "poster-wide.png" : "poster\(i % 5 + 1).png"
            let file = URL(fileURLWithPath: dir).appendingPathComponent(poster).absoluteString
            return AnimeItem(["id": 9000 + i, "titles": ["ru": t], "typeTitle": i % 3 == 0 ? "ТВ сериал" : "ONA", "year": 2020 + i % 7, "season": "Осень \(2020 + i % 7)", "myAnimeListScore": [9.04, 8.71, 7.9, 8.6, 6.2, 8.88, 5.9, 8.2, 7.4, 8.1][i], "posterUrlSmall": file, "posterUrl": file,
                              "genres": [["id": 1, "title": "Экшен"], ["id": 10, "title": "Фэнтези"], ["id": 22, "title": "Романтика"]].prefix(1 + i % 3).map { $0 }])
        }
    }
    static func detailed(_ item: AnimeItem) -> AnimeItem {
        var o = item.object
        o["descriptions"] = [["source": "qa", "value": "Конец девятнадцатого века. Посреди Америки начинается скачка через весь континент, и [character=1]герой[/character] отправляется в путь, чтобы узнать, кто он на самом деле. Длинное описание проверяет, как текст сворачивается до трёх строк и раскрывается по нажатию «Ещё»."]]
        return AnimeItem(o)
    }
    static func episodes() -> [Episode] { (1...12).map { Episode(["id": 7000 + $0, "episodeFull": "ONA \($0) серия", "episodeInt": $0]) } }
}
extension Array {
    // Одинаковый «случайный» порядок для одной и той же полки — чтобы тестовые полки отличались.
    func shuffled(seed: String) -> [Element] { var g = SeededGenerator(seed: UInt64(truncatingIfNeeded: seed.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) })); return shuffled(using: &g) }
}
struct SeededGenerator: RandomNumberGenerator { var state: UInt64; init(seed: UInt64) { state = seed | 1 }; mutating func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state } }
extension Fixtures {
    static func translations() -> [Translation] {
        let raw = [("subRu", "AniLibria"), ("subRu", "AniLibria"), ("subRu", "Crunchyroll, Wakanim, AniMedia, Shiza Project и ещё пять команд переводчиков"), ("voiceRu", "Студийная банда"), ("voiceRu", "AniLibria"), ("raw", ""), ("raw", "Original"), ("subJa", ""), ("subJa", "Netflix"), ("voiceEn", "- Opus 2.0"), ("voiceOther", "")]
            .enumerated().map { i, v in Translation(["id": 8000 + i, "type": v.0, "authorsSummary": v.1, "height": i == 0 ? 2160 : 1080, "priority": 100 - i, "qualityType": i == 4 ? "bd" : "tv"]) }
        return Translation.clean(raw, remembered: "")
    }
}
#endif
