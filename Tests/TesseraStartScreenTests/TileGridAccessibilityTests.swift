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
        XCTAssertEqual(
            cell.accessibilityValue,
            TesseraStartScreenStrings.string(.a11yBadgeDot),
            "D34/E15.4: точка без числа озвучивается строкой «есть уведомление»"
        )

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

    // MARK: - Бэйдж-точка (D34, E15.4)

    /// Строка точки: ru «есть уведомление», en «has a notification».
    func testDotBadgeStringIsLocalizedInBothLanguages() {
        XCTAssertEqual(
            TesseraStartScreenStrings.string(.a11yBadgeDot, language: "ru"),
            "есть уведомление"
        )
        XCTAssertEqual(
            TesseraStartScreenStrings.string(.a11yBadgeDot, language: "en"),
            "has a notification"
        )
    }

    /// `.dot` озвучивается строкой, label не меняется, число и `.none` — как раньше.
    func testStaticTileValueForDotCountAndNone() {
        let cell = TesseraTileCell(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        let dotValue = TesseraStartScreenStrings.string(.a11yBadgeDot)

        cell.configure(
            with: .tile(tesseraTestTile("mail", badge: .dot)),
            liveTileEngine: nil,
            isVisible: false
        )
        XCTAssertEqual(cell.accessibilityValue, dotValue)
        XCTAssertEqual(cell.accessibilityLabel, "mail", "Label точкой не меняется")

        cell.configure(
            with: .tile(tesseraTestTile("mail", badge: .count(7))),
            liveTileEngine: nil,
            isVisible: false
        )
        XCTAssertEqual(cell.accessibilityValue, "7")

        cell.configure(
            with: .tile(tesseraTestTile("mail", badge: .count(0))),
            liveTileEngine: nil,
            isVisible: false
        )
        XCTAssertNil(cell.accessibilityValue, "Нулевой счётчик не озвучивается")

        cell.configure(
            with: .tile(tesseraTestTile("mail", badge: .none)),
            liveTileEngine: nil,
            isVisible: false
        )
        XCTAssertNil(cell.accessibilityValue)
    }

    /// Значение следует за бэйджем: `.dot` → число → `.dot` → `.none`.
    func testValueUpdatesWhenBadgeChanges() {
        let cell = TesseraTileCell(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        let dotValue = TesseraStartScreenStrings.string(.a11yBadgeDot)
        let sequence: [(TileBadge, String?)] = [
            (.dot, dotValue),
            (.count(12), "12"),
            (.dot, dotValue),
            (.none, nil),
        ]
        for (badge, expected) in sequence {
            cell.configure(
                with: .tile(tesseraTestTile("mail", badge: badge)),
                liveTileEngine: nil,
                isVisible: false
            )
            XCTAssertEqual(cell.accessibilityValue, expected, "badge: \(badge)")
        }
    }

    /// 1x1: заголовок скрыт визуально (D47), но label по-прежнему его
    /// озвучивает, а значение точки добавляется.
    func testSmallTileKeepsLabelAndAnnouncesDot() {
        let cell = TesseraTileCell(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        cell.configure(
            with: .tile(tesseraTestTile("notes", size: .small, badge: .dot)),
            liveTileEngine: nil,
            isVisible: false
        )
        XCTAssertEqual(cell.accessibilityLabel, "notes")
        XCTAssertEqual(
            cell.accessibilityValue,
            TesseraStartScreenStrings.string(.a11yBadgeDot)
        )
    }

    /// Ярлык панели папки и автономная live-плитка озвучивают точку так же;
    /// текст хоста (`accessibilityText`) приоритетнее строки модуля.
    func testPanelShortcutAndStandaloneLiveTileAnnounceDot() throws {
        let dotValue = TesseraStartScreenStrings.string(.a11yBadgeDot)

        let folder = TileFolder(
            id: "folder",
            title: "Folder",
            tiles: [tesseraTestTile("in-folder", size: .small, badge: .dot)]
        )
        let panel = TesseraFolderPanelCell(
            frame: CGRect(x: 0, y: 0, width: 350, height: 160)
        )
        panel.configure(folder: folder, columns: 4, spacing: 8)
        panel.layoutIfNeeded()
        let shortcut = try XCTUnwrap(panel.shortcutCells.first)
        XCTAssertEqual(shortcut.accessibilityValue, dotValue)

        let live = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        live.setFaces(front: TesseraLiveTileFace(title: "Почта"), back: nil)
        live.badge = .dot
        XCTAssertEqual(live.accessibilityValue, dotValue)
        live.badgeView.accessibilityText = "Новое письмо"
        XCTAssertEqual(live.accessibilityValue, "Новое письмо")
        live.badgeView.accessibilityText = nil
        live.badge = .count(5)
        XCTAssertEqual(live.accessibilityValue, "5")
        live.badge = .none
        XCTAssertNil(live.accessibilityValue)
    }

    // MARK: - Custom actions папок в режиме редактирования (E11.5)

    /// Стенд: ярлыки a, b, c, d, e small; папка «Work» из b, папка «Play» из e.
    private func makeActionsHost(
        extraFolders: Int = 0
    ) -> TesseraTestDragHost {
        let ids = ["a", "b", "c", "d", "e"] + (0..<extraFolders).map { "x\($0)" }
        return TesseraTestDragHost(
            descriptors: ids.map { tesseraTestTile($0, size: .small) },
            prepare: { store, columns in
                _ = store.createFolder(withTile: "b", title: "Work", columns: columns)
                _ = store.createFolder(withTile: "e", title: "Play", columns: columns)
                for index in 0..<extraFolders {
                    _ = store.createFolder(withTile: AnyHashable("x\(index)"), title: "F\(index)", columns: columns)
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

    /// «Убрать из папки» выносит ярлык на рабочий стол на первую свободную ячейку
    /// после папки (E14.5: порядок чтения по ячейкам).
    func testPanelShortcutRemoveFromFolderAction() throws {
        let host = TesseraTestDragHost(
            descriptors: ["a", "b", "c", "d", "e"].map { tesseraTestTile($0, size: .small) },
            prepare: { store, columns in
                // D45: в «Work» три ярлыка — после ухода одного папка остаётся.
                if let folder = store.createFolder(withTile: "b", title: "Work", columns: columns) {
                    _ = store.addToFolder("c", folderID: folder.id, columns: columns)
                    _ = store.addToFolder("d", folderID: folder.id, columns: columns)
                }
                _ = store.createFolder(withTile: "e", title: "Play", columns: columns)
            }
        )
        let work = try XCTUnwrap(host.folders.first { $0.title == "Work" }?.id)
        let panel = try openPanel(host, folderID: work)

        let cell = panel.shortcutCells[1]
        XCTAssertEqual(
            actionNames(cell),
            [
                TesseraStartScreenStrings.string(.a11yActionRemoveFromFolder),
                TesseraStartScreenStrings.string(.a11yActionUnpin),
                // E16.1: средний ярлык панели можно сдвинуть в обе стороны.
                TesseraStartScreenStrings.string(.a11yActionMoveEarlier),
                TesseraStartScreenStrings.string(.a11yActionMoveLater),
                moveName("Play"),
            ]
        )
        let remove = try XCTUnwrap(action(named: TesseraStartScreenStrings.string(.a11yActionRemoveFromFolder), in: cell))
        XCTAssertEqual(remove.actionHandler?(remove), true)

        XCTAssertEqual(host.folders.first { $0.id == work }?.tiles.map { $0.id }, ["b", "d"] as [AnyHashable])
        let order = host.storeIDs
        XCTAssertGreaterThan(
            order.firstIndex(of: "c") ?? -1,
            order.firstIndex(of: work) ?? Int.max,
            "Ярлык встаёт после папки в порядке чтения"
        )
        let workCell = try XCTUnwrap(host.store.placement(of: work))
        let cCell = try XCTUnwrap(host.store.placement(of: "c"))
        XCTAssertTrue(TileGridPlacement.isReadingOrdered(workCell, before: cCell), "Ячейка — после ячейки папки")
    }

    /// «Переместить в папку <другая>» переносит ярлык панели в другую папку.
    func testPanelShortcutMoveToFolderAction() throws {
        let host = TesseraTestDragHost(
            descriptors: ["a", "b", "c", "d", "e"].map { tesseraTestTile($0, size: .small) },
            prepare: { store, columns in
                if let folder = store.createFolder(withTile: "b", title: "Work", columns: columns) {
                    _ = store.addToFolder("c", folderID: folder.id, columns: columns)
                    _ = store.addToFolder("d", folderID: folder.id, columns: columns)
                }
                _ = store.createFolder(withTile: "e", title: "Play", columns: columns)
            }
        )
        let work = try XCTUnwrap(host.folders.first { $0.title == "Work" }?.id)
        let play = try XCTUnwrap(host.folders.first { $0.title == "Play" }?.id)
        let panel = try openPanel(host, folderID: work)

        let move = try XCTUnwrap(action(named: moveName("Play"), in: panel.shortcutCells[1]))
        XCTAssertEqual(move.actionHandler?(move), true)
        XCTAssertEqual(host.folders.first { $0.id == play }?.tiles.map { $0.id }, ["e", "c"] as [AnyHashable])
        XCTAssertEqual(host.folders.first { $0.id == work }?.tiles.map { $0.id }, ["b", "d"] as [AnyHashable])
    }

    /// Выход из edit снимает действия и с ячеек сетки, и с ярлыков панели.
    func testEndEditingClearsFolderActions() throws {
        let host = TesseraTestDragHost(
            descriptors: ["a", "b", "c"].map { tesseraTestTile($0, size: .small) },
            prepare: { store, columns in
                if let folder = store.createFolder(withTile: "b", title: "Work", columns: columns) {
                    _ = store.addToFolder("c", folderID: folder.id, columns: columns)
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
