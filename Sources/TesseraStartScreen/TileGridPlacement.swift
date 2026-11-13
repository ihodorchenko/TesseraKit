// Координаты верхнеуровневого элемента сетки рабочего стола (E14.1, D30–D33).
//
// Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка»
// (персистентность TileStore) и решения D30–D33 в docs/STATE.md.

import Foundation

/// Явная ячейка верхнеуровневого элемента (ярлыка или папки) на холсте сетки
/// (E14.1, D30).
///
/// Координаты — в **юнитах** и **логические**: `column == 0` — начало чтения
/// (в RTL это правый край, зеркалит только вью-слой, документ §9), `row == 0` —
/// верхняя строка. Ячейка задаёт левый верхний угол элемента; его след на
/// холсте определяется размером (D15, при узкой сетке — с поправкой
/// ``TileLayoutEngine/fittingSize(_:columns:)``).
///
/// Значение хранится в `tiles.json` (схема версии 2) вместе с шириной холста;
/// про ширину см. ``TileStore/canvasColumns``.
public struct TileGridPlacement: Equatable, Hashable, Codable, Sendable {

    /// Строка левого верхнего угла (отсчёт от 0, сверху вниз).
    public var row: Int

    /// Колонка левого верхнего угла (отсчёт от 0 в направлении чтения).
    public var column: Int

    /// Создаёт ячейку.
    ///
    /// - Parameters:
    ///   - row: Строка левого верхнего угла.
    ///   - column: Колонка левого верхнего угла.
    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    /// Порядок чтения: сначала по строке, затем по колонке.
    ///
    /// - Parameters:
    ///   - lhs: Первая ячейка.
    ///   - rhs: Вторая ячейка.
    /// - Returns: `true`, если `lhs` читается раньше `rhs`.
    public static func isReadingOrdered(_ lhs: TileGridPlacement, before rhs: TileGridPlacement) -> Bool {
        if lhs.row != rhs.row { return lhs.row < rhs.row }
        return lhs.column < rhs.column
    }
}
