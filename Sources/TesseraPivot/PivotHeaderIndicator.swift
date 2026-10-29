//
//  PivotHeaderIndicator.swift
//  TesseraPivot
//
//  Индикатор активного заголовка пивота.
//  Контракт: docs/PIVOT-IOS-DESIGN.md §3 «Архитектура» (лента заголовков +
//  индикатор), §4 «Математика ядра» (индикатор = lerp(центров соседних
//  заголовков); окраска — по расстоянию от `t`), §7 «Производительность»
//  (индикатор — отдельный слой, гоняется только трансформом), §8
//  «Accessibility» (RTL, Reduce Motion).
//  Задача плана: E2.2.
//
//  Дисциплина производительности (§4, §7): в горячем пути скролла меняется
//  только `transform`. Базовая позиция (`bounds`/`center`) задаётся один раз
//  за layout-проход ленты — `placeBar(inStripBounds:)`. Чистые функции не
//  читают состояние и не требуют главного потока: их использует и лента, и
//  контрактные тесты E2.7.
//

#if canImport(UIKit)
import UIKit

/// Подчёркивание под активным заголовком ленты.
///
/// Отдельный слой поверх `UICollectionView` заголовков (§3, §7): ячейки
/// переиспользуются и перекрашиваются, а индикатор живёт сам по себе и потому
/// может непрерывно ехать между заголовками разной ширины (§4, «Важная
/// тонкость» — интерполируются именно центры, а не `t × constWidth`).
///
/// Положение меняется только через ``placeBar(inStripBounds:)`` (layout-проход)
/// и ``move(toCenterX:)`` (`transform` в горячем пути). Размер `bounds` в
/// горячем пути не трогается, `setNeedsLayout` не вызывается.
///
/// Порядок использования — только через ``PivotHeaderStripView``: он владеет
/// геометрией ленты и содержимым ячеек. Публичная поверхность самого индикатора
/// ограничена видом (цвет, толщина, ширина) и чистыми функциями для тестов.
///
/// ## Reduce Motion
///
/// Индикатор не анимируется сам по себе: он повторяет жест пользователя, пока
/// палец двигает пейджер (§8). Поэтому Reduce Motion его не отключает —
/// отключаются только самодвижущиеся анимации (например, автоцентрирование
/// ленты, см. `PivotHeaderStripView.scrollToCenter(index:animated:)`).
public final class PivotHeaderIndicator: UIView {

    // MARK: - Чистые функции (математика §4)

    /// Центр индикатора для прогресса `t` (docs/PIVOT-IOS-DESIGN.md §4).
    ///
    /// `indicatorCenter = lerp(center[i], center[i + 1], frac)`, где
    /// `i = clamp(floor(t), 0, count - 2)`. Ширины заголовков разные, поэтому
    /// интерполируются центры, а не множитель ширины: иначе индикатор
    /// «уплывает» от текста на середине свайпа (§4).
    ///
    /// Границы и защита от мусорных значений:
    /// - `centers` пуст — `0` (ленты нет, индикатор скрыт);
    /// - один центр (`count < 2`) — он же: интерполировать не с чем;
    /// - `t <= 0` — первый центр, `t >= count - 1` — последний: при bounce
    ///   прогресс уходит за диапазон, а индикатор не должен уезжать за крайние
    ///   заголовки;
    /// - `NaN` — первый центр (неопределённый прогресс = начало ленты);
    /// - бесконечности зажимаются границами, поэтому приведение к `Int` ниже
    ///   никогда не переполняется.
    ///
    /// Дробная часть берётся от **зажатого** прогресса: на `t = count - 1` это
    /// даёт ровно последний центр, а не «первый из последней пары» — типовая
    /// ошибка `frac(t)` от незажатого `t`.
    ///
    /// - Parameters:
    ///   - centers: Центры заголовков в координатах контента ленты, в порядке
    ///     чтения (в RTL — уже зеркалированные, см. `PivotHeaderStripView`).
    ///   - t: Нормализованный по направлению чтения прогресс
    ///     `contentOffset.x / pageWidth` (§4).
    /// - Returns: Центр индикатора в тех же координатах, что и `centers`.
    public static func indicatorCenter(centers: [CGFloat], progress t: CGFloat) -> CGFloat {
        guard let firstCenter = centers.first else { return 0 }
        guard centers.count > 1 else { return firstCenter }
        guard !t.isNaN else { return firstCenter }

        let lastIndex = centers.count - 1
        let clampedProgress = min(max(t, 0), CGFloat(lastIndex))
        let lowerIndex = min(Int(clampedProgress.rounded(.down)), lastIndex - 1)
        let fraction = clampedProgress - CGFloat(lowerIndex)

        let lowerCenter = centers[lowerIndex]
        let upperCenter = centers[lowerIndex + 1]

        return lowerCenter + (upperCenter - lowerCenter) * fraction
    }

    /// Насколько заголовок «активен» по расстоянию от прогресса (§4, «Окраска
    /// текста»).
    ///
    /// `factor = 1 - clamp(|distance| / span, 0, 1)`; `span` по умолчанию `1` —
    /// расстояние в единицах индексов страниц. `distance` считается как
    /// `index - t` (знак не важен, берётся модуль). Возвращает `1` в точке `t`,
    /// `0` на расстоянии `span` и дальше — так лента плавно «передаёт акцент»
    /// от уходящего заголовка к приходящему, а не переключает его скачком.
    ///
    /// Защитные случаи: `span <= 0` — «размывать нечего»: `1` при нулевом
    /// расстоянии, иначе `0`; `NaN` в любом аргументе и бесконечное расстояние —
    /// `0` (неизвестный заголовок считается неактивным).
    ///
    /// - Parameters:
    ///   - distance: Расстояние заголовка от прогресса в единицах индексов
    ///     (`index - t`).
    ///   - span: Радиус подсветки; значения `<= 0` трактуются как «без
    ///     размывания».
    /// - Returns: Коэффициент в `0...1`, где `1` — полный акцентный цвет.
    public static func blendFactor(distanceFromProgress distance: CGFloat, span: CGFloat = 1) -> CGFloat {
        guard !distance.isNaN, !span.isNaN else { return 0 }
        guard span > 0 else { return distance == 0 ? 1 : 0 }
        guard !distance.isInfinite else { return 0 }

        let ratio = abs(distance) / span
        return max(0, 1 - min(ratio, 1))
    }

    // MARK: - Вид

    /// Цвет подчёркивания — акцентный цвет стиля (§3: «вид индикатора —
    /// подчёркивание и/или акцентный цвет текста»).
    ///
    /// Лента выставляет его из ``PivotHeaderStripView/activeColor``. Динамические
    /// системные цвета работают как есть: подчёркивание — фон вью, тему меняет
    /// UIKit.
    public var activeColor: UIColor {
        didSet {
            guard activeColor != oldValue else { return }
            backgroundColor = activeColor
        }
    }

    /// Ширина подчёркивания в точках.
    ///
    /// Подчёркивание не повторяет ширину активного заголовка: его ширина
    /// фиксирована, а меняются только центр и толщина. Изменение размера
    /// применяется на ближайшем layout-проходе ленты (пометка `setNeedsLayout`
    /// у супервью), в горячем пути свайпа размер не меняется (§4, §7).
    public var barWidth: CGFloat = 24 {
        didSet {
            guard barWidth != oldValue else { return }
            superview?.setNeedsLayout()
        }
    }

    /// Толщина подчёркивания в точках (по умолчанию 3 pt — узнаваемая толщина
    /// WP-акцента).
    public var barHeight: CGFloat = 3 {
        didSet {
            guard barHeight != oldValue else { return }
            superview?.setNeedsLayout()
        }
    }

    // MARK: - Инициализация

    /// Создаёт индикатор с акцентным цветом.
    ///
    /// - Parameter activeColor: Цвет подчёркивания; по умолчанию `.systemBlue` —
    ///   дефолт ``PivotStyle/activeColor``.
    public init(activeColor: UIColor = .systemBlue) {
        self.activeColor = activeColor
        super.init(frame: .zero)
        configure()
    }

    /// Создаёт индикатор из архива/сториборда.
    ///
    /// - Parameter coder: Декодер архива.
    public required init?(coder: NSCoder) {
        self.activeColor = .systemBlue
        super.init(coder: coder)
        configure()
    }

    /// Общая настройка: слой декоративный, событий не ловит и в
    /// accessibility-дерево не входит — VoiceOver озвучивает заголовки-кнопки
    /// (§8), а не подчёркивание.
    private func configure() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = activeColor
        layer.cornerRadius = barHeight / 2
        isHidden = true
    }

    // MARK: - Позиционирование (внутренний контракт с лентой)

    /// Раскладывает подчёркивание на базовую позицию внутри ленты.
    ///
    /// Вызывается только из layout-прохода ``PivotHeaderStripView`` (§7). Здесь
    /// допустим `bounds`/`center`; после этого ``move(toCenterX:)`` сдвигает
    /// подчёркивание одним `transform` и layout больше не трогает.
    ///
    /// - Parameter stripBounds: `bounds` ленты в её собственной системе координат:
    ///   индикатор прижат к нижней кромке.
    internal func placeBar(inStripBounds stripBounds: CGRect) {
        transform = .identity
        bounds = CGRect(x: 0, y: 0, width: barWidth, height: barHeight)
        center = CGPoint(
            x: barWidth / 2,
            y: stripBounds.maxY - barHeight / 2
        )
        layer.cornerRadius = barHeight / 2
    }

    /// Сдвигает подчёркивание к центру `centerX` в координатах ленты.
    ///
    /// Только `transform`: ни `frame`, ни `bounds`, ни `setNeedsLayout` (§4, §7).
    /// Так как базовая позиция после ``placeBar(inStripBounds:)`` — левый край
    /// (`origin.x == 0`), сдвиг `centerX - barWidth / 2` ставит центр
    /// подчёркивания ровно в `centerX`.
    ///
    /// - Parameter centerX: Центр в координатах ленты (обычно из
    ///   ``indicatorCenter(centers:progress:)``, пересчитанный на текущий
    ///   `contentOffset` ленты).
    internal func move(toCenterX centerX: CGFloat) {
        let translation = CGAffineTransform(translationX: centerX - barWidth / 2, y: 0)
        guard transform != translation else { return }
        transform = translation
    }
}
#endif
