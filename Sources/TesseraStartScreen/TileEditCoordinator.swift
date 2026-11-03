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
//  E8.9: магнитизм к ячейкам. Под перетаскиваемой плиткой строится виртуальная
//  сетка слотов той же размерности (`TesseraTileGridView.magnetSlotCenters(for:)`),
//  а выбор ближайшего слота делает чистая функция
//  `TesseraTileMagnet.magnetTarget(for:slotCenters:snapRadius:)`. Точка отсчёта —
//  **центр снимка** (`point + grabOffset`), а не палец (E10.5-A2): иначе плитка,
//  взятая не за центр, «прыгала» к слоту до половины плитки. Стартовая зона,
//  особые цели (папка/центр ярлыка) и над панелью притяжение отключено; при
//  Reduce Motion — целиком. Цели E8.4 и таймер E8.6 по-прежнему считаются по
//  точке пальца, поэтому магнит не меняет порядок и слияние.
//
//  E10.5 (W4, 02.11.2026) — цели и геометрия drag:
//  - A1: у плитки-папки есть краевые зоны перестановки: левая/правая половина
//    (вне центральной зоны) — `.reorder` с базовым индексом папки, центральная
//    зона — add-to-folder по удержанию E8.6 (D14). Папка-источник не таскается
//    в папку (`session.isTile`).
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
//    когда ячейка-фокус уже существует.
//  - C1: drop и публичный `move` идут через `TileStore.moveItem(_:toIndex:columns:)`;
//    делегат получает фактический (зажатый/канонизированный) индекс, сетка
//    синхронизируется со снимком store.
//  - C2: после unpin и папочных операций вызывается
//    `TileStore.canonicalizeVisibleOrder(columns:)`.
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

    /// Ярлык перемещён между папками или на рабочий стол с позицией (E11.1).
    ///
    /// Именно этот вариант координатор вызывает при перемещении ярлыка (из
    /// drag-жеста, из ``TesseraTileEditCoordinator/moveBetweenFolders(_:to:at:)``
    /// и из прежнего двухаргументного метода) — **ровно один раз за операцию**.
    /// Реализация по умолчанию пересылает событие прежнему
    /// ``tileEditCoordinator(_:didMove:toFolder:)``, поэтому делегат, который
    /// знает только его, продолжает работать; делегат, которому нужна позиция,
    /// реализует этот метод (тогда прежний не вызывается).
    ///
    /// - Parameters:
    ///   - coordinator: Координатор-источник события.
    ///   - tileID: Идентификатор ярлыка.
    ///   - folderID: Папка-цель; `nil` — ярлык вынесен на рабочий стол.
    ///   - index: Фактический индекс ярлыка в порядке сетки после
    ///     канонизации (когда `folderID == nil`); `nil` — при переносе в папку.
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didMove tileID: AnyHashable,
        toFolder folderID: AnyHashable?,
        atIndex index: Int?
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

    /// E11.1: по умолчанию — пересылка в прежний колбэк без индекса, чтобы
    /// существующие делегаты не потеряли событие.
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didMove tileID: AnyHashable,
        toFolder folderID: AnyHashable?,
        atIndex index: Int?
    ) {
        tileEditCoordinator(coordinator, didMove: tileID, toFolder: folderID)
    }

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
///   фиксируется одним `TileStore.moveItem(_:toIndex:columns:)`; автопрокрутка
///   у краёв; при подходе
///   пальца к центру слота той же размерности снимок притягивается к ячейке
///   (E8.9) — короткий spring, не влияющий на цели E8.4/E8.6;
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
///   Бросить можно на сетку / пустое место — ярлык встаёт на позицию превью
///   (`TileStore.moveBetweenFolders(_:to:at:)`, папка из одного ярлыка
///   распадается); на центр другой папки с удержанием E8.6 — перенос в неё;
///   центр обычного ярлыка тут не создаёт папку (работает как перестановка);
///   центр родной папки, панель и отмена возвращают ярлык, модель не меняется;
///   делегат получает ровно один
///   `didMove(_:toFolder:atIndex:)`.
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
        // E11.5: панель раскрытой папки переконфигурируется при каждом снимке —
        // custom actions её ярлыков добираются отложенной сверкой.
        grid.panelShortcutsDidConfigure = { [weak self] _, _ in
            self?.scheduleReconcile()
        }
    }

    deinit {
        grid.panelShortcutsDidConfigure = nil
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
        // E12.10: вход в edit (в т. ч. кнопкой хоста) приводит порядок модели к
        // порядку чтения — будущий drag, в том числе из панели папки, считает
        // слоты по канонической модели.
        canonicalizeModelOrderForEditing()
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
        // E12.10: порядок модели — до захвата базы drag'а (и при уже включённом
        // edit: хост мог поменять модель, пока edit был открыт).
        canonicalizeModelOrderForEditing()
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

        // Индекс до удаления: после мутации сетка переупакуется, а фокус
        // VoiceOver должен уйти на элемент, вставший на освободившееся место
        // (или на последний, если ярлык был последним).
        let removedIndex = grid.index(ofItemID: tileID)

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
                let removed = self.store.unpin(tileID)
                self.grid.setItemHidden(false, forItemID: tileID)

                guard removed else {
                    self.reconcileEditControls(animated: false)
                    return
                }

                // E10.5-C2: удаление из модели переупаковывает сетку — видимый
                // порядок приводим к порядку чтения (E10.15) и синхронизируем
                // сетку со снимком store.
                self.canonicalizeVisibleOrderIfNeeded()
                self.render(animated: true)
                self.delegate?.tileEditCoordinator(self, didUnpin: tileID)
                self.postLayoutChanged(afterUnpinningAtIndex: removedIndex)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.announce(TesseraStartScreenStrings.string(.a11yTileUnpinned))
            }
        )
    }

    /// Немедленное открепление без анимации (ячейка вне экрана/ярлык в папке).
    ///
    /// - Parameter tileID: Идентификатор ярлыка.
    private func performImmediateUnpin(_ tileID: AnyHashable) {
        // Удаляем запись в любом исходе: повторный unpin после отказа
        // хранилища должен снова иметь право на попытку.
        defer { unpinsInFlight.remove(tileID) }

        guard store.unpin(tileID) else { return }
        // E10.5-C2: папочные/unpin-операции не знают числа колонок — порядок
        // приводим к порядку чтения явно, одной операцией.
        canonicalizeVisibleOrderIfNeeded()
        render(animated: true)
        delegate?.tileEditCoordinator(self, didUnpin: tileID)
        postLayoutChanged(afterUnpinningAtIndex: nil)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        announce(TesseraStartScreenStrings.string(.a11yTileUnpinned))
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
    /// Переставляет элемент сетки через `TileStore` (§6).
    ///
    /// Операция раскладки не требует одобрения (D14). Перестановка идёт через
    /// ``TileStore/moveItem(_:toIndex:columns:)`` (E10.5-C1): хранилище
    /// канонизирует видимый порядок под фактическое число колонок (E10.15), а
    /// возвращённый индекс — фактический. Именно его получает делегат в
    /// `didMove`; после операции сетка синхронизируется со снимком хранилища.
    ///
    /// - Parameters:
    ///   - itemID: Идентификатор ярлыка или папки на сетке.
    ///   - index: Целевой индекс; хранилище зажимает значения.
    /// - Returns: `true`, если порядок изменился.
    @discardableResult
    public func move(_ itemID: AnyHashable, toIndex index: Int) -> Bool {
        // m1 (фикс-раунд W4): «изменился ли порядок» фиксируется ДО мутации.
        // Хост может быть подписан на `store.onChange` и синхронно применять
        // снимок к сетке — тогда после `moveItem` `grid.items` уже новый, и
        // сравнение после мутации ложно вернуло бы `false` без `didMove`.
        let idsBefore = grid.items.map { $0.id }
        let columns = grid.columns > 0 ? grid.columns : nil
        guard let actualIndex = store.moveItem(itemID, toIndex: index, columns: columns) else {
            return false
        }

        let changed = store.snapshot().items.map { $0.id } != idsBefore
        render(animated: true)
        guard changed else { return false }

        delegate?.tileEditCoordinator(self, didMove: itemID, toIndex: actualIndex)
        // E10.5-B6: элемент переехал — переводим фокус VoiceOver на его ячейку
        // после раскладки.
        postLayoutChanged(focusing: itemID)
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
            title: resolvedNewFolderTitle(title ?? configuration.folderTitle)
        )
        guard let folder else {
            if grid.index(ofItemID: tileID) != nil {
                notifyGroupingFailure(.createFolder, tileID: tileID, folderID: nil)
            }
            return nil
        }

        // E10.5-C2: папочные операции не знают числа колонок — видимый порядок
        // приводим к порядку чтения явно, затем синхронизируем сетку.
        canonicalizeVisibleOrderIfNeeded()
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
        guard store.addToFolder(tileID, folderID: folderID) else {
            notifyGroupingFailure(.addToFolder, tileID: tileID, folderID: folderID)
            return false
        }

        canonicalizeVisibleOrderIfNeeded()
        render(animated: true)
        delegate?.tileEditCoordinator(self, didAdd: tileID, toFolder: folderID)
        postLayoutChanged(focusing: folderID)
        announce(TesseraStartScreenStrings.string(.a11yFolderTileAdded))
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
        moveBetweenFolders(tileID, to: folderID, at: nil)
    }

    /// Перемещает ярлык между папками или на рабочий стол с позицией (E11.2).
    ///
    /// Без `index` ярлык, вынесенный из папки, встаёт сразу после неё; с
    /// `index` — на эту позицию видимого порядка (см.
    /// ``TileStore/moveBetweenFolders(_:to:at:)``). Порядок чтения под число
    /// колонок приводится после операции, фокус VoiceOver — на ярлыке.
    ///
    /// - Parameters:
    ///   - tileID: Ярлык, лежащий в папке.
    ///   - folderID: Папка-цель; `nil` — на рабочий стол.
    ///   - index: Позиция на рабочем столе.
    /// - Returns: `true`, если перемещение выполнено.
    @discardableResult
    public func moveBetweenFolders(
        _ tileID: AnyHashable,
        to folderID: AnyHashable?,
        at index: Int?
    ) -> Bool {
        guard store.moveBetweenFolders(tileID, to: folderID, at: index) else {
            notifyGroupingFailure(.moveBetweenFolders, tileID: tileID, folderID: folderID)
            return false
        }

        canonicalizeVisibleOrderIfNeeded()
        render(animated: true)
        // E11.1: единый колбэк с индексом (по умолчанию пересылает в прежний).
        delegate?.tileEditCoordinator(
            self,
            didMove: tileID,
            toFolder: folderID,
            atIndex: folderID == nil ? grid.index(ofItemID: tileID) : nil
        )
        if grid.index(ofItemID: tileID) != nil {
            postLayoutChanged(focusing: tileID)
        } else if let folderID = folderID {
            postLayoutChanged(focusing: folderID)
        }
        announce(TesseraStartScreenStrings.string(folderID == nil ? .a11yFolderTileOnStart : .a11yFolderTileMoved))
        return true
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

    // MARK: - Синхронизация и accessibility (E10.5)

    /// Приводит видимый порядок модели к порядку чтения (E10.5-C2, E10.15).
    ///
    /// Нужна после операций, которые не знают числа колонок: unpin и папочные
    /// операции (`TileStore.canonicalizeVisibleOrder(columns:)`). Хранилище само
    /// уведомит подписчиков (в drag-транзакции автосохранение выключено — запись
    /// будет одна по завершении).
    private func canonicalizeVisibleOrderIfNeeded() {
        guard grid.columns > 0 else { return }
        _ = store.canonicalizeVisibleOrder(columns: grid.columns)
    }

    /// Канонизирует порядок модели перед редактированием (E12.10).
    ///
    /// Хост может принести неканоничную модель: упаковка поднимает малую
    /// плитку, стоящую в модели последней, в «дыру» после среднего ярлыка, и
    /// видимый порядок расходится с `gridOrder`. Операции drop'а работают по
    /// слотам модели (`createFolder` заменяет слот цели, `moveItem` считает
    /// индексы), поэтому слияние на «поднявшуюся» плитку создавало папку в
    /// конце сетки, а не на месте цели. Приводим порядок к порядку чтения на
    /// входе в edit и на старте drag: видимая раскладка при этом не меняется
    /// (канонизация — перестановка только модели). Сетку подтягиваем, лишь
    /// если до канонизации она показывала модель: расхождение, принесённое
    /// хостом, по-прежнему ловит m2-проверка на захвате.
    private func canonicalizeModelOrderForEditing() {
        guard grid.columns > 0 else { return }
        let gridWasInSync = gridMatches(store.snapshot())
        guard store.canonicalizeVisibleOrder(columns: grid.columns) else { return }
        if gridWasInSync {
            syncGridWithModel(animated: false)
            // Смена порядка применяется `reloadData`: ячейки нужны сразу — на
            // них опирается захват drag в этом же проходе runloop.
            grid.layoutIfNeeded()
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
        let snapshot = store.snapshot()
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
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let argument = itemID.flatMap { self.grid.cellView(forItemID: $0) }
            self.accessibilityNotificationPoster(.layoutChanged, argument)
        }
    }

    /// Публикует `.layoutChanged` после unpin (E10.5-B6).
    ///
    /// Фокус получает элемент, вставший на место удалённого (или последний в
    /// сетке): сам удалённый ярлык уже не существует.
    ///
    /// - Parameter removedIndex: Индекс удалённого элемента до мутации.
    private func postLayoutChanged(afterUnpinningAtIndex removedIndex: Int?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let items = self.grid.items
            let focusID: AnyHashable?
            if let removedIndex, !items.isEmpty {
                focusID = items[min(max(removedIndex, 0), items.count - 1)].id
            } else {
                focusID = items.last?.id
            }
            let argument = focusID.flatMap { self.grid.cellView(forItemID: $0) }
            self.accessibilityNotificationPoster(.layoutChanged, argument)
        }
    }

    // MARK: - Согласованность drag-сессии (E10.5-B1)

    /// Совпадает ли модель с базой drag по структуре.
    ///
    /// Сравниваются идентификаторы, размеры и содержимое папок: бейджи/подписи
    /// раскладку не меняют и отменять из-за них перетаскивание нельзя.
    ///
    /// - Parameter session: Активная drag-сессия.
    /// - Returns: `true`, если модель всё ещё та, что была на захвате.
    private func modelMatchesBase(_ session: TesseraTileDragSession) -> Bool {
        // E11.1: у drag из папки база превью содержит синтетический ярлык, а
        // модель с ним не совпадает — сверяем с реальным снимком модели.
        let base = session.modelBaseSnapshot.items
        let current = store.snapshot().items
        guard base.count == current.count else { return false }

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
    /// Сравниваются идентификаторы, их порядок и размеры: именно это делает
    /// превью-E8.4 и снимок `TileStore`. Бейджи/подписи не входят.
    ///
    /// - Parameter snapshot: Ожидаемый снимок.
    /// - Returns: `true`, если сетка показывает его.
    private func gridMatchesDragSnapshot(_ snapshot: TileGridSnapshot) -> Bool {
        let current = grid.items
        guard current.count == snapshot.items.count else { return false }

        for (currentItem, expectedItem) in zip(current, snapshot.items) {
            guard currentItem.id == expectedItem.id,
                  currentItem.size == expectedItem.size else {
                return false
            }
        }
        return true
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
        guard dragSession == nil else { return }

        // m2 (фикс-раунд W4): контракт хоста — к моменту захвата сетка обязана
        // показывать актуальный снимок `TileStore`. Если снимок и модель
        // разошлись (внешний update в обход координатора, не применённый
        // store-снимок), drag не начинается: иначе превью считалось бы от
        // чужой базы, а drop/cancel могли бы разойтись с моделью. В DEBUG
        // нарушение контракта видно как assertion, а не как «проглоченный»
        // long-press.
        let modelSnapshot = store.snapshot()
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
              let initialIndex = grid.index(ofItemID: itemID),
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
            initialIndex: initialIndex,
            isTile: item.tile != nil,
            slotFrame: frame,
            liftFrame: frame,
            placeholder: placeholder,
            dragView: dragView,
            point: point,
            baseSnapshot: modelSnapshot,
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
    /// вставлен отдельным ярлыком сразу после неё. Этот синтетический элемент
    /// даёт перетаскиваемому ярлыку слот, пустышку и участие в push-превью
    /// (`TileLayoutEngine.previewOrder`) как у обычной плитки; сверка с моделью
    /// (``modelMatchesBase(_:)``) идёт по реальному снимку.
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
        let modelSnapshot = store.snapshot()
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

        // Отображаемый снимок: ярлык вынут из папки и лежит сразу после неё.
        // Размер берётся из дескриптора, как его разрешит `TileStore` при выносе.
        displayFolder.tiles.removeAll { $0.id == hit.tile.id }
        items[folderIndex] = .folder(displayFolder)
        items.insert(.tile(hit.tile), at: folderIndex + 1)
        let displaySnapshot = TileGridSnapshot(items: items, unpinned: modelSnapshot.unpinned)

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
            initialIndex: folderIndex + 1,
            isTile: true,
            slotFrame: slotFrame,
            liftFrame: hit.frame,
            placeholder: placeholder,
            dragView: hit.snapshot,
            point: point,
            baseSnapshot: displaySnapshot,
            modelBaseSnapshot: modelSnapshot,
            sourceFolderID: hit.folder.id,
            magnetSize: hit.tile.size
        )
    }

    /// Ставит оверлеи, создаёт drag-сессию и запускает подъём (общий хвост
    /// старта drag для ячейки сетки и для ярлыка из папки, E11.1).
    ///
    /// - Parameters:
    ///   - itemID: Идентификатор перетаскиваемого ярлыка/папки.
    ///   - initialIndex: Индекс в базовом снимке.
    ///   - isTile: Ярлык ли это.
    ///   - slotFrame: Рамка слота в сетке (пустышка).
    ///   - liftFrame: Рамка, с которой стартует снимок (для ярлыка из папки —
    ///     рамка иконки панели).
    ///   - placeholder: Пустышка.
    ///   - dragView: Снимок.
    ///   - point: Точка захвата в координатах сетки.
    ///   - baseSnapshot: База превью.
    ///   - modelBaseSnapshot: Снимок модели, если он отличается от базы.
    ///   - sourceFolderID: Папка-источник (drag из панели).
    ///   - magnetSize: Размерность для магнита.
    private func installDragSession(
        itemID: AnyHashable,
        initialIndex: Int,
        isTile: Bool,
        slotFrame: CGRect,
        liftFrame: CGRect,
        placeholder: UIView,
        dragView: UIView,
        point: CGPoint,
        baseSnapshot: TileGridSnapshot,
        modelBaseSnapshot: TileGridSnapshot?,
        sourceFolderID: AnyHashable?,
        magnetSize: TileSize
    ) {
        beginDragStoreTransaction()

        grid.setItemHidden(true, forItemID: itemID)
        removeControl(for: itemID)

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

        // E8.4: база превью — порядок модели на момент захвата. Сетка и модель
        // к этому моменту совпадают, поэтому снимок хранилища и есть то, что
        // видит пользователь.
        let session = TesseraTileDragSession(
            itemID: itemID,
            initialIndex: initialIndex,
            isTile: isTile,
            grabOffset: CGPoint(x: liftFrame.midX - point.x, y: liftFrame.midY - point.y),
            dragView: dragView,
            placeholder: placeholder,
            lastPoint: point,
            baseSnapshot: baseSnapshot,
            magnetSize: magnetSize,
            modelBaseSnapshot: modelBaseSnapshot,
            sourceFolderID: sourceFolderID
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
    /// Решение принимается по базовой раскладке (E11.7, ``hitTestTarget(at:session:)``),
    /// а не по `grid.item(at:)`: исходная ячейка скрыта, но остаётся в раскладке
    /// и перехватила бы хит-тест, а рамки сетки уже сдвинуты превью.
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

        var target: HoverTarget = .none

        if grid.bounds.insetBy(dx: -8, dy: -8).contains(point),
           let (hovered, frame) = hitTestTarget(at: point, session: session),
           let baseIndex = session.baseIndex(of: hovered.id) {

            switch hovered {
            case .folder(let folder):
                if !session.isTile {
                    // Перетаскивание папки по сетке — обычная перестановка:
                    // папку нельзя бросить в папку (вложенности нет).
                    target = .reorder(hovered.id, index: baseIndex)
                } else if folder.id == session.sourceFolderID {
                    // E11.1: центр родной папки — «вернуть в папку» (no-op),
                    // край — обычная перестановка: ярлык встаёт перед папкой.
                    target = isPointInDropCenter(point, of: frame)
                        ? .sourceFolder
                        : .reorder(hovered.id, index: baseIndex)
                } else if isPointInDropCenter(point, of: frame) {
                    // E10.5-A1: центральная зона папки — добавление ярлыка
                    // внутрь по удержанию E8.6 (D14). Без удержания drop — no-op.
                    target = .folder(folder.id)
                } else {
                    // E10.5-A1: левая/правая (и прочие краевые) половины плитки
                    // папки — перестановка: папка встаёт в базовый индекс цели,
                    // ярлык занимает её место (push-превью E8.4).
                    target = .reorder(hovered.id, index: baseIndex)
                }

            case .tile(let tile):
                if session.isTile, session.sourceFolderID == nil,
                   isPointInDropCenter(point, of: frame) {
                    // Центр ярлыка — создание папки из двух ярлыков (D14).
                    // E11.1: для ярлыка, взятого из папки, папка не создаётся —
                    // центр работает как обычная перестановка (вынос на сетку).
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

        // E12.1: над пустым местом (дыра, зазор, область под плитками) позиция —
        // слот порядка, ближайший к пальцу, а не «последнее превью».
        // На подъёме палец стоит там, где была иконка панели (после закрытия панели
        // это обычно пустое место): превью остаётся в слоте «после папки», пока
        // палец не сдвинется на заметное расстояние.
        if !session.hasMovedFromOrigin {
            let dx = point.x - session.originPoint.x
            let dy = point.y - session.originPoint.y
            if dx * dx + dy * dy > Self.emptySlotActivationDistance * Self.emptySlotActivationDistance {
                session.hasMovedFromOrigin = true
            }
        }
        if target == .none,
           session.hasMovedFromOrigin,
           grid.bounds.insetBy(dx: -8, dy: -8).contains(point),
           !session.isOverFolderPanel {
            target = emptySpaceTarget(at: point, session: session)
        }

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
    /// E10.5-A2: расстояние считается от **центра снимка**
    /// (`point + grabOffset`), а не от точки пальца. Иначе плитка, взятая не за
    /// центр, притягивалась к слоту с ошибкой до половины плитки и «прыгала»;
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
    /// - Returns: Центр ближайшего слота в радиусе или `nil`.
    private func magnetTarget(for point: CGPoint, session: TesseraTileDragSession) -> CGPoint? {
        guard configuration.magnetSnapRadius > 0, !isReduceMotionEnabled() else { return nil }
        guard !session.isOverFolderPanel else { return nil }
        guard session.hasLeftOriginSlot else { return nil }

        switch session.hover {
        case .folder, .group:
            return nil
        case .none, .reorder, .slot, .sourceFolder:
            break
        }

        let snapshotCenter = CGPoint(
            x: point.x + session.grabOffset.x,
            y: point.y + session.grabOffset.y
        )
        return TesseraTileMagnet.magnetTarget(
            for: snapshotCenter,
            slotCenters: grid.magnetSlotCenters(for: session.magnetSize),
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
        let previewOrder: [TileGridItem]?
        switch target {
        case .reorder(let targetID, _):
            previewOrder = TileLayoutEngine.previewOrder(
                items: session.baseSnapshot.items,
                draggingID: session.itemID,
                targetID: targetID
            )
        case .slot(let insertionIndex):
            previewOrder = TileLayoutEngine.previewOrder(
                items: session.baseSnapshot.items,
                draggingID: session.itemID,
                insertionIndex: insertionIndex
            )
        case .none, .folder, .group, .sourceFolder:
            previewOrder = nil
        }
        guard let preview = previewOrder else {
            animatePlaceholder(to: currentFrame(of: session))
            return
        }

        guard preview.map({ $0.id }) != grid.items.map({ $0.id }) else {
            animatePlaceholder(to: currentFrame(of: session))
            return
        }

        let previewSnapshot = TileGridSnapshot(
            items: preview,
            unpinned: session.baseSnapshot.unpinned
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

    /// Элемент-цель под пальцем и рамка, по которой решается зона (E11.7).
    ///
    /// Хит-тест идёт по **базовой** раскладке (порядок
    /// ``TesseraTileDragSession/baseSnapshot`` — тот же, что у `.reorder` и
    /// `baseIndex`), а не по рамкам сетки: те уже сдвинуты push-превью, и
    /// плитка, уехавшая из-под пальца, делала центр папки/ярлыка недостижимым
    /// при подходе в сторону сдвига. Центр/край (25%) считаются по базовой
    /// рамке. Над собственным базовым слотом цель — `nil` (остаёмся на
    /// последнем превью, E8.4/«c»). Подсветка по-прежнему рисуется на видимой
    /// (сдвинутой) рамке цели — её берёт ``showDropHighlight(for:style:)``.
    ///
    /// Пока раскрыта панель папки (в т. ч. во время анимированного закрытия),
    /// раскладка сетки не совпадает с базовой — действует прежний хит-тест по
    /// рамкам сетки.
    ///
    /// - Parameters:
    ///   - point: Точка в координатах сетки.
    ///   - session: Активная drag-сессия.
    /// - Returns: Элемент и рамка для расчёта зоны или `nil`.
    private func hitTestTarget(
        at point: CGPoint,
        session: TesseraTileDragSession
    ) -> (TileGridItem, CGRect)? {
        if grid.expandedFolderID == nil, let frames = baseFrames(for: session) {
            for item in session.baseSnapshot.items {
                guard let contentFrame = frames[item.id] else { continue }
                let frame = grid.gridFrame(fromContentFrame: contentFrame)
                guard frame.contains(point) else { continue }
                // Собственный базовый слот — не цель (нет перестановки с собой).
                return item.id == session.itemID ? nil : (item, frame)
            }
            return nil
        }

        guard let hovered = item(under: point, excluding: session.itemID)
                ?? panelItem(under: point, excluding: session.itemID),
              let frame = grid.frame(forItemID: hovered.id) else {
            return nil
        }
        return (hovered, frame)
    }

    /// Смещение пальца от точки захвата, после которого над пустым местом
    /// включается выбор позиции (E12.1), pt.
    static let emptySlotActivationDistance: CGFloat = 12

    /// Цель над пустым местом: позиция вставки по порядку чтения (E12.1).
    ///
    /// Раскладка строго компактная (E8.5), поэтому «позиция» drop'а — это
    /// индекс **порядка**, а не пиксели: упаковщик сам кладёт элемент в первое
    /// подходящее место для этого индекса. Чтобы пользователь выбирал, куда
    /// попадёт элемент, над пустым местом (дыра, зазор, область под плитками)
    /// позиция берётся по клетке пальца в базовой раскладке: элемент встаёт
    /// сразу после последней плитки, не позже этой клетки в порядке чтения
    /// (``TesseraTileGridView/baseInsertionIndex(forGridPoint:items:draggingID:)``).
    /// Превью и drop используют ту же позицию, поэтому элемент ложится ровно
    /// туда, где его показало превью.
    ///
    /// Над собственным базовым слотом элемента (E8.4/«c»), при раскрытой панели
    /// и без раскладки результат `.none` — остаёмся на последнем превью.
    ///
    /// - Parameters:
    ///   - point: Точка пальца в координатах сетки.
    ///   - session: Активная drag-сессия.
    /// - Returns: `.slot` с позицией вставки или `.none`.
    private func emptySpaceTarget(
        at point: CGPoint,
        session: TesseraTileDragSession
    ) -> HoverTarget {
        guard grid.expandedFolderID == nil,
              let own = baseFrames(for: session)?[session.itemID],
              !grid.gridFrame(fromContentFrame: own).contains(point),
              let insertion = grid.baseInsertionIndex(
                  forGridPoint: point,
                  items: session.baseSnapshot.items,
                  draggingID: session.itemID
              ) else {
            return .none
        }
        return .slot(insertion)
    }

    /// Базовые рамки элементов сессии в координатах контента (E11.7).
    ///
    /// Считаются один раз за сессию и перестраиваются, если изменилась
    /// геометрия сетки (ширина, колонки, поля, направление). Смещение
    /// прокрутки в кэш не входит: рамки хранятся в координатах контента и на
    /// каждом шаге (в т. ч. на кадре автопрокрутки) переводятся
    /// `grid.gridFrame(fromContentFrame:)` с актуальным `contentOffset`.
    ///
    /// - Parameter session: Активная drag-сессия.
    /// - Returns: Рамки по идентификатору или `nil`, если посчитать нельзя.
    private func baseFrames(for session: TesseraTileDragSession) -> [AnyHashable: CGRect]? {
        let key = grid.baseFramesKey()
        if let cached = session.baseFrames, cached.key == key {
            return cached.frames
        }
        guard let frames = grid.baseContentFrames(for: session.baseSnapshot.items) else {
            session.baseFrames = nil
            return nil
        }
        session.baseFrames = (key: key, frames: frames)
        return frames
    }

    /// Элемент под точкой, кроме перетаскиваемого (рамки сетки; запасной путь).
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

    /// Элемент-панель под точкой (для переиспользования существующей ветки
    /// `.folderContent` в ``updateHoverTargets(at:)``).
    ///
    /// - Parameters:
    ///   - point: Точка в координатах сетки.
    ///   - excludedID: Идентификатор перетаскиваемого элемента.
    /// - Returns: `.folderContent`, если точка над панелью, иначе `nil`.
    private func panelItem(
        under point: CGPoint,
        excluding excludedID: AnyHashable
    ) -> TileGridItem? {
        guard isPointOverFolderPanel(point),
              let item = grid.item(at: point),
              item.id != excludedID else {
            return nil
        }
        return item
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
        case .none, .reorder, .slot, .sourceFolder:
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
        case .none, .reorder, .slot, .sourceFolder:
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
            case .none, .reorder, .slot, .sourceFolder:
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
    /// E8.4: сетка к этому моменту показывает превью порядка, а модель всё ещё
    /// в состоянии на момент захвата. Drop фиксирует превью одним
    /// ``TileStore/moveItem(_:toIndex:columns:)`` по индексу перетаскиваемой
    /// плитки в превью (E10.5-C1: хранилище канонизирует порядок и возвращает
    /// фактический индекс), отмена возвращает сетке порядок модели и не пишет в
    /// модель вовсе. E9.5: drop в центр без удержания E8.6 — no-op.
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

        default:
            // E11.1: ярлык из папки выносится на рабочий стол на позицию превью.
            if session.sourceFolderID != nil {
                dropOutOfFolder(session)
                return
            }
            // Индекс перетаскиваемой плитки в текущем (превью) порядке сетки —
            // ровно тот, который `TileStore.moveItem` воспроизведёт: хранилище
            // тоже вынимает элемент и вставляет его на это место.
            let finalIndex = previewIndex(of: session)
            let actualIndex = commitPreviewOrder(session, toIndex: finalIndex)
            let frame = currentFrame(of: session)
            moveDragView(session, to: frame) {
                self.cleanupDrag(session, unhide: true)
                guard session.modelChanged, let actualIndex else { return }
                self.delegate?.tileEditCoordinator(
                    self,
                    didMove: session.itemID,
                    toIndex: actualIndex
                )
                // E10.5-B6: после перестановки фокус VoiceOver — на переехавшую
                // плитку.
                self.postLayoutChanged(focusing: session.itemID)
            }
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

    /// Завершает drop ярлыка из панели на сетку: вынос из папки (E11.1).
    ///
    /// Позиция — индекс ярлыка в текущем (превью) порядке сетки. Если в папке
    /// был один ярлык, она распадётся и в итоговом порядке её уже нет —
    /// индекс уменьшается на единицу, когда папка стояла раньше ярлыка.
    /// Дальше как у остальных папочных drop'ов: канонизация, `render`, рамка
    /// читается после них, фокус VoiceOver — на ярлыке.
    ///
    /// - Parameter session: Drag-сессия (источник — папка).
    private func dropOutOfFolder(_ session: TesseraTileDragSession) {
        guard let sourceID = session.sourceFolderID else { return }

        var index = previewIndex(of: session)
        if let folder = session.modelBaseSnapshot.folders.first(where: { $0.id == sourceID }),
           folder.tiles.count == 1,
           let folderIndex = grid.index(ofItemID: sourceID),
           folderIndex < index {
            index -= 1
        }

        guard store.moveBetweenFolders(session.itemID, to: nil, at: index) else {
            failGroupingDrop(
                .moveBetweenFolders,
                session: session,
                folderID: nil,
                reason: TesseraStartScreenStrings.string(.a11yGroupingReasonMoveDenied)
            )
            return
        }

        session.modelChanged = true
        canonicalizeVisibleOrderIfNeeded()
        render(animated: true)
        let frame = currentFrame(of: session)
        let actualIndex = grid.index(ofItemID: session.itemID)
        delegate?.tileEditCoordinator(
            self,
            didMove: session.itemID,
            toFolder: nil,
            atIndex: actualIndex
        )
        announce(TesseraStartScreenStrings.string(.a11yFolderTileOnStart))
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        moveDragView(session, to: frame) {
            self.cleanupDrag(session, unhide: true)
            self.postLayoutChanged(focusing: session.itemID)
        }
    }

    /// Завершает drop ярлыка из панели на центр другой папки (E11.1).
    ///
    /// Вызывается только при выдержанном удержании E8.6. Перенос идёт через
    /// ``TileStore/moveBetweenFolders(_:to:at:)`` (одобрение хоста, D14); папка-
    /// источник распадается, если ярлык был последним.
    ///
    /// - Parameters:
    ///   - session: Drag-сессия (источник — папка).
    ///   - folderID: Папка-цель.
    private func dropFromFolderIntoFolder(_ session: TesseraTileDragSession, folderID: AnyHashable) {
        guard store.moveBetweenFolders(session.itemID, to: folderID, at: nil) else {
            failGroupingDrop(
                .moveBetweenFolders,
                session: session,
                folderID: folderID,
                reason: TesseraStartScreenStrings.string(.a11yGroupingReasonMoveDenied)
            )
            return
        }

        session.modelChanged = true
        canonicalizeVisibleOrderIfNeeded()
        render(animated: true)
        // Рамку цели читаем после переупаковки: распад папки-источника сдвигает
        // соседей.
        let folderFrame = grid.frame(forItemID: folderID) ?? session.placeholder.frame
        delegate?.tileEditCoordinator(
            self,
            didMove: session.itemID,
            toFolder: folderID,
            atIndex: nil
        )
        announce(TesseraStartScreenStrings.string(.a11yFolderTileMoved))
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        collapseDragView(session, into: folderFrame) {
            self.cleanupDrag(session, unhide: false)
            self.postLayoutChanged(focusing: folderID)
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

    /// Фиксирует превью порядка в модели на drop (E8.4, E10.5-C1).
    ///
    /// Используется ``TileStore/moveItem(_:toIndex:columns:)``: хранилище
    /// зажимает индекс, канонизирует видимый порядок под фактическое число
    /// колонок (E10.15) и возвращает фактический индекс. Сетка после drop
    /// синхронизируется со снимком store — если канонизация переставила
    /// соседей, на экране окажется порядок модели, а не превью.
    ///
    /// - Parameters:
    ///   - session: Drag-сессия.
    ///   - index: Целевой индекс перетаскиваемой плитки в видимом порядке.
    /// - Returns: Фактический индекс из хранилища или `nil`, если элемента на
    ///   сетке уже нет.
    private func commitPreviewOrder(_ session: TesseraTileDragSession, toIndex index: Int) -> Int? {
        let columns = grid.columns > 0 ? grid.columns : nil
        guard let actualIndex = store.moveItem(
            session.itemID,
            toIndex: index,
            columns: columns
        ) else {
            // Элемент исчез из модели (внешняя мутация) — сетка должна совпасть
            // с моделью, а не остаться с превью.
            render(animated: true)
            return nil
        }

        let baseIDs = session.baseSnapshot.items.map { $0.id }
        let currentIDs = store.snapshot().items.map { $0.id }
        session.modelChanged = baseIDs != currentIDs
        render(animated: true)
        return actualIndex
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
                reason: TesseraStartScreenStrings.string(.a11yGroupingReasonAddDenied)
            )
            return
        }

        session.modelChanged = true
        // E10.5-C2: операция с папкой не знает числа колонок — порядок чтения
        // приводим явно; удаление ярлыка из сетки меняет упаковку.
        canonicalizeVisibleOrderIfNeeded()
        render(animated: true)
        // Рамку папки читаем после переупаковки: удаление ярлыка могло сдвинуть
        // папку вверх, и снимок должен лететь в её актуальный слот.
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
    /// Операция D14 состоит из двух одобряемых шагов (создание папки из
    /// целевого ярлыка, добавление перетаскиваемого), но выполняется атомарно
    /// (E11.6): ``TileStore`` откатывает первый шаг, если хост отказал второму,
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
            withTile: targetID,
            adding: session.itemID,
            title: resolvedNewFolderTitle(configuration.folderTitle)
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
        canonicalizeVisibleOrderIfNeeded()
        render(animated: true)
        // E11.3: рамку папки читаем после канонизации и `render` — до них новой
        // плитки в сетке нет, и снимок летел бы в старый слот плейсхолдера.
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
        editControlsHost?.removeFromSuperview()
        editControlsHost = nil

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
    /// «Убрать из папки» — ``moveBetweenFolders(_:to:at:)`` с `nil`: ярлык
    /// встаёт сразу после папки (или на её месте, если она распалась).
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
/// E10.5-A1: у плитки-папки две роли — краевые зоны переставляют её как обычную
/// плитку (`.reorder`), центральная зона по удержанию E8.6 добавляет ярлык
/// внутрь (`.folder`, D14). E9.5: drop в центр без выдержанного удержания —
/// возврат на исходное место (no-op).
enum HoverTarget: Equatable {

    /// Цели нет (пустое место/плитка вне сетки).
    case none

    /// Перестановка к элементу `id`.
    ///
    /// `index` — индекс цели в **базовом** порядке сетки (снимок на момент
    /// захвата), а не в текущем превью: превью пересчитывается от базы на
    /// каждом шаге (E8.4), и индекс превью зависел бы от предыдущей цели.
    /// Он же — индекс перетаскиваемой плитки в превью и целевой индекс
    /// `TileStore.moveItem(_:toIndex:columns:)` при фиксации drop'а.
    case reorder(AnyHashable, index: Int)

    /// Центральная зона папки `id`: добавление ярлыка в папку по удержанию E8.6
    /// (D14). Без удержания drop — no-op (E9.5).
    case folder(AnyHashable)

    /// Создание папки из ярлыка `id` (drop на его центр). Без удержания E8.6
    /// drop — no-op (E9.5).
    case group(AnyHashable)

    /// Центр папки-источника при drag ярлыка из неё (E11.1): цели нет, drop
    /// возвращает ярлык в папку, модель не меняется.
    case sourceFolder

    /// Пустое место под пальцем (E12.1): позиция вставки по порядку чтения.
    ///
    /// Значение — позиция вставки среди остальных элементов (без
    /// перетаскиваемого), `0 ... count`; она же индекс перетаскиваемого элемента
    /// в превью и целевой индекс drop'а. Выбирается по клетке пальца в базовой
    /// раскладке (`emptySpaceTarget`).
    case slot(Int)

    /// Идентификатор цели удержания E8.6, если цель его поддерживает.
    ///
    /// Удержание взводится и для центра ярлыка (создание папки), и для центра
    /// плитки-папки (добавление в папку): это одна и та же машина
    /// ``TesseraMergeHoverTracker``.
    var mergeTargetID: AnyHashable? {
        switch self {
        case .folder(let itemID), .group(let itemID):
            return itemID
        case .none, .reorder, .slot, .sourceFolder:
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
        case .none, .reorder, .slot, .sourceFolder:
            return nil
        }
    }
}

/// Активная drag-сессия.
///
/// Класс, а не структура: координатор и таймер меняют `lastPoint`/`hover`
/// из разных мест, и копии значения разъехались бы.
final class TesseraTileDragSession {

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
    /// панели палец стоит там, где была иконка, и слот не должен «убегать» из-под
    /// него в тот же кадр. Взводится один раз за сессию.
    var hasMovedFromOrigin = false

    /// Снимок модели на момент захвата (E8.4).
    ///
    /// База для превью порядка (`TileLayoutEngine.previewOrder`) и для проверки
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
        magnetSize: TileSize,
        modelBaseSnapshot: TileGridSnapshot? = nil,
        sourceFolderID: AnyHashable? = nil
    ) {
        self.modelBaseSnapshot = modelBaseSnapshot ?? baseSnapshot
        self.sourceFolderID = sourceFolderID
        self.itemID = itemID
        self.initialIndex = initialIndex
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
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
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
/// можно меньше содержимого. Выступ ограничен 6 pt: зазор между плитками сетки
/// по умолчанию 8 pt, так что кнопка не заходит на соседнюю плитку, а у
/// крайних плиток остаётся в полях (≥ 16 pt). Светлая заливка с тёмным символом, тонкое
/// кольцо и тень читаются на плитках любого цвета в светлой и тёмной темах.
/// Видимая кнопка может быть мелкой, а зона касания расширяется до
/// ``minimumHitSide`` (`hitTest`).
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

    /// Выступ кнопки за рамку плитки по каждой оси, pt.
    static let cornerOverhang: CGFloat = 6

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
        let overhang = TesseraTileEditControlView.cornerOverhang
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft

        // Кнопка открепления — в верхнем углу по направлению чтения, стрелка —
        // в нижнем противоположном (§9, RTL). Центр кнопки лежит у самого угла
        // рамки, чуть наружу: половина диаметра остаётся над плиткой.
        let unpinX = isRightToLeft ? bounds.width - side + overhang : -overhang
        let resizeX = isRightToLeft ? -overhang : bounds.width - side + overhang

        unpinButton.frame = CGRect(x: unpinX, y: -overhang, width: side, height: side)
        resizeButton.frame = CGRect(
            x: resizeX,
            y: bounds.height - side + overhang,
            width: side,
            height: side
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

    /// Зона касания кнопки: видимая рамка, расширенная до 44 pt вокруг центра.
    private func hitFrame(for button: UIButton) -> CGRect {
        let minSide = TesseraTileEditControlView.minimumHitSide
        let frame = button.frame
        let dx = max(0, (minSide - frame.width) / 2)
        let dy = max(0, (minSide - frame.height) / 2)
        return frame.insetBy(dx: -dx, dy: -dy)
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
