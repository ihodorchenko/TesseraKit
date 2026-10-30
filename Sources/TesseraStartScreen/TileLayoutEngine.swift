// Раскладка плиточной сетки рабочего стола в юнитных координатах.
// Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md — §3 «Плиточная сетка»
// (формула юнита, упаковка слева направо сверху вниз, хранение позиции в
// юнитных координатах) и §14 «Уточнения MVP» п. 4 (D15: четыре размера —
// 1×1, 2×2, 4×2, 4×4).
//
// E8.5 — строгая компактность: «честные дыры» §3 отменены, финальная раскладка
// компактна сверху вниз (см. ``TileLayoutEngine/packCompact(items:columns:unit:)``
// и «Отступления реализации» в проектном документе). Публичный вход прежний —
// ``TileLayoutEngine/pack(items:columns:unit:)`` — и теперь он компактный:
// обычная раскладка и edit/drag дают одинаковый визуал.
//
// D17 (docs/STATE.md) — панель раскрытой папки: чистые функции индекса вставки
// панели после строки папки, отступа строк под панелью и её высоты — в конце
// файла. Основная часть движка остаётся без UIKit и без состояния.
//
// E8.4 — ``previewOrder(items:draggingID:targetID:)``: чистое превью порядка
// при перетаскивании (push-физика без записи в `TileStore`). Функция работает
// только с идентификаторами модели (`TileGridItem`), геометрию не считает.
//
// E8.7 — ``resizePlacement(items:resizingID:newSize:columns:)``: чистое
// размещение при resize. Увеличенная плитка по возможности остаётся на своём
// месте, а конфликтующие плитки справа/снизу уходят в конец порядка — их
// упаковывает ``pack(items:columns:unit:)`` уже ниже. Уменьшение порядок не
// меняет. Функция тоже работает только с моделью и упаковкой.
//
// Модуль намеренно чистый: только CoreGraphics (`CGFloat`, `CGSize`, `CGRect`),
// модель `TileSize` и элементы снимка сетки. Никакого UIKit, layout-контекста и
// состояния — все функции детерминированы и тестируются без UI (E4.7).

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
/// размеров упаковываются строго компактно: каждая встаёт в самую верхнюю-левую
/// позицию, где помещается целиком, а после размещения всю раскладку можно
/// «схлопнуть» вверх-влево до неподвижной точки. Свободный юнит остаётся только
/// там, куда не помещается ни одна из текущих плиток (например, справа от 2×2,
/// если следующая плитка — 4×2); если плитку утащили, нижние поднимаются в
/// освободившееся место.
///
/// «Честные дыры» проектного документа §3 (E8.5) отменены: отступление
/// зафиксировано в «Отступлениях реализации» docs/STARTSCREEN-IOS-DESIGN.md.
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

    /// Упаковывает плитки строго компактно
    /// (docs/STARTSCREEN-IOS-DESIGN.md §3; E8.5).
    ///
    /// Публичный вход раскладки. Работает как
    /// ``packCompact(items:columns:unit:)``: каждая плитка встаёт в самую
    /// верхнюю-левую позицию, где помещается целиком, затем раскладка
    /// схлопывается вверх-влево до неподвижной точки. Пустые юниты остаются
    /// только там, куда не помещается ни одна из **текущих** плиток; «честные
    /// дыры» §3 (E8.5) отменены.
    ///
    /// Строгая компактность применяется и к обычной раскладке, и к
    /// edit/drag-переупаковке (обе идут через эту функцию), поэтому визуал
    /// режимов не различается и после перетаскивания нижние плитки поднимаются
    /// в освободившиеся места.
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
        packCompact(items: items, columns: columns, unit: unit)
    }

    // MARK: - Строгая компактность (E8.5)

    /// Строго компактная упаковка: якорь + схлопывание (E8.5).
    ///
    /// Алгоритм из двух фаз:
    ///
    /// 1. **Якорь.** Для каждой плитки в порядке массива перебираются строки
    ///    сверху вниз и колонки слева направо; выбирается первая позиция, где
    ///    весь прямоугольник `unitColumns × unitRows` свободен. Более поздняя
    ///    плитка поэтому всегда занимает свободное место выше, если оно есть.
    /// 2. **Схлопывание.** ``stabilize(_:columns:)`` снимает каждую плитку с
    ///    сетки и ищет для неё более раннюю позицию (выше или левее в той же
    ///    строке); проход повторяется до неподвижной точки. Якорная фаза уже
    ///    даёт неподвижную точку для текущего порядка, поэтому на практике
    ///    схлопывание ничего не двигает — оно гарантирует инвариант и подстрахует
    ///    будущие изменения якорной стратегии.
    ///
    /// Дыра остаётся только там, куда не помещается ни одна из текущих плиток
    /// (например, справа от 2×2, если следующая плитка — 4×2). Это не «честная
    /// дыра» §3, а след размеров: сдвигать в неё нечего. Если позже появится
    /// плитка подходящего размера, она займёт это место при переупаковке; если
    /// плитку утащили, нижние поднимаются вверх.
    ///
    /// - Parameters:
    ///   - items: Пары «идентификатор ярлыка — размер плитки» в порядке сетки.
    ///   - columns: Число колонок, больше нуля.
    ///   - unit: Размер юнита в точках, больше нуля.
    /// - Returns: Слоты в порядке `items`; пустой массив для вырожденной
    ///   геометрии или пустого входа.
    static func packCompact(
        items: [(id: AnyHashable, size: TileSize)],
        columns: Int,
        unit: CGFloat
    ) -> [TileLayoutSlot] {
        guard columns > 0, unit.isFinite, unit > 0 else { return [] }

        // Фаза 1 «якорь»: занятость сетки — матрица, потому что перебор идёт
        // построчно и подряд; строки добавляются по мере роста упаковки.
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

        // Фаза 2 «схлопывание»: дыры, в которые можно сдвинуть плитку вверх или
        // влево, не остаются.
        return stabilize(slots, columns: columns)
    }

    /// Схлопывает раскладку вверх-влево до неподвижной точки (E8.5).
    ///
    /// Каждая плитка по очереди снимается с сетки и ставится в самую раннюю
    /// свободную позицию: сначала строки выше, затем — в своей строке левее
    /// текущей колонки. Позиция «правее в той же строке» или «ниже» не
    /// считается улучшением, поэтому порядок массива слотов не меняется —
    /// двигаются только координаты.
    ///
    /// Проход повторяется, пока хоть одна плитка сдвинулась: сдвиг верхней
    /// плитки освобождает место нижней. Каждый сдвиг строго уменьшает
    /// лексикографический ключ `(row, column)` одной плитки, поэтому цикл
    /// конечен (ключей конечное число, сумма ключей убывает).
    ///
    /// Функция внутренняя: публичная упаковка — ``pack(items:columns:unit:)``.
    /// Отдельно от неё тестируется искусственно «подвешенная» плитка, которую
    /// нужно поднять.
    ///
    /// - Parameters:
    ///   - slots: Слоты в любом порядке; координаты неотрицательны.
    ///   - columns: Число колонок, больше нуля.
    /// - Returns: Слоты в прежнем порядке с компактными координатами; при
    ///   вырожденных аргументах (неположительные координаты, плитка шире сетки)
    ///   — входной массив без изменений.
    static func stabilize(_ slots: [TileLayoutSlot], columns: Int) -> [TileLayoutSlot] {
        guard columns > 0, !slots.isEmpty else { return slots }
        guard slots.allSatisfy({
            $0.unitColumns > 0
                && $0.unitRows > 0
                && $0.unitColumns <= columns
                && $0.column >= 0
                && $0.row >= 0
        }) else {
            return slots
        }

        var working = slots

        // Матрица занятости всей раскладки: высота — до последней занятой строки.
        var height = 0
        for slot in working {
            height = max(height, slot.row + slot.unitRows)
        }
        var occupied = Array(
            repeating: Array(repeating: false, count: columns),
            count: height
        )
        for slot in working {
            markOccupied(
                &occupied,
                column: slot.column,
                row: slot.row,
                width: slot.unitColumns,
                height: slot.unitRows
            )
        }

        var didMove = true
        while didMove {
            didMove = false

            // Обход сверху вниз и слева направо: сдвиг верхней плитки
            // освобождает место нижней в том же проходе.
            let order = working.indices.sorted { lhs, rhs in
                let left = working[lhs]
                let right = working[rhs]
                if left.row != right.row {
                    return left.row < right.row
                }
                return left.column < right.column
            }

            for index in order {
                let slot = working[index]

                // Снимаем плитку: её собственные юниты не мешают поиску.
                unmarkOccupied(
                    &occupied,
                    column: slot.column,
                    row: slot.row,
                    width: slot.unitColumns,
                    height: slot.unitRows
                )

                if let target = firstEarlierFreePosition(
                    in: occupied,
                    column: slot.column,
                    row: slot.row,
                    width: slot.unitColumns,
                    height: slot.unitRows,
                    columns: columns
                ) {
                    working[index] = TileLayoutSlot(
                        id: slot.id,
                        size: slot.size,
                        column: target.column,
                        row: target.row,
                        unit: slot.unit
                    )
                    markOccupied(
                        &occupied,
                        column: target.column,
                        row: target.row,
                        width: slot.unitColumns,
                        height: slot.unitRows
                    )
                    didMove = true
                } else {
                    markOccupied(
                        &occupied,
                        column: slot.column,
                        row: slot.row,
                        width: slot.unitColumns,
                        height: slot.unitRows
                    )
                }
            }
        }

        return working
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

    // MARK: - Превью порядка при перетаскивании (E8.4)

    // Функция работает с `TileGridItem` из снимка `TileStore`; этот тип объявлен
    // под `canImport(UIKit)`, поэтому и функция доступна только там.
    #if canImport(UIKit)

    /// Превью порядка сетки при наведении перетаскиваемой плитки на цель.
    ///
    /// Push-физика спеки WP (E8.4): перетаскиваемая плитка занимает слот цели,
    /// а не «переставляется рядом с ней». Алгоритм: вынуть `draggingID` из
    /// `items` и вставить его на **исходный** индекс `targetID` (индекс цели в
    /// переданном наборе, до вынимания). Следствия:
    ///
    /// - если перетаскиваемая плитка была ниже цели, цель и всё, что ниже неё,
    ///   сдвигается на одну позицию вниз — перетаскиваемая занимает слот цели;
    /// - если перетаскиваемая была выше цели, плитки между старой и новой
    ///   позицией сдвигаются на одну позицию вверх, заполняя освободившийся
    ///   слот, а перетаскиваемая встаёт на место цели.
    ///
    /// Индекс вставки совпадает с индексом перетаскиваемой плитки в превью,
    /// поэтому фиксация drop'а — это `TileStore.move(draggingID,
    /// toIndex: indexOfDraggingInPreview)`: `TileStore` вынимает элемент и
    /// вставляет его по тому же правилу, и порядок совпадает с превью
    /// (проверяется тестом `TileDragPushTests`).
    ///
    /// Функция чистая: `TileStore` не трогает, от геометрии не зависит и
    /// вызывается на каждом шаге drag без записи в модель (запись — только на
    /// drop).
    ///
    /// Вырожденные случаи дают `nil`: пустой набор, `draggingID == targetID`,
    /// один из идентификаторов не найден, а также если найденный элемент —
    /// панель раскрытой папки (D17): панель не плитка и в перестановке не
    /// участвует.
    ///
    /// - Parameters:
    ///   - items: Порядок сетки на момент захвата (базовый, без превью).
    ///   - draggingID: Идентификатор перетаскиваемой плитки.
    ///   - targetID: Идентификатор плитки-цели под пальцем.
    /// - Returns: Новый порядок или `nil` для вырожденного случая.
    public static func previewOrder(
        items: [TileGridItem],
        draggingID: AnyHashable,
        targetID: AnyHashable
    ) -> [TileGridItem]? {
        guard !items.isEmpty,
              draggingID != targetID,
              let from = items.firstIndex(where: { $0.id == draggingID }),
              let target = items.firstIndex(where: { $0.id == targetID }),
              !items[from].isFolderPanel,
              !items[target].isFolderPanel else {
            return nil
        }

        var order = items
        let dragging = order.remove(at: from)
        // Индекс цели — исходный: после вынимания он может уменьшиться на 1,
        // но вставка именно на исходный индекс и даёт «плитка встаёт на место
        // цели». Для последнего элемента значение зажимается длиной набора.
        order.insert(dragging, at: min(target, order.count))
        return order
    }

    // MARK: - Resize-выталкивание (E8.7)

    /// Новый порядок сетки после изменения размера плитки (E8.7).
    ///
    /// Resize в стиле WP: увеличиваемая плитка **по возможности остаётся на
    /// своём месте**, а плитки, которые мешают новому размеру, выталкиваются
    /// вниз. Функция чистая: она не трогает `TileStore`, а возвращает порядок
    /// элементов, который затем упаковывается
    /// ``pack(items:columns:unit:)`` и анимируется batch-обновлением сетки
    /// (`TesseraTileGridView.update(snapshot:animated:)`).
    ///
    /// ## Правила
    ///
    /// 1. **Текущая раскладка.** Элементы упаковываются так же, как в сетке:
    ///    ``fittingSize(_:columns:)`` (ужимание под узкую сетку) и
    ///    ``pack(items:columns:unit:)`` с юнитом 1 — юнитные координаты от
    ///    масштаба не зависят.
    /// 2. **Целевое место.** Целевая строка — прежняя (если уход конфликтов не
    ///    открыл выше дыру, в которую плитку поднимет схлопывание E8.5), целевая
    ///    колонка — `min(колонка, columns − newSize.unitColumns)`: широкая плитка
    ///    (4 юнита) при четырёх колонках всегда встаёт в колонку 0, средняя при
    ///    трёх — не правее колонки 1. Собственный старый след плитки при проверке
    ///    считается свободным: плитка растёт на своём месте.
    /// 3. **Место справа — по юнитам.** Целевой прямоугольник
    ///    `newSize.unitColumns × newSize.unitRows` должен быть свободен в каждой
    ///    строке плитки, то есть число свободных колонок справа от целевой
    ///    колонки в этих строках должно быть не меньше `newSize.unitColumns`.
    ///    При росте вниз (wide 4×2 → large 4×4) проверяются и добавленные снизу
    ///    строки; при росте вширь — колонки справа. Любая другая плитка в этих
    ///    юнитах — конфликт.
    /// 4. **Помещается.** Порядок не меняется, изменённая плитка сохраняет
    ///    индекс. При увеличении она остаётся и на прежней позиции, а соседи не
    ///    трогаются: ``pack`` воспроизводит их слоты (префикс порядка и размеры
    ///    остальных плиток прежние). При уменьшении компактная упаковка может
    ///    подтянуть плитку вверх или влево в освободившееся место — это
    ///    требование E8.5, а не выталкивание соседей.
    /// 5. **Не помещается.** Конфликтующие плитки уходят в **конец** порядка:
    ///    упаковка ставит их последними, то есть в самые нижние свободные места,
    ///    а изменённая плитка встаёт в первую свободную позицию своего нового
    ///    следа. Остальные элементы идут в порядке чтения — сверху вниз, слева
    ///    направо: упаковка сохраняет их взаимный порядок и слоты всюду, где
    ///    уход конфликтов не освободил место выше. Результат детерминирован —
    ///    «плавания» по случайным позициям нет, только компактное схлопывание.
    /// 6. **Уменьшение.** Новый след — подмножество старого, конфликтов нет,
    ///    порядок не меняется: выталкиваний при уменьшении не бывает.
    ///
    /// Строгая компактность E8.5 применяется после: если из-за ухода конфликтов
    /// выше образовалась дыра, в которую помещается только конфликтующая плитка,
    /// она её заполнит. Это не произвольное «плавание», а требование E8.5
    /// (пустых дыр не остаётся). Вниз изменённая плитка при этом не опускается:
    /// схлопывание двигает плитку только вверх или влево — проверено тестами.
    ///
    /// Панель раскрытой папки (D17) — не плитка, а представление: набор, в
    /// котором она есть, функция не переставляет и возвращает как есть
    /// (`TileStore` панель не хранит, поэтому в resize-потоке её и нет).
    ///
    /// - Parameters:
    ///   - items: Элементы сетки в порядке `TileStore`.
    ///   - resizingID: Идентификатор изменяемой плитки или папки.
    ///   - newSize: Новый размер (D15).
    ///   - columns: Число колонок сетки, больше нуля.
    /// - Returns: Новый порядок, в котором изменённая плитка уже имеет
    ///   `newSize`. Исходный массив — для вырожденных случаев: пустой набор,
    ///   нет такого элемента, элемент — панель, панель есть в наборе,
    ///   неположительное число колонок.
    public static func resizePlacement(
        items: [TileGridItem],
        resizingID: AnyHashable,
        newSize: TileSize,
        columns: Int
    ) -> [TileGridItem] {
        guard columns > 0,
              !items.isEmpty,
              !items.contains(where: { $0.isFolderPanel }),
              let index = items.firstIndex(where: { $0.id == resizingID }),
              items[index].size != newSize else {
            return items
        }

        // Тот же след, что увидит раскладка: ужимаем под узкую сетку (D15).
        let footprint = fittingSize(newSize, columns: columns)
        let width = footprint.unitColumns
        let height = footprint.unitRows
        guard width > 0, height > 0, width <= columns else { return items }

        let packItems: [(id: AnyHashable, size: TileSize)] = items.map { item in
            (id: item.id, size: fittingSize(item.size, columns: columns))
        }
        let slots = pack(items: packItems, columns: columns, unit: 1)
        // fittingSize гарантирует, что ни одна плитка не пропущена; страховка
        // на случай будущих правил нормализации.
        guard slots.count == items.count,
              let slot = slots.first(where: { $0.id == resizingID }) else {
            return items
        }

        let targetColumn = min(slot.column, columns - width)
        let targetRow = slot.row
        let target = CGRect(
            x: CGFloat(targetColumn),
            y: CGFloat(targetRow),
            width: CGFloat(width),
            height: CGFloat(height)
        )

        // Конфликт — любая другая плитка, занимающая юниты целевого следа.
        var conflictingIDs = Set<AnyHashable>()
        for other in slots where other.id != resizingID && other.unitFrame.intersects(target) {
            conflictingIDs.insert(other.id)
        }

        let resizedItem = item(items[index], resizingTo: newSize)

        // Место справа свободно и колонка не требует сдвига — плитка остаётся
        // на своём месте, порядок не меняем.
        if conflictingIDs.isEmpty, targetColumn == slot.column {
            var result = items
            result[index] = resizedItem
            return result
        }

        // Остальные элементы — в порядке чтения: упаковка такого порядка
        // воспроизводит их слоты (каждая плитка не может встать раньше своей
        // позиции: более ранние юниты заняты плитками, идущими раньше).
        let readingOrder = slots.sorted { lhs, rhs in
            lhs.row != rhs.row ? lhs.row < rhs.row : lhs.column < rhs.column
        }
        let itemsByID = Dictionary(
            items.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var before: [TileGridItem] = []
        var after: [TileGridItem] = []
        for other in readingOrder {
            guard other.id != resizingID,
                  !conflictingIDs.contains(other.id),
                  let element = itemsByID[other.id] else { continue }
            if other.row < targetRow
                || (other.row == targetRow && other.column < targetColumn) {
                before.append(element)
            } else {
                after.append(element)
            }
        }

        let conflicting = readingOrder.compactMap { other -> TileGridItem? in
            guard conflictingIDs.contains(other.id) else { return nil }
            return itemsByID[other.id]
        }

        return before + [resizedItem] + after + conflicting
    }

    /// Копия элемента сетки с новым размером (E8.7).
    ///
    /// Меняет только ``TileSize``: заголовок, иконка, действие, бейдж и
    /// содержимое папки остаются прежними. Панель раскрытой папки размера не
    /// имеет, поэтому возвращается без изменений.
    ///
    /// - Parameters:
    ///   - item: Элемент сетки.
    ///   - size: Новый размер.
    /// - Returns: Копия элемента с новым размером.
    private static func item(_ item: TileGridItem, resizingTo size: TileSize) -> TileGridItem {
        switch item {
        case .tile(var descriptor):
            descriptor.size = size
            return .tile(descriptor)
        case .folder(var folder):
            folder.size = size
            return .folder(folder)
        case .folderContent:
            return item
        }
    }

    #endif

    // MARK: - Панель раскрытой папки (D17)

    /// Внутренние поля панели по вертикали, в точках.
    ///
    /// Горизонтально содержимое панели полей не добавляет: ярлыки встают в те
    /// же колонки, что и плитки рабочего стола (панель уже ограничена полями
    /// раскладки). Поля заголовка — по ``panelPadding`` с каждой стороны.
    static let panelPadding: CGFloat = 12

    /// Высота строки заголовка панели в точках (одна строка Dynamic Type).
    static let panelHeaderHeight: CGFloat = 44

    /// Зазор между заголовком и сеткой содержимого панели в точках.
    static let panelHeaderSpacing: CGFloat = 8

    /// Зазор между ячейками сетки содержимого панели в точках.
    ///
    /// Совпадает с зазором сетки рабочего стола (`itemSpacing` раскладки по
    /// умолчанию), поэтому ярлыки панели встают в те же колонки, что и плитки
    /// под панелью.
    static let panelContentSpacing: CGFloat = 8

    /// Сторона ярлыка панели раскрытой папки в точках (D17, E7).
    ///
    /// Ярлык в панели — та же плитка small, что и на рабочем столе, поэтому его
    /// сторона считается **той же формулой юнита**, что у сетки
    /// (``unit(screenWidth:columns:gaps:)``):
    ///
    /// `юнит = (ширина − зазор × (N − 1)) / N`.
    ///
    /// Доступной шириной служит вся ширина панели, которая уже равна ширине
    /// контента сетки (без внешних полей раскладки), а зазор —
    /// ``panelContentSpacing``. Горизонтальных полей панель не добавляет, иначе
    /// ярлык стал бы меньше плитки 1×1 и разъехался бы с колонками сетки.
    ///
    /// - Parameters:
    ///   - width: Полная ширина панели в точках (ширина контента сетки).
    ///   - columns: Число колонок сетки содержимого, больше нуля.
    /// - Returns: Сторона квадратного ярлыка в точках или `0` для вырожденной
    ///   геометрии.
    static func panelTileSide(width: CGFloat, columns: Int) -> CGFloat {
        unit(screenWidth: width, columns: columns, gaps: panelContentSpacing)
    }

    /// Высота полноширинной панели раскрытой папки в точках (D17, E7.1).
    ///
    /// Панель состоит из строки заголовка и квадратной сетки содержимого:
    ///
    /// - внешние поля сверху и снизу — по 12 pt (`panelPadding`);
    /// - заголовок — 44 pt: высота фиксирована, потому что заголовок занимает
    ///   ровно одну строку;
    /// - зазор между заголовком и сеткой — 8 pt;
    /// - ярлыки содержимого квадратные, их сторона равна юниту сетки
    ///   (``panelTileSide(width:columns:)``), зазоры между строками — 8 pt;
    /// - по горизонтали ярлыки занимают всю ширину панели: тот же юнит и тот же
    ///   зазор, что у сетки, дают ровно `columns` колонок без остатка.
    ///
    /// Итоговая формула (строки — `ceil(count / columns)`):
    ///
    /// `высота = padding × 2 + заголовок + зазор + строки × юнит +
    /// (строки − 1) × зазор`.
    ///
    /// Формула обязана совпадать с метриками `TesseraFolderPanelCell`: ячейка
    /// раскладывает содержимое по этим же числам, поэтому высота панели точно
    /// вмещает последнюю строку ярлыков.
    ///
    /// Метод не зависит от модели ярлыка: раскладка передаёт только число
    /// ярлыков папки (``panelHeight(tileCount:width:columns:)``), чтобы не
    /// удерживать `TileFolder` с замыканиями и картинками.
    ///
    /// Вырожденная геометрия (нечисловая/неположительная ширина, ширина, где
    /// зазоры съедают всё место, `columns <= 0`) даёт `0`: панель без высоты,
    /// как и плитка без места.
    ///
    /// - Parameters:
    ///   - tileCount: Число ярлыков в сетке содержимого панели; отрицательное
    ///     трактуется как 0.
    ///   - width: Полная ширина панели в точках (ширина контента сетки без
    ///     внешних полей раскладки).
    ///   - columns: Число колонок сетки содержимого панели, больше нуля.
    /// - Returns: Высота панели в точках.
    static func panelHeight(tileCount: Int, width: CGFloat, columns: Int) -> CGFloat {
        guard columns > 0, width.isFinite, width > 0 else { return 0 }

        let columnCount = max(1, columns)
        let side = panelTileSide(width: width, columns: columnCount)
        guard side.isFinite, side > 0 else { return 0 }

        let count = max(0, tileCount)
        let rows = count == 0 ? 0 : (count + columnCount - 1) / columnCount
        let headerHeight = panelPadding * 2 + panelHeaderHeight

        guard rows > 0 else { return headerHeight }

        let contentHeight = CGFloat(rows) * side + CGFloat(rows - 1) * panelContentSpacing
        return headerHeight + panelHeaderSpacing + contentHeight
    }

    /// Ужимает след плитки под узкую сетку, не меняя модель (D15).
    ///
    /// D15 рассчитан на 4 колонки; при меньшем числе колонок широкая плитка
    /// не помещается. Вместо пропуска плитки (он сдвинул бы соответствие
    /// «индекс → элемент») берётся ближайший меньший размер: 2×2 при двух-трёх
    /// колонках и 1×1 при одной. Это деградация геометрии, а не модели:
    /// `TileSize` ярлыка в `TileStore` не меняется.
    ///
    /// - Parameters:
    ///   - size: Запрошенный размер плитки.
    ///   - columns: Число колонок сетки.
    /// - Returns: Размер, который заведомо помещается в сетку.
    static func fittingSize(_ size: TileSize, columns: Int) -> TileSize {
        guard columns > 0 else { return size }
        guard size.unitColumns > columns else { return size }
        return columns >= 2 ? .medium : .small
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

    /// Снимает отметку занятости с прямоугольника (E8.5).
    ///
    /// Нужно схлопыванию: плитка временно «поднимается» с сетки, чтобы её
    /// собственные юниты не мешали поиску более ранней позиции.
    private static func unmarkOccupied(
        _ grid: inout [[Bool]],
        column: Int,
        row: Int,
        width: Int,
        height: Int
    ) {
        for currentRow in row..<(row + height) {
            for currentColumn in column..<(column + width) {
                grid[currentRow][currentColumn] = false
            }
        }
    }

    /// Ищет самую раннюю свободную позицию, которая идёт **раньше** текущей
    /// (E8.5).
    ///
    /// Обход тот же, что у якорной упаковки: сверху вниз, слева направо. Строки
    /// выше проверяются целиком — сдвиг вверх допустим в любую колонку; в
    /// собственной строке — только колонки левее текущей. Позиция-источник в
    /// проверку не входит: вызывающий уже снял прямоугольник с сетки.
    ///
    /// Вызывающий обязан держать в матрице не меньше `row + height` строк:
    /// схлопывание строит её по последней занятой строке раскладки, а это не
    /// меньше любой позиции слота.
    ///
    /// - Parameters:
    ///   - grid: Занятость сетки без проверяемой плитки.
    ///   - column: Текущая колонка плитки.
    ///   - row: Текущая строка плитки.
    ///   - width: Ширина следа плитки в юнитах.
    ///   - height: Высота следа плитки в юнитах.
    ///   - columns: Число колонок сетки.
    /// - Returns: Колонка и строка более ранней позиции или `nil`.
    private static func firstEarlierFreePosition(
        in grid: [[Bool]],
        column: Int,
        row: Int,
        width: Int,
        height: Int,
        columns: Int
    ) -> (column: Int, row: Int)? {
        guard width <= columns else { return nil }

        for currentRow in 0...row {
            let lastColumn = currentRow == row ? column - 1 : columns - width
            guard lastColumn >= 0 else { continue }

            for currentColumn in 0...lastColumn {
                if isFree(
                    in: grid,
                    column: currentColumn,
                    row: currentRow,
                    width: width,
                    height: height
                ) {
                    return (column: currentColumn, row: currentRow)
                }
            }
        }
        return nil
    }
}

#if canImport(UIKit)

/// Панель раскрытой папки: чистые функции места и сдвига (D17, E7).
///
/// Раскрытие папки в WP-стиле (D17) вставляет панель
/// ``TileGridItem/folderContent(_:)`` **после** строки, в которой заканчивается
/// плитка ``TileGridItem/folder(_:)``. Сама плитка папки остаётся на своём месте
/// и видна всё время, пока папка раскрыта: панель — отдельная полноширинная
/// строка под ней, а не замена плитки. Панель растягивается на всю ширину сетки
/// и растёт вниз до ``panelHeight(for:width:columns:)``; всё, что начинается
/// ниже строки папки, встаёт под панелью — визуально строки сдвигаются вниз на
/// её высоту. Саму геометрию в точках собирает
/// `TesseraTileCollectionViewLayout`.
///
/// Функции этого расширения ничего не знают о UICollectionView: они по модели,
/// числу колонок и высоте панели отвечают на вопросы — на каком индекс массива
/// вставить панель, есть ли под панелью что сдвигать и какой высоты будет
/// панель.
///
/// Размещение считается той же строго компактной упаковкой (E8.5), что и
/// обычная раскладка: функции вызывают ``pack(items:columns:unit:)`` с юнитом 1.
/// Юнитные
/// координаты не зависят от масштаба, поэтому единичный юнит даёт ровно те же
/// строки и колонки, что и реальная геометрия в точках.
extension TileLayoutEngine {

    /// Геометрия раскрытия в юнитных координатах.
    ///
    /// `slots` — слоты всех элементов набора, кроме самой панели (панель не
    /// упаковывается как плитка); `folderEndRow` — первая строка, идущая
    /// **после** папки: с неё начинается полноширинная строка панели.
    private struct FolderPanelGeometry {

        /// Слоты элементов по идентификатору.
        var slots: [AnyHashable: TileLayoutSlot]

        /// Первая строка после папки (номер строки, идущей сразу за её
        /// последней строкой): с неё начинается панель.
        var folderEndRow: Int

        /// Индекс папки в исходном массиве элементов.
        var folderIndex: Int
    }

    /// Считает юнитные координаты элементов и первую строку после папки.
    ///
    /// - Parameters:
    ///   - items: Элементы сетки в порядке отображения.
    ///   - columns: Число колонок, больше нуля.
    ///   - expandedFolderID: Идентификатор раскрытой папки.
    /// - Returns: Геометрия либо `nil`, если папки в наборе нет.
    private static func folderPanelGeometry(
        items: [TileGridItem],
        columns: Int,
        expandedFolderID: AnyHashable
    ) -> FolderPanelGeometry? {
        guard columns > 0 else { return nil }

        guard let folderIndex = items.firstIndex(where: { item in
            guard case .folder(let folder) = item else { return false }
            return folder.id == expandedFolderID
        }) else {
            return nil
        }

        // Панель в упаковку не входит: она не плитка, а отдельная строка под
        // папкой, высота которой считается в точках, а не в юнитах.
        let packItems: [(id: AnyHashable, size: TileSize)] = items.compactMap { item in
            guard !item.isFolderPanel else { return nil }
            return (id: item.id, size: fittingSize(item.size, columns: columns))
        }
        let packedSlots = pack(items: packItems, columns: columns, unit: 1)

        var slots: [AnyHashable: TileLayoutSlot] = [:]
        slots.reserveCapacity(packedSlots.count)
        for slot in packedSlots {
            slots[slot.id] = slot
        }

        guard let folderSlot = slots[expandedFolderID] else { return nil }

        return FolderPanelGeometry(
            slots: slots,
            folderEndRow: folderSlot.row + folderSlot.unitRows,
            folderIndex: folderIndex
        )
    }

    /// Индекс массива, с которого панель вставляется в набор элементов (D17, E7).
    ///
    /// Панель — отдельный элемент набора, а не замена плитки: плитка папки
    /// остаётся на своём индексе, поэтому `displayItems.count == items.count + 1`.
    /// Вставлять панель логично сразу после плитки папки: она идёт следующей в
    /// порядке элементов, а **геометрически** раскладка ставит её полноширинной
    /// строкой сразу после строки, в которой заканчивается папка (см.
    /// ``rowsBelowOffset(items:columns:expandedFolderID:panelHeight:)`` и
    /// `TesseraTileCollectionViewLayout`).
    ///
    /// Число колонок здесь не нужно: смещение панели в массиве не зависит от
    /// раскладки, а строку панели считает геометрия вью-слоя. Так сигнатура
    /// остаётся чистой и тестируемой без UI.
    ///
    /// - Parameters:
    ///   - items: Базовые элементы сетки в порядке отображения (снимок
    ///     `TileStore`, без панели).
    ///   - expandedFolderID: Идентификатор раскрытой папки; `nil` — раскрытия нет.
    /// - Returns: Индекс для вставки `.folderContent(folder)` в массив (индекс
    ///   плитки-папки + 1) либо `nil`, если такой папки нет или панель уже
    ///   присутствует в наборе.
    public static func folderPanelInsertionIndex(
        items: [TileGridItem],
        expandedFolderID: AnyHashable?
    ) -> Int? {
        guard let expandedFolderID else { return nil }
        guard !items.contains(where: { $0.isFolderPanel }) else { return nil }
        guard let folderIndex = items.firstIndex(where: { item in
            guard case .folder(let folder) = item else { return false }
            return folder.id == expandedFolderID
        }) else {
            return nil
        }
        return folderIndex + 1
    }

    /// Отступ строк под панелью от её верхнего края в точках (D17, E7).
    ///
    /// Панель встаёт полноширинной строкой сразу после строки, в которой
    /// заканчивается плитка папки, и растёт вниз. Всё, что **начинается** ниже
    /// этой строки, оказывается под панелью, поэтому первый ряд под панелью
    /// начинается ровно на её высоту (плюс обычный зазор сетки) от верхнего края
    /// панели. Элементы, стоящие в тех же строках, что и папка (например, small
    /// справа от 2×2-папки), остаются на месте: панель начинается ниже них.
    ///
    /// Функция нужна тестам E7.4 и хосту, который считает прокрутку: сама
    /// раскладка кладёт элементы под панель тем же правилом. Если под панелью
    /// ничего нет (папка в последней строке), сдвиг `0`; если панель уже
    /// есть в наборе, тоже `0`: её влияние уже учтено раскладкой.
    ///
    /// - Parameters:
    ///   - items: Базовые элементы сетки в порядке отображения (без панели).
    ///   - columns: Число колонок сетки, больше нуля.
    ///   - expandedFolderID: Идентификатор раскрытой папки.
    ///   - panelHeight: Высота панели в точках, вычисленная
    ///     ``panelHeight(for:width:columns:)``.
    /// - Returns: `panelHeight`, если под панелью есть что сдвигать, иначе `0`.
    public static func rowsBelowOffset(
        items: [TileGridItem],
        columns: Int,
        expandedFolderID: AnyHashable?,
        panelHeight: CGFloat
    ) -> CGFloat {
        guard panelHeight.isFinite, panelHeight > 0 else { return 0 }
        guard columns > 0, let expandedFolderID else { return 0 }
        guard !items.contains(where: { $0.isFolderPanel }) else { return 0 }
        guard let geometry = folderPanelGeometry(
            items: items,
            columns: columns,
            expandedFolderID: expandedFolderID
        ) else {
            return 0
        }

        // Под панель уходит всё, что начинается со строки сразу после папки.
        // Саму папку не считаем: панель встаёт под ней, а не вместо неё.
        for (index, item) in items.enumerated() where !item.isFolderPanel {
            guard index != geometry.folderIndex,
                  let slot = geometry.slots[item.id] else { continue }
            if slot.row >= geometry.folderEndRow {
                return panelHeight
            }
        }
        return 0
    }

    /// Высота полноширинной панели раскрытой папки в точках (D17, E7.1).
    ///
    /// Складывает строку заголовка и сетку содержимого папки; константы и
    /// формула описаны в ``panelHeight(tileCount:width:columns:)``. Число
    /// колонок — это число колонок сетки содержимого панели: раскладка передаёт
    /// сюда число колонок рабочего стола (по §3 — 4).
    ///
    /// - Parameters:
    ///   - folder: Раскрытая папка.
    ///   - width: Полная ширина панели в точках (ширина контента сетки).
    ///   - columns: Число колонок сетки содержимого, больше нуля.
    /// - Returns: Высота панели в точках; `0` для вырожденной геометрии.
    public static func panelHeight(
        for folder: TileFolder,
        width: CGFloat,
        columns: Int
    ) -> CGFloat {
        panelHeight(tileCount: folder.tiles.count, width: width, columns: columns)
    }
}

#endif
