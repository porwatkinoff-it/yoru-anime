import Foundation
import SwiftUI
import AuthenticationServices

// Оценки и ссылки Шикимори. id на Шикимори совпадает с id MyAnimeList, а его Anime 365 отдаёт в myAnimeListId.
// Карточки просят оценку при показе; запросы собираются пачками до 50 id (лимит Шикимори ~5 в секунду),
// результат кэшируется на 3 дня, чтобы главная открывалась без сети к Шикимори.
@MainActor final class Shikimori: ObservableObject {
    static let shared = Shikimori()
    static let site = "https://shikimori.io"
    @Published private(set) var scores: [Int: Double] = [:]
    private var stamps: [Int: Double] = [:]
    private var queue = Set<Int>(), asked = Set<Int>()
    private var running = false
    private static let ttl: Double = 3 * 24 * 3600

    init() {
        if let d = UserDefaults.standard.dictionary(forKey: "shiki-scores") as? [String: [Double]] {
            let now = Date().timeIntervalSince1970
            for (k, v) in d { if let id = Int(k), v.count == 2, now - v[1] < Self.ttl { scores[id] = v[0]; stamps[id] = v[1] } }
        }
    }

    func score(_ item: AnimeItem) -> Double? { item.malId > 0 ? scores[item.malId] : nil }
    func want(_ item: AnimeItem) {
        let id = item.malId
        guard id > 0, scores[id] == nil, !asked.contains(id) else { return }
        #if DEBUG
        if QA.has("--fixtures") { return }
        #endif
        asked.insert(id); queue.insert(id)
        if !running { running = true; Task { await drain() } }
    }
    private func drain() async {
        try? await Task.sleep(for: .milliseconds(400))
        while !queue.isEmpty {
            let ids = Array(queue.prefix(50)); queue.subtract(ids)
            await fetch(ids)
            try? await Task.sleep(for: .milliseconds(400))
        }
        running = false
        save()
    }
    private func fetch(_ ids: [Int]) async {
        guard var c = URLComponents(string: Self.site + "/api/animes") else { return }
        c.queryItems = [URLQueryItem(name: "ids", value: ids.map(String.init).joined(separator: ",")), URLQueryItem(name: "limit", value: "50")]
        guard let url = c.url else { return }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.setValue("Yoru/2.3 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let a = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            asked.subtract(ids); return   // попробуем при следующем показе
        }
        let now = Date().timeIntervalSince1970
        var got: [Int: Double] = [:]
        for o in a {
            guard let id = (o["id"] as? NSNumber)?.intValue else { continue }
            let s = (o["score"] as? String).flatMap(Double.init) ?? (o["score"] as? NSNumber)?.doubleValue ?? 0
            got[id] = s
        }
        // Нет у Шикимори — запоминаем 0, чтобы не спрашивать снова и показывать оценку MAL.
        for id in ids { stamps[id] = now; if got[id] == nil { got[id] = 0 } }
        scores.merge(got) { $1 }
    }
    private func save() {
        var d: [String: [Double]] = [:]
        for (id, s) in scores { d["\(id)"] = [s, stamps[id] ?? 0] }
        UserDefaults.standard.set(d, forKey: "shiki-scores")
    }

    // Ссылка Шикимори, вставленная в поиск: shikimori.one/animes/z52991-sousou-no-frieren, /mangas/2-berserk, /ranobe/….
    enum Link: Equatable { case anime(Int), manga(Int) }
    static func link(_ text: String) -> Link? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t.contains("://") ? t : "https://" + t), let host = u.host?.lowercased(), host.contains("shikimori") else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, let id = Int(parts[1].drop { !$0.isNumber }.prefix { $0.isNumber }), id > 0 else { return nil }
        switch parts[0] { case "animes": return .anime(id); case "mangas", "ranobe": return .manga(id); default: return nil }
    }
    // Аниме: та же запись на Anime 365 по id MyAnimeList. Манга: название с Шикимори → поиск на MangaLib, затем Com-X.
    enum Found { case anime(AnimeItem), manga(MangaItem), title(String) }
    static func resolve(_ link: Link, store: AnimeStore) async throws -> Found? {
        switch link {
        case .anime(let id):
            if let item = try await store.shelf(["myAnimeListId": "\(id)"], limit: 1).first { return .anime(item) }
            return try await info("animes", id).map { .title($0.ru.isEmpty ? $0.en : $0.ru) }
        case .manga(let id):
            var names: (ru: String, en: String)? = try await info("mangas", id)
            if names == nil { names = try await info("ranobe", id) }
            guard let n = names else { return nil }
            // Поиск возвращает похожие тайтлы первыми («Памятник Берсерку»), поэтому ищем точное совпадение названия.
            let norm = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
            let wanted = Set([n.ru, n.en].map(norm).filter { !$0.isEmpty })
            var fallback: MangaItem?
            for q in [n.ru, n.en] where !q.isEmpty {
                for src in MangaSource.allCases {
                    guard let list = try? await MangaAPI.search(src, q, page: 1).0 else { continue }
                    if let m = list.first(where: { wanted.contains(norm($0.title)) || wanted.contains(norm($0.subtitle)) }) { return .manga(m) }
                    if fallback == nil { fallback = list.first }
                }
            }
            if let m = fallback { return .manga(m) }
            return .title(n.ru.isEmpty ? n.en : n.ru)
        }
    }
    private static func info(_ kind: String, _ id: Int) async throws -> (ru: String, en: String)? {
        guard let url = URL(string: site + "/api/\(kind)/\(id)") else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 15); r.setValue("Yoru/2.3 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (o["russian"] as? String ?? "", o["name"] as? String ?? "")
    }

    // Описание с Шикимори — короче и аккуратнее, чем у Anime 365. Разметку [character=…]Имя[/character] убираем.
    @Published private(set) var texts: [Int: String] = [:]
    func text(_ item: AnimeItem) -> String? { texts[item.malId].flatMap { $0.isEmpty ? nil : $0 } }
    func loadText(_ item: AnimeItem) async {
        let id = item.malId
        guard id > 0, texts[id] == nil else { return }
        #if DEBUG
        if QA.has("--fixtures") { return }
        #endif
        let key = "shiki-text-\(id)", d = UserDefaults.standard
        if let v = d.array(forKey: key), v.count == 2, let t = v[0] as? String, let at = v[1] as? Double, Date().timeIntervalSince1970 - at < 7 * 86400 { texts[id] = t; return }
        guard let o = try? await Self.json("/api/animes/\(id)") as? [String: Any] else { return }
        let raw = o["description"] as? String ?? ""
        let t = raw.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression).replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        texts[id] = t
        if let s = (o["score"] as? String).flatMap(Double.init), s > 0 { scores[id] = s; stamps[id] = Date().timeIntervalSince1970 }
        d.set([t, Date().timeIntervalSince1970], forKey: key)
    }

    // Оценка манги и комиксов: ищем тайтл на Шикимори по названию (точное совпадение русского или оригинального).
    // Результат на неделю: [id Шикимори, оценка, время]; 0 — на Шикимори такого нет.
    @Published private(set) var manga: [String: [Double]] = UserDefaults.standard.dictionary(forKey: "shiki-manga") as? [String: [Double]] ?? [:]
    func mangaScore(_ m: MangaItem) -> (id: Int, score: Double)? {
        guard let v = manga[m.id], v.count == 3, v[0] > 0 else { return nil }
        return (Int(v[0]), v[1])
    }
    // Ищем мангу на Шикимори по точному совпадению названия. «Не нашлось» помним только для этого же названия
    // (страница сперва открывается с заглушкой), а сетевые ошибки не кэшируем вовсе.
    func loadManga(_ m: MangaItem) async {
        let sig = Self.norm(m.title) + "|" + Self.norm(m.subtitle)
        if let v = manga[m.id], v.count == 3, Date().timeIntervalSince1970 - v[2] < 7 * 86400, v[0] > 0 || UserDefaults.standard.string(forKey: "shiki-manga-miss-\(m.id)") == sig { return }
        #if DEBUG
        if QA.has("--fixtures") { return }
        #endif
        let wanted = Set([m.title, m.subtitle].map(Self.norm).filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return }
        var found: [String: Any]?, failed = false
        for q in [m.title, m.subtitle] where !q.isEmpty && found == nil {
            for kind in ["mangas", "ranobe"] where found == nil {
                var c = URLComponents(); c.queryItems = [URLQueryItem(name: "search", value: q), URLQueryItem(name: "limit", value: "8")]
                guard let a = try? await Self.json("/api/\(kind)?" + (c.percentEncodedQuery ?? "")) as? [[String: Any]] else { failed = true; continue }
                if let hit = a.first(where: { wanted.contains(Self.norm($0["russian"] as? String ?? "")) || wanted.contains(Self.norm($0["name"] as? String ?? "")) }) {
                    found = hit; UserDefaults.standard.set(kind, forKey: "shiki-manga-kind-\(m.id)")
                }
            }
        }
        if Task.isCancelled || (found == nil && failed) { return }
        let id = (found?["id"] as? NSNumber)?.doubleValue ?? 0
        let score = (found?["score"] as? String).flatMap(Double.init) ?? 0
        manga[m.id] = [id, score, Date().timeIntervalSince1970]
        UserDefaults.standard.set(sig, forKey: "shiki-manga-miss-\(m.id)")
        UserDefaults.standard.set(manga, forKey: "shiki-manga")
    }
    static func mangaURL(_ m: MangaItem) -> URL? {
        guard let s = shared.mangaScore(m) else { return nil }
        return URL(string: site + "/" + (UserDefaults.standard.string(forKey: "shiki-manga-kind-\(m.id)") ?? "mangas") + "/\(s.id)")
    }
    nonisolated static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
    static func json(_ path: String) async throws -> Any {
        guard let url = URL(string: site + path) else { throw URLError(.badURL) }
        var r = URLRequest(url: url, timeoutInterval: 15); r.setValue("Yoru/2.3 (iOS)", forHTTPHeaderField: "User-Agent")
        // Шикимори пускает ~5 запросов в секунду: на 429 ждём и пробуем ещё раз.
        for attempt in 0..<3 {
            let (data, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 && attempt < 2 { try await Task.sleep(for: .milliseconds(700 * (attempt + 1))); continue }
            guard code == 200 else { throw URLError(.badServerResponse) }
            return try JSONSerialization.jsonObject(with: data)
        }
        throw URLError(.badServerResponse)
    }

    static func url(_ item: AnimeItem) -> URL? { item.malId > 0 ? URL(string: site + "/animes/\(item.malId)") : search(item.title) }
    static func search(_ q: String) -> URL? {
        var c = URLComponents(string: site + "/animes"); c?.queryItems = [URLQueryItem(name: "search", value: q)]; return c?.url
    }
}

// Есть ли у аниме 4K: последние переводы сериала (новые серии обычно выходят в лучшем качестве).
// Карточки спрашивают при показе, не больше трёх запросов сразу; ответ хранится двое суток.
@MainActor final class UHD: ObservableObject {
    static let shared = UHD()
    @Published private(set) var known: [Int: Bool] = [:]
    private var stamps: [Int: Double] = [:]
    private var queue: [Int] = [], asked = Set<Int>(), running = 0
    private static let ttl: Double = 2 * 24 * 3600
    init() {
        let now = Date().timeIntervalSince1970
        for (k, v) in UserDefaults.standard.dictionary(forKey: "uhd-cache2") as? [String: [Double]] ?? [:] {
            if let id = Int(k), v.count == 2, now - v[1] < Self.ttl { known[id] = v[0] > 0; stamps[id] = v[1] }
        }
    }
    func has(_ item: AnimeItem) -> Bool { known[item.id] == true }
    func set(_ id: Int, _ value: Bool) { known[id] = value; stamps[id] = Date().timeIntervalSince1970; save() }
    func want(_ item: AnimeItem, store: AnimeStore) {
        let id = item.id
        guard id > 0, known[id] == nil, !asked.contains(id) else { return }
        #if DEBUG
        if QA.has("--fixtures") { return }
        #endif
        asked.insert(id); queue.append(id); pump(store)
    }
    private func pump(_ store: AnimeStore) {
        while running < 3, !queue.isEmpty {
            let id = queue.removeFirst(); running += 1
            Task {
                if let a = try? await store.request("translations", ["seriesId": "\(id)", "isActive": "1", "limit": "1000", "fields": "height"]) as? [[String: Any]] {
                    known[id] = a.contains { (($0["height"] as? NSNumber)?.intValue ?? 0) >= 2160 }; stamps[id] = Date().timeIntervalSince1970
                } else { asked.remove(id) }
                running -= 1
                if queue.isEmpty && running == 0 { save() } else { pump(store) }
            }
        }
    }
    private func save() {
        var d: [String: [Double]] = [:]
        for (id, v) in known { d["\(id)"] = [v ? 1 : 0, stamps[id] ?? 0] }
        UserDefaults.standard.set(d, forKey: "uhd-cache2")
    }
}

// MARK: Аккаунт Шикимори
// Вход через OAuth (ключи приложения — из Info.plist, их подставляет generate-project.py из локального файла).
// Токены лежат в связке ключей. Оценка и прогресс уходят в список пользователя: «смотрю» или «просмотрено».
// Список оценённого и просмотренного подтягивается в «Моё».
struct ShikiRate: Identifiable, Codable, Equatable {
    var id: Int            // id записи user_rate
    var malId: Int
    var title: String
    var subtitle: String
    var poster: String
    var kind: String
    var total: Int
    var score: Int
    var status: String
    var episodes: Int
    var siteScore: Double
    var updated: String
    static let statuses: [(String, String)] = [("watching", "Смотрю"), ("rewatching", "Пересматриваю"), ("completed", "Просмотрено"), ("planned", "Запланировано"), ("on_hold", "Отложено"), ("dropped", "Брошено")]
    static func statusTitle(_ s: String) -> String { statuses.first { $0.0 == s }?.1 ?? s }
    init?(_ o: [String: Any]) {
        guard let id = (o["id"] as? NSNumber)?.intValue, let a = o["anime"] as? [String: Any], let mal = (a["id"] as? NSNumber)?.intValue else { return nil }
        self.id = id; malId = mal
        title = (a["russian"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? a["name"] as? String ?? ""
        subtitle = a["name"] as? String ?? ""
        let img = (a["image"] as? [String: Any])?["original"] as? String ?? ""
        poster = img.isEmpty ? "" : (img.hasPrefix("http") ? img : Shikimori.site + img)
        kind = a["kind"] as? String ?? ""
        total = (a["episodes"] as? NSNumber)?.intValue ?? 0
        score = (o["score"] as? NSNumber)?.intValue ?? 0
        status = o["status"] as? String ?? ""
        episodes = (o["episodes"] as? NSNumber)?.intValue ?? 0
        siteScore = (a["score"] as? String).flatMap(Double.init) ?? 0
        updated = o["updated_at"] as? String ?? ""
    }
}

@MainActor final class ShikiAccount: ObservableObject {
    static let shared = ShikiAccount()
    static let redirect = "yoru://shikimori"
    static let agent = "Yoru/2.3 (iOS)"
    private static let vault = "com.resvvt.nightanime.shikimori"
    @Published private(set) var nickname = UserDefaults.standard.string(forKey: "shiki-nick") ?? ""
    @Published private(set) var userId = UserDefaults.standard.integer(forKey: "shiki-user")
    @Published private(set) var rates: [Int: ShikiRate] = [:]     // по malId
    @Published private(set) var loading = false
    @Published var message = ""
    private var tokens: [String: Any] = [:]

    // Ключи приложения Шикимори: из сборки (shikimori.local.json) или введённые один раз на экране «Подключить Шикимори».
    @Published private(set) var appKeys: [String: String] = [:]
    var clientId: String { let v = Self.info("ShikimoriClientId"); return v.isEmpty ? appKeys["id"] ?? "" : v }
    var clientSecret: String { let v = Self.info("ShikimoriClientSecret"); return v.isEmpty ? appKeys["secret"] ?? "" : v }
    var configured: Bool { !clientId.isEmpty && !clientSecret.isEmpty }
    var builtIn: Bool { !Self.info("ShikimoriClientId").isEmpty && !Self.info("ShikimoriClientSecret").isEmpty }
    func setAppKeys(id: String, secret: String) {
        appKeys = ["id": id, "secret": secret]
        Self.saveKeychain(try? JSONSerialization.data(withJSONObject: appKeys), account: "app")
    }
    var signedIn: Bool { userId > 0 && tokens["access_token"] is String }
    private static func info(_ k: String) -> String { let v = Bundle.main.object(forInfoDictionaryKey: k) as? String ?? ""; return v.hasPrefix("$(") ? "" : v }

    init() {
        if let d = Self.keychain(), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { tokens = o }
        if let d = Self.keychain(account: "app"), let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] { appKeys = o }
        if let d = UserDefaults.standard.data(forKey: "shiki-rates"), let list = try? JSONDecoder().decode([ShikiRate].self, from: d) {
            rates = Dictionary(list.map { ($0.malId, $0) }, uniquingKeysWith: { a, _ in a })
        }
        #if DEBUG
        // Демо для проверки вида без ключей приложения: запись в сеть не пройдёт, но экраны видны.
        if QA.has("--shiki-demo") {
            userId = 1; nickname = "demo"; tokens = ["access_token": "demo", "expires_at": 9e12]
            let a: [[String: Any]] = [["id": 1, "score": 10, "status": "completed", "episodes": 28, "updated_at": "2026-11-10", "anime": ["id": 52991, "russian": "Провожающая в последний путь Фрирен", "name": "Sousou no Frieren", "kind": "tv", "episodes": 28, "score": "9.25", "image": ["original": "/system/animes/original/52991.jpg"]]],
                                      ["id": 2, "score": 0, "status": "watching", "episodes": 3, "updated_at": "2026-11-15", "anime": ["id": 59978, "russian": "Провожающая в последний путь Фрирен 2", "name": "Sousou no Frieren 2nd Season", "kind": "tv", "episodes": 10, "score": "8.9", "image": ["original": "/system/animes/original/59978.jpg"]]],
                                      ["id": 3, "score": 9, "status": "completed", "episodes": 64, "updated_at": "2026-10-01", "anime": ["id": 5114, "russian": "Стальной алхимик: Братство", "name": "Fullmetal Alchemist: Brotherhood", "kind": "tv", "episodes": 64, "score": "9.1", "image": ["original": "/system/animes/original/5114.jpg"]]]]
            rates = Dictionary(a.compactMap(ShikiRate.init).map { ($0.malId, $0) }, uniquingKeysWith: { a, _ in a })
        }
        #endif
    }
    var authorizeURL: URL? {
        var c = URLComponents(string: Shikimori.site + "/oauth/authorize")
        c?.queryItems = [URLQueryItem(name: "client_id", value: clientId), URLQueryItem(name: "redirect_uri", value: Self.redirect),
                         URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "scope", value: "user_rates")]
        return c?.url
    }
    // Вызывается с адресом, на который Шикимори вернул после входа: yoru://shikimori?code=…
    func finish(_ callback: URL) async throws {
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw APIError(message: "Шикимори не вернул код входа")
        }
        try await token(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect])
        let me = try await call("GET", "/api/users/whoami") as? [String: Any]
        guard let id = (me?["id"] as? NSNumber)?.intValue else { throw APIError(message: "Не удалось узнать пользователя Шикимори") }
        userId = id; nickname = me?["nickname"] as? String ?? ""
        UserDefaults.standard.set(id, forKey: "shiki-user"); UserDefaults.standard.set(nickname, forKey: "shiki-nick")
        YoruAccount.shared.vaultChanged("shikimori")
        await refresh()
    }
    func signOut() {
        tokens = [:]; Self.saveKeychain(nil); userId = 0; nickname = ""; rates = [:]
        for k in ["shiki-user", "shiki-nick", "shiki-rates"] { UserDefaults.standard.removeObject(forKey: k) }
    }
    // Вход для аккаунта Yoru (общий формат с Mac и Android): ключи приложения и токены, шифруются паролем Yoru.
    func vaultPayload() -> Data? {
        guard signedIn, let access = tokens["access_token"] as? String else { return nil }
        let o: [String: Any] = ["id": clientId, "secret": clientSecret, "access": access, "refresh": tokens["refresh_token"] as? String ?? "",
                                "expires": Int64(((tokens["expires_at"] as? NSNumber)?.doubleValue ?? 0) * 1000), "userId": userId, "nickname": nickname]
        return try? JSONSerialization.data(withJSONObject: o)
    }
    // Вход пришёл из аккаунта Yoru; nil — «Выйти везде» на другом устройстве.
    func install(_ data: Data?) {
        guard let data else { return signOut() }
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let id = o["id"] as? String, let secret = o["secret"] as? String, !id.isEmpty, !secret.isEmpty, !builtIn { setAppKeys(id: id, secret: secret) }
        guard let access = o["access"] as? String, !access.isEmpty, let uid = (o["userId"] as? NSNumber)?.intValue, uid > 0 else { return }
        if uid != userId { rates = [:]; save() }
        tokens = ["access_token": access, "refresh_token": o["refresh"] as? String ?? "", "expires_at": ((o["expires"] as? NSNumber)?.doubleValue ?? 0) / 1000]
        Self.saveKeychain(try? JSONSerialization.data(withJSONObject: tokens))
        userId = uid; nickname = o["nickname"] as? String ?? ""
        UserDefaults.standard.set(uid, forKey: "shiki-user"); UserDefaults.standard.set(nickname, forKey: "shiki-nick")
    }
    func rate(_ item: AnimeItem) -> ShikiRate? { item.malId > 0 ? rates[item.malId] : nil }
    var list: [ShikiRate] { rates.values.sorted { $0.updated > $1.updated } }

    // Весь список пользователя (до 5000 записей за раз хватает с запасом).
    func refresh() async {
        guard signedIn else { return }
        #if DEBUG
        if QA.has("--shiki-demo") { return }
        #endif
        loading = true; defer { loading = false }
        do {
            guard let a = try await call("GET", "/api/users/\(userId)/anime_rates?limit=5000") as? [[String: Any]] else { return }
            rates = Dictionary(a.compactMap(ShikiRate.init).map { ($0.malId, $0) }, uniquingKeysWith: { a, _ in a })
            save(); message = ""
        } catch { message = error.localizedDescription }
    }
    // Оценка с телефона: создаёт или меняет запись. Статус — по тому, что посмотрено в приложении.
    func setScore(_ score: Int, for item: AnimeItem, watched: Int) async {
        guard signedIn, item.malId > 0 else { return }
        var fields: [String: Any] = ["score": score]
        let old = rates[item.malId]
        if old == nil || old?.status == "planned" { fields["status"] = Self.status(item, watched: watched) }
        if watched > (old?.episodes ?? 0) { fields["episodes"] = watched }
        await write(item, fields)
    }
    // Серия досмотрена: прогресс и статус «смотрю» → «просмотрено» на последней серии вышедшего тайтла.
    func episodeDone(_ item: AnimeItem, number: Int) async {
        guard signedIn, item.malId > 0, number > 0 else { return }
        let old = rates[item.malId]
        guard number > (old?.episodes ?? 0) || old?.status == "planned" else { return }
        var fields: [String: Any] = ["episodes": max(number, old?.episodes ?? 0)]
        if old?.status != "completed" && old?.status != "rewatching" { fields["status"] = Self.status(item, watched: number) }
        await write(item, fields)
    }
    func setStatus(_ status: String, for item: AnimeItem) async { await write(item, ["status": status]) }
    // Перенос того, что уже посмотрено в Yoru: история → «Смотрю»/«Просмотрено» с числом серий.
    // Только увеличивает прогресс; «Просмотрено» и «Пересматриваю» на Шикимори не трогает.
    @discardableResult
    // При запуске проверяются только тайтлы, где с прошлого раза что-то смотрели (метка stamp-) или изменилась запись на Шикимори.
    func importLocal(_ store: AnimeStore, all: Bool = false) async -> Int {
        guard signedIn else { return 0 }
        let d = UserDefaults.standard
        var pushed = d.dictionary(forKey: "shiki-pushed") as? [String: String] ?? [:]
        defer { d.set(pushed, forKey: "shiki-pushed") }
        var sent = 0
        for item in store.history.prefix(60) where item.malId > 0 {
            let r = rates[item.malId]
            let stamp = "\(d.object(forKey: "stamp-\(item.id)") ?? "")|\(r?.status ?? ""):\(r?.episodes ?? 0)"
            if !all && pushed["\(item.id)"] == stamp { continue }
            pushed["\(item.id)"] = stamp
            if let s = r?.status, s == "completed" || s == "rewatching" { continue }
            guard let (full, episodes) = try? await store.details(item) else { pushed["\(item.id)"] = nil; continue }
            let regular = Episode.regular(episodes)
            let done = episodes.filter { regular.contains($0.id) && store.isDone($0.id) }.map { Int($0.number) }.max() ?? 0
            let started = store.lastEpisode(item) != 0
            let old = rates[item.malId]
            if done > 0 && (done > (old?.episodes ?? 0) || old == nil || old?.status == "planned") {
                await episodeDone(full, number: done); sent += 1
            } else if done == 0, started, old == nil || old?.status == "planned" {
                await write(full, ["status": "watching"]); sent += 1
            }
        }
        return sent
    }
    // Обратная сторона: что отмечено на Шикимори, отмечается просмотренным в Yoru. «Просмотрено» — все серии,
    // «Смотрю»/«Отложено»/«Брошено» — первые N серий; аниме в процессе появляется в «Продолжить просмотр».
    // Уже перенесённое (статус и число серий не менялись) пропускается; за раз — до 40 тайтлов, остальное в следующий раз.
    @discardableResult
    func pullToApp(_ store: AnimeStore) async -> Int {
        guard signedIn else { return 0 }
        #if DEBUG
        if QA.has("--shiki-demo") { return 0 }
        #endif
        let d = UserDefaults.standard
        var pulled = d.dictionary(forKey: "shiki-pulled") as? [String: String] ?? [:]
        var map = d.dictionary(forKey: "shiki-map") as? [String: Int] ?? [:]
        var changed = 0, budget = 40
        for r in list where r.status != "planned" && (r.episodes > 0 || r.status == "completed") {
            let key = "\(r.malId)", stamp = "\(r.status):\(r.episodes)"
            guard pulled[key] != stamp, budget > 0 else { continue }
            budget -= 1
            var item: AnimeItem?
            if let id = map[key], let h = store.history.first(where: { $0.id == id }) { item = h }
            if item == nil { item = try? await store.shelf(["myAnimeListId": key], limit: 1).first }
            guard let base = item else { pulled[key] = stamp; continue }      // нет на Anime 365
            map[key] = base.id
            guard let (full, episodes) = try? await store.details(base), !episodes.isEmpty else { continue }
            let regular = Episode.regular(episodes)
            let limit = r.status == "completed" || r.status == "rewatching" && r.episodes == 0 ? Int.max : r.episodes
            let list = episodes.filter { regular.contains($0.id) }.sorted { $0.number < $1.number }
            var marked = false
            for e in list where Int(e.number) <= limit && !store.isDone(e.id) { d.set(true, forKey: "done-\(e.id)"); marked = true }
            if marked { changed += 1; store.rememberEpisodes(full.id, episodes) }
            // В процессе: следующая серия — в «Продолжить просмотр», если в Yoru ещё не начинали.
            if r.status == "watching" || r.status == "rewatching", limit != Int.max, store.lastEpisode(full) == 0,
               let next = list.first(where: { Int($0.number) > limit }) {
                d.set(next.id, forKey: "last-\(full.id)")
                if !store.history.contains(where: { $0.id == full.id }) && store.history.count < 50 { store.history.append(full); store.save("history", store.history) }
            }
            pulled[key] = stamp
        }
        d.set(pulled, forKey: "shiki-pulled"); d.set(map, forKey: "shiki-map")
        if changed > 0 { store.objectWillChange.send() }
        return changed
    }
    // Двусторонний перенос: сначала Шикимори → Yoru, затем Yoru → Шикимори.
    @Published private(set) var syncing = false
    // Перенос по кнопке или после входа: этап и итог показывает плашка внизу на любом экране.
    @Published private(set) var reporting = false
    @Published private(set) var syncStep = ""
    @Published var syncResult = ""
    func syncBoth(_ store: AnimeStore, report: Bool = false) async {
        guard signedIn, !syncing else { return }
        syncing = true; reporting = report; syncResult = ""; if report { message = "" }
        defer { syncing = false; reporting = false }
        syncStep = "Шикимори: загружаю ваш список…"
        await refresh()
        syncStep = "Шикимори: переношу просмотренное в Yoru…"
        let got = await pullToApp(store)
        syncStep = "Шикимори: отправляю просмотренное из Yoru…"
        let sent = await importLocal(store, all: report)
        if got > 0 { await store.sync() }
        if report {
            var parts: [String] = []
            if got > 0 { parts.append("из Шикимори: \(got)") }
            if sent > 0 { parts.append("на Шикимори: \(sent)") }
            message = !message.isEmpty ? message : parts.isEmpty ? "Всё уже совпадает с Шикимори" : "Перенесено " + parts.joined(separator: ", ")
            syncResult = message
        }
    }
    static func status(_ item: AnimeItem, watched: Int) -> String {
        let o = item.object
        let total = (o["numberOfEpisodes"] as? NSNumber)?.intValue ?? 0
        let airing = (o["isAiring"] as? NSNumber)?.boolValue ?? false
        return !airing && total > 0 && watched >= total || watched == 0 ? "completed" : "watching"
    }
    private func write(_ item: AnimeItem, _ fields: [String: Any]) async {
        do {
            let result: Any
            if let old = rates[item.malId] {
                result = try await call("PATCH", "/api/v2/user_rates/\(old.id)", ["user_rate": fields])
            } else {
                var f = fields; f["user_id"] = userId; f["target_id"] = item.malId; f["target_type"] = "Anime"
                result = try await call("POST", "/api/v2/user_rates", ["user_rate": f])
            }
            guard let o = result as? [String: Any], let id = (o["id"] as? NSNumber)?.intValue else { return }
            var r = rates[item.malId] ?? ShikiRate(["id": id, "anime": ["id": item.malId, "russian": item.title, "name": item.subtitle]])!
            r.id = id
            r.score = (o["score"] as? NSNumber)?.intValue ?? r.score
            r.status = o["status"] as? String ?? r.status
            r.episodes = (o["episodes"] as? NSNumber)?.intValue ?? r.episodes
            r.updated = o["updated_at"] as? String ?? ISO8601DateFormatter().string(from: Date())
            if r.poster.isEmpty { r.poster = item.poster }
            if r.total == 0 { r.total = (item.object["numberOfEpisodes"] as? NSNumber)?.intValue ?? 0 }
            rates[item.malId] = r; save(); message = ""
        } catch { message = error.localizedDescription }
    }
    private func save() { if let d = try? JSONEncoder().encode(Array(rates.values)) { UserDefaults.standard.set(d, forKey: "shiki-rates") } }

    // MARK: Сеть
    private func token(_ form: [String: String]) async throws {
        var f = form; f["client_id"] = clientId; f["client_secret"] = clientSecret
        var r = URLRequest(url: URL(string: Shikimori.site + "/oauth/token")!, timeoutInterval: 20)
        r.httpMethod = "POST"; r.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents(); c.queryItems = f.map { URLQueryItem(name: $0.key, value: $0.value) }
        r.httpBody = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, var o = try JSONSerialization.jsonObject(with: data) as? [String: Any], o["access_token"] is String else {
            if code == 400 || code == 401, form["grant_type"] == "refresh_token" {
                // Токены Шикимори одноразовые: если их уже обновило другое устройство, свежие лежат в аккаунте Yoru.
                let old = tokens["refresh_token"] as? String
                if await YoruAccount.shared.recover("shikimori"), tokens["refresh_token"] as? String != old { return }
                signOut(); throw APIError(message: "Вход в Шикимори истёк — войдите снова")
            }
            throw APIError(message: "Шикимори не пустил (\(code))")
        }
        o["expires_at"] = Date().timeIntervalSince1970 + ((o["expires_in"] as? NSNumber)?.doubleValue ?? 86400) - 60
        tokens = o; Self.saveKeychain(try? JSONSerialization.data(withJSONObject: o))
        if signedIn { YoruAccount.shared.vaultChanged("shikimori") }
    }
    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> Any {
        if ((tokens["expires_at"] as? NSNumber)?.doubleValue ?? 0) < Date().timeIntervalSince1970, let refresh = tokens["refresh_token"] as? String {
            try await token(["grant_type": "refresh_token", "refresh_token": refresh])
        }
        guard let access = tokens["access_token"] as? String, let url = URL(string: Shikimori.site + path) else { throw APIError(message: "Войдите в Шикимори") }
        for attempt in 0..<3 {
            var r = URLRequest(url: url, timeoutInterval: 20)
            r.httpMethod = method; r.setValue(Self.agent, forHTTPHeaderField: "User-Agent"); r.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
            if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (data, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 && attempt < 2 { try await Task.sleep(for: .milliseconds(800 * (attempt + 1))); continue }
            if code == 401 { tokens["expires_at"] = 0; throw APIError(message: "Шикимори попросил войти заново") }
            guard (200..<300).contains(code) else { throw APIError(message: "Шикимори ответил ошибкой \(code)") }
            return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)
        }
        throw APIError(message: "Шикимори занят — попробуйте позже")
    }
    private static func keychain(account: String = "oauth") -> Data? {
        var result: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: vault, kSecAttrAccount as String: account, kSecReturnData as String: true]
        return SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }
    private static func saveKeychain(_ data: Data?, account: String = "oauth") {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: vault, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let data else { return }
        var add = q; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
