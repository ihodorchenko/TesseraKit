//
//  PanoramaControllerCoverageTests.swift
//  TesseraPanoramaTests
//
//  Покрытие E9.10 (W5-B): поведение `PanoramaViewController` на живых
//  UIView/UIWindow.
//  Проектный документ: docs/PANORAMA-IOS-DESIGN.md — §5 «Вертикальный скролл
//  внутри секции» (вариант B: горизонталь — панораме, вертикаль — ребёнку),
//  §6 «Производительность» (ленивая загрузка окном ±1, prefetch до снапа),
//  §4 «Геометрия и математика ядра» (единый скаляр t, делегат) и
//  docs/CORE-IOS-DESIGN.md §2 «Ключевые контракты» (арбитраж, один писатель
//  contentOffset).
//
//  Что проверяется:
//  - (а) ленивая загрузка: в памяти только текущая секция и соседи ±1, причём
//    как child-контроллеры; выход из окна выгружает и отсоединяет;
//  - (б) prefetch: цель снапа и её сосед догружаются в
//    `scrollViewWillEndDragging`, то есть до начала снапа/до `didShowSectionAt`;
//    видимая секция при этом не выгружается;
//  - (в) `reload(sections:)`: текущая секция сохраняется по `id`, загруженное
//    окно переиспользуется, контроллеры выживших `id` не пересоздаются;
//  - (г) делегат: `didShowSectionAt` — ровно один вызов на реальную смену, без
//    промежуточных кадров свайпа; `didChangeProgress` согласован с offset'ом;
//  - (д) арбитраж варианта B: горизонталь принадлежит панораме, вертикаль —
//    реальному `UIScrollView` секции; проверяется публичный контракт
//    `registerVerticalOwner(_:)` + `TesseraGestureArbiter` (чистое решение по
//    оси и блокировка детей на время горизонтального жеста). Приватная точка
//    `.began` панорамы тестам недоступна — см. отчёт по задаче.
//
//  Детерминизм: прогресс/показ синхронизируются вызовами публичных делегатов
//  скролла (как в PanoramaControllerReviewTests), без sleep; ожидание run loop
//  не требуется. Конец анимации `setContentOffset(_:animated:)` в тестовом
//  процессе без дисплея не наступает — он эмулируется постановкой offset'а и
//  вызовом `scrollViewDidEndScrollingAnimation`, как в существующих тестах.
//

#if canImport(UIKit)

import XCTest
import UIKit
import TesseraCore
@testable import TesseraPanorama

// MARK: - Шпион делегата

/// Шпион делегата панорамы: показы, прогресс и снимки загруженного окна.
private final class PanoramaCoverageSpy: PanoramaDelegate {
    /// Индексы `didShowSectionAt` в порядке поступления.
    private(set) var shown: [Int] = []
    /// Значения `didChangeProgress`.
    private(set) var progress: [CGFloat] = []
    /// Сырой `contentOffset.x` в момент каждого `didChangeProgress`.
    private(set) var progressRawOffsets: [CGFloat] = []
    /// Загруженные секции в момент каждого `didShowSectionAt`.
    private(set) var loadedAtShow: [Set<Int>] = []

    func panorama(_ panorama: PanoramaViewController, didShowSectionAt index: Int) {
        shown.append(index)
        loadedAtShow.append(Set(panorama.loadedSections.keys))
    }

    func panorama(_ panorama: PanoramaViewController, didChangeProgress t: CGFloat) {
        progress.append(t)
        progressRawOffsets.append(panorama.scrollView.contentOffset.x)
    }
}

// MARK: - Контент секции с реальным вертикальным скроллом

/// Секция с настоящим вертикальным `UIScrollView` внутри — сценарий варианта B.
private final class VerticalSectionContentController: UIViewController {
    /// Вертикальный скролл-вью контента: регистрируется у панорамы как владелец.
    let scrollView = UIScrollView()

    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Фиксированный высокий контент: размер не зависит от момента, когда
        // UIKit выставит кадр вида (детерминизм теста).
        scrollView.contentSize = CGSize(width: 1_000, height: 3_000)
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
    }
}

final class PanoramaControllerCoverageTests: XCTestCase {

    private var window: UIWindow?

    /// Окно 390×700: при peek 48 шаг секции — 342 pt.
    private let screen = CGSize(width: 390, height: 700)
    private let itemWidth: CGFloat = 342

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        super.tearDown()
    }

    // MARK: - Вспомогательные средства

    /// Секции с фабриками, запоминающими создание контроллеров.
    private func makeSections(
        count: Int,
        ids: [Int]? = nil,
        onMake: ((Int) -> Void)? = nil
    ) -> [PanoramaSection] {
        let identifiers = ids ?? Array(0..<count)
        return identifiers.map { id in
            PanoramaSection(id: id, title: "Section \(id)") {
                onMake?(id)
                return UIViewController()
            }
        }
    }

    /// Секции, чей контент содержит реальный вертикальный скролл.
    private func makeVerticalSections(count: Int) -> [PanoramaSection] {
        (0..<count).map { index in
            PanoramaSection(id: index, title: "Section \(index)") {
                VerticalSectionContentController()
            }
        }
    }

    /// Панорама в настоящем окне: appearance и layout — как в приложении.
    private func makeWindowedPanorama(
        sections: [PanoramaSection],
        size: CGSize? = nil
    ) -> PanoramaViewController {
        let panorama = PanoramaViewController(sections: sections)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size ?? screen))
        window.rootViewController = panorama
        window.isHidden = false
        self.window = window
        panorama.view.frame = window.bounds
        panorama.view.layoutIfNeeded()
        return panorama
    }

    private func loadedIndices(_ panorama: PanoramaViewController) -> Set<Int> {
        Set(panorama.loadedSections.keys)
    }

    /// Доводит начатую снап-анимацию/инерцию до цели: offset в цель и
    /// синтетический конец анимации. Если UIKit уже завершил переход сам,
    /// повторный `didShowSectionAt` подавлен контроллером (lastShown), поэтому
    /// вызов идемпотентен.
    private func completeTransitionIfNeeded(
        _ panorama: PanoramaViewController,
        to targetX: CGFloat
    ) {
        let scrollView = panorama.scrollView
        if abs(scrollView.contentOffset.x - targetX) > 0.001 {
            scrollView.setContentOffset(CGPoint(x: targetX, y: 0), animated: false)
        }
        scrollView.scrollViewDidEndScrollingAnimation(scrollView)
    }

    /// Каждое значение `didChangeProgress` — это ровно прогресс offset'а,
    /// снятого в момент колбэка (инвариант «один скаляр t»).
    private func assertProgressMatchesOffsets(
        _ spy: PanoramaCoverageSpy,
        _ panorama: PanoramaViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            spy.progress.count,
            spy.progressRawOffsets.count,
            "число колбэков прогресса и снимков offset'а не совпало",
            file: file,
            line: line
        )
        for (t, rawOffset) in zip(spy.progress, spy.progressRawOffsets) {
            XCTAssertEqual(
                t,
                panorama.scrollView.readingProgress(forRawOffset: rawOffset),
                accuracy: 0.000_001,
                "t=\(t) не соответствует offset=\(rawOffset)",
                file: file,
                line: line
            )
        }
    }

    // MARK: - (а) Ленивая загрузка окном ±1

    /// Показ 5 секций: child-контроллеры только текущей секции и соседей ±1;
    /// секции окна не только созданы, но и подключены как дети.
    func testLazyWindowLoadsOnlyCurrentAndNeighbourSections() throws {
        var made: [Int] = []
        let panorama = makeWindowedPanorama(sections: makeSections(count: 5) { made.append($0) })

        XCTAssertEqual(panorama.currentSectionIndex, 0)
        XCTAssertEqual(loadedIndices(panorama), [0, 1], "в памяти должна быть только текущая секция и сосед")
        XCTAssertEqual(panorama.children.count, 2, "child-контроллеров вне окна быть не должно")
        XCTAssertEqual(made.sorted(), [0, 1], "фабрики секций вне окна не должны вызываться")

        let first = try XCTUnwrap(panorama.loadedSections[0])
        let second = try XCTUnwrap(panorama.loadedSections[1])
        XCTAssertTrue(first.parent === panorama)
        XCTAssertTrue(second.parent === panorama)
        XCTAssertTrue(first.view.superview === panorama.scrollView)
        XCTAssertEqual(first.view.frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(
            second.view.frame.minX,
            panorama.scrollView.alignmentOffset(forReadingIndex: 1),
            accuracy: 0.001
        )

        // Переход к средней секции: окно переезжает, ушедшая выгружается.
        panorama.selectSection(at: 2, animated: false)

        XCTAssertEqual(panorama.currentSectionIndex, 2)
        XCTAssertEqual(loadedIndices(panorama), [1, 2, 3])
        XCTAssertEqual(panorama.children.count, 3)
        XCTAssertNil(first.parent, "секция вне окна должна выгружаться")
        XCTAssertNil(panorama.loadedSections[0])
        XCTAssertFalse(panorama.children.contains { $0 === first })
        XCTAssertEqual(made.sorted(), [0, 1, 2, 3])

        // Край ленты: окно зажимается, лишних соседей нет.
        panorama.selectSection(at: 4, animated: false)

        XCTAssertEqual(loadedIndices(panorama), [3, 4])
        XCTAssertEqual(panorama.children.count, 2)
        XCTAssertEqual(panorama.currentSectionIndex, 4)
        XCTAssertEqual(panorama.scrollView.contentOffset.x, panorama.scrollView.alignmentOffset(forReadingIndex: 4), accuracy: 0.5)
    }

    /// Выгруженные секции освобождаются: слабые/сильные ссылки контроллера на
    /// них не мешают окну двигаться (повторная загрузка — новый экземпляр).
    func testUnloadedSectionsAreRecreatedOnReturn() throws {
        let panorama = makeWindowedPanorama(sections: makeSections(count: 4))
        let first = try XCTUnwrap(panorama.loadedSections[0])

        panorama.selectSection(at: 3, animated: false)
        XCTAssertNil(first.parent)
        XCTAssertNil(panorama.loadedSections[0])

        panorama.selectSection(at: 0, animated: false)
        let returned = try XCTUnwrap(panorama.loadedSections[0])
        XCTAssertFalse(returned === first, "выгруженная секция должна создаваться заново")
        XCTAssertTrue(returned.parent === panorama)
        XCTAssertEqual(loadedIndices(panorama), [0, 1])
    }

    // MARK: - (б) Prefetch до снапа

    /// Быстрый свайп: цель снапа известна в `scrollViewWillEndDragging` — её
    /// окно догружается **до** снапа и до `didShowSectionAt`, а видимая секция
    /// остаётся в памяти (иначе в кадре был бы пустой слот).
    func testPrefetchLoadsSnapTargetBeforeDeceleration() throws {
        var made: [Int] = []
        let panorama = makeWindowedPanorama(sections: makeSections(count: 5) { made.append($0) })
        panorama.selectSection(at: 1, animated: false) // окно {0, 1, 2}
        let spy = PanoramaCoverageSpy()
        panorama.delegate = spy
        let scrollView = panorama.scrollView
        let visible = [
            0: try XCTUnwrap(panorama.loadedSections[0]),
            1: try XCTUnwrap(panorama.loadedSections[1]),
            2: try XCTUnwrap(panorama.loadedSections[2]),
        ]

        // Опорные точки берём из фактической геометрии скролла (политика снапа
        // возвращает выравнивание секции), а не из литерала: `contentOffset`
        // может выровняться по пикселю устройства.
        let startOffsetX = scrollView.contentOffset.x
        scrollView.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset = CGPoint(x: startOffsetX + itemWidth * 0.4, y: 0)
        let draggedOffsetX = scrollView.contentOffset.x
        var target = scrollView.contentOffset
        // 2 pt/ms = 2000 pt/s > порога 600 → шаг +1 от стартовой секции 1.
        scrollView.scrollViewWillEndDragging(
            scrollView,
            withVelocity: CGPoint(x: 2.0, y: 0),
            targetContentOffset: &target
        )

        XCTAssertEqual(
            target.x,
            scrollView.alignmentOffset(forReadingIndex: 2),
            accuracy: 0.5,
            "цель снапа — секция 2"
        )
        XCTAssertEqual(
            scrollView.contentOffset.x,
            draggedOffsetX,
            accuracy: 0.5,
            "prefetch выполняется до начала снапа: offset ещё на пальце"
        )
        XCTAssertGreaterThan(
            abs(scrollView.contentOffset.x - target.x),
            1,
            "offset не должен прыгнуть к цели до снапа"
        )
        XCTAssertTrue(spy.shown.isEmpty, "didShowSectionAt до завершения перехода быть не должно")
        XCTAssertEqual(
            loadedIndices(panorama),
            [0, 1, 2, 3],
            "prefetch обязан догрузить цель снапа и её соседа, не выгружая текущую секцию"
        )
        XCTAssertTrue(panorama.loadedSections[0] === visible[0], "prefetch не должен выгружать видимую секцию")
        XCTAssertTrue(panorama.loadedSections[1] === visible[1])
        XCTAssertTrue(panorama.loadedSections[2] === visible[2])
        XCTAssertNotNil(panorama.loadedSections[3])
        XCTAssertEqual(made.sorted(), [0, 1, 2, 3])

        // Инерция закончилась на цели: окно переезжает, показ — один.
        scrollView.contentOffset = CGPoint(x: target.x, y: 0)
        scrollView.scrollViewDidEndDecelerating(scrollView)

        XCTAssertEqual(spy.shown, [2])
        XCTAssertEqual(loadedIndices(panorama), [1, 2, 3])
        XCTAssertNil(visible[0]?.parent, "секция вне окна выгружается по завершении перехода")
        XCTAssertTrue(spy.loadedAtShow.first?.isSuperset(of: [2, 3]) ?? false)
    }

    /// Обратный свайп: prefetch догружает секцию позади окна — симметрично
    /// прямому направлению.
    func testPrefetchWorksBackwards() {
        let panorama = makeWindowedPanorama(sections: makeSections(count: 5))
        panorama.selectSection(at: 2, animated: false) // окно {1, 2, 3}
        let spy = PanoramaCoverageSpy()
        panorama.delegate = spy
        let scrollView = panorama.scrollView

        scrollView.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset = CGPoint(x: itemWidth * 1.7, y: 0)
        var target = scrollView.contentOffset
        scrollView.scrollViewWillEndDragging(
            scrollView,
            withVelocity: CGPoint(x: -2.0, y: 0),
            targetContentOffset: &target
        )

        XCTAssertEqual(
            target.x,
            scrollView.alignmentOffset(forReadingIndex: 1),
            accuracy: 0.5,
            "цель снапа — секция 1"
        )
        XCTAssertEqual(loadedIndices(panorama), [0, 1, 2, 3])
        XCTAssertTrue(spy.shown.isEmpty)

        scrollView.contentOffset = CGPoint(x: target.x, y: 0)
        scrollView.scrollViewDidEndDecelerating(scrollView)

        XCTAssertEqual(spy.shown, [1])
        XCTAssertEqual(loadedIndices(panorama), [0, 1, 2])
    }

    // MARK: - (в) reload(sections:)

    /// `reload` с теми же `id`: текущая секция, offset и всё загруженное окно
    /// сохраняются, контроллеры переиспользуются (фабрики не вызываются).
    func testReloadWithSameIdentifiersReusesWindowAndCurrentSection() throws {
        var made: [Int] = []
        let panorama = makeWindowedPanorama(sections: makeSections(count: 4) { made.append($0) })
        panorama.selectSection(at: 1, animated: false) // окно {0, 1, 2}
        let before: [Int: UIViewController] = [
            0: try XCTUnwrap(panorama.loadedSections[0]),
            1: try XCTUnwrap(panorama.loadedSections[1]),
            2: try XCTUnwrap(panorama.loadedSections[2]),
        ]
        made.removeAll()
        let spy = PanoramaCoverageSpy()
        panorama.delegate = spy

        panorama.reload(sections: makeSections(count: 4) { made.append($0) })

        XCTAssertEqual(panorama.currentSectionIndex, 1, "текущая секция сохраняется")
        XCTAssertEqual(
            panorama.scrollView.contentOffset.x,
            panorama.scrollView.alignmentOffset(forReadingIndex: 1),
            accuracy: 0.5
        )
        XCTAssertEqual(loadedIndices(panorama), [0, 1, 2], "загруженное окно переиспользуется")
        for (index, controller) in before {
            XCTAssertTrue(
                panorama.loadedSections[index] === controller,
                "контроллер секции \(index) пересоздан"
            )
        }
        XCTAssertEqual(made, [], "фабрики выживших id вызываться не должны")
        XCTAssertTrue(spy.shown.isEmpty, "reload не является показом секции")
    }

    /// `reload` с перестановкой: текущая секция ищется по `id`, выжившие в
    /// новом окне переиспользуются и переставляются в новые слоты, вышедшие из
    /// окна выгружаются, новое создаётся только для окна.
    func testReloadWithReorderKeepsCurrentByIDAndReusesSurvivors() throws {
        var made: [Int] = []
        let panorama = makeWindowedPanorama(sections: makeSections(count: 5) { made.append($0) })
        panorama.selectSection(at: 2, animated: false) // окно {1, 2, 3}
        let byID: [Int: UIViewController] = [
            1: try XCTUnwrap(panorama.loadedSections[1]),
            2: try XCTUnwrap(panorama.loadedSections[2]),
            3: try XCTUnwrap(panorama.loadedSections[3]),
        ]
        made.removeAll()

        // id 2 — текущая; в новом наборе это индекс 2, вокруг него {4, 2, 1};
        // id 3 уходит за окно, id 4 появляется в окне.
        panorama.reload(sections: makeSections(count: 5, ids: [0, 4, 2, 1, 3]) { made.append($0) })

        XCTAssertEqual(panorama.currentSectionIndex, 2, "текущая секция должна сохраняться по id")
        XCTAssertEqual(
            panorama.scrollView.contentOffset.x,
            panorama.scrollView.alignmentOffset(forReadingIndex: 2),
            accuracy: 0.5
        )
        XCTAssertEqual(loadedIndices(panorama), [1, 2, 3])
        XCTAssertTrue(panorama.loadedSections[2] === byID[2], "текущая секция пересоздана")
        XCTAssertTrue(panorama.loadedSections[3] === byID[1], "выживший id пересоздан")
        XCTAssertEqual(
            panorama.loadedSections[3]?.view.frame.minX ?? -1,
            panorama.scrollView.alignmentOffset(forReadingIndex: 3),
            accuracy: 0.001,
            "переиспользованный контроллер должен переехать в новый слот"
        )
        XCTAssertEqual(made, [4], "создаваться должна только секция, которой не было в окне")
        XCTAssertNil(byID[3]?.parent, "секция, вышедшая из окна, выгружается")
        XCTAssertNil(panorama.loadedSections[4])
    }

    // MARK: - (г) Делегат: показ и прогресс

    /// Программный переход: ровно один `didShowSectionAt` на реальную смену,
    /// повторный переход в ту же секцию события не дублирует; дальний
    /// мгновенный переход даёт один показ и скачок прогресса на цель.
    func testProgrammaticTransitionReportsOneShowPerRealChange() {
        let panorama = makeWindowedPanorama(sections: makeSections(count: 5))
        let spy = PanoramaCoverageSpy()
        panorama.delegate = spy

        panorama.selectSection(at: 1, animated: false)
        // Горячий путь кадра: UIKit в приложении присылает его на запись
        // offset'а; в тестовом процессе дублируем событие явно (как в
        // PanoramaControllerReviewTests для делегатов скролла).
        panorama.scrollView.scrollViewDidScroll(panorama.scrollView)

        XCTAssertEqual(spy.shown, [1])
        XCTAssertEqual(spy.progress.last ?? -1, 1, accuracy: 0.001)
        assertProgressMatchesOffsets(spy, panorama)

        // Переход «на месте» — не реальная смена: события нет.
        panorama.selectSection(at: 1, animated: false)
        XCTAssertEqual(spy.shown, [1], "повторный показ той же секции — дубль события")

        // Дальний мгновенный переход: один показ, прогресс — сразу целевой.
        panorama.selectSection(at: 4, animated: false)
        panorama.scrollView.scrollViewDidScroll(panorama.scrollView)

        XCTAssertEqual(spy.shown, [1, 4])
        XCTAssertEqual(spy.progress.last ?? -1, 4, accuracy: 0.001)
        XCTAssertEqual(Set(panorama.loadedSections.keys), [3, 4])
        assertProgressMatchesOffsets(spy, panorama)
        XCTAssertEqual(
            spy.loadedAtShow.last,
            [3, 4],
            "к моменту показа окно ±1 должно быть загружено"
        )
    }

    /// Анимированный программный переход: единственный показ — после
    /// завершения перехода; прогресс не выходит за пределы шага.
    func testAnimatedProgrammaticTransitionReportsSingleShow() {
        let panorama = makeWindowedPanorama(sections: makeSections(count: 5))
        panorama.selectSection(at: 1, animated: false)
        let spy = PanoramaCoverageSpy()
        panorama.delegate = spy

        panorama.selectSection(at: 2, animated: true)
        // Снап-точка — из фактической геометрии скролла: `contentOffset` может
        // выравниваться по пикселю устройства.
        let snapX = panorama.scrollView.alignmentOffset(forReadingIndex: 2)
        // В тестовом процессе анимация может не продвинуться — доводим её так,
        // как это делает UIKit в приложении.
        completeTransitionIfNeeded(panorama, to: snapX)
        panorama.scrollView.scrollViewDidScroll(panorama.scrollView)

        XCTAssertEqual(spy.shown, [2], "на кадрах анимации показ не сообщается")
        XCTAssertEqual(panorama.currentSectionIndex, 2)
        XCTAssertEqual(panorama.scrollView.contentOffset.x, snapX, accuracy: 0.5)
        assertProgressMatchesOffsets(spy, panorama)
        for value in spy.progress {
            XCTAssertGreaterThanOrEqual(value, 1 - 0.001, "прогресс вышел за шаг перехода: \(value)")
            XCTAssertLessThanOrEqual(value, 2 + 0.001, "прогресс вышел за шаг перехода: \(value)")
        }
    }

    /// Свайп: промежуточные кадры (в том числе пересекающие соседнюю секцию)
    /// не дают показа; ровно один `didShowSectionAt` — после завершения
    /// перехода. Жест в пределах той же секции повторного показа не даёт.
    func testSwipeReportsShowOnlyAfterTransitionFinishes() {
        let panorama = makeWindowedPanorama(sections: makeSections(count: 5))
        panorama.selectSection(at: 1, animated: false)
        let spy = PanoramaCoverageSpy()
        panorama.delegate = spy
        let scrollView = panorama.scrollView

        // Свайп вперёд с кадрами, пересекающими секцию 2 и возвращающимися.
        scrollView.scrollViewWillBeginDragging(scrollView)
        for readingOffset: CGFloat in [1.3, 2.2, 1.6] {
            scrollView.contentOffset = CGPoint(x: itemWidth * readingOffset, y: 0)
            // Гарантируем горячий путь события, даже если UIKit не прислал его
            // на программную запись offset'а.
            scrollView.scrollViewDidScroll(scrollView)
        }
        XCTAssertEqual(spy.shown, [], "показ до завершения перехода")
        var target = scrollView.contentOffset
        scrollView.scrollViewWillEndDragging(
            scrollView,
            withVelocity: .zero,
            targetContentOffset: &target
        )
        let snapX = scrollView.alignmentOffset(forReadingIndex: 2)
        XCTAssertEqual(target.x, snapX, accuracy: 0.5, "снап — на ближайшую секцию 2")
        scrollView.scrollViewDidEndDragging(scrollView, willDecelerate: false)
        completeTransitionIfNeeded(panorama, to: snapX)

        XCTAssertEqual(spy.shown, [2], "ровно один показ на реальную смену секции")
        XCTAssertEqual(panorama.currentSectionIndex, 2)
        assertProgressMatchesOffsets(spy, panorama)

        // Жест в пределах секции 2: снап возвращает на ту же секцию — показа нет.
        scrollView.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset = CGPoint(x: itemWidth * 2.2, y: 0)
        scrollView.scrollViewDidScroll(scrollView)
        scrollView.contentOffset = CGPoint(x: itemWidth * 1.85, y: 0)
        scrollView.scrollViewDidScroll(scrollView)
        var secondTarget = scrollView.contentOffset
        scrollView.scrollViewWillEndDragging(
            scrollView,
            withVelocity: .zero,
            targetContentOffset: &secondTarget
        )
        XCTAssertEqual(secondTarget.x, snapX, accuracy: 0.5)
        scrollView.scrollViewDidEndDragging(scrollView, willDecelerate: false)
        completeTransitionIfNeeded(panorama, to: snapX)

        XCTAssertEqual(spy.shown, [2], "жест в пределах секции не должен повторять показ")
        assertProgressMatchesOffsets(spy, panorama)
    }

    // MARK: - (д) Арбитраж варианта B

    /// Вариант B на живых объектах: вертикаль — реальному `UIScrollView` секции
    /// (его прокрутка работает), горизонталь — панораме (её пан — горизонтальный
    /// владелец арбитра, вертикального контента у неё нет). На время
    /// горизонтального жеста ребёнок блокируется и затем восстанавливается —
    /// ровно контракт `TesseraGestureArbiter`, который контроллер собирает на
    /// `.began` пана.
    func testVariantBHorizontalBelongsToPagerVerticalBelongsToSection() throws {
        let panorama = makeWindowedPanorama(sections: makeVerticalSections(count: 3))
        let content = try XCTUnwrap(
            panorama.loadedSections[0] as? VerticalSectionContentController,
            "секция 0 должна быть загружена окном"
        )
        content.view.layoutIfNeeded()
        let sectionScroll = content.scrollView
        XCTAssertTrue(sectionScroll.superview === content.view)
        XCTAssertGreaterThan(
            sectionScroll.contentSize.height,
            sectionScroll.bounds.height,
            "в секции должен быть реальный вертикальный контент"
        )

        // Публичная регистрация вертикального владельца (§5).
        panorama.registerVerticalOwner(sectionScroll)

        // Вертикаль исполняется ребёнком: его offset меняется, панорама стоит.
        let panoramaOffsetBefore = panorama.scrollView.contentOffset
        sectionScroll.setContentOffset(CGPoint(x: 0, y: 40), animated: false)
        XCTAssertEqual(sectionScroll.contentOffset.y, 40, accuracy: 0.001)
        XCTAssertEqual(
            panorama.scrollView.contentOffset.x,
            panoramaOffsetBefore.x,
            accuracy: 0.001,
            "вертикальная прокрутка секции не должна двигать панораму"
        )
        XCTAssertEqual(panorama.scrollView.contentOffset.y, 0, accuracy: 0.001)

        // Горизонталь исполняется панорамой: у скролла нет вертикального
        // контента, направление заблокировано, вертикальный bounce выключен.
        XCTAssertTrue(panorama.scrollView.isDirectionalLockEnabled)
        XCTAssertFalse(panorama.scrollView.alwaysBounceVertical)
        XCTAssertEqual(
            panorama.scrollView.contentSize.height,
            panorama.scrollView.bounds.height,
            accuracy: 0.001,
            "у горизонтального скролла панорамы не должно быть вертикального контента"
        )

        // Решение по доминирующей оси — та же чистая функция, что контроллер
        // применяет на первом колбэке пана (`.began`).
        XCTAssertEqual(
            TesseraGestureArbiter.axisDecision(forVelocity: CGPoint(x: 12, y: 2)),
            .horizontal,
            "горизонтальный жест должен уходить панораме"
        )
        XCTAssertEqual(
            TesseraGestureArbiter.axisDecision(forVelocity: CGPoint(x: 2, y: 12)),
            .vertical,
            "вертикальный жест должен уходить секции"
        )

        // Арбитр с живыми объектами: пан панорамы — горизонтальный владелец
        // (без данных о направлении жест остаётся у него), дети блокируются на
        // время горизонтального жеста и восстанавливаются после.
        let arbiter = TesseraGestureArbiter(
            horizontalOwner: panorama.scrollView,
            verticalOwners: [sectionScroll]
        )
        XCTAssertTrue(arbiter.shouldBegin(panorama.scrollView.panGestureRecognizer))
        XCTAssertTrue(arbiter.gestureRecognizerShouldBegin(panorama.scrollView.panGestureRecognizer))

        XCTAssertTrue(sectionScroll.isScrollEnabled)
        arbiter.prepareForHorizontalScroll()
        XCTAssertFalse(
            sectionScroll.isScrollEnabled,
            "на время горизонтального жеста вертикальный скролл секции блокируется"
        )
        XCTAssertTrue(
            panorama.scrollView.isScrollEnabled,
            "блокировка детей не должна выключать сам горизонтальный владелец"
        )
        arbiter.endHorizontalScroll()
        XCTAssertTrue(sectionScroll.isScrollEnabled, "прокрутка секции должна восстанавливаться")

        // Снятие регистрации не падает и не трогает иерархию (ссылки слабые).
        panorama.unregisterVerticalOwner(sectionScroll)
        XCTAssertTrue(sectionScroll.isScrollEnabled)
    }
}

#endif
