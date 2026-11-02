//
//  TileGridAccessibilityTests.swift
//  TesseraStartScreenTests
//
//  VoiceOver-подписи сетки (E9.8в, волна W3 плана E9/E10).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §4 «Live-плитки»
//  (фронт/бэк контентной модели) и §9 «Accessibility» (плитка — один элемент:
//  label — заголовок, value — счётчик бэйджа; ярлык панели раскрытой папки —
//  тот же путь).
//
//  E9.8в: label live-плитки строится из `liveContent.frontFace` — заголовок и
//  подпись через запятую, — потому что VoiceOver должен читать то, что видно на
//  лицевой стороне, а не статичный заголовок ярлыка. value по-прежнему берётся
//  из бэйджа.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileGridAccessibilityTests: XCTestCase {

    // MARK: - Live-плитки (E9.8в)

    /// Label живой плитки — заголовок и подпись фронта через запятую; value —
    /// счётчик бэйджа, как у статичной плитки.
    func testLiveTileLabelComesFromFrontFaceAndValueFromBadge() {
        let live = tesseraTestLiveTile(
            "weather",
            front: TesseraLiveTileFace(title: "Погода", detail: "Минск, +12°"),
            back: TesseraLiveTileFace(title: "Прогноз"),
            badge: .count(3)
        )
        let cell = TesseraTileCell(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        cell.configure(with: .tile(live), liveTileEngine: nil, isVisible: false)

        XCTAssertEqual(cell.accessibilityLabel, "Погода, Минск, +12°")
        XCTAssertEqual(cell.accessibilityValue, "3")
    }

    /// Фронт без подписи даёт только заголовок; пустой заголовок фронта
    /// откатывается к заголовку ярлыка.
    func testLiveTileLabelFallsBackWhenFrontFaceIsEmpty() {
        let withoutDetail = tesseraTestLiveTile(
            "mail",
            front: TesseraLiveTileFace(title: "Почта"),
            badge: .dot
        )
        let cell = TesseraTileCell(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        cell.configure(with: .tile(withoutDetail), liveTileEngine: nil, isVisible: false)
        XCTAssertEqual(cell.accessibilityLabel, "Почта")
        XCTAssertNil(cell.accessibilityValue, "Точка без числа не озвучивается")

        let emptyFront = TileDescriptor(
            id: "empty-front",
            title: "Заголовок ярлыка",
            action: {},
            liveContent: TesseraTestLiveProvider(
                frontFace: TesseraLiveTileFace(title: "", detail: "Деталь")
            )
        )
        cell.configure(with: .tile(emptyFront), liveTileEngine: nil, isVisible: false)
        XCTAssertEqual(cell.accessibilityLabel, "Заголовок ярлыка, Деталь")
    }

    /// Статичная плитка без live-контента озвучивается прежним заголовком:
    /// поведение E9.8в не затрагивает.
    func testStaticTileLabelUnchanged() {
        let cell = TesseraTileCell(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        cell.configure(
            with: .tile(tesseraTestTile("notes", size: .small)),
            liveTileEngine: nil,
            isVisible: false
        )
        XCTAssertEqual(cell.accessibilityLabel, "notes")
        XCTAssertNil(cell.accessibilityValue)
    }

    /// Ярлык внутри панели раскрытой папки идёт тем же путём: label из фронта
    /// live-контента, value — из бэйджа.
    func testPanelShortcutLabelComesFromFrontFace() throws {
        let live = tesseraTestLiveTile(
            "in-folder",
            front: TesseraLiveTileFace(title: "Внутри", detail: "2 новых"),
            badge: .count(2),
            size: .small
        )
        let folder = TileFolder(id: "folder", title: "Folder", tiles: [live])
        let panel = TesseraFolderPanelCell(
            frame: CGRect(x: 0, y: 0, width: 350, height: 160)
        )
        panel.configure(folder: folder, columns: 4, spacing: 8)
        panel.layoutIfNeeded()

        let shortcut = try XCTUnwrap(panel.shortcutCells.first)
        XCTAssertEqual(shortcut.accessibilityLabel, "Внутри, 2 новых")
        XCTAssertEqual(shortcut.accessibilityValue, "2")
    }

    /// Ярлык панели без live-контента озвучивается заголовком ярлыка, как и
    /// плитка сетки.
    func testPanelShortcutLabelWithoutLiveContent() throws {
        let folder = TileFolder(
            id: "folder",
            title: "Folder",
            tiles: [tesseraTestTile("plain-in-folder", size: .small)]
        )
        let panel = TesseraFolderPanelCell(
            frame: CGRect(x: 0, y: 0, width: 350, height: 160)
        )
        panel.configure(folder: folder, columns: 4, spacing: 8)
        panel.layoutIfNeeded()

        let shortcut = try XCTUnwrap(panel.shortcutCells.first)
        XCTAssertEqual(shortcut.accessibilityLabel, "plain-in-folder")
        XCTAssertNil(shortcut.accessibilityValue)
    }

    // MARK: - Custom actions папок в режиме редактирования (E11.5)

    /// Стенд: ярлыки a, b, c, d, e small; папка «Work» из b, папка «Play» из e.
    private func makeActionsHost(
        extraFolders: Int = 0
    ) -> TesseraTestDragHost {
        let ids = ["a", "b", "c", "d", "e"] + (0..<extraFolders).map { "x\($0)" }
        return TesseraTestDragHost(
            descriptors: ids.map { tesseraTestTile($0, size: .small) },
            prepare: { store in
                _ = store.createFolder(withTile: "b", title: "Work")
                _ = store.createFolder(withTile: "e", title: "Play")
                for index in 0..<extraFolders {
                    _ = store.createFolder(withTile: AnyHashable("x\(index)"), title: "F\(index)")
                }
            }
        )
    }

    private func actionNames(_ cell: UIView?) -> [String] {
        (cell?.accessibilityCustomActions ?? []).map { $0.name }
    }

    private func action(named name: String, in cell: UIView?) -> UIAccessibilityCustomAction? {
        cell?.accessibilityCustomActions?.first { $0.name == name }
    }

    private func addName(_ title: String) -> String {
        String(format: TesseraStartScreenStrings.string(.a11yActionAddToFolderFormat), title)
    }

    private func moveName(_ title: String) -> String {
        String(format: TesseraStartScreenStrings.string(.a11yActionMoveToFolderFormat), title)
    }

    /// Ярлык на сетке получает «Добавить в папку <название>» по одному на
    /// папку; действие кладёт ярлык в папку через координатор (делегат получает
    /// `didAdd`).
    func testGridTileGetsAddToFolderActionPerFolder() throws {
        let host = makeActionsHost()
        host.coordinator.beginEditing()

        let names = actionNames(host.host.cell("a"))
        XCTAssertTrue(names.contains(addName("Work")))
        XCTAssertTrue(names.contains(addName("Play")))
        XCTAssertTrue(names.contains(TesseraStartScreenStrings.string(.a11yActionUnpin)))

        let folderID = try XCTUnwrap(host.folders.first { $0.title == "Work" }?.id)
        let add = try XCTUnwrap(action(named: addName("Work"), in: host.host.cell("a")))
        XCTAssertEqual(add.actionHandler?(add), true)
        XCTAssertEqual(
            host.folders.first { $0.id == folderID }?.tiles.map { $0.id },
            ["b", "a"] as [AnyHashable]
        )
        XCTAssertFalse(host.gridIDs.contains("a"))
    }

    /// У плитки-папки новых действий нет.
    func testFolderTileHasNoFolderActions() throws {
        let host = makeActionsHost()
        host.coordinator.beginEditing()
        let folderID = try XCTUnwrap(host.firstFolderID)

        let names = actionNames(host.host.cell(folderID))
        XCTAssertFalse(names.contains { $0.hasPrefix(addName("").trimmingCharacters(in: .whitespaces)) })
        XCTAssertFalse(names.contains(TesseraStartScreenStrings.string(.a11yActionRemoveFromFolder)))
    }

    /// Отказ функции одобрения: действие возвращает `false`, модель не
    /// меняется, делегат получает `didFailGrouping`.
    func testAddToFolderActionDeniedByApproval() throws {
        let host = makeActionsHost()
        host.coordinator.beginEditing()
        host.store.approval = { _, _, action in action != .addToFolder }
        let before = host.storeIDs

        let add = try XCTUnwrap(action(named: addName("Work"), in: host.host.cell("a")))
        XCTAssertEqual(add.actionHandler?(add), false)
        XCTAssertEqual(host.storeIDs, before)
    }

    /// Не больше `maxFolderActions` пунктов «в папку» на ярлык.
    func testAddToFolderActionsAreCapped() {
        let host = makeActionsHost(extraFolders: 8)
        host.coordinator.beginEditing()

        let addNames = actionNames(host.host.cell("a")).filter { $0.hasPrefix(addName("").trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(addNames.count, TesseraTileEditCoordinator.maxFolderActions)
    }

    /// Новая папка появляется в действиях уже настроенных ячеек (подпись
    /// действий включает состав папок).
    func testActionsRefreshWhenFolderIsCreated() throws {
        let host = makeActionsHost()
        host.coordinator.beginEditing()
        XCTAssertNil(action(named: addName("Fresh"), in: host.host.cell("a")))

        let created = host.coordinator.createFolder(withTile: "d", title: "Fresh")
        XCTAssertNotNil(created)
        XCTAssertTrue(host.waitUntil {
            self.action(named: self.addName("Fresh"), in: host.host.cell("a")) != nil
        })
    }

    /// Ярлыки панели в edit: «Убрать из папки» и «Переместить в папку <другая>».
    private func openPanel(_ host: TesseraTestDragHost, folderID: AnyHashable) throws -> TesseraFolderPanelCell {
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == folderID })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertTrue(host.waitUntil {
            host.host.panelCell(folderID: folderID)?.shortcutCells.first?.accessibilityCustomActions != nil
        }, "Действия ярлыков панели выставлены отложенной сверкой")
        return try XCTUnwrap(host.host.panelCell(folderID: folderID))
    }

    /// «Убрать из папки» выносит ярлык на рабочий стол сразу после папки.
    func testPanelShortcutRemoveFromFolderAction() throws {
        let host = TesseraTestDragHost(
            descriptors: ["a", "b", "c", "d", "e"].map { tesseraTestTile($0, size: .small) },
            prepare: { store in
                if let folder = store.createFolder(withTile: "b", title: "Work") {
                    _ = store.addToFolder("c", folderID: folder.id)
                }
                _ = store.createFolder(withTile: "e", title: "Play")
            }
        )
        let work = try XCTUnwrap(host.folders.first { $0.title == "Work" }?.id)
        let panel = try openPanel(host, folderID: work)

        let cell = panel.shortcutCells[1]
        XCTAssertEqual(
            actionNames(cell),
            [
                TesseraStartScreenStrings.string(.a11yActionRemoveFromFolder),
                moveName("Play"),
            ]
        )
        let remove = try XCTUnwrap(action(named: TesseraStartScreenStrings.string(.a11yActionRemoveFromFolder), in: cell))
        XCTAssertEqual(remove.actionHandler?(remove), true)

        XCTAssertEqual(host.folders.first { $0.id == work }?.tiles.map { $0.id }, ["b"] as [AnyHashable])
        let order = host.storeIDs
        XCTAssertEqual(order.firstIndex(of: "c"), (order.firstIndex(of: work) ?? -2) + 1,
                       "Ярлык встаёт сразу после папки")
    }

    /// «Переместить в папку <другая>» переносит ярлык панели в другую папку.
    func testPanelShortcutMoveToFolderAction() throws {
        let host = TesseraTestDragHost(
            descriptors: ["a", "b", "c", "d", "e"].map { tesseraTestTile($0, size: .small) },
            prepare: { store in
                if let folder = store.createFolder(withTile: "b", title: "Work") {
                    _ = store.addToFolder("c", folderID: folder.id)
                }
                _ = store.createFolder(withTile: "e", title: "Play")
            }
        )
        let work = try XCTUnwrap(host.folders.first { $0.title == "Work" }?.id)
        let play = try XCTUnwrap(host.folders.first { $0.title == "Play" }?.id)
        let panel = try openPanel(host, folderID: work)

        let move = try XCTUnwrap(action(named: moveName("Play"), in: panel.shortcutCells[1]))
        XCTAssertEqual(move.actionHandler?(move), true)
        XCTAssertEqual(host.folders.first { $0.id == play }?.tiles.map { $0.id }, ["e", "c"] as [AnyHashable])
        XCTAssertEqual(host.folders.first { $0.id == work }?.tiles.map { $0.id }, ["b"] as [AnyHashable])
    }

    /// Выход из edit снимает действия и с ячеек сетки, и с ярлыков панели.
    func testEndEditingClearsFolderActions() throws {
        let host = TesseraTestDragHost(
            descriptors: ["a", "b", "c"].map { tesseraTestTile($0, size: .small) },
            prepare: { store in
                if let folder = store.createFolder(withTile: "b", title: "Work") {
                    _ = store.addToFolder("c", folderID: folder.id)
                }
            }
        )
        let work = try XCTUnwrap(host.firstFolderID)
        let panel = try openPanel(host, folderID: work)
        XCTAssertNotNil(host.host.cell("a")?.accessibilityCustomActions)

        host.coordinator.endEditing()
        XCTAssertNil(host.host.cell("a")?.accessibilityCustomActions)
        XCTAssertTrue(panel.shortcutCells.allSatisfy { $0.accessibilityCustomActions == nil })
    }
}

#endif
