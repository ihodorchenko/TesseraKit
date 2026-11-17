//
//  PanoHeaderTests.swift
//  TesseraPanoramaTests
//
//  Contract tests for the panorama header math.
//  Design document: docs/PANORAMA-IOS-DESIGN.md §4 (geometry and core math:
//  "Headers: piecewise-linear interpolation between the keyframes
//  0, 0.5, 1") and §7 (accessibility and system integration: Reduce Motion —
//  header parallax and animations are disabled, leaving a static state).
//
//  Checked: the pure `keyframeAlpha`/`keyframeOffset` (keyframes,
//  linearity between them, monotonicity, symmetry, clamping outside the range,
//  defensive `NaN`/infinities) and the header layer's behavior with an injectable
//  Reduce Motion provider (headers are static, only the active one is visible).
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraPanorama

final class PanoHeaderTests: XCTestCase {

    /// The header layer width for `transform` checks (§4: `travel = width × 0.3`).
    private let width: CGFloat = 390

    /// The full shift range when `travelRatio == 0.3` (the layer style's default).
    private var travel: CGFloat { width * 0.3 }

    // MARK: - Helpers

    private func alpha(_ phase: CGFloat) -> CGFloat {
        TesseraPanoHeaderView.keyframeAlpha(progress: phase)
    }

    private func offset(_ phase: CGFloat, travel: CGFloat = 100) -> CGFloat {
        TesseraPanoHeaderView.keyframeOffset(progress: phase, travel: travel)
    }

    /// A header layer with forced LTR: the sign of the shift does not depend on
    /// the test simulator's system language (§7, RTL).
    ///
    /// Reduce Motion is explicitly off by default: animated contracts must not
    /// depend on the system setting of the machine running the tests.
    private func makeHeader(
        titles: [String] = ["One", "Two", "Three"]
    ) -> TesseraPanoHeaderView {
        let header = TesseraPanoHeaderView(titles: titles)
        header.semanticContentAttribute = .forceLeftToRight
        header.isReduceMotionEnabled = { false }
        header.frame = CGRect(x: 0, y: 0, width: width, height: 120)
        header.layoutIfNeeded()
        return header
    }

    /// Labels in reading order: `rebuildLabels()` adds them in the order of titles.
    private func headerLabels(in header: TesseraPanoHeaderView) -> [UILabel] {
        header.subviews.compactMap { $0 as? UILabel }
    }

    // MARK: - keyframeAlpha: keyframes (§4)

    /// The alpha keyframes: `0 → 0`, `0.5 → 1`, `1 → 0`.
    func testAlphaKeyframes() {
        XCTAssertEqual(alpha(0), 0)
        XCTAssertEqual(alpha(0.5), 1)
        XCTAssertEqual(alpha(1), 0)
    }

    /// Between keyframes alpha is linear: `2x` up to the center and `2 − 2x` after it.
    func testAlphaIsLinearBetweenKeyframes() {
        let cases: [(phase: CGFloat, expected: CGFloat)] = [
            (0.1, 0.2),
            (0.25, 0.5),
            (0.4, 0.8),
            (0.5, 1),
            (0.6, 0.8),
            (0.75, 0.5),
            (0.9, 0.2),
        ]

        for entry in cases {
            XCTAssertEqual(
                alpha(entry.phase),
                entry.expected,
                accuracy: 0.000_001,
                "alpha at phase \(entry.phase)"
            )
        }
    }

    /// Alpha rises monotonically up to the center and falls monotonically after it: the header does not
    /// "flicker" on a transition (§4).
    func testAlphaIsMonotonicAroundCenter() {
        var previous = alpha(0)

        for step in 1...100 {
            let phase = CGFloat(step) / 100
            let value = alpha(phase)

            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)

            if phase <= 0.5 {
                XCTAssertGreaterThanOrEqual(
                    value,
                    previous - 0.000_001,
                    "alpha must rise at phase \(phase)"
                )
            } else {
                XCTAssertLessThanOrEqual(
                    value,
                    previous + 0.000_001,
                    "alpha must fall at phase \(phase)"
                )
            }
            previous = value
        }
    }

    /// Outside `0...1` the phase is clamped: alpha stays 0, including bounce,
    /// `NaN`, and infinities.
    func testAlphaClampsOutsideKeyframeRange() {
        for phase: CGFloat in [-1, -0.001, 1.001, 2, 100] {
            XCTAssertEqual(alpha(phase), 0, accuracy: 0.000_001, "phase \(phase)")
        }

        XCTAssertEqual(alpha(.nan), 0)
        XCTAssertEqual(alpha(.infinity), 0)
        XCTAssertEqual(alpha(-.infinity), 0)
    }

    /// Alpha is symmetric about the middle: adjacent sections fade in
    /// the same way before and after the center (§4).
    func testAlphaIsSymmetricAroundCenter() {
        for delta: CGFloat in [0, 0.1, 0.25, 0.4, 0.5] {
            XCTAssertEqual(
                alpha(0.5 - delta),
                alpha(0.5 + delta),
                accuracy: 0.000_001,
                "alpha symmetry at deviation \(delta)"
            )
        }
    }

    // MARK: - keyframeOffset: keyframes (§4)

    /// The shift keyframes: `0 → −travel/2`, `0.5 → 0`, `1 → +travel/2`.
    func testOffsetKeyframes() {
        XCTAssertEqual(offset(0, travel: 100), -50)
        XCTAssertEqual(offset(0.5, travel: 100), 0)
        XCTAssertEqual(offset(1, travel: 100), 50)
    }

    /// The shift is linearly interpolated: `offset = (x − 0.5) × travel`.
    func testOffsetIsLinearBetweenKeyframes() {
        XCTAssertEqual(offset(0.25, travel: 100), -25, accuracy: 0.000_001)
        XCTAssertEqual(offset(0.4, travel: 100), -10, accuracy: 0.000_001)
        XCTAssertEqual(offset(0.6, travel: 100), 10, accuracy: 0.000_001)
        XCTAssertEqual(offset(0.75, travel: 100), 25, accuracy: 0.000_001)
    }

    /// Outside the keyframes the phase is clamped, and the shift does not go beyond
    /// `±travel/2`; `NaN` gives a zero shift (the method's defensive contract).
    func testOffsetClampsOutsideKeyframeRange() {
        XCTAssertEqual(offset(-1, travel: 100), -50)
        XCTAssertEqual(offset(2, travel: 100), 50)
        XCTAssertEqual(offset(-.infinity, travel: 100), -50)
        XCTAssertEqual(offset(.infinity, travel: 100), 50)
        XCTAssertEqual(offset(.nan, travel: 100), 0)
    }

    /// The shift is antisymmetric about the center: the outgoing and incoming labels
    /// deviate in opposite directions by equal amounts (§4).
    func testOffsetIsAntisymmetricAroundCenter() {
        for delta: CGFloat in [0, 0.1, 0.25, 0.4, 0.5] {
            XCTAssertEqual(
                offset(0.5 - delta, travel: 100),
                -offset(0.5 + delta, travel: 100),
                accuracy: 0.000_001,
                "shift antisymmetry at deviation \(delta)"
            )
        }
    }

    /// The caller sets the sign of the amplitude: a negative `travel` flips the sign
    /// of the shift, and a zero one zeroes it (§4, RTL).
    func testOffsetRespectsTravelSignAndZero() {
        XCTAssertEqual(offset(0.75, travel: -100), -25, accuracy: 0.000_001)
        XCTAssertEqual(offset(0.25, travel: -100), 25, accuracy: 0.000_001)

        for phase: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            XCTAssertEqual(offset(phase, travel: 0), 0, accuracy: 0.000_001)
        }
    }

    // MARK: - Applying progress to labels (§4)

    /// At `t = 0.5` both adjacent labels are visible with alpha 0.5 and the third is hidden;
    /// the neighbors' shifts have opposite signs (`travel = 390 × 0.3 = 117`).
    func testApplyProgressFadesNeighbourHeaders() {
        let header = makeHeader()
        header.apply(progress: 0.5, activeIndex: 0)

        let labels = headerLabels(in: header)
        XCTAssertEqual(labels.count, 3)

        XCTAssertEqual(labels[0].alpha, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(labels[1].alpha, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(labels[2].alpha, 0, accuracy: 0.000_001)

        XCTAssertEqual(labels[0].transform.tx, -travel / 4, accuracy: 0.000_001)
        XCTAssertEqual(labels[1].transform.tx, travel / 4, accuracy: 0.000_001)
    }

    /// At whole `t` exactly one label is visible: the active one stands without a shift, and its neighbors
    /// are fully transparent. These are the 0.5/0/1 keyframes through `apply`.
    func testApplyProgressAtIntegerShowsSingleActiveHeader() {
        let header = makeHeader()

        header.apply(progress: 1, activeIndex: 1)
        var labels = headerLabels(in: header)
        XCTAssertEqual(labels.map(\.alpha), [0, 1, 0])
        XCTAssertEqual(labels[1].transform, .identity)
        XCTAssertEqual(header.accessibilityLabel, "Two")

        header.apply(progress: 2, activeIndex: 2)
        labels = headerLabels(in: header)
        XCTAssertEqual(labels.map(\.alpha), [0, 0, 1])
        XCTAssertEqual(header.accessibilityLabel, "Three")
    }

    /// Progress beyond the strip's bounds (bounce) is clamped: the edge header does not
    /// "fade out" on the elastic rebound (§4).
    func testApplyProgressClampsOutOfRangeValues() {
        let header = makeHeader()

        header.apply(progress: 10, activeIndex: 2)
        XCTAssertEqual(headerLabels(in: header).map(\.alpha), [0, 0, 1])

        header.apply(progress: -5, activeIndex: 0)
        XCTAssertEqual(headerLabels(in: header).map(\.alpha), [1, 0, 0])
    }

    // MARK: - Reduce Motion (§7)

    /// With Reduce Motion on, headers are static: only the active one is visible,
    /// with no shift or fades, regardless of fractional progress.
    func testReduceMotionShowsOnlyActiveHeader() {
        let header = makeHeader()
        header.isReduceMotionEnabled = { true }

        header.apply(progress: 1.5, activeIndex: 1)

        let labels = headerLabels(in: header)
        XCTAssertEqual(labels.map(\.alpha), [0, 1, 0])

        for label in labels {
            XCTAssertEqual(
                label.transform,
                .identity,
                "headers must not shift under Reduce Motion"
            )
        }
        XCTAssertEqual(header.accessibilityLabel, "Two")
    }

    /// The provider is read on every `apply`: toggling Reduce Motion
    /// on the fly switches between the static and animated states (§7).
    func testReduceMotionProviderIsReadOnEachApply() {
        let header = makeHeader()
        var reduceMotion = true
        header.isReduceMotionEnabled = { reduceMotion }

        header.apply(progress: 0.5, activeIndex: 0)
        XCTAssertEqual(headerLabels(in: header).map(\.alpha), [1, 0, 0])
        XCTAssertTrue(headerLabels(in: header).allSatisfy { $0.transform == .identity })

        reduceMotion = false
        header.apply(progress: 0.5, activeIndex: 0)
        var labels = headerLabels(in: header)
        XCTAssertEqual(labels[0].alpha, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(labels[1].alpha, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(labels[2].alpha, 0, accuracy: 0.000_001)
        XCTAssertEqual(labels[0].transform.tx, -travel / 4, accuracy: 0.000_001)
        XCTAssertEqual(labels[1].transform.tx, travel / 4, accuracy: 0.000_001)

        reduceMotion = true
        header.apply(progress: 0.5, activeIndex: 0)
        labels = headerLabels(in: header)
        XCTAssertEqual(labels.map(\.alpha), [1, 0, 0])
        XCTAssertTrue(labels.allSatisfy { $0.transform == .identity })
    }

    // MARK: - Active header color

    /// The accent copy of a label: the only `UILabel` inside the header label.
    private func accentLabel(of label: UILabel) -> UILabel? {
        label.subviews.compactMap { $0 as? UILabel }.first
    }

    /// The accent weight is the section's "activity" `max(0, 1 − |i − t|)`: it matches
    /// the phase's alpha and changes linearly between whole `t` values.
    func testActiveColorWeightInterpolatesByProgress() {
        let cases: [(index: Int, t: CGFloat, weight: CGFloat)] = [
            (0, 0, 1), (1, 0, 0), (1, 1, 1),
            (0, 0.25, 0.75), (1, 0.25, 0.25),
            (0, 0.5, 0.5), (1, 0.5, 0.5),
            (2, 0.5, 0), (0, 1, 0),
        ]
        for entry in cases {
            XCTAssertEqual(
                TesseraPanoHeaderView.activeColorWeight(index: entry.index, progress: entry.t),
                entry.weight,
                accuracy: 0.000_001,
                "section \(entry.index), t = \(entry.t)"
            )
        }
    }

    /// `activeTextColor` is set: every label has an accent copy of this color
    /// with the same text, its alpha is the accent weight by `t`, and the main label
    /// stays `textColor`. At whole `t` the active header is entirely
    /// in the accent; at the midpoint of a transition, half and half for both neighbors.
    func testActiveColorIsAppliedAndInterpolatedByProgress() throws {
        let header = makeHeader()
        header.style = TesseraPanoHeaderView.Style(textColor: .white, activeTextColor: .systemYellow)
        header.layoutIfNeeded()

        let labels = headerLabels(in: header)
        XCTAssertEqual(labels.count, 3, "accent copies must not be siblings of the labels")
        let accents = try labels.map { try XCTUnwrap(accentLabel(of: $0)) }
        for (label, accent) in zip(labels, accents) {
            XCTAssertEqual(label.textColor, .white)
            XCTAssertEqual(accent.textColor, .systemYellow)
            XCTAssertEqual(accent.text, label.text)
            XCTAssertEqual(accent.frame, label.bounds)
            XCTAssertFalse(accent.isAccessibilityElement)
        }

        header.apply(progress: 1, activeIndex: 1)
        XCTAssertEqual(accents.map(\.alpha), [0, 1, 0])

        header.apply(progress: 0.5, activeIndex: 0)
        XCTAssertEqual(accents[0].alpha, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(accents[1].alpha, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(accents[2].alpha, 0, accuracy: 0.000_001)

        header.apply(progress: 0.25, activeIndex: 0)
        XCTAssertEqual(accents[0].alpha, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(accents[1].alpha, 0.25, accuracy: 0.000_001)

        // The main phase (fade/shift) did not change from adding the accent.
        XCTAssertEqual(labels[0].alpha, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(labels[1].alpha, 0.25, accuracy: 0.000_001)
    }

    /// Reduce Motion: the active header is fully accented, the others are not.
    func testActiveColorUnderReduceMotionIsStatic() throws {
        let header = makeHeader()
        header.style = TesseraPanoHeaderView.Style(activeTextColor: .systemRed)
        header.isReduceMotionEnabled = { true }

        header.apply(progress: 1.4, activeIndex: 1)

        let accents = try headerLabels(in: header).map { try XCTUnwrap(accentLabel(of: $0)) }
        XCTAssertEqual(accents.map(\.alpha), [0, 1, 0])
    }

    /// Without `activeTextColor` there are no accent copies; turning the color on and off
    /// on the fly creates and removes them, and changing the titles rebuilds them for the new set.
    func testAccentLabelsFollowStyleAndTitles() {
        let header = makeHeader()
        XCTAssertTrue(headerLabels(in: header).allSatisfy { accentLabel(of: $0) == nil })

        header.style = TesseraPanoHeaderView.Style(activeTextColor: .systemBlue)
        XCTAssertTrue(headerLabels(in: header).allSatisfy { accentLabel(of: $0) != nil })

        header.setTitles(["A", "B"])
        let labels = headerLabels(in: header)
        XCTAssertEqual(labels.count, 2)
        XCTAssertEqual(labels.map { accentLabel(of: $0)?.text }, ["A", "B"])

        header.style = TesseraPanoHeaderView.Style()
        XCTAssertTrue(headerLabels(in: header).allSatisfy { accentLabel(of: $0) == nil })
    }

    /// `TesseraPanoramaStyle.headerActiveColor` reaches the panorama's header layer;
    /// one equal to `headerColor` needs no accent.
    func testPanoramaStyleHeaderActiveColorReachesHeaderLayer() {
        let sections = (0..<3).map { index in
            TesseraPanoramaSection(id: index, title: "S\(index)") { UIViewController() }
        }
        let panorama = TesseraPanoramaViewController(
            sections: sections,
            style: TesseraPanoramaStyle(headerColor: .white, headerActiveColor: .systemYellow)
        )
        panorama.loadViewIfNeeded()
        XCTAssertEqual(panorama.headerView.style.activeTextColor, .systemYellow)

        panorama.style = TesseraPanoramaStyle(headerColor: .white, headerActiveColor: .white)
        XCTAssertNil(panorama.headerView.style.activeTextColor)
    }

    // MARK: - VoiceOver from the header

    /// A three-finger swipe with focus on the header layer goes to the handler;
    /// without a handler the layer does not claim the gesture.
    func testAccessibilityScrollIsRoutedToHandler() {
        let header = makeHeader()
        XCTAssertFalse(header.accessibilityScroll(.left))

        var received: [UIAccessibilityScrollDirection] = []
        header.accessibilityScrollHandler = { direction in
            received.append(direction)
            return direction == .left
        }

        XCTAssertTrue(header.accessibilityScroll(.left))
        XCTAssertFalse(header.accessibilityScroll(.up))
        XCTAssertEqual(received, [.left, .up])
    }
}

#endif
