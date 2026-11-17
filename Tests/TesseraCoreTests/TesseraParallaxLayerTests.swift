//
//  TesseraParallaxLayerTests.swift
//  TesseraCoreTests
//
//  Contract tests for parallax.
//  Design document: docs/CORE-IOS-DESIGN.md §2 (key contracts:
//  "Parallax: backgroundOffset = offset × factor, factor ∈ (0, 1);
//  the layer is deliberately larger than contentSize; Reduce Motion → factor 0"), §3
//  (conceptual API surface: TesseraParallaxLayer is background + factor + axis)
//  and §2 (Reduce Motion).
//
//  Checked: the pure function `effectiveOffset(contentOffset:factor:)`
//  (the background shift in content coordinates, with the same sign as the offset), rebuilding
//  `transform` on `update(withContentOffset:)` (an on-screen projection with a
//  minus sign for a layer next to the scroll view), the direction contract "the background moves
//  the same way as the content, but slower", and the parallax cutoff via an
//  injectable Reduce Motion provider.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraCore

final class TesseraParallaxLayerTests: XCTestCase {

    // MARK: - Helper checks

    /// Checks that the layer's transform is a pure translation with no scale or rotation.
    private func assertTranslation(
        _ transform: CGAffineTransform,
        x: CGFloat,
        y: CGFloat,
        accuracy: CGFloat = 0.0001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(transform.a, 1, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(transform.b, 0, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(transform.c, 0, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(transform.d, 1, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(transform.tx, x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(transform.ty, y, accuracy: accuracy, file: file, line: line)
    }

    /// A layer with an offset already applied and a pass-through Reduce Motion provider.
    private func makeLayer(
        factor: CGFloat,
        offset: CGPoint,
        reduceMotion: Bool = false,
        respectsReduceMotion: Bool = true
    ) -> TesseraParallaxLayer {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { reduceMotion })
        layer.respectsReduceMotion = respectsReduceMotion
        layer.configure(factor: factor, extraSize: 0)
        layer.update(withContentOffset: offset)
        return layer
    }

    // MARK: - effectiveOffset: the pure contract

    /// With factor 0 the background stays in place regardless of the offset.
    func testEffectiveOffsetAtFactorZero() {
        let offset = CGPoint(x: 120, y: -80)
        let result = TesseraParallaxLayer.effectiveOffset(contentOffset: offset, factor: 0)

        XCTAssertEqual(result.x, 0)
        XCTAssertEqual(result.y, 0)
    }

    /// With factor 0.5 the background shifts exactly half as fast as the content on both axes.
    func testEffectiveOffsetAtHalfFactor() {
        let result = TesseraParallaxLayer.effectiveOffset(
            contentOffset: CGPoint(x: 120, y: -80),
            factor: 0.5
        )

        XCTAssertEqual(result.x, 60)
        XCTAssertEqual(result.y, -40)
    }

    /// With factor 1 the background moves together with the content (the edge case of the allowed
    /// range, although the design range is `(0, 1)`).
    func testEffectiveOffsetAtFullFactor() {
        let offset = CGPoint(x: 120, y: -80)
        let result = TesseraParallaxLayer.effectiveOffset(contentOffset: offset, factor: 1)

        XCTAssertEqual(result.x, offset.x)
        XCTAssertEqual(result.y, offset.y)
    }

    /// The offset's sign is preserved on both axes: `effectiveOffset` is the background shift
    /// in content coordinates. The on-screen projection (`transform`) has a minus sign;
    /// it is checked by the `update(withContentOffset:)` tests and the direction contract.
    func testEffectiveOffsetPreservesSignOnBothAxes() {
        let result = TesseraParallaxLayer.effectiveOffset(
            contentOffset: CGPoint(x: -120, y: 80),
            factor: 0.25
        )

        XCTAssertEqual(result.x, -30)
        XCTAssertEqual(result.y, 20)
    }

    // MARK: - Layer configuration

    /// `factor` is a multiplier with a default of 0.5, `extraSize` is zero.
    func testDefaultFactorAndExtraSize() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })

        XCTAssertEqual(layer.factor, 0.5)
        XCTAssertEqual(layer.extraSize, 0)
        XCTAssertEqual(layer.contentSize, .zero)
    }

    /// `configure` clamps the factor to `[0, 1]`; `NaN` and infinity are treated
    /// as 0 (a safe "do not move").
    func testConfigureClampsFactorToUnitRange() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })

        layer.configure(factor: 1.5, extraSize: 0)
        XCTAssertEqual(layer.factor, 1)

        layer.configure(factor: -0.5, extraSize: 0)
        XCTAssertEqual(layer.factor, 0)

        layer.configure(factor: .nan, extraSize: 0)
        XCTAssertEqual(layer.factor, 0)

        layer.configure(factor: .infinity, extraSize: 0)
        XCTAssertEqual(layer.factor, 0)

        layer.configure(factor: 0.25, extraSize: 0)
        XCTAssertEqual(layer.factor, 0.25)
    }

    /// A negative or non-numeric size margin is treated as 0, and a valid one is
    /// added to each axis.
    func testConfigureSanitizesExtraSize() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })

        layer.configure(factor: 0.5, extraSize: -64)
        XCTAssertEqual(layer.extraSize, 0)

        layer.configure(factor: 0.5, extraSize: .nan)
        XCTAssertEqual(layer.extraSize, 0)

        layer.configure(factor: 0.5, extraSize: .infinity)
        XCTAssertEqual(layer.extraSize, 0)

        layer.configure(factor: 0.5, extraSize: 10)
        XCTAssertEqual(layer.extraSize, 10)
    }

    /// The layer's size equals `contentSize + extraSize` on each axis (Core §2:
    /// the layer is deliberately larger than the content).
    func testSetContentSizeAddsExtraSizeOnBothAxes() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })
        layer.configure(factor: 0.5, extraSize: 64)
        layer.setContentSize(CGSize(width: 300, height: 200))

        XCTAssertEqual(layer.contentSize, CGSize(width: 300, height: 200))
        XCTAssertEqual(layer.bounds.size, CGSize(width: 364, height: 264))
    }

    /// Negative and non-numeric `contentSize` components are treated as 0.
    func testSetContentSizeSanitizesDegenerateComponents() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })
        layer.configure(factor: 0.5, extraSize: 0)
        layer.setContentSize(CGSize(width: -100, height: CGFloat.nan))

        XCTAssertEqual(layer.contentSize, .zero)
        XCTAssertEqual(layer.bounds.size, .zero)
    }

    /// The initializer taking a `frame` uses its size as `contentSize`.
    func testFrameInitializerTakesContentSizeFromFrame() {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let layer = TesseraParallaxLayer(frame: frame)

        XCTAssertEqual(layer.contentSize, CGSize(width: 320, height: 480))
        XCTAssertEqual(layer.bounds.size, CGSize(width: 320, height: 480))
    }

    /// A repeated `configure` with the same values is idempotent: the size and
    /// the transform do not change.
    func testConfigureIsIdempotentForSameValues() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })
        layer.configure(factor: 0.5, extraSize: 64)
        layer.setContentSize(CGSize(width: 300, height: 200))
        layer.update(withContentOffset: CGPoint(x: 40, y: 20))

        let bounds = layer.bounds
        let transform = layer.transform

        layer.configure(factor: 0.5, extraSize: 64)

        XCTAssertEqual(layer.bounds, bounds)
        XCTAssertEqual(layer.transform, transform)
    }

    // MARK: - update(withContentOffset:) and transform

    /// `update(withContentOffset:)` changes only `transform`: the shift equals
    /// `−offset × factor` (an on-screen projection for a layer next to the scroll view),
    /// with no scale or rotation.
    ///
    /// Previously the test canonized `+offset × factor`, and exactly that sign moved
    /// the background opposite to the content.
    func testUpdateTranslatesLayerByEffectiveOffset() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })
        layer.configure(factor: 0.5, extraSize: 0)

        layer.update(withContentOffset: CGPoint(x: 120, y: -40))

        assertTranslation(layer.transform, x: -60, y: 20)
    }

    /// A zero offset leaves the layer at rest (an identity transform).
    func testUpdateWithZeroOffsetKeepsIdentity() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })
        layer.configure(factor: 0.5, extraSize: 0)

        layer.update(withContentOffset: .zero)

        XCTAssertEqual(layer.transform, .identity)
    }

    /// Non-numeric offset coordinates are ignored: `NaN` does not "poison"
    /// `transform`, and the last valid state is kept.
    func testUpdateIgnoresNonFiniteCoordinates() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })
        layer.configure(factor: 0.5, extraSize: 0)
        layer.update(withContentOffset: CGPoint(x: 100, y: 100))

        layer.update(withContentOffset: CGPoint(x: CGFloat.nan, y: 999))

        assertTranslation(layer.transform, x: -50, y: -50)
    }

    /// Changing `factor` recomputes the transform from the last offset without a new
    /// call to `update(withContentOffset:)`.
    func testConfigureRecomputesTransformFromLastOffset() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })
        layer.configure(factor: 0.5, extraSize: 0)
        layer.update(withContentOffset: CGPoint(x: 120, y: -40))
        assertTranslation(layer.transform, x: -60, y: 20)

        layer.configure(factor: 1, extraSize: 0)
        assertTranslation(layer.transform, x: -120, y: 40)

        layer.configure(factor: 0, extraSize: 0)
        XCTAssertEqual(layer.transform, .identity)
    }

    // MARK: - Reduce Motion

    /// Reduce Motion → the effective factor is 0 even if 1 is configured:
    /// the background stays in place while the content keeps scrolling (Core §2, Reduce Motion).
    func testReduceMotionProviderForcesZeroFactor() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { true })
        layer.configure(factor: 1, extraSize: 0)

        layer.update(withContentOffset: CGPoint(x: 200, y: 100))

        XCTAssertEqual(layer.transform, .identity)
        // The public configuration is not overridden: only the effective factor is disabled.
        XCTAssertEqual(layer.factor, 1)
    }

    /// `respectsReduceMotion == false` disables the cutoff (a debugging scenario):
    /// the factor applies even with Reduce Motion on.
    func testRespectsReduceMotionFalseAppliesFactor() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { true })
        layer.respectsReduceMotion = false
        layer.configure(factor: 1, extraSize: 0)

        layer.update(withContentOffset: CGPoint(x: 200, y: 100))

        assertTranslation(layer.transform, x: -200, y: -100)
    }

    /// The provider is queried on every recomputation: toggling Reduce Motion
    /// is picked up by the next `update` without recreating the layer.
    func testProviderToggleIsAppliedOnNextUpdate() {
        var reduceMotion = true
        let layer = TesseraParallaxLayer(reduceMotionProvider: { reduceMotion })
        layer.configure(factor: 0.5, extraSize: 0)

        layer.update(withContentOffset: CGPoint(x: 100, y: 100))
        XCTAssertEqual(layer.transform, .identity)

        reduceMotion = false
        layer.update(withContentOffset: CGPoint(x: 200, y: 200))
        assertTranslation(layer.transform, x: -100, y: -100)
    }

    /// The system notification about a Reduce Motion change resets the shift without waiting for
    /// the next `scrollViewDidScroll` (Core §2, Reduce Motion).
    func testReduceMotionNotificationResetsTransform() {
        var reduceMotion = false
        let layer = TesseraParallaxLayer(reduceMotionProvider: { reduceMotion })
        layer.configure(factor: 0.5, extraSize: 0)
        layer.update(withContentOffset: CGPoint(x: 100, y: 100))
        assertTranslation(layer.transform, x: -50, y: -50)

        reduceMotion = true
        NotificationCenter.default.post(
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )

        XCTAssertEqual(layer.transform, .identity)
    }

    // MARK: - Direction: the layer is a sibling of the scroll view

    /// The direction-contract scene: a "screen" container holding a background layer and,
    /// **next to** it (not inside), a scroll view with content, exactly how
    /// Panorama and StartScreen place the layer.
    private struct SiblingScene {
        let container: UIView
        let layer: TesseraParallaxLayer
        let scrollView: UIScrollView
        let content: UIView

        /// The on-screen position (in container coordinates) of a view's origin, accounting for
        /// `transform` and `contentOffset`.
        func screenOrigin(of view: UIView) -> CGPoint {
            view.convert(CGPoint.zero, to: container)
        }

        /// Writes the offset to the scroll view and forwards it to the layer, as
        /// a consumer does in `scrollViewDidScroll`.
        func scroll(to offset: CGPoint) {
            scrollView.contentOffset = offset
            layer.update(withContentOffset: scrollView.contentOffset)
        }
    }

    private func makeSiblingScene(factor: CGFloat, reduceMotion: Bool) -> SiblingScene {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))

        let layer = TesseraParallaxLayer(reduceMotionProvider: { reduceMotion })
        layer.configure(factor: factor, extraSize: 0)
        layer.setContentSize(container.bounds.size)
        layer.center = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
        container.addSubview(layer)

        let scrollView = UIScrollView(frame: container.bounds)
        let content = UIView(frame: CGRect(x: 0, y: 0, width: 2000, height: 2000))
        scrollView.addSubview(content)
        scrollView.contentSize = content.bounds.size
        container.addSubview(scrollView)

        return SiblingScene(container: container, layer: layer, scrollView: scrollView, content: content)
    }

    /// The direction contract: the layer sits next to the scroll view; the offset
    /// grows by Δ on both axes → the content moves on screen by −Δ, the background by
    /// −Δ × factor: **the same way** as the content, but slower.
    ///
    /// Previously the layer set `transform = +offset × factor`, and the background moved in
    /// the direction opposite to the content; this test catches a sign regression.
    func testSiblingLayerMovesWithContentButSlowerOnBothAxes() {
        let factor: CGFloat = 0.5
        let scene = makeSiblingScene(factor: factor, reduceMotion: false)
        scene.scroll(to: CGPoint(x: 100, y: 60))

        let contentBefore = scene.screenOrigin(of: scene.content)
        let backgroundBefore = scene.screenOrigin(of: scene.layer)

        let delta = CGPoint(x: 80, y: 40)
        scene.scroll(to: CGPoint(x: 100 + delta.x, y: 60 + delta.y))

        let contentAfter = scene.screenOrigin(of: scene.content)
        let backgroundAfter = scene.screenOrigin(of: scene.layer)

        // Content: offset +Δ → on-screen position −Δ.
        XCTAssertEqual(contentAfter.x - contentBefore.x, -delta.x, accuracy: 0.0001)
        XCTAssertEqual(contentAfter.y - contentBefore.y, -delta.y, accuracy: 0.0001)

        // Background: −Δ × factor, the same sign as the content, with a magnitude factor times smaller.
        XCTAssertEqual(backgroundAfter.x - backgroundBefore.x, -delta.x * factor, accuracy: 0.0001)
        XCTAssertEqual(backgroundAfter.y - backgroundBefore.y, -delta.y * factor, accuracy: 0.0001)
    }

    /// The direction contract under Reduce Motion: the content keeps moving away while
    /// the background's on-screen position does not change (Core §2, Reduce Motion).
    func testSiblingLayerStaysInPlaceUnderReduceMotion() {
        let scene = makeSiblingScene(factor: 0.5, reduceMotion: true)
        scene.scroll(to: CGPoint(x: 100, y: 60))

        let contentBefore = scene.screenOrigin(of: scene.content)
        let backgroundBefore = scene.screenOrigin(of: scene.layer)

        scene.scroll(to: CGPoint(x: 180, y: 100))

        let contentAfter = scene.screenOrigin(of: scene.content)
        let backgroundAfter = scene.screenOrigin(of: scene.layer)

        XCTAssertEqual(contentAfter.x - contentBefore.x, -80, accuracy: 0.0001)
        XCTAssertEqual(contentAfter.y - contentBefore.y, -40, accuracy: 0.0001)
        XCTAssertEqual(backgroundAfter.x - backgroundBefore.x, 0, accuracy: 0.0001)
        XCTAssertEqual(backgroundAfter.y - backgroundBefore.y, 0, accuracy: 0.0001)
        XCTAssertEqual(scene.layer.transform, .identity)
    }

    // MARK: - The layer is decorative

    /// The layer is decorative: it does not intercept touches and is not a separate
    /// element of the accessibility tree.
    func testLayerIsDecorative() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })

        XCTAssertFalse(layer.isUserInteractionEnabled)
        XCTAssertFalse(layer.isAccessibilityElement)
    }
}

#endif
