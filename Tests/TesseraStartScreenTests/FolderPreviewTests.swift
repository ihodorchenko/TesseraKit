//
//  FolderPreviewTests.swift
//  TesseraStartScreenTests
//
//  Тесты превью закрытой папки (задача E7.4, решение D17).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка»;
//  D17 в docs/STATE.md — закрытая папка показывает мини-сетку 2×2 из первых
//  четырёх иконок содержимого.
//
//  Отдельной чистой функции «первые четыре» в API нет: выбор делает
//  `TesseraFolderPreviewView.configure(tiles:schedule:)` (и такой же `prefix(4)`
//  в `TesseraTileCell` перед вызовом). Поэтому контракт проверяется на уровне
//  значения-вью без окна: число мини-плиток и их бэйджи как наблюдаемый признак
//  порядка. Таймер флипа не запускается — превью не в окне.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class FolderPreviewTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Ярлыки с уникальными идентификаторами и заданными бэйджами.
    ///
    /// - Parameter badges: Бэйджи в порядке ярлыков.
    /// - Returns: Массив ярлыков «t0», «t1», …
    private func makeTiles(_ badges: [TesseraTileBadge]) -> [TesseraTileDescriptor] {
        badges.enumerated().map { index, badge in
            tesseraTestTile("t\(index)", badge: badge)
        }
    }

    /// Превью без окна: расписание не запускается.
    ///
    /// - Returns: Пустое превью.
    private func makePreview() -> TesseraFolderPreviewView {
        TesseraFolderPreviewView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
    }

    /// Применяет ярлыки с фиксированным seed расписания.
    ///
    /// - Parameters:
    ///   - preview: Превью.
    ///   - tiles: Ярлыки папки в порядке отображения.
    private func configure(_ preview: TesseraFolderPreviewView, tiles: [TesseraTileDescriptor]) {
        preview.configure(tiles: tiles, schedule: TesseraFolderFlipSchedule(seed: 7))
    }

    // MARK: - Выбор первых четырёх

    /// Пустая папка не создаёт мини-плиток.
    func testEmptyFolderShowsNoMiniTiles() {
        let preview = makePreview()

        configure(preview, tiles: [])

        XCTAssertTrue(preview.miniTileViews.isEmpty)
    }

    /// Меньше четырёх ярлыков — показываются все, в порядке папки.
    func testFewerThanFourTilesAreShownInOrder() {
        let preview = makePreview()
        let tiles = makeTiles([.dot, .count(3), .none])

        configure(preview, tiles: tiles)

        XCTAssertEqual(preview.miniTileViews.map { $0.badge }, [.dot, .count(3), .none])
    }

    /// Ровно четыре ярлыка — все четыре.
    func testFourTilesAreAllShown() {
        let preview = makePreview()
        let tiles = makeTiles([.count(1), .count(2), .count(3), .count(4)])

        configure(preview, tiles: tiles)

        XCTAssertEqual(preview.miniTileViews.count, 4)
        XCTAssertEqual(
            preview.miniTileViews.map { $0.badge },
            [.count(1), .count(2), .count(3), .count(4)]
        )
    }

    /// Больше четырёх — берутся именно первые четыре, а не последние.
    func testMoreThanFourTilesUseFirstFourOnly() {
        let preview = makePreview()
        let tiles = makeTiles((0..<6).map { .count(100 + $0) })

        configure(preview, tiles: tiles)

        XCTAssertEqual(preview.miniTileViews.count, 4)
        XCTAssertEqual(
            preview.miniTileViews.map { $0.badge },
            [.count(100), .count(101), .count(102), .count(103)]
        )
        XCTAssertFalse(preview.miniTileViews.contains { $0.badge == .count(104) })
    }

    /// Уменьшение папки убирает лишние мини-плитки (переиспользование вью).
    func testReconfigureWithFewerTilesRemovesExtraViews() {
        let preview = makePreview()
        configure(preview, tiles: makeTiles((0..<5).map { .count($0 + 1) }))
        XCTAssertEqual(preview.miniTileViews.count, 4)

        configure(preview, tiles: makeTiles([.dot, .count(2)]))

        XCTAssertEqual(preview.miniTileViews.count, 2)
        XCTAssertEqual(preview.miniTileViews.map { $0.badge }, [.dot, .count(2)])
    }

    /// Повторная конфигурация с тем же содержимым идемпотентна: фаза не
    /// сбрасывается, вью не пересоздаются.
    func testReconfigureWithSameTilesKeepsViews() {
        let preview = makePreview()
        let tiles = makeTiles([.count(1), .count(2), .count(3), .count(4)])
        configure(preview, tiles: tiles)
        let firstMiniTile = preview.miniTileViews.first

        configure(preview, tiles: tiles)

        XCTAssertEqual(preview.miniTileViews.count, 4)
        XCTAssertTrue(preview.miniTileViews.first === firstMiniTile)
    }

    /// Настоящее изменение состава обновляет содержимое мини-плиток.
    ///
    /// Сами вью переиспользуются (лишние удаляются, недостающие добавляются):
    /// тест фиксирует содержимое, а не идентичность вью.
    func testReconfigureWithDifferentTilesUpdatesContent() {
        let preview = makePreview()
        configure(preview, tiles: makeTiles([.count(1), .count(2)]))

        configure(preview, tiles: makeTiles([.dot, .count(7), .count(8)]))

        XCTAssertEqual(preview.miniTileViews.count, 3)
        XCTAssertEqual(preview.miniTileViews.map { $0.badge }, [.dot, .count(7), .count(8)])
    }
}

#endif
