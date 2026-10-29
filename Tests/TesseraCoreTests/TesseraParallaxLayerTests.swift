//
//  TesseraParallaxLayerTests.swift
//  TesseraCoreTests
//
//  Контрактные тесты параллакса (задача E1.7).
//  Проектный документ: docs/Core-iOS-Design.md §2 «Ключевые контракты»
//  («Параллакс: backgroundOffset = offset × factor, factor ∈ (0, 1);
//  слой заведомо больше contentSize; Reduce Motion → фактор 0»), §3
//  «Концептуальная поверхность API» (TesseraParallaxLayer — фон + фактор + ось)
//  и §2, п. 6 (Reduce Motion).
//
//  Проверяются чистая функция `effectiveOffset(contentOffset:factor:)`,
//  пересборка `transform` при `update(withContentOffset:)` и отсечка
//  параллакса через инжектируемый провайдер Reduce Motion.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraCore

final class TesseraParallaxLayerTests: XCTestCase {

    // MARK: - Вспомогательные проверки

    /// Проверяет, что трансформ слоя — это чистый сдвиг без масштаба и поворота.
    private func assertTranslation(
        _ transform: CGAffineTransform,
        x: CGFloat,
        y: CGFloat,
        accuracy: CGFloat = 0.0001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(transform.a, 1, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(transform.b, 0, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(transform.c, 0, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(transform.d, 1, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(transform.tx, x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(transform.ty, y, accuracy: accuracy, file: file, line: line)
    }

    /// Слой с уже применённым offset'ом и прозрачным провайдером Reduce Motion.
    private func makeLayer(
        factor: CGFloat,
        offset: CGPoint,
        reduceMotion: Bool = false,
        respectsReduceMotion: Bool = true
    ) -> TesseraParallaxLayer {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { reduceMotion })
        layer.respectsReduceMotion = respectsReduceMotion
        layer.configure(factor: factor, extraSize: 0)
        layer.update(withContentOffset: offset)
        return layer
    }

    // MARK: - effectiveOffset: чистый контракт

    /// При факторе 0 фон стоит на месте независимо от offset'а.
    func testEffectiveOffsetAtFactorZero() {
        let offset = CGPoint(x: 120, y: -80)
        let result = TesseraParallaxLayer.effectiveOffset(contentOffset: offset, factor: 0)

        XCTAssertEqual(result.x, 0)
        XCTAssertEqual(result.y, 0)
    }

    /// При факторе 0.5 фон смещается ровно вдвое медленнее контента по обеим осям.
    func testEffectiveOffsetAtHalfFactor() {
        let result = TesseraParallaxLayer.effectiveOffset(
            contentOffset: CGPoint(x: 120, y: -80),
            factor: 0.5
        )

        XCTAssertEqual(result.x, 60)
        XCTAssertEqual(result.y, -40)
    }

    /// При факторе 1 фон едет вместе с контентом (крайний случай допустимого
    /// диапазона, хотя проектный диапазон — `(0, 1)`).
    func testEffectiveOffsetAtFullFactor() {
        let offset = CGPoint(x: 120, y: -80)
        let result = TesseraParallaxLayer.effectiveOffset(contentOffset: offset, factor: 1)

        XCTAssertEqual(result.x, offset.x)
        XCTAssertEqual(result.y, offset.y)
    }

    /// Знак offset'а сохраняется на обеих осях: слой сдвигается в ту же сторону.
    func testEffectiveOffsetPreservesSignOnBothAxes() {
        let result = TesseraParallaxLayer.effectiveOffset(
            contentOffset: CGPoint(x: -120, y: 80),
            factor: 0.25
        )

        XCTAssertEqual(result.x, -30)
        XCTAssertEqual(result.y, 20)
    }

    // MARK: - Конфигурация слоя

    /// `factor` — множитель по умолчанию 0.5, `extraSize` — ноль.
    func testDefaultFactorAndExtraSize() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })

        XCTAssertEqual(layer.factor, 0.5)
        XCTAssertEqual(layer.extraSize, 0)
        XCTAssertEqual(layer.contentSize, .zero)
    }

    /// `configure` отсекает фактор в `[0, 1]`; `NaN` и бесконечность трактуются
    /// как 0 (безопасное «не двигаемся»).
    func testConfigureClampsFactorToUnitRange() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })

        layer.configure(factor: 1.5, extraSize: 0)
        XCTAssertEqual(layer.factor, 1)

        layer.configure(factor: -0.5, extraSize: 0)
        XCTAssertEqual(layer.factor, 0)

        layer.configure(factor: .nan, extraSize: 0)
        XCTAssertEqual(layer.factor, 0)

        layer.configure(factor: .infinity, extraSize: 0)
        XCTAssertEqual(layer.factor, 0)

        layer.configure(factor: 0.25, extraSize: 0)
        XCTAssertEqual(layer.factor, 0.25)
    }

    /// Отрицательный и нечисловой запас размера трактуется как 0, а валидный —
    /// прибавляется к каждой оси.
    func testConfigureSanitizesExtraSize() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })

        layer.configure(factor: 0.5, extraSize: -64)
        XCTAssertEqual(layer.extraSize, 0)

        layer.configure(factor: 0.5, extraSize: .nan)
        XCTAssertEqual(layer.extraSize, 0)

        layer.configure(factor: 0.5, extraSize: .infinity)
        XCTAssertEqual(layer.extraSize, 0)

        layer.configure(factor: 0.5, extraSize: 10)
        XCTAssertEqual(layer.extraSize, 10)
    }

    /// Размер слоя равен `contentSize + extraSize` по каждой оси (Core §2:
    /// слой заведомо больше контента).
    func testSetContentSizeAddsExtraSizeOnBothAxes() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })
        layer.configure(factor: 0.5, extraSize: 64)
        layer.setContentSize(CGSize(width: 300, height: 200))

        XCTAssertEqual(layer.contentSize, CGSize(width: 300, height: 200))
        XCTAssertEqual(layer.bounds.size, CGSize(width: 364, height: 264))
    }

    /// Отрицательные и нечисловые компоненты `contentSize` трактуются как 0.
    func testSetContentSizeSanitizesDegenerateComponents() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })
        layer.configure(factor: 0.5, extraSize: 0)
        layer.setContentSize(CGSize(width: -100, height: CGFloat.nan))

        XCTAssertEqual(layer.contentSize, .zero)
        XCTAssertEqual(layer.bounds.size, .zero)
    }

    /// Инициализатор с `frame` берёт его размер как `contentSize`.
    func testFrameInitializerTakesContentSizeFromFrame() {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let layer = TesseraParallaxLayer(frame: frame)

        XCTAssertEqual(layer.contentSize, CGSize(width: 320, height: 480))
        XCTAssertEqual(layer.bounds.size, CGSize(width: 320, height: 480))
    }

    /// Повторный `configure` с теми же значениями идемпотентен: размер и
    /// трансформ не меняются.
    func testConfigureIsIdempotentForSameValues() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })
        layer.configure(factor: 0.5, extraSize: 64)
        layer.setContentSize(CGSize(width: 300, height: 200))
        layer.update(withContentOffset: CGPoint(x: 40, y: 20))

        let bounds = layer.bounds
        let transform = layer.transform

        layer.configure(factor: 0.5, extraSize: 64)

        XCTAssertEqual(layer.bounds, bounds)
        XCTAssertEqual(layer.transform, transform)
    }

    // MARK: - update(withContentOffset:) и transform

    /// `update(withContentOffset:)` меняет только `transform`: сдвиг равен
    /// `offset × factor`, масштаба и поворота нет.
    func testUpdateTranslatesLayerByEffectiveOffset() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })
        layer.configure(factor: 0.5, extraSize: 0)

        layer.update(withContentOffset: CGPoint(x: 120, y: -40))

        assertTranslation(layer.transform, x: 60, y: -20)
    }

    /// Нулевой offset оставляет слой в покое (identity-трансформ).
    func testUpdateWithZeroOffsetKeepsIdentity() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })
        layer.configure(factor: 0.5, extraSize: 0)

        layer.update(withContentOffset: .zero)

        XCTAssertEqual(layer.transform, .identity)
    }

    /// Нечисловые координаты offset'а игнорируются: `NaN` не «отравляет»
    /// `transform`, последнее валидное состояние сохраняется.
    func testUpdateIgnoresNonFiniteCoordinates() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })
        layer.configure(factor: 0.5, extraSize: 0)
        layer.update(withContentOffset: CGPoint(x: 100, y: 100))

        layer.update(withContentOffset: CGPoint(x: CGFloat.nan, y: 999))

        assertTranslation(layer.transform, x: 50, y: 50)
    }

    /// Смена `factor` пересчитывает трансформ от последнего offset'а без нового
    /// вызова `update(withContentOffset:)`.
    func testConfigureRecomputesTransformFromLastOffset() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })
        layer.configure(factor: 0.5, extraSize: 0)
        layer.update(withContentOffset: CGPoint(x: 120, y: -40))
        assertTranslation(layer.transform, x: 60, y: -20)

        layer.configure(factor: 1, extraSize: 0)
        assertTranslation(layer.transform, x: 120, y: -40)

        layer.configure(factor: 0, extraSize: 0)
        XCTAssertEqual(layer.transform, .identity)
    }

    // MARK: - Reduce Motion

    /// Reduce Motion → действующий фактор 0, даже если сконфигурирован 1:
    /// фон стоит на месте, контент продолжает скроллиться (Core §2, п. 6).
    func testReduceMotionProviderForcesZeroFactor() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { true })
        layer.configure(factor: 1, extraSize: 0)

        layer.update(withContentOffset: CGPoint(x: 200, y: 100))

        XCTAssertEqual(layer.transform, .identity)
        // Публичная конфигурация не подменяется: отключён только действующий фактор.
        XCTAssertEqual(layer.factor, 1)
    }

    /// `respectsReduceMotion == false` отключает отсечку (отладочный сценарий):
    /// фактор применяется даже при включённом Reduce Motion.
    func testRespectsReduceMotionFalseAppliesFactor() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { true })
        layer.respectsReduceMotion = false
        layer.configure(factor: 1, extraSize: 0)

        layer.update(withContentOffset: CGPoint(x: 200, y: 100))

        assertTranslation(layer.transform, x: 200, y: 100)
    }

    /// Провайдер опрашивается на каждом пересчёте: переключение Reduce Motion
    /// подхватывается следующим `update` без пересоздания слоя.
    func testProviderToggleIsAppliedOnNextUpdate() {
        var reduceMotion = true
        let layer = TesseraParallaxLayer(reduceMotionProvider: { reduceMotion })
        layer.configure(factor: 0.5, extraSize: 0)

        layer.update(withContentOffset: CGPoint(x: 100, y: 100))
        XCTAssertEqual(layer.transform, .identity)

        reduceMotion = false
        layer.update(withContentOffset: CGPoint(x: 200, y: 200))
        assertTranslation(layer.transform, x: 100, y: 100)
    }

    /// Системное уведомление о смене Reduce Motion сбрасывает сдвиг, не дожидаясь
    /// следующего `scrollViewDidScroll` (Core §2, п. 6).
    func testReduceMotionNotificationResetsTransform() {
        var reduceMotion = false
        let layer = TesseraParallaxLayer(reduceMotionProvider: { reduceMotion })
        layer.configure(factor: 0.5, extraSize: 0)
        layer.update(withContentOffset: CGPoint(x: 100, y: 100))
        assertTranslation(layer.transform, x: 50, y: 50)

        reduceMotion = true
        NotificationCenter.default.post(
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )

        XCTAssertEqual(layer.transform, .identity)
    }

    // MARK: - Декоративность слоя

    /// Слой декоративный: не перехватывает касания и не является отдельным
    /// элементом accessibility-дерева.
    func testLayerIsDecorative() {
        let layer = TesseraParallaxLayer(reduceMotionProvider: { false })

        XCTAssertFalse(layer.isUserInteractionEnabled)
        XCTAssertFalse(layer.isAccessibilityElement)
    }
}

#endif
