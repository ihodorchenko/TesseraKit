// Раскладка бэйджа плитки в нижнем углу (D29, E15.1).
// Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md — §4 «Бэйдж»,
// «Отступления реализации» (E15), пп. 59 и 60 (D47); docs/W10M-STARTSCREEN.md §1.

#if canImport(UIKit)
import UIKit
#else
import CoreGraphics
#endif

/// Раскладка бэйджа в **нижнем** углу плитки у конца строки и резерв места
/// под него для подписи (D29, E15.1).
///
/// Как в W10M, бэйдж (капсула со счётчиком или точка) сидит в правом нижнем
/// углу в LTR и в левом нижнем в RTL. Один и тот же расчёт использует статичная
/// ячейка сетки (``TesseraTileCell``) и живая плитка (``TesseraLiveTileView``),
/// поэтому углы у них не расходятся.
///
/// ## Подпись и бэйдж
///
/// Подпись плитки прижата к низу, то есть делит нижний ряд с бэйджем. Чтобы они
/// не наложились, бэйдж отнимает место у подписи одним из двух способов
/// (``Arrangement``):
/// - ``Arrangement/beside`` — подпись остаётся в нижнем ряду, но становится
///   уже на ширину бэйджа с зазором (``titleTrailingReserve``). Выбирается,
///   пока подпись сохраняет не меньше ``minimumTitleFraction`` ширины контента и
///   не меньше ``minimumTitleWidth`` pt;
/// - ``Arrangement/above`` — на узкой плитке (1×1) подпись остаётся полной
///   ширины, но поднимается над рядом бэйджа (``titleBottomReserve``). Если при
///   этом иконке не хватает высоты, иконка уступает (правило «текст важнее»).
///   Малая плитка с иконкой этот способ не использует (D47, ниже).
///
/// Способ выбирается по геометрии **без правки** и в правке не меняется:
/// подпись не прыгает между режимами при входе в редактирование.
///
/// ## Малая плитка 1×1 с бэйджем: иконка и бэйдж, без подписи (D47)
///
/// Как в W10M, на малой плитке с видимым бэйджем (капсула или точка) подпись не
/// рисуется: остаются иконка и бэйдж (``Arrangement/iconAndBadge``). Иконка
/// стоит по центру верхней зоны плитки, над рядом бэйджа
/// (``smallTileIconFrame(tileSize:inset:bottomReserve:)``), бэйдж — в нижнем углу
/// у конца строки; они не пересекаются, и иконку не выдавливает ни бэйдж, ни
/// подпись. Подпись в таком режиме скрыта только визуально: label и value
/// VoiceOver остаются прежними. Решение «скрыть ли подпись» принимает вызывающий
/// (``make(tileSize:badgeSize:inset:isRightToLeft:editClearance:hidesTitle:)``):
/// ему известны размер ярлыка по модели (`TileSize.small`) и наличие иконки —
/// без иконки подпись остаётся, иначе на плитке не было бы ничего, кроме бэйджа.
/// Малая плитка без бэйджа и плитки 2×2, 4×2, 4×4 раскладываются как раньше.
///
/// ## Правка: обход стрелки размера
///
/// В правке стрелка размера сидит в том же нижнем углу и заходит в плитку на
/// `диаметр − выступ` (``TesseraTileEditControlView/badgeClearance(forTileSize:maxDiameter:)``).
/// Бэйдж сдвигается вдоль нижнего ряда от угла на эту величину плюс
/// ``editGap`` (в LTR влево, в RTL вправо), так что рамки бэйджа и стрелки не
/// пересекаются. Это наименее навязчивое решение: бэйдж остаётся видимым,
/// подпись в режиме «над» не страдает, а в режиме «рядом» подпись сужается
/// на тот же сдвиг. Если бэйдж не помещается правее кнопки (капсула «99+» на
/// 1×1 уже ≈ 57 pt, крупный Dynamic Type), он **скрывается только на время
/// правки** (``isHiddenByEditControls``): поднять его вверх между кнопками
/// значило бы наехать на иконку (D47) либо выдавить подпись 1×1.
struct TesseraTileBadgeLayout: Equatable {

    /// Как подпись уступает место бэйджу.
    enum Arrangement: Equatable {

        /// Бэйджа нет: подписи ничего не резервируется.
        case none

        /// Подпись в нижнем ряду, уже на ширину бэйджа.
        case beside

        /// Подпись над рядом бэйджа, полной ширины.
        case above

        /// Подписи нет: иконка над рядом бэйджа и бэйдж в углу (D47).
        case iconAndBadge
    }

    /// Наименьшая сторона иконки малой плитки с бэйджем, pt: даже когда бэйдж
    /// раздут Dynamic Type и верхней зоне не хватает места, иконка не
    /// пропадает (бэйдж рисуется поверх неё).
    static let minimumSmallIconSide: CGFloat = 12

    /// Наибольшая сторона иконки малой плитки с бэйджем, pt.
    static let maximumSmallIconSide: CGFloat = 34

    /// Доля меньшей стороны плитки, выше которой иконка малой плитки с бэйджем
    /// не растёт.
    static let smallIconSideFraction: CGFloat = 0.45

    /// Зазор между бэйджем и подписью, pt.
    static let titleGap: CGFloat = 4

    /// Зазор между бэйджем и стрелкой размера в правке, pt.
    static let editGap: CGFloat = 2

    /// Наименьшая ширина подписи в режиме «рядом», pt.
    static let minimumTitleWidth: CGFloat = 40

    /// Наименьшая доля ширины контента, остающаяся подписи в режиме «рядом».
    static let minimumTitleFraction: CGFloat = 0.6

    /// Рамка бэйджа в координатах плитки; нулевая, если бэйджа нет.
    var frame: CGRect = .zero

    /// Способ, которым подпись обходит бэйдж.
    var arrangement: Arrangement = .none

    /// Скрыт ли бэйдж на время правки, потому что не помещается рядом со
    /// стрелкой размера.
    var isHiddenByEditControls = false

    /// Ширина, которую подпись отдаёт бэйджу со стороны конца строки (режим
    /// «рядом»), pt.
    var titleTrailingReserve: CGFloat = 0

    /// Высота нижнего ряда, которую подпись отдаёт бэйджу (режим «над»), pt.
    var titleBottomReserve: CGFloat = 0

    /// Высота нижнего ряда бэйджа с зазором, которую иконка малой плитки
    /// оставляет бэйджу (D47), pt. Считается всегда, когда бэйдж есть: решение
    /// «показывать ли иконку вместо подписи» принимает вызывающий (у живой
    /// плитки оно зависит от иконки конкретной стороны).
    var iconBottomReserve: CGFloat = 0

    /// Считает раскладку.
    ///
    /// - Parameters:
    ///   - tileSize: Размер плитки.
    ///   - badgeSize: Собственный размер бэйджа (`.zero` — бэйджа нет).
    ///   - inset: Поле плитки: отступ бэйджа от нижнего и бокового краёв и
    ///     поле подписи.
    ///   - isRightToLeft: Направление чтения.
    ///   - editClearance: Сколько нижнего угла у конца строки занимает стрелка
    ///     размера внутри плитки; `0` — вне правки либо стрелки нет.
    ///   - hidesTitle: `true` — малая плитка с иконкой: подписи нет, подписи
    ///     ничего не резервируется (``Arrangement/iconAndBadge``, D47). Без
    ///     бэйджа флаг ничего не меняет.
    /// - Returns: Рамка бэйджа и резерв для подписи.
    static func make(
        tileSize: CGSize,
        badgeSize: CGSize,
        inset: CGFloat,
        isRightToLeft: Bool,
        editClearance: CGFloat,
        hidesTitle: Bool = false
    ) -> TesseraTileBadgeLayout {
        guard badgeSize.width > 0, badgeSize.height > 0,
              tileSize.width > 0, tileSize.height > 0 else {
            return TesseraTileBadgeLayout()
        }

        let width = tileSize.width
        let contentWidth = max(0, width - inset * 2)
        let normalY = tileSize.height - inset - badgeSize.height

        // Позиция вне правки: у края с отступом `inset`; слишком широкий бэйдж
        // прижимается к полю, а не вылезает за плитку.
        func originX(margin: CGFloat) -> CGFloat {
            isRightToLeft ? margin : width - margin - badgeSize.width
        }
        func fits(_ x: CGFloat) -> Bool {
            x >= inset - 0.001 && x + badgeSize.width <= width - inset + 0.001
        }
        let normalX = max(inset, min(originX(margin: inset), width - inset - badgeSize.width))

        var layout = TesseraTileBadgeLayout()
        var x = normalX
        var trailingMargin = inset

        if editClearance > 0 {
            let margin = max(inset, editClearance + editGap)
            let shiftedX = originX(margin: margin)
            if fits(shiftedX) {
                x = shiftedX
                trailingMargin = margin
            } else {
                // Не помещается правее стрелки: на время правки бэйдж скрыт, а
                // подпись резервирует место как вне правки.
                layout.isHiddenByEditControls = true
            }
        }
        layout.frame = CGRect(x: x, y: normalY, width: badgeSize.width, height: badgeSize.height)
        layout.iconBottomReserve = badgeSize.height + titleGap

        // D47: малая плитка с иконкой — подписи нет, резерва тоже.
        if hidesTitle {
            layout.arrangement = .iconAndBadge
            return layout
        }

        // Способ решается по геометрии вне правки (подпись не прыгает).
        let normalReserve = badgeSize.width + titleGap
        let besideWidth = contentWidth - normalReserve
        let threshold = max(minimumTitleWidth, contentWidth * minimumTitleFraction)
        if besideWidth >= threshold {
            layout.arrangement = .beside
            layout.titleTrailingReserve = (trailingMargin - inset) + normalReserve
        } else {
            layout.arrangement = .above
            layout.titleBottomReserve = badgeSize.height + titleGap
        }
        return layout
    }

    /// Рамка иконки малой плитки с бэйджем (D47).
    ///
    /// Иконка стоит по центру **верхней зоны**: от верхнего поля до зазора над
    /// рядом бэйджа. Зона не зависит от стороны бэйджа и от правки, поэтому в RTL
    /// и при сдвиге бэйджа от стрелки размера иконка остаётся на месте, а кнопка
    /// открепления (верхний угол у конца строки) на неё не заходит. Сторона —
    /// высота зоны, но не больше ``smallIconSideFraction`` меньшей стороны плитки,
    /// ``maximumSmallIconSide``, ширины контента и ширины между кнопками правки
    /// (иконка не заходит под кнопку открепления даже в правке); не меньше
    /// ``minimumSmallIconSide``: при раздутом Dynamic Type бэйдж уходит поверх
    /// иконки, но иконка остаётся.
    ///
    /// - Parameters:
    ///   - tileSize: Размер плитки.
    ///   - inset: Поле плитки.
    ///   - bottomReserve: ``iconBottomReserve`` раскладки бэйджа.
    /// - Returns: Рамка иконки в координатах плитки.
    static func smallTileIconFrame(
        tileSize: CGSize,
        inset: CGFloat,
        bottomReserve: CGFloat
    ) -> CGRect {
        let zoneHeight = max(0, tileSize.height - inset * 2 - bottomReserve)
        let contentWidth = max(0, tileSize.width - inset * 2)
        // Иконка стоит по центру и в правке не должна наезжать на кнопку
        // открепления в верхнем углу: та заходит в плитку на `диаметр − выступ`
        // (у малой плитки диаметр — минимальный). Резерв берётся всегда, а не
        // только в правке, чтобы иконка не прыгала при входе в правку.
        let buttonReserve = TesseraTileEditControlView.minimumDiameter
            - TesseraTileEditControlView.cornerOverhang
        let limit = min(
            zoneHeight,
            min(tileSize.width, tileSize.height) * smallIconSideFraction,
            maximumSmallIconSide,
            contentWidth,
            tileSize.width - 2 * buttonReserve - 1
        )
        let side = max(minimumSmallIconSide, floor(limit))
        let x = ((tileSize.width - side) / 2).rounded()
        let y = inset + max(0, ((zoneHeight - side) / 2).rounded())
        return CGRect(x: x, y: y, width: side, height: side)
    }
}
