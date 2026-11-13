//
//  AppsListPageTests.swift
//  TesseraStartScreenTests
//
//  Тесты правой страницы — списка приложений (E10.9, трек T2; W4-B, E10.5).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §6 «Страница справа:
//  список приложений + настройки» — `UITableView` с секциями по буквам и
//  `sectionIndexTitles` (нативный паттерн), источник истины — `TileStore`.
//
//  W4 → E14.5/E14.6: pin из списка идёт через `TileStore.pinTile(_:columns:)`
//  (новая строка в конце холста), unpin — через `TileStore.unpin(_:columns:)` и
//  `collapseEmptyRows(columns:)` (дыра остаётся, схлопывается только пустая
//  строка); секции списка и позиция чтения при этом не меняются.
//
//  Страница поднимается в настоящем окне: видимые ячейки и `contentSize`
//  таблицы существуют только после layout в иерархии окна.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class AppsListPageTests: XCTestCase {

    // MARK: - Окружение

    private var directory: TesseraTestDirectory!
    private var window: UIWindow!

    override func setUp() {
        super.setUp()
        directory = TesseraTestDirectory()
    }

    override func tearDown() {
        window?.isHidden = true
        window = nil
        directory = nil
        super.tearDown()
    }

    private func makeStore(_ descriptors: [TileDescriptor]) -> TileStore {
        let store = TileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog(descriptors)
        return store
    }

    private func tile(
        _ title: String,
        id: String? = nil,
        icon: UIImage? = nil,
        size: TileSize = .medium
    ) -> TileDescriptor {
        TileDescriptor(id: id ?? title, title: title, icon: icon, action: {}, size: size)
    }

    /// Поднимает страницу в окне и возвращает её таблицу.
    private func host(_ page: TesseraAppsListPageViewController) -> UITableView {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = page
        window.isHidden = false
        self.window = window
        page.view.layoutIfNeeded()
        guard let table = page.scrollView as? UITableView else {
            XCTFail("scrollView страницы должен быть таблицей")
            return UITableView()
        }
        table.layoutIfNeeded()
        return table
    }

    /// Подписи строк по секциям.
    private func rowTitles(_ page: TesseraAppsListPageViewController, _ table: UITableView) -> [[String]] {
        (0..<page.numberOfSections(in: table)).map { section in
            (0..<page.tableView(table, numberOfRowsInSection: section)).map { row in
                page.tableView(table, cellForRowAt: IndexPath(row: row, section: section)).textLabel?.text ?? ""
            }
        }
    }

    private func section(of title: String, in rows: [[String]]) -> Int? {
        rows.firstIndex { $0.contains(title) }
    }

    private func solidIcon(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    // MARK: - Секции по collation (задача 3)

    /// «Éclair» и «Eagle» — одна буква указателя: диакритика не разводит
    /// подписи по разным секциям.
    func testDiacriticsShareSection() {
        let page = TesseraAppsListPageViewController.make(store: makeStore([
            tile("Éclair"), tile("Eagle"), tile("Apple"),
        ]))
        let table = host(page)
        let rows = rowTitles(page, table)

        XCTAssertNotNil(section(of: "Éclair", in: rows))
        XCTAssertEqual(section(of: "Éclair", in: rows), section(of: "Eagle", in: rows))
        // Порядок внутри секции — локализованный.
        if let index = section(of: "Eagle", in: rows) {
            XCTAssertEqual(rows[index], ["Eagle", "Éclair"])
        }
    }

    /// Иероглифы не дают по секции на каждый символ: collation группирует их
    /// (в en-локали — в «#», в zh — по первой букве пиньиня; у выбранных
    /// подписей она общая — «B»).
    func testCJKTitlesDoNotCreateSectionPerCharacter() {
        let cjk = ["北京", "白菜", "包子"]
        let page = TesseraAppsListPageViewController.make(store: makeStore(cjk.map { tile($0) }))
        let table = host(page)
        let rows = rowTitles(page, table)

        let sections = Set(cjk.compactMap { section(of: $0, in: rows) })
        XCTAssertEqual(sections.count, 1, "CJK-подписи должны попасть в одну секцию: \(rows)")
    }

    /// Цифры и символы — в секции «#», она последняя среди ярлыков.
    func testDigitsAndSymbolsGoToHashSection() {
        let page = TesseraAppsListPageViewController.make(store: makeStore([
            tile("1Password"), tile("%Calc"), tile("Notes"),
        ]))
        let table = host(page)
        let rows = rowTitles(page, table)

        guard let digits = section(of: "1Password", in: rows),
              let symbols = section(of: "%Calc", in: rows),
              let notes = section(of: "Notes", in: rows)
        else { return XCTFail("Строки не найдены: \(rows)") }

        XCTAssertEqual(digits, symbols)
        XCTAssertEqual(page.tableView(table, titleForHeaderInSection: digits), "#")
        XCTAssertLessThan(notes, digits)
    }

    /// Jump-list — нативный указатель collation, а прыжок по пустой букве
    /// ведёт к ближайшей непустой секции.
    func testSectionIndexTitlesComeFromCollation() {
        let page = TesseraAppsListPageViewController.make(store: makeStore([
            tile("Apple"), tile("Mail"), tile("Zoom"),
        ]))
        let table = host(page)
        let collation = UILocalizedIndexedCollation.current()

        XCTAssertEqual(page.sectionIndexTitles(for: table), collation.sectionIndexTitles)

        let indexTitles = collation.sectionIndexTitles
        let rows = rowTitles(page, table)
        guard let mailSection = section(of: "Mail", in: rows) else {
            return XCTFail("Нет секции Mail")
        }
        // Индекс буквы «M» ведёт в секцию Mail.
        if let mailIndex = indexTitles.firstIndex(of: "M") {
            XCTAssertEqual(
                page.tableView(table, sectionForSectionIndexTitle: indexTitles[mailIndex], at: mailIndex),
                mailSection
            )
        }
        // Любой индекс даёт допустимую секцию.
        for (index, title) in indexTitles.enumerated() {
            let target = page.tableView(table, sectionForSectionIndexTitle: title, at: index)
            XCTAssertTrue((0..<page.numberOfSections(in: table)).contains(target))
        }
    }

    // MARK: - Иконка в сигнатуре строки (задача 4)

    /// Смена иконки при тех же id/title перерисовывает видимую строку.
    func testIconChangeRefreshesVisibleRow() {
        let store = makeStore([tile("Mail", id: "mail", icon: solidIcon(.red))])
        let page = TesseraAppsListPageViewController.make(store: store)
        let table = host(page)

        let indexPath = IndexPath(row: 0, section: 0)
        guard let before = table.cellForRow(at: indexPath)?.imageView?.image else {
            return XCTFail("Строка не видима или без иконки")
        }

        store.setCatalog([tile("Mail", id: "mail", icon: solidIcon(.blue))])
        table.layoutIfNeeded()

        let after = table.cellForRow(at: indexPath)?.imageView?.image
        XCTAssertNotNil(after)
        XCTAssertFalse(before === after, "Новая иконка должна попасть в видимую строку")
    }

    // MARK: - Offset после reloadData (задача 5)

    /// Каталог сократился — прежний offset за пределами контента зажимается
    /// сразу после перезагрузки, а не «когда-нибудь» следующим layout-проходом
    /// UIKit (до правки страница принудительно возвращала offset 3600+ pt при
    /// контенте в три строки).
    func testOffsetIsClampedAfterCatalogShrinks() {
        let titles = (0..<80).map { String(format: "App %02d", $0) }
        let store = makeStore(titles.map { tile($0) })
        let page = TesseraAppsListPageViewController.make(store: store)
        let table = host(page)

        let inset = table.adjustedContentInset
        let bottom = table.contentSize.height + inset.bottom - table.bounds.height
        XCTAssertGreaterThan(bottom, 1000)
        table.setContentOffset(CGPoint(x: table.contentOffset.x, y: bottom), animated: false)

        store.setCatalog(titles.prefix(3).map { tile($0) })

        assertOffsetInRange(table, "сразу после перезагрузки")
        // Три строки помещаются в экран — позиция чтения возвращается в начало.
        XCTAssertEqual(table.contentOffset.y, -table.adjustedContentInset.top, accuracy: 0.5)

        table.layoutIfNeeded()
        assertOffsetInRange(table, "после layout")
    }

    /// Позиция чтения внутри допустимого диапазона сохраняется (§6: unpin на
    /// сетке не «прыгает» списком в начало). Точное значение не проверяется:
    /// при `automaticDimension` UIKit сам уточняет offset по мере замера
    /// оценённых строк.
    func testOffsetIsPreservedWhenStillValid() {
        let titles = (0..<80).map { String(format: "App %02d", $0) }
        let store = makeStore(titles.map { tile($0) })
        let page = TesseraAppsListPageViewController.make(store: store)
        let table = host(page)

        table.setContentOffset(CGPoint(x: table.contentOffset.x, y: 300), animated: false)
        table.layoutIfNeeded()

        store.setCatalog(titles.prefix(70).map { tile($0) })
        assertOffsetInRange(table, "сразу после перезагрузки")
        XCTAssertGreaterThan(table.contentOffset.y, 200, "Список не должен прыгать в начало")

        table.layoutIfNeeded()
        assertOffsetInRange(table, "после layout")
        XCTAssertGreaterThan(table.contentOffset.y, 200, "Список не должен прыгать в начало")
    }

    private func assertOffsetInRange(
        _ table: UITableView,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let inset = table.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, table.contentSize.height + inset.bottom - table.bounds.height)
        XCTAssertLessThanOrEqual(table.contentOffset.y, maxY + 0.5, message, file: file, line: line)
        XCTAssertGreaterThanOrEqual(table.contentOffset.y, minY - 0.5, message, file: file, line: line)
    }

    // MARK: - Pin/unpin через колонки сетки (W4, E10.5)

    // Pin/unpin выполняется production-методом страницы `setPinned(_:for:)` —
    // тем же, который вызывают кнопка-аксессуар строки и кастомное действие
    // VoiceOver. UI-события (тапы) в тест-раннере ненадёжны, поэтому тест не
    // симулирует касания, а вызывает production-вход напрямую; UI-обвязка
    // строки проверяется отдельно метаданными: кнопка на месте, подпись
    // соответствует состоянию, target-action зарегистрирован, у строки
    // актуальные accessibility value/custom action.

    /// Идентификаторы элементов видимого порядка сетки.
    private func ids(_ store: TileStore) -> [AnyHashable] {
        store.snapshot().items.map { $0.id }
    }

    /// Заголовки секций таблицы по порядку.
    private func sectionTitles(
        _ page: TesseraAppsListPageViewController,
        _ table: UITableView
    ) -> [String?] {
        (0..<page.numberOfSections(in: table)).map {
            page.tableView(table, titleForHeaderInSection: $0)
        }
    }

    /// Позиция строки с подписью `title` (через data source страницы).
    private func indexPath(
        of title: String,
        page: TesseraAppsListPageViewController,
        table: UITableView
    ) -> IndexPath? {
        for section in 0..<page.numberOfSections(in: table) {
            for row in 0..<page.tableView(table, numberOfRowsInSection: section) {
                let indexPath = IndexPath(row: row, section: section)
                let cell = page.tableView(table, cellForRowAt: indexPath)
                if cell.textLabel?.text == title { return indexPath }
            }
        }
        return nil
    }

    /// Ячейка строки: видимая — тот же путь, что у пользователя; для строки вне
    /// экрана — ячейка data source (без прокрутки, чтобы не менять позицию
    /// чтения в тестах про offset).
    private func cell(
        forTitle title: String,
        page: TesseraAppsListPageViewController,
        table: UITableView
    ) -> UITableViewCell? {
        guard let indexPath = indexPath(of: title, page: page, table: table) else {
            return nil
        }
        return table.cellForRow(at: indexPath)
            ?? page.tableView(table, cellForRowAt: indexPath)
    }

    /// Проверяет UI-обвязку строки закрепления: кнопка-аксессуар, её подпись и
    /// зарегистрированный target-action, accessibility-состояние строки.
    private func assertPinButton(
        forTitle title: String,
        pinned: Bool,
        page: TesseraAppsListPageViewController,
        table: UITableView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let cell = cell(forTitle: title, page: page, table: table) else {
            return XCTFail("В списке нет строки «\(title)»", file: file, line: line)
        }
        guard let button = cell.accessoryView as? UIButton else {
            return XCTFail("У строки «\(title)» нет кнопки закрепления", file: file, line: line)
        }
        let expectedTitle = pinned ? page.texts.unpinActionTitle : page.texts.pinActionTitle
        XCTAssertEqual(button.accessibilityLabel, expectedTitle, file: file, line: line)
        let selectors = button.actions(forTarget: button, forControlEvent: .touchUpInside) ?? []
        XCTAssertFalse(
            selectors.isEmpty,
            "у кнопки строки «\(title)» не зарегистрирован target-action",
            file: file,
            line: line
        )
        XCTAssertEqual(
            cell.accessibilityValue,
            pinned ? page.texts.pinnedValue : nil,
            file: file,
            line: line
        )
        XCTAssertEqual(
            cell.accessibilityCustomActions?.first?.name,
            expectedTitle,
            file: file,
            line: line
        )
    }

    /// Закрепляет или открепляет ярлык тем же методом страницы, что и кнопка
    /// (``TesseraAppsListPageViewController/setPinned(_:for:)``).
    @discardableResult
    private func pin(
        _ pinned: Bool,
        forTileID id: AnyHashable,
        title: String,
        page: TesseraAppsListPageViewController,
        table: UITableView
    ) -> Bool {
        assertPinButton(forTitle: title, pinned: !pinned, page: page, table: table)
        return page.setPinned(pinned, for: id)
    }

    /// Проверяет, что порядок снимка — порядок чтения компактной раскладки:
    /// слоты `pack` идут строго по (строка, колонка) в порядке снимка (E10.15).
    private func assertReadingOrder(
        _ store: TileStore,
        columns: Int,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let items = store.snapshot().layoutItems
        let slots = TileLayoutEngine.pack(items: items, columns: columns, unit: 1)
        XCTAssertEqual(slots.count, items.count, message(), file: file, line: line)
        for (previous, next) in zip(slots, slots.dropFirst()) {
            let ordered = previous.row < next.row
                || (previous.row == next.row && previous.column < next.column)
            XCTAssertTrue(
                ordered,
                "\(message()) порядок снимка не совпадает с порядком чтения: "
                    + "\(previous.id)(\(previous.row),\(previous.column)) → "
                    + "\(next.id)(\(next.row),\(next.column))",
                file: file,
                line: line
            )
        }
    }

    /// Проверяет, что порядок снимка — порядок чтения ячеек модели (E14.5):
    /// строка, затем колонка; дыры порядок не меняют.
    private func assertCellReadingOrder(
        _ store: TileStore,
        columns: Int,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            store.placementReadingOrder(forColumns: columns),
            store.snapshot().items.map { $0.id },
            message(),
            file: file,
            line: line
        )
    }

    /// Pin из списка передаёт в хранилище число колонок сетки: ярлык встаёт в
    /// **новую строку** в конце холста (E14.5, D33) — одной операцией, дыры выше
    /// не заполняются.
    ///
    /// «Aurora» (2×2) и «Wide» (4×2) на 4 колонках; «Spark» (1×1) откреплён.
    /// После pin Spark стоит в (4, 0) под «Wide», порядок чтения — [A, W, S].
    func testPinFromListUsesGridColumnsAndPlacesTileInNewRow() {
        let store = makeStore([
            tile("Aurora", id: "a", size: .medium),
            tile("Wide", id: "w", size: .wide),
            tile("Spark", id: "s", size: .small),
        ])
        XCTAssertTrue(store.unpin("s", columns: 4))
        XCTAssertEqual(ids(store), ["a", "w"])
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["s"])

        let page = TesseraAppsListPageViewController.make(store: store, columns: 4)
        let table = host(page)
        let structureBefore = rowTitles(page, table)
        let sectionsBefore = sectionTitles(page, table)

        var changes = 0
        store.onChange = { _ in changes += 1 }
        XCTAssertTrue(pin(true, forTileID: "s", title: "Spark", page: page, table: table))

        XCTAssertEqual(changes, 1, "pin — одна операция модели")
        XCTAssertTrue(store.isPinned("s"))
        XCTAssertTrue(store.snapshot().unpinned.isEmpty)
        XCTAssertEqual(ids(store), ["a", "w", "s"], "порядок модели — порядок чтения ячеек")
        XCTAssertEqual(store.placement(of: "s"), TileGridPlacement(row: 4, column: 0), "новая строка после «Wide»")
        XCTAssertEqual(
            store.snapshot().items.firstIndex { $0.id == AnyHashable("s") },
            2,
            "индекс ярлыка в порядке чтения"
        )
        assertCellReadingOrder(store, columns: 4, "после pin из списка")
        XCTAssertEqual(rowTitles(page, table), structureBefore, "pin не меняет секции списка")
        XCTAssertEqual(sectionTitles(page, table), sectionsBefore)
        // Двусторонняя связь §6: строка сразу отражает новое состояние.
        assertPinButton(forTitle: "Spark", pinned: true, page: page, table: table)
    }

    /// Кнопка строки действительно запускает pin: её зарегистрированный
    /// target-action (`handleTap` → `onTap` → `setPinned`) меняет хранилище.
    ///
    /// UI-событие не симулируется (касания в тест-раннере ненадёжны), поэтому
    /// зарегистрированный target-action вызывается напрямую — это ровно тот
    /// метод, который вызывает UIKit при тапе.
    func testPinButtonHandlerPinsTile() {
        let store = makeStore([
            tile("Aurora", id: "a", size: .medium),
            tile("Wide", id: "w", size: .wide),
            tile("Spark", id: "s", size: .small),
        ])
        XCTAssertTrue(store.unpin("s", columns: 4))

        let page = TesseraAppsListPageViewController.make(store: store, columns: 4)
        let table = host(page)
        guard let cell = cell(forTitle: "Spark", page: page, table: table),
              let button = cell.accessoryView as? UIButton
        else {
            return XCTFail("У строки Spark нет кнопки закрепления")
        }
        XCTAssertTrue(button.isEnabled)
        guard let selectorName = button.actions(
            forTarget: button,
            forControlEvent: .touchUpInside
        )?.first else {
            return XCTFail("У кнопки нет target-action для touchUpInside")
        }

        _ = button.perform(NSSelectorFromString(selectorName))

        XCTAssertTrue(store.isPinned("s"))
        XCTAssertEqual(ids(store), ["a", "w", "s"], "pin — в новую строку в конце")
    }

    /// Фолбэк `columns == nil`: хост не сообщил раскладку странице — pin берёт
    /// ширину, известную хранилищу (`effectiveColumns`), и ставит ярлык в новую
    /// строку в конце холста (E14.5, E14.6).
    func testPinWithoutColumnsUsesStoreWidthAndAppendsToNewRow() {
        let store = makeStore([
            tile("Aurora", id: "a", size: .medium),
            tile("Wide", id: "w", size: .wide),
            tile("Spark", id: "s", size: .small),
        ])
        XCTAssertTrue(store.unpin("s", columns: 4))

        let page = TesseraAppsListPageViewController.make(store: store)
        let table = host(page)
        XCTAssertTrue(pin(true, forTileID: "s", title: "Spark", page: page, table: table))

        XCTAssertTrue(store.isPinned("s"))
        XCTAssertEqual(ids(store), ["a", "w", "s"], "без колонок страница берёт ширину хранилища: новая строка в конце")
        XCTAssertEqual(store.snapshot().items.firstIndex { $0.id == AnyHashable("s") }, 2)
    }

    /// Unpin из списка оставляет дыру на месте ярлыка и не переупаковывает сетку
    /// (E14.5, D30): после него страница схлопывает только полностью пустую
    /// строку (D31). Секции списка и их строки при этом не меняются — ярлык
    /// остаётся в каталоге, меняется только состояние.
    ///
    /// «Alpha» (1×1), «Bravo» (2×2), «Whiskey» (4×2), «Charlie» (2×2) на
    /// 4 колонках: Alpha (0,0), Bravo (0,1), Whiskey (2,0), Charlie (4,0). После
    /// удаления Alpha в её ячейке дыра, остальные на месте (Bravo остаётся в
    /// строке 0, схлопывать нечего).
    func testUnpinFromListLeavesHoleWithoutRepacking() {
        let store = makeStore([
            tile("Alpha", id: "a", size: .small),
            tile("Bravo", id: "b", size: .medium),
            tile("Whiskey", id: "w", size: .wide),
            tile("Charlie", id: "c", size: .medium),
        ])
        XCTAssertEqual(ids(store), ["a", "b", "w", "c"])
        assertReadingOrder(store, columns: 4, "до unpin")

        let page = TesseraAppsListPageViewController.make(store: store, columns: 4)
        let table = host(page)
        let structureBefore = rowTitles(page, table)
        let sectionsBefore = sectionTitles(page, table)

        var changes = 0
        store.onChange = { _ in changes += 1 }
        XCTAssertTrue(pin(false, forTileID: "a", title: "Alpha", page: page, table: table))

        XCTAssertEqual(changes, 1, "unpin — одно изменение модели: пустых строк нет, схлопывать нечего")
        XCTAssertFalse(store.isPinned("a"))
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["a"])
        XCTAssertEqual(ids(store), ["b", "w", "c"], "порядок — порядок чтения ячеек, без репака")
        XCTAssertEqual(store.placement(of: "b"), TileGridPlacement(row: 0, column: 1), "дыра на месте «Alpha» осталась")
        XCTAssertEqual(store.placement(of: "c"), TileGridPlacement(row: 4, column: 0))
        assertCellReadingOrder(store, columns: 4, "после unpin из списка")
        XCTAssertEqual(rowTitles(page, table), structureBefore, "unpin не меняет секции списка")
        XCTAssertEqual(sectionTitles(page, table), sectionsBefore)
        assertPinButton(forTitle: "Alpha", pinned: false, page: page, table: table)
    }

    /// Unpin из списка последнего ярлыка строки схлопывает пустую строку (D31):
    /// «Whiskey» (4×2) занимает строки 2–3 один, поэтому «Charlie» поднимается.
    func testUnpinFromListCollapsesFullyEmptyRow() {
        let store = makeStore([
            tile("Alpha", id: "a", size: .small),
            tile("Bravo", id: "b", size: .medium),
            tile("Whiskey", id: "w", size: .wide),
            tile("Charlie", id: "c", size: .medium),
        ])
        let page = TesseraAppsListPageViewController.make(store: store, columns: 4)
        let table = host(page)

        var changes = 0
        store.onChange = { _ in changes += 1 }
        XCTAssertTrue(pin(false, forTileID: "w", title: "Whiskey", page: page, table: table))

        XCTAssertEqual(changes, 2, "unpin и схлопывание строк — два изменения модели")
        XCTAssertEqual(ids(store), ["a", "b", "c"])
        XCTAssertEqual(store.placement(of: "a"), TileGridPlacement(row: 0, column: 0))
        XCTAssertEqual(store.placement(of: "c"), TileGridPlacement(row: 2, column: 0), "строки 2–3 схлопнуты")
        assertCellReadingOrder(store, columns: 4, "после unpin и схлопывания")
    }

    /// Unpin из списка не перезагружает таблицу: состав строк (секции) не
    /// меняется, позиция чтения сохраняется (§6, T2: unpin не «прыгает»).
    func testUnpinFromListKeepsSectionsAndOffset() {
        let titles = (0..<60).map { String(format: "App %02d", $0) }
        let store = makeStore(titles.map { tile($0, size: .small) })
        let page = TesseraAppsListPageViewController.make(store: store, columns: 4)
        let table = host(page)

        table.setContentOffset(CGPoint(x: table.contentOffset.x, y: 300), animated: false)
        table.layoutIfNeeded()

        let structureBefore = rowTitles(page, table)
        let sectionsBefore = sectionTitles(page, table)
        let offsetBefore = table.contentOffset

        var changes = 0
        store.onChange = { _ in changes += 1 }
        XCTAssertTrue(pin(false, forTileID: "App 00", title: "App 00", page: page, table: table))

        XCTAssertEqual(changes, 1, "порядок уже канонический — unpin одно изменение")
        XCTAssertFalse(store.isPinned("App 00"))
        XCTAssertEqual(ids(store).count, titles.count - 1)
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["App 00"])
        XCTAssertEqual(rowTitles(page, table), structureBefore, "unpin не меняет строки списка")
        XCTAssertEqual(sectionTitles(page, table), sectionsBefore)
        XCTAssertEqual(table.contentOffset.y, offsetBefore.y, accuracy: 0.5, "позиция чтения сохраняется")
        assertOffsetInRange(table, "после unpin из списка")
        XCTAssertGreaterThan(table.contentOffset.y, 250, "список не должен прыгать в начало")
    }

    /// Unpin ярлыка из папки: папка не распускается (в ней второй ярлык),
    /// строки и секции списка не меняются — ярлык остаётся в каталоге с
    /// состоянием «не закреплён», а хранилище остаётся согласованным.
    func testUnpinFromFolderKeepsSectionsStable() {
        let store = makeStore([
            tile("Alpha", id: "a", size: .small),
            tile("Bravo", id: "b", size: .small),
        ])
        guard let folder = store.createFolder(withTile: "a", title: "Группа", columns: 4) else {
            return XCTFail("Не удалось создать папку")
        }
        XCTAssertTrue(store.addToFolder("b", folderID: folder.id, columns: 4))
        XCTAssertEqual(ids(store), [folder.id])

        let page = TesseraAppsListPageViewController.make(store: store, columns: 4)
        let table = host(page)
        let structureBefore = rowTitles(page, table)
        let sectionsBefore = sectionTitles(page, table)
        XCTAssertEqual(structureBefore.flatMap { $0 }, ["Alpha", "Bravo"])

        XCTAssertTrue(pin(false, forTileID: "a", title: "Alpha", page: page, table: table))

        XCTAssertFalse(store.isPinned("a"))
        XCTAssertTrue(store.isPinned("b"))
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["a"])
        XCTAssertEqual(
            store.snapshot().folders.first?.tiles.map { $0.id },
            ["b"],
            "папка остаётся: в ней второй ярлык"
        )
        assertReadingOrder(store, columns: 4, "после unpin из папки")
        XCTAssertEqual(rowTitles(page, table), structureBefore)
        XCTAssertEqual(sectionTitles(page, table), sectionsBefore)
        assertPinButton(forTitle: "Alpha", pinned: false, page: page, table: table)
        assertPinButton(forTitle: "Bravo", pinned: true, page: page, table: table)
    }
}

#endif
