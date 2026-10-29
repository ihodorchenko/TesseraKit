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
//   go(toPage:animated:); делегат и подписчики только читают (§2 «Один писатель»);
// - в scrollViewDidScroll нет layout: только чтение offset и колбэк делегата
//   (§2 «Дисциплина производительности»); фреймы страниц и contentSize
//   раскладываются в viewDidLayoutSubviews.

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
    private var currentPageIndex = 0

    /// Последняя страница, о которой сообщили делегату.
    private var lastShownPageIndex: Int?

    /// Ширина, при которой раскладка была выполнена в прошлый раз.
    private var lastLayoutWidth: CGFloat = 0

    /// Направление чтения, для которого рассчитаны физические слоты страниц.
    private var lastLayoutDirection: UIUserInterfaceLayoutDirection?

    /// Нужно ли восстановить offset текущей страницы на ближайшем layout'е
    /// (первый layout, `reload(pages:)`, смена ширины или направления).
    private var needsOffsetRestore = true

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
        let rootView = UIView()
        rootView.backgroundColor = .clear
        rootView.addSubview(scrollView)
        view = rootView
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPager()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Показ мог состояться без layout (например, нулевой размер при
        // добавлении в контейнер) — синхронизируем индекс и окно страниц.
        updateCurrentPageIndexFromOffset()
        if scrollView.bounds.width > 0 {
            refreshLoadedPages(around: currentPageIndex)
        }
    }

    // MARK: - Публичный API

    /// Пересобирает пейджер под новый набор страниц.
    ///
    /// Текущая страница сохраняется по `id`, если он есть в новом наборе; иначе
    /// сохраняется прежний индекс с зажимом в новые границы. Загруженные
    /// контроллеры освобождаются, `contentSize` и фреймы пересчитываются в
    /// `viewDidLayoutSubviews` (единственное место layout'а).
    ///
    /// - Parameter pages: Новые страницы в порядке чтения.
    public func reload(pages: [TesseraPageDescriptor]) {
        let previousIndex = clampedPageIndex(currentPageIndex)
        let previousID: AnyHashable? = pages.indices.contains(previousIndex)
            ? pages[previousIndex].id
            : nil

        // Останавливаем инерцию/анимацию до удаления страниц: offset пишет
        // только контроллер, поэтому делаем это явно.
        if isViewLoaded {
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        }

        for controller in loadedControllers.values {
            detach(controller)
        }
        loadedControllers.removeAll()
        contentHosting.removeAll()

        self.pages = pages

        if pages.isEmpty {
            currentPageIndex = 0
            lastShownPageIndex = nil
            needsOffsetRestore = true
            if isViewLoaded {
                view.setNeedsLayout()
                view.layoutIfNeeded()
            }
            return
        }

        if let previousID, let preservedIndex = pages.firstIndex(where: { $0.id == previousID }) {
            currentPageIndex = preservedIndex
        } else {
            currentPageIndex = min(max(previousIndex, 0), pages.count - 1)
        }

        lastShownPageIndex = nil
        needsOffsetRestore = true

        // Пересобираем окно страниц сразу, не дожидаясь следующего прохода
        // run loop: reload — синхронная операция, а layout остаётся в
        // viewDidLayoutSubviews.
        if isViewLoaded {
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
    }

    /// Переходит к странице по индексу в порядке чтения.
    ///
    /// Программный переход — второй разрешённый писатель `contentOffset`
    /// (§2 «Один писатель»). При `animated == true` делегат продолжает получать
    /// `didChangeProgress` на кадрах анимации, а `didShowPageAt` — по её
    /// завершении. Индекс зажимается в `0...pages.count - 1`.
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
        currentPageIndex = targetIndex
        needsOffsetRestore = false

        let targetOffset = CGPoint(
            x: CGFloat(rawSlot(forReadingIndex: targetIndex)) * pageWidth,
            y: 0
        )
        scrollView.setContentOffset(targetOffset, animated: animated)

        if !animated {
            finishTransition()
        }
    }

    // MARK: - UIScrollViewDelegate

    /// Прогресс прокрутки.
    ///
    /// Здесь нет layout'а (docs/Core-iOS-Design.md §2, «Дисциплина
    /// производительности»): только чтение offset'а, обновление индекса и
    /// колбэк делегата. `t` нормализуется по направлению чтения через
    /// `TesseraRTL` (§2 «Инвариант прогресса»).
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView, !pages.isEmpty else { return }

        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return }

        let rawProgress = scrollView.contentOffset.x / pageWidth
        guard rawProgress.isFinite else { return }

        // Ближайшая страница: нужна для восстановления индекса при повороте.
        currentPageIndex = readingPageIndex(forRawProgress: rawProgress, rounded: true)

        let progress = TesseraRTL.normalizedProgress(
            rawProgress,
            pageCount: pages.count,
            layoutDirection: effectiveLayoutDirection
        )
        guard progress.isFinite else { return }

        delegate?.pager(self, didChangeProgress: progress)
    }

    /// Кастомный снап режима `.snapping` (docs/Core-iOS-Design.md §2).
    ///
    /// Расчёт полностью делегируется ``TesseraSnapPolicy``; пейджер только
    /// подставляет фактическую ширину страницы и скорость жеста. В режиме
    /// `.paged` снап выполняет `isPagingEnabled`.
    public func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard scrollView === self.scrollView, mode == .snapping, !pages.isEmpty else {
            return
        }

        let itemWidth = scrollView.bounds.width
        guard itemWidth > 0 else { return }

        targetContentOffset.pointee.x = snapPolicy.targetContentOffset(
            proposedOffset: targetContentOffset.pointee.x,
            velocity: velocity.x,
            itemWidth: itemWidth,
            pageCount: pages.count
        )
    }

    /// Конец жеста без инерции: переход считается завершённым сразу.
    public func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        guard scrollView === self.scrollView, !decelerate else { return }
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
        scrollView.frame = view.bounds

        let pageWidth = scrollView.bounds.width
        let pageHeight = scrollView.bounds.height
        let direction = effectiveLayoutDirection

        guard !pages.isEmpty else {
            scrollView.contentSize = .zero
            lastLayoutWidth = pageWidth
            lastLayoutDirection = direction
            return
        }

        guard pageWidth > 0 else { return }

        // Индекс до пересчёта contentSize: изменение contentSize может
        // подвинуть offset и обновить currentPageIndex в scrollViewDidScroll.
        let preservedIndex = clampedPageIndex(currentPageIndex)

        scrollView.contentSize = CGSize(
            width: pageWidth * CGFloat(pages.count),
            height: pageHeight
        )

        let widthChanged = lastLayoutWidth > 0 && abs(pageWidth - lastLayoutWidth) > .ulpOfOne
        let directionChanged = lastLayoutDirection != nil && lastLayoutDirection != direction

        if needsOffsetRestore || widthChanged || directionChanged {
            currentPageIndex = preservedIndex
            let slot = rawSlot(forReadingIndex: preservedIndex)
            scrollView.contentOffset = CGPoint(x: CGFloat(slot) * pageWidth, y: 0)
            needsOffsetRestore = false
        } else {
            clampContentOffsetIfNeeded(pageWidth: pageWidth)
        }

        lastLayoutWidth = pageWidth
        lastLayoutDirection = direction

        refreshLoadedPages(around: currentPageIndex)
        layoutPageFrames(pageWidth: pageWidth, pageHeight: pageHeight)
    }

    /// Зажимает offset в допустимые границы после изменения числа страниц.
    private func clampContentOffsetIfNeeded(pageWidth: CGFloat) {
        let maximumOffset = max(0, pageWidth * CGFloat(pages.count) - pageWidth)
        let clampedX = min(max(scrollView.contentOffset.x, 0), maximumOffset)
        guard clampedX != scrollView.contentOffset.x else { return }

        scrollView.contentOffset = CGPoint(x: clampedX, y: 0)
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

    // MARK: - Ленивая загрузка child-VC

    /// Держит в памяти текущую страницу и соседей ±1.
    ///
    /// Вызывается после завершения перехода и из layout'а, но никогда из
    /// `scrollViewDidScroll`: добавление child-VC — это изменение иерархии,
    /// а не работа для кадра прокрутки (§2).
    private func refreshLoadedPages(around index: Int) {
        guard !pages.isEmpty else { return }

        let center = clampedPageIndex(index)
        let desired = Set(
            [center - 1, center, center + 1].filter { pages.indices.contains($0) }
        )

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

    /// Фиксирует текущую страницу, обновляет окно ±1 и уведомляет делегата.
    private func finishTransition() {
        guard !pages.isEmpty else { return }

        updateCurrentPageIndexFromOffset()
        if scrollView.bounds.width > 0 {
            refreshLoadedPages(around: currentPageIndex)
            view.setNeedsLayout()
        }
        reportCurrentPageIfNeeded()
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

    /// Физический слот страницы в координатах контента.
    ///
    /// В LTR страницы лежат в порядке чтения слева направо. В RTL первая
    /// страница чтения — самая правая: слот зеркалится
    /// (`pageCount - 1 - index`), а прогресс и индекс нормализует `TesseraRTL`
    /// (docs/Core-iOS-Design.md §2, «Инвариант прогресса»).
    private func rawSlot(forReadingIndex index: Int) -> Int {
        guard !pages.isEmpty else { return 0 }

        let clampedIndex = clampedPageIndex(index)
        guard effectiveLayoutDirection == .rightToLeft else { return clampedIndex }
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
            layoutDirection: effectiveLayoutDirection
        )
    }

    /// Зажимает индекс в границы набора страниц.
    private func clampedPageIndex(_ index: Int) -> Int {
        guard !pages.isEmpty else { return 0 }
        return min(max(index, 0), pages.count - 1)
    }
}
#endif
