import SwiftUI
import UIKit

@main struct NightAnimeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AnimeStore()
    @StateObject private var downloads = DownloadCenter.shared
    init() {
        let tab = UITabBarAppearance(); tab.configureWithOpaqueBackground(); tab.backgroundColor = UIColor(red: 0.03, green: 0.05, blue: 0.09, alpha: 0.96)
        UITabBar.appearance().standardAppearance = tab; UITabBar.appearance().scrollEdgeAppearance = tab
    }
    var body: some Scene { WindowGroup {
        if let qa = qaPlayback { NativePlayerView(playback: qa).ignoresSafeArea() }
        else if ProcessInfo.processInfo.arguments.contains("--subtitle-test"), let video = Bundle.main.url(forResource: "probe", withExtension: "mp4"), let subs = Bundle.main.url(forResource: "subtitles", withExtension: "ass") {
            NativePlayerView(playback: Playback(options: [VideoOption(id: "test", url: video, height: 720)], subtitles: subs, title: "Проверка ASS-субтитров", key: "subtitle-test")).ignoresSafeArea()
        } else { RootView().environmentObject(store).environmentObject(downloads).preferredColorScheme(.dark).tint(Night.accent) }
    } }
    // Отладочный запуск плеера с локальным файлом: --player-file=/path.mp4 [--player-subs=/path.ass].
    var qaPlayback: Playback? {
        #if DEBUG
        guard let file = QA.value("--player-file") else { return nil }
        return Playback(options: [VideoOption(id: "qa", url: URL(fileURLWithPath: file), height: 1080)], subtitles: QA.value("--player-subs").map { URL(fileURLWithPath: $0) }, title: "Проверка плеера · ONA 1 серия", key: "qa-player", hasNext: true)
        #else
        return nil
        #endif
    }
}

#if DEBUG
// Параметры запуска для проверки экранов в симуляторе; в Release их нет.
enum QA {
    static func has(_ name: String) -> Bool { ProcessInfo.processInfo.arguments.contains(name) }
    static func value(_ name: String) -> String? { ProcessInfo.processInfo.arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) } }
}
#endif

// Палитра и элементы оформления Night TV — те же цвета, что в Android-версии.
enum Night {
    static func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color { Color(red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255).opacity(alpha) }
    static let bg = rgb(0x0a101c)
    static let panel = rgb(0x202c3e, 0.63)
    static let card = rgb(0x172335, 0.31)
    static let accent = rgb(0xedf4ff)
    static let muted = rgb(0xa9a9bd)
    static let meta = rgb(0xaaaabd)
    static let stroke = Color.white.opacity(0.13)
    // Роли из replica/design/tokens.json.
    static let text = rgb(0xf2f5fb)
    static let surface = rgb(0x172335)
    static let raised = rgb(0x202c3e, 0.85)
    static let onAccent = rgb(0x0f1a2a)
    static let fresh = rgb(0xffcc80)
    static let scoreHigh = rgb(0x6fdc8c)
    static let scoreMid = rgb(0xc9d1e0)
    static let scoreLow = rgb(0xff8a80)
    static let progress = rgb(0x7fb2ff)
    static let danger = rgb(0xff8a80)
}
struct NightBackground: View {
    var body: some View {
        // Ровный ночной фон без фотографии: глубокий синий с лёгким переходом сверху вниз.
        LinearGradient(colors: [Night.rgb(0x0e1626), Night.rgb(0x0a101c), Night.rgb(0x070b14)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
    }
}
struct NightButtonStyle: ButtonStyle {
    var selected = false
    var wide = false
    func makeBody(configuration: Configuration) -> some View {
        let lit = selected || configuration.isPressed
        configuration.label.font(.system(size: 15, weight: .medium)).lineLimit(wide ? 2 : 1).multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, wide ? 8 : 0).frame(minHeight: wide ? 56 : 46).frame(maxWidth: wide ? .infinity : nil)
            .foregroundStyle(lit ? Night.rgb(0x111d2d) : Night.rgb(0xeeeeff))
            .background(lit ? Night.rgb(0xedf3fa) : Night.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Night.stroke, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1).animation(.easeOut(duration: 0.13), value: configuration.isPressed)
    }
}
// Постеры уменьшаются до размера карточки и держатся в памяти, чтобы каталог открывался мгновенно.
enum PosterCache { static let images: NSCache<NSString, UIImage> = { let c = NSCache<NSString, UIImage>(); c.totalCostLimit = 24 * 1024 * 1024; return c }() }
struct CachedPoster: View {
    let url: String
    var fill = false
    @State private var image: UIImage?
    init(url: String, fill: Bool = false) { self.url = url; self.fill = fill; _image = State(initialValue: PosterCache.images.object(forKey: url as NSString)) }
    var body: some View {
        Group { if let image { if fill { Color.clear.overlay(Image(uiImage: image).resizable().scaledToFill()).clipped() } else { Image(uiImage: image).resizable().scaledToFit() } } else { Color.clear } }
        .task(id: url) {
            guard image == nil, let u = URL(string: url), let (data, _) = try? await URLSession.shared.data(from: u), let full = UIImage(data: data) else { return }
            let scale = min(1, 430 / max(full.size.height, 1))
            let thumb = await full.byPreparingThumbnail(ofSize: CGSize(width: full.size.width * scale, height: full.size.height * scale)) ?? full
            PosterCache.images.setObject(thumb, forKey: url as NSString, cost: Int(thumb.size.width * thumb.size.height * thumb.scale * thumb.scale * 4))
            image = thumb
        }
    }
}

struct LoginView: View {
    @EnvironmentObject var store: AnimeStore
    @Environment(\.dismiss) var dismiss
    @State var email = ""; @State var password = ""; @State var busy = false; @State var error = ""
    func field<F: View>(_ f: F) -> some View { f.font(.system(size: 17)).foregroundStyle(.white).padding(.horizontal, 16).frame(height: 52).background(Night.panel, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Night.stroke)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(store.token.isEmpty ? "Вход в Anime 365" : "Аккаунт Anime 365").font(.system(size: 22, weight: .bold)).foregroundStyle(.white); Spacer(); Button("Закрыть") { dismiss() }.buttonStyle(NightButtonStyle()) }
            if !store.token.isEmpty {
                ScrollView { AccountPanel(); UpdatePanel().padding(.top, 12) }
                Button("Выйти") { store.logout(); dismiss() }.buttonStyle(NightButtonStyle())
            } else {
                field(TextField("", text: $email, prompt: Text("E-mail").foregroundStyle(Night.rgb(0x9c9eaf))).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled())
                field(SecureField("", text: $password, prompt: Text("Пароль").foregroundStyle(Night.rgb(0x9c9eaf))))
                Text(error.isEmpty ? "Пароль отправляется только Anime 365. Токен хранится в Связке ключей iPhone, пароль не сохраняется." : error).font(.system(size: 13)).foregroundStyle(error.isEmpty ? Night.meta : .orange)
                Button(busy ? "Вход…" : "Войти") { Task { busy = true; error = ""; do { try await store.login(email.trimmingCharacters(in: .whitespaces), password, "universal"); password = ""; dismiss() } catch { self.error = error.localizedDescription }; busy = false } }
                    .buttonStyle(NightButtonStyle(selected: true)).disabled(busy || email.isEmpty || password.isEmpty)
            }
            Spacer()
            Text("Yoru Anime \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.system(size: 12)).foregroundStyle(Night.meta).frame(maxWidth: .infinity)
        }.padding(20).background(NightBackground()).presentationDetents([.medium, .large])
    }
}
