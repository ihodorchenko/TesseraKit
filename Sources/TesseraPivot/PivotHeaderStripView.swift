//
//  PivotHeaderStripView.swift
//  TesseraPivot
//
//  Лента заголовков пивота: горизонтальный UICollectionView + отдельный индикатор.
//  Контракт: docs/PIVOT-IOS-DESIGN.md §3 «Архитектура» (PivotHeaderStripView —
//  «UICollectionView заголовков + индикатор», режим ленты по ширине контента или
//  равные ширины), §4 «Математика ядра» (индикатор интерполируется между
//  центрами заголовков; окраска — по расстоянию от `t`; автоцентрирование —
//  только если лента переполнена), §5 «Синхронизация ленты и пейджера» (один
//  источник истины и один писатель contentOffset), §7 «Производительность»
//  (переиспользование ячеек; в горячем пути только frame/transform/alpha, без
//  reloadData и layout), §8 «Accessibility» (Dynamic Type, RTL, VoiceOver).
//  Задача плана: E2.2.
//
//  Дисциплина производительности (§4, §7): `apply(progress:)` и
//  `scrollViewDidScroll` ленты меняют только `transform` индикатора и
//  цвет/шрифт/alpha уже видимых ячеек. `reloadData`, `invalidateLayout`,
//  измерение текста и пересборка геометрии выполняются только в layout-проходе
//  и в сеттерах конфигурации — никогда в горячем пути свайпа.
//

#if canImport(UIKit)
import UIKit
import TesseraCore

/// Горизонтальная лента заголовков секций с непрерывным индикатором.
///
/// Синхронизация односторонняя (§5): контроллер в `scrollViewDidScroll` пейджера
/// вызывает ``apply(progress:)``, лента двигает индикатор и перекрашивает
/// заголовки. Обратной записи нет — лента никогда не трогает `contentOffset`
/// пейджера; тап лишь сообщает о намерении через ``onSelect``, а переход
/// выполняет контроллер (единственный писатель, §5).
///
/// ## Порядок использования
///
/// ```swift
/// let strip = PivotHeaderStripView()
/// strip.titles = sections.map(\.title)
/// strip.mode = style.stripMode
/// strip.titleFont = style.titleFont
/// strip.titleTextStyle = style.titleTextStyle
/// strip.activeColor = style.activeColor
/// strip.inactiveColor = style.inactiveColor
/// strip.showsIndicator = style.indicatorStyle != .accentText
/// strip.onSelect = { index in pivot.select(index: index) }
/// // в scrollViewDidScroll пейджера, на каждом кадре:
/// strip.apply(progress: t)
/// ```
///
/// ## Режимы ширины (§3)
///
/// - ``PivotStyle/StripMode/content`` — ячейка по ширине текста; лента
///   скроллится, если не помещается;
/// - ``PivotStyle/StripMode/fill`` — равные ширины: заголовки делят ширину
///   ленты поровну, лента не скроллится.
///
/// Режим — это запрос вызывающего; лента вправе отступить от `.fill` на крупном
/// Dynamic Type и на слишком узких ячейках (см. документацию ``mode``), потому
/// что усечённые до нечитаемого заголовки-кнопки нарушают §8.
///
/// ## RTL (§8)
///
/// Порядок заголовков задаёт раскладка ленты: в RTL секция `0` оказывается
/// справа. Индикатор работает в координатах контента и берёт центры из
/// фактических атрибутов раскладки, поэтому `t` в порядке чтения указывает на
/// визуально правильный заголовок независимо от того, как UIKit реализует
/// зеркалирование. Точка контента переводится в координаты ленты через
/// `convert(_:to:)` — без ручной арифметики на `contentOffset`.
///
/// ## Accessibility
///
/// - заголовки — кнопки VoiceOver (`.button`, у активного — `.selected`, §8);
/// - шрифт масштабируется по ``titleFont``/``titleTextStyle`` и пересобирается
///   при смене категории Dynamic Type;
/// - в горячем пути не создаётся и не измеряется ни одного шрифта: активный и
///   неактивный шрифты кешируются на layout-проход.
///
/// Все методы — главный поток: UIKit-вью не рассчитана на фоновые вызовы
/// (docs/CORE-IOS-DESIGN.md §3, «вся работа на главном потоке UI»).
public final class PivotHeaderStripView: UIView {

    // MARK: - Данные

    /// Заголовки секций в порядке чтения: индекс `0` — первая секция для
    /// пользователя независимо от LTR/RTL (§8).
    ///
    /// Установка перезагружает ячейки (`reloadData`), поэтому в горячем пути
    /// свайпа менять нельзя. Прогресс зажимается в новый диапазон индексов:
    /// после смены набора лента не «зависает» за последним заголовком.
    public var titles: [String] = [] {
        didSet {
            guard titles != oldValue else { return }
            reloadHeaders()
        }
    }

    /// Режим ширины заголовков (§3).
    ///
    /// Стиль (``PivotStyle``) хранит запрос пользователя, а лента применяет его
    /// с поправкой на §8:
    /// - на accessibility-размерах `.fill` уступает `.content`, если равная
    ///   ширина меньше ширины самого длинного заголовка — текст не усекается до
    ///   нечитаемого;
    /// - `.fill` уступает `.content` и тогда, когда равная ширина меньше
    ///   ``minimumItemWidth``: заголовок перестаёт быть пригодной для тапа
    ///   кнопкой.
    ///
    /// На обычных размерах `.fill` усекает длинные заголовки хвостом
    /// (`.byTruncatingTail`) — это осознанный компромисс режима «равные ширины».
    public var mode: PivotStyle.StripMode = .content {
        didSet {
            guard mode != oldValue else { return }
            invalidateHeaderGeometry(reloadData: false)
        }
    }

    /// Ближайшая к последнему применённому прогрессу секция.
    ///
    /// Обновляется в ``apply(progress:)``: на середине свайпа «активной» уже
    /// считается следующая секция. Используется для жирности активного
    /// заголовка и для accessibility-признака `.selected` (§8).
    public private(set) var selectedIndex: Int = 0

    /// Тап по заголовку: индекс в порядке чтения (§8, RTL).
    ///
    /// Лента не меняет выделение и не двигает пейджер сама (§5: один писатель
    /// `contentOffset`). Контроллер в обработчике выполняет программный переход,
    /// а выделение вернётся вместе со следующим `apply(progress:)`.
    public var onSelect: ((Int) -> Void)?

    // MARK: - Внешний вид (§3: шрифты/цвета настраиваемые)

    /// Акцентный цвет: цвет активного заголовка и подчёркивания.
    ///
    /// Промежуточные оттенки неактивных соседей получаются непрерывной
    /// интерполяцией от ``inactiveColor`` к этому цвету по расстоянию от `t`
    /// (§4, «Окраска текста»). По умолчанию `.systemBlue` — дефолт
    /// ``PivotStyle/activeColor``.
    public var activeColor: UIColor = .systemBlue {
        didSet {
            guard activeColor != oldValue else { return }
            indicator.activeColor = activeColor
            applyHighlightToVisibleHeaders()
        }
    }

    /// Цвет неактивного заголовка (§4). По умолчанию `.systemGray` — дефолт
    /// ``PivotStyle/inactiveColor``.
    public var inactiveColor: UIColor = .systemGray {
        didSet {
            guard inactiveColor != oldValue else { return }
            applyHighlightToVisibleHeaders()
        }
    }

    /// Базовый (немасштабированный) шрифт заголовков (§8, «Dynamic Type»).
    ///
    /// Компонент сам масштабирует его через `UIFontMetrics(forTextStyle:)` с
    /// ``titleTextStyle`` и пересобирает при смене категории размера текста.
    /// Передавать уже масштабированный шрифт нельзя — он будет масштабирован
    /// повторно; передавайте базовый размер. По умолчанию — системный semibold
    /// 17 pt, как у ``PivotStyle/titleFont``.
    public var titleFont: UIFont = .systemFont(ofSize: 17, weight: .semibold) {
        didSet {
            guard titleFont != oldValue else { return }
            invalidateHeaderGeometry(reloadData: true)
        }
    }

    /// Текстовый стиль, метрики которого масштабируют ``titleFont`` (§8).
    /// По умолчанию `.headline` — как у ``PivotStyle/titleTextStyle``.
    public var titleTextStyle: UIFont.TextStyle = .headline {
        didSet {
            guard titleTextStyle != oldValue else { return }
            invalidateHeaderGeometry(reloadData: true)
        }
    }

    /// Жирность активного заголовка (§3: «жирность активного»).
    ///
    /// Неактивные заголовки показываются ``titleFont`` как есть, активный — тот
    /// же шрифт с этой жирностью. По умолчанию `.semibold`: совпадает с
    /// дефолтным ``PivotStyle/titleFont``, поэтому «из коробки» акцент передаётся
    /// цветом, а не скачком ширины текста. Классический WP-контраст получается,
    /// если задать ``titleFont`` без жирности (`.regular`) — тогда активный
    /// заголовок станет semibold.
    public var activeFontWeight: UIFont.Weight = .semibold {
        didSet {
            guard activeFontWeight != oldValue else { return }
            invalidateHeaderGeometry(reloadData: true)
        }
    }

    /// Радиус «передачи акцента» в единицах прогресса (§4).
    ///
    /// `1` (по умолчанию) — заголовок на полпути между секциями уже полностью
    /// неактивен; большее значение подсвечивает и дальних соседей. Отрицательные
    /// и нулевые значения трактуются как «без размывания» (см.
    /// ``PivotHeaderIndicator/blendFactor(distanceFromProgress:span:)``).
    public var highlightSpan: CGFloat = 1 {
        didSet {
            guard highlightSpan != oldValue else { return }
            applyHighlightToVisibleHeaders()
        }
    }

    /// Показывать подчёркивание под активным заголовком.
    ///
    /// Для `PivotStyle.IndicatorStyle.accentText` контроллер выставляет `false`
    /// (§3: вид индикатора — только акцентный текст). Непрерывная окраска
    /// заголовков от флага не зависит — она работает всегда (§4).
    public var showsIndicator: Bool = true {
        didSet {
            guard showsIndicator != oldValue else { return }
            updateIndicatorPosition()
        }
    }

    /// Горизонтальные отступы ленты: слева/справа от крайних заголовков в режиме
    /// `.content` (§3). В `.fill` ячейки делят ширину ленты, поэтому внешние
    /// отступы не применяются.
    public var horizontalInset: CGFloat = 16 {
        didSet {
            guard horizontalInset != oldValue else { return }
            invalidateHeaderGeometry(reloadData: false)
        }
    }

    /// Промежуток между заголовками в точках (§3). В `.fill` он вычитается из
    /// доступной ширины до деления на число заголовков.
    public var interItemSpacing: CGFloat = 20 {
        didSet {
            guard interItemSpacing != oldValue else { return }
            invalidateHeaderGeometry(reloadData: false)
        }
    }

    /// Горизонтальный отступ текста внутри ячейки: ширина ячейки в `.content`
    /// равна ширине текста плюс два таких отступа.
    public var horizontalTextPadding: CGFloat = 8 {
        didSet {
            guard horizontalTextPadding != oldValue else { return }
            invalidateHeaderGeometry(reloadData: false)
        }
    }

    /// Минимальная ширина ячейки заголовка: тапабельная цель и нижняя граница
    /// применимости режима `.fill` (§8).
    public var minimumItemWidth: CGFloat = 44 {
        didSet {
            guard minimumItemWidth != oldValue else { return }
            invalidateHeaderGeometry(reloadData: false)
        }
    }

    // MARK: - Состояние

    private let headerLayout: UICollectionViewFlowLayout
    private let collectionView: UICollectionView

    /// Индикатор ленты.
    ///
    /// Доступен на уровне модуля (`@testable`), чтобы контрактные тесты E2.7
    /// могли проверить, что в горячем пути меняется только `transform`;
    /// в публичную поверхность не входит — геометрией владеет лента.
    internal private(set) var indicator: PivotHeaderIndicator

    /// Последний применённый прогресс. Хранится, чтобы перекрашивать заново
    /// появляющиеся ячейки и повторять положение индикатора при собственной
    /// прокрутке ленты без обращения к пейджеру.
    ///
    /// Чтение открыто на уровне модуля (`@testable`) — контрактным тестам
    /// синхронизации; пишет только сама лента.
    private(set) var lastProgress: CGFloat = 0

    /// Сколько раз лента запускала анимированную доцентровку (`scrollToItem`
    /// с анимацией).
    ///
    /// Только для контрактных тестов модуля (`@testable`): анимация прокрутки
    /// в тестовом окружении без сцены не исполняется, и по `contentOffset`
    /// анимированную доцентровку не отличить от мгновенной (E9.6).
    private(set) var animatedCenteringCount = 0

    /// Кеш ширин ячеек и центров в координатах контента. Считается только в
    /// layout-проходе (§4, §7).
    private var requiredWidthsCache: [CGFloat] = []
    private var contentCenters: [CGFloat] = []
    private var contentWidth: CGFloat = 0
    private var isGeometryValid = false
    private var lastLayoutSize: CGSize = .zero

    /// Направление раскладки коллекции, для которого посчитана геометрия.
    ///
    /// Центры заголовков зависят от направления (в RTL раскладка зеркалит
    /// ячейки), а размер ленты при смене направления не меняется — поэтому
    /// одной проверки размера в `layoutSubviews` мало (E9.6).
    private var lastLayoutDirection: UIUserInterfaceLayoutDirection?

    /// Нужно ли после ближайшего layout'а вернуть выделенный заголовок в
    /// видимую область: поворот/смена ширины или направления раскладки
    /// сдвигают ячейки относительно сохранённого `contentOffset` (§9, E9.6).
    private var needsSelectionVisibilityRestore = false

    /// Кеш шрифтов: активный/неактивный шрифт пересобирается только при смене
    /// Dynamic Type или настроек шрифта, а не на каждом кадре свайпа (§7).
    private var activeFontCache: UIFont?
    private var inactiveFontCache: UIFont?

    // MARK: - Инициализация

    /// Создаёт ленту с пустым набором заголовков.
    ///
    /// - Parameter frame: Начальный кадр; обычно ленту раскладывает контроллер.
    public override init(frame: CGRect) {
        headerLayout = PivotHeaderFlowLayout()
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: headerLayout)
        indicator = PivotHeaderIndicator()
        super.init(frame: frame)
        commonInit()
    }

    /// Создаёт ленту из архива/сториборда.
    ///
    /// - Parameter coder: Декодер архива.
    public required init?(coder: NSCoder) {
        headerLayout = PivotHeaderFlowLayout()
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: headerLayout)
        indicator = PivotHeaderIndicator()
        super.init(coder: coder)
        commonInit()
    }

    /// Общая настройка: коллекция заголовков и отдельный слой индикатора (§3, §7).
    ///
    /// Индикатор добавлен после коллекции, поэтому всегда выше ячеек; событий он
    /// не ловит и потому тапы по заголовкам не перекрывает.
    private func commonInit() {
        backgroundColor = .clear
        clipsToBounds = true

        headerLayout.scrollDirection = .horizontal
        headerLayout.minimumInteritemSpacing = 0
        headerLayout.estimatedItemSize = .zero
        // §8, RTL: порядок ячеек — это порядок секций в модели, а визуальное
        // направление задаёт раскладка по `semanticContentAttribute` окружения.
        // Геометрия индикатора читает фактические атрибуты, поэтому зеркалирование
        // отдельной веткой не дублируется.
        headerLayout.sectionInset = UIEdgeInsets(
            top: 0,
            left: max(horizontalInset, 0),
            bottom: 0,
            right: max(horizontalInset, 0)
        )
        headerLayout.minimumLineSpacing = max(interItemSpacing, 0)

        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset = .zero
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            PivotHeaderCell.self,
            forCellWithReuseIdentifier: PivotHeaderCell.reuseIdentifier
        )

        indicator.activeColor = activeColor
        indicator.isHidden = true

        addSubview(collectionView)
        addSubview(indicator)

        // §8, Dynamic Type: пересчитать шрифты и ширины при смене категории.
        // Уведомление приходит на главном потоке после обновления traits.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
    }

    // MARK: - Публичный API синхронизации (§5)

    /// Применяет прогресс пейджера: двигает индикатор и перекрашивает заголовки.
    ///
    /// Единственная точка входа из `scrollViewDidScroll` пейджера (§5). Внутри —
    /// только `transform` индикатора и цвет/шрифт/alpha уже видимых ячеек: ни
    /// `reloadData`, ни `layoutIfNeeded`, ни `invalidateLayout`, ни измерения
    /// текста (§4, §7). Если лента ещё не разложена, вызов безопасен: прогресс
    /// запоминается и применится в ближайшем layout-проходе.
    ///
    /// - Parameter t: Нормализованный по направлению чтения прогресс
    ///   `contentOffset.x / pageWidth` (§4, ``TesseraRTL/normalizedProgress(_:pageCount:layoutDirection:)``).
    ///   Значения за пределами диапазона допустимы: индикатор зажимается
    ///   крайними центрами, «активный» заголовок — крайней секцией.
    public func apply(progress t: CGFloat) {
        lastProgress = t.isNaN ? 0 : t
        selectedIndex = nearestIndex(to: lastProgress)
        updateIndicatorPosition()
        applyHighlightToVisibleHeaders()
    }

    /// Устанавливает выделение по индексу без прокрутки ленты и без `onSelect`.
    ///
    /// Используется контроллером для начального состояния, восстановления после
    /// поворота и программных переходов: это ``apply(progress:)`` с целым `t`.
    /// Доцентрирование ленты — отдельный вызов
    /// ``scrollToCenter(index:animated:)`` (§4: лента доцентровывается по
    /// завершении перехода).
    ///
    /// - Parameter index: Индекс секции в порядке чтения; зажимается в диапазон
    ///   существующих заголовков. Пустая лента даёт ``selectedIndex`` `0`.
    public func select(index: Int) {
        guard !titles.isEmpty else {
            selectedIndex = 0
            return
        }

        apply(progress: CGFloat(min(max(index, 0), titles.count - 1)))
    }

    /// Доцентровывает ленту так, чтобы заголовок `index` оказался по центру.
    ///
    /// По §4 — только если лента переполнена **и заголовок за краем** (целиком
    /// или частично вне видимой области): видимый заголовок ленту не двигает,
    /// иначе она дёргалась бы на каждом переходе (E9.6). Позиция —
    /// `.centeredHorizontally`. Если лента не переполнена, а `contentOffset`
    /// остался ненулевым (например, после поворота в более широкую ориентацию),
    /// он возвращается к началу без анимации — все заголовки и так видны.
    ///
    /// `animated` — намерение вызывающего, но при Reduce Motion анимация
    /// отключается принудительно (§8: «прыжок по тапу — без анимации»):
    /// автоцентрирование — самодвижущаяся анимация, а не повтор жеста, в
    /// отличие от непрерывного индикатора.
    ///
    /// - Parameters:
    ///   - index: Индекс секции в порядке чтения; зажимается в диапазон.
    ///   - animated: Анимировать ли прокрутку ленты (с поправкой на Reduce Motion).
    public func scrollToCenter(index: Int, animated: Bool) {
        guard !titles.isEmpty else { return }

        rebuildGeometryIfNeeded()
        guard isOverflowing else {
            resetOffsetIfNotOverflowing()
            return
        }

        let clampedIndex = min(max(index, 0), titles.count - 1)
        let indexPath = IndexPath(item: clampedIndex, section: 0)
        guard isItemBeyondVisibleEdge(at: indexPath) else { return }

        let shouldAnimate = animated && !TesseraAccessibility.isReduceMotionEnabled
        if shouldAnimate {
            animatedCenteringCount += 1
        }
        collectionView.scrollToItem(
            at: indexPath,
            at: .centeredHorizontally,
            animated: shouldAnimate
        )
    }

    /// Заголовок целиком или частично вне видимой области ленты (§4).
    ///
    /// Сравнение — в координатах контента коллекции: и фрейм атрибутов, и
    /// `bounds` (видимый прямоугольник) живут в них, в том числе в RTL.
    /// Нет атрибутов — считаем «за краем», чтобы не потерять доцентровку.
    private func isItemBeyondVisibleEdge(at indexPath: IndexPath) -> Bool {
        guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else {
            return true
        }
        let visible = collectionView.bounds
        let tolerance: CGFloat = 0.5
        return frame.minX < visible.minX - tolerance || frame.maxX > visible.maxX + tolerance
    }

    /// Непереполненная лента не скроллится: остаточный `contentOffset`
    /// сбрасывается к началу без анимации.
    private func resetOffsetIfNotOverflowing() {
        let leading = CGPoint(x: -collectionView.adjustedContentInset.left, y: collectionView.contentOffset.y)
        guard abs(collectionView.contentOffset.x - leading.x) > 0.5 else { return }
        collectionView.setContentOffset(leading, animated: false)
    }

    // MARK: - Layout

    /// Раскладывает коллекцию, пересобирает геометрию ленты и ставит индикатор.
    ///
    /// Единственный layout-проход ленты: здесь допустимы измерение текста,
    /// `invalidateLayout` и `bounds`/`center` индикатора (§4, §7).
    ///
    /// Геометрия пересобирается при смене размера **и** направления раскладки
    /// (E9.6): в RTL раскладка зеркалит ячейки, а размер ленты при этом прежний.
    /// После поворота или смены направления выделенный заголовок возвращается в
    /// видимую область без анимации (§9 «лента пересоберётся сама»).
    public override func layoutSubviews() {
        super.layoutSubviews()

        let size = bounds.size
        if size != lastLayoutSize {
            // Первый layout с ненулевой шириной — не поворот: доцентровку при
            // первом показе выполняет контроллер.
            if lastLayoutSize.width > 0 {
                needsSelectionVisibilityRestore = true
            }
            lastLayoutSize = size
            isGeometryValid = false
            // Ширины ячеек зависят от ширины ленты, поэтому размеры делегата
            // нужно перезапросить, а не брать из кеша раскладки.
            collectionView.collectionViewLayout.invalidateLayout()
        }

        let direction = collectionView.effectiveUserInterfaceLayoutDirection
        if let lastLayoutDirection, lastLayoutDirection != direction {
            isGeometryValid = false
            needsSelectionVisibilityRestore = true
            collectionView.collectionViewLayout.invalidateLayout()
        }
        lastLayoutDirection = direction

        syncLayoutMetrics()
        collectionView.frame = bounds

        rebuildGeometryIfNeeded()
        indicator.placeBar(inStripBounds: bounds)

        if needsSelectionVisibilityRestore, bounds.width > 0 {
            needsSelectionVisibilityRestore = false
            scrollToCenter(index: selectedIndex, animated: false)
        }
        updateIndicatorPosition()
    }

    /// Смена `semanticContentAttribute` ленты на лету (E9.6).
    ///
    /// Коллекция — дочерний вид и семантику родителя не наследует (её
    /// `effectiveUserInterfaceLayoutDirection` берётся из trait-коллекции),
    /// поэтому атрибут переносится на неё явно, а геометрия помечается
    /// невалидной: иначе центры остались бы посчитанными для прежнего
    /// направления и индикатор стоял бы под чужим заголовком.
    public override var semanticContentAttribute: UISemanticContentAttribute {
        didSet {
            guard semanticContentAttribute != oldValue else { return }
            collectionView.semanticContentAttribute = semanticContentAttribute
            setNeedsLayout()
        }
    }

    /// Смена направления из окружения (trait `layoutDirection`) — та же
    /// инвалидация, что и при смене семантики (E9.6). Саму пересборку выполняет
    /// `layoutSubviews`, сверяя направление коллекции с запомненным.
    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.layoutDirection != traitCollection.layoutDirection {
            setNeedsLayout()
        }
    }

    /// Синхронизирует отступы раскладки с действующим режимом ширины (§3).
    ///
    /// В `.fill` внешние отступы ленты не применяются: ячейки делят всю ширину
    /// (плюс промежутки), иначе суммарная ширина перестала бы совпадать с
    /// шириной ленты и появился бы ложный скролл.
    private func syncLayoutMetrics() {
        let inset = effectiveHorizontalInset
        let spacing = effectiveItemSpacing
        guard headerLayout.sectionInset.left != inset
            || headerLayout.minimumLineSpacing != spacing
        else { return }

        headerLayout.sectionInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        headerLayout.minimumLineSpacing = spacing
        headerLayout.invalidateLayout()
    }

    // MARK: - Геометрия (только layout-проход)

    /// Пересобирает кеш геометрии, если он помечен невалидным.
    private func rebuildGeometryIfNeeded() {
        guard !isGeometryValid else { return }
        rebuildGeometry()
    }

    /// Считает центры заголовков в координатах контента (§4).
    ///
    /// Источник истины — фактические атрибуты раскладки: они уже учитывают
    /// направление чтения, отступы и промежутки, поэтому в RTL ничего не нужно
    /// зеркалить руками. Ручная геометрия (ширины + отступы + промежутки) —
    /// только запасной вариант для ячеек, которых раскладка ещё не отдала:
    /// нужный вариант (прямой или зеркальный) определяется сверкой с реальными
    /// атрибутами, а не догадкой о поведении UIKit в RTL (§8).
    private func rebuildGeometry() {
        guard !titles.isEmpty, bounds.width > 0 else {
            contentCenters = []
            contentWidth = 0
            isGeometryValid = true
            return
        }

        // Атрибуты существующих ячеек доступны только после подготовки
        // раскладки; принудительный проход здесь допустим — это layout, а не
        // горячий путь свайпа (§4, §7).
        collectionView.layoutIfNeeded()

        let inset = effectiveHorizontalInset
        let spacing = effectiveItemSpacing

        var widths: [CGFloat] = []
        widths.reserveCapacity(titles.count)
        for index in titles.indices {
            widths.append(itemWidth(at: index))
        }

        var directCenters: [CGFloat] = []
        directCenters.reserveCapacity(widths.count)
        var originX = inset
        for width in widths {
            directCenters.append(originX + width / 2)
            originX += width + spacing
        }
        let totalWidth = originX - spacing + inset
        let mirroredCenters = directCenters.map { totalWidth - $0 }

        var centers = shouldMirrorCenters(direct: directCenters, mirrored: mirroredCenters)
            ? mirroredCenters
            : directCenters

        // Точные позиции из раскладки: перекрывают расчётные там, где доступны.
        for item in titles.indices {
            let indexPath = IndexPath(item: item, section: 0)
            guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { continue }
            centers[item] = attributes.frame.midX
        }

        contentCenters = centers
        contentWidth = collectionView.contentSize.width
        isGeometryValid = true
    }

    /// Решает, зеркалит ли раскладка заголовки в текущем направлении (§8).
    ///
    /// Сверяет расчётные прямые и зеркальные центры с фактическими атрибутами:
    /// так решение не зависит от того, как именно UIKit реализует RTL
    /// (зеркалит ячейки или уводит `contentOffset` в минус). Если раскладка ещё
    /// не подготовлена, для RTL ожидается зеркалирование — это штатное поведение
    /// потоковой раскладки; выбор уточнится на следующем layout-проходе.
    private func shouldMirrorCenters(direct: [CGFloat], mirrored: [CGFloat]) -> Bool {
        guard isRightToLeft else { return false }

        var directError: CGFloat = 0
        var mirroredError: CGFloat = 0
        var comparedItems = 0

        for item in direct.indices {
            let indexPath = IndexPath(item: item, section: 0)
            guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { continue }

            let center = attributes.frame.midX
            directError += abs(center - direct[item])
            mirroredError += abs(center - mirrored[item])
            comparedItems += 1
        }

        guard comparedItems > 0 else { return true }
        return mirroredError < directError
    }

    /// Ширина ячейки заголовка для действующего режима (§3, §8).
    ///
    /// В `.content` ширина считается по самому широкому состоянию (активный
    /// шрифт): при смене жирности текст не прыгает и не обрезается.
    private func itemWidth(at index: Int) -> CGFloat {
        guard titles.indices.contains(index) else { return 0 }

        if effectiveMode == .fill {
            return fillItemWidth
        }

        rebuildRequiredWidthsIfNeeded()
        return requiredWidthsCache[index]
    }

    /// Ширина ячейки в режиме `.fill`: все заголовки делят ширину ленты поровну,
    /// промежутки вычитаются до деления (§3).
    private var fillItemWidth: CGFloat {
        let count = CGFloat(titles.count)
        guard count > 0 else { return 0 }

        let available = bounds.width - effectiveItemSpacing * (count - 1)
        // Не даём ширине схлопнуться в ноль: нулевая ячейка ломает раскладку,
        // а переполнение ленты обрабатывается как обычный скролл.
        return max(available / count, 1)
    }

    /// Ширины заголовков в режиме `.content` с учётом Dynamic Type.
    private func rebuildRequiredWidthsIfNeeded() {
        guard requiredWidthsCache.count != titles.count else { return }

        let activeFont = headerFont(isActive: true)
        let inactiveFont = headerFont(isActive: false)
        let textPadding = max(horizontalTextPadding, 0)
        let minimumWidth = max(minimumItemWidth, 1)

        requiredWidthsCache = titles.map { title in
            let textWidth = max(
                measuredTextWidth(title, font: activeFont),
                measuredTextWidth(title, font: inactiveFont)
            )
            return max(textWidth + textPadding * 2, minimumWidth)
        }
    }

    /// Ширина строки в шрифте с округлением вверх: дробные значения дали бы
    /// обрезанный хвост текста при усечении.
    private func measuredTextWidth(_ title: String, font: UIFont) -> CGFloat {
        (title as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    /// Действующий режим ширины: запрос вызывающего плюс поправки §8.
    private var effectiveMode: PivotStyle.StripMode {
        guard mode == .fill else { return .content }
        guard titles.count > 1, bounds.width > 0 else { return .fill }

        let fillWidth = fillItemWidth
        // Слишком тесные ячейки — не кнопки: отдаём ширину тексту и скролл.
        guard fillWidth >= max(minimumItemWidth, 1) else { return .content }

        // На обычных размерах усечение хвоста допустимо, на accessibility —
        // нет: текст заголовка не должен теряться (§8).
        guard isAccessibilityTextSize else { return .fill }

        rebuildRequiredWidthsIfNeeded()
        let widestTitleWidth = requiredWidthsCache.max() ?? 0
        return fillWidth >= widestTitleWidth ? .fill : .content
    }

    private var isAccessibilityTextSize: Bool {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    }

    private var effectiveHorizontalInset: CGFloat {
        effectiveMode == .fill ? 0 : max(horizontalInset, 0)
    }

    private var effectiveItemSpacing: CGFloat {
        titles.count > 1 ? max(interItemSpacing, 0) : 0
    }

    private var isOverflowing: Bool {
        isGeometryValid && contentWidth > bounds.width + 0.5
    }

    /// Направление, в котором раскладка фактически расставляет ячейки, — это
    /// направление коллекции, а не самой ленты (E9.6).
    private var isRightToLeft: Bool {
        collectionView.effectiveUserInterfaceLayoutDirection == .rightToLeft
    }

    // MARK: - Индикатор (§4, §7)

    /// Ставит индикатор на центр, соответствующий последнему прогрессу.
    ///
    /// Индикатор — отдельный слой поверх ленты (§7), поэтому точка контента
    /// переводится в координаты ленты через `convert(_:to:)`: это единственный
    /// способ не зависеть от того, как UIKit реализует RTL (сдвиг координат или
    /// отрицательный `contentOffset`). Меняется только `transform` (§4).
    private func updateIndicatorPosition() {
        guard isGeometryValid else { return }

        guard showsIndicator, !contentCenters.isEmpty, bounds.width > 0 else {
            indicator.isHidden = true
            return
        }

        if indicator.isHidden {
            indicator.isHidden = false
        }
        let contentCenter = PivotHeaderIndicator.indicatorCenter(
            centers: contentCenters,
            progress: lastProgress
        )
        let centerInStrip = collectionView.convert(CGPoint(x: contentCenter, y: 0), to: self)
        indicator.move(toCenterX: centerInStrip.x)
    }

    // MARK: - Шрифты (§8, Dynamic Type)

    /// Шрифт заголовка для активного/неактивного состояния.
    ///
    /// Базовый шрифт масштабируется метриками ``titleTextStyle``; активный
    /// дополнительно получает жирность ``activeFontWeight`` через дескриптор,
    /// чтобы сохранить семейство и размер. Результат кешируется: горячий путь
    /// свайпа не создаёт шрифтов (§7).
    private func headerFont(isActive: Bool) -> UIFont {
        if isActive, let cached = activeFontCache { return cached }
        if !isActive, let cached = inactiveFontCache { return cached }

        let metrics = UIFontMetrics(forTextStyle: titleTextStyle)
        let scaledFont = metrics.scaledFont(for: titleFont, compatibleWith: traitCollection)

        let font: UIFont
        if isActive {
            let descriptor = scaledFont.fontDescriptor.addingAttributes([
                UIFontDescriptor.AttributeName.traits: [
                    UIFontDescriptor.TraitKey.weight: activeFontWeight
                ]
            ])
            font = UIFont(descriptor: descriptor, size: scaledFont.pointSize)
        } else {
            font = scaledFont
        }

        if isActive {
            activeFontCache = font
        } else {
            inactiveFontCache = font
        }
        return font
    }

    // MARK: - Окраска (§4, «Окраска текста»)

    /// Перекрашивает видимые заголовки по их расстоянию от прогресса.
    ///
    /// Только уже существующие ячейки: `reloadData` и создание новых ячеек в
    /// горячем пути запрещены (§7). Новые ячейки получают состояние в
    /// `cellForItemAt`.
    private func applyHighlightToVisibleHeaders() {
        guard !titles.isEmpty else { return }

        let activeIndex = selectedIndex
        for cell in collectionView.visibleCells {
            guard
                let headerCell = cell as? PivotHeaderCell,
                let indexPath = collectionView.indexPath(for: cell)
            else { continue }
            configure(headerCell, at: indexPath.item, activeIndex: activeIndex)
        }
    }

    /// Применяет к ячейке состояние заголовка `index`.
    private func configure(_ cell: PivotHeaderCell, at index: Int, activeIndex: Int) {
        guard titles.indices.contains(index) else { return }

        let isActive = index == activeIndex
        let factor = PivotHeaderIndicator.blendFactor(
            distanceFromProgress: CGFloat(index) - lastProgress,
            span: highlightSpan
        )

        cell.apply(
            title: titles[index],
            font: headerFont(isActive: isActive),
            isActive: isActive,
            factor: factor,
            activeColor: activeColor,
            inactiveColor: inactiveColor
        )
    }

    // MARK: - Инвалидация конфигурации

    /// Сбрасывает кеши ширины/шрифтов и просит раскладку пересчитать ячейки.
    ///
    /// Вызывается из сеттеров конфигурации и из уведомления Dynamic Type, то
    /// есть вне горячего пути свайпа (§7).
    ///
    /// - Parameter reloadData: Нужно ли пересоздать ячейки. Шрифты и тексты
    ///   ячеек обновляются и без `reloadData`, поэтому перезагрузка нужна только
    ///   при смене шрифта/стиля, но не при смене режима или отступов.
    private func invalidateHeaderGeometry(reloadData: Bool) {
        requiredWidthsCache.removeAll(keepingCapacity: true)
        activeFontCache = nil
        inactiveFontCache = nil
        isGeometryValid = false

        collectionView.collectionViewLayout.invalidateLayout()
        if reloadData {
            collectionView.reloadData()
        }
        setNeedsLayout()
        applyHighlightToVisibleHeaders()
    }

    /// Перезагружает ленту после смены набора заголовков.
    ///
    /// Прогресс зажимается в новый диапазон: после удаления секций лента не
    /// должна указывать на несуществующий заголовок.
    private func reloadHeaders() {
        lastProgress = min(max(lastProgress, 0), CGFloat(max(titles.count - 1, 0)))
        selectedIndex = nearestIndex(to: lastProgress)

        requiredWidthsCache.removeAll(keepingCapacity: true)
        activeFontCache = nil
        inactiveFontCache = nil
        isGeometryValid = false

        collectionView.reloadData()
        collectionView.collectionViewLayout.invalidateLayout()
        setNeedsLayout()
    }

    /// Индекс ближайшей к прогрессу секции, зажатый в диапазон заголовков.
    private func nearestIndex(to progress: CGFloat) -> Int {
        guard !titles.isEmpty, !progress.isNaN else { return 0 }

        let lastIndex = CGFloat(titles.count - 1)
        let clampedProgress = min(max(progress, 0), lastIndex)
        return Int(clampedProgress.rounded())
    }

    // MARK: - Уведомления

    /// Смена категории Dynamic Type: шрифты и ширины пересчитываются (§8).
    @objc private func contentSizeCategoryDidChange() {
        invalidateHeaderGeometry(reloadData: true)
    }
}

// MARK: - UICollectionViewDataSource

extension PivotHeaderStripView: UICollectionViewDataSource {

    /// Число заголовков — по одному на секцию.
    public func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        titles.count
    }

    /// Ячейка заголовка с состоянием, соответствующим последнему прогрессу.
    public func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: PivotHeaderCell.reuseIdentifier,
            for: indexPath
        )
        if let headerCell = cell as? PivotHeaderCell {
            configure(headerCell, at: indexPath.item, activeIndex: selectedIndex)
        }
        return cell
    }
}

// MARK: - UICollectionViewDelegateFlowLayout

extension PivotHeaderStripView: UICollectionViewDelegateFlowLayout {

    /// Размер ячейки: высота — вся лента, ширина — по режиму (§3).
    public func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        guard titles.indices.contains(indexPath.item) else { return .zero }

        return CGSize(
            width: itemWidth(at: indexPath.item),
            height: max(collectionView.bounds.height, 1)
        )
    }

    /// Тап по заголовку: сообщает намерение, не меняя состояние ленты (§5).
    public func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard titles.indices.contains(indexPath.item) else { return }

        onSelect?(indexPath.item)
    }

    /// Собственная прокрутка ленты пользователем: индикатор следует за
    /// заголовком, к которому «прилип», только трансформом (§4, §7).
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
        updateIndicatorPosition()
    }
}

// MARK: - Ячейка заголовка

/// Ячейка заголовка ленты.
///
/// Внутренняя деталь: без autolayout и без `intrinsicContentSize`-зависимостей,
/// чтобы смена шрифта и цвета в горячем пути не запускала layout-проход (§4, §7).
/// Размер задаёт делегат ленты, текст центрируется в `contentView`.
private final class PivotHeaderCell: UICollectionViewCell {

    static let reuseIdentifier = "PivotHeaderCell"

    private let titleLabel = UILabel()

    // Последнее применённое состояние: позволяет пропускать работу, когда
    // прогресс сдвинулся меньше чем на полпроцента (§7).
    private var appliedTitle: String?
    private var appliedFont: UIFont?
    private var appliedIsActive: Bool?
    private var appliedFactor: CGFloat = -1
    private var appliedActiveColor: UIColor?
    private var appliedInactiveColor: UIColor?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel.frame = contentView.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        appliedTitle = nil
        appliedFont = nil
        appliedIsActive = nil
        appliedFactor = -1
        appliedActiveColor = nil
        appliedInactiveColor = nil
        titleLabel.text = nil
    }

    /// Общая настройка: ячейка — кнопка для VoiceOver (§8), подпись — её
    /// accessibility-label, а не отдельный элемент.
    private func setUp() {
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .button

        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        // §8: в `.fill` длинный заголовок усекается хвостом; на обычных размерах
        // это осознанный компромисс режима равных ширин (см. `mode`).
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isAccessibilityElement = false
        contentView.addSubview(titleLabel)
    }

    /// Применяет состояние заголовка.
    ///
    /// Вызывается и из `cellForItemAt`, и из горячего пути свайпа, поэтому
    /// сначала сравнивает состояние с последним применённым и выходит без
    /// работы, если ничего заметно не изменилось (§7).
    ///
    /// - Parameters:
    ///   - title: Текст заголовка.
    ///   - font: Уже масштабированный шрифт состояния.
    ///   - isActive: Ближайший ли это к прогрессу заголовок (жирность + `.selected`).
    ///   - factor: Коэффициент акцента `0...1` из
    ///     ``PivotHeaderIndicator/blendFactor(distanceFromProgress:span:)``.
    ///   - activeColor: Цвет полного акцента.
    ///   - inactiveColor: Цвет неактивного заголовка.
    func apply(
        title: String,
        font: UIFont,
        isActive: Bool,
        factor: CGFloat,
        activeColor: UIColor,
        inactiveColor: UIColor
    ) {
        let clampedFactor = min(max(factor, 0), 1)

        guard appliedTitle != title
            || appliedFont != font
            || appliedIsActive != isActive
            || abs(appliedFactor - clampedFactor) > 0.005
            || appliedActiveColor != activeColor
            || appliedInactiveColor != inactiveColor
        else { return }

        appliedTitle = title
        appliedFont = font
        appliedIsActive = isActive
        appliedFactor = clampedFactor
        appliedActiveColor = activeColor
        appliedInactiveColor = inactiveColor

        titleLabel.text = title
        if titleLabel.font != font {
            titleLabel.font = font
        }
        titleLabel.textColor = Self.blendedColor(
            active: activeColor,
            inactive: inactiveColor,
            amount: clampedFactor
        )

        accessibilityLabel = title
        let isSelectedForAccessibility = accessibilityTraits.contains(.selected)
        if isActive != isSelectedForAccessibility {
            if isActive {
                accessibilityTraits = [.button, .selected]
            } else {
                accessibilityTraits = .button
            }
        }
    }

    /// Непрерывная интерполяция цвета от неактивного к активному (§4).
    ///
    /// Цвет создаётся динамическим (`UIColor(dynamicProvider:)`) и разрешает
    /// исходные цвета в момент отрисовки: системные динамические цвета
    /// продолжают подстраиваться под светлую/тёмную тему, тогда как
    /// преждевременное `getRed` зафиксировало бы одну тему навсегда.
    private static func blendedColor(active: UIColor, inactive: UIColor, amount: CGFloat) -> UIColor {
        let blendAmount = min(max(amount, 0), 1)
        if blendAmount <= 0 { return inactive }
        if blendAmount >= 1 { return active }

        return UIColor { traits in
            let resolvedActive = active.resolvedColor(with: traits)
            let resolvedInactive = inactive.resolvedColor(with: traits)

            guard
                let activeComponents = resolvedActive.rgbaComponents,
                let inactiveComponents = resolvedInactive.rgbaComponents
            else {
                // Нецветовые/шаблонные цвета не смешиваются: отдаём ближайший полюс.
                return blendAmount < 0.5 ? resolvedInactive : resolvedActive
            }

            return UIColor(
                red: inactiveComponents.red
                    + (activeComponents.red - inactiveComponents.red) * blendAmount,
                green: inactiveComponents.green
                    + (activeComponents.green - inactiveComponents.green) * blendAmount,
                blue: inactiveComponents.blue
                    + (activeComponents.blue - inactiveComponents.blue) * blendAmount,
                alpha: inactiveComponents.alpha
                    + (activeComponents.alpha - inactiveComponents.alpha) * blendAmount
            )
        }
    }
}

// MARK: - Раскладка ленты

/// Потоковая раскладка ленты, зеркалящая заголовки в RTL (§8, E9.6).
///
/// У `UICollectionViewFlowLayout` `flipsHorizontallyInOppositeLayoutDirection`
/// по умолчанию `false`: при направлении, заданном локально
/// (`semanticContentAttribute`), ячейки не зеркалились, хотя пейджер зеркалит
/// слоты страниц, — порядок заголовков расходился с направлением свайпа.
/// Включённый флаг переворачивает систему координат, когда
/// `effectiveUserInterfaceLayoutDirection` коллекции противоположно
/// `developmentLayoutDirection` раскладки (LTR). Геометрия индикатора по-прежнему
/// читает фактические атрибуты, поэтому от способа зеркалирования не зависит.
private final class PivotHeaderFlowLayout: UICollectionViewFlowLayout {
    override var flipsHorizontallyInOppositeLayoutDirection: Bool { true }

    override var developmentLayoutDirection: UIUserInterfaceLayoutDirection { .leftToRight }
}

// MARK: - Компоненты цвета

private extension UIColor {

    /// RGBA-компоненты в `0...1`; `nil` для цветов, которые нельзя разложить
    /// (например, шаблонных). Вызывать только для разрешённого цвета: у
    /// динамического цвета `getRed` не знает темы.
    var rgbaComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return (red, green, blue, alpha)
    }
}
#endif
