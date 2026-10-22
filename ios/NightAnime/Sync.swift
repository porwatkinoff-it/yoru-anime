import Foundation
import Network

// Общая история просмотра в том же формате, что у Android и ТВ (State.java):
// побеждает более свежая запись по отметке времени, просмотренные серии объединяются.
// Токен Anime 365 в обмен не попадает.
enum HistoryState {
    static var d: UserDefaults { .standard }
    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static func savePosition(_ key: String, _ value: Int) { d.set(value, forKey: key); d.set(now(), forKey: "ts-" + key) }
    static func int64(_ key: String) -> Int64 { (d.object(forKey: key) as? NSNumber)?.int64Value ?? 0 }
    static func number(_ any: Any?) -> Int64 { (any as? NSNumber)?.int64Value ?? 0 }
    // Объекты с сайта содержат null, а UserDefaults такие словари не принимает — храним их как JSON.
    static func storeJSON(_ value: Any?, _ key: String) { d.set(value.flatMap { try? JSONSerialization.data(withJSONObject: $0) }, forKey: key) }
    static func loadJSON(_ key: String) -> Any? { d.data(forKey: key).flatMap { try? JSONSerialization.jsonObject(with: $0) } }

    static func export() -> [String: Any] {
        var o: [String: Any] = ["v": 1]
        for k in ["favorites", "history"] {
            let items = (d.array(forKey: k) as? [Data] ?? []).compactMap { try? JSONSerialization.jsonObject(with: $0) }
            o[k] = ["t": int64("t-" + k), "items": items]
        }
        var series: [String: Any] = [:], done: [Int] = [], positions: [String: Any] = [:]
        for (k, v) in d.dictionaryRepresentation() {
            if k.hasPrefix("done-"), (v as? Bool) == true, let id = Int(k.dropFirst(5)) { done.append(id) }
            else if k.hasPrefix("last-"), let sid = Optional(String(k.dropFirst(5))) { series[sid] = ["last": number(v), "tr": d.string(forKey: "tr-" + sid) ?? "", "t": int64("stamp-" + sid)] }
            else if k.hasPrefix("position-") { positions[k] = ["v": number(v), "t": int64("ts-" + k)] }
        }
        o["series"] = series; o["done"] = done; o["positions"] = positions
        if let item = loadJSON("lp-item") {
            o["lastPlay"] = ["item": item, "episode": loadJSON("lp-episode") ?? [:], "translation": loadJSON("lp-translation") ?? [:], "t": int64("lp-t")]
        }
        return o
    }

    @MainActor static func merge(_ i: [String: Any], into store: AnimeStore) {
        for k in ["favorites", "history"] {
            // Свежий список побеждает; пустой список (например, на новом телефоне) берётся с другого устройства.
            let localEmpty = (d.array(forKey: k) ?? []).isEmpty
            guard let l = i[k] as? [String: Any], let items = l["items"] as? [[String: Any]], number(l["t"]) > int64("t-" + k) || (localEmpty && !items.isEmpty) else { continue }
            let parsed = items.map(AnimeItem.init)
            d.set(parsed.map(\.raw), forKey: k); d.set(max(number(l["t"]), int64("t-" + k)), forKey: "t-" + k)
            if k == "favorites" { store.favorites = parsed } else { store.history = parsed }
        }
        for (sid, value) in i["series"] as? [String: Any] ?? [:] {
            guard let s = value as? [String: Any], number(s["t"]) > int64("stamp-" + sid) else { continue }
            d.set(Int(number(s["last"])), forKey: "last-" + sid)
            if let tr = s["tr"] as? String, !tr.isEmpty { d.set(tr, forKey: "tr-" + sid) }
            d.set(number(s["t"]), forKey: "stamp-" + sid)
        }
        for id in i["done"] as? [Any] ?? [] { d.set(true, forKey: "done-\(number(id))") }
        for (k, value) in i["positions"] as? [String: Any] ?? [:] {
            guard k.hasPrefix("position-"), let p = value as? [String: Any], number(p["t"]) > int64("ts-" + k) else { continue }
            d.set(Int(number(p["v"])), forKey: k); d.set(number(p["t"]), forKey: "ts-" + k)
        }
        if let lp = i["lastPlay"] as? [String: Any], number(lp["t"]) > int64("lp-t"), let item = lp["item"] {
            storeJSON(item, "lp-item"); storeJSON(lp["episode"] ?? [:], "lp-episode"); storeJSON(lp["translation"] ?? [:], "lp-translation"); d.set(number(lp["t"]), forKey: "lp-t")
        }
        store.objectWillChange.send()
    }
}

// Находит приставку (Night Air объявляет _nightanime._tcp) и обменивается с ней историей.
enum TVSync {
    static var running = false

    @MainActor static func run(_ store: AnimeStore) async {
        #if DEBUG
        // Тестовые данные (--fixtures) не должны попадать в настоящую историю на телевизоре.
        if QA.value("--fixtures") != nil || QA.value("--player-file") != nil { return }
        #endif
        guard !running else { return }
        running = true; defer { running = false }
        guard let endpoint = await find() else { return }
        do {
            let remote = try await http(endpoint, "GET", body: nil)
            if let json = try JSONSerialization.jsonObject(with: remote) as? [String: Any] { HistoryState.merge(json, into: store) }
            let body = try JSONSerialization.data(withJSONObject: HistoryState.export())
            _ = try await http(endpoint, "POST", body: body)
        } catch { }
    }

    static func find() async -> NWEndpoint? {
        await withCheckedContinuation { (c: CheckedContinuation<NWEndpoint?, Never>) in
            let browser = NWBrowser(for: .bonjour(type: "_nightanime._tcp", domain: nil), using: .tcp)
            var finished = false
            let finish: (NWEndpoint?) -> Void = { e in guard !finished else { return }; finished = true; browser.cancel(); c.resume(returning: e) }
            browser.browseResultsChangedHandler = { results, _ in if let r = results.first { finish(r.endpoint) } }
            browser.stateUpdateHandler = { if case .failed = $0 { finish(nil) } }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finish(nil) }
        }
    }

    // Простой HTTP/1.1 поверх NWConnection: Bonjour-адрес сразу подходит для подключения.
    static func http(_ endpoint: NWEndpoint, _ method: String, body: Data?) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            let conn = NWConnection(to: endpoint, using: .tcp)
            var buffer = Data(), finished = false
            let finish: (Result<Data, Error>) -> Void = { r in guard !finished else { return }; finished = true; conn.cancel(); c.resume(with: r) }
            func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let data { buffer.append(data) }
                    if buffer.count > 4_000_000 { finish(.failure(APIError(message: "too large"))); return }
                    if complete || error != nil {
                        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)), let head = String(data: buffer[..<split.lowerBound], encoding: .utf8), head.hasPrefix("HTTP/1.1 200") else { finish(.failure(APIError(message: "sync failed"))); return }
                        finish(.success(buffer[split.upperBound...]))
                    } else { receive() }
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var request = Data("\(method) /state HTTP/1.1\r\nHost: night-tv\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: \(body?.count ?? 0)\r\n\r\n".utf8)
                    if let body { request.append(body) }
                    conn.send(content: request, completion: .contentProcessed { e in if let e { finish(.failure(e)) } else { receive() } })
                case .failed(let e): finish(.failure(e))
                default: break
                }
            }
            conn.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish(.failure(APIError(message: "timeout"))) }
        }
    }
}
