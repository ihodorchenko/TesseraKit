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
//    small → wide → medium → large на месте (D28, E15.3; рост выталкивает
//    соседей вниз),
//    собственный drag-координатор (снэпшот + пустышка + превью на ячейках без
//    записи в модель + инвалидация layout), а не нативный `UICollectionView` interactive movement;
//  - §3 «Плиточная сетка»: ячейки и выталкивание считает `TileLayoutEngine`, анимацию
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
//  E14.5 (D30–D33): координатор целиком работает на ячейках. Цель drag — клетка
//  под пальцем по базовой раскладке (`HoverTarget.cell`/`.newRow`, центр
//  плитки/папки — слияние); превью — те же элементы на других ячейках
//  (`TileLayoutEngine.inserting` от базовых размещений, таблица ячеек в снимке
//  сетки), на слиянии и без цели — база; drop фиксируется операциями `TileStore`
//  по ячейкам с последующим `collapseEmptyRows`; кнопки правки и публичные
//  методы идут теми же операциями. Индексного API нет (E14.6, D33): делегат
//  получает ячейку, а не индекс. Подробно — STARTSCREEN-IOS-DESIGN,
//  «Отступления реализации (E14)», п. 53–54.
//
//  E8.4: во время перетаскивания модель НЕ меняется. Раскладка соседей —
//  превью, которое живёт только в сетке (`grid.update(snapshot:animated:)`); в
//  `TileStore` изменение пишется один раз на drop, а отмена просто возвращает
//  сетке снимок на момент захвата. Хост не получает `onChange` на каждый шаг
//  drag, автосохранение не срабатывает.
//
//  E8.7/E14.5: resize-выталкивание. При увеличении плитка остаётся на своём
//  месте, а конфликтующие плитки уходят вниз каскадом
//  (`TileStore.resize(_:to:columns:)`); координатор передаёт реальное
//  число колонок сетки. Цикл размеров D15/D28 (small → wide → medium → large →
//  small, порядок — `TileSize.cycleOrder`) не меняется.
//
//  E8.6: папка из двух ярлыков больше не создаётся мгновенно при drop на
//  центр плитки-цели. Нужно удержать перетаскиваемую плитку над целью больше
//  `mergeHoverDuration` (600 мс) при смещении пальца строго меньше
//  `mergeHoverDisplacement` (10 pt); тогда цель подсвечивается «впитыванием»
//  (масштаб 1,08 + акцентная рамка, ~0,2 с) и drop создаёт папку. Таймер не
//  истёк или палец сместился на допуск и больше — цель не группирует: drop в
//  центр ярлыка/папки возвращает ярлык на исходное место (E9.5), в остальных
//  зонах работает обычное перетаскивание E8.4.
//  Решение «сливать или нет» принимает чистая state-машина
//  ``TesseraMergeHoverTracker``: в ней нет UIKit и часов системы, поэтому она
//  тестируется без симулятора.
//
//  E9.8а: границы E8.6 строгие (`<10 pt`, `>600 мс`). После смещения за допуск
//  удержание отменяется, но не «залипает» навсегда: возврат пальца в допуск
//  запускает новый отсчёт 600 мс (E10.5-A3), выход из зоны/смена цели — тоже.
//
//  E9.5: центр плитки-цели — единственная зона, где drop не переставляет
//  ярлык. Без выдержанного удержания E8.6 drop на центр = возврат на исходное
//  место (no-op/отмена); push-превью для центральной зоны нет. То же правило
//  действует для центральной зоны плитки-папки (add-to-folder по удержанию).
//
//  E8.8: движения плиток при перестановке (переезд соседей в
//  `TesseraTileGridView.update(snapshot:animated:)` и пустышка под снятой
//  плиткой) идут bounce-кривой `cubic-bezier(0.175, 0.885, 0.32, 1.1)`,
//  0,26 с. Фабрика общая — `TesseraTileGridView.bounceTimingParameters()`;
//  кривая раскрытия/закрытия панели папки (0.1, 0.9, 0.2, 1) не меняется.
//
//  E8.9/E14.5: магнитизм к ячейкам. Снимок притягивается к рамке ячейки-цели для
//  его размера (`TesseraTileGridView.baseFrame(forCell:size:)`), а решение
//  «в радиусе или нет» принимает чистая функция
//  `TesseraTileMagnet.magnetTarget(for:slotCenters:snapRadius:)`. Точка отсчёта —
//  **центр снимка** (`point + grabOffset`), а не палец (E10.5-A2): иначе плитка,
//  взятая не за центр, «прыгала» к слоту до половины плитки. Стартовая зона,
//  особые цели (папка/центр ярлыка) и над панелью притяжение отключено; при
//  Reduce Motion — целиком. Цели E8.4 и таймер E8.6 по-прежнему считаются по
//  точке пальца, поэтому магнит не меняет порядок и слияние.
//
//  E10.5 (W4, 02.11.2026) — цели и геометрия drag:
//  - A1: у плитки-папки есть краевые зоны размещения: левая/правая половина
//    (вне центральной зоны) — `.cell` с ячейкой папки (до E14.5 — `.reorder` с
//    базовым индексом), центральная зона — add-to-folder по удержанию E8.6
//    (D14). Папка-источник не таскается в папку (`session.isTile`).
//  - A2: магнит считает слот от центра снимка (`grabOffset`), а не от пальца.
//  - A3: удержание перевзводится после возврата пальца в допуск / смены цели.
//  - A4: при входе в edit и старте drag раскрытая панель папки закрывается
//    штатным `closeFolder`; drag не начинается с ячеек панели (`.folderContent`).
//  - B1: внешняя модель/снимок во время drag — детерминированная безопасная
//    отмена и синхронизация сетки с моделью (а не откат к устаревшей базе).
//  - B2: `deinit` и fly-out восстанавливают скрытую ячейку, `isScrollEnabled`,
//    `autosaves`, снимают оверлеи и аниматоры.
//  - B3: двойной быстрый unpin — in-flight guard по tileID: один fly-out,
//    одна мутация, один колбэк.
//  - B4: смена `controlDiameter`/`jiggle*`/`mergeHover*` на лету перестраивает
//    контролы, фазы и удержание.
//  - B5: после `render` (unpin/создание папки) «желе» и дим переприменяются.
//  - B6: `.layoutChanged` после unpin/resize/move — на следующий проход runloop,
//    когда ячейка-фокус уже существует. E14.7: после unpin фокус — следующий
//    элемент в порядке чтения ячеек (предыдущий, если ярлык был последним, сама
//    сетка, если элементов не осталось); после resize/move/drop/вынесения —
//    элемент, который изменился или переехал, после слияния — папка.
//  - C1: делегат получает фактическую ячейку, сетка синхронизируется со снимком
//    store (E14.5/E14.6: операции по ячейкам, до E14 — индекс порядка).
//  - C3: встроенный экран папки активирует ярлык общим маршрутом `grid.onTap`,
//    а не вызовом `action` напрямую; в edit-режиме не активирует.
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
    ///   - cell: Ячейка левого верхнего угла элемента после операции (после
    ///     выталкивания, ограничения холстом и схлопывания пустых строк).
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didMove tileID: AnyHashable,
        toCell cell: TileGridPlacement
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

    /// Ярлык перемещён между папками или на рабочий стол с ячейкой (E11.1, E14.6).
    ///
    /// Именно этот вариант координатор вызывает при перемещении ярлыка (из
    /// drag-жеста и из ``TesseraTileEditCoordinator/moveBetweenFolders(_:to:)``) —
    /// **ровно один раз за операцию**. Реализация по умолчанию пересылает
    /// событие в ``tileEditCoordinator(_:didMove:toFolder:)``, поэтому делегат,
    /// которому ячейка не нужна, реализует только его; делегат, которому она
    /// нужна, реализует этот метод (тогда тот не вызывается).
    ///
    /// - Parameters:
    ///   - coordinator: Координатор-источник события.
    ///   - tileID: Идентификатор ярлыка.
    ///   - folderID: Папка-цель; `nil` — ярлык вынесен на рабочий стол.
    ///   - cell: Ячейка ярлыка на рабочем столе после операции (когда
    ///     `folderID == nil`); `nil` — при переносе в папку.
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didMove tileID: AnyHashable,
        toFolder folderID: AnyHashable?,
        atCell cell: TileGridPlacement?
    )

    /// Папка распущена: в ней остался один ярлык, и он занял место папки (D45).
    ///
    /// Папка не бывает из 0–1 ярлыков: когда операция координатора (открепление,
    /// вынос на рабочий стол, перенос в другую папку — в том числе drop из
    /// панели) оставляет в папке один ярлык, папка исчезает, а этот ярлык
    /// становится верхнеуровневым элементом на её ячейке со **своим** размером
    /// (бо́льший ярлык выталкивает соседей вниз). Метод вызывается **после**
    /// успешной операции и после её основного колбэка
    /// (`didUnpin`, `didMove(_:toFolder:atCell:)`), один раз на распавшуюся
    /// папку. Папка, которая исчезла пустой, событие не вызывает. Распад из
    /// чистки каталога (``TileStore/setCatalog(_:)``), загрузки файла и вызовов
    /// `TileStore` в обход координатора сюда не приходит — хост видит его в
    /// снимке `TileStore.onChange`.
    ///
    /// - Parameters:
    ///   - coordinator: Координатор-источник события.
    ///   - folderID: Идентификатор распущенной папки (её больше нет в модели).
    ///   - tileID: Идентификатор оставшегося ярлыка, ставшего верхнеуровневым.
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didDissolveFolder folderID: AnyHashable,
        remainingTile tileID: AnyHashable
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
        toCell cell: TileGridPlacement
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

    /// E11.1/E14.6: по умолчанию — пересылка в колбэк без ячейки, чтобы делегат,
    /// которому позиция не нужна, не потерял событие.
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didMove tileID: AnyHashable,
        toFolder folderID: AnyHashable?,
        atCell cell: TileGridPlacement?
    ) {
        tileEditCoordinator(coordinator, didMove: tileID, toFolder: folderID)
    }

    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didDissolveFolder folderID: AnyHashable,
        remainingTile tileID: AnyHashable
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

    /// Наибольший диаметр круглых кнопок «открепить»/«размер» в точках.
    ///
    /// E12.5: это потолок, а не фиксированный размер. Фактический диаметр
    /// масштабируется по меньшей стороне плитки (≈ 24 % стороны) и не меньше
    /// 20 pt: на малой плитке кнопки компактные (≈ 22 pt), на средней и больше —
    /// до `controlDiameter`. Зона касания у любой кнопки не меньше 44 × 44 pt
    /// независимо от диаметра (расширение `hitTest`).
    public var controlDiameter: CGFloat

    /// Ширина зоны автопрокрутки у верхнего и нижнего края сетки в точках.
    public var autoScrollEdge: CGFloat

    /// Максимальная скорость автопрокрутки в точках за кадр.
    public var autoScrollMaximumSpeed: CGFloat

    /// Название папки, создаваемой перетаскиванием ярлыка на ярлык.
    ///
    /// Пустая строка (по умолчанию) — локализованное «Папка»/«Folder» из строк
    /// модуля (E12.7); непустое значение перекрывает его.
    public var folderTitle: String

    /// Сколько нужно удерживать перетаскиваемую плитку над центром ярлыка-цели
    /// (или центральной зоной плитки-папки), чтобы drop сгруппировал ярлыки
    /// (E8.6, E10.5-A1).
    ///
    /// По умолчанию 0,6 с (600 мс — спека WP); порог строгий (`>600 мс`,
    /// E9.8а). До истечения этого времени цель только подсвечивается обычной
    /// рамкой, а drop не группирует: вне центральной зоны — обычная
    /// перестановка E8.4, в центре — no-op (E9.5). Нулевое значение возвращает
    /// почти мгновенное слияние
    /// (поведение до E8.6): готовность наступает на первом же кадре после
    /// наведения, по отпусканию палец успевает раньше.
    public var mergeHoverDuration: TimeInterval

    /// Допустимое смещение пальца за время удержания в точках (E8.6).
    ///
    /// По умолчанию 10 pt; допуск строгий (`<10 pt`, E9.8а). Смещение на допуск
    /// или больше отменяет удержание: жест остаётся обычным перетаскиванием
    /// E8.4, даже если палец всё ещё над центром плитки-цели. Порог намеренно
    /// маленький: он отделяет «палец замер, чтобы собрать папку» от «палец ведёт
    /// плитку дальше». Возврат пальца в допуск после отмены запускает новый
    /// отсчёт 600 мс (E10.5-A3).
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
    /// Притяжение включается, когда **центр снимка** (палец + `grabOffset`,
    /// E10.5-A2) оказывается ближе этого радиуса к центру виртуального слота
    /// той же размерности, что и перетаскиваемая плитка: снимок плавно
    /// подъезжает к центру, а не «прыгает» туда.
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
    ///   - controlDiameter: Наибольший диаметр кнопок (малые плитки получают
    ///     меньше, см. ``controlDiameter``), по умолчанию 28.
    ///   - autoScrollEdge: Зона автопрокрутки, по умолчанию 64.
    ///   - autoScrollMaximumSpeed: Максимальная скорость, по умолчанию 9.
    ///   - folderTitle: Название новой папки; пусто — локализованное по умолчанию.
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
///   `TileStore.unpin(_:columns:)` (ячейка остаётся дырой, пустая строка
///   схлопывается);
/// - **resize**: стрелка → циклическая смена размера из поддерживаемых
///   (по умолчанию — все четыре, помещающиеся в текущее число колонок) через
///   `TileStore.resize(_:to:columns:)`; при увеличении плитка остаётся
///   на месте, а конфликтующие соседи уходят вниз (E8.7, E14.5);
/// - **drag**: собственный координатор — снимок едет за пальцем и слегка
///   уменьшается (0.95, спека WP: плитка «отделяется» от плоскости, а не
///   приближается), на месте остаётся пустышка; при наведении на плитку-цель
///   раскладка пересобирается превью (E8.4, E14.5): перетаскиваемая встаёт на
///   ячейку под пальцем (на ячейку цели, если палец у края занятой клетки), а
///   мешающие плитки выталкиваются вниз каскадом (D31); место, откуда взяли
///   плитку, остаётся дырой. Это **превью без записи в модель**; при отпускании
///   раскладка фиксируется одной операцией `TileStore` по ячейкам
///   (`moveItem(_:toCell:columns:)`, `moveItemToNewRow`) и схлопывается пустая
///   строка; автопрокрутка у краёв; при подходе пальца к рамке ячейки-цели
///   снимок притягивается к ней (E8.9) — короткий spring, не влияющий на цели
///   E8.4/E8.6;
/// - **папки** (D14): перетаскивание ярлыка на папку — `addToFolder`; на центр
///   ярлыка — удержание (E8.6): пока палец стоит над целью меньше 600 мс или
///   уходит больше чем на 10 pt, drop не группирует (в центре — no-op E9.5), а
///   после
///   удержания цель подсвечивается «впитыванием» и drop вызывает `createFolder`
///   + `addToFolder`. Всё через `TileStore.approval`; отказ → анимация возврата
///   на место. Экран папки — минимальный sheet (`TesseraFolderViewController`),
///   в нём долгое нажатие на ярлык открывает меню «переместить в другую папку /
///   на рабочий стол», которое вызывает `TileStore.moveBetweenFolders` (тоже
///   через одобрение);
/// - **ярлык из папки** (E11.1): в режиме редактирования тап по папке
///   раскрывает панель, а долгое нажатие по иконке в панели мгновенно закрывает
///   её и поднимает ярлык (источник drag — папка, `TesseraTileDragSession.sourceFolderID`).
///   Бросить можно на сетку / пустое место — ярлык встаёт на ячейку превью
///   (`TileStore.extractFromFolder(_:toCell:columns:)`; D45: из папки в два
///   ярлыка вынос распускает её — оставшийся ярлык встаёт на её место, и превью
///   цели-размещения уже показывает этот итог); на центр другой папки с удержанием E8.6 —
///   перенос в неё; центр обычного ярлыка тут не создаёт папку (работает как
///   размещение на его ячейку); центр родной папки, панель и отмена возвращают
///   ярлык, модель не меняется;
///   делегат получает ровно один
///   `didMove(_:toFolder:atCell:)`.
///
/// ## Ограничения
///
/// - сетка не должна одновременно использовать свой `onLongPress` для другой
///   цели: координатор ставит собственный жест долгого нажатия; если хост всё же
///   задал `grid.onLongPress`, передайте оттуда `handleLongPress(on:at:)` —
///   дублирующий вызов игнорируется;
/// - в режиме редактирования хост должен сам решить, что делать с тапом по
///   плитке (`editor.isEditing`); координатор тапы не перехватывает, чтобы не
///   отбирать у хоста навигацию. Тап по папке в режиме редактирования
///   раскрывает нативную панель (E11.1), как и вне его;
/// - внутри панели нельзя менять порядок ярлыков перетаскиванием (E11.1:
///   вне объёма) — из неё ярлык только выносится на сетку или переносится в
///   другую папку.
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
            // E10.5-B4: диаметр кнопок входит в инициализатор оверлея, поэтому
            // контролы пересоздаются целиком, а «желе»/custom actions навешиваются
            // заново уже с новыми фазой и длительностью. Радиус/spring магнита и
            // пороги удержания читаются в момент использования — их достаточно
            // снять (см. выше).
            removeAllEditControls()
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
    /// «использовать набор по умолчанию». Хост задаёт **набор**, а не порядок:
    /// порядок цикла — малый → широкий → средний → большой — фиксирован
    /// (D28), недоступные размеры в нём пропускаются.
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
    ///
    /// Внутренний шов для тестов E10.5 (windowed-сессии проверяют зоны цели,
    /// `grabOffset` магнита, перевзвод удержания и позицию снимка). Публичным
    /// API не является: наружу отдаётся только ``isDragging``.
    private(set) var dragSession: TesseraTileDragSession?

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
    private(set) var mergeTracker: TesseraMergeHoverTracker?

    /// Рамка, в которую последний раз схлопывался снимок drag (E11.3); шов для тестов.
    private(set) var lastCollapseTargetFrame: CGRect?

    /// Таймер удержания (E8.6); `nil` — отсчёт не идёт.
    ///
    /// Отдельный `Timer`, а не тикер автопрокрутки: `CADisplayLink` крутится
    /// каждый кадр и на простое, а решение «удержание выдержано» нужно ровно
    /// один раз через `mergeHoverDuration`.
    private var mergeTimer: Timer?

    /// Кнопки «открепить»/«размер» поверх видимых плиток, по идентификатору.
    private(set) var editControls: [AnyHashable: TesseraTileEditControlView] = [:]

    /// Кнопки «открепить» на ярлыках панели раскрытой папки, по идентификатору
    /// ярлыка (D46).
    ///
    /// Живут в том же обрезающем контейнере, что и ``editControls``; только в
    /// режиме редактирования и только пока панель устоялась (не открывается и
    /// не закрывается). Кнопки «размер» у них нет: у члена папки своего
    /// размера нет.
    private(set) var panelEditControls: [AnyHashable: TesseraTileEditControlView] = [:]

    /// Обрезающий контейнер кнопок (E12.4): рамка = `bounds` сетки.
    ///
    /// Плитка обрезается границами коллекции (= `bounds` сетки), а кнопки —
    /// подвью самой сетки, поэтому раньше они выступали за край. Контейнер
    /// с `clipsToBounds` обрезает их по той же границе. Создаётся лениво.
    private(set) var editControlsHost: TesseraTileEditControlsHostView?

    /// Фазы «желе» по идентификатору плитки (кеш до смены конфигурации).
    private var jiggleSpecs: [AnyHashable: TesseraJiggleSpec] = [:]

    /// Ячейки, которым координатор выставил custom actions (чтобы снять их в конце).
    private var cellsWithEditActions: [ObjectIdentifier: TesseraTileCell] = [:]

    /// Подпись custom actions ячейки: идентификатор плитки, папка-владелец (для
    /// ярлыка панели) и состав доступных папок — пропуск повторов, но не
    /// устаревших действий после создания/удаления папки (E11.5).
    private var editActionsItemByCell: [ObjectIdentifier: [AnyHashable]] = [:]

    /// Максимум пунктов «в папку»/«в другую папку» у одной плитки (E11.5):
    /// ротор VoiceOver с десятками действий неудобен, поэтому берутся первые
    /// папки в порядке сетки.
    static let maxFolderActions = 6

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

    /// Идёт ли внешнее изменение модели во время drag (E10.5-B1).
    ///
    /// `TileStore` сообщает о мутации до её применения (`objectWillChange`),
    /// поэтому подписчик координатора только взводит флаг: сравнение снимков —
    /// на ближайшем шаге drag. Собственные мутации координатора происходят
    /// после `dragSession = nil`, так что флаг взводится только чужой записью.
    private var storeChangedDuringDrag = false

    /// Ярлыки, для которых уже играет fly-out открепления (E10.5-B3).
    ///
    /// Двойной быстрый тап по булавке не должен запускать вторую анимацию и
    /// вторую мутацию: пока снимок летит, повторный вызов ``unpin(_:)`` для
    /// того же ярлыка игнорируется.
    private var unpinsInFlight: Set<AnyHashable> = []

    /// Публикация accessibility-уведомлений режима редактирования (E10.5-B6).
    ///
    /// По умолчанию — `UIAccessibility.post(notification:argument:)`.
    /// Внутренний шов для тестов: `.layoutChanged` после unpin/resize/move
    /// нельзя наблюдать средствами системы без включённого VoiceOver.
    var accessibilityNotificationPoster: (UIAccessibility.Notification, Any?) -> Void = {
        UIAccessibility.post(notification: $0, argument: $1)
    }

    /// Ключ анимации «желе» на слое.
    static let jiggleKey = "tessera.edit.jiggle"

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
        reportGridWidthToStore()
        // E14.5: смена числа колонок сетки меняет ширину холста — сообщаем её
        // хранилищу (ячейки хранятся на холсте конкретной ширины, D32).
        grid.columnsDidChange = { [weak self] _ in
            self?.gridColumnsDidChange()
        }
        // E11.5: панель раскрытой папки переконфигурируется при каждом снимке —
        // custom actions её ярлыков добираются отложенной сверкой.
        grid.panelShortcutsDidConfigure = { [weak self] _, _ in
            self?.scheduleReconcile()
        }
        // D46: кнопки открепления на ярлыках панели появляются, когда панель
        // устоялась, и уходят, как только она начинает закрываться.
        grid.folderPanelStateDidChange = { [weak self] in
            guard let self, self.isEditing else { return }
            self.reconcilePanelEditControls(fadesIn: true)
        }
    }

    deinit {
        grid.folderPanelStateDidChange = nil
        grid.panelShortcutsDidConfigure = nil
        grid.columnsDidChange = nil
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

        // E10.5-B2: незавершённая drag-сессия — состояние сетки, а не модели.
        // Снимаем её целиком: базовый порядок, скрытая ячейка, прокрутка,
        // оверлеи и хвостовые аниматоры. Иначе координатор может исчезнуть,
        // оставив сетку с невидимой ячейкой, выключенным скроллом и чужим
        // порядком — без хозяина, который это починит.
        let interruptedSession = dragSession
        dragSession = nil
        stopPlaceholderAnimation()
        interruptedSession?.dragView.removeFromSuperview()
        interruptedSession?.placeholder.removeFromSuperview()
        if let session = interruptedSession {
            if !gridMatches(session.baseSnapshot) {
                grid.update(snapshot: session.baseSnapshot, animated: false)
            }
            grid.setItemHidden(false, forItemID: session.itemID)
            // n1 (фикс-раунд W4): прокрутку выключает только drag-сессия,
            // поэтому восстанавливаем её лишь после прерванного drag, а не
            // безусловно (иначе deinit затирал бы намерение хоста).
            grid.isScrollEnabled = true
        }

        // Оверлеи — подвью сетки: если их не убрать, они переживут координатор.
        for control in editControls.values {
            control.removeFromSuperview()
        }
        editControls.removeAll()
        dropHighlightView?.removeFromSuperview()
        dropHighlightView = nil

        for cell in cellsWithEditActions.values {
            cell.accessibilityCustomActions = nil
        }
        cellsWithEditActions.removeAll()
        editActionsItemByCell.removeAll()

        for item in grid.items {
            if let cell = grid.cellView(forItemID: item.id) as? TesseraTileCell {
                // «Желе» живёт на слое содержимого ячейки (см. applyJiggle).
                cell.contentView.layer.removeAnimation(
                    forKey: TesseraTileEditCoordinator.jiggleKey
                )
            }
        }
        // E8.2/E10.4: дим снимает сетка — она владелец прозрачности.
        grid.setEditDimming(liftedDimmingTargets(), animated: false)
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
            // E10.5-B1: мутация модели во время drag взводит флаг — на
            // ближайшем шаге сессия сверит снимок с базой и безопасно отменится.
            // `objectWillChange` приходит до изменения, поэтому саму сверку
            // делает отложенная ``scheduleReconcile()`` (хост успевает
            // применить снимок к сетке).
            if self.dragSession != nil {
                self.storeChangedDuringDrag = true
            }
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
    ///   полной яркости, остальные гаснут до ``TesseraTileGridView/dimmedTileAlpha``. `nil` — вход
    ///   с пустого места, гаснут все плитки.
    private func beginEditing(focusing itemID: AnyHashable?) {
        guard !isEditing, isEnabled else { return }

        isEditing = true
        dimmingFocusID = itemID
        backgroundTapRecognizer.isEnabled = true
        // E10.5-A4: раскрытая панель папки закрывается при входе в edit штатным
        // `closeFolder` (при Reduce Motion — мгновенно). Иначе drag начинается
        // поверх панели: её место в раскладке фиксировано, а строки под ней
        // сдвинуты. После неанимированного (reloadData) закрытия ячейки
        // пересоздаются — отложенная сверка вернёт им «желе» и дим.
        closeExpandedFolderForEditing()
        // E14.5: ширина сетки — хранилищу, а сетка показывает его ячейки: будущий
        // drag, в том числе из панели папки, считает цели по тем же ячейкам.
        prepareModelForEditing()
        reconcileEditControls(animated: false, dimAnimated: true)
        // Ячейки могут быть ещё не созданы (первый layout/показ): доберём
        // кнопки, «желе» и димминг на следующем проходе runloop.
        scheduleReconcile()

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        announce(TesseraStartScreenStrings.string(.a11yEditingEntered))
        delegate?.tileEditCoordinatorDidBeginEditing(self)
    }

    /// Закрывает панель раскрытой папки, если она открыта (E10.5-A4).
    ///
    /// Вызывается при входе в редактирование и старте drag: панель —
    /// полноширинная строка, сдвигающая раскладку, и drag по ней запрещён.
    /// Анимация панели своя (D17); при Reduce Motion и вне окна `closeFolder`
    /// сам выберет мгновенную ветку.
    private func closeExpandedFolderForEditing() {
        guard grid.expandedFolderID != nil else { return }
        grid.closeFolder(animated: !isReduceMotionEnabled())
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

        announce(TesseraStartScreenStrings.string(.a11yEditingExited))
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

        // E10.5-A4/E9.8а: панель не плитка, её место фиксировано раскладкой.
        // Вне редактирования долгое нажатие по панели только входит в
        // редактирование (и закрывает панель штатно).
        // E11.1: в режиме редактирования долгое нажатие по иконке панели
        // поднимает ярлык (источник — папка); вне панельной иконки (заголовок,
        // фон) ничего не происходит.
        guard !item.isFolderPanel else {
            if isEditing {
                startDragFromPanel(at: point)
            } else {
                beginEditing()
            }
            return
        }
        guard grid.index(ofItemID: item.id) != nil else { return }

        // m3 (фикс-раунд W4): drag стартует сразу за long-press, поэтому панель
        // закрывается **мгновенно** (`closeFolder(animated: false)`), а не
        // анимированно: иначе первые кадры drag шли бы поверх сдвигающейся
        // раскладки, а превью уходили бы в отложенный снимок сетки (M1).
        // Для публичного `beginEditing()` без drag анимация закрытия остаётся.
        closeExpandedFolderInstantlyIfNeeded()
        // E14.5: ячейки модели и сетки — до захвата базы drag'а (и при уже
        // включённом edit: хост мог поменять модель, пока edit был открыт).
        prepareModelForEditing()
        if !isEditing {
            beginEditing(focusing: item.id)
        }
        startDrag(itemID: item.id, at: point)
    }

    /// Закрывает панель папки мгновенно перед стартом drag (m3).
    ///
    /// Если панель уже закрывается анимированно (переход панели идёт), сетка
    /// откладывает команду закрытия (last-wins); это не ошибка — M1-страховка
    /// в ``syncGridWithModel(animated:)``/``render(animated:)`` не даст
    /// устаревшему превью примениться после перехода.
    private func closeExpandedFolderInstantlyIfNeeded() {
        guard grid.expandedFolderID != nil else { return }
        grid.closeFolder(animated: false)
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
    /// ``TileStore/unpin(_:columns:)`` — модель меняется, когда плитка уже
    /// улетела. Ячейка ярлыка остаётся дырой (D30); полностью опустевшая строка
    /// схлопывается (``TileStore/collapseEmptyRows(columns:)``, D31). Если
    /// хранилище отказывает, ячейка возвращается на место.
    ///
    /// Папку открепить нельзя (она существует, пока в ней есть ярлыки), поэтому
    /// для папки метод ничего не делает. Ярлык внутри папки на сетке не показан:
    /// для него операция сразу идёт в хранилище; если в папке было два ярлыка,
    /// она распускается (D45): раскрытая панель закрывается, оставшийся ярлык
    /// встаёт на место папки, делегат после `didUnpin` получает `didDissolveFolder`,
    /// а фокус VoiceOver уходит на оставшийся ярлык (при трёх и более — на соседний
    /// ярлык панели: следующий, у последнего — предыдущий).
    ///
    /// - Parameter tileID: Идентификатор ярлыка.
    public func unpin(_ tileID: AnyHashable) {
        guard dragSession == nil else { return }
        // E10.5-B3: пока снимок ярлыка летит, повторный тап по булавке
        // игнорируется — один fly-out, одна мутация, один колбэк.
        guard !unpinsInFlight.contains(tileID) else { return }
        unpinsInFlight.insert(tileID)

        guard let item = grid.items.first(where: { $0.id == tileID }) else {
            // Ярлык лежит в папке или уже откреплён — анимировать нечего.
            performImmediateUnpin(tileID)
            return
        }
        guard item.tile != nil else {
            unpinsInFlight.remove(tileID)
            return
        }

        guard let cell = grid.cellView(forItemID: tileID) as? TesseraTileCell,
              let frame = grid.frame(forItemID: tileID),
              let snapshot = TesseraTileEditCoordinator.makeSnapshot(of: cell) else {
            performImmediateUnpin(tileID)
            return
        }

        // E14.7: цель фокуса выбирается до удаления, по порядку чтения: следующий
        // элемент после ярлыка (или предыдущий, если он был последним). Индекс
        // «на месте удалённого» не годится: дыры и схлопывание строк не меняют
        // порядок оставшихся, но место ярлыка может остаться пустым.
        let focus = UnpinFocus.gridItem(focusTarget(afterRemoving: tileID))

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
            completion: { [weak self, weak grid] _ in
                snapshot.removeFromSuperview()
                // E10.5-B2: координатор мог исчезнуть посреди fly-out
                // (deinit) — ячейку всё равно возвращаем, иначе плитка
                // останется невидимой, а модель — закреплённой.
                guard let self else {
                    grid?.setItemHidden(false, forItemID: tileID)
                    return
                }

                self.unpinsInFlight.remove(tileID)
                let removed = self.store.unpin(tileID, columns: self.storeColumns)
                self.grid.setItemHidden(false, forItemID: tileID)

                guard removed else {
                    self.reconcileEditControls(animated: false)
                    return
                }

                // E14.5: уход ярлыка оставил дыру; пустая строка схлопывается,
                // затем сетка синхронизируется со снимком store.
                self.store.collapseEmptyRows(columns: self.storeColumns)
                self.render(animated: true)
                self.delegate?.tileEditCoordinator(self, didUnpin: tileID)
                self.postLayoutChanged(afterUnpinning: focus)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.announce(TesseraStartScreenStrings.string(.a11yTileUnpinned))
            }
        )
    }

    /// Открепление ярлыка раскрытой панели кнопкой на нём (D46).
    ///
    /// Тот же сценарий, что у кнопки на плитке сетки: ярлык улетает (снимок
    /// иконки уменьшается и гаснет), затем идёт обычное открепление ярлыка папки
    /// ``performImmediateUnpin(_:)`` — ``TileStore/unpin(_:columns:)``, `didUnpin`,
    /// правило D45 (в папке из двух ярлыков она распускается, панель
    /// закрывается, оставшийся ярлык встаёт на место папки, `didDissolveFolder`)
    /// и фокус VoiceOver (оставшийся ярлык / следующий в панели, у последнего —
    /// предыдущий). Подтверждения нет. Reduce Motion — без полёта, мгновенно.
    ///
    /// Публичное ``unpin(_:)`` (в том числе действие VoiceOver) остаётся
    /// синхронным и без полёта: анимация относится только к тапу по кнопке.
    ///
    /// - Parameter tileID: Идентификатор ярлыка папки.
    func unpinPanelTile(_ tileID: AnyHashable) {
        guard isEditing, dragSession == nil, unpinsInFlight.isEmpty else { return }

        guard !isReduceMotionEnabled(),
              let panel = grid.panelShortcuts(),
              let index = panel.folder.tiles.firstIndex(where: { $0.id == tileID }),
              panel.cells.indices.contains(index),
              let geometry = grid.panelShortcutGeometry(),
              geometry.tileIDs == panel.folder.tiles.map({ $0.id }),
              let snapshot = TesseraTileEditCoordinator.makeSnapshot(of: panel.cells[index]) else {
            unpin(tileID)
            reconcilePanelEditControls(fadesIn: false)
            return
        }

        let cell = panel.cells[index]
        let frame = geometry.frames[index]
        unpinsInFlight.insert(tileID)
        removePanelControl(for: tileID)
        cell.alpha = 0

        snapshot.frame = frame
        snapshot.isUserInteractionEnabled = false
        snapshot.layer.zPosition = 1000
        snapshot.layer.shadowColor = UIColor.black.cgColor
        snapshot.layer.shadowOpacity = 0.2
        snapshot.layer.shadowRadius = 12
        snapshot.layer.shadowOffset = CGSize(width: 0, height: 6)
        grid.addSubview(snapshot)

        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseIn],
            animations: {
                snapshot.alpha = 0
                // frame при не-единичном transform не определён — bounds/center.
                snapshot.bounds = CGRect(
                    origin: .zero,
                    size: CGSize(width: frame.width * 0.35, height: frame.height * 0.35)
                )
                snapshot.center = CGPoint(x: frame.midX, y: frame.midY - 48)
            },
            completion: { [weak self] _ in
                snapshot.removeFromSuperview()
                // Ячейка прозрачна на время полёта: без мутации модели её надо
                // вернуть, иначе ярлык останется невидимым. При успехе ячейку
                // переконфигурирует сетка (`configure` сбрасывает прозрачность).
                guard let self else {
                    cell.alpha = 1
                    return
                }

                let stillInPanel = self.isEditing && self.dragSession == nil
                    && self.grid.panelShortcuts()?.folder.tiles.contains { $0.id == tileID } == true
                guard stillInPanel else {
                    // Панель закрыли или ярлык ушёл, пока он летел: мутации нет.
                    cell.alpha = 1
                    self.unpinsInFlight.remove(tileID)
                    self.reconcilePanelEditControls(fadesIn: false)
                    return
                }

                // `performImmediateUnpin` сам снимает `unpinsInFlight`.
                self.performImmediateUnpin(tileID)
                if self.store.isPinned(tileID) {
                    // Хранилище отказало: ярлык остаётся в папке.
                    cell.alpha = 1
                }
                self.reconcilePanelEditControls(fadesIn: false)
            }
        )
    }

    /// Немедленное открепление без анимации (ячейка вне экрана/ярлык в папке).
    ///
    /// Ярлык внутри папки (в том числе в раскрытой панели, где его снимает
    /// VoiceOver-действие «Открепить») подчиняется правилу D45: если в папке
    /// остаётся один ярлык, папка **распускается** — панель закрывается (штатным
    /// `closeFolder`, анимированно, при Reduce Motion мгновенно), а оставшийся
    /// ярлык встаёт на место папки; фокус VoiceOver уходит на него. Если в папке
    /// остаётся два и больше, панель остаётся, а фокус — на **следующем** ярлыке
    /// панели в порядке отображения (на последнем — на предыдущем). Делегат
    /// получает `didUnpin`, затем `didDissolveFolder`.
    ///
    /// - Parameter tileID: Идентификатор ярлыка.
    private func performImmediateUnpin(_ tileID: AnyHashable) {
        // Удаляем запись в любом исходе: повторный unpin после отказа
        // хранилища должен снова иметь право на попытку.
        defer { unpinsInFlight.remove(tileID) }

        // E14.7/D45: цель фокуса выбирается до удаления. Ярлык на сетке (ячейка
        // вне экрана) — сосед по порядку чтения; ярлык в папке — оставшийся
        // ярлык распавшейся папки либо соседний ярлык панели.
        let dissolution = dissolutionPlan(whenRemoving: tileID)
        let focus = unpinFocus(for: tileID, dissolution: dissolution)
        guard store.unpin(tileID, columns: storeColumns) else { return }
        // E14.5: дыра остаётся, пустая строка схлопывается (D31).
        store.collapseEmptyRows(columns: storeColumns)
        // D45: панель распавшейся папки закрывается раньше, чем сетка применит
        // снимок без папки (сетка отложит снимок до конца анимации закрытия).
        closePanel(ofDissolving: dissolution)
        render(animated: true)
        delegate?.tileEditCoordinator(self, didUnpin: tileID)
        notifyDissolution(dissolution)
        postLayoutChanged(afterUnpinning: focus)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        announce(TesseraStartScreenStrings.string(.a11yTileUnpinned))
    }

    // MARK: - Resize

    /// Циклически меняет размер элемента: small → wide → medium → large → small
    /// (docs/STARTSCREEN-IOS-DESIGN.md §5, D15, D28, E15.3).
    ///
    /// Порядок цикла задан явно в `TileSize.cycleOrder` (порядок W10M с `large`
    /// в конце), а не порядком `allCases` и не порядком списка хоста.
    /// Поддерживаемые размеры по умолчанию — все четыре, которые помещаются в
    /// число колонок сетки (широкая плитка требует четырёх). Хост может сузить
    /// набор через ``supportedSizesProvider``: неподдерживаемые размеры цикл
    /// пропускает. Тот же шаг делает действие VoiceOver «Изменить размер»
    /// (оно вызывает этот метод). Переупаковку выполняет
    /// `TileStore` + `TesseraTileGridView.update(snapshot:animated:)`: раскладка
    /// пересчитывается `TileLayoutEngine`, соседи переезжают batch-анимацией.
    ///
    /// E14.5: resize идёт через ``TileStore/resize(_:to:columns:)`` —
    /// якорная ячейка остаётся, рост выталкивает мешающие плитки вниз каскадом
    /// (D31), уменьшение оставляет дыру; затем схлопывается только полностью
    /// пустая строка (``TileStore/collapseEmptyRows(columns:)``).
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

        let next = item.size.next(among: sizes)
        guard next != item.size,
              store.resize(itemID, to: next, columns: storeColumns) else {
            return nil
        }

        store.collapseEmptyRows(columns: storeColumns)
        render(animated: true)
        delegate?.tileEditCoordinator(self, didResize: itemID, to: next)
        // E10.5-B6: после resize плитка переехала — фокус VoiceOver переводим
        // на её новую рамку (на следующий проход runloop, когда ячейка уже
        // разложена).
        postLayoutChanged(focusing: itemID)
        UISelectionFeedbackGenerator().selectionChanged()
        let sizeName = TesseraTileEditCoordinator.name(for: next)
        announce(String(format: TesseraStartScreenStrings.string(.a11yResizeFormat), sizeName))
        return next
    }

    /// Список размеров, доступных элементу.
    ///
    /// - Parameter item: Ярлык или папка.
    /// - Returns: Поддерживаемые размеры (порядок цикла задаёт `TileSize.cycleOrder`,
    ///   D28); никогда не пустой.
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

    /// Переставляет элемент сетки на ячейку через `TileStore` (§6, E14.6).
    ///
    /// Операция раскладки не требует одобрения (D14). Элемент встаёт на `cell`,
    /// ограниченную холстом; мешающие плитки выталкиваются вниз каскадом (D31),
    /// дыра на старом месте остаётся, полностью пустая строка схлопывается
    /// (``TileStore/moveItem(_:toCell:columns:)``,
    /// ``TileStore/collapseEmptyRows(columns:)``). Делегат получает итоговую
    /// ячейку элемента; сетка синхронизируется со снимком хранилища.
    ///
    /// - Parameters:
    ///   - itemID: Идентификатор ярлыка или папки на сетке.
    ///   - cell: Желаемая ячейка левого верхнего угла (логические координаты).
    /// - Returns: `true`, если раскладка изменилась.
    @discardableResult
    public func move(_ itemID: AnyHashable, toCell cell: TileGridPlacement) -> Bool {
        finishMove(of: itemID, moved: store.moveItem(itemID, toCell: cell, columns: storeColumns))
    }

    /// Переставляет элемент сетки в новую строку в конце холста (E14.6, D33).
    ///
    /// Как ``move(_:toCell:)``, но цель — ``TileStore/moveItemToNewRow(_:columns:)``.
    ///
    /// - Parameter itemID: Идентификатор ярлыка или папки на сетке.
    /// - Returns: `true`, если раскладка изменилась.
    @discardableResult
    public func moveToNewRow(_ itemID: AnyHashable) -> Bool {
        finishMove(of: itemID, moved: store.moveItemToNewRow(itemID, columns: storeColumns))
    }

    /// Общий хвост ``move(_:toCell:)`` и ``moveToNewRow(_:)``: схлопывание пустой
    /// строки, синхронизация сетки, делегат, фокус VoiceOver.
    private func finishMove(of itemID: AnyHashable, moved: Bool) -> Bool {
        guard moved else { return false }

        let columns = storeColumns
        store.collapseEmptyRows(columns: columns)
        render(animated: true)
        if let cell = store.placements(forColumns: columns)[itemID] {
            delegate?.tileEditCoordinator(self, didMove: itemID, toCell: cell)
        }
        // E10.5-B6: элемент переехал — переводим фокус VoiceOver на его ячейку
        // после раскладки.
        postLayoutChanged(focusing: itemID)
        return true
    }

    // MARK: - Папки (D14: только через функцию одобрения хоста)

    /// Создаёт папку из ярлыка на сетке.
    ///
    /// Вся проверка — внутри хранилища: хост получает
    /// `TileGroupingAction.createFolder`; отказ оставляет модель нетронутой.
    /// Папка встаёт на ячейку ярлыка (2×2, D20), соседи выталкиваются вниз
    /// (D31). Создание папки из двух ярлыков drop'ом делает
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
            title: resolvedNewFolderTitle(title ?? configuration.folderTitle),
            columns: storeColumns
        )
        guard let folder else {
            if grid.index(ofItemID: tileID) != nil {
                notifyGroupingFailure(.createFolder, tileID: tileID, folderID: nil)
            }
            return nil
        }

        render(animated: true)
        delegate?.tileEditCoordinator(self, didCreateFolder: folder)
        postLayoutChanged(focusing: folder.id)
        announce(TesseraStartScreenStrings.string(.a11yFolderCreated))
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
        guard store.addToFolder(tileID, folderID: folderID, columns: storeColumns) else {
            notifyGroupingFailure(.addToFolder, tileID: tileID, folderID: folderID)
            return false
        }

        // E14.5: ячейка ярлыка осталась дырой; пустая строка схлопывается.
        store.collapseEmptyRows(columns: storeColumns)
        render(animated: true)
        delegate?.tileEditCoordinator(self, didAdd: tileID, toFolder: folderID)
        postLayoutChanged(focusing: folderID)
        announce(TesseraStartScreenStrings.string(.a11yFolderTileAdded))
        return true
    }

    /// Перемещает ярлык между папками или из папки на рабочий стол (D14).
    ///
    /// Вынос на рабочий стол идёт по ячейкам
    /// (``TileStore/extractFromFolder(_:toCell:columns:)``): ярлык встаёт на
    /// ячейку папки (если он в ней последний) либо на первую свободную ячейку
    /// после ячейки папки в порядке чтения (после распада папки, см. ниже, —
    /// с учётом ярлыка, занявшего её место). Перенос в другую папку —
    /// ``TileStore/moveBetweenFolders(_:to:columns:)``. После операции
    /// схлопывается пустая строка, фокус VoiceOver — на ярлыке.
    ///
    /// D45: если в папке-источнике было два ярлыка, она распускается — оставшийся
    /// ярлык встаёт на её место со своим размером, раскрытая панель закрывается, а
    /// делегат после `didMove` получает `didDissolveFolder`.
    ///
    /// - Parameters:
    ///   - tileID: Ярлык, лежащий в папке.
    ///   - folderID: Папка-цель; `nil` — на рабочий стол.
    /// - Returns: `true`, если перемещение выполнено.
    @discardableResult
    public func moveBetweenFolders(_ tileID: AnyHashable, to folderID: AnyHashable?) -> Bool {
        let columns = storeColumns
        let dissolution = dissolutionPlan(whenRemoving: tileID)
        let moved: Bool
        if let folderID {
            moved = store.moveBetweenFolders(tileID, to: folderID, columns: columns)
        } else if let cell = extractionCell(forTile: tileID, columns: columns) {
            moved = store.extractFromFolder(tileID, toCell: cell, columns: columns)
        } else {
            moved = store.extractFromFolderToNewRow(tileID, columns: columns)
        }
        guard moved else {
            notifyGroupingFailure(.moveBetweenFolders, tileID: tileID, folderID: folderID)
            return false
        }

        store.collapseEmptyRows(columns: columns)
        closePanel(ofDissolving: dissolution)
        render(animated: true)
        // E11.1/E14.6: единый колбэк с ячейкой (по умолчанию пересылает в
        // `didMove(_:toFolder:)`).
        delegate?.tileEditCoordinator(
            self,
            didMove: tileID,
            toFolder: folderID,
            atCell: folderID == nil ? store.placements(forColumns: columns)[tileID] : nil
        )
        notifyDissolution(dissolution)
        // D45: решение по модели, а не по сетке: при закрытии панели распавшейся
        // папки сетка отложила снимок, и вынесенного ярлыка в ней ещё нет.
        if folderID == nil {
            postLayoutChanged(focusing: tileID)
        } else if let folderID = folderID {
            postLayoutChanged(focusing: folderID)
        }
        announce(TesseraStartScreenStrings.string(folderID == nil ? .a11yFolderTileOnStart : .a11yFolderTileMoved))
        return true
    }

    /// Ячейка для ярлыка, выносимого из папки без жеста (E14.5, E14.6).
    ///
    /// - Parameters:
    ///   - tileID: Ярлык в папке.
    ///   - columns: Число колонок сетки.
    /// - Returns: Ячейка папки-источника, если ярлык в ней последний (папка
    ///   исчезнет), иначе первая свободная ячейка после неё; `nil` — подходит
    ///   только новая строка (нет папки-источника).
    private func extractionCell(
        forTile tileID: AnyHashable,
        columns: Int
    ) -> TileGridPlacement? {
        let snapshot = store.snapshot(columns: columns)
        let placed = placedItems(of: snapshot)

        guard let folder = store.folderContaining(tileID),
              let folderCell = placed.first(where: { $0.id == folder.id })?.cell,
              let tile = folder.tiles.first(where: { $0.id == tileID }) else {
            return nil
        }
        // Последний ярлык папки: она исчезнет, и ярлык занимает её ячейку.
        if folder.tiles.count == 1 { return folderCell }
        // D45: из папки в два ярлыка уходит один — папка распадётся, и оставшийся
        // ярлык займёт её ячейку со своим размером; свободную ячейку ищем уже в
        // такой раскладке, чтобы вынесенный ярлык не оказался на оставшемся.
        var layout = placed
        if folder.tiles.count == 2, let remaining = folder.tiles.first(where: { $0.id != tileID }) {
            layout = TileLayoutEngine.inserting(
                id: remaining.id,
                size: remaining.size,
                at: folderCell,
                into: TileLayoutEngine.removing(id: folder.id, from: placed),
                columns: columns
            )
        }
        return firstFreeCell(for: tile.size, after: folderCell, in: layout, columns: columns)
    }

    /// Активирует ярлык со встроенного экрана папки общим маршрутом сетки
    /// (E10.5-C3).
    ///
    /// Тап по ярлыку внутри `TesseraFolderViewController` — это событие
    /// ``TesseraTileGridView/onTap``, а не прямой вызов `TileDescriptor.action`:
    /// хост получает тап один раз и тем же маршрутом, что и тап по плитке
    /// сетки. В режиме редактирования действие не выполняется (тап
    /// принадлежит координатору).
    ///
    /// - Parameter tile: Ярлык из содержимого папки.
    /// - Returns: `true`, если событие передано хосту.
    @discardableResult
    func activateTileFromFolder(_ tile: TileDescriptor) -> Bool {
        guard !isEditing else { return false }
        grid.forwardTileTap(tile)
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
        announce(TesseraStartScreenStrings.string(.a11yFolderUnavailable))
        delegate?.tileEditCoordinator(
            self,
            didFailGrouping: action,
            tileID: tileID,
            folderID: folderID
        )
    }

    // MARK: - Распад папки (D45)

    /// Распад папки, который вызовет уход ярлыка из неё (D45).
    private struct FolderDissolutionPlan {

        /// Папка, в которой два ярлыка.
        let folderID: AnyHashable

        /// Ярлык, который останется и займёт её место.
        let remainingTileID: AnyHashable
    }

    /// Куда уйдёт фокус VoiceOver после открепления (E14.7, D45).
    private enum UnpinFocus {

        /// Ярлык был на сетке: сосед по порядку чтения (`nil` — цели нет).
        case gridItem(AnyHashable?)

        /// Папка распалась: оставшийся ярлык, ставший элементом сетки.
        case dissolvedTile(AnyHashable)

        /// Папка пережила открепление: соседний ярлык её панели.
        case panelTile(AnyHashable, folderID: AnyHashable)
    }

    /// Распадётся ли папка, если убрать из неё ярлык (D45).
    ///
    /// Папка с двумя ярлыками, потеряв один, распускается (``TileStore``:
    /// `minimumFolderTileCount`). Считается **до** операции хранилища, по его
    /// снимку: после неё папки в модели уже нет.
    ///
    /// - Parameter tileID: Ярлык, который уйдёт из папки.
    /// - Returns: План распада или `nil` (ярлык не в папке либо папка переживёт уход).
    private func dissolutionPlan(whenRemoving tileID: AnyHashable) -> FolderDissolutionPlan? {
        guard let folder = store.folderContaining(tileID),
              folder.tiles.count == 2,
              let remaining = folder.tiles.first(where: { $0.id != tileID }) else {
            return nil
        }
        return FolderDissolutionPlan(folderID: folder.id, remainingTileID: remaining.id)
    }

    /// Закрывает раскрытую панель папки, которая вот-вот распадётся (D45).
    ///
    /// Вызывается **до** `render`: пока сетка показывает прежний снимок, штатный
    /// `closeFolder` анимирует закрытие (при Reduce Motion и вне окна —
    /// мгновенно), а снимок без папки сетка отложит до конца перехода (E10.2).
    ///
    /// - Parameter plan: План распада.
    private func closePanel(ofDissolving plan: FolderDissolutionPlan?) {
        guard let plan, grid.expandedFolderID == plan.folderID else { return }
        grid.closeFolder(animated: !isReduceMotionEnabled())
    }

    /// Сообщает делегату о распаде папки-источника drag-сессии после успешного
    /// drop (D45): папка распадается, если в ней было два ярлыка.
    private func notifyDissolution(of session: TesseraTileDragSession) {
        guard let dissolution = session.folderDissolution else { return }
        delegate?.tileEditCoordinator(
            self,
            didDissolveFolder: dissolution.folderID,
            remainingTile: dissolution.remaining.id
        )
    }

    /// Сообщает делегату о распаде папки после успешной операции (D45).
    private func notifyDissolution(_ plan: FolderDissolutionPlan?) {
        guard let plan else { return }
        delegate?.tileEditCoordinator(
            self,
            didDissolveFolder: plan.folderID,
            remainingTile: plan.remainingTileID
        )
    }

    /// Цель фокуса VoiceOver после открепления ярлыка (E14.7, D45).
    ///
    /// - Parameters:
    ///   - tileID: Открепляемый ярлык.
    ///   - dissolution: План распада его папки, если она распадётся.
    /// - Returns: Цель: оставшийся ярлык распавшейся папки; соседний ярлык
    ///   панели (следующий в порядке отображения, у последнего — предыдущий);
    ///   для ярлыка на сетке — сосед по порядку чтения (``focusTarget(afterRemoving:)``).
    private func unpinFocus(for tileID: AnyHashable, dissolution: FolderDissolutionPlan?) -> UnpinFocus {
        if let dissolution { return .dissolvedTile(dissolution.remainingTileID) }
        if let folder = store.folderContaining(tileID) {
            let tiles = folder.tiles
            if let index = tiles.firstIndex(where: { $0.id == tileID }) {
                if tiles.indices.contains(index + 1) { return .panelTile(tiles[index + 1].id, folderID: folder.id) }
                if index > 0 { return .panelTile(tiles[index - 1].id, folderID: folder.id) }
            }
            // Единственный ярлык переходной папки: папка исчезнет без остатка.
            return .gridItem(nil)
        }
        return .gridItem(focusTarget(afterRemoving: tileID))
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
        let snapshot = modelSnapshot()

        // M1 (фикс-раунд W4): при идущем переходе панели папки у сетки может
        // быть отложенный снимок (pending); снимок модели передаётся всегда,
        // чтобы заменить его (last-wins, E10.2).
        if !gridMatches(snapshot) || grid.isFolderChangeAnimating {
            grid.update(snapshot: snapshot, animated: animated && !isReduceMotionEnabled())
        }

        if isEditing {
            reconcileEditControls(animated: animated)
            // Новые ячейки коллекция создаёт в своём layout-проходе: повторная
            // сверка после него добавит им custom actions и «желе».
            scheduleReconcile()
        }
    }

    /// Число колонок для операций хранилища: реальная ширина сетки (E14.5).
    ///
    /// Ячейки хранятся на холсте этой ширины (D32), поэтому её получают все
    /// операции по ячейкам и снимок `snapshot(columns:)`.
    private var storeColumns: Int {
        max(1, grid.columns)
    }

    /// Снимок модели для сетки: порядок, размеры, папки и таблица ячеек под
    /// ширину сетки (E14.5, ``TileStore/snapshot(columns:)``).
    private func modelSnapshot() -> TileGridSnapshot {
        store.snapshot(columns: storeColumns)
    }

    /// Совпадает ли текущий снимок сетки с моделью (порядок, размеры, папки и
    /// ячейки).
    ///
    /// - Parameter snapshot: Снимок из `TileStore`.
    /// - Returns: `true`, если сетке нечего обновлять.
    private func gridMatches(_ snapshot: TileGridSnapshot) -> Bool {
        gridItemsMatch(snapshot) && gridPlacementsMatch(snapshot)
    }

    /// Совпадают ли с моделью порядок, размеры и папки сетки (без ячеек).
    ///
    /// - Parameter snapshot: Снимок из `TileStore`.
    /// - Returns: `true`, если состав и содержимое папок те же.
    private func gridItemsMatch(_ snapshot: TileGridSnapshot) -> Bool {
        // E14.7: сетка держит элементы в порядке чтения ячеек; ожидаемый снимок
        // приводится к нему тем же правилом.
        let expectedItems = grid.readingOrdered(snapshot).items
        let currentItems = grid.items
        guard currentItems.count == expectedItems.count else { return false }

        for (current, expected) in zip(currentItems, expectedItems) {
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

    /// Показывает ли сетка ту же таблицу ячеек, что и снимок (E14.5).
    ///
    /// Без неё превью, у которого изменились только ячейки (те же элементы в том
    /// же порядке), выглядело бы «ничего не изменилось» и тихо отбрасывалось.
    ///
    /// - Parameter snapshot: Ожидаемый снимок.
    /// - Returns: `true`, если таблицы равны (в том числе обе отсутствуют).
    private func gridPlacementsMatch(_ snapshot: TileGridSnapshot) -> Bool {
        grid.snapshot?.placementTable == snapshot.placementTable
    }

    // MARK: - Синхронизация и accessibility (E10.5)

    /// Сообщает `TileStore` ширину сетки (E14.1, D33).
    ///
    /// Хранилище узнаёт ширину только от хоста: по ней оно назначает ячейки
    /// файлу версии 1 и раскладке первого запуска (``TileStore/placeItems(columns:)``,
    /// однократно и без уведомления подписчиков), а затем пересчитывает ячейки
    /// после операций. Вызывается при создании координатора и на входе в
    /// правку/drag.
    private func reportGridWidthToStore() {
        guard grid.columns > 0 else { return }
        store.placeItems(columns: grid.columns)
    }

    /// Готовит модель и сетку к редактированию (E14.5).
    ///
    /// Сообщает хранилищу ширину сетки и, если сетка показывает те же элементы,
    /// но без таблицы ячеек модели (хост построил её из `snapshot()` или
    /// ``TileStore/snapshot(columns:)`` с другой шириной), подтягивает её без
    /// анимации: цели drag и превью считаются по ячейкам, и они обязаны
    /// совпадать с кадрами на экране. Расхождение состава, принесённое хостом,
    /// по-прежнему ловит m2-проверка на захвате.
    private func prepareModelForEditing() {
        reportGridWidthToStore()
        let snapshot = modelSnapshot()
        guard gridItemsMatch(snapshot), !gridPlacementsMatch(snapshot) else { return }
        grid.update(snapshot: snapshot, animated: false)
        // Смена ячеек применяется батчем коллекции: рамки нужны сразу — на них
        // опирается захват drag в этом же проходе runloop.
        grid.layoutIfNeeded()
    }

    /// Реакция на смену числа колонок сетки (E14.5, D32).
    ///
    /// Ширину узнаёт хранилище; во время правки сетка пересобирается под неё
    /// (при другой ширине холста — проекция по порядку чтения без дыр), а
    /// идущий drag отменяется: его база считалась на прежних колонках.
    private func gridColumnsDidChange() {
        reportGridWidthToStore()
        guard isEditing else { return }
        if dragSession != nil {
            cancelDragForExternalChange()
        } else {
            syncGridWithModel(animated: false)
            reconcileEditControls(animated: false)
        }
    }

    /// Применяет текущий снимок модели к сетке.
    ///
    /// Источник истины — ``TileStore``: после внешних изменений и при отмене
    /// drag сетка приводится к актуальному снимку, а не к устаревшей базе
    /// захвата (E10.5-B1).
    ///
    /// M1 (фикс-раунд W4): даже если сетка уже показывает этот порядок, во
    /// время анимации панели папки у неё может лежать отложенный (pending)
    /// снимок — например, последний шаг drag-превью. `grid.update` заменяет его
    /// по правилу last-wins (E10.2), поэтому снимок модели передаётся всегда,
    /// пока идёт переход панели: иначе после завершения анимации сетка
    /// применила бы устаревшее превью, и видимый порядок разошёлся бы с
    /// моделью.
    ///
    /// - Parameter animated: Анимировать ли перестановку.
    private func syncGridWithModel(animated: Bool) {
        let snapshot = modelSnapshot()
        guard !gridMatches(snapshot) || grid.isFolderChangeAnimating else { return }
        grid.update(snapshot: snapshot, animated: animated && !isReduceMotionEnabled())
    }

    /// Публикует `.layoutChanged` с фокусом на элементе (E10.5-B6).
    ///
    /// Пост откладывается на следующий проход runloop: к этому моменту коллекция
    /// уже разложила новые рамки, и ячейка-аргумент существует. Синхронный пост
    /// из колбэка batch-обновления мог бы указать на удалённый элемент.
    ///
    /// - Parameter itemID: Элемент, на который должен уйти фокус; `nil` — без
    ///   аргумента.
    private func postLayoutChanged(focusing itemID: AnyHashable?) {
        // D45: если идёт закрытие панели распавшейся папки, пост ждёт конца
        // перехода и отложенного снимка (сетка сама ставит фокус на плитку
        // папки, которой уже нет); спокойная сетка — тот же один проход runloop.
        grid.performAfterFolderTransition { [weak self] in
            guard let self else { return }
            let argument = itemID.flatMap { self.grid.cellView(forItemID: $0) }
            self.accessibilityNotificationPoster(.layoutChanged, argument)
        }
    }

    /// Элемент, на который уйдёт фокус VoiceOver после открепления (E14.7).
    ///
    /// Порядок сетки — порядок чтения ячеек (строка, затем колонка), поэтому
    /// «следующий» — это следующий элемент в нём: он остаётся на сетке после
    /// открепления (открепление никого не двигает, а схлопывание пустой строки
    /// и выталкивание порядок оставшихся не меняют). Если открепляемый был
    /// последним, берётся предыдущий. Без соседей и для ярлыка, которого нет на
    /// сетке (лежит в папке), цели нет — `nil`.
    ///
    /// - Parameter itemID: Открепляемый ярлык.
    /// - Returns: Идентификатор соседнего элемента или `nil`.
    private func focusTarget(afterRemoving itemID: AnyHashable) -> AnyHashable? {
        let items = grid.items
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return nil }
        if items.indices.contains(index + 1) { return items[index + 1].id }
        if index > 0 { return items[index - 1].id }
        return nil
    }

    /// Публикует `.layoutChanged` после unpin (E10.5-B6, E14.7).
    ///
    /// Пост откладывается на следующий проход runloop (B6): к этому моменту
    /// сетка применила снимок и ячейка-фокус существует. Цель — заранее
    /// выбранный сосед (``focusTarget(afterRemoving:)``); если его уже нет на
    /// сетке или цели не было (ярлык из папки), фокус получает последний
    /// элемент сетки, а если сетка опустела — сама сетка. На удалённый элемент
    /// фокус не уходит никогда.
    ///
    /// - Parameter focusID: Заранее выбранный сосед; `nil` — цели нет.
    private func postLayoutChanged(afterUnpinningFocusing focusID: AnyHashable?) {
        grid.performAfterFolderTransition { [weak self] in
            guard let self else { return }
            let items = self.grid.items
            let resolvedID: AnyHashable?
            if let focusID, items.contains(where: { $0.id == focusID }) {
                resolvedID = focusID
            } else {
                resolvedID = items.last?.id
            }
            let argument: Any? = resolvedID.flatMap { self.grid.cellView(forItemID: $0) }
                ?? (items.isEmpty ? self.grid : nil)
            self.accessibilityNotificationPoster(.layoutChanged, argument)
        }
    }

    /// Публикует `.layoutChanged` после unpin по заранее выбранной цели (E14.7,
    /// D45).
    ///
    /// Цель «сосед по сетке» и «оставшийся ярлык распавшейся папки» — элементы
    /// сетки (``postLayoutChanged(afterUnpinningFocusing:)``). Цель «ярлык панели» —
    /// ячейка панели раскрытой папки; если панели нет (закрыта) или ячейки
    /// ещё нет, фокус получает плитка папки, а при её отсутствии — тот же
    /// запасной путь, что у сетки. Пост — на следующем проходе runloop (B6).
    ///
    /// - Parameter focus: Цель фокуса.
    private func postLayoutChanged(afterUnpinning focus: UnpinFocus) {
        switch focus {
        case .gridItem(let itemID):
            postLayoutChanged(afterUnpinningFocusing: itemID)
        case .dissolvedTile(let itemID):
            postLayoutChanged(afterUnpinningFocusing: itemID)
        case .panelTile(let tileID, let folderID):
            grid.performAfterFolderTransition { [weak self] in
                guard let self else { return }
                if let panel = self.grid.panelShortcuts(),
                   panel.folder.id == folderID,
                   let index = panel.folder.tiles.firstIndex(where: { $0.id == tileID }),
                   panel.cells.indices.contains(index) {
                    self.accessibilityNotificationPoster(.layoutChanged, panel.cells[index])
                    return
                }
                if let folderCell = self.grid.cellView(forItemID: folderID) {
                    self.accessibilityNotificationPoster(.layoutChanged, folderCell)
                    return
                }
                let items = self.grid.items
                let argument: Any? = items.last.flatMap { self.grid.cellView(forItemID: $0.id) }
                    ?? (items.isEmpty ? self.grid : nil)
                self.accessibilityNotificationPoster(.layoutChanged, argument)
            }
        }
    }

    // MARK: - Согласованность drag-сессии (E10.5-B1)

    /// Совпадает ли модель с базой drag по структуре.
    ///
    /// Сравниваются идентификаторы, размеры, содержимое папок и ячейки:
    /// бейджи/подписи раскладку не меняют и отменять из-за них перетаскивание
    /// нельзя.
    ///
    /// - Parameter session: Активная drag-сессия.
    /// - Returns: `true`, если модель всё ещё та, что была на захвате.
    private func modelMatchesBase(_ session: TesseraTileDragSession) -> Bool {
        // E11.1: у drag из папки база превью содержит синтетический ярлык, а
        // модель с ним не совпадает — сверяем с реальным снимком модели.
        let base = session.modelBaseSnapshot.items
        let current = store.snapshot().items
        guard base.count == current.count else { return false }
        // E14.5: ячейки — часть модели; чужая правка, которая только передвинула
        // плитки, тоже делает базу устаревшей.
        guard store.placements(forColumns: session.columns) == session.modelPlacements else {
            return false
        }

        for (baseItem, currentItem) in zip(base, current) {
            guard baseItem.id == currentItem.id, baseItem.size == currentItem.size else {
                return false
            }
            guard (baseItem.folder == nil) == (currentItem.folder == nil) else { return false }
            let baseTiles = baseItem.folder?.tiles.map { $0.id } ?? []
            let currentTiles = currentItem.folder?.tiles.map { $0.id } ?? []
            guard baseTiles == currentTiles else { return false }
        }
        return true
    }

    /// Показывает ли сетка ровно этот порядок и состав элементов.
    ///
    /// Сравниваются идентификаторы, их порядок, размеры и таблица ячеек (E14.5):
    /// именно это делает превью и снимок `TileStore`. Бейджи/подписи не входят.
    ///
    /// - Parameter snapshot: Ожидаемый снимок.
    /// - Returns: `true`, если сетка показывает его.
    private func gridMatchesDragSnapshot(_ snapshot: TileGridSnapshot) -> Bool {
        let current = grid.items
        // E14.7: см. `gridItemsMatch` — порядок сетки — порядок чтения ячеек.
        let expectedItems = grid.readingOrdered(snapshot).items
        guard current.count == expectedItems.count else { return false }

        for (currentItem, expectedItem) in zip(current, expectedItems) {
            guard currentItem.id == expectedItem.id,
                  currentItem.size == expectedItem.size else {
                return false
            }
        }
        return gridPlacementsMatch(snapshot)
    }

    /// Согласована ли drag-сессия с моделью и сеткой (E10.5-B1).
    ///
    /// Сетка должна показывать либо последнее применённое координатором превью
    /// (``TesseraTileDragSession/expectedSnapshot``), либо отложенное — сетка
    /// могла запомнить его на время анимации панели папки и применить позже.
    /// Любой другой порядок/состав — внешний `grid.update` в обход координатора.
    /// Отложенное превью при совпадении становится ожидаемым.
    ///
    /// - Parameter session: Активная drag-сессия.
    /// - Returns: `true`, если можно продолжать перетаскивание.
    private func dragStateIsConsistent(_ session: TesseraTileDragSession) -> Bool {
        if storeChangedDuringDrag, !modelMatchesBase(session) {
            return false
        }
        if gridMatchesDragSnapshot(session.expectedSnapshot) {
            return true
        }
        if let pending = session.pendingSnapshot, gridMatchesDragSnapshot(pending) {
            session.expectedSnapshot = pending
            session.pendingSnapshot = nil
            return true
        }
        return false
    }

    /// Безопасно отменяет drag при внешнем изменении модели/снимка (E10.5-B1).
    ///
    /// Порядок важен: сначала снимается сессия и её оверлеи, затем сетка
    /// приводится к текущей модели — так отмена не откатывает чужие изменения
    /// к устаревшему снимку захвата. Внешняя мутация могла пройти при
    /// выключенном drag-транзакцией автосохранении, поэтому её сохраняем.
    private func cancelDragForExternalChange() {
        guard let session = dragSession else { return }

        stopTicker()
        resetMergeHover()
        stopMagnetAnimation(session)
        session.magnetTarget = nil
        dragSession = nil
        storeChangedDuringDrag = false

        grid.isScrollEnabled = true
        hideDropHighlight()
        session.dragView.removeFromSuperview()
        session.placeholder.removeFromSuperview()
        stopPlaceholderAnimation()
        grid.setItemHidden(false, forItemID: session.itemID)

        syncGridWithModel(animated: true)
        reconcileEditControls(animated: false)
        endDragStoreTransaction(saveIfNeeded: true)
        announce(TesseraStartScreenStrings.string(.a11yDragCancelled))
    }

    // MARK: - Drag: старт и движение

    /// Поднимает плитку и начинает перетаскивание.
    ///
    /// Снимает копию ячейки **до** скрытия, кладёт на её место пустышку и вешает
    /// снимок поверх сетки. Модель на этом шаге не меняется.
    ///
    /// E8.4/E14.5: здесь же запоминается снимок модели с ячейками — база для
    /// хит-теста, превью и отката. Во время drag `TileStore` не пишется, так что
    /// эти ячейки остаются в модели до самого drop'а.
    ///
    /// E8.2: снимок всегда полной яркости — если плитка была в дим-поле
    /// (редактирование начато с пустого места), прозрачность снимается до
    /// снятия копии, иначе в копию попал бы alpha 0,7.
    ///
    /// - Parameters:
    ///   - itemID: Идентификатор ярлыка или папки.
    ///   - point: Точка захвата в координатах сетки.
    private func startDrag(itemID: AnyHashable, at point: CGPoint) {
        guard dragSession == nil else { return }

        // m2 (фикс-раунд W4): контракт хоста — к моменту захвата сетка обязана
        // показывать актуальный снимок `TileStore`. Если снимок и модель
        // разошлись (внешний update в обход координатора, не применённый
        // store-снимок), drag не начинается: иначе превью считалось бы от
        // чужой базы, а drop/cancel могли бы разойтись с моделью. В DEBUG
        // нарушение контракта видно как assertion, а не как «проглоченный»
        // long-press.
        // E14.5: хост мог показать те же элементы без таблицы ячеек — подтягиваем
        // её до сравнения (иначе хит-тест считался бы по другим кадрам).
        prepareModelForEditing()
        let modelSnapshot = self.modelSnapshot()
        if !gridMatches(modelSnapshot) {
            #if DEBUG
            assertionFailure(
                "TesseraTileEditCoordinator.startDrag: снимок сетки не совпадает "
                    + "с моделью TileStore на захвате — drag не начнётся. "
                    + "Хост обязан применять снимки store к сетке (E10.5-B1)."
            )
            #endif
            return
        }
        guard let item = grid.items.first(where: { $0.id == itemID }),
              let frame = grid.frame(forItemID: itemID),
              frame.intersects(grid.bounds),
              let placeholder = grid.placeholderView(forItemID: itemID) else {
            return
        }

        // E8.2: плитка под пальцем становится «выбранной» и полной яркости.
        // «Желе» снимаем до снимка: копия не должна унаследовать ни дим, ни
        // текущий угол покачивания. Прозрачность меняет сетка — владелец дима
        // (E10.4).
        if let cell = grid.cellView(forItemID: itemID) as? TesseraTileCell {
            cell.contentView.layer.removeAnimation(forKey: TesseraTileEditCoordinator.jiggleKey)
        }
        grid.setEditDimming([itemID: 1], animated: false)
        guard let dragView = makeDragView(forItemID: itemID) else {
            // Снимок не удался: возвращаем дим, чтобы плитка не осталась ярче
            // соседей без начатого drag.
            applyEditDimming(animated: false)
            return
        }
        dimmingFocusID = itemID

        installDragSession(
            itemID: itemID,
            isTile: item.tile != nil,
            slotFrame: frame,
            liftFrame: frame,
            placeholder: placeholder,
            dragView: dragView,
            point: point,
            baseSnapshot: modelSnapshot,
            basePlacements: placedItems(of: modelSnapshot),
            modelBaseSnapshot: nil,
            sourceFolderID: nil,
            magnetSize: item.size
        )
    }

    /// Поднимает ярлык из панели раскрытой папки и начинает drag (E11.1).
    ///
    /// Источник drag — папка (``TesseraTileDragSession/sourceFolderID``), а не
    /// элемент сетки. Модель за время drag не меняется: сетке показывается
    /// **отображаемый** снимок — модельный, где ярлык убран из состава папки и
    /// вставлен отдельным ярлыком. E14.5: у синтетического ярлыка нет базовой
    /// ячейки в модели — он встаёт на первую свободную ячейку после ячейки
    /// папки (``firstFreeCell(for:after:in:columns:)``), так что пустышка и
    /// превью работают как у обычной плитки; цели те же, что у drag по сетке.
    /// Сверка с моделью (``modelMatchesBase(_:)``) идёт по реальному снимку и
    /// реальным ячейкам.
    ///
    /// Панель закрывается **мгновенно** (как в m3): снимок иконки берётся до
    /// закрытия, рамка иконки и смещение захвата считаются в тех же
    /// координатах, поэтому ярлык остаётся под пальцем.
    ///
    /// - Parameter point: Точка нажатия в координатах сетки.
    private func startDragFromPanel(at point: CGPoint) {
        guard dragSession == nil, isEditing,
              let hit = grid.panelTile(at: point) else {
            return
        }

        // m2: контракт хоста — сетка показывает актуальный снимок модели.
        prepareModelForEditing()
        let modelSnapshot = self.modelSnapshot()
        guard gridMatches(modelSnapshot) else {
            #if DEBUG
            assertionFailure(
                "TesseraTileEditCoordinator.startDragFromPanel: the grid snapshot "
                    + "differs from the TileStore model at grab time; drag will not "
                    + "start (E10.5-B1)."
            )
            #endif
            return
        }
        var items = modelSnapshot.items
        guard let folderIndex = items.firstIndex(where: { $0.folder?.id == hit.folder.id }),
              var displayFolder = items[folderIndex].folder,
              displayFolder.tiles.contains(where: { $0.id == hit.tile.id }) else {
            return
        }

        // Отображаемый снимок: ярлык вынут из папки и лежит сразу после неё в
        // порядке снимка, а на сетке — на свободной ячейке после папки. Размер
        // берётся из дескриптора, как его разрешит `TileStore` при выносе.
        let modelPlaced = placedItems(of: modelSnapshot)
        guard let folderCell = modelPlaced.first(where: { $0.id == hit.folder.id })?.cell else {
            return
        }
        let tileCell = firstFreeCell(
            for: hit.tile.size,
            after: folderCell,
            in: modelPlaced,
            columns: storeColumns
        )
        var displayCells: [AnyHashable: TileGridPlacement] = [:]
        for placed in modelPlaced { displayCells[placed.id] = placed.cell }
        displayCells[hit.tile.id] = tileCell

        displayFolder.tiles.removeAll { $0.id == hit.tile.id }
        items[folderIndex] = .folder(displayFolder)
        items.insert(.tile(hit.tile), at: folderIndex + 1)
        let displaySnapshot = TileGridSnapshot(
            items: items,
            unpinned: modelSnapshot.unpinned,
            placementTable: TileGridPlacementTable(cells: displayCells, columns: storeColumns)
        )
        let displayPlaced = modelPlaced + [
            TilePlacedItem(id: hit.tile.id, size: hit.tile.size, cell: tileCell),
        ]

        // D45: в папке из двух ярлыков вынос одного распускает её — готовим
        // «итоговую картину» (оставшийся ярлык на ячейке папки) для превью. Те же
        // шаги делает `TileStore`: без выносимого ярлыка и без папки, оставшийся на
        // ячейке папки по `inserting`.
        var dissolution: DragFolderDissolution?
        if let modelFolder = modelSnapshot.folders.first(where: { $0.id == hit.folder.id }),
           modelFolder.tiles.count == 2,
           let remaining = modelFolder.tiles.first(where: { $0.id != hit.tile.id }) {
            var dissolvedItems = displaySnapshot.items
            if let index = dissolvedItems.firstIndex(where: { $0.folder?.id == hit.folder.id }) {
                dissolvedItems[index] = .tile(remaining)
            }
            dissolution = DragFolderDissolution(
                folderID: hit.folder.id,
                remaining: remaining,
                items: dissolvedItems,
                placements: TileLayoutEngine.inserting(
                    id: remaining.id,
                    size: remaining.size,
                    at: folderCell,
                    into: TileLayoutEngine.removing(id: hit.folder.id, from: modelPlaced),
                    columns: storeColumns
                )
            )
        }

        // m3: панель закрывается мгновенно — drag стартует сразу за long-press.
        grid.closeFolder(animated: false)
        guard grid.expandedFolderID == nil else { return }

        dimmingFocusID = hit.tile.id
        grid.update(snapshot: displaySnapshot, animated: !isReduceMotionEnabled())
        guard let slotFrame = grid.frame(forItemID: hit.tile.id),
              let placeholder = grid.placeholderView(forItemID: hit.tile.id) else {
            // Сетка не приняла отображаемый снимок: возвращаем модель.
            syncGridWithModel(animated: false)
            dimmingFocusID = nil
            return
        }

        installDragSession(
            itemID: hit.tile.id,
            isTile: true,
            slotFrame: slotFrame,
            liftFrame: hit.frame,
            placeholder: placeholder,
            dragView: hit.snapshot,
            point: point,
            baseSnapshot: displaySnapshot,
            basePlacements: displayPlaced,
            modelBaseSnapshot: modelSnapshot,
            sourceFolderID: hit.folder.id,
            magnetSize: hit.tile.size,
            folderDissolution: dissolution
        )
    }

    /// Ставит оверлеи, создаёт drag-сессию и запускает подъём (общий хвост
    /// старта drag для ячейки сетки и для ярлыка из папки, E11.1).
    ///
    /// - Parameters:
    ///   - itemID: Идентификатор перетаскиваемого ярлыка/папки.
    ///   - isTile: Ярлык ли это.
    ///   - slotFrame: Рамка слота в сетке (пустышка).
    ///   - liftFrame: Рамка, с которой стартует снимок (для ярлыка из папки —
    ///     рамка иконки панели).
    ///   - placeholder: Пустышка.
    ///   - dragView: Снимок.
    ///   - point: Точка захвата в координатах сетки.
    ///   - baseSnapshot: База превью (с таблицей ячеек).
    ///   - basePlacements: Размещения базы по ячейкам (E14.5).
    ///   - modelBaseSnapshot: Снимок модели, если он отличается от базы.
    ///   - sourceFolderID: Папка-источник (drag из панели).
    ///   - magnetSize: Размерность для магнита.
    ///   - folderDissolution: Итоговая картина распада папки-источника (D45),
    ///     если в ней два ярлыка.
    private func installDragSession(
        itemID: AnyHashable,
        isTile: Bool,
        slotFrame: CGRect,
        liftFrame: CGRect,
        placeholder: UIView,
        dragView: UIView,
        point: CGPoint,
        baseSnapshot: TileGridSnapshot,
        basePlacements: [TilePlacedItem],
        modelBaseSnapshot: TileGridSnapshot?,
        sourceFolderID: AnyHashable?,
        magnetSize: TileSize,
        folderDissolution: DragFolderDissolution? = nil
    ) {
        beginDragStoreTransaction()

        grid.setItemHidden(true, forItemID: itemID)
        removeControl(for: itemID)
        // D46: во время drag кнопок на ярлыках панели нет (панель при этом уже
        // закрыта мгновенно; страховка на случай иного порядка).
        removeAllPanelEditControls()

        placeholder.frame = slotFrame
        placeholder.layer.zPosition = 500
        grid.addSubview(placeholder)

        dragView.frame = liftFrame
        dragView.isUserInteractionEnabled = false
        dragView.layer.zPosition = 1000
        dragView.layer.shadowColor = UIColor.black.cgColor
        dragView.layer.shadowOpacity = 0.22
        dragView.layer.shadowRadius = 14
        dragView.layer.shadowOffset = CGSize(width: 0, height: 8)
        grid.addSubview(dragView)

        // E8.4/E14.5: база превью — ячейки модели на момент захвата. Сетка и
        // модель к этому моменту совпадают, поэтому снимок хранилища и есть то,
        // что видит пользователь.
        let session = TesseraTileDragSession(
            itemID: itemID,
            isTile: isTile,
            grabOffset: CGPoint(x: liftFrame.midX - point.x, y: liftFrame.midY - point.y),
            dragView: dragView,
            placeholder: placeholder,
            lastPoint: point,
            baseSnapshot: baseSnapshot,
            magnetSize: magnetSize,
            columns: storeColumns,
            basePlacements: basePlacements,
            modelPlacements: store.placements(forColumns: storeColumns),
            modelBaseSnapshot: modelBaseSnapshot,
            sourceFolderID: sourceFolderID,
            folderDissolution: folderDissolution
        )
        dragSession = session
        storeChangedDuringDrag = false
        grid.isScrollEnabled = false

        updateHoverTargets(at: point)

        if !isReduceMotionEnabled() {
            dragView.transform = .identity
            // Масштаб подъёма снимаем в локальную константу: анимационный блок
            // живёт до конца анимации, и сильный захват `self` задерживал бы
            // `deinit` координатора (а он обязан успеть восстановить сетку).
            let liftScale = configuration.liftScale
            UIView.animate(
                withDuration: 0.16,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut],
                animations: {
                    dragView.transform = CGAffineTransform(
                        scaleX: liftScale,
                        y: liftScale
                    )
                },
                completion: nil
            )
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        startTickerIfNeeded()
    }

    /// Размещения верхнеуровневых элементов снимка по его таблице ячеек (E14.5).
    ///
    /// Правило отката то же, что у раскладки сетки
    /// (``TileGridPlacementTable/resolve(items:cells:placementColumns:columns:)``):
    /// нет таблицы, она неполная, другой ширины или не проходит `validate` —
    /// ячейки берутся из упаковки по порядку, как их нарисует сетка.
    ///
    /// - Parameter snapshot: Снимок сетки (панель раскрытой папки в нём не учитывается).
    /// - Returns: Размещения в порядке элементов снимка.
    private func placedItems(of snapshot: TileGridSnapshot) -> [TilePlacedItem] {
        let columns = storeColumns
        let items: [(id: AnyHashable, size: TileSize)] = snapshot.items.compactMap { item in
            item.isFolderPanel ? nil : (id: item.id, size: item.size)
        }
        if let placed = TileGridPlacementTable.resolve(
            items: items,
            cells: snapshot.placementTable?.cells,
            placementColumns: snapshot.placementTable?.columns,
            columns: columns
        ) {
            return placed
        }
        let packed = TileLayoutEngine.pack(
            items: items.map { (id: $0.id, size: TileLayoutEngine.fittingSize($0.size, columns: columns)) },
            columns: columns,
            unit: 1
        )
        return packed.map {
            TilePlacedItem(id: $0.id, size: $0.size, cell: TileGridPlacement(row: $0.row, column: $0.column))
        }
    }

    /// Первая свободная ячейка под размер не раньше `origin` в порядке чтения
    /// (E14.5).
    ///
    /// Нужна стартовой ячейке синтетического ярлыка при drag из панели папки:
    /// слот появляется рядом с папкой (если справа от неё есть место — там), а не
    /// в «самой верхней дыре». Если свободной ячейки нет до конца холста —
    /// новая строка (`TileLayoutEngine.newRowCell`).
    ///
    /// - Parameters:
    ///   - size: Размер размещаемого ярлыка.
    ///   - origin: Ячейка, раньше которой в порядке чтения не искать.
    ///   - placements: Занятые ячейки.
    ///   - columns: Число колонок сетки.
    /// - Returns: Ячейка левого верхнего угла.
    private func firstFreeCell(
        for size: TileSize,
        after origin: TileGridPlacement,
        in placements: [TilePlacedItem],
        columns: Int
    ) -> TileGridPlacement {
        let fitted = TileLayoutEngine.fittingSize(size, columns: columns)
        let width = fitted.unitColumns
        let height = fitted.unitRows
        var lastRow = 0
        for placed in placements {
            let footprint = TileLayoutEngine.fittingSize(placed.size, columns: columns)
            lastRow = max(lastRow, placed.cell.row + footprint.unitRows)
        }

        guard width > 0, width <= columns, origin.row <= lastRow else {
            return TileLayoutEngine.newRowCell(size: size, columns: columns, placements: placements)
        }
        for row in origin.row...lastRow {
            for column in 0...(columns - width) {
                if row == origin.row, column < origin.column { continue }
                let isFree = !placements.contains { placed in
                    let footprint = TileLayoutEngine.fittingSize(placed.size, columns: columns)
                    return row < placed.cell.row + footprint.unitRows
                        && placed.cell.row < row + height
                        && column < placed.cell.column + footprint.unitColumns
                        && placed.cell.column < column + width
                }
                if isFree { return TileGridPlacement(row: row, column: column) }
            }
        }
        return TileLayoutEngine.newRowCell(size: size, columns: columns, placements: placements)
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

    /// Пересчитывает цель под пальцем, превью раскладки и подсветку.
    ///
    /// Решение принимается по **базовой** раскладке (``hoverTarget(at:session:)``),
    /// а не по `grid.item(at:)`: исходная ячейка скрыта, но остаётся в раскладке и
    /// перехватила бы хит-тест, а рамки сетки уже сдвинуты превью.
    ///
    /// E14.5: цель — клетка под пальцем (``HoverTarget/cell(_:)``), «новая строка»
    /// или слияние (центр плитки/папки). Превью каждый раз считается от базовых
    /// размещений, а не от предыдущего превью (сдвиги не накапливаются), и
    /// возвращается к базовым, когда цель — слияние или её нет.
    ///
    /// E8.9: в конце шага снимок ставится под палец (или притягивается к ячейке
    /// цели). Здесь же сбрасывается признак «палец над панелью папки»:
    /// притяжение над панелью не работает.
    ///
    /// - Parameter point: Точка пальца в координатах сетки.
    private func updateHoverTargets(at point: CGPoint) {
        guard let session = dragSession else { return }

        // E10.5-B1: внешняя мутация модели или чужой `grid.update` во время
        // drag делает базу превью и сетку несогласованными — безопасно
        // отменяем перетаскивание, не дожидаясь drop.
        guard dragStateIsConsistent(session) else {
            cancelDragForExternalChange()
            return
        }

        // E8.9/m7: признак пересчитывается на каждом шаге, а не только при
        // смене цели: панель могла уехать вместе с автопрокруткой. Хит-тест
        // сетки нужен потому, что `item(under:)` видит только элементы модели.
        session.isOverFolderPanel = isPointOverFolderPanel(point)

        // E12.1: на подъёме палец стоит там, где была иконка панели (после
        // закрытия панели это обычно пустое место): превью остаётся в базовой
        // раскладке, пока палец не сдвинется на заметное расстояние.
        if !session.hasMovedFromOrigin {
            let dx = point.x - session.originPoint.x
            let dy = point.y - session.originPoint.y
            if dx * dx + dy * dy > Self.emptySlotActivationDistance * Self.emptySlotActivationDistance {
                session.hasMovedFromOrigin = true
            }
        }

        let target = hoverTarget(at: point, session: session)

        applyDragPreview(for: target, session: session)

        // E8.6: удержание над центром ярлыка/папки взводится, перевзводится и
        // сбрасывается на каждом шаге — до обновления подсветки, чтобы она сразу
        // показала «впитывание», если удержание уже выдержано.
        let hoverChanged = session.hover != target
        session.hover = target
        updateMergeHover(for: target, at: point)

        if hoverChanged {
            updateDropHighlight(for: target)
        } else {
            updateDropHighlightFrame()
        }

        // E8.9: снимок ведётся за пальцем после выбора цели. Притяжение —
        // только визуальный слой: цели считаются по точке пальца, поэтому
        // раскладка и таймер слияния от него не зависят.
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

    /// Центр ячейки-цели, к которому нужно притянуть снимок, или `nil`.
    ///
    /// E14.5: снимок притягивается к рамке **ячейки-цели** (для размера
    /// перетаскиваемого элемента на ограниченной холстом ячейке, см.
    /// ``TesseraTileGridView/baseFrame(forCell:size:)``): к ячейке
    /// ``HoverTarget/cell(_:)``, к началу новой строки для
    /// ``HoverTarget/newRow`` и к собственной базовой ячейке, пока цели нет.
    ///
    /// E10.5-A2: расстояние считается от **центра снимка**
    /// (`point + grabOffset`), а не от точки пальца. Иначе плитка, взятая не за
    /// центр, притягивалась бы с ошибкой до половины плитки и «прыгала»;
    /// при этом снимок должен сместиться не больше чем на радиус притяжения.
    ///
    /// Притяжение отключено:
    /// - при Reduce Motion — снимок остаётся строго под пальцем (E8.1);
    /// - при нулевом/нечисловом ``TesseraTileEditConfiguration/magnetSnapRadius``;
    /// - пока палец не вышел из стартовой зоны захвата (``TesseraTileDragSession/hasLeftOriginSlot``);
    /// - над панелью раскрытой папки;
    /// - над целями удержания E8.6 (центральная зона ярлыка/папки): в этих
    ///   местах снимок не должен уезжать из-под пальца, пока пользователь
    ///   держит удержание или целится в папку.
    ///
    /// - Parameters:
    ///   - point: Точка пальца в координатах сетки.
    ///   - session: Активная drag-сессия.
    /// - Returns: Центр рамки ячейки-цели в радиусе или `nil`.
    private func magnetTarget(for point: CGPoint, session: TesseraTileDragSession) -> CGPoint? {
        guard configuration.magnetSnapRadius > 0, !isReduceMotionEnabled() else { return nil }
        guard !session.isOverFolderPanel else { return nil }
        guard session.hasLeftOriginSlot else { return nil }

        let cell: TileGridPlacement
        switch session.hover {
        case .folder, .group, .sourceFolder:
            return nil
        case .none:
            guard let own = session.basePlacements.first(where: { $0.id == session.itemID }) else {
                return nil
            }
            cell = own.cell
        case .cell(let target):
            cell = target
        case .newRow:
            cell = session.newRowCell
        }
        guard let frame = grid.baseFrame(forCell: cell, size: session.magnetSize) else { return nil }

        let snapshotCenter = CGPoint(
            x: point.x + session.grabOffset.x,
            y: point.y + session.grabOffset.y
        )
        return TesseraTileMagnet.magnetTarget(
            for: snapshotCenter,
            slotCenters: [CGPoint(x: frame.midX, y: frame.midY)],
            snapRadius: configuration.magnetSnapRadius
        )
    }

    /// Внутренний шов тестов: цель магнита для активной drag-сессии.
    ///
    /// Позволяет проверить расчёт центра снимка (`grabOffset`) и работу в RTL
    /// без симуляции касаний; в проде не используется. Гейтинг (Reduce Motion,
    /// панель, цели удержания) остаётся тем же, что у боевого пути.
    ///
    /// - Parameter point: Точка пальца в координатах сетки.
    /// - Returns: Центр слота или `nil`.
    func dragMagnetTargetForTesting(at point: CGPoint) -> CGPoint? {
        guard let session = dragSession else { return nil }
        return magnetTarget(for: point, session: session)
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

    /// Пересобирает превью раскладки сетки для цели под пальцем (E8.4, E14.5).
    ///
    /// Пишет **только в сетку** — `grid.update(snapshot:animated:)` гонит
    /// batch-анимацию ~0,26 с с bounce-кривой E8.8, соседи «расступаются» без
    /// записи в `TileStore`. Снимок несёт таблицу ячеек
    /// (``TileGridPlacementTable``), поэтому превью — это те же элементы на
    /// других ячейках, а не другой порядок.
    ///
    /// Размещения каждый раз считаются от ``TesseraTileDragSession/basePlacements``,
    /// а не от предыдущего превью: при перемещении между целями сдвиги не
    /// накапливаются. Для ``HoverTarget/cell(_:)`` это
    /// `TileLayoutEngine.inserting` (элемент встаёт на ячейку, мешающие
    /// выталкиваются вниз каскадом, D31), для ``HoverTarget/newRow`` — вставка
    /// на ячейку новой строки. Для слияния (центр плитки/папки), родной папки и
    /// отсутствия цели превью **возвращается к базовым размещениям**: цель
    /// остаётся под пальцем, а подсветка рисуется на ней (раньше здесь
    /// оставалось прежнее превью, и цель «убегала» из-под пальца). Пустые строки
    /// во время drag не схлопываются (D31) — только на drop.
    ///
    /// D45: drag ярлыка из папки в два ярлыка на цели-размещении
    /// (`.cell`/`.newRow`) показывает **итог**: элемент-папка заменён оставшимся
    /// ярлыком на её ячейке (``TesseraTileDragSession/folderDissolution``);
    /// пока цель — слияние, родная папка или её нет, показывается база (папка с
    /// одним ярлыком, как при подъёме), а отмена и отказ хоста возвращают
    /// сетке модель с исходной папкой (``restore()``).
    ///
    /// - Parameters:
    ///   - target: Цель под пальцем.
    ///   - session: Активная drag-сессия.
    private func applyDragPreview(for target: HoverTarget, session: TesseraTileDragSession) {
        // D45: при drag из папки в два ярлыка цель-размещение показывает
        // итоговую картину: папка уже распущена, оставшийся ярлык стоит на её
        // ячейке, а перетаскиваемый встаёт по обычным правилам (тот же порядок
        // шагов, что у `TileStore.extractFromFolder`). Остальные цели (слияние,
        // родная папка, нет цели) — база: папка со вторым ярлыком на месте, как
        // при подъёме.
        var previewItems = session.baseSnapshot.items
        let desired: [TilePlacedItem]
        switch target {
        case .cell(let cell):
            var basis = session.basePlacements
            if let dissolution = session.folderDissolution {
                basis = dissolution.placements
                previewItems = dissolution.items
            }
            desired = TileLayoutEngine.inserting(
                id: session.itemID,
                size: session.magnetSize,
                at: cell,
                into: basis,
                columns: session.columns
            )
        case .newRow:
            var basis = session.basePlacements
            if let dissolution = session.folderDissolution {
                basis = dissolution.placements
                previewItems = dissolution.items
            }
            desired = TileLayoutEngine.inserting(
                id: session.itemID,
                size: session.magnetSize,
                at: session.newRowCell,
                into: basis,
                columns: session.columns
            )
        case .none, .folder, .group, .sourceFolder:
            desired = session.basePlacements
        }

        guard desired != session.previewPlacements else {
            animatePlaceholder(to: currentFrame(of: session))
            return
        }
        session.previewPlacements = desired

        var cells: [AnyHashable: TileGridPlacement] = [:]
        for placed in desired { cells[placed.id] = placed.cell }
        let previewSnapshot = TileGridSnapshot(
            items: previewItems,
            unpinned: session.baseSnapshot.unpinned,
            placementTable: TileGridPlacementTable(cells: cells, columns: session.columns)
        )
        // E10.5-B1: сетка обязана показывать именно этот снимок; расхождение на
        // следующем шаге означает внешний `grid.update`. Если сетка отложила
        // снимок на время перехода панели, он запоминается как pending и станет
        // ожидаемым, когда доедет.
        session.pendingSnapshot = previewSnapshot
        grid.update(snapshot: previewSnapshot, animated: !isReduceMotionEnabled())
        if gridMatchesDragSnapshot(previewSnapshot) {
            session.expectedSnapshot = previewSnapshot
            session.pendingSnapshot = nil
        }
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

    /// Смещение пальца от точки захвата, после которого над пустым местом
    /// включается выбор клетки (E12.1), pt.
    static let emptySlotActivationDistance: CGFloat = 12

    /// Цель под пальцем: клетка сетки по базовой раскладке (E14.5, D21, D33).
    ///
    /// Хит-тест идёт по **базовой** раскладке (``TesseraTileDragSession/basePlacements``,
    /// те же кадры, что видел пользователь до сдвигов превью, E11.7), а не по
    /// рамкам сетки. Палец определяет клетку (строка/колонка в логических,
    /// незеркальных координатах: RTL учитывает сетка,
    /// ``TesseraTileGridView/baseCell(forGridPoint:)``); колонка ограничивается
    /// `0 ..< columns`, строка — не меньше 0.
    ///
    /// Если клетка занята другим элементом базовой раскладки, решает зона его
    /// базовой рамки (``isPointInDropCenter(_:of:)``):
    /// - центр плитки — `.group` (создание папки по удержанию E8.6, D14; только
    ///   для ярлыка, не взятого из папки);
    /// - центр папки — `.folder` (добавление по удержанию; папку в папку
    ///   бросить нельзя) либо `.sourceFolder` для родной папки drag из панели;
    /// - край (всё остальное, в том числе зазоры) — `.cell` с **ячейкой элемента-цели**:
    ///   перетаскиваемый встаёт на неё, цель выталкивается вниз (D31).
    ///
    /// Над собственной базовой ячейкой цели нет (`.none`, превью — база). Над
    /// пустой клеткой цель — эта клетка; ниже последней занятой строки —
    /// ``HoverTarget/newRow``. Пока палец не сдвинулся от точки захвата
    /// (``TesseraTileDragSession/hasMovedFromOrigin``), пустые клетки цели не
    /// дают.
    ///
    /// Пока раскрыта панель папки (в т. ч. во время анимированного закрытия),
    /// раскладка сетки не совпадает с базовой: клетки не считаются, а элемент
    /// под пальцем ищется по рамкам сетки (запасной путь); его ячейка берётся из
    /// базовых размещений. Над самой панелью и над пустым местом цели нет.
    ///
    /// - Parameters:
    ///   - point: Точка пальца в координатах сетки.
    ///   - session: Активная drag-сессия.
    /// - Returns: Цель под пальцем.
    private func hoverTarget(at point: CGPoint, session: TesseraTileDragSession) -> HoverTarget {
        guard !session.isOverFolderPanel,
              grid.bounds.insetBy(dx: -8, dy: -8).contains(point) else {
            return .none
        }

        if grid.expandedFolderID != nil {
            guard let hovered = item(under: point, excluding: session.itemID),
                  let frame = grid.frame(forItemID: hovered.id),
                  let placed = session.basePlacements.first(where: { $0.id == hovered.id }) else {
                return .none
            }
            return zoneTarget(for: hovered, at: placed.cell, frame: frame, point: point, session: session)
        }

        guard let frames = baseFrames(for: session),
              let finger = grid.baseCell(forGridPoint: point) else {
            return .none
        }

        let columns = session.columns
        let row = max(0, finger.row)
        let column = min(max(0, finger.column), columns - 1)

        var bottom = 0
        var occupant: TilePlacedItem?
        for placed in session.basePlacements {
            let footprint = TileLayoutEngine.fittingSize(placed.size, columns: columns)
            bottom = max(bottom, placed.cell.row + footprint.unitRows)
            if occupant == nil,
               row >= placed.cell.row, row < placed.cell.row + footprint.unitRows,
               column >= placed.cell.column, column < placed.cell.column + footprint.unitColumns {
                occupant = placed
            }
        }

        guard let occupant else {
            guard session.hasMovedFromOrigin else { return .none }
            return row >= bottom
                ? .newRow
                : .cell(TileGridPlacement(row: row, column: column))
        }
        // Собственная базовая ячейка — не цель (нет перестановки с собой).
        if occupant.id == session.itemID { return .none }

        guard let contentFrame = frames[occupant.id],
              let item = session.baseSnapshot.items.first(where: { $0.id == occupant.id }) else {
            return .cell(occupant.cell)
        }
        return zoneTarget(
            for: item,
            at: occupant.cell,
            frame: grid.gridFrame(fromContentFrame: contentFrame),
            point: point,
            session: session
        )
    }

    /// Цель над занятой клеткой по зоне рамки элемента (E14.5).
    ///
    /// Центр (``isPointInDropCenter(_:of:)``) — слияние, край — размещение на
    /// ячейку элемента-цели (``HoverTarget/cell(_:)``).
    ///
    /// - Parameters:
    ///   - item: Элемент под пальцем.
    ///   - cell: Его ячейка в базовой раскладке.
    ///   - frame: Рамка, по которой решается зона, в координатах сетки.
    ///   - point: Точка пальца в координатах сетки.
    ///   - session: Активная drag-сессия.
    /// - Returns: Цель под пальцем.
    private func zoneTarget(
        for item: TileGridItem,
        at cell: TileGridPlacement,
        frame: CGRect,
        point: CGPoint,
        session: TesseraTileDragSession
    ) -> HoverTarget {
        let edgeTarget = HoverTarget.cell(cell)
        let isCenter = isPointInDropCenter(point, of: frame)

        switch item {
        case .folder(let folder):
            // Папку нельзя бросить в папку (вложенности нет) — перестановка.
            guard session.isTile else { return edgeTarget }
            if folder.id == session.sourceFolderID {
                // E11.1: центр родной папки — «вернуть в папку» (no-op), край —
                // обычный вынос на ячейку папки.
                return isCenter ? .sourceFolder : edgeTarget
            }
            // E10.5-A1: центральная зона папки — добавление ярлыка внутрь по
            // удержанию E8.6 (D14); без удержания drop — no-op.
            return isCenter ? .folder(folder.id) : edgeTarget

        case .tile(let tile):
            // Центр ярлыка — создание папки из двух ярлыков (D14). E11.1: для
            // ярлыка, взятого из папки, папка не создаётся — центр работает как
            // обычное размещение на ячейку (вынос на сетку).
            if session.isTile, session.sourceFolderID == nil, isCenter {
                return .group(tile.id)
            }
            return edgeTarget

        case .folderContent:
            // Панели в базовой раскладке нет (она сдвигала бы строки).
            return .none
        }
    }

    /// Базовые рамки элементов сессии в координатах контента (E11.7).
    ///
    /// Считаются один раз за сессию и перестраиваются, если изменилась
    /// геометрия сетки (ширина, колонки, поля, направление). Смещение
    /// прокрутки в кэш не входит: рамки хранятся в координатах контента и на
    /// каждом шаге (в т. ч. на кадре автопрокрутки) переводятся
    /// `grid.gridFrame(fromContentFrame:)` с актуальным `contentOffset`.
    /// E14.5: рамки берутся по таблице ячеек базового снимка.
    ///
    /// - Parameter session: Активная drag-сессия.
    /// - Returns: Рамки по идентификатору или `nil`, если посчитать нельзя.
    private func baseFrames(for session: TesseraTileDragSession) -> [AnyHashable: CGRect]? {
        let key = grid.baseFramesKey()
        if let cached = session.baseFrames, cached.key == key {
            return cached.frames
        }
        guard let frames = grid.baseContentFrames(
            for: session.baseSnapshot.items,
            placementTable: session.baseSnapshot.placementTable
        ) else {
            session.baseFrames = nil
            return nil
        }
        session.baseFrames = (key: key, frames: frames)
        return frames
    }

    /// Элемент под точкой, кроме перетаскиваемого (рамки сетки; запасной путь
    /// при раскрытой панели папки).
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

    /// Лежит ли точка над панелью раскрытой папки (m7, W5-фикс).
    ///
    /// `item(under:)` перебирает только элементы модели, а панель — элемент
    /// представления, поэтому её ищем хит-тестом сетки (`grid.item(at:)`):
    /// панель имеет собственный `IndexPath` в коллекции. Нужно и в
    /// ``updateHoverTargets(at:)`` (снять магнит/показать, что цель не плитка),
    /// и в ``finishDrag(commit:)`` (drop над панелью — no-op, E9.5-семантика).
    ///
    /// - Parameter point: Точка в координатах сетки.
    /// - Returns: `true`, если точка попадает в панель раскрытой папки.
    private func isPointOverFolderPanel(_ point: CGPoint) -> Bool {
        guard grid.expandedFolderID != nil else { return false }
        return grid.item(at: point)?.isFolderPanel == true
    }

    /// Попадает ли точка в центральную половину рамки (зона удержания E8.6).
    ///
    /// Центральная зона используется для двух целей: центр ярлыка — создание
    /// папки (E8.6), центр плитки-папки — добавление ярлыка в папку (E10.5-A1).
    /// Всё, что снаружи этой зоны, — краевые половины, они переставляют плитку.
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

    /// Взводит, ведёт, перевзводит или сбрасывает удержание E8.6.
    ///
    /// Цели удержания — центр ярлыка (создание папки) и центральная зона
    /// плитки-папки (добавление внутрь); для обеих используется одна машина
    /// ``TesseraMergeHoverTracker``. Вызывается на каждом шаге drag (и на каждом
    /// кадре автопрокрутки) сразу после вычисления цели под пальцем, поэтому
    /// обязана быть дешёвой: в установившемся состоянии она делает одно
    /// сравнение смещения.
    ///
    /// - Parameters:
    ///   - target: Цель под пальцем.
    ///   - point: Точка пальца в координатах сетки.
    private func updateMergeHover(for target: HoverTarget, at point: CGPoint) {
        guard let targetID = target.mergeTargetID else {
            // Центр ярлыка и центральная зона папки — цели удержания; любая
            // другая цель (перестановка, пустое место) снимает удержание.
            resetMergeHover()
            return
        }

        guard mergeTracker?.targetID == targetID else {
            // Смена цели — новый отсчёт: удерживать нужно именно над этой
            // плиткой, а не «где-то рядом» (E8.6).
            armMergeHover(on: targetID, at: point)
            return
        }

        let wasReady = mergeTracker?.state == .fired
        guard mergeTracker?.update(point: point) == true else { return }

        // E12.3: палец сместился на допуск или больше — прежнее удержание
        // отменено, якорь перенесён в текущую точку, отсчёт 600 мс (E9.8а)
        // начат заново. Старый таймер снимается (`scheduleMergeTimer` делает
        // это сам), уже показанное «впитывание» откатывается.
        scheduleMergeTimer()
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
              let targetID = session.hover.mergeTargetID,
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
        if case .folder = session.hover {
            announce(TesseraStartScreenStrings.string(.a11yDragHoldToAddToFolder))
        } else {
            announce(TesseraStartScreenStrings.string(.a11yDragHoldToCreateFolder))
        }
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
        if let style = dragSession?.hover.baseHighlightStyle {
            view.apply(style)
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
        case .none, .cell, .newRow, .sourceFolder:
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

        if let session = dragSession, let targetID = session.hover.mergeTargetID {
            ready = mergeTracker?.isMergeReady == true
            // «Впитывание» усиливает тот же стиль цели: для центра ярлыка —
            // оранжевый `.merge`, для центра папки — синий `.mergeFolder`.
            let baseStyle = session.hover.baseHighlightStyle ?? .group
            let style: TesseraTileDropHighlightView.Style
            if ready {
                style = baseStyle == .folder ? .mergeFolder : .merge
            } else {
                style = baseStyle
            }
            showDropHighlight(for: targetID, style: style)
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
        case .none, .cell, .newRow, .sourceFolder:
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
    /// Остальные гаснут до ``TesseraTileGridView/dimmedTileAlpha`` (0,7). Скрытые
    /// координатором ячейки (`alpha == 0`: drag/unpin) не трогаем — их
    /// видимостью владеет `TesseraTileGridView.setItemHidden`, и «поднять»
    /// такую плитку до 0,7 значило бы показать её раньше времени. Само
    /// применение и хранение дима — в сетке (E10.4,
    /// `TesseraTileGridView.setEditDimming(_:animated:)`): `configure` ячейки
    /// больше не сбрасывает прозрачность, поэтому дим переживает
    /// update/resize/drop.
    ///
    /// - Parameters:
    ///   - animated: Анимировать переход или выставить прозрачность сразу.
    ///     При Reduce Motion анимации нет, но сам дим применяется: это не
    ///     движение, его убирать нельзя (длительность — у сетки).
    ///   - itemIDs: Ограничение набора ячеек (горячий путь прокрутки передаёт
    ///     только плитки с кнопками). `nil` — все элементы снимка.
    private func applyEditDimming(animated: Bool, limitedTo itemIDs: [AnyHashable]? = nil) {
        // E10.4: владелец дима — сетка. Координатор только считает цели:
        // сетка применяет их к видимым ячейкам и хранит, поэтому `configure`
        // (update/resize/drop/переиспользование) больше не стирает дим.
        let candidates = itemIDs ?? grid.items.map { $0.id }
        var targets: [AnyHashable: CGFloat] = [:]
        targets.reserveCapacity(candidates.count)

        for itemID in candidates {
            // alpha скрытой перетаскиваемой ячейки принадлежит drag-сессии:
            // скрытие сильнее дима, сетка сама оставит её прозрачной.
            if itemID == dragSession?.itemID { continue }
            targets[itemID] = dimmingTargetAlpha(for: itemID)
        }

        guard !targets.isEmpty else { return }
        grid.setEditDimming(targets, animated: animated && !isReduceMotionEnabled())
    }

    /// Цели полной яркости для всех элементов сетки (E8.2, E10.4).
    ///
    /// Используется при снятии дима: сетка — владелец прозрачности, координатор
    /// только передаёт «все 1».
    ///
    /// - Returns: Прозрачность 1 по идентификатору каждого элемента снимка.
    private func liftedDimmingTargets() -> [AnyHashable: CGFloat] {
        var targets: [AnyHashable: CGFloat] = [:]
        targets.reserveCapacity(grid.items.count)
        for item in grid.items {
            targets[item.id] = 1
        }
        return targets
    }

    /// Целевая прозрачность содержимого плитки в текущем состоянии.
    ///
    /// Во время drag «выбранной» считается перетаскиваемая плитка и цель под
    /// пальцем; вне drag — плитка, через которую вошли в редактирование.
    ///
    /// - Parameter itemID: Идентификатор плитки.
    /// - Returns: 1 для полной яркости, ``TesseraTileGridView/dimmedTileAlpha`` для дима.
    private func dimmingTargetAlpha(for itemID: AnyHashable) -> CGFloat {
        guard isEditing else { return 1 }

        if let session = dragSession {
            if itemID == session.itemID { return 1 }

            switch session.hover {
            case .folder(let targetID), .group(let targetID):
                if targetID == itemID { return 1 }
            case .none, .cell, .newRow, .sourceFolder:
                break
            }
            return TesseraTileGridView.dimmedTileAlpha
        }

        if itemID == dimmingFocusID { return 1 }
        return TesseraTileGridView.dimmedTileAlpha
    }

    // MARK: - Drag: финал

    /// Завершает перетаскивание.
    ///
    /// Внутренний шаг drag-сессии (жест — `.ended`/`.cancelled`); тесты E4.7
    /// вызывают его через `@testable import`, чтобы завершить перестановку без
    /// симуляции касаний.
    ///
    /// E8.4/E14.5: сетка к этому моменту показывает превью раскладки, а модель
    /// всё ещё в состоянии на момент захвата. Drop фиксирует цель под пальцем
    /// одной операцией `TileStore` по ячейкам: ``HoverTarget/cell(_:)`` —
    /// ``TileStore/moveItem(_:toCell:columns:)`` (из папки —
    /// ``TileStore/extractFromFolder(_:toCell:columns:)``), ``HoverTarget/newRow`` —
    /// ``TileStore/moveItemToNewRow(_:columns:)`` / ``TileStore/extractFromFolderToNewRow(_:columns:)``,
    /// ``HoverTarget/group`` — создание папки на ячейке цели (D20), ``HoverTarget/folder`` —
    /// ``TileStore/addToFolder(_:folderID:columns:)`` (из папки —
    /// ``TileStore/moveBetweenFolders(_:to:columns:)``). После удачной операции
    /// схлопывается пустая строка (``TileStore/collapseEmptyRows(columns:)``,
    /// D31). Отмена, drop без цели и drop без изменений возвращают сетке базовую
    /// раскладку и не пишут в модель вовсе. E9.5: drop в центр без удержания
    /// E8.6 — no-op.
    ///
    /// - Parameter commit: `true` — зафиксировать превью, `false` — вернуть
    ///   порядок на момент захвата (жест отменён).
    func finishDrag(commit: Bool) {
        guard let session = dragSession else { return }

        // E10.5-B1: модель/снимок разошлись с базой захвата — фиксировать
        // превью нельзя, безопасно отменяем и синхронизируемся с моделью.
        guard dragStateIsConsistent(session) else {
            cancelDragForExternalChange()
            return
        }

        defer {
            storeChangedDuringDrag = false
            endDragStoreTransaction(saveIfNeeded: session.modelChanged)
        }

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
            restore()
            settleDragView(session) {
                self.cleanupDrag(session, unhide: true)
            }
            return
        }

        // m7 (W5-фикс): панель раскрытой папки — не drop-цель. Если хост открыл
        // панель во время drag (долгое нажатие её обычно закрывает, но хост
        // вправе открыть её сам), hover остаётся `.none`, и default-ветка
        // зафиксировала бы последнее push-превью. Отпускание над панелью
        // возвращает ярлык на исходное место: store и делегат не трогаем.
        // Проверка по последней точке нужна, если панель появилась под пальцем
        // уже после последнего шага drag.
        if session.isOverFolderPanel || isPointOverFolderPanel(session.lastPoint) {
            returnAfterNoOpDrop(session)
            return
        }

        switch session.hover {
        case .sourceFolder:
            // E11.1: центр родной папки — ярлык возвращается, модель не меняется.
            returnAfterNoOpDrop(session)

        case .folder(let folderID) where session.isTile && isMergeReady:
            // E10.5-A1/E8.6: центр папки с выдержанным удержанием — добавляем
            // ярлык внутрь (D14). E11.1: для ярлыка из папки это перенос.
            if session.sourceFolderID != nil {
                dropFromFolderIntoFolder(session, folderID: folderID)
            } else {
                dropIntoFolder(session, folderID: folderID)
            }

        case .group(let targetID) where session.isTile && isMergeReady:
            // E8.6: папка создаётся только если удержание выдержано (подсветка
            // уже показала «впитывание»).
            dropIntoNewFolder(session, targetID: targetID)

        case .folder where session.isTile, .group where session.isTile:
            // E9.5: drop в центр без удержания 600 мс — возврат на исходное
            // место (no-op/отмена). Пуш-превью центральной зоны не делаем.
            returnAfterNoOpDrop(session)

        case .cell(let cell):
            dropOntoGrid(session, cell: cell)

        case .newRow:
            dropOntoGrid(session, cell: nil)

        default:
            // Цели нет (вне сетки, над своей ячейкой, подъём без движения):
            // раскладка не меняется, элемент возвращается на место / в папку.
            returnAfterNoOpDrop(session)
        }
    }

    /// Возврат ярлыка на исходное место при no-op drop (E9.5).
    ///
    /// Вызывается, когда drop отпущен над центром ярлыка/папки без выдержанного
    /// удержания E8.6 (E9.5), а также над панелью раскрытой папки (m7).
    /// Модель не меняется, делегат не получает `didMove`.
    /// Сетка возвращается к порядку модели (если палец успел побывать в зоне
    /// перестановки, превью снимается), снимок уезжает на место.
    ///
    /// - Parameter session: Drag-сессия.
    private func returnAfterNoOpDrop(_ session: TesseraTileDragSession) {
        restore()
        settleDragView(session) {
            self.cleanupDrag(session, unhide: true)
        }
    }

    /// Возвращает снимок на место после отмены/no-op/отказа (E11.1).
    ///
    /// Обычный элемент едет в свой слот. Ярлык, взятый из папки, после
    /// `restore()` уже не элемент сетки (синтетический слот убран вместе с
    /// отображаемым снимком) — он «впитывается» обратно в папку-источник.
    ///
    /// - Parameters:
    ///   - session: Drag-сессия.
    ///   - completion: Завершение (убрать оверлеи).
    private func settleDragView(
        _ session: TesseraTileDragSession,
        completion: @escaping () -> Void
    ) {
        if let sourceID = session.sourceFolderID,
           grid.index(ofItemID: session.itemID) == nil,
           let folderFrame = grid.frame(forItemID: sourceID) {
            collapseDragView(session, into: folderFrame, completion: completion)
        } else {
            moveDragView(session, to: currentFrame(of: session), completion: completion)
        }
    }

    /// Завершает drop на клетку или в новую строку (E14.5, D21, D33).
    ///
    /// Элемент сетки переносится ``TileStore/moveItem(_:toCell:columns:)`` /
    /// ``TileStore/moveItemToNewRow(_:columns:)``: старое место остаётся дырой,
    /// мешающие плитки выталкиваются вниз каскадом (D31). Ярлык из панели папки
    /// выносится ``TileStore/extractFromFolder(_:toCell:columns:)`` /
    /// ``TileStore/extractFromFolderToNewRow(_:columns:)`` (E11.1): одобрение
    /// хоста спрашивается там же (D14), папка с одним оставшимся ярлыком
    /// распускается (D45: ярлык встаёт на её ячейку, делегат получает
    /// `didDissolveFolder` после `didMove`).
    /// После удачной операции схлопывается полностью пустая строка. Если
    /// раскладка не изменилась (элемент и так на этой ячейке), это no-op.
    /// Дальше как у остальных drop'ов: `render`, рамка читается после него, фокус
    /// VoiceOver — на элементе.
    ///
    /// - Parameters:
    ///   - session: Drag-сессия.
    ///   - cell: Желаемая ячейка; `nil` — новая строка в конце холста.
    private func dropOntoGrid(_ session: TesseraTileDragSession, cell: TileGridPlacement?) {
        let columns = session.columns

        if session.sourceFolderID != nil {
            let extracted: Bool
            if let cell {
                extracted = store.extractFromFolder(session.itemID, toCell: cell, columns: columns)
            } else {
                extracted = store.extractFromFolderToNewRow(session.itemID, columns: columns)
            }
            guard extracted else {
                failGroupingDrop(
                    .moveBetweenFolders,
                    session: session,
                    folderID: nil,
                    reason: TesseraStartScreenStrings.string(.a11yGroupingReasonMoveDenied)
                )
                return
            }

            session.modelChanged = true
            store.collapseEmptyRows(columns: columns)
            render(animated: true)
            let frame = currentFrame(of: session)
            delegate?.tileEditCoordinator(
                self,
                didMove: session.itemID,
                toFolder: nil,
                atCell: store.placements(forColumns: columns)[session.itemID]
            )
            notifyDissolution(of: session)
            announce(TesseraStartScreenStrings.string(.a11yFolderTileOnStart))
            UINotificationFeedbackGenerator().notificationOccurred(.success)

            moveDragView(session, to: frame) {
                self.cleanupDrag(session, unhide: true)
                self.postLayoutChanged(focusing: session.itemID)
            }
            return
        }

        let moved: Bool
        if let cell {
            moved = store.moveItem(session.itemID, toCell: cell, columns: columns)
        } else {
            moved = store.moveItemToNewRow(session.itemID, columns: columns)
        }
        guard moved else {
            // Раскладка не изменилась (или элемент исчез из модели): сетка
            // возвращается к модели, делегат и сохранение не трогаются.
            returnAfterNoOpDrop(session)
            return
        }

        session.modelChanged = true
        store.collapseEmptyRows(columns: columns)
        render(animated: true)
        let actualCell = store.placements(forColumns: columns)[session.itemID]
        let frame = currentFrame(of: session)
        moveDragView(session, to: frame) {
            self.cleanupDrag(session, unhide: true)
            if let actualCell {
                self.delegate?.tileEditCoordinator(
                    self,
                    didMove: session.itemID,
                    toCell: actualCell
                )
            }
            // E10.5-B6: после переноса фокус VoiceOver — на переехавшую плитку.
            self.postLayoutChanged(focusing: session.itemID)
        }
    }

    /// Завершает drop ярлыка из панели на центр другой папки (E11.1).
    ///
    /// Вызывается только при выдержанном удержании E8.6. Перенос идёт через
    /// ``TileStore/moveBetweenFolders(_:to:columns:)`` (одобрение хоста, D14);
    /// папка-источник из двух ярлыков распускается (D45): оставшийся ярлык встаёт
    /// на её место, делегат получает `didDissolveFolder` после `didMove`.
    ///
    /// - Parameters:
    ///   - session: Drag-сессия (источник — папка).
    ///   - folderID: Папка-цель.
    private func dropFromFolderIntoFolder(_ session: TesseraTileDragSession, folderID: AnyHashable) {
        guard store.moveBetweenFolders(session.itemID, to: folderID, columns: session.columns) else {
            failGroupingDrop(
                .moveBetweenFolders,
                session: session,
                folderID: folderID,
                reason: TesseraStartScreenStrings.string(.a11yGroupingReasonMoveDenied)
            )
            return
        }

        session.modelChanged = true
        store.collapseEmptyRows(columns: session.columns)
        render(animated: true)
        // Рамку цели читаем после синхронизации: схлопывание строк могло сдвинуть
        // папку.
        let folderFrame = grid.frame(forItemID: folderID) ?? session.placeholder.frame
        delegate?.tileEditCoordinator(
            self,
            didMove: session.itemID,
            toFolder: folderID,
            atCell: nil
        )
        notifyDissolution(of: session)
        announce(TesseraStartScreenStrings.string(.a11yFolderTileMoved))
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        collapseDragView(session, into: folderFrame) {
            self.cleanupDrag(session, unhide: false)
            self.postLayoutChanged(focusing: folderID)
        }
    }

    /// Завершает drop на существующую папку (D14).
    ///
    /// - Parameters:
    ///   - session: Drag-сессия.
    ///   - folderID: Папка-цель.
    private func dropIntoFolder(_ session: TesseraTileDragSession, folderID: AnyHashable) {
        guard store.addToFolder(session.itemID, folderID: folderID, columns: session.columns) else {
            failGroupingDrop(
                .addToFolder,
                session: session,
                folderID: folderID,
                reason: TesseraStartScreenStrings.string(.a11yGroupingReasonAddDenied)
            )
            return
        }

        session.modelChanged = true
        // E14.5: ячейка ярлыка осталась дырой; пустая строка схлопывается.
        store.collapseEmptyRows(columns: session.columns)
        render(animated: true)
        // Рамку папки читаем после синхронизации: схлопывание строки могло
        // сдвинуть папку вверх, и снимок должен лететь в её актуальный слот.
        let folderFrame = grid.frame(forItemID: folderID) ?? session.placeholder.frame
        delegate?.tileEditCoordinator(self, didAdd: session.itemID, toFolder: folderID)
        announce(TesseraStartScreenStrings.string(.a11yFolderTileAdded))
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        collapseDragView(session, into: folderFrame) {
            self.cleanupDrag(session, unhide: false)
            self.postLayoutChanged(focusing: folderID)
        }
    }

    /// Завершает drop на центр другого ярлыка: создаёт папку из двух ярлыков.
    ///
    /// E8.6: вызывается только из ``finishDrag(commit:)`` и только когда
    /// удержание выдержано (`TesseraMergeHoverTracker/isMergeReady`) —
    /// «впитывание» уже показано пользователю. Drop на центр без удержания
    /// сюда не попадает: он возвращает ярлык на исходное место (no-op, E9.5).
    ///
    /// E14.5: папка встаёт на ячейку цели и всегда 2×2 (D20), соседи
    /// выталкиваются вниз каскадом (D31), ячейка перетаскиваемого ярлыка остаётся
    /// дырой (``TileStore/createFolder(from:onto:title:columns:)``).
    ///
    /// Операция D14 состоит из двух одобряемых шагов (создание папки из
    /// целевого ярлыка, добавление перетаскиваемого), но выполняется атомарно
    /// (E11.6): ``TileStore`` не меняет модель, если хост отказал на любом шаге,
    /// — модель остаётся ровно как до drop'а, а делегат получает только
    /// `didFailGrouping` (папки не существовало, поэтому `folderID == nil`).
    /// `didCreateFolder` приходит только после успеха обоих шагов, перед
    /// `didAdd`.
    ///
    /// - Parameters:
    ///   - session: Drag-сессия.
    ///   - targetID: Ярлык, на центр которого бросили.
    private func dropIntoNewFolder(_ session: TesseraTileDragSession, targetID: AnyHashable) {
        let folder: TileFolder
        switch store.createFolder(
            from: session.itemID,
            onto: targetID,
            title: resolvedNewFolderTitle(configuration.folderTitle),
            columns: session.columns
        ) {
        case .created(let created):
            folder = created
        case .createDenied:
            failGroupingDrop(
                .createFolder,
                session: session,
                folderID: nil,
                reason: TesseraStartScreenStrings.string(.a11yGroupingReasonCreateDenied)
            )
            return
        case .addDenied:
            failGroupingDrop(
                .addToFolder,
                session: session,
                folderID: nil,
                reason: TesseraStartScreenStrings.string(.a11yGroupingReasonTileAddDenied)
            )
            return
        }

        session.modelChanged = true
        store.collapseEmptyRows(columns: session.columns)
        render(animated: true)
        // E11.3: рамку папки читаем после `render` — до него новой плитки в
        // сетке нет, и снимок летел бы в старый слот плейсхолдера.
        let folderFrame = grid.frame(forItemID: folder.id) ?? session.placeholder.frame
        delegate?.tileEditCoordinator(self, didCreateFolder: folder)
        delegate?.tileEditCoordinator(self, didAdd: session.itemID, toFolder: folder.id)
        announce(TesseraStartScreenStrings.string(.a11yFolderCreatedFromTwoTiles))
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        collapseDragView(session, into: folderFrame) {
            self.cleanupDrag(session, unhide: false)
            self.postLayoutChanged(focusing: folder.id)
        }
    }

    /// Возвращает ярлык на место после отказа функции одобрения (D14).
    ///
    /// E8.4: превью порядка в модель не писало; сетку синхронизируем с текущим
    /// состоянием `TileStore`, а не с базовым снимком: модель могла измениться
    /// извне, иначе экран разошёлся бы с ней. Двухшаговое создание папки
    /// откатывается в хранилище целиком (E11.6), так что при его отказе модель
    /// совпадает с состоянием до drop'а.
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
        announce(String(format: TesseraStartScreenStrings.string(.a11yGroupingFailedFormat), reason))
        delegate?.tileEditCoordinator(
            self,
            didFailGrouping: action,
            tileID: session.itemID,
            folderID: folderID
        )

        settleDragView(session) {
            self.cleanupDrag(session, unhide: true)
        }
    }

    /// Возвращает сетке порядок модели (отмена drag, E8.4).
    ///
    /// Модель за время drag не менялась — превью живёт только в сетке, поэтому
    /// откат не пишет в `TileStore` и не вызывает `onChange` у хоста. Источник
    /// истины — текущий снимок модели, а не база захвата: если модель успела
    /// измениться извне, сетка не должна откатиться к устаревшему порядку
    /// (E10.5-B1).
    private func restore() {
        syncGridWithModel(animated: true)
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

        restore()
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
        lastCollapseTargetFrame = frame
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
        // E10.5-B1: автопрокрутка — тоже шаг drag; внешнее изменение отменяет
        // сессию до пересчёта целей.
        guard dragStateIsConsistent(session) else {
            cancelDragForExternalChange()
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
    /// Тут же переприменяется димминг (E8.2): новые и переиспользованные ячейки
    /// могли появиться с полной яркостью, поэтому прозрачность выставляется
    /// после конфигурации. Владелец дима — сетка (E10.4).
    ///
    /// - Parameters:
    ///   - animated: Анимировать ли переезд кнопок при resize/reorder.
    ///   - dimAnimated: Анимировать ли переход прозрачности (вход в режим).
    private func reconcileEditControls(animated: Bool, dimAnimated: Bool = false) {
        guard isEditing else {
            removeAllEditControls()
            return
        }

        syncEditControlsHost()
        let items = grid.items
        let actualIDs = Set(items.map { $0.id })

        for itemID in editControls.keys where !actualIDs.contains(itemID) {
            editControls[itemID]?.removeFromSuperview()
        }
        editControls = editControls.filter { actualIDs.contains($0.key) }

        let reduceMotion = isReduceMotionEnabled()
        let folderTargets = store.snapshot().folders
        // Оверлеи создаются только для плиток у экрана (и одной экранной высоты
        // запаса): держать кнопки для сотни далёких ярлыков незачем.
        let creationBounds = grid.bounds.insetBy(dx: 0, dy: -grid.bounds.height)
        // D29, E15.1: бэйдж плитки обходит стрелку размера — сетке сообщается,
        // сколько угла она занимает.
        var badgeClearances: [AnyHashable: CGFloat] = [:]

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
                // E12.9: новый оверлей сразу встаёт на место плитки — иначе
                // анимированный проход анимировал бы его из нулевой рамки
                // (перелёт из левого верхнего угла сетки).
                control.frame = frame
                editControls[item.id] = control
            }

            let canUnpin = item.tile != nil
            let canResize = supportedSizes(for: item).count > 1
            control.configure(canUnpin: canUnpin, canResize: canResize)
            control.layer.zPosition = 200
            badgeClearances[item.id] = canResize
                ? TesseraTileEditControlView.badgeClearance(
                    forTileSize: frame.size,
                    maxDiameter: configuration.controlDiameter
                )
                : 0

            let isDragged = dragSession?.itemID == item.id
            control.isHidden = isDragged || !frame.intersects(grid.bounds)
            control.tileSize = frame.size

            if animated, !reduceMotion, control.frame != frame {
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
            applyEditActions(to: item, folders: folderTargets)
        }
        applyPanelEditActions(folders: folderTargets)
        reconcilePanelEditControls(fadesIn: false)
        grid.setBadgeEditClearances(badgeClearances, animated: animated || dimAnimated)

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
        editControlsContainer().addSubview(control)
        return control
    }

    /// Возвращает обрезающий контейнер кнопок, создавая его при необходимости.
    ///
    /// E12.4: контейнер лежит над коллекцией (`zPosition` 200, как раньше у
    /// самих кнопок: ниже снимка drag и плейсхолдера) и повторяет `bounds`
    /// сетки.
    private func editControlsContainer() -> TesseraTileEditControlsHostView {
        if let host = editControlsHost, host.superview === grid {
            syncEditControlsHost()
            return host
        }
        let host = TesseraTileEditControlsHostView()
        host.layer.zPosition = 200
        grid.addSubview(host)
        editControlsHost = host
        syncEditControlsHost()
        return host
    }

    /// Выравнивает контейнер кнопок по `bounds` сетки (только `frame`).
    private func syncEditControlsHost() {
        guard let host = editControlsHost, host.frame != grid.bounds else { return }
        host.frame = grid.bounds
    }

    // MARK: - Кнопки на ярлыках панели папки (D46)

    /// Создаёт, двигает и снимает кнопки открепления на ярлыках панели.
    ///
    /// Кнопки есть, только когда: идёт редактирование, нет drag, панель видима,
    /// её ячейки соответствуют составу папки и она **не переезжает** (не
    /// открывается и не закрывается). Иначе все кнопки панели снимаются. Кнопка
    /// ярлыка, который сейчас улетает (``unpinPanelTile(_:)``), не показывается.
    /// Это тот же оверлей, что на плитках сетки (общий размер и угол —
    /// ``TesseraTileEditControlView/unpinButtonFrame(inTileBounds:side:isRightToLeft:)``),
    /// но только с кнопкой открепления и с урезанной зоной касания.
    ///
    /// - Parameter fadesIn: Плавно проявлять новые кнопки (раскрытие панели);
    ///   при Reduce Motion они появляются сразу.
    private func reconcilePanelEditControls(fadesIn: Bool) {
        guard isEditing, dragSession == nil, !grid.isFolderChangeAnimating,
              let geometry = grid.panelShortcutGeometry(),
              geometry.frames.count == geometry.tileIDs.count else {
            removeAllPanelEditControls()
            return
        }

        syncEditControlsHost()
        let liveIDs = Set(geometry.tileIDs)
        for (tileID, control) in panelEditControls where !liveIDs.contains(tileID) {
            control.removeFromSuperview()
        }
        panelEditControls = panelEditControls.filter { liveIDs.contains($0.key) }

        let animatesAppearance = fadesIn && !isReduceMotionEnabled()
        let outset = min(
            TesseraTileEditControlView.cornerOverhang,
            max(0, geometry.spacing)
        )
        for (index, tileID) in geometry.tileIDs.enumerated() {
            // Ярлык улетает: его кнопка уже снята и не возвращается до конца.
            if unpinsInFlight.contains(tileID) {
                removePanelControl(for: tileID)
                continue
            }

            let frame = geometry.frames[index]
            let control: TesseraTileEditControlView
            if let existing = panelEditControls[tileID] {
                control = existing
            } else {
                control = makePanelControl(for: tileID)
                control.frame = frame
                control.tileSize = frame.size
                panelEditControls[tileID] = control
                if animatesAppearance {
                    control.alpha = 0
                    UIView.animate(
                        withDuration: 0.18,
                        delay: 0,
                        options: [.allowUserInteraction, .curveEaseOut],
                        animations: { control.alpha = 1 },
                        completion: nil
                    )
                }
            }
            control.panelHitOutset = outset
            control.tileSize = frame.size
            control.frame = frame
            control.isHidden = !frame.intersects(grid.bounds)
        }
    }

    /// Двигает кнопки панели за ярлыками при прокрутке (только `frame`).
    private func updatePanelEditControlFrames() {
        guard !panelEditControls.isEmpty else { return }
        guard let geometry = grid.panelShortcutGeometry(),
              !grid.isFolderChangeAnimating else {
            for control in panelEditControls.values { control.isHidden = true }
            return
        }

        syncEditControlsHost()
        for (index, tileID) in geometry.tileIDs.enumerated() {
            guard let control = panelEditControls[tileID] else { continue }
            let frame = geometry.frames[index]
            control.frame = frame
            control.tileSize = frame.size
            control.isHidden = !frame.intersects(grid.bounds)
        }
    }

    /// Создаёт оверлей ярлыка панели: только кнопка открепления.
    ///
    /// - Parameter tileID: Идентификатор ярлыка папки.
    /// - Returns: Оверлей, уже добавленный в контейнер кнопок.
    private func makePanelControl(for tileID: AnyHashable) -> TesseraTileEditControlView {
        let control = TesseraTileEditControlView(diameter: configuration.controlDiameter)
        control.isPanelMember = true
        // Без стрелки размера: у члена папки своего размера нет; открепления у
        // самой папки нет по D38, поэтому оверлей папки сюда не попадает.
        control.configure(canUnpin: true, canResize: false)
        control.layer.zPosition = 200
        control.onUnpin = { [weak self] in
            self?.unpinPanelTile(tileID)
        }
        editControlsContainer().addSubview(control)
        return control
    }

    /// Убирает кнопку ярлыка панели.
    private func removePanelControl(for tileID: AnyHashable) {
        panelEditControls[tileID]?.removeFromSuperview()
        panelEditControls.removeValue(forKey: tileID)
    }

    /// Убирает все кнопки панели.
    private func removeAllPanelEditControls() {
        for control in panelEditControls.values {
            control.removeFromSuperview()
        }
        panelEditControls.removeAll()
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
        removeAllPanelEditControls()
        editControlsHost?.removeFromSuperview()
        editControlsHost = nil
        // Стрелок больше нет — бэйджи возвращаются в угол (D29, E15.1).
        grid.resetBadgeEditClearances(animated: true)

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

        syncEditControlsHost()
        for (itemID, control) in editControls {
            guard let frame = grid.frame(forItemID: itemID) else {
                control.isHidden = true
                continue
            }
            control.frame = frame
            control.tileSize = frame.size
            control.isHidden = dragSession?.itemID == itemID
                || !frame.intersects(grid.bounds)
        }

        updatePanelEditControlFrames()

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
            // E10.5-B1: к этому моменту хост уже применил внешний снимок —
            // активный drag с разошедшимся состоянием безопасно отменяем.
            if let session = self.dragSession, !self.dragStateIsConsistent(session) {
                self.cancelDragForExternalChange()
                return
            }
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

    /// Выставляет ячейке custom actions resize/unpin/«в папку» (§9, E11.5).
    ///
    /// Ячейка — один accessibility-элемент, поэтому кнопки-подвью VoiceOver не
    /// видит; действия добавляются к самой ячейке. Для ярлыка на сетке к
    /// «Открепить»/«Изменить размер» добавляется «Добавить в папку <название>»
    /// по одному на папку (не больше ``maxFolderActions``). Операции идут через
    /// публичный ``addToFolder(_:folderID:)`` — функция одобрения хоста (D14),
    /// озвучивание и фокус уже там. У плитки-папки новых действий нет.
    ///
    /// - Parameters:
    ///   - item: Элемент сетки.
    ///   - folders: Папки модели в порядке сетки.
    private func applyEditActions(to item: TileGridItem, folders: [TileFolder]) {
        guard let cell = grid.cellView(forItemID: item.id) as? TesseraTileCell,
              cell.itemID == item.id else {
            return
        }

        let key = ObjectIdentifier(cell)
        let targets = item.tile != nil ? Array(folders.prefix(TesseraTileEditCoordinator.maxFolderActions)) : []
        let signature: [AnyHashable] = [item.id] + targets.map { $0.id }
        guard editActionsItemByCell[key] != signature else { return }

        var actions: [UIAccessibilityCustomAction] = []
        if item.tile != nil {
            actions.append(
                UIAccessibilityCustomAction(name: TesseraStartScreenStrings.string(.a11yActionUnpin), image: nil) { [weak self] _ in
                    guard let self else { return false }
                    self.unpin(item.id)
                    return true
                }
            )
        }
        if supportedSizes(for: item).count > 1 {
            actions.append(
                UIAccessibilityCustomAction(name: TesseraStartScreenStrings.string(.a11yActionResize), image: nil) { [weak self] _ in
                    guard let self else { return false }
                    self.cycleSize(of: item.id)
                    return true
                }
            )
        }
        for folder in targets {
            let name = String(
                format: TesseraStartScreenStrings.string(.a11yActionAddToFolderFormat),
                folderActionTitle(folder)
            )
            let folderID = folder.id
            actions.append(
                UIAccessibilityCustomAction(name: name, image: nil) { [weak self] _ in
                    guard let self else { return false }
                    return self.addToFolder(item.id, folderID: folderID)
                }
            )
        }

        cell.accessibilityCustomActions = actions.isEmpty ? nil : actions
        cellsWithEditActions[key] = cell
        editActionsItemByCell[key] = signature
    }

    /// Выставляет custom actions ярлыкам панели раскрытой папки (E11.5).
    ///
    /// «Убрать из папки» — ``moveBetweenFolders(_:to:)`` с `nil`: ярлык
    /// встаёт сразу после папки (или на её месте, если она распалась).
    /// «Открепить» — ``unpin(_:)`` (D45: при двух ярлыках папка распускается).
    /// «Переместить в папку <название>» — по одному на другую папку (не больше
    /// ``maxFolderActions``). Вне режима редактирования действий нет.
    ///
    /// - Parameter folders: Папки модели в порядке сетки.
    private func applyPanelEditActions(folders: [TileFolder]) {
        guard isEditing, let panel = grid.panelShortcuts() else { return }

        let targets = folders
            .filter { $0.id != panel.folder.id }
            .prefix(TesseraTileEditCoordinator.maxFolderActions)
        for (index, cell) in panel.cells.enumerated() where panel.folder.tiles.indices.contains(index) {
            let tileID = panel.folder.tiles[index].id
            let key = ObjectIdentifier(cell)
            let signature: [AnyHashable] = [tileID, panel.folder.id] + targets.map { $0.id }
            guard editActionsItemByCell[key] != signature else { continue }

            var actions: [UIAccessibilityCustomAction] = [
                UIAccessibilityCustomAction(
                    name: TesseraStartScreenStrings.string(.a11yActionRemoveFromFolder),
                    image: nil
                ) { [weak self] _ in
                    guard let self else { return false }
                    return self.moveBetweenFolders(tileID, to: nil)
                },
                // D45: «Открепить» ярлык папки — путь, которым папка распускается
                // «по одному» (W10M §6.9); при двух ярлыках панель закроется, а
                // оставшийся ярлык встанет на место папки.
                UIAccessibilityCustomAction(
                    name: TesseraStartScreenStrings.string(.a11yActionUnpin),
                    image: nil
                ) { [weak self] _ in
                    guard let self else { return false }
                    self.unpin(tileID)
                    return true
                },
            ]
            for folder in targets {
                let name = String(
                    format: TesseraStartScreenStrings.string(.a11yActionMoveToFolderFormat),
                    folderActionTitle(folder)
                )
                let folderID = folder.id
                actions.append(
                    UIAccessibilityCustomAction(name: name, image: nil) { [weak self] _ in
                        guard let self else { return false }
                        return self.moveBetweenFolders(tileID, to: folderID)
                    }
                )
            }
            cell.accessibilityCustomActions = actions
            cellsWithEditActions[key] = cell
            editActionsItemByCell[key] = signature
        }
    }

    /// Название новой папки (E12.7): пустое — локализованное по умолчанию.
    ///
    /// Значение по умолчанию живёт в строках модуля
    /// (`folderScreen.defaultTitle`, en/ru), а не в конфигурации:
    /// ``TesseraTileEditConfiguration/folderTitle`` лишь перекрывает его.
    /// `TileStore` по-прежнему принимает пустое название — подстановка только
    /// на пути создания папки редактором.
    private func resolvedNewFolderTitle(_ title: String) -> String {
        title.isEmpty ? TesseraStartScreenStrings.string(.folderScreenDefaultTitle) : title
    }

    /// Название папки для пунктов custom actions: пустое — из конфигурации,
    /// затем общая подпись папки без названия.
    private func folderActionTitle(_ folder: TileFolder) -> String {
        if !folder.title.isEmpty { return folder.title }
        if !configuration.folderTitle.isEmpty { return configuration.folderTitle }
        return TesseraStartScreenStrings.string(.folderScreenDefaultTitle)
    }

    /// Озвучивает сообщение VoiceOver.
    ///
    /// - Parameter message: Готовая локализованная строка (``TesseraStartScreenStrings``).
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
        performBackgroundTap(at: recognizer.location(in: grid))
    }

    /// Решение жеста «тап по фону»: вышел ли тап в точке из редактирования.
    ///
    /// Вынесено из обработчика, чтобы тест мог прогнать «касание → решение
    /// `shouldReceive` → действие» без настоящего `UITapGestureRecognizer`.
    ///
    /// - Parameter point: Точка тапа в координатах сетки.
    func performBackgroundTap(at point: CGPoint) {
        guard isEditing, dragSession == nil else { return }
        guard grid.item(at: point) == nil else { return }
        endEditing()
    }

    /// Попадает ли касание в зону кнопки правки.
    ///
    /// Решение принимает сам контейнер кнопок тем же `hitTest`, которым кнопки
    /// получают касания (зоны касания, RTL-зеркалирование, видимость, наложения
    /// соседних оверлеев), поэтому жест фона и кнопки не могут разойтись.
    ///
    /// - Parameter touch: Касание жеста фона.
    /// - Returns: `true`, если под касанием кнопка «открепить» или «размер».
    private func isEditControlHit(by touch: UITouch) -> Bool {
        guard let host = editControlsHost, host.superview === grid else { return false }
        return host.hitTest(touch.location(in: host), with: nil) != nil
    }

    /// Жест «тап по фону» (для тестов: проверка `isEnabled` и `shouldReceive`).
    var backgroundTapGestureRecognizer: UIGestureRecognizer { backgroundTapRecognizer }

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

    /// Локализованное название размера для озвучивания.
    ///
    /// - Parameter size: Размер ярлыка.
    /// - Returns: Название для VoiceOver.
    private static func name(for size: TileSize) -> String {
        switch size {
        case .small: return TesseraStartScreenStrings.string(.a11ySizeSmall)
        case .medium: return TesseraStartScreenStrings.string(.a11ySizeMedium)
        case .wide: return TesseraStartScreenStrings.string(.a11ySizeWide)
        case .large: return TesseraStartScreenStrings.string(.a11ySizeLarge)
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
            // Касание в зоне любой кнопки правки (плитка сетки или ярлык панели,
            // включая выступ в зазор и расширенную до 44 pt зону) принадлежит
            // кнопке: иначе тап по выступающей части сработал бы и как «тап по
            // пустому месту» и вывел бы из правки (E15.10).
            return isEditing && dragSession == nil && !isEditControlHit(by: touch)
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
/// - ``State/fired`` — порог выдержан, drop создаёт папку (``isMergeReady``).
///
/// Контракт удержания (E12.3): «палец остаётся в пределах допуска (<10 pt)
/// дольше порога (>600 мс), **считая от последнего заметного движения**».
/// Смещение от якоря на допуск или больше отменяет удержание (в том числе уже
/// выдержанное) и **переносит якорь в текущую точку с новым отсчётом** — палец,
/// дошедший до центра цели несколькими шагами, перевзводится там, где
/// остановился, а не ждёт возврата к первой точке входа в зону.
///
/// Время читается через замыкание ``now``, а не напрямую из системных часов:
/// тесты подменяют его управляемыми часами и проверяют порог без `sleep`.
/// В проде подставляется `CACurrentMediaTime()` — тот же монотонный отсчёт,
/// что у `CADisplayLink` и Core Animation, так что пауза приложения не
/// сдвигает таймер.
///
/// Переходы:
/// - ``beginHover(targetID:point:)``: новый ярлык —
///   `armed` с якорем в точке и отсчётом с текущего момента; повторный вызов
///   для того же ярлыка в `armed`/`fired` ничего не делает, чтобы покадровые
///   вызовы не перезапускали таймер;
/// - ``update(point:)``: смещение от якоря на допуск или больше — отмена и
///   перевзвод: `armed` с якорем в текущей точке и отсчётом с текущего момента
///   (E12.3, заменяет «cancelled до возврата к старому якорю» из E10.5-A3);
/// - ``timerFired()``: прошло строго больше порога (`>600 мс`, E9.8а) —
///   `fired`, иначе остаётся `armed` (таймер мог сработать чуть раньше из-за
///   округления runloop);
/// - ``reset()`` — `idle`.
///
/// Границы E8.6 строгие (E9.8а): смещение ровно на допуск отменяет удержание
/// (нужно «меньше 10 pt»), а порог времени должен быть превышен (нужно
/// «больше 600 мс»). Постоянно двигающийся палец (каждый шаг ≥10 pt) не
/// успевает выдержать порог — готовности нет; смена цели приходит через
/// ``beginHover(targetID:point:)`` или ``reset()``.
struct TesseraMergeHoverTracker {

    /// Состояние удержания.
    enum State: Equatable {

        /// Удержания нет.
        case idle

        /// Палец над ярлыком, отсчёт идёт.
        case armed

        /// Порог выдержан: drop создаст папку.
        case fired
    }

    /// Сколько времени нужно удерживать палец (``TesseraTileEditConfiguration/mergeHoverDuration``).
    private let hoverDuration: TimeInterval

    /// Допустимое смещение пальца от якоря в точках
    /// (``TesseraTileEditConfiguration/mergeHoverDisplacement``).
    ///
    /// E9.8а: радиус строгий — удержание живёт, пока смещение **меньше**
    /// допуска. Значение санитизируется: отрицательное/нечисловое — 0.
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
        self.hoverDuration = hoverDuration.isFinite ? max(0, hoverDuration) : 0
        self.displacementThreshold = displacementThreshold.isFinite
            ? max(0, displacementThreshold)
            : 0
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

    /// Проверяет смещение пальца от якоря и перевзводит удержание.
    ///
    /// Смещение на допуск или больше отменяет удержание и в `armed`, и в
    /// `fired` (подсветка «впитывания» обещает слияние только пока палец
    /// стоит) и сразу начинает новое: якорь переносится в текущую точку,
    /// отсчёт идёт с текущего момента, состояние — `armed` (E12.3). Так
    /// удержание считается от последнего заметного движения; возвращаться к
    /// старому якорю не нужно, а постоянно движущийся палец не накопит порог.
    ///
    /// - Parameter point: Текущая точка пальца в координатах сетки.
    /// - Returns: `true`, если удержание перевзведено (прежний отсчёт и
    ///   готовность недействительны — координатору нужно пересоздать таймер и,
    ///   если было `fired`, откатить подсветку).
    @discardableResult
    mutating func update(point: CGPoint) -> Bool {
        guard let anchor, state == .armed || state == .fired else { return false }

        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        // Сравнение квадратов: hypot/`sqrt` здесь не нужен, порог тоже в точках.
        let distanceSquared = dx * dx + dy * dy
        let thresholdSquared = displacementThreshold * displacementThreshold
        // E9.8а: допуск строгий (`<10 pt`); при нулевом допуске разрешена
        // только точка якоря.
        let isWithinTolerance = displacementThreshold > 0
            ? distanceSquared < thresholdSquared
            : distanceSquared == 0

        guard !isWithinTolerance else { return false }

        // E12.3: перенос якоря и новый отсчёт с текущей точки.
        self.anchor = point
        startedAt = now()
        state = .armed
        return true
    }

    /// Таймер удержания сработал.
    ///
    /// E9.8а: порог строгий — готовность наступает только после `>600 мс`; на
    /// ровно 600 мс удержание ещё не выдержано, координатор досчитает остаток.
    ///
    /// - Returns: `true`, если порог выдержан и состояние стало `fired`;
    ///   `false` — рано (состояние осталось `armed`) или отсчёт не идёт.
    @discardableResult
    mutating func timerFired() -> Bool {
        guard state == .armed, let startedAt else { return false }
        let elapsed = now() - startedAt
        let hasElapsed = hoverDuration == 0 ? elapsed >= 0 : elapsed > hoverDuration
        guard hasElapsed else { return false }

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
///
/// E14.5 (D21, D33): цель — **клетка сетки под пальцем**, а не слот порядка.
/// Над занятой клеткой решает зона: центр — слияние (`.group`/`.folder`, по
/// удержанию E8.6, D14), край — `.cell` с ячейкой элемента-цели (перетаскиваемый
/// встаёт на неё, цель выталкивается вниз каскадом, D31). Над пустой клеткой
/// цель — именно эта клетка; ниже последней занятой строки — «новая строка».
/// E9.5: drop в центр без выдержанного удержания — возврат на исходное место
/// (no-op).
enum HoverTarget: Equatable {

    /// Цели нет (вне сетки, над собственной базовой ячейкой, над панелью
    /// раскрытой папки, подъём ещё не сдвинулся с места). Превью — базовая
    /// раскладка, drop — no-op.
    case none

    /// Положить элемент на ячейку (логические координаты, без ограничения
    /// холстом: его делают `TileLayoutEngine.inserting` и операции
    /// `TileStore` по ячейкам). Для краевой зоны занятой клетки — ячейка
    /// элемента-цели в базовой раскладке; для пустой клетки — клетка под пальцем.
    case cell(TileGridPlacement)

    /// Новая строка в конце холста (палец ниже последней занятой строки).
    case newRow

    /// Центральная зона папки `id`: добавление ярлыка в папку по удержанию E8.6
    /// (D14). Без удержания drop — no-op (E9.5).
    case folder(AnyHashable)

    /// Создание папки из ярлыка `id` (drop на его центр). Без удержания E8.6
    /// drop — no-op (E9.5).
    case group(AnyHashable)

    /// Центр папки-источника при drag ярлыка из неё (E11.1): цели нет, drop
    /// возвращает ярлык в папку, модель не меняется.
    case sourceFolder

    /// Идентификатор цели удержания E8.6, если цель его поддерживает.
    ///
    /// Удержание взводится и для центра ярлыка (создание папки), и для центра
    /// плитки-папки (добавление в папку): это одна и та же машина
    /// ``TesseraMergeHoverTracker``.
    var mergeTargetID: AnyHashable? {
        switch self {
        case .folder(let itemID), .group(let itemID):
            return itemID
        case .none, .cell, .newRow, .sourceFolder:
            return nil
        }
    }

    /// Стиль подсветки цели до готовности к слиянию (E8.6).
    var baseHighlightStyle: TesseraTileDropHighlightView.Style? {
        switch self {
        case .folder:
            return .folder
        case .group:
            return .group
        case .none, .cell, .newRow, .sourceFolder:
            return nil
        }
    }
}

/// Итоговая картина распада папки-источника при drag ярлыка из панели (D45).
///
/// В папке два ярлыка: когда выносимый уходит, папка распускается, и оставшийся
/// встаёт на её ячейку со своим размером. Превью цели-размещения показывает именно
/// это, поэтому набор считается один раз на захвате — от размещений модели, а не
/// от предыдущего превью.
struct DragFolderDissolution {

    /// Папка, которая распадётся.
    let folderID: AnyHashable

    /// Оставшийся ярлык, занимающий место папки.
    let remaining: TileDescriptor

    /// Элементы сетки после распада: папка заменена оставшимся ярлыком; выносимый
    /// ярлык (синтетический элемент базы) остаётся на месте.
    let items: [TileGridItem]

    /// Размещения модели **без** выносимого ярлыка: папка убрана, оставшийся
    /// ярлык поставлен на её ячейку `TileLayoutEngine.inserting` (бо́льший
    /// выталкивает соседей вниз). От них считаются превью и «новая строка».
    let placements: [TilePlacedItem]
}

/// Активная drag-сессия.
///
/// Класс, а не структура: координатор и таймер меняют `lastPoint`/`hover`
/// из разных мест, и копии значения разъехались бы.
final class TesseraTileDragSession {

    /// Идентификатор перетаскиваемого элемента.
    let itemID: AnyHashable

    /// Ярлык ли это (папку нельзя бросить в папку — вложенности нет).
    let isTile: Bool

    /// Папка-источник, если ярлык взят из панели раскрытой папки (E11.1).
    ///
    /// `nil` — обычный drag элемента сетки. Для drag из папки ``itemID`` — это
    /// ярлык, которого нет среди элементов модели на сетке: в ``baseSnapshot``
    /// он вставлен синтетическим элементом сразу после папки, а модель не
    /// меняется до drop.
    let sourceFolderID: AnyHashable?

    /// Реальный снимок модели на момент захвата (E11.1).
    ///
    /// Совпадает с ``baseSnapshot`` для обычного drag; для drag из папки —
    /// без синтетического ярлыка. По нему ``TesseraTileEditCoordinator``
    /// проверяет, что модель не менялась извне.
    let modelBaseSnapshot: TileGridSnapshot

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

    /// Палец сместился от точки захвата больше чем на
    /// ``TesseraTileEditCoordinator/emptySlotActivationDistance`` (E12.1).
    ///
    /// До этого над пустым местом превью не трогается: при подъёме ярлыка из
    /// панели палец стоит там, где была иконка, и пустышка не должна «убегать»
    /// из-под него в тот же кадр. Взводится один раз за сессию.
    var hasMovedFromOrigin = false

    /// Снимок модели на момент захвата (E8.4, E14.5): элементы и таблица ячеек.
    ///
    /// База для превью раскладки (``basePlacements``) и для проверки
    /// «модель не менялась извне» (E10.5-B1): собственных мутаций за время drag
    /// нет, но внешний писатель (хост, экран папки) может изменить модель —
    /// тогда сессия безопасно отменяется. Заодно хранит `unpinned` —
    /// превью-снимки сетки обязаны сохранять список ярлыков вне стола, иначе
    /// `update` сбросил бы его.
    let baseSnapshot: TileGridSnapshot

    /// Снимок, который координатор последним попросил показать сетке (E10.5-B1).
    ///
    /// На захвате равен ``baseSnapshot``, затем обновляется каждым применённым
    /// превью. Сетка обязана показывать либо его, либо базу: расхождение состава
    /// и размеров означает внешний `grid.update` в обход координатора.
    var expectedSnapshot: TileGridSnapshot

    /// Превью, которое координатор попросил показать, но сетка отложила
    /// (переход панели папки, E10.2). Становится ``expectedSnapshot``, когда
    /// сетка его применит.
    var pendingSnapshot: TileGridSnapshot?

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

    /// Кэш базовых рамок хит-теста в координатах контента (E11.7).
    ///
    /// Строится лениво и сбрасывается при смене ключа геометрии сетки.
    var baseFrames: (key: TesseraTileGridView.BaseFramesKey, frames: [AnyHashable: CGRect])?

    /// Менялась ли модель за время drag (нужно для единственного сохранения).
    ///
    /// E8.4: во время drag всегда `false`; выставляется только на drop.
    var modelChanged = false

    /// Число колонок сетки на момент захвата (E14.5).
    ///
    /// Ячейки считаются на холсте этой ширины; смена колонок сетки посреди drag
    /// отменяет сессию (``TesseraTileEditCoordinator``).
    let columns: Int

    /// Базовые размещения верхнеуровневых элементов на момент захвата (E14.5).
    ///
    /// Порядок — как в ``baseSnapshot``. Хит-тест и превью всегда считаются от
    /// них, а не от предыдущего превью: сдвиги не накапливаются. Для drag из
    /// панели папки сюда входит синтетический ярлык на стартовой свободной ячейке.
    let basePlacements: [TilePlacedItem]

    /// Размещения, которые сетка показывает сейчас (E14.5): базовые либо
    /// результат `TileLayoutEngine.inserting` для текущей цели. Нужны, чтобы не
    /// посылать сетке одинаковое превью повторно.
    var previewPlacements: [TilePlacedItem]

    /// Ячейки модели на момент захвата (E14.5).
    ///
    /// Нужны проверке «модель не менялась извне»: для drag из папки в
    /// ``basePlacements`` есть синтетический ярлык, а в модели его нет.
    let modelPlacements: [AnyHashable: TileGridPlacement]

    /// Итоговая картина распада папки-источника (D45): в ней два ярлыка, и
    /// после выноса одного она распускается. `nil` — папка переживёт вынос,
    /// drag не из папки либо в папке один ярлык (``dissolvingFolderID``).
    let folderDissolution: DragFolderDissolution?

    /// Папка-источник, которая исчезнет на drop (E14.5): ярлык в ней последний.
    ///
    /// `TileStore` убирает такую папку **до** расчёта новой строки, поэтому
    /// превью и магнит для цели «новая строка» её тоже не учитывают. D45: такая
    /// папка бывает только переходной (``TileStore/createFolder(withTile:title:columns:)``);
    /// распад папки из двух ярлыков — ``folderDissolution``.
    var dissolvingFolderID: AnyHashable? {
        guard let sourceFolderID,
              let folder = modelBaseSnapshot.folders.first(where: { $0.id == sourceFolderID }),
              folder.tiles.count == 1 else {
            return nil
        }
        return sourceFolderID
    }

    /// Ячейка цели «новая строка» для перетаскиваемого элемента (E14.5): первая
    /// строка после последней занятой, колонка 0 — как её посчитает `TileStore`
    /// (без самого элемента и без исчезающей папки-источника).
    var newRowCell: TileGridPlacement {
        // D45: после распада папки строки считаются с оставшимся ярлыком на её
        // месте, так же, как в `TileStore.extractFromFolderToNewRow`.
        TileLayoutEngine.newRowCell(
            size: magnetSize,
            columns: columns,
            placements: folderDissolution?.placements
                ?? basePlacements.filter { $0.id != dissolvingFolderID },
            excluding: itemID
        )
    }

    init(
        itemID: AnyHashable,
        isTile: Bool,
        grabOffset: CGPoint,
        dragView: UIView,
        placeholder: UIView,
        lastPoint: CGPoint,
        baseSnapshot: TileGridSnapshot,
        magnetSize: TileSize,
        columns: Int,
        basePlacements: [TilePlacedItem],
        modelPlacements: [AnyHashable: TileGridPlacement],
        modelBaseSnapshot: TileGridSnapshot? = nil,
        sourceFolderID: AnyHashable? = nil,
        folderDissolution: DragFolderDissolution? = nil
    ) {
        self.folderDissolution = folderDissolution
        self.modelBaseSnapshot = modelBaseSnapshot ?? baseSnapshot
        self.sourceFolderID = sourceFolderID
        self.itemID = itemID
        self.columns = columns
        self.basePlacements = basePlacements
        self.previewPlacements = basePlacements
        self.modelPlacements = modelPlacements
        self.isTile = isTile
        self.grabOffset = grabOffset
        self.dragView = dragView
        self.placeholder = placeholder
        self.lastPoint = lastPoint
        self.originPoint = lastPoint
        self.baseSnapshot = baseSnapshot
        self.expectedSnapshot = baseSnapshot
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

/// Обрезающий контейнер кнопок редактирования (E12.4).
///
/// Совпадает с `bounds` сетки и обрезает кнопки (`clipsToBounds`) по той же
/// границе, по которой коллекция обрезает сами плитки: кнопка плитки, ушедшей
/// под край (например, под status bar), не рисуется поверх соседнего UI.
/// Сам контейнер касания не перехватывает.
final class TesseraTileEditControlsHostView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Пропускает касания мимо контейнера, если они не попали в кнопку.
    ///
    /// Если зоны касания нескольких оверлеев накладываются, побеждает кнопка,
    /// **центр которой ближе к точке**; при равенстве — верхняя в порядке
    /// подвью. Наложения бывают у соседей: стрелка размера верхней плитки и
    /// кнопка открепления плитки под ней стоят в одной колонке у конца строки
    /// (E15.2), а кнопки ярлыков панели папки (D46) стоят вплотную. Внутри одного
    /// оверлея зоны двух его кнопок не пересекаются
    /// (``TesseraTileEditControlView/gridHitZone(buttonFrame:tileBounds:isRightToLeft:ownsUpperHalf:)``).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled,
              self.point(inside: point, with: event) else {
            return nil
        }

        var claims: [(control: TesseraTileEditControlView, view: UIView)] = []
        for subview in subviews.reversed() {
            guard let control = subview as? TesseraTileEditControlView else { continue }
            let local = control.convert(point, from: self)
            if let hit = control.hitTest(local, with: event) {
                claims.append((control, hit))
            }
        }
        guard claims.count > 1 else {
            return claims.first?.view
        }

        // Расстояние — от точки до центра заявленной кнопки (в координатах её оверлея).
        func distance(_ claim: (control: TesseraTileEditControlView, view: UIView)) -> CGFloat {
            let local = claim.control.convert(point, from: self)
            return hypot(local.x - claim.view.frame.midX, local.y - claim.view.frame.midY)
        }
        var best = claims[0]
        var bestDistance = distance(best)
        for claim in claims.dropFirst() {
            let candidate = distance(claim)
            if candidate < bestDistance {
                best = claim
                bestDistance = candidate
            }
        }
        return best.view
    }
}

/// Оверлей кнопок «открепить» и «размер» поверх плитки.
///
/// Занимает рамку плитки, чтобы кнопки и «желе» вращались вокруг её центра, но
/// перехватывает касания только в самих кнопках: тап по остальной площади
/// проходит к коллекции (и дальше к хосту).
///
/// E12.5 (в духе Windows 10 Mobile): кнопки компактные, диаметр масштабируется
/// по размеру плитки (``diameter(forTileSize:maxDiameter:)``) и они сидят на
/// углах, чуть выступая за рамку (``cornerOverhang``), чтобы закрывать как
/// можно меньше содержимого. Выступ ограничен 4 pt (D48): зазор между плитками
/// сетки по умолчанию 8 pt, так что кнопка не заходит на соседнюю плитку, а у
/// крайних плиток остаётся в полях (≥ 16 pt). Выступ в половину зазора нужен
/// ещё и друг к другу: стрелка верхней плитки и открепление нижней стоят в одной
/// колонке, их круги (4 + 4 pt) в зазор 8 pt ровно касаются и не перекрываются.
/// Светлая заливка с тёмным символом, тонкое
/// кольцо и тень читаются на плитках любого цвета в светлой и тёмной темах.
/// Видимая кнопка может быть мелкой, а зона касания расширяется до
/// ``minimumHitSide`` (`hitTest`).
///
/// E15.2 (D29): обе кнопки плитки сетки стоят у конца строки — открепление в
/// верхнем углу, стрелка размера в нижнем, — и на малой плитке их зоны касания
/// делятся по половинам высоты
/// (``gridHitZone(buttonFrame:tileBounds:isRightToLeft:ownsUpperHalf:)``).
final class TesseraTileEditControlView: UIView {

    /// Нажатие на кнопку открепления.
    var onUnpin: (() -> Void)?

    /// Нажатие на стрелку размера.
    var onResize: (() -> Void)?

    /// Наименьшая сторона зоны касания кнопки (HIG), pt.
    static let minimumHitSide: CGFloat = 44

    /// Наименьший диаметр видимой кнопки, pt.
    static let minimumDiameter: CGFloat = 20

    /// Доля меньшей стороны плитки, из которой считается диаметр.
    static let diameterFraction: CGFloat = 0.24

    /// Выступ кнопки за рамку плитки по каждой оси, pt (D48).
    ///
    /// 4 pt = половина зазора сетки по умолчанию (8 pt): круги кнопок соседних
    /// плиток одной колонки (стрелка верхней и открепление нижней) касаются, но
    /// не перекрываются. От этого значения зависят рамки кнопок, зоны касания,
    /// обход бэйджа (``badgeClearance(forTileSize:maxDiameter:)``) и зона кнопки
    /// ярлыка панели (``panelHitOutset``) — отдельных констант нет.
    static let cornerOverhang: CGFloat = 4

    /// Диаметр видимой кнопки для плитки заданного размера.
    ///
    /// - Parameters:
    ///   - tileSize: Размер плитки.
    ///   - maxDiameter: Потолок из ``TesseraTileEditConfiguration/controlDiameter``.
    /// - Returns: Диаметр от 20 pt до потолка (потолок ниже 20 pt поднимается до 20).
    static func diameter(forTileSize tileSize: CGSize, maxDiameter: CGFloat) -> CGFloat {
        let ceiling = max(minimumDiameter, maxDiameter)
        let scaled = (min(tileSize.width, tileSize.height) * diameterFraction).rounded()
        return min(ceiling, max(minimumDiameter, scaled))
    }

    /// Рамка кнопки открепления в верхнем углу плитки (D29, D46, E15.2).
    ///
    /// **Единственное место, где выбирается угол кнопки открепления.** Сетка и
    /// панель папки строят кнопку этим помощником, поэтому угол у них общий.
    /// Кнопка — в верхнем углу **у конца строки** (правом в LTR, левом в RTL, как
    /// в W10M), центр у самого угла рамки, чуть наружу (``cornerOverhang``).
    /// Стрелка размера сидит в нижнем углу той же стороны
    /// (``resizeButtonFrame(inTileBounds:side:isRightToLeft:)``): обе кнопки
    /// одного плиточного оверлея стоят друг над другом.
    ///
    /// - Parameters:
    ///   - bounds: Границы плитки (начало координат оверлея).
    ///   - side: Диаметр кнопки.
    ///   - isRightToLeft: Направление чтения.
    /// - Returns: Рамка кнопки в координатах оверлея.
    static func unpinButtonFrame(
        inTileBounds bounds: CGRect,
        side: CGFloat,
        isRightToLeft: Bool
    ) -> CGRect {
        let overhang = cornerOverhang
        let x = isRightToLeft ? -overhang : bounds.width - side + overhang
        return CGRect(x: x, y: -overhang, width: side, height: side)
    }

    /// Рамка стрелки размера в нижнем углу плитки у конца строки (D29, E15.2).
    ///
    /// Правый нижний угол в LTR, левый нижний в RTL; центр у самого угла рамки,
    /// чуть наружу (``cornerOverhang``). Тот же помощник использует раскладка
    /// бэйджа плитки, чтобы обойти кнопку (``badgeClearance(forTileSize:maxDiameter:)``).
    ///
    /// - Parameters:
    ///   - bounds: Границы плитки (начало координат оверлея).
    ///   - side: Диаметр кнопки.
    ///   - isRightToLeft: Направление чтения.
    /// - Returns: Рамка кнопки в координатах оверлея.
    static func resizeButtonFrame(
        inTileBounds bounds: CGRect,
        side: CGFloat,
        isRightToLeft: Bool
    ) -> CGRect {
        let overhang = cornerOverhang
        let x = isRightToLeft ? -overhang : bounds.width - side + overhang
        return CGRect(x: x, y: bounds.height - side + overhang, width: side, height: side)
    }

    /// Сколько нижнего угла плитки со стороны конца строки занимает стрелка
    /// размера **внутри** плитки, pt (E15.1).
    ///
    /// Это отступ, на который бэйдж в правке уходит от края: у стрелки диаметра
    /// `side` внутрь плитки заходит `side − cornerOverhang` по каждой оси.
    ///
    /// - Parameters:
    ///   - tileSize: Размер плитки.
    ///   - maxDiameter: Потолок из ``TesseraTileEditConfiguration/controlDiameter``.
    /// - Returns: Ширина занятого угла внутри плитки.
    static func badgeClearance(forTileSize tileSize: CGSize, maxDiameter: CGFloat) -> CGFloat {
        max(0, diameter(forTileSize: tileSize, maxDiameter: maxDiameter) - cornerOverhang)
    }

    /// Зона касания кнопки плитки **сетки** (E15.2).
    ///
    /// Обе кнопки плитки стоят у конца строки одна над другой, и на малой плитке
    /// (≈ 50–55 pt) их зоны 44 × 44 pt пересеклись бы. Правило детерминировано и
    /// не отдаёт кнопкам центр плитки:
    /// 1. зона — видимая рамка кнопки, расширенная до ``minimumHitSide`` вокруг
    ///    её центра;
    /// 2. **вертикаль**: кнопка открепления владеет **верхней половиной** высоты
    ///    плитки (зона не заходит ниже её середины), стрелка размера — **нижней**
    ///    (не заходит выше середины): зоны двух кнопок никогда не пересекаются;
    /// 3. **горизонталь**: зона не заходит за вертикальную ось плитки (минус 1 pt)
    ///    со стороны конца строки, поэтому центр и тело плитки (тап, long-press,
    ///    drag) принадлежат плитке. У плитки шире ≈ 52 pt п. 3 ничего не обрезает.
    ///
    /// - Parameters:
    ///   - buttonFrame: Видимая рамка кнопки в координатах оверлея.
    ///   - tileBounds: Границы плитки (начало координат оверлея).
    ///   - isRightToLeft: Направление чтения.
    ///   - ownsUpperHalf: `true` — кнопка открепления (верхняя половина),
    ///     `false` — стрелка размера (нижняя).
    /// - Returns: Зона касания (нулевая, если она вырождена).
    static func gridHitZone(
        buttonFrame: CGRect,
        tileBounds: CGRect,
        isRightToLeft: Bool,
        ownsUpperHalf: Bool
    ) -> CGRect {
        let dx = max(0, (minimumHitSide - buttonFrame.width) / 2)
        let dy = max(0, (minimumHitSide - buttonFrame.height) / 2)
        var zone = buttonFrame.insetBy(dx: -dx, dy: -dy)

        let midX = tileBounds.midX
        let midY = tileBounds.midY
        var minX = zone.minX
        var maxX = zone.maxX
        var minY = zone.minY
        var maxY = zone.maxY
        if isRightToLeft {
            maxX = min(maxX, midX - 1)
        } else {
            minX = max(minX, midX + 1)
        }
        if ownsUpperHalf {
            maxY = min(maxY, midY)
        } else {
            minY = max(minY, midY)
        }
        zone = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return zone.width <= 0 || zone.height <= 0 ? .zero : zone
    }

    /// Зона касания кнопки открепления ярлыка панели папки (D46, E15.2).
    ///
    /// Правило детерминировано и ничего не отнимает у ярлыка и соседей:
    /// 1. допустимая область — **угловая четверть** ярлыка, где сидит кнопка
    ///    (верхняя у конца строки: правая в LTR, левая в RTL), плюс выступ
    ///    наружу не больше `outset` (кнопка не заходит на соседа); за осями
    ///    симметрии ярлыка (минус 1 pt) зоны нет, поэтому центр и остальное тело
    ///    ярлыка принадлежат самому ярлыку (тап — ничего нового, long-press —
    ///    drag из папки);
    /// 2. внутри этой области зона — квадрат не меньше 44 × 44 pt (HIG), прижатый
    ///    к внешнему углу и растущий внутрь ярлыка, но не дальше осей: у малого
    ///    ярлыка (≈ 55 pt) это ≈ 32 pt, у крупного — полные 44 pt. Видимая
    ///    кнопка всегда внутри зоны.
    ///
    /// - Parameters:
    ///   - buttonFrame: Видимая рамка кнопки в координатах оверлея.
    ///   - tileBounds: Границы ярлыка (начало координат оверлея).
    ///   - isRightToLeft: Направление чтения: в RTL четверть левая.
    ///   - outset: Допустимый выход зоны за рамку ярлыка.
    /// - Returns: Зона касания (нулевая, если она вырождена).
    static func panelUnpinHitZone(
        buttonFrame: CGRect,
        tileBounds: CGRect,
        isRightToLeft: Bool,
        outset: CGFloat
    ) -> CGRect {
        let clip = max(0, outset)
        let quadrantWidth = max(0, tileBounds.width / 2 - 1) + clip
        let quadrantHeight = max(0, tileBounds.height / 2 - 1) + clip
        let quadrant = CGRect(
            x: isRightToLeft ? tileBounds.minX - clip : tileBounds.midX + 1,
            y: tileBounds.minY - clip,
            width: quadrantWidth,
            height: quadrantHeight
        )

        let width = min(quadrant.width, max(minimumHitSide, buttonFrame.width))
        let height = min(quadrant.height, max(minimumHitSide, buttonFrame.height))
        let zone = CGRect(
            x: isRightToLeft ? quadrant.minX : quadrant.maxX - width,
            y: quadrant.minY,
            width: width,
            height: height
        )
        return zone.isNull || zone.width <= 0 || zone.height <= 0 ? .zero : zone
    }

    /// SF Symbol кнопки «открепить» (E8.3).
    ///
    /// Выбрана перечёркнутая булавка, а не крестик: действие — не удаление, а
    /// открепление с рабочего стола (ярлык остаётся в списке приложений).
    /// `pin.slash` — канонический символ «открепить»; простая `pin` обозначает
    /// состояние «закреплено» и читалась бы как обратное действие. Символ
    /// доступен с iOS 13, то есть входит в целевой iOS 15.
    private static let unpinSymbolName = "pin.slash"

    /// Заливка кнопки: светлая в обеих темах (контраст с тёмными и цветными
    /// плитками), в тёмной чуть приглушена, чтобы не «светить».
    private static let fillColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.92, alpha: 1)
            : UIColor(white: 1, alpha: 1)
    }

    /// Символ кнопки: тёмный на светлой заливке.
    private static let glyphColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.08, alpha: 1)
            : UIColor(white: 0.12, alpha: 1)
    }

    /// Тонкое кольцо: отделяет светлую заливку от светлых плиток.
    static let ringColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0, alpha: 0.6)
            : UIColor(white: 0, alpha: 0.35)
    }

    private let unpinButton = UIButton(type: .system)
    private let resizeButton = UIButton(type: .system)

    /// Потолок диаметра из конфигурации.
    let diameter: CGFloat

    /// Размер плитки: от него зависит фактический диаметр кнопок.
    ///
    /// Обновляется координатором вместе с `frame`; смена размера плитки
    /// (resize) перестраивает кнопки на следующем layout.
    var tileSize: CGSize = .zero {
        didSet {
            guard tileSize != oldValue else { return }
            setNeedsLayout()
        }
    }

    private var showsUnpin = true
    private var showsResize = true

    /// Оверлей ярлыка панели раскрытой папки, а не плитки сетки (D46).
    ///
    /// У такого оверлея только кнопка открепления, а её зона касания урезана
    /// (``panelUnpinHitZone(buttonFrame:tileBounds:isRightToLeft:outset:)``),
    /// чтобы не отнимать тапы у самого ярлыка и соседей. Раскладка кнопки и её
    /// размер — те же, что на сетке (``unpinButtonFrame(inTileBounds:side:isRightToLeft:)``).
    var isPanelMember = false

    /// Насколько зона касания кнопки ярлыка панели может выйти за рамку ярлыка
    /// (D46): не больше выступа кнопки и не больше зазора между ярлыками.
    var panelHitOutset: CGFloat = TesseraTileEditControlView.cornerOverhang

    /// Создаёт оверлей.
    ///
    /// - Parameter diameter: Наибольший диаметр кнопок в точках.
    init(diameter: CGFloat) {
        self.diameter = max(TesseraTileEditControlView.minimumDiameter, diameter)
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

    /// Видимая рамка кнопки открепления в координатах оверлея.
    var unpinButtonFrame: CGRect { unpinButton.frame }

    /// Видимая рамка кнопки размера в координатах оверлея.
    var resizeButtonFrame: CGRect { resizeButton.frame }

    /// Зона касания кнопки открепления (не меньше 44 × 44 pt).
    var unpinHitFrame: CGRect { hitFrame(for: unpinButton) }

    /// Зона касания кнопки размера (не меньше 44 × 44 pt).
    var resizeHitFrame: CGRect { hitFrame(for: resizeButton) }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard bounds.width > 0, bounds.height > 0 else { return }

        let side = TesseraTileEditControlView.diameter(
            forTileSize: bounds.size,
            maxDiameter: diameter
        )
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft

        // Обе кнопки — у конца строки (правый край в LTR, левый в RTL, как в
        // W10M): открепление сверху, стрелка размера снизу (D29, E15.2). Центр
        // кнопки лежит у самого угла рамки, чуть наружу: половина диаметра
        // остаётся над плиткой. Углы выбирают общие помощники — открепление
        // ими же пользуется панель папки.
        unpinButton.frame = TesseraTileEditControlView.unpinButtonFrame(
            inTileBounds: bounds,
            side: side,
            isRightToLeft: isRightToLeft
        )
        resizeButton.frame = TesseraTileEditControlView.resizeButtonFrame(
            inTileBounds: bounds,
            side: side,
            isRightToLeft: isRightToLeft
        )
        for button in [unpinButton, resizeButton] {
            button.layer.cornerRadius = side / 2
            button.layer.shadowPath = UIBezierPath(
                ovalIn: button.bounds
            ).cgPath
        }
        updateColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    /// Зона касания кнопки.
    ///
    /// Плитка сетки: видимая рамка, расширенная до 44 pt вокруг центра и
    /// разделённая между кнопками по половинам плитки
    /// (``gridHitZone(buttonFrame:tileBounds:isRightToLeft:ownsUpperHalf:)``).
    /// Для кнопки открепления ярлыка панели (D46) зона урезана до угловой
    /// четверти ярлыка (``panelUnpinHitZone(buttonFrame:tileBounds:isRightToLeft:outset:)``).
    private func hitFrame(for button: UIButton) -> CGRect {
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        if isPanelMember, button === unpinButton {
            return TesseraTileEditControlView.panelUnpinHitZone(
                buttonFrame: button.frame,
                tileBounds: bounds,
                isRightToLeft: isRightToLeft,
                outset: panelHitOutset
            )
        }
        return TesseraTileEditControlView.gridHitZone(
            buttonFrame: button.frame,
            tileBounds: bounds,
            isRightToLeft: isRightToLeft,
            ownsUpperHalf: button === unpinButton
        )
    }

    /// Кнопка, в зону касания которой попадает точка (координаты оверлея).
    private func button(at point: CGPoint) -> UIButton? {
        for button in [resizeButton, unpinButton]
        where !button.isHidden && hitFrame(for: button).contains(point) {
            return button
        }
        return nil
    }

    /// Кнопки могут выступать за рамку плитки, а зона касания шире видимой
    /// кнопки, поэтому попадание считается по зонам касания, а не по `bounds`.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        button(at: point) != nil
    }

    /// Пропускает касания мимо оверлея, если они не попали в зону кнопки.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
        return button(at: point)
    }

    /// Применяет динамические цвета (слой не знает о смене темы сам).
    private func updateColors() {
        for button in [unpinButton, resizeButton] {
            button.tintColor = TesseraTileEditControlView.glyphColor
            button.backgroundColor = TesseraTileEditControlView.fillColor
            button.layer.borderColor = TesseraTileEditControlView.ringColor
                .resolvedColor(with: traitCollection).cgColor
        }
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
            UIImage.SymbolConfiguration(pointSize: 10, weight: .bold),
            forImageIn: .normal
        )
        button.layer.cornerRadius = diameter / 2
        button.layer.borderWidth = 1
        // Тень не обрезается: `clipsToBounds` выключен, скругление даёт фон.
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.35
        button.layer.shadowRadius = 2
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
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

        /// Ярлык: удержание ещё не выдержано, drop — no-op (E9.5).
        case group

        /// Центр ярлыка: удержание выдержано, drop создаст папку (E8.6).
        ///
        /// Тот же акцент, что у `.group` (оранжевый), но рамка толще и заливка
        /// плотнее, а координатор дополнительно увеличивает вид до
        /// ``TesseraTileEditConfiguration/mergeHighlightScale``. Состояние
        /// читается и без анимации: при Reduce Motion меняются только рамка и
        /// масштаб.
        case merge

        /// Центральная зона папки: удержание выдержано, drop добавит ярлык в
        /// папку (E8.6, D14).
        ///
        /// Сохраняет опорный акцент папки (синий), а не перекрашивается в
        /// оранжевый: «впитывание» — усиление той же цели, а не другая цель;
        /// отличаются толщина рамки и плотность заливки.
        case mergeFolder
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
    /// Пара «опорный стиль → состояние впитывания» держит один и тот же акцент
    /// (`.group → .merge` — оранжевый, `.folder → .mergeFolder` — синий):
    /// «впитывание» должно читаться как усиление той же цели, а не как другая
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
        case .mergeFolder:
            color = .systemBlue
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
/// - тап по ярлыку закрывает папку и отдаёт событие хосту через
///   ``TesseraTileGridView/onTap`` (D12; E10.5-C3) — прямого вызова
///   `TileDescriptor.action` нет: событие обрабатывается один раз и тем же
///   маршрутом, что тап по плитке сетки;
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

        closeButton.setTitle(TesseraStartScreenStrings.string(.folderScreenDone), for: .normal)
        closeButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityLabel = TesseraStartScreenStrings.string(.folderScreenClose)

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

        titleLabel.text = folder.title.isEmpty ? TesseraStartScreenStrings.string(.folderScreenDefaultTitle) : folder.title
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
            UIAccessibilityCustomAction(name: TesseraStartScreenStrings.string(.folderScreenMoveAction), image: nil) { [weak self, weak tileView] _ in
                guard let self, let tileView, let tile = tileView.tile else { return false }
                self.presentMoveMenu(for: tile, sourceView: tileView)
                return true
            }
        ]
        return tileView
    }

    /// Тап по ярлыку: закрыть папку, затем активировать событие общим маршрутом.
    ///
    /// E10.5-C3/m4: действие ярлыка выполняет хост по
    /// ``TesseraTileGridView/onTap`` (D12), а не экран папки. Активация — в
    /// completion закрытия sheet, как раньше было с `action`: иначе событие
    /// хоста приходит до того, как экран папки начал уходить, и навигация
    /// хоста конфликтует с dismiss-анимацией. В режиме редактирования
    /// активации нет.
    ///
    /// - Parameter sender: Плитка содержимого.
    @objc private func tileTapped(_ sender: TesseraFolderTileView) {
        guard let tile = sender.tile else { return }
        dismiss(animated: !reduceMotion) { [weak self] in
            self?.performActivation(tile)
        }
    }

    /// Активирует ярлык после закрытия экрана папки (m4).
    ///
    /// Основной путь — общий `grid.onTap` через координатор (в edit-режиме
    /// координатор активацию не выполняет). Fallback: если координатора/сетки
    /// уже нет (экран пережил владельца), действие ярлыка выполняется напрямую,
    /// как было до E10.5-C3, чтобы тап не «потерялся».
    ///
    /// - Parameter tile: Ярлык содержимого папки.
    func performActivation(_ tile: TileDescriptor) {
        if let coordinator {
            coordinator.activateTileFromFolder(tile)
            return
        }
        tile.action()
    }

    /// Передаёт тап по ярлыку координатору (общий маршрут `onTap`).
    ///
    /// Внутренний шов: контракт «экран папки не вызывает `action` напрямую»
    /// проверяется тестом без реальной презентации sheet.
    ///
    /// - Parameter tile: Ярлык содержимого папки.
    /// - Returns: `true`, если координатор передал событие хосту.
    @discardableResult
    func activateTile(_ tile: TileDescriptor) -> Bool {
        coordinator?.activateTileFromFolder(tile) ?? false
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
            title: String(
                format: TesseraStartScreenStrings.string(.folderScreenMoveMenuTitleFormat),
                tile.title
            ),
            message: nil,
            preferredStyle: .actionSheet
        )

        let otherFolders = store.snapshot().folders.filter { $0.id != folderID }
        for folder in otherFolders {
            let name = folder.title.isEmpty ? TesseraStartScreenStrings.string(.folderScreenDefaultTitle) : folder.title
            let title = String(
                format: TesseraStartScreenStrings.string(.folderScreenMoveMenuIntoFormat),
                name
            )
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.move(tileID: tile.id, to: folder.id)
            })
        }

        alert.addAction(UIAlertAction(title: TesseraStartScreenStrings.string(.folderScreenMoveMenuToStart), style: .default) { [weak self] _ in
            self?.move(tileID: tile.id, to: nil)
        })
        alert.addAction(UIAlertAction(title: TesseraStartScreenStrings.string(.commonCancel), style: .cancel, handler: nil))

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
    /// Правила словоформ и сами формы — в ``TesseraStartScreenStrings``: у
    /// русского языка три формы, у английского две (E9.8г).
    ///
    /// - Parameter count: Число ярлыков.
    /// - Returns: Строка вида «3 ярлыка» / "3 shortcuts".
    private static func tilesText(_ count: Int) -> String {
        TesseraStartScreenStrings.folderTilesCountText(count)
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
