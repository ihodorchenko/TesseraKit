//
//  AppsListPageTests.swift
//  TesseraStartScreenTests
//
//  Тесты правой страницы — списка приложений (E10.9, трек T2).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §6 «Страница справа:
//  список приложений + настройки» — `UITableView` с секциями по буквам и
//  `sectionIndexTitles` (нативный паттерн), источник истины — `TileStore`.
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

    private func tile(_ title: String, id: String? = nil, icon: UIImage? = nil) -> TileDescriptor {
        TileDescriptor(id: id ?? title, title: title, icon: icon, action: {})
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
}

#endif
