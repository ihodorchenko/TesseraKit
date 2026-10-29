// Правая страница рабочего стола: список приложений и настройки.
//
// Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md
//  - §1 «Ключевая архитектурная идея: три страницы»: справа от START живёт
//    список приложений; свайп справа налево уводит на него;
//  - §6 «Страница справа: список приложений + настройки»: UITableView с
//    секциями по буквам и `sectionIndexTitles` (jump-list), настройки —
//    секция списка, двусторонняя связь с ярлыками через TileStore;
//  - §9 «Accessibility»: строки — стандартные элементы, jump-list доступен,
//    Dynamic Type, RTL;
//  - §14 «Уточнения MVP» п. 1–2 и D12/D13 в docs/STATE.md: ярлык — просто
//    действие (без поля `type`), а сама страница опциональна — её создаёт хост,
//    если хочет третью страницу пейджера;
//  - D14: страница ничего не делает с папками сама — все операции с папками
//    идут через TileStore и функцию одобрения хоста (в списке таких операций
//    нет: pin/unpin — это раскладка, а не группировка).
//
// Источник истины — TileStore (§6, правило «один писатель»). Страница не
// держит собственного состояния рабочего стола: она читает `snapshot()` и
// перестраивает секции после каждого изменения хранилища, а pin/unpin
// выполняет методами TileStore. Поэтому сетка и список не расходятся:
// pin из списка появляется в сетке через `onChange` хоста, unpin на сетке
// меняет состояние строк здесь — по подписке на изменение того же хранилища.
//
// Подписка — на `objectWillChange` (`ObservableObject`; iOS 15 — по правилу
// AGENTS.md), а не на `onChange`: `onChange` — единственное замыкание, его
// держит хост и через него обновляет сетку. Подписка на objectWillChange
// ничья и допускает несколько наблюдателей, поэтому страница не отнимает
// канал у сетки.
//
// Геометрия страницы: собственных распознавателей жестов здесь нет. Пейджер
// (docs/CORE-IOS-DESIGN.md §2) забирает горизонталь, а этот UITableView —
// вертикаль; арбитраж по доминирующей оси делает пейджер, страница получает
// уже готовое решение. Поэтому таблица просто скроллится вертикально.

#if canImport(UIKit)
import Combine
import UIKit

// MARK: - Настройки страницы (элементы списка)

/// Элемент секции настроек правой страницы (docs/STARTSCREEN-IOS-DESIGN.md §6).
///
/// «Настройки — секция/элемент списка»: компонент не знает, что именно
/// настраивается, — он показывает строки, которые передал хост, и вызывает их
/// ``action``. Так отдельный экран настроек остаётся за приложением (§6), а
/// страница не превращается в ещё один источник состояния.
///
/// Строки настроек не связаны с `TileStore`: это обычные действия хоста.
public struct TesseraAppsListSettingsItem {

    /// Стабильный идентификатор строки; уникален в пределах секции настроек.
    ///
    /// Используется страницей только для сравнения состояния при перезагрузке,
    /// поэтому произвольное хэшируемое значение подходит.
    public let id: AnyHashable

    /// Основная подпись строки.
    public var title: String

    /// Пояснение под подписью; `nil` — строка в одну линию.
    public var subtitle: String?

    /// Иконка строки; `nil` — без иконки (текст прижмётся к краю).
    public var icon: UIImage?

    /// Действие по тапу. Вызывается на главном потоке, как и `TileDescriptor.action`.
    public let action: () -> Void

    /// Создаёт строку секции настроек.
    ///
    /// - Parameters:
    ///   - id: Уникальный идентификатор строки.
    ///   - title: Основная подпись.
    ///   - subtitle: Пояснение; по умолчанию нет.
    ///   - icon: Иконка; по умолчанию нет.
    ///   - action: Действие по тапу.
    public init(
        id: AnyHashable,
        title: String,
        subtitle: String? = nil,
        icon: UIImage? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.action = action
    }
}

/// Локализуемые строки правой страницы.
///
/// Внутри компонента строки по умолчанию русские (язык проектной документации),
/// но хост может заменить их целиком — как и заголовки других компонентов,
/// страница не тянет за собой собственный ресурсный бандл.
public struct TesseraAppsListTexts: Equatable {

    /// Заголовок секции настроек.
    public var settingsSectionTitle: String

    /// Текст пустого состояния: в каталоге нет ни ярлыков, ни настроек.
    public var emptyTitle: String

    /// Название действия «закрепить ярлык на рабочем столе» (кнопка и custom action).
    public var pinActionTitle: String

    /// Название действия «открепить ярлык с рабочего стола».
    public var unpinActionTitle: String

    /// Значение строки для VoiceOver у закреплённого ярлыка.
    public var pinnedValue: String

    /// Создаёт набор строк.
    ///
    /// - Parameters:
    ///   - settingsSectionTitle: Заголовок секции настроек.
    ///   - emptyTitle: Текст пустого состояния.
    ///   - pinActionTitle: Действие «закрепить».
    ///   - unpinActionTitle: Действие «открепить».
    ///   - pinnedValue: Значение закреплённой строки для VoiceOver.
    public init(
        settingsSectionTitle: String = "Настройки",
        emptyTitle: String = "Нет приложений",
        pinActionTitle: String = "Закрепить на рабочем столе",
        unpinActionTitle: String = "Открепить",
        pinnedValue: String = "Закреплено"
    ) {
        self.settingsSectionTitle = settingsSectionTitle
        self.emptyTitle = emptyTitle
        self.pinActionTitle = pinActionTitle
        self.unpinActionTitle = unpinActionTitle
        self.pinnedValue = pinnedValue
    }
}

// MARK: - Страница

/// Правая опциональная страница пейджера рабочего стола (§6; D13).
///
/// Страница показывает **весь каталог** ярлыков, сгруппированный по первой
/// букве подписи, и отдельную секцию настроек. Строка ярлыка — стандартный
/// элемент списка: тап запускает `TileDescriptor.action` (D12: ярлык — просто
/// действие), кнопка-«канцелярская кнопка» в аксессуаре закрепляет или
/// открепляет ярлык, а состояние строки всегда отражает `TileStore`.
///
/// ## Использование
///
/// ```swift
/// let page = TesseraAppsListPageViewController.make(
///     store: store,
///     settings: [
///         TesseraAppsListSettingsItem(id: "settings", title: "Настройки рабочего стола") {
///             host.presentSettings()
///         }
///     ]
/// )
/// // Хост подключает страницу замыканием: ссылок на тип пейджера страница не знает.
/// ```
///
/// Страница не подписывается на `TileStore.onChange` и не меняет каталог
/// ярлыков: `setCatalog(_:)`, `load()` и раскладка остаются делом хоста.
/// Всё, что она делает с хранилищем, — `snapshot()`, `pin(_:at:)` и
/// `unpin(_:)`; операции с папками (D14) проходят через `approval` хоста
/// и здесь не инициируются.
///
/// Своих распознавателей жестов страница не добавляет: вертикальный скролл —
/// это таблица, горизонталь — пейджер. Скролл-вью отдаётся наружу через
/// ``scrollView``, чтобы хост мог зарегистрировать её вертикальным владельцем
/// в `TesseraGestureArbiter` (docs/CORE-IOS-DESIGN.md §2).
///
/// ## Accessibility (§9)
///
/// - строки — настоящие `UITableViewCell`: подпись = `title`, значение =
///   «Закреплено» (``TesseraAppsListTexts/pinnedValue``), признак — кнопка;
/// - кнопка аксессуара — самостоятельный элемент VoiceOver с понятным
///   действием («Закрепить»/«Открепить»), плюс то же действие доступно
///   как `UIAccessibilityCustomAction` на самой строке;
/// - jump-list — нативный `sectionIndexTitles`; RTL-зеркалирование индекса
///   и строк выполняет UIKit (принудительный `semanticContentAttribute`
///   не выставляется, чтобы не сломать направление, заданное хостом);
/// - Dynamic Type: шрифты строк и пустого состояния — текстовые стили;
/// - при pin/unpin видимые строки пересобираются на месте, поэтому VoiceOver
///   не теряет фокус, как при `reloadData`.
///
/// - Note: Все методы и колбэки вызываются на главном потоке.
public final class TesseraAppsListPageViewController: UIViewController {

    // MARK: - Публичный интерфейс

    /// Строки секции настроек; изменение перестраивает секцию.
    ///
    /// Пустой массив — секции настроек нет (§14 п. 2: страница не навязывает
    /// хосту разделы, которых у приложения нет).
    public var settingsItems: [TesseraAppsListSettingsItem] {
        didSet {
            // Строки настроек — не состояние хранилища, поэтому сравнивать
            // подписи/пояснения по снимку нечем: перезагружаем секцию целиком.
            refreshTable(forceReload: true)
        }
    }

    /// Локализуемые строки страницы.
    public var texts: TesseraAppsListTexts {
        didSet {
            guard texts != oldValue else { return }
            refreshTable(forceReload: true)
        }
    }

    /// Скролл-вью страницы — вертикальный владелец для `TesseraGestureArbiter`
    /// (docs/CORE-IOS-DESIGN.md §2 «Арбитраж», §3).
    ///
    /// Страница не настраивает арбитраж сама: жест между горизонтальным
    /// пейджером и вертикальным списком распределяет хост, у которого есть оба
    /// скролл-вью. Наружу отдаётся именно `UIScrollView` — этого арбитру
    /// достаточно, а внутренний тип таблицы остаётся деталью реализации.
    public var scrollView: UIScrollView { tableView }

    /// Создаёт страницу — единственный поддерживаемый вход.
    ///
    /// Статическая фабрика нужна, чтобы в `StartScreenViewController` страница
    /// подключалась замыканием `{ TesseraAppsListPageViewController.make(store: store) }`
    /// и тип страницы не протекал в API пейджера (D13).
    ///
    /// - Parameters:
    ///   - store: Хранилище рабочего стола — единственный источник истины (§6).
    ///   - settings: Строки секции настроек; по умолчанию секции нет.
    ///   - texts: Локализуемые строки; по умолчанию русские подписи.
    /// - Returns: Готовая страница.
    public static func make(
        store: TileStore,
        settings: [TesseraAppsListSettingsItem] = [],
        texts: TesseraAppsListTexts = TesseraAppsListTexts()
    ) -> TesseraAppsListPageViewController {
        TesseraAppsListPageViewController(store: store, settings: settings, texts: texts)
    }

    // MARK: - Данные

    /// Хранилище рабочего стола (§6: источник истины).
    private let store: TileStore

    /// Таблица списка приложений и настроек.
    private let tableView = UITableView(frame: .zero, style: .plain)

    /// Подписка на изменения хранилища.
    private var storeSubscription: AnyCancellable?

    /// Секции ярлыков по буквам в порядке отображения.
    private var sections: [AppSection] = []

    /// Структура последней отрисованной таблицы — чтобы отличить смену состава
    /// строк (нужна перезагрузка) от смены состояния (достаточно видимых ячеек).
    private var lastStructure: [SectionSignature] = []

    /// Состояние «закреплён» по строкам последней отрисовки.
    private var lastPinnedFlags: [[Bool]] = []

    /// Кэш миниатюр иконок: стандартная ячейка берёт размер картинки в layout,
    /// поэтому крупные иконки приложения приводятся к размеру строки один раз.
    private let iconCache: NSCache<UIImage, UIImage> = {
        let cache = NSCache<UIImage, UIImage>()
        cache.countLimit = 128
        return cache
    }()

    /// Подпись пустого состояния (создаётся один раз).
    private var emptyStateLabel: UILabel?

    /// Контейнер пустого состояния для `tableView.backgroundView`.
    private lazy var emptyStateView: UIView = makeEmptyStateView()

    /// Размер иконки строки в точках (стандартный размер иконки в списках iOS).
    private static let iconSide: CGFloat = 29

    /// Идентификаторы переиспользования ячеек.
    private static let defaultCellIdentifier = "TesseraAppsListDefaultCell"
    private static let subtitleCellIdentifier = "TesseraAppsListSubtitleCell"

    /// Заголовок секции для подписей, начинающихся не с буквы (цифры, символы,
    /// эмодзи): в iOS-списках такая секция традиционно называется «#».
    private static let otherSectionTitle = "#"

    // MARK: - Модель строк

    /// Ярлык в списке вместе с его состоянием на рабочем столе.
    private struct AppEntry {
        /// Ярлык из снимка хранилища (действие, иконка, бейдж, размер).
        let descriptor: TileDescriptor

        /// Закреплён ли ярлык на сетке или в папке.
        let isPinned: Bool

        /// Идентификатор ярлыка (D12: стабильный, уникальный в пределах стола).
        var id: AnyHashable { descriptor.id }

        /// Подпись — она же алфавитный ключ и accessibility label.
        var title: String { descriptor.title }

        /// Иконка ярлыка.
        var icon: UIImage? { descriptor.icon }
    }

    /// Секция ярлыков одной буквы.
    private struct AppSection {
        /// Буква-заголовок секции (или «#»).
        let title: String

        /// Строки в алфавитном порядке.
        var entries: [AppEntry]
    }

    /// Состояние строки для сравнения «изменилась ли таблица по составу».
    private struct RowSignature: Equatable {
        let id: AnyHashable
        let title: String
    }

    /// Состояние секции для сравнения «изменилась ли таблица по составу».
    private struct SectionSignature: Equatable {
        let title: String
        let rows: [RowSignature]
    }

    // MARK: - Инициализация

    /// Создаёт страницу; используйте ``make(store:settings:texts:)``.
    ///
    /// - Parameters:
    ///   - store: Хранилище рабочего стола.
    ///   - settings: Строки секции настроек.
    ///   - texts: Локализуемые строки.
    private init(
        store: TileStore,
        settings: [TesseraAppsListSettingsItem],
        texts: TesseraAppsListTexts
    ) {
        self.store = store
        self.settingsItems = settings
        self.texts = texts
        super.init(nibName: nil, bundle: nil)
    }

    /// Страница не поддерживает создание из архива/сториборда: ей нужно
    /// хранилище, которое передаётся только через ``make(store:settings:texts:)``.
    ///
    /// - Parameter coder: Декодер архива.
    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("TesseraAppsListPageViewController создаётся через make(store:settings:texts:)")
    }

    // MARK: - Жизненный цикл

    public override func viewDidLoad() {
        super.viewDidLoad()
        setUpTableView()

        // §6: единственный канал обновлений — хранилище. Подписка на
        // objectWillChange не отнимает onChange у сетки (см. шапку файла).
        storeSubscription = store.objectWillChange.sink { [weak self] _ in
            self?.refreshTable(forceReload: false)
        }

        // §9, Dynamic Type: стандартная ячейка не обязана пересобирать шрифт
        // на лету, поэтому пересчитываем видимые строки и высоты при смене
        // категории размера текста. Один наблюдатель на страницу.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )

        refreshTable(forceReload: true)
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Страница могла быть выгружена пейджером и собрана заново, а хранилище
        // за это время уже поменялось; повторная сборка дешёвая и идемпотентная.
        refreshTable(forceReload: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Пересобирает видимые строки и их высоты под новую категорию Dynamic Type.
    @objc private func contentSizeCategoryDidChange() {
        guard isViewLoaded else { return }
        // Начало/конец обновлений заставляет таблицу переспросить высоты строк
        // при `automaticDimension`; данные при этом не меняются.
        tableView.beginUpdates()
        tableView.endUpdates()
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath) else { continue }
            configure(cell, at: indexPath)
        }
        // Пустое состояние — единственная метка страницы вне ячеек.
        emptyStateLabel?.font = UIFont.preferredFont(forTextStyle: .body)
    }

    // MARK: - Настройка таблицы

    /// Собирает таблицу: делегаты, стили, safe area.
    private func setUpTableView() {
        view.backgroundColor = .systemBackground

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .systemBackground
        tableView.dataSource = self
        tableView.delegate = self
        tableView.alwaysBounceVertical = true
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        // На iPad строки не растягиваются на всю ширину — читаемая колонка.
        tableView.cellLayoutMarginsFollowReadableWidth = true
        // §9: контейнер не является одним элементом — элементы это строки.
        tableView.isAccessibilityElement = false

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Данные и перезагрузка

    /// Перестраивает секции по текущему снимку хранилища.
    ///
    /// В список попадает **весь** каталог: и закреплённые ярлыки (`items`,
    /// включая содержимое папок), и незакреплённые (`unpinned`). Так требование
    /// §6 «unpin на сетке → элемент списка меняет состояние» выполняется без
    /// второго источника данных: состояние — это флаг из того же снимка.
    private func rebuildSections() {
        let snapshot = store.snapshot()

        var pinnedIDs = Set<AnyHashable>()
        var catalog: [AnyHashable: TileDescriptor] = [:]

        for item in snapshot.items {
            switch item {
            case .tile(let descriptor):
                pinnedIDs.insert(descriptor.id)
                catalog[descriptor.id] = descriptor
            case .folder(let folder):
                // Ярлыки папки тоже закреплены: сетка показывает их через папку,
                // поэтому в списке они отмечены как закреплённые. Unpin такого
                // ярлыка TileStore выполняет сам (убирает из папки, D14 — это
                // следствие открепления, а не операция группировки).
                for tile in folder.tiles {
                    pinnedIDs.insert(tile.id)
                    catalog[tile.id] = tile
                }
            }
        }

        for descriptor in snapshot.unpinned {
            catalog[descriptor.id] = descriptor
        }

        let entries = catalog.values
            .map { AppEntry(descriptor: $0, isPinned: pinnedIDs.contains($0.id)) }
            .sorted { lhs, rhs in
                lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }

        var grouped: [String: [AppEntry]] = [:]
        var order: [String] = []
        for entry in entries {
            let letter = Self.sectionTitle(for: entry.title)
            if grouped[letter] == nil {
                order.append(letter)
            }
            grouped[letter, default: []].append(entry)
        }

        let sortedLetters = order.sorted { lhs, rhs in
            if lhs == Self.otherSectionTitle { return false }
            if rhs == Self.otherSectionTitle { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }

        sections = sortedLetters.map { AppSection(title: $0, entries: grouped[$0] ?? []) }
    }

    /// Пересобирает таблицу по хранилищу.
    ///
    /// - Parameter forceReload: `true` — перезагрузить таблицу даже при
    ///   неизменной структуре (смена строк/текстов страницы).
    private func refreshTable(forceReload: Bool) {
        guard isViewLoaded else { return }

        let previousStructure = lastStructure
        let previousPinnedFlags = lastPinnedFlags

        rebuildSections()
        let structure = makeStructure()
        let pinnedFlags = makePinnedFlags()

        if !forceReload, structure == previousStructure, pinnedFlags == previousPinnedFlags {
            return
        }

        lastStructure = structure
        lastPinnedFlags = pinnedFlags

        if forceReload || structure != previousStructure {
            let previousOffset = tableView.contentOffset
            tableView.reloadData()
            updateEmptyState()
            // §6, двусторонняя связь: unpin на сетке не должен «прыгать»
            // списком в начало — возвращаем позицию чтения, если UIKit её сбросил.
            if tableView.contentOffset != previousOffset {
                tableView.setContentOffset(previousOffset, animated: false)
            }
        } else {
            // Изменилось только состояние (pin/unpin): собираем видимые строки
            // заново. reloadData здесь не нужен, а в режиме VoiceOver он ещё и
            // сбросил бы фокус с читаемой строки.
            for indexPath in tableView.indexPathsForVisibleRows ?? [] {
                guard let cell = tableView.cellForRow(at: indexPath) else { continue }
                configure(cell, at: indexPath)
            }
        }
    }

    /// Состав таблицы (секции и строки) для сравнения; включая секцию настроек.
    private func makeStructure() -> [SectionSignature] {
        var result = sections.map { section in
            SectionSignature(
                title: section.title,
                rows: section.entries.map { RowSignature(id: $0.id, title: $0.title) }
            )
        }
        if !settingsItems.isEmpty {
            result.append(
                SectionSignature(
                    title: texts.settingsSectionTitle,
                    rows: settingsItems.map { RowSignature(id: $0.id, title: $0.title) }
                )
            )
        }
        return result
    }

    /// Флаги «закреплён» по строкам ярлыков — состояние, которое меняется через
    /// сетку (unpin) и через саму страницу (pin), без изменения состава строк.
    private func makePinnedFlags() -> [[Bool]] {
        sections.map { $0.entries.map(\.isPinned) }
    }

    /// Закрепляет или открепляет ярлык через хранилище (§6).
    ///
    /// - Parameters:
    ///   - pinned: `true` — закрепить, `false` — открепить.
    ///   - tileID: Идентификатор ярлыка из каталога.
    /// - Returns: `true`, если хранилище изменило состояние.
    @discardableResult
    private func setPinned(_ pinned: Bool, for tileID: AnyHashable) -> Bool {
        if pinned {
            return store.pin(tileID)
        }
        return store.unpin(tileID)
    }

    // MARK: - Пустое состояние

    /// Показывает заглушку, когда в списке нет ни ярлыков, ни настроек.
    private func updateEmptyState() {
        let hasRows = !sections.isEmpty || !settingsItems.isEmpty
        if hasRows {
            tableView.backgroundView = nil
            tableView.separatorStyle = .singleLine
        } else {
            emptyStateLabel?.text = texts.emptyTitle
            emptyStateLabel?.accessibilityLabel = texts.emptyTitle
            tableView.backgroundView = emptyStateView
            tableView.separatorStyle = .none
        }
    }

    /// Собирает вид пустого состояния (§9: обычный accessibility-элемент).
    private func makeEmptyStateView() -> UIView {
        let container = UIView()

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = texts.emptyTitle
        label.textAlignment = .center
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.isAccessibilityElement = true
        label.accessibilityLabel = texts.emptyTitle
        emptyStateLabel = label

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -32),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])
        return container
    }

    // MARK: - Ячейки

    /// Достаёт ячейку нужного стиля, создавая её при первом обращении.
    ///
    /// Регистрация классов не подходит: зарегистрированный `UITableViewCell`
    /// создаётся только в стиле `.default`, а строке настроек с пояснением нужен
    /// `.subtitle`. Стиль фиксируется идентификатором, поэтому смешивания нет.
    private func dequeueCell(
        in tableView: UITableView,
        identifier: String,
        style: UITableViewCell.CellStyle
    ) -> UITableViewCell {
        tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: style, reuseIdentifier: identifier)
    }

    /// Настраивает строку по её позиции.
    ///
    /// - Parameters:
    ///   - cell: Переиспользуемая ячейка.
    ///   - indexPath: Позиция строки.
    private func configure(_ cell: UITableViewCell, at indexPath: IndexPath) {
        if indexPath.section < sections.count {
            configureAppCell(cell, entry: sections[indexPath.section].entries[indexPath.row])
        } else {
            configureSettingsCell(cell, item: settingsItems[indexPath.section - sections.count])
        }
    }

    /// Настраивает строку ярлыка.
    ///
    /// - Parameters:
    ///   - cell: Ячейка.
    ///   - entry: Ярлык с состоянием «закреплён».
    private func configureAppCell(_ cell: UITableViewCell, entry: AppEntry) {
        // Полная настройка: ячейка могла раньше показывать строку настроек.
        cell.imageView?.image = iconImage(for: entry.icon)
        cell.imageView?.contentMode = .scaleAspectFit
        cell.textLabel?.text = entry.title
        cell.detailTextLabel?.text = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default
        cell.accessibilityHint = nil

        // §9: строка — стандартный элемент; подпись ярлыка и состояние.
        cell.accessibilityLabel = entry.title
        cell.accessibilityValue = entry.isPinned ? texts.pinnedValue : nil
        cell.accessibilityTraits = .button

        let actionTitle = entry.isPinned ? texts.unpinActionTitle : texts.pinActionTitle
        let tileID = entry.id
        let isPinned = entry.isPinned

        // То же действие доступно ротором VoiceOver — маленькую кнопку
        // в аксессуаре не нужно искать на ощупь.
        cell.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: actionTitle) { [weak self] _ in
                guard let self else { return false }
                return self.setPinned(!isPinned, for: tileID)
            },
        ]

        let button = pinButton(in: cell)
        button.setImage(Self.pinImage(pinned: entry.isPinned), for: .normal)
        button.accessibilityLabel = actionTitle
        button.onTap = { [weak self] in
            self?.setPinned(!isPinned, for: tileID)
        }
    }

    /// Настраивает строку секции настроек.
    ///
    /// - Parameters:
    ///   - cell: Ячейка.
    ///   - item: Строка, заданная хостом.
    private func configureSettingsCell(_ cell: UITableViewCell, item: TesseraAppsListSettingsItem) {
        cell.imageView?.image = iconImage(for: item.icon)
        cell.imageView?.contentMode = .scaleAspectFit
        cell.textLabel?.text = item.title
        cell.detailTextLabel?.text = item.subtitle
        cell.accessoryView = nil
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        cell.accessibilityLabel = item.title
        cell.accessibilityValue = item.subtitle
        cell.accessibilityHint = nil
        cell.accessibilityTraits = .button
        cell.accessibilityCustomActions = nil
    }

    /// Возвращает кнопку-аксессуар строки, создавая её при необходимости.
    ///
    /// - Parameter cell: Ячейка ярлыка.
    /// - Returns: Кнопка закрепления.
    private func pinButton(in cell: UITableViewCell) -> TesseraAppsListPinButton {
        if let existing = cell.accessoryView as? TesseraAppsListPinButton {
            return existing
        }
        let button = TesseraAppsListPinButton()
        cell.accessoryView = button
        return button
    }

    /// Символ кнопки закрепления.
    ///
    /// - Parameter pinned: Текущее состояние.
    /// - Returns: Закреплённая кнопка — заполненная, свободная — контурная.
    private static func pinImage(pinned: Bool) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        let name = pinned ? "pin.circle.fill" : "pin.circle"
        return UIImage(systemName: name, withConfiguration: configuration)
            ?? UIImage(systemName: "checkmark.circle", withConfiguration: configuration)
    }

    /// Приводит иконку ярлыка к размеру строки.
    ///
    /// Стандартная ячейка учитывает натуральный размер `UIImage` в layout,
    /// поэтому иконка 1024×1024 растянула бы строку на весь экран. Рисуем
    /// миниатюру с сохранением пропорций и кэшируем по объекту иконки.
    ///
    /// - Parameter icon: Исходная иконка ярлыка.
    /// - Returns: Миниатюра для `imageView` строки.
    private func iconImage(for icon: UIImage?) -> UIImage? {
        guard let icon, icon.size.width > 0, icon.size.height > 0 else { return nil }
        if let cached = iconCache.object(forKey: icon) {
            return cached
        }

        let side = Self.iconSide
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let thumbnail = renderer.image { _ in
            let scale = min(side / icon.size.width, side / icon.size.height)
            let size = CGSize(width: icon.size.width * scale, height: icon.size.height * scale)
            let rect = CGRect(
                x: (side - size.width) / 2,
                y: (side - size.height) / 2,
                width: size.width,
                height: size.height
            )
            icon.draw(in: rect)
        }

        iconCache.setObject(thumbnail, forKey: icon)
        return thumbnail
    }

    // MARK: - Алфавитный указатель

    /// Заголовок секции по подписи ярлыка.
    ///
    /// Берётся первый символ подписи в верхнем регистре; подписи, начинающиеся
    /// не с буквы (цифры, символы, эмодзи), попадают в общую секцию «#».
    /// Транслитерация не выполняется: сортировка идёт по текущей локали
    /// (`localizedStandardCompare`), поэтому кириллица и латиница образуют
    /// свои секции без смешивания.
    ///
    /// - Parameter title: Подпись ярлыка.
    /// - Returns: Буква-заголовок секции или «#».
    private static func sectionTitle(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return otherSectionTitle }
        // Верхний регистр может дать больше одного символа (например, «ß» → «SS»),
        // поэтому от результата снова берём первый символ.
        let letter = String(String(first).uppercased().prefix(1))
        guard let scalar = letter.unicodeScalars.first,
              CharacterSet.letters.contains(scalar) else {
            return otherSectionTitle
        }
        return letter
    }
}

// MARK: - UITableViewDataSource

extension TesseraAppsListPageViewController: UITableViewDataSource {

    /// Число секций: буквы алфавита плюс (если хост задал) секция настроек.
    ///
    /// - Parameter tableView: Таблица страницы.
    /// - Returns: Число секций.
    public func numberOfSections(in tableView: UITableView) -> Int {
        sections.count + (settingsItems.isEmpty ? 0 : 1)
    }

    /// Число строк в секции.
    ///
    /// - Parameters:
    ///   - tableView: Таблица страницы.
    ///   - section: Индекс секции.
    /// - Returns: Число строк.
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section < sections.count {
            return sections[section].entries.count
        }
        return settingsItems.count
    }

    /// Заголовок секции: буква или заголовок секции настроек.
    ///
    /// - Parameters:
    ///   - tableView: Таблица страницы.
    ///   - section: Индекс секции.
    /// - Returns: Заголовок или `nil`, если секции настроек нет.
    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section < sections.count {
            return sections[section].title
        }
        return settingsItems.isEmpty ? nil : texts.settingsSectionTitle
    }

    /// Заголовки jump-list (§6, §9): только буквы ярлыков, без настроек.
    ///
    /// - Parameter tableView: Таблица страницы.
    /// - Returns: Заголовки указателя или `nil`, если ярлыков нет.
    public func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        sections.isEmpty ? nil : sections.map(\.title)
    }

    /// Обрабатывает прыжок по jump-list.
    ///
    /// Возвращённого индекса достаточно: UITableView сам прокручивает таблицу
    /// к секции (документ §6 — «нативный паттерн, ничего изобретать не надо»).
    ///
    /// - Parameters:
    ///   - tableView: Таблица страницы.
    ///   - title: Буква, по которой коснулись указателя.
    ///   - index: Индекс заголовка в ``sectionIndexTitles(for:)``.
    /// - Returns: Индекс секции, к которой перешли.
    public func tableView(
        _ tableView: UITableView,
        sectionForSectionIndexTitle title: String,
        at index: Int
    ) -> Int {
        guard sections.indices.contains(index) else {
            return max(0, sections.count - 1)
        }
        return index
    }

    /// Создаёт и настраивает строку списка.
    ///
    /// - Parameters:
    ///   - tableView: Таблица страницы.
    ///   - indexPath: Позиция строки.
    /// - Returns: Готовая ячейка.
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section < sections.count {
            let entry = sections[indexPath.section].entries[indexPath.row]
            let cell = dequeueCell(
                in: tableView,
                identifier: Self.defaultCellIdentifier,
                style: .default
            )
            configureAppCell(cell, entry: entry)
            return cell
        }

        let item = settingsItems[indexPath.section - sections.count]
        let hasSubtitle = item.subtitle != nil
        let cell = dequeueCell(
            in: tableView,
            identifier: hasSubtitle ? Self.subtitleCellIdentifier : Self.defaultCellIdentifier,
            style: hasSubtitle ? .subtitle : .default
        )
        configureSettingsCell(cell, item: item)
        return cell
    }
}

// MARK: - UITableViewDelegate

extension TesseraAppsListPageViewController: UITableViewDelegate {

    /// Тап по строке: ярлык выполняет своё действие (D12), настройка — своё.
    ///
    /// - Parameters:
    ///   - tableView: Таблица страницы.
    ///   - indexPath: Позиция строки.
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if indexPath.section < sections.count {
            // D12: ярлык — просто действие; карточки приложения и deep-links
            // в v1 отрезаны (§10), поэтому страница ничего не открывает сама.
            sections[indexPath.section].entries[indexPath.row].descriptor.action()
            return
        }

        let settingsIndex = indexPath.section - sections.count
        guard settingsItems.indices.contains(settingsIndex) else { return }
        settingsItems[settingsIndex].action()
    }
}

// MARK: - Кнопка закрепления

/// Кнопка-аксессуар строки: закрепить или открепить ярлык.
///
/// Отдельный accessibility-элемент: VoiceOver озвучивает кнопку её действием
/// («Закрепить на рабочем столе» / «Открепить»), а строка остаётся кнопкой
/// запуска приложения. Размер — 44×44 точки, минимальная цель касания (§9).
private final class TesseraAppsListPinButton: UIButton {

    /// Действие по тапу; обновляется при настройке ячейки.
    var onTap: (() -> Void)?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    /// Кнопка не создаётся из архива.
    ///
    /// - Parameter coder: Декодер архива.
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TesseraAppsListPinButton создаётся только программно")
    }

    /// Держит цель касания 44×44 точки (§9), даже если ячейка спрашивает
    /// «естественный» размер по картинке.
    override var intrinsicContentSize: CGSize {
        CGSize(width: 44, height: 44)
    }

    /// Держит цель касания 44×44 точки при раскладке аксессуара ячейкой.
    ///
    /// - Parameter size: Предлагаемый размер.
    /// - Returns: Фиксированный размер цели касания.
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: 44, height: 44)
    }

    /// Вызывает действие строки.
    @objc private func handleTap() {
        onTap?()
    }
}

#endif
