import ActivityKit
import Foundation
import UIKit

// Скачанная серия. Файлы лежат в Application Support/Downloads внутри приложения: <id серии>.mp4 и субтитры рядом.
struct DownloadItem: Codable, Identifiable, Equatable {
    enum State: String, Codable { case queued, running, failed, done }
    let id: Int                 // id серии (episode) на Anime 365
    let seriesId: Int
    let series: Data            // карточка аниме — чтобы «Загрузки» работали без сети
    let episodeTitle: String
    let episodeNumber: Double
    let translationId: Int
    let translationTitle: String
    var translationKind: String? = nil
    var translationAuthors: String? = nil
    var height: Int
    var video: String           // имя файла
    var subtitles: String?
    var bytes: Int64 = 0
    var total: Int64 = 0
    var state: State = .queued
    var error: String?
    var created = Date()
    var item: AnimeItem { AnimeItem((try? JSONSerialization.jsonObject(with: series)) as? [String: Any] ?? [:]) }
    var progress: Double { state == .done ? 1 : total > 0 ? Double(bytes) / Double(total) : 0 }
}

// Загрузки в духе Netflix и Кинопоиска: серия качается в фоне, даже если приложение закрыто,
// играет без интернета, учитывает качество и «только по Wi‑Fi», может удаляться после просмотра.
@MainActor final class DownloadCenter: NSObject, ObservableObject {
    static let shared = DownloadCenter()
    static let sessionId = "com.resvvt.nightanime.downloads"
    // «Наилучшее»: самое высокое качество, которое есть у перевода (4K, 1440p, 1080p…).
    static let best = 100_000
    static func label(_ h: Int) -> String { h >= 2160 ? "4K" : h > 0 ? "\(h)p" : "Файл" }
    @Published private(set) var items: [DownloadItem] = []
    @Published var quality = UserDefaults.standard.object(forKey: "dl-quality") as? Int ?? 720 { didSet { UserDefaults.standard.set(quality, forKey: "dl-quality") } }
    @Published var wifiOnly = UserDefaults.standard.object(forKey: "dl-wifi") as? Bool ?? true { didSet { UserDefaults.standard.set(wifiOnly, forKey: "dl-wifi") } }
    @Published var autoDelete = UserDefaults.standard.bool(forKey: "dl-autodelete") { didSet { UserDefaults.standard.set(autoDelete, forKey: "dl-autodelete") } }
    var backgroundCompletion: (() -> Void)?
    // Когда прогресс каждой загрузки последний раз показывался на экране.
    private var published: [Int: TimeInterval] = [:]
    // Скорость каждой загрузки (байт/с, сглаженная) — для строки «5,2 МБ/с» в «Загрузках».
    private(set) var rates: [Int: Double] = [:]
    private var rateSample: [Int: (bytes: Int64, time: TimeInterval)] = [:]
    func rate(_ id: Int) -> Double { items.first { $0.id == id }?.state == .running ? rates[id] ?? 0 : 0 }
    var totalRate: Double { items.filter { $0.state == .running }.reduce(0) { $0 + (rates[$1.id] ?? 0) } }
    static func speed(_ v: Double) -> String { size(Int64(v)) + "/с" }
    nonisolated let folder: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true; var w = u; try? w.setResourceValues(v)
        return u
    }()
    var index: URL { folder.appendingPathComponent("index.json") }
    lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionId)
        c.sessionSendsLaunchEvents = true; c.isDiscretionary = false; c.httpMaximumConnectionsPerHost = 2
        c.httpAdditionalHeaders = ["User-Agent": "NightAnime/1.0 (iOS)"]
        return URLSession(configuration: c, delegate: self, delegateQueue: .main)
    }()

    // Нужен, чтобы самим докачать прерванное: свежую ссылку даёт только сайт.
    weak var store: AnimeStore? { didSet { if store != nil, oldValue == nil { resumeInterrupted() } } }
    // Live Activity и оценка скорости для неё.
    private var activity: Activity<DownloadAttributes>?
    private var batch: Set<Int> = []
    private var speed: Double = 0
    private var sample: (bytes: Int64, time: TimeInterval)?
    private var liveAt: TimeInterval = 0
    private var interrupted = false

    override init() {
        super.init()
        let d = UserDefaults.standard
        // Чистая установка (в том числе после удаления приложения): список загрузок восстановится из аккаунта Yoru.
        if d.string(forKey: "dl-ids") == nil && !FileManager.default.fileExists(atPath: index.path) { d.set(true, forKey: "dl-fresh") }
        if let data = try? Data(contentsOf: index), let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) { items = saved }
        // Пропавшие файлы убираем.
        items.removeAll { $0.state == .done && !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.video).path) }
        activity = Activity<DownloadAttributes>.activities.first
        batch = Set(items.filter { $0.state == .running || $0.state == .queued }.map(\.id))
        // «Качается», но задачи нет: систему перезапустили, приложение обновили или смахнули из памяти.
        // Такие серии докачиваются сами, как только есть ссылка сайта (см. resumeInterrupted).
        // Проверяем только то, что качалось до запуска: новые загрузки за эти миллисекунды уже со своей задачей.
        let pending = batch
        session.getAllTasks { tasks in
            let alive = Set(tasks.compactMap { $0.taskDescription.flatMap(Int.init) })
            Task { @MainActor in
                for i in self.items.indices where pending.contains(self.items[i].id) && (self.items[i].state == .running || self.items[i].state == .queued) && !alive.contains(self.items[i].id) {
                    self.items[i].state = .queued; self.items[i].error = "Продолжится автоматически"; self.interrupted = true
                }
                self.save()
                // Сначала даём сессии отдать задачи, отменённые системой: у них есть данные для докачки.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.resumeInterrupted() }
            }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { self.updateLive(force: true) } }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { self.updateLive(force: true) } }
    }

    // Прерванные серии: новая ссылка у сайта и загрузка заново. Не больше трёх попыток подряд на серию.
    func resumeInterrupted() {
        var signedIn = store.map { !$0.token.isEmpty } ?? false
        #if DEBUG
        if QA.value("--qa-download-url") != nil { signedIn = true }
        #endif
        guard interrupted, let store, signedIn else { return }
        interrupted = false
        session.getAllTasks { tasks in
            let alive = Set(tasks.compactMap { $0.taskDescription.flatMap(Int.init) })
            Task { @MainActor in
                for d in self.items where d.state == .queued && d.error == "Продолжится автоматически" && !alive.contains(d.id) {
                    if self.tries(d.id) >= 3 { self.fail(d.id, "Загрузка прервалась"); continue }
                    self.retry(d.id, store: store)
                }
            }
        }
    }
    private func tries(_ id: Int) -> Int {
        let n = UserDefaults.standard.integer(forKey: "dl-auto-\(id)"); UserDefaults.standard.set(n + 1, forKey: "dl-auto-\(id)"); return n
    }
    private func fail(_ id: Int, _ message: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = .failed; items[i].error = message; save()
    }
    // После переустановки: как только аккаунт прислал список и вход в Anime 365, серии качаются заново сами.
    func autoRestore(store: AnimeStore) {
        resumeInterrupted()   // вход в Anime 365 мог прийти из аккаунта только сейчас
        guard UserDefaults.standard.bool(forKey: "dl-fresh"), !store.token.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: "dl-fresh")
        if !missing.isEmpty { restore(store: store) }
    }

    func item(_ episode: Int) -> DownloadItem? { items.first { $0.id == episode } }
    func save() {
        try? JSONEncoder().encode(items).write(to: index, options: .atomic)
        // Набор загрузок изменился — список уходит в аккаунт Yoru, чтобы после переустановки скачать их заново.
        let ids = items.map(\.id).sorted().map(String.init).joined(separator: ",")
        // Первое сохранение на чистой установке не трогает отметку времени: иначе пустой список
        // «побеждает» в аккаунте и затирает загрузки, которые нужно восстановить.
        let stored = UserDefaults.standard.string(forKey: "dl-ids")
        if ids != stored {
            UserDefaults.standard.set(ids, forKey: "dl-ids")
            if stored != nil || !ids.isEmpty { UserDefaults.standard.set(HistoryState.now(), forKey: "dl-t"); YoruAccount.shared.changed() }
        }
        updateLive(force: true)
    }
    // Загрузки с других устройств и из прошлой установки, которых здесь нет.
    @Published var remote: [[String: Any]] = (HistoryState.loadJSON("dl-remote") as? [String: Any])?["items"] as? [[String: Any]] ?? [] { didSet { objectWillChange.send() } }
    var missing: [[String: Any]] {
        let have = Set(items.map(\.id)), hidden = Set(UserDefaults.standard.array(forKey: "dl-hidden") as? [Int] ?? [])
        // Просмотренные серии заново не качаем и не предлагаем.
        return remote.filter { let id = Int(HistoryState.number($0["id"])); return id > 0 && !have.contains(id) && !hidden.contains(id) && !UserDefaults.standard.bool(forKey: "done-\(id)") }
    }
    func exportSync(into o: inout [String: Any]) {
        let list: [[String: Any]] = items.map { d in
            ["id": d.id, "seriesId": d.seriesId, "series": (try? JSONSerialization.jsonObject(with: d.series)) ?? [:], "episodeTitle": d.episodeTitle, "episodeNumber": d.episodeNumber,
             "translationId": d.translationId, "translationTitle": d.translationTitle, "translationKind": d.translationKind ?? "", "translationAuthors": d.translationAuthors ?? "", "height": d.height]
        }
        o["downloads"] = ["t": HistoryState.int64("dl-t"), "items": list]
    }
    func mergeSync(_ i: [String: Any]) {
        guard let l = i["downloads"] as? [String: Any], let list = l["items"] as? [[String: Any]] else { return }
        HistoryState.storeJSON(l, "dl-remote"); remote = list
    }
    func hideMissing() { UserDefaults.standard.set(missing.map { Int(HistoryState.number($0["id"])) } + (UserDefaults.standard.array(forKey: "dl-hidden") as? [Int] ?? []), forKey: "dl-hidden"); objectWillChange.send() }
    // Скачивает заново по одной: у сайта каждый раз берётся свежая ссылка.
    func restore(store: AnimeStore) {
        let list = missing
        for o in list {
            let id = Int(HistoryState.number(o["id"]))
            let series = (o["series"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
            let rec = DownloadItem(id: id, seriesId: Int(HistoryState.number(o["seriesId"])), series: series, episodeTitle: o["episodeTitle"] as? String ?? "", episodeNumber: (o["episodeNumber"] as? NSNumber)?.doubleValue ?? 0,
                                   translationId: Int(HistoryState.number(o["translationId"])), translationTitle: o["translationTitle"] as? String ?? "", translationKind: o["translationKind"] as? String,
                                   translationAuthors: o["translationAuthors"] as? String, height: Int(HistoryState.number(o["height"])), video: "\(id).mp4", state: .failed, error: Self.waiting)
            items.append(rec)
        }
        save()
        Task {
            for o in list {
                let id = Int(HistoryState.number(o["id"]))
                guard let d = item(id) else { continue }
                let t = Translation(["id": d.translationId, "type": d.translationKind ?? "", "authorsSummary": d.translationAuthors ?? "", "title": d.translationTitle])
                let e = Episode(["id": d.id, "episodeFull": d.episodeTitle, "episodeInt": d.episodeNumber])
                if let i = items.firstIndex(where: { $0.id == id }) { items[i].state = .running; items[i].error = nil }
                do { try await enqueue(t, e, d.item, store: store) }
                catch { if let i = items.firstIndex(where: { $0.id == id }) { items[i].state = .failed; items[i].error = error.localizedDescription; save() } }
            }
        }
    }
    var usedBytes: Int64 { items.reduce(0) { $0 + ($1.state == .done ? max($1.total, $1.bytes) : $1.bytes) } }
    var freeBytes: Int64 { (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage).flatMap { $0 } ?? 0 }

    // Ставит серию в очередь: берёт у сайта прямые ссылки, выбирает качество и сразу скачивает субтитры.
    func enqueue(_ t: Translation, _ e: Episode, _ series: AnimeItem, store: AnimeStore) async throws {
        if let existing = item(e.id), existing.state == .done || (existing.state == .running && existing.bytes > 0) { return }
        var urls: [(Int, URL)] = []
        var subtitles: URL?
        #if DEBUG
        if let test = QA.value("--qa-download-url"), let u = URL(string: test) { urls = [(720, u)] }
        #endif
        if urls.isEmpty {
            let d = try await store.embed(t)
            // Ссылки «stream» ведут прямо на видеосервер (mp4 с докачкой). Ссылки «download» — на страницу сайта,
            // которая без входа через браузер отвечает 403, поэтому они только запасные.
            for o in d["stream"] as? [[String: Any]] ?? [] { if let s = (o["urls"] as? [String])?.first, let u = store.makeURL(s) { urls.append(((o["height"] as? NSNumber)?.intValue ?? 0, u)) } }
            if urls.isEmpty { for o in d["download"] as? [[String: Any]] ?? [] { if let s = o["url"] as? String, let u = store.makeURL(s) { urls.append(((o["height"] as? NSNumber)?.intValue ?? 0, u)) } } }
            subtitles = (d["subtitlesUrl"] as? String).flatMap(store.makeURL)
            if t.kind.hasPrefix("sub") && subtitles == nil { throw APIError(message: "Для этого перевода сайт не дал субтитры. Выберите другой перевод.") }
        }
        guard !urls.isEmpty else { throw APIError(message: "Сайт не дал ссылку для скачивания. Проверьте подписку или выберите другой перевод.") }
        // Лучшее качество, не выше выбранного в настройках; если такого нет — самое низкое из доступных.
        let chosen = urls.filter { $0.0 <= quality }.max { $0.0 < $1.0 } ?? urls.min { $0.0 < $1.0 }!
        Servers.remember(urls.map(\.1))
        let fit = (chosen.0, Servers.preferred(chosen.1)[0])
        var subtitleName: String?
        if let subtitles {
            var r = URLRequest(url: subtitles); r.setValue("NightAnime/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: r), (response as? HTTPURLResponse)?.statusCode == 200, data.count < 8_000_000,
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251), text.contains("[Events]") || text.contains("-->") else { throw APIError(message: "Не удалось скачать субтитры. Повторите позже.") }
            let name = "\(e.id).\(text.contains("[Events]") ? "ass" : text.hasPrefix("WEBVTT") ? "vtt" : "srt")"
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8); subtitleName = name
        }
        let record = DownloadItem(id: e.id, seriesId: series.id, series: series.raw, episodeTitle: e.title, episodeNumber: e.number, translationId: t.id, translationTitle: t.title,
                                  translationKind: t.kind, translationAuthors: String(t.signature.split(separator: "|", maxSplits: 1).last ?? ""),
                                  height: fit.0, video: "\(e.id).mp4", subtitles: subtitleName, state: .running)
        items.removeAll { $0.id == e.id }; items.append(record); save()
        // Скачивание не делает аниме «начатым» — запоминаем только перевод для следующих серий.
        UserDefaults.standard.set(t.signature, forKey: "tr-\(series.id)")
        start(record.id, fit.1)
    }
    func start(_ id: Int, _ url: URL) {
        var r = URLRequest(url: url); r.allowsCellularAccess = !wifiOnly
        let task = session.downloadTask(with: r); task.taskDescription = "\(id)"; batch.insert(id)
        UserDefaults.standard.set(url.absoluteString, forKey: "dl-url-\(id)")
        task.resume()
    }
    // Повтор берёт у сайта свежую ссылку: ссылки на видеосервер живут ограниченное время.
    func retry(_ id: Int, store: AnimeStore) {
        guard let d = item(id) else { return }
        let t = Translation(["id": d.translationId, "type": d.translationKind ?? "", "authorsSummary": d.translationAuthors ?? ""])
        let e = Episode(["id": d.id, "episodeFull": d.episodeTitle, "episodeInt": d.episodeNumber])
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].state = .running; items[i].error = nil; items[i].bytes = 0 }
        Task {
            do { try await enqueue(t, e, d.item, store: store) }
            catch { if let i = items.firstIndex(where: { $0.id == id }) { items[i].state = .failed; items[i].error = error.localizedDescription; save() } }
        }
    }
    func remove(_ id: Int) {
        session.getAllTasks { tasks in tasks.filter { $0.taskDescription == "\(id)" }.forEach { $0.cancel() } }
        if let d = item(id) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(d.video)); if let s = d.subtitles { try? FileManager.default.removeItem(at: folder.appendingPathComponent(s)) } }
        items.removeAll { $0.id == id }; rates[id] = nil; rateSample[id] = nil
        // Удалённую здесь серию не предлагаем «восстановить»: она уходит и из списка аккаунта.
        if remote.contains(where: { Int(HistoryState.number($0["id"])) == id }) {
            remote.removeAll { Int(HistoryState.number($0["id"])) == id }
            HistoryState.storeJSON(["t": HistoryState.int64("dl-t"), "items": remote], "dl-remote")
        }
        save()
    }
    func removeSeries(_ seriesId: Int) { items.filter { $0.seriesId == seriesId }.forEach { remove($0.id) } }
    // После досмотра: «Удалять просмотренные» как умные загрузки у Netflix.
    func watched(_ episode: Int) { if autoDelete, item(episode)?.state == .done { remove(episode) } }

    // Просмотр скачанной серии считается как обычный: «Продолжить», история и плитка на ТВ.
    func playback(_ d: DownloadItem, hasNext: Bool = false, store: AnimeStore) -> Playback {
        let t = Translation(["id": d.translationId, "type": d.translationKind ?? "", "authorsSummary": d.translationAuthors ?? ""])
        store.remember(t, Episode(["id": d.id, "episodeFull": d.episodeTitle, "episodeInt": d.episodeNumber]), d.item)
        return Playback(options: [VideoOption(id: "file", url: folder.appendingPathComponent(d.video), height: d.height)], subtitles: d.subtitles.map { folder.appendingPathComponent($0) },
                 title: "\(d.item.title) · \(d.episodeTitle)", key: "position-\(d.translationId)", episodeId: d.id, hasNext: hasNext, offline: true, poster: d.item.poster)
    }
    static let sizes: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .file; f.allowsNonnumericFormatting = false; return f }()
    static func size(_ bytes: Int64) -> String { sizes.string(fromByteCount: bytes) }
}

extension DownloadCenter: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Файл нужно забрать до выхода из метода — потом система его удалит.
        guard let id = downloadTask.taskDescription.flatMap(Int.init) else { return }
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let target = folder.appendingPathComponent("\(id).mp4")
        var moved = false
        if code == 200 || code == 206 { try? FileManager.default.removeItem(at: target); moved = (try? FileManager.default.moveItem(at: location, to: target)) != nil }
        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        // Быстрый сервер подвёл — дальше берём ссылки сайта, пока проверка не найдёт новый.
        if !moved, downloadTask.originalRequest?.url?.host == Servers.best { Servers.best = nil }
        MainActor.assumeIsolated {
            guard let i = items.firstIndex(where: { $0.id == id }) else { try? FileManager.default.removeItem(at: target); return }
            if moved { items[i].state = .done; items[i].bytes = Int64(size); items[i].total = Int64(size); items[i].error = nil; UserDefaults.standard.removeObject(forKey: "dl-auto-\(id)") }
            else { items[i].state = .failed; items[i].error = code == 403 || code == 401 || code == 410 ? "Ссылка устарела — нажмите, чтобы повторить" : "Сервер не отдал файл (\(code))" }
            save()
        }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(Int.init) else { return }
        MainActor.assumeIsolated {
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            // Публикуем не чаще раза в секунду и не мельче процента — иначе список перерисовывается десятки раз в секунду.
            let total = max(totalBytesExpectedToWrite, 0), step = max(total / 100, 1 << 20), now = ProcessInfo.processInfo.systemUptime
            if items[i].total != total || (totalBytesWritten - items[i].bytes >= step && now - (published[id] ?? 0) >= 1) {
                if let p = rateSample[id], now > p.time, totalBytesWritten >= p.bytes {
                    let v = Double(totalBytesWritten - p.bytes) / (now - p.time); rates[id] = (rates[id] ?? 0) == 0 ? v : rates[id]! * 0.6 + v * 0.4
                }
                rateSample[id] = (totalBytesWritten, now)
                items[i].bytes = totalBytesWritten; items[i].total = total; items[i].state = .running; items[i].error = nil; published[id] = now
                updateLive()
            }
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription.flatMap(Int.init) else { return }
        let ns = error as NSError
        if ns.code != NSURLErrorCancelled, task.originalRequest?.url?.host == Servers.best { Servers.best = nil }
        // Отмена системой (обновление приложения, нехватка ресурсов, смахнули из памяти) — не ошибка: докачиваем с того же места,
        // а если данных для докачки нет — берём у сайта свежую ссылку.
        let system = ns.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] != nil
        let resume = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        MainActor.assumeIsolated {
            guard ns.code != NSURLErrorCancelled || system, let i = items.firstIndex(where: { $0.id == id }) else { return }
            if system || ns.code == NSURLErrorNetworkConnectionLost || ns.code == NSURLErrorTimedOut, tries(id) < 3 {
                if let resume {
                    let t = session.downloadTask(withResumeData: resume); t.taskDescription = "\(id)"; t.resume()
                    items[i].state = .running; items[i].error = nil; save(); return
                }
                if system { items[i].state = .queued; items[i].error = "Продолжится автоматически"; interrupted = true; save(); resumeInterrupted(); return }
            }
            items[i].state = .failed
            items[i].error = ns.code == NSURLErrorNotConnectedToInternet || ns.code == NSURLErrorNetworkConnectionLost ? "Нет сети — повторите позже"
                : ns.code == NSURLErrorCannotWriteToFile || ns.code == NSURLErrorCannotCreateFile ? "Не хватает места на устройстве"
                : (ns.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] != nil ? "Загрузка прервалась" : "Ошибка загрузки")
            save()
        }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated { backgroundCompletion?(); backgroundCompletion = nil }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == DownloadCenter.sessionId else { return completionHandler() }
        DownloadCenter.shared.backgroundCompletion = completionHandler
        _ = DownloadCenter.shared.session
    }
}

// Live Activity: прогресс загрузок в Dynamic Island и на экране блокировки, пока приложение свёрнуто.
extension DownloadCenter {
    static let waiting = "Ждёт загрузки"
    func updateLive(force: Bool = false) {
        let active = items.filter { $0.state == .running || $0.state == .queued || ($0.state == .failed && $0.error == Self.waiting) }
        batch.formUnion(active.map(\.id))
        let inBatch = items.filter { batch.contains($0.id) }
        let done = inBatch.filter { $0.state == .done }.count, failed = inBatch.filter { $0.state == .failed && $0.error != Self.waiting }.count
        if active.isEmpty {
            batch = []; speed = 0; sample = nil
            guard let a = activity else { return }
            activity = nil
            let st = DownloadAttributes.ContentState(title: "", left: 0, done: done, failed: failed, fraction: 1, finished: true)
            Task { await a.end(ActivityContent(state: st, staleDate: nil), dismissalPolicy: done > 0 ? .after(Date().addingTimeInterval(15 * 60)) : .immediate) }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - liveAt >= 2 else { return }
        liveAt = now
        let bytes = inBatch.reduce(Int64(0)) { $0 + ($1.state == .done ? max($1.total, $1.bytes) : $1.bytes) }
        // Скорость — скользящее среднее по всем сериям пачки.
        if let s = sample { if now - s.time >= 1 { let v = Double(bytes - s.bytes) / (now - s.time); if v >= 0 { speed = speed == 0 ? v : speed * 0.7 + v * 0.3 }; sample = (bytes, now) } } else { sample = (bytes, now) }
        // Размер ещё не начатых серий неизвестен — считаем их средними.
        let known = inBatch.filter { $0.total > 0 }
        let average = known.isEmpty ? 0 : known.reduce(Int64(0)) { $0 + $1.total } / Int64(known.count)
        let total = inBatch.reduce(Int64(0)) { $0 + ($1.total > 0 ? $1.total : average) }
        let fraction = total > 0 ? min(Double(bytes) / Double(total), 1) : 0
        let current = active.first { $0.state == .running && $0.bytes > 0 } ?? active[0]
        var st = DownloadAttributes.ContentState(title: "\(current.item.title) · \(current.episodeTitle)", left: active.count, done: done, failed: failed, fraction: fraction)
        if speed > 4096, total > bytes, fraction < 0.999 {
            let eta = Double(total - bytes) / speed * 1.1
            if eta < 12 * 3600 { let n = Date(); st.end = n.addingTimeInterval(eta); st.start = n.addingTimeInterval(-eta * fraction / (1 - fraction)) }
        }
        let content = ActivityContent(state: st, staleDate: st.end?.addingTimeInterval(600))
        if let a = activity { Task { await a.update(content) } }
        else if ActivityAuthorizationInfo().areActivitiesEnabled, UIApplication.shared.applicationState == .active {
            activity = try? Activity.request(attributes: DownloadAttributes(), content: content)
        }
    }
}
