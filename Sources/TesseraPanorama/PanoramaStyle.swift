// Конфигурация внешнего вида панорамы.
// Проектный документ: docs/PANORAMA-IOS-DESIGN.md — §3 «Концептуальная архитектура»
// (PanoramaStyle: ширина секции (peek), множитель параллакса, шрифты/цвета
// заголовков, поведение фона), §4 «Геометрия и математика ядра»
// (itemWidth = screenWidth − peek, peek 16–64 pt; backgroundOffset =
// offset.x × parallaxFactor, типично 0.4–0.6), §7 «Accessibility» (Dynamic Type,
// Reduce Motion) и §9 «Объём MVP» (в v1 — одна картинка на весь фон).

#if canImport(UIKit)
import UIKit

/// Внешний вид панорамы: ширина «холста» с peek, множитель параллакса,
/// оформление заголовков и поведение фона (docs/PANORAMA-IOS-DESIGN.md §3).
///
/// Тип — конфиг-структура с дефолтами у всех полей: достаточно создать
/// `PanoramaStyle()`, чтобы получить системный вид. Стиль не хранит состояние и
/// не зависит от иерархии представлений — это снимок настроек, который компонент
/// читает при применении.
///
/// - Note: Значения читаются на главном потоке: цвета и шрифты — UIKit-объекты.
/// - Note: Reduce Motion не входит в стиль: это системная настройка, а не
///   предпочтение оформления. При `isReduceMotionEnabled` компонент отключает
///   параллакс и анимации заголовков, оставляя простой снап
///   (docs/PANORAMA-IOS-DESIGN.md §7).
public struct PanoramaStyle {

    /// Поведение фона панорамы (docs/PANORAMA-IOS-DESIGN.md §3, §9).
    ///
    /// В v1 фон один на всю панораму: произвольный фон для каждой секции
    /// сознательно отрезан (§9, «Отрезано в v1»). Перечисление намеренно не
    /// содержит случая «свой фон у секции».
    public enum BackgroundBehavior {
        /// Фон не рисуется: за секциями виден системный/прозрачный фон.
        case none

        /// Одна картинка на весь фон панорамы.
        ///
        /// `nil` допустим, пока изображение не подготовлено: слой фона остаётся
        /// пустым (прозрачным), и визуально панорама выглядит как при `.none`.
        /// Параллакс при этом не рисует ничего, пока картинка не задана.
        case image(UIImage?)

        /// Совпадает ли поведение с другим; картинки — по идентичности.
        func isIdentical(to other: BackgroundBehavior) -> Bool {
            switch (self, other) {
            case (.none, .none):
                return true
            case let (.image(lhs), .image(rhs)):
                return lhs === rhs
            default:
                return false
            }
        }
    }

    /// Ширина зоны «подсматривания» следующей секции со стороны направления
    /// чтения (в LTR — справа), в точках.
    ///
    /// Ширина секции считается как `itemWidth = screenWidth − peek`
    /// (документ §4, «Ширина секции»), поэтому значение всегда удерживается в
    /// диапазоне `16...64`: кламп применяется в ``init(peek:parallaxFactor:headerFont:headerColor:headerActiveColor:backgroundBehavior:)``
    /// и при каждой последующей записи. Нечисловые значения (`NaN`, `±∞`)
    /// трактуются как дефолт `48`.
    public var peek: CGFloat {
        didSet { peek = Self.clampedPeek(peek) }
    }

    /// Множитель скорости фона относительно контента.
    ///
    /// Смещение фона — `backgroundOffset = contentOffset.x × parallaxFactor`
    /// (документ §4, «Параллакс фона»: `0 < parallaxFactor < 1`, типично
    /// `0.4–0.6`). Значение всегда удерживается в открытом интервале `(0, 1)` —
    /// практически в `0.01...0.99`: кламп применяется в инициализаторе и при
    /// каждой последующей записи. Нечисловые значения (`NaN`, `±∞`) трактуются
    /// как дефолт `0.5`.
    ///
    /// - Note: `0` (фон стоит) и `1` (фон едет вместе с контентом) недостижимы:
    ///   это уже не параллакс. Отключение параллакса — прерогатива
    ///   Reduce Motion, а не стиля (§7).
    public var parallaxFactor: CGFloat {
        didSet { parallaxFactor = Self.clampedParallaxFactor(parallaxFactor) }
    }

    /// Базовый шрифт заголовков секций.
    ///
    /// По умолчанию — системный bold 34 pt (базовый размер `.largeTitle`).
    /// Это именно немасштабированный шрифт: компонент масштабирует его под
    /// текущую категорию Dynamic Type через `UIFontMetrics` и пересчитывает при
    /// изменении категории (документ §7, «Dynamic Type»).
    ///
    /// Если передать уже масштабированный шрифт, он будет масштабирован
    /// повторно; для точного контроля передавайте базовый размер.
    public var headerFont: UIFont

    /// Цвет заголовка секции в неактивном состоянии.
    ///
    /// По умолчанию — `.label`: цвет адаптируется к светлой и тёмной теме.
    /// На фоновой картинке контраст заголовка обеспечивает компонент
    /// (документ §6, «Фон»).
    public var headerColor: UIColor

    /// Акцентный цвет заголовка текущей (активной) секции.
    ///
    /// По умолчанию — `.systemBlue`. Цвет интерполируется по прогрессу `t`
    /// вместе с фейдом заголовков (§4): на целом `t` активный заголовок целиком
    /// окрашен этим цветом, а на переходе уходящий заголовок плавно возвращается
    /// к ``headerColor``, входящий — набирает акцент. Если задать то же значение,
    /// что и ``headerColor``, заголовки визуально не выделяются цветом.
    public var headerActiveColor: UIColor

    /// Поведение фона. По умолчанию `.none`.
    public var backgroundBehavior: BackgroundBehavior

    /// Поведение системной подстройки отступов горизонтальной полосы секций
    /// (документ §8, «Navigation bar»).
    ///
    /// По умолчанию `.never`: кадр полосы задаёт панорама (под слоем
    /// заголовков), а safe area получают сами контроллеры секций; фон при этом
    /// лежит под баром на всю высоту вида. Иные значения нужны, когда хост хочет,
    /// чтобы UIKit сам отступил от бара/home-индикатора.
    ///
    /// - Important: Геометрия снапа и прогресс `t` считаются от `contentOffset`
    ///   без учёта горизонтальных `adjustedContentInset`: значения, дающие
    ///   боковые отступы (`.always`, а в альбомной ориентации с вырезом — и
    ///   `.automatic`/`.scrollableAxes`), сдвигают ленту на величину бокового
    ///   safe area. Для полноэкранной панорамы оставляйте `.never`.
    public var contentInsetAdjustmentBehavior: UIScrollView.ContentInsetAdjustmentBehavior

    /// Нижняя и верхняя границы ``peek`` (документ §4, «Ширина секции»).
    private static let peekRange: ClosedRange<CGFloat> = 16...64

    /// Границы ``parallaxFactor``: открытый интервал `(0, 1)` из §4
    /// («Параллакс фона»), представленный замкнутым `0.01...0.99`.
    static let parallaxFactorRange: ClosedRange<CGFloat> = 0.01...0.99

    /// Дефолт ``peek``; используется при нечисловом входе.
    private static let defaultPeek: CGFloat = 48

    /// Дефолт ``parallaxFactor``; используется при нечисловом входе.
    private static let defaultParallaxFactor: CGFloat = 0.5

    /// Создаёт стиль панорамы; у всех параметров есть системные дефолты.
    ///
    /// - Parameters:
    ///   - peek: Ширина зоны подсматривания следующей секции, по умолчанию `48`.
    ///     Значения вне `16...64` приводятся к ближайшей границе.
    ///   - parallaxFactor: Множитель параллакса фона, по умолчанию `0.5`.
    ///     Значения вне открытого интервала `(0, 1)` приводятся к ближайшей
    ///     границе `0.01...0.99` (§4).
    ///   - headerFont: Базовый (немасштабированный) шрифт заголовков, по
    ///     умолчанию системный bold 34 pt.
    ///   - headerColor: Цвет неактивного заголовка, по умолчанию `.label`.
    ///   - headerActiveColor: Акцентный цвет активного заголовка,
    ///     по умолчанию `.systemBlue`.
    ///   - backgroundBehavior: Поведение фона, по умолчанию `.none`.
    ///   - contentInsetAdjustmentBehavior: Подстройка отступов полосы секций
    ///     под safe area, по умолчанию `.never` (§8).
    public init(
        peek: CGFloat = 48,
        parallaxFactor: CGFloat = 0.5,
        headerFont: UIFont = .systemFont(ofSize: 34, weight: .bold),
        headerColor: UIColor = .label,
        headerActiveColor: UIColor = .systemBlue,
        backgroundBehavior: BackgroundBehavior = .none,
        contentInsetAdjustmentBehavior: UIScrollView.ContentInsetAdjustmentBehavior = .never
    ) {
        // Кламп в инициализаторе обязателен: наблюдатели свойств не вызываются
        // при первой записи в init, поэтому без него инвариант диапазона
        // нарушился бы до первого внешнего присваивания.
        self.peek = Self.clampedPeek(peek)
        self.parallaxFactor = Self.clampedParallaxFactor(parallaxFactor)
        self.headerFont = headerFont
        self.headerColor = headerColor
        self.headerActiveColor = headerActiveColor
        self.backgroundBehavior = backgroundBehavior
        self.contentInsetAdjustmentBehavior = contentInsetAdjustmentBehavior
    }

    /// Совпадает ли стиль с другим по всем полям (E10.13).
    ///
    /// Нужен, чтобы контроллер не переприменял тот же стиль на каждом
    /// обновлении SwiftUI. Публичного `Equatable` нет: картинка фона сравнивается
    /// по идентичности (`===`), а не по содержимому — для пропуска лишней работы
    /// этого достаточно, но как общая семантика равенства это было бы неожиданно.
    ///
    /// - Parameter other: Стиль для сравнения.
    /// - Returns: `true`, если применение `other` вместо `self` ничего не меняет.
    func isEquivalent(to other: PanoramaStyle) -> Bool {
        peek == other.peek
            && parallaxFactor == other.parallaxFactor
            && headerFont == other.headerFont
            && headerColor == other.headerColor
            && headerActiveColor == other.headerActiveColor
            && contentInsetAdjustmentBehavior == other.contentInsetAdjustmentBehavior
            && backgroundBehavior.isIdentical(to: other.backgroundBehavior)
    }

    /// Приводит ``peek`` к диапазону `16...64`; нечисловой вход — к дефолту.
    private static func clampedPeek(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultPeek }
        return min(max(value, peekRange.lowerBound), peekRange.upperBound)
    }

    /// Приводит ``parallaxFactor`` к интервалу `(0, 1)` (`0.01...0.99`);
    /// нечисловой вход — к дефолту.
    private static func clampedParallaxFactor(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultParallaxFactor }
        return min(max(value, parallaxFactorRange.lowerBound), parallaxFactorRange.upperBound)
    }
}
#endif
