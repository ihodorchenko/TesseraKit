//
//  PivotView.swift
//  TesseraPivot
//
//  SwiftUI-фасад пивота.
//  Контракт: docs/PIVOT-IOS-DESIGN.md §2 «Выбор фундамента» (UIKit-ядро +
//  SwiftUI-фасад через `UIViewControllerRepresentable`), §3 «Архитектура»
//  (декларативный API: секции, стиль, делегат), §8 «Accessibility» (мост
//  состояния — только `ObservableObject`: iOS 15 не поддерживает макрос
//  Observable).
//  Задача плана: E2.5.
//
//  Фасад не дублирует механику: он только создаёт и обновляет
//  `PivotViewController`. Вся синхронизация ленты и пейджера, арбитраж жестов и
//  accessibility живут в UIKit-ядре (§2, §5).
//

#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit

/// SwiftUI-представление пивота (docs/PIVOT-IOS-DESIGN.md §2, §3).
///
/// Обёртка над ``PivotViewController``: SwiftUI описывает состояние
/// декларативно, а непрерывную синхронизацию ленты с `contentOffset` выполняет
/// UIKit-ядро — на iOS 15 чистый SwiftUI не отдаёт прогресс перетаскивания
/// страницы, поэтому индикатор не мог бы ехать за пальцем (§2).
///
/// ```swift
/// PivotView(
///     sections: [
///         PivotSection(id: "home", title: "Главная") { HomeViewController() },
///         PivotSection(id: "news", title: "Новости") { NewsViewController() },
///     ],
///     style: PivotStyle(appTitle: "Приложение")
/// )
/// ```
///
/// ## Обновление
///
/// - ``PivotStyle`` применяется на каждом обновлении; сеттеры ленты в ядре
///   сравнивают значения с прежними, поэтому лишней перезагрузки ячеек нет;
/// - секции пересобираются только при изменении набора `id` или заголовков:
///   сравнить поставщиков контента (`TesseraContentProviding`) нельзя, поэтому
///   смена контента при том же `id` не подхватывается — меняйте `id` секции
///   либо вызывайте `reload(sections:)` у контроллера напрямую (§3).
///
/// ## Делегат
///
/// `PivotDelegate` — протокол с классовой связностью, а SwiftUI-структура не
/// может хранить `weak`-ссылку. Поэтому фасад передаёт делегата координатору,
/// который удерживает последнее значение `PivotView` и пробрасывает все три
/// колбэка (§3). Делегат удерживается сильной ссылкой, пока представление
/// установлено: если он сам держит SwiftUI-состояние, используйте промежуточный
/// объект во избежание цикла.
public struct PivotView: UIViewControllerRepresentable {

    /// Секции в порядке чтения (docs/PIVOT-IOS-DESIGN.md §3).
    private let sections: [PivotSection]

    /// Внешний вид: шрифты и цвета ленты, вид индикатора, режим ширины,
    /// крупный заголовок приложения.
    private let style: PivotStyle

    /// Наблюдатель выбора, прогресса и показа секции.
    private let delegate: PivotDelegate?

    /// Создаёт фасад пивота.
    ///
    /// - Parameters:
    ///   - sections: Секции в порядке чтения; первый элемент — первая страница
    ///     для пользователя (в RTL порядок зеркалит ядро, §8).
    ///   - style: Внешний вид; по умолчанию системный.
    ///   - delegate: Наблюдатель состояния; необязателен.
    public init(
        sections: [PivotSection],
        style: PivotStyle = PivotStyle(),
        delegate: PivotDelegate? = nil
    ) {
        self.sections = sections
        self.style = style
        self.delegate = delegate
    }

    // MARK: - UIViewControllerRepresentable

    /// Создаёт координатор-делегат (§3: мост колбэков UIKit в SwiftUI).
    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Создаёт UIKit-ядро пивота.
    ///
    /// - Parameter context: Контекст SwiftUI.
    /// - Returns: Настроенный ``PivotViewController``.
    public func makeUIViewController(context: Context) -> PivotViewController {
        let pivot = PivotViewController(sections: sections, style: style)
        pivot.delegate = context.coordinator
        context.coordinator.pivotViewController = pivot
        return pivot
    }

    /// Обновляет секции и стиль существующего контроллера.
    ///
    /// Полная пересборка (`reload`) выполняется только при изменении `id` или
    /// заголовков; стиль применяется всегда — его сеттеры в ядре идемпотентны.
    ///
    /// - Parameters:
    ///   - uiViewController: Живой ``PivotViewController``.
    ///   - context: Контекст SwiftUI с координатором.
    public func updateUIViewController(
        _ uiViewController: PivotViewController,
        context: Context
    ) {
        // Координатор хранит последнюю версию описания: иначе делегат видел бы
        // устаревшее состояние после перерисовки SwiftUI.
        context.coordinator.parent = self
        context.coordinator.pivotViewController = uiViewController

        uiViewController.delegate = context.coordinator
        uiViewController.style = style

        if Self.sectionsDiffer(uiViewController.sections, sections) {
            uiViewController.reload(sections: sections)
        }
    }

    /// Сравнивает наборы секций по тому, что можно сравнить.
    ///
    /// `PivotSection` не `Equatable`: поставщик контента — протокол с фабрикой,
    /// у которой нет семантики равенства. Поэтому «то же самое» определяется
    /// парой `id` + `title`; при одинаковых `id` и заголовках пересборка не
    /// нужна (см. документацию ``PivotView``).
    ///
    /// - Parameters:
    ///   - lhs: Текущие секции контроллера.
    ///   - rhs: Новые секции из SwiftUI.
    /// - Returns: `true`, если требуется `reload`.
    private static func sectionsDiffer(
        _ lhs: [PivotSection],
        _ rhs: [PivotSection]
    ) -> Bool {
        guard lhs.count == rhs.count else { return true }

        for (current, updated) in zip(lhs, rhs) {
            if current.id != updated.id || current.title != updated.title {
                return true
            }
        }
        return false
    }

    // MARK: - Координатор

    /// Делегат UIKit-ядра, пробрасывающий события в `PivotDelegate` (§3).
    ///
    /// Живёт столько же, сколько представление: его удерживает SwiftUI, поэтому
    /// слабая ссылка `PivotViewController.delegate` не теряет наблюдателя между
    /// перерисовками.
    public final class Coordinator: NSObject, PivotDelegate {

        /// Последняя версия описания из SwiftUI: источник делегата и состояния.
        fileprivate var parent: PivotView

        /// Ядро, к которому привязан координатор. Слабо: контроллер уже
        /// удерживается иерархией SwiftUI.
        fileprivate weak var pivotViewController: PivotViewController?

        /// Создаёт координатор поверх описания пивота.
        ///
        /// - Parameter parent: Описание из `makeCoordinator()`.
        fileprivate init(parent: PivotView) {
            self.parent = parent
            super.init()
        }

        /// Пробрасывает выбор секции во внешний делегат.
        ///
        /// - Parameters:
        ///   - pivot: Пивот-источник события.
        ///   - index: Индекс выбранной секции в порядке чтения.
        public func pivot(_ pivot: PivotViewController, didSelectSectionAt index: Int) {
            parent.delegate?.pivot(pivot, didSelectSectionAt: index)
        }

        /// Пробрасывает непрерывный прогресс во внешний делегат.
        ///
        /// - Parameters:
        ///   - pivot: Пивот-источник события.
        ///   - t: Нормализованный прогресс в порядке чтения.
        public func pivot(_ pivot: PivotViewController, didChangeProgress t: CGFloat) {
            parent.delegate?.pivot(pivot, didChangeProgress: t)
        }

        /// Пробрасывает завершение перехода во внешний делегат.
        ///
        /// - Parameters:
        ///   - pivot: Пивот-источник события.
        ///   - index: Индекс показанной секции в порядке чтения.
        public func pivot(_ pivot: PivotViewController, didShowSectionAt index: Int) {
            parent.delegate?.pivot(pivot, didShowSectionAt: index)
        }
    }
}
#endif
