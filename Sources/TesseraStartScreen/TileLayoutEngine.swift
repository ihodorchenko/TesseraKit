// Раскладка плиточной сетки рабочего стола в юнитных координатах.
// Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md — §3 «Плиточная сетка»
// (формула юнита, жадная упаковка слева направо сверху вниз, «честные дыры»,
// хранение позиции в юнитных координатах) и §14 «Уточнения MVP» п. 4
// (D15: четыре размера — 1×1, 2×2, 4×2, 4×4).
//
// Модуль намеренно чистый: только CoreGraphics (`CGFloat`, `CGSize`, `CGRect`)
// и модель `TileSize`. Никакого UIKit, layout-контекста и состояния — все
// функции детерминированы и тестируются без UI (E4.7).

import CoreGraphics

/// Позиция ярлыка на сетке в юнитных координатах
/// (docs/STARTSCREEN-IOS-DESIGN.md §3, «Модель раскладки»).
///
/// Положение хранится парой ``column``/``row`` в юнитах, а не в точках: при
/// повороте экрана или смене ширины меняется только ``unit``, а юнитные
/// координаты остаются прежними. ``size`` описывает запрошенный размер плитки
/// (D15), ``unitColumns``/``unitRows`` — её фактический след на сетке.
///
/// ``frame`` — «сырая» рамка в точках без промежутков (unit × юнитные
/// координаты). Итоговая геометрия с зазорами между юнитами и началом координат
/// контента считается через ``TileLayoutEngine/rect(for:unit:gap:origin:)``.
public struct TileLayoutSlot: Equatable {
    /// Идентификатор ярлыка, к которому относится слот.
    public let id: AnyHashable

    /// Запрошенный размер плитки (D15).
    public let size: TileSize

    /// Колонка левого верхнего угла в юнитах (отсчёт от 0, слева направо).
    public let column: Int

    /// Строка левого верхнего угла в юнитах (отсчёт от 0, сверху вниз).
    public let row: Int

    /// Размер одного юнита в точках, с которым считалась эта раскладка.
    ///
    /// Хранится снимком, чтобы ``frame`` и
    /// ``TileLayoutEngine/rect(for:unit:gap:origin:)`` могли работать без
    /// повторной передачи геометрии. При повороте/смене ширины раскладку
    /// пересобирают через ``TileLayoutEngine/repack(_:columns:unit:)`` —
    /// юнитные координаты при этом не меняются.
    public let unit: CGFloat

    /// Создаёт слот раскладки.
    ///
    /// Обычно слоты создаёт ``TileLayoutEngine/pack(items:columns:unit:)``;
    /// инициализатор публичный, чтобы тесты и потребители могли собрать
    /// ожидаемое значение без запуска упаковки.
    ///
    /// - Parameters:
    ///   - id: Идентификатор ярлыка.
    ///   - size: Размер плитки в юнитах.
    ///   - column: Колонка левого верхнего угла в юнитах.
    ///   - row: Строка левого верхнего угла в юнитах.
    ///   - unit: Размер юнита в точках.
    public init(id: AnyHashable, size: TileSize, column: Int, row: Int, unit: CGFloat) {
        self.id = id
        self.size = size
        self.column = column
        self.row = row
        self.unit = unit
    }

    /// Ширина следа плитки в юнитах.
    public var unitColumns: Int {
        size.unitColumns
    }

    /// Высота следа плитки в юнитах.
    public var unitRows: Int {
        size.unitRows
    }

    /// Прямоугольник слота в юнитных координатах: `x = column`, `y = row`,
    /// `width = unitColumns`, `height = unitRows`.
    ///
    /// Удобен для проверок и отладки; для точек используйте ``frame`` или
    /// ``TileLayoutEngine/rect(for:unit:gap:origin:)``.
    public var unitFrame: CGRect {
        CGRect(
            x: CGFloat(column),
            y: CGFloat(row),
            width: CGFloat(unitColumns),
            height: CGFloat(unitRows)
        )
    }

    /// Рамка слота в точках без промежутков между юнитами.
    ///
    /// Это `unit × unitFrame`. Реальная сетка добавляет зазоры между соседними
    /// юнитами, поэтому для отрисовки нужен
    /// ``TileLayoutEngine/rect(for:unit:gap:origin:)``: он же учитывает
    /// внутренние зазоры широких и больших плиток.
    ///
    /// При нечисловом или неположительном ``unit`` возвращается `.zero`.
    public var frame: CGRect {
        guard unit.isFinite, unit > 0 else { return .zero }

        return CGRect(
            x: CGFloat(column) * unit,
            y: CGFloat(row) * unit,
            width: CGFloat(unitColumns) * unit,
            height: CGFloat(unitRows) * unit
        )
    }
}

/// Чистые функции раскладки плиточной сетки
/// (docs/STARTSCREEN-IOS-DESIGN.md §3, «Плиточная сетка»; D15 в docs/STATE.md).
///
/// Сетка описывается числом колонок и размером юнита в точках. Плитки четырёх
/// размеров упаковываются жадно: слева направо, сверху вниз, в первую свободную
/// позицию, куда прямоугольник помещается целиком. Пустые юниты не заливаются
/// соседями — «честные дыры» допускаются документом §3; более поздняя плитка
/// может занять дыру, оставшуюся выше, потому что поиск каждый раз начинается
/// с верхней строки.
///
/// Все функции — `static` и не хранят состояние: результат зависит только от
/// аргументов. Направление чтения (RTL) здесь не учитывается — зеркалирование
/// сетки выполняет вью-слой (документ §9, «RTL»), а движок работает в
/// LTR-координатах.
public enum TileLayoutEngine {

    /// Размер одного юнита сетки в точках
    /// (docs/STARTSCREEN-IOS-DESIGN.md §3, «Модель раскладки»).
    ///
    /// Формула документа: `unit = (screenWidth − margins − gaps × (N − 1)) / N`.
    /// В сигнатуре нет отдельного `margins` (по заданию E4.2), поэтому
    /// `screenWidth` — уже доступная ширина контента: хост вычитает внешние
    /// поля сам, а параметр `gaps` — зазор между двумя соседними колонками.
    ///
    /// Защитные случаи: `columns <= 0`, нечисловые `screenWidth`/`gaps`,
    /// отрицательный зазор (трактуется как 0) и ситуация, когда зазоры съедают
    /// всю ширину, дают `0`. Отрицательный результат невозможен.
    ///
    /// - Parameters:
    ///   - screenWidth: Доступная ширина сетки в точках (без внешних полей).
    ///   - columns: Число колонок, больше нуля.
    ///   - gaps: Зазор между соседними колонками в точках.
    /// - Returns: Размер юнита в точках или `0` для вырожденной геометрии.
    public static func unit(screenWidth: CGFloat, columns: Int, gaps: CGFloat) -> CGFloat {
        guard columns > 0, screenWidth.isFinite, gaps.isFinite else { return 0 }

        let spacing = max(gaps, 0)
        let available = screenWidth - spacing * CGFloat(columns - 1)

        guard available.isFinite, available > 0 else { return 0 }

        return available / CGFloat(columns)
    }

    /// Жадно упаковывает плитки в юнитные координаты
    /// (docs/STARTSCREEN-IOS-DESIGN.md §3, «Алгоритм упаковки»).
    ///
    /// Для каждой плитки в порядке массива перебираются строки сверху вниз и
    /// колонки слева направо; выбирается первая позиция, где весь прямоугольник
    /// `unitColumns × unitRows` свободен. Занятые юниты не сдвигаются и не
    /// пересобираются — дыры остаются «честными» (документ §3). Плитка,
    /// поместившаяся в дыру выше, может занять её: поиск всегда начинается с
    /// нулевой строки.
    ///
    /// Возвращаемые слоты идут **в порядке входного массива**, а не в порядке
    /// обхода сетки: по индексу слота можно сопоставить его с ярлыком. Если
    /// ширина плитки больше числа колонок (например, `.wide` при `columns == 3`),
    /// плитка пропускается: сетка не может изобразить её без искажения размера.
    ///
    /// - Parameters:
    ///   - items: Пары «идентификатор ярлыка — размер плитки» в порядке сетки.
    ///   - columns: Число колонок, больше нуля (для всех размеров D15 нужно ≥ 4).
    ///   - unit: Размер юнита в точках, больше нуля.
    /// - Returns: Слоты в порядке `items`; пустой массив для вырожденной
    ///   геометрии или пустого входа.
    public static func pack(
        items: [(id: AnyHashable, size: TileSize)],
        columns: Int,
        unit: CGFloat
    ) -> [TileLayoutSlot] {
        guard columns > 0, unit.isFinite, unit > 0 else { return [] }

        // Занятость сетки: строки добавляются по мере роста упаковки.
        // Матрица, а не словарь, потому что перебор идёт построчно и подряд.
        var occupied: [[Bool]] = []
        var slots: [TileLayoutSlot] = []
        slots.reserveCapacity(items.count)

        for item in items {
            let width = item.size.unitColumns
            let height = item.size.unitRows

            // Плитка шире сетки не помещается без искажения размера.
            guard width > 0, height > 0, width <= columns else { continue }

            var row = 0
            while true {
                ensureRows(&occupied, count: row + height, columns: columns)

                if let column = firstFreeColumn(
                    in: occupied,
                    row: row,
                    width: width,
                    height: height,
                    columns: columns
                ) {
                    markOccupied(
                        &occupied,
                        column: column,
                        row: row,
                        width: width,
                        height: height
                    )
                    slots.append(
                        TileLayoutSlot(
                            id: item.id,
                            size: item.size,
                            column: column,
                            row: row,
                            unit: unit
                        )
                    )
                    break
                }

                row += 1
            }
        }

        return slots
    }

    /// Пересобирает раскладку из готовых слотов
    /// (docs/STARTSCREEN-IOS-DESIGN.md §3, «Реализация — кастомный
    /// UICollectionViewLayout»: изменения модели переупаковываются и
    /// инвалидируют layout).
    ///
    /// Идентификаторы и размеры берутся из `slots` в порядке массива, после
    /// чего выполняется ``pack(items:columns:unit:)``. Используется при смене
    /// числа колонок или размера юнита (поворот/другая ширина экрана): юнитные
    /// координаты пересчитываются, а ``TileLayoutSlot/unit`` и рамки слотов
    /// получают новую геометрию.
    ///
    /// - Parameters:
    ///   - slots: Текущие слоты в порядке ярлыков.
    ///   - columns: Новое число колонок.
    ///   - unit: Новый размер юнита в точках.
    /// - Returns: Пересобранные слоты; пустой массив для вырожденной геометрии.
    public static func repack(
        _ slots: [TileLayoutSlot],
        columns: Int,
        unit: CGFloat
    ) -> [TileLayoutSlot] {
        let items: [(id: AnyHashable, size: TileSize)] = slots.map {
            (id: $0.id, size: $0.size)
        }
        return pack(items: items, columns: columns, unit: unit)
    }

    /// Меняет размер одной плитки и переупаковывает всю сетку
    /// (docs/STARTSCREEN-IOS-DESIGN.md §3, §14 п. 4; D15).
    ///
    /// Resize в WP-стиле — смена ``TileSize`` с последующей переупаковкой:
    /// меняется только след плитки, порядок остальных ярлыков сохраняется.
    /// Меняется первая плитка с идентификатором `id`; идентификаторы ярлыков
    /// уникальны (см. ``TileDescriptor/id``), поэтому неоднозначности нет.
    /// Если `id` не найден, раскладка просто пересобирается без изменений —
    /// это позволяет использовать метод как общий `repack`.
    ///
    /// - Parameters:
    ///   - slots: Текущие слоты в порядке ярлыков.
    ///   - id: Идентификатор изменяемой плитки.
    ///   - size: Новый размер плитки.
    ///   - columns: Число колонок.
    ///   - unit: Размер юнита в точках.
    /// - Returns: Пересобранные слоты в прежнем порядке ярлыков.
    public static func resizing(
        _ slots: [TileLayoutSlot],
        id: AnyHashable,
        to size: TileSize,
        columns: Int,
        unit: CGFloat
    ) -> [TileLayoutSlot] {
        var didResize = false
        let items: [(id: AnyHashable, size: TileSize)] = slots.map { slot in
            if !didResize, slot.id == id {
                didResize = true
                return (id: slot.id, size: size)
            }
            return (id: slot.id, size: slot.size)
        }
        return pack(items: items, columns: columns, unit: unit)
    }

    /// Переводит слот из юнитных координат в рамку в точках
    /// (docs/STARTSCREEN-IOS-DESIGN.md §3, «Модель раскладки»).
    ///
    /// Координаты:
    /// - `x = origin.x + column × (unit + gap)`,
    /// - `y = origin.y + row × (unit + gap)`,
    /// - `width = unitColumns × unit + (unitColumns − 1) × gap`,
    /// - `height = unitRows × unit + (unitRows − 1) × gap`.
    ///
    /// Внутренние зазоры входят в рамку широкой/большой плитки: плитка 2×2
    /// занимает два юнита и зазор между ними, а не «съедает» его.
    ///
    /// - Parameters:
    ///   - slot: Слот в юнитных координатах.
    ///   - unit: Размер юнита в точках; `nil` — использовать
    ///     ``TileLayoutSlot/unit``, с которым считался слот.
    ///   - gap: Зазор между соседними юнитами в точках; отрицательный
    ///     трактуется как 0.
    ///   - origin: Начало координат контента сетки (например, `contentInset`).
    /// - Returns: Рамка в точках; `.zero` для нечислового/неположительного
    ///   юнита или пустого следа плитки.
    public static func rect(
        for slot: TileLayoutSlot,
        unit: CGFloat? = nil,
        gap: CGFloat = 0,
        origin: CGPoint = .zero
    ) -> CGRect {
        let scale = unit ?? slot.unit
        guard scale.isFinite, scale > 0 else { return .zero }

        let columns = slot.unitColumns
        let rows = slot.unitRows
        guard columns > 0, rows > 0 else { return .zero }

        let spacing = gap.isFinite ? max(gap, 0) : 0

        return CGRect(
            x: origin.x + CGFloat(slot.column) * (scale + spacing),
            y: origin.y + CGFloat(slot.row) * (scale + spacing),
            width: CGFloat(columns) * scale + CGFloat(columns - 1) * spacing,
            height: CGFloat(rows) * scale + CGFloat(rows - 1) * spacing
        )
    }

    // MARK: - Внутренняя упаковка

    /// Достраивает матрицу занятости до `count` строк.
    private static func ensureRows(_ grid: inout [[Bool]], count: Int, columns: Int) {
        guard grid.count < count else { return }

        let newRows = Array(
            repeating: Array(repeating: false, count: columns),
            count: count - grid.count
        )
        grid.append(contentsOf: newRows)
    }

    /// Ищет первую свободную колонку в строке `row` для прямоугольника
    /// `width × height`.
    private static func firstFreeColumn(
        in grid: [[Bool]],
        row: Int,
        width: Int,
        height: Int,
        columns: Int
    ) -> Int? {
        guard width <= columns else { return nil }

        for column in 0...(columns - width) {
            if isFree(in: grid, column: column, row: row, width: width, height: height) {
                return column
            }
        }
        return nil
    }

    /// Проверяет, что прямоугольник целиком свободен.
    ///
    /// Вызывающий обязан заранее достроить матрицу до `row + height` строк
    /// (``ensureRows``), поэтому индексация здесь безопасна.
    private static func isFree(
        in grid: [[Bool]],
        column: Int,
        row: Int,
        width: Int,
        height: Int
    ) -> Bool {
        for currentRow in row..<(row + height) {
            for currentColumn in column..<(column + width) where grid[currentRow][currentColumn] {
                return false
            }
        }
        return true
    }

    /// Помечает прямоугольник занятым.
    private static func markOccupied(
        _ grid: inout [[Bool]],
        column: Int,
        row: Int,
        width: Int,
        height: Int
    ) {
        for currentRow in row..<(row + height) {
            for currentColumn in column..<(column + width) {
                grid[currentRow][currentColumn] = true
            }
        }
    }
}
