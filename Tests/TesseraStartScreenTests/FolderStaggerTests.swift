//
//  FolderStaggerTests.swift
//  TesseraStartScreenTests
//
//  Тесты каскада иконок панели раскрытой папки (задача E7.4, решение D17).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка»,
//  §9 «Reduce Motion»; D17 в docs/STATE.md — иконки появляются каскадом
//  ~35 мс на индекс.
//
//  `TesseraTileGridView.staggerDelay(index:)` — чистая функция: проверяются
//  неотрицательность, монотонность, линейность и детерминизм. Таймеры и
//  UI-цикл не нужны.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class FolderStaggerTests: XCTestCase {

    /// Нулевой и отрицательные индексы не задерживают появление иконки.
    func testZeroAndNegativeIndicesHaveNoDelay() {
        XCTAssertEqual(TesseraTileGridView.staggerDelay(index: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(TesseraTileGridView.staggerDelay(index: -1), 0, accuracy: 1e-12)
        XCTAssertEqual(TesseraTileGridView.staggerDelay(index: -100), 0, accuracy: 1e-12)
    }

    /// Задержка линейна по индексу: `index × folderIconStagger`.
    func testDelayIsLinearInIndex() {
        for index in 0...12 {
            XCTAssertEqual(
                TesseraTileGridView.staggerDelay(index: index),
                TimeInterval(index) * TesseraTileGridView.folderIconStagger,
                accuracy: 1e-12,
                "Индекс \(index)"
            )
        }
    }

    /// Задержка неотрицательна и не убывает с ростом индекса.
    func testDelayIsNonNegativeAndMonotonic() {
        var previous: TimeInterval = 0

        for index in 0...64 {
            let delay = TesseraTileGridView.staggerDelay(index: index)
            XCTAssertGreaterThanOrEqual(delay, 0, "Индекс \(index)")
            XCTAssertGreaterThanOrEqual(delay, previous, "Индекс \(index)")
            previous = delay
        }
    }

    /// Функция детерминирована: повторный вызов даёт то же значение.
    func testDelayIsDeterministic() {
        for index in [0, 1, 3, 4, 9, 25, 100] {
            XCTAssertEqual(
                TesseraTileGridView.staggerDelay(index: index),
                TesseraTileGridView.staggerDelay(index: index)
            )
        }
    }

    /// Константа каскада — положительная микро-задержка из D17 (35 мс).
    func testStaggerConstantIsMicroDelay() {
        XCTAssertEqual(TesseraTileGridView.folderIconStagger, 0.035, accuracy: 1e-9)
        XCTAssertGreaterThan(TesseraTileGridView.folderIconStagger, 0)
        XCTAssertLessThan(TesseraTileGridView.folderIconStagger, 0.1)
    }
}

#endif
