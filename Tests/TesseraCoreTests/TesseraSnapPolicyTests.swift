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
//

import XCTest
@testable import TesseraCore

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

    // MARK: - Порог скорости

    /// Быстрый свайп вправо (положительная скорость) уводит на следующую секцию
    /// относительно ближайшей, а не относительно текущей.
    func testFastPositiveVelocitySelectsNextSection() {
        let policy = TesseraSnapPolicy(velocityThreshold: 600)

        XCTAssertEqual(targetOffset(proposed: 10, velocity: 601, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 100, velocity: 1000, policy: policy), 200)
        XCTAssertEqual(targetOffset(proposed: 240, velocity: 2000, policy: policy), 300)
    }

    /// Быстрый свайп влево (отрицательная скорость) уводит на предыдущую секцию.
    func testFastNegativeVelocitySelectsPreviousSection() {
        let policy = TesseraSnapPolicy(velocityThreshold: 600)

        XCTAssertEqual(targetOffset(proposed: 300, velocity: -601, policy: policy), 200)
        XCTAssertEqual(targetOffset(proposed: 100, velocity: -1000, policy: policy), 0)
    }

    /// Порог строгий (`abs(velocity) > threshold`): ровно на пороге остаёмся на
    /// ближайшей секции.
    func testVelocityAtThresholdKeepsNearestSection() {
        let policy = TesseraSnapPolicy(velocityThreshold: 600)

        XCTAssertEqual(targetOffset(proposed: 100, velocity: 600, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 100, velocity: -600, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 100, velocity: 600.5, policy: policy), 200)
        XCTAssertEqual(targetOffset(proposed: 100, velocity: -600.5, policy: policy), 0)
    }

    /// Отрицательный порог нормализуется к нулю: любая ненулевая скорость
    /// считается быстрым свайпом, нулевая — нет.
    func testNegativeVelocityThresholdIsTreatedAsZero() {
        let policy = TesseraSnapPolicy(velocityThreshold: -100)

        XCTAssertEqual(targetOffset(proposed: 100, velocity: 0, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 100, velocity: 5, policy: policy), 200)
        XCTAssertEqual(targetOffset(proposed: 100, velocity: -5, policy: policy), 0)
    }

    /// Пользовательский порог работает вместо дефолтных 600 pt/s.
    func testCustomVelocityThreshold() {
        let policy = TesseraSnapPolicy(velocityThreshold: 100)

        XCTAssertEqual(targetOffset(proposed: 100, velocity: 100, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 100, velocity: 101, policy: policy), 200)
        XCTAssertEqual(targetOffset(proposed: 100, velocity: -101, policy: policy), 0)
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
