// Делегат пейджера TesseraCore.
// Проектный документ: docs/Core-iOS-Design.md — §2 «Ключевые контракты»
// (инвариант прогресса, один писатель contentOffset) и §3 «Концептуальная
// поверхность API» (TesseraPagerDelegate — didShowPage, didChangeProgress).

#if canImport(UIKit)
import UIKit

/// Наблюдатель состояния `TesseraPagerViewController`.
///
/// Делегат только читает состояние: `contentOffset` пишут исключительно жест
/// пейджера и программный переход контроллера
/// (docs/Core-iOS-Design.md §2, «Один писатель»). Возвращать значения или
/// записывать offset из колбэков нельзя — это создаёт цикл обратной связи.
///
/// Оба метода вызываются на главном потоке. Реализации по умолчанию пусты,
/// чтобы делегат мог подписаться только на нужное событие.
public protocol TesseraPagerDelegate: AnyObject {
    /// Пейджер завершил переход и показывает страницу `index`.
    ///
    /// Индекс — в порядке чтения: `0` — первая страница для пользователя,
    /// независимо от LTR/RTL (нормализация через `TesseraRTL`).
    /// Вызывается по завершении перехода
    /// (`scrollViewDidEndDecelerating` / `scrollViewDidEndScrollingAnimation`),
    /// а также после мгновенного `go(toPage:animated: false)`. Показ начальной
    /// страницы без перехода отдельным событием не является.
    ///
    /// - Parameters:
    ///   - pager: Пейджер-источник события.
    ///   - index: Индекс показанной страницы в порядке чтения.
    func pager(_ pager: TesseraPagerViewController, didShowPageAt index: Int)

    /// Непрерывный прогресс прокрутки изменился.
    ///
    /// Значение нормализовано по направлению чтения
    /// (docs/Core-iOS-Design.md §2, «Инвариант прогресса»): `0` — первая
    /// страница, `pageCount - 1` — последняя. Целая часть — индекс страницы,
    /// дробная — прогресс перехода. При оттягивании за край (`bounce`) значение
    /// может выходить за пределы диапазона — потребитель сам решает, как его
    /// ограничить.
    ///
    /// Метод вызывается из `scrollViewDidScroll`; layout в этот момент не
    /// выполняется (docs/Core-iOS-Design.md §2, «Дисциплина производительности»).
    ///
    /// - Parameters:
    ///   - pager: Пейджер-источник события.
    ///   - t: Нормализованный прогресс `t = contentOffset.x / pageWidth`.
    func pager(_ pager: TesseraPagerViewController, didChangeProgress t: CGFloat)
}

public extension TesseraPagerDelegate {
    /// Реализация по умолчанию: смена страницы не интересует делегата.
    func pager(_ pager: TesseraPagerViewController, didShowPageAt index: Int) {}

    /// Реализация по умолчанию: прогресс не интересует делегата.
    func pager(_ pager: TesseraPagerViewController, didChangeProgress t: CGFloat) {}
}
#endif
