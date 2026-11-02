//
//  PanoHeaderView.swift
//  TesseraPanorama
//
//  Слой заголовков секций панорамы.
//  Проектный документ: docs/PANORAMA-IOS-DESIGN.md — §3 (PanoHeaderView),
//  §4 «Заголовки» (кусочно-линейная интерполяция по дробной части t),
//  §6 (дисциплина производительности), §7 (Reduce Motion, Dynamic Type, RTL).
//

import TesseraCore
import UIKit

/// Слой заголовков секций панорамы.
///
/// По §3 `docs/PANORAMA-IOS-DESIGN.md` это отдельный слой над секциями: он не
/// владеет `contentOffset` и получает прогресс `t` снаружи. Каждый заголовок —
/// `UILabel` на текстовом стиле Dynamic Type; видимость и сдвиг метки считаются
/// от одной и той же фазы, поэтому смена секций — непрерывное «перетекание»,
/// а не жёсткое переключение (§4).
///
/// ## Модель фазы
///
/// Для метки секции `i` при прогрессе `t` (в порядке чтения):
///
/// ```
/// phase = 0.5 + (i - t) / 2
/// ```
///
/// - `phase == 0.5` — секция активна: заголовок в центре, альфа 1, сдвиг 0;
/// - `phase` в `0...0.5` — соседняя секция позади по порядку чтения;
/// - `phase` в `0.5...1` — соседняя секция впереди.
///
/// Альфа и сдвиг берутся из ``keyframeAlpha(progress:)`` и
/// ``keyframeOffset(progress:travel:)`` — кусочно-линейно между кадрами
/// `0`, `0.5`, `1` (§4). На середине перехода (`frac(t) == 0.5`) видны обе
/// соседние метки с альфой 0.5; к целому `t` остаётся ровно одна активная.
/// На стыках секций значения непрерывны — скачка нет.
///
/// Для `t = i + f`, `f` в `0...1`, формулы соседних секций сводятся к линейным:
///
/// ```
/// секция i    (активная): alpha = 1 − f,  offset = −(f/2)·travel
/// секция i+1  (следующая): alpha = f,     offset = ((1 − f)/2)·travel
/// ```
///
/// Это удобная форма для контрактных тестов E3.7: на `f = 0` видна только
/// секция `i`, на `f = 1` — только `i + 1`.
///
/// ## Производительность
///
/// ``apply(progress:activeIndex:)`` вызывается из `scrollViewDidScroll` и меняет
/// только `alpha`/`transform`; ни `setNeedsLayout`, ни `sizeThatFits` в этом пути
/// нет (§4, §6). Единственное исключение — текст accessibility-элемента, и то
/// лишь на границе секций. Раскладка меток выполняется один раз в
/// `layoutSubviews` — при создании и смене размера; там же сбрасывается и заново
/// считается transform.
///
/// ## Доступность (§7)
///
/// - **Reduce Motion** — провайдер ``isReduceMotionEnabled`` (по умолчанию
///   системная настройка через `TesseraAccessibility`). При `true` заголовки
///   статичны: виден только активный, без сдвига и фейдов.
/// - **Dynamic Type** — `UIFont.preferredFont(forTextStyle:)` либо базовый
///   шрифт, масштабированный через `UIFontMetrics`, плюс
///   `adjustsFontForContentSizeCategory`; при смене размера текста вид
///   пересчитывает раскладку (вне скролла).
/// - **RTL** — `t` приходит нормализованным по направлению чтения (см.
///   `TesseraRTL.normalizedProgress`). Знак горизонтального сдвига, отступы и
///   выравнивание текста зеркалятся по `effectiveUserInterfaceLayoutDirection`.
/// - **VoiceOver** — вид является одним accessibility-элементом с трейтом
///   `.header` и текстом активной секции. Сами метки для VoiceOver скрыты,
///   чтобы угасающий сосед не читался как отдельный заголовок.
///
/// - Note: `t` — прогресс пейджера в порядке чтения; вид не пишет
///   `contentOffset` (§2 `docs/CORE-IOS-DESIGN.md`), а только читает его
///   производную.
///
/// Внутримодульное имя из §3 — `PanoHeaderView` (`typealias` ниже); публичное
/// имя несёт префикс `Tessera` по правилу `AGENTS.md`.
public final class TesseraPanoHeaderView: UIView {

    // MARK: - Стиль

    /// Стиль заголовков секций.
    ///
    /// Намеренно минимален: типографика задана текстовым стилем Dynamic Type
    /// (или базовым шрифтом, который масштабирует `UIFontMetrics`), а не
    /// абсолютным размером (§7 `docs/PANORAMA-IOS-DESIGN.md`).
    public struct Style {

        /// Текстовый стиль, по метрикам которого масштабируется шрифт
        /// заголовков (Dynamic Type, §7).
        ///
        /// По умолчанию `.largeTitle` — крупный заголовок секции в духе
        /// Windows Phone Panorama.
        public var textStyle: UIFont.TextStyle

        /// Базовый (немасштабированный) шрифт заголовков.
        ///
        /// Если задан, вид масштабирует его через
        /// `UIFontMetrics(forTextStyle:).scaledFont(for:)` — именно так
        /// `PanoramaStyle.headerFont` из §3 попадает в заголовки.
        /// `nil` означает «взять `UIFont.preferredFont(forTextStyle:)`».
        ///
        /// - Important: Передавайте немасштабированный шрифт. Если передать
        ///   уже масштабированный (например, `preferredFont`), Dynamic Type
        ///   применится дважды.
        public var baseFont: UIFont?

        /// Цвет текста заголовков. Прозрачность (фейд) задаётся альфой метки,
        /// поэтому цвет может быть любым, включая акцентный.
        public var textColor: UIColor

        /// Цвет активного заголовка (`PanoramaStyle.headerActiveColor`, E9.7).
        ///
        /// `nil` — заголовки одного цвета ``textColor``. Иначе цвет
        /// интерполируется по прогрессу `t`: вес акцента у заголовка равен его
        /// «активности» — той же кусочно-линейной функции фазы, что и альфа
        /// (``TesseraPanoHeaderView/keyframeAlpha(progress:)``): `1` на целом `t`
        /// своей секции, `0` у соседа на целом `t`. Интерполяция выполняется
        /// альфой акцентной копии метки поверх основной, поэтому горячий путь
        /// по-прежнему трогает только `alpha`/`transform` (§4, §6).
        public var activeTextColor: UIColor?

        /// Амплитуда горизонтального сдвига как доля ширины вида.
        ///
        /// Полный размах сдвига — `travel = width * travelRatio`; заголовок
        /// уезжает на `±travel/2` при полном угасании. Отрицательные значения
        /// при инициализации приводятся к нулю.
        public var travelRatio: CGFloat

        /// Отступы содержимого; в RTL левый и правый меняются местами.
        public var contentInsets: UIEdgeInsets

        /// Максимальное число строк заголовка; `0` — без ограничения.
        ///
        /// При больших размерах Dynamic Type многострочный заголовок не
        /// обрезается по словам (§7).
        public var numberOfLines: Int

        /// Создаёт стиль заголовков.
        public init(
            textStyle: UIFont.TextStyle = .largeTitle,
            baseFont: UIFont? = nil,
            textColor: UIColor = .label,
            activeTextColor: UIColor? = nil,
            travelRatio: CGFloat = 0.3,
            contentInsets: UIEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16),
            numberOfLines: Int = 0
        ) {
            self.textStyle = textStyle
            self.baseFont = baseFont
            self.textColor = textColor
            self.activeTextColor = activeTextColor
            self.travelRatio = max(travelRatio, 0)
            self.contentInsets = contentInsets
            self.numberOfLines = max(numberOfLines, 0)
        }
    }

    // MARK: - Состояние

    /// Провайдер настройки Reduce Motion.
    ///
    /// Инжектируется для тестов и для хостов, у которых своё представление о
    /// движении. По умолчанию читает системную настройку в момент вызова
    /// (значение не кешируется: включение Reduce Motion во время работы
    /// приложения срабатывает сразу). См. §7 `docs/PANORAMA-IOS-DESIGN.md`.
    public var isReduceMotionEnabled: () -> Bool = {
        TesseraAccessibility.isReduceMotionEnabled
    }

    /// Заголовки секций в порядке чтения (индекс 0 — первая секция).
    ///
    /// Меняются только через ``setTitles(_:)``: пересоздание меток — это
    /// раскладка, поэтому его нельзя вызывать во время скролла.
    public private(set) var titles: [String]

    /// Стиль заголовков. Изменение применяется сразу (вне скролла).
    public var style: Style {
        didSet {
            applyStyleToLabels()
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            // Размер шрифта мог измениться — сдвиг зависит от ширины вида,
            // поэтому пересчитываем transform уже после ближайшей раскладки.
            applyCurrentState()
        }
    }

    /// Метки по одной на секцию; порядок совпадает с ``titles``.
    private var labels: [UILabel] = []

    /// Акцентные копии меток (``Style/activeTextColor``), по одной на секцию.
    ///
    /// Каждая лежит **внутри** своей метки (subview) с тем же текстом и
    /// кадром `bounds` метки: сдвиг и фейд метки применяются к ней автоматически
    /// (групповая прозрачность слоя), а вес акцента — её собственная альфа.
    /// Непрозрачный акцент поверх непрозрачного глифа даёт ровно линейную
    /// интерполяцию цветов. Пусто, если акцентный цвет не задан.
    private var accentLabels: [UILabel] = []

    /// Маршрут VoiceOver-жеста «три пальца» с заголовка (E9.7).
    ///
    /// Слой заголовков — отдельный accessibility-элемент, и фокус VoiceOver
    /// может стоять на нём; без маршрута трёхпальцевый свайп с заголовка не
    /// листал бы секции. Обработчик задаёт контроллер панорамы: направление
    /// он превращает в шаг по секциям и пишет `contentOffset` сам (§2,
    /// «Один писатель»). `nil` — жест уходит системе.
    var accessibilityScrollHandler: ((UIAccessibilityScrollDirection) -> Bool)?

    /// Последний прогресс из ``apply(progress:activeIndex:)`` — чтобы
    /// переприменить состояние после раскладки, смены стиля или Reduce Motion.
    private var storedProgress: CGFloat = 0

    /// Последний индекс активной секции из ``apply(progress:activeIndex:)``.
    private var storedActiveIndex: Int = 0

    /// Индекс, для которого уже выставлен `accessibilityLabel`.
    private var accessibilityTitleIndex: Int = -1

    // MARK: - Жизненный цикл

    /// Создаёт слой заголовков.
    ///
    /// - Parameters:
    ///   - titles: Заголовки секций в порядке чтения.
    ///   - style: Стиль заголовков.
    public init(titles: [String], style: Style = Style()) {
        self.titles = titles
        self.style = style
        super.init(frame: .zero)
        commonInit()
    }

    /// Не поддерживается: вид создаётся только из кода.
    @available(*, unavailable, message: "Используйте init(titles:style:)")
    public required init?(coder: NSCoder) {
        fatalError("TesseraPanoHeaderView не поддерживает загрузку из Interface Builder")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func commonInit() {
        backgroundColor = .clear
        // Заголовки — декоративный слой над контентом: касания должны уходить
        // в пейджер и секции. VoiceOver при этом продолжает видеть элемент.
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .header

        rebuildLabels()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reduceMotionStatusDidChange),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )

        apply(progress: 0, activeIndex: 0)
    }

    // MARK: - Публичный API

    /// Заменяет набор заголовков.
    ///
    /// Пересоздаёт метки и запускает раскладку, поэтому вызывать метод можно
    /// только вне `scrollViewDidScroll` (§6 `docs/PANORAMA-IOS-DESIGN.md`).
    ///
    /// - Parameter titles: Заголовки секций в порядке чтения.
    public func setTitles(_ titles: [String]) {
        guard titles != self.titles else { return }
        self.titles = titles
        rebuildLabels()
        applyCurrentState()
    }

    /// Применяет прогресс свайпа к заголовкам.
    ///
    /// Вызывается из `scrollViewDidScroll` пейджера и меняет **только**
    /// `alpha` и `transform` меток — без раскладки, без создания представлений
    /// и без записи `contentOffset` (§4, §6 `docs/PANORAMA-IOS-DESIGN.md`).
    /// Дополнительно на границе секций обновляется `accessibilityLabel`
    /// заголовка (см. §7), чтобы VoiceOver читал актуальную секцию; это не
    /// геометрия и не вызывает layout-прохода.
    ///
    /// Контракт параметров:
    /// - `t` — глобальный прогресс `contentOffset.x / itemWidth`, уже
    ///   нормализованный по направлению чтения (`TesseraRTL.normalizedProgress`).
    ///   Целая часть — индекс секции, дробная — прогресс перехода.
    /// - `activeIndex` — индекс активной секции (целая часть `t`). Используется
    ///   для статичного режима Reduce Motion и текста VoiceOver; непрерывные
    ///   transform/alpha считаются от `t`, поэтому заголовки остаются плавными
    ///   даже при расхождении аргументов на кадр.
    ///
    /// При включённом Reduce Motion (§7) движение отключается: показывается
    /// только заголовок `activeIndex`, остальные скрыты, сдвига нет.
    ///
    /// - Parameters:
    ///   - t: Прогресс пейджера в порядке чтения.
    ///   - activeIndex: Индекс активной секции.
    public func apply(progress t: CGFloat, activeIndex: Int) {
        storedProgress = t
        storedActiveIndex = activeIndex
        applyCurrentState()
    }

    // MARK: - Чистая математика (публичная для контрактных тестов E3.7)

    /// Альфа заголовка по его фазе.
    ///
    /// Ключевые кадры §4 `docs/PANORAMA-IOS-DESIGN.md`:
    ///
    /// ```
    /// 0 → 0, 0.5 → 1, 1 → 0
    /// ```
    ///
    /// Кусочно-линейная интерполяция (`x` — аргумент, зажатый в `0...1`):
    ///
    /// ```
    /// x ≤ 0.5:  alpha = 2x
    /// x > 0.5:  alpha = 2 − 2x
    /// ```
    ///
    /// Пик приходится ровно на фазу 0.5 — момент, когда секция находится
    /// в центре вида. На краях фазы заголовок полностью прозрачен: соседняя
    /// секция ещё не вошла (или уже ушла).
    ///
    /// Функция чистая: не читает состояние вида, не требует главного потока,
    /// не вызывает side effects. Защитные случаи: `NaN` даёт `0`, бесконечности
    /// зажимаются границами.
    ///
    /// - Parameter frac: Фаза заголовка (`0...1`; значения вне диапазона
    ///   зажимаются).
    /// - Returns: Альфа в `0...1`.
    public static func keyframeAlpha(progress frac: CGFloat) -> CGFloat {
        guard !frac.isNaN else { return 0 }

        let x = min(max(frac, 0), 1)
        if x <= 0.5 {
            return 2 * x
        }
        return 2 - 2 * x
    }

    /// Горизонтальный сдвиг заголовка по его фазе.
    ///
    /// Ключевые кадры:
    ///
    /// ```
    /// 0 → −travel/2, 0.5 → 0, 1 → +travel/2
    /// ```
    ///
    /// Формула (линейная интерполяция, `x` — аргумент, зажатый в `0...1`):
    ///
    /// ```
    /// offset = (x − 0.5) · travel
    /// ```
    ///
    /// В кадре 0.5 (активный заголовок) сдвиг нулевой — метка стоит на своём
    /// месте; максимальное отклонение `±travel/2` достигается на краях, где
    /// альфа уже равна нулю. Знак направления задаёт вызывающий: в RTL сдвиг
    /// зеркалится, потому что «следующая секция» приходит слева.
    ///
    /// Функция чистая; `NaN` даёт `0`, бесконечности зажимаются границами,
    /// отрицательный `travel` просто меняет знак сдвига.
    ///
    /// - Parameters:
    ///   - frac: Фаза заголовка (`0...1`; значения вне диапазона зажимаются).
    ///   - travel: Полный размах сдвига в точках.
    /// - Returns: Сдвиг по горизонтали в точках.
    public static func keyframeOffset(progress frac: CGFloat, travel: CGFloat) -> CGFloat {
        guard !frac.isNaN else { return 0 }

        let x = min(max(frac, 0), 1)
        return (x - 0.5) * travel
    }

    /// Фаза заголовка секции `index` для прогресса `t`.
    ///
    /// `phase = 0.5 + (index − t) / 2`; в кадре 0.5 метка стоит в центре.
    /// Шаг фазы между соседними секциями — 0.5, поэтому уже вторая соседняя
    /// секция полностью прозрачна.
    private static func phase(index: Int, progress t: CGFloat) -> CGFloat {
        0.5 + (CGFloat(index) - t) * 0.5
    }

    /// Вес акцентного цвета заголовка секции `index` при прогрессе `t` (E9.7).
    ///
    /// `weight = max(0, 1 − |index − t|)` — «активность» секции; совпадает с
    /// ``keyframeAlpha(progress:)`` её фазы. Видимый цвет заголовка —
    /// `lerp(textColor, activeTextColor, weight)`.
    ///
    /// - Parameters:
    ///   - index: Индекс секции в порядке чтения.
    ///   - t: Прогресс в порядке чтения.
    /// - Returns: Вес в `0...1`.
    static func activeColorWeight(index: Int, progress t: CGFloat) -> CGFloat {
        keyframeAlpha(progress: phase(index: index, progress: t))
    }

    // MARK: - Применение состояния

    private func applyCurrentState() {
        guard !labels.isEmpty else { return }

        let activeIndex = clampedIndex(storedActiveIndex)

        guard !isReduceMotionEnabled() else {
            applyStaticState(activeIndex: activeIndex)
            return
        }

        // Прогресс за пределы ленты выходит только на bounce. Дробную часть
        // зажимаем, чтобы крайний заголовок не «затухал» при упругом отскоке.
        let maxProgress = CGFloat(max(labels.count - 1, 0))
        let progress = storedProgress.isNaN
            ? CGFloat(activeIndex)
            : min(max(storedProgress, 0), maxProgress)

        let travel = max(bounds.width, 0) * style.travelRatio
        let direction: CGFloat = effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1

        for (index, label) in labels.enumerated() {
            let phase = Self.phase(index: index, progress: progress)
            let alpha = Self.keyframeAlpha(progress: phase)
            let offset = Self.keyframeOffset(progress: phase, travel: travel)

            // Строго только alpha/transform: никакой геометрии и раскладки.
            label.alpha = alpha
            label.transform = CGAffineTransform(translationX: direction * offset, y: 0)
            // Вес акцента — «активность» заголовка: та же функция фазы, что и
            // альфа (1 на целом t своей секции, 0 у соседа). Только alpha.
            if accentLabels.indices.contains(index) {
                accentLabels[index].alpha = Self.activeColorWeight(index: index, progress: progress)
            }
        }

        // Единственное, что apply трогает помимо alpha/transform, — текст
        // accessibility-элемента при смене активной секции (§7). Это не
        // раскладка и не геометрия; обновление происходит только на границе
        // секций, а не на каждом кадре.
        updateAccessibilityTitle(for: activeIndex)
    }

    /// Статичное состояние для Reduce Motion (§7): только активный заголовок,
    /// без сдвига и фейдов.
    private func applyStaticState(activeIndex: Int) {
        for (index, label) in labels.enumerated() {
            label.alpha = index == activeIndex ? 1 : 0
            label.transform = .identity
            if accentLabels.indices.contains(index) {
                accentLabels[index].alpha = index == activeIndex ? 1 : 0
            }
        }

        updateAccessibilityTitle(for: activeIndex)
    }

    /// Пересчитывает `accessibilityLabel` только при смене активной секции,
    /// чтобы не трогать accessibility-дерево на каждом кадре скролла.
    private func updateAccessibilityTitle(for index: Int) {
        guard titles.indices.contains(index) else {
            accessibilityTitleIndex = -1
            accessibilityLabel = nil
            return
        }

        guard index != accessibilityTitleIndex else { return }
        accessibilityTitleIndex = index
        accessibilityLabel = titles[index]
    }

    private func clampedIndex(_ index: Int) -> Int {
        guard !labels.isEmpty else { return 0 }
        return min(max(index, 0), labels.count - 1)
    }

    // MARK: - Раскладка

    public override func layoutSubviews() {
        super.layoutSubviews()

        guard !labels.isEmpty else { return }

        let insets = resolvedContentInsets()
        let content = bounds.inset(by: insets)
        let width = max(content.width, 0)
        let height = max(content.height, 0)

        for label in labels {
            // Frame и transform смешивать нельзя (UIKit не гарантирует
            // результат), поэтому на время раскладки сдвиг сбрасывается,
            // а после установки frame применяется заново из сохранённого
            // прогресса. Раскладка происходит вне scrollViewDidScroll.
            label.transform = .identity

            let fitting = label.sizeThatFits(
                CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            )
            let labelHeight = height > 0 ? min(fitting.height, height) : fitting.height
            label.frame = CGRect(
                x: content.minX,
                y: content.minY,
                width: width,
                height: labelHeight
            )
        }

        for (index, accent) in accentLabels.enumerated() where labels.indices.contains(index) {
            accent.frame = labels[index].bounds
        }

        applyCurrentState()
    }

    public override var intrinsicContentSize: CGSize {
        let insets = resolvedContentInsets()
        let vertical = insets.top + insets.bottom
        let width = max(bounds.width - insets.left - insets.right, 0)

        guard width > 0, !labels.isEmpty else {
            let lineHeight = scaledFont.lineHeight
            return CGSize(
                width: UIView.noIntrinsicMetric,
                height: max((lineHeight + vertical).rounded(.up), 0)
            )
        }

        var contentHeight: CGFloat = 0
        for label in labels {
            let fitting = label.sizeThatFits(
                CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            )
            contentHeight = max(contentHeight, fitting.height)
        }

        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: max((contentHeight + vertical).rounded(.up), 0)
        )
    }

    /// Отступы с учётом направления раскладки: в RTL левый и правый
    /// меняются местами, чтобы у заголовка был один и тот же «ведущий» край.
    private func resolvedContentInsets() -> UIEdgeInsets {
        var insets = style.contentInsets
        if effectiveUserInterfaceLayoutDirection == .rightToLeft {
            // Обмен через локальную переменную: прямые два inout-доступа
            // к свойствам одной структуры нарушают эксклюзивность Swift.
            let left = insets.left
            insets.left = insets.right
            insets.right = left
        }
        insets.top = max(insets.top, 0)
        insets.left = max(insets.left, 0)
        insets.bottom = max(insets.bottom, 0)
        insets.right = max(insets.right, 0)
        return insets
    }

    // MARK: - Метки

    private func rebuildLabels() {
        labels.forEach { $0.removeFromSuperview() }
        // Акцентные копии лежат внутри старых меток и уходят вместе с ними.
        accentLabels = []
        labels = titles.map(Self.makeLabel(text:))
        labels.forEach { addSubview($0) }

        applyStyleToLabels()

        isAccessibilityElement = !titles.isEmpty
        accessibilityTitleIndex = -1
        accessibilityLabel = nil

        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// Метка заголовка: только визуал, для VoiceOver скрыта (§7).
    private static func makeLabel(text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textAlignment = .natural
        label.isAccessibilityElement = false
        label.isUserInteractionEnabled = false
        return label
    }

    /// Создаёт или убирает акцентные копии меток под ``Style/activeTextColor``.
    ///
    /// Вызывается при пересоздании меток и при смене стиля — вне скролла.
    private func syncAccentLabels() {
        let needsAccent = style.activeTextColor != nil
        let isInSync = needsAccent
            ? accentLabels.count == labels.count
            : accentLabels.isEmpty
        guard !isInSync else { return }

        accentLabels.forEach { $0.removeFromSuperview() }
        accentLabels = []
        guard needsAccent else { return }

        accentLabels = labels.map { label in
            let accent = Self.makeLabel(text: label.text ?? "")
            accent.frame = label.bounds
            accent.alpha = 0
            label.addSubview(accent)
            return accent
        }
        setNeedsLayout()
    }

    private func applyStyleToLabels() {
        syncAccentLabels()

        let font = scaledFont
        for (index, label) in labels.enumerated() {
            Self.configure(label, font: font, color: style.textColor, numberOfLines: style.numberOfLines)
            if let activeColor = style.activeTextColor, accentLabels.indices.contains(index) {
                Self.configure(
                    accentLabels[index],
                    font: font,
                    color: activeColor,
                    numberOfLines: style.numberOfLines
                )
            }
        }
    }

    /// Типографика метки (основной и акцентной — одинаковая, кроме цвета).
    private static func configure(
        _ label: UILabel,
        font: UIFont,
        color: UIColor,
        numberOfLines: Int
    ) {
        label.font = font
        // Шрифт получен из UIFontMetrics/preferredFont, поэтому метка сама
        // пересчитает его при смене категории Dynamic Type (§7).
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = numberOfLines
        label.textAlignment = .natural
    }

    // MARK: - Accessibility (§7)

    /// Трёхпальцевый свайп VoiceOver с фокусом на заголовке (E9.7).
    ///
    /// Жест уходит в ``accessibilityScrollHandler`` (контроллер панорамы); без
    /// обработчика или при отказе — системе.
    ///
    /// - Parameter direction: Направление жеста VoiceOver.
    /// - Returns: `true`, если жест обработан.
    public override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        if let accessibilityScrollHandler, accessibilityScrollHandler(direction) {
            return true
        }
        return super.accessibilityScroll(direction)
    }

    /// Шрифт заголовков под текущую категорию Dynamic Type.
    ///
    /// - если задан ``Style/baseFont`` — `UIFontMetrics` масштабирует его
    ///   (интеграция с `PanoramaStyle.headerFont`, §3);
    /// - иначе берётся системный `preferredFont(forTextStyle:)`.
    private var scaledFont: UIFont {
        let metrics = UIFontMetrics(forTextStyle: style.textStyle)
        guard let baseFont = style.baseFont else {
            return UIFont.preferredFont(forTextStyle: style.textStyle, compatibleWith: traitCollection)
        }
        return metrics.scaledFont(for: baseFont, compatibleWith: traitCollection)
    }

    // MARK: - Системные изменения

    /// Reduce Motion включили/выключили — переприменяем сохранённый прогресс.
    @objc private func reduceMotionStatusDidChange() {
        applyCurrentState()
    }

    /// Сменился размер текста Dynamic Type — нужна новая раскладка меток.
    /// Сами шрифты обновляет `adjustsFontForContentSizeCategory`.
    @objc private func contentSizeCategoryDidChange() {
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
}

/// Архитектурное имя слоя из §3 `docs/PANORAMA-IOS-DESIGN.md`.
/// Остаётся внутренним: публичный тип несёт префикс `Tessera`.
typealias PanoHeaderView = TesseraPanoHeaderView
