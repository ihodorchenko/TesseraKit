// Конфигурация внешнего вида пивота.
// Проектный документ: docs/PIVOT-IOS-DESIGN.md — §3 «Архитектура»
// (PivotStyle — шрифты/цвета заголовков, вид индикатора, режим ленты),
// §4 «Математика ядра» (непрерывная окраска по расстоянию от t) и
// §8 «Accessibility и системная интеграция» (Dynamic Type, Reduce Motion, RTL).

#if canImport(UIKit)
import UIKit

/// Внешний вид пивота: шрифт и цвета ленты заголовков, вид индикатора,
/// режим ширины заголовков и крупный заголовок приложения
/// (docs/PIVOT-IOS-DESIGN.md §3).
///
/// Тип — конфиг-структура с дефолтами у всех полей: достаточно создать
/// `PivotStyle()`, чтобы получить системный вид. Стиль не хранит состояние и
/// не зависит от иерархии представлений — это чистый снимок настроек; компонент
/// читает его при применении и при смене Dynamic Type (§8).
///
/// - Note: Значения читаются на главном потоке: цвета и шрифты — UIKit-объекты.
/// - Note: Reduce Motion не входит в стиль: это системная настройка, а не
///   предпочтение оформления. Компонент запрашивает её через
///   ``TesseraAccessibility/isReduceMotionEnabled`` в момент решения (§8).
public struct PivotStyle {

    /// Вид выделения активного заголовка (docs/PIVOT-IOS-DESIGN.md §3).
    ///
    /// Выбор влияет только на визуальное выделение; синхронизация ленты и
    /// пейджера от него не зависит (§5).
    public enum IndicatorStyle {
        /// Только подчёркивание под активным заголовком.
        case underline

        /// Только акцентный цвет текста: активный заголовок окрашивается в
        /// ``PivotStyle/activeColor``, соседние — интерполируются к
        /// ``PivotStyle/inactiveColor`` по расстоянию от `t` (§4, «Окраска
        /// текста»). Отдельного подчёркивания нет.
        case accentText

        /// Подчёркивание и акцентный цвет текста одновременно.
        case underlineAndText
    }

    /// Режим ширины заголовков в ленте (docs/PIVOT-IOS-DESIGN.md §3).
    ///
    /// Отличие от Panorama: заголовки пивота имеют разную ширину, поэтому
    /// индикатор интерполируется между их центрами, а не по константному шагу
    /// (§4, «Важная тонкость»).
    public enum StripMode {
        /// Ширина заголовка — по его тексту; лента прокручивается, если
        /// заголовки не помещаются.
        case content

        /// Заголовки делят доступную ширину поровну. При очень крупном
        /// Dynamic Type компонент вправе отступить от режима (усечение или
        /// возврат к `.content`), иначе заголовки сольются (§8, «Dynamic Type»);
        /// сам стиль при этом остаётся запросом пользователя.
        case fill
    }

    /// Базовый шрифт заголовков ленты.
    ///
    /// По умолчанию — системный semibold 17 pt, то есть базовый размер
    /// `UIFont.TextStyle.headline`. Это именно базовый, немасштабированный
    /// шрифт: компонент масштабирует его под текущую категорию Dynamic Type
    /// через `UIFontMetrics(forTextStyle:)` с ``titleTextStyle`` и пересчитывает
    /// при изменении категории (docs/PIVOT-IOS-DESIGN.md §8, «Dynamic Type»).
    ///
    /// Если передать уже масштабированный шрифт, он будет масштабирован
    /// повторно; для точного контроля передавайте базовый размер.
    public var titleFont: UIFont

    /// Текстовый стиль, метрики которого используются для Dynamic Type
    /// (docs/PIVOT-IOS-DESIGN.md §8, «Dynamic Type»).
    ///
    /// Определяет, как растёт ``titleFont`` при увеличении системного размера
    /// текста. По умолчанию `.headline` — семантически корректный стиль для
    /// заголовков ленты.
    public var titleTextStyle: UIFont.TextStyle

    /// Цвет активного заголовка и индикатора.
    ///
    /// По умолчанию `.systemBlue`. При `.accentText` и `.underlineAndText`
    /// этот цвет —
    /// «полюс акцента», к которому интерполируются цвета соседних заголовков
    /// по расстоянию от `t` (§4, «Окраска текста»).
    public var activeColor: UIColor

    /// Цвет неактивного заголовка.
    ///
    /// По умолчанию `.systemGray`. Промежуточные значения получаются
    /// интерполяцией между ``activeColor`` и этим цветом (§4).
    public var inactiveColor: UIColor

    /// Вид выделения активного заголовка. По умолчанию `.underline`.
    public var indicatorStyle: IndicatorStyle

    /// Режим ширины заголовков в ленте. По умолчанию `.content`.
    public var stripMode: StripMode

    /// Крупный заголовок приложения над лентой
    /// (docs/PIVOT-IOS-DESIGN.md §1, «Крупный заголовок приложения»).
    ///
    /// `nil` — не показывать: компонент занимает экран только лентой и
    /// контентом, а крупный заголовок может интегрироваться с
    /// `navigationItem.largeTitle` снаружи (§9, «Заголовок приложения»).
    /// Строка — встроенный статичный заголовок WP-поведения (§9).
    public var appTitle: String?

    /// Создаёт стиль пивота; у всех параметров есть системные дефолты.
    ///
    /// - Parameters:
    ///   - titleFont: базовый (немасштабированный) шрифт заголовков,
    ///     по умолчанию системный semibold 17 pt.
    ///   - titleTextStyle: стиль метрик Dynamic Type, по умолчанию `.headline`.
    ///   - activeColor: цвет активного заголовка и индикатора,
    ///     по умолчанию `.systemBlue`.
    ///   - inactiveColor: цвет неактивного заголовка,
    ///     по умолчанию `.systemGray`.
    ///   - indicatorStyle: вид выделения активного заголовка,
    ///     по умолчанию `.underline`.
    ///   - stripMode: режим ширины заголовков, по умолчанию `.content`.
    ///   - appTitle: крупный заголовок приложения; `nil` (по умолчанию) —
    ///     не показывать.
    public init(
        titleFont: UIFont = .systemFont(ofSize: 17, weight: .semibold),
        titleTextStyle: UIFont.TextStyle = .headline,
        activeColor: UIColor = .systemBlue,
        inactiveColor: UIColor = .systemGray,
        indicatorStyle: IndicatorStyle = .underline,
        stripMode: StripMode = .content,
        appTitle: String? = nil
    ) {
        self.titleFont = titleFont
        self.titleTextStyle = titleTextStyle
        self.activeColor = activeColor
        self.inactiveColor = inactiveColor
        self.indicatorStyle = indicatorStyle
        self.stripMode = stripMode
        self.appTitle = appTitle
    }
}
#endif
