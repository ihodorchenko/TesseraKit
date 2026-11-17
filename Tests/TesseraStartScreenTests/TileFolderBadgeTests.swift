//
//  TileFolderBadgeTests.swift
//  TesseraStartScreenTests
//
//  A folder tile's badge is the sum of the numeric badges of the nested tiles (D44).
//  If there are no numeric ones but there is a dot, it is a dot; a sum over 99 is "99+" (drawn by
//  the badge itself, as on a tile). The folder badge follows the same placement rules as
//  a tile badge: the bottom corner at the end of the line, avoiding the resize arrow in
//  edit mode, hiding "99+" on 1×1 in edit mode. A small folder (1×1) with a badge does not draw
//  a title (like a small tile with an icon, D47): the mini grid sits above the badge row.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md (the "Implementation deviations"
//  section); decisions D44 and D47 in docs/STATE.md.
//
//  Screen widths 375/414 pt with 6 columns (margins 16, gap 8): a small tile is
//  50.3 / 57 pt.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileFolderBadgeTests: XCTestCase {

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    // MARK: - Rig

    private let screenWidths: [CGFloat] = [375, 414]

    private let badges: [(String, TesseraTileBadge)] = [
        ("count 3", .count(3)),
        ("count 99+", .count(150)),
        ("dot", .dot),
    ]

    private func unit(_ screenWidth: CGFloat) -> CGFloat {
        (screenWidth - 32 - 5 * 8) / 6
    }

    /// Folder sizes for a screen width with 6 columns, margins 16 and gap 8.
    private func folderSizes(screenWidth: CGFloat) -> [(TesseraTileSize, CGSize)] {
        let unit = unit(screenWidth)
        return [
            (.small, CGSize(width: unit, height: unit)),
            (.medium, CGSize(width: 2 * unit + 8, height: 2 * unit + 8)),
            (.wide, CGSize(width: 4 * unit + 24, height: 2 * unit + 8)),
        ]
    }

    private func inset(for size: CGSize) -> CGFloat {
        max(6, min(12, min(size.width, size.height) * 0.08))
    }

    /// A folder with two tiles: the first has a badge, the second does not; another composition
    /// goes through `members`.
    private func folder(
        id: String = "F",
        title: String = "Work",
        size: TesseraTileSize = .medium,
        members: [TesseraTileDescriptor]? = nil,
        badge: TesseraTileBadge = .count(3)
    ) -> TesseraTileFolder {
        TesseraTileFolder(
            id: id,
            title: title,
            tiles: members ?? [
                tesseraTestTile("mail", size: .small, badge: badge),
                tesseraTestTile("notes", size: .small),
            ],
            size: size
        )
    }

    /// A cell with a folder in a window with the given Dynamic Type and direction.
    private func makeCell(
        size: CGSize,
        folder: TesseraTileFolder,
        rightToLeft: Bool = false,
        category: UIContentSizeCategory = .large,
        editClearance: CGFloat = 0,
        isExpanded: Bool = false
    ) -> TesseraTileCell {
        let parent = UIViewController()
        let child = UIViewController()
        parent.addChild(child)
        parent.view.addSubview(child.view)
        child.view.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
        child.didMove(toParent: parent)
        parent.setOverrideTraitCollection(
            UITraitCollection(preferredContentSizeCategory: category),
            forChild: child
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        self.window = window

        let cell = TesseraTileCell(frame: CGRect(origin: CGPoint(x: 10, y: 10), size: size))
        if rightToLeft {
            cell.semanticContentAttribute = .forceRightToLeft
            cell.contentView.semanticContentAttribute = .forceRightToLeft
        }
        child.view.addSubview(cell)
        cell.configure(
            with: .folder(folder),
            liveTileEngine: nil,
            isVisible: false,
            isFolderExpanded: isExpanded
        )
        cell.setBadgeEditClearance(editClearance, animated: false)
        cell.layoutIfNeeded()
        return cell
    }

    private func badgeView(of cell: TesseraTileCell) -> TesseraLiveTileBadgeView {
        cell.contentView.subviews.compactMap { $0 as? TesseraLiveTileBadgeView }.first
            ?? TesseraLiveTileBadgeView()
    }

    private func titleLabel(of cell: TesseraTileCell) -> UILabel {
        cell.contentView.subviews.compactMap { $0 as? UILabel }.first ?? UILabel()
    }

    private func countText(of badgeView: TesseraLiveTileBadgeView) -> String? {
        badgeView.subviews.compactMap { $0 as? UILabel }.first?.text
    }

    // MARK: - Aggregate helper (D44)

    private func aggregate(_ badges: [TesseraTileBadge]) -> TesseraTileBadge {
        TesseraTileFolder.aggregateBadge(of: badges.enumerated().map {
            tesseraTestTile("t\($0.offset)", size: .small, badge: $0.element)
        })
    }

    /// An empty folder and a folder without badges give `.none`.
    func testAggregateIsNoneForEmptyAndBadgeless() {
        XCTAssertEqual(TesseraTileFolder.aggregateBadge(of: []), .none)
        XCTAssertEqual(aggregate([.none, .none, .none]), .none)
        XCTAssertEqual(folder(members: []).aggregateBadge, .none)
    }

    /// Counters add up; a single tile gives its counter.
    func testAggregateSumsPositiveCounts() {
        XCTAssertEqual(aggregate([.count(3)]), .count(3))
        XCTAssertEqual(aggregate([.count(3), .count(4), .none, .count(1)]), .count(8))
        XCTAssertEqual(aggregate([.count(1), .count(1)]), .count(2))
    }

    /// Zero and negative counters are ignored; if only those exist, the result is `.none`.
    func testAggregateIgnoresZeroAndNegativeCounts() {
        XCTAssertEqual(aggregate([.count(0), .count(-5)]), .none)
        XCTAssertEqual(aggregate([.count(-5), .count(2), .count(0)]), .count(2))
        XCTAssertEqual(aggregate([.count(-100), .count(3)]), .count(3), "a negative count is not subtracted")
    }

    /// A dot without positive counters is a dot; a dot with `.count(0)` is too.
    func testAggregateDotOnlyWhenNoPositiveCount() {
        XCTAssertEqual(aggregate([.dot]), .dot)
        XCTAssertEqual(aggregate([.none, .dot, .dot]), .dot)
        XCTAssertEqual(aggregate([.dot, .count(0)]), .dot)
        XCTAssertEqual(aggregate([.count(-1), .dot]), .dot)
    }

    /// A dot together with a counter: the counter wins (the dot does not add one).
    func testAggregateCountWinsOverDot() {
        XCTAssertEqual(aggregate([.dot, .count(3)]), .count(3))
        XCTAssertEqual(aggregate([.count(2), .dot, .count(5)]), .count(7))
    }

    /// A sum over 99 stays a number (the badge draws the "99+" label); a large
    /// sum saturates and does not overflow.
    func testAggregateOverNinetyNineAndSaturation() {
        XCTAssertEqual(aggregate([.count(60), .count(60)]), .count(120))
        XCTAssertEqual(aggregate([.count(99), .count(1)]), .count(100))
        XCTAssertEqual(aggregate([.count(Int.max), .count(5)]), .count(Int.max), "no overflow")
        XCTAssertEqual(aggregate([.count(Int.max - 1), .count(1), .count(1)]), .count(Int.max))
    }

    /// The order and position of a tile do not matter; all tiles are counted, not just
    /// the four visible in the preview.
    func testAggregateCountsAllMembersNotJustPreviewFour() {
        let members = (0..<6).map { tesseraTestTile("m\($0)", size: .small, badge: .count(10)) }
        XCTAssertEqual(TesseraTileFolder.aggregateBadge(of: members), .count(60))
        XCTAssertEqual(TesseraTileFolder.aggregateBadge(of: members.reversed()), .count(60))
    }

    // MARK: - Badge on a grid cell

    /// A capsule with a counter, "99+" and a dot: the widget is visible and the text is correct.
    func testFolderCellShowsAggregateCapsuleDotAnd99Plus() {
        let size = CGSize(width: 110, height: 110)
        let sum = makeCell(size: size, folder: folder(members: [
            tesseraTestTile("a", size: .small, badge: .count(3)),
            tesseraTestTile("b", size: .small, badge: .count(4)),
            tesseraTestTile("c", size: .small),
        ]))
        XCTAssertFalse(badgeView(of: sum).isHidden)
        XCTAssertEqual(badgeView(of: sum).badge, .count(7))
        XCTAssertEqual(countText(of: badgeView(of: sum)), "7")
        XCTAssertGreaterThan(badgeView(of: sum).frame.width, 0)

        let many = makeCell(size: size, folder: folder(members: [
            tesseraTestTile("a", size: .small, badge: .count(70)),
            tesseraTestTile("b", size: .small, badge: .count(40)),
        ]))
        XCTAssertEqual(countText(of: badgeView(of: many)), "99+")

        let dot = makeCell(size: size, folder: folder(members: [
            tesseraTestTile("a", size: .small, badge: .dot),
            tesseraTestTile("b", size: .small),
        ]))
        XCTAssertFalse(badgeView(of: dot).isHidden)
        XCTAssertEqual(badgeView(of: dot).badge, .dot)
        XCTAssertEqual(badgeView(of: dot).frame.size, CGSize(width: 10, height: 10))
    }

    /// Nobody has a badge: the widget is hidden and there is no frame (the previous behavior).
    func testFolderCellHidesBadgeWhenNoMemberHasOne() {
        let cell = makeCell(
            size: CGSize(width: 110, height: 110),
            folder: folder(members: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small, badge: .count(0)),
            ])
        )
        XCTAssertTrue(badgeView(of: cell).isHidden)
        XCTAssertEqual(badgeView(of: cell).frame, .zero)
        XCTAssertFalse(titleLabel(of: cell).isHidden)
    }

    /// A reused cell does not inherit another's badge: neither after a folder with a
    /// badge nor when switching to a tile or to a folder without a badge.
    func testReusedCellDoesNotInheritFolderBadge() {
        let cell = makeCell(size: CGSize(width: 110, height: 110), folder: folder())
        XCTAssertEqual(badgeView(of: cell).badge, .count(3))

        cell.prepareForReuse()
        XCTAssertEqual(badgeView(of: cell).badge, .none)
        XCTAssertNil(cell.accessibilityValue)

        cell.configure(with: .folder(folder(badge: .none)), liveTileEngine: nil, isVisible: false)
        cell.layoutIfNeeded()
        XCTAssertTrue(badgeView(of: cell).isHidden)

        cell.configure(
            with: .tile(tesseraTestTile("t", size: .medium, badge: .count(2))),
            liveTileEngine: nil,
            isVisible: false
        )
        cell.layoutIfNeeded()
        XCTAssertEqual(badgeView(of: cell).badge, .count(2), "the tile's badge is its own")
    }

    // MARK: - Corner and layout by size

    /// The folder badge is at the bottom at the end of the line (right in LTR, left in RTL) on
    /// 1×1, 2×2 and 4×2 folders; the title and preview do not overlap it, and the preview does not disappear;
    /// a small folder with a badge does not draw a title.
    func testBadgeSitsBottomTrailingAndDoesNotOverlapTitleOrPreview() throws {
        for width in screenWidths {
            for (tileSize, size) in folderSizes(screenWidth: width) {
                for (badgeName, badge) in badges {
                    for rtl in [false, true] {
                        let label = "\(Int(width)) pt \(tileSize) \(badgeName) rtl=\(rtl)"
                        let cell = makeCell(
                            size: size, folder: folder(size: tileSize, badge: badge), rightToLeft: rtl
                        )
                        let bounds = cell.contentView.bounds
                        let inset = inset(for: size)
                        let badgeView = badgeView(of: cell)
                        let frame = badgeView.frame
                        XCTAssertFalse(badgeView.isHidden, label)
                        XCTAssertEqual(badgeView.alpha, 1, accuracy: 0.001, label)
                        XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "inside the tile: \(label)")
                        XCTAssertEqual(frame.maxY, bounds.height - inset, accuracy: 0.5, "at the bottom: \(label)")
                        if rtl {
                            XCTAssertEqual(frame.minX, inset, accuracy: 0.5, "on the left in RTL: \(label)")
                        } else {
                            XCTAssertEqual(frame.maxX, bounds.width - inset, accuracy: 0.5, "on the right in LTR: \(label)")
                        }

                        let preview = try XCTUnwrap(cell.folderPreviewView, label)
                        XCTAssertFalse(preview.isHidden, label)
                        XCTAssertGreaterThanOrEqual(preview.frame.width, 12, "the preview did not disappear: \(label)")
                        XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(preview.frame), label)
                        XCTAssertFalse(preview.frame.intersects(frame), "preview × badge: \(label)")

                        let title = titleLabel(of: cell)
                        if tileSize == .small {
                            XCTAssertTrue(title.isHidden, "1×1 with a badge has no title: \(label)")
                            // The preview is centered above the badge row.
                            XCTAssertEqual(preview.frame.midX, bounds.midX, accuracy: 1, label)
                            XCTAssertLessThanOrEqual(preview.frame.maxY, frame.minY, label)
                        } else {
                            XCTAssertFalse(title.isHidden, label)
                            XCTAssertFalse(title.frame.intersects(frame), "title × badge: \(label)")
                            XCTAssertLessThanOrEqual(
                                preview.frame.maxY, min(title.frame.minY, frame.minY), "preview above the row: \(label)"
                            )
                            // The preview is still pinned to the top corner in reading direction.
                            XCTAssertEqual(preview.frame.minY, inset, accuracy: 0.5, label)
                            XCTAssertEqual(
                                rtl ? bounds.width - preview.frame.maxX : preview.frame.minX, inset,
                                accuracy: 0.5, label
                            )
                        }
                    }
                }
            }
        }
    }

    /// A folder without a badge is laid out as before badges: the title is visible at any size
    /// (including 1×1) at full width, the preview is pinned to the top corner and the title to the bottom.
    func testFolderWithoutBadgeKeepsItsLookAtAllSizes() throws {
        for width in screenWidths {
            for (tileSize, size) in folderSizes(screenWidth: width) {
                for rtl in [false, true] {
                    let label = "\(Int(width)) pt \(tileSize) rtl=\(rtl)"
                    let cell = makeCell(size: size, folder: folder(size: tileSize, badge: .none), rightToLeft: rtl)
                    let bounds = cell.contentView.bounds
                    let inset = inset(for: size)
                    let title = titleLabel(of: cell)
                    let preview = try XCTUnwrap(cell.folderPreviewView, label)
                    XCTAssertFalse(title.isHidden, "the title is visible: \(label)")
                    XCTAssertEqual(title.frame.minX, inset, accuracy: 0.5, label)
                    XCTAssertEqual(
                        title.frame.width, bounds.width - inset * 2, accuracy: 0.5, "the title spans the full width: \(label)"
                    )
                    XCTAssertEqual(title.frame.maxY, bounds.height - inset, accuracy: 0.5, label)
                    XCTAssertEqual(preview.frame.minY, inset, accuracy: 0.5, label)
                    XCTAssertLessThanOrEqual(preview.frame.maxY, title.frame.minY, label)
                    XCTAssertTrue(badgeView(of: cell).isHidden, label)
                }
            }
        }
    }

    /// A 2×2 folder's title yields to the badge beside it: it gets narrower, not taller.
    func testTitleOfMediumFolderYieldsToBadgeBeside() {
        let size = CGSize(width: 110, height: 110)
        let plain = makeCell(size: size, folder: folder(badge: .none))
        let withBadge = makeCell(size: size, folder: folder(badge: .count(3)))
        XCTAssertLessThan(titleLabel(of: withBadge).frame.width, titleLabel(of: plain).frame.width)
        XCTAssertLessThanOrEqual(titleLabel(of: withBadge).frame.height, titleLabel(of: plain).frame.height + 0.5)
    }

    /// Dynamic Type: at XXL and AX5 the badge does not run into the title and preview.
    func testBadgeDoesNotOverlapAtLargeDynamicType() {
        let categories: [UIContentSizeCategory] = [.extraExtraLarge, .accessibilityExtraExtraExtraLarge]
        for category in categories {
            for (tileSize, size) in folderSizes(screenWidth: 375) {
                for (badgeName, badge) in badges {
                    let label = "\(category.rawValue) \(tileSize) \(badgeName)"
                    let cell = makeCell(size: size, folder: folder(size: tileSize, badge: badge), category: category)
                    let frame = badgeView(of: cell).frame
                    let title = titleLabel(of: cell)
                    XCTAssertTrue(cell.contentView.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), label)
                    if !title.isHidden {
                        XCTAssertFalse(title.frame.intersects(frame), "title × badge: \(label)")
                    }
                    if let preview = cell.folderPreviewView, preview.frame.width > 0 {
                        XCTAssertFalse(preview.frame.intersects(frame), "preview × badge: \(label)")
                    }
                }
            }
        }
    }

    // MARK: - Edit mode: avoiding the resize arrow

    /// In edit mode the folder badge avoids the resize arrow, and the title and preview do not
    /// overlap it; "99+" on 1×1 is hidden in edit mode.
    func testEditModeSlidesFolderBadgeAwayFromResizeArrow() {
        for width in screenWidths {
            for (tileSize, size) in folderSizes(screenWidth: width) {
                for (badgeName, badge) in badges {
                    for rtl in [false, true] {
                        let label = "\(Int(width)) pt \(tileSize) \(badgeName) rtl=\(rtl)"
                        let clearance = TesseraTileEditControlView.badgeClearance(forTileSize: size, maxDiameter: 28)
                        let normal = makeCell(size: size, folder: folder(size: tileSize, badge: badge), rightToLeft: rtl)
                        let editing = makeCell(
                            size: size, folder: folder(size: tileSize, badge: badge),
                            rightToLeft: rtl, editClearance: clearance
                        )
                        let editBadge = badgeView(of: editing)
                        let normalBadge = badgeView(of: normal)
                        let isHidden = tileSize == .small && badgeName == "count 99+"
                        XCTAssertEqual(editBadge.alpha, isHidden ? 0 : 1, accuracy: 0.001, "'99+' on 1×1: \(label)")
                        if isHidden { continue }

                        let arrow = TesseraTileEditControlView.resizeButtonFrame(
                            inTileBounds: CGRect(origin: .zero, size: size),
                            side: TesseraTileEditControlView.diameter(forTileSize: size, maxDiameter: 28),
                            isRightToLeft: rtl
                        )
                        let frame = editBadge.frame
                        XCTAssertFalse(frame.intersects(arrow), "badge × arrow: \(label)")
                        XCTAssertEqual(frame.maxY, normalBadge.frame.maxY, accuracy: 0.5, "same row: \(label)")
                        let moved = rtl
                            ? frame.minX - normalBadge.frame.minX
                            : normalBadge.frame.maxX - frame.maxX
                        XCTAssertGreaterThan(moved, 0, "moved away from the corner: \(label)")
                        let title = titleLabel(of: editing)
                        if !title.isHidden { XCTAssertFalse(title.frame.intersects(frame), "title: \(label)") }
                        if let preview = editing.folderPreviewView {
                            XCTAssertFalse(preview.frame.intersects(frame), "preview: \(label)")
                        }
                    }
                }
            }
        }
    }

    /// A live coordinator: in edit mode the folder badge does not intersect the resize arrow, and
    /// after leaving it returns to the corner (the coordinator computes the shift for a folder the same way
    /// as for a tile).
    func testCoordinatorEditModeKeepsFolderBadgeClearOfArrow() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small, badge: .count(3)),
                tesseraTestTile("b", size: .small, badge: .dot),
                tesseraTestTile("c", size: .small),
            ],
            columns: 6,
            windowSize: CGSize(width: 375, height: 844),
            prepare: { store, columns in
                guard let created = store.createFolder(withTile: "a", title: "Work", columns: columns) else { return }
                _ = store.addToFolder("b", folderID: created.id, columns: columns)
            }
        )
        host.coordinator.isReduceMotionEnabled = { true }
        host.host.grid.isReduceMotionEnabled = { true }
        let folder = try XCTUnwrap(host.folders.first)
        host.coordinator.beginEditing()
        host.spin(0.05)

        let cell = try XCTUnwrap(host.host.cell(folder.id))
        cell.layoutIfNeeded()
        let badgeView = badgeView(of: cell)
        XCTAssertEqual(badgeView.badge, .count(3), "dot and counter: the counter wins")
        let control = try XCTUnwrap(host.coordinator.editControls[folder.id])
        control.layoutIfNeeded()
        let tile = try XCTUnwrap(host.host.grid.frame(forItemID: folder.id))
        XCTAssertGreaterThan(cell.badgeEditClearance, 0)
        let badgeFrame = cell.contentView.convert(badgeView.frame, to: host.host.grid)
        let resize = control.convert(control.resizeButtonFrame, to: host.host.grid)
        XCTAssertTrue(tile.insetBy(dx: -0.5, dy: -0.5).contains(badgeFrame))
        XCTAssertFalse(badgeFrame.intersects(resize), "badge × arrow")

        host.coordinator.endEditing()
        host.spin(0.05)
        cell.layoutIfNeeded()
        XCTAssertEqual(cell.badgeEditClearance, 0)
        XCTAssertEqual(
            self.badgeView(of: cell).frame.maxX,
            cell.contentView.bounds.width - max(6, min(12, cell.contentView.bounds.width * 0.08)),
            accuracy: 0.5
        )
    }

    // MARK: - Live update

    /// A change of a folder member's badge reaches the folder tile through the grid snapshot: the sum,
    /// the dot and hiding are updated on the same cell, without a reload.
    func testMemberBadgeChangeUpdatesFolderBadgeThroughSnapshot() throws {
        func snapshot(mail: TesseraTileBadge, other: TesseraTileBadge = .none) -> TesseraTileGridSnapshot {
            TesseraTileGridSnapshot(items: [
                .folder(folder(members: [
                    tesseraTestTile("mail", size: .small, badge: mail),
                    tesseraTestTile("notes", size: .small, badge: other),
                ])),
                .tile(tesseraTestTile("solo", size: .small)),
            ], unpinned: [])
        }
        let host = TesseraTestWindowedGrid(snapshot: snapshot(mail: .none), columns: 6)
        let cell = try XCTUnwrap(host.cell("F"))
        XCTAssertTrue(badgeView(of: cell).isHidden)

        host.grid.update(snapshot: snapshot(mail: .count(3)), animated: false)
        host.layout()
        XCTAssertTrue(host.cell("F") === cell, "the same cell")
        XCTAssertEqual(badgeView(of: cell).badge, .count(3))
        XCTAssertFalse(badgeView(of: cell).isHidden)
        XCTAssertGreaterThan(badgeView(of: cell).frame.width, 0)
        XCTAssertEqual(cell.accessibilityValue, "3, 2")

        host.grid.update(snapshot: snapshot(mail: .count(3), other: .count(200)), animated: false)
        host.layout()
        XCTAssertEqual(countText(of: badgeView(of: cell)), "99+")

        host.grid.update(snapshot: snapshot(mail: .none, other: .dot), animated: false)
        host.layout()
        XCTAssertEqual(badgeView(of: cell).badge, .dot)
        XCTAssertEqual(cell.accessibilityValue, "\(TesseraStartScreenStrings.string(.a11yBadgeDot)), 2")

        host.grid.update(snapshot: snapshot(mail: .none), animated: false)
        host.layout()
        XCTAssertTrue(badgeView(of: cell).isHidden)
        XCTAssertEqual(cell.accessibilityValue, "2")
    }

    /// The badge also changes when a snapshot is applied with animation.
    func testMemberBadgeChangeUpdatesFolderBadgeWithAnimatedSnapshot() throws {
        func snapshot(_ mail: TesseraTileBadge) -> TesseraTileGridSnapshot {
            TesseraTileGridSnapshot(items: [
                .folder(folder(members: [
                    tesseraTestTile("mail", size: .small, badge: mail),
                    tesseraTestTile("notes", size: .small),
                ])),
                .tile(tesseraTestTile("solo", size: .small)),
            ], unpinned: [])
        }
        let host = TesseraTestWindowedGrid(snapshot: snapshot(.none), columns: 6)
        let cell = try XCTUnwrap(host.cell("F"))
        host.grid.update(snapshot: snapshot(.count(5)), animated: true)
        XCTAssertTrue(host.waitUntil { self.badgeView(of: cell).badge == .count(5) })
    }

    /// Store: a member leaving the catalog (an invisible one is not counted), unpinning and
    /// folder dissolution (D45) recompute the badge; after dissolution the remaining tile
    /// shows its own badge as a tile.
    func testStoreDissolveAndCatalogPruneRecomputeAggregate() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        let columns = 6
        func catalog(_ entries: [(String, TesseraTileBadge)]) -> [TesseraTileDescriptor] {
            entries.map { tesseraTestTile($0.0, size: .small, badge: $0.1) }
        }
        let all: [(String, TesseraTileBadge)] = [("a", .count(3)), ("b", .count(4)), ("c", .dot), ("solo", .none)]
        store.setCatalog(catalog(all))
        store.placeItems(columns: columns)
        let created = try XCTUnwrap(store.createFolder(withTile: "a", title: "Work", columns: columns))
        XCTAssertTrue(store.addToFolder("b", folderID: created.id, columns: columns))
        XCTAssertTrue(store.addToFolder("c", folderID: created.id, columns: columns))
        XCTAssertEqual(store.snapshot(columns: columns).folders.first?.aggregateBadge, .count(7))

        let host = TesseraTestWindowedGrid(snapshot: store.snapshot(columns: columns), columns: columns)
        let cell = try XCTUnwrap(host.cell(created.id))
        XCTAssertEqual(badgeView(of: cell).badge, .count(7))

        // The member left the catalog: it is invisible and not counted (D45).
        store.setCatalog(catalog(all.filter { $0.0 != "b" }))
        host.grid.update(snapshot: store.snapshot(columns: columns), animated: false)
        host.layout()
        XCTAssertEqual(store.snapshot(columns: columns).folders.first?.tiles.count, 2)
        XCTAssertEqual(badgeView(of: cell).badge, .count(3), "an invisible member is not counted")

        // Unpinning a member: one tile remains in the folder, so the folder is dissolved.
        XCTAssertTrue(store.unpin("a", columns: columns))
        let dissolved = store.snapshot(columns: columns)
        XCTAssertTrue(dissolved.folders.isEmpty, "D45: a one-tile folder is dissolved")
        host.grid.update(snapshot: dissolved, animated: false)
        host.layout()
        let tileCell = try XCTUnwrap(host.cell("c"))
        XCTAssertEqual(badgeView(of: tileCell).badge, .dot, "the remaining tile keeps its own badge")
        XCTAssertEqual(tileCell.accessibilityValue, TesseraStartScreenStrings.string(.a11yBadgeDot))
    }

    /// A folder of three: unpinning one recomputes the aggregate from the remaining ones.
    func testUnpinOneOfThreeRecomputesAggregate() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        let columns = 6
        store.setCatalog([
            tesseraTestTile("a", size: .small, badge: .count(10)),
            tesseraTestTile("b", size: .small, badge: .count(5)),
            tesseraTestTile("c", size: .small, badge: .count(1)),
        ])
        store.placeItems(columns: columns)
        let created = try XCTUnwrap(store.createFolder(withTile: "a", title: "F", columns: columns))
        XCTAssertTrue(store.addToFolder("b", folderID: created.id, columns: columns))
        XCTAssertTrue(store.addToFolder("c", folderID: created.id, columns: columns))
        XCTAssertEqual(store.snapshot(columns: columns).folders.first?.aggregateBadge, .count(16))

        XCTAssertTrue(store.unpin("a", columns: columns))
        XCTAssertEqual(store.snapshot(columns: columns).folders.first?.aggregateBadge, .count(6))
    }

    // MARK: - Accessibility

    /// The folder's value reflects the aggregate through the same helper as a tile: a number for
    /// a sum, "has a notification" for a dot; the label is the title; the tile count and
    /// "expanded" are kept; without a badge the value is as before.
    func testFolderAccessibilityValueReflectsAggregate() {
        let size = CGSize(width: 110, height: 110)
        let dotText = TesseraStartScreenStrings.string(.a11yBadgeDot)
        let expanded = TesseraStartScreenStrings.string(.panelExpanded)

        let sum = makeCell(size: size, folder: folder(badge: .count(3)))
        XCTAssertEqual(sum.accessibilityLabel, "Work", "the label is the folder title")
        XCTAssertEqual(sum.accessibilityValue, "3, 2")
        sum.setFolderExpanded(true)
        XCTAssertEqual(sum.accessibilityValue, "3, 2, \(expanded)")
        sum.setFolderExpanded(false)
        XCTAssertEqual(sum.accessibilityValue, "3, 2")

        let dot = makeCell(size: size, folder: folder(badge: .dot))
        XCTAssertEqual(dot.accessibilityValue, "\(dotText), 2")

        let many = makeCell(size: size, folder: folder(members: [
            tesseraTestTile("a", size: .small, badge: .count(70)),
            tesseraTestTile("b", size: .small, badge: .count(40)),
        ]))
        XCTAssertEqual(many.accessibilityValue, "110, 2", "the number is spoken, not '99+'")

        let plain = makeCell(size: size, folder: folder(badge: .none))
        XCTAssertEqual(plain.accessibilityValue, "2", "without a badge, as before")
        XCTAssertTrue(plain.isAccessibilityElement)
    }

    // MARK: - Panel and expanded folder

    /// On an expanded folder's tile the badge stays, while the panel header has no badge of its own
    /// (badges exist only on the panel's tiles, as before).
    func testPanelHeaderHasNoBadgeAndFolderTileKeepsOneWhenExpanded() throws {
        let folder = folder(members: [
            tesseraTestTile("mail", size: .small, badge: .count(3)),
            tesseraTestTile("notes", size: .small, badge: .dot),
        ])
        let host = TesseraTestWindowedGrid(
            items: [.folder(folder), .tile(tesseraTestTile("solo", size: .small))],
            columns: 6
        )
        host.grid.openFolder(folder, animated: false)
        XCTAssertTrue(host.waitForFolderTransition())
        host.layout()

        let tileCell = try XCTUnwrap(host.cell(folder.id))
        XCTAssertEqual(badgeView(of: tileCell).badge, .count(3), "the expanded folder's tile keeps its badge")
        XCTAssertEqual(tileCell.accessibilityValue, "3, 2, \(TesseraStartScreenStrings.string(.panelExpanded))")

        let panel = try XCTUnwrap(host.panelCell(folderID: folder.id))
        func ownBadges(in view: UIView) -> [TesseraLiveTileBadgeView] {
            var result: [TesseraLiveTileBadgeView] = []
            for subview in view.subviews {
                if subview is TesseraTileCell { continue }
                if let badge = subview as? TesseraLiveTileBadgeView { result.append(badge) }
                result += ownBadges(in: subview)
            }
            return result
        }
        XCTAssertTrue(ownBadges(in: panel).isEmpty, "the panel header has no badge")
        XCTAssertEqual(
            panel.shortcutCells.map { badgeView(of: $0).badge }, [.count(3), .dot], "the panel tiles' badges are unchanged"
        )
    }

    // MARK: - Preview

    /// The preview's mini icons keep their own badges next to the folder badge.
    func testPreviewMiniTilesKeepTheirOwnBadges() throws {
        let cell = makeCell(size: CGSize(width: 110, height: 110), folder: folder(members: [
            tesseraTestTile("a", size: .small, badge: .dot),
            tesseraTestTile("b", size: .small, badge: .count(3)),
            tesseraTestTile("c", size: .small),
        ]))
        let preview = try XCTUnwrap(cell.folderPreviewView)
        XCTAssertEqual(preview.miniTileViews.map { $0.badge }, [.dot, .count(3), .none])
        XCTAssertEqual(badgeView(of: cell).badge, .count(3), "sum: the dot does not add")
    }
}

#endif
