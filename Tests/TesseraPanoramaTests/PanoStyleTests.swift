//
//  PanoStyleTests.swift
//  TesseraPanoramaTests
//
//  Contract tests for the panorama configuration.
//  Design document: docs/PANORAMA-IOS-DESIGN.md §3 (conceptual
//  architecture: `TesseraPanoramaStyle`: section width with peek, parallax multiplier,
//  header fonts/colors, background behavior) and §4 (geometry and core math
//  (peek 16…64 pt; `0 < parallaxFactor < 1`, typically 0.4–0.6).
//
//  Checked: system defaults, clamps of `peek` and `parallaxFactor` in the
//  initializer and on every write, protection against `NaN`/infinities, and
//  preservation of custom values that stay within the range.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraPanorama

final class PanoStyleTests: XCTestCase {

    // MARK: - Defaults

    /// Default values: peek 48 pt, parallax 0.5, system bold 34 pt,
    /// `.label`/`.systemBlue`, background `.none` (§3, §4).
    func testDefaults() {
        let style = TesseraPanoramaStyle()

        XCTAssertEqual(style.peek, 48, accuracy: 0.000_001)
        XCTAssertEqual(style.parallaxFactor, 0.5, accuracy: 0.000_001)

        XCTAssertEqual(style.headerFont.pointSize, 34, accuracy: 0.000_001)
        XCTAssertTrue(
            style.headerFont.fontDescriptor.symbolicTraits.contains(.traitBold),
            "the default header is system bold 34 pt (§3)"
        )

        XCTAssertEqual(style.headerColor, .label)
        XCTAssertEqual(style.headerActiveColor, .systemBlue)
        XCTAssertEqual(
            style.contentInsetAdjustmentBehavior,
            .never,
            "§8: the section strip frame is set by the panorama; no adjustment by default"
        )

        if case .none = style.backgroundBehavior {
            // The expected default: no background is drawn until an image is set (§9).
        } else {
            XCTFail("the background behavior must be .none by default")
        }
    }

    // MARK: - Clamp of peek (16...64), §4

    /// `peek` is clamped to `16...64` already in the initializer: property observers
    /// are not called on the first write, so without a clamp in init the range
    /// invariant would be violated.
    func testPeekClampsAtInitialization() {
        let cases: [(input: CGFloat, expected: CGFloat)] = [
            (-100, 16),
            (0, 16),
            (15.99, 16),
            (16, 16),
            (40, 40),
            (64, 64),
            (64.01, 64),
            (100, 64),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraPanoramaStyle(peek: entry.input).peek,
                entry.expected,
                accuracy: 0.000_001,
                "peek \(entry.input) must be clamped to 16...64"
            )
        }
    }

    /// Non-numeric `peek` values are treated as the default 48, not as an edge
    /// of the range: `NaN` must not "stick" to 16 or 64.
    func testPeekFallsBackToDefaultForNonFiniteValues() {
        for value: CGFloat in [.nan, .infinity, -.infinity] {
            XCTAssertEqual(
                TesseraPanoramaStyle(peek: value).peek,
                48,
                accuracy: 0.000_001,
                "non-numeric peek \(value) falls back to the default 48"
            )
        }
    }

    /// A write to an existing style is clamped the same way as initialization: from outside
    /// it is impossible to push `peek` out of the range.
    func testPeekClampsOnAssignment() {
        var style = TesseraPanoramaStyle()

        style.peek = 100
        XCTAssertEqual(style.peek, 64, accuracy: 0.000_001)

        style.peek = 1
        XCTAssertEqual(style.peek, 16, accuracy: 0.000_001)

        style.peek = 32
        XCTAssertEqual(style.peek, 32, accuracy: 0.000_001)

        style.peek = .nan
        XCTAssertEqual(style.peek, 48, accuracy: 0.000_001)

        style.peek = .infinity
        XCTAssertEqual(style.peek, 48, accuracy: 0.000_001)
    }

    // MARK: - Clamp of parallaxFactor to (0, 1), §4

    /// §4: `0 < parallaxFactor < 1`, typically 0.4–0.6. Values inside the open
    /// interval are preserved as is (the typical range is not a bound), while
    /// the bounds `0`/`1` and everything beyond them are clamped inward: `0.01...0.99`. A zero
    /// factor is unreachable through the style: disabling parallax is the prerogative of
    /// Reduce Motion (§7).
    func testParallaxFactorClampsAtInitialization() {
        let cases: [(input: CGFloat, expected: CGFloat)] = [
            (-1, 0.01),
            (0, 0.01),
            (0.01, 0.01),
            (0.2, 0.2),
            (0.39, 0.39),
            (0.4, 0.4),
            (0.5, 0.5),
            (0.6, 0.6),
            (0.61, 0.61),
            (0.8, 0.8),
            (0.99, 0.99),
            (1, 0.99),
            (3, 0.99),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraPanoramaStyle(parallaxFactor: entry.input).parallaxFactor,
                entry.expected,
                accuracy: 0.000_001,
                "parallaxFactor \(entry.input) must lie in (0, 1) per §4"
            )
        }
    }

    /// The clamp result is always strictly inside `(0, 1)`, exactly the §4 condition.
    func testParallaxFactorStaysInsideOpenUnitInterval() {
        for value: CGFloat in [-.greatestFiniteMagnitude, -1, 0, 1e-9, 0.5, 1 - 1e-9, 1, 2, .greatestFiniteMagnitude] {
            let factor = TesseraPanoramaStyle(parallaxFactor: value).parallaxFactor
            XCTAssertGreaterThan(factor, 0, "parallaxFactor \(value) → \(factor)")
            XCTAssertLessThan(factor, 1, "parallaxFactor \(value) → \(factor)")
        }
    }

    /// Non-numeric `parallaxFactor` values are treated as the default 0.5.
    func testParallaxFactorFallsBackToDefaultForNonFiniteValues() {
        for value: CGFloat in [.nan, .infinity, -.infinity] {
            XCTAssertEqual(
                TesseraPanoramaStyle(parallaxFactor: value).parallaxFactor,
                0.5,
                accuracy: 0.000_001,
                "non-numeric parallaxFactor \(value) falls back to the default 0.5"
            )
        }
    }

    /// A write to an existing style is clamped the same way as initialization.
    func testParallaxFactorClampsOnAssignment() {
        var style = TesseraPanoramaStyle()

        style.parallaxFactor = 0
        XCTAssertEqual(style.parallaxFactor, 0.01, accuracy: 0.000_001)

        style.parallaxFactor = 0.7
        XCTAssertEqual(style.parallaxFactor, 0.7, accuracy: 0.000_001)

        style.parallaxFactor = 1.5
        XCTAssertEqual(style.parallaxFactor, 0.99, accuracy: 0.000_001)

        style.parallaxFactor = 0.45
        XCTAssertEqual(style.parallaxFactor, 0.45, accuracy: 0.000_001)

        style.parallaxFactor = .nan
        XCTAssertEqual(style.parallaxFactor, 0.5, accuracy: 0.000_001)
    }

    // MARK: - Custom values and derived geometry

    /// Values within the ranges are preserved as is, and the style's other fields
    /// (font, colors, background) are not overridden by the clamp (§3).
    func testCustomValuesArePreserved() {
        let font = UIFont.systemFont(ofSize: 28, weight: .semibold)
        let style = TesseraPanoramaStyle(
            peek: 20,
            parallaxFactor: 0.45,
            headerFont: font,
            headerColor: .darkGray,
            headerActiveColor: .systemRed,
            backgroundBehavior: .image(nil)
        )

        XCTAssertEqual(style.peek, 20, accuracy: 0.000_001)
        XCTAssertEqual(style.parallaxFactor, 0.45, accuracy: 0.000_001)
        XCTAssertEqual(style.headerFont.pointSize, 28, accuracy: 0.000_001)
        XCTAssertEqual(style.headerColor, .darkGray)
        XCTAssertEqual(style.headerActiveColor, .systemRed)

        if case .image(let image) = style.backgroundBehavior {
            XCTAssertNil(image, "a nil image is valid: the layer stays empty (§3)")
        } else {
            XCTFail("the .image background behavior must be preserved in the style")
        }
    }

    /// The peek clamp preserves the §4 invariant: `itemWidth = width − peek` stays
    /// positive even at the compact iPhone SE width (320 pt).
    func testClampedPeekKeepsItemWidthPositive() {
        for width: CGFloat in [320, 375, 390, 430, 768] {
            for peek: CGFloat in [16, 40, 48, 64] {
                let style = TesseraPanoramaStyle(peek: peek)
                let itemWidth = width - style.peek

                XCTAssertGreaterThan(
                    itemWidth,
                    0,
                    "width \(width) and peek \(style.peek): itemWidth must be > 0"
                )
            }
        }
    }
}

#endif
