//
//  TileGridReduceMotionTests.swift
//  TesseraStartScreenTests
//
//  Reduce Motion при применении снимка сетки (E9.4 и подтверждение E10.14,
//  волна W3 плана E9/E10).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §9 «Accessibility»
//  (Reduce Motion: нет флипов, «желе», параллакса; анимации не проигрываются);
//  STATE.md, решение по E9.4: кроссфейд смены состава сетки учитывает
//  настройку.
//
//  E10.14: ветка кроссфейда с `animated: true` достижима только после
//  `guard shouldAnimate`, потому что `shouldAnimate` включает
//  `!isReduceMotionEnabled()`. Тесты подтверждают, что при Reduce Motion
//  снимок применяется без кроссфейда (и сразу — состав уже новый), а без
//  Reduce Motion кроссфейд выполняется. Провайдер Reduce Motion — внутренний
//  шов сетки (`isReduceMotionEnabled`), системная настройка не меняется.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileGridReduceMotionTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Сетка с составом `[a, b]` в окне: кроссфейд возможен только на экране.
    private func makeHost() -> TesseraTestWindowedGrid {
        let host = TesseraTestWindowedGrid(
            items: [.tile(tesseraTestTile("a", size: .small)),
                    .tile(tesseraTestTile("b", size: .small))]
        )
        host.layout()
        return host
    }

    /// Снимок с добавленным ярлыком `c` (смена состава).
    private func snapshotWithExtraTile() -> TileGridSnapshot {
        TileGridSnapshot(
            items: [
                .tile(tesseraTestTile("a", size: .small)),
                .tile(tesseraTestTile("b", size: .small)),
                .tile(tesseraTestTile("c", size: .small)),
            ],
            unpinned: []
        )
    }

    // MARK: - Кроссфейд смены состава (E9.4, E10.14)

    /// Без Reduce Motion смена состава применяется кроссфейдом: снимок
    /// действительно анимируется, а не подменяется молча.
    func testCompositionChangeCrossfadesWithoutReduceMotion() {
        let host = makeHost()
        host.grid.isReduceMotionEnabled = { false }

        host.grid.update(snapshot: snapshotWithExtraTile(), animated: true)
        host.layout()

        XCTAssertTrue(
            host.grid.didApplyLastSnapshotWithCrossfade,
            "Без Reduce Motion кроссфейд выполняется"
        )
        XCTAssertEqual(host.grid.items.count, 3)
        XCTAssertEqual(
            host.grid.items.map { $0.id },
            [AnyHashable("a"), AnyHashable("b"), AnyHashable("c")]
        )
    }

    /// При Reduce Motion тот же вызов идёт без кроссфейда: снимок применяется
    /// сразу, состав уже новый к моменту возврата из `update`.
    func testCompositionChangeSkipsCrossfadeUnderReduceMotion() {
        let host = makeHost()
        host.grid.isReduceMotionEnabled = { true }

        host.grid.update(snapshot: snapshotWithExtraTile(), animated: true)
        host.layout()

        XCTAssertFalse(
            host.grid.didApplyLastSnapshotWithCrossfade,
            "Reduce Motion отключает кроссфейд"
        )
        XCTAssertEqual(host.grid.items.count, 3)
        XCTAssertEqual(
            host.grid.items.map { $0.id },
            [AnyHashable("a"), AnyHashable("b"), AnyHashable("c")]
        )
    }

    /// «Без анимации» (animated: false) не включает кроссфейд независимо от
    /// настройки: ветка выбирается вызывающим кодом.
    func testNonAnimatedUpdateNeverCrossfades() {
        let host = makeHost()
        host.grid.isReduceMotionEnabled = { false }

        host.grid.update(snapshot: snapshotWithExtraTile(), animated: false)
        host.layout()

        XCTAssertFalse(host.grid.didApplyLastSnapshotWithCrossfade)
        XCTAssertEqual(host.grid.items.count, 3)
    }

    /// Перезагрузка снимка (`reload(snapshot:)`) всегда без кроссфейда: это
    /// первый показ/полная замена данных, а не анимированное изменение.
    func testReloadNeverCrossfades() {
        let host = makeHost()
        host.grid.isReduceMotionEnabled = { false }

        host.grid.reload(snapshot: snapshotWithExtraTile())
        host.layout()

        XCTAssertFalse(host.grid.didApplyLastSnapshotWithCrossfade)
        XCTAssertEqual(host.grid.items.count, 3)
    }

    // MARK: - Reduce Motion и панель папки (E10.2)

    /// При Reduce Motion раскрытие панели идёт неанимированной веткой сетки:
    /// состояние применяется сразу, без `isFolderChangeAnimating`.
    func testFolderExpansionAppliesImmediatelyUnderReduceMotion() {
        let folder = tesseraTestFolder("folder", tileCount: 3)
        let host = TesseraTestWindowedGrid(items: [.folder(folder)])
        host.grid.isReduceMotionEnabled = { true }

        host.grid.openFolder(folder, animated: true)
        host.layout()

        XCTAssertEqual(host.grid.expandedFolderID, folder.id)
        XCTAssertFalse(
            host.grid.isFolderChangeAnimating,
            "Reduce Motion не запускает анимацию панели"
        )
        XCTAssertTrue(host.grid.isScrollEnabled, "Прокрутка не блокируется")
    }
}

#endif
