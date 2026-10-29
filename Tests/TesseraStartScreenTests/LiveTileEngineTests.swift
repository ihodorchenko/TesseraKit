//
//  LiveTileEngineTests.swift
//  TesseraStartScreenTests
//
//  Тесты live-движка плиток (задача E4.7).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §4 «Live-плитки (движок)»
//  (флипы, стахгер пакетами со случайным разбросом, паузы вне экрана/в фоне,
//  Reduce Motion — флипов нет, показывается статичный фронт) и §9
//  «Accessibility» (Reduce Motion).
//
//  Проверяются чистые функции стахгера/батчей с seeded-генератором и поведение
//  движка при инжектированном провайдере Reduce Motion. Тесты не ждут таймеров
//  и не поднимают окно: «флипы выключены» проверяется по устоявшейся стороне
//  плитки после `refresh`, а не по времени.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class LiveTileEngineTests: XCTestCase {

    // MARK: - Тестовый провайдер

    /// Провайдер контента с наблюдаемой подпиской.
    private final class TestProvider: TesseraLiveTileContentProvider {

        var frontFace = TesseraLiveTileFace(title: "Front")
        var backFaceValue: TesseraLiveTileFace? = TesseraLiveTileFace(
            title: "Back",
            detail: "3 новых"
        )

        var backFace: TesseraLiveTileFace? {
            backFaceValue
        }

        /// Сколько раз движок подписался на обновления.
        private(set) var observationCount = 0

        /// Сколько раз вызывалась отмена подписки.
        private(set) var cancellationCount = 0

        func startObservingChanges(_ onChange: @escaping () -> Void) -> (() -> Void)? {
            observationCount += 1
            return { [weak self] in
                self?.cancellationCount += 1
            }
        }
    }

    // MARK: - Вспомогательные средства

    private func makePlanner(
        batchSize: Int = 3,
        batchStagger: TimeInterval = 0.35,
        jitter: TimeInterval = 0.35,
        seed: UInt64 = 42
    ) -> TesseraLiveTileStaggerPlanner {
        TesseraLiveTileStaggerPlanner(
            batchSize: batchSize,
            batchStagger: batchStagger,
            jitter: jitter,
            seed: seed
        )
    }

    // MARK: - Стахгер и батчи (seeded)

    /// Один seed — один и тот же план: поведение воспроизводимо в тестах и на
    /// устройстве (§4).
    func testPlannerIsDeterministicForSameSeed() {
        let first = makePlanner(seed: 42).plan(tileCount: 8)
        let second = makePlanner(seed: 42).plan(tileCount: 8)

        XCTAssertEqual(first.entries, second.entries)
        XCTAssertEqual(first.maximumDelay, second.maximumDelay, accuracy: 1e-9)
    }

    /// Другой seed меняет порядок пакетов (проверка зафиксирована для двух
    /// известных seed, чтобы тест не зависел от случайности).
    func testPlannerDifferentSeedsProduceDifferentOrders() {
        let first = makePlanner(seed: 42).plan(tileCount: 8)
        let second = makePlanner(seed: 7).plan(tileCount: 8)

        XCTAssertNotEqual(first.entries.map { $0.index }, second.entries.map { $0.index })
    }

    /// Каждая плитка получает ровно один флип за цикл; стахгер меняет только
    /// моменты старта, а не число флипов (§4).
    func testPlannerAssignsEveryTileExactlyOnce() {
        let plan = makePlanner(seed: 123).plan(tileCount: 10)

        XCTAssertEqual(plan.entries.count, 10)
        XCTAssertEqual(plan.entries.map { $0.index }.sorted(), Array(0..<10))
        XCTAssertEqual(Set(plan.entries.map { $0.index }).count, 10)
    }

    /// Пакет `k` стартует через `k × batchStagger`, внутри пакета — случайная
    /// добавка `0...jitter` (§4).
    func testPlannerBatchesAndDelays() {
        let batchSize = 3
        let stagger: TimeInterval = 0.35
        let jitter: TimeInterval = 0.35
        let plan = makePlanner(
            batchSize: batchSize,
            batchStagger: stagger,
            jitter: jitter,
            seed: 42
        ).plan(tileCount: 8)

        for (position, entry) in plan.entries.enumerated() {
            XCTAssertEqual(entry.batch, position / batchSize)
            let batchStart = Double(entry.batch) * stagger
            XCTAssertGreaterThanOrEqual(entry.delay, batchStart - 1e-9)
            XCTAssertLessThanOrEqual(entry.delay, batchStart + jitter + 1e-9)
        }

        let maximum = plan.entries.map { $0.delay }.max() ?? 0
        XCTAssertEqual(plan.maximumDelay, maximum, accuracy: 1e-9)
    }

    /// Без разброса задержка равна только старту пакета.
    func testPlannerWithZeroJitterUsesBatchStaggerOnly() {
        let plan = makePlanner(batchStagger: 0.5, jitter: 0, seed: 5).plan(tileCount: 7)

        for entry in plan.entries {
            XCTAssertEqual(entry.delay, Double(entry.batch) * 0.5, accuracy: 1e-9)
        }
    }

    /// Пустой и отрицательный вход дают пустой план.
    func testPlannerHandlesEmptyAndNegativeCounts() {
        let empty = makePlanner().plan(tileCount: 0)
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertEqual(empty.maximumDelay, 0)

        let negative = makePlanner().plan(tileCount: -5)
        XCTAssertTrue(negative.entries.isEmpty)
        XCTAssertEqual(negative.maximumDelay, 0)
    }

    /// Отрицательные параметры зажимаются: `batchSize` — минимум 1, паузы — 0.
    func testPlannerClampsNegativeParameters() {
        let planner = makePlanner(batchSize: 0, batchStagger: -1, jitter: -1, seed: 1)
        let plan = planner.plan(tileCount: 5)

        XCTAssertEqual(plan.entries.count, 5)
        for (position, entry) in plan.entries.enumerated() {
            XCTAssertEqual(entry.batch, position)
            XCTAssertEqual(entry.delay, 0, accuracy: 1e-9)
        }
        XCTAssertEqual(plan.maximumDelay, 0, accuracy: 1e-9)
    }

    /// Seedable-генератор: одинаковая последовательность при одном seed,
    /// значения `0..<upperBound`.
    func testSeededGeneratorIsDeterministicAndInRange() {
        var first = TesseraSeededGenerator(seed: 7)
        var second = TesseraSeededGenerator(seed: 7)

        for _ in 0..<16 {
            XCTAssertEqual(first.next(), second.next())
        }

        for _ in 0..<100 {
            XCTAssertLessThan(first.next(upperBound: 7), 7)
        }
        XCTAssertEqual(first.next(upperBound: 1), 0)
    }

    // MARK: - Конфигурация движка

    /// Значения по умолчанию §4: редкий цикл, короткий флип, пакеты по три.
    func testConfigurationDefaults() {
        let configuration = TesseraLiveTileEngine.Configuration()

        XCTAssertEqual(configuration.cycleInterval, 8)
        XCTAssertEqual(configuration.flipDuration, 0.45)
        XCTAssertEqual(configuration.batchSize, 3)
        XCTAssertEqual(configuration.batchStagger, 0.35)
        XCTAssertEqual(configuration.jitter, 0.35)
    }

    // MARK: - Движок и Reduce Motion

    /// Движок без окна: регистрация читает стороны и не запускает флип.
    ///
    /// `flipDuration` применяется к контейнеру при регистрации (§4).
    func testRegistrationSetsFacesAndFlipDuration() {
        let engine = TesseraLiveTileEngine(
            configuration: TesseraLiveTileEngine.Configuration(flipDuration: 0.9),
            isReduceMotionEnabled: { true }
        )
        let view = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let provider = TestProvider()

        engine.register(view, provider: provider, isVisible: true)

        XCTAssertEqual(view.face(for: .front)?.title, "Front")
        XCTAssertEqual(view.face(for: .back)?.title, "Back")
        XCTAssertEqual(view.flipAnimationDuration, 0.9, accuracy: 1e-9)
        XCTAssertEqual(view.side, .front)
        XCTAssertFalse(view.isFlipping)
        XCTAssertEqual(provider.observationCount, 1)

        engine.unregister(view)
        XCTAssertEqual(provider.cancellationCount, 1)

        // Повторная отмена не должна вызывать подписку второй раз.
        engine.unregister(view)
        XCTAssertEqual(provider.cancellationCount, 1)
    }

    /// Reduce Motion: флипов нет, показывается статичный фронт. Даже если
    /// плитка была переведена на бэк, `refresh` возвращает её на фронт (§4, §9).
    func testReduceMotionKeepsStaticFront() {
        let engine = TesseraLiveTileEngine(
            configuration: TesseraLiveTileEngine.Configuration(
                cycleInterval: 0.5,
                flipDuration: 0.2,
                batchSize: 2,
                batchStagger: 0,
                jitter: 0,
                seed: 1
            ),
            isReduceMotionEnabled: { true }
        )
        let view = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let provider = TestProvider()

        engine.register(view, provider: provider)
        XCTAssertEqual(view.side, .front)

        // Принудительно показываем бэк — движок обязан вернуть фронт.
        view.show(.back, animated: false)
        XCTAssertEqual(view.side, .back)

        engine.refresh(view)
        XCTAssertEqual(view.side, .front)
        XCTAssertFalse(view.isFlipping)

        engine.setVisible(false, for: view)
        engine.setVisible(true, for: view)
        engine.refresh(view)
        XCTAssertEqual(view.side, .front)

        engine.unregister(view)
    }

    /// Пауза по видимости не запускает флип и не ломает регистрацию (§4,
    /// «Паузы»): повторная регистрация заменяет прежнюю запись.
    func testVisibilityPauseAndReRegistrationAreSafe() {
        let engine = TesseraLiveTileEngine(
            configuration: TesseraLiveTileEngine.Configuration(seed: 2),
            isReduceMotionEnabled: { true }
        )
        let view = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let first = TestProvider()
        let second = TestProvider()

        engine.register(view, provider: first, isVisible: false)
        engine.setVisible(true, for: view)
        engine.register(view, provider: second, isVisible: true)

        XCTAssertEqual(first.cancellationCount, 1)
        XCTAssertEqual(second.observationCount, 1)
        XCTAssertEqual(view.side, .front)

        engine.unregister(view)
        XCTAssertEqual(second.cancellationCount, 1)
    }

    /// Провайдер без бэка — статичная плитка: запрос бэка игнорируется, движок
    /// не считает её подходящей для флипа (§4, «опциональный бэк»).
    func testProviderWithoutBackStaysOnFront() {
        let engine = TesseraLiveTileEngine(
            configuration: TesseraLiveTileEngine.Configuration(),
            isReduceMotionEnabled: { true }
        )
        let view = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let provider = TestProvider()
        provider.backFaceValue = nil

        engine.register(view, provider: provider)
        XCTAssertNil(view.face(for: .back))
        view.show(.back, animated: false)
        XCTAssertEqual(view.side, .front)

        engine.unregister(view)
    }
}

#endif
