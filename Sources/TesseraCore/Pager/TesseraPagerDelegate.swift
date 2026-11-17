// Delegate of the TesseraCore pager.
// Design document: docs/CORE-IOS-DESIGN.md (key contracts:
// the progress invariant and the single writer of contentOffset; conceptual
// API surface: TesseraPagerDelegate has didShowPage and didChangeProgress).

#if canImport(UIKit)
import UIKit

/// Observes the state of `TesseraPagerViewController`.
///
/// The delegate only reads state: `contentOffset` is written exclusively by the pager's
/// gesture and the controller's programmatic transition
/// (see the single-writer contract in docs/CORE-IOS-DESIGN.md). Returning values or
/// writing the offset from callbacks is not allowed because it creates a feedback loop.
///
/// Both methods are called on the main thread. The default implementations are empty
/// so that a delegate can subscribe only to the event it needs.
public protocol TesseraPagerDelegate: AnyObject {
    /// The pager finished a transition and is showing the page at `index`.
    ///
    /// The index is in reading order: `0` is the first page for the user,
    /// regardless of LTR/RTL (normalized through `TesseraRTL`).
    /// Called when a transition completes
    /// (`scrollViewDidEndDecelerating` / `scrollViewDidEndScrollingAnimation`),
    /// and also after an instant `go(toPage:animated: false)`. Showing the initial
    /// page without a transition is not a separate event.
    ///
    /// - Parameters:
    ///   - pager: The pager that emitted the event.
    ///   - index: The index of the shown page in reading order.
    func pager(_ pager: TesseraPagerViewController, didShowPageAt index: Int)

    /// The continuous scroll progress changed.
    ///
    /// The value is normalized by the reading direction
    /// (see the progress invariant in docs/CORE-IOS-DESIGN.md): `0` is the first
    /// page and `pageCount - 1` is the last. The integer part is the page index
    /// and the fractional part is the transition progress. When pulling past an edge (`bounce`) the value
    /// may fall outside the range; the consumer decides how to
    /// clamp it.
    ///
    /// The method is called from `scrollViewDidScroll`; no layout is
    /// performed at that point (see the performance discipline in docs/CORE-IOS-DESIGN.md).
    ///
    /// - Parameters:
    ///   - pager: The pager that emitted the event.
    ///   - t: The normalized progress `t = contentOffset.x / pageWidth`.
    func pager(_ pager: TesseraPagerViewController, didChangeProgress t: CGFloat)
}

public extension TesseraPagerDelegate {
    /// Default implementation: the delegate is not interested in page changes.
    func pager(_ pager: TesseraPagerViewController, didShowPageAt index: Int) {}

    /// Default implementation: the delegate is not interested in progress.
    func pager(_ pager: TesseraPagerViewController, didChangeProgress t: CGFloat) {}
}
#endif
