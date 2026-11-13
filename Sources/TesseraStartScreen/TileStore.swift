// Хранилище состояния «Рабочего стола»: порядок, размеры, папки и закрепления.
//
// Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md
//  - §3 «Плиточная сетка»: раскладку в юнитах считает TileLayoutEngine
//    (чистые функции, файл TileLayoutEngine.swift); порядок элементов, размеры,
//    закрепления и папки — задача TileStore;
//  - §5 «Режим редактирования»: «TileStore сохраняет порядок/размеры/закрепления
//    (JSON/файл), выживает между запусками»;
//  - §6 «Страница справа»: TileStore — единственный источник истины и для сетки,
//    и для списка приложений (двусторонний pin/unpin, правило «один писатель»);
//  - §14 «Уточнения MVP» и D12–D15 в docs/STATE.md: ярлык — просто действие
//    (без поля type), папки создаются/меняются только через функцию одобрения
//    хоста, у ярлыков четыре размера.
//
// Модель ярлыка и папки — `TileDescriptor.swift` / `TileFolder.swift` (E4.2):
// хранилище не дублирует их, а надстраивает состояние поверх каталога ярлыков.
//
// Поток: все методы рассчитаны на главный поток — состояние рабочего стола не
// размазывается по модулям (docs/CORE-IOS-DESIGN.md §3). Запись на диск
// синхронная, JSON небольшой: это дешевле, чем очередь и гонки за файл.

#if canImport(UIKit)
import Combine
import Foundation
import UIKit

// MARK: - Снимок сетки

/// Элемент сетки рабочего стола: ярлык, папка или панель раскрытой папки.
///
/// Снимок отдаёт элементы в порядке отображения. Ярлык приходит с текущим
/// размером и подписью, папка — со своими ярлыками, чтобы сетка и экран папки
/// рисовались по одному снимку и не дёргали хранилище на каждый элемент.
///
/// ``folderContent(_:)`` — не элемент данных, а UI-состояние раскрытия (D17):
/// `TileStore` и файл состояния её не содержат, а вью-слой **вставляет** её
/// отдельным элементом сразу после плитки папки. Плитка папки при этом остаётся
/// в наборе и на экране: панель — полноширинная строка под ней. Она живёт в этом
/// же перечислении, чтобы раскладка (`TileLayoutEngine`/
/// `TesseraTileCollectionViewLayout`) видела раскрытую панель в общем порядке
/// элементов.
public enum TileGridItem {

    /// Ярлык с текущим размером из хранилища.
    case tile(TileDescriptor)

    /// Папка вместе с её ярлыками (в порядке папки).
    case folder(TileFolder)

    /// Полноширинная панель раскрытой папки (D17, E7.1).
    ///
    /// Панель показывает заголовок папки и сетку её содержимого. В наборе
    /// элементов вью-слой **вставляет** её сразу после плитки-папки: плитка
    /// остаётся видимой, число элементов растёт на один, а панель занимает
    /// полноширинную строку сразу после строки, в которой заканчивается папка
    /// (``folderContent(_:)`` растягивается на всю ширину). В данных панели нет:
    /// это представление состояния «папка раскрыта», поэтому в снимке
    /// `TileStore` панель не появляется и между запусками не сохраняется.
    /// Идентификатор панели совпадает с идентификатором папки — по нему
    /// раскладка находит строку папки, после которой встаёт панель.
    case folderContent(TileFolder)

    /// Идентификатор элемента (ярлыка, папки или панели папки).
    public var id: AnyHashable {
        switch self {
        case .tile(let descriptor): return descriptor.id
        case .folder(let folder): return folder.id
        case .folderContent(let folder): return folder.id
        }
    }

    /// Текущий размер элемента в юнитах (D15).
    ///
    /// У панели раскрытой папки собственного размера в юнитах нет: она всегда
    /// занимает всю ширину сетки, а её высоту считает
    /// ``TileLayoutEngine/panelHeight(for:width:columns:)``. Для единообразия
    /// возвращается ``TileSize/wide`` — ближайший «полноширинный» размер D15.
    /// Раскладка не упаковывает панель по этой метке: панель — отдельная строка
    /// под папкой (``panelFolder``), а не плитка.
    public var size: TileSize {
        switch self {
        case .tile(let descriptor): return descriptor.size
        case .folder(let folder): return folder.size
        case .folderContent: return .wide
        }
    }

    /// Ярлык, если элемент — ярлык.
    public var tile: TileDescriptor? {
        guard case .tile(let descriptor) = self else { return nil }
        return descriptor
    }

    /// Папка, если элемент — плитка-папка.
    ///
    /// Панель раскрытой папки (``folderContent(_:)``) сюда не попадает: это не
    /// элемент данных, и её папка доступна через ``panelFolder``. Так
    /// ``TileGridSnapshot/folders`` и обходы снимка не считают одну папку
    /// дважды, когда панель добавлена к набору элементов вью-слоем.
    public var folder: TileFolder? {
        guard case .folder(let folder) = self else { return nil }
        return folder
    }

    /// Папка, если элемент — панель раскрытой папки.
    public var panelFolder: TileFolder? {
        guard case .folderContent(let folder) = self else { return nil }
        return folder
    }

    /// Является ли элемент полноширинной панелью раскрытой папки (D17).
    public var isFolderPanel: Bool {
        if case .folderContent = self { return true }
        return false
    }

    /// Ярлыки папки, если элемент — плитка-папка.
    ///
    /// У панели раскрытой папки содержимое берётся из ``panelFolder``: панель —
    /// представление, а не второй экземпляр папки.
    public var folderTiles: [TileDescriptor] {
        guard case .folder(let folder) = self else { return [] }
        return folder.tiles
    }
}

/// Снимок сетки рабочего стола — то, что читают UI и раскладка.
///
/// Снимок — значение: он не связан с хранилищем и не меняется задним числом.
/// Пиксельной геометрии в нём нет: раскладку считает `TileLayoutEngine` (§3),
/// а снимок даёт порядок, размеры и папки. ``layoutItems`` — готовый вход для
/// `TileLayoutEngine.pack(items:columns:unit:)`.
public struct TileGridSnapshot {

    /// Элементы сетки в порядке отображения: слева направо, сверху вниз.
    public let items: [TileGridItem]

    /// Ярлыки вне сетки: их можно прикрепить; из них же строится список
    /// приложений (§6, двусторонний pin/unpin).
    public let unpinned: [TileDescriptor]

    /// Необязательная таблица явных ячеек (E14.3, D30).
    ///
    /// «Боковой» вход раскладки: пока таблицы нет, сетка раскладывает элементы
    /// упаковкой по порядку ``items`` (строго компактно, как раньше). Если она
    /// есть, полна и корректна для текущего числа колонок сетки, плитки встают
    /// на свои ячейки, а дыры остаются. Неполная, некорректная или рассчитанная
    /// на другую ширину таблица игнорируется целиком — см.
    /// ``TileGridPlacementTable``. `TileStore.snapshot()` таблицу не прикладывает
    /// (ширина сетки ему неизвестна); снимок с таблицей для конкретной ширины
    /// строит ``TileStore/snapshot(columns:)``.
    public let placementTable: TileGridPlacementTable?

    /// Создаёт снимок.
    ///
    /// - Parameters:
    ///   - items: Элементы сетки в порядке отображения.
    ///   - unpinned: Ярлыки вне сетки.
    ///   - placementTable: Таблица явных ячеек; `nil` — раскладка по порядку.
    init(
        items: [TileGridItem],
        unpinned: [TileDescriptor],
        placementTable: TileGridPlacementTable? = nil
    ) {
        self.items = items
        self.unpinned = unpinned
        self.placementTable = placementTable
    }

    /// Пары «идентификатор — размер» в порядке сетки для `TileLayoutEngine`.
    ///
    /// Хранилище не считает раскладку само (§3): оно отдаёт данные, а движок
    /// упаковывает их в юнитные координаты.
    ///
    /// Панель раскрытой папки (``TileGridItem/folderContent(_:)``) в пары не
    /// входит: у неё нет юнитного размера, а её строку и высоту считает
    /// раскладка по идентификатору папки. В снимке `TileStore` панели нет, но
    /// вью-слой может добавить её к набору элементов — фильтр делает
    /// `layoutItems` безопасным и для такого набора.
    public var layoutItems: [(id: AnyHashable, size: TileSize)] {
        items.compactMap { item in
            guard !item.isFolderPanel else { return nil }
            return (id: item.id, size: item.size)
        }
    }

    /// Все папки в порядке сетки.
    ///
    /// Панель раскрытой папки не учитывается: папка уже есть в снимке как
    /// плитка-папка, а панель — её представление (D17).
    public var folders: [TileFolder] {
        items.compactMap { $0.folder }
    }

    /// Пустая ли сетка.
    public var isEmpty: Bool {
        items.isEmpty
    }

    /// Элемент по идентификатору.
    ///
    /// - Parameter id: Идентификатор ярлыка или папки.
    /// - Returns: Элемент сетки или `nil`, если его нет на сетке.
    public func item(withID id: AnyHashable) -> TileGridItem? {
        items.first { $0.id == id }
    }
}

// MARK: - Одобрение операций с папками (D14)

/// Операция группировки, которую TileStore спрашивает у хоста (D14).
///
/// Порядок важен для UI-подсказок: `createFolder` — «собрать папку», `addToFolder`
/// — «положить ярлык в существующую папку», `moveBetweenFolders` — «перенести
/// ярлык в другую папку или обратно на рабочий стол».
public enum TileGroupingAction: Equatable {

    /// Создание папки из ярлыка.
    case createFolder

    /// Добавление ярлыка с сетки в папку.
    case addToFolder

    /// Перемещение ярлыка между папками (или из папки на рабочий стол).
    case moveBetweenFolders
}

/// Функция одобрения операций с папками (D14).
///
/// Хост решает, разрешена ли операция; по умолчанию разрешено всё
/// (`TileStore.approval` = allow-all). Вызывается синхронно на главном потоке
/// до изменения состояния, поэтому функция обязана быть быстрой и не должна
/// трогать сам `TileStore` (иначе получится рекурсия по уведомлениям).
///
/// - Parameters:
///   - folder: Папка-цель; `nil` для `createFolder` и для переноса на рабочий стол.
///   - tile: Ярлык, с которым выполняется операция.
///   - action: Тип операции.
/// - Returns: `true` — операцию выполнять, `false` — отказать без изменения состояния.
public typealias TileGroupingApproval = (_ folder: TileFolder?, _ tile: TileDescriptor, _ action: TileGroupingAction) -> Bool

// MARK: - Ошибки персистентности

/// Ошибки работы с сохранённым состоянием.
public enum TileStoreError: Error, CustomStringConvertible {

    /// Файл записан более новой версией схемы: читать его нельзя.
    case unsupportedSchemaVersion(Int)

    public var description: String {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "TileStore: неподдерживаемая версия схемы \(version)"
        }
    }
}

// MARK: - Хранилище

/// Единственный источник истины для порядка, размеров, папок и закреплений
/// (§5, §6; D12–D15).
///
/// Хранилище держит каталог известных ярлыков (действия — замыкания, они не
/// сериализуются) и отдельно — раскладку: порядок элементов сетки, размеры и
/// папки. Сетка и список приложений только читают снимок и вызывают операции
/// редактирования, поэтому правило «один писатель» (§6) выполняется: пишет
/// только TileStore.
///
/// Использование:
///
/// ```swift
/// let store = TileStore()                        // Application Support/TesseraStartScreen
/// store.approval = { folder, tile, action in true }   // дефолт — разрешено (D14)
/// store.setCatalog(descriptors)                  // ярлыки приложения с действиями
/// try? store.load()                              // восстановить раскладку
/// store.pinTile("weather", columns: 6)           // закрепить: ярлык встанет в новую строку
/// store.resize("weather", to: .wide, columns: 6) // D15: 1×1 / 2×2 / 4×2 / 4×4
/// ```
///
/// Размеры. `TileDescriptor` несёт размер-по-умолчанию (D15, §3), но
/// авторитетный размер хранит TileStore: в снимке ярлыки приходят уже с текущим
/// размером, а смена размера — операция хранилища (§5, resize в edit-режиме).
///
/// Идентификаторы. `TileDescriptor.id` и `TileFolder.id` — `AnyHashable`.
/// В файл они попадают в каноническом виде (`s:` — String, `i:` — Int,
/// `u:` — UUID, `o:` — прочее через `String(describing:)`), поэтому
/// раскладка не зависит от типа идентификатора. Хэшируемые типы без
/// стабильного `description` в персистентности не поддерживаются.
///
/// - Note: Все методы и коллбэки вызываются на главном потоке.
public final class TileStore: ObservableObject {

    // MARK: - Публичные настройки

    /// Публикация изменений для SwiftUI-фасада (iOS 15: только `ObservableObject`).
    ///
    /// Дополнительно к ней есть ``onChange`` — он удобнее UIKit-координатору,
    /// которому нужен готовый снимок, а не факт изменения.
    public let objectWillChange = ObservableObjectPublisher()

    /// Колбэк после каждого изменения состояния: приходит готовый снимок.
    ///
    /// Вызывается на главном потоке, после сохранения (если включено
    /// ``autosaves``). Хранилище в колбэке не модифицируется — только читается.
    public var onChange: ((TileGridSnapshot) -> Void)?

    /// Функция одобрения операций с папками (D14).
    ///
    /// По умолчанию разрешено всё; хост может запретить отдельные операции.
    /// Проверяется до изменения состояния в операциях с папками:
    /// `createFolder(from:onto:title:columns:)`, ``addToFolder(_:folderID:columns:)``,
    /// ``moveBetweenFolders(_:to:columns:)`` и ``extractFromFolder(_:toCell:columns:)``.
    public var approval: TileGroupingApproval = { _, _, _ in true }

    /// Автосохранение после каждой операции редактирования (по умолчанию включено).
    ///
    /// Ошибки записи не прерывают операцию: они попадают в
    /// ``lastPersistenceError``, потому что потеря персистентности не должна
    /// ломать UI. Для явной обработки используйте ``save()``.
    public var autosaves: Bool = true

    /// Последняя ошибка сохранения/загрузки — для диагностики.
    public private(set) var lastPersistenceError: Error?

    /// Резервная копия нечитаемого файла состояния, отложенная последним
    /// ``load()`` (E10.3d), — для диагностики и ручного восстановления.
    ///
    /// Если файл не декодируется или записан более новой схемой, `load()`
    /// переименовывает его в `<имя>.unreadable-<ISO-дата>.json` рядом с
    /// оригиналом, чтобы первое автосохранение не затёрло данные схемой текущей
    /// версии. `nil` — нечитаемых файлов не встречалось.
    public private(set) var lastUnreadableFileBackupURL: URL?

    /// Ширина холста, на которую рассчитаны сохранённые ячейки (E14.1, D32).
    ///
    /// `nil` — ячеек ещё нет: файл версии 1 или первый запуск, ширина сетки
    /// хоста пока не известна. Как только хост сообщает ширину
    /// (``placeItems(columns:)`` или любая операция с `columns`), ячейки
    /// назначаются однократным прогоном `TileLayoutEngine.packCompact` по
    /// текущему порядку и сразу сохраняются. Если ширина хоста отличается от
    /// `canvasColumns`, файл не перезаписывается: для хоста действует проекция
    /// ``placements(forColumns:)``.
    public private(set) var canvasColumns: Int?

    /// Каталог, в котором лежит JSON-файл состояния.
    public let directoryURL: URL

    /// Путь к JSON-файлу состояния.
    public let fileURL: URL

    // MARK: - Внутреннее состояние

    /// Каталог ярлыков в порядке регистрации (действия, иконки, бейджи).
    private var catalog: [TileDescriptor] = []

    /// Индекс каталога по каноническому ключу идентификатора.
    private var catalogIndex: [String: Int] = [:]

    /// Порядок элементов сетки: канонические ключи ярлыков и папок.
    ///
    /// Ярлык, лежащий в папке, в этом массиве не встречается (инвариант
    /// «один ярлык — одно место»).
    private var gridOrder: [String] = []

    /// Авторитетные размеры ярлыков по каноническому ключу.
    ///
    /// Папка хранит свой размер в ``FolderRecord/size``.
    private var sizes: [String: TileSize] = [:]

    /// Папки в порядке сетки (в `gridOrder` они стоят по своим ключам).
    private var folderRecords: [FolderRecord] = []

    /// Прочитан ли файл состояния: после этого новые ярлыки каталога не
    /// закрепляются автоматически (иначе «откреплённые» пользователем ярлыки
    /// возвращались бы при каждом запуске).
    private var restoredFromDisk = false

    /// Регистрировал ли хост каталог (``setCatalog(_:)``): только тогда
    /// ``load()`` чистит папки по каталогу (E10.3c). До регистрации каталога
    /// любой ярлык «неизвестен», и чистка удалила бы всё содержимое папок.
    private var catalogRegistered = false

    /// Нечитаемый файл состояния не удалось отложить в резервную копию:
    /// ``save()`` повторит попытку перед записью и не затрёт файл (E10.3d).
    private var unreadableFilePending = false

    /// Источник текущей даты для имени резервной копии (подменяется в тестах).
    var currentDate: () -> Date = { Date() }

    /// Версия схемы JSON-файла.
    ///
    /// Версия 2 (E14.1, D33): у каждого верхнеуровневого элемента есть ячейка
    /// `row`/`column`, а в документе — ширина холста `columns`. Версия 1
    /// читается и мигрирует лениво (``placeItems(columns:)``).
    private static let schemaVersion = 2

    /// Явные ячейки верхнеуровневых элементов по каноническому ключу (E14.1).
    ///
    /// Есть записи и для невидимых ключей (ярлыков вне текущего каталога): они
    /// хранят свою ячейку, но не участвуют в раскладке и коллизиях (D30).
    /// Пока ``canvasColumns`` равно `nil` («нераскладочное» состояние: файл
    /// версии 1 или первый запуск до того, как стала известна ширина), словарь пуст.
    private var placementsByKey: [String: TileGridPlacement] = [:]

    /// Последняя ширина сетки хоста, которую хранилище узнало из вызова с
    /// `columns` (``placeItems(columns:)``, ``resize(_:to:columns:)`` и т. п.).
    private var hostColumns: Int?

    /// Наименьшее число ярлыков в папке (D45): папка из 0 или 1 ярлыка не
    /// существует.
    ///
    /// Правило действует там, где ярлыки **убирают** из папки (вынос, открепление,
    /// перенос в другую папку, чистка по каталогу) и при загрузке файла; когда папка
    /// теряет ярлык и в ней остаётся один, она **распускается**: последний
    /// ярлык встаёт на ячейку папки со своим размером. Единственное исключение —
    /// переходное состояние публичного ``createFolder(withTile:title:columns:)``
    /// (папка из одного ярлыка до последующего ``addToFolder(_:folderID:columns:)``).
    static let minimumFolderTileCount = 2

    /// Папки, которые файл принёс с одним ярлыком и которые ещё не распущены
    /// (D45).
    ///
    /// Каталог в момент ``load()`` может быть не зарегистрирован: какие из
    /// ярлыков папки на самом деле существуют, пока неизвестно, и распускать
    /// папку рано (удалённое приложение не должно превращаться в «невидимый»
    /// ярлык на сетке). Такие папки запоминаются здесь, а чистка по каталогу
    /// (``pruneFoldersAgainstCatalog()``) распускает их после того, как
    /// каталог зарегистрирован.
    private var underfilledFolderKeys: Set<String> = []

    /// Ярлыки, занявшие место распущенной папки в чистке по каталогу и при
    /// загрузке, вместе с ячейкой папки (D45).
    ///
    /// Их окончательные ячейки считает `resolveDissolvedTiles()` движком
    /// (`inserting` на ячейке папки: бо́льший ярлык выталкивает соседей вниз).
    private var pendingDissolvedTiles: [(key: String, cell: TileGridPlacement)] = []

    /// Каноническое число колонок сетки по умолчанию (6, D26).
    ///
    /// Нужно, когда ширина сетки хоста ещё не известна (``effectiveColumns``):
    /// у `TileStore` нет ширины экрана.
    /// экрана. Значение — ``TileLayoutEngine/defaultColumns``. Если хост задал
    /// своё число колонок, вызывающий передаёт его в ``resize(_:to:columns:)``.
    static let defaultGridColumns = TileLayoutEngine.defaultColumns

    // MARK: - Инициализация

    /// Создаёт хранилище.
    ///
    /// - Parameter directoryURL: Каталог для JSON-файла; `nil` — каталог по
    ///   умолчанию (Application Support/TesseraStartScreen). Каталог
    ///   инжектируется для тестов и для изоляции нескольких рабочих столов.
    public init(directoryURL: URL? = nil) {
        let directory = directoryURL ?? TileStore.defaultDirectoryURL()
        self.directoryURL = directory
        self.fileURL = directory.appendingPathComponent("tiles.json", isDirectory: false)
    }

    /// Каталог по умолчанию: Application Support/TesseraStartScreen.
    ///
    /// Application Support — правильное место для состояния, которое
    /// пользователь не создаёт вручную: оно не бэкапится как документы и не
    /// чистится как Caches. Фолбэки — на случай песочниц без Application Support.
    public static func defaultDirectoryURL() -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("TesseraStartScreen", isDirectory: true)
    }

    // MARK: - Каталог ярлыков

    /// Регистрирует каталог ярлыков приложения (D12).
    ///
    /// Действия ярлыков не сериализуются, поэтому после перезапуска хост
    /// передаёт каталог заново, а ``load()`` накладывает на него сохранённую
    /// раскладку. Вызывайте каталог **до** `load()`: ярлыки, неизвестные на
    /// момент загрузки, останутся в файле, но не попадут в снимок, пока не
    /// появятся в каталоге.
    ///
    /// Размер новых ярлыков берётся из `TileDescriptor.size` (по умолчанию
    /// `.medium` — D12). Передавайте каталог целиком одним вызовом: ярлыки, не
    /// попавшие в текущий вызов, считаются удалёнными и вычищаются из папок.
    ///
    /// Повторные идентификаторы отбрасываются (побеждает первый). На первом
    /// запуске (файла состояния ещё нет) новые ярлыки сразу закрепляются в конце
    /// сетки; после восстановления файла — нет, чтобы не воскрешать откреплённые.
    /// Ярлыки, пропавшие из каталога, убираются из папок (каталог авторитетен
    /// для их содержимого), а папка, в которой осталось меньше двух ярлыков,
    /// распускается (D45): при одном оставшемся ярлыке он встаёт на ячейку папки со
    /// своим размером (бо́льший выталкивает соседей вниз, D31), пустая папка
    /// исчезает — удалённое приложение не оставляет «мёртвых» плиток. Та же
    /// чистка выполняется после ``load()``, если каталог уже зарегистрирован
    /// (E10.3c), поэтому порядок вызовов `setCatalog`/`load` на папки не влияет.
    /// Папки из 0–1 ярлыков, прочитанные из файла, распускаются здесь же.
    /// Ярлыки вне каталога, стоящие прямо на сетке, не удаляются: они остаются
    /// невидимыми ключами и держат своё место до возвращения в каталог.
    ///
    /// Ячейки (E14.1): если они уже есть (``canvasColumns``), новые ярлыки
    /// получают строку в конце холста, а вернувшиеся невидимые — свою прежнюю
    /// ячейку, если она свободна от видимых элементов, иначе тоже новую строку
    /// в конце. Без ячеек (первый запуск) раскладка первого запуска назначается
    /// при первом ``placeItems(columns:)``. Метод файл не пишет.
    ///
    /// - Parameter descriptors: Каталог ярлыков в начальном порядке.
    public func setCatalog(_ descriptors: [TileDescriptor]) {
        // Видимые до смены каталога ключи: при конфликте ячеек они сильнее тех,
        // что только что вернулись в каталог (E14.1, D30).
        let settledBefore = Set(visibleGridKeys())

        var seen = Set<String>()
        var unique: [TileDescriptor] = []
        unique.reserveCapacity(descriptors.count)
        for descriptor in descriptors {
            let key = TileStore.storageKey(for: descriptor.id)
            guard seen.insert(key).inserted else { continue }
            unique.append(descriptor)
        }

        catalog = unique
        catalogRegistered = true
        catalogIndex.removeAll(keepingCapacity: true)
        for (index, descriptor) in unique.enumerated() {
            catalogIndex[TileStore.storageKey(for: descriptor.id)] = index
        }

        // Ярлыки, которых хранилище ещё не знало (нет сохранённого размера):
        // только их можно закрепить автоматически на первом запуске. Так
        // повторная регистрация каталога не воскрешает откреплённые ярлыки.
        var introduced = Set<String>()
        for descriptor in unique {
            let key = TileStore.storageKey(for: descriptor.id)
            if sizes[key] == nil {
                sizes[key] = descriptor.size
                introduced.insert(key)
            }
        }

        pruneFoldersAgainstCatalog()

        if !restoredFromDisk {
            let onGrid = Set(gridOrder)
            for descriptor in unique {
                let key = TileStore.storageKey(for: descriptor.id)
                guard introduced.contains(key), !onGrid.contains(key) else { continue }
                gridOrder.append(key)
            }
        }

        // E14.1: ячейки появившихся ключей — новая строка в конце холста (если
        // ячейки уже есть), вернувшиеся невидимые встают на своё место, если оно
        // свободно. Без ячеек (нераскладочное состояние) ничего не делается:
        // первый запуск раскладывается прогоном `packCompact`, когда известна
        // ширина (``placeItems(columns:)``).
        reconcilePlacements(settled: settledBefore)

        notifyChange()
    }

    /// Ярлык по идентификатору.
    ///
    /// - Parameter id: Идентификатор ярлыка.
    /// - Returns: Ярлык из каталога с текущим размером или `nil`.
    public func descriptor(withID id: AnyHashable) -> TileDescriptor? {
        guard let index = catalogIndex[TileStore.storageKey(for: id)] else { return nil }
        return resolved(catalog[index])
    }

    // MARK: - Снимок

    /// Текущий снимок сетки: порядок, размеры, папки и откреплённые ярлыки.
    ///
    /// Снимок собирается по запросу и не кешируется: сетка читает его после
    /// каждого изменения, а хранилище остаётся единственным источником истины.
    ///
    /// Раскрытая панель папки (D17) в снимок не попадает: хранилище хранит
    /// данные, а состояние «папка раскрыта» — представление. Хост добавляет
    /// ``TileGridItem/folderContent(_:)`` к копии элементов сам, поэтому
    /// персистентность не меняется.
    ///
    /// - Returns: Согласованный снимок сетки.
    public func snapshot() -> TileGridSnapshot {
        makeSnapshot(orderedBy: nil)
    }

    /// Собирает снимок: элементы в порядке чтения ячеек (E14.7).
    ///
    /// Порядок `items` — порядок VoiceOver (``TesseraTileGridView`` отдаёт его
    /// коллекции как порядок индексов), поэтому он обязан совпадать с тем, как
    /// элементы читаются на экране: строка по возрастанию, затем логическая
    /// колонка. `gridOrder` этого не гарантирует после ``load()``, миграции
    /// v1 → v2, ``setCatalog(_:)`` и проекции под другую ширину, поэтому снимок
    /// всегда сортируется по ячейкам, а не берёт `gridOrder` как есть.
    ///
    /// - Parameter columns: Ширина, по ячейкам которой читать порядок:
    ///   ``canvasColumns`` — сохранённые ячейки, иная — проекция (D32);
    ///   `nil` — сохранённые ячейки, а без них (нераскладочное состояние) —
    ///   порядок модели.
    /// - Returns: Снимок без таблицы ячеек.
    private func makeSnapshot(orderedBy columns: Int?) -> TileGridSnapshot {
        var items: [TileGridItem] = []
        var placedKeys = Set<String>()

        for key in readingOrderedKeys(forColumns: columns) {
            if let record = folderRecords.first(where: { $0.key == key }) {
                items.append(.folder(materialize(record)))
                placedKeys.formUnion(record.tileKeys)
            } else if let index = catalogIndex[key] {
                items.append(.tile(resolved(catalog[index])))
                placedKeys.insert(key)
            }
        }

        let unpinned = catalog
            .filter { !placedKeys.contains(TileStore.storageKey(for: $0.id)) }
            .map(resolved)

        return TileGridSnapshot(items: items, unpinned: unpinned)
    }

    /// Снимок сетки с таблицей явных ячеек для ширины `columns` (E14.3, D30).
    ///
    /// Те же элементы и ярлыки вне сетки, что у ``snapshot()``, плюс
    /// ``TileGridSnapshot/placementTable``: ячейки из ``placements(forColumns:)``
    /// (сохранённая раскладка с дырами, если `columns` совпадает с
    /// ``canvasColumns``, иначе проекция без дыр, D32) и заявленная ширина
    /// `columns`. Сетка той же ширины раскладывает плитки на эти ячейки; сетка
    /// другой ширины таблицу игнорирует и упаковывает по порядку.
    ///
    /// С E14.5 это штатный путь хоста и координатора редактирования: сетка
    /// показывает сохранённые ячейки (дыры), а ``onChange`` отдаёт такой же
    /// снимок, когда ширина хоста известна. Хост без хранилища и без таблицы
    /// по-прежнему получает упаковку по порядку.
    ///
    /// - Parameter columns: Число колонок сетки хоста, больше нуля.
    /// - Returns: Снимок; при `columns <= 0` таблица не прикладывается.
    public func snapshot(columns: Int) -> TileGridSnapshot {
        guard columns > 0 else { return snapshot() }
        // E14.7: порядок элементов — порядок чтения именно тех ячеек, что идут в
        // таблице (для другой ширины — проекции), чтобы VoiceOver читал плитки
        // так, как они лежат на экране.
        let base = makeSnapshot(orderedBy: columns)
        return TileGridSnapshot(
            items: base.items,
            unpinned: base.unpinned,
            placementTable: TileGridPlacementTable(
                cells: placements(forColumns: columns),
                columns: columns
            )
        )
    }

    // MARK: - Закрепление

    /// Закреплён ли ярлык (на сетке или в папке).
    ///
    /// - Parameter tileID: Идентификатор ярлыка.
    /// - Returns: `true`, если ярлык есть на сетке или в папке.
    public func isPinned(_ tileID: AnyHashable) -> Bool {
        let key = TileStore.storageKey(for: tileID)
        return gridOrder.contains(key) || folderRecords.contains { $0.tileKeys.contains(key) }
    }

    // MARK: - Папки (D14: только через одобрение хоста)

    /// Размер только что созданной папки: всегда medium (E12.2).
    ///
    /// По памяти о Windows 10 Mobile папка — всегда плитка 2×2, и от размера
    /// ярлыка-цели он не зависит; wide/large цель замещается средней папкой.
    static let newFolderSize: TileSize = .medium

    /// Итог атомарного создания папки из двух ярлыков (E11.6, E14.4).
    enum AtomicFolderResult {

        /// Оба шага одобрены: папка создана, второй ярлык лежит в ней.
        case created(TileFolder)

        /// Хост отклонил создание папки (первый шаг) либо ярлыков нет на сетке.
        case createDenied

        /// Хост отклонил добавление второго ярлыка (второй шаг); состояние не
        /// менялось.
        case addDenied
    }

    /// Папка, в которой лежит ярлык.
    ///
    /// - Parameter tileID: Идентификатор ярлыка.
    /// - Returns: Папка или `nil`, если ярлык не в папке.
    public func folderContaining(_ tileID: AnyHashable) -> TileFolder? {
        let key = TileStore.storageKey(for: tileID)
        guard let record = folderRecords.first(where: { $0.tileKeys.contains(key) }) else {
            return nil
        }
        return materialize(record)
    }

    // MARK: - Ячейки на холсте (E14.1, D30–D33)

    /// Сохранённые ячейки видимых верхнеуровневых элементов на холсте шириной
    /// ``canvasColumns`` (логические координаты, 0 — начало чтения).
    ///
    /// Пусто, пока ячеек нет (``canvasColumns`` равно `nil`). Это именно
    /// сохранённая раскладка: для хоста с другой шириной используйте
    /// ``placements(forColumns:)``. Содержимое папок ячеек не имеет.
    public var placements: [AnyHashable: TileGridPlacement] {
        guard canvasColumns != nil else { return [:] }
        return storedVisiblePlacements()
    }

    /// Ячейка элемента на сохранённом холсте.
    ///
    /// - Parameter id: Идентификатор ярлыка или папки на сетке.
    /// - Returns: Ячейка или `nil`, если ячеек ещё нет либо элемента нет на
    ///   видимой сетке.
    public func placement(of id: AnyHashable) -> TileGridPlacement? {
        guard canvasColumns != nil else { return nil }
        let key = TileStore.storageKey(for: id)
        guard visibleGridKeys().contains(key) else { return nil }
        return placementsByKey[key]
    }

    /// Ячейки видимых элементов для хоста с шириной `columns` (D32).
    ///
    /// Если `columns` совпадает с ``canvasColumns``, возвращается сохранённая
    /// раскладка с дырами. Иначе — **проекция**: плитки в порядке чтения
    /// сохранённых ячеек (строка, затем колонка) упаковываются
    /// `TileLayoutEngine.packCompact` под ширину хоста, без дыр. Проекция
    /// считается на лету и **файл не перезаписывает**: возврат к прежней
    /// ширине без правок возвращает дыры. Без ячеек (``canvasColumns`` равно
    /// `nil`) это упаковка текущего порядка модели. Ярлык шире `columns`
    /// занимает ужатый след (``TileLayoutEngine/fittingSize(_:columns:)``).
    ///
    /// Первая операция редактирования при несовпадении ширины принимает
    /// раскладку под ширину хоста как новый холст (обновляется
    /// ``canvasColumns``): операции по ячейкам считают координаты движком и
    /// принимают проекцию как холст сами (D31).
    ///
    /// - Parameter columns: Число колонок сетки хоста, больше нуля.
    /// - Returns: Ячейки по идентификаторам; пусто при `columns <= 0`.
    public func placements(forColumns columns: Int) -> [AnyHashable: TileGridPlacement] {
        guard columns > 0 else { return [:] }
        if canvasColumns == columns {
            return storedVisiblePlacements()
        }
        var result: [AnyHashable: TileGridPlacement] = [:]
        for (key, placement) in projectedPlacements(columns: columns) {
            if let id = visibleItemID(forKey: key) {
                result[id] = placement
            }
        }
        return result
    }

    /// Идентификаторы видимых элементов в порядке чтения ячеек для ширины
    /// `columns` (строка, затем колонка; при равных ячейках — порядок модели).
    ///
    /// Для ширины, совпадающей с ``canvasColumns``, порядок берётся из
    /// сохранённых ячеек; иначе — из проекции (``placements(forColumns:)``).
    ///
    /// - Parameter columns: Число колонок сетки хоста, больше нуля.
    /// - Returns: Идентификаторы в порядке чтения; пусто при `columns <= 0`.
    public func placementReadingOrder(forColumns columns: Int) -> [AnyHashable] {
        guard columns > 0 else { return [] }
        return readingOrderedKeys(forColumns: columns).compactMap { visibleItemID(forKey: $0) }
    }

    /// Ключи видимых элементов в порядке чтения ячеек (E14.7).
    ///
    /// Один источник порядка для ``snapshot()``, ``snapshot(columns:)`` и
    /// ``placementReadingOrder(forColumns:)``. Порядок чтения — строка по
    /// возрастанию, затем логическая колонка (0 — начало чтения, поэтому в RTL
    /// порядок тот же); пересечений ячеек нет, равные ячейки (повреждённый файл)
    /// остаются в порядке модели.
    ///
    /// - Parameter columns: Ширина хоста; `nil` — без ширины: сохранённые ячейки,
    ///   а если их ещё нет, порядок модели.
    /// - Returns: Канонические ключи видимых элементов.
    private func readingOrderedKeys(forColumns columns: Int?) -> [String] {
        let visible = visibleGridKeys()
        if let columns, columns > 0 {
            let cells = canvasColumns == columns
                ? placementsByKey
                : projectedPlacements(columns: columns)
            return TileStore.readingSorted(visible, by: cells)
        }
        guard canvasColumns != nil else { return visible }
        return TileStore.readingSorted(visible, by: placementsByKey)
    }

    /// Сообщает хранилищу ширину сетки хоста и, если ячеек ещё нет, назначает их
    /// (ленивая миграция v1 → v2 и раскладка первого запуска, E14.1, D33).
    ///
    /// Однократно: если ячеек нет (файл версии 1 или первый запуск), текущий
    /// порядок видимых элементов упаковывается прежним
    /// `TileLayoutEngine.packCompact` для `columns` — внешне ничего не
    /// меняется, — ячейки невидимых ключей ставятся в новые строки в конце, и
    /// результат сразу сохраняется (при ``autosaves``). Если ячейки уже есть,
    /// метод только запоминает ширину; файл не трогается, даже если ширина
    /// отличается от ``canvasColumns`` (D32). Миграция ждёт, пока
    /// зарегистрирован каталог и есть что раскладывать; тогда её выполнят
    /// ``load()`` или следующий вызов. Миграция не сохраняет файл, который
    /// ещё не прочитан ``load()`` (иначе затёрла бы его).
    ///
    /// Ширина запоминается и операциями с `columns` (``resize(_:to:columns:)``,
    /// ``moveItem(_:toCell:columns:)``, ``pinTile(_:columns:)`` и др.).
    ///
    /// Уведомление ``onChange`` не отправляется: снимок сетки не меняется.
    ///
    /// - Parameter columns: Число колонок сетки хоста, больше нуля.
    /// - Returns: `true`, если ячейки назначены этим вызовом.
    @discardableResult
    public func placeItems(columns: Int) -> Bool {
        guard columns > 0 else { return false }
        hostColumns = columns
        let wasUnplaced = canvasColumns == nil
        migrateIfPossible()
        return wasUnplaced && canvasColumns != nil
    }

    // MARK: - Персистентность

    /// Сохраняет состояние в JSON атомарной записью (§5).
    ///
    /// Каталог создаётся при необходимости. Запись атомарная: файл либо старый,
    /// либо новый целиком — оборванный запуск не оставит половину раскладки.
    /// Пишется схема версии 2 (E14.1): у каждого элемента `row`/`column`, в
    /// документе — ширина холста `columns`; пока ячеек нет
    /// (``canvasColumns`` равно `nil`), поля опускаются, и следующий `load()`
    /// считает файл нераскладочным.
    ///
    /// Если ``load()`` нашёл нечитаемый файл и не смог отложить его в
    /// резервную копию, запись сначала повторяет эту попытку и при неудаче
    /// бросает ошибку: нечитаемый файл не затирается (E10.3d).
    ///
    /// - Throws: Ошибку файловой системы или кодирования JSON.
    public func save() throws {
        if unreadableFilePending {
            try backUpUnreadableFile()
        }

        let document = TileStoreDocument(
            version: TileStore.schemaVersion,
            columns: canvasColumns,
            items: makeDocumentItems(),
            sizes: sizes,
            folders: folderRecords.map {
                TileStoreDocument.Folder(key: $0.key, title: $0.title, size: $0.size, tileKeys: $0.tileKeys)
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        lastPersistenceError = nil
    }

    /// Читает сохранённое состояние и накладывает его на текущий каталог.
    ///
    /// Восстанавливаются порядок сетки, размеры, папки и закрепления; каталог
    /// ярлыков (действия) остаётся тем, что зарегистрировал хост. Ярлыки из
    /// файла, которых нет в каталоге, стоящие прямо на сетке, сохраняются в
    /// модели невидимыми ключами: в снимок они не попадают, но держат место до
    /// регистрации. Если каталог уже зарегистрирован, папки чистятся по нему,
    /// как в ``setCatalog(_:)``: неизвестные ярлыки из папок убираются, папка
    /// без единого ярлыка каталога распускается (E10.3c). Папка, которая есть
    /// в файле, но отсутствует в порядке сетки, не теряется — она встаёт в
    /// конец сетки.
    ///
    /// Файл версии 1 (ячеек нет) мигрирует лениво (E14.1, D33): `load()` идёт до
    /// того, как известна ширина сетки, поэтому ячейки назначает
    /// ``placeItems(columns:)`` — однократным прогоном `packCompact` по
    /// сохранённому порядку, с немедленной записью версии 2. Если ширина уже
    /// известна, миграция выполняется в конце `load()`. Версия новее
    /// поддерживаемой обрабатывается как и раньше (резервная копия, состояние
    /// не меняется).
    ///
    /// Если файла нет — ничего не происходит (первый запуск). Ошибка чтения не
    /// меняет текущее состояние и пробрасывается вызывающему. Если файл
    /// прочитан, но не декодируется или записан более новой схемой, он до
    /// любой записи переименовывается в резервную копию
    /// `<имя>.unreadable-<ISO-дата>.json` рядом (``lastUnreadableFileBackupURL``):
    /// хранилище продолжает работу с текущим состоянием, а автосохранение
    /// пишет новый файл, не затирая нечитаемый (E10.3d).
    ///
    /// - Throws: Ошибку чтения/декодирования или ``TileStoreError``.
    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        // Ошибка ввода-вывода (нет доступа и т. п.) может быть временной:
        // файл не трогаем, просто пробрасываем.
        let data = try Data(contentsOf: fileURL)

        let document: TileStoreDocument
        do {
            document = try JSONDecoder().decode(TileStoreDocument.self, from: data)
            guard document.version <= TileStore.schemaVersion else {
                throw TileStoreError.unsupportedSchemaVersion(document.version)
            }
        } catch {
            // Содержимое прочитано, но понять его нельзя: откладываем файл в
            // резервную копию до того, как первое автосохранение запишет схему
            // текущей версии поверх.
            lastPersistenceError = error
            unreadableFilePending = true
            try? backUpUnreadableFile()
            throw error
        }

        apply(document)
        if catalogRegistered {
            pruneFoldersAgainstCatalog()
        }
        restoredFromDisk = true
        // E14.1: ячейки из файла приводятся к инвариантам (границы, коллизии
        // видимых); файл версии 1 мигрирует, если хост уже сообщил ширину.
        reconcilePlacements()
        migrateIfPossible()
        notifyChange()
    }

    /// Переименовывает нечитаемый файл состояния в резервную копию (E10.3d).
    ///
    /// Имя — `<имя>.unreadable-<ISO-дата>.json` в том же каталоге (двоеточия
    /// времени заменены дефисами). Переименование в пределах каталога атомарно;
    /// существующая копия не перезаписывается — к имени добавляется `-2`, `-3`…
    /// Если файла уже нет, откладывать нечего.
    ///
    /// - Throws: Ошибку файловой системы, если файл не удалось переименовать.
    private func backUpUnreadableFile() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            unreadableFilePending = false
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: currentDate()).replacingOccurrences(of: ":", with: "-")
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension.isEmpty ? "json" : fileURL.pathExtension

        var lastError: Error?
        for attempt in 1...100 {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let backupURL = directoryURL.appendingPathComponent(
                "\(baseName).unreadable-\(stamp)\(suffix).\(fileExtension)",
                isDirectory: false
            )
            guard !fileManager.fileExists(atPath: backupURL.path) else { continue }
            do {
                // `moveItem` не перезаписывает существующий файл: если копию
                // успели создать между проверкой и переименованием, пробуем
                // следующее имя.
                try fileManager.moveItem(at: fileURL, to: backupURL)
                lastUnreadableFileBackupURL = backupURL
                unreadableFilePending = false
                return
            } catch {
                lastError = error
                guard fileManager.fileExists(atPath: fileURL.path) else {
                    unreadableFilePending = false
                    return
                }
            }
        }
        throw lastError ?? CocoaError(.fileWriteFileExists)
    }

    /// Применяет прочитанный документ к модели.
    ///
    /// Метод терпим к мусору в файле: дубликаты отбрасываются, ярлык не может
    /// оказаться и на сетке, и в папке, папки без содержимого распускаются.
    /// Это дешевле, чем падать на слегка испорченном файле состояния.
    ///
    /// - Parameter document: Прочитанный документ.
    private func apply(_ document: TileStoreDocument) {
        sizes = document.sizes

        var seenFolders = Set<String>()
        folderRecords = document.folders
            .filter { seenFolders.insert($0.key).inserted }
            .map {
                FolderRecord(
                    key: $0.key,
                    id: TileStore.identifier(fromStorageKey: $0.key),
                    title: $0.title,
                    size: $0.size,
                    tileKeys: $0.tileKeys
                )
            }

        // Ярлык принадлежит максимум одной папке: первый по порядку файла
        // побеждает. Папка не может лежать в папке — ключи папок отбрасываются.
        let recordKeys = Set(folderRecords.map { $0.key })
        var claimed = Set<String>()
        for index in folderRecords.indices {
            folderRecords[index].tileKeys = folderRecords[index].tileKeys.filter {
                !recordKeys.contains($0) && claimed.insert($0).inserted
            }
        }

        // Пустые папки не имеют смысла на сетке — распускаем.
        var dissolved = Set<String>()
        folderRecords.removeAll { record in
            if record.tileKeys.isEmpty {
                dissolved.insert(record.key)
                return true
            }
            return false
        }

        // D45: папка из одного ярлыка (файл старой версии, ручная правка) тоже
        // не существует, но распустить её можно только когда известен каталог:
        // ярлык мог исчезнуть из приложения. Запоминаем такие папки — чистка по
        // каталогу доведёт дело (``pruneFoldersAgainstCatalog()``).
        underfilledFolderKeys = Set(
            folderRecords
                .filter { $0.tileKeys.count < TileStore.minimumFolderTileCount }
                .map { $0.key }
        )
        pendingDissolvedTiles = []

        let folderKeys = Set(folderRecords.map { $0.key })
        var order: [String] = []
        var seenItems = Set<String>()
        for item in document.items {
            guard seenItems.insert(item.key).inserted else { continue }
            guard !dissolved.contains(item.key) else { continue }
            switch item.kind {
            case .folder:
                guard folderKeys.contains(item.key) else { continue }
            case .tile:
                // Ярлык может ещё не быть в каталоге — место запоминаем.
                break
            }
            order.append(item.key)
        }

        // Инвариант: ярлык из папки не дублируется на сетке.
        let tilesInFolders = Set(folderRecords.flatMap { $0.tileKeys })
        order.removeAll { tilesInFolders.contains($0) }

        // «Сиротские» папки: есть в `folders`, но не в порядке сетки. Без места
        // на сетке их ярлыки пропали бы из снимка и из списка откреплённых —
        // ставим такие папки в конец сетки в порядке файла (E10.3c).
        let placed = Set(order)
        for record in folderRecords where !placed.contains(record.key) {
            order.append(record.key)
        }

        gridOrder = order
        applyStoredPlacements(from: document)
    }

    /// Накладывает на модель ячейки из документа (E14.1).
    ///
    /// Нераскладочное состояние (``canvasColumns`` равно `nil`, ячеек нет):
    /// файл версии 1; в документе нет ширины холста; **частичный** набор —
    /// хотя бы у одного уцелевшего элемента нет `row`/`column`. Ячейки тогда
    /// назначит ленивая миграция.
    ///
    /// Отдельные плохие значения (отрицательные, чрезмерные, не помещающиеся в
    /// холст) — «нарушители»: запись о них отбрасывается, и ``reconcilePlacements(settled:)``
    /// переносит их в новые строки в конце. Коллизии видимых элементов также
    /// разрешает он — когда известно, кто видим.
    ///
    /// - Parameter document: Прочитанный документ.
    private func applyStoredPlacements(from document: TileStoreDocument) {
        placementsByKey = [:]
        canvasColumns = nil
        guard let columns = document.columns, columns > 0 else { return }

        var firstItems: [String: TileStoreDocument.Item] = [:]
        for item in document.items where firstItems[item.key] == nil {
            firstItems[item.key] = item
        }

        var parsed: [String: TileGridPlacement] = [:]
        for key in gridOrder {
            guard let item = firstItems[key], let row = item.row, let column = item.column else {
                return
            }
            parsed[key] = TileGridPlacement(row: row, column: column)
        }

        for (key, placement) in parsed where isPlacementValid(placement, forKey: key, columns: columns) {
            placementsByKey[key] = placement
        }
        canvasColumns = columns
    }

    /// Раскладка в виде элементов JSON-документа, с признаком «ярлык/папка».
    ///
    /// - Returns: Элементы в порядке сетки (с ячейками, если они есть).
    private func makeDocumentItems() -> [TileStoreDocument.Item] {
        let folderKeys = Set(folderRecords.map { $0.key })
        let hasCanvas = canvasColumns != nil
        return gridOrder.map { key in
            let placement = hasCanvas ? placementsByKey[key] : nil
            return TileStoreDocument.Item(
                kind: folderKeys.contains(key) ? .folder : .tile,
                key: key,
                row: placement?.row,
                column: placement?.column
            )
        }
    }

    // MARK: - Уведомления и служебные операции

    /// Сообщает об изменении после операции: сохранение (если включено
    /// ``autosaves``), затем снимок подписчикам.
    ///
    /// Координаты операции уже посчитаны движком и сохраняются как есть
    /// (``commitCells(_:columns:)``): пересчёта упаковкой нет.
    private func didChange() {
        if autosaves {
            saveIfPossible()
        }
        notifyChange()
    }

    /// Отправляет снимок подписчикам: `objectWillChange` и ``onChange``.
    ///
    /// E14.5: если хранилище знает ширину сетки хоста (её сообщает координатор
    /// редактирования, ``placeItems(columns:)``), снимок идёт с таблицей явных
    /// ячеек (``snapshot(columns:)``) — хост, применяющий `onChange` к сетке,
    /// получает дыры, а не упаковку по порядку. Без известной ширины снимок
    /// прежний: сетка раскладывает его упаковкой.
    private func notifyChange() {
        let snapshot = hostColumns.map { snapshot(columns: $0) } ?? snapshot()
        objectWillChange.send()
        onChange?(snapshot)
    }

    /// Сохраняет состояние, запоминая ошибку вместо проброса.
    private func saveIfPossible() {
        do {
            try save()
        } catch {
            lastPersistenceError = error
        }
    }

    /// Виден ли ключ сетки в снимке: папка или ярлык из текущего каталога.
    ///
    /// Остальные ключи `gridOrder` — невидимые: ярлыки, которых нет в
    /// каталоге (``load()`` запоминает их место до регистрации).
    ///
    /// - Parameter key: Канонический ключ из `gridOrder`.
    /// - Returns: `true`, если элемент попадает в ``snapshot()``.
    private func isVisibleGridKey(_ key: String) -> Bool {
        catalogIndex[key] != nil || folderRecords.contains { $0.key == key }
    }

    /// Ключи видимых элементов сетки в порядке снимка (E10.3a).
    ///
    /// Порядок совпадает с `snapshot().items` и `layoutItems`: это порядок чтения
    /// ячеек (``gridOrder``).
    ///
    /// - Returns: Канонические ключи видимых элементов.
    private func visibleGridKeys() -> [String] {
        let folderKeys = Set(folderRecords.map { $0.key })
        return gridOrder.filter { catalogIndex[$0] != nil || folderKeys.contains($0) }
    }

    /// Применяет новый порядок видимых элементов, не двигая невидимые
    /// (E8.7, E10.3a).
    ///
    /// `visibleKeys` — ключи элементов снимка в новом порядке (порядок чтения
    /// ячеек, ``commitCells(_:columns:)``). В `gridOrder` бывают ключи,
    /// которых в снимке нет: ярлыки, ещё не зарегистрированные в каталоге
    /// (``load()`` их запоминает). Их место не должно меняться от операции с
    /// другим элементом, поэтому они остаются на прежних индексах `gridOrder`,
    /// а видимые элементы занимают остальные позиции в новом порядке.
    ///
    /// Если в `visibleKeys` есть дубликаты или невидимый ключ, порядок не
    /// меняется: лучше оставить прежнюю раскладку, чем потерять или задвоить
    /// ключ в `gridOrder`. Проверка полноты набора — на вызывающем.
    ///
    /// - Parameter visibleKeys: Канонические ключи видимых элементов в новом порядке.
    /// - Returns: `true`, если `gridOrder` изменился.
    @discardableResult
    private func applyVisibleOrder(_ visibleKeys: [String]) -> Bool {
        let visibleSet = Set(visibleKeys)
        guard visibleSet.count == visibleKeys.count else { return false }

        let hidden = gridOrder.enumerated().filter { !isVisibleGridKey($0.element) }
        guard !hidden.contains(where: { visibleSet.contains($0.element) }) else { return false }

        var result = visibleKeys
        for (index, key) in hidden {
            result.insert(key, at: min(index, result.count))
        }

        guard result != gridOrder else { return false }
        gridOrder = result
        return true
    }

    // MARK: - Ячейки: внутренние операции (E14.1)

    /// Запоминает ширину хоста из вызова с `columns`.
    ///
    /// - Parameter columns: Число колонок; `nil` и неположительные игнорируются.
    private func noteHostColumns(_ columns: Int?) {
        guard let columns = columns, columns > 0 else { return }
        hostColumns = columns
    }

    /// Ширина, для которой пересчитываются ячейки после операции: последняя
    /// ширина хоста, иначе ширина холста, иначе умолчание (D26). Внутренняя:
    /// страница списка приложений берёт её, когда хост не передал колонки (E14.5).
    var effectiveColumns: Int {
        hostColumns ?? canvasColumns ?? TileStore.defaultGridColumns
    }

    /// Размер элемента по ключу: папка, затем сохранённый размер, затем каталог.
    private func storedSize(ofKey key: String) -> TileSize {
        if let record = folderRecords.first(where: { $0.key == key }) { return record.size }
        if let size = sizes[key] { return size }
        if let index = catalogIndex[key] { return catalog[index].size }
        return .medium
    }

    /// Размер элемента, ужатый под ширину холста (D15, E14.1).
    private func footprint(ofKey key: String, columns: Int) -> TileSize {
        TileLayoutEngine.fittingSize(storedSize(ofKey: key), columns: columns)
    }

    /// Идентификатор видимого элемента по ключу.
    private func visibleItemID(forKey key: String) -> AnyHashable? {
        if let record = folderRecords.first(where: { $0.key == key }) { return record.id }
        if let index = catalogIndex[key] { return catalog[index].id }
        return nil
    }

    /// Сохранённые ячейки видимых элементов по идентификаторам.
    private func storedVisiblePlacements() -> [AnyHashable: TileGridPlacement] {
        var result: [AnyHashable: TileGridPlacement] = [:]
        for key in visibleGridKeys() {
            guard let placement = placementsByKey[key], let id = visibleItemID(forKey: key) else { continue }
            result[id] = placement
        }
        return result
    }

    /// Прежняя компактная упаковка (`packCompact`) ключей в заданном порядке.
    ///
    /// - Parameters:
    ///   - keys: Ключи в порядке упаковки.
    ///   - columns: Ширина холста, больше нуля.
    /// - Returns: Ячейки по ключам (элемент, который не поместился, пропускается).
    private func packedPlacements(of keys: [String], columns: Int) -> [String: TileGridPlacement] {
        guard columns > 0 else { return [:] }
        let slots = TileLayoutEngine.packCompact(
            items: keys.map { (id: AnyHashable($0), size: footprint(ofKey: $0, columns: columns)) },
            columns: columns,
            unit: 1
        )
        var result: [String: TileGridPlacement] = [:]
        for slot in slots {
            guard let key = slot.id.base as? String else { continue }
            result[key] = TileGridPlacement(row: slot.row, column: slot.column)
        }
        return result
    }

    /// Проекция раскладки на ширину `columns` без дыр (D32): видимые элементы
    /// в порядке чтения сохранённых ячеек (без ячеек — в порядке модели)
    /// упаковываются `packCompact`.
    private func projectedPlacements(columns: Int) -> [String: TileGridPlacement] {
        var keys = visibleGridKeys()
        if canvasColumns != nil {
            keys = TileStore.readingSorted(keys, by: placementsByKey)
        }
        return packedPlacements(of: keys, columns: columns)
    }

    /// Ключи в порядке чтения ячеек (строка, колонка); при равных ячейках и без
    /// ячеек — исходный порядок (сортировка устойчива за счёт индекса).
    private static func readingSorted(_ keys: [String], by cells: [String: TileGridPlacement]) -> [String] {
        keys.enumerated().sorted { lhs, rhs in
            switch (cells[lhs.element], cells[rhs.element]) {
            case let (left?, right?):
                if left != right { return TileGridPlacement.isReadingOrdered(left, before: right) }
                return lhs.offset < rhs.offset
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map { $0.element }
    }

    /// Допустима ли ячейка: неотрицательна, не чрезмерна и целиком в холсте.
    private func isPlacementValid(_ placement: TileGridPlacement, forKey key: String, columns: Int) -> Bool {
        guard placement.row >= 0, placement.column >= 0,
              placement.row <= TileStore.maxPlacementRow,
              placement.column < columns else { return false }
        let size = footprint(ofKey: key, columns: columns)
        return placement.column + size.unitColumns <= columns
    }

    /// Разумный предел строки в файле: больше — мусор, а не раскладка.
    private static let maxPlacementRow = 100_000

    /// Однократная ленивая миграция: назначает ячейки прогоном `packCompact`.
    ///
    /// Нужны ширина хоста, зарегистрированный каталог и непустой порядок.
    /// После миграции файл сразу сохраняется, но только если он не
    /// затёрт непрочитанное состояние (``restoredFromDisk`` либо файла нет).
    private func migrateIfPossible() {
        guard canvasColumns == nil, let columns = hostColumns, columns > 0,
              catalogRegistered, !gridOrder.isEmpty else { return }
        placementsByKey = packedPlacements(of: visibleGridKeys(), columns: columns)
        canvasColumns = columns
        reconcilePlacements()

        guard autosaves, restoredFromDisk || !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        saveIfPossible()
    }

    /// Приводит ячейки к инвариантам холста (E14.1, D30).
    ///
    /// Ничего не делает, пока ячеек нет. Иначе:
    /// - записи для ключей, которых нет в порядке сетки, удаляются;
    /// - видимые элементы (в порядке сетки, «устоявшиеся» — `settled` — вперёд)
    ///   сохраняют свою ячейку, если она целиком в холсте и не пересекается с
    ///   уже принятыми; остальные — нарушители и новички — упаковываются
    ///   `packCompact` в **новые строки в конце холста** (первая строка после
    ///   последней занятой видимыми элементами; один новичок встаёт в колонку 0);
    /// - невидимые ключи сохраняют ячейку, если она в границах холста, и **не
    ///   участвуют в коллизиях**; без допустимой ячейки они получают её в
    ///   строках после видимых.
    ///
    /// - Parameter settled: Ключи, видимые до изменения каталога.
    private func reconcilePlacements(settled: Set<String> = []) {
        guard let columns = canvasColumns, columns > 0 else { return }

        let visible = visibleGridKeys()
        let visibleSet = Set(visible)
        let indexInGrid = Dictionary(
            gridOrder.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Прямоугольник элемента: (строка, колонка, ширина, высота) в юнитах.
        typealias Rect = (row: Int, column: Int, width: Int, height: Int)
        func overlaps(_ a: Rect, _ b: Rect) -> Bool {
            a.column < b.column + b.width && b.column < a.column + a.width
                && a.row < b.row + b.height && b.row < a.row + a.height
        }

        var accepted: [Rect] = []
        var next: [String: TileGridPlacement] = [:]
        var pendingVisible: [String] = []

        let priority = visible.filter { settled.contains($0) } + visible.filter { !settled.contains($0) }
        for key in priority {
            let size = footprint(ofKey: key, columns: columns)
            if let placement = placementsByKey[key],
               isPlacementValid(placement, forKey: key, columns: columns) {
                let rect: Rect = (placement.row, placement.column, size.unitColumns, size.unitRows)
                if !accepted.contains(where: { overlaps($0, rect) }) {
                    accepted.append(rect)
                    next[key] = placement
                    continue
                }
            }
            pendingVisible.append(key)
        }
        pendingVisible.sort { (indexInGrid[$0] ?? 0) < (indexInGrid[$1] ?? 0) }

        var pendingHidden: [String] = []
        for key in gridOrder where !visibleSet.contains(key) {
            if let placement = placementsByKey[key], isPlacementValid(placement, forKey: key, columns: columns) {
                next[key] = placement
            } else {
                pendingHidden.append(key)
            }
        }

        // Новые строки в конце: ниже последней занятой видимыми строки.
        var baseRow = accepted.map { $0.row + $0.height }.max() ?? 0
        for group in [pendingVisible, pendingHidden] where !group.isEmpty {
            let packed = packedPlacements(of: group, columns: columns)
            var bottom = baseRow
            for key in group {
                guard let cell = packed[key] else { continue }
                next[key] = TileGridPlacement(row: baseRow + cell.row, column: cell.column)
                let size = footprint(ofKey: key, columns: columns)
                bottom = max(bottom, baseRow + cell.row + size.unitRows)
            }
            baseRow = bottom
        }

        placementsByKey = next
    }

    /// Убирает из папок ярлыки, которых больше нет в каталоге, и распускает
    /// папки, в которых осталось меньше двух ярлыков (D45).
    ///
    /// Вызывается при перерегистрации каталога и после ``load()`` при
    /// зарегистрированном каталоге (E10.3c): удалённое приложение не должно
    /// оставлять «мёртвые» идентификаторы в папках, а папка без единого ярлыка
    /// каталога — пустую плитку на сетке. Политика: каталог авторитетен для
    /// содержимого папок (неизвестные ярлыки из них удаляются, **невидимых**
    /// членов папки после чистки не бывает), а ярлыки вне каталога прямо на
    /// сетке остаются невидимыми ключами.
    ///
    /// D45: папка, потерявшая в чистке ярлыки (или пришедшая из файла с одним
    /// ярлыком, ``underfilledFolderKeys``), при двух и более видимых ярлыках
    /// остаётся; при одном — **распускается**: ярлык встаёт на ячейку папки со
    /// своим размером (``dissolveFolder(withKey:)``); при нуле — исчезает.
    /// Папка, которой чистка не коснулась, правилом не затрагивается (переходная
    /// папка ``createFolder(withTile:title:columns:)`` переживает
    /// повторную регистрацию каталога).
    private func pruneFoldersAgainstCatalog() {
        var affected = underfilledFolderKeys
        underfilledFolderKeys = []
        for index in folderRecords.indices {
            let before = folderRecords[index].tileKeys.count
            folderRecords[index].tileKeys.removeAll { catalogIndex[$0] == nil }
            if folderRecords[index].tileKeys.count != before {
                affected.insert(folderRecords[index].key)
            }
        }

        // Порядок — по папкам сетки, а не по множеству: каскад выталкивания
        // детерминирован.
        var removedAny = false
        for key in folderRecords.map({ $0.key }) where affected.contains(key) {
            guard let record = folderRecords.first(where: { $0.key == key }),
                  record.tileKeys.count < TileStore.minimumFolderTileCount else { continue }
            dissolveFolder(withKey: key)
            removedAny = true
        }
        if removedAny { resolveDissolvedTiles() }
    }

    /// Распускает папку структурно: убирает её из модели, а единственный
    /// оставшийся ярлык ставит на её место (D45).
    ///
    /// Для чистки по каталогу и загрузки (операции пользователя считают то же
    /// самое по набору размещений, ``dissolveFolderIfNeeded(withKey:in:columns:)``).
    /// Пустая папка просто исчезает. Ярлык с одним оставшимся ключом
    /// занимает в `gridOrder` индекс папки, а его ячейка — ячейка папки, ужатая
    /// под холст (``TileLayoutEngine/clamped(cell:size:columns:)``); окончательно
    /// решает ``resolveDissolvedTiles()`` (выталкивание соседей), если ячейки
    /// уже есть.
    ///
    /// - Parameter folderKey: Ключ папки, в которой меньше двух ярлыков.
    private func dissolveFolder(withKey folderKey: String) {
        guard let recordIndex = folderRecords.firstIndex(where: { $0.key == folderKey }) else { return }
        let record = folderRecords.remove(at: recordIndex)
        let folderCell = placementsByKey.removeValue(forKey: folderKey)

        guard let remaining = record.tileKeys.first, record.tileKeys.count == 1 else {
            gridOrder.removeAll { $0 == folderKey }
            return
        }

        // Ярлык не может остаться и на сетке (инвариант «одно место»), но файл
        // бывает испорчен: прежнюю запись убираем, место — папки.
        gridOrder.removeAll { $0 == remaining }
        if let position = gridOrder.firstIndex(of: folderKey) {
            gridOrder[position] = remaining
        } else {
            gridOrder.append(remaining)
        }

        if let columns = canvasColumns, columns > 0, let folderCell {
            let cell = TileLayoutEngine.clamped(
                cell: folderCell,
                size: storedSize(ofKey: remaining),
                columns: columns
            )
            placementsByKey[remaining] = cell
            pendingDissolvedTiles.append((key: remaining, cell: cell))
        }
    }

    /// Доводит ячейки ярлыков, занявших место распущенных папок (D45):
    /// ставит каждый на ячейку папки через `TileLayoutEngine.inserting`.
    ///
    /// Бо́льший ярлык (wide, large) выталкивает соседей вниз каскадом (D31),
    /// слишком правая колонка сдвигается влево, меньший оставляет дыру. Если
    /// видимый набор ещё не корректен (файл с перекрытиями, нет ячеек у
    /// части ярлыков), расчёт пропускается: коллизии разрешит
    /// ``reconcilePlacements(settled:)``. Порядок модели после расчёта —
    /// порядок чтения ячеек.
    private func resolveDissolvedTiles() {
        let pending = pendingDissolvedTiles
        pendingDissolvedTiles = []
        guard !pending.isEmpty, let columns = canvasColumns, columns > 0 else { return }

        let pendingKeys = Set(pending.map { $0.key })
        var items: [TilePlacedItem] = []
        for key in visibleGridKeys() where !pendingKeys.contains(key) {
            guard let cell = placementsByKey[key] else { return }
            items.append(TilePlacedItem(id: AnyHashable(key), size: storedSize(ofKey: key), cell: cell))
        }
        guard TileLayoutEngine.validate(items, columns: columns).isEmpty else { return }

        for entry in pending where catalogIndex[entry.key] != nil {
            items = TileLayoutEngine.inserting(
                id: AnyHashable(entry.key),
                size: storedSize(ofKey: entry.key),
                at: entry.cell,
                into: items,
                columns: columns
            )
        }
        for item in items {
            if let key = item.id.base as? String { placementsByKey[key] = item.cell }
        }
        applyVisibleOrder(TileStore.readingSorted(visibleGridKeys(), by: placementsByKey))
    }

    /// Ярлык с авторитетным размером из хранилища.
    ///
    /// - Parameter descriptor: Запись каталога.
    /// - Returns: Копия ярлыка с текущим размером.
    private func resolved(_ descriptor: TileDescriptor) -> TileDescriptor {
        var copy = descriptor
        copy.size = sizes[TileStore.storageKey(for: descriptor.id)] ?? descriptor.size
        return copy
    }

    /// Собирает публичную модель папки по внутренней записи.
    ///
    /// - Parameter record: Внутренняя запись папки.
    /// - Returns: Папка с разрешёнными ярлыками и их размерами.
    private func materialize(_ record: FolderRecord) -> TileFolder {
        TileFolder(
            id: record.id,
            title: record.title,
            icon: record.icon,
            tiles: record.tileKeys.compactMap { key in
                guard let index = catalogIndex[key] else { return nil }
                return resolved(catalog[index])
            },
            size: record.size
        )
    }

    // MARK: - Канонические ключи идентификаторов

    /// Канонический вид `AnyHashable`-идентификатора для хранения и сравнения.
    ///
    /// Тип попадает в префикс, чтобы `String("1")` и `Int(1)` не считались
    /// одним ярлыком. Прочие хэшируемые типы кодируются через `description`:
    /// для персистентности это работает, только если `description` стабилен
    /// между запусками (для `URL`, например, стабилен).
    ///
    /// - Parameter id: Идентификатор ярлыка или папки.
    /// - Returns: Строковый ключ.
    private static func storageKey(for id: AnyHashable) -> String {
        switch id.base {
        case let string as String: return "s:" + string
        case let int as Int: return "i:" + String(int)
        case let uuid as UUID: return "u:" + uuid.uuidString
        default: return "o:" + String(describing: id.base)
        }
    }

    /// Восстанавливает идентификатор папки из канонического ключа.
    ///
    /// Папки создаёт только TileStore, поэтому на практике это всегда `String`
    /// (`folder-UUID`); остальные ветки — для чтения старых/ручных файлов.
    ///
    /// - Parameter key: Строковый ключ из файла состояния.
    /// - Returns: Идентификатор для публичной модели.
    private static func identifier(fromStorageKey key: String) -> AnyHashable {
        if key.hasPrefix("s:") {
            return AnyHashable(String(key.dropFirst(2)))
        }
        if key.hasPrefix("i:"), let value = Int(key.dropFirst(2)) {
            return AnyHashable(value)
        }
        if key.hasPrefix("u:"), let value = UUID(uuidString: String(key.dropFirst(2))) {
            return AnyHashable(value)
        }
        if key.hasPrefix("o:") {
            return AnyHashable(String(key.dropFirst(2)))
        }
        return AnyHashable(key)
    }
}

// MARK: - Операции по ячейкам (E14.4, D30–D33)

/// Операции над верхнеуровневыми элементами **по координатам**: движок
/// (`TileLayoutEngine+Placement`) считает новые ячейки, хранилище применяет их
/// как есть (E14.4).
///
/// Индексного API нет (E14.6, D33): позиция элемента — ячейка, порядок чтения
/// производный. Свойства операций:
///
/// - дыры не схлопываются: уход элемента оставляет свободную ячейку, рост и
///   вставка выталкивают мешающие плитки вниз каскадом (D31);
/// - операция заканчивается ``didChange()`` и пишет координаты, которые посчитал
///   движок, без пересчёта упаковкой;
/// - ширина хоста `columns` передаётся явно, она же становится шириной холста
///   (``canvasColumns``). Если сохранённая раскладка рассчитана на другую
///   ширину, первая же успешная операция принимает репак по порядку чтения
///   (проекцию D32) как новый холст и применяет к нему свою правку;
/// - порядок модели (`gridOrder`, он же порядок `snapshot().items`) после операции —
///   порядок чтения ячеек (строка, колонка), файл пишет элементы в нём;
/// - ярлыки вне каталога (невидимые ключи) хранят свои ячейки, но в коллизиях
///   не участвуют (E14.1);
/// - схлопывание пустых строк — отдельная операция ``collapseEmptyRows(columns:)``:
///   её зовёт слой правки только на drop, остальные операции строк не схлопывают;
/// - папка не бывает из 0–1 ярлыков (D45): когда операция убирает ярлык из
///   папки и там остаётся один, папка распускается, а оставшийся ярлык встаёт на
///   её ячейку со своим размером (бо́льший выталкивает соседей вниз). Исключение —
///   переходная папка ``createFolder(withTile:title:columns:)``.
///
/// Операция с неверным вводом (нет элемента, нет в каталоге, `columns <= 0`,
/// отказ хоста) ничего не меняет и возвращает `false`; уведомление и запись —
/// ровно одна на успешную операцию. Операции с группировкой спрашивают у хоста
/// одобрение (D14).
extension TileStore {

    // MARK: Перенос

    /// Переносит ярлык или папку на ячейку (E14.4, D31).
    ///
    /// Элемент встаёт на `cell`, ограниченную холстом (слишком правая колонка
    /// сдвигается влево); плитки, которые мешают, выталкиваются вниз каскадом
    /// (`TileLayoutEngine.inserting`). Место, которое элемент освободил, остаётся
    /// дырой — репака нет. Одобрение хоста не спрашивается: это операция
    /// раскладки, а не группировки (D14).
    ///
    /// - Parameters:
    ///   - itemID: Идентификатор ярлыка или папки на сетке.
    ///   - cell: Желаемая ячейка левого верхнего угла (логические координаты).
    ///   - columns: Число колонок сетки хоста, больше нуля.
    /// - Returns: `true`, если раскладка изменилась; `false` — элемента нет на
    ///   сетке, элемент уже на этой ячейке и ничего не двигается либо `columns <= 0`.
    @discardableResult
    public func moveItem(_ itemID: AnyHashable, toCell cell: TileGridPlacement, columns: Int) -> Bool {
        guard columns > 0 else { return false }
        noteHostColumns(columns)
        let key = TileStore.storageKey(for: itemID)
        guard visibleGridKeys().contains(key) else { return false }

        let basis = cellBasis(columns: columns)
        let moved = TileLayoutEngine.inserting(
            id: AnyHashable(key),
            size: storedSize(ofKey: key),
            at: cell,
            into: basis,
            columns: columns
        )
        guard moved != basis else { return false }
        commitCells(moved, columns: columns)
        didChange()
        return true
    }

    /// Переносит ярлык или папку в новую строку в конце холста (E14.4, D33).
    ///
    /// Цель — `TileLayoutEngine.newRowCell`: первая строка после последней
    /// занятой (без учёта самого переносимого элемента), колонка 0. Остальное —
    /// как в ``moveItem(_:toCell:columns:)``.
    ///
    /// - Parameters:
    ///   - itemID: Идентификатор ярлыка или папки на сетке.
    ///   - columns: Число колонок сетки хоста, больше нуля.
    /// - Returns: `true`, если раскладка изменилась.
    @discardableResult
    public func moveItemToNewRow(_ itemID: AnyHashable, columns: Int) -> Bool {
        guard columns > 0 else { return false }
        noteHostColumns(columns)
        let key = TileStore.storageKey(for: itemID)
        guard visibleGridKeys().contains(key) else { return false }

        let basis = cellBasis(columns: columns)
        let cell = TileLayoutEngine.newRowCell(
            size: storedSize(ofKey: key),
            columns: columns,
            placements: basis,
            excluding: AnyHashable(key)
        )
        let moved = TileLayoutEngine.inserting(
            id: AnyHashable(key),
            size: storedSize(ofKey: key),
            at: cell,
            into: basis,
            columns: columns
        )
        guard moved != basis else { return false }
        commitCells(moved, columns: columns)
        didChange()
        return true
    }

    // MARK: Размер

    /// Меняет размер ярлыка или папки на месте (E14.4, D15, D31).
    ///
    /// Якорная ячейка остаётся (если новая ширина не помещается, колонка
    /// сдвигается влево); рост выталкивает мешающие плитки вниз каскадом
    /// (`TileLayoutEngine.resizing`), уменьшение оставляет дыру. Ярлык в папке
    /// или вне сетки просто меняет авторитетный размер, ячейки не меняются.
    ///
    /// - Parameters:
    ///   - itemID: Идентификатор ярлыка или папки.
    ///   - size: Новый размер (D15).
    ///   - columns: Число колонок сетки хоста, больше нуля.
    /// - Returns: `true`, если размер изменился; `false` — элемента нет, размер
    ///   тот же либо `columns <= 0`.
    @discardableResult
    public func resize(_ itemID: AnyHashable, to size: TileSize, columns: Int) -> Bool {
        guard columns > 0 else { return false }
        noteHostColumns(columns)
        let key = TileStore.storageKey(for: itemID)

        let folderIndex = folderRecords.firstIndex { $0.key == key }
        guard folderIndex != nil || catalogIndex[key] != nil else { return false }
        let currentSize: TileSize? = folderIndex.map { folderRecords[$0].size } ?? sizes[key]
        guard currentSize != size else { return false }

        // Раскладка считается до записи размера: базис несёт прежние размеры.
        let basis = cellBasis(columns: columns)
        let resized = TileLayoutEngine.resizing(
            id: AnyHashable(key),
            to: size,
            in: basis,
            columns: columns
        )

        if let index = folderIndex {
            folderRecords[index].size = size
        } else {
            sizes[key] = size
        }
        commitCells(resized, columns: columns)
        didChange()
        return true
    }

    // MARK: Папки

    /// Создаёт папку из двух ярлыков на месте цели (E14.4, D20, D31).
    ///
    /// Папка всегда средняя (2×2, E12.2). Она встаёт на ячейку ярлыка-цели
    /// через `TileLayoutEngine.inserting`: малая цель растёт до 2×2 и выталкивает
    /// соседей вниз каскадом, слишком правая колонка сдвигается влево. Ярлыки
    /// цели и источника уходят с верхнего уровня, их ячейки остаются дырами,
    /// кроме тех, что накрыла папка. Внутри папки порядок: цель, затем источник.
    ///
    /// Хост одобряет оба шага по очереди (`.createFolder`, затем `.addToFolder`,
    /// как у двух раздельных вызовов); состояние до обоих
    /// одобрений не меняется, при отказе откатывать нечего.
    ///
    /// - Parameters:
    ///   - sourceID: Перетаскиваемый ярлык на сетке.
    ///   - targetID: Ярлык на сетке, на месте которого встанет папка.
    ///   - title: Название папки.
    ///   - columns: Число колонок сетки хоста, больше нуля.
    /// - Returns: Итог операции (`.createDenied` также при неверном вводе).
    func createFolder(
        from sourceID: AnyHashable,
        onto targetID: AnyHashable,
        title: String = "",
        columns: Int
    ) -> AtomicFolderResult {
        guard columns > 0 else { return .createDenied }
        noteHostColumns(columns)
        let sourceKey = TileStore.storageKey(for: sourceID)
        let targetKey = TileStore.storageKey(for: targetID)
        let visible = Set(visibleGridKeys())
        guard sourceKey != targetKey,
              let sourceCatalog = catalogIndex[sourceKey],
              let targetCatalog = catalogIndex[targetKey],
              visible.contains(sourceKey), visible.contains(targetKey) else {
            return .createDenied
        }

        let basis = cellBasis(columns: columns)
        guard let targetItem = basis.first(where: { $0.id == AnyHashable(targetKey) }) else {
            return .createDenied
        }

        let folderID = AnyHashable("folder-" + UUID().uuidString)
        var record = FolderRecord(
            key: TileStore.storageKey(for: folderID),
            id: folderID,
            title: title,
            size: TileStore.newFolderSize,
            tileKeys: [targetKey]
        )
        guard approval(nil, catalog[targetCatalog], .createFolder) else { return .createDenied }
        guard approval(materialize(record), catalog[sourceCatalog], .addToFolder) else { return .addDenied }

        record.tileKeys.append(sourceKey)
        var items = TileLayoutEngine.removing(id: AnyHashable(sourceKey), from: basis)
        items = TileLayoutEngine.removing(id: AnyHashable(targetKey), from: items)
        items = TileLayoutEngine.inserting(
            id: AnyHashable(record.key),
            size: record.size,
            at: targetItem.cell,
            into: items,
            columns: columns
        )

        folderRecords.append(record)
        gridOrder.removeAll { $0 == sourceKey || $0 == targetKey }
        gridOrder.append(record.key)
        commitCells(items, columns: columns)
        didChange()
        return .created(materialize(record))
    }

    /// Создаёт папку из одного ярлыка на его месте (E14.5, D20, D31).
    ///
    /// Папка всегда 2×2 и встаёт на ячейку
    /// ярлыка через `TileLayoutEngine.inserting`: соседи выталкиваются вниз
    /// каскадом. Хост одобряет создание (`.createFolder`).
    ///
    /// D45: папка из одного ярлыка — **переходное** состояние: хост обязан
    /// следом добавить в неё второй ярлык (``addToFolder(_:folderID:columns:)``).
    /// Правило «папка не бывает из 0–1 ярлыков» хранилище
    /// проводит, когда ярлыки **убирают** из папки и при загрузке файла; сама
    /// по себе одноярлычная папка до этого момента не распускается (и
    /// переживает ``setCatalog(_:)``).
    ///
    /// - Parameters:
    ///   - tileID: Ярлык на сетке, который станет первым содержимым папки.
    ///   - title: Название папки.
    ///   - columns: Число колонок сетки хоста, больше нуля.
    /// - Returns: Созданная папка или `nil` (нет ярлыка на сетке, `columns <= 0`
    ///   либо отказ хоста).
    @discardableResult
    public func createFolder(withTile tileID: AnyHashable, title: String = "", columns: Int) -> TileFolder? {
        guard columns > 0 else { return nil }
        noteHostColumns(columns)
        let tileKey = TileStore.storageKey(for: tileID)
        guard let catalogPosition = catalogIndex[tileKey],
              visibleGridKeys().contains(tileKey) else {
            return nil
        }
        let basis = cellBasis(columns: columns)
        guard let tileItem = basis.first(where: { $0.id == AnyHashable(tileKey) }) else { return nil }
        guard approval(nil, catalog[catalogPosition], .createFolder) else { return nil }

        let folderID = AnyHashable("folder-" + UUID().uuidString)
        let record = FolderRecord(
            key: TileStore.storageKey(for: folderID),
            id: folderID,
            title: title,
            size: TileStore.newFolderSize,
            tileKeys: [tileKey]
        )
        var items = TileLayoutEngine.removing(id: AnyHashable(tileKey), from: basis)
        items = TileLayoutEngine.inserting(
            id: AnyHashable(record.key),
            size: record.size,
            at: tileItem.cell,
            into: items,
            columns: columns
        )

        folderRecords.append(record)
        gridOrder.removeAll { $0 == tileKey }
        gridOrder.append(record.key)
        commitCells(items, columns: columns)
        didChange()
        return materialize(record)
    }

    /// Добавляет ярлык с сетки в существующую папку (E14.4).
    ///
    /// Ярлык уходит с верхнего уровня, его ячейка остаётся дырой (репака нет);
    /// папка сохраняет свою ячейку и размер.
    ///
    /// - Parameters:
    ///   - tileID: Ярлык на сетке.
    ///   - folderID: Идентификатор папки.
    ///   - columns: Число колонок сетки хоста, больше нуля.
    /// - Returns: `true`, если состояние изменилось; `false` — ярлык уже в этой
    ///   папке или в другой, ярлыка/папки нет, хост запретил либо `columns <= 0`.
    @discardableResult
    public func addToFolder(_ tileID: AnyHashable, folderID: AnyHashable, columns: Int) -> Bool {
        guard columns > 0 else { return false }
        noteHostColumns(columns)
        let tileKey = TileStore.storageKey(for: tileID)
        let folderKey = TileStore.storageKey(for: folderID)

        guard let catalogPosition = catalogIndex[tileKey],
              let folderIndex = folderRecords.firstIndex(where: { $0.key == folderKey }),
              !folderRecords[folderIndex].tileKeys.contains(tileKey),
              visibleGridKeys().contains(tileKey) else {
            return false
        }
        guard approval(materialize(folderRecords[folderIndex]), catalog[catalogPosition], .addToFolder) else {
            return false
        }

        let items = TileLayoutEngine.removing(id: AnyHashable(tileKey), from: cellBasis(columns: columns))
        gridOrder.removeAll { $0 == tileKey }
        folderRecords[folderIndex].tileKeys.append(tileKey)
        commitCells(items, columns: columns)
        didChange()
        return true
    }

    /// Выносит ярлык из папки на сетку, на ячейку (E14.4, D31).
    ///
    /// Ярлык становится верхнеуровневым элементом со своим размером на `cell`,
    /// ограниченной холстом; мешающие плитки выталкиваются вниз каскадом.
    /// Папка не бывает из 0–1 ярлыков (D45): если в ней остался один ярлык,
    /// папка **распускается**, и этот ярлык встаёт на её ячейку со своим
    /// размером (``dissolveFolderIfNeeded(withKey:in:columns:)``) — до того, как
    /// встанет вынесенный. Если папка опустела (в ней был один ярлык — переходная
    /// папка ``createFolder(withTile:title:columns:)``), она исчезает, а её
    /// ячейка остаётся дырой. Хост одобряет перенос как `.moveBetweenFolders`
    /// с папкой-целью `nil` (D14). Операция — одно изменение модели (один `onChange`).
    ///
    /// - Parameters:
    ///   - tileID: Ярлык, лежащий в папке.
    ///   - cell: Желаемая ячейка левого верхнего угла.
    ///   - columns: Число колонок сетки хоста, больше нуля.
    /// - Returns: `true`, если состояние изменилось; `false` — ярлыка нет в папке,
    ///   хост запретил либо `columns <= 0`.
    @discardableResult
    public func extractFromFolder(_ tileID: AnyHashable, toCell cell: TileGridPlacement, columns: Int) -> Bool {
        performExtract(tileID, cell: cell, columns: columns)
    }

    /// Выносит ярлык из папки в новую строку в конце холста (E14.4, D33).
    ///
    /// Как ``extractFromFolder(_:toCell:columns:)``, но ячейка — первая строка
    /// после последней занятой, колонка 0. Папка, которая распалась (D45) или
    /// исчезла, в расчёт строки не входит: оставшийся ярлык стоит на её
    /// ячейке со своим размером, и строка считается уже с ним.
    ///
    /// - Parameters:
    ///   - tileID: Ярлык, лежащий в папке.
    ///   - columns: Число колонок сетки хоста, больше нуля.
    /// - Returns: `true`, если состояние изменилось.
    @discardableResult
    public func extractFromFolderToNewRow(_ tileID: AnyHashable, columns: Int) -> Bool {
        performExtract(tileID, cell: nil, columns: columns)
    }

    /// Перемещает ярлык из одной папки в другую, не трогая остальную раскладку
    /// (E14.4).
    ///
    /// Папка-источник, в которой остался один ярлык, **распускается** (D45):
    /// оставшийся ярлык встаёт на её ячейку со своим размером; бо́льший ярлык
    /// выталкивает соседей вниз (D31), меньший оставляет дыру. Папка, которая
    /// опустела (переходная папка из одного ярлыка), исчезает, а её ячейка
    /// остаётся дырой (схлопывание — ``collapseEmptyRows(columns:)``). Хост
    /// одобряет перенос как `.moveBetweenFolders` (D14). Возврат на рабочий стол —
    /// ``extractFromFolder(_:toCell:columns:)``.
    ///
    /// - Parameters:
    ///   - tileID: Ярлык, лежащий в папке.
    ///   - folderID: Папка-цель.
    ///   - columns: Число колонок сетки хоста, больше нуля.
    /// - Returns: `true`, если состояние изменилось; `false` — ярлыка нет ни в
    ///   одной папке, цель совпадает с текущей папкой или не существует, хост
    ///   запретил либо `columns <= 0`.
    @discardableResult
    public func moveBetweenFolders(_ tileID: AnyHashable, to folderID: AnyHashable, columns: Int) -> Bool {
        guard columns > 0 else { return false }
        noteHostColumns(columns)
        let tileKey = TileStore.storageKey(for: tileID)
        let folderKey = TileStore.storageKey(for: folderID)

        guard let catalogPosition = catalogIndex[tileKey],
              let sourceIndex = folderRecords.firstIndex(where: { $0.tileKeys.contains(tileKey) }),
              let targetIndex = folderRecords.firstIndex(where: { $0.key == folderKey }),
              targetIndex != sourceIndex else {
            return false
        }
        guard approval(materialize(folderRecords[targetIndex]), catalog[catalogPosition], .moveBetweenFolders) else {
            return false
        }

        var items = cellBasis(columns: columns)
        let sourceKey = folderRecords[sourceIndex].key
        folderRecords[sourceIndex].tileKeys.removeAll { $0 == tileKey }
        folderRecords[targetIndex].tileKeys.append(tileKey)
        // D45: в папке-источнике осталось меньше двух — она распускается.
        dissolveFolderIfNeeded(withKey: sourceKey, in: &items, columns: columns)
        commitCells(items, columns: columns)
        didChange()
        return true
    }

    // MARK: Закрепление

    /// Открепляет ярлык: уход с сетки оставляет дыру (E14.4, D30).
    ///
    /// Ярлык на сетке просто уходит, его ячейка остаётся свободной. Ярлык из
    /// папки выходит из неё; если в папке остался один ярлык, она
    /// **распускается** (D45): оставшийся ярлык встаёт на ячейку папки со своим
    /// размером (``dissolveFolderIfNeeded(withKey:in:columns:)``). Опустевшая
    /// папка (переходная, из одного ярлыка) исчезает, и её ячейка остаётся дырой.
    /// Одобрение хоста не спрашивается (D14: открепление не группировка).
    ///
    /// - Parameters:
    ///   - tileID: Идентификатор ярлыка.
    ///   - columns: Число колонок сетки хоста, больше нуля.
    /// - Returns: `true`, если состояние изменилось.
    @discardableResult
    public func unpin(_ tileID: AnyHashable, columns: Int) -> Bool {
        guard columns > 0 else { return false }
        noteHostColumns(columns)
        let key = TileStore.storageKey(for: tileID)

        if let index = folderRecords.firstIndex(where: { $0.tileKeys.contains(key) }) {
            var items = cellBasis(columns: columns)
            let folderKey = folderRecords[index].key
            folderRecords[index].tileKeys.removeAll { $0 == key }
            // D45: в папке осталось меньше двух — она распускается.
            dissolveFolderIfNeeded(withKey: folderKey, in: &items, columns: columns)
            commitCells(items, columns: columns)
            didChange()
            return true
        }

        guard catalogIndex[key] != nil, gridOrder.contains(key) else { return false }
        let items = TileLayoutEngine.removing(id: AnyHashable(key), from: cellBasis(columns: columns))
        gridOrder.removeAll { $0 == key }
        commitCells(items, columns: columns)
        didChange()
        return true
    }

    /// Закрепляет ярлык на сетке в новой строке в конце холста (E14.4, D33).
    ///
    /// Размер берётся из сохранённых размеров или умолчания дескриптора (D15);
    /// на узкой сетке плитка ужимается движком (`fittingSize`), колонка — 0.
    ///
    /// - Parameters:
    ///   - tileID: Идентификатор ярлыка из каталога.
    ///   - columns: Число колонок сетки хоста, больше нуля.
    /// - Returns: `true`, если ярлык закреплён; `false` — его нет в каталоге, он
    ///   уже на сетке или в папке либо `columns <= 0`.
    @discardableResult
    public func pinTile(_ tileID: AnyHashable, columns: Int) -> Bool {
        guard columns > 0 else { return false }
        noteHostColumns(columns)
        let key = TileStore.storageKey(for: tileID)
        guard let catalogPosition = catalogIndex[key], !gridOrder.contains(key),
              folderContaining(tileID) == nil else { return false }

        if sizes[key] == nil {
            sizes[key] = catalog[catalogPosition].size
        }
        let size = storedSize(ofKey: key)
        let basis = cellBasis(columns: columns)
        let cell = TileLayoutEngine.newRowCell(size: size, columns: columns, placements: basis)
        let items = TileLayoutEngine.inserting(
            id: AnyHashable(key),
            size: size,
            at: cell,
            into: basis,
            columns: columns
        )
        gridOrder.append(key)
        commitCells(items, columns: columns)
        didChange()
        return true
    }

    // MARK: Схлопывание

    /// Схлопывает пустые строки холста (E14.4, D31).
    ///
    /// Строка удаляется, только если её не покрывает ни один элемент (высокие
    /// плитки покрывают все свои строки). Зовёт слой правки **только на drop**,
    /// никогда во время drag. Идемпотентна: на раскладке без пустых строк ничего
    /// не меняет, не пишет файл и не уведомляет.
    ///
    /// - Parameter columns: Число колонок сетки хоста, больше нуля.
    /// - Returns: `true`, если раскладка изменилась.
    @discardableResult
    public func collapseEmptyRows(columns: Int) -> Bool {
        guard columns > 0 else { return false }
        noteHostColumns(columns)

        let basis = cellBasis(columns: columns)
        let collapsed = TileLayoutEngine.collapsingEmptyRows(in: basis, columns: columns)
        guard collapsed != basis else { return false }
        commitCells(collapsed, columns: columns)
        didChange()
        return true
    }

    // MARK: Внутреннее

    /// Общая часть выноса из папки (E14.4): ячейка либо новая строка.
    ///
    /// - Parameters:
    ///   - tileID: Ярлык, лежащий в папке.
    ///   - cell: Ячейка; `nil` — новая строка в конце холста.
    ///   - columns: Число колонок сетки хоста.
    private func performExtract(_ tileID: AnyHashable, cell: TileGridPlacement?, columns: Int) -> Bool {
        guard columns > 0 else { return false }
        noteHostColumns(columns)
        let key = TileStore.storageKey(for: tileID)

        guard let catalogPosition = catalogIndex[key],
              let sourceIndex = folderRecords.firstIndex(where: { $0.tileKeys.contains(key) }) else {
            return false
        }
        guard approval(nil, catalog[catalogPosition], .moveBetweenFolders) else { return false }

        var items = cellBasis(columns: columns)
        let folderKey = folderRecords[sourceIndex].key
        folderRecords[sourceIndex].tileKeys.removeAll { $0 == key }
        // D45: папка с одним ярлыком распускается раньше, чем встанет вынесенный:
        // оставшийся ярлык занимает ячейку папки, а вынесенный встаёт на `cell` по
        // обычным правилам (на ячейку папки он тоже может попасть — тогда
        // оставшийся уходит вниз).
        dissolveFolderIfNeeded(withKey: folderKey, in: &items, columns: columns)

        let size = storedSize(ofKey: key)
        let target = cell ?? TileLayoutEngine.newRowCell(size: size, columns: columns, placements: items)
        items = TileLayoutEngine.inserting(
            id: AnyHashable(key),
            size: size,
            at: target,
            into: items,
            columns: columns
        )
        gridOrder.append(key)
        commitCells(items, columns: columns)
        didChange()
        return true
    }

    /// Распускает папку, в которой после ухода ярлыка осталось меньше двух (D45).
    ///
    /// Ничего не делает, если ярлыков в папке достаточно. Иначе папка исчезает
    /// из модели и из набора `items`; единственный оставшийся видимый ярлык
    /// встаёт на **ячейку папки со своим размером** через
    /// `TileLayoutEngine.inserting`: бо́льший (wide, large) выталкивает соседей
    /// вниз каскадом (D31), слишком правая колонка сдвигается влево, меньший
    /// оставляет дыру. Размер ярлыка — авторитетный размер хранилища
    /// (``storedSize(ofKey:)``), его выбор пользователя не теряется. Пустая
    /// папка просто исчезает.
    ///
    /// Запись `gridOrder` и порядок чтения приводит ``commitCells(_:columns:)``;
    /// вызывающий обязан вызвать его (и ``didChange()``) после. Невидимых членов
    /// у папки в операциях не бывает: каталог авторитетен (``pruneFoldersAgainstCatalog()``).
    ///
    /// - Parameters:
    ///   - folderKey: Ключ папки, из которой только что убрали ярлык.
    ///   - items: Рабочий набор размещений; обновляется на месте.
    ///   - columns: Ширина холста.
    /// - Returns: Ключ ярлыка, занявшего место папки, либо `nil` (папка осталась
    ///   или исчезла пустой).
    @discardableResult
    private func dissolveFolderIfNeeded(
        withKey folderKey: String,
        in items: inout [TilePlacedItem],
        columns: Int
    ) -> String? {
        guard let index = folderRecords.firstIndex(where: { $0.key == folderKey }),
              folderRecords[index].tileKeys.count < TileStore.minimumFolderTileCount else {
            return nil
        }
        let record = folderRecords.remove(at: index)
        gridOrder.removeAll { $0 == folderKey }
        let folderCell = items.first { $0.id == AnyHashable(folderKey) }?.cell
        items = TileLayoutEngine.removing(id: AnyHashable(folderKey), from: items)

        guard record.tileKeys.count == 1, let remaining = record.tileKeys.first,
              catalogIndex[remaining] != nil, let cell = folderCell else {
            return nil
        }
        items = TileLayoutEngine.inserting(
            id: AnyHashable(remaining),
            size: storedSize(ofKey: remaining),
            at: cell,
            into: items,
            columns: columns
        )
        gridOrder.append(remaining)
        return remaining
    }

    /// Рабочий набор размещений видимых элементов для ширины `columns`
    /// (E14.4): отправная точка каждой операции по ячейкам.
    ///
    /// Если холст той же ширины, берутся сохранённые ячейки (с дырами); иначе
    /// (D32) — проекция ``placements(forColumns:)``: репак по порядку чтения без
    /// дыр, и операция применяется к нему. Сам метод **ничего не меняет**:
    /// холст принимает ``commitCells(_:columns:)`` только после успешной
    /// операции, поэтому отказ не перезаписывает файл. Размеры — запрошенные
    /// (след ужимает движок). Набор, не прошедший `validate`, заменяется
    /// проекцией.
    ///
    /// - Parameter columns: Число колонок, больше нуля.
    /// - Returns: Элементы в порядке сетки; идентификатор — канонический ключ.
    private func cellBasis(columns: Int) -> [TilePlacedItem] {
        let keys = visibleGridKeys()

        func build(from cells: [String: TileGridPlacement]) -> [TilePlacedItem] {
            var items: [TilePlacedItem] = []
            items.reserveCapacity(keys.count)
            var missing: [String] = []
            for key in keys {
                if let cell = cells[key] {
                    items.append(TilePlacedItem(id: AnyHashable(key), size: storedSize(ofKey: key), cell: cell))
                } else {
                    missing.append(key)
                }
            }
            // Защита: у видимого ключа нет ячейки — новая строка в конце.
            for key in missing {
                let size = storedSize(ofKey: key)
                let cell = TileLayoutEngine.newRowCell(size: size, columns: columns, placements: items)
                items = TileLayoutEngine.inserting(
                    id: AnyHashable(key), size: size, at: cell, into: items, columns: columns
                )
            }
            return items
        }

        let stored = canvasColumns == columns ? placementsByKey : projectedPlacements(columns: columns)
        let items = build(from: stored)
        if TileLayoutEngine.validate(items, columns: columns).isEmpty {
            return items
        }
        return build(from: projectedPlacements(columns: columns))
    }

    /// Принимает посчитанную раскладку как модель (E14.4): ячейки видимых
    /// элементов, ширина холста и порядок чтения.
    ///
    /// Ячейки невидимых ключей сохраняются (в коллизиях не участвуют), а те, что
    /// не помещаются в новую ширину, получают место в конце
    /// (``reconcilePlacements(settled:)``). `gridOrder` для видимых элементов
    /// становится порядком чтения ячеек; структурные правки `gridOrder` (уход
    /// ярлыка, новая папка) вызывающий делает до вызова. Уведомление и запись —
    /// на вызывающем (``didChange()``).
    ///
    /// - Parameters:
    ///   - items: Размещения всех видимых элементов после операции.
    ///   - columns: Ширина холста (ширина хоста).
    private func commitCells(_ items: [TilePlacedItem], columns: Int) {
        var next: [String: TileGridPlacement] = [:]
        for item in items {
            if let key = item.id.base as? String { next[key] = item.cell }
        }
        let visibleSet = Set(visibleGridKeys())
        for key in gridOrder where !visibleSet.contains(key) {
            if let placement = placementsByKey[key] { next[key] = placement }
        }
        placementsByKey = next
        canvasColumns = columns

        let ordered = TileStore.readingSorted(items.compactMap { $0.id.base as? String }, by: next)
        applyVisibleOrder(ordered)
        reconcilePlacements()
    }
}

// MARK: - Внутренние записи

/// Внутренняя запись папки: ярлыки хранятся ключами, а не копиями.
///
/// Копии `TileDescriptor` внутри папки устаревали бы при перерегистрации
/// каталога (новые подписи/иконки), поэтому публичная ``TileFolder``
/// собирается по запросу.
private struct FolderRecord {

    /// Канонический ключ папки (по нему папка стоит в порядке сетки).
    var key: String

    /// Идентификатор папки для публичной модели.
    var id: AnyHashable

    /// Подпись папки.
    var title: String

    /// Иконка-превью; в файл не пишется (runtime-состояние).
    var icon: UIImage?

    /// Размер плитки-папки.
    var size: TileSize

    /// Канонические ключи ярлыков в порядке отображения.
    var tileKeys: [String]
}

// MARK: - JSON-схема состояния

/// Версионированный документ состояния (читается только TileStore).
///
/// Каталог ярлыков в файл не попадает: `action` — замыкание, его нельзя
/// сериализовать. Хранится только раскладка: порядок, ячейки и ширина холста
/// (версия 2, E14.1), размеры, папки.
/// Ключи элементов — канонические строки (см. `TileStore.storageKey(for:)`),
/// поэтому схема не зависит от типа `AnyHashable`-идентификатора.
private struct TileStoreDocument: Codable {

    /// Версия схемы; запись читается, только если она не новее текущей.
    var version: Int

    /// Ширина холста в юнитах, на которую рассчитаны `row`/`column` (версия 2).
    ///
    /// В файле версии 1 и в нераскладочном состоянии поля нет.
    var columns: Int?

    /// Порядок элементов сетки.
    var items: [Item]

    /// Размеры ярлыков по каноническим ключам.
    var sizes: [String: TileSize]

    /// Папки с составом и размерами.
    var folders: [Folder]

    /// Элемент порядка сетки.
    struct Item: Codable {

        /// Что за элемент: ярлык или папка.
        enum Kind: String, Codable {
            case tile
            case folder
        }

        var kind: Kind
        var key: String

        /// Строка левого верхнего угла элемента (версия 2).
        var row: Int?

        /// Колонка левого верхнего угла элемента (версия 2).
        var column: Int?
    }

    /// Папка в файле состояния.
    struct Folder: Codable {
        var key: String
        var title: String
        var size: TileSize
        var tileKeys: [String]
    }
}
#endif
