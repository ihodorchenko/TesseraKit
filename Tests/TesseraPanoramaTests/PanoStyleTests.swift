//
//  PanoStyleTests.swift
//  TesseraPanoramaTests
//
//  Контрактные тесты конфигурации панорамы (задача E3.7).
//  Проектный документ: docs/PANORAMA-IOS-DESIGN.md §3 «Концептуальная
//  архитектура» (`PanoramaStyle`: ширина секции с peek, множитель параллакса,
//  шрифты/цвета заголовков, поведение фона) и §4 «Геометрия и математика ядра»
//  (peek 16…64 pt; `0 < parallaxFactor < 1`, типично 0.4–0.6).
//
//  Проверяются: системные дефолты, клампы `peek` и `parallaxFactor` в
//  инициализаторе и на каждой записи, защита от `NaN`/бесконечностей и
//  сохранение пользовательских значений, не выходящих за диапазон.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraPanorama

final class PanoStyleTests: XCTestCase {

    // MARK: - Дефолты

    /// Значения по умолчанию: peek 48 pt, параллакс 0.5, системный bold 34 pt,
    /// `.label`/`.systemBlue`, фон `.none` (§3, §4).
    func testDefaults() {
        let style = PanoramaStyle()

        XCTAssertEqual(style.peek, 48, accuracy: 0.000_001)
        XCTAssertEqual(style.parallaxFactor, 0.5, accuracy: 0.000_001)

        XCTAssertEqual(style.headerFont.pointSize, 34, accuracy: 0.000_001)
        XCTAssertTrue(
            style.headerFont.fontDescriptor.symbolicTraits.contains(.traitBold),
            "дефолтный заголовок — системный bold 34 pt (§3)"
        )

        XCTAssertEqual(style.headerColor, .label)
        XCTAssertEqual(style.headerActiveColor, .systemBlue)
        XCTAssertEqual(
            style.contentInsetAdjustmentBehavior,
            .never,
            "§8: кадр полосы секций задаёт панорама — по умолчанию без подстройки"
        )

        if case .none = style.backgroundBehavior {
            // Ожидаемый дефолт: фон не рисуется, пока картинка не задана (§9).
        } else {
            XCTFail("по умолчанию поведение фона должно быть .none")
        }
    }

    // MARK: - Кламп peek (16...64), §4

    /// `peek` зажимается в `16...64` уже в инициализаторе: наблюдатели свойств
    /// при первой записи не вызываются, поэтому без клампа в init инвариант
    /// диапазона нарушился бы.
    func testPeekClampsAtInitialization() {
        let cases: [(input: CGFloat, expected: CGFloat)] = [
            (-100, 16),
            (0, 16),
            (15.99, 16),
            (16, 16),
            (40, 40),
            (64, 64),
            (64.01, 64),
            (100, 64),
        ]

        for entry in cases {
            XCTAssertEqual(
                PanoramaStyle(peek: entry.input).peek,
                entry.expected,
                accuracy: 0.000_001,
                "peek \(entry.input) должен зажиматься в 16...64"
            )
        }
    }

    /// Нечисловые значения `peek` трактуются как дефолт 48, а не как край
    /// диапазона: `NaN` не должен «прилипать» к 16 или 64.
    func testPeekFallsBackToDefaultForNonFiniteValues() {
        for value: CGFloat in [.nan, .infinity, -.infinity] {
            XCTAssertEqual(
                PanoramaStyle(peek: value).peek,
                48,
                accuracy: 0.000_001,
                "нечисловой peek \(value) — дефолт 48"
            )
        }
    }

    /// Запись в существующий стиль клампится так же, как инициализация: снаружи
    /// невозможно вывести `peek` из диапазона.
    func testPeekClampsOnAssignment() {
        var style = PanoramaStyle()

        style.peek = 100
        XCTAssertEqual(style.peek, 64, accuracy: 0.000_001)

        style.peek = 1
        XCTAssertEqual(style.peek, 16, accuracy: 0.000_001)

        style.peek = 32
        XCTAssertEqual(style.peek, 32, accuracy: 0.000_001)

        style.peek = .nan
        XCTAssertEqual(style.peek, 48, accuracy: 0.000_001)

        style.peek = .infinity
        XCTAssertEqual(style.peek, 48, accuracy: 0.000_001)
    }

    // MARK: - Кламп parallaxFactor в (0, 1), §4 (E9.7)

    /// §4: `0 < parallaxFactor < 1`, типично 0.4–0.6. Значения внутри открытого
    /// интервала сохраняются как есть (типичный диапазон — не граница), а
    /// границы `0`/`1` и всё за ними зажимаются внутрь: `0.01...0.99`. Нулевой
    /// фактор недостижим стилем — отключение параллакса прерогатива
    /// Reduce Motion (§7).
    func testParallaxFactorClampsAtInitialization() {
        let cases: [(input: CGFloat, expected: CGFloat)] = [
            (-1, 0.01),
            (0, 0.01),
            (0.01, 0.01),
            (0.2, 0.2),
            (0.39, 0.39),
            (0.4, 0.4),
            (0.5, 0.5),
            (0.6, 0.6),
            (0.61, 0.61),
            (0.8, 0.8),
            (0.99, 0.99),
            (1, 0.99),
            (3, 0.99),
        ]

        for entry in cases {
            XCTAssertEqual(
                PanoramaStyle(parallaxFactor: entry.input).parallaxFactor,
                entry.expected,
                accuracy: 0.000_001,
                "parallaxFactor \(entry.input) должен лежать в (0, 1) по §4"
            )
        }
    }

    /// Результат клампа всегда строго внутри `(0, 1)` — ровно условие §4.
    func testParallaxFactorStaysInsideOpenUnitInterval() {
        for value: CGFloat in [-.greatestFiniteMagnitude, -1, 0, 1e-9, 0.5, 1 - 1e-9, 1, 2, .greatestFiniteMagnitude] {
            let factor = PanoramaStyle(parallaxFactor: value).parallaxFactor
            XCTAssertGreaterThan(factor, 0, "parallaxFactor \(value) → \(factor)")
            XCTAssertLessThan(factor, 1, "parallaxFactor \(value) → \(factor)")
        }
    }

    /// Нечисловые значения `parallaxFactor` трактуются как дефолт 0.5.
    func testParallaxFactorFallsBackToDefaultForNonFiniteValues() {
        for value: CGFloat in [.nan, .infinity, -.infinity] {
            XCTAssertEqual(
                PanoramaStyle(parallaxFactor: value).parallaxFactor,
                0.5,
                accuracy: 0.000_001,
                "нечисловой parallaxFactor \(value) — дефолт 0.5"
            )
        }
    }

    /// Запись в существующий стиль клампится так же, как инициализация.
    func testParallaxFactorClampsOnAssignment() {
        var style = PanoramaStyle()

        style.parallaxFactor = 0
        XCTAssertEqual(style.parallaxFactor, 0.01, accuracy: 0.000_001)

        style.parallaxFactor = 0.7
        XCTAssertEqual(style.parallaxFactor, 0.7, accuracy: 0.000_001)

        style.parallaxFactor = 1.5
        XCTAssertEqual(style.parallaxFactor, 0.99, accuracy: 0.000_001)

        style.parallaxFactor = 0.45
        XCTAssertEqual(style.parallaxFactor, 0.45, accuracy: 0.000_001)

        style.parallaxFactor = .nan
        XCTAssertEqual(style.parallaxFactor, 0.5, accuracy: 0.000_001)
    }

    // MARK: - Пользовательские значения и производная геометрия

    /// Значения внутри диапазонов сохраняются как есть, а остальные поля стиля
    /// (шрифт, цвета, фон) не подменяются клампом (§3).
    func testCustomValuesArePreserved() {
        let font = UIFont.systemFont(ofSize: 28, weight: .semibold)
        let style = PanoramaStyle(
            peek: 20,
            parallaxFactor: 0.45,
            headerFont: font,
            headerColor: .darkGray,
            headerActiveColor: .systemRed,
            backgroundBehavior: .image(nil)
        )

        XCTAssertEqual(style.peek, 20, accuracy: 0.000_001)
        XCTAssertEqual(style.parallaxFactor, 0.45, accuracy: 0.000_001)
        XCTAssertEqual(style.headerFont.pointSize, 28, accuracy: 0.000_001)
        XCTAssertEqual(style.headerColor, .darkGray)
        XCTAssertEqual(style.headerActiveColor, .systemRed)

        if case .image(let image) = style.backgroundBehavior {
            XCTAssertNil(image, "nil-картинка допустима: слой остаётся пустым (§3)")
        } else {
            XCTFail("поведение фона .image должно сохраняться в стиле")
        }
    }

    /// Кламп peek сохраняет инвариант §4: `itemWidth = width − peek` остаётся
    /// положительным даже на компактной ширине iPhone SE (320 pt).
    func testClampedPeekKeepsItemWidthPositive() {
        for width: CGFloat in [320, 375, 390, 430, 768] {
            for peek: CGFloat in [16, 40, 48, 64] {
                let style = PanoramaStyle(peek: peek)
                let itemWidth = width - style.peek

                XCTAssertGreaterThan(
                    itemWidth,
                    0,
                    "ширина \(width) и peek \(style.peek): itemWidth должен быть > 0"
                )
            }
        }
    }
}

#endif
