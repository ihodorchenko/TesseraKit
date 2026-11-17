//
//  TesseraPivotHeaderStripView.swift
//  TesseraPivot
//
//  The pivot header strip: a horizontal UICollectionView + a separate indicator.
//  Contract: docs/PIVOT-IOS-DESIGN.md (architecture: TesseraPivotHeaderStripView is a
//  UICollectionView of headers + an indicator, with a strip mode of content width or
//  equal widths; core math: the indicator is interpolated between
//  the header centers; coloring by the distance from `t`; auto-centering
//  only if the strip overflows; synchronizing the strip and the pager: a single
//  source of truth and a single writer of contentOffset; performance:
//  cell reuse, and on the hot path only frame/transform/alpha, no
//  reloadData or layout; accessibility: Dynamic Type, RTL, VoiceOver).
//
//  Performance discipline: `apply(progress:)` and the strip's
//  `scrollViewDidScroll` change only the indicator's `transform` and the
//  color/font/alpha of already visible cells. `reloadData`, `invalidateLayout`,
//  text measurement, and geometry rebuilds happen only in the layout pass
//  and in the configuration setters, never on the swipe hot path.
//

#if canImport(UIKit)
import UIKit
import TesseraCore

/// A horizontal strip of section headers with a continuous indicator.
///
/// Synchronization is one-way: in the pager's `scrollViewDidScroll`, the controller
/// calls ``apply(progress:)``, and the strip moves the indicator and recolors the
/// headers. There is no write-back: the strip never touches the pager's `contentOffset`;
/// a tap only reports the intent through ``onSelect``, and the transition is
/// performed by the controller (the single writer).
///
/// ## Usage
///
/// ```swift
/// let strip = TesseraPivotHeaderStripView()
/// strip.titles = sections.map(\.title)
/// strip.mode = style.stripMode
/// strip.titleFont = style.titleFont
/// strip.titleTextStyle = style.titleTextStyle
/// strip.activeColor = style.activeColor
/// strip.inactiveColor = style.inactiveColor
/// strip.showsIndicator = style.indicatorStyle != .accentText
/// strip.onSelect = { index in pivot.select(index: index) }
/// // in the pager's scrollViewDidScroll, on every frame:
/// strip.apply(progress: t)
/// ```
///
/// ## Width modes
///
/// - ``TesseraPivotStyle/StripMode/content``: a cell is as wide as its text; the strip
///   scrolls if it does not fit;
/// - ``TesseraPivotStyle/StripMode/fill``: equal widths; the headers share the strip's width
///   equally, and the strip does not scroll.
///
/// The mode is the caller's request; the strip may depart from `.fill` at large
/// Dynamic Type sizes and on cells that are too narrow (see the documentation of ``mode``), because
/// header buttons truncated to illegibility break accessibility.
///
/// ## RTL
///
/// The header order is set by the strip's layout: in RTL, section `0` ends up
/// on the right. The indicator works in content coordinates and takes centers from the
/// actual layout attributes, so `t` in reading order points to the
/// visually correct header regardless of how UIKit implements
/// mirroring. A content point is converted into strip coordinates through
/// `convert(_:to:)`, with no manual arithmetic on `contentOffset`.
///
/// ## Accessibility
///
/// - the headers are VoiceOver buttons (`.button`, and `.selected` for the active one);
/// - the font is scaled by ``titleFont``/``titleTextStyle`` and rebuilt
///   when the Dynamic Type category changes;
/// - no font is created or measured on the hot path: the active and
///   inactive fonts are cached per layout pass.
///
/// All methods run on the main thread: a UIKit view is not designed for calls from background threads
/// (docs/CORE-IOS-DESIGN.md: all UI work happens on the main thread).
public final class TesseraPivotHeaderStripView: UIView {

    // MARK: - Data

    /// The section headers in reading order: index `0` is the first section for the
    /// user regardless of LTR/RTL.
    ///
    /// Setting this reloads the cells (`reloadData`), so it must not be changed on the swipe
    /// hot path. The progress is clamped to the new index range:
    /// after the set changes, the strip does not "hang" past the last header.
    public var titles: [String] = [] {
        didSet {
            guard titles != oldValue else { return }
            reloadHeaders()
        }
    }

    /// The header width mode.
    ///
    /// The style (``TesseraPivotStyle``) holds the user's request, and the strip applies it
    /// with these adjustments:
    /// - at accessibility sizes, `.fill` yields to `.content` if the equal
    ///   width is less than the width of the longest header, so the text is not truncated to
    ///   illegibility;
    /// - `.fill` also yields to `.content` when the equal width is less than
    ///   ``minimumItemWidth``: the header stops being a button that is
    ///   usable for tapping.
    ///
    /// At regular sizes, `.fill` truncates long headers at the tail
    /// (`.byTruncatingTail`); this is a deliberate compromise of the "equal widths" mode.
    public var mode: TesseraPivotStyle.StripMode = .content {
        didSet {
            guard mode != oldValue else { return }
            invalidateHeaderGeometry(reloadData: false)
        }
    }

    /// The section nearest to the last applied progress.
    ///
    /// Updated in ``apply(progress:)``: in the middle of a swipe, the next section is already
    /// considered "active". Used for the active header's boldness
    /// and for the accessibility `.selected` trait.
    public private(set) var selectedIndex: Int = 0

    /// A tap on a header: the index in reading order.
    ///
    /// The strip changes neither the selection nor the pager by itself (the single writer of
    /// `contentOffset`). In its handler, the controller performs a programmatic transition,
    /// and the selection returns with the next `apply(progress:)`.
    public var onSelect: ((Int) -> Void)?

    // MARK: - Appearance (fonts and colors are configurable)

    /// The accent color: the color of the active header and the underline.
    ///
    /// The intermediate shades of inactive neighbors are obtained by continuous
    /// interpolation from ``inactiveColor`` to this color by the distance from `t`
    /// (the text coloring). The default is `.systemBlue`, the default of
    /// ``TesseraPivotStyle/activeColor``.
    public var activeColor: UIColor = .systemBlue {
        didSet {
            guard activeColor != oldValue else { return }
            indicator.activeColor = activeColor
            applyHighlightToVisibleHeaders()
        }
    }

    /// The color of an inactive header. The default is `.systemGray`, the default of
    /// ``TesseraPivotStyle/inactiveColor``.
    public var inactiveColor: UIColor = .systemGray {
        didSet {
            guard inactiveColor != oldValue else { return }
            applyHighlightToVisibleHeaders()
        }
    }

    /// The base (unscaled) font of the headers (see Dynamic Type).
    ///
    /// The component scales it itself through `UIFontMetrics(forTextStyle:)` with
    /// ``titleTextStyle`` and rebuilds it when the text size category changes.
    /// Do not pass an already scaled font: it would be scaled
    /// again; pass the base size. The default is the system semibold
    /// 17 pt, like ``TesseraPivotStyle/titleFont``.
    public var titleFont: UIFont = .systemFont(ofSize: 17, weight: .semibold) {
        didSet {
            guard titleFont != oldValue else { return }
            invalidateHeaderGeometry(reloadData: true)
        }
    }

    /// The text style whose metrics scale ``titleFont``.
    /// The default is `.headline`, like ``TesseraPivotStyle/titleTextStyle``.
    public var titleTextStyle: UIFont.TextStyle = .headline {
        didSet {
            guard titleTextStyle != oldValue else { return }
            invalidateHeaderGeometry(reloadData: true)
        }
    }

    /// The boldness of the active header.
    ///
    /// Inactive headers are shown in ``titleFont`` as is, and the active one in the same
    /// font with this weight. The default is `.semibold`: it matches the
    /// default ``TesseraPivotStyle/titleFont``, so out of the box the accent is conveyed
    /// by color rather than by a jump in text width. The classic Windows Phone contrast is obtained
    /// by setting ``titleFont`` without weight (`.regular`); then the active
    /// header becomes semibold.
    public var activeFontWeight: UIFont.Weight = .semibold {
        didSet {
            guard activeFontWeight != oldValue else { return }
            invalidateHeaderGeometry(reloadData: true)
        }
    }

    /// The radius of the "accent handover" in progress units.
    ///
    /// `1` (the default) means a header halfway between sections is already fully
    /// inactive; a larger value also highlights farther neighbors. Negative
    /// and zero values are treated as "no blurring" (see
    /// ``TesseraPivotHeaderIndicator/blendFactor(distanceFromProgress:span:)``).
    public var highlightSpan: CGFloat = 1 {
        didSet {
            guard highlightSpan != oldValue else { return }
            applyHighlightToVisibleHeaders()
        }
    }

    /// Whether to show the underline under the active header.
    ///
    /// For `TesseraPivotStyle.IndicatorStyle.accentText` the controller sets `false`
    /// (the indicator style is accent text only). The continuous coloring of the
    /// headers does not depend on the flag: it always works.
    public var showsIndicator: Bool = true {
        didSet {
            guard showsIndicator != oldValue else { return }
            updateIndicatorPosition()
        }
    }

    /// The strip's horizontal insets: left/right of the outermost headers in
    /// `.content` mode. In `.fill` the cells share the strip's width, so the outer
    /// insets are not applied.
    public var horizontalInset: CGFloat = 16 {
        didSet {
            guard horizontalInset != oldValue else { return }
            invalidateHeaderGeometry(reloadData: false)
        }
    }

    /// The spacing between headers in points. In `.fill` it is subtracted from the
    /// available width before dividing by the number of headers.
    public var interItemSpacing: CGFloat = 20 {
        didSet {
            guard interItemSpacing != oldValue else { return }
            invalidateHeaderGeometry(reloadData: false)
        }
    }

    /// The horizontal inset of the text inside a cell: the cell width in `.content`
    /// is the text width plus two such insets.
    public var horizontalTextPadding: CGFloat = 8 {
        didSet {
            guard horizontalTextPadding != oldValue else { return }
            invalidateHeaderGeometry(reloadData: false)
        }
    }

    /// The minimum width of a header cell: a tappable target and the lower bound of
    /// where the `.fill` mode is applicable.
    public var minimumItemWidth: CGFloat = 44 {
        didSet {
            guard minimumItemWidth != oldValue else { return }
            invalidateHeaderGeometry(reloadData: false)
        }
    }

    // MARK: - State

    private let headerLayout: UICollectionViewFlowLayout
    private let collectionView: UICollectionView

    /// The strip's indicator.
    ///
    /// Available at module level (`@testable`) so that contract tests
    /// can verify that only `transform` changes on the hot path;
    /// it is not part of the public surface: the strip owns the geometry.
    internal private(set) var indicator: TesseraPivotHeaderIndicator

    /// The last applied progress. Stored so that newly appearing cells can be recolored
    /// and the indicator position repeated during the strip's own
    /// scrolling without asking the pager.
    ///
    /// Readable at module level (`@testable`) for the synchronization
    /// contract tests; written only by the strip itself.
    private(set) var lastProgress: CGFloat = 0

    /// How many times the strip started an animated re-centering (`scrollToItem`
    /// with animation).
    ///
    /// For module contract tests only (`@testable`): a scroll animation
    /// does not run in a test environment without a scene, and by `contentOffset`
    /// an animated re-centering cannot be told from an instant one.
    private(set) var animatedCenteringCount = 0

    /// The cache of cell widths and centers in content coordinates. Computed only in
    /// the layout pass.
    private var requiredWidthsCache: [CGFloat] = []
    private var contentCenters: [CGFloat] = []
    private var contentWidth: CGFloat = 0
    private var isGeometryValid = false
    private var lastLayoutSize: CGSize = .zero

    /// The collection's layout direction for which the geometry was computed.
    ///
    /// Header centers depend on the direction (in RTL the layout mirrors
    /// the cells), and the strip's size does not change when the direction changes, so
    /// a size check in `layoutSubviews` alone is not enough.
    private var lastLayoutDirection: UIUserInterfaceLayoutDirection?

    /// Whether, after the next layout, the selected header must be returned to
    /// the visible area: a rotation or a width or layout direction change
    /// shifts the cells relative to the saved `contentOffset`.
    private var needsSelectionVisibilityRestore = false

    /// The font cache: the active/inactive font is rebuilt only when
    /// Dynamic Type or the font settings change, not on every swipe frame.
    private var activeFontCache: UIFont?
    private var inactiveFontCache: UIFont?

    // MARK: - Initialization

    /// Creates a strip with an empty set of headers.
    ///
    /// - Parameter frame: The initial frame; usually the controller lays the strip out.
    public override init(frame: CGRect) {
        headerLayout = PivotHeaderFlowLayout()
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: headerLayout)
        indicator = TesseraPivotHeaderIndicator()
        super.init(frame: frame)
        commonInit()
    }

    /// Creates a strip from an archive/storyboard.
    ///
    /// - Parameter coder: The archive decoder.
    public required init?(coder: NSCoder) {
        headerLayout = PivotHeaderFlowLayout()
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: headerLayout)
        indicator = TesseraPivotHeaderIndicator()
        super.init(coder: coder)
        commonInit()
    }

    /// Common setup: the headers collection and a separate indicator layer.
    ///
    /// The indicator is added after the collection, so it is always above the cells; it catches
    /// no events and therefore does not block taps on the headers.
    private func commonInit() {
        backgroundColor = .clear
        clipsToBounds = true

        headerLayout.scrollDirection = .horizontal
        headerLayout.minimumInteritemSpacing = 0
        headerLayout.estimatedItemSize = .zero
        // RTL: the cell order is the order of sections in the model, and the visual
        // direction is set by the layout according to the environment's `semanticContentAttribute`.
        // The indicator geometry reads the actual attributes, so mirroring
        // is not duplicated in a separate branch.
        headerLayout.sectionInset = UIEdgeInsets(
            top: 0,
            left: max(horizontalInset, 0),
            bottom: 0,
            right: max(horizontalInset, 0)
        )
        headerLayout.minimumLineSpacing = max(interItemSpacing, 0)

        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset = .zero
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            PivotHeaderCell.self,
            forCellWithReuseIdentifier: PivotHeaderCell.reuseIdentifier
        )

        indicator.activeColor = activeColor
        indicator.isHidden = true

        addSubview(collectionView)
        addSubview(indicator)

        // Dynamic Type: recompute fonts and widths when the category changes.
        // The notification arrives on the main thread after the traits update.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
    }

    // MARK: - Public synchronization API

    /// Applies the pager's progress: moves the indicator and recolors the headers.
    ///
    /// The only entry point from the pager's `scrollViewDidScroll`. Inside it there is
    /// only the indicator's `transform` and the color/font/alpha of already visible cells: no
    /// `reloadData`, no `layoutIfNeeded`, no `invalidateLayout`, and no text
    /// measurement. If the strip has not been laid out yet, the call is safe: the progress
    /// is remembered and applied in the next layout pass.
    ///
    /// - Parameter t: The progress normalized by the reading direction
    ///   `contentOffset.x / pageWidth` (see ``TesseraRTL/normalizedProgress(_:pageCount:layoutDirection:)``).
    ///   Values outside the range are allowed: the indicator is clamped
    ///   to the outermost centers, and the "active" header to the outermost section.
    public func apply(progress t: CGFloat) {
        lastProgress = t.isNaN ? 0 : t
        selectedIndex = nearestIndex(to: lastProgress)
        updateIndicatorPosition()
        applyHighlightToVisibleHeaders()
    }

    /// Sets the selection by index without scrolling the strip and without `onSelect`.
    ///
    /// Used by the controller for the initial state, restoring after
    /// a rotation, and programmatic transitions: this is ``apply(progress:)`` with an integer `t`.
    /// Re-centering the strip is a separate call,
    /// ``scrollToCenter(index:animated:)``: the strip is re-centered when a
    /// transition completes.
    ///
    /// - Parameter index: The section index in reading order; clamped to the range of
    ///   existing headers. An empty strip gives ``selectedIndex`` `0`.
    public func select(index: Int) {
        guard !titles.isEmpty else {
            selectedIndex = 0
            return
        }

        apply(progress: CGFloat(min(max(index, 0), titles.count - 1)))
    }

    /// Re-centers the strip so that the header `index` ends up at the center.
    ///
    /// Only if the strip overflows **and the header is off the edge** (fully
    /// or partly outside the visible area): a visible header does not move the strip,
    /// otherwise it would jitter on every transition. The position is
    /// `.centeredHorizontally`. If the strip does not overflow, but `contentOffset`
    /// remains non-zero (for example, after a rotation to a wider orientation),
    /// it returns to the start without animation, since all headers are visible anyway.
    ///
    /// `animated` is the caller's intent, but with Reduce Motion the animation
    /// is forcibly disabled (a jump on tap has no animation):
    /// auto-centering is a self-driven animation, not a repeat of the gesture, unlike
    /// the continuous indicator.
    ///
    /// - Parameters:
    ///   - index: The section index in reading order; clamped to the range.
    ///   - animated: Whether to animate the strip's scroll (adjusted for Reduce Motion).
    public func scrollToCenter(index: Int, animated: Bool) {
        guard !titles.isEmpty else { return }

        rebuildGeometryIfNeeded()
        guard isOverflowing else {
            resetOffsetIfNotOverflowing()
            return
        }

        let clampedIndex = min(max(index, 0), titles.count - 1)
        let indexPath = IndexPath(item: clampedIndex, section: 0)
        guard isItemBeyondVisibleEdge(at: indexPath) else { return }

        let shouldAnimate = animated && !TesseraAccessibility.isReduceMotionEnabled
        if shouldAnimate {
            animatedCenteringCount += 1
        }
        collectionView.scrollToItem(
            at: indexPath,
            at: .centeredHorizontally,
            animated: shouldAnimate
        )
    }

    /// A header fully or partly outside the strip's visible area.
    ///
    /// The comparison is in the collection's content coordinates: both the attributes' frame and
    /// `bounds` (the visible rectangle) live in them, including in RTL.
    /// No attributes means "off the edge", so that re-centering is not lost.
    private func isItemBeyondVisibleEdge(at indexPath: IndexPath) -> Bool {
        guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else {
            return true
        }
        let visible = collectionView.bounds
        let tolerance: CGFloat = 0.5
        return frame.minX < visible.minX - tolerance || frame.maxX > visible.maxX + tolerance
    }

    /// A strip that does not overflow does not scroll: a residual `contentOffset`
    /// is reset to the start without animation.
    private func resetOffsetIfNotOverflowing() {
        let leading = CGPoint(x: -collectionView.adjustedContentInset.left, y: collectionView.contentOffset.y)
        guard abs(collectionView.contentOffset.x - leading.x) > 0.5 else { return }
        collectionView.setContentOffset(leading, animated: false)
    }

    // MARK: - Layout

    /// Lays out the collection, rebuilds the strip geometry, and places the indicator.
    ///
    /// The strip's only layout pass: text measurement,
    /// `invalidateLayout`, and the indicator's `bounds`/`center` are allowed here.
    ///
    /// The geometry is rebuilt when the size **or** the layout direction changes
    /// (in RTL the layout mirrors the cells, while the strip's size stays the same).
    /// After a rotation or a direction change, the selected header returns to
    /// the visible area without animation (the strip rebuilds itself).
    public override func layoutSubviews() {
        super.layoutSubviews()

        let size = bounds.size
        if size != lastLayoutSize {
            // The first layout with a non-zero width is not a rotation: the controller
            // performs the re-centering on first display.
            if lastLayoutSize.width > 0 {
                needsSelectionVisibilityRestore = true
            }
            lastLayoutSize = size
            isGeometryValid = false
            // Cell widths depend on the strip's width, so the delegate's sizes
            // must be requested again rather than taken from the layout cache.
            collectionView.collectionViewLayout.invalidateLayout()
        }

        let direction = collectionView.effectiveUserInterfaceLayoutDirection
        if let lastLayoutDirection, lastLayoutDirection != direction {
            isGeometryValid = false
            needsSelectionVisibilityRestore = true
            collectionView.collectionViewLayout.invalidateLayout()
        }
        lastLayoutDirection = direction

        syncLayoutMetrics()
        collectionView.frame = bounds

        rebuildGeometryIfNeeded()
        indicator.placeBar(inStripBounds: bounds)

        if needsSelectionVisibilityRestore, bounds.width > 0 {
            needsSelectionVisibilityRestore = false
            scrollToCenter(index: selectedIndex, animated: false)
        }
        updateIndicatorPosition()
    }

    /// A `semanticContentAttribute` change of the strip on the fly.
    ///
    /// The collection is a child view and does not inherit the parent's semantics (its
    /// `effectiveUserInterfaceLayoutDirection` comes from the collection's traits),
    /// so the attribute is carried over to it explicitly, and the geometry is marked
    /// invalid: otherwise the centers would stay computed for the previous
    /// direction and the indicator would sit under the wrong header.
    public override var semanticContentAttribute: UISemanticContentAttribute {
        didSet {
            guard semanticContentAttribute != oldValue else { return }
            collectionView.semanticContentAttribute = semanticContentAttribute
            setNeedsLayout()
        }
    }

    /// A direction change from the environment (the `layoutDirection` trait) is the same
    /// invalidation as a semantics change. The rebuild itself is done by
    /// `layoutSubviews`, comparing the collection's direction with the remembered one.
    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.layoutDirection != traitCollection.layoutDirection {
            setNeedsLayout()
        }
    }

    /// Synchronizes the layout insets with the effective width mode.
    ///
    /// In `.fill`, the strip's outer insets are not applied: the cells share the whole width
    /// (plus the gaps), otherwise the total width would stop matching
    /// the strip's width and a false scroll would appear.
    private func syncLayoutMetrics() {
        let inset = effectiveHorizontalInset
        let spacing = effectiveItemSpacing
        guard headerLayout.sectionInset.left != inset
            || headerLayout.minimumLineSpacing != spacing
        else { return }

        headerLayout.sectionInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        headerLayout.minimumLineSpacing = spacing
        headerLayout.invalidateLayout()
    }

    // MARK: - Geometry (layout pass only)

    /// Rebuilds the geometry cache if it is marked invalid.
    private func rebuildGeometryIfNeeded() {
        guard !isGeometryValid else { return }
        rebuildGeometry()
    }

    /// Computes the header centers in content coordinates.
    ///
    /// The source of truth is the actual layout attributes: they already account for
    /// the reading direction, insets, and gaps, so nothing needs to be mirrored by hand in RTL.
    /// Manual geometry (widths + insets + gaps) is
    /// only a fallback for cells the layout has not provided yet:
    /// the right variant (direct or mirrored) is determined by checking against the real
    /// attributes rather than by guessing UIKit's behavior in RTL.
    private func rebuildGeometry() {
        guard !titles.isEmpty, bounds.width > 0 else {
            contentCenters = []
            contentWidth = 0
            isGeometryValid = true
            return
        }

        // The attributes of existing cells are available only after the layout is
        // prepared; a forced pass is acceptable here because this is layout, not the
        // swipe hot path.
        collectionView.layoutIfNeeded()

        let inset = effectiveHorizontalInset
        let spacing = effectiveItemSpacing

        var widths: [CGFloat] = []
        widths.reserveCapacity(titles.count)
        for index in titles.indices {
            widths.append(itemWidth(at: index))
        }

        var directCenters: [CGFloat] = []
        directCenters.reserveCapacity(widths.count)
        var originX = inset
        for width in widths {
            directCenters.append(originX + width / 2)
            originX += width + spacing
        }
        let totalWidth = originX - spacing + inset
        let mirroredCenters = directCenters.map { totalWidth - $0 }

        var centers = shouldMirrorCenters(direct: directCenters, mirrored: mirroredCenters)
            ? mirroredCenters
            : directCenters

        // Exact positions from the layout: they override the computed ones where available.
        for item in titles.indices {
            let indexPath = IndexPath(item: item, section: 0)
            guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { continue }
            centers[item] = attributes.frame.midX
        }

        contentCenters = centers
        contentWidth = collectionView.contentSize.width
        isGeometryValid = true
    }

    /// Decides whether the layout mirrors the headers in the current direction.
    ///
    /// Compares the computed direct and mirrored centers with the actual attributes:
    /// this way the decision does not depend on exactly how UIKit implements RTL
    /// (mirroring the cells or moving `contentOffset` negative). If the layout is not
    /// prepared yet, mirroring is expected for RTL: this is the standard behavior
    /// of the flow layout; the choice is refined on the next layout pass.
    private func shouldMirrorCenters(direct: [CGFloat], mirrored: [CGFloat]) -> Bool {
        guard isRightToLeft else { return false }

        var directError: CGFloat = 0
        var mirroredError: CGFloat = 0
        var comparedItems = 0

        for item in direct.indices {
            let indexPath = IndexPath(item: item, section: 0)
            guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { continue }

            let center = attributes.frame.midX
            directError += abs(center - direct[item])
            mirroredError += abs(center - mirrored[item])
            comparedItems += 1
        }

        guard comparedItems > 0 else { return true }
        return mirroredError < directError
    }

    /// The width of a header cell for the effective mode.
    ///
    /// In `.content`, the width is computed for the widest state (the active
    /// font): when the weight changes, the text neither jumps nor is truncated.
    private func itemWidth(at index: Int) -> CGFloat {
        guard titles.indices.contains(index) else { return 0 }

        if effectiveMode == .fill {
            return fillItemWidth
        }

        rebuildRequiredWidthsIfNeeded()
        return requiredWidthsCache[index]
    }

    /// The cell width in `.fill` mode: all headers share the strip's width equally,
    /// and the gaps are subtracted before dividing.
    private var fillItemWidth: CGFloat {
        let count = CGFloat(titles.count)
        guard count > 0 else { return 0 }

        let available = bounds.width - effectiveItemSpacing * (count - 1)
        // Do not let the width collapse to zero: a zero-width cell breaks the layout,
        // and a strip overflow is handled as ordinary scrolling.
        return max(available / count, 1)
    }

    /// The header widths in `.content` mode, taking Dynamic Type into account.
    private func rebuildRequiredWidthsIfNeeded() {
        guard requiredWidthsCache.count != titles.count else { return }

        let activeFont = headerFont(isActive: true)
        let inactiveFont = headerFont(isActive: false)
        let textPadding = max(horizontalTextPadding, 0)
        let minimumWidth = max(minimumItemWidth, 1)

        requiredWidthsCache = titles.map { title in
            let textWidth = max(
                measuredTextWidth(title, font: activeFont),
                measuredTextWidth(title, font: inactiveFont)
            )
            return max(textWidth + textPadding * 2, minimumWidth)
        }
    }

    /// The string width in a font, rounded up: fractional values would give
    /// a truncated tail of the text when truncating.
    private func measuredTextWidth(_ title: String, font: UIFont) -> CGFloat {
        (title as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    /// The effective width mode: the caller's request plus the accessibility adjustments.
    private var effectiveMode: TesseraPivotStyle.StripMode {
        guard mode == .fill else { return .content }
        guard titles.count > 1, bounds.width > 0 else { return .fill }

        let fillWidth = fillItemWidth
        // Cells that are too tight are not buttons: give the width to the text and scroll.
        guard fillWidth >= max(minimumItemWidth, 1) else { return .content }

        // At regular sizes, truncating the tail is acceptable, and at accessibility sizes
        // it is not: the header text must not be lost.
        guard isAccessibilityTextSize else { return .fill }

        rebuildRequiredWidthsIfNeeded()
        let widestTitleWidth = requiredWidthsCache.max() ?? 0
        return fillWidth >= widestTitleWidth ? .fill : .content
    }

    private var isAccessibilityTextSize: Bool {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    }

    private var effectiveHorizontalInset: CGFloat {
        effectiveMode == .fill ? 0 : max(horizontalInset, 0)
    }

    private var effectiveItemSpacing: CGFloat {
        titles.count > 1 ? max(interItemSpacing, 0) : 0
    }

    private var isOverflowing: Bool {
        isGeometryValid && contentWidth > bounds.width + 0.5
    }

    /// The direction in which the layout actually arranges the cells is
    /// the collection's direction, not the strip's own.
    private var isRightToLeft: Bool {
        collectionView.effectiveUserInterfaceLayoutDirection == .rightToLeft
    }

    // MARK: - Indicator

    /// Places the indicator at the center corresponding to the last progress.
    ///
    /// The indicator is a separate layer above the strip, so a content point
    /// is converted into strip coordinates through `convert(_:to:)`: this is the only
    /// way to not depend on how UIKit implements RTL (a coordinate shift or
    /// a negative `contentOffset`). Only `transform` changes.
    private func updateIndicatorPosition() {
        guard isGeometryValid else { return }

        guard showsIndicator, !contentCenters.isEmpty, bounds.width > 0 else {
            indicator.isHidden = true
            return
        }

        if indicator.isHidden {
            indicator.isHidden = false
        }
        let contentCenter = TesseraPivotHeaderIndicator.indicatorCenter(
            centers: contentCenters,
            progress: lastProgress
        )
        let centerInStrip = collectionView.convert(CGPoint(x: contentCenter, y: 0), to: self)
        indicator.move(toCenterX: centerInStrip.x)
    }

    // MARK: - Fonts (Dynamic Type)

    /// The header font for the active/inactive state.
    ///
    /// The base font is scaled by the ``titleTextStyle`` metrics; the active one
    /// additionally gets the ``activeFontWeight`` weight through a descriptor
    /// to preserve the family and size. The result is cached: the swipe
    /// hot path creates no fonts.
    private func headerFont(isActive: Bool) -> UIFont {
        if isActive, let cached = activeFontCache { return cached }
        if !isActive, let cached = inactiveFontCache { return cached }

        let metrics = UIFontMetrics(forTextStyle: titleTextStyle)
        let scaledFont = metrics.scaledFont(for: titleFont, compatibleWith: traitCollection)

        let font: UIFont
        if isActive {
            let descriptor = scaledFont.fontDescriptor.addingAttributes([
                UIFontDescriptor.AttributeName.traits: [
                    UIFontDescriptor.TraitKey.weight: activeFontWeight
                ]
            ])
            font = UIFont(descriptor: descriptor, size: scaledFont.pointSize)
        } else {
            font = scaledFont
        }

        if isActive {
            activeFontCache = font
        } else {
            inactiveFontCache = font
        }
        return font
    }

    // MARK: - Coloring (the text coloring)

    /// Recolors the visible headers by their distance from the progress.
    ///
    /// Only existing cells: `reloadData` and creating new cells on the
    /// hot path are forbidden. New cells get their state in
    /// `cellForItemAt`.
    private func applyHighlightToVisibleHeaders() {
        guard !titles.isEmpty else { return }

        let activeIndex = selectedIndex
        for cell in collectionView.visibleCells {
            guard
                let headerCell = cell as? PivotHeaderCell,
                let indexPath = collectionView.indexPath(for: cell)
            else { continue }
            configure(headerCell, at: indexPath.item, activeIndex: activeIndex)
        }
    }

    /// Applies the state of the header `index` to a cell.
    private func configure(_ cell: PivotHeaderCell, at index: Int, activeIndex: Int) {
        guard titles.indices.contains(index) else { return }

        let isActive = index == activeIndex
        let factor = TesseraPivotHeaderIndicator.blendFactor(
            distanceFromProgress: CGFloat(index) - lastProgress,
            span: highlightSpan
        )

        cell.apply(
            title: titles[index],
            font: headerFont(isActive: isActive),
            isActive: isActive,
            factor: factor,
            activeColor: activeColor,
            inactiveColor: inactiveColor
        )
    }

    // MARK: - Configuration invalidation

    /// Resets the width/font caches and asks the layout to recompute the cells.
    ///
    /// Called from the configuration setters and from the Dynamic Type notification, that
    /// is, off the swipe hot path.
    ///
    /// - Parameter reloadData: Whether the cells must be recreated. The fonts and texts of
    ///   cells are updated without `reloadData`, so a reload is needed only
    ///   when the font/style changes, not when the mode or insets change.
    private func invalidateHeaderGeometry(reloadData: Bool) {
        requiredWidthsCache.removeAll(keepingCapacity: true)
        activeFontCache = nil
        inactiveFontCache = nil
        isGeometryValid = false

        collectionView.collectionViewLayout.invalidateLayout()
        if reloadData {
            collectionView.reloadData()
        }
        setNeedsLayout()
        applyHighlightToVisibleHeaders()
    }

    /// Reloads the strip after the set of headers changes.
    ///
    /// The progress is clamped to the new range: after sections are removed, the strip
    /// must not point to a nonexistent header.
    private func reloadHeaders() {
        lastProgress = min(max(lastProgress, 0), CGFloat(max(titles.count - 1, 0)))
        selectedIndex = nearestIndex(to: lastProgress)

        requiredWidthsCache.removeAll(keepingCapacity: true)
        activeFontCache = nil
        inactiveFontCache = nil
        isGeometryValid = false

        collectionView.reloadData()
        collectionView.collectionViewLayout.invalidateLayout()
        setNeedsLayout()
    }

    /// The index of the section nearest to the progress, clamped to the range of headers.
    private func nearestIndex(to progress: CGFloat) -> Int {
        guard !titles.isEmpty, !progress.isNaN else { return 0 }

        let lastIndex = CGFloat(titles.count - 1)
        let clampedProgress = min(max(progress, 0), lastIndex)
        return Int(clampedProgress.rounded())
    }

    // MARK: - Notifications

    /// A Dynamic Type category change: fonts and widths are recomputed.
    @objc private func contentSizeCategoryDidChange() {
        invalidateHeaderGeometry(reloadData: true)
    }
}

// MARK: - UICollectionViewDataSource

extension TesseraPivotHeaderStripView: UICollectionViewDataSource {

    /// The number of headers: one per section.
    public func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        titles.count
    }

    /// A header cell with the state matching the last progress.
    public func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: PivotHeaderCell.reuseIdentifier,
            for: indexPath
        )
        if let headerCell = cell as? PivotHeaderCell {
            configure(headerCell, at: indexPath.item, activeIndex: selectedIndex)
        }
        return cell
    }
}

// MARK: - UICollectionViewDelegateFlowLayout

extension TesseraPivotHeaderStripView: UICollectionViewDelegateFlowLayout {

    /// The cell size: the height is the whole strip, the width depends on the mode.
    public func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        guard titles.indices.contains(indexPath.item) else { return .zero }

        return CGSize(
            width: itemWidth(at: indexPath.item),
            height: max(collectionView.bounds.height, 1)
        )
    }

    /// A tap on a header: reports the intent without changing the strip's state.
    public func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard titles.indices.contains(indexPath.item) else { return }

        onSelect?(indexPath.item)
    }

    /// The user's own scrolling of the strip: the indicator follows the
    /// header it has "snapped" to, by transform only.
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
        updateIndicatorPosition()
    }
}

// MARK: - Header cell

/// A strip header cell.
///
/// An internal detail: no autolayout and no `intrinsicContentSize` dependencies,
/// so that changing the font and color on the hot path does not trigger a layout pass.
/// The size is set by the strip's delegate, and the text is centered in `contentView`.
private final class PivotHeaderCell: UICollectionViewCell {

    static let reuseIdentifier = "PivotHeaderCell"

    private let titleLabel = UILabel()

    // The last applied state: lets us skip work when the
    // progress moved by less than half a percent.
    private var appliedTitle: String?
    private var appliedFont: UIFont?
    private var appliedIsActive: Bool?
    private var appliedFactor: CGFloat = -1
    private var appliedActiveColor: UIColor?
    private var appliedInactiveColor: UIColor?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel.frame = contentView.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        appliedTitle = nil
        appliedFont = nil
        appliedIsActive = nil
        appliedFactor = -1
        appliedActiveColor = nil
        appliedInactiveColor = nil
        titleLabel.text = nil
    }

    /// Common setup: the cell is a button for VoiceOver, and the caption is its
    /// accessibility label rather than a separate element.
    private func setUp() {
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .button

        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        // In `.fill`, a long header is truncated at the tail; at regular sizes
        // this is a deliberate compromise of the equal-widths mode (see `mode`).
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isAccessibilityElement = false
        contentView.addSubview(titleLabel)
    }

    /// Applies the header state.
    ///
    /// Called both from `cellForItemAt` and from the swipe hot path, so it
    /// first compares the state with the last applied one and exits without
    /// doing any work if nothing noticeable changed.
    ///
    /// - Parameters:
    ///   - title: The header text.
    ///   - font: The already scaled font of the state.
    ///   - isActive: Whether this is the header nearest to the progress (weight + `.selected`).
    ///   - factor: The accent coefficient `0...1` from
    ///     ``TesseraPivotHeaderIndicator/blendFactor(distanceFromProgress:span:)``.
    ///   - activeColor: The full accent color.
    ///   - inactiveColor: The color of an inactive header.
    func apply(
        title: String,
        font: UIFont,
        isActive: Bool,
        factor: CGFloat,
        activeColor: UIColor,
        inactiveColor: UIColor
    ) {
        let clampedFactor = min(max(factor, 0), 1)

        guard appliedTitle != title
            || appliedFont != font
            || appliedIsActive != isActive
            || abs(appliedFactor - clampedFactor) > 0.005
            || appliedActiveColor != activeColor
            || appliedInactiveColor != inactiveColor
        else { return }

        appliedTitle = title
        appliedFont = font
        appliedIsActive = isActive
        appliedFactor = clampedFactor
        appliedActiveColor = activeColor
        appliedInactiveColor = inactiveColor

        titleLabel.text = title
        if titleLabel.font != font {
            titleLabel.font = font
        }
        titleLabel.textColor = Self.blendedColor(
            active: activeColor,
            inactive: inactiveColor,
            amount: clampedFactor
        )

        accessibilityLabel = title
        let isSelectedForAccessibility = accessibilityTraits.contains(.selected)
        if isActive != isSelectedForAccessibility {
            if isActive {
                accessibilityTraits = [.button, .selected]
            } else {
                accessibilityTraits = .button
            }
        }
    }

    /// Continuous color interpolation from inactive to active.
    ///
    /// The color is created dynamic (`UIColor(dynamicProvider:)`) and resolves the
    /// source colors at draw time: system dynamic colors
    /// keep adapting to the light/dark theme, whereas
    /// a premature `getRed` would freeze a single theme forever.
    private static func blendedColor(active: UIColor, inactive: UIColor, amount: CGFloat) -> UIColor {
        let blendAmount = min(max(amount, 0), 1)
        if blendAmount <= 0 { return inactive }
        if blendAmount >= 1 { return active }

        return UIColor { traits in
            let resolvedActive = active.resolvedColor(with: traits)
            let resolvedInactive = inactive.resolvedColor(with: traits)

            guard
                let activeComponents = resolvedActive.rgbaComponents,
                let inactiveComponents = resolvedInactive.rgbaComponents
            else {
                // Non-color/template colors are not blended: return the nearest pole.
                return blendAmount < 0.5 ? resolvedInactive : resolvedActive
            }

            return UIColor(
                red: inactiveComponents.red
                    + (activeComponents.red - inactiveComponents.red) * blendAmount,
                green: inactiveComponents.green
                    + (activeComponents.green - inactiveComponents.green) * blendAmount,
                blue: inactiveComponents.blue
                    + (activeComponents.blue - inactiveComponents.blue) * blendAmount,
                alpha: inactiveComponents.alpha
                    + (activeComponents.alpha - inactiveComponents.alpha) * blendAmount
            )
        }
    }
}

// MARK: - Strip layout

/// A flow layout of the strip that mirrors the headers in RTL.
///
/// For `UICollectionViewFlowLayout`, `flipsHorizontallyInOppositeLayoutDirection`
/// is `false` by default: with a direction set locally
/// (`semanticContentAttribute`), the cells were not mirrored even though the pager mirrors
/// the page slots, so the header order diverged from the swipe direction.
/// The enabled flag flips the coordinate system when the collection's
/// `effectiveUserInterfaceLayoutDirection` is opposite to the layout's
/// `developmentLayoutDirection` (LTR). The indicator geometry still
/// reads the actual attributes, so it does not depend on the mirroring method.
private final class PivotHeaderFlowLayout: UICollectionViewFlowLayout {
    override var flipsHorizontallyInOppositeLayoutDirection: Bool { true }

    override var developmentLayoutDirection: UIUserInterfaceLayoutDirection { .leftToRight }
}

// MARK: - Color components

private extension UIColor {

    /// RGBA components in `0...1`; `nil` for colors that cannot be decomposed
    /// (for example, template colors). Call only for a resolved color: a
    /// dynamic color's `getRed` does not know the theme.
    var rgbaComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return (red, green, blue, alpha)
    }
}
#endif
