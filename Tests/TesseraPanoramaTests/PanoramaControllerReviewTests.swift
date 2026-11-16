//
//  PanoramaControllerReviewTests.swift
//  TesseraPanoramaTests
//
//  Контроллер-тесты панорамы по итогам ревью (трек T4: E9.2б, E9.7, E10.13,
//  E10.12б). Проектный документ: docs/PANORAMA-IOS-DESIGN.md — §4 «Снап»,
//  §6 «Ленивая загрузка», §7 «Accessibility» (VoiceOver, RTL), §8
//  «Адаптивность» (поворот, отложенный layout, navigation bar).
//
//  Каждый тест воспроизводит сценарий дефекта:
//  - E9.2б: жест без скорости оставлял offset между снап-точками;
//  - E9.7: VoiceOver-свайп с заголовка не листал; `contentInsetAdjustmentBehavior`
//    не настраивался стилем;
//  - E10.13: отложенный layout не применялся; смена LTR↔RTL открывала
//    зеркальную секцию; смена `peek` оставляла секцию между снап-точками;
//    `reload` пересоздавал выжившие секции; дальний `selectSection` пролетал
//    пустые слоты; тот же стиль переприменялся; поворот слал ложный прогресс;
//  - E10.12б: SwiftUI-контент секции с тем же `id`/заголовком не обновлялся.
//
//  Анимация `setContentOffset(_:animated:)` в тестовом процессе без окна
//  ведёт себя по-разному (UIKit может завершить её синхронно), поэтому тесты
//  допускают оба исхода: синхронное завершение либо имитацию конца анимации
//  вызовом `scrollViewDidEndScrollingAnimation`.
//

#if canImport(UIKit)

import SwiftUI
import XCTest
import UIKit
import TesseraCore
@testable import TesseraPanorama

/// Шпион делегата: показы секций и прогресс (с состоянием окна секций).
private final class PanoramaSpy: TesseraPanoramaDelegate {
    var shown: [Int] = []
    var progress: [CGFloat] = []
    /// Загруженные секции в момент каждого `didChangeProgress`.
    var loadedAtProgress: [Set<Int>] = []

    func panorama(_ panorama: TesseraPanoramaViewController, didShowSectionAt index: Int) {
        shown.append(index)
    }

    func panorama(_ panorama: TesseraPanoramaViewController, didChangeProgress t: CGFloat) {
        progress.append(t)
        loadedAtProgress.append(Set(panorama.loadedSections.keys))
    }
}

/// SwiftUI-контент секции с проверяемым значением.
private struct ProbeView: View {
    let value: Int

    var body: some View {
        Text("\(value)")
    }
}

final class PanoramaControllerReviewTests: XCTestCase {

    private let screen = CGSize(width: 390, height: 700)

    /// Шаг секции при peek 48: `390 − 48 = 342`.
    private let itemWidth: CGFloat = 342

    // MARK: - Вспомогательные средства

    private func makeSections(
        count: Int,
        ids: [Int]? = nil,
        onMake: ((Int) -> Void)? = nil
    ) -> [TesseraPanoramaSection] {
        (ids ?? Array(0..<count)).map { id in
            TesseraPanoramaSection(id: id, title: "Section \(id)") {
                onMake?(id)
                return UIViewController()
            }
        }
    }

    private func makeSwiftUISections(count: Int, value: Int) -> [TesseraPanoramaSection] {
        (0..<count).map { id in
            TesseraPanoramaSection(
                id: id,
                title: "Section \(id)",
                content: TesseraSwiftUIContentProvider { ProbeView(value: value) }
            )
        }
    }

    private func makePanorama(
        sections: [TesseraPanoramaSection],
        style: TesseraPanoramaStyle = TesseraPanoramaStyle(),
        size: CGSize? = nil
    ) -> TesseraPanoramaViewController {
        let panorama = TesseraPanoramaViewController(sections: sections, style: style)
        panorama.loadViewIfNeeded()
        panorama.view.frame = CGRect(origin: .zero, size: size ?? screen)
        panorama.view.layoutIfNeeded()
        return panorama
    }

    private func makePanorama(count: Int = 4) -> TesseraPanoramaViewController {
        makePanorama(sections: makeSections(count: count))
    }

    /// Доводит программную анимацию offset'а до конца, если UIKit не завершил
    /// её синхронно.
    private func finishAnimationIfNeeded(
        _ panorama: TesseraPanoramaViewController,
        to targetX: CGFloat,
        spy: PanoramaSpy,
        expectedShown: Int
    ) {
        guard !spy.shown.contains(expectedShown) else { return }
        let scrollView = panorama.scrollView
        scrollView.setContentOffset(CGPoint(x: targetX, y: 0), animated: false)
        scrollView.scrollViewDidEndScrollingAnimation(scrollView)
    }

    // MARK: - E9.2б: доводка снапа без инерции

    /// Жест закончился без скорости на 200 pt: политика выбирает секцию 1
    /// (342), но UIKit при нулевой скорости цель игнорирует. Панорама сама
    /// доводит offset до 342 и только потом сообщает показ секции.
    func testDragWithoutVelocityAlignsOffset() {
        let panorama = makePanorama()
        let spy = PanoramaSpy()
        panorama.delegate = spy
        let scrollView = panorama.scrollView

        scrollView.contentOffset = .zero
        scrollView.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset = CGPoint(x: 200, y: 0)
        var target = CGPoint(x: 200, y: 0)
        scrollView.scrollViewWillEndDragging(scrollView, withVelocity: .zero, targetContentOffset: &target)
        XCTAssertEqual(target.x, itemWidth, accuracy: 0.001)

        scrollView.scrollViewDidEndDragging(scrollView, willDecelerate: false)

        // Либо анимация завершилась синхронно (offset выровнен, показ — 1),
        // либо она ещё идёт и показ не сообщён. Показ при невыровненном
        // offset'е — дефект E9.2б.
        XCTAssertTrue(
            spy.shown.isEmpty || abs(scrollView.contentOffset.x - itemWidth) < 0.001,
            "показ секции \(spy.shown) при невыровненном offset \(scrollView.contentOffset.x)"
        )
        finishAnimationIfNeeded(panorama, to: itemWidth, spy: spy, expectedShown: 1)

        XCTAssertEqual(scrollView.contentOffset.x, itemWidth, accuracy: 0.001, "offset не выровнен после drag без скорости")
        XCTAssertEqual(spy.shown, [1])
        XCTAssertEqual(panorama.currentSectionIndex, 1)
    }

    /// Без цели политики (жест без `willEndDragging`) доводка идёт к ближайшей
    /// секции: 442 pt (1,29 секции) — назад к секции 1, а не «как есть».
    func testDragWithoutVelocityAndWithoutPolicyTargetAlignsToNearest() {
        let panorama = makePanorama()
        let spy = PanoramaSpy()
        panorama.delegate = spy
        let scrollView = panorama.scrollView

        scrollView.contentOffset = CGPoint(x: itemWidth + 100, y: 0)
        scrollView.scrollViewDidEndDragging(scrollView, willDecelerate: false)

        XCTAssertTrue(
            spy.shown.isEmpty || abs(scrollView.contentOffset.x - itemWidth) < 0.001,
            "показ секции \(spy.shown) при невыровненном offset \(scrollView.contentOffset.x)"
        )
        finishAnimationIfNeeded(panorama, to: itemWidth, spy: spy, expectedShown: 1)

        XCTAssertEqual(scrollView.contentOffset.x, itemWidth, accuracy: 0.001)
        XCTAssertEqual(spy.shown, [1])
    }

    /// Уже выровненный offset: доводка не нужна, переход завершается сразу.
    func testDragEndingAlignedFinishesImmediately() {
        let panorama = makePanorama()
        let spy = PanoramaSpy()
        panorama.delegate = spy
        let scrollView = panorama.scrollView

        scrollView.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset = CGPoint(x: itemWidth, y: 0)
        var target = CGPoint(x: itemWidth, y: 0)
        scrollView.scrollViewWillEndDragging(scrollView, withVelocity: .zero, targetContentOffset: &target)
        scrollView.scrollViewDidEndDragging(scrollView, willDecelerate: false)

        XCTAssertEqual(spy.shown, [1])
        XCTAssertEqual(scrollView.contentOffset.x, itemWidth, accuracy: 0.001)
    }

    // MARK: - E9.7: VoiceOver с заголовка, contentInsetAdjustmentBehavior

    /// Фокус VoiceOver на слое заголовков: трёхпальцевый свайп влево (вперёд
    /// в LTR по конвенции UIKit, W1) листает на следующую секцию.
    func testAccessibilityScrollFromHeaderPagesSections() {
        let panorama = makePanorama()
        panorama.view.semanticContentAttribute = .forceLeftToRight
        panorama.view.layoutIfNeeded()
        let spy = PanoramaSpy()
        panorama.delegate = spy

        XCTAssertTrue(panorama.headerView.accessibilityScroll(.left), "жест с заголовка обязан листать")
        finishAnimationIfNeeded(panorama, to: itemWidth, spy: spy, expectedShown: 1)

        XCTAssertEqual(panorama.currentSectionIndex, 1)
        XCTAssertEqual(panorama.scrollView.contentOffset.x, itemWidth, accuracy: 0.001)

        // Вертикальный жест — не листание секций.
        XCTAssertFalse(panorama.headerView.accessibilityScroll(.up))
    }

    /// §8: подстройка отступов полосы секций берётся из стиля и меняется на лету.
    func testContentInsetAdjustmentBehaviorComesFromStyle() {
        let panorama = makePanorama()
        XCTAssertEqual(panorama.scrollView.contentInsetAdjustmentBehavior, .never)

        var style = TesseraPanoramaStyle()
        style.contentInsetAdjustmentBehavior = .always
        panorama.style = style
        XCTAssertEqual(panorama.scrollView.contentInsetAdjustmentBehavior, .always)

        let configured = makePanorama(
            sections: makeSections(count: 2),
            style: TesseraPanoramaStyle(contentInsetAdjustmentBehavior: .scrollableAxes)
        )
        XCTAssertEqual(configured.scrollView.contentInsetAdjustmentBehavior, .scrollableAxes)
    }

    // MARK: - E10.13: отложенный layout

    /// Поворот во время жеста откладывается (§8), а по завершении инерции
    /// обязан примениться: кадр полосы и offset — под новую ширину.
    func testDeferredLayoutIsAppliedWhenScrollEnds() {
        let panorama = makePanorama()
        panorama.selectSection(at: 1, animated: false)
        let scrollView = panorama.scrollView

        scrollView.interactionOverrideForTesting = true
        panorama.view.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        panorama.view.layoutIfNeeded()
        XCTAssertEqual(scrollView.frame.width, screen.width, "во время жеста layout откладывается")

        scrollView.interactionOverrideForTesting = false
        scrollView.scrollViewDidEndDecelerating(scrollView)

        XCTAssertEqual(scrollView.frame.width, 844, "отложенный layout не применился")
        XCTAssertEqual(scrollView.contentOffset.x, scrollView.alignmentOffset(forReadingIndex: 1), accuracy: 0.001)
        XCTAssertEqual(panorama.currentSectionIndex, 1)
    }

    // MARK: - E10.13: смена направления чтения на лету

    /// LTR → RTL → LTR через `semanticContentAttribute` корневого вида:
    /// остаётся та же секция в порядке чтения, а не зеркальная.
    func testSemanticDirectionChangeKeepsReadingSection() {
        let panorama = makePanorama()
        panorama.view.semanticContentAttribute = .forceLeftToRight
        panorama.view.layoutIfNeeded()
        panorama.selectSection(at: 1, animated: false)
        let scrollView = panorama.scrollView
        XCTAssertEqual(scrollView.contentOffset.x, itemWidth, accuracy: 0.001)

        panorama.view.semanticContentAttribute = .forceRightToLeft
        panorama.view.layoutIfNeeded()

        XCTAssertEqual(scrollView.resolvedLayoutDirection, .rightToLeft)
        XCTAssertEqual(panorama.currentSectionIndex, 1, "смена направления открыла другую секцию")
        // RTL: секция 1 — физический слот 4 − 1 − 1 = 2.
        XCTAssertEqual(scrollView.contentOffset.x, 2 * itemWidth, accuracy: 0.001)
        XCTAssertNotNil(panorama.loadedSections[1])

        panorama.view.semanticContentAttribute = .forceLeftToRight
        panorama.view.layoutIfNeeded()

        XCTAssertEqual(scrollView.resolvedLayoutDirection, .leftToRight)
        XCTAssertEqual(panorama.currentSectionIndex, 1)
        XCTAssertEqual(scrollView.contentOffset.x, itemWidth, accuracy: 0.001)
    }

    /// То же через trait-окружение (направление интерфейса от родителя).
    func testTraitDirectionChangeKeepsReadingSection() {
        // Trait-окружение распространяется только по иерархии с окном.
        let window = UIWindow(frame: CGRect(origin: .zero, size: screen))
        let parent = UIViewController()
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        parent.view.frame = CGRect(origin: .zero, size: screen)
        let panorama = TesseraPanoramaViewController(sections: makeSections(count: 4))
        parent.addChild(panorama)
        parent.view.addSubview(panorama.view)
        panorama.didMove(toParent: parent)
        parent.setOverrideTraitCollection(UITraitCollection(layoutDirection: .leftToRight), forChild: panorama)
        panorama.view.frame = CGRect(origin: .zero, size: screen)
        panorama.view.layoutIfNeeded()
        panorama.selectSection(at: 0, animated: false)
        let scrollView = panorama.scrollView
        XCTAssertEqual(scrollView.contentOffset.x, 0, accuracy: 0.001)

        parent.setOverrideTraitCollection(UITraitCollection(layoutDirection: .rightToLeft), forChild: panorama)
        panorama.view.setNeedsLayout()
        panorama.view.layoutIfNeeded()

        XCTAssertEqual(scrollView.resolvedLayoutDirection, .rightToLeft, "trait-направление не дошло до скролла")
        XCTAssertEqual(panorama.currentSectionIndex, 0, "смена направления открыла зеркальную секцию")
        XCTAssertEqual(scrollView.contentOffset.x, 3 * itemWidth, accuracy: 0.001)
    }

    // MARK: - E10.13: смена peek на лету

    /// Смена `peek` меняет шаг секции; секция остаётся выровненной по новой
    /// снап-точке, а не между ними.
    func testPeekChangeKeepsSectionAligned() {
        let panorama = makePanorama()
        panorama.selectSection(at: 2, animated: false)
        let scrollView = panorama.scrollView
        XCTAssertEqual(scrollView.contentOffset.x, 2 * itemWidth, accuracy: 0.001)

        panorama.style = TesseraPanoramaStyle(peek: 16)
        panorama.view.layoutIfNeeded()

        XCTAssertEqual(scrollView.itemWidth, 374, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentOffset.x, 2 * 374, accuracy: 0.001, "секция между снап-точками")
        XCTAssertEqual(panorama.currentSectionIndex, 2)
    }

    // MARK: - E10.13: reload переиспользует секции

    /// `reload` с теми же `id`: загруженные контроллеры — те же экземпляры,
    /// фабрики заново не вызываются.
    func testReloadReusesSurvivingSections() {
        var made: [Int] = []
        let panorama = makePanorama(sections: makeSections(count: 4) { made.append($0) })
        let before0 = panorama.loadedSections[0]
        let before1 = panorama.loadedSections[1]
        XCTAssertNotNil(before0)
        XCTAssertEqual(made.sorted(), [0, 1])

        panorama.reload(sections: makeSections(count: 4) { made.append($0) })

        XCTAssertTrue(panorama.loadedSections[0] === before0, "секция 0 пересоздана")
        XCTAssertTrue(panorama.loadedSections[1] === before1, "секция 1 пересоздана")
        XCTAssertEqual(made.sorted(), [0, 1], "фабрики выживших не должны вызываться")
        XCTAssertTrue(before0?.parent === panorama)
    }

    /// Перестановка: текущая секция ищется по `id`, выжившие в новом окне
    /// переиспользуются, вышедшие из окна и исчезнувшие выгружаются.
    func testReloadWithReorderKeepsCurrentAndReusesWindow() {
        var made: [Int] = []
        let panorama = makePanorama(sections: makeSections(count: 4) { made.append($0) })
        panorama.selectSection(at: 1, animated: false)
        let byID: [Int: UIViewController] = [
            0: panorama.loadedSections[0]!,
            1: panorama.loadedSections[1]!,
            2: panorama.loadedSections[2]!,
        ]
        made.removeAll()

        panorama.reload(sections: makeSections(count: 4, ids: [3, 1, 0, 2]) { made.append($0) })

        XCTAssertEqual(panorama.currentSectionIndex, 1, "текущая секция — по id 1")
        XCTAssertEqual(panorama.scrollView.contentOffset.x, itemWidth, accuracy: 0.001)
        XCTAssertTrue(panorama.loadedSections[1] === byID[1])
        XCTAssertTrue(panorama.loadedSections[2] === byID[0])
        XCTAssertEqual(made, [3], "создаётся только новая в окне секция")
        XCTAssertNil(byID[2]?.parent, "вышедшая из окна секция выгружена")
    }

    // MARK: - E10.13: дальний анимированный selectSection

    /// Переход 0 → 5 с анимацией: ни на одном кадре прогресса в кадре нет
    /// невыгруженных секций, и анимируется только последний шаг 4 → 5.
    func testAnimatedFarSelectDoesNotFlyOverEmptySlots() {
        let panorama = makePanorama(count: 6)
        let spy = PanoramaSpy()
        panorama.delegate = spy

        panorama.selectSection(at: 5, animated: true)
        finishAnimationIfNeeded(panorama, to: 5 * itemWidth, spy: spy, expectedShown: 5)

        XCTAssertFalse(spy.progress.isEmpty)
        for (progress, loaded) in zip(spy.progress, spy.loadedAtProgress) {
            let visible = Set([Int(progress.rounded(.down)), Int(progress.rounded(.up))])
            XCTAssertTrue(
                visible.isSubset(of: loaded),
                "прогресс \(progress): в кадре секции \(visible), загружены \(loaded.sorted())"
            )
            XCTAssertGreaterThanOrEqual(progress, 4 - 0.001, "анимация пролетает промежуточные слоты")
        }
        XCTAssertEqual(panorama.currentSectionIndex, 5)
        XCTAssertEqual(spy.shown, [5])
        XCTAssertEqual(Set(panorama.loadedSections.keys), [4, 5])
    }

    // MARK: - E10.13: тот же стиль не переприменяется

    /// SwiftUI присваивает стиль на каждом обновлении: равный стиль не
    /// запускает layout и не трогает слои.
    func testAssigningEquivalentStyleIsNoOp() {
        let image = UIImage()
        let panorama = makePanorama(
            sections: makeSections(count: 3),
            style: TesseraPanoramaStyle(backgroundBehavior: .image(image))
        )
        XCTAssertFalse(panorama.view.layer.needsLayout())

        panorama.style = TesseraPanoramaStyle(backgroundBehavior: .image(image))
        XCTAssertFalse(panorama.view.layer.needsLayout(), "тот же стиль переприменён")

        panorama.style = TesseraPanoramaStyle(peek: 20, backgroundBehavior: .image(image))
        XCTAssertTrue(panorama.view.layer.needsLayout(), "новый стиль обязан примениться")
    }

    /// Сравнение стиля учитывает каждое поле.
    func testStyleEquivalenceCoversAllFields() {
        let base = TesseraPanoramaStyle()
        XCTAssertTrue(base.isEquivalent(to: TesseraPanoramaStyle()))

        var changed = base
        changed.parallaxFactor = 0.42
        XCTAssertFalse(base.isEquivalent(to: changed))
        changed = base
        changed.headerFont = .systemFont(ofSize: 20)
        XCTAssertFalse(base.isEquivalent(to: changed))
        changed = base
        changed.headerColor = .red
        XCTAssertFalse(base.isEquivalent(to: changed))
        changed = base
        changed.headerActiveColor = .red
        XCTAssertFalse(base.isEquivalent(to: changed))
        changed = base
        changed.contentInsetAdjustmentBehavior = .always
        XCTAssertFalse(base.isEquivalent(to: changed))
        changed = base
        changed.backgroundBehavior = .image(nil)
        XCTAssertFalse(base.isEquivalent(to: changed))
        XCTAssertFalse(
            TesseraPanoramaStyle(backgroundBehavior: .image(UIImage()))
                .isEquivalent(to: TesseraPanoramaStyle(backgroundBehavior: .image(UIImage()))),
            "картинки сравниваются по идентичности"
        )
    }

    // MARK: - E10.13: поворот без ложного прогресса

    /// Поворот — пересчёт геометрии, а не прогресс пользователя: делегат не
    /// получает `didChangeProgress`, секция сохраняется.
    func testRotationDoesNotReportProgress() {
        let panorama = makePanorama()
        panorama.selectSection(at: 3, animated: false)
        let spy = PanoramaSpy()
        panorama.delegate = spy

        panorama.view.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        panorama.view.layoutIfNeeded()
        panorama.view.frame = CGRect(origin: .zero, size: screen)
        panorama.view.layoutIfNeeded()

        XCTAssertEqual(spy.progress, [], "ложный didChangeProgress при повороте")
        XCTAssertEqual(panorama.currentSectionIndex, 3)
        XCTAssertEqual(panorama.scrollView.contentOffset.x, 3 * itemWidth, accuracy: 0.001)
    }

    // MARK: - E10.12б: контент SwiftUI-секций с тем же id

    /// Те же `id`/заголовки, новый контент: загруженные SwiftUI-секции
    /// обновляются на месте — тот же контроллер, новый `rootView`; offset и
    /// текущая секция не меняются, делегат молчит.
    func testUpdateContentRefreshesLoadedSwiftUISectionsInPlace() throws {
        let panorama = makePanorama(sections: makeSwiftUISections(count: 4, value: 1))
        panorama.selectSection(at: 1, animated: false)
        let spy = PanoramaSpy()
        panorama.delegate = spy
        let before = try XCTUnwrap(panorama.loadedSections[1] as? UIHostingController<ProbeView>)
        XCTAssertEqual(before.rootView.value, 1)

        panorama.updateContent(of: makeSwiftUISections(count: 4, value: 2))

        let after = try XCTUnwrap(panorama.loadedSections[1] as? UIHostingController<ProbeView>)
        XCTAssertTrue(after === before, "контроллер секции пересоздан")
        XCTAssertEqual(after.rootView.value, 2, "контент не обновлён")
        XCTAssertEqual(
            (panorama.loadedSections[0] as? UIHostingController<ProbeView>)?.rootView.value,
            2
        )
        XCTAssertEqual(panorama.currentSectionIndex, 1)
        XCTAssertEqual(panorama.scrollView.contentOffset.x, itemWidth, accuracy: 0.001)
        XCTAssertEqual(spy.shown, [])
        XCTAssertEqual(spy.progress, [])

        // Невыгруженная секция создаётся уже из нового поставщика.
        panorama.selectSection(at: 3, animated: false)
        XCTAssertEqual((panorama.loadedSections[3] as? UIHostingController<ProbeView>)?.rootView.value, 2)
    }

    /// Сквозной сценарий фасада: перерисовка `TesseraPanoramaView` с теми же
    /// `id`/заголовками доносит новый контент до секции.
    func testPanoramaViewPropagatesContentForSameIdentifiers() throws {
        let window = UIWindow(frame: CGRect(origin: .zero, size: screen))
        let host = UIHostingController(rootView: TesseraPanoramaView(sections: makeSwiftUISections(count: 3, value: 1)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()

        let panorama = try XCTUnwrap(Self.findPanorama(in: host), "TesseraPanoramaViewController не найден")
        panorama.view.layoutIfNeeded()
        let before = try XCTUnwrap(panorama.loadedSections[0] as? UIHostingController<ProbeView>)
        XCTAssertEqual(before.rootView.value, 1)

        host.rootView = TesseraPanoramaView(sections: makeSwiftUISections(count: 3, value: 7))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let after = try XCTUnwrap(panorama.loadedSections[0] as? UIHostingController<ProbeView>)
        XCTAssertTrue(after === before)
        XCTAssertEqual(after.rootView.value, 7, "SwiftUI-контент секции с тем же id не обновился")
    }

    private static func findPanorama(in controller: UIViewController) -> TesseraPanoramaViewController? {
        if let panorama = controller as? TesseraPanoramaViewController { return panorama }
        for child in controller.children {
            if let found = findPanorama(in: child) { return found }
        }
        return nil
    }
}

#endif
