//
//  PanoramaView.swift
//  TesseraPanorama
//
//  SwiftUI-фасад панорамы.
//  Проектный документ: docs/PANORAMA-IOS-DESIGN.md — §2 «Выбор фундамента»
//  (UIKit-ядро + SwiftUI-фасад через `UIViewControllerRepresentable`), §3
//  «Концептуальная архитектура» (декларативный API: секции, стиль, делегат),
//  §7 «Accessibility» (мост состояния — только `ObservableObject`: iOS 15 не
//  поддерживает макрос Observable; анимации и VoiceOver остаются в UIKit-ядре).
//
//  Фасад не дублирует механику: он создаёт и обновляет
//  `PanoramaViewController`. Снап, параллакс, заголовки, арбитраж жестов и
//  accessibility живут в UIKit-ядре (§2, §3).
//

#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import TesseraCore
import UIKit

/// SwiftUI-представление панорамы (docs/PANORAMA-IOS-DESIGN.md §2, §3).
///
/// Обёртка над ``PanoramaViewController``. На iOS 15 чистый SwiftUI не отдаёт
/// прогресс перетаскивания страницы, поэтому снап, параллакс фона и
/// интерполяция заголовков по `t` выполняются в UIKit-ядре, а SwiftUI только
/// описывает состояние (§2).
///
/// ```swift
/// PanoramaView(
///     sections: [
///         PanoramaSection(id: "start", title: "Начало") { StartViewController() },
///         PanoramaSection(id: "news", title: "Новости") { NewsViewController() },
///     ],
///     style: PanoramaStyle(
///         peek: 48,
///         backgroundBehavior: .image(UIImage(named: "panorama-bg"))
///     )
/// )
/// ```
///
/// ## Обновление
///
/// - ``PanoramaStyle`` применяется на каждом обновлении: сеттеры ядра
///   идемпотентны, повторная установка того же стиля не перезагружает секции;
/// - секции пересобираются только при изменении набора `id` или заголовков:
///   сравнить поставщиков контента (`TesseraContentProviding`) нельзя, поэтому
///   смена контента при том же `id` не подхватывается — меняйте `id` секции либо
///   вызывайте `reload(sections:)` у контроллера напрямую (§3).
///
/// ## Делегат
///
/// ``PanoramaDelegate`` — протокол с классовой связностью, а SwiftUI-структура не
/// может хранить `weak`-ссылку. Поэтому фасад передаёт делегата координатору,
/// который удерживает последнее значение ``PanoramaView`` и пробрасывает оба
/// колбэка (§3). Делегат удерживается сильной ссылкой, пока представление
/// установлено: если он сам держит SwiftUI-состояние, используйте промежуточный
/// объект во избежание цикла.
public struct PanoramaView: UIViewControllerRepresentable {

    /// Секции в порядке чтения (§3).
    private let sections: [PanoramaSection]

    /// Внешний вид: peek, множитель параллакса, шрифт и цвета заголовков, фон.
    private let style: PanoramaStyle

    /// Политика снапа (§4, «Снап»).
    ///
    /// В ``PanoramaStyle`` поля снапа нет (волна 1), поэтому порог скорости
    /// передаётся отдельно и уходит в ядро как есть.
    private let snapPolicy: TesseraSnapPolicy

    /// Наблюдатель прогресса и показа секции.
    private let delegate: PanoramaDelegate?

    /// Создаёт фасад панорамы.
    ///
    /// - Parameters:
    ///   - sections: Секции в порядке чтения; первый элемент — первая секция для
    ///     пользователя (в RTL физический порядок зеркалит ядро, §7).
    ///   - style: Внешний вид; по умолчанию системный.
    ///   - snapPolicy: Политика снапа; по умолчанию — параметры Core.
    ///   - delegate: Наблюдатель состояния; необязателен.
    public init(
        sections: [PanoramaSection],
        style: PanoramaStyle = PanoramaStyle(),
        snapPolicy: TesseraSnapPolicy = TesseraSnapPolicy(),
        delegate: PanoramaDelegate? = nil
    ) {
        self.sections = sections
        self.style = style
        self.snapPolicy = snapPolicy
        self.delegate = delegate
    }

    // MARK: - UIViewControllerRepresentable

    /// Создаёт координатор-делегат (§3: мост колбэков UIKit в SwiftUI).
    ///
    /// - Returns: Координатор, удерживаемый SwiftUI.
    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Создаёт UIKit-ядро панорамы.
    ///
    /// - Parameter context: Контекст SwiftUI.
    /// - Returns: Настроенный ``PanoramaViewController``.
    public func makeUIViewController(context: Context) -> PanoramaViewController {
        let panorama = PanoramaViewController(sections: sections, style: style)
        panorama.snapPolicy = snapPolicy
        panorama.delegate = context.coordinator
        context.coordinator.panoramaViewController = panorama
        return panorama
    }

    /// Обновляет секции, стиль и политику снапа существующего контроллера.
    ///
    /// Полная пересборка (`reload`) выполняется только при изменении `id` или
    /// заголовков; стиль и снап применяются всегда — их сеттеры в ядре
    /// идемпотентны.
    ///
    /// - Parameters:
    ///   - uiViewController: Живой ``PanoramaViewController``.
    ///   - context: Контекст SwiftUI с координатором.
    public func updateUIViewController(
        _ uiViewController: PanoramaViewController,
        context: Context
    ) {
        // Координатор хранит последнюю версию описания: иначе делегат видел бы
        // устаревшее состояние после перерисовки SwiftUI.
        context.coordinator.parent = self
        context.coordinator.panoramaViewController = uiViewController

        uiViewController.delegate = context.coordinator
        uiViewController.style = style
        uiViewController.snapPolicy = snapPolicy

        if Self.sectionsDiffer(uiViewController.sections, sections) {
            uiViewController.reload(sections: sections)
        }
    }

    /// Сравнивает наборы секций по тому, что можно сравнить.
    ///
    /// ``PanoramaSection`` не `Equatable`: поставщик контента — протокол с
    /// фабрикой, у которой нет семантики равенства. Поэтому «то же самое»
    /// определяется парой `id` + `title`; при одинаковых `id` и заголовках
    /// пересборка не нужна (см. документацию ``PanoramaView``).
    ///
    /// - Parameters:
    ///   - lhs: Текущие секции контроллера.
    ///   - rhs: Новые секции из SwiftUI.
    /// - Returns: `true`, если требуется `reload`.
    private static func sectionsDiffer(
        _ lhs: [PanoramaSection],
        _ rhs: [PanoramaSection]
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

    /// Делегат UIKit-ядра, пробрасывающий события в ``PanoramaDelegate`` (§3).
    ///
    /// Живёт столько же, сколько представление: его удерживает SwiftUI, поэтому
    /// слабая ссылка `PanoramaViewController.delegate` не теряет наблюдателя
    /// между перерисовками.
    public final class Coordinator: NSObject, PanoramaDelegate {

        /// Последняя версия описания из SwiftUI: источник делегата и состояния.
        fileprivate var parent: PanoramaView

        /// Ядро, к которому привязан координатор. Слабо: контроллер уже
        /// удерживается иерархией SwiftUI.
        fileprivate weak var panoramaViewController: PanoramaViewController?

        /// Создаёт координатор поверх описания панорамы.
        ///
        /// - Parameter parent: Описание из `makeCoordinator()`.
        fileprivate init(parent: PanoramaView) {
            self.parent = parent
            super.init()
        }

        /// Пробрасывает показ секции во внешний делегат.
        ///
        /// - Parameters:
        ///   - panorama: Панорама-источник события.
        ///   - index: Индекс показанной секции в порядке чтения.
        public func panorama(_ panorama: PanoramaViewController, didShowSectionAt index: Int) {
            parent.delegate?.panorama(panorama, didShowSectionAt: index)
        }

        /// Пробрасывает непрерывный прогресс во внешний делегат.
        ///
        /// - Parameters:
        ///   - panorama: Панорама-источник события.
        ///   - t: Нормализованный прогресс в порядке чтения.
        public func panorama(_ panorama: PanoramaViewController, didChangeProgress t: CGFloat) {
            parent.delegate?.panorama(panorama, didChangeProgress: t)
        }
    }
}
#endif
