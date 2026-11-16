//
//  PivotRTLTests.swift
//  TesseraPivotTests
//
//  Контрактные тесты RTL пивота (задача E2.7).
//  Проектный документ: docs/PIVOT-IOS-DESIGN.md §8 «Accessibility и системная
//  интеграция» (в RTL зеркалится всё — порядок заголовков и направление свайпа)
//  и §4 «Математика ядра» (индикатор интерполируется по центрам в порядке
//  чтения). Нормализация прогресса и индексов — общий контракт Core
//  (docs/CORE-IOS-DESIGN.md §2, «Инвариант прогресса»): пивот не дублирует
//  зеркалирование, а работает с `TesseraRTL`-нормализованными значениями.
//
//  Проверяются: нормализация `t` и индексов через `TesseraRTL` в LTR и RTL;
//  чтение заголовков/выделения в порядке чтения; зеркалирование физических
//  слотов пейджера при программном переходе; инверсия VoiceOver-жеста в RTL.
//

#if canImport(UIKit)

import XCTest
import UIKit
import TesseraCore
@testable import TesseraPivot

final class PivotRTLTests: XCTestCase {

    private let ltr = UIUserInterfaceLayoutDirection.leftToRight
    private let rtl = UIUserInterfaceLayoutDirection.rightToLeft
    private let pivotSize = CGSize(width: 320, height: 640)

    // MARK: - Вспомогательные средства

    private func makeSections(count: Int) -> [TesseraPivotSection] {
        (0..<count).map { index in
            TesseraPivotSection(id: index, title: "Секция \(index)") {
                UIViewController()
            }
        }
    }

    /// Пивот с принудительным RTL: направление задаётся до первого layout'а,
    /// потому что физические слоты страниц рассчитываются в нём (§8).
    private func makeLoadedRTLPivot(
        sectionCount: Int = 4
    ) throws -> (pivot: TesseraPivotViewController, scrollView: UIScrollView) {
        let pivot = TesseraPivotViewController(sections: makeSections(count: sectionCount))
        pivot.loadViewIfNeeded()

        pivot.view.semanticContentAttribute = .forceRightToLeft
        pivot.pagerViewController.view.semanticContentAttribute = .forceRightToLeft

        pivot.view.frame = CGRect(origin: .zero, size: pivotSize)
        pivot.view.layoutIfNeeded()

        let scrollView = try XCTUnwrap(
            pivot.pagerViewController.view.subviews
                .compactMap { $0 as? UIScrollView }
                .first,
            "Пейджер пивота обязан содержать UIScrollView"
        )
        return (pivot, scrollView)
    }

    // MARK: - Нормализация прогресса (§4, TesseraRTL)

    /// LTR: прогресс секций — сырой `contentOffset.x / pageWidth` без изменений.
    func testNormalizedProgressIsIdentityInLTR() {
        let cases: [(raw: CGFloat, expected: CGFloat)] = [
            (0, 0),
            (0.5, 0.5),
            (1, 1),
            (1.5, 1.5),
            (2, 2),
            (2.5, 2.5),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraRTL.normalizedProgress(
                    entry.raw,
                    pageCount: 3,
                    layoutDirection: ltr
                ),
                entry.expected,
                "LTR не должен зеркалировать t=\(entry.raw)"
            )
        }
    }

    /// RTL: прогресс зеркалится относительно середины ленты —
    /// `pageCount - 1 - t`, поэтому `0` остаётся первой секцией для
    /// пользователя (§8, §4).
    func testNormalizedProgressMirrorsSectionsInRTL() {
        let cases: [(raw: CGFloat, expected: CGFloat)] = [
            (0, 2),
            (0.5, 1.5),
            (1, 1),
            (1.5, 0.5),
            (2, 0),
            (-0.5, 2.5),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraRTL.normalizedProgress(
                    entry.raw,
                    pageCount: 3,
                    layoutDirection: rtl
                ),
                entry.expected,
                "RTL-зеркалирование t=\(entry.raw)"
            )
        }
    }

    /// LTR: индекс — целая часть прогресса с клампом (правило «целая часть —
    /// индекс», docs/CORE-IOS-DESIGN.md §2).
    func testPageIndexInLTRFloorsRawProgress() {
        let cases: [(raw: CGFloat, expected: Int)] = [
            (0, 0),
            (0.99, 0),
            (1, 1),
            (1.99, 1),
            (2.5, 2),
            (3, 3),
            (3.99, 3),
            (99, 3),
            (-1, 0),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraRTL.pageIndex(for: entry.raw, pageCount: 4, layoutDirection: ltr),
                entry.expected,
                "LTR-индекс для t=\(entry.raw)"
            )
        }
    }

    /// RTL: сначала берётся физический слот (floor + кламп), затем он
    /// зеркалится в порядок чтения — индекс всегда в порядке чтения (§8).
    func testPageIndexInRTLMapsPhysicalSlotToReadingIndex() {
        let cases: [(raw: CGFloat, expected: Int)] = [
            (0, 3),
            (0.99, 3),
            (1, 2),
            (2, 1),
            (3, 0),
            (99, 0),
            (-1, 3),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraRTL.pageIndex(for: entry.raw, pageCount: 4, layoutDirection: rtl),
                entry.expected,
                "RTL-индекс для t=\(entry.raw)"
            )
        }
    }

    // MARK: - Индикатор в порядке чтения (§4)

    /// В RTL центры заголовков приходят в порядке чтения, то есть убывают по
    /// координате: секция `0` — крайняя правая. Интерполяция обязана работать
    /// с этими центрами как есть, без повторного зеркалирования.
    func testIndicatorInterpolatesMirroredCentersInReadingOrder() {
        // Секции 0, 1, 2: центры в координатах контента RTL-ленты.
        let centers: [CGFloat] = [300, 160, 40]

        let cases: [(t: CGFloat, expected: CGFloat)] = [
            (0, 300),
            (0.5, 230),
            (1, 160),
            (1.5, 100),
            (2, 40),
            // Кламп на bounce: за границами — крайние секции, а не «уезд».
            (3.5, 40),
            (-1, 300),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraPivotHeaderIndicator.indicatorCenter(centers: centers, progress: entry.t),
                entry.expected,
                accuracy: 0.000_001,
                "t=\(entry.t) в RTL-геометрии"
            )
        }
    }

    // MARK: - Лента: порядок чтения в LTR и RTL

    /// `titles` — всегда порядок чтения: RTL меняет только визуальную
    /// раскладку, а не модель данных (§8).
    func testStripKeepsTitlesInReadingOrderInBothDirections() {
        for attribute: UISemanticContentAttribute in [.forceLeftToRight, .forceRightToLeft] {
            let strip = TesseraPivotHeaderStripView(
                frame: CGRect(x: 0, y: 0, width: 320, height: 48)
            )
            strip.semanticContentAttribute = attribute
            strip.titles = ["Один", "Два", "Три"]

            XCTAssertEqual(
                strip.titles,
                ["Один", "Два", "Три"],
                "порядок заголовков не зависит от направления раскладки"
            )
        }
    }

    /// Выделение ленты — в порядке чтения: прогресс `t` в RTL-режиме уже
    /// нормализован Core, поэтому `selectedIndex` не зависит от направления.
    func testStripSelectionUsesReadingOrderInRTL() {
        let strip = TesseraPivotHeaderStripView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 48)
        )
        strip.semanticContentAttribute = .forceRightToLeft
        strip.titles = ["Один", "Два", "Три", "Четыре"]

        let cases: [(t: CGFloat, expected: Int)] = [
            (0, 0),
            (0.49, 0),
            (0.5, 1),
            (1.5, 2),
            (3, 3),
            (10, 3),
        ]

        for entry in cases {
            strip.apply(progress: entry.t)
            XCTAssertEqual(
                strip.selectedIndex,
                entry.expected,
                "t=\(entry.t) в RTL должен выделять секцию чтения \(entry.expected)"
            )
        }
    }

    // MARK: - Пивот в RTL: физические слоты и жест VoiceOver

    /// Программный переход использует зеркальные физические слоты: секция
    /// чтения `0` живёт в крайнем правом слоте, `index` наружу остаётся в
    /// порядке чтения (§5, §8).
    func testPivotSelectSectionUsesMirroredSlotsInRTL() throws {
        let (pivot, scrollView) = try makeLoadedRTLPivot(sectionCount: 4)
        let pageWidth = scrollView.bounds.width

        // Стартовая секция чтения 0 занимает физический слот 3.
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 3, accuracy: 0.5)

        pivot.selectSection(at: 1, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2, accuracy: 0.5)
        XCTAssertEqual(pivot.currentSectionIndex, 1, "индекс — в порядке чтения")
        XCTAssertEqual(pivot.headerStripView.selectedIndex, 1)

        pivot.selectSection(at: 3, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, 0, accuracy: 0.5)
        XCTAssertEqual(pivot.currentSectionIndex, 3)
    }

    /// VoiceOver-жест в RTL инвертируется относительно LTR: в LTR свайп влево
    /// листает вперёд (конвенция UIKit, E9.3), поэтому в RTL вперёд по чтению
    /// ведёт «вправо», а «влево» с первой секции — назад, за границу набора (§8).
    func testPivotAccessibilityScrollInvertsDirectionInRTL() throws {
        let (pivot, _) = try makeLoadedRTLPivot(sectionCount: 3)

        XCTAssertFalse(
            pivot.accessibilityScroll(.left),
            "В RTL «влево» — назад, с первой секции некуда"
        )
        XCTAssertTrue(pivot.accessibilityScroll(.right))
        XCTAssertEqual(pivot.currentSectionIndex, 1)

        XCTAssertTrue(pivot.accessibilityScroll(.left))
        XCTAssertEqual(pivot.currentSectionIndex, 0)
    }
}

#endif
