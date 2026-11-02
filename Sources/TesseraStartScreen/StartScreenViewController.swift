//
//  StartScreenViewController.swift
//  TesseraStartScreen
//
//  Экран рабочего стола: горизонтальный пейджер из одной–трёх страниц и
//  вертикальная сетка ярлыков с параллаксом обоев.
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md — §1 «Ключевая
//  архитектурная идея: три страницы» (START в центре, слева — хук, справа —
//  список приложений; политика левого края), §2 «Архитектура»
//  (StartScreenViewController → пейджер → StartPage с TileGridView и фоном),
//  §7 «Страница слева: хук» (ленивая загрузка и колбэки появления/скрытия),
//  §8 «Параллакс фона» (вертикаль, factor 0.4–0.6, только transform,
//  Reduce Motion → статично) и §9 «Accessibility» (accessibilityScroll,
//  озвучивание названия страницы, RTL).
//  Уточнения пользователя: D13 (боковые страницы существуют, только если хост
//  их задал; пейджер — от 1 до 3 страниц) — docs/STATE.md и §14 документа.
//  Задача плана: E4.1.
//
//  Границы ответственности:
//  - контроллер владеет композицией страниц и политикой края, но не данными:
//    снимок сетки приходит извне через ``TesseraStartScreenViewController/reload(grid:)``
//    (правило «один писатель», §6), действия ярлыков и навигацию выполняет хост;
//  - содержимое правой страницы не входит в этот таргет: контроллер получает
//    только фабрику `() -> UIViewController` и не знает её конкретного типа (D13);
//  - в горячем пути прокрутки сетки нет layout: offset уходит в
//    `TesseraParallaxLayer.update(withContentOffset:)`, который меняет только
//    `transform` (§8, docs/CORE-IOS-DESIGN.md §2).
//

#if canImport(UIKit)
import UIKit
import TesseraCore

/// Страница рабочего стола в порядке чтения (docs/STARTSCREEN-IOS-DESIGN.md §1).
///
/// Порядок объявления соответствует документу: слева — хук, в центре — START,
/// справа — список приложений. В RTL физическая раскладка страниц зеркалится
/// пейджером Core (`TesseraRTL`), а порядок чтения остаётся тем же.
public enum TesseraStartScreenPage: Hashable {

    /// Левая страница-хук (§7). Существует, только если хост передал
    /// ``QuickPanelProviding`` (D13).
    case quickPanel

    /// Центральная страница с сеткой ярлыков и обоями (§2, §8).
    case start

    /// Правая страница — список приложений и настройки (§2, §6).
    case applications
}

/// Контроллер рабочего стола: пейджер страниц, сетка START и обои с параллаксом.
///
/// ## Композиция (§1, §2, D13)
///
/// ```
/// StartScreenViewController
///     └─ TesseraPagerViewController (режим .paged)
///          ├─ QuickPanelPage   ← только если задан QuickPanelProviding
///          ├─ StartPage        ← TesseraTileGridView + TesseraParallaxLayer
///          └─ ApplicationsPage ← только если задана фабрика правой страницы
/// ```
///
/// Состав страниц масштабируется от одной (только START) до трёх (D13).
/// Страницы передаются пейджеру в порядке чтения; физическое зеркалирование
/// и нормализацию прогресса выполняет Core (`TesseraRTL`), поэтому здесь нет
/// собственной RTL-ветки.
///
/// ## Политика края (§1)
///
/// Свойство ``yieldsLeftEdgeToSystemGesture`` по умолчанию `false`: рабочий
/// стол — корневой экран, обе кромки наши. При `true` ведущая кромка уступается
/// системному жесту навигации, а страница-хук перестаёт быть частью
/// свайпаемого набора: её можно показать только программно через
/// ``showPage(_:animated:)``. Пока панель открыта программно, она остаётся в
/// пейджере; как только пользователь уходит с неё, страница убирается из
/// свайпаемого набора (см. ``yieldsLeftEdgeToSystemGesture``).
///
/// ## Арбитраж осей (§1, docs/CORE-IOS-DESIGN.md §2)
///
/// Пейджер владеет горизонталью, вертикаль — детям. Контроллер подписывается
/// на пан пейджера и по доминирующей оси
/// (``TesseraGestureArbiter/axisDecision(forVelocity:)``) на время
/// горизонтального жеста блокирует прокрутку детей, возвращая её по
/// завершении: сетку START — выключением её пан-жеста (её `isScrollEnabled`
/// принадлежит анимации папки и редактированию), скроллы боковых страниц —
/// через ``TesseraGestureArbiter``. Вертикальный жест остаётся детям и не
/// блокируется.
///
/// Арбитраж трёхсторонний (§1): вертикальных владельцев двое — сетка START и
/// скролл боковой страницы (хук §7 или список приложений §6). Сетка START
/// регистрируется автоматически: она есть в любой конфигурации (D13). Скроллы
/// опциональных страниц создаёт хост, поэтому контроллер их не знает — хост
/// регистрирует их сам через ``registerVerticalOwner(_:)`` из `viewDidLoad`
/// контроллера страницы и снимает через ``unregisterVerticalOwner(_:)``, если скролл
/// перестал использоваться. Оба метода — холодный путь: они не выполняются из
/// `scrollViewDidScroll` и не трогают layout.
///
/// ## События (§2, §7)
///
/// ``currentPage`` и события ``delegate`` идут от подтверждения пейджера
/// (завершение перехода). Страница-хук получает `quickPanelWillAppear`, как
/// только начинает появляться (свайп, программный показ, появление экрана с
/// открытым хуком), и `quickPanelDidDisappear` — когда полностью ушла с экрана
/// или экран скрылся; делегат получает те же переходы как
/// `didChangeHookVisibility`. Пока START за кадром, live-плитки сетки стоят на
/// паузе (§4).
///
/// ## Параллакс (§8)
///
/// START-страница держит `TesseraParallaxLayer` за сеткой. Offset приходит из
/// `TesseraTileGridView.onScrollOffsetChanged`; в этом колбэке выполняется
/// только `transform` фонового слоя — ни layout, ни перезагрузки ячеек
/// (docs/CORE-IOS-DESIGN.md §2, «Дисциплина производительности»). При
/// Reduce Motion слой сам замораживается (Core §2, п. 6).
///
/// ## Accessibility (§9)
///
/// - `accessibilityScroll` листает страницы в порядке чтения с учётом RTL;
/// - по завершении перехода озвучивается название страницы
///   (``TesseraAccessibility/announcePageChange(_:)``) — только смена
///   страницы на показанном экране, стартовая страница не озвучивается;
/// - названия страниц задаются свойствами ``quickPanelTitle``,
///   ``startPageTitle`` и ``applicationsPageTitle`` — хост их локализует.
///
/// - Important: Работает только на главном потоке: UI-состояние не
///   размазывается по модулям (docs/CORE-IOS-DESIGN.md §3).
public final class TesseraStartScreenViewController: UIViewController {

    // MARK: - Идентификаторы страниц

    /// Идентификатор START-страницы для пейджера Core.
    private static let startPageID = AnyHashable("TesseraStartScreen.start")

    /// Идентификатор страницы-хука для пейджера Core.
    ///
    /// Пейджер после W1 переиспользует контроллеры страниц с тем же `id`
    /// (docs/CORE-IOS-DESIGN.md, «Отступления реализации», п. 7). Замена
    /// поставщика в ``configure(leftPanel:rightPage:)`` поэтому меняет
    /// поколение в `id`: иначе пейджер оставил бы на экране контроллер
    /// прежнего поставщика.
    private var quickPanelPageID: AnyHashable {
        AnyHashable("TesseraStartScreen.quickPanel#\(quickPanelPageGeneration)")
    }

    /// Идентификатор правой страницы для пейджера Core (поколение — как у хука).
    private var applicationsPageID: AnyHashable {
        AnyHashable("TesseraStartScreen.applications#\(applicationsPageGeneration)")
    }

    /// Поколение страницы-хука: растёт при замене поставщика.
    private var quickPanelPageGeneration = 0

    /// Поколение правой страницы: растёт при каждой новой фабрике.
    private var applicationsPageGeneration = 0

    // MARK: - Публичная конфигурация

    /// Обои рабочего стола (§8).
    ///
    /// `nil` (по умолчанию) — обоев нет, видна системная подложка страницы.
    /// Изображение рисуется с `scaleAspectFill` и обрезается по видимому окну;
    /// смена картинки не пересоздаёт страницы и не трогает прокрутку.
    public var wallpaperImage: UIImage? {
        didSet {
            startPageController.wallpaperImage = wallpaperImage
        }
    }

    /// Множитель параллакса обоев (§8).
    ///
    /// Документ задаёт диапазон `0.4...0.6`; значения вне его зажимаются к
    /// ближайшей границе, `NaN` трактуется как `0.5`. При Reduce Motion
    /// действующий фактор равен нулю (``TesseraParallaxLayer``), но запас
    /// размера фона считается по заданному значению — включение настройки на
    /// лету не оставит пустых полос.
    public var wallpaperParallaxFactor: CGFloat = 0.5 {
        didSet {
            let sanitized = Self.sanitizedParallaxFactor(wallpaperParallaxFactor)

            // Свойство-наблюдатель при присваивании внутри себя повторно не
            // вызывается (Swift заменяет сохранённое значение молча), поэтому
            // страницу обновляем здесь же, а не «на следующем проходе».
            if sanitized != wallpaperParallaxFactor {
                wallpaperParallaxFactor = sanitized
            }
            startPageController.parallaxFactor = sanitized
        }
    }

    /// Уступать ли ведущую кромку системному жесту навигации (docs/STARTSCREEN-IOS-DESIGN.md §1).
    ///
    /// - `false` (по умолчанию) — рабочий стол задуман корневым экраном: обе
    ///   кромки принадлежат пейджеру, страница-хук доступна свайпом (если хост
    ///   её задал). Хост обязан не вкладывать экран в навигационный стек либо
    ///   сам отключить `interactivePopGestureRecognizer`.
    /// - `true` — экран живёт в навигационном стеке: ведущая кромка отдана
    ///   системе, а страница-хук исключается из свайпаемого набора. Открыть её
    ///   можно только программно — ``showPage(_:animated:)``. После ухода
    ///   пользователя с открытой программно панели она снова выпадает из
    ///   свайпа (пересборка страниц отложена на следующий проход run loop,
    ///   чтобы не менять набор страниц внутри колбэка пейджера).
    ///
    /// Пан пейджера требует проигрывания системного edge-жеста, если экран уже
    /// в стеке; это требование ставится один раз и после смены политики назад
    /// не снимается (UIKit не умеет отменять `require(toFail:)`). Поэтому
    /// задавайте свойство до показа экрана.
    ///
    /// - Note: В RTL физическая кромка зеркалится вместе со страницами: хуком
    ///   становится правая по экрану страница, и системной уступается именно
    ///   ведущая (в RTL — правая) кромка. Отдельной ветки здесь не нужно.
    public var yieldsLeftEdgeToSystemGesture: Bool = false {
        didSet {
            guard yieldsLeftEdgeToSystemGesture != oldValue else { return }

            if yieldsLeftEdgeToSystemGesture {
                // Панель уже на экране (например, политику включили после
                // программного показа) — оставляем её в наборе до ухода.
                if currentPage == .quickPanel, leftPanel != nil {
                    isQuickPanelUnlocked = true
                }
            } else {
                // Политика «обе кромки наши»: панель снова обычная страница.
                isQuickPanelUnlocked = false
            }

            rebuildPages()
            if isViewLoaded {
                view.setNeedsLayout()
            }
            applySystemEdgePriorityIfNeeded()
        }
    }

    /// Название страницы-хука для VoiceOver (§9).
    ///
    /// По умолчанию английское; хост локализует. Используется в озвучивании
    /// смены страницы и как `title` описания страницы пейджера.
    public var quickPanelTitle: String = "Quick panel"

    /// Наблюдатель смены страницы и видимости хука (UIKit-канал событий).
    ///
    /// Контроллер сообщает ``StartScreenDelegate/startScreen(_:didChangePage:index:)``
    /// по подтверждённому пейджером переходу (жест, программный показ,
    /// уход с исчезнувшей после ``configure(leftPanel:rightPage:)`` страницы) и
    /// ``StartScreenDelegate/startScreen(_:didChangeHookVisibility:)`` — при
    /// смене видимости страницы-хука, включая появление и уход самого экрана.
    /// Показ стартовой страницы событием не является.
    ///
    /// Тапы по сетке контроллер делегату не пересылает: в UIKit их отдаёт
    /// `gridView.onTap`, который остаётся за хостом (тот же делегат получает
    /// тапы в `StartScreenView` — фасад подписывается на `onTap` сам).
    ///
    /// Ссылка слабая: делегата удерживает хост (в SwiftUI — координатор фасада).
    public weak var delegate: StartScreenDelegate?

    /// Название START-страницы для VoiceOver (§9).
    public var startPageTitle: String = "Start"

    /// Название правой страницы для VoiceOver (§9).
    public var applicationsPageTitle: String = "Applications"

    /// Текущая страница в порядке чтения.
    ///
    /// До загрузки вида — ``TesseraStartScreenPage/start`` либо страница,
    /// запрошенная через ``showPage(_:animated:)`` до показа. После загрузки
    /// обновляется только по подтверждению пейджера — по завершении перехода
    /// (источник истины — Core, §2): анимированный ``showPage(_:animated:)``
    /// не меняет значение, пока переход не завершился, а перехваченный
    /// пальцем переход оставляет ту страницу, на которой пейджер остановился.
    public private(set) var currentPage: TesseraStartScreenPage = .start

    /// Сетка START-страницы.
    ///
    /// Открыта хосту для режима редактирования (E4.4): снэпшоты ячеек, рамки,
    /// пустышки и «желе» живут на сетке. Данные по-прежнему приходят только
    /// через ``reload(grid:)``; поля сетки (`contentInsets`) контроллер
    /// выставляет сам с учётом safe area — переопределять их не нужно.
    ///
    /// - Important: `onScrollOffsetChanged` сетки занят параллаксом (§8);
    ///   переопределять это замыкание нельзя — иначе обои перестанут двигаться.
    public var gridView: TesseraTileGridView {
        startPageController.gridView
    }

    // MARK: - Внутренние представления

    /// Пейджер Core в режиме `.paged`: снап даёт `isPagingEnabled` (§1, §2).
    private let pagerViewController: TesseraPagerViewController

    /// START-страница, которой контроллер владеет напрямую.
    ///
    /// Держим её сама, чтобы сетка и позиция прокрутки переживали пересборку
    /// страниц (`configure`): пейджер может выгрузить и запросить страницу
    /// заново, но получит тот же экземпляр.
    private let startPageController: TesseraStartPageViewController

    /// Страницы в порядке чтения (для индексов и озвучивания).
    private var pageOrder: [TesseraStartScreenPage] = []

    /// Текущая страница в порядке чтения — наш индекс, синхронизированный с
    /// пейджером по завершении переходов.
    private var currentPageIndex = 0

    /// Цель программного перехода, ещё не подтверждённая пейджером.
    ///
    /// Нужна только хуку: страница-хук считается видимой с момента запроса
    /// (колбэк `quickPanelWillAppear` — до появления, §7), а отложенная
    /// «заморозка» хука при политике края не должна убрать страницу, к которой
    /// идёт анимация. Снимается подтверждением, пересборкой страниц и
    /// перехватом перехода пальцем (`.began` пана пейджера).
    private var pendingPage: TesseraStartScreenPage?

    /// Последний прогресс пейджера `t` в порядке чтения.
    ///
    /// Видимость хука считается по нему: страница видна, пока
    /// `|t − индекс хука| < 1`. `nil` — прогресса ещё не было (нулевая ширина),
    /// тогда видимость берётся по ``currentPage``.
    private var lastPagerProgress: CGFloat?

    /// Показан ли экран (между `viewWillAppear` и `viewDidDisappear`).
    ///
    /// Колбэки хука (§7), события видимости и озвучивание страниц (§9) до
    /// показа экрана не отправляются: `viewDidLoad` — не появление.
    private var isScreenVisible = false

    // MARK: - Состояние страницы-хука

    /// Поставщик левой страницы (§7). `nil` — страницы нет (D13).
    private var leftPanel: QuickPanelProviding?

    /// Фабрика правой страницы (§6). `nil` — страницы нет (D13).
    private var rightPageFactory: (() -> UIViewController)?

    /// Видима ли страница-хук сейчас (для делегата, §7).
    private var isQuickPanelOnScreen = false

    /// Поставщик, получивший `quickPanelWillAppear` без парного
    /// `quickPanelDidDisappear`.
    ///
    /// `didDisappear` уходит именно ему: при замене или удалении поставщика,
    /// пока хук на экране, колбэки остаются симметричными (прежний получает
    /// `didDisappear`, новый — `willAppear`).
    private var appearedQuickPanel: QuickPanelProviding?

    /// Открыта ли страница-хук программно при политике ``yieldsLeftEdgeToSystemGesture``.
    ///
    /// Пока `true`, страница входит в набор пейджера (только программный
    /// доступ). Уход с неё снимает флаг и убирает страницу из свайпа.
    private var isQuickPanelUnlocked = false

    /// Запланирована ли отложенная «заморозка» страницы-хука.
    ///
    /// Пересборка страниц внутри `pager(_:didShowPageAt:)` была бы реентерабельной
    /// по отношению к пейджеру, поэтому выносится на следующий проход run loop.
    private var isQuickPanelLockScheduled = false

    /// Озвучивание названия страницы (§9).
    ///
    /// Внутренний шов для тестов: по умолчанию —
    /// ``TesseraAccessibility/announcePageChange(_:)``.
    var pageAnnouncer: (String) -> Void = { TesseraAccessibility.announcePageChange($0) }

    // MARK: - Политика края

    /// Скролл-вью пейджера, найденный в иерархии Core (для приоритета edge-жеста).
    ///
    /// Core не публикует скролл-вью; используется тот же контракт `loadView`
    /// пейджера (единственный прямой потомок — `UIScrollView`), что и в Pivot.
    /// Если иерархия Core изменится, поиск вернёт `nil`, и экран продолжит
    /// работать штатными средствами UIKit.
    private var pagerScrollView: UIScrollView?

    /// Поставлен ли уже приоритет системного edge-жеста над паном пейджера.
    private var didApplySystemEdgePriority = false

    // MARK: - Арбитраж осей (§1, CORE-IOS-DESIGN.md §2)

    /// Пан пейджера, на который подписан контроллер (владелец — Core).
    ///
    /// Подписка через `addTarget` аддитивна и не заменяет делегата
    /// `UIScrollView`: подмена делегата сломала бы его собственную обработку
    /// одновременных жестов.
    private weak var observedPagerPan: UIPanGestureRecognizer?

    /// Арбитр Core на время горизонтального жеста.
    ///
    /// Живёт только между `.began` и `.ended`: он удерживает вертикальные
    /// скролл-вью сильными ссылками, а страницы пейджер загружает лениво и
    /// пересоздаёт (§7), поэтому постоянное удержание продлевало бы жизнь
    /// выгруженному контенту.
    private var gestureArbiter: TesseraGestureArbiter?

    /// Пан сетки START, выключенный контроллером на время горизонтального
    /// жеста (`nil` — контроллер его не выключал).
    ///
    /// Сетка блокируется флагом жеста, а не `isScrollEnabled`: тот флаг
    /// принадлежит анимации папки и координатору редактирования (E10.6).
    private weak var lockedGridPan: UIGestureRecognizer?

    /// Слабая ссылка на вертикальный скролл-вью боковой страницы.
    ///
    /// Боковые страницы опциональны (D13) и выгружаются пейджером, поэтому
    /// между жестами контроллер не держит их сильными ссылками: выгруженная
    /// страница выпадает из реестра сама.
    private struct WeakVerticalOwner {
        weak var scrollView: UIScrollView?
    }

    /// Зарегистрированные хостом вертикальные владельцы боковых страниц (§1).
    ///
    /// Сетка START сюда не входит: она есть всегда и блокируется
    /// автоматически, отдельным флагом жеста (``lockedGridPan``).
    private var extraVerticalOwners: [WeakVerticalOwner] = []

    // MARK: - Инициализация

    /// Создаёт пустой рабочий стол.
    ///
    /// Пока хост не вызвал ``configure(leftPanel:rightPage:)``, существует одна
    /// страница START (D13). Снимок сетки передаётся позже через ``reload(grid:)``.
    public init() {
        pagerViewController = TesseraPagerViewController(mode: .paged)
        startPageController = TesseraStartPageViewController()
        super.init(nibName: nil, bundle: nil)
        startPageController.parallaxFactor = Self.sanitizedParallaxFactor(wallpaperParallaxFactor)
    }

    /// Инициализация из архива/сториборда не поддерживается: композиция
    /// строится кодом (§2).
    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Жизненный цикл

    /// Собирает иерархию и стартовую страницу.
    ///
    /// Колбэков хука, событий делегата и озвучивания здесь нет: загрузка вида —
    /// не появление экрана (§7, §9). Стартовая страница не озвучивается вовсе —
    /// VoiceOver сам объявит появившийся экран.
    public override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        configureSubviews()

        // Пересборка сама ставит пейджер на ``currentPage`` (в том числе на
        // страницу, запрошенную через `showPage` до загрузки).
        rebuildPages()
    }

    /// Раскладывает пейджер и применяет политику края.
    ///
    /// Единственный layout-проход контроллера: в горячем пути прокрутки сетки
    /// layout'а нет (§8).
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        pagerViewController.view.frame = view.bounds
        resolvePagerScrollViewIfNeeded()
        applySystemEdgePriorityIfNeeded()
    }

    /// Экран вот-вот появится: хук на текущей странице получает
    /// `quickPanelWillAppear` до появления, делегат — видимость хука (§7).
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        isScreenVisible = true
        updateQuickPanelVisibility()
    }

    /// Повторяет попытку включить политику края: навигационный контроллер
    /// может стать доступен только к показу.
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Страховка на случай appearance без `viewWillAppear`.
        if !isScreenVisible {
            isScreenVisible = true
            updateQuickPanelVisibility()
        }
        resolvePagerScrollViewIfNeeded()
        applySystemEdgePriorityIfNeeded()
    }

    /// Экран ушёл с экрана — хук получает колбэк скрытия, делегат — видимость (§7).
    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        isScreenVisible = false
        updateQuickPanelVisibility()
    }

    deinit {
        // Подписка на пан пейджера аддитивна: снимаем её явно, как в Pivot.
        observedPagerPan?.removeTarget(
            self,
            action: #selector(pagerPanDidChange(_:))
        )
    }

    // MARK: - Публичный API

    /// Применяет снимок сетки START-страницы.
    ///
    /// Данные приходят из `TileStore` (или от хоста) и не меняются контроллером:
    /// сетка только отображает снимок (§6, правило «один писатель»). Метод
    /// можно вызывать до показа экрана — сетка применит снимок без окна.
    ///
    /// - Parameter snapshot: Снимок ярлыков и папок.
    public func reload(grid snapshot: TileGridSnapshot) {
        startPageController.apply(snapshot: snapshot)
    }

    /// Задаёт боковые страницы и пересобирает пейджер (D13).
    ///
    /// Пейджер масштабируется от одной страницы до трёх:
    /// - `leftPanel != nil` добавляет левую страницу-хук;
    /// - `rightPage` добавляет правую страницу (список приложений/настройки);
    /// - `nil` убирает соответствующую страницу.
    ///
    /// Текущая страница сохраняется: если пользователь стоял на START, после
    /// добавления хука он остаётся на START, а не перескакивает на первую
    /// страницу (пейджер Core сохраняет страницу по `id`, контроллер после
    /// пересборки ещё и явно ставит пейджер на фактический индекс). Если
    /// текущая страница исчезла из нового набора, контроллер переходит на
    /// START и сообщает делегату о смене страницы.
    ///
    /// Новый поставщик хука (другой экземпляр) и новая фабрика правой страницы
    /// пересоздают соответствующую страницу — пейджер не оставит на экране
    /// контроллер прежнего поставщика. Если хук в этот момент на экране,
    /// прежний поставщик получает `quickPanelDidDisappear`, новый —
    /// `quickPanelWillAppear` (§7); для делегата хук остаётся видимым, событий
    /// видимости нет.
    ///
    /// - Parameters:
    ///   - leftPanel: Поставщик страницы-хука (§7); `nil` — страницы нет.
    ///   - rightPage: Фабрика контроллера правой страницы; `nil` — страницы нет.
    ///     Фабрика может вызываться повторно (пейджер лениво выгружает страницы
    ///     ±1) и должна возвращать контроллер, который можно встроить заново.
    ///
    /// - Note: Вертикальный скролл боковой страницы регистрируется отдельно —
    ///   через ``registerVerticalOwner(_:)`` из `viewDidLoad` контроллера
    ///   страницы (§1).
    public func configure(
        leftPanel: QuickPanelProviding?,
        rightPage: (() -> UIViewController)?
    ) {
        if !Self.isSameProvider(self.leftPanel, leftPanel) {
            // Прежний поставщик уходит: парный `didDisappear` — до замены,
            // иначе он ушёл бы новому (или никому при удалении хука).
            sendQuickPanelDidDisappearIfNeeded()
            if leftPanel != nil {
                quickPanelPageGeneration += 1
            }
        }
        if rightPage != nil {
            // Замыкания несравнимы: новая фабрика — новая страница.
            applicationsPageGeneration += 1
        }

        self.leftPanel = leftPanel
        self.rightPageFactory = rightPage

        if leftPanel == nil {
            isQuickPanelUnlocked = false
        }

        rebuildPages()
    }

    /// Обновляет источники боковых страниц без пересборки пейджера.
    ///
    /// Путь SwiftUI-фасада (E10.8): поставщик хука и фабрика правой страницы,
    /// созданные в `body`, приходят новыми экземплярами на каждой перерисовке.
    /// Пересборка пейджера на каждый кадр остановила бы идущий свайп, поэтому
    /// при неизменном наличии страниц источники заменяются «тихо»: уже
    /// загруженные страницы остаются, новые экземпляры используются при
    /// следующем создании страницы и для колбэков хука (логически это тот же
    /// поставщик — его актуальное описание).
    ///
    /// - Precondition: Наличие хука и правой страницы не меняется; иначе нужен
    ///   ``configure(leftPanel:rightPage:)``.
    func updateSidePageSources(
        leftPanel: QuickPanelProviding?,
        rightPage: (() -> UIViewController)?
    ) {
        guard (leftPanel != nil) == (self.leftPanel != nil),
              (rightPage != nil) == (rightPageFactory != nil) else {
            configure(leftPanel: leftPanel, rightPage: rightPage)
            return
        }

        self.leftPanel = leftPanel
        self.rightPageFactory = rightPage
        if appearedQuickPanel != nil {
            appearedQuickPanel = leftPanel
        }
    }

    /// Программно показывает страницу в порядке чтения.
    ///
    /// Единственный способ открыть страницу-хук при
    /// ``yieldsLeftEdgeToSystemGesture == true``: страница на время показа
    /// добавляется в пейджер, поэтому первое открытие пересобирает набор
    /// страниц. Переход сообщается так же, как свайп: `quickPanelWillAppear`
    /// (до появления), событие делегата и анонс VoiceOver — по завершении.
    ///
    /// ``currentPage`` меняется по подтверждению пейджера: без анимации — сразу,
    /// с анимацией — по её завершении (палец может перехватить переход).
    ///
    /// При Reduce Motion анимация перехода отключается (§9). Если запрошенной
    /// страницы нет (нет хука или фабрики правой страницы), вызов — no-op,
    /// кроме случая до загрузки вида: намерение запоминается, и первый layout
    /// покажет нужную страницу.
    ///
    /// - Parameters:
    ///   - page: Целевая страница.
    ///   - animated: Намерение анимировать переход; Reduce Motion приоритетнее.
    public func showPage(_ page: TesseraStartScreenPage, animated: Bool) {
        let shouldAnimate = animated && !TesseraAccessibility.isReduceMotionEnabled

        guard isViewLoaded else {
            // До показа вида запоминаем намерение: `viewDidLoad` соберёт
            // страницы из актуальной конфигурации и встанет на нужную.
            guard canInclude(page) else { return }
            // Программный разворот нужен только если открываем хук при
            // политике уступки края; для остальных целей он снимается, чтобы
            // страница-хук не попала в свайп «за компанию».
            isQuickPanelUnlocked = (page == .quickPanel && yieldsLeftEdgeToSystemGesture)
            currentPage = page
            return
        }

        // Политика края: хука нет в свайпе — разворачиваем его программно.
        if page == .quickPanel,
           yieldsLeftEdgeToSystemGesture,
           !isQuickPanelUnlocked,
           leftPanel != nil {
            isQuickPanelUnlocked = true
            rebuildPages()
        }

        guard let index = pageOrder.firstIndex(of: page) else { return }

        // Цель — до перехода: хук получает `willAppear` до появления (§7).
        pendingPage = page == currentPage ? nil : page
        updateQuickPanelVisibility()

        pagerViewController.go(toPage: index, animated: shouldAnimate)

        // Переход без анимации синхронен: подтверждение (если страница
        // сменилась) уже пришло через `didShowPageAt`.
        if !shouldAnimate {
            pendingPage = nil
            updateQuickPanelVisibility()
        }
    }

    // MARK: - Регистрация вертикальных владельцев (§1)

    /// Регистрирует вертикальный скролл-вью боковой страницы.
    ///
    /// Арбитраж трёхсторонний (§1): горизонталь принадлежит пейджеру, вертикаль —
    /// сетке START и скроллам боковых страниц. Сетку START контроллер
    /// регистрирует сам (она есть в любой конфигурации, D13), а скроллы
    /// опциональных страниц создаёт хост, поэтому о них нужно сообщить:
    ///
    /// ```swift
    /// // В контроллере боковой страницы:
    /// override func viewDidLoad() {
    ///     super.viewDidLoad()
    ///     startScreen.registerVerticalOwner(listPage.scrollView)
    /// }
    /// ```
    ///
    /// Регистрируйте скролл в `viewDidLoad` контроллера страницы, когда
    /// скролл-вью уже существует. Не полагайтесь на `viewDidAppear`: после W1
    /// пейджер пересылает appearance только текущей странице, а соседи ±1
    /// загружаются без него — свайп с START начинается раньше, чем боковая
    /// страница «появится». На время
    /// горизонтального жеста пейджера прокрутка владельца блокируется и по
    /// завершении жеста получает прежнее `isScrollEnabled`
    /// (``TesseraGestureArbiter``). Вертикальный жест не блокируется — он
    /// остаётся странице.
    ///
    /// Ссылки слабые: когда пейджер выгружает страницу (D13, ленивая загрузка
    /// ±1), её скролл выпадает из реестра сам — снимать регистрацию не
    /// обязательно. Повторная регистрация того же экземпляра — no-op. Скролл-вью
    /// самого пейджера в арбитраж не попадает (``TesseraGestureArbiter``
    /// исключает горизонтального владельца).
    ///
    /// - Parameter scrollView: Вертикальный скролл-вью боковой страницы; у
    ///   ``TesseraAppsListPageViewController`` это его `scrollView`.
    ///
    /// - Note: Регистрация пополняет список владельцев, из которого арбитр
    ///   собирается на каждый жест: второй арбитр для боковых страниц не
    ///   создаётся — START-сетка и они блокируются одним и тем же
    ///   ``TesseraGestureArbiter``. Если горизонтальный жест уже идёт,
    ///   регистрация вступит в силу со следующего жеста: арбитр собирается на
    ///   `.began` и в Core не расширяется.
    public func registerVerticalOwner(_ scrollView: UIScrollView) {
        guard scrollView !== pagerScrollView else { return }

        pruneExtraVerticalOwners()
        guard !extraVerticalOwners.contains(where: { $0.scrollView === scrollView }) else {
            return
        }
        extraVerticalOwners.append(WeakVerticalOwner(scrollView: scrollView))
    }

    /// Снимает регистрацию вертикального скролл-вью боковой страницы.
    ///
    /// Вызывать не обязательно: ссылки слабые, и освобождённые скроллы выпадают
    /// из арбитража сами. Метод нужен, когда страница живёт дальше, но её
    /// скролл больше не должен блокироваться на время горизонтального жеста
    /// (например, хост переиспользует скролл-вью для другой страницы).
    ///
    /// - Parameter scrollView: Ранее зарегистрированный вертикальный скролл-вью.
    public func unregisterVerticalOwner(_ scrollView: UIScrollView) {
        extraVerticalOwners.removeAll { owner in
            guard let registered = owner.scrollView else { return true }
            return registered === scrollView
        }
    }

    // MARK: - Accessibility (§9)

    /// Пагинация страниц жестом VoiceOver «три пальца».
    ///
    /// Направление переводится в шаг по страницам через
    /// ``TesseraAccessibility/pageStep(for:layoutDirection:)`` с учётом RTL;
    /// переход выполняет ``showPage(_:animated:)``, поэтому `contentOffset`
    /// по-прежнему пишет только пейджер (docs/CORE-IOS-DESIGN.md §2).
    ///
    /// Вертикальные направления возвращают `false`: вертикаль принадлежит
    /// сетке (вариант B, §1).
    ///
    /// - Parameter direction: Направление жеста VoiceOver.
    /// - Returns: `true`, если жест обработан.
    public override func accessibilityScroll(
        _ direction: UIAccessibilityScrollDirection
    ) -> Bool {
        guard isViewLoaded, !pageOrder.isEmpty else { return false }

        let step = TesseraAccessibility.pageStep(
            for: direction,
            layoutDirection: view.effectiveUserInterfaceLayoutDirection
        )
        guard step != 0 else { return false }

        let targetIndex = currentPageIndex + step
        guard pageOrder.indices.contains(targetIndex) else { return false }

        showPage(
            pageOrder[targetIndex],
            animated: !TesseraAccessibility.isReduceMotionEnabled
        )
        return true
    }

    // MARK: - Сборка представлений

    /// Добавляет пейджер ребёнком и задаёт его делегата (§2).
    private func configureSubviews() {
        startPageController.parallaxFactor = Self.sanitizedParallaxFactor(
            wallpaperParallaxFactor
        )
        startPageController.wallpaperImage = wallpaperImage

        addChild(pagerViewController)
        pagerViewController.view.frame = view.bounds
        pagerViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pagerViewController.view)
        pagerViewController.didMove(toParent: self)
        pagerViewController.delegate = self
    }

    // MARK: - Пересборка страниц

    /// Пересобирает набор страниц пейджера из текущей конфигурации (D13).
    ///
    /// Один источник и для порядка страниц, и для `TesseraPageDescriptor`:
    /// `pageOrder` и набор пейджера всегда строятся вместе, поэтому индексы
    /// озвучивания и `accessibilityScroll` не расходятся с пейджером.
    ///
    /// После `reload(pages:)` пейджер явно ставится на фактический индекс
    /// подтверждённой страницы (`go(toPage:animated: false)`): Core сохраняет
    /// страницу по `id`, но смена поколения `id` (замена поставщика), зажим
    /// индекса при исчезновении страницы и прерванная анимация не должны
    /// оставить на экране не ту страницу, о которой знает контроллер (E10.6).
    /// Незавершённый программный переход при этом отменяется.
    ///
    /// Пересборка вызывается только из «холодных» путей (конфигурация,
    /// программный показ, уход со страницы-хука) — не из `scrollViewDidScroll`.
    private func rebuildPages() {
        let built = makePages()
        let order = built.map { $0.page }
        pageOrder = order

        var anchor = currentPage
        if !order.contains(anchor) {
            if anchor == .quickPanel {
                isQuickPanelUnlocked = false
            }
            anchor = order.contains(.start) ? .start : (order.first ?? .start)
        }

        guard isViewLoaded else {
            currentPage = anchor
            currentPageIndex = order.firstIndex(of: anchor) ?? 0
            return
        }

        // Перезагрузка отменяет анимацию пейджера — цель больше не ждём.
        pendingPage = nil
        // Свежий прогресс придёт из `reload` (восстановление offset'а).
        lastPagerProgress = nil
        pagerViewController.reload(pages: built.map { $0.descriptor })

        let index = order.firstIndex(of: anchor) ?? 0
        if anchor != currentPage {
            // Текущая страница исчезла: это смена страницы для делегата и
            // VoiceOver, даже если пейджер не успеет подтвердить её сам
            // (например, при нулевой ширине до первого layout'а).
            confirmPage(anchor, at: index)
        } else {
            currentPageIndex = index
        }

        pagerViewController.go(toPage: index, animated: false)
        updateQuickPanelVisibility()
    }

    /// Собирает пары «страница в порядке чтения — описание для пейджера».
    ///
    /// Замыкания захватывают `self` слабо: пейджер удерживается контроллером,
    /// поэтому сильный захват замкнул бы цикл `контроллер → пейджер → страница`.
    private func makePages() -> [(page: TesseraStartScreenPage, descriptor: TesseraPageDescriptor)] {
        var result: [(page: TesseraStartScreenPage, descriptor: TesseraPageDescriptor)] = []

        // D13 + политика края: хук существует, только если хост его задал, и
        // попадает в свайпаемый набор при политике «обе кромки наши» либо
        // после программного разворота.
        if leftPanel != nil, !yieldsLeftEdgeToSystemGesture || isQuickPanelUnlocked {
            let descriptor = TesseraPageDescriptor(
                id: quickPanelPageID,
                title: quickPanelTitle,
                makeContent: { [weak self] in
                    guard let self, let panel = self.leftPanel else {
                        return UIViewController()
                    }
                    return panel.makeQuickPanelViewController()
                }
            )
            result.append((.quickPanel, descriptor))
        }

        let startDescriptor = TesseraPageDescriptor(
            id: Self.startPageID,
            title: startPageTitle,
            makeContent: { [weak self] in
                self?.startPageController ?? UIViewController()
            }
        )
        result.append((.start, startDescriptor))

        if rightPageFactory != nil {
            let descriptor = TesseraPageDescriptor(
                id: applicationsPageID,
                title: applicationsPageTitle,
                makeContent: { [weak self] in
                    self?.rightPageFactory?() ?? UIViewController()
                }
            )
            result.append((.applications, descriptor))
        }

        return result
    }

    // MARK: - Подтверждение страницы

    /// Фиксирует страницу, подтверждённую пейджером, и рассылает события.
    ///
    /// Единственное место записи ``currentPage`` после загрузки вида: смена
    /// страницы сообщается делегату и озвучивается (только если экран
    /// показан, §9), повторное подтверждение той же страницы (пейджер заново
    /// сообщает её после `reload`) — нет.
    private func confirmPage(_ page: TesseraStartScreenPage, at index: Int) {
        currentPageIndex = index
        if pendingPage == page {
            pendingPage = nil
        }

        let changed = page != currentPage
        currentPage = page
        updateQuickPanelVisibility()

        if changed {
            delegate?.startScreen(self, didChangePage: page, index: index)
            if isScreenVisible {
                pageAnnouncer(pageTitle(for: page))
            }
        }

        scheduleQuickPanelLockIfNeeded(after: page)
    }

    // MARK: - Страница-хук (§7)

    /// Видна ли страница-хук сейчас.
    ///
    /// Хук виден, если экран показан и страница хотя бы частично в окне
    /// пейджера (`|t − индекс хука| < 1`) либо к ней идёт программный переход
    /// (тогда `willAppear` приходит до появления).
    private var isQuickPanelVisible: Bool {
        guard isScreenVisible,
              leftPanel != nil,
              let index = pageOrder.firstIndex(of: .quickPanel) else {
            return false
        }
        if pendingPage == .quickPanel {
            return true
        }
        guard let progress = lastPagerProgress, progress.isFinite else {
            return currentPage == .quickPanel
        }
        return abs(progress - CGFloat(index)) < 1 - Self.pageVisibilityEpsilon
    }

    /// Доля страницы, при которой она считается ушедшей с экрана.
    private static let pageVisibilityEpsilon: CGFloat = 0.001

    /// Приводит колбэки хука и событие делегата к текущей видимости (§7).
    ///
    /// Поставщику — `quickPanelWillAppear` при появлении и
    /// `quickPanelDidDisappear` тому же экземпляру при скрытии; делегату —
    /// `didChangeHookVisibility` только при смене значения. Вызывается и из
    /// колбэка прогресса пейджера: здесь нет layout'а, только сравнение и
    /// (раз за переход) колбэки.
    private func updateQuickPanelVisibility() {
        let visible = isQuickPanelVisible

        if visible {
            if appearedQuickPanel == nil, let panel = leftPanel {
                appearedQuickPanel = panel
                panel.quickPanelWillAppear()
            }
        } else {
            sendQuickPanelDidDisappearIfNeeded()
        }

        guard visible != isQuickPanelOnScreen else { return }
        isQuickPanelOnScreen = visible
        delegate?.startScreen(self, didChangeHookVisibility: visible)
    }

    /// Отправляет `quickPanelDidDisappear` поставщику, получившему `willAppear`.
    private func sendQuickPanelDidDisappearIfNeeded() {
        guard let appeared = appearedQuickPanel else { return }
        appearedQuickPanel = nil
        appeared.quickPanelDidDisappear()
    }

    /// Тот же ли это поставщик хука.
    ///
    /// Классовые поставщики сравниваются по ссылке; значимые типы сравнить
    /// нельзя (бокс каждый раз новый) — они считаются новым поставщиком.
    private static func isSameProvider(
        _ lhs: QuickPanelProviding?,
        _ rhs: QuickPanelProviding?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return (lhs as AnyObject) === (rhs as AnyObject)
        default:
            return false
        }
    }

    /// Возвращает хук в разряд «только программно» после ухода с него.
    ///
    /// Пересборка страниц отложена: `didShowPageAt` вызывается пейджером из
    /// завершения его перехода, и менять набор страниц прямо в этом колбэке —
    /// реентерабельность. К следующему проходу run loop пользователь уже не на
    /// панели (или успел вернуться, или к панели идёт программный переход —
    /// тогда панель остаётся открытой).
    private func scheduleQuickPanelLockIfNeeded(after page: TesseraStartScreenPage) {
        guard yieldsLeftEdgeToSystemGesture,
              isQuickPanelUnlocked,
              page != .quickPanel,
              leftPanel != nil,
              !isQuickPanelLockScheduled else {
            return
        }

        isQuickPanelLockScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isQuickPanelLockScheduled = false

            guard self.yieldsLeftEdgeToSystemGesture, self.isQuickPanelUnlocked else { return }
            // Пользователь успел вернуться на панель (или к ней идёт
            // программный переход) — оставляем её в наборе, следующая
            // попытка ухода снова сюда попадёт.
            guard self.currentPage != .quickPanel,
                  self.pendingPage != .quickPanel else { return }

            self.isQuickPanelUnlocked = false
            self.rebuildPages()
        }
    }

    // MARK: - Политика края (§1)

    /// Находит скролл-вью пейджера по контракту его иерархии.
    ///
    /// `TesseraPagerViewController` не публикует скролл-вью (тот же открытый
    /// вопрос, что и в Pivot). Если Core начнёт класть в корневой вид не только
    /// `UIScrollView`, поиск вернёт `nil` — политика края просто не применит
    /// приоритет, падения нет.
    private func resolvePagerScrollViewIfNeeded() {
        guard pagerScrollView == nil else { return }

        guard let scrollView = pagerViewController.view.subviews
            .compactMap({ $0 as? UIScrollView })
            .first else {
            return
        }

        pagerScrollView = scrollView
        observePagerPan(scrollView.panGestureRecognizer)
    }

    /// Уступает ведущую кромку системному жесту навигации (§1).
    ///
    /// Требование к пару пейджера проигрывать edge-жест ставится один раз и не
    /// заменяет делегатов жестов (замена делегата `UIScrollView` сломала бы его
    /// собственную обработку одновременных жестов). Вне кромки системный жест
    /// сразу фейлится, поэтому обычный свайп пейджера не страдает. Вне
    /// навигационного стека (`interactivePopGestureRecognizer == nil`) политика
    /// сводится к исключению страницы-хука из свайпа.
    ///
    /// Layout не выполняется — только настройка зависимостей распознавателей.
    private func applySystemEdgePriorityIfNeeded() {
        guard yieldsLeftEdgeToSystemGesture, !didApplySystemEdgePriority else { return }
        guard let pagerScrollView,
              let popGesture = navigationController?.interactivePopGestureRecognizer else {
            return
        }
        // Не меняем зависимости у уже начавшегося жеста: дождёмся layout'а,
        // когда пан снова в состоянии `.possible`.
        guard pagerScrollView.panGestureRecognizer.state == .possible else { return }

        pagerScrollView.panGestureRecognizer.require(toFail: popGesture)
        didApplySystemEdgePriority = true
    }

    // MARK: - Арбитраж осей (§1, CORE-IOS-DESIGN.md §2)

    /// Подписывается на состояния пана пейджера, не заменяя его делегата.
    private func observePagerPan(_ pan: UIPanGestureRecognizer) {
        guard observedPagerPan !== pan else { return }

        observedPagerPan?.removeTarget(
            self,
            action: #selector(pagerPanDidChange(_:))
        )
        pan.addTarget(self, action: #selector(pagerPanDidChange(_:)))
        observedPagerPan = pan
    }

    /// Реакция на пан пейджера: блокировка/разблокировка вертикальных детей.
    ///
    /// Layout здесь не выполняется — только флаги прокрутки. `.began` во время
    /// программной анимации означает перехват перехода пальцем: цель
    /// `showPage` больше не ждём, страницу подтвердит сам пейджер.
    @objc private func pagerPanDidChange(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            if pendingPage != nil {
                pendingPage = nil
                updateQuickPanelVisibility()
            }
            beginHorizontalScroll(isHorizontal: isHorizontalPan(pan))
        case .ended, .cancelled, .failed:
            endHorizontalScroll()
        case .possible, .changed:
            break
        @unknown default:
            endHorizontalScroll()
        }
    }

    /// Начинает горизонтальный жест: на время жеста дети не прокручиваются.
    ///
    /// Детей двое (§1): сетка START (блокируется автоматически) и скроллы
    /// боковых страниц, зарегистрированные хостом через
    /// ``registerVerticalOwner(_:)``.
    ///
    /// Сетка START блокируется не через `isScrollEnabled`, а выключением её
    /// пан-жеста (`panGestureRecognizer.isEnabled`): `isScrollEnabled` сетки
    /// пишут и анимация панели папки (D17), и координатор редактирования, оба
    /// со своим снимком «было/стало». Снимок арбитра поверх их снимков
    /// гонялся с ними и мог навсегда оставить сетку выключенной (E10.6).
    /// Отдельный флаг жеста с ними не пересекается: контроллер включает пан
    /// обратно, только если сам его выключил. Скроллы боковых страниц
    /// по-прежнему блокирует ``TesseraGestureArbiter`` (их флаг больше никто
    /// не трогает).
    ///
    /// Решение по доминирующей оси принимается по первому доступному вектору
    /// пана (как в Pivot): заменить делегата пана пейджера нельзя, поэтому
    /// `gestureRecognizerShouldBegin` арбитра не назначается. Если жест
    /// вертикальный, дети остаются прокручиваемыми — иначе выключение
    /// скролл-вью остановило бы начавшуюся вертикальную прокрутку (§1,
    /// CORE-IOS-DESIGN.md §2 «Арбитраж»).
    ///
    /// - Parameter isHorizontal: Доминирует ли горизонталь в начавшемся жесте.
    func beginHorizontalScroll(isHorizontal: Bool) {
        guard isHorizontal else {
            // Вертикаль принадлежит детям: снимаем возможную прошлую
            // блокировку и не трогаем их прокрутку.
            endHorizontalScroll()
            return
        }

        // Защита от наложения жестов: незавершённая блокировка сначала
        // снимается, иначе исходные состояния потеряются.
        if gestureArbiter != nil || lockedGridPan != nil {
            endHorizontalScroll()
        }

        if let gridPan = startPageController.gridScrollView?.panGestureRecognizer,
           gridPan.isEnabled {
            gridPan.isEnabled = false
            lockedGridPan = gridPan
        }

        guard let pagerScrollView else { return }
        pruneExtraVerticalOwners()
        let arbiter = TesseraGestureArbiter(
            horizontalOwner: pagerScrollView,
            verticalOwners: sidePageVerticalOwners
        )
        arbiter.prepareForHorizontalScroll()
        gestureArbiter = arbiter
    }

    /// Доминирующая горизонталь ли у только начавшегося пана пейджера.
    ///
    /// Повторяет запасной путь Core: при нулевой скорости ось определяется по
    /// смещению (масштаб для сравнения модулей не важен).
    private func isHorizontalPan(_ pan: UIPanGestureRecognizer) -> Bool {
        let velocity = pan.velocity(in: pan.view)
        let vector = velocity == .zero ? pan.translation(in: pan.view) : velocity
        return TesseraGestureArbiter.axisDecision(forVelocity: vector) == .horizontal
    }

    /// Завершает горизонтальный жест: возвращает детям прокрутку.
    ///
    /// Пан сетки включается безусловно, если его выключил контроллер: его
    /// флаг больше никто не пишет, а `isScrollEnabled` сетки остаётся за её
    /// собственными владельцами. После этого арбитр освобождается: сильных
    /// ссылок на скролл-вью боковых страниц между жестами контроллер не
    /// держит, выгруженные страницы (D13) не живут в арбитре.
    func endHorizontalScroll() {
        if let gridPan = lockedGridPan {
            gridPan.isEnabled = true
            lockedGridPan = nil
        }
        gestureArbiter?.endHorizontalScroll()
        gestureArbiter = nil
        pruneExtraVerticalOwners()
    }

    /// Вертикальные владельцы боковых страниц для арбитра.
    ///
    /// Сетка START сюда не входит — её блокирует отдельный флаг жеста (см.
    /// ``beginHorizontalScroll(isHorizontal:)``). Повторы и сам скролл-вью
    /// пейджера отсекаем здесь, не полагаясь на внутреннюю фильтрацию
    /// ``TesseraGestureArbiter``.
    private var sidePageVerticalOwners: [UIScrollView] {
        var owners: [UIScrollView] = []
        let gridScrollView = startPageController.gridScrollView

        for owner in extraVerticalOwners {
            guard let scrollView = owner.scrollView,
                  scrollView !== pagerScrollView,
                  scrollView !== gridScrollView,
                  !owners.contains(where: { $0 === scrollView }) else {
                continue
            }
            owners.append(scrollView)
        }

        return owners
    }

    /// Убирает из реестра освобождённые скролл-вью боковых страниц.
    ///
    /// Пейджер выгружает страницы лениво (D13), поэтому их скроллы исчезают без
    /// явного ``unregisterVerticalOwner(_:)``.
    private func pruneExtraVerticalOwners() {
        extraVerticalOwners.removeAll { $0.scrollView == nil }
    }

    // MARK: - Вспомогательные

    /// Может ли страница существовать в текущей конфигурации (D13).
    private func canInclude(_ page: TesseraStartScreenPage) -> Bool {
        switch page {
        case .quickPanel:
            return leftPanel != nil
        case .start:
            return true
        case .applications:
            return rightPageFactory != nil
        }
    }

    /// Название страницы для VoiceOver (§9).
    private func pageTitle(for page: TesseraStartScreenPage) -> String {
        switch page {
        case .quickPanel:
            return quickPanelTitle
        case .start:
            return startPageTitle
        case .applications:
            return applicationsPageTitle
        }
    }

    /// Зажимает множитель параллакса в диапазон документа (§8: `0.4...0.6`).
    private static func sanitizedParallaxFactor(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0.4), 0.6)
    }
}

// MARK: - TesseraPagerDelegate (§1, §7, §9)

extension TesseraStartScreenViewController: TesseraPagerDelegate {

    /// Завершение перехода: подтверждение страницы, события делегата и
    /// озвучивание (``confirmPage(_:at:)``).
    ///
    /// Контроллер — постоянный делегат пейджера; SwiftUI-фасад получает
    /// события через ``delegate`` и пейджер не перехватывает.
    ///
    /// - Parameters:
    ///   - pager: Пейджер-источник события.
    ///   - index: Показанная страница в порядке чтения (RTL уже нормализован Core).
    public func pager(
        _ pager: TesseraPagerViewController,
        didShowPageAt index: Int
    ) {
        guard pageOrder.indices.contains(index) else { return }

        lastPagerProgress = CGFloat(index)
        confirmPage(pageOrder[index], at: index)
    }

    /// Прогресс прокрутки: только видимость страницы-хука (§7).
    ///
    /// Вызывается из `scrollViewDidScroll` пейджера, поэтому здесь нет layout'а:
    /// сохраняется `t`, а колбэки хука и делегата уходят только при смене
    /// видимости (раз за переход). Параллакс обоев привязан к вертикальному
    /// offset'у сетки, а не к `t`.
    ///
    /// - Parameters:
    ///   - pager: Пейджер-источник события.
    ///   - t: Нормализованный прогресс в порядке чтения.
    public func pager(
        _ pager: TesseraPagerViewController,
        didChangeProgress t: CGFloat
    ) {
        lastPagerProgress = t
        updateQuickPanelVisibility()
    }
}

// MARK: - START-страница (§2, §8)

/// Страница START: обои с вертикальным параллаксом и сетка ярлыков.
///
/// Приватная деталь композиции: снаружи доступна только через
/// ``TesseraStartScreenViewController``. Страница не ходит в `TileStore` —
/// снимок приходит от контроллера (``apply(snapshot:)``), правило «один
/// писатель» §6.
///
/// Параллакс устроен как в Panorama, но по вертикали: слой заведомо больше
/// `contentSize` (Core §2, «Параллакс»), картинка занимает видимое окно за всю
/// прокрутку, а `update(withContentOffset:)` на каждом кадре меняет только
/// `transform`. Reduce Motion замораживает слой внутри Core; собственного
/// ветвления по настройке здесь нет. Запас слоя пересчитывается и при росте
/// контента без нового снимка (раскрытие папки, `grid.update`): страница
/// наблюдает `contentSize` коллекции (KVO) и помечает себя для layout'а.
///
/// Live-плитки (§4, «Паузы»): пока страница не показана пейджером (после
/// `viewDidDisappear` и до `viewWillAppear` — пейджер пересылает appearance
/// только текущей странице), видимые ячейки сетки стоят на паузе — START за
/// кадром не флипается.
private final class TesseraStartPageViewController: UIViewController {

    // MARK: - Метрики

    private enum Metrics {
        /// Базовое поле сетки сверх safe area (§3: внешние поля задаёт хост).
        static let contentInset: CGFloat = 16

        /// Минимальный запас фона под «резину» прокрутки у краёв.
        static let backgroundBouncePadding: CGFloat = 96
    }

    // MARK: - Представления

    /// Сетка ярлыков START (E4.2).
    let gridView = TesseraTileGridView()

    /// Скролл-вью сетки для арбитража осей (§1).
    ///
    /// Коллекция — прямой потомок сетки (контракт `TesseraTileGridView`), поэтому
    /// отдельный публичный аксессор Core не нужен. `nil` — сетка ещё не собрана;
    /// арбитр тогда создаётся без вертикальных владельцев и ничего не блокирует.
    var gridScrollView: UIScrollView? {
        gridView.subviews.compactMap { $0 as? UIScrollView }.first
    }

    /// Фоновый слой с параллаксом (Core, §8).
    private let parallaxLayer = TesseraParallaxLayer()

    /// Обои внутри слоя.
    private let backgroundImageView = UIImageView()

    /// Наблюдение `contentSize` коллекции сетки (§8: запас обоев при росте
    /// контента без `reload`).
    private var contentSizeObservation: NSKeyValueObservation?

    /// Высота контента, под которую последний раз разложен слой обоев.
    private var backgroundContentHeight: CGFloat?

    /// Идёт ли `layoutPage()` — KVO изнутри собственного прохода не
    /// перезапрашивает layout.
    private var isLayingOutPage = false

    /// Стоят ли live-плитки на паузе (§4): `true`, пока страница не показана.
    private var areLiveTilesPaused = true

    // MARK: - Конфигурация

    /// Множитель параллакса; зажимается в `0.4...0.6` при раскладке (§8).
    var parallaxFactor: CGFloat = 0.5 {
        didSet {
            guard isViewLoaded else { return }
            view.setNeedsLayout()
        }
    }

    /// Обои; `nil` — только системная подложка страницы.
    var wallpaperImage: UIImage? {
        didSet {
            backgroundImageView.image = wallpaperImage
            backgroundImageView.isHidden = wallpaperImage == nil
        }
    }

    // MARK: - Инициализация

    init() {
        super.init(nibName: nil, bundle: nil)

        // §8: offset приходит из единственного разрешённого места — колбэка
        // прокрутки сетки. Внутри — только transform слоя, без layout.
        gridView.onScrollOffsetChanged = { [weak self] offset in
            self?.parallaxLayer.update(
                withContentOffset: CGPoint(x: 0, y: offset.y)
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Жизненный цикл

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        // Слой заведомо больше страницы; без клипа он заезжал бы на соседние
        // страницы пейджера при свайпе.
        view.clipsToBounds = true

        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.clipsToBounds = true
        backgroundImageView.isUserInteractionEnabled = false
        backgroundImageView.isAccessibilityElement = false
        backgroundImageView.image = wallpaperImage
        backgroundImageView.isHidden = wallpaperImage == nil

        parallaxLayer.addSubview(backgroundImageView)
        view.addSubview(parallaxLayer)
        view.addSubview(gridView)

        // §8: высота контента растёт и без нового снимка (панель папки D17,
        // `grid.update` от хоста или координатора). Сам пересчёт — в
        // ближайшем layout-проходе, а не в колбэке: KVO приходит из layout'а
        // коллекции, и здесь только помечается страница.
        contentSizeObservation = gridScrollView?.observe(
            \.contentSize,
            options: [.new]
        ) { [weak self] _, _ in
            self?.contentSizeDidChange()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPage()
    }

    /// START-страница становится текущей: live-плитки возобновляются (§4).
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setLiveTilesPaused(false)
    }

    /// START-страница ушла (пейджер показал другую или экран скрыт):
    /// live-плитки на паузу (§4).
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        setLiveTilesPaused(true)
    }

    // MARK: - Live-плитки (§4, «Паузы»)

    /// Ставит live-плитки и idle-флип папок START на паузу или снимает её.
    ///
    /// Используется тот же путь, что у сетки при уходе ячейки с экрана
    /// (`setLiveTileVisible`): движок не флипает невидимую плитку и сбрасывает
    /// незавершённый флип, подписки провайдеров сохраняются. Ячейки, скрытые
    /// на время drag (`setItemHidden`), не возобновляются.
    private func setLiveTilesPaused(_ paused: Bool) {
        areLiveTilesPaused = paused
        applyLiveTilePause()
    }

    /// Применяет паузу к видимым ячейкам коллекции.
    ///
    /// Вызывается и после layout'а: `willDisplay` сетки (новый снимок, рост
    /// контента) регистрирует ячейки видимыми, и START за кадром снова
    /// флипался бы.
    private func applyLiveTilePause() {
        guard let collectionView = gridScrollView as? UICollectionView else { return }
        for case let cell as TesseraTileCell in collectionView.visibleCells {
            if areLiveTilesPaused {
                cell.setLiveTileVisible(false)
            } else if !cell.accessibilityElementsHidden {
                cell.setLiveTileVisible(true)
            }
        }
    }

    /// Высота контента сетки изменилась: запас обоев пересчитается в
    /// ближайшем layout-проходе (§8).
    private func contentSizeDidChange() {
        guard isViewLoaded, !isLayingOutPage else { return }
        let height = gridView.contentSize.height
        guard height != backgroundContentHeight else { return }
        view.setNeedsLayout()
    }

    // MARK: - Данные

    /// Применяет снимок сетки (E4.2).
    ///
    /// Работает и до загрузки вида: снимок применяется к сетке, а фон
    /// пересчитается на ближайшем layout'е.
    func apply(snapshot: TileGridSnapshot) {
        gridView.reload(snapshot: snapshot)

        if isViewLoaded {
            view.setNeedsLayout()
        }
    }

    // MARK: - Layout и параллакс (§8)

    /// Раскладывает сетку с учётом safe area и пересчитывает фон.
    ///
    /// Вызывается только из `viewDidLayoutSubviews` (плюс `setNeedsLayout`
    /// после `reload(grid:)`); в скролле layout'а нет (§8).
    private func layoutPage() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        isLayingOutPage = true
        defer { isLayingOutPage = false }

        if gridView.frame != bounds {
            gridView.frame = bounds
        }

        // §3: поля сетки — единственный источник внешних отступов. Складываем
        // базовое поле с безопасной зоной; сетка живёт под пейджером и сама
        // safe area не подмешивает.
        let safeArea = view.safeAreaInsets
        let insets = UIEdgeInsets(
            top: safeArea.top + Metrics.contentInset,
            left: safeArea.left + Metrics.contentInset,
            bottom: safeArea.bottom + Metrics.contentInset,
            right: safeArea.right + Metrics.contentInset
        )
        if gridView.contentInsets != insets {
            gridView.contentInsets = insets
        }

        // Сетке нужен актуальный `contentSize` для расчёта хода фона; это
        // layout-проход, а не горячий путь прокрутки (§8).
        gridView.layoutIfNeeded()

        layoutBackground(in: bounds)

        // Ячейки, показанные этим проходом, сетка регистрирует видимыми.
        if areLiveTilesPaused {
            applyLiveTilePause()
        }
    }

    /// Раскладывает слой обоев под вертикальный параллакс (§8).
    ///
    /// Схема повторяет горизонтальную из Panorama, но по оси Y:
    /// - `contentSize` слоя — высота контента, но не меньше вьюпорта;
    /// - запас `extraSize` — весь ход фона (`maximumOffsetY × factor`) плюс
    ///   «резина» на границах: слой заведомо больше контента (Core §2);
    /// - слой — сосед скролла сетки, Core проецирует смещение фона на экран
    ///   со знаком минус (`transform = −offset × factor`, E10.7): при
    ///   прокрутке вниз обои уезжают вверх вместе с плитками, но медленнее;
    /// - поэтому начало слоя — у верхнего края страницы, поднятое только на
    ///   `padding` (поле под «резину» над верхом, где offset < 0), а весь ход
    ///   фона `shift` плюс второе поле лежат ниже вьюпорта: экранный верх
    ///   картинки `−padding − offset × factor`, низ
    ///   `height + shift + padding − offset × factor` — вьюпорт закрыт при
    ///   любом offset в `[−padding / factor, maximumOffset + padding / factor]`;
    /// - картинка занимает только реально видимое окно за всю прокрутку.
    ///
    /// Множитель берётся из конфигурации, а не из действующего: при
    /// Reduce Motion Core обнуляет фактор, но запас должен остаться
    /// достаточным, если настройку включат «на лету».
    private func layoutBackground(in bounds: CGRect) {
        let factor = Self.sanitizedFactor(parallaxFactor)
        backgroundContentHeight = gridView.contentSize.height
        let contentHeight = max(gridView.contentSize.height, bounds.height)
        let maximumOffset = max(0, contentHeight - bounds.height)
        let shift = maximumOffset * factor
        let padding = max(Metrics.backgroundBouncePadding, bounds.height * 0.35)

        parallaxLayer.configure(factor: factor, extraSize: shift + padding * 2)
        parallaxLayer.setContentSize(
            CGSize(width: bounds.width, height: contentHeight)
        )

        // Начало слоя (и картинки) — на `padding` выше страницы: запас под
        // «резину» сверху. Ход фона `shift` и нижнее поле — ниже вьюпорта,
        // туда слой уезжает при прокрутке вниз (E10.7).
        let layerSize = parallaxLayer.bounds.size
        parallaxLayer.center = CGPoint(
            x: layerSize.width / 2,
            y: -padding + layerSize.height / 2
        )

        backgroundImageView.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: bounds.height + shift + padding * 2
        )
    }

    /// Зажимает множитель параллакса в `0.4...0.6` (§8).
    private static func sanitizedFactor(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0.4), 0.6)
    }
}
#endif
