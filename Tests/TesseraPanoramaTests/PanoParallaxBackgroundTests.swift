//
//  PanoParallaxBackgroundTests.swift
//  TesseraPanoramaTests
//
//  Tests for the panorama background under parallax.
//  Design documents: docs/PANORAMA-IOS-DESIGN.md §3 (background parallax),
//  docs/CORE-IOS-DESIGN.md §2 ("Parallax: backgroundOffset = offset × factor;
//  the layer is deliberately larger than contentSize").
//
//  The background layer is a sibling of the scroll view (it lives in `view`, not in `TesseraPanoScrollView`), and Core
//  projects the background shift onto the screen with a minus sign: `transform = −offset ×
//  factor`. Checked: the direction (the background moves the same way as the sections, but
//  slower) and the coverage: the image covers the whole screen at the start and at the end
//  of the strip, and also on the rubber band past both edges.
//

#if canImport(UIKit)

import XCTest
import UIKit
import TesseraCore
@testable import TesseraPanorama

final class PanoParallaxBackgroundTests: XCTestCase {

    // MARK: - Helpers

    /// The panorama screen size.
    private let screenSize = CGSize(width: 390, height: 700)

    /// The parallax multiplier: the upper bound of the typical §4 range (0.4–0.6).
    private let factor: CGFloat = 0.6

    /// A loaded and laid-out panorama of four sections with a background image.
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
        // The simulator's system Reduce Motion must not affect the test geometry.
        panorama.parallaxLayer.respectsReduceMotion = false
        return panorama
    }

    /// The background image inside the layer.
    private func backgroundImageView(
        of panorama: TesseraPanoramaViewController
    ) throws -> UIImageView {
        try XCTUnwrap(
            panorama.parallaxLayer.subviews.compactMap { $0 as? UIImageView }.first,
            "The panorama background is an image inside the parallax layer"
        )
    }

    /// The on-screen (in `view` coordinates) rectangle of the background image, accounting for
    /// the layer's `transform`.
    private func screenRectOfBackground(
        in panorama: TesseraPanoramaViewController
    ) throws -> CGRect {
        let imageView = try backgroundImageView(of: panorama)
        return imageView.convert(imageView.bounds, to: panorama.view)
    }

    /// Writes the offset to the panorama's scroll view; the panorama itself forwards it to the layer
    /// from `scrollViewDidScroll`.
    private func scroll(_ panorama: TesseraPanoramaViewController, toX x: CGFloat) {
        panorama.scrollView.contentOffset = CGPoint(x: x, y: 0)
    }

    /// Checks that the background image covers the whole screen.
    private func assertBackgroundCoversScreen(
        _ panorama: TesseraPanoramaViewController,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let rect = try screenRectOfBackground(in: panorama)
        let screen = panorama.view.bounds
        let tolerance: CGFloat = 0.001
        XCTAssertLessThanOrEqual(rect.minX, screen.minX + tolerance, "\(message): gap on the left", file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.maxX, screen.maxX - tolerance, "\(message): gap on the right", file: file, line: line)
        XCTAssertLessThanOrEqual(rect.minY, screen.minY + tolerance, "\(message): gap at the top", file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.maxY, screen.maxY - tolerance, "\(message): gap at the bottom", file: file, line: line)
    }

    // MARK: - Direction

    /// An offset increase of Δ moves the background on screen by −Δ × factor: the same way
    /// as the sections, but slower. Previously the background moved right, against the content.
    func testBackgroundMovesWithSectionsButSlower() throws {
        let panorama = makePanorama()
        let maximum = panorama.scrollView.maximumOffsetX
        XCTAssertGreaterThan(maximum, 0, "Four sections must give the strip some travel")

        scroll(panorama, toX: 0)
        let before = try screenRectOfBackground(in: panorama)

        let delta = maximum / 2
        scroll(panorama, toX: delta)
        let after = try screenRectOfBackground(in: panorama)

        XCTAssertEqual(after.minX - before.minX, -delta * factor, accuracy: 0.001)
        XCTAssertEqual(after.minY, before.minY, accuracy: 0.001, "The panorama has no vertical axis")
        XCTAssertEqual(panorama.parallaxLayer.transform.tx, -delta * factor, accuracy: 0.001)
    }

    // MARK: - Screen coverage

    /// At the start of the strip (offset 0) the background covers the screen.
    func testBackgroundCoversScreenAtStart() throws {
        let panorama = makePanorama()
        scroll(panorama, toX: 0)
        try assertBackgroundCoversScreen(panorama, "offset 0")
    }

    /// At the end of the strip (maximum offset) the background covers the screen: the background's travel
    /// `maximumOffsetX × factor` lies to the right of the viewport.
    func testBackgroundCoversScreenAtEnd() throws {
        let panorama = makePanorama()
        scroll(panorama, toX: panorama.scrollView.maximumOffsetX)
        try assertBackgroundCoversScreen(panorama, "maximum offset")
    }

    /// The rubber band past both edges of the strip does not expose the background's edges.
    func testBackgroundCoversScreenOnBounceAtBothEdges() throws {
        let panorama = makePanorama()
        let bounce = screenSize.width / 2

        scroll(panorama, toX: -bounce)
        try assertBackgroundCoversScreen(panorama, "bounce before the start of the strip")

        scroll(panorama, toX: panorama.scrollView.maximumOffsetX + bounce)
        try assertBackgroundCoversScreen(panorama, "bounce past the end of the strip")
    }

    /// Coverage holds over the whole allowed factor range (a clamp to
    /// `(0, 1)` instead of `0.4…0.6`), including the extreme 0.01 and 0.99, and also on
    /// a half-screen rubber band past both edges.
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
