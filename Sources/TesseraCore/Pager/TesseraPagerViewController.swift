// TesseraPagerViewController: the horizontal pager of TesseraCore.
// Design document: docs/CORE-IOS-DESIGN.md (key contracts:
// the progress invariant `t`, the single writer of contentOffset, the two pager modes, the performance
// discipline; and the conceptual API surface).
//
// Design:
// - a single horizontal UIScrollView; pages are full-width frames;
// - t = contentOffset.x / pageWidth, exposed normalized by the
//   reading direction through TesseraRTL (the progress invariant);
// - contentOffset is written only by the UIScrollView gesture and the programmatic
//   go(toPage:animated:) (and by the pager itself when settling a snap and
//   restoring geometry); the delegate and subscribers only read (the single-writer contract);
// - scrollViewDidScroll does no layout: it only reads the offset and calls the delegate
//   (the performance discipline); page frames and contentSize
//   are laid out in viewDidLayoutSubviews;
// - page appearance callbacks are forwarded manually: only the
//   current (visible) page gets appear, and the ±1 neighbors are kept in memory off screen.

#if canImport(UIKit)
import UIKit

/// The pager's operating mode (the two pager modes in docs/CORE-IOS-DESIGN.md).
public enum TesseraPagerMode {
    /// Full-width pages, snapping via `UIScrollView.isPagingEnabled`.
    case paged

    /// The snapping step is set by ``TesseraSnapPolicy``: `decelerationRate = .fast`
    /// and the target offset is computed in `scrollViewWillEndDragging`.
    case snapping
}

/// A horizontal pager with child view controller containers and lazy ±1 loading.
///
/// Contracts (docs/CORE-IOS-DESIGN.md):
/// - progress `t = contentOffset.x / pageWidth`, normalized in RTL by the
///   reading direction through `TesseraRTL`;
/// - `contentOffset` is written only by the gesture and ``go(toPage:animated:)``;
/// - the `.paged` and `.snapping` modes;
/// - `scrollViewDidScroll` does no layout, only callbacks.
///
/// The current page and its neighbors (±1) are kept in memory. Page controllers
/// are created through `TesseraContentHosting` and attached as child view controllers
/// (`addChild` / `didMove(toParent:)`).
///
/// Pages receive appearance callbacks (`viewWillAppear` / `viewDidAppear` / ...)
/// by visibility: only the current page gets appear, when the pager is shown
/// and when the current page changes at the end of a transition; the ±1 neighbors loaded
/// off screen get no callbacks.
///
/// - Important: Works only on the main thread. The delegate is not retained.
public final class TesseraPagerViewController: UIViewController, UIScrollViewDelegate {

    // MARK: - Public configuration

    /// The pager mode, set at creation. It does not change on the fly: changing the mode
    /// means a different controller instance.
    public let mode: TesseraPagerMode

    /// The snapping policy for the `.snapping` mode.
    ///
    /// Not used in `.paged` mode. Changing the policy does not perform
    /// layout and takes effect from the next scroll gesture.
    public var snapPolicy: TesseraSnapPolicy

    /// The observer of page changes and progress.
    ///
    /// Not retained by the pager (the delegate only reads state).
    public weak var delegate: TesseraPagerDelegate?

    // MARK: - Geometry and state

    /// The pager's only scroll view: both the gesture and the programmatic transition go
    /// through it (the single-writer contract).
    private let scrollView = UIScrollView()

    /// The reuse registry for content controllers.
    private let contentHosting = TesseraContentHosting()

    /// The pages in reading order.
    private var pages: [TesseraPageDescriptor] = []

    /// The loaded controllers by reading-order index (the current page and its ±1 neighbors).
    private var loadedControllers: [Int: UIViewController] = [:]

    /// The current (nearest) page in reading order.
    ///
    /// Readable inside the module (for contract tests); written only by the pager.
    private(set) var currentPageIndex = 0

    /// The last page reported to the delegate.
    private var lastShownPageIndex: Int?

    /// The width at which layout was last performed.
    private var lastLayoutWidth: CGFloat = 0

    /// The reading direction the physical page slots were computed for.
    ///
    /// The current `contentOffset` is interpreted in this direction, not in the live
    /// `effectiveUserInterfaceLayoutDirection`: after a direction change on the fly
    /// and until the next layout, the offset still sits in the old slots.
    private var lastLayoutDirection: UIUserInterfaceLayoutDirection?

    /// Whether the current page's offset must be restored on the next layout
    /// (the first layout, `reload(pages:)`, a width change, or a direction change).
    private var needsOffsetRestore = true

    /// Geometry is being written in `layoutPager()`: intermediate `scrollViewDidScroll` calls
    /// (UIKit clamping the offset when the frame/contentSize changes) must not disturb
    /// the index or reach the delegate.
    private var isApplyingLayout = false

    /// A programmatic offset animation of the pager is in progress (`go(toPage:animated:)` or
    /// settling a snap); it ends in `scrollViewDidEndScrollingAnimation`.
    private var isAnimatingTransition = false

    /// `contentOffset.x` at the start of a gesture: the anchor for the ±1 snap step.
    private var dragStartOffsetX: CGFloat?

    /// The snap target computed in `scrollViewWillEndDragging` (the `.snapping` mode).
    ///
    /// Needed to settle when the gesture ended without inertia: UIKit ignores a
    /// modified `targetContentOffset` at zero velocity.
    private var pendingSnapOffsetX: CGFloat?

    /// The pager's own appearance state (forwarded to the children manually).
    private var appearanceState: AppearanceState = .disappeared

    /// The page that was sent appear (begun or completed).
    private weak var appearanceController: UIViewController?

    // MARK: - Initialization

    /// Creates a pager.
    ///
    /// - Parameters:
    ///   - mode: The `.paged` or `.snapping` mode.
    ///   - pages: The pages in reading order. You can pass an empty array
    ///     and fill the pager through ``reload(pages:)``.
    ///   - snapPolicy: The snapping policy for the `.snapping` mode.
    public init(
        mode: TesseraPagerMode = .paged,
        pages: [TesseraPageDescriptor] = [],
        snapPolicy: TesseraSnapPolicy = TesseraSnapPolicy()
    ) {
        self.mode = mode
        self.pages = pages
        self.snapPolicy = snapPolicy
        super.init(nibName: nil, bundle: nil)
        configureScrollView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    public override func loadView() {
        let rootView = PagerRootView()
        rootView.backgroundColor = .clear
        rootView.addSubview(scrollView)
        view = rootView
    }

    /// Appearance is forwarded to the children manually, by visibility rather than by
    /// presence in the hierarchy (the ±1 neighbors sit in the scroll view off screen).
    public override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPager()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        // The environment direction changed: slots are re-laid out in layoutPager().
        if previousTraitCollection?.layoutDirection != traitCollection.layoutDirection {
            view.setNeedsLayout()
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        appearanceState = .appearing
        syncPageAppearance(animated: animated)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // The pager may have been shown without a layout (for example, a zero size when
        // added to a container), so synchronize the index and the page window.
        updateCurrentPageIndexFromOffset()
        if scrollView.bounds.width > 0 {
            refreshLoadedPages(around: currentPageIndex)
        }

        // UIKit does not send viewDidAppear without viewWillAppear, but guard anyway:
        // the current page's appear must have begun before it completes.
        appearanceState = .appearing
        syncPageAppearance(animated: animated)
        appearanceController?.endAppearanceTransition()
        appearanceState = .appeared
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        appearanceState = .disappearing
        appearanceController?.beginAppearanceTransition(false, animated: animated)
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        appearanceController?.endAppearanceTransition()
        appearanceController = nil
        appearanceState = .disappeared
    }

    // MARK: - Public API

    /// Rebuilds the pager for a new set of pages.
    ///
    /// The current page is preserved by `id` if it is present in the new set; otherwise
    /// the previous index is kept, clamped to the new bounds. Controllers
    /// of pages whose `id` survives and falls in the new ±1 window are reused
    /// (the same instance; SwiftUI content is updated in place); only
    /// pages that disappeared or left the window are unloaded. `contentSize` and frames
    /// are recomputed in `viewDidLayoutSubviews` (the only place layout happens).
    ///
    /// - Parameter newPages: The new pages in reading order.
    public func reload(pages newPages: [TesseraPageDescriptor]) {
        // The current id comes from the OLD set: it is used to find the page in the new one.
        let oldPages = pages
        let previousIndex = clampedPageIndex(currentPageIndex)
        let previousID: AnyHashable? = oldPages.indices.contains(previousIndex)
            ? oldPages[previousIndex].id
            : nil

        // Stop inertia/animation before removing pages: only the controller
        // writes the offset, so do this explicitly.
        if isViewLoaded {
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        }
        isAnimatingTransition = false
        dragStartOffsetX = nil
        pendingSnapOffsetX = nil

        // Loaded controllers, keyed by the old set's ids.
        var survivors: [(id: AnyHashable, controller: UIViewController)] = []
        for (index, controller) in loadedControllers.sorted(by: { $0.key < $1.key }) {
            if oldPages.indices.contains(index) {
                survivors.append((oldPages[index].id, controller))
            } else {
                detach(controller)
            }
        }
        loadedControllers.removeAll()

        pages = newPages

        if newPages.isEmpty {
            for survivor in survivors {
                detach(survivor.controller)
            }
            contentHosting.removeAll()
            currentPageIndex = 0
            lastShownPageIndex = nil
            needsOffsetRestore = true
            if isViewLoaded {
                view.setNeedsLayout()
                view.layoutIfNeeded()
            }
            return
        }

        if let previousID, let preservedIndex = newPages.firstIndex(where: { $0.id == previousID }) {
            currentPageIndex = preservedIndex
        } else {
            currentPageIndex = min(max(previousIndex, 0), newPages.count - 1)
        }

        // Reuse the survivors in the new ±1 window; unload the rest.
        let window = pageWindow(around: currentPageIndex)
        for survivor in survivors {
            if let newIndex = newPages.firstIndex(where: { $0.id == survivor.id }),
               window.contains(newIndex),
               loadedControllers[newIndex] == nil {
                loadedControllers[newIndex] = survivor.controller
                // The same instance from the registry; a SwiftUI provider updates rootView.
                _ = contentHosting.viewController(
                    for: survivor.id,
                    provider: newPages[newIndex].content
                )
            } else {
                detach(survivor.controller)
                contentHosting.removeContent(for: survivor.id)
            }
        }

        lastShownPageIndex = nil
        needsOffsetRestore = true

        // Rebuild the page window right away without waiting for the next run loop
        // pass: reload is a synchronous operation, and layout stays in
        // viewDidLayoutSubviews.
        if isViewLoaded {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            syncPageAppearance(animated: false)
        }
    }

    /// Navigates to a page by reading-order index.
    ///
    /// A programmatic transition is the second permitted writer of `contentOffset`
    /// (the single-writer contract). With `animated == true`, the delegate keeps receiving
    /// `didChangeProgress` on animation frames, and `didShowPageAt` on its
    /// completion. The index is clamped to `0...pages.count - 1`.
    ///
    /// An animated transition farther than the adjacent page is a "direct jump" without
    /// flying through the intermediate pages (see docs/PIVOT-IOS-DESIGN.md): without
    /// animation, the offset is moved to the neighbor of the target page on the side of the current one,
    /// the ±1 window is loaded around the target, and one last step is animated.
    /// The delegate receives one `didChangeProgress` with a jump to the target's neighbor
    /// (progress always reflects the actual offset), then the animation frames;
    /// `didShowPageAt` is sent only for the target.
    ///
    /// - Parameters:
    ///   - index: The reading-order index (in RTL, not the physical slot).
    ///   - animated: Whether to animate the transition using `UIScrollView`.
    public func go(toPage index: Int, animated: Bool) {
        guard !pages.isEmpty else { return }

        // Before the view loads, remember the intent: the first layout will place the offset
        // on the right page without an intermediate jump.
        guard isViewLoaded else {
            currentPageIndex = clampedPageIndex(index)
            needsOffsetRestore = true
            return
        }

        // First bring the geometry up to date: contentSize and frames
        // are laid out in viewDidLayoutSubviews, not in this method.
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else {
            currentPageIndex = clampedPageIndex(index)
            needsOffsetRestore = true
            view.setNeedsLayout()
            return
        }

        let targetIndex = clampedPageIndex(index)
        let targetOffset = contentOffset(forReadingIndex: targetIndex, pageWidth: pageWidth)
        needsOffsetRestore = false
        pendingSnapOffsetX = nil

        guard animated, abs(scrollView.contentOffset.x - targetOffset.x) > Self.alignmentTolerance else {
            // Without animation, or there is nothing to animate: UIKit does not send
            // scrollViewDidEndScrollingAnimation for a zero-length path.
            isAnimatingTransition = false
            currentPageIndex = targetIndex
            scrollView.setContentOffset(targetOffset, animated: false)
            finishTransition()
            return
        }

        updateCurrentPageIndexFromOffset()
        let distance = targetIndex - currentPageIndex
        if abs(distance) > 1 {
            // Direct jump: without animation, to the target's neighbor on the side of the current page.
            let neighbourIndex = targetIndex - distance.signum()
            scrollView.setContentOffset(
                contentOffset(forReadingIndex: neighbourIndex, pageWidth: pageWidth),
                animated: false
            )
            refreshLoadedPages(around: targetIndex)
        }

        currentPageIndex = targetIndex
        isAnimatingTransition = true
        scrollView.setContentOffset(targetOffset, animated: true)
    }

    // MARK: - UIScrollViewDelegate

    /// Scroll progress.
    ///
    /// No layout happens here (see the performance discipline in docs/CORE-IOS-DESIGN.md): only
    /// reading the offset, updating the index, and calling the
    /// delegate. `t` is normalized by the reading direction through
    /// `TesseraRTL` (the progress invariant).
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView, !isApplyingLayout else { return }
        reportProgress()
    }

    /// Gesture start: remember the start offset for snapping and clear the flag of
    /// a programmatic animation (the gesture interrupts it, and UIKit does not send
    /// `didEndScrollingAnimation`).
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }
        dragStartOffsetX = scrollView.contentOffset.x
        pendingSnapOffsetX = nil
        isAnimatingTransition = false
    }

    /// Custom snapping for the `.snapping` mode (docs/CORE-IOS-DESIGN.md).
    ///
    /// The computation is fully delegated to ``TesseraSnapPolicy``; the pager only
    /// supplies the actual page width, the gesture velocity, and the start
    /// offset. UIKit reports `velocity` in points/ms and the policy expects pt/s, so
    /// the `× 1000` conversion happens here. In `.paged` mode snapping is performed by
    /// `isPagingEnabled`.
    public func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard scrollView === self.scrollView else { return }

        let startOffsetX = dragStartOffsetX
        dragStartOffsetX = nil

        guard mode == .snapping, !pages.isEmpty else { return }

        let itemWidth = scrollView.bounds.width
        guard itemWidth > 0 else { return }

        let target = snapPolicy.targetContentOffset(
            proposedOffset: targetContentOffset.pointee.x,
            velocity: velocity.x * Self.millisecondsPerSecond,
            itemWidth: itemWidth,
            pageCount: pages.count,
            startOffset: startOffsetX
        )
        targetContentOffset.pointee.x = target
        pendingSnapOffsetX = target
    }

    /// The end of a gesture without inertia: the transition is considered complete immediately.
    ///
    /// In `.snapping` mode at zero velocity, UIKit does not move the offset to the
    /// snap target: the pager, as the only writer, settles it itself
    /// with an animation to the nearest page, and the transition completes in
    /// `scrollViewDidEndScrollingAnimation`.
    public func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        guard scrollView === self.scrollView else { return }

        let snapOffsetX = pendingSnapOffsetX
        pendingSnapOffsetX = nil
        guard !decelerate else { return }

        if mode == .snapping, let alignedOffset = alignedSnapOffset(preferred: snapOffsetX),
           abs(scrollView.contentOffset.x - alignedOffset) > Self.alignmentTolerance {
            isAnimatingTransition = true
            scrollView.setContentOffset(CGPoint(x: alignedOffset, y: 0), animated: true)
            return
        }

        finishTransition()
    }

    /// The end of deceleration: record the shown page.
    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }
        finishTransition()
    }

    /// The end of a programmatic `setContentOffset(_:animated:)` animation.
    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }
        finishTransition()
    }

    // MARK: - Accessibility

    /// Pagination with the VoiceOver three-finger gesture.
    ///
    /// The direction is converted into a page step in reading order through
    /// `TesseraAccessibility.pageStep`; the transition itself is performed by `go(toPage:)`,
    /// so `contentOffset` is still written only by the controller.
    /// Reduce Motion disables the transition animation.
    public override func accessibilityScroll(
        _ direction: UIAccessibilityScrollDirection
    ) -> Bool {
        guard isViewLoaded, !pages.isEmpty else { return false }

        updateCurrentPageIndexFromOffset()
        let step = TesseraAccessibility.pageStep(
            for: direction,
            layoutDirection: effectiveLayoutDirection
        )
        guard step != 0 else { return false }

        let targetIndex = currentPageIndex + step
        guard pages.indices.contains(targetIndex) else { return false }

        go(toPage: targetIndex, animated: !TesseraAccessibility.isReduceMotionEnabled)
        return true
    }

    // MARK: - Configuration

    /// UIKit reports the gesture velocity in points/ms; the snapping policy uses pt/s.
    private static let millisecondsPerSecond: CGFloat = 1000

    /// The "offset is already aligned" tolerance, in points.
    private static let alignmentTolerance: CGFloat = 0.5

    private func configureScrollView() {
        scrollView.isPagingEnabled = mode == .paged
        scrollView.decelerationRate = mode == .snapping ? .fast : .normal
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.backgroundColor = .clear
        scrollView.delegate = self
    }

    // MARK: - Layout (the only place pages are laid out)

    /// Lays out the scroll view, the pages, and `contentSize`.
    ///
    /// Called only from `viewDidLayoutSubviews` (and from synchronous
    /// `layoutIfNeeded` calls in public methods). There is no layout in
    /// `scrollViewDidScroll` (the performance discipline).
    private func layoutPager() {
        // The index is read BEFORE any geometry writes: a frame change (rotation) and a
        // contentSize change can make UIKit clamp the offset and upset the current page.
        let preservedIndex = clampedPageIndex(currentPageIndex)
        let direction = effectiveLayoutDirection

        isApplyingLayout = true
        scrollView.frame = view.bounds

        let pageWidth = scrollView.bounds.width
        let pageHeight = scrollView.bounds.height

        guard !pages.isEmpty else {
            scrollView.contentSize = .zero
            isApplyingLayout = false
            lastLayoutWidth = pageWidth
            lastLayoutDirection = direction
            return
        }

        guard pageWidth > 0 else {
            isApplyingLayout = false
            return
        }

        let widthChanged = lastLayoutWidth > 0 && abs(pageWidth - lastLayoutWidth) > .ulpOfOne
        let directionChanged = lastLayoutDirection != nil && lastLayoutDirection != direction

        // Slots are now computed in the current direction.
        lastLayoutWidth = pageWidth
        lastLayoutDirection = direction

        scrollView.contentSize = CGSize(
            width: pageWidth * CGFloat(pages.count),
            height: pageHeight
        )

        let restoresOffset = needsOffsetRestore || widthChanged || directionChanged
        var clampedOffset = false
        if restoresOffset {
            currentPageIndex = preservedIndex
            scrollView.contentOffset = contentOffset(
                forReadingIndex: preservedIndex,
                pageWidth: pageWidth
            )
            needsOffsetRestore = false
        } else {
            clampedOffset = clampContentOffsetIfNeeded(pageWidth: pageWidth)
        }
        isApplyingLayout = false

        if restoresOffset || clampedOffset {
            // Subscribers receive the final progress once, without
            // intermediate clamping values.
            reportProgress()
            if restoresOffset {
                currentPageIndex = preservedIndex
            }
        }

        refreshLoadedPages(around: currentPageIndex)
        layoutPageFrames(pageWidth: pageWidth, pageHeight: pageHeight)

        if !isScrollInFlight {
            syncPageAppearance(animated: false)
        }
    }

    /// Clamps the offset to the valid bounds after the page count changes.
    ///
    /// - Returns: `true` if the offset changed.
    private func clampContentOffsetIfNeeded(pageWidth: CGFloat) -> Bool {
        let maximumOffset = max(0, pageWidth * CGFloat(pages.count) - pageWidth)
        let clampedX = min(max(scrollView.contentOffset.x, 0), maximumOffset)
        guard clampedX != scrollView.contentOffset.x else { return false }

        scrollView.contentOffset = CGPoint(x: clampedX, y: 0)
        return true
    }

    /// Lays out the frames of all loaded pages.
    private func layoutPageFrames(pageWidth: CGFloat, pageHeight: CGFloat) {
        for (index, controller) in loadedControllers {
            controller.view.frame = pageRect(
                forReadingIndex: index,
                pageWidth: pageWidth,
                pageHeight: pageHeight
            )
        }
    }

    /// The page frame: full-width, in the physical slot corresponding to the
    /// reading-order index.
    private func pageRect(
        forReadingIndex index: Int,
        pageWidth: CGFloat,
        pageHeight: CGFloat
    ) -> CGRect {
        let slot = rawSlot(forReadingIndex: index)
        return CGRect(
            x: CGFloat(slot) * pageWidth,
            y: 0,
            width: pageWidth,
            height: pageHeight
        )
    }

    /// The alignment offset of a page in reading order.
    private func contentOffset(forReadingIndex index: Int, pageWidth: CGFloat) -> CGPoint {
        CGPoint(x: CGFloat(rawSlot(forReadingIndex: index)) * pageWidth, y: 0)
    }

    /// The aligned offset for settling a snap after a gesture without inertia.
    ///
    /// Uses the target computed by the policy in `scrollViewWillEndDragging`;
    /// if there is none, the page nearest to the current offset.
    private func alignedSnapOffset(preferred: CGFloat?) -> CGFloat? {
        guard !pages.isEmpty else { return nil }
        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return nil }

        if let preferred, preferred.isFinite {
            return preferred
        }
        return snapPolicy.targetContentOffset(
            proposedOffset: scrollView.contentOffset.x,
            velocity: 0,
            itemWidth: pageWidth,
            pageCount: pages.count
        )
    }

    // MARK: - Lazy loading of child view controllers

    /// The indices of the ±1 window around a page.
    private func pageWindow(around index: Int) -> Set<Int> {
        guard !pages.isEmpty else { return [] }
        let center = clampedPageIndex(index)
        return Set([center - 1, center, center + 1].filter { pages.indices.contains($0) })
    }

    /// Keeps the current page and its ±1 neighbors in memory.
    ///
    /// Called after a transition completes and from layout, but never from
    /// `scrollViewDidScroll`: adding a child view controller is a hierarchy change,
    /// not work for a scroll frame.
    private func refreshLoadedPages(around index: Int) {
        guard !pages.isEmpty else { return }

        let desired = pageWindow(around: index)

        for loadedIndex in Array(loadedControllers.keys) where !desired.contains(loadedIndex) {
            guard let controller = loadedControllers.removeValue(forKey: loadedIndex) else {
                continue
            }
            detach(controller)
            if pages.indices.contains(loadedIndex) {
                contentHosting.removeContent(for: pages[loadedIndex].id)
            }
        }

        for pageIndex in desired.sorted() where loadedControllers[pageIndex] == nil {
            loadPage(at: pageIndex)
        }
    }

    /// Creates a page controller and attaches it as a child view controller.
    ///
    /// The page gets no appearance callbacks here: forwarding by visibility
    /// is done by `syncPageAppearance(animated:)`.
    private func loadPage(at index: Int) {
        guard pages.indices.contains(index) else { return }

        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return }

        let descriptor = pages[index]
        var controller = contentHosting.viewController(
            for: descriptor.id,
            provider: descriptor.content
        )

        // Guard against a repeated id: one controller cannot be added twice.
        // For valid page sets (unique ids) this branch does not run.
        if loadedControllers.values.contains(where: { $0 === controller }) {
            controller = descriptor.content.makeContentViewController()
        }

        addChild(controller)
        controller.view.frame = pageRect(
            forReadingIndex: index,
            pageWidth: pageWidth,
            pageHeight: scrollView.bounds.height
        )
        scrollView.addSubview(controller.view)
        controller.didMove(toParent: self)
        loadedControllers[index] = controller
    }

    /// Detaches a child view controller from the pager.
    ///
    /// If the page was sent appear, it receives a balanced disappear
    /// before removal.
    private func detach(_ controller: UIViewController) {
        if controller === appearanceController {
            switch appearanceState {
            case .appearing, .appeared:
                controller.beginAppearanceTransition(false, animated: false)
                controller.endAppearanceTransition()
            case .disappearing:
                controller.endAppearanceTransition()
            case .disappeared:
                break
            }
            appearanceController = nil
        }

        guard controller.parent != nil else {
            controller.view.removeFromSuperview()
            return
        }

        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    // MARK: - Appearance by visibility

    /// The pager's appearance state.
    private enum AppearanceState {
        case disappeared
        case appearing
        case appeared
        case disappearing
    }

    /// Whether the offset is currently moving (gesture, inertia, or programmatic animation).
    private var isScrollInFlight: Bool {
        scrollView.isDragging || scrollView.isDecelerating || isAnimatingTransition
    }

    /// Forwards appear to the current page and disappear to the previous one.
    ///
    /// - `.appearing`: the current page begins appear (the pager's
    ///   `viewDidAppear` completes it); if appear was already begun on another page,
    ///   it is cancelled with a balanced disappear.
    /// - `.appeared`: when the current page changes, the previous one gets a full
    ///   disappear and the new one a full appear.
    /// - A hidden or disappearing pager forwards no callbacks.
    private func syncPageAppearance(animated: Bool) {
        guard appearanceState == .appearing || appearanceState == .appeared else { return }

        let current = loadedControllers[clampedPageIndex(currentPageIndex)]
        guard current !== appearanceController else { return }

        if let previous = appearanceController {
            previous.beginAppearanceTransition(false, animated: animated)
            previous.endAppearanceTransition()
            appearanceController = nil
        }

        guard let current else { return }
        current.beginAppearanceTransition(true, animated: animated)
        if appearanceState == .appeared {
            current.endAppearanceTransition()
        }
        appearanceController = current
    }

    // MARK: - Completing a transition

    /// Records the current page, updates the ±1 window, and notifies the delegate.
    private func finishTransition() {
        isAnimatingTransition = false
        guard !pages.isEmpty else { return }

        updateCurrentPageIndexFromOffset()
        if scrollView.bounds.width > 0 {
            refreshLoadedPages(around: currentPageIndex)
            view.setNeedsLayout()
        }
        syncPageAppearance(animated: false)
        reportCurrentPageIfNeeded()
    }

    /// Updates the index from the offset and reports progress to the delegate.
    private func reportProgress() {
        guard !pages.isEmpty else { return }

        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return }

        let rawProgress = scrollView.contentOffset.x / pageWidth
        guard rawProgress.isFinite else { return }

        // The nearest page: needed to restore the index on rotation.
        currentPageIndex = readingPageIndex(forRawProgress: rawProgress, rounded: true)

        let progress = TesseraRTL.normalizedProgress(
            rawProgress,
            pageCount: pages.count,
            layoutDirection: slotLayoutDirection
        )
        guard progress.isFinite else { return }

        delegate?.pager(self, didChangeProgress: progress)
    }

    private func updateCurrentPageIndexFromOffset() {
        guard !pages.isEmpty else {
            currentPageIndex = 0
            return
        }

        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return }

        let rawProgress = scrollView.contentOffset.x / pageWidth
        guard rawProgress.isFinite else { return }

        currentPageIndex = readingPageIndex(forRawProgress: rawProgress, rounded: true)
    }

    private func reportCurrentPageIfNeeded() {
        guard !pages.isEmpty else { return }
        guard let delegate else { return }

        let index = clampedPageIndex(currentPageIndex)
        guard lastShownPageIndex != index else { return }

        lastShownPageIndex = index
        delegate.pager(self, didShowPageAt: index)
    }

    // MARK: - RTL and coordinates

    /// The reading direction of the current view.
    private var effectiveLayoutDirection: UIUserInterfaceLayoutDirection {
        if isViewLoaded {
            return view.effectiveUserInterfaceLayoutDirection
        }

        // Fallback before the view loads: the current trait context.
        switch UITraitCollection.current.layoutDirection {
        case .rightToLeft:
            return .rightToLeft
        case .leftToRight:
            return .leftToRight
        case .unspecified:
            return .leftToRight
        @unknown default:
            return .leftToRight
        }
    }

    /// The direction in which the slots are currently laid out (and the offset sits).
    ///
    /// Before the first layout, the view's live direction.
    private var slotLayoutDirection: UIUserInterfaceLayoutDirection {
        lastLayoutDirection ?? effectiveLayoutDirection
    }

    /// The physical slot of a page in content coordinates.
    ///
    /// In LTR, pages lie in reading order from left to right. In RTL the first
    /// page in reading order is the rightmost: the slot is mirrored
    /// (`pageCount - 1 - index`), while progress and index are normalized by `TesseraRTL`
    /// (see the progress invariant in docs/CORE-IOS-DESIGN.md).
    private func rawSlot(forReadingIndex index: Int) -> Int {
        guard !pages.isEmpty else { return 0 }

        let clampedIndex = clampedPageIndex(index)
        guard slotLayoutDirection == .rightToLeft else { return clampedIndex }
        return pages.count - 1 - clampedIndex
    }

    /// The page index in reading order from raw progress.
    ///
    /// - Parameters:
    ///   - rawProgress: `contentOffset.x / pageWidth`.
    ///   - rounded: `true` for the nearest page, `false` for the integer part
    ///     (the "integer part is the index" rule).
    private func readingPageIndex(forRawProgress rawProgress: CGFloat, rounded: Bool) -> Int {
        guard !pages.isEmpty else { return 0 }

        let position = rounded ? rawProgress.rounded() : rawProgress.rounded(.down)
        let clampedRawIndex = min(max(position, 0), CGFloat(pages.count - 1))

        return TesseraRTL.pageIndex(
            for: clampedRawIndex,
            pageCount: pages.count,
            layoutDirection: slotLayoutDirection
        )
    }

    /// Clamps an index to the bounds of the page set.
    private func clampedPageIndex(_ index: Int) -> Int {
        guard !pages.isEmpty else { return 0 }
        return min(max(index, 0), pages.count - 1)
    }
}

/// The pager's root view: changing `semanticContentAttribute` on the fly marks
/// layout as needed so that `layoutPager()` re-lays out the slots for the new direction.
private final class PagerRootView: UIView {
    override var semanticContentAttribute: UISemanticContentAttribute {
        didSet {
            if oldValue != semanticContentAttribute {
                setNeedsLayout()
            }
        }
    }
}
#endif
