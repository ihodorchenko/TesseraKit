//
//  StartScreenView.swift
//  TesseraStartScreen
//
//  SwiftUI-фасад рабочего стола.
//  Контракт: docs/STARTSCREEN-IOS-DESIGN.md — §2 «Архитектура»
//  (StartScreenView → StartScreenViewController; StartScreenDelegate — события
//  тапа и переходов), §3 «Плиточная сетка» (снимок сетки — единственный вход
//  данных), §6 «Страница справа» и §7 «Страница слева» (боковые страницы —
//  только если хост их задал, D13), §8 «Параллакс фона» (обои и множитель),
//  §9 «Accessibility» (VoiceOver, Dynamic Type, RTL) и §14 «Уточнения MVP»
//  (D12–D15 в docs/STATE.md).
//  Задача плана: E4.6.
//
//  Границы ответственности:
//  - фасад не дублирует механику: пейджер, сетка, параллакс, режим
//    редактирования и папки живут в UIKit-ядре (E4.1–E4.5), а SwiftUI-структура
//    только создаёт и обновляет `TesseraStartScreenViewController` и переводит
//    его события в `StartScreenDelegate` (как `PivotView` в E2.5);
//  - данные приходят значением — снимком `TileGridSnapshot`; фасад не владеет
//    `TileStore` и не подписывается на него (правило «один писатель», §6);
//  - `updateUIViewController` — единственное место применения конфигурации:
//    каждое поле сравнивается с текущим состоянием контроллера, поэтому
//    перерисовка SwiftUI не перезагружает страницы и не пересоздаёт пейджер.
//
//  Только iOS 15 API: `UIViewControllerRepresentable` и обычный `ObservableObject`
//  в ядре; `@Observable`, `@Entry` и прочие API новее iOS 15 не используются.
//

#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit
import TesseraCore

// MARK: - Стиль

/// Внешний вид рабочего стола (docs/STARTSCREEN-IOS-DESIGN.md §8, §9).
///
/// Стиль — значение: фасад применяет его на каждом обновлении, а сеттеры
/// контроллера идемпотентны, поэтому повторная установка тех же значений не
/// трогает иерархию и не перезапускает анимации.
///
/// Заголовки страниц нужны VoiceOver (§9): контроллер озвучивает название
/// страницы по завершении перехода. Внутри компонента строки по умолчанию
/// английские (значения совпадают с умолчаниями
/// ``TesseraStartScreenViewController``); хост локализует их, передав свой стиль.
public struct StartScreenStyle {

    /// Обои рабочего стола (§8).
    ///
    /// `nil` (по умолчанию) — обоев нет, видна системная подложка страницы.
    /// Фасад сравнивает обои по ссылке: передавайте стабильный экземпляр
    /// `UIImage`, иначе картинка будет переназначаться на каждой перерисовке.
    public var wallpaper: UIImage?

    /// Множитель параллакса обоев (§8).
    ///
    /// Документ задаёт диапазон `0.4...0.6`; ядро зажимает значение к ближайшей
    /// границе, а `NaN` трактуется как `0.5`. При Reduce Motion действующий
    /// множитель равен нулю (§9), но запас фона считается по заданному — так
    /// включение настройки «на лету» не оставит пустых полос.
    public var wallpaperParallaxFactor: CGFloat

    /// Название страницы-хука для VoiceOver (§7, §9).
    public var quickPanelTitle: String

    /// Название START-страницы для VoiceOver (§9).
    public var startPageTitle: String

    /// Название правой страницы (список приложений) для VoiceOver (§6, §9).
    public var applicationsPageTitle: String

    /// Создаёт стиль рабочего стола.
    ///
    /// - Parameters:
    ///   - wallpaper: Обои; по умолчанию нет.
    ///   - wallpaperParallaxFactor: Множитель параллакса, по умолчанию `0.5`.
    ///   - quickPanelTitle: Название страницы-хука, по умолчанию как в контроллере.
    ///   - startPageTitle: Название START-страницы, по умолчанию как в контроллере.
    ///   - applicationsPageTitle: Название правой страницы, по умолчанию как в контроллере.
    public init(
        wallpaper: UIImage? = nil,
        wallpaperParallaxFactor: CGFloat = 0.5,
        quickPanelTitle: String = "Quick panel",
        startPageTitle: String = "Start",
        applicationsPageTitle: String = "Applications"
    ) {
        self.wallpaper = wallpaper
        self.wallpaperParallaxFactor = wallpaperParallaxFactor
        self.quickPanelTitle = quickPanelTitle
        self.startPageTitle = startPageTitle
        self.applicationsPageTitle = applicationsPageTitle
    }
}

// MARK: - Фасад

/// SwiftUI-представление рабочего стола (docs/STARTSCREEN-IOS-DESIGN.md §2).
///
/// Обёртка над ``TesseraStartScreenViewController``: пейджер (START и две
/// опциональные боковые страницы, D13), вертикальная сетка ярлыков с
/// параллаксом обоев и режим редактирования остаются в UIKit-ядре. Фасад
/// декларативно задаёт снимок сетки, боковые страницы и стиль, а события
/// отдаёт через ``StartScreenDelegate``.
///
/// ```swift
/// @StateObject private var store = TileStore()
///
/// var body: some View {
///     StartScreenView(
///         snapshot: store.snapshot(columns: 6),   // ширина сетки; ячейки и дыры (E14.5)
///         style: StartScreenStyle(startPageTitle: "Начало"),
///         rightPage: { TesseraAppsListPageViewController.make(store: store) },
///         delegate: host
///     )
/// }
/// ```
///
/// ## Обновление
///
/// - снимок сетки применяется, только если видимое состояние элементов
///   действительно изменилось: состав, размеры, подписи, бейджи, иконки,
///   live-провайдер (`liveContent`, по ссылке) и то же самое для ярлыков внутри
///   папок — перерисовка SwiftUI не вызывает `reloadData` и не сбрасывает
///   позицию прокрутки и фокус VoiceOver. Замыкание `action` сравнить нельзя,
///   и ради него сетка не перезагружается: делегат получает ярлык (и папку)
///   из последнего снимка по `id`, то есть с актуальным `action`;
/// - боковые страницы пересобираются при смене «есть/нет» и при смене типа
///   поставщика хука. Новый экземпляр того же типа (например,
///   `QuickPanelProvider`, созданный в `body`) и новая фабрика `rightPage`
///   пейджер не пересобирают: они подменяются «тихо» и используются при
///   следующем создании страницы и для колбэков хука. Чтобы пересоздать уже
///   загруженную боковую страницу, пересоздайте представление (`.id(…)`) или
///   временно передайте `nil`;
/// - стиль применяется всегда, но каждое поле сравнивается с текущим
///   значением контроллера, поэтому лишних layout-проходов нет. Обои
///   сравниваются по ссылке — передавайте стабильный экземпляр `UIImage`, а не
///   создавайте новый на каждой перерисовке.
///
/// Если хост одновременно владеет `TileEditCoordinator`, он анимирует resize,
/// reorder и drag сам. Фасад сравнивает снимок с фактическим состоянием сетки,
/// поэтому уже применённое координатором изменение повторно не перезагружается;
/// обновляйте SwiftUI-состояние после `TileStore.onChange`, чтобы порядок
/// «координатор → SwiftUI» сохранялся.
///
/// ## Раскрытие папок (D17, E7.3)
///
/// По умолчанию тап по папке раскрывает её встроенной панелью сетки: заголовок
/// (в нижнем регистре) и сетка ярлыков (то же число колонок, что у рабочего стола) появляются под строкой
/// папки, строки ниже сдвигаются, иконки идут каскадом. Повторный тап, тап по
/// пустому месту и `Back`/VoiceOver-escape закрывают панель; состояние также
/// снимается, если папка исчезла из снимка.
///
/// Хосту, который показывает собственный экран папки, нужно передать
/// `folderTapHandler`, возвращающий `true`: тогда нативная панель не
/// открывается, а `didTapFolder` не приходит — навигацию выполняет сам
/// перехватчик. Раскрытие и закрытие сообщаются делегату событиями
/// `didExpandFolder`/`didCollapseFolder`.
///
/// ## Делегат
///
/// ``StartScreenDelegate`` — протокол с классовой связностью, а SwiftUI-структура
/// не может хранить `weak`-ссылку. Поэтому фасад передаёт делегата координатору,
/// который удерживает последнее значение ``StartScreenView`` и пробрасывает все
/// колбэки. Делегат удерживается сильной ссылкой, пока представление
/// установлено (как в `PivotView`/`PanoramaView`).
///
/// ## Accessibility (§9)
///
/// Фасад не дублирует доступность ядра, а сохраняет её:
///
/// - плитка — один элемент VoiceOver с заголовком и счётчиком бэйджа, вход и
///   выход из режима редактирования озвучиваются, а `resize`/`unpin` доступны
///   как `UIAccessibilityCustomAction` (E4.2, E4.4);
/// - переходы страниц и видимость хука приходят от контроллера через его
///   UIKit-``TesseraStartScreenViewController/delegate`` (координатор фасада —
///   этот делегат): пейджер не перехватывается, поэтому `accessibilityScroll`,
///   озвучивание названия страницы и колбэки страницы-хука (§7, §9) работают
///   так же, как в UIKit. Контроллер остаётся единственным писателем своего
///   состояния;
/// - VoiceOver-активация плитки идёт тем же путём, что тап пальцем
///   (`gridView.onTap` → делегат), поэтому хост обрабатывает оба способа
///   одинаково;
/// - Dynamic Type и RTL приходят в UIKit из trait-окружения (система/хостинг
///   SwiftUI): фасад не фиксирует шрифты и не выставляет
///   `semanticContentAttribute` принудительно, чтобы не сломать направление,
///   заданное хостом. Зеркалирование сетки, пейджера и jump-list делает ядро
///   (§9, `TesseraRTL`);
/// - Reduce Motion читается ядром из системы (§9); в фасаде нет собственных
///   анимаций, которые нужно было бы отключать.
///
/// - Note: Все колбэки и обновления выполняются на главном потоке.
public struct StartScreenView: UIViewControllerRepresentable {

    // MARK: - Входные данные

    /// Снимок сетки: элементы, их порядок и размеры (§3, D15).
    ///
    /// Снимок — значение из `TileStore`: фасад его только отображает.
    private let snapshot: TileGridSnapshot

    /// Обои, множитель параллакса и названия страниц.
    private let style: StartScreenStyle

    /// Поставщик левой страницы-хука (§7); `nil` — страницы нет (D13).
    private let leftPanel: QuickPanelProviding?

    /// Фабрика правой страницы — списка приложений (§6); `nil` — страницы нет
    /// (D13). Пейджер лениво выгружает страницы ±1, поэтому фабрика может
    /// вызываться повторно и должна возвращать контроллер, который можно
    /// встроить заново.
    private let rightPage: (() -> UIViewController)?

    /// Уступать ли ведущую кромку системному жесту навигации (§1).
    ///
    /// `false` (по умолчанию) — рабочий стол задуман корневым экраном. Политику
    /// нельзя отменить после показа: UIKit не умеет снимать
    /// `require(toFail:)`, поэтому задавайте её сразу, а не на лету.
    private let yieldsLeftEdgeToSystemGesture: Bool

    /// Перехватчик тапа по папке (D17, E7.3).
    ///
    /// `nil` (по умолчанию) — папка раскрывается нативной панелью сетки. Если
    /// замыкание вернуло `true`, нативное раскрытие не выполняется: хост сам
    /// обрабатывает тап (например, показывает прежний экран папки). При `true`
    /// событие ``StartScreenDelegate/startScreen(_:didTapFolder:)`` не приходит,
    /// чтобы навигация не выполнилась дважды.
    private let folderTapHandler: ((TileFolder) -> Bool)?

    /// Наблюдатель событий рабочего стола.
    private let delegate: StartScreenDelegate?

    /// Создаёт фасад рабочего стола.
    ///
    /// - Parameters:
    ///   - snapshot: Снимок сетки (§3); единственный вход данных.
    ///   - style: Внешний вид и названия страниц; по умолчанию системный.
    ///   - leftPanel: Поставщик страницы-хука (§7); `nil` — хука нет (D13).
    ///   - rightPage: Фабрика правой страницы (§6); `nil` — страницы нет (D13).
    ///   - yieldsLeftEdgeToSystemGesture: Политика ведущей кромки (§1);
    ///     по умолчанию `false` — рабочий стол корневой экран.
    ///   - folderTapHandler: Перехватчик тапа по папке (D17); `nil` — нативное
    ///     раскрытие панелью.
    ///   - delegate: Наблюдатель тапов и переходов; необязателен.
    public init(
        snapshot: TileGridSnapshot,
        style: StartScreenStyle = StartScreenStyle(),
        leftPanel: QuickPanelProviding? = nil,
        rightPage: (() -> UIViewController)? = nil,
        yieldsLeftEdgeToSystemGesture: Bool = false,
        folderTapHandler: ((TileFolder) -> Bool)? = nil,
        delegate: StartScreenDelegate? = nil
    ) {
        self.snapshot = snapshot
        self.style = style
        self.leftPanel = leftPanel
        self.rightPage = rightPage
        self.yieldsLeftEdgeToSystemGesture = yieldsLeftEdgeToSystemGesture
        self.folderTapHandler = folderTapHandler
        self.delegate = delegate
    }

    // MARK: - UIViewControllerRepresentable

    /// Создаёт координатор — мост колбэков UIKit в ``StartScreenDelegate``.
    ///
    /// - Returns: Координатор, удерживаемый SwiftUI.
    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Создаёт UIKit-ядро рабочего стола.
    ///
    /// Конфигурация применяется **до** загрузки вида: контроллер собирает
    /// страницы из `leftPanel`/`rightPage` уже в `viewDidLoad` (D13), поэтому
    /// боковые страницы не должны подключаться после первой раскладки.
    ///
    /// - Parameter context: Контекст SwiftUI.
    /// - Returns: Настроенный ``TesseraStartScreenViewController``.
    public func makeUIViewController(
        context: Context
    ) -> TesseraStartScreenViewController {
        let screen = TesseraStartScreenViewController()
        context.coordinator.screenViewController = screen
        context.coordinator.applyConfiguration(self, to: screen, isInitial: true)
        context.coordinator.attach(to: screen)
        return screen
    }

    /// Применяет изменившуюся конфигурацию к живому контроллеру.
    ///
    /// Метод вызывается при каждой перерисовке SwiftUI, поэтому все применения
    /// сравнивают значения с текущим состоянием (см. документацию
    /// ``StartScreenView``): пересборка страниц и перезагрузка сетки случаются
    /// только при реальных изменениях.
    ///
    /// - Parameters:
    ///   - uiViewController: Живой ``TesseraStartScreenViewController``.
    ///   - context: Контекст SwiftUI с координатором.
    public func updateUIViewController(
        _ uiViewController: TesseraStartScreenViewController,
        context: Context
    ) {
        // Координатор хранит последнюю версию описания: иначе делегат видел бы
        // устаревшее состояние после перерисовки SwiftUI.
        context.coordinator.parent = self
        context.coordinator.screenViewController = uiViewController

        context.coordinator.applyConfiguration(self, to: uiViewController, isInitial: false)
        // Страховка: хост мог переназначить UIKit-делегата контроллера.
        context.coordinator.ensureScreenDelegate(on: uiViewController)
    }

    /// Отпускает связи координатора при разборе представления.
    ///
    /// Координатор снимается с UIKit-делегата контроллера и отпускает
    /// замыкания сетки: экран, переживший представление, не удерживает
    /// состояние SwiftUI.
    ///
    /// - Parameters:
    ///   - uiViewController: Разбираемый контроллер.
    ///   - coordinator: Координатор представления.
    public static func dismantleUIViewController(
        _ uiViewController: TesseraStartScreenViewController,
        coordinator: Coordinator
    ) {
        coordinator.detach()
    }

    // MARK: - Сравнение снимков

    /// Сравниваемые признаки ярлыка: то, что видно, озвучивается и живёт.
    ///
    /// `action` не входит: замыкания несравнимы, а сетка действие не исполняет
    /// — делегат получает ярлык из последнего снимка (см. `Coordinator`).
    /// `liveContent` сравнивается по ссылке: смена провайдера (или его
    /// появление) должна дойти до сетки, иначе плитка не станет живой (E10.8).
    fileprivate struct ShortcutSignature: Equatable {
        let id: AnyHashable
        let size: TileSize
        let title: String
        let badge: TileBadge
        let iconIdentifier: ObjectIdentifier?
        let liveContentIdentifier: ObjectIdentifier?

        init(shortcut: TileDescriptor) {
            id = shortcut.id
            size = shortcut.size
            title = shortcut.title
            badge = shortcut.badge
            iconIdentifier = shortcut.icon.map { ObjectIdentifier($0) }
            liveContentIdentifier = shortcut.liveContent.map { ObjectIdentifier($0) }
        }
    }

    /// Сравниваемые признаки элемента сетки.
    ///
    /// `TileGridSnapshot` и `TileGridItem` не `Equatable`: в ярлыке есть
    /// замыкание `action`, у которого нет семантики равенства. Поэтому «то же
    /// самое» определяется тем, что видно и озвучивается: идентификатор,
    /// размер (D15), подпись, бейдж (D12), ссылка на иконку, live-провайдер и
    /// содержимое папки — с подписями и бейджами её ярлыков (превью и панель
    /// папки их показывают, E9.8б). Признак панели раскрытой папки (D17)
    /// входит в подпись отдельным полем: панель и плитка-папка имеют один
    /// идентификатор, но это разные состояния экрана.
    fileprivate struct ItemSignature: Equatable {
        let id: AnyHashable
        let size: TileSize
        let title: String
        let badge: TileBadge
        let iconIdentifier: ObjectIdentifier?
        let liveContentIdentifier: ObjectIdentifier?
        let folderContents: [ShortcutSignature]
        let isFolderPanel: Bool

        init(item: TileGridItem) {
            id = item.id
            size = item.size

            switch item {
            case .tile(let shortcut):
                title = shortcut.title
                badge = shortcut.badge
                iconIdentifier = shortcut.icon.map { ObjectIdentifier($0) }
                liveContentIdentifier = shortcut.liveContent.map { ObjectIdentifier($0) }
                folderContents = []
                isFolderPanel = false
            case .folder(let folder):
                title = folder.title
                // У папки бейджа нет (§4): счётчик внимания — свойство ярлыка.
                badge = .none
                iconIdentifier = folder.icon.map { ObjectIdentifier($0) }
                liveContentIdentifier = nil
                folderContents = folder.tiles.map { ShortcutSignature(shortcut: $0) }
                isFolderPanel = false
            case .folderContent(let folder):
                title = folder.title
                badge = .none
                iconIdentifier = folder.icon.map { ObjectIdentifier($0) }
                liveContentIdentifier = nil
                folderContents = folder.tiles.map { ShortcutSignature(shortcut: $0) }
                isFolderPanel = true
            }
        }
    }

    /// Признаки массива элементов — вход сравнения снимков.
    fileprivate static func signatures(for items: [TileGridItem]) -> [ItemSignature] {
        items.map { ItemSignature(item: $0) }
    }

    /// Зажимает множитель параллакса так же, как ядро (§8: `0.4...0.6`).
    ///
    /// Нужен для сравнения: контроллер уже хранит зажатое значение, поэтому
    /// стиль с `0.9` не должен применяться на каждом обновлении.
    fileprivate static func sanitizedParallaxFactor(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0.4), 0.6)
    }

    /// Тип поставщика хука — стабильный признак для сравнения между
    /// перерисовками.
    ///
    /// Экземпляр поставщика, созданного в `body`, новый на каждой перерисовке,
    /// поэтому сравнение по ссылке пересобирало бы пейджер на каждый кадр
    /// (E10.8). Смена типа — это смена страницы; новый экземпляр того же типа
    /// подменяется без пересборки.
    fileprivate static func providerType(of value: QuickPanelProviding) -> ObjectIdentifier {
        ObjectIdentifier(type(of: value))
    }

    // MARK: - Координатор

    /// Мост событий UIKit-ядра в ``StartScreenDelegate``.
    ///
    /// Живёт столько же, сколько представление: его удерживает SwiftUI, поэтому
    /// слабая ссылка контроллера (``TesseraStartScreenViewController/delegate``)
    /// не теряет наблюдателя между перерисовками. Сам координатор — UIKit-делегат
    /// контроллера: страницы и видимость хука пересылаются хосту как есть, а
    /// тапы сетки (`onTap`) — с ярлыком из последнего снимка.
    public final class Coordinator: NSObject, StartScreenDelegate, TesseraPagerDelegate {

        /// Последняя версия описания из SwiftUI: источник делегата и конфигурации.
        fileprivate var parent: StartScreenView

        /// Контроллер экрана. Слабо: иерархией владеет SwiftUI.
        fileprivate weak var screenViewController: TesseraStartScreenViewController?

        /// Наличие боковых страниц в последней применённой конфигурации (D13).
        ///
        /// Нужно, чтобы не пересобирать страницы на каждой перерисовке SwiftUI:
        /// пересборка останавливает идущий свайп пейджера.
        private var appliedHasLeftPanel: Bool?
        private var appliedHasRightPage: Bool?

        /// Тип последнего применённого поставщика хука (стабильный признак).
        private var appliedLeftPanelType: ObjectIdentifier?

        /// Создаёт координатор поверх описания рабочего стола.
        ///
        /// - Parameter parent: Описание из `makeCoordinator()`.
        fileprivate init(parent: StartScreenView) {
            self.parent = parent
            super.init()
        }

        // MARK: Применение конфигурации

        /// Применяет описание к контроллеру.
        ///
        /// Порядок важен: названия страниц задаются до пересборки пейджера,
        /// политика края — до первого показа (§1), снимок сетки — после
        /// страниц, чтобы не трогать раскладку дважды.
        ///
        /// - Parameters:
        ///   - description: Актуальное описание из SwiftUI.
        ///   - screen: Живой контроллер экрана.
        ///   - isInitial: `true` при создании вида — все поля применяются без
        ///     сравнений.
        fileprivate func applyConfiguration(
            _ description: StartScreenView,
            to screen: TesseraStartScreenViewController,
            isInitial: Bool
        ) {
            apply(style: description.style, to: screen)
            applyEdgePolicy(description.yieldsLeftEdgeToSystemGesture, to: screen)
            applySidePages(
                leftPanel: description.leftPanel,
                rightPage: description.rightPage,
                to: screen,
                force: isInitial
            )
            applyGrid(description.snapshot, to: screen, force: isInitial)
            applyFolderTapHandler(description.folderTapHandler, to: screen)
        }

        /// Применяет стиль, не трогая неизменившиеся поля.
        private func apply(style: StartScreenStyle, to screen: TesseraStartScreenViewController) {
            if screen.wallpaperImage !== style.wallpaper {
                screen.wallpaperImage = style.wallpaper
            }

            let factor = StartScreenView.sanitizedParallaxFactor(style.wallpaperParallaxFactor)
            if factor != screen.wallpaperParallaxFactor {
                screen.wallpaperParallaxFactor = style.wallpaperParallaxFactor
            }

            if screen.quickPanelTitle != style.quickPanelTitle {
                screen.quickPanelTitle = style.quickPanelTitle
            }
            if screen.startPageTitle != style.startPageTitle {
                screen.startPageTitle = style.startPageTitle
            }
            if screen.applicationsPageTitle != style.applicationsPageTitle {
                screen.applicationsPageTitle = style.applicationsPageTitle
            }
        }

        /// Применяет политику ведущей кромки (§1).
        ///
        /// Контроллер сам игнорирует повторную установку того же значения.
        private func applyEdgePolicy(
            _ yieldsEdge: Bool,
            to screen: TesseraStartScreenViewController
        ) {
            guard screen.yieldsLeftEdgeToSystemGesture != yieldsEdge else { return }
            screen.yieldsLeftEdgeToSystemGesture = yieldsEdge
        }

        /// Пересобирает боковые страницы только при смене конфигурации (D13).
        ///
        /// `configure` — «холодный» путь: он пересобирает пейджер (и
        /// останавливает идущий свайп), поэтому вызывается только при смене
        /// наличия страниц или типа поставщика хука. Новые экземпляры при той же
        /// конфигурации (поставщик и фабрика, созданные в `body`) подменяются
        /// без пересборки (E10.8).
        private func applySidePages(
            leftPanel: QuickPanelProviding?,
            rightPage: (() -> UIViewController)?,
            to screen: TesseraStartScreenViewController,
            force: Bool
        ) {
            let hasLeftPanel = leftPanel != nil
            let hasRightPage = rightPage != nil
            let leftPanelType = leftPanel.map { StartScreenView.providerType(of: $0) }

            let needsRebuild = force
                || appliedHasLeftPanel != hasLeftPanel
                || appliedHasRightPage != hasRightPage
                || leftPanelType != appliedLeftPanelType

            appliedHasLeftPanel = hasLeftPanel
            appliedHasRightPage = hasRightPage
            appliedLeftPanelType = leftPanelType

            if needsRebuild {
                screen.configure(leftPanel: leftPanel, rightPage: rightPage)
            } else {
                screen.updateSidePageSources(leftPanel: leftPanel, rightPage: rightPage)
            }
        }

        /// Применяет снимок сетки, если он отличается от показанного (§3).
        ///
        /// Сравнивается не предыдущее описание SwiftUI, а фактическое состояние
        /// сетки: координатору редактирования (E4.4) можно анимировать изменение
        /// раньше, чем придёт перерисовка SwiftUI — тогда повторного
        /// `reloadData` не будет и анимация не сорвётся.
        private func applyGrid(
            _ snapshot: TileGridSnapshot,
            to screen: TesseraStartScreenViewController,
            force: Bool
        ) {
            if !force {
                let desired = StartScreenView.signatures(for: snapshot.items)
                let current = StartScreenView.signatures(for: screen.gridView.items)
                // E14.5: снимок с таблицей явных ячеек (`TileStore.snapshot(columns:)`)
                // меняет раскладку и тогда, когда состав и размеры те же — например,
                // после открепления остаётся дыра. Снимок без таблицы раскладку не
                // задаёт и показанную таблицу не затирает.
                let placementsChanged = snapshot.placementTable != nil
                    && snapshot.placementTable != screen.gridView.snapshot?.placementTable
                guard desired != current || placementsChanged else { return }
            }
            screen.reload(grid: snapshot)
        }

        /// Передаёт сетке перехватчик тапа по папке (D17, E7.3).
        ///
        /// Замыкание не сравнивается: оно небольшое, а присвоение свойства
        /// сетки ничего не пересобирает. Хост может менять перехватчик между
        /// перерисовками SwiftUI.
        private func applyFolderTapHandler(
            _ handler: ((TileFolder) -> Bool)?,
            to screen: TesseraStartScreenViewController
        ) {
            screen.gridView.folderTapHandler = handler
        }

        // MARK: Подключение к ядру

        /// Подключает координатор к живому контроллеру.
        ///
        /// Сетка отдаёт тапы только через `onTap`, поэтому фасад забирает это
        /// замыкание себе: иначе ни тап пальцем, ни активация VoiceOver не
        /// дошли бы до делегата. Хосту, которому нужно своё поведение тапа,
        /// следует использовать ``StartScreenDelegate``, а не переопределять
        /// `onTap` (см. документацию ``StartScreenView``). Переходы страниц и
        /// видимость хука приходят через UIKit-делегат контроллера.
        ///
        /// - Parameter screen: Контроллер, созданный в `makeUIViewController`.
        fileprivate func attach(to screen: TesseraStartScreenViewController) {
            screenViewController = screen

            screen.gridView.onTap = { [weak self] item in
                self?.handleTap(item)
            }
            // D17: раскрытие и закрытие панели папки — события делегата.
            screen.gridView.onFolderExpansionChanged = { [weak self] folder, expanded in
                self?.handleFolderExpansion(folder, expanded: expanded)
            }
            ensureScreenDelegate(on: screen)
        }

        /// Отпускает связи при разборе представления.
        fileprivate func detach() {
            if let screen = screenViewController, screen.delegate === self {
                screen.delegate = nil
            }
            screenViewController?.gridView.onTap = nil
            screenViewController?.gridView.onFolderExpansionChanged = nil
            // Перехватчик принадлежит хосту-представлению: экран, переживший
            // SwiftUI, не должен удерживать замыкание с его состоянием.
            screenViewController?.gridView.folderTapHandler = nil
            screenViewController = nil
        }

        /// Ставит координатор UIKit-делегатом контроллера (если его сменили).
        fileprivate func ensureScreenDelegate(on screen: TesseraStartScreenViewController) {
            if screen.delegate !== self {
                screen.delegate = self
            }
        }

        // MARK: События

        /// Тап по элементу сетки (палец или активация VoiceOver).
        ///
        /// Действие ярлыка не выполняется (D12): компонент сообщает событие, а
        /// `TileDescriptor.action` вызывает хост — иначе действие выполнилось бы
        /// дважды, если хост тоже на него подписан. Ярлык и папка берутся из
        /// последнего снимка SwiftUI по `id`: сетка не перезагружается ради
        /// нового замыкания `action` (оно несравнимо), но делегат получает
        /// актуальное (E10.8).
        private func handleTap(_ item: TileGridItem) {
            guard let screen = screenViewController else { return }

            switch item {
            case .tile(let shortcut):
                parent.delegate?.startScreen(screen, didTapShortcut: latestShortcut(for: shortcut))
            case .folder(let folder):
                // D14/D17: событие тапа по папке. Нативное раскрытие панели
                // выполняет сетка (если перехватчик не запретил).
                parent.delegate?.startScreen(screen, didTapFolder: latestFolder(for: folder))
            case .folderContent:
                // Панель раскрытой папки (D17): тап по её заголовку/пустому
                // месту ничего не меняет; ярлыки внутри обрабатывает панель.
                break
            }
        }

        /// Раскрытие/закрытие панели папки сеткой (D17, E7.3).
        ///
        /// - Parameters:
        ///   - folder: Папка, к которой относится событие.
        ///   - expanded: `true` — панель раскрыта, `false` — свёрнута.
        private func handleFolderExpansion(_ folder: TileFolder, expanded: Bool) {
            guard let screen = screenViewController else { return }
            let latest = latestFolder(for: folder)
            if expanded {
                parent.delegate?.startScreen(screen, didExpandFolder: latest)
            } else {
                parent.delegate?.startScreen(screen, didCollapseFolder: latest)
            }
        }

        /// Ярлык с тем же `id` из последнего снимка (в том числе внутри папки).
        private func latestShortcut(for shortcut: TileDescriptor) -> TileDescriptor {
            for item in parent.snapshot.items {
                switch item {
                case .tile(let candidate) where candidate.id == shortcut.id:
                    return candidate
                case .folder(let folder), .folderContent(let folder):
                    if let candidate = folder.tiles.first(where: { $0.id == shortcut.id }) {
                        return candidate
                    }
                default:
                    continue
                }
            }
            return shortcut
        }

        /// Папка с тем же `id` из последнего снимка.
        private func latestFolder(for folder: TileFolder) -> TileFolder {
            for item in parent.snapshot.items {
                if case .folder(let candidate) = item, candidate.id == folder.id {
                    return candidate
                }
            }
            return folder
        }

        // MARK: StartScreenDelegate (мост UIKit → хост)

        /// Смена страницы — пересылается делегату хоста как есть.
        ///
        /// - Parameters:
        ///   - screen: Контроллер-источник события.
        ///   - page: Показанная страница.
        ///   - index: Индекс в порядке чтения.
        public func startScreen(
            _ screen: TesseraStartScreenViewController,
            didChangePage page: TesseraStartScreenPage,
            index: Int
        ) {
            parent.delegate?.startScreen(screen, didChangePage: page, index: index)
        }

        /// Видимость хука — пересылается делегату хоста как есть (в том числе
        /// при появлении и уходе экрана, §7).
        ///
        /// - Parameters:
        ///   - screen: Контроллер-источник события.
        ///   - isVisible: Видна ли страница-хук.
        public func startScreen(
            _ screen: TesseraStartScreenViewController,
            didChangeHookVisibility isVisible: Bool
        ) {
            parent.delegate?.startScreen(screen, didChangeHookVisibility: isVisible)
        }

        // MARK: Устаревший прокси пейджера

        /// Устаревший путь: координатор больше не делегат пейджера.
        ///
        /// Переходы приходят через ``TesseraStartScreenViewController/delegate``
        /// (E10.8). Метод оставлен ради стабильности публичной поверхности и
        /// лишь пересылает событие контроллеру.
        ///
        /// - Parameters:
        ///   - pager: Пейджер-источник события.
        ///   - index: Показанная страница в порядке чтения.
        @available(*, deprecated, message: "Переходы страниц приходят через TesseraStartScreenViewController.delegate")
        public func pager(
            _ pager: TesseraPagerViewController,
            didShowPageAt index: Int
        ) {
            screenViewController?.pager(pager, didShowPageAt: index)
        }
    }
}
#endif
