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
/// `TileStore` и файл состояния её не содержат, а вью-слой **заменяет** ею
/// плитку папки на том же индексе («разворот на месте»). Она живёт в этом же
/// перечислении, чтобы раскладка (`TileLayoutEngine`/
/// `TesseraTileCollectionViewLayout`) видела раскрытую панель в общем порядке
/// элементов.
public enum TileGridItem {

    /// Ярлык с текущим размером из хранилища.
    case tile(TileDescriptor)

    /// Папка вместе с её ярлыками (в порядке папки).
    case folder(TileFolder)

    /// Полноширинная панель раскрытой папки (D17, E7.1).
    ///
    /// Панель показывает заголовок папки и сетку её содержимого. Раскрытие
    /// «на месте»: в наборе элементов вью-слой **заменяет** плитку-папку панелью
    /// по тому же индексу, поэтому число элементов не меняется, а панель
    /// занимает верхний край и место бывшей плитки (``folderContent(_:)``
    /// растягивается на всю ширину). В данных панели нет: это представление
    /// состояния «папка раскрыта», поэтому в снимке `TileStore` панель не
    /// появляется и между запусками не сохраняется. Идентификатор панели
    /// совпадает с идентификатором папки — по нему раскладка находит след
    /// папки, на место которого встаёт.
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
    /// Раскладка не упаковывает панель по этой метке: место в упаковке она
    /// берёт у самой папки (``panelFolder``), чтобы занять ровно её след.
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

    /// Пары «идентификатор — размер» в порядке сетки для `TileLayoutEngine`.
    ///
    /// Хранилище не считает раскладку само (§3): оно отдаёт данные, а движок
    /// упаковывает их в юнитные координаты.
    ///
    /// Панель раскрытой папки (``TileGridItem/folderContent(_:)``) в пары не
    /// входит: у неё нет юнитного размера, а её место и высоту считает
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
/// store.pin("weather")                           // закрепить: ярлык появится на сетке
/// store.resize("weather", to: .wide)             // D15: 1×1 / 2×2 / 4×2 / 4×4
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
    /// Проверяется до изменения состояния в ``createFolder(withTile:title:)``,
    /// ``addToFolder(_:folderID:)`` и ``moveBetweenFolders(_:to:)``.
    public var approval: TileGroupingApproval = { _, _, _ in true }

    /// Автосохранение после каждой операции редактирования (по умолчанию включено).
    ///
    /// Ошибки записи не прерывают операцию: они попадают в
    /// ``lastPersistenceError``, потому что потеря персистентности не должна
    /// ломать UI. Для явной обработки используйте ``save()``.
    public var autosaves: Bool = true

    /// Последняя ошибка сохранения/загрузки — для диагностики.
    public private(set) var lastPersistenceError: Error?

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

    /// Версия схемы JSON-файла.
    private static let schemaVersion = 1

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
    /// Ярлыки, пропавшие из каталога, убираются из папок, а опустевшие папки
    /// распускаются: удалённое приложение не оставляет «мёртвых» плиток.
    ///
    /// - Parameter descriptors: Каталог ярлыков в начальном порядке.
    public func setCatalog(_ descriptors: [TileDescriptor]) {
        var seen = Set<String>()
        var unique: [TileDescriptor] = []
        unique.reserveCapacity(descriptors.count)
        for descriptor in descriptors {
            let key = TileStore.storageKey(for: descriptor.id)
            guard seen.insert(key).inserted else { continue }
            unique.append(descriptor)
        }

        catalog = unique
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
        var items: [TileGridItem] = []
        var placedKeys = Set<String>()

        for key in gridOrder {
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

    // MARK: - Закрепление

    /// Закрепляет ярлык на сетке (§6: pin из списка приложений).
    ///
    /// - Parameters:
    ///   - tileID: Идентификатор ярлыка из каталога.
    ///   - index: Позиция в сетке; `nil` — в конец.
    /// - Returns: `true`, если состояние изменилось.
    @discardableResult
    public func pin(_ tileID: AnyHashable, at index: Int? = nil) -> Bool {
        let key = TileStore.storageKey(for: tileID)
        guard catalogIndex[key] != nil, !gridOrder.contains(key) else { return false }
        guard folderContaining(tileID) == nil else { return false }

        if sizes[key] == nil, let index = catalogIndex[key] {
            sizes[key] = catalog[index].size
        }
        let position = index.map { min(max($0, 0), gridOrder.count) } ?? gridOrder.count
        gridOrder.insert(key, at: position)
        didChange()
        return true
    }

    /// Открепляет ярлык: убирает его с сетки, но оставляет в каталоге
    /// (он остаётся доступен в списке приложений).
    ///
    /// Если ярлык лежал в папке, он удаляется из папки; опустевшая папка
    /// распускается — иначе на сетке осталась бы плитка без содержимого.
    /// Удаление папки — следствие открепления последнего ярлыка, а не отдельная
    /// операция группировки, поэтому одобрение хоста здесь не спрашивается (D14).
    ///
    /// - Parameter tileID: Идентификатор ярлыка.
    /// - Returns: `true`, если состояние изменилось.
    @discardableResult
    public func unpin(_ tileID: AnyHashable) -> Bool {
        let key = TileStore.storageKey(for: tileID)

        if let index = folderRecords.firstIndex(where: { $0.tileKeys.contains(key) }) {
            folderRecords[index].tileKeys.removeAll { $0 == key }
            dissolveFolderIfEmpty(at: index)
            didChange()
            return true
        }

        guard catalogIndex[key] != nil, let position = gridOrder.firstIndex(of: key) else {
            return false
        }
        gridOrder.remove(at: position)
        didChange()
        return true
    }

    /// Закреплён ли ярлык (на сетке или в папке).
    ///
    /// - Parameter tileID: Идентификатор ярлыка.
    /// - Returns: `true`, если ярлык есть на сетке или в папке.
    public func isPinned(_ tileID: AnyHashable) -> Bool {
        let key = TileStore.storageKey(for: tileID)
        return gridOrder.contains(key) || folderRecords.contains { $0.tileKeys.contains(key) }
    }

    // MARK: - Размер

    /// Меняет размер ярлыка или папки (D15: четыре размера).
    ///
    /// Какие размеры реально доступны конкретному ярлыку, решает хост
    /// (в модели ярлыка нет списка поддерживаемых размеров — D12);
    /// хранилище принимает любой из четырёх.
    ///
    /// - Parameters:
    ///   - itemID: Идентификатор ярлыка или папки.
    ///   - size: Новый размер.
    /// - Returns: `true`, если состояние изменилось.
    @discardableResult
    public func resize(_ itemID: AnyHashable, to size: TileSize) -> Bool {
        let key = TileStore.storageKey(for: itemID)

        if let index = folderRecords.firstIndex(where: { $0.key == key }) {
            guard folderRecords[index].size != size else { return false }
            folderRecords[index].size = size
            didChange()
            return true
        }

        guard catalogIndex[key] != nil, sizes[key] != size else { return false }
        sizes[key] = size
        didChange()
        return true
    }

    // MARK: - Порядок в сетке

    /// Переставляет элемент сетки (ярлык или папку).
    ///
    /// Это операция раскладки, а не группировки: D14 требует одобрения только
    /// для создания папки, добавления ярлыка и перемещения между папками,
    /// поэтому перестановка на сетке выполняется без функции одобрения.
    ///
    /// - Parameters:
    ///   - itemID: Идентификатор ярлыка или папки на сетке.
    ///   - index: Целевая позиция; значения за границами зажимаются.
    /// - Returns: `true`, если позиция изменилась.
    @discardableResult
    public func move(_ itemID: AnyHashable, toIndex index: Int) -> Bool {
        let key = TileStore.storageKey(for: itemID)
        guard let from = gridOrder.firstIndex(of: key), !gridOrder.isEmpty else { return false }
        let to = min(max(index, 0), gridOrder.count - 1)
        guard from != to else { return false }

        gridOrder.remove(at: from)
        gridOrder.insert(key, at: to)
        didChange()
        return true
    }

    // MARK: - Папки (D14: только через одобрение хоста)

    /// Создаёт папку из ярлыка, стоящего на сетке.
    ///
    /// Ярлык немедленно переезжает в новую папку, а на его месте в сетке
    /// появляется плитка-папка (размер по умолчанию — 2×2). Это единственный
    /// способ создать папку: пустая папка в v1 не создаётся, потому что функция
    /// одобрения D14 получает ярлык-инициатор.
    ///
    /// - Parameters:
    ///   - tileID: Ярлык, который станет первым содержимым папки.
    ///   - title: Название папки; пустая строка допустима.
    /// - Returns: Созданная папка или `nil`, если хост запретил операцию либо
    ///   ярлыка нет на сетке.
    @discardableResult
    public func createFolder(withTile tileID: AnyHashable, title: String = "") -> TileFolder? {
        let tileKey = TileStore.storageKey(for: tileID)
        guard let catalogPosition = catalogIndex[tileKey],
              let gridPosition = gridOrder.firstIndex(of: tileKey) else {
            return nil
        }
        let descriptor = catalog[catalogPosition]
        guard approval(nil, descriptor, .createFolder) else { return nil }

        let folderID = AnyHashable("folder-" + UUID().uuidString)
        let record = FolderRecord(
            key: TileStore.storageKey(for: folderID),
            id: folderID,
            title: title,
            size: .medium,
            tileKeys: [tileKey]
        )
        folderRecords.append(record)
        gridOrder[gridPosition] = record.key
        didChange()
        return materialize(record)
    }

    /// Добавляет ярлык с сетки в существующую папку.
    ///
    /// - Parameters:
    ///   - tileID: Ярлык на сетке.
    ///   - folderID: Идентификатор папки.
    /// - Returns: `true`, если состояние изменилось. `false` — ярлык уже в этой
    ///   папке, лежит в другой папке (для этого есть ``moveBetweenFolders(_:to:)``)
    ///   или хост запретил операцию.
    @discardableResult
    public func addToFolder(_ tileID: AnyHashable, folderID: AnyHashable) -> Bool {
        let tileKey = TileStore.storageKey(for: tileID)
        let folderKey = TileStore.storageKey(for: folderID)

        guard let catalogPosition = catalogIndex[tileKey],
              let folderIndex = folderRecords.firstIndex(where: { $0.key == folderKey }),
              !folderRecords[folderIndex].tileKeys.contains(tileKey),
              let gridPosition = gridOrder.firstIndex(of: tileKey) else {
            return false
        }

        let folder = materialize(folderRecords[folderIndex])
        guard approval(folder, catalog[catalogPosition], .addToFolder) else { return false }

        gridOrder.remove(at: gridPosition)
        folderRecords[folderIndex].tileKeys.append(tileKey)
        didChange()
        return true
    }

    /// Перемещает ярлык между папками или из папки на рабочий стол.
    ///
    /// - Parameters:
    ///   - tileID: Ярлык, лежащий в папке.
    ///   - folderID: Папка-цель; `nil` — вернуть ярлык на рабочий стол (в конец сетки).
    /// - Returns: `true`, если состояние изменилось. `false` — ярлыка нет ни в
    ///   одной папке, целевая папка совпадает с текущей или хост запретил операцию.
    @discardableResult
    public func moveBetweenFolders(_ tileID: AnyHashable, to folderID: AnyHashable?) -> Bool {
        let tileKey = TileStore.storageKey(for: tileID)

        guard let catalogPosition = catalogIndex[tileKey],
              let sourceIndex = folderRecords.firstIndex(where: { $0.tileKeys.contains(tileKey) }) else {
            return false
        }

        var target: TileFolder?
        if let folderID = folderID {
            let folderKey = TileStore.storageKey(for: folderID)
            guard let targetIndex = folderRecords.firstIndex(where: { $0.key == folderKey }),
                  targetIndex != sourceIndex else {
                return false
            }
            target = materialize(folderRecords[targetIndex])
        }

        guard approval(target, catalog[catalogPosition], .moveBetweenFolders) else { return false }

        folderRecords[sourceIndex].tileKeys.removeAll { $0 == tileKey }
        if let target = target,
           let targetIndex = folderRecords.firstIndex(where: { $0.id == target.id }) {
            folderRecords[targetIndex].tileKeys.append(tileKey)
        } else {
            gridOrder.append(tileKey)
        }
        dissolveFolderIfEmpty(at: sourceIndex)
        didChange()
        return true
    }

    /// Перемещение ярлыка в папку или на рабочий стол.
    ///
    /// Семантически совпадает с ``moveBetweenFolders(_:to:)`` — оставлено как
    /// читаемый алиас: и перемещение между папками, и возврат на рабочий стол
    /// проходят через функцию одобрения хоста с действием
    /// ``TileGroupingAction/moveBetweenFolders`` (D14).
    ///
    /// - Parameters:
    ///   - tileID: Ярлык, лежащий в папке.
    ///   - folderID: Папка-цель; `nil` — на рабочий стол.
    /// - Returns: `true`, если состояние изменилось.
    @discardableResult
    public func move(_ tileID: AnyHashable, toFolder folderID: AnyHashable?) -> Bool {
        moveBetweenFolders(tileID, to: folderID)
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

    // MARK: - Персистентность

    /// Сохраняет состояние в JSON атомарной записью (§5).
    ///
    /// Каталог создаётся при необходимости. Запись атомарная: файл либо старый,
    /// либо новый целиком — оборванный запуск не оставит половину раскладки.
    ///
    /// - Throws: Ошибку файловой системы или кодирования JSON.
    public func save() throws {
        let document = TileStoreDocument(
            version: TileStore.schemaVersion,
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
    /// файла, которых нет в каталоге, сохраняются в модели, но не попадают в
    /// снимок до регистрации; папки с неизвестными ярлыками остаются.
    ///
    /// Если файла нет — ничего не происходит (первый запуск). Ошибка чтения не
    /// меняет текущее состояние и пробрасывается вызывающему.
    ///
    /// - Throws: Ошибку чтения/декодирования или ``TileStoreError``.
    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        let data = try Data(contentsOf: fileURL)
        let document = try JSONDecoder().decode(TileStoreDocument.self, from: data)
        guard document.version <= TileStore.schemaVersion else {
            throw TileStoreError.unsupportedSchemaVersion(document.version)
        }

        apply(document)
        restoredFromDisk = true
        notifyChange()
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

        // Ярлык принадлежит максимум одной папке: первый по порядку файла побеждает.
        var claimed = Set<String>()
        for index in folderRecords.indices {
            folderRecords[index].tileKeys = folderRecords[index].tileKeys.filter { claimed.insert($0).inserted }
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

        gridOrder = order
    }

    /// Раскладка в виде элементов JSON-документа, с признаком «ярлык/папка».
    ///
    /// - Returns: Элементы в порядке сетки.
    private func makeDocumentItems() -> [TileStoreDocument.Item] {
        let folderKeys = Set(folderRecords.map { $0.key })
        return gridOrder.map { key in
            TileStoreDocument.Item(kind: folderKeys.contains(key) ? .folder : .tile, key: key)
        }
    }

    // MARK: - Уведомления и служебные операции

    /// Сообщает об изменении: сначала сохранение (если включено), затем снимок.
    private func didChange() {
        if autosaves {
            saveIfPossible()
        }
        notifyChange()
    }

    /// Отправляет снимок подписчикам: `objectWillChange` и ``onChange``.
    private func notifyChange() {
        let snapshot = snapshot()
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

    /// Распускает опустевшую папку и убирает её плитку из сетки.
    ///
    /// - Parameter index: Индекс папки в ``folderRecords``.
    private func dissolveFolderIfEmpty(at index: Int) {
        guard folderRecords.indices.contains(index), folderRecords[index].tileKeys.isEmpty else { return }
        let key = folderRecords[index].key
        folderRecords.remove(at: index)
        gridOrder.removeAll { $0 == key }
    }

    /// Убирает из папок ярлыки, которых больше нет в каталоге, и распускает
    /// опустевшие папки.
    ///
    /// Вызывается при перерегистрации каталога: удалённое приложение не должно
    /// оставлять «мёртвые» идентификаторы в папках.
    private func pruneFoldersAgainstCatalog() {
        for index in folderRecords.indices {
            folderRecords[index].tileKeys.removeAll { catalogIndex[$0] == nil }
        }

        var dissolved = Set<String>()
        folderRecords.removeAll { record in
            if record.tileKeys.isEmpty {
                dissolved.insert(record.key)
                return true
            }
            return false
        }
        if !dissolved.isEmpty {
            gridOrder.removeAll { dissolved.contains($0) }
        }
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
/// сериализовать. Хранится только раскладка: порядок, размеры, папки.
/// Ключи элементов — канонические строки (см. `TileStore.storageKey(for:)`),
/// поэтому схема не зависит от типа `AnyHashable`-идентификатора.
private struct TileStoreDocument: Codable {

    /// Версия схемы; запись читается, только если она не новее текущей.
    var version: Int

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
