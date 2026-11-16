import SwiftUI
import UIKit
import CryptoKit
import CommonCrypto
import Network

// Аккаунт Yoru: своя регистрация по логину и паролю на сервере yoru-sync (Proxmox).
// В аккаунте лежат история, избранное, места в сериях, чтение манги, список загрузок и входы в сервисы.
// Пароль на сервер не уходит: устройство выводит из него два ключа — для входа и для шифрования.
// Входы в Anime 365, MangaLib и Com-X шифруются ключом от пароля, сервер видит только шифротекст.
enum YoruCrypto {
    static let rounds: UInt32 = 210_000
    // master = PBKDF2-HMAC-SHA256(пароль в NFC UTF-8, соль, 210000, 32 байта)
    static func master(_ password: String, salt: Data) -> Data {
        let pw = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let s = [UInt8](salt)
        _ = pw.withUnsafeBufferPointer { p in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), UnsafeRawPointer(p.baseAddress!).assumingMemoryBound(to: Int8.self), pw.count,
                                 s, s.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, 32)
        }
        return Data(out)
    }
    static func keys(_ password: String, salt: Data) async -> (auth: Data, enc: Data) {
        await Task.detached(priority: .userInitiated) {
            let m = SymmetricKey(data: master(password, salt: salt))
            return (Data(HMAC<SHA256>.authenticationCode(for: Data("yoru-auth".utf8), using: m)), Data(HMAC<SHA256>.authenticationCode(for: Data("yoru-enc".utf8), using: m)))
        }.value
    }
    static func seal(_ data: Data, _ key: Data) -> String? { (try? AES.GCM.seal(data, using: SymmetricKey(data: key)).combined)?.base64EncodedString() }
    static func open(_ text: String, _ key: Data) -> Data? {
        guard let d = Data(base64Encoded: text), let box = try? AES.GCM.SealedBox(combined: d) else { return nil }
        return try? AES.GCM.open(box, using: SymmetricKey(data: key))
    }
    static func random(_ n: Int) -> Data { var b = [UInt8](repeating: 0, count: n); _ = SecRandomCopyBytes(kSecRandomDefault, n, &b); return Data(b) }
}

struct YoruDevice: Identifiable { let id: String; let name: String; let last: Date; let current: Bool }

@MainActor final class YoruAccount: ObservableObject {
    static let shared = YoruAccount()
    // Адрес сервера через Tailscale Funnel; можно поменять в окне аккаунта.
    // Домашний провайдер режет *.ts.net, поэтому дома запросы идут на сервер напрямую (findLAN).
    static let defaultServer = "https://yoru.tailfdcf3d.ts.net"
    static let services = ["anime365", "mangalib", "comx", "shikimori"]
    @Published var server = UserDefaults.standard.string(forKey: "yoru-server") ?? YoruAccount.defaultServer { didSet { UserDefaults.standard.set(server, forKey: "yoru-server") } }
    @Published private(set) var login = UserDefaults.standard.string(forKey: "yoru-login") ?? ""
    @Published var email = ""
    @Published var emailVerified = true
    @Published var mailEnabled = false
    @Published var devices: [YoruDevice] = []
    @Published var syncing = false
    @Published var lastSync: Date? = UserDefaults.standard.object(forKey: "yoru-synced") as? Date
    @Published var syncError: String?
    weak var store: AnimeStore?
    private var token = MangaAccounts.keychain("yoru-token") ?? ""
    private var enc = MangaAccounts.keychain("yoru-enc").flatMap { Data(base64Encoded: $0) }
    private var current: Task<Void, Never>?
    private var again = false
    private var debounce: Task<Void, Never>?
    private var installing = false
    private var installed: Set<String> = []
    var logged: Bool { !token.isEmpty }
    var d: UserDefaults { .standard }

    // MARK: запросы
    func call(_ path: String, _ body: [String: Any] = [:], auth: Bool = true) async throws -> [String: Any] {
        let typed = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let main = typed.isEmpty ? Self.defaultServer : (typed.contains("://") ? typed : "https://" + typed)
        guard !main.isEmpty else { throw APIError(message: "Укажите адрес сервера Yoru") }
        let payload = try JSONSerialization.data(withJSONObject: body)
        // Сначала адрес, который ответил в прошлый раз; при сетевой ошибке — второй (домашняя сеть или интернет).
        var bases = [main]
        if main == Self.defaultServer, let lan = d.string(forKey: "yoru-lan") { bases = d.bool(forKey: "yoru-via-lan") ? [lan, main] : [main, lan] }
        var result: (Data, URLResponse)?
        var looked = false
        var i = 0
        while i < bases.count {
            let base = bases[i]; i += 1
            guard let url = URL(string: base + path) else { continue }
            var r = URLRequest(url: url, timeoutInterval: base == main ? 25 : 6); r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if auth { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            r.httpBody = payload
            if let ok = try? await URLSession.shared.data(for: r) {
                result = ok
                if main == Self.defaultServer { d.set(base != main, forKey: "yoru-via-lan") }
                break
            }
            // Адрес приставки в сети неизвестен или сменился — ищем её заново один раз.
            if i == bases.count, main == Self.defaultServer, !looked {
                looked = true
                if let lan = await Self.findLAN(), !bases.contains(lan) { d.set(lan, forKey: "yoru-lan"); bases.append(lan) }
            }
        }
        guard let (data, response) = result else { throw APIError(message: "Сервер Yoru недоступен. Проверьте интернет.") }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if code == 401 && auth { signedOut(); throw APIError(message: j["error"] as? String ?? "Вход в аккаунт Yoru завершён. Войдите снова.") }
        guard code == 200 else { throw APIError(message: j["error"] as? String ?? "Сервер Yoru ответил ошибкой (\(code))") }
        return j
    }
    // Домашний yoru-sync объявляет себя в сети как _yoru-sync._tcp (avahi): берём его IPv4 и порт.
    static func findLAN() async -> String? {
        #if DEBUG
        if QA.has("--no-tv") { return nil }
        #endif
        guard let endpoint = await TVSync.find("_yoru-sync._tcp") else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let params = NWParameters.tcp
            (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
            let conn = NWConnection(to: endpoint, using: params)
            var finished = false
            let finish: (String?) -> Void = { v in guard !finished else { return }; finished = true; conn.cancel(); c.resume(returning: v) }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port)? = conn.currentPath?.remoteEndpoint, case .ipv4(let a) = host {
                        let ip = "\(a)".split(separator: "%").first.map(String.init) ?? ""
                        finish(ip.isEmpty ? nil : "http://\(ip):\(port.rawValue)")
                    } else { finish(nil) }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            conn.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(nil) }
        }
    }
    static var deviceName: String { "\(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)" }
    private func salt(_ who: String) async throws -> Data {
        let j = try await call("/v1/prelogin", ["login": who], auth: false)
        guard let s = (j["salt"] as? String).flatMap({ Data(base64Encoded: $0) }) else { throw APIError(message: "Сервер Yoru ответил неожиданно") }
        return s
    }
    private func signedIn(_ j: [String: Any], enc key: Data) async {
        token = j["token"] as? String ?? ""; enc = key
        login = j["login"] as? String ?? ""; d.set(login, forKey: "yoru-login")
        MangaAccounts.keychain("yoru-token", set: token); MangaAccounts.keychain("yoru-enc", set: key.base64EncodedString())
        // Входы этого устройства, сделанные до аккаунта, тоже уходят в аккаунт, но уступают более новым.
        // Только те, где здесь действительно есть вход: пустая отметка 1 заслонила бы вход из аккаунта.
        for s in Self.services where HistoryState.int64("vault-t-" + s) == 0 { if await payload(s) != nil { d.set(1, forKey: "vault-t-" + s) } }
        d.set(true, forKey: "vault-fix-1")
        await refreshMe(); await sync()
    }
    private func signedOut() {
        token = ""; enc = nil; login = ""; email = ""; devices = []; lastSync = nil
        MangaAccounts.keychain("yoru-token", set: nil); MangaAccounts.keychain("yoru-enc", set: nil)
        d.removeObject(forKey: "yoru-login"); d.removeObject(forKey: "yoru-synced")
        // После выхода входы этого устройства снова считаются «своими»: при следующем входе они уступят аккаунту.
        for s in Self.services { d.removeObject(forKey: "vault-t-" + s); d.removeObject(forKey: "vault-del-" + s) }
    }

    // MARK: вход и регистрация
    func register(login who: String, email: String, invite: String, password: String) async throws {
        let s = YoruCrypto.random(16)
        let k = await YoruCrypto.keys(password, salt: s)
        let j = try await call("/v1/register", ["login": who, "email": email, "invite": invite, "salt": s.base64EncodedString(), "auth": k.auth.base64EncodedString(), "device": Self.deviceName], auth: false)
        await signedIn(j, enc: k.enc)
    }
    func signIn(login who: String, password: String) async throws {
        let s = try await salt(who)
        let k = await YoruCrypto.keys(password, salt: s)
        let j = try await call("/v1/login", ["login": who, "auth": k.auth.base64EncodedString(), "device": Self.deviceName], auth: false)
        await signedIn(j, enc: k.enc)
    }
    func forgot(_ who: String) async throws -> String {
        let j = try await call("/v1/forgot", ["login": who], auth: false)
        return j["note"] as? String ?? "Если у аккаунта подтверждена почта, на неё отправлен код."
    }
    // Новый пароль по коду из письма. Входы в сервисы были зашифрованы старым паролем — их придётся повторить.
    func reset(login who: String, code: String, password: String) async throws {
        let s = YoruCrypto.random(16)
        let k = await YoruCrypto.keys(password, salt: s)
        let j = try await call("/v1/reset", ["login": who, "code": code, "salt": s.base64EncodedString(), "auth": k.auth.base64EncodedString(), "device": Self.deviceName], auth: false)
        await signedIn(j, enc: k.enc)
    }
    func refreshMe() async {
        guard logged, let j = try? await call("/v1/me") else { return }
        // Связка ключей переживает удаление приложения, а UserDefaults — нет: логин берём с сервера.
        if let l = j["login"] as? String, !l.isEmpty, l != login { login = l; d.set(l, forKey: "yoru-login") }
        email = j["email"] as? String ?? ""; emailVerified = (j["emailVerified"] as? Bool) ?? true; mailEnabled = (j["mail"] as? Bool) ?? false
        devices = (j["devices"] as? [[String: Any]] ?? []).map { o in
            YoruDevice(id: o["id"] as? String ?? "", name: o["name"] as? String ?? "Устройство", last: Date(timeIntervalSince1970: Double(HistoryState.number(o["last"]))), current: (o["current"] as? Bool) ?? false)
        }
    }
    func verifyEmail(_ code: String) async throws { _ = try await call("/v1/verify-email", ["code": code]); await refreshMe() }
    func resend() async throws { _ = try await call("/v1/resend") }
    func changeEmail(_ new: String, password: String) async throws {
        let k = await YoruCrypto.keys(password, salt: try await salt(login))
        _ = try await call("/v1/email", ["email": new, "old": k.auth.base64EncodedString()]); await refreshMe()
    }
    // Смена пароля: входы в сервисы перешифровываются новым ключом прямо на устройстве.
    func changePassword(old: String, new: String) async throws {
        let oldKeys = await YoruCrypto.keys(old, salt: try await salt(login))
        let j = try await call("/v1/sync", ["state": await exportState()])
        let vault = (j["state"] as? [String: Any])?["vault"] as? [String: Any] ?? [:]
        let s = YoruCrypto.random(16)
        let k = await YoruCrypto.keys(new, salt: s)
        var out: [String: Any] = [:]
        for (svc, value) in vault {
            guard var e = value as? [String: Any] else { continue }
            if let text = e["d"] as? String {
                guard let plain = YoruCrypto.open(text, oldKeys.enc), let sealed = YoruCrypto.seal(plain, k.enc) else { continue }
                e["d"] = sealed
            }
            out[svc] = e
        }
        _ = try await call("/v1/password", ["old": oldKeys.auth.base64EncodedString(), "salt": s.base64EncodedString(), "auth": k.auth.base64EncodedString(), "vault": out])
        enc = k.enc; MangaAccounts.keychain("yoru-enc", set: k.enc.base64EncodedString())
        await refreshMe()
    }
    func signOut(all: Bool = false) async {
        if logged { _ = try? await call("/v1/logout", all ? ["all": true] : [:]) }
        signedOut()
    }
    func removeDevice(_ id: String) async throws { _ = try await call("/v1/logout", ["device": id]); await refreshMe() }
    func deleteAccount(password: String) async throws {
        let k = await YoruCrypto.keys(password, salt: try await salt(login))
        _ = try await call("/v1/delete", ["old": k.auth.base64EncodedString()])
        signedOut()
    }

    // MARK: синхронизация
    // Локальные изменения уходят на сервер через пару секунд, пачкой.
    func changed() {
        guard logged, !installing else { return }
        debounce?.cancel()
        debounce = Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if !Task.isCancelled { await sync() } }
    }
    func vaultChanged(_ svc: String) {
        guard !installing else { return }
        d.set(HistoryState.now(), forKey: "vault-t-" + svc); d.removeObject(forKey: "vault-del-" + svc)
        changed()
    }
    // «Выйти везде»: вход в сервис стирается из аккаунта, остальные устройства выйдут при синхронизации.
    func forgetEverywhere(_ svc: String) {
        d.set(HistoryState.now(), forKey: "vault-t-" + svc); d.set(true, forKey: "vault-del-" + svc)
        changed()
    }
    // Вход в сервис на этом устройстве перестал работать: возможно, другое устройство уже обновило его в аккаунте.
    func recover(_ svc: String) async -> Bool {
        guard logged else { return false }
        installed.remove(svc); await sync(); return installed.contains(svc)
    }

    func sync(_ store: AnimeStore) async {
        self.store = store
        #if DEBUG
        // Проверка в симуляторе против локального сервера: --yoru-server=… и тестовый аккаунт.
        if let s = QA.value("--yoru-server"), server != s { server = s }
        // Проверка пути до сервера (интернет или домашняя сеть) без изменения данных.
        if QA.has("--yoru-ping") {
            let ok = (try? await call("/v1/prelogin", ["login": "qa-ping"], auth: false)) != nil
            d.set(ok ? "ok lan=\(d.bool(forKey: "yoru-via-lan")) \(d.string(forKey: "yoru-lan") ?? "-")" : "fail", forKey: "qa-yoru-ping")
        }
        if QA.has("--qa-seed"), d.object(forKey: "last-1001") == nil {
            let now = HistoryState.now(), item = AnimeItem(["id": 1001, "titles": ["ru": "Тест Yoru"]])
            store.favorites = [item]; d.set([item.raw], forKey: "favorites"); d.set(now, forKey: "t-favorites")
            d.set(3, forKey: "last-1001"); d.set(now, forKey: "stamp-1001"); d.set("voiceRu|QA", forKey: "tr-1001"); d.set(true, forKey: "done-5001")
            d.set(0.4, forKey: "watch-5002"); d.set(now, forKey: "ts-watch-5002"); HistoryState.savePosition("position-777", 120)
        }
        if let t = QA.value("--qa-anime-token"), store.token != t { store.token = t; Vault.save(t); vaultChanged("anime365") }
        if !logged, let p = QA.value("--yoru-password") {
            do {
                if let w = QA.value("--yoru-register") { try await register(login: w, email: w + "@example.com", invite: QA.value("--yoru-invite") ?? "", password: p) }
                else if let w = QA.value("--yoru-login") { try await signIn(login: w, password: p) }
            } catch { syncError = error.localizedDescription }
            return
        }
        #endif
        await sync()
    }
    func sync() async {
        guard logged, store != nil else { return }
        #if DEBUG
        if QA.value("--fixtures") != nil || QA.value("--player-file") != nil || QA.has("--no-sync") { return }
        #endif
        if let current { again = true; await current.value; if !again { return } }
        again = false
        let task = Task { await run() }
        current = task; await task.value; current = nil
    }
    private func run() async {
        guard let store else { return }
        syncing = true; defer { syncing = false }
        do {
            let j = try await call("/v1/sync", ["state": await exportState()])
            guard let st = j["state"] as? [String: Any] else { return }
            installing = true
            HistoryState.merge(st, into: store)
            mergeFractions(st)
            DownloadCenter.shared.mergeSync(st)
            MangaStore.shared.merge(st)
            await installVault(st)
            installing = false
            DownloadCenter.shared.autoRestore(store: store)
            syncError = nil; lastSync = Date(); d.set(lastSync, forKey: "yoru-synced")
        } catch { installing = false; syncError = error.localizedDescription }
    }
    func exportState() async -> [String: Any] {
        var o = HistoryState.export()
        var fr: [String: Any] = [:]
        for (k, v) in d.dictionaryRepresentation() where k.hasPrefix("watch-") {
            fr[k] = ["v": (v as? NSNumber)?.doubleValue ?? 0, "t": max(HistoryState.int64("ts-" + k), 1)]
        }
        o["fractions"] = fr
        DownloadCenter.shared.exportSync(into: &o)
        MangaStore.shared.export(into: &o)
        o["vault"] = await exportVault()
        return o
    }
    private func mergeFractions(_ st: [String: Any]) {
        for (k, value) in st["fractions"] as? [String: Any] ?? [:] {
            guard k.hasPrefix("watch-"), let e = value as? [String: Any], HistoryState.number(e["t"]) > HistoryState.int64("ts-" + k) else { continue }
            d.set((e["v"] as? NSNumber)?.doubleValue ?? 0, forKey: k); d.set(HistoryState.number(e["t"]), forKey: "ts-" + k)
        }
    }
    private func payload(_ svc: String) async -> Data? {
        if svc == "anime365" { guard let t = store?.token, !t.isEmpty else { return nil }; return try? JSONSerialization.data(withJSONObject: ["token": t]) }
        if svc == "shikimori" { return ShikiAccount.shared.vaultPayload() }
        return await MangaAccounts.shared.vaultPayload(svc)
    }
    private func exportVault() async -> [String: Any] {
        guard let enc else { return [:] }
        // До 2.3.1 вход в аккаунт ставил отметку 1 и сервисам без входа — тогда вход с другого устройства не приходил. Один раз чистим.
        if !d.bool(forKey: "vault-fix-1") {
            for s in Self.services where HistoryState.int64("vault-t-" + s) == 1 && !d.bool(forKey: "vault-del-" + s) {
                if await payload(s) == nil { d.removeObject(forKey: "vault-t-" + s) }
            }
            d.set(true, forKey: "vault-fix-1")
        }
        // Вход в Шикимори, сделанный до того, как он стал частью аккаунта, тоже уходит в аккаунт (уступая более новым).
        if HistoryState.int64("vault-t-shikimori") == 0, ShikiAccount.shared.vaultPayload() != nil { d.set(1, forKey: "vault-t-shikimori") }
        var v: [String: Any] = [:]
        for s in Self.services {
            let t = HistoryState.int64("vault-t-" + s)
            guard t > 0 else { continue }
            if d.bool(forKey: "vault-del-" + s) { v[s] = ["t": t, "d": NSNull()]; continue }
            if let p = await payload(s), let sealed = YoruCrypto.seal(p, enc) { v[s] = ["t": t, "d": sealed] }
        }
        return v
    }
    private func installVault(_ st: [String: Any]) async {
        guard let enc else { return }
        for (s, value) in st["vault"] as? [String: Any] ?? [:] {
            guard Self.services.contains(s), let e = value as? [String: Any], HistoryState.number(e["t"]) > HistoryState.int64("vault-t-" + s) else { continue }
            var plain: Data?
            if let text = e["d"] as? String {
                // Не расшифровалось — запись сделана другим паролем; не трогаем.
                guard let p = YoruCrypto.open(text, enc) else { continue }
                plain = p
            }
            switch s {
            case "anime365":
                guard let store else { continue }
                let t = plain.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["token"] as? String ?? ""
                if t.isEmpty { store.logout() } else { store.token = t; Vault.save(t); Task { await store.refreshAccount() } }
            case "shikimori":
                ShikiAccount.shared.install(plain)
                if let store, ShikiAccount.shared.signedIn { Task { await ShikiAccount.shared.syncBoth(store) } }
            default:
                await MangaAccounts.shared.install(s, plain)
            }
            d.set(HistoryState.number(e["t"]), forKey: "vault-t-" + s); d.removeObject(forKey: "vault-del-" + s)
            installed.insert(s)
        }
    }
}

// MARK: Экран аккаунта

struct YoruAccountCard: View {
    @ObservedObject var account = YoruAccount.shared
    @State var open = false
    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 14) {
                Image(systemName: account.logged ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus").font(.system(size: 24)).foregroundStyle(account.logged ? Night.scoreHigh : Night.text).frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Аккаунт Yoru").font(.system(size: 17, weight: .bold)).foregroundStyle(Night.text)
                    Text(status).font(.system(size: 13)).foregroundStyle(Night.muted).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(account.logged ? "Открыть" : "Войти").font(.system(size: 14, weight: .semibold)).foregroundStyle(Night.text)
            }
            .padding(14).background(Night.panel, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Night.stroke))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $open) { YoruAccountView() }
    }
    var status: String {
        guard account.logged else { return "История, загрузки и входы в сервисы сохранятся в аккаунте — и после переустановки, и на других устройствах" }
        if let e = account.syncError { return account.login + " · " + e }
        return account.login + (account.lastSync.map { " · синхронизировано " + $0.formatted(date: .omitted, time: .shortened) } ?? "")
    }
}

struct YoruAccountView: View {
    enum Mode { case login, register, forgot, reset }
    @EnvironmentObject var store: AnimeStore
    @ObservedObject var account = YoruAccount.shared
    @Environment(\.dismiss) var dismiss
    @State var mode = Mode.login
    @State var who = ""
    @State var email = ""
    @State var invite = ""
    @State var password = ""
    @State var password2 = ""
    @State var code = ""
    @State var oldPassword = ""
    @State var busy = false
    // Какая кнопка сейчас выполняется — на ней спиннер.
    @State var working: String?
    @State var error: String?
    @State var note: String?
    @State var changing = false
    @State var confirmAll = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("Аккаунт Yoru").font(.system(size: 22, weight: .bold)).foregroundStyle(.white); Spacer(); Button("Закрыть") { dismiss() }.buttonStyle(NightButtonStyle()) }
                if account.logged { panel } else { form }
                if let error { Text(error).font(.system(size: 14)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45)) }
                if let note { Text(note).font(.system(size: 14)).foregroundStyle(Night.scoreHigh) }
            }.padding(20)
        }
        .background(NightBackground()).presentationDetents([.large])
        .task { if account.logged { await account.refreshMe() } }
    }

    // MARK: без входа
    @ViewBuilder var form: some View {
        Text(mode == .register ? "Новый аккаунт: история, загрузки и входы в Anime 365, MangaLib и Com-X будут общими на всех ваших устройствах. Для регистрации нужен код приглашения."
             : mode == .forgot || mode == .reset ? "Код для нового пароля придёт на почту, подтверждённую в аккаунте. Входы в сервисы после смены пароля по почте нужно будет повторить."
             : "Войдите, чтобы история и загрузки не пропадали при переустановке и были общими на iPhone, Android, ТВ и Mac.")
            .font(.system(size: 13)).foregroundStyle(Night.meta)
        Picker("", selection: $mode) { Text("Вход").tag(Mode.login); Text("Регистрация").tag(Mode.register) }.pickerStyle(.segmented)
            .opacity(mode == .forgot || mode == .reset ? 0.5 : 1)
        field(mode == .login || mode == .forgot ? "Логин или почта" : "Логин", text: $who, content: .username)
        if mode == .register {
            field("Почта для восстановления пароля", text: $email, content: .emailAddress, keyboard: .emailAddress)
            field("Код приглашения", text: $invite, content: .oneTimeCode)
        }
        if mode == .reset { field("Код из письма", text: $code, content: .oneTimeCode, keyboard: .numberPad) }
        if mode != .forgot {
            secure(mode == .reset ? "Новый пароль" : "Пароль", text: $password, content: mode == .login ? .password : .newPassword)
            if mode != .login { secure("Повторите пароль", text: $password2, content: .newPassword) }
        }
        Button(action: submit) {
            HStack { if busy { ProgressView().tint(.white) }; Text(mode == .login ? "Войти" : mode == .register ? "Создать аккаунт" : mode == .forgot ? "Прислать код" : "Сменить пароль и войти") }.frame(maxWidth: .infinity)
        }.buttonStyle(PillStyle(primary: true)).disabled(busy)
        HStack {
            if mode == .login { Button("Забыли пароль?") { mode = .forgot; error = nil; note = nil }.buttonStyle(PillStyle()) }
            if mode == .forgot || mode == .reset { Button("Назад ко входу") { mode = .login; error = nil; note = nil }.buttonStyle(PillStyle()) }
            if mode == .forgot { Button("У меня уже есть код") { mode = .reset; error = nil }.buttonStyle(PillStyle()) }
        }
        // Свой адрес сервера синхронизации — только для проверки; обычный пользователь его не видит.
        #if DEBUG
        DisclosureGroup("Сервер") {
            field("Адрес сервера", text: $account.server, content: .URL, keyboard: .URL).padding(.top, 6)
        }.font(.system(size: 14)).foregroundStyle(Night.muted).tint(Night.muted)
        #endif
    }
    func submit() {
        error = nil; note = nil
        let w = who.trimmingCharacters(in: .whitespaces)
        if w.isEmpty { error = "Введите логин"; return }
        if mode == .register || mode == .reset {
            if password.count < 8 { error = "Пароль — не короче 8 символов"; return }
            if password != password2 { error = "Пароли не совпадают"; return }
        }
        if mode == .login && password.isEmpty { error = "Введите пароль"; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                switch mode {
                case .login: try await account.signIn(login: w, password: password)
                case .register: try await account.register(login: w, email: email.trimmingCharacters(in: .whitespaces), invite: invite, password: password)
                case .forgot: note = try await account.forgot(w); mode = .reset
                case .reset: try await account.reset(login: w, code: code.trimmingCharacters(in: .whitespaces), password: password); note = "Пароль изменён. Войдите в сервисы заново — их входы были зашифрованы старым паролем."
                }
                password = ""; password2 = ""; code = ""
                if account.logged { await store.sync() }
            } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: с входом
    @ViewBuilder var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(account.login).font(.system(size: 20, weight: .bold)).foregroundStyle(Night.text)
            Text(account.email.isEmpty ? "" : account.email + (account.emailVerified ? " · подтверждена" : " · не подтверждена")).font(.system(size: 13)).foregroundStyle(Night.muted)
            HStack {
                Button { Task { await account.sync() } } label: { HStack { if account.syncing { ProgressView().tint(.white) }; Text("Синхронизировать") } }.buttonStyle(PillStyle(primary: true)).disabled(account.syncing)
                if let t = account.lastSync { Text(t.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundStyle(Night.muted) }
            }
            if let e = account.syncError { Text(e).font(.system(size: 13)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45)) }
        }.card()
        if !account.emailVerified {
            VStack(alignment: .leading, spacing: 10) {
                Text("Подтвердите почту").font(.system(size: 16, weight: .bold)).foregroundStyle(Night.text)
                Text(account.mailEnabled ? "Мы отправили код на \(account.email). Без подтверждённой почты пароль не восстановить." : "Отправка писем на сервере пока не настроена.").font(.system(size: 13)).foregroundStyle(Night.meta)
                if account.mailEnabled {
                    field("Код из письма", text: $code, content: .oneTimeCode, keyboard: .numberPad)
                    HStack {
                        Button("Подтвердить") { run("verify") { try await account.verifyEmail(code.trimmingCharacters(in: .whitespaces)); code = ""; note = "Почта подтверждена" } }.buttonStyle(PillStyle(primary: true, busy: working == "verify"))
                        Button("Прислать ещё раз") { run("resend") { try await account.resend(); note = "Код отправлен" } }.buttonStyle(PillStyle(busy: working == "resend"))
                    }
                }
            }.card()
        }
        VStack(alignment: .leading, spacing: 10) {
            Text("Устройства").font(.system(size: 16, weight: .bold)).foregroundStyle(Night.text)
            ForEach(account.devices) { dev in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dev.name + (dev.current ? " · это устройство" : "")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Night.text)
                        Text("Был в сети " + dev.last.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundStyle(Night.muted)
                    }
                    Spacer()
                    if !dev.current { Button("Отключить") { run("dev-\(dev.id)") { try await account.removeDevice(dev.id) } }.buttonStyle(PillStyle(busy: working == "dev-\(dev.id)")) }
                }
            }
        }.card()
        VStack(alignment: .leading, spacing: 10) {
            Button(changing ? "Отмена" : "Сменить пароль") { changing.toggle(); error = nil }.buttonStyle(PillStyle())
            if changing {
                secure("Текущий пароль", text: $oldPassword, content: .password)
                secure("Новый пароль", text: $password, content: .newPassword)
                secure("Повторите новый пароль", text: $password2, content: .newPassword)
                Button("Сохранить пароль") {
                    if password.count < 8 { error = "Пароль — не короче 8 символов"; return }
                    if password != password2 { error = "Пароли не совпадают"; return }
                    run("password") { try await account.changePassword(old: oldPassword, new: password); oldPassword = ""; password = ""; password2 = ""; changing = false; note = "Пароль изменён. На других устройствах войдите в аккаунт заново." }
                }.buttonStyle(PillStyle(primary: true, busy: working == "password"))
            }
        }.card()
        HStack {
            Button("Выйти") { run("out") { await account.signOut() } }.buttonStyle(PillStyle(busy: working == "out"))
            Button("Выйти на всех устройствах") { confirmAll = true }.buttonStyle(PillStyle(busy: working == "out-all"))
        }
        .confirmationDialog("Выйти из аккаунта Yoru на всех устройствах?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Выйти везде", role: .destructive) { run("out-all") { await account.signOut(all: true) } }
        } message: { Text("Входы в сервисы на устройствах останутся, а синхронизация остановится до нового входа.") }
        Text("Выход из аккаунта Yoru не выходит из Anime 365, MangaLib и Com-X на этом устройстве.").font(.system(size: 12)).foregroundStyle(Night.muted)
    }
    func run(_ key: String = "", _ f: @escaping () async throws -> Void) {
        error = nil; note = nil; busy = true; working = key
        Task { defer { busy = false; working = nil }; do { try await f() } catch { self.error = error.localizedDescription } }
    }
    func field(_ title: String, text: Binding<String>, content: UITextContentType, keyboard: UIKeyboardType = .default) -> some View {
        TextField("", text: text, prompt: Text(title).foregroundStyle(Night.muted))
            .textContentType(content).keyboardType(keyboard).textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(12).foregroundStyle(Night.text).background(Night.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Night.stroke))
    }
    func secure(_ title: String, text: Binding<String>, content: UITextContentType) -> some View {
        SecureField("", text: text, prompt: Text(title).foregroundStyle(Night.muted))
            .textContentType(content).textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(12).foregroundStyle(Night.text).background(Night.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Night.stroke))
    }
}

extension View {
    func card() -> some View {
        frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Night.panel, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Night.stroke))
    }
}
