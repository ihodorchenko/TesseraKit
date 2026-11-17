//
//  TesseraPivotHeaderIndicator.swift
//  TesseraPivot
//
//  The indicator of the pivot's active header.
//  Contract: docs/PIVOT-IOS-DESIGN.md (architecture: header strip +
//  indicator; core math: indicator = lerp(centers of neighboring
//  headers), with coloring by the distance from `t`; performance:
//  the indicator is a separate layer driven only by a transform; accessibility
//  «Accessibility» (RTL, Reduce Motion).
//
//  Performance discipline: on the scroll hot path only `transform` changes.
//  The base position (`bounds`/`center`) is set once
//  per strip layout pass, in `placeBar(inStripBounds:)`. The pure functions
//  read no state and do not require the main thread: they are used by both the strip and
//  the contract tests.
//

#if canImport(UIKit)
import UIKit

/// An underline under the strip's active header.
///
/// A separate layer above the headers' `UICollectionView` (see the performance notes in the design document):
/// cells are reused and recolored, while the indicator lives on its own and can therefore
/// move continuously between headers of different widths (the important subtlety:
/// the centers are interpolated, not `t × constWidth`).
///
/// The position changes only through ``placeBar(inStripBounds:)`` (the layout pass)
/// and ``move(toCenterX:)`` (`transform` on the hot path). The size of `bounds` is
/// not touched on the hot path, and `setNeedsLayout` is not called.
///
/// Usage: only through ``TesseraPivotHeaderStripView``, which owns the
/// strip geometry and the cell content. The public surface of the indicator itself
/// is limited to its appearance (color, thickness, width) and pure functions for tests.
///
/// ## Reduce Motion
///
/// The indicator does not animate on its own: it follows the user's gesture while the
/// finger moves the pager. Reduce Motion therefore does not disable it;
/// only self-driven animations are disabled (for example, the strip's auto-centering,
/// see `TesseraPivotHeaderStripView.scrollToCenter(index:animated:)`).
public final class TesseraPivotHeaderIndicator: UIView {

    // MARK: - Pure functions (the math)

    /// The indicator center for progress `t` (see docs/PIVOT-IOS-DESIGN.md).
    ///
    /// `indicatorCenter = lerp(center[i], center[i + 1], frac)`, where
    /// `i = clamp(floor(t), 0, count - 2)`. Header widths differ, so
    /// the centers are interpolated, not a width multiplier: otherwise the indicator
    /// "drifts" away from the text in the middle of a swipe.
    ///
    /// Bounds and protection against garbage values:
    /// - `centers` is empty: `0` (there is no strip, the indicator is hidden);
    /// - a single center (`count < 2`): that center, since there is nothing to interpolate with;
    /// - `t <= 0` gives the first center and `t >= count - 1` the last: during bounce
    ///   the progress goes out of range, and the indicator must not move past the outermost
    ///   headers;
    /// - `NaN` gives the first center (undefined progress means the start of the strip);
    /// - infinities are clamped to the bounds, so the conversion to `Int` below
    ///   never overflows.
    ///
    /// The fractional part is taken from the **clamped** progress: at `t = count - 1` this
    /// gives exactly the last center, not "the first of the last pair", which is the typical
    /// mistake of taking `frac(t)` of an unclamped `t`.
    ///
    /// - Parameters:
    ///   - centers: The header centers in the strip's content coordinates, in
    ///     reading order (already mirrored in RTL; see `TesseraPivotHeaderStripView`).
    ///   - t: The progress normalized by the reading direction
    ///     `contentOffset.x / pageWidth`.
    /// - Returns: The indicator center in the same coordinates as `centers`.
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

    /// How "active" a header is by its distance from the progress (the text
    /// coloring weight).
    ///
    /// `factor = 1 - clamp(|distance| / span, 0, 1)`; `span` is `1` by default,
    /// a distance in page index units. `distance` is computed as
    /// `index - t` (the sign does not matter, the absolute value is taken). Returns `1` at the point `t`
    /// and `0` at a distance of `span` and beyond, so the strip smoothly "hands over the accent"
    /// from the outgoing header to the incoming one rather than switching abruptly.
    ///
    /// Defensive cases: `span <= 0` means "nothing to blur": `1` at zero
    /// distance, otherwise `0`; `NaN` in any argument and an infinite distance give
    /// `0` (an unknown header is considered inactive).
    ///
    /// - Parameters:
    ///   - distance: The header's distance from the progress in index units
    ///     (`index - t`).
    ///   - span: The highlight radius; values `<= 0` are treated as "no
    ///     blurring".
    /// - Returns: A coefficient in `0...1`, where `1` is the full accent color.
    public static func blendFactor(distanceFromProgress distance: CGFloat, span: CGFloat = 1) -> CGFloat {
        guard !distance.isNaN, !span.isNaN else { return 0 }
        guard span > 0 else { return distance == 0 ? 1 : 0 }
        guard !distance.isInfinite else { return 0 }

        let ratio = abs(distance) / span
        return max(0, 1 - min(ratio, 1))
    }

    // MARK: - Appearance

    /// The underline color is the style's accent color (the indicator style is
    /// an underline and/or an accent text color).
    ///
    /// The strip sets it from ``TesseraPivotHeaderStripView/activeColor``. Dynamic
    /// system colors work as is: the underline is the view's background, and the theme is changed by
    /// UIKit.
    public var activeColor: UIColor {
        didSet {
            guard activeColor != oldValue else { return }
            backgroundColor = activeColor
        }
    }

    /// The underline width in points.
    ///
    /// The underline does not copy the width of the active header: its width is
    /// fixed, and only the center and thickness change. A size change
    /// is applied on the strip's next layout pass (`setNeedsLayout` is marked
    /// on the superview); the size does not change on the swipe hot path.
    public var barWidth: CGFloat = 24 {
        didSet {
            guard barWidth != oldValue else { return }
            superview?.setNeedsLayout()
        }
    }

    /// The underline thickness in points (3 pt by default, the recognizable thickness
    /// of the Windows Phone accent).
    public var barHeight: CGFloat = 3 {
        didSet {
            guard barHeight != oldValue else { return }
            superview?.setNeedsLayout()
        }
    }

    // MARK: - Initialization

    /// Creates an indicator with an accent color.
    ///
    /// - Parameter activeColor: The underline color; `.systemBlue` by default,
    ///   the default of ``TesseraPivotStyle/activeColor``.
    public init(activeColor: UIColor = .systemBlue) {
        self.activeColor = activeColor
        super.init(frame: .zero)
        configure()
    }

    /// Creates an indicator from an archive/storyboard.
    ///
    /// - Parameter coder: The archive decoder.
    public required init?(coder: NSCoder) {
        self.activeColor = .systemBlue
        super.init(coder: coder)
        configure()
    }

    /// Common setup: the layer is decorative, catches no events, and is
    /// not part of the accessibility tree; VoiceOver reads the header buttons,
    /// not the underline.
    private func configure() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = activeColor
        layer.cornerRadius = barHeight / 2
        isHidden = true
    }

    // MARK: - Positioning (an internal contract with the strip)

    /// Lays the underline out at its base position inside the strip.
    ///
    /// Called only from the layout pass of ``TesseraPivotHeaderStripView``. `bounds`/`center` are
    /// allowed here; after that ``move(toCenterX:)`` shifts the
    /// underline with a single `transform` and layout is not touched again.
    ///
    /// - Parameter stripBounds: The strip's `bounds` in its own coordinate system:
    ///   the indicator is pressed to the bottom edge.
    internal func placeBar(inStripBounds stripBounds: CGRect) {
        transform = .identity
        bounds = CGRect(x: 0, y: 0, width: barWidth, height: barHeight)
        center = CGPoint(
            x: barWidth / 2,
            y: stripBounds.maxY - barHeight / 2
        )
        layer.cornerRadius = barHeight / 2
    }

    /// Shifts the underline to the center `centerX` in the strip's coordinates.
    ///
    /// Only `transform`: no `frame`, no `bounds`, no `setNeedsLayout`.
    /// Since the base position after ``placeBar(inStripBounds:)`` is the left edge
    /// (`origin.x == 0`), the shift `centerX - barWidth / 2` puts the underline's
    /// center exactly at `centerX`.
    ///
    /// - Parameter centerX: The center in the strip's coordinates (usually from
    ///   ``indicatorCenter(centers:progress:)``, converted to the strip's current
    ///   `contentOffset`).
    internal func move(toCenterX centerX: CGFloat) {
        let translation = CGAffineTransform(translationX: centerX - barWidth / 2, y: 0)
        guard transform != translation else { return }
        transform = translation
    }
}
#endif
