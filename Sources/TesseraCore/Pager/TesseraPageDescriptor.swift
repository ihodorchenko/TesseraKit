// Описание страницы пейджера TesseraCore.
// Проектный документ: docs/Core-iOS-Design.md — §2 «Ключевые контракты»
// (инвариант прогресса, один писатель contentOffset) и §3 «Концептуальная
// поверхность API» (TesseraPageDescriptor — id, заголовок, makeContent()).

#if canImport(UIKit)
import UIKit

/// Описание одной страницы `TesseraPagerViewController`.
///
/// Страницы передаются в порядке чтения: первый элемент массива — первая
/// страница для пользователя. В RTL пейджер зеркалит физическую раскладку, а
/// индекс и прогресс нормализует через `TesseraRTL`
/// (docs/Core-iOS-Design.md §2, «Инвариант прогресса»).
///
/// - Important: `id` должен быть уникален в пределах одного пейджера: по нему
///   `TesseraContentHosting` переиспользует контроллер контента. Поведение при
///   повторяющихся идентификаторах не определено.
/// - Note: Все методы и свойства рассчитаны на главный поток: UI-состояние
///   Core не размазывается по модулям (docs/Core-iOS-Design.md §3).
public struct TesseraPageDescriptor {
    /// Стабильный идентификатор страницы.
    ///
    /// Используется для переиспользования контроллера через
    /// `TesseraContentHosting`: пока идентификатор встречается в пейджере,
    /// хостинг может вернуть тот же экземпляр контроллера.
    public let id: AnyHashable

    /// Заголовок страницы.
    ///
    /// Пейджер хранит заголовок как часть описания страницы; текст для
    /// accessibility и подписей компоненты строят из него самостоятельно.
    public let title: String

    /// Поставщик контроллера контента страницы.
    public let content: TesseraContentProviding

    /// Создаёт описание страницы с готовым поставщиком контента.
    ///
    /// - Parameters:
    ///   - id: Уникальный в пределах пейджера идентификатор страницы.
    ///   - title: Заголовок страницы.
    ///   - content: Поставщик `UIViewController` (UIKit или SwiftUI-фасад).
    public init(id: AnyHashable, title: String, content: TesseraContentProviding) {
        self.id = id
        self.title = title
        self.content = content
    }

    /// Создаёт описание страницы поверх фабрики UIKit-контроллера.
    ///
    /// Аналог convenience-инициализатора: структура не поддерживает
    /// `convenience init`, поэтому это обычный дополнительный инициализатор.
    /// Замыкание оборачивается в ``TesseraViewControllerProvider`` и вызывается
    /// лениво, при первом запросе страницы у пейджера.
    ///
    /// - Parameters:
    ///   - id: Уникальный в пределах пейджера идентификатор страницы.
    ///   - title: Заголовок страницы.
    ///   - makeContent: Фабрика контроллера контента; вызывается на главном потоке.
    public init(
        id: AnyHashable,
        title: String,
        makeContent: @escaping () -> UIViewController
    ) {
        self.init(
            id: id,
            title: title,
            content: TesseraViewControllerProvider(makeContent)
        )
    }
}
#endif
