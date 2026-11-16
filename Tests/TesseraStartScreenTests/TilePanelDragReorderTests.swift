//
//  TilePanelDragReorderTests.swift
//  TesseraStartScreenTests
//
//  Перестановка ярлыков drag'ом внутри открытой панели папки (E16.1, D40,
//  13.11.2026; W10M §6.5, §6.6). Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md
//  «Отступления реализации (E16)», п. 65; решение D40 в docs/STATE.md.
//
//  Правила, которые проверяются:
//  - долгое нажатие по ярлыку панели в правке начинает перестановку: панель
//    остаётся открытой, ярлык скрыт и заменён пустышкой, кнопок открепления нет;
//  - слот под пальцем — по рамкам слотов раскладки панели (строки/колонки, RTL);
//    пустое место и заголовок дают ближайший слот;
//  - соседи сдвигаются от базового порядка (без накопления), модель не меняется;
//  - drop фиксирует `TileStore.moveWithinFolder` (один раз, делегат
//    `didReorderTile`), drop на свой слот и отмена возвращают порядок;
//  - выход пальца за панель плюс запас переводит drag в вынос (панель
//    закрывается мгновенно, цели E14, D45, отказ хоста), назад к перестановке
//    в этом drag возврата нет;
//  - Reduce Motion — мгновенный сдвиг; автопрокрутка у края работает.
//
//  Стенд — настоящие `TileStore` и сетка в окне; раскладки точные.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TilePanelDragReorderTests: XCTestCase {

    // MARK: - Помощники

    private let folderID: AnyHashable = "F"

    private final class Recorder: TesseraTileEditCoordinatorDelegate {
        var reorders: [(tile: AnyHashable, folder: AnyHashable, index: Int)] = []
        var moves: [(tile: AnyHashable, folder: AnyHashable?, cell: TileGridPlacement?)] = []
        var failures: [TileGroupingAction] = []
        var dissolutions: [AnyHashable] = []

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didReorderTile tileID: AnyHashable,
            inFolder folderID: AnyHashable,
            toIndex index: Int
        ) {
            reorders.append((tileID, folderID, index))
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toFolder folderID: AnyHashable?,
            atCell cell: TileGridPlacement?
        ) {
            moves.append((tileID, folderID, cell))
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didFailGrouping action: TileGroupingAction,
            tileID: AnyHashable,
            folderID: AnyHashable?
        ) {
            failures.append(action)
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didDissolveFolder folderID: AnyHashable,
            remainingTile tileID: AnyHashable
        ) {
            dissolutions.append(folderID)
        }
    }

    /// Стенд: папка F (medium, (0,0)) из `count` малых ярлыков `t0…`, плитка `a`
    /// в правом столбце под папкой. 4 колонки: панель — строки по четыре ярлыка.
    private func makeHost(
        count: Int = 6,
        reduceMotion: Bool = false
    ) throws -> TesseraTestDragHost {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("a", .small, 0, 3)],
            folders: [
                CellFixtureFolder("F", .medium, 0, 0, contents: (0..<count).map { ("t\($0)", TileSize.small) }),
            ],
            configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.05, magnetSnapRadius: 0)
        )
        if reduceMotion {
            host.host.grid.isReduceMotionEnabled = { true }
            host.coordinator.isReduceMotionEnabled = { true }
        }
        return host
    }

    private func ids(_ host: TesseraTestDragHost) -> [AnyHashable] {
        host.store.folderContaining("t0")?.tiles.map { $0.id } ?? []
    }

    @discardableResult
    private func openPanel(_ host: TesseraTestDragHost) throws -> TesseraFolderPanelCell {
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == self.folderID })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)
        XCTAssertTrue(host.waitUntil {
            host.host.panelCell(folderID: folderID)?.shortcutCells.first?.accessibilityCustomActions != nil
        })
        return try XCTUnwrap(host.host.panelCell(folderID: folderID))
    }

    private func geometry(_ host: TesseraTestDragHost) throws -> TesseraPanelShortcutGeometry {
        try XCTUnwrap(host.host.grid.panelShortcutGeometry())
    }

    private func assertFrame(
        _ lhs: CGRect, _ rhs: CGRect, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(lhs.minX, rhs.minX, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(lhs.minY, rhs.minY, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: 0.5, message, file: file, line: line)
    }

    private func center(_ frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Долгое нажатие по ярлыку панели `index`; возвращает точку нажатия.
    @discardableResult
    private func lift(_ host: TesseraTestDragHost, index: Int) throws -> CGPoint {
        let panelItem = try XCTUnwrap(host.host.grid.displayItems.first { $0.isFolderPanel })
        let point = center(try geometry(host).frames[index])
        host.coordinator.handleLongPress(on: panelItem, at: point)
        return point
    }

    /// Ждёт, пока drag завершится и уборка пройдёт.
    private func settle(_ host: TesseraTestDragHost) {
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil && !host.host.grid.isFolderChangeAnimating })
        XCTAssertTrue(host.waitUntil { host.host.grid.subviews.allSatisfy { !($0 is TesseraTilePlaceholderView) } })
        host.spin(0.4)
    }

    // MARK: - Старт

    /// Долгое нажатие по ярлыку панели в правке начинает перестановку: панель
    /// остаётся открытой, модель не тронута, кнопок открепления нет.
    func testLongPressStartsReorderAndKeepsPanelOpen() throws {
        let host = try makeHost()
        let panel = try openPanel(host)
        XCTAssertEqual(host.coordinator.panelEditControls.count, 6)
        let before = ids(host)

        try lift(host, index: 2)

        XCTAssertTrue(host.coordinator.isDragging)
        let session = try XCTUnwrap(host.coordinator.dragSession)
        let reorder = try XCTUnwrap(session.panelReorder)
        XCTAssertEqual(reorder.sourceIndex, 2)
        XCTAssertEqual(reorder.slot, 2)
        XCTAssertEqual(reorder.folder.id, "F")
        XCTAssertEqual(session.itemID, "t2")
        XCTAssertNil(session.sourceFolderID, "Это не вынос")
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID, "Панель осталась открытой")
        XCTAssertEqual(ids(host), before, "Модель не меняется во время drag")
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty, "Кнопок на ярлыках во время drag нет")
        XCTAssertEqual(panel.reorderSourceIndex, 2)
        XCTAssertTrue(panel.shortcutCells[2].accessibilityElementsHidden, "Поднятый ярлык скрыт")

        host.coordinator.finishDrag(commit: false)
        settle(host)
        XCTAssertEqual(panel.reorderSourceIndex, nil)
        XCTAssertFalse(panel.shortcutCells[2].accessibilityElementsHidden)
        host.coordinator.endEditing()
    }

    /// Долгое нажатие вне иконок панели (заголовок, фон) drag не начинает.
    func testLongPressOnPanelBackgroundDoesNotStart() throws {
        let host = try makeHost()
        try openPanel(host)
        let panelItem = try XCTUnwrap(host.host.grid.displayItems.first { $0.isFolderPanel })
        let frame = try geometry(host).panelFrame

        host.coordinator.handleLongPress(on: panelItem, at: CGPoint(x: frame.midX, y: frame.minY + 6))

        XCTAssertFalse(host.coordinator.isDragging)
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)
        host.coordinator.endEditing()
    }

    /// Центр тела ярлыка не принадлежит кнопке открепления: long-press по телу
    /// доходит до жеста (зона кнопки — угловая четверть), E15.9/E15.10.
    func testBodyCenterIsOutsideUnpinButtonZone() throws {
        let host = try makeHost()
        try openPanel(host)
        let geometry = try geometry(host)
        let control = try XCTUnwrap(host.coordinator.panelEditControls["t1"])
        control.layoutIfNeeded()
        let frame = geometry.frames[1]

        let bodyPoint = control.convert(center(frame), from: host.host.grid)
        XCTAssertNil(control.hitTest(bodyPoint, with: nil), "Тело ярлыка — не кнопка")
        // Правый верхний угол — кнопка.
        let corner = control.convert(CGPoint(x: frame.maxX - 4, y: frame.minY + 4), from: host.host.grid)
        XCTAssertNotNil(control.hitTest(corner, with: nil), "Угол — кнопка открепления")
        host.coordinator.endEditing()
    }

    // MARK: - Слот под пальцем

    /// Чистая функция: сетка 4 колонки; центры слотов, зазоры, пустое место.
    func testSlotHitTestRowsAndColumns() {
        let frames: [CGRect] = (0..<6).map { index in
            CGRect(x: CGFloat(index % 4) * 50, y: 100 + CGFloat(index / 4) * 50, width: 48, height: 48)
        }
        func slot(_ x: CGFloat, _ y: CGFloat) -> Int? {
            TesseraTileEditCoordinator.panelReorderSlot(at: CGPoint(x: x, y: y), slotFrames: frames, spacing: 2)
        }

        XCTAssertEqual(slot(24, 124), 0)
        XCTAssertEqual(slot(174, 124), 3)
        XCTAssertEqual(slot(24, 174), 4)
        XCTAssertEqual(slot(74, 174), 5)
        XCTAssertEqual(slot(48.5, 124), 0, "Зазор между колонками принадлежит ближайшему слоту")
        XCTAssertEqual(slot(124, 148.8), 2, "Зазор между строками")
        XCTAssertEqual(slot(174, 174), 5, "Пустое место последней строки — ближайший слот")
        XCTAssertEqual(slot(124, 400), 5, "Под панелью — ближайший слот последней строки")
        XCTAssertEqual(slot(124, 10), 2, "Над сеткой (заголовок) — ближайший слот первой строки")
        XCTAssertNil(TesseraTileEditCoordinator.panelReorderSlot(at: .zero, slotFrames: [], spacing: 2))
    }

    /// Рамки слотов реальной панели: слот под центром каждого ярлыка, а слоты не
    /// зависят от превью сдвига.
    func testSlotFramesFromPanelGeometry() throws {
        let host = try makeHost()
        try openPanel(host)
        let geometry = try geometry(host)

        XCTAssertEqual(geometry.slotFrames.count, 6)
        for (slot, frame) in zip(geometry.slotFrames, geometry.frames) {
            assertFrame(slot, frame, "Без превью слоты совпадают с рамками ярлыков")
        }
        for (index, frame) in geometry.slotFrames.enumerated() {
            XCTAssertEqual(
                TesseraTileEditCoordinator.panelReorderSlot(
                    at: center(frame), slotFrames: geometry.slotFrames, spacing: geometry.spacing
                ),
                index
            )
        }
        XCTAssertEqual(geometry.slotFrames[4].minX, geometry.slotFrames[0].minX, accuracy: 0.5, "Пятый — во второй строке")
        XCTAssertGreaterThan(geometry.slotFrames[4].minY, geometry.slotFrames[0].maxY - 1)
        XCTAssertTrue(geometry.panelFrame.contains(center(geometry.slotFrames[5])))
        host.coordinator.endEditing()
    }

    /// RTL: колонки панели зеркалятся (слот 0 — правый), хит-тест по рамкам тоже.
    func testSlotHitTestInRightToLeft() throws {
        let host = try makeHost()
        host.host.grid.semanticContentAttribute = .forceRightToLeft
        host.host.collectionView?.semanticContentAttribute = .forceRightToLeft
        host.host.grid.invalidateTileLayout(animated: false)
        host.host.layout()
        try openPanel(host)
        host.host.layout()
        let geometry = try geometry(host)

        XCTAssertGreaterThan(geometry.slotFrames[0].midX, geometry.slotFrames[1].midX, "RTL: слот 0 правее слота 1")
        for (index, frame) in geometry.slotFrames.enumerated() {
            XCTAssertEqual(
                TesseraTileEditCoordinator.panelReorderSlot(
                    at: center(frame), slotFrames: geometry.slotFrames, spacing: geometry.spacing
                ),
                index
            )
        }

        // Реальный drag в RTL: ярлык 0 на слот 1 (левее на экране).
        try lift(host, index: 0)
        host.coordinator.updateDrag(to: center(geometry.slotFrames[1]))
        XCTAssertEqual(host.coordinator.dragSession?.panelReorder?.slot, 1)
        host.coordinator.finishDrag(commit: true)
        settle(host)
        XCTAssertEqual(ids(host), ["t1", "t0", "t2", "t3", "t4", "t5"] as [AnyHashable])
        let panel = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        XCTAssertEqual(panel.shortcutCells.map { $0.itemID }, ids(host).map { Optional($0) })
        XCTAssertGreaterThan(panel.shortcutCells[0].frame.midX, panel.shortcutCells[1].frame.midX)
        host.coordinator.endEditing()
    }

    // MARK: - Превью

    /// Палец над слотом 3: пустышка в слоте 3, соседи сдвинулись, модель и
    /// `onChange` не тронуты.
    func testSiblingsShiftAndModelIsUntouched() throws {
        let host = try makeHost(reduceMotion: true)
        let panel = try openPanel(host)
        var changes = 0
        host.store.onChange = { _ in changes += 1 }
        let slots = try geometry(host).slotFrames.map { panel.contentView.convert($0, from: host.host.grid) }
        try lift(host, index: 0)

        host.coordinator.updateDrag(to: center(try geometry(host).slotFrames[3]))

        XCTAssertEqual(panel.reorderSlot, 3)
        // Порядок слотов: t1 t2 t3 [t0] t4 t5.
        XCTAssertEqual(panel.shortcutCells[1].frame.origin.x, slots[0].origin.x, accuracy: 0.5)
        XCTAssertEqual(panel.shortcutCells[2].frame.origin.x, slots[1].origin.x, accuracy: 0.5)
        XCTAssertEqual(panel.shortcutCells[3].frame.origin.x, slots[2].origin.x, accuracy: 0.5)
        assertFrame(panel.shortcutCells[4].frame, slots[4], "За пустышкой ярлыки на своих местах")
        assertFrame(panel.shortcutCells[5].frame, slots[5])
        XCTAssertEqual(changes, 0, "Модель не пишется во время drag")
        XCTAssertEqual(ids(host), ["t0", "t1", "t2", "t3", "t4", "t5"] as [AnyHashable])
        XCTAssertEqual(host.store.autosaves, false)

        host.coordinator.finishDrag(commit: false)
        settle(host)
        host.coordinator.endEditing()
    }

    /// Превью считается от базового порядка: проход по слотам 3 → 1 → 2 даёт то же,
    /// что прямой переход на 2; повторный шаг в тот же слот ничего не меняет.
    func testPreviewIsComputedFromBaseWithoutAccumulation() throws {
        let host = try makeHost(reduceMotion: true)
        let panel = try openPanel(host)
        let geometry = try geometry(host)
        let slots = geometry.slotFrames.map { panel.contentView.convert($0, from: host.host.grid) }
        try lift(host, index: 0)

        for slot in [3, 1, 2, 2] {
            host.coordinator.updateDrag(to: center(geometry.slotFrames[slot]))
        }

        // Ожидаемый порядок слотов: t1 t2 [t0] t3 t4 t5.
        XCTAssertEqual(panel.reorderSlot, 2)
        assertFrame(panel.shortcutCells[1].frame, slots[0])
        assertFrame(panel.shortcutCells[2].frame, slots[1])
        assertFrame(panel.shortcutCells[3].frame, slots[3])
        assertFrame(panel.shortcutCells[4].frame, slots[4])
        assertFrame(panel.shortcutCells[5].frame, slots[5])

        // Возврат на исходный слот — полная база.
        host.coordinator.updateDrag(to: center(geometry.slotFrames[0]))
        for index in 1..<6 { assertFrame(panel.shortcutCells[index].frame, slots[index]) }

        host.coordinator.finishDrag(commit: false)
        settle(host)
        host.coordinator.endEditing()
    }

    /// Reduce Motion: слот меняется мгновенно, анимаций на ярлыках и пустышке нет.
    func testReduceMotionShiftsInstantlyWithoutAnimations() throws {
        let host = try makeHost(reduceMotion: true)
        let panel = try openPanel(host)
        try lift(host, index: 0)

        host.coordinator.updateDrag(to: center(try geometry(host).slotFrames[2]))

        for cell in panel.shortcutCells {
            XCTAssertTrue(cell.layer.animationKeys()?.isEmpty ?? true, "Без анимации сдвига")
        }
        host.coordinator.finishDrag(commit: false)
        settle(host)
        host.coordinator.endEditing()
    }

    /// Без Reduce Motion сдвиг идёт анимацией; модельные рамки — сразу конечные.
    func testShiftIsAnimatedWithoutReduceMotion() throws {
        let host = try makeHost()
        let panel = try openPanel(host)
        let slots = try geometry(host).slotFrames.map { panel.contentView.convert($0, from: host.host.grid) }
        try lift(host, index: 0)

        host.coordinator.updateDrag(to: center(try geometry(host).slotFrames[1]))

        assertFrame(panel.shortcutCells[1].frame, slots[0], "Модельный кадр — конечный")
        host.coordinator.finishDrag(commit: false)
        settle(host)
        host.coordinator.endEditing()
    }

    // MARK: - Drop и отмена

    /// Drop на слот 3: одна операция модели, один делегатный вызов, панель
    /// осталась открытой и показывает новый порядок, кнопки вернулись.
    func testDropCommitsMoveWithinFolder() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let panel = try openPanel(host)
        var changes = 0
        host.store.onChange = { _ in changes += 1 }
        let placements = host.store.placements
        try lift(host, index: 0)

        host.coordinator.updateDrag(to: center(try geometry(host).slotFrames[3]))
        host.coordinator.finishDrag(commit: true)
        settle(host)

        XCTAssertEqual(ids(host), ["t1", "t2", "t3", "t0", "t4", "t5"] as [AnyHashable])
        XCTAssertEqual(changes, 1, "Один onChange на drop")
        XCTAssertEqual(recorder.reorders.count, 1)
        XCTAssertEqual(recorder.reorders.first?.tile, "t0")
        XCTAssertEqual(recorder.reorders.first?.folder, "F")
        XCTAssertEqual(recorder.reorders.first?.index, 3)
        XCTAssertTrue(recorder.moves.isEmpty && recorder.failures.isEmpty)
        XCTAssertEqual(host.store.placements, placements, "Ячейки рабочего стола не менялись")
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID, "Панель осталась открытой")
        XCTAssertEqual(panel.shortcutCells.map { $0.itemID }, ids(host).map { Optional($0) })
        XCTAssertNil(panel.reorderSourceIndex)
        XCTAssertTrue(panel.shortcutCells.allSatisfy { !$0.accessibilityElementsHidden }, "Скрытых ярлыков нет")
        let slots = try geometry(host).slotFrames
        for (index, cell) in panel.shortcutCells.enumerated() {
            let frame = panel.contentView.convert(cell.frame, to: host.host.grid)
            XCTAssertEqual(frame.origin.x, slots[index].origin.x, accuracy: 0.5)
            XCTAssertEqual(frame.origin.y, slots[index].origin.y, accuracy: 0.5)
        }
        XCTAssertEqual(host.coordinator.panelEditControls.count, 6, "Кнопки открепления вернулись")
        XCTAssertEqual(host.store.autosaves, false, "Автосохранение стенда восстановлено")
        XCTAssertEqual(host.host.grid.snapshot?.folders.first?.tiles.map { $0.id }, ids(host))
        host.coordinator.endEditing()
    }

    /// Drop сохраняется один раз на диск (автосохранение включено у стенда).
    func testDropPersistsOnce() throws {
        let host = try makeHost()
        host.store.autosaves = true
        try openPanel(host)
        host.store.autosaves = true
        try FileManager.default.removeItem(at: host.store.fileURL)
        try lift(host, index: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.store.fileURL.path), "Во время drag ничего не пишется")

        host.coordinator.updateDrag(to: center(try geometry(host).slotFrames[4]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.store.fileURL.path), "Превью не пишет файл")
        host.coordinator.finishDrag(commit: true)
        settle(host)

        XCTAssertTrue(FileManager.default.fileExists(atPath: host.store.fileURL.path), "Drop записал файл")
        let fresh = TileStore(directoryURL: host.directory.url)
        fresh.setCatalog((0..<6).map { tesseraTestTile("t\($0)", size: .small) } + [tesseraTestTile("a", size: .small)])
        try fresh.load()
        XCTAssertEqual(
            fresh.folderContaining("t0")?.tiles.map { $0.id },
            ["t0", "t2", "t3", "t4", "t1", "t5"] as [AnyHashable]
        )
        host.coordinator.endEditing()
    }

    /// Drop на свой слот: no-op — ни модели, ни делегата, ни `onChange`.
    func testDropOnOwnSlotIsNoOp() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let panel = try openPanel(host)
        var changes = 0
        host.store.onChange = { _ in changes += 1 }
        let point = try lift(host, index: 2)

        host.coordinator.updateDrag(to: CGPoint(x: point.x + 4, y: point.y + 4))
        host.coordinator.finishDrag(commit: true)
        settle(host)

        XCTAssertEqual(changes, 0)
        XCTAssertTrue(recorder.reorders.isEmpty)
        XCTAssertEqual(ids(host), ["t0", "t1", "t2", "t3", "t4", "t5"] as [AnyHashable])
        XCTAssertEqual(panel.shortcutCells.map { $0.itemID }, ids(host).map { Optional($0) })
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)
        host.coordinator.endEditing()
    }

    /// Отмена жеста: порядок и кадры возвращаются, модель и делегат не тронуты.
    func testCancelRestoresOriginalOrder() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let panel = try openPanel(host)
        let slots = try geometry(host).slotFrames.map { panel.contentView.convert($0, from: host.host.grid) }
        var changes = 0
        host.store.onChange = { _ in changes += 1 }
        try lift(host, index: 0)

        host.coordinator.updateDrag(to: center(try geometry(host).slotFrames[3]))
        host.coordinator.finishDrag(commit: false)
        settle(host)

        XCTAssertEqual(changes, 0)
        XCTAssertTrue(recorder.reorders.isEmpty)
        XCTAssertEqual(ids(host), ["t0", "t1", "t2", "t3", "t4", "t5"] as [AnyHashable])
        for (index, cell) in panel.shortcutCells.enumerated() {
            XCTAssertEqual(cell.frame.origin.x, slots[index].origin.x, accuracy: 0.5)
            XCTAssertEqual(cell.frame.origin.y, slots[index].origin.y, accuracy: 0.5)
        }
        XCTAssertTrue(panel.shortcutCells.allSatisfy { !$0.accessibilityElementsHidden })
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)
        XCTAssertEqual(host.coordinator.panelEditControls.count, 6)
        XCTAssertEqual(host.store.autosaves, false)
        host.coordinator.endEditing()
    }

    /// Внешнее изменение модели во время перестановки отменяет drag и возвращает
    /// панель (B1); выход из правки тоже.
    func testExternalChangeAndEndEditingCancelReorder() throws {
        let host = try makeHost()
        let panel = try openPanel(host)
        try lift(host, index: 0)
        host.coordinator.updateDrag(to: center(try geometry(host).slotFrames[2]))

        XCTAssertTrue(host.store.moveWithinFolder("t3", folderID: "F", toIndex: 0))
        host.host.grid.update(snapshot: host.store.snapshot(columns: 4), animated: false)
        host.host.layout()
        host.coordinator.updateDrag(to: center(try geometry(host).slotFrames[3]))

        XCTAssertFalse(host.coordinator.isDragging, "Drag отменён")
        XCTAssertNil(panel.reorderSourceIndex)
        XCTAssertEqual(ids(host), ["t3", "t0", "t1", "t2", "t4", "t5"] as [AnyHashable], "Чужая правка осталась")
        XCTAssertTrue(panel.shortcutCells.allSatisfy { !$0.accessibilityElementsHidden })

        try lift(host, index: 1)
        XCTAssertTrue(host.coordinator.isDragging)
        host.coordinator.endEditing()
        XCTAssertFalse(host.coordinator.isDragging)
        XCTAssertNil(panel.reorderSourceIndex)
    }

    // MARK: - Выход за панель: вынос

    /// Палец в запасе у края панели ещё переставляет; за запасом — вынос.
    func testLeavingPanelSwitchesToTakeOutAfterMargin() throws {
        let host = try makeHost()
        let panel = try openPanel(host)
        let panelFrame = try geometry(host).panelFrame
        let slotX = try geometry(host).slotFrames[0].midX
        let session = try lift(host, index: 0)
        _ = session
        let dragView = try XCTUnwrap(host.coordinator.dragSession?.dragView)

        // В пределах запаса — по-прежнему перестановка.
        host.coordinator.updateDrag(to: CGPoint(x: slotX, y: panelFrame.maxY + TesseraTileEditCoordinator.panelReorderExitMargin - 2))
        XCTAssertNotNil(host.coordinator.dragSession?.panelReorder)
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)

        // За запасом — вынос.
        host.coordinator.updateDrag(to: CGPoint(x: slotX, y: panelFrame.maxY + TesseraTileEditCoordinator.panelReorderExitMargin + 30))
        let taken = try XCTUnwrap(host.coordinator.dragSession)
        XCTAssertNil(taken.panelReorder)
        XCTAssertEqual(taken.sourceFolderID, "F", "Источник — папка")
        XCTAssertEqual(taken.itemID, "t0")
        XCTAssertTrue(taken.dragView === dragView, "Тот же снимок едет за пальцем")
        XCTAssertNil(host.host.grid.expandedFolderID, "Панель закрыта мгновенно")
        XCTAssertFalse(host.host.grid.isFolderChangeAnimating)
        XCTAssertNil(panel.reorderSourceIndex)
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty)
        XCTAssertEqual(ids(host), ["t0", "t1", "t2", "t3", "t4", "t5"] as [AnyHashable], "Модель не менялась")
        XCTAssertEqual(host.store.autosaves, false, "Транзакция автосохранения одна")

        host.coordinator.finishDrag(commit: false)
        settle(host)
        XCTAssertEqual(host.store.autosaves, false)
        host.coordinator.endEditing()
    }

    /// После выноса к перестановке в том же drag возврата нет: палец над прежним
    /// местом панели ничего не переставляет; drop на пустую клетку — вынос E14.
    func testNoSwitchingBackAndTakeOutDropOnCell() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        try openPanel(host)
        let slotCenter = center(try geometry(host).slotFrames[1])
        let panelFrame = try geometry(host).panelFrame
        try lift(host, index: 2)

        host.coordinator.updateDrag(to: CGPoint(x: slotCenter.x, y: panelFrame.maxY + 60))
        XCTAssertNil(host.coordinator.dragSession?.panelReorder)
        host.coordinator.updateDrag(to: slotCenter)
        XCTAssertNil(host.coordinator.dragSession?.panelReorder, "Назад к перестановке нельзя")
        XCTAssertNil(host.host.grid.expandedFolderID, "Панель заново не открывается")

        let target = try XCTUnwrap(host.cellPoint(row: 1, column: 3))
        host.coordinator.updateDrag(to: target)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(tesseraCell(1, 3)))
        host.coordinator.finishDrag(commit: true)
        settle(host)

        XCTAssertTrue(recorder.reorders.isEmpty, "Это не перестановка")
        XCTAssertEqual(recorder.moves.count, 1)
        XCTAssertEqual(recorder.moves.first?.tile, "t2")
        XCTAssertNil(recorder.moves.first?.folder)
        XCTAssertEqual(host.store.placement(of: "t2"), tesseraCell(1, 3))
        XCTAssertEqual(ids(host), ["t0", "t1", "t3", "t4", "t5"] as [AnyHashable])
        host.coordinator.endEditing()
    }

    /// Перемещённый ярлык и вынос из папки в два ярлыка: правило D45 работает и
    /// после выхода из перестановки (папка распускается).
    func testTakeOutAfterReorderDissolvesTwoTileFolder() throws {
        let host = try makeHost(count: 2)
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        try openPanel(host)
        let panelFrame = try geometry(host).panelFrame
        let slotX = try geometry(host).slotFrames[0].midX
        try lift(host, index: 0)

        host.coordinator.updateDrag(to: CGPoint(x: slotX, y: panelFrame.maxY + 80))
        XCTAssertNil(host.coordinator.dragSession?.panelReorder)
        XCTAssertNotNil(host.coordinator.dragSession?.folderDissolution, "Итог распада показан в превью")
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 3)))
        host.coordinator.finishDrag(commit: true)
        settle(host)

        XCTAssertEqual(recorder.dissolutions, ["F"])
        XCTAssertTrue(host.folders.isEmpty, "Папка распущена")
        XCTAssertEqual(host.store.placement(of: "t1"), tesseraCell(0, 0), "Оставшийся ярлык — на месте папки")
        host.coordinator.endEditing()
    }

    /// Отказ хоста при drop после выноса: модель не меняется, делегат получает
    /// отказ, панель закрыта (как в E11.1).
    func testTakeOutRefusalAfterLeavingRestoresModel() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.store.approval = { _, _, action in action != .moveBetweenFolders }
        try openPanel(host)
        let panelFrame = try geometry(host).panelFrame
        let slotX = try geometry(host).slotFrames[0].midX
        try lift(host, index: 0)

        host.coordinator.updateDrag(to: CGPoint(x: slotX, y: panelFrame.maxY + 80))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 3)))
        host.coordinator.finishDrag(commit: true)
        settle(host)

        XCTAssertEqual(recorder.failures, [.moveBetweenFolders])
        XCTAssertEqual(ids(host), ["t0", "t1", "t2", "t3", "t4", "t5"] as [AnyHashable])
        XCTAssertTrue(recorder.moves.isEmpty)
        host.coordinator.endEditing()
    }

    /// Перестановка не спрашивает одобрения хоста (D14): запрет на любые
    /// операции с папками её не блокирует.
    func testReorderIgnoresHostApproval() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.store.approval = { _, _, _ in false }
        try openPanel(host)
        try lift(host, index: 0)

        host.coordinator.updateDrag(to: center(try geometry(host).slotFrames[2]))
        host.coordinator.finishDrag(commit: true)
        settle(host)

        XCTAssertEqual(ids(host), ["t1", "t2", "t0", "t3", "t4", "t5"] as [AnyHashable])
        XCTAssertTrue(recorder.failures.isEmpty)
        host.coordinator.endEditing()
    }

    // MARK: - Автопрокрутка в высокой панели

    /// Панель выше экрана: у нижнего края сетка прокручивается, слот считается по
    /// актуальной геометрии, перестановка остаётся перестановкой.
    func testAutoScrollInTallPanelKeepsReordering() throws {
        let host = try makeHost(count: 40)
        try openPanel(host)
        let grid = host.host.grid
        XCTAssertGreaterThan(try geometry(host).panelFrame.height, grid.bounds.height - 100, "Панель высокая")
        let offsetBefore = grid.contentOffset.y
        try lift(host, index: 0)

        let bottom = CGPoint(x: grid.bounds.midX, y: grid.bounds.height - 4)
        host.coordinator.updateDrag(to: bottom)
        XCTAssertNotNil(host.coordinator.dragSession?.panelReorder, "У края экрана внутри высокой панели — всё ещё перестановка")
        XCTAssertTrue(host.waitUntil(timeout: 3) { grid.contentOffset.y > offsetBefore + 20 }, "Тикер прокручивает сетку")
        XCTAssertNotNil(host.coordinator.dragSession?.panelReorder)
        XCTAssertGreaterThan(host.coordinator.dragSession?.panelReorder?.slot ?? 0, 4, "Слот пересчитан по прокрученной панели")

        host.coordinator.finishDrag(commit: false)
        settle(host)
        host.coordinator.endEditing()
    }
}

#endif
