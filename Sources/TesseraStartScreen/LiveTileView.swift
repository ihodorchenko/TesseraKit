//
//  LiveTileView.swift
//  TesseraStartScreen
//
//  Контейнер живой плитки: две стороны и независимый бэйдж.
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md — §4 «Live-плитки
//  (движок)» (флип: `CATransform3D` + перспектива `m34`, поворот по Y на 90°,
//  подмена стороны, доворот; только трансформы, layout не трогаем; бэйдж —
//  отдельный view, не часть флипа), §9 «Accessibility» (VoiceOver, Dynamic
//  Type, RTL) и §10 «MVP» (флип простых текстовых плиток). Уточнения — D12 и
//  D15 в docs/STATE.md.
//  Задача плана: E4.3 «LiveTileEngine (волна 1)».
//
//  Дисциплина производительности (§4, RISK.md R10): флип не меняет `frame`,
//  `bounds` и не вызывает layout — только `layer.transform` и `isHidden` в
//  момент подмены стороны. Текст и цвета меняются вне горячего пути: при
//  регистрации, обновлении контента и смене стороны.
//

#if canImport(UIKit)
import UIKit

// MARK: - Бэйдж

/// Бэйдж живой плитки: красная точка или счётчик внимания (§4, «Бэйдж»;
/// D12/D15 — бэйдж ярлыка).
///
/// Отдельный view поверх контейнера плитки, **не часть флипа**: при перевороте
/// бэйдж остаётся на месте и не поворачивается вместе со стороной (§4).
/// Содержимое берётся напрямую из модели ярлыка ``TesseraTileBadge`` (D12): это
/// ровно те же три состояния, что хранит `TesseraTileDescriptor.badge`, поэтому
/// преобразование не нужно и модель остаётся единственным источником истины.
///
/// Вид:
/// - ``TesseraTileBadge/dot`` — красный круг без текста (есть новое, число
///   неизвестно);
/// - ``TesseraTileBadge/count(_:)`` — красная капсула с числом; больше 99 показывается
///   как «99+», чтобы бэйдж не растягивал плитку;
/// - ``TesseraTileBadge/none`` — бэйджа нет.
///
/// Бэйдж не является отдельным элементом VoiceOver: озвучивание счётчика —
/// часть плитки (§9, «Плитка — один элемент»). Хост задаёт
/// ``accessibilityText``, если нужно осмысленное описание («3 новых»);
/// по умолчанию плитка озвучивает число.
public final class TesseraLiveTileBadgeView: UIView {

    // MARK: - Метрики

    private enum Metrics {
        static let dotDiameter: CGFloat = 10
        static let minimumHeight: CGFloat = 18
        static let horizontalPadding: CGFloat = 6
        static let labelInset: CGFloat = 4
    }

    // MARK: - Публичные свойства

    /// Текущий бэйдж модели ярлыка (D12). По умолчанию ``TesseraTileBadge/none``.
    ///
    /// `.count(0)` и отрицательные счётчики не показываются — так же, как
    /// ``TesseraTileBadge/isVisible`` в модели.
    public var badge: TesseraTileBadge = .none {
        didSet {
            guard badge != oldValue else { return }
            applyBadge()
        }
    }

    /// Текст бэйджа для VoiceOver.
    ///
    /// Включается в `accessibilityValue` плитки рядом с заголовком стороны
    /// (§9). Пустая строка трактуется как «нет текста». Локализация — забота
    /// хоста: движок не придумывает формулировок.
    public var accessibilityText: String? {
        didSet {
            guard accessibilityText != oldValue else { return }
            onAccessibilityTextChange?()
        }
    }

    /// Внутренние колбэки для ``TesseraLiveTileView``.
    var onBadgeChange: (() -> Void)?
    var onAccessibilityTextChange: (() -> Void)?

    // MARK: - Подпредставления

    private let countLabel = UILabel()

    /// Нормализованный бэйдж: неположительный счётчик — это отсутствие бэйджа.
    private var normalizedBadge: TesseraTileBadge {
        switch badge {
        case .count(let value):
            return value > 0 ? .count(value) : .none
        case .dot, .none:
            return badge
        }
    }

    // MARK: - Инициализация

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func commonInit() {
        // Бэйдж — декоративная деталь: касания и фокус принадлежат плитке.
        isUserInteractionEnabled = false
        isAccessibilityElement = false

        backgroundColor = .systemRed

        countLabel.textColor = .white
        countLabel.textAlignment = .center
        countLabel.numberOfLines = 1
        countLabel.lineBreakMode = .byClipping
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            maximumPointSize: 13
        )
        addSubview(countLabel)

        // §9, Dynamic Type: капсула растёт вместе со шрифтом счётчика.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )

        applyBadge()
    }

    // MARK: - Размер и отрисовка

    public override var intrinsicContentSize: CGSize {
        switch normalizedBadge {
        case .none:
            return .zero
        case .dot:
            return CGSize(width: Metrics.dotDiameter, height: Metrics.dotDiameter)
        case .count:
            let labelSize = countLabel.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            )
            let height = max(Metrics.minimumHeight, ceil(labelSize.height) + 2)
            let width = max(height, ceil(labelSize.width) + Metrics.horizontalPadding * 2)
            return CGSize(width: width, height: height)
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
        countLabel.frame = bounds.insetBy(dx: Metrics.labelInset, dy: 0)
    }

    private func applyBadge() {
        let normalized = normalizedBadge

        switch normalized {
        case .none:
            isHidden = true
            countLabel.text = nil
        case .dot:
            isHidden = false
            countLabel.text = nil
        case .count(let value):
            isHidden = false
            countLabel.text = value > 99 ? "99+" : "\(value)"
        }

        invalidateIntrinsicContentSize()
        setNeedsLayout()
        // Позиция бэйджа считается в layout плитки: размер капсулы изменился.
        superview?.setNeedsLayout()
        onBadgeChange?()
    }

    @objc private func contentSizeCategoryDidChange() {
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }
}

// MARK: - Кеш изображений плитки

/// Кеш изображений сторон, декодированных под размер плитки (§4, «Память»).
///
/// Хост отдаёт иконку «как есть» — нередко 1024×1024 пикселя. Показанная в
/// `UIImageView` 28 pt, она всё равно держит в памяти полный декодированный
/// буфер (~4 МБ), и десяток живых плиток съедает десятки мегабайт. Кеш рисует
/// уменьшенную копию под запрошенный бокс × scale экрана
/// (`UIGraphicsImageRenderer`, iOS 10+) и отдаёт её повторно всем плиткам с
/// той же иконкой и тем же размером.
///
/// Ключ — **идентичность** объекта `UIImage` (не содержимое: сравнивать
/// пиксели дороже, чем рисовать), размер результата в пикселях и режим
/// отрисовки. Исходная картинка в ключе держится слабо: кеш не продлевает
/// жизнь «сырой» иконке, а запись умершей иконки не совпадает ни с одной
/// новой, даже если та заняла тот же адрес памяти.
///
/// Иконка, которая уже помещается в бокс, не перерисовывается: кеш отдаёт её
/// с нужным режимом отрисовки (SF Symbols остаются векторными).
///
/// - Note: Только главный поток — как и вся отрисовка плитки. Рендер
///   выполняется при раскладке стороны (смена размера или контента), а не в
///   горячем пути скролла/флипа: при переиспользовании ячейки с той же
///   иконкой и размером это попадание в кеш.
final class TesseraLiveTileImageCache {

    /// Общий кеш плиток.
    static let shared = TesseraLiveTileImageCache()

    /// Ключ записи: слабая ссылка на исходник + пиксельный размер + режим.
    private final class Key: NSObject {

        weak var source: UIImage?
        let sourceID: ObjectIdentifier
        let pixelWidth: Int
        let pixelHeight: Int
        let renderingMode: Int

        init(source: UIImage, pixelWidth: Int, pixelHeight: Int, renderingMode: UIImage.RenderingMode) {
            self.source = source
            self.sourceID = ObjectIdentifier(source)
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.renderingMode = renderingMode.rawValue
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(sourceID)
            hasher.combine(pixelWidth)
            hasher.combine(pixelHeight)
            hasher.combine(renderingMode)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key,
                  let source,
                  let otherSource = other.source
            else { return false }
            return source === otherSource
                && pixelWidth == other.pixelWidth
                && pixelHeight == other.pixelHeight
                && renderingMode == other.renderingMode
        }
    }

    private let cache = NSCache<Key, UIImage>()

    /// Число фактических перерисовок (промахов кеша с рендером) — для тестов.
    private(set) var renderCount = 0

    /// Создаёт кеш.
    ///
    /// - Parameters:
    ///   - countLimit: Максимум записей; по умолчанию 256.
    ///   - totalCostLimit: Лимит памяти в байтах декодированных буферов; по
    ///     умолчанию 32 МБ.
    init(countLimit: Int = 256, totalCostLimit: Int = 32 * 1024 * 1024) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    /// Изображение, вписанное в `box` с сохранением пропорций.
    ///
    /// - Parameters:
    ///   - source: Исходная иконка.
    ///   - box: Бокс показа в точках.
    ///   - scale: Масштаб экрана; пиксельный размер результата ≤ `box × scale`.
    ///   - renderingMode: Режим отрисовки результата (шаблон для глифа).
    /// - Returns: Уменьшенная копия из кеша или новая; исходник с нужным
    ///   режимом, если он уже помещается в бокс.
    func image(
        for source: UIImage,
        fitting box: CGSize,
        scale: CGFloat,
        renderingMode: UIImage.RenderingMode
    ) -> UIImage {
        let scale = max(1, scale)
        let sourceSize = source.size
        guard sourceSize.width > 0, sourceSize.height > 0, box.width > 0, box.height > 0 else {
            return source.withRenderingMode(renderingMode)
        }

        // Вписываем с сохранением пропорций, не увеличивая исходник.
        let fit = min(box.width / sourceSize.width, box.height / sourceSize.height, 1)
        let targetPoints = CGSize(width: sourceSize.width * fit, height: sourceSize.height * fit)
        let pixelWidth = max(1, Int((targetPoints.width * scale).rounded(.down)))
        let pixelHeight = max(1, Int((targetPoints.height * scale).rounded(.down)))

        let key = Key(source: source, pixelWidth: pixelWidth, pixelHeight: pixelHeight, renderingMode: renderingMode)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let result: UIImage
        let sourcePixelWidth = sourceSize.width * source.scale
        let sourcePixelHeight = sourceSize.height * source.scale
        if sourcePixelWidth <= CGFloat(pixelWidth) + 0.5, sourcePixelHeight <= CGFloat(pixelHeight) + 0.5 {
            // Уже в размер (в том числе векторные символы): не перерисовываем.
            result = source.withRenderingMode(renderingMode)
        } else {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = scale
            format.opaque = false
            let size = CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                source.draw(in: CGRect(origin: .zero, size: size))
            }
            result = rendered.withRenderingMode(renderingMode)
            renderCount += 1
        }

        cache.setObject(result, forKey: key, cost: pixelWidth * pixelHeight * 4)
        return result
    }
}

// MARK: - Сторона плитки

/// Внутреннее представление одной стороны: фон, иконка, заголовок, подпись.
///
/// Сторона не является accessibility-элементом: плитка целиком — один элемент
/// (§9). Раскладка содержимого — обычный layout-проход при смене размера или
/// Dynamic Type; флип её не вызывает.
final class TesseraLiveTileFaceView: UIView {

    private enum Metrics {
        static let minimumInset: CGFloat = 6
        static let maximumInset: CGFloat = 12
        /// Высота, ниже которой плитка считается компактной (1×1).
        static let compactHeight: CGFloat = 96
        /// Высота, начиная с которой показывается подпись бэка.
        static let detailHeight: CGFloat = 112
        /// Минимальный размер, при котором показывается иконка.
        static let iconMinimumSide: CGFloat = 80
    }

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    private(set) var face: TesseraLiveTileFace?

    /// Ширина, которую текст стороны отдаёт бэйджу со стороны конца строки
    /// (D29, E15.1), pt. Бэйдж лежит в нижнем ряду, где прижат текст.
    var badgeTrailingReserve: CGFloat = 0 {
        didSet {
            guard badgeTrailingReserve != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// Высота нижнего ряда, которую текст стороны отдаёт бэйджу, pt: текст
    /// поднимается над рядом бэйджа на узкой плитке (D29, E15.1).
    var badgeBottomReserve: CGFloat = 0 {
        didSet {
            guard badgeBottomReserve != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// Плитка малая (1×1, ``TesseraTileSize/small``), D47. Выставляет контейнер.
    var isSmallTile = false {
        didSet {
            guard isSmallTile != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// Высота нижнего ряда бэйджа с зазором, pt; `0` — бэйджа нет (D47).
    ///
    /// Малая плитка с бэйджем и иконкой стороны показывает иконку и бэйдж без
    /// заголовка и подписи: иконка занимает верхнюю зону над этим рядом
    /// (``TesseraTileBadgeLayout/smallTileIconFrame(tileSize:inset:bottomReserve:)``).
    /// Решение принимается для каждой стороны отдельно: у стороны без иконки
    /// текст остаётся, иначе плитка была бы пустой.
    var badgeIconBottomReserve: CGFloat = 0 {
        didSet {
            guard badgeIconBottomReserve != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// Исходная иконка, уменьшенная копия которой сейчас показана, и её
    /// пиксельный размер: повторная раскладка без изменений кеш не трогает.
    private weak var displayedIconSource: UIImage?
    private var displayedIconPixelSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func commonInit() {
        isAccessibilityElement = false
        clipsToBounds = true
        backgroundColor = .clear

        iconView.contentMode = .scaleAspectFit
        iconView.clipsToBounds = true
        iconView.isAccessibilityElement = false

        titleLabel.numberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textAlignment = .natural
        titleLabel.isAccessibilityElement = false
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: 15, weight: .semibold)
        )

        detailLabel.numberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.textAlignment = .natural
        detailLabel.isAccessibilityElement = false
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
            for: .systemFont(ofSize: 11, weight: .regular)
        )

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(detailLabel)

        // §9, Dynamic Type: ручная раскладка текста должна пересчитаться при
        // смене категории.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
    }

    /// Применяет содержимое стороны; `nil` — сторона пустая и скрывается её
    /// владельцем.
    func apply(_ face: TesseraLiveTileFace?) {
        self.face = face

        guard let face else {
            backgroundColor = .clear
            iconView.image = nil
            iconView.isHidden = true
            displayedIconSource = nil
            displayedIconPixelSize = .zero
            titleLabel.text = nil
            detailLabel.text = nil
            setNeedsLayout()
            return
        }

        backgroundColor = face.backgroundColor

        // Иконки рисуются шаблоном в цвете текста стороны: на плитке нужен
        // одноцветный глиф, а не цветная картинка. Саму картинку ставит
        // раскладка (`layoutFace`): только там известен размер слота, под
        // который иконка декодируется (§4, «Память»).
        iconView.tintColor = face.foregroundColor
        if face.icon !== displayedIconSource {
            iconView.image = nil
            displayedIconSource = nil
            displayedIconPixelSize = .zero
        }

        titleLabel.text = face.title
        titleLabel.textColor = face.foregroundColor

        detailLabel.text = face.detail
        detailLabel.textColor = face.foregroundColor.withAlphaComponent(0.82)

        setNeedsLayout()
    }

    /// Поле плитки по её ширине (общее у стороны и бэйджа, D29, E15.1).
    static func inset(forWidth width: CGFloat) -> CGFloat {
        max(Metrics.minimumInset, min(Metrics.maximumInset, width * 0.08))
    }

    private var isRightToLeftLayout: Bool {
        effectiveUserInterfaceLayoutDirection == .rightToLeft
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutFace()
    }

    private func layoutFace() {
        guard let face else { return }

        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }

        let inset = TesseraLiveTileFaceView.inset(forWidth: width)

        // D47: малая плитка с бэйджем и иконкой — иконка и бэйдж, без текста.
        // Иконка рисуется и на плитке уже 80 pt (обычное правило её скрывает).
        if isSmallTile, badgeIconBottomReserve > 0, let icon = face.icon {
            let frame = TesseraTileBadgeLayout.smallTileIconFrame(
                tileSize: bounds.size,
                inset: inset,
                bottomReserve: badgeIconBottomReserve
            )
            titleLabel.isHidden = true
            detailLabel.isHidden = true
            iconView.isHidden = false
            iconView.frame = frame
            applyIcon(icon, side: frame.width)
            return
        }
        titleLabel.isHidden = false

        // Нижний ряд делит с бэйджем текст: он уже на `badgeTrailingReserve`
        // либо поднят на `badgeBottomReserve` (D29, E15.1).
        let contentWidth = width - 2 * inset - badgeTrailingReserve
        guard contentWidth > 0 else { return }
        let textX = isRightToLeftLayout ? inset + badgeTrailingReserve : inset

        let isRightToLeft = isRightToLeftLayout
        let compact = height < Metrics.compactHeight
        titleLabel.numberOfLines = compact ? 2 : 3
        detailLabel.numberOfLines = compact ? 1 : 2

        let hasDetail = !(face.detail?.isEmpty ?? true) && height >= Metrics.detailHeight
        detailLabel.isHidden = !hasDetail

        let iconSide = min(28, max(18, min(width, height) * 0.2))
        let hasIcon = face.icon != nil
            && width >= Metrics.iconMinimumSide
            && height >= Metrics.iconMinimumSide
        iconView.isHidden = !hasIcon

        var textTop = inset
        if hasIcon, let icon = face.icon {
            let iconX = isRightToLeft ? width - inset - iconSide : inset
            iconView.frame = CGRect(x: iconX, y: inset, width: iconSide, height: iconSide)
            textTop = inset + iconSide + 6
            applyIcon(icon, side: iconSide)
        }

        let availableHeight = max(0, height - textTop - inset - badgeBottomReserve)

        // Подпись резервирует не больше 40% доступной высоты; заголовок
        // забирает остаток и усекается, если места мало (1×1, крупный
        // Dynamic Type — §9).
        let detailHeight: CGFloat
        if hasDetail {
            let measured = detailLabel.sizeThatFits(
                CGSize(width: contentWidth, height: availableHeight)
            )
            detailHeight = min(ceil(measured.height), availableHeight * 0.4)
        } else {
            detailHeight = 0
        }

        let spacing: CGFloat = detailHeight > 0 ? 2 : 0
        let measuredTitle = titleLabel.sizeThatFits(
            CGSize(width: contentWidth, height: availableHeight)
        )
        let titleHeight = min(
            ceil(measuredTitle.height),
            max(0, availableHeight - detailHeight - spacing)
        )

        let blockHeight = titleHeight + spacing + detailHeight
        // Текст прижат к низу, как на WP; если под иконкой не помещается —
        // начинается сразу под ней.
        let blockTop = max(textTop, height - inset - badgeBottomReserve - blockHeight)

        titleLabel.frame = CGRect(
            x: textX,
            y: blockTop,
            width: contentWidth,
            height: titleHeight
        )
        detailLabel.frame = CGRect(
            x: textX,
            y: blockTop + titleHeight + spacing,
            width: contentWidth,
            height: detailHeight
        )
    }

    /// Ставит иконку, декодированную под слот `side × side` × scale (§4).
    ///
    /// Повторный вызов с той же иконкой и тем же пиксельным размером ничего
    /// не делает; иначе картинка берётся из ``TesseraLiveTileImageCache``,
    /// так что одинаковые плитки делят один буфер.
    private func applyIcon(_ icon: UIImage, side: CGFloat) {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
        let pixelSize = CGSize(width: (side * scale).rounded(), height: (side * scale).rounded())
        guard icon !== displayedIconSource || pixelSize != displayedIconPixelSize || iconView.image == nil else {
            return
        }
        iconView.image = TesseraLiveTileImageCache.shared.image(
            for: icon,
            fitting: CGSize(width: side, height: side),
            scale: scale,
            renderingMode: .alwaysTemplate
        )
        displayedIconSource = icon
        displayedIconPixelSize = pixelSize
    }

    @objc private func contentSizeCategoryDidChange() {
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        // §9: в RTL иконка переезжает к правому краю; при смене масштаба
        // экрана иконку нужно декодировать заново — пересчитать раскладку.
        if previousTraitCollection?.layoutDirection != traitCollection.layoutDirection
            || previousTraitCollection?.displayScale != traitCollection.displayScale {
            setNeedsLayout()
        }
    }
}

// MARK: - Контейнер плитки

/// Контейнер живой плитки с двумя сторонами и бэйджем (§4).
///
/// ## Флип
///
/// Стороны лежат друг на друге. Флип — две фазы по половине
/// ``flipAnimationDuration``:
/// 1. уходящая сторона поворачивается вокруг оси Y на 90° с перспективой
///    (`m34 ≈ −1/500`) и прячется;
/// 2. приходящая сторона появляется повёрнутой на −90° и доворачивается до 0°.
///
/// Подмена стороны происходит в момент, когда обе стороны повёрнуты ребром,
/// поэтому зеркального текста не видно. Меняются только `layer.transform` и
/// `isHidden`; `frame`/`bounds`/`layout` не трогаются — это и есть дисциплина
/// §4 и RISK.md R10.
///
/// ## Reduce Motion (§9)
///
/// View не знает о настройке: политику «флипов нет, статичный фронт» держит
/// ``TesseraLiveTileEngine``. Если вызвать ``show(_:animated:)`` с
/// `animated: false`, сторона меняется мгновенно без анимации.
///
/// ## Бэйдж (§4, D15)
///
/// ``badgeView`` — отдельный слой поверх обеих сторон: он не входит в
/// анимируемые стороны и не переворачивается. Хост задаёт вид через
/// ``badge``/``badgeView``. Для VoiceOver счётчик включается в значение
/// плитки (``badgeAccessibilityText``).
///
/// ## Потоки
///
/// Только главный поток: UIView и Core Animation.
///
/// - Note: Контейнер не содержит действия ярлыка (D12): тап обрабатывает
///   ячейка/хост, а не движок. Контейнер — один accessibility-элемент с
///   признаком кнопки (§9).
public final class TesseraLiveTileView: UIView {

    /// Сторона плитки.
    public enum Side: Equatable {

        /// Фронт: иконка/заголовок плитки.
        case front

        /// Бэк: живой контент.
        case back
    }

    // MARK: - Публичные свойства

    /// Устоявшаяся сторона: сторона, которая видна, когда флип не идёт.
    ///
    /// Во время анимации значение меняется только по её завершении; отмена
    /// флипа возвращает прежнюю сторону (``cancelFlip()``).
    public private(set) var side: Side = .front

    /// Идёт ли сейчас анимация флипа.
    ///
    /// Движок использует это свойство, чтобы не накладывать флипы друг на
    /// друга.
    public private(set) var isFlipping = false

    /// Длительность полного флипа (обе половины), секунды.
    ///
    /// По умолчанию 0.45 с. Движок выставляет значение из
    /// ``TesseraLiveTileEngine/Configuration/flipDuration`` при регистрации.
    /// Значения `<= 0` трактуются как «без анимации»: сторона меняется
    /// мгновенно.
    public var flipAnimationDuration: TimeInterval = 0.45

    /// Бэйдж поверх плитки; не часть флипа (§4).
    ///
    /// View создаётся контейнером и позиционируется в нижнем углу у конца строки
    /// (D29, E15.1; ``TesseraTileBadgeLayout``) с учётом направления чтения (§9,
    /// RTL): в LTR — справа, в RTL — слева.
    public let badgeView = TesseraLiveTileBadgeView()

    /// Сколько нижнего угла у конца строки занимает стрелка размера режима
    /// редактирования, pt; `0` — вне правки (D29, E15.1). Бэйдж обходит её;
    /// выставляет ячейка сетки.
    var badgeEditClearance: CGFloat = 0 {
        didSet {
            guard badgeEditClearance != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// Плитка малая (1×1, ``TesseraTileSize/small``), D47: сторона с иконкой и бэйджем
    /// показывает их без текста. Выставляет ячейка сетки по модели ярлыка; у
    /// самостоятельного контейнера вне сетки `false` — раскладка прежняя.
    var isSmallTile = false {
        didSet {
            guard isSmallTile != oldValue else { return }
            for face in [frontView, backView] {
                face.isSmallTile = isSmallTile
            }
            setNeedsLayout()
        }
    }

    /// Бэйдж ярлыка (D12/D15): красная точка или счётчик.
    ///
    /// Хост передаёт ``TesseraTileDescriptor/badge`` напрямую; бэйдж не участвует во
    /// флипе и живёт поверх обеих сторон (§4).
    public var badge: TesseraTileBadge {
        get { badgeView.badge }
        set { badgeView.badge = newValue }
    }

    /// Текст бэйджа для VoiceOver; `nil` — озвучивается число из счётчика.
    public var badgeAccessibilityText: String? {
        get { badgeView.accessibilityText }
        set { badgeView.accessibilityText = newValue }
    }

    /// Действие ярлыка по активации VoiceOver (D12).
    ///
    /// Тап пальцем обрабатывает хост (ячейка сетки), но VoiceOver активирует
    /// сам accessibility-элемент плитки, минуя ячейку. Хост передаёт сюда
    /// ``TesseraTileDescriptor/action``; если действие не задано, плитка остаётся
    /// статичным элементом, несмотря на признак кнопки.
    public var onActivate: (() -> Void)?

    // MARK: - Внутреннее состояние

    private let frontView = TesseraLiveTileFaceView()
    private let backView = TesseraLiveTileFaceView()

    private var frontFace: TesseraLiveTileFace?
    private var backFace: TesseraLiveTileFace?

    /// Поколение анимации: отменённые и устаревшие completion-блоки
    /// игнорируются.
    private var flipGeneration: UInt64 = 0
    private var flipCompletion: (() -> Void)?

    private enum AnimationKey {
        static let outgoing = "tessera.liveTile.flip.outgoing"
        static let incoming = "tessera.liveTile.flip.incoming"
    }

    /// Расстояние до точки схода перспективы. `m34 = −1/500` — классическое
    /// значение для флипа плитки: заметная глубина без «рыбьего глаза».
    private static let perspectiveDistance: CGFloat = 500

    // MARK: - Инициализация

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        clipsToBounds = true
        backgroundColor = .secondarySystemBackground

        // §9: плитка — один элемент, действия ярлыка озвучиваются признаком
        // кнопки. Подписи сторон отдельными элементами не являются.
        isAccessibilityElement = true
        accessibilityTraits = .button

        frontView.isHidden = false
        backView.isHidden = true
        addSubview(frontView)
        addSubview(backView)
        addSubview(badgeView)

        badgeView.onBadgeChange = { [weak self] in
            self?.updateAccessibility()
        }
        badgeView.onAccessibilityTextChange = { [weak self] in
            self?.updateAccessibility()
        }

        updateAccessibility()
    }

    // MARK: - Контент

    /// Заменяет содержимое обеих сторон.
    ///
    /// Фронт обязателен; бэк `nil` означает «у плитки нет обратной стороны».
    /// Если бэк исчез, пока он был показан (или показывался), плитка
    /// возвращается на фронт без анимации — состояние не застревает между
    /// сторонами.
    ///
    /// - Parameters:
    ///   - front: Содержимое фронта.
    ///   - back: Содержимое бэка либо `nil`.
    public func setFaces(front: TesseraLiveTileFace, back: TesseraLiveTileFace?) {
        frontFace = front
        backFace = back

        frontView.apply(front)
        backView.apply(back)

        if back == nil {
            if isFlipping {
                cancelFlip()
            }
            if side == .back {
                settle(on: .front)
            }
        }

        updateAccessibility()
        setNeedsLayout()
    }

    /// Содержимое стороны; `nil` — сторона не задана.
    ///
    /// - Parameter side: Запрошенная сторона.
    /// - Returns: Содержимое стороны либо `nil`.
    public func face(for side: Side) -> TesseraLiveTileFace? {
        side == .front ? frontFace : backFace
    }

    // MARK: - Флип

    /// Показывает сторону `target` (§4).
    ///
    /// - Parameters:
    ///   - target: Сторона, которая должна стать видимой. Если бэка нет,
    ///     запрос на `.back` игнорируется.
    ///   - animated: `true` — флип с перспективой; `false` — мгновенная
    ///     подмена (Reduce Motion, §9).
    ///   - completion: Вызывается после завершения флипа или сразу, если
    ///     показывать нечего. При отмене (``cancelFlip()``,
    ///     ``setFaces(front:back:)`` без бэка) не вызывается.
    public func show(_ target: Side, animated: Bool, completion: (() -> Void)? = nil) {
        guard target != .back || backFace != nil else {
            completion?()
            return
        }

        guard animated, flipAnimationDuration > 0 else {
            settle(on: target)
            completion?()
            return
        }

        if isFlipping {
            // Незавершённый флип доводим до устоявшейся стороны без
            // анимации: иначе половина новой анимации наложится на старую.
            cancelFlip()
        }

        guard target != side else {
            completion?()
            return
        }

        isFlipping = true
        flipCompletion = completion
        flipGeneration &+= 1
        let generation = flipGeneration

        let outgoing = faceView(for: side)
        let incoming = faceView(for: target)
        incoming.isHidden = true

        let halfDuration = max(0.05, min(flipAnimationDuration, 3) / 2)
        let halfOut = Self.perspectiveRotation(by: .pi / 2)
        let halfIn = Self.perspectiveRotation(by: -.pi / 2)

        // Фаза 1: уходящая сторона уходит в ребро (+90°).
        let outgoingAnimation = CABasicAnimation(keyPath: "transform")
        outgoingAnimation.fromValue = NSValue(caTransform3D: Self.perspectiveRotation(by: 0))
        outgoingAnimation.toValue = NSValue(caTransform3D: halfOut)
        outgoingAnimation.duration = halfDuration
        outgoingAnimation.timingFunction = CAMediaTimingFunction(name: .easeIn)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self,
                  self.flipGeneration == generation,
                  self.isFlipping
            else { return }
            self.beginIncomingFlip(
                incoming: incoming,
                outgoing: outgoing,
                target: target,
                initialTransform: halfIn,
                duration: halfDuration,
                generation: generation
            )
        }
        outgoing.layer.add(outgoingAnimation, forKey: AnimationKey.outgoing)
        outgoing.layer.transform = halfOut
        CATransaction.commit()
    }

    /// Отменяет текущий флип и возвращает устоявшуюся сторону без анимации.
    ///
    /// Используется паузами §4 (плитка ушла с экрана, приложение в фон,
    /// Reduce Motion) и переиспользованием ячейки.
    public func cancelFlip() {
        flipGeneration &+= 1
        isFlipping = false
        flipCompletion = nil
        resetTransforms()
    }

    // MARK: - Фазы анимации

    private func beginIncomingFlip(
        incoming: UIView,
        outgoing: UIView,
        target: Side,
        initialTransform: CATransform3D,
        duration: TimeInterval,
        generation: UInt64
    ) {
        // Момент подмены: обе стороны повёрнуты ребром, поэтому смена
        // видимости незаметна. Layout не меняется — только hidden/transform.
        outgoing.isHidden = true
        outgoing.layer.transform = CATransform3DIdentity

        incoming.isHidden = false
        incoming.layer.transform = initialTransform

        // Фаза 2: доворот приходящей стороны от −90° к 0°.
        let incomingAnimation = CABasicAnimation(keyPath: "transform")
        incomingAnimation.fromValue = NSValue(caTransform3D: initialTransform)
        incomingAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        incomingAnimation.duration = duration
        incomingAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.flipGeneration == generation else { return }
            self.finishFlip(on: target)
        }
        incoming.layer.add(incomingAnimation, forKey: AnimationKey.incoming)
        incoming.layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func finishFlip(on target: Side) {
        isFlipping = false
        side = target

        frontView.layer.removeAllAnimations()
        backView.layer.removeAllAnimations()
        frontView.layer.transform = CATransform3DIdentity
        backView.layer.transform = CATransform3DIdentity
        frontView.isHidden = side != .front
        backView.isHidden = side != .back

        updateAccessibility()

        let completion = flipCompletion
        flipCompletion = nil
        completion?()
    }

    /// Мгновенно приводит плитку к стороне `target`.
    private func settle(on target: Side) {
        flipGeneration &+= 1
        isFlipping = false
        flipCompletion = nil
        side = target
        resetTransforms()
    }

    /// Возвращает обе стороны к устоявшейся стороне без анимации.
    private func resetTransforms() {
        for faceSide in [Side.front, .back] {
            let view = faceView(for: faceSide)
            view.layer.removeAllAnimations()
            view.layer.transform = CATransform3DIdentity
            view.isHidden = faceSide != side
        }
        updateAccessibility()
    }

    private func faceView(for side: Side) -> UIView {
        side == .front ? frontView : backView
    }

    /// `CATransform3D` поворота вокруг оси Y с перспективой (§4).
    ///
    /// `m34` — перспективный член матрицы: без него поворот выглядит плоским
    /// масштабированием, с ним дальняя сторона плитки уходит в глубину.
    private static func perspectiveRotation(by angle: CGFloat) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / perspectiveDistance
        return CATransform3DRotate(transform, angle, 0, 1, 0)
    }

    // MARK: - Layout и доступность

    public override func layoutSubviews() {
        super.layoutSubviews()

        // Посреди флипа у стороны неединичный 3D-`layer.transform`, а `frame`
        // при неединичном трансформе не определён (документация UIView):
        // присваивание `frame` даёт значение, зависящее от реализации UIKit.
        // Геометрию сторон задаём через `bounds` + `center` — они от
        // трансформа не зависят, и флип продолжается с той же фазы.
        let faceBounds = CGRect(origin: .zero, size: bounds.size)
        let faceCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        for face in [frontView, backView] {
            if face.bounds != faceBounds {
                face.bounds = faceBounds
            }
            if face.center != faceCenter {
                face.center = faceCenter
            }
        }

        // Бэйдж не участвует во флипе и позиционируется отдельно: в нижнем
        // углу у конца строки (D29, E15.1) — правом в LTR и левом в RTL; в
        // правке он обходит стрелку размера. Текст сторон уступает ему место.
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let badgeLayout = TesseraTileBadgeLayout.make(
            tileSize: bounds.size,
            badgeSize: badgeView.intrinsicContentSize,
            inset: TesseraLiveTileFaceView.inset(forWidth: bounds.width),
            isRightToLeft: isRightToLeft,
            editClearance: badgeEditClearance
        )
        badgeView.frame = badgeLayout.frame
        badgeView.alpha = badgeLayout.isHiddenByEditControls ? 0 : 1
        for face in [frontView, backView] {
            face.badgeTrailingReserve = badgeLayout.titleTrailingReserve
            face.badgeBottomReserve = badgeLayout.titleBottomReserve
            face.badgeIconBottomReserve = badgeLayout.iconBottomReserve
        }
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if previousTraitCollection?.layoutDirection != traitCollection.layoutDirection {
            setNeedsLayout()
        }
    }

    /// §9: плитка — один элемент; заголовок стороны и счётчик бэйджа —
    /// его label и value.
    private func updateAccessibility() {
        let visibleFace = side == .front ? frontFace : (backFace ?? frontFace)

        guard let visibleFace else {
            accessibilityLabel = nil
            accessibilityValue = nil
            return
        }

        var label = visibleFace.title
        if let detail = visibleFace.detail, !detail.isEmpty {
            label += ", " + detail
        }
        accessibilityLabel = label

        if let badgeText = badgeView.accessibilityText, !badgeText.isEmpty {
            accessibilityValue = badgeText
        } else {
            // D34/E15.4: без текста хоста точка озвучивается строкой модуля.
            accessibilityValue = badgeView.badge.accessibilityValueText
        }
    }

    /// VoiceOver-активация ярлыка (D12): жест двойного тапа приходит сюда, а
    /// не в ячейку сетки, потому что плитка — самостоятельный элемент (§9).
    public override func accessibilityActivate() -> Bool {
        guard let onActivate else { return super.accessibilityActivate() }
        onActivate()
        return true
    }
}

#endif
