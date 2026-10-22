import Foundation
import SwiftUI

// Новые версии выходят на GitHub. iPhone не может поставить IPA сам, поэтому приложение
// только сообщает о новой версии и открывает страницу релиза, где лежит файл для GBox.
struct AppRelease: Identifiable, Equatable { let version: String; let notes: String; let page: URL; var id: String { version } }

enum Updater {
    static let repo = "porwatkinoff-it/yoru-anime"
    static let page = URL(string: "https://github.com/\(repo)/releases/latest")!
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    // Сравнение версий вида 2.0.10 > 2.0.9.
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }, y = b.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for i in 0..<max(x.count, y.count) { let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0; if p != q { return p > q } }
        return false
    }
    // Автопроверка не чаще раза в 6 часов; ручная — всегда.
    static var due: Bool { Date().timeIntervalSince(UserDefaults.standard.object(forKey: "update-checked") as? Date ?? .distantPast) > 6 * 3600 }
    static func check() async throws -> AppRelease? {
        UserDefaults.standard.set(Date(), forKey: "update-checked")
        var r = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept"); r.setValue("NightAnime/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200, let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError(message: "GitHub не ответил (\(code))") }
        let version = (o["tag_name"] as? String ?? "").replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
        guard newer(version, than: current) else { return nil }
        return AppRelease(version: version, notes: (o["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines), page: (o["html_url"] as? String).flatMap(URL.init) ?? page)
    }
}

// Строка «Обновления» в меню аккаунта.
struct UpdatePanel: View {
    @Environment(\.openURL) var openURL
    @State var release: AppRelease?
    @State var status = ""
    @State var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Обновления").font(.system(size: 17, weight: .bold)).foregroundStyle(Night.text)
            Text("Установлена версия \(Updater.current). Новые версии выходят на GitHub.").font(.system(size: 13)).foregroundStyle(Night.muted)
            if let release {
                Text("Доступна версия \(release.version)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Night.scoreHigh)
                Button("Скачать на GitHub") { openURL(release.page) }.buttonStyle(NightButtonStyle(selected: true))
            } else {
                if !status.isEmpty { Text(status).font(.system(size: 13)).foregroundStyle(Night.muted) }
                Button(busy ? "Проверяю…" : "Проверить обновления") { Task { busy = true; do { release = try await Updater.check(); status = release == nil ? "У вас последняя версия" : "" } catch { status = error.localizedDescription }; busy = false } }
                    .buttonStyle(NightButtonStyle()).disabled(busy)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Night.panel, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Night.stroke))
    }
}
