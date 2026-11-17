// Appearance configuration of the pivot.
// Design document: docs/PIVOT-IOS-DESIGN.md (architecture:
// TesseraPivotStyle holds the header fonts/colors, the indicator style, and the strip mode),
// core math (continuous coloring by the distance from t), and
// accessibility and system integration (Dynamic Type, Reduce Motion, RTL).

#if canImport(UIKit)
import UIKit

/// The appearance of the pivot: the font and colors of the header strip, the indicator style,
/// the header width mode, and the large app title
/// (see docs/PIVOT-IOS-DESIGN.md).
///
/// A configuration struct with defaults for every field: creating
/// `TesseraPivotStyle()` is enough to get the system look. The style holds no state and
/// does not depend on the view hierarchy; it is a pure snapshot of settings. The component
/// reads it when applying it and when Dynamic Type changes.
///
/// - Note: Values are read on the main thread: colors and fonts are UIKit objects.
/// - Note: Reduce Motion is not part of the style: it is a system setting, not an
///   appearance preference. The component queries it through
///   ``TesseraAccessibility/isReduceMotionEnabled`` at the moment of the decision.
public struct TesseraPivotStyle {

    /// How the active header is highlighted (see docs/PIVOT-IOS-DESIGN.md).
    ///
    /// The choice affects only the visual highlight; the synchronization of the strip and
    /// the pager does not depend on it.
    public enum IndicatorStyle {
        /// An underline under the active header only.
        case underline

        /// An accent text color only: the active header is tinted with
        /// ``TesseraPivotStyle/activeColor`` and the neighboring ones are interpolated toward
        /// ``TesseraPivotStyle/inactiveColor`` by the distance from `t` (see the text coloring
        /// notes in the design document). There is no separate underline.
        case accentText

        /// An underline and an accent text color at the same time.
        case underlineAndText
    }

    /// The header width mode in the strip (see docs/PIVOT-IOS-DESIGN.md).
    ///
    /// A difference from Panorama: pivot headers have different widths, so the
    /// indicator is interpolated between their centers rather than by a constant step
    /// (see the important subtlety in the design document).
    public enum StripMode {
        /// The header width follows its text; the strip scrolls if the
        /// headers do not fit.
        case content

        /// The headers share the available width equally. At very large
        /// Dynamic Type sizes, the component may depart from the mode (truncation or
        /// falling back to `.content`), otherwise the headers would run together (see the Dynamic Type notes in the design document);
        /// the style itself remains the user's request.
        case fill
    }

    /// The base font of the strip headers.
    ///
    /// The default is the system semibold 17 pt, that is, the base size of
    /// `UIFont.TextStyle.headline`. This is deliberately a base, unscaled
    /// font: the component scales it for the current Dynamic Type category
    /// through `UIFontMetrics(forTextStyle:)` with ``titleTextStyle`` and recomputes it
    /// when the category changes (see the Dynamic Type notes in docs/PIVOT-IOS-DESIGN.md).
    ///
    /// If you pass an already scaled font, it will be scaled
    /// again; pass the base size for precise control.
    public var titleFont: UIFont

    /// The text style whose metrics are used for Dynamic Type
    /// (see the Dynamic Type notes in docs/PIVOT-IOS-DESIGN.md).
    ///
    /// Determines how ``titleFont`` grows when the system text size
    /// increases. The default is `.headline`, a semantically appropriate style for
    /// strip headers.
    public var titleTextStyle: UIFont.TextStyle

    /// The color of the active header and the indicator.
    ///
    /// The default is `.systemBlue`. With `.accentText` and `.underlineAndText`
    /// this color is
    /// the "accent pole" toward which the colors of neighboring headers are interpolated
    /// by the distance from `t` (see the text coloring notes in the design document).
    public var activeColor: UIColor

    /// The color of an inactive header.
    ///
    /// The default is `.systemGray`. Intermediate values are obtained by
    /// interpolating between ``activeColor`` and this color.
    public var inactiveColor: UIColor

    /// How the active header is highlighted. The default is `.underline`.
    public var indicatorStyle: IndicatorStyle

    /// The header width mode in the strip. The default is `.content`.
    public var stripMode: StripMode

    /// The large app title above the strip
    /// (see the large app title notes in docs/PIVOT-IOS-DESIGN.md).
    ///
    /// `nil` means not shown: the component fills the screen with only the strip and
    /// the content, and the large title can be integrated with
    /// `navigationItem.largeTitle` from outside (see the app title notes in the design document).
    /// A string is the built-in static title of the Windows Phone behavior.
    public var appTitle: String?

    /// Creates a pivot style; every parameter has a system default.
    ///
    /// - Parameters:
    ///   - titleFont: The base (unscaled) font of the headers,
    ///     the system semibold 17 pt by default.
    ///   - titleTextStyle: The Dynamic Type metrics style, `.headline` by default.
    ///   - activeColor: The color of the active header and the indicator,
    ///     `.systemBlue` by default.
    ///   - inactiveColor: The color of an inactive header,
    ///     `.systemGray` by default.
    ///   - indicatorStyle: How the active header is highlighted,
    ///     `.underline` by default.
    ///   - stripMode: The header width mode, `.content` by default.
    ///   - appTitle: The large app title; `nil` (the default) means
    ///     not shown.
    public init(
        titleFont: UIFont = .systemFont(ofSize: 17, weight: .semibold),
        titleTextStyle: UIFont.TextStyle = .headline,
        activeColor: UIColor = .systemBlue,
        inactiveColor: UIColor = .systemGray,
        indicatorStyle: IndicatorStyle = .underline,
        stripMode: StripMode = .content,
        appTitle: String? = nil
    ) {
        self.titleFont = titleFont
        self.titleTextStyle = titleTextStyle
        self.activeColor = activeColor
        self.inactiveColor = inactiveColor
        self.indicatorStyle = indicatorStyle
        self.stripMode = stripMode
        self.appTitle = appTitle
    }
}
#endif
