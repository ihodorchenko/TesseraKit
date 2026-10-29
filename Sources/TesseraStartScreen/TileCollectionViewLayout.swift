//
//  TileCollectionViewLayout.swift
//  TesseraStartScreen
//
//  Кастомная раскладка плиточной сетки рабочего стола.
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md — §3 «Плиточная сетка»
//  (формула юнита, юнитные координаты, жадная упаковка с «честными дырами»,
//  реализация: кастомный UICollectionViewLayout, атрибуты считаются из модели,
//  изменения — через инвалидацию с контекстом), §5 «Режим редактирования»
//  (resize/reorder переупаковывают модель и инвалидируют layout), §9
//  «Accessibility» (RTL: сетка зеркалится вью-слоем) и §14 п. 4
//  (D15: четыре размера — 1×1, 2×2, 4×2, 4×4).
//  Задача плана: E4.2-UI.
//
//  Границы ответственности: раскладка не хранит состояние рабочего стола и не
//  знает про ярлыки/папки. Она получает от TesseraTileGridView список пар
//  «идентификатор — размер», переводит их в юнитные координаты через
//  TileLayoutEngine (чистые функции из E4.2) и раскладывает в рамки в точках.
//  Пиксельная геометрия — ширина, поля, зазоры — единственное, чем владеет
//  этот файл; порядок, размеры и папки приходят из модели (TileStore → снимок).
//
//  Дисциплина производительности (§3, и CORE-IOS-DESIGN.md §2): пересчёт
//  геометрии возможен только в layout-проходе (prepare/collectionViewContentSize)
//  или по явной инвалидации. В scrollViewDidScroll ничего из этого не
//  вызывается — за это отвечает TesseraTileGridView.
//

#if canImport(UIKit)
import UIKit

// MARK: - Причина инвалидации

/// Причина пересчёта раскладки (внутренняя деталь, наружу не выходит).
///
/// Нужна, чтобы инвалидация несла контекст: `resize` и `reorder` — это не
/// «новый набор данных», а переупаковка того же набора (§5). UICollectionView
/// по контексту понимает, что перезагружать ячейки не нужно, достаточно
/// пересчитать атрибуты; список элементов для этого приходит в
/// ``TesseraTileLayoutInvalidationContext``.
enum TesseraTileLayoutInvalidationReason: Equatable {

    /// Изменился состав/размеры элементов сетки — модель переупакована.
    case items

    /// Изменилась только геометрия (колонки, поля, зазор, направление
    /// чтения): состав прежний, рамки могли сдвинуться.
    case geometry
}

// MARK: - Контекст инвалидации

/// Контекст инвалидации раскладки сетки (§3, §5).
///
/// UICollectionView поддерживает инвалидацию с контекстом
/// (`invalidateLayout(with:)`): контекст позволяет сказать, *что* изменилось,
/// и не перезагружать ячейки, если поменялась только рамка. Здесь контекст
/// несёт причину и идентификаторы элементов в порядке сетки — по ним ячейка
/// или координатор редактирования (E4.4) могут сопоставить атрибуты с моделью,
/// не читая снимок повторно.
///
/// Класс внутренний: снаружи инвалидацию запускает только `TesseraTileGridView`,
/// а публичного API для контекста не требуется — правило минимальной
/// публичной поверхности (AGENTS.md).
final class TesseraTileLayoutInvalidationContext: UICollectionViewLayoutInvalidationContext {

    /// Что именно стало причиной пересчёта.
    let reason: TesseraTileLayoutInvalidationReason

    /// Идентификаторы элементов в порядке сетки на момент инвалидации.
    let itemIdentifiers: [AnyHashable]

    /// Создаёт контекст инвалидации.
    ///
    /// - Parameters:
    ///   - reason: Причина пересчёта.
    ///   - itemIdentifiers: Идентификаторы элементов в порядке сетки.
    init(reason: TesseraTileLayoutInvalidationReason, itemIdentifiers: [AnyHashable]) {
        self.reason = reason
        self.itemIdentifiers = itemIdentifiers
        super.init()
    }
}

// MARK: - Атрибуты плитки

/// Атрибуты ячейки сетки: рамка плюс модель, к которой она относится.
///
/// Наследник ``UICollectionViewLayoutAttributes`` нужен, чтобы координатор
/// редактирования и тесты могли получить идентификатор и размер плитки прямо
/// из атрибутов (например, при перетаскивании и определении видимости), не
/// восстанавливая соответствие «индекс → элемент» вручную. Класс внутренний:
/// наружу отдаётся геометрия через `TesseraTileGridView.frame(forItemID:)`.
final class TesseraTileLayoutAttributes: UICollectionViewLayoutAttributes {

    /// Идентификатор ярлыка или папки, к которой относятся атрибуты.
    var itemID: AnyHashable?

    /// Размер плитки из модели (D15): запрошенный, до возможного ужатия под
    /// узкую сетку. Нужен ячейке для выбора шрифта и координатору для resize.
    var tileSize: TileSize = .medium

    /// Копирование обязательно: UICollectionView копирует атрибуты при
    /// анимациях и переиспользовании, и без переопределения кастомные поля
    /// потерялись бы у копии.
    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! TesseraTileLayoutAttributes
        copy.itemID = itemID
        copy.tileSize = tileSize
        return copy
    }
}

// MARK: - Раскладка

/// Раскладка плиточной сетки на ``TileLayoutEngine``
/// (docs/STARTSCREEN-IOS-DESIGN.md §3; D15 в docs/STATE.md).
///
/// ## Как считается геометрия (§3)
///
/// 1. Доступная ширина = `bounds.width − contentInsets.left − contentInsets.right`.
/// 2. Юнит = ``TileLayoutEngine/unit(screenWidth:columns:gaps:)``; зазор между
///    колонками — ``itemSpacing`` (в формуле §3 это `gaps`).
/// 3. ``TileLayoutEngine/pack(items:columns:unit:)`` жадно упаковывает плитки в
///    юнитные координаты; дыры остаются «честными».
/// 4. ``TileLayoutEngine/rect(for:unit:gap:origin:)`` переводит слот в рамку в
///    точках; внутренние зазоры входят в рамку широкой/большой плитки.
///
/// Позиция в юнитных координатах хранится в движке, поэтому поворот экрана
/// меняет только юнит: `prepare()` пересчитывает рамки, не трогая модель.
///
/// ## RTL (§9)
///
/// Движок работает в LTR-координатах. Зеркалирование сетки — задача вью-слоя:
/// здесь рамка каждого слота отражается по горизонтали, если направление
/// чтения коллекции — справа налево. Порядок элементов при этом не меняется:
/// элемент `0` остаётся первым в порядке чтения и визуально оказывается справа.
///
/// ## Инвалидация (§3, §5)
///
/// - смена ширины/высоты или направления чтения — `shouldInvalidateLayout`
///   (только размеры: изменение `contentOffset` при скролле инвалидацию не
///   вызывает, иначе layout пересчитывался бы на каждом кадре);
/// - resize/reorder и смена состава — явная инвалидация с
///   ``TesseraTileLayoutInvalidationContext`` через
///   ``setItems(_:reason:)``; анимацию выполняет `TesseraTileGridView`.
///
/// ## Узкая сетка
///
/// D15 требует четырёх размеров, и ``columns`` по умолчанию 4. Если хост
/// задал меньше колонок, чем ширина плитки, раскладка не выбрасывает плитку
/// (иначе разъехалось бы соответствие «индекс → элемент»), а ужимает её след:
/// 2×2 при 2–3 колонках и 1×1 при одной. Это деградация геометрии, а не смена
/// модели: `TileStore` и ячейка по-прежнему видят исходный ``TileSize``.
final class TesseraTileCollectionViewLayout: UICollectionViewLayout {

    // MARK: - Конфигурация

    /// Число колонок сетки (по §3 — 4 по умолчанию). Значения меньше 1
    /// зажимаются к 1; см. «Узкая сетка» в документации класса.
    var columns: Int {
        get { columnCount }
        set {
            let clamped = max(1, newValue)
            guard clamped != columnCount else { return }
            columnCount = clamped
            invalidateGeometry()
        }
    }

    /// Внешние поля сетки в точках (по §3 — `margins` в формуле юнита).
    ///
    /// Отрицательные и нечисловые значения при расчёте трактуются как 0.
    /// Поля задаются здесь, а не через `collectionView.contentInset`: раскладка
    /// сама считает полную ширину контента, и два источника полей не должны
    /// конкурировать.
    var contentInsets: UIEdgeInsets = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16) {
        didSet {
            guard contentInsets != oldValue else { return }
            invalidateGeometry()
        }
    }

    /// Зазор между соседними юнитами сетки в точках (`gaps` в формуле §3).
    ///
    /// Отрицательное значение трактуется как 0. Зазор входит и в формулу
    /// юнита, и в рамку каждой плитки: широкие плитки не «съедают» внутренние
    /// промежутки.
    var itemSpacing: CGFloat = 8 {
        didSet {
            guard itemSpacing != oldValue else { return }
            invalidateGeometry()
        }
    }

    // MARK: - Запросы геометрии

    /// Текущее число колонок; хранится отдельно, чтобы `columns` мог быть
    /// вычисляемым свойством с зажимом к 1.
    private var columnCount: Int = 4

    /// Идентификаторы элементов в порядке сетки (индекс совпадает с
    /// `IndexPath.item`). Обновляется в layout-проходе.
    private(set) var itemIdentifiers: [AnyHashable] = []

    /// Рамка элемента в координатах контента коллекции.
    ///
    /// Координаты контента — те же, в которых UICollectionView хранит рамки
    /// ячеек: `(0, 0)` — левый верхний угол контента, без учёта `contentOffset`.
    /// Для координат сетки-вью используйте `TesseraTileGridView.frame(forItemID:)`.
    ///
    /// - Parameter id: Идентификатор ярлыка или папки.
    /// - Returns: Рамка в точках или `nil`, если элемента нет в текущем наборе.
    func frame(forItemID id: AnyHashable) -> CGRect? {
        ensureGeometry()
        guard let index = indexByID[id], attributesByIndex.indices.contains(index) else {
            return nil
        }
        return attributesByIndex[index].frame
    }

    /// Рамка элемента по индексу в порядке сетки (координаты контента).
    ///
    /// - Parameter index: Индекс элемента; значения вне диапазона дают `nil`.
    /// - Returns: Рамка в точках или `nil`.
    func frame(forItemAt index: Int) -> CGRect? {
        ensureGeometry()
        guard attributesByIndex.indices.contains(index) else { return nil }
        return attributesByIndex[index].frame
    }

    /// Индекс элемента в порядке сетки.
    ///
    /// - Parameter id: Идентификатор ярлыка или папки.
    /// - Returns: Индекс или `nil`, если элемента нет.
    func index(ofItemID id: AnyHashable) -> Int? {
        ensureGeometry()
        return indexByID[id]
    }

    // MARK: - Модель

    /// Пары «идентификатор — размер» в порядке сетки.
    ///
    /// Хранится копией: раскладка не удерживает `TileDescriptor` и `TileFolder`
    /// (в них есть замыкания и `UIImage`), ей для геометрии достаточно
    /// идентичности и размера D15.
    private var layoutItems: [GeometryKey.Item] = []

    // MARK: - Состояние layout-прохода

    /// Ключ последнего пересчёта: всё, от чего зависит геометрия.
    private var lastKey: GeometryKey?

    /// Атрибуты в порядке сетки.
    private var attributesByIndex: [TesseraTileLayoutAttributes] = []

    /// Быстрый поиск индекса по идентификатору.
    private var indexByID: [AnyHashable: Int] = [:]

    /// Последний посчитанный размер контента.
    private var cachedContentSize: CGSize = .zero

    // MARK: - Вид ключа

    /// Всё, от чего зависит геометрия, одним значением.
    ///
    /// Сравнение ключа в ``ensureGeometry()`` избавляет от лишних пересчётов:
    /// `prepare()` UICollectionView может вызываться чаще, чем реально меняется
    /// ширина или модель.
    private struct GeometryKey: Equatable {

        /// Размер `bounds` коллекции (ширина задаёт юнит, высота — только
        /// размер контента).
        var boundsSize: CGSize

        /// Направление чтения: в RTL сетка зеркалится (§9).
        var direction: UIUserInterfaceLayoutDirection

        /// Эффективное число колонок, не меньше 1.
        var columns: Int

        /// Санитизированные внешние поля.
        var insets: UIEdgeInsets

        /// Санитизированный зазор между юнитами.
        var spacing: CGFloat

        /// Элементы в порядке сетки.
        var items: [Item]

        /// Элемент, от которого зависит только геометрия.
        struct Item: Equatable {
            var id: AnyHashable
            var size: TileSize
        }
    }

    // MARK: - Модель и инвалидация

    /// Причина последней инвалидации — для тестов E4.7 и отладки.
    ///
    /// UICollectionView не отдаёт контекст обратно в `prepare()`, поэтому
    /// кастомные свойства контекста раскладка запоминает здесь: так тест может
    /// проверить, что resize/reorder шли именно через инвалидацию с контекстом,
    /// а не через `reloadData`.
    private(set) var lastInvalidationReason: TesseraTileLayoutInvalidationReason?

    /// Запоминает причину из контекста и передаёт инвалидацию дальше.
    ///
    /// По документации UIKit переопределение `invalidateLayout(with:)` обязано
    /// вызвать `super`; раскладка при этом не кеширует атрибуты насовсем —
    /// ключ геометрии в ``ensureGeometry()`` всё равно решает, что пересчитать.
    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        if let tileContext = context as? TesseraTileLayoutInvalidationContext {
            lastInvalidationReason = tileContext.reason
        }
        super.invalidateLayout(with: context)
    }

    /// Принимает новый набор элементов и инвалидирует раскладку с контекстом
    /// (§3, §5).
    ///
    /// Вызывается `TesseraTileGridView` перед `reloadData()` (полная перезагрузка) или
    /// внутри `performBatchUpdates` (анимированный resize/reorder). Сам метод
    /// анимацию не запускает — это делает вью-слой, который владеет коллекцией.
    ///
    /// - Parameters:
    ///   - items: Элементы сетки в порядке отображения.
    ///   - reason: Причина пересчёта (состав или только геометрия).
    func setItems(_ items: [TileGridItem], reason: TesseraTileLayoutInvalidationReason) {
        layoutItems = items.map { GeometryKey.Item(id: $0.id, size: $0.size) }
        itemIdentifiers = layoutItems.map { $0.id }

        let context = TesseraTileLayoutInvalidationContext(
            reason: reason,
            itemIdentifiers: itemIdentifiers
        )
        invalidateLayout(with: context)
    }

    /// Инвалидирует раскладку из-за смены конфигурации (колонки, поля, зазор).
    private func invalidateGeometry() {
        let context = TesseraTileLayoutInvalidationContext(
            reason: .geometry,
            itemIdentifiers: layoutItems.map { $0.id }
        )
        invalidateLayout(with: context)
    }

    // MARK: - UICollectionViewLayout

    /// Пересчитывает атрибуты, если изменился ключ геометрии.
    ///
    /// В горячем пути скролла не вызывается: `shouldInvalidateLayout` для
    /// изменения `contentOffset` возвращает `false`, поэтому UICollectionView
    /// не просит layout пересчитываться на каждом кадре (§3, дисциплина
    /// CORE-IOS-DESIGN.md §2).
    override func prepare() {
        super.prepare()
        ensureGeometry()
    }

    /// Размер контента: высота последней строки плюс нижнее поле.
    override var collectionViewContentSize: CGSize {
        ensureGeometry()
        return cachedContentSize
    }

    /// Атрибуты элементов, пересекающихся с прямоугольником.
    ///
    /// Перебор линейный: элементов на рабочем столе десятки, и словарь
    /// квадрантов здесь дороже, чем сам перебор.
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        ensureGeometry()
        return attributesByIndex.filter { $0.frame.intersects(rect) }
    }

    /// Атрибуты одного элемента по индексу.
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        ensureGeometry()
        guard attributesByIndex.indices.contains(indexPath.item) else { return nil }
        return attributesByIndex[indexPath.item]
    }

    /// Нужно ли пересчитать раскладку при изменении `bounds`.
    ///
    /// Инвалидация только по размеру и направлению чтения. Изменение
    /// `bounds.origin` — это скролл; возвращать `true` на него нельзя, иначе
    /// layout пересчитывался бы на каждом кадре (§3). Поворот и смена ширины
    /// меняют юнит — их пересчитываем.
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let lastKey else { return true }

        let sizeChanged = abs(newBounds.width - lastKey.boundsSize.width) > 0.5
            || abs(newBounds.height - lastKey.boundsSize.height) > 0.5
        guard let collectionView else { return sizeChanged }

        let directionChanged = collectionView.effectiveUserInterfaceLayoutDirection != lastKey.direction
        return sizeChanged || directionChanged
    }

    // MARK: - Пересчёт геометрии

    /// Пересчитывает атрибуты, если ключ геометрии отличается от последнего.
    ///
    /// Вызывается из layout-прохода и из запросов рамок. Если коллекции ещё
    /// нет (layout создан до установки в коллекцию), геометрия остаётся пустой:
    /// первый же `prepare()` после установки всё посчитает.
    private func ensureGeometry() {
        guard let collectionView else { return }

        let key = makeKey(for: collectionView)
        guard key != lastKey else { return }
        rebuild(for: key)
    }

    /// Собирает ключ геометрии из текущего состояния коллекции и раскладки.
    private func makeKey(for collectionView: UICollectionView) -> GeometryKey {
        GeometryKey(
            boundsSize: collectionView.bounds.size,
            direction: collectionView.effectiveUserInterfaceLayoutDirection,
            columns: columns,
            insets: sanitized(insets: contentInsets),
            spacing: sanitized(spacing: itemSpacing),
            items: layoutItems
        )
    }

    /// Пересобирает атрибуты по ключу.
    ///
    /// Здесь же обновляются ``itemIdentifiers`` и ``cachedContentSize``: после
    /// этого layout согласован с моделью, даже если UICollectionView ещё не
    /// спросил атрибуты.
    private func rebuild(for key: GeometryKey) {
        lastKey = key
        itemIdentifiers = key.items.map { $0.id }
        attributesByIndex.removeAll(keepingCapacity: true)
        indexByID.removeAll(keepingCapacity: true)
        cachedContentSize = .zero

        guard !key.items.isEmpty else { return }

        let contentWidth = key.boundsSize.width - key.insets.left - key.insets.right
        guard contentWidth.isFinite, contentWidth > 0 else { return }

        let unit = TileLayoutEngine.unit(
            screenWidth: contentWidth,
            columns: key.columns,
            gaps: key.spacing
        )
        guard unit > 0 else { return }

        // Ужимаем только след плитки для узкой сетки; модель (TileSize) не
        // меняется — её по-прежнему видят ячейка и TileStore.
        let packItems: [(id: AnyHashable, size: TileSize)] = key.items.map {
            (id: $0.id, size: normalizedSize($0.size, columns: key.columns))
        }
        let slots = TileLayoutEngine.pack(
            items: packItems,
            columns: key.columns,
            unit: unit
        )

        // Движок пропускает только плитки шире сетки; normalizedSize это
        // исключает. Страховка на случай будущих изменений движка: лучше
        // остаться без атрибутов, чем получить рассинхрон индексов.
        guard slots.count == key.items.count else { return }

        var maximumY = key.insets.top
        attributesByIndex.reserveCapacity(slots.count)

        for (index, slot) in slots.enumerated() {
            var frame = TileLayoutEngine.rect(
                for: slot,
                unit: unit,
                gap: key.spacing,
                origin: CGPoint(x: key.insets.left, y: key.insets.top)
            )

            // §9, RTL: движок считает в LTR, зеркалирование — здесь.
            if key.direction == .rightToLeft {
                let localX = frame.minX - key.insets.left
                frame.origin.x = key.insets.left + contentWidth - localX - frame.width
            }

            let attributes = TesseraTileLayoutAttributes(
                forCellWith: IndexPath(item: index, section: 0)
            )
            attributes.itemID = slot.id
            attributes.tileSize = key.items[index].size
            attributes.frame = frame
            attributesByIndex.append(attributes)
            indexByID[slot.id] = index
            maximumY = max(maximumY, frame.maxY)
        }

        cachedContentSize = CGSize(
            width: key.boundsSize.width,
            height: maximumY + key.insets.bottom
        )
    }

    // MARK: - Служебные преобразования

    /// Ужимает след плитки под узкую сетку, не меняя модель.
    ///
    /// D15 рассчитан на 4 колонки; при меньшем числе колонок широкая плитка
    /// не помещается. Вместо пропуска (который сдвинул бы соответствие индексов)
    /// берём ближайший меньший размер: 2×2 при двух-трёх колонках и 1×1 при
    /// одной.
    private func normalizedSize(_ size: TileSize, columns: Int) -> TileSize {
        guard size.unitColumns > columns else { return size }
        return columns >= 2 ? .medium : .small
    }

    /// Санитизирует внешние поля: отрицательные и нечисловые — 0.
    private func sanitized(insets: UIEdgeInsets) -> UIEdgeInsets {
        UIEdgeInsets(
            top: sanitized(length: insets.top),
            left: sanitized(length: insets.left),
            bottom: sanitized(length: insets.bottom),
            right: sanitized(length: insets.right)
        )
    }

    /// Санитизирует зазор: отрицательный и нечисловой — 0.
    private func sanitized(spacing: CGFloat) -> CGFloat {
        sanitized(length: spacing)
    }

    /// Санитизирует одно значение длины: отрицательное и нечисловое — 0.
    private func sanitized(length: CGFloat) -> CGFloat {
        guard length.isFinite else { return 0 }
        return max(0, length)
    }
}

#endif
