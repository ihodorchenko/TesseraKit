//
//  LiveTileEngineTests.swift
//  TesseraStartScreenTests
//
//  Tests for the live tile engine.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §4 "Live tiles (engine)"
//  (flips, staggering in batches with random jitter, pauses off screen/in the background,
//  Reduce Motion: no flips, a static front is shown) and §9
//  "Accessibility" (Reduce Motion).
//
//  The tests check the pure stagger/batch functions with a seeded generator and the behavior
//  of the engine with an injected Reduce Motion provider. They do not wait for timers
//  and do not bring up a window: "flips disabled" is checked by the settled side of the
//  tile after `refresh`, not by time.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class LiveTileEngineTests: XCTestCase {

    // MARK: - Test provider

    /// A content provider with an observable subscription.
    private final class TestProvider: TesseraLiveTileContentProvider {

        var frontFace = TesseraLiveTileFace(title: "Front")
        var backFaceValue: TesseraLiveTileFace? = TesseraLiveTileFace(
            title: "Back",
            detail: "3 new"
        )

        var backFace: TesseraLiveTileFace? {
            backFaceValue
        }

        /// How many times the engine subscribed to updates.
        private(set) var observationCount = 0

        /// How many times the subscription was cancelled.
        private(set) var cancellationCount = 0

        func startObservingChanges(_ onChange: @escaping () -> Void) -> (() -> Void)? {
            observationCount += 1
            return { [weak self] in
                self?.cancellationCount += 1
            }
        }
    }

    // MARK: - Helpers

    private func makePlanner(
        batchSize: Int = 3,
        batchStagger: TimeInterval = 0.35,
        jitter: TimeInterval = 0.35,
        seed: UInt64 = 42
    ) -> TesseraLiveTileStaggerPlanner {
        TesseraLiveTileStaggerPlanner(
            batchSize: batchSize,
            batchStagger: batchStagger,
            jitter: jitter,
            seed: seed
        )
    }

    // MARK: - Stagger and batches (seeded)

    /// One seed gives the same plan: the behavior is reproducible in tests and on
    /// a device (§4).
    func testPlannerIsDeterministicForSameSeed() {
        let first = makePlanner(seed: 42).plan(tileCount: 8)
        let second = makePlanner(seed: 42).plan(tileCount: 8)

        XCTAssertEqual(first.entries, second.entries)
        XCTAssertEqual(first.maximumDelay, second.maximumDelay, accuracy: 1e-9)
    }

    /// A different seed changes the batch order (the check is pinned for two
    /// known seeds so that the test does not depend on randomness).
    func testPlannerDifferentSeedsProduceDifferentOrders() {
        let first = makePlanner(seed: 42).plan(tileCount: 8)
        let second = makePlanner(seed: 7).plan(tileCount: 8)

        XCTAssertNotEqual(first.entries.map { $0.index }, second.entries.map { $0.index })
    }

    /// Each tile gets exactly one flip per cycle; the stagger changes only
    /// the start moments, not the number of flips (§4).
    func testPlannerAssignsEveryTileExactlyOnce() {
        let plan = makePlanner(seed: 123).plan(tileCount: 10)

        XCTAssertEqual(plan.entries.count, 10)
        XCTAssertEqual(plan.entries.map { $0.index }.sorted(), Array(0..<10))
        XCTAssertEqual(Set(plan.entries.map { $0.index }).count, 10)
    }

    /// Batch `k` starts after `k × batchStagger`, with a random addition
    /// `0...jitter` inside the batch (§4).
    func testPlannerBatchesAndDelays() {
        let batchSize = 3
        let stagger: TimeInterval = 0.35
        let jitter: TimeInterval = 0.35
        let plan = makePlanner(
            batchSize: batchSize,
            batchStagger: stagger,
            jitter: jitter,
            seed: 42
        ).plan(tileCount: 8)

        for (position, entry) in plan.entries.enumerated() {
            XCTAssertEqual(entry.batch, position / batchSize)
            let batchStart = Double(entry.batch) * stagger
            XCTAssertGreaterThanOrEqual(entry.delay, batchStart - 1e-9)
            XCTAssertLessThanOrEqual(entry.delay, batchStart + jitter + 1e-9)
        }

        let maximum = plan.entries.map { $0.delay }.max() ?? 0
        XCTAssertEqual(plan.maximumDelay, maximum, accuracy: 1e-9)
    }

    /// Without jitter the delay equals just the batch start.
    func testPlannerWithZeroJitterUsesBatchStaggerOnly() {
        let plan = makePlanner(batchStagger: 0.5, jitter: 0, seed: 5).plan(tileCount: 7)

        for entry in plan.entries {
            XCTAssertEqual(entry.delay, Double(entry.batch) * 0.5, accuracy: 1e-9)
        }
    }

    /// Empty and negative input give an empty plan.
    func testPlannerHandlesEmptyAndNegativeCounts() {
        let empty = makePlanner().plan(tileCount: 0)
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertEqual(empty.maximumDelay, 0)

        let negative = makePlanner().plan(tileCount: -5)
        XCTAssertTrue(negative.entries.isEmpty)
        XCTAssertEqual(negative.maximumDelay, 0)
    }

    /// Negative parameters are clamped: `batchSize` is at least 1, pauses are 0.
    func testPlannerClampsNegativeParameters() {
        let planner = makePlanner(batchSize: 0, batchStagger: -1, jitter: -1, seed: 1)
        let plan = planner.plan(tileCount: 5)

        XCTAssertEqual(plan.entries.count, 5)
        for (position, entry) in plan.entries.enumerated() {
            XCTAssertEqual(entry.batch, position)
            XCTAssertEqual(entry.delay, 0, accuracy: 1e-9)
        }
        XCTAssertEqual(plan.maximumDelay, 0, accuracy: 1e-9)
    }

    /// A seedable generator: the same sequence for the same seed,
    /// values in `0..<upperBound`.
    func testSeededGeneratorIsDeterministicAndInRange() {
        var first = TesseraSeededGenerator(seed: 7)
        var second = TesseraSeededGenerator(seed: 7)

        for _ in 0..<16 {
            XCTAssertEqual(first.next(), second.next())
        }

        for _ in 0..<100 {
            XCTAssertLessThan(first.next(upperBound: 7), 7)
        }
        XCTAssertEqual(first.next(upperBound: 1), 0)
    }

    // MARK: - Engine configuration

    /// Default values from §4: a rare cycle, a short flip, batches of three.
    func testConfigurationDefaults() {
        let configuration = TesseraLiveTileEngine.Configuration()

        XCTAssertEqual(configuration.cycleInterval, 8)
        XCTAssertEqual(configuration.flipDuration, 0.45)
        XCTAssertEqual(configuration.batchSize, 3)
        XCTAssertEqual(configuration.batchStagger, 0.35)
        XCTAssertEqual(configuration.jitter, 0.35)
    }

    // MARK: - Engine and Reduce Motion

    /// An engine without a window: registration reads the sides and does not start a flip.
    ///
    /// `flipDuration` is applied to the container on registration (§4).
    func testRegistrationSetsFacesAndFlipDuration() {
        let engine = TesseraLiveTileEngine(
            configuration: TesseraLiveTileEngine.Configuration(flipDuration: 0.9),
            isReduceMotionEnabled: { true }
        )
        let view = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let provider = TestProvider()

        engine.register(view, provider: provider, isVisible: true)

        XCTAssertEqual(view.face(for: .front)?.title, "Front")
        XCTAssertEqual(view.face(for: .back)?.title, "Back")
        XCTAssertEqual(view.flipAnimationDuration, 0.9, accuracy: 1e-9)
        XCTAssertEqual(view.side, .front)
        XCTAssertFalse(view.isFlipping)
        XCTAssertEqual(provider.observationCount, 1)

        engine.unregister(view)
        XCTAssertEqual(provider.cancellationCount, 1)

        // A repeated cancellation must not call the subscription a second time.
        engine.unregister(view)
        XCTAssertEqual(provider.cancellationCount, 1)
    }

    /// Reduce Motion: no flips, a static front is shown. Even if
    /// the tile was switched to the back, `refresh` returns it to the front (§4, §9).
    func testReduceMotionKeepsStaticFront() {
        let engine = TesseraLiveTileEngine(
            configuration: TesseraLiveTileEngine.Configuration(
                cycleInterval: 0.5,
                flipDuration: 0.2,
                batchSize: 2,
                batchStagger: 0,
                jitter: 0,
                seed: 1
            ),
            isReduceMotionEnabled: { true }
        )
        let view = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let provider = TestProvider()

        engine.register(view, provider: provider)
        XCTAssertEqual(view.side, .front)

        // Force the back to be shown: the engine must return the front.
        view.show(.back, animated: false)
        XCTAssertEqual(view.side, .back)

        engine.refresh(view)
        XCTAssertEqual(view.side, .front)
        XCTAssertFalse(view.isFlipping)

        engine.setVisible(false, for: view)
        engine.setVisible(true, for: view)
        engine.refresh(view)
        XCTAssertEqual(view.side, .front)

        engine.unregister(view)
    }

    /// A visibility pause does not start a flip and does not break registration (§4,
    /// "Pauses"): a repeated registration replaces the previous entry.
    func testVisibilityPauseAndReRegistrationAreSafe() {
        let engine = TesseraLiveTileEngine(
            configuration: TesseraLiveTileEngine.Configuration(seed: 2),
            isReduceMotionEnabled: { true }
        )
        let view = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let first = TestProvider()
        let second = TestProvider()

        engine.register(view, provider: first, isVisible: false)
        engine.setVisible(true, for: view)
        engine.register(view, provider: second, isVisible: true)

        XCTAssertEqual(first.cancellationCount, 1)
        XCTAssertEqual(second.observationCount, 1)
        XCTAssertEqual(view.side, .front)

        engine.unregister(view)
        XCTAssertEqual(second.cancellationCount, 1)
    }

    /// A provider without a back is a static tile: a back request is ignored, and the engine
    /// does not consider it suitable for a flip (§4, "optional back").
    func testProviderWithoutBackStaysOnFront() {
        let engine = TesseraLiveTileEngine(
            configuration: TesseraLiveTileEngine.Configuration(),
            isReduceMotionEnabled: { true }
        )
        let view = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let provider = TestProvider()
        provider.backFaceValue = nil

        engine.register(view, provider: provider)
        XCTAssertNil(view.face(for: .back))
        view.show(.back, animated: false)
        XCTAssertEqual(view.side, .front)

        engine.unregister(view)
    }
}

#endif
