//
//  TileTitleDynamicTypeTests.swift
//  TesseraStartScreenTests
//
//  Заголовки плиток на accessibility-размерах Dynamic Type (E12.6).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §9 «Accessibility»,
//  п. 43: шрифт растёт, но ограничен геометрией плитки; слово не рвётся
//  посреди символа; VoiceOver читает полный заголовок.
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

    /// Ячейка в окне с переопределённой категорией Dynamic Type.
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

    /// Ширина самого длинного слова в текущем шрифте подписи.
    private func longestWordWidth(_ label: UILabel) -> CGFloat {
        (label.text ?? "").components(separatedBy: .whitespaces).map {
            ($0 as NSString).size(withAttributes: [.font: label.font as Any]).width
        }.max() ?? 0
    }

    func testTitleLabelNeverBreaksByCharacter() {
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraLarge] {
            let (_, label) = makeCell(title: "Календарь", side: 73, category: category)
            XCTAssertEqual(label.lineBreakMode, .byTruncatingTail)
        }
    }

    func testLongWordFitsOrFallsBackToSingleLineAtAccessibilitySize() {
        let (_, label) = makeCell(
            title: "Календарь", side: 73, category: .accessibilityExtraExtraLarge
        )
        let fits = longestWordWidth(label) <= label.bounds.width + 0.5
        XCTAssertTrue(
            fits || label.numberOfLines == 1,
            "Слово либо помещается целиком, либо заголовок усекается в одну строку"
        )
        XCTAssertGreaterThan(label.frame.width, 0)
    }

    func testFontCappedByTileGeometryAtAccessibilitySize() {
        let (_, large) = makeCell(title: "Музыка", side: 73, category: .large)
        let (_, accessible) = makeCell(
            title: "Музыка", side: 73, category: .accessibilityExtraExtraExtraLarge
        )
        // Потолок — доля стороны плитки (с учётом подгонки под ширину).
        XCTAssertLessThanOrEqual(
            accessible.font.pointSize,
            max(12, floor(73 * TesseraTileCell.titleFontSideFraction)) + 0.5
        )
        XCTAssertGreaterThanOrEqual(accessible.font.pointSize, large.font.pointSize * 0.6 - 0.5)
    }

    func testFontScaleDownRespectsMinimumFactor() {
        let (_, label) = makeCell(
            title: "Конфиденциальность", side: 73, category: .accessibilityExtraExtraExtraLarge
        )
        let cap = max(12, floor(73 * TesseraTileCell.titleFontSideFraction))
        XCTAssertGreaterThanOrEqual(
            label.font.pointSize,
            floor(cap * TesseraTileCell.titleMinimumScaleFactor) - 1.5
        )
        XCTAssertEqual(label.numberOfLines, 1, "Слово не влезло — одна строка с многоточием")
    }

    func testTitleLabelStaysInsideTileAndVoiceOverLabelIsFull() {
        for side: CGFloat in [73, 150, 310] {
            let (cell, label) = makeCell(
                title: "Календарь событий", side: side, category: .accessibilityExtraExtraLarge
            )
            XCTAssertGreaterThanOrEqual(label.frame.minX, 0)
            XCTAssertGreaterThanOrEqual(label.frame.minY, 0)
            XCTAssertLessThanOrEqual(label.frame.maxX, cell.contentView.bounds.width + 0.5)
            XCTAssertLessThanOrEqual(label.frame.maxY, cell.contentView.bounds.height + 0.5)
            XCTAssertEqual(cell.accessibilityLabel, "Календарь событий")
        }
    }

    func testNormalSizeFontUnchangedForSmallTile() {
        let (_, label) = makeCell(title: "Почта", side: 73, category: .large)
        XCTAssertEqual(label.font.pointSize, 12, accuracy: 0.5)
    }
}

#endif
