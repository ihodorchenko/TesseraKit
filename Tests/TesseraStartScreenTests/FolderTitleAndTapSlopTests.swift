//
//  FolderTitleAndTapSlopTests.swift
//  TesseraStartScreenTests
//
//  Tests for minor findings from manual Example runs:
//  - a new folder gets a localized default title (module strings,
//    not a literal; `TesseraTileEditConfiguration.folderTitle` overrides it), and the panel
//    heading shows the title as typed;
//  - a touch that moved beyond the slop is not treated as a tap on a tile.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class FolderTitleAndTapSlopTests: XCTestCase {

    // MARK: - Default folder title

    /// The default string differs between en and ru and is non-empty.
    func testDefaultFolderTitleIsLocalizedInBothLanguages() {
        let russian = TesseraStartScreenStrings.string(.folderScreenDefaultTitle, language: "ru")
        let english = TesseraStartScreenStrings.string(.folderScreenDefaultTitle, language: "en")
        XCTAssertFalse(russian.isEmpty)
        XCTAssertFalse(english.isEmpty)
        XCTAssertNotEqual(russian, english)
    }

    /// A folder created by the coordinator without a title gets the default
    /// title; an explicit title and the configuration's `folderTitle` override it.
    func testCoordinatorCreatedFolderGetsDefaultTitle() throws {
        let fallback = TesseraStartScreenStrings.string(.folderScreenDefaultTitle)
        let host = TesseraTestDragHost(descriptors: [tesseraTestTile("a"), tesseraTestTile("b")])

        let first = try XCTUnwrap(host.coordinator.createFolder(withTile: "a"))
        XCTAssertEqual(first.title, fallback)

        let second = try XCTUnwrap(host.coordinator.createFolder(withTile: "b", title: "Work"))
        XCTAssertEqual(second.title, "Work", "An explicit title is not replaced")

        let custom = TesseraTestDragHost(
            descriptors: [tesseraTestTile("a")],
            configuration: TesseraTileEditConfiguration(folderTitle: "Mine")
        )
        XCTAssertEqual(try XCTUnwrap(custom.coordinator.createFolder(withTile: "a")).title, "Mine")
    }

    /// A folder created by dropping a tile onto a tile (the atomic path) also
    /// gets the default title.
    func testDropCreatedFolderGetsDefaultTitle() throws {
        let host = TesseraTestDragHost(
            descriptors: [tesseraTestTile("t", size: .medium), tesseraTestTile("s", size: .small)],
            configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.1)
        )
        let center = try XCTUnwrap(host.point("t"))
        XCTAssertTrue(host.startDrag("s"))
        host.coordinator.updateDrag(to: center)
        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })
        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { !host.folders.isEmpty })
        XCTAssertEqual(
            host.folders.first?.title,
            TesseraStartScreenStrings.string(.folderScreenDefaultTitle)
        )
    }

    /// The store still accepts an empty title (the fallback applies only
    /// on the editor's folder creation path).
    func testStoreStillAcceptsEmptyFolderTitle() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog([tesseraTestTile("a")])
        XCTAssertEqual(try XCTUnwrap(store.createFolder(withTile: "a", columns: 4)).title, "")
    }

    // MARK: - Panel heading and folder tile label

    /// Finds labels inside a view (recursively).
    private func allLabels(in view: UIView) -> [UILabel] {
        var result: [UILabel] = []
        for subview in view.subviews {
            if let label = subview as? UILabel { result.append(label) }
            result += allLabels(in: subview)
        }
        return result
    }

    /// The panel heading shows the title as typed, without lowercasing;
    /// an empty title is replaced by the default title.
    func testPanelHeadingShowsTitleAsTypedAndFallsBackWhenEmpty() throws {
        let typed = TesseraTileFolder(id: "f1", title: "Work", tiles: [tesseraTestTile("a")])
        let empty = TesseraTileFolder(id: "f2", title: "", tiles: [tesseraTestTile("b")])

        for (folder, expected) in [
            (typed, "Work"),
            (empty, TesseraStartScreenStrings.string(.folderScreenDefaultTitle)),
        ] {
            let grid = TesseraTileGridView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            grid.columns = 4
            grid.reload(snapshot: TesseraTileGridSnapshot(items: [.folder(folder)], unpinned: []))
            grid.layoutIfNeeded()
            grid.openFolder(folder, animated: false)
            grid.layoutIfNeeded()
            let collectionView = try XCTUnwrap(grid.subviews.compactMap { $0 as? UICollectionView }.first)
            collectionView.layoutIfNeeded()
            let panelIndex = try XCTUnwrap(grid.displayItems.firstIndex { $0.isFolderPanel })
            let panel = try XCTUnwrap(
                collectionView.cellForItem(at: IndexPath(item: panelIndex, section: 0)) as? TesseraFolderPanelCell
            )
            let header = allLabels(in: panel).first { $0.accessibilityTraits.contains(.header) }
            XCTAssertEqual(header?.text, expected)
            XCTAssertEqual(header?.accessibilityLabel, expected)
        }
    }

    /// A folder tile without a title is labelled with the default title.
    func testFolderTileWithoutTitleShowsDefaultTitle() throws {
        let empty = TesseraTileFolder(id: "f", title: "", tiles: [tesseraTestTile("a")])
        let grid = TesseraTileGridView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        grid.columns = 4
        grid.reload(snapshot: TesseraTileGridSnapshot(items: [.folder(empty)], unpinned: []))
        grid.layoutIfNeeded()
        let collectionView = try XCTUnwrap(grid.subviews.compactMap { $0 as? UICollectionView }.first)
        collectionView.layoutIfNeeded()
        let cell = try XCTUnwrap(collectionView.cellForItem(at: IndexPath(item: 0, section: 0)))
        XCTAssertEqual(
            cell.accessibilityLabel,
            TesseraStartScreenStrings.string(.folderScreenDefaultTitle)
        )
        XCTAssertTrue(allLabels(in: cell).contains {
            $0.text == TesseraStartScreenStrings.string(.folderScreenDefaultTitle)
        })
    }

    // MARK: - Tap slop

    /// A grid with one tile and an `onTap` counter.
    private func makeGrid(taps: @escaping (TesseraTileGridItem) -> Void) throws -> (TesseraTileGridView, UICollectionView) {
        let grid = TesseraTileGridView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        grid.columns = 4
        grid.onTap = taps
        grid.reload(snapshot: TesseraTileGridSnapshot(items: [.tile(tesseraTestTile("a"))], unpinned: []))
        grid.layoutIfNeeded()
        let collectionView = try XCTUnwrap(grid.subviews.compactMap { $0 as? UICollectionView }.first)
        collectionView.layoutIfNeeded()
        return (grid, collectionView)
    }

    /// Selecting a cell without touch movement is a tap; with movement beyond the slop it is
    /// not a tap, and the next selection after a new touch works again.
    func testSelectionAfterMovementBeyondSlopIsNotATap() throws {
        var tapped: [AnyHashable] = []
        let (grid, collectionView) = try makeGrid { tapped.append($0.id) }
        let indexPath = IndexPath(item: 0, section: 0)

        grid.collectionView(collectionView, didSelectItemAt: indexPath)
        XCTAssertEqual(tapped, ["a"], "A plain tap goes through")

        grid.tapSlopRecognizer.exceededSlop = true
        grid.collectionView(collectionView, didSelectItemAt: indexPath)
        XCTAssertEqual(tapped, ["a"], "A long swipe does not trigger a tap")

        grid.tapSlopRecognizer.exceededSlop = false
        grid.collectionView(collectionView, didSelectItemAt: indexPath)
        XCTAssertEqual(tapped, ["a", "a"], "A new touch without movement is a tap again")
    }

    /// The movement observer sits on the collection view and does not interfere with touches.
    func testSlopRecognizerIsPassiveAndInstalled() throws {
        let (grid, collectionView) = try makeGrid { _ in }
        let recognizer = grid.tapSlopRecognizer
        XCTAssertTrue(collectionView.gestureRecognizers?.contains { $0 === recognizer } ?? false)
        XCTAssertFalse(recognizer.cancelsTouchesInView)
        XCTAssertFalse(recognizer.delaysTouchesBegan)
        XCTAssertFalse(recognizer.delaysTouchesEnded)
        XCTAssertEqual(TesseraTileTapSlopRecognizer.slop, 10)
    }
}

#endif
