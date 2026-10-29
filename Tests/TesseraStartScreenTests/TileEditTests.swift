//
//  TileEditTests.swift
//  TesseraStartScreenTests
//
//  Тесты режима редактирования (задача E4.7).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §5 «Режим редактирования»
//  (resize — циклическая смена размера small → medium → wide → large → small,
//  перетаскивание и расчёт цели drop) и §14 «Уточнения MVP» п. 4 (D15: четыре
//  размера).
//
//  Чистого публичного помощника «следующий размер» и «позиция drop» в
//  координаторе нет: resize-цикл собирается из `TileSize.allCases`, числа
//  колонок сетки и `supportedSizesProvider`, а цель drop считается по рамкам
//  `TesseraTileGridView` (приватный `isPointInDropCenter`). Поэтому resize-цикл
//  проверяется через реальный `TesseraTileEditCoordinator.cycleSize(of:)`
//  (без окна и UI-цикла), а расчёт drop — через публичную геометрию сетки,
//  которой пользуется drag-координатор.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileEditTests: XCTestCase {

    // MARK: - Вспомогательные средства

    private func makeStore(
        _ descriptors: [TileDescriptor],
        in directory: TesseraTestDirectory
    ) -> TileStore {
        let store = TileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog(descriptors)
        return store
    }

    /// Сетка, разложенная вручную: окно не нужно, коллекция получает bounds.
    private func makeGrid(store: TileStore, columns: Int = 4) -> TesseraTileGridView {
        let grid = TesseraTileGridView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        grid.columns = columns
        grid.reload(snapshot: store.snapshot())
        grid.layoutIfNeeded()
        grid.subviews
            .compactMap { $0 as? UICollectionView }
            .forEach { $0.layoutIfNeeded() }
        return grid
    }

    // MARK: - Модель размера (D15)

    /// Порядок resize-цикла задан моделью: small → medium → wide → large.
    func testTileSizeCycleOrderMatchesD15() {
        XCTAssertEqual(TileSize.allCases, [.small, .medium, .wide, .large])
        XCTAssertEqual(TileSize.small.unitSize, CGSize(width: 1, height: 1))
        XCTAssertEqual(TileSize.medium.unitSize, CGSize(width: 2, height: 2))
        XCTAssertEqual(TileSize.wide.unitSize, CGSize(width: 4, height: 2))
        XCTAssertEqual(TileSize.large.unitSize, CGSize(width: 4, height: 4))
    }

    // MARK: - Resize-цикл

    /// Координатор проходит полный цикл и возвращается к исходному размеру,
    /// меняя авторитетный размер в `TileStore` (D15, §5).
    func testCycleSizeFollowsResizeOrder() {
        let directory = TesseraTestDirectory()
        let store = makeStore([tesseraTestTile("a", size: .small)], in: directory)
        let grid = makeGrid(store: store)
        let editor = TesseraTileEditCoordinator(grid: grid, store: store)

        XCTAssertEqual(editor.cycleSize(of: "a"), .medium)
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .medium)
        XCTAssertEqual(grid.items.first { $0.id == AnyHashable("a") }?.size, .medium)

        XCTAssertEqual(editor.cycleSize(of: "a"), .wide)
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .wide)

        XCTAssertEqual(editor.cycleSize(of: "a"), .large)
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .large)

        XCTAssertEqual(editor.cycleSize(of: "a"), .small)
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .small)
        XCTAssertEqual(grid.items.first { $0.id == AnyHashable("a") }?.size, .small)
    }

    /// Неизвестный идентификатор не меняет состояние.
    func testCycleSizeRejectsUnknownItem() {
        let directory = TesseraTestDirectory()
        let store = makeStore([tesseraTestTile("a")], in: directory)
        let grid = makeGrid(store: store)
        let editor = TesseraTileEditCoordinator(grid: grid, store: store)

        XCTAssertNil(editor.cycleSize(of: "missing"))
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .medium)
    }

    /// В узкой сетке (3 колонки) wide/large недоступны: цикл идёт только между
    /// small и medium — плитка не должна вылезать за сетку (§3).
    func testCycleSizeRespectsGridColumns() {
        let directory = TesseraTestDirectory()
        let store = makeStore([tesseraTestTile("a", size: .small)], in: directory)
        let grid = makeGrid(store: store, columns: 3)
        let editor = TesseraTileEditCoordinator(grid: grid, store: store)

        XCTAssertEqual(editor.cycleSize(of: "a"), .medium)
        XCTAssertEqual(editor.cycleSize(of: "a"), .small)
        XCTAssertEqual(editor.cycleSize(of: "a"), .medium)
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .medium)
    }

    /// Хост может сузить набор размеров через `supportedSizesProvider`:
    /// цикл идёт по нему, а пустой массив означает «набор по умолчанию».
    func testCycleSizeUsesSupportedSizesProvider() {
        let directory = TesseraTestDirectory()
        let store = makeStore([tesseraTestTile("a", size: .small)], in: directory)
        let grid = makeGrid(store: store)
        let editor = TesseraTileEditCoordinator(grid: grid, store: store)

        editor.supportedSizesProvider = { _ in [.small, .large] }
        XCTAssertEqual(editor.cycleSize(of: "a"), .large)
        XCTAssertEqual(editor.cycleSize(of: "a"), .small)

        editor.supportedSizesProvider = { _ in [] }
        XCTAssertEqual(editor.cycleSize(of: "a"), .medium)
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .medium)
    }

    /// Если доступен ровно один размер, менять нечего.
    func testCycleSizeReturnsNilForSingleSupportedSize() {
        let directory = TesseraTestDirectory()
        let store = makeStore([tesseraTestTile("a", size: .medium)], in: directory)
        let grid = makeGrid(store: store)
        let editor = TesseraTileEditCoordinator(grid: grid, store: store)

        editor.supportedSizesProvider = { _ in [.medium] }
        XCTAssertNil(editor.cycleSize(of: "a"))
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .medium)
    }

    // MARK: - Reduce Motion

    /// При Reduce Motion «желе» выключено, но режим редактирования работает
    /// (§5, §9). Провайдер настройки инжектируется.
    func testReduceMotionDisablesJiggle() {
        let directory = TesseraTestDirectory()
        let store = makeStore([tesseraTestTile("a")], in: directory)
        let grid = makeGrid(store: store)
        let editor = TesseraTileEditCoordinator(grid: grid, store: store)

        editor.isReduceMotionEnabled = { true }
        editor.beginEditing()
        XCTAssertTrue(editor.isEditing)
        XCTAssertFalse(editor.isJiggling)

        editor.isReduceMotionEnabled = { false }
        XCTAssertTrue(editor.isJiggling)

        editor.endEditing()
        XCTAssertFalse(editor.isEditing)
        XCTAssertFalse(editor.isJiggling)
    }

    // MARK: - Геометрия drop

    /// Цель drop ищется по рамкам сетки: центр плитки принадлежит ей, а точка в
    /// зазоре между плитками — нет. Это те же запросы, которыми пользуется
    /// drag-координатор (`item(under:excluding:)`, `frame(forItemID:)`).
    func testDropHitTestingUsesTileFrames() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(
            [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .medium),
                tesseraTestTile("c", size: .small),
            ],
            in: directory
        )
        let grid = makeGrid(store: store)

        let frame = try XCTUnwrap(grid.frame(forItemID: "b"))
        let center = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertEqual(grid.item(at: center)?.id, AnyHashable("b"))

        // Зазор сразу справа от «b»: внешний зазор между юнитами не принадлежит
        // ни одной плите.
        let gapPoint = CGPoint(
            x: frame.maxX + grid.itemSpacing / 2,
            y: frame.midY
        )
        XCTAssertNil(grid.item(at: gapPoint))

        XCTAssertNil(grid.frame(forItemID: "missing"))
        XCTAssertNil(grid.item(at: CGPoint(x: -1000, y: -1000)))
    }

    /// Перестановка — модель drop'а: индекс зажимается, набор ярлыков не
    /// теряется и не дублируется (§5, §6).
    func testDropReorderThroughStoreKeepsItemSet() {
        let directory = TesseraTestDirectory()
        let store = makeStore(
            [
                tesseraTestTile("a"),
                tesseraTestTile("b"),
                tesseraTestTile("c"),
            ],
            in: directory
        )

        let initial = Set(store.snapshot().items.map { $0.id })
        XCTAssertTrue(store.move("a", toIndex: 2))
        XCTAssertEqual(Set(store.snapshot().items.map { $0.id }), initial)
        XCTAssertEqual(store.snapshot().items.map { $0.id }, ["b", "c", "a"])

        XCTAssertFalse(store.move("a", toIndex: 99))
        XCTAssertEqual(store.snapshot().items.map { $0.id }, ["b", "c", "a"])
        XCTAssertEqual(Set(store.snapshot().items.map { $0.id }), initial)
    }
}

#endif
