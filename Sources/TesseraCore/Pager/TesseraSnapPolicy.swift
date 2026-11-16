//
//  TesseraSnapPolicy.swift
//  TesseraCore
//
//  Конфиг и расчёт кастомного снапа для неполностраничных страниц (peek).
//  Проектный документ: docs/Core-iOS-Design.md §3 «Концептуальная поверхность API»
//  (TesseraSnapPolicy — конфиг снапа) и §4 «Снап» в составе режима `snapping`
//  (docs/Core-iOS-Design.md §2 «Два режима пейджера»:
//  ширина страницы ≠ ширины экрана, `decelerationRate = .fast`,
//  ближайший центр + порог скорости).
//

import CoreGraphics

/// Выравнивание, к которому снап приводит страницу.
///
/// Различие режимов — в формуле «ближайшего» индекса (см.
/// `TesseraSnapPolicy.targetContentOffset(proposedOffset:velocity:itemWidth:pageCount:startOffset:)`),
/// а не в знаке итогового offset'а: политика возвращает offset начала страницы.
public enum TesseraSnapAlignment {
    /// Выравнивание по ведущему краю: индекс = `floor(offset / itemWidth + 0.5)`.
    case leading
    /// Выравнивание по центру: индекс = `round(offset / itemWidth)`.
    case center
}

/// Политика снапа для режима `snapping`: порог скорости и выравнивание.
///
/// Тип — чистая конфиг-структура без зависимостей от UIKit: расчёт
/// `targetContentOffset` детерминирован и полностью тестируем без scroll view.
/// Потребитель (пейджер в режиме `snapping` / `TesseraPanoScrollView`) вызывает
/// `targetContentOffset(...)` из
/// `UIScrollViewDelegate.scrollViewWillEndDragging(_:withVelocity:targetContentOffset:)`,
/// подставляя `proposedOffset` из параметра `inout`-указателя, скорость
/// `velocity`, переведённую из points/ms UIKit в pt/s (`× 1000`), и стартовый
/// offset жеста из `scrollViewWillBeginDragging`.
///
/// Документ §2: в режиме `snapping` потребитель дополнительно выставляет
/// `decelerationRate = .fast` — это его ответственность, политика децелерацией не управляет.
///
/// Все величины — в координатах содержимого scroll view (points), без учёта
/// `contentInset`. Если для центрирования потребитель задаёт inset/смещение
/// вьюпорта, пересчёт в эти координаты — на его стороне: сигнатура намеренно
/// не принимает ширину вьюпорта, чтобы политика оставалась одной формулой.
public struct TesseraSnapPolicy {
    /// Порог скорости свайпа в pt/s: свайп быстрее порога уводит на соседнюю
    /// секцию, медленнее — оставляет на ближайшей. По умолчанию 600 pt/s.
    ///
    /// Ожидается неотрицательным; отрицательное значение нормализуется к нулю,
    /// чтобы нулевая скорость никогда не считалась «быстрым свайпом».
    public var velocityThreshold: CGFloat

    /// Выравнивание секции. По умолчанию `.center`.
    public var alignment: TesseraSnapAlignment

    /// - Parameters:
    ///   - velocityThreshold: порог скорости в pt/s, по умолчанию 600.
    ///   - alignment: выравнивание, по умолчанию `.center`.
    public init(velocityThreshold: CGFloat = 600, alignment: TesseraSnapAlignment = .center) {
        self.velocityThreshold = velocityThreshold
        self.alignment = alignment
    }

    /// Возвращает offset, к которому должен прилипнуть скролл после жеста.
    ///
    /// Алгоритм:
    /// 1. Вырожденный вход (`itemWidth <= 0` или `pageCount <= 0`) — вернуть
    ///    `proposedOffset` без изменений (снапить не к чему).
    /// 2. Ближайший индекс `nearest` относительно `proposedOffset`:
    ///    - `.center`:  `nearest = round(proposedOffset / itemWidth)`;
    ///    - `.leading`: `nearest = floor(proposedOffset / itemWidth + 0.5)`.
    /// 3. Если `|velocity| > velocityThreshold` — шаг на одну секцию по знаку
    ///    скорости (`velocity > 0` → `+1`, `velocity < 0` → `−1`) от опорного
    ///    индекса: секции, с которой начался жест (ближайшей к `startOffset`
    ///    по той же формуле выравнивания), а если `startOffset` не передан —
    ///    от `nearest`. Иначе — `nearest`.
    /// 4. Результат — `index * itemWidth`, зажатый в `[0, (pageCount - 1) * itemWidth]`.
    ///
    /// Опора на стартовую секцию нужна потому, что `proposedOffset` у быстрого
    /// флика уже включает инерцию: шаг от `nearest(proposed)` перескакивал бы
    /// через секцию. Со `startOffset` один жест сдвигает не больше чем на одну
    /// секцию от стартовой (поведение WP), а медленный жест (ниже порога)
    /// остаётся на ближайшей к `proposedOffset`.
    ///
    /// Знак скорости — в конвенции `UIScrollView`: положительная скорость
    /// увеличивает `contentOffset.x` (в LTR это следующая секция, в RTL потребитель
    /// нормализует координаты по направлению чтения, документ §2 «Инвариант прогресса»).
    ///
    /// - Important: `UIScrollViewDelegate.scrollViewWillEndDragging` отдаёт
    ///   скорость в **points/ms**; потребитель обязан перевести её в pt/s
    ///   (`× 1000`) перед вызовом — порог ``velocityThreshold`` задан в pt/s.
    ///
    /// Формулы `.center` и `.leading` совпадают для неотрицательного
    /// `proposedOffset` (округление к ближайшему, полуцелые — вверх), но
    /// расходятся при отрицательных значениях (`round(-0.5) == -1`,
    /// `floor(0) == 0`); такой индекс затем клампится в ноль. Раздельные формулы
    /// сохранены, чтобы контракт оставался верным при сдвинутых координатах
    /// (inset'ы, неотрицательный origin).
    ///
    /// - Parameters:
    ///   - proposedOffset: предложенный системой offset (обычно
    ///     `targetContentOffset.pointee`).
    ///   - velocity: скорость жеста по горизонтали в pt/s (знаковая).
    ///   - itemWidth: ширина одной секции (шаг снапа) в pt.
    ///   - pageCount: число секций.
    ///   - startOffset: `contentOffset.x` в начале жеста (обычно запоминается в
    ///     `scrollViewWillBeginDragging`); `nil` или нечисловое значение —
    ///     опора на `nearest(proposedOffset)`, как до появления параметра.
    /// - Returns: клампированный целевой offset; для вырожденного входа —
    ///   `proposedOffset` как есть.
    public func targetContentOffset(proposedOffset: CGFloat,
                                    velocity: CGFloat,
                                    itemWidth: CGFloat,
                                    pageCount: Int,
                                    startOffset: CGFloat? = nil) -> CGFloat {
        // Вырожденная геометрия: снап невозможен, отдаём предложение системы.
        guard itemWidth > 0, pageCount > 0 else { return proposedOffset }

        let nearestIndex = self.nearestIndex(for: proposedOffset, itemWidth: itemWidth)
        let threshold = max(velocityThreshold, 0)

        let targetIndex: CGFloat
        if abs(velocity) > threshold {
            // Быстрый свайп: шаг на секцию в сторону движения от стартовой
            // секции жеста (без неё — от ближайшей к предложенному offset'у).
            let baseIndex: CGFloat
            if let startOffset, startOffset.isFinite {
                baseIndex = self.nearestIndex(for: startOffset, itemWidth: itemWidth)
            } else {
                baseIndex = nearestIndex
            }
            targetIndex = velocity > 0 ? baseIndex + 1 : baseIndex - 1
        } else {
            // Медленный жест или удержание: остаёмся на ближайшей секции.
            targetIndex = nearestIndex
        }

        // Эквивалент клампа индекса в [0, pageCount - 1], но в координатах offset'а.
        let lowerBound: CGFloat = 0
        let upperBound = CGFloat(pageCount - 1) * itemWidth
        return min(max(targetIndex * itemWidth, lowerBound), upperBound)
    }

    /// Ближайший индекс секции по формулам из документа (§2 «Два режима пейджера»).
    private func nearestIndex(for proposedOffset: CGFloat, itemWidth: CGFloat) -> CGFloat {
        let position = proposedOffset / itemWidth
        switch alignment {
        case .center:
            // round(proposedOffset / itemWidth) — округление к ближайшему,
            // полуцелые уходят от нуля (стандартное правило Swift).
            return position.rounded()
        case .leading:
            // floor(proposedOffset / itemWidth + 0.5) — полуцелые всегда вверх.
            return (position + 0.5).rounded(.down)
        }
    }
}
