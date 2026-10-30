//
//  TesseraSnapPolicyTests.swift
//  TesseraCoreTests
//
//  Контрактные тесты снапа (задача E1.7).
//  Проектный документ: docs/Core-iOS-Design.md §2 «Ключевые контракты»
//  («Два режима пейджера»: ближайший центр + порог скорости) и §3
//  «Концептуальная поверхность API» (TesseraSnapPolicy — конфиг снапа).
//
//  Проверяется чистая функция `targetContentOffset(...)`: она не зависит от UIKit и
//  потому выполняется как на iOS, так и на macOS-хосте (файл не требует UIKit).
//  Сценарии скорости (E10.11) заданы в единицах UIKit (points/ms) и переводятся
//  в pt/s так же, как это делают потребители политики.
//

import XCTest
@testable import TesseraCore

/// Коэффициент `UIScrollView.DecelerationRate.fast` (0.99 за миллисекунду):
/// константа продублирована, чтобы файл не зависел от UIKit.
private enum UIScrollViewFastDecelerationRateForTests {
    static let value: CGFloat = 0.99
}

final class TesseraSnapPolicyTests: XCTestCase {

    /// Шаг снапа по умолчанию для тестов: 100 pt.
    private let itemWidth: CGFloat = 100

    /// Универсальный вызов политики с дефолтными параметрами.
    private func targetOffset(
        proposed: CGFloat,
        velocity: CGFloat = 0,
        itemWidth: CGFloat? = nil,
        pageCount: Int = 5,
        policy: TesseraSnapPolicy = TesseraSnapPolicy()
    ) -> CGFloat {
        policy.targetContentOffset(
            proposedOffset: proposed,
            velocity: velocity,
            itemWidth: itemWidth ?? self.itemWidth,
            pageCount: pageCount
        )
    }

    // MARK: - Выравнивание .center

    /// `.center` округляет к ближайшей секции; полуцелые значения уходят вверх
    /// (стандартное правило `CGFloat.rounded()` — от нуля).
    func testCenterAlignmentRoundsToNearestSection() {
        let policy = TesseraSnapPolicy(velocityThreshold: 600, alignment: .center)

        XCTAssertEqual(targetOffset(proposed: 0, policy: policy), 0)
        XCTAssertEqual(targetOffset(proposed: 49, policy: policy), 0)
        XCTAssertEqual(targetOffset(proposed: 50, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 51, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 149, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 150, policy: policy), 200)
        XCTAssertEqual(targetOffset(proposed: 249, policy: policy), 200)
    }

    /// Полуцелые индексы (0.5, 1.5, 2.5) при `.center` округляются от нуля.
    func testCenterAlignmentRoundsHalfValuesAwayFromZero() {
        let policy = TesseraSnapPolicy(alignment: .center)

        XCTAssertEqual(targetOffset(proposed: 50, pageCount: 4, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 150, pageCount: 4, policy: policy), 200)
        XCTAssertEqual(targetOffset(proposed: 250, pageCount: 4, policy: policy), 300)
    }

    // MARK: - Выравнивание .leading

    /// `.leading` считает индекс как `floor(offset / itemWidth + 0.5)`: полуцелые
    /// всегда вверх, в отличие от округления «от нуля» на отрицательных значениях.
    func testLeadingAlignmentRoundsHalfUp() {
        let policy = TesseraSnapPolicy(velocityThreshold: 600, alignment: .leading)

        XCTAssertEqual(targetOffset(proposed: 0, policy: policy), 0)
        XCTAssertEqual(targetOffset(proposed: 49.9, policy: policy), 0)
        XCTAssertEqual(targetOffset(proposed: 50, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 99.9, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 100, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 149.9, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 150, policy: policy), 200)
    }

    /// Для неотрицательных offset'ов формулы `.center` и `.leading` совпадают
    /// (это зафиксировано в документации к `targetContentOffset`).
    func testAlignmentsAgreeOnNonNegativeOffsets() {
        let center = TesseraSnapPolicy(alignment: .center)
        let leading = TesseraSnapPolicy(alignment: .leading)
        let proposals: [CGFloat] = [0, 12.5, 25, 37.5, 50, 62.5, 75, 87.5, 100,
                                    250, 500, 750, 1000]

        for proposed in proposals {
            XCTAssertEqual(
                targetOffset(proposed: proposed, policy: center),
                targetOffset(proposed: proposed, policy: leading),
                "Формулы выравниваний разошлись на неотрицательном offset \(proposed)"
            )
        }
    }

    /// Отрицательный offset клампится в ноль при любом выравнивании: левее первой
    /// секции снапить некуда.
    func testNegativeOffsetsClampToFirstSection() {
        let center = TesseraSnapPolicy(alignment: .center)
        let leading = TesseraSnapPolicy(alignment: .leading)

        for proposed: CGFloat in [-10, -50, -60, -150, -250] {
            XCTAssertEqual(targetOffset(proposed: proposed, policy: center), 0)
            XCTAssertEqual(targetOffset(proposed: proposed, policy: leading), 0)
        }
    }

    // MARK: - Порог скорости: реальные сценарии (E10.11)
    //
    // UIKit отдаёт скорость в points/ms, политика ждёт pt/s: потребитель
    // переводит `× 1000`. `proposedOffset` у флика уже включает инерцию —
    // для `.fast` (0.99/мс) проекция ≈ `offset + v(pt/ms) × 0.99 / 0.01`.

    /// Скорость UIKit (points/ms) в единицах политики (pt/s).
    private func pointsPerSecond(_ pointsPerMillisecond: CGFloat) -> CGFloat {
        pointsPerMillisecond * 1000
    }

    /// Цель инерции UIKit при `decelerationRate = .fast`.
    private func projectedOffset(from offset: CGFloat, pointsPerMillisecond velocity: CGFloat) -> CGFloat {
        let rate = UIScrollViewFastDecelerationRateForTests.value
        return offset + velocity * rate / (1 - rate)
    }

    /// Старт 0, протяжка 100, флик 3 pt/ms (3000 pt/s) при секции 320:
    /// инерция предлагает ≈397 (ближайшая — 1), но шаг считается от стартовой
    /// секции — итог 1, а не 2 (перескок секции).
    func testFastFlickStepsOneSectionFromGestureStart() {
        let width: CGFloat = 320
        let proposed = projectedOffset(from: 100, pointsPerMillisecond: 3)
        XCTAssertEqual(proposed, 397, accuracy: 0.5)

        let target = TesseraSnapPolicy().targetContentOffset(
            proposedOffset: proposed,
            velocity: pointsPerSecond(3),
            itemWidth: width,
            pageCount: 5,
            startOffset: 0
        )
        XCTAssertEqual(target, width, "один жест — не дальше соседней секции")

        // Без стартового offset'а опора — ближайшая к proposed: перескок.
        let legacy = TesseraSnapPolicy().targetContentOffset(
            proposedOffset: proposed,
            velocity: pointsPerSecond(3),
            itemWidth: width,
            pageCount: 5
        )
        XCTAssertEqual(legacy, width * 2)
    }

    /// Короткая протяжка 50 и флик 1 pt/ms (1000 pt/s > 600): соседняя секция,
    /// хотя инерция предлагает ≈149 (ближайшая — текущая 0).
    func testShortFastFlickMovesToNeighbour() {
        let width: CGFloat = 320
        let proposed = projectedOffset(from: 50, pointsPerMillisecond: 1)

        XCTAssertEqual(
            TesseraSnapPolicy().targetContentOffset(
                proposedOffset: proposed,
                velocity: pointsPerSecond(1),
                itemWidth: width,
                pageCount: 5,
                startOffset: 0
            ),
            width
        )
    }

    /// Та же короткая протяжка медленнее порога (0,4 pt/ms = 400 pt/s):
    /// откат на ближайшую секцию.
    func testShortSlowDragReturnsToNearest() {
        let width: CGFloat = 320
        let proposed = projectedOffset(from: 50, pointsPerMillisecond: 0.4)

        XCTAssertEqual(
            TesseraSnapPolicy().targetContentOffset(
                proposedOffset: proposed,
                velocity: pointsPerSecond(0.4),
                itemWidth: width,
                pageCount: 5,
                startOffset: 0
            ),
            0
        )
    }

    /// Флик назад со стартом на секции 2: протяжка −100, −3 pt/ms — итог 1,
    /// а не 0.
    func testFastBackwardFlickStepsOneSectionFromGestureStart() {
        let width: CGFloat = 320
        let proposed = projectedOffset(from: 540, pointsPerMillisecond: -3)

        XCTAssertEqual(
            TesseraSnapPolicy().targetContentOffset(
                proposedOffset: proposed,
                velocity: pointsPerSecond(-3),
                itemWidth: width,
                pageCount: 5,
                startOffset: 640
            ),
            width
        )
    }

    /// Флик против направления протяжки: протянули вперёд, бросили назад —
    /// шаг от стартовой секции по знаку скорости (кламп в ноль на первой).
    func testFlickAgainstDragDirectionUsesVelocitySign() {
        let width: CGFloat = 320
        let policy = TesseraSnapPolicy()

        XCTAssertEqual(
            policy.targetContentOffset(
                proposedOffset: projectedOffset(from: 380, pointsPerMillisecond: -1),
                velocity: pointsPerSecond(-1),
                itemWidth: width,
                pageCount: 5,
                startOffset: 320
            ),
            0
        )
        XCTAssertEqual(
            policy.targetContentOffset(
                proposedOffset: projectedOffset(from: 80, pointsPerMillisecond: -2),
                velocity: pointsPerSecond(-2),
                itemWidth: width,
                pageCount: 5,
                startOffset: 0
            ),
            0
        )
    }

    /// Нечисловой стартовый offset игнорируется — опора на ближайшую.
    func testNonFiniteStartOffsetFallsBackToNearest() {
        XCTAssertEqual(
            targetOffset(proposed: 100, velocity: 1000),
            TesseraSnapPolicy().targetContentOffset(
                proposedOffset: 100,
                velocity: 1000,
                itemWidth: itemWidth,
                pageCount: 5,
                startOffset: .nan
            )
        )
    }

    /// Порог строгий (`abs(velocity) > threshold`): ровно на пороге остаёмся на
    /// ближайшей секции; чуть выше — шаг от стартовой.
    func testVelocityAtThresholdKeepsNearestSection() {
        let policy = TesseraSnapPolicy(velocityThreshold: 600)

        for start: CGFloat? in [nil, 100] {
            XCTAssertEqual(policy.targetContentOffset(proposedOffset: 130, velocity: 600, itemWidth: itemWidth, pageCount: 5, startOffset: start), 100)
            XCTAssertEqual(policy.targetContentOffset(proposedOffset: 70, velocity: -600, itemWidth: itemWidth, pageCount: 5, startOffset: start), 100)
            XCTAssertEqual(policy.targetContentOffset(proposedOffset: 130, velocity: 600.5, itemWidth: itemWidth, pageCount: 5, startOffset: start), 200)
            XCTAssertEqual(policy.targetContentOffset(proposedOffset: 70, velocity: -600.5, itemWidth: itemWidth, pageCount: 5, startOffset: start), 0)
        }
    }

    /// Отрицательный порог нормализуется к нулю: любая ненулевая скорость
    /// считается быстрым свайпом, нулевая — нет.
    func testNegativeVelocityThresholdIsTreatedAsZero() {
        let policy = TesseraSnapPolicy(velocityThreshold: -100)

        XCTAssertEqual(targetOffset(proposed: 100, velocity: 0, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 100, velocity: 5, policy: policy), 200)
        XCTAssertEqual(targetOffset(proposed: 100, velocity: -5, policy: policy), 0)
    }

    /// Пользовательский порог в pt/s: 1500 pt/s (1,5 pt/ms) — флик 1 pt/ms
    /// уже «медленный», 2 pt/ms — быстрый.
    func testCustomVelocityThreshold() {
        let width: CGFloat = 320
        let policy = TesseraSnapPolicy(velocityThreshold: 1500)

        XCTAssertEqual(
            policy.targetContentOffset(
                proposedOffset: projectedOffset(from: 50, pointsPerMillisecond: 1),
                velocity: pointsPerSecond(1),
                itemWidth: width,
                pageCount: 5,
                startOffset: 0
            ),
            0
        )
        XCTAssertEqual(
            policy.targetContentOffset(
                proposedOffset: projectedOffset(from: 50, pointsPerMillisecond: 2),
                velocity: pointsPerSecond(2),
                itemWidth: width,
                pageCount: 5,
                startOffset: 0
            ),
            width
        )
    }

    // MARK: - Кламп в [0, (pageCount - 1) * itemWidth]

    /// Выше последней секции offset не уходит.
    func testUpperBoundClamp() {
        XCTAssertEqual(targetOffset(proposed: 200, velocity: 2000, pageCount: 3), 200)
        XCTAssertEqual(targetOffset(proposed: 1000, velocity: 0, pageCount: 3), 200)
        XCTAssertEqual(targetOffset(proposed: 250, velocity: 0, pageCount: 3), 200)
    }

    /// Ниже первой секции offset не уходит.
    func testLowerBoundClamp() {
        XCTAssertEqual(targetOffset(proposed: 0, velocity: -2000, pageCount: 3), 0)
        XCTAssertEqual(targetOffset(proposed: -1000, velocity: 0, pageCount: 3), 0)
    }

    /// Для одной страницы допустим только нулевой offset.
    func testSinglePageAlwaysReturnsZero() {
        XCTAssertEqual(targetOffset(proposed: 500, velocity: 2000, pageCount: 1), 0)
        XCTAssertEqual(targetOffset(proposed: -500, velocity: -2000, pageCount: 1), 0)
        XCTAssertEqual(targetOffset(proposed: 0, velocity: 0, pageCount: 1), 0)
    }

    // MARK: - Вырожденные входы

    /// Некорректная ширина секции (0, отрицательная, NaN) — снапить не к чему,
    /// возвращается предложение системы без изменений.
    func testDegenerateItemWidthReturnsProposedOffset() {
        let proposals: [CGFloat] = [123.456, -50, 0]

        for width: CGFloat in [0, -100, .nan] {
            for proposed in proposals {
                XCTAssertEqual(
                    targetOffset(proposed: proposed, itemWidth: width),
                    proposed,
                    "Ширина \(width), proposed \(proposed): ожидался исходный offset"
                )
            }
        }
    }

    /// Некорректное число страниц (0, отрицательное) — возвращается предложение
    /// системы без изменений.
    func testDegeneratePageCountReturnsProposedOffset() {
        for count in [0, -2] {
            XCTAssertEqual(
                targetOffset(proposed: 123.456, velocity: 1000, pageCount: count),
                123.456
            )
        }
    }

    // MARK: - Конфигурация по умолчанию

    /// Дефолты: порог 600 pt/s и выравнивание `.center`.
    func testDefaultConfiguration() {
        let policy = TesseraSnapPolicy()

        XCTAssertEqual(policy.velocityThreshold, 600)
        XCTAssertEqual(policy.alignment, .center)

        // Поведенческая проверка дефолтного порога.
        XCTAssertEqual(targetOffset(proposed: 100, velocity: 600, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 100, velocity: 601, policy: policy), 200)
    }
}
