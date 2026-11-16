//
//  DefaultColumnsTests.swift
//  TesseraStartScreenTests
//
//  Тесты числа колонок по умолчанию (E13, D26): 6 малых колонок, как в
//  Windows 10 Mobile (docs/W10M-STARTSCREEN.md §2) — три средние плитки в ряд,
//  широкая — 4 колонки из 6. Значение одно на сетку, раскладку и хранилище;
//  хост может задать своё `columns`.
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class DefaultColumnsTests: XCTestCase {

    /// Умолчание одно: движок, раскладка, сетка и хранилище берут его из
    /// ``TesseraTileLayoutEngine/defaultColumns``.
    func testDefaultColumnsIsSixEverywhere() {
        XCTAssertEqual(TesseraTileLayoutEngine.defaultColumns, 6)
        XCTAssertEqual(TesseraTileStore.defaultGridColumns, 6)
        XCTAssertEqual(TesseraTileCollectionViewLayout().columns, 6)
        XCTAssertEqual(TesseraTileGridView(frame: .zero).columns, 6)
    }

    /// Хост по-прежнему может задать своё число колонок.
    func testHostCanOverrideColumns() {
        let grid = TesseraTileGridView(frame: .zero)
        grid.columns = 4
        XCTAssertEqual(grid.columns, 4)
    }

    /// На сетке по умолчанию три средние плитки встают в один ряд, широкая —
    /// на 4 колонки из 6, а юнит равен `(ширина − поля − 5 × зазор) / 6`.
    func testGridWithDefaultColumnsPacksThreeMediumsPerRow() throws {
        let items: [TesseraTileGridItem] = [
            .tile(tesseraTestTile("m0", size: .medium)),
            .tile(tesseraTestTile("m1", size: .medium)),
            .tile(tesseraTestTile("m2", size: .medium)),
            .tile(tesseraTestTile("w0", size: .wide)),
        ]
        let host = TesseraTestWindowedGrid(items: items, columns: TesseraTileLayoutEngine.defaultColumns)
        let grid = host.grid
        XCTAssertEqual(grid.columns, 6)

        let frames = try ["m0", "m1", "m2", "w0"].map { id in
            try XCTUnwrap(grid.frame(forItemID: id), "Нет рамки \(id)")
        }

        let unit = TesseraTileLayoutEngine.unit(
            screenWidth: grid.bounds.width - 32,
            columns: 6,
            gaps: grid.itemSpacing
        )
        let spacing = grid.itemSpacing
        XCTAssertEqual(frames[0].width, unit * 2 + spacing, accuracy: 1.0)
        XCTAssertEqual(frames[0].minY, frames[1].minY, accuracy: 0.001)
        XCTAssertEqual(frames[1].minY, frames[2].minY, accuracy: 0.001)
        XCTAssertLessThan(frames[0].maxX, frames[1].minX)
        XCTAssertLessThan(frames[1].maxX, frames[2].minX)
        // Широкая плитка — на следующем ряду, шириной в 4 колонки.
        XCTAssertGreaterThan(frames[3].minY, frames[0].maxY)
        XCTAssertEqual(frames[3].width, unit * 4 + spacing * 3, accuracy: 1.0)
        XCTAssertLessThan(frames[3].width, grid.bounds.width - 32)
    }

    /// Пока хост не назвал ширину сетки, хранилище считает по умолчанию 6 колонок
    /// (`effectiveColumns`); названная ширина её заменяет. Прежний
    /// `resize(_:to:)` без `columns` удалён в E14.6 — ширина передаётся явно.
    func testStoreEffectiveColumnsDefaultsToSix() {
        let directory = TesseraTestDirectory()
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog([tesseraTestTile("a", size: .medium)])

        XCTAssertEqual(store.effectiveColumns, 6)
        store.placeItems(columns: 4)
        XCTAssertEqual(store.effectiveColumns, 4)
    }
}

#endif
