//
//  AppsListPageTests.swift
//  TesseraStartScreenTests
//
//  Tests for the right-hand page: the app list.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §6 "Right page:
//  app list + settings": a `UITableView` with letter sections and
//  `sectionIndexTitles` (the native pattern); the source of truth is `TesseraTileStore`.
//
//  Pinning from the list goes through `TesseraTileStore.pinTile(_:columns:)`
//  (a new row at the end of the canvas); unpinning goes through `TesseraTileStore.unpin(_:columns:)` and
//  `collapseEmptyRows(columns:)` (the hole stays, only an empty
//  row collapses); list sections and the reading position do not change.
//
//  The page is brought up in a real window: visible cells and the table's `contentSize`
//  exist only after layout in the window hierarchy.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class AppsListPageTests: XCTestCase {

    // MARK: - Environment

    private var directory: TesseraTestDirectory!
    private var window: UIWindow!

    override func setUp() {
        super.setUp()
        directory = TesseraTestDirectory()
    }

    override func tearDown() {
        window?.isHidden = true
        window = nil
        directory = nil
        super.tearDown()
    }

    private func makeStore(_ descriptors: [TesseraTileDescriptor]) -> TesseraTileStore {
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog(descriptors)
        return store
    }

    private func tile(
        _ title: String,
        id: String? = nil,
        icon: UIImage? = nil,
        size: TesseraTileSize = .medium
    ) -> TesseraTileDescriptor {
        TesseraTileDescriptor(id: id ?? title, title: title, icon: icon, action: {}, size: size)
    }

    /// Brings the page up in a window and returns its table.
    private func host(_ page: TesseraAppsListPageViewController) -> UITableView {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = page
        window.isHidden = false
        self.window = window
        page.view.layoutIfNeeded()
        guard let table = page.scrollView as? UITableView else {
            XCTFail("The page's scrollView must be a table")
            return UITableView()
        }
        table.layoutIfNeeded()
        return table
    }

    /// Row titles by section.
    private func rowTitles(_ page: TesseraAppsListPageViewController, _ table: UITableView) -> [[String]] {
        (0..<page.numberOfSections(in: table)).map { section in
            (0..<page.tableView(table, numberOfRowsInSection: section)).map { row in
                page.tableView(table, cellForRowAt: IndexPath(row: row, section: section)).textLabel?.text ?? ""
            }
        }
    }

    private func section(of title: String, in rows: [[String]]) -> Int? {
        rows.firstIndex { $0.contains(title) }
    }

    private func solidIcon(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    // MARK: - Sections by collation

    /// "Éclair" and "Eagle" share one index letter: diacritics do not split
    /// titles into different sections.
    func testDiacriticsShareSection() {
        let page = TesseraAppsListPageViewController.make(store: makeStore([
            tile("Éclair"), tile("Eagle"), tile("Apple"),
        ]))
        let table = host(page)
        let rows = rowTitles(page, table)

        XCTAssertNotNil(section(of: "Éclair", in: rows))
        XCTAssertEqual(section(of: "Éclair", in: rows), section(of: "Eagle", in: rows))
        // Order within a section is localized.
        if let index = section(of: "Eagle", in: rows) {
            XCTAssertEqual(rows[index], ["Eagle", "Éclair"])
        }
    }

    /// Ideographs do not produce a section per character: collation groups them
    /// (in the en locale into "#", in zh by the first pinyin letter;
    /// the chosen titles share it: "B").
    func testCJKTitlesDoNotCreateSectionPerCharacter() {
        let cjk = ["北京", "白菜", "包子"]
        let page = TesseraAppsListPageViewController.make(store: makeStore(cjk.map { tile($0) }))
        let table = host(page)
        let rows = rowTitles(page, table)

        let sections = Set(cjk.compactMap { section(of: $0, in: rows) })
        XCTAssertEqual(sections.count, 1, "CJK titles must land in one section: \(rows)")
    }

    /// Digits and symbols go into the "#" section, which is the last among tiles.
    func testDigitsAndSymbolsGoToHashSection() {
        let page = TesseraAppsListPageViewController.make(store: makeStore([
            tile("1Password"), tile("%Calc"), tile("Notes"),
        ]))
        let table = host(page)
        let rows = rowTitles(page, table)

        guard let digits = section(of: "1Password", in: rows),
              let symbols = section(of: "%Calc", in: rows),
              let notes = section(of: "Notes", in: rows)
        else { return XCTFail("Rows not found: \(rows)") }

        XCTAssertEqual(digits, symbols)
        XCTAssertEqual(page.tableView(table, titleForHeaderInSection: digits), "#")
        XCTAssertLessThan(notes, digits)
    }

    /// The jump list is the native collation index, and jumping to an empty letter
    /// leads to the nearest non-empty section.
    func testSectionIndexTitlesComeFromCollation() {
        let page = TesseraAppsListPageViewController.make(store: makeStore([
            tile("Apple"), tile("Mail"), tile("Zoom"),
        ]))
        let table = host(page)
        let collation = UILocalizedIndexedCollation.current()

        XCTAssertEqual(page.sectionIndexTitles(for: table), collation.sectionIndexTitles)

        let indexTitles = collation.sectionIndexTitles
        let rows = rowTitles(page, table)
        guard let mailSection = section(of: "Mail", in: rows) else {
            return XCTFail("No Mail section")
        }
        // The index of the letter "M" leads to the Mail section.
        if let mailIndex = indexTitles.firstIndex(of: "M") {
            XCTAssertEqual(
                page.tableView(table, sectionForSectionIndexTitle: indexTitles[mailIndex], at: mailIndex),
                mailSection
            )
        }
        // Any index yields a valid section.
        for (index, title) in indexTitles.enumerated() {
            let target = page.tableView(table, sectionForSectionIndexTitle: title, at: index)
            XCTAssertTrue((0..<page.numberOfSections(in: table)).contains(target))
        }
    }

    // MARK: - Icon in the row signature

    /// Changing the icon with the same id/title redraws the visible row.
    func testIconChangeRefreshesVisibleRow() {
        let store = makeStore([tile("Mail", id: "mail", icon: solidIcon(.red))])
        let page = TesseraAppsListPageViewController.make(store: store)
        let table = host(page)

        let indexPath = IndexPath(row: 0, section: 0)
        guard let before = table.cellForRow(at: indexPath)?.imageView?.image else {
            return XCTFail("Row is not visible or has no icon")
        }

        store.setCatalog([tile("Mail", id: "mail", icon: solidIcon(.blue))])
        table.layoutIfNeeded()

        let after = table.cellForRow(at: indexPath)?.imageView?.image
        XCTAssertNotNil(after)
        XCTAssertFalse(before === after, "The new icon must reach the visible row")
    }

    // MARK: - Offset after reloadData

    /// The catalog shrank: the previous offset beyond the content is clamped
    /// right after the reload, not "eventually" by the next UIKit layout pass
    /// (before the fix the page forcibly restored an offset of 3600+ pt with
    /// three rows of content).
    func testOffsetIsClampedAfterCatalogShrinks() {
        let titles = (0..<80).map { String(format: "App %02d", $0) }
        let store = makeStore(titles.map { tile($0) })
        let page = TesseraAppsListPageViewController.make(store: store)
        let table = host(page)

        let inset = table.adjustedContentInset
        let bottom = table.contentSize.height + inset.bottom - table.bounds.height
        XCTAssertGreaterThan(bottom, 1000)
        table.setContentOffset(CGPoint(x: table.contentOffset.x, y: bottom), animated: false)

        store.setCatalog(titles.prefix(3).map { tile($0) })

        assertOffsetInRange(table, "right after reload")
        // Three rows fit on screen: the reading position returns to the start.
        XCTAssertEqual(table.contentOffset.y, -table.adjustedContentInset.top, accuracy: 0.5)

        table.layoutIfNeeded()
        assertOffsetInRange(table, "after layout")
    }

    /// A reading position within the valid range is preserved (§6: unpin on
    /// the grid does not "jump" the list to the start). The exact value is not checked:
    /// with `automaticDimension` UIKit refines the offset itself as it measures
    /// estimated rows.
    func testOffsetIsPreservedWhenStillValid() {
        let titles = (0..<80).map { String(format: "App %02d", $0) }
        let store = makeStore(titles.map { tile($0) })
        let page = TesseraAppsListPageViewController.make(store: store)
        let table = host(page)

        table.setContentOffset(CGPoint(x: table.contentOffset.x, y: 300), animated: false)
        table.layoutIfNeeded()

        store.setCatalog(titles.prefix(70).map { tile($0) })
        assertOffsetInRange(table, "right after reload")
        XCTAssertGreaterThan(table.contentOffset.y, 200, "The list must not jump to the start")

        table.layoutIfNeeded()
        assertOffsetInRange(table, "after layout")
        XCTAssertGreaterThan(table.contentOffset.y, 200, "The list must not jump to the start")
    }

    private func assertOffsetInRange(
        _ table: UITableView,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let inset = table.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, table.contentSize.height + inset.bottom - table.bounds.height)
        XCTAssertLessThanOrEqual(table.contentOffset.y, maxY + 0.5, message, file: file, line: line)
        XCTAssertGreaterThanOrEqual(table.contentOffset.y, minY - 0.5, message, file: file, line: line)
    }

    // MARK: - Pin/unpin through grid columns

    // Pin/unpin is performed by the page's production method `setPinned(_:for:)`,
    // the same one the row's accessory button and the custom
    // VoiceOver action call. UI events (taps) are unreliable in the test runner, so the test does not
    // simulate touches but calls the production entry point directly; the row's UI wiring
    // is checked separately through metadata: the button is present, its label
    // matches the state, the target-action is registered, and the row has
    // the current accessibility value/custom action.

    /// Identifiers of the grid's visible-order items.
    private func ids(_ store: TesseraTileStore) -> [AnyHashable] {
        store.snapshot().items.map { $0.id }
    }

    /// Table section titles in order.
    private func sectionTitles(
        _ page: TesseraAppsListPageViewController,
        _ table: UITableView
    ) -> [String?] {
        (0..<page.numberOfSections(in: table)).map {
            page.tableView(table, titleForHeaderInSection: $0)
        }
    }

    /// Position of the row with the title `title` (through the page's data source).
    private func indexPath(
        of title: String,
        page: TesseraAppsListPageViewController,
        table: UITableView
    ) -> IndexPath? {
        for section in 0..<page.numberOfSections(in: table) {
            for row in 0..<page.tableView(table, numberOfRowsInSection: section) {
                let indexPath = IndexPath(row: row, section: section)
                let cell = page.tableView(table, cellForRowAt: indexPath)
                if cell.textLabel?.text == title { return indexPath }
            }
        }
        return nil
    }

    /// The row's cell: a visible one follows the same path as the user; for a row off
    /// screen, the data source cell (without scrolling, so as not to change the reading
    /// position in the offset tests).
    private func cell(
        forTitle title: String,
        page: TesseraAppsListPageViewController,
        table: UITableView
    ) -> UITableViewCell? {
        guard let indexPath = indexPath(of: title, page: page, table: table) else {
            return nil
        }
        return table.cellForRow(at: indexPath)
            ?? page.tableView(table, cellForRowAt: indexPath)
    }

    /// Checks the pin row's UI wiring: the accessory button, its label and
    /// the registered target-action, and the row's accessibility state.
    private func assertPinButton(
        forTitle title: String,
        pinned: Bool,
        page: TesseraAppsListPageViewController,
        table: UITableView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let cell = cell(forTitle: title, page: page, table: table) else {
            return XCTFail("No row \"\(title)\" in the list", file: file, line: line)
        }
        guard let button = cell.accessoryView as? UIButton else {
            return XCTFail("Row \"\(title)\" has no pin button", file: file, line: line)
        }
        let expectedTitle = pinned ? page.texts.unpinActionTitle : page.texts.pinActionTitle
        XCTAssertEqual(button.accessibilityLabel, expectedTitle, file: file, line: line)
        let selectors = button.actions(forTarget: button, forControlEvent: .touchUpInside) ?? []
        XCTAssertFalse(
            selectors.isEmpty,
            "the target-action is not registered on the button of row \"\(title)\"",
            file: file,
            line: line
        )
        XCTAssertEqual(
            cell.accessibilityValue,
            pinned ? page.texts.pinnedValue : nil,
            file: file,
            line: line
        )
        XCTAssertEqual(
            cell.accessibilityCustomActions?.first?.name,
            expectedTitle,
            file: file,
            line: line
        )
    }

    /// Pins or unpins a tile through the same page method as the button and
    /// (``TesseraAppsListPageViewController/setPinned(_:for:)``).
    @discardableResult
    private func pin(
        _ pinned: Bool,
        forTileID id: AnyHashable,
        title: String,
        page: TesseraAppsListPageViewController,
        table: UITableView
    ) -> Bool {
        assertPinButton(forTitle: title, pinned: !pinned, page: page, table: table)
        return page.setPinned(pinned, for: id)
    }

    /// Checks that the snapshot order is the reading order of the compact layout:
    /// `pack` slots go strictly by (row, column) in snapshot order.
    private func assertReadingOrder(
        _ store: TesseraTileStore,
        columns: Int,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let items = store.snapshot().layoutItems
        let slots = TesseraTileLayoutEngine.pack(items: items, columns: columns, unit: 1)
        XCTAssertEqual(slots.count, items.count, message(), file: file, line: line)
        for (previous, next) in zip(slots, slots.dropFirst()) {
            let ordered = previous.row < next.row
                || (previous.row == next.row && previous.column < next.column)
            XCTAssertTrue(
                ordered,
                "\(message()) snapshot order does not match reading order: "
                    + "\(previous.id)(\(previous.row),\(previous.column)) → "
                    + "\(next.id)(\(next.row),\(next.column))",
                file: file,
                line: line
            )
        }
    }

    /// Checks that the snapshot order is the reading order of the model cells:
    /// row, then column; holes do not change the order.
    private func assertCellReadingOrder(
        _ store: TesseraTileStore,
        columns: Int,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            store.placementReadingOrder(forColumns: columns),
            store.snapshot().items.map { $0.id },
            message(),
            file: file,
            line: line
        )
    }

    /// Pinning from the list passes the grid's column count to the store: the tile is placed in a
    /// **new row** at the end of the canvas (D33) in a single operation; holes above
    /// are not filled.
    ///
    /// "Aurora" (2×2) and "Wide" (4×2) on 4 columns; "Spark" (1×1) is unpinned.
    /// After pinning, Spark sits at (4, 0) below "Wide", and the reading order is [A, W, S].
    func testPinFromListUsesGridColumnsAndPlacesTileInNewRow() {
        let store = makeStore([
            tile("Aurora", id: "a", size: .medium),
            tile("Wide", id: "w", size: .wide),
            tile("Spark", id: "s", size: .small),
        ])
        XCTAssertTrue(store.unpin("s", columns: 4))
        XCTAssertEqual(ids(store), ["a", "w"])
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["s"])

        let page = TesseraAppsListPageViewController.make(store: store, columns: 4)
        let table = host(page)
        let structureBefore = rowTitles(page, table)
        let sectionsBefore = sectionTitles(page, table)

        var changes = 0
        store.onChange = { _ in changes += 1 }
        XCTAssertTrue(pin(true, forTileID: "s", title: "Spark", page: page, table: table))

        XCTAssertEqual(changes, 1, "pin is one model operation")
        XCTAssertTrue(store.isPinned("s"))
        XCTAssertTrue(store.snapshot().unpinned.isEmpty)
        XCTAssertEqual(ids(store), ["a", "w", "s"], "model order is the cell reading order")
        XCTAssertEqual(store.placement(of: "s"), TesseraTileGridPlacement(row: 4, column: 0), "new row after \"Wide\"")
        XCTAssertEqual(
            store.snapshot().items.firstIndex { $0.id == AnyHashable("s") },
            2,
            "tile index in reading order"
        )
        assertCellReadingOrder(store, columns: 4, "after pin from the list")
        XCTAssertEqual(rowTitles(page, table), structureBefore, "pin does not change list sections")
        XCTAssertEqual(sectionTitles(page, table), sectionsBefore)
        // Two-way link (§6): the row immediately reflects the new state.
        assertPinButton(forTitle: "Spark", pinned: true, page: page, table: table)
    }

    /// The row button really triggers pin: its registered
    /// target-action (`handleTap` → `onTap` → `setPinned`) changes the store.
    ///
    /// The UI event is not simulated (touches are unreliable in the test runner), so the
    /// registered target-action is called directly; this is exactly the
    /// method UIKit calls on a tap.
    func testPinButtonHandlerPinsTile() {
        let store = makeStore([
            tile("Aurora", id: "a", size: .medium),
            tile("Wide", id: "w", size: .wide),
            tile("Spark", id: "s", size: .small),
        ])
        XCTAssertTrue(store.unpin("s", columns: 4))

        let page = TesseraAppsListPageViewController.make(store: store, columns: 4)
        let table = host(page)
        guard let cell = cell(forTitle: "Spark", page: page, table: table),
              let button = cell.accessoryView as? UIButton
        else {
            return XCTFail("The Spark row has no pin button")
        }
        XCTAssertTrue(button.isEnabled)
        guard let selectorName = button.actions(
            forTarget: button,
            forControlEvent: .touchUpInside
        )?.first else {
            return XCTFail("The button has no touchUpInside target-action")
        }

        _ = button.perform(NSSelectorFromString(selectorName))

        XCTAssertTrue(store.isPinned("s"))
        XCTAssertEqual(ids(store), ["a", "w", "s"], "pin goes into a new row at the end")
    }

    /// Fallback `columns == nil`: the host did not report the layout to the page, so pin uses
    /// the width known to the store (`effectiveColumns`) and places the tile in a new
    /// row at the end of the canvas.
    func testPinWithoutColumnsUsesStoreWidthAndAppendsToNewRow() {
        let store = makeStore([
            tile("Aurora", id: "a", size: .medium),
            tile("Wide", id: "w", size: .wide),
            tile("Spark", id: "s", size: .small),
        ])
        XCTAssertTrue(store.unpin("s", columns: 4))

        let page = TesseraAppsListPageViewController.make(store: store)
        let table = host(page)
        XCTAssertTrue(pin(true, forTileID: "s", title: "Spark", page: page, table: table))

        XCTAssertTrue(store.isPinned("s"))
        XCTAssertEqual(ids(store), ["a", "w", "s"], "without columns the page uses the store width: a new row at the end")
        XCTAssertEqual(store.snapshot().items.firstIndex { $0.id == AnyHashable("s") }, 2)
    }

    /// Unpinning from the list leaves a hole in the tile's place and does not repack the grid
    /// (D30): afterwards the page collapses only a fully empty
    /// row (D31). List sections and their rows do not change: the tile
    /// stays in the catalog, only its state changes.
    ///
    /// "Alpha" (1×1), "Bravo" (2×2), "Whiskey" (4×2), "Charlie" (2×2) on
    /// 4 columns: Alpha (0,0), Bravo (0,1), Whiskey (2,0), Charlie (4,0). After
    /// removing Alpha, its cell is a hole and the others stay in place (Bravo stays in
    /// row 0, so there is nothing to collapse).
    func testUnpinFromListLeavesHoleWithoutRepacking() {
        let store = makeStore([
            tile("Alpha", id: "a", size: .small),
            tile("Bravo", id: "b", size: .medium),
            tile("Whiskey", id: "w", size: .wide),
            tile("Charlie", id: "c", size: .medium),
        ])
        XCTAssertEqual(ids(store), ["a", "b", "w", "c"])
        assertReadingOrder(store, columns: 4, "before unpin")

        let page = TesseraAppsListPageViewController.make(store: store, columns: 4)
        let table = host(page)
        let structureBefore = rowTitles(page, table)
        let sectionsBefore = sectionTitles(page, table)

        var changes = 0
        store.onChange = { _ in changes += 1 }
        XCTAssertTrue(pin(false, forTileID: "a", title: "Alpha", page: page, table: table))

        XCTAssertEqual(changes, 1, "unpin is one model change: there are no empty rows, nothing to collapse")
        XCTAssertFalse(store.isPinned("a"))
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["a"])
        XCTAssertEqual(ids(store), ["b", "w", "c"], "order is the cell reading order, without repacking")
        XCTAssertEqual(store.placement(of: "b"), TesseraTileGridPlacement(row: 0, column: 1), "the hole at \"Alpha\" remains")
        XCTAssertEqual(store.placement(of: "c"), TesseraTileGridPlacement(row: 4, column: 0))
        assertCellReadingOrder(store, columns: 4, "after unpin from the list")
        XCTAssertEqual(rowTitles(page, table), structureBefore, "unpin does not change list sections")
        XCTAssertEqual(sectionTitles(page, table), sectionsBefore)
        assertPinButton(forTitle: "Alpha", pinned: false, page: page, table: table)
    }

    /// Unpinning the last tile of a row from the list collapses the empty row (D31):
    /// "Whiskey" (4×2) occupies rows 2–3 alone, so "Charlie" moves up.
    func testUnpinFromListCollapsesFullyEmptyRow() {
        let store = makeStore([
            tile("Alpha", id: "a", size: .small),
            tile("Bravo", id: "b", size: .medium),
            tile("Whiskey", id: "w", size: .wide),
            tile("Charlie", id: "c", size: .medium),
        ])
        let page = TesseraAppsListPageViewController.make(store: store, columns: 4)
        let table = host(page)

        var changes = 0
        store.onChange = { _ in changes += 1 }
        XCTAssertTrue(pin(false, forTileID: "w", title: "Whiskey", page: page, table: table))

        XCTAssertEqual(changes, 2, "unpin and row collapse are two model changes")
        XCTAssertEqual(ids(store), ["a", "b", "c"])
        XCTAssertEqual(store.placement(of: "a"), TesseraTileGridPlacement(row: 0, column: 0))
        XCTAssertEqual(store.placement(of: "c"), TesseraTileGridPlacement(row: 2, column: 0), "rows 2–3 collapsed")
        assertCellReadingOrder(store, columns: 4, "after unpin and collapse")
    }

    /// Unpinning from the list does not reload the table: the set of rows (sections) does not
    /// change and the reading position is preserved (§6: unpin does not "jump").
    func testUnpinFromListKeepsSectionsAndOffset() {
        let titles = (0..<60).map { String(format: "App %02d", $0) }
        let store = makeStore(titles.map { tile($0, size: .small) })
        let page = TesseraAppsListPageViewController.make(store: store, columns: 4)
        let table = host(page)

        table.setContentOffset(CGPoint(x: table.contentOffset.x, y: 300), animated: false)
        table.layoutIfNeeded()

        let structureBefore = rowTitles(page, table)
        let sectionsBefore = sectionTitles(page, table)
        let offsetBefore = table.contentOffset

        var changes = 0
        store.onChange = { _ in changes += 1 }
        XCTAssertTrue(pin(false, forTileID: "App 00", title: "App 00", page: page, table: table))

        XCTAssertEqual(changes, 1, "order is already canonical: unpin is one change")
        XCTAssertFalse(store.isPinned("App 00"))
        XCTAssertEqual(ids(store).count, titles.count - 1)
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["App 00"])
        XCTAssertEqual(rowTitles(page, table), structureBefore, "unpin does not change list rows")
        XCTAssertEqual(sectionTitles(page, table), sectionsBefore)
        XCTAssertEqual(table.contentOffset.y, offsetBefore.y, accuracy: 0.5, "the reading position is preserved")
        assertOffsetInRange(table, "after unpin from the list")
        XCTAssertGreaterThan(table.contentOffset.y, 250, "the list must not jump to the start")
    }

    /// Unpinning a tile from a folder: the folder is not dissolved (D45: two
    /// tiles remain in it; a two-tile folder would be dissolved), list rows and sections do not
    /// change: the tile stays in the catalog in the "not pinned" state, and
    /// the store stays consistent.
    func testUnpinFromFolderKeepsSectionsStable() {
        let store = makeStore([
            tile("Alpha", id: "a", size: .small),
            tile("Bravo", id: "b", size: .small),
            tile("Charlie", id: "c", size: .small),
        ])
        guard let folder = store.createFolder(withTile: "a", title: "Group", columns: 4) else {
            return XCTFail("Failed to create a folder")
        }
        XCTAssertTrue(store.addToFolder("b", folderID: folder.id, columns: 4))
        XCTAssertTrue(store.addToFolder("c", folderID: folder.id, columns: 4))
        XCTAssertEqual(ids(store), [folder.id])

        let page = TesseraAppsListPageViewController.make(store: store, columns: 4)
        let table = host(page)
        let structureBefore = rowTitles(page, table)
        let sectionsBefore = sectionTitles(page, table)
        XCTAssertEqual(structureBefore.flatMap { $0 }, ["Alpha", "Bravo", "Charlie"])

        XCTAssertTrue(pin(false, forTileID: "a", title: "Alpha", page: page, table: table))

        XCTAssertFalse(store.isPinned("a"))
        XCTAssertTrue(store.isPinned("b"))
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["a"])
        XCTAssertEqual(
            store.snapshot().folders.first?.tiles.map { $0.id },
            ["b", "c"],
            "the folder remains: it has two tiles"
        )
        assertReadingOrder(store, columns: 4, "after unpin from a folder")
        XCTAssertEqual(rowTitles(page, table), structureBefore)
        XCTAssertEqual(sectionTitles(page, table), sectionsBefore)
        assertPinButton(forTitle: "Alpha", pinned: false, page: page, table: table)
        assertPinButton(forTitle: "Bravo", pinned: true, page: page, table: table)
    }
}

#endif
