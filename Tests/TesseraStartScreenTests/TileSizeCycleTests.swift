//
//  TileSizeCycleTests.swift
//  TesseraStartScreenTests
//
//  Цикл размеров по тапу на стрелку (D28, E15.3): малый → широкий → средний →
//  большой → малый. Порядок задан явно (`TileSize.cycleOrder`), а не порядком
//  `allCases`; хост задаёт набор `supportedSizesProvider`, а не порядок.
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §5 и «Отступления
//  реализации (E15)», п. 59; W10M-STARTSCREEN.md §5.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileSizeCycleTests: XCTestCase {

    // MARK: - Чистая модель

    /// Порядок цикла — W10M с `large` в конце; он не совпадает с `allCases`.
    func testCycleOrderIsExplicitAndDiffersFromAllCases() {
        XCTAssertEqual(TileSize.cycleOrder, [.small, .wide, .medium, .large])
        XCTAssertEqual(TileSize.allCases, [.small, .medium, .wide, .large])
        XCTAssertNotEqual(TileSize.cycleOrder, TileSize.allCases)
        XCTAssertEqual(Set(TileSize.cycleOrder), Set(TileSize.allCases), "все четыре размера D15")
    }

    /// Из любого размера полный набор ведёт по кругу в порядке W10M.
    func testNextAmongAllSizesFollowsCycleFromEveryStart() {
        let all = TileSize.allCases
        XCTAssertEqual(TileSize.small.next(among: all), .wide)
        XCTAssertEqual(TileSize.wide.next(among: all), .medium)
        XCTAssertEqual(TileSize.medium.next(among: all), .large)
        XCTAssertEqual(TileSize.large.next(among: all), .small)

        for start in TileSize.allCases {
            var size = start
            var visited: [TileSize] = []
            for _ in 0..<4 {
                size = size.next(among: all)
                visited.append(size)
            }
            XCTAssertEqual(size, start, "четыре шага замыкают круг от \(start)")
            XCTAssertEqual(Set(visited).count, 4, "круг проходит все размеры от \(start)")
        }
    }

    /// Неподдерживаемые размеры пропускаются; порядок списка хоста не важен.
    func testNextSkipsUnsupportedAndIgnoresHostListOrder() {
        // Без wide: small → medium → large → small.
        let noWide: [TileSize] = [.large, .small, .medium]
        XCTAssertEqual(TileSize.small.next(among: noWide), .medium)
        XCTAssertEqual(TileSize.medium.next(among: noWide), .large)
        XCTAssertEqual(TileSize.large.next(among: noWide), .small)

        // Без large (3 колонки: wide тоже не влезает → small/medium).
        XCTAssertEqual(TileSize.small.next(among: [.medium, .small]), .medium)
        XCTAssertEqual(TileSize.medium.next(among: [.medium, .small]), .small)

        // Список в обратном порядке даёт тот же результат.
        for start in TileSize.allCases {
            XCTAssertEqual(
                start.next(among: [.small, .wide, .large]),
                start.next(among: [.large, .wide, .small])
            )
        }
        XCTAssertEqual(TileSize.small.next(among: [.small, .large]), .large)
        XCTAssertEqual(TileSize.large.next(among: [.small, .large]), .small)
    }

    /// Единственный поддерживаемый размер замыкает цикл на себе; пустой набор — тоже.
    func testNextWithSingleOrEmptySetStaysOnCurrent() {
        for size in TileSize.allCases {
            XCTAssertEqual(size.next(among: [size]), size)
            XCTAssertEqual(size.next(among: []), size)
        }
    }

    /// Текущий размер вне поддерживаемого набора: берётся ближайший дальше по циклу.
    func testNextFromUnsupportedCurrentTakesNearestOnCycle() {
        XCTAssertEqual(TileSize.medium.next(among: [.small, .wide]), .small, "medium → large(нет) → small")
        XCTAssertEqual(TileSize.wide.next(among: [.large]), .large)
        XCTAssertEqual(TileSize.small.next(among: [.large, .medium]), .medium, "small → wide(нет) → medium")
    }

    // MARK: - Координатор

    private func makeHost(
        size: TileSize,
        columns: Int = 6
    ) -> TesseraTestDragHost {
        TesseraTestDragHost(
            descriptors: [tesseraTestTile("a", size: size)],
            columns: columns
        )
    }

    /// Координатор идёт по циклу D28 из каждого стартового размера и замыкает круг.
    func testCoordinatorCyclesInW10MOrderFromEveryStart() {
        let expected: [TileSize: [TileSize]] = [
            .small: [.wide, .medium, .large, .small],
            .wide: [.medium, .large, .small, .wide],
            .medium: [.large, .small, .wide, .medium],
            .large: [.small, .wide, .medium, .large],
        ]
        for start in TileSize.allCases {
            let host = makeHost(size: start)
            for (step, next) in (expected[start] ?? []).enumerated() {
                XCTAssertEqual(host.coordinator.cycleSize(of: "a"), next, "старт \(start), шаг \(step + 1)")
                XCTAssertEqual(host.store.descriptor(withID: "a")?.size, next)
                XCTAssertEqual(host.host.grid.items.first { $0.id == AnyHashable("a") }?.size, next)
            }
        }
    }

    /// Хост сужает набор: цикл пропускает недоступные размеры, порядок задан
    /// моделью, а не списком хоста.
    func testCoordinatorRespectsSupportedSizesProvider() {
        let host = makeHost(size: .small)
        host.coordinator.supportedSizesProvider = { _ in [.large, .small, .medium] }
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .medium, "wide пропущен")
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .large)
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .small)

        host.coordinator.supportedSizesProvider = { _ in [.large, .wide] }
        // Текущий small вне набора: ближайший дальше по циклу — wide.
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .wide)
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .large)
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .wide)
    }

    /// Единственный поддерживаемый размер: менять нечего, стрелки нет.
    func testCoordinatorSingleSupportedSizeDoesNothing() {
        let host = makeHost(size: .medium)
        host.coordinator.supportedSizesProvider = { _ in [.medium] }
        XCTAssertNil(host.coordinator.cycleSize(of: "a"))
        XCTAssertEqual(host.store.descriptor(withID: "a")?.size, .medium)
    }

    /// Узкая сетка (3 колонки): wide/large не влезают, цикл — small ↔ medium.
    func testCoordinatorInNarrowGridCyclesBetweenSmallAndMedium() {
        let host = makeHost(size: .small, columns: 3)
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .medium)
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .small)
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .medium)
    }

    // MARK: - Формат хранения

    /// Размер после шагов цикла сохраняется и читается как раньше (сырое
    /// значение `TileSize`); формат файла не менялся.
    func testPersistenceRoundTripKeepsCycledSize() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = TileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog([tesseraTestTile("a", size: .small)])
        store.placeItems(columns: 6)
        XCTAssertTrue(store.resize("a", to: TileSize.small.next(among: TileSize.allCases), columns: 6))
        try store.save()

        let fresh = TileStore(directoryURL: directory.url)
        fresh.setCatalog([tesseraTestTile("a", size: .small)])
        try fresh.load()
        XCTAssertEqual(fresh.descriptor(withID: "a")?.size, .wide)

        let json = try String(contentsOf: store.fileURL)
        XCTAssertTrue(json.contains("\"wide\""), "в файле сырое значение размера")
    }

    // MARK: - VoiceOver

    /// Действие «Изменить размер» делает тот же шаг цикла D28, что и стрелка: оба
    /// вызывают `cycleSize(of:)`, поэтому озвучивается тот же новый размер
    /// (объявление шлётся только при включённом VoiceOver и не перехватывается).
    func testVoiceOverResizeActionUsesSameCycle() throws {
        let host = makeHost(size: .small)
        host.coordinator.beginEditing()
        let resizeName = TesseraStartScreenStrings.string(.a11yActionResize)
        func action() -> UIAccessibilityCustomAction? {
            host.host.cell("a")?.accessibilityCustomActions?.first { $0.name == resizeName }
        }
        XCTAssertTrue(host.waitUntil { action() != nil })

        let expected: [TileSize] = [.wide, .medium, .large, .small]
        for next in expected {
            let current = try XCTUnwrap(action())
            XCTAssertEqual(current.actionHandler?(current), true)
            XCTAssertEqual(host.store.descriptor(withID: "a")?.size, next)
            XCTAssertTrue(host.waitUntil { action() != nil })
        }
        host.coordinator.endEditing()
    }

    /// Стрелка (кнопка оверлея) и действие VoiceOver дают один и тот же размер.
    func testArrowButtonAndVoiceOverActionAgree() throws {
        let host = makeHost(size: .wide)
        host.coordinator.beginEditing()
        host.spin(0.03)
        let control = try XCTUnwrap(host.coordinator.editControls["a"])
        control.onResize?()
        XCTAssertEqual(host.store.descriptor(withID: "a")?.size, .medium, "стрелка: wide → medium")

        let resizeName = TesseraStartScreenStrings.string(.a11yActionResize)
        XCTAssertTrue(host.waitUntil {
            host.host.cell("a")?.accessibilityCustomActions?.contains { $0.name == resizeName } == true
        })
        let action = try XCTUnwrap(
            host.host.cell("a")?.accessibilityCustomActions?.first { $0.name == resizeName }
        )
        XCTAssertEqual(action.actionHandler?(action), true)
        XCTAssertEqual(host.store.descriptor(withID: "a")?.size, .large, "VoiceOver: medium → large")
        host.coordinator.endEditing()
    }
}

#endif
