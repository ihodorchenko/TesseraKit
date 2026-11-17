//
//  TileSizeCycleTests.swift
//  TesseraStartScreenTests
//
//  The size cycle on a tap of the arrow (D28): small → wide → medium →
//  large → small. The order is set explicitly (`TesseraTileSize.cycleOrder`), not by the order of
//  `allCases`; the host provides the set via `supportedSizesProvider`, not the order.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §5 and "Implementation
//  deviations"; docs/W10M-STARTSCREEN.md §5.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileSizeCycleTests: XCTestCase {

    // MARK: - Pure model

    /// The cycle order is that of Windows 10 Mobile with `large` last; it differs from `allCases`.
    func testCycleOrderIsExplicitAndDiffersFromAllCases() {
        XCTAssertEqual(TesseraTileSize.cycleOrder, [.small, .wide, .medium, .large])
        XCTAssertEqual(TesseraTileSize.allCases, [.small, .medium, .wide, .large])
        XCTAssertNotEqual(TesseraTileSize.cycleOrder, TesseraTileSize.allCases)
        XCTAssertEqual(Set(TesseraTileSize.cycleOrder), Set(TesseraTileSize.allCases), "all four D15 sizes")
    }

    /// From any size the full set leads around the circle in the Windows 10 Mobile order.
    func testNextAmongAllSizesFollowsCycleFromEveryStart() {
        let all = TesseraTileSize.allCases
        XCTAssertEqual(TesseraTileSize.small.next(among: all), .wide)
        XCTAssertEqual(TesseraTileSize.wide.next(among: all), .medium)
        XCTAssertEqual(TesseraTileSize.medium.next(among: all), .large)
        XCTAssertEqual(TesseraTileSize.large.next(among: all), .small)

        for start in TesseraTileSize.allCases {
            var size = start
            var visited: [TesseraTileSize] = []
            for _ in 0..<4 {
                size = size.next(among: all)
                visited.append(size)
            }
            XCTAssertEqual(size, start, "four steps close the circle from \(start)")
            XCTAssertEqual(Set(visited).count, 4, "the circle visits all sizes from \(start)")
        }
    }

    /// Unsupported sizes are skipped; the order of the host list does not matter.
    func testNextSkipsUnsupportedAndIgnoresHostListOrder() {
        // Without wide: small → medium → large → small.
        let noWide: [TesseraTileSize] = [.large, .small, .medium]
        XCTAssertEqual(TesseraTileSize.small.next(among: noWide), .medium)
        XCTAssertEqual(TesseraTileSize.medium.next(among: noWide), .large)
        XCTAssertEqual(TesseraTileSize.large.next(among: noWide), .small)

        // Without large (3 columns: wide does not fit either → small/medium).
        XCTAssertEqual(TesseraTileSize.small.next(among: [.medium, .small]), .medium)
        XCTAssertEqual(TesseraTileSize.medium.next(among: [.medium, .small]), .small)

        // The list in reverse order gives the same result.
        for start in TesseraTileSize.allCases {
            XCTAssertEqual(
                start.next(among: [.small, .wide, .large]),
                start.next(among: [.large, .wide, .small])
            )
        }
        XCTAssertEqual(TesseraTileSize.small.next(among: [.small, .large]), .large)
        XCTAssertEqual(TesseraTileSize.large.next(among: [.small, .large]), .small)
    }

    /// A single supported size closes the cycle on itself; an empty set does too.
    func testNextWithSingleOrEmptySetStaysOnCurrent() {
        for size in TesseraTileSize.allCases {
            XCTAssertEqual(size.next(among: [size]), size)
            XCTAssertEqual(size.next(among: []), size)
        }
    }

    /// The current size is outside the supported set: the nearest one further along the cycle is taken.
    func testNextFromUnsupportedCurrentTakesNearestOnCycle() {
        XCTAssertEqual(TesseraTileSize.medium.next(among: [.small, .wide]), .small, "medium → large (unsupported) → small")
        XCTAssertEqual(TesseraTileSize.wide.next(among: [.large]), .large)
        XCTAssertEqual(TesseraTileSize.small.next(among: [.large, .medium]), .medium, "small → wide (unsupported) → medium")
    }

    // MARK: - Coordinator

    private func makeHost(
        size: TesseraTileSize,
        columns: Int = 6
    ) -> TesseraTestDragHost {
        TesseraTestDragHost(
            descriptors: [tesseraTestTile("a", size: size)],
            columns: columns
        )
    }

    /// The coordinator follows the D28 cycle from each starting size and closes the circle.
    func testCoordinatorCyclesInW10MOrderFromEveryStart() {
        let expected: [TesseraTileSize: [TesseraTileSize]] = [
            .small: [.wide, .medium, .large, .small],
            .wide: [.medium, .large, .small, .wide],
            .medium: [.large, .small, .wide, .medium],
            .large: [.small, .wide, .medium, .large],
        ]
        for start in TesseraTileSize.allCases {
            let host = makeHost(size: start)
            for (step, next) in (expected[start] ?? []).enumerated() {
                XCTAssertEqual(host.coordinator.cycleSize(of: "a"), next, "start \(start), step \(step + 1)")
                XCTAssertEqual(host.store.descriptor(withID: "a")?.size, next)
                XCTAssertEqual(host.host.grid.items.first { $0.id == AnyHashable("a") }?.size, next)
            }
        }
    }

    /// The host narrows the set: the cycle skips unavailable sizes, the order is set
    /// by the model, not by the host list.
    func testCoordinatorRespectsSupportedSizesProvider() {
        let host = makeHost(size: .small)
        host.coordinator.supportedSizesProvider = { _ in [.large, .small, .medium] }
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .medium, "wide skipped")
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .large)
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .small)

        host.coordinator.supportedSizesProvider = { _ in [.large, .wide] }
        // The current small is outside the set: the nearest one further along the cycle is wide.
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .wide)
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .large)
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .wide)
    }

    /// A single supported size: there is nothing to change, no arrow.
    func testCoordinatorSingleSupportedSizeDoesNothing() {
        let host = makeHost(size: .medium)
        host.coordinator.supportedSizesProvider = { _ in [.medium] }
        XCTAssertNil(host.coordinator.cycleSize(of: "a"))
        XCTAssertEqual(host.store.descriptor(withID: "a")?.size, .medium)
    }

    /// A narrow grid (3 columns): wide/large do not fit, the cycle is small ↔ medium.
    func testCoordinatorInNarrowGridCyclesBetweenSmallAndMedium() {
        let host = makeHost(size: .small, columns: 3)
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .medium)
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .small)
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .medium)
    }

    // MARK: - Storage format

    /// The size after cycle steps is saved and read as before (the raw
    /// value of `TesseraTileSize`); the file format did not change.
    func testPersistenceRoundTripKeepsCycledSize() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog([tesseraTestTile("a", size: .small)])
        store.placeItems(columns: 6)
        XCTAssertTrue(store.resize("a", to: TesseraTileSize.small.next(among: TesseraTileSize.allCases), columns: 6))
        try store.save()

        let fresh = TesseraTileStore(directoryURL: directory.url)
        fresh.setCatalog([tesseraTestTile("a", size: .small)])
        try fresh.load()
        XCTAssertEqual(fresh.descriptor(withID: "a")?.size, .wide)

        let json = try String(contentsOf: store.fileURL)
        XCTAssertTrue(json.contains("\"wide\""), "the file has the raw size value")
    }

    // MARK: - VoiceOver

    /// The "Change size" action performs the same D28 cycle step as the arrow: both
    /// call `cycleSize(of:)`, so the same new size is announced
    /// (the announcement is posted only when VoiceOver is on and is not intercepted).
    func testVoiceOverResizeActionUsesSameCycle() throws {
        let host = makeHost(size: .small)
        host.coordinator.beginEditing()
        let resizeName = TesseraStartScreenStrings.string(.a11yActionResize)
        func action() -> UIAccessibilityCustomAction? {
            host.host.cell("a")?.accessibilityCustomActions?.first { $0.name == resizeName }
        }
        XCTAssertTrue(host.waitUntil { action() != nil })

        let expected: [TesseraTileSize] = [.wide, .medium, .large, .small]
        for next in expected {
            let current = try XCTUnwrap(action())
            XCTAssertEqual(current.actionHandler?(current), true)
            XCTAssertEqual(host.store.descriptor(withID: "a")?.size, next)
            XCTAssertTrue(host.waitUntil { action() != nil })
        }
        host.coordinator.endEditing()
    }

    /// The arrow (an overlay button) and the VoiceOver action give the same size.
    func testArrowButtonAndVoiceOverActionAgree() throws {
        let host = makeHost(size: .wide)
        host.coordinator.beginEditing()
        host.spin(0.03)
        let control = try XCTUnwrap(host.coordinator.editControls["a"])
        control.onResize?()
        XCTAssertEqual(host.store.descriptor(withID: "a")?.size, .medium, "arrow: wide → medium")

        let resizeName = TesseraStartScreenStrings.string(.a11yActionResize)
        XCTAssertTrue(host.waitUntil {
            host.host.cell("a")?.accessibilityCustomActions?.contains { $0.name == resizeName } == true
        })
        let action = try XCTUnwrap(
            host.host.cell("a")?.accessibilityCustomActions?.first { $0.name == resizeName }
        )
        XCTAssertEqual(action.actionHandler?(action), true)
        XCTAssertEqual(host.store.descriptor(withID: "a")?.size, .large, "VoiceOver: medium → large")
        host.coordinator.endEditing()
    }
}

#endif
