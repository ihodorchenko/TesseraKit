//
//  TesseraPivotView.swift
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
//  `TesseraPivotViewController`. Вся синхронизация ленты и пейджера, арбитраж жестов и
//  accessibility живут в UIKit-ядре (§2, §5).
//

#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit

/// SwiftUI-представление пивота (docs/PIVOT-IOS-DESIGN.md §2, §3).
///
/// Обёртка над ``TesseraPivotViewController``: SwiftUI описывает состояние
/// декларативно, а непрерывную синхронизацию ленты с `contentOffset` выполняет
/// UIKit-ядро — на iOS 15 чистый SwiftUI не отдаёт прогресс перетаскивания
/// страницы, поэтому индикатор не мог бы ехать за пальцем (§2).
///
/// ```swift
/// TesseraPivotView(
///     sections: [
///         TesseraPivotSection(id: "home", title: "Главная") { HomeViewController() },
///         TesseraPivotSection(id: "news", title: "Новости") { NewsViewController() },
///     ],
///     style: TesseraPivotStyle(appTitle: "Приложение")
/// )
/// ```
///
/// ## Обновление
///
/// - ``TesseraPivotStyle`` применяется на каждом обновлении; сеттеры ленты в ядре
///   сравнивают значения с прежними, поэтому лишней перезагрузки ячеек нет;
/// - при изменении набора `id` или заголовков секции пересобираются сразу
///   (`reload(sections:)`);
/// - при тех же `id` и заголовках новый контент всё равно доносится до
///   страниц (E10.12а): сравнить поставщиков контента
///   (`TesseraContentProviding`) нельзя, поэтому секции передаются ядру на
///   каждом обновлении. Пейджер переиспользует контроллеры с сохранившимся
///   `id` и обновляет `rootView` SwiftUI-страниц на месте — текущая страница,
///   скролл и `@State` контента сохраняются. Во время жеста, инерции или
///   анимированного перехода обновление откладывается до его завершения,
///   чтобы не оборвать движение;
/// - колбэк прогресса не вызывается синхронно внутри
///   `updateUIViewController`: прогресс, изменившийся при перестройке,
///   приходит следующим проходом главной очереди.
///
/// ## Делегат
///
/// `TesseraPivotDelegate` — протокол с классовой связностью, а SwiftUI-структура не
/// может хранить `weak`-ссылку. Поэтому фасад передаёт делегата координатору,
/// который удерживает последнее значение `TesseraPivotView` и пробрасывает все три
/// колбэка (§3). Делегат удерживается сильной ссылкой, пока представление
/// установлено: если он сам держит SwiftUI-состояние, используйте промежуточный
/// объект во избежание цикла.
public struct TesseraPivotView: UIViewControllerRepresentable {

    /// Секции в порядке чтения (docs/PIVOT-IOS-DESIGN.md §3).
    private let sections: [TesseraPivotSection]

    /// Внешний вид: шрифты и цвета ленты, вид индикатора, режим ширины,
    /// крупный заголовок приложения.
    private let style: TesseraPivotStyle

    /// Наблюдатель выбора, прогресса и показа секции.
    private let delegate: TesseraPivotDelegate?

    /// Создаёт фасад пивота.
    ///
    /// - Parameters:
    ///   - sections: Секции в порядке чтения; первый элемент — первая страница
    ///     для пользователя (в RTL порядок зеркалит ядро, §8).
    ///   - style: Внешний вид; по умолчанию системный.
    ///   - delegate: Наблюдатель состояния; необязателен.
    public init(
        sections: [TesseraPivotSection],
        style: TesseraPivotStyle = TesseraPivotStyle(),
        delegate: TesseraPivotDelegate? = nil
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
    /// - Returns: Настроенный ``TesseraPivotViewController``.
    public func makeUIViewController(context: Context) -> TesseraPivotViewController {
        let pivot = TesseraPivotViewController(sections: sections, style: style)
        pivot.delegate = context.coordinator
        context.coordinator.pivotViewController = pivot
        return pivot
    }

    /// Обновляет секции и стиль существующего контроллера.
    ///
    /// Структурное изменение (`id` или заголовки) — немедленный `reload`; тот
    /// же набор — обновление контента через
    /// ``TesseraPivotViewController/refreshSectionContent(_:)`` (E10.12а, отложенное
    /// на время движения страниц). Стиль применяется всегда — его сеттеры в
    /// ядре идемпотентны.
    ///
    /// - Parameters:
    ///   - uiViewController: Живой ``TesseraPivotViewController``.
    ///   - context: Контекст SwiftUI с координатором.
    public func updateUIViewController(
        _ uiViewController: TesseraPivotViewController,
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
        } else {
            uiViewController.refreshSectionContent(sections)
        }
    }

    /// Сравнивает структуру наборов секций.
    ///
    /// `TesseraPivotSection` не `Equatable`: поставщик контента — протокол с фабрикой,
    /// у которой нет семантики равенства. Поэтому структура определяется парой
    /// `id` + `title`; при совпадении контент обновляется отдельным путём
    /// (см. документацию ``TesseraPivotView``).
    ///
    /// - Parameters:
    ///   - lhs: Текущие секции контроллера.
    ///   - rhs: Новые секции из SwiftUI.
    /// - Returns: `true`, если требуется `reload`.
    private static func sectionsDiffer(
        _ lhs: [TesseraPivotSection],
        _ rhs: [TesseraPivotSection]
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

    /// Делегат UIKit-ядра, пробрасывающий события в `TesseraPivotDelegate` (§3).
    ///
    /// Живёт столько же, сколько представление: его удерживает SwiftUI, поэтому
    /// слабая ссылка `TesseraPivotViewController.delegate` не теряет наблюдателя между
    /// перерисовками.
    public final class Coordinator: NSObject, TesseraPivotDelegate {

        /// Последняя версия описания из SwiftUI: источник делегата и состояния.
        fileprivate var parent: TesseraPivotView

        /// Ядро, к которому привязан координатор. Слабо: контроллер уже
        /// удерживается иерархией SwiftUI.
        fileprivate weak var pivotViewController: TesseraPivotViewController?

        /// Создаёт координатор поверх описания пивота.
        ///
        /// - Parameter parent: Описание из `makeCoordinator()`.
        fileprivate init(parent: TesseraPivotView) {
            self.parent = parent
            super.init()
        }

        /// Пробрасывает выбор секции во внешний делегат.
        ///
        /// - Parameters:
        ///   - pivot: Пивот-источник события.
        ///   - index: Индекс выбранной секции в порядке чтения.
        public func pivot(_ pivot: TesseraPivotViewController, didSelectSectionAt index: Int) {
            parent.delegate?.pivot(pivot, didSelectSectionAt: index)
        }

        /// Пробрасывает непрерывный прогресс во внешний делегат.
        ///
        /// - Parameters:
        ///   - pivot: Пивот-источник события.
        ///   - t: Нормализованный прогресс в порядке чтения.
        public func pivot(_ pivot: TesseraPivotViewController, didChangeProgress t: CGFloat) {
            parent.delegate?.pivot(pivot, didChangeProgress: t)
        }

        /// Пробрасывает завершение перехода во внешний делегат.
        ///
        /// - Parameters:
        ///   - pivot: Пивот-источник события.
        ///   - index: Индекс показанной секции в порядке чтения.
        public func pivot(_ pivot: TesseraPivotViewController, didShowSectionAt index: Int) {
            parent.delegate?.pivot(pivot, didShowSectionAt: index)
        }
    }
}
#endif
