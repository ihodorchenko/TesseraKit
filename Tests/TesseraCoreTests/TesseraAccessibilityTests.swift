//
//  TesseraAccessibilityTests.swift
//  TesseraCoreTests
//
//  Контрактные тесты accessibility-утилит (задача E1.7).
//  Проектный документ: docs/Core-iOS-Design.md §1 «Состав пакета»
//  (TesseraAccessibilityKit: пагинация, анонсы смены страницы, RTL-нормализация)
//  и §2 «Ключевые контракты» (в RTL «вперёд» — по направлению чтения).
//
//  Проверяется `pageStep(for:layoutDirection:)` для всех направлений жеста
//  VoiceOver в LTR и RTL: физические `.left`/`.right` инвертируются, порядковые
//  `.next`/`.previous` — нет (иначе получится двойное зеркалирование).
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraCore

final class TesseraAccessibilityTests: XCTestCase {

    private let ltr = UIUserInterfaceLayoutDirection.leftToRight
    private let rtl = UIUserInterfaceLayoutDirection.rightToLeft

    // MARK: - Физические направления

    /// LTR: свайп вправо — следующая страница, влево — предыдущая.
    func testPhysicalDirectionsInLTR() {
        XCTAssertEqual(TesseraAccessibility.pageStep(for: .right, layoutDirection: ltr), 1)
        XCTAssertEqual(TesseraAccessibility.pageStep(for: .left, layoutDirection: ltr), -1)
    }

    /// RTL: физические направления инвертируются — «вперёд» по направлению
    /// чтения это влево.
    func testPhysicalDirectionsInRTL() {
        XCTAssertEqual(TesseraAccessibility.pageStep(for: .right, layoutDirection: rtl), -1)
        XCTAssertEqual(TesseraAccessibility.pageStep(for: .left, layoutDirection: rtl), 1)
    }

    // MARK: - Порядковые направления

    /// `.next`/`.previous` заданы в порядке чтения и не зеркалируются повторно
    /// в RTL (иначе жест «назад» листал бы вперёд).
    func testOrdinalDirectionsAreIndependentOfLayoutDirection() {
        for direction in [ltr, rtl] {
            XCTAssertEqual(
                TesseraAccessibility.pageStep(for: .next, layoutDirection: direction),
                1,
                "next, direction=\(direction)"
            )
            XCTAssertEqual(
                TesseraAccessibility.pageStep(for: .previous, layoutDirection: direction),
                -1,
                "previous, direction=\(direction)"
            )
        }
    }

    // MARK: - Вертикальные направления

    /// Вертикальные жесты не адресованы горизонтальному пейджеру — шаг 0
    /// в обоих направлениях раскладки.
    func testVerticalDirectionsProduceZeroStep() {
        for direction in [ltr, rtl] {
            XCTAssertEqual(
                TesseraAccessibility.pageStep(for: .up, layoutDirection: direction),
                0,
                "up, direction=\(direction)"
            )
            XCTAssertEqual(
                TesseraAccessibility.pageStep(for: .down, layoutDirection: direction),
                0,
                "down, direction=\(direction)"
            )
        }
    }

    // MARK: - Полная таблица направлений

    /// Сводная проверка всех поддерживаемых направлений в обеих раскладках.
    func testPageStepTable() {
        let cases: [(direction: UIAccessibilityScrollDirection,
                     layout: UIUserInterfaceLayoutDirection,
                     expected: Int)] = [
            (.right, ltr, 1),
            (.right, rtl, -1),
            (.left, ltr, -1),
            (.left, rtl, 1),
            (.next, ltr, 1),
            (.next, rtl, 1),
            (.previous, ltr, -1),
            (.previous, rtl, -1),
            (.up, ltr, 0),
            (.up, rtl, 0),
            (.down, ltr, 0),
            (.down, rtl, 0),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraAccessibility.pageStep(
                    for: entry.direction,
                    layoutDirection: entry.layout
                ),
                entry.expected,
                "direction=\(entry.direction), layout=\(entry.layout)"
            )
        }
    }

    // MARK: - Reduce Motion

    /// Утилита Reduce Motion доступна как чтение системной настройки (тип
    /// `Bool`); значение не кешируется и не подменяется.
    func testReduceMotionFlagIsReadable() {
        let value = TesseraAccessibility.isReduceMotionEnabled
        XCTAssertEqual(value, UIAccessibility.isReduceMotionEnabled)
    }

    /// Пустая строка анонса игнорируется — метод не падает и ничего не постит.
    func testEmptyAnnouncementIsIgnored() {
        TesseraAccessibility.announcePageChange("")
    }
}

#endif
