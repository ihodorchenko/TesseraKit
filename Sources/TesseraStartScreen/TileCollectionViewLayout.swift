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
/// 1. Доступная ширина = `bounds.width − contentInsets.left − contentInsets.right`;
///    края контента и верхнее поле округляются до пикселя (E10.1).
/// 2. Юнит = ``TileLayoutEngine/unit(screenWidth:columns:gaps:scale:)``: формула
///    §3, округлённая вниз до пикселя (`displayScale` коллекции, запасной —
///    `UIScreen.main.scale`); зазор между колонками — ``itemSpacing`` (в
///    формуле §3 это `gaps`), тоже на пиксельной сетке. Остаток ширины
///    делится поровну на поля: сетка центрируется
///    (``TileLayoutEngine/gridMetrics(contentWidth:columns:spacing:scale:)``).
/// 3. ``TileLayoutEngine/pack(items:columns:unit:)`` строго компактно
///    упаковывает плитки в юнитные координаты (E8.5).
/// 4. ``TileLayoutEngine/rect(for:unit:gap:origin:)`` переводит слот в рамку в
///    точках; внутренние зазоры входят в рамку широкой/большой плитки. Все
///    рамки кратны `1 / scale`.
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
/// ## Панель раскрытой папки (D17, E7)
///
/// Раскрытие вставляет панель ``TileGridItem/folderContent(_:)`` **после
/// полосы папки** — строк плитки-папки, расширенных вниз на плитки, которые
/// начинаются в этих строках и заканчиваются ниже
/// (``TileLayoutEngine/folderBandEndRow(for:in:)``, E10.1); сама плитка
/// остаётся в наборе и на экране (число элементов растёт на один). Поэтому:
///
/// - панель растягивается на всю ширину контента (все ``columns`` колонок) и
///   занимает полноширинную строку сразу под полосой папки;
/// - высоту в точках считает
///   ``TileLayoutEngine/panelHeight(tileCount:width:columns:spacing:scale:)`` —
///   юнит и зазор ярлыков панели те же, что у сетки (``itemSpacing``, пиксельное
///   выравнивание); раскладка не хранит `TileFolder`, только число ярлыков;
/// - базовая упаковка не меняется: плитка папки и её соседи получают те же
///   слоты, что и в свёрнутой сетке, а всё, что начинается ниже полосы,
///   упаковывается заново и встаёт под панелью;
/// - элементы полосы (например, small справа от 2×2-папки или 2×2-ярлык,
///   начинающийся в строках папки и заканчивающийся ниже) остаются на месте:
///   панель начинается ниже них и ни с кем не пересекается;
/// - идентификатор панели совпадает с идентификатором папки, поэтому панель не
///   адресуется как элемент модели (``frame(forItemID:)`` по идентификатору
///   папки возвращает рамку самой плитки папки).
///
/// ## Анимация «папка ↔ панель» (D17, E7)
///
/// Сетка делает одно batch-обновление: `insertItems` панели при раскрытии и
/// `deleteItems` панели при закрытии. Плитка папки не удаляется и не
/// вставляется, поэтому её атрибуты анимации не нужны. Атрибуты панели
/// раскладка выдаёт явно:
///
/// - при раскрытии панель появляется с высотой 0
///   (``initialLayoutAttributesForAppearingItem``) и растёт до ``panelHeight``;
///   верхний край и ширина при этом не меняются, поэтому элементы под панелью
///   одновременно сдвигаются вниз;
/// - при закрытии панель схлопывается до нулевой высоты
///   (``finalLayoutAttributesForDisappearingItem``), а элементы под ней
///   поднимаются, пока плитка папки остаётся на месте.
///
/// Нулевая высота панели выдаётся только на время batch-обновления, в котором
/// панель действительно появляется или удаляется
/// (`prepare(forCollectionViewUpdates:)`). При `reloadData` (Reduce Motion, сетка
/// вне окна) UICollectionView не анимирует вставку, и панель обязана сразу
/// получить полный размер — иначе на кадр появился бы артефакт нулевой высоты.
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

    /// Масштаб экрана для пиксельного выравнивания вместо `displayScale`
    /// коллекции (E10.1).
    ///
    /// `nil` — масштаб берётся из `traitCollection.displayScale` коллекции
    /// (``resolvedDisplayScale(_:)``). Внутренний вход для тестов: раскладку
    /// без окна нельзя перевести на другой масштаб иначе. `0` — без
    /// выравнивания.
    var displayScaleOverride: CGFloat? {
        didSet {
            guard displayScaleOverride != oldValue else { return }
            invalidateGeometry()
        }
    }

    /// Масштаб для пиксельного выравнивания по `displayScale` (E10.1).
    ///
    /// `displayScale` коллекции без окна может быть `0` — тогда берётся
    /// `UIScreen.main.scale`; если и он не задан, выравнивания нет (`0`).
    /// Тем же правилом пользуется ячейка панели раскрытой папки: её ярлыки
    /// обязаны встать в те же пиксельные колонки, что и плитки сетки.
    ///
    /// - Parameter traitScale: `traitCollection.displayScale`.
    /// - Returns: Положительный масштаб либо `0` («не выравнивать»).
    static func resolvedDisplayScale(_ traitScale: CGFloat) -> CGFloat {
        if traitScale.isFinite, traitScale > 0 {
            return traitScale
        }
        let screenScale = UIScreen.main.scale
        return screenScale.isFinite && screenScale > 0 ? screenScale : 0
    }

    // MARK: - Запросы геометрии

    /// Текущее число колонок; хранится отдельно, чтобы `columns` мог быть
    /// вычисляемым свойством с зажимом к 1.
    private var columnCount: Int = 4

    /// Идентификаторы элементов в порядке сетки (индекс совпадает с
    /// `IndexPath.item`). Обновляется в layout-проходе.
    ///
    /// При раскрытой папке в наборе есть и плитка папки, и панель
    /// (``TileGridItem/folderContent(_:)``), поэтому идентификатор папки
    /// встречается дважды: у плитки и у панели.
    private(set) var itemIdentifiers: [AnyHashable] = []

    /// Рамка элемента в координатах контента коллекции.
    ///
    /// Координаты контента — те же, в которых UICollectionView хранит рамки
    /// ячеек: `(0, 0)` — левый верхний угол контента, без учёта `contentOffset`.
    /// Для координат сетки-вью используйте `TesseraTileGridView.frame(forItemID:)`.
    ///
    /// Панель раскрытой папки делит идентификатор с плиткой папки, но не
    /// адресуется как элемент модели: по идентификатору папки возвращается
    /// рамка самой плитки (она остаётся в наборе, пока папка раскрыта).
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

    /// Элементы в порядке сетки: идентификатор, модель размера и признак
    /// панели раскрытой папки.
    ///
    /// Хранится копией: раскладка не удерживает `TileDescriptor` и `TileFolder`
    /// (в них есть замыкания и `UIImage`), ей для геометрии достаточно
    /// идентичности, размера D15 и числа ярлыков панели (от него зависит высота
    /// панели в точках).
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

    // MARK: - Состояние анимации панели папки (D17, E7)

    /// Индекс панели раскрытой папки в текущем наборе атрибутов.
    ///
    /// `nil`, если панели нет или геометрия ещё не посчитана. Нужен, чтобы
    /// отличить появление панели от обычной плитки.
    private var panelAttributeIndex: Int?

    /// Индекс панели, которая появляется текущим batch-обновлением.
    ///
    /// Заполняется в ``prepare(forCollectionViewUpdates:)`` только для реальной
    /// вставки; при `reloadData` остаётся `nil`, и панель сразу получает полную
    /// высоту.
    private var appearingPanelIndex: Int?

    /// Рамка панели, исчезнувшей из набора на последнем `setItems`.
    ///
    /// UICollectionView запрашивает финальные атрибуты удаляемого элемента уже
    /// после того, как раскладка получила новый набор: панели в нём больше нет,
    /// и без сохранённой рамки схлопывание не из чего построить.
    private var disappearingPanel: (index: Int, attributes: TesseraTileLayoutAttributes)?

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

        /// Масштаб пиксельного выравнивания (E10.1); `0` — без выравнивания.
        var scale: CGFloat

        /// Элементы в порядке сетки.
        var items: [Item]

        /// Элемент, от которого зависит только геометрия.
        struct Item: Equatable {

            /// Идентификатор элемента.
            var id: AnyHashable

            /// Размер плитки из модели (D15). У панели — метка ``TileSize/wide``.
            var size: TileSize

            /// Элемент — полноширинная панель раскрытой папки (D17).
            ///
            /// Панель не участвует в базовой упаковке: она занимает отдельную
            /// полноширинную строку после строки папки.
            var isPanel: Bool

            /// Число ярлыков панели: от него зависит высота панели в точках.
            ///
            /// Только число, а не сами ярлыки: раскладка не удерживает
            /// `TileDescriptor` и `TileFolder` (в них замыкания и `UIImage`).
            var folderTileCount: Int
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
    /// (§3, §5, D17).
    ///
    /// Вызывается `TesseraTileGridView` перед `reloadData()` (полная перезагрузка) или
    /// внутри `performBatchUpdates` (анимированный resize/reorder). Сам метод
    /// анимацию не запускает — это делает вью-слой, который владеет коллекцией.
    ///
    /// Появление и исчезновение панели папки приходят сюда же: при раскрытии в
    /// наборе появляется панель (число элементов растёт на один), при закрытии —
    /// исчезает; плитка папки остаётся на месте. Геометрия пересобирается по
    /// смене ключа, а инвалидация несёт контекст `.items` — ячейки не
    /// перезагружаются без надобности, UICollectionView доезжает до новых рамок
    /// анимацией вью-слоя.
    ///
    /// - Parameters:
    ///   - items: Элементы сетки в порядке отображения.
    ///   - reason: Причина пересчёта (состав или только геометрия).
    func setItems(_ items: [TileGridItem], reason: TesseraTileLayoutInvalidationReason) {
        // Атрибуты исчезающей панели запоминаем до смены набора: в новом наборе
        // её уже нет, а UICollectionView спросит финальные атрибуты по прежнему
        // индексу (D17, E7).
        capturePanelTransition(replacingWith: items)
        appearingPanelIndex = nil

        layoutItems = items.map { item in
            let panel = item.panelFolder
            return GeometryKey.Item(
                id: item.id,
                size: item.size,
                isPanel: panel != nil,
                folderTileCount: panel?.tiles.count ?? 0
            )
        }
        itemIdentifiers = layoutItems.map { $0.id }

        let context = TesseraTileLayoutInvalidationContext(
            reason: reason,
            itemIdentifiers: itemIdentifiers
        )
        invalidateLayout(with: context)
    }

    /// Запоминает атрибуты панели, которая исчезает при закрытии папки.
    ///
    /// Вызывается из ``setItems(_:reason:)`` до замены набора: раскладка ещё
    /// знает старые элементы и их атрибуты, поэтому может построить анимацию
    /// схлопывания по прежней рамке. Исчезновением считается только переход
    /// «панель была — панели не стало»; при обычном resize/reorder и при
    /// раскрытии (панель появляется) ничего не запоминается: плитка папки при
    /// раскрытии никуда не девается.
    ///
    /// - Parameter items: Новый набор элементов сетки.
    private func capturePanelTransition(replacingWith items: [TileGridItem]) {
        disappearingPanel = nil

        let oldPanelIndex = layoutItems.firstIndex { $0.isPanel }
        guard let oldPanelIndex,
              !items.contains(where: { $0.isFolderPanel }) else {
            return
        }

        // Геометрия могла ещё не посчитаться: `frame(forItemID:)` и `prepare()`
        // считают её лениво. Атрибуты нужны в координатах контента, поэтому
        // пересчитываем по текущим (ещё старым) элементам.
        ensureGeometry()

        guard attributesByIndex.indices.contains(oldPanelIndex),
              let copy = attributesByIndex[oldPanelIndex].copy() as? TesseraTileLayoutAttributes else {
            return
        }
        disappearingPanel = (index: oldPanelIndex, attributes: copy)
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

    // MARK: - Анимация панели папки (D17, E7)

    /// Разбирает batch-обновление: появляется ли панель текущим обновлением.
    ///
    /// UICollectionView вызывает метод, когда сетка уже отдала новый набор через
    /// ``setItems(_:reason:)``. Только здесь видно, что панель именно
    /// появляется анимацией: при `reloadData` (Reduce Motion, сетка вне окна)
    /// этого вызова нет, и панель сразу получает полную высоту.
    override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        super.prepare(forCollectionViewUpdates: updateItems)
        appearingPanelIndex = nil

        // Ключ геометрии уже новый: атрибуты должны соответствовать набору,
        // который прислала сетка.
        ensureGeometry()

        for update in updateItems {
            guard case .insert = update.updateAction,
                  let indexPath = update.indexPathAfterUpdate else {
                continue
            }
            // Появилась панель — раскрытие. Плитка папки при этом остаётся
            // вставленной и не удаляется, поэтому других специальных атрибутов
            // для раскрытия не требуется.
            if let panelAttributeIndex, indexPath.item == panelAttributeIndex {
                appearingPanelIndex = indexPath.item
            }
        }
    }

    /// Начальные атрибуты появляющегося элемента.
    ///
    /// При раскрытии панель приходит с высотой 0 и вырастает до полной: верхний
    /// край и ширина не меняются, поэтому элементы под панелью одновременно
    /// сдвигаются вниз.
    override func initialLayoutAttributesForAppearingItem(
        at itemIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        if let appearingPanelIndex,
           itemIndexPath.item == appearingPanelIndex,
           itemIndexPath.item == panelAttributeIndex,
           let attributes = layoutAttributesForItem(at: itemIndexPath),
           let collapsed = collapsedPanelAttributes(from: attributes) {
            return collapsed
        }

        return super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)
    }

    /// Финальные атрибуты исчезающего элемента.
    ///
    /// При закрытии панель схлопывается до высоты 0: верхний край остаётся на
    /// месте, поэтому элементы под панелью поднимаются вверх, а плитка папки
    /// остаётся видна там, где и была.
    override func finalLayoutAttributesForDisappearingItem(
        at itemIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        if let panel = disappearingPanel,
           panel.index == itemIndexPath.item,
           let collapsed = collapsedPanelAttributes(from: panel.attributes) {
            return collapsed
        }

        return super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath)
    }

    /// Копия атрибутов панели со схлопнутой высотой (D17, E7).
    ///
    /// Верхний край и ширина панели сохраняются: панель «вырастает» вниз после
    /// строки папки и так же схлопывается вверх. Копия обязательна:
    /// UICollectionView анимирует именно возвращённый объект, и портить кадр
    /// атрибутов раскладки нельзя.
    ///
    /// - Parameter attributes: Полные атрибуты панели.
    /// - Returns: Копия с `frame.size.height == 0` или `nil`, если копирование
    ///   недоступно.
    private func collapsedPanelAttributes(
        from attributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes? {
        guard let copy = attributes.copy() as? UICollectionViewLayoutAttributes else {
            return nil
        }
        var frame = copy.frame
        frame.size.height = 0
        copy.frame = frame
        return copy
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
            scale: displayScaleOverride.map { $0.isFinite ? max($0, 0) : 0 }
                ?? Self.resolvedDisplayScale(collectionView.traitCollection.displayScale),
            items: layoutItems
        )
    }

    /// Пересобирает атрибуты по ключу.
    ///
    /// Здесь же обновляются ``itemIdentifiers`` и ``cachedContentSize``: после
    /// этого layout согласован с моделью, даже если UICollectionView ещё не
    /// спросил атрибуты.
    ///
    /// Горизонталь (E10.1): края контента и верхнее поле округляются до
    /// пикселя, юнит — вниз до пикселя
    /// (``TileLayoutEngine/gridMetrics(contentWidth:columns:spacing:scale:)``),
    /// остаток ширины делится поровну на поля — сетка центрируется. Поэтому все
    /// рамки кратны `1 / scale`.
    ///
    /// Раскрытие папки (D17) считается в три шага:
    ///
    /// 1. Базовая упаковка: все плитки, включая саму папку, получают те же
    ///    слоты, что и в свёрнутой сетке — панель в упаковке не участвует.
    /// 2. Полоса папки (E10.1): строки папки, расширенные вниз на плитки,
    ///    которые начинаются в этих строках и заканчиваются ниже
    ///    (``TileLayoutEngine/folderBandEndRow(for:in:)``). Панель занимает
    ///    полноширинную строку сразу после полосы и растягивается на всю
    ///    ширину контента.
    /// 3. Элементы, которые начинаются ниже полосы, упаковываются заново и
    ///    встают под панелью. Элементы полосы и всё, что выше, остаются на
    ///    месте: панель начинается ниже них и никого не перекрывает.
    private func rebuild(for key: GeometryKey) {
        lastKey = key
        itemIdentifiers = key.items.map { $0.id }
        attributesByIndex.removeAll(keepingCapacity: true)
        indexByID.removeAll(keepingCapacity: true)
        cachedContentSize = .zero
        panelAttributeIndex = nil

        guard !key.items.isEmpty else { return }

        // E10.1: края контента — на пиксельной сетке; ширина между ними —
        // доступная ширина формулы юнита.
        let contentLeft = TileLayoutEngine.pixelRound(key.insets.left, scale: key.scale)
        let contentRight = TileLayoutEngine.pixelRound(
            key.boundsSize.width - key.insets.right,
            scale: key.scale
        )
        let contentWidth = contentRight - contentLeft
        let contentTop = TileLayoutEngine.pixelRound(key.insets.top, scale: key.scale)
        guard contentWidth.isFinite, contentWidth > 0 else { return }

        guard let metrics = TileLayoutEngine.gridMetrics(
            contentWidth: contentWidth,
            columns: key.columns,
            spacing: key.spacing,
            scale: key.scale
        ) else {
            return
        }
        let unit = metrics.unit
        let spacing = metrics.spacing
        // Левый край сетки: остаток после выравнивания юнита делится на поля.
        let gridLeft = contentLeft + metrics.leading

        // Панель в базовой упаковке не участвует: она отдельная полноширинная
        // строка под папкой, а не плитка. Ужимаем только след плиток для узкой
        // сетки; модель (TileSize) не меняется — её видят ячейка и TileStore.
        let panelIndices = key.items.indices.filter { key.items[$0].isPanel }
        let mainPanelIndex = panelIndices.first
        var baseIndices: [Int] = []
        baseIndices.reserveCapacity(key.items.count)
        var packItems: [(id: AnyHashable, size: TileSize)] = []
        packItems.reserveCapacity(key.items.count - panelIndices.count)
        for index in key.items.indices where !key.items[index].isPanel {
            baseIndices.append(index)
            packItems.append(
                (id: key.items[index].id, size: normalizedSize(key.items[index].size, columns: key.columns))
            )
        }
        let slots = TileLayoutEngine.pack(
            items: packItems,
            columns: key.columns,
            unit: unit
        )

        // Движок пропускает только плитки шире сетки; normalizedSize это
        // исключает. Страховка на случай будущих изменений движка: лучше
        // остаться без атрибутов, чем получить рассинхрон индексов.
        guard slots.count == baseIndices.count else { return }

        /// Слоты базовых элементов по индексу в наборе.
        var slotByIndex: [Int: TileLayoutSlot] = [:]
        slotByIndex.reserveCapacity(baseIndices.count)
        for (position, index) in baseIndices.enumerated() {
            slotByIndex[index] = slots[position]
        }

        /// Рамка слота в точках с началом сетки и зеркалированием RTL (§9).
        ///
        /// Зеркалится внутри ширины сетки (`metrics.width`), а не контента:
        /// так сетка занимает одни и те же пиксельные колонки в LTR и RTL, и
        /// ярлыки панели (ячейка зеркалит колонки тем же правилом) совпадают
        /// с плитками.
        func elementFrame(for slot: TileLayoutSlot, top: CGFloat) -> CGRect {
            var rect = TileLayoutEngine.rect(
                for: slot,
                unit: unit,
                gap: spacing,
                origin: CGPoint(x: gridLeft, y: top)
            )
            if key.direction == .rightToLeft {
                let localX = rect.minX - gridLeft
                rect.origin.x = gridLeft + metrics.width - localX - rect.width
            }
            return rect
        }

        var frames: [CGRect?] = Array(repeating: nil, count: key.items.count)

        if let panelIndex = mainPanelIndex {
            panelAttributeIndex = panelIndex
            let panelHeight = TileLayoutEngine.panelHeight(
                tileCount: key.items[panelIndex].folderTileCount,
                width: contentWidth,
                columns: key.columns,
                spacing: key.spacing,
                scale: key.scale
            )
            let panelID = key.items[panelIndex].id
            // Плитка папки остаётся в наборе: по её слоту находится полоса,
            // после которой встаёт панель.
            let folderIndex = baseIndices.first { key.items[$0].id == panelID }

            if let folderIndex, let folderSlot = slotByIndex[folderIndex] {
                // E10.1: панель встаёт не под последней строкой папки, а под
                // полосой — иначе плитка, начинающаяся в строках папки и
                // заканчивающаяся ниже, осталась бы на месте под панелью.
                let bandEndRow = TileLayoutEngine.folderBandEndRow(for: folderSlot, in: slots)

                // D17: панель — полноширинная строка сразу после полосы папки;
                // верхний край — начало следующей строки сетки.
                let panelTop = contentTop + CGFloat(bandEndRow) * (unit + spacing)
                frames[panelIndex] = CGRect(
                    x: contentLeft,
                    y: panelTop,
                    width: contentWidth,
                    height: panelHeight
                )

                var belowIndices: [Int] = []
                belowIndices.reserveCapacity(baseIndices.count)
                for index in baseIndices {
                    guard let slot = slotByIndex[index] else { continue }
                    if slot.row < bandEndRow {
                        // Полоса папки и всё, что выше, остаются на месте: на
                        // неподвижной точке полосы ни одна такая плитка не
                        // заходит ниже `bandEndRow`.
                        frames[index] = elementFrame(for: slot, top: contentTop)
                    } else {
                        belowIndices.append(index)
                    }
                }

                // Всё, что начинается ниже полосы, упаковывается заново от
                // левого края и встаёт сразу под панелью. Юнитная сетка
                // сохраняется, начало координат — нижняя граница панели и зазор.
                if !belowIndices.isEmpty {
                    let belowItems: [(id: AnyHashable, size: TileSize)] = belowIndices.map { index in
                        (
                            id: key.items[index].id,
                            size: normalizedSize(key.items[index].size, columns: key.columns)
                        )
                    }
                    let belowSlots = TileLayoutEngine.pack(
                        items: belowItems,
                        columns: key.columns,
                        unit: unit
                    )
                    guard belowSlots.count == belowIndices.count else { return }

                    let belowTop = panelTop + panelHeight + spacing
                    for (position, index) in belowIndices.enumerated() {
                        frames[index] = elementFrame(for: belowSlots[position], top: belowTop)
                    }
                }
            } else {
                // Панели без плитки-папки не бывает в нормальном потоке (сетка
                // вставляет её только к существующей папке). Защитный путь:
                // панель без высоты сверху, базовые элементы — обычной упаковкой.
                frames[panelIndex] = CGRect(
                    x: contentLeft,
                    y: contentTop,
                    width: contentWidth,
                    height: 0
                )
                for index in baseIndices {
                    guard let slot = slotByIndex[index] else { continue }
                    frames[index] = elementFrame(for: slot, top: contentTop)
                }
            }
        } else {
            for index in baseIndices {
                guard let slot = slotByIndex[index] else { continue }
                frames[index] = elementFrame(for: slot, top: contentTop)
            }
        }

        // D17 раскрывает одну папку; лишние панели (если хост всё же положит
        // несколько) получают пустую рамку, чтобы индексы не разъехались.
        if let mainPanelIndex = mainPanelIndex {
            for index in panelIndices where index != mainPanelIndex {
                frames[index] = CGRect(
                    x: contentLeft,
                    y: contentTop,
                    width: contentWidth,
                    height: 0
                )
            }
        }

        var maximumY = contentTop
        attributesByIndex.reserveCapacity(key.items.count)

        for (index, item) in key.items.enumerated() {
            guard let frame = frames[index] else { return }

            let attributes = TesseraTileLayoutAttributes(
                forCellWith: IndexPath(item: index, section: 0)
            )
            attributes.itemID = item.id
            attributes.tileSize = item.size
            attributes.frame = frame
            attributesByIndex.append(attributes)

            // Панель не адресуется как элемент модели: по идентификатору папки
            // `frame(forItemID:)` возвращает рамку самой плитки папки.
            if !item.isPanel {
                indexByID[item.id] = index
            }
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
    /// одной. Правило живёт в `TileLayoutEngine.fittingSize(_:columns:)`, чтобы
    /// раскладка и чистые функции панели (E7.1) считали одинаково.
    private func normalizedSize(_ size: TileSize, columns: Int) -> TileSize {
        TileLayoutEngine.fittingSize(size, columns: columns)
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
