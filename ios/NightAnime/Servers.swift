import Foundation
import SwiftUI

// Видеосерверы Anime 365. Сайт в каждой ссылке даёт случайный сервер (ru-NNNNNN.<домен>), и любой из них
// отдаёт тот же файл по той же ссылке. Скорость у них разная, поэтому приложение запоминает серверы,
// которые встречало, проверяет их скорость и подставляет самый быстрый; ссылка сайта остаётся запасной.
struct ServerResult: Identifiable, Equatable { let host: String; var mbit: Double?; var error: String?; var id: String { host } }

enum Servers {
    static var d: UserDefaults { .standard }
    static var auto: Bool { get { d.object(forKey: "server-auto") as? Bool ?? true } set { d.set(newValue, forKey: "server-auto") } }
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
    static func test(sample: URL, each: @escaping @MainActor (ServerResult) -> Void) async -> [ServerResult] {
        var hosts = seen
        if let h = sample.host, isVideo(h), !hosts.contains(h) { hosts.insert(h, at: 0) }
        var out: [ServerResult] = []
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 15; config.urlCache = nil
        let session = URLSession(configuration: config)
        for host in hosts {
            var c = URLComponents(url: sample, resolvingAgainstBaseURL: false)!; c.host = host
            var r = URLRequest(url: c.url!); r.setValue("bytes=0-4194303", forHTTPHeaderField: "Range"); r.setValue("NightAnime/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            var result = ServerResult(host: host)
            let start = Date()
            do {
                let (data, response) = try await session.data(for: r)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code / 100 == 2, data.count > 100_000 { result.mbit = Double(data.count) * 8 / 1e6 / max(Date().timeIntervalSince(start), 0.001) }
                else { result.error = "не отдал файл (\(code))" }
            } catch { result.error = (error as NSError).code == NSURLErrorTimedOut ? "слишком медленно" : "недоступен" }
            out.append(result)
            await each(result)
        }
        let speeds = Dictionary(uniqueKeysWithValues: out.compactMap { r in r.mbit.map { (r.host, $0) } })
        d.set(speeds, forKey: "servers-mbit"); d.set(Date(), forKey: "servers-tested")
        // Неработающие серверы забываем, быстрые — в начало списка.
        d.set(out.filter { $0.mbit != nil }.sorted { $0.mbit! > $1.mbit! }.map(\.host), forKey: "servers-seen")
        best = out.filter { $0.mbit != nil }.max { $0.mbit! < $1.mbit! }?.host
        return out
    }
}

// Меню аккаунта: имя, подписка и видеосерверы с проверкой скорости.
struct AccountPanel: View {
    @EnvironmentObject var store: AnimeStore
    @State var results: [ServerResult] = []
    @State var testing = false
    @State var message = ""
    @State var auto = Servers.auto
    static let day: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM yyyy"; return f }()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row {
                Text(store.account).font(.system(size: 17, weight: .bold)).foregroundStyle(Night.text)
                subscription
            }
            row {
                Text("Сервер видео").font(.system(size: 17, weight: .bold)).foregroundStyle(Night.text)
                Picker("Сервер видео", selection: $auto) { Text("Самый быстрый").tag(true); Text("Как выдаёт сайт").tag(false) }.pickerStyle(.segmented)
                    .onChange(of: auto) { Servers.auto = auto }
                Text(auto ? "Видео и загрузки идут через самый быстрый из проверенных серверов. Если он не ответит, плеер возьмёт ссылку сайта." : "Каждую серию сайт отдаёт со случайного сервера.")
                    .font(.system(size: 13)).foregroundStyle(Night.muted)
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, r in
                    HStack {
                        Text("Сервер \(i + 1)").font(.system(size: 15, weight: .medium).monospacedDigit()).foregroundStyle(Night.text)
                        if r.host == Servers.best { Text("лучший").font(.system(size: 11, weight: .heavy)).foregroundStyle(Night.onAccent).padding(.horizontal, 6).padding(.vertical, 2).background(Night.scoreHigh, in: Capsule()) }
                        Spacer()
                        Text(r.mbit.map { String(format: "%.0f Мбит/с", $0) } ?? r.error ?? "—").font(.system(size: 14).monospacedDigit())
                            .foregroundStyle(r.mbit == nil ? Night.danger : r.mbit! >= 25 ? Night.scoreHigh : r.mbit! >= 8 ? Night.scoreMid : Night.scoreLow)
                    }
                }
                if testing { ProgressView().frame(maxWidth: .infinity) }
                if !message.isEmpty { Text(message).font(.system(size: 13)).foregroundStyle(Night.danger) }
                Button(testing ? "Проверяю…" : "Проверить серверы") { Task { await test() } }.buttonStyle(NightButtonStyle(selected: true)).disabled(testing)
                if let t = Servers.tested, !testing { Text("Последняя проверка: \(t.formatted(.relative(presentation: .named)))").font(.system(size: 12)).foregroundStyle(Night.muted) }
            }
        }
        .task { await store.refreshAccount() }
    }
    var shown: [ServerResult] {
        if !results.isEmpty { return results }
        let saved = Servers.results
        return Servers.seen.map { ServerResult(host: $0, mbit: saved[$0], error: saved[$0] == nil ? "не проверен" : nil) }
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
    func test() async {
        testing = true; message = ""; results = []
        do { let sample = try await store.serverSample(); _ = await Servers.test(sample: sample) { r in results.append(r) } }
        catch { message = error.localizedDescription }
        if !results.isEmpty { results.sort { ($0.mbit ?? -1) > ($1.mbit ?? -1) } }
        testing = false
    }
}
