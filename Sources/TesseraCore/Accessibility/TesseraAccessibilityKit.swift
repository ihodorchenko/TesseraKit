import UIKit

/// Утилиты доступности общего слоя `TesseraCore`.
///
/// Состав соответствует §1 и §3 проектного документа `docs/Core-iOS-Design.md`:
/// запросы Reduce Motion, анонсы смены страницы и преобразование
/// `UIAccessibilityScrollDirection` в шаг по страницам с учётом направления чтения.
///
/// Публичная поверхность намеренно минимальна (§4: стабильность API) и состоит
/// только из чистых функций и одного чтения системной настройки. Единственный
/// побочный эффект — постановка VoiceOver-анонса в ``announcePageChange(_:)``.
/// Состояние не кешируется: компонент спрашивает значение в момент решения
/// (включение Reduce Motion во время работы приложения должно срабатывать сразу).
public enum TesseraAccessibility {

    /// Включён ли в системе режим «Уменьшение движения» (Reduce Motion).
    ///
    /// Контракт §1 и §2 `docs/Core-iOS-Design.md`: при `true` компоненты отключают
    /// параллакс (фактор 0), флипы плиток и «желе» при редактировании; вместо
    /// самодвижущихся анимаций остаётся статичное состояние. Непрерывный прогресс,
    /// который повторяет жест пользователя, Reduce Motion не отключает.
    public static var isReduceMotionEnabled: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    /// Озвучивает смену страницы через VoiceOver.
    ///
    /// Отправляет системное уведомление `.announcement` — «анонсы смены страницы»
    /// из §1 `docs/Core-iOS-Design.md`. Вызывать по завершении перехода: анонс во
    /// время анимации перебивается сменой accessibility-фокуса, и пользователь
    /// слышит обрывок.
    ///
    /// - Parameter announcement: готовая локализованная строка, например
    ///   «Страница 2 из 5». Метод не форматирует и не переводит текст: строки
    ///   и их локализация — ответственность компонента. Пустая строка игнорируется.
    ///
    /// `UIAccessibility.post` должен выполняться в главном потоке; если метод
    /// вызван не из главного, уведомление переадресуется на главный поток, чтобы
    /// не нарушать правило «вся работа на главном потоке UI» (§3).
    public static func announcePageChange(_ announcement: String) {
        guard !announcement.isEmpty else { return }

        let post = {
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }

        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    /// Шаг по страницам для жеста VoiceOver «три пальца» (`accessibilityScroll`).
    ///
    /// Возвращает `+1` — следующая страница в порядке чтения, `-1` — предыдущая,
    /// `0` — жест не относится к горизонтальной пагинации. Готовое значение
    /// складывается с текущим индексом страницы; пейджер остаётся единственным
    /// писателем `contentOffset` (§2), утилита лишь вычисляет намерение.
    ///
    /// Правила:
    /// - `.right` / `.left` — физические направления свайпа. В LTR `.right`
    ///   ведёт вперёд (`+1`), `.left` — назад (`-1`); в RTL знак инвертируется,
    ///   потому что «вперёд» по направлению чтения — это влево, а `t`
    ///   нормализуется от направления чтения (§2).
    /// - `.next` / `.previous` — не физические, а порядковые направления: они уже
    ///   заданы в порядке чтения, поэтому `.next` всегда даёт `+1`, а `.previous`
    ///   всегда `-1` независимо от `layoutDirection`. Инвертировать их ещё раз
    ///   в RTL нельзя — получится двойное зеркалирование и жест «назад» будет
    ///   листать вперёд.
    /// - `.up` / `.down` и любые будущие значения — вертикальные жесты;
    ///   горизонтальному пейджеру они не адресованы, поэтому `0` (компонент
    ///   передаёт жест ребёнку или игнорирует).
    ///
    /// - Parameters:
    ///   - direction: Направление из `accessibilityScroll(_:)`.
    ///   - layoutDirection: Направление раскладки интерфейса.
    /// - Returns: `+1`, `-1` или `0`.
    public static func pageStep(
        for direction: UIAccessibilityScrollDirection,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> Int {
        let isRightToLeft = layoutDirection == .rightToLeft

        switch direction {
        case .right:
            return isRightToLeft ? -1 : 1
        case .left:
            return isRightToLeft ? 1 : -1
        case .next:
            return 1
        case .previous:
            return -1
        case .up, .down:
            return 0
        @unknown default:
            return 0
        }
    }
}
