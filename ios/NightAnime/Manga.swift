import SwiftUI
import UIKit
import WebKit
import CryptoKit
import ImageIO

// MARK: Манга: модели

enum MangaSource: String, CaseIterable, Codable, Identifiable {
    case mangalib, comx
    var id: String { rawValue }
    var title: String { self == .mangalib ? "MangaLib" : "Com-X" }
}
struct MangaItem: Identifiable, Hashable, Codable {
    var source: MangaSource
    // MangaLib: slug_url, Com-X: адрес страницы тайтла (/1234-name.html).
    var key: String
    var title: String
    var subtitle = ""
    var cover = ""
    var meta = ""
    var id: String { source.rawValue + ":" + key }
    static func == (a: MangaItem, b: MangaItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}
struct MangaChapter: Identifiable, Hashable, Codable {
    var id: String
    var volume: String
    var number: String
    var name: String
    var branch: Int? = nil
    var title: String {
        let head = [volume.isEmpty ? nil : "Том \(volume)", number.isEmpty ? nil : "Глава \(number)"].compactMap { $0 }.joined(separator: " · ")
        if head.isEmpty { return name.isEmpty ? "Глава" : name }
        return name.isEmpty ? head : head + " — " + name
    }
    var short: String { number.isEmpty ? (name.isEmpty ? "Глава" : name) : "Глава \(number)" }
}
struct MangaDetails: Codable {
    var item: MangaItem
    var summary = ""
    var tags: [String] = []
    var info: [String] = []
    // Главы по порядку чтения: первая — первой.
    var chapters: [MangaChapter] = []
}
struct MangaError: LocalizedError { let message: String; var errorDescription: String? { message } }

// MARK: MangaLib

enum MangaLib {
    static let api = "https://api.cdnlibs.org/api"
    // img2.imglib.info отдаёт 403 без браузерных cookies, второй сервер сайта отдаёт картинки всем.
    static let images = "https://img3.cdnlibs.org"
    static let redirect = "https://mangalib.me/ru/front/auth/oauth/callback"
    static let session: URLSession = { let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 25; return URLSession(configuration: c) }()

    static func request(_ path: String, _ query: [(String, String)] = [], method: String = "GET", body: [String: Any]? = nil, auth: Bool = true, retry: Bool = true) async throws -> Any {
        var c = URLComponents(string: api + path)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        var r = URLRequest(url: c.url!); r.httpMethod = method
        r.setValue("1", forHTTPHeaderField: "Site-Id"); r.setValue("https://mangalib.me/", forHTTPHeaderField: "Referer"); r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { r.httpBody = try? JSONSerialization.data(withJSONObject: body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let token = auth ? await MangaAccounts.shared.libAccess() : nil
        if let token { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        #if DEBUG
        if QA.has("--manga-offline") { throw MangaError(message: "Не удалось подключиться к MangaLib. Проверьте интернет.") }
        #endif
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: r) } catch { throw MangaError(message: "Не удалось подключиться к MangaLib. Проверьте интернет.") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, token != nil, retry, await MangaAccounts.shared.libRefresh() { return try await request(path, query, method: method, body: body, auth: auth, retry: false) }
        let json = try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(status), let json else {
            if status == 404 || status == 451 || status == 403 { throw MangaError(message: token == nil ? "MangaLib показывает этот тайтл только после входа. Войдите в аккаунт MangaLib." : "MangaLib не отдаёт этот тайтл.") }
            throw MangaError(message: "MangaLib ответил с ошибкой \(status). Повторите позже.")
        }
        return json
    }
    static func item(_ d: [String: Any]) -> MangaItem {
        let cover = d["cover"] as? [String: Any] ?? [:]
        let rus = d["rus_name"] as? String ?? "", name = d["name"] as? String ?? ""
        let type = (d["type"] as? [String: Any])?["label"] as? String ?? ""
        let year = d["releaseDateString"] as? String ?? ""
        let rating = (d["rating"] as? [String: Any])?["averageFormated"] as? String ?? ""
        return MangaItem(source: .mangalib, key: d["slug_url"] as? String ?? "", title: rus.isEmpty ? name : rus, subtitle: rus.isEmpty ? "" : name,
                         cover: cover["default"] as? String ?? cover["md"] as? String ?? cover["thumbnail"] as? String ?? "",
                         meta: [rating.isEmpty ? nil : "★ " + rating, type.isEmpty ? nil : type, year.isEmpty ? nil : String(year.prefix(4))].compactMap { $0 }.joined(separator: " · "))
    }
    static func search(_ q: String, page: Int, swapped: Bool = false) async throws -> ([MangaItem], Bool) {
        var query = [("site_id[]", "1"), ("page", "\(page)"), ("fields[]", "rate_avg"), ("fields[]", "rate")]
        if q.isEmpty { query.append(("sort_by", "views")) } else { query.append(("q", q)) }
        let j = try await request("/manga", query) as? [String: Any] ?? [:]
        let list = (j["data"] as? [[String: Any]] ?? []).map(item).filter { !$0.key.isEmpty }
        let more = (j["meta"] as? [String: Any])?["has_next_page"] as? Bool ?? false
        // «Тфкгещ» вместо «Naruto»: если ничего не нашлось, пробуем запрос в другой раскладке.
        if list.isEmpty, page == 1, !swapped, let other = swapLayout(q) { return try await search(other, page: 1, swapped: true) }
        return (list, more)
    }
    static func swapLayout(_ q: String) -> String? {
        let en = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.`QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>~")
        let ru = Array("йцукенгшщзхъфывапролджэячсмитьбюёЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮЁ")
        var map: [Character: Character] = [:]
        for (a, b) in zip(en, ru) { map[a] = b; map[b] = a }
        let out = String(q.map { map[$0] ?? $0 })
        return out == q || q.isEmpty ? nil : out
    }
    static func details(_ m: MangaItem) async throws -> MangaDetails {
        let slug = m.key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? m.key
        async let info = request("/manga/\(slug)", [("fields[]", "summary"), ("fields[]", "genres"), ("fields[]", "tags"), ("fields[]", "releaseDate"), ("fields[]", "authors"), ("fields[]", "status_id")])
        async let list = request("/manga/\(slug)/chapters")
        let d = ((try await info) as? [String: Any])?["data"] as? [String: Any] ?? [:]
        var item = MangaLib.item(d); if item.key.isEmpty { item = m }
        if item.cover.isEmpty { item.cover = m.cover }
        let chapters = (((try await list) as? [String: Any])?["data"] as? [[String: Any]] ?? []).map { c -> MangaChapter in
            let branch = (c["branches"] as? [[String: Any]])?.first?["branch_id"] as? Int
            return MangaChapter(id: "\((c["id"] as? NSNumber)?.intValue ?? 0)", volume: c["volume"] as? String ?? "", number: c["number"] as? String ?? "", name: c["name"] as? String ?? "", branch: branch)
        }
        let genres = (d["genres"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let status = (d["status"] as? [String: Any])?["label"] as? String
        let authors = (d["authors"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
        let summary = Self.plainText(d["summary"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return MangaDetails(item: item, summary: summary, tags: genres, info: [status, authors.isEmpty ? nil : authors].compactMap { $0 }, chapters: chapters)
    }
    /// Описание MangaLib приходит строкой или документом вида {type: doc, content: [paragraph → text]}.
    nonisolated static func plainText(_ value: Any?) -> String {
        if let s = value as? String { return s }
        guard let node = value as? [String: Any] else { return "" }
        if let text = node["text"] as? String { return text }
        let parts = (node["content"] as? [Any] ?? []).map { plainText($0) }
        let type = node["type"] as? String ?? ""
        if type == "hardBreak" { return "\n" }
        return parts.joined(separator: type == "doc" ? "\n\n" : "")
    }
    static func pages(_ m: MangaItem, _ ch: MangaChapter) async throws -> [URL] {
        let slug = m.key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? m.key
        var q = [("number", ch.number), ("volume", ch.volume)]
        if let b = ch.branch { q.append(("branch_id", "\(b)")) }
        let d = (try await request("/manga/\(slug)/chapter", q) as? [String: Any])?["data"] as? [String: Any] ?? [:]
        let pages = (d["pages"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }.compactMap { u -> URL? in
            u.hasPrefix("http") ? URL(string: u) : URL(string: images + "/" + u.drop { $0 == "/" })
        }
        guard !pages.isEmpty else { throw MangaError(message: "В этой главе нет страниц") }
        return pages
    }
    // Вход через OAuth с PKCE: пользователь вводит пароль на странице auth.lib.social, приложение получает только код.
    static func authorizeURL(state: String, challenge: String) -> URL {
        var c = URLComponents(string: "https://auth.lib.social/auth/oauth/authorize")!
        c.queryItems = [("scope", ""), ("client_id", "1"), ("response_type", "code"), ("redirect_uri", redirect), ("state", state), ("code_challenge", challenge), ("code_challenge_method", "S256"), ("prompt", "consent")].map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.url!
    }
}

// MARK: Com-X

// Перед com-x.life стоит анти-бот с проверкой в JavaScript: страницы сайта читаются из невидимого WKWebView,
// который один раз проходит проверку и дальше делает fetch() с теми же cookies. Картинки с img.com-x.life
// грузятся обычными запросами.
@MainActor final class Comx: NSObject, WKNavigationDelegate {
    static let shared = Comx()
    static let base = URL(string: "https://com-x.life/")!
    private var web: WKWebView?
    private var ready = false
    private var waiting: [CheckedContinuation<Void, Error>] = []

    private func makeWeb() -> WKWebView {
        let c = WKWebViewConfiguration(); c.websiteDataStore = .default()
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: c)
        w.navigationDelegate = self; w.alpha = 0.01; w.isUserInteractionEnabled = false
        // В окне WKWebView работает как обычная вкладка: таймеры проверки не замедляются.
        if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first { window.insertSubview(w, at: 0) }
        return w
    }
    func prepare() async throws {
        if ready { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            waiting.append(c)
            guard waiting.count == 1 else { return }
            if web == nil { web = makeWeb() }
            web?.load(URLRequest(url: Self.base))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 35_000_000_000)
                self?.finish(MangaError(message: "Com-X не открылся: сайт долго проверяет браузер. Повторите позже."))
            }
        }
    }
    private func finish(_ error: Error?) {
        let list = waiting; waiting = []
        if error == nil { ready = true }
        for c in list { if let error { c.resume(throwing: error) } else { c.resume() } }
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard !self.waiting.isEmpty else { return }
            // Страница проверки открывается по тому же адресу; настоящий сайт на DLE объявляет dle_root.
            let state = (try? await webView.evaluateJavaScript("location.hostname + '|' + (typeof dle_root !== 'undefined')")) as? String ?? ""
            let parts = state.split(separator: "|").map(String.init)
            guard parts.count == 2, parts[0].hasSuffix("com-x.life"), parts[1] == "true" else { return }
            self.finish(nil)
        }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}
    // Тело асинхронной JS-функции выполняется на странице com-x.life; если проверка сайта истекла, проходим её снова.
    func run(_ js: String, _ args: [String: Any] = [:], retry: Bool = true) async throws -> Any? {
        try await prepare()
        guard let web else { throw MangaError(message: "Com-X недоступен") }
        do {
            let value = try await web.callAsyncJavaScript(js, arguments: args, in: nil, contentWorld: .page)
            if let d = value as? [String: Any], d["challenge"] as? Bool == true { throw MangaError(message: "challenge") }
            return value
        } catch {
            guard retry else { throw MangaError(message: "Com-X не ответил. Повторите позже.") }
            ready = false
            return try await run(js, args, retry: false)
        }
    }
    func reset() { ready = false; web?.load(URLRequest(url: Self.base)) }

    static let parseList = """
    const d = new DOMParser().parseFromString(html, 'text/html');
    if (!d.querySelector('.short') && !html.includes('dle_root')) return {challenge: true};
    const abs = s => { if (!s) return ''; try { return new URL(s, location.origin).href } catch (e) { return '' } };
    return {more: !!d.querySelector('.pagination__pages a, .navigation a, .pagination a[href*="/page/"]') && !!html.match(/page\\/(\\d+)\\//),
      items: [...d.querySelectorAll('.short')].map(e => {
        const a = e.querySelector('.readed__title a') || e.querySelector('h3 a') || e.querySelector('a.readed__img');
        const img = e.querySelector('img');
        const name = (a && a.textContent.trim()) || (img && img.getAttribute('alt')) || '';
        return {href: a ? a.getAttribute('href') : '', title: name,
                cover: abs(img && (img.getAttribute('data-src') || img.getAttribute('src'))),
                meta: [...e.querySelectorAll('.readed__meta-item')].map(x => x.textContent.trim()).filter(Boolean).join(' · ')}
      }).filter(x => x.href)};
    """
    static func items(_ value: Any?) -> ([MangaItem], Bool) {
        let d = value as? [String: Any] ?? [:]
        let list = (d["items"] as? [[String: Any]] ?? []).compactMap { e -> MangaItem? in
            guard let href = e["href"] as? String, let u = URL(string: href, relativeTo: base) else { return nil }
            // Название на сайте записано как «Original / Русское».
            let parts = (e["title"] as? String ?? "").components(separatedBy: " / ")
            let title = parts.count > 1 ? parts.dropFirst().joined(separator: " / ") : parts.first ?? ""
            return MangaItem(source: .comx, key: u.path, title: title.isEmpty ? "Комикс" : title, subtitle: parts.count > 1 ? parts[0] : "", cover: e["cover"] as? String ?? "", meta: e["meta"] as? String ?? "")
        }
        return (list, d["more"] as? Bool ?? false)
    }
    static func search(_ q: String, page: Int) async throws -> ([MangaItem], Bool) {
        if q.isEmpty {
            let path = page > 1 ? "/comix-read/manga-read/page/\(page)/" : "/comix-read/manga-read/"
            return items(try await shared.run("const r = await fetch(path); const html = await r.text();\n" + parseList, ["path": path]))
        }
        let js = """
        const body = new URLSearchParams({do: 'search', subaction: 'search', story: q, search_start: String(page), full_search: '0', result_from: String((page - 1) * 20 + 1)});
        const r = await fetch('/index.php?do=search', {method: 'POST', body});
        const html = await r.text();
        """ + parseList
        var (list, _) = items(try await shared.run(js, ["q": q, "page": page]))
        list = list.reduce(into: [MangaItem]()) { a, x in if !a.contains(x) { a.append(x) } }
        return (list, list.count >= 20)
    }
    // window.__DATA__ = {…}; за объектом в том же <script> идёт код, поэтому вырезаем объект по скобкам.
    static let dataJS = """
    let data = null;
    const at = html.indexOf('window.__DATA__');
    if (at >= 0) {
      const start = html.indexOf('{', at); let depth = 0, inStr = false, esc = false, end = -1;
      for (let i = start; i >= 0 && i < html.length; i++) {
        const c = html[i];
        if (inStr) { if (esc) esc = false; else if (c === '\\\\') esc = true; else if (c === '"') inStr = false; continue; }
        if (c === '"') inStr = true; else if (c === '{') depth++; else if (c === '}') { depth--; if (depth === 0) { end = i; break; } }
      }
      if (end > start) { try { data = JSON.parse(html.slice(start, end + 1)) } catch (e) {} }
    }
    """
    static func details(_ m: MangaItem) async throws -> MangaDetails {
        let js = """
        const r = await fetch(path); const html = await r.text();
        if (!html.includes('__DATA__') && !html.includes('dle_root')) return {challenge: true};
        """ + dataJS + """
        const d = new DOMParser().parseFromString(html, 'text/html');
        const t = s => { const e = d.querySelector(s); return e ? e.textContent.trim() : '' };
        const img = d.querySelector('.page__poster img');
        return {data, title: t('h1'), original: t('.page__title-original'), text: t('.page__text'),
                cover: img ? new URL(img.getAttribute('data-src') || img.getAttribute('src'), location.origin).href : '',
                tags: [...d.querySelectorAll('.page__tags a')].map(a => a.textContent.trim()),
                info: [...d.querySelectorAll('.page__list li')].map(li => li.textContent.replace(/\\s+/g, ' ').trim())};
        """
        let d = try await shared.run(js, ["path": m.key]) as? [String: Any] ?? [:]
        guard let data = d["data"] as? [String: Any], let news = (data["news_id"] as? NSNumber)?.intValue else { throw MangaError(message: "Не удалось прочитать страницу Com-X") }
        var item = m
        if let t = d["title"] as? String, !t.isEmpty {
            let parts = t.components(separatedBy: " / ")
            item.title = parts.count > 1 ? parts.dropFirst().joined(separator: " / ") : t
            if parts.count > 1 { item.subtitle = parts[0] }
        }
        if let o = d["original"] as? String, !o.isEmpty { item.subtitle = o }
        if let c = d["cover"] as? String, !c.isEmpty { item.cover = c }
        let chapters = (data["chapters"] as? [[String: Any]] ?? []).reversed().map { c -> MangaChapter in
            let id = (c["id"] as? NSNumber)?.intValue ?? 0
            let number = (c["number"] as? NSNumber).map { "\($0)" } ?? c["number"] as? String ?? ""
            let volume = (c["volume"] as? NSNumber).map { $0.intValue > 0 ? "\($0)" : "" } ?? c["volume"] as? String ?? ""
            return MangaChapter(id: "\(news)/\(id)", volume: volume == "0" ? "" : volume, number: number == "0" ? "" : number, name: Self.chapterName(c["title"] as? String ?? ""))
        }
        let info = (d["info"] as? [String] ?? []).filter { !$0.isEmpty }
        return MangaDetails(item: item, summary: d["text"] as? String ?? "", tags: d["tags"] as? [String] ?? [], info: Array(info.prefix(5)), chapters: Array(chapters))
    }
    /// Com-X пишет главу как «1 - 1 Название»: том и номер уже показаны отдельно.
    static func chapterName(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: #"^\d+(\.\d+)?\s*-\s*\d+(\.\d+)?\s*"#, options: .regularExpression) else { return t }
        return String(t[r.upperBound...])
    }
    static func pages(_ m: MangaItem, _ ch: MangaChapter) async throws -> [URL] {
        let js = """
        const r = await fetch(path); const html = await r.text();
        if (!html.includes('__DATA__') && !html.includes('dle_root')) return {challenge: true};
        """ + dataJS + """
        return {images: data && data.images ? data.images : [], logged: data ? !!data.is_logged : false};
        """
        let d = try await shared.run(js, ["path": "/readcomix/\(ch.id).html"]) as? [String: Any] ?? [:]
        let urls = (d["images"] as? [String] ?? []).compactMap { p in p.hasPrefix("http") ? URL(string: p) : URL(string: "https://img.com-x.life/comix/" + p.drop { $0 == "/" }) }
        guard !urls.isEmpty else { throw MangaError(message: d["logged"] as? Bool == false ? "Com-X не показал страницы. Возможно, глава доступна только после входа." : "В этой главе нет страниц") }
        return urls
    }
}

enum MangaAPI {
    static func search(_ s: MangaSource, _ q: String, page: Int) async throws -> ([MangaItem], Bool) {
        #if DEBUG
        if QA.has("--manga-fixtures") { return page > 1 ? ([], false) : (MangaFixtures.items(s), false) }
        #endif
        return s == .mangalib ? try await MangaLib.search(q, page: page) : try await Comx.search(q, page: page)
    }
    static func details(_ m: MangaItem) async throws -> MangaDetails {
        #if DEBUG
        if QA.has("--manga-fixtures") { return MangaFixtures.details(m) }
        #endif
        return m.source == .mangalib ? try await MangaLib.details(m) : try await Comx.details(m)
    }
    static func pages(_ m: MangaItem, _ ch: MangaChapter) async throws -> [URL] {
        #if DEBUG
        if QA.has("--manga-fixtures") { return MangaFixtures.pages() }
        #endif
        return m.source == .mangalib ? try await MangaLib.pages(m, ch) : try await Comx.pages(m, ch)
    }
}

// MARK: Аккаунты манги

// Аккаунты манги живут отдельно от Anime 365: токены MangaLib — в Связке ключей, вход Com-X — cookies сайта в WKWebView.
@MainActor final class MangaAccounts: ObservableObject {
    static let shared = MangaAccounts()
    @Published var libName = ""
    @Published var libLogged = false
    @Published var comxLogged = false
    private struct Tokens: Codable { var access: String; var refresh: String; var expires: Date }
    private var tokens: Tokens?
    private var refreshing: Task<Bool, Never>?
    init() {
        tokens = Self.keychain("mangalib").flatMap { try? JSONDecoder().decode(Tokens.self, from: Data($0.utf8)) }
        libLogged = tokens != nil; libName = UserDefaults.standard.string(forKey: "mangalib-name") ?? ""
    }
    static func keychain(_ account: String) -> String? {
        var result: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Vault.service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func keychain(_ account: String, set value: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Vault.service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = q; add[kSecValueData as String] = Data(value.utf8); add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    private func store(_ j: [String: Any]) -> Bool {
        guard let access = j["access_token"] as? String, !access.isEmpty else { return false }
        let t = Tokens(access: access, refresh: j["refresh_token"] as? String ?? tokens?.refresh ?? "", expires: Date().addingTimeInterval((j["expires_in"] as? NSNumber)?.doubleValue ?? 86400 * 7))
        tokens = t; libLogged = true
        if let data = try? JSONEncoder().encode(t) { Self.keychain("mangalib", set: String(data: data, encoding: .utf8)) }
        YoruAccount.shared.vaultChanged("mangalib")
        return true
    }
    func libAccess() async -> String? {
        guard let t = tokens else { return nil }
        if t.expires.timeIntervalSinceNow < 60 { _ = await libRefresh() }
        return tokens?.access
    }
    func libRefresh() async -> Bool {
        if let refreshing { return await refreshing.value }
        guard let t = tokens, !t.refresh.isEmpty else { return false }
        let task = Task<Bool, Never> {
            let j = try? await MangaLib.request("/auth/oauth/token", method: "POST", body: ["grant_type": "refresh_token", "client_id": "1", "refresh_token": t.refresh, "scope": ""], auth: false) as? [String: Any]
            return j.map(store) ?? false
        }
        refreshing = task; let ok = await task.value; refreshing = nil
        // Другое устройство аккаунта Yoru могло уже обновить токен (старый тогда недействителен) — берём свежий из аккаунта.
        if !ok, await YoruAccount.shared.recover("mangalib"), tokens?.refresh != t.refresh { return true }
        if !ok { libLogout() }
        return ok
    }
    func libExchange(code: String, verifier: String) async throws {
        let j = try await MangaLib.request("/auth/oauth/token", method: "POST", body: ["grant_type": "authorization_code", "client_id": "1", "redirect_uri": MangaLib.redirect, "code_verifier": verifier, "code": code], auth: false) as? [String: Any]
        guard let j, store(j) else { throw MangaError(message: "MangaLib не выдал вход. Попробуйте ещё раз.") }
        await refreshLibName()
    }
    func refreshLibName() async {
        guard tokens != nil, let d = (try? await MangaLib.request("/auth/me") as? [String: Any])?["data"] as? [String: Any] else { return }
        libName = d["username"] as? String ?? d["name"] as? String ?? "Аккаунт"
        UserDefaults.standard.set(libName, forKey: "mangalib-name")
    }
    func libLogout() {
        tokens = nil; libLogged = false; libName = ""; Self.keychain("mangalib", set: nil); UserDefaults.standard.removeObject(forKey: "mangalib-name")
    }
    // Вход для аккаунта Yoru: токены MangaLib и cookies Com-X (зашифрованы ключом от пароля Yoru).
    func vaultPayload(_ svc: String) async -> Data? {
        switch svc {
        case "mangalib":
            // Общий формат для iOS, Android и Mac: expires — миллисекунды с 1970 года.
            guard let t = tokens else { return nil }
            return try? JSONSerialization.data(withJSONObject: ["access": t.access, "refresh": t.refresh, "expires": Int64(t.expires.timeIntervalSince1970 * 1000), "name": libName])
        case "comx":
            let list = await WKWebsiteDataStore.default().httpCookieStore.allCookies().filter { $0.domain.hasSuffix("com-x.life") && ($0.name.hasPrefix("dle_") || $0.name == "PHPSESSID") }
            guard comxLogged, !list.isEmpty else { return nil }
            let a: [[String: Any]] = list.map { c in
                var o: [String: Any] = ["name": c.name, "value": c.value, "domain": c.domain, "path": c.path, "secure": c.isSecure]
                if let e = c.expiresDate { o["expires"] = e.timeIntervalSince1970 }
                return o
            }
            return try? JSONSerialization.data(withJSONObject: a)
        default: return nil
        }
    }
    // nil — «Выйти везде» на другом устройстве.
    func install(_ svc: String, _ data: Data?) async {
        switch svc {
        case "mangalib":
            guard let data else { return libLogout() }
            guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let access = o["access"] as? String, !access.isEmpty else { return }
            let t = Tokens(access: access, refresh: o["refresh"] as? String ?? "", expires: Date(timeIntervalSince1970: Double((o["expires"] as? NSNumber)?.int64Value ?? 0) / 1000))
            tokens = t; libLogged = true
            if let d = try? JSONEncoder().encode(t) { Self.keychain("mangalib", set: String(data: d, encoding: .utf8)) }
            if let name = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["name"] as? String, !name.isEmpty { libName = name; UserDefaults.standard.set(name, forKey: "mangalib-name") }
        case "comx":
            guard let data else { return await comxLogout() }
            guard let a = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
            let store = WKWebsiteDataStore.default().httpCookieStore
            for o in a {
                var p: [HTTPCookiePropertyKey: Any] = [.name: o["name"] as? String ?? "", .value: o["value"] as? String ?? "", .domain: o["domain"] as? String ?? "com-x.life", .path: o["path"] as? String ?? "/"]
                if (o["secure"] as? Bool) == true { p[.secure] = "TRUE" }
                if let e = o["expires"] as? Double { p[.expires] = Date(timeIntervalSince1970: e) }
                if let c = HTTPCookie(properties: p) { await store.setCookie(c) }
            }
            Comx.shared.reset(); await refreshComx()
        default: break
        }
    }
    // DLE ставит после входа cookie dle_user_id.
    func refreshComx() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        comxLogged = cookies.contains { $0.domain.hasSuffix("com-x.life") && $0.name == "dle_user_id" && !$0.value.isEmpty && $0.value != "0" && $0.value != "deleted" }
    }
    func comxLogout() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for c in await store.allCookies() where c.domain.hasSuffix("com-x.life") && (c.name.hasPrefix("dle_") || c.name == "PHPSESSID") { await store.deleteCookie(c) }
        comxLogged = false; Comx.shared.reset()
    }
}

// MARK: Чтение и позиции

struct MangaPosition: Codable { var chapter: String; var page: Int; var count: Int; var title: String }
@MainActor final class MangaStore: ObservableObject {
    static let shared = MangaStore()
    @Published var source: MangaSource = MangaSource(rawValue: UserDefaults.standard.string(forKey: "manga-source") ?? "") ?? .mangalib { didSet { UserDefaults.standard.set(source.rawValue, forKey: "manga-source") } }
    @Published var recent: [MangaItem] = []
    @Published var positions: [String: MangaPosition] = [:]
    @Published var read: [String: Set<String>] = [:]
    @Published var path: [MangaItem] = []
    private var pages: [String: Int] = [:]
    // Когда менялся каждый тайтл и список «Продолжить чтение» — для синхронизации через аккаунт Yoru.
    private var stamps: [String: Int64] = MangaStore.load("manga-ts") ?? [:]
    private func touch(_ id: String) { stamps[id] = HistoryState.now(); Self.save("manga-ts", stamps) }
    init() {
        recent = Self.load("manga-recent") ?? []
        positions = Self.load("manga-positions") ?? [:]
        read = Self.load("manga-read") ?? [:]
        pages = Self.load("manga-pages") ?? [:]
        // Чтение из версий до аккаунта Yoru тоже уходит в аккаунт, но уступает любым новым отметкам.
        for id in Set(positions.keys).union(read.keys) where stamps[id] == nil { stamps[id] = 1 }
        if !recent.isEmpty, HistoryState.int64("manga-recent-t") == 0 { UserDefaults.standard.set(1, forKey: "manga-recent-t") }
    }
    static func load<T: Decodable>(_ key: String) -> T? { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    static func save<T: Encodable>(_ key: String, _ value: T) { UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key) }
    func page(_ item: MangaItem, _ ch: MangaChapter) -> Int { pages[item.id + "|" + ch.id] ?? 0 }
    func isRead(_ item: MangaItem, _ ch: MangaChapter) -> Bool { read[item.id]?.contains(ch.id) ?? false }
    // Сохраняем место в главе, главу тайтла и прочитанные главы; тайтл поднимается в «Продолжить чтение».
    func remember(_ item: MangaItem, _ ch: MangaChapter, page: Int, count: Int) {
        pages[item.id + "|" + ch.id] = page
        positions[item.id] = MangaPosition(chapter: ch.id, page: page, count: count, title: ch.short)
        if count > 0, page >= count - 1 { read[item.id, default: []].insert(ch.id); Self.save("manga-read", read) }
        if recent.first?.id != item.id { recent.removeAll { $0.id == item.id }; recent.insert(item, at: 0); recent = Array(recent.prefix(30)); Self.save("manga-recent", recent); UserDefaults.standard.set(HistoryState.now(), forKey: "manga-recent-t") }
        Self.save("manga-pages", pages); Self.save("manga-positions", positions); touch(item.id)
    }
    func toggleRead(_ item: MangaItem, _ ch: MangaChapter) {
        if isRead(item, ch) { read[item.id]?.remove(ch.id) } else { read[item.id, default: []].insert(ch.id) }
        Self.save("manga-read", read); touch(item.id)
    }
    static func object<T: Encodable>(_ v: T) -> Any? { (try? JSONEncoder().encode(v)).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
    static func decode<T: Decodable>(_ any: Any?, _ type: T.Type) -> T? {
        guard let any, JSONSerialization.isValidJSONObject(any) || any is [Any], let d = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    // Чтение манги для аккаунта Yoru: место, прочитанные главы и страницы по каждому тайтлу.
    func export(into o: inout [String: Any]) {
        var m: [String: Any] = [:]
        for (id, t) in stamps {
            var e: [String: Any] = ["t": t, "read": Array(read[id] ?? [])]
            if let p = positions[id] { e["pos"] = Self.object(p) }
            var pg: [String: Int] = [:]
            for (k, v) in pages where k.hasPrefix(id + "|") { pg[String(k.dropFirst(id.count + 1))] = v }
            e["pages"] = pg
            m[id] = e
        }
        o["manga"] = m
        o["mangaRecent"] = ["t": HistoryState.int64("manga-recent-t"), "items": recent.compactMap { Self.object($0) }]
    }
    func merge(_ i: [String: Any]) {
        var changed = false
        for (id, value) in i["manga"] as? [String: Any] ?? [:] {
            guard let e = value as? [String: Any], HistoryState.number(e["t"]) > (stamps[id] ?? 0) else { continue }
            positions[id] = Self.decode(e["pos"], MangaPosition.self)
            read[id] = Set(e["read"] as? [String] ?? [])
            pages = pages.filter { !$0.key.hasPrefix(id + "|") }
            for (k, v) in e["pages"] as? [String: Any] ?? [:] { pages[id + "|" + k] = Int(HistoryState.number(v)) }
            stamps[id] = HistoryState.number(e["t"]); changed = true
        }
        if changed { Self.save("manga-positions", positions); Self.save("manga-read", read); Self.save("manga-pages", pages); Self.save("manga-ts", stamps) }
        if let l = i["mangaRecent"] as? [String: Any], let items = l["items"] as? [Any], HistoryState.number(l["t"]) > HistoryState.int64("manga-recent-t") || (recent.isEmpty && !items.isEmpty) {
            recent = items.compactMap { Self.decode($0, MangaItem.self) }
            Self.save("manga-recent", recent); UserDefaults.standard.set(max(HistoryState.number(l["t"]), HistoryState.int64("manga-recent-t")), forKey: "manga-recent-t")
        }
    }
}

// MARK: Загрузки глав

// Скачанные главы лежат внутри приложения: Application Support/Manga/<тайтл>/<глава>/001.jpg… и pages.json.
// Рядом title.json с карточкой и списком глав, чтобы без сети открывалась вся книга.
@MainActor final class MangaDownloads: ObservableObject {
    static let shared = MangaDownloads()
    @Published var progress: [String: Double] = [:]
    @Published var done: Set<String> = []
    @Published var titles: [MangaDetails] = []
    @Published var failed: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    static let root: URL = {
        var u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Manga", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true; try? u.setResourceValues(v)
        return u
    }()
    nonisolated static func hash(_ s: String) -> String { Insecure.SHA1.hash(data: Data(s.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() }
    static func folder(_ item: MangaItem) -> URL { root.appendingPathComponent(hash(item.id), isDirectory: true) }
    static func folder(_ item: MangaItem, _ ch: MangaChapter) -> URL { folder(item).appendingPathComponent(hash(ch.id), isDirectory: true) }
    static func key(_ item: MangaItem, _ ch: MangaChapter) -> String { item.id + "|" + ch.id }
    init() { scan() }
    func scan() {
        let fm = FileManager.default
        var list: [MangaDetails] = [], ready: Set<String> = []
        for dir in (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? [] {
            guard let d = try? JSONDecoder().decode(MangaDetails.self, from: Data(contentsOf: dir.appendingPathComponent("title.json"))) else { continue }
            let have = d.chapters.filter { fm.fileExists(atPath: Self.folder(d.item, $0).appendingPathComponent("pages.json").path) }
            if have.isEmpty { try? fm.removeItem(at: dir); continue }
            have.forEach { ready.insert(Self.key(d.item, $0)) }
            list.append(d)
        }
        done = ready
        titles = list.sorted { $0.item.title.localizedCompare($1.item.title) == .orderedAscending }
    }
    func local(_ item: MangaItem) -> MangaDetails? { titles.first { $0.item.id == item.id } }
    func localPages(_ item: MangaItem, _ ch: MangaChapter) -> [URL]? {
        let dir = Self.folder(item, ch)
        guard let names = try? JSONDecoder().decode([String].self, from: Data(contentsOf: dir.appendingPathComponent("pages.json"))) else { return nil }
        return names.map { dir.appendingPathComponent($0) }
    }
    func count(_ item: MangaItem) -> Int { done.filter { $0.hasPrefix(item.id + "|") }.count }
    func download(_ details: MangaDetails, _ chapters: [MangaChapter]) {
        let item = details.item
        try? FileManager.default.createDirectory(at: Self.folder(item), withIntermediateDirectories: true)
        try? JSONEncoder().encode(details).write(to: Self.folder(item).appendingPathComponent("title.json"), options: .atomic)
        if !titles.contains(where: { $0.item.id == item.id }) { titles.append(details) } else { titles = titles.map { $0.item.id == item.id ? details : $0 } }
        for ch in chapters {
            let key = Self.key(item, ch)
            guard !done.contains(key), tasks[key] == nil else { continue }
            progress[key] = 0; failed[key] = nil
            tasks[key] = Task { await self.run(item, ch, key) }
        }
    }
    private func run(_ item: MangaItem, _ ch: MangaChapter, _ key: String) async {
        // Главы качаются по очереди, чтобы не забивать сеть и не получать отказы сайта.
        while progress.contains(where: { $0.key != key && $0.value > 0 }) { try? await Task.sleep(nanoseconds: 300_000_000); if Task.isCancelled { return } }
        progress[key] = 0.01
        let dir = Self.folder(item, ch)
        do {
            let urls = try await MangaAPI.pages(item, ch)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var names = [String](repeating: "", count: urls.count), finished = 0
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                var next = 0
                func add() { let i = next; next += 1; group.addTask { (i, try await MangaImages.save(urls[i], to: dir, index: i)) } }
                for _ in 0..<min(4, urls.count) { add() }
                while let (i, name) = try await group.next() {
                    names[i] = name; finished += 1
                    await MainActor.run { self.progress[key] = max(0.01, Double(finished) / Double(urls.count)) }
                    if Task.isCancelled { group.cancelAll(); throw CancellationError() }
                    if next < urls.count { add() }
                }
            }
            try JSONEncoder().encode(names).write(to: dir.appendingPathComponent("pages.json"), options: .atomic)
            done.insert(key)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            if !(error is CancellationError) { failed[key] = error.localizedDescription }
        }
        progress[key] = nil; tasks[key] = nil
    }
    func cancel(_ item: MangaItem, _ ch: MangaChapter) {
        let key = Self.key(item, ch); tasks[key]?.cancel(); tasks[key] = nil; progress[key] = nil
    }
    func delete(_ item: MangaItem, _ ch: MangaChapter) {
        try? FileManager.default.removeItem(at: Self.folder(item, ch)); done.remove(Self.key(item, ch))
        if count(item) == 0 { deleteTitle(item) }
    }
    func deleteTitle(_ item: MangaItem) {
        for (k, t) in tasks where k.hasPrefix(item.id + "|") { t.cancel(); tasks[k] = nil; progress[k] = nil }
        try? FileManager.default.removeItem(at: Self.folder(item))
        done = done.filter { !$0.hasPrefix(item.id + "|") }; titles.removeAll { $0.item.id == item.id }
    }
    func size(_ item: MangaItem) -> Int64 {
        let e = FileManager.default.enumerator(at: Self.folder(item), includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let f = e?.nextObject() as? URL { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return total
    }
}

// MARK: Картинки страниц

enum MangaImages {
    static let session: URLSession = { let c = URLSessionConfiguration.default; c.timeoutIntervalForRequest = 40; c.urlCache = nil; c.httpMaximumConnectionsPerHost = 4; return URLSession(configuration: c) }()
    static let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("manga-pages", isDirectory: true)
    static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        if url.host?.contains("com-x") == true { r.setValue("https://com-x.life/", forHTTPHeaderField: "Referer") } else { r.setValue("https://mangalib.me/", forHTTPHeaderField: "Referer") }
        return r
    }
    static func fetch(_ url: URL) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        #if DEBUG
        if QA.has("--manga-offline") { throw MangaError(message: "Страница не загрузилась") }
        #endif
        let file = cache.appendingPathComponent(MangaDownloads.hash(url.absoluteString))
        if let d = try? Data(contentsOf: file) { return d }
        var last: Error = MangaError(message: "Страница не загрузилась")
        for attempt in 0..<3 {
            do {
                let (d, r) = try await session.data(for: request(url))
                guard (r as? HTTPURLResponse)?.statusCode == 200, d.count > 100 else { throw MangaError(message: "Страница не загрузилась (\((r as? HTTPURLResponse)?.statusCode ?? 0))") }
                try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                try? d.write(to: file, options: .atomic)
                return d
            } catch { last = error; try? await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1))) }
        }
        throw last
    }
    static func save(_ url: URL, to dir: URL, index: Int) async throws -> String {
        let data = try await fetch(url)
        let ext = ["png", "webp", "gif", "jpeg", "jpg"].first { url.pathExtension.lowercased() == $0 } ?? "jpg"
        let name = String(format: "%03d.%@", index + 1, ext)
        try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        return name
    }
    // Страница уменьшается до ширины экрана в пикселях; длинные ленты манхвы — не больше 12 Мп, чтобы хватало памяти.
    static func decode(_ data: Data, width: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Double, let h = p[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0 else { return UIImage(data: data) }
        var scale = min(1, Double(width) * 1.5 / w)
        if w * h * scale * scale > 12_000_000 { scale = sqrt(12_000_000 / (w * h)) }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
                       kCGImageSourceThumbnailMaxPixelSize: (max(w, h) * scale).rounded(.up)] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }
}

#if DEBUG
// Тайтл и страницы без сети для проверки экранов: --manga-fixtures.
enum MangaFixtures {
    static func items(_ s: MangaSource) -> [MangaItem] {
        (1...9).map { MangaItem(source: s, key: "fixture-\($0)", title: "Проверочная манга \($0)", subtitle: "Fixture \($0)", cover: "", meta: "★ 9,\($0) · Манга · 2024") }
    }
    static func details(_ m: MangaItem) -> MangaDetails {
        MangaDetails(item: m, summary: "Тестовое описание тайтла для проверки экрана манги.", tags: ["Фэнтези", "Приключения"], info: ["Онгоинг"],
                     chapters: (1...12).map { MangaChapter(id: "\($0)", volume: "1", number: "\($0)", name: $0 == 1 ? "Начало" : "") })
    }
    static func pages() -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("manga-fixture", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let colors: [UIColor] = [.systemIndigo, .systemTeal, .systemOrange, .systemPink, .systemGreen, .systemPurple]
        return colors.enumerated().map { i, color in
            let file = dir.appendingPathComponent("p\(i).png")
            if !FileManager.default.fileExists(atPath: file.path) {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1200)).image { ctx in
                    UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 1200))
                    color.setFill(); ctx.fill(CGRect(x: 40, y: 40, width: 720, height: 1120))
                    ("Страница \(i + 1)" as NSString).draw(at: CGPoint(x: 200, y: 540), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 80), .foregroundColor: UIColor.white])
                }
                try? image.pngData()?.write(to: file)
            }
            return file
        }
    }
}
#endif
