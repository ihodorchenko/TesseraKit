//
//  TileMergeHoverTests.swift
//  TesseraStartScreenTests
//
//  Тесты слияния в папку по удержанию (задача E8.6).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §5 «Режим редактирования»
//  и docs/PLAN.md E8.6/E9.8а: папка из двух ярлыков создаётся не мгновенно по
//  drop на центр плитки-цели, а после удержания **строго больше** 600 мс при
//  смещении пальца **строго меньше** 10 pt.
//
//  Проверяется чистая state-машина `TesseraMergeHoverTracker` (никакого UI):
//  строгие границы допуска и времени, перевзвод после возврата в допуск
//  (E10.5-A3), сбросы, готовность к drop. Часы и таймер инжектируются,
//  поэтому тесты не спят и не флакуют.
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileMergeHoverTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Управляемые часы state-машины: время двигает тест, а не runloop.
    private final class TestClock {

        /// Текущее «монотонное» время в секундах.
        var time: TimeInterval = 0

        /// Продвигает часы.
        ///
        /// - Parameter interval: Приращение в секундах.
        func advance(_ interval: TimeInterval) {
            time += interval
        }
    }

    /// Трекер на управляемых часах с параметрами из конфигурации.
    ///
    /// - Parameters:
    ///   - clock: Часы теста.
    ///   - configuration: Конфигурация редактирования (по умолчанию — боевые
    ///     значения: 600 мс и 10 pt).
    /// - Returns: Машина удержания, читающая время из `clock`.
    private func makeTracker(
        _ clock: TestClock,
        configuration: TesseraTileEditConfiguration = TesseraTileEditConfiguration()
    ) -> TesseraMergeHoverTracker {
        TesseraMergeHoverTracker(
            hoverDuration: configuration.mergeHoverDuration,
            displacementThreshold: configuration.mergeHoverDisplacement,
            now: { clock.time }
        )
    }

    /// Взводит удержание над ярлыком «a» в заданной точке.
    ///
    /// - Parameters:
    ///   - tracker: Машина удержания.
    ///   - point: Точка пальца (якорь допуска).
    private func arm(_ tracker: inout TesseraMergeHoverTracker, at point: CGPoint = .zero) {
        tracker.beginHover(targetID: "a", point: point)
    }

    // MARK: - Конфигурация

    /// Значения по умолчанию: 600 мс удержания, 10 pt допуска и подсветка
    /// «впитывания» ~0,2 с в диапазоне 1.06–1.1.
    func testConfigurationDefaultsMatchSpec() {
        let configuration = TesseraTileEditConfiguration()

        XCTAssertEqual(configuration.mergeHoverDuration, 0.6, accuracy: 0.0001)
        XCTAssertEqual(configuration.mergeHoverDisplacement, 10, accuracy: 0.0001)
        XCTAssertEqual(configuration.mergeHighlightDuration, 0.2, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(configuration.mergeHighlightScale, 1.06)
        XCTAssertLessThanOrEqual(configuration.mergeHighlightScale, 1.1)
    }

    /// Пороги из конфигурации доходят до машины удержания без искажений.
    func testConfigurationThresholdsAreRespected() {
        let clock = TestClock()
        var configuration = TesseraTileEditConfiguration()
        configuration.mergeHoverDuration = 0.1
        configuration.mergeHoverDisplacement = 4
        var tracker = makeTracker(clock, configuration: configuration)

        arm(&tracker)

        // 3 pt — внутри допуска (`<4 pt` в этом тесте): удержание продолжается.
        tracker.update(point: CGPoint(x: 3, y: 0))
        XCTAssertEqual(tracker.state, .armed)

        // 4 pt — ровно допуск: строгая граница E9.8а, удержание отменено.
        tracker.update(point: CGPoint(x: 4, y: 0))
        XCTAssertEqual(tracker.state, .cancelled)

        // Возврат в исходное состояние и проверка укороченного таймера.
        tracker.reset()
        arm(&tracker)
        clock.advance(0.05)
        XCTAssertFalse(tracker.timerFired())
        XCTAssertEqual(tracker.state, .armed)
        // Ровно порог (0,1 с) — ещё не готовность: сравнение строгое.
        clock.advance(0.05)
        XCTAssertFalse(tracker.timerFired())
        clock.advance(0.01)
        XCTAssertTrue(tracker.timerFired())
        XCTAssertEqual(tracker.state, .fired)
    }

    // MARK: - Порог смещения (10 px)

    /// Смещение внутри допуска удержание не отменяет.
    func testSmallDisplacementKeepsArmed() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)

        for offset in [CGPoint(x: 3, y: 0), CGPoint(x: 0, y: 9), CGPoint(x: -7, y: 6)] {
            tracker.update(point: offset)
            XCTAssertEqual(tracker.state, .armed, "Смещение \(offset) должно оставаться в допуске")
        }
    }

    /// Ровно 10 pt — граница допуска; E9.8а требует смещения строго меньше,
    /// поэтому ровно на допуске удержание отменяется.
    func testDisplacementExactlyAtThresholdCancels() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        // Пифагорова тройка 6–8–10: смещение ровно 10 pt.
        tracker.update(point: CGPoint(x: 6, y: 8))

        XCTAssertEqual(tracker.state, .cancelled)
        XCTAssertFalse(tracker.isMergeReady)
    }

    /// Чуть меньше 10 pt — удержание ещё в силе (граница строгая).
    func testDisplacementJustInsideThresholdKeepsArmed() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        tracker.update(point: CGPoint(x: 6, y: 7.999))

        XCTAssertEqual(tracker.state, .armed)
    }

    /// Смещение больше 10 pt отменяет удержание.
    func testLargeDisplacementCancels() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        tracker.update(point: CGPoint(x: 11, y: 0))

        XCTAssertEqual(tracker.state, .cancelled)
        XCTAssertFalse(tracker.isMergeReady)
        XCTAssertFalse(tracker.isArmed)
    }

    /// Якорь — точка начала удержания, а не предыдущий шаг: несколько мелких
    /// шагов в одну сторону суммируются.
    func testDisplacementIsMeasuredFromAnchorNotFromLastStep() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        for step in 1...3 {
            tracker.update(point: CGPoint(x: CGFloat(step) * 5, y: 0))
        }

        // Каждый шаг по 5 pt: на втором шаге от якоря уже 10 pt — строгий
        // допуск E9.8а отменяет удержание.
        XCTAssertEqual(tracker.state, .cancelled)
    }

    /// После отмены таймер не «воскрешает» готовность.
    func testCancelledStateIgnoresTimer() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        tracker.update(point: CGPoint(x: 12, y: 0))
        clock.advance(1)

        XCTAssertFalse(tracker.timerFired())
        XCTAssertEqual(tracker.state, .cancelled)
    }

    /// Вне допуска отмена остаётся в силе: мелкое движение у края зоны не
    /// возвращает готовность.
    func testStayOutsideToleranceKeepsCancelled() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        tracker.update(point: CGPoint(x: 20, y: 0))
        XCTAssertEqual(tracker.state, .cancelled)

        tracker.update(point: CGPoint(x: 15, y: 0))
        XCTAssertEqual(tracker.state, .cancelled)
        XCTAssertFalse(tracker.isMergeReady)
    }

    /// E10.5-A3: возврат пальца в допуск запускает новый отсчёт с полным
    /// порогом, а не мгновенную готовность.
    func testReturnToToleranceRearmsCountdown() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        tracker.update(point: CGPoint(x: 20, y: 0))
        XCTAssertEqual(tracker.state, .cancelled)

        clock.advance(1.0)
        tracker.update(point: CGPoint(x: 4, y: 0))

        XCTAssertEqual(tracker.state, .armed)
        XCTAssertFalse(tracker.isMergeReady)
        XCTAssertEqual(tracker.remainingDuration, 0.6, accuracy: 0.0001)

        clock.advance(0.59)
        XCTAssertFalse(tracker.timerFired())
        clock.advance(0.02)
        XCTAssertTrue(tracker.timerFired())
        XCTAssertTrue(tracker.isMergeReady)
    }

    /// Возврат в допуск после уже показанного «впитывания» (fired → cancelled)
    /// тоже начинает новый отсчёт, а не воскрешает готовность мгновенно.
    func testReturnToToleranceAfterFiredStartsNewCountdown() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.61)
        XCTAssertTrue(tracker.timerFired())

        tracker.update(point: CGPoint(x: 15, y: 0))
        XCTAssertEqual(tracker.state, .cancelled)

        tracker.update(point: CGPoint(x: 2, y: 0))
        XCTAssertEqual(tracker.state, .armed)
        XCTAssertFalse(tracker.isMergeReady)
        XCTAssertEqual(tracker.remainingDuration, 0.6, accuracy: 0.0001)
    }

    // MARK: - Порог времени (600 мс)

    /// До истечения порога таймер готовность не включает.
    func testTimerBeforeThresholdKeepsArmed() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.59)

        XCTAssertFalse(tracker.timerFired())
        XCTAssertEqual(tracker.state, .armed)
        XCTAssertFalse(tracker.isMergeReady)
        XCTAssertEqual(tracker.remainingDuration, 0.01, accuracy: 0.0001)
    }

    /// Ровно 600 мс — порог ещё не выдержан: E9.8а требует «больше 600 мс».
    func testTimerAtThresholdDoesNotFire() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.6)

        XCTAssertFalse(tracker.timerFired())
        XCTAssertEqual(tracker.state, .armed)
        XCTAssertFalse(tracker.isMergeReady)
    }

    /// Чуть больше 600 мс — готовность наступает.
    func testTimerJustOverThresholdFires() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.6001)

        XCTAssertTrue(tracker.timerFired())
        XCTAssertEqual(tracker.state, .fired)
        XCTAssertTrue(tracker.isMergeReady)
    }

    /// Удержание дольше порога тоже включает готовность.
    func testTimerAfterThresholdFires() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(1.5)

        XCTAssertTrue(tracker.timerFired())
        XCTAssertTrue(tracker.isMergeReady)
    }

    /// После готовности остаток до срабатывания — 0, повторный вызов таймера
    /// ничего не ломает.
    func testRemainingDurationIsZeroAfterFire() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.61)
        XCTAssertTrue(tracker.timerFired())

        XCTAssertEqual(tracker.remainingDuration, 0, accuracy: 0.0001)
        XCTAssertFalse(tracker.timerFired())
        XCTAssertEqual(tracker.state, .fired)
    }

    /// Таймер без наведения (idle) не срабатывает.
    func testTimerWithoutHoverDoesNothing() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        clock.advance(5)

        XCTAssertFalse(tracker.timerFired())
        XCTAssertEqual(tracker.state, .idle)
    }

    // MARK: - Готовность и drop

    /// Гейт drop'а: папка создаётся только при `isMergeReady`.
    ///
    /// `finishDrag(commit: true)` спрашивает ровно это свойство, поэтому тест
    /// фиксирует: готовность включается только таймером и снимается смещением —
    /// мгновенного слияния по drop'у (поведение до E8.6) больше нет.
    func testDropMergesOnlyAfterHoverFires() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)

        // Drop сразу после наведения — группировки нет (в центре ярлыка это
        // no-op по E9.5).
        XCTAssertFalse(tracker.isMergeReady)
        XCTAssertFalse(tracker.timerFired())

        clock.advance(0.3)
        // Drop на половине удержания — всё ещё обычное перетаскивание.
        XCTAssertFalse(tracker.timerFired())
        XCTAssertFalse(tracker.isMergeReady)

        clock.advance(0.31)
        // Drop после 600 мс — слияние.
        XCTAssertTrue(tracker.timerFired())
        XCTAssertTrue(tracker.isMergeReady)
    }

    /// Мелкое дрожание пальца после готовности не отменяет слияние.
    func testSmallMoveAfterFireKeepsReady() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.61)
        XCTAssertTrue(tracker.timerFired())

        tracker.update(point: CGPoint(x: 5, y: -5))

        XCTAssertTrue(tracker.isMergeReady)
        XCTAssertEqual(tracker.state, .fired)
    }

    /// Заметное движение после готовности отменяет слияние: подсветка
    /// «впитывания» обещает папку только пока палец стоит.
    func testLargeMoveAfterFireCancelsReady() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.61)
        XCTAssertTrue(tracker.timerFired())

        tracker.update(point: CGPoint(x: 11, y: 0))

        XCTAssertFalse(tracker.isMergeReady)
        XCTAssertEqual(tracker.state, .cancelled)
    }

    // MARK: - Сбросы и смена цели

    /// Смена цели начинает новый отсчёт с полным порогом.
    func testBeginHoverOnAnotherTargetRestartsCountdown() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.61)
        XCTAssertTrue(tracker.timerFired())

        clock.advance(0.5)
        tracker.beginHover(targetID: "b", point: CGPoint(x: 100, y: 100))

        XCTAssertEqual(tracker.state, .armed)
        XCTAssertEqual(tracker.targetID?.base as? String, "b")
        XCTAssertEqual(tracker.anchor?.x, 100)
        XCTAssertEqual(tracker.anchor?.y, 100)
        XCTAssertEqual(tracker.remainingDuration, 0.6, accuracy: 0.0001)

        clock.advance(0.59)
        XCTAssertFalse(tracker.timerFired())
        clock.advance(0.02)
        XCTAssertTrue(tracker.timerFired())
    }

    /// Покадровые повторные вызовы для того же ярлыка не перезапускают отсчёт.
    func testRepeatedBeginHoverForSameTargetDoesNotRestart() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.4)

        // Палец чуть сдвинулся, координатор снова передал ту же цель.
        tracker.beginHover(targetID: "a", point: CGPoint(x: 3, y: 0))
        XCTAssertEqual(tracker.state, .armed)
        XCTAssertEqual(tracker.remainingDuration, 0.2, accuracy: 0.0001)

        clock.advance(0.21)
        XCTAssertTrue(tracker.timerFired())
    }

    /// Повторный вызов для того же ярлыка в готовности не сбрасывает её.
    func testRepeatedBeginHoverAfterFireKeepsReady() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.61)
        XCTAssertTrue(tracker.timerFired())

        tracker.beginHover(targetID: "a", point: CGPoint(x: 2, y: 2))

        XCTAssertEqual(tracker.state, .fired)
        XCTAssertTrue(tracker.isMergeReady)
    }

    /// Новый заход после отмены возвращает удержание в работу.
    func testBeginHoverAfterCancellationRearmsSameTarget() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        tracker.update(point: CGPoint(x: 15, y: 0))
        XCTAssertEqual(tracker.state, .cancelled)

        tracker.beginHover(targetID: "a", point: CGPoint(x: 15, y: 0))

        XCTAssertEqual(tracker.state, .armed)
        XCTAssertEqual(tracker.remainingDuration, 0.6, accuracy: 0.0001)
    }

    /// `reset()` возвращает машину в исходное состояние.
    func testResetReturnsToIdle() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        arm(&tracker)
        clock.advance(0.61)
        XCTAssertTrue(tracker.timerFired())

        tracker.reset()

        XCTAssertEqual(tracker.state, .idle)
        XCTAssertNil(tracker.targetID)
        XCTAssertNil(tracker.anchor)
        XCTAssertFalse(tracker.isMergeReady)
        XCTAssertEqual(tracker.remainingDuration, 0, accuracy: 0.0001)
        XCTAssertFalse(tracker.timerFired())
    }

    /// `update` без наведения ничего не делает.
    func testUpdateWithoutHoverDoesNothing() {
        let clock = TestClock()
        var tracker = makeTracker(clock)

        tracker.update(point: CGPoint(x: 100, y: 100))

        XCTAssertEqual(tracker.state, .idle)
        XCTAssertFalse(tracker.timerFired())
    }
}

#endif
