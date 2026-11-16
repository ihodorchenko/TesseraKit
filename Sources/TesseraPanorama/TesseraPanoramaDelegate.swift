// Делегат панорамы.
// Проектный документ: docs/PANORAMA-IOS-DESIGN.md — §3 «Концептуальная архитектура»
// (TesseraPanoramaDelegate — didShowSection, didChangeProgress) и §4 «Геометрия и
// математика ядра» (единый прогресс t, никакого layout в scrollViewDidScroll).

#if canImport(UIKit)
import UIKit

/// Наблюдатель состояния панорамы.
///
/// Делегат только читает состояние: `contentOffset` пишут исключительно жест
/// панорамы и программный переход контроллера (docs/PANORAMA-IOS-DESIGN.md §4,
/// «Правило производительности» и инвариант одного писателя из
/// docs/CORE-IOS-DESIGN.md §2). Возвращать значения или записывать offset из
/// колбэков нельзя — это создаёт цикл обратной связи: фон и заголовки уже
/// анимируются от того же `t`.
///
/// Все методы вызываются на главном потоке. Оба метода — опциональные события:
/// в расширении ниже есть пустые реализации по умолчанию, поэтому делегат
/// вправе реализовать только нужные ему события.
public protocol TesseraPanoramaDelegate: AnyObject {

    /// Панорама показала секцию `index`.
    ///
    /// Индекс — в порядке чтения: `0` — первая секция для пользователя,
    /// независимо от LTR/RTL (документ §7, «RTL»). Вызывается по завершении
    /// перехода (жестом или программно), когда активной стала секция `index`;
    /// удобен для озвучивания заголовка секции (документ §7, «VoiceOver») и для
    /// внешней аналитики.
    ///
    /// - Parameters:
    ///   - panorama: Панорама-источник события.
    ///   - index: Индекс показанной секции в порядке чтения.
    func panorama(_ panorama: TesseraPanoramaViewController, didShowSectionAt index: Int)

    /// Непрерывный прогресс прокрутки изменился.
    ///
    /// Значение нормализовано по направлению чтения (документ §7, «RTL»):
    /// `0` — первая секция, `sectionCount - 1` — последняя. Целая часть —
    /// индекс секции, дробная — прогресс перехода; шаг секции —
    /// `itemWidth = screenWidth − peek` (документ §4, «Ширина секции»).
    /// При оттягивании за край (`bounce`) значение может выходить за пределы
    /// диапазона — потребитель сам решает, как его ограничить.
    ///
    /// Метод вызывается из `scrollViewDidScroll`; в этот момент выполняется
    /// только `frame`/`transform`/`alpha`, layout не запускается
    /// (документ §4, «Правило производительности»).
    ///
    /// - Parameters:
    ///   - panorama: Панорама-источник события.
    ///   - t: Нормализованный прогресс `t = contentOffset.x / itemWidth`.
    func panorama(_ panorama: TesseraPanoramaViewController, didChangeProgress t: CGFloat)
}

public extension TesseraPanoramaDelegate {
    /// Реализация по умолчанию: показ секции не интересует делегата.
    func panorama(_ panorama: TesseraPanoramaViewController, didShowSectionAt index: Int) {}

    /// Реализация по умолчанию: прогресс не интересует делегата.
    func panorama(_ panorama: TesseraPanoramaViewController, didChangeProgress t: CGFloat) {}
}
#endif
