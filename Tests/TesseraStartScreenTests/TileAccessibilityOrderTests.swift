//
//  TileAccessibilityOrderTests.swift
//  TesseraStartScreenTests
//
//  Порядок VoiceOver по ячейкам и фокус после операций правки (E14.7).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §9 «Accessibility» и
//  «Отступления реализации (E14)», п. 55; решения D30–D33 в docs/STATE.md.
//
//  Порядок обхода VoiceOver — порядок индексов коллекции (сетка не задаёт
//  `accessibilityElements`, раскладка отдаёт атрибуты по индексу), поэтому
//  проверяется порядок снимка и набора коллекции, а также то, что кадры
//  элементов идут в том же порядке (строка сверху вниз, затем колонка в
//  направлении чтения): так порядок по индексам совпадает и с тем, что увидел бы
//  обход по кадрам. Реального VoiceOver здесь нет — проверка структурная.
//
//  Покрыто: дыры в строке, высокие и широкие плитки, файл не в порядке чтения,
//  миграция v1 → v2, проекция под другую ширину, `setCatalog`, сетка без
//  `TileStore` (только таблица ячеек), откат на упаковку, смена колонок, RTL,
//  панель раскрытой папки; фокус после unpin (следующий/предыдущий/сетка),
//  resize, drop в дыру, слияния в папку, вынос из папки; custom actions.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileAccessibilityOrderTests: XCTestCase {

    // MARK: - Помощники

    private func small(_ id: String) -> TileGridItem { .tile(tesseraTestTile(id, size: .small)) }
    private func medium(_ id: String) -> TileGridItem { .tile(tesseraTestTile(id, size: .medium)) }
    private func wide(_ id: String) -> TileGridItem { .tile(tesseraTestTile(id, size: .wide)) }

    private func ids(_ items: [TileGridItem]) -> [AnyHashable] { items.map { $0.id } }

    /// Снимок с таблицей ячеек для сетки заданной ширины.
    private func snapshot(
        _ items: [TileGridItem],
        cells: [AnyHashable: TileGridPlacement],
        columns: Int? = 4
    ) -> TileGridSnapshot {
        TileGridSnapshot(
            items: items,
            unpinned: [],
            placementTable: TileGridPlacementTable(cells: cells, columns: columns)
        )
    }

    /// Кадры элементов коллекции идут в порядке чтения: строка сверху вниз, затем
    /// колонка в направлении чтения (в RTL — справа налево). Панель раскрытой
    /// папки входит в проверку наравне с плитками.
    private func assertFramesFollowReadingOrder(
        _ host: TesseraTestWindowedGrid,
        rightToLeft: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        host.layout()
        let collectionView = try XCTUnwrap(host.collectionView, file: file, line: line)
        let count = host.grid.displayItems.count
        var frames: [CGRect] = []
        for index in 0..<count {
            let attributes = try XCTUnwrap(
                collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0)),
                "атрибуты \(index)", file: file, line: line
            )
            frames.append(attributes.frame)
        }
        for index in 1..<max(count, 1) {
            let previous = frames[index - 1]
            let current = frames[index]
            let sameRow = abs(previous.minY - current.minY) < 0.5
            if sameRow {
                let inReadingDirection = rightToLeft
                    ? previous.minX > current.minX
                    : previous.minX < current.minX
                XCTAssertTrue(
                    inReadingDirection,
                    "элементы \(index - 1) и \(index) в одной строке идут против чтения",
                    file: file, line: line
                )
            } else {
                XCTAssertLessThan(
                    previous.minY, current.minY,
                    "элемент \(index) выше элемента \(index - 1)", file: file, line: line
                )
            }
        }
    }

    // MARK: - Сетка: порядок по таблице ячеек (без TileStore)

    /// Дыра в строке: элементы, поданные хостом вперемешку, идут в порядке
    /// чтения ячеек — в снимке сетки и в наборе коллекции.
    func testGridOrdersItemsByCellsWithHoleInRow() throws {
        let cells: [AnyHashable: TileGridPlacement] = [
            "a": tesseraCell(0, 0), "b": tesseraCell(0, 3), "c": tesseraCell(3, 1),
        ]
        let host = TesseraTestWindowedGrid(
            snapshot: snapshot([medium("c"), small("b"), small("a")], cells: cells)
        )

        XCTAssertEqual(host.grid.items.map { $0.id }, ["a", "b", "c"] as [AnyHashable])
        XCTAssertEqual(host.grid.displayItems.map { $0.id }, ["a", "b", "c"] as [AnyHashable])
        XCTAssertEqual(host.grid.index(ofItemID: "b"), 1)
        try assertFramesFollowReadingOrder(host)
    }

    /// Высокие и широкие плитки: порядок — строка, затем колонка левого верхнего
    /// угла, а не «снизу вверх по высоте».
    func testGridOrdersTallAndWideTilesByTopLeftCell() throws {
        let cells: [AnyHashable: TileGridPlacement] = [
            "m": tesseraCell(0, 0), "s1": tesseraCell(0, 2), "s3": tesseraCell(0, 3),
            "s2": tesseraCell(1, 2), "w": tesseraCell(2, 0), "t": tesseraCell(4, 3),
        ]
        let host = TesseraTestWindowedGrid(
            snapshot: snapshot(
                [small("t"), wide("w"), small("s2"), small("s3"), small("s1"), medium("m")],
                cells: cells
            )
        )

        XCTAssertEqual(
            host.grid.displayItems.map { $0.id },
            ["m", "s1", "s3", "s2", "w", "t"] as [AnyHashable]
        )
        try assertFramesFollowReadingOrder(host)
    }

    /// Порядок снимка уже верный — снимок сетки тот же, без перестановок.
    func testGridKeepsOrderedSnapshotAsIs() {
        let cells: [AnyHashable: TileGridPlacement] = ["a": tesseraCell(0, 0), "b": tesseraCell(1, 0)]
        let ordered = snapshot([small("a"), small("b")], cells: cells)
        let result = ordered.readingOrdered(columns: 4)
        XCTAssertEqual(result.items.map { $0.id }, ["a", "b"] as [AnyHashable])
        XCTAssertEqual(result.placementTable, ordered.placementTable)
    }

    /// Без применимой таблицы порядок остаётся таким, как отдал хост: упаковка
    /// `pack` идёт по порядку снимка. Это таблица другой ширины, неполная и её
    /// отсутствие.
    func testGridKeepsGivenOrderWhenTableIsNotApplicable() {
        let items = [small("c"), small("a"), small("b")]

        // Таблица рассчитана на 6 колонок, сетка — 4.
        let otherWidth = TesseraTestWindowedGrid(
            snapshot: snapshot(
                items,
                cells: ["a": tesseraCell(0, 0), "b": tesseraCell(0, 1), "c": tesseraCell(1, 0)],
                columns: 6
            )
        )
        XCTAssertEqual(otherWidth.grid.items.map { $0.id }, ["c", "a", "b"] as [AnyHashable])

        // Неполная: нет ячейки у "b".
        let partial = TesseraTestWindowedGrid(
            snapshot: snapshot(items, cells: ["a": tesseraCell(0, 0), "c": tesseraCell(1, 0)])
        )
        XCTAssertEqual(partial.grid.items.map { $0.id }, ["c", "a", "b"] as [AnyHashable])

        // С пересечением: ячейки не проходят проверку.
        let overlapping = TesseraTestWindowedGrid(
            snapshot: snapshot(
                items,
                cells: ["a": tesseraCell(0, 0), "b": tesseraCell(0, 0), "c": tesseraCell(1, 0)]
            )
        )
        XCTAssertEqual(overlapping.grid.items.map { $0.id }, ["c", "a", "b"] as [AnyHashable])

        // Без таблицы.
        let noTable = TesseraTestWindowedGrid(items: items)
        XCTAssertEqual(noTable.grid.items.map { $0.id }, ["c", "a", "b"] as [AnyHashable])
    }

    /// `update(snapshot:animated:)` приводит порядок так же, как `reload`.
    func testUpdateAlsoOrdersByCells() {
        let host = TesseraTestWindowedGrid(items: [small("a")])
        let cells: [AnyHashable: TileGridPlacement] = [
            "a": tesseraCell(2, 0), "b": tesseraCell(0, 2), "c": tesseraCell(1, 1),
        ]
        host.grid.update(
            snapshot: snapshot([small("a"), small("b"), small("c")], cells: cells),
            animated: false
        )
        host.layout()
        XCTAssertEqual(host.grid.items.map { $0.id }, ["b", "c", "a"] as [AnyHashable])
        XCTAssertEqual(host.grid.displayItems.map { $0.id }, ["b", "c", "a"] as [AnyHashable])
    }

    /// Смена числа колонок делает таблицу применимой: порядок перестраивается по
    /// ней (а до этого шла упаковка по порядку хоста).
    func testColumnsChangeReordersWhenTableBecomesApplicable() throws {
        let cells: [AnyHashable: TileGridPlacement] = [
            "a": tesseraCell(0, 0), "b": tesseraCell(0, 1), "c": tesseraCell(1, 0),
        ]
        let host = TesseraTestWindowedGrid(
            snapshot: snapshot([small("c"), small("b"), small("a")], cells: cells, columns: 6),
            columns: 4
        )
        XCTAssertEqual(host.grid.items.map { $0.id }, ["c", "b", "a"] as [AnyHashable], "ширина не совпала")

        host.grid.columns = 6
        host.layout()
        XCTAssertEqual(host.grid.items.map { $0.id }, ["a", "b", "c"] as [AnyHashable])
        XCTAssertEqual(host.grid.displayItems.map { $0.id }, ["a", "b", "c"] as [AnyHashable])
        try assertFramesFollowReadingOrder(host)
    }

    // MARK: - RTL

    /// RTL: колонки логические, порядок тот же (колонка 0 — справа), кадры идут
    /// справа налево.
    func testRightToLeftOrderUsesLogicalColumns() throws {
        let cells: [AnyHashable: TileGridPlacement] = [
            "a": tesseraCell(0, 0), "b": tesseraCell(0, 3), "c": tesseraCell(1, 2), "d": tesseraCell(2, 0),
        ]
        let host = TesseraTestWindowedGrid(
            snapshot: snapshot([small("d"), small("c"), small("b"), small("a")], cells: cells)
        )
        host.grid.semanticContentAttribute = .forceRightToLeft
        host.collectionView?.semanticContentAttribute = .forceRightToLeft
        host.grid.reload(snapshot: snapshot([small("d"), small("c"), small("b"), small("a")], cells: cells))
        host.layout()

        XCTAssertEqual(host.grid.displayItems.map { $0.id }, ["a", "b", "c", "d"] as [AnyHashable])
        let aFrame = try XCTUnwrap(host.grid.frame(forItemID: "a"))
        let bFrame = try XCTUnwrap(host.grid.frame(forItemID: "b"))
        XCTAssertGreaterThan(aFrame.midX, bFrame.midX, "колонка 0 — у правого края")
        try assertFramesFollowReadingOrder(host, rightToLeft: true)
    }

    // MARK: - Панель раскрытой папки

    /// Панель стоит сразу после последнего элемента полосы папки (в порядке
    /// чтения), плитки ниже читаются после неё; ярлыки папки читаются внутри
    /// панели, то есть после плитки папки.
    func testFolderPanelFollowsBandAndKeepsOrder() throws {
        let folder = TileFolder(
            id: "f",
            title: "Work",
            tiles: ["x1", "x2", "x3"].map { tesseraTestTile($0, size: .small) },
            size: .medium
        )
        let cells: [AnyHashable: TileGridPlacement] = [
            "f": tesseraCell(0, 0), "s1": tesseraCell(0, 2), "s3": tesseraCell(0, 3),
            "s2": tesseraCell(1, 2), "x": tesseraCell(2, 0), "y": tesseraCell(2, 1),
        ]
        let host = TesseraTestWindowedGrid(
            snapshot: snapshot(
                [small("y"), small("x"), small("s2"), small("s3"), small("s1"), .folder(folder)],
                cells: cells
            )
        )
        host.grid.openFolder(folder, animated: false)
        host.layout()

        let display = host.grid.displayItems
        XCTAssertEqual(
            display.map { $0.isFolderPanel ? "panel" : "\($0.id)" },
            ["f", "s1", "s3", "s2", "panel", "x", "y"]
        )
        XCTAssertEqual(host.grid.items.count, 6, "в снимке панели нет")
        try assertFramesFollowReadingOrder(host)

        let panel = try XCTUnwrap(host.panelCell(folderID: "f"))
        panel.layoutIfNeeded()
        XCTAssertEqual(
            panel.shortcutCells.compactMap { $0.accessibilityLabel },
            ["x1", "x2", "x3"],
            "ярлыки папки читаются в порядке папки"
        )
    }

    // MARK: - TileStore: порядок снимка по ячейкам

    private func makeStore(
        catalog: [TileDescriptor],
        in directory: TesseraTestDirectory
    ) -> TileStore {
        let store = TileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog(catalog)
        return store
    }

    private func write(_ document: [String: Any], to store: TileStore, in directory: TesseraTestDirectory) throws {
        try directory.create()
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try data.write(to: store.fileURL)
    }

    /// Порядок снимка совпадает с порядком чтения ячеек для заданной ширины.
    private func assertSnapshotIsReadingOrdered(
        _ store: TileStore,
        columns: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let cells = store.placements(forColumns: columns)
        let expected = cells
            .sorted { TileGridPlacement.isReadingOrdered($0.value, before: $1.value) }
            .map { $0.key }
        XCTAssertEqual(
            store.snapshot(columns: columns).items.map { $0.id }, expected,
            "snapshot(columns:) идёт в порядке чтения ячеек", file: file, line: line
        )
        XCTAssertEqual(
            store.placementReadingOrder(forColumns: columns), expected,
            file: file, line: line
        )
    }

    /// Файл версии 2, в котором элементы записаны не в порядке чтения: после
    /// `load()` снимок идёт по ячейкам, а не по порядку файла.
    func testStoreSnapshotAfterLoadOfUnorderedFileFollowsCells() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(catalog: ["a", "b", "c"].map { tesseraTestTile($0, size: .small) }, in: directory)
        try write(
            [
                "version": 2,
                "columns": 4,
                "items": [
                    ["kind": "tile", "key": "s:c", "row": 1, "column": 0],
                    ["kind": "tile", "key": "s:a", "row": 0, "column": 2],
                    ["kind": "tile", "key": "s:b", "row": 0, "column": 0],
                ],
                "sizes": ["s:a": "small", "s:b": "small", "s:c": "small"],
                "folders": [],
            ],
            to: store,
            in: directory
        )
        try store.load()

        XCTAssertEqual(store.snapshot().items.map { $0.id }, ["b", "a", "c"] as [AnyHashable])
        XCTAssertEqual(store.snapshot(columns: 4).items.map { $0.id }, ["b", "a", "c"] as [AnyHashable])
        assertSnapshotIsReadingOrdered(store, columns: 4)

        // Сетка из такого снимка показывает тот же порядок.
        let host = TesseraTestWindowedGrid(snapshot: store.snapshot(columns: 4))
        XCTAssertEqual(host.grid.items.map { $0.id }, ["b", "a", "c"] as [AnyHashable])
    }

    /// Миграция v1 → v2: `packCompact` забивает дыру правее средней плитки
    /// поздней маленькой, и порядок чтения расходится с порядком файла v1 — снимок
    /// идёт по ячейкам.
    func testStoreSnapshotAfterV1MigrationFollowsCells() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(
            catalog: [
                tesseraTestTile("m", size: .medium),
                tesseraTestTile("w", size: .wide),
                tesseraTestTile("s", size: .small),
            ],
            in: directory
        )
        try write(
            [
                "version": 1,
                "items": [
                    ["kind": "tile", "key": "s:m"],
                    ["kind": "tile", "key": "s:w"],
                    ["kind": "tile", "key": "s:s"],
                ],
                "sizes": ["s:m": "medium", "s:w": "wide", "s:s": "small"],
                "folders": [],
            ],
            to: store,
            in: directory
        )
        try store.load()
        XCTAssertTrue(store.placeItems(columns: 4))

        XCTAssertEqual(store.placement(of: "s"), tesseraCell(0, 2), "малая плитка заняла дыру выше широкой")
        XCTAssertEqual(store.placement(of: "w"), tesseraCell(2, 0))
        XCTAssertEqual(store.snapshot().items.map { $0.id }, ["m", "s", "w"] as [AnyHashable])
        XCTAssertEqual(store.snapshot(columns: 4).items.map { $0.id }, ["m", "s", "w"] as [AnyHashable])
        assertSnapshotIsReadingOrdered(store, columns: 4)
    }

    /// Проекция под другую ширину (D32): снимок для ширины хоста идёт по ячейкам
    /// проекции, для ширины холста — по сохранённым; файл не перезаписывается.
    func testStoreSnapshotForOtherWidthFollowsProjectedCells() throws {
        let directory = TesseraTestDirectory()
        let store = try TileStoreCellFixture.makeStore(
            columns: 6,
            tiles: [
                CellFixtureTile("m", .medium, 0, 0),
                CellFixtureTile("w", .wide, 0, 2),
                CellFixtureTile("s", .small, 2, 0),
            ],
            in: directory
        )
        let stored = try Data(contentsOf: store.fileURL)

        XCTAssertEqual(store.snapshot(columns: 6).items.map { $0.id }, ["m", "w", "s"] as [AnyHashable])
        XCTAssertEqual(
            store.snapshot(columns: 4).items.map { $0.id }, ["m", "s", "w"] as [AnyHashable],
            "в проекции на 4 колонки малая плитка встала правее средней, широкая — ниже"
        )
        assertSnapshotIsReadingOrdered(store, columns: 6)
        assertSnapshotIsReadingOrdered(store, columns: 4)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), stored, "проекция файл не пишет")

        // Сетка хоста на 4 колонках получает таблицу проекции и тот же порядок.
        let host = TesseraTestWindowedGrid(snapshot: store.snapshot(columns: 4), columns: 4)
        XCTAssertEqual(host.grid.displayItems.map { $0.id }, ["m", "s", "w"] as [AnyHashable])
        try assertFramesFollowReadingOrder(host)
    }

    /// `setCatalog`: ярлык, вернувшийся в каталог на своё прежнее место выше
    /// остальных, встаёт в порядке чтения, а не в конец порядка модели.
    func testStoreSnapshotAfterSetCatalogFollowsCells() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(catalog: [tesseraTestTile("a", size: .small)], in: directory)
        try write(
            [
                "version": 2,
                "columns": 4,
                "items": [
                    ["kind": "tile", "key": "s:a", "row": 0, "column": 1],
                    ["kind": "tile", "key": "s:g", "row": 0, "column": 0],
                ],
                "sizes": ["s:a": "small", "s:g": "small"],
                "folders": [],
            ],
            to: store,
            in: directory
        )
        try store.load()
        XCTAssertEqual(store.snapshot().items.map { $0.id }, ["a"] as [AnyHashable], "«g» не в каталоге")

        store.setCatalog([tesseraTestTile("a", size: .small), tesseraTestTile("g", size: .small)])
        XCTAssertEqual(store.placement(of: "g"), tesseraCell(0, 0))
        XCTAssertEqual(store.snapshot().items.map { $0.id }, ["g", "a"] as [AnyHashable])
        XCTAssertEqual(store.snapshot(columns: 4).items.map { $0.id }, ["g", "a"] as [AnyHashable])
        assertSnapshotIsReadingOrdered(store, columns: 4)
    }

    /// Папки — верхнеуровневые элементы наравне с плитками: порядок по ячейкам
    /// папки, а не по номеру в каталоге.
    func testStoreSnapshotOrdersFoldersLikeTiles() throws {
        let directory = TesseraTestDirectory()
        let store = try TileStoreCellFixture.makeStore(
            columns: 4,
            tiles: [CellFixtureTile("a", .small, 0, 2), CellFixtureTile("z", .small, 3, 0)],
            folders: [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small)])],
            in: directory
        )
        XCTAssertEqual(store.snapshot(columns: 4).items.map { $0.id }, ["f", "a", "z"] as [AnyHashable])
    }

    // MARK: - Фокус после операций правки (.layoutChanged)

    private final class PostRecorder {
        var posts: [(UIAccessibility.Notification, Any?)] = []
    }

    private func record(_ host: TesseraTestDragHost) -> PostRecorder {
        let recorder = PostRecorder()
        host.coordinator.accessibilityNotificationPoster = { notification, argument in
            recorder.posts.append((notification, argument))
        }
        return recorder
    }

    /// Раскладка с дырами: a(0,0), b(0,3), c(4,0); остальное пусто.
    private func makeHoleHost() throws -> TesseraTestDragHost {
        try TesseraTestDragHost(
            cells: [
                CellFixtureTile("a", .small, 0, 0),
                CellFixtureTile("b", .small, 0, 3),
                CellFixtureTile("c", .small, 4, 0),
            ]
        )
    }

    private func assertFocus(
        _ recorder: PostRecorder,
        on view: UIView?,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(recorder.posts.last?.0, UIAccessibility.Notification.layoutChanged, file: file, line: line)
        XCTAssertNotNil(view, "ячейка-цель существует: \(message)", file: file, line: line)
        XCTAssertTrue((recorder.posts.last?.1 as? UIView) === view, message, file: file, line: line)
    }

    /// Unpin: фокус — следующий в порядке чтения, даже если на месте удалённого
    /// ярлыка осталась пустая ячейка.
    func testFocusAfterUnpinGoesToNextInReadingOrder() throws {
        let host = try makeHoleHost()
        let recorder = record(host)

        host.coordinator.unpin("a")
        XCTAssertTrue(host.waitUntil { !recorder.posts.isEmpty }, "уведомление опубликовано")
        XCTAssertFalse(host.store.isPinned("a"))
        assertFocus(recorder, on: host.host.cell("b"), "следующий после «a» — «b»")

        // Середина: удаляется «b» — следом «c», хотя между ними пять пустых строк.
        let middle = try makeHoleHost()
        let middleRecorder = record(middle)
        middle.coordinator.unpin("b")
        XCTAssertTrue(middle.waitUntil { !middleRecorder.posts.isEmpty })
        assertFocus(middleRecorder, on: middle.host.cell("c"), "следующий после «b» — «c»")
    }

    /// Unpin последнего элемента: фокус — на предыдущем.
    func testFocusAfterUnpinOfLastGoesToPrevious() throws {
        let host = try makeHoleHost()
        let recorder = record(host)

        host.coordinator.unpin("c")
        XCTAssertTrue(host.waitUntil { !recorder.posts.isEmpty })
        XCTAssertFalse(host.store.isPinned("c"))
        assertFocus(recorder, on: host.host.cell("b"), "после последнего — предыдущий")
    }

    /// Unpin единственного элемента: на сетке никого нет, фокус — на самой сетке.
    func testFocusAfterUnpinOfOnlyItemGoesToGrid() throws {
        let host = try TesseraTestDragHost(cells: [CellFixtureTile("a", .small, 0, 0)])
        let recorder = record(host)

        host.coordinator.unpin("a")
        XCTAssertTrue(host.waitUntil { !recorder.posts.isEmpty })
        XCTAssertTrue(host.gridIDs.isEmpty)
        XCTAssertEqual(recorder.posts.last?.0, UIAccessibility.Notification.layoutChanged)
        XCTAssertTrue((recorder.posts.last?.1 as? UIView) === host.host.grid, "фокус — сама сетка")
    }

    /// Unpin ярлыка, которого нет на сетке (лежит в папке): прежнее поведение —
    /// фокус на последнем элементе сетки, на несуществующий ярлык не уходит.
    func testFocusAfterUnpinOfTileInsideFolderKeepsPreviousBehavior() throws {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("a", .small, 0, 3), CellFixtureTile("z", .small, 3, 0)],
            folders: [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small)])]
        )
        let recorder = record(host)

        host.coordinator.unpin("x")
        XCTAssertTrue(host.waitUntil { !recorder.posts.isEmpty })
        XCTAssertFalse(host.store.isPinned("x"))
        assertFocus(recorder, on: host.host.cell("z"), "последний элемент сетки в порядке чтения")
    }

    /// Resize: фокус — на изменённой плитке, и она остаётся на своей ячейке
    /// (дыры не схлопываются).
    func testFocusAfterResizeStaysOnResizedTile() throws {
        let host = try makeHoleHost()
        let recorder = record(host)

        host.coordinator.beginEditing()
        XCTAssertEqual(host.coordinator.cycleSize(of: "b"), .medium)
        XCTAssertTrue(host.waitUntil { !recorder.posts.isEmpty })
        assertFocus(recorder, on: host.host.cell("b"), "фокус на «b»")
        XCTAssertEqual(host.store.placement(of: "b"), tesseraCell(0, 2), "рост сдвинул колонку влево, ячейка на месте")
        host.coordinator.endEditing()
    }

    /// Drop в дыру: фокус — на переехавшей плитке; порядок снимка — порядок
    /// чтения новых ячеек.
    func testFocusAfterMoveIntoHoleGoesToMovedTile() throws {
        let host = try makeHoleHost()
        let recorder = record(host)

        XCTAssertTrue(host.coordinator.move("c", toCell: tesseraCell(0, 1)))
        XCTAssertTrue(host.waitUntil { !recorder.posts.isEmpty })
        XCTAssertEqual(host.store.placement(of: "c"), tesseraCell(0, 1))
        XCTAssertEqual(host.gridIDs, ["a", "c", "b"] as [AnyHashable], "порядок следует за ячейками")
        XCTAssertEqual(host.gridIDs, host.storeIDs)
        assertFocus(recorder, on: host.host.cell("c"), "фокус на «c»")
    }

    /// Слияние в папку: фокус — на созданной папке; добавление в существующую —
    /// на папке-цели.
    func testFocusAfterMergeIntoFolderGoesToFolder() throws {
        let host = try makeHoleHost()
        let recorder = record(host)

        let folder = try XCTUnwrap(host.coordinator.createFolder(withTile: "b"))
        host.host.layout()
        XCTAssertTrue(host.waitUntil { !recorder.posts.isEmpty })
        assertFocus(recorder, on: host.host.cell(folder.id), "фокус на созданной папке")

        recorder.posts.removeAll()
        XCTAssertTrue(host.coordinator.addToFolder("a", folderID: folder.id))
        host.host.layout()
        XCTAssertTrue(host.waitUntil { !recorder.posts.isEmpty })
        assertFocus(recorder, on: host.host.cell(folder.id), "фокус на папке-цели")
    }

    /// Вынос из папки: фокус — на вынесенном ярлыке (он на сетке).
    func testFocusAfterExtractFromFolderGoesToTile() throws {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("z", .small, 3, 0)],
            folders: [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small)])]
        )
        let recorder = record(host)

        XCTAssertTrue(host.coordinator.moveBetweenFolders("y", to: nil))
        host.host.layout()
        XCTAssertTrue(host.waitUntil { !recorder.posts.isEmpty })
        XCTAssertTrue(host.gridIDs.contains("y"))
        assertFocus(recorder, on: host.host.cell("y"), "фокус на вынесенном ярлыке")
        XCTAssertEqual(host.gridIDs, host.storeIDs)
    }

    // MARK: - Custom actions на новых операциях

    /// «Открепить» и «Изменить размер» работают по ячейкам: открепление оставляет
    /// дыру (соседи не двигаются), размер меняется на месте.
    func testCustomActionsUnpinAndResizeUseCellOperations() throws {
        let host = try makeHoleHost()
        let recorder = record(host)
        host.coordinator.beginEditing()

        func action(_ name: String, in id: AnyHashable) -> UIAccessibilityCustomAction? {
            host.host.cell(id)?.accessibilityCustomActions?.first { $0.name == name }
        }
        let resizeName = TesseraStartScreenStrings.string(.a11yActionResize)
        let unpinName = TesseraStartScreenStrings.string(.a11yActionUnpin)
        XCTAssertTrue(host.waitUntil { action(resizeName, in: "a") != nil && action(unpinName, in: "b") != nil })

        let resize = try XCTUnwrap(action(resizeName, in: "a"))
        XCTAssertEqual(resize.actionHandler?(resize), true)
        let resizedA = host.store.snapshot().items.first { $0.id == AnyHashable("a") }
        XCTAssertEqual(resizedA?.size, .medium)
        XCTAssertEqual(host.store.placement(of: "a"), tesseraCell(0, 0))
        XCTAssertEqual(host.store.placement(of: "b"), tesseraCell(0, 3), "сосед на своей ячейке")

        let unpin = try XCTUnwrap(action(unpinName, in: "b"))
        XCTAssertEqual(unpin.actionHandler?(unpin), true)
        XCTAssertTrue(host.waitUntil { !host.store.isPinned("b") })
        XCTAssertEqual(host.store.placement(of: "a"), tesseraCell(0, 0))
        XCTAssertEqual(host.store.placement(of: "c"), tesseraCell(2, 0), "пустые строки схлопнулись, порядок сохранён")
        XCTAssertTrue(host.waitUntil { recorder.posts.contains { ($0.1 as? UIView) === host.host.cell("c") } },
                      "после открепления фокус — на следующем в порядке чтения")
        host.coordinator.endEditing()
    }
}

#endif
