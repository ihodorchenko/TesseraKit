//
//  PanoramaViewController.swift
//  TesseraPanorama
//
//  Оркестратор панорамы: горизонталь, фон с параллаксом, заголовки секций и
//  child-контроллеры с ленивой загрузкой.
//  Проектный документ: docs/PANORAMA-IOS-DESIGN.md — §3 «Концептуальная
//  архитектура» (компоновка: PanoramaViewController → PanoScrollView +
//  PanoBackgroundView + PanoHeaderView + контейнер секций), §4 «Геометрия и
//  математика ядра» (единый скаляр t, параллакс фона, снап, никакого layout в
//  скролле), §5 «Вертикальный скролл внутри секции» (вариант B: горизонталь
//  родителю, вертикаль ребёнку), §6 «Производительность» (lazy ±1, prefetch,
//  без layout в горячем пути), §7 «Accessibility» (VoiceOver, Reduce Motion,
//  Dynamic Type, RTL), §8 «Адаптивность» (поворот, одна секция, пустой список),
//  §9 «Объём MVP».
//
//  Инварианты (§1, §4):
//  - единственный скаляр `t = contentOffset.x / itemWidth` — источник для фона,
//    заголовков и делегата;
//  - `contentOffset` пишут только жест `PanoScrollView` и программный переход
//    (`selectSection(at:animated:)`) — правило одного писателя из
//    docs/CORE-IOS-DESIGN.md §2;
//  - в `scrollViewDidScroll` — только `frame`/`transform`/`alpha`, без layout.
//

#if canImport(UIKit)
import TesseraCore
import UIKit

/// Контроллер панорамы: горизонтальные секции-«холсты» с peek, параллакс фона и
/// заголовки, анимированные по прогрессу свайпа (docs/PANORAMA-IOS-DESIGN.md §3).
///
/// ## Компоновка (§3)
///
/// ```
/// PanoramaViewController
///     ├─ TesseraParallaxLayer + UIImageView  ← фон, параллакс по смещению
///     ├─ PanoScrollView                       ← горизонталь, снап, t
///     │     └─ child-VC секций (окно ±1)      ← вертикальный скролл секции
///     └─ PanoHeaderView                       ← заголовки по тому же t
/// ```
///
/// Фон лежит ниже остальных слоёв и виден в полосе «подсматривания» (peek) и в
/// секциях с прозрачным контентом. Заголовки вынесены над полосой прокрутки:
/// они не участвуют в горизонтальной раскладке, а двигаются собственным
/// `transform` от того же `t` (§4, «Заголовки»).
///
/// ## Единый прогресс (§1, §4)
///
/// `t = contentOffset.x / itemWidth`; целая часть — индекс секции, дробная —
/// прогресс перехода. В RTL прогресс и индекс нормализуются по направлению
/// чтения через ``TesseraRTL``: `0` — первая секция для пользователя, а не
/// первый физический слот. Фон и заголовки получают тот же `t`, поэтому
/// расхождений между слоями быть не может.
///
/// ## Ленивая загрузка и prefetch (§6)
///
/// В памяти — текущая секция и соседи ±1. Окно обновляется по завершении
/// перехода и в layout-проходе, а сосед, к которому уже летит инерция,
/// догружается в `scrollViewWillEndDragging` — до снапа, чтобы свайп не упирался
/// в ленивую загрузку. В `scrollViewDidScroll` иерархия не меняется.
///
/// ## Вертикальный скролл (§5, вариант B)
///
/// Горизонталь обрабатывает ``PanoScrollView``, вертикаль — собственный скролл
/// секции. Контроллеры контента регистрируют свои вертикальные скролл-вью через
/// ``registerVerticalOwner(_:)``; на время горизонтального жеста их прокрутка
/// блокируется и восстанавливается через ``TesseraGestureArbiter``. Точка
/// принятия решения по оси и вынужденное отклонение от §5 задокументированы в
/// ``registerVerticalOwner(_:)``.
///
/// ## Accessibility (§7)
///
/// - **VoiceOver**: трёхпальцевый свайп обрабатывается ``PanoScrollView`` и
///   контроллером как шаг по секциям
///   (``TesseraAccessibility/pageStep(for:layoutDirection:)``), а по завершении
///   перехода название секции озвучивается через
///   ``TesseraAccessibility/announcePageChange(_:)``. Заголовок слоя заголовков —
///   отдельный элемент с трейтом `.header`.
/// - **Reduce Motion**: параллакс выключает сам ``TesseraParallaxLayer`` (фактор
///   0), статичные заголовки — ``PanoHeaderView``, а программные переходы
///   контроллер выполняет без анимации.
/// - **Dynamic Type**: шрифты заголовков масштабируются внутри
///   ``PanoHeaderView``; смена категории размера текста пересчитывает раскладку
///   вне горячего пути скролла.
/// - **RTL**: слоты секций зеркалируются, прогресс и индекс нормализуются через
///   ``TesseraRTL`` (§7, «RTL»).
///
/// ## Адаптивность (§8)
///
/// При смене ширины/высоты (поворот, iPad, split view) `itemWidth` и `contentSize`
/// пересчитываются, а текущая секция восстанавливается по индексу и сохранённой
/// доле внутри секции. Смена геометрии во время активного жеста или инерции
/// откладывается до их завершения (§8). Одна секция — без снапа и на всю ширину;
/// пустой список — без секций и заголовков (placeholder не фабрикуется, см.
/// примечание ниже).
///
/// - Note: **Пустой список.** ``PanoramaDelegate`` (волна 1) не имеет хука
///   placeholder-состояния, а менять протокол вне write-скоупа нельзя. Поэтому
///   при пустом наборе секций контроллер не показывает собственный placeholder:
///   остаётся только фон, заголовки скрыты. Хост узнаёт о пустом состоянии по
///   пустому `sections` в момент `reload`. Открытый вопрос для следующей волны —
///   добавить в делегат событие пустого состояния (см. отчёт).
///
/// - Important: Только главный поток: UI-состояние не размазывается по модулям
///   (docs/CORE-IOS-DESIGN.md §3). Делегат не удерживается.
public final class PanoramaViewController: UIViewController {

    // MARK: - Метрики компоновки

    /// Геометрия, не зависящая от стиля и Dynamic Type.
    private enum Metrics {
        /// Отступ от верхней safe area до слоя заголовков.
        static let headerTopPadding: CGFloat = 8

        /// Отступ от заголовков до полосы прокрутки.
        static let headerBottomSpacing: CGFloat = 8

        /// Боковой отступ текста заголовков.
        static let headerSideInset: CGFloat = 20

        /// Допуск «offset уже выровнен», в точках (доводка снапа, E9.2б).
        static let alignmentTolerance: CGFloat = 0.5

        /// Минимальный запас фонового слоя под «резину» на границах (§4).
        ///
        /// При bounce `contentOffset` уходит за край ленты, и фон сдвигается
        /// дальше обычного диапазона. Запас нужен с обеих сторон, иначе на
        /// упругом отскоке у края появилась бы пустая полоса.
        static let backgroundBouncePadding: CGFloat = 96
    }

    // MARK: - Публичная конфигурация

    /// Текущий набор секций в порядке чтения (§3).
    ///
    /// Меняется только через ``reload(sections:)`` (и инициализатор). Секции —
    /// источник истины и для заголовков, и для контента: по их `id` хостинг
    /// переиспользует child-контроллеры, а текущая секция сохраняется при
    /// перезагрузке.
    public private(set) var sections: [PanoramaSection] = []

    /// Внешний вид панорамы (§3).
    ///
    /// Присваивание применяется сразу: шрифт и цвета заголовков, фон и
    /// подстройка отступов уходят в слои, а peek и раскладка — в ближайший
    /// layout-проход (вне скролла), где текущая секция восстанавливается под
    /// новую ширину (§8).
    ///
    /// Присваивание того же стиля (все поля совпадают, картинка фона — тот же
    /// экземпляр) ничего не делает: SwiftUI-фасад присваивает стиль на каждом
    /// обновлении (E10.13).
    public var style: PanoramaStyle {
        didSet {
            guard !oldValue.isEquivalent(to: style) else { return }
            applyStyle()
        }
    }

    /// Политика снапа (§4, «Снап»).
    ///
    /// В ``PanoramaStyle`` поля снапа нет (волна 1), поэтому порог скорости и
    /// выравнивание настраиваются здесь. Значение по умолчанию — параметры Core
    /// (`600` pt/s, выравнивание по центру). Смена политики не требует layout и
    /// вступает в силу со следующего жеста.
    public var snapPolicy: TesseraSnapPolicy {
        didSet {
            scrollView.snapPolicy = snapPolicy
        }
    }

    /// Наблюдатель показа секции и прогресса.
    ///
    /// Не удерживается (§3: делегат только читает состояние). Публичные колбэки —
    /// ``PanoramaDelegate``.
    public weak var delegate: PanoramaDelegate?

    // MARK: - Слои (§3)

    /// Горизонтальный скролл панорамы: геометрия секций, снап и `t` (§4).
    ///
    /// Доступен на уровне модуля (`@testable`) для контрактных тестов E3.7;
    /// в публичную поверхность не входит — программные переходы выполняются
    /// через ``selectSection(at:animated:)``.
    let scrollView: PanoScrollView

    /// Слой заголовков секций, анимируемый по `t` (§4, «Заголовки»).
    let headerView: PanoHeaderView

    /// Фоновый слой с параллаксом (Core §2, PANORAMA §4).
    ///
    /// Размер и `transform` меняются только вне горячего пути: размер — в
    /// layout-проходе, `transform` — из `scrollViewDidScroll`.
    let parallaxLayer = TesseraParallaxLayer()

    /// Картинка фона; одна на всю панораму (§9, «Отрезано в v1»).
    private let backgroundImageView = UIImageView()

    // MARK: - Состояние

    /// Реестр переиспользования контроллеров контента (Core, `TesseraContentHosting`).
    private let contentHosting = TesseraContentHosting()

    /// Загруженные child-контроллеры по индексу в порядке чтения (окно ±1, §6).
    ///
    /// `private(set)` на уровне модуля — для контрактных тестов E3.7.
    private(set) var loadedSections: [Int: UIViewController] = [:]

    /// Текущая секция в порядке чтения (ближайшая к прогрессу).
    ///
    /// `private(set)` на уровне модуля — для контрактных тестов E3.7.
    private(set) var currentSectionIndex: Int = 0

    /// Секция, о которой уже сообщили делегату (`didShowSectionAt`).
    private var lastShownSectionIndex: Int?

    /// Ширина/высота последнего layout-прохода — для детекта смены геометрии (§8).
    private var lastLayoutWidth: CGFloat = 0
    private var lastLayoutHeight: CGFloat = 0

    /// Направление чтения последнего layout-прохода (§7, «RTL»).
    private var lastLayoutDirection: UIUserInterfaceLayoutDirection?

    /// Нужно восстановить offset текущей секции на ближайшем layout'е
    /// (первый layout, `reload`, смена направления чтения).
    private var needsOffsetRestore = true

    /// Доля внутри секции, сохранённая перед сменой геометрии (§8).
    ///
    /// Хранится как прогресс в порядке чтения: `i + f`, где `i` — индекс, `f` —
    /// доля перехода к следующей.
    private var savedReadingProgress: CGFloat?

    /// Layout пришлось отложить из-за активного жеста/инерции (§8).
    private var needsDeferredLayout = false

    /// Идёт программное восстановление offset'а в layout-проходе.
    ///
    /// Нужно, чтобы `scrollViewDidScroll`, вызванный `setContentOffset` внутри
    /// layout'а, не рассылал `didChangeProgress`: это не прогресс пользователя, а
    /// следствие пересчёта геометрии. Колбэки делегата из layout-прохода ломали
    /// бы контракт «делегат читает состояние» (§4) и, в SwiftUI-фасаде, приходили
    /// бы во время обновления представления.
    private var isRestoringGeometry = false

    // MARK: - Арбитраж жестов (§5, вариант B)

    /// Слабая ссылка на вертикальный скролл-вью секции.
    ///
    /// Секции загружаются лениво окном ±1 и выгружаются (§6), поэтому сильных
    /// ссылок на их скроллы контроллер не держит.
    private struct WeakVerticalOwner {
        weak var scrollView: UIScrollView?
    }

    /// Зарегистрированные вертикальные владельцы-дети.
    private var verticalOwners: [WeakVerticalOwner] = []

    /// Арбитр Core на время горизонтального жеста.
    ///
    /// Живёт только между `.began` и завершением пана: он удерживает вертикальные
    /// скролл-вью сильными ссылками, а секции пересоздаются, поэтому постоянное
    /// удержание продлевало бы жизнь выгруженному контенту.
    private var gestureArbiter: TesseraGestureArbiter?

    /// Пан скролл-вью, на который подписан контроллер (слабо: владелец — скролл).
    private weak var observedPan: UIPanGestureRecognizer?

    // MARK: - Инициализация

    /// Создаёт панораму с готовым набором секций.
    ///
    /// - Parameters:
    ///   - sections: Секции в порядке чтения; пустой массив — допустимое начальное
    ///     состояние (секции можно передать позже через ``reload(sections:)``, §8).
    ///   - style: Внешний вид; по умолчанию системный.
    public init(sections: [PanoramaSection] = [], style: PanoramaStyle = PanoramaStyle()) {
        let scrollView = PanoScrollView(peek: style.peek)
        scrollView.sectionCount = sections.count

        self.scrollView = scrollView
        self.headerView = TesseraPanoHeaderView(
            titles: sections.map(\.title),
            style: PanoramaViewController.makeHeaderStyle(from: style)
        )
        self.sections = sections
        self.style = style
        self.snapPolicy = TesseraSnapPolicy()

        super.init(nibName: nil, bundle: nil)
    }

    /// Инициализация из архива/сториборда не поддерживается: компоновка строится
    /// кодом (§3).
    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        observedPan?.removeTarget(self, action: #selector(scrollPanDidChange(_:)))
    }

    // MARK: - Жизненный цикл

    /// Корневой вид, который замечает смену `semanticContentAttribute` на лету
    /// (§7, «RTL»; E10.13).
    public override func loadView() {
        view = PanoramaRootView()
    }

    /// Смена направления чтения через trait-окружение перераскладывает слоты
    /// (§7, «RTL»; E10.13). Текущая секция сохраняется по прогрессу в прежнем
    /// направлении — см. `layoutPanorama()`.
    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded,
              previousTraitCollection?.layoutDirection != traitCollection.layoutDirection else { return }
        view.setNeedsLayout()
    }

    /// Собирает иерархию слоёв и подписки (§3).
    public override func viewDidLoad() {
        super.viewDidLoad()

        configureSubviews()
        applyStyle()

        // Заголовки могли быть заменены через `reload` до загрузки вида: сеттер
        // слоя идемпотентен и не пересоздаёт метки, если набор не изменился.
        headerView.setTitles(sections.map(\.title))
        scrollView.sectionCount = sections.count
        view.setNeedsLayout()
    }

    /// Единственный layout-проход контроллера (§4, §6, §8).
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPanorama()
    }

    /// Синхронизирует индекс и окно секций с фактическим offset'ом к показу.
    ///
    /// Показ мог состояться без layout (например, нулевая ширина при добавлении
    /// в контейнер) — здесь состояние доводится до согласованного.
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard !sections.isEmpty, scrollView.bounds.width > 0 else { return }
        applyProgress(notifyDelegate: false)
        refreshLoadedSections(around: currentSectionIndex)
    }

    // MARK: - Публичный API

    /// Пересобирает панораму под новый набор секций.
    ///
    /// Текущая секция сохраняется по `id`, если он есть в новом наборе; иначе
    /// сохраняется прежний индекс с зажимом в новые границы. Контроллеры
    /// секций, чей `id` сохранился и попадает в новое окно ±1, переиспользуются
    /// (тот же экземпляр — вертикальная позиция и `@State` не теряются;
    /// SwiftUI-контент обновляется на месте), выгружаются только исчезнувшие и
    /// вышедшие из окна (E10.13, как пейджер Core в W1). `contentSize` и кадры
    /// пересчитываются в `viewDidLayoutSubviews` (единственное место layout'а, §4).
    ///
    /// - Parameter newSections: Новые секции в порядке чтения; пустой массив
    ///   допустим (§8).
    public func reload(sections newSections: [PanoramaSection]) {
        // Текущий id — из СТАРОГО набора: по нему секция ищется в новом.
        let oldSections = sections
        let previousIndex = clampedSectionIndex(currentSectionIndex)
        let previousID: AnyHashable? = oldSections.indices.contains(previousIndex)
            ? oldSections[previousIndex].id
            : nil

        // Останавливаем инерцию/анимацию до выгрузки секций: `contentOffset`
        // пишет только контроллер (§2, «Один писатель»).
        if isViewLoaded {
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        }
        _ = scrollView.consumePendingSnapOffsetX()

        // Загруженные контроллеры — по id старого набора.
        var survivors: [(id: AnyHashable, controller: UIViewController)] = []
        for (index, controller) in loadedSections.sorted(by: { $0.key < $1.key }) {
            if oldSections.indices.contains(index) {
                survivors.append((oldSections[index].id, controller))
            } else {
                detach(controller)
            }
        }
        loadedSections.removeAll()

        self.sections = newSections

        if newSections.isEmpty {
            currentSectionIndex = 0
        } else if let previousID,
                  let preservedIndex = newSections.firstIndex(where: { $0.id == previousID }) {
            currentSectionIndex = preservedIndex
        } else {
            currentSectionIndex = min(max(previousIndex, 0), newSections.count - 1)
        }

        // Выжившие в новом окне ±1 остаются (тот же экземпляр из реестра,
        // SwiftUI-поставщик обновляет rootView); остальные выгружаются.
        let window = sectionWindow(around: currentSectionIndex)
        for survivor in survivors {
            if let newIndex = newSections.firstIndex(where: { $0.id == survivor.id }),
               window.contains(newIndex),
               loadedSections[newIndex] == nil {
                loadedSections[newIndex] = survivor.controller
                _ = contentHosting.viewController(
                    for: survivor.id,
                    provider: newSections[newIndex].content
                )
            } else {
                detach(survivor.controller)
                contentHosting.removeContent(for: survivor.id)
            }
        }
        if newSections.isEmpty {
            contentHosting.removeAll()
        }

        lastShownSectionIndex = nil
        savedReadingProgress = nil
        needsOffsetRestore = true

        guard isViewLoaded else { return }

        headerView.setTitles(newSections.map(\.title))
        scrollView.sectionCount = newSections.count
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    /// Доносит новый контент до секций с тем же набором `id` и заголовков
    /// (E10.12б).
    ///
    /// Путь SwiftUI-фасада: при перерисовке ``PanoramaView`` с теми же `id` и
    /// заголовками полный ``reload(sections:)`` не нужен (он останавливает
    /// прокрутку и сбрасывает показ секции), но поставщики контента новые —
    /// их замыкания захватили свежее состояние. Здесь заменяется только модель,
    /// а загруженные контроллеры получают новый контент через
    /// ``TesseraContentHosting``: SwiftUI-контроллер обновляет `rootView` на
    /// месте (тот же экземпляр, позиция и `@State` сохраняются); UIKit-поставщик
    /// обновлять произвольный контроллер не умеет — экземпляр остаётся прежним.
    /// Невыгруженные секции создадутся из новых поставщиков при загрузке.
    /// `contentOffset`, окно ±1 и делегат не затрагиваются.
    ///
    /// Если набор `id`/заголовков всё же отличается, выполняется полный
    /// ``reload(sections:)``.
    ///
    /// - Parameter newSections: Секции с тем же порядком `id` и заголовков.
    func updateContent(of newSections: [PanoramaSection]) {
        guard Self.haveSameIdentity(sections, newSections) else {
            reload(sections: newSections)
            return
        }

        sections = newSections
        for index in loadedSections.keys where newSections.indices.contains(index) {
            // Для валидных наборов (уникальные id) реестр вернёт тот же
            // загруженный экземпляр, обновив его контент на месте.
            let section = newSections[index]
            _ = contentHosting.viewController(for: section.id, provider: section.content)
        }
    }

    /// Совпадают ли наборы секций по `id` и заголовкам (по порядку).
    ///
    /// ``PanoramaSection`` не `Equatable`: у поставщика контента нет семантики
    /// равенства, поэтому идентичность набора — пары `id` + `title`.
    ///
    /// - Parameters:
    ///   - lhs: Первый набор.
    ///   - rhs: Второй набор.
    /// - Returns: `true`, если `id` и заголовки совпадают поэлементно.
    static func haveSameIdentity(_ lhs: [PanoramaSection], _ rhs: [PanoramaSection]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { $0.id == $1.id && $0.title == $1.title }
    }

    /// Программно переходит к секции.
    ///
    /// Единственный программный писатель `contentOffset` (§2, «Один писатель»).
    /// При анимированном переходе делегат продолжает получать `didChangeProgress`
    /// на кадрах анимации, поэтому заголовки и фон анимируются сами — отдельной
    /// анимации слоёв нет (§4).
    ///
    /// При Reduce Motion анимация отключается принудительно (§7). Индекс
    /// зажимается в границы набора секций.
    ///
    /// Анимированный переход дальше соседней секции — «прямой прыжок», как у
    /// пейджера Core (E10.13): окно ±1 сначала загружается вокруг цели, offset
    /// без анимации переставляется на соседа цели со стороны текущей секции, и
    /// анимируется один последний шаг — без пролёта пустых (невыгруженных)
    /// слотов. Делегат получает один `didChangeProgress` со скачком на соседа
    /// цели (прогресс всегда отражает фактический offset), затем кадры
    /// анимации; `didShowSectionAt` — только для цели.
    ///
    /// - Parameters:
    ///   - index: Индекс секции в порядке чтения (в RTL — не физический слот).
    ///   - animated: Намерение анимировать переход; Reduce Motion имеет приоритет.
    public func selectSection(at index: Int, animated: Bool) {
        guard !sections.isEmpty else { return }

        let targetIndex = clampedSectionIndex(index)
        let shouldAnimate = animated && !TesseraAccessibility.isReduceMotionEnabled

        currentSectionIndex = targetIndex

        guard isViewLoaded else {
            // До загрузки вида запоминаем намерение: первый layout поставит offset
            // на нужную секцию без промежуточного скачка.
            needsOffsetRestore = true
            return
        }

        // Геометрия должна быть актуальной до расчёта offset'а. Это layout-путь,
        // а не горячий: программный переход не выполняется внутри скролла (§6).
        view.layoutIfNeeded()

        // Ширины ещё нет (вид вне иерархии): запоминаем намерение, offset
        // поставит первый настоящий layout — без ложного анонса секции (§8).
        guard scrollView.bounds.width > 0 else {
            needsOffsetRestore = true
            return
        }

        let offset = CGPoint(x: scrollView.rawOffset(forReadingProgress: CGFloat(targetIndex)), y: 0)
        if abs(offset.x - scrollView.contentOffset.x) <= .ulpOfOne {
            // Переход «на месте»: анимации не будет, завершение фиксируем сами —
            // иначе `scrollViewDidEndScrollingAnimation` не придёт.
            scrollView.setContentOffset(offset, animated: false)
            finishTransition()
            return
        }

        if shouldAnimate {
            let fromIndex = nearestSectionIndex(
                forReadingProgress: scrollView.readingProgress(forRawOffset: scrollView.contentOffset.x)
            )
            let distance = targetIndex - fromIndex
            if abs(distance) > 1 {
                // Окно цели — до прыжка: в кадре анимации не должно быть
                // пустых слотов. Иерархия меняется вне горячего пути (§6).
                refreshLoadedSections(around: targetIndex)
                let neighbourIndex = targetIndex - distance.signum()
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.rawOffset(forReadingProgress: CGFloat(neighbourIndex)), y: 0),
                    animated: false
                )
                currentSectionIndex = targetIndex
            }
        }

        scrollView.setContentOffset(offset, animated: shouldAnimate)
        if !shouldAnimate {
            finishTransition()
        }
    }

    /// Регистрирует вертикальный скролл-вью секции (§5, вариант B).
    ///
    /// Горизонталь принадлежит ``PanoScrollView``, вертикаль — контенту секции.
    /// Контроллер контента вызывает метод (например, из `viewDidAppear`) и
    /// передаёт свой вертикальный `UIScrollView`. На время горизонтального жеста
    /// контроллер собирает ``TesseraGestureArbiter`` из зарегистрированных детей:
    /// их прокрутка блокируется и восстанавливается в исходное состояние по
    /// завершении жеста (`prepareForHorizontalScroll()` /
    /// `endHorizontalScroll()`).
    ///
    /// Ссылки слабые: выгруженные секции (§6) выпадают из реестра сами.
    ///
    /// - Parameter scrollView: Вертикальный скролл-вью контента секции.
    ///
    /// - Note: **Отклонение от §5.** Арбитр не назначается делегатом
    ///   `panGestureRecognizer` панорамы: подмена делегата у `UIScrollView`
    ///   отключила бы его собственную обработку одновременных жестов (вложенные
    ///   скроллы, системный edge-swipe). Поэтому:
    ///   1. решение по доминирующей оси принимается на первом колбэке пана
    ///      (`.began`) через
    ///      ``TesseraGestureArbiter/axisDecision(forVelocity:)`` — та же чистая
    ///      функция, что и в `gestureRecognizerShouldBegin` арбитра;
    ///   2. дети блокируются и разблокируются методами арбитра, то есть обе
    ///      половины контракта арбитража задействованы, но точка решения сдвинута
    ///      с `gestureRecognizerShouldBegin` на `.began`. Это тот же компромисс,
    ///      что принят в `PivotViewController` (E2).
    public func registerVerticalOwner(_ scrollView: UIScrollView) {
        guard scrollView !== self.scrollView else { return }

        pruneVerticalOwners()
        guard !verticalOwners.contains(where: { $0.scrollView === scrollView }) else { return }
        verticalOwners.append(WeakVerticalOwner(scrollView: scrollView))
    }

    /// Снимает регистрацию вертикального скролл-вью секции (§5).
    ///
    /// Вызывать не обязательно: ссылки слабые, и освобождённые скроллы выпадают из
    /// арбитража сами. Метод нужен, когда контроллер контента перестаёт
    /// использовать скролл-вью, но живёт дальше.
    ///
    /// - Parameter scrollView: Ранее зарегистрированный вертикальный скролл-вью.
    public func unregisterVerticalOwner(_ scrollView: UIScrollView) {
        verticalOwners.removeAll { owner in
            guard let registered = owner.scrollView else { return true }
            return registered === scrollView
        }
    }

    // MARK: - Accessibility (§7)

    /// Пагинация секций жестом VoiceOver «три пальца» (§7, «VoiceOver»).
    ///
    /// Направление превращается в шаг по секциям через
    /// ``TesseraAccessibility/pageStep(for:layoutDirection:)`` (с учётом RTL), а
    /// переход выполняет ``selectSection(at:animated:)`` — `contentOffset`
    /// по-прежнему пишет контроллер (§2). Метод дублирует обработку из
    /// ``PanoScrollView``: у жеста бывает разный accessibility-фокус (слой
    /// заголовков, контент секции), а результат обязан быть одинаковым.
    ///
    /// - Parameter direction: Направление жеста VoiceOver.
    /// - Returns: `true`, если жест обработан.
    public override func accessibilityScroll(
        _ direction: UIAccessibilityScrollDirection
    ) -> Bool {
        guard isViewLoaded, sections.count > 1 else { return false }

        let step = TesseraAccessibility.pageStep(
            for: direction,
            layoutDirection: view.effectiveUserInterfaceLayoutDirection
        )
        return handleAccessibilityStep(step)
    }

    // MARK: - Сборка слоёв

    /// Создаёт иерархию: фон, скролл, заголовки (§3).
    private func configureSubviews() {
        view.backgroundColor = .systemBackground
        view.clipsToBounds = true

        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.clipsToBounds = true
        backgroundImageView.isUserInteractionEnabled = false
        backgroundImageView.isAccessibilityElement = false
        parallaxLayer.addSubview(backgroundImageView)
        view.addSubview(parallaxLayer)

        scrollView.observer = self
        scrollView.peek = style.peek
        scrollView.snapPolicy = snapPolicy
        view.addSubview(scrollView)

        // Заголовки — верхний слой: они декоративны (wave 1 отключает у них
        // пользовательские касания) и не должны перекрывать прокрутку.
        view.addSubview(headerView)

        // §7, E9.7: фокус VoiceOver может стоять на слое заголовков —
        // трёхпальцевый свайп с него листает секции так же, как с контента.
        headerView.accessibilityScrollHandler = { [weak self] direction in
            self?.accessibilityScroll(direction) ?? false
        }

        observeScrollPan()

        // §7, Dynamic Type: высота заголовков зависит от размера текста.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
    }

    /// Применяет стиль к слоям (§3).
    ///
    /// `peek` здесь в скролл не пишется: его применяет layout-проход, который
    /// до этого запоминает прогресс по прежней ширине секции — иначе секция
    /// осталась бы между снап-точками (§8, E10.13).
    private func applyStyle() {
        guard isViewLoaded else { return }

        scrollView.contentInsetAdjustmentBehavior = style.contentInsetAdjustmentBehavior
        headerView.style = Self.makeHeaderStyle(from: style)
        applyBackgroundBehavior()
        view.setNeedsLayout()
    }

    /// Переносит поведение фона из стиля в слой (§3, §9).
    ///
    /// В v1 фон один на всю панораму: `.image` — картинка на весь слой,
    /// `.none` — прозрачный слой, виден системный фон под панорамой.
    private func applyBackgroundBehavior() {
        switch style.backgroundBehavior {
        case .none:
            backgroundImageView.image = nil
            backgroundImageView.isHidden = true
        case .image(let image):
            backgroundImageView.image = image
            backgroundImageView.isHidden = (image == nil)
        }
    }

    /// Стиль заголовков из стиля панорамы (§3, §7).
    ///
    /// `PanoramaStyle.headerFont` — базовый (немасштабированный) шрифт: слой
    /// заголовков сам масштабирует его через `UIFontMetrics` под Dynamic Type.
    ///
    /// `PanoramaStyle.headerActiveColor` уходит в слой как цвет активного
    /// заголовка, интерполируемый по `t` (E9.7). Если он совпадает с
    /// `headerColor`, акцент не нужен — слой не создаёт акцентных копий меток.
    private static func makeHeaderStyle(from style: PanoramaStyle) -> PanoHeaderView.Style {
        PanoHeaderView.Style(
            textStyle: .largeTitle,
            baseFont: style.headerFont,
            textColor: style.headerColor,
            activeTextColor: style.headerActiveColor == style.headerColor
                ? nil
                : style.headerActiveColor,
            travelRatio: 0.3,
            contentInsets: UIEdgeInsets(
                top: 8,
                left: Metrics.headerSideInset,
                bottom: 8,
                right: Metrics.headerSideInset
            ),
            numberOfLines: 0
        )
    }

    // MARK: - Layout (единственное место раскладки)

    /// Раскладывает заголовки, скролл, секции, фон и `contentSize`.
    ///
    /// Вызывается только из `viewDidLayoutSubviews` и синхронных
    /// `layoutIfNeeded` из публичных методов. В `scrollViewDidScroll` layout'а нет
    /// (§4, «Правило производительности»; §6).
    private func layoutPanorama() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        // §8: при активном свайпе изменение размера лучше отложить до конца
        // децелерации — пересборка contentSize дёргала бы offset под пальцем.
        if scrollView.isUserScrollInFlight {
            needsDeferredLayout = true
            return
        }

        // Направление чтения корневого вида — единственный источник для слоёв:
        // `semanticContentAttribute` не наследуется subview'ами, а скролл и
        // заголовки считают слоты/зеркалирование от собственного направления.
        if scrollView.semanticContentAttribute != view.semanticContentAttribute {
            scrollView.semanticContentAttribute = view.semanticContentAttribute
        }
        if headerView.semanticContentAttribute != view.semanticContentAttribute {
            headerView.semanticContentAttribute = view.semanticContentAttribute
        }

        let direction = view.effectiveUserInterfaceLayoutDirection
        // Направление, в котором сейчас разложены слоты и стоит offset.
        let slotDirection = lastLayoutDirection ?? direction
        // `peek` из стиля ещё не применён к скроллу: смена ширины секции на лету
        // — такая же смена геометрии, как поворот (E10.13).
        let peekChanged = abs(scrollView.peek - style.peek) > .ulpOfOne
        let geometryChanged = lastLayoutWidth > 0
            && (abs(bounds.width - lastLayoutWidth) > .ulpOfOne
                || abs(bounds.height - lastLayoutHeight) > .ulpOfOne
                || slotDirection != direction
                || peekChanged)

        // §8: долю внутри секции запоминаем до смены itemWidth, иначе после
        // пересчёта её уже не восстановить. Нормализация — по направлению, в
        // котором offset стоит сейчас, а не по новому: при смене LTR↔RTL иначе
        // открылась бы зеркальная секция (E10.13). Скролл здесь ещё в прежней
        // геометрии: кадр и peek применяются ниже.
        if geometryChanged, sections.count > 1 {
            savedReadingProgress = scrollView.readingProgress(
                forRawOffset: scrollView.contentOffset.x,
                layoutDirection: slotDirection
            )
        }

        // Запись кадра, contentSize и offset'а — следствие пересчёта геометрии,
        // а не прогресс пользователя: UIKit может прислать на них
        // `scrollViewDidScroll`, и делегат не должен получить ложный
        // `didChangeProgress`, а текущая секция — сбиться (E10.13). Итоговый
        // прогресс применяется один раз в конце прохода.
        isRestoringGeometry = true
        layoutHeader(in: bounds)

        let contentTop = headerView.isHidden
            ? 0
            : min(headerView.frame.maxY + Metrics.headerBottomSpacing, bounds.height)
        scrollView.frame = CGRect(
            x: 0,
            y: contentTop,
            width: bounds.width,
            height: max(bounds.height - contentTop, 0)
        )

        // Геометрия контента: §4 — itemWidth = width − peek, contentSize по числу
        // секций. Порядок важен: contentSize до восстановления offset'а, иначе
        // UIKit зажмёт offset по старому размеру.
        scrollView.peek = style.peek
        scrollView.sectionCount = sections.count
        scrollView.isScrollEnabled = sections.count > 1
        scrollView.contentSize = scrollView.requiredContentSize

        restoreOffsetIfNeeded(geometryChanged: geometryChanged)
        isRestoringGeometry = false

        layoutBackground()
        refreshLoadedSections(around: currentSectionIndex)
        layoutSectionFrames()
        applyProgress(notifyDelegate: false)

        lastLayoutWidth = bounds.width
        lastLayoutHeight = bounds.height
        lastLayoutDirection = direction
        needsDeferredLayout = false
    }

    /// Раскладывает слой заголовков (§4, «Заголовки»).
    ///
    /// Высота — по `intrinsicContentSize`, то есть по фактическим меткам и
    /// текущему Dynamic Type. Ширину задаём до чтения intrinsic: заголовки
    /// считают высоту от фактической ширины (§7).
    private func layoutHeader(in bounds: CGRect) {
        guard !sections.isEmpty else {
            headerView.isHidden = true
            headerView.frame = .zero
            return
        }

        headerView.isHidden = false

        // Ширина нужна до высоты: `intrinsicContentSize` заголовков зависит от
        // ширины слоя. Прямая запись `frame.size` не запускает layout дважды.
        headerView.frame.size.width = bounds.width
        let height = max(headerView.intrinsicContentSize.height, 0)

        headerView.frame = CGRect(
            x: 0,
            y: view.safeAreaInsets.top + Metrics.headerTopPadding,
            width: bounds.width,
            height: height
        )
    }

    /// Раскладывает фоновый слой под параллакс (§4, «Параллакс фона»).
    ///
    /// Контракт Core (`docs/CORE-IOS-DESIGN.md` §2, п. «Параллакс»): слой
    /// заведомо больше контента — `contentSize` плюс запас `extraSize`. Здесь
    /// `contentSize` — размер контента панорамы (но не меньше вьюпорта, иначе
    /// пустое состояние осталось бы без фона), а запас — весь ход фона
    /// (`maximumOffsetX × factor`) плюс поля под «резину» на границах.
    ///
    /// Слой — сосед скролла, поэтому ``TesseraParallaxLayer/update(withContentOffset:)``
    /// проецирует смещение фона (`backgroundOffset = offset × factor`) на экран
    /// со знаком минус: `transform = −backgroundOffset` (E10.7). При росте offset'а
    /// фон уезжает влево вместе с секциями, но медленнее. Начало слоя — у левого
    /// края вьюпорта, сдвинутое влево только на поле `padding` (под «резину» до
    /// начала ленты, где offset < 0); весь ход фона `shift` и правое поле лежат
    /// справа от вьюпорта. Экранный левый край картинки — `−padding − offset × factor`,
    /// правый — `width + shift + padding − offset × factor`: вьюпорт закрыт при
    /// любом offset'е в `[−padding / factor, maximumOffsetX + padding / factor]`,
    /// то есть ни на bounce, ни на краю ленты пустых полос нет. Сама картинка
    /// занимает только реально посещаемое окно, а не всю площадь огромного слоя.
    ///
    /// Множитель берётся из стиля, а не из действующего: при Reduce Motion
    /// действующий фактор равен нулю (Core §2, п. 6), но запас должен остаться
    /// достаточным, если настройку выключат на лету.
    private func layoutBackground() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let factor = style.parallaxFactor
        let shift = scrollView.maximumOffsetX * factor
        // «Резина» уводит contentOffset за край ленты; запас с обеих сторон
        // покрывает выход на `padding / factor`. Слагаемое `0.6 × width × factor`
        // гарантирует не меньше 0.6 ширины экрана при любом факторе из (0, 1)
        // (E9.7: кламп расширен с 0.4…0.6 до 0.01…0.99), остальные — прежний
        // минимум для типичных факторов.
        let padding = max(
            Metrics.backgroundBouncePadding,
            bounds.width * 0.35,
            bounds.width * 0.6 * factor
        )

        let contentSize = CGSize(
            width: max(scrollView.contentSize.width, bounds.width),
            height: max(scrollView.contentSize.height, bounds.height)
        )
        parallaxLayer.configure(factor: factor, extraSize: shift + padding * 2)
        parallaxLayer.setContentSize(contentSize)

        let size = parallaxLayer.bounds.size
        // Начало слоя уходит влево только на «резину»: слой едет влево
        // (transform = −offset × factor, E10.7), поэтому ход фона `shift` нужен
        // справа. Тогда при любом offset'е вьюпорт остаётся внутри картинки,
        // прижатой к началу координат слоя.
        parallaxLayer.center = CGPoint(
            x: -padding + size.width / 2,
            y: size.height / 2
        )

        // Видимое окно фона за всю ленту: вьюпорт, ход фона и «резина» по краям.
        // Остальную площадь огромного слоя заполнять незачем: её не видно.
        backgroundImageView.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width + shift + padding * 2,
            height: bounds.height
        )
    }

    /// Восстанавливает `contentOffset` текущей секции (§8).
    ///
    /// Восстановление — программная запись `contentOffset` из layout'а:
    /// вызывающий держит `isRestoringGeometry` поднятым, колбэки прогресса
    /// делегату на это время выключены.
    ///
    /// - Parameter geometryChanged: Сменилась ширина/высота/направление чтения/peek.
    private func restoreOffsetIfNeeded(geometryChanged: Bool) {
        guard !sections.isEmpty else {
            if scrollView.contentOffset != .zero {
                scrollView.contentOffset = .zero
            }
            needsOffsetRestore = false
            savedReadingProgress = nil
            return
        }

        if needsOffsetRestore {
            // Первый layout, `reload` или смена направления: встаём ровно на
            // сохранённую секцию, без доли перехода.
            scrollView.setContentOffset(
                CGPoint(
                    x: scrollView.rawOffset(
                        forReadingProgress: CGFloat(clampedSectionIndex(currentSectionIndex))
                    ),
                    y: 0
                ),
                animated: false
            )
            needsOffsetRestore = false
            savedReadingProgress = nil
            return
        }

        if geometryChanged, let progress = savedReadingProgress {
            // §8: «по индексу и сохранённому прогрессу» — доля внутри секции
            // сохраняется, если она представима в новых границах.
            scrollView.setContentOffset(
                CGPoint(x: scrollView.rawOffset(forReadingProgress: progress), y: 0),
                animated: false
            )
            savedReadingProgress = nil
            return
        }

        // Число секций могло уменьшиться — offset нужно зажать.
        let maximum = scrollView.maximumOffsetX
        let clampedX = min(max(scrollView.contentOffset.x, 0), maximum)
        if clampedX != scrollView.contentOffset.x {
            scrollView.contentOffset = CGPoint(x: clampedX, y: 0)
        }
    }

    /// Раскладывает кадры загруженных child-контроллеров.
    ///
    /// Единственное место, где меняются их `frame`; в скролле кадры не трогаются
    /// (§4, §6).
    private func layoutSectionFrames() {
        for (index, controller) in loadedSections {
            let frame = scrollView.rect(forReadingIndex: index)
            guard controller.view.frame != frame else { continue }
            controller.view.frame = frame
        }
    }

    // MARK: - Прогресс (горячий путь)

    /// Применяет текущий `contentOffset` к слоям и делегату.
    ///
    /// В горячем пути (из `scrollViewDidScroll`) меняются только `transform` и
    /// `alpha`: `headerView.apply` и `parallaxLayer.update` не запускают layout
    /// (§4, «Правило производительности»). `notifyDelegate: false` используется в
    /// layout-проходе и при синхронизации состояния — там внешний прогресс не
    /// событие.
    ///
    /// - Parameter notifyDelegate: Сообщать ли `didChangeProgress` делегату.
    private func applyProgress(notifyDelegate: Bool) {
        let rawOffset = scrollView.contentOffset.x
        let progress = scrollView.readingProgress(forRawOffset: rawOffset)
        guard progress.isFinite else { return }

        currentSectionIndex = nearestSectionIndex(forReadingProgress: progress)

        // §4: фон и заголовки анимируются от одного и того же t.
        headerView.apply(progress: progress, activeIndex: currentSectionIndex)
        parallaxLayer.update(withContentOffset: CGPoint(x: rawOffset, y: 0))

        guard notifyDelegate, !isRestoringGeometry else { return }
        delegate?.panorama(self, didChangeProgress: progress)
    }

    /// Ближайшая к прогрессу секция в порядке чтения (§4).
    ///
    /// Прогресс уже нормализован по направлению чтения, поэтому индекс — просто
    /// округление с зажимом в границы набора.
    private func nearestSectionIndex(forReadingProgress progress: CGFloat) -> Int {
        guard !sections.isEmpty else { return 0 }
        let last = CGFloat(sections.count - 1)
        return Int(min(max(progress, 0), last).rounded())
    }

    // MARK: - Ленивая загрузка child-VC (§6)

    /// Держит в памяти текущую секцию и соседей ±1, выгружая остальные.
    ///
    /// Вызывается по завершении перехода, из layout'а и `viewDidAppear`, но
    /// никогда из `scrollViewDidScroll`: добавление child-VC — изменение
    /// иерархии, а не работа для кадра прокрутки (§4, §6).
    ///
    /// - Parameter index: Секция, вокруг которой строится окно.
    private func refreshLoadedSections(around index: Int) {
        guard !sections.isEmpty, scrollView.bounds.width > 0 else { return }

        let desired = sectionWindow(around: index)

        for loadedIndex in Array(loadedSections.keys) where !desired.contains(loadedIndex) {
            guard let controller = loadedSections.removeValue(forKey: loadedIndex) else {
                continue
            }
            detach(controller)
            if sections.indices.contains(loadedIndex) {
                contentHosting.removeContent(for: sections[loadedIndex].id)
            }
        }

        for sectionIndex in desired.sorted() where loadedSections[sectionIndex] == nil {
            loadSection(at: sectionIndex)
        }
    }

    /// Догружает окно вокруг цели, **не выгружая** текущую секцию (§6).
    ///
    /// Prefetch-хук вызывается из `scrollViewWillEndDragging`: цель снапа уже
    /// известна, но видимая секция ещё в кадре, поэтому выгрузка здесь дала бы
    /// пустой кадр. Освобождение делает ``refreshLoadedSections(around:)`` по
    /// завершении перехода.
    ///
    /// - Parameter index: Целевая секция снапа.
    private func prefetchSections(around index: Int) {
        guard !sections.isEmpty, scrollView.bounds.width > 0 else { return }

        for sectionIndex in sectionWindow(around: index).sorted()
        where loadedSections[sectionIndex] == nil {
            loadSection(at: sectionIndex)
        }
    }

    /// Индексы окна ±1 вокруг секции (§6); пусто для пустого набора.
    private func sectionWindow(around index: Int) -> Set<Int> {
        guard !sections.isEmpty else { return [] }
        let center = clampedSectionIndex(index)
        return Set([center - 1, center, center + 1].filter { sections.indices.contains($0) })
    }

    /// Создаёт контроллер секции и подключает его как child-VC.
    ///
    /// Контроллер берётся из ``TesseraContentHosting`` по `id` секции: повторная
    /// загрузка того же `id` переиспользует экземпляр (для SwiftUI-контента —
    /// обновляет `rootView` на месте, §6).
    ///
    /// - Parameter index: Индекс секции в порядке чтения.
    private func loadSection(at index: Int) {
        guard sections.indices.contains(index) else { return }

        let section = sections[index]
        var controller = contentHosting.viewController(
            for: section.id,
            provider: section.content
        )

        // Защита от повторяющегося id: один контроллер нельзя добавить дважды.
        // Для валидных наборов (уникальные id) ветка не выполняется.
        if loadedSections.values.contains(where: { $0 === controller }) {
            controller = section.content.makeContentViewController()
        }

        addChild(controller)
        controller.view.frame = scrollView.rect(forReadingIndex: index)
        scrollView.addSubview(controller.view)
        controller.didMove(toParent: self)
        loadedSections[index] = controller
    }

    /// Отсоединяет child-VC от контроллера.
    private func detach(_ controller: UIViewController) {
        guard controller.parent != nil else {
            controller.view.removeFromSuperview()
            return
        }

        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    // MARK: - Завершение перехода

    /// Фиксирует текущую секцию, обновляет окно ±1 и уведомляет делегата.
    ///
    /// Вызывается по завершении жеста без инерции, децелерации и программной
    /// анимации — вне горячего пути скролла (§4, §6).
    private func finishTransition() {
        guard !sections.isEmpty else { return }

        if scrollView.bounds.width > 0 {
            applyProgress(notifyDelegate: false)
            refreshLoadedSections(around: currentSectionIndex)
        }

        reportCurrentSectionIfNeeded()
        applyDeferredLayoutIfNeeded()
    }

    /// Сообщает делегату о смене секции и озвучивает её название (§7).
    private func reportCurrentSectionIfNeeded() {
        guard sections.indices.contains(currentSectionIndex) else { return }
        guard lastShownSectionIndex != currentSectionIndex else { return }

        lastShownSectionIndex = currentSectionIndex
        announceSection(at: currentSectionIndex)
        delegate?.panorama(self, didShowSectionAt: currentSectionIndex)
    }

    /// Озвучивает название секции при смене (§7, «VoiceOver»).
    ///
    /// Вызывается по завершении перехода: во время анимации анонс перебивается
    /// сменой accessibility-фокуса (см. ``TesseraAccessibility/announcePageChange(_:)``).
    /// Пустой заголовок не озвучивается.
    ///
    /// - Parameter index: Индекс показанной секции в порядке чтения.
    private func announceSection(at index: Int) {
        guard sections.indices.contains(index) else { return }

        let title = sections[index].title
        guard !title.isEmpty else { return }

        TesseraAccessibility.announcePageChange(title)
    }

    /// Досрочно применяет отложенный из-за скролла layout (§8).
    ///
    /// Отложенный проход уже «потратил» флаг `needsLayout` вида, поэтому
    /// одного `layoutIfNeeded()` мало — без `setNeedsLayout()` он ничего не
    /// делает, и новая геометрия (поворот во время свайпа) не применилась бы до
    /// случайного следующего прохода (E10.13).
    private func applyDeferredLayoutIfNeeded() {
        guard needsDeferredLayout, !scrollView.isUserScrollInFlight else { return }

        needsDeferredLayout = false
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    /// Зажимает индекс в границы набора секций.
    private func clampedSectionIndex(_ index: Int) -> Int {
        guard !sections.isEmpty else { return 0 }
        return min(max(index, 0), sections.count - 1)
    }

    // MARK: - Арбитраж вертикального скролла (§5, вариант B)

    /// Подписывается на состояния пана панорамы, не заменяя его делегата.
    ///
    /// `addTarget` аддитивен и не ломает внутреннюю обработку `UIScrollView`, в
    /// отличие от подмены `panGestureRecognizer.delegate` (почему она опасна —
    /// см. ``registerVerticalOwner(_:)``).
    private func observeScrollPan() {
        let pan = scrollView.panGestureRecognizer
        guard observedPan !== pan else { return }

        observedPan?.removeTarget(self, action: #selector(scrollPanDidChange(_:)))
        pan.addTarget(self, action: #selector(scrollPanDidChange(_:)))
        observedPan = pan
    }

    /// Состояния пана панорамы: блокировка и разблокировка вертикальных детей.
    ///
    /// - Parameter pan: Пан ``PanoScrollView``.
    @objc private func scrollPanDidChange(_ pan: UIPanGestureRecognizer) {
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

    /// Начинает горизонтальный жест: собирает арбитр и блокирует детей.
    ///
    /// Ось определяется по первому доступному вектору пана (при нулевой скорости —
    /// по смещению: для сравнения модулей масштаб не важен). Если жест
    /// вертикальный, пейджер его не ведёт, а прокрутка детей не блокируется —
    /// иначе выключение скролла остановило бы начавшуюся вертикальную прокрутку
    /// секции (§5).
    ///
    /// - Parameter pan: Пан, перешедший в состояние `.began`.
    private func beginHorizontalScroll(with pan: UIPanGestureRecognizer) {
        let velocity = pan.velocity(in: pan.view)
        let vector = velocity == .zero ? pan.translation(in: pan.view) : velocity
        guard TesseraGestureArbiter.axisDecision(forVelocity: vector) == .horizontal else {
            endHorizontalScroll()
            return
        }

        // Защита от наложения жестов: незавершённый арбитр сначала возвращает
        // детям исходное состояние, иначе снимок `isScrollEnabled` потеряется.
        if gestureArbiter != nil {
            endHorizontalScroll()
        }

        pruneVerticalOwners()
        let owners = liveVerticalOwners
        guard !owners.isEmpty else { return }

        let arbiter = TesseraGestureArbiter(horizontalOwner: scrollView, verticalOwners: owners)
        arbiter.prepareForHorizontalScroll()
        gestureArbiter = arbiter
    }

    /// Завершает горизонтальный жест: возвращает детям исходную прокрутку.
    ///
    /// После этого арбитр освобождается: сильных ссылок на скролл-вью секций между
    /// жестами контроллер не держит, выгруженные секции (§6) не живут в арбитре.
    private func endHorizontalScroll() {
        gestureArbiter?.endHorizontalScroll()
        gestureArbiter = nil
        pruneVerticalOwners()
    }

    /// Живые зарегистрированные владельцы (без самого панорамного скролла).
    private var liveVerticalOwners: [UIScrollView] {
        verticalOwners
            .compactMap(\.scrollView)
            .filter { $0 !== scrollView }
    }

    /// Убирает из реестра освобождённые скролл-вью (§6: секции живут окном ±1).
    private func pruneVerticalOwners() {
        verticalOwners.removeAll { $0.scrollView == nil }
    }

    // MARK: - Уведомления

    /// Сменился размер текста Dynamic Type — нужна новая раскладка заголовков
    /// (§7). Сами шрифты обновляет ``PanoHeaderView``.
    @objc private func contentSizeCategoryDidChange() {
        guard isViewLoaded else { return }
        view.setNeedsLayout()
    }
}

// MARK: - PanoScrollViewObserving (§4, §6, §7)

extension PanoramaViewController: PanoScrollViewObserving {

    /// Горячий путь прокрутки: только `transform`/`alpha` и колбэк делегата (§4).
    ///
    /// - Parameter scrollView: Источник события.
    func panoScrollViewDidScroll(_ scrollView: PanoScrollView) {
        // Запись геометрии в layout-проходе — не прогресс: итог применит сам
        // проход (E10.13).
        guard !isRestoringGeometry else { return }
        applyProgress(notifyDelegate: true)
    }

    /// Жест закончился: цель снапа известна — догружаем соседа до инерции (§6).
    ///
    /// - Parameters:
    ///   - scrollView: Источник события.
    ///   - velocityX: Скорость жеста (не используется: решает политика снапа).
    ///   - targetReadingIndex: Целевая секция в порядке чтения.
    func panoScrollViewWillEndDragging(
        _ scrollView: PanoScrollView,
        velocityX: CGFloat,
        targetReadingIndex: Int
    ) {
        prefetchSections(around: targetReadingIndex)
    }

    /// Жест завершён без инерции: доводка снапа (E9.2б) либо завершение сразу.
    ///
    /// При нулевой скорости UIKit не начинает инерцию и игнорирует изменённый
    /// в `scrollViewWillEndDragging` `targetContentOffset` — offset остался бы
    /// между снап-точками. Контроллер — программный писатель `contentOffset`
    /// (§2, «Один писатель») — сам доводит его до цели политики анимацией и
    /// завершает переход в `scrollViewDidEndScrollingAnimation`. При Reduce
    /// Motion доводка мгновенная (§7).
    ///
    /// - Parameters:
    ///   - scrollView: Источник события.
    ///   - decelerate: Начнётся ли инерция.
    func panoScrollViewDidEndDragging(
        _ scrollView: PanoScrollView,
        willDecelerate decelerate: Bool
    ) {
        let snapTarget = scrollView.consumePendingSnapOffsetX()
        guard !decelerate else { return }

        if let alignedX = scrollView.alignedSnapOffsetX(preferred: snapTarget),
           abs(scrollView.contentOffset.x - alignedX) > Metrics.alignmentTolerance {
            let target = CGPoint(x: alignedX, y: scrollView.contentOffset.y)
            if TesseraAccessibility.isReduceMotionEnabled {
                scrollView.setContentOffset(target, animated: false)
            } else {
                // Переход завершит `panoScrollViewDidEndScrollingAnimation`.
                scrollView.setContentOffset(target, animated: true)
                return
            }
        }
        finishTransition()
    }

    /// Инерция закончилась: фиксируем показанную секцию.
    ///
    /// - Parameter scrollView: Источник события.
    func panoScrollViewDidEndDecelerating(_ scrollView: PanoScrollView) {
        finishTransition()
    }

    /// Программная анимация завершилась: фиксируем показанную секцию.
    ///
    /// - Parameter scrollView: Источник события.
    func panoScrollViewDidEndScrollingAnimation(_ scrollView: PanoScrollView) {
        finishTransition()
    }

    /// Жест VoiceOver «три пальца» из скролл-вью (§7).
    ///
    /// - Parameters:
    ///   - scrollView: Источник события.
    ///   - step: Шаг по секциям в порядке чтения (уже с учётом RTL).
    /// - Returns: `true`, если переход выполнен.
    func panoScrollView(_ scrollView: PanoScrollView, accessibilityStep step: Int) -> Bool {
        // Индекс берём из фактического offset'а, а не из кеша: жест мог прийти
        // до завершения предыдущего перехода.
        applyProgress(notifyDelegate: false)
        return handleAccessibilityStep(step)
    }

    /// Выполняет шаг VoiceOver по секциям (§7).
    ///
    /// `contentOffset` пишет только контроллер — через
    /// ``selectSection(at:animated:)`` (§2, «Один писатель»).
    ///
    /// - Parameter step: `+1` — следующая секция, `-1` — предыдущая.
    /// - Returns: `true`, если переход выполнен.
    private func handleAccessibilityStep(_ step: Int) -> Bool {
        guard step != 0, sections.count > 1 else { return false }

        let targetIndex = currentSectionIndex + step
        guard sections.indices.contains(targetIndex) else { return false }

        selectSection(at: targetIndex, animated: !TesseraAccessibility.isReduceMotionEnabled)
        return true
    }
}

/// Корневой вид панорамы: смена `semanticContentAttribute` на лету помечает
/// layout, чтобы `layoutPanorama()` перенёс направление на слои и переложил
/// слоты, сохранив текущую секцию (§7, «RTL»; E10.13).
private final class PanoramaRootView: UIView {
    override var semanticContentAttribute: UISemanticContentAttribute {
        didSet {
            if oldValue != semanticContentAttribute {
                setNeedsLayout()
            }
        }
    }
}
#endif
