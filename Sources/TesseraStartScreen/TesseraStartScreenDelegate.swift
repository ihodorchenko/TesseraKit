// Делегат рабочего стола (Start Screen).
//
// Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md
//  - §2 «Архитектура»: `TesseraStartScreenDelegate` — события рабочего стола
//    (тап, переходы страниц, хук); модель и раскладка живут отдельно;
//  - §6 «Страница справа: список приложений + настройки» и §7 «Страница
//    слева: хук»: действия ярлыков и навигация — забота хоста, компонент
//    только сообщает о намерении;
//  - §9 «Accessibility»: доступность плиток, режима редактирования и озвучивание
//    страниц выполняет UIKit-ядро (`TesseraTileGridView` E4.2,
//    `TesseraTileEditCoordinator` E4.4, `TesseraStartScreenViewController`
//    E4.1); делегат — наблюдатель и ничего не дублирует и не озвучивает;
//  - §14 «Уточнения MVP» п. 1–2 и D12/D13 в docs/STATE.md: ярлык — просто
//    действие (без поля `type`), боковые страницы опциональны.
//
// Задача плана: E4.6 (SwiftUI-фасад + accessibility).
//
// Делегат — единственный канал событий фасада: UIKit-ядро отдаёт тапы сетки и
// переходы пейджера, а фасад переводит их в этот протокол. Все методы
// вызываются на главном потоке; обязательных методов нет, поэтому хост
// подписывается только на нужные события (пустые реализации — в extension).

#if canImport(UIKit)
import UIKit

/// Наблюдатель событий рабочего стола (docs/STARTSCREEN-IOS-DESIGN.md §2).
///
/// Делегат только читает состояние и реагирует на действия пользователя:
/// модель (`TesseraTileStore`) и раскладку (`TileGridView`) он не меняет — это правило
/// «один писатель» из §6 и `docs/CORE-IOS-DESIGN.md` §2. Если нужно изменить
/// состав ярлыков (pin/unpin, resize, папки), хост делает это через `TesseraTileStore` и
/// передаёт фасаду новый снимок сетки.
///
/// ## Что фасад НЕ делает сам (D12)
///
/// Тап по ярлыку — это событие ``startScreen(_:didTapShortcut:)``, а **не**
/// вызов `TesseraTileDescriptor.action`. Действие ярлыка выполняет хост: так D12
/// («ярлык — просто действие») остаётся в одном месте, а хост может добавить
/// аналитику, защиту от повторного тапа или навигацию до запуска действия.
/// Если вызывать `action` ещё и в фасаде, действие выполнилось бы дважды.
///
/// ```swift
/// final class Host: TesseraStartScreenDelegate {
///     func startScreen(
///         _ screen: TesseraStartScreenViewController,
///         didTapShortcut shortcut: TesseraTileDescriptor
///     ) {
///         shortcut.action()
///     }
/// }
/// ```
///
/// ## Accessibility (§9)
///
/// VoiceOver-активация плитки приходит тем же путём, что и тап пальцем
/// (`accessibilityActivate` ячейки → `onTap` сетки), поэтому делегату не нужно
/// различать способы ввода:
///
/// - плитка уже один элемент с заголовком и счётчиком бэйджа (E4.2);
/// - в режиме редактирования `resize`/`unpin` доступны как
///   `UIAccessibilityCustomAction`, а вход и выход озвучиваются (E4.4);
/// - листание страниц жестом VoiceOver и озвучивание названия страницы делает
///   контроллер (E4.1) — фасад лишь не перекрывает это поведение, пробрасывая
///   события пейджера в контроллер.
///
/// - Note: В режиме редактирования сетка продолжает сообщать тапы — координатор
///   редактирования (E4.4) их не перехватывает. Если хост подключил
///   `TesseraTileEditCoordinator`, решение «реагировать или нет» принимает он
///   сам по своему `isEditing` (docs/STARTSCREEN-IOS-DESIGN.md §5).
///
/// - Note: Делегат удерживается фасадом сильной ссылкой (SwiftUI-структура не
///   умеет хранить `weak`). Если делегат держит SwiftUI-состояние, используйте
///   промежуточный объект, чтобы не создать цикл.
public protocol TesseraStartScreenDelegate: AnyObject {

    /// Пользователь выбрал ярлык (тап пальцем или активация VoiceOver).
    ///
    /// Ярлык приходит из снимка сетки — с идентификатором, заголовком, иконкой,
    /// бейджем, размером и действием (D12). Фасад **не** вызывает
    /// `TesseraTileDescriptor.action`: это решение хоста (см. документацию протокола).
    /// Папки приходят отдельным событием ``startScreen(_:didTapFolder:)``.
    ///
    /// - Parameters:
    ///   - screen: Контроллер-источник события.
    ///   - shortcut: Выбранный ярлык.
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didTapShortcut shortcut: TesseraTileDescriptor
    )

    /// Пользователь выбрал папку на сетке.
    ///
    /// Открытие папки — навигация хоста (D14): фасад не показывает собственный
    /// экран папки. Если хост использует `TesseraTileEditCoordinator`, он может
    /// передать папку в ``TesseraTileEditCoordinator/openFolder(_:)``; иначе
    /// показывает свой контроллер.
    ///
    /// - Note: С D17 (E7.3) по умолчанию папка дополнительно раскрывается
    ///   нативной панелью сетки, поэтому событие — «палец коснулся папки», а не
    ///   команда показа экрана. Чтобы сохранить прежнее поведение (свой экран
    ///   без встроенной панели), задайте перехватчик в `TesseraStartScreenView`.
    ///
    /// - Parameters:
    ///   - screen: Контроллер-источник события.
    ///   - folder: Выбранная папка вместе с ярлыками.
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didTapFolder folder: TesseraTileFolder
    )

    /// Сетка раскрыла папку нативной панелью (D17, E7.3).
    ///
    /// Событие приходит после анимации раскрытия: панель уже вставлена, строки
    /// ниже сдвинуты, иконки начинают каскад. Хост может использовать его для
    /// аналитики или синхронизации своего состояния; менять снимок сетки в
    /// колбэке не нужно — раскрытие уже выполнено.
    ///
    /// - Parameters:
    ///   - screen: Контроллер-источник события.
    ///   - folder: Раскрытая папка.
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didExpandFolder folder: TesseraTileFolder
    )

    /// Сетка свернула нативную панель папки (D17, E7.3).
    ///
    /// Приходит и при закрытии по повторному тапу, тапу по пустому месту,
    /// вызову ``TesseraTileGridView/closeFolder(animated:)`` или `Back`, и при
    /// исчезновении открытой папки из снимка (модель распустила папку).
    ///
    /// - Parameters:
    ///   - screen: Контроллер-источник события.
    ///   - folder: Свёрнутая папка.
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didCollapseFolder folder: TesseraTileFolder
    )

    /// Пейджер завершил переход и показывает новую страницу.
    ///
    /// Индекс — в порядке чтения (Core нормализует его с учётом RTL): `0` —
    /// первая страница для пользователя, независимо от LTR/RTL. Набор страниц
    /// зависит от конфигурации (D13): боковые страницы существуют, только если
    /// хост их задал, поэтому индекс `0` — это либо хук, либо START.
    ///
    /// Событие приходит по завершении перехода (жестом или программно), а не на
    /// кадрах прокрутки: непрерывный прогресс рабочему столу не нужен, а
    /// покадровые вызовы заставляли бы SwiftUI перерисовываться на каждом кадре.
    ///
    /// - Parameters:
    ///   - screen: Контроллер-источник события.
    ///   - page: Показанная страница в порядке чтения.
    ///   - index: Индекс страницы в порядке чтения.
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didChangePage page: TesseraStartScreenPage,
        index: Int
    )

    /// Изменилась видимость страницы-хука (§7).
    ///
    /// `true` — хук сейчас на экране (пользователь листает пейджер или хост
    /// показал его программно), `false` — ушёл с экрана. Событие нужно для
    /// ленивой загрузки контента хука на уровне экрана; сам
    /// ``TesseraQuickPanelProviding`` дополнительно получает `quickPanelWillAppear` /
    /// `quickPanelDidDisappear` от контроллера, поэтому обычно достаточно их.
    ///
    /// Событие приходит только при смене значения — при первом переходе на
    /// START, если хук не показывался, вызова не будет.
    ///
    /// - Parameters:
    ///   - screen: Контроллер-источник события.
    ///   - isVisible: `true`, если страница-хук сейчас на экране.
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didChangeHookVisibility isVisible: Bool
    )
}

public extension TesseraStartScreenDelegate {

    /// По умолчанию тап по ярлыку игнорируется: хост подписывается на нужные
    /// события выборочно (docs/STARTSCREEN-IOS-DESIGN.md §2).
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didTapShortcut shortcut: TesseraTileDescriptor
    ) {}

    /// По умолчанию папка не открывается: навигация — за хостом (D14).
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didTapFolder folder: TesseraTileFolder
    ) {}

    /// По умолчанию раскрытие папки не интересует делегата (D17).
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didExpandFolder folder: TesseraTileFolder
    ) {}

    /// По умолчанию закрытие папки не интересует делегата (D17).
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didCollapseFolder folder: TesseraTileFolder
    ) {}

    /// По умолчанию смена страницы не интересует делегата.
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didChangePage page: TesseraStartScreenPage,
        index: Int
    ) {}

    /// По умолчанию видимость хука не интересует делегата.
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didChangeHookVisibility isVisible: Bool
    ) {}
}
#endif
