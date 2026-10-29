// Модель ярлыка рабочего стола (Start Screen).
// Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md — §3 «Плиточная сетка»
// (модель раскладки, юнитные координаты), §14 «Уточнения MVP» п. 1 и 4
// (D12/D15: ярлык — просто действие без поля `type`; четыре размера плиток).
// D14 (папки и функция одобрения) описан в docs/STATE.md; модель папки —
// в TileFolder.swift, операции с папками — в TileStore.

#if canImport(UIKit)
import UIKit
#else
import CoreGraphics
#endif

/// Размер ярлыка на сетке рабочего стола в юнитах
/// (docs/STARTSCREEN-IOS-DESIGN.md §3, §14 п. 4; D15 в docs/STATE.md).
///
/// Размеры заданы парами «колонки × строки»:
/// - ``small`` — 1×1,
/// - ``medium`` — 2×2,
/// - ``wide`` — 4×2,
/// - ``large`` — 4×4.
///
/// Значения — именно размеры в юнитах, а не в точках: сетка пересчитывается
/// под любую ширину экрана, а положение ярлыков хранится в юнитных координатах
/// (документ §3, «Модель раскладки»). `String`-сырое значение используется
/// персистентностью `TileStore` (E4.6), `CaseIterable` — циклом resize в E4.4.
public enum TileSize: String, CaseIterable, Codable, Hashable {
    /// 1×1 юнит.
    case small

    /// 2×2 юнита; размер по умолчанию для ярлыка (D12).
    case medium

    /// 4×2 юнита: «широкая» плитка.
    case wide

    /// 4×4 юнита: «большая» плитка.
    case large

    /// Размер ярлыка в юнитах: ширина — число колонок, высота — число строк.
    ///
    /// Для всех случаев `width` и `height` — целые положительные значения;
    /// движок раскладки использует их как целые (`unitColumns`/`unitRows`).
    public var unitSize: CGSize {
        switch self {
        case .small:
            return CGSize(width: 1, height: 1)
        case .medium:
            return CGSize(width: 2, height: 2)
        case .wide:
            return CGSize(width: 4, height: 2)
        case .large:
            return CGSize(width: 4, height: 4)
        }
    }

    /// Ширина ярлыка в юнитах (число колонок сетки).
    public var unitColumns: Int {
        Int(unitSize.width)
    }

    /// Высота ярлыка в юнитах (число строк сетки).
    public var unitRows: Int {
        Int(unitSize.height)
    }
}

/// Бейдж внимания на ярлыке — красная точка или счётчик
/// (docs/STARTSCREEN-IOS-DESIGN.md §14 п. 1; D12 в docs/STATE.md).
///
/// Бейдж не является частью live-флипа: это отдельный элемент угла плитки
/// (документ §4, «Бейдж»). Модель хранит намерение, а внешний вид и озвучивание
/// для VoiceOver строит компонент.
public enum TileBadge: Equatable, Hashable {
    /// Бейджа нет.
    case none

    /// Красная точка без числа — «есть что-то новое».
    case dot

    /// Счётчик внимания. Неположительное значение не показывается:
    /// см. ``isVisible``.
    case count(Int)

    /// Нужно ли визуально показывать бейдж.
    ///
    /// `.count(0)` и отрицательные счётчики трактуются как отсутствие бейджа:
    /// так модель не требует от вью повторной проверки знака и не показывает
    /// пустую красную точку. `.dot` и положительный счётчик видимы.
    public var isVisible: Bool {
        switch self {
        case .none:
            return false
        case .dot:
            return true
        case let .count(value):
            return value > 0
        }
    }
}

#if canImport(UIKit)

/// Ярлык рабочего стола — просто действие над плиткой
/// (docs/STARTSCREEN-IOS-DESIGN.md §3, §14 п. 1; D12 в docs/STATE.md).
///
/// У ярлыка **нет** поля `type`: группировка по типам приложений не
/// используется, ярлык описывается идентификатором, подписью, иконкой,
/// действием, бейджем и размером плитки. Действие — единственный способ
/// поведения: тап по плитке вызывает ``action``, а переходы, открытие папок и
/// прочая навигация остаются за хостом.
///
/// Модель — обычное значение (`struct`): `TileStore` хранит массив ярлыков и
/// заменяет/меняет их копии, не превращая компонент в источник глобального
/// состояния. Живой контент (флипы, стахгер, паузы) — задача `LiveTileEngine`
/// (E4.3, документ §4); здесь только статичная модель ярлыка.
public struct TileDescriptor {
    /// Стабильный идентификатор ярлыка.
    ///
    /// Должен быть уникален в пределах рабочего стола: по нему `TileStore`
    /// находит ярлык для resize, unpin и операций с папками (D14). Поведение при
    /// повторяющихся идентификаторах не определено.
    public let id: AnyHashable

    /// Подпись ярлыка; используется и как accessibility label плитки
    /// (документ §9, «Плитка — один элемент»).
    public var title: String

    /// Иконка ярлыка. `nil` допустим: плитка покажет заглушку/только подпись.
    public var icon: UIImage?

    /// Действие по тапу. Вызывается на главном потоке компонентом.
    ///
    /// Замыкание — часть идентичности ярлыка и не заменяется при resize;
    /// для смены поведения хост создаёт новый ``TileDescriptor``.
    public let action: () -> Void

    /// Бейдж внимания — красная точка или счётчик (D12). По умолчанию `.none`.
    public var badge: TileBadge

    /// Размер плитки в юнитах (D15). По умолчанию `.medium`.
    public var size: TileSize

    /// Создаёт ярлык рабочего стола.
    ///
    /// - Parameters:
    ///   - id: Уникальный идентификатор ярлыка в пределах рабочего стола.
    ///   - title: Подпись ярлыка.
    ///   - icon: Иконка; `nil` — без иконки.
    ///   - action: Действие по тапу; вызывается на главном потоке.
    ///   - badge: Бейдж внимания, по умолчанию `.none`.
    ///   - size: Размер плитки, по умолчанию `.medium` (D12).
    public init(
        id: AnyHashable,
        title: String,
        icon: UIImage? = nil,
        action: @escaping () -> Void,
        badge: TileBadge = .none,
        size: TileSize = .medium
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.action = action
        self.badge = badge
        self.size = size
    }
}

#endif
