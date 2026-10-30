//
//  TesseraParallaxLayer.swift
//  TesseraCore/Parallax
//
//  Фоновый слой с параллаксом.
//  Контракт: docs/Core-iOS-Design.md §2 «Ключевые контракты» (пункт «Параллакс:
//  backgroundOffset = offset × factor, factor ∈ (0, 1); слой заведомо больше contentSize;
//  Reduce Motion → фактор 0»; экранная проекция для слоя рядом со скроллом —
//  `transform = −backgroundOffset`, E10.7), §3 «Концептуальная поверхность API»
//  (`TesseraParallaxLayer ← фон + фактор + ось`), §4 «Зависимости и структура» (каталог `Parallax`).
//  Детали фона в Panorama: docs/Panorama-iOS-Design.md §3 «Параллакс фона».
//  Задача плана: E1.3.
//
//  Дисциплина производительности (Core §2, п. 5; AGENTS.md, п. 5): в `update(withContentOffset:)`
//  меняется только `transform`. Никакого layout-прохода, `setNeedsLayout`, `frame` и создания
//  вьюх в горячем пути скролла. `bounds` меняется исключительно в конфигурации
//  (`configure` / `setContentSize` / `init`).
//

import UIKit

/// Фоновый слой, который при скролле сдвигается медленнее контента.
///
/// Смещение фона вычисляется чистой функцией ``effectiveOffset(contentOffset:factor:)``:
/// `backgroundOffset = contentOffset × factor`, `factor ∈ (0, 1)` — это смещение в координатах
/// контента, такое же по знаку, как `contentOffset`. Слой поддерживает обе оси — потребитель
/// передаёт в ``update(withContentOffset:)`` полный `CGPoint`, а неиспользуемую ось обнуляет сам
/// (например, для горизонтальной панорамы `y = 0`).
///
/// ## Экранная проекция: слой — сосед скролла
///
/// Слой рассчитан на размещение **рядом** со скролл-вью (в общем супервью, под ним), а не
/// внутри него. Поэтому смещение фона проецируется на экран со знаком минус:
/// `transform = −backgroundOffset`. Рост `contentOffset` на Δ уводит контент на экране на −Δ,
/// а фон — на −Δ × factor: в ту же сторону, что и контент, но медленнее (E10.7).
///
/// - Important: До E10.7 слой ставил `transform = +backgroundOffset`, и фон соседа скролла ехал
///   в сторону, противоположную контенту. Сигнатуры не менялись; поменялась только экранная
///   проекция. Потребитель кладёт слой так, чтобы запас размера был со стороны, куда слой
///   уезжает: начало слоя — у верхнего/левого края вьюпорта (минус поле под «резину» на
///   отрицательный offset), основной запас — снизу/справа.
///
/// Размер слоя равен `contentSize + extraSize` по каждой оси: запас `extraSize` нужен, чтобы при
/// сдвиге на `factor × offset` у краёв не появлялись пустые полосы (Core §2, Panorama §3).
///
/// ## Reduce Motion
///
/// При включённом Reduce Motion (и `respectsReduceMotion == true`, по умолчанию) действующий
/// фактор равен 0: фон стоит на месте, контент продолжает скроллиться. Провайдер настройки
/// инжектируется в инициализаторе, поэтому поведение тестируется без системных настроек.
///
/// ## Порядок использования
///
/// ```swift
/// let layer = TesseraParallaxLayer()
/// layer.configure(factor: 0.5, extraSize: 64)
/// layer.setContentSize(scrollView.contentSize)
/// // в scrollViewDidScroll:
/// layer.update(withContentOffset: scrollView.contentOffset)
/// ```
///
/// Все методы — главный поток: UIKit-вью не предназначена для фоновых вызовов
/// (Core §3: «вся работа на главном потоке UI»).
public final class TesseraParallaxLayer: UIView {

    // MARK: - Публичное состояние

    /// Учитывать ли системную настройку Reduce Motion.
    ///
    /// `true` (по умолчанию) — при включённом Reduce Motion действующий фактор равен 0.
    /// `false` — фактор применяется всегда (нужно только для отладочных сценариев).
    public var respectsReduceMotion: Bool = true {
        didSet {
            guard respectsReduceMotion != oldValue else { return }
            applyTransform()
        }
    }

    /// Текущий множитель параллакса. Всегда в `[0, 1]`: значения вне диапазона отсекаются
    /// в ``configure(factor:extraSize:)``. Значение по умолчанию — `0.5`.
    public private(set) var factor: CGFloat = TesseraParallaxLayer.defaultFactor

    /// Запас размера слоя сверх `contentSize`, в точках. Всегда `>= 0`: отрицательный или
    /// нечисловой запас отсекается в ``configure(factor:extraSize:)``.
    ///
    /// Запас прибавляется к **каждой** оси целиком:
    /// `width = contentSize.width + extraSize`, `height = contentSize.height + extraSize`.
    public private(set) var extraSize: CGFloat = 0

    /// Размер контента, под который рассчитан слой. Задаётся через ``setContentSize(_:)``.
    public private(set) var contentSize: CGSize = .zero

    // MARK: - Приватное состояние

    /// Значение множителя по умолчанию (Core §2: типичный диапазон 0.4–0.6).
    private static let defaultFactor: CGFloat = 0.5

    /// Провайдер системной настройки Reduce Motion. Инжектируется ради тестируемости.
    private let reduceMotionProvider: () -> Bool

    /// Последний применённый offset: нужен, чтобы пересчитать `transform` при смене
    /// `factor`, `extraSize` или `respectsReduceMotion` без нового вызова ``update(withContentOffset:)``.
    private var lastContentOffset: CGPoint = .zero

    // MARK: - Инициализация

    /// Создаёт слой с инжектируемым провайдером Reduce Motion.
    ///
    /// - Parameter reduceMotionProvider: Возвращает `true`, если Reduce Motion включён.
    ///   По умолчанию читается системная настройка `UIAccessibility.isReduceMotionEnabled`.
    ///   Провайдер опрашивается при каждой пересборке трансформа, поэтому переключение
    ///   настройки подхватывается на следующем кадре скролла.
    public init(reduceMotionProvider: @escaping () -> Bool = { UIAccessibility.isReduceMotionEnabled }) {
        self.reduceMotionProvider = reduceMotionProvider
        super.init(frame: .zero)
        commonInit()
    }

    /// Создаёт слой, у которого `contentSize` равен размеру переданного `frame`.
    ///
    /// - Parameter frame: Начальный кадр; его размер становится ``contentSize``.
    public override init(frame: CGRect) {
        self.reduceMotionProvider = { UIAccessibility.isReduceMotionEnabled }
        super.init(frame: frame)
        commonInit()
        contentSize = Self.sanitizedSize(frame.size)
    }

    /// Инициализация из Interface Builder / Storyboard.
    ///
    /// Использует системный провайдер Reduce Motion. `contentSize` остаётся нулевым —
    /// слой из разметки обязан получить размер через ``setContentSize(_:)`` до первого
    /// ``update(withContentOffset:)``.
    public required init?(coder: NSCoder) {
        self.reduceMotionProvider = { UIAccessibility.isReduceMotionEnabled }
        super.init(coder: coder)
        commonInit()
    }

    // MARK: - Публичный API

    /// Задаёт множитель параллакса и запас размера.
    ///
    /// Метод идемпотентен: повторный вызов с теми же значениями не трогает ни размер, ни
    /// `transform`. Layout-прохода не вызывает — только `bounds` и `transform` слоя.
    ///
    /// - Parameters:
    ///   - factor: Множитель `0 < factor < 1`. Значения вне диапазона приводятся к ближайшей
    ///     границе: `0` — параллакс выключен (как при Reduce Motion), `1` — слой едет вместе
    ///     с контентом. `NaN` и бесконечность трактуются как `0` (безопасное «не двигаемся»).
    ///   - extraSize: Запас сверх `contentSize` по каждой оси, в точках. Отрицательные и
    ///     нечисловые значения трактуются как `0`.
    public func configure(factor: CGFloat, extraSize: CGFloat) {
        self.factor = Self.sanitizedFactor(factor)
        self.extraSize = Self.sanitizedExtraSize(extraSize)
        applyLayerSize()
        applyTransform()
    }

    /// Задаёт размер контента, под который рассчитывается слой.
    ///
    /// Собственный размер слоя становится `contentSize + extraSize` по каждой оси
    /// (см. ``extraSize``). Отрицательные и нечисловые компоненты трактуются как `0`.
    ///
    /// - Parameter size: Размер контента в точках.
    public func setContentSize(_ size: CGSize) {
        contentSize = Self.sanitizedSize(size)
        applyLayerSize()
    }

    /// Применяет offset контента к фону.
    ///
    /// Вызывается из `scrollViewDidScroll` (или из контроллера, который транслирует offset).
    /// Меняет **только** `transform`; размер, иерархия и layout не трогаются
    /// (Core §2, п. 5). Трансформ — экранная проекция смещения фона для слоя-соседа скролла:
    /// `transform = −effectiveOffset(offset, factor)`, то есть фон едет в ту же сторону, что
    /// контент, но в `factor` раз медленнее. При включённом Reduce Motion действующий фактор
    /// равен 0 и слой остаётся на месте.
    ///
    /// - Parameter offset: Текущий `contentOffset` контента. Нечисловые значения игнорируются
    ///   (состояние слоя не меняется), чтобы `NaN` не «отравил» `transform`.
    public func update(withContentOffset offset: CGPoint) {
        guard offset.x.isFinite, offset.y.isFinite else { return }
        guard offset != lastContentOffset else { return }
        lastContentOffset = offset
        applyTransform()
    }

    /// Чистая функция смещения фона: `contentOffset × factor`.
    ///
    /// Результат — смещение фона **в координатах контента**: знак совпадает со знаком
    /// `contentOffset` (как и `contentOffset`, это «насколько видимое окно ушло вперёд по фону»).
    /// Экранная проекция для слоя рядом со скроллом — со знаком минус:
    /// `transform = −effectiveOffset` (так делает сам ``TesseraParallaxLayer``). Потребитель,
    /// который смещает фон не через слой (например, через `CALayer.transform` соседнего
    /// слоя), применяет ту же проекцию. Используется и тестами контракта.
    /// Отсечения `factor` здесь нет — валидация выполняется в ``configure(factor:extraSize:)``.
    ///
    /// - Parameters:
    ///   - contentOffset: Смещение контента.
    ///   - factor: Множитель параллакса.
    /// - Returns: Смещение фона по обеим осям.
    public static func effectiveOffset(contentOffset: CGPoint, factor: CGFloat) -> CGPoint {
        CGPoint(x: contentOffset.x * factor, y: contentOffset.y * factor)
    }

    // MARK: - Применение состояния

    /// Общая настройка вью: фон не перехватывает касания и не является элементом
    /// accessibility-дерева сам по себе (декоративный слой).
    ///
    /// Здесь же — подписка на смену Reduce Motion: если пользователь включил настройку,
    /// пока скролл стоит, слой обязан вернуться в нулевую позицию, не дожидаясь следующего
    /// `scrollViewDidScroll` (Core §2, п. 6: параллакс отключается при Reduce Motion).
    /// Подписка не удерживает слой: селекторный observer в `NotificationCenter` слабый,
    /// а с iOS 9 снимается автоматически.
    private func commonInit() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reduceMotionStatusDidChange),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
    }

    /// Системное уведомление о смене Reduce Motion: пересобирает `transform` текущим offset'ом.
    @objc private func reduceMotionStatusDidChange() {
        applyTransform()
    }

    /// Пересчитывает собственный размер слоя.
    ///
    /// Размер задаётся через `bounds`, а не `frame`: при непустом `transform` значение
    /// `frame` не определено, `bounds.size` — единственный надёжный источник размера.
    /// `center` при этом не меняется, то есть слой растёт вокруг своего текущего центра.
    private func applyLayerSize() {
        let target = CGSize(
            width: contentSize.width + extraSize,
            height: contentSize.height + extraSize
        )
        guard target != bounds.size else { return }
        bounds = CGRect(origin: .zero, size: target)
    }

    /// Пересобирает `transform` из последнего offset'а и действующего фактора.
    ///
    /// Экранная проекция для слоя-соседа скролла: `transform = −backgroundOffset` — фон
    /// уходит в ту же сторону, что контент (E10.7). При нулевом действующем факторе сдвиг
    /// `−0` даёт тот же identity-трансформ. Лишних записей не делает: сравнение трансформа
    /// дешёвое и защищает от лишних перерисовок композитора.
    private func applyTransform() {
        let backgroundOffset = Self.effectiveOffset(
            contentOffset: lastContentOffset,
            factor: resolvedFactor
        )
        // `0 - x`, а не `-x`: при нулевом сдвиге не получаем `-0.0` в трансформе.
        let target = CGAffineTransform(
            translationX: 0 - backgroundOffset.x,
            y: 0 - backgroundOffset.y
        )
        guard transform != target else { return }
        transform = target
    }

    /// Действующий множитель с учётом Reduce Motion (Core §2: «Reduce Motion → фактор 0»).
    ///
    /// Провайдер опрашивается на каждом пересчёте, а не кэшируется: чтение настройки —
    /// дешёвое обращение к системному кэшу. Дополнительно смена настройки на «горячую»
    /// ловится уведомлением `UIAccessibility.reduceMotionStatusDidChangeNotification`
    /// (см. ``commonInit()``), поэтому замороженного сдвига при простое не остаётся.
    private var resolvedFactor: CGFloat {
        if respectsReduceMotion, reduceMotionProvider() { return 0 }
        return factor
    }

    // MARK: - Санитизация входа

    /// Отсекает `factor` в `[0, 1]`; `NaN`/бесконечность → `0`.
    private static func sanitizedFactor(_ raw: CGFloat) -> CGFloat {
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), 1)
    }

    /// Отсекает отрицательный и нечисловой запас размера в `0`.
    private static func sanitizedExtraSize(_ raw: CGFloat) -> CGFloat {
        guard raw.isFinite, raw > 0 else { return 0 }
        return raw
    }

    /// Отсекает отрицательные и нечисловые компоненты размера в `0`.
    private static func sanitizedSize(_ raw: CGSize) -> CGSize {
        CGSize(
            width: raw.width.isFinite && raw.width > 0 ? raw.width : 0,
            height: raw.height.isFinite && raw.height > 0 ? raw.height : 0
        )
    }
}
