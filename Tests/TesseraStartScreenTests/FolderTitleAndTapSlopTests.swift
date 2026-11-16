//
//  FolderTitleAndTapSlopTests.swift
//  TesseraStartScreenTests
//
//  Тесты E12.7 (мелкие находки ручного прогона Example):
//  - новая папка получает локализованное название по умолчанию (строки
//    модуля, а не литерал; `TesseraTileEditConfiguration.folderTitle` его
//    перекрывает), а заголовок панели показывает название как набрано;
//  - касание, ушедшее дальше допуска, не считается тапом по плитке.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class FolderTitleAndTapSlopTests: XCTestCase {

    // MARK: - Название папки по умолчанию

    /// Строка по умолчанию различается в en/ru и не пуста.
    func testDefaultFolderTitleIsLocalizedInBothLanguages() {
        let russian = TesseraStartScreenStrings.string(.folderScreenDefaultTitle, language: "ru")
        let english = TesseraStartScreenStrings.string(.folderScreenDefaultTitle, language: "en")
        XCTAssertFalse(russian.isEmpty)
        XCTAssertFalse(english.isEmpty)
        XCTAssertNotEqual(russian, english)
    }

    /// Папка, созданная координатором без названия, получает название по
    /// умолчанию; явное название и `folderTitle` конфигурации его перекрывают.
    func testCoordinatorCreatedFolderGetsDefaultTitle() throws {
        let fallback = TesseraStartScreenStrings.string(.folderScreenDefaultTitle)
        let host = TesseraTestDragHost(descriptors: [tesseraTestTile("a"), tesseraTestTile("b")])

        let first = try XCTUnwrap(host.coordinator.createFolder(withTile: "a"))
        XCTAssertEqual(first.title, fallback)

        let second = try XCTUnwrap(host.coordinator.createFolder(withTile: "b", title: "Работа"))
        XCTAssertEqual(second.title, "Работа", "Явное название не заменяется")

        let custom = TesseraTestDragHost(
            descriptors: [tesseraTestTile("a")],
            configuration: TesseraTileEditConfiguration(folderTitle: "Мои")
        )
        XCTAssertEqual(try XCTUnwrap(custom.coordinator.createFolder(withTile: "a")).title, "Мои")
    }

    /// Папка, созданная drop'ом ярлыка на ярлык (атомарный путь), тоже
    /// получает название по умолчанию.
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

    /// Хранилище по-прежнему принимает пустое название (подстановка — только
    /// на пути создания папки редактором).
    func testStoreStillAcceptsEmptyFolderTitle() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog([tesseraTestTile("a")])
        XCTAssertEqual(try XCTUnwrap(store.createFolder(withTile: "a", columns: 4)).title, "")
    }

    // MARK: - Заголовок панели и подпись плитки папки

    /// Ищет подписи внутри вью (рекурсивно).
    private func allLabels(in view: UIView) -> [UILabel] {
        var result: [UILabel] = []
        for subview in view.subviews {
            if let label = subview as? UILabel { result.append(label) }
            result += allLabels(in: subview)
        }
        return result
    }

    /// Заголовок панели — как набрано, без приведения к нижнему регистру;
    /// пустое название заменяется названием по умолчанию.
    func testPanelHeadingShowsTitleAsTypedAndFallsBackWhenEmpty() throws {
        let typed = TesseraTileFolder(id: "f1", title: "Работа", tiles: [tesseraTestTile("a")])
        let empty = TesseraTileFolder(id: "f2", title: "", tiles: [tesseraTestTile("b")])

        for (folder, expected) in [
            (typed, "Работа"),
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

    /// Плитка папки без названия подписывается названием по умолчанию.
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

    // MARK: - Допуск смещения тапа

    /// Сетка с одной плиткой и счётчиком `onTap`.
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

    /// Выбор ячейки без смещения касания — тап; со смещением дальше допуска —
    /// не тап, и следующий выбор после нового касания снова работает.
    func testSelectionAfterMovementBeyondSlopIsNotATap() throws {
        var tapped: [AnyHashable] = []
        let (grid, collectionView) = try makeGrid { tapped.append($0.id) }
        let indexPath = IndexPath(item: 0, section: 0)

        grid.collectionView(collectionView, didSelectItemAt: indexPath)
        XCTAssertEqual(tapped, ["a"], "Обычный тап проходит")

        grid.tapSlopRecognizer.exceededSlop = true
        grid.collectionView(collectionView, didSelectItemAt: indexPath)
        XCTAssertEqual(tapped, ["a"], "Длинный свайп не вызывает тап")

        grid.tapSlopRecognizer.exceededSlop = false
        grid.collectionView(collectionView, didSelectItemAt: indexPath)
        XCTAssertEqual(tapped, ["a", "a"], "Новое касание без смещения — снова тап")
    }

    /// Наблюдатель смещения стоит на коллекции и не вмешивается в касания.
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
