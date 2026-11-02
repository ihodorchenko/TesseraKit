// Хостинг контента TesseraCore: реестр переиспользования и мост состояния
// (мост `TesseraStateBridge` устарел — E9.9, удаление в мажорном релизе).
// Проектный документ: docs/Core-iOS-Design.md — §1 «Состав пакета»,
// §3 «Концептуальная поверхность API».

#if canImport(UIKit)
import UIKit
#endif

#if canImport(Combine)
import Combine

/// Мост состояния между UIKit-ядром и SwiftUI-фасадами
/// (docs/Core-iOS-Design.md, §1 — «мост состояния через `ObservableObject`»).
///
/// iOS 15 не поддерживает `@Observable`, поэтому перенос состояния выполняется
/// через `ObservableObject`: SwiftUI-фасад подписывается на мост, а ядро уведомляет
/// его методом `update(_:)`. `@Published` сам сообщает SwiftUI об изменении,
/// отдельного канала уведомлений не требуется (§3 — никаких уведомлений «в никуда»).
///
/// Мост не копирует объект и не подменяет его наблюдаемость: фасад получает
/// исходный `Object`, а мост лишь публикует факт его замены.
///
/// - Important: **Устарел (E9.9).** Ни один компонент TesseraKit мост не
///   использует: фасады Pivot, Panorama и StartScreen передают состояние
///   напрямую через `UIViewControllerRepresentable` и собственные
///   `ObservableObject`. Тип нарушает правило трёх для Core (механика в Core —
///   только если нужна минимум двум компонентам), поэтому помечен
///   `@available(*, deprecated)` и будет удалён в следующем мажорном релизе
///   (контракт 8: публичная поверхность Core меняется только через deprecation).
///   Замена — собственный `ObservableObject` на стороне приложения или
///   `@ObservedObject` непосредственно на исходном объекте.
@available(*, deprecated, message: "TesseraStateBridge не используется компонентами TesseraKit и будет удалён в следующем мажорном релизе. Наблюдайте исходный ObservableObject напрямую (@ObservedObject / @StateObject).")
public final class TesseraStateBridge<Object: ObservableObject>: ObservableObject {
    /// Текущий наблюдаемый объект. Меняется только через `init(_:)` и `update(_:)`,
    /// поэтому фасад не может незаметно подменить источник состояния.
    @Published public private(set) var object: Object

    /// Создаёт мост поверх существующего наблюдаемого объекта.
    public init(_ object: Object) {
        self.object = object
    }

    /// Публикует замену наблюдаемого объекта.
    ///
    /// SwiftUI-фасад получает уведомление через `objectWillChange` и перерисовывается.
    public func update(_ object: Object) {
        self.object = object
    }
}
#endif

#if canImport(UIKit)
/// Реестр переиспользования контроллеров контента
/// (docs/Core-iOS-Design.md, §1 и §3).
///
/// Один `id` — один контроллер: повторный запрос возвращает тот же экземпляр,
/// а не создаёт новый. Для `TesseraSwiftUIContentProvider` при повторном запросе
/// обновляется `rootView` существующего `UIHostingController` — хостинг
/// переиспользуется между перестройками иерархии, контроллер не пересоздаётся.
///
/// Реестр — часть UIKit-ядра: SwiftUI-фасады передают сюда провайдеры
/// и получают обычные `UIViewController` (§1).
///
/// - Important:
///   - Работает только на главном потоке: UI-состояние не размазывается по модулям (§3).
///   - Держит сильные ссылки на контроллеры: освобождайте их через
///     `removeContent(for:)` или `removeAll()`, когда контент больше не нужен.
public final class TesseraContentHosting {
    /// Контроллеры по идентификаторам: словарь и есть контракт «один id — один контроллер».
    private var controllers: [AnyHashable: UIViewController] = [:]

    /// Создаёт пустой реестр.
    public init() {}

    /// Возвращает контроллер для `id`, создавая его при первом запросе.
    ///
    /// Повторный запрос с тем же `id` не создаёт новый контроллер:
    /// для SwiftUI-провайдера обновляется `rootView`, остальные провайдеры
    /// возвращают уже созданный экземпляр без изменений.
    ///
    /// - Parameters:
    ///   - id: идентификатор контента (например, идентификатор страницы пейджера).
    ///   - provider: фабрика контента; вызывается только при первом запросе.
    /// - Returns: тот же экземпляр контроллера для одного и того же `id`.
    ///
    /// - Note: Смена поставщика или типа контента для занятого `id` не поддерживается
    ///   (реестр сохраняет первый контроллер): удалите запись через `removeContent(for:)`
    ///   и запросите контент заново.
    public func viewController(
        for id: AnyHashable,
        provider: TesseraContentProviding
    ) -> UIViewController {
        if let existing = controllers[id] {
            // Повторный запрос: SwiftUI-провайдер обновляет rootView на месте.
            // Остальные провайдеры не умеют обновлять произвольный контроллер —
            // возвращаем сохранённый экземпляр, сохраняя инвариант «один id — один контроллер».
            _ = (provider as? TesseraContentUpdating)?.updateContent(of: existing)
            return existing
        }

        let controller = provider.makeContentViewController()
        controllers[id] = controller
        return controller
    }

    /// Удаляет контроллер для `id` из реестра.
    ///
    /// Сам контроллер не уничтожается принудительно — реестр лишь перестаёт
    /// держать на него сильную ссылку; следующий запрос создаст новый экземпляр.
    public func removeContent(for id: AnyHashable) {
        controllers.removeValue(forKey: id)
    }

    /// Очищает реестр: все контроллеры перестают переиспользоваться.
    public func removeAll() {
        controllers.removeAll()
    }
}
#endif
