//
//  TesseraParallaxLayer.swift
//  TesseraCore/Parallax
//
//  A background layer with parallax.
//  Contract: the key contracts in docs/CORE-IOS-DESIGN.md (parallax:
//  backgroundOffset = offset × factor, factor ∈ (0, 1); the layer is always larger than contentSize;
//  Reduce Motion → factor 0; the on-screen projection for a layer next to a scroll view is
//  `transform = −backgroundOffset`), the conceptual API surface
//  (`TesseraParallaxLayer` = background + factor + axis), and the package structure (the `Parallax` directory).
//  Background details in Panorama: docs/PANORAMA-IOS-DESIGN.md (background parallax).
//
//
//  Performance discipline (docs/CORE-IOS-DESIGN.md): `update(withContentOffset:)`
//  changes only `transform`. No layout pass, `setNeedsLayout`, `frame` changes, or view creation
//  on the scroll hot path. `bounds` changes only in configuration
//  (`configure` / `setContentSize` / `init`).
//

import UIKit

/// A background layer that moves more slowly than the content when scrolling.
///
/// The background offset is computed by the pure function ``effectiveOffset(contentOffset:factor:)``:
/// `backgroundOffset = contentOffset × factor`, `factor ∈ (0, 1)`. This is an offset in content
/// coordinates with the same sign as `contentOffset`. The layer supports both axes: the consumer
/// passes a full `CGPoint` to ``update(withContentOffset:)`` and zeroes the unused axis itself
/// (for example, `y = 0` for a horizontal panorama).
///
/// ## On-screen projection: the layer is a sibling of the scroll view
///
/// The layer is meant to be placed **next to** the scroll view (in a shared superview, below it), not
/// inside it. The background offset is therefore projected onto the screen with a minus sign:
/// `transform = −backgroundOffset`. When `contentOffset` grows by Δ, the content moves by −Δ on screen
/// and the background by −Δ × factor: in the same direction as the content, but more slowly.
///
/// - Important: Earlier versions set `transform = +backgroundOffset`, so the background of a scroll view's sibling moved
///   opposite to the content. Signatures did not change; only the on-screen
///   projection did. The consumer places the layer so that the size margin is on the side the layer
///   moves toward: the layer's origin is at the top/left edge of the viewport (minus a margin for the rubber band
///   on a negative offset), and the main margin is at the bottom/right.
///
/// The layer's size is `contentSize + extraSize` on each axis: the `extraSize` margin is needed so that
/// shifting by `factor × offset` does not reveal empty strips at the edges.
///
/// ## Reduce Motion
///
/// When Reduce Motion is on (and `respectsReduceMotion == true`, the default), the effective
/// factor is 0: the background stays in place while the content keeps scrolling. The setting provider
/// is injected in the initializer, so the behavior is testable without system settings.
///
/// ## Usage
///
/// ```swift
/// let layer = TesseraParallaxLayer()
/// layer.configure(factor: 0.5, extraSize: 64)
/// layer.setContentSize(scrollView.contentSize)
/// // in scrollViewDidScroll:
/// layer.update(withContentOffset: scrollView.contentOffset)
/// ```
///
/// All methods run on the main thread: a UIKit view is not designed for calls from background threads
/// (all UI work happens on the main thread).
public final class TesseraParallaxLayer: UIView {

    // MARK: - Public state

    /// Whether to honor the system Reduce Motion setting.
    ///
    /// `true` (the default): when Reduce Motion is on, the effective factor is 0.
    /// `false`: the factor is always applied (needed only for debugging scenarios).
    public var respectsReduceMotion: Bool = true {
        didSet {
            guard respectsReduceMotion != oldValue else { return }
            applyTransform()
        }
    }

    /// The current parallax multiplier. Always in `[0, 1]`: out-of-range values are clamped
    /// in ``configure(factor:extraSize:)``. The default is `0.5`.
    public private(set) var factor: CGFloat = TesseraParallaxLayer.defaultFactor

    /// The layer's size margin beyond `contentSize`, in points. Always `>= 0`: a negative or
    /// non-finite margin is clamped in ``configure(factor:extraSize:)``.
    ///
    /// The margin is added to **each** axis in full:
    /// `width = contentSize.width + extraSize`, `height = contentSize.height + extraSize`.
    public private(set) var extraSize: CGFloat = 0

    /// The content size the layer is sized for. Set through ``setContentSize(_:)``.
    public private(set) var contentSize: CGSize = .zero

    // MARK: - Private state

    /// The default multiplier (a typical range is 0.4–0.6).
    private static let defaultFactor: CGFloat = 0.5

    /// The Reduce Motion setting provider. Injected for testability.
    private let reduceMotionProvider: () -> Bool

    /// The last applied offset: needed to recompute `transform` when
    /// `factor`, `extraSize`, or `respectsReduceMotion` changes without a new ``update(withContentOffset:)`` call.
    private var lastContentOffset: CGPoint = .zero

    // MARK: - Initialization

    /// Creates a layer with an injectable Reduce Motion provider.
    ///
    /// - Parameter reduceMotionProvider: Returns `true` if Reduce Motion is on.
    ///   By default it reads the system setting `UIAccessibility.isReduceMotionEnabled`.
    ///   The provider is queried on every transform rebuild, so toggling the
    ///   setting is picked up on the next scroll frame.
    public init(reduceMotionProvider: @escaping () -> Bool = { UIAccessibility.isReduceMotionEnabled }) {
        self.reduceMotionProvider = reduceMotionProvider
        super.init(frame: .zero)
        commonInit()
    }

    /// Creates a layer whose `contentSize` equals the size of the given `frame`.
    ///
    /// - Parameter frame: The initial frame; its size becomes ``contentSize``.
    public override init(frame: CGRect) {
        self.reduceMotionProvider = { UIAccessibility.isReduceMotionEnabled }
        super.init(frame: frame)
        commonInit()
        contentSize = Self.sanitizedSize(frame.size)
    }

    /// Initialization from Interface Builder / Storyboard.
    ///
    /// Uses the system Reduce Motion provider. `contentSize` stays zero:
    /// a layer created from markup must receive a size through ``setContentSize(_:)`` before the first
    /// ``update(withContentOffset:)``.
    public required init?(coder: NSCoder) {
        self.reduceMotionProvider = { UIAccessibility.isReduceMotionEnabled }
        super.init(coder: coder)
        commonInit()
    }

    // MARK: - Public API

    /// Sets the parallax multiplier and the size margin.
    ///
    /// The method is idempotent: a repeated call with the same values touches neither the size nor
    /// `transform`. It does not trigger a layout pass, only the layer's `bounds` and `transform`.
    ///
    /// - Parameters:
    ///   - factor: A multiplier `0 < factor < 1`. Out-of-range values are clamped to the nearest
    ///     bound: `0` turns parallax off (as with Reduce Motion), `1` makes the layer move with
    ///     the content. `NaN` and infinity are treated as `0` (a safe "do not move").
    ///   - extraSize: The margin beyond `contentSize` on each axis, in points. Negative and
    ///     non-finite values are treated as `0`.
    public func configure(factor: CGFloat, extraSize: CGFloat) {
        self.factor = Self.sanitizedFactor(factor)
        self.extraSize = Self.sanitizedExtraSize(extraSize)
        applyLayerSize()
        applyTransform()
    }

    /// Sets the content size the layer is computed for.
    ///
    /// The layer's own size becomes `contentSize + extraSize` on each axis
    /// (see ``extraSize``). Negative and non-finite components are treated as `0`.
    ///
    /// - Parameter size: The content size in points.
    public func setContentSize(_ size: CGSize) {
        contentSize = Self.sanitizedSize(size)
        applyLayerSize()
    }

    /// Applies the content offset to the background.
    ///
    /// Called from `scrollViewDidScroll` (or from a controller that forwards the offset).
    /// Changes **only** `transform`; size, hierarchy, and layout are untouched.
    /// The transform is the on-screen projection of the background offset for a layer next to a scroll view:
    /// `transform = −effectiveOffset(offset, factor)`, so the background moves in the same direction as the
    /// content, but `factor` times slower. When Reduce Motion is on, the effective factor
    /// is 0 and the layer stays in place.
    ///
    /// - Parameter offset: The current `contentOffset` of the content. Non-finite values are ignored
    ///   (the layer's state does not change) so that `NaN` does not poison `transform`.
    public func update(withContentOffset offset: CGPoint) {
        guard offset.x.isFinite, offset.y.isFinite else { return }
        guard offset != lastContentOffset else { return }
        lastContentOffset = offset
        applyTransform()
    }

    /// The pure background offset function: `contentOffset × factor`.
    ///
    /// The result is the background offset **in content coordinates**: its sign matches the sign of
    /// `contentOffset` (like `contentOffset`, it is "how far the visible window has advanced over the background").
    /// The on-screen projection for a layer next to a scroll view has a minus sign:
    /// `transform = −effectiveOffset` (this is what ``TesseraParallaxLayer`` itself does). A consumer
    /// that moves the background without the layer (for example, through the `CALayer.transform` of a neighboring
    /// layer) applies the same projection. Also used by the contract tests.
    /// There is no clamping of `factor` here; validation happens in ``configure(factor:extraSize:)``.
    ///
    /// - Parameters:
    ///   - contentOffset: The content offset.
    ///   - factor: The parallax multiplier.
    /// - Returns: The background offset on both axes.
    public static func effectiveOffset(contentOffset: CGPoint, factor: CGFloat) -> CGPoint {
        CGPoint(x: contentOffset.x * factor, y: contentOffset.y * factor)
    }

    // MARK: - Applying state

    /// Common view setup: the background does not intercept touches and is not an element of the
    /// accessibility tree by itself (a decorative layer).
    ///
    /// This is also where it subscribes to Reduce Motion changes: if the user turns the setting on
    /// while scrolling is idle, the layer must return to the zero position without waiting for the next
    /// `scrollViewDidScroll` (parallax is disabled under Reduce Motion).
    /// The subscription does not retain the layer: a selector-based `NotificationCenter` observer is weak,
    /// and since iOS 9 it is removed automatically.
    private func commonInit() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reduceMotionStatusDidChange),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
    }

    /// The system notification about a Reduce Motion change: rebuilds `transform` with the current offset.
    @objc private func reduceMotionStatusDidChange() {
        applyTransform()
    }

    /// Recomputes the layer's own size.
    ///
    /// The size is set through `bounds`, not `frame`: with a non-identity `transform` the
    /// `frame` value is undefined, and `bounds.size` is the only reliable source of size.
    /// `center` does not change, so the layer grows around its current center.
    private func applyLayerSize() {
        let target = CGSize(
            width: contentSize.width + extraSize,
            height: contentSize.height + extraSize
        )
        guard target != bounds.size else { return }
        bounds = CGRect(origin: .zero, size: target)
    }

    /// Rebuilds `transform` from the last offset and the effective factor.
    ///
    /// The on-screen projection for a layer next to a scroll view: `transform = −backgroundOffset`, so the background
    /// moves in the same direction as the content. With a zero effective factor the shift
    /// `−0` yields the same identity transform. It makes no redundant writes: comparing transforms
    /// is cheap and avoids needless compositor redraws.
    private func applyTransform() {
        let backgroundOffset = Self.effectiveOffset(
            contentOffset: lastContentOffset,
            factor: resolvedFactor
        )
        // `0 - x`, not `-x`: with a zero shift we do not get `-0.0` in the transform.
        let target = CGAffineTransform(
            translationX: 0 - backgroundOffset.x,
            y: 0 - backgroundOffset.y
        )
        guard transform != target else { return }
        transform = target
    }

    /// The effective multiplier with Reduce Motion taken into account (Reduce Motion → factor 0).
    ///
    /// The provider is queried on every recomputation rather than cached: reading the setting is
    /// a cheap call to a system cache. In addition, a live change of the setting
    /// is caught by the `UIAccessibility.reduceMotionStatusDidChangeNotification` notification
    /// (see ``commonInit()``), so no frozen offset remains while idle.
    private var resolvedFactor: CGFloat {
        if respectsReduceMotion, reduceMotionProvider() { return 0 }
        return factor
    }

    // MARK: - Input sanitization

    /// Clamps `factor` to `[0, 1]`; `NaN`/infinity → `0`.
    private static func sanitizedFactor(_ raw: CGFloat) -> CGFloat {
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), 1)
    }

    /// Clamps a negative or non-finite size margin to `0`.
    private static func sanitizedExtraSize(_ raw: CGFloat) -> CGFloat {
        guard raw.isFinite, raw > 0 else { return 0 }
        return raw
    }

    /// Clamps negative and non-finite size components to `0`.
    private static func sanitizedSize(_ raw: CGSize) -> CGSize {
        CGSize(
            width: raw.width.isFinite && raw.width > 0 ? raw.width : 0,
            height: raw.height.isFinite && raw.height > 0 ? raw.height : 0
        )
    }
}
