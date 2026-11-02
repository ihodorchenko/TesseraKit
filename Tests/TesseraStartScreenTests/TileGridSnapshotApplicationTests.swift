//
//  TileGridSnapshotApplicationTests.swift
//  TesseraStartScreenTests
//
//  Дифф-применение снимка и состояние ячеек сетки (E10.4, волна W3 плана
//  E9/E10). Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3
//  «Плиточная сетка» (инвалидация и batch-обновления), §4 «Live-плитки»
//  (флипы, паузы), §5 «Режим редактирования» (дим 0.7), §8 «Параллакс»
//  (пауза live-контента вне экрана), §9 «Accessibility»; D12 (ярлык —
//  действие), D17 (панель папки), E8.2 (дим), E8.9 (магнитизм), E10.1
//  (пиксельное выравнивание, `gridMetrics`).
//
//  Проверяется:
//  - снимок при смене состава применяется диффом: ячейки сохраняют
//    регистрацию live-плитки (флип не сбрасывается на лицевую сторону) и
//    фазу idle-флипа превью папки;
//  - владелец дима 0.7 — сетка: дим переживает update/resize/drop;
//  - ярлык панели раскрытой папки активируется общим маршрутом `onTap` и не
//    активируется в режиме редактирования;
//  - `magnetSlotCenters(for:)` совпадает с рамками раскладки до пикселя
//    (`TileLayoutEngine.gridMetrics`);
//  - публичная пауза live-контента не снимается `grid.update` в обход
//    контроллера, пока START за кадром (остаток T1).
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileGridSnapshotApplicationTests: XCTestCase {

    // MARK: - Окружение

    private var windows: [UIWindow] = []

    override func tearDown() {
        for window in windows {
            window.subviews.forEach { $0.removeFromSuperview() }
            window.isHidden = true
        }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - Дифф снимка: live-плитки (E10.4)

    /// Смена состава больше не идёт через `reloadData`: live-ячейка сохраняется
    /// вместе с контейнером, поэтому флип на обратную сторону не сбрасывается на
    /// лицевую (раньше это ломало live-плитки при каждом обновлении бейджей).
    func testSnapshotDiffPreservesLiveTileFlip() throws {
        let live = tesseraTestLiveTile(
            "live",
            front: TesseraLiveTileFace(title: "Front"),
            back: TesseraLiveTileFace(title: "Back"),
            size: .medium
        )
        let other = tesseraTestTile("other", size: .small)
        let extra = tesseraTestTile("extra", size: .small)
        let host = TesseraTestWindowedGrid(items: [.tile(live), .tile(other)])
        host.layout()

        let liveView = try XCTUnwrap(
            host.firstSubview(of: TesseraLiveTileView.self),
            "Live-плитка на экране"
        )
        let liveCell = try XCTUnwrap(host.cell(live.id))
        liveView.show(.back, animated: false)
        XCTAssertEqual(liveView.side, .back)

        host.grid.update(
            snapshot: TileGridSnapshot(
                items: [.tile(live), .tile(other), .tile(extra)],
                unpinned: []
            ),
            animated: false
        )
        host.layout()

        let liveViewAfter = try XCTUnwrap(host.firstSubview(of: TesseraLiveTileView.self))
        XCTAssertTrue(liveViewAfter === liveView, "Контейнер живой плитки сохранён")
        XCTAssertTrue(host.cell(live.id) === liveCell, "Ячейка сохранена диффом")
        XCTAssertEqual(
            liveViewAfter.side,
            .back,
            "Флип не сброшен на лицевую сторону при смене состава"
        )
        XCTAssertFalse(liveViewAfter.isFlipping)
    }

    // MARK: - Дифф снимка: превью папки (E10.4)

    /// Превью закрытой папки сохраняет idlе-флип: переиспользование ячейки при
    /// `reloadData` сбрасывало мини-плитки на иконки, теперь состав применяется
    /// диффом и состояние превью не перезапускается.
    func testSnapshotDiffPreservesFolderPreviewFlip() throws {
        // B1 (фикс-раунд): idle-флип превью возможен только у ярлыка с видимым
        // бейджем — `TesseraFolderMiniTileView.showBadge` игнорирует `.none`.
        let folder = TileFolder(
            id: "folder",
            title: "folder",
            tiles: (0..<4).map {
                tesseraTestTile("folder-tile\($0)", size: .small, badge: .count($0 + 1))
            }
        )
        let other = tesseraTestTile("other", size: .small)
        let extra = tesseraTestTile("extra", size: .small)
        let host = TesseraTestWindowedGrid(items: [.folder(folder), .tile(other)])
        host.layout()

        let cell = try XCTUnwrap(host.cell(folder.id))
        let preview = try XCTUnwrap(cell.folderPreviewView)
        let miniTile = try XCTUnwrap(preview.miniTileViews.first)
        XCTAssertTrue(miniTile.hasVisibleBadge, "У ярлыка папки есть бейдж")
        miniTile.showBadge(animated: false)
        XCTAssertTrue(miniTile.showsBadgeSide, "Мини-плитка перевернулась к бейджу")

        host.grid.update(
            snapshot: TileGridSnapshot(
                items: [.folder(folder), .tile(other), .tile(extra)],
                unpinned: []
            ),
            animated: false
        )
        host.layout()

        let cellAfter = try XCTUnwrap(host.cell(folder.id))
        let previewAfter = try XCTUnwrap(cellAfter.folderPreviewView)
        let miniTileAfter = try XCTUnwrap(previewAfter.miniTileViews.first)
        XCTAssertTrue(cellAfter === cell, "Ячейка папки сохранена")
        XCTAssertTrue(previewAfter === preview, "Превью папки не пересоздано")
        XCTAssertTrue(miniTileAfter === miniTile)
        XCTAssertTrue(
            miniTileAfter.showsBadgeSide,
            "Idle-флип превью не сброшен на иконку"
        )
    }

    // MARK: - Контракт «без анимации» (M2)

    /// `reload(snapshot:)` и `update(animated: false)` обязаны применять смену
    /// состава без анимации: иначе `performBatchUpdates` анимирует
    /// insert/delete дефолтной длительностью UIKit (~0,25 с) и контракт
    /// «снимок без анимации» нарушается. Внутренний признак фиксирует
    /// `UIView.performWithoutAnimation`; анимированный путь идёт кроссфейдом.
    func testNonAnimatedSnapshotApplicationDoesNotAnimateDiff() {
        let host = TesseraTestWindowedGrid(
            items: [.tile(tesseraTestTile("a", size: .small))]
        )
        host.layout()

        host.grid.update(
            snapshot: TileGridSnapshot(
                items: [
                    .tile(tesseraTestTile("a", size: .small)),
                    .tile(tesseraTestTile("b", size: .small)),
                ],
                unpinned: []
            ),
            animated: false
        )
        host.layout()

        XCTAssertTrue(
            host.grid.didApplyLastSnapshotWithoutAnimation,
            "Неанимированный путь применяется через UIView.performWithoutAnimation"
        )
        XCTAssertFalse(host.grid.didApplyLastSnapshotWithCrossfade)
        XCTAssertEqual(host.grid.items.count, 2)

        // reload(snapshot:) — тоже без анимации.
        host.grid.reload(
            snapshot: TileGridSnapshot(
                items: [
                    .tile(tesseraTestTile("a", size: .small)),
                    .tile(tesseraTestTile("b", size: .small)),
                    .tile(tesseraTestTile("c", size: .small)),
                ],
                unpinned: []
            )
        )
        host.layout()
        XCTAssertTrue(host.grid.didApplyLastSnapshotWithoutAnimation)

        // Анимированный путь — кроссфейд, а не «без анимации».
        host.grid.update(
            snapshot: TileGridSnapshot(
                items: [
                    .tile(tesseraTestTile("a", size: .small)),
                    .tile(tesseraTestTile("b", size: .small)),
                    .tile(tesseraTestTile("c", size: .small)),
                    .tile(tesseraTestTile("d", size: .small)),
                ],
                unpinned: []
            ),
            animated: true
        )
        host.layout()
        XCTAssertTrue(host.grid.didApplyLastSnapshotWithCrossfade)
        XCTAssertFalse(host.grid.didApplyLastSnapshotWithoutAnimation)
        XCTAssertEqual(host.grid.items.count, 4)
    }

    // MARK: - Владелец дима (E10.4, E8.2)

    /// Дим 0.7 режима редактирования переживает обновление снимка, resize и
    /// возврат из скрытия на время drag: владелец прозрачности — сетка, а не
    /// `configure` ячейки.
    func testEditDimmingSurvivesSnapshotUpdateResizeAndDrop() throws {
        let first = tesseraTestTile("first", size: .small)
        let second = tesseraTestTile("second", size: .small)
        let host = TesseraTestWindowedGrid(items: [.tile(first), .tile(second)])
        host.layout()

        let targets: [AnyHashable: CGFloat] = [
            first.id: TesseraTileGridView.dimmedTileAlpha,
            second.id: TesseraTileGridView.dimmedTileAlpha,
        ]
        host.grid.setEditDimming(targets, animated: false)
        let cell = try XCTUnwrap(host.cell(first.id))
        XCTAssertEqual(
            cell.contentView.alpha,
            TesseraTileGridView.dimmedTileAlpha,
            accuracy: 0.001
        )

        // 1) Обновление снимка: меняется только содержимое (бейдж).
        host.grid.update(
            snapshot: TileGridSnapshot(
                items: [
                    .tile(TileDescriptor(
                        id: first.id,
                        title: first.title,
                        action: {},
                        badge: .dot,
                        size: .small
                    )),
                    .tile(second),
                ],
                unpinned: []
            ),
            animated: false
        )
        host.layout()
        XCTAssertEqual(
            try XCTUnwrap(host.cell(first.id)).contentView.alpha,
            TesseraTileGridView.dimmedTileAlpha,
            accuracy: 0.001,
            "Дим пережил update"
        )

        // 2) Resize: смена размера переупаковывает сетку.
        host.grid.update(
            snapshot: TileGridSnapshot(
                items: [.tile(first), .tile(tesseraTestTile("second", size: .medium))],
                unpinned: []
            ),
            animated: false
        )
        host.layout()
        XCTAssertEqual(
            try XCTUnwrap(host.cell(first.id)).contentView.alpha,
            TesseraTileGridView.dimmedTileAlpha,
            accuracy: 0.001,
            "Дим пережил resize"
        )

        // 3) Drop/unpin: скрытие на время drag не должно «поднять» плитку до 1.
        host.grid.setItemHidden(true, forItemID: first.id)
        XCTAssertEqual(try XCTUnwrap(host.cell(first.id)).contentView.alpha, 0, accuracy: 0.001)
        host.grid.setItemHidden(false, forItemID: first.id)
        XCTAssertEqual(
            try XCTUnwrap(host.cell(first.id)).contentView.alpha,
            TesseraTileGridView.dimmedTileAlpha,
            accuracy: 0.001,
            "После возврата из скрытия остаётся дим, а не полная яркость"
        )

        // 4) Снятие дима возвращает полную яркость.
        host.grid.setEditDimming(
            [first.id: 1, second.id: 1],
            animated: false
        )
        XCTAssertEqual(try XCTUnwrap(host.cell(first.id)).contentView.alpha, 1, accuracy: 0.001)
    }

    /// Реальный координатор входа в редактирование применяет дим через сетку, и
    /// обновление снимка в режиме редактирования его не стирает.
    func testCoordinatorDimmingSurvivesGridUpdate() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = TileStore(directoryURL: directory.url)
        store.autosaves = false

        let first = tesseraTestTile("first", size: .small)
        let second = tesseraTestTile("second", size: .small)
        let host = TesseraTestWindowedGrid(items: [.tile(first), .tile(second)])
        host.layout()

        let coordinator = TesseraTileEditCoordinator(grid: host.grid, store: store)
        coordinator.beginEditing()
        host.layout()

        XCTAssertTrue(
            host.waitUntil { [self] in
                let alpha = self.alpha(of: first.id, in: host)
                return abs(alpha - TesseraTileGridView.dimmedTileAlpha) < 0.001
            },
            "Дим режима редактирования применён к ячейкам"
        )
        defer { coordinator.endEditing() }

        host.grid.update(
            snapshot: TileGridSnapshot(
                items: [
                    .tile(TileDescriptor(
                        id: first.id,
                        title: first.title,
                        action: {},
                        badge: .count(2),
                        size: .small
                    )),
                    .tile(second),
                ],
                unpinned: []
            ),
            animated: false
        )
        host.layout()

        XCTAssertEqual(
            alpha(of: first.id, in: host),
            TesseraTileGridView.dimmedTileAlpha,
            accuracy: 0.001,
            "update в режиме редактирования не стирает дим"
        )
    }

    /// Прозрачность содержимого ячейки элемента.
    ///
    /// - Parameters:
    ///   - id: Идентификатор элемента.
    ///   - host: Окно с сеткой.
    /// - Returns: `contentView.alpha` видимой ячейки или 1, если её нет.
    private func alpha(of id: AnyHashable, in host: TesseraTestWindowedGrid) -> CGFloat {
        host.cell(id)?.contentView.alpha ?? 1
    }

    // MARK: - Ярлыки панели раскрытой папки (E10.4)

    /// Активация ярлыка внутри панели идёт общим маршрутом `onTap` (действие
    /// ярлыка выполняет хост, D12), а не вызовом `action` мимо события.
    func testPanelShortcutActivationGoesThroughOnTap() throws {
        var actionCalls = 0
        let inFolder = TileDescriptor(
            id: "in-folder",
            title: "Inside",
            action: { actionCalls += 1 },
            size: .small
        )
        let folder = TileFolder(id: "folder", title: "Folder", tiles: [inFolder])
        let host = TesseraTestWindowedGrid(items: [.folder(folder)])
        host.grid.openFolder(folder, animated: false)
        host.layout()

        let panel = try XCTUnwrap(host.panelCell(folderID: folder.id))
        let shortcut = try XCTUnwrap(panel.shortcutCells.first)

        var tapped: [TileGridItem] = []
        host.grid.onTap = { tapped.append($0) }

        XCTAssertTrue(shortcut.accessibilityActivate())
        XCTAssertEqual(tapped.count, 1, "Активация пришла в onTap")
        XCTAssertEqual(tapped.first?.tile?.id, inFolder.id)
        XCTAssertEqual(actionCalls, 0, "Панель не вызывает action напрямую")
        XCTAssertEqual(
            host.grid.expandedFolderID,
            folder.id,
            "Активация ярлыка не закрывает папку"
        )
    }

    /// В режиме редактирования панель не активирует действие ярлыка: тап
    /// принадлежит координатору.
    func testPanelShortcutDoesNotActivateInEditMode() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = TileStore(directoryURL: directory.url)
        store.autosaves = false

        var actionCalls = 0
        let inFolder = TileDescriptor(
            id: "in-folder",
            title: "Inside",
            action: { actionCalls += 1 },
            size: .small
        )
        let folder = TileFolder(id: "folder", title: "Folder", tiles: [inFolder])
        let host = TesseraTestWindowedGrid(items: [.folder(folder)])
        host.grid.openFolder(folder, animated: false)
        host.layout()

        let coordinator = TesseraTileEditCoordinator(grid: host.grid, store: store)
        coordinator.beginEditing()
        host.layout()
        defer { coordinator.endEditing() }

        let panel = try XCTUnwrap(host.panelCell(folderID: folder.id))
        let shortcut = try XCTUnwrap(panel.shortcutCells.first)

        var tapped: [TileGridItem] = []
        host.grid.onTap = { tapped.append($0) }

        _ = shortcut.accessibilityActivate()

        XCTAssertTrue(tapped.isEmpty, "В edit-режиме действие не активируется")
        XCTAssertEqual(actionCalls, 0)
    }

    // MARK: - Магнитизм: центры слотов = рамки раскладки (E10.4, E10.1)

    /// `magnetSlotCenters(for:)` считает геометрию через
    /// `TileLayoutEngine.gridMetrics`, поэтому центры слотов совпадают с
    /// центрами фактических рамок раскладки до пикселя (раньше невыровненный
    /// юнит расходился с раскладкой).
    func testMagnetSlotCentersMatchLayoutFrames() throws {
        let smallItems = (0..<5).map {
            TileGridItem.tile(tesseraTestTile("s\($0)", size: .small))
        }
        let host = TesseraTestWindowedGrid(items: smallItems)
        host.layout()

        let centers = host.grid.magnetSlotCenters(for: .small)
        XCTAssertEqual(centers.count, 4 * 2, "Четыре колонки на две занятые строки")

        // n5: центр слота не обязан быть на пиксельной сетке (при нечётной
        // ширине юнита он попадает на полпикселя). Выравнивание гарантирует
        // раскладка — проверяем рамки элементов, а центры слотов лишь сверяем
        // с центрами этих рамок ниже.
        let scale = host.grid.traitCollection.displayScale > 0
            ? host.grid.traitCollection.displayScale
            : UIScreen.main.scale
        for item in smallItems {
            let frame = try XCTUnwrap(host.grid.frame(forItemID: item.id))
            for (value, label) in [
                (frame.minX, "minX"), (frame.minY, "minY"),
                (frame.width, "width"), (frame.height, "height"),
            ] {
                XCTAssertEqual(
                    (value * scale).rounded(),
                    value * scale,
                    accuracy: 1e-6,
                    "Рамка \(item.id): \(label) на пиксельной сетке"
                )
            }
        }

        // Первая строка занята четырьмя small-плитками: центры их слотов —
        // в точности центры рамок раскладки.
        for index in 0..<4 {
            let frame = try XCTUnwrap(host.grid.frame(forItemID: "s\(index)"))
            XCTAssertEqual(centers[index].x, frame.midX, accuracy: 1e-6)
            XCTAssertEqual(centers[index].y, frame.midY, accuracy: 1e-6)
        }
    }

    /// Для medium-плитки центр слота совпадает с центром её рамки (2×2 юнита), в
    /// том числе при нестандартных полях: горизонталь повторяет раскладку.
    func testMagnetSlotCentersMatchLayoutFramesWithInsets() throws {
        let medium = tesseraTestTile("m", size: .medium)
        let items: [TileGridItem] = [
            .tile(medium),
            .tile(tesseraTestTile("s0", size: .small)),
            .tile(tesseraTestTile("s1", size: .small)),
        ]
        let host = TesseraTestWindowedGrid(items: items)
        host.grid.contentInsets = UIEdgeInsets(top: 10, left: 21, bottom: 10, right: 9)
        host.grid.invalidateTileLayout(animated: false)
        host.layout()

        let centers = host.grid.magnetSlotCenters(for: .medium)
        XCTAssertEqual(centers.count, 3, "Две строки: medium помещается в трёх колонках")

        let expected = try XCTUnwrap(host.grid.frame(forItemID: medium.id))
        XCTAssertEqual(centers[0].x, expected.midX, accuracy: 1e-6)
        XCTAssertEqual(centers[0].y, expected.midY, accuracy: 1e-6)
    }

    // MARK: - Публичная пауза live-контента (E10.4, остаток T1)

    /// Пока START за кадром, `grid.update` в обход контроллера не возобновляет
    /// live-плитки: пауза принадлежит сетке и учитывается в конфигурации ячеек.
    func testLiveTilesStayPausedAfterGridUpdateWhileStartOffScreen() throws {
        let screen = TesseraStartScreenViewController()
        screen.configure(leftPanel: nil, rightPage: { UIViewController() })
        screen.gridView.liveTileConfiguration = TesseraLiveTileEngine.Configuration(
            cycleInterval: 0.8,
            flipDuration: 0.1,
            batchSize: 10,
            batchStagger: 0,
            jitter: 0,
            seed: 1
        )

        let live = tesseraTestLiveTile(
            "live",
            front: TesseraLiveTileFace(title: "Front"),
            back: TesseraLiveTileFace(title: "Back")
        )
        let first = tesseraTestTile("first", size: .small)
        let second = tesseraTestTile("second", size: .small)
        // Medium live + small в той же строке: добавление второго small не
        // меняет высоту контента — сценарий из остатка T1 (layout не
        // перезапускается, паузу применяет только сетка).
        screen.reload(grid: TileGridSnapshot(items: [.tile(live), .tile(first)], unpinned: []))
        let window = host(screen)
        appear(screen)

        let liveView = try XCTUnwrap(
            firstSubview(of: TesseraLiveTileView.self, in: screen.gridView),
            "Live-плитка показана на START"
        )
        XCTAssertEqual(liveView.side, .front)

        screen.showPage(.applications, animated: false)
        layout(screen)
        XCTAssertEqual(screen.currentPage, .applications)
        XCTAssertTrue(
            screen.gridView.isLiveContentPaused,
            "START за кадром — публичная пауза live-контента включена"
        )

        // Обновление в обход контроллера — остаток T1: раньше `willDisplay`
        // новой ячейки регистрировал её видимой и флип возобновлялся.
        screen.gridView.update(
            snapshot: TileGridSnapshot(
                items: [.tile(live), .tile(first), .tile(second)],
                unpinned: []
            ),
            animated: false
        )
        spin(1.3)

        let liveViewAfter = try XCTUnwrap(
            firstSubview(of: TesseraLiveTileView.self, in: screen.gridView)
        )
        XCTAssertTrue(liveViewAfter === liveView, "Ячейка live-плитки сохранена")
        XCTAssertEqual(liveViewAfter.side, .front, "START за кадром — флипов нет")
        XCTAssertFalse(liveViewAfter.isFlipping)

        // Возврат на START возобновляет расписание.
        screen.showPage(.start, animated: false)
        XCTAssertFalse(screen.gridView.isLiveContentPaused)
        XCTAssertTrue(
            waitUntil(timeout: 3) { liveView.side == .back || liveView.isFlipping },
            "На START расписание флипов возобновляется"
        )
        window.isHidden = true
    }

    // MARK: - Помощники контроллера (§4, §8)

    private let screenSize = CGSize(width: 390, height: 844)

    /// Встраивает экран в окно и доводит раскладку (без appearance).
    ///
    /// - Parameter screen: Экран рабочего стола.
    /// - Returns: Окно, удерживаемое до `tearDown`.
    private func host(_ screen: TesseraStartScreenViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: screenSize))
        window.isHidden = false
        windows.append(window)

        screen.loadViewIfNeeded()
        screen.view.frame = window.bounds
        window.addSubview(screen.view)
        layout(screen)
        return window
    }

    /// Доводит раскладку экрана и его сетки.
    ///
    /// - Parameter screen: Экран рабочего стола.
    private func layout(_ screen: TesseraStartScreenViewController) {
        screen.view.layoutIfNeeded()
        screen.gridView.superview?.layoutIfNeeded()
        screen.gridView.layoutIfNeeded()
        screen.gridView.subviews
            .compactMap { $0 as? UICollectionView }
            .forEach { $0.layoutIfNeeded() }
    }

    /// Сообщает экрану о появлении (двойной appearance идемпотентен).
    ///
    /// - Parameter screen: Экран рабочего стола.
    private func appear(_ screen: TesseraStartScreenViewController) {
        screen.beginAppearanceTransition(true, animated: false)
        screen.endAppearanceTransition()
    }

    /// Прокручивает run loop заданное время.
    ///
    /// - Parameter seconds: Длительность ожидания.
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Ждёт выполнения условия, прокручивая run loop.
    ///
    /// - Parameters:
    ///   - timeout: Максимальное ожидание.
    ///   - condition: Условие готовности.
    /// - Returns: `true`, если условие выполнилось.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// Первый подвид заданного типа в иерархии.
    ///
    /// - Parameters:
    ///   - type: Тип подвида.
    ///   - root: Корень поиска.
    /// - Returns: Найденный вид или `nil`.
    private func firstSubview<T: UIView>(of type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }
}

#endif
