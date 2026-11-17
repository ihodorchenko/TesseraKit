//
//  LiveTileLayoutAndImageTests.swift
//  TesseraStartScreenTests
//
//  Tests for the live tile container.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §4 "Live tiles
//  (engine)": a flip uses only transforms, and a layout in the middle of a flip must not
//  break the geometry of the sides; "images are decoded to the tile size and
//  cached".
//
//  The tests do not bring up a window and do not wait for animations: the flip starts with a long
//  duration, and the model state of the layers is checked in its middle.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class LiveTileLayoutAndImageTests: XCTestCase {

    // MARK: - Helpers

    /// Tile sides in the order they were added: front, then back.
    private func faceViews(of tile: TesseraLiveTileView) -> [TesseraLiveTileFaceView] {
        tile.subviews.compactMap { $0 as? TesseraLiveTileFaceView }
    }

    /// A side's icon is the only `UIImageView` among its subviews.
    private func iconView(of face: TesseraLiveTileFaceView) -> UIImageView? {
        face.subviews.compactMap { $0 as? UIImageView }.first
    }

    /// A large raster icon, like an app's "raw" image.
    private func makeLargeIcon(side: CGFloat = 1024) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    /// The screen scale that a tile side uses.
    private func displayScale(of view: UIView) -> CGFloat {
        let scale = view.traitCollection.displayScale
        return scale > 0 ? scale : UIScreen.main.scale
    }

    // MARK: - Layout in the middle of a flip

    /// During a flip the outgoing side has a non-identity 3D `transform`; `frame`
    /// is undefined under such a transform. The tile's layout (for example, when the cell
    /// size changes in the middle of a flip) must set `bounds` + `center`, not
    /// `frame`, otherwise the side gets degenerate `bounds`.
    func testLayoutDuringFlipKeepsFaceBoundsAndCenter() {
        let tile = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        tile.setFaces(front: TesseraLiveTileFace(title: "Front"), back: TesseraLiveTileFace(title: "Back"))
        tile.layoutIfNeeded()

        tile.flipAnimationDuration = 3
        tile.show(.back, animated: true)
        XCTAssertTrue(tile.isFlipping)

        let faces = faceViews(of: tile)
        XCTAssertEqual(faces.count, 2)
        guard let front = faces.first else { return }
        XCTAssertFalse(
            CATransform3DIsIdentity(front.layer.transform),
            "In the middle of a flip the outgoing side must have a rotation"
        )
        let flipTransform = front.layer.transform

        // The cell changed size in the middle of a flip.
        tile.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        tile.setNeedsLayout()
        tile.layoutIfNeeded()

        for face in faces {
            XCTAssertEqual(face.bounds.origin, .zero)
            XCTAssertEqual(face.bounds.size.width, 200, accuracy: 0.001)
            XCTAssertEqual(face.bounds.size.height, 120, accuracy: 0.001)
            XCTAssertEqual(face.center.x, 100, accuracy: 0.001)
            XCTAssertEqual(face.center.y, 60, accuracy: 0.001)
        }
        // Layout does not touch the transform: the flip continues from the same phase.
        XCTAssertTrue(CATransform3DEqualToTransform(front.layer.transform, flipTransform))
    }

    /// A repeated layout of the same size in the middle of a flip does not distort the sides.
    func testRepeatedLayoutDuringFlipIsStable() {
        let tile = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 150, height: 150))
        tile.setFaces(front: TesseraLiveTileFace(title: "Front"), back: TesseraLiveTileFace(title: "Back"))
        tile.layoutIfNeeded()

        tile.flipAnimationDuration = 3
        tile.show(.back, animated: true)

        for _ in 0..<3 {
            tile.setNeedsLayout()
            tile.layoutIfNeeded()
        }

        for face in faceViews(of: tile) {
            XCTAssertEqual(face.bounds, CGRect(x: 0, y: 0, width: 150, height: 150))
            XCTAssertEqual(face.center, CGPoint(x: 75, y: 75))
        }
    }

    // MARK: - Icon downsampling

    /// §4: a side's image is decoded to the tile size × scale rather than
    /// shown "as is" (1024×1024 pixels on a 200 pt tile).
    func testFaceIconIsDownsampledToTileSize() {
        let tile = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        tile.setFaces(front: TesseraLiveTileFace(title: "Mail", icon: makeLargeIcon()), back: nil)
        tile.layoutIfNeeded()

        guard let front = faceViews(of: tile).first else {
            return XCTFail("No tile side")
        }
        front.layoutIfNeeded()

        guard let image = iconView(of: front)?.image else {
            return XCTFail("The side's icon is not shown")
        }
        let scale = displayScale(of: front)
        XCTAssertLessThanOrEqual(image.size.width * image.scale, 200 * scale + 0.5)
        XCTAssertLessThanOrEqual(image.size.height * image.scale, 200 * scale + 0.5)
        XCTAssertLessThan(image.size.width * image.scale, 1024)
        // The glyph is still tinted with the side's color.
        XCTAssertEqual(image.renderingMode, .alwaysTemplate)
    }

    /// Two tiles with the same icon of the same size get the same
    /// downsampled object from the shared cache.
    func testSameIconOnTwoTilesComesFromCache() {
        let icon = makeLargeIcon()
        let first = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let second = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        for tile in [first, second] {
            tile.setFaces(front: TesseraLiveTileFace(title: "Mail", icon: icon), back: nil)
            tile.layoutIfNeeded()
            faceViews(of: tile).first?.layoutIfNeeded()
        }

        let firstImage = faceViews(of: first).first.flatMap { iconView(of: $0)?.image }
        let secondImage = faceViews(of: second).first.flatMap { iconView(of: $0)?.image }
        XCTAssertNotNil(firstImage)
        XCTAssertTrue(firstImage === secondImage, "A repeated request must come from the cache")
    }

    /// Cache: the result size is ≤ the requested size × scale, proportions are preserved,
    /// a repeated request does not redraw, and a different size renders anew.
    func testImageCacheDownsamplesAndReuses() {
        let cache = TesseraLiveTileImageCache()
        let icon = makeLargeIcon()
        let box = CGSize(width: 28, height: 28)

        let first = cache.image(for: icon, fitting: box, scale: 3, renderingMode: .alwaysTemplate)
        XCTAssertLessThanOrEqual(first.size.width * first.scale, 84 + 0.5)
        XCTAssertLessThanOrEqual(first.size.height * first.scale, 84 + 0.5)
        XCTAssertEqual(first.renderingMode, .alwaysTemplate)
        XCTAssertEqual(cache.renderCount, 1)

        let second = cache.image(for: icon, fitting: box, scale: 3, renderingMode: .alwaysTemplate)
        XCTAssertTrue(first === second)
        XCTAssertEqual(cache.renderCount, 1, "A repeated request must not redraw")

        _ = cache.image(for: icon, fitting: CGSize(width: 18, height: 18), scale: 3, renderingMode: .alwaysTemplate)
        XCTAssertEqual(cache.renderCount, 2)
    }

    /// A non-square icon is fitted with its proportions preserved.
    func testImageCacheKeepsAspectRatio() {
        let cache = TesseraLiveTileImageCache()
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400), format: format).image { _ in }

        let result = cache.image(for: wide, fitting: CGSize(width: 28, height: 28), scale: 2, renderingMode: .automatic)
        XCTAssertEqual(result.size.width * result.scale, 56, accuracy: 1)
        XCTAssertEqual(result.size.height * result.scale, 28, accuracy: 1)
    }

    /// A small icon (already at the right size) is not redrawn.
    func testImageCacheDoesNotRedrawSmallIcon() {
        let cache = TesseraLiveTileImageCache()
        let small = makeLargeIcon(side: 20)

        let result = cache.image(for: small, fitting: CGSize(width: 28, height: 28), scale: 3, renderingMode: .alwaysTemplate)
        XCTAssertEqual(cache.renderCount, 0)
        XCTAssertEqual(result.size, small.size)
        XCTAssertEqual(result.renderingMode, .alwaysTemplate)
    }
}

#endif
