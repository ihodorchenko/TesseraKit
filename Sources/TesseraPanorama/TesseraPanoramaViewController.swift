//
//  TesseraPanoramaViewController.swift
//  TesseraPanorama
//
//  The panorama orchestrator: the horizontal strip, the parallax background, the section headers, and
//  child controllers with lazy loading.
//  Design document: docs/PANORAMA-IOS-DESIGN.md (conceptual
//  architecture: the composition TesseraPanoramaViewController → TesseraPanoScrollView +
//  PanoBackgroundView + PanoHeaderView + the sections container; core geometry and
//  math: a single scalar t, background parallax, snapping, no layout in
//  scrolling; vertical scrolling inside a section: horizontal goes to the
//  parent and vertical to the child; performance: lazy ±1, prefetch,
//  no layout on the hot path; accessibility: VoiceOver, Reduce Motion,
//  Dynamic Type, RTL; adaptivity: rotation, a single section, an empty list;
//  the MVP scope).
//
//  Invariants:
//  - the single scalar `t = contentOffset.x / itemWidth` is the source for the background,
//    the headers, and the delegate;
//  - `contentOffset` is written only by the `TesseraPanoScrollView` gesture and the programmatic transition
//    (`selectSection(at:animated:)`), per the single-writer rule from
//    docs/CORE-IOS-DESIGN.md;
//  - `scrollViewDidScroll` changes only `frame`/`transform`/`alpha`, with no layout.
//

#if canImport(UIKit)
import TesseraCore
import UIKit

/// The panorama controller: horizontal "canvas" sections with a peek, a parallax background, and
/// headers animated by the swipe progress (see docs/PANORAMA-IOS-DESIGN.md).
///
/// ## Composition
///
/// ```
/// TesseraPanoramaViewController
///     ├─ TesseraParallaxLayer + UIImageView  ← background, parallax by offset
///     ├─ TesseraPanoScrollView               ← horizontal, snapping, t
///     │     └─ section child view controllers (±1 window)  ← the section's vertical scroll
///     └─ PanoHeaderView                      ← headers driven by the same t
/// ```
///
/// The background lies below the other layers and is visible in the peek strip and in
/// sections with transparent content. The headers sit above the scroll strip:
/// they do not take part in the horizontal layout and move with their own
/// `transform` driven by the same `t`.
///
/// ## A single progress value
///
/// `t = contentOffset.x / itemWidth`; the integer part is the section index and the fractional part is
/// the transition progress. In RTL, progress and index are normalized by the reading
/// direction through ``TesseraRTL``: `0` is the first section for the user, not the
/// first physical slot. The background and headers receive the same `t`, so
/// the layers cannot disagree.
///
/// ## Lazy loading and prefetch
///
/// The current section and its ±1 neighbors are kept in memory. The window is updated when a
/// transition completes and in the layout pass, and the neighbor that inertia is already heading to
/// is loaded in `scrollViewWillEndDragging`, before the snap, so a swipe does not stall
/// on lazy loading. The hierarchy does not change in `scrollViewDidScroll`.
///
/// ## Vertical scrolling
///
/// ``TesseraPanoScrollView`` handles horizontal scrolling, and the section's own scroll handles
/// vertical. Content controllers register their vertical scroll views through
/// ``registerVerticalOwner(_:)``; during a horizontal gesture their scrolling
/// is blocked and restored through ``TesseraGestureArbiter``. The point where
/// the axis decision is made and the forced deviation from the intended design are documented in
/// ``registerVerticalOwner(_:)``.
///
/// ## Accessibility
///
/// ``registerVerticalOwner(_:)``.
/// - **VoiceOver**: a three-finger swipe is handled by ``TesseraPanoScrollView`` and
///   the controller as a step through the sections
///   (``TesseraAccessibility/pageStep(for:layoutDirection:)``), and when the
///   transition completes the section name is announced through
///   ``TesseraAccessibility/announcePageChange(_:)``. The headers layer is
///   a separate element with the `.header` trait.
/// - **Reduce Motion**: ``TesseraParallaxLayer`` disables parallax itself (factor
///   0), ``PanoHeaderView`` makes the headers static, and the controller performs programmatic
///   transitions without animation.
/// - **Dynamic Type**: the header fonts are scaled inside
///   ``PanoHeaderView``; a change of the text size category recomputes the layout
///   outside the scroll hot path.
///   ``TesseraRTL`` (see the RTL notes in the design document).
///
/// - **RTL**: the section slots are mirrored, and progress and index are normalized through
///
/// ## Adaptivity
/// When the width/height changes (rotation, iPad, split view), `itemWidth` and `contentSize`
/// are recomputed, and the current section is restored by its index and the saved
/// fraction within the section. A geometry change during an active gesture or inertia
/// is deferred until they finish. A single section has no snapping and takes the full width;
/// an empty list has no sections and no headers (no placeholder is fabricated; see the
///
/// note below).
/// - Note: **Empty list.** ``TesseraPanoramaDelegate`` has no hook for a
///   placeholder state. With an empty set of sections, the controller therefore
///   shows no placeholder of its own: only the background remains and the headers are hidden. The host learns about the empty state from the
///   empty `sections` at the moment of `reload`. An open question for a future
///   revision is adding an empty-state event to the delegate.
///
/// - Important: Main thread only: UI state is not spread across modules
///   (docs/CORE-IOS-DESIGN.md). The delegate is not retained.
public final class TesseraPanoramaViewController: UIViewController {

    // MARK: - Layout metrics

    /// Geometry that does not depend on the style or Dynamic Type.
    private enum Metrics {
        /// The inset from the top safe area to the headers layer.
        static let headerTopPadding: CGFloat = 8

        /// The inset from the headers to the scroll strip.
        static let headerBottomSpacing: CGFloat = 8

        /// The side inset of the header text.
        static let headerSideInset: CGFloat = 20

        /// The "offset is already aligned" tolerance, in points (settling a snap).
        static let alignmentTolerance: CGFloat = 0.5

        /// The minimum margin of the background layer for the rubber band at the edges.
        ///
        /// During bounce `contentOffset` goes past the edge of the strip, and the background shifts
        /// farther than the usual range. The margin is needed on both sides, otherwise an
        /// empty strip would appear at the edge during an elastic bounce.
        static let backgroundBouncePadding: CGFloat = 96
    }

    // MARK: - Public configuration

    /// The current set of sections in reading order.
    ///
    /// Changes only through ``reload(sections:)`` (and the initializer). The sections are
    /// the source of truth for both the headers and the content: hosting reuses
    /// child controllers by their `id`, and the current section is preserved
    /// across a reload.
    public private(set) var sections: [TesseraPanoramaSection] = []

    /// The appearance of the panorama.
    ///
    /// An assignment is applied immediately: the header font and colors, the background, and
    /// the inset adjustment go to the layers, while the peek and layout go to the next
    /// layout pass (outside scrolling), where the current section is restored for the
    /// new width.
    ///
    /// Assigning the same style (all fields match, and the background image is the same
    /// instance) does nothing: the SwiftUI facade assigns the style on every
    /// update.
    public var style: TesseraPanoramaStyle {
        didSet {
            guard !oldValue.isEquivalent(to: style) else { return }
            applyStyle()
        }
    }

    /// The snapping policy.
    ///
    /// ``TesseraPanoramaStyle`` has no snapping field, so the velocity threshold and
    /// alignment are configured here. The default is Core's parameters
    /// (`600` pt/s, center alignment). Changing the policy needs no layout and
    /// takes effect from the next gesture.
    public var snapPolicy: TesseraSnapPolicy {
        didSet {
            scrollView.snapPolicy = snapPolicy
        }
    }

    /// The observer of section changes and progress.
    ///
    /// Not retained (the delegate only reads state). The public callbacks are
    /// ``TesseraPanoramaDelegate``.
    public weak var delegate: TesseraPanoramaDelegate?

    // MARK: - Layers

    /// The panorama's horizontal scroll: section geometry, snapping, and `t`.
    ///
    /// Available at module level (`@testable`) for contract tests;
    /// it is not part of the public surface: programmatic transitions are performed
    /// through ``selectSection(at:animated:)``.
    let scrollView: TesseraPanoScrollView

    /// The section headers layer, animated by `t`.
    let headerView: PanoHeaderView

    /// The background layer with parallax (see the Core and Panorama design documents).
    ///
    /// Its size and `transform` change only off the hot path: the size in the
    /// layout pass and the `transform` from `scrollViewDidScroll`.
    let parallaxLayer = TesseraParallaxLayer()

    /// The background image; one for the whole panorama.
    private let backgroundImageView = UIImageView()

    // MARK: - State

    /// The reuse registry for content controllers (Core, `TesseraContentHosting`).
    private let contentHosting = TesseraContentHosting()

    /// The loaded child controllers by reading-order index (the ±1 window).
    ///
    /// `private(set)` at module level, for contract tests.
    private(set) var loadedSections: [Int: UIViewController] = [:]

    /// The current section in reading order (the nearest to the progress).
    ///
    /// `private(set)` at module level, for contract tests.
    private(set) var currentSectionIndex: Int = 0

    /// The section already reported to the delegate (`didShowSectionAt`).
    private var lastShownSectionIndex: Int?

    /// The width/height of the last layout pass, used to detect a geometry change.
    private var lastLayoutWidth: CGFloat = 0
    private var lastLayoutHeight: CGFloat = 0

    /// The reading direction of the last layout pass.
    private var lastLayoutDirection: UIUserInterfaceLayoutDirection?

    /// Whether the current section's offset must be restored on the next layout
    /// (the first layout, `reload`, a reading direction change).
    private var needsOffsetRestore = true

    /// The fraction within a section saved before a geometry change.
    ///
    /// Stored as progress in reading order: `i + f`, where `i` is the index and `f` is the
    /// fraction of the transition to the next one.
    private var savedReadingProgress: CGFloat?

    /// Layout had to be deferred because of an active gesture/inertia.
    private var needsDeferredLayout = false

    /// A programmatic offset restoration is in progress in the layout pass.
    ///
    /// Needed so that `scrollViewDidScroll`, triggered by `setContentOffset` inside
    /// layout, does not send `didChangeProgress`: this is not user progress but a
    /// consequence of recomputing geometry. Delegate callbacks from the layout pass would break
    /// the "the delegate reads state" contract and, in the SwiftUI facade, would arrive
    /// during a view update.
    private var isRestoringGeometry = false

    // MARK: - Gesture arbitration

    /// A weak reference to a section's vertical scroll view.
    ///
    /// Sections are loaded lazily in a ±1 window and unloaded, so the controller holds
    /// no strong references to their scroll views.
    private struct WeakVerticalOwner {
        weak var scrollView: UIScrollView?
    }

    /// The registered vertical child owners.
    private var verticalOwners: [WeakVerticalOwner] = []

    /// The Core arbiter for the duration of a horizontal gesture.
    ///
    /// It lives only between `.began` and the end of the pan: it holds the vertical
    /// scroll views by strong references, and sections are recreated, so keeping it permanently
    /// would extend the life of unloaded content.
    private var gestureArbiter: TesseraGestureArbiter?

    /// The scroll view's pan that the controller subscribes to (weak: the owner is the scroll view).
    private weak var observedPan: UIPanGestureRecognizer?

    // MARK: - Initialization

    /// Creates a panorama with a ready set of sections.
    ///
    /// - Parameters:
    ///   - sections: The sections in reading order; an empty array is a valid initial
    ///     state (sections can be passed later through ``reload(sections:)``).
    ///   - style: The appearance; the system default if omitted.
    public init(sections: [TesseraPanoramaSection] = [], style: TesseraPanoramaStyle = TesseraPanoramaStyle()) {
        let scrollView = TesseraPanoScrollView(peek: style.peek)
        scrollView.sectionCount = sections.count

        self.scrollView = scrollView
        self.headerView = TesseraPanoHeaderView(
            titles: sections.map(\.title),
            style: TesseraPanoramaViewController.makeHeaderStyle(from: style)
        )
        self.sections = sections
        self.style = style
        self.snapPolicy = TesseraSnapPolicy()

        super.init(nibName: nil, bundle: nil)
    }

    /// Initialization from an archive/storyboard is not supported: the layout is built
    /// in code.
    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        observedPan?.removeTarget(self, action: #selector(scrollPanDidChange(_:)))
    }

    // MARK: - Lifecycle

    /// The root view, which notices a `semanticContentAttribute` change on the fly
    /// (see the RTL notes in the design document).
    public override func loadView() {
        view = PanoramaRootView()
    }

    /// A reading direction change through the trait environment re-lays out the slots
    /// (RTL). The current section is preserved by progress in the previous
    /// direction; see `layoutPanorama()`.
    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded,
              previousTraitCollection?.layoutDirection != traitCollection.layoutDirection else { return }
        view.setNeedsLayout()
    }

    /// Builds the layer hierarchy and subscriptions.
    public override func viewDidLoad() {
        super.viewDidLoad()

        configureSubviews()
        applyStyle()

        // The headers may have been replaced through `reload` before the view loaded: the layer's
        // setter is idempotent and does not recreate labels if the set is unchanged.
        headerView.setTitles(sections.map(\.title))
        scrollView.sectionCount = sections.count
        view.setNeedsLayout()
    }

    /// The controller's only layout pass.
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPanorama()
    }

    /// Synchronizes the index and the section window with the actual offset when shown.
    ///
    /// The view may have been shown without a layout (for example, zero width when added
    /// to a container); here the state is brought to a consistent form.
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard !sections.isEmpty, scrollView.bounds.width > 0 else { return }
        applyProgress(notifyDelegate: false)
        refreshLoadedSections(around: currentSectionIndex)
    }

    // MARK: - Public API

    /// Rebuilds the panorama for a new set of sections.
    ///
    /// The current section is preserved by `id` if it is present in the new set; otherwise
    /// the previous index is kept, clamped to the new bounds. Controllers
    /// of sections whose `id` survives and falls in the new ±1 window are reused
    /// (the same instance, so the vertical position and `@State` are not lost;
    /// SwiftUI content is updated in place), and only those that disappeared or
    /// left the window are unloaded (like the Core pager). `contentSize` and frames
    /// are recomputed in `viewDidLayoutSubviews` (the only place layout happens).
    ///
    /// - Parameter newSections: The new sections in reading order; an empty array
    ///   is allowed.
    public func reload(sections newSections: [TesseraPanoramaSection]) {
        // The current id comes from the OLD set: it is used to find the section in the new one.
        let oldSections = sections
        let previousIndex = clampedSectionIndex(currentSectionIndex)
        let previousID: AnyHashable? = oldSections.indices.contains(previousIndex)
            ? oldSections[previousIndex].id
            : nil

        // Stop inertia/animation before unloading sections: `contentOffset`
        // is written only by the controller (the single-writer contract).
        if isViewLoaded {
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        }
        _ = scrollView.consumePendingSnapOffsetX()

        // Loaded controllers, keyed by the old set's ids.
        var survivors: [(id: AnyHashable, controller: UIViewController)] = []
        for (index, controller) in loadedSections.sorted(by: { $0.key < $1.key }) {
            if oldSections.indices.contains(index) {
                survivors.append((oldSections[index].id, controller))
            } else {
                detach(controller)
            }
        }
        loadedSections.removeAll()

        self.sections = newSections

        if newSections.isEmpty {
            currentSectionIndex = 0
        } else if let previousID,
                  let preservedIndex = newSections.firstIndex(where: { $0.id == previousID }) {
            currentSectionIndex = preservedIndex
        } else {
            currentSectionIndex = min(max(previousIndex, 0), newSections.count - 1)
        }

        // Survivors in the new ±1 window stay (the same instance from the registry,
        // and the SwiftUI provider updates rootView); the rest are unloaded.
        let window = sectionWindow(around: currentSectionIndex)
        for survivor in survivors {
            if let newIndex = newSections.firstIndex(where: { $0.id == survivor.id }),
               window.contains(newIndex),
               loadedSections[newIndex] == nil {
                loadedSections[newIndex] = survivor.controller
                _ = contentHosting.viewController(
                    for: survivor.id,
                    provider: newSections[newIndex].content
                )
            } else {
                detach(survivor.controller)
                contentHosting.removeContent(for: survivor.id)
            }
        }
        if newSections.isEmpty {
            contentHosting.removeAll()
        }

        lastShownSectionIndex = nil
        savedReadingProgress = nil
        needsOffsetRestore = true

        guard isViewLoaded else { return }

        headerView.setTitles(newSections.map(\.title))
        scrollView.sectionCount = newSections.count
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    /// Delivers new content to sections with the same set of `id`s and titles.
    ///
    /// The SwiftUI facade path: when ``TesseraPanoramaView`` is redrawn with the same `id`s and
    /// titles, a full ``reload(sections:)`` is not needed (it stops
    /// scrolling and resets the shown section), but the content providers are new:
    /// their closures captured fresh state. Only the model is replaced here,
    /// and the loaded controllers receive the new content through
    /// ``TesseraContentHosting``: a SwiftUI controller updates its `rootView` in
    /// place (the same instance; position and `@State` are preserved); a UIKit provider
    /// cannot update an arbitrary controller, so the instance stays as it was.
    /// Sections that are not loaded will be created from the new providers when they load.
    /// `contentOffset`, the ±1 window, and the delegate are not affected.
    ///
    /// If the set of `id`s/titles does differ after all, a full
    /// ``reload(sections:)``.
    ///
    /// - Parameter newSections: Sections with the same order of `id`s and titles.
    func updateContent(of newSections: [TesseraPanoramaSection]) {
        guard Self.haveSameIdentity(sections, newSections) else {
            reload(sections: newSections)
            return
        }

        sections = newSections
        for index in loadedSections.keys where newSections.indices.contains(index) {
            // For valid sets (unique ids) the registry returns the same
            // loaded instance, updating its content in place.
            let section = newSections[index]
            _ = contentHosting.viewController(for: section.id, provider: section.content)
        }
    }

    /// Whether two section sets match by `id` and titles (in order).
    ///
    /// ``TesseraPanoramaSection`` is not `Equatable`: a content provider has no equality
    /// semantics, so the identity of a set is the `id` + `title` pairs.
    ///
    /// - Parameters:
    ///   - lhs: The first set.
    ///   - rhs: The second set.
    /// - Returns: `true` if the `id`s and titles match element by element.
    static func haveSameIdentity(_ lhs: [TesseraPanoramaSection], _ rhs: [TesseraPanoramaSection]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { $0.id == $1.id && $0.title == $1.title }
    }

    /// Navigates to a section programmatically.
    ///
    /// The only programmatic writer of `contentOffset` (the single-writer contract).
    /// During an animated transition, the delegate keeps receiving `didChangeProgress`
    /// on animation frames, so the headers and background animate on their own; there is no
    /// separate layer animation.
    ///
    /// With Reduce Motion, animation is forcibly disabled. The index
    /// is clamped to the bounds of the section set.
    ///
    /// An animated transition farther than the adjacent section is a "direct jump", like the
    /// Core pager: the ±1 window is first loaded around the target, the offset
    /// is moved without animation to the target's neighbor on the side of the current section, and
    /// one last step is animated, without flying over empty (unloaded)
    /// slots. The delegate receives one `didChangeProgress` with a jump to the target's
    /// neighbor (progress always reflects the actual offset), then the
    /// animation frames; `didShowSectionAt` is sent only for the target.
    ///
    /// - Parameters:
    ///   - index: The section index in reading order (in RTL, not the physical slot).
    ///   - animated: The intent to animate the transition; Reduce Motion takes priority.
    public func selectSection(at index: Int, animated: Bool) {
        guard !sections.isEmpty else { return }

        let targetIndex = clampedSectionIndex(index)
        let shouldAnimate = animated && !TesseraAccessibility.isReduceMotionEnabled

        currentSectionIndex = targetIndex

        guard isViewLoaded else {
            // Before the view loads, remember the intent: the first layout will place the offset
            // on the right section without an intermediate jump.
            needsOffsetRestore = true
            return
        }

        // The geometry must be current before the offset is computed. This is a layout path,
        // not the hot one: a programmatic transition does not run inside scrolling.
        view.layoutIfNeeded()

        // There is no width yet (the view is outside the hierarchy): remember the intent, and the
        // first real layout will set the offset, without a false section announcement.
        guard scrollView.bounds.width > 0 else {
            needsOffsetRestore = true
            return
        }

        let offset = CGPoint(x: scrollView.rawOffset(forReadingProgress: CGFloat(targetIndex)), y: 0)
        if abs(offset.x - scrollView.contentOffset.x) <= .ulpOfOne {
            // An in-place transition: there will be no animation, so we record completion ourselves;
            // otherwise `scrollViewDidEndScrollingAnimation` would never arrive.
            scrollView.setContentOffset(offset, animated: false)
            finishTransition()
            return
        }

        if shouldAnimate {
            let fromIndex = nearestSectionIndex(
                forReadingProgress: scrollView.readingProgress(forRawOffset: scrollView.contentOffset.x)
            )
            let distance = targetIndex - fromIndex
            if abs(distance) > 1 {
                // The target's window comes before the jump: the animation frame must not contain
                // empty slots. The hierarchy changes off the hot path.
                refreshLoadedSections(around: targetIndex)
                let neighbourIndex = targetIndex - distance.signum()
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.rawOffset(forReadingProgress: CGFloat(neighbourIndex)), y: 0),
                    animated: false
                )
                currentSectionIndex = targetIndex
            }
        }

        scrollView.setContentOffset(offset, animated: shouldAnimate)
        if !shouldAnimate {
            finishTransition()
        }
    }

    /// Registers a section's vertical scroll view.
    ///
    /// Horizontal belongs to ``TesseraPanoScrollView`` and vertical to the section's content.
    /// A content controller calls this method (for example, from `viewDidAppear`) and
    /// passes its vertical `UIScrollView`. For the duration of a horizontal gesture
    /// the controller builds a ``TesseraGestureArbiter`` from the registered children:
    /// their scrolling is blocked and restored to its original state when
    /// the gesture ends (`prepareForHorizontalScroll()` /
    /// `endHorizontalScroll()`).
    ///
    /// The references are weak: unloaded sections drop out of the registry on their own.
    ///
    /// - Parameter scrollView: The vertical scroll view of the section's content.
    ///
    /// - Note: **A deviation from the intended design.** The arbiter is not assigned as the delegate of the
    ///   panorama's `panGestureRecognizer`: replacing the delegate of a `UIScrollView`
    ///   would disable its own handling of simultaneous gestures (nested
    ///   scrolls, the system edge swipe). Therefore:
    ///   1. the decision by the dominant axis is made on the pan's first callback
    ///      (`.began`) through
    ///      ``TesseraGestureArbiter/axisDecision(forVelocity:)``, the same pure
    ///      function used in the arbiter's `gestureRecognizerShouldBegin`;
    ///   2. the children are blocked and unblocked by the arbiter's methods, so both
    ///      halves of the arbitration contract are used, but the decision point is moved
    ///      from `gestureRecognizerShouldBegin` to `.began`. This is the same compromise
    ///      as in `TesseraPivotViewController`.
    public func registerVerticalOwner(_ scrollView: UIScrollView) {
        guard scrollView !== self.scrollView else { return }

        pruneVerticalOwners()
        guard !verticalOwners.contains(where: { $0.scrollView === scrollView }) else { return }
        verticalOwners.append(WeakVerticalOwner(scrollView: scrollView))
    }

    /// Unregisters a section's vertical scroll view.
    ///
    /// Calling this is optional: references are weak, and deallocated scroll views drop out of
    /// arbitration on their own. The method is needed when a content controller stops
    /// using a scroll view but stays alive.
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
    /// ``TesseraAccessibility/pageStep(for:layoutDirection:)`` (taking RTL into account), and
    /// the transition is performed by ``selectSection(at:animated:)``, so `contentOffset`
    /// is still written by the controller. The method duplicates the handling in
    /// ``TesseraPanoScrollView``: the gesture can have different accessibility focus (the headers
    /// layer, the section content), and the result must be the same.
    ///
    /// - Parameter direction: The VoiceOver gesture direction.
    /// - Returns: `true` if the gesture was handled.
    public override func accessibilityScroll(
        _ direction: UIAccessibilityScrollDirection
    ) -> Bool {
        guard isViewLoaded, sections.count > 1 else { return false }

        let step = TesseraAccessibility.pageStep(
            for: direction,
            layoutDirection: view.effectiveUserInterfaceLayoutDirection
        )
        return handleAccessibilityStep(step)
    }

    // MARK: - Assembling the layers

    /// Creates the hierarchy: background, scroll view, headers.
    private func configureSubviews() {
        view.backgroundColor = .systemBackground
        view.clipsToBounds = true

        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.clipsToBounds = true
        backgroundImageView.isUserInteractionEnabled = false
        backgroundImageView.isAccessibilityElement = false
        parallaxLayer.addSubview(backgroundImageView)
        view.addSubview(parallaxLayer)

        scrollView.observer = self
        scrollView.peek = style.peek
        scrollView.snapPolicy = snapPolicy
        view.addSubview(scrollView)

        // The headers are the top layer: they are decorative (they have user
        // interaction disabled) and must not cover scrolling.
        view.addSubview(headerView)

        // VoiceOver focus may rest on the headers layer:
        // a three-finger swipe from it pages the sections just like from the content.
        headerView.accessibilityScrollHandler = { [weak self] direction in
            self?.accessibilityScroll(direction) ?? false
        }

        observeScrollPan()

        // Dynamic Type: the headers' height depends on the text size.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
    }

    /// Applies the style to the layers.
    ///
    /// `peek` is not written to the scroll view here: the layout pass applies it, and
    /// beforehand it saves the progress by the previous section width; otherwise the section
    /// would be left between snap points.
    private func applyStyle() {
        guard isViewLoaded else { return }

        scrollView.contentInsetAdjustmentBehavior = style.contentInsetAdjustmentBehavior
        headerView.style = Self.makeHeaderStyle(from: style)
        applyBackgroundBehavior()
        view.setNeedsLayout()
    }

    /// Carries the background behavior from the style into the layer.
    ///
    /// In v1 there is one background for the whole panorama: `.image` is an image over the whole layer,
    /// `.none` is a transparent layer, and the system background under the panorama shows through.
    private func applyBackgroundBehavior() {
        switch style.backgroundBehavior {
        case .none:
            backgroundImageView.image = nil
            backgroundImageView.isHidden = true
        case .image(let image):
            backgroundImageView.image = image
            backgroundImageView.isHidden = (image == nil)
        }
    }

    /// The headers style derived from the panorama style.
    ///
    /// `TesseraPanoramaStyle.headerFont` is the base (unscaled) font: the headers
    /// layer scales it itself through `UIFontMetrics` for Dynamic Type.
    ///
    /// `TesseraPanoramaStyle.headerActiveColor` goes into the layer as the color of the active
    /// header, interpolated by `t`. If it equals
    /// `headerColor`, no accent is needed and the layer creates no accent copies of the labels.
    private static func makeHeaderStyle(from style: TesseraPanoramaStyle) -> PanoHeaderView.Style {
        PanoHeaderView.Style(
            textStyle: .largeTitle,
            baseFont: style.headerFont,
            textColor: style.headerColor,
            activeTextColor: style.headerActiveColor == style.headerColor
                ? nil
                : style.headerActiveColor,
            travelRatio: 0.3,
            contentInsets: UIEdgeInsets(
                top: 8,
                left: Metrics.headerSideInset,
                bottom: 8,
                right: Metrics.headerSideInset
            ),
            numberOfLines: 0
        )
    }

    // MARK: - Layout (the only place layout happens)

    /// Lays out the headers, the scroll view, the sections, the background, and `contentSize`.
    ///
    /// Called only from `viewDidLayoutSubviews` and from synchronous
    /// `layoutIfNeeded` calls in public methods. There is no layout in `scrollViewDidScroll`
    /// (see the performance rule in the design document).
    private func layoutPanorama() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        // During an active swipe, a size change is better deferred until the end of
        // deceleration: rebuilding contentSize would jerk the offset under the finger.
        if scrollView.isUserScrollInFlight {
            needsDeferredLayout = true
            return
        }

        // The reading direction of the root view is the single source for the layers:
        // `semanticContentAttribute` is not inherited by subviews, and the scroll view and
        // headers compute slots/mirroring from their own direction.
        if scrollView.semanticContentAttribute != view.semanticContentAttribute {
            scrollView.semanticContentAttribute = view.semanticContentAttribute
        }
        if headerView.semanticContentAttribute != view.semanticContentAttribute {
            headerView.semanticContentAttribute = view.semanticContentAttribute
        }

        let direction = view.effectiveUserInterfaceLayoutDirection
        // The direction in which the slots are currently laid out and the offset sits.
        let slotDirection = lastLayoutDirection ?? direction
        // The style's `peek` has not been applied to the scroll view yet: a section width change on the fly
        // is the same kind of geometry change as a rotation.
        let peekChanged = abs(scrollView.peek - style.peek) > .ulpOfOne
        let geometryChanged = lastLayoutWidth > 0
            && (abs(bounds.width - lastLayoutWidth) > .ulpOfOne
                || abs(bounds.height - lastLayoutHeight) > .ulpOfOne
                || slotDirection != direction
                || peekChanged)

        // The fraction within a section is saved before itemWidth changes; after
        // the recomputation it could no longer be restored. Normalization uses the direction
        // the offset sits in now, not the new one: otherwise, on an LTR↔RTL switch, the
        // mirrored section would open. The scroll view is still in its previous
        // geometry here: the frame and peek are applied below.
        if geometryChanged, sections.count > 1 {
            savedReadingProgress = scrollView.readingProgress(
                forRawOffset: scrollView.contentOffset.x,
                layoutDirection: slotDirection
            )
        }

        // Writing the frame, contentSize, and offset is a consequence of recomputing geometry,
        // not user progress: UIKit may send `scrollViewDidScroll` for them,
        // and the delegate must not receive a false
        // `didChangeProgress`, nor the current section get lost. The final
        // progress is applied once at the end of the pass.
        isRestoringGeometry = true
        layoutHeader(in: bounds)

        let contentTop = headerView.isHidden
            ? 0
            : min(headerView.frame.maxY + Metrics.headerBottomSpacing, bounds.height)
        scrollView.frame = CGRect(
            x: 0,
            y: contentTop,
            width: bounds.width,
            height: max(bounds.height - contentTop, 0)
        )

        // Content geometry: itemWidth = width − peek, contentSize by the number of
        // sections. Order matters: contentSize before restoring the offset, otherwise
        // UIKit would clamp the offset to the old size.
        scrollView.peek = style.peek
        scrollView.sectionCount = sections.count
        scrollView.isScrollEnabled = sections.count > 1
        scrollView.contentSize = scrollView.requiredContentSize

        restoreOffsetIfNeeded(geometryChanged: geometryChanged)
        isRestoringGeometry = false

        layoutBackground()
        refreshLoadedSections(around: currentSectionIndex)
        layoutSectionFrames()
        applyProgress(notifyDelegate: false)

        lastLayoutWidth = bounds.width
        lastLayoutHeight = bounds.height
        lastLayoutDirection = direction
        needsDeferredLayout = false
    }

    /// Lays out the headers layer.
    ///
    /// The height comes from `intrinsicContentSize`, that is, from the actual labels and
    /// the current Dynamic Type. The width is set before reading intrinsic: the headers
    /// compute their height from the actual width.
    private func layoutHeader(in bounds: CGRect) {
        guard !sections.isEmpty else {
            headerView.isHidden = true
            headerView.frame = .zero
            return
        }

        headerView.isHidden = false

        // The width is needed before the height: the headers' `intrinsicContentSize` depends on
        // the layer's width. Writing `frame.size` directly does not trigger layout twice.
        headerView.frame.size.width = bounds.width
        let height = max(headerView.intrinsicContentSize.height, 0)

        headerView.frame = CGRect(
            x: 0,
            y: view.safeAreaInsets.top + Metrics.headerTopPadding,
            width: bounds.width,
            height: height
        )
    }

    /// Lays out the background layer for parallax.
    ///
    /// The Core contract (`docs/CORE-IOS-DESIGN.md`, parallax): the layer is
    /// always larger than the content: `contentSize` plus the `extraSize` margin. Here
    /// `contentSize` is the panorama's content size (but not smaller than the viewport, otherwise
    /// the empty state would be left without a background), and the margin is the whole background travel
    /// (`maximumOffsetX × factor`) plus the rubber-band margins at the edges.
    ///
    /// The layer is a sibling of the scroll view, so ``TesseraParallaxLayer/update(withContentOffset:)``
    /// projects the background offset (`backgroundOffset = offset × factor`) onto the screen
    /// with a minus sign: `transform = −backgroundOffset`. As the offset grows,
    /// the background moves left together with the sections, but more slowly. The layer's origin is at the left
    /// edge of the viewport, shifted left only by the `padding` margin (for the rubber band before
    /// the start of the strip, where offset < 0); the whole background travel `shift` and the right margin lie
    /// to the right of the viewport. The on-screen left edge of the image is `−padding − offset × factor`
    /// and the right edge is `width + shift + padding − offset × factor`: the viewport is covered at
    /// any offset in `[−padding / factor, maximumOffsetX + padding / factor]`,
    /// so there are no empty strips either during bounce or at the edge of the strip. The image itself
    /// covers only the window that is actually visited, not the whole area of the huge layer.
    ///
    /// The multiplier is taken from the style, not the effective one: with Reduce Motion
    /// the effective factor is zero, but the margin must remain
    /// sufficient if the setting is turned off on the fly.
    private func layoutBackground() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let factor = style.parallaxFactor
        let shift = scrollView.maximumOffsetX * factor
        // The rubber band moves contentOffset past the edge of the strip; the margin on both sides
        // covers an overshoot of `padding / factor`. The `0.6 × width × factor` term
        // guarantees at least 0.6 of the screen width for any factor in (0, 1)
        // (the clamp was widened from 0.4…0.6 to 0.01…0.99); the other terms are the previous
        // minimum for typical factors.
        let padding = max(
            Metrics.backgroundBouncePadding,
            bounds.width * 0.35,
            bounds.width * 0.6 * factor
        )

        let contentSize = CGSize(
            width: max(scrollView.contentSize.width, bounds.width),
            height: max(scrollView.contentSize.height, bounds.height)
        )
        parallaxLayer.configure(factor: factor, extraSize: shift + padding * 2)
        parallaxLayer.setContentSize(contentSize)

        let size = parallaxLayer.bounds.size
        // The layer's origin shifts left only by the rubber band: the layer moves left
        // (transform = −offset × factor), so the background travel `shift` is needed
        // on the right. Then at any offset the viewport stays inside the image,
        // which is pinned to the layer's origin.
        parallaxLayer.center = CGPoint(
            x: -padding + size.width / 2,
            y: size.height / 2
        )

        // The visible background window for the whole strip: the viewport, the background travel, and the rubber band at the edges.
        // There is no point filling the rest of the huge layer: it is not visible.
        backgroundImageView.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width + shift + padding * 2,
            height: bounds.height
        )
    }

    /// Restores the current section's `contentOffset`.
    ///
    /// Restoration is a programmatic write of `contentOffset` from layout:
    /// the caller keeps `isRestoringGeometry` raised, and progress callbacks to
    /// the delegate are switched off meanwhile.
    ///
    /// - Parameter geometryChanged: The width/height/reading direction/peek changed.
    private func restoreOffsetIfNeeded(geometryChanged: Bool) {
        guard !sections.isEmpty else {
            if scrollView.contentOffset != .zero {
                scrollView.contentOffset = .zero
            }
            needsOffsetRestore = false
            savedReadingProgress = nil
            return
        }

        if needsOffsetRestore {
            // The first layout, `reload`, or a direction change: land exactly on
            // the saved section, with no transition fraction.
            scrollView.setContentOffset(
                CGPoint(
                    x: scrollView.rawOffset(
                        forReadingProgress: CGFloat(clampedSectionIndex(currentSectionIndex))
                    ),
                    y: 0
                ),
                animated: false
            )
            needsOffsetRestore = false
            savedReadingProgress = nil
            return
        }

        if geometryChanged, let progress = savedReadingProgress {
            // Restore "by index and saved progress": the fraction within a section
            // is preserved if it is representable in the new bounds.
            scrollView.setContentOffset(
                CGPoint(x: scrollView.rawOffset(forReadingProgress: progress), y: 0),
                animated: false
            )
            savedReadingProgress = nil
            return
        }

        // The number of sections may have decreased, so the offset must be clamped.
        let maximum = scrollView.maximumOffsetX
        let clampedX = min(max(scrollView.contentOffset.x, 0), maximum)
        if clampedX != scrollView.contentOffset.x {
            scrollView.contentOffset = CGPoint(x: clampedX, y: 0)
        }
    }

    /// Lays out the frames of the loaded child controllers.
    ///
    /// The only place their `frame` changes; frames are not touched during scrolling
    /// (see the performance rule in the design document).
    private func layoutSectionFrames() {
        for (index, controller) in loadedSections {
            let frame = scrollView.rect(forReadingIndex: index)
            guard controller.view.frame != frame else { continue }
            controller.view.frame = frame
        }
    }

    // MARK: - Progress (the hot path)

    /// Applies the current `contentOffset` to the layers and the delegate.
    ///
    /// On the hot path (from `scrollViewDidScroll`) only `transform` and
    /// `alpha` change: `headerView.apply` and `parallaxLayer.update` do not trigger layout
    /// (see the performance rule in the design document). `notifyDelegate: false` is used in
    /// the layout pass and when synchronizing state, where external progress is not an
    /// event.
    ///
    /// - Parameter notifyDelegate: Whether to report `didChangeProgress` to the delegate.
    private func applyProgress(notifyDelegate: Bool) {
        let rawOffset = scrollView.contentOffset.x
        let progress = scrollView.readingProgress(forRawOffset: rawOffset)
        guard progress.isFinite else { return }

        currentSectionIndex = nearestSectionIndex(forReadingProgress: progress)

        // The background and headers are animated from the same t.
        headerView.apply(progress: progress, activeIndex: currentSectionIndex)
        parallaxLayer.update(withContentOffset: CGPoint(x: rawOffset, y: 0))

        guard notifyDelegate, !isRestoringGeometry else { return }
        delegate?.panorama(self, didChangeProgress: progress)
    }

    /// The section nearest to the progress, in reading order.
    ///
    /// The progress is already normalized by the reading direction, so the index is simply
    /// a rounding clamped to the bounds of the set.
    private func nearestSectionIndex(forReadingProgress progress: CGFloat) -> Int {
        guard !sections.isEmpty else { return 0 }
        let last = CGFloat(sections.count - 1)
        return Int(min(max(progress, 0), last).rounded())
    }

    // MARK: - Lazy loading of child view controllers

    /// Keeps the current section and its ±1 neighbors in memory and unloads the rest.
    ///
    /// Called when a transition completes, from layout, and from `viewDidAppear`, but
    /// never from `scrollViewDidScroll`: adding a child view controller is a hierarchy
    /// change, not work for a scroll frame.
    ///
    /// - Parameter index: The section around which the window is built.
    private func refreshLoadedSections(around index: Int) {
        guard !sections.isEmpty, scrollView.bounds.width > 0 else { return }

        let desired = sectionWindow(around: index)

        for loadedIndex in Array(loadedSections.keys) where !desired.contains(loadedIndex) {
            guard let controller = loadedSections.removeValue(forKey: loadedIndex) else {
                continue
            }
            detach(controller)
            if sections.indices.contains(loadedIndex) {
                contentHosting.removeContent(for: sections[loadedIndex].id)
            }
        }

        for sectionIndex in desired.sorted() where loadedSections[sectionIndex] == nil {
            loadSection(at: sectionIndex)
        }
    }

    /// Loads the window around the target **without unloading** the current section.
    ///
    /// The prefetch hook is called from `scrollViewWillEndDragging`: the snap target is already
    /// known, but the visible section is still in frame, so unloading here would give an
    /// empty frame. ``refreshLoadedSections(around:)`` does the freeing when the
    /// transition completes.
    ///
    /// - Parameter index: The snap's target section.
    private func prefetchSections(around index: Int) {
        guard !sections.isEmpty, scrollView.bounds.width > 0 else { return }

        for sectionIndex in sectionWindow(around: index).sorted()
        where loadedSections[sectionIndex] == nil {
            loadSection(at: sectionIndex)
        }
    }

    /// The indices of the ±1 window around a section; empty for an empty set.
    private func sectionWindow(around index: Int) -> Set<Int> {
        guard !sections.isEmpty else { return [] }
        let center = clampedSectionIndex(index)
        return Set([center - 1, center, center + 1].filter { sections.indices.contains($0) })
    }

    /// Creates a section controller and attaches it as a child view controller.
    ///
    /// The controller is taken from ``TesseraContentHosting`` by the section's `id`: loading
    /// the same `id` again reuses the instance (for SwiftUI content it
    /// updates `rootView` in place).
    ///
    /// - Parameter index: The section index in reading order.
    private func loadSection(at index: Int) {
        guard sections.indices.contains(index) else { return }

        let section = sections[index]
        var controller = contentHosting.viewController(
            for: section.id,
            provider: section.content
        )

        // Guard against a repeated id: one controller cannot be added twice.
        // For valid sets (unique ids) this branch does not run.
        if loadedSections.values.contains(where: { $0 === controller }) {
            controller = section.content.makeContentViewController()
        }

        addChild(controller)
        controller.view.frame = scrollView.rect(forReadingIndex: index)
        scrollView.addSubview(controller.view)
        controller.didMove(toParent: self)
        loadedSections[index] = controller
    }

    /// Detaches a child view controller from the controller.
    private func detach(_ controller: UIViewController) {
        guard controller.parent != nil else {
            controller.view.removeFromSuperview()
            return
        }

        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    // MARK: - Completing a transition

    /// Records the current section, updates the ±1 window, and notifies the delegate.
    ///
    /// Called when a gesture without inertia, deceleration, or a programmatic
    /// animation completes, off the scroll hot path.
    private func finishTransition() {
        guard !sections.isEmpty else { return }

        if scrollView.bounds.width > 0 {
            applyProgress(notifyDelegate: false)
            refreshLoadedSections(around: currentSectionIndex)
        }

        reportCurrentSectionIfNeeded()
        applyDeferredLayoutIfNeeded()
    }

    /// Reports a section change to the delegate and announces its name.
    private func reportCurrentSectionIfNeeded() {
        guard sections.indices.contains(currentSectionIndex) else { return }
        guard lastShownSectionIndex != currentSectionIndex else { return }

        lastShownSectionIndex = currentSectionIndex
        announceSection(at: currentSectionIndex)
        delegate?.panorama(self, didShowSectionAt: currentSectionIndex)
    }

    /// Announces the section name on a change.
    ///
    /// Called when a transition completes: during the animation, an announcement is interrupted
    /// by the accessibility focus change (see ``TesseraAccessibility/announcePageChange(_:)``).
    /// An empty title is not announced.
    ///
    /// - Parameter index: The index of the shown section in reading order.
    private func announceSection(at index: Int) {
        guard sections.indices.contains(index) else { return }

        let title = sections[index].title
        guard !title.isEmpty else { return }

        TesseraAccessibility.announcePageChange(title)
    }

    /// Applies early a layout that was deferred because of scrolling.
    ///
    /// The deferred pass has already "spent" the view's `needsLayout` flag, so
    /// a single `layoutIfNeeded()` is not enough: without `setNeedsLayout()` it does nothing,
    /// and the new geometry (a rotation during a swipe) would not be applied until
    /// some later pass happened to run.
    private func applyDeferredLayoutIfNeeded() {
        guard needsDeferredLayout, !scrollView.isUserScrollInFlight else { return }

        needsDeferredLayout = false
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    /// Clamps an index to the bounds of the section set.
    private func clampedSectionIndex(_ index: Int) -> Int {
        guard !sections.isEmpty else { return 0 }
        return min(max(index, 0), sections.count - 1)
    }

    // MARK: - Vertical scroll arbitration

    /// Subscribes to the panorama's pan states without replacing its delegate.
    ///
    /// `addTarget` is additive and does not break `UIScrollView`'s internal handling, unlike
    /// replacing `panGestureRecognizer.delegate` (why that is dangerous:
    /// see ``registerVerticalOwner(_:)``).
    private func observeScrollPan() {
        let pan = scrollView.panGestureRecognizer
        guard observedPan !== pan else { return }

        observedPan?.removeTarget(self, action: #selector(scrollPanDidChange(_:)))
        pan.addTarget(self, action: #selector(scrollPanDidChange(_:)))
        observedPan = pan
    }

    /// The panorama pan's states: blocking and unblocking the vertical children.
    ///
    /// - Parameter pan: The pan of ``TesseraPanoScrollView``.
    @objc private func scrollPanDidChange(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            beginHorizontalScroll(with: pan)
        case .ended, .cancelled, .failed:
            endHorizontalScroll()
        case .possible, .changed:
            break
        @unknown default:
            endHorizontalScroll()
        }
    }

    /// Begins a horizontal gesture: creates the arbiter and blocks the children.
    ///
    /// The axis is determined from the pan's first available vector (at zero velocity,
    /// from the translation: for comparing magnitudes the scale does not matter). If the gesture is
    /// vertical, the pager does not lead it and the children's scrolling is not blocked;
    /// otherwise disabling the scroll would stop a vertical scroll of the section
    /// that has already begun.
    ///
    /// - Parameter pan: The pan that entered the `.began` state.
    private func beginHorizontalScroll(with pan: UIPanGestureRecognizer) {
        let velocity = pan.velocity(in: pan.view)
        let vector = velocity == .zero ? pan.translation(in: pan.view) : velocity
        guard TesseraGestureArbiter.axisDecision(forVelocity: vector) == .horizontal else {
            endHorizontalScroll()
            return
        }

        // Guard against overlapping gestures: an unfinished arbiter first returns
        // the children to their original state; otherwise the `isScrollEnabled` snapshot would be lost.
        if gestureArbiter != nil {
            endHorizontalScroll()
        }

        pruneVerticalOwners()
        let owners = liveVerticalOwners
        guard !owners.isEmpty else { return }

        let arbiter = TesseraGestureArbiter(horizontalOwner: scrollView, verticalOwners: owners)
        arbiter.prepareForHorizontalScroll()
        gestureArbiter = arbiter
    }

    /// Ends the horizontal gesture: returns the children's scrolling to its original state.
    ///
    /// After that the arbiter is released: the controller holds no strong references to the sections' scroll views
    /// between gestures, and unloaded sections do not live on in the arbiter.
    private func endHorizontalScroll() {
        gestureArbiter?.endHorizontalScroll()
        gestureArbiter = nil
        pruneVerticalOwners()
    }

    /// The live registered owners (excluding the panorama's own scroll view).
    private var liveVerticalOwners: [UIScrollView] {
        verticalOwners
            .compactMap(\.scrollView)
            .filter { $0 !== scrollView }
    }

    /// Removes released scroll views from the registry (sections live in a ±1 window).
    private func pruneVerticalOwners() {
        verticalOwners.removeAll { $0.scrollView == nil }
    }

    // MARK: - Notifications

    /// The Dynamic Type text size changed: the headers need a new layout
    /// The fonts themselves are updated by ``PanoHeaderView``.
    @objc private func contentSizeCategoryDidChange() {
        guard isViewLoaded else { return }
        view.setNeedsLayout()
    }
}

// MARK: - PanoScrollViewObserving

extension TesseraPanoramaViewController: PanoScrollViewObserving {

    /// The scrolling hot path: only `transform`/`alpha` and the delegate callback.
    ///
    /// - Parameter scrollView: The event source.
    func panoScrollViewDidScroll(_ scrollView: TesseraPanoScrollView) {
        // Writing geometry in the layout pass is not progress: the pass itself will apply the
        // result.
        guard !isRestoringGeometry else { return }
        applyProgress(notifyDelegate: true)
    }

    /// The gesture ended: the snap target is known, so load the neighbor before inertia.
    ///
    /// - Parameters:
    ///   - scrollView: The event source.
    ///   - velocityX: The gesture velocity (unused: the snapping policy decides).
    ///   - targetReadingIndex: The target section in reading order.
    func panoScrollViewWillEndDragging(
        _ scrollView: TesseraPanoScrollView,
        velocityX: CGFloat,
        targetReadingIndex: Int
    ) {
        prefetchSections(around: targetReadingIndex)
    }

    /// The gesture finished without inertia: settle the snap, or finish at once.
    ///
    /// At zero velocity UIKit does not start inertia and ignores the
    /// `targetContentOffset` modified in `scrollViewWillEndDragging`, so the offset would stay
    /// between snap points. The controller, as the programmatic writer of `contentOffset`
    /// (the single-writer contract), settles it to the policy's target with an animation and
    /// completes the transition in `scrollViewDidEndScrollingAnimation`. With Reduce
    /// Motion the settle is instantaneous.
    ///
    /// - Parameters:
    ///   - scrollView: The event source.
    ///   - decelerate: Whether inertia will begin.
    func panoScrollViewDidEndDragging(
        _ scrollView: TesseraPanoScrollView,
        willDecelerate decelerate: Bool
    ) {
        let snapTarget = scrollView.consumePendingSnapOffsetX()
        guard !decelerate else { return }

        if let alignedX = scrollView.alignedSnapOffsetX(preferred: snapTarget),
           abs(scrollView.contentOffset.x - alignedX) > Metrics.alignmentTolerance {
            let target = CGPoint(x: alignedX, y: scrollView.contentOffset.y)
            if TesseraAccessibility.isReduceMotionEnabled {
                scrollView.setContentOffset(target, animated: false)
            } else {
                // The transition will be completed by `panoScrollViewDidEndScrollingAnimation`.
                scrollView.setContentOffset(target, animated: true)
                return
            }
        }
        finishTransition()
    }

    /// Inertia ended: record the shown section.
    ///
    /// - Parameter scrollView: The event source.
    func panoScrollViewDidEndDecelerating(_ scrollView: TesseraPanoScrollView) {
        finishTransition()
    }

    /// The programmatic animation finished: record the shown section.
    ///
    /// - Parameter scrollView: The event source.
    func panoScrollViewDidEndScrollingAnimation(_ scrollView: TesseraPanoScrollView) {
        finishTransition()
    }

    /// The VoiceOver three-finger gesture from the scroll view.
    ///
    /// - Parameters:
    ///   - scrollView: The event source.
    ///   - step: The step through the sections in reading order (already adjusted for RTL).
    /// - Returns: `true` if the transition was performed.
    func panoScrollView(_ scrollView: TesseraPanoScrollView, accessibilityStep step: Int) -> Bool {
        // Take the index from the actual offset, not from a cache: the gesture may have arrived
        // before the previous transition completed.
        applyProgress(notifyDelegate: false)
        return handleAccessibilityStep(step)
    }

    /// Performs a VoiceOver step through the sections.
    ///
    /// `contentOffset` is written only by the controller, through
    /// ``selectSection(at:animated:)`` (the single-writer contract).
    ///
    /// - Parameter step: `+1` is the next section and `-1` the previous one.
    /// - Returns: `true` if the transition was performed.
    private func handleAccessibilityStep(_ step: Int) -> Bool {
        guard step != 0, sections.count > 1 else { return false }

        let targetIndex = currentSectionIndex + step
        guard sections.indices.contains(targetIndex) else { return false }

        selectSection(at: targetIndex, animated: !TesseraAccessibility.isReduceMotionEnabled)
        return true
    }
}

/// The panorama's root view: a `semanticContentAttribute` change on the fly marks
/// layout as needed so that `layoutPanorama()` carries the direction over to the layers and re-lays out
/// the slots, preserving the current section.
private final class PanoramaRootView: UIView {
    override var semanticContentAttribute: UISemanticContentAttribute {
        didSet {
            if oldValue != semanticContentAttribute {
                setNeedsLayout()
            }
        }
    }
}
#endif
