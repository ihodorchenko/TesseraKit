//
//  TileEditCoordinator.swift
//  TesseraStartScreen
//
//  Координатор режима редактирования рабочего стола: «желе», unpin, resize,
//  собственный drag и операции с папками через функцию одобрения хоста.
//
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md
//  - §5 «Режим редактирования»: long-press → «желе» (мягкая синусоидальная
//    `CAKeyframeAnimation` поворота ±1,2° за 0,4 с со случайной фазой), unpin
//    с fly-out, dimming всех плиток, кроме выбранной (E8.2), resize по циклу
//    small → medium → wide → large с переупаковкой, собственный drag-координатор
//    (снэпшот + пустышка + превью порядка без записи в модель + инвалидация
//    layout), а не нативный `UICollectionView` interactive movement;
//  - §3 «Плиточная сетка»: переупаковку считает `TileLayoutEngine`, анимацию
//    сдвига соседей — `TesseraTileGridView.update(snapshot:animated:)` через
//    batch updates;
//  - §9 «Accessibility»: в edit-режиме у плитки появляются custom actions
//    resize/unpin, смена режима озвучивается; Reduce Motion отключает «желе»,
//    fly-out, анимацию димминга и параллакс-подобные эффекты, оставляя кнопки
//    открепления, сам димминг и подсветку;
//  - §14 «Уточнения MVP»: D12 (ярлык — просто действие), D14 (папки — только
//    через функцию одобрения `TileStore.approval`), D15 (четыре размера).
//
//  Правило «один писатель» (§6): модель меняет только `TileStore`; координатор
//  не хранит порядок и размеры, а читает снимок и вызывает операции хранилища.
//  Сетка не ходит в хранилище сама — после каждой мутации координатор применяет
//  новый снимок через `update(snapshot:animated:)`, но только если хост ещё не
//  сделал этого из своего `TileStore.onChange` (сравнение снимков дешёвое).
//
//  E8.4: во время перетаскивания модель НЕ меняется. Порядок соседей —
//  превью, которое живёт только в сетке (`TileLayoutEngine.previewOrder` +
//  `grid.update(snapshot:animated:)`); в `TileStore` порядок пишется один раз на
//  drop, а отмена просто возвращает сетке снимок на момент захвата. Хост не
//  получает `onChange` на каждый шаг drag, автосохранение не срабатывает.
//
//  E8.7: resize-выталкивание. При увеличении плитка по возможности остаётся на
//  своём месте, а конфликтующие плитки справа/снизу уходят вниз
//  (`TileLayoutEngine.resizePlacement` + `TileStore.resize(_:to:columns:)`);
//  координатор передаёт реальное число колонок сетки. Цикл размеров D15
//  (small → medium → wide → large → small) не меняется.
//
//  E8.6: папка из двух ярлыков больше не создаётся мгновенно при drop на
//  центр плитки-цели. Нужно удержать перетаскиваемую плитку над целью не
//  меньше `mergeHoverDuration` (600 мс) при смещении пальца не больше
//  `mergeHoverDisplacement` (10 pt); тогда цель подсвечивается «впитыванием»
//  (масштаб 1,08 + акцентная рамка, ~0,2 с) и drop создаёт папку. Таймер не
//  истёк или палец сместился больше допуска — обычное перетаскивание E8.4.
//  Решение «сливать или нет» принимает чистая state-машина
//  ``TesseraMergeHoverTracker``: в ней нет UIKit и часов системы, поэтому она
//  тестируется без симулятора.
//
//  E8.8: движения плиток при перестановке (переезд соседей в
//  `TesseraTileGridView.update(snapshot:animated:)` и пустышка под снятой
//  плиткой) идут bounce-кривой `cubic-bezier(0.175, 0.885, 0.32, 1.1)`,
//  0,26 с. Фабрика общая — `TesseraTileGridView.bounceTimingParameters()`;
//  кривая раскрытия/закрытия панели папки (0.1, 0.9, 0.2, 1) не меняется.
//
//  E8.9: магнитизм к ячейкам. Под перетаскиваемой плиткой строится виртуальная
//  сетка слотов той же размерности (`TesseraTileGridView.magnetSlotCenters(for:)`),
//  а выбор ближайшего слота делает чистая функция
//  `TesseraTileMagnet.magnetTarget(for:slotCenters:snapRadius:)`. Если палец
//  попадает в `magnetSnapRadius` (28 pt) от центра ближайшего слота, снимок
//  плавно подъезжает к его центру (spring 0,2 с); за радиусом снова следует
//  за пальцем 1:1. Это только визуальный слой: цели E8.4 и таймер E8.6
//  считаются по точке пальца, а не по центру снимка, поэтому перестановка и
//  слияние не меняются. Над панелью раскрытой папки и над целями группировки
//  (папка, центр ярлыка из зоны E8.6) притяжение не работает; при Reduce
//  Motion оно отключено целиком — снимок остаётся строго под пальцем.
//
//  Дисциплина прокрутки (§3, CORE-IOS-DESIGN.md §2): в колбэке `contentOffset`
//  координатор трогает только `frame`/`isHidden` видов-кнопок поверх сетки и
//  `alpha` содержимого ячеек (димминг) — всё это разрешённые в горячем пути
//  свойства; layout сетки и ячеек не пересчитывается.
//
//  Границы ответственности:
//  - сетка (`TesseraTileGridView`) отображает снимок и отдаёт геометрию;
//  - `TileStore` — единственный писатель модели;
//  - координатор владеет жестами, оверлеями кнопок открепления/размера,
//    drag-сессией и минимальным экраном папки;
//  - открытие ярлыка/папки по тапу остаётся за хостом (`onTap` сетки).
//
//  Все методы — главный поток: UIKit-вью и `TileStore` не рассчитаны на
//  фоновые вызовы (CORE-IOS-DESIGN.md §3).
//
//  Задача плана: E4.4 (после E4.2: TileDescriptor, TileLayoutEngine, TileStore,
//  TileGridView уже в репозитории); E8.2 — димминг в режиме редактирования,
//  E8.3 — булавка вместо крестика у кнопки «открепить», E8.4 — push-физика
//  drag: превью порядка без записи в модель, фиксация на drop; E8.6 — слияние
//  в папку по удержанию (600 мс / 10 pt) с подсветкой «впитывания»; E8.9 —
//  виртуальная сетка слотов и spring-притяжение снимка к ближайшей ячейке.
//

#if canImport(UIKit)
import Combine
import UIKit
import TesseraCore

// MARK: - Делегат

/// Наблюдатель режима редактирования рабочего стола (docs/STARTSCREEN-IOS-DESIGN.md §5).
///
/// Делегат только узнаёт о том, что координатор уже сделал через `TileStore`.
/// Возвращать значения и менять модель из колбэков нельзя: единственный писатель
/// — `TileStore` (§6), а координатор уже применил снимок к сетке.
///
/// Все методы вызываются на главном потоке. Обязательных методов нет: любое
/// событие можно игнорировать, реализации по умолчанию пустые.
public protocol TesseraTileEditCoordinatorDelegate: AnyObject {

    /// Координатор вошёл в режим редактирования.
    ///
    /// - Parameter coordinator: Координатор-источник события.
    func tileEditCoordinatorDidBeginEditing(_ coordinator: TesseraTileEditCoordinator)

    /// Координатор вышел из режима редактирования.
    ///
    /// - Parameter coordinator: Координатор-источник события.
    func tileEditCoordinatorDidEndEditing(_ coordinator: TesseraTileEditCoordinator)

    /// Ярлык откреплен с сетки (``TesseraTileEditCoordinator/unpin(_:)``).
    ///
    /// - Parameters:
    ///   - coordinator: Координатор-источник события.
    ///   - tileID: Идентификатор откреплённого ярлыка.
    func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didUnpin tileID: AnyHashable)

    /// Размер ярлыка или папки изменён (``TesseraTileEditCoordinator/cycleSize(of:)``).
    ///
    /// - Parameters:
    ///   - coordinator: Координатор-источник события.
    ///   - tileID: Идентификатор ярлыка или папки.
    ///   - size: Новый размер (D15).
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didResize tileID: AnyHashable,
        to size: TileSize
    )

    /// Элемент переставлен на сетке.
    ///
    /// - Parameters:
    ///   - coordinator: Координатор-источник события.
    ///   - tileID: Идентификатор ярлыка или папки.
    ///   - index: Новый индекс в порядке сетки.
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didMove tileID: AnyHashable,
        toIndex index: Int
    )

    /// Создана папка (D14).
    ///
    /// - Parameters:
    ///   - coordinator: Координатор-источник события.
    ///   - folder: Созданная папка.
    func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didCreateFolder folder: TileFolder)

    /// Ярлык добавлен в папку (D14).
    ///
    /// - Parameters:
    ///   - coordinator: Координатор-источник события.
    ///   - tileID: Идентификатор ярлыка.
    ///   - folderID: Идентификатор папки-цели.
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didAdd tileID: AnyHashable,
        toFolder folderID: AnyHashable
    )

    /// Ярлык перемещён между папками или на рабочий стол (D14).
    ///
    /// - Parameters:
    ///   - coordinator: Координатор-источник события.
    ///   - tileID: Идентификатор ярлыка.
    ///   - folderID: Папка-цель; `nil` — ярлык вернулся на рабочий стол.
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didMove tileID: AnyHashable,
        toFolder folderID: AnyHashable?
    )

    /// Функция одобрения хоста (D14) отказала в операции с папкой.
    ///
    /// Состояние модели не изменилось (кроме случая, когда папка уже создана,
    /// а отказано только добавление второго ярлыка — см.
    /// ``TesseraTileEditCoordinator``).
    ///
    /// - Parameters:
    ///   - coordinator: Координатор-источник события.
    ///   - action: Отклонённая операция группировки.
    ///   - tileID: Ярлык, с которым пытались выполнить операцию.
    ///   - folderID: Папка-цель; `nil` для создания папки.
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didFailGrouping action: TileGroupingAction,
        tileID: AnyHashable,
        folderID: AnyHashable?
    )
}

public extension TesseraTileEditCoordinatorDelegate {

    func tileEditCoordinatorDidBeginEditing(_ coordinator: TesseraTileEditCoordinator) {}

    func tileEditCoordinatorDidEndEditing(_ coordinator: TesseraTileEditCoordinator) {}

    func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didUnpin tileID: AnyHashable) {}

    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didResize tileID: AnyHashable,
        to size: TileSize
    ) {}

    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didMove tileID: AnyHashable,
        toIndex index: Int
    ) {}

    func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didCreateFolder folder: TileFolder) {}

    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didAdd tileID: AnyHashable,
        toFolder folderID: AnyHashable
    ) {}

    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didMove tileID: AnyHashable,
        toFolder folderID: AnyHashable?
    ) {}

    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didFailGrouping action: TileGroupingAction,
        tileID: AnyHashable,
        folderID: AnyHashable?
    ) {}
}

// MARK: - Конфигурация

/// Параметры режима редактирования (docs/STARTSCREEN-IOS-DESIGN.md §5).
///
/// Значения по умолчанию: мягкий синусоидальный поворот «желе» ±1,2° с циклом
/// 0,4 с, отдельная фаза на каждую плитку (seedable — детерминированная для
/// тестов E4.7), автопрокрутка у краёв при перетаскивании, параметры
/// слияния в папку по удержанию (E8.6): 600 мс удержания, допуск 10 pt и
/// анимация подсветки «впитывания» 0,2 с с масштабом 1,08, а также параметры
/// магнитизма к ячейкам (E8.9): радиус 28 pt, spring 0,2 с с демпфированием
/// 0,82.
public struct TesseraTileEditConfiguration {

    /// Seed «желе» и фаз: одинаковый seed даёт одинаковую картину покачивания.
    ///
    /// Фаза плитки считается stable-хэшем её идентификатора, смешанным с seed,
    /// поэтому она не зависит от `hashValue` (который рандомизируется между
    /// запусками) и воспроизводится в тестах.
    public var seed: UInt64

    /// Амплитуда «желе» в градусах (по умолчанию ±1,2°).
    ///
    /// Малая амплитуда при мягкой синусоидальной анимации читается как «дыхание»
    /// плитки, а не как дёрганье: резкое покачивание глазу мешает, а цель
    /// эффекта — показать, что элемент «живой» и его можно двигать.
    public var jiggleAngle: CGFloat

    /// Базовая длительность одного цикла покачивания в секундах.
    ///
    /// По умолчанию 0,4 с; с разбросом фазы/длительности (0,85–1,15) циклы
    /// плиток расходятся на 0,34–0,46 с, и сетка не качается синхронно.
    public var jiggleDuration: TimeInterval

    /// Масштаб поднятой плитки при перетаскивании.
    ///
    /// Плитка слегка уменьшается, отделяясь от плоскости (в спеке WP — scale 0.95):
    /// так захваченная плитка читается как «взятая» и не перекрывает соседей,
    /// а рост 1.04, наоборот, наезжал бы на них и выглядел как приближение.
    /// При Reduce Motion подъём не анимируется (плитка едет 1:1 за пальцем).
    /// Значение не обязано быть больше единицы: код анимаций работает с любым
    /// масштабом, а рамки/центр снимка задаются через `bounds`/`center`,
    /// поэтому уменьшение (< 1) безопасно.
    public var liftScale: CGFloat

    /// Диаметр круглых кнопок «открепить»/«размер» в точках.
    public var controlDiameter: CGFloat

    /// Ширина зоны автопрокрутки у верхнего и нижнего края сетки в точках.
    public var autoScrollEdge: CGFloat

    /// Максимальная скорость автопрокрутки в точках за кадр.
    public var autoScrollMaximumSpeed: CGFloat

    /// Название папки, создаваемой перетаскиванием ярлыка на ярлык.
    ///
    /// Пустая строка допустима: `TileStore` не требует названия, а экран папки
    /// покажет нейтральный заголовок.
    public var folderTitle: String

    /// Сколько нужно удерживать перетаскиваемую плитку над центром ярлыка-цели,
    /// чтобы drop создал папку (E8.6).
    ///
    /// По умолчанию 0,6 с (600 мс — спека WP). До истечения этого времени цель
    /// только подсвечивается обычной рамкой, а drop выполняет обычную
    /// перестановку E8.4. Нулевое значение возвращает почти мгновенное слияние
    /// (поведение до E8.6): готовность наступает на первом же кадре после
    /// наведения, по отпусканию палец успевает раньше.
    public var mergeHoverDuration: TimeInterval

    /// Допустимое смещение пальца за время удержания в точках (E8.6).
    ///
    /// По умолчанию 10 pt. Смещение больше допуска отменяет удержание: жест
    /// остаётся обычным перетаскиванием E8.4, даже если палец всё ещё над
    /// центром плитки-цели. Порог намеренно маленький: он отделяет «палец
    /// замер, чтобы собрать папку» от «палец ведёт плитку дальше».
    public var mergeHoverDisplacement: CGFloat

    /// Масштаб подсветки плитки-цели в состоянии «впитывания» (E8.6).
    ///
    /// По умолчанию 1,08 — середина диапазона 1.06–1.1 из спеки WP. Больше
    /// 1,1 цель читалась бы как «плитка выросла», а не «плитка втягивает в
    /// себя соседнюю». Значения меньше 1 не запрещены, но бессмысленны:
    /// «впитывание» — это лёгкое увеличение. При Reduce Motion масштаб
    /// применяется без анимации.
    public var mergeHighlightScale: CGFloat

    /// Длительность анимации подсветки «впитывания» в секундах (E8.6).
    ///
    /// По умолчанию 0,2 с: успевает прочитаться как реакция на удержание, но
    /// не запаздывает относительно отпускания пальца. При Reduce Motion
    /// анимация не проигрывается — рамка и масштаб выставляются сразу.
    public var mergeHighlightDuration: TimeInterval

    /// Радиус притяжения снимка к центру слота в точках (E8.9).
    ///
    /// По умолчанию 28 pt — середина диапазона 24–32 pt из спеки WP.
    /// Притяжение включается, когда палец оказывается ближе этого радиуса к
    /// центру виртуального слота той же размерности, что и перетаскиваемая
    /// плитка: снимок плавно подъезжает к центру, а не «прыгает» туда.
    /// Меньше 24 pt притяжение почти незаметно, больше 32 pt — начинает
    /// «отбирать» плитку у пальца на полпути между слотами.
    ///
    /// `0` отключает притяжение; отрицательные и нечисловые значения тоже
    /// трактуются как отключённое.
    public var magnetSnapRadius: CGFloat

    /// Длительность spring-подъезда снимка к центру слота в секундах (E8.9).
    ///
    /// По умолчанию 0,2 с: короткий spring читается как «плитка встала в
    /// ячейку», но не задерживает снимок за пальцем. `0` — снимок
    /// переставляется мгновенно (анимации притяжения нет).
    ///
    /// При Reduce Motion притяжение отключено целиком: снимок остаётся строго
    /// под пальцем (то же правило, что у подъёма плитки в E8.1), поэтому
    /// длительность не используется.
    public var magnetSpringDuration: TimeInterval

    /// Демпфирование spring-анимации притяжения (E8.9).
    ///
    /// По умолчанию 0,82 — почти критическое, с едва заметным отскоком:
    /// сильный отскок (меньше 0,6) на сетке выглядит как дрожание. Значение
    /// зажимается в диапазон 0,01…1; нечисловое трактуется как 0,82.
    public var magnetSpringDamping: CGFloat

    /// Создаёт конфигурацию.
    ///
    /// - Parameters:
    ///   - seed: Seed фаз «желе»; по умолчанию фиксированный.
    ///   - jiggleAngle: Амплитуда в градусах, по умолчанию 1.2.
    ///   - jiggleDuration: Длительность цикла в секундах, по умолчанию 0.4.
    ///   - liftScale: Масштаб поднятой плитки, по умолчанию 0.95 (плитка
    ///     слегка уменьшается, отделяясь от плоскости, — спека WP).
    ///   - controlDiameter: Диаметр кнопок, по умолчанию 28.
    ///   - autoScrollEdge: Зона автопрокрутки, по умолчанию 64.
    ///   - autoScrollMaximumSpeed: Максимальная скорость, по умолчанию 9.
    ///   - folderTitle: Название новой папки, по умолчанию пусто.
    ///   - mergeHoverDuration: Удержание до слияния, по умолчанию 0.6 с.
    ///   - mergeHoverDisplacement: Допуск смещения, по умолчанию 10 pt.
    ///   - mergeHighlightScale: Масштаб «впитывания», по умолчанию 1.08.
    ///   - mergeHighlightDuration: Длительность подсветки, по умолчанию 0.2 с.
    ///   - magnetSnapRadius: Радиус притяжения к слоту, по умолчанию 28 pt.
    ///   - magnetSpringDuration: Длительность spring-подъезда, по умолчанию 0.2 с.
    ///   - magnetSpringDamping: Демпфирование spring, по умолчанию 0.82.
    public init(
        seed: UInt64 = 0xE4_0004_0000_0001,
        jiggleAngle: CGFloat = 1.2,
        jiggleDuration: TimeInterval = 0.4,
        liftScale: CGFloat = 0.95,
        controlDiameter: CGFloat = 28,
        autoScrollEdge: CGFloat = 64,
        autoScrollMaximumSpeed: CGFloat = 9,
        folderTitle: String = "",
        mergeHoverDuration: TimeInterval = 0.6,
        mergeHoverDisplacement: CGFloat = 10,
        mergeHighlightScale: CGFloat = 1.08,
        mergeHighlightDuration: TimeInterval = 0.2,
        magnetSnapRadius: CGFloat = 28,
        magnetSpringDuration: TimeInterval = 0.2,
        magnetSpringDamping: CGFloat = 0.82
    ) {
        self.seed = seed
        self.jiggleAngle = jiggleAngle
        self.jiggleDuration = jiggleDuration
        self.liftScale = liftScale
        self.controlDiameter = controlDiameter
        self.autoScrollEdge = autoScrollEdge
        self.autoScrollMaximumSpeed = autoScrollMaximumSpeed
        self.folderTitle = folderTitle
        self.mergeHoverDuration = mergeHoverDuration
        self.mergeHoverDisplacement = mergeHoverDisplacement
        self.mergeHighlightScale = mergeHighlightScale
        self.mergeHighlightDuration = mergeHighlightDuration
        self.magnetSnapRadius = magnetSnapRadius
        self.magnetSpringDuration = magnetSpringDuration
        self.magnetSpringDamping = magnetSpringDamping
    }
}

// MARK: - Координатор

/// Координатор режима редактирования рабочего стола
/// (docs/STARTSCREEN-IOS-DESIGN.md §5; D14/D15 в docs/STATE.md).
///
/// ## Использование
///
/// ```swift
/// let editor = TesseraTileEditCoordinator(grid: grid, store: store)
/// editor.delegate = self
/// grid.onTap = { item in
///     switch item {
///     case .tile(let tile) where !editor.isEditing: tile.action()
///     case .folder(let folder): editor.openFolder(folder)   // D14: экран папки
///     default: break
///     }
/// }
/// // Жест долгого нажатия координатор ставит сам; отдельно `grid.onLongPress`
/// // задавать не нужно.
/// ```
///
/// ## Что делает координатор
///
/// - **вход**: long-press по плитке или пустому месту → режим редактирования;
///   по плитке сразу поднимается drag-сессия (как в iOS home);
/// - **«желе»**: мягкая синусоидальная `CAKeyframeAnimation` поворота ±1,2°
///   за цикл 0,4 с с детерминированной фазой на каждую плитку; при Reduce
///   Motion анимации нет — остаются кнопки открепления;
/// - **димминг** (E8.2): при входе в режим все плитки, кроме выбранной
///   (той, по которой было долгое нажатие), гаснут до opacity 0,7; во время
///   drag полной яркости остаются снимок и плитка-цель под пальцем, а при
///   выходе яркость восстанавливается;
/// - **unpin**: булавка (`pin.slash`) → fly-out снимка плитки, затем
///   `TileStore.unpin`;
/// - **resize**: стрелка → циклическая смена размера из поддерживаемых
///   (по умолчанию — все четыре, помещающиеся в текущее число колонок) через
///   `TileStore.resize(_:to:columns:)` и переупаковку layout; при увеличении
///   плитка остаётся на месте, а конфликтующие соседи уходят вниз (E8.7);
/// - **drag**: собственный координатор — снимок едет за пальцем и слегка
///   уменьшается (0.95, спека WP: плитка «отделяется» от плоскости, а не
///   приближается), на месте остаётся пустышка; при наведении на плитку-цель
///   порядок пересобирается push-физикой (E8.4): перетаскиваемая встаёт в слот
///   цели, а при движении снизу вверх цель и плитки под ней сдвигаются на одну
///   позицию вниз (при движении сверху вниз освободившийся слот заполняется
///   сдвигом вверх). Это **превью без записи в модель**; при отпускании порядок
///   фиксируется одним `TileStore.move`; автопрокрутка у краёв; при подходе
///   пальца к центру слота той же размерности снимок притягивается к ячейке
///   (E8.9) — короткий spring, не влияющий на цели E8.4/E8.6;
/// - **папки** (D14): перетаскивание ярлыка на папку — `addToFolder`; на центр
///   ярлыка — удержание (E8.6): пока палец стоит над целью меньше 600 мс или
///   уходит больше чем на 10 pt, drop делает обычную перестановку E8.4, а после
///   удержания цель подсвечивается «впитыванием» и drop вызывает `createFolder`
///   + `addToFolder`. Всё через `TileStore.approval`; отказ → анимация возврата
///   на место. Экран папки — минимальный sheet (`TesseraFolderViewController`),
///   в нём долгое нажатие на ярлык открывает меню «переместить в другую папку /
///   на рабочий стол», которое вызывает `TileStore.moveBetweenFolders` (тоже
///   через одобрение).
///
/// ## Ограничения
///
/// - сетка не должна одновременно использовать свой `onLongPress` для другой
///   цели: координатор ставит собственный жест долгого нажатия; если хост всё же
///   задал `grid.onLongPress`, передайте оттуда `handleLongPress(on:at:)` —
///   дублирующий вызов игнорируется;
/// - в режиме редактирования хост должен сам решить, что делать с тапом по
///   плитке (`editor.isEditing`); координатор тапы не перехватывает, чтобы не
///   отбирать у хоста навигацию;
/// - перетаскивание ярлыков между папками выполняется из экрана папки меню,
///   а не drag-жестом (drag между двумя sheet-экранами в v1 не поддерживается).
public final class TesseraTileEditCoordinator: NSObject {

    // MARK: - Публичные настройки

    /// Наблюдатель событий редактирования.
    public weak var delegate: TesseraTileEditCoordinatorDelegate?

    /// Параметры «желе», drag и папок.
    ///
    /// Изменение на лету перезапускает анимации: фазы пересчитываются от нового
    /// seed, кнопки пересоздаются с новым диаметром. Текущее удержание при этом
    /// снимается (E8.6): порог и допуск могли измениться, и продолжать отсчёт
    /// по старым значениям было бы нечестно.
    public var configuration: TesseraTileEditConfiguration {
        didSet {
            jiggleSpecs.removeAll()
            // E8.6: порог и допуск удержания могли измениться — текущее
            // удержание пересчитывать нечестно, проще снять его: подсветка
            // вернётся к обычной, а новое удержание взведётся при повторном
            // входе пальца на центр ярлыка.
            resetMergeHover()
            // E8.9: радиус и spring притяжения могли измениться — снимаем
            // текущее притяжение, чтобы следующий шаг drag начался от того
            // кадра, который видит пользователь.
            resetDragMagnet()
            guard isEditing else { return }
            for control in editControls.values {
                control.layer.removeAnimation(forKey: TesseraTileEditCoordinator.jiggleKey)
            }
            for item in grid.items {
                if let cell = grid.cellView(forItemID: item.id) as? TesseraTileCell {
                    cell.contentView.layer.removeAnimation(
                        forKey: TesseraTileEditCoordinator.jiggleKey
                    )
                }
            }
            reconcileEditControls(animated: false)
        }
    }

    /// Включён ли режим редактирования (жесты и кнопки).
    ///
    /// При `false` координатор не реагирует на long-press и сворачивает текущий
    /// режим редактирования. По умолчанию `true`.
    public var isEnabled: Bool = true {
        didSet {
            guard oldValue != isEnabled else { return }
            longPressRecognizer.isEnabled = isEnabled
            if !isEnabled {
                endEditing()
            }
        }
    }

    /// Дополнительный фильтр поддерживаемых размеров для конкретного элемента.
    ///
    /// В модели ярлыка нет списка поддерживаемых размеров (D12), поэтому по
    /// умолчанию координатор разрешает все размеры D15, которые помещаются в
    /// текущее число колонок сетки. Хост может сузить набор: например, запретить
    /// `large` для ярлыков конкретного приложения. Пустой массив трактуется как
    /// «использовать набор по умолчанию».
    public var supportedSizesProvider: ((TileGridItem) -> [TileSize])?

    /// Контроллер, от которого показывать экран папки.
    ///
    /// Если не задан, координатор идёт по цепочке респондеров от сетки
    /// (`UIView.next`) и показывает sheet от ближайшего `UIViewController`.
    public var presentingViewControllerProvider: (() -> UIViewController?)?

    /// Хост-обработчик открытия папки.
    ///
    /// Если задан, координатор не показывает встроенный экран, а отдаёт папку
    /// хосту (например, для собственного контроллера папки). Если не задан —
    /// открывается минимальный `TesseraFolderViewController`.
    public var onFolderOpen: ((TileFolder) -> Void)?

    /// Провайдер Reduce Motion (docs/STARTSCREEN-IOS-DESIGN.md §9).
    ///
    /// По умолчанию читается системная настройка через
    /// ``TesseraAccessibility/isReduceMotionEnabled``. Значение спрашивается в
    /// момент решения: включение Reduce Motion во время сеанса редактирования
    /// сразу убирает «желе» и сокращает анимации.
    public var isReduceMotionEnabled: () -> Bool = {
        TesseraAccessibility.isReduceMotionEnabled
    }

    /// Текущий режим редактирования.
    public private(set) var isEditing: Bool = false

    /// Идёт ли перетаскивание прямо сейчас.
    public var isDragging: Bool {
        dragSession != nil
    }

    /// Покачиваются ли плитки сейчас (режим редактирования без Reduce Motion).
    public var isJiggling: Bool {
        isEditing && !isReduceMotionEnabled()
    }

    // MARK: - Внутреннее состояние

    /// Сетка, которой владеет координатор жестов и оверлеев.
    private let grid: TesseraTileGridView

    /// Единственный писатель модели (§6).
    private let store: TileStore

    /// Жест «вход в редактирование + перетаскивание».
    private let longPressRecognizer = UILongPressGestureRecognizer()

    /// Жест «тап по пустому месту — выйти из редактирования».
    private let backgroundTapRecognizer = UITapGestureRecognizer()

    /// Наблюдение за прокруткой коллекции: кнопки должны ездить вместе с плитками.
    private var scrollObservation: NSKeyValueObservation?

    /// Подписка на изменения `TileStore`, сделанные не координатором (хост,
    /// экран папки): кнопки должны появиться/исчезнуть без прокрутки.
    private var storeCancellable: AnyCancellable?

    /// Тикер автопрокрутки у краёв во время drag.
    private var displayLink: CADisplayLink?

    /// Слабый мост к координатору для `CADisplayLink` (без цикла удержания).
    private let displayLinkProxy = TesseraTileEditTickerProxy()

    /// Активная drag-сессия; `nil` — перетаскивания нет.
    private var dragSession: TesseraTileDragSession?

    /// Аниматор переезда пустышки (E8.8).
    ///
    /// Удерживается, чтобы следующая цель под пальцем могла остановить прошлый
    /// переезд в текущей точке: `UIViewPropertyAnimator` не поддерживает
    /// `.beginFromCurrentState`, а без остановки новая анимация началась бы от
    /// конечного кадра предыдущей (модель слоя обновляется сразу) — пустышка
    /// прыгала бы при быстрой смене цели.
    private var placeholderAnimator: UIViewPropertyAnimator?

    /// State-машина удержания над ярлыком-целью (E8.6).
    ///
    /// Живёт только во время drag и только пока палец над центром ярлыка,
    /// на котором можно собрать папку. `nil` — удержания нет (цель другая,
    /// таймер ещё не взведён или удержание уже сброшено).
    private var mergeTracker: TesseraMergeHoverTracker?

    /// Таймер удержания (E8.6); `nil` — отсчёт не идёт.
    ///
    /// Отдельный `Timer`, а не тикер автопрокрутки: `CADisplayLink` крутится
    /// каждый кадр и на простое, а решение «удержание выдержано» нужно ровно
    /// один раз через `mergeHoverDuration`.
    private var mergeTimer: Timer?

    /// Кнопки «открепить»/«размер» поверх видимых плиток, по идентификатору.
    private var editControls: [AnyHashable: TesseraTileEditControlView] = [:]

    /// Фазы «желе» по идентификатору плитки (кеш до смены конфигурации).
    private var jiggleSpecs: [AnyHashable: TesseraJiggleSpec] = [:]

    /// Ячейки, которым координатор выставил custom actions (чтобы снять их в конце).
    private var cellsWithEditActions: [ObjectIdentifier: TesseraTileCell] = [:]

    /// Идентификатор, для которого ячейке выставлены custom actions (пропуск повторов).
    private var editActionsItemByCell: [ObjectIdentifier: AnyHashable] = [:]

    /// Подсветка плитки-цели при перетаскивании.
    private var dropHighlightView: TesseraTileDropHighlightView?

    /// Плитка, которая остаётся полной яркости в дим-поле (E8.2).
    ///
    /// Выставляется при входе в редактирование long-press'ом по плитке и при
    /// старте drag; при входе с пустого места равен `nil`, и тогда гаснут все
    /// плитки. Во время drag его перекрывает перетаскиваемая плитка: полной
    /// яркости остаются снимок и цель под пальцем (см.
    /// ``dimmingTargetAlpha(for:)``).
    private var dimmingFocusID: AnyHashable?

    /// Прозрачность невыбранной плитки в режиме редактирования (E8.2).
    ///
    /// 0,7 — из спеки WP: плитки остаются читаемыми и доступными для действий,
    /// но фон визуально уходит назад, а выбранная/перетаскиваемая — вперёд.
    private static let dimmedTileAlpha: CGFloat = 0.7

    /// Длительность перехода димминга (E8.2).
    ///
    /// Короткая, чтобы режим «включался» без паузы; при Reduce Motion не
    /// используется — прозрачность меняется мгновенно (сам дим остаётся, это не
    /// движение).
    private static let dimmingDuration: TimeInterval = 0.18

    /// Отложенная сверка кнопок: не выполняет layout внутри колбэка прокрутки.
    private var hasScheduledReconcile = false

    /// Значение ``TileStore/autosaves`` до начала drag.
    ///
    /// С E8.4 модель за время drag не меняется вовсе: порядок соседей — превью
    /// в сетке. Но drop может состоять из нескольких мутаций (создание папки +
    /// добавление ярлыка) или одной перестановки, и сохранять состояние нужно
    /// один раз по завершении, а не после каждой операции. Поэтому на время drag
    /// автосохранение выключается и восстанавливается в
    /// ``endDragStoreTransaction(saveIfNeeded:)``.
    private var autosavesBeforeDrag: Bool?

    /// Ключ анимации «желе» на слое.
    private static let jiggleKey = "tessera.edit.jiggle"

    // MARK: - Инициализация

    /// Создаёт координатор и ставит жесты на сетку.
    ///
    /// - Parameters:
    ///   - grid: Сетка рабочего стола (E4.2). Координатор удерживает её сильно:
    ///     жест и оверлеи не могут существовать без неё.
    ///   - store: Единственный писатель модели (§6).
    ///   - configuration: Параметры «желе», drag и папок.
    public init(
        grid: TesseraTileGridView,
        store: TileStore,
        configuration: TesseraTileEditConfiguration = TesseraTileEditConfiguration()
    ) {
        self.grid = grid
        self.store = store
        self.configuration = configuration
        super.init()

        displayLinkProxy.coordinator = self
        setUpGestures()
        observeScrollView()
        observeStore()
        observeNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        scrollObservation?.invalidate()
        scrollObservation = nil
        displayLink?.invalidate()
        displayLink = nil

        // E8.6: таймер удержания держит замыкание на координатор — снимаем его
        // до того, как уйдут оверлеи.
        mergeTimer?.invalidate()
        mergeTimer = nil
        mergeTracker = nil

        // E8.9: spring притяжения держит замыкание на сессию с видом снимка —
        // останавливаем его до того, как сетка и оверлеи уйдут из иерархии.
        dragSession?.magnetAnimator?.stopAnimation(true)
        dragSession?.magnetAnimator = nil

        if let wasEnabled = autosavesBeforeDrag {
            autosavesBeforeDrag = nil
            store.autosaves = wasEnabled
        }

        grid.removeGestureRecognizer(longPressRecognizer)
        grid.removeGestureRecognizer(backgroundTapRecognizer)

        // E8.4: незавершённое превью — состояние сетки, а не модели. Возвращаем
        // базовый порядок, чтобы координатор не оставил после себя чужой экран.
        if let session = dragSession {
            grid.update(snapshot: session.baseSnapshot, animated: false)
        }

        // Оверлеи — подвью сетки: если их не убрать, они переживут координатор.
        for control in editControls.values {
            control.removeFromSuperview()
        }
        editControls.removeAll()
        dropHighlightView?.removeFromSuperview()
        dropHighlightView = nil
        dragSession?.dragView.removeFromSuperview()
        dragSession?.placeholder.removeFromSuperview()
        stopPlaceholderAnimation()
        dragSession = nil

        for cell in cellsWithEditActions.values {
            cell.accessibilityCustomActions = nil
        }
        cellsWithEditActions.removeAll()
        editActionsItemByCell.removeAll()

        for item in grid.items {
            if let cell = grid.cellView(forItemID: item.id) as? TesseraTileCell {
                cell.contentView.layer.removeAnimation(
                    forKey: TesseraTileEditCoordinator.jiggleKey
                )
                // E8.2: не оставляем плитки в дим-поле после ухода координатора.
                // Полностью скрытую (alpha 0) плитку не трогаем: этим состоянием
                // владеет сетка (`setSourceHidden`), а не димминг.
                if cell.contentView.alpha > 0 {
                    cell.contentView.alpha = 1
                }
            }
        }
        dimmingFocusID = nil
    }

    /// Ставит жесты: long-press (вход + drag) и tap по фону (выход).
    private func setUpGestures() {
        longPressRecognizer.minimumPressDuration = 0.45
        longPressRecognizer.allowableMovement = 12
        longPressRecognizer.delegate = self
        longPressRecognizer.addTarget(
            self,
            action: #selector(handleLongPressGesture(_:))
        )
        grid.addGestureRecognizer(longPressRecognizer)

        backgroundTapRecognizer.delegate = self
        backgroundTapRecognizer.cancelsTouchesInView = false
        backgroundTapRecognizer.isEnabled = false
        backgroundTapRecognizer.addTarget(
            self,
            action: #selector(handleBackgroundTap(_:))
        )
        grid.addGestureRecognizer(backgroundTapRecognizer)
    }

    /// Подписывается на прокрутку коллекции внутри сетки.
    ///
    /// Сетка не отдаёт хост-колбэк прокрутки, свободный от параллакса (§8), а
    /// кнопкам редактирования нужно ехать вместе с плитками. Поэтому координатор
    /// слушает `contentOffset` самой коллекции: в обработчике только `frame` и
    /// `isHidden`, без пересчёта layout (§3, CORE-IOS-DESIGN.md §2).
    private func observeScrollView() {
        guard let scrollView = TesseraTileEditCoordinator.findScrollView(in: grid) else {
            return
        }
        scrollObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            self?.scrollOffsetDidChange()
        }
    }

    /// Подписывается на изменения хранилища, чтобы сверять кнопки после
    /// внешних правок (pin/unpin из списка приложений, экран папки).
    ///
    /// `objectWillChange` приходит до изменения и без снимка, поэтому сверка
    /// откладывается на следующий проход runloop — к этому моменту хост уже
    /// применит снимок к сетке.
    private func observeStore() {
        storeCancellable = store.objectWillChange.sink { [weak self] in
            guard let self, self.isEditing else { return }
            self.scheduleReconcile()
        }
    }

    /// Подписки на Reduce Motion и уход приложения в фон.
    private func observeNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reduceMotionStatusDidChange),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    // MARK: - Режим редактирования

    /// Входит в режим редактирования: «желе», димминг и кнопки.
    ///
    /// Повторный вызов ничего не делает. При Reduce Motion «желе» и анимация
    /// димминга не запускаются, но сам дим, кнопки и custom actions появляются
    /// (§9).
    public func beginEditing() {
        beginEditing(focusing: nil)
    }

    /// Общая реализация входа с указанием «выбранной» плитки (E8.2).
    ///
    /// - Parameter itemID: Плитка, по которой вошли long-press'ом; она остаётся
    ///   полной яркости, остальные гаснут до ``dimmedTileAlpha``. `nil` — вход
    ///   с пустого места, гаснут все плитки.
    private func beginEditing(focusing itemID: AnyHashable?) {
        guard !isEditing, isEnabled else { return }

        isEditing = true
        dimmingFocusID = itemID
        backgroundTapRecognizer.isEnabled = true
        reconcileEditControls(animated: false, dimAnimated: true)
        // Ячейки могут быть ещё не созданы (первый layout/показ): доберём
        // кнопки, «желе» и димминг на следующем проходе runloop.
        scheduleReconcile()

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        announce("Режим редактирования.")
        delegate?.tileEditCoordinatorDidBeginEditing(self)
    }

    /// Выходит из режима редактирования и снимает активное перетаскивание.
    ///
    /// E8.4: модель за время drag не менялась (порядок — превью в сетке),
    /// поэтому откат — это возврат сетке снимка на момент захвата, без записи в
    /// `TileStore`: незавершённый drag не оставляет модель в промежуточном
    /// состоянии. Димминг снимается короткой анимацией (E8.2); при Reduce
    /// Motion яркость возвращается сразу.
    public func endEditing() {
        guard isEditing else { return }

        cancelDragImmediately()
        isEditing = false
        dimmingFocusID = nil
        backgroundTapRecognizer.isEnabled = false
        removeAllEditControls()
        removeAllJiggle()
        // Возвращаем яркость всем плиткам; к этому моменту drag уже снят и
        // скрытых координатором ячеек нет.
        applyEditDimming(animated: true)

        announce("Режим редактирования завершён.")
        delegate?.tileEditCoordinatorDidEndEditing(self)
    }

    /// Переключает режим редактирования.
    public func toggleEditing() {
        if isEditing {
            endEditing()
        } else {
            beginEditing()
        }
    }

    /// Вход в редактирование и сразу drag элемента (для хоста, который ведёт
    /// собственный long-press вместо встроенного).
    ///
    /// Встроенный жест координатора вызывает этот же метод; повторный вызов во
    /// время уже начатого drag игнорируется, поэтому дублирование безопасно.
    /// Плитка передаётся в ``beginEditing(focusing:)`` как выбранная: до старта
    /// drag она полной яркости, остальные сразу гаснут (E8.2).
    ///
    /// - Parameters:
    ///   - item: Элемент, по которому было долгое нажатие.
    ///   - point: Точка нажатия в координатах сетки (как в
    ///     `TesseraTileGridView.onLongPress`).
    public func handleLongPress(on item: TileGridItem, at point: CGPoint) {
        guard isEnabled, grid.window != nil, dragSession == nil else { return }
        guard grid.index(ofItemID: item.id) != nil else { return }

        if !isEditing {
            beginEditing(focusing: item.id)
        }
        startDrag(itemID: item.id, at: point)
    }

    /// Пересчитывает положение кнопок редактирования.
    ///
    /// Нужен после поворота экрана, смены ширины контейнера или
    /// `invalidateTileLayout(animated:)` — координатор не подписан на bounds
    /// сетки, чтобы не дублировать layout-проходы.
    public func refreshEditControls() {
        guard isEditing else { return }
        reconcileEditControls(animated: false)
    }

    // MARK: - Unpin

    /// Открепляет ярлык с fly-out анимацией (§5).
    ///
    /// Сначала проигрывается анимация снимка ячейки, затем вызывается
    /// ``TileStore/unpin(_:)`` — модель меняется, когда плитка уже улетела.
    /// Если хранилище отказывает, ячейка возвращается на место.
    ///
    /// Папку открепить нельзя (она существует, пока в ней есть ярлыки), поэтому
    /// для папки метод ничего не делает. Ярлык внутри папки на сетке не показан:
    /// для него операция сразу идёт в хранилище.
    ///
    /// - Parameter tileID: Идентификатор ярлыка.
    public func unpin(_ tileID: AnyHashable) {
        guard dragSession == nil else { return }

        guard let item = grid.items.first(where: { $0.id == tileID }) else {
            // Ярлык лежит в папке или уже откреплён — анимировать нечего.
            performImmediateUnpin(tileID)
            return
        }
        guard item.tile != nil else { return }

        guard let cell = grid.cellView(forItemID: tileID) as? TesseraTileCell,
              let frame = grid.frame(forItemID: tileID),
              let snapshot = TesseraTileEditCoordinator.makeSnapshot(of: cell) else {
            performImmediateUnpin(tileID)
            return
        }

        removeControl(for: tileID)
        cell.contentView.layer.removeAnimation(forKey: TesseraTileEditCoordinator.jiggleKey)
        grid.setItemHidden(true, forItemID: tileID)

        snapshot.frame = frame
        snapshot.isUserInteractionEnabled = false
        snapshot.layer.zPosition = 1000
        snapshot.layer.shadowColor = UIColor.black.cgColor
        snapshot.layer.shadowOpacity = 0.2
        snapshot.layer.shadowRadius = 12
        snapshot.layer.shadowOffset = CGSize(width: 0, height: 6)
        grid.addSubview(snapshot)

        let reduceMotion = isReduceMotionEnabled()
        UIView.animate(
            withDuration: reduceMotion ? 0.12 : 0.22,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseIn],
            animations: {
                snapshot.alpha = 0
                if !reduceMotion {
                    // frame при не-единичном transform не определён — меняем
                    // bounds/center, как требует UIKit.
                    snapshot.bounds = CGRect(
                        origin: .zero,
                        size: CGSize(width: frame.width * 0.35, height: frame.height * 0.35)
                    )
                    snapshot.center = CGPoint(x: frame.midX, y: frame.midY - 48)
                }
            },
            completion: { [weak self] _ in
                snapshot.removeFromSuperview()
                guard let self else { return }

                let removed = self.store.unpin(tileID)
                self.grid.setItemHidden(false, forItemID: tileID)

                guard removed else {
                    self.reconcileEditControls(animated: false)
                    return
                }

                self.render(animated: true)
                self.delegate?.tileEditCoordinator(self, didUnpin: tileID)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.announce("Ярлык откреплён.")
            }
        )
    }

    /// Немедленное открепление без анимации (ячейка вне экрана/ярлык в папке).
    ///
    /// - Parameter tileID: Идентификатор ярлыка.
    private func performImmediateUnpin(_ tileID: AnyHashable) {
        guard store.unpin(tileID) else { return }
        render(animated: true)
        delegate?.tileEditCoordinator(self, didUnpin: tileID)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        announce("Ярлык откреплён.")
    }

    // MARK: - Resize

    /// Циклически меняет размер элемента: small → medium → wide → large → small
    /// (docs/STARTSCREEN-IOS-DESIGN.md §5, D15).
    ///
    /// Поддерживаемые размеры по умолчанию — все четыре, которые помещаются в
    /// число колонок сетки (широкая плитка требует четырёх). Хост может сузить
    /// набор через ``supportedSizesProvider``. Переупаковку выполняет
    /// `TileStore` + `TesseraTileGridView.update(snapshot:animated:)`: раскладка
    /// пересчитывается `TileLayoutEngine`, соседи переезжают batch-анимацией.
    ///
    /// E8.7: координатор передаёт хранилищу реальное число колонок сетки, и
    /// resize идёт через `TileStore.resize(_:to:columns:)` — увеличиваемая
    /// плитка по возможности остаётся на месте, а плитки, попавшие в её новый
    /// след справа или снизу, уходят вниз (``TileLayoutEngine/resizePlacement``).
    ///
    /// - Parameter itemID: Идентификатор ярлыка или папки.
    /// - Returns: Новый размер или `nil`, если менять нечего.
    @discardableResult
    public func cycleSize(of itemID: AnyHashable) -> TileSize? {
        guard dragSession == nil,
              let item = grid.items.first(where: { $0.id == itemID }) else {
            return nil
        }

        let sizes = supportedSizes(for: item)
        guard sizes.count > 1 else { return nil }

        let currentIndex = sizes.firstIndex(of: item.size) ?? -1
        let next = sizes[(currentIndex + 1) % sizes.count]
        guard next != item.size,
              store.resize(itemID, to: next, columns: grid.columns) else {
            return nil
        }

        render(animated: true)
        delegate?.tileEditCoordinator(self, didResize: itemID, to: next)
        UISelectionFeedbackGenerator().selectionChanged()
        announce("Размер: \(TesseraTileEditCoordinator.name(for: next)).")
        return next
    }

    /// Список размеров, доступных элементу.
    ///
    /// - Parameter item: Ярлык или папка.
    /// - Returns: Поддерживаемые размеры в порядке цикла D15; никогда не пустой.
    private func supportedSizes(for item: TileGridItem) -> [TileSize] {
        if let provider = supportedSizesProvider {
            let custom = provider(item)
            if !custom.isEmpty {
                return custom
            }
        }

        let columns = max(1, grid.columns)
        let fits = TileSize.allCases.filter { $0.unitColumns <= columns }
        return fits.isEmpty ? [.small] : fits
    }

    // MARK: - Порядок

    /// Переставляет элемент сетки через `TileStore` (§6).
    ///
    /// Операция раскладки не требует одобрения (D14). Drag использует то же
    /// правило `TileStore.move(_:toIndex:)` при фиксации drop'а (E8.4), но
    /// пишет модель только один раз — на отпускании, а не на каждом шаге.
    ///
    /// - Parameters:
    ///   - itemID: Идентификатор ярлыка или папки на сетке.
    ///   - index: Целевой индекс; хранилище зажимает значения.
    /// - Returns: `true`, если порядок изменился.
    @discardableResult
    public func move(_ itemID: AnyHashable, toIndex index: Int) -> Bool {
        guard store.move(itemID, toIndex: index) else { return false }
        render(animated: true)
        delegate?.tileEditCoordinator(self, didMove: itemID, toIndex: index)
        return true
    }

    // MARK: - Папки (D14: только через функцию одобрения хоста)

    /// Создаёт папку из ярлыка на сетке.
    ///
    /// Вся проверка — внутри ``TileStore/createFolder(withTile:title:)``: хост
    /// получает `TileGroupingAction.createFolder`; отказ оставляет модель
    /// нетронутой. Создание папки из двух ярлыков drop'ом делает
    /// ``TesseraTileEditCoordinator`` сам (два одобренных шага: создание,
    /// затем добавление).
    ///
    /// - Parameters:
    ///   - tileID: Ярлык, который станет первым содержимым папки.
    ///   - title: Название; `nil` — ``TesseraTileEditConfiguration/folderTitle``.
    /// - Returns: Созданная папка или `nil`, если хост отказал.
    @discardableResult
    public func createFolder(withTile tileID: AnyHashable, title: String? = nil) -> TileFolder? {
        let folder = store.createFolder(
            withTile: tileID,
            title: title ?? configuration.folderTitle
        )
        guard let folder else {
            if grid.index(ofItemID: tileID) != nil {
                notifyGroupingFailure(.createFolder, tileID: tileID, folderID: nil)
            }
            return nil
        }

        render(animated: true)
        delegate?.tileEditCoordinator(self, didCreateFolder: folder)
        announce("Папка создана.")
        return folder
    }

    /// Добавляет ярлык с сетки в папку через функцию одобрения (D14).
    ///
    /// - Parameters:
    ///   - tileID: Ярлык на сетке.
    ///   - folderID: Папка-цель.
    /// - Returns: `true`, если ярлык добавлен.
    @discardableResult
    public func addToFolder(_ tileID: AnyHashable, folderID: AnyHashable) -> Bool {
        guard store.addToFolder(tileID, folderID: folderID) else {
            notifyGroupingFailure(.addToFolder, tileID: tileID, folderID: folderID)
            return false
        }

        render(animated: true)
        delegate?.tileEditCoordinator(self, didAdd: tileID, toFolder: folderID)
        announce("Ярлык добавлен в папку.")
        return true
    }

    /// Перемещает ярлык между папками или из папки на рабочий стол (D14).
    ///
    /// - Parameters:
    ///   - tileID: Ярлык, лежащий в папке.
    ///   - folderID: Папка-цель; `nil` — на рабочий стол.
    /// - Returns: `true`, если перемещение выполнено.
    @discardableResult
    public func moveBetweenFolders(_ tileID: AnyHashable, to folderID: AnyHashable?) -> Bool {
        guard store.moveBetweenFolders(tileID, to: folderID) else {
            notifyGroupingFailure(.moveBetweenFolders, tileID: tileID, folderID: folderID)
            return false
        }

        render(animated: true)
        delegate?.tileEditCoordinator(self, didMove: tileID, toFolder: folderID)
        announce(folderID == nil ? "Ярлык на рабочем столе." : "Ярлык перемещён в папку.")
        return true
    }

    /// Открывает экран папки.
    ///
    /// Если задан ``onFolderOpen`` — папка отдаётся хосту. Иначе показывается
    /// минимальный `TesseraFolderViewController` (sheet) с содержимым папки:
    /// тап открывает ярлык, долгое нажатие — меню перемещения между папками
    /// (через ``moveBetweenFolders(_:to:)``, то есть с одобрением хоста).
    ///
    /// - Parameter folder: Папка из снимка `TileStore`.
    public func openFolder(_ folder: TileFolder) {
        if let onFolderOpen {
            onFolderOpen(folder)
            return
        }

        guard let presenter = presentingViewController() else { return }

        // Папка в снимке могла измениться между тапом и открытием.
        let fresh = store.snapshot().folders.first { $0.id == folder.id } ?? folder
        let controller = TesseraFolderViewController(
            folder: fresh,
            store: store,
            coordinator: self
        )
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(controller, animated: !isReduceMotionEnabled())
    }

    /// Контроллер для показа экрана папки.
    ///
    /// - Returns: Ближайший `UIViewController` от сетки или провайдер хоста.
    private func presentingViewController() -> UIViewController? {
        if let provider = presentingViewControllerProvider {
            return provider()
        }

        var responder: UIResponder? = grid
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller
            }
            responder = current.next
        }
        return nil
    }

    /// Сообщает хосту об отказе функции одобрения (D14).
    ///
    /// - Parameters:
    ///   - action: Отклонённая операция.
    ///   - tileID: Ярлык-инициатор.
    ///   - folderID: Папка-цель; `nil` для создания.
    private func notifyGroupingFailure(
        _ action: TileGroupingAction,
        tileID: AnyHashable,
        folderID: AnyHashable?
    ) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        announce("Операция с папкой недоступна.")
        delegate?.tileEditCoordinator(
            self,
            didFailGrouping: action,
            tileID: tileID,
            folderID: folderID
        )
    }

    // MARK: - Применение снимка

    /// Применяет модель к сетке, если хост ещё не сделал этого из `onChange`.
    ///
    /// Сравнение дешёвое и спасает от двойного обновления: типичный хост
    /// подписан на ``TileStore/onChange`` и сам вызывает
    /// `update(snapshot:animated:)`, а координатор вызывает этот метод сразу
    /// после мутации.
    ///
    /// - Parameter animated: Анимировать ли перестановку/размер.
    private func render(animated: Bool) {
        let snapshot = store.snapshot()

        if !gridMatches(snapshot) {
            grid.update(snapshot: snapshot, animated: animated && !isReduceMotionEnabled())
        }

        if isEditing {
            reconcileEditControls(animated: animated)
            // Новые ячейки коллекция создаёт в своём layout-проходе: повторная
            // сверка после него добавит им custom actions и «желе».
            scheduleReconcile()
        }
    }

    /// Совпадает ли текущий снимок сетки с моделью (порядок, размеры, папки).
    ///
    /// - Parameter snapshot: Снимок из `TileStore`.
    /// - Returns: `true`, если сетке нечего обновлять.
    private func gridMatches(_ snapshot: TileGridSnapshot) -> Bool {
        let currentItems = grid.items
        guard currentItems.count == snapshot.items.count else { return false }

        for (current, expected) in zip(currentItems, snapshot.items) {
            guard current.id == expected.id, current.size == expected.size else {
                return false
            }
            if let currentFolder = current.folder, let expectedFolder = expected.folder {
                guard currentFolder.title == expectedFolder.title,
                      currentFolder.tiles.map({ $0.id }) == expectedFolder.tiles.map({ $0.id }) else {
                    return false
                }
            }
        }
        return true
    }

    // MARK: - Drag: старт и движение

    /// Поднимает плитку и начинает перетаскивание.
    ///
    /// Снимает копию ячейки **до** скрытия, кладёт на её место пустышку и вешает
    /// снимок поверх сетки. Модель на этом шаге не меняется.
    ///
    /// E8.4: здесь же запоминается снимок модели — базовый порядок для превью
    /// (`previewOrder`) и для отката. Во время drag `TileStore` не пишется, так
    /// что этот порядок остаётся в модели до самого drop'а.
    ///
    /// E8.2: снимок всегда полной яркости — если плитка была в дим-поле
    /// (редактирование начато с пустого места), прозрачность снимается до
    /// снятия копии, иначе в копию попал бы alpha 0,7.
    ///
    /// - Parameters:
    ///   - itemID: Идентификатор ярлыка или папки.
    ///   - point: Точка захвата в координатах сетки.
    private func startDrag(itemID: AnyHashable, at point: CGPoint) {
        guard dragSession == nil,
              let item = grid.items.first(where: { $0.id == itemID }),
              let frame = grid.frame(forItemID: itemID),
              frame.intersects(grid.bounds),
              let initialIndex = grid.index(ofItemID: itemID),
              let placeholder = grid.placeholderView(forItemID: itemID) else {
            return
        }

        // E8.2: плитка под пальцем становится «выбранной» и полной яркости.
        // «Желе» снимаем до снимка: копия не должна унаследовать ни дим, ни
        // текущий угол покачивания.
        if let cell = grid.cellView(forItemID: itemID) as? TesseraTileCell {
            cell.contentView.layer.removeAnimation(forKey: TesseraTileEditCoordinator.jiggleKey)
            if cell.contentView.alpha > 0 {
                cell.contentView.alpha = 1
            }
        }
        guard let dragView = makeDragView(forItemID: itemID) else {
            // Снимок не удался: возвращаем дим, чтобы плитка не осталась ярче
            // соседей без начатого drag.
            applyEditDimming(animated: false)
            return
        }
        dimmingFocusID = itemID

        beginDragStoreTransaction()

        grid.setItemHidden(true, forItemID: itemID)
        removeControl(for: itemID)

        placeholder.frame = frame
        placeholder.layer.zPosition = 500
        grid.addSubview(placeholder)

        dragView.frame = frame
        dragView.isUserInteractionEnabled = false
        dragView.layer.zPosition = 1000
        dragView.layer.shadowColor = UIColor.black.cgColor
        dragView.layer.shadowOpacity = 0.22
        dragView.layer.shadowRadius = 14
        dragView.layer.shadowOffset = CGSize(width: 0, height: 8)
        grid.addSubview(dragView)

        // E8.4: база превью — порядок модели на момент захвата. Сетка и модель
        // к этому моменту совпадают, поэтому снимок хранилища и есть то, что
        // видит пользователь.
        let session = TesseraTileDragSession(
            itemID: itemID,
            initialIndex: initialIndex,
            isTile: item.tile != nil,
            grabOffset: CGPoint(x: frame.midX - point.x, y: frame.midY - point.y),
            dragView: dragView,
            placeholder: placeholder,
            lastPoint: point,
            baseSnapshot: store.snapshot(),
            magnetSize: item.size
        )
        dragSession = session
        grid.isScrollEnabled = false

        updateHoverTargets(at: point)

        if !isReduceMotionEnabled() {
            dragView.transform = .identity
            UIView.animate(
                withDuration: 0.16,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut],
                animations: {
                    dragView.transform = CGAffineTransform(
                        scaleX: self.configuration.liftScale,
                        y: self.configuration.liftScale
                    )
                },
                completion: nil
            )
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        startTickerIfNeeded()
    }

    /// Создаёт снимок ячейки для перетаскивания.
    ///
    /// Сначала снимается копия самой ячейки с принудительным обновлением экрана
    /// (`afterScreenUpdates: true`): к этому моменту координатор уже снял с неё
    /// дим (E8.2), и снимок обязан быть полной яркости. Затем — резервный
    /// `resizableSnapshotView`; последним берётся готовый снимок сетки (он
    /// дешевле, но может не успеть показать снятый дим). Для ячейки вне экрана
    /// возвращает `nil`, и drag не начинается.
    ///
    /// - Parameter itemID: Идентификатор элемента.
    /// - Returns: Вид-снимок.
    private func makeDragView(forItemID itemID: AnyHashable) -> UIView? {
        if let cell = grid.cellView(forItemID: itemID),
           let snapshot = cell.snapshotView(afterScreenUpdates: true) {
            return snapshot
        }
        if let cell = grid.cellView(forItemID: itemID),
           let snapshot = cell.resizableSnapshotView(
               from: cell.bounds,
               afterScreenUpdates: true,
               withCapInsets: .zero
           ) {
            return snapshot
        }
        return grid.snapshotView(forItemID: itemID)
    }

    /// Ведёт снимок за пальцем и обновляет цель под ним.
    ///
    /// Внутренний шаг drag-сессии: жест координатора вызывает его из `.changed`,
    /// а тесты E4.7 — напрямую через `@testable import`, чтобы прогонять
    /// перестановку без симуляции касаний.
    ///
    /// Позицию снимка выставляет ``updateHoverTargets(at:)`` — после выбора
    /// цели: притяжение E8.9 зависит от зоны E8.6 под пальцем и не должно
    /// запускаться над панелью раскрытой папки.
    ///
    /// - Parameter point: Точка пальца в координатах сетки.
    func updateDrag(to point: CGPoint) {
        guard let session = dragSession else { return }

        session.lastPoint = point
        updateHoverTargets(at: point)
    }

    /// Пересчитывает цель под пальцем, превью порядка и подсветку.
    ///
    /// Решение принимается по рамкам сетки, а не по `grid.item(at:)`: исходная
    /// ячейка скрыта, но остаётся в раскладке и перехватила бы хит-тест.
    ///
    /// E8.4: цель `.reorder` хранит **базовый** индекс плитки-цели (порядок
    /// снимка на момент захвата), а не индекс в текущем превью — иначе индекс
    /// зависел бы от предыдущего шага и «сдвиги» накапливались бы.
    ///
    /// E8.9: в конце шага снимок ставится под палец (или притягивается к
    /// ближайшему слоту). Здесь же сбрасывается признак «палец над панелью
    /// папки»: притяжение над панелью не работает.
    ///
    /// - Parameter point: Точка пальца в координатах сетки.
    private func updateHoverTargets(at point: CGPoint) {
        guard let session = dragSession else { return }

        // E8.9: признак пересчитывается на каждом шаге, а не только при смене
        // цели: панель могла уехать вместе с автопрокруткой.
        session.isOverFolderPanel = false

        var target: HoverTarget = .none

        if grid.bounds.insetBy(dx: -8, dy: -8).contains(point),
           let hovered = item(under: point, excluding: session.itemID),
           let frame = grid.frame(forItemID: hovered.id),
           let baseIndex = session.baseIndex(of: hovered.id) {

            switch hovered {
            case .folder(let folder):
                if session.isTile {
                    // Ярлык над папкой — добавление (D14), папка не переезжает.
                    target = .folder(folder.id)
                } else {
                    // Перетаскивание папки по сетке — обычная перестановка.
                    target = .reorder(hovered.id, index: baseIndex)
                }

            case .tile(let tile):
                if session.isTile, isPointInDropCenter(point, of: frame) {
                    // Центр ярлыка — создание папки из двух ярлыков (D14).
                    target = .group(tile.id)
                } else {
                    target = .reorder(hovered.id, index: baseIndex)
                }

            case .folderContent:
                // Панель раскрытой папки (D17) не цель перетаскивания в E7.1:
                // её место в раскладке фиксировано, а взаимодействие с
                // содержимым панели появится в E7.3. E8.9: и притяжения над
                // панелью нет — она сдвигает строки, и виртуальная сетка под
                // ней не совпадала бы с фактическими слотами.
                session.isOverFolderPanel = true
            }
        }

        applyDragPreview(for: target, session: session)

        // E8.6: удержание над центром ярлыка взводится/сбрасывается на каждом
        // шаге — до обновления подсветки, чтобы она сразу показала «впитывание»,
        // если удержание уже выдержано.
        let hoverChanged = session.hover != target
        session.hover = target
        updateMergeHover(for: target, at: point)

        if hoverChanged {
            updateDropHighlight(for: target)
        } else {
            updateDropHighlightFrame()
        }

        // E8.9: снимок ведётся за пальцем после выбора цели. Притяжение —
        // только визуальный слой: цели E8.4/E8.6 считаются по точке пальца,
        // поэтому порядок и таймер слияния от него не зависят.
        updateDragViewPosition(for: point, session: session)
    }

    // MARK: - Магнитизм к ячейкам (E8.9)

    /// Ставит снимок под палец или притягивает его к центру ближайшего слота.
    ///
    /// Без притяжения снимок следует за пальцем 1:1 (E8.1), как и до E8.9.
    /// В радиусе слота он плавно подъезжает к центру коротким spring'ом; пока
    /// цель та же, анимация не перезапускается — иначе на каждом событии
    /// касания плитка «дёргалась» бы. За радиусом spring снимается и снимок
    /// снова жёстко следует за пальцем.
    ///
    /// - Parameters:
    ///   - point: Точка пальца в координатах сетки.
    ///   - session: Активная drag-сессия.
    private func updateDragViewPosition(for point: CGPoint, session: TesseraTileDragSession) {
        let followCenter = CGPoint(
            x: point.x + session.grabOffset.x,
            y: point.y + session.grabOffset.y
        )

        // Пока палец ни разу не вышел из радиуса притяжения от точки захвата,
        // магнит не включаем: снимок и так стоит в исходном слоте, и без этого
        // правила плитка «залипала» бы на месте захвата на первые ~28 pt
        // движения.
        updateMagnetEngagement(for: point, session: session)

        guard let target = magnetTarget(for: point, session: session) else {
            stopMagnetAnimation(session)
            session.magnetTarget = nil
            if session.dragView.center != followCenter {
                session.dragView.center = followCenter
            }
            return
        }

        // Та же цель: spring уже едет в неё (или доехал) — не трогаем.
        guard session.magnetTarget != target else { return }
        session.magnetTarget = target

        // Ячейка под снимком совпала с целью — анимировать нечего (например,
        // захват ровно за центр плитки на её же слоте).
        guard session.dragView.center != target else { return }

        animateDragView(session, to: target)
    }

    /// Включает притяжение после того, как палец покинул стартовую зону (E8.9).
    ///
    /// На захвате снимок уже стоит в исходном слоте, поэтому «притягивать»
    /// плитку к нему нечего: без этого флага снимок оставался бы
    /// пришпиленным к стартовому центру, пока палец не отойдёт от него на
    /// полный радиус, — первые точки движения не следовали бы за пальцем.
    /// Флаг взводится один раз за сессию и дальше не снимается.
    ///
    /// - Parameters:
    ///   - point: Точка пальца в координатах сетки.
    ///   - session: Активная drag-сессия.
    private func updateMagnetEngagement(for point: CGPoint, session: TesseraTileDragSession) {
        guard !session.hasLeftOriginSlot else { return }

        let radius = configuration.magnetSnapRadius
        guard radius.isFinite, radius > 0 else { return }

        let dx = point.x - session.originPoint.x
        let dy = point.y - session.originPoint.y
        guard dx * dx + dy * dy > radius * radius else { return }

        session.hasLeftOriginSlot = true
    }

    /// Центр слота, к которому нужно притянуть снимок, или `nil`.
    ///
    /// Притяжение отключено:
    /// - при Reduce Motion — снимок остаётся строго под пальцем (E8.1);
    /// - при нулевом/нечисловом ``TesseraTileEditConfiguration/magnetSnapRadius``;
    /// - пока палец не вышел из стартовой зоны захвата (``TesseraTileDragSession/hasLeftOriginSlot``);
    /// - над панелью раскрытой папки;
    /// - над целями группировки (папка и центр ярлыка — зона E8.6): в этих
    ///   местах снимок не должен уезжать из-под пальца, пока пользователь
    ///   держит удержание или целится в папку.
    ///
    /// - Parameters:
    ///   - point: Точка пальца в координатах сетки.
    ///   - session: Активная drag-сессия.
    /// - Returns: Центр ближайшего слота в радиусе или `nil`.
    private func magnetTarget(for point: CGPoint, session: TesseraTileDragSession) -> CGPoint? {
        guard configuration.magnetSnapRadius > 0, !isReduceMotionEnabled() else { return nil }
        guard !session.isOverFolderPanel else { return nil }
        guard session.hasLeftOriginSlot else { return nil }

        switch session.hover {
        case .folder, .group:
            return nil
        case .none, .reorder:
            break
        }

        return TesseraTileMagnet.magnetTarget(
            for: point,
            slotCenters: grid.magnetSlotCenters(for: session.magnetSize),
            snapRadius: configuration.magnetSnapRadius
        )
    }

    /// Плавно подъезжает снимком к центру слота (E8.9).
    ///
    /// Предыдущий spring останавливается в текущем кадре презентации, чтобы
    /// новая анимация началась без прыжка (тот же приём, что у пустышки в
    /// E8.8). Длительность и демпфирование — из
    /// ``TesseraTileEditConfiguration/magnetSpringDuration`` и
    /// ``TesseraTileEditConfiguration/magnetSpringDamping``; нулевая
    /// длительность даёт мгновенную перестановку.
    ///
    /// - Parameters:
    ///   - session: Активная drag-сессия.
    ///   - center: Целевой центр снимка в координатах сетки.
    private func animateDragView(_ session: TesseraTileDragSession, to center: CGPoint) {
        stopMagnetAnimation(session)

        let duration = configuration.magnetSpringDuration
        guard duration.isFinite, duration > 0 else {
            session.dragView.center = center
            return
        }

        let damping = configuration.magnetSpringDamping.isFinite
            ? min(max(configuration.magnetSpringDamping, 0.01), 1)
            : 0.82
        // Замыкание держит только вид-снимок: аниматор принадлежит сессии, и
        // захват самой сессии дал бы цикл «сессия → аниматор → сессия».
        let dragView = session.dragView
        let animator = UIViewPropertyAnimator(
            duration: duration,
            timingParameters: UISpringTimingParameters(dampingRatio: damping)
        )
        animator.addAnimations {
            dragView.center = center
        }
        animator.startAnimation()
        session.magnetAnimator = animator
    }

    /// Останавливает spring притяжения, оставляя снимок в текущем кадре.
    ///
    /// После `stopAnimation(true)` модель слоя могла остаться в цели прошлой
    /// анимации, поэтому её явно возвращают к presentation-кадру: следующее
    /// движение (к пальцу или к новому слоту) начнётся без скачка.
    ///
    /// - Parameter session: Активная drag-сессия.
    private func stopMagnetAnimation(_ session: TesseraTileDragSession) {
        guard let animator = session.magnetAnimator else { return }

        session.magnetAnimator = nil
        let visibleCenter = session.dragView.layer.presentation()?.position ?? session.dragView.center
        animator.stopAnimation(true)

        if session.dragView.center != visibleCenter {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            session.dragView.center = visibleCenter
            CATransaction.commit()
        }
    }

    /// Снимает текущее притяжение, не завершая drag (E8.9).
    ///
    /// Нужен при смене конфигурации: радиус и spring могли измениться, и
    /// продолжать движение по старым параметрам нечестно.
    private func resetDragMagnet() {
        guard let session = dragSession else { return }
        stopMagnetAnimation(session)
        session.magnetTarget = nil
    }

    /// Пересобирает превью порядка сетки для цели под пальцем (E8.4).
    ///
    /// Пишет **только в сетку** — `grid.update(snapshot:animated:)` гонит
    /// batch-анимацию ~0,26 с с bounce-кривой E8.8, соседи «расступаются» без
    /// записи в `TileStore`.
    /// Порядок каждый раз считается от ``TesseraTileDragSession/baseSnapshot``,
    /// а не от предыдущего превью: при перемещении между целями сдвиги не
    /// накапливаются.
    ///
    /// Для целей, которые не переставляют порядок (пустое место, папка, центр
    /// ярлыка), последнее превью остаётся как есть. Возврат к базовому порядку
    /// здесь был бы ошибкой: плитка под пальцем уже переехала вместе с превью,
    /// и хит-тест на следующем кадре дал бы попеременно `.none`/`.reorder` —
    /// соседи «мигали» бы между двумя раскладками.
    ///
    /// - Parameters:
    ///   - target: Цель под пальцем.
    ///   - session: Активная drag-сессия.
    private func applyDragPreview(for target: HoverTarget, session: TesseraTileDragSession) {
        guard case .reorder(let targetID, _) = target,
              let preview = TileLayoutEngine.previewOrder(
                  items: session.baseSnapshot.items,
                  draggingID: session.itemID,
                  targetID: targetID
              ) else {
            animatePlaceholder(to: currentFrame(of: session))
            return
        }

        guard preview.map({ $0.id }) != grid.items.map({ $0.id }) else {
            animatePlaceholder(to: currentFrame(of: session))
            return
        }

        grid.update(
            snapshot: TileGridSnapshot(
                items: preview,
                unpinned: session.baseSnapshot.unpinned
            ),
            animated: !isReduceMotionEnabled()
        )
        if isEditing {
            // Кнопки поверх плиток переставляются одновременно с соседями:
            // свой короткий переезд (0,24 с) стартует вместе с batch-анимацией
            // сетки.
            reconcileEditControls(animated: true)
            scheduleReconcile()
        }
        animatePlaceholder(to: currentFrame(of: session))
    }

    /// Анимирует пустышку к новой рамке при «расступании» соседей (E8.8).
    ///
    /// Кривая и длительность — общие с batch-анимацией сетки
    /// (``TesseraTileGridView/bounceTimingParameters()``): место, откуда взяли
    /// плитку, переезжает с тем же лёгким отскоком, что и соседи, поэтому
    /// картинка не распадается на два разных движения.
    ///
    /// - Parameter frame: Новая рамка в координатах сетки.
    private func animatePlaceholder(to frame: CGRect) {
        guard let placeholder = dragSession?.placeholder else { return }
        guard placeholder.frame != frame else { return }

        // §9: при Reduce Motion движение мгновенное, как и у сетки.
        guard !isReduceMotionEnabled() else {
            stopPlaceholderAnimation()
            placeholder.frame = frame
            return
        }

        // Новый шаг drag может прийти на середине прошлого переезда.
        // Запоминаем кадр, который видит пользователь, останавливаем прошлую
        // анимацию и стартуем с этой точки: модель слоя уже стоит в цели, и
        // без возврата к presentation-кадру новая анимация началась бы с
        // «прыжка» к концу предыдущей.
        let currentFrame = placeholder.layer.presentation()?.frame ?? placeholder.frame
        stopPlaceholderAnimation()
        if placeholder.frame != currentFrame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            placeholder.frame = currentFrame
            CATransaction.commit()
        }

        let animator = UIViewPropertyAnimator(
            duration: TesseraTileGridView.tileMoveDuration,
            timingParameters: TesseraTileGridView.bounceTimingParameters()
        )
        animator.addAnimations {
            placeholder.frame = frame
        }
        animator.startAnimation()
        placeholderAnimator = animator
    }

    /// Останавливает незавершённый переезд пустышки (E8.8).
    ///
    /// `stopAnimation(true)` оставляет вид в текущей позиции — следующая
    /// анимация продолжит движение от неё, а не от конечного кадра.
    private func stopPlaceholderAnimation() {
        placeholderAnimator?.stopAnimation(true)
        placeholderAnimator = nil
    }

    /// Элемент под точкой, кроме перетаскиваемого.
    ///
    /// - Parameters:
    ///   - point: Точка в координатах сетки.
    ///   - excludedID: Идентификатор, который нужно игнорировать (сам drag).
    /// - Returns: Элемент или `nil`.
    private func item(under point: CGPoint, excluding excludedID: AnyHashable) -> TileGridItem? {
        for item in grid.items where item.id != excludedID {
            guard let frame = grid.frame(forItemID: item.id) else { continue }
            if frame.contains(point) {
                return item
            }
        }
        return nil
    }

    /// Попадает ли точка в центральную половину рамки (drop «в папку»).
    ///
    /// - Parameters:
    ///   - point: Точка в координатах сетки.
    ///   - frame: Рамка плитки.
    /// - Returns: `true`, если точка в центральной зоне.
    private func isPointInDropCenter(_ point: CGPoint, of frame: CGRect) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        let insetX = frame.width * 0.25
        let insetY = frame.height * 0.25
        return frame.insetBy(dx: insetX, dy: insetY).contains(point)
    }

    // MARK: - Удержание над целью (E8.6)

    /// Взводит, ведёт или сбрасывает удержание над ярлыком-целью.
    ///
    /// Вызывается на каждом шаге drag (и на каждом кадре автопрокрутки) сразу
    /// после вычисления цели под пальцем, поэтому обязана быть дешёвой: в
    /// установившемся состоянии она делает одно сравнение смещения.
    ///
    /// - Parameters:
    ///   - target: Цель под пальцем.
    ///   - point: Точка пальца в координатах сетки.
    private func updateMergeHover(for target: HoverTarget, at point: CGPoint) {
        guard case .group(let targetID) = target else {
            // Центр ярлыка — единственная цель слияния; любая другая цель
            // (папка, перестановка, пустое место) снимает удержание.
            resetMergeHover()
            return
        }

        guard mergeTracker?.targetID == targetID else {
            // Смена цели — новый отсчёт: удерживать нужно именно над этой
            // плиткой, а не «где-то рядом» (E8.6).
            armMergeHover(on: targetID, at: point)
            return
        }

        let wasReady = mergeTracker?.isMergeReady == true
        mergeTracker?.update(point: point)
        guard mergeTracker?.state == .cancelled else { return }

        // Палец сместился больше допуска — удержание отменено, дальше обычный
        // drag E8.4. Таймер снимаем, а уже показанное «впитывание» откатываем.
        cancelMergeTimer()
        if wasReady {
            refreshMergeHighlight(animated: true)
        }
    }

    /// Начинает новый отсчёт удержания над ярлыком.
    ///
    /// Порог и допуск читаются из ``configuration`` в момент взвода: изменение
    /// конфигурации на лету снимает текущее удержание (см. `didSet`).
    ///
    /// - Parameters:
    ///   - targetID: Ярлык, на центр которого наведён палец.
    ///   - point: Точка пальца в координатах сетки (якорь для допуска смещения).
    private func armMergeHover(on targetID: AnyHashable, at point: CGPoint) {
        resetMergeHover()

        var tracker = TesseraMergeHoverTracker(
            hoverDuration: max(0, configuration.mergeHoverDuration),
            displacementThreshold: max(0, configuration.mergeHoverDisplacement)
        )
        tracker.beginHover(targetID: targetID, point: point)
        mergeTracker = tracker
        scheduleMergeTimer()
    }

    /// Планирует срабатывание таймера удержания на остаток интервала.
    ///
    /// Режим `.common`, а не `.default`: во время перетаскивания коллекция
    /// находится в tracking-режиме, и таймер в `.default` не сработал бы до
    /// отпускания пальца — то есть ровно никогда.
    private func scheduleMergeTimer() {
        cancelMergeTimer()
        guard let tracker = mergeTracker, tracker.isArmed else { return }

        // Остаток, а не полный интервал: если таймер сработал на волосок
        // раньше порога, следующий досчитает недостающее.
        let interval = max(0.01, tracker.remainingDuration)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.mergeTimerDidFire()
        }
        RunLoop.main.add(timer, forMode: .common)
        mergeTimer = timer
    }

    /// Таймер удержания сработал: проверяет порог и показывает «впитывание».
    ///
    /// Готовность к слиянию — единственное, что отличает drop с созданием
    /// папки от обычной перестановки E8.4, поэтому перед переключением
    /// состояния ещё раз проверяется, что палец всё ещё над тем же ярлыком
    /// (цель могла смениться автопрокруткой или уходом пальца).
    private func mergeTimerDidFire() {
        mergeTimer = nil

        guard let session = dragSession,
              case .group(let targetID) = session.hover,
              mergeTracker?.targetID == targetID else {
            return
        }

        guard mergeTracker?.timerFired() == true else {
            // Порог ещё не выдержан — досчитываем остаток.
            scheduleMergeTimer()
            return
        }

        refreshMergeHighlight(animated: true)

        // Тактильный отклик «готово» — по желанию, из спеки WP (лёгкий удар).
        // Жест при этом не меняется: сигнал только подтверждает, что папка
        // будет создана, если отпустить палец сейчас. При Reduce Motion он
        // остаётся: это не движение, а обратная связь.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        announce("Отпустите, чтобы создать папку.")
    }

    /// Снимает удержание: таймер, состояние машины и «впитывание» подсветки.
    ///
    /// Видимость подсветки не трогается — вызывающий либо прячет её, либо
    /// перерисовывает. Если палец всё ещё над центром ярлыка, вид возвращается
    /// к обычной подсветке цели (`.group`), а масштаб — к 1: сброс не должен
    /// оставлять на экране обещание слияния.
    private func resetMergeHover() {
        cancelMergeTimer()
        mergeTracker = nil

        guard let view = dropHighlightView else { return }
        if case .group = dragSession?.hover {
            view.apply(.group)
        }
        view.transform = .identity
    }

    /// Останавливает таймер удержания.
    private func cancelMergeTimer() {
        mergeTimer?.invalidate()
        mergeTimer = nil
    }

    // MARK: - Подсветка цели

    /// Показывает/прячет подсветку плитки-цели.
    ///
    /// E8.2: цель — единственная плитка, которая во время drag остаётся полной
    /// яркости в дим-поле (``dimmingTargetAlpha(for:)``), поэтому рамка
    /// подсветки читается на приглушённых соседях. Здесь же обновляется
    /// прозрачность: новая цель коротко «вспыхивает», а плитка, переставшая
    /// быть целью, возвращается в дим.
    ///
    /// E8.6: для центра ярлыка вид зависит от удержания — обычная рамка до
    /// порога и «впитывание» после него (``refreshMergeHighlight(animated:)``).
    ///
    /// - Parameter target: Текущая цель под пальцем.
    private func updateDropHighlight(for target: HoverTarget) {
        switch target {
        case .none, .reorder:
            hideDropHighlight()

        case .folder(let itemID):
            showDropHighlight(for: itemID, style: .folder)

        case .group:
            refreshMergeHighlight(animated: false)
        }

        applyEditDimming(animated: true)
    }

    /// Обновляет вид подсветки центра ярлыка под состояние удержания (E8.6).
    ///
    /// Единственное место, которое владеет `transform` подсветки: масштаб
    /// 1,08 в готовности к слиянию и 1 в остальных состояниях. Стиль `.merge`
    /// добавляет акцентную рамку — это второй, не анимационный признак
    /// состояния, поэтому при Reduce Motion оно остаётся видимым: меняется
    /// только рамка и масштаб, без проигрывания анимации.
    ///
    /// Увеличивается оверлей подсветки, а не ячейка цели: `transform` ячейки
    /// занят «желе» и layout'ом коллекции (E4.2), а оверлей повторяет рамку
    /// плитки, поэтому визуально «впитывание» читается как рост самой цели.
    ///
    /// - Parameter animated: Анимировать переход ``TesseraTileEditConfiguration/mergeHighlightDuration``.
    private func refreshMergeHighlight(animated: Bool) {
        var ready = false

        if let session = dragSession, case .group(let targetID) = session.hover {
            ready = mergeTracker?.isMergeReady == true
            showDropHighlight(for: targetID, style: ready ? .merge : .group)
        }

        guard let view = dropHighlightView else { return }

        let scale = ready ? max(1, configuration.mergeHighlightScale) : 1
        let apply: () -> Void = {
            view.transform = CGAffineTransform(scaleX: scale, y: scale)
        }

        // Reduce Motion отключает только анимацию: рамка и масштаб
        // выставляются сразу, состояние всё равно читается.
        guard animated, !isReduceMotionEnabled() else {
            apply()
            return
        }

        UIView.animate(
            withDuration: max(0, configuration.mergeHighlightDuration),
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
            animations: apply,
            completion: nil
        )
    }

    /// Досчитывает рамку уже показанной подсветки (после переупаковки).
    ///
    /// E8.6: рамка задаётся через `bounds`/`center`, а не `frame`: в состоянии
    /// «впитывания» у вида не-единичный `transform`, и `frame` для него
    /// не определён.
    private func updateDropHighlightFrame() {
        guard let session = dragSession, let view = dropHighlightView, !view.isHidden else {
            return
        }

        switch session.hover {
        case .folder(let itemID), .group(let itemID):
            if let frame = grid.frame(forItemID: itemID) {
                view.bounds = CGRect(origin: .zero, size: frame.size)
                view.center = CGPoint(x: frame.midX, y: frame.midY)
            }
        case .none, .reorder:
            break
        }
    }

    /// Показывает подсветку на рамке элемента.
    ///
    /// - Parameters:
    ///   - itemID: Элемент-цель.
    ///   - style: Тип цели (папка, создание папки, «впитывание»).
    private func showDropHighlight(
        for itemID: AnyHashable,
        style: TesseraTileDropHighlightView.Style
    ) {
        guard let frame = grid.frame(forItemID: itemID) else {
            hideDropHighlight()
            return
        }

        let view: TesseraTileDropHighlightView
        if let existing = dropHighlightView {
            view = existing
        } else {
            view = TesseraTileDropHighlightView(frame: frame)
            view.layer.zPosition = 600
            grid.addSubview(view)
            dropHighlightView = view
        }

        view.apply(style)
        // `bounds`/`center` вместо `frame`: вид может быть отмасштабирован
        // «впитыванием» (E8.6).
        view.bounds = CGRect(origin: .zero, size: frame.size)
        view.center = CGPoint(x: frame.midX, y: frame.midY)
        view.isHidden = false
    }

    /// Прячет подсветку цели и снимает «впитывание».
    private func hideDropHighlight() {
        guard let view = dropHighlightView else { return }
        view.isHidden = true
        view.transform = .identity
    }

    // MARK: - Димминг (E8.2)

    /// Применяет к видимым ячейкам прозрачность режима редактирования.
    ///
    /// Полной яркости остаются:
    /// - плитка, по которой вошли в режим (``dimmingFocusID``), пока нет drag;
    /// - перетаскиваемая плитка (её ячейка скрыта — яркость несёт снимок);
    /// - плитка-цель под пальцем (папка или центр ярлыка) — чтобы существующая
    ///   подсветка drop'а не утонула в дим-поле.
    ///
    /// Остальные гаснут до ``dimmedTileAlpha`` (0,7). Скрытые координатором
    /// ячейки (`contentView.alpha == 0`: drag/unpin) не трогаем — их
    /// видимостью владеет `TesseraTileGridView.setItemHidden`, и «поднять»
    /// такую плитку до 0,7 значило бы показать её раньше времени.
    ///
    /// - Parameters:
    ///   - animated: Анимировать переход ``dimmingDuration`` или выставить
    ///     прозрачность сразу. При Reduce Motion анимации нет, но сам дим
    ///     применяется: это не движение, его убирать нельзя.
    ///   - itemIDs: Ограничение набора ячеек (горячий путь прокрутки передаёт
    ///     только плитки с кнопками). `nil` — все элементы снимка.
    private func applyEditDimming(animated: Bool, limitedTo itemIDs: [AnyHashable]? = nil) {
        // Собираем изменения до анимации: `grid.cellView` во время анимации
        // может вернуть уже другую (переиспользованную) ячейку.
        var changes: [(cell: TesseraTileCell, alpha: CGFloat)] = []

        let candidates = itemIDs ?? grid.items.map { $0.id }
        for itemID in candidates {
            // alpha скрытой перетаскиваемой ячейки принадлежит drag-сессии.
            if itemID == dragSession?.itemID { continue }
            guard let cell = grid.cellView(forItemID: itemID) as? TesseraTileCell,
                  cell.itemID == itemID else {
                continue
            }
            // Ячейка скрыта сеткой (drag/unpin): не «воскрешаем» её диммингом.
            guard cell.contentView.alpha > 0.001 else { continue }

            let target = dimmingTargetAlpha(for: itemID)
            guard abs(cell.contentView.alpha - target) > 0.001 else { continue }
            changes.append((cell, target))
        }

        guard !changes.isEmpty else { return }

        let apply: () -> Void = {
            for change in changes {
                change.cell.contentView.alpha = change.alpha
            }
        }

        guard animated, !isReduceMotionEnabled() else {
            apply()
            return
        }

        UIView.animate(
            withDuration: TesseraTileEditCoordinator.dimmingDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
            animations: apply,
            completion: nil
        )
    }

    /// Целевая прозрачность содержимого плитки в текущем состоянии.
    ///
    /// Во время drag «выбранной» считается перетаскиваемая плитка и цель под
    /// пальцем; вне drag — плитка, через которую вошли в редактирование.
    ///
    /// - Parameter itemID: Идентификатор плитки.
    /// - Returns: 1 для полной яркости, ``dimmedTileAlpha`` для дима.
    private func dimmingTargetAlpha(for itemID: AnyHashable) -> CGFloat {
        guard isEditing else { return 1 }

        if let session = dragSession {
            if itemID == session.itemID { return 1 }

            switch session.hover {
            case .folder(let targetID), .group(let targetID):
                if targetID == itemID { return 1 }
            case .none, .reorder:
                break
            }
            return TesseraTileEditCoordinator.dimmedTileAlpha
        }

        if itemID == dimmingFocusID { return 1 }
        return TesseraTileEditCoordinator.dimmedTileAlpha
    }

    // MARK: - Drag: финал

    /// Завершает перетаскивание.
    ///
    /// Внутренний шаг drag-сессии (жест — `.ended`/`.cancelled`); тесты E4.7
    /// вызывают его через `@testable import`, чтобы завершить перестановку без
    /// симуляции касаний.
    ///
    /// E8.4: сетка к этому моменту показывает превью порядка, а модель всё ещё
    /// в состоянии на момент захвата. Drop фиксирует превью одним
    /// ``TileStore/move(_:toIndex:)`` по индексу перетаскиваемой плитки в
    /// превью (он же — целевой индекс), отмена возвращает сетке базовый снимок
    /// и не пишет в модель вовсе.
    ///
    /// - Parameter commit: `true` — зафиксировать превью, `false` — вернуть
    ///   порядок на момент захвата (жест отменён).
    func finishDrag(commit: Bool) {
        guard let session = dragSession else { return }

        defer { endDragStoreTransaction(saveIfNeeded: session.modelChanged) }

        // E8.6: готовность к слиянию снимается до сброса удержания — по этому
        // флагу drop выбирает между созданием папки и обычной перестановкой.
        let isMergeReady = mergeTracker?.isMergeReady == true

        stopTicker()
        resetMergeHover()
        // E8.9: возврат снимка на место (moveDragView/collapseDragView) должен
        // стартовать от текущего кадра, а не от цели незавершённого spring'а.
        stopMagnetAnimation(session)
        session.magnetTarget = nil
        dragSession = nil
        grid.isScrollEnabled = true
        hideDropHighlight()

        guard commit else {
            restore(session)
            moveDragView(session, to: currentFrame(of: session), completion: {
                self.cleanupDrag(session, unhide: true)
            })
            return
        }

        switch session.hover {
        case .folder(let folderID) where session.isTile:
            dropIntoFolder(session, folderID: folderID)

        case .group(let targetID) where session.isTile && isMergeReady:
            // E8.6: папка создаётся только если удержание выдержано (подсветка
            // уже показала «впитывание»). Иначе — обычный путь ниже.
            dropIntoNewFolder(session, targetID: targetID)

        default:
            // Индекс перетаскиваемой плитки в текущем (превью) порядке сетки —
            // ровно тот, который `TileStore.move` воспроизведёт: хранилище тоже
            // вынимает элемент и вставляет его на это место.
            let finalIndex = previewIndex(of: session)
            commitPreviewOrder(session, toIndex: finalIndex)
            let frame = currentFrame(of: session)
            moveDragView(session, to: frame) {
                self.cleanupDrag(session, unhide: true)
                guard finalIndex != session.initialIndex else { return }
                self.delegate?.tileEditCoordinator(
                    self,
                    didMove: session.itemID,
                    toIndex: finalIndex
                )
            }
        }
    }

    /// Индекс перетаскиваемой плитки в текущем порядке сетки.
    ///
    /// Во время drag сетка показывает превью, поэтому это целевой индекс
    /// drop'а; без превью он равен исходному.
    ///
    /// - Parameter session: Drag-сессия.
    /// - Returns: Индекс в порядке сетки.
    private func previewIndex(of session: TesseraTileDragSession) -> Int {
        grid.index(ofItemID: session.itemID) ?? session.initialIndex
    }

    /// Фиксирует превью порядка в модели на drop (E8.4).
    ///
    /// `TileStore.move(_:toIndex:)` вынимает элемент и вставляет его по индексу
    /// превью, поэтому порядок в модели совпадает с тем, что видит пользователь
    /// (это проверяет `TileDragPushTests` через чистую функцию).
    ///
    /// Если хранилище не переставило элемент (порядок уже такой либо модель
    /// успела измениться извне), сетку синхронизируем с моделью, чтобы на экране
    /// не осталось висеть превью.
    ///
    /// - Parameters:
    ///   - session: Drag-сессия.
    ///   - index: Целевой индекс перетаскиваемой плитки.
    private func commitPreviewOrder(_ session: TesseraTileDragSession, toIndex index: Int) {
        if store.move(session.itemID, toIndex: index) {
            session.modelChanged = true
            return
        }
        render(animated: true)
    }

    /// Завершает drop на существующую папку (D14).
    ///
    /// - Parameters:
    ///   - session: Drag-сессия.
    ///   - folderID: Папка-цель.
    private func dropIntoFolder(_ session: TesseraTileDragSession, folderID: AnyHashable) {
        guard store.addToFolder(session.itemID, folderID: folderID) else {
            failGroupingDrop(
                .addToFolder,
                session: session,
                folderID: folderID,
                reason: "добавление в папку запрещено"
            )
            return
        }

        session.modelChanged = true
        render(animated: true)
        // Рамку папки читаем после переупаковки: удаление ярлыка могло сдвинуть
        // папку вверх, и снимок должен лететь в её актуальный слот.
        let folderFrame = grid.frame(forItemID: folderID) ?? session.placeholder.frame
        delegate?.tileEditCoordinator(self, didAdd: session.itemID, toFolder: folderID)
        announce("Ярлык добавлен в папку.")
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        collapseDragView(session, into: folderFrame) {
            self.cleanupDrag(session, unhide: false)
        }
    }

    /// Завершает drop на центр другого ярлыка: создаёт папку из двух ярлыков.
    ///
    /// E8.6: вызывается только из ``finishDrag(commit:)`` и только когда
    /// удержание выдержано (`TesseraMergeHoverTracker/isMergeReady`) —
    /// «впитывание» уже показано пользователю. Обычный drop на центр без
    /// удержания сюда не попадает и завершается перестановкой E8.4.
    ///
    /// Операция D14 состоит из двух одобряемых шагов: создание папки из
    /// целевого ярлыка и добавление перетаскиваемого. Если второй шаг запрещён,
    /// папка остаётся с целевым ярлыком, а перетаскиваемый возвращается на
    /// исходное место — документированное ограничение двухшаговой операции.
    ///
    /// - Parameters:
    ///   - session: Drag-сессия.
    ///   - targetID: Ярлык, на центр которого бросили.
    private func dropIntoNewFolder(_ session: TesseraTileDragSession, targetID: AnyHashable) {
        guard let folder = store.createFolder(
            withTile: targetID,
            title: configuration.folderTitle
        ) else {
            failGroupingDrop(
                .createFolder,
                session: session,
                folderID: nil,
                reason: "создание папки запрещено"
            )
            return
        }

        session.modelChanged = true
        delegate?.tileEditCoordinator(self, didCreateFolder: folder)

        guard store.addToFolder(session.itemID, folderID: folder.id) else {
            render(animated: true)
            failGroupingDrop(
                .addToFolder,
                session: session,
                folderID: folder.id,
                reason: "папка создана, но добавление ярлыка запрещено"
            )
            return
        }

        let folderFrame = grid.frame(forItemID: folder.id) ?? session.placeholder.frame
        render(animated: true)
        delegate?.tileEditCoordinator(self, didAdd: session.itemID, toFolder: folder.id)
        announce("Создана папка из двух ярлыков.")
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        collapseDragView(session, into: folderFrame) {
            self.cleanupDrag(session, unhide: false)
        }
    }

    /// Возвращает ярлык на место после отказа функции одобрения (D14).
    ///
    /// E8.4: превью порядка в модель не писало, но отказ мог случиться после
    /// первой мутации двухшаговой операции с папкой (папка создана, ярлык ещё
    /// нет), поэтому сетку синхронизируем с текущим состоянием `TileStore`, а не
    /// с базовым снимком: иначе экран разошёлся бы с моделью.
    ///
    /// - Parameters:
    ///   - action: Отклонённая операция.
    ///   - session: Drag-сессия.
    ///   - folderID: Папка-цель.
    ///   - reason: Причина для озвучивания.
    private func failGroupingDrop(
        _ action: TileGroupingAction,
        session: TesseraTileDragSession,
        folderID: AnyHashable?,
        reason: String
    ) {
        render(animated: true)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        announce("Не удалось: \(reason).")
        delegate?.tileEditCoordinator(
            self,
            didFailGrouping: action,
            tileID: session.itemID,
            folderID: folderID
        )

        moveDragView(session, to: currentFrame(of: session)) {
            self.cleanupDrag(session, unhide: true)
        }
    }

    /// Возвращает сетке порядок на момент захвата (отмена drag, E8.4).
    ///
    /// Модель за время drag не менялась — превью живёт только в сетке, поэтому
    /// откат не пишет в `TileStore` и не вызывает `onChange` у хоста. Снимок
    /// захвата — ``TesseraTileDragSession/baseSnapshot``.
    ///
    /// - Parameter session: Drag-сессия.
    private func restore(_ session: TesseraTileDragSession) {
        guard !gridMatches(session.baseSnapshot) else { return }
        grid.update(snapshot: session.baseSnapshot, animated: true)
    }

    /// Текущая рамка перетаскиваемого элемента (после переупаковки).
    ///
    /// - Parameter session: Drag-сессия.
    /// - Returns: Рамка в координатах сетки.
    private func currentFrame(of session: TesseraTileDragSession) -> CGRect {
        grid.frame(forItemID: session.itemID) ?? session.placeholder.frame
    }

    /// Убирает снимок, пустышку и подсветку, возвращает исходную ячейку.
    ///
    /// - Parameters:
    ///   - session: Drag-сессия.
    ///   - unhide: Показывать ли исходную ячейку (элемент остался на сетке).
    private func cleanupDrag(_ session: TesseraTileDragSession, unhide: Bool) {
        // E8.9: spring притяжения мог ещё не доиграть — снимаем его вместе с
        // оверлеями, чтобы он не оживил уже убранный снимок.
        stopMagnetAnimation(session)
        session.magnetTarget = nil
        session.dragView.removeFromSuperview()
        session.placeholder.removeFromSuperview()
        stopPlaceholderAnimation()
        hideDropHighlight()

        if unhide {
            grid.setItemHidden(false, forItemID: session.itemID)
        }
        reconcileEditControls(animated: false)
    }

    /// Немедленно отменяет drag (выход из режима редактирования, фон).
    ///
    /// E8.4: отмена — это только возврат базового порядка сетки; модель не
    /// пишется, поэтому откат мгновенный и не зависит от `TileStore`.
    private func cancelDragImmediately() {
        guard let session = dragSession else { return }

        stopTicker()
        resetMergeHover()
        // E8.9: незавершённый spring притяжения не должен пережить сессию —
        // снимок убирается сразу, без хвостовой анимации.
        stopMagnetAnimation(session)
        session.magnetTarget = nil
        dragSession = nil
        grid.isScrollEnabled = true
        hideDropHighlight()

        restore(session)
        session.dragView.removeFromSuperview()
        session.placeholder.removeFromSuperview()
        stopPlaceholderAnimation()
        grid.setItemHidden(false, forItemID: session.itemID)
        reconcileEditControls(animated: false)
        endDragStoreTransaction(saveIfNeeded: session.modelChanged)
    }

    /// Проигрывает возврат снимка к месту и вызывает completion.
    ///
    /// - Parameters:
    ///   - session: Drag-сессия.
    ///   - frame: Куда вернуть.
    ///   - completion: Завершение (убрать оверлеи).
    private func moveDragView(
        _ session: TesseraTileDragSession,
        to frame: CGRect,
        completion: @escaping () -> Void
    ) {
        UIView.animate(
            withDuration: isReduceMotionEnabled() ? 0.1 : 0.2,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut],
            animations: {
                session.dragView.transform = .identity
                session.dragView.bounds = CGRect(origin: .zero, size: frame.size)
                session.dragView.center = CGPoint(x: frame.midX, y: frame.midY)
                session.dragView.alpha = 1
            },
            completion: { _ in completion() }
        )
    }

    /// Уменьшает снимок в папку и убирает его (drop в папку).
    ///
    /// - Parameters:
    ///   - session: Drag-сессия.
    ///   - frame: Рамка папки.
    ///   - completion: Завершение.
    private func collapseDragView(
        _ session: TesseraTileDragSession,
        into frame: CGRect,
        completion: @escaping () -> Void
    ) {
        let reduceMotion = isReduceMotionEnabled()
        UIView.animate(
            withDuration: reduceMotion ? 0.12 : 0.22,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseIn],
            animations: {
                session.dragView.bounds = CGRect(origin: .zero, size: frame.size)
                session.dragView.center = CGPoint(x: frame.midX, y: frame.midY)
                session.dragView.alpha = 0
                if !reduceMotion {
                    session.dragView.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
                }
            },
            completion: { _ in completion() }
        )
    }

    // MARK: - Транзакция автосохранения drag

    /// Выключает автосохранение на время drag.
    ///
    /// E8.4: превью порядка модель не трогает, но drop может состоять из
    /// нескольких мутаций (создание папки + добавление ярлыка), а
    /// `TileStore.save()` синхронный: без транзакции каждая из них писала бы
    /// JSON отдельно. Состояние сохраняется один раз в
    /// ``endDragStoreTransaction(saveIfNeeded:)``.
    private func beginDragStoreTransaction() {
        guard autosavesBeforeDrag == nil else { return }
        autosavesBeforeDrag = store.autosaves
        store.autosaves = false
    }

    /// Восстанавливает автосохранение и при необходимости пишет состояние.
    ///
    /// - Parameter saveIfNeeded: Менялась ли модель в ходе drag (включая drop).
    private func endDragStoreTransaction(saveIfNeeded: Bool) {
        guard let wasEnabled = autosavesBeforeDrag else { return }
        autosavesBeforeDrag = nil
        store.autosaves = wasEnabled

        guard wasEnabled, saveIfNeeded else { return }
        // Ошибка записи не должна ломать жест: хранилище остаётся источником
        // истины в памяти, а диагностика — забота хоста (см. TileStore.save()).
        try? store.save()
    }

    // MARK: - Автопрокрутка при перетаскивании

    /// Запускает тикер, пока идёт drag.
    private func startTickerIfNeeded() {
        guard displayLink == nil else { return }

        let link = CADisplayLink(
            target: displayLinkProxy,
            selector: #selector(TesseraTileEditTickerProxy.tick(_:))
        )
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Останавливает тикер автопрокрутки.
    private func stopTicker() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Кадр тикера: прокрутка у краёв и пересчёт цели под пальцем.
    ///
    /// Тикер работает только во время drag (не в течение всего редактирования),
    /// поэтому в простое не тратит кадры.
    ///
    /// - Parameter link: Тикер.
    fileprivate func displayLinkDidFire(_ link: CADisplayLink) {
        guard let session = dragSession else {
            stopTicker()
            return
        }

        let bounds = grid.bounds
        let edge = max(1, configuration.autoScrollEdge)
        let point = session.lastPoint

        var delta: CGFloat = 0
        if point.y < edge {
            delta = -autoScrollSpeed(distance: edge - point.y)
        } else if point.y > bounds.height - edge {
            delta = autoScrollSpeed(distance: point.y - (bounds.height - edge))
        }

        guard delta != 0 else { return }

        let offset = grid.contentOffset
        let maximumY = max(0, grid.contentSize.height - bounds.height)
        let newY = min(max(offset.y + delta, 0), maximumY)
        guard abs(newY - offset.y) > 0.01 else { return }

        // Смещение двигает контент под неподвижным пальцем; снимок остаётся
        // под пальцем, а пустышка и цель пересчитываются.
        grid.setContentOffset(CGPoint(x: offset.x, y: newY), animated: false)
        session.placeholder.frame = currentFrame(of: session)
        updateHoverTargets(at: point)
    }

    /// Скорость автопрокрутки по расстоянию до края.
    ///
    /// - Parameter distance: Расстояние до края в точках.
    /// - Returns: Смещение за кадр.
    private func autoScrollSpeed(distance: CGFloat) -> CGFloat {
        let edge = max(1, configuration.autoScrollEdge)
        let ratio = min(1, max(0, distance / edge))
        let speed = configuration.autoScrollMaximumSpeed * ratio
        return max(1, speed)
    }

    // MARK: - Оверлеи редактирования

    /// Создаёт или обновляет кнопки открепления/размера у видимых плиток.
    ///
    /// Кнопки — подвью сетки, а не ячеек: так они не страдают от
    /// переиспользования ячеек и ездят вместе с плиткой обновлением `frame`
    /// в обработчике прокрутки (без layout сетки).
    ///
    /// Тут же переприменяется димминг (E8.2): конфигурация и переиспользование
    /// ячеек возвращают `contentView.alpha` к 1, поэтому прозрачность нужно
    /// выставлять после них.
    ///
    /// - Parameters:
    ///   - animated: Анимировать ли переезд кнопок при resize/reorder.
    ///   - dimAnimated: Анимировать ли переход прозрачности (вход в режим).
    private func reconcileEditControls(animated: Bool, dimAnimated: Bool = false) {
        guard isEditing else {
            removeAllEditControls()
            return
        }

        let items = grid.items
        let actualIDs = Set(items.map { $0.id })

        for itemID in editControls.keys where !actualIDs.contains(itemID) {
            editControls[itemID]?.removeFromSuperview()
        }
        editControls = editControls.filter { actualIDs.contains($0.key) }

        let reduceMotion = isReduceMotionEnabled()
        // Оверлеи создаются только для плиток у экрана (и одной экранной высоты
        // запаса): держать кнопки для сотни далёких ярлыков незачем.
        let creationBounds = grid.bounds.insetBy(dx: 0, dy: -grid.bounds.height)

        for item in items {
            guard let frame = grid.frame(forItemID: item.id) else { continue }

            // Перетаскиваемая плитка скрыта: её оверлей не нужен до конца drag.
            if item.id == dragSession?.itemID {
                editControls[item.id]?.removeFromSuperview()
                editControls.removeValue(forKey: item.id)
                continue
            }

            let control: TesseraTileEditControlView
            if let existing = editControls[item.id] {
                control = existing
            } else {
                guard frame.intersects(creationBounds) else { continue }
                control = makeControl(for: item)
                editControls[item.id] = control
            }

            let canUnpin = item.tile != nil
            let canResize = supportedSizes(for: item).count > 1
            control.configure(canUnpin: canUnpin, canResize: canResize)
            control.layer.zPosition = 200

            let isDragged = dragSession?.itemID == item.id
            control.isHidden = isDragged || !frame.intersects(grid.bounds)

            if animated, control.frame != frame {
                UIView.animate(
                    withDuration: 0.24,
                    delay: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction],
                    animations: {
                        control.frame = frame
                    },
                    completion: nil
                )
            } else {
                control.frame = frame
            }

            // «Желе» — на слой контента ячейки, как ждёт E4.2 (иначе
            // UICollectionView сбросил бы transform самой ячейки). Оверлей с
            // кнопками получает ту же анимацию и фазу, чтобы кнопки
            // открепления/размера вращались вместе с плиткой вокруг её центра.
            if let cell = grid.cellView(forItemID: item.id) as? TesseraTileCell,
               cell.itemID == item.id {
                applyJiggle(
                    to: cell.contentView,
                    itemID: item.id,
                    enabled: !reduceMotion
                )
            }
            applyJiggle(to: control, itemID: item.id, enabled: !reduceMotion)
            applyEditActions(to: item)
        }

        // E8.2: после конфигурации ячеек — снова выставить прозрачность.
        applyEditDimming(animated: dimAnimated)
    }

    /// Создаёт оверлей с кнопками и подписывает их на действия.
    ///
    /// - Parameter item: Элемент (для замыканий нужен только идентификатор).
    /// - Returns: Новый оверлей, уже добавленный в сетку.
    private func makeControl(for item: TileGridItem) -> TesseraTileEditControlView {
        let control = TesseraTileEditControlView(diameter: configuration.controlDiameter)
        let itemID = item.id
        control.onUnpin = { [weak self] in
            self?.unpin(itemID)
        }
        control.onResize = { [weak self] in
            self?.cycleSize(of: itemID)
        }
        grid.addSubview(control)
        return control
    }

    /// Убирает оверлей элемента.
    ///
    /// - Parameter itemID: Идентификатор элемента.
    private func removeControl(for itemID: AnyHashable) {
        editControls[itemID]?.removeFromSuperview()
        editControls.removeValue(forKey: itemID)
    }

    /// Снимает все оверлеи и custom actions.
    private func removeAllEditControls() {
        for control in editControls.values {
            control.removeFromSuperview()
        }
        editControls.removeAll()

        for cell in cellsWithEditActions.values {
            cell.accessibilityCustomActions = nil
        }
        cellsWithEditActions.removeAll()
        editActionsItemByCell.removeAll()
    }

    /// Обновляет `frame`/видимость оверлеев и димминг при прокрутке.
    ///
    /// Вызывается из наблюдения за `contentOffset`; здесь меняются только
    /// `frame`/`isHidden` кнопок и `alpha` содержимого ячеек — layout не
    /// пересчитывается (CORE-IOS-DESIGN.md §2).
    private func scrollOffsetDidChange() {
        guard isEditing else { return }

        for (itemID, control) in editControls {
            guard let frame = grid.frame(forItemID: itemID) else {
                control.isHidden = true
                continue
            }
            control.frame = frame
            control.isHidden = dragSession?.itemID == itemID
                || !frame.intersects(grid.bounds)
        }

        // E8.2: `prepareForReuse` у переиспользованной ячейки вернул alpha 1 —
        // возвращаем дим. Это только `alpha` (разрешённое в горячем пути
        // свойство), никакого layout. Ограничиваемся плитками с кнопками
        // (видимая область + запас), чтобы не копировать весь снимок на кадр.
        applyEditDimming(animated: false, limitedTo: Array(editControls.keys))

        // Кнопки для плиток, попавших в кадр при прокрутке, создаются уже вне
        // колбэка прокрутки — чтобы не выполнять layout внутри него.
        scheduleReconcile()
    }

    /// Планирует сверку кнопок на следующий проход runloop.
    private func scheduleReconcile() {
        guard isEditing, !hasScheduledReconcile else { return }
        hasScheduledReconcile = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasScheduledReconcile = false
            guard self.isEditing else { return }
            self.reconcileEditControls(animated: false)
        }
    }

    // MARK: - «Желе» и accessibility

    /// Вешает/снимает «желе» на слой вида.
    ///
    /// - Parameters:
    ///   - view: Слой ячейки (контент) или оверлея кнопок.
    ///   - itemID: Идентификатор плитки — от него зависит фаза.
    ///   - enabled: Включено ли «желе» (Reduce Motion выключает).
    private func applyJiggle(to view: UIView, itemID: AnyHashable, enabled: Bool) {
        guard enabled else {
            view.layer.removeAnimation(forKey: TesseraTileEditCoordinator.jiggleKey)
            return
        }
        guard view.layer.animation(forKey: TesseraTileEditCoordinator.jiggleKey) == nil else {
            return
        }

        let spec = jiggleSpec(for: itemID)
        view.layer.add(
            TesseraTileEditCoordinator.makeJiggleAnimation(spec: spec),
            forKey: TesseraTileEditCoordinator.jiggleKey
        )
    }

    /// Снимает «желе» со всех видимых ячеек.
    private func removeAllJiggle() {
        for item in grid.items {
            if let cell = grid.cellView(forItemID: item.id) as? TesseraTileCell {
                cell.contentView.layer.removeAnimation(
                    forKey: TesseraTileEditCoordinator.jiggleKey
                )
            }
            editControls[item.id]?.layer.removeAnimation(
                forKey: TesseraTileEditCoordinator.jiggleKey
            )
        }
        jiggleSpecs.removeAll()
    }

    /// Параметры «желе» для плитки (детерминированные по seed и id).
    ///
    /// - Parameter itemID: Идентификатор плитки.
    /// - Returns: Амплитуда, длительность и фаза.
    private func jiggleSpec(for itemID: AnyHashable) -> TesseraJiggleSpec {
        if let cached = jiggleSpecs[itemID] {
            return cached
        }

        let identity = String(describing: itemID.base)
        let hash = TesseraTileEditCoordinator.stableHash(identity)
        var generator = TesseraSeededGenerator(seed: configuration.seed ^ hash)

        let amplitudeFactor = 0.85 + 0.3 * TesseraTileEditCoordinator.unitRandom(&generator)
        let durationFactor = 0.85 + 0.3 * TesseraTileEditCoordinator.unitRandom(&generator)
        let phaseFactor = TesseraTileEditCoordinator.unitRandom(&generator)

        let degrees = max(0.5, configuration.jiggleAngle) * CGFloat(amplitudeFactor)
        let duration = max(0.08, configuration.jiggleDuration * durationFactor)
        let spec = TesseraJiggleSpec(
            angle: degrees * .pi / 180,
            duration: duration,
            timeOffset: TimeInterval(phaseFactor) * duration
        )
        jiggleSpecs[itemID] = spec
        return spec
    }

    /// Выставляет ячейке custom actions resize/unpin (§9).
    ///
    /// Ячейка — один accessibility-элемент, поэтому кнопки-подвью VoiceOver не
    /// видит; действия добавляются к самой ячейке.
    ///
    /// - Parameter item: Элемент сетки.
    private func applyEditActions(to item: TileGridItem) {
        guard let cell = grid.cellView(forItemID: item.id) as? TesseraTileCell,
              cell.itemID == item.id else {
            return
        }

        let key = ObjectIdentifier(cell)
        guard editActionsItemByCell[key] != item.id else { return }

        var actions: [UIAccessibilityCustomAction] = []
        if item.tile != nil {
            actions.append(
                UIAccessibilityCustomAction(name: "Открепить", image: nil) { [weak self] _ in
                    guard let self else { return false }
                    self.unpin(item.id)
                    return true
                }
            )
        }
        if supportedSizes(for: item).count > 1 {
            actions.append(
                UIAccessibilityCustomAction(name: "Изменить размер", image: nil) { [weak self] _ in
                    guard let self else { return false }
                    self.cycleSize(of: item.id)
                    return true
                }
            )
        }

        cell.accessibilityCustomActions = actions.isEmpty ? nil : actions
        cellsWithEditActions[key] = cell
        editActionsItemByCell[key] = item.id
    }

    /// Озвучивает сообщение VoiceOver.
    ///
    /// - Parameter message: Готовая строка (локализация — забота хоста в v1).
    private func announce(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    // MARK: - Жесты

    /// Long-press: вход в редактирование и/или подъём плитки.
    ///
    /// - Parameter recognizer: Жест координатора.
    @objc private func handleLongPressGesture(_ recognizer: UILongPressGestureRecognizer) {
        guard isEnabled else { return }

        let point = recognizer.location(in: grid)
        switch recognizer.state {
        case .began:
            guard grid.window != nil else { return }
            if let item = grid.item(at: point) {
                handleLongPress(on: item, at: point)
            } else {
                beginEditing()
            }

        case .changed:
            updateDrag(to: point)

        case .ended:
            finishDrag(commit: true)

        case .cancelled, .failed:
            finishDrag(commit: false)

        default:
            break
        }
    }

    /// Тап по пустому месту выходит из редактирования.
    ///
    /// - Parameter recognizer: Жест координатора.
    @objc private func handleBackgroundTap(_ recognizer: UITapGestureRecognizer) {
        guard isEditing, dragSession == nil else { return }
        let point = recognizer.location(in: grid)
        guard grid.item(at: point) == nil else { return }
        endEditing()
    }

    // MARK: - Уведомления

    /// Reduce Motion переключили на лету: перезапускаем/снимаем «желе».
    @objc private func reduceMotionStatusDidChange() {
        guard isEditing else { return }
        jiggleSpecs.removeAll()
        reconcileEditControls(animated: false)
    }

    /// Приложение уходит в фон: незавершённый drag откатываем.
    @objc private func applicationDidEnterBackground() {
        guard dragSession != nil else { return }
        cancelDragImmediately()
    }

    // MARK: - Служебные

    /// Ищет прокручиваемую коллекцию в иерархии сетки.
    ///
    /// - Parameter view: Корень поиска.
    /// - Returns: Первый `UIScrollView` в глубину.
    private static func findScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }

    /// Снимок ячейки для fly-out (unpin) с резервным вариантом.
    ///
    /// - Parameter cell: Видимая ячейка.
    /// - Returns: Снимок или `nil`.
    private static func makeSnapshot(of cell: TesseraTileCell) -> UIView? {
        if let snapshot = cell.snapshotView(afterScreenUpdates: false) {
            return snapshot
        }
        return cell.resizableSnapshotView(
            from: cell.bounds,
            afterScreenUpdates: true,
            withCapInsets: .zero
        )
    }

    /// Stable-хэш строки (FNV-1a): одинаковый между запусками.
    ///
    /// - Parameter string: Строка.
    /// - Returns: 64-битный хэш.
    private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Равномерное число `0..<1` из seedable-генератора.
    ///
    /// - Parameter generator: Генератор `TesseraSeededGenerator` (E4.3).
    /// - Returns: Число в диапазоне `[0, 1)`.
    private static func unitRandom(_ generator: inout TesseraSeededGenerator) -> Double {
        Double(generator.next()) / Double(UInt64.max)
    }

    /// Создаёт анимацию «желе».
    ///
    /// Покачивание — синусоида, а не три кадра «−амплитуда / +амплитуда /
    /// −амплитуда» с `easeInEaseOut`. У синуса скорость в крайних точках
    /// (`sin = ±1`) равна нулю и меняется непрерывно, поэтому на развороте нет
    /// резкого торможения с последующим рывком — именно оно и читалось как
    /// «дёрганье» трёхкадрового варианта.
    ///
    /// Цикл разбит на `N = 12` равных шагов и сэмплирован по формуле
    ///
    ///     values[i] = angle * sin(2π * i / N),   i = 0…N
    ///     keyTimes[i] = i / N
    ///
    /// Кадр `i = N` замыкает цикл: `sin(2π) = 0` совпадает с `i = 0`, и
    /// `keyTimes` заканчиваются ровно на 1.0 — этого требует Core Animation;
    /// без замыкающего кадра последнее значение удерживалось бы до конца
    /// длительности и на стыке циклов получался бы рывок. Между кадрами —
    /// линейная интерполяция: форму кривой задают сами выборки синуса, любая
    /// дополнительная нелинейность только исказила бы её. Шаг `1/12` при цикле
    /// 0,34–0,46 с — около 0,03 с, мельче кадра экрана (60 Гц), поэтому ломаная
    /// из 12 выборок визуально неотличима от синусоиды.
    ///
    /// `N = 12` — компромисс: 6–8 выборок заметно «гранят» на медленном цикле,
    /// 24+ дают лишние вычисления интерполяции на каждом слое каждой плитки
    /// без видимой разницы.
    ///
    /// - Parameter spec: Параметры покачивания.
    /// - Returns: Бесконечно повторяющаяся анимация поворота.
    private static func makeJiggleAnimation(spec: TesseraJiggleSpec) -> CAKeyframeAnimation {
        let steps = 12

        // Синусоида, сэмплированная по равным долям цикла; кадр `steps`
        // замыкает её в ноль, чтобы `keyTimes` закончились на 1.0.
        let values: [CGFloat] = (0...steps).map { step in
            let phase = 2 * Double.pi * Double(step) / Double(steps)
            return CGFloat(sin(phase)) * spec.angle
        }
        let keyTimes: [NSNumber] = (0...steps).map { step in
            NSNumber(value: Double(step) / Double(steps))
        }

        // Линейные сегменты: интерполируются сами выборки синуса, своих
        // ускорений/замедлений сегментам не нужно.
        let linear = CAMediaTimingFunction(name: .linear)

        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = values
        animation.keyTimes = keyTimes
        animation.timingFunctions = Array(repeating: linear, count: steps)
        animation.duration = spec.duration
        animation.timeOffset = spec.timeOffset
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// Русское название размера для озвучивания.
    ///
    /// - Parameter size: Размер ярлыка.
    /// - Returns: Название для VoiceOver.
    private static func name(for size: TileSize) -> String {
        switch size {
        case .small: return "маленький"
        case .medium: return "средний"
        case .wide: return "широкий"
        case .large: return "большой"
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension TesseraTileEditCoordinator: UIGestureRecognizerDelegate {

    /// Не даёт long-press'у координатора перехватывать кнопки оверлея.
    ///
    /// Кнопка — `UIControl`, её тап должен дойти до неё, а не начинать drag.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard isEnabled else { return false }

        if gestureRecognizer === backgroundTapRecognizer {
            return isEditing && dragSession == nil
        }
        if gestureRecognizer === longPressRecognizer {
            var view: UIView? = touch.view
            while let current = view {
                if current is UIControl {
                    return false
                }
                view = current.superview
            }
        }
        return true
    }

    /// Разрешает работать одновременно с long-press самой сетки (E4.2).
    ///
    /// Сетка ставит свой жест только когда хост задал `onLongPress`; если он
    /// делегирует его координатору, оба жеста не должны «съедать» друг друга.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard otherGestureRecognizer is UILongPressGestureRecognizer,
              let view = otherGestureRecognizer.view else {
            return false
        }
        // Жест сетки живёт на её коллекции, а жест координатора — на самой сетке.
        return view.isDescendant(of: grid)
    }
}

// MARK: - Внутренние типы координатора

/// Чистая state-машина удержания над ярлыком-целью (E8.6).
///
/// Отвечает на один вопрос: «палец стоит над центром ярлыка достаточно долго и
/// достаточно неподвижно, чтобы отпускание создало папку?». UIKit здесь нет —
/// поэтому машина тестируется без симулятора (`TileMergeHoverTests`).
///
/// Состояния:
/// - ``State/idle`` — удержания нет;
/// - ``State/armed`` — палец над центром ярлыка, отсчёт идёт;
/// - ``State/fired`` — порог выдержан, drop создаёт папку (``isMergeReady``);
/// - ``State/cancelled`` — палец сместился больше допуска, удержание отменено.
///
/// Время читается через замыкание ``now``, а не напрямую из системных часов:
/// тесты подменяют его управляемыми часами и проверяют порог без `sleep`.
/// В проде подставляется `CACurrentMediaTime()` — тот же монотонный отсчёт,
/// что у `CADisplayLink` и Core Animation, так что пауза приложения не
/// сдвигает таймер.
///
/// Переходы:
/// - ``beginHover(targetID:point:)``: новый ярлык (или выход из `cancelled`) —
///   `armed` с якорем в точке и отсчётом с текущего момента; повторный вызов
///   для того же ярлыка в `armed`/`fired` ничего не делает, чтобы покадровые
///   вызовы не перезапускали таймер;
/// - ``update(point:)``: смещение от якоря больше допуска — `cancelled`;
/// - ``timerFired()``: прошло не меньше порога — `fired`, иначе остаётся
///   `armed` (таймер мог сработать чуть раньше из-за округления runloop);
/// - ``reset()`` — `idle`.
///
/// `cancelled` — терминальное состояние для текущего ярлыка: вернуть
/// готовность может только ``beginHover(targetID:point:)`` (палец ушёл и
/// вернулся) или ``reset()`` — координатор сбрасывает удержание при смене цели.
struct TesseraMergeHoverTracker {

    /// Состояние удержания.
    enum State: Equatable {

        /// Удержания нет.
        case idle

        /// Палец над ярлыком, отсчёт идёт.
        case armed

        /// Порог выдержан: drop создаст папку.
        case fired

        /// Палец сместился больше допуска.
        case cancelled
    }

    /// Сколько времени нужно удерживать палец (``TesseraTileEditConfiguration/mergeHoverDuration``).
    private let hoverDuration: TimeInterval

    /// Допустимое смещение пальца от якоря в точках
    /// (``TesseraTileEditConfiguration/mergeHoverDisplacement``).
    private let displacementThreshold: CGFloat

    /// Монотонные часы; инжектируются для тестов.
    private let now: () -> TimeInterval

    /// Момент взвода отсчёта по часам ``now``.
    private var startedAt: TimeInterval?

    /// Текущее состояние.
    private(set) var state: State = .idle

    /// Ярлык, над которым идёт удержание.
    private(set) var targetID: AnyHashable?

    /// Точка, от которой считается смещение пальца.
    private(set) var anchor: CGPoint?

    /// Создаёт машину удержания.
    ///
    /// - Parameters:
    ///   - hoverDuration: Порог удержания в секундах; отрицательные значения
    ///     трактуются как 0 (слияние сразу по наведению).
    ///   - displacementThreshold: Допуск смещения в точках.
    ///   - now: Провайдер монотонного времени; по умолчанию системные часы.
    init(
        hoverDuration: TimeInterval,
        displacementThreshold: CGFloat,
        now: @escaping () -> TimeInterval = { CACurrentMediaTime() }
    ) {
        self.hoverDuration = max(0, hoverDuration)
        self.displacementThreshold = max(0, displacementThreshold)
        self.now = now
    }

    /// Готов ли drop создать папку (E8.6).
    var isMergeReady: Bool {
        state == .fired
    }

    /// Идёт ли отсчёт удержания.
    var isArmed: Bool {
        state == .armed
    }

    /// Сколько осталось до готовности; 0, если отсчёт не идёт.
    ///
    /// Нужно координатору: таймер планируется на остаток, поэтому повторный
    /// запуск после раннего срабатывания не продлевает удержание.
    var remainingDuration: TimeInterval {
        guard state == .armed, let startedAt else { return 0 }
        return max(0, hoverDuration - (now() - startedAt))
    }

    /// Начинает (или продолжает) удержание над ярлыком.
    ///
    /// Повторный вызов для того же ярлыка в состояниях `armed`/`fired`
    /// игнорируется: координатор вызывает метод на каждом шаге пальца, и
    /// перезапуск отсчёта не дал бы удержанию когда-либо завершиться.
    ///
    /// - Parameters:
    ///   - targetID: Ярлык под пальцем.
    ///   - point: Точка пальца в координатах сетки — якорь допуска смещения.
    mutating func beginHover(targetID: AnyHashable, point: CGPoint) {
        if self.targetID == targetID, state == .armed || state == .fired {
            return
        }

        self.targetID = targetID
        anchor = point
        startedAt = now()
        state = .armed
    }

    /// Проверяет смещение пальца от якоря.
    ///
    /// Смещение дальше допуска отменяет удержание и в `armed`, и в `fired`:
    /// подсветка «впитывания» обещает слияние только пока палец стоит.
    ///
    /// - Parameter point: Текущая точка пальца в координатах сетки.
    mutating func update(point: CGPoint) {
        guard state == .armed || state == .fired, let anchor else { return }

        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        // Сравнение квадратов: hypot/`sqrt` здесь не нужен, порог тоже в точках.
        guard dx * dx + dy * dy > displacementThreshold * displacementThreshold else {
            return
        }

        state = .cancelled
        startedAt = nil
    }

    /// Таймер удержания сработал.
    ///
    /// - Returns: `true`, если порог выдержан и состояние стало `fired`;
    ///   `false` — рано (состояние осталось `armed`) или отсчёт не идёт.
    @discardableResult
    mutating func timerFired() -> Bool {
        guard state == .armed, let startedAt else { return false }
        guard now() - startedAt >= hoverDuration else { return false }

        state = .fired
        return true
    }

    /// Сбрасывает удержание в исходное состояние.
    mutating func reset() {
        state = .idle
        targetID = nil
        anchor = nil
        startedAt = nil
    }
}

/// Чистая математика магнитизма к ячейкам (E8.9).
///
/// Отвечает на один вопрос: «есть ли в радиусе притяжения центр слота, к
/// которому снимок должен подъехать?». UIKit и геометрия сетки сюда не
/// входят: координатор передаёт уже посчитанные центры
/// (`TesseraTileGridView.magnetSlotCenters(for:)`), поэтому функция
/// тестируется без симулятора (`TileMagnetTests`).
///
/// Притяжение — только визуальный слой (спека WP): цели push-физики E8.4 и
/// таймер слияния E8.6 считаются по точке пальца, а не по центру снимка,
/// так что магнит не может изменить порядок или создать папку.
enum TesseraTileMagnet {

    /// Центр ближайшего слота в радиусе притяжения.
    ///
    /// Расстояние считается обычным евклидовым (по квадратам, без `sqrt`:
    /// порог тоже в точках — квадраты сравнимы). Радиус включительный:
    /// центр ровно на `snapRadius` ещё притягивает. При равном расстоянии
    /// побеждает слот, который идёт в массиве раньше, — результат
    /// детерминирован и не зависит от порядка перебора.
    ///
    /// - Parameters:
    ///   - point: Точка пальца в координатах сетки.
    ///   - slotCenters: Центры виртуальных слотов той же размерности (E8.9).
    ///   - snapRadius: Радиус притяжения в точках; `0`, отрицательные и
    ///     нечисловые значения отключают притяжение.
    /// - Returns: Центр ближайшего слота или `nil`, если в радиусе слотов нет.
    static func magnetTarget(
        for point: CGPoint,
        slotCenters: [CGPoint],
        snapRadius: CGFloat
    ) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        guard snapRadius.isFinite, snapRadius > 0 else { return nil }

        let radiusSquared = snapRadius * snapRadius
        var best: CGPoint?
        var bestDistanceSquared = CGFloat.greatestFiniteMagnitude

        for center in slotCenters {
            guard center.x.isFinite, center.y.isFinite else { continue }

            let dx = center.x - point.x
            let dy = center.y - point.y
            let distanceSquared = dx * dx + dy * dy
            guard distanceSquared <= radiusSquared, distanceSquared < bestDistanceSquared else {
                continue
            }

            best = center
            bestDistanceSquared = distanceSquared
        }

        return best
    }

    /// Центры виртуальных слотов размера `size` (E8.9).
    ///
    /// Сетка виртуальная: слоты перебираются с шагом в один юнит по
    /// вертикали и горизонтали, поэтому в результат попадают и ячейки, которые
    /// сейчас пусты. След плитки ужимается под узкую сетку тем же правилом,
    /// что и в раскладке (``TileLayoutEngine/fittingSize(_:columns:)``).
    ///
    /// Функция не знает о `contentOffset` и RTL: координатор и раскладка
    /// передают начало координат контента, а зеркалирование переставляет
    /// колонки, но множество центров оставляет тем же.
    ///
    /// - Parameters:
    ///   - size: Размер перетаскиваемой плитки (D15).
    ///   - columns: Число колонок сетки, больше нуля.
    ///   - unit: Размер юнита в точках.
    ///   - gap: Зазор между соседними юнитами в точках.
    ///   - origin: Начало координат контента сетки.
    ///   - rowCount: Число занятых строк сетки в юнитах.
    /// - Returns: Центры слотов в том же пространстве координат, что `origin`;
    ///   пустой массив для вырожденной геометрии.
    static func slotCenters(
        for size: TileSize,
        columns: Int,
        unit: CGFloat,
        gap: CGFloat,
        origin: CGPoint,
        rowCount: Int
    ) -> [CGPoint] {
        guard columns > 0, unit.isFinite, unit > 0, rowCount > 0,
              origin.x.isFinite, origin.y.isFinite else {
            return []
        }

        let fittedSize = TileLayoutEngine.fittingSize(size, columns: columns)
        let width = fittedSize.unitColumns
        let height = fittedSize.unitRows
        guard width > 0, height > 0, width <= columns, rowCount >= height else { return [] }

        let spacing = gap.isFinite ? max(gap, 0) : 0
        var centers: [CGPoint] = []
        centers.reserveCapacity((rowCount - height + 1) * (columns - width + 1))

        for row in 0...(rowCount - height) {
            for column in 0...(columns - width) {
                let slot = TileLayoutSlot(
                    id: AnyHashable(0),
                    size: fittedSize,
                    column: column,
                    row: row,
                    unit: unit
                )
                let rect = TileLayoutEngine.rect(
                    for: slot,
                    unit: unit,
                    gap: spacing,
                    origin: origin
                )
                centers.append(CGPoint(x: rect.midX, y: rect.midY))
            }
        }

        return centers
    }
}

/// Параметры покачивания одной плитки.
private struct TesseraJiggleSpec {

    /// Амплитуда поворота в радианах.
    let angle: CGFloat

    /// Длительность цикла в секундах.
    let duration: TimeInterval

    /// Сдвиг фазы в секундах.
    let timeOffset: TimeInterval
}

/// Цель под пальцем во время перетаскивания.
private enum HoverTarget: Equatable {

    /// Цели нет (пустое место/плитка вне сетки).
    case none

    /// Перестановка к элементу `id`.
    ///
    /// `index` — индекс цели в **базовом** порядке сетки (снимок на момент
    /// захвата), а не в текущем превью: превью пересчитывается от базы на
    /// каждом шаге (E8.4), и индекс превью зависел бы от предыдущей цели.
    /// Он же — индекс перетаскиваемой плитки в превью и целевой индекс
    /// `TileStore.move` при фиксации drop'а.
    case reorder(AnyHashable, index: Int)

    /// Добавление ярлыка в папку `id`.
    case folder(AnyHashable)

    /// Создание папки из ярлыка `id` (drop на его центр).
    case group(AnyHashable)
}

/// Активная drag-сессия.
///
/// Класс, а не структура: координатор и таймер меняют `lastPoint`/`hover`
/// из разных мест, и копии значения разъехались бы.
private final class TesseraTileDragSession {

    /// Идентификатор перетаскиваемого элемента.
    let itemID: AnyHashable

    /// Индекс на момент захвата.
    ///
    /// Нужен, чтобы не звать делегата, если drop не изменил порядок, и как
    /// запасной индекс, если превью почему-то не применилось. Откат при отмене
    /// идёт не через индекс, а через ``baseSnapshot`` (E8.4).
    let initialIndex: Int

    /// Ярлык ли это (папку нельзя бросить в папку — вложенности нет).
    let isTile: Bool

    /// Размерность перетаскиваемого элемента (E8.9).
    ///
    /// По ней строится виртуальная сетка слотов: притягивать плитку можно
    /// только к ячейкам той же размерности (D15).
    let magnetSize: TileSize

    /// Смещение центра снимка относительно пальца.
    let grabOffset: CGPoint

    /// Снимок, едущий за пальцем.
    let dragView: UIView

    /// Пустышка на месте плитки.
    let placeholder: UIView

    /// Последняя точка пальца в координатах сетки.
    var lastPoint: CGPoint

    /// Точка захвата в координатах сетки (E8.9).
    ///
    /// От неё отсчитывается стартовая зона, в которой притяжение не включается:
    /// снимок и так стоит в исходном слоте, и без этой зоны первые ~28 pt
    /// движения плитка не следовала бы за пальцем.
    let originPoint: CGPoint

    /// Вышел ли палец из стартовой зоны захвата (E8.9).
    ///
    /// Пока `false`, притяжение выключено; взводится один раз за сессию.
    var hasLeftOriginSlot = false

    /// Снимок модели на момент захвата (E8.4).
    ///
    /// База для превью порядка (`TileLayoutEngine.previewOrder`) и для отката
    /// при отмене: во время drag `TileStore` не меняется, поэтому этот снимок
    /// всё время равен модели. Заодно хранит `unpinned` — превью-снимки сетки
    /// обязаны сохранять список ярлыков вне стола, иначе `update` сбросил бы его.
    let baseSnapshot: TileGridSnapshot

    /// Текущая цель под пальцем.
    var hover: HoverTarget = .none

    /// Палец сейчас над панелью раскрытой папки (D17, E8.9).
    ///
    /// Над панелью притяжение не работает: её место в раскладке фиксировано,
    /// и «прилипание» снимка к сетке под панелью выглядело бы как сбой.
    var isOverFolderPanel = false

    /// Центр слота, к которому снимок притянут сейчас (E8.9).
    ///
    /// `nil` — притяжения нет, снимок следует за пальцем. Хранится, чтобы
    /// покадровые обновления не перезапускали spring на каждом событии касания.
    var magnetTarget: CGPoint?

    /// Действующий spring-аниматор притяжения (E8.9).
    ///
    /// Удерживается, как аниматор пустышки (E8.8): следующая цель должна
    /// остановить прошлый spring в текущем кадре, а не доиграть до конца.
    var magnetAnimator: UIViewPropertyAnimator?

    /// Менялась ли модель за время drag (нужно для единственного сохранения).
    ///
    /// E8.4: во время drag всегда `false`; выставляется только на drop.
    var modelChanged = false

    /// Базовый индекс элемента — по снимку на момент захвата.
    ///
    /// - Parameter itemID: Идентификатор ярлыка или папки.
    /// - Returns: Индекс в исходном порядке или `nil`, если элемента не было.
    func baseIndex(of itemID: AnyHashable) -> Int? {
        baseSnapshot.items.firstIndex { $0.id == itemID }
    }

    init(
        itemID: AnyHashable,
        initialIndex: Int,
        isTile: Bool,
        grabOffset: CGPoint,
        dragView: UIView,
        placeholder: UIView,
        lastPoint: CGPoint,
        baseSnapshot: TileGridSnapshot,
        magnetSize: TileSize
    ) {
        self.itemID = itemID
        self.initialIndex = initialIndex
        self.isTile = isTile
        self.grabOffset = grabOffset
        self.dragView = dragView
        self.placeholder = placeholder
        self.lastPoint = lastPoint
        self.originPoint = lastPoint
        self.baseSnapshot = baseSnapshot
        self.magnetSize = magnetSize
    }
}

/// Слабый мост `CADisplayLink` → координатор.
private final class TesseraTileEditTickerProxy {

    /// Координатор, который получает кадры.
    weak var coordinator: TesseraTileEditCoordinator?

    /// Кадр тикера.
    ///
    /// - Parameter link: Тикер.
    @objc func tick(_ link: CADisplayLink) {
        coordinator?.displayLinkDidFire(link)
    }
}

// MARK: - Кнопки редактирования

/// Оверлей кнопок «открепить» и «размер» поверх плитки.
///
/// Занимает рамку плитки, чтобы кнопки и «желе» вращались вокруг её центра, но
/// перехватывает касания только в самих кнопках: тап по остальной площади
/// проходит к коллекции (и дальше к хосту).
final class TesseraTileEditControlView: UIView {

    /// Нажатие на кнопку открепления.
    var onUnpin: (() -> Void)?

    /// Нажатие на стрелку размера.
    var onResize: (() -> Void)?

    /// SF Symbol кнопки «открепить» (E8.3).
    ///
    /// Выбрана перечёркнутая булавка, а не крестик: действие — не удаление, а
    /// открепление с рабочего стола (ярлык остаётся в списке приложений).
    /// `pin.slash` — канонический символ «открепить»; простая `pin` обозначает
    /// состояние «закреплено» и читалась бы как обратное действие. Символ
    /// доступен с iOS 13, то есть входит в целевой iOS 15.
    private static let unpinSymbolName = "pin.slash"

    private let unpinButton = UIButton(type: .system)
    private let resizeButton = UIButton(type: .system)
    private let diameter: CGFloat
    private var showsUnpin = true
    private var showsResize = true

    /// Создаёт оверлей.
    ///
    /// - Parameter diameter: Диаметр кнопок в точках.
    init(diameter: CGFloat) {
        self.diameter = max(22, diameter)
        super.init(frame: .zero)

        isAccessibilityElement = false
        backgroundColor = .clear

        setUpButton(
            unpinButton,
            symbolName: TesseraTileEditControlView.unpinSymbolName,
            action: #selector(unpinTapped)
        )
        setUpButton(
            resizeButton,
            symbolName: "arrow.up.left.and.arrow.down.right",
            action: #selector(resizeTapped)
        )
        addSubview(unpinButton)
        addSubview(resizeButton)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Показывает/прячет кнопки под возможности элемента.
    ///
    /// - Parameters:
    ///   - canUnpin: Показывать ли кнопку открепления (у папки её нет).
    ///   - canResize: Показывать ли стрелку размера.
    func configure(canUnpin: Bool, canResize: Bool) {
        guard canUnpin != showsUnpin || canResize != showsResize else { return }
        showsUnpin = canUnpin
        showsResize = canResize
        unpinButton.isHidden = !canUnpin
        resizeButton.isHidden = !canResize
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard bounds.width > 0, bounds.height > 0 else { return }

        let inset: CGFloat = 2
        let side = min(diameter, max(22, min(bounds.width, bounds.height) * 0.4))
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft

        // Кнопка открепления — в верхнем углу по направлению чтения, стрелка —
        // в нижнем противоположном (§9, RTL).
        let unpinX = isRightToLeft ? bounds.width - inset - side : inset
        let resizeX = isRightToLeft ? inset : bounds.width - inset - side

        unpinButton.frame = CGRect(x: unpinX, y: inset, width: side, height: side)
        resizeButton.frame = CGRect(
            x: resizeX,
            y: bounds.height - inset - side,
            width: side,
            height: side
        )
        unpinButton.layer.cornerRadius = side / 2
        resizeButton.layer.cornerRadius = side / 2
    }

    /// Пропускает касания мимо оверлея, если они не попали в кнопку.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    /// Настраивает круглую кнопку.
    ///
    /// - Parameters:
    ///   - button: Кнопка.
    ///   - symbolName: Имя SF Symbol.
    ///   - action: Селектор нажатия.
    private func setUpButton(_ button: UIButton, symbolName: String, action: Selector) {
        button.setImage(UIImage(systemName: symbolName), for: .normal)
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 11, weight: .bold),
            forImageIn: .normal
        )
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        button.layer.cornerRadius = diameter / 2
        button.clipsToBounds = true
        button.isAccessibilityElement = false
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    /// Открепление.
    @objc private func unpinTapped() {
        onUnpin?()
    }

    /// Стрелка размера.
    @objc private func resizeTapped() {
        onResize?()
    }
}

// MARK: - Подсветка цели

/// Подсветка плитки-цели при перетаскивании.
///
/// Не перехватывает касания и не озвучивается: это визуальная подсказка.
/// E8.2: цель остаётся полной яркости на фоне приглушённых соседей
/// (``TesseraTileEditCoordinator``), поэтому рамка и заливка читаются
/// на светлой плитке без усиления цвета.
final class TesseraTileDropHighlightView: UIView {

    /// Тип цели.
    enum Style {

        /// Папка: ярлык будет добавлен.
        case folder

        /// Ярлык: удержание ещё не выдержано, drop — обычная перестановка.
        case group

        /// Ярлык: удержание выдержано, drop создаст папку (E8.6).
        ///
        /// Тот же акцент, что у `.group`, но рамка толще и заливка плотнее, а
        /// координатор дополнительно увеличивает вид до
        /// ``TesseraTileEditConfiguration/mergeHighlightScale``. Состояние
        /// читается и без анимации: при Reduce Motion меняются только рамка и
        /// масштаб.
        case merge
    }

    /// Текущий стиль.
    private(set) var style: Style = .folder

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        layer.cornerRadius = 4
        layer.borderWidth = 3
        updateColors()
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Применяет стиль.
    ///
    /// - Parameter style: Тип цели.
    func apply(_ style: Style) {
        guard style != self.style else { return }
        self.style = style
        updateColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    /// Обновляет адаптивные цвета и толщину рамки.
    ///
    /// Стили `.group` и `.merge` — один и тот же акцент (оранжевый): состояние
    /// «впитывания» должно читаться как усиление той же цели, а не как другая
    /// цель. Отличаются толщина рамки и плотность заливки — признаки, видимые
    /// и без анимации (E8.6, Reduce Motion).
    private func updateColors() {
        let color: UIColor
        let borderWidth: CGFloat
        let fillAlpha: CGFloat

        switch style {
        case .folder:
            color = .systemBlue
            borderWidth = 3
            fillAlpha = 0.12
        case .group:
            color = .systemOrange
            borderWidth = 3
            fillAlpha = 0.12
        case .merge:
            color = .systemOrange
            borderWidth = 4
            fillAlpha = 0.24
        }

        layer.borderColor = color.cgColor
        layer.borderWidth = borderWidth
        backgroundColor = color.withAlphaComponent(fillAlpha)
    }
}

// MARK: - Экран папки

/// Минимальный экран папки (D14): содержимое и перемещение ярлыков между папками.
///
/// Решение E4.4: папка открывается **модальным sheet**, а не раскрытием на месте.
/// Причины: сетка остаётся единственным владельцем drag-координатора, а sheet
/// даёт готовую кнопку закрытия и VoiceOver-фокус. Внутри:
///
/// - тап по ярлыку закрывает папку и вызывает `TileDescriptor.action` (D12);
/// - долгое нажатие (и custom action VoiceOver «Переместить») открывает меню
///   «в другую папку / на рабочий стол»; каждая операция идёт через
///   `TileStore.moveBetweenFolders` и, значит, через функцию одобрения хоста (D14);
/// - после перемещения экран перечитывает папку из `TileStore`; если папка
///   опустела и распустилась, sheet закрывается.
///
/// Вложенных папок нет (`TileFolder.tiles` — только ярлыки), поэтому список
/// «других папок» плоский.
final class TesseraFolderViewController: UIViewController {

    /// Хранилище — единственный писатель модели (§6).
    private let store: TileStore

    /// Координатор, через который выполняются перемещения (D14).
    private weak var coordinator: TesseraTileEditCoordinator?

    /// Идентификатор открытой папки.
    private let folderID: AnyHashable

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    /// Создаёт экран папки.
    ///
    /// - Parameters:
    ///   - folder: Папка из снимка `TileStore`.
    ///   - store: Хранилище.
    ///   - coordinator: Координатор редактирования.
    init(folder: TileFolder, store: TileStore, coordinator: TesseraTileEditCoordinator) {
        self.folderID = folder.id
        self.store = store
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        view.accessibilityViewIsModal = true

        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.textColor = .label

        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel

        closeButton.setTitle("Готово", for: .normal)
        closeButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityLabel = "Закрыть папку"

        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true

        stackView.axis = .vertical
        stackView.spacing = 12

        [titleLabel, subtitleLabel, closeButton, scrollView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor,
                constant: -12
            ),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -16
            ),

            scrollView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stackView.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: 4
            ),
            stackView.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: 16
            ),
            stackView.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -16
            ),
            stackView.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -24
            ),
            stackView.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                constant: -32
            ),
        ])

        rebuild()
    }

    /// Перечитывает папку из хранилища и перестраивает содержимое.
    ///
    /// Если папки больше нет (распустилась после перемещения последнего ярлыка),
    /// экран закрывается.
    private func rebuild() {
        guard let folder = currentFolder() else {
            dismiss(animated: !reduceMotion)
            return
        }

        titleLabel.text = folder.title.isEmpty ? "Папка" : folder.title
        subtitleLabel.text = TesseraFolderViewController.tilesText(folder.tiles.count)

        for arranged in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }

        let columns = 2
        var index = 0
        while index < folder.tiles.count {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 12
            row.distribution = .fillEqually

            for _ in 0..<columns {
                if index < folder.tiles.count {
                    let tile = folder.tiles[index]
                    index += 1
                    let tileView = makeTileView(for: tile)
                    row.addArrangedSubview(tileView)
                    tileView.heightAnchor.constraint(equalToConstant: 108).isActive = true
                } else {
                    let spacer = UIView()
                    spacer.isUserInteractionEnabled = false
                    row.addArrangedSubview(spacer)
                    spacer.heightAnchor.constraint(equalToConstant: 108).isActive = true
                }
            }

            stackView.addArrangedSubview(row)
        }
    }

    /// Учитывает ли экран Reduce Motion (с приоритетом провайдера координатора).
    private var reduceMotion: Bool {
        coordinator?.isReduceMotionEnabled() ?? TesseraAccessibility.isReduceMotionEnabled
    }

    /// Текущая версия папки из хранилища.
    ///
    /// - Returns: Папка или `nil`, если она уже распустилась.
    private func currentFolder() -> TileFolder? {
        store.snapshot().folders.first { $0.id == folderID }
    }

    /// Создаёт плитку содержимого папки с тапом и меню перемещения.
    ///
    /// - Parameter tile: Ярлык.
    /// - Returns: Вид-плитка.
    private func makeTileView(for tile: TileDescriptor) -> TesseraFolderTileView {
        let tileView = TesseraFolderTileView(tile: tile)
        tileView.addTarget(self, action: #selector(tileTapped(_:)), for: .touchUpInside)

        let longPress = UILongPressGestureRecognizer(
            target: self,
            action: #selector(tileLongPressed(_:))
        )
        longPress.minimumPressDuration = 0.45
        tileView.addGestureRecognizer(longPress)

        tileView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Переместить", image: nil) { [weak self, weak tileView] _ in
                guard let self, let tileView, let tile = tileView.tile else { return false }
                self.presentMoveMenu(for: tile, sourceView: tileView)
                return true
            }
        ]
        return tileView
    }

    /// Тап по ярлыку: закрыть папку и выполнить действие (D12).
    ///
    /// - Parameter sender: Плитка содержимого.
    @objc private func tileTapped(_ sender: TesseraFolderTileView) {
        guard let action = sender.tile?.action else { return }
        let animated = !reduceMotion
        dismiss(animated: animated, completion: action)
    }

    /// Долгое нажатие по ярлыку: меню перемещения между папками (D14).
    ///
    /// - Parameter recognizer: Жест.
    @objc private func tileLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              let tileView = recognizer.view as? TesseraFolderTileView,
              let tile = tileView.tile else {
            return
        }
        presentMoveMenu(for: tile, sourceView: tileView)
    }

    /// Показывает меню «куда переместить ярлык».
    ///
    /// - Parameters:
    ///   - tile: Ярлык.
    ///   - sourceView: Вид-источник для popover на iPad.
    private func presentMoveMenu(for tile: TileDescriptor, sourceView: UIView) {
        let alert = UIAlertController(
            title: "Переместить «\(tile.title)»",
            message: nil,
            preferredStyle: .actionSheet
        )

        let otherFolders = store.snapshot().folders.filter { $0.id != folderID }
        for folder in otherFolders {
            let name = folder.title.isEmpty ? "Папка" : folder.title
            alert.addAction(UIAlertAction(title: "В «\(name)»", style: .default) { [weak self] _ in
                self?.move(tileID: tile.id, to: folder.id)
            })
        }

        alert.addAction(UIAlertAction(title: "На рабочий стол", style: .default) { [weak self] _ in
            self?.move(tileID: tile.id, to: nil)
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel, handler: nil))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }
        present(alert, animated: !reduceMotion)
    }

    /// Выполняет перемещение через координатор (и функцию одобрения D14).
    ///
    /// - Parameters:
    ///   - tileID: Ярлык.
    ///   - folderID: Папка-цель; `nil` — на рабочий стол.
    private func move(tileID: AnyHashable, to folderID: AnyHashable?) {
        guard let coordinator else { return }

        guard coordinator.moveBetweenFolders(tileID, to: folderID) else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        rebuild()
    }

    /// Закрывает экран.
    @objc private func closeTapped() {
        dismiss(animated: !reduceMotion)
    }

    /// Склоняет число ярлыков для подзаголовка.
    ///
    /// - Parameter count: Число ярлыков.
    /// - Returns: Строка вида «3 ярлыка».
    private static func tilesText(_ count: Int) -> String {
        let remainder100 = count % 100
        let remainder10 = count % 10
        let word: String
        if (11...14).contains(remainder100) {
            word = "ярлыков"
        } else if remainder10 == 1 {
            word = "ярлык"
        } else if (2...4).contains(remainder10) {
            word = "ярлыка"
        } else {
            word = "ярлыков"
        }
        return "\(count) \(word)"
    }
}

// MARK: - Плитка внутри папки

/// Плитка содержимого папки: иконка, подпись, бейдж.
///
/// `UIControl`, чтобы ловить тап; долгое нажатие и VoiceOver-действие
/// «Переместить» вешает экран папки.
final class TesseraFolderTileView: UIControl {

    /// Ярлык, который показывает плитка.
    private(set) var tile: TileDescriptor?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let badgeView = TesseraLiveTileBadgeView()

    /// Создаёт плитку.
    ///
    /// - Parameter tile: Ярлык.
    init(tile: TileDescriptor) {
        self.tile = tile
        super.init(frame: .zero)
        setUp()
        update(with: tile)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Обновляет содержимое.
    ///
    /// - Parameter tile: Ярлык.
    func update(with tile: TileDescriptor) {
        self.tile = tile

        if let icon = tile.icon {
            iconView.image = icon
            iconView.tintColor = nil
        } else {
            iconView.image = UIImage(systemName: "square.grid.2x2.fill")
            iconView.tintColor = .secondaryLabel
        }

        titleLabel.text = tile.title
        badgeView.badge = tile.badge

        accessibilityLabel = tile.title
        switch tile.badge {
        case .count(let value) where value > 0:
            accessibilityValue = String(value)
        case .none, .dot, .count:
            accessibilityValue = nil
        }
        setNeedsLayout()
    }

    /// Общая настройка вида.
    private func setUp() {
        isAccessibilityElement = true
        accessibilityTraits = .button
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 10
        clipsToBounds = true

        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false

        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        titleLabel.textAlignment = .center
        titleLabel.textColor = .label
        titleLabel.isAccessibilityElement = false

        badgeView.isAccessibilityElement = false

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(badgeView)
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.7 : 1
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let bounds = contentBounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let inset: CGFloat = 10
        let iconSide = min(38, bounds.width * 0.45)
        let titleHeight = min(36, max(16, bounds.height * 0.32))

        iconView.frame = CGRect(
            x: (bounds.width - iconSide) / 2,
            y: inset,
            width: iconSide,
            height: iconSide
        )
        titleLabel.frame = CGRect(
            x: inset,
            y: bounds.height - inset - titleHeight,
            width: bounds.width - inset * 2,
            height: titleHeight
        )

        let badgeSize = badgeView.intrinsicContentSize
        let showsBadge = badgeSize.width > 0 && badgeSize.height > 0
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        badgeView.frame = showsBadge
            ? CGRect(
                x: isRightToLeft ? inset : bounds.width - inset - badgeSize.width,
                y: inset,
                width: badgeSize.width,
                height: badgeSize.height
            )
            : .zero
    }

    /// Границы без учёта возможного сдвига от highlight.
    private var contentBounds: CGRect {
        CGRect(origin: .zero, size: bounds.size)
    }
}

#endif
