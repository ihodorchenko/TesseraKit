//
//  TileGridAccessibilityTests.swift
//  TesseraStartScreenTests
//
//  VoiceOver-подписи сетки (E9.8в, волна W3 плана E9/E10).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §4 «Live-плитки»
//  (фронт/бэк контентной модели) и §9 «Accessibility» (плитка — один элемент:
//  label — заголовок, value — счётчик бэйджа; ярлык панели раскрытой папки —
//  тот же путь).
//
//  E9.8в: label live-плитки строится из `liveContent.frontFace` — заголовок и
//  подпись через запятую, — потому что VoiceOver должен читать то, что видно на
//  лицевой стороне, а не статичный заголовок ярлыка. value по-прежнему берётся
//  из бэйджа.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileGridAccessibilityTests: XCTestCase {

    // MARK: - Live-плитки (E9.8в)

    /// Label живой плитки — заголовок и подпись фронта через запятую; value —
    /// счётчик бэйджа, как у статичной плитки.
    func testLiveTileLabelComesFromFrontFaceAndValueFromBadge() {
        let live = tesseraTestLiveTile(
            "weather",
            front: TesseraLiveTileFace(title: "Погода", detail: "Минск, +12°"),
            back: TesseraLiveTileFace(title: "Прогноз"),
            badge: .count(3)
        )
        let cell = TesseraTileCell(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        cell.configure(with: .tile(live), liveTileEngine: nil, isVisible: false)

        XCTAssertEqual(cell.accessibilityLabel, "Погода, Минск, +12°")
        XCTAssertEqual(cell.accessibilityValue, "3")
    }

    /// Фронт без подписи даёт только заголовок; пустой заголовок фронта
    /// откатывается к заголовку ярлыка.
    func testLiveTileLabelFallsBackWhenFrontFaceIsEmpty() {
        let withoutDetail = tesseraTestLiveTile(
            "mail",
            front: TesseraLiveTileFace(title: "Почта"),
            badge: .dot
        )
        let cell = TesseraTileCell(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        cell.configure(with: .tile(withoutDetail), liveTileEngine: nil, isVisible: false)
        XCTAssertEqual(cell.accessibilityLabel, "Почта")
        XCTAssertNil(cell.accessibilityValue, "Точка без числа не озвучивается")

        let emptyFront = TileDescriptor(
            id: "empty-front",
            title: "Заголовок ярлыка",
            action: {},
            liveContent: TesseraTestLiveProvider(
                frontFace: TesseraLiveTileFace(title: "", detail: "Деталь")
            )
        )
        cell.configure(with: .tile(emptyFront), liveTileEngine: nil, isVisible: false)
        XCTAssertEqual(cell.accessibilityLabel, "Заголовок ярлыка, Деталь")
    }

    /// Статичная плитка без live-контента озвучивается прежним заголовком:
    /// поведение E9.8в не затрагивает.
    func testStaticTileLabelUnchanged() {
        let cell = TesseraTileCell(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        cell.configure(
            with: .tile(tesseraTestTile("notes", size: .small)),
            liveTileEngine: nil,
            isVisible: false
        )
        XCTAssertEqual(cell.accessibilityLabel, "notes")
        XCTAssertNil(cell.accessibilityValue)
    }

    /// Ярлык внутри панели раскрытой папки идёт тем же путём: label из фронта
    /// live-контента, value — из бэйджа.
    func testPanelShortcutLabelComesFromFrontFace() throws {
        let live = tesseraTestLiveTile(
            "in-folder",
            front: TesseraLiveTileFace(title: "Внутри", detail: "2 новых"),
            badge: .count(2),
            size: .small
        )
        let folder = TileFolder(id: "folder", title: "Folder", tiles: [live])
        let panel = TesseraFolderPanelCell(
            frame: CGRect(x: 0, y: 0, width: 350, height: 160)
        )
        panel.configure(folder: folder, columns: 4, spacing: 8)
        panel.layoutIfNeeded()

        let shortcut = try XCTUnwrap(panel.shortcutCells.first)
        XCTAssertEqual(shortcut.accessibilityLabel, "Внутри, 2 новых")
        XCTAssertEqual(shortcut.accessibilityValue, "2")
    }

    /// Ярлык панели без live-контента озвучивается заголовком ярлыка, как и
    /// плитка сетки.
    func testPanelShortcutLabelWithoutLiveContent() throws {
        let folder = TileFolder(
            id: "folder",
            title: "Folder",
            tiles: [tesseraTestTile("plain-in-folder", size: .small)]
        )
        let panel = TesseraFolderPanelCell(
            frame: CGRect(x: 0, y: 0, width: 350, height: 160)
        )
        panel.configure(folder: folder, columns: 4, spacing: 8)
        panel.layoutIfNeeded()

        let shortcut = try XCTUnwrap(panel.shortcutCells.first)
        XCTAssertEqual(shortcut.accessibilityLabel, "plain-in-folder")
        XCTAssertNil(shortcut.accessibilityValue)
    }
}

#endif
