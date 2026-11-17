//
//  TileGridAccessibilityTests.swift
//  TesseraStartScreenTests
//
//  VoiceOver labels of the grid.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §4 "Live tiles"
//  (front/back of the content model) and §9 "Accessibility" (a tile is a single element:
//  label is the title, value is the badge count; a tile of an opened folder's panel
//  takes the same path).
//
//  The label of a live tile is built from `liveContent.frontFace` — the title and the
//  detail separated by a comma — because VoiceOver must read what is visible on the
//  front face, not the tile's static title. The value is still taken
//  from the badge.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileGridAccessibilityTests: XCTestCase {

    // MARK: - Live tiles

    /// The label of a live tile is the front title and detail separated by a comma; the value is
    /// the badge count, as for a static tile.
    func testLiveTileLabelComesFromFrontFaceAndValueFromBadge() {
        let live = tesseraTestLiveTile(
            "weather",
            front: TesseraLiveTileFace(title: "Weather", detail: "Minsk, +12°"),
            back: TesseraLiveTileFace(title: "Forecast"),
            badge: .count(3)
        )
        let cell = TesseraTileCell(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        cell.configure(with: .tile(live), liveTileEngine: nil, isVisible: false)

        XCTAssertEqual(cell.accessibilityLabel, "Weather, Minsk, +12°")
        XCTAssertEqual(cell.accessibilityValue, "3")
    }

    /// A front without a detail gives only the title; an empty front title
    /// falls back to the tile's title.
    func testLiveTileLabelFallsBackWhenFrontFaceIsEmpty() {
        let withoutDetail = tesseraTestLiveTile(
            "mail",
            front: TesseraLiveTileFace(title: "Mail"),
            badge: .dot
        )
        let cell = TesseraTileCell(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        cell.configure(with: .tile(withoutDetail), liveTileEngine: nil, isVisible: false)
        XCTAssertEqual(cell.accessibilityLabel, "Mail")
        XCTAssertEqual(
            cell.accessibilityValue,
            TesseraStartScreenStrings.string(.a11yBadgeDot),
            "D34: a dot without a number is announced with the \"has a notification\" string"
        )

        let emptyFront = TesseraTileDescriptor(
            id: "empty-front",
            title: "Tile title",
            action: {},
            liveContent: TesseraTestLiveProvider(
                frontFace: TesseraLiveTileFace(title: "", detail: "Detail")
            )
        )
        cell.configure(with: .tile(emptyFront), liveTileEngine: nil, isVisible: false)
        XCTAssertEqual(cell.accessibilityLabel, "Tile title, Detail")
    }

    /// A static tile without live content is announced with its usual title:
    /// the live-tile behavior does not affect it.
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

    /// A tile inside an opened folder's panel takes the same path: the label comes from the front
    /// of the live content, the value from the badge.
    func testPanelShortcutLabelComesFromFrontFace() throws {
        let live = tesseraTestLiveTile(
            "in-folder",
            front: TesseraLiveTileFace(title: "Inside", detail: "2 new"),
            badge: .count(2),
            size: .small
        )
        let folder = TesseraTileFolder(id: "folder", title: "Folder", tiles: [live])
        let panel = TesseraFolderPanelCell(
            frame: CGRect(x: 0, y: 0, width: 350, height: 160)
        )
        panel.configure(folder: folder, columns: 4, spacing: 8)
        panel.layoutIfNeeded()

        let shortcut = try XCTUnwrap(panel.shortcutCells.first)
        XCTAssertEqual(shortcut.accessibilityLabel, "Inside, 2 new")
        XCTAssertEqual(shortcut.accessibilityValue, "2")
    }

    /// A panel tile without live content is announced with the tile's title, like
    /// a grid tile.
    func testPanelShortcutLabelWithoutLiveContent() throws {
        let folder = TesseraTileFolder(
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

    // MARK: - Dot badge (D34)

    /// The dot string is localized in both ru and en ("has a notification" in en).
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

    /// `.dot` is announced as a string, the label does not change, a number and `.none` — as before.
    func testStaticTileValueForDotCountAndNone() {
        let cell = TesseraTileCell(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        let dotValue = TesseraStartScreenStrings.string(.a11yBadgeDot)

        cell.configure(
            with: .tile(tesseraTestTile("mail", badge: .dot)),
            liveTileEngine: nil,
            isVisible: false
        )
        XCTAssertEqual(cell.accessibilityValue, dotValue)
        XCTAssertEqual(cell.accessibilityLabel, "mail", "The dot does not change the label")

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
        XCTAssertNil(cell.accessibilityValue, "A zero count is not announced")

        cell.configure(
            with: .tile(tesseraTestTile("mail", badge: .none)),
            liveTileEngine: nil,
            isVisible: false
        )
        XCTAssertNil(cell.accessibilityValue)
    }

    /// The value follows the badge: `.dot` → number → `.dot` → `.none`.
    func testValueUpdatesWhenBadgeChanges() {
        let cell = TesseraTileCell(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        let dotValue = TesseraStartScreenStrings.string(.a11yBadgeDot)
        let sequence: [(TesseraTileBadge, String?)] = [
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

    /// 1x1: the title is visually hidden (D47), but the label still
    /// announces it, and the dot value is added.
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

    /// A folder panel tile and a standalone live tile announce the dot the same way;
    /// the host text (`accessibilityText`) takes priority over the module string.
    func testPanelShortcutAndStandaloneLiveTileAnnounceDot() throws {
        let dotValue = TesseraStartScreenStrings.string(.a11yBadgeDot)

        let folder = TesseraTileFolder(
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
        live.setFaces(front: TesseraLiveTileFace(title: "Mail"), back: nil)
        live.badge = .dot
        XCTAssertEqual(live.accessibilityValue, dotValue)
        live.badgeView.accessibilityText = "New message"
        XCTAssertEqual(live.accessibilityValue, "New message")
        live.badgeView.accessibilityText = nil
        live.badge = .count(5)
        XCTAssertEqual(live.accessibilityValue, "5")
        live.badge = .none
        XCTAssertNil(live.accessibilityValue)
    }

    // MARK: - Custom actions of folders in edit mode

    /// The test bench: small tiles a, b, c, d, e; folder "Work" from b, folder "Play" from e.
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

    /// A tile on the grid gets "Add to folder <title>", one per folder; the action
    /// puts the tile into the folder through the coordinator (the delegate receives
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

    /// A folder tile has no new actions.
    func testFolderTileHasNoFolderActions() throws {
        let host = makeActionsHost()
        host.coordinator.beginEditing()
        let folderID = try XCTUnwrap(host.firstFolderID)

        let names = actionNames(host.host.cell(folderID))
        XCTAssertFalse(names.contains { $0.hasPrefix(addName("").trimmingCharacters(in: .whitespaces)) })
        XCTAssertFalse(names.contains(TesseraStartScreenStrings.string(.a11yActionRemoveFromFolder)))
    }

    /// A refusal from the approval function: the action returns `false`, the model does not
    /// change, the delegate receives `didFailGrouping`.
    func testAddToFolderActionDeniedByApproval() throws {
        let host = makeActionsHost()
        host.coordinator.beginEditing()
        host.store.approval = { _, _, action in action != .addToFolder }
        let before = host.storeIDs

        let add = try XCTUnwrap(action(named: addName("Work"), in: host.host.cell("a")))
        XCTAssertEqual(add.actionHandler?(add), false)
        XCTAssertEqual(host.storeIDs, before)
    }

    /// No more than `maxFolderActions` "to folder" items per tile.
    func testAddToFolderActionsAreCapped() {
        let host = makeActionsHost(extraFolders: 8)
        host.coordinator.beginEditing()

        let addNames = actionNames(host.host.cell("a")).filter { $0.hasPrefix(addName("").trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(addNames.count, TesseraTileEditCoordinator.maxFolderActions)
    }

    /// A new folder appears in the actions of already configured cells (the action
    /// label includes the folder composition).
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

    /// Panel tiles in edit mode: "Remove from folder" and "Move to folder <other>".
    private func openPanel(_ host: TesseraTestDragHost, folderID: AnyHashable) throws -> TesseraFolderPanelCell {
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == folderID })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertTrue(host.waitUntil {
            host.host.panelCell(folderID: folderID)?.shortcutCells.first?.accessibilityCustomActions != nil
        }, "The panel tiles' actions are set by the deferred reconciliation")
        return try XCTUnwrap(host.host.panelCell(folderID: folderID))
    }

    /// "Remove from folder" takes a tile out to the desktop, to the first free cell
    /// after the folder (reading order by cells).
    func testPanelShortcutRemoveFromFolderAction() throws {
        let host = TesseraTestDragHost(
            descriptors: ["a", "b", "c", "d", "e"].map { tesseraTestTile($0, size: .small) },
            prepare: { store, columns in
                // D45: "Work" has three tiles — after one leaves, the folder remains.
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
                // The middle panel tile can be moved in both directions.
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
            "A tile lands after the folder in reading order"
        )
        let workCell = try XCTUnwrap(host.store.placement(of: work))
        let cCell = try XCTUnwrap(host.store.placement(of: "c"))
        XCTAssertTrue(TesseraTileGridPlacement.isReadingOrdered(workCell, before: cCell), "The cell is after the folder's cell")
    }

    /// "Move to folder <other>" moves a panel tile to another folder.
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

    /// Leaving edit mode removes the actions from both grid cells and panel tiles.
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
