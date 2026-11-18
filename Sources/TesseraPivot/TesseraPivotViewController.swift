//
//  TesseraPivotViewController.swift
//  TesseraPivot
//
//  The pivot orchestrator: the large app title, the header strip, and
//  a full-screen pager from TesseraCore.
//  Contract: docs/PIVOT-IOS-DESIGN.md (architecture: the layout from top to bottom:
//  the app title label → TesseraPivotHeaderStripView → the pager; core math:
//  auto-centering of the strip when a transition completes; synchronizing the strip and
//  the pager: a single source of truth and a single writer of `contentOffset`;
//  vertical scrolling inside a page: option B, where the pager only scrolls
//  horizontally and the children scroll vertically; accessibility: VoiceOver, Reduce Motion,
//  Dynamic Type, RTL; adaptivity: a single section hides the strip).
//
//  Invariants:
//  - the source of truth is the pager's `contentOffset`; it is written only by the pager's gesture
//    and the programmatic transition (``selectSection(at:animated:)`` →
//    `TesseraPagerViewController.go(toPage:animated:)`);
//  - the strip is only a reader: `didChangeProgress` → `headerStripView.apply(progress:)`,
//    there is no write-back to the pager;
//  - there is no layout on the progress hot path: the strip's `apply(progress:)` moves only
//    the indicator's `transform` and recolors the visible cells.
//

#if canImport(UIKit)
import UIKit
import TesseraCore

/// The pivot controller: a header strip with continuous synchronization and
/// full-screen section pages (see docs/PIVOT-IOS-DESIGN.md).
///
/// The layout from top to bottom:
///
/// ```
/// TesseraPivotViewController
///     ├─ the large app title (UILabel, optional: ``TesseraPivotStyle/appTitle``)
///     ├─ TesseraPivotHeaderStripView   ← the header strip + indicator, outside the pager,
///     │                            so it stays pinned vertically
///     └─ TesseraPagerViewController (.paged mode) ← the pages from ``TesseraPivotSection``
/// ```
///
/// ## Synchronization
///
/// - swipe → strip: the pager's `didChangeProgress` is passed to
///   ``TesseraPivotHeaderStripView/apply(progress:)``; there is no write-back;
/// - header tap → pager: ``selectSection(at:animated:)`` calls
///   `go(toPage:animated:)`; with Reduce Motion the transition has no animation;
/// - transition completion (`didShowPageAt`) → auto-centering of the strip,
///   announcing the section name, and the delegate callback
///   ``TesseraPivotDelegate/pivot(_:didShowSectionAt:)``.
///
/// ## Vertical scrolling (option B)
///
/// The pager scrolls only horizontally, and the pages own vertical scrolling.
/// Content controllers register their vertical scroll views through
/// ``registerVerticalOwner(_:)``; arbitration is performed by
/// ``TesseraGestureArbiter`` from Core: during a horizontal gesture the children's scrolling
/// is blocked and then restored. The details and the forced
/// deviation from the intended design are in the documentation of the registration methods.
///
/// ## RTL
///
/// The progress and indices arrive from Core already normalized by the reading
/// direction (`TesseraRTL`): `0` is the first section for the user. The strip receives
/// the same progress in reading order and converts the geometry into content
/// coordinates itself. There is therefore no separate mirroring branch here; otherwise
/// mirroring would be applied twice.
///
/// - Important: Main thread only: UI state is not
///   spread across modules (docs/CORE-IOS-DESIGN.md). The delegate is not
///   retained.
public final class TesseraPivotViewController: UIViewController {

    // MARK: - Layout constants

    /// The layout geometry, independent of the style.
    ///
    /// The strip's height is not included here: it depends on Dynamic Type and
    /// is computed from the actual header font.
    private enum Metrics {
        /// The side inset of the large app title.
        static let appTitleInset: CGFloat = 20

        /// The inset from the top to the large title.
        static let appTitleTopPadding: CGFloat = 8

        /// The inset between the large title and the header strip.
        static let appTitleBottomPadding: CGFloat = 4

        /// The minimum height of the header strip.
        static let minimumStripHeight: CGFloat = 48

        /// The total vertical margin around the header text in the strip:
        /// half above and half below, with the indicator drawn on top of it.
        static let stripVerticalPadding: CGFloat = 16
    }

    // MARK: - Public configuration

    /// The current set of sections in reading order.
    ///
    /// Changes only through ``reload(sections:)`` (and the initializer). The sections are
    /// the source of truth for both the strip (headers) and the pager (pages,
    /// docs/PIVOT-IOS-DESIGN.md).
    public private(set) var sections: [TesseraPivotSection] = []

    /// The appearance of the pivot (see docs/PIVOT-IOS-DESIGN.md).
    ///
    /// Any assignment is applied to the strip and the large title: the setters of
    /// ``TesseraPivotHeaderStripView`` compare with the previous value, so
    /// setting the same style again does not reload the cells. The strip scales the
    /// header fonts itself for Dynamic Type; the large app title
    /// is recomputed by the controller.
    public var style: TesseraPivotStyle {
        didSet {
            guard isViewLoaded else { return }
            applyStyle()
        }
    }

    /// The observer of selection, progress, and section changes.
    ///
    /// Not retained (the delegate only reads state; see docs/PIVOT-IOS-DESIGN.md).
    /// The public callbacks come from ``TesseraPivotDelegate``.
    public weak var delegate: TesseraPivotDelegate?

    // MARK: - Internal views

    /// The header strip with the indicator. Outside the pager, it is pinned
    /// vertically automatically.
    ///
    /// Available at module level (`@testable`) so that contract tests
    /// can verify tap/swipe synchronization; it is not part of the public surface:
    /// the controller owns the strip's geometry and content.
    let headerStripView = TesseraPivotHeaderStripView()

    /// The Core pager in `.paged` mode (snapping comes from `isPagingEnabled`).
    ///
    /// Available at module level for contract tests; there is no public
    /// access: transitions are performed through ``selectSection(at:animated:)``.
    let pagerViewController: TesseraPagerViewController

    /// The large app title (Windows Phone behavior).
    ///
    /// Shown only when ``TesseraPivotStyle/appTitle`` is non-empty; with `nil`
    /// the title is integrated from outside through `navigationItem.largeTitle`.
    private let appTitleLabel = UILabel()

    // MARK: - Synchronization state

    /// The current section in reading order.
    ///
    /// Updated from the continuous progress (the nearest section) and when a
    /// transition completes; used by VoiceOver paging and for restoring
    /// the selection after ``reload(sections:)``.
    private(set) var currentSectionIndex: Int = 0

    /// Whether the strip must be re-centered on the next layout pass.
    ///
    /// The first display and `reload` happen before the strip has a
    /// width, so auto-centering is deferred until layout.
    private var needsInitialCentering = true

    /// The generation of programmatic transitions.
    ///
    /// It grows on every ``selectSection(at:animated:)``. It is needed to tell
    /// the events of the current transition from the "tails" of an interrupted one: when a new
    /// transition interrupts an animated `setContentOffset`, UIKit synchronously
    /// sends `scrollViewDidEndScrollingAnimation` for the old animation, and
    /// the Core pager reports `didShowPageAt` for the intermediate page on
    /// which the animation was interrupted.
    private var transitionGeneration = 0

    /// The current programmatic transition; `nil` when the transition is finished or
    /// interrupted by a gesture/`reload`.
    private var activeTransition: ProgrammaticTransition?

    /// A programmatic transition of the controller.
    private struct ProgrammaticTransition {
        /// The generation issued to the transition (``transitionGeneration``).
        let generation: Int
        /// The target section in reading order.
        let target: Int
        /// Whether the transition is animated (taking Reduce Motion into account).
        let animated: Bool
        /// A synchronous `go(toPage:animated:)` call is in progress: events that arrive
        /// at this moment for another page are tails of the previous transition.
        var isIssuing: Bool
        /// Carrying the strip's progress over for a far animated jump.
        let stripRemap: StripProgressRemap?
    }

    /// Carrying the pager's progress over to the strip for a far animated jump.
    ///
    /// The pager jumps farther than ±1 as follows: the offset is moved
    /// without animation to the target's neighbor, then one step is animated. The raw
    /// progress therefore arrives at the neighbor as a jump, and the indicator would teleport
    /// across the intermediate headers and highlight the neighbor. The strip instead
    /// receives progress carried linearly from the segment
    /// `[neighbour, target]` onto `[from, target]`: the indicator moves continuously from
    /// the source header to the target during the single animated
    /// step. The external delegate still receives the pager's raw progress.
    struct StripProgressRemap: Equatable {
        /// The progress the strip was showing at the moment of the tap.
        let from: CGFloat
        /// The target's neighbor on the side of the source section: the start of the animated step.
        let neighbour: CGFloat
        /// The target section.
        let target: CGFloat

        /// The strip's progress for a raw pager progress.
        func stripProgress(forPagerProgress progress: CGFloat) -> CGFloat {
            let span = target - neighbour
            guard span != 0 else { return progress }
            let fraction = min(max((progress - neighbour) / span, 0), 1)
            return from + (target - from) * fraction
        }
    }

    /// A ``reload(sections:)`` is in progress: the progress the pager reports during
    /// the rebuild is not forwarded to the delegate synchronously.
    private var isReloading = false

    /// The progress deferred for the duration of `reload`; delivered asynchronously and only
    /// if it differs from the last one delivered.
    private var deferredProgress: CGFloat?

    /// The last progress delivered to the external delegate.
    private var lastDeliveredProgress: CGFloat?

    /// The last raw progress of the pager (in reading order).
    private var lastPagerProgress: CGFloat?

    /// The sections whose content update is deferred until the end of a transition
    /// (see ``refreshSectionContent(_:)``).
    private var deferredContentSections: [TesseraPivotSection]?

    /// Whether a retry to apply the deferred content is scheduled.
    private var isContentRefreshRetryScheduled = false

    /// The strip height cache: it depends on Dynamic Type, and is recomputed only
    /// when the text size category changes, not on every swipe frame.
    private var cachedStripHeight: CGFloat = 0
    private var cachedStripHeightCategory: UIContentSizeCategory?

    // MARK: - Gesture arbitration state (option B)

    /// The pager's scroll view, found in the Core hierarchy.
    ///
    /// Core does not publish it (see the documentation of ``registerVerticalOwner(_:)``).
    /// `private(set)`: for the module's contract tests only.
    private(set) var pagerScrollView: UIScrollView?

    /// The vertical child owners: weak references, so that pages that went away
    /// (lazy ±1 loading) do not leak and are not blocked needlessly.
    private var verticalOwners: [VerticalOwner] = []

    /// The Core arbiter for the duration of a horizontal gesture.
    ///
    /// It lives only between the `panGestureRecognizer`'s `.began` and `.ended`: the arbiter
    /// holds the vertical scroll views by strong references, and pages are
    /// loaded lazily and recreated, so keeping it permanently
    /// would extend the life of unloaded content.
    private var gestureArbiter: TesseraGestureArbiter?

    /// The pager's pan that the controller subscribes to (weak: the owner is Core).
    private weak var observedPagerPan: UIPanGestureRecognizer?

    /// A weak reference to a child's vertical scroll view.
    private struct VerticalOwner {
        weak var scrollView: UIScrollView?
    }

    // MARK: - Initialization

    /// Creates a pivot with a ready set of sections.
    ///
    /// The pager is created immediately in `.paged` mode (see docs/PIVOT-IOS-DESIGN.md):
    /// snapping and inertia come from `UIScrollView.isPagingEnabled`, and custom snapping is not
    /// needed. The pages are built from the sections through ``TesseraPageDescriptor``.
    ///
    /// - Parameters:
    ///   - sections: The sections in reading order; an empty array is a valid
    ///     initial state (pages can be passed later through
    ///     ``reload(sections:)``).
    ///   - style: The appearance; the system default if omitted.
    public init(sections: [TesseraPivotSection] = [], style: TesseraPivotStyle = TesseraPivotStyle()) {
        self.sections = sections
        self.style = style
        self.pagerViewController = TesseraPagerViewController(
            mode: .paged,
            pages: Self.makePageDescriptors(for: sections)
        )
        super.init(nibName: nil, bundle: nil)
    }

    /// Initialization from an archive/storyboard is not supported: the layout
    /// is built in code.
    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    /// Builds the hierarchy: the title, the strip, and the pager child.
    public override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        configureSubviews()

        // The set of sections may have changed before the view loaded (`reload` before display):
        // the pager is rebuilt from the current state.
        pagerViewController.reload(pages: Self.makePageDescriptors(for: sections))

        applyStyle()
        synchronizeStripSelection()
    }

    /// Lays out the title, the strip, and the pager, and picks up the pager's
    /// scroll view for arbitration.
    ///
    /// The controller's only layout pass: there is no layout on the progress
    /// hot path.
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        layoutPivot()
        resolvePagerScrollViewIfNeeded()
        performInitialCenteringIfNeeded()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        observedPagerPan?.removeTarget(
            self,
            action: #selector(pagerPanDidChange(_:))
        )
    }

    // MARK: - Public API

    /// Rebuilds the pivot for a new set of sections.
    ///
    /// Both the strip (headers) and the pager (pages) are rebuilt from a single
    /// source, the sections array. The current section is preserved by `id`
    /// if it is present in the new set; otherwise the previous index is kept, clamped
    /// to the new bounds, so a rebuild does not "throw" the user back to the
    /// first section.
    ///
    /// There is no write-back into `contentOffset`: the pager restores
    /// the page by `id` itself (the single-writer contract). Section controllers with a
    /// surviving `id` are reused by the pager: the scroll position and state of
    /// the pages are not lost, and SwiftUI content is updated in place.
    ///
    /// The progress the pager reports during a rebuild is not passed to the delegate
    /// synchronously: `reload` is often called from a
    /// view update (SwiftUI `updateUIViewController`), and writing
    /// state in a callback at that step is a "state change during
    /// a view update". The final progress is delivered on the next pass of the main
    /// queue and only if it changed. The strip receives the progress immediately.
    ///
    /// An unfinished programmatic transition is interrupted by a rebuild (the pager
    /// stops the animation).
    ///
    /// - Parameter sections: The new sections in reading order. An empty array
    ///   is allowed: the strip is hidden.
    public func reload(sections newSections: [TesseraPivotSection]) {
        let previousID: AnyHashable? = sections.indices.contains(currentSectionIndex)
            ? sections[currentSectionIndex].id
            : nil

        sections = newSections
        deferredContentSections = nil
        activeTransition = nil

        if newSections.isEmpty {
            currentSectionIndex = 0
        } else if let previousID,
                  let preservedIndex = newSections.firstIndex(where: { $0.id == previousID }) {
            currentSectionIndex = preservedIndex
        } else {
            currentSectionIndex = min(max(currentSectionIndex, 0), newSections.count - 1)
        }

        needsInitialCentering = true

        guard isViewLoaded else { return }

        isReloading = true
        headerStripView.titles = sections.map(\.title)
        pagerViewController.reload(pages: Self.makePageDescriptors(for: newSections))
        synchronizeStripSelection()

        view.setNeedsLayout()
        // Lay out right away: the strip may have been hidden (a single section) and its
        // geometry before this layout pass is zero, so auto-centering
        // would go wrong without a width and height. This is a layout path, not the hot one.
        view.layoutIfNeeded()
        centerStrip(index: currentSectionIndex, animated: false)
        isReloading = false

        scheduleDeferredProgressDelivery()
    }

    /// Delivers new section content when the `id`s and titles are unchanged.
    ///
    /// The SwiftUI facade path: ``TesseraPivotView`` cannot compare content
    /// providers, so on every update with the same set of `id`s/titles
    /// it passes the sections here. Content is updated through ``reload(sections:)``:
    /// the pager reuses controllers with a surviving `id` and
    /// updates the `rootView` of SwiftUI hostings in place (the
    /// `TesseraContentUpdating` path in `TesseraContentHosting`), and the page, scroll position, and
    /// `@State` are preserved.
    ///
    /// During a gesture, inertia, or a programmatic transition, the rebuild is deferred:
    /// the pager's `reload` stops the motion and returns the offset to the
    /// nearest page (a jerk under the finger, an interrupted tap animation).
    /// The deferred sections are applied when the transition completes (the latest
    /// to arrive win).
    ///
    /// - Parameter newSections: Sections with the same `id`s and titles as
    ///   the current ones, but possibly with new content.
    func refreshSectionContent(_ newSections: [TesseraPivotSection]) {
        guard isViewLoaded else {
            // Before the view loads, `viewDidLoad` will rebuild the pager from `sections` itself.
            sections = newSections
            return
        }

        guard !isTransitionInFlight else {
            deferredContentSections = newSections
            scheduleContentRefreshRetry()
            return
        }

        reload(sections: newSections)
    }

    /// Whether the pages are moving: a gesture, inertia, or a programmatic transition.
    var isTransitionInFlight: Bool {
        if activeTransition?.animated == true { return true }
        guard let pagerScrollView else { return false }
        return pagerScrollView.isTracking || pagerScrollView.isDragging || pagerScrollView.isDecelerating
    }

    /// Applies the deferred content if the motion has ended.
    private func applyDeferredContentIfIdle() {
        guard let pending = deferredContentSections, !isTransitionInFlight else { return }
        deferredContentSections = nil
        reload(sections: pending)
    }

    /// A safeguard for deferred content: not every end of motion is visible
    /// to the controller (inertia that returned the same page does not give
    /// `didShowPageAt`), so the attempt is repeated until the motion
    /// ends. It works only when there are deferred sections.
    private func scheduleContentRefreshRetry() {
        guard !isContentRefreshRetryScheduled else { return }
        isContentRefreshRetryScheduled = true

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.contentRefreshRetryInterval) { [weak self] in
            guard let self else { return }
            self.isContentRefreshRetryScheduled = false
            guard self.deferredContentSections != nil else { return }

            if self.isTransitionInFlight {
                self.scheduleContentRefreshRetry()
            } else {
                self.applyDeferredContentIfIdle()
            }
        }
    }

    /// The interval for retrying to apply deferred content.
    private static let contentRefreshRetryInterval: TimeInterval = 0.1

    /// Delivers the progress deferred during `reload` on the next pass of the
    /// main queue.
    ///
    /// A value equal to the last delivered one is not delivered at all:
    /// a rebuild with the same set of sections produces no callbacks, and the
    /// "callback → SwiftUI state → update → reload" cycle does not arise.
    private func scheduleDeferredProgressDelivery() {
        guard let progress = deferredProgress else { return }
        guard progress != lastDeliveredProgress else {
            deferredProgress = nil
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.deliverDeferredProgress()
        }
    }

    /// Delivery of the deferred progress; a fresher synchronous progress
    /// cancels it (resets ``deferredProgress``).
    private func deliverDeferredProgress() {
        guard let progress = deferredProgress else { return }
        deferredProgress = nil
        guard progress != lastDeliveredProgress else { return }

        lastDeliveredProgress = progress
        delegate?.pivot(self, didChangeProgress: progress)
    }

    /// Navigates to a section programmatically.
    ///
    /// The only programmatic writer of `contentOffset`: the transition
    /// is performed by ``TesseraPagerViewController/go(toPage:animated:)``. During an
    /// animated transition the pager's delegate keeps sending progress on
    /// frames, so the strip and the indicator animate on their own; there is no separate
    /// indicator animation.
    ///
    /// With Reduce Motion, animation is forcibly disabled (a jump on
    /// tap has no animation). The index is clamped to the bounds of the section set.
    ///
    /// An animated transition does not put the indicator on the target in advance:
    /// otherwise the indicator would jump to the target for a frame and go back with the first
    /// animation frame. The strip is driven by the pager's progress; for a jump farther than
    /// the adjacent section, by the carried-over progress (see `StripProgressRemap`):
    /// the indicator moves continuously from the source header to the target.
    ///
    /// Without animation the strip is not animated at all, neither the indicator nor
    /// the auto-centering.
    ///
    /// - Parameters:
    ///   - index: The section index in reading order (in RTL, not the physical slot).
    ///   - animated: The intent to animate the transition; Reduce Motion takes priority.
    public func selectSection(at index: Int, animated: Bool) {
        guard !sections.isEmpty else { return }

        let targetIndex = min(max(index, 0), sections.count - 1)
        let shouldAnimate = animated && !TesseraAccessibility.isReduceMotionEnabled
        let startIndex = currentSectionIndex

        transitionGeneration &+= 1
        let generation = transitionGeneration

        var stripRemap: StripProgressRemap?
        if shouldAnimate, abs(targetIndex - startIndex) > 1 {
            let step = targetIndex > startIndex ? 1 : -1
            stripRemap = StripProgressRemap(
                from: headerStripView.lastProgress,
                neighbour: CGFloat(targetIndex - step),
                target: CGFloat(targetIndex)
            )
        }

        activeTransition = ProgrammaticTransition(
            generation: generation,
            target: targetIndex,
            animated: shouldAnimate,
            isIssuing: true,
            stripRemap: stripRemap
        )
        currentSectionIndex = targetIndex

        if !shouldAnimate {
            headerStripView.select(index: targetIndex)
        }
        pagerViewController.go(toPage: targetIndex, animated: shouldAnimate)

        // The transition may have completed synchronously (without animation or "nothing
        // to animate"), or may have been interrupted by a nested call, in which case the generation
        // is already different and another transition must not be touched.
        guard activeTransition?.generation == generation else { return }

        if shouldAnimate,
           let lastPagerProgress,
           abs(lastPagerProgress - CGFloat(targetIndex)) > Self.progressTolerance {
            activeTransition?.isIssuing = false
            return
        }

        // The transition completed synchronously; `didShowPageAt` may not have arrived (the section
        // was already shown), so re-center the strip ourselves, without animation.
        activeTransition = nil
        headerStripView.select(index: targetIndex)
        centerStrip(index: targetIndex, animated: false)
        applyDeferredContentIfIdle()
    }

    /// The tolerance for "the progress sits on a whole section".
    private static let progressTolerance: CGFloat = 0.001

    /// Registers a page's vertical scroll view (see docs/PIVOT-IOS-DESIGN.md:
    /// option B).
    ///
    /// The pager scrolls only horizontally, and the pages own vertical scrolling.
    /// A section's content controller calls this method from `viewDidLoad` (or
    /// right after creating the scroll view) and passes its vertical
    /// `UIScrollView`. Not from `viewDidAppear`: the pager forwards
    /// appearance only to the current page, the ±1 neighbors are loaded without it, and
    /// a neighbor the user taps during inertia would not yet have been
    /// registered. Repeated registration is safe (duplicates
    /// are dropped), and the references are weak. For the duration of the pager's
    /// horizontal gesture, the controller builds a ``TesseraGestureArbiter`` from the registered
    /// children: the children's scrolling is blocked and restored to its original state
    /// when the gesture ends
    /// (`prepareForHorizontalScroll()` / `endHorizontalScroll()`).
    ///
    /// The reference to the scroll view is weak: pages are loaded lazily and recreated,
    /// so released owners drop out of the registry automatically.
    /// The arbiter is created only for the duration of a gesture, so the controller holds no strong
    /// references to the scroll views between gestures.
    ///
    /// - Parameter scrollView: The vertical scroll view of the page's content.
    ///
    /// - Note: **A deviation from the intended design.** `TesseraPagerViewController` does not expose its
    ///   `UIScrollView` publicly, and its pan gesture belongs to the
    ///   `UIScrollView` itself. Therefore:
    ///   1. the pager's scroll view is found by walking the Core hierarchy (the only
    ///      direct descendant of the pager's root view; Core's contract tests use
    ///      the same approach) rather than through a public hook;
    ///   2. the arbiter's `gestureRecognizerShouldBegin` is not assigned to the pager's
    ///      pan: replacing `panGestureRecognizer.delegate` on a `UIScrollView`
    ///      would disable its own handling of simultaneous gestures
    ///      (nested scrolls, the system edge swipe). The decision by the dominant
    ///      axis is made on the pan's very first callback through
    ///      ``TesseraGestureArbiter/axisDecision(forVelocity:)``, after which the
    ///      arbiter blocks the children for the duration of the horizontal gesture; both
    ///      halves of the arbitration contract are used, but the point where the
    ///      decision is made is moved from `gestureRecognizerShouldBegin` to `.began`.
    ///   A full solution needs a public Core hook, for example an accessor
    ///   `TesseraPagerViewController.horizontalScrollView` (this is an
    ///   open API question).
    public func registerVerticalOwner(_ scrollView: UIScrollView) {
        guard scrollView !== pagerScrollView else { return }

        pruneVerticalOwners()
        if !verticalOwners.contains(where: { $0.scrollView === scrollView }) {
            verticalOwners.append(VerticalOwner(scrollView: scrollView))
        }
    }

    /// Unregisters a page's vertical scroll view.
    ///
    /// Calling this is optional: references are weak, and released pages drop out of
    /// arbitration on their own. The method is needed when a content controller stops
    /// using a scroll view but stays alive (for example, replaced it).
    ///
    /// - Parameter scrollView: A previously registered vertical scroll view.
    public func unregisterVerticalOwner(_ scrollView: UIScrollView) {
        verticalOwners.removeAll { owner in
            guard let registered = owner.scrollView else { return true }
            return registered === scrollView
        }
    }

    // MARK: - Accessibility

    /// Section paging with the VoiceOver three-finger gesture.
    ///
    /// The direction is converted into a step through the sections via
    /// ``TesseraAccessibility/pageStep(for:layoutDirection:)`` taking the
    /// reading direction into account; the transition itself is performed by ``selectSection(at:animated:)``,
    /// so `contentOffset` is still written only by the pager.
    ///
    /// The Core pager can do the same for its own scroll view; both implementations
    /// lead to the same `go(toPage:)` and give the same result. Here the gesture is
    /// handled at the pivot level so that it also works on the header strip.
    ///
    /// - Parameter direction: The VoiceOver gesture direction.
    /// - Returns: `true` if the gesture was handled.
    public override func accessibilityScroll(
        _ direction: UIAccessibilityScrollDirection
    ) -> Bool {
        guard isViewLoaded, !sections.isEmpty else { return false }

        let step = TesseraAccessibility.pageStep(
            for: direction,
            layoutDirection: view.effectiveUserInterfaceLayoutDirection
        )
        guard step != 0 else { return false }

        let targetIndex = currentSectionIndex + step
        guard sections.indices.contains(targetIndex) else { return false }

        selectSection(at: targetIndex, animated: true)
        return true
    }

    // MARK: - Assembling the views

    /// Creates the hierarchy: the title, the strip, and the pager as a child view controller.
    private func configureSubviews() {
        appTitleLabel.numberOfLines = 0
        appTitleLabel.lineBreakMode = .byTruncatingTail
        appTitleLabel.accessibilityTraits = .header
        appTitleLabel.isHidden = true

        headerStripView.titles = sections.map(\.title)
        headerStripView.onSelect = { [weak self] index in
            self?.handleHeaderTap(at: index)
        }

        view.addSubview(appTitleLabel)
        view.addSubview(headerStripView)

        addChild(pagerViewController)
        view.addSubview(pagerViewController.view)
        pagerViewController.didMove(toParent: self)
        pagerViewController.delegate = self

        // Dynamic Type: the large title is recomputed when the category changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
    }

    /// Applies the style to the strip and the large title.
    ///
    /// The strip's setters compare values with the previous ones, so applying
    /// the same style again does not reload the cells. Called from
    /// `viewDidLoad`, from the ``style`` setter, and when Dynamic Type changes.
    private func applyStyle() {
        headerStripView.mode = style.stripMode
        headerStripView.titleFont = style.titleFont
        headerStripView.titleTextStyle = style.titleTextStyle
        headerStripView.activeColor = style.activeColor
        headerStripView.inactiveColor = style.inactiveColor
        // The indicator style is an underline and/or an accent text color.
        headerStripView.showsIndicator = style.indicatorStyle != .accentText

        appTitleLabel.text = style.appTitle
        appTitleLabel.isHidden = !isAppTitleVisible
        updateAppTitleFont()

        invalidateStripHeightCache()
        view.setNeedsLayout()
    }

    /// Recomputes the large title font for Dynamic Type.
    ///
    /// `TesseraPivotStyle` has no separate font for the app title (the style
    /// describes the strip), so the system bold font with the
    /// `.largeTitle` metrics is used: semantically this is a screen's large title.
    private func updateAppTitleFont() {
        let metrics = UIFontMetrics(forTextStyle: .largeTitle)
        let baseFont = UIFont.systemFont(ofSize: 34, weight: .bold)
        appTitleLabel.font = metrics.scaledFont(for: baseFont, compatibleWith: traitCollection)
    }

    /// Whether to show the large app title.
    private var isAppTitleVisible: Bool {
        guard let appTitle = style.appTitle else { return false }
        return !appTitle.isEmpty
    }

    // MARK: - Layout

    /// Lays out the title, the strip, and the pager from top to bottom.
    ///
    /// The pager takes all the remaining height, including the bottom safe area: pages
    /// are ordinary child view controllers and receive correct `safeAreaInsets` from the pager,
    /// so a vertical content scroll can pass under the home indicator
    /// (the strip is pinned, and only the page's content scrolls).
    private func layoutPivot() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        // A single section or none: hide the strip, since it carries no information.
        let isStripVisible = sections.count > 1
        headerStripView.isHidden = !isStripVisible

        var top = view.safeAreaInsets.top

        if isAppTitleVisible {
            let titleWidth = max(bounds.width - Metrics.appTitleInset * 2, 0)
            let fittingSize = appTitleLabel.sizeThatFits(
                CGSize(width: titleWidth, height: .greatestFiniteMagnitude)
            )
            appTitleLabel.frame = CGRect(
                x: Metrics.appTitleInset,
                y: top + Metrics.appTitleTopPadding,
                width: titleWidth,
                height: ceil(fittingSize.height)
            )
            top = appTitleLabel.frame.maxY + Metrics.appTitleBottomPadding
        } else {
            appTitleLabel.frame = .zero
        }

        let stripHeight = isStripVisible ? stripHeightForCurrentTextSize : 0
        headerStripView.frame = CGRect(
            x: 0,
            y: top,
            width: bounds.width,
            height: stripHeight
        )

        let pagerFrame = CGRect(
            x: 0,
            y: headerStripView.frame.maxY,
            width: bounds.width,
            height: max(bounds.height - headerStripView.frame.maxY, 0)
        )

        if pagerViewController.view.frame != pagerFrame {
            pagerViewController.view.frame = pagerFrame
            // Let the pager lay out the pages in this same pass: otherwise the first
            // display and offset restoration would lag by a frame.
            pagerViewController.view.layoutIfNeeded()
        }
    }

    /// The strip height for the current Dynamic Type.
    ///
    /// Cached by text size category: on the swipe hot path, fonts are not
    /// created.
    private var stripHeightForCurrentTextSize: CGFloat {
        let category = traitCollection.preferredContentSizeCategory
        if cachedStripHeight > 0, cachedStripHeightCategory == category {
            return cachedStripHeight
        }

        let metrics = UIFontMetrics(forTextStyle: style.titleTextStyle)
        let font = metrics.scaledFont(for: style.titleFont, compatibleWith: traitCollection)
        let height = max(
            Metrics.minimumStripHeight,
            ceil(font.lineHeight) + Metrics.stripVerticalPadding
        )

        cachedStripHeight = height
        cachedStripHeightCategory = category
        return height
    }

    /// Resets the strip height cache when Dynamic Type changes.
    private func invalidateStripHeightCache() {
        cachedStripHeight = 0
        cachedStripHeightCategory = nil
    }

    /// Re-centers the strip on the current section after the first layout.
    ///
    /// Before the strip has a width, auto-centering is impossible: `reload` and
    /// setting the initial sections happen before layout.
    private func performInitialCenteringIfNeeded() {
        guard needsInitialCentering, sections.count > 1 else { return }
        centerStrip(index: currentSectionIndex, animated: false)
    }

    /// Re-centers the strip if it already has a width.
    ///
    /// Before `scrollToCenter`, the strip is laid out forcibly: its geometry
    /// (the header centers and the collection's `contentSize`) is computed in
    /// `layoutSubviews`, while `reload` and the first display may happen before it.
    /// This is a layout pass, not the swipe hot path.
    ///
    /// If there is no width yet, auto-centering is deferred until layout.
    private func centerStrip(index: Int, animated: Bool) {
        guard isViewLoaded, headerStripView.bounds.width > 0 else {
            needsInitialCentering = true
            return
        }

        needsInitialCentering = false
        headerStripView.layoutIfNeeded()
        headerStripView.scrollToCenter(index: index, animated: animated)
    }

    // MARK: - Synchronization

    /// A tap on a strip header: reports the intent and starts a transition.
    ///
    /// The strip does not move the pager itself: it only reports the index, and
    /// the controller writes `contentOffset` through ``selectSection(at:animated:)``.
    /// The delegate receives the selection before the transition, as described in ``TesseraPivotDelegate``.
    private func handleHeaderTap(at index: Int) {
        guard sections.indices.contains(index) else { return }

        delegate?.pivot(self, didSelectSectionAt: index)
        selectSection(
            at: index,
            animated: !TesseraAccessibility.isReduceMotionEnabled
        )
    }

    /// Updates the strip's selection without scrolling the pager.
    ///
    /// Used after `reload`: the strip must show the preserved section
    /// before the first progress event.
    private func synchronizeStripSelection() {
        guard !sections.isEmpty else { return }
        headerStripView.select(index: currentSectionIndex)
    }

    /// The section nearest to the progress; the progress is already in reading order.
    private func updateCurrentIndex(fromProgress progress: CGFloat) {
        guard !sections.isEmpty, progress.isFinite else { return }

        let lastIndex = CGFloat(sections.count - 1)
        let clampedProgress = min(max(progress, 0), lastIndex)
        currentSectionIndex = Int(clampedProgress.rounded())
    }

    /// Announces the section name on a change.
    ///
    /// Called when a transition completes: during the animation, an announcement is interrupted
    /// by the accessibility focus change (see ``TesseraAccessibility/announcePageChange(_:)``).
    /// An empty title is not announced.
    private func announceSection(at index: Int) {
        guard sections.indices.contains(index) else { return }

        let title = sections[index].title
        guard !title.isEmpty else { return }

        TesseraAccessibility.announcePageChange(title)
    }

    // MARK: - Vertical scroll arbitration (option B)

    /// Finds the pager's scroll view and subscribes to its pan.
    ///
    /// The deviation from the intended design is documented in ``registerVerticalOwner(_:)``: Core
    /// does not publish the scroll view, so the contract of its `loadView` is used:
    /// the only direct descendant of the root view. If the Core hierarchy changes,
    /// the lookup returns `nil`, and vertical scrolling keeps working through the standard
    /// UIKit mechanisms (without explicitly blocking the children); there is no crash.
    private func resolvePagerScrollViewIfNeeded() {
        guard pagerScrollView == nil else { return }

        let scrollView = pagerViewController.view.subviews
            .compactMap { $0 as? UIScrollView }
            .first
        guard let scrollView else { return }

        pagerScrollView = scrollView
        observePagerPan(scrollView.panGestureRecognizer)
    }

    /// Subscribes to the pager pan's states without replacing its delegate.
    ///
    /// `addTarget` is additive and does not break `UIScrollView`'s internal handlers,
    /// unlike replacing `panGestureRecognizer.delegate` (why that is dangerous:
    /// see ``registerVerticalOwner(_:)``).
    private func observePagerPan(_ pan: UIPanGestureRecognizer) {
        guard observedPagerPan !== pan else { return }

        observedPagerPan?.removeTarget(
            self,
            action: #selector(pagerPanDidChange(_:))
        )
        pan.addTarget(self, action: #selector(pagerPanDidChange(_:)))
        observedPagerPan = pan
    }

    /// Begins a horizontal gesture: creates the arbiter and blocks the vertical children.
    ///
    /// The arbiter lives only for the duration of the gesture: it holds the passed scroll views
    /// by strong references, and pages are loaded lazily in a ±1 window and recreated.
    /// The snapshot of the children's original `isScrollEnabled` is held by the arbiter itself, so
    /// the start and end of a gesture must come as a pair (``pagerPanDidChange(_:)``).
    ///
    /// The dominant axis is checked from the pan's first available vector through
    /// ``TesseraGestureArbiter/axisDecision(forVelocity:)``: if the gesture is
    /// vertical, the pager does not lead it and the children's scrolling is not blocked;
    /// otherwise disabling the scroll view would stop a vertical scroll of the page
    /// that has already begun (see the arbitration contract in docs/CORE-IOS-DESIGN.md).
    ///
    /// No layout is performed here, only the scrolling flag.
    ///
    /// - Parameter pan: The pager's pan that entered the `.began` state.
    private func beginHorizontalScroll(with pan: UIPanGestureRecognizer) {
        guard let pagerScrollView else { return }

        guard isHorizontalPan(pan) else {
            // Vertical belongs to the child: clear any earlier
            // blocking and do not touch the children's `isScrollEnabled`.
            endHorizontalScroll()
            return
        }

        // Guard against overlapping gestures: an unfinished arbiter first returns
        // the children to their original state; otherwise the `isScrollEnabled` snapshot would be lost.
        if gestureArbiter != nil {
            endHorizontalScroll()
        }

        pruneVerticalOwners()
        let arbiter = TesseraGestureArbiter(
            horizontalOwner: pagerScrollView,
            verticalOwners: liveVerticalOwners
        )
        arbiter.prepareForHorizontalScroll()
        gestureArbiter = arbiter
    }

    /// Whether the just-started pager pan is predominantly horizontal.
    ///
    /// Repeats Core's fallback path: at zero velocity the axis is determined from the
    /// translation (the scale does not matter for comparing magnitudes). When the magnitudes are equal,
    /// horizontal wins, which is the default of
    /// ``TesseraGestureArbiter/axisDecision(forVelocity:)``.
    private func isHorizontalPan(_ pan: UIPanGestureRecognizer) -> Bool {
        let velocity = pan.velocity(in: pan.view)
        let vector = velocity == .zero ? pan.translation(in: pan.view) : velocity
        return TesseraGestureArbiter.axisDecision(forVelocity: vector) == .horizontal
    }

    /// Ends the horizontal gesture: returns the children's original scrolling.
    ///
    /// After that the arbiter is released: the controller holds no strong references to the pages' scroll views
    /// between gestures, and unloaded pages do not live
    /// on in the arbiter.
    private func endHorizontalScroll() {
        gestureArbiter?.endHorizontalScroll()
        gestureArbiter = nil
        pruneVerticalOwners()
    }

    /// The live registered owners (excluding the pager itself).
    private var liveVerticalOwners: [UIScrollView] {
        verticalOwners
            .compactMap(\.scrollView)
            .filter { $0 !== pagerScrollView }
    }

    /// Removes released scroll views from the registry (pages live in a ±1 window).
    private func pruneVerticalOwners() {
        verticalOwners.removeAll { $0.scrollView == nil }
    }

    /// The pager pan's states: blocking and unblocking the vertical children.
    ///
    /// `UIScrollView` begins a pan on a horizontal drag; for that time
    /// the child vertical scrolls are disabled so that the gesture is not "torn"
    /// between axes (see the arbitration contract in docs/CORE-IOS-DESIGN.md). When the
    /// gesture ends, each child gets its original `isScrollEnabled` back.
    ///
    /// No layout is performed here, only reading state and the scrolling flag
    /// (see the performance rule in the design document).
    @objc private func pagerPanDidChange(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            // The gesture interrupted a programmatic transition: from now on the strip is driven by the raw
            // progress, and the end is wherever the finger stops it.
            activeTransition = nil
            beginHorizontalScroll(with: pan)
        case .ended, .cancelled, .failed:
            endHorizontalScroll()
            // A gesture without inertia ended: the deferred content can be applied
            // now; with inertia it is applied by `didShowPageAt` or the retry.
            applyDeferredContentIfIdle()
        case .possible, .changed:
            break
        @unknown default:
            endHorizontalScroll()
        }
    }

    // MARK: - Notifications

    /// A Dynamic Type category change: the large title and the
    /// strip height are recomputed. Called off the swipe hot path.
    @objc private func contentSizeCategoryDidChange() {
        guard isViewLoaded else { return }

        updateAppTitleFont()
        invalidateStripHeightCache()
        view.setNeedsLayout()
    }

    // MARK: - Page factory

    /// Turns sections into Core pager pages (see docs/PIVOT-IOS-DESIGN.md).
    ///
    /// The section's identifier and title pass into ``TesseraPageDescriptor``
    /// unchanged: the pager reuses the content controller by `id` and
    /// preserves the current page on `reload`.
    private static func makePageDescriptors(
        for sections: [TesseraPivotSection]
    ) -> [TesseraPageDescriptor] {
        sections.map { section in
            TesseraPageDescriptor(
                id: section.id,
                title: section.title,
                content: section.content
            )
        }
    }
}

// MARK: - TesseraPagerDelegate

extension TesseraPivotViewController: TesseraPagerDelegate {

    /// Swipe → strip: the single point of continuous synchronization.
    ///
    /// Only the progress is read here: the strip moves the indicator and recolors the
    /// visible headers (`transform`/color), and no layout is triggered.
    /// There is no write-back into the pager, so no cycles arise.
    ///
    /// - Parameters:
    ///   - pager: The pager that emitted the event.
    ///   - progress: The progress normalized by the reading direction
    ///     (``TesseraRTL``). During bounce it may go outside the range.
    public func pager(
        _ pager: TesseraPagerViewController,
        didChangeProgress progress: CGFloat
    ) {
        lastPagerProgress = progress

        // A far animated jump: the strip travels from the source header to the
        // target one instead of teleporting to the target's neighbor.
        let stripProgress = activeTransition?.stripRemap?
            .stripProgress(forPagerProgress: progress) ?? progress
        headerStripView.apply(progress: stripProgress)
        updateCurrentIndex(fromProgress: progress)

        // During `reload`, without a synchronous callback: it is delivered
        // `scheduleDeferredProgressDelivery()`.
        guard !isReloading else {
            deferredProgress = progress
            return
        }
        deferredProgress = nil
        lastDeliveredProgress = progress
        delegate?.pivot(self, didChangeProgress: progress)
    }

    /// Transition completion: strip auto-centering, the announcement, and the delegate callback.
    ///
    /// False completions are discarded:
    /// - those that arrive synchronously inside `go(toPage:animated:)` for a page that is not
    ///   the target: this is the `scrollViewDidEndScrollingAnimation` of the previous,
    ///   interrupted animation, where the pager reports the page on which it
    ///   was interrupted;
    /// - those that arrive during ``reload(sections:)``: the rebuild stops the
    ///   animation, and its "completion" is also a tail of an interrupted transition.
    ///
    /// The strip's auto-centering is animated only for animated transitions:
    /// `selectSection(animated: false)` does not animate the strip.
    ///
    /// - Parameters:
    ///   - pager: The pager that emitted the event.
    ///   - index: The shown section in reading order.
    public func pager(
        _ pager: TesseraPagerViewController,
        didShowPageAt index: Int
    ) {
        guard sections.indices.contains(index), !isReloading else { return }

        if let transition = activeTransition, transition.isIssuing, index != transition.target {
            return
        }

        let animatesStrip = activeTransition.map { !($0.isIssuing && !$0.animated) } ?? true
        activeTransition = nil

        currentSectionIndex = index
        needsInitialCentering = false

        headerStripView.select(index: index)
        // Re-center the strip when the transition completes, and only if
        // the header is off the edge; Reduce Motion disables the animation inside
        // `scrollToCenter`.
        headerStripView.scrollToCenter(index: index, animated: animatesStrip)

        // Core rebuilt the ±1 page window: clean the registry of the scroll views
        // of unloaded pages so they do not take part in the next gestures.
        pruneVerticalOwners()

        announceSection(at: index)
        delegate?.pivot(self, didShowSectionAt: index)

        applyDeferredContentIfIdle()
    }
}
#endif
