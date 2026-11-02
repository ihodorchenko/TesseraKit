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

    /// Левая/правая половина плитки-папки — зона перестановки: папка встаёт в
    /// базовый индекс, ярлык занимает её место (E10.5-A1, push-превью E8.4).
    func testFolderEdgeZoneReordersTileInsteadOfAdding() throws {
        let host = makeFolderHost()
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let folderID = try XCTUnwrap(host.firstFolderID)

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(folderID, fx: 0.1, fy: 0.5)))

        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .reorder(folderID, index: 1),
            "Край папки — цель перестановки с базовым индексом папки"
        )

        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(
            host.waitUntil { recorder.moves.count == 1 },
            "Drop в краевой зоне завершился перестановкой"
        )
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("a"))
        XCTAssertEqual(recorder.moves.first?.index, 1, "Фактический индекс из store")
        XCTAssertEqual(host.storeIDs, [folderID, AnyHashable("a")])
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }

    /// Перетаскивание папки по сетке — обычная перестановка в любой зоне:
    /// папку нельзя бросить в папку (`session.isTile == false`).
    func testFolderAsSourceIsNeverGrouped() throws {
        let host = makeFolderHost()
        let folderID = try XCTUnwrap(host.firstFolderID)

        XCTAssertTrue(host.startDrag(folderID))
        XCTAssertEqual(host.coordinator.dragSession?.isTile, false)

        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("a", fx: 0.5, fy: 0.5)))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .reorder(AnyHashable("a"), index: 0),
            "Папка над центром ярлыка — перестановка, а не группировка"
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

    /// Смещение на допуск отменяет удержание, возврат в допуск запускает новый
    /// отсчёт 600 мс — drop после возврата создаёт папку (E10.5-A3, E9.8а).
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

        // Смещение 15 pt внутри центральной зоны: удержание отменено.
        host.coordinator.updateDrag(to: CGPoint(x: center.x + 15, y: center.y))
        XCTAssertEqual(host.coordinator.mergeTracker?.state, .cancelled)
        XCTAssertFalse(host.coordinator.mergeTracker?.isMergeReady == true)

        // Отмена терминальна, пока палец не вернулся в допуск.
        host.spin(0.12)
        XCTAssertEqual(host.coordinator.mergeTracker?.state, .cancelled)
        XCTAssertFalse(host.coordinator.mergeTracker?.isMergeReady == true)

        // Возврат в допуск — новый отсчёт, а не мгновенная готовность.
        host.coordinator.updateDrag(to: center)
        XCTAssertEqual(host.coordinator.mergeTracker?.state, .armed)
        XCTAssertFalse(host.coordinator.mergeTracker?.isMergeReady == true)
        XCTAssertTrue(
            host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
            "Новый отсчёт 600 мс выдержан"
        )

        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { recorder.createdFolders.count == 1 })
        XCTAssertEqual(host.folders.count, 1, "Папка создана после возврата в допуск")
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

    /// Drop отдаёт делегату фактический индекс из `TileStore.moveItem`, а сетка
    /// синхронизируется со снимком store (E10.5-C1).
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
        XCTAssertEqual(recorder.moves.first?.index, 2, "Фактический индекс из store")
        XCTAssertEqual(host.storeIDs, ["b", "c", "a"])
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
            TileStore.readingOrder(of: host.store.snapshot().layoutItems, columns: 4),
            "Видимый порядок канонизирован к порядку чтения"
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

    /// Перемещение ярлыка из папки на рабочий стол тоже канонизирует порядок и
    /// идёт через функцию одобрения (D14, E10.5-C2).
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

    /// E11.2: вынос из папки без индекса ставит ярлык сразу после папки, а не в
    /// конец; фокус и канонизация сохраняются.
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

        XCTAssertTrue(host.coordinator.moveBetweenFolders("b", to: nil))
        XCTAssertEqual(host.storeIDs, [folderID, "b", "c", "d"])
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

        XCTAssertTrue(host.startDrag("a"))
        // Сначала — над краем c: превью перестановки [b, c, a].
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("c", fx: 0.1, fy: 0.5)))
        host.host.layout()
        XCTAssertEqual(host.coordinator.dragSession?.hover, .reorder(AnyHashable("c"), index: 2))

        // Затем — центр b: зона E8.6, удержание не выдержано.
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("b", fx: 0.5, fy: 0.5)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group(AnyHashable("b")))
        host.coordinator.finishDrag(commit: true)

        XCTAssertEqual(host.storeIDs, baseIDs, "Модель не изменилась")
        XCTAssertTrue(recorder.moves.isEmpty)
        XCTAssertTrue(recorder.createdFolders.isEmpty)
        XCTAssertTrue(
            host.waitUntil { host.gridIDs == baseIDs },
            "Превью перестановки снято, порядок вернулся к исходному"
        )
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

        // Reorder-превью: палец на краю папки.
        host.coordinator.updateDrag(
            to: try XCTUnwrap(host.point(folderID, fx: 0.1, fy: 0.5))
        )
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .reorder(folderID, index: 1)
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
        XCTAssertEqual(host.storeIDs, [folderID, AnyHashable("a")])
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
        // reorder-превью, поэтому нижнюю границу пересчитываем по новой рамке).
        host.coordinator.updateDrag(to: CGPoint(x: central.maxX, y: central.midY))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .reorder(AnyHashable("b"), index: 1)
        )
        let movedFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "b"))
        let movedCentral = movedFrame.insetBy(
            dx: movedFrame.width * 0.25,
            dy: movedFrame.height * 0.25
        )
        host.coordinator.updateDrag(to: CGPoint(x: movedCentral.midX, y: movedCentral.maxY))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .reorder(AnyHashable("b"), index: 1)
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
        session.hover = .none

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
        // Пуш-превью перестановки: ярлык встаёт на место папки.
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(folderID, fx: 0.1, fy: 0.5)))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .reorder(folderID, index: 1)
        )
        XCTAssertNotEqual(host.gridIDs, host.storeIDs, "Превью отличается от модели")

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
        XCTAssertNotEqual(
            host.gridIDs,
            host.storeIDs,
            "Сетка всё ещё показывает push-превью — именно его нельзя фиксировать"
        )

        host.coordinator.finishDrag(commit: true)

        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
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
        // Превью перестановки, затем палец — в пустое место, где появится панель.
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(folderID, fx: 0.1, fy: 0.5)))
        host.coordinator.updateDrag(to: panelPoint)
        XCTAssertEqual(host.coordinator.dragSession?.hover, HoverTarget.none)
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
                if let folder = store.createFolder(withTile: "b") {
                    _ = store.addToFolder("c", folderID: folder.id)
                }
                _ = store.createFolder(withTile: "e")
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
        iconIndex: Int
    ) throws -> CGPoint {
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == folderID })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        let panelItem = try XCTUnwrap(host.host.grid.displayItems.first { $0.isFolderPanel })
        let panel = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        let icon = try XCTUnwrap(panel.shortcutCells[iconIndex] as TesseraTileCell?)
        let point = try XCTUnwrap(icon.superview?.convert(icon.center, to: host.host.grid))

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

    /// Вынос на сетку: ярлык встаёт на позицию превью, делегат получает
    /// `didMove(toFolder: nil, atIndex:)`, прежний колбэк не вызывается.
    func testDropOutOfFolderLandsAtPreviewIndex() throws {
        let host = makePanelHost()
        let recorder = IndexedMoveRecorder()
        host.coordinator.delegate = recorder
        let (f1, _) = try panelHostFolderIDs(host)

        try startPanelDrag(host, folderID: f1, iconIndex: 1)
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("a", fx: 0.1, fy: 0.5)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .reorder("a", index: 0))
        XCTAssertEqual(host.gridIDs.first, AnyHashable("c"), "Превью: ярлык на месте цели")

        host.coordinator.finishDrag(commit: true)

        XCTAssertEqual(recorder.moves.count, 1)
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("c"))
        XCTAssertNil(recorder.moves.first?.folder ?? nil)
        XCTAssertEqual(recorder.moves.first?.index, 0)
        XCTAssertEqual(host.storeIDs.first, AnyHashable("c"))
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["b"] as [AnyHashable])
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertTrue(host.waitForDragCleanup("c"))
        XCTAssertNil(host.coordinator.dragSession)
        // Кадр, в который летит снимок, — рамка вынесенной плитки после render.
        XCTAssertNotNil(host.host.grid.frame(forItemID: "c"))
    }

    /// Вынос последнего ярлыка распускает папку; индекс учитывает, что папка,
    /// стоявшая перед ярлыком, исчезла из итогового порядка.
    func testDropOfLastTileDissolvesFolderAndAdjustsIndex() throws {
        let host = makePanelHost()
        let recorder = IndexedMoveRecorder()
        host.coordinator.delegate = recorder
        let (_, f2) = try panelHostFolderIDs(host)

        try startPanelDrag(host, folderID: f2, iconIndex: 0)
        XCTAssertEqual(host.coordinator.dragSession?.sourceFolderID, f2)
        // Пустое место: превью не меняется, ярлык остаётся после папки.
        host.coordinator.updateDrag(to: emptyPoint(in: host))
        XCTAssertEqual(host.coordinator.dragSession?.hover, HoverTarget.none)

        host.coordinator.finishDrag(commit: true)

        XCTAssertFalse(host.storeIDs.contains(f2), "Папка из одного ярлыка распалась")
        XCTAssertEqual(host.storeIDs.last, AnyHashable("e"), "Ярлык занял место папки")
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
    /// как перестановка (вынос на сетку).
    func testCenterOfPlainTileDoesNotCreateFolderForFolderSource() throws {
        let host = makePanelHost()
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let (f1, _) = try panelHostFolderIDs(host)

        try startPanelDrag(host, folderID: f1, iconIndex: 1)
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("a", fx: 0.5, fy: 0.5)))
        guard case .reorder(let targetID, _)? = host.coordinator.dragSession?.hover,
              targetID == AnyHashable("a") else {
            return XCTFail("Центр ярлыка — перестановка, а не группировка")
        }
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
}

#endif
