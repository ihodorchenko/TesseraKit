//
//  StartWallpaperParallaxTests.swift
//  TesseraStartScreenTests
//
//  Тесты обоев START-страницы под вертикальный параллакс (задача E10.7б).
//  Проектные документы: docs/STARTSCREEN-IOS-DESIGN.md §8 «Параллакс обоев»,
//  docs/CORE-IOS-DESIGN.md §2 («Параллакс: backgroundOffset = offset × factor;
//  слой заведомо больше contentSize»).
//
//  Слой обоев — сосед скролла сетки (лежит в виде страницы, а не в коллекции),
//  и Core проецирует смещение фона на экран со знаком минус: `transform =
//  −offset × factor`. Проверяются направление (обои уезжают вверх вместе с
//  плитками, но медленнее) и покрытие: картинка закрывает страницу в начале и
//  в конце прокрутки, а также на «резине» за обоими краями.
//

#if canImport(UIKit)

import XCTest
import UIKit
import TesseraCore
@testable import TesseraStartScreen

final class StartWallpaperParallaxTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Множитель параллакса: верхняя граница клампа (0.4...0.6), при ней ход
    /// обоев максимален.
    private let factor: CGFloat = 0.6

    /// Собранная START-страница: экран, слой обоев, вид страницы и коллекция.
    private struct Scene {
        let screen: TesseraStartScreenViewController
        let layer: TesseraParallaxLayer
        let page: UIView
        let collectionView: UICollectionView

        /// Максимальный offset сетки — тем же расчётом, что и раскладка обоев.
        var maximumOffset: CGFloat {
            let height = page.bounds.height
            return max(0, max(screen.gridView.contentSize.height, height) - height)
        }
    }

    /// Ищет первый вид заданного типа в поддереве.
    private func firstSubview<T: UIView>(of type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    /// Экран с высокой сеткой (заведомо больше вьюпорта) и картинкой обоев.
    private func makeScene() throws -> Scene {
        let screen = TesseraStartScreenViewController()
        screen.wallpaperParallaxFactor = factor
        screen.wallpaperImage = UIImage()
        let tiles = (0..<40).map { TileGridItem.tile(tesseraTestTile("t\($0)")) }
        screen.reload(grid: TileGridSnapshot(items: tiles, unpinned: []))

        screen.loadViewIfNeeded()
        screen.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        screen.view.layoutIfNeeded()

        // Без окна пейджер мог ещё не разложить страницы — доводим вручную,
        // как в `PagerPagesTests`.
        let pager = try XCTUnwrap(
            screen.children.compactMap { $0 as? TesseraPagerViewController }.first,
            "Экран обязан содержать пейджер Core"
        )
        pager.view.frame = screen.view.bounds
        pager.view.layoutIfNeeded()

        let layer = try XCTUnwrap(
            firstSubview(of: TesseraParallaxLayer.self, in: screen.view),
            "START-страница держит слой обоев"
        )
        let page = try XCTUnwrap(layer.superview, "Слой обоев лежит в виде страницы")
        page.layoutIfNeeded()

        let collectionView = try XCTUnwrap(
            screen.gridView.subviews.compactMap { $0 as? UICollectionView }.first,
            "Сетка держит коллекцию"
        )
        // Системный Reduce Motion симулятора не должен влиять на геометрию теста.
        layer.respectsReduceMotion = false

        return Scene(screen: screen, layer: layer, page: page, collectionView: collectionView)
    }

    /// Картинка обоев внутри слоя.
    private func wallpaperView(in scene: Scene) throws -> UIImageView {
        try XCTUnwrap(
            scene.layer.subviews.compactMap { $0 as? UIImageView }.first,
            "Обои — картинка внутри слоя параллакса"
        )
    }

    /// Прямоугольник обоев в координатах страницы с учётом `transform` слоя.
    private func screenRectOfWallpaper(in scene: Scene) throws -> CGRect {
        let imageView = try wallpaperView(in: scene)
        return imageView.convert(imageView.bounds, to: scene.page)
    }

    /// Пишет offset в коллекцию; трансляцию в слой делает колбэк сетки
    /// `onScrollOffsetChanged` из `scrollViewDidScroll`.
    private func scroll(_ scene: Scene, toY y: CGFloat) {
        scene.collectionView.contentOffset = CGPoint(x: 0, y: y)
    }

    /// Проверяет, что обои закрывают всю страницу.
    private func assertWallpaperCoversPage(
        _ scene: Scene,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let rect = try screenRectOfWallpaper(in: scene)
        let page = scene.page.bounds
        let tolerance: CGFloat = 0.001
        XCTAssertLessThanOrEqual(rect.minX, page.minX + tolerance, "\(message): полоса слева", file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.maxX, page.maxX - tolerance, "\(message): полоса справа", file: file, line: line)
        XCTAssertLessThanOrEqual(rect.minY, page.minY + tolerance, "\(message): полоса сверху", file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.maxY, page.maxY - tolerance, "\(message): полоса снизу", file: file, line: line)
    }

    // MARK: - Направление (E10.7)

    /// Прокрутка вниз на Δ уводит обои на экране на −Δ × factor: вверх, как и
    /// плитки, но медленнее. До E10.7 обои ехали вниз — против контента.
    func testWallpaperMovesWithTilesButSlower() throws {
        let scene = try makeScene()
        let maximum = scene.maximumOffset
        XCTAssertGreaterThan(maximum, 0, "Сорок плиток обязаны давать вертикальный ход")

        scroll(scene, toY: 0)
        let before = try screenRectOfWallpaper(in: scene)

        let delta = maximum / 2
        scroll(scene, toY: delta)
        let after = try screenRectOfWallpaper(in: scene)

        XCTAssertEqual(after.minY - before.minY, -delta * factor, accuracy: 0.001)
        XCTAssertEqual(after.minX, before.minX, accuracy: 0.001, "Горизонтали у обоев нет")
        XCTAssertEqual(scene.layer.transform.ty, -delta * factor, accuracy: 0.001)
    }

    // MARK: - Покрытие страницы

    /// В начале прокрутки (offset 0) обои закрывают страницу.
    func testWallpaperCoversPageAtTop() throws {
        let scene = try makeScene()
        scroll(scene, toY: 0)
        try assertWallpaperCoversPage(scene, "offset 0")
    }

    /// В конце прокрутки (максимальный offset) обои закрывают страницу: ход
    /// обоев `maximumOffset × factor` лежит ниже вьюпорта.
    func testWallpaperCoversPageAtBottom() throws {
        let scene = try makeScene()
        scroll(scene, toY: scene.maximumOffset)
        try assertWallpaperCoversPage(scene, "максимальный offset")
    }

    /// «Резина» за обоими краями прокрутки не обнажает краёв обоев.
    func testWallpaperCoversPageOnBounceAtBothEdges() throws {
        let scene = try makeScene()
        let bounce = scene.page.bounds.height / 3

        scroll(scene, toY: -bounce)
        try assertWallpaperCoversPage(scene, "bounce над верхом")

        scroll(scene, toY: scene.maximumOffset + bounce)
        try assertWallpaperCoversPage(scene, "bounce под низом")
    }
}

#endif
