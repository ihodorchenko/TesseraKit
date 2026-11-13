// Раскладка бэйджа плитки в нижнем углу (D29, E15.1).
// Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md — §4 «Бэйдж»,
// «Отступления реализации» (E15), п. 59; docs/W10M-STARTSCREEN.md §1.

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
///
/// Способ выбирается по геометрии **без правки** и в правке не меняется:
/// подпись не прыгает между режимами при входе в редактирование.
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
/// значило бы выдавить подпись 1×1.
struct TesseraTileBadgeLayout: Equatable {

    /// Как подпись уступает место бэйджу.
    enum Arrangement: Equatable {

        /// Бэйджа нет: подписи ничего не резервируется.
        case none

        /// Подпись в нижнем ряду, уже на ширину бэйджа.
        case beside

        /// Подпись над рядом бэйджа, полной ширины.
        case above
    }

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
    /// - Returns: Рамка бэйджа и резерв для подписи.
    static func make(
        tileSize: CGSize,
        badgeSize: CGSize,
        inset: CGFloat,
        isRightToLeft: Bool,
        editClearance: CGFloat
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
}
