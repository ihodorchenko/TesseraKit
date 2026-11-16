//
//  TileStoreFolderMinTwoTests.swift
//  TesseraStartScreenTests
//
//  Папка не бывает из 0–1 ярлыков: модель `TesseraTileStore` (E14.8, D45, 13.11.2026).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md «Отступления реализации
//  (E14)», п. 56; решения D30–D33 и D45 в docs/STATE.md.
//
//  Правило: когда операция убирает ярлык из папки и там остаётся один, папка
//  распускается — оставшийся ярлык встаёт на ячейку папки со **своим** размером
//  через `TesseraTileLayoutEngine.inserting` (бо́льший выталкивает соседей вниз, D31,
//  слишком правая колонка сдвигается влево, меньший оставляет дыру). Правило
//  действует во всех операциях, убирающих ярлык из папки (вынос, вынос в новую
//  строку, открепление, перенос в другую папку), в чистке по каталогу и при
//  загрузке файла. Исключение — переходная папка `createFolder(withTile:)`.
//
//  Раскладки точные (`TileStoreCellFixture`), 6 колонок; одно уведомление и
//  одна запись на операцию.
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileStoreFolderMinTwoTests: XCTestCase {

    private let columns = 6

    // MARK: - Помощники

    private func makeStore(
        _ tiles: [CellFixtureTile],
        folders: [CellFixtureFolder] = [],
        unpinned: [(String, TesseraTileSize)] = [],
        in directory: TesseraTestDirectory,
        autosaves: Bool = true
    ) throws -> TesseraTileStore {
        try TileStoreCellFixture.makeStore(
            columns: columns, tiles: tiles, folders: folders, unpinned: unpinned, in: directory, autosaves: autosaves
        )
    }

    private func catalogIDs(
        _ tiles: [CellFixtureTile],
        folders: [CellFixtureFolder] = [],
        unpinned: [(String, TesseraTileSize)] = []
    ) -> [String] {
        tiles.map { $0.id } + folders.flatMap { $0.contents.map { $0.id } } + unpinned.map { $0.0 }
    }

    /// Считает уведомления `onChange`.
    private func countNotifications(_ store: TesseraTileStore) -> () -> Int {
        var count = 0
        store.onChange = { _ in count += 1 }
        return { count }
    }

    /// Файл содержит ровно ячейки модели: перечитанное хранилище совпадает.
    private func assertRoundTrip(
        _ store: TesseraTileStore,
        catalog: [String],
        in directory: TesseraTestDirectory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try store.save()
        let fresh = TesseraTileStore(directoryURL: directory.url)
        fresh.setCatalog(catalog.map { tesseraTestTile($0, size: store.descriptor(withID: $0)?.size ?? .small) })
        try fresh.load()
        XCTAssertEqual(fresh.placements, store.placements, "ячейки переживают круг записи", file: file, line: line)
        XCTAssertEqual(
            fresh.snapshot().items.map { $0.id }, store.snapshot().items.map { $0.id }, file: file, line: line
        )
        XCTAssertEqual(fresh.snapshot().folders.count, store.snapshot().folders.count, file: file, line: line)
        for item in store.snapshot().items {
            XCTAssertEqual(fresh.snapshot().item(withID: item.id)?.size, item.size, file: file, line: line)
        }
    }

    // MARK: - Вынос из папки

    /// Вынос из папки в два ярлыка: папка распускается, оставшийся ярлык встаёт на
    /// её ячейку, вынесенный — на указанную. Одно уведомление, один круг записи.
    func testExtractLeavingOneDissolvesFolder() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 4)]
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small)])]
        let store = try makeStore(tiles, folders: folders, in: directory)
        let notifications = countNotifications(store)

        XCTAssertTrue(store.extractFromFolder("x", toCell: tesseraCell(3, 3), columns: columns))

        XCTAssertEqual(notifications(), 1, "одно изменение на операцию")
        XCTAssertNil(store.placement(of: "f"))
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        XCTAssertEqual(store.placement(of: "y"), tesseraCell(0, 0), "оставшийся ярлык — на ячейке папки")
        XCTAssertEqual(store.snapshot().item(withID: "y")?.size, .small, "со своим размером")
        XCTAssertEqual(store.placement(of: "x"), tesseraCell(3, 3))
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(0, 4))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
        try assertRoundTrip(store, catalog: ["a", "x", "y"], in: directory)
    }

    /// Вынос из папки в три ярлыка: папка остаётся с двумя, ячейки не меняются.
    func testExtractLeavingTwoKeepsFolder() throws {
        let directory = TesseraTestDirectory()
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small), ("z", .small)])]
        let store = try makeStore([], folders: folders, in: directory)
        let notifications = countNotifications(store)

        XCTAssertTrue(store.extractFromFolder("x", toCell: tesseraCell(3, 3), columns: columns))

        XCTAssertEqual(notifications(), 1)
        XCTAssertEqual(store.placement(of: "f"), tesseraCell(0, 0))
        XCTAssertEqual(store.folderContaining("y")?.tiles.map { $0.id }, ["y", "z"])
        XCTAssertEqual(store.snapshot().folders.count, 1)
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs([], folders: folders))
    }

    /// Вынос в новую строку: оставшийся ярлык стоит на ячейке папки и входит в расчёт
    /// «последней занятой строки» (large после распада опускает новую строку).
    func testExtractToNewRowDissolvesAndCountsRemainingTileInNewRow() throws {
        let directory = TesseraTestDirectory()
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .large)])]
        let store = try makeStore([], folders: folders, in: directory)

        XCTAssertTrue(store.extractFromFolderToNewRow("x", columns: columns))

        XCTAssertEqual(store.placement(of: "y"), tesseraCell(0, 0))
        XCTAssertEqual(store.snapshot().item(withID: "y")?.size, .large)
        XCTAssertEqual(store.placement(of: "x"), tesseraCell(4, 0), "после large (строки 0–3)")
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs([], folders: folders))
    }

    /// Вынос на саму ячейку папки: оставшийся ярлык уже стоит там, вынесенный
    /// занимает ячейку и выталкивает его вниз (обычные правила размещения).
    func testExtractOntoFolderCellPushesRemainingTileDown() throws {
        let directory = TesseraTestDirectory()
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small)])]
        let store = try makeStore([], folders: folders, in: directory)

        XCTAssertTrue(store.extractFromFolder("x", toCell: tesseraCell(0, 0), columns: columns))

        XCTAssertEqual(store.placement(of: "x"), tesseraCell(0, 0))
        XCTAssertEqual(store.placement(of: "y"), tesseraCell(1, 0), "y вытолкнута под x")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs([], folders: folders))
    }

    /// Хост запретил вынос — модель не меняется, папка цела, уведомлений нет.
    func testDeniedExtractLeavesFolderIntact() throws {
        let directory = TesseraTestDirectory()
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small)])]
        let store = try makeStore([], folders: folders, in: directory)
        let before = store.placements
        let notifications = countNotifications(store)
        store.approval = { _, _, _ in false }

        XCTAssertFalse(store.extractFromFolder("x", toCell: tesseraCell(3, 3), columns: columns))

        XCTAssertEqual(notifications(), 0)
        XCTAssertEqual(store.placements, before)
        XCTAssertEqual(store.folderContaining("x")?.tiles.map { $0.id }, ["x", "y"])
    }

    // MARK: - Размер оставшегося ярлыка

    /// Оставшийся ярлык больше папки (large) выталкивает соседей вниз каскадом.
    func testRemainingTileBiggerThanFolderPushesNeighborsDown() throws {
        let directory = TesseraTestDirectory()
        let tiles = [
            CellFixtureTile("a", .small, 2, 0),
            CellFixtureTile("b", .small, 2, 1),
            CellFixtureTile("c", .small, 0, 4),
            CellFixtureTile("d", .small, 4, 0),
        ]
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .large)])]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertTrue(store.unpin("x", columns: columns))

        XCTAssertEqual(store.placement(of: "y"), tesseraCell(0, 0))
        XCTAssertEqual(store.snapshot().item(withID: "y")?.size, .large)
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(4, 0), "a выдавлена под large")
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(4, 1))
        XCTAssertEqual(store.placement(of: "d"), tesseraCell(5, 0), "каскад дошёл до d")
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(0, 4), "дыры вне области не тронуты")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders, unpinned: []))
    }

    /// Wide-ярлык у правого края: колонка сдвигается влево, чтобы он поместился.
    func testWideRemainingTileAtRightEdgeClampsLeft() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("n", .small, 0, 2)]
        let folders = [CellFixtureFolder("f", .medium, 0, 4, contents: [("x", .small), ("y", .wide)])]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertTrue(store.unpin("x", columns: columns))

        XCTAssertEqual(store.placement(of: "y"), tesseraCell(0, 2), "4 колонки: влево до колонки 2")
        XCTAssertEqual(store.placement(of: "n"), tesseraCell(2, 2), "n вытолкнута под wide")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
    }

    /// Large у правого края при распаде тоже ужимается холстом и не выходит за него.
    func testLargeRemainingTileAtRightEdgeStaysInsideCanvas() throws {
        let directory = TesseraTestDirectory()
        let valid = [CellFixtureFolder("f", .medium, 1, 4, contents: [("x", .small), ("y", .large)])]
        let store = try makeStore([], folders: valid, in: directory)

        XCTAssertTrue(store.extractFromFolderToNewRow("x", columns: columns))

        XCTAssertEqual(store.placement(of: "y"), tesseraCell(1, 2), "large 4×4 в 6 колонках: правый край — колонка 2")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs([], folders: valid))
    }

    /// Выбранный пользователем размер сохраняется (medium) и переживает круг записи;
    /// меньший оставшийся ярлык оставляет дыру на ячейках папки.
    func testRemainingTileKeepsCustomSizeAndLeavesHole() throws {
        let directory = TesseraTestDirectory()
        let folders = [CellFixtureFolder("f", .wide, 0, 0, contents: [("x", .small), ("y", .medium)])]
        let tiles = [CellFixtureTile("n", .small, 0, 4)]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertTrue(store.unpin("x", columns: columns))

        XCTAssertEqual(store.snapshot().item(withID: "y")?.size, .medium)
        XCTAssertEqual(store.placement(of: "y"), tesseraCell(0, 0))
        XCTAssertFalse(store.placements.values.contains(tesseraCell(0, 2)), "правая половина wide-папки — дыра")
        XCTAssertEqual(store.placement(of: "n"), tesseraCell(0, 4))
        try assertRoundTrip(store, catalog: ["n", "x", "y"], in: directory)
    }

    // MARK: - Открепление

    /// Открепление ярлыка из папки в два ярлыка: папка распускается; ярлык —
    /// среди откреплённых; из трёх — папка остаётся.
    func testUnpinInsideFolderLeavingOneDissolvesAndLeavingTwoKeeps() throws {
        let directory = TesseraTestDirectory()
        let folders = [
            CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small)]),
            CellFixtureFolder("g", .medium, 3, 0, contents: [("p", .small), ("q", .small), ("r", .small)]),
        ]
        let store = try makeStore([], folders: folders, in: directory)
        let notifications = countNotifications(store)

        XCTAssertTrue(store.unpin("x", columns: columns))
        XCTAssertEqual(notifications(), 1)
        XCTAssertNil(store.folderContaining("y"))
        XCTAssertEqual(store.placement(of: "y"), tesseraCell(0, 0))
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["x"])

        XCTAssertTrue(store.unpin("p", columns: columns))
        XCTAssertEqual(notifications(), 2)
        XCTAssertEqual(store.folderContaining("q")?.tiles.map { $0.id }, ["q", "r"])
        XCTAssertEqual(store.placement(of: "g"), tesseraCell(3, 0))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs([], folders: folders))
        try assertRoundTrip(store, catalog: ["x", "y", "p", "q", "r"], in: directory)
    }

    // MARK: - Перенос между папками

    /// Папка-источник из двух ярлыков распускается, цель получает ярлык.
    func testMoveBetweenFoldersSourceLeftWithOneDissolves() throws {
        let directory = TesseraTestDirectory()
        let folders = [
            CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("x2", .small)]),
            CellFixtureFolder("g", .medium, 0, 3, contents: [("y", .small), ("y2", .small)]),
        ]
        let store = try makeStore([], folders: folders, in: directory)
        let notifications = countNotifications(store)

        XCTAssertTrue(store.moveBetweenFolders("x", to: "g", columns: columns))

        XCTAssertEqual(notifications(), 1)
        XCTAssertNil(store.placement(of: "f"))
        XCTAssertEqual(store.placement(of: "x2"), tesseraCell(0, 0))
        XCTAssertEqual(store.folderContaining("x")?.tiles.map { $0.id }, ["y", "y2", "x"])
        XCTAssertEqual(store.placement(of: "g"), tesseraCell(0, 3))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs([], folders: folders))
    }

    /// Порядок шагов: оставшийся ярлык большого размера на месте папки-источника
    /// выталкивает папку-цель вниз, а перенесённый ярлык при этом попадает в неё.
    func testMoveBetweenFoldersRemainingLargeTilePushesTargetFolderDown() throws {
        let directory = TesseraTestDirectory()
        let folders = [
            CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("x2", .large)]),
            CellFixtureFolder("g", .medium, 2, 2, contents: [("y", .small), ("y2", .small)]),
        ]
        let store = try makeStore([], folders: folders, in: directory)

        XCTAssertTrue(store.moveBetweenFolders("x", to: "g", columns: columns))

        XCTAssertEqual(store.placement(of: "x2"), tesseraCell(0, 0))
        XCTAssertEqual(store.placement(of: "g"), tesseraCell(4, 2), "папка-цель вытолкнута под large")
        XCTAssertEqual(store.folderContaining("x")?.id, AnyHashable("g"))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs([], folders: folders))
    }

    /// Ярлык-остаток и перенесённый ярлык могут оказаться в одной папке следующим
    /// шагом: после распада остаток — обычный ярлык, и `addToFolder` его принимает.
    func testRemainingTileCanBeAddedToTargetFolderAfterDissolve() throws {
        let directory = TesseraTestDirectory()
        let folders = [
            CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("x2", .small)]),
            CellFixtureFolder("g", .medium, 0, 3, contents: [("y", .small), ("y2", .small)]),
        ]
        let store = try makeStore([], folders: folders, in: directory)

        XCTAssertTrue(store.moveBetweenFolders("x", to: "g", columns: columns))
        XCTAssertTrue(store.addToFolder("x2", folderID: "g", columns: columns))

        XCTAssertEqual(store.folderContaining("x2")?.tiles.map { $0.id }, ["y", "y2", "x", "x2"])
        XCTAssertEqual(store.snapshot().folders.count, 1)
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs([], folders: folders))
    }

    // MARK: - Чистка по каталогу

    /// Ярлык пропал из каталога: из папки в два ярлыка остаётся один — папка
    /// распускается (его ячейка — ячейка папки); из трёх — остаётся с двумя; оба
    /// пропали — папка исчезает. Одно уведомление за `setCatalog`.
    func testPruneAgainstCatalogDissolvesUnderfilledFolders() throws {
        let directory = TesseraTestDirectory()
        let folders = [
            CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .wide)]),
            CellFixtureFolder("g", .medium, 3, 0, contents: [("p", .small), ("q", .small), ("r", .small)]),
            CellFixtureFolder("h", .medium, 3, 3, contents: [("m", .small), ("n", .small)]),
        ]
        let store = try makeStore([], folders: folders, in: directory)
        let notifications = countNotifications(store)

        let all = ["x", "y", "p", "q", "r", "m", "n"]
        let remaining = all.filter { $0 != "x" && $0 != "p" && $0 != "m" && $0 != "n" }
        store.setCatalog(remaining.map { tesseraTestTile($0, size: $0 == "y" ? .wide : .small) })

        XCTAssertEqual(notifications(), 1)
        XCTAssertNil(store.folderContaining("y"), "f распущена")
        XCTAssertEqual(store.placement(of: "y"), tesseraCell(0, 0))
        XCTAssertEqual(store.snapshot().item(withID: "y")?.size, .wide, "размер оставшегося ярлыка сохранён")
        XCTAssertEqual(store.folderContaining("q")?.tiles.map { $0.id }, ["q", "r"], "g с двумя ярлыками остаётся")
        XCTAssertNil(store.placement(of: "h"), "h опустела и исчезла")
        XCTAssertEqual(store.snapshot().folders.count, 1)
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: remaining)
    }

    /// Оставшийся при чистке ярлык большого размера выталкивает соседей вниз.
    func testPruneRemainingLargeTilePushesNeighborsDown() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 2, 0)]
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .large)])]
        let store = try makeStore(tiles, folders: folders, in: directory)

        store.setCatalog(["a", "y"].map { tesseraTestTile($0, size: $0 == "y" ? .large : .small) })

        XCTAssertEqual(store.placement(of: "y"), tesseraCell(0, 0))
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(4, 0))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: ["a", "y"])
    }

    /// Папка, которой чистка не коснулась, правилом не затрагивается (переходная
    /// папка `createFolder(withTile:)` переживает повторный `setCatalog`).
    func testRepeatedSetCatalogKeepsTransientSingleTileFolder() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 1)]
        let store = try makeStore(tiles, in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", columns: columns))

        store.setCatalog(["a", "b"].map { tesseraTestTile($0, size: .small) })

        XCTAssertEqual(store.snapshot().folders.map { $0.id }, [folder.id])
        XCTAssertEqual(store.folderContaining("a")?.tiles.map { $0.id }, ["a"])
    }

    // MARK: - Загрузка файла

    /// Файл с папками из 0 и из 1 ярлыка при зарегистрированном каталоге:
    /// пустая исчезает, одноярлычная распускается — ярлык на ячейке папки.
    func testLoadRepairsZeroAndOneTileFolders() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 4)]
        let folders = [
            CellFixtureFolder("one", .medium, 0, 0, contents: [("x", .wide)]),
            CellFixtureFolder("empty", .medium, 2, 0, contents: []),
            CellFixtureFolder("ok", .medium, 4, 0, contents: [("p", .small), ("q", .small)]),
        ]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertEqual(store.snapshot().folders.map { $0.id }, ["ok"])
        XCTAssertEqual(store.placement(of: "x"), tesseraCell(0, 0), "x заняла ячейку папки со своим размером")
        XCTAssertEqual(store.snapshot().item(withID: "x")?.size, .wide)
        XCTAssertNil(store.placement(of: "empty"))
        XCTAssertEqual(store.placement(of: "ok"), tesseraCell(4, 0))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: ["a", "x", "p", "q"])
    }

    /// Файл версии 2 читается до регистрации каталога: одноярлычная папка ждёт
    /// каталога (какие ярлыки существуют, неизвестно) и после `setCatalog`
    /// распускается; если её ярлыка в каталоге нет — исчезает без «призрака».
    func testLoadBeforeCatalogDefersDissolveUntilCatalogIsKnown() throws {
        for tileInCatalog in [true, false] {
            let directory = TesseraTestDirectory()
            try directory.create()
            let json = """
            {
              "version": 2, "columns": 6,
              "items": [
                {"kind": "tile", "key": "s:a", "row": 0, "column": 4},
                {"kind": "folder", "key": "s:f", "row": 0, "column": 0}
              ],
              "sizes": {"s:a": "small", "s:x": "medium"},
              "folders": [{"key": "s:f", "title": "F", "size": "medium", "tileKeys": ["s:x"]}]
            }
            """
            let store = TesseraTileStore(directoryURL: directory.url)
            store.autosaves = false
            try Data(json.utf8).write(to: store.fileURL)
            try store.load()
            XCTAssertEqual(store.canvasColumns, 6)

            store.setCatalog((tileInCatalog ? ["a", "x"] : ["a"]).map { tesseraTestTile($0, size: .small) })

            XCTAssertTrue(store.snapshot().folders.isEmpty, "tileInCatalog=\(tileInCatalog)")
            if tileInCatalog {
                XCTAssertEqual(store.placement(of: "x"), tesseraCell(0, 0))
                XCTAssertEqual(store.snapshot().item(withID: "x")?.size, .medium)
            } else {
                XCTAssertNil(store.placement(of: "x"), "ярлыка нет в каталоге — не остаётся и невидимым ключом на сетке")
                XCTAssertEqual(store.snapshot().items.map { $0.id }, ["a"])
            }
            tesseraAssertCellInvariants(store, columns: 6, catalogIDs: tileInCatalog ? ["a", "x"] : ["a"])
        }
    }

    /// Файл версии 1 (без ячеек): одноярлычная папка заменяется ярлыком на её месте в порядке.
    func testLoadVersionOneFileReplacesOneTileFolderInPlace() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let json = """
        {
          "version": 1,
          "items": [
            {"kind": "tile", "key": "s:a"},
            {"kind": "folder", "key": "s:f"},
            {"kind": "tile", "key": "s:b"}
          ],
          "sizes": {},
          "folders": [{"key": "s:f", "title": "F", "size": "medium", "tileKeys": ["s:x"]}]
        }
        """
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        try Data(json.utf8).write(to: store.fileURL)
        store.setCatalog(["a", "b", "x"].map { tesseraTestTile($0, size: .small) })
        try store.load()

        XCTAssertEqual(store.snapshot().items.map { $0.id }, ["a", "x", "b"] as [AnyHashable])
        XCTAssertTrue(store.snapshot().folders.isEmpty)
    }

    // MARK: - Переходная папка из одного ярлыка

    /// `createFolder(withTile:)` создаёт переходную папку: она живёт до
    /// `addToFolder`; снятие её единственного ярлыка убирает папку (дыра), а не
    /// распускает в никуда.
    func testTransientSingleTileFolderLifecycle() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 3)]
        let store = try makeStore(tiles, in: directory)

        let folder = try XCTUnwrap(store.createFolder(withTile: "a", columns: columns))
        XCTAssertEqual(store.snapshot().folders.map { $0.id }, [folder.id], "переходная папка живёт")

        XCTAssertTrue(store.addToFolder("b", folderID: folder.id, columns: columns))
        XCTAssertEqual(store.folderContaining("a")?.tiles.map { $0.id }, ["a", "b"])
    }

    /// Переходная папка исчезает, когда из неё уходит единственный ярлык.
    func testTransientFolderDisappearsWhenItsTileLeaves() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 3)]
        let store = try makeStore(tiles, in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", columns: columns))

        XCTAssertTrue(store.unpin("a", columns: columns))

        XCTAssertTrue(store.snapshot().folders.isEmpty)
        XCTAssertNil(store.placement(of: folder.id))
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["a"])
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: ["a", "b"])
    }

    // MARK: - Сохранение

    /// Распад — одно сохранение: файл после операции описывает ярлык на ячейке
    /// папки и не содержит папки.
    func testDissolveIsPersistedInOneWrite() throws {
        let directory = TesseraTestDirectory()
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .medium)])]
        let store = try makeStore([], folders: folders, in: directory)

        XCTAssertTrue(store.unpin("x", columns: columns))

        let data = try Data(contentsOf: store.fileURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["key"] as? String, "s:y")
        XCTAssertEqual(items.first?["kind"] as? String, "tile")
        XCTAssertEqual(items.first?["row"] as? Int, 0)
        XCTAssertEqual(items.first?["column"] as? Int, 0)
        XCTAssertEqual((object["folders"] as? [Any])?.count, 0)
        XCTAssertEqual((object["sizes"] as? [String: String])?["s:y"], "medium")
    }

    // MARK: - Свойство: после любых операций и чистки каталога папок меньше двух нет

    /// Случайные папки (2–4 ярлыка) и случайные подмножества каталога: после
    /// `setCatalog` ни одной папки из 0–1 ярлыка, ярлыки не теряются, пересечений нет.
    func testRandomCatalogPruneNeverLeavesUnderfilledFolders() throws {
        for seed in 1...24 {
            var rng = TesseraTestSeededGenerator(seed: UInt64(seed))
            let directory = TesseraTestDirectory()
            let sizes: [TesseraTileSize] = [.small, .medium, .wide, .large]

            var folders: [CellFixtureFolder] = []
            var all: [String] = []
            let rows = [0, 4, 8]
            for index in 0..<3 {
                let count = 2 + rng.int(upperBound: 3)
                let ids = (0..<count).map { "f\(index)t\($0)" }
                all += ids
                folders.append(CellFixtureFolder(
                    "F\(index)", .medium, rows[index], 0,
                    contents: ids.map { ($0, sizes[rng.int(upperBound: 4)]) }
                ))
            }
            let store = try makeStore([], folders: folders, in: directory)

            let kept = all.filter { _ in rng.int(upperBound: 3) != 0 }
            var sizeByID: [String: TesseraTileSize] = [:]
            for folder in folders { for content in folder.contents { sizeByID[content.id] = content.size } }
            store.setCatalog(kept.map { tesseraTestTile($0, size: sizeByID[$0] ?? .small) })

            for folder in store.snapshot().folders {
                XCTAssertGreaterThanOrEqual(folder.tiles.count, 2, "seed \(seed)")
            }
            tesseraAssertCellInvariants(store, columns: columns, catalogIDs: kept, checkOrder: false)
        }
    }
}

#endif
