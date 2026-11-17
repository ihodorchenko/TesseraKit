import UIKit

/// Accessibility utilities of the shared `TesseraCore` layer.
///
/// Covers the accessibility contract in `docs/CORE-IOS-DESIGN.md`:
/// Reduce Motion queries, page-change announcements, and conversion of
/// `UIAccessibilityScrollDirection` into a page step that respects the reading direction.
///
/// The public surface is intentionally minimal (API stability) and consists
/// only of pure functions and one read of a system setting. The only
/// side effect is posting a VoiceOver announcement in ``announcePageChange(_:)``.
/// No state is cached: the component asks for the value at the moment of the decision
/// (turning on Reduce Motion while the app is running must take effect immediately).
///
/// Responsibility for announcements: `TesseraPagerViewController` does **not**
/// announce page changes. The announcement is the host's job (the component
/// or app that embeds the pager). Only the host knows what exactly to say
/// (a section title, "Page 2 of 5", a localized name),
/// and only it can avoid a double announcement when the text is already spoken
/// another way (for example, by moving the accessibility focus to the title).
public enum TesseraAccessibility {

    /// Whether the system "Reduce Motion" setting is on.
    ///
    /// Per the contract in `docs/CORE-IOS-DESIGN.md`: when `true`, components disable
    /// parallax (factor 0), tile flips, and the jiggle in edit mode; a static state
    /// remains instead of self-driven animations. Continuous progress that follows
    /// the user's gesture is not disabled by Reduce Motion.
    public static var isReduceMotionEnabled: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    /// Announces a page change through VoiceOver.
    ///
    /// Posts the system `.announcement` notification (the page-change announcements
    /// from `docs/CORE-IOS-DESIGN.md`). Call it when the transition finishes: an announcement made
    /// during the animation is interrupted by the accessibility focus change, and the user
    /// hears a fragment.
    ///
    /// Called by the pager's **host**, not by the pager itself: `TesseraPagerViewController`
    /// does not send announcements. A typical call site is the delegate callback
    /// `pager(_:didShowPageAt:)` (it fires when the transition completes, including
    /// after a VoiceOver paging gesture via `accessibilityScroll`). Pivot, Panorama,
    /// and StartScreen work this way.
    ///
    /// - Parameter announcement: A ready, localized string, for example
    ///   "Page 2 of 5". The method neither formats nor translates the text: strings
    ///   and their localization are the component's responsibility. An empty string is ignored.
    ///
    /// `UIAccessibility.post` must run on the main thread; if the method is
    /// called from another thread, the notification is forwarded to the main thread so that
    /// the rule "all UI work happens on the main thread" is not violated.
    public static func announcePageChange(_ announcement: String) {
        guard !announcement.isEmpty else { return }

        let post = {
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }

        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    /// The page step for the VoiceOver three-finger gesture (`accessibilityScroll`).
    ///
    /// Returns `+1` for the next page in reading order, `-1` for the previous one,
    /// and `0` if the gesture does not apply to horizontal paging. The result
    /// is added to the current page index; the pager remains the only
    /// writer of `contentOffset`, and this utility only computes the intent.
    ///
    /// Rules:
    /// - `.left` / `.right` are the physical directions of the VoiceOver three-finger
    ///   swipe (the direction the fingers move). UIKit convention: a swipe left
    ///   (`.left`) pages **forward**: the content moves left and the next page
    ///   appears from the right, like an ordinary finger swipe.
    ///   So in LTR `.left` gives `+1` and `.right` gives `-1`. The system
    ///   `UIPageViewController` behaves the same way: its accessibility implementation
    ///   `accessibilityScroll(_:)` picks the "after" controller (the next one)
    ///   on `.left` and the "before" controller (the previous one) on `.right`. In RTL the sign
    ///   is inverted: the next page in reading order lies to the left,
    ///   and a swipe right goes "forward" (`t` is normalized by the reading
    ///   direction).
    /// - `.next` / `.previous` are ordinal rather than physical directions: they are already
    ///   expressed in reading order, so `.next` always gives `+1` and `.previous`
    ///   always gives `-1` regardless of `layoutDirection`. They must not be inverted again
    ///   in RTL: that would mirror twice, and the "back" gesture would
    ///   page forward.
    /// - `.up` / `.down` and any future values are vertical gestures;
    ///   they are not addressed to a horizontal pager, so the result is `0` (the component
    ///   passes the gesture to the child or ignores it).
    ///
    /// - Parameters:
    ///   - direction: The direction from `accessibilityScroll(_:)`.
    ///   - layoutDirection: The interface layout direction.
    /// - Returns: `+1`, `-1`, or `0`.
    public static func pageStep(
        for direction: UIAccessibilityScrollDirection,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> Int {
        let isRightToLeft = layoutDirection == .rightToLeft

        switch direction {
        case .left:
            // A swipe left goes forward in LTR (UIKit convention, see above).
            return isRightToLeft ? -1 : 1
        case .right:
            // A swipe right goes back in LTR.
            return isRightToLeft ? 1 : -1
        case .next:
            return 1
        case .previous:
            return -1
        case .up, .down:
            return 0
        @unknown default:
            return 0
        }
    }
}
