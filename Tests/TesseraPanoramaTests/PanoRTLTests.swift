//
//  PanoRTLTests.swift
//  TesseraPanoramaTests
//
//  Контрактные тесты RTL-геометрии панорамы (задача E3.7).
//  Проектный документ: docs/PANORAMA-IOS-DESIGN.md §7 «Accessibility и
//  системная интеграция» («RTL: прогресс t и направление снапа считаются от
//  направления чтения») и §4 «Геометрия и математика ядра» (шаг секции
//  `itemWidth = screenWidth − peek`, а не ширина экрана).
//
//  Проверяются: нормализация прогресса и индексов через `TesseraRTL` в LTR и
//  RTL для `itemWidth ≠ screenWidth`; зеркалирование физических слотов и
//  отступов; обратимость `readingProgress ↔ rawOffset`; крайние случаи
//  (одна секция, пустая лента).
//

#if canImport(UIKit)

import XCTest
import UIKit
import TesseraCore
@testable import TesseraPanorama

final class PanoRTLTests: XCTestCase {

    private let ltr = UIUserInterfaceLayoutDirection.leftToRight
    private let rtl = UIUserInterfaceLayoutDirection.rightToLeft

    /// §4: ширина экрана и peek, из которых получается шаг секции.
    private let screenWidth: CGFloat = 390
    private let peek: CGFloat = 48
    private let pageCount = 4

    /// Шаг секции `itemWidth = screenWidth − peek = 342` — намеренно не 390:
    /// RTL-тесты должны ловить подмену шага шириной экрана.
    private var itemWidth: CGFloat { screenWidth - peek }

    /// Верхняя граница ленты: `(pageCount − 1) × itemWidth`.
    private var maxOffset: CGFloat { CGFloat(pageCount - 1) * itemWidth }

    // MARK: - Вспомогательные средства

    /// Скролл-вью с принудительным направлением чтения: системный язык
    /// симулятора не должен влиять на проверки (§7).
    private func makeScrollView(
        sectionCount: Int? = nil,
        direction: UIUserInterfaceLayoutDirection = .leftToRight
    ) -> PanoScrollView {
        let scrollView = PanoScrollView(peek: peek)
        scrollView.frame = CGRect(
            x: 0,
            y: 0,
            width: screenWidth,
            height: 700
        )
        scrollView.semanticContentAttribute = direction == .rightToLeft
            ? .forceRightToLeft
            : .forceLeftToRight
        scrollView.sectionCount = sectionCount ?? pageCount
        scrollView.contentSize = scrollView.requiredContentSize
        return scrollView
    }

    /// Ожидаемый прогресс в порядке чтения для сырого offset'а — тем же Core-
    /// контрактом, который применяет панорама (§7).
    private func expectedReadingProgress(
        rawOffset: CGFloat,
        direction: UIUserInterfaceLayoutDirection
    ) -> CGFloat {
        TesseraRTL.normalizedProgress(
            rawOffset / itemWidth,
            pageCount: pageCount,
            layoutDirection: direction
        )
    }

    // MARK: - Направление раскладки

    /// `resolvedLayoutDirection` следует за `semanticContentAttribute`: все
    /// дальнейшие RTL-проверки опираются на это.
    func testResolvedLayoutDirectionFollowsSemanticAttribute() {
        XCTAssertEqual(
            makeScrollView(direction: .leftToRight).resolvedLayoutDirection,
            .leftToRight
        )
        XCTAssertEqual(
            makeScrollView(direction: .rightToLeft).resolvedLayoutDirection,
            .rightToLeft
        )
    }

    // MARK: - Шаг секции не равен ширине экрана (§4)

    /// В обоих направлениях `itemWidth = 342`, а `contentSize = 4 × 342 + 48`:
    /// peek вычитается одинаково, направление чтения меняет только слоты.
    func testItemWidthIsScreenWidthMinusPeekInBothDirections() {
        for direction in [ltr, rtl] {
            let scrollView = makeScrollView(direction: direction)

            XCTAssertEqual(
                scrollView.itemWidth,
                itemWidth,
                accuracy: 0.000_001,
                "направление \(direction): шаг секции"
            )
            XCTAssertNotEqual(
                scrollView.itemWidth,
                screenWidth,
                "peek обязан уменьшать шаг относительно экрана (§4)"
            )
            XCTAssertEqual(
                scrollView.contentSize.width,
                CGFloat(pageCount) * itemWidth + peek,
                accuracy: 0.000_001,
                "направление \(direction): contentSize"
            )
            XCTAssertEqual(
                scrollView.maximumOffsetX,
                maxOffset,
                accuracy: 0.000_001,
                "направление \(direction): граница ленты"
            )
        }
    }

    // MARK: - LTR: слоты, прогресс и индексы

    /// LTR: слот совпадает с индексом чтения, выравнивание — `index × itemWidth`,
    /// кадр секции — та же координата с шириной 342 (§4).
    func testLTRAlignmentStepsByItemWidth() {
        let scrollView = makeScrollView(direction: .leftToRight)

        for index in 0..<pageCount {
            XCTAssertEqual(scrollView.physicalSlot(forReadingIndex: index), index)
            XCTAssertEqual(
                scrollView.alignmentOffset(forReadingIndex: index),
                CGFloat(index) * itemWidth,
                accuracy: 0.000_001,
                "LTR: offset секции \(index)"
            )

            let rect = scrollView.rect(forReadingIndex: index)
            XCTAssertEqual(
                rect.minX,
                CGFloat(index) * itemWidth,
                accuracy: 0.000_001,
                "LTR: x секции \(index)"
            )
            XCTAssertEqual(rect.width, itemWidth, accuracy: 0.000_001)
        }
    }

    /// LTR: `t = offset / itemWidth` без зеркалирования; целая часть — индекс,
    /// дробная — прогресс перехода (§4).
    func testLTRReadingProgressUsesItemWidth() {
        let scrollView = makeScrollView(direction: .leftToRight)

        let cases: [(raw: CGFloat, expected: CGFloat)] = [
            (0, 0),
            (171, 0.5),
            (342, 1),
            (513, 1.5),
            (684, 2),
            (1_026, 3),
        ]

        for entry in cases {
            XCTAssertEqual(
                scrollView.readingProgress(forRawOffset: entry.raw),
                entry.expected,
                accuracy: 0.000_001,
                "LTR-прогресс для raw \(entry.raw)"
            )
            XCTAssertEqual(
                scrollView.readingProgress(forRawOffset: entry.raw),
                expectedReadingProgress(rawOffset: entry.raw, direction: ltr),
                accuracy: 0.000_001,
                "панорама должна совпадать с TesseraRTL в LTR"
            )
        }

        // Сырой `currentProgress()` — физический `t`; в LTR он же и в порядке
        // чтения (§4).
        scrollView.contentOffset = CGPoint(x: 342, y: 0)
        XCTAssertEqual(scrollView.currentProgress(), 1, accuracy: 0.000_001)
    }

    /// LTR: индекс — округлённый физический слот с клампом; на границе 0.5
    /// округление уходит вверх (стандартное правило Swift, §4).
    func testLTRReadingIndexRoundsToNearestSlot() {
        let scrollView = makeScrollView(direction: .leftToRight)

        let cases: [(raw: CGFloat, expected: Int)] = [
            (0, 0),
            (170, 0),
            (171, 1),
            (342, 1),
            (513, 2),
            (683, 2),
            (684, 2),
            (855, 3),
            (1_026, 3),
            (1_200, 3),
            (-100, 0),
        ]

        for entry in cases {
            XCTAssertEqual(
                scrollView.readingIndex(forRawOffset: entry.raw),
                entry.expected,
                "LTR-индекс для raw \(entry.raw)"
            )
        }
    }

    // MARK: - RTL: зеркальные слоты (§7)

    /// RTL: секция чтения `0` живёт в крайнем правом физическом слоте
    /// (`pageCount − 1 − index`), а выравнивание остаётся `slot × itemWidth`.
    func testRTLPhysicalSlotsAreMirrored() {
        let scrollView = makeScrollView(direction: .rightToLeft)

        for index in 0..<pageCount {
            let slot = pageCount - 1 - index

            XCTAssertEqual(
                scrollView.physicalSlot(forReadingIndex: index),
                slot,
                "RTL: физический слот секции чтения \(index)"
            )
            XCTAssertEqual(
                scrollView.alignmentOffset(forReadingIndex: index),
                CGFloat(slot) * itemWidth,
                accuracy: 0.000_001,
                "RTL: offset секции чтения \(index)"
            )
            XCTAssertEqual(
                scrollView.alignmentOffset(forReadingIndex: index),
                scrollView.maximumOffsetX - CGFloat(index) * itemWidth,
                accuracy: 0.000_001,
                "RTL: крайняя секция чтения должна стоять у правого края"
            )
        }
    }

    /// RTL: секции сдвинуты на полосу `peek` вправо — зеркальная лента
    /// начинается с запаса, чтобы подсматривание было на ведущей стороне.
    func testRTLSectionRectsAreShiftedByPeek() {
        let scrollView = makeScrollView(direction: .rightToLeft)

        for index in 0..<pageCount {
            let slot = pageCount - 1 - index
            let rect = scrollView.rect(forReadingIndex: index)

            XCTAssertEqual(
                rect.minX,
                peek + CGFloat(slot) * itemWidth,
                accuracy: 0.000_001,
                "RTL: x секции чтения \(index)"
            )
            XCTAssertEqual(rect.width, itemWidth, accuracy: 0.000_001)
            XCTAssertEqual(rect.height, scrollView.bounds.height, accuracy: 0.000_001)
        }

        // Крайняя правая секция чтения 0 упирается в конец contentSize.
        XCTAssertEqual(
            scrollView.rect(forReadingIndex: 0).maxX,
            scrollView.contentSize.width,
            accuracy: 0.000_001
        )
    }

    // MARK: - RTL: прогресс и индексы через TesseraRTL (§7)

    /// RTL: сырой прогресс зеркалируется `(pageCount − 1) − t`; значения
    /// совпадают с прямым вызовом `TesseraRTL.normalizedProgress` (панорама не
    /// дублирует зеркалирование).
    func testRTLReadingProgressMirrorsRawOffset() {
        let scrollView = makeScrollView(direction: .rightToLeft)

        let cases: [(raw: CGFloat, expected: CGFloat)] = [
            (0, 3),
            (171, 2.5),
            (342, 2),
            (513, 1.5),
            (684, 1),
            (1_026, 0),
        ]

        for entry in cases {
            XCTAssertEqual(
                scrollView.readingProgress(forRawOffset: entry.raw),
                entry.expected,
                accuracy: 0.000_001,
                "RTL-прогресс для raw \(entry.raw)"
            )
        }

        // Bounce: RTL-нормализация не клампит — контракт §4 «потребитель сам
        // решает, как ограничить».
        for raw: CGFloat in [-100, 1_200] {
            XCTAssertEqual(
                scrollView.readingProgress(forRawOffset: raw),
                expectedReadingProgress(rawOffset: raw, direction: rtl),
                accuracy: 0.000_001,
                "RTL-прогресс на bounce для raw \(raw)"
            )
            XCTAssertEqual(
                scrollView.readingProgress(forRawOffset: raw),
                CGFloat(pageCount - 1) - raw / itemWidth,
                accuracy: 0.000_001
            )
        }
    }

    /// RTL: индекс считается по физическому слоту (округление + кламп), а затем
    /// зеркалится в порядок чтения — это правило `TesseraRTL.pageIndex` (§7).
    func testRTLReadingIndexMirrorsPhysicalSlot() {
        let scrollView = makeScrollView(direction: .rightToLeft)

        let cases: [(raw: CGFloat, expected: Int)] = [
            (0, 3),
            (170, 3),
            (171, 2),
            (342, 2),
            (513, 1),
            (683, 1),
            (684, 1),
            (855, 0),
            (1_026, 0),
            (1_200, 0),
            (-100, 3),
        ]

        for entry in cases {
            XCTAssertEqual(
                scrollView.readingIndex(forRawOffset: entry.raw),
                entry.expected,
                "RTL-индекс для raw \(entry.raw)"
            )
        }
    }

    /// `rawOffset(forReadingProgress:)` обратен `readingProgress(forRawOffset:)`
    /// в RTL-диапазоне и клампится на границах ленты (§8).
    func testRTLRawOffsetRoundTripsReadingProgress() {
        let scrollView = makeScrollView(direction: .rightToLeft)

        var progress: CGFloat = 0
        while progress <= 3 {
            let raw = scrollView.rawOffset(forReadingProgress: progress)
            XCTAssertEqual(
                scrollView.readingProgress(forRawOffset: raw),
                progress,
                accuracy: 0.000_001,
                "round-trip прогресса \(progress) через raw \(raw)"
            )
            progress += 0.25
        }

        let cases: [(progress: CGFloat, expected: CGFloat)] = [
            (0, maxOffset),
            (1.5, 513),
            (3, 0),
            (-1, maxOffset),
            (10, 0),
        ]

        for entry in cases {
            XCTAssertEqual(
                scrollView.rawOffset(forReadingProgress: entry.progress),
                entry.expected,
                accuracy: 0.000_001,
                "RTL raw offset для прогресса \(entry.progress)"
            )
        }
    }

    /// Свойство зеркалирования: для одного и того же физического offset'а
    /// прогрессы LTR и RTL дополняют друг друга до `pageCount − 1`.
    func testLTRAndRTLProgressSumToPageCountMinusOne() {
        let ltrScrollView = makeScrollView(direction: .leftToRight)
        let rtlScrollView = makeScrollView(direction: .rightToLeft)

        for raw: CGFloat in [0, 100, 171, 342, 513, 684, 855, 1_026, -100, 1_200] {
            let ltrProgress = ltrScrollView.readingProgress(forRawOffset: raw)
            let rtlProgress = rtlScrollView.readingProgress(forRawOffset: raw)

            XCTAssertEqual(
                ltrProgress + rtlProgress,
                CGFloat(pageCount - 1),
                accuracy: 0.000_001,
                "сумма прогрессов LTR/RTL для raw \(raw)"
            )
        }
    }

    // MARK: - Одна секция и пустая лента (§8)

    /// Одна секция в RTL: peek не вычитается, лента — вьюпорт, прогресс и
    /// индекс всегда 0, кадр секции — весь холст.
    func testRTLSingleSectionUsesFullWidth() {
        let scrollView = makeScrollView(sectionCount: 1, direction: .rightToLeft)

        XCTAssertEqual(scrollView.itemWidth, screenWidth, accuracy: 0.000_001)
        XCTAssertEqual(
            scrollView.contentSize.width,
            screenWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(scrollView.alignmentOffset(forReadingIndex: 0), 0)
        XCTAssertEqual(scrollView.readingProgress(forRawOffset: 0), 0)
        XCTAssertEqual(scrollView.readingIndex(forRawOffset: 500), 0)
        XCTAssertEqual(scrollView.physicalSlot(forReadingIndex: 0), 0)

        let rect = scrollView.rect(forReadingIndex: 0)
        XCTAssertEqual(rect, CGRect(origin: .zero, size: scrollView.bounds.size))
    }

    /// Пустая лента: геометрии нет, но прогресс и индекс не падают (§8).
    func testEmptyPanoramaHasNoGeometry() {
        let scrollView = makeScrollView(sectionCount: 0, direction: .rightToLeft)

        XCTAssertEqual(scrollView.contentSize, .zero)
        XCTAssertEqual(scrollView.alignmentOffset(forReadingIndex: 0), 0)
        XCTAssertEqual(scrollView.readingProgress(forRawOffset: 300), 0)
        XCTAssertEqual(scrollView.readingIndex(forRawOffset: 300), 0)
        XCTAssertEqual(scrollView.rect(forReadingIndex: 0), .zero)
    }
}

#endif
