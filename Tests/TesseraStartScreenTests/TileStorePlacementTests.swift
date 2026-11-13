//
//  TileStorePlacementTests.swift
//  TesseraStartScreenTests
//
//  Тесты модели с явными ячейками и схемы `tiles.json` версии 2 (E14.1).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка»
//  (персистентность TileStore) и «Отступления реализации»; решения D30–D33 в
//  docs/STATE.md; план — docs/PLAN.md, эпик E14.
//
//  Проверяются:
//  - миграция v1 → v2: ленивая, однократная, ячейки равны `packCompact` по
//    старому порядку; файл не затирается до `load()`;
//  - круг записи/чтения v2, раскладка первого запуска, новая строка для
//    новых ключей, возврат/перенос невидимых ключей;
//  - проекция под другую ширину (D32): без перезаписи файла, возврат к
//    прежней ширине возвращает дыры, первая правка принимает новый холст;
//  - починка нарушителей на загрузке (пересечения, границы, мусор),
//    частичный набор ячеек, версия новее поддерживаемой;
//  - папки имеют ячейки, содержимое папок — нет.
//
//  Переходное правило E14.1 («ячейки после операции равны упаковке порядка»)
//  удалено в E14.6 вместе с индексным API: дыры после операций проверяют
//  `TileStoreCellOperationsTests`.
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileStorePlacementTests: XCTestCase {

    // MARK: - Вспомогательные средства

    private func descriptors() -> [TileDescriptor] {
        [
            tesseraTestTile("a", size: .small),
            tesseraTestTile("b", size: .medium),
            tesseraTestTile("c", size: .medium),
            tesseraTestTile("d", size: .small),
        ]
    }

    private func makeStore(
        _ catalog: [TileDescriptor],
        in directory: TesseraTestDirectory,
        autosaves: Bool = true
    ) -> TileStore {
        let store = TileStore(directoryURL: directory.url)
        store.autosaves = autosaves
        store.setCatalog(catalog)
        return store
    }

    private func write(_ json: String, to store: TileStore, directory: TesseraTestDirectory) throws {
        try directory.create()
        try Data(json.utf8).write(to: store.fileURL)
    }

    /// Ожидаемые ячейки: прежний `packCompact` по порядку снимка.
    private func packedExpectation(
        _ store: TileStore,
        columns: Int
    ) -> [AnyHashable: TileGridPlacement] {
        let items = store.snapshot().layoutItems.map {
            (id: $0.id, size: TileLayoutEngine.fittingSize($0.size, columns: columns))
        }
        var result: [AnyHashable: TileGridPlacement] = [:]
        for slot in TileLayoutEngine.packCompact(items: items, columns: columns, unit: 1) {
            result[slot.id] = TileGridPlacement(row: slot.row, column: slot.column)
        }
        return result
    }

    private func jsonObject(_ store: TileStore) throws -> [String: Any] {
        let data = try Data(contentsOf: store.fileURL)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func fileItems(_ store: TileStore) throws -> [[String: Any]] {
        try XCTUnwrap(try jsonObject(store)["items"] as? [[String: Any]])
    }

    /// Нет пересечений видимых элементов и все прямоугольники внутри холста.
    private func assertNoOverlapsAndInBounds(
        _ store: TileStore,
        columns: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let cells = store.placements
        let sizes = Dictionary(uniqueKeysWithValues: store.snapshot().items.map { ($0.id, $0.size) })
        var rects: [(id: AnyHashable, rect: CGRect)] = []
        for (id, cell) in cells {
            let size = TileLayoutEngine.fittingSize(sizes[id] ?? .medium, columns: columns)
            let rect = CGRect(x: cell.column, y: cell.row, width: size.unitColumns, height: size.unitRows)
            XCTAssertGreaterThanOrEqual(cell.row, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(cell.column, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(rect.maxX, CGFloat(columns), file: file, line: line)
            rects.append((id, rect))
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                XCTAssertFalse(
                    rects[i].rect.intersects(rects[j].rect),
                    "\(rects[i].id) пересекает \(rects[j].id)",
                    file: file,
                    line: line
                )
            }
        }
        XCTAssertEqual(Set(cells.keys), Set(store.snapshot().items.map { $0.id }), file: file, line: line)
    }

    private let v1Json = """
    {
      "version": 1,
      "items": [
        {"kind": "tile", "key": "s:a"},
        {"kind": "tile", "key": "s:b"},
        {"kind": "tile", "key": "s:c"},
        {"kind": "tile", "key": "s:d"}
      ],
      "sizes": {"s:a": "small", "s:b": "medium", "s:c": "medium", "s:d": "small"},
      "folders": []
    }
    """

    // MARK: - Миграция v1 → v2

    /// Файл версии 1 мигрирует лениво: `load()` ячеек не даёт, первый вызов с
    /// шириной назначает их прежним `packCompact` и сразу пишет версию 2.
    func testV1MigratesLazilyOnceAndPersists() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(descriptors(), in: directory)
        try write(v1Json, to: store, directory: directory)
        let originalData = try Data(contentsOf: store.fileURL)

        try store.load()
        XCTAssertNil(store.canvasColumns)
        XCTAssertTrue(store.placements.isEmpty)
        XCTAssertNil(store.placement(of: "a"))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalData, "load() файл не переписывает")

        XCTAssertTrue(store.placeItems(columns: 6))
        XCTAssertEqual(store.canvasColumns, 6)
        XCTAssertEqual(store.placements, packedExpectation(store, columns: 6))
        XCTAssertEqual(store.placement(of: "a"), TileGridPlacement(row: 0, column: 0))

        // Записано сразу: версия 2, ширина холста, ячейки у каждого элемента.
        let object = try jsonObject(store)
        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertEqual(object["columns"] as? Int, 6)
        let items = try fileItems(store)
        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(items.allSatisfy { $0["row"] is Int && $0["column"] is Int })
        let migratedData = try Data(contentsOf: store.fileURL)

        // Однократно: повторный вызов и другая ширина файл не трогают.
        XCTAssertFalse(store.placeItems(columns: 6))
        XCTAssertFalse(store.placeItems(columns: 4))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), migratedData)
        XCTAssertEqual(store.canvasColumns, 6)

        let reloaded = makeStore(descriptors(), in: directory)
        try reloaded.load()
        XCTAssertEqual(reloaded.canvasColumns, 6)
        XCTAssertEqual(reloaded.placements, store.placements)
    }

    /// Если ширина известна до `load()`, миграция выполняется в конце `load()`.
    func testV1MigratesAtLoadWhenWidthAlreadyKnown() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(descriptors(), in: directory)
        try write(v1Json, to: store, directory: directory)
        let originalData = try Data(contentsOf: store.fileURL)

        // До load() в хранилище только посев каталога: файл v1 затирать нельзя.
        XCTAssertTrue(store.placeItems(columns: 4))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalData)

        try store.load()
        XCTAssertEqual(store.canvasColumns, 4)
        XCTAssertEqual(store.placements, packedExpectation(store, columns: 4))
        XCTAssertNotEqual(try Data(contentsOf: store.fileURL), originalData)
        XCTAssertEqual(try jsonObject(store)["version"] as? Int, 2)
    }

    /// Миграция ждёт каталог: невидимые ярлыки не должны занять холст.
    func testMigrationWaitsForCatalog() throws {
        let directory = TesseraTestDirectory()
        let store = TileStore(directoryURL: directory.url)
        try write(v1Json, to: store, directory: directory)
        try store.load()

        XCTAssertFalse(store.placeItems(columns: 6), "каталога ещё нет")
        XCTAssertNil(store.canvasColumns)

        store.setCatalog(descriptors())
        XCTAssertTrue(store.placeItems(columns: 6))
        XCTAssertEqual(store.placements, packedExpectation(store, columns: 6))
    }

    /// Невидимые ярлыки файла v1 получают ячейки в строках после видимых и не
    /// сдвигают видимых.
    func testV1InvisibleKeysGoBelowVisible() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore([tesseraTestTile("a", size: .small), tesseraTestTile("b", size: .medium)], in: directory)
        try write(v1Json, to: store, directory: directory)
        try store.load()
        store.placeItems(columns: 6)

        XCTAssertEqual(store.placements, packedExpectation(store, columns: 6))
        let items = try fileItems(store)
        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(items.allSatisfy { $0["row"] is Int }, "у невидимых тоже есть ячейки")

        // Вернувшийся невидимый ярлык «c» — на своём месте, оно свободно.
        store.setCatalog(descriptors())
        let c = try XCTUnwrap(store.placement(of: "c"))
        XCTAssertGreaterThanOrEqual(c.row, 2)
        assertNoOverlapsAndInBounds(store, columns: 6)
    }

    // MARK: - Круг v2, первый запуск, новые ключи

    func testSeedIsPackedWhenWidthKnown() {
        let directory = TesseraTestDirectory()
        let store = makeStore(descriptors(), in: directory)

        XCTAssertNil(store.canvasColumns, "до ширины ячеек нет")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))

        XCTAssertTrue(store.placeItems(columns: 6))
        XCTAssertEqual(store.placements, packedExpectation(store, columns: 6))
        XCTAssertEqual(store.placement(of: "a"), TileGridPlacement(row: 0, column: 0))
        XCTAssertEqual(store.placement(of: "b"), TileGridPlacement(row: 0, column: 1))
        XCTAssertEqual(store.placement(of: "d"), TileGridPlacement(row: 0, column: 5))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testPlaceItemsOnEmptyStoreWritesNothing() {
        let directory = TesseraTestDirectory()
        let store = TileStore(directoryURL: directory.url)
        XCTAssertFalse(store.placeItems(columns: 6))
        XCTAssertFalse(store.placeItems(columns: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// Круг v2: запись → чтение дают те же ячейки, порядок и ширину холста;
    /// ключи JSON отсортированы.
    func testRoundTripOfSchemaV2() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(descriptors(), in: directory)
        store.placeItems(columns: 6)
        XCTAssertTrue(store.resize("a", to: .wide, columns: 6))
        try store.save()

        let reloaded = makeStore(descriptors(), in: directory)
        try reloaded.load()
        XCTAssertEqual(reloaded.canvasColumns, 6)
        XCTAssertEqual(reloaded.placements, store.placements)
        XCTAssertEqual(reloaded.snapshot().items.map { $0.id }, store.snapshot().items.map { $0.id })

        let text = String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
        let columnsRange = try XCTUnwrap(text.range(of: "\"columns\""))
        let itemsRange = try XCTUnwrap(text.range(of: "\"items\""))
        let versionRange = try XCTUnwrap(text.range(of: "\"version\""))
        XCTAssertLessThan(columnsRange.lowerBound, itemsRange.lowerBound)
        XCTAssertLessThan(itemsRange.lowerBound, versionRange.lowerBound)
    }

    /// Новый ключ каталога после появления ячеек — в новую строку в конце.
    func testNewCatalogKeyGoesToNewRowAtEnd() {
        let directory = TesseraTestDirectory()
        let store = makeStore(descriptors(), in: directory)
        store.placeItems(columns: 6)
        let before = store.placements

        store.setCatalog(descriptors() + [tesseraTestTile("e", size: .wide)])
        // Занято строками 0–1 (две средние): новая строка — 2.
        XCTAssertEqual(store.placement(of: "e"), TileGridPlacement(row: 2, column: 0))
        for (id, cell) in before {
            XCTAssertEqual(store.placement(of: id), cell, "прежние ячейки не двигаются")
        }

        store.setCatalog(descriptors() + [
            tesseraTestTile("e", size: .wide),
            tesseraTestTile("f", size: .small),
        ])
        XCTAssertEqual(store.placement(of: "f"), TileGridPlacement(row: 4, column: 0))
        assertNoOverlapsAndInBounds(store, columns: 6)
    }

    // MARK: - Невидимые ключи

    private func storeWithInvisibleD(_ directory: TesseraTestDirectory) throws -> TileStore {
        let first = makeStore(descriptors(), in: directory)
        first.placeItems(columns: 6)
        try first.save()

        let store = makeStore(Array(descriptors().prefix(3)), in: directory)
        try store.load()
        return store
    }

    /// Невидимый ярлык хранит ячейку; вернувшись на свободное место, встаёт на него.
    func testInvisibleKeyReturnsToFreeCell() throws {
        let directory = TesseraTestDirectory()
        let store = try storeWithInvisibleD(directory)
        XCTAssertNil(store.placement(of: "d"), "невидимых нет в видимых ячейках")
        XCTAssertEqual(store.placements.count, 3)

        XCTAssertTrue(store.unpin("a", columns: 6))
        XCTAssertTrue(try fileItems(store).contains { ($0["key"] as? String) == "s:d" && $0["row"] is Int },
                      "ячейка невидимого сохранена в файле")

        store.setCatalog(descriptors())
        XCTAssertEqual(store.placement(of: "d"), TileGridPlacement(row: 0, column: 5))
        assertNoOverlapsAndInBounds(store, columns: 6)
    }

    /// Если место занято видимым элементом, вернувшийся ключ — в новую строку.
    func testInvisibleKeyRelocatesWhenCellIsTaken() throws {
        let directory = TesseraTestDirectory()
        let store = try storeWithInvisibleD(directory)

        // «c» (2×2) переносится на колонку 5 и ограничивается холстом до колонки 4:
        // занимает колонки 4–5 строк 0–1, то есть ячейку (0, 5) невидимого «d».
        XCTAssertTrue(store.moveItem("c", toCell: TileGridPlacement(row: 0, column: 5), columns: 6))
        XCTAssertEqual(store.placement(of: "c"), TileGridPlacement(row: 0, column: 4))

        store.setCatalog(descriptors())
        let d = try XCTUnwrap(store.placement(of: "d"))
        XCTAssertEqual(d, TileGridPlacement(row: 2, column: 0), "строка после последней занятой")
        assertNoOverlapsAndInBounds(store, columns: 6)
    }

    // MARK: - Другая ширина (D32)

    /// Файл с дырами на холсте 6.
    private let holesJson = """
    {
      "version": 2,
      "columns": 6,
      "items": [
        {"kind": "tile", "key": "s:a", "row": 0, "column": 0},
        {"kind": "tile", "key": "s:b", "row": 2, "column": 3},
        {"kind": "tile", "key": "s:c", "row": 4, "column": 1}
      ],
      "sizes": {"s:a": "small", "s:b": "small", "s:c": "medium"},
      "folders": []
    }
    """

    private func holesStore(_ directory: TesseraTestDirectory) throws -> TileStore {
        let store = makeStore(
            [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .medium),
            ],
            in: directory
        )
        try write(holesJson, to: store, directory: directory)
        try store.load()
        return store
    }

    func testProjectionForOtherWidthDoesNotRewriteFileAndRestoresHoles() throws {
        let directory = TesseraTestDirectory()
        let store = try holesStore(directory)
        let originalData = try Data(contentsOf: store.fileURL)

        // Дыры сохранены для ширины холста.
        let stored = store.placements(forColumns: 6)
        XCTAssertEqual(stored["b"], TileGridPlacement(row: 2, column: 3))
        XCTAssertEqual(stored["c"], TileGridPlacement(row: 4, column: 1))
        XCTAssertEqual(stored, store.placements)

        // Ширина 4: репак по порядку чтения без дыр.
        let projected = store.placements(forColumns: 4)
        XCTAssertEqual(projected["a"], TileGridPlacement(row: 0, column: 0))
        XCTAssertEqual(projected["b"], TileGridPlacement(row: 0, column: 1))
        XCTAssertEqual(projected["c"], TileGridPlacement(row: 0, column: 2))
        XCTAssertEqual(store.placementReadingOrder(forColumns: 4), ["a", "b", "c"])

        // Хост сообщил ширину 4 — файл не тронут, холст прежний.
        XCTAssertFalse(store.placeItems(columns: 4))
        XCTAssertEqual(store.canvasColumns, 6)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalData)

        // Возврат к прежней ширине без правок возвращает дыры.
        XCTAssertEqual(store.placements(forColumns: 6), stored)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalData)
    }

    func testFirstMutationInMismatchedWidthAdoptsNewCanvas() throws {
        let directory = TesseraTestDirectory()
        let store = try holesStore(directory)
        store.placeItems(columns: 4)
        let originalData = try Data(contentsOf: store.fileURL)

        XCTAssertTrue(store.resize("b", to: .medium, columns: 4))
        XCTAssertEqual(store.canvasColumns, 4)
        XCTAssertNotEqual(try Data(contentsOf: store.fileURL), originalData)
        XCTAssertEqual(try jsonObject(store)["columns"] as? Int, 4)
        // Проекция: a (0,0), b (0,1), c (0,2); рост «b» до 2×2 на месте накрывает
        // «c», и она выталкивается вниз (D31).
        XCTAssertEqual(store.placement(of: "a"), TileGridPlacement(row: 0, column: 0))
        XCTAssertEqual(store.placement(of: "b"), TileGridPlacement(row: 0, column: 1))
        XCTAssertEqual(store.placement(of: "c"), TileGridPlacement(row: 2, column: 2))
        assertNoOverlapsAndInBounds(store, columns: 4)

        // Теперь проекция нужна для 6, а прежние дыры потеряны.
        XCTAssertNotEqual(store.placements(forColumns: 6)["c"], TileGridPlacement(row: 4, column: 1))
    }

    /// Без ячеек проекция — упаковка текущего порядка.
    func testProjectionWithoutPlacementsPacksCurrentOrder() {
        let directory = TesseraTestDirectory()
        let store = makeStore(descriptors(), in: directory)
        XCTAssertEqual(store.placements(forColumns: 6), packedExpectation(store, columns: 6))
        XCTAssertEqual(store.placements(forColumns: 4), packedExpectation(store, columns: 4))
        XCTAssertNil(store.canvasColumns)
        XCTAssertTrue(store.placements(forColumns: 0).isEmpty)
    }

    // MARK: - Починка файла

    /// Пересечения, выход за границы и отрицательные ячейки — нарушители уходят
    /// в новые строки в конце; устоявшиеся элементы остаются на местах.
    func testLoadRepairsOverlapsAndOutOfBounds() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(descriptors(), in: directory, autosaves: false)
        let json = """
        {
          "version": 2,
          "columns": 6,
          "items": [
            {"kind": "tile", "key": "s:a", "row": 0, "column": 0},
            {"kind": "tile", "key": "s:b", "row": 0, "column": 0},
            {"kind": "tile", "key": "s:c", "row": 0, "column": 5},
            {"kind": "tile", "key": "s:d", "row": -1, "column": 2}
          ],
          "sizes": {"s:a": "small", "s:b": "medium", "s:c": "medium", "s:d": "small"},
          "folders": []
        }
        """
        try write(json, to: store, directory: directory)
        try store.load()

        XCTAssertEqual(store.canvasColumns, 6)
        XCTAssertEqual(store.placement(of: "a"), TileGridPlacement(row: 0, column: 0))
        assertNoOverlapsAndInBounds(store, columns: 6)
        // Нарушители — ниже занятого a (одна строка), в порядке сетки.
        for id in ["b", "c", "d"] {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(store.placement(of: id)).row, 1)
        }
        XCTAssertEqual(store.placement(of: "b"), TileGridPlacement(row: 1, column: 0))
    }

    /// Нет ширины холста либо частичный набор ячеек — файл читается как
    /// нераскладочный, а не отвергается.
    func testCorruptedOrPartialPlacementsFallBackToUnplaced() throws {
        let directory = TesseraTestDirectory()
        let partial = """
        {
          "version": 2,
          "columns": 6,
          "items": [
            {"kind": "tile", "key": "s:a", "row": 0, "column": 0},
            {"kind": "tile", "key": "s:b"},
            {"kind": "tile", "key": "s:c", "row": 3, "column": 3},
            {"kind": "tile", "key": "s:d", "row": 5, "column": 1}
          ],
          "sizes": {"s:a": "small", "s:b": "medium", "s:c": "medium", "s:d": "small"},
          "folders": []
        }
        """
        let noWidth = partial.replacingOccurrences(of: "\"columns\": 6,", with: "")
        for json in [partial, noWidth] {
            let store = makeStore(descriptors(), in: directory, autosaves: false)
            try write(json, to: store, directory: directory)
            XCTAssertNoThrow(try store.load())
            XCTAssertNil(store.canvasColumns)
            XCTAssertEqual(store.snapshot().items.map { $0.id }, ["a", "b", "c", "d"])

            XCTAssertTrue(store.placeItems(columns: 6))
            XCTAssertEqual(store.placements, packedExpectation(store, columns: 6))
        }
    }

    /// Версия новее поддерживаемой: резервная копия, состояние не тронуто.
    func testFutureVersionKeepsStateUntouched() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(descriptors(), in: directory)
        store.placeItems(columns: 6)
        let placements = store.placements
        let future = Data(#"{"version":3,"columns":6,"items":[],"sizes":{},"folders":[]}"#.utf8)
        try future.write(to: store.fileURL)

        XCTAssertThrowsError(try store.load()) { error in
            guard case TileStoreError.unsupportedSchemaVersion(let version)? = error as? TileStoreError else {
                return XCTFail("Ожидалась unsupportedSchemaVersion: \(error)")
            }
            XCTAssertEqual(version, 3)
        }
        XCTAssertEqual(store.placements, placements)
        XCTAssertEqual(store.canvasColumns, 6)
        XCTAssertNotNil(store.lastUnreadableFileBackupURL)
    }

    // MARK: - Папки

    func testFoldersKeepPlacementsAndContentsHaveNone() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(descriptors(), in: directory)
        store.placeItems(columns: 6)

        let folder = try XCTUnwrap(store.createFolder(withTile: "b", columns: 6))
        XCTAssertTrue(store.addToFolder("c", folderID: folder.id, columns: 6))

        XCTAssertNotNil(store.placement(of: folder.id))
        XCTAssertNil(store.placement(of: "b"))
        XCTAssertNil(store.placement(of: "c"))
        XCTAssertEqual(store.placements.count, 3)
        // Папка встала на ячейку «b»; ячейка «c» осталась дырой (без репака).
        XCTAssertEqual(store.placement(of: folder.id), TileGridPlacement(row: 0, column: 1))
        XCTAssertEqual(store.placement(of: "d"), TileGridPlacement(row: 0, column: 5))

        let items = try fileItems(store)
        let folderItem = try XCTUnwrap(items.first { ($0["kind"] as? String) == "folder" })
        XCTAssertNotNil(folderItem["row"] as? Int)
        XCTAssertNotNil(folderItem["column"] as? Int)
        XCTAssertFalse(items.contains { ($0["key"] as? String) == "s:b" })

        let reloaded = makeStore(descriptors(), in: directory)
        try reloaded.load()
        XCTAssertEqual(reloaded.placements, store.placements)
        XCTAssertEqual(reloaded.placement(of: folder.id), store.placement(of: folder.id))
    }
}

#endif
