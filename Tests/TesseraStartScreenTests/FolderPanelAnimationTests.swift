//
//  FolderPanelAnimationTests.swift
//  TesseraStartScreenTests
//
//  Анимации панели раскрытой папки (E10.2, волна W3 плана E9/E10).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка»,
//  §5 «Режим редактирования» (блокировка прокрутки), §9 «Accessibility»
//  (озвучивание состояния, `.layoutChanged`, Dynamic Type); D17/D18 в
//  docs/STATE.md — панель раскрывается инлайн, одновременно открыта максимум
//  одна папка.
//
//  Проверяется сериализация переходов панели:
//  - смена папки A → B не смешивает `reloadData` и `performBatchUpdates` в
//    одном проходе runloop (иначе `NSInternalInconsistencyException`);
//  - `update(snapshot:)` посреди открытия/закрытия запоминается и применяется
//    после завершения перехода;
//  - `isScrollEnabled` имеет одного владельца: блокировка drag-координатора
//    переживает завершение анимации панели;
//  - `clampContentOffsetAfterCollapse` работает и в неанимированной ветке
//    закрытия;
//  - `.layoutChanged` публикуется во всех четырёх ветках (open/close ×
//    animated/не animated), включая Reduce Motion;
//  - `accessibilityValue` папки сообщает «раскрыта», не теряя число ярлыков;
//  - шрифт заголовка панели масштабируется Dynamic Type и укладывается в
//    фиксированную высоту строки панели.
//
//  Анимации настоящие (UIViewPropertyAnimator + batch-обновления), поэтому
//  тесты с окном: `TesseraTestWindowedGrid`. Завершение перехода ожидается
//  прокруткой run loop (`waitForFolderTransition`), без фиксированных пауз.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class FolderPanelAnimationTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Сетка вне окна: неанимированные ветки и геометрия без UI-цикла.
    ///
    /// - Parameter items: Элементы снимка в порядке отображения.
    /// - Returns: Разложенная сетка.
    private func makeGrid(_ items: [TileGridItem]) -> TesseraTileGridView {
        let grid = TesseraTileGridView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        grid.columns = 4
        grid.reload(snapshot: TileGridSnapshot(items: items, unpinned: []))
        layout(grid)
        return grid
    }

    /// Прогоняет layout сетки и её коллекции: ячейки и рамки актуальны.
    ///
    /// - Parameter grid: Сетка.
    private func layout(_ grid: TesseraTileGridView) {
        grid.layoutIfNeeded()
        grid.subviews
            .compactMap { $0 as? UICollectionView }
            .forEach { $0.layoutIfNeeded() }
    }

    /// Индексы панелей раскрытой папки в наборе коллекции.
    ///
    /// - Parameter grid: Сетка.
    /// - Returns: Индексы элементов `folderContent`.
    private func panelIndices(in grid: TesseraTileGridView) -> [Int] {
        grid.displayItems.indices.filter { grid.displayItems[$0].isFolderPanel }
    }

    // MARK: - Смена папки A → B (E10.2)

    /// Пока открыта папка A, повторный тап по B не должен запускать
    /// `reloadData` и `performBatchUpdates` в одном проходе runloop: A
    /// сворачивается мгновенно, B открывается следующим проходом. Итог — открыта
    /// ровно одна папка, события хоста идут парой «закрылась A — открылась B».
    func testOpeningAnotherFolderSerializesTransitions() {
        let first = tesseraTestFolder("first", tileCount: 4)
        let second = tesseraTestFolder("second", tileCount: 4)
        let host = TesseraTestWindowedGrid(items: [.folder(first), .folder(second)])

        var events: [(id: AnyHashable, expanded: Bool)] = []
        host.grid.onFolderExpansionChanged = { folder, expanded in
            events.append((folder.id, expanded))
        }

        host.grid.openFolder(first)
        XCTAssertTrue(host.waitForFolderTransition(), "Открытие A завершилось")
        XCTAssertEqual(host.grid.expandedFolderID, first.id)

        host.grid.openFolder(second)
        XCTAssertTrue(
            host.waitUntil { host.grid.expandedFolderID == second.id },
            "Отложенное открытие B выполнилось"
        )
        XCTAssertTrue(host.waitForFolderTransition(), "Открытие B завершилось")
        host.layout()

        XCTAssertEqual(host.grid.expandedFolderID, second.id)
        XCTAssertEqual(panelIndices(in: host.grid).count, 1, "Панель только у B")
        let panels = panelIndices(in: host.grid)
        XCTAssertEqual(host.grid.displayItems[panels[0]].id, second.id)
        XCTAssertEqual(events.map { $0.id }, [first.id, first.id, second.id])
        XCTAssertEqual(events.map { $0.expanded }, [true, false, true])
    }

    // MARK: - Снимок посреди анимации (E10.2)

    /// `update(snapshot:)` во время открытия панели не теряется и не попадает
    /// внутрь незавершённого batch-обновления: применяется после перехода,
    /// раскрытие сохраняется, новый элемент появляется в наборе.
    func testUpdateDuringOpeningAppliesAfterTransition() {
        let folder = tesseraTestFolder("folder", tileCount: 3)
        let tile = tesseraTestTile("a", size: .small)
        let extra = tesseraTestTile("extra", size: .small)
        let host = TesseraTestWindowedGrid(items: [.tile(tile), .folder(folder)])

        var events: [Bool] = []
        host.grid.onFolderExpansionChanged = { _, expanded in events.append(expanded) }

        host.grid.openFolder(folder)
        XCTAssertTrue(host.grid.isFolderChangeAnimating, "Анимация открытия идёт")

        // Снимок приходит посреди 280 мс: набор занят batch-вставкой панели.
        host.grid.update(
            snapshot: TileGridSnapshot(
                items: [.tile(tile), .folder(folder), .tile(extra)],
                unpinned: []
            ),
            animated: true
        )
        XCTAssertFalse(
            host.grid.items.contains { $0.id == extra.id },
            "Снимок ждёт завершения перехода, а не применяется поверх batch"
        )

        XCTAssertTrue(host.waitForFolderTransition(), "Переход завершился")
        host.layout()

        XCTAssertEqual(host.grid.expandedFolderID, folder.id, "Раскрытие сохранено")
        XCTAssertEqual(host.grid.items.count, 3)
        XCTAssertTrue(host.grid.items.contains { $0.id == extra.id })
        XCTAssertEqual(panelIndices(in: host.grid).count, 1)
        XCTAssertEqual(events, [true], "Отложенный снимок не закрыл папку")
    }

    /// `update(snapshot:)` во время закрытия панели применяется после перехода:
    /// панель уходит, обновлённый состав и событие закрытия не теряются.
    func testUpdateDuringClosingAppliesAfterTransition() {
        let folder = tesseraTestFolder("folder", tileCount: 3)
        let tile = tesseraTestTile("a", size: .small)
        let extra = tesseraTestTile("extra", size: .small)
        let host = TesseraTestWindowedGrid(
            items: [.tile(tile), .folder(folder), .tile(extra)]
        )

        var events: [Bool] = []
        host.grid.onFolderExpansionChanged = { _, expanded in events.append(expanded) }

        host.grid.openFolder(folder, animated: false)
        host.layout()
        XCTAssertEqual(host.grid.expandedFolderID, folder.id)

        host.grid.closeFolder()
        XCTAssertTrue(host.grid.isFolderChangeAnimating, "Анимация закрытия идёт")

        host.grid.update(
            snapshot: TileGridSnapshot(items: [.tile(tile), .folder(folder)], unpinned: []),
            animated: false
        )

        XCTAssertTrue(host.waitForFolderTransition(), "Закрытие завершилось")
        host.layout()

        XCTAssertNil(host.grid.expandedFolderID)
        XCTAssertEqual(panelIndices(in: host.grid).count, 0)
        XCTAssertEqual(host.grid.items.count, 2, "Отложенный снимок применён")
        XCTAssertEqual(events, [true, false])
    }

    /// M1: если отложенный снимок применился через `reloadData` (fallback при
    /// смене порядка общих элементов), отложенная цель панели не исполняется в
    /// том же стеке — иначе снова получили бы `reloadData` + `performBatchUpdates`
    /// в одном проходе runloop. Цель переоткладывается на следующий проход.
    func testDeferredSnapshotAndFolderTargetDoNotShareRunLoopPass() {
        let first = tesseraTestFolder("first", tileCount: 3)
        let second = tesseraTestFolder("second", tileCount: 3)
        let tileA = tesseraTestTile("a", size: .small)
        let tileB = tesseraTestTile("b", size: .small)
        let host = TesseraTestWindowedGrid(
            items: [.folder(first), .tile(tileA), .tile(tileB), .folder(second)]
        )

        host.grid.openFolder(first)
        XCTAssertTrue(host.grid.isFolderChangeAnimating, "Открытие A идёт")

        // Пока идёт переход: цель панели (B) и снимок, который уберёт A и
        // переставит общие ярлыки — то есть применится fallback-ом через
        // reloadData.
        host.grid.openFolder(second)
        host.grid.update(
            snapshot: TileGridSnapshot(
                items: [.tile(tileB), .tile(tileA), .folder(second)],
                unpinned: []
            ),
            animated: false
        )

        XCTAssertTrue(
            host.waitUntil(timeout: 3) {
                host.grid.expandedFolderID == second.id
                    && !host.grid.isFolderChangeAnimating
            },
            "Снимок и цель панели применяются последовательно, без падения"
        )
        host.layout()

        XCTAssertEqual(host.grid.expandedFolderID, second.id)
        XCTAssertEqual(panelIndices(in: host.grid).count, 1)
        XCTAssertEqual(host.grid.items.map { $0.id }, [tileB.id, tileA.id, second.id])
        XCTAssertFalse(host.grid.isFolderChangeAnimating)
    }

    /// m4/E10.2: повторный тап по папке в первые ~0.12 с закрытия — цель
    /// «открыть снова», а не потерянный тап: последняя цель побеждает.
    func testRetapWhileClosingReopensFolder() {
        let folder = tesseraTestFolder("folder", tileCount: 3)
        let tile = tesseraTestTile("a", size: .small)
        let host = TesseraTestWindowedGrid(items: [.folder(folder), .tile(tile)])

        host.grid.openFolder(folder, animated: false)
        host.layout()
        XCTAssertEqual(host.grid.expandedFolderID, folder.id)

        host.grid.closeFolder()
        XCTAssertTrue(host.grid.isFolderChangeAnimating, "Закрытие идёт")

        // Папка ещё числится раскрытой (иконки гаснут), но пользователь уже
        // передумал: повторный тап обязан запланировать открытие.
        host.grid.toggleFolder(folder)

        XCTAssertTrue(
            host.waitUntil(timeout: 3) {
                host.grid.expandedFolderID == folder.id
                    && !host.grid.isFolderChangeAnimating
            },
            "Повторный тап во время закрытия возвращает панель"
        )
        host.layout()
        XCTAssertEqual(panelIndices(in: host.grid).count, 1)
    }

    // MARK: - Владелец isScrollEnabled (E10.2)

    /// Блокировка прокрутки drag-координатором переживает завершение анимации
    /// панели: сетка не восстанавливает устаревший снимок `isScrollEnabled`.
    func testScrollLockSurvivesDragLockDuringPanelAnimation() {
        let folder = tesseraTestFolder("folder", tileCount: 4)
        let host = TesseraTestWindowedGrid(items: [.folder(folder)])

        host.grid.openFolder(folder)
        XCTAssertFalse(
            host.grid.isScrollEnabled,
            "На время анимации панели прокрутка заблокирована"
        )

        // Drag-координатор включил блокировку, пока панель ещё растёт.
        host.grid.isScrollEnabled = false
        XCTAssertTrue(host.waitForFolderTransition(), "Открытие завершилось")

        XCTAssertFalse(
            host.grid.isScrollEnabled,
            "Снятие блокировки панели не должно включать прокрутку против drag"
        )

        host.grid.isScrollEnabled = true
        XCTAssertTrue(host.grid.isScrollEnabled)
    }

    /// Без внешней блокировки прокрутка возвращается сразу после анимации
    /// панели, а не остаётся выключенной навсегда.
    func testScrollRestoredAfterPanelAnimation() {
        let folder = tesseraTestFolder("folder", tileCount: 4)
        let host = TesseraTestWindowedGrid(items: [.folder(folder)])

        host.grid.openFolder(folder)
        XCTAssertTrue(host.waitForFolderTransition())
        XCTAssertTrue(host.grid.isScrollEnabled)
    }

    // MARK: - Кламп contentOffset (E10.2)

    /// Неанимированное закрытие панели (Reduce Motion / вне окна) тоже зажимает
    /// `contentOffset`: контент стал короче, позиция прокрутки не остаётся за
    /// его концом.
    func testNonAnimatedCloseClampsContentOffset() {
        let folder = tesseraTestFolder("big", tileCount: 64)
        let grid = makeGrid([.folder(folder)])

        grid.openFolder(folder, animated: false)
        layout(grid)

        let expandedMaximum = max(0, grid.contentSize.height - grid.bounds.height)
        XCTAssertGreaterThan(expandedMaximum, 0, "Панель обязана удлинить контент")

        grid.setContentOffset(
            CGPoint(x: 0, y: expandedMaximum),
            animated: false
        )
        XCTAssertEqual(grid.contentOffset.y, expandedMaximum, accuracy: 0.5)

        grid.closeFolder(animated: false)
        layout(grid)

        let collapsedMaximum = max(0, grid.contentSize.height - grid.bounds.height)
        XCTAssertEqual(
            grid.contentOffset.y,
            collapsedMaximum,
            accuracy: 0.5,
            "Неанимированное закрытие зажимает offset"
        )
        XCTAssertLessThan(grid.contentOffset.y, expandedMaximum)
    }

    // MARK: - .layoutChanged во всех ветках (E10.2)

    /// `.layoutChanged` публикуется и в анимированных, и в неанимированных
    /// ветках раскрытия/закрытия, включая Reduce Motion.
    func testLayoutChangedPostedInAllExpansionBranches() {
        let folder = tesseraTestFolder("folder", tileCount: 4)
        let host = TesseraTestWindowedGrid(items: [.folder(folder)])

        var posts: [UIAccessibility.Notification] = []
        var arguments: [Any?] = []
        host.grid.accessibilityNotificationPoster = { notification, argument in
            posts.append(notification)
            arguments.append(argument)
        }

        // Анимированное открытие.
        host.grid.openFolder(folder)
        XCTAssertTrue(host.waitForFolderTransition())
        XCTAssertEqual(posts.count, 1)
        XCTAssertNotNil(arguments.first ?? nil, "Фокус переводится на панель")

        // Анимированное закрытие.
        host.grid.closeFolder()
        XCTAssertTrue(host.waitForFolderTransition())
        XCTAssertEqual(posts.count, 2)
        XCTAssertNotNil(arguments.last ?? nil, "Фокус возвращается на папку")

        // Неанимированные открытие и закрытие.
        host.grid.openFolder(folder, animated: false)
        XCTAssertEqual(posts.count, 3)
        host.grid.closeFolder(animated: false)
        XCTAssertEqual(posts.count, 4)

        // Reduce Motion: анимированный вызов идёт неанимированной веткой, но
        // уведомление и событие хосту обязательны.
        host.grid.isReduceMotionEnabled = { true }
        host.grid.openFolder(folder, animated: true)
        XCTAssertEqual(posts.count, 5)
        host.grid.closeFolder(animated: true)
        XCTAssertEqual(posts.count, 6)

        XCTAssertEqual(
            posts,
            Array(repeating: UIAccessibility.Notification.layoutChanged, count: 6)
        )
        XCTAssertFalse(host.grid.isFolderChangeAnimating)
    }

    // MARK: - Озвучивание «папка раскрыта» (E10.2)

    /// `accessibilityValue` папки сообщает «раскрыта», не теряя число ярлыков;
    /// закрытие возвращает прежнее значение.
    func testFolderAccessibilityValueAnnouncesExpanded() {
        let folder = tesseraTestFolder("folder", tileCount: 3)
        let cell = TesseraTileCell(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        cell.configure(with: .folder(folder), liveTileEngine: nil, isVisible: false)

        XCTAssertEqual(cell.accessibilityLabel, "folder")
        XCTAssertEqual(cell.accessibilityValue, "3")

        cell.setFolderExpanded(true)
        XCTAssertEqual(cell.accessibilityValue, "3, \(TesseraStartScreenStrings.string(.panelExpanded))")

        cell.setFolderExpanded(false)
        XCTAssertEqual(cell.accessibilityValue, "3")

        // Пустая папка: числа нет, состояние озвучивается отдельно.
        let empty = TileFolder(id: "empty", title: "empty")
        cell.configure(with: .folder(empty), liveTileEngine: nil, isVisible: false)
        XCTAssertNil(cell.accessibilityValue)
        cell.setFolderExpanded(true)
        XCTAssertEqual(cell.accessibilityValue, TesseraStartScreenStrings.string(.panelExpanded))
    }

    /// Та же пара «число ярлыков + раскрыта» приходит на реальной ячейке после
    /// раскрытия панели в сетке.
    func testFolderCellValueAfterExpansionInGrid() {
        let folder = tesseraTestFolder("folder", tileCount: 5)
        let host = TesseraTestWindowedGrid(items: [.folder(folder)])

        host.grid.openFolder(folder, animated: false)
        host.layout()

        XCTAssertEqual(
            host.cell(folder.id)?.accessibilityValue,
            "5, \(TesseraStartScreenStrings.string(.panelExpanded))"
        )
    }

    // MARK: - Dynamic Type заголовка панели (E10.2)

    /// Шрифт заголовка панели масштабируется Dynamic Type, но не выходит за
    /// потолок и укладывается в фиксированную высоту строки заголовка панели —
    /// иначе заголовок обрезался бы на accessibility-размерах.
    func testPanelTitleFontScalesWithinHeaderHeight() {
        let defaultFont = TesseraFolderPanelCell.makeTitleFont(compatibleWith: nil)
        let smallFont = TesseraFolderPanelCell.makeTitleFont(
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .extraSmall)
        )
        let accessibilityFont = TesseraFolderPanelCell.makeTitleFont(
            compatibleWith: UITraitCollection(
                preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge
            )
        )

        XCTAssertLessThanOrEqual(smallFont.pointSize, defaultFont.pointSize)
        XCTAssertGreaterThan(accessibilityFont.pointSize, defaultFont.pointSize)
        XCTAssertLessThanOrEqual(accessibilityFont.pointSize, 28)
        XCTAssertLessThanOrEqual(
            accessibilityFont.lineHeight,
            TileLayoutEngine.panelHeaderHeight + 0.001,
            "Строка заголовка обязана уместиться в высоту панели"
        )
        XCTAssertLessThanOrEqual(
            defaultFont.lineHeight,
            TileLayoutEngine.panelHeaderHeight + 0.001
        )
    }
}

#endif
