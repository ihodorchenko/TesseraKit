// Раскладка по явным координатам: чистый слой «размещение по ячейкам» (E14.2).
// Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка» и
// «Отступления реализации (E14)»; решения D30–D33 в docs/STATE.md.
//
// Раньше раскладка была функцией порядка: ``TileLayoutEngine/pack(items:columns:unit:)``
// строго компактно укладывал плитки по массиву. Вариант Б (D30) делает моделью
// явные координаты: у каждого верхнеуровневого элемента есть ячейка
// (``TileGridPlacement``), плитка якорится на ней, а дыры сохраняются. Этот файл —
// чистые операции над таким набором: размещение, вставка с выталкиванием вниз
// каскадом (D31), resize на месте, удаление без репака, схлопывание пустых строк,
// поиск свободной ячейки и проверка корректности.
//
// Слой ничего не знает о UIKit, хранилище и сетке: только `TileSize`, ячейки и
// число колонок. Все функции — `static`, детерминированы и не хранят состояния.
// Ячейки — **логические** (колонка 0 — начало чтения); зеркалирование RTL делает
// вью-слой (документ §9). Старый индексный API (`pack`, `repack`, `resizing`,
// `previewOrder`, `resizePlacement`) остаётся нетронутым до E14.5.

import CoreGraphics

/// Элемент набора размещений: идентификатор, запрошенный размер и ячейка
/// левого верхнего угла (E14.2, D30).
///
/// Набор размещений — массив таких элементов. Порядок массива **не модель**: он
/// нужен только затем, чтобы сопоставлять результат со входом (как у
/// ``TileLayoutEngine/pack(items:columns:unit:)``) и делать вывод детерминированным.
/// Размер здесь — запрошенный (D15, как в `TileStore`); след на сетке движок
/// считает по ``TileLayoutEngine/fittingSize(_:columns:)``.
public struct TilePlacedItem: Equatable {

    /// Идентификатор верхнеуровневого элемента (ярлыка или папки).
    public var id: AnyHashable

    /// Запрошенный размер плитки (D15).
    public var size: TileSize

    /// Ячейка левого верхнего угла (логические координаты, в юнитах).
    public var cell: TileGridPlacement

    /// Создаёт элемент набора размещений.
    ///
    /// - Parameters:
    ///   - id: Идентификатор элемента.
    ///   - size: Запрошенный размер плитки.
    ///   - cell: Ячейка левого верхнего угла.
    public init(id: AnyHashable, size: TileSize, cell: TileGridPlacement) {
        self.id = id
        self.size = size
        self.cell = cell
    }
}

/// Прямоугольник следа плитки в юнитах — внутреннее представление движка.
fileprivate struct PlacementRect: Equatable {

    var row: Int
    var column: Int
    var width: Int
    var height: Int

    /// Первая строка под прямоугольником.
    var bottom: Int { row + height }

    /// Первая колонка справа от прямоугольника.
    var trailing: Int { column + width }

    /// Пересекаются ли два прямоугольника (общая граница — не пересечение).
    func overlaps(_ other: PlacementRect) -> Bool {
        row < other.bottom && other.row < bottom
            && column < other.trailing && other.column < trailing
    }
}

// MARK: - Размещение по координатам (E14.2)

extension TileLayoutEngine {

    // MARK: Слоты и проверка

    /// Слоты по явным ячейкам — без упаковки (E14.2).
    ///
    /// Каждый элемент встаёт ровно на свою ячейку; ничего не сдвигается и не
    /// схлопывается. Слоты идут **в порядке входного массива**. Как и
    /// ``pack(items:columns:unit:)``, при `fitting == false` плитка шире сетки
    /// пропускается (сетка не может изобразить её без искажения размера); при
    /// `fitting == true` размер предварительно ужимается
    /// ``fittingSize(_:columns:)`` (деградация геометрии, как в раскладке под узкую
    /// сетку), и пропусков нет. Слот несёт размер, по которому считался его след.
    ///
    /// - Parameters:
    ///   - placements: Набор размещений.
    ///   - columns: Число колонок, больше нуля.
    ///   - unit: Размер юнита в точках, больше нуля.
    ///   - fitting: Ужимать ли размеры под узкую сетку вместо пропуска.
    /// - Returns: Слоты в порядке `placements`; пустой массив для вырожденной
    ///   геометрии.
    public static func slots(
        placements: [TilePlacedItem],
        columns: Int,
        unit: CGFloat,
        fitting: Bool = false
    ) -> [TileLayoutSlot] {
        guard columns > 0, unit.isFinite, unit > 0 else { return [] }

        var result: [TileLayoutSlot] = []
        result.reserveCapacity(placements.count)

        for item in placements {
            let size = fitting ? fittingSize(item.size, columns: columns) : item.size
            guard size.unitColumns > 0, size.unitRows > 0, size.unitColumns <= columns else { continue }

            result.append(
                TileLayoutSlot(
                    id: item.id,
                    size: size,
                    column: item.cell.column,
                    row: item.cell.row,
                    unit: unit
                )
            )
        }
        return result
    }

    /// Идентификаторы элементов, нарушающих корректность набора (E14.2).
    ///
    /// Нарушитель — элемент, чей след (по ``fittingSize(_:columns:)``) выходит за
    /// холст `[0, columns)` по колонкам, лежит в отрицательных строке/колонке или
    /// пересекается с другим элементом. Пустой результат — набор корректен.
    /// Порядок — по входному массиву, без повторов. При `columns <= 0` нарушителями
    /// считаются все элементы.
    ///
    /// - Parameters:
    ///   - placements: Набор размещений.
    ///   - columns: Число колонок.
    /// - Returns: Идентификаторы нарушителей.
    public static func validate(_ placements: [TilePlacedItem], columns: Int) -> [AnyHashable] {
        guard columns > 0 else { return placements.map(\.id) }

        let rects = placements.map { placementRect($0, columns: columns) }
        var offenders: [AnyHashable] = []

        for (index, rect) in rects.enumerated() {
            var isOffender = rect.row < 0 || rect.column < 0 || rect.trailing > columns
            if !isOffender {
                for other in rects.indices where other != index && rect.overlaps(rects[other]) {
                    isOffender = true
                    break
                }
            }
            if isOffender { offenders.append(placements[index].id) }
        }
        return offenders
    }

    /// Есть ли в наборе пересекающиеся следы (E14.2).
    ///
    /// Только пересечения: выход за холст проверяет ``validate(_:columns:)``.
    ///
    /// - Parameters:
    ///   - placements: Набор размещений.
    ///   - columns: Число колонок (нужно для ужатия размеров под узкую сетку).
    /// - Returns: `true`, если хотя бы два следа пересекаются.
    public static func hasOverlaps(_ placements: [TilePlacedItem], columns: Int) -> Bool {
        guard columns > 0 else { return false }

        let rects = placements.map { placementRect($0, columns: columns) }
        for lhs in rects.indices {
            for rhs in rects.indices where rhs > lhs && rects[lhs].overlaps(rects[rhs]) {
                return true
            }
        }
        return false
    }

    // MARK: Ячейка

    /// Ограничивает ячейку холстом под размер плитки (E14.2, D31).
    ///
    /// Строка не меньше 0; колонка ограничивается так, чтобы
    /// `column + ширина ≤ columns`: слишком правая ячейка **сдвигается влево**,
    /// вправо — никогда. Ширина — по ``fittingSize(_:columns:)``, поэтому на узкой
    /// сетке плитка всегда помещается. При `columns <= 0` колонка — 0.
    ///
    /// - Parameters:
    ///   - cell: Желаемая ячейка.
    ///   - size: Размер плитки.
    ///   - columns: Число колонок.
    /// - Returns: Допустимая ячейка.
    public static func clamped(cell: TileGridPlacement, size: TileSize, columns: Int) -> TileGridPlacement {
        let width = fittingSize(size, columns: columns).unitColumns
        let maxColumn = max(0, columns - width)
        return TileGridPlacement(
            row: max(0, cell.row),
            column: min(max(0, cell.column), maxColumn)
        )
    }

    // MARK: Вставка и resize

    /// Ставит элемент на ячейку; мешающие плитки выталкиваются вниз каскадом
    /// (E14.2, D31).
    ///
    /// Алгоритм:
    ///
    /// 1. Ячейка приводится к холсту ``clamped(cell:size:columns:)`` — получается
    ///    прямоугольник вставки `R`. Если элемент с таким `id` уже есть, он
    ///    исключается из коллизий (это перенос): остальные элементы сравниваются
    ///    только с `R`, а не с его старым местом.
    /// 2. Остальные элементы обходятся в порядке чтения **исходных** позиций
    ///    (строка, затем колонка, затем индекс во входном массиве).
    /// 3. Каждый элемент проверяется на пересечение со всем уже размещённым
    ///    (`R` и ранее обработанные, с учётом их новых позиций). Если пересечение
    ///    есть, элемент сдвигается **вниз** в той же колонке на минимальную строку,
    ///    очищающую все пересекающие прямоугольники (нижняя граница самого
    ///    нижнего из них); проверка повторяется — это и есть каскад: сдвинутый
    ///    элемент становится препятствием для следующих.
    /// 4. Элементы без пересечений не двигаются, включая дыры выше и вокруг
    ///    затронутой области. По горизонтали никто не двигается.
    ///
    /// Результат всегда без пересечений (каждый элемент размещается с проверкой на
    /// всех предыдущих) и конечен (один проход, строки только растут). Порядок
    /// массива сохраняется; новый элемент добавляется в конец, существующий
    /// остаётся на своём индексе. Идемпотентно: вставка уже корректного
    /// размещения на его собственную ячейку набор не меняет. При `columns <= 0`
    /// возвращается вход без изменений. Вход считается корректным (след внутри
    /// холста); пересечения во входе разрешаются тем же проходом.
    ///
    /// - Parameters:
    ///   - id: Идентификатор вставляемого или переносимого элемента.
    ///   - size: Размер элемента (запрошенный, D15).
    ///   - cell: Желаемая ячейка.
    ///   - placements: Текущий набор размещений.
    ///   - columns: Число колонок.
    /// - Returns: Новый набор размещений.
    public static func inserting(
        id: AnyHashable,
        size: TileSize,
        at cell: TileGridPlacement,
        into placements: [TilePlacedItem],
        columns: Int
    ) -> [TilePlacedItem] {
        guard columns > 0 else { return placements }

        let moved = TilePlacedItem(
            id: id,
            size: size,
            cell: clamped(cell: cell, size: size, columns: columns)
        )
        let insertion = placementRect(moved, columns: columns)

        // Остальные элементы в порядке чтения исходных позиций.
        let others = placements.indices.filter { placements[$0].id != id }
        let order = others.sorted { lhs, rhs in
            let left = placements[lhs].cell
            let right = placements[rhs].cell
            if left.row != right.row { return left.row < right.row }
            if left.column != right.column { return left.column < right.column }
            return lhs < rhs
        }

        var placed: [PlacementRect] = [insertion]
        var newRows: [Int: Int] = [:]
        newRows.reserveCapacity(order.count)

        for index in order {
            var rect = placementRect(placements[index], columns: columns)
            while true {
                let blockers = placed.filter { $0.overlaps(rect) }
                guard let lowest = blockers.map(\.bottom).max() else { break }
                // Нижняя граница самого нижнего препятствия: выше уходить нельзя,
                // потому что текущая строка уже пересекает его.
                rect.row = lowest
            }
            newRows[index] = rect.row
            placed.append(rect)
        }

        // Сборка в порядке входа: существующий элемент остаётся на индексе,
        // новый — в конец.
        var result: [TilePlacedItem] = []
        result.reserveCapacity(placements.count + 1)
        var didPlaceMoved = false

        for index in placements.indices {
            if placements[index].id == id {
                if !didPlaceMoved {
                    result.append(moved)
                    didPlaceMoved = true
                }
                continue
            }
            var item = placements[index]
            item.cell.row = newRows[index] ?? item.cell.row
            result.append(item)
        }
        if !didPlaceMoved { result.append(moved) }
        return result
    }

    /// Меняет размер элемента на месте (E14.2, D31).
    ///
    /// Якорная ячейка остаётся; если `column + новая ширина > columns`, колонка
    /// сдвигается влево (``clamped(cell:size:columns:)``). Рост разрешает
    /// пересечения тем же каскадом выталкивания вниз, что и
    /// ``inserting(id:size:at:into:columns:)``. Уменьшение ничего не двигает и
    /// оставляет дыру. Неизвестный `id` или `columns <= 0` — вход без изменений.
    ///
    /// - Parameters:
    ///   - id: Идентификатор изменяемого элемента.
    ///   - newSize: Новый размер.
    ///   - placements: Текущий набор размещений.
    ///   - columns: Число колонок.
    /// - Returns: Новый набор размещений.
    public static func resizing(
        id: AnyHashable,
        to newSize: TileSize,
        in placements: [TilePlacedItem],
        columns: Int
    ) -> [TilePlacedItem] {
        guard columns > 0, let item = placements.first(where: { $0.id == id }) else {
            return placements
        }
        return inserting(id: id, size: newSize, at: item.cell, into: placements, columns: columns)
    }

    /// Убирает элемент из набора **без** репака — дыра остаётся (E14.2, D30).
    ///
    /// - Parameters:
    ///   - id: Идентификатор удаляемого элемента.
    ///   - placements: Текущий набор размещений.
    /// - Returns: Набор без элемента; остальные элементы не двигаются.
    public static func removing(id: AnyHashable, from placements: [TilePlacedItem]) -> [TilePlacedItem] {
        placements.filter { $0.id != id }
    }

    /// Схлопывает пустые строки (E14.2, D31).
    ///
    /// Строка удаляется, только если её не покрывает **ни один** прямоугольник —
    /// высокие плитки (2×2, 4×4) покрывают все свои строки. Каждый элемент
    /// сдвигается вверх на число удалённых строк выше его верхней строки;
    /// многострочные пустые промежутки (включая пустые строки в самом верху)
    /// схлопываются целиком. Монотонное отображение строк сохраняет непрерывность
    /// следа и не создаёт пересечений. Горизонтальные координаты не меняются.
    ///
    /// Вызывается слоем правки **только на drop**, не во время drag (D31).
    ///
    /// - Parameters:
    ///   - placements: Текущий набор размещений.
    ///   - columns: Число колонок (нужно для ужатия размеров под узкую сетку:
    ///     высота большой плитки на узкой сетке — по ``fittingSize(_:columns:)``).
    /// - Returns: Набор без пустых строк; порядок массива сохранён.
    public static func collapsingEmptyRows(
        in placements: [TilePlacedItem],
        columns: Int
    ) -> [TilePlacedItem] {
        guard columns > 0, !placements.isEmpty else { return placements }

        var covered = Set<Int>()
        var maxRow = 0
        for item in placements {
            let rect = placementRect(item, columns: columns)
            guard rect.row >= 0 else { continue }
            for row in rect.row..<rect.bottom { covered.insert(row) }
            maxRow = max(maxRow, rect.bottom)
        }

        // shift[r] — сколько пустых строк лежит строго выше строки r.
        var shift = Array(repeating: 0, count: maxRow + 1)
        var removed = 0
        for row in 0...maxRow {
            shift[row] = removed
            if !covered.contains(row) { removed += 1 }
        }
        guard removed > 0 else { return placements }

        return placements.map { item in
            guard item.cell.row >= 0, item.cell.row <= maxRow else { return item }
            var shifted = item
            shifted.cell.row -= shift[item.cell.row]
            return shifted
        }
    }

    // MARK: Свободные ячейки

    /// Ячейка «новая строка»: первая строка после последней занятой, колонка 0
    /// (E14.2, D30).
    ///
    /// Для новых закреплений и цели drop «снизу». Пустой набор даёт строку 0.
    ///
    /// - Parameters:
    ///   - size: Размер размещаемого элемента (колонка 0 помещается всегда, размер
    ///     учитывается для единообразия через ``clamped(cell:size:columns:)``).
    ///   - columns: Число колонок.
    ///   - placements: Текущий набор размещений.
    ///   - excluding: Идентификатор элемента, который не учитывается (переносимый
    ///     элемент освобождает своё место).
    /// - Returns: Ячейка `(row: нижняя граница, column: 0)`.
    public static func newRowCell(
        size: TileSize,
        columns: Int,
        placements: [TilePlacedItem],
        excluding id: AnyHashable? = nil
    ) -> TileGridPlacement {
        guard columns > 0 else { return TileGridPlacement(row: 0, column: 0) }

        var bottom = 0
        for item in placements where item.id != id {
            bottom = max(bottom, placementRect(item, columns: columns).bottom)
        }
        return clamped(cell: TileGridPlacement(row: bottom, column: 0), size: size, columns: columns)
    }

    /// Первая свободная ячейка «сверху-слева» под размер (first-fit) (E14.2).
    ///
    /// Перебор строк сверху вниз, колонок слева направо; результат — первая
    /// позиция, где весь прямоугольник свободен. Находится всегда: ниже последней
    /// занятой строки место свободно. Нужна для случаев переноса, когда нужную
    /// ячейку занять нельзя.
    ///
    /// - Parameters:
    ///   - size: Размер размещаемого элемента.
    ///   - columns: Число колонок.
    ///   - placements: Текущий набор размещений.
    ///   - excluding: Идентификатор элемента, который не учитывается (переносимый
    ///     элемент освобождает своё место).
    /// - Returns: Ячейка левого верхнего угла.
    public static func firstFreeCell(
        size: TileSize,
        columns: Int,
        placements: [TilePlacedItem],
        excluding id: AnyHashable? = nil
    ) -> TileGridPlacement {
        guard columns > 0 else { return TileGridPlacement(row: 0, column: 0) }

        let fitted = fittingSize(size, columns: columns)
        let obstacles = placements
            .filter { $0.id != id }
            .map { placementRect($0, columns: columns) }
        let lastRow = obstacles.map(\.bottom).max() ?? 0

        for row in 0...max(0, lastRow) {
            for column in 0...(columns - fitted.unitColumns) {
                let candidate = PlacementRect(
                    row: row,
                    column: column,
                    width: fitted.unitColumns,
                    height: fitted.unitRows
                )
                if !obstacles.contains(where: { $0.overlaps(candidate) }) {
                    return TileGridPlacement(row: row, column: column)
                }
            }
        }
        return TileGridPlacement(row: max(0, lastRow), column: 0)
    }

    // MARK: Внутреннее

    /// След элемента: ячейка плюс размер, ужатый под узкую сетку.
    fileprivate static func placementRect(_ item: TilePlacedItem, columns: Int) -> PlacementRect {
        let fitted = fittingSize(item.size, columns: columns)
        return PlacementRect(
            row: item.cell.row,
            column: item.cell.column,
            width: fitted.unitColumns,
            height: fitted.unitRows
        )
    }
}
