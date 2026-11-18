//
//  TileFolderRenameTests.swift
//  TesseraStartScreenTests
//
//  Folder rename (D35; docs/W10M-STARTSCREEN.md §6.7). Design document:
//  docs/STARTSCREEN-IOS-DESIGN.md, "Implementation notes and deviations";
//  decision D35 in docs/DECISIONS.md.
//
//  What is tested:
//  - the model: `TesseraTileStore.renameFolder(_:to:)` (whitespace trimming, an empty name is
//    the default name, the 64-character limit, an unknown folder, the same name without a
//    notification, the write round trip, a single `onChange`, cell/size/contents intact);
//  - the grid: editing the name in an open panel (field, return, tap outside, empty name,
//    the final name in the handler, header height, closing the panel, replacing
//    the handler, the limit while typing), the keyboard (the field above it, restoring insets and
//    offset, Reduce Motion), RTL and Dynamic Type;
//  - the coordinator: the handler, `TesseraTileStore`, the delegate, the default name from
//    the configuration, entering/leaving edit mode, a disabled coordinator;
//  - VoiceOver: the "Rename" action on the panel title and the folder tile,
//    the field label, focus before and after editing;
//  - gestures: a long press on the name starts neither a drag nor entering edit mode (the name
//    zone), a long press on a panel tile still takes it out;
//  - en/ru strings.
//
//  Exact layouts (`TileStoreCellFixture`, 4 columns), no `sleep`.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileFolderRenameTests: XCTestCase {

    // MARK: - Model helpers

    private let columns = 4

    private func makeStore(
        in directory: TesseraTestDirectory,
        autosaves: Bool = false
    ) throws -> TesseraTileStore {
        try TileStoreCellFixture.makeStore(
            columns: columns,
            tiles: [CellFixtureTile("a0", .small, 3, 0)],
            folders: [CellFixtureFolder("F", .medium, 0, 0, contents: [("x", .small), ("y", .small), ("z", .small)])],
            in: directory,
            autosaves: autosaves
        )
    }

    private func folderTitle(_ store: TesseraTileStore, id: AnyHashable = "F") -> String? {
        store.snapshot(columns: columns).folders.first { $0.id == id }?.title
    }

    private func countNotifications(_ store: TesseraTileStore) -> () -> Int {
        var count = 0
        store.onChange = { _ in count += 1 }
        return { count }
    }

    // MARK: - TesseraTileStore.renameFolder

    /// Whitespace and newlines at the edges are dropped; the result is written to the model.
    func testRenameTrimsSurroundingWhitespaceAndNewlines() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)
        XCTAssertTrue(store.renameFolder("F", to: "  \n Work \t\n"))
        XCTAssertEqual(folderTitle(store), "Work")
    }

    /// An empty or whitespace-only name returns the default name: the same
    /// localized "Folder" that a new folder gets.
    func testRenameEmptyReturnsDefaultTitle() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)
        let fallback = TesseraStartScreenStrings.string(.folderScreenDefaultTitle)

        XCTAssertTrue(store.renameFolder("F", to: "Work"))
        XCTAssertTrue(store.renameFolder("F", to: ""))
        XCTAssertEqual(folderTitle(store), fallback)

        XCTAssertTrue(store.renameFolder("F", to: "Games"))
        XCTAssertTrue(store.renameFolder("F", to: "  \n\t "))
        XCTAssertEqual(folderTitle(store), fallback, "Whitespace only is an empty name too")
    }

    /// The 64-character limit: a long name is truncated, whitespace at the cut edge is trimmed.
    func testRenameCapsLengthAndTrimsAfterCut() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)
        XCTAssertEqual(TesseraTileFolder.maximumTitleLength, 64)

        XCTAssertTrue(store.renameFolder("F", to: String(repeating: "я", count: 100)))
        XCTAssertEqual(folderTitle(store), String(repeating: "я", count: 64))

        // The cut falls on a space: the tail after truncation does not stay a space.
        let spaced = String(repeating: "a", count: 63) + " " + String(repeating: "b", count: 10)
        XCTAssertTrue(store.renameFolder("F", to: spaced))
        XCTAssertEqual(folderTitle(store), String(repeating: "a", count: 63))

        // Exactly the limit passes whole; characters are counted, not bytes.
        let emoji = String(repeating: "😀", count: 64)
        XCTAssertTrue(store.renameFolder("F", to: emoji))
        XCTAssertEqual(folderTitle(store)?.count, 64)
    }

    /// The name is a single line: newlines inside become spaces.
    func testRenameKeepsSingleLine() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)
        XCTAssertTrue(store.renameFolder("F", to: "Work\nprojects"))
        XCTAssertEqual(folderTitle(store), "Work projects")
    }

    /// An unknown folder and a tile instead of a folder give `false`, without notifications.
    func testRenameUnknownFolderIsNoOp() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)
        let notifications = countNotifications(store)

        XCTAssertFalse(store.renameFolder("nope", to: "X"))
        XCTAssertFalse(store.renameFolder("a0", to: "X"), "A tile is not a folder")
        XCTAssertEqual(notifications(), 0)
        XCTAssertEqual(folderTitle(store), "F")
    }

    /// The same name (including after normalization) gives `false`, without `onChange` or a write.
    func testRenameToSameTitleIsNoOpWithoutNotificationOrSave() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory, autosaves: true)
        XCTAssertTrue(store.renameFolder("F", to: "Work"))
        try FileManager.default.removeItem(at: store.fileURL)
        let notifications = countNotifications(store)

        XCTAssertFalse(store.renameFolder("F", to: "Work"))
        XCTAssertFalse(store.renameFolder("F", to: "  Work  "))
        XCTAssertEqual(notifications(), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.fileURL.path),
            "An unchanged name does not write the file"
        )
    }

    /// Write round trip: the name survives a restart; an empty name is the default name.
    func testRenamePersistsThroughRoundTrip() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory, autosaves: true)
        XCTAssertTrue(store.renameFolder("F", to: "Work"))

        let catalog = ["a0", "x", "y", "z"].map { tesseraTestTile($0, size: .small) }
        let fresh = TesseraTileStore(directoryURL: directory.url)
        fresh.setCatalog(catalog)
        try fresh.load()
        XCTAssertEqual(folderTitle(fresh), "Work")

        XCTAssertTrue(store.renameFolder("F", to: ""))
        let again = TesseraTileStore(directoryURL: directory.url)
        again.setCatalog(catalog)
        try again.load()
        XCTAssertEqual(folderTitle(again), TesseraStartScreenStrings.string(.folderScreenDefaultTitle))
    }

    /// Exactly one notification per successful operation; the snapshot carries the new name.
    func testRenameNotifiesOnChangeOnce() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)
        var snapshots: [TesseraTileGridSnapshot] = []
        store.onChange = { snapshots.append($0) }

        XCTAssertTrue(store.renameFolder("F", to: "Work"))
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.folders.first?.title, "Work")
    }

    /// Renaming touches neither the cell, nor the size, nor the folder contents.
    func testRenameKeepsCellSizeAndContent() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)
        let before = store.snapshot(columns: columns)
        let cellsBefore = before.placementTable?.cells
        let folderBefore = try XCTUnwrap(before.folders.first)

        XCTAssertTrue(store.renameFolder("F", to: "Work"))
        let after = store.snapshot(columns: columns)
        let folderAfter = try XCTUnwrap(after.folders.first)
        XCTAssertEqual(after.placementTable?.cells, cellsBefore)
        XCTAssertEqual(folderAfter.size, folderBefore.size)
        XCTAssertEqual(folderAfter.tiles.map { $0.id }, folderBefore.tiles.map { $0.id })
        XCTAssertEqual(after.items.map { $0.id }, before.items.map { $0.id })
    }

    // MARK: - Grid helpers

    private final class Recorder {
        var renames: [(AnyHashable, String)] = []
        var posts: [(UIAccessibility.Notification, Any?)] = []
    }

    private struct GridFixture {
        let host: TesseraTestWindowedGrid
        let folder: TesseraTileFolder
        let recorder: Recorder
        var grid: TesseraTileGridView { host.grid }
    }

    /// A grid in a window with a single folder "Work" of four tiles; the rename
    /// handler records calls (`installsHandler == false` means without it).
    private func makeGridFixture(
        installsHandler: Bool = true,
        title: String = "Work",
        extraItems: [TesseraTileGridItem] = [],
        size: CGSize = TesseraTestWindowedGrid.defaultSize
    ) -> GridFixture {
        let folder = tesseraTestFolder("F", tileCount: 4, title: title)
        let host = TesseraTestWindowedGrid(
            items: [.folder(folder)] + extraItems,
            columns: 4,
            size: size
        )
        host.window.makeKeyAndVisible()
        let recorder = Recorder()
        host.grid.accessibilityNotificationPoster = { recorder.posts.append(($0, $1)) }
        if installsHandler {
            host.grid.folderRenameHandler = { recorder.renames.append(($0, $1)) }
        }
        return GridFixture(host: host, folder: folder, recorder: recorder)
    }

    @discardableResult
    private func openPanel(_ fixture: GridFixture) throws -> TesseraFolderPanelCell {
        fixture.grid.openFolder(fixture.folder, animated: false)
        fixture.host.layout()
        XCTAssertEqual(fixture.grid.expandedFolderID, "F")
        return try XCTUnwrap(fixture.host.panelCell(folderID: "F"))
    }

    private func type(_ text: String, in panel: TesseraFolderPanelCell) {
        panel.titleTextField.text = text
    }

    private func pressReturn(in panel: TesseraFolderPanelCell) {
        let field = panel.titleTextField
        _ = field.delegate?.textFieldShouldReturn?(field)
    }

    /// A tap on free space of the grid (under the panel), like a finger touch.
    private func tapGridBackground(_ grid: TesseraTileGridView) {
        final class FakeTap: UITapGestureRecognizer {
            var point = CGPoint.zero
            override func location(in view: UIView?) -> CGPoint { point }
        }
        let tap = FakeTap()
        tap.point = CGPoint(x: 195, y: grid.bounds.height - 20)
        grid.perform(NSSelectorFromString("handleBackgroundTap:"), with: tap)
    }

    private func longPressRecognizer(of panel: TesseraFolderPanelCell) -> UILongPressGestureRecognizer? {
        panel.titleHeaderLabel.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }.first
    }

    // MARK: - Grid: entering edit

    /// A long press on the name (about 0.5 s) is enabled only when the grid has
    /// a handler; without it the title is static, editing does not start, and there is no
    /// VoiceOver action.
    func testNameLongPressIsEnabledOnlyWithHandler() throws {
        let without = makeGridFixture(installsHandler: false)
        let bare = try openPanel(without)
        XCTAssertEqual(longPressRecognizer(of: bare)?.isEnabled, false)
        XCTAssertEqual(longPressRecognizer(of: bare)?.minimumPressDuration ?? 0, 0.5, accuracy: 0.001)
        XCTAssertFalse(bare.beginTitleEditing())
        XCTAssertFalse(bare.isEditingTitle)
        XCTAssertNil(bare.titleHeaderLabel.accessibilityCustomActions)
        XCTAssertFalse(without.grid.isFolderNameHit(at: CGPoint(x: 100, y: 20)))

        let with = makeGridFixture()
        let panel = try openPanel(with)
        XCTAssertEqual(longPressRecognizer(of: panel)?.isEnabled, true)
        XCTAssertTrue(panel.beginTitleEditing())
        XCTAssertTrue(panel.isEditingTitle)
        XCTAssertTrue(with.grid.isEditingFolderName)
    }

    /// The field: the name in the field is the same as in the title and fully selected, a single line, return is
    /// "Done", no autocorrection; a VoiceOver label; the font and frame are those of the title.
    func testFieldIsPrefilledSelectedSingleLineAndAccessible() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        let label = panel.titleHeaderLabel
        XCTAssertTrue(panel.beginTitleEditing())

        let field = panel.titleTextField
        XCTAssertEqual(field.text, "Work")
        XCTAssertFalse(field.isHidden)
        XCTAssertTrue(label.isHidden)
        XCTAssertTrue(field.isFirstResponder)
        XCTAssertEqual(field.returnKeyType, .done)
        XCTAssertEqual(field.autocorrectionType, .no)
        XCTAssertEqual(field.spellCheckingType, .no)
        XCTAssertEqual(field.accessibilityLabel, TesseraStartScreenStrings.string(.folderNameFieldLabel))
        XCTAssertEqual(field.font, label.font)
        XCTAssertEqual(field.frame, label.frame, "The field takes the title frame")

        let range = try XCTUnwrap(field.selectedTextRange)
        XCTAssertEqual(field.text(in: range), "Work", "The name is fully selected")
    }

    /// Editing does not change the header height: the panel and the tiles under the title stay in place.
    func testHeaderHeightAndLayoutAreStableDuringEditing() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        let panelFrame = panel.frame
        let shortcutFrames = panel.shortcutCells.map { $0.frame }
        let labelFrame = panel.titleHeaderLabel.frame
        let contentHeight = fixture.grid.contentSize.height

        XCTAssertTrue(panel.beginTitleEditing())
        fixture.host.layout()
        XCTAssertEqual(panel.frame, panelFrame)
        XCTAssertEqual(panel.shortcutCells.map { $0.frame }, shortcutFrames)
        XCTAssertEqual(panel.titleHeaderLabel.frame, labelFrame)
        XCTAssertEqual(panel.titleTextField.frame, labelFrame)
        XCTAssertEqual(fixture.grid.contentSize.height, contentHeight)

        pressReturn(in: panel)
        fixture.host.layout()
        XCTAssertEqual(panel.frame, panelFrame)
        XCTAssertEqual(panel.titleHeaderLabel.frame, labelFrame)
    }

    // MARK: - Grid: committing

    /// Return commits the name: the handler receives the final (normalized) name,
    /// the title shows it, editing is finished.
    func testReturnCommitsFinalNameAndUpdatesLabel() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        XCTAssertTrue(panel.beginTitleEditing())
        type("  Games  ", in: panel)
        pressReturn(in: panel)

        XCTAssertEqual(fixture.recorder.renames.count, 1)
        XCTAssertEqual(fixture.recorder.renames.first?.0, "F")
        XCTAssertEqual(fixture.recorder.renames.first?.1, "Games")
        XCTAssertEqual(panel.titleHeaderLabel.text, "Games")
        XCTAssertEqual(panel.titleHeaderLabel.accessibilityLabel, "Games")
        XCTAssertFalse(panel.isEditingTitle)
        XCTAssertFalse(fixture.grid.isEditingFolderName)
        XCTAssertTrue(panel.titleTextField.isHidden)
        XCTAssertFalse(panel.titleHeaderLabel.isHidden)
        XCTAssertFalse(panel.titleTextField.isFirstResponder)
    }

    /// A tap on the grid background commits the name and does not close the folder.
    func testBackgroundTapCommitsAndKeepsFolderOpen() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        XCTAssertTrue(panel.beginTitleEditing())
        type("Games", in: panel)

        tapGridBackground(fixture.grid)
        XCTAssertEqual(fixture.recorder.renames.map { $0.1 }, ["Games"])
        XCTAssertFalse(panel.isEditingTitle)
        XCTAssertEqual(fixture.grid.expandedFolderID, "F", "A tap outside the field only commits the name")
        XCTAssertEqual(panel.titleHeaderLabel.text, "Games")

        // Outside editing the same tap still closes the folder.
        fixture.grid.isReduceMotionEnabled = { true }
        tapGridBackground(fixture.grid)
        XCTAssertNil(fixture.grid.expandedFolderID)
    }

    /// An empty name (or whitespace only) is the "default name": the handler receives
    /// an empty string, the title shows the localized default name.
    func testEmptyNameBecomesDefaultTitle() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        XCTAssertTrue(panel.beginTitleEditing())
        type("   ", in: panel)
        pressReturn(in: panel)

        XCTAssertEqual(fixture.recorder.renames.map { $0.1 }, [""])
        XCTAssertEqual(
            panel.titleHeaderLabel.text,
            TesseraStartScreenStrings.string(.folderScreenDefaultTitle)
        )
    }

    /// The name did not change (including after trimming whitespace): the handler is not called.
    func testUnchangedNameDoesNotCallHandler() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        XCTAssertTrue(panel.beginTitleEditing())
        type(" Work ", in: panel)
        pressReturn(in: panel)
        XCTAssertTrue(fixture.recorder.renames.isEmpty)
        XCTAssertEqual(panel.titleHeaderLabel.text, "Work")

        // An empty folder with the default name and empty input are "no change" too.
        let untitled = makeGridFixture(title: "")
        let blank = try openPanel(untitled)
        XCTAssertTrue(blank.beginTitleEditing())
        type("", in: blank)
        pressReturn(in: blank)
        XCTAssertTrue(untitled.recorder.renames.isEmpty)
    }

    /// The handler receives a name no longer than the limit, as a single line.
    func testHandlerReceivesCappedSingleLineName() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        XCTAssertTrue(panel.beginTitleEditing())
        type(String(repeating: "ы", count: 90) + "\ntail", in: panel)
        pressReturn(in: panel)
        XCTAssertEqual(fixture.recorder.renames.first?.1.count, TesseraTileFolder.maximumTitleLength)
        XCTAssertFalse(fixture.recorder.renames.first?.1.contains("\n") ?? true)
    }

    /// Input is limited by the cap: an edit after which the string is longer than 64 is not
    /// applied; deletion and replacement within the cap go through.
    func testTypingIsCappedAtMaximumLength() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        XCTAssertTrue(panel.beginTitleEditing())
        let field = panel.titleTextField
        let delegate = try XCTUnwrap(field.delegate)

        field.text = String(repeating: "a", count: 64)
        XCTAssertFalse(
            delegate.textField?(field, shouldChangeCharactersIn: NSRange(location: 64, length: 0), replacementString: "b") ?? true
        )
        XCTAssertTrue(
            delegate.textField?(field, shouldChangeCharactersIn: NSRange(location: 0, length: 1), replacementString: "b") ?? false,
            "Replacing a character within the cap goes through"
        )
        XCTAssertTrue(
            delegate.textField?(field, shouldChangeCharactersIn: NSRange(location: 60, length: 4), replacementString: "") ?? false,
            "Deletion goes through"
        )
        XCTAssertFalse(
            delegate.textField?(field, shouldChangeCharactersIn: NSRange(location: 64, length: 0), replacementString: "😀") ?? true
        )
    }

    /// Closing the panel during editing commits the name (D35), VoiceOver focus does not
    /// return to the panel title.
    func testClosingPanelWhileEditingCommits() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        XCTAssertTrue(panel.beginTitleEditing())
        type("Games", in: panel)
        fixture.recorder.posts.removeAll()

        fixture.grid.closeFolder(animated: false)
        XCTAssertEqual(fixture.recorder.renames.map { $0.1 }, ["Games"])
        XCTAssertFalse(fixture.grid.isEditingFolderName)
        XCTAssertNil(fixture.grid.expandedFolderID)
        XCTAssertFalse(
            fixture.recorder.posts.contains { ($0.1 as? UILabel) === panel.titleHeaderLabel },
            "The panel is closed: focus goes to the folder tile"
        )
    }

    /// Replacing the handler in the middle of editing commits what was typed with the old handler;
    /// with `nil` the title is static again.
    func testReplacingHandlerCommitsWithOldHandlerAndDisablesEditing() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        XCTAssertTrue(panel.beginTitleEditing())
        type("Games", in: panel)

        fixture.grid.folderRenameHandler = nil
        XCTAssertEqual(fixture.recorder.renames.map { $0.1 }, ["Games"])
        XCTAssertFalse(panel.isEditingTitle)
        XCTAssertFalse(panel.isTitleEditable)
        XCTAssertEqual(longPressRecognizer(of: panel)?.isEnabled, false)
        XCTAssertNil(panel.titleHeaderLabel.accessibilityCustomActions)
    }

    /// The panel went into reuse in the middle of editing: the name is committed, and
    /// the handler is called on the next run loop pass.
    func testReusingPanelWhileEditingCommitsDeferred() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        XCTAssertTrue(panel.beginTitleEditing())
        type("Games", in: panel)

        panel.prepareForReuse()
        XCTAssertFalse(panel.isEditingTitle)
        XCTAssertTrue(fixture.recorder.renames.isEmpty, "The handler is not called inside reuse")
        XCTAssertTrue(fixture.host.waitUntil { !fixture.recorder.renames.isEmpty })
        XCTAssertEqual(fixture.recorder.renames.first?.1, "Games")
    }

    // MARK: - Keyboard

    /// A 390×500 window and a folder below the first screen; the panel is expanded, the grid
    /// is scrolled so that the panel header is at the bottom edge of the screen (the keyboard will
    /// cover it). Reduce Motion is on: scrolling without animation.
    private func makeScrollingFixture() throws -> (GridFixture, TesseraFolderPanelCell, CGFloat) {
        let tiles: [TesseraTileGridItem] = (0..<4).map { .tile(tesseraTestTile("t\($0)", size: .medium)) }
        let folder = tesseraTestFolder("F", tileCount: 4, title: "Work")
        let host = TesseraTestWindowedGrid(
            items: tiles + [.folder(folder)] + (0..<6).map { .tile(tesseraTestTile("u\($0)", size: .wide)) },
            columns: 4,
            size: CGSize(width: 390, height: 500)
        )
        host.window.makeKeyAndVisible()
        let recorder = Recorder()
        host.grid.accessibilityNotificationPoster = { recorder.posts.append(($0, $1)) }
        host.grid.folderRenameHandler = { recorder.renames.append(($0, $1)) }
        host.grid.isReduceMotionEnabled = { true }
        let fixture = GridFixture(host: host, folder: folder, recorder: recorder)

        let folderFrame = try XCTUnwrap(host.grid.frame(forItemID: "F"))
        host.grid.openFolder(folder, animated: false)
        host.layout()
        let offset = folderFrame.maxY - 380
        XCTAssertGreaterThan(offset, 0, "The folder is below the first screen")
        host.grid.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        host.layout()
        let panel = try XCTUnwrap(host.panelCell(folderID: "F"))
        return (fixture, panel, host.collectionView?.contentOffset.y ?? 0)
    }

    private func fieldFrameInGrid(_ panel: TesseraFolderPanelCell, grid: TesseraTileGridView) -> CGRect {
        panel.titleTextField.convert(panel.titleTextField.bounds, to: grid)
    }

    /// The keyboard covers the field: the grid scrolls so that the field becomes
    /// visible above it (Reduce Motion: without animation, the offset is immediate), the bottom inset
    /// of the collection equals the overlap; when finished, the insets and the offset are restored.
    func testKeyboardScrollsFieldAboveKeyboardAndRestoresOnEnd() throws {
        let (fixture, panel, originalOffset) = try makeScrollingFixture()
        let grid = fixture.grid
        let collection = try XCTUnwrap(fixture.host.collectionView)
        XCTAssertGreaterThan(fieldFrameInGrid(panel, grid: grid).maxY, 200, "Without the keyboard the field is below its future edge")

        XCTAssertTrue(panel.beginTitleEditing())
        let keyboardHeight: CGFloat = 300
        grid.applyKeyboardFrame(
            CGRect(x: 0, y: 500 - keyboardHeight, width: 390, height: keyboardHeight)
        )
        XCTAssertEqual(collection.contentInset.bottom, keyboardHeight, accuracy: 0.5)
        let field = fieldFrameInGrid(panel, grid: grid)
        XCTAssertGreaterThanOrEqual(field.minY, 0, "The title is visible at the top")
        XCTAssertLessThanOrEqual(field.maxY, 500 - keyboardHeight, "The field is above the keyboard")

        pressReturn(in: panel)
        XCTAssertEqual(collection.contentInset.bottom, 0, accuracy: 0.001, "Insets restored")
        XCTAssertEqual(collection.contentOffset.y, originalOffset, accuracy: 1, "Offset restored")
    }

    /// The keyboard hid in the middle of editing: the insets are restored, editing continues;
    /// the user's scroll during editing is not rolled back on completion.
    func testKeyboardHideRestoresInsetsAndUserScrollIsKept() throws {
        let (fixture, panel, _) = try makeScrollingFixture()
        let grid = fixture.grid
        let collection = try XCTUnwrap(fixture.host.collectionView)
        XCTAssertTrue(panel.beginTitleEditing())
        grid.applyKeyboardFrame(CGRect(x: 0, y: 200, width: 390, height: 300))
        XCTAssertEqual(collection.contentInset.bottom, 300, accuracy: 0.5)

        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        XCTAssertEqual(collection.contentInset.bottom, 0, accuracy: 0.001)
        XCTAssertTrue(panel.isEditingTitle, "Hiding the keyboard does not end editing")

        // The user scrolled on their own: the offset is not rolled back on completion.
        grid.setContentOffset(CGPoint(x: 0, y: collection.contentOffset.y + 120), animated: false)
        let userOffset = collection.contentOffset.y
        pressReturn(in: panel)
        XCTAssertEqual(collection.contentOffset.y, userOffset, accuracy: 1)
    }

    /// A keyboard notification that arrived before editing was registered (during
    /// `becomeFirstResponder`) is taken into account: the last frame is remembered.
    func testKeyboardFrameNotificationBeforeEditingIsRemembered() throws {
        let (fixture, panel, _) = try makeScrollingFixture()
        let collection = try XCTUnwrap(fixture.host.collectionView)

        NotificationCenter.default.post(
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(x: 0, y: 200, width: 390, height: 300)]
        )
        XCTAssertEqual(collection.contentInset.bottom, 0, accuracy: 0.001, "Outside editing the insets are not touched")

        // The simulator may post its own keyboard notifications when the field becomes first
        // responder (for example with a hardware keyboard connected, as on CI runners). Those
        // legitimately replace the frame posted above, so the remembered-frame scenario cannot be
        // observed in that environment.
        var systemNotifications = 0
        let tokens = [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification]
            .map { name in NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                systemNotifications += 1
            } }
        defer { tokens.forEach { NotificationCenter.default.removeObserver($0) } }

        XCTAssertTrue(panel.beginTitleEditing())
        try XCTSkipIf(
            systemNotifications > 0,
            "The simulator posted its own keyboard notifications while editing started"
        )
        XCTAssertEqual(collection.contentInset.bottom, 300, accuracy: 0.5)
        pressReturn(in: panel)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    // MARK: - RTL and Dynamic Type

    /// RTL: the field and the title are in the same frame (the full header width), the alignment is
    /// natural; in RTL the field is mirrored together with the title.
    func testRightToLeftHeaderKeepsFieldAndLabelAligned() throws {
        let fixture = makeGridFixture()
        fixture.grid.semanticContentAttribute = .forceRightToLeft
        fixture.host.collectionView?.semanticContentAttribute = .forceRightToLeft
        let panel = try openPanel(fixture)
        panel.semanticContentAttribute = .forceRightToLeft
        panel.contentView.semanticContentAttribute = .forceRightToLeft
        fixture.host.layout()

        XCTAssertTrue(panel.beginTitleEditing())
        XCTAssertEqual(panel.titleTextField.frame, panel.titleHeaderLabel.frame)
        XCTAssertEqual(panel.titleTextField.textAlignment, .natural)
        XCTAssertEqual(panel.titleHeaderLabel.textAlignment, .natural)
        type("Games", in: panel)
        pressReturn(in: panel)
        XCTAssertEqual(fixture.recorder.renames.map { $0.1 }, ["Games"])
    }

    /// Dynamic Type: the field takes the title font (capped by the header height) and
    /// follows it when the category changes.
    func testFieldFontFollowsHeaderFontAndFitsHeader() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        let large = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let expected = TesseraFolderPanelCell.makeTitleFont(compatibleWith: large)
        XCTAssertLessThanOrEqual(
            expected.lineHeight,
            TesseraTileLayoutEngine.panelHeaderHeight,
            "The title row fits into the header at AX5"
        )
        panel.refreshTypography()
        XCTAssertEqual(panel.titleTextField.font, panel.titleHeaderLabel.font)
    }

    // MARK: - VoiceOver

    /// The "Rename" action on the panel title starts the same editing;
    /// focus moves to the field and returns to the title after committing.
    func testHeaderRenameActionStartsEditingAndReturnsFocus() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        let actions = try XCTUnwrap(panel.titleHeaderLabel.accessibilityCustomActions)
        XCTAssertEqual(actions.map { $0.name }, [TesseraStartScreenStrings.string(.a11yActionRenameFolder)])
        fixture.recorder.posts.removeAll()

        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(action.actionHandler?(action), true)
        XCTAssertTrue(panel.isEditingTitle)
        XCTAssertTrue(
            fixture.recorder.posts.contains { $0.0 == .layoutChanged && ($0.1 as? UITextField) === panel.titleTextField },
            "Focus on the field"
        )

        type("Games", in: panel)
        fixture.recorder.posts.removeAll()
        pressReturn(in: panel)
        XCTAssertTrue(
            fixture.recorder.posts.contains { $0.0 == .layoutChanged && ($0.1 as? UILabel) === panel.titleHeaderLabel },
            "Focus returned to the title"
        )
        XCTAssertEqual(panel.titleHeaderLabel.accessibilityLabel, "Games", "The label reflects the new name")
        XCTAssertFalse(
            fixture.recorder.posts.contains { $0.0 == .announcement },
            "There are no additional announcements"
        )
    }

    /// The folder tile gets the "Rename" action together with the handler;
    /// activation expands the folder and starts editing; without a handler there is no action.
    func testFolderTileRenameActionOpensPanelAndStartsEditing() throws {
        let fixture = makeGridFixture()
        let tile = try XCTUnwrap(fixture.host.cell("F"))
        let actions = try XCTUnwrap(tile.accessibilityCustomActions)
        XCTAssertEqual(actions.map { $0.name }, [TesseraStartScreenStrings.string(.a11yActionRenameFolder)])
        XCTAssertNil(fixture.grid.expandedFolderID)

        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(action.actionHandler?(action), true)
        XCTAssertTrue(fixture.host.waitUntil(timeout: 3) { fixture.grid.isEditingFolderName })
        XCTAssertEqual(fixture.grid.expandedFolderID, "F")

        fixture.grid.commitFolderNameEditing()
        fixture.grid.folderRenameHandler = nil
        XCTAssertNil(try XCTUnwrap(fixture.host.cell("F")).accessibilityCustomActions)
    }

    /// A regular tile does not get the "Rename" action.
    func testTilesHaveNoRenameAction() throws {
        let tile = tesseraTestTile("t", size: .small)
        let host = TesseraTestWindowedGrid(items: [.tile(tile), .folder(tesseraTestFolder("F"))])
        host.grid.folderRenameHandler = { _, _ in }
        XCTAssertNil(host.cell("t")?.accessibilityCustomActions)
        XCTAssertNotNil(host.cell("F")?.accessibilityCustomActions)
    }

    // MARK: - Strings

    /// The new strings exist in en and ru and differ.
    func testStringsExistInBothLanguages() {
        for key in [TesseraStartScreenStrings.Key.a11yActionRenameFolder, .folderNameFieldLabel] {
            let en = TesseraStartScreenStrings.string(key, language: "en")
            let ru = TesseraStartScreenStrings.string(key, language: "ru")
            XCTAssertNotEqual(en, key.rawValue)
            XCTAssertNotEqual(ru, key.rawValue)
            XCTAssertNotEqual(en, ru)
        }
        XCTAssertEqual(TesseraStartScreenStrings.string(.a11yActionRenameFolder, language: "en"), "Rename")
        XCTAssertEqual(TesseraStartScreenStrings.string(.a11yActionRenameFolder, language: "ru"), "Переименовать")
        XCTAssertEqual(TesseraStartScreenStrings.string(.folderNameFieldLabel, language: "en"), "Folder name")
        XCTAssertEqual(TesseraStartScreenStrings.string(.folderNameFieldLabel, language: "ru"), "Имя папки")
    }

    // MARK: - Coordinator

    private final class DelegateRecorder: TesseraTileEditCoordinatorDelegate {
        var renames: [(AnyHashable, String)] = []
        var events: [String] = []

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didRenameFolder folderID: AnyHashable,
            to title: String
        ) {
            renames.append((folderID, title))
        }

        func tileEditCoordinatorDidBeginEditing(_ coordinator: TesseraTileEditCoordinator) {
            events.append("begin")
        }

        func tileEditCoordinatorDidEndEditing(_ coordinator: TesseraTileEditCoordinator) {
            events.append("end")
        }
    }

    private func makeCoordinatorHost(
        configuration: TesseraTileEditConfiguration = TesseraTileEditConfiguration(
            mergeHoverDuration: 0.05,
            magnetSnapRadius: 0
        )
    ) throws -> TesseraTestDragHost {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("a0", .small, 3, 0)],
            folders: [CellFixtureFolder("F", .medium, 0, 0, contents: [("x", .small), ("y", .small), ("z", .small)])],
            configuration: configuration
        )
        host.host.window.makeKeyAndVisible()
        return host
    }

    private func openPanel(_ host: TesseraTestDragHost) throws -> TesseraFolderPanelCell {
        let folder = try XCTUnwrap(host.folders.first)
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        return try XCTUnwrap(host.host.panelCell(folderID: "F"))
    }

    /// The coordinator installs the handler; renaming in the panel changes `TesseraTileStore`,
    /// the grid and calls the delegate once with the final name; the size, cell and
    /// contents do not change.
    func testCoordinatorHandlerRenamesStoreGridAndNotifiesDelegate() throws {
        let host = try makeCoordinatorHost()
        let delegate = DelegateRecorder()
        host.coordinator.delegate = delegate
        XCTAssertNotNil(host.host.grid.folderRenameHandler)
        let cellsBefore = host.store.snapshot(columns: 4).placementTable?.cells
        let panel = try openPanel(host)

        XCTAssertTrue(panel.beginTitleEditing())
        type("  Games ", in: panel)
        pressReturn(in: panel)

        XCTAssertEqual(host.folders.first?.title, "Games")
        XCTAssertEqual(host.host.grid.items.compactMap { $0.folder }.first?.title, "Games")
        XCTAssertEqual(delegate.renames.count, 1)
        XCTAssertEqual(delegate.renames.first?.0, "F")
        XCTAssertEqual(delegate.renames.first?.1, "Games")
        XCTAssertEqual(host.store.snapshot(columns: 4).placementTable?.cells, cellsBefore)
        XCTAssertEqual(host.folders.first?.size, .medium)
        XCTAssertEqual(host.folders.first?.tiles.count, 3)
        XCTAssertFalse(host.coordinator.isEditing, "Renaming does not enter edit mode")
    }

    /// An empty name returns the default name: the localized one or
    /// the configuration's `folderTitle`, as when creating a folder.
    func testCoordinatorEmptyNameUsesDefaultOrConfiguredTitle() throws {
        let plain = try makeCoordinatorHost()
        XCTAssertTrue(plain.coordinator.renameFolder("F", to: "Work"))
        XCTAssertTrue(plain.coordinator.renameFolder("F", to: "  "))
        XCTAssertEqual(plain.folders.first?.title, TesseraStartScreenStrings.string(.folderScreenDefaultTitle))

        let custom = try makeCoordinatorHost(
            configuration: TesseraTileEditConfiguration(folderTitle: "Mine")
        )
        XCTAssertTrue(custom.coordinator.renameFolder("F", to: "Work"))
        XCTAssertTrue(custom.coordinator.renameFolder("F", to: ""))
        XCTAssertEqual(custom.folders.first?.title, "Mine")
    }

    /// An unchanged and an unknown name give `false`, the delegate is not called.
    func testCoordinatorRenameNoOpDoesNotNotifyDelegate() throws {
        let host = try makeCoordinatorHost()
        let delegate = DelegateRecorder()
        host.coordinator.delegate = delegate

        XCTAssertFalse(host.coordinator.renameFolder("F", to: "F"))
        XCTAssertFalse(host.coordinator.renameFolder("missing", to: "X"))
        XCTAssertTrue(delegate.renames.isEmpty)
    }

    /// Renaming also works in edit mode; entering and leaving edit mode
    /// commit the name being typed.
    func testEditModeTransitionsCommitName() throws {
        let host = try makeCoordinatorHost()
        let delegate = DelegateRecorder()
        host.coordinator.delegate = delegate
        host.coordinator.beginEditing()
        let panel = try openPanel(host)

        XCTAssertTrue(panel.beginTitleEditing(), "Renaming is available in edit mode")
        type("Games", in: panel)
        host.coordinator.endEditing()
        XCTAssertEqual(host.folders.first?.title, "Games", "Leaving edit mode commits the name")
        XCTAssertFalse(host.host.grid.isEditingFolderName)

        let reopened = try XCTUnwrap(host.host.panelCell(folderID: "F"))
        XCTAssertTrue(reopened.beginTitleEditing())
        type("Work", in: reopened)
        host.coordinator.beginEditing()
        XCTAssertEqual(host.folders.first?.title, "Work", "Entering edit mode commits the name")
        XCTAssertEqual(delegate.renames.map { $0.1 }, ["Games", "Work"])
    }

    /// A tap on the grid background while the name is being edited in edit mode commits
    /// the name; edit mode stays on (leaving is a separate tap).
    func testBackgroundTapDuringRenameCommitsAndKeepsEditMode() throws {
        let host = try makeCoordinatorHost()
        host.coordinator.beginEditing()
        let panel = try openPanel(host)
        XCTAssertTrue(panel.beginTitleEditing())
        type("Games", in: panel)

        tapGridBackground(host.host.grid)
        XCTAssertEqual(host.folders.first?.title, "Games")
        XCTAssertFalse(host.host.grid.isEditingFolderName)
        XCTAssertTrue(host.coordinator.isEditing, "Committing the name does not end edit mode")
        XCTAssertEqual(host.host.grid.expandedFolderID, "F")
        host.coordinator.endEditing()
    }

    /// A disabled coordinator removes the handler (the title is static) and
    /// commits the name being typed; an enabled one restores it.
    func testDisablingCoordinatorRemovesRenameHandler() throws {
        let host = try makeCoordinatorHost()
        let panel = try openPanel(host)
        XCTAssertTrue(panel.beginTitleEditing())
        type("Games", in: panel)

        host.coordinator.isEnabled = false
        XCTAssertNil(host.host.grid.folderRenameHandler)
        XCTAssertEqual(host.folders.first?.title, "Games", "What was typed is committed before disabling")
        XCTAssertFalse(panel.isEditingTitle)
        XCTAssertFalse(panel.beginTitleEditing())

        host.coordinator.isEnabled = true
        XCTAssertNotNil(host.host.grid.folderRenameHandler)
        XCTAssertTrue(panel.beginTitleEditing())
        panel.endTitleEditing()
    }

    /// The "Rename" action on a folder tile coexists with the actions of
    /// the editor: the editor assigns and clears its own (`= nil`), "Rename"
    /// stays both in edit mode and after leaving it.
    func testRenameActionSurvivesEditorActionReconciliation() throws {
        let host = try makeCoordinatorHost()
        let renameName = TesseraStartScreenStrings.string(.a11yActionRenameFolder)
        XCTAssertEqual(actionNames(host, "F"), [renameName])

        host.coordinator.beginEditing()
        host.spin(0.1)
        let editing = actionNames(host, "F")
        XCTAssertTrue(editing.contains(TesseraStartScreenStrings.string(.a11yActionResize)), "The editor's actions are in place")
        XCTAssertEqual(editing.filter { $0 == renameName }.count, 1, "\"Rename\" appears once, no duplicates")
        host.coordinator.endEditing()
        XCTAssertEqual(actionNames(host, "F"), [renameName])
    }

    private func actionNames(_ host: TesseraTestDragHost, _ id: AnyHashable) -> [String] {
        host.host.cell(id)?.accessibilityCustomActions?.map { $0.name } ?? []
    }

    // MARK: - Gestures

    /// The name zone: the whole title row of an open panel; panel tiles, the background and
    /// a closed panel are not the name. Grid and coordinator gestures do not accept such touches.
    func testNameHitZoneIsHeaderOnly() throws {
        let host = try makeCoordinatorHost()
        let panel = try openPanel(host)
        let grid = host.host.grid
        let header = panel.titleHeaderLabel.convert(panel.titleHeaderLabel.bounds, to: grid)
        XCTAssertTrue(grid.isFolderNameHit(at: CGPoint(x: header.midX, y: header.midY)))
        XCTAssertTrue(grid.isFolderNameHit(at: CGPoint(x: header.minX + 4, y: header.midY)))

        let geometry = try XCTUnwrap(grid.panelShortcutGeometry())
        let tileFrame = geometry.frames[0]
        XCTAssertFalse(grid.isFolderNameHit(at: CGPoint(x: tileFrame.midX, y: tileFrame.midY)))
        XCTAssertFalse(grid.isFolderNameHit(at: CGPoint(x: header.midX, y: grid.bounds.height - 5)))

        grid.closeFolder(animated: false)
        XCTAssertFalse(grid.isFolderNameHit(at: CGPoint(x: header.midX, y: header.midY)), "The panel is closed")
    }

    /// A long press on the name neither enters edit mode nor starts a drag: the touch
    /// in the name zone is not accepted by the coordinator gesture, and the press itself starts
    /// name editing. A long press on a panel tile still takes it out.
    func testNameLongPressDoesNotDragAndTileLongPressStillDragsOut() throws {
        let host = try makeCoordinatorHost()
        host.coordinator.beginEditing()
        let panel = try openPanel(host)
        let grid = host.host.grid
        let panelItem = try XCTUnwrap(grid.displayItems.first { $0.isFolderPanel })

        // A long press on the name: name editing, no drag.
        XCTAssertTrue(panel.beginTitleEditing())
        XCTAssertFalse(host.coordinator.isDragging)
        XCTAssertTrue(host.coordinator.isEditing)
        panel.endTitleEditing()

        // A long press on a panel tile in edit mode: a drag out of the folder.
        let geometry = try XCTUnwrap(grid.panelShortcutGeometry())
        let frame = geometry.frames[1]
        host.coordinator.handleLongPress(on: panelItem, at: CGPoint(x: frame.midX, y: frame.midY))
        XCTAssertTrue(host.coordinator.isDragging)
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        host.coordinator.endEditing()
    }
}

#endif
