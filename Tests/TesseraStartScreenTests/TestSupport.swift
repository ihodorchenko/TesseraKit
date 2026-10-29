//
//  TestSupport.swift
//  TesseraStartScreenTests
//
//  Общие детерминированные помощники тестов рабочего стола (E4.7).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка»
//  (тесты на случайных конфигурациях плиток), §5 «Режим редактирования»
//  (персистентность TileStore), §14 «Уточнения MVP» (D12–D15).
//
//  Все помощники — только для тестов: публичного API target'а они не касаются.
//  «Случайность» всегда seeded, поэтому прогон воспроизводим и не флакует.
//

#if canImport(UIKit)

import Foundation
import XCTest
@testable import TesseraStartScreen

// MARK: - Детерминированный генератор

/// Простой seeded-генератор для «случайных» конфигураций раскладки (§3).
///
/// Не использует `SystemRandomNumberGenerator`: тест обязан давать одну и ту
/// же конфигурацию при каждом запуске. Реализация намеренно не совпадает с
/// production-генератором стахгера `TesseraSeededGenerator`, чтобы тест
/// раскладки не зависел от внутренностей Live-движка.
struct TesseraTestSeededGenerator {

    /// Состояние LCG.
    private var state: UInt64

    /// Создаёт генератор.
    ///
    /// - Parameter seed: Зерно; одинаковое зерно даёт одинаковую последовательность.
    init(seed: UInt64) {
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    }

    /// Следующее псевдослучайное значение.
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    /// Значение `0..<upperBound`.
    ///
    /// - Parameter upperBound: Положительная граница.
    mutating func int(upperBound: Int) -> Int {
        precondition(upperBound > 0, "upperBound должен быть положительным")
        return Int((next() >> 33) % UInt64(upperBound))
    }
}

// MARK: - Временная директория

/// Временный каталог для тестов персистентности `TileStore`.
///
/// Каталог удаляется в `deinit`: тесты не оставляют мусор в песочнице
/// симулятора и не зависят от порядка прогона.
final class TesseraTestDirectory {

    /// Путь каталога.
    let url: URL

    /// Создаёт описание каталога (сам каталог создаётся по необходимости).
    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TesseraStartScreenTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Создаёт каталог на диске.
    func create() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

// MARK: - Модель ярлыка

/// Ярлык для тестов: действие-заглушка и настраиваемые размер/бейдж (D12/D15).
///
/// - Parameters:
///   - id: Идентификатор ярлыка.
///   - size: Размер плитки, по умолчанию `.medium` (D12).
///   - badge: Бейдж внимания, по умолчанию `.none`.
/// - Returns: Готовый `TileDescriptor`.
func tesseraTestTile(
    _ id: String,
    size: TileSize = .medium,
    badge: TileBadge = .none
) -> TileDescriptor {
    TileDescriptor(
        id: id,
        title: id,
        action: {},
        badge: badge,
        size: size
    )
}

/// Идентификаторы элементов снимка в порядке отображения.
///
/// - Parameter items: Элементы сетки.
/// - Returns: Идентификаторы в том же порядке.
func tesseraTestIDs(_ items: [TileGridItem]) -> [AnyHashable] {
    items.map { $0.id }
}

#endif
