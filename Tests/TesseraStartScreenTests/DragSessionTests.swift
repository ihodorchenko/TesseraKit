//
//  DragSessionTests.swift
//  TesseraStartScreenTests
//
//  Полные drag-сессии режима редактирования (E10.5, волна W4 плана E9/E10).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §5 «Режим редактирования»
//  (собственный drag-координатор: снимок, пустышка, push-превью, магнит,
//  слияние в папку по удержанию, unpin/resize) и §3 «Плиточная сетка»;
//  docs/PLAN.md E10.5, E9.5, E9.8а.
//
//  Проверяется на реальных ячейках и настоящем `TileStore` в окне
//  (`TesseraTestWindowedGrid` + `TesseraTestDragHost`):
//  - A1: краевые зоны плитки-папки переставляют её, центральная — добавляет
//    ярлык по удержанию E8.6; папка-источник не таскается в папку;
//  - A2: магнит считает слот от центра снимка (`grabOffset`), а не от пальца;
//  - A3: удержание перевзводится после возврата пальца в допуск;
//  - A4: вход в edit закрывает панель папки, drag с панели не начинается;
//  - B1: внешняя модель/снимок во время drag — безопасная отмена без отката к
//    устаревшей базе;
//  - B2: `deinit`/fly-out восстанавливают скрытую ячейку, прокрутку и autosaves;
//  - B3: двойной быстрый unpin — один fly-out и один колбэк;
//  - B4: смена конфигурации на лету перестраивает контролы и «желе»;
//  - B5: «желе» и дим переживают unpin и создание папки;
//  - B6: `.layoutChanged` после unpin/resize;
//  - C1: делегат получает фактический (зажатый/канонизированный) индекс, сетка
//    синхронизируется со снимком store;
//  - C2: `canonicalizeVisibleOrder(columns:)` после unpin/папочных операций;
//  - C3: экран папки активирует ярлык общим маршрутом `grid.onTap`;
//  - E9.5: drop в центр без удержания — возврат на исходное место (no-op);
//  - E9.8а: значения по умолчанию для строгих границ и «желе» ±1,2°;
//  - E11.1: drag ярлыка из панели раскрытой папки (вынос на сетку на позицию
//    превью, распад папки из одного ярлыка, перенос в другую папку по
//    удержанию, no-op без удержания / на родной папке / при отмене), тап по
//    папке в режиме редактирования открывает панель.
//
//  - E12.1: вынос единственного ярлыка в «дыру» модели не кладёт его в
//    соседнюю папку (не воспроизведено; охранные тесты, удержание над B не
//    переживает уход пальца);
//  - E12.1 → E14.5 (цель — клетка под пальцем: `HoverTarget.cell`/`.newRow`,
//    drop там, где показало превью): отдельный набор `DropSlotTests`;
//  - E14.5: цель drag — клетка по базовой раскладке (край занятой клетки — ячейка
//    элемента-цели, центр — слияние), превью — те же элементы на других ячейках
//    (порядок снимка не меняется), центр слияния показывает базовую раскладку;
//  - E11.6: атомарное создание папки drop'ом — отказ второго шага откатывает
//    первый (модель как до drop'а, только `didFailGrouping`), `didCreateFolder`
//    приходит после обоих шагов и перед `didAdd`.
//
//  Детерминизм: без `sleep`; завершение — прокруткой run loop (`waitUntil`),
//  таймеры удержания в тестах укорачиваются через конфигурацию.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class DragSessionTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Делегат-рекордер событий координатора.
    private final class DragDelegateRecorder: TesseraTileEditCoordinatorDelegate {

        /// События `didMove(toIndex:)` в порядке прихода.
        var moves: [(id: AnyHashable, index: Int)] = []

        /// События `didUnpin`.
        var unpins: [AnyHashable] = []

        /// События `didResize`.
        var resizes: [(id: AnyHashable, size: TileSize)] = []

        /// События `didCreateFolder`.
        var createdFolders: [TileFolder] = []

        /// События `didAdd(toFolder:)`.
        var additions: [(id: AnyHashable, folder: AnyHashable)] = []

        /// События `didMove(toFolder:)`.
        var folderMoves: [(id: AnyHashable, folder: AnyHashable?)] = []

        /// События `didFailGrouping`.
        var failures: [TileGroupingAction] = []

        /// Порядок делегатных событий папок: "create" / "add" (E11.6).
        var folderEventLog: [String] = []

        /// Сколько раз координатор вошёл/вышел из редактирования.
        var beginEditingCount = 0
        var endEditingCount = 0

        func tileEditCoordinatorDidBeginEditing(_ coordinator: TesseraTileEditCoordinator) {
            beginEditingCount += 1
        }

        func tileEditCoordinatorDidEndEditing(_ coordinator: TesseraTileEditCoordinator) {
            endEditingCount += 1
        }

        func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didUnpin tileID: AnyHashable) {
            unpins.append(tileID)
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didResize tileID: AnyHashable,
            to size: TileSize
        ) {
            resizes.append((tileID, size))
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toIndex index: Int
        ) {
            moves.append((tileID, index))
        }

        func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didCreateFolder folder: TileFolder) {
            createdFolders.append(folder)
            folderEventLog.append("create")
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didAdd tileID: AnyHashable,
            toFolder folderID: AnyHashable
        ) {
            additions.append((tileID, folderID))
            folderEventLog.append("add")
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toFolder folderID: AnyHashable?
        ) {
            folderMoves.append((tileID, folderID))
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didFailGrouping action: TileGroupingAction,
            tileID: AnyHashable,
            folderID: AnyHashable?
        ) {
            failures.append(action)
        }
    }

    /// Стенд с папкой из ярлыка «b» (порядок сетки: «a», папка).
    ///
    /// - Parameters:
    ///   - configuration: Параметры редактирования.
    /// - Returns: Готовый стенд.
    private func makeFolderHost(
        configuration: TesseraTileEditConfiguration = TesseraTileEditConfiguration()
    ) -> TesseraTestDragHost {
        TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ],
            configuration: configuration,
            prepare: { store in
                _ = store.createFolder(withTile: "b")
            }
        )
    }

    /// Альфа содержимого ячейки.
    ///
    /// - Parameters:
    ///   - id: Идентификатор элемента.
    ///   - host: Стенд.
    /// - Returns: `contentView.alpha` или 1, если ячейки нет.
    private func alpha(of id: AnyHashable, in host: TesseraTestDragHost) -> CGFloat {
        host.host.cell(id)?.contentView.alpha ?? 1
    }

    /// Ячейка элемента в модели — она же базовая ячейка drag (E14.5): модель за
    /// время drag не меняется.
    ///
    /// - Parameters:
    ///   - id: Идентификатор элемента.
    ///   - host: Стенд.
    /// - Returns: Ячейка из `TileStore`.
    private func cell(_ id: AnyHashable, in host: TesseraTestDragHost) throws -> TileGridPlacement {
        // Ячейки, которые видит сетка (для ширины сетки): файл мог быть собран
        // операциями на другой ширине холста, тогда это проекция (D32).
        try XCTUnwrap(
            host.store.placements(forColumns: host.host.grid.columns)[id],
            "У \(id) нет ячейки в модели"
        )
    }

    /// Текущая анимация «желе» на ячейке (E8.2/E10.5-B5).
    ///
    /// - Parameters:
    ///   - id: Идентификатор элемента.
    ///   - host: Стенд.
    /// - Returns: Анимация или `nil`.
    private func jiggle(of id: AnyHashable, in host: TesseraTestDragHost) -> CAAnimation? {
        host.host.cell(id)?.contentView.layer.animation(
            forKey: TesseraTileEditCoordinator.jiggleKey
        )
    }

    // MARK: - Конфигурация E9.8а

    /// Границы E8.6 и «желе»: 600 мс / 10 pt и ±1,2° — значения по умолчанию.
    func testDragConfigurationDefaultsMatchApprovedDecisions() {
        let configuration = TesseraTileEditConfiguration()

        XCTAssertEqual(configuration.mergeHoverDuration, 0.6, accuracy: 0.0001)
        XCTAssertEqual(configuration.mergeHoverDisplacement, 10, accuracy: 0.0001)
        XCTAssertEqual(configuration.jiggleAngle, 1.2, accuracy: 0.0001)
        XCTAssertEqual(configuration.jiggleDuration, 0.4, accuracy: 0.0001)
        XCTAssertEqual(configuration.controlDiameter, 28, accuracy: 0.0001)
    }

    // MARK: - A1: краевые зоны плитки-папки

    /// Левая/правая половина плитки-папки — зона размещения: ярлык встаёт на
    /// ячейку папки, а папка выталкивается вниз (E10.5-A1, E14.5, D31).
    func testFolderEdgeZoneReordersTileInsteadOfAdding() throws {
        let host = makeFolderHost()
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let folderID = try XCTUnwrap(host.firstFolderID)

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(folderID, fx: 0.1, fy: 0.5)))

        let folderCell = try cell(folderID, in: host)
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(folderCell),
            "Край папки — цель размещения с ячейкой папки"
        )

        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(
            host.waitUntil { recorder.moves.count == 1 },
            "Drop в краевой зоне завершился перемещением"
        )
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("a"))
        XCTAssertEqual(recorder.moves.first?.index, 0, "Фактический индекс в порядке чтения")
        XCTAssertEqual(host.store.placement(of: "a"), folderCell, "Ярлык — на ячейке папки")
        XCTAssertEqual(
            host.store.placement(of: folderID),
            TileGridPlacement(row: folderCell.row + 1, column: folderCell.column),
            "Папка вытолкнута вниз (D31)"
        )
        XCTAssertEqual(host.storeIDs, [AnyHashable("a"), folderID])
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }

    /// Перетаскивание папки по сетке — обычное размещение в любой зоне:
    /// папку нельзя бросить в папку (`session.isTile == false`).
    func testFolderAsSourceIsNeverGrouped() throws {
        let host = makeFolderHost()
        let folderID = try XCTUnwrap(host.firstFolderID)

        XCTAssertTrue(host.startDrag(folderID))
        XCTAssertEqual(host.coordinator.dragSession?.isTile, false)

        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("a", fx: 0.5, fy: 0.5)))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(try cell("a", in: host)),
            "Папка над центром ярлыка — размещение на его ячейку, а не группировка"
        )
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitForDragCleanup(folderID))
    }

    /// Центральная зона папки без удержания — no-op (E9.5): модель и сетка не
    /// меняются, делегат не получает событий.
    func testFolderCenterZoneWithoutHoldReturnsToOriginalPlace() throws {
        let host = makeFolderHost(configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0))
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let folderID = try XCTUnwrap(host.firstFolderID)
        let folderTilesBefore = try XCTUnwrap(host.folders.first).tiles.map { $0.id }

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(folderID, fx: 0.5, fy: 0.5)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .folder(folderID))

        host.coordinator.finishDrag(commit: true)
        XCTAssertEqual(host.storeIDs, ["a", folderID], "Модель не изменилась")
        XCTAssertEqual(
            try XCTUnwrap(host.folders.first).tiles.map { $0.id },
            folderTilesBefore,
            "Ярлык не добавлен в папку без удержания"
        )
        XCTAssertTrue(recorder.additions.isEmpty)
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }

    /// Центральная зона папки с выдержанным удержанием E8.6 — ярлык уходит
    /// внутрь папки (D14), сетка остаётся с одной плиткой-папкой.
    func testFolderCenterZoneAfterHoldAddsTileToFolder() throws {
        let host = makeFolderHost(
            configuration: TesseraTileEditConfiguration(
                mergeHoverDuration: 0.05,
                magnetSnapRadius: 0
            )
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let folderID = try XCTUnwrap(host.firstFolderID)

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(folderID, fx: 0.5, fy: 0.5)))
        XCTAssertTrue(
            host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
            "Удержание над центральной зоной папки выдержано"
        )

        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { recorder.additions.count == 1 })
        XCTAssertEqual(recorder.additions.first?.id, AnyHashable("a"))
        XCTAssertEqual(recorder.additions.first?.folder, folderID)
        XCTAssertEqual(host.storeIDs, [folderID], "Ярлык ушёл в папку")
        XCTAssertTrue(
            host.waitUntil {
                host.folders.first?.tiles.contains { $0.id == AnyHashable("a") } == true
            },
            "Ярлык в модели папки"
        )
    }

    /// E11.3: при создании папки снимок схлопывается в рамку новой плитки-папки,
    /// а не в слот плейсхолдера (рамка читается после `render`).
    func testNewFolderDropCollapsesIntoFolderFrame() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("x", size: .small),
                tesseraTestTile("b", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(
                mergeHoverDuration: 0.05,
                magnetSnapRadius: 0
            )
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.startDrag("a"))
        let placeholderFrame = try XCTUnwrap(host.coordinator.dragSession?.placeholder.frame)
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("b", fx: 0.5, fy: 0.5)))
        XCTAssertTrue(
            host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
            "Удержание над центром ярлыка выдержано"
        )
        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { recorder.additions.count == 1 })

        let folderID = try XCTUnwrap(host.firstFolderID)
        let target = try XCTUnwrap(host.coordinator.lastCollapseTargetFrame)
        let folderFrame = try XCTUnwrap(host.host.grid.frame(forItemID: folderID))
        XCTAssertEqual(target, folderFrame, "Цель полёта — рамка новой папки")
        XCTAssertNotEqual(target, placeholderFrame, "Не старый слот плейсхолдера")
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil }, "Drag завершён")
    }

    // MARK: - A2: магнит от центра снимка (grabOffset)

    /// Магнит считает расстояние от центра снимка, а не от пальца: плитка,
    /// взятая за угол, притягивается к слоту, хотя палец от него дальше
    /// радиуса; снимок при этом не прыгает (E10.5-A2).
    func testMagnetUsesSnapshotCenterNotFingerPoint() throws {
        let host = TesseraTestDragHost(
            descriptors: (0..<4).map { tesseraTestTile("s\($0)", size: .small) },
            configuration: TesseraTileEditConfiguration(
                magnetSnapRadius: 28,
                magnetSpringDuration: 0
            )
        )
        let slotCenters = host.host.grid.magnetSlotCenters(for: .small)
        XCTAssertEqual(slotCenters.count, 4, "Один ряд из четырёх small-слотов")
        let slotCenter = slotCenters[2]

        // Захват за угол: grabOffset ≈ 0,4 стороны плитки, длина > радиуса.
        XCTAssertTrue(host.startDrag("s0", fx: 0.1, fy: 0.1))
        let session = try XCTUnwrap(host.coordinator.dragSession)
        XCTAssertGreaterThan(
            hypot(session.grabOffset.x, session.grabOffset.y),
            host.coordinator.configuration.magnetSnapRadius,
            "Захват не за центр — старый (по пальцу) магнит здесь не сработал бы"
        )

        // Палец ставим так, чтобы ЦЕНТР снимка оказался в центре слота.
        let point = CGPoint(
            x: slotCenter.x - session.grabOffset.x,
            y: slotCenter.y - session.grabOffset.y
        )
        XCTAssertGreaterThan(
            hypot(point.x - slotCenter.x, point.y - slotCenter.y),
            host.coordinator.configuration.magnetSnapRadius,
            "Палец дальше радиуса от слота"
        )
        host.coordinator.updateDrag(to: point)

        let sessionAfter = try XCTUnwrap(host.coordinator.dragSession)
        XCTAssertEqual(sessionAfter.magnetTarget, slotCenter, "Цель магнита — центр слота")
        XCTAssertEqual(
            sessionAfter.dragView.center.x,
            slotCenter.x,
            accuracy: 0.001,
            "Снимок притянут к центру слота"
        )
        XCTAssertEqual(sessionAfter.dragView.center.y, slotCenter.y, accuracy: 0.001)
        let followCenter = CGPoint(
            x: point.x + sessionAfter.grabOffset.x,
            y: point.y + sessionAfter.grabOffset.y
        )
        XCTAssertLessThanOrEqual(
            hypot(
                sessionAfter.dragView.center.x - followCenter.x,
                sessionAfter.dragView.center.y - followCenter.y
            ),
            host.coordinator.configuration.magnetSnapRadius + 0.001,
            "Снимок сместился к слоту не больше чем на радиус"
        )

        // Уводим палец далеко: магнит снимается, снимок снова под пальцем 1:1.
        let farPoint = CGPoint(x: point.x, y: point.y + 150)
        host.coordinator.updateDrag(to: farPoint)
        let sessionFar = try XCTUnwrap(host.coordinator.dragSession)
        XCTAssertNil(sessionFar.magnetTarget, "Слотов рядом нет")
        XCTAssertEqual(
            sessionFar.dragView.center.x,
            farPoint.x + sessionFar.grabOffset.x,
            accuracy: 0.001
        )
        XCTAssertEqual(
            sessionFar.dragView.center.y,
            farPoint.y + sessionFar.grabOffset.y,
            accuracy: 0.001
        )
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitForDragCleanup("s0"))
    }

    // MARK: - A3: перевзвод удержания E8.6

    /// Смещение на допуск отменяет удержание и переносит якорь на текущую точку
    /// (E12.3, заменил E10.5-A3): возврат к старому якорю — снова смещение, то
    /// есть новый отсчёт 600 мс; drop после выдержанного нового отсчёта создаёт папку.
    func testMergeHoldRearmsAfterReturningToTolerance() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(
                mergeHoverDuration: 0.05,
                magnetSnapRadius: 0
            )
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let center = try XCTUnwrap(host.point("b", fx: 0.5, fy: 0.5))

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: center)
        XCTAssertEqual(host.coordinator.mergeTracker?.state, .armed)
        XCTAssertEqual(host.coordinator.mergeTracker?.anchor, center)

        // Смещение 15 pt внутри центральной зоны: якорь переносится в новую точку.
        let moved = CGPoint(x: center.x + 15, y: center.y)
        host.coordinator.updateDrag(to: moved)
        XCTAssertEqual(host.coordinator.mergeTracker?.state, .armed)
        XCTAssertEqual(host.coordinator.mergeTracker?.anchor, moved)
        XCTAssertFalse(host.coordinator.mergeTracker?.isMergeReady == true)

        // Возврат к старой точке — снова смещение на 15 pt: ещё один перевзвод,
        // а не мгновенная готовность.
        host.coordinator.updateDrag(to: center)
        XCTAssertEqual(host.coordinator.mergeTracker?.state, .armed)
        XCTAssertEqual(host.coordinator.mergeTracker?.anchor, center)
        XCTAssertFalse(host.coordinator.mergeTracker?.isMergeReady == true)
        XCTAssertTrue(
            host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
            "Новый отсчёт 600 мс выдержан"
        )

        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { recorder.createdFolders.count == 1 })
        XCTAssertEqual(host.folders.count, 1, "Папка создана после перевзвода")
    }

    // MARK: - A4: панель папки и вход в edit

    /// Вход в редактирование закрывает раскрытую панель папки штатным
    /// `closeFolder` (E10.5-A4).
    func testBeginEditingClosesExpandedFolder() throws {
        let host = makeFolderHost()
        let folderID = try XCTUnwrap(host.firstFolderID)
        let folder = try XCTUnwrap(host.folders.first)

        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)

        host.coordinator.beginEditing()
        XCTAssertTrue(
            host.host.waitForFolderTransition(),
            "Закрытие панели завершилось"
        )
        XCTAssertNil(host.host.grid.expandedFolderID, "Панель закрыта при входе в edit")
        XCTAssertTrue(host.host.grid.isScrollEnabled)
        host.coordinator.endEditing()
    }

    /// Drag не начинается с ячеек панели раскрытой папки (E10.5-A4/E9.8а):
    /// панель — представление, её место фиксировано раскладкой.
    func testDragDoesNotStartFromExpandedFolderPanel() throws {
        let host = makeFolderHost()
        let folderID = try XCTUnwrap(host.firstFolderID)
        let folder = try XCTUnwrap(host.folders.first)

        host.coordinator.beginEditing()
        // Хост явно раскрывает панель уже в edit-режиме (разрешено).
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)

        let panelItem = try XCTUnwrap(
            host.host.grid.displayItems.first { $0.isFolderPanel }
        )
        let panelCell = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        let panelCenter = panelCell.convert(
            CGPoint(x: panelCell.bounds.midX, y: panelCell.bounds.midY),
            to: host.host.grid
        )

        host.coordinator.handleLongPress(on: panelItem, at: panelCenter)

        XCTAssertFalse(host.coordinator.isDragging, "Панель не таскается")
        XCTAssertEqual(
            host.host.grid.expandedFolderID,
            folderID,
            "Панель осталась раскрытой"
        )
        XCTAssertEqual(host.storeIDs, ["a", folderID], "Модель не тронута")
        host.coordinator.endEditing()
    }

    // MARK: - B1: внешние изменения во время drag

    /// Внешняя мутация модели (unpin из списка приложений) во время drag:
    /// сессия безопасно отменяется, сетка синхронизируется с моделью, к
    /// устаревшей базе ничего не откатывается (E10.5-B1).
    func testExternalModelChangeCancelsDragWithoutStaleRestore() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.startDrag("a"))
        // Хост меняет модель и применяет снимок, пока палец ещё держит плитку.
        XCTAssertTrue(host.store.unpin("c"))
        host.host.grid.update(snapshot: host.store.snapshot(), animated: false)
        host.host.layout()

        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("b", fx: 0.5, fy: 0.5)))

        XCTAssertFalse(host.coordinator.isDragging, "Drag отменён")
        XCTAssertEqual(host.storeIDs, ["a", "b"], "Модель не откатилась к базе")
        XCTAssertEqual(host.gridIDs, host.storeIDs, "Сетка синхронизирована с моделью")
        XCTAssertTrue(host.host.grid.isScrollEnabled, "Прокрутка восстановлена")
        XCTAssertGreaterThan(alpha(of: AnyHashable("a"), in: host), 0.9, "Ячейка снова видима")
        XCTAssertTrue(recorder.moves.isEmpty, "Делегат не получал перестановку")
        XCTAssertTrue(host.store.autosaves == false, "Автосохранение стенда не включилось")
    }

    /// Внешний `grid.update` в обход координатора (снимок без части элементов)
    /// тоже отменяет drag и возвращает сетку к модели (E10.5-B1).
    func testExternalGridUpdateCancelsDragAndRestoresModel() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.startDrag("a"))
        // Чужой снимок с тем же составом, но переставленным порядком.
        let reversed = Array(host.store.snapshot().items.reversed())
        host.host.grid.update(
            snapshot: TileGridSnapshot(items: reversed, unpinned: []),
            animated: false
        )
        host.host.layout()
        XCTAssertEqual(host.gridIDs, reversed.map { $0.id })

        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("b", fx: 0.5, fy: 0.5)))

        XCTAssertFalse(host.coordinator.isDragging, "Drag отменён")
        XCTAssertEqual(host.gridIDs, host.storeIDs, "Порядок модели возвращён")
        XCTAssertEqual(host.gridIDs, ["a", "b", "c"])
        XCTAssertTrue(recorder.moves.isEmpty)
    }

    // MARK: - B2: deinit и fly-out

    /// `deinit` активной drag-сессии возвращает скрытую ячейку, прокрутку,
    /// автосохранение и снимает оверлеи (E10.5-B2).
    func testDeinitRestoresHiddenCellScrollAndAutosaves() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = TileStore(directoryURL: directory.url)
        store.autosaves = true
        store.setCatalog([
            tesseraTestTile("a", size: .small),
            tesseraTestTile("b", size: .small),
        ])
        let windowed = TesseraTestWindowedGrid(items: store.snapshot().items)
        windowed.layout()

        var editor: TesseraTileEditCoordinator? = TesseraTileEditCoordinator(
            grid: windowed.grid,
            store: store
        )
        editor?.isReduceMotionEnabled = { false }
        windowed.grid.isReduceMotionEnabled = { false }
        let item = try XCTUnwrap(windowed.grid.items.first { $0.id == AnyHashable("a") })
        let frame = try XCTUnwrap(windowed.grid.frame(forItemID: "a"))
        let center = CGPoint(x: frame.midX, y: frame.midY)
        editor?.handleLongPress(on: item, at: center)

        XCTAssertTrue(try XCTUnwrap(editor).isDragging)
        XCTAssertFalse(store.autosaves, "Транзакция drag выключила автосохранение")
        XCTAssertFalse(windowed.grid.isScrollEnabled, "Прокрутка выключена на drag")
        XCTAssertEqual(
            try XCTUnwrap(windowed.cell("a")).contentView.alpha,
            0,
            accuracy: 0.001,
            "Исходная ячейка скрыта"
        )

        editor = nil

        XCTAssertTrue(store.autosaves, "Автосохранение восстановлено")
        XCTAssertTrue(windowed.grid.isScrollEnabled, "Прокрутка восстановлена")
        XCTAssertEqual(windowed.grid.items.map { $0.id }, store.snapshot().items.map { $0.id })
        XCTAssertEqual(
            try XCTUnwrap(windowed.cell("a")).contentView.alpha,
            1,
            accuracy: 0.001,
            "Скрытая ячейка возвращена"
        )
        XCTAssertNil(
            windowed.firstSubview(of: TesseraTilePlaceholderView.self),
            "Пустышка снята"
        )
        XCTAssertNil(
            windowed.firstSubview(of: TesseraTileDropHighlightView.self),
            "Подсветка цели снята"
        )
    }

    /// deinit посреди fly-out: ячейка всё равно возвращается, мутация unpin не
    /// происходит (анимация отменяется) — E10.5-B2.
    func testFlyOutCompletionRestoresCellAfterCoordinatorDeinit() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = TileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog([
            tesseraTestTile("a", size: .small),
            tesseraTestTile("b", size: .small),
        ])
        let windowed = TesseraTestWindowedGrid(items: store.snapshot().items)
        windowed.layout()

        var editor: TesseraTileEditCoordinator? = TesseraTileEditCoordinator(
            grid: windowed.grid,
            store: store
        )
        editor?.isReduceMotionEnabled = { false }
        windowed.grid.isReduceMotionEnabled = { false }
        editor?.unpin("a")
        XCTAssertEqual(
            try XCTUnwrap(windowed.cell("a")).contentView.alpha,
            0,
            accuracy: 0.001,
            "Fly-out скрыл ячейку"
        )

        editor = nil

        XCTAssertTrue(
            windowed.waitUntil {
                (windowed.cell("a")?.contentView.alpha ?? 0) > 0
            },
            "Ячейка возвращена после исчезновения координатора"
        )
        XCTAssertTrue(store.isPinned("a"), "Мутация не выполнена — модель не тронута")
        XCTAssertEqual(windowed.grid.items.map { $0.id }.contains(AnyHashable("a")), true)
    }

    // MARK: - B3: двойной быстрый unpin

    /// Повторный unpin во время fly-out не запускает вторую анимацию, вторую
    /// мутацию и второй колбэк (E10.5-B3).
    func testDoubleUnpinRunsSingleFlyOut() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ]
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder

        host.coordinator.unpin("a")
        let subviewsAfterFirst = Set(host.host.grid.subviews.map { ObjectIdentifier($0) })
        host.coordinator.unpin("a")
        let subviewsAfterSecond = Set(host.host.grid.subviews.map { ObjectIdentifier($0) })
        XCTAssertEqual(
            subviewsAfterFirst,
            subviewsAfterSecond,
            "Второй fly-out не создан"
        )

        XCTAssertTrue(
            host.waitUntil { recorder.unpins.count == 1 },
            "Ровно один колбэк открепления"
        )
        XCTAssertEqual(host.storeIDs, ["b"])
        XCTAssertTrue(host.waitUntil { recorder.unpins.count == 1 })
        XCTAssertEqual(host.store.isPinned("a"), false)
    }

    // MARK: - B4: смена конфигурации на лету

    /// Смена `controlDiameter`/`jiggleDuration` на лету пересоздаёт контролы и
    /// перезапускает «желе» (E10.5-B4).
    func testConfigurationChangeRebuildsControlsAndJiggle() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ]
        )
        host.coordinator.beginEditing()
        let firstControl = try XCTUnwrap(host.coordinator.editControls[AnyHashable("a")])
        XCTAssertEqual(firstControl.diameter, 28, accuracy: 0.001)

        var configuration = host.coordinator.configuration
        configuration.controlDiameter = 44
        configuration.jiggleDuration = 0.8
        configuration.jiggleAngle = 2
        host.coordinator.configuration = configuration

        let secondControl = try XCTUnwrap(host.coordinator.editControls[AnyHashable("a")])
        XCTAssertFalse(secondControl === firstControl, "Контрол пересоздан под новый диаметр")
        XCTAssertEqual(secondControl.diameter, 44, accuracy: 0.001)

        let animation = try XCTUnwrap(jiggle(of: AnyHashable("a"), in: host))
        let duration = try XCTUnwrap(animation.duration)
        XCTAssertGreaterThanOrEqual(duration, 0.8 * 0.85 - 0.001)
        XCTAssertLessThanOrEqual(duration, 0.8 * 1.15 + 0.001)
        host.coordinator.endEditing()
    }

    // MARK: - B5: «желе» и дим после unpin/создания папки

    /// После unpin и создания папки сетка переприменяет «желе» и дим: плитки не
    /// замирают и не теряют прозрачность (E10.5-B5, E8.2, E10.4).
    func testJiggleAndDimmingSurviveUnpinAndFolderCreation() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ]
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        host.coordinator.beginEditing()

        XCTAssertTrue(
            host.waitUntil {
                abs(self.alpha(of: AnyHashable("a"), in: host) - TesseraTileGridView.dimmedTileAlpha) < 0.01
                    && self.jiggle(of: AnyHashable("a"), in: host) != nil
            },
            "Вход в edit: дим и «желе»"
        )

        host.coordinator.unpin("b")
        XCTAssertTrue(host.waitUntil { recorder.unpins.count == 1 })
        XCTAssertTrue(
            host.waitUntil {
                abs(self.alpha(of: AnyHashable("a"), in: host) - TesseraTileGridView.dimmedTileAlpha) < 0.01
                    && self.jiggle(of: AnyHashable("a"), in: host) != nil
            },
            "После unpin соседняя плитка не замерла и не потеряла дим"
        )

        let folder = try XCTUnwrap(host.coordinator.createFolder(withTile: "a"))
        // Новые ячейки создаются в layout-проходе коллекции — доводим его до
        // проверки «желе»/дима на ячейке папки.
        host.host.layout()
        XCTAssertTrue(
            host.waitUntil {
                let cell = host.host.cell(folder.id)
                return cell != nil
                    && abs((cell?.contentView.alpha ?? 0) - TesseraTileGridView.dimmedTileAlpha) < 0.01
                    && self.jiggle(of: folder.id, in: host) != nil
            },
            "Ячейка папки получила дим и «желе» после reload"
        )
        host.coordinator.endEditing()
    }

    // MARK: - B6: .layoutChanged после unpin/resize

    /// После unpin публикуется `.layoutChanged` с фокусом на элемент, вставший
    /// на место удалённого (E10.5-B6).
    func testLayoutChangedPostedAfterUnpin() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ]
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        var posts: [(UIAccessibility.Notification, Any?)] = []
        host.coordinator.accessibilityNotificationPoster = { notification, argument in
            posts.append((notification, argument))
        }

        host.coordinator.unpin("a")
        XCTAssertTrue(host.waitUntil { recorder.unpins.count == 1 })
        XCTAssertTrue(host.waitUntil { !posts.isEmpty }, "Уведомление опубликовано")
        XCTAssertEqual(posts.last?.0, UIAccessibility.Notification.layoutChanged)
        XCTAssertTrue(
            (posts.last?.1 as? UIView) === host.host.cell("b"),
            "Фокус на элементе, занявшем место удалённого"
        )
    }

    /// После resize публикуется `.layoutChanged` с фокусом на изменённую плитку
    /// (E10.5-B6).
    func testLayoutChangedPostedAfterResize() throws {
        let host = TesseraTestDragHost(
            descriptors: [tesseraTestTile("a", size: .small)]
        )
        var posts: [(UIAccessibility.Notification, Any?)] = []
        host.coordinator.accessibilityNotificationPoster = { notification, argument in
            posts.append((notification, argument))
        }

        host.coordinator.beginEditing()
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .medium)
        XCTAssertTrue(host.waitUntil { !posts.isEmpty })
        XCTAssertEqual(posts.last?.0, UIAccessibility.Notification.layoutChanged)
        XCTAssertTrue(
            (posts.last?.1 as? UIView) === host.host.cell("a"),
            "Фокус на изменённой плите"
        )
        host.coordinator.endEditing()
    }

    // MARK: - C1: фактический индекс из store

    /// Drop отдаёт делегату фактический индекс элемента в порядке чтения после
    /// `TileStore.moveItem(_:toCell:columns:)`, а сетка синхронизируется со
    /// снимком store (E10.5-C1, E14.5): «a» встала на ячейку «c», «c» вытолкнута
    /// вниз.
    func testDropReportsActualIndexFromStore() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("c", fx: 0.1, fy: 0.5)))
        host.coordinator.finishDrag(commit: true)

        XCTAssertTrue(host.waitUntil { recorder.moves.count == 1 })
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("a"))
        XCTAssertEqual(recorder.moves.first?.index, 1, "Фактический индекс в порядке чтения")
        XCTAssertEqual(host.storeIDs, ["b", "a", "c"])
        XCTAssertEqual(host.gridIDs, host.storeIDs, "Сетка синхронизирована со store")
    }

    /// Публичный `move` зажимает индекс хранилищем и отдаёт делегату
    /// фактический, а не запрошенный индекс (E10.5-C1).
    func testPublicMoveClampsAndReportsActualIndex() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .small),
            ]
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.coordinator.move("a", toIndex: 99))
        XCTAssertEqual(recorder.moves.count, 1)
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("a"))
        XCTAssertEqual(recorder.moves.first?.index, 2, "Индекс зажат до последнего")
        XCTAssertEqual(host.storeIDs, ["b", "c", "a"])
        XCTAssertEqual(host.gridIDs, host.storeIDs)
    }

    /// Drop после канонизации порядка (E10.15): сетка совпадает со снимком
    /// store, даже если тот переставил соседей; делегат получает индекс из
    /// хранилища (E10.5-C1).
    func testDropSyncsGridWithCanonicalizedStoreOrder() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("A", size: .medium),
                tesseraTestTile("W", size: .wide),
                tesseraTestTile("S", size: .small),
                tesseraTestTile("T", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.startDrag("S"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("A", fx: 0.1, fy: 0.5)))
        host.coordinator.finishDrag(commit: true)

        XCTAssertTrue(host.waitUntil { recorder.moves.count == 1 })
        let storeIDs = host.storeIDs
        XCTAssertEqual(host.gridIDs, storeIDs, "Сетка совпадает со снимком store")
        XCTAssertEqual(
            storeIDs,
            host.store.placementReadingOrder(forColumns: 4),
            "Порядок модели — порядок чтения ячеек"
        )
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("S"))
        XCTAssertEqual(
            recorder.moves.first?.index,
            storeIDs.firstIndex(of: AnyHashable("S")),
            "Делегат получил индекс из store"
        )
    }

    // MARK: - C2: канонизация после unpin/папочных операций

    /// После unpin видимый порядок приводится к порядку чтения (E10.5-C2).
    func testCanonicalizeVisibleOrderAfterUnpin() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("A", size: .medium),
                tesseraTestTile("W", size: .wide),
                tesseraTestTile("S", size: .small),
                tesseraTestTile("T", size: .small),
            ]
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        host.coordinator.beginEditing()
        defer { host.coordinator.endEditing() }

        host.coordinator.unpin("T")
        XCTAssertTrue(host.waitUntil { recorder.unpins.count == 1 })

        XCTAssertEqual(
            host.storeIDs,
            ["A", "S", "W"],
            "Unpin канонизировал порядок"
        )
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
    }

    /// Создание папки тоже канонизирует видимый порядок (E10.5-C2).
    func testCanonicalizeVisibleOrderAfterFolderCreation() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("A", size: .medium),
                tesseraTestTile("W", size: .wide),
                tesseraTestTile("S", size: .small),
            ]
        )
        let folder = try XCTUnwrap(host.coordinator.createFolder(withTile: "S"))
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertEqual(host.storeIDs, ["A", folder.id, "W"], "Порядок чтения после папки")
        XCTAssertEqual(
            host.storeIDs,
            TileStore.readingOrder(of: host.store.snapshot().layoutItems, columns: 4)
        )
    }

    /// Перемещение ярлыка из папки на рабочий стол оставляет порядок модели
    /// порядком чтения ячеек и идёт через функцию одобрения (D14, E10.5-C2,
    /// E14.5): последний ярлык занимает ячейку исчезнувшей папки.
    func testCanonicalizeVisibleOrderAfterMoveBetweenFolders() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("A", size: .medium),
                tesseraTestTile("W", size: .wide),
                tesseraTestTile("S", size: .small),
            ],
            prepare: { store in
                _ = store.createFolder(withTile: "S")
            }
        )
        let folderID = try XCTUnwrap(host.firstFolderID)
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.coordinator.moveBetweenFolders("S", to: nil))
        XCTAssertTrue(host.waitUntil { recorder.folderMoves.count == 1 })
        XCTAssertEqual(host.storeIDs, ["A", "S", "W"], "Порядок чтения после возврата")
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertEqual(host.folders.isEmpty, true, "Опустевшая папка распущена")
        XCTAssertFalse(host.storeIDs.contains(folderID))
    }

    /// E11.2/E14.5: вынос из папки без индекса ставит ярлык на первую свободную
    /// ячейку после папки (рядом с ней), а не в конец; порядок модели — порядок
    /// чтения ячеек.
    func testMoveOutOfFolderLandsAfterFolderThroughCoordinator() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .small),
                tesseraTestTile("d", size: .small),
            ],
            prepare: { store in
                if let folder = store.createFolder(withTile: "a") {
                    _ = store.addToFolder("b", folderID: folder.id)
                }
            }
        )
        let folderID = try XCTUnwrap(host.firstFolderID)

        let folderCell = try cell(folderID, in: host)
        XCTAssertTrue(host.coordinator.moveBetweenFolders("b", to: nil))
        // Папка 2×2 в (0, 0), «c» и «d» справа в строке 0; первая свободная
        // ячейка после папки — (1, 2), под «c».
        XCTAssertEqual(host.store.placement(of: "b"), TileGridPlacement(row: folderCell.row + 1, column: 2))
        XCTAssertEqual(host.storeIDs, [folderID, "c", "d", "b"])
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
    }

    // MARK: - C3: экран папки через onTap

    /// Тап по ярлыку встроенного экрана папки идёт общим маршрутом `grid.onTap`
    /// (действие выполняет хост), а не вызовом `action` напрямую (E10.5-C3).
    func testFolderScreenTapRoutesThroughGridOnTap() throws {
        var actionCalls = 0
        var folderTile = TileDescriptor(
            id: "in-folder",
            title: "Inside",
            action: { actionCalls += 1 },
            size: .small
        )
        folderTile.badge = .none
        let host = TesseraTestDragHost(
            descriptors: [tesseraTestTile("a", size: .small), folderTile],
            prepare: { store in
                _ = store.createFolder(withTile: "in-folder")
            }
        )
        var tapped: [TileGridItem] = []
        host.host.grid.onTap = { tapped.append($0) }

        let folder = try XCTUnwrap(host.folders.first)
        let tile = try XCTUnwrap(folder.tiles.first)
        let screen = TesseraFolderViewController(
            folder: folder,
            store: host.store,
            coordinator: host.coordinator
        )

        XCTAssertTrue(screen.activateTile(tile), "Тап передан координатору")
        XCTAssertEqual(tapped.count, 1, "Событие ушло в grid.onTap")
        XCTAssertEqual(tapped.first?.tile?.id, tile.id)
        XCTAssertEqual(actionCalls, 0, "Экран папки не вызывает action напрямую")
    }

    /// В режиме редактирования экран папки не активирует ярлык (E10.5-C3).
    func testFolderScreenTapDoesNotActivateInEditMode() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ],
            prepare: { store in
                _ = store.createFolder(withTile: "b")
            }
        )
        var tapped: [TileGridItem] = []
        host.host.grid.onTap = { tapped.append($0) }
        let folder = try XCTUnwrap(host.folders.first)
        let tile = try XCTUnwrap(folder.tiles.first)

        host.coordinator.beginEditing()
        defer { host.coordinator.endEditing() }

        XCTAssertFalse(host.coordinator.activateTileFromFolder(tile))
        XCTAssertTrue(tapped.isEmpty, "В edit-режиме действие не активируется")
    }

    // MARK: - E9.5: центр без удержания = no-op

    /// Drop на центр ярлыка без удержания возвращает ярлык на исходное место,
    /// даже если до этого палец побывал в зоне перестановки (E9.5).
    func testDropOnTileCenterWithoutHoldReturnsToOriginalPlace() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let baseIDs = host.storeIDs
        // E11.7: центр «b» берём по базовой раскладке — после превью «b» нарисована
        // на слоте «a», а зона решается по базовой рамке.
        let baseCenterOfB = try XCTUnwrap(host.point("b", fx: 0.5, fy: 0.5))

        XCTAssertTrue(host.startDrag("a"))
        // Сначала — над краем c: превью размещения (a на ячейке c, c вниз).
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("c", fx: 0.1, fy: 0.5)))
        host.host.layout()
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(try cell("c", in: host)))

        // Затем — центр b: зона E8.6, удержание не выдержано.
        host.coordinator.updateDrag(to: baseCenterOfB)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group(AnyHashable("b")))
        host.coordinator.finishDrag(commit: true)

        XCTAssertEqual(host.storeIDs, baseIDs, "Модель не изменилась")
        XCTAssertTrue(recorder.moves.isEmpty)
        XCTAssertTrue(recorder.createdFolders.isEmpty)
        XCTAssertTrue(
            host.waitUntil { host.host.grid.snapshot?.placementTable == host.store.snapshot(columns: 4).placementTable },
            "Превью размещения снято, ячейки вернулись к модельным"
        )
        XCTAssertEqual(host.gridIDs, baseIDs)
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }

    // MARK: - M1: отложенное превью во время закрытия панели

    /// Готовит drag поверх идущего анимированного закрытия панели папки (M1).
    ///
    /// Публичный `beginEditing()` закрывает панель анимированно; пока переход
    /// идёт, сетка откладывает превью (`pendingSnapshot`) и не применяет его.
    /// Long-press по плитке в этот момент стартует drag по «сдвинутой» раскладке.
    ///
    /// - Parameter host: Стенд с закрытой панелью.
    /// - Returns: Идентификатор папки-цели.
    private func startDragDuringAnimatedFolderClose(
        _ host: TesseraTestDragHost
    ) throws -> AnyHashable {
        let folderID = try XCTUnwrap(host.firstFolderID)
        let folder = try XCTUnwrap(host.folders.first)
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()

        host.coordinator.beginEditing()
        XCTAssertTrue(
            host.host.grid.isFolderChangeAnimating,
            "Анимированное закрытие панели стартовало"
        )
        XCTAssertNotNil(host.host.grid.expandedFolderID)

        let item = try XCTUnwrap(host.host.grid.items.first { $0.id == AnyHashable("a") })
        host.coordinator.handleLongPress(on: item, at: try XCTUnwrap(host.point("a")))
        XCTAssertTrue(host.coordinator.isDragging)
        XCTAssertTrue(
            host.host.grid.isFolderChangeAnimating,
            "Переход панели ещё идёт — следующие превью сетка отложит"
        )

        // Превью размещения: палец на краю папки (панель ещё раскрыта — цель
        // ищется по рамкам сетки, ячейка берётся из базовых размещений).
        host.coordinator.updateDrag(
            to: try XCTUnwrap(host.point(folderID, fx: 0.1, fy: 0.5))
        )
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(try cell(folderID, in: host))
        )
        return folderID
    }

    /// Отмена drag во время анимированного закрытия панели не оставляет
    /// отложенное превью: после перехода сетка равна модели (M1).
    func testCancelDuringAnimatedFolderCloseReplacesDeferredPreview() throws {
        let host = makeFolderHost(
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        _ = try startDragDuringAnimatedFolderClose(host)

        host.coordinator.finishDrag(commit: false)
        XCTAssertFalse(host.coordinator.isDragging)
        XCTAssertTrue(host.host.waitForFolderTransition())
        XCTAssertEqual(
            host.host.grid.items.map { $0.id },
            host.storeIDs,
            "После перехода сетка не показывает устаревшее превью"
        )
        XCTAssertNil(host.host.grid.expandedFolderID)
    }

    /// No-op drop в центр папки (без удержания) во время закрытия панели тоже
    /// заменяет отложенное превью снимком модели (M1, E9.5).
    func testNoOpCenterDuringAnimatedFolderCloseReplacesDeferredPreview() throws {
        let host = makeFolderHost(
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let folderID = try startDragDuringAnimatedFolderClose(host)

        host.coordinator.updateDrag(
            to: try XCTUnwrap(host.point(folderID, fx: 0.5, fy: 0.5))
        )
        XCTAssertEqual(host.coordinator.dragSession?.hover, .folder(folderID))

        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.host.waitForFolderTransition())
        XCTAssertEqual(host.gridIDs, host.storeIDs)
        XCTAssertEqual(host.storeIDs, [AnyHashable("a"), folderID], "No-op: модель не менялась")
    }

    /// `endEditing()` во время закрытия панели не оставляет сетку с превью
    /// после завершения перехода (M1).
    func testEndEditingDuringAnimatedFolderCloseReplacesDeferredPreview() throws {
        let host = makeFolderHost(
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        _ = try startDragDuringAnimatedFolderClose(host)

        host.coordinator.endEditing()
        XCTAssertFalse(host.coordinator.isEditing)
        XCTAssertTrue(host.host.waitForFolderTransition())
        XCTAssertEqual(host.host.grid.items.map { $0.id }, host.storeIDs)
    }

    /// m3: long-press при открытой панели закрывает её мгновенно, drag стартует
    /// по штатной раскладке, а drop после этого синхронизирует сетку и модель.
    func testLongPressClosesExpandedFolderInstantlyAndDropStaysConsistent() throws {
        let host = makeFolderHost()
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let folderID = try XCTUnwrap(host.firstFolderID)
        let folder = try XCTUnwrap(host.folders.first)

        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)

        let item = try XCTUnwrap(host.host.grid.items.first { $0.id == AnyHashable("a") })
        host.coordinator.handleLongPress(on: item, at: try XCTUnwrap(host.point("a")))

        XCTAssertNil(host.host.grid.expandedFolderID, "Панель закрыта мгновенно")
        XCTAssertFalse(host.host.grid.isFolderChangeAnimating)
        XCTAssertTrue(host.coordinator.isDragging)

        host.host.layout()
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(folderID, fx: 0.1, fy: 0.5)))
        host.coordinator.finishDrag(commit: true)

        XCTAssertTrue(host.waitUntil { recorder.moves.count == 1 })
        XCTAssertEqual(host.storeIDs, [AnyHashable("a"), folderID], "«a» на ячейке папки, папка ниже")
        XCTAssertEqual(host.gridIDs, host.storeIDs)
    }

    // MARK: - m1: синхронный onChange хоста

    /// Публичный `move` считает изменение порядка ДО мутации: если хост
    /// синхронно применяет `store.onChange` к сетке, `didMove` и `.layoutChanged`
    /// всё равно приходят, а метод возвращает `true` (m1).
    func testPublicMoveWithSynchronousStoreOnChangeReportsMove() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .small),
            ]
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        var posts: [(UIAccessibility.Notification, Any?)] = []
        host.coordinator.accessibilityNotificationPoster = { notification, argument in
            posts.append((notification, argument))
        }
        // Хост как в Example: снимок store применяется к сетке синхронно.
        // Захватывается только сетка (не host/store) — цикла «store → onChange →
        // host → store» нет.
        let grid = host.host.grid
        host.store.onChange = { snapshot in
            grid.update(snapshot: snapshot, animated: false)
        }

        XCTAssertTrue(host.coordinator.move("a", toIndex: 99), "Порядок изменился")
        XCTAssertEqual(recorder.moves.count, 1, "didMove пришёл, несмотря на синхронный onChange")
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("a"))
        XCTAssertEqual(recorder.moves.first?.index, 2, "Фактический индекс")
        XCTAssertEqual(host.gridIDs, host.storeIDs)
        XCTAssertTrue(host.waitUntil { !posts.isEmpty }, ".layoutChanged опубликован")
        XCTAssertEqual(posts.last?.0, UIAccessibility.Notification.layoutChanged)
    }

    // MARK: - m4: экран папки, fallback без координатора

    /// Если координатора/сетки уже нет, экран папки выполняет действие ярлыка
    /// напрямую (fallback m4), а не теряет тап.
    func testFolderScreenFallbackActionWithoutCoordinator() throws {
        var actionCalls = 0
        let folderTile = TileDescriptor(
            id: "in-folder",
            title: "Inside",
            action: { actionCalls += 1 },
            size: .small
        )
        let host = TesseraTestDragHost(
            descriptors: [tesseraTestTile("a", size: .small), folderTile],
            prepare: { store in
                _ = store.createFolder(withTile: "in-folder")
            }
        )
        let folder = try XCTUnwrap(host.folders.first)
        let tile = try XCTUnwrap(folder.tiles.first)

        // Временный координатор живёт только на время инициализации экрана:
        // weak-ссылка в контроллере обнулится.
        var temporaryCoordinator: TesseraTileEditCoordinator? = TesseraTileEditCoordinator(
            grid: host.host.grid,
            store: host.store
        )
        let screen = TesseraFolderViewController(
            folder: folder,
            store: host.store,
            coordinator: try XCTUnwrap(temporaryCoordinator)
        )
        temporaryCoordinator = nil

        screen.performActivation(tile)
        XCTAssertEqual(actionCalls, 1, "Fallback выполнил действие ярлыка")
    }

    // MARK: - n11: границы центральной зоны

    /// Границы центральной зоны drop: 25%/75% полуоткрыты — левая/верхняя
    /// границы включительно, правая/нижняя — нет (E8.6/E10.5-A1).
    func testDropCenterZoneBoundariesAreHalfOpen() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        XCTAssertTrue(host.startDrag("a"))
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "b"))
        let central = frame.insetBy(dx: frame.width * 0.25, dy: frame.height * 0.25)

        // Левая и верхняя границы включительны.
        host.coordinator.updateDrag(to: CGPoint(x: central.minX, y: central.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group(AnyHashable("b")))
        host.coordinator.updateDrag(to: CGPoint(x: central.midX, y: central.minY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group(AnyHashable("b")))

        // Правая граница — уже вне центральной зоны (это же включает
        // превью размещения, поэтому нижнюю границу пересчитываем по новой рамке).
        host.coordinator.updateDrag(to: CGPoint(x: central.maxX, y: central.midY))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(try cell("b", in: host))
        )
        // E11.7: зона решается по БАЗОВОЙ рамке «b» (она не сдвигается вместе с
        // превью), поэтому нижняя граница считается от той же `frame`/`central`.
        host.coordinator.updateDrag(to: CGPoint(x: central.midX, y: central.maxY))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(try cell("b", in: host))
        )
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }

    // MARK: - n11: магнит в RTL и при Reduce Motion

    /// В RTL магнит считает центры слотов той же геометрией и притягивает снимок
    /// к центру слота (E8.9/E10.5-A2): зеркалится раскладка, а не расчёт.
    func testMagnetUsesSlotCentersInRTL() throws {
        let host = TesseraTestDragHost(
            descriptors: (0..<8).map { tesseraTestTile("s\($0)", size: .small) },
            configuration: TesseraTileEditConfiguration(
                magnetSnapRadius: 40,
                magnetSpringDuration: 0
            )
        )
        // Направление задаём коллекции напрямую: раскладка читает её
        // `effectiveUserInterfaceLayoutDirection`.
        host.host.collectionView?.semanticContentAttribute = .forceRightToLeft
        host.host.grid.semanticContentAttribute = .forceRightToLeft
        host.host.grid.invalidateTileLayout(animated: false)
        host.host.layout()

        // Колонки действительно зеркалятся: s0 — правее s3.
        let firstFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "s0"))
        let thirdFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "s3"))
        XCTAssertGreaterThan(
            firstFrame.minX,
            thirdFrame.minX,
            "RTL зеркалит колонки раскладки"
        )

        XCTAssertTrue(host.startDrag("s0", fx: 0.9, fy: 0.9))
        let session = try XCTUnwrap(host.coordinator.dragSession)
        session.hasLeftOriginSlot = true
        // E14.5: притяжение — к рамке ячейки-цели. Последний центр списка
        // (правый нижний на экране) в RTL — логическая клетка (1, 0): колонка 0
        // — начало чтения, то есть правый край.
        session.hover = .cell(TileGridPlacement(row: 1, column: 0))

        let centers = host.host.grid.magnetSlotCenters(for: .small)
        XCTAssertEqual(centers.count, 8, "Две строки по четыре small-слота")
        let target = try XCTUnwrap(centers.last)
        let point = CGPoint(
            x: target.x - session.grabOffset.x,
            y: target.y - session.grabOffset.y
        )
        XCTAssertEqual(
            host.coordinator.dragMagnetTargetForTesting(at: point),
            target,
            "Центр снимка на слоте — притяжение к нему в RTL"
        )
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitForDragCleanup("s0"))
    }

    /// При Reduce Motion магнит отключён целиком (E8.9).
    func testMagnetDisabledByReduceMotion() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ]
        )
        host.coordinator.isReduceMotionEnabled = { true }
        host.host.grid.isReduceMotionEnabled = { true }
        XCTAssertTrue(host.startDrag("a", fx: 0.9, fy: 0.9))
        let session = try XCTUnwrap(host.coordinator.dragSession)
        session.hasLeftOriginSlot = true
        session.hover = .none

        let centers = host.host.grid.magnetSlotCenters(for: .small)
        let target = try XCTUnwrap(centers.last)
        let point = CGPoint(
            x: target.x - session.grabOffset.x,
            y: target.y - session.grabOffset.y
        )
        XCTAssertNil(
            host.coordinator.dragMagnetTargetForTesting(at: point),
            "Reduce Motion отключает притяжение"
        )
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }

    // MARK: - n11: .layoutChanged после папочных операций

    /// После создания папки публикуется `.layoutChanged` с фокусом на её ячейке
    /// (E10.5-B6).
    func testLayoutChangedPostedAfterFolderCreation() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("A", size: .medium),
                tesseraTestTile("W", size: .wide),
                tesseraTestTile("S", size: .small),
            ]
        )
        var posts: [(UIAccessibility.Notification, Any?)] = []
        host.coordinator.accessibilityNotificationPoster = { notification, argument in
            posts.append((notification, argument))
        }

        let folder = try XCTUnwrap(host.coordinator.createFolder(withTile: "S"))
        host.host.layout()
        XCTAssertTrue(host.waitUntil { !posts.isEmpty })
        XCTAssertEqual(posts.last?.0, UIAccessibility.Notification.layoutChanged)
        XCTAssertTrue(
            (posts.last?.1 as? UIView) === host.host.cell(folder.id),
            "Фокус на ячейке созданной папки"
        )
    }
    /// Drop «на место» (хост отпустил плитку, порядок не изменился) во время
    /// закрытия панели: default-ветка `finishDrag` синхронизирует сетку с
    /// моделью, отложенное превью не применяется после перехода (M1).
    func testDropInPlaceDuringAnimatedFolderCloseReplacesDeferredPreview() throws {
        let host = makeFolderHost(
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        _ = try startDragDuringAnimatedFolderClose(host)

        // Уводим палец в пустое место: цель `.none`, drop — фиксация индекса
        // «на месте» (default-ветка finishDrag).
        host.coordinator.updateDrag(to: CGPoint(x: 10, y: 700))
        XCTAssertEqual(host.coordinator.dragSession?.hover, HoverTarget.none)
        host.coordinator.finishDrag(commit: true)

        XCTAssertTrue(host.host.waitForFolderTransition())
        XCTAssertEqual(host.host.grid.items.map { $0.id }, host.storeIDs)
        XCTAssertEqual(host.storeIDs, [AnyHashable("a"), try XCTUnwrap(host.firstFolderID)])
    }

    /// Уход приложения в фон во время закрытия панели отменяет drag и тоже не
    /// оставляет отложенное превью (M1, фон — путь cancelDragImmediately).
    func testBackgroundDuringAnimatedFolderCloseReplacesDeferredPreview() throws {
        let host = makeFolderHost(
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        _ = try startDragDuringAnimatedFolderClose(host)

        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        XCTAssertFalse(host.coordinator.isDragging)
        XCTAssertTrue(host.host.waitForFolderTransition())
        XCTAssertEqual(host.host.grid.items.map { $0.id }, host.storeIDs)
    }

    // MARK: - m7: drop над панелью раскрытой папки — no-op

    /// Drop над панелью раскрытой папки не фиксирует последнее push-превью:
    /// хост открывает панель во время drag, отпускание возвращает ярлык на
    /// исходное место (m7, E9.5-семантика; STARTSCREEN §30).
    func testDropOverExpandedFolderPanelIsNoOp() throws {
        let host = makeFolderHost(
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let folderID = try XCTUnwrap(host.firstFolderID)
        let folder = try XCTUnwrap(host.folders.first)

        XCTAssertTrue(host.startDrag("a"))
        // Превью размещения: ярлык встаёт на ячейку папки, папка уходит вниз.
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(folderID, fx: 0.1, fy: 0.5)))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(try cell(folderID, in: host))
        )
        let modelTable = host.store.snapshot(columns: 4).placementTable
        XCTAssertNotEqual(host.host.grid.snapshot?.placementTable, modelTable, "Превью отличается от модели")

        // Хост открывает панель уже во время drag (long-press её бы закрыл).
        host.host.grid.openFolder(folder, animated: true)
        XCTAssertTrue(host.host.waitForFolderTransition())
        host.host.layout()
        let panelCell = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        let panelPoint = panelCell.convert(
            CGPoint(x: panelCell.bounds.midX, y: panelCell.bounds.midY),
            to: host.host.grid
        )

        host.coordinator.updateDrag(to: panelPoint)
        XCTAssertTrue(
            host.coordinator.dragSession?.isOverFolderPanel == true,
            "Признак «над панелью» выставлен"
        )
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            HoverTarget.none,
            "Панель — не цель drop"
        )
        XCTAssertEqual(
            host.host.grid.snapshot?.placementTable,
            modelTable,
            "Над панелью превью возвращается к базовой раскладке (E14.5): фиксировать нечего"
        )

        host.coordinator.finishDrag(commit: true)

        XCTAssertTrue(host.waitUntil { host.host.grid.snapshot?.placementTable == modelTable })
        XCTAssertEqual(
            host.storeIDs,
            [AnyHashable("a"), folderID],
            "Store не изменился: drop над панелью — no-op"
        )
        XCTAssertTrue(recorder.moves.isEmpty, "didMove не пришёл")
        XCTAssertTrue(recorder.createdFolders.isEmpty)
        XCTAssertTrue(host.waitForDragCleanup("a"))
        XCTAssertEqual(
            host.host.grid.expandedFolderID,
            folderID,
            "Панель остаётся раскрытой — drop её не закрывает"
        )
    }

    /// Панель, открытая хостом уже **под пальцем** (без шага drag после
    /// открытия), тоже даёт no-op при отпускании: признак проверяется и по
    /// последней точке, а не только по последнему `updateDrag` (m7).
    func testDropOverPanelOpenedUnderFingerIsNoOp() throws {
        let host = makeFolderHost(
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let folderID = try XCTUnwrap(host.firstFolderID)
        let folder = try XCTUnwrap(host.folders.first)

        // Запоминаем координаты центра панели в той же раскладке, затем
        // закрываем её: во время drag панель откроется там же.
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        let panelCell = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        let panelPoint = panelCell.convert(
            CGPoint(x: panelCell.bounds.midX, y: panelCell.bounds.midY),
            to: host.host.grid
        )
        host.host.grid.closeFolder(animated: false)
        host.host.layout()

        XCTAssertTrue(host.startDrag("a"))
        // Превью размещения, затем палец — в пустое место, где появится панель.
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(folderID, fx: 0.1, fy: 0.5)))
        host.coordinator.updateDrag(to: panelPoint)
        // E14.5: ниже последней занятой строки цель — «новая строка»; панели под
        // пальцем пока нет.
        XCTAssertEqual(host.coordinator.dragSession?.hover, HoverTarget.newRow)
        XCTAssertFalse(host.coordinator.dragSession?.isOverFolderPanel == true)

        // Панель появляется под пальцем без нового шага drag.
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)

        host.coordinator.finishDrag(commit: true)

        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertEqual(host.storeIDs, [AnyHashable("a"), folderID])
        XCTAssertTrue(recorder.moves.isEmpty, "didMove не пришёл")
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }


    // MARK: - E11.1: drag ярлыка из панели папки

    /// Делегат, реализующий только новый колбэк с индексом (E11.1): прежний
    /// `didMove(toFolder:)` при этом не вызывается (ровно один из двух).
    private final class IndexedMoveRecorder: TesseraTileEditCoordinatorDelegate {

        /// События `didMove(toFolder:atIndex:)`.
        var moves: [(id: AnyHashable, folder: AnyHashable?, index: Int?)] = []

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toFolder folderID: AnyHashable?,
            atIndex index: Int?
        ) {
            moves.append((tileID, folderID, index))
        }
    }

    /// Стенд E11.1: порядок сетки — «a», папка F1 («b», «c»), «d», папка F2 («e»).
    private func makePanelHost(
        configuration: TesseraTileEditConfiguration = TesseraTileEditConfiguration(
            mergeHoverDuration: 0.05,
            magnetSnapRadius: 0
        )
    ) -> TesseraTestDragHost {
        TesseraTestDragHost(
            descriptors: ["a", "b", "c", "d", "e"].map { tesseraTestTile($0, size: .small) },
            configuration: configuration,
            prepare: { store in
                // E12.2: папки создаются medium; геометрия этих тестов рассчитана
                // на малые плитки-папки, поэтому возвращаем им small.
                if let folder = store.createFolder(withTile: "b") {
                    _ = store.addToFolder("c", folderID: folder.id)
                    _ = store.resize(folder.id, to: .small)
                }
                if let folder = store.createFolder(withTile: "e") {
                    _ = store.resize(folder.id, to: .small)
                }
            }
        )
    }

    /// Идентификаторы папок стенда E11.1 по порядку: (F1, F2).
    private func panelHostFolderIDs(_ host: TesseraTestDragHost) throws -> (AnyHashable, AnyHashable) {
        let folders = host.folders
        XCTAssertEqual(folders.count, 2)
        return (try XCTUnwrap(folders.first).id, try XCTUnwrap(folders.last).id)
    }

    /// Входит в edit, раскрывает панель папки и начинает drag иконки панели.
    ///
    /// - Returns: Точка захвата в координатах сетки.
    @discardableResult
    private func startPanelDrag(
        _ host: TesseraTestDragHost,
        folderID: AnyHashable,
        iconIndex: Int,
        grab: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) throws -> CGPoint {
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == folderID })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        let panelItem = try XCTUnwrap(host.host.grid.displayItems.first { $0.isFolderPanel })
        let panel = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        let icon = try XCTUnwrap(panel.shortcutCells[iconIndex] as TesseraTileCell?)
        // `grab` — доля рамки иконки (E12.3: хват за центр и за края).
        let iconFrame = try XCTUnwrap(icon.superview).convert(icon.frame, to: host.host.grid)
        let point = CGPoint(
            x: iconFrame.minX + iconFrame.width * grab.x,
            y: iconFrame.minY + iconFrame.height * grab.y
        )

        host.coordinator.handleLongPress(on: panelItem, at: point)
        return point
    }

    /// Точка в пустой области сетки (правый нижний угол, под всеми плитками).
    private func emptyPoint(in host: TesseraTestDragHost) -> CGPoint {
        let bounds = host.host.grid.bounds
        return CGPoint(x: bounds.maxX - 3, y: bounds.maxY - 3)
    }

    /// Долгое нажатие по иконке панели в edit: панель закрывается мгновенно,
    /// стартует drag с источником-папкой; модель за время drag не меняется,
    /// сетка показывает отображаемый снимок с ярлыком после папки.
    func testLongPressOnPanelIconStartsDragFromFolder() throws {
        let host = makePanelHost()
        let (f1, _) = try panelHostFolderIDs(host)
        let before = host.storeIDs

        try startPanelDrag(host, folderID: f1, iconIndex: 1)

        XCTAssertTrue(host.coordinator.isDragging)
        let session = try XCTUnwrap(host.coordinator.dragSession)
        XCTAssertEqual(session.sourceFolderID, f1)
        XCTAssertEqual(session.itemID, AnyHashable("c"))
        XCTAssertNil(host.host.grid.expandedFolderID, "Панель закрыта мгновенно")
        XCTAssertFalse(host.host.grid.isFolderChangeAnimating)
        XCTAssertEqual(host.storeIDs, before, "Модель не меняется во время drag")
        XCTAssertEqual(
            host.gridIDs,
            ["a", f1, "c", "d", host.folders[1].id] as [AnyHashable],
            "Синтетический ярлык лежит сразу после папки"
        )
        XCTAssertEqual(
            host.folders.first?.tiles.map { $0.id },
            ["b", "c"] as [AnyHashable],
            "Состав папки в модели прежний"
        )
        host.coordinator.endEditing()
        XCTAssertEqual(host.gridIDs, before, "Отмена возвращает сетке порядок модели")
    }

    /// Вынос на сетку: ярлык встаёт на ячейку превью, делегат получает
    /// `didMove(toFolder: nil, atIndex:)`, прежний колбэк не вызывается.
    func testDropOutOfFolderLandsAtPreviewIndex() throws {
        let host = makePanelHost()
        let recorder = IndexedMoveRecorder()
        host.coordinator.delegate = recorder
        let (f1, _) = try panelHostFolderIDs(host)
        let aFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "a"))
        let aCell = try cell("a", in: host)

        try startPanelDrag(host, folderID: f1, iconIndex: 1)
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("a", fx: 0.1, fy: 0.5)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(aCell))
        XCTAssertEqual(
            host.host.grid.frame(forItemID: "c"),
            aFrame,
            "Превью: ярлык на месте цели"
        )

        host.coordinator.finishDrag(commit: true)

        XCTAssertEqual(recorder.moves.count, 1)
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("c"))
        XCTAssertNil(recorder.moves.first?.folder ?? nil)
        XCTAssertEqual(recorder.moves.first?.index, 0)
        XCTAssertEqual(host.storeIDs.first, AnyHashable("c"))
        XCTAssertEqual(host.store.placement(of: "c"), aCell)
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["b"] as [AnyHashable])
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertTrue(host.waitForDragCleanup("c"))
        XCTAssertNil(host.coordinator.dragSession)
        // Кадр, в который летит снимок, — рамка вынесенной плитки после render.
        XCTAssertNotNil(host.host.grid.frame(forItemID: "c"))
    }

    /// Вынос последнего ярлыка: папка исчезает (её ячейка остаётся дырой), а
    /// индекс учитывает, что папка исчезла из итогового порядка.
    func testDropOfLastTileDissolvesFolderAndAdjustsIndex() throws {
        let host = makePanelHost()
        let recorder = IndexedMoveRecorder()
        host.coordinator.delegate = recorder
        let (_, f2) = try panelHostFolderIDs(host)

        try startPanelDrag(host, folderID: f2, iconIndex: 0)
        XCTAssertEqual(host.coordinator.dragSession?.sourceFolderID, f2)
        // Пустое место под плитками (E14.5): цель — «новая строка».
        host.coordinator.updateDrag(to: emptyPoint(in: host))
        XCTAssertEqual(host.coordinator.dragSession?.hover, HoverTarget.newRow)

        host.coordinator.finishDrag(commit: true)

        XCTAssertFalse(host.storeIDs.contains(f2), "Папка из одного ярлыка исчезла")
        XCTAssertEqual(host.storeIDs.last, AnyHashable("e"), "Ярлык — в новой строке")
        XCTAssertEqual(host.store.placement(of: "e")?.column, 0)
        XCTAssertEqual(recorder.moves.first?.index, host.storeIDs.count - 1)
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertTrue(host.waitForDragCleanup("e"))
    }

    /// Перенос в другую папку: центр папки-цели с выдержанным удержанием.
    /// Работает и прежний колбэк (делегат, не знающий про индекс).
    func testDropOnOtherFolderCenterAfterHoldMovesTile() throws {
        let host = makePanelHost()
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let (f1, f2) = try panelHostFolderIDs(host)

        try startPanelDrag(host, folderID: f1, iconIndex: 1)
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(f2, fx: 0.5, fy: 0.5)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .folder(f2))
        XCTAssertTrue(
            host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
            "Удержание над центром чужой папки выдержано"
        )

        host.coordinator.finishDrag(commit: true)

        XCTAssertEqual(recorder.folderMoves.count, 1, "Прежний колбэк получил событие")
        XCTAssertEqual(recorder.folderMoves.first?.id, AnyHashable("c"))
        XCTAssertEqual(recorder.folderMoves.first?.folder, f2)
        XCTAssertEqual(host.folders.first { $0.id == f1 }?.tiles.map { $0.id }, ["b"] as [AnyHashable])
        XCTAssertEqual(host.folders.first { $0.id == f2 }?.tiles.map { $0.id }, ["e", "c"] as [AnyHashable])
        let target = try XCTUnwrap(host.coordinator.lastCollapseTargetFrame)
        XCTAssertEqual(target, host.host.grid.frame(forItemID: f2), "Полёт — в рамку папки-цели")
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
    }

    /// Без удержания drop на центр другой папки — no-op: модель не тронута,
    /// колбэков нет, сетка возвращается к порядку модели.
    func testDropOnOtherFolderCenterWithoutHoldIsNoOp() throws {
        let host = makePanelHost(
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let (f1, f2) = try panelHostFolderIDs(host)
        let before = host.storeIDs

        try startPanelDrag(host, folderID: f1, iconIndex: 1)
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(f2, fx: 0.5, fy: 0.5)))
        XCTAssertEqual(host.coordinator.mergeTracker?.isMergeReady, false)
        host.coordinator.finishDrag(commit: true)

        XCTAssertEqual(host.storeIDs, before)
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["b", "c"] as [AnyHashable])
        XCTAssertTrue(recorder.folderMoves.isEmpty)
        XCTAssertTrue(recorder.failures.isEmpty)
        XCTAssertTrue(host.waitUntil { host.gridIDs == before })
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
    }

    /// Центр родной папки (даже с выдержанным удержанием) и отмена жеста
    /// возвращают ярлык: модель и делегат не затронуты.
    func testDropOnSourceFolderCenterAndCancelLeaveModelUntouched() throws {
        let host = makePanelHost()
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let (f1, _) = try panelHostFolderIDs(host)
        let before = host.storeIDs

        // Центр родной папки.
        try startPanelDrag(host, folderID: f1, iconIndex: 1)
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(f1, fx: 0.5, fy: 0.5)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .sourceFolder)
        host.spin(0.12)
        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        XCTAssertTrue(host.waitUntil { host.gridIDs == before })
        XCTAssertEqual(host.storeIDs, before)
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["b", "c"] as [AnyHashable])

        // Отмена после превью.
        try startPanelDrag(host, folderID: f1, iconIndex: 0)
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("a", fx: 0.1, fy: 0.5)))
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        XCTAssertTrue(host.waitUntil { host.gridIDs == before })
        XCTAssertEqual(host.storeIDs, before)
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["b", "c"] as [AnyHashable])

        XCTAssertTrue(recorder.folderMoves.isEmpty)
        XCTAssertTrue(recorder.createdFolders.isEmpty)
        XCTAssertTrue(recorder.moves.isEmpty)
    }

    /// Центр обычного ярлыка для ярлыка из папки не создаёт папку: работает
    /// как размещение на его ячейку (вынос на сетку).
    func testCenterOfPlainTileDoesNotCreateFolderForFolderSource() throws {
        let host = makePanelHost()
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let (f1, _) = try panelHostFolderIDs(host)

        try startPanelDrag(host, folderID: f1, iconIndex: 1)
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("a", fx: 0.5, fy: 0.5)))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(try cell("a", in: host)),
            "Центр ярлыка — размещение на его ячейку, а не группировка"
        )
        host.spin(0.12)
        host.coordinator.finishDrag(commit: true)

        XCTAssertTrue(recorder.createdFolders.isEmpty)
        XCTAssertEqual(recorder.folderMoves.count, 1)
        XCTAssertEqual(host.folders.count, 2)
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
    }

    /// Долгое нажатие по заголовку/фону панели в edit drag не начинает.
    func testLongPressOnPanelBackgroundDoesNotStartDrag() throws {
        let host = makePanelHost()
        let (f1, _) = try panelHostFolderIDs(host)
        host.coordinator.beginEditing()
        host.host.grid.openFolder(try XCTUnwrap(host.folders.first), animated: false)
        host.host.layout()
        let panelItem = try XCTUnwrap(host.host.grid.displayItems.first { $0.isFolderPanel })
        let panel = try XCTUnwrap(host.host.panelCell(folderID: f1))
        let point = panel.convert(CGPoint(x: panel.bounds.midX, y: 8), to: host.host.grid)

        host.coordinator.handleLongPress(on: panelItem, at: point)

        XCTAssertFalse(host.coordinator.isDragging)
        XCTAssertEqual(host.host.grid.expandedFolderID, f1, "Панель осталась раскрытой")
        host.coordinator.endEditing()
    }

    /// Тап по папке в режиме редактирования открывает нативную панель, режим
    /// редактирования не прерывается, `onTap` приходит.
    func testTapOnFolderInEditModeOpensPanelWithoutLeavingEdit() throws {
        let host = makePanelHost()
        let (f1, _) = try panelHostFolderIDs(host)
        var tapped: [AnyHashable] = []
        host.host.grid.onTap = { tapped.append($0.id) }
        host.coordinator.beginEditing()

        let collectionView = try XCTUnwrap(host.host.collectionView)
        let index = try XCTUnwrap(host.host.grid.displayItems.firstIndex { $0.id == f1 })
        host.host.grid.collectionView(collectionView, didSelectItemAt: IndexPath(item: index, section: 0))

        XCTAssertEqual(host.host.grid.expandedFolderID, f1)
        XCTAssertTrue(host.coordinator.isEditing)
        XCTAssertEqual(tapped, [f1])
        host.coordinator.endEditing()
    }

    /// Перехватчик `folderTapHandler` в edit работает как вне его: `true`
    /// отменяет раскрытие и `onTap`.
    func testFolderTapHandlerInterceptsInEditMode() throws {
        let host = makePanelHost()
        let (f1, _) = try panelHostFolderIDs(host)
        var tapped = 0
        var intercepted = 0
        host.host.grid.onTap = { _ in tapped += 1 }
        host.host.grid.folderTapHandler = { _ in
            intercepted += 1
            return true
        }
        host.coordinator.beginEditing()

        let collectionView = try XCTUnwrap(host.host.collectionView)
        let index = try XCTUnwrap(host.host.grid.displayItems.firstIndex { $0.id == f1 })
        host.host.grid.collectionView(collectionView, didSelectItemAt: IndexPath(item: index, section: 0))

        XCTAssertEqual(intercepted, 1)
        XCTAssertEqual(tapped, 0)
        XCTAssertNil(host.host.grid.expandedFolderID)
        host.coordinator.endEditing()
    }


    // MARK: - E11.6: атомарное создание папки

    /// Drop на центр ярлыка с выдержанным удержанием.
    private func dropOnCenterAfterHold(_ host: TesseraTestDragHost, dragged: AnyHashable, target: AnyHashable) throws {
        XCTAssertTrue(host.startDrag(dragged))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(target, fx: 0.5, fy: 0.5)))
        XCTAssertTrue(
            host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
            "Удержание над центром ярлыка выдержано"
        )
        host.coordinator.finishDrag(commit: true)
    }

    /// Отказ второго шага (`addToFolder`) откатывает создание папки: модель и
    /// сетка как до drop'а, делегат получает только `didFailGrouping`
    /// (без `didCreateFolder`/`didAdd`), хост не получает `onChange` ни для
    /// промежуточного состояния, ни для отката.
    func testDeniedSecondStepRollsBackFolderCreation() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("x", size: .small),
                tesseraTestTile("b", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(
                mergeHoverDuration: 0.05,
                magnetSnapRadius: 0
            )
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        host.store.approval = { _, _, action in action != .addToFolder }
        let before = host.storeIDs
        var changeCount = 0
        host.store.onChange = { _ in changeCount += 1 }

        try dropOnCenterAfterHold(host, dragged: "a", target: "b")

        XCTAssertTrue(host.waitUntil { recorder.failures.count == 1 })
        XCTAssertEqual(recorder.failures, [.addToFolder])
        XCTAssertTrue(recorder.createdFolders.isEmpty, "didCreateFolder не отправляется")
        XCTAssertTrue(recorder.additions.isEmpty)
        XCTAssertEqual(host.storeIDs, before, "Порядок модели прежний")
        XCTAssertTrue(host.folders.isEmpty, "Записи папки нет")
        XCTAssertEqual(host.store.snapshot().items.map { $0.id }, before)
        XCTAssertEqual(changeCount, 0, "Ни промежуточного состояния, ни отката")
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        XCTAssertEqual(host.gridIDs, before, "Сетка как до drop'а")
    }

    /// Откат возвращает целевой ярлык на его место и сохраняет его размер.
    func testRollbackKeepsTargetSizeAndPosition() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .wide),
            ],
            configuration: TesseraTileEditConfiguration(
                mergeHoverDuration: 0.05,
                magnetSnapRadius: 0
            )
        )
        host.store.approval = { _, _, action in action != .addToFolder }
        let before = host.store.snapshot()

        let result = host.store.createFolder(withTile: "b", adding: "a")
        guard case .addDenied = result else {
            return XCTFail("Ожидался откат второго шага, получено \(result)")
        }
        let after = host.store.snapshot()
        XCTAssertEqual(after.items.map { $0.id }, before.items.map { $0.id })
        XCTAssertEqual(after.items.last?.tile?.size, .wide)
        XCTAssertTrue(after.folders.isEmpty)
        // Хранилище остаётся рабочим: повторное создание после снятия запрета.
        host.store.approval = { _, _, _ in true }
        guard case .created(let folder) = host.store.createFolder(withTile: "b", adding: "a") else {
            return XCTFail("Повторное создание должно пройти")
        }
        XCTAssertEqual(folder.tiles.map { $0.id }, ["b", "a"] as [AnyHashable])
    }

    /// Отказ первого шага: делегат получает `didFailGrouping(.createFolder)`,
    /// модель нетронута.
    func testDeniedFirstStepLeavesModelUntouched() throws {
        let host = TesseraTestDragHost(
            descriptors: [tesseraTestTile("a", size: .small), tesseraTestTile("b", size: .small)],
            configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.05, magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        host.store.approval = { _, _, action in action != .createFolder }
        let before = host.storeIDs

        try dropOnCenterAfterHold(host, dragged: "a", target: "b")

        XCTAssertTrue(host.waitUntil { recorder.failures.count == 1 })
        XCTAssertEqual(recorder.failures, [.createFolder])
        XCTAssertTrue(recorder.createdFolders.isEmpty)
        XCTAssertEqual(host.storeIDs, before)
    }

    /// Успех: `didCreateFolder` приходит после обоих шагов и строго перед
    /// `didAdd`; `onChange` хоста срабатывает один раз.
    func testSuccessfulCreationSendsCreateThenAddAfterBothSteps() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.05, magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        var changeCount = 0
        host.store.onChange = { _ in changeCount += 1 }

        try dropOnCenterAfterHold(host, dragged: "a", target: "b")

        XCTAssertTrue(host.waitUntil { recorder.additions.count == 1 })
        XCTAssertEqual(recorder.folderEventLog, ["create", "add"])
        XCTAssertEqual(recorder.createdFolders.first?.tiles.map { $0.id }, ["b", "a"] as [AnyHashable],
                       "К моменту didCreateFolder в папке оба ярлыка")
        XCTAssertTrue(recorder.failures.isEmpty)
        XCTAssertEqual(changeCount, 1, "Одно уведомление за операцию")
        XCTAssertEqual(host.folders.count, 1)
    }

    // MARK: - E12.1: вынос единственного ярлыка в «дыру»

    /// Стенд E12.1 (4 колонки): `s0` (кол. 0), папка «Работа» из одного ярлыка
    /// `mail` (кол. 1), medium `cal` (кол. 2–3), папка B из `m`,`n`,`p` — в
    /// модели ниже слева остаётся дыра под «Работой».
    private func makeMoveOutHost(columns: Int = 4, magnet: CGFloat = 0) -> TesseraTestDragHost {
        let descriptors: [TileDescriptor] = [
            tesseraTestTile("s0", size: .small),
            tesseraTestTile("mail", size: .small),
            tesseraTestTile("cal", size: .medium),
            tesseraTestTile("m", size: .small),
            tesseraTestTile("n", size: .small),
            tesseraTestTile("p", size: .small)
        ]
        return TesseraTestDragHost(
            descriptors: descriptors,
            columns: columns,
            configuration: TesseraTileEditConfiguration(
                mergeHoverDuration: 0.05,
                magnetSnapRadius: magnet
            ),
            prepare: { store in
                _ = store.createFolder(withTile: "mail")
                if let folder = store.createFolder(withTile: "m") {
                    _ = store.addToFolder("n", folderID: folder.id)
                    _ = store.addToFolder("p", folderID: folder.id)
                }
            }
        )
    }

    /// Точка центра ячейки «ряд 1, колонка 1» модельной раскладки (под «Работой»).
    private func moveOutHolePoint(_ host: TesseraTestDragHost, work: AnyHashable) throws -> CGPoint {
        let s0 = try XCTUnwrap(host.host.grid.frame(forItemID: "s0"))
        let workFrame = try XCTUnwrap(host.host.grid.frame(forItemID: work))
        let gap = workFrame.minX - s0.maxX
        return CGPoint(x: workFrame.midX, y: workFrame.midY + workFrame.height + gap)
    }

    /// Проверяет итог выноса: «Работа» распалась, `mail` — обычный ярлык, B цела.
    private func assertMailIsPlainTile(
        _ host: TesseraTestDragHost,
        folderB: AnyHashable,
        work: AnyHashable,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(host.storeIDs.contains(work), "Работа распалась: \(message)", file: file, line: line)
        XCTAssertTrue(host.storeIDs.contains("mail"), "mail — обычный ярлык сетки: \(message)", file: file, line: line)
        XCTAssertEqual(
            host.folders.first { $0.id == folderB }?.tiles.map { $0.id },
            ["m", "n", "p"] as [AnyHashable],
            "Состав папки B не изменился: \(message)",
            file: file,
            line: line
        )
    }

    /// E12.1 (не воспроизведён вручную): вынос единственного ярлыка в «дыру»
    /// модели с удержанием ~0,8 с не кладёт его в соседнюю папку B — ни в 4, ни
    /// в 5/6 колонок. Отображаемый снимок (пустая «Работа» + синтетический
    /// ярлык) пересобирает упаковку: медиум и B уезжают, а точка над «дырой»
    /// модели попадает в плитку, занявшую её в базовой раскладке, — это
    /// перестановка, не слияние.
    func testDropOfSoleFolderTileIntoModelHoleNeverEntersNeighborFolder() throws {
        for columns in [4, 5, 6] {
            let host = makeMoveOutHost(columns: columns)
            let (work, folderB) = try panelHostFolderIDs(host)
            let hole = try moveOutHolePoint(host, work: work)

            try startPanelDrag(host, folderID: work, iconIndex: 0)
            host.coordinator.updateDrag(to: hole)
            host.spin(0.12) // удержание в тесте — 0,05 с
            XCTAssertNotEqual(
                host.coordinator.dragSession?.hover,
                .folder(folderB),
                "cols=\(columns): над дырой модели цель не папка B"
            )
            XCTAssertNotEqual(host.coordinator.mergeTracker?.isMergeReady, true, "cols=\(columns)")
            host.coordinator.finishDrag(commit: true)
            host.spin(0.3)
            assertMailIsPlainTile(host, folderB: folderB, work: work, "cols=\(columns)")
        }
    }

    /// E12.1: удержание, взведённое (и даже выдержанное) над B, не переживает
    /// уход пальца — drop в «дыре» после него не слияние. Покрыты уход на пустое
    /// место, на краевую зону самой B (в пределах её рамки) и на «дыру».
    func testHoldOverNeighborFolderDoesNotSurviveMovingAway() throws {
        for columns in [4, 5, 6] {
            for waitForFire in [false, true] {
                let host = makeMoveOutHost(columns: columns)
                let (work, folderB) = try panelHostFolderIDs(host)
                let hole = try moveOutHolePoint(host, work: work)
                let empty = emptyPoint(in: host)

                try startPanelDrag(host, folderID: work, iconIndex: 0)
                let session = try XCTUnwrap(host.coordinator.dragSession)
                // Центр B в базовой раскладке (она отличается от модельной).
                let content = try XCTUnwrap(host.host.grid.baseContentFrames(for: session.baseSnapshot.items, placementTable: session.baseSnapshot.placementTable))
                let bFrame = host.host.grid.gridFrame(fromContentFrame: try XCTUnwrap(content[folderB]))

                host.coordinator.updateDrag(to: CGPoint(x: bFrame.midX, y: bFrame.midY))
                XCTAssertEqual(session.hover, .folder(folderB), "cols=\(columns): палец над центром B")
                if waitForFire {
                    XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })
                }

                for away in [
                    CGPoint(x: bFrame.minX + 2, y: bFrame.midY), // край самой B
                    hole,
                    empty
                ] {
                    host.coordinator.updateDrag(to: away)
                    XCTAssertNotEqual(session.hover, .folder(folderB), "cols=\(columns) \(away)")
                    XCTAssertNil(host.coordinator.mergeTracker, "Удержание сброшено при уходе: cols=\(columns) \(away)")
                    // Возврат в центр B — новый отсчёт, а не «уже готово».
                    host.coordinator.updateDrag(to: CGPoint(x: bFrame.midX, y: bFrame.midY))
                    XCTAssertEqual(host.coordinator.mergeTracker?.isMergeReady, false, "cols=\(columns) \(away)")
                }

                host.coordinator.updateDrag(to: hole)
                host.coordinator.finishDrag(commit: true)
                host.spin(0.3)
                assertMailIsPlainTile(host, folderB: folderB, work: work, "cols=\(columns) fire=\(waitForFire)")
            }
        }
    }

    // MARK: - E11.7: хит-тест по базовой раскладке

    /// Стенд E11.7: ряд `a b c d` (small) и папка F (small) с ярлыками `f`, `g`
    /// во втором ряду, 4 колонки.
    private func makeBaseHitHost() -> TesseraTestDragHost {
        TesseraTestDragHost(
            descriptors: ["a", "b", "c", "d", "f", "g"].map { tesseraTestTile($0, size: .small) },
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0),
            prepare: { store in
                // E12.2: папка создаётся medium; тесты E11.7 рассчитаны на small.
                if let folder = store.createFolder(withTile: "f") {
                    _ = store.addToFolder("g", folderID: folder.id)
                    _ = store.resize(folder.id, to: .small)
                }
            }
        )
    }

    /// Репро E11.7 / сценарий B E14.5: папка, уехавшая из-под пальца превью
    /// размещения, остаётся целью по базовой рамке — центр достижим при подходе в
    /// сторону сдвига, а превью при этом возвращается к базовой раскладке: цель
    /// остаётся под пальцем, подсветка рисуется на ней.
    func testFolderCenterReachableAfterPreviewShiftedItAway() throws {
        let host = makeBaseHitHost()
        let folderID = try XCTUnwrap(host.firstFolderID)
        let baseCenter = try XCTUnwrap(host.point(folderID, fx: 0.5, fy: 0.5))
        let baseEdge = try XCTUnwrap(host.point(folderID, fx: 0.1, fy: 0.5))
        let baseFrame = try XCTUnwrap(host.host.grid.frame(forItemID: folderID))

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: baseEdge)
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(try cell(folderID, in: host)),
            "Край папки — размещение на её ячейку, превью сдвигает папку"
        )
        XCTAssertTrue(host.waitUntil {
            host.host.grid.frame(forItemID: folderID) != baseFrame
        }, "Папка уехала с базового слота")

        host.coordinator.updateDrag(to: baseCenter)
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .folder(folderID),
            "Центр базовой рамки папки — .folder, а не .none над плейсхолдером"
        )

        // Сценарий B (E14.5): над центром папки превью вернулось к базовой
        // раскладке — папка снова на своём месте под пальцем, подсветка на ней.
        XCTAssertEqual(
            host.host.grid.frame(forItemID: folderID),
            baseFrame,
            "Цель слияния не «убегает» из-под пальца"
        )
        let highlight = try XCTUnwrap(
            host.host.grid.subviews.compactMap { $0 as? TesseraTileDropHighlightView }
                .first { !$0.isHidden }
        )
        XCTAssertEqual(highlight.center.x, baseFrame.midX, accuracy: 0.5)
        XCTAssertEqual(highlight.center.y, baseFrame.midY, accuracy: 0.5)
        XCTAssertEqual(highlight.bounds.size, baseFrame.size)
        XCTAssertTrue(baseFrame.contains(baseCenter), "Палец над подсвеченной целью")

        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }

    /// `.group` срабатывает только внутри центра БАЗОВОЙ рамки цели; на месте,
    /// куда цель уехала после превью (вытолкнута вниз, D31), и над собственной
    /// ячейкой — нет.
    func testGroupFiresOnlyInsideBaseFrameCenter() throws {
        let host = makeBaseHitHost()
        let baseCenter = try XCTUnwrap(host.point("b", fx: 0.5, fy: 0.5))
        let baseEdge = try XCTUnwrap(host.point("b", fx: 0.9, fy: 0.5))
        let ownSlotCenter = try XCTUnwrap(host.point("a", fx: 0.5, fy: 0.5))
        let baseFrameOfB = try XCTUnwrap(host.host.grid.frame(forItemID: "b"))
        let bCell = try cell("b", in: host)

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: baseEdge)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(bCell))
        XCTAssertTrue(host.waitUntil {
            host.host.grid.frame(forItemID: "b").map { $0.minY > baseFrameOfB.minY + 1 } ?? false
        }, "«b» вытолкнута вниз")

        // Центр видимой «b» (она теперь ниже) — в базовой раскладке там пусто:
        // это клетка, а не группа.
        let shiftedCenter = try XCTUnwrap(host.point("b", fx: 0.5, fy: 0.5))
        host.coordinator.updateDrag(to: shiftedCenter)
        XCTAssertNotEqual(host.coordinator.dragSession?.hover, .group("b"), "Не по базовой рамке")

        // Своя базовая ячейка — цели нет, превью — база.
        host.coordinator.updateDrag(to: ownSlotCenter)
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            HoverTarget.none,
            "Над собственной базовой ячейкой — .none"
        )

        // Центр базовой рамки «b» — группа, хотя «b» ещё едет обратно.
        host.coordinator.updateDrag(to: baseCenter)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("b"))

        // Базовый край «b» — по-прежнему размещение на её ячейку.
        host.coordinator.updateDrag(to: baseEdge)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(bCell))

        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }

    /// Автопрокрутка/`contentOffset`: базовые рамки хранятся в координатах
    /// контента, поэтому после прокрутки цель находится по той же плитке.
    func testBaseHitTestFollowsContentOffset() throws {
        let host = TesseraTestDragHost(
            descriptors: (0..<48).map { tesseraTestTile("t\($0)", size: .small) },
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        XCTAssertTrue(host.startDrag("t0"))
        let grid = host.host.grid

        grid.setContentOffset(CGPoint(x: 0, y: 200), animated: false)
        host.host.layout()
        let centerBefore = try XCTUnwrap(host.point("t21", fx: 0.5, fy: 0.5))
        host.coordinator.updateDrag(to: centerBefore)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t21"))

        // Превью сдвигает сетку; затем контент уезжает ещё на 100 pt.
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("t21", fx: 0.9, fy: 0.5)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(try cell("t21", in: host)))
        grid.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        host.host.layout()

        let session = try XCTUnwrap(host.coordinator.dragSession)
        let content = try XCTUnwrap(grid.baseContentFrames(for: session.baseSnapshot.items, placementTable: session.baseSnapshot.placementTable))
        let frame = grid.gridFrame(fromContentFrame: try XCTUnwrap(content["t21"]))
        XCTAssertEqual(frame.midY, centerBefore.y - 100, accuracy: 0.5, "Рамка сместилась с offset")

        host.coordinator.updateDrag(to: CGPoint(x: frame.midX, y: frame.midY))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .group("t21"),
            "Хит-тест учитывает актуальный contentOffset"
        )

        host.coordinator.finishDrag(commit: false)
        grid.setContentOffset(.zero, animated: false)
        host.host.layout()
        XCTAssertTrue(host.waitForDragCleanup("t0"))
    }

    // MARK: - E12.3: перенос из панели на центр другой папки

    /// E12.3: иконка панели → центр другой папки (по базовой раскладке) с
    /// удержанием сливается при стандартном магните (28 pt) — и при хвате за
    /// центр иконки, и за её края; снимок при этом не уезжает из-под пальца.
    func testPanelIconToOtherFolderCenterMergesWithMagnet() throws {
        let grabs: [CGPoint] = [
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.05, y: 0.05),
            CGPoint(x: 0.95, y: 0.95),
            CGPoint(x: 0.05, y: 0.95),
            CGPoint(x: 0.95, y: 0.05)
        ]
        for grab in grabs {
            let host = makePanelHost(configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.05))
            let (f1, f2) = try panelHostFolderIDs(host)
            let start = try startPanelDrag(host, folderID: f1, iconIndex: 1, grab: grab)
            let session = try XCTUnwrap(host.coordinator.dragSession)
            let content = try XCTUnwrap(host.host.grid.baseContentFrames(for: session.baseSnapshot.items, placementTable: session.baseSnapshot.placementTable))
            let base = host.host.grid.gridFrame(fromContentFrame: try XCTUnwrap(content[f2]))
            let target = CGPoint(x: base.midX, y: base.midY)

            // Палец уходит в центр одним событием (старт — в панели, вне сетки):
            // тест изолирует магнит от якоря допуска удержания (см. дизайн-док, п. 40).
            XCTAssertNotEqual(start, target)
            host.coordinator.updateDrag(to: target)
            host.spin(0.02)
            XCTAssertEqual(session.hover, .folder(f2), "grab=\(grab): палец над центром F2")
            XCTAssertTrue(
                host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
                "grab=\(grab): удержание выдержано"
            )
            // Снимок стоит под пальцем (а не притянут к слоту).
            XCTAssertEqual(session.dragView.center.x, target.x + session.grabOffset.x, accuracy: 0.5, "grab=\(grab)")
            XCTAssertEqual(session.dragView.center.y, target.y + session.grabOffset.y, accuracy: 0.5, "grab=\(grab)")

            host.coordinator.finishDrag(commit: true)
            host.spin(0.3)
            XCTAssertEqual(
                host.folders.first { $0.id == f2 }?.tiles.map { $0.id },
                ["e", "c"] as [AnyHashable],
                "grab=\(grab): ярлык слился с F2"
            )
        }
    }

    /// E12.1 (гипотеза о хвате): вынос единственного ярлыка в «дыру» модели при
    /// стандартном магните и хвате за края иконки не кладёт его в соседнюю
    /// папку; палец стоит над «дырой» модели, снимок не уезжает от него дальше
    /// радиуса магнита.
    func testSoleFolderTileEdgeGrabIntoHoleNeverEntersNeighborFolderWithMagnet() throws {
        let grabs = [CGPoint(x: 0.05, y: 0.05), CGPoint(x: 0.95, y: 0.95), CGPoint(x: 0.95, y: 0.05)]
        for columns in [4, 5, 6] {
            for grab in grabs {
                let host = makeMoveOutHost(columns: columns, magnet: 28)
                let (work, folderB) = try panelHostFolderIDs(host)
                let hole = try moveOutHolePoint(host, work: work)

                try startPanelDrag(host, folderID: work, iconIndex: 0, grab: grab)
                let session = try XCTUnwrap(host.coordinator.dragSession)
                host.coordinator.updateDrag(to: CGPoint(x: hole.x - 30, y: hole.y))
                host.coordinator.updateDrag(to: hole)
                host.spin(0.12)
                XCTAssertNotEqual(session.hover, .folder(folderB), "cols=\(columns) grab=\(grab)")
                XCTAssertNotEqual(host.coordinator.mergeTracker?.isMergeReady, true, "cols=\(columns) grab=\(grab)")
                host.coordinator.finishDrag(commit: true)
                host.spin(0.3)
                assertMailIsPlainTile(host, folderB: folderB, work: work, "cols=\(columns) grab=\(grab)")
            }
        }
    }

    // MARK: - E12.3: удержание считается от последнего заметного движения

    /// Идёт пальцем от `start` к `end` равными шагами (событие на шаг), без пауз.
    private func walk(
        _ host: TesseraTestDragHost,
        from start: CGPoint,
        to end: CGPoint,
        steps: Int
    ) {
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            host.coordinator.updateDrag(to: CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            ))
        }
    }

    /// E12.3: 14 шагов от иконки панели к центру B, остановка — слияние
    /// (воспроизведение ручного прогона: на входе в зону якорь ставился на
    /// первой точке зоны, и палец, ушедший дальше 10 pt, больше не перевзводился).
    /// Магнит — по умолчанию (28 pt); хват и за центр, и за угол иконки.
    func testPanelIconWalkToOtherFolderCenterMerges() throws {
        let grabs = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.05, y: 0.05), CGPoint(x: 0.95, y: 0.95)]
        for grab in grabs {
            let host = makePanelHost(configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.1))
            let (f1, f2) = try panelHostFolderIDs(host)
            let start = try startPanelDrag(host, folderID: f1, iconIndex: 1, grab: grab)
            let session = try XCTUnwrap(host.coordinator.dragSession)
            let content = try XCTUnwrap(host.host.grid.baseContentFrames(for: session.baseSnapshot.items, placementTable: session.baseSnapshot.placementTable))
            let base = host.host.grid.gridFrame(fromContentFrame: try XCTUnwrap(content[f2]))
            let target = CGPoint(x: base.midX, y: base.midY)

            walk(host, from: start, to: target, steps: 14)
            XCTAssertEqual(session.hover, .folder(f2), "grab=\(grab): палец над центром F2")
            XCTAssertTrue(
                host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
                "grab=\(grab): удержание выдержано после остановки"
            )

            host.coordinator.finishDrag(commit: true)
            host.spin(0.3)
            XCTAssertEqual(
                host.folders.first { $0.id == f2 }?.tiles.map { $0.id },
                ["e", "c"] as [AnyHashable],
                "grab=\(grab): ярлык слился с F2"
            )
        }
    }

    /// E12.3: тот же 14-шаговый заход с плитки сетки (создание папки и
    /// добавление в существующую) завершается слиянием.
    func testGridTileWalkToFolderCenterMerges() throws {
        let host = makePanelHost(configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.1))
        let (_, f2) = try panelHostFolderIDs(host)
        let start = try XCTUnwrap(host.point("a"))
        let target = try XCTUnwrap(host.point(f2))

        XCTAssertTrue(host.startDrag("a"))
        walk(host, from: start, to: target, steps: 14)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .folder(f2))
        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })

        host.coordinator.finishDrag(commit: true)
        host.spin(0.3)
        XCTAssertEqual(
            host.folders.first { $0.id == f2 }?.tiles.map { $0.id },
            ["e", "a"] as [AnyHashable]
        )
    }

    /// E12.3: постоянное медленное движение внутри центральной зоны (каждый
    /// шаг ≥10 pt) готовности не даёт, даже когда суммарное время давно
    /// больше порога.
    func testContinuousMovementOverFolderCenterNeverBecomesReady() throws {
        let host = makePanelHost(configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.3))
        let (_, f2) = try panelHostFolderIDs(host)
        let center = try XCTUnwrap(host.point(f2))

        XCTAssertTrue(host.startDrag("a"))
        // Вход в зону — на −8 pt от центра; дальше шаги ±8 pt (16 pt между соседними).
        host.coordinator.updateDrag(to: CGPoint(x: center.x - 8, y: center.y))
        for step in 0..<24 {
            let dx: CGFloat = step % 2 == 0 ? 8 : -8
            host.coordinator.updateDrag(to: CGPoint(x: center.x + dx, y: center.y))
            XCTAssertEqual(host.coordinator.dragSession?.hover, .folder(f2), "шаг \(step)")
            host.spin(0.05)
            XCTAssertFalse(host.coordinator.mergeTracker?.isMergeReady == true, "шаг \(step)")
        }

        // Остановка — через порог от последнего движения готовность наступает.
        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })
        host.coordinator.finishDrag(commit: false)
        host.spin(0.3)
    }

    /// E12.3: сместиться на 15 pt и вернуться к старой точке — готовность не
    /// раньше порога от последнего перевзвода.
    func testReturnToOldAnchorDoesNotMergeEarlierThanHoldFromLastMove() throws {
        let host = makePanelHost(configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.4))
        let (_, f2) = try panelHostFolderIDs(host)
        let center = try XCTUnwrap(host.point(f2))
        let a = CGPoint(x: center.x - 8, y: center.y)
        let b = CGPoint(x: center.x + 7, y: center.y)

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: a)
        host.spin(0.25)
        host.coordinator.updateDrag(to: b)
        host.spin(0.25)
        // Возврат к старому якорю A: смещение 15 pt от B — новый отсчёт.
        let reanchoredAt = Date()
        host.coordinator.updateDrag(to: a)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .folder(f2))
        host.spin(0.2)
        XCTAssertFalse(
            host.coordinator.mergeTracker?.isMergeReady == true,
            "Через 0,2 с после последнего перевзвода готовности ещё нет"
        )
        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })
        XCTAssertGreaterThan(Date().timeIntervalSince(reanchoredAt), 0.4)

        host.coordinator.finishDrag(commit: false)
        host.spin(0.3)
    }

    /// E12.3 (хвост): drop без готовности на центре папки не оставляет превью
    /// более раннего reorder — порядок сетки равен модели, ярлык не на чужом слоте.
    func testNotReadyDropOnFolderCenterLeavesNoPushPreview() throws {
        let host = makePanelHost(configuration: TesseraTileEditConfiguration(mergeHoverDuration: 5))
        let (f1, f2) = try panelHostFolderIDs(host)
        let modelBefore = host.storeIDs
        let start = try startPanelDrag(host, folderID: f1, iconIndex: 1)
        let session = try XCTUnwrap(host.coordinator.dragSession)
        let content = try XCTUnwrap(host.host.grid.baseContentFrames(for: session.baseSnapshot.items, placementTable: session.baseSnapshot.placementTable))
        let base = host.host.grid.gridFrame(fromContentFrame: try XCTUnwrap(content[f2]))
        let target = CGPoint(x: base.midX, y: base.midY)

        walk(host, from: start, to: target, steps: 14)
        XCTAssertEqual(session.hover, .folder(f2))
        XCTAssertNotEqual(host.coordinator.mergeTracker?.isMergeReady, true)

        host.coordinator.finishDrag(commit: true)
        host.spin(0.5)
        XCTAssertEqual(host.storeIDs, modelBefore, "Модель не менялась")
        XCTAssertEqual(host.gridIDs, modelBefore, "Сетка вернулась к порядку модели")
    }

    // MARK: - E12.2: папка из wide/large/small цели (всегда medium)

    /// Стенд: цель любого размера + перетаскиваемый ярлык + «хвост» из малых.
    private func makeWideTargetHost(
        target: TileSize,
        source: TileSize,
        sourceFirst: Bool
    ) -> TesseraTestDragHost {
        let pair = [
            tesseraTestTile("t", size: target),
            tesseraTestTile("s", size: source),
        ]
        return TesseraTestDragHost(
            descriptors: (sourceFirst ? pair.reversed() : pair) + [
                tesseraTestTile("x1", size: .small),
                tesseraTestTile("x2", size: .small),
                tesseraTestTile("x3", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.1)
        )
    }

    /// E12.2: слияние на центр wide/large/small цели с удержанием создаёт
    /// папку; папка всегда medium (W10M), и при пальце, дошедшем несколькими
    /// шагами, и при «прыжке» сразу в центр. Модель и сетка согласованы.
    func testMergeOnTargetCenterCreatesMediumFolder() throws {
        let cases: [(target: TileSize, source: TileSize)] = [
            (.wide, .medium), (.wide, .small), (.large, .medium), (.large, .small),
            (.small, .medium), (.medium, .small),
        ]
        for walking in [true, false] {
          for sourceFirst in [false, true] {
            for item in cases {
                let label = "target=\(item.target) source=\(item.source) walking=\(walking) sourceFirst=\(sourceFirst)"
                let host = makeWideTargetHost(target: item.target, source: item.source, sourceFirst: sourceFirst)
                let recorder = DragDelegateRecorder()
                host.coordinator.delegate = recorder
                let start = try XCTUnwrap(host.point("s"))
                let center = try XCTUnwrap(host.point("t"))

                XCTAssertTrue(host.startDrag("s"), label)
                if walking {
                    walk(host, from: start, to: center, steps: 14)
                } else {
                    host.coordinator.updateDrag(to: center)
                }
                XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t"), label)
                XCTAssertTrue(
                    host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
                    "Удержание выдержано: \(label)"
                )

                host.coordinator.finishDrag(commit: true)
                XCTAssertTrue(host.waitUntil { recorder.additions.count == 1 }, label)
                let folder = try XCTUnwrap(host.folders.first, label)
                XCTAssertEqual(folder.size, .medium, "Папка всегда medium: \(label)")
                XCTAssertEqual(folder.tiles.map { $0.id }, ["t", "s"] as [AnyHashable], label)
                XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil }, label)
                host.spin(0.3)
                XCTAssertEqual(host.gridIDs, host.storeIDs, "Сетка = модель: \(label)")
                XCTAssertEqual(host.storeIDs.count, 4, "Папка + три малых: \(label)")

                // Раскладка здравая: папка 2×2, снимок летел в её рамку, рамки
                // не пересекаются.
                let frame = try XCTUnwrap(host.host.grid.frame(forItemID: folder.id), label)
                let small = try XCTUnwrap(host.host.grid.frame(forItemID: "x1"), label)
                XCTAssertGreaterThan(frame.width, small.width * 1.5, "Папка больше малой: \(label)")
                XCTAssertLessThan(frame.width, small.width * 3, "Папка не wide: \(label)")
                XCTAssertEqual(host.coordinator.lastCollapseTargetFrame, frame, label)
                let frames = host.storeIDs.compactMap { host.host.grid.frame(forItemID: $0) }
                for (i, a) in frames.enumerated() {
                    for b in frames[(i + 1)...] {
                        XCTAssertFalse(a.intersects(b.insetBy(dx: 1, dy: 1)), "Пересечение: \(label)")
                    }
                }
            }
          }
        }
    }
    // MARK: - E12.10: drag из обычного режима при неканоничном порядке модели

    /// Стенд как «Старт» в Example: малая «Почта», средний «Календарь», wide
    /// «Погода», папка «Работа» (из «Заметок» и «Фото»), large «Музыка» и малые
    /// «Настройки» **последними в модели** — упаковка поднимает их в «дыру» справа
    /// от календаря, то есть порядок модели не совпадает с порядком чтения.
    private func makeStartLikeHost() -> TesseraTestDragHost {
        TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("mail", size: .small),
                tesseraTestTile("calendar", size: .medium),
                tesseraTestTile("weather", size: .wide),
                tesseraTestTile("notes", size: .small),
                tesseraTestTile("photos", size: .small),
                tesseraTestTile("music", size: .large),
                tesseraTestTile("settings", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.1),
            prepare: { store in
                if let folder = store.createFolder(withTile: "notes", title: "Работа") {
                    store.addToFolder("photos", folderID: folder.id)
                }
            }
        )
    }

    /// E12.10/E14.5: свежий старт, edit выключен; один жест — long-press на
    /// «Почте» (вход в edit + drag) и без отрыва на «Настройки» с удержанием.
    /// Папка 2×2 встаёт на ячейку цели (D20), а не в конец сетки; «Настройки»
    /// стоят в крайней колонке (0, 3), 2×2 там не помещается, поэтому ячейка
    /// сдвигается влево до (0, 2), а календарь, который она накрывает, уходит
    /// вниз каскадом (D31). Ячейка «Почты» остаётся дырой.
    func testStartFromNormalModeMergeOntoHoleFillingTileKeepsTargetSlot() throws {
        let host = makeStartLikeHost()
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        XCTAssertFalse(host.coordinator.isEditing)
        let start = try XCTUnwrap(host.point("mail"))
        let target = try XCTUnwrap(host.point("settings"))
        let targetFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "settings"))
        let calendarFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "calendar"))
        XCTAssertGreaterThan(targetFrame.minX, calendarFrame.maxX, "«Настройки» стоят в дыре справа от календаря")
        XCTAssertEqual(targetFrame.minY, calendarFrame.minY, accuracy: 1)

        XCTAssertTrue(host.startDrag("mail"))
        XCTAssertTrue(host.coordinator.isEditing)
        walk(host, from: start, to: target, steps: 14)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("settings"))
        XCTAssertTrue(
            host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
            "Удержание выдержано"
        )

        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { recorder.additions.count == 1 })
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        host.spin(0.3)

        let folder = try XCTUnwrap(host.folders.first { $0.tiles.map { $0.id } == ["settings", "mail"] as [AnyHashable] })
        XCTAssertEqual(host.gridIDs, host.storeIDs, "Сетка = модель")
        XCTAssertEqual(folder.size, .medium)
        // Папка в строке цели (а не в конце сетки), ячейка сдвинута влево до 2.
        XCTAssertEqual(host.store.placement(of: folder.id), TileGridPlacement(row: 0, column: 2))
        XCTAssertEqual(host.storeIDs.first, folder.id, "Папка — первая в порядке чтения, а не в конце")
        let folderFrame = try XCTUnwrap(host.host.grid.frame(forItemID: folder.id))
        XCTAssertEqual(folderFrame.minY, targetFrame.minY, accuracy: 1, "В строке цели")
        // Календарь, накрытый папкой, вытолкнут вниз (D31); дыра «Почты» осталась.
        let newCalendarFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "calendar"))
        XCTAssertGreaterThan(newCalendarFrame.minY, folderFrame.maxY - 1)
        XCTAssertNil(host.store.placements(forColumns: 4).values.first { $0 == TileGridPlacement(row: 0, column: 0) }, "Ячейка «Почты» — дыра")
    }

    /// E12.10 → E14.5: старт drag (в т. ч. из уже включённого edit и при возврате
    /// без слияния) не меняет ни модель, ни видимую раскладку: координаты ячеек —
    /// сама модель, порядок не канонизируется (раньше `canonicalizeVisibleOrder`),
    /// «Настройки» остаются в дыре справа от календаря.
    func testDragStartKeepsModelAndLayoutUntouched() throws {
        for editFirst in [false, true] {
            let host = makeStartLikeHost()
            let before = host.storeIDs.compactMap { host.host.grid.frame(forItemID: $0) }
            let idsBefore = host.storeIDs
            let cellsBefore = host.store.placements(forColumns: 4)
            if editFirst { host.coordinator.beginEditing() }
            XCTAssertTrue(host.startDrag("mail"), "editFirst=\(editFirst)")
            XCTAssertEqual(host.storeIDs, idsBefore, "Порядок модели не тронут: editFirst=\(editFirst)")
            XCTAssertEqual(host.store.placements(forColumns: 4), cellsBefore, "Ячейки не тронуты: editFirst=\(editFirst)")
            XCTAssertEqual(host.gridIDs, host.storeIDs, "editFirst=\(editFirst)")
            host.coordinator.finishDrag(commit: false)
            XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
            host.spin(0.3)
            let after = host.storeIDs.compactMap { host.host.grid.frame(forItemID: $0) }
            XCTAssertEqual(before.count, after.count)
            // Сравниваем набор рамок: порядок идентификаторов поменялся, раскладка — нет.
            let key: (CGRect) -> String = { "\(Int($0.minX.rounded())),\(Int($0.minY.rounded())),\(Int($0.width.rounded()))" }
            XCTAssertEqual(Set(before.map(key)), Set(after.map(key)), "editFirst=\(editFirst)")
        }
    }
}

#endif
