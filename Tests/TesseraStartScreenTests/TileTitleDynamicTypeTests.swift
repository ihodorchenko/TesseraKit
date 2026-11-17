//
//  TileTitleDynamicTypeTests.swift
//  TesseraStartScreenTests
//
//  Tile titles at accessibility Dynamic Type sizes.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §9 "Accessibility":
//  the font grows but is bounded by the tile geometry; a word is never broken
//  mid-character; VoiceOver reads the full title.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileTitleDynamicTypeTests: XCTestCase {

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    /// A cell in a window with an overridden Dynamic Type category.
    private func makeCell(
        title: String,
        side: CGFloat,
        category: UIContentSizeCategory
    ) -> (cell: TesseraTileCell, label: UILabel) {
        let parent = UIViewController()
        let child = UIViewController()
        parent.addChild(child)
        parent.view.addSubview(child.view)
        child.view.frame = CGRect(x: 0, y: 0, width: 320, height: 320)
        child.didMove(toParent: parent)
        parent.setOverrideTraitCollection(
            UITraitCollection(preferredContentSizeCategory: category),
            forChild: child
        )

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        self.window = window

        let cell = TesseraTileCell(frame: CGRect(x: 10, y: 10, width: side, height: side))
        child.view.addSubview(cell)
        cell.configure(
            with: .tile(tesseraTestTile(title, size: .small)),
            liveTileEngine: nil,
            isVisible: false
        )
        cell.layoutIfNeeded()

        let label = tesseraTestTitleLabel(in: cell)
        return (cell, label)
    }

    private func tesseraTestTitleLabel(in cell: TesseraTileCell) -> UILabel {
        cell.contentView.subviews.compactMap { $0 as? UILabel }.first ?? UILabel()
    }

    /// The width of the longest word in the label's current font.
    private func longestWordWidth(_ label: UILabel) -> CGFloat {
        (label.text ?? "").components(separatedBy: .whitespaces).map {
            ($0 as NSString).size(withAttributes: [.font: label.font as Any]).width
        }.max() ?? 0
    }

    func testTitleLabelNeverBreaksByCharacter() {
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraLarge] {
            let (_, label) = makeCell(title: "Calendar", side: 73, category: category)
            XCTAssertEqual(label.lineBreakMode, .byTruncatingTail)
        }
    }

    func testLongWordFitsOrFallsBackToSingleLineAtAccessibilitySize() {
        let (_, label) = makeCell(
            title: "Calendar", side: 73, category: .accessibilityExtraExtraLarge
        )
        let fits = longestWordWidth(label) <= label.bounds.width + 0.5
        XCTAssertTrue(
            fits || label.numberOfLines == 1,
            "Either the word fits entirely, or the title is truncated to one line"
        )
        XCTAssertGreaterThan(label.frame.width, 0)
    }

    func testFontCappedByTileGeometryAtAccessibilitySize() {
        let (_, large) = makeCell(title: "Music", side: 73, category: .large)
        let (_, accessible) = makeCell(
            title: "Music", side: 73, category: .accessibilityExtraExtraExtraLarge
        )
        // The ceiling is a fraction of the tile side (taking fit-to-width into account).
        XCTAssertLessThanOrEqual(
            accessible.font.pointSize,
            max(12, floor(73 * TesseraTileCell.titleFontSideFraction)) + 0.5
        )
        XCTAssertGreaterThanOrEqual(accessible.font.pointSize, large.font.pointSize * 0.6 - 0.5)
    }

    func testFontScaleDownRespectsMinimumFactor() {
        let (_, label) = makeCell(
            title: "Internationalization", side: 73, category: .accessibilityExtraExtraExtraLarge
        )
        let cap = max(12, floor(73 * TesseraTileCell.titleFontSideFraction))
        XCTAssertGreaterThanOrEqual(
            label.font.pointSize,
            floor(cap * TesseraTileCell.titleMinimumScaleFactor) - 1.5
        )
        XCTAssertEqual(label.numberOfLines, 1, "The word does not fit — one line with an ellipsis")
    }

    func testTitleLabelStaysInsideTileAndVoiceOverLabelIsFull() {
        for side: CGFloat in [73, 150, 310] {
            let (cell, label) = makeCell(
                title: "Calendar events", side: side, category: .accessibilityExtraExtraLarge
            )
            XCTAssertGreaterThanOrEqual(label.frame.minX, 0)
            XCTAssertGreaterThanOrEqual(label.frame.minY, 0)
            XCTAssertLessThanOrEqual(label.frame.maxX, cell.contentView.bounds.width + 0.5)
            XCTAssertLessThanOrEqual(label.frame.maxY, cell.contentView.bounds.height + 0.5)
            XCTAssertEqual(cell.accessibilityLabel, "Calendar events")
        }
    }

    func testNormalSizeFontUnchangedForSmallTile() {
        let (_, label) = makeCell(title: "Mail", side: 73, category: .large)
        XCTAssertEqual(label.font.pointSize, 12, accuracy: 0.5)
    }
}

#endif
