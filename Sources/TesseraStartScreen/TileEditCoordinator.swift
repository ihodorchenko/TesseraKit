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
//    с fly-out, resize по циклу small → medium → wide → large с переупаковкой,
//    собственный drag-координатор (снэпшот + пустышка + переупаковка модели +
//    инвалидация layout), а не нативный `UICollectionView` interactive movement;
//  - §3 «Плиточная сетка»: переупаковку считает `TileLayoutEngine`, анимацию
//    сдвига соседей — `TesseraTileGridView.update(snapshot:animated:)` через
//    batch updates;
//  - §9 «Accessibility»: в edit-режиме у плитки появляются custom actions
//    resize/unpin, смена режима озвучивается; Reduce Motion отключает «желе»,
//    fly-out и параллакс-подобные эффекты, оставляя крестики и подсветку;
//  - §14 «Уточнения MVP»: D12 (ярлык — просто действие), D14 (папки — только
//    через функцию одобрения `TileStore.approval`), D15 (четыре размера).
//
//  Правило «один писатель» (§6): модель меняет только `TileStore`; координатор
//  не хранит порядок и размеры, а читает снимок и вызывает операции хранилища.
//  Сетка не ходит в хранилище сама — после каждой мутации координатор применяет
//  новый снимок через `update(snapshot:animated:)`, но только если хост ещё не
//  сделал этого из своего `TileStore.onChange` (сравнение снимков дешёвое).
//
//  Дисциплина прокрутки (§3, CORE-IOS-DESIGN.md §2): в колбэке `contentOffset`
//  координатор трогает только `frame`/`isHidden` видов-кнопок поверх сетки —
//  layout сетки и ячеек не пересчитывается.
//
//  Границы ответственности:
//  - сетка (`TesseraTileGridView`) отображает снимок и отдаёт геометрию;
//  - `TileStore` — единственный писатель модели;
//  - координатор владеет жестами, оверлеями крестиков/стрелок, drag-сессией
//    и минимальным экраном папки;
//  - открытие ярлыка/папки по тапу остаётся за хостом (`onTap` сетки).
//
//  Все методы — главный поток: UIKit-вью и `TileStore` не рассчитаны на
//  фоновые вызовы (CORE-IOS-DESIGN.md §3).
//
//  Задача плана: E4.4 (после E4.2: TileDescriptor, TileLayoutEngine, TileStore,
//  TileGridView уже в репозитории).
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
/// тестов E4.7), автопрокрутка у краёв при перетаскивании.
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
    /// При Reduce Motion подъём не анимируется (плитка едет 1:1 за пальцем).
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

    /// Создаёт конфигурацию.
    ///
    /// - Parameters:
    ///   - seed: Seed фаз «желе»; по умолчанию фиксированный.
    ///   - jiggleAngle: Амплитуда в градусах, по умолчанию 1.2.
    ///   - jiggleDuration: Длительность цикла в секундах, по умолчанию 0.4.
    ///   - liftScale: Масштаб поднятой плитки, по умолчанию 1.04.
    ///   - controlDiameter: Диаметр кнопок, по умолчанию 28.
    ///   - autoScrollEdge: Зона автопрокрутки, по умолчанию 64.
    ///   - autoScrollMaximumSpeed: Максимальная скорость, по умолчанию 9.
    ///   - folderTitle: Название новой папки, по умолчанию пусто.
    public init(
        seed: UInt64 = 0xE4_0004_0000_0001,
        jiggleAngle: CGFloat = 1.2,
        jiggleDuration: TimeInterval = 0.4,
        liftScale: CGFloat = 1.04,
        controlDiameter: CGFloat = 28,
        autoScrollEdge: CGFloat = 64,
        autoScrollMaximumSpeed: CGFloat = 9,
        folderTitle: String = ""
    ) {
        self.seed = seed
        self.jiggleAngle = jiggleAngle
        self.jiggleDuration = jiggleDuration
        self.liftScale = liftScale
        self.controlDiameter = controlDiameter
        self.autoScrollEdge = autoScrollEdge
        self.autoScrollMaximumSpeed = autoScrollMaximumSpeed
        self.folderTitle = folderTitle
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
///   Motion анимации нет — остаются крестики;
/// - **unpin**: крестик → fly-out снимка плитки, затем `TileStore.unpin`;
/// - **resize**: стрелка → циклическая смена размера из поддерживаемых
///   (по умолчанию — все четыре, помещающиеся в текущее число колонок) через
///   `TileStore.resize` и переупаковку layout;
/// - **drag**: собственный координатор — снимок едет за пальцем, на месте
///   остаётся пустышка, соседи «расступаются» переупаковкой модели, при
///   отпускании плитка встаёт в ближайшее валидное место; автопрокрутка у краёв;
/// - **папки** (D14): перетаскивание ярлыка на папку — `addToFolder`,
///   на центр ярлыка — `createFolder` + `addToFolder`, всё через
///   `TileStore.approval`; отказ → анимация возврата на место. Экран папки —
///   минимальный sheet (`TesseraFolderViewController`), в нём долгое нажатие на
///   ярлык открывает меню «переместить в другую папку / на рабочий стол»,
///   которое вызывает `TileStore.moveBetweenFolders` (тоже через одобрение).
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
    /// seed, кнопки пересоздаются с новым диаметром.
    public var configuration: TesseraTileEditConfiguration {
        didSet {
            jiggleSpecs.removeAll()
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

    /// Отложенная сверка кнопок: не выполняет layout внутри колбэка прокрутки.
    private var hasScheduledReconcile = false

    /// Значение ``TileStore/autosaves`` до начала drag.
    ///
    /// Перетаскивание переставляет модель на каждом «расступании»; писать JSON
    /// на каждый шаг — лишние синхронные записи на диск в горячем пути. На время
    /// drag автосохранение выключается, а по завершении восстанавливается и
    /// состояние сохраняется один раз.
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

        if let wasEnabled = autosavesBeforeDrag {
            autosavesBeforeDrag = nil
            store.autosaves = wasEnabled
        }

        grid.removeGestureRecognizer(longPressRecognizer)
        grid.removeGestureRecognizer(backgroundTapRecognizer)

        // Оверлеи — подвью сетки: если их не убрать, они переживут координатор.
        for control in editControls.values {
            control.removeFromSuperview()
        }
        editControls.removeAll()
        dropHighlightView?.removeFromSuperview()
        dropHighlightView = nil
        dragSession?.dragView.removeFromSuperview()
        dragSession?.placeholder.removeFromSuperview()
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
            }
        }
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

    /// Входит в режим редактирования: «желе», крестики и стрелки.
    ///
    /// Повторный вызов ничего не делает. При Reduce Motion «желе» не запускается,
    /// но кнопки и custom actions появляются (§9).
    public func beginEditing() {
        guard !isEditing, isEnabled else { return }

        isEditing = true
        backgroundTapRecognizer.isEnabled = true
        reconcileEditControls(animated: false)
        // Ячейки могут быть ещё не созданы (первый layout/показ): доберём
        // крестики и «желе» на следующем проходе runloop.
        scheduleReconcile()

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        announce("Режим редактирования.")
        delegate?.tileEditCoordinatorDidBeginEditing(self)
    }

    /// Выходит из режима редактирования и снимает активное перетаскивание.
    ///
    /// Порядок отката drag-перестановки — ``TileStore/move(_:toIndex:)`` к
    /// исходному индексу, поэтому незавершённый drag не оставляет модель
    /// в промежуточном состоянии.
    public func endEditing() {
        guard isEditing else { return }

        cancelDragImmediately()
        isEditing = false
        backgroundTapRecognizer.isEnabled = false
        removeAllEditControls()
        removeAllJiggle()

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
    ///
    /// - Parameters:
    ///   - item: Элемент, по которому было долгое нажатие.
    ///   - point: Точка нажатия в координатах сетки (как в
    ///     `TesseraTileGridView.onLongPress`).
    public func handleLongPress(on item: TileGridItem, at point: CGPoint) {
        guard isEnabled, grid.window != nil, dragSession == nil else { return }
        guard grid.index(ofItemID: item.id) != nil else { return }

        if !isEditing {
            beginEditing()
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
        guard next != item.size, store.resize(itemID, to: next) else { return nil }

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
    /// Операция раскладки не требует одобрения (D14); это тот же путь, которым
    /// пользуется drag при «расступании» соседей.
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
    /// - Parameters:
    ///   - itemID: Идентификатор ярлыка или папки.
    ///   - point: Точка захвата в координатах сетки.
    private func startDrag(itemID: AnyHashable, at point: CGPoint) {
        guard dragSession == nil,
              let item = grid.items.first(where: { $0.id == itemID }),
              let frame = grid.frame(forItemID: itemID),
              frame.intersects(grid.bounds),
              let initialIndex = grid.index(ofItemID: itemID),
              let placeholder = grid.placeholderView(forItemID: itemID),
              let dragView = makeDragView(forItemID: itemID) else {
            return
        }

        beginDragStoreTransaction()

        grid.setItemHidden(true, forItemID: itemID)
        removeControl(for: itemID)
        if let cell = grid.cellView(forItemID: itemID) as? TesseraTileCell {
            cell.contentView.layer.removeAnimation(forKey: TesseraTileEditCoordinator.jiggleKey)
        }

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

        let session = TesseraTileDragSession(
            itemID: itemID,
            initialIndex: initialIndex,
            isTile: item.tile != nil,
            grabOffset: CGPoint(x: frame.midX - point.x, y: frame.midY - point.y),
            dragView: dragView,
            placeholder: placeholder,
            lastPoint: point
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
    /// Сначала берётся готовый снимок сетки (он дешевле), затем — резервный
    /// вариант через `resizableSnapshotView`; для ячейки вне экрана возвращает
    /// `nil`, и drag не начинается.
    ///
    /// - Parameter itemID: Идентификатор элемента.
    /// - Returns: Вид-снимок.
    private func makeDragView(forItemID itemID: AnyHashable) -> UIView? {
        if let snapshot = grid.snapshotView(forItemID: itemID) {
            return snapshot
        }
        guard let cell = grid.cellView(forItemID: itemID) else { return nil }
        return cell.resizableSnapshotView(
            from: cell.bounds,
            afterScreenUpdates: true,
            withCapInsets: .zero
        )
    }

    /// Ведёт снимок за пальцем и обновляет цель под ним.
    ///
    /// Внутренний шаг drag-сессии: жест координатора вызывает его из `.changed`,
    /// а тесты E4.7 — напрямую через `@testable import`, чтобы прогонять
    /// перестановку без симуляции касаний.
    ///
    /// - Parameter point: Текущая точка пальца в координатах сетки.
    func updateDrag(to point: CGPoint) {
        guard let session = dragSession else { return }

        session.lastPoint = point
        session.dragView.center = CGPoint(
            x: point.x + session.grabOffset.x,
            y: point.y + session.grabOffset.y
        )
        updateHoverTargets(at: point)
    }

    /// Пересчитывает цель под пальцем, «расступание» соседей и подсветку.
    ///
    /// Решение принимается по рамкам модели, а не по `grid.item(at:)`: исходная
    /// ячейка скрыта, но остаётся в раскладке и перехватила бы хит-тест.
    ///
    /// - Parameter point: Точка пальца в координатах сетки.
    private func updateHoverTargets(at point: CGPoint) {
        guard let session = dragSession else { return }

        var target: HoverTarget = .none

        if grid.bounds.insetBy(dx: -8, dy: -8).contains(point),
           let hovered = item(under: point, excluding: session.itemID),
           let frame = grid.frame(forItemID: hovered.id) {

            switch hovered {
            case .folder(let folder):
                if session.isTile {
                    // Ярлык над папкой — добавление (D14), папка не переезжает.
                    target = .folder(folder.id)
                } else if let index = grid.index(ofItemID: hovered.id) {
                    target = .reorder(hovered.id, index: index)
                }

            case .tile(let tile):
                if session.isTile, isPointInDropCenter(point, of: frame) {
                    // Центр ярлыка — создание папки из двух ярлыков (D14).
                    target = .group(tile.id)
                } else if let index = grid.index(ofItemID: hovered.id) {
                    target = .reorder(hovered.id, index: index)
                }
            }
        }

        // «Расступание»: переставляем модель, layout переупаковывается и
        // доезжает batch-анимацией сетки (§3, §5). Пустышка переезжает в новый
        // слот перетаскиваемой плитки той же длительностью, что и соседи.
        if case .reorder(_, let index) = target,
           grid.index(ofItemID: session.itemID) != index,
           store.move(session.itemID, toIndex: index) {
            session.modelChanged = true
            render(animated: true)
            animatePlaceholder(to: currentFrame(of: session))
        }

        guard session.hover != target else {
            updateDropHighlightFrame()
            return
        }
        session.hover = target
        updateDropHighlight(for: target)
    }

    /// Анимирует пустышку к новой рамке при «расступании» соседей.
    ///
    /// - Parameter frame: Новая рамка в координатах сетки.
    private func animatePlaceholder(to frame: CGRect) {
        guard let placeholder = dragSession?.placeholder else { return }
        guard placeholder.frame != frame else { return }

        UIView.animate(
            withDuration: 0.24,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: {
                placeholder.frame = frame
            },
            completion: nil
        )
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

    // MARK: - Подсветка цели

    /// Показывает/прячет подсветку плитки-цели.
    ///
    /// - Parameter target: Текущая цель под пальцем.
    private func updateDropHighlight(for target: HoverTarget) {
        switch target {
        case .none, .reorder:
            hideDropHighlight()

        case .folder(let itemID):
            showDropHighlight(for: itemID, style: .folder)

        case .group(let itemID):
            showDropHighlight(for: itemID, style: .group)
        }
    }

    /// Досчитывает рамку уже показанной подсветки (после переупаковки).
    private func updateDropHighlightFrame() {
        guard let session = dragSession, let view = dropHighlightView, !view.isHidden else {
            return
        }

        switch session.hover {
        case .folder(let itemID), .group(let itemID):
            if let frame = grid.frame(forItemID: itemID) {
                view.frame = frame
            }
        case .none, .reorder:
            break
        }
    }

    /// Показывает подсветку на рамке элемента.
    ///
    /// - Parameters:
    ///   - itemID: Элемент-цель.
    ///   - style: Тип цели (папка или создание папки).
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
        view.frame = frame
        view.isHidden = false
    }

    /// Прячет подсветку цели.
    private func hideDropHighlight() {
        dropHighlightView?.isHidden = true
    }

    // MARK: - Drag: финал

    /// Завершает перетаскивание.
    ///
    /// Внутренний шаг drag-сессии (жест — `.ended`/`.cancelled`); тесты E4.7
    /// вызывают его через `@testable import`, чтобы завершить перестановку без
    /// симуляции касаний.
    ///
    /// - Parameter commit: `true` — применить drop, `false` — откатить к
    ///   исходному индексу (жест отменён).
    func finishDrag(commit: Bool) {
        guard let session = dragSession else { return }

        defer { endDragStoreTransaction(saveIfNeeded: session.modelChanged) }

        stopTicker()
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

        case .group(let targetID) where session.isTile:
            dropIntoNewFolder(session, targetID: targetID)

        default:
            let finalIndex = grid.index(ofItemID: session.itemID) ?? session.initialIndex
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
        restore(session)
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

    /// Откатывает перестановку к исходному индексу.
    ///
    /// - Parameter session: Drag-сессия.
    private func restore(_ session: TesseraTileDragSession) {
        guard grid.index(ofItemID: session.itemID) != nil else { return }
        guard store.move(session.itemID, toIndex: session.initialIndex) else { return }
        render(animated: true)
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
        session.dragView.removeFromSuperview()
        session.placeholder.removeFromSuperview()
        hideDropHighlight()

        if unhide {
            grid.setItemHidden(false, forItemID: session.itemID)
        }
        reconcileEditControls(animated: false)
    }

    /// Немедленно отменяет drag (выход из режима редактирования, фон).
    private func cancelDragImmediately() {
        guard let session = dragSession else { return }

        stopTicker()
        dragSession = nil
        grid.isScrollEnabled = true
        hideDropHighlight()

        restore(session)
        session.dragView.removeFromSuperview()
        session.placeholder.removeFromSuperview()
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
    /// Модель меняется на каждом «расступании», а `TileStore.save()` синхронный:
    /// без транзакции drag писал бы JSON десятки раз. Состояние сохраняется один
    /// раз в ``endDragStoreTransaction(saveIfNeeded:)``.
    private func beginDragStoreTransaction() {
        guard autosavesBeforeDrag == nil else { return }
        autosavesBeforeDrag = store.autosaves
        store.autosaves = false
    }

    /// Восстанавливает автосохранение и при необходимости пишет состояние.
    ///
    /// - Parameter saveIfNeeded: Были ли изменения модели за время drag.
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

    /// Создаёт или обновляет крестики/стрелки у видимых плиток.
    ///
    /// Кнопки — подвью сетки, а не ячеек: так они не страдают от
    /// переиспользования ячеек и ездят вместе с плиткой обновлением `frame`
    /// в обработчике прокрутки (без layout сетки).
    ///
    /// - Parameter animated: Анимировать ли переезд кнопок при resize/reorder.
    private func reconcileEditControls(animated: Bool) {
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
            // кнопками получает ту же анимацию и фазу, чтобы крестик/стрелка
            // вращались вместе с плиткой вокруг её центра.
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

    /// Обновляет `frame`/видимость оверлеев при прокрутке.
    ///
    /// Вызывается из наблюдения за `contentOffset`; кроме `frame` и `isHidden`
    /// здесь ничего не меняется (CORE-IOS-DESIGN.md §2).
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

    /// Перестановка к индексу элемента `id`.
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

    /// Индекс на момент захвата — для отката при отмене/отказе.
    let initialIndex: Int

    /// Ярлык ли это (папку нельзя бросить в папку — вложенности нет).
    let isTile: Bool

    /// Смещение центра снимка относительно пальца.
    let grabOffset: CGPoint

    /// Снимок, едущий за пальцем.
    let dragView: UIView

    /// Пустышка на месте плитки.
    let placeholder: UIView

    /// Последняя точка пальца в координатах сетки.
    var lastPoint: CGPoint

    /// Текущая цель под пальцем.
    var hover: HoverTarget = .none

    /// Менялась ли модель за время drag (нужно для единственного сохранения).
    var modelChanged = false

    init(
        itemID: AnyHashable,
        initialIndex: Int,
        isTile: Bool,
        grabOffset: CGPoint,
        dragView: UIView,
        placeholder: UIView,
        lastPoint: CGPoint
    ) {
        self.itemID = itemID
        self.initialIndex = initialIndex
        self.isTile = isTile
        self.grabOffset = grabOffset
        self.dragView = dragView
        self.placeholder = placeholder
        self.lastPoint = lastPoint
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

    /// Нажатие на крестик.
    var onUnpin: (() -> Void)?

    /// Нажатие на стрелку размера.
    var onResize: (() -> Void)?

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
            symbolName: "xmark",
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
    ///   - canUnpin: Показывать ли крестик (у папки его нет).
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

        // Крестик — в верхнем углу по направлению чтения, стрелка — в нижнем
        // противоположном (§9, RTL).
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

    /// Крестик.
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
final class TesseraTileDropHighlightView: UIView {

    /// Тип цели.
    enum Style {

        /// Папка: ярлык будет добавлен.
        case folder

        /// Ярлык: будет создана папка.
        case group
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

    /// Обновляет адаптивные цвета.
    private func updateColors() {
        let color: UIColor
        switch style {
        case .folder:
            color = .systemBlue
        case .group:
            color = .systemOrange
        }
        layer.borderColor = color.cgColor
        backgroundColor = color.withAlphaComponent(0.12)
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
