//
//  TileStoreTests.swift
//  TesseraStartScreenTests
//
//  Тесты хранилища рабочего стола (задача E4.7).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §5 «Режим редактирования»
//  (TileStore сохраняет порядок/размеры/закрепления и выживает между
//  запусками), §6 «Страница справа» (единственный источник истины,
//  двусторонний pin/unpin) и §14 «Уточнения MVP» п. 3 (D14: создание папки,
//  добавление ярлыка и перемещение между папками — только через функцию
//  одобрения хоста; дефолт — разрешено).
//
//  Проверяются: консистентность pin/unpin, move/resize, папки и функция
//  одобрения, round-trip персистентности во временную директорию, испорченный
//  файл и неподдерживаемая версия схемы. Тесты не поднимают UI и работают
//  на главном потоке, как и сам TileStore.
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileStoreTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Ширина сетки хоста во всех операциях по ячейкам (E14.6).
    private let columns = 6

    private func makeDescriptors() -> [TileDescriptor] {
        [
            tesseraTestTile("a", size: .small),
            tesseraTestTile("b", size: .medium),
            tesseraTestTile("c", size: .medium),
            tesseraTestTile("d", size: .small),
        ]
    }

    /// Создаёт хранилище поверх временного каталога.
    ///
    /// Автосохранение по умолчанию выключено: большинство тестов проверяют
    /// модель, а не файловые операции.
    ///
    /// - Parameters:
    ///   - descriptors: Каталог ярлыков (D12).
    ///   - directory: Временный каталог теста.
    ///   - autosaves: Включить автосохранение.
    /// - Returns: Настроенное хранилище.
    private func makeStore(
        _ descriptors: [TileDescriptor],
        in directory: TesseraTestDirectory,
        autosaves: Bool = false
    ) -> TileStore {
        let store = TileStore(directoryURL: directory.url)
        store.autosaves = autosaves
        store.setCatalog(descriptors)
        // Раскладка первого запуска: a(0,0) b(0,1) c(0,3) d(0,5) на 6 колонках.
        store.placeItems(columns: columns)
        return store
    }

    private func ids(_ snapshot: TileGridSnapshot) -> [AnyHashable] {
        snapshot.items.map { $0.id }
    }

    // MARK: - Первый запуск и закрепление

    /// На первом запуске каталог целиком закрепляется в порядке регистрации.
    func testFirstLaunchPinsCatalogInOrder() {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let snapshot = store.snapshot()

        XCTAssertEqual(ids(snapshot), ["a", "b", "c", "d"])
        XCTAssertTrue(snapshot.unpinned.isEmpty)
        XCTAssertEqual(snapshot.layoutItems.map { $0.id }, ids(snapshot))
        XCTAssertTrue(store.isPinned("a"))
    }

    /// pin/unpin консистентны: ярлык не может быть на сетке и в списке
    /// откреплённых одновременно, повторные вызовы возвращают `false`.
    func testPinAndUnpinKeepSnapshotConsistent() {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)

        XCTAssertFalse(store.pinTile("a", columns: columns))
        XCTAssertFalse(store.isPinned("missing"))
        XCTAssertFalse(store.pinTile("missing", columns: columns))
        XCTAssertFalse(store.unpin("missing", columns: columns))

        XCTAssertTrue(store.unpin("b", columns: columns))
        XCTAssertFalse(store.isPinned("b"))
        XCTAssertEqual(ids(store.snapshot()), ["a", "c", "d"])
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["b"])

        // Закрепление — новая строка в конце холста (D33): порядок чтения a, c, d, b.
        XCTAssertTrue(store.pinTile("b", columns: columns))
        XCTAssertEqual(ids(store.snapshot()), ["a", "c", "d", "b"])
        XCTAssertTrue(store.snapshot().unpinned.isEmpty)
        XCTAssertTrue(store.isPinned("b"))
    }

    /// Открепление последнего ярлыка папки распускает папку: плитка без
    /// содержимого не остаётся на сетке (§5).
    func testUnpinLastFolderTileDissolvesFolder() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", title: "A", columns: columns))

        // Папка 2×2 встаёт на ячейку «a» и выталкивает «b» вниз (D31).
        XCTAssertEqual(ids(store.snapshot()), [folder.id, "c", "d", "b"])

        XCTAssertTrue(store.unpin("a", columns: columns))
        XCTAssertNil(store.folderContaining("a"))
        XCTAssertEqual(ids(store.snapshot()), ["c", "d", "b"])
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["a"])
        XCTAssertFalse(store.isPinned("a"))
    }

    /// Ярлык из папки нельзя закрепить повторно: инвариант «один ярлык — одно
    /// место» (§6).
    func testPinRejectsTileThatLivesInFolder() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        _ = try XCTUnwrap(store.createFolder(withTile: "a", title: "A", columns: columns))

        XCTAssertFalse(store.pinTile("a", columns: columns))
        XCTAssertEqual(store.folderContaining("a")?.tiles.count, 1)
    }

    // MARK: - E12.2: размер новой папки (всегда medium)

    /// Папка всегда создаётся средней (W10M), независимо от размера ярлыка-цели
    /// (small/medium/wide/large, сохранённого или из дескриптора); размер
    /// переживает round-trip. Заменяет E11.4 (наследование размера).
    func testCreateFolderIsAlwaysMedium() throws {
        let directory = TesseraTestDirectory()
        // D45: папка из одного ярлыка при загрузке распускается, поэтому к трём
        // переходным папкам добавлено по второму ярлыку (кроме проверки размера
        // новой папки тест ничего не меняет).
        let descriptors = makeDescriptors() + ["e", "f", "g"].map { tesseraTestTile($0, size: .small) }
        let store = makeStore(descriptors, in: directory)

        let small = try XCTUnwrap(store.createFolder(withTile: "a", columns: columns))
        XCTAssertEqual(small.size, .medium)
        let medium = try XCTUnwrap(store.createFolder(withTile: "b", columns: columns))
        XCTAssertEqual(medium.size, .medium)

        XCTAssertTrue(store.resize("c", to: .wide, columns: columns))
        let wide = try XCTUnwrap(store.createFolder(withTile: "c", columns: columns))
        XCTAssertEqual(wide.size, .medium, "Сохранённый wide-размер ярлыка не наследуется")
        XCTAssertTrue(store.addToFolder("d", folderID: small.id, columns: columns))
        XCTAssertTrue(store.addToFolder("e", folderID: medium.id, columns: columns))
        XCTAssertTrue(store.addToFolder("f", folderID: wide.id, columns: columns))

        XCTAssertEqual(store.snapshot().folders.map { $0.size }, [.medium, .medium, .medium])

        try store.save()
        let restored = makeStore(descriptors, in: directory)
        try restored.load()
        XCTAssertEqual(restored.snapshot().folders.map { $0.size }, [.medium, .medium, .medium])
    }

    /// Атомарное создание из wide/large цели тоже даёт medium; сам размер
    /// папки пользователь может поменять (`resize`), и он сохраняется — в том
    /// числе у папок, записанных на диск при короткой жизни E11.4.
    func testAtomicCreateFromWideTargetIsMediumAndFolderStaysResizable() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        XCTAssertTrue(store.resize("a", to: .large, columns: columns))
        guard case .created(let folder) = store.createFolder(from: "b", onto: "a", columns: columns) else {
            return XCTFail("Создание должно пройти")
        }
        XCTAssertEqual(folder.size, .medium)

        XCTAssertTrue(store.resize(folder.id, to: .wide, columns: columns))
        try store.save()
        let restored = makeStore(makeDescriptors(), in: directory)
        try restored.load()
        XCTAssertEqual(restored.snapshot().folders.first?.size, .wide, "Сохранённый размер папки не трогаем")
    }

    // MARK: - E11.2/E14.4: вынос из папки на рабочий стол

    /// Вынос ярлыка из папки на ячейку: он встаёт на неё, папка остаётся с
    /// оставшимся содержимым. D45: в папке остаётся два ярлыка (после выноса из
    /// папки в три), поэтому она не распускается.
    func testExtractFromFolderLandsOnCell() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", columns: columns))
        XCTAssertTrue(store.addToFolder("b", folderID: folder.id, columns: columns))
        XCTAssertTrue(store.addToFolder("c", folderID: folder.id, columns: columns))
        XCTAssertEqual(ids(store.snapshot()), [folder.id, "d"])

        XCTAssertTrue(store.extractFromFolder("b", toCell: tesseraCell(2, 0), columns: columns))
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(2, 0))
        XCTAssertEqual(ids(store.snapshot()), [folder.id, "d", "b"])
        XCTAssertEqual(store.folderContaining("a")?.tiles.count, 2)
    }

    /// Вынос последнего ярлыка: папка исчезает, ярлык встаёт на указанную ячейку.
    func testExtractLastTileRemovesFolder() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "b", columns: columns))
        XCTAssertEqual(ids(store.snapshot()), ["a", folder.id, "c", "d"])

        XCTAssertTrue(store.extractFromFolder("b", toCell: tesseraCell(0, 1), columns: columns))
        XCTAssertEqual(ids(store.snapshot()), ["a", "b", "c", "d"])
        XCTAssertTrue(store.snapshot().folders.isEmpty)
    }

    /// Вынос в новую строку ставит ярлык после последней занятой строки.
    func testExtractFromFolderToNewRow() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", columns: columns))
        XCTAssertTrue(store.addToFolder("b", folderID: folder.id, columns: columns))
        XCTAssertTrue(store.addToFolder("c", folderID: folder.id, columns: columns))

        // D45: в папке из трёх остаётся два — она не распускается.
        XCTAssertTrue(store.extractFromFolderToNewRow("b", columns: columns))
        XCTAssertEqual(ids(store.snapshot()), [folder.id, "d", "b"])
        XCTAssertEqual(store.placement(of: "b")?.column, 0)
    }

    // MARK: - move / resize

    /// Перенос на ячейку зажимается холстом, неизвестные ярлыки и перенос на
    /// собственную ячейку — `false` (операция раскладки, без одобрения D14).
    func testMoveItemRejectsUnknownAndSameCell() {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)

        XCTAssertFalse(store.moveItem("a", toCell: tesseraCell(0, 0), columns: columns), "собственная ячейка")
        XCTAssertFalse(store.moveItem("missing", toCell: tesseraCell(1, 0), columns: columns))

        XCTAssertTrue(store.moveItem("a", toCell: tesseraCell(5, 99), columns: columns))
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(5, 5), "колонка зажата холстом")

        for id in ["a", "b", "c", "d"] {
            XCTAssertTrue(store.unpin(id, columns: columns))
        }
        XCTAssertFalse(store.moveItem("a", toCell: tesseraCell(0, 0), columns: columns))
    }

    /// resize меняет авторитетный размер ярлыка (D15), повтор — no-op,
    /// неизвестный идентификатор — `false`.
    func testResizeUpdatesAuthoritativeSizeAndIgnoresNoOps() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)

        for size in [TileSize.medium, .wide, .large, .small] {
            XCTAssertTrue(store.resize("a", to: size, columns: columns))
            XCTAssertEqual(store.descriptor(withID: "a")?.size, size)
            XCTAssertEqual(
                store.snapshot().items.first(where: { $0.id == AnyHashable("a") })?.size,
                size
            )
            XCTAssertFalse(store.resize("a", to: size, columns: columns))
        }

        XCTAssertFalse(store.resize("missing", to: .wide, columns: columns))
    }

    /// Папка тоже масштабируется; размер ярлыка внутри папки виден в её снимке.
    func testResizeFolderAndFolderTiles() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", title: "A", columns: columns))

        XCTAssertTrue(store.resize(folder.id, to: .wide, columns: columns))
        XCTAssertEqual(store.snapshot().folders.first?.size, .wide)
        XCTAssertFalse(store.resize(folder.id, to: .wide, columns: columns))

        XCTAssertTrue(store.resize("a", to: .large, columns: columns))
        XCTAssertEqual(store.folderContaining("a")?.tiles.first?.size, .large)
    }

    // MARK: - Персистентность

    /// Round-trip: порядок, размеры, папки и закрепления выживают запись и
    /// чтение JSON (§5).
    func testPersistenceRoundTripKeepsOrderSizesFoldersAndPins() throws {
        let directory = TesseraTestDirectory()
        let descriptors = makeDescriptors()

        let store = makeStore(descriptors, in: directory)
        XCTAssertTrue(store.unpin("d", columns: columns))
        XCTAssertTrue(store.resize("a", to: .wide, columns: columns))
        let folder = try XCTUnwrap(store.createFolder(withTile: "b", title: "Работа", columns: columns))
        XCTAssertTrue(store.addToFolder("c", folderID: folder.id, columns: columns))
        try store.save()
        XCTAssertNil(store.lastPersistenceError)

        let restored = makeStore(descriptors, in: directory)
        try restored.load()

        let snapshot = restored.snapshot()
        XCTAssertEqual(ids(snapshot), [AnyHashable("a"), folder.id])
        XCTAssertEqual(snapshot.folders.count, 1)
        XCTAssertEqual(snapshot.folders.first?.title, "Работа")
        XCTAssertEqual(
            snapshot.folders.first?.tiles.map { $0.id },
            [AnyHashable("b"), AnyHashable("c")]
        )
        XCTAssertEqual(restored.descriptor(withID: "a")?.size, .wide)
        XCTAssertEqual(snapshot.unpinned.map { $0.id }, [AnyHashable("d")])
        XCTAssertFalse(restored.isPinned("d"))

        // Второй round-trip: новое закрепление (новая строка) тоже переживает перезапуск.
        XCTAssertTrue(restored.pinTile("d", columns: columns))
        try restored.save()

        let restoredAgain = makeStore(descriptors, in: directory)
        try restoredAgain.load()
        XCTAssertEqual(
            ids(restoredAgain.snapshot()),
            [AnyHashable("a"), folder.id, AnyHashable("d")]
        )
    }

    /// При включённом автосохранении операция редактирования сразу пишет файл
    /// состояния (§5).
    func testAutosaveWritesStateFile() {
        let directory = TesseraTestDirectory()
        // Без `placeItems`: ширина сетки хранилищу ещё неизвестна, файла нет.
        let store = TileStore(directoryURL: directory.url)
        store.autosaves = true
        store.setCatalog(makeDescriptors())

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertTrue(store.unpin("a", columns: columns))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertNil(store.lastPersistenceError)
    }

    /// Ошибка записи не ломает модель: операция выполняется, а ошибка попадает
    /// в `lastPersistenceError`.
    func testPersistenceErrorIsRecordedWithoutBreakingState() throws {
        let directory = TesseraTestDirectory()
        // На месте каталога лежит файл — создать директорию невозможно.
        try Data("not a directory".utf8).write(to: directory.url)

        let store = TileStore(directoryURL: directory.url)
        store.autosaves = true
        store.setCatalog(makeDescriptors())

        XCTAssertTrue(store.resize("a", to: .wide, columns: columns))
        XCTAssertNotNil(store.lastPersistenceError)
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .wide)
        XCTAssertThrowsError(try store.save())
    }

    /// Испорченный файл: `load()` бросает ошибку и не меняет текущее состояние.
    func testLoadThrowsOnCorruptedFileAndKeepsState() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = makeStore(makeDescriptors(), in: directory)

        try Data("{ это не JSON".utf8).write(to: store.fileURL)
        let before = ids(store.snapshot())

        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(ids(store.snapshot()), before)
        XCTAssertTrue(store.isPinned("a"))
    }

    /// Файл новее текущей схемы не читается (§5, версионированный документ).
    func testLoadThrowsOnUnsupportedSchemaVersion() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = makeStore(makeDescriptors(), in: directory)

        let json = #"{"version":99,"items":[],"sizes":{},"folders":[]}"#
        try Data(json.utf8).write(to: store.fileURL)

        XCTAssertThrowsError(try store.load()) { error in
            guard let storeError = error as? TileStoreError else {
                return XCTFail("Ожидалась TileStoreError, пришло: \(error)")
            }
            switch storeError {
            case .unsupportedSchemaVersion(let version):
                XCTAssertEqual(version, 99)
            }
        }
    }

    // MARK: - Функция одобрения (D14)

    /// Хост получает правильные папку, ярлык и тип операции для всех трёх
    /// действий D14.
    func testApprovalReceivesCorrectFolderTileAndAction() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)

        var calls: [(folder: AnyHashable?, tile: AnyHashable, action: TileGroupingAction)] = []
        store.approval = { folder, tile, action in
            calls.append((folder?.id, tile.id, action))
            return true
        }

        let folderA = try XCTUnwrap(store.createFolder(withTile: "a", title: "A", columns: columns))
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(calls[0].folder)
        XCTAssertEqual(calls[0].tile, AnyHashable("a"))
        XCTAssertEqual(calls[0].action, .createFolder)

        XCTAssertTrue(store.addToFolder("b", folderID: folderA.id, columns: columns))
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].folder, folderA.id)
        XCTAssertEqual(calls[1].tile, AnyHashable("b"))
        XCTAssertEqual(calls[1].action, .addToFolder)

        let folderB = try XCTUnwrap(store.createFolder(withTile: "c", title: "B", columns: columns))
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[2].action, .createFolder)

        XCTAssertTrue(store.moveBetweenFolders("b", to: folderB.id, columns: columns))
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls[3].folder, folderB.id)
        XCTAssertEqual(calls[3].tile, AnyHashable("b"))
        XCTAssertEqual(calls[3].action, .moveBetweenFolders)

        XCTAssertTrue(store.extractFromFolderToNewRow("b", columns: columns))
        XCTAssertEqual(calls.count, 5)
        XCTAssertNil(calls[4].folder)
        XCTAssertEqual(calls[4].tile, AnyHashable("b"))
        XCTAssertEqual(calls[4].action, .moveBetweenFolders)
    }

    /// Отказ в создании папки не меняет состояние.
    func testDeniedCreateFolderLeavesStateUntouched() {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let before = ids(store.snapshot())

        store.approval = { _, _, action in action != .createFolder }

        XCTAssertNil(store.createFolder(withTile: "a", title: "A", columns: columns))
        XCTAssertEqual(ids(store.snapshot()), before)
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        XCTAssertTrue(store.isPinned("a"))
    }

    /// Отказ в добавлении ярлыка в папку оставляет ярлык на сетке.
    func testDeniedAddToFolderKeepsTileOnGrid() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", title: "A", columns: columns))

        store.approval = { _, _, action in action != .addToFolder }

        XCTAssertFalse(store.addToFolder("b", folderID: folder.id, columns: columns))
        XCTAssertEqual(ids(store.snapshot()), [folder.id, "c", "d", "b"], "«b» вытолкнут папкой вниз и остался на сетке")
        XCTAssertEqual(
            store.snapshot().folders.first?.tiles.map { $0.id },
            [AnyHashable("a")]
        )
    }

    /// Отказ в перемещении между папками оставляет ярлык в исходной папке.
    func testDeniedMoveBetweenFoldersKeepsTileInSourceFolder() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folderA = try XCTUnwrap(store.createFolder(withTile: "a", title: "A", columns: columns))
        let folderB = try XCTUnwrap(store.createFolder(withTile: "b", title: "B", columns: columns))
        XCTAssertTrue(store.addToFolder("c", folderID: folderA.id, columns: columns))

        store.approval = { _, _, action in action != .moveBetweenFolders }

        XCTAssertFalse(store.moveBetweenFolders("c", to: folderB.id, columns: columns))
        XCTAssertEqual(store.folderContaining("c")?.id, folderA.id)
        XCTAssertEqual(
            store.snapshot().folders.first(where: { $0.id == folderB.id })?.tiles.map { $0.id },
            [AnyHashable("b")]
        )
    }

    /// Перемещение на рабочий стол (`nil`) проходит через то же одобрение D14.
    /// D45: обе исходные папки теряют ярлык и остаются с одним — распускаются, а
    /// ярлыки встают на ячейки папок; вынесенный ярлык — в новой строке в конце.
    func testMoveBetweenFoldersReturnsTileToDesktopAndDissolvesFolders() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folderA = try XCTUnwrap(store.createFolder(withTile: "a", title: "A", columns: columns))
        let folderB = try XCTUnwrap(store.createFolder(withTile: "b", title: "B", columns: columns))
        XCTAssertTrue(store.addToFolder("c", folderID: folderA.id, columns: columns))

        // Из папки A уходит «c»: в ней остаётся «a» — папка распускается.
        XCTAssertTrue(store.moveBetweenFolders("c", to: folderB.id, columns: columns))
        XCTAssertNil(store.folderContaining("a"))
        XCTAssertEqual(store.folderContaining("c")?.id, folderB.id)
        // Из папки B уходит «c»: остаётся «b» — тоже распускается.
        XCTAssertTrue(store.extractFromFolderToNewRow("c", columns: columns))

        XCTAssertTrue(store.snapshot().folders.isEmpty)
        XCTAssertNil(store.folderContaining("c"))
        XCTAssertEqual(Set(ids(store.snapshot())), ["a", "b", "c", "d"])
        // E14.6: вынос без ячейки — новая строка в конце холста; порядок — по ячейкам.
        XCTAssertEqual(ids(store.snapshot()).last, "c")
        XCTAssertTrue(store.isPinned("c"))
    }

    /// Перемещение в ту же папку отклоняется до вызова одобрения: хост не
    /// получает бессмысленную операцию.
    func testMoveBetweenFoldersRejectsSameFolderWithoutApproval() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)

        var approvalCalls = 0
        store.approval = { _, _, _ in
            approvalCalls += 1
            return true
        }

        let folder = try XCTUnwrap(store.createFolder(withTile: "a", title: "A", columns: columns))
        XCTAssertEqual(approvalCalls, 1)

        XCTAssertFalse(store.moveBetweenFolders("a", to: folder.id, columns: columns))
        XCTAssertEqual(approvalCalls, 1)
        XCTAssertEqual(store.folderContaining("a")?.id, folder.id)
    }
}

#endif
