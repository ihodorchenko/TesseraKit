//
//  TileMergeHoverTests.swift
//  TesseraStartScreenTests
//
//  Tests for merging into a folder by hold.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §5 "Edit mode"
//  (merge hold): a folder of two tiles is not created instantly on
//  a drop on the center of the target tile, but after a hold of **strictly more than** 600 ms with
//  a finger displacement **strictly less than** 10 pt.
//
//  The pure state machine `TesseraMergeHoverTracker` is tested (no UI):
//  strict tolerance and time boundaries, moving the anchor and rearming at the last
//  point on a displacement at the tolerance, resets, drop readiness. The clock and timer are injected,
//  so the tests neither sleep nor flake.
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileMergeHoverTests: XCTestCase {

    // MARK: - Helpers

    /// A controllable clock for the state machine: the test advances time, not the run loop.
    private final class TestClock {

        /// The current "monotonic" time in seconds.
        var time: TimeInterval = 0

        /// Advances the clock.
        ///
        /// - Parameter interval: Increment in seconds.
        func advance(_ interval: TimeInterval) {
            time += interval
        }
    }

    /// A tracker on a controllable clock with parameters from the configuration.
    ///
    /// - Parameters:
    ///   - clock: The test clock.
    ///   - configuration: Edit configuration (by default the production
    ///     values: 600 ms and 10 pt).
    /// - Returns: A hold machine that reads time from `clock`.
    private func makeTracker(
        _ clock: TestClock,
        configuration: TesseraTileEditConfiguration = TesseraTileEditConfiguration()
    ) -> TesseraMergeHoverTracker {
        TesseraMergeHoverTracker(
            hoverDuration: configuration.mergeHoverDuration,
            displacementThreshold: configuration.mergeHoverDisplacement,
            now: { clock.time }
        )
    }

    /// Arms the hold over tile "a" at the given point.
    ///
    /// - Parameters:
    ///   - tracker: The hold machine.
    ///   - point: The finger point (the tolerance anchor).
    private func arm(_ tracker: inout TesseraMergeHoverTracker, at point: CGPoint = .zero) {
        tracker.beginHover(targetID: "a", point: point)
    }

    // MARK: - Configuration

    /// Default values: a 600 ms hold, a 10 pt tolerance and an "absorb"
    /// highlight of ~0.2 s in the 1.06–1.1 range.
    func testConfigurationDefaultsMatchSpec() {
        let configuration = TesseraTileEditConfiguration()

        XCTAssertEqual(configuration.mergeHoverDuration, 0.6, accuracy: 0.0001)
        XCTAssertEqual(configuration.mergeHoverDisplacement, 10, accuracy: 0.0001)
        XCTAssertEqual(configuration.mergeHighlightDuration, 0.2, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(configuration.mergeHighlightScale, 1.06)
        XCTAssertLessThanOrEqual(configuration.mergeHighlightScale, 1.1)
    }

    /// Thresholds from the configuration reach the hold machine without distortion.
    func testConfigurationThresholdsAreRespected() {
        let clock = TestClock()
        var configuration = TesseraTileEditConfiguration()
        configuration.mergeHoverDuration = 0.1
        configuration.mergeHoverDisplacement = 4
        var tracker = makeTracker(clock, configuration: configuration)

        arm(&tracker)

        // 3 pt is within the tolerance (`<4 pt` in this test): the hold continues.
        tracker.update(point: CGPoint(x: 3, y: 0))
        XCTAssertEqual(tracker.state, .armed)

        // 4 pt is exactly the tolerance: a strict boundary, the hold is cancelled and
        // rearmed with the anchor at the new point.
        XCTAssertTrue(tracker.update(point: CGPoint(x: 4, y: 0)))
        XCTAssertEqual(tracker.anchor, CGPoint(x: 4, y: 0))

        // Return to the initial state and a check of the shortened timer.
        tracker.reset()
        arm(&tracker)
        clock.advance(0.05)
        XCTAssertFalse(tracker.timerFired())
        XCTAssertEqual(tracker.state, .armed)
        // Exactly the threshold (0.1 s) is not yet readiness: the comparison is strict.
        clock.advance(0.05)
        XCTAssertFalse(tracker.timerFired())
        clock.advance(0.01)
        XCTAssertTrue(tracker.timerFired())
        XCTAssertEqual(tracker.state, .fired)
    }

    // MARK: - Displacement threshold (10 px)

    /// A displacement within the tolerance does not cancel the hold.
    func testSmallDisplacementKeepsArmed() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)

        for offset in [CGPoint(x: 3, y: 0), CGPoint(x: 0, y: 9), CGPoint(x: -7, y: 6)] {
            tracker.update(point: offset)
            XCTAssertEqual(tracker.state, .armed, "Displacement \(offset) must stay within the tolerance")
        }
    }

    /// Exactly 10 pt is the tolerance boundary; the requirement is a displacement strictly less,
    /// so exactly at the tolerance the hold is cancelled and rearmed with a new
    /// anchor.
    func testDisplacementExactlyAtThresholdCancels() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        // The 6-8-10 Pythagorean triple: the displacement is exactly 10 pt.
        clock.advance(0.5)
        XCTAssertTrue(tracker.update(point: CGPoint(x: 6, y: 8)))

        // The previous countdown is reset, the anchor moved, a new countdown with the full threshold.
        XCTAssertEqual(tracker.state, .armed)
        XCTAssertEqual(tracker.anchor, CGPoint(x: 6, y: 8))
        XCTAssertEqual(tracker.remainingDuration, 0.6, accuracy: 0.0001)
        XCTAssertFalse(tracker.isMergeReady)
    }

    /// Slightly less than 10 pt: the hold is still in force (the boundary is strict).
    func testDisplacementJustInsideThresholdKeepsArmed() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        tracker.update(point: CGPoint(x: 6, y: 7.999))

        XCTAssertEqual(tracker.state, .armed)
    }

    /// A displacement greater than 10 pt cancels the previous hold and rearms it with
    /// the anchor at the current point.
    func testLargeDisplacementCancels() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        XCTAssertTrue(tracker.update(point: CGPoint(x: 11, y: 0)))

        XCTAssertFalse(tracker.isMergeReady)
        XCTAssertTrue(tracker.isArmed)
        XCTAssertEqual(tracker.anchor, CGPoint(x: 11, y: 0))
    }

    /// The anchor is the point where the hold began, not the previous step: several small
    /// steps in one direction add up.
    func testDisplacementIsMeasuredFromAnchorNotFromLastStep() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        for step in 1...3 {
            tracker.update(point: CGPoint(x: CGFloat(step) * 5, y: 0))
        }

        // Each step is 5 pt: at the second step the distance from the anchor is already 10 pt, so the strict
        // tolerance cancels the hold and moves the anchor to (10, 0); the third
        // step (15, 0) is only 5 pt from the new anchor, so the hold lives.
        XCTAssertEqual(tracker.state, .armed)
        XCTAssertEqual(tracker.anchor, CGPoint(x: 10, y: 0))
    }

    /// After rearming, the old countdown does not "resurrect" readiness: the threshold
    /// is counted from the last noticeable movement.
    func testTimerAfterRearmCountsFromLastMove() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.5)
        tracker.update(point: CGPoint(x: 12, y: 0))
        clock.advance(0.5)

        // 1 s has passed since the hold began, but 0.5 s since the last movement.
        XCTAssertFalse(tracker.timerFired())
        XCTAssertEqual(tracker.state, .armed)
        clock.advance(0.11)
        XCTAssertTrue(tracker.timerFired())
    }

    /// The finger reached the target center in several steps and stopped:
    /// readiness comes >600 ms after the **stop**, not after entering the zone.
    func testStopAfterMovingBeyondToleranceBecomesReadyFromNewAnchor() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.1)
        tracker.update(point: CGPoint(x: 15, y: 0))

        clock.advance(0.6)
        XCTAssertFalse(tracker.timerFired(), "Exactly 600 ms from the new anchor is not ready yet")
        clock.advance(0.01)
        XCTAssertTrue(tracker.timerFired())
        XCTAssertTrue(tracker.isMergeReady)
    }

    /// Constant movement (every step ≥10 pt) rearms the hold
    /// on every step: readiness never comes.
    func testContinuousMovementNeverBecomesReady() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        for step in 1...20 {
            clock.advance(0.2)
            tracker.update(point: CGPoint(x: CGFloat(step) * 12, y: 0))
            XCTAssertFalse(tracker.timerFired(), "step \(step)")
            XCTAssertFalse(tracker.isMergeReady, "step \(step)")
        }
    }

    /// Returning to the old anchor gives no advantage: the countdown runs from
    /// the last rearm (with the new anchor).
    func testReturnToOldAnchorDoesNotShortenCountdown() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.3)
        tracker.update(point: CGPoint(x: 15, y: 0))
        clock.advance(0.5)
        // Return to the old anchor: 15 pt from the new one, a rearm again.
        XCTAssertTrue(tracker.update(point: .zero))
        XCTAssertEqual(tracker.anchor, .zero)
        XCTAssertEqual(tracker.remainingDuration, 0.6, accuracy: 0.0001)

        clock.advance(0.59)
        XCTAssertFalse(tracker.timerFired())
        clock.advance(0.02)
        XCTAssertTrue(tracker.timerFired())
    }

    /// Returning within the tolerance of the new anchor does not reset the hold.
    func testMovementWithinNewAnchorToleranceKeepsCountdown() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        tracker.update(point: CGPoint(x: 20, y: 0))
        clock.advance(0.4)
        XCTAssertFalse(tracker.update(point: CGPoint(x: 24, y: 0)))
        XCTAssertEqual(tracker.remainingDuration, 0.2, accuracy: 0.0001)
    }

    /// A displacement after the "absorb" has already been shown (fired) also starts
    /// a new countdown from the current point instead of resurrecting readiness.
    func testMoveAfterFiredStartsNewCountdownFromNewAnchor() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.61)
        XCTAssertTrue(tracker.timerFired())

        XCTAssertTrue(tracker.update(point: CGPoint(x: 15, y: 0)))
        XCTAssertEqual(tracker.state, .armed)
        XCTAssertFalse(tracker.isMergeReady)
        XCTAssertEqual(tracker.remainingDuration, 0.6, accuracy: 0.0001)
    }

    // MARK: - Time threshold (600 ms)

    /// Before the threshold expires the timer does not enable readiness.
    func testTimerBeforeThresholdKeepsArmed() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.59)

        XCTAssertFalse(tracker.timerFired())
        XCTAssertEqual(tracker.state, .armed)
        XCTAssertFalse(tracker.isMergeReady)
        XCTAssertEqual(tracker.remainingDuration, 0.01, accuracy: 0.0001)
    }

    /// Exactly 600 ms: the threshold has not been held yet; the requirement is "more than 600 ms".
    func testTimerAtThresholdDoesNotFire() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.6)

        XCTAssertFalse(tracker.timerFired())
        XCTAssertEqual(tracker.state, .armed)
        XCTAssertFalse(tracker.isMergeReady)
    }

    /// Slightly more than 600 ms: readiness comes.
    func testTimerJustOverThresholdFires() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.6001)

        XCTAssertTrue(tracker.timerFired())
        XCTAssertEqual(tracker.state, .fired)
        XCTAssertTrue(tracker.isMergeReady)
    }

    /// A hold longer than the threshold enables readiness too.
    func testTimerAfterThresholdFires() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(1.5)

        XCTAssertTrue(tracker.timerFired())
        XCTAssertTrue(tracker.isMergeReady)
    }

    /// After readiness the remainder until firing is 0; a repeated timer call
    /// breaks nothing.
    func testRemainingDurationIsZeroAfterFire() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.61)
        XCTAssertTrue(tracker.timerFired())

        XCTAssertEqual(tracker.remainingDuration, 0, accuracy: 0.0001)
        XCTAssertFalse(tracker.timerFired())
        XCTAssertEqual(tracker.state, .fired)
    }

    /// A timer without hover (idle) does not fire.
    func testTimerWithoutHoverDoesNothing() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        clock.advance(5)

        XCTAssertFalse(tracker.timerFired())
        XCTAssertEqual(tracker.state, .idle)
    }

    // MARK: - Readiness and drop

    /// The drop gate: a folder is created only when `isMergeReady`.
    ///
    /// `finishDrag(commit: true)` asks exactly this property, so the test
    /// pins that readiness is enabled only by the timer and cleared by displacement:
    /// there is no longer an instant merge on drop (the behavior before the hold was introduced).
    func testDropMergesOnlyAfterHoverFires() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)

        // A drop right after hover gives no grouping (on a tile center this is a
        // no-op).
        XCTAssertFalse(tracker.isMergeReady)
        XCTAssertFalse(tracker.timerFired())

        clock.advance(0.3)
        // A drop at half the hold is still an ordinary drag.
        XCTAssertFalse(tracker.timerFired())
        XCTAssertFalse(tracker.isMergeReady)

        clock.advance(0.31)
        // A drop after 600 ms is a merge.
        XCTAssertTrue(tracker.timerFired())
        XCTAssertTrue(tracker.isMergeReady)
    }

    /// A small finger tremor after readiness does not cancel the merge.
    func testSmallMoveAfterFireKeepsReady() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.61)
        XCTAssertTrue(tracker.timerFired())

        tracker.update(point: CGPoint(x: 5, y: -5))

        XCTAssertTrue(tracker.isMergeReady)
        XCTAssertEqual(tracker.state, .fired)
    }

    /// A noticeable movement after readiness cancels the merge (with a rearm from
    /// the new point): the "absorb" highlight promises a folder only while the finger is still.
    func testLargeMoveAfterFireCancelsReady() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.61)
        XCTAssertTrue(tracker.timerFired())

        tracker.update(point: CGPoint(x: 11, y: 0))

        XCTAssertFalse(tracker.isMergeReady)
        XCTAssertEqual(tracker.state, .armed)
    }

    // MARK: - Resets and target change

    /// Changing the target starts a new countdown with the full threshold.
    func testBeginHoverOnAnotherTargetRestartsCountdown() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.61)
        XCTAssertTrue(tracker.timerFired())

        clock.advance(0.5)
        tracker.beginHover(targetID: "b", point: CGPoint(x: 100, y: 100))

        XCTAssertEqual(tracker.state, .armed)
        XCTAssertEqual(tracker.targetID?.base as? String, "b")
        XCTAssertEqual(tracker.anchor?.x, 100)
        XCTAssertEqual(tracker.anchor?.y, 100)
        XCTAssertEqual(tracker.remainingDuration, 0.6, accuracy: 0.0001)

        clock.advance(0.59)
        XCTAssertFalse(tracker.timerFired())
        clock.advance(0.02)
        XCTAssertTrue(tracker.timerFired())
    }

    /// Per-frame repeated calls for the same tile do not restart the countdown.
    func testRepeatedBeginHoverForSameTargetDoesNotRestart() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.4)

        // The finger moved slightly, the coordinator passed the same target again.
        tracker.beginHover(targetID: "a", point: CGPoint(x: 3, y: 0))
        XCTAssertEqual(tracker.state, .armed)
        XCTAssertEqual(tracker.remainingDuration, 0.2, accuracy: 0.0001)

        clock.advance(0.21)
        XCTAssertTrue(tracker.timerFired())
    }

    /// A repeated call for the same tile while ready does not reset readiness.
    func testRepeatedBeginHoverAfterFireKeepsReady() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.61)
        XCTAssertTrue(tracker.timerFired())

        tracker.beginHover(targetID: "a", point: CGPoint(x: 2, y: 2))

        XCTAssertEqual(tracker.state, .fired)
        XCTAssertTrue(tracker.isMergeReady)
    }

    /// A repeated `beginHover` after a rearm for the same target restarts nothing
    /// (the anchor stays moved, the countdown is not reset).
    func testBeginHoverForSameTargetAfterRearmDoesNotRestart() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        tracker.update(point: CGPoint(x: 15, y: 0))
        XCTAssertEqual(tracker.state, .armed)
        clock.advance(0.2)

        tracker.beginHover(targetID: "a", point: CGPoint(x: 15, y: 0))

        XCTAssertEqual(tracker.state, .armed)
        XCTAssertEqual(tracker.remainingDuration, 0.4, accuracy: 0.0001)
    }

    /// `reset()` returns the machine to the initial state.
    func testResetReturnsToIdle() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.61)
        XCTAssertTrue(tracker.timerFired())

        tracker.reset()

        XCTAssertEqual(tracker.state, .idle)
        XCTAssertNil(tracker.targetID)
        XCTAssertNil(tracker.anchor)
        XCTAssertFalse(tracker.isMergeReady)
        XCTAssertEqual(tracker.remainingDuration, 0, accuracy: 0.0001)
        XCTAssertFalse(tracker.timerFired())
    }

    /// `update` without hover does nothing.
    func testUpdateWithoutHoverDoesNothing() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        tracker.update(point: CGPoint(x: 100, y: 100))

        XCTAssertEqual(tracker.state, .idle)
        XCTAssertFalse(tracker.timerFired())
    }
}

#endif
