//
//  TileGridPixelAlignmentTests.swift
//  TesseraStartScreenTests
//
//  Пиксельное выравнивание сетки рабочего стола (E10.1).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Модель раскладки»
//  (формула юнита), «Отступления реализации» (пиксельное выравнивание).
//
//  Формула §3 даёт дробный юнит: при ширине 393 pt (контент 361, зазор 8)
//  юнит 84.25 pt — края плиток попадают между пикселями. Раскладка округляет
//  юнит вниз до пикселя (`1 / displayScale`), а остаток ширины делит поровну
//  на поля. Проверяется настоящая раскладка с подменой масштаба: все рамки —
//  плитки, папка и панель раскрытой папки — кратны `1 / scale`.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileGridPixelAlignmentTests: XCTestCase {

    /// Ширины экранов iPhone (SE/mini, 13/14, 15/16 Pro, Pro Max).
    private let widths: [CGFloat] = [375, 390, 393, 430]

    /// Масштабы экрана.
    private let scales: [CGFloat] = [2, 3]

    /// Проверяет, что значение кратно `1 / scale`.
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

    /// Раскладка на коллекции без окна с подменённым масштабом.
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

    /// Набор с раскрытой папкой и плитками всех размеров.
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

    /// Все рамки (плитки, папка, панель) кратны `1 / scale` на ширинах
    /// 375/390/393/430 и масштабах 2×/3×; сетка центрирована — поля
    /// различаются не больше чем на пиксель.
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
                    let label = "ширина \(width), \(Int(scale))×, элемент \(index)"
                    assertOnPixelGrid(frame.minX, scale: scale, "\(label): x")
                    assertOnPixelGrid(frame.minY, scale: scale, "\(label): y")
                    assertOnPixelGrid(frame.width, scale: scale, "\(label): ширина")
                    assertOnPixelGrid(frame.height, scale: scale, "\(label): высота")
                    if !items[index].isFolderPanel {
                        minX = min(minX, frame.minX)
                        maxX = max(maxX, frame.maxX)
                    }
                }

                // Сетка с плиткой 4×4 занимает всю ширину юнитов: поля слева и
                // справа отличаются не больше чем на пиксель.
                let left = minX - 16
                let right = (width - 16) - maxX
                XCTAssertGreaterThanOrEqual(left, -1e-6, "ширина \(width), \(Int(scale))×")
                XCTAssertGreaterThanOrEqual(right, -1e-6, "ширина \(width), \(Int(scale))×")
                XCTAssertLessThanOrEqual(abs(left - right), 1 / scale + 1e-6, "ширина \(width), \(Int(scale))×")
            }
        }
    }

    /// 393 pt, 3×: «сырой» юнит 84.25 становится 84, плитка 1×1 — 84 pt, а
    /// остаток (1 pt) делится на поля: слева 1/3 pt (пиксель), справа 2/3.
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

    /// Нулевой масштаб — выравнивания нет: геометрия совпадает с формулой §3.
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
