//
//  StartScreenViewController.swift
//  TesseraStartScreen
//
//  The start screen: a horizontal pager of one to three pages and
//  a vertical grid of tiles with a wallpaper parallax.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md — §1 "The key
//  architectural idea: three pages" (START in the center, the hook on the left, the
//  app list on the right; the left edge policy), §2 "Architecture"
//  (StartScreenViewController → pager → StartPage with TileGridView and the background),
//  §7 "The left page: the hook" (lazy loading and appear/disappear callbacks),
//  §8 "Background parallax" (vertical, factor 0.4–0.6, transform only,
//  Reduce Motion → static), and §9 "Accessibility" (accessibilityScroll,
//  announcing the page title, RTL).
//  User clarifications: D13 (the side pages exist only if the host
//  supplied them; the pager has 1 to 3 pages) — docs/STATE.md and §14 of the document.
//
//  Responsibilities:
//  - the controller owns the page composition and the edge policy, but not the data:
//    the grid snapshot comes from outside via ``TesseraStartScreenViewController/reload(grid:)``
//    (the "single writer" rule, §6), tile actions and navigation are handled by the host;
//  - the right page content is not part of this target: the controller receives
//    only a `() -> UIViewController` factory and does not know its concrete type (D13);
//  - there is no layout in the grid scroll hot path: the offset goes to
//    `TesseraParallaxLayer.update(withContentOffset:)`, which changes only
//    `transform` (§8, docs/CORE-IOS-DESIGN.md §2).
//

#if canImport(UIKit)
import UIKit
import TesseraCore

/// A start screen page in reading order (docs/STARTSCREEN-IOS-DESIGN.md §1).
///
/// The declaration order matches the document: the hook on the left, START in the center,
/// the app list on the right. In RTL the physical page layout is mirrored
/// by the Core pager (`TesseraRTL`), while the reading order stays the same.
public enum TesseraStartScreenPage: Hashable {

    /// The left hook page (§7). Exists only if the host supplied
    /// ``TesseraQuickPanelProviding`` (D13).
    case quickPanel

    /// The central page with the tile grid and the wallpaper (§2, §8).
    case start

    /// The right page — the app list and settings (§2, §6).
    case applications
}

/// The start screen controller: the page pager, the START grid, and the wallpaper with parallax.
///
/// ## Composition (§1, §2, D13)
///
/// ```
/// StartScreenViewController
///     └─ TesseraPagerViewController (.paged mode)
///          ├─ QuickPanelPage   ← only if a TesseraQuickPanelProviding is set
///          ├─ StartPage        ← TesseraTileGridView + TesseraParallaxLayer
///          └─ ApplicationsPage ← only if a right page factory is set
/// ```
///
/// The page set scales from one (START only) to three (D13).
/// Pages are passed to the pager in reading order; the physical mirroring
/// and progress normalization are done by Core (`TesseraRTL`), so there is no
/// RTL branch of its own here.
///
/// ## Edge policy (§1)
///
/// The ``yieldsLeftEdgeToSystemGesture`` property is `false` by default: the start
/// screen is a root screen, and both edges are ours. With `true` the leading edge is yielded to
/// the system navigation gesture, and the hook page stops being part of the
/// swipeable set: it can be shown only programmatically via
/// ``showPage(_:animated:)``. While the panel is open programmatically, it stays in the
/// pager; as soon as the user leaves it, the page is removed from the
/// swipeable set (see ``yieldsLeftEdgeToSystemGesture``).
///
/// ## Axis arbitration (§1, docs/CORE-IOS-DESIGN.md §2)
///
/// The pager owns the horizontal axis, and the vertical axis belongs to children. The controller subscribes
/// to the pager pan and, by the dominant axis
/// (``TesseraGestureArbiter/axisDecision(forVelocity:)``), for the duration of
/// a horizontal gesture blocks the children's scrolling, returning it when
/// the gesture ends: the START grid by disabling its pan gesture (its `isScrollEnabled`
/// belongs to the folder animation and edit mode), the side page scrolls
/// through ``TesseraGestureArbiter``. A vertical gesture stays with the children and is not
/// blocked.
///
/// The arbitration is three-way (§1): there are two vertical owners — the START grid and the
/// scroll of a side page (the hook §7 or the app list §6). The START grid
/// is registered automatically: it exists in any configuration (D13). The scrolls of
/// optional pages are created by the host, so the controller does not know them — the host
/// registers them itself through ``registerVerticalOwner(_:)`` from the page controller's
/// `viewDidLoad` and removes them through ``unregisterVerticalOwner(_:)`` if the scroll
/// is no longer used. Both methods are a cold path: they are not executed from
/// `scrollViewDidScroll` and do not touch layout.
///
/// ## Events (§2, §7)
///
/// ``currentPage`` and ``delegate`` events come from the pager's confirmation
/// (the end of a transition). The hook page gets `quickPanelWillAppear` as
/// soon as it starts to appear (a swipe, a programmatic show, the screen appearing with an
/// open hook), and `quickPanelDidDisappear` when it has fully left the screen
/// or the screen was hidden; the delegate gets the same transitions as
/// `didChangeHookVisibility`. While START is off screen, the grid's live tiles are
/// paused (§4).
///
/// ## Parallax (§8)
///
/// The START page keeps a `TesseraParallaxLayer` behind the grid. The offset comes from
/// `TesseraTileGridView.onScrollOffsetChanged`; this callback performs
/// only the `transform` of the background layer — no layout and no cell reloads
/// (docs/CORE-IOS-DESIGN.md §2, "Performance discipline"). With
/// Reduce Motion the layer freezes itself (Core §2, contract 6).
///
/// ## Accessibility (§9)
///
/// - `accessibilityScroll` flips pages in reading order, taking RTL into account;
/// - when a transition ends the page title is announced
///   (``TesseraAccessibility/announcePageChange(_:)``) — only a page
///   change on a shown screen; the start page is not announced;
/// - page titles are set by the ``quickPanelTitle``,
///   ``startPageTitle``, and ``applicationsPageTitle`` properties — the host localizes them.
///
/// - Important: Works on the main thread only: UI state is not
///   smeared across modules (docs/CORE-IOS-DESIGN.md §3).
public final class TesseraStartScreenViewController: UIViewController {

    // MARK: - Page identifiers

    /// The START page identifier for the Core pager.
    private static let startPageID = AnyHashable("TesseraStartScreen.start")

    /// The hook page identifier for the Core pager.
    ///
    /// The pager reuses page controllers with the same `id`
    /// (docs/CORE-IOS-DESIGN.md, "Implementation deviations"). Replacing
    /// the provider in ``configure(leftPanel:rightPage:)`` therefore changes
    /// the generation in the `id`: otherwise the pager would keep the controller
    /// of the previous provider on screen.
    private var quickPanelPageID: AnyHashable {
        AnyHashable("TesseraStartScreen.quickPanel#\(quickPanelPageGeneration)")
    }

    /// The right page identifier for the Core pager (the generation works as for the hook).
    private var applicationsPageID: AnyHashable {
        AnyHashable("TesseraStartScreen.applications#\(applicationsPageGeneration)")
    }

    /// The hook page generation: grows when the provider is replaced.
    private var quickPanelPageGeneration = 0

    /// The right page generation: grows with every new factory.
    private var applicationsPageGeneration = 0

    // MARK: - Public configuration

    /// The start screen wallpaper (§8).
    ///
    /// `nil` (the default) means no wallpaper; the system page background is visible.
    /// The image is drawn with `scaleAspectFill` and cropped to the visible window;
    /// changing the image does not recreate pages and does not touch scrolling.
    public var wallpaperImage: UIImage? {
        didSet {
            startPageController.wallpaperImage = wallpaperImage
        }
    }

    /// The wallpaper parallax multiplier (§8).
    ///
    /// The document sets the range `0.4...0.6`; values outside it are clamped to
    /// the nearest bound, and `NaN` is treated as `0.5`. With Reduce Motion
    /// the effective factor is zero (``TesseraParallaxLayer``), but the background
    /// size margin is computed from the set value — enabling the setting
    /// on the fly will not leave empty strips.
    public var wallpaperParallaxFactor: CGFloat = 0.5 {
        didSet {
            let sanitized = Self.sanitizedParallaxFactor(wallpaperParallaxFactor)

            // A property observer is not invoked again for an assignment inside itself
            // (Swift replaces the stored value silently), so we
            // update the page here rather than "on the next pass".
            if sanitized != wallpaperParallaxFactor {
                wallpaperParallaxFactor = sanitized
            }
            startPageController.parallaxFactor = sanitized
        }
    }

    /// Whether to yield the leading edge to the system navigation gesture (docs/STARTSCREEN-IOS-DESIGN.md §1).
    ///
    /// - `false` (the default) — the start screen is meant to be a root screen: both
    ///   edges belong to the pager, and the hook page is available by swipe (if the host
    ///   supplied it). The host must not embed the screen in a navigation stack or must
    ///   disable `interactivePopGestureRecognizer` itself.
    /// - `true` — the screen lives in a navigation stack: the leading edge is given to
    ///   the system, and the hook page is excluded from the swipeable set. It can be opened
    ///   only programmatically — ``showPage(_:animated:)``. After the
    ///   user leaves a programmatically opened panel, it drops out of the
    ///   swipe again (the page rebuild is deferred to the next run loop pass
    ///   so as not to change the page set inside a pager callback).
    ///
    /// The pager pan requires the system edge gesture to fail first if the screen is already
    /// in a stack; this requirement is set once and is not removed after a policy change
    /// back (UIKit cannot cancel `require(toFail:)`). So
    /// set the property before the screen is shown.
    ///
    /// - Note: In RTL the physical edge is mirrored together with the pages: the hook
    ///   becomes the page on the right of the screen, and it is the leading edge (the right one in RTL)
    ///   that is yielded to the system. No separate branch is needed here.
    public var yieldsLeftEdgeToSystemGesture: Bool = false {
        didSet {
            guard yieldsLeftEdgeToSystemGesture != oldValue else { return }

            if yieldsLeftEdgeToSystemGesture {
                // The panel is already on screen (for example, the policy was enabled after
                // a programmatic show) — we keep it in the set until it is left.
                if currentPage == .quickPanel, leftPanel != nil {
                    isQuickPanelUnlocked = true
                }
            } else {
                // The "both edges are ours" policy: the panel is an ordinary page again.
                isQuickPanelUnlocked = false
            }

            rebuildPages()
            if isViewLoaded {
                view.setNeedsLayout()
            }
            applySystemEdgePriorityIfNeeded()
        }
    }

    /// The hook page title for VoiceOver (§9).
    ///
    /// English by default; the host localizes it. Used in the announcement of
    /// a page change and as the `title` of the pager page descriptor.
    public var quickPanelTitle: String = "Quick panel"

    /// The observer of page changes and hook visibility (the UIKit event channel).
    ///
    /// The controller reports ``TesseraStartScreenDelegate/startScreen(_:didChangePage:index:)``
    /// on a transition confirmed by the pager (a gesture, a programmatic show,
    /// leaving a page that disappeared after ``configure(leftPanel:rightPage:)``) and
    /// ``TesseraStartScreenDelegate/startScreen(_:didChangeHookVisibility:)`` — when the
    /// hook page visibility changes, including the screen itself appearing and leaving.
    /// Showing the start page is not an event.
    ///
    /// The controller does not forward grid taps to the delegate: in UIKit they are delivered by
    /// `gridView.onTap`, which stays with the host (the same delegate receives
    /// taps in `TesseraStartScreenView` — the facade subscribes to `onTap` itself).
    ///
    /// The reference is weak: the delegate is retained by the host (in SwiftUI, the facade coordinator).
    public weak var delegate: TesseraStartScreenDelegate?

    /// The START page title for VoiceOver (§9).
    public var startPageTitle: String = "Start"

    /// The right page title for VoiceOver (§9).
    public var applicationsPageTitle: String = "Applications"

    /// The current page in reading order.
    ///
    /// Before the view loads — ``TesseraStartScreenPage/start`` or the page
    /// requested through ``showPage(_:animated:)`` before display. After loading it
    /// is updated only on the pager's confirmation — when a transition completes
    /// (the source of truth is Core, §2): an animated ``showPage(_:animated:)``
    /// does not change the value until the transition completes, and a transition intercepted
    /// by a finger leaves the page the pager stopped on.
    public private(set) var currentPage: TesseraStartScreenPage = .start

    /// The START page grid.
    ///
    /// Exposed to the host for edit mode: cell snapshots, frames,
    /// placeholders, and the jiggle live on the grid. Data still arrives only
    /// through ``reload(grid:)``; the controller sets the grid insets (`contentInsets`)
    /// itself, taking the safe area into account — there is no need to override them.
    ///
    /// - Important: The grid's `onScrollOffsetChanged` is occupied by the parallax (§8);
    ///   this closure must not be overridden — otherwise the wallpaper stops moving.
    public var gridView: TesseraTileGridView {
        startPageController.gridView
    }

    // MARK: - Internal views

    /// The Core pager in `.paged` mode: snapping is provided by `isPagingEnabled` (§1, §2).
    private let pagerViewController: TesseraPagerViewController

    /// The START page, owned by the controller directly.
    ///
    /// We hold it ourselves so that the grid and the scroll position survive page
    /// rebuilds (`configure`): the pager may unload and request the page
    /// again, but it gets the same instance.
    private let startPageController: TesseraStartPageViewController

    /// The pages in reading order (for indices and announcements).
    private var pageOrder: [TesseraStartScreenPage] = []

    /// The current page in reading order — our index, synchronized with
    /// the pager when transitions complete.
    private var currentPageIndex = 0

    /// The target of a programmatic transition not yet confirmed by the pager.
    ///
    /// Needed only by the hook: the hook page is considered visible from the moment of the request
    /// (the `quickPanelWillAppear` callback comes before appearing, §7), and the deferred
    /// "freeze" of the hook under the edge policy must not remove the page the animation
    /// is heading to. Cleared by a confirmation, a page rebuild, and
    /// the transition being intercepted by a finger (the pager pan's `.began`).
    private var pendingPage: TesseraStartScreenPage?

    /// The last pager progress `t` in reading order.
    ///
    /// Hook visibility is computed from it: the page is visible while
    /// `|t − hook index| < 1`. `nil` means there has been no progress yet (zero width),
    /// and then visibility is taken from ``currentPage``.
    private var lastPagerProgress: CGFloat?

    /// Whether the screen is shown (between `viewWillAppear` and `viewDidDisappear`).
    ///
    /// Hook callbacks (§7), visibility events, and page announcements (§9) are not sent
    /// before the screen is shown: `viewDidLoad` is not an appearance.
    private var isScreenVisible = false

    // MARK: - Hook page state

    /// The left page provider (§7). `nil` means there is no page (D13).
    private var leftPanel: TesseraQuickPanelProviding?

    /// The right page factory (§6). `nil` means there is no page (D13).
    private var rightPageFactory: (() -> UIViewController)?

    /// Whether the hook page is visible now (for the delegate, §7).
    private var isQuickPanelOnScreen = false

    /// The provider that received `quickPanelWillAppear` without a paired
    /// `quickPanelDidDisappear`.
    ///
    /// `didDisappear` goes exactly to it: when the provider is replaced or removed
    /// while the hook is on screen, the callbacks stay symmetric (the previous one gets
    /// `didDisappear`, the new one — `willAppear`).
    private var appearedQuickPanel: TesseraQuickPanelProviding?

    /// Whether the hook page is opened programmatically under the ``yieldsLeftEdgeToSystemGesture`` policy.
    ///
    /// While `true`, the page is part of the pager set (programmatic access
    /// only). Leaving it clears the flag and removes the page from the swipe.
    private var isQuickPanelUnlocked = false

    /// Whether a deferred "freeze" of the hook page is scheduled.
    ///
    /// Rebuilding pages inside `pager(_:didShowPageAt:)` would be reentrant
    /// with respect to the pager, so it is moved to the next run loop pass.
    private var isQuickPanelLockScheduled = false

    /// Announcing the page title (§9).
    ///
    /// An internal seam for tests: by default —
    /// ``TesseraAccessibility/announcePageChange(_:)``.
    var pageAnnouncer: (String) -> Void = { TesseraAccessibility.announcePageChange($0) }

    // MARK: - Edge policy

    /// The pager's scroll view found in the Core hierarchy (for the edge gesture priority).
    ///
    /// Core does not publish the scroll view; the same pager `loadView` contract
    /// (the only direct child is a `UIScrollView`) is used as in Pivot.
    /// If the Core hierarchy changes, the lookup returns `nil` and the screen keeps
    /// working with standard UIKit means.
    private var pagerScrollView: UIScrollView?

    /// Whether the system edge gesture priority over the pager pan is already set.
    private var didApplySystemEdgePriority = false

    // MARK: - Axis arbitration (§1, CORE-IOS-DESIGN.md §2)

    /// The pager pan the controller is subscribed to (owned by Core).
    ///
    /// A subscription via `addTarget` is additive and does not replace the `UIScrollView`
    /// delegate: replacing the delegate would break its own handling of
    /// simultaneous gestures.
    private weak var observedPagerPan: UIPanGestureRecognizer?

    /// The Core arbiter for the duration of a horizontal gesture.
    ///
    /// It lives only between `.began` and `.ended`: it holds the vertical
    /// scroll views by strong references, while the pager loads pages lazily and
    /// recreates them (§7), so permanent retention would extend the life of
    /// unloaded content.
    private var gestureArbiter: TesseraGestureArbiter?

    /// The START grid pan, disabled by the controller for the duration of a horizontal
    /// gesture (`nil` means the controller did not disable it).
    ///
    /// The grid is blocked by the gesture flag, not by `isScrollEnabled`: that flag
    /// belongs to the folder animation and the edit coordinator.
    private weak var lockedGridPan: UIGestureRecognizer?

    /// A weak reference to the vertical scroll view of a side page.
    ///
    /// Side pages are optional (D13) and are unloaded by the pager, so
    /// between gestures the controller does not hold them by strong references: an unloaded
    /// page drops out of the registry by itself.
    private struct WeakVerticalOwner {
        weak var scrollView: UIScrollView?
    }

    /// The vertical owners of side pages registered by the host (§1).
    ///
    /// The START grid is not included: it always exists and is blocked
    /// automatically, with a separate gesture flag (``lockedGridPan``).
    private var extraVerticalOwners: [WeakVerticalOwner] = []

    // MARK: - Initialization

    /// Creates an empty start screen.
    ///
    /// Until the host calls ``configure(leftPanel:rightPage:)``, there is a single
    /// START page (D13). The grid snapshot is passed later through ``reload(grid:)``.
    public init() {
        pagerViewController = TesseraPagerViewController(mode: .paged)
        startPageController = TesseraStartPageViewController()
        super.init(nibName: nil, bundle: nil)
        startPageController.parallaxFactor = Self.sanitizedParallaxFactor(wallpaperParallaxFactor)
    }

    /// Initialization from an archive/storyboard is not supported: the composition
    /// is built in code (§2).
    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    /// Builds the hierarchy and the start page.
    ///
    /// There are no hook callbacks, delegate events, or announcements here: loading the view is
    /// not the screen appearing (§7, §9). The start page is not announced at all —
    /// VoiceOver announces the appeared screen itself.
    public override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        configureSubviews()

        // The rebuild itself puts the pager on ``currentPage`` (including on the
        // page requested through `showPage` before loading).
        rebuildPages()
    }

    /// Lays out the pager and applies the edge policy.
    ///
    /// The controller's only layout pass: there is no layout in the grid scroll
    /// hot path (§8).
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        pagerViewController.view.frame = view.bounds
        resolvePagerScrollViewIfNeeded()
        applySystemEdgePriorityIfNeeded()
    }

    /// The screen is about to appear: the hook on the current page gets
    /// `quickPanelWillAppear` before appearing, the delegate gets the hook visibility (§7).
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        isScreenVisible = true
        updateQuickPanelVisibility()
    }

    /// Retries enabling the edge policy: the navigation controller
    /// may become available only by the time of display.
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // A safeguard for an appearance without `viewWillAppear`.
        if !isScreenVisible {
            isScreenVisible = true
            updateQuickPanelVisibility()
        }
        resolvePagerScrollViewIfNeeded()
        applySystemEdgePriorityIfNeeded()
    }

    /// The screen left the screen — the hook gets the hide callback, the delegate gets the visibility (§7).
    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        isScreenVisible = false
        updateQuickPanelVisibility()
    }

    deinit {
        // The pager pan subscription is additive: we remove it explicitly, as in Pivot.
        observedPagerPan?.removeTarget(
            self,
            action: #selector(pagerPanDidChange(_:))
        )
    }

    // MARK: - Public API

    /// Applies a snapshot to the START page grid.
    ///
    /// The data comes from `TesseraTileStore` (or from the host) and is not changed by the controller:
    /// the grid only displays the snapshot (§6, the "single writer" rule). The method
    /// can be called before the screen is shown — the grid applies the snapshot without a window.
    ///
    /// - Parameter snapshot: A snapshot of tiles and folders.
    public func reload(grid snapshot: TesseraTileGridSnapshot) {
        startPageController.apply(snapshot: snapshot)
    }

    /// Sets the side pages and rebuilds the pager (D13).
    ///
    /// The pager scales from one page to three:
    /// - `leftPanel != nil` adds the left hook page;
    /// - `rightPage` adds the right page (the app list/settings);
    /// - `nil` removes the corresponding page.
    ///
    /// The current page is kept: if the user was on START, after
    /// the hook is added they stay on START instead of jumping to the first
    /// page (the Core pager keeps the page by `id`, and after the rebuild the controller
    /// also explicitly puts the pager on the actual index). If the
    /// current page disappeared from the new set, the controller goes to
    /// START and reports the page change to the delegate.
    ///
    /// A new hook provider (a different instance) and a new right page factory
    /// recreate the corresponding page — the pager will not keep the controller
    /// of the previous provider on screen. If the hook is on screen at that moment,
    /// the previous provider gets `quickPanelDidDisappear`, the new one gets
    /// `quickPanelWillAppear` (§7); for the delegate the hook stays visible, and there are no
    /// visibility events.
    ///
    /// - Parameters:
    ///   - leftPanel: The hook page provider (§7); `nil` means no page.
    ///   - rightPage: The right page controller factory; `nil` means no page.
    ///     The factory may be called again (the pager lazily unloads pages
    ///     ±1) and must return a controller that can be embedded anew.
    ///
    /// - Note: The vertical scroll of a side page is registered separately —
    ///   through ``registerVerticalOwner(_:)`` from the page controller's `viewDidLoad`
    ///   (§1).
    public func configure(
        leftPanel: TesseraQuickPanelProviding?,
        rightPage: (() -> UIViewController)?
    ) {
        if !Self.isSameProvider(self.leftPanel, leftPanel) {
            // The previous provider leaves: the paired `didDisappear` goes before the replacement,
            // otherwise it would go to the new one (or to nobody when the hook is removed).
            sendQuickPanelDidDisappearIfNeeded()
            if leftPanel != nil {
                quickPanelPageGeneration += 1
            }
        }
        if rightPage != nil {
            // Closures are not comparable: a new factory means a new page.
            applicationsPageGeneration += 1
        }

        self.leftPanel = leftPanel
        self.rightPageFactory = rightPage

        if leftPanel == nil {
            isQuickPanelUnlocked = false
        }

        rebuildPages()
    }

    /// Updates the side page sources without rebuilding the pager.
    ///
    /// The SwiftUI facade path: the hook provider and the right page factory,
    /// created in `body`, arrive as new instances on every redraw.
    /// Rebuilding the pager on every frame would stop a swipe in progress, so
    /// when the presence of pages is unchanged the sources are replaced "quietly": already
    /// loaded pages stay, new instances are used on the
    /// next page creation and for hook callbacks (logically it is the same
    /// provider — its current description).
    ///
    /// - Precondition: The presence of the hook and the right page does not change; otherwise a call to
    ///   ``configure(leftPanel:rightPage:)``.
    func updateSidePageSources(
        leftPanel: TesseraQuickPanelProviding?,
        rightPage: (() -> UIViewController)?
    ) {
        guard (leftPanel != nil) == (self.leftPanel != nil),
              (rightPage != nil) == (rightPageFactory != nil) else {
            configure(leftPanel: leftPanel, rightPage: rightPage)
            return
        }

        self.leftPanel = leftPanel
        self.rightPageFactory = rightPage
        if appearedQuickPanel != nil {
            appearedQuickPanel = leftPanel
        }
    }

    /// Programmatically shows a page in reading order.
    ///
    /// The only way to open the hook page when
    /// ``yieldsLeftEdgeToSystemGesture == true``: for the duration of display the page is
    /// added to the pager, so the first opening rebuilds the page set.
    /// The transition is reported like a swipe: `quickPanelWillAppear`
    /// (before appearing), a delegate event, and a VoiceOver announcement — on completion.
    ///
    /// ``currentPage`` changes on the pager's confirmation: without animation — immediately,
    /// with animation — when it completes (a finger may intercept the transition).
    ///
    /// With Reduce Motion the transition animation is disabled (§9). If the requested
    /// page does not exist (no hook or right page factory), the call is a no-op,
    /// except before the view loads: the intent is remembered, and the first layout
    /// shows the needed page.
    ///
    /// - Parameters:
    ///   - page: The target page.
    ///   - animated: The intent to animate the transition; Reduce Motion takes priority.
    public func showPage(_ page: TesseraStartScreenPage, animated: Bool) {
        let shouldAnimate = animated && !TesseraAccessibility.isReduceMotionEnabled

        guard isViewLoaded else {
            // Before the view is shown we remember the intent: `viewDidLoad` will build
            // the pages from the current configuration and land on the right one.
            guard canInclude(page) else { return }
            // A programmatic unfold is needed only if we open the hook under
            // the edge yielding policy; for other targets it is cleared so that
            // the hook page does not end up in the swipe "along the way".
            isQuickPanelUnlocked = (page == .quickPanel && yieldsLeftEdgeToSystemGesture)
            currentPage = page
            return
        }

        // The edge policy: the hook is not in the swipe — we unfold it programmatically.
        if page == .quickPanel,
           yieldsLeftEdgeToSystemGesture,
           !isQuickPanelUnlocked,
           leftPanel != nil {
            isQuickPanelUnlocked = true
            rebuildPages()
        }

        guard let index = pageOrder.firstIndex(of: page) else { return }

        // The target is set before the transition: the hook gets `willAppear` before appearing (§7).
        pendingPage = page == currentPage ? nil : page
        updateQuickPanelVisibility()

        pagerViewController.go(toPage: index, animated: shouldAnimate)

        // A transition without animation is synchronous: the confirmation (if the page
        // changed) has already arrived through `didShowPageAt`.
        if !shouldAnimate {
            pendingPage = nil
            updateQuickPanelVisibility()
        }
    }

    // MARK: - Vertical owner registration (§1)

    /// Registers the vertical scroll view of a side page.
    ///
    /// The arbitration is three-way (§1): the horizontal axis belongs to the pager, the vertical one to
    /// the START grid and the side page scrolls. The controller registers the START grid
    /// itself (it exists in any configuration, D13), while the scrolls of
    /// optional pages are created by the host, so they must be reported:
    ///
    /// ```swift
    /// // In the side page controller:
    /// override func viewDidLoad() {
    ///     super.viewDidLoad()
    ///     startScreen.registerVerticalOwner(listPage.scrollView)
    /// }
    /// ```
    ///
    /// Register the scroll in the page controller's `viewDidLoad`, when
    /// the scroll view already exists. Do not rely on `viewDidAppear`: the
    /// pager forwards appearance only to the current page, while the ±1 neighbors are
    /// loaded without it — a swipe from START begins before the side
    /// page "appears". For the duration of the pager's
    /// horizontal gesture the owner's scrolling is blocked and, when
    /// the gesture ends, gets back its previous `isScrollEnabled`
    /// (``TesseraGestureArbiter``). A vertical gesture is not blocked — it
    /// stays with the page.
    ///
    /// References are weak: when the pager unloads a page (D13, lazy loading
    /// ±1), its scroll drops out of the registry by itself — unregistering is not
    /// required. Registering the same instance again is a no-op. The pager's own scroll view
    /// does not get into the arbitration (``TesseraGestureArbiter``
    /// excludes the horizontal owner).
    ///
    /// - Parameter scrollView: The vertical scroll view of a side page; for
    ///   ``TesseraAppsListPageViewController`` it is its `scrollView`.
    ///
    /// - Note: Registration adds to the list of owners from which the arbiter
    ///   is assembled for every gesture: no second arbiter is created for side pages —
    ///   the START grid and they are blocked by the same
    ///   ``TesseraGestureArbiter``. If a horizontal gesture is already in progress,
    ///   the registration takes effect from the next gesture: the arbiter is assembled on
    ///   `.began` and is not extended in Core.
    public func registerVerticalOwner(_ scrollView: UIScrollView) {
        guard scrollView !== pagerScrollView else { return }

        pruneExtraVerticalOwners()
        guard !extraVerticalOwners.contains(where: { $0.scrollView === scrollView }) else {
            return
        }
        extraVerticalOwners.append(WeakVerticalOwner(scrollView: scrollView))
    }

    /// Unregisters the vertical scroll view of a side page.
    ///
    /// Calling it is not required: references are weak, and released scrolls drop out
    /// of the arbitration by themselves. The method is needed when the page lives on but its
    /// scroll must no longer be blocked during a horizontal gesture
    /// (for example, the host reuses the scroll view for another page).
    ///
    /// - Parameter scrollView: A previously registered vertical scroll view.
    public func unregisterVerticalOwner(_ scrollView: UIScrollView) {
        extraVerticalOwners.removeAll { owner in
            guard let registered = owner.scrollView else { return true }
            return registered === scrollView
        }
    }

    // MARK: - Accessibility (§9)

    /// Page pagination by the VoiceOver three-finger gesture.
    ///
    /// The direction is converted to a page step through
    /// ``TesseraAccessibility/pageStep(for:layoutDirection:)`` taking RTL into account;
    /// the transition is performed by ``showPage(_:animated:)``, so `contentOffset`
    /// is still written only by the pager (docs/CORE-IOS-DESIGN.md §2).
    ///
    /// Vertical directions return `false`: the vertical axis belongs to
    /// the grid (variant B, §1).
    ///
    /// - Parameter direction: The VoiceOver gesture direction.
    /// - Returns: `true` if the gesture was handled.
    public override func accessibilityScroll(
        _ direction: UIAccessibilityScrollDirection
    ) -> Bool {
        guard isViewLoaded, !pageOrder.isEmpty else { return false }

        let step = TesseraAccessibility.pageStep(
            for: direction,
            layoutDirection: view.effectiveUserInterfaceLayoutDirection
        )
        guard step != 0 else { return false }

        let targetIndex = currentPageIndex + step
        guard pageOrder.indices.contains(targetIndex) else { return false }

        showPage(
            pageOrder[targetIndex],
            animated: !TesseraAccessibility.isReduceMotionEnabled
        )
        return true
    }

    // MARK: - Building views

    /// Adds the pager as a child and sets its delegate (§2).
    private func configureSubviews() {
        startPageController.parallaxFactor = Self.sanitizedParallaxFactor(
            wallpaperParallaxFactor
        )
        startPageController.wallpaperImage = wallpaperImage

        addChild(pagerViewController)
        pagerViewController.view.frame = view.bounds
        pagerViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pagerViewController.view)
        pagerViewController.didMove(toParent: self)
        pagerViewController.delegate = self
    }

    // MARK: - Rebuilding pages

    /// Rebuilds the pager's page set from the current configuration (D13).
    ///
    /// A single source for both the page order and the `TesseraPageDescriptor`:
    /// `pageOrder` and the pager set are always built together, so the
    /// announcement indices and `accessibilityScroll` do not diverge from the pager.
    ///
    /// After `reload(pages:)` the pager is explicitly put on the actual index
    /// of the confirmed page (`go(toPage:animated: false)`): Core keeps the
    /// page by `id`, but a change of the `id` generation (a provider replacement), clamping
    /// of the index when a page disappears, and an interrupted animation must not
    /// leave on screen a page other than the one the controller knows about.
    /// An unfinished programmatic transition is cancelled.
    ///
    /// The rebuild is called only from "cold" paths (configuration,
    /// a programmatic show, leaving the hook page) — not from `scrollViewDidScroll`.
    private func rebuildPages() {
        let built = makePages()
        let order = built.map { $0.page }
        pageOrder = order

        var anchor = currentPage
        if !order.contains(anchor) {
            if anchor == .quickPanel {
                isQuickPanelUnlocked = false
            }
            anchor = order.contains(.start) ? .start : (order.first ?? .start)
        }

        guard isViewLoaded else {
            currentPage = anchor
            currentPageIndex = order.firstIndex(of: anchor) ?? 0
            return
        }

        // A reload cancels the pager animation — we no longer wait for the target.
        pendingPage = nil
        // Fresh progress will come from `reload` (the offset restoration).
        lastPagerProgress = nil
        pagerViewController.reload(pages: built.map { $0.descriptor })

        let index = order.firstIndex(of: anchor) ?? 0
        if anchor != currentPage {
            // The current page disappeared: this is a page change for the delegate and
            // VoiceOver, even if the pager does not manage to confirm it itself
            // (for example, with zero width before the first layout).
            confirmPage(anchor, at: index)
        } else {
            currentPageIndex = index
        }

        pagerViewController.go(toPage: index, animated: false)
        updateQuickPanelVisibility()
    }

    /// Builds "page in reading order — pager descriptor" pairs.
    ///
    /// Closures capture `self` weakly: the pager is retained by the controller,
    /// so a strong capture would close the `controller → pager → page` cycle.
    private func makePages() -> [(page: TesseraStartScreenPage, descriptor: TesseraPageDescriptor)] {
        var result: [(page: TesseraStartScreenPage, descriptor: TesseraPageDescriptor)] = []

        // D13 + edge policy: the hook exists only if the host supplied it, and
        // goes into the swipeable set under the "both edges are ours" policy or
        // after a programmatic unfold.
        if leftPanel != nil, !yieldsLeftEdgeToSystemGesture || isQuickPanelUnlocked {
            let descriptor = TesseraPageDescriptor(
                id: quickPanelPageID,
                title: quickPanelTitle,
                makeContent: { [weak self] in
                    guard let self, let panel = self.leftPanel else {
                        return UIViewController()
                    }
                    return panel.makeQuickPanelViewController()
                }
            )
            result.append((.quickPanel, descriptor))
        }

        let startDescriptor = TesseraPageDescriptor(
            id: Self.startPageID,
            title: startPageTitle,
            makeContent: { [weak self] in
                self?.startPageController ?? UIViewController()
            }
        )
        result.append((.start, startDescriptor))

        if rightPageFactory != nil {
            let descriptor = TesseraPageDescriptor(
                id: applicationsPageID,
                title: applicationsPageTitle,
                makeContent: { [weak self] in
                    self?.rightPageFactory?() ?? UIViewController()
                }
            )
            result.append((.applications, descriptor))
        }

        return result
    }

    // MARK: - Page confirmation

    /// Records the page confirmed by the pager and dispatches events.
    ///
    /// The only place that writes ``currentPage`` after the view loads: a page
    /// change is reported to the delegate and announced (only if the screen
    /// is shown, §9), while a repeated confirmation of the same page (the pager reports
    /// it again after `reload`) is not.
    private func confirmPage(_ page: TesseraStartScreenPage, at index: Int) {
        currentPageIndex = index
        if pendingPage == page {
            pendingPage = nil
        }

        let changed = page != currentPage
        currentPage = page
        updateQuickPanelVisibility()

        if changed {
            delegate?.startScreen(self, didChangePage: page, index: index)
            if isScreenVisible {
                pageAnnouncer(pageTitle(for: page))
            }
        }

        scheduleQuickPanelLockIfNeeded(after: page)
    }

    // MARK: - Hook page (§7)

    /// Whether the hook page is visible now.
    ///
    /// The hook is visible if the screen is shown and the page is at least partly in the pager
    /// window (`|t − hook index| < 1`) or a programmatic transition is heading to it
    /// (then `willAppear` comes before appearing).
    private var isQuickPanelVisible: Bool {
        guard isScreenVisible,
              leftPanel != nil,
              let index = pageOrder.firstIndex(of: .quickPanel) else {
            return false
        }
        if pendingPage == .quickPanel {
            return true
        }
        guard let progress = lastPagerProgress, progress.isFinite else {
            return currentPage == .quickPanel
        }
        return abs(progress - CGFloat(index)) < 1 - Self.pageVisibilityEpsilon
    }

    /// The page fraction at which it is considered to have left the screen.
    private static let pageVisibilityEpsilon: CGFloat = 0.001

    /// Brings the hook callbacks and the delegate event in line with the current visibility (§7).
    ///
    /// The provider gets `quickPanelWillAppear` on appearing and
    /// `quickPanelDidDisappear` — the same instance — on hiding; the delegate gets
    /// `didChangeHookVisibility` only when the value changes. Called also from the
    /// pager progress callback: there is no layout here, only a comparison and
    /// (once per transition) callbacks.
    private func updateQuickPanelVisibility() {
        let visible = isQuickPanelVisible

        if visible {
            if appearedQuickPanel == nil, let panel = leftPanel {
                appearedQuickPanel = panel
                panel.quickPanelWillAppear()
            }
        } else {
            sendQuickPanelDidDisappearIfNeeded()
        }

        guard visible != isQuickPanelOnScreen else { return }
        isQuickPanelOnScreen = visible
        delegate?.startScreen(self, didChangeHookVisibility: visible)
    }

    /// Sends `quickPanelDidDisappear` to the provider that received `willAppear`.
    private func sendQuickPanelDidDisappearIfNeeded() {
        guard let appeared = appearedQuickPanel else { return }
        appearedQuickPanel = nil
        appeared.quickPanelDidDisappear()
    }

    /// Whether this is the same hook provider.
    ///
    /// Class providers are compared by reference; value types cannot be compared
    /// (the box is new each time) — they are considered a new provider.
    private static func isSameProvider(
        _ lhs: TesseraQuickPanelProviding?,
        _ rhs: TesseraQuickPanelProviding?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return (lhs as AnyObject) === (rhs as AnyObject)
        default:
            return false
        }
    }

    /// Returns the hook to the "programmatic only" category after leaving it.
    ///
    /// The page rebuild is deferred: `didShowPageAt` is called by the pager from the
    /// completion of its transition, and changing the page set right in this callback is
    /// reentrancy. By the next run loop pass the user is no longer on
    /// the panel (or has returned, or a programmatic transition is heading to the panel —
    /// then the panel stays open).
    private func scheduleQuickPanelLockIfNeeded(after page: TesseraStartScreenPage) {
        guard yieldsLeftEdgeToSystemGesture,
              isQuickPanelUnlocked,
              page != .quickPanel,
              leftPanel != nil,
              !isQuickPanelLockScheduled else {
            return
        }

        isQuickPanelLockScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isQuickPanelLockScheduled = false

            guard self.yieldsLeftEdgeToSystemGesture, self.isQuickPanelUnlocked else { return }
            // The user managed to return to the panel (or a programmatic
            // transition is heading to it) — we keep it in the set, and the next
            // attempt to leave will get here again.
            guard self.currentPage != .quickPanel,
                  self.pendingPage != .quickPanel else { return }

            self.isQuickPanelUnlocked = false
            self.rebuildPages()
        }
    }

    // MARK: - Edge policy (§1)

    /// Finds the pager's scroll view by the contract of its hierarchy.
    ///
    /// `TesseraPagerViewController` does not publish the scroll view (the same open
    /// question as in Pivot). If Core starts putting something other than a
    /// `UIScrollView` into the root view, the lookup returns `nil` — the edge policy simply does not apply
    /// the priority, and there is no crash.
    private func resolvePagerScrollViewIfNeeded() {
        guard pagerScrollView == nil else { return }

        guard let scrollView = pagerViewController.view.subviews
            .compactMap({ $0 as? UIScrollView })
            .first else {
            return
        }

        pagerScrollView = scrollView
        observePagerPan(scrollView.panGestureRecognizer)
    }

    /// Yields the leading edge to the system navigation gesture (§1).
    ///
    /// The requirement for the pager pan to wait for the edge gesture to fail is set once and does not
    /// replace the gesture delegates (replacing the `UIScrollView` delegate would break its
    /// own handling of simultaneous gestures). Away from the edge the system gesture
    /// fails immediately, so an ordinary pager swipe does not suffer. Outside
    /// a navigation stack (`interactivePopGestureRecognizer == nil`) the policy
    /// boils down to excluding the hook page from the swipe.
    ///
    /// No layout is performed — only the setup of recognizer dependencies.
    private func applySystemEdgePriorityIfNeeded() {
        guard yieldsLeftEdgeToSystemGesture, !didApplySystemEdgePriority else { return }
        guard let pagerScrollView,
              let popGesture = navigationController?.interactivePopGestureRecognizer else {
            return
        }
        // We do not change dependencies on a gesture that has already begun: we wait for the layout,
        // when the pan is in the `.possible` state again.
        guard pagerScrollView.panGestureRecognizer.state == .possible else { return }

        pagerScrollView.panGestureRecognizer.require(toFail: popGesture)
        didApplySystemEdgePriority = true
    }

    // MARK: - Axis arbitration (§1, CORE-IOS-DESIGN.md §2)

    /// Subscribes to the pager pan states without replacing its delegate.
    private func observePagerPan(_ pan: UIPanGestureRecognizer) {
        guard observedPagerPan !== pan else { return }

        observedPagerPan?.removeTarget(
            self,
            action: #selector(pagerPanDidChange(_:))
        )
        pan.addTarget(self, action: #selector(pagerPanDidChange(_:)))
        observedPagerPan = pan
    }

    /// The reaction to the pager pan: blocking/unblocking the vertical children.
    ///
    /// No layout is performed here — only scroll flags. A `.began` during a
    /// programmatic animation means a finger intercepted the transition: we no longer wait for the
    /// `showPage` target, and the pager itself will confirm the page.
    @objc private func pagerPanDidChange(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            if pendingPage != nil {
                pendingPage = nil
                updateQuickPanelVisibility()
            }
            beginHorizontalScroll(isHorizontal: isHorizontalPan(pan))
        case .ended, .cancelled, .failed:
            endHorizontalScroll()
        case .possible, .changed:
            break
        @unknown default:
            endHorizontalScroll()
        }
    }

    /// Begins a horizontal gesture: the children do not scroll for its duration.
    ///
    /// There are two children (§1): the START grid (blocked automatically) and the scrolls of
    /// side pages registered by the host through
    /// ``registerVerticalOwner(_:)``.
    ///
    /// The START grid is blocked not through `isScrollEnabled` but by disabling its
    /// pan gesture (`panGestureRecognizer.isEnabled`): the grid's `isScrollEnabled`
    /// is written both by the folder panel animation and by the edit coordinator, each
    /// with its own "was/is" snapshot. The arbiter's snapshot on top of theirs
    /// raced with them and could leave the grid disabled forever.
    /// A separate gesture flag does not intersect with them: the controller turns the pan
    /// back on only if it turned it off itself. The side page scrolls
    /// are still blocked by ``TesseraGestureArbiter`` (nobody else
    /// touches their flag).
    ///
    /// The decision by the dominant axis is made from the first available pan
    /// vector (as in Pivot): the pager pan delegate cannot be replaced, so the arbiter's
    /// `gestureRecognizerShouldBegin` is not assigned. If the gesture is
    /// vertical, the children stay scrollable — otherwise disabling the
    /// scroll view would stop a vertical scroll that has begun (§1,
    /// CORE-IOS-DESIGN.md §2 "Arbitration").
    ///
    /// - Parameter isHorizontal: Whether the horizontal axis dominates in the gesture that began.
    func beginHorizontalScroll(isHorizontal: Bool) {
        guard isHorizontal else {
            // The vertical axis belongs to the children: we clear any possible previous
            // block and do not touch their scrolling.
            endHorizontalScroll()
            return
        }

        // Protection against overlapping gestures: an unfinished block is first
        // cleared, otherwise the original states would be lost.
        if gestureArbiter != nil || lockedGridPan != nil {
            endHorizontalScroll()
        }

        if let gridPan = startPageController.gridScrollView?.panGestureRecognizer,
           gridPan.isEnabled {
            gridPan.isEnabled = false
            lockedGridPan = gridPan
        }

        guard let pagerScrollView else { return }
        pruneExtraVerticalOwners()
        let arbiter = TesseraGestureArbiter(
            horizontalOwner: pagerScrollView,
            verticalOwners: sidePageVerticalOwners
        )
        arbiter.prepareForHorizontalScroll()
        gestureArbiter = arbiter
    }

    /// Whether the pager pan that has just begun is horizontally dominant.
    ///
    /// Repeats the Core fallback path: with zero velocity the axis is determined by
    /// the translation (the scale does not matter for comparing magnitudes).
    private func isHorizontalPan(_ pan: UIPanGestureRecognizer) -> Bool {
        let velocity = pan.velocity(in: pan.view)
        let vector = velocity == .zero ? pan.translation(in: pan.view) : velocity
        return TesseraGestureArbiter.axisDecision(forVelocity: vector) == .horizontal
    }

    /// Ends a horizontal gesture: returns scrolling to the children.
    ///
    /// The grid pan is turned on unconditionally if the controller turned it off: its
    /// flag is no longer written by anyone, while the grid's `isScrollEnabled` stays with its
    /// own owners. After that the arbiter is released: the controller holds no
    /// strong references to the side page scroll views between gestures,
    /// and unloaded pages (D13) do not live in the arbiter.
    func endHorizontalScroll() {
        if let gridPan = lockedGridPan {
            gridPan.isEnabled = true
            lockedGridPan = nil
        }
        gestureArbiter?.endHorizontalScroll()
        gestureArbiter = nil
        pruneExtraVerticalOwners()
    }

    /// The vertical owners of side pages for the arbiter.
    ///
    /// The START grid is not included — it is blocked by a separate gesture flag (see
    /// ``beginHorizontalScroll(isHorizontal:)``). Repeats and the pager's own scroll view
    /// are filtered out here, without relying on the internal filtering
    /// ``TesseraGestureArbiter``.
    private var sidePageVerticalOwners: [UIScrollView] {
        var owners: [UIScrollView] = []
        let gridScrollView = startPageController.gridScrollView

        for owner in extraVerticalOwners {
            guard let scrollView = owner.scrollView,
                  scrollView !== pagerScrollView,
                  scrollView !== gridScrollView,
                  !owners.contains(where: { $0 === scrollView }) else {
                continue
            }
            owners.append(scrollView)
        }

        return owners
    }

    /// Removes released side page scroll views from the registry.
    ///
    /// The pager unloads pages lazily (D13), so their scrolls disappear without
    /// an explicit ``unregisterVerticalOwner(_:)``.
    private func pruneExtraVerticalOwners() {
        extraVerticalOwners.removeAll { $0.scrollView == nil }
    }

    // MARK: - Helpers

    /// Whether a page can exist in the current configuration (D13).
    private func canInclude(_ page: TesseraStartScreenPage) -> Bool {
        switch page {
        case .quickPanel:
            return leftPanel != nil
        case .start:
            return true
        case .applications:
            return rightPageFactory != nil
        }
    }

    /// The page title for VoiceOver (§9).
    private func pageTitle(for page: TesseraStartScreenPage) -> String {
        switch page {
        case .quickPanel:
            return quickPanelTitle
        case .start:
            return startPageTitle
        case .applications:
            return applicationsPageTitle
        }
    }

    /// Clamps the parallax multiplier to the document range (§8: `0.4...0.6`).
    private static func sanitizedParallaxFactor(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0.4), 0.6)
    }
}

// MARK: - TesseraPagerDelegate (§1, §7, §9)

extension TesseraStartScreenViewController: TesseraPagerDelegate {

    /// The transition completion: page confirmation, delegate events, and
    /// announcement (``confirmPage(_:at:)``).
    ///
    /// The controller is the pager's permanent delegate; the SwiftUI facade receives
    /// events through ``delegate`` and does not intercept the pager.
    ///
    /// - Parameters:
    ///   - pager: The event source pager.
    ///   - index: The page shown in reading order (RTL is already normalized by Core).
    public func pager(
        _ pager: TesseraPagerViewController,
        didShowPageAt index: Int
    ) {
        guard pageOrder.indices.contains(index) else { return }

        lastPagerProgress = CGFloat(index)
        confirmPage(pageOrder[index], at: index)
    }

    /// Scroll progress: only the hook page visibility (§7).
    ///
    /// Called from the pager's `scrollViewDidScroll`, so there is no layout here:
    /// `t` is saved, and the hook and delegate callbacks go out only when
    /// visibility changes (once per transition). The wallpaper parallax is bound to the vertical
    /// offset of the grid, not to `t`.
    ///
    /// - Parameters:
    ///   - pager: The event source pager.
    ///   - t: The normalized progress in reading order.
    public func pager(
        _ pager: TesseraPagerViewController,
        didChangeProgress t: CGFloat
    ) {
        lastPagerProgress = t
        updateQuickPanelVisibility()
    }
}

// MARK: - START page (§2, §8)

/// The START page: the wallpaper with a vertical parallax and the tile grid.
///
/// A private composition detail: from outside it is available only through
/// ``TesseraStartScreenViewController``. The page does not access `TesseraTileStore` —
/// the snapshot comes from the controller (``apply(snapshot:)``), the "single
/// writer" rule of §6.
///
/// The parallax works as in Panorama, but vertically: the layer is deliberately larger than
/// `contentSize` (Core §2, "Parallax"), the image occupies the visible window over the whole
/// scroll, and `update(withContentOffset:)` changes only the
/// `transform` on every frame. Reduce Motion freezes the layer inside Core; there is no
/// branching on the setting here. The layer margin is also recomputed when the
/// content grows without a new snapshot (folder expansion, `grid.update`): the page
/// observes the collection's `contentSize` (KVO) and marks itself for layout.
///
/// Live tiles (§4, "Pauses"): while the page is not shown by the pager (after
/// `viewDidDisappear` and before `viewWillAppear` — the pager forwards appearance
/// only to the current page), the grid has the public live content pause enabled
/// (`isLiveContentPaused`) — START off screen does not flip, and `grid.update`
/// bypassing the controller does not lift the pause.
private final class TesseraStartPageViewController: UIViewController {

    // MARK: - Metrics

    private enum Metrics {
        /// The base grid margin on top of the safe area (§3: the outer margins are set by the host).
        static let contentInset: CGFloat = 16

        /// The minimum background margin for the scroll "rubber band" at the edges.
        static let backgroundBouncePadding: CGFloat = 96
    }

    // MARK: - Views

    /// The START tile grid.
    let gridView = TesseraTileGridView()

    /// The grid scroll view for axis arbitration (§1).
    ///
    /// The collection is a direct child of the grid (the `TesseraTileGridView` contract), so
    /// no separate public Core accessor is needed. `nil` means the grid is not built yet;
    /// the arbiter is then created without vertical owners and blocks nothing.
    var gridScrollView: UIScrollView? {
        gridView.subviews.compactMap { $0 as? UIScrollView }.first
    }

    /// The background layer with parallax (Core, §8).
    private let parallaxLayer = TesseraParallaxLayer()

    /// The wallpaper inside the layer.
    private let backgroundImageView = UIImageView()

    /// The observation of the grid collection's `contentSize` (§8: the wallpaper margin when
    /// content grows without `reload`).
    private var contentSizeObservation: NSKeyValueObservation?

    /// The content height the wallpaper layer was last laid out for.
    private var backgroundContentHeight: CGFloat?

    /// Whether `layoutPage()` is running — KVO from within its own pass does not
    /// request layout again.
    private var isLayingOutPage = false

    // MARK: - Configuration

    /// The parallax multiplier; clamped to `0.4...0.6` during layout (§8).
    var parallaxFactor: CGFloat = 0.5 {
        didSet {
            guard isViewLoaded else { return }
            view.setNeedsLayout()
        }
    }

    /// The wallpaper; `nil` means only the system page background.
    var wallpaperImage: UIImage? {
        didSet {
            backgroundImageView.image = wallpaperImage
            backgroundImageView.isHidden = wallpaperImage == nil
        }
    }

    // MARK: - Initialization

    init() {
        super.init(nibName: nil, bundle: nil)

        // §8: the offset comes from the single allowed place — the grid's
        // scroll callback. Inside there is only a layer transform, no layout.
        gridView.onScrollOffsetChanged = { [weak self] offset in
            self?.parallaxLayer.update(
                withContentOffset: CGPoint(x: 0, y: offset.y)
            )
        }
        // §4: before the page appears, the grid's live content is paused. The pause
        // belongs to the grid: it is honored in cell configuration,
        // so `grid.update` bypassing the controller does not resume the tiles.
        gridView.isLiveContentPaused = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        // The layer is deliberately larger than the page; without clipping it would ride onto the neighboring
        // pager pages during a swipe.
        view.clipsToBounds = true

        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.clipsToBounds = true
        backgroundImageView.isUserInteractionEnabled = false
        backgroundImageView.isAccessibilityElement = false
        backgroundImageView.image = wallpaperImage
        backgroundImageView.isHidden = wallpaperImage == nil

        parallaxLayer.addSubview(backgroundImageView)
        view.addSubview(parallaxLayer)
        view.addSubview(gridView)

        // §8: the content height grows even without a new snapshot (the folder panel D17,
        // `grid.update` from the host or the coordinator). The recomputation itself is in the
        // nearest layout pass, not in the callback: KVO comes from the collection's
        // layout, and here the page is only marked.
        contentSizeObservation = gridScrollView?.observe(
            \.contentSize,
            options: [.new]
        ) { [weak self] _, _ in
            self?.contentSizeDidChange()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPage()
    }

    /// The START page becomes current: live tiles resume (§4).
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        gridView.isLiveContentPaused = false
    }

    /// The START page left (the pager showed another one or the screen is hidden):
    /// live tiles are paused (§4).
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        gridView.isLiveContentPaused = true
    }

    /// The grid content height changed: the wallpaper margin is recomputed in
    /// the nearest layout pass (§8).
    private func contentSizeDidChange() {
        guard isViewLoaded, !isLayingOutPage else { return }
        let height = gridView.contentSize.height
        guard height != backgroundContentHeight else { return }
        view.setNeedsLayout()
    }

    // MARK: - Data

    /// Applies the grid snapshot.
    ///
    /// Works before the view loads too: the snapshot is applied to the grid, and the background
    /// is recomputed on the nearest layout.
    func apply(snapshot: TesseraTileGridSnapshot) {
        gridView.reload(snapshot: snapshot)

        if isViewLoaded {
            view.setNeedsLayout()
        }
    }

    // MARK: - Layout and parallax (§8)

    /// Lays out the grid taking the safe area into account and recomputes the background.
    ///
    /// Called only from `viewDidLayoutSubviews` (plus `setNeedsLayout`
    /// after `reload(grid:)`); there is no layout in scrolling (§8).
    private func layoutPage() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        isLayingOutPage = true
        defer { isLayingOutPage = false }

        if gridView.frame != bounds {
            gridView.frame = bounds
        }

        // §3: the grid insets are the only source of outer margins. We add the
        // base margin to the safe area; the grid lives under the pager and does not mix
        // the safe area in itself.
        let safeArea = view.safeAreaInsets
        let insets = UIEdgeInsets(
            top: safeArea.top + Metrics.contentInset,
            left: safeArea.left + Metrics.contentInset,
            bottom: safeArea.bottom + Metrics.contentInset,
            right: safeArea.right + Metrics.contentInset
        )
        if gridView.contentInsets != insets {
            gridView.contentInsets = insets
        }

        // The grid needs an up-to-date `contentSize` to compute the background travel; this is
        // a layout pass, not the scroll hot path (§8).
        gridView.layoutIfNeeded()

        layoutBackground(in: bounds)
    }

    /// Lays out the wallpaper layer for a vertical parallax (§8).
    ///
    /// The scheme repeats the horizontal one from Panorama, but along the Y axis:
    /// - the layer's `contentSize` is the content height, but not less than the viewport;
    /// - the `extraSize` margin is the whole background travel (`maximumOffsetY × factor`) plus
    ///   the "rubber band" at the boundaries: the layer is deliberately larger than the content (Core §2);
    /// - the layer is a sibling of the grid scroll, and Core projects the background offset onto the screen
    ///   with a minus sign (`transform = −offset × factor`):
    ///   when scrolling down, the wallpaper moves up together with the tiles, but more slowly;
    /// - therefore the layer origin is at the top edge of the page, raised only by
    ///   `padding` (the margin for the "rubber band" above the top, where offset < 0), while the whole
    ///   background travel `shift` plus the second margin lie below the viewport: the on-screen top
    ///   of the image is `−padding − offset × factor`, the bottom is
    ///   `height + shift + padding − offset × factor` — the viewport is covered at
    ///   any offset in `[−padding / factor, maximumOffset + padding / factor]`;
    /// - the image occupies only the window that is actually visible over the whole scroll.
    ///
    /// The multiplier is taken from the configuration, not from the effective one: with
    /// Reduce Motion Core zeroes the factor, but the margin must stay
    /// sufficient if the setting is turned on "on the fly".
    private func layoutBackground(in bounds: CGRect) {
        let factor = Self.sanitizedFactor(parallaxFactor)
        backgroundContentHeight = gridView.contentSize.height
        let contentHeight = max(gridView.contentSize.height, bounds.height)
        let maximumOffset = max(0, contentHeight - bounds.height)
        let shift = maximumOffset * factor
        let padding = max(Metrics.backgroundBouncePadding, bounds.height * 0.35)

        parallaxLayer.configure(factor: factor, extraSize: shift + padding * 2)
        parallaxLayer.setContentSize(
            CGSize(width: bounds.width, height: contentHeight)
        )

        // The layer (and image) origin is `padding` above the page: a margin for the
        // "rubber band" at the top. The background travel `shift` and the bottom margin are below the viewport,
        // where the layer goes when scrolling down.
        let layerSize = parallaxLayer.bounds.size
        parallaxLayer.center = CGPoint(
            x: layerSize.width / 2,
            y: -padding + layerSize.height / 2
        )

        backgroundImageView.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: bounds.height + shift + padding * 2
        )
    }

    /// Clamps the parallax multiplier to `0.4...0.6` (§8).
    private static func sanitizedFactor(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0.4), 0.6)
    }
}
#endif
