//
//  LiveTileView.swift
//  TesseraStartScreen
//
//  The live tile container: two faces and an independent badge.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md, §4 (live tiles, the engine: the flip is a
//  `CATransform3D` with `m34` perspective, a 90° rotation around Y, a face swap and a rotation to
//  completion; transforms only, no layout; the badge is a separate view, not part of the flip), §9
//  (Accessibility: VoiceOver, Dynamic Type, RTL) and §10 (MVP: flipping simple text tiles).
//  Clarifications: D12 and D15 in docs/STATE.md.
//
//  Performance discipline (§4, RISK.md R10): the flip does not change `frame` or `bounds` and does
//  not trigger layout; only `layer.transform` and `isHidden` at the moment of the face swap. Text
//  and colors change off the hot path: on registration, on content updates and on a face change.
//

#if canImport(UIKit)
import UIKit

// MARK: - Badge

/// The live tile badge: a red dot or an attention counter (§4, "Badge"; D12/D15, the shortcut
/// badge).
///
/// A separate view over the tile container, **not part of the flip**: when the tile flips, the badge
/// stays in place and does not rotate with the face (§4). Its content comes directly from the
/// shortcut model ``TesseraTileBadge`` (D12): these are exactly the same three states that
/// `TesseraTileDescriptor.badge` stores, so no conversion is needed and the model stays the single
/// source of truth.
///
/// Appearance:
/// - ``TesseraTileBadge/dot`` is a red circle without text (there is something new, the number is
///   unknown);
/// - ``TesseraTileBadge/count(_:)`` is a red capsule with a number; values above 99 are shown as
///   "99+" so that the badge does not stretch the tile;
/// - ``TesseraTileBadge/none`` means no badge.
///
/// The badge is not a separate VoiceOver element: announcing the counter is part of the tile (§9,
/// "a tile is a single element"). The host sets ``accessibilityText`` if a meaningful description
/// is needed (for example, "3 new"); by default the tile announces the number.
public final class TesseraLiveTileBadgeView: UIView {

    // MARK: - Metrics

    private enum Metrics {
        static let dotDiameter: CGFloat = 10
        static let minimumHeight: CGFloat = 18
        static let horizontalPadding: CGFloat = 6
        static let labelInset: CGFloat = 4
    }

    // MARK: - Public properties

    /// The current badge of the shortcut model (D12). ``TesseraTileBadge/none`` by default.
    ///
    /// `.count(0)` and negative counters are not shown, the same as
    /// ``TesseraTileBadge/isVisible`` in the model.
    public var badge: TesseraTileBadge = .none {
        didSet {
            guard badge != oldValue else { return }
            applyBadge()
        }
    }

    /// The badge text for VoiceOver.
    ///
    /// Included in the tile's `accessibilityValue` next to the face title (§9). An empty string is
    /// treated as "no text". Localization is the host's concern: the engine does not invent wording.
    public var accessibilityText: String? {
        didSet {
            guard accessibilityText != oldValue else { return }
            onAccessibilityTextChange?()
        }
    }

    /// Internal callbacks for ``TesseraLiveTileView``.
    var onBadgeChange: (() -> Void)?
    var onAccessibilityTextChange: (() -> Void)?

    // MARK: - Subviews

    private let countLabel = UILabel()

    /// The normalized badge: a non-positive counter means no badge.
    private var normalizedBadge: TesseraTileBadge {
        switch badge {
        case .count(let value):
            return value > 0 ? .count(value) : .none
        case .dot, .none:
            return badge
        }
    }

    // MARK: - Initialization

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
        // The badge is a decorative detail: touches and focus belong to the tile.
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

        // §9, Dynamic Type: the capsule grows with the counter font.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )

        applyBadge()
    }

    // MARK: - Size and drawing

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
        // The badge position is computed in the tile layout: the capsule size changed.
        superview?.setNeedsLayout()
        onBadgeChange?()
    }

    @objc private func contentSizeCategoryDidChange() {
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }
}

// MARK: - Tile image cache

/// A cache of face images decoded to the tile size (§4, "Memory").
///
/// The host passes an icon as is, often 1024×1024 pixels. Shown in a 28 pt `UIImageView`, it still
/// holds the full decoded buffer in memory (about 4 MB), and a dozen live tiles eat tens of
/// megabytes. The cache draws a downscaled copy for the requested box times the screen scale
/// (`UIGraphicsImageRenderer`, iOS 10+) and hands it out again to all tiles with the same icon and
/// the same size.
///
/// The key is the **identity** of the `UIImage` object (not its content: comparing pixels is more
/// expensive than drawing), the result size in pixels and the rendering mode. The source image is
/// held weakly in the key: the cache does not extend the life of the "raw" icon, and an entry of a
/// dead icon does not match any new one, even if that one took the same memory address.
///
/// An icon that already fits the box is not redrawn: the cache returns it with the required
/// rendering mode (SF Symbols stay vector).
///
/// - Note: Main thread only, like all tile drawing. Rendering happens during face layout (a size or
///   content change), not on the scroll/flip hot path: when a cell is reused with the same icon and
///   size, it is a cache hit.
final class TesseraLiveTileImageCache {

    /// The shared tile cache.
    static let shared = TesseraLiveTileImageCache()

    /// An entry key: a weak reference to the source + the pixel size + the mode.
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

    /// The number of actual redraws (cache misses with a render), for tests.
    private(set) var renderCount = 0

    /// Creates a cache.
    ///
    /// - Parameters:
    ///   - countLimit: The maximum number of entries; 256 by default.
    ///   - totalCostLimit: The memory limit in bytes of decoded buffers; 32 MB by default.
    init(countLimit: Int = 256, totalCostLimit: Int = 32 * 1024 * 1024) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    /// An image fitted into `box` with the aspect ratio preserved.
    ///
    /// - Parameters:
    ///   - source: The source icon.
    ///   - box: The display box in points.
    ///   - scale: The screen scale; the result's pixel size is at most `box × scale`.
    ///   - renderingMode: The rendering mode of the result (template for a glyph).
    /// - Returns: A downscaled copy from the cache or a new one; the source with the required mode
    ///   if it already fits the box.
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

        // Fit with the aspect ratio preserved, without enlarging the source.
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
            // Already the right size (including vector symbols): do not redraw.
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

// MARK: - Tile face

/// The internal view of a single face: background, icon, title, caption.
///
/// A face is not an accessibility element: the whole tile is a single element (§9). Content layout
/// is an ordinary layout pass on a size or Dynamic Type change; the flip does not trigger it.
final class TesseraLiveTileFaceView: UIView {

    private enum Metrics {
        static let minimumInset: CGFloat = 6
        static let maximumInset: CGFloat = 12
        /// The height below which a tile counts as compact (1×1).
        static let compactHeight: CGFloat = 96
        /// The height from which the back caption is shown.
        static let detailHeight: CGFloat = 112
        /// The minimum size at which the icon is shown.
        static let iconMinimumSide: CGFloat = 80
    }

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    private(set) var face: TesseraLiveTileFace?

    /// The width the face text yields to the badge on the trailing side (D29), in pt. The badge sits
    /// in the bottom row, where the text is pressed.
    var badgeTrailingReserve: CGFloat = 0 {
        didSet {
            guard badgeTrailingReserve != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// The height of the bottom row that the face text yields to the badge, in pt: on a narrow tile
    /// the text rises above the badge row (D29).
    var badgeBottomReserve: CGFloat = 0 {
        didSet {
            guard badgeBottomReserve != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// Whether the tile is small (1×1, ``TesseraTileSize/small``), D47. Set by the container.
    var isSmallTile = false {
        didSet {
            guard isSmallTile != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// The height of the badge's bottom row including the gap, in pt; `0` means no badge (D47).
    ///
    /// A small tile with a badge and a face icon shows the icon and the badge without a title and
    /// caption: the icon takes the top zone above this row
    /// (``TesseraTileBadgeLayout/smallTileIconFrame(tileSize:inset:bottomReserve:)``). The decision
    /// is made per face: a face without an icon keeps its text, otherwise the tile would be empty.
    var badgeIconBottomReserve: CGFloat = 0 {
        didSet {
            guard badgeIconBottomReserve != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// The source icon whose downscaled copy is currently shown, and its pixel size: a repeated
    /// layout without changes does not touch the cache.
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

        // §9, Dynamic Type: the manual text layout must be recomputed when the category changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
    }

    /// Applies the face content; `nil` means the face is empty and its owner hides it.
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

        // Icons are drawn as a template in the face's text color: a tile needs a single-color glyph,
        // not a colored picture. The image itself is set by the layout (`layoutFace`): only there is
        // the slot size known that the icon is decoded for (§4, "Memory").
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

    /// The tile inset for its width (shared by the face and the badge, D29).
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

        // D47: a small tile with a badge and an icon shows the icon and the badge, without text.
        // The icon is drawn even on a tile narrower than 80 pt (the usual rule hides it).
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

        // The bottom row is shared with the badge: the text is narrower by `badgeTrailingReserve`
        // or raised by `badgeBottomReserve` (D29).
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

        // The caption reserves at most 40% of the available height; the title takes the rest and is
        // truncated if there is little room (1×1, large Dynamic Type; §9).
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
        // The text is pressed to the bottom, as in Windows Phone; if it does not fit under the icon,
        // it starts right below it.
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

    /// Sets the icon decoded for a `side × side` slot times the scale (§4).
    ///
    /// A repeated call with the same icon and the same pixel size does nothing; otherwise the image
    /// is taken from ``TesseraLiveTileImageCache``, so identical tiles share one buffer.
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

        // §9: in RTL the icon moves to the right edge; when the screen scale changes, the icon must
        // be decoded again, so the layout is recomputed.
        if previousTraitCollection?.layoutDirection != traitCollection.layoutDirection
            || previousTraitCollection?.displayScale != traitCollection.displayScale {
            setNeedsLayout()
        }
    }
}

// MARK: - Tile container

/// A live tile container with two faces and a badge (§4).
///
/// ## Flip
///
/// The faces lie on top of each other. The flip has two phases of half of
/// ``flipAnimationDuration`` each:
/// 1. the outgoing face rotates around the Y axis by 90° with perspective (`m34 ≈ −1/500`) and
///    hides;
/// 2. the incoming face appears rotated by −90° and rotates to completion up to 0°.
///
/// The faces are swapped at the moment both are edge-on, so no mirrored text is visible. Only
/// `layer.transform` and `isHidden` change; `frame`/`bounds`/layout are not touched, which is the
/// discipline of §4 and RISK.md R10.
///
/// ## Reduce Motion (§9)
///
/// The view does not know about the setting: the "no flips, a static front" policy is held by
/// ``TesseraLiveTileEngine``. If ``show(_:animated:)`` is called with `animated: false`, the face
/// changes instantly without animation.
///
/// ## Badge (§4, D15)
///
/// ``badgeView`` is a separate layer over both faces: it is not part of the animated faces and does
/// not flip. The host sets its appearance through ``badge``/``badgeView``. For VoiceOver the counter
/// is included in the tile's value (``badgeAccessibilityText``).
///
/// ## Threading
///
/// Main thread only: UIView and Core Animation.
///
/// - Note: The container holds no shortcut action (D12): the tap is handled by the cell/host, not by
///   the engine. The container is a single accessibility element with the button trait (§9).
public final class TesseraLiveTileView: UIView {

    /// A side of the tile.
    public enum Side: Equatable {

        /// The front: the tile icon/title.
        case front

        /// The back: the live content.
        case back
    }

    // MARK: - Public properties

    /// The settled side: the side that is visible when no flip is running.
    ///
    /// During an animation the value changes only when it completes; cancelling the flip restores
    /// the previous side (``cancelFlip()``).
    public private(set) var side: Side = .front

    /// Whether a flip animation is running.
    ///
    /// The engine uses this property to avoid overlapping flips.
    public private(set) var isFlipping = false

    /// The duration of a full flip (both halves), in seconds.
    ///
    /// 0.45 s by default. The engine sets the value from
    /// ``TesseraLiveTileEngine/Configuration/flipDuration`` on registration. Values `<= 0` mean "no
    /// animation": the side changes instantly.
    public var flipAnimationDuration: TimeInterval = 0.45

    /// The badge over the tile; not part of the flip (§4).
    ///
    /// The view is created by the container and positioned in the bottom corner at the trailing end
    /// (D29; ``TesseraTileBadgeLayout``) taking the reading direction into account (§9, RTL): on the
    /// right in LTR, on the left in RTL.
    public let badgeView = TesseraLiveTileBadgeView()

    /// How much of the bottom trailing corner the edit-mode resize arrow takes, in pt; `0` outside
    /// edit mode (D29). The badge avoids it; set by the grid cell.
    var badgeEditClearance: CGFloat = 0 {
        didSet {
            guard badgeEditClearance != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// Whether the tile is small (1×1, ``TesseraTileSize/small``), D47: a face with an icon and a
    /// badge shows them without text. Set by the grid cell from the shortcut model; for a standalone
    /// container outside a grid it is `false` and the layout is unchanged.
    var isSmallTile = false {
        didSet {
            guard isSmallTile != oldValue else { return }
            for face in [frontView, backView] {
                face.isSmallTile = isSmallTile
            }
            setNeedsLayout()
        }
    }

    /// The shortcut badge (D12/D15): a red dot or a counter.
    ///
    /// The host passes ``TesseraTileDescriptor/badge`` directly; the badge does not take part in the
    /// flip and lives over both faces (§4).
    public var badge: TesseraTileBadge {
        get { badgeView.badge }
        set { badgeView.badge = newValue }
    }

    /// The badge text for VoiceOver; `nil` means the counter number is announced.
    public var badgeAccessibilityText: String? {
        get { badgeView.accessibilityText }
        set { badgeView.accessibilityText = newValue }
    }

    /// The shortcut action on VoiceOver activation (D12).
    ///
    /// A finger tap is handled by the host (the grid cell), but VoiceOver activates the tile's
    /// accessibility element itself, bypassing the cell. The host passes
    /// ``TesseraTileDescriptor/action`` here; if no action is set, the tile stays a static element
    /// despite the button trait.
    public var onActivate: (() -> Void)?

    // MARK: - Internal state

    private let frontView = TesseraLiveTileFaceView()
    private let backView = TesseraLiveTileFaceView()

    private var frontFace: TesseraLiveTileFace?
    private var backFace: TesseraLiveTileFace?

    /// The animation generation: cancelled and stale completion blocks are ignored.
    private var flipGeneration: UInt64 = 0
    private var flipCompletion: (() -> Void)?

    private enum AnimationKey {
        static let outgoing = "tessera.liveTile.flip.outgoing"
        static let incoming = "tessera.liveTile.flip.incoming"
    }

    /// The distance to the perspective vanishing point. `m34 = −1/500` is the classic value for a
    /// tile flip: noticeable depth without a "fisheye".
    private static let perspectiveDistance: CGFloat = 500

    // MARK: - Initialization

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

        // §9: a tile is a single element, and shortcut actions are announced by the button trait.
        // The face captions are not separate elements.
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

    // MARK: - Content

    /// Replaces the content of both faces.
    ///
    /// The front is required; a `nil` back means "the tile has no back side". If the back disappears
    /// while it is shown (or being shown), the tile returns to the front without animation, so the
    /// state does not get stuck between faces.
    ///
    /// - Parameters:
    ///   - front: The front content.
    ///   - back: The back content, or `nil`.
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

    /// The content of a side; `nil` means the side is not set.
    ///
    /// - Parameter side: The requested side.
    /// - Returns: The side content, or `nil`.
    public func face(for side: Side) -> TesseraLiveTileFace? {
        side == .front ? frontFace : backFace
    }

    // MARK: - Flip

    /// Shows the `target` side (§4).
    ///
    /// - Parameters:
    ///   - target: The side that should become visible. If there is no back, a request for `.back`
    ///     is ignored.
    ///   - animated: `true` for a flip with perspective; `false` for an instant swap (Reduce Motion,
    ///     §9).
    ///   - completion: Called when the flip finishes, or immediately if there is nothing to show.
    ///     Not called on cancellation (``cancelFlip()``, ``setFaces(front:back:)`` without a back).
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
            // An unfinished flip is brought to the settled side without animation: otherwise half of
            // the new animation would overlap the old one.
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

        // Phase 1: the outgoing side goes edge-on (+90°).
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

    /// Cancels the current flip and returns the settled side without animation.
    ///
    /// Used by the §4 pauses (the tile left the screen, the app went to the background, Reduce
    /// Motion) and by cell reuse.
    public func cancelFlip() {
        flipGeneration &+= 1
        isFlipping = false
        flipCompletion = nil
        resetTransforms()
    }

    // MARK: - Animation phases

    private func beginIncomingFlip(
        incoming: UIView,
        outgoing: UIView,
        target: Side,
        initialTransform: CATransform3D,
        duration: TimeInterval,
        generation: UInt64
    ) {
        // The swap moment: both sides are edge-on, so the visibility change is unnoticeable. Layout
        // does not change, only hidden/transform.
        outgoing.isHidden = true
        outgoing.layer.transform = CATransform3DIdentity

        incoming.isHidden = false
        incoming.layer.transform = initialTransform

        // Phase 2: the incoming side rotates to completion from −90° to 0°.
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

    /// Instantly brings the tile to the `target` side.
    private func settle(on target: Side) {
        flipGeneration &+= 1
        isFlipping = false
        flipCompletion = nil
        side = target
        resetTransforms()
    }

    /// Returns both sides to the settled side without animation.
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

    /// A `CATransform3D` rotation around the Y axis with perspective (§4).
    ///
    /// `m34` is the perspective term of the matrix: without it the rotation looks like flat scaling,
    /// with it the far side of the tile goes into depth.
    private static func perspectiveRotation(by angle: CGFloat) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / perspectiveDistance
        return CATransform3DRotate(transform, angle, 0, 1, 0)
    }

    // MARK: - Layout and accessibility

    public override func layoutSubviews() {
        super.layoutSubviews()

        // In the middle of a flip a face has a non-identity 3D `layer.transform`, and `frame` is
        // undefined under a non-identity transform (UIView documentation): assigning `frame` gives
        // a UIKit implementation-dependent value. The face geometry is set through `bounds` +
        // `center`, which do not depend on the transform, so the flip continues from the same phase.
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

        // The badge does not take part in the flip and is positioned separately: in the bottom
        // corner at the trailing end (D29), the right one in LTR and the left one in RTL; in edit
        // mode it avoids the resize arrow. The face text yields room to it.
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

    /// §9: a tile is a single element; the face title and the badge counter are its label and
    /// value.
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
            // D34: without host text, the dot is announced with a module string.
            accessibilityValue = badgeView.badge.accessibilityValueText
        }
    }

    /// VoiceOver activation of a shortcut (D12): the double-tap gesture arrives here, not in the grid
    /// cell, because the tile is a standalone element (§9).
    public override func accessibilityActivate() -> Bool {
        guard let onActivate else { return super.accessibilityActivate() }
        onActivate()
        return true
    }
}

#endif
