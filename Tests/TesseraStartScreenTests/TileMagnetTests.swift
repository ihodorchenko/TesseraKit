//
//  TileMagnetTests.swift
//  TesseraStartScreenTests
//
//  Тесты магнитизма к ячейкам (задача E8.9).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §5 «Режим редактирования»
//  и docs/PLAN.md E8.9: под перетаскиваемой плиткой строится виртуальная сетка,
//  и снимок плавно притягивается к центру ближайшего слота той же размерности.
//
//  Проверяется чистая математика `TesseraTileMagnet` (никакого UI): выбор
//  ближайшего центра в радиусе, граница радиуса, вырожденные и нечисловые
//  входы, детерминированность при равном расстоянии. Геометрию слотов даёт
//  сетка, поэтому тесты не инстанцируют `UICollectionView`.
//
//  E10.5-A2: координатор передаёт сюда **центр снимка** (`point + grabOffset`),
//  а не точку пальца; сама функция остаётся чистой «точка → ближайший слот»,
//  поэтому контракт и тесты не меняются. Проверка того, что координатор считает
//  от центра снимка, — `DragSessionTests.testMagnetUsesSnapshotCenterNotFingerPoint`.
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileMagnetTests: XCTestCase {

    // MARK: - Конфигурация

    /// Значения по умолчанию: радиус из диапазона спеки WP 24–32 pt и
    /// короткий spring притяжения.
    func testConfigurationDefaultsMatchSpec() {
        let configuration = TesseraTileEditConfiguration()

        XCTAssertEqual(configuration.magnetSnapRadius, 28, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(configuration.magnetSnapRadius, 24)
        XCTAssertLessThanOrEqual(configuration.magnetSnapRadius, 32)

        XCTAssertEqual(configuration.magnetSpringDuration, 0.2, accuracy: 0.0001)
        XCTAssertGreaterThan(configuration.magnetSpringDuration, 0)
        XCTAssertLessThanOrEqual(configuration.magnetSpringDuration, 0.3)

        XCTAssertEqual(configuration.magnetSpringDamping, 0.82, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(configuration.magnetSpringDamping, 0)
        XCTAssertLessThanOrEqual(configuration.magnetSpringDamping, 1)
    }

    /// Кастомные значения проходят через инициализатор без искажений.
    func testCustomConfigurationIsStored() {
        let configuration = TesseraTileEditConfiguration(
            magnetSnapRadius: 24,
            magnetSpringDuration: 0.15,
            magnetSpringDamping: 0.7
        )

        XCTAssertEqual(configuration.magnetSnapRadius, 24, accuracy: 0.0001)
        XCTAssertEqual(configuration.magnetSpringDuration, 0.15, accuracy: 0.0001)
        XCTAssertEqual(configuration.magnetSpringDamping, 0.7, accuracy: 0.0001)
    }

    // MARK: - Выбор ближайшего слота

    /// Притягивает к ближайшему центру, а не к первому в массиве.
    func testNearestCenterWins() {
        let centers = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 100, y: 0),
            CGPoint(x: 0, y: 100)
        ]

        XCTAssertEqual(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 20, y: 5),
                slotCenters: centers,
                snapRadius: 30
            ),
            CGPoint(x: 0, y: 0)
        )
        XCTAssertEqual(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 85, y: 0),
                slotCenters: centers,
                snapRadius: 30
            ),
            CGPoint(x: 100, y: 0)
        )
    }

    /// Расстояние евклидово: точка «по диагонали» тоже притягивается.
    func testDiagonalDistanceIsEuclidean() {
        XCTAssertEqual(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 18, y: 24),
                slotCenters: [CGPoint(x: 0, y: 0)],
                snapRadius: 31
            ),
            CGPoint(x: 0, y: 0)
        )
        XCTAssertNil(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 18, y: 24),
                slotCenters: [CGPoint(x: 0, y: 0)],
                snapRadius: 29
            )
        )
    }

    /// За радиусом притяжения нет.
    func testPointOutsideRadiusHasNoTarget() {
        XCTAssertNil(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 40, y: 0),
                slotCenters: [CGPoint(x: 0, y: 0)],
                snapRadius: 24
            )
        )
    }

    /// Радиус включительный: центр ровно на границе ещё притягивает.
    func testExactRadiusIsInclusive() {
        // Египетский треугольник 3–4–5: расстояние ровно 5 pt.
        XCTAssertEqual(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 3, y: 4),
                slotCenters: [CGPoint(x: 0, y: 0)],
                snapRadius: 5
            ),
            CGPoint(x: 0, y: 0)
        )
        XCTAssertNil(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 3.1, y: 4),
                slotCenters: [CGPoint(x: 0, y: 0)],
                snapRadius: 5
            )
        )
    }

    /// Нулевой радиус отключает притяжение (даже точно над центром).
    func testZeroRadiusDisablesMagnet() {
        XCTAssertNil(
            TesseraTileMagnet.magnetTarget(
                for: .zero,
                slotCenters: [.zero],
                snapRadius: 0
            )
        )
    }

    /// Отрицательный и нечисловой радиус трактуются как отключённое притяжение.
    func testInvalidRadiusDisablesMagnet() {
        let centers = [CGPoint(x: 0, y: 0)]

        for radius in [CGFloat(-10), .nan, .infinity] {
            XCTAssertNil(
                TesseraTileMagnet.magnetTarget(
                    for: .zero,
                    slotCenters: centers,
                    snapRadius: radius
                ),
                "Радиус \(radius) должен отключать притяжение"
            )
        }
    }

    // MARK: - Вырожденные входы

    /// Пустой набор слотов — притягивать некуда.
    func testEmptySlotCentersReturnNil() {
        XCTAssertNil(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 10, y: 10),
                slotCenters: [],
                snapRadius: 32
            )
        )
    }

    /// При равном расстоянии побеждает первый слот — результат детерминирован.
    func testFirstCenterWinsOnTie() {
        let left = CGPoint(x: -10, y: 0)
        let right = CGPoint(x: 10, y: 0)

        XCTAssertEqual(
            TesseraTileMagnet.magnetTarget(
                for: .zero,
                slotCenters: [left, right],
                snapRadius: 15
            ),
            left
        )
        XCTAssertEqual(
            TesseraTileMagnet.magnetTarget(
                for: .zero,
                slotCenters: [right, left],
                snapRadius: 15
            ),
            right
        )
    }

    /// Нечисловые центры пропускаются, а не ломают весь поиск.
    func testNonFiniteCentersAreSkipped() {
        let broken = CGPoint(x: CGFloat.nan, y: 0)
        let valid = CGPoint(x: 0, y: 0)

        XCTAssertEqual(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 5, y: 0),
                slotCenters: [broken, valid],
                snapRadius: 10
            ),
            valid
        )
    }

    /// Нечисловая точка пальца не даёт цели.
    func testNonFinitePointReturnsNil() {
        XCTAssertNil(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: CGFloat.nan, y: 10),
                slotCenters: [CGPoint(x: 0, y: 0)],
                snapRadius: 32
            )
        )
        XCTAssertNil(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 10, y: CGFloat.infinity),
                slotCenters: [CGPoint(x: 0, y: 0)],
                snapRadius: 32
            )
        )
    }

    // MARK: - Виртуальная сетка слотов

    /// Центры идут с шагом «юнит + зазор» и покрывают все позиции, куда
    /// помещается плитка той же размерности.
    func testVirtualSlotCentersCoverEveryCell() {
        let centers = TesseraTileMagnet.slotCenters(
            for: .medium,
            columns: 4,
            unit: 100,
            gap: 10,
            origin: CGPoint(x: 16, y: 16),
            rowCount: 2
        )

        // 2×2 в сетке 4 колонки и 2 строки: три позиции по горизонтали.
        XCTAssertEqual(centers, [
            CGPoint(x: 121, y: 121),
            CGPoint(x: 231, y: 121),
            CGPoint(x: 341, y: 121)
        ])
    }

    /// Маленькая плитка встаёт в каждую ячейку, включая пустые.
    func testVirtualSlotCentersForSmallTile() {
        let centers = TesseraTileMagnet.slotCenters(
            for: .small,
            columns: 2,
            unit: 50,
            gap: 0,
            origin: .zero,
            rowCount: 2
        )

        XCTAssertEqual(centers, [
            CGPoint(x: 25, y: 25),
            CGPoint(x: 75, y: 25),
            CGPoint(x: 25, y: 75),
            CGPoint(x: 75, y: 75)
        ])
    }

    /// След ужимается под узкую сетку так же, как в раскладке: широкая плитка
    /// при двух колонках становится 2×2.
    func testVirtualSlotCentersFitNarrowGrid() {
        let centers = TesseraTileMagnet.slotCenters(
            for: .wide,
            columns: 2,
            unit: 100,
            gap: 0,
            origin: .zero,
            rowCount: 2
        )

        XCTAssertEqual(centers, [CGPoint(x: 100, y: 100)])
    }

    /// Плитке не хватает занятых строк — слотов нет.
    func testVirtualSlotCentersRequireEnoughRows() {
        XCTAssertTrue(
            TesseraTileMagnet.slotCenters(
                for: .large,
                columns: 4,
                unit: 100,
                gap: 10,
                origin: .zero,
                rowCount: 3
            ).isEmpty
        )
    }

    /// Вырожденная геометрия не даёт слотов.
    func testVirtualSlotCentersInvalidGeometryIsEmpty() {
        XCTAssertTrue(
            TesseraTileMagnet.slotCenters(
                for: .small,
                columns: 0,
                unit: 100,
                gap: 10,
                origin: .zero,
                rowCount: 2
            ).isEmpty
        )
        XCTAssertTrue(
            TesseraTileMagnet.slotCenters(
                for: .small,
                columns: 4,
                unit: 0,
                gap: 10,
                origin: .zero,
                rowCount: 2
            ).isEmpty
        )
        XCTAssertTrue(
            TesseraTileMagnet.slotCenters(
                for: .small,
                columns: 4,
                unit: 100,
                gap: 10,
                origin: .zero,
                rowCount: 0
            ).isEmpty
        )
    }

    // MARK: - Радиус из конфигурации

    /// Притяжение использует радиус конфигурации, а не собственный порог.
    func testConfiguredRadiusIsUsed() {
        let configuration = TesseraTileEditConfiguration(magnetSnapRadius: 24)
        let centers = [CGPoint(x: 0, y: 0)]

        XCTAssertEqual(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 24, y: 0),
                slotCenters: centers,
                snapRadius: configuration.magnetSnapRadius
            ),
            centers[0]
        )
        XCTAssertNil(
            TesseraTileMagnet.magnetTarget(
                for: CGPoint(x: 25, y: 0),
                slotCenters: centers,
                snapRadius: configuration.magnetSnapRadius
            )
        )
    }
}

#endif
