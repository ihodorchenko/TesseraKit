//
//  TileMagnetTests.swift
//  TesseraStartScreenTests
//
//  Tests for the magnet to cells.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §5 "Edit mode"
//  (magnet): a virtual grid is built under the dragged tile,
//  and the drag image is smoothly pulled to the center of the nearest slot of the same dimensions.
//
//  The pure math of `TesseraTileMagnet` is tested (no UI): choosing
//  the nearest center within the radius, the radius boundary, degenerate and non-numeric
//  inputs, determinism at equal distance. The slot geometry comes from
//  the grid, so the tests do not instantiate `UICollectionView`.
//
//  The coordinator passes the **drag image center** (`point + grabOffset`) here,
//  not the finger point; the function itself stays a pure "point → nearest slot",
//  so the contract and the tests do not change. The check that the coordinator computes
//  from the drag image center is `DragSessionTests.testMagnetUsesSnapshotCenterNotFingerPoint`.
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileMagnetTests: XCTestCase {

    // MARK: - Configuration

    /// Default values: a radius within the Windows Phone spec range of 24–32 pt and
    /// a short pull spring.
    func testConfigurationDefaultsMatchSpec() {
        let configuration = TesseraTileEditConfiguration()

        XCTAssertEqual(configuration.magnetSnapRadius, 28, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(configuration.magnetSnapRadius, 24)
        XCTAssertLessThanOrEqual(configuration.magnetSnapRadius, 32)

        XCTAssertEqual(configuration.magnetSpringDuration, 0.2, accuracy: 0.0001)
        XCTAssertGreaterThan(configuration.magnetSpringDuration, 0)
        XCTAssertLessThanOrEqual(configuration.magnetSpringDuration, 0.3)

        XCTAssertEqual(configuration.magnetSpringDamping, 0.82, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(configuration.magnetSpringDamping, 0)
        XCTAssertLessThanOrEqual(configuration.magnetSpringDamping, 1)
    }

    /// Custom values pass through the initializer without distortion.
    func testCustomConfigurationIsStored() {
        let configuration = TesseraTileEditConfiguration(
            magnetSnapRadius: 24,
            magnetSpringDuration: 0.15,
            magnetSpringDamping: 0.7
        )

        XCTAssertEqual(configuration.magnetSnapRadius, 24, accuracy: 0.0001)
        XCTAssertEqual(configuration.magnetSpringDuration, 0.15, accuracy: 0.0001)
        XCTAssertEqual(configuration.magnetSpringDamping, 0.7, accuracy: 0.0001)
    }

    // MARK: - Choosing the nearest slot

    /// Pulls to the nearest center, not to the first one in the array.
    func testNearestCenterWins() {
        let centers = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 100, y: 0),
            CGPoint(x: 0, y: 100)
        ]

        XCTAssertEqual(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 20, y: 5),
                slotCenters: centers,
                snapRadius: 30
            ),
            CGPoint(x: 0, y: 0)
        )
        XCTAssertEqual(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 85, y: 0),
                slotCenters: centers,
                snapRadius: 30
            ),
            CGPoint(x: 100, y: 0)
        )
    }

    /// The distance is Euclidean: a point "on the diagonal" is pulled too.
    func testDiagonalDistanceIsEuclidean() {
        XCTAssertEqual(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 18, y: 24),
                slotCenters: [CGPoint(x: 0, y: 0)],
                snapRadius: 31
            ),
            CGPoint(x: 0, y: 0)
        )
        XCTAssertNil(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 18, y: 24),
                slotCenters: [CGPoint(x: 0, y: 0)],
                snapRadius: 29
            )
        )
    }

    /// There is no pull beyond the pull radius.
    func testPointOutsideRadiusHasNoTarget() {
        XCTAssertNil(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 40, y: 0),
                slotCenters: [CGPoint(x: 0, y: 0)],
                snapRadius: 24
            )
        )
    }

    /// The radius is inclusive: a center exactly on the boundary still pulls.
    func testExactRadiusIsInclusive() {
        // The 3-4-5 triangle: the distance is exactly 5 pt.
        XCTAssertEqual(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 3, y: 4),
                slotCenters: [CGPoint(x: 0, y: 0)],
                snapRadius: 5
            ),
            CGPoint(x: 0, y: 0)
        )
        XCTAssertNil(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 3.1, y: 4),
                slotCenters: [CGPoint(x: 0, y: 0)],
                snapRadius: 5
            )
        )
    }

    /// A zero radius disables the pull (even exactly over a center).
    func testZeroRadiusDisablesMagnet() {
        XCTAssertNil(
            TesseraTileMagnet.magnetTarget(
                for: .zero,
                slotCenters: [.zero],
                snapRadius: 0
            )
        )
    }

    /// A negative and a non-numeric radius are treated as a disabled pull.
    func testInvalidRadiusDisablesMagnet() {
        let centers = [CGPoint(x: 0, y: 0)]

        for radius in [CGFloat(-10), .nan, .infinity] {
            XCTAssertNil(
                TesseraTileMagnet.magnetTarget(
                    for: .zero,
                    slotCenters: centers,
                    snapRadius: radius
                ),
                "Radius \(radius) must disable the pull"
            )
        }
    }

    // MARK: - Degenerate inputs

    /// An empty set of slots: there is nothing to pull to.
    func testEmptySlotCentersReturnNil() {
        XCTAssertNil(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 10, y: 10),
                slotCenters: [],
                snapRadius: 32
            )
        )
    }

    /// At equal distance the first slot wins: the result is deterministic.
    func testFirstCenterWinsOnTie() {
        let left = CGPoint(x: -10, y: 0)
        let right = CGPoint(x: 10, y: 0)

        XCTAssertEqual(
            TesseraTileMagnet.magnetTarget(
                for: .zero,
                slotCenters: [left, right],
                snapRadius: 15
            ),
            left
        )
        XCTAssertEqual(
            TesseraTileMagnet.magnetTarget(
                for: .zero,
                slotCenters: [right, left],
                snapRadius: 15
            ),
            right
        )
    }

    /// Non-numeric centers are skipped instead of breaking the whole search.
    func testNonFiniteCentersAreSkipped() {
        let broken = CGPoint(x: CGFloat.nan, y: 0)
        let valid = CGPoint(x: 0, y: 0)

        XCTAssertEqual(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 5, y: 0),
                slotCenters: [broken, valid],
                snapRadius: 10
            ),
            valid
        )
    }

    /// A non-numeric finger point gives no target.
    func testNonFinitePointReturnsNil() {
        XCTAssertNil(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: CGFloat.nan, y: 10),
                slotCenters: [CGPoint(x: 0, y: 0)],
                snapRadius: 32
            )
        )
        XCTAssertNil(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 10, y: CGFloat.infinity),
                slotCenters: [CGPoint(x: 0, y: 0)],
                snapRadius: 32
            )
        )
    }

    // MARK: - Virtual slot grid

    /// The centers go in steps of "unit + gap" and cover all positions where a tile
    /// of the same dimensions fits.
    func testVirtualSlotCentersCoverEveryCell() {
        let centers = TesseraTileMagnet.slotCenters(
            for: .medium,
            columns: 4,
            unit: 100,
            gap: 10,
            origin: CGPoint(x: 16, y: 16),
            rowCount: 2
        )

        // 2×2 in a grid of 4 columns and 2 rows: three positions horizontally.
        XCTAssertEqual(centers, [
            CGPoint(x: 121, y: 121),
            CGPoint(x: 231, y: 121),
            CGPoint(x: 341, y: 121)
        ])
    }

    /// A small tile fits into every cell, including empty ones.
    func testVirtualSlotCentersForSmallTile() {
        let centers = TesseraTileMagnet.slotCenters(
            for: .small,
            columns: 2,
            unit: 50,
            gap: 0,
            origin: .zero,
            rowCount: 2
        )

        XCTAssertEqual(centers, [
            CGPoint(x: 25, y: 25),
            CGPoint(x: 75, y: 25),
            CGPoint(x: 25, y: 75),
            CGPoint(x: 75, y: 75)
        ])
    }

    /// The footprint shrinks to a narrow grid as in the layout: a wide tile
    /// in two columns becomes 2×2.
    func testVirtualSlotCentersFitNarrowGrid() {
        let centers = TesseraTileMagnet.slotCenters(
            for: .wide,
            columns: 2,
            unit: 100,
            gap: 0,
            origin: .zero,
            rowCount: 2
        )

        XCTAssertEqual(centers, [CGPoint(x: 100, y: 100)])
    }

    /// The tile lacks occupied rows: there are no slots.
    func testVirtualSlotCentersRequireEnoughRows() {
        XCTAssertTrue(
            TesseraTileMagnet.slotCenters(
                for: .large,
                columns: 4,
                unit: 100,
                gap: 10,
                origin: .zero,
                rowCount: 3
            ).isEmpty
        )
    }

    /// Degenerate geometry gives no slots.
    func testVirtualSlotCentersInvalidGeometryIsEmpty() {
        XCTAssertTrue(
            TesseraTileMagnet.slotCenters(
                for: .small,
                columns: 0,
                unit: 100,
                gap: 10,
                origin: .zero,
                rowCount: 2
            ).isEmpty
        )
        XCTAssertTrue(
            TesseraTileMagnet.slotCenters(
                for: .small,
                columns: 4,
                unit: 0,
                gap: 10,
                origin: .zero,
                rowCount: 2
            ).isEmpty
        )
        XCTAssertTrue(
            TesseraTileMagnet.slotCenters(
                for: .small,
                columns: 4,
                unit: 100,
                gap: 10,
                origin: .zero,
                rowCount: 0
            ).isEmpty
        )
    }

    // MARK: - Radius from the configuration

    /// The pull uses the configuration radius, not its own threshold.
    func testConfiguredRadiusIsUsed() {
        let configuration = TesseraTileEditConfiguration(magnetSnapRadius: 24)
        let centers = [CGPoint(x: 0, y: 0)]

        XCTAssertEqual(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 24, y: 0),
                slotCenters: centers,
                snapRadius: configuration.magnetSnapRadius
            ),
            centers[0]
        )
        XCTAssertNil(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 25, y: 0),
                slotCenters: centers,
                snapRadius: configuration.magnetSnapRadius
            )
        )
    }
}

#endif
