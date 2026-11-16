//
//  TileStoreCellOperationsTests.swift
//  TesseraStartScreenTests
//
//  Операции `TileStore` по ячейкам (E14.4): перенос, resize на месте, папки,
//  открепление/закрепление, схлопывание пустых строк.
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 и «Отступления
//  реализации (E14)»; решения D20, D30–D33 в docs/STATE.md; план — E14.4.
//
//  Проверяются: дыры остаются (репака нет), выталкивание вниз каскадом,
//  папка 2×2 на месте малой цели и сдвиг колонки влево, вынос на ячейку и в
//  новую строку, исчезновение опустевшей папки с дырой, resize на месте,
//  закрепление в новую строку, схлопывание только непокрытых строк (и
//  идемпотентность), одно уведомление на операцию, no-op на неверный ввод,
//  согласованность модели (`tesseraAssertCellInvariants`). Имена после E14.6:
//  `resize(_:to:columns:)` и `pinTile(_:columns:)` (были `resizeInPlace`,
//  `pinTileToNewRow`).
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileStoreCellOperationsTests: XCTestCase {

    private let columns = 6

    private func makeStore(
        _ tiles: [CellFixtureTile],
        folders: [CellFixtureFolder] = [],
        unpinned: [(String, TileSize)] = [],
        in directory: TesseraTestDirectory,
        columns: Int = 6
    ) throws -> TileStore {
        try TileStoreCellFixture.makeStore(
            columns: columns, tiles: tiles, folders: folders, unpinned: unpinned, in: directory
        )
    }

    private func catalogIDs(
        _ tiles: [CellFixtureTile],
        folders: [CellFixtureFolder] = [],
        unpinned: [(String, TileSize)] = []
    ) -> [String] {
        tiles.map { $0.id } + folders.flatMap { $0.contents.map { $0.id } } + unpinned.map { $0.0 }
    }

    // MARK: - Перенос

    /// Перенос на свободную ячейку: дыра остаётся, остальные не двигаются.
    func testMoveItemToFreeCellLeavesHole() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 1), CellFixtureTile("c", .small, 0, 2)]
        let store = try makeStore(tiles, in: directory)

        XCTAssertTrue(store.moveItem("a", toCell: tesseraCell(3, 4), columns: columns))

        XCTAssertEqual(store.placement(of: "a"), tesseraCell(3, 4))
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(0, 1))
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(0, 2))
        XCTAssertNil(store.placements.values.first { $0 == tesseraCell(0, 0) }, "ячейка (0, 0) — дыра")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
        XCTAssertEqual(tesseraTestIDs(store.snapshot().items), ["b", "c", "a"])
    }

    /// Каскад: вставка выталкивает вниз цепочку, остальное не трогает.
    func testMoveItemPushesDownCascade() throws {
        let directory = TesseraTestDirectory()
        let tiles = [
            CellFixtureTile("A", .medium, 0, 0),
            CellFixtureTile("B", .small, 2, 0),
            CellFixtureTile("C", .small, 3, 0),
            CellFixtureTile("D", .small, 0, 3),
            CellFixtureTile("X", .small, 0, 4),
        ]
        let store = try makeStore(tiles, in: directory)

        XCTAssertTrue(store.moveItem("X", toCell: tesseraCell(0, 0), columns: columns))

        XCTAssertEqual(store.placement(of: "X"), tesseraCell(0, 0))
        XCTAssertEqual(store.placement(of: "A"), tesseraCell(1, 0))
        XCTAssertEqual(store.placement(of: "B"), tesseraCell(3, 0))
        XCTAssertEqual(store.placement(of: "C"), tesseraCell(4, 0))
        XCTAssertEqual(store.placement(of: "D"), tesseraCell(0, 3), "вне затронутой области — на месте")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// Слишком правая ячейка сдвигается влево; перенос на свою ячейку — no-op.
    func testMoveItemClampsLeftAndSameCellIsNoOp() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("w", .wide, 0, 0), CellFixtureTile("s", .small, 2, 0)]
        let store = try makeStore(tiles, in: directory)
        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        XCTAssertTrue(store.moveItem("w", toCell: tesseraCell(4, 5), columns: columns))
        XCTAssertEqual(store.placement(of: "w"), tesseraCell(4, 2), "wide 4×2 на 6 колонках: колонка ≤ 2")
        XCTAssertEqual(notifications, 1)

        XCTAssertFalse(store.moveItem("w", toCell: tesseraCell(4, 2), columns: columns))
        XCTAssertFalse(store.moveItem("w", toCell: tesseraCell(4, 5), columns: columns), "после зажима та же ячейка")
        XCTAssertEqual(notifications, 1, "no-op не уведомляет")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// Папку переносят так же, как ярлык.
    func testMoveFolderToCell() throws {
        let directory = TesseraTestDirectory()
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small)])]
        let tiles = [CellFixtureTile("a", .small, 0, 2)]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertTrue(store.moveItem("f", toCell: tesseraCell(2, 2), columns: columns))
        XCTAssertEqual(store.placement(of: "f"), tesseraCell(2, 2))
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(0, 2))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
    }

    /// Перенос в новую строку: после последней занятой, колонка 0, дыра остаётся.
    func testMoveItemToNewRow() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .medium, 0, 2), CellFixtureTile("c", .small, 1, 0)]
        let store = try makeStore(tiles, in: directory)

        XCTAssertTrue(store.moveItemToNewRow("a", columns: columns))

        XCTAssertEqual(store.placement(of: "a"), tesseraCell(2, 0))
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(0, 2))
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(1, 0))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// Единственный элемент в последней строке: «новая строка» — его собственная.
    func testMoveItemToNewRowWhenAlreadyAloneAtBottomIsNoOp() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 1, 0)]
        let store = try makeStore(tiles, in: directory)
        XCTAssertFalse(store.moveItemToNewRow("b", columns: columns))
    }

    // MARK: - Resize

    /// Рост выталкивает вниз; размер сохраняется в модели; якорь остаётся.
    func testResizeGrowthPushesDown() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 1), CellFixtureTile("c", .small, 1, 0), CellFixtureTile("z", .small, 0, 4)]
        let store = try makeStore(tiles, in: directory)

        XCTAssertTrue(store.resize("a", to: .medium, columns: columns))

        XCTAssertEqual(store.snapshot().item(withID: "a")?.size, .medium)
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(0, 0))
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(2, 1), "b пересекал 2×2 — вниз под него")
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(2, 0))
        XCTAssertEqual(store.placement(of: "z"), tesseraCell(0, 4))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// Уменьшение оставляет дыру и ничего не двигает.
    func testResizeShrinkLeavesHole() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("big", .large, 0, 0), CellFixtureTile("n", .small, 4, 0)]
        let store = try makeStore(tiles, in: directory)

        XCTAssertTrue(store.resize("big", to: .small, columns: columns))

        XCTAssertEqual(store.placement(of: "big"), tesseraCell(0, 0))
        XCTAssertEqual(store.placement(of: "n"), tesseraCell(4, 0), "ничего не подтянулось")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// Рост у правого края сдвигает колонку влево; папка меняет размер так же.
    func testResizeClampsLeftAndWorksForFolders() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("s", .small, 0, 5)]
        let folders = [CellFixtureFolder("f", .medium, 4, 0, contents: [("x", .small), ("y", .small)])]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertTrue(store.resize("s", to: .medium, columns: columns))
        XCTAssertEqual(store.placement(of: "s"), tesseraCell(0, 4))

        XCTAssertTrue(store.resize("f", to: .wide, columns: columns))
        XCTAssertEqual(store.snapshot().folders.first?.size, .wide)
        XCTAssertEqual(store.placement(of: "f"), tesseraCell(4, 0))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
    }

    /// Тот же размер, неизвестный элемент: no-op. Ярлык в папке — только размер.
    func testResizeNoOpsAndTileInFolder() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0)]
        let folders = [CellFixtureFolder("f", .medium, 2, 0, contents: [("x", .small), ("y", .small)])]
        let store = try makeStore(tiles, folders: folders, in: directory)
        let before = store.placements
        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        XCTAssertFalse(store.resize("a", to: .small, columns: columns))
        XCTAssertFalse(store.resize("nope", to: .wide, columns: columns))
        XCTAssertFalse(store.resize("a", to: .wide, columns: 0))
        XCTAssertEqual(notifications, 0)

        XCTAssertTrue(store.resize("x", to: .wide, columns: columns))
        XCTAssertEqual(store.tileSizeInFolder("x"), .wide)
        XCTAssertEqual(store.placements, before, "ячейки не менялись")
        XCTAssertEqual(notifications, 1)
    }

    // MARK: - Создание папки

    /// Малая цель становится папкой 2×2 на своей ячейке и выталкивает соседа;
    /// ячейка источника остаётся дырой.
    func testCreateFolderOnSmallTargetBecomesMediumAndPushesNeighbor() throws {
        let directory = TesseraTestDirectory()
        let tiles = [
            CellFixtureTile("T", .small, 1, 1),
            CellFixtureTile("N", .small, 1, 2),
            CellFixtureTile("S", .small, 0, 5),
            CellFixtureTile("K", .small, 4, 4),
        ]
        let store = try makeStore(tiles, in: directory)

        guard case .created(let folder) = store.createFolder(from: "S", onto: "T", title: "Игры", columns: columns) else {
            return XCTFail("папка должна создаться")
        }

        XCTAssertEqual(folder.size, .medium, "D20: папка всегда 2×2")
        XCTAssertEqual(folder.title, "Игры")
        XCTAssertEqual(folder.tiles.map { $0.id }, ["T", "S"])
        XCTAssertEqual(store.placement(of: folder.id), tesseraCell(1, 1))
        XCTAssertEqual(store.placement(of: "N"), tesseraCell(3, 2), "N вытолкнут под папку")
        XCTAssertEqual(store.placement(of: "K"), tesseraCell(4, 4))
        XCTAssertNil(store.placement(of: "S"))
        XCTAssertNil(store.placement(of: "T"))
        XCTAssertFalse(store.placements.values.contains(tesseraCell(0, 5)), "ячейка источника — дыра")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// Цель у правого края: папка сдвигается влево.
    func testCreateFolderClampsLeft() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("T", .small, 0, 5), CellFixtureTile("S", .small, 3, 0)]
        let store = try makeStore(tiles, in: directory)

        guard case .created(let folder) = store.createFolder(from: "S", onto: "T", columns: columns) else {
            return XCTFail("папка должна создаться")
        }
        XCTAssertEqual(store.placement(of: folder.id), tesseraCell(0, 4))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// Широкая цель замещается средней папкой, остальные ячейки — дыры.
    func testCreateFolderOnWideTargetKeepsHoles() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("T", .wide, 0, 0), CellFixtureTile("S", .small, 2, 0), CellFixtureTile("K", .small, 0, 4)]
        let store = try makeStore(tiles, in: directory)

        guard case .created(let folder) = store.createFolder(from: "S", onto: "T", columns: columns) else {
            return XCTFail("папка должна создаться")
        }
        XCTAssertEqual(store.placement(of: folder.id), tesseraCell(0, 0))
        XCTAssertEqual(store.snapshot().item(withID: folder.id)?.size, .medium)
        XCTAssertEqual(store.placement(of: "K"), tesseraCell(0, 4))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// Одобрение хоста: порядок вопросов, отказ первого и второго шага без следов.
    func testCreateFolderApprovalAndDenials() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("T", .small, 0, 0), CellFixtureTile("S", .small, 0, 1)]
        let store = try makeStore(tiles, in: directory)
        let before = store.placements
        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        var actions: [TileGroupingAction] = []
        store.approval = { _, _, action in actions.append(action); return action != .createFolder }
        guard case .createDenied = store.createFolder(from: "S", onto: "T", columns: columns) else {
            return XCTFail("ожидался отказ создания")
        }
        XCTAssertEqual(actions, [.createFolder])

        actions = []
        store.approval = { _, _, action in actions.append(action); return action != .addToFolder }
        guard case .addDenied = store.createFolder(from: "S", onto: "T", columns: columns) else {
            return XCTFail("ожидался отказ добавления")
        }
        XCTAssertEqual(actions, [.createFolder, .addToFolder])

        XCTAssertEqual(store.placements, before)
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        XCTAssertEqual(notifications, 0)
    }

    /// Неверный ввод: тот же ярлык, нет на сетке, папка вместо ярлыка, ширина 0.
    func testCreateFolderInvalidInput() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("T", .small, 0, 0), CellFixtureTile("S", .small, 0, 1)]
        // D45: в папке не меньше двух ярлыков (одноярлычная при загрузке распускается).
        let folders = [CellFixtureFolder("f", .medium, 2, 0, contents: [("x", .small), ("x2", .small)])]
        let store = try makeStore(tiles, folders: folders, unpinned: [("u", .small)], in: directory)

        for (source, target, columns) in [("T", "T", 6), ("S", "u", 6), ("u", "T", 6), ("S", "f", 6), ("S", "x", 6), ("S", "T", 0)] as [(String, String, Int)] {
            guard case .createDenied = store.createFolder(from: source, onto: target, columns: columns) else {
                return XCTFail("(\(source), \(target), \(columns)) должен быть отказом")
            }
        }
        XCTAssertEqual(store.snapshot().folders.count, 1)
    }

    // MARK: - Добавление в папку

    /// Ярлык уходит в папку; его ячейка — дыра, папка остаётся на своей.
    func testAddToFolderLeavesHole() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 1), CellFixtureTile("c", .small, 0, 4)]
        let folders = [CellFixtureFolder("f", .medium, 2, 0, contents: [("x", .small), ("y", .small)])]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertTrue(store.addToFolder("a", folderID: "f", columns: columns))

        XCTAssertNil(store.placement(of: "a"))
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(0, 1))
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(0, 4))
        XCTAssertEqual(store.placement(of: "f"), tesseraCell(2, 0))
        XCTAssertEqual(store.folderContaining("a")?.id, AnyHashable("f"))
        XCTAssertEqual(store.snapshot().folders.first?.tiles.map { $0.id }, ["x", "y", "a"])
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
    }

    /// Отказ хоста, повтор, ярлык в другой папке, неизвестные id — всё no-op.
    func testAddToFolderNoOps() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0)]
        let folders = [
            CellFixtureFolder("f", .medium, 2, 0, contents: [("x", .small), ("x2", .small)]),
            CellFixtureFolder("g", .medium, 2, 3, contents: [("y", .small), ("y2", .small)]),
        ]
        let store = try makeStore(tiles, folders: folders, unpinned: [("u", .small)], in: directory)
        let before = store.placements
        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        XCTAssertFalse(store.addToFolder("x", folderID: "f", columns: columns), "уже в этой папке")
        XCTAssertFalse(store.addToFolder("y", folderID: "f", columns: columns), "в другой папке")
        XCTAssertFalse(store.addToFolder("u", folderID: "f", columns: columns), "не на сетке")
        XCTAssertFalse(store.addToFolder("a", folderID: "nope", columns: columns))
        XCTAssertFalse(store.addToFolder("a", folderID: "f", columns: 0))
        store.approval = { _, _, _ in false }
        XCTAssertFalse(store.addToFolder("a", folderID: "f", columns: columns), "хост запретил")

        XCTAssertEqual(store.placements, before)
        XCTAssertEqual(notifications, 0)
    }

    // MARK: - Вынос из папки

    /// Вынос на ячейку со своим размером: каскад; папка из трёх остаётся с двумя
    /// (D45: из двух осталась бы с одним — распускается, см. `TileStoreFolderMinTwoTests`).
    func testExtractFromFolderToCellKeepsFolderWithRemainingTile() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 3, 0), CellFixtureTile("b", .small, 5, 0)]
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .medium), ("y", .small), ("z", .small)])]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertTrue(store.extractFromFolder("x", toCell: tesseraCell(3, 0), columns: columns))

        XCTAssertEqual(store.placement(of: "x"), tesseraCell(3, 0))
        XCTAssertEqual(store.snapshot().item(withID: "x")?.size, .medium, "размер ярлыка свой")
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(5, 0), "a вытолкнут под x")
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(6, 0), "каскад дошёл до b")
        XCTAssertEqual(store.placement(of: "f"), tesseraCell(0, 0), "папка с двумя ярлыками остаётся")
        XCTAssertEqual(store.folderContaining("y")?.tiles.map { $0.id }, ["y", "z"])
        XCTAssertNil(store.folderContaining("x"))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
    }

    /// Вынос последнего ярлыка переходной папки (D45: папка из одного ярлыка —
    /// только `createFolder(withTile:)`): папка исчезает, её ячейка — дыра.
    func testExtractLastTileRemovesFolderAndLeavesHole() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 3), CellFixtureTile("x", .small, 0, 0)]
        let folders: [CellFixtureFolder] = []
        let store = try makeStore(tiles, folders: folders, in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "x", columns: columns))
        XCTAssertEqual(store.placement(of: folder.id), tesseraCell(0, 0))

        XCTAssertTrue(store.extractFromFolder("x", toCell: tesseraCell(4, 4), columns: columns))

        XCTAssertNil(store.placement(of: folder.id))
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        XCTAssertEqual(store.placement(of: "x"), tesseraCell(4, 4))
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(0, 3))
        XCTAssertFalse(store.placements.values.contains(tesseraCell(0, 0)), "ячейка папки — дыра")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
    }

    /// Вынос в новую строку; опустевшая папка в расчёт строки не входит.
    func testExtractToNewRow() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 3)]
        let folders = [
            CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small)]),
            CellFixtureFolder("g", .medium, 4, 0, contents: [("z", .small), ("z2", .small)]),
        ]
        let store = try makeStore(tiles, folders: folders, in: directory)

        // D45: из папки f (x, y) уходит x — f распадается в y на своей ячейке.
        XCTAssertTrue(store.extractFromFolderToNewRow("x", columns: columns))
        XCTAssertEqual(store.placement(of: "x"), tesseraCell(6, 0), "после папки g (строки 4–5)")
        XCTAssertEqual(store.placement(of: "y"), tesseraCell(0, 0), "y заняла место f")

        // Из папки g уходит z: g распадается в z2 (малая, строка 4), строки 5 свободна;
        // новая строка считается по нижней занятой — это x (строка 6).
        XCTAssertTrue(store.extractFromFolderToNewRow("z", columns: columns))
        XCTAssertNil(store.placement(of: "g"))
        XCTAssertEqual(store.placement(of: "z2"), tesseraCell(4, 0))
        XCTAssertEqual(store.placement(of: "z"), tesseraCell(7, 0), "после x (строка 6)")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
    }

    /// Вынос широкого ярлыка к правому краю сдвигает колонку влево.
    func testExtractClampsLeft() throws {
        let directory = TesseraTestDirectory()
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .wide), ("y", .small)])]
        let store = try makeStore([], folders: folders, in: directory)

        XCTAssertTrue(store.extractFromFolder("x", toCell: tesseraCell(3, 5), columns: columns))
        XCTAssertEqual(store.placement(of: "x"), tesseraCell(3, 2))
    }

    /// Неверный ввод и отказ хоста: no-op; хост получает `.moveBetweenFolders`.
    func testExtractNoOpsAndApprovalAction() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0)]
        let folders = [CellFixtureFolder("f", .medium, 2, 0, contents: [("x", .small), ("y", .small)])]
        let store = try makeStore(tiles, folders: folders, in: directory)
        let before = store.placements
        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        XCTAssertFalse(store.extractFromFolder("a", toCell: tesseraCell(1, 1), columns: columns), "ярлык не в папке")
        XCTAssertFalse(store.extractFromFolder("nope", toCell: tesseraCell(1, 1), columns: columns))
        XCTAssertFalse(store.extractFromFolderToNewRow("a", columns: columns))
        XCTAssertFalse(store.extractFromFolder("x", toCell: tesseraCell(1, 1), columns: 0))

        var seen: [(TileGroupingAction, Bool)] = []
        store.approval = { folder, _, action in seen.append((action, folder == nil)); return false }
        XCTAssertFalse(store.extractFromFolder("x", toCell: tesseraCell(1, 1), columns: columns))
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.0, .moveBetweenFolders)
        XCTAssertEqual(seen.first?.1, true, "папка-цель nil — на рабочий стол")

        XCTAssertEqual(store.placements, before)
        XCTAssertEqual(notifications, 0)
    }

    // MARK: - Между папками

    /// Папка-источник из двух ярлыков распалась (D45): оставшийся ярлык встал на её
    /// ячейку (раньше при опустевшей папке тут оставалась дыра), остальное на месте.
    func testMoveBetweenFoldersDissolvingSourceFillsCellWithRemainingTile() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 4)]
        let folders = [
            CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("x2", .small)]),
            CellFixtureFolder("g", .medium, 2, 2, contents: [("y", .small), ("y2", .small)]),
        ]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertTrue(store.moveBetweenFolders("x", to: "g", columns: columns))

        XCTAssertNil(store.placement(of: "f"))
        XCTAssertEqual(store.placement(of: "x2"), tesseraCell(0, 0))
        XCTAssertEqual(store.placement(of: "g"), tesseraCell(2, 2))
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(0, 4))
        XCTAssertEqual(store.folderContaining("x")?.id, AnyHashable("g"))
        XCTAssertNil(store.folderContaining("x2"))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
    }

    /// Папка-источник остаётся (в ней три ярлыка, D45): ячейки не меняются; та же
    /// папка/отказ — no-op.
    func testMoveBetweenFoldersKeepingSourceAndNoOps() throws {
        let directory = TesseraTestDirectory()
        let folders = [
            CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("x2", .small), ("x3", .small)]),
            CellFixtureFolder("g", .medium, 2, 2, contents: [("y", .small), ("y2", .small)]),
        ]
        let store = try makeStore([], folders: folders, in: directory)
        let before = store.placements

        XCTAssertFalse(store.moveBetweenFolders("x", to: "f", columns: columns), "в ту же папку")
        XCTAssertFalse(store.moveBetweenFolders("x", to: "nope", columns: columns))
        XCTAssertFalse(store.moveBetweenFolders("ghost", to: "g", columns: columns))
        store.approval = { _, _, _ in false }
        XCTAssertFalse(store.moveBetweenFolders("x", to: "g", columns: columns))
        store.approval = { _, _, _ in true }

        XCTAssertTrue(store.moveBetweenFolders("x", to: "g", columns: columns))
        XCTAssertEqual(store.placements, before)
        XCTAssertEqual(store.folderContaining("x2")?.tiles.map { $0.id }, ["x2", "x3"])
    }

    // MARK: - Открепление и закрепление

    /// Открепление ярлыка на сетке оставляет дыру; он появляется среди откреплённых.
    func testUnpinLeavesHole() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 1), CellFixtureTile("c", .small, 1, 0)]
        let store = try makeStore(tiles, in: directory)

        XCTAssertTrue(store.unpin("a", columns: columns))

        XCTAssertNil(store.placement(of: "a"))
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(0, 1))
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(1, 0))
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["a"])
        XCTAssertFalse(store.isPinned("a"))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// Открепление ярлыков из папки по одному (D45): из трёх — папка остаётся с двумя,
    /// из двух — распускается, и последний ярлык встаёт на ячейку папки.
    func testUnpinFolderContentOneByOneDissolvesFolder() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 4)]
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small), ("z", .small)])]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertTrue(store.unpin("x", columns: columns))
        XCTAssertEqual(store.placement(of: "f"), tesseraCell(0, 0))
        XCTAssertEqual(store.folderContaining("y")?.tiles.map { $0.id }, ["y", "z"])

        XCTAssertTrue(store.unpin("y", columns: columns))
        XCTAssertNil(store.placement(of: "f"))
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        XCTAssertEqual(store.placement(of: "z"), tesseraCell(0, 0), "оставшийся ярлык — на месте папки")
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(0, 4))
        XCTAssertEqual(Set(store.snapshot().unpinned.map { $0.id }), ["x", "y"])
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
    }

    /// Открепление неизвестного, уже откреплённого, папки и ширина 0 — no-op.
    func testUnpinNoOps() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0)]
        let folders = [CellFixtureFolder("f", .medium, 2, 0, contents: [("x", .small), ("x2", .small)])]
        let store = try makeStore(tiles, folders: folders, unpinned: [("u", .small)], in: directory)

        XCTAssertFalse(store.unpin("u", columns: columns))
        XCTAssertFalse(store.unpin("nope", columns: columns))
        XCTAssertFalse(store.unpin("f", columns: columns), "папку открепить нельзя (D38)")
        XCTAssertFalse(store.unpin("a", columns: 0))
        XCTAssertEqual(store.snapshot().items.count, 2)
    }

    /// Закрепление: новая строка в конце, размер из `sizes`/каталога.
    func testPinTileGoesToNewRow() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .medium, 0, 0), CellFixtureTile("b", .small, 0, 4)]
        let store = try makeStore(tiles, unpinned: [("w", .wide), ("s", .small)], in: directory)

        XCTAssertTrue(store.pinTile("w", columns: columns))
        XCTAssertEqual(store.placement(of: "w"), tesseraCell(2, 0))
        XCTAssertEqual(store.snapshot().item(withID: "w")?.size, .wide)

        XCTAssertTrue(store.pinTile("s", columns: columns))
        XCTAssertEqual(store.placement(of: "s"), tesseraCell(4, 0))
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(0, 0))
        XCTAssertTrue(store.snapshot().unpinned.isEmpty)
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, unpinned: [("w", .wide), ("s", .small)]))
    }

    /// На узкой сетке большая плитка ужимается по ширине, колонка — 0.
    func testPinTileFitsNarrowGrid() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0)]
        let store = try makeStore(tiles, unpinned: [("L", .large)], in: directory, columns: 2)

        XCTAssertTrue(store.pinTile("L", columns: 2))
        XCTAssertEqual(store.placement(of: "L"), tesseraCell(1, 0))
        tesseraAssertCellInvariants(store, columns: 2, catalogIDs: ["a", "L"])
    }

    /// Закрепление: уже на сетке, в папке, нет в каталоге, ширина 0 — no-op.
    func testPinTileNoOps() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0)]
        let folders = [CellFixtureFolder("f", .medium, 2, 0, contents: [("x", .small), ("x2", .small)])]
        let store = try makeStore(tiles, folders: folders, unpinned: [("u", .small)], in: directory)

        XCTAssertFalse(store.pinTile("a", columns: columns))
        XCTAssertFalse(store.pinTile("x", columns: columns))
        XCTAssertFalse(store.pinTile("nope", columns: columns))
        XCTAssertFalse(store.pinTile("u", columns: 0))
        XCTAssertEqual(store.snapshot().items.count, 2)
    }

    // MARK: - Схлопывание пустых строк

    /// Схлопываются только строки, которых не покрывает ни один элемент.
    func testCollapseEmptyRowsOnlyRemovesUncoveredRows() throws {
        let directory = TesseraTestDirectory()
        let tiles = [
            CellFixtureTile("tall", .large, 1, 0),   // строки 1–4
            CellFixtureTile("s1", .small, 1, 4),     // строка 1
            CellFixtureTile("s2", .small, 7, 4),     // строка 7; 5–6 пусты
            CellFixtureTile("s3", .small, 10, 0),    // 8–9 пусты
        ]
        let store = try makeStore(tiles, in: directory)

        XCTAssertTrue(store.collapseEmptyRows(columns: columns))

        // Строка 0 пуста (выше всех), 5–6 пусты, 8–9 пусты: всего 5 строк уйдёт.
        XCTAssertEqual(store.placement(of: "tall"), tesseraCell(0, 0))
        XCTAssertEqual(store.placement(of: "s1"), tesseraCell(0, 4), "строки 2–4 покрыты высокой плиткой")
        XCTAssertEqual(store.placement(of: "s2"), tesseraCell(5 - 1, 4), "7 − (1 + 2)")
        XCTAssertEqual(store.placement(of: "s3"), tesseraCell(10 - 5, 0))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// Идемпотентность: повторный вызов и раскладка без пустых строк — no-op.
    func testCollapseEmptyRowsIsIdempotentAndSilent() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 3, 0)]
        let store = try makeStore(tiles, in: directory)
        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        XCTAssertTrue(store.collapseEmptyRows(columns: columns))
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(1, 0))
        let afterFirst = store.placements
        let fileAfterFirst = try Data(contentsOf: store.fileURL)

        XCTAssertFalse(store.collapseEmptyRows(columns: columns))
        XCTAssertEqual(store.placements, afterFirst)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), fileAfterFirst)
        XCTAssertEqual(notifications, 1)
        XCTAssertFalse(store.collapseEmptyRows(columns: 0))
    }

    /// Операции строк не схлопывают: дыра-строка остаётся, пока не позвали `collapseEmptyRows`.
    func testOperationsDoNotCollapseRowsByThemselves() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 1, 0), CellFixtureTile("c", .small, 2, 0)]
        let store = try makeStore(tiles, in: directory)

        XCTAssertTrue(store.unpin("b", columns: columns))
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(2, 0), "пустая строка 1 осталась")
        XCTAssertTrue(store.collapseEmptyRows(columns: columns))
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(1, 0))
    }

    // MARK: - Уведомления и отсутствие репака

    /// Одна операция — один `onChange`, и снимок уже согласован.
    func testSingleNotificationPerOperation() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 1)]
        let store = try makeStore(tiles, in: directory)
        var snapshots: [TileGridSnapshot] = []
        store.onChange = { snapshots.append($0) }

        guard case .created(let folder) = store.createFolder(from: "a", onto: "b", columns: columns) else {
            return XCTFail("папка должна создаться")
        }
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(tesseraTestIDs(snapshots[0].items), [folder.id])
    }

    /// Операции не пересчитывают ячейки упаковкой: уход соседа оставляет дыру, а
    /// ячейка далёкой плитки не подтягивается (переходный репак E14.1 удалён в E14.6).
    func testUnpinDoesNotRepackOtherCells() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 1), CellFixtureTile("c", .small, 3, 3)]
        let store = try makeStore(tiles, in: directory)

        XCTAssertTrue(store.moveItem("c", toCell: tesseraCell(5, 5), columns: columns))
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(5, 5), "ячейка не пересчитана упаковкой")

        XCTAssertTrue(store.unpin("a", columns: columns))
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(0, 1), "дыра на месте «a» осталась")
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(5, 5))
    }

    /// Ширина хоста, отличная от холста, при ошибке ввода не перезаписывает файл (D32).
    func testInvalidInputDoesNotAdoptCanvasOrWriteFile() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 3, 5)]
        let store = try makeStore(tiles, in: directory)
        let original = try Data(contentsOf: store.fileURL)

        XCTAssertFalse(store.moveItem("nope", toCell: tesseraCell(0, 0), columns: 4))
        XCTAssertFalse(store.moveItem("a", toCell: tesseraCell(0, 0), columns: 4), "уже на месте в проекции")
        XCTAssertFalse(store.collapseEmptyRows(columns: 4), "в проекции пустых строк нет")

        XCTAssertEqual(store.canvasColumns, 6)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }
}

private extension TileStore {

    /// Размер ярлыка из каталога хранилища (для проверки resize внутри папки).
    func tileSizeInFolder(_ id: AnyHashable) -> TileSize? {
        folderContaining(id)?.tiles.first { $0.id == id }?.size
    }
}

#endif
