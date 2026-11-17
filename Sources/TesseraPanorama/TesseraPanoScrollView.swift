//
//  TesseraPanoScrollView.swift
//  TesseraPanorama
//
//  The horizontal scroll view of the panorama: sections narrower than the screen (peek), custom snapping, and
//  the single source of the progress `t`.
//  Design document: docs/PANORAMA-IOS-DESIGN.md (conceptual
//  architecture: the TesseraPanoScrollView layer under TesseraPanoramaViewController; core geometry
//  and math: `itemWidth = screenWidth − peek`; `t = offset.x / itemWidth`;
//  snapping via `targetContentOffset(forProposedContentOffset:withScrollingVelocity:)`;
//  `decelerationRate = .fast`; standard bounce at the edges),
//  performance (no layout in `scrollViewDidScroll`), accessibility
//  (VoiceOver, RTL), and adaptivity (a single section: no snapping, centered).
//

#if canImport(UIKit)
import TesseraCore
import UIKit

/// An observer of ``TesseraPanoScrollView`` events.
///
/// The protocol is module-internal: the panorama exposes only ``TesseraPanoramaDelegate`` publicly,
/// and the scroll lifecycle is a core detail (see `docs/PANORAMA-IOS-DESIGN.md`).
/// The observer reference is weak: the scroll view is retained by the controller, so there is no
/// strong back reference.
protocol PanoScrollViewObserving: AnyObject {

    /// The content scrolled: the per-frame hot path.
    ///
    /// The observer must restrict itself to `frame`/`transform`/`alpha`: layout is
    /// forbidden in this call.
    ///
    /// - Parameter scrollView: The event source.
    func panoScrollViewDidScroll(_ scrollView: TesseraPanoScrollView)

    /// The gesture ended and the system is about to start inertia.
    ///
    /// Provides the already computed target index **in reading order**; this is the point
    /// for prefetching the neighbor before the snap.
    ///
    /// - Parameters:
    ///   - scrollView: The event source.
    ///   - velocityX: The gesture's horizontal velocity in pt/s (signed, in physical
    ///     content coordinates, as in `UIScrollView`).
    ///   - targetReadingIndex: The index, in reading order, of the section the scroll will settle on
    ///     (mirrored through ``TesseraRTL`` in RTL).
    func panoScrollViewWillEndDragging(
        _ scrollView: TesseraPanoScrollView,
        velocityX: CGFloat,
        targetReadingIndex: Int
    )

    /// The gesture finished; `decelerate == false` means there will be no inertial motion.
    ///
    /// - Parameters:
    ///   - scrollView: The event source.
    ///   - decelerate: Whether inertia will begin after the gesture.
    func panoScrollViewDidEndDragging(_ scrollView: TesseraPanoScrollView, willDecelerate decelerate: Bool)

    /// Inertia ended: the snap settled on a section.
    ///
    /// - Parameter scrollView: The event source.
    func panoScrollViewDidEndDecelerating(_ scrollView: TesseraPanoScrollView)

    /// A programmatic `setContentOffset(_:animated:)` animation finished.
    ///
    /// - Parameter scrollView: The event source.
    func panoScrollViewDidEndScrollingAnimation(_ scrollView: TesseraPanoScrollView)

    /// The VoiceOver three-finger gesture: a step through the sections in reading order.
    ///
    /// - Parameters:
    ///   - scrollView: The event source.
    ///   - step: `+1` is the next section and `-1` the previous one (already adjusted for RTL).
    /// - Returns: `true` if the transition was performed.
    func panoScrollView(_ scrollView: TesseraPanoScrollView, accessibilityStep step: Int) -> Bool
}

/// The panorama's horizontal scroll view with non-full-page sections and custom
/// snapping (see docs/PANORAMA-IOS-DESIGN.md).
///
/// ## Role in the architecture
///
/// ```
/// TesseraPanoramaViewController  ← orchestration, child view controllers, background, headers
///     └─ TesseraPanoScrollView    ← horizontal only, geometry and snapping
/// ```
///
/// The scroll view owns **only** the section geometry, snapping, and the scroll
/// lifecycle. The hierarchy of child controllers, the background, headers, the delegate, and
/// accessibility announcements belong to ``TesseraPanoramaViewController``: it receives events
/// through the module-internal ``PanoScrollViewObserving``. `contentOffset` is written
/// exclusively by this scroll view's gesture and the controller's programmatic transition, so the
/// single-writer rule from `docs/CORE-IOS-DESIGN.md` is respected.
///
/// ## Geometry
///
/// - `itemWidth = bounds.width − peek`, with `peek` in the range 16…64 pt;
/// - section `i` (in reading order) sits in the physical slot
///   `slot = i` (LTR) or `slot = sectionCount − 1 − i` (RTL), at x =
///   `slot × itemWidth` (+ `peek` in RTL, a mirrored margin at the start of the strip);
/// - `contentSize.width = sectionCount × itemWidth + peek`: the extra
///   `peek` strip at the end of the strip lets the last section align to the leading
///   edge and shows the background in the peeking zone at the boundary;
/// - the alignment of section `i` is `offset.x = slot × itemWidth`;
/// - the progress `t = offset.x / itemWidth` is raw in ``currentProgress()``
///   (physical content coordinates), and in reading order it is provided by
///   ``readingProgress(forRawOffset:)``: in RTL it is normalized through
///   ``TesseraRTL`` (see the RTL notes in the design document).
///
/// In alignment coordinates the raw progress is always an integer (`slot`), so the
/// ``TesseraRTL`` normalization gives exactly the section index in reading order:
/// the "integer part of `t` is the index" invariant holds without corrections.
///
/// ## Snapping
///
/// `isPagingEnabled = false` (full-page paging cannot do peek),
/// `decelerationRate = .fast`, and the target is computed in
/// `scrollViewWillEndDragging(_:withVelocity:targetContentOffset:)` through
/// ``TesseraSnapPolicy``: the nearest center plus a velocity threshold. The policy
/// clamps the result to `0...(sectionCount − 1) × itemWidth`, which matches this scroll view's
/// valid `contentOffset` range, so the rubber band at the
/// edges stays standard and snapping does not interfere with bounce.
///
/// ## Performance discipline
///
/// ``scrollViewDidScroll(_:)`` only forwards the event to the observer: there is no layout
/// and no change to `contentSize` or frames here. The controller sets the geometry
/// in `viewDidLayoutSubviews`.
///
/// - Important: The scroll view's delegate is occupied by the scrolling itself (self-delegation).
///   Do not assign your own `delegate`: that would disable snapping and the observer
///   events. The public configuration is ``snapPolicy`` and ``peek``.
/// - Important: Main thread only: UIKit state is not spread across modules
///   (`docs/CORE-IOS-DESIGN.md`).
public final class TesseraPanoScrollView: UIScrollView, UIScrollViewDelegate {

    // MARK: - Geometry constants

    /// The working range of ``peek``: 16…64 pt.
    private static let peekRange: ClosedRange<CGFloat> = 16...64

    /// The default value of ``peek`` (the middle of the range).
    private static let defaultPeek: CGFloat = 48

    // MARK: - Public state

    /// The margin for peeking at the next section, in points.
    ///
    /// `itemWidth = bounds.width − peek`. Like ``TesseraPanoramaStyle/peek``,
    /// the value is kept in the range `16...64`; `NaN` and infinities
    /// are treated as the default `48`. Writing does not change the geometry by itself:
    /// the controller recomputes `contentSize` in its layout pass.
    public var peek: CGFloat {
        get { storedPeek }
        set { storedPeek = Self.sanitizedPeek(newValue) }
    }

    /// The snapping policy (`TesseraSnapPolicy` from `docs/CORE-IOS-DESIGN.md`).
    ///
    /// The snapping formula lives in Core and is pure: the scroll view only supplies
    /// the actual section width and the gesture velocity. Changing the policy does not perform
    /// layout and takes effect from the next gesture.
    public var snapPolicy: TesseraSnapPolicy

    /// The number of panorama sections; set by the controller.
    ///
    /// It affects ``itemWidth`` (a single section takes the full width), `contentSize`,
    /// snapping, and bounce: with `sectionCount <= 1` there is nowhere to page, so
    /// horizontal bounce and scrolling are disabled (a single section: no
    /// snapping, centered).
    public var sectionCount: Int {
        get { storedSectionCount }
        set {
            let clamped = max(newValue, 0)
            guard clamped != storedSectionCount else { return }
            storedSectionCount = clamped
            alwaysBounceHorizontal = clamped > 1
        }
    }

    /// The width of a single section: `bounds.width − peek`.
    ///
    /// For an empty panorama and for a single section it equals the scroll view's width:
    /// there is nothing to peek at, and the canvas takes the full width. The value is always
    /// greater than zero for non-empty `bounds`; the division in
    /// ``currentProgress()``.
    public var itemWidth: CGFloat {
        let width = bounds.width
        guard width > 0 else { return 0 }
        guard storedSectionCount > 1 else { return width }
        return max(width - effectivePeek, 1)
    }

    // MARK: - Internal state

    /// The observer of the scroll lifecycle (the panorama controller).
    weak var observer: PanoScrollViewObserving?

    /// The storage for ``peek``, validated on write.
    private var storedPeek: CGFloat = TesseraPanoScrollView.defaultPeek

    /// The storage for ``sectionCount``, validated on write.
    private var storedSectionCount: Int = 0

    /// `contentOffset.x` at the start of a gesture: the anchor for the ±1 snap step.
    private var dragStartOffsetX: CGFloat?

    /// The snap target of the last `scrollViewWillEndDragging`.
    ///
    /// At zero velocity UIKit ignores a modified `targetContentOffset`
    /// and does not move the offset to the target; the controller picks it up through
    /// ``consumePendingSnapOffsetX()`` and settles the offset itself.
    private var pendingSnapOffsetX: CGFloat?

    /// An override of the "gesture or inertia in progress" flag for tests.
    ///
    /// `isDragging`/`isDecelerating` are read-only UIKit properties and cannot
    /// be set without a real touch. `nil` means the actual state.
    var interactionOverrideForTesting: Bool?

    /// Whether user scrolling is in progress: a gesture or inertia.
    var isUserScrollInFlight: Bool {
        interactionOverrideForTesting ?? (isDragging || isDecelerating)
    }

    /// ``peek`` with a guaranteed range (a safeguard for values received before init).
    private var effectivePeek: CGFloat { Self.sanitizedPeek(storedPeek) }

    /// The reading direction of the current hierarchy (for slots and progress normalization).
    ///
    /// Progress and index are computed from the reading direction (see the RTL notes in the design document).
    var resolvedLayoutDirection: UIUserInterfaceLayoutDirection {
        effectiveUserInterfaceLayoutDirection
    }

    // MARK: - Lifecycle

    /// Creates the panorama scroll view.
    ///
    /// - Parameters:
    ///   - peek: The peeking margin in points; `48` by default, clamped to
    ///     `16...64`.
    ///   - snapPolicy: The snapping policy; Core's parameters by default
    ///     (a threshold of 600 pt/s, center alignment).
    public init(peek: CGFloat = 48, snapPolicy: TesseraSnapPolicy = TesseraSnapPolicy()) {
        self.storedPeek = TesseraPanoScrollView.sanitizedPeek(peek)
        self.snapPolicy = snapPolicy
        super.init(frame: .zero)
        commonInit()
    }

    /// Creates a scroll view with the given frame and default peek/snapping.
    ///
    /// - Parameter frame: The initial frame.
    public override init(frame: CGRect) {
        self.storedPeek = TesseraPanoScrollView.defaultPeek
        self.snapPolicy = TesseraSnapPolicy()
        super.init(frame: frame)
        commonInit()
    }

    /// Not supported: the scroll view is created only from code.
    @available(*, unavailable, message: "Use init(peek:snapPolicy:)")
    public required init?(coder: NSCoder) {
        fatalError("TesseraPanoScrollView does not support loading from Interface Builder")
    }

    /// Common scroll view setup.
    ///
    /// `isPagingEnabled` is off on purpose: paging handles only full-width
    /// pages, while the panorama shows a peek. `contentInsetAdjustmentBehavior =
    /// .never` is the initial value: the controller sets the scroll view's frame, and the child section
    /// controllers get the bottom safe area. The panorama controller
    /// overrides it from `TesseraPanoramaStyle.contentInsetAdjustmentBehavior`.
    private func commonInit() {
        isPagingEnabled = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = false
        // Horizontal bounce is enabled by sectionCount > 1: there is nowhere to page if
        // there is only one section.
        alwaysBounceHorizontal = false
        bounces = true
        // Direction lock: a diagonal gesture is not split between the
        // axes, and vertical stays with the child (vertical scrolling inside a section).
        isDirectionalLockEnabled = true
        backgroundColor = .clear
        delegate = self
    }

    // MARK: - Public API

    /// The raw scroll progress `t = contentOffset.x / itemWidth`.
    ///
    /// A value in physical content coordinates: `0` is the start of the strip, the integer
    /// part is the section's physical slot, and the fractional part is the transition progress. During bounce
    /// it may go beyond `0...(sectionCount − 1)`; the consumer decides how
    /// to clamp it. For progress in reading order (mirrored in RTL)
    /// use ``readingProgress(forRawOffset:)``; this is what the panorama exposes
    /// (see ``TesseraPanoramaDelegate``).
    ///
    /// The method is pure: it only reads `contentOffset` and `bounds`, writes nothing, and
    /// does not trigger layout.
    ///
    /// - Returns: The raw progress; `0` for zero width or a non-finite offset.
    public func currentProgress() -> CGFloat {
        let width = itemWidth
        guard width > 0, contentOffset.x.isFinite else { return 0 }
        return contentOffset.x / width
    }

    // MARK: - Geometry (module-internal; used by the controller and tests)

    /// The maximum valid `contentOffset.x` (the strip bounds).
    ///
    /// For `contentSize.width = sectionCount × itemWidth + peek` this is exactly
    /// `(sectionCount − 1) × itemWidth`, the same bound that
    /// ``TesseraSnapPolicy`` clamps to. There are no negative values.
    var maximumOffsetX: CGFloat {
        guard bounds.width > 0 else { return 0 }
        return max(contentSize.width - bounds.width, 0)
    }

    /// The content size for the current number of sections.
    ///
    /// - empty: `.zero` (nothing to page);
    /// - one section: the viewport size, the section takes the whole canvas;
    /// - otherwise: `sectionCount × itemWidth + peek`.
    var requiredContentSize: CGSize {
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0, storedSectionCount > 0 else { return .zero }
        guard storedSectionCount > 1 else { return CGSize(width: width, height: height) }
        return CGSize(
            width: CGFloat(storedSectionCount) * itemWidth + effectivePeek,
            height: height
        )
    }

    /// The physical slot of section `index` (in reading order).
    ///
    /// LTR: the slot equals the index; RTL: mirrored
    /// (`sectionCount − 1 − index`) so the first section in reading order is the rightmost
    /// (see the RTL notes in the design document).
    func physicalSlot(forReadingIndex index: Int) -> Int {
        guard storedSectionCount > 0 else { return 0 }
        let clamped = min(max(index, 0), storedSectionCount - 1)
        guard resolvedLayoutDirection == .rightToLeft else { return clamped }
        return storedSectionCount - 1 - clamped
    }

    /// The frame of section `index` in content coordinates.
    ///
    /// In RTL the sections are shifted right by `peek`: the mirrored copy of the LTR strip
    /// starts not at zero but with the margin strip, so that the peek of the next
    /// section ends up on the leading side of reading (the left).
    ///
    /// - Parameter index: The section index in reading order.
    /// - Returns: The section frame; `.zero` for an empty panorama or zero width.
    func rect(forReadingIndex index: Int) -> CGRect {
        guard storedSectionCount > 0, bounds.width > 0 else { return .zero }
        guard storedSectionCount > 1 else { return CGRect(origin: .zero, size: bounds.size) }

        let slot = physicalSlot(forReadingIndex: index)
        let leading = resolvedLayoutDirection == .rightToLeft ? effectivePeek : 0
        return CGRect(
            x: leading + CGFloat(slot) * itemWidth,
            y: 0,
            width: itemWidth,
            height: bounds.height
        )
    }

    /// The `contentOffset.x` at which section `index` is aligned to the leading edge.
    ///
    /// In RTL the alignment is mirrored: the section is pressed to the right edge of the viewport, and
    /// the peek strip of the next section is on the left. The formula
    /// `slot × itemWidth` is the same for both directions because the slot is already
    /// mirrored and the sections in RTL are shifted by `peek`.
    ///
    /// - Parameter index: The section index in reading order.
    /// - Returns: The alignment offset; `0` for a single section and an empty strip.
    func alignmentOffset(forReadingIndex index: Int) -> CGFloat {
        guard storedSectionCount > 1 else { return 0 }
        return CGFloat(physicalSlot(forReadingIndex: index)) * itemWidth
    }

    /// The progress in reading order for a raw offset.
    ///
    /// In LTR this is `offset / itemWidth`; in RTL ``TesseraRTL/normalizedProgress(_:pageCount:layoutDirection:)``
    /// mirrors it around the middle of the strip. During bounce the value may
    /// go outside the range; normalization does not clamp (Core behaves the same way).
    ///
    /// - Parameter rawOffsetX: The physical `contentOffset.x`.
    /// - Returns: The progress in reading order; `0` for a single section and garbage input.
    func readingProgress(forRawOffset rawOffsetX: CGFloat) -> CGFloat {
        readingProgress(forRawOffset: rawOffsetX, layoutDirection: resolvedLayoutDirection)
    }

    /// The progress in reading order for a raw offset in a **given** direction.
    ///
    /// Needed when LTR↔RTL changes on the fly: the offset still sits in the slots
    /// of the previous direction while ``resolvedLayoutDirection`` is already the new one,
    /// and normalizing by the new direction would reveal the mirrored section.
    ///
    /// - Parameters:
    ///   - rawOffsetX: The physical `contentOffset.x`.
    ///   - layoutDirection: The direction in which the slots are laid out.
    /// - Returns: The progress in reading order; `0` for a single section and garbage input.
    func readingProgress(
        forRawOffset rawOffsetX: CGFloat,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> CGFloat {
        guard storedSectionCount > 1 else { return 0 }
        let width = itemWidth
        guard width > 0, rawOffsetX.isFinite else { return 0 }
        return TesseraRTL.normalizedProgress(
            rawOffsetX / width,
            pageCount: storedSectionCount,
            layoutDirection: layoutDirection
        )
    }

    /// Takes the snap target of the last gesture; a repeated call returns `nil`.
    ///
    /// - Returns: The `contentOffset.x` of the target computed by the policy, or `nil`
    ///   if the gesture did not compute one (a single section, zero width).
    func consumePendingSnapOffsetX() -> CGFloat? {
        defer { pendingSnapOffsetX = nil }
        return pendingSnapOffsetX
    }

    /// The nearest aligned offset for settling after a gesture without inertia.
    ///
    /// The policy target from `scrollViewWillEndDragging` is preferred; without it,
    /// the section nearest to the current offset (the same policy with zero
    /// velocity). The result is clamped to `0...maximumOffsetX`.
    ///
    /// - Parameter preferred: The target computed by the policy for the gesture.
    /// - Returns: The aligned offset, or `nil` if there is no snapping (≤ 1 section).
    func alignedSnapOffsetX(preferred: CGFloat?) -> CGFloat? {
        let width = itemWidth
        guard storedSectionCount > 1, width > 0 else { return nil }

        let target: CGFloat
        if let preferred, preferred.isFinite {
            target = preferred
        } else {
            target = snapPolicy.targetContentOffset(
                proposedOffset: contentOffset.x,
                velocity: 0,
                itemWidth: width,
                pageCount: storedSectionCount
            )
        }
        return min(max(target, 0), maximumOffsetX)
    }

    /// The raw offset for a progress in reading order: the inverse of the
    /// ``readingProgress(forRawOffset:)`` conversion.
    ///
    /// In RTL ``TesseraRTL/normalizedProgress(_:pageCount:layoutDirection:)`` is
    /// an involution (`(n − 1) − ((n − 1) − t) == t`), so the same call converts
    /// reading progress back to physical coordinates. The result is clamped to
    /// `0...maximumOffsetX`: right at the strip boundary, the fraction within a section is not
    /// representable.
    ///
    /// - Parameter progress: The progress in reading order (`0...sectionCount − 1`).
    /// - Returns: The clamped `contentOffset.x`.
    func rawOffset(forReadingProgress progress: CGFloat) -> CGFloat {
        guard storedSectionCount > 1 else { return 0 }
        let width = itemWidth
        guard width > 0, progress.isFinite else { return 0 }

        let raw = TesseraRTL.normalizedProgress(
            progress,
            pageCount: storedSectionCount,
            layoutDirection: resolvedLayoutDirection
        )
        return min(max(raw * width, 0), maximumOffsetX)
    }

    /// The nearest section index in reading order for a raw offset.
    ///
    /// Rounding to the slot happens **before** mirroring, as in
    /// ``TesseraRTL/pageIndex(for:pageCount:layoutDirection:)``: what matters is the physical
    /// slot currently in frame, not the entry progress of the next section.
    ///
    /// - Parameter rawOffsetX: The physical `contentOffset.x`.
    /// - Returns: The index in reading order (`0` for an empty strip).
    func readingIndex(forRawOffset rawOffsetX: CGFloat) -> Int {
        guard storedSectionCount > 1 else { return 0 }
        let width = itemWidth
        guard width > 0, rawOffsetX.isFinite else { return 0 }

        let slot = min(
            max((rawOffsetX / width).rounded(), 0),
            CGFloat(storedSectionCount - 1)
        )
        return TesseraRTL.pageIndex(
            for: slot,
            pageCount: storedSectionCount,
            layoutDirection: resolvedLayoutDirection
        )
    }

    // MARK: - UIScrollViewDelegate

    /// The scrolling hot path.
    ///
    /// No layout and no `contentSize` changes: the event goes to the observer, which
    /// moves only `transform`/`alpha` and reports progress to the delegate.
    ///
    /// - Parameter scrollView: The source scroll view (always `self`).
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === self else { return }
        observer?.panoScrollViewDidScroll(self)
    }

    /// Gesture start: remember the start offset for snapping.
    ///
    /// - Parameter scrollView: The source scroll view.
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === self else { return }
        dragStartOffsetX = contentOffset.x
        pendingSnapOffsetX = nil
    }

    /// The panorama's custom snapping.
    ///
    /// The target computation is fully delegated to ``TesseraSnapPolicy``: the scroll view
    /// supplies the actual section width (`itemWidth`) and the gesture velocity.
    /// `isPagingEnabled` is off, so this is the only settling mechanism.
    ///
    /// For a single section there is no snapping: there is nowhere to page, and the offset stays zero.
    /// Prefetch hook: the observer receives the already computed target index, so the neighbor
    /// has time to load before deceleration begins.
    ///
    /// - Parameters:
    ///   - scrollView: The source scroll view.
    ///   - velocity: The gesture velocity; only the horizontal component is used.
    ///   - targetContentOffset: The target proposed by the system; overwritten
    ///     with the snap result.
    public func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard scrollView === self else { return }

        // UIKit reports velocity in points/ms; the policy and the observer use pt/s.
        let velocityX = velocity.x * 1000
        let startOffsetX = dragStartOffsetX
        dragStartOffsetX = nil

        let count = storedSectionCount
        let width = itemWidth

        pendingSnapOffsetX = nil
        guard count > 1, width > 0 else {
            // A single section: no snapping needed, leave the target alone.
            if count == 1 {
                targetContentOffset.pointee.x = 0
            }
            observer?.panoScrollViewWillEndDragging(
                self,
                velocityX: velocityX,
                targetReadingIndex: 0
            )
            return
        }

        targetContentOffset.pointee.x = snapPolicy.targetContentOffset(
            proposedOffset: targetContentOffset.pointee.x,
            velocity: velocityX,
            itemWidth: width,
            pageCount: count,
            startOffset: startOffsetX
        )
        pendingSnapOffsetX = targetContentOffset.pointee.x

        // Prefetch: the target is already known and the snap has not started yet.
        observer?.panoScrollViewWillEndDragging(
            self,
            velocityX: velocityX,
            targetReadingIndex: readingIndex(forRawOffset: targetContentOffset.pointee.x)
        )
    }

    /// The gesture finished: tell the controller whether inertia will follow.
    ///
    /// - Parameters:
    ///   - scrollView: The source scroll view.
    ///   - decelerate: Whether inertia will begin.
    public func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        guard scrollView === self else { return }
        observer?.panoScrollViewDidEndDragging(self, willDecelerate: decelerate)
    }

    /// Inertia ended: the snap settled on a section.
    ///
    /// - Parameter scrollView: The source scroll view.
    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === self else { return }
        observer?.panoScrollViewDidEndDecelerating(self)
    }

    /// The programmatic offset animation finished.
    ///
    /// - Parameter scrollView: The source scroll view.
    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView === self else { return }
        observer?.panoScrollViewDidEndScrollingAnimation(self)
    }

    // MARK: - Accessibility

    /// Section paging with the VoiceOver three-finger gesture.
    ///
    /// `UIScrollView`'s own implementation would page by a "screen", ignoring
    /// section boundaries and snapping; here the direction is converted into a step through the sections
    /// via ``TesseraAccessibility/pageStep(for:layoutDirection:)`` (taking
    /// RTL into account), and the controller makes the decision and performs the transition, so
    /// `contentOffset` is still written by it alone (the single-writer contract).
    ///
    /// - Parameter direction: The VoiceOver gesture direction.
    /// - Returns: `true` if the gesture was handled.
    public override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        // A single section or an empty strip: there is no paging, hand the gesture to the system.
        guard storedSectionCount > 1 else { return super.accessibilityScroll(direction) }

        let step = TesseraAccessibility.pageStep(
            for: direction,
            layoutDirection: resolvedLayoutDirection
        )
        // Vertical gestures and a missing observer are not ours to address.
        guard step != 0, let observer else { return super.accessibilityScroll(direction) }
        return observer.panoScrollView(self, accessibilityStep: step)
    }

    // MARK: - Input sanitization

    /// Clamps `peek` to the range `16...64`; `NaN`/infinities become the default.
    private static func sanitizedPeek(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultPeek }
        return min(max(value, peekRange.lowerBound), peekRange.upperBound)
    }
}
#endif
