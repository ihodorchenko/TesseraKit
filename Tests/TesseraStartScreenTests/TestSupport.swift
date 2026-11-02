//
//  TestSupport.swift
//  TesseraStartScreenTests
//
//  Общие детерминированные помощники тестов рабочего стола (E4.7).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка»
//  (тесты на случайных конфигурациях плиток), §5 «Режим редактирования»
//  (персистентность TileStore), §14 «Уточнения MVP» (D12–D15).
//
//  Все помощники — только для тестов: публичного API target'а они не касаются.
//  «Случайность» всегда seeded, поэтому прогон воспроизводим и не флакует.
//

#if canImport(UIKit)

import Foundation
import XCTest
@testable import TesseraStartScreen

// MARK: - Детерминированный генератор

/// Простой seeded-генератор для «случайных» конфигураций раскладки (§3).
///
/// Не использует `SystemRandomNumberGenerator`: тест обязан давать одну и ту
/// же конфигурацию при каждом запуске. Реализация намеренно не совпадает с
/// production-генератором стахгера `TesseraSeededGenerator`, чтобы тест
/// раскладки не зависел от внутренностей Live-движка.
struct TesseraTestSeededGenerator {

    /// Состояние LCG.
    private var state: UInt64

    /// Создаёт генератор.
    ///
    /// - Parameter seed: Зерно; одинаковое зерно даёт одинаковую последовательность.
    init(seed: UInt64) {
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    }

    /// Следующее псевдослучайное значение.
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    /// Значение `0..<upperBound`.
    ///
    /// - Parameter upperBound: Положительная граница.
    mutating func int(upperBound: Int) -> Int {
        precondition(upperBound > 0, "upperBound должен быть положительным")
        return Int((next() >> 33) % UInt64(upperBound))
    }
}

// MARK: - Временная директория

/// Временный каталог для тестов персистентности `TileStore`.
///
/// Каталог удаляется в `deinit`: тесты не оставляют мусор в песочнице
/// симулятора и не зависят от порядка прогона.
final class TesseraTestDirectory {

    /// Путь каталога.
    let url: URL

    /// Создаёт описание каталога (сам каталог создаётся по необходимости).
    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TesseraStartScreenTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Создаёт каталог на диске.
    func create() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

// MARK: - Модель ярлыка

/// Ярлык для тестов: действие-заглушка и настраиваемые размер/бейдж (D12/D15).
///
/// - Parameters:
///   - id: Идентификатор ярлыка.
///   - size: Размер плитки, по умолчанию `.medium` (D12).
///   - badge: Бейдж внимания, по умолчанию `.none`.
/// - Returns: Готовый `TileDescriptor`.
func tesseraTestTile(
    _ id: String,
    size: TileSize = .medium,
    badge: TileBadge = .none
) -> TileDescriptor {
    TileDescriptor(
        id: id,
        title: id,
        action: {},
        badge: badge,
        size: size
    )
}

/// Идентификаторы элементов снимка в порядке отображения.
///
/// - Parameter items: Элементы сетки.
/// - Returns: Идентификаторы в том же порядке.
func tesseraTestIDs(_ items: [TileGridItem]) -> [AnyHashable] {
    items.map { $0.id }
}

/// Папка для тестов: заголовок, число ярлыков small и размер (D17/D15).
///
/// - Parameters:
///   - id: Идентификатор папки.
///   - tileCount: Число ярлыков в папке.
///   - title: Подпись; по умолчанию — идентификатор.
///   - size: Размер папки на сетке, по умолчанию `.medium`.
/// - Returns: Модель папки.
func tesseraTestFolder(
    _ id: String,
    tileCount: Int = 4,
    title: String? = nil,
    size: TileSize = .medium
) -> TileFolder {
    TileFolder(
        id: id,
        title: title ?? id,
        tiles: (0..<tileCount).map { tesseraTestTile("\(id)-tile\($0)", size: .small) },
        size: size
    )
}

// MARK: - Live-контент (E9.8в, E10.4)

/// Провайдер live-контента для тестов: стороны задаются напрямую, подписки нет.
///
/// Наследование протокола использует его дефолтные реализации: бэк — заданный
/// при создании, подписка на обновления не нужна (v1, §10).
final class TesseraTestLiveProvider: TesseraLiveTileContentProvider {

    /// Содержимое фронта.
    var frontFace: TesseraLiveTileFace

    /// Содержимое бэка; `nil` — флипов нет.
    var backFace: TesseraLiveTileFace?

    /// Создаёт провайдера.
    ///
    /// - Parameters:
    ///   - frontFace: Содержимое фронта.
    ///   - backFace: Содержимое бэка; `nil` — статичная плитка.
    init(frontFace: TesseraLiveTileFace, backFace: TesseraLiveTileFace? = nil) {
        self.frontFace = frontFace
        self.backFace = backFace
    }
}

/// Живой ярлык для тестов: провайдер с заданными сторонами и действием-заглушкой.
///
/// - Parameters:
///   - id: Идентификатор ярлыка.
///   - front: Содержимое фронта.
///   - back: Содержимое бэка; `nil` — флипов нет.
///   - badge: Бейдж внимания.
///   - size: Размер плитки.
///   - action: Действие ярлыка (по умолчанию пустое).
/// - Returns: Готовый `TileDescriptor` с live-контентом.
func tesseraTestLiveTile(
    _ id: String,
    front: TesseraLiveTileFace,
    back: TesseraLiveTileFace? = nil,
    badge: TileBadge = .none,
    size: TileSize = .medium,
    action: @escaping () -> Void = {}
) -> TileDescriptor {
    TileDescriptor(
        id: id,
        title: id,
        action: action,
        badge: badge,
        size: size,
        liveContent: TesseraTestLiveProvider(frontFace: front, backFace: back)
    )
}

// MARK: - Окно с сеткой (E10.2, E10.4)

/// Сетка в реальном окне для тестов, которым нужны анимации панели папки и
/// настоящие ячейки (E10.2, E10.4).
///
/// В окне `UIViewPropertyAnimator` раскрытия панели и batch-обновления
/// UICollectionView выполняются по-настоящему, поэтому тесты дожидаются
/// завершения перехода прокруткой run loop (`waitForFolderTransition`), а не
/// фиксированной задержкой. Окно принадлежит хосту и снимается в `deinit`.
final class TesseraTestWindowedGrid {

    /// Размер окна по умолчанию (ширина класса iPhone 13/14/15/17).
    static let defaultSize = CGSize(width: 390, height: 844)

    /// Окно, в которое встроена сетка.
    let window: UIWindow

    /// Сетка под тестом.
    let grid: TesseraTileGridView

    /// Создаёт окно с сеткой и применяет первый снимок.
    ///
    /// - Parameters:
    ///   - items: Элементы снимка в порядке отображения.
    ///   - columns: Число колонок сетки.
    ///   - size: Размер окна и сетки.
    init(
        items: [TileGridItem] = [],
        columns: Int = 4,
        size: CGSize = TesseraTestWindowedGrid.defaultSize
    ) {
        window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.isHidden = false
        grid = TesseraTileGridView(frame: CGRect(origin: .zero, size: size))
        grid.columns = columns
        window.addSubview(grid)
        grid.reload(snapshot: TileGridSnapshot(items: items, unpinned: []))
        layout()
    }

    deinit {
        window.subviews.forEach { $0.removeFromSuperview() }
        window.isHidden = true
    }

    /// Коллекция внутри сетки.
    var collectionView: UICollectionView? {
        grid.subviews.compactMap { $0 as? UICollectionView }.first
    }

    /// Доводит раскладку сетки и коллекции: ячейки и рамки актуальны.
    func layout() {
        grid.layoutIfNeeded()
        collectionView?.layoutIfNeeded()
    }

    /// Применяет снимок без анимации и доводит раскладку.
    ///
    /// - Parameter items: Новые элементы снимка.
    func reload(_ items: [TileGridItem]) {
        grid.reload(snapshot: TileGridSnapshot(items: items, unpinned: []))
        layout()
    }

    /// Прокручивает run loop заданное время (ожидание таймеров, а не анимаций).
    ///
    /// - Parameter seconds: Длительность ожидания в секундах.
    func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Ждёт выполнения условия, прокручивая run loop (без фиксированной паузы).
    ///
    /// - Parameters:
    ///   - timeout: Максимальное ожидание в секундах.
    ///   - condition: Условие готовности.
    /// - Returns: `true`, если условие выполнилось до таймаута.
    @discardableResult
    func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// Ждёт завершения анимации панели папки (E10.2).
    ///
    /// - Parameter timeout: Максимальное ожидание в секундах.
    /// - Returns: `true`, если переход завершился до таймаута.
    @discardableResult
    func waitForFolderTransition(timeout: TimeInterval = 2) -> Bool {
        waitUntil(timeout: timeout) { !self.grid.isFolderChangeAnimating }
    }

    /// Видимая ячейка элемента.
    ///
    /// - Parameter id: Идентификатор ярлыка или папки.
    /// - Returns: Ячейка или `nil`, если элемента нет на экране.
    func cell(_ id: AnyHashable) -> TesseraTileCell? {
        grid.cellView(forItemID: id) as? TesseraTileCell
    }

    /// Видимая ячейка-панель раскрытой папки.
    ///
    /// - Parameter folderID: Идентификатор раскрытой папки.
    /// - Returns: Панель или `nil`, если она вне экрана.
    func panelCell(folderID: AnyHashable) -> TesseraFolderPanelCell? {
        guard let collectionView,
              let index = grid.displayItems.firstIndex(where: {
                  $0.isFolderPanel && $0.id == folderID
              }) else {
            return nil
        }
        return collectionView.cellForItem(
            at: IndexPath(item: index, section: 0)
        ) as? TesseraFolderPanelCell
    }

    /// Первый подвид заданного типа в иерархии.
    ///
    /// - Parameters:
    ///   - type: Тип подвида.
    ///   - root: Корень поиска; по умолчанию — сетка.
    /// - Returns: Найденный вид или `nil`.
    func firstSubview<T: UIView>(of type: T.Type, in root: UIView? = nil) -> T? {
        func find(in view: UIView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews {
                if let match = find(in: subview) { return match }
            }
            return nil
        }
        return find(in: root ?? grid)
    }
}

#endif
