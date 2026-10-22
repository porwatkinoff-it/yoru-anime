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

    override init() {
        super.init()
        if let data = try? Data(contentsOf: index), let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) { items = saved }
        // Пропавшие файлы убираем; «качается», но задачи нет (приложение было удалено из памяти до старта) — помечаем ошибкой.
        items.removeAll { $0.state == .done && !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.video).path) }
        session.getAllTasks { tasks in
            let alive = Set(tasks.compactMap { $0.taskDescription.flatMap(Int.init) })
            Task { @MainActor in
                for i in self.items.indices where (self.items[i].state == .running || self.items[i].state == .queued) && !alive.contains(self.items[i].id) {
                    self.items[i].state = .failed; self.items[i].error = "Загрузка прервалась"
                }
                self.save()
            }
        }
    }

    func item(_ episode: Int) -> DownloadItem? { items.first { $0.id == episode } }
    func save() { try? JSONEncoder().encode(items).write(to: index, options: .atomic) }
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
        let task = session.downloadTask(with: r); task.taskDescription = "\(id)"
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
        items.removeAll { $0.id == id }; save()
    }
    func removeSeries(_ seriesId: Int) { items.filter { $0.seriesId == seriesId }.forEach { remove($0.id) } }
    // После досмотра: «Удалять просмотренные» как умные загрузки у Netflix.
    func watched(_ episode: Int) { if autoDelete, item(episode)?.state == .done { remove(episode) } }

    // Просмотр скачанной серии считается как обычный: «Продолжить», история и плитка на ТВ.
    func playback(_ d: DownloadItem, hasNext: Bool = false, store: AnimeStore) -> Playback {
        let t = Translation(["id": d.translationId, "type": d.translationKind ?? "", "authorsSummary": d.translationAuthors ?? ""])
        store.remember(t, Episode(["id": d.id, "episodeFull": d.episodeTitle, "episodeInt": d.episodeNumber]), d.item)
        return Playback(options: [VideoOption(id: "file", url: folder.appendingPathComponent(d.video), height: d.height)], subtitles: d.subtitles.map { folder.appendingPathComponent($0) },
                 title: "\(d.item.title) · \(d.episodeTitle)", key: "position-\(d.translationId)", episodeId: d.id, hasNext: hasNext, offline: true)
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
            if moved { items[i].state = .done; items[i].bytes = Int64(size); items[i].total = Int64(size); items[i].error = nil }
            else { items[i].state = .failed; items[i].error = code == 403 || code == 401 || code == 410 ? "Ссылка устарела — нажмите, чтобы повторить" : "Сервер не отдал файл (\(code))" }
            save()
        }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(Int.init) else { return }
        MainActor.assumeIsolated {
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            // Публикуем не чаще, чем раз в процент, — иначе список перерисовывается сотни раз в секунду.
            let total = max(totalBytesExpectedToWrite, 0), step = max(total / 100, 1 << 20)
            if totalBytesWritten - items[i].bytes >= step || items[i].total != total { items[i].bytes = totalBytesWritten; items[i].total = total; items[i].state = .running }
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription.flatMap(Int.init) else { return }
        let ns = error as NSError
        if ns.code != NSURLErrorCancelled, task.originalRequest?.url?.host == Servers.best { Servers.best = nil }
        MainActor.assumeIsolated {
            guard ns.code != NSURLErrorCancelled, let i = items.firstIndex(where: { $0.id == id }) else { return }
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
