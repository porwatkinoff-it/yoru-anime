import ActivityKit
import Foundation

// Live Activity загрузок: общий тип для приложения и расширения YoruWidget (Dynamic Island и экран блокировки).
// В фоне приложение спит и не может двигать полосу каждую секунду, поэтому полоса идёт по времени:
// start…end рассчитаны так, что сейчас она стоит на текущем проценте и доходит до конца к ожидаемому окончанию.
struct DownloadAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String           // что качается сейчас: «Аниме · 5 серия»
        var left: Int               // сколько серий ещё качается (с текущей)
        var done: Int               // сколько уже скачано в этой пачке
        var failed: Int = 0
        var fraction: Double        // общий прогресс на момент обновления
        var start: Date?            // полоса по времени, если скорость известна
        var end: Date?
        var finished = false
    }
}
