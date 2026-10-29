//
//  PivotHeaderStripViewTests.swift
//  TesseraPivotTests
//
//  Контрактные тесты ленты заголовков пивота (задача E2.7).
//  Проектный документ: docs/PIVOT-IOS-DESIGN.md §3 «Архитектура» (режимы ленты:
//  по ширине контента и равные ширины), §4 «Математика ядра» (выделение —
//  ближайшая к прогрессу секция), §5 «Синхронизация ленты и пейджера» (лента —
//  только читатель: `onSelect` сообщает намерение, но ничего не двигает),
//  §7 «Производительность» (в горячем пути — только `transform` индикатора,
//  без layout и без записи в `contentOffset`), §8 «Accessibility» (минимум
//  44 pt на тапабельную кнопку-заголовок).
//
//  Чистых функций выбора режима/порядка в публичной поверхности ленты нет
//  (это приватная геометрия `effectiveMode`), поэтому режимы проверяются через
//  публичный делегат раскладки — без UI-цикла и без окна.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraPivot

final class PivotHeaderStripViewTests: XCTestCase {

    // MARK: - Вспомогательные средства

    private func makeStrip(
        width: CGFloat = 320,
        height: CGFloat = 48,
        titles: [String] = []
    ) -> PivotHeaderStripView {
        let strip = PivotHeaderStripView(
            frame: CGRect(x: 0, y: 0, width: width, height: height)
        )
        strip.titles = titles
        return strip
    }

    private func collectionView(
        of strip: PivotHeaderStripView
    ) throws -> UICollectionView {
        try XCTUnwrap(
            strip.subviews.compactMap { $0 as? UICollectionView }.first,
            "Лента обязана содержать UICollectionView заголовков"
        )
    }

    /// Ширина ячейки по публичному делегату раскладки (без окна и UI-цикла).
    private func itemWidth(
        of strip: PivotHeaderStripView,
        at index: Int
    ) throws -> CGFloat {
        let collectionView = try collectionView(of: strip)
        let layout = try XCTUnwrap(
            collectionView.collectionViewLayout as? UICollectionViewFlowLayout
        )
        return strip.collectionView(
            collectionView,
            layout: layout,
            sizeForItemAt: IndexPath(item: index, section: 0)
        ).width
    }

    // MARK: - Конфигурация

    /// Дефолты ленты: пустой набор, режим по ширине контента, скрытый до
    /// раскладки индикатор, отступы и минимальная ширина ячейки (§3, §8).
    func testDefaultConfiguration() {
        let strip = PivotHeaderStripView(frame: .zero)

        XCTAssertTrue(strip.titles.isEmpty)
        if case .content = strip.mode {
            // Ожидаемый режим по умолчанию (§3).
        } else {
            XCTFail("По умолчанию лента должна быть в режиме .content")
        }
        XCTAssertEqual(strip.selectedIndex, 0)
        XCTAssertTrue(strip.showsIndicator)
        XCTAssertEqual(strip.highlightSpan, 1)
        XCTAssertEqual(strip.horizontalInset, 16)
        XCTAssertEqual(strip.interItemSpacing, 20)
        XCTAssertEqual(strip.horizontalTextPadding, 8)
        XCTAssertEqual(strip.minimumItemWidth, 44)
        XCTAssertTrue(strip.indicator.isHidden)
        XCTAssertNil(strip.onSelect)
    }

    /// Пустая лента — валидное состояние (§9 «одна секция / пусто»): прогресс,
    /// выбор и автоцентрирование не падают и не создают заголовков.
    func testEmptyTitlesStaySafe() {
        let strip = makeStrip()

        strip.apply(progress: 3.5)
        XCTAssertEqual(strip.selectedIndex, 0)

        strip.select(index: 4)
        XCTAssertEqual(strip.selectedIndex, 0)

        strip.scrollToCenter(index: 2, animated: true)
        strip.scrollToCenter(index: -1, animated: false)

        XCTAssertTrue(strip.titles.isEmpty)
        XCTAssertTrue(strip.indicator.isHidden)
    }

    // MARK: - Выделение по прогрессу (§4)

    /// «Активная» секция — ближайшая к прогрессу: до 0.5 — текущая, с 0.5 —
    /// следующая (§4).
    func testApplyProgressSelectsNearestSection() {
        let strip = makeStrip(titles: ["Один", "Два", "Три", "Четыре", "Пять"])

        let cases: [(progress: CGFloat, expected: Int)] = [
            (0, 0),
            (0.49, 0),
            (0.5, 1),
            (1, 1),
            (1.49, 1),
            (1.5, 2),
            (2.5, 3),
            (4, 4),
        ]

        for entry in cases {
            strip.apply(progress: entry.progress)
            XCTAssertEqual(
                strip.selectedIndex,
                entry.expected,
                "t=\(entry.progress) должен выделять секцию \(entry.expected)"
            )
        }
    }

    /// Прогресс за пределами диапазона (bounce) и `NaN` зажимаются крайними
    /// секциями: лента не «зависает» вне набора (§4).
    func testApplyProgressClampsOutOfRangeValues() {
        let strip = makeStrip(titles: ["Один", "Два", "Три", "Четыре"])

        strip.apply(progress: -5)
        XCTAssertEqual(strip.selectedIndex, 0)

        strip.apply(progress: 99)
        XCTAssertEqual(strip.selectedIndex, 3)

        strip.apply(progress: .nan)
        XCTAssertEqual(strip.selectedIndex, 0)
    }

    /// `select(index:)` — это `apply(progress:)` с целым `t`: индекс зажимается,
    /// а `onSelect` не вызывается (программный выбор — не тап пользователя).
    func testSelectIndexClampsAndDoesNotNotifySelection() {
        let strip = makeStrip(titles: ["Один", "Два", "Три"])
        var selections: [Int] = []
        strip.onSelect = { selections.append($0) }

        strip.select(index: 2)
        XCTAssertEqual(strip.selectedIndex, 2)

        strip.select(index: 99)
        XCTAssertEqual(strip.selectedIndex, 2)
        XCTAssertEqual(strip.selectedIndex, strip.titles.count - 1)

        strip.select(index: -10)
        XCTAssertEqual(strip.selectedIndex, 0)

        XCTAssertTrue(selections.isEmpty, "программный select не должен вызывать onSelect")
    }

    /// Смена набора заголовков зажимает сохранённый прогресс в новый диапазон:
    /// после удаления секций лента не указывает на несуществующий заголовок.
    func testTitlesUpdateClampsSelectionToNewRange() {
        let strip = makeStrip(titles: ["0", "1", "2", "3", "4"])

        strip.apply(progress: 4)
        XCTAssertEqual(strip.selectedIndex, 4)

        strip.titles = ["A", "B"]
        XCTAssertEqual(strip.selectedIndex, 1)
        XCTAssertEqual(strip.titles, ["A", "B"])

        strip.titles = ["A"]
        XCTAssertEqual(strip.selectedIndex, 0)
    }

    /// Тап по заголовку — только `onSelect` с индексом в порядке чтения;
    /// лента не меняет выделение и не двигает пейджер сама (§5).
    func testTapReportsSelectionWithoutChangingState() throws {
        let strip = makeStrip(titles: ["Один", "Два", "Три"])
        var selections: [Int] = []
        strip.onSelect = { selections.append($0) }

        let collectionView = try collectionView(of: strip)
        strip.collectionView(
            collectionView,
            didSelectItemAt: IndexPath(item: 2, section: 0)
        )

        XCTAssertEqual(selections, [2])
        XCTAssertEqual(strip.selectedIndex, 0, "тап не должен менять выделение напрямую")
    }

    // MARK: - Режимы ширины (§3)

    /// `.content`: ширина ячейки — по тексту, поэтому заголовки разной длины
    /// получают разную ширину, а короткие упираются в минимум 44 pt (§3, §8).
    func testContentModeSizesFollowText() throws {
        let strip = makeStrip(
            titles: ["A", "Длинный заголовок секции", "BB"]
        )

        let widths = try (0..<strip.titles.count).map { try itemWidth(of: strip, at: $0) }

        XCTAssertEqual(widths.count, 3)
        XCTAssertGreaterThan(Set(widths.map { Int($0.rounded()) }).count, 1)
        for width in widths {
            XCTAssertGreaterThanOrEqual(
                width,
                strip.minimumItemWidth - 0.000_001,
                "ячейка уже \(strip.minimumItemWidth) pt перестаёт быть тапабельной кнопкой"
            )
        }
    }

    /// `.fill`: заголовки делят ширину ленты поровну, промежутки вычитаются до
    /// деления (§3).
    func testFillModeSplitsWidthEqually() throws {
        let strip = makeStrip(
            width: 320,
            titles: ["Один", "Два", "Три"]
        )
        strip.mode = .fill

        let expected = (320 - strip.interItemSpacing * 2) / 3
        let widths = try (0..<3).map { try itemWidth(of: strip, at: $0) }

        for width in widths {
            XCTAssertEqual(width, expected, accuracy: 0.000_001)
        }
    }

    /// Слишком узкие равные ячейки — не кнопки: `.fill` уступает `.content`,
    /// и ширина возвращается к тексту с минимумом (§8, «Dynamic Type»).
    func testFillModeFallsBackWhenCellsWouldBeTooNarrow() throws {
        let strip = makeStrip(
            width: 90,
            titles: ["Один", "Два", "Три", "Четыре"]
        )
        strip.mode = .fill

        // (90 - 20 * 3) / 4 = 7.5 pt — нечитаемо и не тапабельно.
        let widths = try (0..<4).map { try itemWidth(of: strip, at: $0) }

        for width in widths {
            XCTAssertGreaterThanOrEqual(
                width,
                strip.minimumItemWidth - 0.000_001,
                "на узкой ленте режим .fill должен отступить к .content (§8)"
            )
        }
    }

    // MARK: - Индикатор: вид и горячий путь (§4, §7)

    /// Цвет активного заголовка из стиля доходит до подчёркивания-индикатора.
    func testActiveColorPropagatesToIndicator() {
        let strip = makeStrip(titles: ["Один", "Два"])

        strip.activeColor = .systemRed

        XCTAssertEqual(strip.indicator.activeColor, .systemRed)
        XCTAssertEqual(strip.indicator.backgroundColor, .systemRed)
    }

    /// После layout-прохода индикатор показан и прижат к нижней кромке ленты.
    func testLayoutPlacesAndShowsIndicator() {
        let strip = makeStrip(titles: ["Один", "Два", "Три"])

        strip.layoutSubviews()

        XCTAssertFalse(strip.indicator.isHidden)
        XCTAssertEqual(strip.indicator.center.y, strip.bounds.maxY - 1.5, accuracy: 0.000_001)

        strip.showsIndicator = false
        XCTAssertTrue(strip.indicator.isHidden)

        strip.showsIndicator = true
        strip.layoutSubviews()
        XCTAssertFalse(strip.indicator.isHidden)
    }

    /// Горячий путь свайпа: `apply(progress:)` двигает только `transform`
    /// индикатора — `bounds`/`center` не меняются, коллекция не скроллится,
    /// `contentOffset` не пишется (§4, §5, §7).
    func testApplyProgressMovesIndicatorOnlyByTransform() throws {
        let strip = makeStrip(
            width: 640,
            titles: ["Один", "Два", "Три", "Четыре"]
        )
        strip.layoutSubviews()

        let indicator = strip.indicator
        let collectionView = try collectionView(of: strip)
        let boundsBefore = indicator.bounds
        let centerBefore = indicator.center

        strip.apply(progress: 0)
        let firstPosition = indicator.center.x + indicator.transform.tx

        strip.apply(progress: 1)
        let secondPosition = indicator.center.x + indicator.transform.tx

        XCTAssertEqual(indicator.bounds, boundsBefore)
        XCTAssertEqual(indicator.center, centerBefore)
        XCTAssertNotEqual(secondPosition, firstPosition)
        XCTAssertEqual(collectionView.contentOffset.x, 0, accuracy: 0.000_001)
    }
}

#endif
