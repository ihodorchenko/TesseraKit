//
//  PanoScrollView.swift
//  TesseraPanorama
//
//  Горизонтальный скролл панорамы: секции уже экрана (peek), кастомный снап и
//  единственный источник прогресса `t`.
//  Проектный документ: docs/PANORAMA-IOS-DESIGN.md — §3 «Концептуальная
//  архитектура» (слой PanoScrollView под PanoramaViewController), §4 «Геометрия
//  и математика ядра» (`itemWidth = screenWidth − peek`; `t = offset.x / itemWidth`;
//  снап через `targetContentOffset(forProposedContentOffset:withScrollingVelocity:)`;
//  `decelerationRate = .fast`; на границах — стандартный bounce), §6
//  «Производительность» (в `scrollViewDidScroll` нет layout), §7 «Accessibility»
//  (VoiceOver, RTL), §8 «Адаптивность» (одна секция — без снапа, по центру).
//

#if canImport(UIKit)
import TesseraCore
import UIKit

/// Наблюдатель событий ``PanoScrollView``.
///
/// Протокол внутримодульный: наружу панорама отдаёт только ``PanoramaDelegate``,
/// а жизненный цикл скролла — деталь ядра (§3 `docs/PANORAMA-IOS-DESIGN.md`).
/// Ссылка наблюдателя слабая: скролл-вью удерживает контроллер, обратной сильной
/// связи нет.
protocol PanoScrollViewObserving: AnyObject {

    /// Содержимое прокрутилось — горячий путь кадра (§4, §6).
    ///
    /// Наблюдатель обязан ограничиться `frame`/`transform`/`alpha`: layout в этом
    /// вызове запрещён.
    ///
    /// - Parameter scrollView: Источник события.
    func panoScrollViewDidScroll(_ scrollView: PanoScrollView)

    /// Жест закончился, система готовится начать инерцию.
    ///
    /// Отдаёт уже рассчитанный целевой индекс **в порядке чтения** — это точка
    /// prefetch'а соседа до снапа (§6).
    ///
    /// - Parameters:
    ///   - scrollView: Источник события.
    ///   - velocityX: Горизонтальная скорость жеста в pt/s (знаковая, в физических
    ///     координатах контента — как в `UIScrollView`).
    ///   - targetReadingIndex: Индекс секции, к которой прилипнет скролл, в порядке
    ///     чтения (в RTL зеркалирован через ``TesseraRTL``).
    func panoScrollViewWillEndDragging(
        _ scrollView: PanoScrollView,
        velocityX: CGFloat,
        targetReadingIndex: Int
    )

    /// Жест завершён; `decelerate == false` — движения по инерции не будет.
    ///
    /// - Parameters:
    ///   - scrollView: Источник события.
    ///   - decelerate: Начнётся ли инерция после жеста.
    func panoScrollViewDidEndDragging(_ scrollView: PanoScrollView, willDecelerate decelerate: Bool)

    /// Инерция закончилась — снап встал на секцию.
    ///
    /// - Parameter scrollView: Источник события.
    func panoScrollViewDidEndDecelerating(_ scrollView: PanoScrollView)

    /// Завершилась программная анимация `setContentOffset(_:animated:)`.
    ///
    /// - Parameter scrollView: Источник события.
    func panoScrollViewDidEndScrollingAnimation(_ scrollView: PanoScrollView)

    /// Жест VoiceOver «три пальца»: шаг по секциям в порядке чтения.
    ///
    /// - Parameters:
    ///   - scrollView: Источник события.
    ///   - step: `+1` — следующая секция, `-1` — предыдущая (уже с учётом RTL).
    /// - Returns: `true`, если переход выполнен.
    func panoScrollView(_ scrollView: PanoScrollView, accessibilityStep step: Int) -> Bool
}

/// Горизонтальный скролл панорамы с неполностраничными секциями и кастомным
/// снапом (docs/PANORAMA-IOS-DESIGN.md §3, §4).
///
/// ## Роль в архитектуре (§3)
///
/// ```
/// PanoramaViewController  ← оркестрация, child-VC, фон, заголовки
///     └─ PanoScrollView    ← только горизонталь, геометрия и снап
/// ```
///
/// Скролл-вью владеет **только** геометрией секций, снапом и жизненным циклом
/// прокрутки. Иерархией child-контроллеров, фоном, заголовками, делегатом и
/// accessibility-анонсами владеет ``PanoramaViewController``: он получает события
/// через внутримодульный ``PanoScrollViewObserving``. `contentOffset` пишут
/// исключительно жест этого скролл-вью и программный переход контроллера — правило
/// одного писателя из `docs/CORE-IOS-DESIGN.md` §2 соблюдается.
///
/// ## Геометрия (§4)
///
/// - `itemWidth = bounds.width − peek`, `peek` в диапазоне 16…64 pt;
/// - секция `i` (в порядке чтения) стоит в физическом слоте
///   `slot = i` (LTR) или `slot = sectionCount − 1 − i` (RTL), по x =
///   `slot × itemWidth` (+ `peek` в RTL — зеркальный запас в начале ленты);
/// - `contentSize.width = sectionCount × itemWidth + peek`: дополнительная
///   полоса `peek` в конце ленты позволяет выровнять последнюю секцию по ведущему
///   краю и показывает фон в зоне «подсматривания» на границе (§4);
/// - выравнивание секции `i` — `offset.x = slot × itemWidth`;
/// - прогресс `t = offset.x / itemWidth` — в ``currentProgress()`` он сырой
///   (физические координаты контента), а в порядке чтения его отдаёт
///   ``readingProgress(forRawOffset:)``: в RTL он нормализуется через
///   ``TesseraRTL`` (§7, «RTL»).
///
/// В координатах выравнивания сырой прогресс всегда целый (`slot`), поэтому
/// нормализация ``TesseraRTL`` даёт ровно индекс секции в порядке чтения —
/// инвариант «целая часть `t` — индекс» из §4 выполняется без поправок.
///
/// ## Снап (§4)
///
/// `isPagingEnabled = false` (полностраничный пейджинг не умеет peek),
/// `decelerationRate = .fast`, расчёт цели — в
/// `scrollViewWillEndDragging(_:withVelocity:targetContentOffset:)` через
/// ``TesseraSnapPolicy``: ближайший центр плюс порог скорости. Политика
/// клампит результат в `0...(sectionCount − 1) × itemWidth`, что совпадает с
/// допустимым диапазоном `contentOffset` этого скролл-вью, поэтому «резина» на
/// границах остаётся штатной, а снап в bounce не вмешивается.
///
/// ## Дисциплина производительности (§6)
///
/// ``scrollViewDidScroll(_:)`` только пробрасывает событие наблюдателю: ни layout,
/// ни изменения `contentSize`/frame'ов здесь нет. Геометрию задаёт контроллер
/// в `viewDidLayoutSubviews`.
///
/// - Important: Делегат скролл-вью занят самим скроллом (self-delegation).
///   Назначать свой `delegate` нельзя: это отключило бы снап и события
///   наблюдателя. Публичная настройка — ``snapPolicy`` и ``peek``.
/// - Important: Только главный поток: UIKit-состояние не размазывается по модулям
///   (`docs/CORE-IOS-DESIGN.md` §3).
public final class PanoScrollView: UIScrollView, UIScrollViewDelegate {

    // MARK: - Константы геометрии

    /// Рабочий диапазон ``peek`` из §4 («Ширина секции»): 16…64 pt.
    private static let peekRange: ClosedRange<CGFloat> = 16...64

    /// Значение ``peek`` по умолчанию (середина диапазона §4).
    private static let defaultPeek: CGFloat = 48

    // MARK: - Публичное состояние

    /// Запас «подсматривания» следующей секции, в точках.
    ///
    /// §4: `itemWidth = bounds.width − peek`. Как и ``PanoramaStyle/peek``,
    /// значение удерживается в диапазоне `16...64`; `NaN` и бесконечности
    /// трактуются как дефолт `48`. Запись не меняет геометрию сама по себе:
    /// `contentSize` пересчитывает контроллер в своём layout-проходе (§6).
    public var peek: CGFloat {
        get { storedPeek }
        set { storedPeek = Self.sanitizedPeek(newValue) }
    }

    /// Политика снапа (docs/CORE-IOS-DESIGN.md §3, `TesseraSnapPolicy`).
    ///
    /// Формула снапа живёт в Core и чиста: скролл-вью только подставляет
    /// фактическую ширину секции и скорость жеста. Смена политики не выполняет
    /// layout и вступает в силу со следующего жеста (§4).
    public var snapPolicy: TesseraSnapPolicy

    /// Число секций панорамы; задаёт контроллер.
    ///
    /// Влияет на ``itemWidth`` (одна секция — на всю ширину, §8), `contentSize`,
    /// снап и bounce: при `sectionCount <= 1` листать некуда, поэтому
    /// горизонтальный bounce и прокрутка выключаются (§8, «одна секция — без
    /// снапа, по центру»).
    public var sectionCount: Int {
        get { storedSectionCount }
        set {
            let clamped = max(newValue, 0)
            guard clamped != storedSectionCount else { return }
            storedSectionCount = clamped
            alwaysBounceHorizontal = clamped > 1
        }
    }

    /// Ширина одной секции (§4): `bounds.width − peek`.
    ///
    /// Для пустой панорамы и для единственной секции равна ширине скролл-вью:
    /// подсматривать нечего, холст занимает всю ширину (§8). Значение всегда
    /// больше нуля при непустых `bounds` — на нём держится деление в
    /// ``currentProgress()``.
    public var itemWidth: CGFloat {
        let width = bounds.width
        guard width > 0 else { return 0 }
        guard storedSectionCount > 1 else { return width }
        return max(width - effectivePeek, 1)
    }

    // MARK: - Внутреннее состояние

    /// Наблюдатель жизненного цикла скролла (контроллер панорамы).
    weak var observer: PanoScrollViewObserving?

    /// Хранилище ``peek`` — валидируется на записи.
    private var storedPeek: CGFloat = PanoScrollView.defaultPeek

    /// Хранилище ``sectionCount`` — валидируется на записи.
    private var storedSectionCount: Int = 0

    /// ``peek`` с гарантией диапазона (страховка для значений, полученных до init).
    private var effectivePeek: CGFloat { Self.sanitizedPeek(storedPeek) }

    /// Направление чтения текущей иерархии (для слотов и нормализации прогресса).
    ///
    /// §7, «RTL»: прогресс и индекс считаются от направления чтения.
    var resolvedLayoutDirection: UIUserInterfaceLayoutDirection {
        effectiveUserInterfaceLayoutDirection
    }

    // MARK: - Жизненный цикл

    /// Создаёт скролл-вью панорамы.
    ///
    /// - Parameters:
    ///   - peek: Запас подсматривания в точках; по умолчанию `48`, клампится в
    ///     `16...64` (§4).
    ///   - snapPolicy: Политика снапа; по умолчанию — параметры Core
    ///     (порог 600 pt/s, выравнивание по центру).
    public init(peek: CGFloat = 48, snapPolicy: TesseraSnapPolicy = TesseraSnapPolicy()) {
        self.storedPeek = PanoScrollView.sanitizedPeek(peek)
        self.snapPolicy = snapPolicy
        super.init(frame: .zero)
        commonInit()
    }

    /// Создаёт скролл-вью с заданным кадром и дефолтными peek/снапом.
    ///
    /// - Parameter frame: Начальный кадр.
    public override init(frame: CGRect) {
        self.storedPeek = PanoScrollView.defaultPeek
        self.snapPolicy = TesseraSnapPolicy()
        super.init(frame: frame)
        commonInit()
    }

    /// Не поддерживается: скролл-вью создаётся только из кода.
    @available(*, unavailable, message: "Используйте init(peek:snapPolicy:)")
    public required init?(coder: NSCoder) {
        fatalError("PanoScrollView не поддерживает загрузку из Interface Builder")
    }

    /// Общая настройка скролл-вью (§4, «Снап»).
    ///
    /// `isPagingEnabled` выключен осознанно: пейджинг умеет только полноширинные
    /// страницы, а панорама показывает peek. `contentInsetAdjustmentBehavior =
    /// .never` — кадр скролл-вью задаёт контроллер, а нижнюю safe area получают
    /// child-контроллеры секций; в `PanoramaStyle` соответствующего поля нет
    /// (отклонение от §8 задокументировано в отчёте).
    private func commonInit() {
        isPagingEnabled = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = false
        // Горизонтальный bounce включает sectionCount > 1 — листать некуда, если
        // секция одна (§8).
        alwaysBounceHorizontal = false
        bounces = true
        // Блокировка направления: диагональный жест не «размазывается» между
        // осями, вертикаль остаётся ребёнку (§5, «Вертикальный скролл»).
        isDirectionalLockEnabled = true
        backgroundColor = .clear
        delegate = self
    }

    // MARK: - Публичный API

    /// Сырой прогресс прокрутки `t = contentOffset.x / itemWidth` (§4).
    ///
    /// Значение в физических координатах контента: `0` — начало ленты, целая
    /// часть — физический слот секции, дробная — прогресс перехода. При bounce
    /// может выходить за `0...(sectionCount − 1)` — потребитель сам решает, как
    /// его ограничить. Для прогресса в порядке чтения (в RTL он зеркалируется)
    /// есть ``readingProgress(forRawOffset:)``; наружу панорама отдаёт именно
    /// его (см. ``PanoramaDelegate``).
    ///
    /// Метод чистый: только читает `contentOffset` и `bounds`, ничего не пишет и
    /// не запускает layout.
    ///
    /// - Returns: Сырой прогресс; `0` при нулевой ширине или нечисловом offset.
    public func currentProgress() -> CGFloat {
        let width = itemWidth
        guard width > 0, contentOffset.x.isFinite else { return 0 }
        return contentOffset.x / width
    }

    // MARK: - Геометрия (внутримодульная; используется контроллером и тестами)

    /// Максимальный допустимый `contentOffset.x` (§4, границы ленты).
    ///
    /// Для `contentSize.width = sectionCount × itemWidth + peek` это ровно
    /// `(sectionCount − 1) × itemWidth` — та же граница, в которую клампит
    /// ``TesseraSnapPolicy``. Отрицательных значений не бывает.
    var maximumOffsetX: CGFloat {
        guard bounds.width > 0 else { return 0 }
        return max(contentSize.width - bounds.width, 0)
    }

    /// Размер контента под текущее число секций (§4).
    ///
    /// - пусто — `.zero` (листать нечего);
    /// - одна секция — размер вьюпорта: секция занимает весь холст (§8);
    /// - иначе — `sectionCount × itemWidth + peek`.
    var requiredContentSize: CGSize {
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0, storedSectionCount > 0 else { return .zero }
        guard storedSectionCount > 1 else { return CGSize(width: width, height: height) }
        return CGSize(
            width: CGFloat(storedSectionCount) * itemWidth + effectivePeek,
            height: height
        )
    }

    /// Физический слот секции `index` (в порядке чтения).
    ///
    /// LTR: слот совпадает с индексом; RTL: зеркалится
    /// (`sectionCount − 1 − index`), чтобы первая секция чтения была самой правой
    /// (§7, «RTL»).
    func physicalSlot(forReadingIndex index: Int) -> Int {
        guard storedSectionCount > 0 else { return 0 }
        let clamped = min(max(index, 0), storedSectionCount - 1)
        guard resolvedLayoutDirection == .rightToLeft else { return clamped }
        return storedSectionCount - 1 - clamped
    }

    /// Кадр секции `index` в координатах контента (§4).
    ///
    /// В RTL секции сдвинуты на `peek` вправо: зеркальная копия LTR-ленты
    /// начинается не с нуля, а с полосы запаса, чтобы «подсматривание» следующей
    /// секции оказалось на ведущей стороне чтения (слева).
    ///
    /// - Parameter index: Индекс секции в порядке чтения.
    /// - Returns: Кадр секции; `.zero` для пустой панорамы или нулевой ширины.
    func rect(forReadingIndex index: Int) -> CGRect {
        guard storedSectionCount > 0, bounds.width > 0 else { return .zero }
        guard storedSectionCount > 1 else { return CGRect(origin: .zero, size: bounds.size) }

        let slot = physicalSlot(forReadingIndex: index)
        let leading = resolvedLayoutDirection == .rightToLeft ? effectivePeek : 0
        return CGRect(
            x: leading + CGFloat(slot) * itemWidth,
            y: 0,
            width: itemWidth,
            height: bounds.height
        )
    }

    /// `contentOffset.x`, при котором секция `index` выровнена по ведущему краю.
    ///
    /// В RTL выравнивание зеркальное: секция прижата к правому краю вьюпорта, а
    /// полоса подсматривания следующей секции — слева (§7, «RTL»). Формула
    /// `slot × itemWidth` одинакова для обоих направлений, потому что слот уже
    /// зеркалирован, а секции в RTL сдвинуты на `peek`.
    ///
    /// - Parameter index: Индекс секции в порядке чтения.
    /// - Returns: Offset выравнивания; `0` для одной секции и пустой ленты (§8).
    func alignmentOffset(forReadingIndex index: Int) -> CGFloat {
        guard storedSectionCount > 1 else { return 0 }
        return CGFloat(physicalSlot(forReadingIndex: index)) * itemWidth
    }

    /// Прогресс в порядке чтения для сырого offset'а (§7, «RTL»).
    ///
    /// В LTR это `offset / itemWidth`; в RTL ``TesseraRTL/normalizedProgress(_:pageCount:layoutDirection:)``
    /// зеркалирует его относительно середины ленты. При bounce значение может
    /// выходить за диапазон — нормализация не клампит (так же ведёт себя Core).
    ///
    /// - Parameter rawOffsetX: Физический `contentOffset.x`.
    /// - Returns: Прогресс в порядке чтения; `0` при одной секции и мусорном входе.
    func readingProgress(forRawOffset rawOffsetX: CGFloat) -> CGFloat {
        guard storedSectionCount > 1 else { return 0 }
        let width = itemWidth
        guard width > 0, rawOffsetX.isFinite else { return 0 }
        return TesseraRTL.normalizedProgress(
            rawOffsetX / width,
            pageCount: storedSectionCount,
            layoutDirection: resolvedLayoutDirection
        )
    }

    /// Сырой offset для прогресса в порядке чтения — обратное к
    /// ``readingProgress(forRawOffset:)`` преобразование.
    ///
    /// В RTL ``TesseraRTL/normalizedProgress(_:pageCount:layoutDirection:)`` —
    /// инволюция (`(n − 1) − ((n − 1) − t) == t`), поэтому тот же вызов переводит
    /// прогресс чтения обратно в физические координаты. Результат клампится в
    /// `0...maximumOffsetX`: у самой границы ленты доля внутри секции не
    /// представима (§8).
    ///
    /// - Parameter progress: Прогресс в порядке чтения (`0...sectionCount − 1`).
    /// - Returns: Клампированный `contentOffset.x`.
    func rawOffset(forReadingProgress progress: CGFloat) -> CGFloat {
        guard storedSectionCount > 1 else { return 0 }
        let width = itemWidth
        guard width > 0, progress.isFinite else { return 0 }

        let raw = TesseraRTL.normalizedProgress(
            progress,
            pageCount: storedSectionCount,
            layoutDirection: resolvedLayoutDirection
        )
        return min(max(raw * width, 0), maximumOffsetX)
    }

    /// Ближайший индекс секции в порядке чтения для сырого offset'а (§4, §7).
    ///
    /// Округление до слота выполняется **до** зеркалирования — так же, как в
    /// ``TesseraRTL/pageIndex(for:pageCount:layoutDirection:)``: важен физический
    /// слот, который сейчас в кадре, а не прогресс входа следующей секции.
    ///
    /// - Parameter rawOffsetX: Физический `contentOffset.x`.
    /// - Returns: Индекс в порядке чтения (при пустой ленте — `0`).
    func readingIndex(forRawOffset rawOffsetX: CGFloat) -> Int {
        guard storedSectionCount > 1 else { return 0 }
        let width = itemWidth
        guard width > 0, rawOffsetX.isFinite else { return 0 }

        let slot = min(
            max((rawOffsetX / width).rounded(), 0),
            CGFloat(storedSectionCount - 1)
        )
        return TesseraRTL.pageIndex(
            for: slot,
            pageCount: storedSectionCount,
            layoutDirection: resolvedLayoutDirection
        )
    }

    // MARK: - UIScrollViewDelegate

    /// Горячий путь прокрутки (§6).
    ///
    /// Ни layout, ни изменений `contentSize`: событие уходит наблюдателю, который
    /// двигает только `transform`/`alpha` и сообщает прогресс делегату.
    ///
    /// - Parameter scrollView: Скролл-вью-источник (всегда `self`).
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === self else { return }
        observer?.panoScrollViewDidScroll(self)
    }

    /// Кастомный снап панорамы (§4, «Снап»).
    ///
    /// Расчёт цели полностью делегируется ``TesseraSnapPolicy``: скролл-вью
    /// подставляет фактическую ширину секции (`itemWidth`) и скорость жеста.
    /// `isPagingEnabled` выключен, поэтому это единственный механизм прилипания.
    ///
    /// Для одной секции снапа нет: листать некуда, offset остаётся нулевым (§8).
    /// Префetch-хук: наблюдатель получает уже рассчитанный целевой индекс — сосед
    /// успевает загрузиться до начала децелерации (§6).
    ///
    /// - Parameters:
    ///   - scrollView: Скролл-вью-источник.
    ///   - velocity: Скорость жеста; используется только горизонтальная компонента.
    ///   - targetContentOffset: Предложенная системой цель; перезаписывается
    ///     результатом снапа.
    public func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard scrollView === self else { return }

        let count = storedSectionCount
        let width = itemWidth

        guard count > 1, width > 0 else {
            // Одна секция: снап не нужен, цель не трогаем (§8).
            if count == 1 {
                targetContentOffset.pointee.x = 0
            }
            observer?.panoScrollViewWillEndDragging(
                self,
                velocityX: velocity.x,
                targetReadingIndex: 0
            )
            return
        }

        targetContentOffset.pointee.x = snapPolicy.targetContentOffset(
            proposedOffset: targetContentOffset.pointee.x,
            velocity: velocity.x,
            itemWidth: width,
            pageCount: count
        )

        // Prefetch (§6): цель уже известна, снап ещё не начался.
        observer?.panoScrollViewWillEndDragging(
            self,
            velocityX: velocity.x,
            targetReadingIndex: readingIndex(forRawOffset: targetContentOffset.pointee.x)
        )
    }

    /// Жест завершён — сообщаем контроллеру, будет ли инерция.
    ///
    /// - Parameters:
    ///   - scrollView: Скролл-вью-источник.
    ///   - decelerate: Начнётся ли инерция.
    public func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        guard scrollView === self else { return }
        observer?.panoScrollViewDidEndDragging(self, willDecelerate: decelerate)
    }

    /// Инерция закончилась: снап встал на секцию.
    ///
    /// - Parameter scrollView: Скролл-вью-источник.
    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === self else { return }
        observer?.panoScrollViewDidEndDecelerating(self)
    }

    /// Программная анимация offset'а завершилась.
    ///
    /// - Parameter scrollView: Скролл-вью-источник.
    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView === self else { return }
        observer?.panoScrollViewDidEndScrollingAnimation(self)
    }

    // MARK: - Accessibility (§7)

    /// Пагинация секций жестом VoiceOver «три пальца» (§7, «VoiceOver»).
    ///
    /// Собственная реализация `UIScrollView` листала бы «экран», игнорируя
    /// границы секций и снап; здесь направление превращается в шаг по секциям
    /// через ``TesseraAccessibility/pageStep(for:layoutDirection:)`` (с учётом
    /// RTL), а решение и переход выполняет контроллер — `contentOffset` пишет
    /// по-прежнему он (§2, «Один писатель»).
    ///
    /// - Parameter direction: Направление жеста VoiceOver.
    /// - Returns: `true`, если жест обработан.
    public override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        // Одна секция или пустая лента: пагинации нет, отдаём жест системе.
        guard storedSectionCount > 1 else { return super.accessibilityScroll(direction) }

        let step = TesseraAccessibility.pageStep(
            for: direction,
            layoutDirection: resolvedLayoutDirection
        )
        // Вертикальные жесты и отсутствие наблюдателя — не наша адресация.
        guard step != 0, let observer else { return super.accessibilityScroll(direction) }
        return observer.panoScrollView(self, accessibilityStep: step)
    }

    // MARK: - Санитизация входа

    /// Приводит `peek` к диапазону `16...64`; `NaN`/бесконечности — к дефолту.
    private static func sanitizedPeek(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultPeek }
        return min(max(value, peekRange.lowerBound), peekRange.upperBound)
    }
}
#endif
