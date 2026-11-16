// Таблица явных ячеек в снимке сетки — «боковой» вход раскладки (E14.3, D30).
//
// Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка» и
// «Отступления реализации (E14)», п. 51; решения D30–D33 в docs/STATE.md.
//
// До E14.3 раскладка была функцией порядка: ``TileLayoutEngine/pack(items:columns:unit:)``
// строго компактно укладывал плитки по массиву снимка. Чтобы сетка могла
// изобразить настоящие пустоты, снимок получает необязательную таблицу ячеек
// («sidecar»): идентификатор -> ``TileGridPlacement``. Перечисление
// ``TileGridItem`` не меняется (это source-breaking), а снимок без таблицы
// раскладывается ровно как раньше.
//
// Этот файл — чистая часть: сама таблица и правило «можно ли ей верить»
// (``TileGridPlacementTable/resolve(items:cells:placementColumns:columns:)``).
// Правило общее для раскладки и для вспомогательных расчётов сетки (рамки базовой
// раскладки), чтобы они не расходились. UIKit слой не знает.

import CoreGraphics

/// Таблица явных ячеек верхнеуровневых элементов, приложенная к снимку сетки
/// (E14.3, D30).
///
/// Ячейки — **логические**, как в ``TileGridPlacement``: колонка 0 — начало
/// чтения, зеркалирование RTL делает раскладка при расчёте рамок. Таблица
/// описывает раскладку для конкретной ширины холста: ``columns``.
///
/// Раскладка принимает таблицу, только если она покрывает каждый элемент снимка
/// (кроме панели раскрытой папки), её ширина совпадает с числом колонок сетки и
/// набор проходит ``TileLayoutEngine/validate(_:columns:)`` (вне холста и
/// пересечения недопустимы). Иначе таблица игнорируется целиком, и сетка
/// раскладывается прежним ``TileLayoutEngine/pack(items:columns:unit:)`` по
/// порядку снимка — без частичной подстановки: полуправильная раскладка хуже
/// честного репака.
public struct TileGridPlacementTable: Equatable {

    /// Ячейки по идентификаторам верхнеуровневых элементов.
    ///
    /// Лишние идентификаторы (которых нет в снимке) игнорируются; недостающие
    /// делают таблицу неполной — раскладка откатывается на упаковку по порядку.
    public var cells: [AnyHashable: TileGridPlacement]

    /// Ширина холста в колонках, для которой рассчитаны ячейки.
    ///
    /// Если задана и не равна числу колонок сетки, таблица игнорируется
    /// (хранилище отдаёт для другой ширины проекцию без дыр, D32, но проекцию
    /// рассчитывает хост под свою ширину). `nil` — ширина не заявлена: таблицу
    /// проверяет только `validate` на текущей ширине сетки.
    public var columns: Int?

    /// Создаёт таблицу.
    ///
    /// - Parameters:
    ///   - cells: Ячейки по идентификаторам элементов.
    ///   - columns: Ширина холста, для которой рассчитаны ячейки; `nil` — не
    ///     заявлена.
    public init(cells: [AnyHashable: TileGridPlacement], columns: Int? = nil) {
        self.cells = cells
        self.columns = columns
    }

    /// Применима ли таблица на сетке заданной ширины и каково итоговое
    /// размещение (E14.3).
    ///
    /// Правило отката на упаковку по порядку (`nil`):
    ///
    /// - таблицы нет (`cells == nil`) или набор элементов пуст;
    /// - заявленная ширина `placementColumns` не равна `columns`;
    /// - ячейки нет хотя бы у одного элемента (таблица неполная);
    /// - набор не проходит ``TileLayoutEngine/validate(_:columns:)`` — след
    ///   выходит за холст, ячейка отрицательна или следы пересекаются.
    ///
    /// Иначе возвращается набор размещений **в порядке `items`** с запрошенными
    /// размерами (D15); ужатие под узкую сетку делают
    /// ``TileLayoutEngine/slots(placements:columns:unit:fitting:)`` и `validate`.
    ///
    /// - Parameters:
    ///   - items: Элементы в порядке снимка (без панели): идентификатор и
    ///     запрошенный размер.
    ///   - cells: Ячейки по идентификаторам; `nil` — таблицы нет.
    ///   - placementColumns: Заявленная ширина холста таблицы; `nil` — не
    ///     заявлена.
    ///   - columns: Число колонок сетки, больше нуля.
    /// - Returns: Размещения для ``TileLayoutEngine/slots(placements:columns:unit:fitting:)``
    ///   либо `nil` — тогда раскладывать надо упаковкой по порядку.
    static func resolve(
        items: [(id: AnyHashable, size: TileSize)],
        cells: [AnyHashable: TileGridPlacement]?,
        placementColumns: Int?,
        columns: Int
    ) -> [TilePlacedItem]? {
        guard let cells, columns > 0, !items.isEmpty else { return nil }
        if let placementColumns, placementColumns != columns { return nil }

        var placed: [TilePlacedItem] = []
        placed.reserveCapacity(items.count)
        for item in items {
            guard let cell = cells[item.id] else { return nil }
            placed.append(TilePlacedItem(id: item.id, size: item.size, cell: cell))
        }
        guard TileLayoutEngine.validate(placed, columns: columns).isEmpty else { return nil }
        return placed
    }
}

// MARK: - Порядок чтения снимка (E14.7)

extension TileGridSnapshot {

    /// Снимок, у которого элементы идут в порядке чтения явных ячеек (E14.7).
    ///
    /// Порядок элементов снимка — порядок индексов коллекции, а значит, и порядок
    /// обхода VoiceOver (см. «Accessibility» в ``TesseraTileGridView``). Хост со
    /// своей таблицей ячеек (без ``TileStore``) мог отдать элементы в любом
    /// порядке; применимая таблица (``TileGridPlacementTable/resolve(items:cells:placementColumns:columns:)``)
    /// задаёт, как элементы лежат на экране, и порядок приводится к ней: строка по
    /// возрастанию, затем логическая колонка (в RTL колонки логические, порядок
    /// тот же). Равные ячейки (их быть не может: ``TileLayoutEngine/validate(_:columns:)``)
    /// остаются в исходном порядке.
    ///
    /// Если таблица не применима (нет, неполная, другая ширина, пересечения),
    /// раскладка идёт упаковкой по порядку `items`, и этот порядок сохраняется
    /// как есть. Снимок с панелью раскрытой папки в `items` тоже не трогается:
    /// панель добавляет сама сетка уже после сортировки.
    ///
    /// - Parameter columns: Число колонок сетки.
    /// - Returns: `self`, если порядок уже верный или таблица не применима;
    ///   иначе копия с переставленными элементами.
    func readingOrdered(columns: Int) -> TileGridSnapshot {
        guard placementTable != nil, !items.contains(where: { $0.isFolderPanel }),
              let placed = TileGridPlacementTable.resolve(
                  items: items.map { (id: $0.id, size: $0.size) },
                  cells: placementTable?.cells,
                  placementColumns: placementTable?.columns,
                  columns: columns
              ) else {
            return self
        }
        var cellByID: [AnyHashable: TileGridPlacement] = [:]
        cellByID.reserveCapacity(placed.count)
        for item in placed { cellByID[item.id] = item.cell }

        let sorted = items.enumerated().sorted { lhs, rhs in
            guard let left = cellByID[lhs.element.id], let right = cellByID[rhs.element.id],
                  left != right else {
                return lhs.offset < rhs.offset
            }
            return TileGridPlacement.isReadingOrdered(left, before: right)
        }
        guard sorted.map({ $0.offset }) != Array(items.indices) else { return self }
        return TileGridSnapshot(
            items: sorted.map { $0.element },
            unpinned: unpinned,
            placementTable: placementTable
        )
    }
}
