//
//  PivotViewController.swift
//  TesseraPivot
//
//  Оркестратор пивота: крупный заголовок приложения, лента заголовков и
//  полноэкранный пейджер из TesseraCore.
//  Контракт: docs/PIVOT-IOS-DESIGN.md §3 «Архитектура» (компоновка сверху вниз:
//  PivotTitleView → PivotHeaderStripView → пейджер), §4 «Математика ядра»
//  (автоцентрирование ленты по завершении перехода), §5 «Синхронизация ленты и
//  пейджера» (один источник истины и один писатель `contentOffset`), §6
//  «Вертикальный скролл внутри страницы» (вариант B: пейджер — только
//  горизонталь, вертикаль — детям), §8 «Accessibility» (VoiceOver, Reduce Motion,
//  Dynamic Type, RTL), §9 «Адаптивность» (одна секция — лента скрывается).
//  Задачи плана: E2.1 (VC + пейджер), E2.3 (синхронизация), E2.4 (вертикальный
//  скролл).
//
//  Инварианты (§5):
//  - источник истины — `contentOffset` пейджера; пишут его только жест пейджера
//    и программный переход (``selectSection(at:animated:)`` →
//    `TesseraPagerViewController.go(toPage:animated:)`);
//  - лента — только читатель: `didChangeProgress` → `headerStripView.apply(progress:)`,
//    обратной записи в пейджер нет;
//  - в горячем пути прогресса нет layout: `apply(progress:)` ленты двигает только
//    `transform` индикатора и перекрашивает видимые ячейки (§4, §7).
//

#if canImport(UIKit)
import UIKit
import TesseraCore

/// Контроллер пивота: лента заголовков с непрерывной синхронизацией и
/// полноэкранные страницы-секции (docs/PIVOT-IOS-DESIGN.md §3).
///
/// Компоновка сверху вниз (§3):
///
/// ```
/// PivotViewController
///     ├─ крупный заголовок приложения (UILabel, опционально — ``PivotStyle/appTitle``)
///     ├─ PivotHeaderStripView   ← лента заголовков + индикатор, вне пейджера,
///     │                            поэтому закреплена по вертикали (§6)
///     └─ TesseraPagerViewController (режим .paged) ← страницы из ``PivotSection``
/// ```
///
/// ## Синхронизация (§5)
///
/// - свайп → лента: `didChangeProgress` пейджера передаётся в
///   ``PivotHeaderStripView/apply(progress:)``; никакой обратной записи нет;
/// - тап по заголовку → пейджер: ``selectSection(at:animated:)`` вызывает
///   `go(toPage:animated:)`; при Reduce Motion переход без анимации (§8);
/// - завершение перехода (`didShowPageAt`) → автоцентрирование ленты,
///   озвучивание названия секции и колбэк делегата
///   ``PivotDelegate/pivot(_:didShowSectionAt:)``.
///
/// ## Вертикальный скролл (§6, вариант B)
///
/// Пейджер скроллит только горизонтально, вертикалью владеют страницы.
/// Контроллеры контента регистрируют свои вертикальные скролл-вью через
/// ``registerVerticalOwner(_:)``; арбитраж выполняет
/// ``TesseraGestureArbiter`` из Core: на время горизонтального жеста прокрутка
/// детей блокируется и затем восстанавливается. Подробности и вынужденное
/// отклонение от §6 — в документации методов регистрации.
///
/// ## RTL (§8)
///
/// Прогресс и индексы приходят из Core уже нормализованными по направлению
/// чтения (`TesseraRTL`): `0` — первая секция для пользователя. Лента получает
/// тот же прогресс в порядке чтения и сама переводит геометрию в координаты
/// контента. Поэтому здесь нет отдельной ветки зеркалирования — иначе
/// зеркалирование применилось бы дважды.
///
/// - Important: Работает только на главном потоке: UI-состояние не
///   размазывается по модулям (docs/CORE-IOS-DESIGN.md §3). Делегат не
///   удерживается.
public final class PivotViewController: UIViewController {

    // MARK: - Константы компоновки

    /// Геометрия компоновки, не зависящая от стиля.
    ///
    /// Высота ленты не входит сюда: она зависит от Dynamic Type (§8) и
    /// считается по фактическому шрифту заголовков.
    private enum Metrics {
        /// Боковой отступ крупного заголовка приложения (§1).
        static let appTitleInset: CGFloat = 20

        /// Отступ сверху до крупного заголовка.
        static let appTitleTopPadding: CGFloat = 8

        /// Отступ между крупным заголовком и лентой заголовков.
        static let appTitleBottomPadding: CGFloat = 4

        /// Минимальная высота ленты заголовков.
        static let minimumStripHeight: CGFloat = 48

        /// Суммарный вертикальный запас вокруг текста заголовка в ленте:
        /// половина сверху и половина снизу, поверх него рисуется индикатор.
        static let stripVerticalPadding: CGFloat = 16
    }

    // MARK: - Публичная конфигурация

    /// Текущий набор секций в порядке чтения.
    ///
    /// Меняется только через ``reload(sections:)`` (и инициализатор). Секции —
    /// источник истины и для ленты (заголовки), и для пейджера (страницы,
    /// docs/PIVOT-IOS-DESIGN.md §3).
    public private(set) var sections: [PivotSection] = []

    /// Внешний вид пивота (docs/PIVOT-IOS-DESIGN.md §3).
    ///
    /// Любое присваивание применяется к ленте и крупному заголовку: у сеттеров
    /// ``PivotHeaderStripView`` есть сравнение с прежним значением, поэтому
    /// повторная установка того же стиля не перезагружает ячейки. Шрифты
    /// заголовков лента масштабирует сама по Dynamic Type (§8); крупный заголовок
    /// приложения пересчитывается контроллером.
    public var style: PivotStyle {
        didSet {
            guard isViewLoaded else { return }
            applyStyle()
        }
    }

    /// Наблюдатель выбора, прогресса и показа секции.
    ///
    /// Не удерживается (docs/PIVOT-IOS-DESIGN.md §5: делегат только читает
    /// состояние). Публичные колбэки — из ``PivotDelegate``.
    public weak var delegate: PivotDelegate?

    // MARK: - Внутренние представления

    /// Лента заголовков с индикатором (§3). Вне пейджера — закреплена по
    /// вертикали автоматически (§6).
    ///
    /// Доступна на уровне модуля (`@testable`), чтобы контрактные тесты E2.7
    /// могли проверить синхронизацию тапа/свайпа; в публичную поверхность не
    /// входит — геометрией и содержимым ленты владеет контроллер.
    let headerStripView = PivotHeaderStripView()

    /// Пейджер Core в режиме `.paged` (§2: снап даёт `isPagingEnabled`).
    ///
    /// Доступен на уровне модуля для контрактных тестов E2.7; публичного
    /// доступа нет — переходы выполняются через ``selectSection(at:animated:)``.
    let pagerViewController: TesseraPagerViewController

    /// Крупный заголовок приложения (WP-поведение, §1, §9).
    ///
    /// Показывается только при непустом ``PivotStyle/appTitle``; при `nil`
    /// заголовок интегрируется снаружи через `navigationItem.largeTitle` (§9).
    private let appTitleLabel = UILabel()

    // MARK: - Состояние синхронизации

    /// Текущая секция в порядке чтения.
    ///
    /// Обновляется из непрерывного прогресса (ближайшая секция) и по завершении
    /// перехода; используется VoiceOver-пагинацией (§8) и восстановлением
    /// выбора после ``reload(sections:)``.
    private(set) var currentSectionIndex: Int = 0

    /// Нужно ли доцентровать ленту при ближайшем layout-проходе.
    ///
    /// Первый показ и `reload` выполняются до того, как у ленты появилась
    /// ширина, поэтому автоцентрирование (§4) откладывается до layout'а.
    private var needsInitialCentering = true

    /// Кеш высоты ленты: зависит от Dynamic Type (§8), пересчитывается только
    /// при смене категории размера текста, а не на каждом кадре свайпа.
    private var cachedStripHeight: CGFloat = 0
    private var cachedStripHeightCategory: UIContentSizeCategory?

    // MARK: - Состояние арбитража жестов (§6, вариант B)

    /// Скролл-вью пейджера, найденный в иерархии Core.
    ///
    /// Core не публикует его (см. документацию ``registerVerticalOwner(_:)``).
    /// `private(set)` — только для контрактных тестов модуля.
    private(set) var pagerScrollView: UIScrollView?

    /// Вертикальные владельцы-дети: слабые ссылки, чтобы исчезнувшие страницы
    /// (ленивая загрузка ±1, §7) не утекали и не блокировались зря.
    private var verticalOwners: [VerticalOwner] = []

    /// Арбитр Core на время горизонтального жеста.
    ///
    /// Живёт только между `panGestureRecognizer` `.began` и `.ended`: арбитр
    /// удерживает вертикальные скролл-вью сильными ссылками, а страницы
    /// загружаются лениво и пересоздаются (§7), поэтому постоянное удержание
    /// продлевало бы жизнь выгруженному контенту.
    private var gestureArbiter: TesseraGestureArbiter?

    /// Пан пейджера, на который подписан контроллер (слабо: владелец — Core).
    private weak var observedPagerPan: UIPanGestureRecognizer?

    /// Слабая ссылка на вертикальный скролл-вью ребёнка.
    private struct VerticalOwner {
        weak var scrollView: UIScrollView?
    }

    // MARK: - Инициализация

    /// Создаёт пивот с готовым набором секций.
    ///
    /// Пейджер создаётся сразу в режиме `.paged` (docs/PIVOT-IOS-DESIGN.md §2):
    /// снап и инерцию даёт `UIScrollView.isPagingEnabled`, кастомный снап не
    /// нужен. Страницы из секций строятся через ``TesseraPageDescriptor``.
    ///
    /// - Parameters:
    ///   - sections: Секции в порядке чтения; пустой массив — допустимое
    ///     начальное состояние (страницы можно передать позже через
    ///     ``reload(sections:)``).
    ///   - style: Внешний вид; по умолчанию системный.
    public init(sections: [PivotSection] = [], style: PivotStyle = PivotStyle()) {
        self.sections = sections
        self.style = style
        self.pagerViewController = TesseraPagerViewController(
            mode: .paged,
            pages: Self.makePageDescriptors(for: sections)
        )
        super.init(nibName: nil, bundle: nil)
    }

    /// Инициализация из архива/сториборда не поддерживается: компоновка
    /// строится кодом (§3).
    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Жизненный цикл

    /// Собирает иерархию: заголовок, лента, пейджер-child (§3).
    public override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        configureSubviews()

        // Набор секций мог измениться до загрузки вида (`reload` до показа):
        // пейджер пересобирается из актуального состояния.
        pagerViewController.reload(pages: Self.makePageDescriptors(for: sections))

        applyStyle()
        synchronizeStripSelection()
    }

    /// Раскладывает заголовок, ленту и пейджер и подхватывает скролл-вью
    /// пейджера для арбитража (§6).
    ///
    /// Единственный layout-проход контроллера: в горячем пути прогресса layout'а
    /// нет (§4, §7).
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        layoutPivot()
        resolvePagerScrollViewIfNeeded()
        performInitialCenteringIfNeeded()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        observedPagerPan?.removeTarget(
            self,
            action: #selector(pagerPanDidChange(_:))
        )
    }

    // MARK: - Публичный API

    /// Пересобирает пивот под новый набор секций.
    ///
    /// Пересобираются и лента (заголовки), и пейджер (страницы) из одного
    /// источника — массива секций (§3). Текущая секция сохраняется по `id`,
    /// если он есть в новом наборе; иначе сохраняется прежний индекс с зажимом
    /// в новые границы — так перестройка не «перебрасывает» пользователя на
    /// первую секцию.
    ///
    /// Обратной записи в `contentOffset` нет: пейджер сам восстанавливает
    /// страницу по `id` (§5, «один писатель»).
    ///
    /// - Parameter sections: Новые секции в порядке чтения. Пустой массив
    ///   допустим: лента скрывается (§9).
    public func reload(sections newSections: [PivotSection]) {
        let previousID: AnyHashable? = sections.indices.contains(currentSectionIndex)
            ? sections[currentSectionIndex].id
            : nil

        sections = newSections

        if newSections.isEmpty {
            currentSectionIndex = 0
        } else if let previousID,
                  let preservedIndex = newSections.firstIndex(where: { $0.id == previousID }) {
            currentSectionIndex = preservedIndex
        } else {
            currentSectionIndex = min(max(currentSectionIndex, 0), newSections.count - 1)
        }

        needsInitialCentering = true

        guard isViewLoaded else { return }

        headerStripView.titles = sections.map(\.title)
        pagerViewController.reload(pages: Self.makePageDescriptors(for: newSections))
        synchronizeStripSelection()

        view.setNeedsLayout()
        // Раскладываем сразу: лента могла быть скрыта (одна секция, §9) и её
        // геометрия до этого layout-прохода нулевая — автоцентрирование (§4)
        // без ширины и высоты ошиблось бы. Это layout-путь, не горячий (§7).
        view.layoutIfNeeded()
        centerStrip(index: currentSectionIndex, animated: false)
    }

    /// Программно переходит к секции.
    ///
    /// Единственный программный писатель `contentOffset` (§5): переход
    /// выполняет ``TesseraPagerViewController/go(toPage:animated:)``. При
    /// анимированном переходе делегат пейджера продолжает присылать прогресс на
    /// кадрах, поэтому лента и индикатор анимируются сами — отдельной анимации
    /// индикатора нет (§5).
    ///
    /// При Reduce Motion анимация отключается принудительно (§8: «прыжок по
    /// тапу — без анимации»). Индекс зажимается в границы набора секций.
    ///
    /// - Parameters:
    ///   - index: Индекс секции в порядке чтения (в RTL — не физический слот).
    ///   - animated: Намерение анимировать переход; Reduce Motion имеет приоритет.
    public func selectSection(at index: Int, animated: Bool) {
        guard !sections.isEmpty else { return }

        let targetIndex = min(max(index, 0), sections.count - 1)
        let shouldAnimate = animated && !TesseraAccessibility.isReduceMotionEnabled

        currentSectionIndex = targetIndex
        headerStripView.select(index: targetIndex)
        pagerViewController.go(toPage: targetIndex, animated: shouldAnimate)

        // Без анимации `go` может не прислать `didShowPageAt` (переход на уже
        // показанную секцию) — доцентровываем ленту сами (§4). При анимации это
        // сделает обработчик завершения перехода.
        guard !shouldAnimate else { return }
        centerStrip(index: targetIndex, animated: false)
    }

    /// Регистрирует вертикальный скролл-вью страницы (docs/PIVOT-IOS-DESIGN.md §6,
    /// вариант B).
    ///
    /// Пейджер скроллит только горизонтально, вертикалью владеют страницы.
    /// Контроллер контента секции вызывает этот метод, например из
    /// `viewDidAppear`, и передаёт свой вертикальный `UIScrollView`. На время
    /// горизонтального жеста пейджера контроллер собирает из зарегистрированных
    /// детей ``TesseraGestureArbiter``: прокрутка детей блокируется и
    /// восстанавливается в исходное состояние по завершении жеста
    /// (`prepareForHorizontalScroll()` / `endHorizontalScroll()`).
    ///
    /// Ссылка на скролл-вью слабая: страницы загружаются лениво и пересоздаются
    /// (§7), поэтому освобождённые владельцы выпадают из реестра автоматически.
    /// Арбитр создаётся только на время жеста, поэтому сильных ссылок на скролл-вью
    /// между жестами контроллер не держит.
    ///
    /// - Parameter scrollView: Вертикальный скролл-вью контента страницы.
    ///
    /// - Note: **Отклонение от §6.** `TesseraPagerViewController` не отдаёт свой
    ///   `UIScrollView` публично, а его пан-жест принадлежит самому
    ///   `UIScrollView`. Поэтому:
    ///   1. скролл-вью пейджера находится обходом иерархии Core (единственный
    ///      прямой потомок корневого вида пейджера — тот же приём используют
    ///      контрактные тесты Core), а не через публичный хук;
    ///   2. `gestureRecognizerShouldBegin` арбитра на пан пейджера не
    ///      назначается: подмена `panGestureRecognizer.delegate` у `UIScrollView`
    ///      отключила бы его собственную обработку одновременных жестов
    ///      (вложенные скроллы, системный edge-swipe). Решение по доминирующей
    ///      оси принимается на первом же колбэке пана через
    ///      ``TesseraGestureArbiter/axisDecision(forVelocity:)``, после чего
    ///      арбитр блокирует детей на время горизонтального жеста — обе
    ///      половины контракта арбитража задействованы, но точка принятия
    ///      решения сдвинута с `gestureRecognizerShouldBegin` на `.began`.    ///   Для полноценного §6 нужен публичный хук Core, например аксессор
    ///   `TesseraPagerViewController.horizontalScrollView` (открытый вопрос в
    ///   отчёте, Core не менялся).
    public func registerVerticalOwner(_ scrollView: UIScrollView) {
        guard scrollView !== pagerScrollView else { return }

        pruneVerticalOwners()
        if !verticalOwners.contains(where: { $0.scrollView === scrollView }) {
            verticalOwners.append(VerticalOwner(scrollView: scrollView))
        }
    }

    /// Снимает регистрацию вертикального скролл-вью страницы (§6).
    ///
    /// Вызывать не обязательно: ссылки слабые, и освобождённые страницы выпадают
    /// из арбитража сами. Метод нужен, когда контроллер контента перестаёт
    /// использовать скролл-вью, но живёт дальше (например, заменил его).
    ///
    /// - Parameter scrollView: Ранее зарегистрированный вертикальный скролл-вью.
    public func unregisterVerticalOwner(_ scrollView: UIScrollView) {
        verticalOwners.removeAll { owner in
            guard let registered = owner.scrollView else { return true }
            return registered === scrollView
        }
    }

    // MARK: - Accessibility (§8)

    /// Пагинация секций жестом VoiceOver «три пальца» (§8).
    ///
    /// Направление превращается в шаг по секциям через
    /// ``TesseraAccessibility/pageStep(for:layoutDirection:)`` с учётом
    /// направления чтения; сам переход выполняет ``selectSection(at:animated:)``,
    /// поэтому `contentOffset` по-прежнему пишет только пейджер (§5).
    ///
    /// Пейджер Core умеет то же самое для своего скролл-вью; обе реализации
    /// ведут в один `go(toPage:)` и дают одинаковый результат — здесь жест
    /// обрабатывается на уровне пивота, чтобы работал и на ленте заголовков.
    ///
    /// - Parameter direction: Направление жеста VoiceOver.
    /// - Returns: `true`, если жест обработан.
    public override func accessibilityScroll(
        _ direction: UIAccessibilityScrollDirection
    ) -> Bool {
        guard isViewLoaded, !sections.isEmpty else { return false }

        let step = TesseraAccessibility.pageStep(
            for: direction,
            layoutDirection: view.effectiveUserInterfaceLayoutDirection
        )
        guard step != 0 else { return false }

        let targetIndex = currentSectionIndex + step
        guard sections.indices.contains(targetIndex) else { return false }

        selectSection(at: targetIndex, animated: true)
        return true
    }

    // MARK: - Сборка представлений

    /// Создаёт иерархию: заголовок, лента, пейджер как child-VC (§3).
    private func configureSubviews() {
        appTitleLabel.numberOfLines = 0
        appTitleLabel.lineBreakMode = .byTruncatingTail
        appTitleLabel.accessibilityTraits = .header
        appTitleLabel.isHidden = true

        headerStripView.titles = sections.map(\.title)
        headerStripView.onSelect = { [weak self] index in
            self?.handleHeaderTap(at: index)
        }

        view.addSubview(appTitleLabel)
        view.addSubview(headerStripView)

        addChild(pagerViewController)
        view.addSubview(pagerViewController.view)
        pagerViewController.didMove(toParent: self)
        pagerViewController.delegate = self

        // §8, Dynamic Type: крупный заголовок пересчитывается при смене категории.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
    }

    /// Применяет стиль к ленте и крупному заголовку (§3, §8).
    ///
    /// Сеттеры ленты сравнивают значения с прежними, поэтому повторное
    /// применение того же стиля не перезагружает ячейки. Вызывается из
    /// `viewDidLoad`, из сеттера ``style`` и при смене Dynamic Type.
    private func applyStyle() {
        headerStripView.mode = style.stripMode
        headerStripView.titleFont = style.titleFont
        headerStripView.titleTextStyle = style.titleTextStyle
        headerStripView.activeColor = style.activeColor
        headerStripView.inactiveColor = style.inactiveColor
        // §3: вид индикатора — подчёркивание и/или акцентный цвет текста.
        headerStripView.showsIndicator = style.indicatorStyle != .accentText

        appTitleLabel.text = style.appTitle
        appTitleLabel.isHidden = !isAppTitleVisible
        updateAppTitleFont()

        invalidateStripHeightCache()
        view.setNeedsLayout()
    }

    /// Пересчитывает шрифт крупного заголовка под Dynamic Type (§8).
    ///
    /// В `PivotStyle` нет отдельного шрифта заголовка приложения (§3: стиль
    /// описывает ленту), поэтому используется системный bold-шрифт метрик
    /// `.largeTitle` — семантически это крупный заголовок экрана.
    private func updateAppTitleFont() {
        let metrics = UIFontMetrics(forTextStyle: .largeTitle)
        let baseFont = UIFont.systemFont(ofSize: 34, weight: .bold)
        appTitleLabel.font = metrics.scaledFont(for: baseFont, compatibleWith: traitCollection)
    }

    /// Показывать ли крупный заголовок приложения (§1, §9).
    private var isAppTitleVisible: Bool {
        guard let appTitle = style.appTitle else { return false }
        return !appTitle.isEmpty
    }

    // MARK: - Layout

    /// Раскладывает заголовок, ленту и пейджер сверху вниз (§3).
    ///
    /// Пейджер занимает всю оставшуюся высоту, включая нижнюю safe area: страницы
    /// — обычные child-VC и получают корректные `safeAreaInsets` от пейджера,
    /// поэтому вертикальный скролл контента может уходить под home-индикатор
    /// (§6: лента закреплена, скроллится только содержимое страницы).
    private func layoutPivot() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        // §9: одна секция или пусто — ленту скрываем, она не несёт информации.
        let isStripVisible = sections.count > 1
        headerStripView.isHidden = !isStripVisible

        var top = view.safeAreaInsets.top

        if isAppTitleVisible {
            let titleWidth = max(bounds.width - Metrics.appTitleInset * 2, 0)
            let fittingSize = appTitleLabel.sizeThatFits(
                CGSize(width: titleWidth, height: .greatestFiniteMagnitude)
            )
            appTitleLabel.frame = CGRect(
                x: Metrics.appTitleInset,
                y: top + Metrics.appTitleTopPadding,
                width: titleWidth,
                height: ceil(fittingSize.height)
            )
            top = appTitleLabel.frame.maxY + Metrics.appTitleBottomPadding
        } else {
            appTitleLabel.frame = .zero
        }

        let stripHeight = isStripVisible ? stripHeightForCurrentTextSize : 0
        headerStripView.frame = CGRect(
            x: 0,
            y: top,
            width: bounds.width,
            height: stripHeight
        )

        let pagerFrame = CGRect(
            x: 0,
            y: headerStripView.frame.maxY,
            width: bounds.width,
            height: max(bounds.height - headerStripView.frame.maxY, 0)
        )

        if pagerViewController.view.frame != pagerFrame {
            pagerViewController.view.frame = pagerFrame
            // Даём пейджеру разложить страницы в этом же проходе: иначе первый
            // показ и восстановление offset'а отставали бы на кадр (§5).
            pagerViewController.view.layoutIfNeeded()
        }
    }

    /// Высота ленты под текущий Dynamic Type (§8).
    ///
    /// Кешируется по категории размера текста: в горячем пути свайпа шрифты не
    /// создаются (§7).
    private var stripHeightForCurrentTextSize: CGFloat {
        let category = traitCollection.preferredContentSizeCategory
        if cachedStripHeight > 0, cachedStripHeightCategory == category {
            return cachedStripHeight
        }

        let metrics = UIFontMetrics(forTextStyle: style.titleTextStyle)
        let font = metrics.scaledFont(for: style.titleFont, compatibleWith: traitCollection)
        let height = max(
            Metrics.minimumStripHeight,
            ceil(font.lineHeight) + Metrics.stripVerticalPadding
        )

        cachedStripHeight = height
        cachedStripHeightCategory = category
        return height
    }

    /// Сбрасывает кеш высоты ленты при смене Dynamic Type (§8).
    private func invalidateStripHeightCache() {
        cachedStripHeight = 0
        cachedStripHeightCategory = nil
    }

    /// Доцентровывает ленту на текущей секции после первого layout'а (§4).
    ///
    /// До появления ширины у ленты автоцентрирование невозможно: `reload` и
    /// установка начальных секций выполняются раньше раскладки.
    private func performInitialCenteringIfNeeded() {
        guard needsInitialCentering, sections.count > 1 else { return }
        centerStrip(index: currentSectionIndex, animated: false)
    }

    /// Доцентровывает ленту, если она уже имеет ширину (§4).
    ///
    /// Перед `scrollToCenter` лента принудительно раскладывается: её геометрия
    /// (центры заголовков и `contentSize` коллекции) считается в
    /// `layoutSubviews`, а `reload` и первый показ могут происходить до него.
    /// Это layout-проход, а не горячий путь свайпа (§4, §7).
    ///
    /// Если ширины ещё нет, автоцентрирование откладывается до layout'а.
    private func centerStrip(index: Int, animated: Bool) {
        guard isViewLoaded, headerStripView.bounds.width > 0 else {
            needsInitialCentering = true
            return
        }

        needsInitialCentering = false
        headerStripView.layoutIfNeeded()
        headerStripView.scrollToCenter(index: index, animated: animated)
    }

    // MARK: - Синхронизация (§5)

    /// Тап по заголовку ленты: сообщает намерение и запускает переход.
    ///
    /// Лента не двигает пейджер сама (§5): она лишь сообщает индекс, а
    /// `contentOffset` пишет контроллер через ``selectSection(at:animated:)``.
    /// Делегат получает выбор до перехода, как описано в ``PivotDelegate``.
    private func handleHeaderTap(at index: Int) {
        guard sections.indices.contains(index) else { return }

        delegate?.pivot(self, didSelectSectionAt: index)
        selectSection(
            at: index,
            animated: !TesseraAccessibility.isReduceMotionEnabled
        )
    }

    /// Обновляет выделение ленты без прокрутки пейджера.
    ///
    /// Используется после `reload`: лента должна показывать сохранённую секцию
    /// ещё до первого события прогресса.
    private func synchronizeStripSelection() {
        guard !sections.isEmpty else { return }
        headerStripView.select(index: currentSectionIndex)
    }

    /// Ближайшая к прогрессу секция; прогресс уже в порядке чтения (§4, §8).
    private func updateCurrentIndex(fromProgress progress: CGFloat) {
        guard !sections.isEmpty, progress.isFinite else { return }

        let lastIndex = CGFloat(sections.count - 1)
        let clampedProgress = min(max(progress, 0), lastIndex)
        currentSectionIndex = Int(clampedProgress.rounded())
    }

    /// Озвучивает название секции при смене (§8, «VoiceOver»).
    ///
    /// Вызывается по завершении перехода: во время анимации анонс перебивается
    /// сменой accessibility-фокуса (см. ``TesseraAccessibility/announcePageChange(_:)``).
    /// Пустой заголовок не озвучивается.
    private func announceSection(at index: Int) {
        guard sections.indices.contains(index) else { return }

        let title = sections[index].title
        guard !title.isEmpty else { return }

        TesseraAccessibility.announcePageChange(title)
    }

    // MARK: - Арбитраж вертикального скролла (§6, вариант B)

    /// Ищет скролл-вью пейджера и подписывается на его пан.
    ///
    /// Отклонение от §6 задокументировано в ``registerVerticalOwner(_:)``: Core
    /// не публикует скролл-вью, поэтому используется контракт его `loadView` —
    /// единственный прямой потомок корневого вида. Если иерархия Core изменится,
    /// поиск вернёт `nil`, и вертикальный скролл продолжит работать штатными
    /// средствами UIKit (без явной блокировки детей); падения нет.
    private func resolvePagerScrollViewIfNeeded() {
        guard pagerScrollView == nil else { return }

        let scrollView = pagerViewController.view.subviews
            .compactMap { $0 as? UIScrollView }
            .first
        guard let scrollView else { return }

        pagerScrollView = scrollView
        observePagerPan(scrollView.panGestureRecognizer)
    }

    /// Подписывается на состояния пана пейджера, не заменяя его делегата.
    ///
    /// `addTarget` аддитивен и не ломает внутренние обработчики `UIScrollView`,
    /// в отличие от подмены `panGestureRecognizer.delegate` (почему она опасна —
    /// см. ``registerVerticalOwner(_:)``).
    private func observePagerPan(_ pan: UIPanGestureRecognizer) {
        guard observedPagerPan !== pan else { return }

        observedPagerPan?.removeTarget(
            self,
            action: #selector(pagerPanDidChange(_:))
        )
        pan.addTarget(self, action: #selector(pagerPanDidChange(_:)))
        observedPagerPan = pan
    }

    /// Начинает горизонтальный жест: создаёт арбитр и блокирует вертикальных детей.
    ///
    /// Арбитр живёт только на время жеста: он удерживает переданные скролл-вью
    /// сильными ссылками, а страницы загружаются лениво окном ±1 и пересоздаются
    /// (§7). Снимок исходных `isScrollEnabled` детей держит сам арбитр, поэтому
    /// начало и завершение жеста обязаны идти парой (``pagerPanDidChange(_:)``).
    ///
    /// Доминирующая ось проверяется по первому доступному вектору пана через
    /// ``TesseraGestureArbiter/axisDecision(forVelocity:)``: если жест
    /// вертикальный, пейджер его не ведёт и прокрутка детей не блокируется —
    /// иначе выключение скролл-вью остановило бы начавшуюся вертикальную
    /// прокрутку страницы (§6, docs/CORE-IOS-DESIGN.md §2 «Арбитраж»).
    ///
    /// Layout здесь не выполняется — только флаг прокрутки (§4, §7).
    ///
    /// - Parameter pan: Пан пейджера, перешедший в состояние `.began`.
    private func beginHorizontalScroll(with pan: UIPanGestureRecognizer) {
        guard let pagerScrollView else { return }

        guard isHorizontalPan(pan) else {
            // Вертикаль принадлежит ребёнку: снимаем возможную прошлую
            // блокировку и не трогаем `isScrollEnabled` детей.
            endHorizontalScroll()
            return
        }

        // Защита от наложения жестов: незавершённый арбитр сначала возвращает
        // детям их исходное состояние, иначе снимок `isScrollEnabled` потеряется.
        if gestureArbiter != nil {
            endHorizontalScroll()
        }

        pruneVerticalOwners()
        let arbiter = TesseraGestureArbiter(
            horizontalOwner: pagerScrollView,
            verticalOwners: liveVerticalOwners
        )
        arbiter.prepareForHorizontalScroll()
        gestureArbiter = arbiter
    }

    /// Доминирующая горизонталь ли у только начавшегося пана пейджера.
    ///
    /// Повторяет запасной путь Core: при нулевой скорости ось определяется по
    /// смещению (масштаб для сравнения модулей не важен). При равенстве модулей
    /// побеждает горизонталь — дефолт
    /// ``TesseraGestureArbiter/axisDecision(forVelocity:)``.
    private func isHorizontalPan(_ pan: UIPanGestureRecognizer) -> Bool {
        let velocity = pan.velocity(in: pan.view)
        let vector = velocity == .zero ? pan.translation(in: pan.view) : velocity
        return TesseraGestureArbiter.axisDecision(forVelocity: vector) == .horizontal
    }

    /// Завершает горизонтальный жест: возвращает детям исходную прокрутку.
    ///
    /// После этого арбитр освобождается: сильных ссылок на скролл-вью страниц
    /// между жестами контроллер не держит, выгруженные страницы (§7) не живут
    /// в арбитре.
    private func endHorizontalScroll() {
        gestureArbiter?.endHorizontalScroll()
        gestureArbiter = nil
        pruneVerticalOwners()
    }

    /// Живые зарегистрированные владельцы (без самого пейджера).
    private var liveVerticalOwners: [UIScrollView] {
        verticalOwners
            .compactMap(\.scrollView)
            .filter { $0 !== pagerScrollView }
    }

    /// Убирает из реестра освобождённые скролл-вью (§7: страницы живут ±1).
    private func pruneVerticalOwners() {
        verticalOwners.removeAll { $0.scrollView == nil }
    }

    /// Состояния пана пейджера: блокировка и разблокировка вертикальных детей.
    ///
    /// `UIScrollView` начинает пан при горизонтальном протягивании; на это время
    /// дочерние вертикальные скроллы выключаются, чтобы жест не «разрывался»
    /// между осями (docs/CORE-IOS-DESIGN.md §2, «Арбитраж»). По завершении
    /// жеста каждому ребёнку возвращается его исходное `isScrollEnabled`.
    ///
    /// Layout здесь не выполняется — только чтение состояния и флаг прокрутки
    /// (§4, §7).
    @objc private func pagerPanDidChange(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            beginHorizontalScroll(with: pan)
        case .ended, .cancelled, .failed:
            endHorizontalScroll()
        case .possible, .changed:
            break
        @unknown default:
            endHorizontalScroll()
        }
    }

    // MARK: - Уведомления

    /// Смена категории Dynamic Type: пересчитываются крупный заголовок и
    /// высота ленты (§8). Вызывается вне горячего пути свайпа (§7).
    @objc private func contentSizeCategoryDidChange() {
        guard isViewLoaded else { return }

        updateAppTitleFont()
        invalidateStripHeightCache()
        view.setNeedsLayout()
    }

    // MARK: - Фабрика страниц

    /// Превращает секции в страницы пейджера Core (docs/PIVOT-IOS-DESIGN.md §3).
    ///
    /// Идентификатор и заголовок секции переходят в ``TesseraPageDescriptor``
    /// без изменений: по `id` пейджер переиспользует контроллер контента и
    /// сохраняет текущую страницу при `reload` (§5, §7).
    private static func makePageDescriptors(
        for sections: [PivotSection]
    ) -> [TesseraPageDescriptor] {
        sections.map { section in
            TesseraPageDescriptor(
                id: section.id,
                title: section.title,
                content: section.content
            )
        }
    }
}

// MARK: - TesseraPagerDelegate (§5)

extension PivotViewController: TesseraPagerDelegate {

    /// Свайп → лента: единственная точка непрерывной синхронизации (§5).
    ///
    /// Здесь только чтение прогресса: лента двигает индикатор и перекрашивает
    /// видимые заголовки (`transform`/цвет), layout не запускается (§4, §7).
    /// Обратной записи в пейджер нет — циклов не возникает (§5).
    ///
    /// - Parameters:
    ///   - pager: Пейджер-источник события.
    ///   - progress: Нормализованный по направлению чтения прогресс
    ///     (§4, ``TesseraRTL``). При bounce может выходить за диапазон.
    public func pager(
        _ pager: TesseraPagerViewController,
        didChangeProgress progress: CGFloat
    ) {
        headerStripView.apply(progress: progress)
        updateCurrentIndex(fromProgress: progress)
        delegate?.pivot(self, didChangeProgress: progress)
    }

    /// Завершение перехода: автоцентрирование ленты, анонс, колбэк делегата (§4, §8).
    ///
    /// - Parameters:
    ///   - pager: Пейджер-источник события.
    ///   - index: Показанная секция в порядке чтения.
    public func pager(
        _ pager: TesseraPagerViewController,
        didShowPageAt index: Int
    ) {
        guard sections.indices.contains(index) else { return }

        currentSectionIndex = index
        needsInitialCentering = false

        headerStripView.select(index: index)
        // §4: доцентровываем ленту только по завершении перехода; Reduce Motion
        // отключает анимацию внутри `scrollToCenter`.
        headerStripView.scrollToCenter(index: index, animated: true)

        // §7: Core пересобрал окно страниц ±1 — чистим реестр от скролл-вью
        // выгруженных страниц, чтобы они не участвовали в следующих жестах.
        pruneVerticalOwners()

        announceSection(at: index)
        delegate?.pivot(self, didShowSectionAt: index)
    }
}
#endif
