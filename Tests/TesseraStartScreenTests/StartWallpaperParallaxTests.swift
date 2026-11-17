//
//  StartWallpaperParallaxTests.swift
//  TesseraStartScreenTests
//
//  Tests of the START page wallpaper under vertical parallax.
//  Design documents: docs/STARTSCREEN-IOS-DESIGN.md §8 "Wallpaper parallax",
//  docs/CORE-IOS-DESIGN.md §2 ("Parallax: backgroundOffset = offset × factor;
//  the layer is deliberately larger than contentSize").
//
//  The wallpaper layer is a sibling of the grid scroll (it lives in the page view, not in the collection),
//  and Core projects the background offset onto the screen with a minus sign: `transform =
//  −offset × factor`. The tests check direction (the wallpaper moves up together with the
//  tiles, but slower) and coverage: the image covers the page at the start and at the
//  end of scrolling, and during the bounce past both edges.
//

#if canImport(UIKit)

import XCTest
import UIKit
import TesseraCore
@testable import TesseraStartScreen

final class StartWallpaperParallaxTests: XCTestCase {

    // MARK: - Helpers

    /// Parallax factor: the upper clamp bound (0.4...0.6), at which the wallpaper
    /// travel is maximal.
    private let factor: CGFloat = 0.6

    /// The assembled START page: screen, wallpaper layer, page view and collection.
    private struct Scene {
        let screen: TesseraStartScreenViewController
        let layer: TesseraParallaxLayer
        let page: UIView
        let collectionView: UICollectionView

        /// Maximum grid offset, computed the same way as the wallpaper layout.
        var maximumOffset: CGFloat {
            let height = page.bounds.height
            return max(0, max(screen.gridView.contentSize.height, height) - height)
        }
    }

    /// Finds the first view of the given type in the subtree.
    private func firstSubview<T: UIView>(of type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    /// A screen with a tall grid (deliberately taller than the viewport) and a wallpaper image.
    private func makeScene() throws -> Scene {
        let screen = TesseraStartScreenViewController()
        screen.wallpaperParallaxFactor = factor
        screen.wallpaperImage = UIImage()
        let tiles = (0..<40).map { TesseraTileGridItem.tile(tesseraTestTile("t\($0)")) }
        screen.reload(grid: TesseraTileGridSnapshot(items: tiles, unpinned: []))

        screen.loadViewIfNeeded()
        screen.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        screen.view.layoutIfNeeded()

        // Without a window the pager may not have laid out its pages yet, so lay them out
        // manually, as in `PagerPagesTests`.
        let pager = try XCTUnwrap(
            screen.children.compactMap { $0 as? TesseraPagerViewController }.first,
            "The screen must contain the Core pager"
        )
        pager.view.frame = screen.view.bounds
        pager.view.layoutIfNeeded()

        let layer = try XCTUnwrap(
            firstSubview(of: TesseraParallaxLayer.self, in: screen.view),
            "The START page holds the wallpaper layer"
        )
        let page = try XCTUnwrap(layer.superview, "The wallpaper layer lives in the page view")
        page.layoutIfNeeded()

        let collectionView = try XCTUnwrap(
            screen.gridView.subviews.compactMap { $0 as? UICollectionView }.first,
            "The grid holds the collection"
        )
        // The simulator's system Reduce Motion must not affect the test geometry.
        layer.respectsReduceMotion = false

        return Scene(screen: screen, layer: layer, page: page, collectionView: collectionView)
    }

    /// The wallpaper image inside the layer.
    private func wallpaperView(in scene: Scene) throws -> UIImageView {
        try XCTUnwrap(
            scene.layer.subviews.compactMap { $0 as? UIImageView }.first,
            "The wallpaper is an image inside the parallax layer"
        )
    }

    /// The wallpaper rectangle in page coordinates, taking the layer's `transform` into account.
    private func screenRectOfWallpaper(in scene: Scene) throws -> CGRect {
        let imageView = try wallpaperView(in: scene)
        return imageView.convert(imageView.bounds, to: scene.page)
    }

    /// Writes the offset into the collection; translating it into the layer is done by the grid's
    /// `onScrollOffsetChanged` callback from `scrollViewDidScroll`.
    private func scroll(_ scene: Scene, toY y: CGFloat) {
        scene.collectionView.contentOffset = CGPoint(x: 0, y: y)
    }

    /// Checks that the wallpaper covers the whole page.
    private func assertWallpaperCoversPage(
        _ scene: Scene,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let rect = try screenRectOfWallpaper(in: scene)
        let page = scene.page.bounds
        let tolerance: CGFloat = 0.001
        XCTAssertLessThanOrEqual(rect.minX, page.minX + tolerance, "\(message): strip on the left", file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.maxX, page.maxX - tolerance, "\(message): strip on the right", file: file, line: line)
        XCTAssertLessThanOrEqual(rect.minY, page.minY + tolerance, "\(message): strip at the top", file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.maxY, page.maxY - tolerance, "\(message): strip at the bottom", file: file, line: line)
    }

    // MARK: - Direction

    /// Scrolling down by Δ moves the wallpaper on screen by −Δ × factor: up, like the
    /// tiles, but slower. Previously the wallpaper moved down, against the content.
    func testWallpaperMovesWithTilesButSlower() throws {
        let scene = try makeScene()
        let maximum = scene.maximumOffset
        XCTAssertGreaterThan(maximum, 0, "Forty tiles must produce vertical travel")

        scroll(scene, toY: 0)
        let before = try screenRectOfWallpaper(in: scene)

        let delta = maximum / 2
        scroll(scene, toY: delta)
        let after = try screenRectOfWallpaper(in: scene)

        XCTAssertEqual(after.minY - before.minY, -delta * factor, accuracy: 0.001)
        XCTAssertEqual(after.minX, before.minX, accuracy: 0.001, "The wallpaper has no horizontal movement")
        XCTAssertEqual(scene.layer.transform.ty, -delta * factor, accuracy: 0.001)
    }

    // MARK: - Page coverage

    /// At the start of scrolling (offset 0) the wallpaper covers the page.
    func testWallpaperCoversPageAtTop() throws {
        let scene = try makeScene()
        scroll(scene, toY: 0)
        try assertWallpaperCoversPage(scene, "offset 0")
    }

    /// At the end of scrolling (maximum offset) the wallpaper covers the page: the wallpaper
    /// travel `maximumOffset × factor` lies below the viewport.
    func testWallpaperCoversPageAtBottom() throws {
        let scene = try makeScene()
        scroll(scene, toY: scene.maximumOffset)
        try assertWallpaperCoversPage(scene, "maximum offset")
    }

    /// The bounce past both scroll edges does not expose the wallpaper's edges.
    func testWallpaperCoversPageOnBounceAtBothEdges() throws {
        let scene = try makeScene()
        let bounce = scene.page.bounds.height / 3

        scroll(scene, toY: -bounce)
        try assertWallpaperCoversPage(scene, "bounce above the top")

        scroll(scene, toY: scene.maximumOffset + bounce)
        try assertWallpaperCoversPage(scene, "bounce below the bottom")
    }
}

#endif
