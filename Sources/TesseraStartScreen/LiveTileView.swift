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
/// Содержимое берётся напрямую из модели ярлыка ``TileBadge`` (D12): это
/// ровно те же три состояния, что хранит `TileDescriptor.badge`, поэтому
/// преобразование не нужно и модель остаётся единственным источником истины.
///
/// Вид:
/// - ``TileBadge/dot`` — красный круг без текста (есть новое, число
///   неизвестно);
/// - ``TileBadge/count(_:)`` — красная капсула с числом; больше 99 показывается
///   как «99+», чтобы бэйдж не растягивал плитку;
/// - ``TileBadge/none`` — бэйджа нет.
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

    /// Текущий бэйдж модели ярлыка (D12). По умолчанию ``TileBadge/none``.
    ///
    /// `.count(0)` и отрицательные счётчики не показываются — так же, как
    /// ``TileBadge/isVisible`` в модели.
    public var badge: TileBadge = .none {
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
    private var normalizedBadge: TileBadge {
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
            titleLabel.text = nil
            detailLabel.text = nil
            setNeedsLayout()
            return
        }

        backgroundColor = face.backgroundColor

        // Иконки рисуются шаблоном в цвете текста стороны: на плитке нужен
        // одноцветный глиф, а не цветная картинка.
        if let icon = face.icon {
            iconView.image = icon.withRenderingMode(.alwaysTemplate)
            iconView.tintColor = face.foregroundColor
        } else {
            iconView.image = nil
        }

        titleLabel.text = face.title
        titleLabel.textColor = face.foregroundColor

        detailLabel.text = face.detail
        detailLabel.textColor = face.foregroundColor.withAlphaComponent(0.82)

        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutFace()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        // §9: в RTL иконка переезжает к правому краю — пересчитать раскладку.
        if previousTraitCollection?.layoutDirection != traitCollection.layoutDirection {
            setNeedsLayout()
        }
    }

    private func layoutFace() {
        guard let face else { return }

        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }

        let inset = max(Metrics.minimumInset, min(Metrics.maximumInset, width * 0.08))
        let contentWidth = width - 2 * inset
        guard contentWidth > 0 else { return }

        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
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
        if hasIcon {
            let iconX = isRightToLeft ? width - inset - iconSide : inset
            iconView.frame = CGRect(x: iconX, y: inset, width: iconSide, height: iconSide)
            textTop = inset + iconSide + 6
        }

        let availableHeight = max(0, height - textTop - inset)

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
        let blockTop = max(textTop, height - inset - blockHeight)

        titleLabel.frame = CGRect(
            x: inset,
            y: blockTop,
            width: contentWidth,
            height: titleHeight
        )
        detailLabel.frame = CGRect(
            x: inset,
            y: blockTop + titleHeight + spacing,
            width: contentWidth,
            height: detailHeight
        )
    }

    @objc private func contentSizeCategoryDidChange() {
        setNeedsLayout()
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
    /// View создаётся контейнером и позиционируется в верхнем углу с учётом
    /// направления чтения (§9, RTL): в LTR — справа, в RTL — слева.
    public let badgeView = TesseraLiveTileBadgeView()

    /// Бэйдж ярлыка (D12/D15): красная точка или счётчик.
    ///
    /// Хост передаёт ``TileDescriptor/badge`` напрямую; бэйдж не участвует во
    /// флипе и живёт поверх обеих сторон (§4).
    public var badge: TileBadge {
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
    /// ``TileDescriptor/action``; если действие не задано, плитка остаётся
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

        frontView.frame = bounds
        backView.frame = bounds

        // Бэйдж не участвует во флипе и позиционируется отдельно. В RTL
        // верхний угол зеркалится (§9): WP-бэйдж живёт в правом верхнем углу
        // LTR-интерфейса.
        let badgeSize = badgeView.intrinsicContentSize
        let inset: CGFloat = 6
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let badgeX = isRightToLeft ? inset : bounds.width - inset - badgeSize.width
        badgeView.frame = CGRect(x: badgeX, y: inset, width: badgeSize.width, height: badgeSize.height)
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
            switch badgeView.badge {
            case .count(let value) where value > 0:
                accessibilityValue = String(value)
            case .none, .dot, .count:
                accessibilityValue = nil
            }
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
