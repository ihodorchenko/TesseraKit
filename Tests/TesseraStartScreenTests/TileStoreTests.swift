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

        XCTAssertFalse(store.pin("a"))
        XCTAssertFalse(store.isPinned("missing"))
        XCTAssertFalse(store.pin("missing"))
        XCTAssertFalse(store.unpin("missing"))

        XCTAssertTrue(store.unpin("b"))
        XCTAssertFalse(store.isPinned("b"))
        XCTAssertEqual(ids(store.snapshot()), ["a", "c", "d"])
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["b"])

        XCTAssertTrue(store.pin("b", at: 0))
        XCTAssertEqual(ids(store.snapshot()), ["b", "a", "c", "d"])
        XCTAssertTrue(store.snapshot().unpinned.isEmpty)
        XCTAssertTrue(store.isPinned("b"))
    }

    /// Открепление последнего ярлыка папки распускает папку: плитка без
    /// содержимого не остаётся на сетке (§5).
    func testUnpinLastFolderTileDissolvesFolder() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", title: "A"))

        XCTAssertEqual(ids(store.snapshot()), [folder.id, "b", "c", "d"])

        XCTAssertTrue(store.unpin("a"))
        XCTAssertNil(store.folderContaining("a"))
        XCTAssertEqual(ids(store.snapshot()), ["b", "c", "d"])
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["a"])
        XCTAssertFalse(store.isPinned("a"))
    }

    /// Ярлык из папки нельзя закрепить повторно: инвариант «один ярлык — одно
    /// место» (§6).
    func testPinRejectsTileThatLivesInFolder() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        _ = try XCTUnwrap(store.createFolder(withTile: "a", title: "A"))

        XCTAssertFalse(store.pin("a"))
        XCTAssertEqual(store.folderContaining("a")?.tiles.count, 1)
    }

    // MARK: - E11.4: размер новой папки

    /// Папка наследует размер ярлыка-цели (сохранённый или из дескриптора) и
    /// переживает round-trip персистентности.
    func testCreateFolderInheritsTileSize() throws {
        let directory = TesseraTestDirectory()
        let descriptors = makeDescriptors()
        let store = makeStore(descriptors, in: directory)

        let small = try XCTUnwrap(store.createFolder(withTile: "a"))
        XCTAssertEqual(small.size, .small)
        let medium = try XCTUnwrap(store.createFolder(withTile: "b"))
        XCTAssertEqual(medium.size, .medium)

        XCTAssertTrue(store.resize("c", to: .wide))
        let wide = try XCTUnwrap(store.createFolder(withTile: "c"))
        XCTAssertEqual(wide.size, .wide, "Сохранённый размер ярлыка важнее дескриптора")

        let folderSizes = Dictionary(
            uniqueKeysWithValues: store.snapshot().folders.map { ($0.id, $0.size) }
        )
        XCTAssertEqual(folderSizes[small.id], .small)
        XCTAssertEqual(folderSizes[medium.id], .medium)
        XCTAssertEqual(folderSizes[wide.id], .wide)

        try store.save()
        let restored = makeStore(descriptors, in: directory)
        try restored.load()
        XCTAssertEqual(
            Set(restored.snapshot().folders.map { $0.size }),
            [.small, .medium, .wide]
        )
    }

    // MARK: - E11.2: вынос из папки на рабочий стол

    /// По умолчанию ярлык встаёт сразу после папки-источника, а не в конец.
    func testMoveOutOfFolderLandsRightAfterFolder() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a"))
        XCTAssertTrue(store.addToFolder("b", folderID: folder.id))
        XCTAssertEqual(ids(store.snapshot()), [folder.id, "c", "d"])

        XCTAssertTrue(store.moveBetweenFolders("b", to: nil))
        XCTAssertEqual(ids(store.snapshot()), [folder.id, "b", "c", "d"])
        XCTAssertEqual(store.folderContaining("a")?.tiles.count, 1)
    }

    /// Вынос последнего ярлыка: папка распадается, ярлык занимает её место.
    func testMoveOutLastTileTakesFolderPlace() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "b"))
        XCTAssertEqual(ids(store.snapshot()), ["a", folder.id, "c", "d"])

        XCTAssertTrue(store.moveBetweenFolders("b", to: nil))
        XCTAssertEqual(ids(store.snapshot()), ["a", "b", "c", "d"])
        XCTAssertTrue(store.snapshot().folders.isEmpty)
    }

    /// Явный индекс задаёт позицию в видимом порядке; значение зажимается.
    func testMoveOutOfFolderToExplicitIndex() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a"))
        XCTAssertTrue(store.addToFolder("b", folderID: folder.id))

        XCTAssertTrue(store.moveBetweenFolders("b", to: nil, at: 2))
        XCTAssertEqual(ids(store.snapshot()), [folder.id, "c", "b", "d"])

        XCTAssertTrue(store.moveBetweenFolders("a", to: nil, at: 99))
        XCTAssertEqual(ids(store.snapshot()), ["c", "b", "d", "a"])
    }

    // MARK: - move / resize

    /// Перестановка зажимает индекс и не трогает неизвестные ярлыки; перестановка
    /// в тот же индекс — no-op (операция раскладки, без одобрения D14).
    func testMoveClampsToBoundsAndRejectsUnknown() {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)

        XCTAssertTrue(store.move("a", toIndex: 99))
        XCTAssertEqual(ids(store.snapshot()), ["b", "c", "d", "a"])

        XCTAssertTrue(store.move("a", toIndex: -5))
        XCTAssertEqual(ids(store.snapshot()), ["a", "b", "c", "d"])

        XCTAssertFalse(store.move("a", toIndex: 0))
        XCTAssertFalse(store.move("missing", toIndex: 1))

        XCTAssertTrue(store.unpin("a"))
        XCTAssertTrue(store.unpin("b"))
        XCTAssertTrue(store.unpin("c"))
        XCTAssertTrue(store.unpin("d"))
        XCTAssertFalse(store.move("a", toIndex: 0))
    }

    /// resize меняет авторитетный размер ярлыка (D15), повтор — no-op,
    /// неизвестный идентификатор — `false`.
    func testResizeUpdatesAuthoritativeSizeAndIgnoresNoOps() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)

        for size in [TileSize.medium, .wide, .large, .small] {
            XCTAssertTrue(store.resize("a", to: size))
            XCTAssertEqual(store.descriptor(withID: "a")?.size, size)
            XCTAssertEqual(
                store.snapshot().items.first(where: { $0.id == AnyHashable("a") })?.size,
                size
            )
            XCTAssertFalse(store.resize("a", to: size))
        }

        XCTAssertFalse(store.resize("missing", to: .wide))
    }

    /// Папка тоже масштабируется; размер ярлыка внутри папки виден в её снимке.
    func testResizeFolderAndFolderTiles() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", title: "A"))

        XCTAssertTrue(store.resize(folder.id, to: .wide))
        XCTAssertEqual(store.snapshot().folders.first?.size, .wide)
        XCTAssertFalse(store.resize(folder.id, to: .wide))

        XCTAssertTrue(store.resize("a", to: .large))
        XCTAssertEqual(store.folderContaining("a")?.tiles.first?.size, .large)
    }

    // MARK: - Персистентность

    /// Round-trip: порядок, размеры, папки и закрепления выживают запись и
    /// чтение JSON (§5).
    func testPersistenceRoundTripKeepsOrderSizesFoldersAndPins() throws {
        let directory = TesseraTestDirectory()
        let descriptors = makeDescriptors()

        let store = makeStore(descriptors, in: directory)
        XCTAssertTrue(store.unpin("d"))
        XCTAssertTrue(store.resize("a", to: .wide))
        let folder = try XCTUnwrap(store.createFolder(withTile: "b", title: "Работа"))
        XCTAssertTrue(store.addToFolder("c", folderID: folder.id))
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

        // Второй round-trip: новое закрепление тоже переживает перезапуск.
        XCTAssertTrue(restored.pin("d", at: 0))
        try restored.save()

        let restoredAgain = makeStore(descriptors, in: directory)
        try restoredAgain.load()
        XCTAssertEqual(
            ids(restoredAgain.snapshot()),
            [AnyHashable("d"), AnyHashable("a"), folder.id]
        )
    }

    /// При включённом автосохранении операция редактирования сразу пишет файл
    /// состояния (§5).
    func testAutosaveWritesStateFile() {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory, autosaves: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertTrue(store.unpin("a"))
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

        XCTAssertTrue(store.resize("a", to: .wide))
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

        let folderA = try XCTUnwrap(store.createFolder(withTile: "a", title: "A"))
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(calls[0].folder)
        XCTAssertEqual(calls[0].tile, AnyHashable("a"))
        XCTAssertEqual(calls[0].action, .createFolder)

        XCTAssertTrue(store.addToFolder("b", folderID: folderA.id))
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].folder, folderA.id)
        XCTAssertEqual(calls[1].tile, AnyHashable("b"))
        XCTAssertEqual(calls[1].action, .addToFolder)

        let folderB = try XCTUnwrap(store.createFolder(withTile: "c", title: "B"))
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[2].action, .createFolder)

        XCTAssertTrue(store.moveBetweenFolders("b", to: folderB.id))
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls[3].folder, folderB.id)
        XCTAssertEqual(calls[3].tile, AnyHashable("b"))
        XCTAssertEqual(calls[3].action, .moveBetweenFolders)

        XCTAssertTrue(store.moveBetweenFolders("b", to: nil))
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

        XCTAssertNil(store.createFolder(withTile: "a", title: "A"))
        XCTAssertEqual(ids(store.snapshot()), before)
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        XCTAssertTrue(store.isPinned("a"))
    }

    /// Отказ в добавлении ярлыка в папку оставляет ярлык на сетке.
    func testDeniedAddToFolderKeepsTileOnGrid() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", title: "A"))

        store.approval = { _, _, action in action != .addToFolder }

        XCTAssertFalse(store.addToFolder("b", folderID: folder.id))
        XCTAssertEqual(ids(store.snapshot()), [folder.id, "b", "c", "d"])
        XCTAssertEqual(
            store.snapshot().folders.first?.tiles.map { $0.id },
            [AnyHashable("a")]
        )
    }

    /// Отказ в перемещении между папками оставляет ярлык в исходной папке.
    func testDeniedMoveBetweenFoldersKeepsTileInSourceFolder() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folderA = try XCTUnwrap(store.createFolder(withTile: "a", title: "A"))
        let folderB = try XCTUnwrap(store.createFolder(withTile: "b", title: "B"))
        XCTAssertTrue(store.addToFolder("c", folderID: folderA.id))

        store.approval = { _, _, action in action != .moveBetweenFolders }

        XCTAssertFalse(store.moveBetweenFolders("c", to: folderB.id))
        XCTAssertEqual(store.folderContaining("c")?.id, folderA.id)
        XCTAssertEqual(
            store.snapshot().folders.first(where: { $0.id == folderB.id })?.tiles.map { $0.id },
            [AnyHashable("b")]
        )
    }

    /// Перемещение на рабочий стол (`nil`) проходит через то же одобрение D14 и
    /// распускает опустевшую исходную папку.
    func testMoveBetweenFoldersReturnsTileToDesktopAndDissolvesEmptyFolder() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folderA = try XCTUnwrap(store.createFolder(withTile: "a", title: "A"))
        let folderB = try XCTUnwrap(store.createFolder(withTile: "b", title: "B"))
        XCTAssertTrue(store.addToFolder("c", folderID: folderA.id))

        XCTAssertTrue(store.moveBetweenFolders("c", to: folderB.id))
        XCTAssertTrue(store.moveBetweenFolders("c", to: nil))

        XCTAssertNil(store.folderContaining("c"))
        XCTAssertEqual(store.folderContaining("a")?.id, folderA.id)
        XCTAssertEqual(store.folderContaining("b")?.id, folderB.id)
        // E11.2: ярлык встаёт сразу после папки-источника, а не в конец сетки.
        XCTAssertEqual(ids(store.snapshot()), [folderA.id, folderB.id, "c", "d"].map { AnyHashable($0) })
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

        let folder = try XCTUnwrap(store.createFolder(withTile: "a", title: "A"))
        XCTAssertEqual(approvalCalls, 1)

        XCTAssertFalse(store.moveBetweenFolders("a", to: folder.id))
        XCTAssertEqual(approvalCalls, 1)
        XCTAssertEqual(store.folderContaining("a")?.id, folder.id)
    }

    /// Алиас `move(_:toFolder:)` ведёт себя как `moveBetweenFolders`.
    func testMoveToFolderAliasMatchesMoveBetweenFolders() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folderA = try XCTUnwrap(store.createFolder(withTile: "a", title: "A"))
        let folderB = try XCTUnwrap(store.createFolder(withTile: "b", title: "B"))

        XCTAssertTrue(store.move("a", toFolder: folderB.id))
        XCTAssertEqual(store.folderContaining("a")?.id, folderB.id)

        XCTAssertTrue(store.move("a", toFolder: nil))
        XCTAssertNil(store.folderContaining("a"))
        XCTAssertTrue(store.isPinned("a"))
        XCTAssertNotEqual(folderA.id, folderB.id)
    }
}

#endif
