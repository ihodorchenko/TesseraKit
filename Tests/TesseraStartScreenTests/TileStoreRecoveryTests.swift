//
//  TileStoreRecoveryTests.swift
//  TesseraStartScreenTests
//
//  Тесты восстановления состояния `TesseraTileStore` (W2: E10.3c, E10.3d).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §5 «Режим
//  редактирования» (персистентность), §6 (один источник истины, pin/unpin) и
//  «Отступления реализации»; план — docs/PLAN.md, раздел «E9–E10».
//
//  Проверяются:
//  - «мёртвые» папки: после `setCatalog` → `load()` папка без единого ярлыка
//    каталога распускается, неизвестные ярлыки из папок убираются; результат
//    не зависит от порядка вызовов `setCatalog`/`load` (E10.3c);
//  - «сиротские» папки (есть в `folders` файла, нет в `items`) встают в конец
//    сетки, их ярлыки не теряются; инварианты «ярлык в одном месте» и
//    согласованность `isPinned`/`pin`/`unpinned` (E10.3c);
//  - повреждённый файл и файл более новой схемы откладываются в резервную
//    копию до первой записи, а автосохранение пишет новый файл (E10.3d).
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileStoreRecoveryTests: XCTestCase {

    // MARK: - Вспомогательные средства

    private func catalog(_ ids: [String]) -> [TesseraTileDescriptor] {
        ids.map { tesseraTestTile($0, size: .small) }
    }

    private func makeStore(
        _ descriptors: [TesseraTileDescriptor],
        in directory: TesseraTestDirectory,
        autosaves: Bool = false
    ) -> TesseraTileStore {
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = autosaves
        store.setCatalog(descriptors)
        return store
    }

    private func ids(_ store: TesseraTileStore) -> [AnyHashable] {
        store.snapshot().items.map { $0.id }
    }

    /// Файлы резервных копий в каталоге хранилища.
    private func backupFiles(in directory: TesseraTestDirectory) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory.url, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("tiles.unreadable-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Инварианты модели: идентификаторы элементов уникальны; каждый ярлык
    /// каталога ровно в одном месте (сетка, одна папка или список
    /// откреплённых); `isPinned` согласован с `unpinned`; ни одна папка в
    /// снимке не пуста.
    private func assertInvariants(
        _ store: TesseraTileStore,
        catalogIDs: [AnyHashable],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let snapshot = store.snapshot()
        let itemIDs = snapshot.items.map { $0.id }
        XCTAssertEqual(Set(itemIDs).count, itemIDs.count, "дубликаты на сетке", file: file, line: line)

        var places: [AnyHashable: Int] = [:]
        for item in snapshot.items {
            if let tile = item.tile { places[tile.id, default: 0] += 1 }
            for tile in item.folderTiles { places[tile.id, default: 0] += 1 }
        }
        for tile in snapshot.unpinned { places[tile.id, default: 0] += 1 }
        for id in catalogIDs {
            XCTAssertEqual(places[id], 1, "ярлык \(id) должен быть ровно в одном месте", file: file, line: line)
        }

        let unpinned = Set(snapshot.unpinned.map { $0.id })
        for id in catalogIDs {
            XCTAssertEqual(store.isPinned(id), !unpinned.contains(id), "isPinned(\(id))", file: file, line: line)
        }
        for folder in snapshot.folders {
            XCTAssertFalse(folder.tiles.isEmpty, "пустая папка \(folder.id) на сетке", file: file, line: line)
        }
    }

    /// Сохраняет файл с папкой [B, C] на месте B: порядок [A, папка, D].
    private func saveLayoutWithFolder(in directory: TesseraTestDirectory) throws -> AnyHashable {
        let store = makeStore(catalog(["a", "b", "c", "d"]), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "b", title: "F", columns: 6))
        XCTAssertTrue(store.addToFolder("c", folderID: folder.id, columns: 6))
        try store.save()
        return folder.id
    }

    // MARK: - E10.3c: «мёртвые» папки

    /// Все ярлыки папки пропали из каталога: после `setCatalog` → `load()`
    /// папка распускается, а не остаётся пустой плиткой.
    func testLoadDissolvesFolderWithoutCatalogTiles() throws {
        let directory = TesseraTestDirectory()
        _ = try saveLayoutWithFolder(in: directory)

        let store = makeStore(catalog(["a", "d"]), in: directory)
        try store.load()

        XCTAssertEqual(ids(store), ["a", "d"])
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        assertInvariants(store, catalogIDs: ["a", "d"])
    }

    /// Часть ярлыков папки осталась в каталоге. D45: в папке остался один ярлык —
    /// она распускается, ярлык «c» встаёт на её место (раньше папка оставалась с
    /// одним ярлыком).
    func testLoadPrunesUnknownTilesFromFolder() throws {
        let directory = TesseraTestDirectory()
        _ = try saveLayoutWithFolder(in: directory)

        let store = makeStore(catalog(["a", "c", "d"]), in: directory)
        try store.load()

        XCTAssertEqual(ids(store), ["a", "c", "d"])
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        assertInvariants(store, catalogIDs: ["a", "c", "d"])
    }

    /// Порядок вызовов не влияет на папки: `load()` до `setCatalog` даёт тот
    /// же результат.
    func testLoadBeforeCatalogGivesSameResult() throws {
        let directory = TesseraTestDirectory()
        _ = try saveLayoutWithFolder(in: directory)

        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        try store.load()
        store.setCatalog(catalog(["a", "d"]))

        XCTAssertEqual(ids(store), ["a", "d"])
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        assertInvariants(store, catalogIDs: ["a", "d"])
    }

    // MARK: - E10.3c: «сиротские» папки

    /// Папка есть в `folders`, но не в `items`: она встаёт в конец сетки, её
    /// ярлыки остаются в ней, а не «висят» откреплёнными, которых нельзя
    /// закрепить.
    func testOrphanFolderIsAppendedToGrid() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let json = """
        {
          "version": 1,
          "items": [{"kind": "tile", "key": "s:a"}],
          "sizes": {},
          "folders": [
            {"key": "s:orphan", "title": "O", "size": "medium", "tileKeys": ["s:b", "s:c"]}
          ]
        }
        """
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        try Data(json.utf8).write(to: store.fileURL)
        store.setCatalog(catalog(["a", "b", "c", "d"]))
        try store.load()

        XCTAssertEqual(ids(store), ["a", "orphan"])
        XCTAssertEqual(store.snapshot().folders.first?.tiles.map { $0.id }, ["b", "c"])
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["d"])
        XCTAssertTrue(store.isPinned("b"))
        XCTAssertFalse(store.pinTile("b", columns: 6), "ярлык из папки не закрепляется второй раз")
        assertInvariants(store, catalogIDs: ["a", "b", "c", "d"])
    }

    /// Испорченные ссылки в файле: ярлык и на сетке, и в папке; папка в
    /// папке; дубликаты — модель всё равно согласована.
    func testLoadRepairsInconsistentFolderReferences() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let json = """
        {
          "version": 1,
          "items": [
            {"kind": "tile", "key": "s:a"},
            {"kind": "folder", "key": "s:f1"},
            {"kind": "tile", "key": "s:b"},
            {"kind": "tile", "key": "s:a"}
          ],
          "sizes": {},
          "folders": [
            {"key": "s:f1", "title": "F1", "size": "medium", "tileKeys": ["s:b", "s:f2", "s:c"]},
            {"key": "s:f2", "title": "F2", "size": "medium", "tileKeys": ["s:c", "s:d"]}
          ]
        }
        """
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        try Data(json.utf8).write(to: store.fileURL)
        store.setCatalog(catalog(["a", "b", "c", "d", "e"]))
        try store.load()

        // D45: у «f2» после чистки дубликата остался один ярлык «d» — папка
        // распускается, «d» встаёт на её место.
        XCTAssertEqual(ids(store), ["a", "f1", "d"])
        XCTAssertEqual(store.snapshot().folders.map { $0.tiles.map { $0.id } }, [["b", "c"]])
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["e"])
        assertInvariants(store, catalogIDs: ["a", "b", "c", "d", "e"])
    }

    // MARK: - E10.3d: нечитаемый файл

    /// Повреждённый JSON: `load()` бросает ошибку, файл до любой записи
    /// отложен в резервную копию с исходными байтами, а автосохранение пишет
    /// новый читаемый файл.
    func testCorruptedFileIsBackedUpBeforeAutosave() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let original = Data("{ это не JSON".utf8)
        let store = makeStore(catalog(["a", "b", "c"]), in: directory, autosaves: true)
        try original.write(to: store.fileURL)

        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(ids(store), ["a", "b", "c"], "приложение работает с текущим состоянием")

        let backups = try backupFiles(in: directory)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))

        XCTAssertTrue(store.unpin("b", columns: 6))
        XCTAssertNil(store.lastPersistenceError)
        let reloaded = makeStore(catalog(["a", "b", "c"]), in: directory)
        XCTAssertNoThrow(try reloaded.load())
        XCTAssertEqual(ids(reloaded), ["a", "c"])
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first)), original)
    }

    /// Файл более новой схемы (версия текущей + 1) не затирается схемой v2.
    func testNewerSchemaFileIsBackedUpBeforeAutosave() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        // Текущая схема — 2 (`TesseraTileStore.schemaVersion`, E14.1), файл записан версией 3.
        let original = Data(#"{"version":3,"items":[],"sizes":{},"folders":[],"future":true}"#.utf8)
        let store = makeStore(catalog(["a", "b"]), in: directory, autosaves: true)
        try original.write(to: store.fileURL)

        XCTAssertThrowsError(try store.load()) { error in
            guard case TesseraTileStoreError.unsupportedSchemaVersion(let version)? = error as? TesseraTileStoreError else {
                return XCTFail("Ожидалась unsupportedSchemaVersion, пришло: \(error)")
            }
            XCTAssertEqual(version, 3)
        }

        let backups = try backupFiles(in: directory)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first)), original)

        XCTAssertTrue(store.resize("a", to: .wide, columns: 6))
        let written = try Data(contentsOf: store.fileURL)
        XCTAssertNotEqual(written, original)
        let reloaded = makeStore(catalog(["a", "b"]), in: directory)
        XCTAssertNoThrow(try reloaded.load())
        XCTAssertEqual(reloaded.descriptor(withID: "a")?.size, .wide)
    }

    /// Существующая резервная копия не перезаписывается: новая получает
    /// суффикс; имя — `<имя>.unreadable-<ISO-дата>.json`.
    func testBackupDoesNotOverwriteExistingCopy() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = makeStore(catalog(["a"]), in: directory, autosaves: true)
        store.currentDate = { Date(timeIntervalSince1970: 1_793_361_600) } // 2026-10-30T12:00:00Z

        let existing = directory.url.appendingPathComponent("tiles.unreadable-2026-10-30T12-00-00Z.json")
        let older = Data("older backup".utf8)
        try older.write(to: existing)

        let original = Data("not json".utf8)
        try original.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())

        let backupURL = try XCTUnwrap(store.lastUnreadableFileBackupURL)
        XCTAssertEqual(backupURL.lastPathComponent, "tiles.unreadable-2026-10-30T12-00-00Z-2.json")
        XCTAssertEqual(try Data(contentsOf: backupURL), original)
        XCTAssertEqual(try Data(contentsOf: existing), older)
    }

    /// Ошибка ввода-вывода не является «нечитаемым содержимым»: отсутствующий
    /// файл — первый запуск, копия не создаётся.
    func testMissingFileCreatesNoBackup() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = makeStore(catalog(["a"]), in: directory)
        XCTAssertNoThrow(try store.load())
        XCTAssertNil(store.lastUnreadableFileBackupURL)
        XCTAssertTrue(try backupFiles(in: directory).isEmpty)
    }
}

#endif
