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
///         snapshot: store.snapshot(),
///         style: StartScreenStyle(startPageTitle: "Начало"),
///         rightPage: { TesseraAppsListPageViewController.make(store: store) },
///         delegate: host
///     )
/// }
/// ```
///
/// ## Обновление
///
/// - снимок сетки применяется, только если состав/размеры/подписи/бейджи
///   элементов действительно изменились (сравнение по значению) — перерисовка
///   SwiftUI не вызывает `reloadData` и не сбрасывает позицию прокрутки и фокус
///   VoiceOver;
/// - боковые страницы пересобираются при смене «есть/нет»; замена классового
///   `QuickPanelProviding` другим экземпляром тоже подхватывается — провайдер
///   сравнивается по ссылке. А вот фабрику `rightPage` и значимые (`struct`)
///   провайдеры сравнить нельзя, поэтому их замена при том же наличии не
///   обнаруживается: пересоздайте представление (например, `.id(…)`) или
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
/// (в нижнем регистре) и четырёхколоночная сетка ярлыков появляются под строкой
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
/// - чтобы делегат получал переходы страниц, координатор на время жизни
///   представления становится делегатом пейджера **и пробрасывает событие
///   контроллеру**: без этого перестали бы работать `accessibilityScroll`,
///   озвучивание названия страницы и колбэки страницы-хука (§7, §9).
///   Контроллер остаётся единственным писателем своего состояния;
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
        // Страховка: контроллер ставит себя делегатом пейджера в `viewDidLoad`;
        // если вид когда-либо перезагрузится, подмена восстановится.
        context.coordinator.ensurePagerDelegate(on: uiViewController)
    }

    /// Отпускает связи координатора при разборе представления.
    ///
    /// Делегат пейджера возвращается контроллеру (а не остаётся висящим на
    /// координаторе), чтобы экран, переживший представление, продолжал
    /// обрабатывать прокрутку и VoiceOver-жесты штатно.
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

    /// Сравниваемые признаки элемента сетки.
    ///
    /// `TileGridSnapshot` и `TileGridItem` не `Equatable`: в ярлыке есть
    /// замыкание `action`, у которого нет семантики равенства. Поэтому «то же
    /// самое» определяется тем, что видно и озвучивается: идентификатор,
    /// размер (D15), подпись, бейдж (D12), ссылка на иконку и состав папки.
    /// Признак панели раскрытой папки (D17) входит в подпись отдельным полем:
    /// панель и плитка-папка имеют один идентификатор, но это разные состояния
    /// экрана.
    /// Действие и порядок сравниваются по идентификатору — если хост заменил
    /// `action` у ярлыка с тем же `id`, перезагрузка не нужна: сетка действие не
    /// хранит.
    fileprivate struct ItemSignature: Equatable {
        let id: AnyHashable
        let size: TileSize
        let title: String
        let badge: TileBadge
        let iconIdentifier: ObjectIdentifier?
        let folderTileIdentifiers: [AnyHashable]
        let isFolderPanel: Bool

        init(item: TileGridItem) {
            id = item.id
            size = item.size

            switch item {
            case .tile(let shortcut):
                title = shortcut.title
                badge = shortcut.badge
                iconIdentifier = shortcut.icon.map { ObjectIdentifier($0) }
                folderTileIdentifiers = []
                isFolderPanel = false
            case .folder(let folder):
                title = folder.title
                // У папки бейджа нет (§4): счётчик внимания — свойство ярлыка.
                badge = .none
                iconIdentifier = folder.icon.map { ObjectIdentifier($0) }
                folderTileIdentifiers = folder.tiles.map { $0.id }
                isFolderPanel = false
            case .folderContent(let folder):
                title = folder.title
                badge = .none
                iconIdentifier = folder.icon.map { ObjectIdentifier($0) }
                folderTileIdentifiers = folder.tiles.map { $0.id }
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

    /// Ссылочная идентичность классового значения, если она есть.
    ///
    /// `QuickPanelProviding` не требует классовой связности, а значимые типы
    /// нельзя сравнивать по ссылке (бокс каждый раз новый). Поэтому для структур
    /// возвращается `nil`, и смена провайдера при том же наличии не
    /// обнаруживается — это задокументированное ограничение ``StartScreenView``.
    fileprivate static func referenceIdentity(of value: Any) -> ObjectIdentifier? {
        guard Mirror(reflecting: value).displayStyle == .class else { return nil }
        return ObjectIdentifier(value as AnyObject)
    }

    // MARK: - Координатор

    /// Мост событий UIKit-ядра в ``StartScreenDelegate``.
    ///
    /// Живёт столько же, сколько представление: его удерживает SwiftUI, поэтому
    /// слабые ссылки контроллера и пейджера не теряют наблюдателя между
    /// перерисовками.
    public final class Coordinator: NSObject, TesseraPagerDelegate {

        /// Последняя версия описания из SwiftUI: источник делегата и конфигурации.
        fileprivate var parent: StartScreenView

        /// Контроллер экрана. Слабо: иерархией владеет SwiftUI.
        fileprivate weak var screenViewController: TesseraStartScreenViewController?

        /// Пейджер Core внутри контроллера — прокси делегата (см. `attach`).
        ///
        /// Слабо: пейджер удерживается контроллером как child-VC.
        private weak var pagerViewController: TesseraPagerViewController?

        /// Наличие боковых страниц в последней применённой конфигурации (D13).
        ///
        /// Нужно, чтобы не пересобирать страницы на каждой перерисовке SwiftUI:
        /// `configure` пересоздаёт загруженные контроллеры пейджера.
        private var appliedHasLeftPanel: Bool?
        private var appliedHasRightPage: Bool?

        /// Ссылочная идентичность последнего применённого поставщика хука.
        private var appliedLeftPanelIdentity: ObjectIdentifier?

        /// Последняя страница, о которой сообщили делегату.
        private var reportedPage: TesseraStartScreenPage?

        /// Последняя сообщённая видимость хука (§7).
        private var reportedHookVisibility = false

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
        /// `configure` — «холодный» путь: он пересоздаёт загруженные страницы
        /// пейджера, поэтому вызывать его на каждой перерисовке нельзя.
        private func applySidePages(
            leftPanel: QuickPanelProviding?,
            rightPage: (() -> UIViewController)?,
            to screen: TesseraStartScreenViewController,
            force: Bool
        ) {
            let hasLeftPanel = leftPanel != nil
            let hasRightPage = rightPage != nil
            let leftPanelIdentity = leftPanel.flatMap {
                StartScreenView.referenceIdentity(of: $0)
            }

            let needsRebuild = force
                || appliedHasLeftPanel != hasLeftPanel
                || appliedHasRightPage != hasRightPage
                || (hasLeftPanel &&
                    leftPanelIdentity != nil &&
                    leftPanelIdentity != appliedLeftPanelIdentity)

            guard needsRebuild else { return }

            appliedHasLeftPanel = hasLeftPanel
            appliedHasRightPage = hasRightPage
            appliedLeftPanelIdentity = leftPanelIdentity
            screen.configure(leftPanel: leftPanel, rightPage: rightPage)
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
                guard desired != current else { return }
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
        /// `onTap` (см. документацию ``StartScreenView``).
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

            // Вид нужен, чтобы найти пейджер и подключить прокси делегата.
            screen.loadViewIfNeeded()
            installPagerDelegate(on: screen)

            // Хук не показан на старте: первая страница — START (D13).
            reportedHookVisibility = false
        }

        /// Отпускает связи при разборе представления.
        fileprivate func detach() {
            if let pager = pagerViewController, pager.delegate === self {
                // Возвращаем делегата контроллеру, а не оставляем `nil`: экран
                // мог пережить представление (например, его удерживает хост).
                pager.delegate = screenViewController
            }
            screenViewController?.gridView.onTap = nil
            screenViewController?.gridView.onFolderExpansionChanged = nil
            // Перехватчик принадлежит хосту-представлению: экран, переживший
            // SwiftUI, не должен удерживать замыкание с его состоянием.
            screenViewController?.gridView.folderTapHandler = nil
            pagerViewController = nil
            screenViewController = nil
        }

        /// Ставит координатор делегатом пейджера.
        ///
        /// Пейджер находится по композиции контроллера (§2): единственный
        /// прямой child — `TesseraPagerViewController`. Если иерархия ядра
        /// изменится, поиск вернёт `nil`, и переходы страниц не будут
        /// пробрасываться — экран продолжит работать, а `pageChanged` просто
        /// не будет приходить (та же деградация, что у политики края в E4.1).
        private func installPagerDelegate(on screen: TesseraStartScreenViewController) {
            guard let pager = screen.children
                .compactMap({ $0 as? TesseraPagerViewController })
                .first else {
                return
            }
            pager.delegate = self
            pagerViewController = pager
        }

        /// Восстанавливает прокси делегата, если контроллер его переустановил.
        fileprivate func ensurePagerDelegate(on screen: TesseraStartScreenViewController) {
            guard let pager = pagerViewController else {
                installPagerDelegate(on: screen)
                return
            }
            if pager.delegate !== self {
                pager.delegate = self
            }
        }

        // MARK: События

        /// Тап по элементу сетки (палец или активация VoiceOver).
        ///
        /// Действие ярлыка не выполняется (D12): компонент сообщает событие, а
        /// `TileDescriptor.action` вызывает хост — иначе действие выполнилось бы
        /// дважды, если хост тоже на него подписан.
        private func handleTap(_ item: TileGridItem) {
            guard let screen = screenViewController else { return }

            switch item {
            case .tile(let shortcut):
                parent.delegate?.startScreen(screen, didTapShortcut: shortcut)
            case .folder(let folder):
                // D14/D17: событие тапа по папке. Нативное раскрытие панели
                // выполняет сетка (если перехватчик не запретил).
                parent.delegate?.startScreen(screen, didTapFolder: folder)
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
            if expanded {
                parent.delegate?.startScreen(screen, didExpandFolder: folder)
            } else {
                parent.delegate?.startScreen(screen, didCollapseFolder: folder)
            }
        }

        /// Завершение перехода пейджера.
        ///
        /// Сначала событие отдаётся контроллеру: его реализация обновляет
        /// `currentPage`, сообщает хуку о появлении/скрытии (§7), озвучивает
        /// название страницы и пересобирает набор страниц при политике края
        /// (§9). Только после этого событие уходит во внешний делегат, уже с
        /// согласованным состоянием контроллера.
        ///
        /// - Parameters:
        ///   - pager: Пейджер-источник события.
        ///   - index: Показанная страница в порядке чтения (RTL уже учтён Core).
        public func pager(
            _ pager: TesseraPagerViewController,
            didShowPageAt index: Int
        ) {
            guard let screen = screenViewController else { return }

            screen.pager(pager, didShowPageAt: index)

            let page = screen.currentPage
            if page != reportedPage {
                reportedPage = page
                parent.delegate?.startScreen(
                    screen,
                    didChangePage: page,
                    index: index
                )
            }

            let isHookVisible = page == .quickPanel
            if isHookVisible != reportedHookVisibility {
                reportedHookVisibility = isHookVisible
                parent.delegate?.startScreen(
                    screen,
                    didChangeHookVisibility: isHookVisible
                )
            }
        }
    }
}
#endif
