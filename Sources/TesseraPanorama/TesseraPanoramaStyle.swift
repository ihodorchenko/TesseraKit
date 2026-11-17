// Appearance configuration of the panorama.
// Design document: docs/PANORAMA-IOS-DESIGN.md (conceptual architecture:
// TesseraPanoramaStyle: section width (peek), parallax factor, header fonts/colors,
// background behavior), core geometry and math
// (itemWidth = screenWidth − peek, peek 16–64 pt; backgroundOffset =
// offset.x × parallaxFactor, typically 0.4–0.6), accessibility (Dynamic Type,
// Reduce Motion) and the MVP scope (in v1, a single image for the whole background).

#if canImport(UIKit)
import UIKit

/// The appearance of the panorama: the width of the "canvas" with its peek, the parallax factor,
/// header styling, and background behavior (see docs/PANORAMA-IOS-DESIGN.md).
///
/// A configuration struct with defaults for every field: creating
/// `TesseraPanoramaStyle()` is enough to get the system look. The style holds no state and
/// does not depend on the view hierarchy; it is a snapshot of settings that the component
/// reads when applying it.
///
/// - Note: Values are read on the main thread: colors and fonts are UIKit objects.
/// - Note: Reduce Motion is not part of the style: it is a system setting, not an
///   appearance preference. When `isReduceMotionEnabled` is on, the component disables
///   parallax and header animations, leaving plain snapping
///   (see docs/PANORAMA-IOS-DESIGN.md).
public struct TesseraPanoramaStyle {

    /// The behavior of the panorama background (see docs/PANORAMA-IOS-DESIGN.md).
    ///
    /// In v1 there is one background for the whole panorama: an arbitrary background for each section
    /// is deliberately out of scope. The enumeration intentionally
    /// has no "per-section background" case.
    public enum BackgroundBehavior {
        /// No background is drawn: the system/transparent background shows behind the sections.
        case none

        /// A single image for the whole panorama background.
        ///
        /// `nil` is allowed until the image is ready: the background layer stays
        /// empty (transparent), and the panorama looks the same as with `.none`.
        /// Parallax draws nothing until an image is set.
        case image(UIImage?)

        /// Whether the behavior matches another one; images are compared by identity.
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

    /// The width of the zone that peeks at the next section on the side of the reading
    /// direction (the right in LTR), in points.
    ///
    /// The section width is computed as `itemWidth = screenWidth − peek`
    /// (see the section width notes in the design document), so the value is always kept in
    /// the range `16...64`: the clamp is applied in ``init(peek:parallaxFactor:headerFont:headerColor:headerActiveColor:backgroundBehavior:)``
    /// and on every later write. Non-finite values (`NaN`, `±∞`)
    /// are treated as the default `48`.
    public var peek: CGFloat {
        didSet { peek = Self.clampedPeek(peek) }
    }

    /// The multiplier of the background speed relative to the content.
    ///
    /// The background offset is `backgroundOffset = contentOffset.x × parallaxFactor`
    /// (see the background parallax notes in the design document: `0 < parallaxFactor < 1`, typically
    /// `0.4–0.6`). The value is always kept within the open interval `(0, 1)`,
    /// in practice `0.01...0.99`: the clamp is applied in the initializer and on
    /// every later write. Non-finite values (`NaN`, `±∞`) are treated
    /// as the default `0.5`.
    ///
    /// - Note: `0` (the background stands still) and `1` (the background moves with the content) are unreachable:
    ///   that is no longer parallax. Disabling parallax is the job of
    ///   Reduce Motion, not of the style.
    public var parallaxFactor: CGFloat {
        didSet { parallaxFactor = Self.clampedParallaxFactor(parallaxFactor) }
    }

    /// The base font of the section headers.
    ///
    /// The default is the system bold 34 pt (the base size of `.largeTitle`).
    /// This is deliberately an unscaled font: the component scales it for the
    /// current Dynamic Type category through `UIFontMetrics` and recomputes it when the
    /// category changes (see the Dynamic Type notes in the design document).
    ///
    /// If you pass an already scaled font, it will be scaled
    /// again; pass the base size for precise control.
    public var headerFont: UIFont

    /// The color of a section header in the inactive state.
    ///
    /// The default is `.label`: the color adapts to the light and dark themes.
    /// On a background image, the component ensures header contrast
    /// (see the background notes in the design document).
    public var headerColor: UIColor

    /// The accent color of the current (active) section's header.
    ///
    /// The default is `.systemBlue`. The color is interpolated by the progress `t`
    /// together with the header fade: at an integer `t` the active header is fully
    /// tinted with this color, and during a transition the outgoing header smoothly returns
    /// to ``headerColor`` while the incoming one gains the accent. If you set the same value
    /// as ``headerColor``, the headers are not highlighted by color.
    public var headerActiveColor: UIColor

    /// The background behavior. The default is `.none`.
    public var backgroundBehavior: BackgroundBehavior

    /// The behavior of the system adjustment of the insets of the horizontal strip of sections
    /// (see the navigation bar notes in the design document).
    ///
    /// The default is `.never`: the panorama sets the strip's frame (under the layer of
    /// headers), and the section controllers get the safe area themselves; the background
    /// lies under the bar across the full height of the view. Other values are for when the host wants
    /// UIKit to inset the content from the bar/home indicator itself.
    ///
    /// - Important: Snapping geometry and the progress `t` are computed from `contentOffset`
    ///   without the horizontal `adjustedContentInset`: values that produce
    ///   side insets (`.always`, and in landscape with a cutout also
    ///   `.automatic`/`.scrollableAxes`) shift the strip by the side
    ///   safe area. Keep `.never` for a full-screen panorama.
    public var contentInsetAdjustmentBehavior: UIScrollView.ContentInsetAdjustmentBehavior

    /// The lower and upper bounds of ``peek`` (see the section width notes in the design document).
    private static let peekRange: ClosedRange<CGFloat> = 16...64

    /// The bounds of ``parallaxFactor``: the open interval `(0, 1)` from the design document
    /// (background parallax), represented by the closed `0.01...0.99`.
    static let parallaxFactorRange: ClosedRange<CGFloat> = 0.01...0.99

    /// The default of ``peek``; used for non-finite input.
    private static let defaultPeek: CGFloat = 48

    /// The default of ``parallaxFactor``; used for non-finite input.
    private static let defaultParallaxFactor: CGFloat = 0.5

    /// Creates a panorama style; every parameter has a system default.
    ///
    /// - Parameters:
    ///   - peek: The width of the zone peeking at the next section, `48` by default.
    ///     Values outside `16...64` are clamped to the nearest bound.
    ///   - parallaxFactor: The background parallax multiplier, `0.5` by default.
    ///     Values outside the open interval `(0, 1)` are clamped to the nearest
    ///     bound of `0.01...0.99`.
    ///   - headerFont: The base (unscaled) font of the headers, the
    ///     system bold 34 pt by default.
    ///   - headerColor: The color of an inactive header, `.label` by default.
    ///   - headerActiveColor: The accent color of the active header,
    ///     `.systemBlue` by default.
    ///   - backgroundBehavior: The background behavior, `.none` by default.
    ///   - contentInsetAdjustmentBehavior: The adjustment of the section strip's insets
    ///     to the safe area, `.never` by default.
    public init(
        peek: CGFloat = 48,
        parallaxFactor: CGFloat = 0.5,
        headerFont: UIFont = .systemFont(ofSize: 34, weight: .bold),
        headerColor: UIColor = .label,
        headerActiveColor: UIColor = .systemBlue,
        backgroundBehavior: BackgroundBehavior = .none,
        contentInsetAdjustmentBehavior: UIScrollView.ContentInsetAdjustmentBehavior = .never
    ) {
        // The clamp in the initializer is required: property observers are not called
        // on the first write in init, so without it the range invariant
        // would be broken until the first external assignment.
        self.peek = Self.clampedPeek(peek)
        self.parallaxFactor = Self.clampedParallaxFactor(parallaxFactor)
        self.headerFont = headerFont
        self.headerColor = headerColor
        self.headerActiveColor = headerActiveColor
        self.backgroundBehavior = backgroundBehavior
        self.contentInsetAdjustmentBehavior = contentInsetAdjustmentBehavior
    }

    /// Whether the style matches another one in every field.
    ///
    /// Lets the controller avoid reapplying the same style on every
    /// SwiftUI update. There is no public `Equatable`: the background image is compared
    /// by identity (`===`), not by content. That is enough to skip redundant work,
    /// but as general equality semantics it would be surprising.
    ///
    /// - Parameter other: The style to compare with.
    /// - Returns: `true` if applying `other` instead of `self` changes nothing.
    func isEquivalent(to other: TesseraPanoramaStyle) -> Bool {
        peek == other.peek
            && parallaxFactor == other.parallaxFactor
            && headerFont == other.headerFont
            && headerColor == other.headerColor
            && headerActiveColor == other.headerActiveColor
            && contentInsetAdjustmentBehavior == other.contentInsetAdjustmentBehavior
            && backgroundBehavior.isIdentical(to: other.backgroundBehavior)
    }

    /// Clamps ``peek`` to the range `16...64`; non-finite input becomes the default.
    private static func clampedPeek(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultPeek }
        return min(max(value, peekRange.lowerBound), peekRange.upperBound)
    }

    /// Clamps ``parallaxFactor`` to the interval `(0, 1)` (`0.01...0.99`);
    /// non-finite input becomes the default.
    private static func clampedParallaxFactor(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultParallaxFactor }
        return min(max(value, parallaxFactorRange.lowerBound), parallaxFactorRange.upperBound)
    }
}
#endif
