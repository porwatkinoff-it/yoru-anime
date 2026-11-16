import ActivityKit
import SwiftUI
import WidgetKit

// Расширение Yoru: Live Activity загрузок в Dynamic Island и на экране блокировки.
@main struct YoruWidgets: WidgetBundle {
    var body: some Widget { DownloadActivityWidget() }
}

private let accent = Color(red: 0.5, green: 0.7, blue: 1)       // Night.progress
private let muted = Color(red: 0.66, green: 0.66, blue: 0.74)
private let background = Color(red: 0.04, green: 0.06, blue: 0.11)

struct DownloadActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadAttributes.self) { context in
            LockScreenDownload(state: context.state)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .activityBackgroundTint(background.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: s.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill").font(.system(size: 30)).foregroundStyle(accent).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Remaining(state: s).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.finished ? "Загрузки готовы" : s.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        DownloadBar(state: s)
                        Text(subtitle(s)).font(.system(size: 13)).foregroundStyle(muted).lineLimit(1)
                    }.padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(accent)
            } compactTrailing: {
                DownloadRing(state: s).frame(width: 18, height: 18)
            } minimal: {
                DownloadRing(state: s).frame(width: 18, height: 18)
            }
            .keylineTint(accent)
        }
    }
}

struct LockScreenDownload: View {
    let state: DownloadAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill").foregroundStyle(accent)
                Text(state.finished ? "Загрузки готовы" : state.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 8)
                Remaining(state: state).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            }
            DownloadBar(state: state)
            Text(subtitle(state)).font(.system(size: 13)).foregroundStyle(muted).lineLimit(1)
        }
    }
}

// Полоса: точный процент, а если известна скорость — плавно по времени до ожидаемого окончания.
struct DownloadBar: View {
    let state: DownloadAttributes.ContentState
    var body: some View {
        Group {
            if !state.finished, let a = state.start, let b = state.end, b > a {
                ProgressView(timerInterval: a...b, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
            } else {
                ProgressView(value: state.finished ? 1 : min(max(state.fraction, 0), 1))
            }
        }.progressViewStyle(.linear).tint(accent)
    }
}

struct DownloadRing: View {
    let state: DownloadAttributes.ContentState
    var body: some View {
        Group {
            if !state.finished, let a = state.start, let b = state.end, b > a {
                ProgressView(timerInterval: a...b, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
            } else {
                ProgressView(value: state.finished ? 1 : min(max(state.fraction, 0), 1))
            }
        }.progressViewStyle(.circular).tint(accent)
    }
}

// Справа: сколько осталось по времени, иначе процент.
struct Remaining: View {
    let state: DownloadAttributes.ContentState
    var body: some View {
        if state.finished { Text("\(state.done)").monospacedDigit() }
        else if let b = state.end, b > Date() { Text(timerInterval: Date()...b, countsDown: true).monospacedDigit().multilineTextAlignment(.trailing).frame(maxWidth: 64, alignment: .trailing) }
        else { Text("\(Int((state.fraction * 100).rounded()))%").monospacedDigit() }
    }
}

func subtitle(_ s: DownloadAttributes.ContentState) -> String {
    if s.finished { return s.failed > 0 ? "Скачано: \(s.done) · с ошибкой: \(s.failed)" : "Скачано серий: \(s.done)" }
    var parts = [s.left == 1 ? "Осталась 1 серия" : "Осталось серий: \(s.left)"]
    if s.done > 0 { parts.append("готово: \(s.done)") }
    if s.failed > 0 { parts.append("ошибок: \(s.failed)") }
    return parts.joined(separator: " · ")
}
