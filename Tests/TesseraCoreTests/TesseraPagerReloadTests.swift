//
//  TesseraPagerReloadTests.swift
//  TesseraCoreTests
//
//  Регрессионные тесты пейджера по повторному ревью (E10.10).
//  Проектный документ: docs/CORE-IOS-DESIGN.md §2 «Ключевые контракты»
//  (инвариант t, один писатель contentOffset) и docs/PIVOT-IOS-DESIGN.md §1 п.4
//  («прямой прыжок без пролёта промежуточных»).
//
//  Сценарии: `reload(pages:)` сохраняет текущую страницу по `id` и не
//  пересоздаёт контроллеры с сохранившимся `id`; поворот (смена ширины) не
//  сбивает текущую страницу; смена направления на лету перераскладывает слоты;
//  appearance-коллбэки приходят по видимости; анимированный дальний переход
//  не пролетает промежуточные страницы.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraCore

/// Контроллер страницы, считающий appearance-коллбэки.
private final class AppearanceSpyController: UIViewController {
    let pageID: String

    private(set) var willAppearCount = 0
    private(set) var didAppearCount = 0
    private(set) var willDisappearCount = 0
    private(set) var didDisappearCount = 0

    init(pageID: String) {
        self.pageID = pageID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        willAppearCount += 1
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppearCount += 1
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        willDisappearCount += 1
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        didDisappearCount += 1
    }

    /// Видима ли страница по счётчикам коллбэков.
    var isAppeared: Bool { didAppearCount > didDisappearCount }

    /// Пары will/did сбалансированы (нет «висящих» переходов).
    var isBalanced: Bool {
        willAppearCount == didAppearCount && willDisappearCount == didDisappearCount
    }
}

/// Фабрика страниц: запоминает каждый созданный контроллер по `id`.
private final class PageFactory {
    private(set) var created: [String: [AppearanceSpyController]] = [:]

    func descriptors(_ ids: [String]) -> [TesseraPageDescriptor] {
        ids.map { id in
            TesseraPageDescriptor(id: id, title: id) { [unowned self] in
                let controller = AppearanceSpyController(pageID: id)
                self.created[id, default: []].append(controller)
                return controller
            }
        }
    }

    func creationCount(_ id: String) -> Int { created[id]?.count ?? 0 }

    func controller(_ id: String) -> AppearanceSpyController? { created[id]?.last }
}

/// Шпион делегата: индексы показанных страниц и значения прогресса.
private final class PagerDelegateSpy: TesseraPagerDelegate {
    var shownIndexes: [Int] = []
    var progressValues: [CGFloat] = []

    func pager(_ pager: TesseraPagerViewController, didShowPageAt index: Int) {
        shownIndexes.append(index)
    }

    func pager(_ pager: TesseraPagerViewController, didChangeProgress t: CGFloat) {
        progressValues.append(t)
    }
}

final class TesseraPagerReloadTests: XCTestCase {

    private let pageWidth: CGFloat = 320
    private let pageHeight: CGFloat = 480

    // MARK: - Вспомогательные средства

    private func makeLoadedPager(
        _ pages: [TesseraPageDescriptor],
        width: CGFloat? = nil,
        height: CGFloat? = nil
    ) throws -> (pager: TesseraPagerViewController, scrollView: UIScrollView) {
        let pager = TesseraPagerViewController(mode: .paged, pages: pages)
        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(
            x: 0,
            y: 0,
            width: width ?? pageWidth,
            height: height ?? pageHeight
        )
        pager.view.layoutIfNeeded()
        return (pager, try scrollView(of: pager))
    }

    private func scrollView(of pager: TesseraPagerViewController) throws -> UIScrollView {
        try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first,
            "Пейджер обязан содержать UIScrollView"
        )
    }

    private func loadedIDs(_ pager: TesseraPagerViewController) -> Set<String> {
        Set(pager.children.compactMap { ($0 as? AppearanceSpyController)?.pageID })
    }

    private func appear(_ pager: TesseraPagerViewController) {
        pager.beginAppearanceTransition(true, animated: false)
        pager.endAppearanceTransition()
    }

    private func disappear(_ pager: TesseraPagerViewController) {
        pager.beginAppearanceTransition(false, animated: false)
        pager.endAppearanceTransition()
    }

    // MARK: - reload(pages:): текущая страница по id (E10.10 a)

    /// `[A, B, C]`, текущая B; `reload([X, A, B, C])` — текущей остаётся B
    /// (теперь индекс 2), offset и прогресс соответствуют ей.
    func testReloadWithInsertedLeadingPageKeepsCurrentPageByID() throws {
        let factory = PageFactory()
        let (pager, scrollView) = try makeLoadedPager(factory.descriptors(["A", "B", "C"]))
        pager.go(toPage: 1, animated: false)
        let spy = PagerDelegateSpy()
        pager.delegate = spy

        pager.reload(pages: factory.descriptors(["X", "A", "B", "C"]))

        XCTAssertEqual(pager.currentPageIndex, 2)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2)
        XCTAssertEqual(try XCTUnwrap(spy.progressValues.last), 2, accuracy: 0.0001)
        XCTAssertEqual(loadedIDs(pager), ["A", "B", "C"])
    }

    /// Текущий `id` исчез — сохраняется прежний индекс с зажимом.
    func testReloadWithoutCurrentIDKeepsClampedIndex() throws {
        let factory = PageFactory()
        let (pager, scrollView) = try makeLoadedPager(factory.descriptors(["A", "B", "C"]))
        pager.go(toPage: 2, animated: false)

        pager.reload(pages: factory.descriptors(["X", "Y"]))

        XCTAssertEqual(pager.currentPageIndex, 1)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth)
    }

    // MARK: - reload(pages:): переиспользование контроллеров (E10.10 b)

    /// Контроллеры с сохранившимся `id` не пересоздаются: тот же экземпляр до и
    /// после `reload`, фрейм — в новом слоте; страница вне окна ±1 не создаётся.
    func testReloadReusesControllersOfSurvivingIDs() throws {
        let factory = PageFactory()
        let (pager, _) = try makeLoadedPager(factory.descriptors(["A", "B", "C"]))
        pager.go(toPage: 1, animated: false)
        let originalA = try XCTUnwrap(factory.controller("A"))
        let originalB = try XCTUnwrap(factory.controller("B"))
        let originalC = try XCTUnwrap(factory.controller("C"))

        pager.reload(pages: factory.descriptors(["X", "A", "B", "C"]))

        XCTAssertEqual(factory.creationCount("A"), 1)
        XCTAssertEqual(factory.creationCount("B"), 1)
        XCTAssertEqual(factory.creationCount("C"), 1)
        XCTAssertEqual(factory.creationCount("X"), 0, "X вне окна ±1 вокруг B")
        XCTAssertTrue(pager.children.contains { $0 === originalA })
        XCTAssertTrue(pager.children.contains { $0 === originalB })
        XCTAssertTrue(pager.children.contains { $0 === originalC })
        XCTAssertEqual(originalB.view.frame.minX, pageWidth * 2)
        XCTAssertEqual(originalA.view.frame.minX, pageWidth)
    }

    /// Исчезнувшие `id` выгружаются; сохранившийся — тот же экземпляр.
    func testReloadDetachesRemovedIDsAndKeepsSurvivor() throws {
        let factory = PageFactory()
        let (pager, scrollView) = try makeLoadedPager(factory.descriptors(["A", "B", "C"]))
        pager.go(toPage: 1, animated: false)
        let originalA = try XCTUnwrap(factory.controller("A"))
        let originalB = try XCTUnwrap(factory.controller("B"))

        pager.reload(pages: factory.descriptors(["B", "D"]))

        XCTAssertNil(originalA.parent)
        XCTAssertTrue(originalB.parent === pager)
        XCTAssertEqual(factory.creationCount("B"), 1)
        XCTAssertEqual(pager.currentPageIndex, 0)
        XCTAssertEqual(scrollView.contentOffset.x, 0)
        XCTAssertEqual(loadedIDs(pager), ["B", "D"])
    }

    // MARK: - Поворот (E10.10 d)

    /// 3 страницы, текущая — последняя; ширина 390 → 844 (поворот).
    /// Зажатие offset'а UIKit'ом при смене frame не должно сбивать страницу.
    func testWidthChangeKeepsLastPage() throws {
        let factory = PageFactory()
        let (pager, scrollView) = try makeLoadedPager(
            factory.descriptors(["A", "B", "C"]),
            width: 390,
            height: 844
        )
        pager.go(toPage: 2, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, 390 * 2)
        let spy = PagerDelegateSpy()
        pager.delegate = spy

        pager.view.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        pager.view.layoutIfNeeded()

        XCTAssertEqual(pager.currentPageIndex, 2)
        XCTAssertEqual(scrollView.contentOffset.x, 844 * 2)
        XCTAssertEqual(scrollView.contentSize.width, 844 * 3)
        XCTAssertEqual(try XCTUnwrap(spy.progressValues.last), 2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(factory.controller("C")).view.frame.minX, 844 * 2)

        // Обратный поворот тоже сохраняет страницу.
        pager.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        pager.view.layoutIfNeeded()

        XCTAssertEqual(pager.currentPageIndex, 2)
        XCTAssertEqual(scrollView.contentOffset.x, 390 * 2)
    }

    // MARK: - Смена направления на лету (E10.10 e)

    /// Смена `semanticContentAttribute` без явного `setNeedsLayout`: слоты
    /// перераскладываются, текущая страница сохраняется по порядку чтения.
    func testSemanticContentAttributeChangeRelayoutsSlots() throws {
        let factory = PageFactory()
        let (pager, scrollView) = try makeLoadedPager(factory.descriptors(["A", "B", "C", "D"]))
        pager.go(toPage: 1, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth)

        pager.view.semanticContentAttribute = .forceRightToLeft
        pager.view.layoutIfNeeded()

        // RTL: страница чтения 1 — физический слот 4 − 1 − 1 = 2.
        XCTAssertEqual(pager.currentPageIndex, 1)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2)
        XCTAssertEqual(try XCTUnwrap(factory.controller("B")).view.frame.minX, pageWidth * 2)
        XCTAssertEqual(try XCTUnwrap(factory.controller("A")).view.frame.minX, pageWidth * 3)

        pager.view.semanticContentAttribute = .forceLeftToRight
        pager.view.layoutIfNeeded()

        XCTAssertEqual(pager.currentPageIndex, 1)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth)
        XCTAssertEqual(try XCTUnwrap(factory.controller("B")).view.frame.minX, pageWidth)
    }

    /// Направление сменилось, а до layout'а пейджер успел синхронизировать
    /// индекс по offset'у (показ пейджера): offset всё ещё стоит в слотах
    /// старого направления и не должен трактоваться как зеркальная страница.
    func testDirectionChangeBeforeLayoutKeepsReadingPage() throws {
        let factory = PageFactory()
        let (pager, scrollView) = try makeLoadedPager(factory.descriptors(["A", "B", "C", "D"]))
        pager.go(toPage: 1, animated: false)

        pager.view.semanticContentAttribute = .forceRightToLeft
        appear(pager)
        pager.view.layoutIfNeeded()

        XCTAssertEqual(pager.currentPageIndex, 1)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2)
        XCTAssertTrue(try XCTUnwrap(factory.controller("B")).isAppeared)
    }

    // MARK: - Appearance по видимости (E10.10 f)

    /// При показе пейджера appear получает только текущая страница; после
    /// свайпа — новая appear, старая disappear; соседи ±1 коллбэков не получают.
    func testAppearanceCallbacksFollowVisiblePage() throws {
        let factory = PageFactory()
        let (pager, scrollView) = try makeLoadedPager(factory.descriptors(["A", "B", "C"]))
        let pageA = try XCTUnwrap(factory.controller("A"))
        let pageB = try XCTUnwrap(factory.controller("B"))

        appear(pager)

        XCTAssertEqual(pageA.willAppearCount, 1)
        XCTAssertEqual(pageA.didAppearCount, 1)
        XCTAssertEqual(pageB.willAppearCount, 0, "сосед ±1 не виден")
        XCTAssertEqual(pageB.didAppearCount, 0)

        // Свайп на B.
        scrollView.contentOffset = CGPoint(x: pageWidth, y: 0)
        pager.scrollViewDidEndDecelerating(scrollView)

        let pageC = try XCTUnwrap(factory.controller("C"))
        XCTAssertTrue(pageB.isAppeared)
        XCTAssertFalse(pageA.isAppeared)
        XCTAssertEqual(pageA.didDisappearCount, 1)
        XCTAssertEqual(pageC.willAppearCount, 0, "новый сосед ±1 не виден")

        disappear(pager)

        for page in [pageA, pageB, pageC] {
            XCTAssertFalse(page.isAppeared, "страница \(page.pageID) осталась видимой")
            XCTAssertTrue(page.isBalanced, "несбалансированные коллбэки у \(page.pageID)")
        }
        XCTAssertEqual(pageB.didDisappearCount, 1)
    }

    /// Мгновенный дальний переход: прежняя текущая выгружается со
    /// сбалансированным disappear, целевая получает appear.
    func testAppearanceOnFarImmediateJumpAndReload() throws {
        let factory = PageFactory()
        let (pager, _) = try makeLoadedPager(factory.descriptors(["A", "B", "C", "D", "E"]))
        let pageA = try XCTUnwrap(factory.controller("A"))
        appear(pager)

        pager.go(toPage: 4, animated: false)

        let pageE = try XCTUnwrap(factory.controller("E"))
        XCTAssertNil(pageA.parent)
        XCTAssertFalse(pageA.isAppeared)
        XCTAssertTrue(pageA.isBalanced)
        XCTAssertTrue(pageE.isAppeared)

        // reload с сохранившимся id текущей страницы не дёргает её appearance.
        pager.reload(pages: factory.descriptors(["E", "F"]))
        XCTAssertEqual(pageE.didAppearCount, 1)
        XCTAssertEqual(pageE.didDisappearCount, 0)
        XCTAssertTrue(pageE.isAppeared)

        disappear(pager)
        XCTAssertFalse(pageE.isAppeared)
        XCTAssertTrue(pageE.isBalanced)
    }

    // MARK: - Анимированный дальний переход (E10.10 c)

    /// `go(toPage:animated:true)` дальше ±1: без пролёта промежуточных
    /// страниц — offset сразу переставляется на соседа цели, окно ±1 вокруг
    /// цели загружено до анимации, `didShowPageAt` приходит один раз — для цели.
    ///
    /// Анимация `setContentOffset(_:animated:)` в тестовом процессе без
    /// приложения ведёт себя по-разному (без окна завершается синхронно, в
    /// окне без дисплея не продвигается), поэтому её конец при необходимости
    /// имитируется: offset ставится в цель, затем `didEndScrollingAnimation`.
    func testAnimatedFarJumpSkipsIntermediatePages() throws {
        let factory = PageFactory()
        let (pager, scrollView) = try makeLoadedPager(
            factory.descriptors(["A", "B", "C", "D", "E", "F"])
        )
        let spy = PagerDelegateSpy()
        pager.delegate = spy

        pager.go(toPage: 5, animated: true)

        // До анимации: offset уже на соседе цели, окно вокруг цели загружено,
        // промежуточные страницы не создавались.
        XCTAssertGreaterThanOrEqual(scrollView.contentOffset.x, pageWidth * 4)
        XCTAssertEqual(loadedIDs(pager), ["E", "F"])
        XCTAssertEqual(factory.creationCount("C"), 0)
        XCTAssertEqual(factory.creationCount("D"), 0)
        XCTAssertTrue(
            spy.shownIndexes.allSatisfy { $0 == 5 },
            "ложный didShowPage для промежуточной страницы: \(spy.shownIndexes)"
        )

        // Без окна UIKit может завершить анимацию синхронно; иначе имитируем
        // последний кадр. Повторное завершение не дублирует didShowPage.
        if spy.shownIndexes.isEmpty {
            scrollView.setContentOffset(CGPoint(x: pageWidth * 5, y: 0), animated: false)
            pager.scrollViewDidEndScrollingAnimation(scrollView)
        }

        XCTAssertEqual(spy.shownIndexes, [5])
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 5)
        XCTAssertEqual(factory.creationCount("B"), 1)
        XCTAssertEqual(factory.creationCount("C"), 0)
        XCTAssertEqual(factory.creationCount("D"), 0)
        XCTAssertFalse(spy.progressValues.isEmpty)
        for value in spy.progressValues {
            XCTAssertGreaterThanOrEqual(value, 4 - 0.0001, "пролёт промежуточной страницы: t = \(value)")
            XCTAssertLessThanOrEqual(value, 5 + 0.0001)
        }
    }

    /// Анимированный переход на текущую страницу не зависает: UIKit не
    /// присылает `didEndScrollingAnimation` для нулевого пути, переход
    /// завершается сразу.
    func testAnimatedGoToCurrentPageFinishesImmediately() throws {
        let factory = PageFactory()
        let (pager, _) = try makeLoadedPager(factory.descriptors(["A", "B", "C"]))
        let spy = PagerDelegateSpy()
        pager.delegate = spy

        pager.go(toPage: 0, animated: true)

        XCTAssertEqual(spy.shownIndexes, [0])
    }
}

#endif
