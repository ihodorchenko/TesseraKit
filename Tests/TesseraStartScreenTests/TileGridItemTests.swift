//
//  TileGridItemTests.swift
//  TesseraStartScreenTests
//
//  Тесты элемента сетки рабочего стола (задача E7.4, решение D17).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка»;
//  D17 в docs/STATE.md — панель раскрытой папки `folderContent` живёт в том же
//  перечислении, что ярлык и папка, но не является элементом данных.
//
//  Проверяются идентичность, размер, «видовые» свойства и switch по всем трём
//  случаям: добавление нового case не должно ломать обработчики хоста. Модель —
//  чистое значение, поэтому UIKit-цикл не нужен.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileGridItemTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Папка с двумя ярлыками для проверок идентичности и содержимого.
    ///
    /// - Returns: Модель папки «f» с ярлыками «a» и «b».
    private func makeFolder() -> TesseraTileFolder {
        TesseraTileFolder(
            id: "f",
            title: "Папка",
            tiles: [tesseraTestTile("a"), tesseraTestTile("b")]
        )
    }

    /// Человекочитаемое имя случая — ровно то, что делает хост в switch.
    ///
    /// Если у `TesseraTileGridItem` появится четвёртый case, этот switch перестанет
    /// компилироваться: тест ловит несовместимость на этапе сборки.
    ///
    /// - Parameter item: Элемент сетки.
    /// - Returns: Имя случая.
    private func describe(_ item: TesseraTileGridItem) -> String {
        switch item {
        case .tile:
            return "tile"
        case .folder:
            return "folder"
        case .folderContent:
            return "folderContent"
        }
    }

    // MARK: - Новый case folderContent (D17)

    /// Панель наследует идентификатор папки: по нему раскладка находит строку
    /// папки, после которой встаёт панель (D17: панель вставляется под плитку).
    func testFolderContentSharesIdentityWithFolder() {
        let folder = makeFolder()
        let panel = TesseraTileGridItem.folderContent(folder)

        XCTAssertEqual(panel.id, folder.id)
        XCTAssertEqual(panel.panelFolder?.id, folder.id)
        XCTAssertEqual(
            panel.panelFolder?.tiles.map { $0.id },
            [AnyHashable("a"), AnyHashable("b")]
        )
    }

    /// Панель — не ярлык и не плитка-папка: только `panelFolder`.
    func testFolderContentIsNeitherTileNorFolder() {
        let folder = makeFolder()
        let panel = TesseraTileGridItem.folderContent(folder)

        XCTAssertNil(panel.tile)
        XCTAssertNil(panel.folder)
        XCTAssertNotNil(panel.panelFolder)
    }

    /// Собственного размера у панели нет: `.wide` — метка «полная ширина».
    /// Раскладка не упаковывает панель по этой метке: панель — отдельная
    /// полноширинная строка под папкой, а не плитка.
    func testFolderContentUsesWideSizeAsFullWidthMarker() {
        let panel = TesseraTileGridItem.folderContent(makeFolder())

        XCTAssertEqual(panel.size, .wide)
        XCTAssertEqual(panel.size.unitColumns, 4)
        XCTAssertEqual(panel.size.unitRows, 2)
    }

    /// `folderTiles` панели пуст: содержимое доступно через `panelFolder`,
    /// чтобы одна папка не считалась дважды при обходе снимка.
    func testFolderContentExposesNoTilesOfItsOwn() {
        let panel = TesseraTileGridItem.folderContent(makeFolder())

        XCTAssertTrue(panel.folderTiles.isEmpty)
        XCTAssertEqual(panel.panelFolder?.tiles.count, 2)
    }

    /// Признак панели отличает её от плитки-папки с тем же идентификатором.
    func testIsFolderPanelDistinguishesPanelFromFolder() {
        let folder = makeFolder()

        XCTAssertTrue(TesseraTileGridItem.folderContent(folder).isFolderPanel)
        XCTAssertFalse(TesseraTileGridItem.folder(folder).isFolderPanel)
        XCTAssertFalse(TesseraTileGridItem.tile(tesseraTestTile("a")).isFolderPanel)
    }

    /// Папка и панель делят идентификатор, но остаются разными случаями: в
    /// наборе они стоят рядом (панель после плитки), а сравнение по `id` не
    /// путает данные с UI-состоянием.
    func testFolderAndPanelShareIDButRemainDistinctCases() {
        let folder = makeFolder()
        let panel = TesseraTileGridItem.folderContent(folder)
        let item = TesseraTileGridItem.folder(folder)

        XCTAssertEqual(panel.id, item.id)

        // Сравнение по идентификатору не должно означать «тот же элемент»:
        // у панели `folder` = nil, у плитки-папки `panelFolder` = nil.
        XCTAssertNotEqual(panel.id, AnyHashable("other"))
        XCTAssertNil(panel.folder)
        XCTAssertNil(item.panelFolder)
    }

    /// Существующие случаи сохраняют прежнюю семантику (совместимость API).
    func testFolderAndTileCasesKeepTheirPayload() {
        let folder = makeFolder()
        let item = TesseraTileGridItem.folder(folder)
        let tile = tesseraTestTile("x", size: .large, badge: .dot)
        let tileItem = TesseraTileGridItem.tile(tile)

        XCTAssertEqual(item.id, folder.id)
        XCTAssertEqual(item.size, folder.size)
        XCTAssertEqual(item.folder?.id, folder.id)
        XCTAssertEqual(item.folderTiles.map { $0.id }, [AnyHashable("a"), AnyHashable("b")])

        XCTAssertEqual(tileItem.id, tile.id)
        XCTAssertEqual(tileItem.size, .large)
        XCTAssertEqual(tileItem.tile?.id, tile.id)
        XCTAssertEqual(tileItem.tile?.badge, .dot)
        XCTAssertNil(tileItem.folder)
    }

    /// Switch по трём случаям исчерпывающий и различает все три вида.
    func testSwitchCoversAllCases() {
        let folder = makeFolder()
        let items: [TesseraTileGridItem] = [
            .tile(tesseraTestTile("a")),
            .folder(folder),
            .folderContent(folder),
        ]

        XCTAssertEqual(items.map(describe), ["tile", "folder", "folderContent"])
    }

    // MARK: - Панель в снимке

    /// Снимок не считает панель данными: `layoutItems` и `folders` её
    /// пропускают, а `item(withID:)` возвращает первую запись с этим
    /// идентификатором. На практике снимок `TesseraTileStore` панель не содержит —
    /// тест страхует хосты, которые всё же положат её в набор.
    func testSnapshotExcludesPanelFromLayoutAndFolders() {
        let folder = makeFolder()
        let snapshot = TesseraTileGridSnapshot(
            items: [
                .folder(folder),
                .folderContent(folder),
            ],
            unpinned: []
        )

        XCTAssertEqual(snapshot.layoutItems.map { $0.id }, [folder.id])
        XCTAssertEqual(snapshot.folders.map { $0.id }, [folder.id])
        XCTAssertEqual(snapshot.item(withID: folder.id)?.folder?.id, folder.id)
        XCTAssertFalse(snapshot.item(withID: folder.id)?.isFolderPanel ?? true)
        XCTAssertEqual(snapshot.items.count, 2)
    }
}

#endif
