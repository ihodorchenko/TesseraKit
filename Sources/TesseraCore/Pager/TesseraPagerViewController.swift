// TesseraPagerViewController — горизонтальный пейджер TesseraCore.
// Проектный документ: docs/Core-iOS-Design.md — §2 «Ключевые контракты»
// (инвариант t, один писатель contentOffset, два режима пейджера, дисциплина
// производительности) и §3 «Концептуальная поверхность API».
//
// Схема:
// - одна горизонтальная UIScrollView, страницы — полноширинные фреймы;
// - t = contentOffset.x / pageWidth, наружу отдаётся нормализованным по
//   направлению чтения через TesseraRTL (§2 «Инвариант прогресса»);
// - contentOffset пишут только жест UIScrollView и программный
//   go(toPage:animated:) (а также доводка снапа и восстановление геометрии
//   самим пейджером); делегат и подписчики только читают (§2 «Один писатель»);
// - в scrollViewDidScroll нет layout: только чтение offset и колбэк делегата
//   (§2 «Дисциплина производительности»); фреймы страниц и contentSize
//   раскладываются в viewDidLayoutSubviews;
// - appearance-коллбэки страниц пересылаются вручную: appear получает только
//   текущая (видимая) страница, соседи ±1 держатся в памяти «за кадром».

#if canImport(UIKit)
import UIKit

/// Режим работы пейджера (docs/Core-iOS-Design.md §2, «Два режима пейджера»).
public enum TesseraPagerMode {
    /// Полноширинные страницы, снап средствами `UIScrollView.isPagingEnabled`.
    case paged

    /// Шаг снапа задаётся ``TesseraSnapPolicy``: `decelerationRate = .fast`
    /// и расчёт целевого offset'а в `scrollViewWillEndDragging`.
    case snapping
}

/// Горизонтальный пейджер с child-VC контейнерами и ленивой загрузкой ±1.
///
/// Контракты (docs/Core-iOS-Design.md §2):
/// - прогресс `t = contentOffset.x / pageWidth`, в RTL нормализуется по
///   направлению чтения через `TesseraRTL`;
/// - `contentOffset` пишут только жест и ``go(toPage:animated:)``;
/// - режимы `.paged` и `.snapping`;
/// - в `scrollViewDidScroll` нет layout — только колбэки.
///
/// В памяти находится текущая страница и её соседи (±1). Контроллеры страниц
/// создаются через `TesseraContentHosting` и подключаются как child-VC
/// (`addChild` / `didMove(toParent:)`).
///
/// Appearance-коллбэки (`viewWillAppear` / `viewDidAppear` / …) страницы
/// получают по видимости: appear — только текущая страница при показе пейджера
/// и при смене текущей страницы по завершении перехода; соседи ±1, загруженные
/// «за кадром», коллбэков не получают.
///
/// - Important: Работает только на главном потоке. Делегат не удерживается.
public final class TesseraPagerViewController: UIViewController, UIScrollViewDelegate {

    // MARK: - Публичная конфигурация

    /// Режим пейджера, заданный при создании. Не меняется на лету: смена режима
    /// — это другой экземпляр контроллера.
    public let mode: TesseraPagerMode

    /// Политика снапа для режима `.snapping`.
    ///
    /// В режиме `.paged` не используется. Изменение политики не выполняет
    /// layout и вступает в силу со следующего жеста прокрутки.
    public var snapPolicy: TesseraSnapPolicy

    /// Наблюдатель смены страницы и прогресса.
    ///
    /// Не удерживается пейджером (§2: делегат только читает состояние).
    public weak var delegate: TesseraPagerDelegate?

    // MARK: - Геометрия и состояние

    /// Единственный скролл-вью пейджера: и жест, и программный переход идут
    /// через него (§2 «Один писатель»).
    private let scrollView = UIScrollView()

    /// Реестр переиспользования контроллеров контента (E1.5).
    private let contentHosting = TesseraContentHosting()

    /// Страницы в порядке чтения.
    private var pages: [TesseraPageDescriptor] = []

    /// Загруженные контроллеры по индексу в порядке чтения (текущая и соседи ±1).
    private var loadedControllers: [Int: UIViewController] = [:]

    /// Текущая (ближайшая) страница в порядке чтения.
    ///
    /// Чтение открыто внутри модуля (для контрактных тестов); пишет только пейджер.
    private(set) var currentPageIndex = 0

    /// Последняя страница, о которой сообщили делегату.
    private var lastShownPageIndex: Int?

    /// Ширина, при которой раскладка была выполнена в прошлый раз.
    private var lastLayoutWidth: CGFloat = 0

    /// Направление чтения, для которого рассчитаны физические слоты страниц.
    ///
    /// Текущий `contentOffset` интерпретируется именно в нём, а не в «живом»
    /// `effectiveUserInterfaceLayoutDirection`: после смены направления на лету
    /// и до ближайшего layout'а offset всё ещё стоит в старых слотах (E10.10).
    private var lastLayoutDirection: UIUserInterfaceLayoutDirection?

    /// Нужно ли восстановить offset текущей страницы на ближайшем layout'е
    /// (первый layout, `reload(pages:)`, смена ширины или направления).
    private var needsOffsetRestore = true

    /// Идёт запись геометрии в `layoutPager()`: промежуточные `scrollViewDidScroll`
    /// (зажатие offset'а UIKit'ом при смене frame/contentSize) не должны сбивать
    /// индекс и доходить до делегата.
    private var isApplyingLayout = false

    /// Идёт программная анимация offset'а пейджера (`go(toPage:animated:)` или
    /// доводка снапа); завершается в `scrollViewDidEndScrollingAnimation`.
    private var isAnimatingTransition = false

    /// `contentOffset.x` на начале жеста — опора шага ±1 снапа (E10.11).
    private var dragStartOffsetX: CGFloat?

    /// Цель снапа, рассчитанная в `scrollViewWillEndDragging` (режим `.snapping`).
    ///
    /// Нужна для доводки, когда жест кончился без инерции: UIKit игнорирует
    /// изменённый `targetContentOffset` при нулевой скорости (E9.2а).
    private var pendingSnapOffsetX: CGFloat?

    /// Состояние appearance самого пейджера (ручная пересылка детям).
    private var appearanceState: AppearanceState = .disappeared

    /// Страница, которой переслан appear (начатый или завершённый).
    private weak var appearanceController: UIViewController?

    // MARK: - Инициализация

    /// Создаёт пейджер.
    ///
    /// - Parameters:
    ///   - mode: Режим `.paged` или `.snapping`.
    ///   - pages: Страницы в порядке чтения. Можно передать пустой массив
    ///     и заполнить пейджер через ``reload(pages:)``.
    ///   - snapPolicy: Политика снапа для режима `.snapping`.
    public init(
        mode: TesseraPagerMode = .paged,
        pages: [TesseraPageDescriptor] = [],
        snapPolicy: TesseraSnapPolicy = TesseraSnapPolicy()
    ) {
        self.mode = mode
        self.pages = pages
        self.snapPolicy = snapPolicy
        super.init(nibName: nil, bundle: nil)
        configureScrollView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Жизненный цикл

    public override func loadView() {
        let rootView = PagerRootView()
        rootView.backgroundColor = .clear
        rootView.addSubview(scrollView)
        view = rootView
    }

    /// Appearance детям пересылается вручную — по видимости, а не по факту
    /// нахождения в иерархии (соседи ±1 лежат в скролл-вью за кадром).
    public override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPager()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        // Смена направления окружения: слоты перераскладываются в layoutPager().
        if previousTraitCollection?.layoutDirection != traitCollection.layoutDirection {
            view.setNeedsLayout()
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        appearanceState = .appearing
        syncPageAppearance(animated: animated)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Показ мог состояться без layout (например, нулевой размер при
        // добавлении в контейнер) — синхронизируем индекс и окно страниц.
        updateCurrentPageIndexFromOffset()
        if scrollView.bounds.width > 0 {
            refreshLoadedPages(around: currentPageIndex)
        }

        // viewDidAppear без viewWillAppear UIKit не присылает, но страхуемся:
        // appear текущей страницы должен быть начат до завершения.
        appearanceState = .appearing
        syncPageAppearance(animated: animated)
        appearanceController?.endAppearanceTransition()
        appearanceState = .appeared
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        appearanceState = .disappearing
        appearanceController?.beginAppearanceTransition(false, animated: animated)
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        appearanceController?.endAppearanceTransition()
        appearanceController = nil
        appearanceState = .disappeared
    }

    // MARK: - Публичный API

    /// Пересобирает пейджер под новый набор страниц.
    ///
    /// Текущая страница сохраняется по `id`, если он есть в новом наборе; иначе
    /// сохраняется прежний индекс с зажимом в новые границы. Контроллеры
    /// страниц, чей `id` сохранился и попадает в новое окно ±1, переиспользуются
    /// (тот же экземпляр; SwiftUI-контент обновляется на месте); выгружаются
    /// только исчезнувшие и вышедшие из окна. `contentSize` и фреймы
    /// пересчитываются в `viewDidLayoutSubviews` (единственное место layout'а).
    ///
    /// - Parameter newPages: Новые страницы в порядке чтения.
    public func reload(pages newPages: [TesseraPageDescriptor]) {
        // Текущий id — из СТАРОГО набора: по нему страница ищется в новом.
        let oldPages = pages
        let previousIndex = clampedPageIndex(currentPageIndex)
        let previousID: AnyHashable? = oldPages.indices.contains(previousIndex)
            ? oldPages[previousIndex].id
            : nil

        // Останавливаем инерцию/анимацию до удаления страниц: offset пишет
        // только контроллер, поэтому делаем это явно.
        if isViewLoaded {
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        }
        isAnimatingTransition = false
        dragStartOffsetX = nil
        pendingSnapOffsetX = nil

        // Загруженные контроллеры — по id старого набора.
        var survivors: [(id: AnyHashable, controller: UIViewController)] = []
        for (index, controller) in loadedControllers.sorted(by: { $0.key < $1.key }) {
            if oldPages.indices.contains(index) {
                survivors.append((oldPages[index].id, controller))
            } else {
                detach(controller)
            }
        }
        loadedControllers.removeAll()

        pages = newPages

        if newPages.isEmpty {
            for survivor in survivors {
                detach(survivor.controller)
            }
            contentHosting.removeAll()
            currentPageIndex = 0
            lastShownPageIndex = nil
            needsOffsetRestore = true
            if isViewLoaded {
                view.setNeedsLayout()
                view.layoutIfNeeded()
            }
            return
        }

        if let previousID, let preservedIndex = newPages.firstIndex(where: { $0.id == previousID }) {
            currentPageIndex = preservedIndex
        } else {
            currentPageIndex = min(max(previousIndex, 0), newPages.count - 1)
        }

        // Переиспользуем выживших в новом окне ±1; остальных выгружаем.
        let window = pageWindow(around: currentPageIndex)
        for survivor in survivors {
            if let newIndex = newPages.firstIndex(where: { $0.id == survivor.id }),
               window.contains(newIndex),
               loadedControllers[newIndex] == nil {
                loadedControllers[newIndex] = survivor.controller
                // Тот же экземпляр из реестра; SwiftUI-поставщик обновляет rootView.
                _ = contentHosting.viewController(
                    for: survivor.id,
                    provider: newPages[newIndex].content
                )
            } else {
                detach(survivor.controller)
                contentHosting.removeContent(for: survivor.id)
            }
        }

        lastShownPageIndex = nil
        needsOffsetRestore = true

        // Пересобираем окно страниц сразу, не дожидаясь следующего прохода
        // run loop: reload — синхронная операция, а layout остаётся в
        // viewDidLayoutSubviews.
        if isViewLoaded {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            syncPageAppearance(animated: false)
        }
    }

    /// Переходит к странице по индексу в порядке чтения.
    ///
    /// Программный переход — второй разрешённый писатель `contentOffset`
    /// (§2 «Один писатель»). При `animated == true` делегат продолжает получать
    /// `didChangeProgress` на кадрах анимации, а `didShowPageAt` — по её
    /// завершении. Индекс зажимается в `0...pages.count - 1`.
    ///
    /// Анимированный переход дальше соседней страницы — «прямой прыжок» без
    /// пролёта промежуточных (docs/PIVOT-IOS-DESIGN.md §1 п.4): offset без
    /// анимации переставляется на соседа целевой страницы со стороны текущей,
    /// окно ±1 загружается вокруг цели, и анимируется один последний шаг.
    /// Делегат получает один `didChangeProgress` со скачком на соседа цели
    /// (прогресс всегда отражает фактический offset), затем кадры анимации;
    /// `didShowPageAt` — только для цели.
    ///
    /// - Parameters:
    ///   - index: Индекс в порядке чтения (в RTL — не физический слот).
    ///   - animated: Анимировать переход средствами `UIScrollView`.
    public func go(toPage index: Int, animated: Bool) {
        guard !pages.isEmpty else { return }

        // До загрузки вида запоминаем намерение: первый layout поставит offset
        // на нужную страницу без промежуточного скачка.
        guard isViewLoaded else {
            currentPageIndex = clampedPageIndex(index)
            needsOffsetRestore = true
            return
        }

        // Сначала доводим геометрию до актуальной: contentSize и фреймы
        // раскладываются в viewDidLayoutSubviews, а не в этом методе (§2).
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else {
            currentPageIndex = clampedPageIndex(index)
            needsOffsetRestore = true
            view.setNeedsLayout()
            return
        }

        let targetIndex = clampedPageIndex(index)
        let targetOffset = contentOffset(forReadingIndex: targetIndex, pageWidth: pageWidth)
        needsOffsetRestore = false
        pendingSnapOffsetX = nil

        guard animated, abs(scrollView.contentOffset.x - targetOffset.x) > Self.alignmentTolerance else {
            // Без анимации — или анимировать нечего: UIKit не присылает
            // scrollViewDidEndScrollingAnimation для нулевого пути.
            isAnimatingTransition = false
            currentPageIndex = targetIndex
            scrollView.setContentOffset(targetOffset, animated: false)
            finishTransition()
            return
        }

        updateCurrentPageIndexFromOffset()
        let distance = targetIndex - currentPageIndex
        if abs(distance) > 1 {
            // Прямой прыжок: без анимации — на соседа цели со стороны текущей.
            let neighbourIndex = targetIndex - distance.signum()
            scrollView.setContentOffset(
                contentOffset(forReadingIndex: neighbourIndex, pageWidth: pageWidth),
                animated: false
            )
            refreshLoadedPages(around: targetIndex)
        }

        currentPageIndex = targetIndex
        isAnimatingTransition = true
        scrollView.setContentOffset(targetOffset, animated: true)
    }

    // MARK: - UIScrollViewDelegate

    /// Прогресс прокрутки.
    ///
    /// Здесь нет layout'а (docs/Core-iOS-Design.md §2, «Дисциплина
    /// производительности»): только чтение offset'а, обновление индекса и
    /// колбэк делегата. `t` нормализуется по направлению чтения через
    /// `TesseraRTL` (§2 «Инвариант прогресса»).
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView, !isApplyingLayout else { return }
        reportProgress()
    }

    /// Начало жеста: запоминаем стартовый offset для снапа и снимаем флаг
    /// программной анимации (жест её перехватывает, UIKit не присылает
    /// `didEndScrollingAnimation`).
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }
        dragStartOffsetX = scrollView.contentOffset.x
        pendingSnapOffsetX = nil
        isAnimatingTransition = false
    }

    /// Кастомный снап режима `.snapping` (docs/Core-iOS-Design.md §2).
    ///
    /// Расчёт полностью делегируется ``TesseraSnapPolicy``; пейджер только
    /// подставляет фактическую ширину страницы, скорость жеста и стартовый
    /// offset. UIKit отдаёт `velocity` в points/ms, политика ждёт pt/s —
    /// перевод `× 1000` здесь (E10.11). В режиме `.paged` снап выполняет
    /// `isPagingEnabled`.
    public func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard scrollView === self.scrollView else { return }

        let startOffsetX = dragStartOffsetX
        dragStartOffsetX = nil

        guard mode == .snapping, !pages.isEmpty else { return }

        let itemWidth = scrollView.bounds.width
        guard itemWidth > 0 else { return }

        let target = snapPolicy.targetContentOffset(
            proposedOffset: targetContentOffset.pointee.x,
            velocity: velocity.x * Self.millisecondsPerSecond,
            itemWidth: itemWidth,
            pageCount: pages.count,
            startOffset: startOffsetX
        )
        targetContentOffset.pointee.x = target
        pendingSnapOffsetX = target
    }

    /// Конец жеста без инерции: переход считается завершённым сразу.
    ///
    /// В режиме `.snapping` при нулевой скорости UIKit не двигает offset к
    /// цели снапа (E9.2а): пейджер — единственный писатель — сам доводит его
    /// анимацией до ближайшей страницы, а переход завершается в
    /// `scrollViewDidEndScrollingAnimation`.
    public func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        guard scrollView === self.scrollView else { return }

        let snapOffsetX = pendingSnapOffsetX
        pendingSnapOffsetX = nil
        guard !decelerate else { return }

        if mode == .snapping, let alignedOffset = alignedSnapOffset(preferred: snapOffsetX),
           abs(scrollView.contentOffset.x - alignedOffset) > Self.alignmentTolerance {
            isAnimatingTransition = true
            scrollView.setContentOffset(CGPoint(x: alignedOffset, y: 0), animated: true)
            return
        }

        finishTransition()
    }

    /// Завершение инерции: фиксируем показанную страницу.
    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }
        finishTransition()
    }

    /// Завершение программной анимации `setContentOffset(_:animated:)`.
    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView else { return }
        finishTransition()
    }

    // MARK: - Accessibility

    /// Пагинация жестом VoiceOver «три пальца».
    ///
    /// Направление превращается в шаг по страницам в порядке чтения через
    /// `TesseraAccessibility.pageStep`; сам переход выполняет `go(toPage:)`,
    /// поэтому `contentOffset` по-прежнему пишет только контроллер (§2).
    /// Reduce Motion отключает анимацию перехода.
    public override func accessibilityScroll(
        _ direction: UIAccessibilityScrollDirection
    ) -> Bool {
        guard isViewLoaded, !pages.isEmpty else { return false }

        updateCurrentPageIndexFromOffset()
        let step = TesseraAccessibility.pageStep(
            for: direction,
            layoutDirection: effectiveLayoutDirection
        )
        guard step != 0 else { return false }

        let targetIndex = currentPageIndex + step
        guard pages.indices.contains(targetIndex) else { return false }

        go(toPage: targetIndex, animated: !TesseraAccessibility.isReduceMotionEnabled)
        return true
    }

    // MARK: - Конфигурация

    /// UIKit отдаёт скорость жеста в points/ms; политика снапа — в pt/s.
    private static let millisecondsPerSecond: CGFloat = 1000

    /// Допуск «offset уже выровнен», в points.
    private static let alignmentTolerance: CGFloat = 0.5

    private func configureScrollView() {
        scrollView.isPagingEnabled = mode == .paged
        scrollView.decelerationRate = mode == .snapping ? .fast : .normal
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.backgroundColor = .clear
        scrollView.delegate = self
    }

    // MARK: - Layout (единственное место раскладки страниц)

    /// Раскладывает скролл-вью, страницы и `contentSize`.
    ///
    /// Вызывается только из `viewDidLayoutSubviews` (и синхронных
    /// `layoutIfNeeded` из публичных методов). В `scrollViewDidScroll` layout'а
    /// нет (§2 «Дисциплина производительности»).
    private func layoutPager() {
        // Индекс — ДО любых записей геометрии: смена frame (поворот) и
        // contentSize может зажать offset UIKit'ом и сбить текущую страницу.
        let preservedIndex = clampedPageIndex(currentPageIndex)
        let direction = effectiveLayoutDirection

        isApplyingLayout = true
        scrollView.frame = view.bounds

        let pageWidth = scrollView.bounds.width
        let pageHeight = scrollView.bounds.height

        guard !pages.isEmpty else {
            scrollView.contentSize = .zero
            isApplyingLayout = false
            lastLayoutWidth = pageWidth
            lastLayoutDirection = direction
            return
        }

        guard pageWidth > 0 else {
            isApplyingLayout = false
            return
        }

        let widthChanged = lastLayoutWidth > 0 && abs(pageWidth - lastLayoutWidth) > .ulpOfOne
        let directionChanged = lastLayoutDirection != nil && lastLayoutDirection != direction

        // Слоты отныне считаются в актуальном направлении.
        lastLayoutWidth = pageWidth
        lastLayoutDirection = direction

        scrollView.contentSize = CGSize(
            width: pageWidth * CGFloat(pages.count),
            height: pageHeight
        )

        let restoresOffset = needsOffsetRestore || widthChanged || directionChanged
        var clampedOffset = false
        if restoresOffset {
            currentPageIndex = preservedIndex
            scrollView.contentOffset = contentOffset(
                forReadingIndex: preservedIndex,
                pageWidth: pageWidth
            )
            needsOffsetRestore = false
        } else {
            clampedOffset = clampContentOffsetIfNeeded(pageWidth: pageWidth)
        }
        isApplyingLayout = false

        if restoresOffset || clampedOffset {
            // Подписчики получают итоговый прогресс один раз — без
            // промежуточных значений зажатия.
            reportProgress()
            if restoresOffset {
                currentPageIndex = preservedIndex
            }
        }

        refreshLoadedPages(around: currentPageIndex)
        layoutPageFrames(pageWidth: pageWidth, pageHeight: pageHeight)

        if !isScrollInFlight {
            syncPageAppearance(animated: false)
        }
    }

    /// Зажимает offset в допустимые границы после изменения числа страниц.
    ///
    /// - Returns: `true`, если offset изменился.
    private func clampContentOffsetIfNeeded(pageWidth: CGFloat) -> Bool {
        let maximumOffset = max(0, pageWidth * CGFloat(pages.count) - pageWidth)
        let clampedX = min(max(scrollView.contentOffset.x, 0), maximumOffset)
        guard clampedX != scrollView.contentOffset.x else { return false }

        scrollView.contentOffset = CGPoint(x: clampedX, y: 0)
        return true
    }

    /// Раскладывает фреймы всех загруженных страниц.
    private func layoutPageFrames(pageWidth: CGFloat, pageHeight: CGFloat) {
        for (index, controller) in loadedControllers {
            controller.view.frame = pageRect(
                forReadingIndex: index,
                pageWidth: pageWidth,
                pageHeight: pageHeight
            )
        }
    }

    /// Фрейм страницы: полноширинный, в физическом слоте, соответствующем
    /// индексу в порядке чтения.
    private func pageRect(
        forReadingIndex index: Int,
        pageWidth: CGFloat,
        pageHeight: CGFloat
    ) -> CGRect {
        let slot = rawSlot(forReadingIndex: index)
        return CGRect(
            x: CGFloat(slot) * pageWidth,
            y: 0,
            width: pageWidth,
            height: pageHeight
        )
    }

    /// Offset выравнивания страницы в порядке чтения.
    private func contentOffset(forReadingIndex index: Int, pageWidth: CGFloat) -> CGPoint {
        CGPoint(x: CGFloat(rawSlot(forReadingIndex: index)) * pageWidth, y: 0)
    }

    /// Выровненный offset для доводки снапа после жеста без инерции.
    ///
    /// Берётся цель, рассчитанная политикой в `scrollViewWillEndDragging`;
    /// если её нет — ближайшая страница к текущему offset'у.
    private func alignedSnapOffset(preferred: CGFloat?) -> CGFloat? {
        guard !pages.isEmpty else { return nil }
        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return nil }

        if let preferred, preferred.isFinite {
            return preferred
        }
        return snapPolicy.targetContentOffset(
            proposedOffset: scrollView.contentOffset.x,
            velocity: 0,
            itemWidth: pageWidth,
            pageCount: pages.count
        )
    }

    // MARK: - Ленивая загрузка child-VC

    /// Индексы окна ±1 вокруг страницы.
    private func pageWindow(around index: Int) -> Set<Int> {
        guard !pages.isEmpty else { return [] }
        let center = clampedPageIndex(index)
        return Set([center - 1, center, center + 1].filter { pages.indices.contains($0) })
    }

    /// Держит в памяти текущую страницу и соседей ±1.
    ///
    /// Вызывается после завершения перехода и из layout'а, но никогда из
    /// `scrollViewDidScroll`: добавление child-VC — это изменение иерархии,
    /// а не работа для кадра прокрутки (§2).
    private func refreshLoadedPages(around index: Int) {
        guard !pages.isEmpty else { return }

        let desired = pageWindow(around: index)

        for loadedIndex in Array(loadedControllers.keys) where !desired.contains(loadedIndex) {
            guard let controller = loadedControllers.removeValue(forKey: loadedIndex) else {
                continue
            }
            detach(controller)
            if pages.indices.contains(loadedIndex) {
                contentHosting.removeContent(for: pages[loadedIndex].id)
            }
        }

        for pageIndex in desired.sorted() where loadedControllers[pageIndex] == nil {
            loadPage(at: pageIndex)
        }
    }

    /// Создаёт контроллер страницы и подключает его как child-VC.
    ///
    /// Appearance-коллбэков страница здесь не получает: пересылку по видимости
    /// выполняет `syncPageAppearance(animated:)`.
    private func loadPage(at index: Int) {
        guard pages.indices.contains(index) else { return }

        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return }

        let descriptor = pages[index]
        var controller = contentHosting.viewController(
            for: descriptor.id,
            provider: descriptor.content
        )

        // Защита от повторяющегося id: один контроллер нельзя добавить дважды.
        // Для валидных наборов страниц (уникальные id) ветка не выполняется.
        if loadedControllers.values.contains(where: { $0 === controller }) {
            controller = descriptor.content.makeContentViewController()
        }

        addChild(controller)
        controller.view.frame = pageRect(
            forReadingIndex: index,
            pageWidth: pageWidth,
            pageHeight: scrollView.bounds.height
        )
        scrollView.addSubview(controller.view)
        controller.didMove(toParent: self)
        loadedControllers[index] = controller
    }

    /// Отсоединяет child-VC от пейджера.
    ///
    /// Если странице был переслан appear, перед удалением она получает
    /// сбалансированный disappear.
    private func detach(_ controller: UIViewController) {
        if controller === appearanceController {
            switch appearanceState {
            case .appearing, .appeared:
                controller.beginAppearanceTransition(false, animated: false)
                controller.endAppearanceTransition()
            case .disappearing:
                controller.endAppearanceTransition()
            case .disappeared:
                break
            }
            appearanceController = nil
        }

        guard controller.parent != nil else {
            controller.view.removeFromSuperview()
            return
        }

        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    // MARK: - Appearance по видимости

    /// Состояние appearance пейджера.
    private enum AppearanceState {
        case disappeared
        case appearing
        case appeared
        case disappearing
    }

    /// Идёт ли сейчас движение offset'а (жест, инерция, программная анимация).
    private var isScrollInFlight: Bool {
        scrollView.isDragging || scrollView.isDecelerating || isAnimatingTransition
    }

    /// Пересылает appear текущей странице, disappear — прежней.
    ///
    /// - `.appearing`: текущей странице начинается appear (завершит его
    ///   `viewDidAppear` пейджера); если appear уже был начат другой странице,
    ///   он отменяется сбалансированным disappear.
    /// - `.appeared`: при смене текущей страницы прежняя получает полный
    ///   disappear, новая — полный appear.
    /// - Скрытый или скрывающийся пейджер коллбэков не пересылает.
    private func syncPageAppearance(animated: Bool) {
        guard appearanceState == .appearing || appearanceState == .appeared else { return }

        let current = loadedControllers[clampedPageIndex(currentPageIndex)]
        guard current !== appearanceController else { return }

        if let previous = appearanceController {
            previous.beginAppearanceTransition(false, animated: animated)
            previous.endAppearanceTransition()
            appearanceController = nil
        }

        guard let current else { return }
        current.beginAppearanceTransition(true, animated: animated)
        if appearanceState == .appeared {
            current.endAppearanceTransition()
        }
        appearanceController = current
    }

    // MARK: - Завершение перехода

    /// Фиксирует текущую страницу, обновляет окно ±1 и уведомляет делегата.
    private func finishTransition() {
        isAnimatingTransition = false
        guard !pages.isEmpty else { return }

        updateCurrentPageIndexFromOffset()
        if scrollView.bounds.width > 0 {
            refreshLoadedPages(around: currentPageIndex)
            view.setNeedsLayout()
        }
        syncPageAppearance(animated: false)
        reportCurrentPageIfNeeded()
    }

    /// Обновляет индекс по offset'у и сообщает прогресс делегату.
    private func reportProgress() {
        guard !pages.isEmpty else { return }

        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return }

        let rawProgress = scrollView.contentOffset.x / pageWidth
        guard rawProgress.isFinite else { return }

        // Ближайшая страница: нужна для восстановления индекса при повороте.
        currentPageIndex = readingPageIndex(forRawProgress: rawProgress, rounded: true)

        let progress = TesseraRTL.normalizedProgress(
            rawProgress,
            pageCount: pages.count,
            layoutDirection: slotLayoutDirection
        )
        guard progress.isFinite else { return }

        delegate?.pager(self, didChangeProgress: progress)
    }

    private func updateCurrentPageIndexFromOffset() {
        guard !pages.isEmpty else {
            currentPageIndex = 0
            return
        }

        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return }

        let rawProgress = scrollView.contentOffset.x / pageWidth
        guard rawProgress.isFinite else { return }

        currentPageIndex = readingPageIndex(forRawProgress: rawProgress, rounded: true)
    }

    private func reportCurrentPageIfNeeded() {
        guard !pages.isEmpty else { return }
        guard let delegate else { return }

        let index = clampedPageIndex(currentPageIndex)
        guard lastShownPageIndex != index else { return }

        lastShownPageIndex = index
        delegate.pager(self, didShowPageAt: index)
    }

    // MARK: - RTL и координаты

    /// Направление чтения текущего вида.
    private var effectiveLayoutDirection: UIUserInterfaceLayoutDirection {
        if isViewLoaded {
            return view.effectiveUserInterfaceLayoutDirection
        }

        // Запасной путь до загрузки вида: текущий trait-контекст.
        switch UITraitCollection.current.layoutDirection {
        case .rightToLeft:
            return .rightToLeft
        case .leftToRight:
            return .leftToRight
        case .unspecified:
            return .leftToRight
        @unknown default:
            return .leftToRight
        }
    }

    /// Направление, в котором сейчас разложены слоты (и стоит offset).
    ///
    /// До первого layout'а — живое направление вида.
    private var slotLayoutDirection: UIUserInterfaceLayoutDirection {
        lastLayoutDirection ?? effectiveLayoutDirection
    }

    /// Физический слот страницы в координатах контента.
    ///
    /// В LTR страницы лежат в порядке чтения слева направо. В RTL первая
    /// страница чтения — самая правая: слот зеркалится
    /// (`pageCount - 1 - index`), а прогресс и индекс нормализует `TesseraRTL`
    /// (docs/Core-iOS-Design.md §2, «Инвариант прогресса»).
    private func rawSlot(forReadingIndex index: Int) -> Int {
        guard !pages.isEmpty else { return 0 }

        let clampedIndex = clampedPageIndex(index)
        guard slotLayoutDirection == .rightToLeft else { return clampedIndex }
        return pages.count - 1 - clampedIndex
    }

    /// Индекс страницы в порядке чтения по сырому прогрессу.
    ///
    /// - Parameters:
    ///   - rawProgress: `contentOffset.x / pageWidth`.
    ///   - rounded: `true` — ближайшая страница, `false` — целая часть
    ///     (правило «целая часть — индекс», §2).
    private func readingPageIndex(forRawProgress rawProgress: CGFloat, rounded: Bool) -> Int {
        guard !pages.isEmpty else { return 0 }

        let position = rounded ? rawProgress.rounded() : rawProgress.rounded(.down)
        let clampedRawIndex = min(max(position, 0), CGFloat(pages.count - 1))

        return TesseraRTL.pageIndex(
            for: clampedRawIndex,
            pageCount: pages.count,
            layoutDirection: slotLayoutDirection
        )
    }

    /// Зажимает индекс в границы набора страниц.
    private func clampedPageIndex(_ index: Int) -> Int {
        guard !pages.isEmpty else { return 0 }
        return min(max(index, 0), pages.count - 1)
    }
}

/// Корневой вид пейджера: смена `semanticContentAttribute` на лету помечает
/// layout, чтобы `layoutPager()` перераскладывал слоты под новое направление.
private final class PagerRootView: UIView {
    override var semanticContentAttribute: UISemanticContentAttribute {
        didSet {
            if oldValue != semanticContentAttribute {
                setNeedsLayout()
            }
        }
    }
}
#endif
