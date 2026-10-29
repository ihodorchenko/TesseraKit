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
//  D17 (docs/STATE.md, E7.3) — нативное WP-раскрытие папки: под плиткой папки
//  (она остаётся видимой) вставляется полноширинная панель
//  `TileGridItem.folderContent` — отдельная строка сразу после строки, в которой
//  заканчивается папка. Блокировка прокрутки на время анимации, каскад иконок
//  после роста высоты, закрытие повторным тапом/тапом по пустому месту/Back и
//  перехватчик `folderTapHandler` для хоста. Панель — ячейка коллекции
//  (`TesseraFolderPanelCell`), поэтому строки под ней сдвигает штатная анимация
//  batch-обновлений, а не ручной layout. Пока папка раскрыта, на её плитке
//  скрыты мини-ярлыки превью 2×2 (подложка и заголовок остаются).
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
///     case .folder(let folder): host.analytics.folderTapped(folder)  // D14/D17
///     default: break
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
/// ## Раскрытие папки (D17, E7.3)
///
/// Тап по закрытой папке раскрывает её нативно, как в Windows Phone: под
/// плиткой папки (она остаётся на месте и видна) вставляется полноширинная
/// панель с заголовком (в нижнем регистре) и четырёхколоночной сеткой ярлыков.
/// Панель занимает отдельную строку сразу после строки, в которой заканчивается
/// папка, и растёт вниз, поэтому всё, что начинается ниже этой строки,
/// сдвигается под неё; иконки появляются каскадом после завершения роста. Пока
/// папка раскрыта, на её плитке скрыты мини-ярлыки превью 2×2 — подложка и
/// заголовок остаются; при закрытии превью возвращается. Панель — это
/// UI-состояние, а не данные: в снимок `TileStore` она не попадает, а ``items``
/// её не содержит.
///
/// - ``toggleFolder(_:)`` / ``openFolder(_:animated:)`` / ``closeFolder(animated:)``
///   — программное управление; состояние читается через ``expandedFolderID``;
/// - ``folderTapHandler`` — перехват: `true` отменяет нативное раскрытие;
/// - закрытие: повторный тап по панели, тап по пустому месту коллекции,
///   ``accessibilityPerformEscape()`` (Back/двумя пальцами) или явный вызов
///   хоста; исчезновение папки из снимка тоже закрывает панель;
/// - в режиме редактирования (`TesseraTileEditCoordinator`) раскрытие не
///   выполняется: тап остаётся событием ``onTap``;
/// - анимация — `cubic-bezier(0.1, 0.9, 0.2, 1)`, 0.28 с
///   (``folderExpansionDuration``); при Reduce Motion (§9) раскрытие мгновенное.
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

    /// Перехватчик тапа по папке (D17, E7.3).
    ///
    /// Если замыкание задано и вернуло `true`, сетка **не** выполняет нативное
    /// раскрытие: решение и показ экрана — за хостом (например, прежний экран
    /// папки). В этом случае ``onTap`` тоже не вызывается, чтобы хост не
    /// обработал тап дважды. `nil` или `false` — папка раскрывается встроенной
    /// панелью (``toggleFolder(_:)``), а событие тапа по-прежнему приходит в
    /// ``onTap``.
    ///
    /// Перехватчик не вызывается в режиме редактирования: там тап остаётся
    /// событием хоста/координатора и раскрытия не запускает.
    public var folderTapHandler: ((TileFolder) -> Bool)?

    /// Событие раскрытия/закрытия папки встроенной панелью (D17, E7.3).
    ///
    /// Внутренний канал для SwiftUI-фасада: UIKit-хост читает состояние через
    /// ``expandedFolderID`` и вызывает ``closeFolder(animated:)``. Первый
    /// параметр — папка, второй — раскрыта ли она сейчас.
    var onFolderExpansionChanged: ((TileFolder, Bool) -> Void)?

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
    ///
    /// Панель раскрытой папки (``TileGridItem/folderContent(_:)``, D17) сюда не
    /// входит: это UI-состояние, а не данные. Хосту и координатору редактирования
    /// нужен именно снимок `TileStore`, чтобы сравнение модели не зависело от
    /// того, открыта ли папка. Состояние раскрытия — ``expandedFolderID``.
    public var items: [TileGridItem] {
        snapshot?.items ?? []
    }

    // MARK: - Раскрытие папки (D17, E7.3)

    /// Длительность анимации раскрытия/закрытия панели папки, секунды (D17).
    ///
    /// Кривая — `cubic-bezier(0.1, 0.9, 0.2, 1)`: быстрый старт и мягкое
    /// торможение, как в Windows Phone.
    public static let folderExpansionDuration: TimeInterval = 0.28

    /// Микро-задержка каскада иконок внутри панели на индекс, секунды (D17).
    public static let folderIconStagger: TimeInterval = 0.035

    /// Задержка появления иконки панели по её индексу (D17).
    ///
    /// Чистая функция от индекса: отрицательные значения трактуются как 0.
    /// Отдельная функция нужна тестам E7.4 — каскад проверяется без таймеров
    /// и без UI-цикла.
    ///
    /// - Parameter index: Индекс ярлыка в сетке содержимого панели.
    /// - Returns: Задержка старта анимации в секундах.
    public static func staggerDelay(index: Int) -> TimeInterval {
        TimeInterval(max(0, index)) * folderIconStagger
    }

    /// Идентификатор раскрытой папки; `nil` — все папки закрыты (D17).
    ///
    /// Публично только чтение: состояние меняют ``toggleFolder(_:)``,
    /// ``openFolder(_:animated:)`` и ``closeFolder(animated:)``. В режиме
    /// редактирования нативное раскрытие не запускается, но явный вызов хоста
    /// не блокируется: решение остаётся за хостом.
    public private(set) var expandedFolderID: AnyHashable?

    /// Переключает раскрытие папки (D17): закрытую — открывает, открытую —
    /// закрывает. Другая раскрытая папка сначала закрывается без анимации:
    /// одновременно раскрыта максимум одна папка.
    ///
    /// - Parameter folder: Папка из текущего снимка сетки.
    public func toggleFolder(_ folder: TileFolder) {
        if expandedFolderID == folder.id {
            closeFolder(animated: true)
        } else {
            openFolder(folder, animated: true)
        }
    }

    /// Раскрывает папку встроенной панелью (D17).
    ///
    /// Под плиткой папки появляется полноширинная панель
    /// ``TileGridItem/folderContent(_:)``: в наборе коллекции она вставляется
    /// отдельным элементом сразу после плитки папки, сама плитка остаётся на
    /// месте и видна всё время раскрытия. Геометрически панель занимает строку
    /// сразу после строки, в которой заканчивается папка, и растягивается на всю
    /// ширину. Batch-обновление только вставляет панель: её высота растёт
    /// 0 → `panelHeight`, а строки, начинающиеся ниже папки, сдвигаются под неё.
    /// На время анимации прокрутка сетки блокируется (`isScrollEnabled = false`),
    /// иконки появляются каскадом ~35 мс на индекс после завершения роста.
    /// Пока папка раскрыта, на её плитке скрыты мини-ярлыки превью 2×2. При
    /// Reduce Motion (§9) и вне окна панель появляется без анимации.
    ///
    /// Если папки нет в текущем снимке, вызов ничего не делает; если открыта
    /// другая папка, она сначала закрывается.
    ///
    /// - Parameters:
    ///   - folder: Папка из текущего снимка сетки.
    ///   - animated: Анимировать ли появление панели (при Reduce Motion
    ///     игнорируется).
    public func openFolder(_ folder: TileFolder, animated: Bool = true) {
        guard !isFolderChangeAnimating else { return }
        guard expandedFolderID != folder.id else { return }
        guard let currentFolder = currentFolder(withID: folder.id) else { return }

        if expandedFolderID != nil {
            collapseExpansion(animated: false, notify: true)
        }

        // D17: панель вставляется отдельным элементом сразу после плитки папки;
        // сама плитка остаётся в наборе.
        guard let insertionIndex = TileLayoutEngine.folderPanelInsertionIndex(
            items: baseItems,
            expandedFolderID: currentFolder.id
        ) else {
            return
        }

        expandedFolderID = currentFolder.id
        invalidateDisplayItems()
        guard displayItems.count == baseItems.count + 1,
              displayItems.indices.contains(insertionIndex),
              displayItems[insertionIndex].isFolderPanel else {
            expandedFolderID = nil
            invalidateDisplayItems()
            return
        }

        setFolderCellExpanded(true, forItemID: currentFolder.id)

        guard animated, canAnimateFolderChange else {
            tileLayout.setItems(displayItems, reason: .items)
            collectionView.reloadData()
            onFolderExpansionChanged?(currentFolder, true)
            return
        }

        let previousScrollState = collectionView.isScrollEnabled
        // D17: на время анимации сетка не прокручивается — иначе элементы под
        // панелью «спорили» бы с пальцем за одно и то же движение.
        collectionView.isScrollEnabled = false
        isFolderChangeAnimating = true

        let panel = IndexPath(item: insertionIndex, section: 0)
        animateFolderChange { [weak self] in
            guard let self else { return }
            self.tileLayout.setItems(self.displayItems, reason: .items)
            self.collectionView.performBatchUpdates({
                // Плитка папки никуда не девается: вставляется только панель,
                // которая растёт из нулевой высоты от своей строки (атрибуты —
                // в раскладке), а строки под ней сдвигаются вниз.
                self.collectionView.insertItems(at: [panel])
            }, completion: nil)
        } completion: { [weak self] in
            guard let self else { return }
            self.isFolderChangeAnimating = false
            self.collectionView.isScrollEnabled = previousScrollState

            if let panelCell = self.collectionView.cellForItem(at: panel) as? TesseraFolderPanelCell {
                // Каскад запускается открытием, а не показом ячейки: прокрутка
                // и переиспользование не должны повторять анимацию.
                panelCell.playIconCascade()
                UIAccessibility.post(notification: .layoutChanged, argument: panelCell)
            }
            self.onFolderExpansionChanged?(currentFolder, true)
        }
    }

    /// Закрывает панель раскрытой папки (D17).
    ///
    /// Иконки панели гаснут, затем её высота схлопывается, а из набора
    /// удаляется сама панель: плитка папки всё это время остаётся на своём
    /// месте, а элементы под панелью поднимаются вверх. При закрытии на плитке
    /// возвращаются мини-ярлыки превью. По завершении прокрутка разблокируется,
    /// а `contentOffset` зажимается в новых границах контента. Хост может
    /// вызвать метод для закрытия по Back, не дожидаясь тапа.
    ///
    /// - Parameter animated: Анимировать ли закрытие (при Reduce Motion
    ///   игнорируется).
    public func closeFolder(animated: Bool = true) {
        collapseExpansion(animated: animated, notify: true)
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
        set {
            guard newValue != tileLayout.columns else { return }
            // Место и высота панели раскрытой папки зависят от числа колонок:
            // вместе с юнитом меняются ширина ячейки содержимого и упаковка
            // соседей. Сбрасываем кеш элементов и, если папка открыта,
            // перестраиваем набор целиком, иначе панель и соседи разъедутся.
            invalidateDisplayItems()
            tileLayout.columns = newValue
            if expandedFolderID != nil {
                tileLayout.setItems(displayItems, reason: .items)
                collectionView.reloadData()
            }
        }
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

    /// Тап по пустому месту сетки — закрытие раскрытой папки (D17).
    ///
    /// Висит на коллекции, а не на самой сетке: обработчик сам проверяет
    /// хит-тест, поэтому тап по ячейке (в том числе по панели) его не закрывает.
    private let backgroundTapRecognizer = UITapGestureRecognizer()

    /// Кеш элементов с вставленной панелью раскрытой папки.
    ///
    /// Пересчитывается редко — при смене снимка, раскрытии/закрытии и числа
    /// колонок, а не на каждый запрос коллекции: вставка ищет индекс папки по
    /// снимку.
    private var cachedDisplayItems: [TileGridItem]?

    /// Идёт ли анимация раскрытия/закрытия панели папки (D17).
    ///
    /// Повторный тап во время 280 мс — обычное дело (палец нетерпелив, панель
    /// уже видна). Начинать второй `performBatchUpdates` поверх незавершённого
    /// нельзя: запросы игнорируются до завершения текущей анимации.
    private var isFolderChangeAnimating = false

    /// Аниматор раскрытия/закрытия панели (D17).
    ///
    /// Удерживается, пока идёт анимация: так её нельзя потерять между кадрами,
    /// а завершение гарантированно разблокирует скролл.
    private var folderAnimator: UIViewPropertyAnimator?

    /// Элементы, скрытые координатором редактирования.
    ///
    /// Хранятся по идентификатору, а не по индексу: после переупорядочивания
    /// или перезагрузки индекс меняется, а скрытым должен остаться тот же
    /// элемент. Раскладку скрытие не меняет — место плитки сохраняется.
    private var hiddenItemIDs: Set<AnyHashable> = []

    /// Идентификатор ячейки сетки.
    private static let cellReuseIdentifier = "TesseraTileCell"

    /// Идентификатор ячейки-панели раскрытой папки (D17).
    private static let folderPanelReuseIdentifier = "TesseraFolderPanelCell"

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
        // D17: панель раскрытой папки — отдельная ячейка: при раскрытии она
        // вставляется под плитку папки штатным batch-обновлением, поэтому соседи
        // под панелью переезжают анимацией UICollectionView, без ручной геометрии.
        collectionView.register(
            TesseraFolderPanelCell.self,
            forCellWithReuseIdentifier: TesseraTileGridView.folderPanelReuseIdentifier
        )

        // D17: тап по пустому месту закрывает раскрытую папку. Жест не отменяет
        // касания (`cancelsTouchesInView = false`), иначе перестал бы работать
        // выбор ячеек; хит-тест в обработчике отсеивает тапы по элементам.
        backgroundTapRecognizer.cancelsTouchesInView = false
        backgroundTapRecognizer.delegate = self
        backgroundTapRecognizer.addTarget(self, action: #selector(handleBackgroundTap(_:)))
        collectionView.addGestureRecognizer(backgroundTapRecognizer)

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

        // D17: при раскрытой папке в наборе есть панель, и индексы элементов не
        // совпадают с индексами снимка. Перестановки панели не нужны — снимок
        // применяется целиком (с кроссфейдом, если сетка на экране), раскрытие
        // сохраняется, пока папка есть в новом снимке.
        if expandedFolderID != nil {
            apply(newSnapshot, animated: shouldAnimate)
            return
        }

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
            invalidateDisplayItems()

            // Если порядок не менялся (только resize/бэйджи), содержимое ячеек
            // можно обновить сразу — переезжать им не с чем. При перестановке
            // содержимое приедет с ячейкой, а обновим его по завершении.
            if oldIDs == newIDs {
                refreshVisibleCells()
            }

            collectionView.performBatchUpdates({
                self.tileLayout.setItems(self.displayItems, reason: .items)
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
        // D17: если открытая папка исчезла из модели (распущена, откреплена),
        // раскрытие снимается — панель без папки остаться не может. Хосту
        // сообщаем о закрытии уже после применения снимка.
        var collapsedFolder: TileFolder?
        if let expandedID = expandedFolderID,
           newSnapshot.items.compactMap({ $0.folder }).first(where: { $0.id == expandedID }) == nil {
            collapsedFolder = currentFolder(withID: expandedID)
            expandedFolderID = nil
        }

        snapshot = newSnapshot
        hiddenItemIDs.formIntersection(newSnapshot.items.map { $0.id })
        invalidateDisplayItems()

        let update = {
            self.tileLayout.setItems(self.displayItems, reason: .items)
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

        if let collapsedFolder {
            onFolderExpansionChanged?(collapsedFolder, false)
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
            guard let item = displayItem(atIndex: indexPath.item) else { continue }

            if item.isFolderPanel {
                (collectionView.cellForItem(at: indexPath) as? TesseraFolderPanelCell)?
                    .refreshTypography()
                continue
            }

            guard let cell = collectionView.cellForItem(at: indexPath) as? TesseraTileCell else {
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
            isVisible: isVisible && !isHidden,
            isFolderExpanded: item.id == expandedFolderID
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
              let item = baseItem(atIndex: index) else {
            return
        }
        handleItemTap(item)
    }

    // MARK: - Запросы для хоста и редактирования

    /// Индекс элемента в порядке сетки.
    ///
    /// Индекс считается по снимку `TileStore`, без панели раскрытой папки:
    /// координатор редактирования передаёт его в `TileStore.move(_:toIndex:)`,
    /// и «лишний» элемент сдвинул бы модель. Панель адресуется отдельно —
    /// ``expandedFolderID``.
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
        return displayItem(atIndex: indexPath.item)
    }

    /// Рамка элемента в координатах сетки.
    ///
    /// Координаты сетки — это `bounds` этого view: рамка уже учитывает
    /// `contentOffset` и поля. Для ячеек за пределами экрана рамка может быть
    /// отрицательной — это нормально, слой перетаскивания сам решает, что
    /// показывать.
    ///
    /// - Parameter id: Идентификатор ярлыка или папки.
    /// - Returns: Рамка в точках или `nil`, если элемента нет в снимке либо сетка
    ///   ещё ни разу не раскладывалась. У раскрытой папки возвращается рамка её
    ///   плитки: плитка остаётся на месте, панель встаёт под ней.
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
        guard snapshot != nil else { return }

        let shouldAnimate = animated
            && window != nil
            && !TesseraAccessibility.isReduceMotionEnabled

        if shouldAnimate {
            collectionView.performBatchUpdates({
                // displayItems, а не snapshot.items: открытая панель раскрытой
                // папки должна остаться в наборе и переехать вместе с сеткой.
                self.tileLayout.setItems(self.displayItems, reason: .geometry)
            }, completion: { [weak self] _ in
                self?.refreshVisibleCells()
            })
        } else {
            tileLayout.setItems(displayItems, reason: .geometry)
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

    /// Элементы снимка в порядке сетки (без панели раскрытой папки).
    private var baseItems: [TileGridItem] {
        snapshot?.items ?? []
    }

    /// Элементы в порядке коллекции: снимок, в который при раскрытой папке
    /// добавлена панель (D17).
    ///
    /// Число элементов при раскрытии равно `baseItems.count + 1`: панель —
    /// отдельный элемент сразу после плитки папки, сама плитка остаётся в
    /// наборе. Кеш сбрасывается только при смене снимка, раскрытия и числа
    /// колонок — на каждый запрос коллекции индекс вставки не пересчитывается.
    /// Доступ внутренний (не публичный): это представление сетки, а не данные;
    /// наружу отдаются ``items`` и ``expandedFolderID``. Тестам E7.4 нужен
    /// именно набор коллекции — по нему проверяются вставка панели под папку и
    /// её удаление.
    var displayItems: [TileGridItem] {
        if let cachedDisplayItems {
            return cachedDisplayItems
        }
        let items = makeDisplayItems()
        cachedDisplayItems = items
        return items
    }

    /// Сбрасывает кеш элементов с панелью.
    private func invalidateDisplayItems() {
        cachedDisplayItems = nil
    }

    /// Собирает элементы коллекции: вставляет панель раскрытой папки после её
    /// плитки, не убирая саму плитку.
    private func makeDisplayItems() -> [TileGridItem] {
        guard let snapshot else { return [] }
        guard let expandedID = expandedFolderID,
              let folder = snapshot.items.compactMap({ $0.folder }).first(where: { $0.id == expandedID }),
              let insertionIndex = TileLayoutEngine.folderPanelInsertionIndex(
                  items: snapshot.items,
                  expandedFolderID: expandedID
              ) else {
            return snapshot.items
        }

        // D17: панель — отдельная полноширинная строка сразу после строки
        // папки. Плитка папки остаётся на своём индексе; строки ниже панели
        // сдвигает раскладка.
        var items = snapshot.items
        items.insert(.folderContent(folder), at: insertionIndex)
        return items
    }

    /// Элемент снимка по индексу (без панели).
    private func baseItem(atIndex index: Int) -> TileGridItem? {
        guard let snapshot, snapshot.items.indices.contains(index) else { return nil }
        return snapshot.items[index]
    }

    /// Элемент коллекции по индексу (с панелью раскрытой папки).
    private func displayItem(atIndex index: Int) -> TileGridItem? {
        let items = displayItems
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    /// Индекс элемента в коллекции; панель пропускается: она делит
    /// идентификатор с папкой, но не является адресуемым элементом модели.
    private func displayIndex(ofItemID id: AnyHashable) -> Int? {
        displayItems.firstIndex { !$0.isFolderPanel && $0.id == id }
    }

    /// `IndexPath` элемента в текущей коллекции.
    private func indexPath(forItemID id: AnyHashable) -> IndexPath? {
        guard let index = displayIndex(ofItemID: id) else { return nil }
        return IndexPath(item: index, section: 0)
    }

    /// Папка из текущего снимка по идентификатору.
    private func currentFolder(withID id: AnyHashable) -> TileFolder? {
        snapshot?.items.compactMap { $0.folder }.first { $0.id == id }
    }

    /// Разрешена ли анимация раскрытия/закрытия панели.
    ///
    /// Вне окна и при Reduce Motion (§9) панель меняет состояние мгновенно:
    /// тесты и первый layout не ждут анимационного цикла.
    private var canAnimateFolderChange: Bool {
        window != nil && !TesseraAccessibility.isReduceMotionEnabled
    }

    /// Активен ли режим редактирования координатора (E7.3).
    ///
    /// Сетка не хранит ссылку на `TesseraTileEditCoordinator`, а публичного
    /// флага режима у неё нет. Единственный сигнал, который координатор
    /// оставляет на сетке, — собственный tap-жест по фону: он включается только
    /// в режиме редактирования (`beginEditing`/`endEditing`), а его делегатом
    /// выступает сам координатор. Свои жесты сетка ставит на коллекцию, поэтому
    /// в `gestureRecognizers` их нет, а чужие tap-жесты хоста не путаются с
    /// координатором: проверяется и тип, и делегат.
    private var isEditModeActive: Bool {
        gestureRecognizers?.contains { recognizer in
            recognizer.isEnabled
                && recognizer is UITapGestureRecognizer
                && recognizer.delegate is TesseraTileEditCoordinator
        } ?? false
    }

    /// Маршрутизация тапа по элементу (палец или активация VoiceOver).
    ///
    /// В режиме редактирования тап остаётся событием хоста: раскрытие не
    /// запускается. Иначе папку можно перехватить через ``folderTapHandler``;
    /// без перехвата она раскрывается нативной панелью (D17), а событие
    /// ``onTap`` по-прежнему уходит подписчику.
    private func handleItemTap(_ item: TileGridItem) {
        switch item {
        case .tile:
            onTap?(item)

        case .folder(let folder):
            guard !isEditModeActive else {
                onTap?(item)
                return
            }
            // Перехватчик полностью владеет тапом папки, когда вернул true:
            // и раскрытие, и событие onTap тогда не выполняются.
            if folderTapHandler?(folder) == true {
                return
            }
            onTap?(item)
            toggleFolder(folder)

        case .folderContent:
            // Панель — представление, а не элемент модели: выбор по ней
            // отключён (`shouldSelectItemAt`), а тап по фону/заголовку
            // закрывает папку жестом самой ячейки-панели (D17).
            break
        }
    }

    /// Тап по пустому месту сетки закрывает раскрытую папку (D17).
    @objc private func handleBackgroundTap(_ recognizer: UITapGestureRecognizer) {
        guard expandedFolderID != nil else { return }

        // Хит-тест по коллекции: тап по ячейке (включая панель и её иконки)
        // закрытием не считается — у панели своя обработка, у плиток своя.
        let point = recognizer.location(in: collectionView)
        guard collectionView.indexPathForItem(at: point) == nil else { return }

        closeFolder(animated: true)
    }

    /// Выполняет анимацию раскрытия/закрытия с кривой D17.
    ///
    /// `UIViewPropertyAnimator` с `UICubicTimingParameters` даёт ровно
    /// `cubic-bezier(0.1, 0.9, 0.2, 1)`; `performBatchUpdates` внутри его
    /// анимационного блока наследует длительность и кривую, поэтому появление
    /// (схлопывание) панели и сдвиг элементов под ней идут одним движением.
    ///
    /// - Parameters:
    ///   - changes: Изменения модели коллекции (batch updates и раскладка).
    ///   - completion: Завершение анимации (уже на главном потоке).
    private func animateFolderChange(
        changes: @escaping () -> Void,
        completion: @escaping () -> Void
    ) {
        let timing = UICubicTimingParameters(
            controlPoint1: CGPoint(x: 0.1, y: 0.9),
            controlPoint2: CGPoint(x: 0.2, y: 1)
        )
        let animator = UIViewPropertyAnimator(
            duration: TesseraTileGridView.folderExpansionDuration,
            timingParameters: timing
        )
        animator.addAnimations(changes)
        animator.addCompletion { [weak self] _ in
            self?.folderAnimator = nil
            completion()
        }
        folderAnimator = animator
        animator.startAnimation()
    }

    /// Снимает раскрытие папки; общая реализация ``closeFolder(animated:)``.
    ///
    /// Панель схлопывается и удаляется из набора; плитка папки всё это время
    /// остаётся на своём месте. Batch-обновление удаляет только панель, поэтому
    /// строки под ней поднимаются вместе с уменьшением её высоты.
    ///
    /// - Parameters:
    ///   - animated: Анимировать ли схлопывание.
    ///   - notify: Сообщать ли хосту о закрытии (при смене папки на другую
    ///     событие тоже нужно: одна папка закрылась, другая открылась).
    private func collapseExpansion(animated: Bool, notify: Bool) {
        guard !isFolderChangeAnimating else { return }
        guard let expandedID = expandedFolderID else { return }

        let folder = currentFolder(withID: expandedID)
            ?? displayItems.first(where: { $0.isFolderPanel })?.panelFolder

        guard let panelIndex = displayItems.firstIndex(where: {
            $0.isFolderPanel && $0.id == expandedID
        }) else {
            // Панели в наборе уже нет (например, папка исчезла из снимка):
            // остаётся только синхронизировать состояние.
            expandedFolderID = nil
            invalidateDisplayItems()
            setFolderCellExpanded(false, forItemID: expandedID)
            tileLayout.setItems(displayItems, reason: .items)
            collectionView.reloadData()
            if let folder, notify {
                onFolderExpansionChanged?(folder, false)
            }
            return
        }

        guard animated, canAnimateFolderChange else {
            expandedFolderID = nil
            invalidateDisplayItems()
            setFolderCellExpanded(false, forItemID: expandedID)
            tileLayout.setItems(displayItems, reason: .items)
            collectionView.reloadData()
            if let folder, notify {
                onFolderExpansionChanged?(folder, false)
            }
            return
        }

        let previousScrollState = collectionView.isScrollEnabled
        collectionView.isScrollEnabled = false
        isFolderChangeAnimating = true

        // Состояние модели снимается только перед batch-обновлением: пока
        // иконки гаснут, dataSource обязан отдавать прежнее число элементов,
        // иначе UICollectionView увидел бы рассогласование до `deleteItems`.
        let collapse = { [weak self] in
            guard let self else { return }
            self.expandedFolderID = nil
            self.invalidateDisplayItems()
            self.setFolderCellExpanded(false, forItemID: expandedID)

            let replacement = IndexPath(item: panelIndex, section: 0)
            self.animateFolderChange {
                self.tileLayout.setItems(self.displayItems, reason: .items)
                self.collectionView.performBatchUpdates({
                    // D17: уходит только панель — плитка папки из набора не
                    // удалялась и остаётся на месте.
                    self.collectionView.deleteItems(at: [replacement])
                }, completion: nil)
            } completion: { [weak self] in
                guard let self else { return }
                self.isFolderChangeAnimating = false
                self.collectionView.isScrollEnabled = previousScrollState
                self.clampContentOffsetAfterCollapse()
                // §9: фокус VoiceOver возвращается на свёрнутую папку.
                if let folderCell = self.cellView(forItemID: expandedID) {
                    UIAccessibility.post(notification: .layoutChanged, argument: folderCell)
                }
                if let folder, notify {
                    self.onFolderExpansionChanged?(folder, false)
                }
            }
        }

        // D17: сначала гаснут иконки, затем схлопывается высота панели и
        // поднимаются элементы под ней. Если панель уже вне экрана — сразу высота.
        if let panelCell = collectionView.cellForItem(
            at: IndexPath(item: panelIndex, section: 0)
        ) as? TesseraFolderPanelCell {
            panelCell.animateIconsOut(completion: collapse)
        } else {
            collapse()
        }
    }

    /// Зажимает `contentOffset` после закрытия: контент стал короче, и позиция
    /// прокрутки могла оказаться за его пределами.
    private func clampContentOffsetAfterCollapse() {
        let maximumY = max(0, contentSize.height - collectionView.bounds.height)
        let offset = collectionView.contentOffset
        guard offset.y > maximumY else { return }
        collectionView.setContentOffset(
            CGPoint(x: offset.x, y: maximumY),
            animated: false
        )
    }

    /// Сообщает видимой ячейке папки о раскрытии/закрытии (D17).
    ///
    /// - Parameters:
    ///   - expanded: Раскрыта ли папка.
    ///   - id: Идентификатор папки.
    private func setFolderCellExpanded(_ expanded: Bool, forItemID id: AnyHashable) {
        guard let cell = cellView(forItemID: id) as? TesseraTileCell else { return }
        cell.setFolderExpanded(expanded)
    }

    /// Долгое нажатие: сообщает элемент и точку старта, дальше ведёт хост.
    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, onLongPress != nil else { return }

        let point = recognizer.location(in: self)
        guard let item = item(at: point), !hiddenItemIDs.contains(item.id) else { return }
        onLongPress?(item, point)
    }

    /// §9, Dynamic Type: пересобрать шрифты видимых ячеек и панели папки.
    @objc private func contentSizeCategoryDidChange() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            if let tileCell = collectionView.cellForItem(at: indexPath) as? TesseraTileCell {
                tileCell.refreshTypography()
            } else if let panelCell = collectionView.cellForItem(at: indexPath) as? TesseraFolderPanelCell {
                panelCell.refreshTypography()
            }
        }
    }

    /// §9: VoiceOver «два пальца влево»/Back закрывают раскрытую папку (D17).
    public override func accessibilityPerformEscape() -> Bool {
        guard expandedFolderID != nil else {
            return super.accessibilityPerformEscape()
        }
        closeFolder(animated: true)
        return true
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

    /// Число элементов в коллекции: снимок плюс панель раскрытой папки (D17).
    public func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        displayItems.count
    }

    /// Ячейка ярлыка, папки или панели раскрытой папки.
    ///
    /// Содержимое плитки готовит ``configure(_:with:isVisible:)``: статичные
    /// иконка, заголовок и бэйдж либо live-контейнер, если у ярлыка есть
    /// ``TileDescriptor/liveContent``. Регистрация live-плитки в движке
    /// выполняется на `willDisplay`, а не здесь: ячейка, подготовленная для
    /// prefetch, может так и не появиться на экране.
    ///
    /// Панель раскрытой папки (D17) — отдельный тип ячейки: она не перехватывает
    /// тапы сетки и рисует заголовок с четырёхколоночной сеткой ярлыков.
    public func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let item = displayItem(atIndex: indexPath.item) else {
            return collectionView.dequeueReusableCell(
                withReuseIdentifier: TesseraTileGridView.cellReuseIdentifier,
                for: indexPath
            )
        }

        if item.isFolderPanel {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TesseraTileGridView.folderPanelReuseIdentifier,
                for: indexPath
            )
            if let panelCell = cell as? TesseraFolderPanelCell,
               let folder = item.panelFolder {
                panelCell.configure(folder: folder, columns: tileLayout.columns)
                // D17: тап по фону/заголовку панели закрывает папку. Ярлыки
                // внутри панели обрабатывает сама ячейка: её жест сначала
                // проверяет попадание в иконку.
                panelCell.onBackgroundTap = { [weak self] in
                    self?.closeFolder(animated: true)
                }
                // Панель вставляется анимацией раскрытия: иконки уже спрятаны,
                // чтобы каскад после роста высоты начался без «вспышки».
                if isFolderChangeAnimating {
                    panelCell.prepareIconCascade()
                }
            }
            return cell
        }

        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: TesseraTileGridView.cellReuseIdentifier,
            for: indexPath
        )
        if let tileCell = cell as? TesseraTileCell {
            configure(tileCell, with: item, isVisible: false)
        }
        return cell
    }
}

// MARK: - UICollectionViewDelegate

extension TesseraTileGridView: UICollectionViewDelegate {

    /// Можно ли выбрать элемент коллекции.
    ///
    /// Панель раскрытой папки — представление, а не элемент модели (D17):
    /// выбор по ней не нужен. Жест самой панели уже обработал попадание в
    /// ярлык или закрытие по фону, а лишний `didSelect` после закрытия мог бы
    /// прийти по индексу, где панели уже нет, и сработать по чужому элементу.
    public func collectionView(
        _ collectionView: UICollectionView,
        shouldSelectItemAt indexPath: IndexPath
    ) -> Bool {
        guard let item = displayItem(atIndex: indexPath.item) else { return false }
        return !item.isFolderPanel
    }

    /// Тап по элементу: маршрутизация в ``handleItemTap(_:)`` (D12, D17).
    public func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        collectionView.deselectItem(at: indexPath, animated: false)

        guard let item = displayItem(atIndex: indexPath.item),
              !hiddenItemIDs.contains(item.id) else {
            return
        }
        handleItemTap(item)
    }

    /// Показ ячейки: регистрирует live-плитку в движке и возвращает скрытое
    /// состояние после переиспользования.
    ///
    /// Регистрация именно здесь, а не в `cellForItemAt`: UICollectionView
    /// сообщает о фактическом появлении ячейки на экране, включая возврат
    /// после прокрутки. Один движок на сетку при этом не пересоздаётся — он
    /// лишь получает контейнер и провайдера.
    ///
    /// Панель раскрытой папки каскад здесь не запускает: анимация принадлежит
    /// открытию папки, иначе прокрутка повторяла бы её на каждом показе.
    public func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let tileCell = cell as? TesseraTileCell,
              let item = displayItem(atIndex: indexPath.item),
              !item.isFolderPanel else {
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

    /// Превью закрытой папки — мини-сетка 2×2 с idle-флипом (D17).
    ///
    /// Создаётся лениво: у ярлыка и у пустой папки превью нет. View живёт
    /// вместе с ячейкой и переиспользуется, чтобы фаза флипа не начиналась
    /// заново при каждом появлении на экране.
    private(set) var folderPreviewView: TesseraFolderPreviewView?

    /// Показывает ли ячейка сейчас превью папки, а не одиночную иконку.
    private var showsFolderPreview = false

    /// Раскрыта ли папка (D17, E7.3).
    ///
    /// Саму панель раскрытия рисует сетка/хост, а не ячейка: ячейке достаточно
    /// поставить превью на паузу и скрыть мини-ярлыки 2×2, пока панель открыта.
    /// Подложка и заголовок плитки остаются — панель встаёт под плиткой, а не
    /// вместо неё.
    private var isFolderExpanded = false

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
    ///   - isFolderExpanded: Раскрыта ли эта папка панелью (D17): раскрытая
    ///     папка ставит idle-флип превью на паузу. Для ярлыка не имеет значения.
    func configure(
        with item: TileGridItem,
        liveTileEngine engine: TesseraLiveTileEngine?,
        isVisible: Bool,
        isFolderExpanded: Bool = false
    ) {
        itemID = item.id

        switch item {
        case .tile(let descriptor):
            endFolderPreview()
            self.isFolderExpanded = false
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
            configureStaticFolder(folder, isVisible: isVisible)
            configureAccessibility(for: folder)
            // D17: раскрытая папка ставит idle-флип превью на паузу, чтобы
            // каскад иконок панели не спорил с переворотом мини-плиток.
            setFolderExpanded(isFolderExpanded)

        case .folderContent(let folder):
            // Панель раскрытой папки (E7.1) рисует волна 2 отдельным видом
            // панели, а не ячейка плитки (D17, E7.3). Защитный запасной путь:
            // только заголовок папки — ячейка не притворяется закрытой папкой
            // с мини-сеткой и не запускает idle-флип.
            endLiveContent()
            endFolderPreview()
            self.isFolderExpanded = false
            iconView.image = nil
            iconView.tintColor = nil
            iconView.isHidden = true
            titleLabel.text = folder.title
            badgeView.badge = .none
            badgeView.isHidden = true
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
        // После папки ячейка могла остаться в её раскладке: бэйдж возвращаем
        // в иерархию (при `.none` он невидим сам по себе).
        badgeView.isHidden = false
    }

    /// Папка: мини-сетка содержимого либо иконка-превью/заглушка, заголовок;
    /// бэйджа у папки нет.
    ///
    /// Закрытая папка показывает до четырёх первых иконок ярлыков (D17): это
    /// WP-превью содержимого вместо одиночной иконки. Пустая папка сохраняет
    /// прежнее поведение — явную иконку-превью ``TileFolder/icon``, а без неё
    /// заглушку `folder.fill`.
    ///
    /// - Parameters:
    ///   - folder: Модель папки.
    ///   - isVisible: Видима ли ячейка: idle-флип превью идёт только на экране.
    private func configureStaticFolder(_ folder: TileFolder, isVisible: Bool) {
        titleLabel.text = folder.title
        badgeView.badge = .none
        badgeView.isHidden = true

        guard !folder.tiles.isEmpty else {
            endFolderPreview()
            if let icon = folder.icon {
                iconView.image = icon
                iconView.tintColor = nil
            } else {
                // Иконка-заглушка папки; шаблонный символ красится в
                // secondaryLabel и адаптируется к тёмной теме.
                iconView.image = UIImage(systemName: "folder.fill")
                iconView.tintColor = .secondaryLabel
            }
            iconView.isHidden = false
            return
        }

        let preview = folderPreviewView ?? makeFolderPreviewView()
        preview.configure(
            tiles: Array(folder.tiles.prefix(4)),
            schedule: TesseraFolderFlipSchedule(folderID: folder.id)
        )
        preview.setExpanded(isFolderExpanded)
        preview.setVisible(isVisible)
        showsFolderPreview = true
        // D17: у раскрытой папки мини-ярлыки превью скрыты — плитка остаётся
        // видимой подложкой с заголовком.
        updateFolderPreviewVisibility()

        // Одиночная иконка уступает место мини-сетке; у её мини-плиток иконки
        // свои, поэтому общая иконка ячейки не нужна.
        iconView.image = nil
        iconView.tintColor = nil
        iconView.isHidden = true
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

    /// Ставит live-плитку и idle-флип папки на паузу или возобновляет их (§4).
    ///
    /// Движок не флипает невидимую плитку и сбрасывает незавершённый флип, но
    /// сохраняет подписку провайдера и состояние сторон — возврат на экран не
    /// требует перерегистрации. Превью папки ведёт собственный таймер, но
    /// пауза у него та же: вне экрана мини-иконки возвращаются к иконкам и не
    /// переворачиваются (D17).
    ///
    /// - Parameter visible: Видима ли ячейка на экране.
    func setLiveTileVisible(_ visible: Bool) {
        folderPreviewView?.setVisible(visible)
        guard isLiveRegistered, let liveTileView, let liveTileEngine else { return }
        liveTileEngine.setVisible(visible, for: liveTileView)
    }

    /// Сообщает ячейке, что папка раскрыта панелью (D17, E7.3).
    ///
    /// Раскрытие рисует панель сетки, а не ячейка: ячейка ставит превью на
    /// паузу (idle-флип не должен спорить с каскадом иконок панели) и прячет
    /// мини-ярлыки 2×2, оставляя подложку и заголовок плитки. Закрытие папки
    /// возвращает превью в расписание (если ячейка видима) и показывает
    /// мини-ярлыки снова.
    ///
    /// Состояние хранится флагом, а не только у превью: ячейка
    /// переиспользуется, и `configure(with:isFolderExpanded:)` применяет флаг
    /// заново при каждом показе, поэтому чужая папка не унаследует скрытое или
    /// показанное превью.
    ///
    /// - Parameter expanded: Раскрыта ли папка этим элементом сетки.
    func setFolderExpanded(_ expanded: Bool) {
        isFolderExpanded = expanded
        folderPreviewView?.setExpanded(expanded)
        updateFolderPreviewVisibility()
    }

    /// Показывает мини-ярлыки превью только у закрытой папки (D17).
    ///
    /// Скрывается именно блок мини-иконок 2×2 (`TesseraFolderPreviewView`), а не
    /// вся ячейка: подложка и заголовок остаются. `isHidden` надёжнее `alpha`:
    /// он исключает превью из отрисовки и hit-теста, а неявные анимации
    /// переиспользованной ячейки не могут вернуть ему видимость.
    private func updateFolderPreviewVisibility() {
        folderPreviewView?.isHidden = !showsFolderPreview || isFolderExpanded
    }

    /// Создаёт превью папки один раз на ячейку.
    ///
    /// Превью не перехватывает касания и не является accessibility-элементом:
    /// папка остаётся одним элементом VoiceOver (§9). Слой — под заголовком,
    /// чтобы текст папки всегда читался поверх сетки иконок.
    private func makeFolderPreviewView() -> TesseraFolderPreviewView {
        let preview = TesseraFolderPreviewView(frame: .zero)
        contentView.insertSubview(preview, belowSubview: titleLabel)
        folderPreviewView = preview
        return preview
    }

    /// Снимает превью папки: возвращает к иконке/заглушке и останавливает
    /// idle-флип. Сам view не уничтожается — он переиспользуется, если ячейка
    /// снова покажет папку.
    private func endFolderPreview() {
        showsFolderPreview = false
        folderPreviewView?.stop()
        folderPreviewView?.isHidden = true
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
        // Превью папки тоже обязано вернуться к иконкам: иначе чужая папка
        // унаследует счётчик и фазу флипа (D17).
        endFolderPreview()
        isFolderExpanded = false

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

        if showsFolderPreview {
            layoutFolderPreview(in: bounds)
            return
        }

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

    /// Раскладывает превью папки и заголовок под ним (D17).
    ///
    /// Превью — квадрат 2×2, прижатый к **верхнему** углу плитки по направлению
    /// чтения (§9): в LTR — к левому, в RTL — к правому. Так закрытая папка
    /// читается как сетка рабочего стола: мини-иконки начинаются от того же края,
    /// что и плитки, а не висят по центру. Отступ от края — как у плитки
    /// (`inset`), поэтому превью не липнет к границе ячейки. Заголовок прижат
    /// к низу, как у ярлыка.
    ///
    /// Если плитка низкая (крупный Dynamic Type, тонкая 1×1-папка), приоритет у
    /// заголовка: превью ужимается вместе с мини-плитками.
    ///
    /// - Parameter bounds: Границы контента ячейки.
    private func layoutFolderPreview(in bounds: CGRect) {
        guard let preview = folderPreviewView else { return }

        let minimumSide = min(bounds.width, bounds.height)
        let inset = max(6, min(12, minimumSide * 0.08))
        let contentWidth = max(0, bounds.width - inset * 2)

        iconView.isHidden = true
        iconView.frame = .zero
        badgeView.frame = .zero

        titleLabel.numberOfLines = 2
        let measuredTitle = titleLabel.sizeThatFits(
            CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        let titleHeight = min(
            ceil(measuredTitle.height),
            titleLabel.font.lineHeight * 2,
            bounds.height * 0.32
        )
        titleLabel.frame = CGRect(
            x: inset,
            y: bounds.height - inset - titleHeight,
            width: contentWidth,
            height: titleHeight
        )

        let gap = max(2, minimumSide * 0.03)
        let available = max(0, bounds.height - inset * 2 - titleHeight - gap)
        let blockSide = min(contentWidth, available)
        guard blockSide > 0 else {
            preview.frame = .zero
            return
        }

        // §9, RTL: мини-сетка зеркалится — прижимается к правому верхнему углу,
        // чтобы порядок чтения остался прежним. Заголовок внизу не зеркалится:
        // его выравнивание задаёт сама подпись (`.natural`).
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        preview.frame = CGRect(
            x: isRightToLeft ? bounds.width - inset - blockSide : inset,
            y: inset,
            width: blockSide,
            height: blockSide
        )
    }
}

// MARK: - Панель раскрытой папки (D17, E7.3)

/// Ячейка-панель раскрытой папки: заголовок и сетка ярлыков (D17).
///
/// Панель — полноширинная ячейка коллекции, которая вставляется отдельной
/// строкой сразу после строки, в которой заканчивается плитка-папка
/// (``TileGridItem/folderContent(_:)``); сама плитка папки остаётся видимой.
/// Геометрию задаёт `TesseraTileCollectionViewLayout` (верхний край — строка
/// сразу под папкой, высота — формула
/// ``TileLayoutEngine/panelHeight(for:width:columns:)``), поэтому ячейка только
/// раскладывает содержимое по тем же константам. Сами константы берутся
/// у движка (`Metrics`): формула высоты и раскладка содержимого обязаны
/// считаться по одним числам.
///
/// ## Отрисовка ярлыков
///
/// Внутри переиспользуется ``TesseraTileCell`` — та же плитка, что и на сетке:
/// подложка, иконка, заголовок, бэйдж. Ячейка настраивается так же, как на
/// рабочем столе (фон не обнуляется), а её сторона равна юниту сетки
/// (``TileLayoutEngine/panelTileSide(width:columns:)``), поэтому ярлык в панели
/// — настоящая small-плитка 1×1, совпадающая с плитками под панелью по размеру
/// и колонкам. Тап по ярлыку вызывает ``TileDescriptor/action`` и **не**
/// закрывает папку (D17); VoiceOver-активация идёт тем же путём через
/// `TesseraTileCell.onActivate`. Тап по фону или заголовку вызывает
/// ``onBackgroundTap`` — так сетка закрывает папку повторным тапом.
///
/// ## Анимация
///
/// Каскад появления (`playIconCascade`) и угасания (`animateIconsOut`) —
/// единственные анимации панели. Задержка по индексу считается чистой функцией
/// ``TesseraTileGridView/staggerDelay(index:)``; при Reduce Motion (§9) каскада
/// нет. Панель не трогает раскладку сетки: соседей сдвигает UICollectionView
/// при вставке/удалении ячейки.
///
/// Высота панели тоже анимируется — но раскладкой, а не ячейкой: при вставке
/// UICollectionView растит рамку от 0 до полной высоты
/// (``TesseraTileCollectionViewLayout``). Ячейка раскладывает содержимое **один
/// раз** по ширине и прижимает к верхнему краю; высота в расчёте не участвует,
/// поэтому во время роста внутренняя раскладка не запускается покадрово, а
/// ячейка только обрезает контент снизу (`clipsToBounds`). Иконки на время
/// роста спрятаны (``prepareIconCascade()``) и появляются каскадом после его
/// завершения — без перескакивания из старой раскладки в новую.
final class TesseraFolderPanelCell: UICollectionViewCell {

    // MARK: - Метрики

    /// Константы совпадают с формулой высоты панели в `TileLayoutEngine`.
    ///
    /// Значения берутся у движка, а не дублируются: высота панели и раскладка
    /// её содержимого обязаны считаться по одним числам, иначе последняя строка
    /// ярлыков либо обрежется, либо не заполнит панель.
    private enum Metrics {
        static let padding = TileLayoutEngine.panelPadding
        static let headerHeight = TileLayoutEngine.panelHeaderHeight
        static let headerSpacing = TileLayoutEngine.panelHeaderSpacing
        static let cellSpacing = TileLayoutEngine.panelContentSpacing
        static let cascadeDuration: TimeInterval = 0.18
        static let cascadeOffset: CGFloat = 10
        static let collapseDuration: TimeInterval = 0.12
    }

    // MARK: - Состояние

    /// Заголовок папки (в отображении — в нижнем регистре, WP-стиль).
    private let titleLabel = UILabel()

    /// Ярлыки папки в порядке отображения.
    private var tiles: [TileDescriptor] = []

    /// Переиспользуемые мини-ячейки ярлыков (та же отрисовка, что на сетке).
    private var shortcutCells: [TesseraTileCell] = []

    /// Число колонок сетки содержимого (по D17 — 4 по умолчанию).
    private var columnCount = 4

    /// Тап по фону или заголовку панели (D17): сетка закрывает папку.
    ///
    /// Внутренний канал для `TesseraTileGridView`: ячейка не знает про
    /// состояние сетки, а её собственный жест уже отсеял попадания в ярлыки.
    var onBackgroundTap: (() -> Void)?

    private let tapRecognizer = UITapGestureRecognizer()

    // MARK: - Внутренняя раскладка

    /// Готовая внутренняя раскладка панели.
    ///
    /// Зависит только от ширины, числа колонок, направления чтения и числа
    /// ярлыков — **но не от высоты**. Панель растёт от 0 до финальной высоты в
    /// batch-анимации, и UICollectionView зовёт `layoutSubviews` на каждом кадре
    /// роста; расчёт по высоте сдвигал бы контент покадрово. Поэтому раскладка
    /// считается один раз на ключ и применяется один раз, а высота работает
    /// только как обрезка (`clipsToBounds`).
    private struct ContentLayout: Equatable {

        /// Ширина панели, для которой посчитана раскладка.
        var width: CGFloat

        /// Число колонок сетки содержимого.
        var columns: Int

        /// Направление чтения: в RTL колонки зеркалятся (§9).
        var rightToLeft: Bool

        /// Число ярлыков: от него зависит набор рамок.
        var tileCount: Int

        /// Рамка заголовка.
        var titleFrame: CGRect

        /// Рамки ярлыков по порядку.
        var tileFrames: [CGRect]
    }

    /// Последняя посчитанная раскладка (ключ — ширина/колонки/RTL/состав).
    private var contentLayout: ContentLayout?

    /// Раскладка, уже применённая к подвью. Повторно рамки не выставляются:
    /// рост высоты не должен запускать внутренний layout.
    private var appliedContentLayout: ContentLayout?

    // MARK: - Инициализация

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // D17: фон панели — системный, чтобы она читалась как «выдвинутая»
        // поверх обоев часть рабочего стола в любой теме.
        backgroundColor = .systemBackground
        contentView.backgroundColor = .clear
        isAccessibilityElement = false

        // D17, E7: при вставке панель приходит с высотой 0 и вырастает до
        // полной в batch-анимации сетки, при закрытии — схлопывается обратно.
        // Содержимое прижато к верху (`layoutSubviews` считает рамки от
        // верхнего края), поэтому обрезаем его по границам ячейки: иначе при
        // малой высоте заголовок и иконки вылезали бы за панель.
        clipsToBounds = true

        titleLabel.font = TesseraFolderPanelCell.makeTitleFont()
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textAlignment = .natural
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.accessibilityTraits = .header
        contentView.addSubview(titleLabel)

        // Тап по ярлыку — действие ярлыка; панель остаётся открытой. Тап мимо
        // ярлыков (фон/заголовок) закрывает папку через `onBackgroundTap`.
        // Жест не отменяет касания: выбор ячейки коллекции для панели всё равно
        // отключён (`shouldSelectItemAt`), а прокрутка не должна ломаться.
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.addTarget(self, action: #selector(handleTap(_:)))
        contentView.addGestureRecognizer(tapRecognizer)
    }

    // MARK: - Содержимое

    /// Применяет папку: заголовок и сетку её ярлыков.
    ///
    /// Состав переиспользуется: при том же числе ярлыков плитки панели только
    /// перенастраиваются, поэтому панель не «мигает» при обновлении снимка.
    ///
    /// - Parameters:
    ///   - folder: Раскрытая папка.
    ///   - columns: Число колонок сетки содержимого (число колонок рабочего
    ///     стола; по умолчанию 4).
    func configure(folder: TileFolder, columns: Int) {
        columnCount = max(1, columns)
        // D17: заголовок показывается в нижнем регистре — WP-стиль; исходная
        // подпись остаётся в accessibility label ячейки папки.
        titleLabel.text = folder.title.lowercased()
        titleLabel.accessibilityLabel = folder.title.isEmpty ? nil : folder.title

        tiles = folder.tiles

        while shortcutCells.count > tiles.count {
            shortcutCells.removeLast().removeFromSuperview()
        }
        while shortcutCells.count < tiles.count {
            let cell = TesseraTileCell(frame: .zero)
            // D17: ярлык в панели — настоящая плитка small, а не «иконка с
            // подписью»: подложку, бэйдж, иконку и заголовок рисует та же
            // ячейка, что и на сетке, поэтому фон не обнуляем.
            contentView.addSubview(cell)
            shortcutCells.append(cell)
        }

        for (index, cell) in shortcutCells.enumerated() {
            cell.configure(with: .tile(tiles[index]), liveTileEngine: nil, isVisible: true)
            cell.onActivate = { [weak self] in
                self?.activateTile(at: index)
            }
            // Ячейка могла прийти из середины прошлого каскада. Сброс — без
            // неявной анимации: configure вызывается и внутри batch-обновления.
            withoutImplicitAnimations {
                cell.layer.removeAllAnimations()
                cell.alpha = 1
                cell.transform = .identity
            }
        }

        // Состав/колонки могли измениться — раскладка пересчитывается один раз
        // и сразу применяется, ещё до начала анимации роста высоты.
        invalidateContentLayout()
        applyContentLayoutIfNeeded()
        setNeedsLayout()
    }

    /// Пересобирает шрифты под текущую категорию Dynamic Type (§9).
    func refreshTypography() {
        titleLabel.font = TesseraFolderPanelCell.makeTitleFont()
        shortcutCells.forEach { $0.refreshTypography() }
        // Рамки от шрифта не зависят (заголовок — одна строка фиксированной
        // высоты), поэтому раскладку не сбрасываем: достаточно перерисовать.
        setNeedsLayout()
    }

    // MARK: - Каскад (D17)

    /// Прячет иконки перед ростом высоты панели (D17, E7).
    ///
    /// Вызывается сеткой на вставке панели. Если иконки остались бы видимыми
    /// на время роста, каскад в конце «перепрятал» бы их и они бы прыгнули.
    /// Состояние применяется без неявной анимации: это подготовка кадра, а не
    /// движение.
    func prepareIconCascade() {
        guard !shortcutCells.isEmpty, !TesseraAccessibility.isReduceMotionEnabled else { return }

        withoutImplicitAnimations {
            for cell in shortcutCells {
                cell.layer.removeAllAnimations()
                cell.alpha = 0
                cell.transform = CGAffineTransform(translationX: 0, y: Metrics.cascadeOffset)
            }
        }
    }

    /// Запускает каскад появления иконок: opacity 0 → 1, сдвиг 10 → 0.
    ///
    /// Вызывается сеткой по завершении роста высоты панели. При Reduce Motion
    /// (§9) иконки сразу видны: движение отключено, состояние — устоявшееся.
    func playIconCascade() {
        guard !shortcutCells.isEmpty else { return }

        guard !TesseraAccessibility.isReduceMotionEnabled else {
            shortcutCells.forEach {
                $0.alpha = 1
                $0.transform = .identity
            }
            return
        }

        // Стартовое состояние ставим без анимации, чтобы каскад не подхватил
        // незавершённое движение панели.
        withoutImplicitAnimations {
            for cell in shortcutCells {
                cell.alpha = 0
                cell.transform = CGAffineTransform(translationX: 0, y: Metrics.cascadeOffset)
            }
        }

        for (index, cell) in shortcutCells.enumerated() {
            UIView.animate(
                withDuration: Metrics.cascadeDuration,
                delay: TesseraTileGridView.staggerDelay(index: index),
                options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
                animations: {
                    cell.alpha = 1
                    cell.transform = .identity
                },
                completion: nil
            )
        }
    }

    /// Гасит иконки перед схлопыванием панели (D17).
    ///
    /// Сетка выполняет удаление ячейки в `completion`, поэтому порядок обратной
    /// анимации — «иконки → высота 0 → строки вверх» — соблюдается.
    ///
    /// - Parameter completion: Вызывается по завершении угасания (на главном
    ///   потоке, синхронно при Reduce Motion).
    func animateIconsOut(completion: @escaping () -> Void) {
        guard !shortcutCells.isEmpty, !TesseraAccessibility.isReduceMotionEnabled else {
            shortcutCells.forEach { $0.alpha = 0 }
            completion()
            return
        }

        UIView.animate(
            withDuration: Metrics.collapseDuration,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState],
            animations: {
                for cell in self.shortcutCells {
                    cell.alpha = 0
                    cell.transform = CGAffineTransform(
                        translationX: 0,
                        y: Metrics.cascadeOffset / 2
                    )
                }
            },
            completion: { _ in completion() }
        )
    }

    // MARK: - Действия

    /// Активация ярлыка внутри панели: папка остаётся открытой (D17).
    ///
    /// - Parameter index: Индекс ярлыка в папке.
    private func activateTile(at index: Int) {
        guard tiles.indices.contains(index) else { return }
        tiles[index].action()
    }

    /// Тап по панели: попал в ярлык — выполнить его действие; мимо ярлыков —
    /// закрыть папку (D17, «повторный тап» по панели).
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: contentView)
        for (index, cell) in shortcutCells.enumerated() where cell.frame.contains(point) {
            activateTile(at: index)
            return
        }
        onBackgroundTap?()
    }

    // MARK: - Раскладка

    override func layoutSubviews() {
        super.layoutSubviews()
        // Высота панели в расчёте не участвует: содержимое прижато к верхнему
        // краю и считается по ширине. При росте высоты этот метод вызывается
        // каждый кадр, но раскладка уже применена — рамки не пересчитываются и
        // не переставляются, поэтому контент не дёргается.
        applyContentLayoutIfNeeded()
    }

    /// Применяет внутреннюю раскладку, если она ещё не применена.
    ///
    /// Ключ — ширина, число колонок, направление чтения и число ярлыков.
    /// Высота в ключ не входит намеренно: она меняется на каждом кадре анимации
    /// роста, а контент от неё не зависит.
    private func applyContentLayoutIfNeeded() {
        let width = contentView.bounds.width
        guard width.isFinite, width > 0 else { return }

        let layout: ContentLayout
        if let cached = contentLayout,
           cached.width == width,
           cached.columns == max(1, columnCount),
           cached.rightToLeft == isRightToLeft,
           cached.tileCount == shortcutCells.count {
            layout = cached
        } else if let computed = makeContentLayout(width: width) {
            contentLayout = computed
            layout = computed
        } else {
            return
        }

        guard layout != appliedContentLayout else { return }

        // Во время batch-обновления UICollectionView включает анимационный
        // контекст: обычная установка frame у подвью анимировала бы их из нуля,
        // и иконки «прыгали» бы на первом кадре роста панели. Отключаем
        // неявные анимации — это подготовка кадра, а не движение.
        withoutImplicitAnimations {
            titleLabel.frame = layout.titleFrame
            for (index, cell) in shortcutCells.enumerated()
            where layout.tileFrames.indices.contains(index) {
                cell.frame = layout.tileFrames[index]
            }
            // Дочерние ячейки получают рамки сразу и раскладываются внутри один
            // раз, пока действия слоя отключены: иначе их иконки/подписи тоже
            // приехали бы из нулевого кадра.
            for cell in shortcutCells {
                cell.layoutIfNeeded()
            }
        }

        appliedContentLayout = layout
    }

    /// Считает внутреннюю раскладку по ширине панели.
    ///
    /// Сторона ярлыка — юнит сетки (``TileLayoutEngine/panelTileSide(width:columns:)``):
    /// та же формула, что у плитки 1×1 на рабочем столе. Юнит считается по всей
    /// ширине панели и зазору `Metrics.cellSpacing`, поэтому по горизонтали
    /// ярлыки занимают ширину целиком и встают в те же колонки, что и плитки под
    /// панелью. Поля `Metrics.padding` действуют по вертикали и для заголовка.
    ///
    /// Высота в расчёт не входит: содержимое прижато к верхнему краю, а рост
    /// панели только обрезает его снизу.
    ///
    /// - Parameter width: Текущая ширина панели (вся ширина контента сетки).
    /// - Returns: Раскладка либо `nil` для вырожденной ширины.
    private func makeContentLayout(width: CGFloat) -> ContentLayout? {
        let padding = Metrics.padding
        let innerWidth = max(0, width - padding * 2)
        let columns = max(1, columnCount)
        let spacing = Metrics.cellSpacing
        let side = TileLayoutEngine.panelTileSide(width: width, columns: columns)
        guard side.isFinite, side > 0 else { return nil }

        let titleFrame = CGRect(
            x: padding,
            y: padding,
            width: innerWidth,
            height: Metrics.headerHeight
        )
        let originY = padding + Metrics.headerHeight + Metrics.headerSpacing
        let rightToLeft = isRightToLeft

        var tileFrames: [CGRect] = []
        tileFrames.reserveCapacity(shortcutCells.count)
        for index in shortcutCells.indices {
            let row = index / columns
            let logicalColumn = index % columns
            // §9, RTL: первый ярлык — в правом верхнем углу сетки панели.
            let column = rightToLeft ? columns - 1 - logicalColumn : logicalColumn
            tileFrames.append(
                CGRect(
                    x: CGFloat(column) * (side + spacing),
                    y: originY + CGFloat(row) * (side + spacing),
                    width: side,
                    height: side
                )
            )
        }

        return ContentLayout(
            width: width,
            columns: columns,
            rightToLeft: rightToLeft,
            tileCount: shortcutCells.count,
            titleFrame: titleFrame,
            tileFrames: tileFrames
        )
    }

    /// Сбрасывает кеш раскладки: состав, колонки или направление изменились.
    private func invalidateContentLayout() {
        contentLayout = nil
        appliedContentLayout = nil
    }

    /// Направление чтения панели (§9, RTL).
    private var isRightToLeft: Bool {
        effectiveUserInterfaceLayoutDirection == .rightToLeft
    }

    /// Выполняет изменения без неявных анимаций слоя.
    ///
    /// `layoutSubviews` панели вызывается в том числе внутри batch-обновления
    /// UICollectionView, где включён анимационный контекст: без отключения
    /// действий установка рамок подвью превратилась бы в анимацию «из нуля» и
    /// содержимое панели поехало бы во время роста её высоты.
    ///
    /// - Parameter changes: Изменения, которые не должны анимироваться.
    private func withoutImplicitAnimations(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    /// §9, RTL: направление чтения меняет порядок колонок в сетке панели.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if previousTraitCollection?.layoutDirection != traitCollection.layoutDirection {
            invalidateContentLayout()
            setNeedsLayout()
        }
    }

    // MARK: - Переиспользование

    override func prepareForReuse() {
        super.prepareForReuse()

        // Панель могла быть удалена посреди каскада: следующая папка не должна
        // унаследовать невидимые или сдвинутые иконки.
        withoutImplicitAnimations {
            for cell in shortcutCells {
                cell.layer.removeAllAnimations()
                cell.alpha = 1
                cell.transform = .identity
            }
        }
        tiles = []
        titleLabel.text = nil
        titleLabel.accessibilityLabel = nil
        onBackgroundTap = nil
        invalidateContentLayout()
    }

    // MARK: - Шрифт

    /// Шрифт заголовка: масштабируется Dynamic Type, но с потолком — строка
    /// заголовка в формуле панели фиксированной высоты (44 pt).
    private static func makeTitleFont() -> UIFont {
        let base = UIFont.systemFont(ofSize: 16, weight: .semibold)
        return UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: base,
            maximumPointSize: 28
        )
    }
}

// MARK: - Превью закрытой папки (D17)

/// Расписание idle-флипа превью папки (D17).
///
/// Закрытая папка переворачивает мини-иконки не одновременно и не по общему
/// таймеру: фаза зависит от идентификатора папки, поэтому соседние папки не
/// «мигают» в такт. Расчёт — чистая функция от seed: один и тот же
/// идентификатор и номер цикла дают одинаковые задержки, и это можно проверить
/// без таймеров (тесты E7.4).
///
/// Seed считается стабильным FNV-1a по строковому описанию идентификатора:
/// `hashValue` в Swift рандомизирован между запусками, а фаза должна оставаться
/// воспроизводимой и предсказуемой в тестах.
struct TesseraFolderFlipSchedule {

    /// Минимальный интервал между циклами флипа, секунды (D17: 4–6 с).
    static let minimumInterval: TimeInterval = 4

    /// Максимальный интервал между циклами флипа, секунды.
    static let maximumInterval: TimeInterval = 6

    /// Минимальная задержка первого цикла после появления папки на экране:
    /// флип не должен совпадать с появлением сетки.
    static let minimumInitialDelay: TimeInterval = 0.8

    /// Максимальный разброс старта мини-иконок внутри одного цикла, секунды.
    static let maximumStagger: TimeInterval = 0.35

    /// Сколько мини-иконка держит счётчик бэйджа до возврата к иконке, секунды.
    static let dwellDuration: TimeInterval = 2.6

    /// Seed расписания.
    let seed: UInt64

    /// Создаёт расписание по явному seed (тесты, повторное использование).
    ///
    /// - Parameter seed: Seed фаз и интервалов.
    init(seed: UInt64) {
        self.seed = seed
    }

    /// Создаёт расписание для папки: фаза детерминированно зависит от `id`.
    ///
    /// - Parameter folderID: Идентификатор папки на рабочем столе.
    init(folderID: AnyHashable) {
        self.init(seed: TesseraFolderFlipSchedule.seed(for: folderID))
    }

    /// Стабильный seed по идентификатору папки (FNV-1a по `String(describing:)`).
    ///
    /// - Parameter folderID: Идентификатор папки.
    /// - Returns: Seed, одинаковый в пределах и между запусками.
    static func seed(for folderID: AnyHashable) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in String(describing: folderID).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash &+ 0xE7_0002_0000_0001
    }

    /// Задержка до первого цикла после появления папки на экране.
    ///
    /// - Returns: Значение в диапазоне
    ///   `minimumInitialDelay...maximumInterval`.
    func initialDelay() -> TimeInterval {
        let fraction = TesseraFolderFlipSchedule.fraction(seed: seed, salt: 0x1)
        let span = TesseraFolderFlipSchedule.maximumInterval
            - TesseraFolderFlipSchedule.minimumInitialDelay
        return TesseraFolderFlipSchedule.minimumInitialDelay + fraction * span
    }

    /// Интервал до следующего цикла.
    ///
    /// - Parameter cycle: Номер цикла, начиная с 1.
    /// - Returns: Значение в диапазоне `minimumInterval...maximumInterval`.
    func interval(cycle: Int) -> TimeInterval {
        let salt = UInt64(bitPattern: Int64(cycle)) &* 0x9E37_79B9_7F4A_7C15 &+ 0x2
        let fraction = TesseraFolderFlipSchedule.fraction(seed: seed, salt: salt)
        let span = TesseraFolderFlipSchedule.maximumInterval
            - TesseraFolderFlipSchedule.minimumInterval
        return TesseraFolderFlipSchedule.minimumInterval + fraction * span
    }

    /// Задержка старта мини-иконки внутри цикла.
    ///
    /// - Parameter miniIndex: Индекс мини-плитки (0...3).
    /// - Returns: Значение в диапазоне `0...maximumStagger`.
    func stagger(miniIndex: Int) -> TimeInterval {
        let salt = UInt64(bitPattern: Int64(miniIndex)) &* 0xBF58_476D_1CE4_E5B9 &+ 0x3
        let fraction = TesseraFolderFlipSchedule.fraction(seed: seed, salt: salt)
        return fraction * TesseraFolderFlipSchedule.maximumStagger
    }

    /// Равномерная дробь `[0, 1)` из seed и соли.
    private static func fraction(seed: UInt64, salt: UInt64) -> Double {
        var generator = TesseraSeededGenerator(seed: seed &+ salt)
        // 53 старших бита — равномерная дробь без потери точности.
        return Double(generator.next() >> 11) / 9_007_199_254_740_992.0
    }
}

/// Превью закрытой папки: мини-сетка «до четырёх» иконок и idle-флип счётчиков
/// (D17).
///
/// ## Почему собственная механика, а не ``TesseraLiveTileEngine``
///
/// Движок и ``TesseraLiveTileView`` заточены под полноразмерную плитку:
/// регистрация движка принимает конкретный ``TesseraLiveTileView`` (не
/// протокол), а контейнер переворачивает две стороны вокруг оси **Y** и
/// раскладывает заголовок/подпись стороны. Папке нужны четыре независимых
/// мини-плитки, переворот вокруг оси **X** и никакого текста, поэтому
/// переиспользовать пару напрямую нельзя, а менять контракт движка в задаче
/// E7.2 нельзя (LiveTileEngine.swift вне её write-скоупа).
///
/// Контейнер повторяет принципы движка: таймер в `.common`, пауза вне экрана,
/// в фоне и при Reduce Motion, только `layer.transform`/`isHidden` в горячем
/// пути, seedable-расписание и сброс в устоявшееся состояние при
/// переиспользовании. Бэйдж — общий ``TesseraLiveTileBadgeView`` из E4.3.
///
/// ## Потоки
///
/// Только главный поток: таймер, уведомления и отложенные возвраты выполняются
/// в main queue.
final class TesseraFolderPreviewView: UIView {

    // MARK: - Метрики

    private enum Metrics {
        /// Зазор между мини-плитками как доля стороны блока: малый, но заметный.
        static let spacingRatio: CGFloat = 0.05
        static let minimumSpacing: CGFloat = 2
    }

    // MARK: - Состояние

    /// Мини-плитки в порядке ярлыков (не больше четырёх).
    private(set) var miniTileViews: [TesseraFolderMiniTileView] = []

    /// Расписание флипа; задаётся в ``configure(tiles:schedule:)``.
    private(set) var schedule = TesseraFolderFlipSchedule(seed: 0)

    /// Подпись содержимого (id + бэйдж): по ней ловится настоящее изменение
    /// папки, чтобы не сбрасывать фазу на каждом обновлении снимка.
    private var signature: [String] = []

    private var isVisible = false
    private var isExpanded = false
    private var isApplicationActive = UIApplication.shared.applicationState != .background

    /// Начиналось ли расписание: первый запуск идёт с ``initialDelay()``,
    /// последующие — с интервала цикла.
    private var hasStarted = false
    private var cycleIndex = 0

    private var cycleTimer: Timer?
    private var staggerWorkItems: [DispatchWorkItem] = []
    private var returnWorkItem: DispatchWorkItem?

    /// Поколение расписания: отложенные флипы прошлого поколения игнорируются.
    private var generation: UInt64 = 0

    private var reduceMotionObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    // MARK: - Инициализация

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        cycleTimer?.invalidate()
        staggerWorkItems.forEach { $0.cancel() }
        returnWorkItem?.cancel()

        let center = NotificationCenter.default
        for observer in [reduceMotionObserver, backgroundObserver, foregroundObserver] {
            if let observer {
                center.removeObserver(observer)
            }
        }
    }

    private func commonInit() {
        // Превью — декорация: папка остаётся одним accessibility-элементом
        // ячейки (§9), касания ей тоже не нужны.
        isAccessibilityElement = false
        isUserInteractionEnabled = false
        backgroundColor = .clear

        installObservers()
    }

    // MARK: - Конфигурация

    /// Применяет первые ярлыки папки и расписание флипа.
    ///
    /// Конфигурация идемпотентна: если состав и бэйджи не изменились (например,
    /// сетка обновила снимок из-за resize), фаза и таймер не сбрасываются.
    /// Настоящее изменение возвращает все мини-плитки к иконкам и запускает
    /// расписание заново.
    ///
    /// - Parameters:
    ///   - tiles: Ярлыки папки; берутся первые четыре.
    ///   - schedule: Расписание флипа (фаза по идентификатору папки).
    func configure(tiles: [TileDescriptor], schedule: TesseraFolderFlipSchedule) {
        let limitedTiles = Array(tiles.prefix(4))
        let newSignature = limitedTiles.map { tile -> String in
            // Идентичность иконки — через ObjectIdentifier: подмена картинки
            // у того же ярлыка должна перерисовать мини-плитку.
            let iconIdentity = tile.icon.map { String(describing: ObjectIdentifier($0)) } ?? "-"
            return "\(String(describing: tile.id))#\(String(describing: tile.badge))#\(iconIdentity)"
        }

        self.schedule = schedule
        guard newSignature != signature else { return }
        signature = newSignature

        stopAnimation()
        cycleIndex = 0

        while miniTileViews.count > limitedTiles.count {
            miniTileViews.removeLast().removeFromSuperview()
        }
        while miniTileViews.count < limitedTiles.count {
            let miniTile = TesseraFolderMiniTileView(frame: .zero)
            addSubview(miniTile)
            miniTileViews.append(miniTile)
        }
        for (miniTile, tile) in zip(miniTileViews, limitedTiles) {
            miniTile.configure(icon: tile.icon, badge: tile.badge)
        }

        setNeedsLayout()
        updateScheduling()
    }

    // MARK: - Жизненный цикл и паузы

    /// Сообщает, видима ли папка на экране (§4, «Паузы»).
    ///
    /// Вызывается на каждом показе/уходе ячейки и при скрытии на время drag.
    ///
    /// - Parameter visible: Видима ли ячейка.
    func setVisible(_ visible: Bool) {
        isVisible = visible
        updateScheduling()
    }

    /// Ставит превью на паузу, пока папка раскрыта (хук волны 2, E7.3).
    ///
    /// - Parameter expanded: Раскрыта ли папка.
    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        updateScheduling()
    }

    /// Полностью останавливает флип и возвращает иконки.
    ///
    /// Используется при переиспользовании ячейки: чужая папка не должна
    /// унаследовать фазу и счётчик.
    func stop() {
        isVisible = false
        isExpanded = false
        cycleIndex = 0
        stopAnimation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateScheduling()
    }

    /// §9, RTL: направление чтения меняет порядок мини-плиток в блоке.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if previousTraitCollection?.layoutDirection != traitCollection.layoutDirection {
            setNeedsLayout()
        }
    }

    // MARK: - Расписание

    /// Можно ли сейчас крутить idle-флип.
    ///
    /// Условия те же, что у ``TesseraLiveTileEngine`` (§4): плитка видима, не
    /// скрыта и в окне, приложение активно, Reduce Motion выключен и хотя бы у
    /// одной мини-плитки есть видимый бэйдж. Ярлыки без бэйджа не
    /// переворачиваются — у них остаётся иконка (D17).
    private var isAnimationAllowed: Bool {
        isVisible
            && !isExpanded
            && !isHidden
            && window != nil
            && isApplicationActive
            && !TesseraAccessibility.isReduceMotionEnabled
            && miniTileViews.contains { $0.hasVisibleBadge }
    }

    /// Перезапускает или останавливает расписание под текущее состояние.
    private func updateScheduling() {
        guard isAnimationAllowed else {
            stopAnimation()
            return
        }

        guard cycleTimer == nil else { return }

        let delay = hasStarted ? schedule.interval(cycle: cycleIndex) : schedule.initialDelay()
        hasStarted = true
        scheduleCycle(after: delay)
    }

    private func scheduleCycle(after delay: TimeInterval) {
        cycleTimer?.invalidate()

        let timer = Timer(timeInterval: max(0.1, delay), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.cycleTimer = nil
            self.runCycle()
        }
        cycleTimer = timer
        // `.common` — таймер продолжает идти во время трекинга прокрутки
        // коллекции, иначе превью «замирает» под пальцем (как у движка).
        RunLoop.main.add(timer, forMode: .common)
    }

    private func runCycle() {
        guard isAnimationAllowed else {
            updateScheduling()
            return
        }

        cycleIndex += 1
        generation &+= 1
        let currentGeneration = generation

        staggerWorkItems.forEach { $0.cancel() }
        staggerWorkItems.removeAll()
        returnWorkItem?.cancel()
        returnWorkItem = nil

        var maximumStagger: TimeInterval = 0
        for (index, miniTile) in miniTileViews.enumerated() where miniTile.hasVisibleBadge {
            let delay = schedule.stagger(miniIndex: index)
            maximumStagger = max(maximumStagger, delay)

            let workItem = DispatchWorkItem { [weak self, weak miniTile] in
                guard let self,
                      let miniTile,
                      self.generation == currentGeneration,
                      self.isAnimationAllowed else { return }
                miniTile.showBadge(animated: true)
            }
            staggerWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        let returnDelay = maximumStagger
            + TesseraFolderMiniTileView.flipDuration
            + TesseraFolderFlipSchedule.dwellDuration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.generation == currentGeneration, self.isAnimationAllowed else {
                return
            }
            self.miniTileViews.forEach { $0.showIcon(animated: true) }
        }
        returnWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + returnDelay, execute: workItem)

        // Следующий цикл стартует от начала текущего: период не зависит от
        // длительности возврата (D17: 4–6 с), а возврат гарантированно раньше.
        scheduleCycle(after: schedule.interval(cycle: cycleIndex))
    }

    /// Сбрасывает таймеры и отложенные флипы, возвращая мини-плитки к иконкам.
    private func stopAnimation() {
        generation &+= 1
        cycleTimer?.invalidate()
        cycleTimer = nil
        staggerWorkItems.forEach { $0.cancel() }
        staggerWorkItems.removeAll()
        returnWorkItem?.cancel()
        returnWorkItem = nil
        hasStarted = false
        miniTileViews.forEach { $0.settleOnIcon() }
    }

    // MARK: - Наблюдатели

    private func installObservers() {
        let center = NotificationCenter.default

        reduceMotionObserver = center.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateScheduling()
        }

        backgroundObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isApplicationActive = false
            self?.updateScheduling()
        }

        foregroundObserver = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isApplicationActive = true
            self?.updateScheduling()
        }
    }

    // MARK: - Раскладка

    /// Раскладывает мини-сетку 2×2 от верхнего угла по направлению чтения.
    ///
    /// Блок больше не центрируется: превью начинается с той же точки, что и
    /// плитки рабочего стола (верхний левый угол в LTR, верхний правый в RTL),
    /// поэтому закрытая папка читается как миниатюра настоящей сетки, а не как
    /// «картинка по центру». Во втором случае блок сам зеркалится по колонкам —
    /// первый ярлык остаётся первым в порядке чтения. Если ярлыков меньше
    /// четырёх, блок прижат к тому же верхнему углу, а не к центру.
    override func layoutSubviews() {
        super.layoutSubviews()

        guard bounds.width > 0, bounds.height > 0, !miniTileViews.isEmpty else { return }

        let side = min(bounds.width, bounds.height)
        let spacing = max(Metrics.minimumSpacing, side * Metrics.spacingRatio)
        let miniSide = max(0, (side - spacing) / 2)
        guard miniSide > 0 else {
            miniTileViews.forEach { $0.frame = .zero }
            return
        }

        let columns = min(2, miniTileViews.count)
        let contentWidth = CGFloat(columns) * miniSide + CGFloat(columns - 1) * spacing
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        // Верхний угол по направлению чтения: в LTR — левый, в RTL — правый.
        let originX = isRightToLeft ? bounds.width - contentWidth : 0
        let originY: CGFloat = 0

        for (index, miniTile) in miniTileViews.enumerated() {
            let row = index / 2
            let logicalColumn = index % 2
            // §9, RTL: первый ярлык — в правом верхнем углу блока.
            let column = isRightToLeft ? columns - 1 - logicalColumn : logicalColumn
            miniTile.frame = CGRect(
                x: originX + CGFloat(column) * (miniSide + spacing),
                y: originY + CGFloat(row) * (miniSide + spacing),
                width: miniSide,
                height: miniSide
            )
        }
    }
}

/// Одна мини-плитка превью папки: иконка ярлыка и его бэйдж на обратной стороне
/// (D17).
///
/// Переворот — вокруг оси **X** (у большой плитки — вокруг Y): у закрытой папки
/// мини-иконки «опрокидываются» вниз, как ячейки WP. Две фазы по половине
/// ``flipDuration``: уходящая сторона в ребро (+90°, перспектива `m34`),
/// подмена, доворот приходящей (−90° → 0°). Меняются только
/// `layer.transform` и `isHidden`; `frame`/`bounds` не трогаются — дисциплина
/// §4 и RISK.md R10.
final class TesseraFolderMiniTileView: UIView {

    /// Длительность полного переворота вокруг оси X, секунды.
    static let flipDuration: TimeInterval = 0.32

    private enum AnimationKey {
        static let outgoing = "tessera.folderMini.flip.outgoing"
        static let incoming = "tessera.folderMini.flip.incoming"
    }

    /// Расстояние до точки схода перспективы. Меньше, чем у большой плитки
    /// (500): на маленьком квадрате сильная перспектива «выворачивает» грань.
    private static let perspectiveDistance: CGFloat = 320

    private let frontView = UIView()
    private let backView = UIView()
    private let iconView = UIImageView()
    private let badgeView = TesseraLiveTileBadgeView()

    private(set) var badge: TileBadge = .none

    /// Показана ли сейчас обратная сторона со счётчиком.
    private(set) var showsBadgeSide = false

    private var flipGeneration: UInt64 = 0

    /// Есть ли что показывать на обратной стороне.
    var hasVisibleBadge: Bool { badge.isVisible }

    // MARK: - Инициализация

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // Мини-плитка — декорация внутри одного accessibility-элемента папки.
        isAccessibilityElement = false
        isUserInteractionEnabled = false
        backgroundColor = .clear

        frontView.isAccessibilityElement = false
        backView.isAccessibilityElement = false
        backView.backgroundColor = .tertiarySystemFill
        backView.clipsToBounds = true

        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false
        iconView.clipsToBounds = true
        frontView.addSubview(iconView)

        badgeView.isHidden = true
        backView.addSubview(badgeView)
        badgeView.onBadgeChange = { [weak self] in
            self?.setNeedsLayout()
        }

        backView.isHidden = true
        addSubview(frontView)
        addSubview(backView)
    }

    // MARK: - Содержимое

    /// Применяет иконку и бэйдж ярлыка; всегда возвращает плитку к иконке.
    ///
    /// - Parameters:
    ///   - icon: Иконка ярлыка; `nil` — нейтральный глиф-заглушка.
    ///   - badge: Бэйдж ярлыка (точка или счётчик).
    func configure(icon: UIImage?, badge: TileBadge) {
        self.badge = badge

        if let icon {
            iconView.image = icon
            iconView.tintColor = nil
        } else {
            // Ярлык без иконки: место в мини-сетке не должно пустовать.
            iconView.image = UIImage(systemName: "app.fill")
            iconView.tintColor = .secondaryLabel
        }

        badgeView.badge = badge
        settleOnIcon()
        setNeedsLayout()
    }

    /// Возвращает плитку к иконке без анимации (устоявшееся состояние).
    func settleOnIcon() {
        flipGeneration &+= 1
        showsBadgeSide = false
        frontView.layer.removeAllAnimations()
        backView.layer.removeAllAnimations()
        frontView.layer.transform = CATransform3DIdentity
        backView.layer.transform = CATransform3DIdentity
        frontView.isHidden = false
        backView.isHidden = true
        badgeView.isHidden = true
    }

    /// Переворачивает мини-плитку к счётчику бэйджа.
    ///
    /// - Parameter animated: `false` — мгновенная подмена (Reduce Motion).
    func showBadge(animated: Bool) {
        transition(toBadgeSide: true, animated: animated)
    }

    /// Переворачивает мини-плитку обратно к иконке.
    ///
    /// - Parameter animated: `false` — мгновенная подмена.
    func showIcon(animated: Bool) {
        transition(toBadgeSide: false, animated: animated)
    }

    // MARK: - Флип

    private func transition(toBadgeSide: Bool, animated: Bool) {
        guard toBadgeSide != showsBadgeSide else { return }
        guard !toBadgeSide || hasVisibleBadge else { return }

        guard animated, Self.flipDuration > 0 else {
            settleOn(toBadgeSide: toBadgeSide)
            return
        }

        flipGeneration &+= 1
        let currentGeneration = flipGeneration

        let outgoing = toBadgeSide ? frontView : backView
        let incoming = toBadgeSide ? backView : frontView
        incoming.isHidden = true

        let halfDuration = max(0.04, Self.flipDuration / 2)
        let halfOut = Self.perspectiveRotation(by: .pi / 2)
        let halfIn = Self.perspectiveRotation(by: -.pi / 2)

        let outgoingAnimation = CABasicAnimation(keyPath: "transform")
        outgoingAnimation.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        outgoingAnimation.toValue = NSValue(caTransform3D: halfOut)
        outgoingAnimation.duration = halfDuration
        outgoingAnimation.timingFunction = CAMediaTimingFunction(name: .easeIn)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.flipGeneration == currentGeneration else { return }
            self.beginIncomingFlip(
                incoming: incoming,
                outgoing: outgoing,
                toBadgeSide: toBadgeSide,
                initialTransform: halfIn,
                duration: halfDuration,
                generation: currentGeneration
            )
        }
        outgoing.layer.add(outgoingAnimation, forKey: AnimationKey.outgoing)
        outgoing.layer.transform = halfOut
        CATransaction.commit()
    }

    private func beginIncomingFlip(
        incoming: UIView,
        outgoing: UIView,
        toBadgeSide: Bool,
        initialTransform: CATransform3D,
        duration: TimeInterval,
        generation: UInt64
    ) {
        // Момент подмены: обе стороны повёрнуты ребром, смена видимости
        // незаметна. Layout не меняется — только hidden/transform.
        outgoing.isHidden = true
        outgoing.layer.transform = CATransform3DIdentity
        incoming.isHidden = false
        incoming.layer.transform = initialTransform
        // Бэйдж — часть обратной стороны: появляется и скрывается в момент
        // подмены, чтобы не «висеть» на поворачивающейся грани.
        badgeView.isHidden = !toBadgeSide

        let incomingAnimation = CABasicAnimation(keyPath: "transform")
        incomingAnimation.fromValue = NSValue(caTransform3D: initialTransform)
        incomingAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        incomingAnimation.duration = duration
        incomingAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.flipGeneration == generation else { return }
            self.settleOn(toBadgeSide: toBadgeSide)
        }
        incoming.layer.add(incomingAnimation, forKey: AnimationKey.incoming)
        incoming.layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// Приводит стороны к целевой стороне (мгновенно).
    private func settleOn(toBadgeSide: Bool) {
        showsBadgeSide = toBadgeSide
        frontView.layer.removeAllAnimations()
        backView.layer.removeAllAnimations()
        frontView.layer.transform = CATransform3DIdentity
        backView.layer.transform = CATransform3DIdentity
        frontView.isHidden = toBadgeSide
        backView.isHidden = !toBadgeSide
        badgeView.isHidden = !toBadgeSide
    }

    /// `CATransform3D` поворота вокруг оси X с перспективой (D17).
    ///
    /// `m34` — перспективный член матрицы: без него переворот выглядит плоским
    /// масштабированием.
    private static func perspectiveRotation(by angle: CGFloat) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / perspectiveDistance
        return CATransform3DRotate(transform, angle, 1, 0, 0)
    }

    // MARK: - Раскладка

    override func layoutSubviews() {
        super.layoutSubviews()

        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }

        frontView.frame = bounds
        backView.frame = bounds
        // Скругление как у иконки приложения: мини-плитка читается как ярлык.
        backView.layer.cornerRadius = side * 0.22

        let inset = side * 0.1
        iconView.frame = bounds.insetBy(dx: inset, dy: inset)

        let badgeSize = badgeView.intrinsicContentSize
        badgeView.frame = CGRect(
            x: (bounds.width - badgeSize.width) / 2,
            y: (bounds.height - badgeSize.height) / 2,
            width: badgeSize.width,
            height: badgeSize.height
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
