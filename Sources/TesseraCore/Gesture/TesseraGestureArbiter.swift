// TesseraGestureArbiter: parent-child gesture arbitration for TesseraCore.
// Design document: docs/CORE-IOS-DESIGN.md
// (key contracts: gesture arbitration; conceptual API surface).
//
// Scheme: the pager owns the horizontal axis (horizontalOwner) and the child
// scroll views own the vertical axis (verticalOwners). The pager decides whether to begin its own pan
// by the dominant axis in `gestureRecognizerShouldBegin`; for the duration of a horizontal
// gesture the children's scrolling is blocked and then restored.
//
// Performance discipline: no layout operations here.
// The methods only read velocity/translation and change the `isScrollEnabled` flag.

import UIKit

/// The dominant axis of a gesture in parent-child arbitration.
///
/// See "gesture arbitration" in docs/CORE-IOS-DESIGN.md: horizontal motion goes to the pager,
/// vertical motion goes to the child scroll view.
public enum TesseraGestureAxis: Equatable {
    /// Horizontal motion: the owning pager handles the gesture.
    case horizontal
    /// Vertical motion: the child scroll views handle the gesture.
    case vertical
}

/// A parent-child gesture arbiter: splits a gesture between the horizontal
/// pager and the vertical children by the dominant axis.
///
/// Contract (docs/CORE-IOS-DESIGN.md, "gesture arbitration"): the pager scrolls only
/// horizontally and the children only vertically; the decision is made by the dominant axis
/// in `gestureRecognizerShouldBegin`, not after the fact. Several
/// children are supported (for example, a grid and a list on one StartScreen).
///
/// Usage.
///
/// - Important: **Do not assign the arbiter as the delegate of a `UIScrollView` pan.**
///   The scroll view itself must remain the delegate of its built-in
///   `panGestureRecognizer`: the line `scrollView.panGestureRecognizer.delegate = arbiter`
///   raises a UIKit exception (`NSInvalidArgumentException`: "UIScrollView's
///   built-in pan gesture recognizer must have its scroll view as its
///   delegate"). The TesseraKit pager is built on `UIScrollView`, so
///   that route is closed to it.
///
/// The working scheme (used by Pivot, Panorama, and StartScreen): subscribe to the scroll view's
/// pan additively via `addTarget`, which leaves its delegate and
/// internal gesture handling untouched, and decide the axis in the `.began` state
/// with the pure function ``axisDecision(forVelocity:)``. For a horizontal gesture, create
/// an arbiter and block the children, then restore them when the gesture ends:
///
/// ```swift
/// // Once, when the pager's scroll view is known:
/// pagerScrollView.panGestureRecognizer.addTarget(
///     self, action: #selector(pagerPanDidChange(_:)))
///
/// @objc private func pagerPanDidChange(_ pan: UIPanGestureRecognizer) {
///     switch pan.state {
///     case .began:
///         let velocity = pan.velocity(in: pan.view)
///         let vector = velocity == .zero ? pan.translation(in: pan.view) : velocity
///         guard TesseraGestureArbiter.axisDecision(forVelocity: vector) == .horizontal
///         else { return } // vertical goes to the children, block nothing
///         let arbiter = TesseraGestureArbiter(horizontalOwner: pagerScrollView,
///                                             verticalOwners: [grid, list])
///         arbiter.prepareForHorizontalScroll() // block the children
///         gestureArbiter = arbiter             // the owner retains the arbiter
///     case .ended, .cancelled, .failed:
///         gestureArbiter?.endHorizontalScroll() // restore the children
///         gestureArbiter = nil
///     default:
///         break
///     }
/// }
/// ```
///
/// `UIGestureRecognizer` holds its targets weakly (verified by the test
/// `TesseraGestureTargetRetentionTests`), so `addTarget(self, …)` does not
/// create a retain cycle and the owner's `deinit` is reachable.
///
/// ``gestureRecognizerShouldBegin(_:)`` (the decision before the gesture begins)
/// applies only where the delegate can be assigned legitimately: for the horizontal owner's
/// **own** `UIPanGestureRecognizer`, or
/// from an override of `gestureRecognizerShouldBegin(_:)` in a `UIScrollView`
/// subclass (a `UIView` method called for gestures of that view; it needs no delegate),
/// for example `return arbiter?.shouldBegin(gestureRecognizer) ??
/// super.gestureRecognizerShouldBegin(gestureRecognizer)`.
///
/// The scroll view does not retain the arbiter, so the owner (the pager or a controller)
/// must retain it. The arbiter holds the scroll views strongly, so with
/// lazily loaded pages it is convenient to create it only for the duration of a gesture.
///
/// All methods are intended for the main thread: UIKit properties and gestures are read
/// and changed only there. No layout is performed.
public final class TesseraGestureArbiter: NSObject, UIGestureRecognizerDelegate {

    // MARK: - Owners

    /// The horizontal owner: the pager whose pan the arbiter lets through or rejects.
    private let horizontalOwner: UIScrollView

    /// The vertical children, stored in registration order without duplicates;
    /// the horizontal owner is excluded at initialization.
    private let verticalOwners: [UIScrollView]

    /// A snapshot of the children's `isScrollEnabled` for the duration of a horizontal gesture.
    /// `nil` means no horizontal gesture is in progress and nothing is blocked.
    private var savedChildStates: [(view: UIScrollView, wasScrollEnabled: Bool)]?

    // MARK: - Initialization

    /// Creates an arbiter for the "horizontal pager, vertical children" pair.
    ///
    /// - Parameters:
    ///   - horizontalOwner: The pager's scroll view, which scrolls only horizontally.
    ///   - verticalOwners: The child scroll views that scroll vertically. Order is
    ///     preserved; duplicates and `horizontalOwner` itself are dropped so that the arbiter
    ///     never disables the owner's scrolling.
    ///
    /// No pan delegate is assigned, and none must be assigned for the built-in
    /// `UIScrollView` pan (UIKit throws an exception); see the recipe in the type description.
    public init(horizontalOwner: UIScrollView, verticalOwners: [UIScrollView]) {
        self.horizontalOwner = horizontalOwner

        // Register the children: only unique instances, and never the owner itself.
        var registered: [UIScrollView] = []
        registered.reserveCapacity(verticalOwners.count)
        for child in verticalOwners {
            guard child !== horizontalOwner else { continue }
            guard !registered.contains(where: { $0 === child }) else { continue }
            registered.append(child)
        }
        self.verticalOwners = registered

        super.init()
    }

    // MARK: - Axis decision

    /// Determines the dominant axis of a gesture from its velocity vector.
    ///
    /// A pure function with no state and no UIKit side effects; it is the main subject of the
    /// arbitration contract tests.
    ///
    /// Rule: horizontal if `|dx| > |dy|`; vertical if `|dx| < |dy|`.
    /// **When the magnitudes are equal (including zero velocity), horizontal
    /// wins.** This is a deliberate default: without data on dominance the gesture
    /// stays with the pager instead of getting stuck on a child. The sign of the velocity does not matter;
    /// magnitudes are compared; the pager normalizes direction in RTL itself,
    /// which has no bearing on the axis choice.
    ///
    /// - Parameter velocity: The gesture's velocity vector (points per second or points;
    ///   only the relative size of the components matters).
    /// - Returns: `.horizontal` if `|dx| >= |dy|`; otherwise `.vertical`.
    public static func axisDecision(forVelocity velocity: CGPoint) -> TesseraGestureAxis {
        abs(velocity.x) >= abs(velocity.y) ? .horizontal : .vertical
    }

    // MARK: - UIGestureRecognizerDelegate

    /// The public "should the gesture begin" decision.
    ///
    /// For the horizontal owner's pan: if the dominant axis is vertical,
    /// returns `false`, so the pager does not begin the gesture and vertical scrolling
    /// stays with the children. Other gestures (the delegate may have been assigned to them too) are
    /// not restricted and the result is `true`.
    ///
    /// - Parameter gestureRecognizer: The recognizer to check.
    /// - Returns: `true` if the gesture may begin.
    public func shouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === horizontalOwner.panGestureRecognizer else {
            return true
        }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }

        let axis = TesseraGestureArbiter.axisDecision(forVelocity: effectiveVelocity(of: pan))
        return axis == .horizontal
    }

    /// The bridge to UIKit: `UIGestureRecognizerDelegate` calls exactly this method.
    /// The decision is delegated to the public `shouldBegin(_:)` so that the logic stays
    /// testable without substituting the protocol.
    ///
    /// Fires only if the arbiter is legitimately assigned as the gesture's delegate;
    /// for the built-in `UIScrollView` pan this is impossible (see the type description).
    @objc public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        shouldBegin(gestureRecognizer)
    }

    // MARK: - Blocking the children during a horizontal gesture

    /// Blocks scrolling of all vertical children for the duration of a horizontal gesture:
    /// it remembers the current `isScrollEnabled` values and sets them to `false`.
    ///
    /// Called at the start of the pager's horizontal scroll (for example, from
    /// `scrollViewWillBeginDragging`). No layout is performed; only the scrolling
    /// flag changes. A repeated call is idempotent: the snapshot is not overwritten,
    /// so the original values are not lost.
    public func prepareForHorizontalScroll() {
        // Already blocking: keep the first (true) snapshot.
        guard savedChildStates == nil else { return }

        var saved: [(view: UIScrollView, wasScrollEnabled: Bool)] = []
        saved.reserveCapacity(verticalOwners.count)
        for child in verticalOwners {
            saved.append((view: child, wasScrollEnabled: child.isScrollEnabled))
            child.isScrollEnabled = false
        }
        savedChildStates = saved
    }

    /// Restores the children's scrolling after a horizontal gesture: gives
    /// each child exactly the `isScrollEnabled` value it had before blocking
    /// (children that were initially disabled stay `false`).
    ///
    /// Called when the pager's horizontal scroll ends (for example, from
    /// `scrollViewDidEndDragging`/`scrollViewDidEndDecelerating`). A call without a
    /// preceding `prepareForHorizontalScroll()` is a no-op. No layout is performed.
    public func endHorizontalScroll() {
        guard let saved = savedChildStates else { return }
        // Reset the snapshot before restoring: a repeated call becomes a no-op.
        savedChildStates = nil
        for entry in saved {
            entry.view.isScrollEnabled = entry.wasScrollEnabled
        }
    }

    // MARK: - Internals

    /// The pan's velocity with a fallback to translation.
    ///
    /// In `gestureRecognizerShouldBegin`, UIKit usually already provides a non-zero velocity.
    /// If it is zero (the gesture has just started or the input is degenerate), the dominant axis
    /// is determined from `translation`: only the ratio of `|dx|` and `|dy|` matters, not the scale,
    /// so the same pure function applies to the displacement.
    private func effectiveVelocity(of pan: UIPanGestureRecognizer) -> CGPoint {
        let velocity = pan.velocity(in: pan.view)
        guard velocity == .zero else { return velocity }
        return pan.translation(in: pan.view)
    }
}
