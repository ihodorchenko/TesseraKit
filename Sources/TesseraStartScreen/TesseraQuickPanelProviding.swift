// The left hook page of the start screen.
//
// Design document: docs/STARTSCREEN-IOS-DESIGN.md, §1 (three pages: the left page is a hook for
// calling anything), §7 (the left page: a container with the `TesseraQuickPanelProviding` protocol,
// an empty placeholder by default, appear/disappear callbacks for lazy loading) and §14 (MVP
// clarifications; D13 in docs/DECISIONS.md: both side pages are optional, the pager has 1 to 3 pages).
//
// Decision D13: no provider, no page. The pager does not silently substitute an empty placeholder;
// it simply does not create the left page. A host that needs an empty hook (for example, to keep
// the gesture) passes its own placeholder.
//
// The UIKit import is required: the provider returns a UIViewController, which the pager owns
// through TesseraContentHosting (docs/CORE-IOS-DESIGN.md §3).

#if canImport(UIKit)
import UIKit

/// Provider of the left hook page (docs/STARTSCREEN-IOS-DESIGN.md §7; D13).
///
/// The hook is a full-screen pager page to the left of START; its content is entirely defined by
/// the host app: quick settings, search, profile, recent apps. The start screen component knows
/// nothing about the content and does not interfere with it; the pager only cares that the page
/// exists.
///
/// Per D13: if the host does not pass a provider (passes `nil` or nothing at all), there is no left
/// page and the pager scales down to one or two pages. A `nil` property is a normal mode, not a
/// configuration error.
///
/// Threading: all methods are called on the main thread. ``makeQuickPanelViewController()`` is
/// called lazily, on the first appearance of the page (the pager loads pages ±1,
/// docs/CORE-IOS-DESIGN.md §3), so the controller must not be created at app launch.
public protocol TesseraQuickPanelProviding {

    /// Creates the controller of the left page.
    ///
    /// Called lazily, when the pager is about to show the page for the first time. The pager owns the
    /// controller: it embeds it as a child view controller and drives the `willMove/didMove`
    /// lifecycle itself.
    ///
    /// - Returns: The hook page controller.
    func makeQuickPanelViewController() -> UIViewController

    /// The page is about to appear on screen.
    ///
    /// Useful for lazy content loading (§7): network, data refresh, starting timers. The default
    /// implementation does nothing.
    func quickPanelWillAppear()

    /// The page has disappeared from the screen.
    ///
    /// Useful for stopping timers and releasing load. The default implementation does nothing.
    func quickPanelDidDisappear()
}

public extension TesseraQuickPanelProviding {

    /// By default the hook does not react to appearing: the content loads immediately.
    func quickPanelWillAppear() {}

    /// By default the hook does not react to disappearing.
    func quickPanelDidDisappear() {}
}

/// A hook page provider built from a closure (§7: "protocol or closure").
///
/// Use it when a separate type for a single page is not worth it:
///
/// ```swift
/// let panel = TesseraQuickPanelProvider {
///     QuickSettingsViewController()
/// }
/// ```
///
/// - Note: If the controller should be reused between appearances, cache it in the closure: the
///   pager may recreate the page after it is unloaded.
public final class TesseraQuickPanelProvider: TesseraQuickPanelProviding {

    /// Page controller factory.
    private let makeViewController: () -> UIViewController

    /// Page appear callback, if set.
    private let onAppear: (() -> Void)?

    /// Page disappear callback, if set.
    private let onDisappear: (() -> Void)?

    /// Creates a provider from a closure.
    ///
    /// - Parameters:
    ///   - makeViewController: Controller factory; called lazily.
    ///   - onAppear: Appear callback; none by default.
    ///   - onDisappear: Disappear callback; none by default.
    public init(
        makeViewController: @escaping () -> UIViewController,
        onAppear: (() -> Void)? = nil,
        onDisappear: (() -> Void)? = nil
    ) {
        self.makeViewController = makeViewController
        self.onAppear = onAppear
        self.onDisappear = onDisappear
    }

    /// Creates the page controller.
    public func makeQuickPanelViewController() -> UIViewController {
        makeViewController()
    }

    /// Reports that the page is appearing.
    public func quickPanelWillAppear() {
        onAppear?()
    }

    /// Reports that the page has disappeared.
    public func quickPanelDidDisappear() {
        onDisappear?()
    }
}
#endif
