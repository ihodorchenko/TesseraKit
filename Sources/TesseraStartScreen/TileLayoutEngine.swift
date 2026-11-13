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
// панели после полосы папки (E10.1), отступа строк под панелью и её высоты — в
// конце файла. E10.1 — пиксельное выравнивание юнита и геометрия сетки
// (``TileLayoutEngine/gridMetrics(contentWidth:columns:spacing:scale:)``).
// Основная часть движка остаётся без UIKit и без состояния.
//
// E14 — размещение по координатам (`TileLayoutEngine+Placement.swift`): превью
// drag, resize, вставка, схлопывание пустых строк работают над набором
// `TilePlacedItem` (идентификатор, размер, ячейка). ``pack(items:columns:unit:)``
// остаётся упаковкой по порядку: откат раскладки сетки без таблицы ячеек (E14.3),
// миграция v1 → v2, проекция при другой ширине холста (D32) и раскладка первого
// запуска (`packCompact`).
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
    /// пересобирают через ``TileLayoutEngine/pack(items:columns:unit:)`` с новым
    /// юнитом — юнитные координаты при этом не меняются.
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

    /// Число колонок сетки по умолчанию — 6 малых колонок (D26).
    ///
    /// Как в Windows 10 Mobile (docs/W10M-STARTSCREEN.md §2): три средние плитки
    /// в ряд, широкая занимает 4 колонки из 6, большая — 4×4. Единственный
    /// источник умолчания для ``TesseraTileGridView/columns`` и для методов
    /// ``TileStore`` без сетки; хост может задать своё `columns`.
    public static let defaultColumns = 6

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

    // MARK: - Пиксельное выравнивание (E10.1)

    /// Размер юнита, выровненный вниз по пиксельной сетке экрана (E10.1).
    ///
    /// Формула та же, что у ``unit(screenWidth:columns:gaps:)``, но результат
    /// округляется **вниз** до кратного `1 / scale`: при ширине 393 pt
    /// (контент 361 pt, зазор 8) «сырой» юнит 84.25 pt даёт дробные пиксели и
    /// размытые края плиток, выровненный — 84 pt на 3× и 84 pt на 2×. Остаток
    /// ширины раскладка делит поровну на поля (сетка центрируется, см.
    /// ``gridMetrics(contentWidth:columns:spacing:scale:)``).
    ///
    /// `scale <= 0` или нечисловой масштаб — выравнивания нет, результат равен
    /// ``unit(screenWidth:columns:gaps:)``.
    ///
    /// - Parameters:
    ///   - screenWidth: Доступная ширина сетки в точках (без внешних полей).
    ///   - columns: Число колонок, больше нуля.
    ///   - gaps: Зазор между соседними колонками в точках.
    ///   - scale: Масштаб экрана (`displayScale`): пикселей в точке.
    /// - Returns: Юнит в точках, кратный `1 / scale`, или `0` для вырожденной
    ///   геометрии.
    public static func unit(
        screenWidth: CGFloat,
        columns: Int,
        gaps: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        pixelFloor(unit(screenWidth: screenWidth, columns: columns, gaps: gaps), scale: scale)
    }

    /// Допуск округления по пиксельной сетке: гасит ошибку плавающей точки
    /// (`84 × 3` может прийти как `251.99999999`).
    private static let pixelEpsilon: CGFloat = 1e-6

    /// Выравнивает масштаб: положительный и конечный — как есть, иначе `0`
    /// («не выравнивать»).
    private static func alignmentScale(_ scale: CGFloat) -> CGFloat {
        scale.isFinite && scale > 0 ? scale : 0
    }

    /// Округляет значение вниз до кратного `1 / scale` (E10.1).
    ///
    /// - Parameters:
    ///   - value: Длина в точках.
    ///   - scale: Масштаб экрана; `<= 0` — значение не меняется.
    /// - Returns: Выровненная длина.
    static func pixelFloor(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let scale = alignmentScale(scale)
        guard scale > 0, value.isFinite else { return value }
        return (value * scale + pixelEpsilon).rounded(.down) / scale
    }

    /// Округляет значение к ближайшему кратному `1 / scale` (E10.1).
    ///
    /// - Parameters:
    ///   - value: Длина или координата в точках.
    ///   - scale: Масштаб экрана; `<= 0` — значение не меняется.
    /// - Returns: Выровненное значение.
    static func pixelRound(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let scale = alignmentScale(scale)
        guard scale > 0, value.isFinite else { return value }
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    /// Горизонтальная геометрия сетки в точках (E10.1).
    ///
    /// Одна и та же для плиток рабочего стола и для ярлыков панели раскрытой
    /// папки: обе стороны считают её по ширине контента, зазору и масштабу,
    /// поэтому колонки совпадают до пикселя.
    struct GridMetrics: Equatable {

        /// Число колонок.
        var columns: Int

        /// Юнит в точках (выровнен по пикселям, если масштаб задан).
        var unit: CGFloat

        /// Зазор между юнитами в точках (санитизирован и выровнен).
        var spacing: CGFloat

        /// Отступ сетки от начала ширины контента: половина остатка после
        /// выравнивания юнита (сетка центрируется).
        var leading: CGFloat

        /// Ширина, которую занимают `columns` юнитов с зазорами.
        var width: CGFloat

        /// Смещение колонки от начала ширины контента в LTR-координатах.
        ///
        /// - Parameter column: Номер колонки, с нуля.
        /// - Returns: Левый край колонки в точках.
        func columnOffset(_ column: Int) -> CGFloat {
            leading + CGFloat(column) * (unit + spacing)
        }
    }

    /// Считает горизонтальную геометрию сетки с пиксельным выравниванием
    /// (E10.1).
    ///
    /// 1. Зазор санитизируется (отрицательный и нечисловой — 0) и округляется
    ///    к ближайшему пикселю.
    /// 2. Юнит — ``unit(screenWidth:columns:gaps:scale:)``: формула §3 с
    ///    округлением вниз до пикселя.
    /// 3. Остаток ширины (`contentWidth − columns × юнит − зазоры`) делится
    ///    поровну на поля: левому полю — половина, округлённая вниз до пикселя,
    ///    правому — всё остальное.
    ///
    /// Без масштаба (`scale <= 0`) выравнивания нет: юнит — точная формула §3,
    /// остаток нулевой, `leading == 0`.
    ///
    /// - Parameters:
    ///   - contentWidth: Ширина контента сетки (без внешних полей).
    ///   - columns: Число колонок, больше нуля.
    ///   - spacing: Зазор между юнитами в точках.
    ///   - scale: Масштаб экрана; `<= 0` — не выравнивать.
    /// - Returns: Геометрия или `nil` для вырожденной ширины/колонок.
    static func gridMetrics(
        contentWidth: CGFloat,
        columns: Int,
        spacing: CGFloat,
        scale: CGFloat
    ) -> GridMetrics? {
        guard columns > 0, contentWidth.isFinite, contentWidth > 0 else { return nil }

        let alignedSpacing = pixelRound(spacing.isFinite ? max(spacing, 0) : 0, scale: scale)
        let alignedUnit = unit(
            screenWidth: contentWidth,
            columns: columns,
            gaps: alignedSpacing,
            scale: scale
        )
        guard alignedUnit.isFinite, alignedUnit > 0 else { return nil }

        let width = CGFloat(columns) * alignedUnit + CGFloat(columns - 1) * alignedSpacing
        let leading: CGFloat
        if alignmentScale(scale) > 0 {
            leading = pixelFloor(max(0, contentWidth - width) / 2, scale: scale)
        } else {
            leading = 0
        }

        return GridMetrics(
            columns: columns,
            unit: alignedUnit,
            spacing: alignedSpacing,
            leading: leading,
            width: width
        )
    }

    // MARK: - Полоса раскрытой папки (E10.1)

    /// Нижняя граница «полосы папки» в юнитных строках (E10.1, D17).
    ///
    /// Панель раскрытой папки — полноширинная строка, поэтому она не может
    /// встать сразу под последней строкой папки, если рядом стоит плитка,
    /// которая начинается в строках папки, а заканчивается ниже (например,
    /// 2×2-ярлык со строки 1 при 2×2-папке в строках 0–1): панель перекрыла бы
    /// её нижнюю половину. Полоса начинается с `[folder.row, folder.row +
    /// unitRows)` и расширяет нижнюю границу до `max(row + unitRows)` всех
    /// плиток, пересекающих полосу, итеративно до неподвижной точки (расширение
    /// может зацепить следующую плитку).
    ///
    /// На неподвижной точке разбиение «остаётся / уходит под панель» по
    /// верхней строке `slot.row < bandEnd` точное: плитка с `row < bandEnd`
    /// либо целиком выше полосы, либо пересекает её — и тогда уже целиком в
    /// ней.
    ///
    /// - Parameters:
    ///   - folderSlot: Слот плитки раскрытой папки.
    ///   - slots: Слоты всех плиток раскладки (папка может входить).
    /// - Returns: Первая строка после полосы: с неё начинается панель.
    static func folderBandEndRow(for folderSlot: TileLayoutSlot, in slots: [TileLayoutSlot]) -> Int {
        let start = folderSlot.row
        var end = folderSlot.row + folderSlot.unitRows
        var changed = true

        while changed {
            changed = false
            for slot in slots where slot.row < end && slot.row + slot.unitRows > start {
                let bottom = slot.row + slot.unitRows
                if bottom > end {
                    end = bottom
                    changed = true
                }
            }
        }
        return end
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
    ///   - columns: Число колонок, больше нуля (для всех размеров D15 нужно ≥ 4; по умолчанию — ``defaultColumns``).
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

    /// Зазор между ячейками сетки содержимого панели по умолчанию, в точках.
    ///
    /// Совпадает с `itemSpacing` раскладки по умолчанию. Раскладка и ячейка
    /// панели (E10.1) берут фактический зазор сетки (`itemSpacing`), чтобы
    /// ярлыки панели вставали в те же колонки, что и плитки под панелью; это
    /// значение — только для устаревших входов без зазора
    /// (``panelHeight(for:width:columns:)``, ``panelHeight(tileCount:width:columns:)``).
    static let panelContentSpacing: CGFloat = 8

    /// Высота полноширинной панели раскрытой папки в точках с зазором по
    /// умолчанию и без пиксельного выравнивания (D17, E7.1).
    ///
    /// Устаревший вход: равен
    /// ``panelHeight(tileCount:width:columns:spacing:scale:)`` с зазором
    /// ``panelContentSpacing`` и `scale == 0`.
    ///
    /// - Parameters:
    ///   - tileCount: Число ярлыков в сетке содержимого панели; отрицательное
    ///     трактуется как 0.
    ///   - width: Полная ширина панели в точках (ширина контента сетки).
    ///   - columns: Число колонок сетки содержимого панели, больше нуля.
    /// - Returns: Высота панели в точках.
    static func panelHeight(tileCount: Int, width: CGFloat, columns: Int) -> CGFloat {
        panelHeight(
            tileCount: tileCount,
            width: width,
            columns: columns,
            spacing: panelContentSpacing,
            scale: 0
        )
    }

    /// Высота полноширинной панели раскрытой папки в точках (D17, E7.1, E10.1).
    ///
    /// Панель состоит из строки заголовка и квадратной сетки содержимого:
    ///
    /// - внешние поля сверху и снизу — по 12 pt (`panelPadding`);
    /// - заголовок — 44 pt: высота фиксирована, потому что заголовок занимает
    ///   ровно одну строку;
    /// - зазор между заголовком и сеткой — 8 pt (`panelHeaderSpacing`);
    /// - ярлыки содержимого квадратные: их сторона и зазоры между ними — юнит и
    ///   зазор **сетки рабочего стола** с тем же пиксельным выравниванием
    ///   (``gridMetrics(contentWidth:columns:spacing:scale:)``), поэтому ярлык
    ///   панели — та же плитка 1×1 в тех же колонках, что и плитки под панелью.
    ///
    /// Итоговая формула (строки — `ceil(count / columns)`):
    ///
    /// `высота = padding × 2 + заголовок + зазор заголовка + строки × юнит +
    /// (строки − 1) × зазор сетки`.
    ///
    /// Формула обязана совпадать с метриками `TesseraFolderPanelCell`: ячейка
    /// раскладывает содержимое по этим же числам, поэтому высота панели точно
    /// вмещает последнюю строку ярлыков.
    ///
    /// Вырожденная геометрия (нечисловая/неположительная ширина, ширина, где
    /// зазоры съедают всё место, `columns <= 0`) даёт `0`: панель без высоты,
    /// как и плитка без места.
    ///
    /// - Parameters:
    ///   - tileCount: Число ярлыков; отрицательное трактуется как 0.
    ///   - width: Полная ширина панели в точках (ширина контента сетки без
    ///     внешних полей раскладки).
    ///   - columns: Число колонок сетки содержимого панели, больше нуля.
    ///   - spacing: Зазор сетки рабочего стола (`itemSpacing`).
    ///   - scale: Масштаб экрана; `<= 0` — без пиксельного выравнивания.
    /// - Returns: Высота панели в точках.
    static func panelHeight(
        tileCount: Int,
        width: CGFloat,
        columns: Int,
        spacing: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        guard let metrics = gridMetrics(
            contentWidth: width,
            columns: columns,
            spacing: spacing,
            scale: scale
        ) else {
            return 0
        }

        let count = max(0, tileCount)
        let rows = count == 0 ? 0 : (count + columns - 1) / columns
        let headerHeight = panelPadding * 2 + panelHeaderHeight

        guard rows > 0 else { return pixelRound(headerHeight, scale: scale) }

        let contentHeight = CGFloat(rows) * metrics.unit + CGFloat(rows - 1) * metrics.spacing
        return pixelRound(headerHeight + panelHeaderSpacing + contentHeight, scale: scale)
    }

    /// Ужимает след плитки под узкую сетку, не меняя модель (D15).
    ///
    /// D15 рассчитан минимум на 4 колонки (по умолчанию 6, D26); при меньшем
    /// числе колонок широкая плитка не помещается. Вместо пропуска плитки (он сдвинул бы соответствие
    /// «индекс → элемент») берётся ближайший меньший размер: 2×2 при двух-трёх
    /// колонках и 1×1 при одной. Это деградация геометрии, а не модели:
    /// `TileSize` ярлыка в `TileStore` не меняется.
    ///
    /// Связь с ограничением колонки (E14.2): след плитки на сетке — всегда
    /// `fittingSize`, поэтому `column + ширина ≤ columns` достижимо для любой
    /// ячейки: ``clamped(cell:size:columns:)`` сдвигает колонку влево именно по
    /// ужатой ширине. При 6 колонках (D26) ужатия нет — все четыре размера D15
    /// (максимум 4 колонки) помещаются как есть; ужатие работает только при
    /// `columns < 4`. Функция зависит только от ширины и не меняет поведения.
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
/// ``TileGridItem/folderContent(_:)`` **после полосы папки** — строк плитки
/// ``TileGridItem/folder(_:)``, расширенных вниз на плитки, которые начинаются
/// в этих строках и заканчиваются ниже (``folderBandEndRow(for:in:)``, E10.1).
/// Сама плитка папки остаётся на своём месте и видна всё время, пока папка
/// раскрыта: панель — отдельная полноширинная строка под полосой, а не замена
/// плитки. Панель растягивается на всю ширину сетки и растёт вниз до
/// ``panelHeight(for:width:columns:spacing:scale:)``; всё, что начинается ниже
/// полосы, встаёт под панелью — визуально строки сдвигаются вниз на её высоту и
/// зазор сетки. Саму геометрию в точках собирает
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
    /// упаковывается как плитка); `bandEndRow` — первая строка после «полосы
    /// папки» (``folderBandEndRow(for:in:)``): с неё начинается
    /// полноширинная строка панели.
    private struct FolderPanelGeometry {

        /// Слоты элементов по идентификатору.
        var slots: [AnyHashable: TileLayoutSlot]

        /// Первая строка после полосы папки (E10.1): с неё начинается панель.
        /// Всё, что начинается выше, остаётся на месте; всё, что начинается с
        /// неё и ниже, уходит под панель.
        var bandEndRow: Int

        /// Индекс папки в исходном массиве элементов.
        var folderIndex: Int
    }

    /// Считает юнитные координаты элементов и нижнюю границу полосы папки.
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
            bandEndRow: folderBandEndRow(for: folderSlot, in: packedSlots),
            folderIndex: folderIndex
        )
    }

    /// Индекс массива для панели без учёта раскладки (D17, E7).
    ///
    /// Устаревший вход: панель встаёт сразу после плитки папки (индекс папки
    /// + 1), соседи по полосе папки (E10.1) не учитываются, поэтому порядок
    /// элементов может не совпасть с визуальным. Сетка пользуется
    /// ``folderPanelInsertionIndex(items:columns:expandedFolderID:)``.
    ///
    /// - Parameters:
    ///   - items: Базовые элементы сетки в порядке отображения (снимок
    ///     `TileStore`, без панели).
    ///   - expandedFolderID: Идентификатор раскрытой папки; `nil` — раскрытия нет.
    /// - Returns: Индекс плитки-папки + 1 либо `nil`, если такой папки нет или
    ///   панель уже присутствует в наборе.
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

    /// Индекс массива, с которого панель вставляется в набор элементов
    /// (D17, E7, E10.1).
    ///
    /// Панель — отдельный элемент набора, а не замена плитки: плитка папки
    /// остаётся на своём индексе, поэтому `displayItems.count == items.count + 1`.
    /// Геометрически панель встаёт полноширинной строкой под **полосой папки**
    /// (``folderBandEndRow(for:in:)``): плитки, которые начинаются в строках
    /// папки и заканчиваются ниже, остаются над панелью вместе с папкой. Чтобы
    /// порядок элементов совпадал с визуальным (VoiceOver, индексы коллекции),
    /// панель вставляется после **последнего** по массиву элемента, который
    /// остаётся над панелью (`row < bandEnd`), — но не раньше, чем сразу после
    /// плитки папки.
    ///
    /// Пример (4 колонки): `[папка 2×2, small, small, ярлык 2×2]` — ярлык
    /// стоит в строках 1–2, полоса — строки 0–2, индекс вставки 4 (после
    /// ярлыка), а не 1.
    ///
    /// - Parameters:
    ///   - items: Базовые элементы сетки в порядке отображения (снимок
    ///     `TileStore`, без панели).
    ///   - columns: Число колонок сетки. При `columns <= 0` геометрии нет, и
    ///     результат совпадает с ``folderPanelInsertionIndex(items:expandedFolderID:)``.
    ///   - expandedFolderID: Идентификатор раскрытой папки; `nil` — раскрытия нет.
    /// - Returns: Индекс для вставки `.folderContent(folder)` либо `nil`, если
    ///   такой папки нет или панель уже присутствует в наборе.
    public static func folderPanelInsertionIndex(
        items: [TileGridItem],
        columns: Int,
        expandedFolderID: AnyHashable?
    ) -> Int? {
        guard let fallback = folderPanelInsertionIndex(
            items: items,
            expandedFolderID: expandedFolderID
        ) else {
            return nil
        }
        guard let expandedFolderID,
              let geometry = folderPanelGeometry(
                  items: items,
                  columns: columns,
                  expandedFolderID: expandedFolderID
              ) else {
            return fallback
        }

        var lastIndexAbovePanel = geometry.folderIndex
        for (index, item) in items.enumerated() {
            guard let slot = geometry.slots[item.id],
                  slot.row < geometry.bandEndRow else { continue }
            lastIndexAbovePanel = max(lastIndexAbovePanel, index)
        }
        return lastIndexAbovePanel + 1
    }

    /// Отступ строк под панелью от её верхнего края в точках (D17, E7, E10.1).
    ///
    /// Панель встаёт полноширинной строкой сразу после **полосы папки**
    /// (``folderBandEndRow(for:in:)``) и растёт вниз. Всё, что **начинается**
    /// с этой строки и ниже, раскладка кладёт под панель: первый ряд под
    /// панелью начинается на `panelHeight + spacing` от её верхнего края —
    /// ровно на столько сдвигаются вниз строки, которые до раскрытия
    /// начинались на месте панели. Элементы полосы (например, small справа от
    /// 2×2-папки или 2×2-ярлык, начинающийся в строках папки) остаются на
    /// месте: панель начинается ниже них.
    ///
    /// Функция нужна тестам E7.4 и хосту, который считает прокрутку: сама
    /// раскладка кладёт элементы под панель тем же правилом. Если под панелью
    /// ничего нет (полоса папки — последняя), сдвиг `0`; если панель уже
    /// есть в наборе, тоже `0`: её влияние уже учтено раскладкой.
    ///
    /// - Parameters:
    ///   - items: Базовые элементы сетки в порядке отображения (без панели).
    ///   - columns: Число колонок сетки, больше нуля.
    ///   - expandedFolderID: Идентификатор раскрытой папки.
    ///   - panelHeight: Высота панели в точках, вычисленная
    ///     ``panelHeight(for:width:columns:spacing:scale:)``.
    ///   - spacing: Зазор сетки (`itemSpacing`), по умолчанию 8 pt — зазор
    ///     раскладки по умолчанию; отрицательный и нечисловой — 0.
    /// - Returns: `panelHeight + spacing`, если под панелью есть что сдвигать,
    ///   иначе `0`.
    public static func rowsBelowOffset(
        items: [TileGridItem],
        columns: Int,
        expandedFolderID: AnyHashable?,
        panelHeight: CGFloat,
        spacing: CGFloat = 8
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

        // Под панель уходит всё, что начинается со строки сразу после полосы
        // папки. Саму папку не считаем: панель встаёт под ней, а не вместо неё.
        for (index, item) in items.enumerated() where !item.isFolderPanel {
            guard index != geometry.folderIndex,
                  let slot = geometry.slots[item.id] else { continue }
            if slot.row >= geometry.bandEndRow {
                return panelHeight + (spacing.isFinite ? max(spacing, 0) : 0)
            }
        }
        return 0
    }

    // MARK: Панель папки на размещениях по координатам (E14.2)

    /// Геометрия раскрытия по уже посчитанным слотам (E14.2).
    ///
    /// В отличие от ``folderPanelGeometry(items:columns:expandedFolderID:)`` ничего
    /// не упаковывает: дыры на сетке сохраняются, панель не делает репак — строки
    /// ниже полосы остаются на своих местах (раскладка сдвигает их вниз на высоту
    /// панели).
    ///
    /// - Parameters:
    ///   - placedSlots: Слоты всех элементов набора без панели, в порядке
    ///     отображения.
    ///   - expandedFolderID: Идентификатор раскрытой папки.
    /// - Returns: Геометрия либо `nil`, если папки среди слотов нет;
    ///   `folderIndex` — индекс папки в `placedSlots`.
    private static func folderPanelGeometry(
        placedSlots: [TileLayoutSlot],
        expandedFolderID: AnyHashable
    ) -> FolderPanelGeometry? {
        guard let folderIndex = placedSlots.firstIndex(where: { $0.id == expandedFolderID }) else {
            return nil
        }

        var byID: [AnyHashable: TileLayoutSlot] = [:]
        byID.reserveCapacity(placedSlots.count)
        for slot in placedSlots {
            byID[slot.id] = slot
        }

        return FolderPanelGeometry(
            slots: byID,
            bandEndRow: folderBandEndRow(for: placedSlots[folderIndex], in: placedSlots),
            folderIndex: folderIndex
        )
    }

    /// Нижняя граница полосы раскрытой папки по набору размещений (E14.2).
    ///
    /// Та же формула, что у ``folderBandEndRow(for:in:)``, но по ячейкам, а не по
    /// упаковке: плитки считаются по ужатым под `columns` размерам, дыры не
    /// заполняются.
    ///
    /// - Parameters:
    ///   - folderID: Идентификатор раскрытой папки.
    ///   - placements: Набор размещений (без панели).
    ///   - columns: Число колонок.
    /// - Returns: Первая строка после полосы либо `nil`, если папки нет в наборе
    ///   или она не помещается в сетку.
    public static func folderBandEndRow(
        forFolder folderID: AnyHashable,
        in placements: [TilePlacedItem],
        columns: Int
    ) -> Int? {
        let placed = slots(placements: placements, columns: columns, unit: 1, fitting: true)
        guard let folderSlot = placed.first(where: { $0.id == folderID }) else { return nil }
        return folderBandEndRow(for: folderSlot, in: placed)
    }

    /// Индекс вставки панели по уже посчитанным слотам (E14.2).
    ///
    /// Правило то же, что у
    /// ``folderPanelInsertionIndex(items:columns:expandedFolderID:)``: панель
    /// встаёт после **последнего** по массиву элемента, который остаётся над
    /// панелью (`row < bandEnd`), но не раньше, чем сразу после папки. Размещение
    /// не пересчитывается — слоты берутся как есть, дыры сохраняются.
    ///
    /// - Parameters:
    ///   - placedSlots: Слоты элементов в порядке отображения, без панели.
    ///   - expandedFolderID: Идентификатор раскрытой папки; `nil` — раскрытия нет.
    /// - Returns: Индекс для вставки панели либо `nil`, если папки среди слотов
    ///   нет.
    public static func folderPanelInsertionIndex(
        placedSlots: [TileLayoutSlot],
        expandedFolderID: AnyHashable?
    ) -> Int? {
        guard let expandedFolderID,
              let geometry = folderPanelGeometry(
                  placedSlots: placedSlots,
                  expandedFolderID: expandedFolderID
              ) else {
            return nil
        }

        var lastIndexAbovePanel = geometry.folderIndex
        for (index, slot) in placedSlots.enumerated() where slot.row < geometry.bandEndRow {
            lastIndexAbovePanel = max(lastIndexAbovePanel, index)
        }
        return lastIndexAbovePanel + 1
    }

    /// Индекс вставки панели по набору размещений (E14.2).
    ///
    /// Порядок элементов — порядок массива `placements`. Обёртка над
    /// ``folderPanelInsertionIndex(placedSlots:expandedFolderID:)``: слоты берутся
    /// с ужатыми под `columns` размерами, репака нет.
    ///
    /// - Parameters:
    ///   - placements: Набор размещений в порядке отображения, без панели.
    ///   - columns: Число колонок.
    ///   - expandedFolderID: Идентификатор раскрытой папки; `nil` — раскрытия нет.
    /// - Returns: Индекс для вставки панели либо `nil`.
    public static func folderPanelInsertionIndex(
        placements: [TilePlacedItem],
        columns: Int,
        expandedFolderID: AnyHashable?
    ) -> Int? {
        folderPanelInsertionIndex(
            placedSlots: slots(placements: placements, columns: columns, unit: 1, fitting: true),
            expandedFolderID: expandedFolderID
        )
    }

    /// Отступ строк под панелью по уже посчитанным слотам (E14.2).
    ///
    /// Семантика ``rowsBelowOffset(items:columns:expandedFolderID:panelHeight:spacing:)``
    /// сохраняется: всё, что **начинается** со строки сразу после полосы папки и
    /// ниже, уходит под панель на `panelHeight + spacing` (дыры между строками
    /// остаются: панель — вставка, а не репак). Если под панелью ничего нет — `0`.
    ///
    /// - Parameters:
    ///   - placedSlots: Слоты элементов в порядке отображения, без панели.
    ///   - expandedFolderID: Идентификатор раскрытой папки.
    ///   - panelHeight: Высота панели в точках.
    ///   - spacing: Зазор сетки (`itemSpacing`); отрицательный и нечисловой — 0.
    /// - Returns: `panelHeight + spacing`, если под панелью есть что сдвигать,
    ///   иначе `0`.
    public static func rowsBelowOffset(
        placedSlots: [TileLayoutSlot],
        expandedFolderID: AnyHashable?,
        panelHeight: CGFloat,
        spacing: CGFloat = 8
    ) -> CGFloat {
        guard panelHeight.isFinite, panelHeight > 0, let expandedFolderID,
              let geometry = folderPanelGeometry(
                  placedSlots: placedSlots,
                  expandedFolderID: expandedFolderID
              ) else {
            return 0
        }

        for (index, slot) in placedSlots.enumerated()
        where index != geometry.folderIndex && slot.row >= geometry.bandEndRow {
            return panelHeight + (spacing.isFinite ? max(spacing, 0) : 0)
        }
        return 0
    }

    /// Отступ строк под панелью по набору размещений (E14.2).
    ///
    /// Обёртка над ``rowsBelowOffset(placedSlots:expandedFolderID:panelHeight:spacing:)``.
    ///
    /// - Parameters:
    ///   - placements: Набор размещений в порядке отображения, без панели.
    ///   - columns: Число колонок.
    ///   - expandedFolderID: Идентификатор раскрытой папки.
    ///   - panelHeight: Высота панели в точках.
    ///   - spacing: Зазор сетки (`itemSpacing`).
    /// - Returns: `panelHeight + spacing`, если под панелью есть что сдвигать,
    ///   иначе `0`.
    public static func rowsBelowOffset(
        placements: [TilePlacedItem],
        columns: Int,
        expandedFolderID: AnyHashable?,
        panelHeight: CGFloat,
        spacing: CGFloat = 8
    ) -> CGFloat {
        rowsBelowOffset(
            placedSlots: slots(placements: placements, columns: columns, unit: 1, fitting: true),
            expandedFolderID: expandedFolderID,
            panelHeight: panelHeight,
            spacing: spacing
        )
    }

    /// Высота полноширинной панели раскрытой папки в точках с зазором по
    /// умолчанию и без пиксельного выравнивания (D17, E7.1).
    ///
    /// Устаревший вход: зазор содержимого — 8 pt (зазор раскладки по
    /// умолчанию), юнит не выравнивается по пикселям. Раскладка сетки считает
    /// высоту по ``panelHeight(for:width:columns:spacing:scale:)`` с
    /// фактическим `itemSpacing` и масштабом экрана.
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

    /// Высота полноширинной панели раскрытой папки в точках (D17, E10.1).
    ///
    /// Ярлыки панели — плитки 1×1 той же сетки: сторона и зазор — юнит и
    /// зазор сетки рабочего стола с пиксельным выравниванием; формула — в
    /// ``panelHeight(tileCount:width:columns:spacing:scale:)``. Число колонок —
    /// число колонок рабочего стола (по §3 — 4).
    ///
    /// - Parameters:
    ///   - folder: Раскрытая папка.
    ///   - width: Полная ширина панели в точках (ширина контента сетки).
    ///   - columns: Число колонок сетки содержимого, больше нуля.
    ///   - spacing: Зазор сетки (`itemSpacing`).
    ///   - scale: Масштаб экрана; `<= 0` — без пиксельного выравнивания.
    /// - Returns: Высота панели в точках; `0` для вырожденной геометрии.
    public static func panelHeight(
        for folder: TileFolder,
        width: CGFloat,
        columns: Int,
        spacing: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        panelHeight(
            tileCount: folder.tiles.count,
            width: width,
            columns: columns,
            spacing: spacing,
            scale: scale
        )
    }
}

#endif
