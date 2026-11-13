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
// E14.5: pin идёт через `TileStore.pinTile(_:columns:)` (новая строка в
// конце холста, D33), unpin — через `TileStore.unpin(_:columns:)` с последующим
// `collapseEmptyRows(columns:)` (дыра остаётся, пустая строка схлопывается, D31).
// Число колонок реальной сетки хост сообщает фабрике (`columns`); если его нет,
// берётся ширина, известная хранилищу. Число колонок фиксируется при создании
// страницы: при смене числа колонок сетки хост обязан пересоздать страницу —
// сама она раскладку не пересчитывает.
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
/// Значения по умолчанию приходят из таблиц ресурсов модуля
/// (`Resources/en.lproj|ru.lproj/Localizable.strings`) и резолвятся по языку
/// системы (E9.8г): на русском устройстве — «Настройки», на английском —
/// «Settings». Для неподдержанного языка действует базовая локаль `en`.
/// Хост может заменить любую строку целиком — как и заголовки других
/// компонентов; переданное значение используется без изменений.
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
    /// Параметры сохранили сигнатуру и значения по умолчанию; сами значения
    /// теперь берутся из таблиц ресурсов модуля по языку системы (E9.8г),
    /// поэтому `TesseraAppsListTexts()` на русском устройстве даёт русские
    /// подписи, а на английском — английские.
    ///
    /// - Parameters:
    ///   - settingsSectionTitle: Заголовок секции настроек.
    ///   - emptyTitle: Текст пустого состояния.
    ///   - pinActionTitle: Действие «закрепить».
    ///   - unpinActionTitle: Действие «открепить».
    ///   - pinnedValue: Значение закреплённой строки для VoiceOver.
    public init(
        settingsSectionTitle: String = TesseraStartScreenStrings.appsListSettingsSectionTitle,
        emptyTitle: String = TesseraStartScreenStrings.appsListEmptyTitle,
        pinActionTitle: String = TesseraStartScreenStrings.appsListPinActionTitle,
        unpinActionTitle: String = TesseraStartScreenStrings.appsListUnpinActionTitle,
        pinnedValue: String = TesseraStartScreenStrings.appsListPinnedValue
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
/// Страница показывает **весь каталог** ярлыков, сгруппированный по буквам
/// алфавитного указателя локали (`UILocalizedIndexedCollation`), и отдельную
/// секцию настроек. Строка ярлыка — стандартный
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
///     ],
///     // Число колонок реальной сетки: pin ставит ярлык в новую строку, unpin
///     // оставляет дыру (ячейки хранятся на холсте этой ширины, E14.5).
///     columns: screen.gridView.columns
/// )
/// // Хост подключает страницу замыканием: ссылок на тип пейджера страница не знает.
/// ```
///
/// Страница не подписывается на `TileStore.onChange` и не меняет каталог
/// ярлыков: `setCatalog(_:)`, `load()` и раскладка остаются делом хоста.
/// Всё, что она делает с хранилищем, — `snapshot()`,
/// `pinTile(_:columns:)`, `unpin(_:columns:)` и
/// `collapseEmptyRows(columns:)`; операции с папками (D14) проходят
/// через `approval` хоста и здесь не инициируются. Число колонок для
/// операций по ячейкам страница берёт из фабрики (``make(store:settings:texts:columns:)``);
/// сама она раскладку не считает и сетку экрана не знает (D13).
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
    ///   - texts: Локализуемые строки; по умолчанию — строки модуля,
    ///     локализованные по языку системы (E9.8г).
    ///   - columns: Число колонок реальной сетки (например,
    ///     `TesseraTileGridView.columns`) на момент создания страницы. По нему
    ///     pin ставит ярлык в новую строку в конце холста, а unpin оставляет
    ///     дыру и схлопывает полностью пустую строку (операции по ячейкам,
    ///     E14.5). `nil` — хост раскладку не сообщил: берётся ширина, которую
    ///     хранилищу сообщил координатор, иначе умолчание. Неположительное
    ///     значение трактуется как `nil`.
    ///
    ///     Число колонок фиксируется при создании страницы и не обновляется
    ///     на лету: при смене числа колонок сетки (поворот, смена ширины)
    ///     хост обязан пересоздать страницу — фабрика правой страницы
    ///     вызывается пейджером при её пересоздании и должна передать
    ///     актуальное число колонок.
    /// - Returns: Готовая страница.
    public static func make(
        store: TileStore,
        settings: [TesseraAppsListSettingsItem] = [],
        texts: TesseraAppsListTexts = TesseraAppsListTexts(),
        columns: Int? = nil
    ) -> TesseraAppsListPageViewController {
        TesseraAppsListPageViewController(
            store: store,
            settings: settings,
            texts: texts,
            columns: columns
        )
    }

    // MARK: - Данные

    /// Хранилище рабочего стола (§6: источник истины).
    private let store: TileStore

    /// Число колонок реальной сетки для операций по ячейкам (E14.5).
    ///
    /// `nil` — хост раскладку не сообщил: берётся ``TileStore/effectiveColumns``
    /// (``make(store:settings:texts:columns:)``). Фиксируется при создании
    /// страницы: при смене числа колонок сетки хост пересоздаёт страницу, иначе
    /// ячейки посчитаются для устаревшей ширины.
    private let columns: Int?

    /// Таблица списка приложений и настроек.
    private let tableView = UITableView(frame: .zero, style: .plain)

    /// Подписка на изменения хранилища.
    private var storeSubscription: AnyCancellable?

    /// Секции ярлыков по буквам в порядке отображения (только непустые).
    private var sections: [AppSection] = []

    /// Алфавитный указатель текущей локали (§6: «секции по буквам +
    /// `sectionIndexTitles`» — нативный паттерн). Обновляется при каждой
    /// пересборке секций, чтобы смена языка не оставляла старый алфавит.
    private var collation = UILocalizedIndexedCollation.current()

    /// Структура последней отрисованной таблицы — чтобы отличить смену состава
    /// строк (нужна перезагрузка) от смены состояния (достаточно видимых ячеек).
    private var lastStructure: [SectionSignature] = []

    /// Состояние строк ярлыков (закреплён, иконка) последней отрисовки.
    private var lastRowStates: [[RowState]] = []

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
        /// Буква-заголовок секции (или «#») — заголовок секции collation.
        let title: String

        /// Индекс секции в `UILocalizedIndexedCollation.sectionTitles`: по нему
        /// jump-list находит ближайшую непустую секцию.
        let collationIndex: Int

        /// Строки в алфавитном порядке.
        var entries: [AppEntry]
    }

    /// Состояние строки для сравнения «изменилась ли таблица по составу».
    private struct RowSignature: Equatable {
        let id: AnyHashable
        let title: String
    }

    /// Изменяемое состояние строки ярлыка при неизменном составе: смена
    /// любого поля пересобирает видимые строки на месте (без `reloadData`).
    ///
    /// Иконка сравнивается по **идентичности** объекта `UIImage`: хост,
    /// заменивший иконку при тех же `id`/`title`, получает перерисованную
    /// строку, а сравнение не платит за сравнение пикселей.
    private struct RowState: Equatable {
        let isPinned: Bool
        let icon: UIImage?

        static func == (lhs: RowState, rhs: RowState) -> Bool {
            lhs.isPinned == rhs.isPinned && lhs.icon === rhs.icon
        }
    }

    /// Обёртка подписи для `UILocalizedIndexedCollation`: collation читает
    /// строку объекта через Objective-C селектор.
    private final class CollationKey: NSObject {
        @objc let title: String

        init(_ title: String) {
            self.title = title
        }
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
    ///   - columns: Число колонок реальной сетки; `nil` — неизвестно.
    private init(
        store: TileStore,
        settings: [TesseraAppsListSettingsItem],
        texts: TesseraAppsListTexts,
        columns: Int?
    ) {
        self.store = store
        self.settingsItems = settings
        self.texts = texts
        // У сетки всегда есть хотя бы одна колонка: неположительное значение
        // не описывает раскладку и трактуется как «колонки неизвестны».
        self.columns = columns.flatMap { $0 > 0 ? $0 : nil }
        super.init(nibName: nil, bundle: nil)
    }

    /// Страница не поддерживает создание из архива/сториборда: ей нужно
    /// хранилище, которое передаётся только через
    /// ``make(store:settings:texts:columns:)``.
    ///
    /// - Parameter coder: Декодер архива.
    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("TesseraAppsListPageViewController создаётся через make(store:settings:texts:columns:)")
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
            case .folderContent:
                // Панель раскрытой папки — UI-состояние (D17), в данных его
                // нет; ярлыки папки уже учтены по элементу `.folder`.
                break
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

        // Секции — по `UILocalizedIndexedCollation` текущей локали (§6,
        // нативный паттерн): «É» попадает к «E», иероглифы не дают по секции
        // на символ, цифры и символы — в «#». Порядок строк внутри секции —
        // `localizedStandardCompare`: раскладка по корзинам сохраняет порядок
        // уже отсортированного массива.
        let collation = UILocalizedIndexedCollation.current()
        self.collation = collation
        let titles = collation.sectionTitles
        var buckets = [[AppEntry]](repeating: [], count: titles.count)
        for entry in entries {
            let index = Self.collationSection(for: entry.title, collation: collation)
            buckets[index].append(entry)
        }

        sections = buckets.enumerated().compactMap { index, entries in
            entries.isEmpty ? nil : AppSection(title: titles[index], collationIndex: index, entries: entries)
        }
    }

    /// Пересобирает таблицу по хранилищу.
    ///
    /// - Parameter forceReload: `true` — перезагрузить таблицу даже при
    ///   неизменной структуре (смена строк/текстов страницы).
    private func refreshTable(forceReload: Bool) {
        guard isViewLoaded else { return }

        let previousStructure = lastStructure
        let previousRowStates = lastRowStates

        rebuildSections()
        let structure = makeStructure()
        let rowStates = makeRowStates()

        if !forceReload, structure == previousStructure, rowStates == previousRowStates {
            return
        }

        lastStructure = structure
        lastRowStates = rowStates

        if forceReload || structure != previousStructure {
            let previousOffset = tableView.contentOffset
            tableView.reloadData()
            updateEmptyState()
            // §6, двусторонняя связь: unpin на сетке не должен «прыгать»
            // списком в начало — возвращаем позицию чтения, если UIKit её
            // сбросил. Но только в пределах нового контента: если каталог
            // сократился, прежний offset может указывать за его конец.
            // `contentSize` reloadData пересчитывает синхронно (по оценкам
            // высот), отдельный layout-проход здесь не нужен.
            let target = clampedContentOffset(previousOffset)
            if tableView.contentOffset != target {
                tableView.setContentOffset(target, animated: false)
            }
        } else {
            // Изменилось только состояние (pin/unpin, иконка): собираем
            // видимые строки заново. reloadData здесь не нужен, а в режиме
            // VoiceOver он ещё и сбросил бы фокус с читаемой строки.
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

    /// Состояние строк ярлыков — то, что меняется без изменения состава строк:
    /// «закреплён» (unpin через сетку, pin через страницу) и иконка ярлыка.
    private func makeRowStates() -> [[RowState]] {
        sections.map { section in
            section.entries.map { RowState(isPinned: $0.isPinned, icon: $0.icon) }
        }
    }

    /// Зажимает offset в допустимый диапазон текущего контента таблицы.
    ///
    /// - Parameter offset: Желаемый offset (позиция чтения до перезагрузки).
    /// - Returns: Ближайший offset в пределах `contentSize` с учётом
    ///   `adjustedContentInset`.
    private func clampedContentOffset(_ offset: CGPoint) -> CGPoint {
        let inset = tableView.adjustedContentInset
        let size = tableView.contentSize
        let visible = tableView.bounds.size
        let minX = -inset.left
        let minY = -inset.top
        let maxX = max(minX, size.width + inset.right - visible.width)
        let maxY = max(minY, size.height + inset.bottom - visible.height)
        return CGPoint(
            x: min(max(offset.x, minX), maxX),
            y: min(max(offset.y, minY), maxY)
        )
    }

    /// Закрепляет или открепляет ярлык через хранилище (§6).
    ///
    /// E14.5: pin идёт через ``TileStore/pinTile(_:columns:)`` — ярлык
    /// встаёт в новую строку в конце холста (D33), дыры выше не заполняются.
    /// Секции списка строятся по каталогу и от позиции на сетке не зависят —
    /// сетка узнаёт новую раскладку через `onChange` хоста.
    ///
    /// Unpin идёт через ``TileStore/unpin(_:columns:)``: ячейка ярлыка остаётся
    /// дырой, а затем ``TileStore/collapseEmptyRows(columns:)`` убирает только
    /// полностью пустую строку (D31). Это два изменения модели (второе — no-op
    /// без уведомления, если пустых строк нет).
    ///
    /// Метод внутренний (не `private`), потому что это же действие выполняют
    /// кнопка строки и кастомное действие VoiceOver; тесты страницы вызывают
    /// его напрямую (UI-события в тест-раннере ненадёжны) и отдельно
    /// проверяют обвязку кнопки метаданными (target-action, accessibility).
    ///
    /// - Parameters:
    ///   - pinned: `true` — закрепить, `false` — открепить.
    ///   - tileID: Идентификатор ярлыка из каталога.
    /// - Returns: `true`, если хранилище изменило состояние.
    @discardableResult
    func setPinned(_ pinned: Bool, for tileID: AnyHashable) -> Bool {
        // E14.5: операции по ячейкам. Ширина — колонки страницы, а если хост их
        // не передал, та, что хранилищу сообщил координатор (иначе чужая ширина
        // перезаписала бы холст, D32).
        let width = columns ?? store.effectiveColumns
        if pinned {
            return store.pinTile(tileID, columns: width)
        }
        guard store.unpin(tileID, columns: width) else { return false }
        // Опустевшая строка схлопывается, дыра внутри строки остаётся (D31).
        store.collapseEmptyRows(columns: width)
        return true
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

    /// Индекс секции collation для подписи ярлыка.
    ///
    /// Группировку делает `UILocalizedIndexedCollation` текущей локали: она
    /// сворачивает диакритику («É» → «E»), относит иероглифы к секциям своего
    /// алфавита (в en/ru — «#», в zh — по пиньиню) и складывает цифры, символы
    /// и эмодзи в последнюю секцию «#». Пустая подпись — тоже в «#».
    ///
    /// - Parameters:
    ///   - title: Подпись ярлыка.
    ///   - collation: Указатель текущей локали.
    /// - Returns: Индекс в `collation.sectionTitles`.
    private static func collationSection(for title: String, collation: UILocalizedIndexedCollation) -> Int {
        let lastIndex = max(0, collation.sectionTitles.count - 1)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return lastIndex }
        let index = collation.section(
            for: CollationKey(trimmed),
            collationStringSelector: #selector(getter: CollationKey.title)
        )
        return min(max(0, index), lastIndex)
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

    /// Заголовки jump-list (§6, §9): полный алфавит
    /// `UILocalizedIndexedCollation` текущей локали, как в системных списках;
    /// секция настроек в указатель не входит.
    ///
    /// - Parameter tableView: Таблица страницы.
    /// - Returns: Заголовки указателя или `nil`, если ярлыков нет.
    public func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        sections.isEmpty ? nil : collation.sectionIndexTitles
    }

    /// Обрабатывает прыжок по jump-list.
    ///
    /// Возвращённого индекса достаточно: UITableView сам прокручивает таблицу
    /// к секции (документ §6 — «нативный паттерн, ничего изобретать не надо»).
    /// Указатель показывает весь алфавит, а таблица — только непустые секции,
    /// поэтому буква без ярлыков ведёт к ближайшей следующей непустой секции
    /// (после последней непустой — к последней).
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
        guard !sections.isEmpty else { return 0 }
        let target = collation.section(forSectionIndexTitle: index)
        return sections.firstIndex { $0.collationIndex >= target } ?? sections.count - 1
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
