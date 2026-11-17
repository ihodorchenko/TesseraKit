// The Panorama delegate.
// Design document: docs/PANORAMA-IOS-DESIGN.md (conceptual architecture:
// TesseraPanoramaDelegate has didShowSection and didChangeProgress; core geometry
// and math: a single progress t, no layout in scrollViewDidScroll).

#if canImport(UIKit)
import UIKit

/// Observes the state of the panorama.
///
/// The delegate only reads state: `contentOffset` is written exclusively by the panorama's
/// gesture and the controller's programmatic transition (see the performance rule in
/// docs/PANORAMA-IOS-DESIGN.md and the single-writer invariant in
/// docs/CORE-IOS-DESIGN.md). Returning values or writing the offset from
/// callbacks is not allowed because it creates a feedback loop: the background and headers are already
/// animated from the same `t`.
///
/// All methods are called on the main thread. Both methods are optional events:
/// the extension below provides empty default implementations, so a delegate
/// may implement only the events it needs.
public protocol TesseraPanoramaDelegate: AnyObject {

    /// The panorama showed the section at `index`.
    ///
    /// The index is in reading order: `0` is the first section for the user,
    /// regardless of LTR/RTL (see the RTL notes in the design document). Called when a transition
    /// completes (by gesture or programmatically) and the section at `index` becomes active;
    /// convenient for announcing the section title (see the VoiceOver notes in the design document) and for
    /// external analytics.
    ///
    /// - Parameters:
    ///   - panorama: The panorama that emitted the event.
    ///   - index: The index of the shown section in reading order.
    func panorama(_ panorama: TesseraPanoramaViewController, didShowSectionAt index: Int)

    /// The continuous scroll progress changed.
    ///
    /// The value is normalized by the reading direction (see the RTL notes in the design document):
    /// `0` is the first section and `sectionCount - 1` is the last. The integer part is
    /// the section index and the fractional part is the transition progress; the section step is
    /// `itemWidth = screenWidth − peek` (see the section width notes in the design document).
    /// When pulling past an edge (`bounce`) the value may fall outside the
    /// range; the consumer decides how to clamp it.
    ///
    /// The method is called from `scrollViewDidScroll`; at that point only
    /// `frame`/`transform`/`alpha` change and no layout is triggered
    /// (see the performance rule in the design document).
    ///
    /// - Parameters:
    ///   - panorama: The panorama that emitted the event.
    ///   - t: The normalized progress `t = contentOffset.x / itemWidth`.
    func panorama(_ panorama: TesseraPanoramaViewController, didChangeProgress t: CGFloat)
}

public extension TesseraPanoramaDelegate {
    /// Default implementation: the delegate is not interested in section changes.
    func panorama(_ panorama: TesseraPanoramaViewController, didShowSectionAt index: Int) {}

    /// Default implementation: the delegate is not interested in progress.
    func panorama(_ panorama: TesseraPanoramaViewController, didChangeProgress t: CGFloat) {}
}
#endif
