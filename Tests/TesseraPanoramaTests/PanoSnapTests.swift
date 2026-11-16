//
//  PanoSnapTests.swift
//  TesseraPanoramaTests
//
//  Контрактные тесты снапа панорамы с peek (задача E3.7).
//  Проектный документ: docs/PANORAMA-IOS-DESIGN.md §4 «Геометрия и математика
//  ядра» (`itemWidth = screenWidth − peek`; снап: ближайший центр + порог
//  скорости; `pagingEnabled` не подходит; на границах — кламп) и §8
//  «Адаптивность и жизненные случаи» (одна секция — без снапа; пустой список).
//
//  Проверяются: ширина секции «экран минус peek», чистая политика
//  `TesseraSnapPolicy` на этой ширине (ближайший центр, порог скорости, кламп
//  границ, вырожденные входы) и та же политика в связке с `TesseraPanoScrollView`.
//

#if canImport(UIKit)

import XCTest
import UIKit
import TesseraCore
@testable import TesseraPanorama

final class PanoSnapTests: XCTestCase {

    /// Ширина экрана, для которой считается геометрия (§4).
    private let screenWidth: CGFloat = 390

    /// Запас подсматривания следующей секции (§4: 16…64 pt).
    private let peek: CGFloat = 48

    /// §4: `itemWidth = screenWidth − peek`; 342 pt при экране 390 и peek 48.
    /// Шаг снапа обязан быть равен этой величине, а не ширине экрана.
    private var itemWidth: CGFloat { screenWidth - peek }

    // MARK: - Вспомогательные средства

    private func makeScrollView(
        sectionCount: Int = 4,
        width: CGFloat? = nil
    ) -> TesseraPanoScrollView {
        let scrollView = TesseraPanoScrollView(peek: peek)
        scrollView.frame = CGRect(
            x: 0,
            y: 0,
            width: width ?? screenWidth,
            height: 700
        )
        scrollView.sectionCount = sectionCount
        scrollView.contentSize = scrollView.requiredContentSize
        return scrollView
    }

    /// Чистая политика снапа на ширине секции панорамы (§4).
    private func snapTarget(
        proposed: CGFloat,
        velocity: CGFloat = 0,
        width: CGFloat? = nil,
        pageCount: Int = 4,
        policy: TesseraSnapPolicy = TesseraSnapPolicy()
    ) -> CGFloat {
        policy.targetContentOffset(
            proposedOffset: proposed,
            velocity: velocity,
            itemWidth: width ?? itemWidth,
            pageCount: pageCount
        )
    }

    /// Цель снапа, которую `TesseraPanoScrollView` подставит системе.
    private func scrollViewTarget(
        _ scrollView: TesseraPanoScrollView,
        proposed: CGFloat,
        velocity: CGFloat = 0
    ) -> CGFloat {
        var target = CGPoint(x: proposed, y: 0)
        scrollView.scrollViewWillEndDragging(
            scrollView,
            withVelocity: CGPoint(x: velocity, y: 0),
            targetContentOffset: &target
        )
        return target.x
    }

    // MARK: - Геометрия: itemWidth = экран − peek (§4)

    /// Ширина секции и `contentSize` считаются от peek: 4 секции при экране 390
    /// и peek 48 дают шаг 342 pt и ленту `4 × 342 + 48 = 1416` pt. Верхняя
    /// граница offset'а совпадает с последним шагом снапа (¶ «Снап», §4).
    func testItemWidthAndContentSizeFollowPeek() {
        let scrollView = makeScrollView()

        XCTAssertEqual(scrollView.itemWidth, itemWidth, accuracy: 0.000_001)
        XCTAssertNotEqual(
            scrollView.itemWidth,
            screenWidth,
            "peek обязан уменьшать ширину секции относительно экрана (§4)"
        )
        XCTAssertEqual(
            scrollView.contentSize.width,
            CGFloat(4) * itemWidth + peek,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            scrollView.maximumOffsetX,
            CGFloat(3) * itemWidth,
            accuracy: 0.000_001
        )
    }

    // MARK: - Ближайший центр (§4, «Снап»)

    /// `.center` округляет позицию к ближайшей секции шагом `itemWidth`, а не
    /// шириной экрана: граница перехода — 171 pt (половина 342).
    func testCenterAlignmentRoundsToNearestPeekSection() {
        let cases: [(proposed: CGFloat, expected: CGFloat)] = [
            (0, 0),
            (100, 0),
            (170, 0),
            (171, 342),
            (300, 342),
            (512, 342),
            (513, 684),
            (683, 684),
            (684, 684),
            (855, 1_026),
            (1_000, 1_026),
        ]

        for entry in cases {
            XCTAssertEqual(
                snapTarget(proposed: entry.proposed),
                entry.expected,
                accuracy: 0.000_001,
                "offset \(entry.proposed) должен прилипать к \(entry.expected)"
            )
        }
    }

    // MARK: - Порог скорости (§4, «Снап»)

    /// Быстрый свайп уводит ровно на одну секцию от ближайшей: порог строгий
    /// (`abs(velocity) > threshold`), на самом пороге 600 pt/s остаёмся на месте.
    func testVelocityThresholdIsStrict() {
        let policy = TesseraSnapPolicy(velocityThreshold: 600)

        XCTAssertEqual(
            snapTarget(proposed: itemWidth, velocity: 600, policy: policy),
            itemWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            snapTarget(proposed: itemWidth, velocity: -600, policy: policy),
            itemWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            snapTarget(proposed: itemWidth, velocity: 601, policy: policy),
            CGFloat(2) * itemWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            snapTarget(proposed: itemWidth, velocity: -601, policy: policy),
            0,
            accuracy: 0.000_001
        )
    }

    /// Быстрый свайп шагает на секцию в сторону движения даже с «недоезда»:
    /// при 100 pt (ближайшая секция 0) положительная скорость ведёт к 342.
    func testFastSwipeStepsToNeighbourOfNearestSection() {
        XCTAssertEqual(
            snapTarget(proposed: 100, velocity: 700),
            itemWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            snapTarget(proposed: 600, velocity: -700),
            itemWidth,
            accuracy: 0.000_001
        )
    }

    // MARK: - Кламп границ (§4)

    /// Снап не выходит за `0...((pageCount − 1) × itemWidth)`: за краем ленты
    /// остаётся стандартный bounce, политика в него не вмешивается (§4).
    func testSnapClampsToSectionBounds() {
        let cases: [(proposed: CGFloat, velocity: CGFloat, pageCount: Int, expected: CGFloat)] = [
            (5_000, 0, 4, 1_026),
            (1_026, 2_000, 4, 1_026),
            (-100, 0, 4, 0),
            (-100, -2_000, 4, 0),
            (5_000, 2_000, 3, 684),
            (-5_000, -2_000, 3, 0),
        ]

        for entry in cases {
            XCTAssertEqual(
                snapTarget(
                    proposed: entry.proposed,
                    velocity: entry.velocity,
                    pageCount: entry.pageCount
                ),
                entry.expected,
                accuracy: 0.000_001,
                "снап вне [0, (n − 1) × itemWidth] для proposed \(entry.proposed)"
            )
        }
    }

    // MARK: - Одна секция (§8)

    /// Одна секция — листать некуда: ширина секции равна экрану (peek не
    /// вычитается), `contentSize` — вьюпорт, снап всегда в ноль.
    func testSingleSectionHasNoSnap() {
        XCTAssertEqual(
            snapTarget(proposed: 500, velocity: 2_000, pageCount: 1),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            snapTarget(proposed: -500, velocity: -2_000, pageCount: 1),
            0,
            accuracy: 0.000_001
        )

        let scrollView = makeScrollView(sectionCount: 1)
        XCTAssertEqual(scrollView.itemWidth, screenWidth, accuracy: 0.000_001)
        XCTAssertEqual(
            scrollView.contentSize.width,
            screenWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: 300, velocity: 2_000),
            0,
            accuracy: 0.000_001
        )
    }

    /// Пустой набор секций: ширина секции формально равна экрану, но
    /// `contentSize` пуст и предложенная системой цель не переписывается.
    func testEmptyPanoramaHasNoSnapTarget() {
        let scrollView = makeScrollView(sectionCount: 0)

        XCTAssertEqual(scrollView.contentSize, .zero)
        XCTAssertEqual(scrollView.itemWidth, screenWidth, accuracy: 0.000_001)
        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: 300),
            300,
            accuracy: 0.000_001
        )
    }

    // MARK: - Вырожденные входы политики

    /// `itemWidth <= 0` (в том числе `NaN`) — снапить не к чему: возвращается
    /// предложение системы без изменений (контракт `TesseraSnapPolicy`).
    func testDegenerateItemWidthReturnsProposal() {
        let proposals: [CGFloat] = [123.456, -50, 0]

        for width: CGFloat in [0, -itemWidth, .nan] {
            for proposed in proposals {
                XCTAssertEqual(
                    snapTarget(proposed: proposed, width: width),
                    proposed,
                    accuracy: 0.000_001,
                    "ширина \(width), proposed \(proposed): ожидался исходный offset"
                )
            }
        }
    }

    /// `pageCount <= 0` — возвращается предложение системы без изменений.
    func testDegeneratePageCountReturnsProposal() {
        for count in [0, -2] {
            XCTAssertEqual(
                snapTarget(proposed: 400, velocity: 1_000, pageCount: count),
                400,
                accuracy: 0.000_001,
                "pageCount \(count): снапить не к чему"
            )
        }
    }

    /// Пока ширины ещё нет (вид вне иерархии), `itemWidth == 0` и скролл-вью
    /// не переписывает цель снапа.
    func testZeroWidthScrollViewReturnsProposal() {
        let scrollView = makeScrollView(sectionCount: 4, width: 0)

        XCTAssertEqual(scrollView.itemWidth, 0, accuracy: 0.000_001)
        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: 300),
            300,
            accuracy: 0.000_001
        )
    }

    // MARK: - Конфигурация скролл-вью (§4, «Снап»)

    /// §4: `pagingEnabled` выключен (полностраничный пейджинг не умеет peek),
    /// замедление `.fast`, направление заблокировано, bounce включается только
    /// при числе секций больше одной (§8).
    func testSnapConfigurationMatchesDocument() {
        let scrollView = TesseraPanoScrollView(frame: .zero)

        XCTAssertFalse(scrollView.isPagingEnabled)
        XCTAssertEqual(scrollView.decelerationRate, .fast)
        XCTAssertTrue(scrollView.isDirectionalLockEnabled)
        XCTAssertEqual(scrollView.contentInsetAdjustmentBehavior, .never)
        XCTAssertFalse(scrollView.alwaysBounceHorizontal)

        scrollView.sectionCount = 2
        XCTAssertTrue(scrollView.alwaysBounceHorizontal)

        scrollView.sectionCount = 1
        XCTAssertFalse(scrollView.alwaysBounceHorizontal)
    }

    // MARK: - Снап в связке с TesseraPanoScrollView

    /// `TesseraPanoScrollView` подставляет политике именно `itemWidth = экран − peek`:
    /// 400 pt при шаге 342 — это секция 1, хотя при шаге 390 это была бы 0.
    func testScrollViewSnapUsesPeekItemWidth() {
        let scrollView = makeScrollView()

        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: 400),
            itemWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: 380),
            itemWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: 513),
            CGFloat(2) * itemWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: itemWidth, velocity: 601),
            CGFloat(2) * itemWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: itemWidth, velocity: -601),
            0,
            accuracy: 0.000_001
        )
    }

    /// Границы ленты в скролл-вью совпадают с границами клампа политики:
    /// последний шаг `3 × 342 = 1026` — это же `maximumOffsetX`.
    func testScrollViewSnapClampsAtEdges() {
        let scrollView = makeScrollView()

        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: 5_000),
            scrollView.maximumOffsetX,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: -100),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: 1_026, velocity: 2_000),
            scrollView.maximumOffsetX,
            accuracy: 0.000_001
        )
    }
}

#endif
