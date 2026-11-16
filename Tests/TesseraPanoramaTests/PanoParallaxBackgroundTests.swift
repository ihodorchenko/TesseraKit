//
//  PanoParallaxBackgroundTests.swift
//  TesseraPanoramaTests
//
//  Тесты фона панорамы под параллакс (задача E10.7в).
//  Проектные документы: docs/PANORAMA-IOS-DESIGN.md §3 «Параллакс фона»,
//  docs/CORE-IOS-DESIGN.md §2 («Параллакс: backgroundOffset = offset × factor;
//  слой заведомо больше contentSize»).
//
//  Слой фона — сосед скролла (лежит в `view`, а не в `TesseraPanoScrollView`), и Core
//  проецирует смещение фона на экран со знаком минус: `transform = −offset ×
//  factor`. Проверяются направление (фон уезжает туда же, куда секции, но
//  медленнее) и покрытие: картинка закрывает весь экран в начале и в конце
//  ленты, а также на «резине» за обоими краями.
//

#if canImport(UIKit)

import XCTest
import UIKit
import TesseraCore
@testable import TesseraPanorama

final class PanoParallaxBackgroundTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Размер экрана панорамы.
    private let screenSize = CGSize(width: 390, height: 700)

    /// Множитель параллакса: верхняя граница типичного диапазона §4 (0.4–0.6).
    private let factor: CGFloat = 0.6

    /// Загруженная и разложенная панорама из четырёх секций с картинкой фона.
    private func makePanorama(factor: CGFloat? = nil) -> TesseraPanoramaViewController {
        let factor = factor ?? self.factor
        let sections = (0..<4).map { index in
            TesseraPanoramaSection(id: index, title: "Section \(index)") { UIViewController() }
        }
        let style = TesseraPanoramaStyle(
            parallaxFactor: factor,
            backgroundBehavior: .image(UIImage())
        )
        let panorama = TesseraPanoramaViewController(sections: sections, style: style)
        panorama.loadViewIfNeeded()
        panorama.view.frame = CGRect(origin: .zero, size: screenSize)
        panorama.view.layoutIfNeeded()
        // Системный Reduce Motion симулятора не должен влиять на геометрию теста.
        panorama.parallaxLayer.respectsReduceMotion = false
        return panorama
    }

    /// Картинка фона внутри слоя.
    private func backgroundImageView(
        of panorama: TesseraPanoramaViewController
    ) throws -> UIImageView {
        try XCTUnwrap(
            panorama.parallaxLayer.subviews.compactMap { $0 as? UIImageView }.first,
            "Фон панорамы — картинка внутри слоя параллакса"
        )
    }

    /// Экранный (в координатах `view`) прямоугольник картинки фона с учётом
    /// `transform` слоя.
    private func screenRectOfBackground(
        in panorama: TesseraPanoramaViewController
    ) throws -> CGRect {
        let imageView = try backgroundImageView(of: panorama)
        return imageView.convert(imageView.bounds, to: panorama.view)
    }

    /// Пишет offset в скролл панорамы; трансляцию в слой делает сама панорама
    /// из `scrollViewDidScroll`.
    private func scroll(_ panorama: TesseraPanoramaViewController, toX x: CGFloat) {
        panorama.scrollView.contentOffset = CGPoint(x: x, y: 0)
    }

    /// Проверяет, что картинка фона закрывает весь экран.
    private func assertBackgroundCoversScreen(
        _ panorama: TesseraPanoramaViewController,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let rect = try screenRectOfBackground(in: panorama)
        let screen = panorama.view.bounds
        let tolerance: CGFloat = 0.001
        XCTAssertLessThanOrEqual(rect.minX, screen.minX + tolerance, "\(message): полоса слева", file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.maxX, screen.maxX - tolerance, "\(message): полоса справа", file: file, line: line)
        XCTAssertLessThanOrEqual(rect.minY, screen.minY + tolerance, "\(message): полоса сверху", file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.maxY, screen.maxY - tolerance, "\(message): полоса снизу", file: file, line: line)
    }

    // MARK: - Направление (E10.7)

    /// Рост offset'а на Δ уводит фон на экране на −Δ × factor: в ту же сторону,
    /// что и секции, но медленнее. До E10.7 фон ехал вправо — против контента.
    func testBackgroundMovesWithSectionsButSlower() throws {
        let panorama = makePanorama()
        let maximum = panorama.scrollView.maximumOffsetX
        XCTAssertGreaterThan(maximum, 0, "Четыре секции обязаны давать ход ленты")

        scroll(panorama, toX: 0)
        let before = try screenRectOfBackground(in: panorama)

        let delta = maximum / 2
        scroll(panorama, toX: delta)
        let after = try screenRectOfBackground(in: panorama)

        XCTAssertEqual(after.minX - before.minX, -delta * factor, accuracy: 0.001)
        XCTAssertEqual(after.minY, before.minY, accuracy: 0.001, "Вертикали у панорамы нет")
        XCTAssertEqual(panorama.parallaxLayer.transform.tx, -delta * factor, accuracy: 0.001)
    }

    // MARK: - Покрытие экрана

    /// В начале ленты (offset 0) фон закрывает экран.
    func testBackgroundCoversScreenAtStart() throws {
        let panorama = makePanorama()
        scroll(panorama, toX: 0)
        try assertBackgroundCoversScreen(panorama, "offset 0")
    }

    /// В конце ленты (максимальный offset) фон закрывает экран: ход фона
    /// `maximumOffsetX × factor` лежит справа от вьюпорта.
    func testBackgroundCoversScreenAtEnd() throws {
        let panorama = makePanorama()
        scroll(panorama, toX: panorama.scrollView.maximumOffsetX)
        try assertBackgroundCoversScreen(panorama, "максимальный offset")
    }

    /// «Резина» за обоими краями ленты не обнажает краёв фона.
    func testBackgroundCoversScreenOnBounceAtBothEdges() throws {
        let panorama = makePanorama()
        let bounce = screenSize.width / 2

        scroll(panorama, toX: -bounce)
        try assertBackgroundCoversScreen(panorama, "bounce до начала ленты")

        scroll(panorama, toX: panorama.scrollView.maximumOffsetX + bounce)
        try assertBackgroundCoversScreen(panorama, "bounce за концом ленты")
    }

    /// Покрытие держится на всём допустимом диапазоне фактора (E9.7: кламп
    /// `(0, 1)` вместо `0.4…0.6`), включая крайние 0.01 и 0.99 — в том числе на
    /// «резине» в полэкрана за обоими краями.
    func testBackgroundCoversScreenForWholeFactorRange() throws {
        let bounce = screenSize.width / 2
        for factor: CGFloat in [0.01, 0.2, 0.8, 0.99] {
            let panorama = makePanorama(factor: factor)
            let maximum = panorama.scrollView.maximumOffsetX
            for x in [-bounce, 0, maximum / 2, maximum, maximum + bounce] {
                scroll(panorama, toX: x)
                try assertBackgroundCoversScreen(panorama, "factor \(factor), offset \(x)")
            }
        }
    }
}

#endif
