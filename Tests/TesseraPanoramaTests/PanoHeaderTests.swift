//
//  PanoHeaderTests.swift
//  TesseraPanoramaTests
//
//  Контрактные тесты математики заголовков панорамы (задача E3.7).
//  Проектный документ: docs/PANORAMA-IOS-DESIGN.md §4 «Геометрия и математика
//  ядра» («Заголовки: кусочно-линейная интерполяция между ключевыми кадрами
//  0, 0.5, 1») и §7 «Accessibility и системная интеграция» (Reduce Motion —
//  параллакс и анимации заголовков отключаются, остаётся статичное состояние).
//
//  Проверяются: чистые `keyframeAlpha`/`keyframeOffset` (ключевые кадры,
//  линейность между ними, монотонность, симметрия, кламп за пределами,
//  защитные `NaN`/бесконечности) и поведение слоя заголовков с инжектируемым
//  провайдером Reduce Motion (заголовки статичны, виден только активный).
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraPanorama

final class PanoHeaderTests: XCTestCase {

    /// Ширина слоя заголовков для проверок `transform` (§4: `travel = width × 0.3`).
    private let width: CGFloat = 390

    /// Полный размах сдвига при `travelRatio == 0.3` (дефолт стиля слоя).
    private var travel: CGFloat { width * 0.3 }

    // MARK: - Вспомогательные средства

    private func alpha(_ phase: CGFloat) -> CGFloat {
        TesseraPanoHeaderView.keyframeAlpha(progress: phase)
    }

    private func offset(_ phase: CGFloat, travel: CGFloat = 100) -> CGFloat {
        TesseraPanoHeaderView.keyframeOffset(progress: phase, travel: travel)
    }

    /// Слой заголовков с принудительным LTR: знак сдвига не зависит от
    /// системного языка тестового симулятора (§7, «RTL»).
    ///
    /// Reduce Motion по умолчанию выключен явно: анимированные контракты не
    /// должны зависеть от системной настройки машины, на которой идут тесты.
    private func makeHeader(
        titles: [String] = ["Один", "Два", "Три"]
    ) -> TesseraPanoHeaderView {
        let header = TesseraPanoHeaderView(titles: titles)
        header.semanticContentAttribute = .forceLeftToRight
        header.isReduceMotionEnabled = { false }
        header.frame = CGRect(x: 0, y: 0, width: width, height: 120)
        header.layoutIfNeeded()
        return header
    }

    /// Метки в порядке чтения: `rebuildLabels()` добавляет их по порядку titles.
    private func headerLabels(in header: TesseraPanoHeaderView) -> [UILabel] {
        header.subviews.compactMap { $0 as? UILabel }
    }

    // MARK: - keyframeAlpha: ключевые кадры (§4)

    /// Ключевые кадры альфы: `0 → 0`, `0.5 → 1`, `1 → 0`.
    func testAlphaKeyframes() {
        XCTAssertEqual(alpha(0), 0)
        XCTAssertEqual(alpha(0.5), 1)
        XCTAssertEqual(alpha(1), 0)
    }

    /// Между кадрами альфа линейна: `2x` до центра и `2 − 2x` после.
    func testAlphaIsLinearBetweenKeyframes() {
        let cases: [(phase: CGFloat, expected: CGFloat)] = [
            (0.1, 0.2),
            (0.25, 0.5),
            (0.4, 0.8),
            (0.5, 1),
            (0.6, 0.8),
            (0.75, 0.5),
            (0.9, 0.2),
        ]

        for entry in cases {
            XCTAssertEqual(
                alpha(entry.phase),
                entry.expected,
                accuracy: 0.000_001,
                "альфа на фазе \(entry.phase)"
            )
        }
    }

    /// Альфа монотонно растёт до центра и монотонно убывает после: заголовок не
    /// «мигает» на переходе (§4).
    func testAlphaIsMonotonicAroundCenter() {
        var previous = alpha(0)

        for step in 1...100 {
            let phase = CGFloat(step) / 100
            let value = alpha(phase)

            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)

            if phase <= 0.5 {
                XCTAssertGreaterThanOrEqual(
                    value,
                    previous - 0.000_001,
                    "альфа должна расти на фазе \(phase)"
                )
            } else {
                XCTAssertLessThanOrEqual(
                    value,
                    previous + 0.000_001,
                    "альфа должна убывать на фазе \(phase)"
                )
            }
            previous = value
        }
    }

    /// За пределами `0...1` фаза зажимается: альфа остаётся 0, включая bounce,
    /// `NaN` и бесконечности.
    func testAlphaClampsOutsideKeyframeRange() {
        for phase: CGFloat in [-1, -0.001, 1.001, 2, 100] {
            XCTAssertEqual(alpha(phase), 0, accuracy: 0.000_001, "фаза \(phase)")
        }

        XCTAssertEqual(alpha(.nan), 0)
        XCTAssertEqual(alpha(.infinity), 0)
        XCTAssertEqual(alpha(-.infinity), 0)
    }

    /// Альфа симметрична относительно середины: соседние секции проявляются
    /// одинаково до и после центра (§4).
    func testAlphaIsSymmetricAroundCenter() {
        for delta: CGFloat in [0, 0.1, 0.25, 0.4, 0.5] {
            XCTAssertEqual(
                alpha(0.5 - delta),
                alpha(0.5 + delta),
                accuracy: 0.000_001,
                "симметрия альфы при отклонении \(delta)"
            )
        }
    }

    // MARK: - keyframeOffset: ключевые кадры (§4)

    /// Ключевые кадры сдвига: `0 → −travel/2`, `0.5 → 0`, `1 → +travel/2`.
    func testOffsetKeyframes() {
        XCTAssertEqual(offset(0, travel: 100), -50)
        XCTAssertEqual(offset(0.5, travel: 100), 0)
        XCTAssertEqual(offset(1, travel: 100), 50)
    }

    /// Сдвиг линейно интерполируется: `offset = (x − 0.5) × travel`.
    func testOffsetIsLinearBetweenKeyframes() {
        XCTAssertEqual(offset(0.25, travel: 100), -25, accuracy: 0.000_001)
        XCTAssertEqual(offset(0.4, travel: 100), -10, accuracy: 0.000_001)
        XCTAssertEqual(offset(0.6, travel: 100), 10, accuracy: 0.000_001)
        XCTAssertEqual(offset(0.75, travel: 100), 25, accuracy: 0.000_001)
    }

    /// За пределами ключевых кадров фаза зажимается, сдвиг не уезжает дальше
    /// `±travel/2`; `NaN` даёт нулевой сдвиг (защитный контракт метода).
    func testOffsetClampsOutsideKeyframeRange() {
        XCTAssertEqual(offset(-1, travel: 100), -50)
        XCTAssertEqual(offset(2, travel: 100), 50)
        XCTAssertEqual(offset(-.infinity, travel: 100), -50)
        XCTAssertEqual(offset(.infinity, travel: 100), 50)
        XCTAssertEqual(offset(.nan, travel: 100), 0)
    }

    /// Сдвиг антисимметричен относительно центра: уходящая и приходящая метки
    /// отклоняются в разные стороны одинаково (§4).
    func testOffsetIsAntisymmetricAroundCenter() {
        for delta: CGFloat in [0, 0.1, 0.25, 0.4, 0.5] {
            XCTAssertEqual(
                offset(0.5 - delta, travel: 100),
                -offset(0.5 + delta, travel: 100),
                accuracy: 0.000_001,
                "антисимметрия сдвига при отклонении \(delta)"
            )
        }
    }

    /// Знак амплитуды задаёт вызывающий: отрицательный `travel` меняет знак
    /// сдвига, нулевой — обнуляет его (§4, «RTL»).
    func testOffsetRespectsTravelSignAndZero() {
        XCTAssertEqual(offset(0.75, travel: -100), -25, accuracy: 0.000_001)
        XCTAssertEqual(offset(0.25, travel: -100), 25, accuracy: 0.000_001)

        for phase: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            XCTAssertEqual(offset(phase, travel: 0), 0, accuracy: 0.000_001)
        }
    }

    // MARK: - Применение прогресса к меткам (§4)

    /// На `t = 0.5` обе соседние метки видны с альфой 0.5, третья погашена;
    /// сдвиги соседей противоположны по знаку (`travel = 390 × 0.3 = 117`).
    func testApplyProgressFadesNeighbourHeaders() {
        let header = makeHeader()
        header.apply(progress: 0.5, activeIndex: 0)

        let labels = headerLabels(in: header)
        XCTAssertEqual(labels.count, 3)

        XCTAssertEqual(labels[0].alpha, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(labels[1].alpha, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(labels[2].alpha, 0, accuracy: 0.000_001)

        XCTAssertEqual(labels[0].transform.tx, -travel / 4, accuracy: 0.000_001)
        XCTAssertEqual(labels[1].transform.tx, travel / 4, accuracy: 0.000_001)
    }

    /// На целых `t` видна ровно одна метка: активная стоит без сдвига, соседи
    /// полностью прозрачны. Это ключевые кадры 0.5/0/1 через `apply`.
    func testApplyProgressAtIntegerShowsSingleActiveHeader() {
        let header = makeHeader()

        header.apply(progress: 1, activeIndex: 1)
        var labels = headerLabels(in: header)
        XCTAssertEqual(labels.map(\.alpha), [0, 1, 0])
        XCTAssertEqual(labels[1].transform, .identity)
        XCTAssertEqual(header.accessibilityLabel, "Два")

        header.apply(progress: 2, activeIndex: 2)
        labels = headerLabels(in: header)
        XCTAssertEqual(labels.map(\.alpha), [0, 0, 1])
        XCTAssertEqual(header.accessibilityLabel, "Три")
    }

    /// Прогресс за границы ленты (bounce) зажимается: крайний заголовок не
    /// «затухает» при упругом отскоке (§4).
    func testApplyProgressClampsOutOfRangeValues() {
        let header = makeHeader()

        header.apply(progress: 10, activeIndex: 2)
        XCTAssertEqual(headerLabels(in: header).map(\.alpha), [0, 0, 1])

        header.apply(progress: -5, activeIndex: 0)
        XCTAssertEqual(headerLabels(in: header).map(\.alpha), [1, 0, 0])
    }

    // MARK: - Reduce Motion (§7)

    /// При включённом Reduce Motion заголовки статичны: виден только активный,
    /// без сдвига и фейдов, независимо от дробного прогресса.
    func testReduceMotionShowsOnlyActiveHeader() {
        let header = makeHeader()
        header.isReduceMotionEnabled = { true }

        header.apply(progress: 1.5, activeIndex: 1)

        let labels = headerLabels(in: header)
        XCTAssertEqual(labels.map(\.alpha), [0, 1, 0])

        for label in labels {
            XCTAssertEqual(
                label.transform,
                .identity,
                "при Reduce Motion сдвига заголовков быть не должно"
            )
        }
        XCTAssertEqual(header.accessibilityLabel, "Два")
    }

    /// Провайдер читается при каждом `apply`: включение/выключение Reduce Motion
    /// на лету переключает статичное и анимированное состояние (§7).
    func testReduceMotionProviderIsReadOnEachApply() {
        let header = makeHeader()
        var reduceMotion = true
        header.isReduceMotionEnabled = { reduceMotion }

        header.apply(progress: 0.5, activeIndex: 0)
        XCTAssertEqual(headerLabels(in: header).map(\.alpha), [1, 0, 0])
        XCTAssertTrue(headerLabels(in: header).allSatisfy { $0.transform == .identity })

        reduceMotion = false
        header.apply(progress: 0.5, activeIndex: 0)
        var labels = headerLabels(in: header)
        XCTAssertEqual(labels[0].alpha, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(labels[1].alpha, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(labels[2].alpha, 0, accuracy: 0.000_001)
        XCTAssertEqual(labels[0].transform.tx, -travel / 4, accuracy: 0.000_001)
        XCTAssertEqual(labels[1].transform.tx, travel / 4, accuracy: 0.000_001)

        reduceMotion = true
        header.apply(progress: 0.5, activeIndex: 0)
        labels = headerLabels(in: header)
        XCTAssertEqual(labels.map(\.alpha), [1, 0, 0])
        XCTAssertTrue(labels.allSatisfy { $0.transform == .identity })
    }
}

#endif
