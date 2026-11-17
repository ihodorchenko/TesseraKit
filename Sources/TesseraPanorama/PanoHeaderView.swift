//
//  PanoHeaderView.swift
//  TesseraPanorama
//
//  The section headers layer of the panorama.
//  Design document: docs/PANORAMA-IOS-DESIGN.md (PanoHeaderView;
//  headers: piecewise-linear interpolation by the fractional part of t;
//  performance discipline; accessibility: Reduce Motion, Dynamic Type, RTL).
//

import TesseraCore
import UIKit

/// The section headers layer of the panorama.
///
/// Per `docs/PANORAMA-IOS-DESIGN.md`, this is a separate layer above the sections: it does not
/// own `contentOffset` and receives the progress `t` from outside. Each header is a
/// `UILabel` using a Dynamic Type text style; a label's visibility and shift are computed
/// from the same phase, so switching sections is a continuous "flow"
/// rather than a hard switch.
///
/// ## The phase model
///
/// For the label of section `i` at progress `t` (in reading order):
///
/// ```
/// phase = 0.5 + (i - t) / 2
/// ```
///
/// - `phase == 0.5`: the section is active: the header is centered, alpha 1, shift 0;
/// - `phase` in `0...0.5`: a neighboring section behind in reading order;
/// - `phase` in `0.5...1`: a neighboring section ahead.
///
/// Alpha and shift come from ``keyframeAlpha(progress:)`` and
/// ``keyframeOffset(progress:travel:)``, piecewise-linear between the keyframes
/// `0`, `0.5`, `1`. In the middle of a transition (`frac(t) == 0.5`) both
/// neighboring labels are visible with alpha 0.5; at an integer `t` exactly one remains active.
/// Values are continuous at section boundaries, so there is no jump.
///
/// For `t = i + f`, with `f` in `0...1`, the formulas of neighboring sections reduce to linear ones:
///
/// ```
/// section i    (active):  alpha = 1 − f,  offset = −(f/2)·travel
/// section i+1  (next):    alpha = f,     offset = ((1 − f)/2)·travel
/// ```
///
/// This is a convenient form for contract tests: at `f = 0` only
/// section `i` is visible, and at `f = 1` only `i + 1`.
///
/// ## Performance
///
/// ``apply(progress:activeIndex:)`` is called from `scrollViewDidScroll` and changes
/// only `alpha`/`transform`; there is no `setNeedsLayout` or `sizeThatFits` on this path.
/// The only exception is the accessibility element's text, and only
/// at a section boundary. Label layout happens once in
/// `layoutSubviews`, on creation and on a size change; the transform is also reset
/// and recomputed there.
///
/// ## Accessibility
///
/// - **Reduce Motion**: the ``isReduceMotionEnabled`` provider (by default
///   the system setting via `TesseraAccessibility`). When `true`, the headers are
///   static: only the active one is visible, with no shift or fades.
/// - **Dynamic Type**: `UIFont.preferredFont(forTextStyle:)` or the base
///   font scaled through `UIFontMetrics`, plus
///   `adjustsFontForContentSizeCategory`; when the text size changes, the view
///   recomputes its layout (outside scrolling).
/// - **RTL**: `t` arrives normalized by the reading direction (see
///   `TesseraRTL.normalizedProgress`). The sign of the horizontal shift, the insets, and
///   the text alignment are mirrored according to `effectiveUserInterfaceLayoutDirection`.
/// - **VoiceOver**: the view is a single accessibility element with the `.header`
///   trait and the text of the active section. The labels themselves are hidden from VoiceOver
///   so that a fading neighbor is not read as a separate header.
///
/// - Note: `t` is the pager's progress in reading order; the view does not write
///   `contentOffset` (see the single-writer contract in `docs/CORE-IOS-DESIGN.md`) and only reads its
///   derivative.
///
/// The module-internal name from the design document is `PanoHeaderView` (a `typealias` below); the public
/// name carries the `Tessera` prefix.
public final class TesseraPanoHeaderView: UIView {

    // MARK: - Style

    /// The style of the section headers.
    ///
    /// Intentionally minimal: typography is set by a Dynamic Type text style
    /// (or by a base font scaled by `UIFontMetrics`) rather than by an
    /// absolute size (see the Dynamic Type notes in `docs/PANORAMA-IOS-DESIGN.md`).
    public struct Style {

        /// The text style whose metrics scale the headers' font
        /// (Dynamic Type).
        ///
        /// The default is `.largeTitle`, a large section header in the style of
        /// Windows Phone Panorama.
        public var textStyle: UIFont.TextStyle

        /// The base (unscaled) font of the headers.
        ///
        /// If set, the view scales it through
        /// `UIFontMetrics(forTextStyle:).scaledFont(for:)`; this is how
        /// `TesseraPanoramaStyle.headerFont` ends up in the headers.
        /// `nil` means "use `UIFont.preferredFont(forTextStyle:)`".
        ///
        /// - Important: Pass an unscaled font. If you pass an
        ///   already scaled one (for example, `preferredFont`), Dynamic Type
        ///   is applied twice.
        public var baseFont: UIFont?

        /// The text color of the headers. Transparency (the fade) is set by the label's alpha,
        /// so the color can be anything, including an accent color.
        public var textColor: UIColor

        /// The color of the active header (`TesseraPanoramaStyle.headerActiveColor`).
        ///
        /// `nil` means all headers share the color ``textColor``. Otherwise the color
        /// is interpolated by the progress `t`: the accent weight of a header equals its
        /// "activity", the same piecewise-linear function of the phase as the alpha
        /// (``TesseraPanoHeaderView/keyframeAlpha(progress:)``): `1` at an integer `t`
        /// of its own section and `0` for a neighbor at an integer `t`. Interpolation is done
        /// with the alpha of an accent copy of the label on top of the main one, so the hot path
        /// still touches only `alpha`/`transform`.
        public var activeTextColor: UIColor?

        /// The amplitude of the horizontal shift as a fraction of the view's width.
        ///
        /// The full range of the shift is `travel = width * travelRatio`; a header
        /// moves by `±travel/2` when fully faded. Negative values
        /// are clamped to zero at initialization.
        public var travelRatio: CGFloat

        /// The content insets; in RTL the left and right swap places.
        public var contentInsets: UIEdgeInsets

        /// The maximum number of header lines; `0` means no limit.
        ///
        /// At large Dynamic Type sizes, a multi-line header is not
        /// truncated mid-word.
        public var numberOfLines: Int

        /// Creates a header style.
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

    // MARK: - State

    /// The Reduce Motion setting provider.
    ///
    /// Injected for tests and for hosts with their own notion of
    /// motion. By default it reads the system setting at call time
    /// (the value is not cached: turning on Reduce Motion while the
    /// app is running takes effect immediately). See the accessibility notes in `docs/PANORAMA-IOS-DESIGN.md`.
    public var isReduceMotionEnabled: () -> Bool = {
        TesseraAccessibility.isReduceMotionEnabled
    }

    /// The section headers in reading order (index 0 is the first section).
    ///
    /// They change only through ``setTitles(_:)``: recreating the labels is
    /// layout work, so it must not be called during scrolling.
    public private(set) var titles: [String]

    /// The headers style. A change is applied immediately (outside scrolling).
    public var style: Style {
        didSet {
            applyStyleToLabels()
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            // The font size may have changed, and the shift depends on the view's width,
            // so recompute the transform after the next layout.
            applyCurrentState()
        }
    }

    /// The labels, one per section; the order matches ``titles``.
    private var labels: [UILabel] = []

    /// The accent copies of the labels (``Style/activeTextColor``), one per section.
    ///
    /// Each lies **inside** its label (as a subview) with the same text and
    /// the label's `bounds` as its frame: the label's shift and fade apply to it automatically
    /// (the layer's group opacity), and the accent weight is its own alpha.
    /// An opaque accent over an opaque glyph gives exactly linear
    /// color interpolation. Empty if no accent color is set.
    private var accentLabels: [UILabel] = []

    /// The route of the VoiceOver three-finger gesture from the header.
    ///
    /// The headers layer is a separate accessibility element, and VoiceOver focus
    /// may rest on it; without a route, a three-finger swipe from the header would not
    /// page through the sections. The handler is set by the panorama controller: it turns the
    /// direction into a section step and writes `contentOffset` itself (the single-writer
    /// contract). `nil` means the gesture goes to the system.
    var accessibilityScrollHandler: ((UIAccessibilityScrollDirection) -> Bool)?

    /// The last progress from ``apply(progress:activeIndex:)``, so the state can be
    /// reapplied after layout, a style change, or a Reduce Motion change.
    private var storedProgress: CGFloat = 0

    /// The last active section index from ``apply(progress:activeIndex:)``.
    private var storedActiveIndex: Int = 0

    /// The index for which `accessibilityLabel` has already been set.
    private var accessibilityTitleIndex: Int = -1

    // MARK: - Lifecycle

    /// Creates the headers layer.
    ///
    /// - Parameters:
    ///   - titles: The section titles in reading order.
    ///   - style: The headers style.
    public init(titles: [String], style: Style = Style()) {
        self.titles = titles
        self.style = style
        super.init(frame: .zero)
        commonInit()
    }

    /// Not supported: the view is created only from code.
    @available(*, unavailable, message: "Use init(titles:style:)")
    public required init?(coder: NSCoder) {
        fatalError("TesseraPanoHeaderView does not support loading from Interface Builder")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func commonInit() {
        backgroundColor = .clear
        // The headers are a decorative layer above the content: touches must pass
        // through to the pager and the sections. VoiceOver still sees the element.
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

    // MARK: - Public API

    /// Replaces the set of headers.
    ///
    /// Recreates the labels and triggers layout, so the method may be called
    /// only outside `scrollViewDidScroll` (see the performance discipline in `docs/PANORAMA-IOS-DESIGN.md`).
    ///
    /// - Parameter titles: The section titles in reading order.
    public func setTitles(_ titles: [String]) {
        guard titles != self.titles else { return }
        self.titles = titles
        rebuildLabels()
        applyCurrentState()
    }

    /// Applies the swipe progress to the headers.
    ///
    /// Called from the pager's `scrollViewDidScroll` and changes **only**
    /// the labels' `alpha` and `transform`: no layout, no view creation,
    /// and no `contentOffset` writes (see the performance discipline in `docs/PANORAMA-IOS-DESIGN.md`).
    /// Additionally, at a section boundary the header's `accessibilityLabel` is updated
    /// so that VoiceOver reads the current section; this is not
    /// geometry and does not trigger a layout pass.
    ///
    /// The parameter contract:
    /// - `t` is the global progress `contentOffset.x / itemWidth`, already
    ///   normalized by the reading direction (`TesseraRTL.normalizedProgress`).
    ///   The integer part is the section index and the fractional part is the transition progress.
    /// - `activeIndex` is the index of the active section (the integer part of `t`). It is used
    ///   for the static Reduce Motion mode and the VoiceOver text; the continuous
    ///   transform/alpha are computed from `t`, so the headers stay smooth
    ///   even if the arguments disagree by a frame.
    ///
    /// With Reduce Motion on, motion is disabled: only the
    /// header at `activeIndex` is shown, the others are hidden, and there is no shift.
    ///
    /// - Parameters:
    ///   - t: The pager's progress in reading order.
    ///   - activeIndex: The index of the active section.
    public func apply(progress t: CGFloat, activeIndex: Int) {
        storedProgress = t
        storedActiveIndex = activeIndex
        applyCurrentState()
    }

    // MARK: - Pure math (public for contract tests)

    /// A header's alpha by its phase.
    ///
    /// The keyframes in `docs/PANORAMA-IOS-DESIGN.md`:
    ///
    /// ```
    /// 0 → 0, 0.5 → 1, 1 → 0
    /// ```
    ///
    /// Piecewise-linear interpolation (`x` is the argument clamped to `0...1`):
    ///
    /// ```
    /// x ≤ 0.5:  alpha = 2x
    /// x > 0.5:  alpha = 2 − 2x
    /// ```
    ///
    /// The peak falls exactly on phase 0.5, the moment the section is
    /// at the center of the view. At the edges of the phase, the header is fully transparent: the neighboring
    /// section has not yet entered (or has already left).
    ///
    /// The function is pure: it reads no view state, does not require the main thread,
    /// and has no side effects. Defensive cases: `NaN` gives `0` and infinities
    /// are clamped to the bounds.
    ///
    /// - Parameter frac: The header's phase (`0...1`; values outside the range
    ///   are clamped).
    /// - Returns: The alpha in `0...1`.
    public static func keyframeAlpha(progress frac: CGFloat) -> CGFloat {
        guard !frac.isNaN else { return 0 }

        let x = min(max(frac, 0), 1)
        if x <= 0.5 {
            return 2 * x
        }
        return 2 - 2 * x
    }

    /// A header's horizontal shift by its phase.
    ///
    /// The keyframes:
    ///
    /// ```
    /// 0 → −travel/2, 0.5 → 0, 1 → +travel/2
    /// ```
    ///
    /// The formula (linear interpolation, `x` is the argument clamped to `0...1`):
    ///
    /// ```
    /// offset = (x − 0.5) · travel
    /// ```
    ///
    /// At keyframe 0.5 (the active header) the shift is zero: the label stays in its
    /// place; the maximum deviation of `±travel/2` is reached at the edges, where
    /// alpha is already zero. The sign of the direction is set by the caller: in RTL the shift
    /// is mirrored because the "next section" arrives from the left.
    ///
    /// The function is pure; `NaN` gives `0`, infinities are clamped to the bounds,
    /// and a negative `travel` simply flips the sign of the shift.
    ///
    /// - Parameters:
    ///   - frac: The header's phase (`0...1`; values outside the range are clamped).
    ///   - travel: The full range of the shift in points.
    /// - Returns: The horizontal shift in points.
    public static func keyframeOffset(progress frac: CGFloat, travel: CGFloat) -> CGFloat {
        guard !frac.isNaN else { return 0 }

        let x = min(max(frac, 0), 1)
        return (x - 0.5) * travel
    }

    /// The phase of the header of section `index` for progress `t`.
    ///
    /// `phase = 0.5 + (index − t) / 2`; at keyframe 0.5 the label stands at the center.
    /// The phase step between neighboring sections is 0.5, so already the second neighboring
    /// section is fully transparent.
    private static func phase(index: Int, progress t: CGFloat) -> CGFloat {
        0.5 + (CGFloat(index) - t) * 0.5
    }

    /// The accent color weight of the header of section `index` at progress `t`.
    ///
    /// `weight = max(0, 1 − |index − t|)` is the section's "activity"; it matches
    /// ``keyframeAlpha(progress:)`` of its phase. The visible color of the header is
    /// `lerp(textColor, activeTextColor, weight)`.
    ///
    /// - Parameters:
    ///   - index: The section index in reading order.
    ///   - t: The progress in reading order.
    /// - Returns: The weight in `0...1`.
    static func activeColorWeight(index: Int, progress t: CGFloat) -> CGFloat {
        keyframeAlpha(progress: phase(index: index, progress: t))
    }

    // MARK: - Applying state

    private func applyCurrentState() {
        guard !labels.isEmpty else { return }

        let activeIndex = clampedIndex(storedActiveIndex)

        guard !isReduceMotionEnabled() else {
            applyStaticState(activeIndex: activeIndex)
            return
        }

        // Progress goes beyond the strip only on bounce. Clamp the fractional part
        // so the edge header does not fade during the elastic bounce.
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

            // Strictly only alpha/transform: no geometry or layout.
            label.alpha = alpha
            label.transform = CGAffineTransform(translationX: direction * offset, y: 0)
            // The accent weight is the header's "activity": the same phase function as
            // the alpha (1 at an integer t of its own section, 0 for a neighbor). Alpha only.
            if accentLabels.indices.contains(index) {
                accentLabels[index].alpha = Self.activeColorWeight(index: index, progress: progress)
            }
        }

        // The only thing apply touches besides alpha/transform is the text of the
        // accessibility element when the active section changes. This is neither
        // layout nor geometry; the update happens only at a section
        // boundary, not on every frame.
        updateAccessibilityTitle(for: activeIndex)
    }

    /// The static state for Reduce Motion: only the active header,
    /// with no shift or fades.
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

    /// Recomputes `accessibilityLabel` only when the active section changes,
    /// so the accessibility tree is not touched on every scroll frame.
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

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()

        guard !labels.isEmpty else { return }

        let insets = resolvedContentInsets()
        let content = bounds.inset(by: insets)
        let width = max(content.width, 0)
        let height = max(content.height, 0)

        for label in labels {
            // Frame and transform must not be mixed (UIKit does not guarantee
            // the result), so the shift is reset for the duration of layout
            // and reapplied after the frame is set, from the saved
            // progress. Layout happens outside scrollViewDidScroll.
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

    /// The insets with the layout direction taken into account: in RTL the left and right
    /// swap places so the header has the same "leading" edge.
    private func resolvedContentInsets() -> UIEdgeInsets {
        var insets = style.contentInsets
        if effectiveUserInterfaceLayoutDirection == .rightToLeft {
            // Swap through a local variable: two direct inout accesses
            // to properties of the same struct violate Swift's exclusivity.
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

    // MARK: - Labels

    private func rebuildLabels() {
        labels.forEach { $0.removeFromSuperview() }
        // The accent copies lie inside the old labels and leave together with them.
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

    /// The header label: visual only, hidden from VoiceOver.
    private static func makeLabel(text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textAlignment = .natural
        label.isAccessibilityElement = false
        label.isUserInteractionEnabled = false
        return label
    }

    /// Creates or removes the accent copies of the labels under ``Style/activeTextColor``.
    ///
    /// Called when the labels are recreated and when the style changes, outside scrolling.
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

    /// The label typography (the same for the main and the accent label, except for color).
    private static func configure(
        _ label: UILabel,
        font: UIFont,
        color: UIColor,
        numberOfLines: Int
    ) {
        label.font = font
        // The font comes from UIFontMetrics/preferredFont, so the label
        // recomputes it itself when the Dynamic Type category changes.
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = numberOfLines
        label.textAlignment = .natural
    }

    // MARK: - Accessibility

    /// The VoiceOver three-finger swipe with focus on the header.
    ///
    /// The gesture goes to ``accessibilityScrollHandler`` (the panorama controller); without a
    /// handler, or if it declines, to the system.
    ///
    /// - Parameter direction: The VoiceOver gesture direction.
    /// - Returns: `true` if the gesture was handled.
    public override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        if let accessibilityScrollHandler, accessibilityScrollHandler(direction) {
            return true
        }
        return super.accessibilityScroll(direction)
    }

    /// The headers font for the current Dynamic Type category.
    ///
    /// - if ``Style/baseFont`` is set, `UIFontMetrics` scales it
    ///   (integration with `TesseraPanoramaStyle.headerFont`);
    /// - otherwise the system `preferredFont(forTextStyle:)` is used.
    private var scaledFont: UIFont {
        let metrics = UIFontMetrics(forTextStyle: style.textStyle)
        guard let baseFont = style.baseFont else {
            return UIFont.preferredFont(forTextStyle: style.textStyle, compatibleWith: traitCollection)
        }
        return metrics.scaledFont(for: baseFont, compatibleWith: traitCollection)
    }

    // MARK: - System changes

    /// Reduce Motion was turned on or off: reapply the saved progress.
    @objc private func reduceMotionStatusDidChange() {
        applyCurrentState()
    }

    /// The Dynamic Type text size changed: the labels need a new layout.
    /// The fonts themselves are updated by `adjustsFontForContentSizeCategory`.
    @objc private func contentSizeCategoryDidChange() {
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
}

/// The architectural name of the layer from `docs/PANORAMA-IOS-DESIGN.md`.
/// It stays internal: the public type carries the `Tessera` prefix.
typealias PanoHeaderView = TesseraPanoHeaderView
