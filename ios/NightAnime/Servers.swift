import Foundation
import SwiftUI

// Видеосерверы Anime 365. Сайт в каждой ссылке даёт случайный сервер (ru-NNNNNN.<домен>), и любой из них
// отдаёт тот же файл по той же ссылке. Скорость у них разная, поэтому приложение запоминает серверы,
// которые встречало, проверяет их скорость и подставляет самый быстрый; ссылка сайта остаётся запасной.
struct ServerResult: Identifiable, Equatable { let host: String; var mbit: Double?; var error: String?; var id: String { host } }

enum Servers {
    static var d: UserDefaults { .standard }
    // Выбор сервера полностью автоматический: пользователь его не видит и не настраивает.
    static let auto = true
    static var best: String? { get { d.string(forKey: "server-best") } set { d.set(newValue, forKey: "server-best") } }
    static var seen: [String] { d.stringArray(forKey: "servers-seen") ?? [] }
    static var results: [String: Double] { d.dictionary(forKey: "servers-mbit") as? [String: Double] ?? [:] }
    static var tested: Date? { d.object(forKey: "servers-tested") as? Date }
    static func isVideo(_ host: String?) -> Bool { host.map { $0.hasPrefix("ru-") && $0.split(separator: ".").count >= 3 } ?? false }
    // Запоминаем серверы из каждого ответа сайта (не больше 12 последних).
    static func remember(_ urls: [URL]) {
        var list = seen
        for h in urls.compactMap(\.host) where isVideo(h) && !list.contains(h) { list.insert(h, at: 0) }
        d.set(Array(list.prefix(12)), forKey: "servers-seen")
    }
    // Ссылка через самый быстрый сервер первой, ссылка сайта — запасной.
    static func preferred(_ u: URL) -> [URL] {
        guard auto, let best, isVideo(u.host), u.host != best, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return [u] }
        c.host = best
        return [c.url ?? u, u]
    }

    // Проверка: один и тот же файл (первые 4 МБ) с каждого сервера, по очереди.
    // Тихая проверка раз в сутки и после отказа лучшего сервера. Только по Wi‑Fi: мобильный трафик не тратим.
    @MainActor static var checking = false
    @MainActor static func autoCheck(_ store: AnimeStore) async {
        let stale = tested.map { Date().timeIntervalSince($0) > 24 * 3600 } ?? true
        guard !checking, !store.token.isEmpty, stale || (best == nil && seen.count > 1) else { return }
        checking = true; defer { checking = false }
        guard let sample = try? await store.serverSample() else { return }
        _ = await test(sample: sample, bytes: 2 << 20, cellular: false) { _ in }
    }

    static func test(sample: URL, bytes: Int = 4 << 20, cellular: Bool = true, each: @escaping @MainActor (ServerResult) -> Void) async -> [ServerResult] {
        var hosts = seen
        if let h = sample.host, isVideo(h), !hosts.contains(h) { hosts.insert(h, at: 0) }
        var out: [ServerResult] = []
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 15; config.urlCache = nil; config.allowsExpensiveNetworkAccess = cellular
        let session = URLSession(configuration: config)
        for host in hosts {
            var c = URLComponents(url: sample, resolvingAgainstBaseURL: false)!; c.host = host
            var r = URLRequest(url: c.url!); r.setValue("bytes=0-\(bytes - 1)", forHTTPHeaderField: "Range"); r.setValue("NightAnime/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            var result = ServerResult(host: host)
            let start = Date()
            do {
                let (data, response) = try await session.data(for: r)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code / 100 == 2, data.count > min(100_000, bytes / 2) { result.mbit = Double(data.count) * 8 / 1e6 / max(Date().timeIntervalSince(start), 0.001) }
                else { result.error = "не отдал файл (\(code))" }
            } catch { result.error = (error as NSError).code == NSURLErrorTimedOut ? "слишком медленно" : "недоступен" }
            out.append(result)
            await each(result)
        }
        // Сеть пропала посреди проверки — прежний выбор не трогаем.
        guard out.contains(where: { $0.mbit != nil }) else { return out }
        let speeds = Dictionary(uniqueKeysWithValues: out.compactMap { r in r.mbit.map { (r.host, $0) } })
        d.set(speeds, forKey: "servers-mbit"); d.set(Date(), forKey: "servers-tested")
        // Неработающие серверы забываем, быстрые — в начало списка.
        d.set(out.filter { $0.mbit != nil }.sorted { $0.mbit! > $1.mbit! }.map(\.host), forKey: "servers-seen")
        best = out.filter { $0.mbit != nil }.max { $0.mbit! < $1.mbit! }?.host
        return out
    }
}

// Меню аккаунта: имя и подписка. Видеосервер выбирается сам (Servers.autoCheck).
struct AccountPanel: View {
    @EnvironmentObject var store: AnimeStore
    static let day: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM yyyy"; return f }()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row {
                Text(store.account).font(.system(size: 17, weight: .bold)).foregroundStyle(Night.text)
                subscription
            }
        }
        .task { await store.refreshAccount() }
    }
    @ViewBuilder var subscription: some View {
        switch store.premium {
        case true?:
            Label(store.premiumUntil.map { "Подписка активна до \(Self.day.string(from: $0))" } ?? "Подписка активна", systemImage: "checkmark.seal.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Night.scoreHigh)
            if let until = store.premiumUntil { let days = Calendar.current.dateComponents([.day], from: Date(), to: until).day ?? 0
                Text(days > 0 ? "Осталось \(days) дн." : "Срок заканчивается сегодня").font(.system(size: 13)).foregroundStyle(days < 14 ? Night.fresh : Night.muted) }
        case false?:
            Label("Подписки нет — видео в высоком качестве и загрузки могут быть недоступны", systemImage: "xmark.seal").font(.system(size: 15, weight: .semibold)).foregroundStyle(Night.danger)
        case nil:
            Text("Проверяю подписку…").font(.system(size: 14)).foregroundStyle(Night.muted)
        }
    }
    func row<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8, content: c).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Night.panel, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Night.stroke))
    }

}
