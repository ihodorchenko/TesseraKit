//
//  TileGridPixelAlignmentTests.swift
//  TesseraStartScreenTests
//
//  Pixel alignment of the start screen grid.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §3 "Layout model"
//  (the unit formula), "Implementation deviations" (pixel alignment).
//
//  The §3 formula gives a fractional unit: at a width of 393 pt (content 361, gap 8)
//  the unit is 84.25 pt, so tile edges fall between pixels. The layout rounds the
//  unit down to a pixel (`1 / displayScale`) and divides the remaining width equally
//  between the margins. The real layout is checked with the scale substituted: all frames
//  (tiles, the folder and the expanded folder's panel) are multiples of `1 / scale`.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileGridPixelAlignmentTests: XCTestCase {

    /// iPhone screen widths (SE/mini, 13/14, 15/16 Pro, Pro Max).
    private let widths: [CGFloat] = [375, 390, 393, 430]

    /// Screen scales.
    private let scales: [CGFloat] = [2, 3]

    /// Checks that a value is a multiple of `1 / scale`.
    private func assertOnPixelGrid(
        _ value: CGFloat,
        scale: CGFloat,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let pixels = value * scale
        XCTAssertEqual(pixels, pixels.rounded(), accuracy: 1e-6, message, file: file, line: line)
    }

    /// A layout on a collection without a window, with the scale substituted.
    private func makeLayout(
        width: CGFloat,
        scale: CGFloat,
        spacing: CGFloat = 8,
        columns: Int = 4
    ) -> (TesseraTileCollectionViewLayout, UICollectionView) {
        let layout = TesseraTileCollectionViewLayout()
        layout.columns = columns
        layout.itemSpacing = spacing
        layout.displayScaleOverride = scale
        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: width, height: 844),
            collectionViewLayout: layout
        )
        return (layout, collectionView)
    }

    /// A set with an expanded folder and tiles of all sizes.
    private func makeItems() -> [TesseraTileGridItem] {
        let folder = TesseraTileFolder(
            id: "folder",
            title: "folder",
            tiles: (0..<7).map { tesseraTestTile("ft\($0)", size: .small) },
            size: .medium
        )
        var items: [TesseraTileGridItem] = [
            .tile(tesseraTestTile("s0", size: .small)),
            .folder(folder),
            .tile(tesseraTestTile("s1", size: .small)),
            .tile(tesseraTestTile("m0", size: .medium)),
            .tile(tesseraTestTile("w0", size: .wide)),
            .tile(tesseraTestTile("s2", size: .small)),
            .tile(tesseraTestTile("l0", size: .large)),
            .tile(tesseraTestTile("s3", size: .small)),
        ]
        if let index = TesseraTileLayoutEngine.folderPanelInsertionIndex(
            items: items,
            columns: 4,
            expandedFolderID: folder.id
        ) {
            items.insert(.folderContent(folder), at: index)
        }
        return items
    }

    /// All frames (tiles, folder, panel) are multiples of `1 / scale` at widths
    /// 375/390/393/430 and scales 2×/3×; the grid is centered, so the margins
    /// differ by no more than a pixel.
    func testAllFramesAreOnPixelGrid() throws {
        let items = makeItems()
        XCTAssertTrue(items.contains { $0.isFolderPanel })

        for width in widths {
            for scale in scales {
                let (layout, collectionView) = makeLayout(width: width, scale: scale)
                layout.setItems(items, reason: .items)
                _ = collectionView

                var minX = CGFloat.infinity
                var maxX = -CGFloat.infinity
                for index in items.indices {
                    let frame = try XCTUnwrap(layout.frame(forItemAt: index))
                    let label = "width \(width), \(Int(scale))×, item \(index)"
                    assertOnPixelGrid(frame.minX, scale: scale, "\(label): x")
                    assertOnPixelGrid(frame.minY, scale: scale, "\(label): y")
                    assertOnPixelGrid(frame.width, scale: scale, "\(label): width")
                    assertOnPixelGrid(frame.height, scale: scale, "\(label): height")
                    if !items[index].isFolderPanel {
                        minX = min(minX, frame.minX)
                        maxX = max(maxX, frame.maxX)
                    }
                }

                // A grid with a 4×4 tile spans the full width of the units: the left and
                // right margins differ by no more than a pixel.
                let left = minX - 16
                let right = (width - 16) - maxX
                XCTAssertGreaterThanOrEqual(left, -1e-6, "width \(width), \(Int(scale))×")
                XCTAssertGreaterThanOrEqual(right, -1e-6, "width \(width), \(Int(scale))×")
                XCTAssertLessThanOrEqual(abs(left - right), 1 / scale + 1e-6, "width \(width), \(Int(scale))×")
            }
        }
    }

    /// 393 pt, 3×: the "raw" unit 84.25 becomes 84, a 1×1 tile is 84 pt, and
    /// the remainder (1 pt) is divided between the margins: 1/3 pt on the left (a pixel), 2/3 on the right.
    func testUnitIsFlooredAndRemainderSplitBetweenMargins() throws {
        let (layout, collectionView) = makeLayout(width: 393, scale: 3)
        _ = collectionView
        layout.setItems(
            (0..<4).map { .tile(tesseraTestTile("s\($0)", size: .small)) },
            reason: .items
        )

        let first = try XCTUnwrap(layout.frame(forItemAt: 0))
        let last = try XCTUnwrap(layout.frame(forItemAt: 3))
        XCTAssertEqual(first.width, 84, accuracy: 1e-9)
        XCTAssertEqual(first.minX, 16 + 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(393 - 16 - last.maxX, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(first.minY, 16, accuracy: 1e-9)
    }

    /// A zero scale means no alignment: the geometry matches the §3 formula.
    func testZeroScaleKeepsExactFormula() throws {
        let (layout, collectionView) = makeLayout(width: 393, scale: 0)
        _ = collectionView
        layout.setItems([.tile(tesseraTestTile("s", size: .small))], reason: .items)

        let frame = try XCTUnwrap(layout.frame(forItemAt: 0))
        XCTAssertEqual(frame.width, 84.25, accuracy: 1e-9)
        XCTAssertEqual(frame.minX, 16, accuracy: 1e-9)
    }
}

#endif
