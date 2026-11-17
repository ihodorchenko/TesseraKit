// The Pivot delegate.
// Design document: docs/PIVOT-IOS-DESIGN.md (architecture:
// TesseraPivotDelegate has didSelectSection and didChangeProgress; synchronizing the
// strip and the pager: a single source of truth and a single writer of contentOffset).

#if canImport(UIKit)
import UIKit

/// Observes the state of the pivot.
///
/// The delegate only reads state: `contentOffset` is written exclusively by the pager's
/// gesture and the controller's programmatic transition on a header tap
/// (see the single-writer rule in docs/PIVOT-IOS-DESIGN.md). Returning
/// values or writing the offset from callbacks is not allowed because it creates a
/// feedback loop: the strip and the indicator are already animated from the same `t`.
///
/// All methods are called on the main thread. There are two required methods
/// (`didSelectSectionAt` and `didChangeProgress`); showing a section when a
/// transition completes is an optional event with an empty default implementation
/// (see docs/PIVOT-IOS-DESIGN.md).
public protocol TesseraPivotDelegate: AnyObject {

    /// The user selected a section by tapping its header in the strip.
    ///
    /// Called before the programmatic transition. The index is in reading order:
    /// `0` is the first section for the user, regardless of LTR/RTL
    /// (see the RTL notes in the design document). The component performs the transition itself
    /// (`setContentOffset(animated:)`), and the delegate does not need to, and must not,
    /// duplicate it.
    ///
    /// - Parameters:
    ///   - pivot: The pivot that emitted the event.
    ///   - index: The index of the selected section in reading order.
    func pivot(_ pivot: TesseraPivotViewController, didSelectSectionAt index: Int)

    /// The continuous scroll progress changed.
    ///
    /// The value is normalized by the reading direction (see the progress notes in the design document):
    /// `0` is the first section and `sectionCount - 1` is the last. The integer part is the
    /// section index and the fractional part is the transition progress. When pulling past an edge
    /// (`bounce`) the value may fall outside the range; the consumer
    /// decides how to clamp it.
    ///
    /// The method is called from `scrollViewDidScroll`; at that point only
    /// `frame`/`transform`/`alpha` change and no layout is triggered
    /// (see the performance rule in docs/PIVOT-IOS-DESIGN.md).
    ///
    /// - Parameters:
    ///   - pivot: The pivot that emitted the event.
    ///   - t: The normalized progress `t = contentOffset.x / pageWidth`.
    func pivot(_ pivot: TesseraPivotViewController, didChangeProgress t: CGFloat)

    /// The pivot finished a transition and is showing the section at `index`.
    ///
    /// The index is in reading order. Called when a transition completes
    /// (by gesture or tap), that is, when the strip and the content are already
    /// synchronized; convenient for announcing the section name
    /// (see the VoiceOver notes in the design document) and for external analytics.
    ///
    /// - Parameters:
    ///   - pivot: The pivot that emitted the event.
    ///   - index: The index of the shown section in reading order.
    func pivot(_ pivot: TesseraPivotViewController, didShowSectionAt index: Int)
}

public extension TesseraPivotDelegate {
    /// Default implementation: the delegate is not interested in section changes.
    ///
    /// The empty body lets a delegate subscribe only to selection and progress
    /// (see docs/PIVOT-IOS-DESIGN.md).
    func pivot(_ pivot: TesseraPivotViewController, didShowSectionAt index: Int) {}
}
#endif
