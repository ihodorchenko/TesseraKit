// TesseraGestureArbiter — арбитраж жестов «родитель-ребёнок» для TesseraCore.
// Проектный документ: docs/Core-iOS-Design.md,
// §2 «Ключевые контракты» (пункт «Арбитраж») и §3 «Концептуальная поверхность API».
//
// Схема (вариант B): горизонталью владеет пейджер (horizontalOwner), вертикалью —
// дочерние скролл-вью (verticalOwners). Пейджер решает, начинать ли собственный пан,
// по доминирующей оси в `gestureRecognizerShouldBegin`; на время горизонтального
// жеста прокрутка детей блокируется и затем восстанавливается.
//
// Дисциплина §2 «Дисциплина производительности»: здесь нет layout-операций.
// Методы только читают velocity/translation и меняют флаг `isScrollEnabled`.

import UIKit

/// Доминирующая ось жеста в арбитраже «родитель-ребёнок».
///
/// См. docs/Core-iOS-Design.md §2 «Арбитраж»: горизонталь отдаётся пейджеру,
/// вертикаль — дочернему скролл-вью.
public enum TesseraGestureAxis: Equatable {
    /// Горизонтальное движение: жест обрабатывает пейджер-владелец.
    case horizontal
    /// Вертикальное движение: жест обрабатывают дочерние скролл-вью.
    case vertical
}

/// Арбитр жестов «родитель-ребёнок»: распределяет жест между горизонтальным
/// пейджером и вертикальными детьми по доминирующей оси.
///
/// Контракт (docs/Core-iOS-Design.md §2 «Арбитраж»): пейджер скроллит только
/// горизонтально, дети — вертикально; решение принимается по доминирующей оси
/// в `gestureRecognizerShouldBegin`, а не постфактум. Поддерживается несколько
/// детей (например, сетка и список на одном экране StartScreen).
///
/// Использование.
///
/// - Important: **Не назначайте арбитр делегатом пана `UIScrollView`.**
///   Делегатом встроенного `panGestureRecognizer` скролл-вью обязан оставаться
///   сам скролл-вью: строка `scrollView.panGestureRecognizer.delegate = arbiter`
///   приводит к исключению UIKit (`NSInvalidArgumentException`: «UIScrollView's
///   built-in pan gesture recognizer must have its scroll view as its
///   delegate»). Пейджер TesseraKit построен на `UIScrollView`, поэтому
///   этот путь для него закрыт.
///
/// Рабочая схема (так делают Pivot, Panorama и StartScreen): подписаться на пан
/// скролл-вью аддитивно через `addTarget` — это не трогает его делегата и
/// внутреннюю обработку жестов — и на состоянии `.began` принять решение по оси
/// чистой функцией ``axisDecision(forVelocity:)``. При горизонтали собрать
/// арбитр и заблокировать детей, по завершении жеста — восстановить:
///
/// ```swift
/// // Один раз, когда скролл-вью пейджера известен:
/// pagerScrollView.panGestureRecognizer.addTarget(
///     self, action: #selector(pagerPanDidChange(_:)))
///
/// @objc private func pagerPanDidChange(_ pan: UIPanGestureRecognizer) {
///     switch pan.state {
///     case .began:
///         let velocity = pan.velocity(in: pan.view)
///         let vector = velocity == .zero ? pan.translation(in: pan.view) : velocity
///         guard TesseraGestureArbiter.axisDecision(forVelocity: vector) == .horizontal
///         else { return } // вертикаль — детям, ничего не блокируем
///         let arbiter = TesseraGestureArbiter(horizontalOwner: pagerScrollView,
///                                             verticalOwners: [grid, list])
///         arbiter.prepareForHorizontalScroll() // блокировка детей
///         gestureArbiter = arbiter             // арбитр держит владелец
///     case .ended, .cancelled, .failed:
///         gestureArbiter?.endHorizontalScroll() // восстановление детей
///         gestureArbiter = nil
///     default:
///         break
///     }
/// }
/// ```
///
/// `UIGestureRecognizer` держит таргеты слабо (проверено тестом
/// `TesseraGestureTargetRetentionTests`), поэтому `addTarget(self, …)` не
/// создаёт цикла удержания и `deinit` владельца достижим.
///
/// ``gestureRecognizerShouldBegin(_:)`` (решение до начала жеста, как в §2)
/// применим только там, где делегата можно назначить законно: для
/// **собственного** `UIPanGestureRecognizer` горизонтального владельца, либо
/// из переопределения `gestureRecognizerShouldBegin(_:)` в подклассе
/// `UIScrollView` (метод `UIView`, вызывается для жестов этого вида, делегата
/// не требует) — например, `return arbiter?.shouldBegin(gestureRecognizer) ??
/// super.gestureRecognizerShouldBegin(gestureRecognizer)`.
///
/// Арбитр не удерживается скролл-вью, поэтому его должен удерживать владелец
/// (пейджер или контроллер). Он сильно держит переданные скролл-вью, поэтому
/// при ленивой загрузке страниц удобно создавать его на время жеста.
///
/// Все методы рассчитаны на главный поток: UIKit-свойства и жесты читаются
/// и меняются только там. Layout не выполняется.
public final class TesseraGestureArbiter: NSObject, UIGestureRecognizerDelegate {

    // MARK: - Владельцы

    /// Горизонтальный владелец: пейджер, чей пан арбитр пропускает или отклоняет.
    private let horizontalOwner: UIScrollView

    /// Вертикальные дети. Хранятся в порядке регистрации, без дублей;
    /// горизонтальный владелец исключён при инициализации.
    private let verticalOwners: [UIScrollView]

    /// Снимок `isScrollEnabled` детей на время горизонтального жеста.
    /// `nil` — горизонтальный жест не идёт, блокировки нет.
    private var savedChildStates: [(view: UIScrollView, wasScrollEnabled: Bool)]?

    // MARK: - Инициализация

    /// Создаёт арбитр для пары «горизонтальный пейджер — вертикальные дети».
    ///
    /// - Parameters:
    ///   - horizontalOwner: скролл-вью пейджера, который скроллит только по горизонтали.
    ///   - verticalOwners: дочерние скролл-вью, скроллящие по вертикали. Порядок
    ///     сохраняется; дубли и сам `horizontalOwner` отбрасываются, чтобы арбитр
    ///     не отключал прокрутку владельца.
    ///
    /// Делегат пана не назначается и не должен назначаться для встроенного
    /// пана `UIScrollView` (UIKit бросит исключение) — см. рецепт в описании типа.
    public init(horizontalOwner: UIScrollView, verticalOwners: [UIScrollView]) {
        self.horizontalOwner = horizontalOwner

        // Регистрация детей: только уникальные экземпляры и никогда — сам владелец.
        var registered: [UIScrollView] = []
        registered.reserveCapacity(verticalOwners.count)
        for child in verticalOwners {
            guard child !== horizontalOwner else { continue }
            guard !registered.contains(where: { $0 === child }) else { continue }
            registered.append(child)
        }
        self.verticalOwners = registered

        super.init()
    }

    // MARK: - Решение по оси

    /// Определяет доминирующую ось жеста по вектору скорости.
    ///
    /// Чистая функция без состояния и UIKit-побочных эффектов — основной объект
    /// контрактных тестов арбитража.
    ///
    /// Правило: горизонталь, если `|dx| > |dy|`; вертикаль, если `|dx| < |dy|`.
    /// **При равенстве модулей (в том числе при нулевой скорости) побеждает
    /// горизонталь** — это осознанный дефолт: без данных о доминировании жест
    /// остаётся у пейджера, а не «залипает» у ребёнка. Знак скорости не важен,
    /// сравниваются модули; направление в RTL нормализует сам пейджер,
    /// к выбору оси это не относится.
    ///
    /// - Parameter velocity: вектор скорости жеста (точки в секунду или точки —
    ///   важна лишь относительная величина компонент).
    /// - Returns: `.horizontal`, если `|dx| >= |dy|`; иначе `.vertical`.
    public static func axisDecision(forVelocity velocity: CGPoint) -> TesseraGestureAxis {
        abs(velocity.x) >= abs(velocity.y) ? .horizontal : .vertical
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Публичное решение «начинать ли жест».
    ///
    /// Для пана горизонтального владельца: если доминирующая ось вертикальная,
    /// возвращается `false` — пейджер жест не начинает, и вертикальный скролл
    /// остаётся детям. Остальные жесты (делегат могли назначить и им) не
    /// ограничиваются — возвращается `true`.
    ///
    /// - Parameter gestureRecognizer: проверяемый распознаватель.
    /// - Returns: `true`, если жест может начаться.
    public func shouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === horizontalOwner.panGestureRecognizer else {
            return true
        }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }

        let axis = TesseraGestureArbiter.axisDecision(forVelocity: effectiveVelocity(of: pan))
        return axis == .horizontal
    }

    /// Мост к UIKit: `UIGestureRecognizerDelegate` вызывает именно этот метод.
    /// Решение делегируется публичному `shouldBegin(_:)`, чтобы логика оставалась
    /// тестируемой без подмены протокола.
    ///
    /// Срабатывает, только если арбитр законно назначен делегатом жеста —
    /// для встроенного пана `UIScrollView` это невозможно (см. описание типа).
    @objc public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        shouldBegin(gestureRecognizer)
    }

    // MARK: - Блокировка детей на время горизонтального жеста

    /// Блокирует прокрутку всех вертикальных детей на время горизонтального жеста:
    /// запоминает текущие `isScrollEnabled` и выставляет `false`.
    ///
    /// Вызывается в начале горизонтального скролла пейджера (например, из
    /// `scrollViewWillBeginDragging`). Layout не выполняется — меняется только
    /// флаг прокрутки. Повторный вызов идемпотентен: снимок не перезаписывается,
    /// поэтому исходные значения не теряются.
    public func prepareForHorizontalScroll() {
        // Уже блокируем — сохраняем первый (истинный) снимок.
        guard savedChildStates == nil else { return }

        var saved: [(view: UIScrollView, wasScrollEnabled: Bool)] = []
        saved.reserveCapacity(verticalOwners.count)
        for child in verticalOwners {
            saved.append((view: child, wasScrollEnabled: child.isScrollEnabled))
            child.isScrollEnabled = false
        }
        savedChildStates = saved
    }

    /// Восстанавливает прокрутку детей после горизонтального жеста: возвращает
    /// каждому ровно то значение `isScrollEnabled`, что было до блокировки
    /// (изначально выключенным детям останется `false`).
    ///
    /// Вызывается по завершении горизонтального скролла пейджера (например, из
    /// `scrollViewDidEndDragging`/`scrollViewDidEndDecelerating`). Вызов без
    /// предшествующего `prepareForHorizontalScroll()` — no-op. Layout не выполняется.
    public func endHorizontalScroll() {
        guard let saved = savedChildStates else { return }
        // Сбрасываем снимок до восстановления: повторный вызов станет no-op.
        savedChildStates = nil
        for entry in saved {
            entry.view.isScrollEnabled = entry.wasScrollEnabled
        }
    }

    // MARK: - Внутреннее

    /// Скорость пана с запасным путём по смещению.
    ///
    /// В `gestureRecognizerShouldBegin` UIKit обычно уже даёт ненулевой velocity.
    /// Если он нулевой (жест только начался / вырожденный ввод), доминирующую ось
    /// определяем по `translation`: для отношения `|dx|` и `|dy|` масштаб не важен,
    /// поэтому та же чистая функция применима к смещению.
    private func effectiveVelocity(of pan: UIPanGestureRecognizer) -> CGPoint {
        let velocity = pan.velocity(in: pan.view)
        guard velocity == .zero else { return velocity }
        return pan.translation(in: pan.view)
    }
}
