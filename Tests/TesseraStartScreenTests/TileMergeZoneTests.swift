//
//  TileMergeZoneTests.swift
//  TesseraStartScreenTests
//
//  Создание папки перетаскиванием: зона слияния, гистерезис и пауза перед
//  превью вытеснения (E17.1, D50, 16.11.2026).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md «Отступления реализации»,
//  п. 66; docs/W10M-STARTSCREEN.md §6.2; решения D22 (удержание 600 мс / 10 pt —
//  не менялось), D50 в docs/STATE.md.
//
//  Что проверяется:
//  - геометрия зоны (`TesseraTileMergeZone`): вход — центр рамки со стороной
//    `max(50 %, 36 pt)` по оси, удержание — рамка без 6 pt по краям;
//  - гистерезис: цель `.group`/`.folder` держится, пока палец в области
//    удержания, и не мигает у границы входной зоны;
//  - пауза перед превью вытеснения: на подходе к центру плитки её сосед не
//    «убегает», превью появляется после паузы (и когда палец замер), смена клетки
//    начинает отсчёт заново, пустые клетки и «новая строка» — сразу, drop паузу
//    не учитывает, таймеры не переживают drag;
//  - сценарий с записи: пять малых плиток в ряд, пятая тащится на третью.
//
//  Таймеры настоящие (run loop), но все «не раньше паузы» проверки делаются
//  синхронно, до прокрутки run loop, поэтому от нагрузки не флакуют.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileMergeZoneTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Делегат-рекордер: нужны созданные папки и добавления.
    private final class Recorder: TesseraTileEditCoordinatorDelegate {

        /// Созданные папки.
        var createdFolders: [TesseraTileFolder] = []

        /// Добавления в папку.
        var additions: [(id: AnyHashable, folder: AnyHashable)] = []

        /// Перестановки по сетке.
        var moves: [(id: AnyHashable, cell: TesseraTileGridPlacement)] = []

        func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didCreateFolder folder: TesseraTileFolder) {
            createdFolders.append(folder)
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didAdd tileID: AnyHashable,
            toFolder folderID: AnyHashable
        ) {
            additions.append((tileID, folderID))
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toCell cell: TesseraTileGridPlacement
        ) {
            moves.append((tileID, cell))
        }
    }

    /// Ячейка в короткой записи.
    private func at(_ row: Int, _ column: Int) -> TesseraTileGridPlacement {
        TesseraTileGridPlacement(row: row, column: column)
    }

    /// Конфигурация: удержание 0,3 с (D22 не менялось — значение сокращено только
    /// ради скорости теста), пауза превью — настраиваемая, магнит выключен.
    private func configuration(
        dwell: TimeInterval = 0.5,
        hold: TimeInterval = 0.3,
        magnet: CGFloat = 0
    ) -> TesseraTileEditConfiguration {
        TesseraTileEditConfiguration(
            mergeHoverDuration: hold,
            magnetSnapRadius: magnet,
            reorderPreviewDwell: dwell
        )
    }

    /// Пять малых плиток `t1…t5` в ряду, 6 колонок (как в Example, D26): ширина
    /// ≈ 55 pt, как на записи пользователя.
    private func makeRowHost(
        configuration: TesseraTileEditConfiguration? = nil
    ) throws -> TesseraTestDragHost {
        try TesseraTestDragHost(
            cells: (0..<5).map { CellFixtureTile("t\($0 + 1)", .small, 0, $0) },
            columns: 6,
            configuration: configuration ?? self.configuration()
        )
    }

    /// Ждёт завершения drop'а: сессия снята, сетка совпала с моделью.
    private func settle(
        _ host: TesseraTestDragHost,
        _ id: AnyHashable,
        columns: Int = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil }, "Сессия завершена", file: file, line: line)
        XCTAssertTrue(host.waitForDragCleanup(id), "Ячейка снова видима", file: file, line: line)
        XCTAssertTrue(
            host.waitUntil { host.gridCells == host.store.placements(forColumns: columns) },
            "Сетка показывает ячейки модели",
            file: file,
            line: line
        )
    }

    /// Точка внутри рамки на заданном расстоянии от её центра.
    private func point(_ frame: CGRect, dx: CGFloat = 0, dy: CGFloat = 0) -> CGPoint {
        CGPoint(x: frame.midX + dx, y: frame.midY + dy)
    }

    // MARK: - Геометрия зоны

    /// Малая плитка 55 pt: входная зона 36 pt (раньше было 27,5 pt).
    func testEntryZoneOnSmallTileIsThirtySixPoints() {
        let frame = CGRect(x: 10, y: 20, width: 55, height: 55)
        let entry = TesseraTileMergeZone.entryRect(in: frame)

        XCTAssertEqual(entry.width, 36, accuracy: 0.001)
        XCTAssertEqual(entry.height, 36, accuracy: 0.001)
        XCTAssertEqual(entry.midX, frame.midX, accuracy: 0.001)
        XCTAssertEqual(entry.midY, frame.midY, accuracy: 0.001)
    }

    /// Средняя плитка/папка 118 pt: половина стороны — 59 pt (как и раньше).
    func testEntryZoneOnMediumTileIsHalfOfSide() {
        let frame = CGRect(x: 0, y: 0, width: 118, height: 118)
        let entry = TesseraTileMergeZone.entryRect(in: frame)

        XCTAssertEqual(entry.width, 59, accuracy: 0.001)
        XCTAssertEqual(entry.height, 59, accuracy: 0.001)
    }

    /// Зона не выходит за рамку: у плитки меньше минимума (30 pt) она равна рамке.
    func testEntryZoneIsClampedToTinyFrame() {
        let frame = CGRect(x: 5, y: 5, width: 30, height: 30)
        XCTAssertEqual(TesseraTileMergeZone.entryRect(in: frame), frame)
    }

    /// Широкая плитка: каждая ось считается отдельно, зона не меньше прежней
    /// половины рамки по каждой оси.
    func testEntryZoneIsComputedPerAxisForWideTile() {
        let frame = CGRect(x: 0, y: 0, width: 240, height: 118)
        let entry = TesseraTileMergeZone.entryRect(in: frame)

        XCTAssertEqual(entry.width, 120, accuracy: 0.001)
        XCTAssertEqual(entry.height, 59, accuracy: 0.001)

        let thin = CGRect(x: 0, y: 0, width: 240, height: 40)
        XCTAssertEqual(TesseraTileMergeZone.entryRect(in: thin).height, 36, accuracy: 0.001, "Минимум 36 pt, но не больше стороны")
    }

    /// Область удержания — рамка без 6 pt по краям, но не меньше входной зоны.
    func testRetainZoneIsInsetFrameAndNeverSmallerThanEntry() {
        let frame = CGRect(x: 0, y: 0, width: 55, height: 55)
        let retain = TesseraTileMergeZone.retainRect(in: frame)
        XCTAssertEqual(retain, frame.insetBy(dx: 6, dy: 6))
        XCTAssertTrue(retain.contains(TesseraTileMergeZone.entryRect(in: frame)))

        let tiny = CGRect(x: 0, y: 0, width: 40, height: 40)
        XCTAssertEqual(
            TesseraTileMergeZone.retainRect(in: tiny),
            TesseraTileMergeZone.entryRect(in: tiny),
            "Рамка без 6 pt (28 pt) меньше входной зоны (36 pt) — берётся входная"
        )
    }

    /// Вырожденная рамка зоны не даёт.
    func testDegenerateFrameHasNoZone() {
        let frame = CGRect(x: 0, y: 0, width: 0, height: 20)
        XCTAssertFalse(TesseraTileMergeZone.contains(.zero, in: frame, isEngaged: false))
        XCTAssertFalse(TesseraTileMergeZone.contains(.zero, in: frame, isEngaged: true))
    }

    /// Живая геометрия: на сетке в 6 колонок входная зона малой плитки — 36 pt,
    /// палец в 17 pt от центра по оси цель делает слиянием, в 19 pt — нет.
    func testLiveSmallTileEntryZoneIsThirtySixPoints() throws {
        let host = try makeRowHost()
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        XCTAssertEqual(frame.width, 55, accuracy: 6, "Малая плитка на 6 колонках ≈ 55 pt")
        XCTAssertGreaterThanOrEqual(frame.width, 40, "Малая плитка шире минимальной зоны")

        XCTAssertTrue(host.startDrag("t5"))
        host.coordinator.updateDrag(to: point(frame, dx: 17))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"), "17 pt от центра — внутри 36 pt")
        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")

        XCTAssertTrue(host.startDrag("t5"))
        host.coordinator.updateDrag(to: point(frame, dx: 19.5))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)), "19,5 pt от центра — вне входной зоны")
        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    // MARK: - Гистерезис

    /// Вход — только через входную зону, удержание — почти по всей плитке:
    /// 7 pt от края (вне входной зоны, внутри области удержания) цель не снимает,
    /// 3 pt от края — снимает, а возврат в 7 pt снова не включает слияние.
    func testHysteresisKeepsMergeTargetUntilFingerLeavesRetainZone() throws {
        let host = try makeRowHost()
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        let outsideEntry = CGPoint(x: frame.maxX - 7, y: frame.midY)
        XCTAssertFalse(TesseraTileMergeZone.entryRect(in: frame).contains(outsideEntry), "Контроль: вне входной зоны")
        XCTAssertTrue(TesseraTileMergeZone.retainRect(in: frame).contains(outsideEntry), "Контроль: в области удержания")

        XCTAssertTrue(host.startDrag("t5"))
        // Без входа в зону область удержания не работает.
        host.coordinator.updateDrag(to: outsideEntry)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)), "Входит только через входную зону")

        host.coordinator.updateDrag(to: point(frame))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"))
        host.coordinator.updateDrag(to: outsideEntry)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"), "Удержание: 7 pt от края")

        host.coordinator.updateDrag(to: CGPoint(x: frame.maxX - 3, y: frame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)), "Вышел из области удержания")
        host.coordinator.updateDrag(to: outsideEntry)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)), "Вход снова только через входную зону")

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    /// Дрожание пальца у границы входной зоны не переключает цель: превью — база,
    /// цель не сдвигается, удержание не перевзводится (смещение < 10 pt от якоря)
    /// и в итоге выдерживается.
    func testJitterAtZoneBoundaryKeepsHighlightAndHoldRunning() throws {
        let host = try makeRowHost()
        let baseTable = try XCTUnwrap(host.gridCells)
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        let entryHalf = TesseraTileMergeZone.entryRect(in: frame).width / 2
        XCTAssertTrue(host.startDrag("t5"))

        // Якорь — точка входа внутри зоны; дальше колебания через границу
        // входной зоны (внутри области удержания, <10 pt от якоря).
        host.coordinator.updateDrag(to: point(frame, dx: entryHalf - 1))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"))
        let tracker = try XCTUnwrap(host.coordinator.mergeTracker)
        let anchor = tracker.anchor

        let retainHalf = TesseraTileMergeZone.retainRect(in: frame).width / 2
        XCTAssertGreaterThan(retainHalf, entryHalf + 1, "Контроль: область удержания шире входной зоны")
        for offset in [entryHalf + 1, entryHalf - 2, retainHalf - 0.5, entryHalf - 1, entryHalf + 1.5] {
            host.coordinator.updateDrag(to: point(frame, dx: offset))
            let session = try XCTUnwrap(host.coordinator.dragSession)
            XCTAssertEqual(session.hover, .group("t3"), "Не мигает на offset \(offset)")
            XCTAssertEqual(session.previewPlacements, session.basePlacements, "Превью — база")
            XCTAssertEqual(host.gridCells, baseTable, "Цель под пальцем")
            XCTAssertEqual(host.coordinator.mergeTracker?.anchor, anchor, "Удержание не перевзведено")
        }

        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true }, "Удержание 600 мс (в тесте 0,3 с) выдержано")
        let highlight = try XCTUnwrap(
            host.host.grid.subviews.compactMap { $0 as? TesseraTileDropHighlightView }.first { !$0.isHidden }
        )
        XCTAssertEqual(highlight.center.x, frame.midX, accuracy: 0.5)

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    /// Выход из области удержания: цель возвращается к логике края (`.cell`),
    /// удержание и его таймер снимаются.
    func testLeavingRetainZoneFallsBackToCellAndStopsHold() throws {
        let host = try makeRowHost()
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        XCTAssertTrue(host.startDrag("t5"))

        host.coordinator.updateDrag(to: point(frame))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"))
        XCTAssertNotNil(host.coordinator.mergeTracker)
        XCTAssertTrue(host.coordinator.hasPendingDragTimersForTesting.merge)

        host.coordinator.updateDrag(to: CGPoint(x: frame.minX + 2, y: frame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)))
        XCTAssertNil(host.coordinator.mergeTracker)
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.merge)

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    // MARK: - Пауза перед превью вытеснения

    /// Подход к соседу сбоку: пока палец не простоял паузу на краю цели, цель не
    /// двигается; превью появляется после паузы и вытесняет её вниз.
    func testNeighbourDoesNotMoveBeforeDwellAndIsPushedAfter() throws {
        let host = try makeRowHost(configuration: configuration(dwell: 0.3))
        let baseTable = try XCTUnwrap(host.gridCells)
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        XCTAssertTrue(host.startDrag("t5"))

        let started = CACurrentMediaTime()
        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)), "Край занятой клетки")
        XCTAssertEqual(host.gridCells, baseTable, "До паузы превью — база: «t3» не убегает")
        XCTAssertTrue(host.coordinator.hasPendingDragTimersForTesting.reorderDwell, "Отсчёт паузы идёт")

        // Палец замер — событий касания нет: превью даёт таймер.
        XCTAssertTrue(host.waitUntil { host.gridCells != baseTable }, "Превью после паузы")
        XCTAssertGreaterThanOrEqual(CACurrentMediaTime() - started, 0.28, "Не раньше паузы")
        XCTAssertEqual(host.gridCells?["t5"], at(0, 2), "Перетаскиваемая на ячейке цели")
        XCTAssertEqual(host.gridCells?["t3"], at(1, 2), "Цель вытолкнута вниз")
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell, "Таймер отработал")

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    /// Смена клетки перезапускает отсчёт: прошедшее на прежней клетке время не
    /// засчитывается новой.
    func testDwellRestartsWhenCellChanges() throws {
        let host = try makeRowHost(configuration: configuration(dwell: 0.5))
        let baseTable = try XCTUnwrap(host.gridCells)
        let t2 = try XCTUnwrap(host.host.grid.frame(forItemID: "t2"))
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        XCTAssertTrue(host.startDrag("t5"))

        host.coordinator.updateDrag(to: CGPoint(x: t2.maxX - 2, y: t2.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 1)))
        host.spin(0.3)
        XCTAssertEqual(host.gridCells, baseTable, "0,3 с < паузы 0,5 с")

        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)))
        host.spin(0.3)
        XCTAssertEqual(host.gridCells, baseTable, "С первой клетки прошло 0,6 с, но со второй только 0,3 с: отсчёт перезапущен")

        XCTAssertTrue(host.waitUntil { host.gridCells != baseTable })
        XCTAssertEqual(host.gridCells?["t3"], at(1, 2), "Вытеснена вторая клетка")
        XCTAssertEqual(host.gridCells?["t2"], at(0, 1), "Первая не тронута")

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    /// Уход с клетки до паузы отменяет превью: после возврата отсчёт идёт заново.
    func testDwellIsDroppedWhenFingerLeavesCell() throws {
        let host = try makeRowHost(configuration: configuration(dwell: 0.3))
        let baseTable = try XCTUnwrap(host.gridCells)
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        XCTAssertTrue(host.startDrag("t5"))

        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
        XCTAssertTrue(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)
        host.coordinator.updateDrag(to: point(t3))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"))
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell, "Слияние снимает отсчёт паузы")

        host.spin(0.4)
        XCTAssertEqual(host.gridCells, baseTable, "Слияние — превью база, таймер паузы не сработал")

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    /// Пустая клетка и «новая строка» никого не вытесняют — превью сразу, без
    /// таймера паузы.
    func testEmptyCellAndNewRowPreviewsAreImmediate() throws {
        // Плитка в строке 3 держит строки 1–2 «внутри» холста: клетка (1, 3) пуста,
        // но это не «новая строка».
        let host = try TesseraTestDragHost(
            cells: (0..<5).map { CellFixtureTile("t\($0 + 1)", .small, 0, $0) }
                + [CellFixtureTile("z", .small, 3, 0)],
            columns: 6,
            configuration: configuration(dwell: 5)
        )
        XCTAssertTrue(host.startDrag("t5"))

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 3)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(1, 3)), "Пустая клетка")
        XCTAssertEqual(host.gridCells?["t5"], at(1, 3), "Превью сразу")
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 5, column: 0)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .newRow)
        XCTAssertEqual(host.gridCells?["t5"], at(4, 0), "«Новая строка» — сразу")
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    /// Drop до паузы фиксирует ту же цель-клетку, что и без паузы: элемент на
    /// ячейке цели, цель вытолкнута вниз; таймер снят.
    func testDropBeforeDwellCommitsSameCellMove() throws {
        let host = try makeRowHost(configuration: configuration(dwell: 5))
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let baseTable = try XCTUnwrap(host.gridCells)
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))

        XCTAssertTrue(host.startDrag("t5"))
        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
        XCTAssertEqual(host.gridCells, baseTable, "Превью ещё не показано")
        host.coordinator.finishDrag(commit: true)
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell, "Таймер снят на drop")
        settle(host, "t5")

        XCTAssertEqual(host.store.placement(of: "t5"), at(0, 2), "Ярлык на ячейке цели")
        XCTAssertEqual(host.store.placement(of: "t3"), at(1, 2), "Цель вытолкнута вниз (D31)")
        XCTAssertEqual(host.store.placement(of: "t4"), at(0, 3), "Остальные на местах")
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("t5"))
    }

    /// Нулевая пауза возвращает прежнее поведение: превью вытеснения сразу.
    func testZeroDwellKeepsImmediatePreview() throws {
        let host = try makeRowHost(configuration: configuration(dwell: 0))
        let baseTable = try XCTUnwrap(host.gridCells)
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        XCTAssertTrue(host.startDrag("t5"))

        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
        XCTAssertNotEqual(host.gridCells, baseTable)
        XCTAssertEqual(host.gridCells?["t3"], at(1, 2))
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    /// Значение по умолчанию — 0,2 с; нечисловое и отрицательное трактуются как 0.
    func testConfigurationDefaultAndSanitizing() throws {
        XCTAssertEqual(TesseraTileEditConfiguration().reorderPreviewDwell, 0.2, accuracy: 0.0001)

        for bad in [TimeInterval.nan, -1, .infinity] {
            let host = try makeRowHost(configuration: configuration(dwell: bad))
            let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
            XCTAssertTrue(host.startDrag("t5"))
            host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
            // .infinity не конечно — это тоже «без паузы», а не бесконечное ожидание.
            XCTAssertEqual(host.gridCells?["t3"], at(1, 2), "Пауза \(bad) = без паузы")
            host.coordinator.finishDrag(commit: false)
            settle(host, "t5")
        }
    }

    /// Reduce Motion паузу не отключает: она про то, чтобы не двигать плитки.
    func testDwellStaysWithReduceMotion() throws {
        let host = try makeRowHost(configuration: configuration(dwell: 0.3))
        host.host.grid.isReduceMotionEnabled = { true }
        host.coordinator.isReduceMotionEnabled = { true }
        let baseTable = try XCTUnwrap(host.gridCells)
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        XCTAssertTrue(host.startDrag("t5"))

        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
        XCTAssertEqual(host.gridCells, baseTable, "Пауза остаётся при Reduce Motion")
        XCTAssertTrue(host.waitUntil { host.gridCells != baseTable })

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    // MARK: - Таймеры не переживают drag

    /// Отмена, завершение и выход из правки снимают таймеры паузы и удержания.
    func testNoTimersLeftAfterCancelDropAndEndEditing() throws {
        let host = try makeRowHost(configuration: configuration(dwell: 5, hold: 5))
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))

        // Отмена жеста на отсчёте паузы.
        XCTAssertTrue(host.startDrag("t5"))
        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
        XCTAssertTrue(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)
        host.coordinator.finishDrag(commit: false)
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)
        settle(host, "t5")

        // Drop на слиянии без выдержанного удержания.
        XCTAssertTrue(host.startDrag("t5"))
        host.coordinator.updateDrag(to: point(t3))
        XCTAssertTrue(host.coordinator.hasPendingDragTimersForTesting.merge)
        host.coordinator.finishDrag(commit: true)
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.merge)
        settle(host, "t5")

        // Выход из правки посреди drag.
        XCTAssertTrue(host.startDrag("t5"))
        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
        XCTAssertTrue(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)
        host.coordinator.endEditing()
        XCTAssertFalse(host.coordinator.isDragging)
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.merge)
    }

    /// Смена конфигурации на лету снимает отсчёт паузы; следующий шаг взводит его
    /// заново.
    func testConfigurationChangeResetsDwell() throws {
        let host = try makeRowHost(configuration: configuration(dwell: 5))
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        XCTAssertTrue(host.startDrag("t5"))
        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
        XCTAssertTrue(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)

        host.coordinator.configuration = configuration(dwell: 5)
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)

        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 3, y: t3.midY))
        XCTAssertTrue(host.coordinator.hasPendingDragTimersForTesting.reorderDwell, "Следующий шаг взвёл отсчёт заново")

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    // MARK: - Сценарий с записи

    /// Запись пользователя: ряд малых плиток, пятая тащится на третью. Подход
    /// справа проходит над четвёртой и краем третьей: ни одна плитка не уезжает
    /// из-под пальца, на центре третьей цель — `.group`, подсветка не мигает при
    /// дрожании, удержание выдерживается, drop создаёт папку из двух плиток.
    func testRecordedScenarioDragFifthOntoThirdCreatesFolder() throws {
        let host = try makeRowHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let baseTable = try XCTUnwrap(host.gridCells)
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        let t5 = try XCTUnwrap(host.host.grid.frame(forItemID: "t5"))
        XCTAssertTrue(host.startDrag("t5"))

        // Путь шагами по 5 pt от центра «t5» к центру «t3».
        var hovers: [HoverTarget] = []
        var x = t5.midX
        while x > t3.midX {
            x = max(t3.midX, x - 5)
            host.coordinator.updateDrag(to: CGPoint(x: x, y: t3.midY))
            let session = try XCTUnwrap(host.coordinator.dragSession)
            hovers.append(session.hover)
            // Пока шаги идут быстрее паузы, превью — база: ничто не убегает.
            XCTAssertEqual(host.gridCells, baseTable, "x = \(x): соседи на местах")
        }
        XCTAssertTrue(hovers.contains(.cell(at(0, 2))), "Палец пересёк край «t3»")
        XCTAssertEqual(hovers.last, .group("t3"), "Центр «t3» — слияние")

        // Дрожание ±8 pt (< 10 pt от якоря удержания) по обеим осям внутри плитки:
        // цель и удержание не сбиваются. Якорь — там, где удержание последний раз
        // перевзводилось на пути (D22), а не обязательно центр.
        let anchor = try XCTUnwrap(host.coordinator.mergeTracker?.anchor)
        for jitter in [CGPoint(x: 8, y: 0), CGPoint(x: -8, y: 3), CGPoint(x: 3, y: 8), CGPoint(x: -4, y: -8)] {
            host.coordinator.updateDrag(to: CGPoint(x: anchor.x + jitter.x, y: anchor.y + jitter.y))
            XCTAssertTrue(t3.insetBy(dx: 6, dy: 6).contains(host.coordinator.dragSession?.lastPoint ?? .zero), "Контроль: точка внутри плитки")
            XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"))
            XCTAssertEqual(host.gridCells, baseTable)
            XCTAssertEqual(host.coordinator.mergeTracker?.targetID, AnyHashable("t3"))
            XCTAssertEqual(host.coordinator.mergeTracker?.anchor, anchor, "Смещение < 10 pt: удержание идёт")
        }

        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })
        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { recorder.createdFolders.count == 1 })
        let folder = try XCTUnwrap(recorder.createdFolders.first)
        settle(host, folder.id)

        XCTAssertEqual(Set(folder.tiles.map { $0.id }), Set<AnyHashable>(["t3", "t5"]), "Папка из двух плиток")
        XCTAssertEqual(folder.size, .medium, "Папка 2×2 (D20)")
        XCTAssertEqual(host.store.placement(of: folder.id), at(0, 2), "На ячейке цели")
        XCTAssertEqual(host.store.placement(of: "t1"), at(0, 0))
        XCTAssertEqual(host.store.placement(of: "t2"), at(0, 1))
        XCTAssertNil(host.store.placement(of: "t5"), "Ярлык ушёл в папку")
    }

    /// Тот же подход «сверху»: палец идёт к центру плитки вертикально, цель не
    /// убегает, слияние достижимо.
    func testApproachFromAboveReachesMergeWithoutPush() throws {
        let host = try TesseraTestDragHost(
            cells: [
                CellFixtureTile("a", .small, 0, 2),
                CellFixtureTile("b", .small, 1, 2),
                CellFixtureTile("c", .small, 2, 4),
            ],
            columns: 6,
            configuration: configuration()
        )
        let baseTable = try XCTUnwrap(host.gridCells)
        let b = try XCTUnwrap(host.host.grid.frame(forItemID: "b"))
        let c = try XCTUnwrap(host.host.grid.frame(forItemID: "c"))
        XCTAssertTrue(host.startDrag("c"))

        var y = c.midY
        var last: HoverTarget = .none
        while y > b.midY {
            y = max(b.midY, y - 5)
            host.coordinator.updateDrag(to: CGPoint(x: b.midX, y: y))
            last = try XCTUnwrap(host.coordinator.dragSession).hover
            XCTAssertEqual(host.gridCells?["b"], baseTable["b"], "y = \(y): «b» не убегает")
            XCTAssertEqual(host.gridCells?["a"], baseTable["a"], "y = \(y): «a» на месте")
        }
        XCTAssertEqual(last, .group("b"))
        host.coordinator.finishDrag(commit: false)
        settle(host, "c")
    }

    // MARK: - Папка как цель

    /// Те же правила для папки: входная зона 59 pt, гистерезис, пауза перед
    /// вытеснением папки с края.
    func testFolderTargetUsesSameZoneHysteresisAndDwell() throws {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("a", .small, 0, 5)],
            folders: [
                CellFixtureFolder("F", .medium, 1, 1, contents: [("f1", .small), ("f2", .small)]),
            ],
            columns: 6,
            configuration: configuration(dwell: 0.3)
        )
        let baseTable = try XCTUnwrap(host.gridCells)
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "F"))
        let entry = TesseraTileMergeZone.entryRect(in: frame)
        XCTAssertEqual(entry.width, frame.width / 2, accuracy: 0.5, "Для 2×2 половина стороны, как и раньше")

        XCTAssertTrue(host.startDrag("a"))
        // Край папки: пауза, потом вытеснение.
        host.coordinator.updateDrag(to: CGPoint(x: frame.minX + 2, y: frame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(1, 1)))
        XCTAssertEqual(host.gridCells, baseTable, "До паузы папка не убегает")
        XCTAssertTrue(host.waitUntil { host.gridCells != baseTable })
        XCTAssertEqual(host.gridCells?["F"], at(2, 1), "После паузы папка вытеснена")

        // Центр: цель — папка, превью — база сразу.
        host.coordinator.updateDrag(to: point(frame))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .folder("F"))
        XCTAssertEqual(host.gridCells, baseTable)
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)

        // Гистерезис: 7 pt от края папки — всё ещё `.folder`.
        host.coordinator.updateDrag(to: CGPoint(x: frame.maxX - 7, y: frame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .folder("F"))
        host.coordinator.updateDrag(to: CGPoint(x: frame.maxX - 3, y: frame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(1, 1)))

        host.coordinator.updateDrag(to: point(frame))
        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })
        host.coordinator.finishDrag(commit: false)
        settle(host, "a")
    }

    // MARK: - Ярлык из панели

    /// Ярлык, выносимый из панели: те же правила зоны и паузы; перестановка внутри
    /// панели (E16) пауз не взводит.
    func testPanelTakeOutUsesDwellAndPanelReorderHasNoTimers() throws {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("t", .small, 0, 2)],
            folders: [
                CellFixtureFolder("F", .medium, 0, 0, contents: [("f1", .small), ("f2", .small), ("f3", .small)]),
            ],
            columns: 6,
            configuration: configuration(dwell: 0.3)
        )
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == AnyHashable("F") })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertTrue(host.waitUntil {
            host.host.panelCell(folderID: "F")?.shortcutCells.first?.accessibilityCustomActions != nil
        })

        // Перестановка внутри панели: длинное нажатие по ярлыку панели, шаги по слотам.
        let panelItem = try XCTUnwrap(host.host.grid.displayItems.first { $0.isFolderPanel })
        let geometry = try XCTUnwrap(host.host.grid.panelShortcutGeometry())
        let slot0 = geometry.frames[0]
        let slot2 = geometry.frames[2]
        host.coordinator.handleLongPress(on: panelItem, at: CGPoint(x: slot0.midX, y: slot0.midY))
        XCTAssertNotNil(host.coordinator.dragSession?.panelReorder)
        host.coordinator.updateDrag(to: CGPoint(x: slot2.midX, y: slot2.midY))
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell, "Перестановка в панели: пауз нет")
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.merge)
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        host.spin(0.4)

        // Вынос: ярлык из панели над краем занятой клетки.
        let iconFrame = try XCTUnwrap(host.host.panelCell(folderID: "F")).shortcutCells[1].frame
        let iconCenter = try XCTUnwrap(host.host.panelCell(folderID: "F")?.shortcutCells[1].superview)
            .convert(CGPoint(x: iconFrame.midX, y: iconFrame.midY), to: host.host.grid)
        host.coordinator.startDragFromPanel(at: iconCenter)
        XCTAssertTrue(host.coordinator.isDragging)
        XCTAssertNil(host.coordinator.dragSession?.panelReorder)

        let tFrame = try XCTUnwrap(host.cellFrame(row: 0, column: 2))
        let baseTable = try XCTUnwrap(host.gridCells)
        host.coordinator.updateDrag(to: CGPoint(x: tFrame.maxX - 2, y: tFrame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)))
        XCTAssertEqual(host.gridCells, baseTable, "До паузы «t» не убегает")
        XCTAssertTrue(host.waitUntil { host.gridCells != baseTable })
        XCTAssertEqual(host.gridCells?["t"], at(1, 2), "После паузы «t» вытеснена")

        // Центр родной папки — по-прежнему `.sourceFolder` (входная зона).
        let folderFrame = try XCTUnwrap(host.cellFrame(row: 0, column: 0, size: .medium))
        host.coordinator.updateDrag(to: point(folderFrame))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .sourceFolder)
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)

        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        host.coordinator.endEditing()
    }

    // MARK: - RTL

    /// RTL: зона и гистерезис считаются по рамке элемента, поэтому работают
    /// зеркально; цель — логическая ячейка.
    func testRightToLeftZoneAndHysteresis() throws {
        let host = try makeRowHost()
        host.host.grid.semanticContentAttribute = .forceRightToLeft
        host.host.collectionView?.semanticContentAttribute = .forceRightToLeft
        host.host.layout()
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        let t5 = try XCTUnwrap(host.host.grid.frame(forItemID: "t5"))
        XCTAssertLessThan(t5.minX, frame.minX, "RTL: «t5» левее «t3»")

        XCTAssertTrue(host.startDrag("t5"))
        host.coordinator.updateDrag(to: point(frame, dx: -17))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"), "Входная зона зеркальна")
        // Край «t3» со стороны «t4» (в RTL — слева на 7 pt): удержание.
        host.coordinator.updateDrag(to: CGPoint(x: frame.minX + 7, y: frame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"))
        host.coordinator.updateDrag(to: CGPoint(x: frame.minX + 3, y: frame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)), "Логическая ячейка (0, 2)")

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    // MARK: - Магнит

    /// Магнит не спорит с зоной: над целью слияния (в том числе в области
    /// удержания) он выключен, снимок остаётся под пальцем.
    func testMagnetStaysOffOverMergeTargetInsideRetainZone() throws {
        let host = try makeRowHost(configuration: configuration(magnet: 28))
        host.coordinator.isReduceMotionEnabled = { false }
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        XCTAssertTrue(host.startDrag("t5"))

        // Выход из стартовой зоны магнита, затем вход в слияние.
        host.coordinator.updateDrag(to: point(frame, dx: 40))
        host.coordinator.updateDrag(to: point(frame))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"))
        XCTAssertNil(host.coordinator.dragMagnetTargetForTesting(at: point(frame)), "Над центром магнита нет")

        let held = CGPoint(x: frame.maxX - 7, y: frame.midY)
        host.coordinator.updateDrag(to: held)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"), "Удержание")
        XCTAssertNil(host.coordinator.dragMagnetTargetForTesting(at: held), "В области удержания магнита нет")

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }
}

#endif
