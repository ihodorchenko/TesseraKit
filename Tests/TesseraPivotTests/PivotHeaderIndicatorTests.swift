//
//  PivotHeaderIndicatorTests.swift
//  TesseraPivotTests
//
//  Контрактные тесты математики индикатора пивота (задача E2.7).
//  Проектный документ: docs/PIVOT-IOS-DESIGN.md §4 «Математика ядра»
//  (`indicatorCenter = lerp(center[i], center[i + 1], frac(t))`; окраска —
//  по расстоянию заголовка от `t`), §7 «Производительность» (индикатор
//  гоняется только трансформом), §11 «Риски» (интерполяция при разных
//  ширинах заголовков — самая вероятная зона визуальных багов, лечится
//  тестами на случайных наборах).
//
//  Обе проверяемые функции статические и не читают состояние — UI-цикл,
//  окно и главный поток для них не нужны.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraPivot

final class PivotHeaderIndicatorTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Детерминированный генератор (SplitMix64): случайные наборы должны
    /// воспроизводиться при падении теста, иначе баг не локализовать.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Центры заголовков разной ширины в координатах контента ленты (§4):
    /// ширина ячейки плюс промежутки и внешние отступы.
    private func makeCenters(
        widths: [CGFloat],
        inset: CGFloat = 16,
        spacing: CGFloat = 20
    ) -> [CGFloat] {
        var centers: [CGFloat] = []
        centers.reserveCapacity(widths.count)

        var originX = inset
        for width in widths {
            centers.append(originX + width / 2)
            originX += width + spacing
        }
        return centers
    }

    // MARK: - indicatorCenter: границы (t = 0, t = count - 1, за пределами)

    /// Пустой набор центров — ленты нет, индикатор скрыт и стоит в нуле.
    func testEmptyCentersReturnZero() {
        XCTAssertEqual(
            PivotHeaderIndicator.indicatorCenter(centers: [], progress: 0),
            0
        )
        XCTAssertEqual(
            PivotHeaderIndicator.indicatorCenter(centers: [], progress: 3.5),
            0
        )
    }

    /// Один заголовок (`count < 2`) — интерполировать не с чем: всегда его центр,
    /// даже на прогрессах за пределами диапазона и на `NaN`.
    func testSingleCenterIsReturnedForAnyProgress() {
        let centers: [CGFloat] = [123.5]

        for progress: CGFloat in [0, 0.25, 1, 10, -10, .nan, .infinity, -.infinity] {
            XCTAssertEqual(
                PivotHeaderIndicator.indicatorCenter(centers: centers, progress: progress),
                123.5,
                "единственный центр должен возвращаться при t=\(progress)"
            )
        }
    }

    /// `t = 0` — первый центр, `t = count - 1` — последний (§4).
    func testFirstAndLastCentersAtBounds() {
        let centers = makeCenters(widths: [40, 120, 64])

        XCTAssertEqual(
            PivotHeaderIndicator.indicatorCenter(centers: centers, progress: 0),
            centers[0]
        )
        XCTAssertEqual(
            PivotHeaderIndicator.indicatorCenter(centers: centers, progress: CGFloat(centers.count - 1)),
            centers[2]
        )
    }

    /// При bounce прогресс уходит за диапазон, но индикатор не должен уезжать
    /// за крайние заголовки — кламп в `0...count - 1` (§4).
    func testOutOfRangeProgressClampsToEdgeCenters() {
        let centers = makeCenters(widths: [40, 120, 64, 200])

        for progress: CGFloat in [-0.001, -1, -100, -CGFloat.greatestFiniteMagnitude] {
            XCTAssertEqual(
                PivotHeaderIndicator.indicatorCenter(centers: centers, progress: progress),
                centers[0],
                "t=\(progress) должен зажиматься к первому центру"
            )
        }

        for progress: CGFloat in [4.001, 4.5, 100, CGFloat.greatestFiniteMagnitude] {
            XCTAssertEqual(
                PivotHeaderIndicator.indicatorCenter(centers: centers, progress: progress),
                centers[3],
                "t=\(progress) должен зажиматься к последнему центру"
            )
        }
    }

    /// `NaN` — неопределённый прогресс трактуется как начало ленты.
    func testNaNProgressReturnsFirstCenter() {
        let centers = makeCenters(widths: [40, 120, 64])
        XCTAssertEqual(
            PivotHeaderIndicator.indicatorCenter(centers: centers, progress: .nan),
            centers[0]
        )
    }

    /// Бесконечности зажимаются границами (и не переполняют приведение к `Int`).
    func testInfiniteProgressClampsToEdgeCenters() {
        let centers = makeCenters(widths: [40, 120, 64, 200])
        XCTAssertEqual(
            PivotHeaderIndicator.indicatorCenter(centers: centers, progress: .infinity),
            centers[3]
        )
        XCTAssertEqual(
            PivotHeaderIndicator.indicatorCenter(centers: centers, progress: -.infinity),
            centers[0]
        )
    }

    // MARK: - indicatorCenter: интерполяция между центрами разной ширины

    /// На целых `t` индикатор стоит ровно на центре соответствующего заголовка:
    /// важна «тонкость» §4 — интерполируются центры, а не `t × constWidth`.
    func testIntegerProgressReturnsExactCenter() {
        let centers = makeCenters(widths: [36, 120, 64, 200, 88])

        for index in centers.indices {
            XCTAssertEqual(
                PivotHeaderIndicator.indicatorCenter(
                    centers: centers,
                    progress: CGFloat(index)
                ),
                centers[index],
                accuracy: 0.000_001,
                "t=\(index) должен давать центр заголовка \(index)"
            )
        }
    }

    /// Половина перехода между заголовками разной ширины — ровно середина
    /// отрезка между их центрами, а не точка «t × средняя ширина» (§4).
    func testInterpolationFollowsCentersNotConstantWidthSteps() {
        let widths: [CGFloat] = [40, 160, 60, 220]
        let centers = makeCenters(widths: widths)

        let midpoint = PivotHeaderIndicator.indicatorCenter(centers: centers, progress: 0.5)
        XCTAssertEqual(midpoint, (centers[0] + centers[1]) / 2, accuracy: 0.000_001)

        // Ложная модель «равные шаги» дала бы на этих ширинах заметно другое
        // значение — индикатор «уплыл» бы от текста на середине свайпа.
        let averageStep = (centers[centers.count - 1] - centers[0]) / CGFloat(centers.count - 1)
        let constantStepMidpoint = centers[0] + averageStep * 0.5
        XCTAssertGreaterThan(
            abs(midpoint - constantStepMidpoint),
            1,
            "интерполяция центров должна отличаться от линейного шага при разных ширинах"
        )
    }

    /// Дробный прогресс даёт `lerp(center[i], center[i + 1], frac(t))`, где
    /// `i = floor(t)`, а на последнем переходе дробная часть берётся от
    /// зажатого прогресса (иначе индикатор уехал бы за последний заголовок).
    func testInterpolationUsesFractionOfClampedProgress() {
        let centers = makeCenters(widths: [40, 120, 64])

        XCTAssertEqual(
            PivotHeaderIndicator.indicatorCenter(centers: centers, progress: 0.25),
            centers[0] + (centers[1] - centers[0]) * 0.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PivotHeaderIndicator.indicatorCenter(centers: centers, progress: 1.25),
            centers[1] + (centers[2] - centers[1]) * 0.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PivotHeaderIndicator.indicatorCenter(centers: centers, progress: 1.75),
            centers[1] + (centers[2] - centers[1]) * 0.75,
            accuracy: 0.000_001
        )
        // t = count - 1 + 0.5 зажимается в последний центр, а не интерполирует
        // ещё раз от последней пары с дробной частью 1.5.
        XCTAssertEqual(
            PivotHeaderIndicator.indicatorCenter(centers: centers, progress: 2.5),
            centers[2],
            accuracy: 0.000_001
        )
    }

    /// На границе целого индекса функция непрерывна: слева и справа от `t = i`
    /// значения совпадают в пределах малой окрестности.
    func testIndicatorCenterIsContinuousAcrossIntegerBoundary() {
        let centers = makeCenters(widths: [50, 140, 70, 210])

        for index in 1..<centers.count {
            let epsilon: CGFloat = 0.000_001
            let left = PivotHeaderIndicator.indicatorCenter(
                centers: centers,
                progress: CGFloat(index) - epsilon
            )
            let right = PivotHeaderIndicator.indicatorCenter(
                centers: centers,
                progress: CGFloat(index) + epsilon
            )

            XCTAssertEqual(left, centers[index], accuracy: 0.001)
            XCTAssertEqual(right, centers[index], accuracy: 0.001)
        }
    }

    /// Случайные наборы центров с произвольными ширинами и промежутками:
    /// результат обязан совпасть с независимым расчётом `lerp(frac)`, где `t`
    /// строится как `i + frac`, а не наоборот.
    func testRandomUnevenCenterSetsFollowLerp() {
        var generator = SeededGenerator(seed: 0x5EED_1234)

        for _ in 0..<50 {
            let count = Int.random(in: 2...8, using: &generator)
            var centers: [CGFloat] = []
            centers.reserveCapacity(count)

            var position = CGFloat.random(in: 0...40, using: &generator)
            for _ in 0..<count {
                let width = CGFloat.random(in: 20...180, using: &generator)
                centers.append(position + width / 2)
                position += width + CGFloat.random(in: 4...40, using: &generator)
            }

            for _ in 0..<10 {
                let lowerIndex = Int.random(in: 0..<(count - 1), using: &generator)
                let fraction = CGFloat.random(in: 0...1, using: &generator)
                let progress = CGFloat(lowerIndex) + fraction

                let expected = centers[lowerIndex] * (1 - fraction)
                    + centers[lowerIndex + 1] * fraction
                let actual = PivotHeaderIndicator.indicatorCenter(
                    centers: centers,
                    progress: progress
                )

                XCTAssertEqual(
                    actual,
                    expected,
                    accuracy: 0.000_001,
                    "lerp на случайных центрах \(centers), t=\(progress)"
                )

                // Индикатор не выходит за отрезок между соседними центрами.
                let lowerCenter = min(centers[lowerIndex], centers[lowerIndex + 1])
                let upperCenter = max(centers[lowerIndex], centers[lowerIndex + 1])
                XCTAssertGreaterThanOrEqual(actual, lowerCenter - 0.000_001)
                XCTAssertLessThanOrEqual(actual, upperCenter + 0.000_001)
            }
        }
    }

    /// Случайные прогрессы за пределами диапазона на случайных наборах
    /// зажимаются к крайним центрам.
    func testRandomOutOfRangeProgressClamps() {
        var generator = SeededGenerator(seed: 0xC0FF_EE01)

        for _ in 0..<25 {
            let count = Int.random(in: 2...7, using: &generator)
            var centers: [CGFloat] = []
            centers.reserveCapacity(count)

            var position = CGFloat.random(in: 0...30, using: &generator)
            for _ in 0..<count {
                let width = CGFloat.random(in: 30...160, using: &generator)
                centers.append(position + width / 2)
                position += width + CGFloat.random(in: 5...35, using: &generator)
            }

            let below = -CGFloat.random(in: 0.001...100, using: &generator)
            XCTAssertEqual(
                PivotHeaderIndicator.indicatorCenter(centers: centers, progress: below),
                centers[0]
            )

            let above = CGFloat(count - 1) + CGFloat.random(in: 0.001...100, using: &generator)
            XCTAssertEqual(
                PivotHeaderIndicator.indicatorCenter(centers: centers, progress: above),
                centers[count - 1]
            )
        }
    }

    /// На возрастающих наборах центров индикатор монотонно едет слева направо:
    /// ни рывков назад, ни «телепортов» через заголовки (§4).
    func testRandomSortedCentersProduceMonotonicPositions() {
        var generator = SeededGenerator(seed: 0xB16_5EED)

        for _ in 0..<20 {
            let count = Int.random(in: 2...7, using: &generator)
            var centers: [CGFloat] = []
            centers.reserveCapacity(count)

            var position = CGFloat.random(in: 0...30, using: &generator)
            for _ in 0..<count {
                let width = CGFloat.random(in: 30...200, using: &generator)
                centers.append(position + width / 2)
                position += width + CGFloat.random(in: 8...40, using: &generator)
            }

            var previous = -CGFloat.greatestFiniteMagnitude
            let steps = 200

            for step in 0...steps {
                let progress = CGFloat(step) / CGFloat(steps) * CGFloat(count - 1)
                let center = PivotHeaderIndicator.indicatorCenter(
                    centers: centers,
                    progress: progress
                )

                XCTAssertGreaterThanOrEqual(
                    center,
                    previous - 0.000_001,
                    "индикатор поехал назад на t=\(progress), центры \(centers)"
                )
                previous = center
            }
        }
    }

    // MARK: - blendFactor: окраска по расстоянию от t (§4)

    /// В точке `t` заголовок полностью активен: коэффициент `1` означает
    /// полный акцентный цвет (§4, «Окраска текста»). Контракт инвертирован
    /// относительно формулировки «0 на расстоянии 0»: в коде и документе
    /// `1` — акцент, `0` — неактивное состояние.
    func testBlendFactorIsFullAccentAtZeroDistance() {
        XCTAssertEqual(PivotHeaderIndicator.blendFactor(distanceFromProgress: 0), 1)
        XCTAssertEqual(PivotHeaderIndicator.blendFactor(distanceFromProgress: -0), 1)
        XCTAssertEqual(PivotHeaderIndicator.blendFactor(distanceFromProgress: 0, span: 3), 1)
    }

    /// На расстоянии `span` и дальше подсветки нет: коэффициент `0`.
    func testBlendFactorReachesZeroAtSpan() {
        XCTAssertEqual(PivotHeaderIndicator.blendFactor(distanceFromProgress: 1), 0)
        XCTAssertEqual(PivotHeaderIndicator.blendFactor(distanceFromProgress: -1), 0)
        XCTAssertEqual(PivotHeaderIndicator.blendFactor(distanceFromProgress: 5), 0)
        XCTAssertEqual(PivotHeaderIndicator.blendFactor(distanceFromProgress: -5), 0)
        XCTAssertEqual(PivotHeaderIndicator.blendFactor(distanceFromProgress: 2, span: 2), 0)
    }

    /// Внутри `span` коэффициент линеен и симметричен по знаку расстояния.
    func testBlendFactorIsSymmetricAndLinearWithinSpan() {
        for distance: CGFloat in [0.1, 0.25, 0.5, 0.75, 0.9] {
            let expected = 1 - distance
            XCTAssertEqual(
                PivotHeaderIndicator.blendFactor(distanceFromProgress: distance),
                expected,
                accuracy: 0.000_001
            )
            XCTAssertEqual(
                PivotHeaderIndicator.blendFactor(distanceFromProgress: -distance),
                expected,
                accuracy: 0.000_001
            )
        }
    }

    /// Коэффициент монотонно убывает с расстоянием и остаётся в `0...1`:
    /// акцент плавно «передаётся» от уходящего заголовка приходящему.
    func testBlendFactorIsMonotonicallyDecreasing() {
        var previous = PivotHeaderIndicator.blendFactor(distanceFromProgress: 0)

        for step in 1...40 {
            let distance = CGFloat(step) * 0.05
            let factor = PivotHeaderIndicator.blendFactor(distanceFromProgress: distance)

            XCTAssertLessThanOrEqual(factor, previous + 0.000_001)
            XCTAssertGreaterThanOrEqual(factor, 0)
            XCTAssertLessThanOrEqual(factor, 1)
            previous = factor
        }
    }

    /// Радиус подсветки масштабирует расстояние: при `span = 2` половина
    /// акцента — на расстоянии `1`.
    func testBlendFactorHonoursCustomSpan() {
        XCTAssertEqual(
            PivotHeaderIndicator.blendFactor(distanceFromProgress: 0.5, span: 2),
            0.75,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PivotHeaderIndicator.blendFactor(distanceFromProgress: 1, span: 2),
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PivotHeaderIndicator.blendFactor(distanceFromProgress: 1.5, span: 2),
            0.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PivotHeaderIndicator.blendFactor(distanceFromProgress: 3, span: 2),
            0,
            accuracy: 0.000_001
        )
    }

    /// `span <= 0` — «размывать нечего»: `1` ровно в точке и `0` в остальных
    /// случаях (защитный контракт документирован у метода).
    func testBlendFactorWithNonPositiveSpanDegradesToBinary() {
        for span: CGFloat in [0, -1, -0.5] {
            XCTAssertEqual(
                PivotHeaderIndicator.blendFactor(distanceFromProgress: 0, span: span),
                1
            )
            XCTAssertEqual(
                PivotHeaderIndicator.blendFactor(distanceFromProgress: 0.1, span: span),
                0
            )
            XCTAssertEqual(
                PivotHeaderIndicator.blendFactor(distanceFromProgress: -2, span: span),
                0
            )
        }
    }

    /// `NaN` и бесконечное расстояние — неизвестный заголовок считается
    /// неактивным (`0`), без падения и без «отравления» цвета.
    func testBlendFactorRejectsNaNAndInfiniteDistance() {
        XCTAssertEqual(PivotHeaderIndicator.blendFactor(distanceFromProgress: .nan), 0)
        XCTAssertEqual(
            PivotHeaderIndicator.blendFactor(distanceFromProgress: 0.5, span: .nan),
            0
        )
        XCTAssertEqual(PivotHeaderIndicator.blendFactor(distanceFromProgress: .infinity), 0)
        XCTAssertEqual(PivotHeaderIndicator.blendFactor(distanceFromProgress: -.infinity), 0)
    }

    // MARK: - Вид индикатора (§3, §7, §8)

    /// Дефолты вида: подчёркивание 24×3 pt, акцентный цвет, декоративность —
    /// индикатор не ловит события и не попадает в accessibility-дерево (§8).
    func testViewDefaults() {
        let indicator = PivotHeaderIndicator()

        XCTAssertEqual(indicator.barWidth, 24)
        XCTAssertEqual(indicator.barHeight, 3)
        XCTAssertEqual(indicator.activeColor, .systemBlue)
        XCTAssertEqual(indicator.backgroundColor, .systemBlue)
        XCTAssertFalse(indicator.isUserInteractionEnabled)
        XCTAssertFalse(indicator.isAccessibilityElement)
        XCTAssertTrue(indicator.isHidden)
    }

    /// `placeBar(inStripBounds:)` — единственное место, где задаются
    /// `bounds`/`center` индикатора; позиция прижата к нижней кромке ленты.
    func testPlaceBarSetsBaseGeometry() {
        let indicator = PivotHeaderIndicator()
        indicator.placeBar(inStripBounds: CGRect(x: 10, y: 20, width: 320, height: 48))

        XCTAssertEqual(indicator.bounds.width, 24)
        XCTAssertEqual(indicator.bounds.height, 3)
        XCTAssertEqual(indicator.center.x, 12)
        // Нижняя кромка ленты: maxY - barHeight / 2.
        XCTAssertEqual(indicator.center.y, 66.5, accuracy: 0.000_001)
        XCTAssertEqual(indicator.layer.cornerRadius, 1.5)
        XCTAssertEqual(indicator.transform, .identity)
    }

    /// Горячий путь (§4, §7): `move(toCenterX:)` меняет только `transform`,
    /// не трогая `bounds`/`center` и не запуская layout.
    func testMoveChangesOnlyTransform() {
        let indicator = PivotHeaderIndicator()
        indicator.placeBar(inStripBounds: CGRect(x: 0, y: 0, width: 320, height: 48))

        let boundsBefore = indicator.bounds
        let centerBefore = indicator.center

        indicator.move(toCenterX: 100)

        XCTAssertEqual(indicator.transform.tx, 100 - 24 / 2, accuracy: 0.000_001)
        XCTAssertEqual(indicator.bounds, boundsBefore)
        XCTAssertEqual(indicator.center, centerBefore)

        indicator.move(toCenterX: 250)

        XCTAssertEqual(indicator.transform.tx, 250 - 24 / 2, accuracy: 0.000_001)
        XCTAssertEqual(indicator.bounds, boundsBefore)
        XCTAssertEqual(indicator.center, centerBefore)
    }
}

#endif
