//
//  TesseraRTLTests.swift
//  TesseraCoreTests
//
//  Контрактные тесты нормализации прогресса по направлению чтения (задача E1.7).
//  Проектный документ: docs/Core-iOS-Design.md §2 «Ключевые контракты»
//  («Инвариант прогресса: t = offset.x / pageWidth; в RTL t нормализуется от
//  направления чтения») и §3 «Концептуальная поверхность API»
//  (TesseraAccessibility / TesseraRTL — утилиты).
//
//  Проверяются обе чистые функции: непрерывный `normalizedProgress` и дискретный
//  `pageIndex` — в LTR и RTL, на границах и для `pageCount <= 1`.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraCore

final class TesseraRTLTests: XCTestCase {

    private let ltr = UIUserInterfaceLayoutDirection.leftToRight
    private let rtl = UIUserInterfaceLayoutDirection.rightToLeft

    // MARK: - normalizedProgress: LTR

    /// В LTR сырой прогресс отдаётся без изменений, включая дробные значения
    /// и выход за диапазон при bounce.
    func testNormalizedProgressIsIdentityInLTR() {
        let values: [CGFloat] = [-0.5, 0, 0.25, 1, 1.5, 2, 3.75, 4, 4.5]

        for value in values {
            XCTAssertEqual(
                TesseraRTL.normalizedProgress(value, pageCount: 5, layoutDirection: ltr),
                value,
                "LTR не должен менять прогресс \(value)"
            )
        }
    }

    // MARK: - normalizedProgress: RTL

    /// В RTL прогресс зеркалится относительно середины ленты:
    /// `pageCount - 1 - t`; непрерывность и знак сохраняются.
    func testNormalizedProgressMirrorsInRTL() {
        let cases: [(input: CGFloat, expected: CGFloat)] = [
            (0, 4),
            (0.5, 3.5),
            (1, 3),
            (1.5, 2.5),
            (2, 2),
            (3.25, 0.75),
            (4, 0),
            (4.5, -0.5),
            (-0.5, 4.5),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraRTL.normalizedProgress(
                    entry.input,
                    pageCount: 5,
                    layoutDirection: rtl
                ),
                entry.expected,
                "RTL-зеркалирование прогресса \(entry.input)"
            )
        }
    }

    /// Для двух страниц RTL-зеркалирование сводится к `1 - t`.
    func testNormalizedProgressMirrorsTwoPagesInRTL() {
        XCTAssertEqual(
            TesseraRTL.normalizedProgress(0, pageCount: 2, layoutDirection: rtl),
            1
        )
        XCTAssertEqual(
            TesseraRTL.normalizedProgress(0.5, pageCount: 2, layoutDirection: rtl),
            0.5
        )
        XCTAssertEqual(
            TesseraRTL.normalizedProgress(1, pageCount: 2, layoutDirection: rtl),
            0
        )
    }

    /// `pageCount <= 1` — нормализовать нечего: прогресс возвращается как есть
    /// в обоих направлениях.
    func testNormalizedProgressWithSinglePageIsIdentity() {
        for count in [1, 0, -3] {
            for direction in [ltr, rtl] {
                XCTAssertEqual(
                    TesseraRTL.normalizedProgress(0.75, pageCount: count, layoutDirection: direction),
                    0.75,
                    "count=\(count), direction=\(direction)"
                )
            }
        }
    }

    // MARK: - pageIndex: LTR

    /// LTR: индекс — целая часть прогресса с клампом в `0...pageCount - 1`.
    func testPageIndexInLTRFloorsAndClamps() {
        let cases: [(input: CGFloat, expected: Int)] = [
            (0, 0),
            (0.99, 0),
            (1, 1),
            (1.99, 1),
            (2.5, 2),
            (4, 4),
            (4.99, 4),
            (100, 4),
            (-100, 0),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraRTL.pageIndex(for: entry.input, pageCount: 5, layoutDirection: ltr),
                entry.expected,
                "LTR-индекс для t=\(entry.input)"
            )
        }
    }

    // MARK: - pageIndex: RTL

    /// RTL: сначала берётся физический индекс (floor + кламп), затем он
    /// зеркалится в порядок чтения: `pageCount - 1 - index`.
    func testPageIndexInRTLMirrorsPhysicalIndex() {
        let cases: [(input: CGFloat, expected: Int)] = [
            (0, 4),
            (0.99, 4),
            (1, 3),
            (1.99, 3),
            (2, 2),
            (3, 1),
            (4, 0),
            (4.99, 0),
            (-0.5, 4),
            (-10, 4),
            (10, 0),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraRTL.pageIndex(for: entry.input, pageCount: 5, layoutDirection: rtl),
                entry.expected,
                "RTL-индекс для t=\(entry.input)"
            )
        }
    }

    /// Для двух страниц RTL-индекс — это `1 - floor(t)` в границах.
    func testPageIndexWithTwoPagesInRTL() {
        XCTAssertEqual(TesseraRTL.pageIndex(for: 0, pageCount: 2, layoutDirection: rtl), 1)
        XCTAssertEqual(TesseraRTL.pageIndex(for: 0.9, pageCount: 2, layoutDirection: rtl), 1)
        XCTAssertEqual(TesseraRTL.pageIndex(for: 1, pageCount: 2, layoutDirection: rtl), 0)
        XCTAssertEqual(TesseraRTL.pageIndex(for: 1.5, pageCount: 2, layoutDirection: rtl), 0)
    }

    // MARK: - pageIndex: защитные случаи

    /// `pageCount <= 1`: индекс всегда 0 — единственная страница одновременно
    /// первая и последняя.
    func testPageIndexWithSinglePageIsAlwaysZero() {
        for count in [1, 0, -3] {
            for direction in [ltr, rtl] {
                XCTAssertEqual(
                    TesseraRTL.pageIndex(for: 2.5, pageCount: count, layoutDirection: direction),
                    0,
                    "count=\(count), direction=\(direction)"
                )
            }
        }
    }

    /// `NaN` в LTR трактуется как первая страница (0).
    func testPageIndexNaNIsZeroInLTR() {
        XCTAssertEqual(
            TesseraRTL.pageIndex(for: .nan, pageCount: 5, layoutDirection: ltr),
            0
        )
    }

    /// Бесконечности зажимаются границами без переполнения `Int`.
    func testPageIndexInfinityClampsToBoundaries() {
        XCTAssertEqual(
            TesseraRTL.pageIndex(for: .infinity, pageCount: 5, layoutDirection: ltr),
            4
        )
        XCTAssertEqual(
            TesseraRTL.pageIndex(for: -.infinity, pageCount: 5, layoutDirection: ltr),
            0
        )
    }
}

#endif
