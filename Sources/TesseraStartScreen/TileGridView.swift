//
//  TileGridView.swift
//  TesseraStartScreen
//
//  Сетка ярлыков и папок рабочего стола: UICollectionView с кастомной
//  раскладкой плюс фасад для хоста и режима редактирования.
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md — §2 «Архитектура»
//  (StartPage: TileGridView — UICollectionView + кастомный layout), §3
//  «Плиточная сетка» (юниты, четыре размера, кастомный layout, инвалидация),
//  §4 «Live-плитки» (live-контент ярлыка обслуживает один
//  `TesseraLiveTileEngine` на сетку: стахгер, флипы, паузы, Reduce Motion;
//  бэйдж — отдельный view контейнера, не часть флипа), §5 «Режим
//  редактирования» (хуки для E4.4: снэпшот, пустышка, инвалидация), §8
//  «Параллакс фона» (колбэк прокрутки отдаёт offset наружу; в самом
//  scrollViewDidScroll ничего не раскладывается) и §9 «Accessibility»
//  (VoiceOver, Dynamic Type, RTL).
//  Уточнения пользователя: D12 (ярлык — действие), D14 (папки — элемент
//  сетки), D15 (четыре размера и live-плитки) — docs/STATE.md; §14
//  STARTSCREEN-IOS-DESIGN.md.
//  Задача плана: E4.2-UI (live-контент подключён в E5).
//
//  Границы ответственности:
//  - сетка только отображает снимок TileGridSnapshot (E4.2) и сообщает о
//    тапах/долгом нажатии; порядок, размеры, папки и действия — за TileStore и
//    хостом (правило «один писатель», §6);
//  - live-контент ярлыка (§4) обслуживает ``TesseraLiveTileEngine``: сетка
//    держит один движок на все ячейки, регистрирует контейнер при показе
//    ячейки и ставит на паузу при уходе с экрана; флипы, стахгер, паузы и
//    Reduce Motion остаются внутри движка, ячейка лишь отдаёт контейнер;
//  - в `scrollViewDidScroll` выполняется только `onScrollOffsetChanged`:
//    ни `layoutIfNeeded`, ни `invalidateLayout`, ни `reloadData` (§3, §8,
//    CORE-IOS-DESIGN.md §2). Параллакс — frame/transform/alpha на стороне
//    подписчика (E4.6).
//

#if canImport(UIKit)
import UIKit
import TesseraCore

/// Сетка ярлыков и папок рабочего стола (docs/STARTSCREEN-IOS-DESIGN.md §2, §3).
///
/// ## Использование
///
/// ```swift
/// let grid = TesseraTileGridView()
/// grid.onTap = { item in
///     switch item {
///     case .tile(let tile): tile.action()
///     case .folder: host.openFolder(item.id)   // навигация — за хостом (D14)
///     }
/// }
/// grid.onLongPress = { item, point in editCoordinator.beginEditing(at: item, point: point) }
/// grid.onScrollOffsetChanged = { offset in background.apply(offsetY: offset.y) }
/// grid.reload(snapshot: store.snapshot())
/// ```
///
/// ## Данные
///
/// Единственный вход данных — ``reload(snapshot:)`` и
/// ``update(snapshot:animated:)``. Сетка не ходит в `TileStore` сама: хост
/// передаёт снимок после каждого изменения (`TileStore.onChange`), поэтому
/// экран и список приложений (§6) читают одно и то же состояние.
///
/// ## Live-плитки (§4)
///
/// Живой контент задаётся провайдером в ``TileDescriptor/liveContent``: сетка
/// создаёт один ``TesseraLiveTileEngine`` на себя, а ячейка с таким ярлыком
/// показывает ``TesseraLiveTileView`` вместо статичной иконки и заголовка.
/// Бэйдж остаётся снаружи флипа (им владеет контейнер).
///
/// Жизненный цикл:
/// - регистрация — в `willDisplay` (ячейка действительно на экране);
/// - пауза — в `didEndDisplaying` и ``setItemHidden(_:forItemID:)``:
///   движок сбрасывает незавершённый флип и не планирует новые;
/// - снятие регистрации — в `prepareForReuse`, как требует контракт движка;
/// - Reduce Motion — движок показывает статичный фронт, сетка его не дублирует.
///
/// Расписание (`cycleInterval`, `flipDuration` и т. п.) настраивается через
/// ``liveTileConfiguration``; провайдерам без подписки доступен явный
/// ``refreshLiveTile(forItemID:)``.
///
/// ## Прокрутка и параллакс
///
/// ``onScrollOffsetChanged`` вызывается из `scrollViewDidScroll` с текущим
/// `contentOffset`. Внутри сетки в этот момент не выполняется ни одной
/// layout-операции (§3, §8): подписчик сам решает, что двинуть —
/// `transform`/`frame`/`alpha` фона. При Reduce Motion подписчик обязан
/// отключить параллакс (§9, E4.6), сетка настройку не проверяет.
///
/// ## Режим редактирования (подготовка для E4.4)
///
/// Сетка не реализует «желе», drag и resize — это задача `TileEditCoordinator`
/// (E4.4). Наружу отдаются ровно те примитивы, которых координатору не хватает:
///
/// - ``frame(forItemID:)`` — рамка плитки в координатах сетки (для наложения
///   слоя перетаскивания и расчёта «расступания»);
/// - ``item(at:)`` — хит-тест точки в координатах сетки (под пальцем/курсором);
/// - ``snapshotView(forItemID:)`` — снимок видимой ячейки для drag; `nil`,
///   если ячейка не видна;
/// - ``cellView(forItemID:)`` — сама видимая ячейка для «желе» и подсветки
///   (менять можно только `transform`/`alpha`, но не `frame`);
/// - ``placeholderView(forItemID:)`` — готовый вид-пустышка с рамкой плитки
///   (ещё не добавлен в иерархию; владелец — координатор);
/// - ``setItemHidden(_:forItemID:)`` — скрыть исходную ячейку, не меняя
///   раскладку (alpha 0 + исключение из VoiceOver);
/// - ``update(snapshot:animated:)`` — применить новый снимок с анимацией
///   resize/reorder (сдвиг соседних плиток анимирует UICollectionView);
/// - ``invalidateTileLayout(animated:)`` — пересчитать геометрию без смены
///   снимка (например, после смены ширины контейнера или настроек сетки);
/// - ``contentOffset``/``setContentOffset(_:animated:)``/``contentSize``/
///   ``isScrollEnabled`` — для автоскролла у краёв во время перетаскивания.
///
/// Сетка не запускает drag-жест сама: долгое нажатие только сообщает точку
/// старта (``onLongPress``), дальнейшее ведение пальца — за координатором,
/// иначе жест перетаскивания конфликтует с прокруткой и с правом хоста
/// настраивать редактирование.
///
/// ## Accessibility (§9)
///
/// - плитка — один элемент VoiceOver с признаком кнопки; заголовок — label,
///   счётчик бэйджа — value;
/// - папка — один элемент с числом ярлыков в value;
/// - Dynamic Type: шрифт заголовка пересобирается при смене категории;
/// - RTL: порядок элементов задаётся раскладкой, иконка и бэйдж зеркалятся.
///
/// ## Поля и safe area
///
/// Сетка не подмешивает `safeAreaInsets` автоматически
/// (`contentInsetAdjustmentBehavior = .never`): внешние поля задаются
/// ``contentInsets``, и хост сам решает, сложить ли их с безопасной зоной.
/// Это держит формулу юнита §3 в одном месте.
///
/// Все методы — главный поток: UIKit-вью не рассчитана на фоновые вызовы
/// (docs/CORE-IOS-DESIGN.md §3).
public final class TesseraTileGridView: UIView {

    // MARK: - Публичные колбэки

    /// Тап по ярлыку или папке.
    ///
    /// Сетка не выполняет действие ярлыка сама (D12): она отдаёт элемент, а
    /// хост решает, вызвать `TileDescriptor.action` или открыть папку. Выбор
    /// папки выполняется хостом — вложенность и навигация в модель не входят
    /// (D14).
    public var onTap: ((TileGridItem) -> Void)?

    /// Долгое нажатие по элементу — вход в режим редактирования (E4.4).
    ///
    /// Второй параметр — точка нажатия в координатах сетки: с неё координатор
    /// запускает снэпшот и перетаскивание. Если замыкание не задано, жест
    /// долгого нажатия отключён и не мешает обычным тапам.
    public var onLongPress: ((TileGridItem, CGPoint) -> Void)? {
        didSet {
            longPressRecognizer.isEnabled = onLongPress != nil
        }
    }

    /// Изменение `contentOffset` при прокрутке сетки (§8).
    ///
    /// Вызывается из `scrollViewDidScroll`; внутри сетки в этот момент нет
    /// layout-операций, поэтому подписчик обязан сам ограничиться
    /// `frame`/`transform`/`alpha` (CORE-IOS-DESIGN.md §2).
    public var onScrollOffsetChanged: ((CGPoint) -> Void)?

    // MARK: - Публичные данные

    /// Последний применённый снимок сетки.
    ///
    /// Снимок — значение из `TileStore`: сетка его не меняет, только
    /// отображает. Хост передаёт новый снимок через ``reload(snapshot:)`` или
    /// ``update(snapshot:animated:)``. Наружу (в публичный API) отдаются только
    /// ``items``: координатору редактирования снимок доступен внутри модуля,
    /// а хосту достаточно самих элементов.
    private(set) var snapshot: TileGridSnapshot?

    /// Элементы сетки в порядке отображения (удобный доступ к снимку).
    public var items: [TileGridItem] {
        snapshot?.items ?? []
    }

    // MARK: - Live-плитки (§4)

    /// Параметры расписания live-флипов (§4).
    ///
    /// По умолчанию — значения ``TesseraLiveTileEngine/Configuration``. Смена
    /// применяется к уже созданному ``liveTileEngine`` сразу: движок
    /// перепланирует цикл и обновит длительность флипа у зарегистрированных
    /// плиток. Сетке без живых плиток настройка ничего не создаёт.
    public var liveTileConfiguration: TesseraLiveTileEngine.Configuration {
        get { storedLiveTileConfiguration }
        set {
            storedLiveTileConfiguration = newValue
            storedLiveTileEngine?.configuration = newValue
        }
    }

    /// Движок живых плиток сетки (docs/STARTSCREEN-IOS-DESIGN.md §4).
    ///
    /// Один на сетку: ячейки переиспользуются, движок — нет. Создаётся при
    /// первом обращении, то есть при первой live-плитке в снимке: статичному
    /// рабочему столу таймеры и подписки не нужны. Движок сам считает стахгер,
    /// держит паузы (вне экрана, фон, Reduce Motion) и удерживает
    /// зарегистрированные контейнеры — сетка обязана снимать регистрацию при
    /// уходе ячейки с экрана, что и делает в `didEndDisplaying`/`prepareForReuse`.
    public var liveTileEngine: TesseraLiveTileEngine {
        if let engine = storedLiveTileEngine {
            return engine
        }
        let engine = TesseraLiveTileEngine(configuration: storedLiveTileConfiguration)
        storedLiveTileEngine = engine
        return engine
    }

    /// Перечитывает live-контент видимой плитки (§4).
    ///
    /// Нужен провайдерам без подписки `startObservingChanges` (v1, §10): после
    /// изменения своего состояния они просят хост обновить плитку. Провайдеры
    /// с подпиской получают то же самое автоматически. Обновление не запускает
    /// флип — расписание остаётся прежним.
    ///
    /// - Parameter id: Идентификатор ярлыка. Для статичной плитки, папки и
    ///   элемента вне экрана вызов ничего не делает.
    public func refreshLiveTile(forItemID id: AnyHashable) {
        guard let cell = cellView(forItemID: id) as? TesseraTileCell,
              let liveTileView = cell.liveTileView,
              let engine = storedLiveTileEngine else {
            return
        }
        engine.refresh(liveTileView)
    }

    // MARK: - Конфигурация раскладки

    /// Число колонок сетки, по умолчанию 4 (§3; 6 — опция для больших экранов,
    /// отрезана в v1 §10).
    ///
    /// Менять до показа или вместе со сменой ширины экрана: сетка сразу
    /// инвалидирует раскладку, но не анимирует это изменение — анимировать
    /// число колонок в v1 не требуется.
    public var columns: Int {
        get { tileLayout.columns }
        set { tileLayout.columns = newValue }
    }

    /// Внешние поля сетки в точках. По умолчанию 16 со всех сторон.
    ///
    /// Задаются раскладке, а не `collectionView.contentInset`: у сетки один
    /// источник полей, иначе формула юнита §3 начала бы двоиться.
    public var contentInsets: UIEdgeInsets {
        get { tileLayout.contentInsets }
        set { tileLayout.contentInsets = newValue }
    }

    /// Зазор между соседними юнитами сетки в точках. По умолчанию 8.
    public var itemSpacing: CGFloat {
        get { tileLayout.itemSpacing }
        set { tileLayout.itemSpacing = newValue }
    }

    // MARK: - Прокрутка

    /// Текущее смещение прокрутки сетки.
    public var contentOffset: CGPoint {
        collectionView.contentOffset
    }

    /// Размер прокручиваемого контента сетки.
    ///
    /// Берётся у раскладки, а не у `collectionView.contentSize`: UICollectionView
    /// обновляет свой `contentSize` в конце layout-прохода, а координатору
    /// перетаскивания значение нужно сразу после ``update(snapshot:animated:)``.
    public var contentSize: CGSize {
        tileLayout.collectionViewContentSize
    }

    /// Включена ли прокрутка сетки.
    ///
    /// Координатор редактирования (E4.4) отключает её на время перетаскивания,
    /// если ведёт автоскролл у краёв сам; иначе палец прокручивал бы сетку и
    /// перетаскивал плитку одновременно.
    public var isScrollEnabled: Bool {
        get { collectionView.isScrollEnabled }
        set { collectionView.isScrollEnabled = newValue }
    }

    // MARK: - Внутреннее состояние

    /// Раскладка сетки; наружу не выходит — её настраивают свойства выше.
    private let tileLayout: TesseraTileCollectionViewLayout

    /// Коллекция ячеек.
    private let collectionView: UICollectionView

    /// Жест долгого нажатия (включается только при заданном ``onLongPress``).
    private let longPressRecognizer = UILongPressGestureRecognizer()

    /// Элементы, скрытые координатором редактирования.
    ///
    /// Хранятся по идентификатору, а не по индексу: после переупорядочивания
    /// или перезагрузки индекс меняется, а скрытым должен остаться тот же
    /// элемент. Раскладку скрытие не меняет — место плитки сохраняется.
    private var hiddenItemIDs: Set<AnyHashable> = []

    /// Идентификатор ячейки сетки.
    private static let cellReuseIdentifier = "TesseraTileCell"

    /// Движок live-плиток; `nil` — сетка ещё не встречала live-контент.
    ///
    /// Храним отдельно от вычисляемого ``liveTileEngine``, чтобы
    /// ``liveTileConfiguration`` не создавал движок (и его наблюдатели) сетке
    /// без живых плиток.
    private var storedLiveTileEngine: TesseraLiveTileEngine?

    /// Параметры, с которыми будет создан ``liveTileEngine``.
    private var storedLiveTileConfiguration = TesseraLiveTileEngine.Configuration()

    // MARK: - Инициализация

    /// Создаёт пустую сетку.
    ///
    /// - Parameter frame: Начальный кадр; обычно сетку раскладывает хост.
    public override init(frame: CGRect) {
        let layout = TesseraTileCollectionViewLayout()
        tileLayout = layout
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        commonInit()
    }

    /// Создаёт сетку из архива/сториборда.
    ///
    /// - Parameter coder: Декодер архива.
    public required init?(coder: NSCoder) {
        let layout = TesseraTileCollectionViewLayout()
        tileLayout = layout
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Общая настройка: коллекция, ячейка, жест и Dynamic Type.
    private func commonInit() {
        backgroundColor = .clear
        // §9: сетка — контейнер, элементы — ячейки; сама она не элемент.
        isAccessibilityElement = false

        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        // Поля сетки живут в раскладке; contentInset коллекции не трогаем,
        // иначе формула юнита §3 получила бы вторую поправку.
        collectionView.contentInset = .zero
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            TesseraTileCell.self,
            forCellWithReuseIdentifier: TesseraTileGridView.cellReuseIdentifier
        )

        longPressRecognizer.minimumPressDuration = 0.45
        longPressRecognizer.delegate = self
        longPressRecognizer.addTarget(self, action: #selector(handleLongPress(_:)))
        // Пока хост не задал onLongPress, жест выключен и не перехватывает
        // касания у обычных тапов.
        longPressRecognizer.isEnabled = false
        collectionView.addGestureRecognizer(longPressRecognizer)

        addSubview(collectionView)

        // §9, Dynamic Type: шрифты ячеек пересобираются при смене категории.
        // Один наблюдатель на сетку вместо наблюдателя в каждой ячейке.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
    }

    // MARK: - Размер

    public override func layoutSubviews() {
        super.layoutSubviews()
        if collectionView.frame != bounds {
            collectionView.frame = bounds
        }
    }

    // MARK: - Данные

    /// Заменяет снимок сетки без анимации.
    ///
    /// Используется при первом показе, после `TileStore.load()` и там, где
    /// хост сам анимирует изменение (например, fly-out при unpin в E4.4).
    ///
    /// - Parameter snapshot: Новый снимок сетки.
    public func reload(snapshot: TileGridSnapshot) {
        apply(snapshot, animated: false)
    }

    /// Применяет снимок с анимацией resize/reorder (§5).
    ///
    /// Если состав тот же (меняются только размеры и порядок), UICollectionView
    /// анимирует перестановку ячеек, а раскладка переупаковывается через
    /// инвалидацию с контекстом (§3). При смене состава (pin/unpin) сетка
    /// делает кроссфейд: точечные insert/delete анимирует координатор
    /// редактирования, если ему нужен собственный эффект (E4.4).
    ///
    /// При Reduce Motion (§9) анимация отключается: снимок применяется сразу.
    ///
    /// - Parameters:
    ///   - newSnapshot: Новый снимок сетки.
    ///   - animated: Анимировать ли изменение, если сетка на экране.
    public func update(snapshot newSnapshot: TileGridSnapshot, animated: Bool) {
        let oldIDs = snapshot?.items.map { $0.id } ?? []
        let newIDs = newSnapshot.items.map { $0.id }
        let shouldAnimate = animated
            && window != nil
            && !TesseraAccessibility.isReduceMotionEnabled

        hiddenItemIDs.formIntersection(newIDs)

        guard shouldAnimate, !oldIDs.isEmpty else {
            apply(newSnapshot, animated: shouldAnimate)
            return
        }

        if Set(oldIDs) == Set(newIDs) {
            // Состав тот же: resize/reorder. Снимок обновляем до batch updates,
            // чтобы dataSource уже отдавал новые элементы, а раскладку
            // переупаковываем внутри того же прохода — тогда UICollectionView
            // анимирует сдвиг соседних плиток сам (§3, §5).
            snapshot = newSnapshot

            // Если порядок не менялся (только resize/бэйджи), содержимое ячеек
            // можно обновить сразу — переезжать им не с чем. При перестановке
            // содержимое приедет с ячейкой, а обновим его по завершении.
            if oldIDs == newIDs {
                refreshVisibleCells()
            }

            collectionView.performBatchUpdates({
                self.tileLayout.setItems(newSnapshot.items, reason: .items)
                self.applyIndexMoves(from: oldIDs, to: newIDs)
            }, completion: { [weak self] _ in
                self?.refreshVisibleCells()
            })
        } else {
            apply(newSnapshot, animated: true)
        }
    }

    /// Применяет снимок к коллекции.
    ///
    /// - Parameters:
    ///   - newSnapshot: Новый снимок.
    ///   - animated: Кроссфейд при смене состава; вызов уже учитывает Reduce
    ///     Motion.
    private func apply(_ newSnapshot: TileGridSnapshot, animated: Bool) {
        snapshot = newSnapshot
        hiddenItemIDs.formIntersection(newSnapshot.items.map { $0.id })

        let update = {
            self.tileLayout.setItems(newSnapshot.items, reason: .items)
            self.collectionView.reloadData()
        }

        if animated, window != nil {
            UIView.transition(
                with: collectionView,
                duration: 0.2,
                options: [.transitionCrossDissolve, .allowUserInteraction],
                animations: update,
                completion: nil
            )
        } else {
            update()
        }
    }

    /// Переставляет ячейки вслед за моделью, чтобы анимация везла каждую плитку
    /// с её содержимым.
    ///
    /// Для каждой плитки, съехавшей с прежнего места, отправляется один
    /// `moveItem`: `from` — индекс в исходном порядке, `to` — индекс в новом.
    /// Это контракт batch-обновлений UICollectionView (как у IGListKit): все
    /// перемещения описываются в координатах «до/после» одной пачкой, а не
    /// последовательно, поэтому обмен двух плиток — это два встречных move.
    /// Метод вызывается только когда состав тот же, поэтому перемещения не
    /// меняют число элементов коллекции.
    ///
    /// - Parameters:
    ///   - oldIDs: Идентификаторы в прежнем порядке.
    ///   - newIDs: Идентификаторы в новом порядке.
    private func applyIndexMoves(from oldIDs: [AnyHashable], to newIDs: [AnyHashable]) {
        for (oldIndex, itemID) in oldIDs.enumerated() {
            guard let newIndex = newIDs.firstIndex(of: itemID), newIndex != oldIndex else {
                continue
            }

            collectionView.moveItem(
                at: IndexPath(item: oldIndex, section: 0),
                to: IndexPath(item: newIndex, section: 0)
            )
        }
    }

    /// Перечитывает содержимое видимых ячеек без перезагрузки коллекции.
    ///
    /// Нужно после анимированного resize/reorder: рамки и порядок уже
    /// обновлены, а бэйдж/размер могли измениться у ячеек, которые не
    /// переезжали. Раскладка при этом не вызывается.
    private func refreshVisibleCells() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: indexPath) as? TesseraTileCell,
                  let item = item(atIndex: indexPath.item) else {
                continue
            }
            configure(cell, with: item, isVisible: true)
        }
    }

    /// Настраивает ячейку под элемент и подписывает её активацию VoiceOver.
    ///
    /// Ячейка — один accessibility-элемент (§9), поэтому двойной тап VoiceOver
    /// приходит в неё, а не в `didSelectItemAt`. Замыкание переводит активацию
    /// в тот же ``onTap``, что и обычный тап.
    ///
    /// - Parameters:
    ///   - cell: Ячейка сетки.
    ///   - item: Элемент, который она показывает.
    ///   - isVisible: Показывается ли ячейка на экране. Для `false` движок не
    ///     создаётся вовсе: `cellForItemAt` лишь готовит ячейку, а регистрацию
    ///     в движке выполняет `willDisplay`.
    private func configure(_ cell: TesseraTileCell, with item: TileGridItem, isVisible: Bool) {
        // Движок создаётся только для live-ярлыка: статичной плите и папке
        // расписание флипов не нужно.
        let engine = isVisible ? liveEngine(for: item) : nil
        // Скрытая на время drag ячейка не должна флипаться «в себя», но её
        // регистрация нужна: возврат из скрытия возобновит расписание без
        // повторного `willDisplay`.
        let isHidden = hiddenItemIDs.contains(item.id)
        cell.configure(
            with: item,
            liveTileEngine: engine,
            isVisible: isVisible && !isHidden
        )
        cell.setSourceHidden(isHidden)

        let itemID = item.id
        cell.onActivate = { [weak self] in
            self?.activate(itemID: itemID)
        }
    }

    /// Движок для элемента: `nil` — ярлык статичный или это папка.
    ///
    /// Обращение к ``liveTileEngine`` лениво создаёт движок, поэтому сетка без
    /// live-контента не заводит таймеров и наблюдателей.
    ///
    /// - Parameter item: Элемент сетки.
    /// - Returns: Движок либо `nil`, если живой стороны у элемента нет.
    private func liveEngine(for item: TileGridItem) -> TesseraLiveTileEngine? {
        guard case .tile(let descriptor) = item, descriptor.liveContent != nil else {
            return nil
        }
        return liveTileEngine
    }

    /// Активация элемента VoiceOver: тот же путь, что у тапа пальцем.
    ///
    /// - Parameter itemID: Идентификатор ярлыка или папки.
    private func activate(itemID: AnyHashable) {
        guard !hiddenItemIDs.contains(itemID),
              let index = index(ofItemID: itemID),
              let item = item(atIndex: index) else {
            return
        }
        onTap?(item)
    }

    // MARK: - Запросы для хоста и редактирования

    /// Индекс элемента в порядке сетки.
    ///
    /// - Parameter id: Идентификатор ярлыка или папки.
    /// - Returns: Индекс или `nil`, если элемента нет в снимке.
    public func index(ofItemID id: AnyHashable) -> Int? {
        snapshot?.items.firstIndex { $0.id == id }
    }

    /// Элемент под точкой в координатах сетки.
    ///
    /// Хит-тест идёт по фактическим атрибутам ячеек: попадание в зазор или
    /// между строками даёт `nil`. Используется координатором перетаскивания,
    /// чтобы найти плитку под пальцем.
    ///
    /// - Parameter point: Точка в координатах сетки (не контента).
    /// - Returns: Элемент или `nil`.
    public func item(at point: CGPoint) -> TileGridItem? {
        let pointInCollection = collectionView.convert(point, from: self)
        guard let indexPath = collectionView.indexPathForItem(at: pointInCollection) else {
            return nil
        }
        return item(atIndex: indexPath.item)
    }

    /// Рамка элемента в координатах сетки.
    ///
    /// Координаты сетки — это `bounds` этого view: рамка уже учитывает
    /// `contentOffset` и поля. Для ячеек за пределами экрана рамка может быть
    /// отрицательной — это нормально, слой перетаскивания сам решает, что
    /// показывать.
    ///
    /// - Parameter id: Идентификатор ярлыка или папки.
    /// - Returns: Рамка в точках или `nil`, если элемента нет в снимке или сетка
    ///   ещё ни разу не раскладывалась.
    public func frame(forItemID id: AnyHashable) -> CGRect? {
        guard let contentFrame = tileLayout.frame(forItemID: id) else { return nil }
        return collectionView.convert(contentFrame, to: self)
    }

    /// Снимок видимой ячейки для перетаскивания (E4.4).
    ///
    /// Возвращает `cell.snapshotView(afterScreenUpdates: false)`: копию
    /// отрисованной ячейки. Для ячейки вне экрана и для ещё не разложенной
    /// коллекции возвращает `nil` — координатор должен начинать drag только по
    /// видимой плитке (под пальцем она видима по определению). Снимайте копию
    /// **до** ``setItemHidden(_:forItemID:)``: у скрытой ячейки снимок пустой.
    ///
    /// - Parameter id: Идентификатор ярлыка или папки.
    /// - Returns: Снимок ячейки или `nil`.
    public func snapshotView(forItemID id: AnyHashable) -> UIView? {
        cellView(forItemID: id)?.snapshotView(afterScreenUpdates: false)
    }

    /// Видимая ячейка элемента — для «желе» и подсветки в редактировании (E4.4).
    ///
    /// Координатор редактирования может навесить на неё анимации («желе» §5:
    /// `CAKeyframeAnimation` поворота ±2°) или изменить `alpha`. Менять `frame`
    /// и вложенную раскладку нельзя: позицией владеет
    /// `TesseraTileCollectionViewLayout`, а ручной frame-проход в обход layout
    /// сломает соответствие модели. Анимации координатор снимает сам по
    /// завершении редактирования; для «желе» надёжнее `CAAnimation` на слое
    /// ячейки/контента, чем `UIView.animate(transform:)`: UICollectionView
    /// применяет к ячейке layout attributes и сбрасывает `cell.transform`.
    ///
    /// - Parameter id: Идентификатор ярлыка или папки.
    /// - Returns: Ячейка или `nil`, если элемент не на экране.
    public func cellView(forItemID id: AnyHashable) -> UIView? {
        guard let indexPath = indexPath(forItemID: id) else { return nil }
        return collectionView.cellForItem(at: indexPath)
    }

    /// Готовая пустышка под плитку — место, откуда ярлык «взяли» (E4.4).
    ///
    /// Возвращает новый вид с рамкой плитки в координатах сетки, но **не
    /// добавляет его в иерархию**: владельцем пустышки остаётся координатор
    /// редактирования, который кладёт её под слой перетаскивания и убирает
    /// после отпускания. Вид не перехватывает касания и скрыт от VoiceOver.
    /// Пустышка не следит за прокруткой: если сетка прокручивается во время
    /// drag, координатор пересчитывает её `frame` по ``frame(forItemID:)``.
    ///
    /// - Parameter id: Идентификатор ярлыка или папки.
    /// - Returns: Вид-пустышка или `nil`, если элемента нет в снимке.
    public func placeholderView(forItemID id: AnyHashable) -> UIView? {
        guard let frame = frame(forItemID: id) else { return nil }
        return TesseraTilePlaceholderView(frame: frame)
    }

    /// Скрывает исходную ячейку на время перетаскивания (E4.4).
    ///
    /// Раскладку скрытие не меняет: место плитки остаётся занятым, поэтому
    /// остальные ярлыки не «прыгают». Скрытая ячейка получает `alpha = 0` и
    /// исключается из VoiceOver; после показа состояния снимка скрытие
    /// сохраняется до явного `false` или до исчезновения элемента из снимка.
    ///
    /// - Parameters:
    ///   - hidden: `true` — скрыть, `false` — вернуть.
    ///   - id: Идентификатор ярлыка или папки.
    public func setItemHidden(_ hidden: Bool, forItemID id: AnyHashable) {
        if hidden {
            hiddenItemIDs.insert(id)
        } else {
            hiddenItemIDs.remove(id)
        }

        guard let indexPath = indexPath(forItemID: id),
              let cell = collectionView.cellForItem(at: indexPath) as? TesseraTileCell else {
            return
        }
        cell.setSourceHidden(hidden)
        // Скрытая на время drag плитка не должна флипаться «в себя»: пауза
        // движка сбрасывает незавершённый флип и не планирует новые (§4,
        // «Паузы»). Возврат ячейки возобновляет расписание без перерегистрации.
        cell.setLiveTileVisible(!hidden)
    }

    /// Пересчитывает геометрию сетки без смены снимка (§3).
    ///
    /// Нужен, когда изменилась ширина/высота контейнера, поля, зазор или число
    /// колонок: модель та же, рамки другие. `animated` анимирует переезд
    /// ячеек через `performBatchUpdates`; при Reduce Motion анимация
    /// отключается (§9).
    ///
    /// - Parameter animated: Анимировать ли переезд ячеек.
    public func invalidateTileLayout(animated: Bool) {
        guard let snapshot else { return }

        let shouldAnimate = animated
            && window != nil
            && !TesseraAccessibility.isReduceMotionEnabled

        if shouldAnimate {
            collectionView.performBatchUpdates({
                self.tileLayout.setItems(snapshot.items, reason: .geometry)
            }, completion: { [weak self] _ in
                self?.refreshVisibleCells()
            })
        } else {
            tileLayout.setItems(snapshot.items, reason: .geometry)
            refreshVisibleCells()
        }
    }

    /// Прокручивает сетку. Используется автоскроллом при перетаскивании.
    ///
    /// - Parameters:
    ///   - offset: Целевое смещение; UIKit сам не зажимает программные
    ///     значения, поэтому границы — забота вызывающего.
    ///   - animated: Анимировать ли прокрутку.
    public func setContentOffset(_ offset: CGPoint, animated: Bool) {
        collectionView.setContentOffset(offset, animated: animated)
    }

    // MARK: - Внутренние помощники

    /// Элемент по индексу в снимке.
    private func item(atIndex index: Int) -> TileGridItem? {
        guard let snapshot, snapshot.items.indices.contains(index) else { return nil }
        return snapshot.items[index]
    }

    /// `IndexPath` элемента в текущей коллекции.
    private func indexPath(forItemID id: AnyHashable) -> IndexPath? {
        guard let index = index(ofItemID: id) else { return nil }
        return IndexPath(item: index, section: 0)
    }

    /// Долгое нажатие: сообщает элемент и точку старта, дальше ведёт хост.
    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, onLongPress != nil else { return }

        let point = recognizer.location(in: self)
        guard let item = item(at: point), !hiddenItemIDs.contains(item.id) else { return }
        onLongPress?(item, point)
    }

    /// §9, Dynamic Type: пересобрать шрифты видимых ячеек.
    @objc private func contentSizeCategoryDidChange() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            (collectionView.cellForItem(at: indexPath) as? TesseraTileCell)?.refreshTypography()
        }
    }

    /// §9, RTL: направление чтения изменилось — пересчитать раскладку и
    /// зеркалирование содержимого ячеек.
    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard previousTraitCollection?.layoutDirection != traitCollection.layoutDirection else {
            return
        }

        // Раскладка сама заметит смену направления в `shouldInvalidateLayout`,
        // но UICollectionView не обязан её опрашивать при смене trait'ов,
        // поэтому инвалидируем явно. Пересчёт заодно переконфигурирует ячейки
        // (иконка и бэйдж зеркалятся по направлению чтения).
        invalidateTileLayout(animated: false)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension TesseraTileGridView: UIGestureRecognizerDelegate {

    /// Разрешает координатору редактирования (E4.4) вести свой жест
    /// перетаскивания одновременно с долгим нажатием сетки.
    ///
    /// Одновременность разрешена только жестам на самой сетке или её коллекции
    /// (туда координатор и добавляет pan перетаскивания). С прокруткой сетки
    /// одновременность запрещена: иначе длинное нажатие срабатывало бы во время
    /// обычного скролла; с панорамным пейджером-родителем (E4.1) — тоже, иначе
    /// арбитраж осей в Core получил бы два активных жеста.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard otherGestureRecognizer !== collectionView.panGestureRecognizer else { return false }
        return otherGestureRecognizer.view === self || otherGestureRecognizer.view === collectionView
    }
}

// MARK: - UICollectionViewDataSource

extension TesseraTileGridView: UICollectionViewDataSource {

    /// Число элементов сетки.
    public func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        snapshot?.items.count ?? 0
    }

    /// Ячейка ярлыка или папки.
    ///
    /// Содержимое готовит ``configure(_:with:isVisible:)``: статичные иконка,
    /// заголовок и бэйдж либо live-контейнер, если у ярлыка есть
    /// ``TileDescriptor/liveContent``. Регистрация live-плитки в движке
    /// выполняется на `willDisplay`, а не здесь: ячейка, подготовленная для
    /// prefetch, может так и не появиться на экране.
    public func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: TesseraTileGridView.cellReuseIdentifier,
            for: indexPath
        )

        if let tileCell = cell as? TesseraTileCell,
           let item = item(atIndex: indexPath.item) {
            configure(tileCell, with: item, isVisible: false)
        }
        return cell
    }
}

// MARK: - UICollectionViewDelegate

extension TesseraTileGridView: UICollectionViewDelegate {

    /// Тап по элементу: сообщает намерение хосту (D12).
    public func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        collectionView.deselectItem(at: indexPath, animated: false)

        guard let item = item(atIndex: indexPath.item),
              !hiddenItemIDs.contains(item.id) else {
            return
        }
        onTap?(item)
    }

    /// Показ ячейки: регистрирует live-плитку в движке и возвращает скрытое
    /// состояние после переиспользования.
    ///
    /// Регистрация именно здесь, а не в `cellForItemAt`: UICollectionView
    /// сообщает о фактическом появлении ячейки на экране, включая возврат
    /// после прокрутки. Один движок на сетку при этом не пересоздаётся — он
    /// лишь получает контейнер и провайдера.
    public func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let tileCell = cell as? TesseraTileCell,
              let item = item(atIndex: indexPath.item) else {
            return
        }
        configure(tileCell, with: item, isVisible: true)
        // Динамический шрифт мог смениться, пока ячейка была вне экрана
        // (например, в prefetch): пересобираем метрики на показе.
        tileCell.refreshTypography()
    }

    /// Уход ячейки с экрана: live-плитка ставится на паузу (§4, «Паузы»).
    ///
    /// Движок сбрасывает незавершённый флип и не планирует новые, но
    /// сохраняет подписку провайдера и состояние сторон — возврат на экран не
    /// требует перерегистрации. Регистрацию окончательно снимает
    /// `prepareForReuse`, как требует контракт движка.
    public func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let tileCell = cell as? TesseraTileCell else { return }
        // UIKit может вызвать метод уже после переиспользования ячейки: если
        // она снова в коллекции, пауза относилась бы к другой (новой) плите.
        guard collectionView.indexPath(for: cell) == nil else { return }
        tileCell.setLiveTileVisible(false)
    }

    /// Прокрутка сетки: наружу отдаётся только offset — никакого layout
    /// (§3, §8, CORE-IOS-DESIGN.md §2).
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onScrollOffsetChanged?(scrollView.contentOffset)
    }
}

// MARK: - Ячейка сетки

/// Ячейка ярлыка или папки.
///
/// Одна ячейка на оба вида элементов: у ярлыка и папки одинаковый каркас
/// (иконка + заголовок в квадрате), различаются только содержимое и наличие
/// бэйджа. Это упрощает переиспользование, когда на месте ярлыка появляется
/// папка (D14: создание папки из ярлыка) — тип ячейки не меняется.
///
/// Ячейка не знает про layout: рамку задаёт раскладка, содержимое —
/// ``configure(with:liveTileEngine:isVisible:)``. В горячем пути скролла она не
/// участвует.
///
/// ## Live-контент (§4, D15)
///
/// Если у ярлыка задан ``TileDescriptor/liveContent``, статичные подвиды
/// (иконка, заголовок, бэйдж) уступают место ``TesseraLiveTileView``: он
/// рисует фронт и бэк, а его бэйдж живёт поверх сторон и не участвует во
/// флипе. Контейнер создаётся один раз и переиспользуется вместе с ячейкой —
/// пересоздание на каждом reuse сбрасывало бы флип и подписку провайдера.
/// Расписание флипов ведёт движок сетки, ячейка лишь сообщает ему видимость.
final class TesseraTileCell: UICollectionViewCell {

    /// Идентификатор элемента, который сейчас показан.
    private(set) var itemID: AnyHashable?

    /// Действие VoiceOver-активации (§9).
    ///
    /// Сетка подписывает замыкание при конфигурации ячейки: двойной тап
    /// VoiceOver попадает в accessibility-элемент плитки, а не в
    /// `collectionView(_:didSelectItemAt:)`.
    var onActivate: (() -> Void)?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()

    /// Бэйдж ярлыка — отдельный view поверх плитки (§4).
    ///
    /// Переиспользуется готовый ``TesseraLiveTileBadgeView`` из E4.3: он уже
    /// умеет точку/счётчик, «99+», Dynamic Type и не входит во флип. В
    /// live-режиме его заменяет бэйдж ``TesseraLiveTileView``.
    private let badgeView = TesseraLiveTileBadgeView()

    /// Контейнер живой плитки; `nil` — ячейка ещё не встречала live-контент.
    private(set) var liveTileView: TesseraLiveTileView?

    /// Показывает ли ячейка сейчас live-контент.
    private var showsLiveContent = false

    /// Движок, в котором зарегистрирован ``liveTileView``.
    ///
    /// Ссылка слабая: владелец движка — сетка. При `nil` (сетка уже
    /// освободилась) снимать регистрацию не с кого, и это безопасно.
    private weak var liveTileEngine: TesseraLiveTileEngine?

    /// Провайдер, с которым контейнер зарегистрирован в движке.
    ///
    /// Нужен, чтобы при повторной конфигурации не пересоздавать подписку:
    /// тот же провайдер — только обновление видимости и бэйджа.
    private weak var registeredLiveProvider: TesseraLiveTileContentProvider?

    /// Зарегистрирован ли ``liveTileView`` в ``liveTileEngine``.
    private var isLiveRegistered = false

    /// bucket размера, для которого собран шрифт (0 — компактные плитки,
    /// 1 — средние, 2 — крупные; границы — по фактической стороне).
    private var titleFontBucket = -1

    // MARK: - Инициализация

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    deinit {
        // Страховка на случай перезагрузки коллекции без `prepareForReuse`:
        // движок удерживает контейнер и провайдера, поэтому исчезнувшая
        // ячейка обязана снять свою регистрацию.
        if isLiveRegistered, let liveTileView {
            liveTileEngine?.unregister(liveTileView)
        }
    }

    /// Общая настройка: квадратная плитка, один accessibility-элемент (§9).
    private func setUp() {
        backgroundColor = .clear
        contentView.backgroundColor = .secondarySystemBackground
        contentView.clipsToBounds = true

        // §9: плитка — один элемент; иконка, заголовок и бэйдж — её части.
        isAccessibilityElement = true
        accessibilityTraits = .button

        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false
        iconView.clipsToBounds = true

        titleLabel.numberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textAlignment = .natural
        titleLabel.textColor = .label
        titleLabel.isAccessibilityElement = false
        // Шрифт собирается вручную в `updateTitleFontIfNeeded()`: сетка
        // оповещает ячейки о смене категории (см. `refreshTypography()`),
        // поэтому автоматическое масштабирование UILabel отключено — иначе
        // масштаб применился бы дважды.
        titleLabel.adjustsFontForContentSizeCategory = false

        contentView.addSubview(iconView)
        contentView.addSubview(titleLabel)
        // Бэйдж последним: он должен быть выше иконки и заголовка.
        contentView.addSubview(badgeView)

        badgeView.onBadgeChange = { [weak self] in
            self?.setNeedsLayout()
        }
    }

    // MARK: - Содержимое

    /// Применяет элемент сетки.
    ///
    /// Статичная плитка и папка рисуются как раньше (иконка + заголовок +
    /// бэйдж). Если у ярлыка есть ``TileDescriptor/liveContent``, содержимое
    /// отдаётся ``TesseraLiveTileView`` и регистрируется в движке.
    ///
    /// - Parameters:
    ///   - item: Ярлык или папка из снимка `TileStore`.
    ///   - engine: Движок live-плиток. `nil` — ячейка только готовится к показу
    ///     (`cellForItemAt`): стороны отрисовываются без расписания флипов.
    ///   - isVisible: Видима ли ячейка сейчас; движок не флипает невидимые
    ///     плитки (§4, «Паузы»).
    func configure(
        with item: TileGridItem,
        liveTileEngine engine: TesseraLiveTileEngine?,
        isVisible: Bool
    ) {
        itemID = item.id

        switch item {
        case .tile(let descriptor):
            if let provider = descriptor.liveContent {
                configureLiveContent(
                    provider: provider,
                    badge: descriptor.badge,
                    engine: engine,
                    isVisible: isVisible
                )
            } else {
                endLiveContent()
                configureStaticTile(descriptor)
            }
            configureAccessibility(for: descriptor)

        case .folder(let folder):
            endLiveContent()
            configureStaticFolder(folder)
            configureAccessibility(for: folder)
        }

        // Размер мог измениться (resize, D15): шрифт пересоберётся в layout.
        titleFontBucket = -1
        accessibilityElementsHidden = false
        contentView.alpha = 1
        setNeedsLayout()
    }

    /// Статичная плитка: иконка, заголовок и бэйдж ярлыка (прежнее поведение).
    private func configureStaticTile(_ descriptor: TileDescriptor) {
        iconView.image = descriptor.icon
        iconView.tintColor = nil
        titleLabel.text = descriptor.title
        badgeView.badge = descriptor.badge
    }

    /// Папка: иконка-превью или заглушка, заголовок; бэйджа у папки нет.
    private func configureStaticFolder(_ folder: TileFolder) {
        if let icon = folder.icon {
            iconView.image = icon
            iconView.tintColor = nil
        } else {
            // Иконка-заглушка папки; шаблонный символ красится в
            // secondaryLabel и адаптируется к тёмной теме.
            iconView.image = UIImage(systemName: "folder.fill")
            iconView.tintColor = .secondaryLabel
        }
        titleLabel.text = folder.title
        badgeView.badge = .none
    }

    // MARK: - Live-контент

    /// Готовит live-сторону: контейнер, бэйдж и регистрация в движке.
    ///
    /// - Parameters:
    ///   - provider: Провайдер контента ярлыка.
    ///   - badge: Бэйдж ярлыка (D12/D15) — рисуется контейнером поверх сторон.
    ///   - engine: Движок сетки; `nil` — предпросмотр без расписания.
    ///   - isVisible: Видима ли ячейка.
    private func configureLiveContent(
        provider: TesseraLiveTileContentProvider,
        badge: TileBadge,
        engine: TesseraLiveTileEngine?,
        isVisible: Bool
    ) {
        let liveView = liveTileView ?? makeLiveTileView()
        showsLiveContent = true

        // Фронт/бэк и бэйдж рисует контейнер: статичные подвиды уступают ему
        // место. Бэйдж контейнера не участвует во флипе (§4, D15).
        iconView.isHidden = true
        titleLabel.isHidden = true
        badgeView.isHidden = true
        liveView.isHidden = false
        liveView.badge = badge

        guard let engine else {
            // Ячейка ещё не показана: стороны без регистрации, чтобы движок не
            // планировал флипы для ячейки, которая может так и не появиться.
            if !isLiveRegistered {
                liveView.setFaces(front: provider.frontFace, back: provider.backFace)
                liveView.show(.front, animated: false)
            }
            return
        }

        attachLiveContent(
            of: provider,
            to: liveView,
            engine: engine,
            isVisible: isVisible
        )
    }

    /// Регистрирует контейнер в движке либо, если провайдер тот же,
    /// ограничивается обновлением видимости.
    ///
    /// Повторная регистрация на каждом обновлении снимка не нужна: движок
    /// удерживает провайдера и сам перечитывает стороны по подписке.
    private func attachLiveContent(
        of provider: TesseraLiveTileContentProvider,
        to liveView: TesseraLiveTileView,
        engine: TesseraLiveTileEngine,
        isVisible: Bool
    ) {
        if isLiveRegistered,
           registeredLiveProvider !== provider || liveTileEngine !== engine {
            // Провайдер или движок сменились: прежняя регистрация неактуальна.
            liveTileEngine?.unregister(liveView)
            isLiveRegistered = false
        }

        liveTileEngine = engine

        if isLiveRegistered {
            engine.setVisible(isVisible, for: liveView)
            return
        }

        registeredLiveProvider = provider
        // Новая регистрация всегда стартует с фронта: ячейка могла прийти из
        // reuse на бэке (движок при `unregister` сторону не меняет), а фронт —
        // устоявшееся состояние плитки (§4).
        liveView.show(.front, animated: false)
        engine.register(liveView, provider: provider, isVisible: isVisible)
        isLiveRegistered = true
    }

    /// Создаёт контейнер живой плитки один раз на ячейку.
    ///
    /// Контейнер не перехватывает касания и не является отдельным
    /// accessibility-элементом: тап и озвучивание остаются за ячейкой (§9,
    /// «плитка — один элемент»).
    private func makeLiveTileView() -> TesseraLiveTileView {
        let liveView = TesseraLiveTileView(frame: contentView.bounds)
        liveView.isAccessibilityElement = false
        liveView.isUserInteractionEnabled = false
        contentView.addSubview(liveView)
        liveTileView = liveView
        return liveView
    }

    /// Снимает live-режим: регистрация в движке отменяется, статичные подвиды
    /// возвращаются в раскладку.
    ///
    /// Сам контейнер не уничтожается — он переиспользуется, если ярлык снова
    /// окажется живым.
    private func endLiveContent() {
        if isLiveRegistered, let liveTileView {
            liveTileEngine?.unregister(liveTileView)
        }
        isLiveRegistered = false
        registeredLiveProvider = nil
        liveTileEngine = nil
        showsLiveContent = false
        // Переиспользованная ячейка уходит в устоявшееся состояние: после
        // `unregister` движок сторону не меняет, поэтому фронт выставляем сами.
        liveTileView?.show(.front, animated: false)
        liveTileView?.isHidden = true
        badgeView.isHidden = false
        iconView.isHidden = false
        titleLabel.isHidden = false
    }

    /// Ставит live-плитку на паузу или возобновляет её (§4, «Паузы»).
    ///
    /// Движок не флипает невидимую плитку и сбрасывает незавершённый флип, но
    /// сохраняет подписку провайдера и состояние сторон — возврат на экран не
    /// требует перерегистрации.
    ///
    /// - Parameter visible: Видима ли ячейка на экране.
    func setLiveTileVisible(_ visible: Bool) {
        guard isLiveRegistered, let liveTileView, let liveTileEngine else { return }
        liveTileEngine.setVisible(visible, for: liveTileView)
    }

    /// §9: ярлык — один элемент, label — заголовок, value — счётчик бэйджа.
    private func configureAccessibility(for descriptor: TileDescriptor) {
        accessibilityLabel = descriptor.title
        switch descriptor.badge {
        case .count(let value) where value > 0:
            accessibilityValue = String(value)
        case .none, .dot, .count:
            // Точка не несёт числа: озвучивать нечего, виджет сообщает о
            // наличии внимания визуально (как в TesseraLiveTileView).
            accessibilityValue = nil
        }
    }

    /// §9: папка — один элемент; число ярлыков в value.
    private func configureAccessibility(for folder: TileFolder) {
        accessibilityLabel = folder.title.isEmpty ? nil : folder.title
        accessibilityValue = folder.tiles.isEmpty ? nil : String(folder.tiles.count)
    }

    /// Пересобирает шрифт заголовка под текущую категорию Dynamic Type.
    ///
    /// Вызывается сеткой при смене категории (одна нотификация на всю сетку
    /// дешевле, чем наблюдатель в каждой ячейке) и перед показом ячейки —
    /// категория могла измениться, пока ячейка была в prefetch.
    func refreshTypography() {
        titleFontBucket = -1
        setNeedsLayout()
    }

    /// VoiceOver-активация плитки (§9): двойной тап вызывает действие ярлыка.
    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return super.accessibilityActivate() }
        onActivate()
        return true
    }

    /// Скрывает/показывает исходную ячейку на время drag (E4.4).
    ///
    /// Меняется `alpha` у `contentView`, а не у ячейки: UICollectionView
    /// применяет к ячейке layout attributes и может вернуть `cell.alpha` к 1
    /// на ближайшем layout-проходе, а `contentView` от атрибутов не зависит.
    /// Рамка и место в раскладке остаются прежними, поэтому соседние плитки
    /// не сдвигаются.
    ///
    /// - Parameter hidden: `true` — ячейка невидима и не озвучивается.
    func setSourceHidden(_ hidden: Bool) {
        contentView.alpha = hidden ? 0 : 1
        accessibilityElementsHidden = hidden
    }

    // MARK: - Переиспользование

    override func prepareForReuse() {
        super.prepareForReuse()

        // Движок удерживает контейнер и провайдера: без явной отмены ячейка
        // осталась бы зарегистрированной после переиспользования (§4).
        endLiveContent()

        // «Желе» режима редактирования (E4.4) живёт на ячейке анимациями слоя.
        // Переиспользованная ячейка не должна унаследовать чужую анимацию или
        // поворот от прежнего элемента.
        layer.removeAllAnimations()
        contentView.layer.removeAllAnimations()
        transform = .identity
        contentView.transform = .identity
        alpha = 1
        contentView.alpha = 1

        itemID = nil
        onActivate = nil
        iconView.image = nil
        iconView.tintColor = nil
        titleLabel.text = nil
        badgeView.badge = .none
        accessibilityLabel = nil
        accessibilityValue = nil
        titleFontBucket = -1
        setSourceHidden(false)
    }

    // MARK: - Раскладка

    override func layoutSubviews() {
        super.layoutSubviews()

        if showsLiveContent {
            // Контейнер занимает всю плитку; содержимое сторон, бэйдж и RTL он
            // раскладывает сам (§4), ячейка только даёт ему рамку.
            liveTileView?.frame = contentView.bounds
            return
        }

        updateTitleFontIfNeeded()
        layoutContent()
    }

    /// §9, RTL: смена направления чтения переставляет иконку и бэйдж.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard previousTraitCollection?.layoutDirection != traitCollection.layoutDirection else {
            return
        }
        setNeedsLayout()
    }

    /// Собирает шрифт заголовка под фактический размер плитки.
    ///
    /// Ячейка не знает модель размера напрямую (раскладка могла ужать след),
    /// поэтому ориентируется на собственные `bounds`: компактные, средние и
    /// крупные плитки дают разные базовые размеры. Метрики Dynamic Type
    /// применяются поверх базового размера; повторная сборка — только при
    /// смене bucket'а или по ``refreshTypography()``.
    private func updateTitleFontIfNeeded() {
        let side = min(contentView.bounds.width, contentView.bounds.height)
        let bucket: Int
        if side < 100 {
            bucket = 0
        } else if side < 220 {
            bucket = 1
        } else {
            bucket = 2
        }

        guard bucket != titleFontBucket else { return }
        titleFontBucket = bucket

        let baseSize: CGFloat
        switch bucket {
        case 0: baseSize = 12
        case 1: baseSize = 14
        default: baseSize = 17
        }

        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: baseSize, weight: .semibold)
        )
    }

    /// Раскладывает иконку, заголовок и бэйдж.
    ///
    /// Только ручные `frame`: ячейка — квадрат сетки, Auto Layout здесь
    /// избыточен и добавил бы лишний проход на каждый resize.
    private func layoutContent() {
        let bounds = contentView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let minimumSide = min(bounds.width, bounds.height)
        let inset = max(6, min(12, minimumSide * 0.08))
        let contentWidth = max(0, bounds.width - inset * 2)
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft

        // Бэйдж — в верхнем углу, противоположном иконке (§4, §9, RTL).
        let badgeSize = badgeView.intrinsicContentSize
        let showsBadge = badgeSize.width > 0 && badgeSize.height > 0
        if showsBadge {
            let badgeX = isRightToLeft ? inset : bounds.width - inset - badgeSize.width
            badgeView.frame = CGRect(
                x: max(inset, badgeX),
                y: inset,
                width: badgeSize.width,
                height: badgeSize.height
            )
        } else {
            badgeView.frame = .zero
        }

        // Иконка — в верхнем углу по направлению чтения (§9).
        let hasImage = iconView.image != nil
        var iconSide = hasImage ? max(14, min(34, minimumSide * 0.22)) : 0
        let lineHeight = titleLabel.font.lineHeight

        // Заголовок прижат к низу и не заходит в верхнюю зону, занятую
        // иконкой/бэйджем: на маленьких плитках бэйдж иначе ложится на первую
        // строку. Если места на строку не остаётся, иконку прячем — текст
        // важнее для 1×1 и крупного Dynamic Type.
        var topReserve = max(hasImage ? iconSide : 0, showsBadge ? badgeSize.height : 0)
        var titleHeightLimit = bounds.height - inset * 2 - (topReserve > 0 ? topReserve + 4 : 0)
        if hasImage && titleHeightLimit < lineHeight {
            iconSide = 0
            topReserve = showsBadge ? badgeSize.height : 0
            titleHeightLimit = bounds.height - inset * 2 - (topReserve > 0 ? topReserve + 4 : 0)
        }

        let showsIcon = hasImage && iconSide > 0
        iconView.isHidden = !showsIcon
        if showsIcon {
            let iconX = isRightToLeft ? bounds.width - inset - iconSide : inset
            iconView.frame = CGRect(x: iconX, y: inset, width: iconSide, height: iconSide)
        } else {
            iconView.frame = .zero
        }

        guard contentWidth > 0 else {
            titleLabel.frame = .zero
            return
        }

        if titleHeightLimit >= lineHeight * 2.5 {
            titleLabel.numberOfLines = 3
        } else if titleHeightLimit >= lineHeight * 1.5 {
            titleLabel.numberOfLines = 2
        } else {
            titleLabel.numberOfLines = 1
        }

        let measured = titleLabel.sizeThatFits(
            CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        let titleHeight = min(ceil(measured.height), max(0, titleHeightLimit))
        titleLabel.frame = CGRect(
            x: inset,
            y: bounds.height - inset - titleHeight,
            width: contentWidth,
            height: titleHeight
        )
    }
}

// MARK: - Пустышка перетаскивания

/// Вид-пустышка под плитку на время перетаскивания (E4.4).
///
/// Отдаётся координатору редактирования через
/// `TesseraTileGridView.placeholderView(forItemID:)`. В иерархию сам не
/// добавляется: место, слой и время жизни определяет координатор. Не ловит
/// касания и скрыт от VoiceOver — это декорация, а не элемент сетки.
final class TesseraTilePlaceholderView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = UIColor.label.withAlphaComponent(0.08)
        layer.borderWidth = 1
        layer.cornerRadius = 0
        updateBorderColor()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateBorderColor()
    }

    /// CGColor не адаптируется автоматически при смене темы — обновляем вручную.
    private func updateBorderColor() {
        layer.borderColor = UIColor.label.withAlphaComponent(0.24).cgColor
    }
}

#endif
