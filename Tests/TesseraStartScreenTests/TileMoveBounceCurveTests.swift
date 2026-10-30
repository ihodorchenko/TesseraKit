//
//  TileMoveBounceCurveTests.swift
//  TesseraStartScreenTests
//
//  Тесты bounce-кривой перемещения плиток (задача E8.8).
//  Проектный документ: docs/PLAN.md, E8.8 — движения соседей при перестановке
//  заканчиваются лёгким «отскоком» `cubic-bezier(0.175, 0.885, 0.32, 1.1)`,
//  без резких прыжков.
//
//  Проверяются контрольные точки общей фабрики и выбранная длительность:
//  чистая логика, UI-цикл и таймеры не нужны. Кривая панели папки
//  (`cubic-bezier(0.1, 0.9, 0.2, 1)`) этой задачей не меняется и здесь не
//  проверяется — её контракт остаётся за E7.3/D17.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileMoveBounceCurveTests: XCTestCase {

    /// Контрольные точки фабрики совпадают со спецификацией E8.8.
    func testBounceControlPointsMatchSpecification() {
        let timing = TesseraTileGridView.bounceTimingParameters()

        XCTAssertEqual(timing.controlPoint1.x, 0.175, accuracy: 1e-9)
        XCTAssertEqual(timing.controlPoint1.y, 0.885, accuracy: 1e-9)
        XCTAssertEqual(timing.controlPoint2.x, 0.32, accuracy: 1e-9)
        XCTAssertEqual(timing.controlPoint2.y, 1.1, accuracy: 1e-9)
    }

    /// `controlPoint2.y > 1` — кривая перелетает цель, то есть это именно
    /// «отскок», а не обычное торможение.
    func testCurveOvershootsTarget() {
        let timing = TesseraTileGridView.bounceTimingParameters()

        XCTAssertGreaterThan(
            timing.controlPoint2.y,
            1,
            "Кривая должна перелетать цель, иначе отскока не будет"
        )
    }

    /// Длительность попадает в задокументированное окно E8.8 (0,22–0,28 с).
    func testTileMoveDurationIsInsideDocumentedWindow() {
        let duration = TesseraTileGridView.tileMoveDuration

        XCTAssertGreaterThanOrEqual(duration, 0.22)
        XCTAssertLessThanOrEqual(duration, 0.28)
    }

    /// Переезд соседей короче раскрытия панели папки: кривую и длительность
    /// D17 (0,28 с) задача E8.8 не трогает.
    func testTileMoveIsShorterThanFolderExpansion() {
        XCTAssertLessThan(
            TesseraTileGridView.tileMoveDuration,
            TesseraTileGridView.folderExpansionDuration
        )
    }

    /// Фабрика детерминирована: повторный вызов даёт те же контрольные точки.
    func testFactoryIsDeterministic() {
        let first = TesseraTileGridView.bounceTimingParameters()
        let second = TesseraTileGridView.bounceTimingParameters()

        XCTAssertEqual(first.controlPoint1, second.controlPoint1)
        XCTAssertEqual(first.controlPoint2, second.controlPoint2)
    }
}

#endif
