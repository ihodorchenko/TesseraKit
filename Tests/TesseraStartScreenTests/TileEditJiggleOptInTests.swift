//
//  TileEditJiggleOptInTests.swift
//  TesseraStartScreenTests
//
//  «Желе» режима редактирования — параметр хоста, по умолчанию выключен
//  (E15.6, D39).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §5 «Режим редактирования»
//  (п. 1: «желе» выключено по умолчанию, включается
//  `TesseraTileEditConfiguration.isJiggleEnabled`), §9 (Reduce Motion
//  выключает «желе» при любом значении параметра); docs/W10M-STARTSCREEN.md
//  §5 (в W10M сетка в правке статична).
//
//  Параметр читается при каждой сверке контролов, поэтому его можно менять на
//  лету: `configuration.didSet` пересобирает контролы и навешивает либо снимает
//  анимации (B4).
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileEditJiggleOptInTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Считает открепления.
    private final class UnpinRecorder: TesseraTileEditCoordinatorDelegate {
        var unpins: [AnyHashable] = []

        func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didUnpin tileID: AnyHashable) {
            unpins.append(tileID)
        }
    }

    private let ids: [AnyHashable] = ["a", "b", "c"]

    private func makeHost(
        jiggle: Bool? = nil,
        reduceMotion: Bool = false
    ) -> TesseraTestDragHost {
        var configuration = TesseraTileEditConfiguration()
        if let jiggle {
            configuration.isJiggleEnabled = jiggle
        }
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .medium),
            ],
            configuration: configuration
        )
        host.coordinator.isReduceMotionEnabled = { reduceMotion }
        return host
    }

    /// «Желе» на слое контента ячейки.
    private func cellJiggle(_ id: AnyHashable, in host: TesseraTestDragHost) -> CAAnimation? {
        host.host.cell(id)?.contentView.layer.animation(
            forKey: TesseraTileEditCoordinator.jiggleKey
        )
    }

    /// «Желе» на оверлее кнопок.
    private func controlJiggle(_ id: AnyHashable, in host: TesseraTestDragHost) -> CAAnimation? {
        host.coordinator.editControls[id]?.layer.animation(
            forKey: TesseraTileEditCoordinator.jiggleKey
        )
    }

    /// Нет ни одного покачивания на видимых ячейках и оверлеях.
    private func assertNoJiggle(
        in host: TesseraTestDragHost,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for id in host.gridIDs {
            XCTAssertNil(cellJiggle(id, in: host), "\(message): ячейка \(id)", file: file, line: line)
            XCTAssertNil(controlJiggle(id, in: host), "\(message): контрол \(id)", file: file, line: line)
            for layer in [host.host.cell(id)?.contentView.layer, host.coordinator.editControls[id]?.layer] {
                guard let layer else { continue }
                XCTAssertNil(
                    layer.animation(forKey: "transform.rotation.z"),
                    "\(message): поворот \(id)", file: file, line: line
                )
                XCTAssertTrue(
                    CATransform3DIsIdentity(layer.transform),
                    "\(message): остаточный transform \(id)", file: file, line: line
                )
            }
        }
    }

    // MARK: - Значение по умолчанию

    /// D39: «желе» выключено по умолчанию; прежние значения амплитуды, цикла и
    /// seed сохранены для хостов, которые его включают.
    func testJiggleIsOffByDefaultAndKeepsParameters() {
        let configuration = TesseraTileEditConfiguration()
        XCTAssertFalse(configuration.isJiggleEnabled)
        XCTAssertEqual(configuration.jiggleAngle, 1.2, accuracy: 0.0001)
        XCTAssertEqual(configuration.jiggleDuration, 0.4, accuracy: 0.0001)
        XCTAssertEqual(configuration.seed, 0xE4_0004_0000_0001)
    }

    // MARK: - Выключено (по умолчанию)

    /// После входа в правку у плиток и оверлеев нет анимации; `isJiggling` ложен,
    /// а дим и кнопки на месте.
    func testNoJiggleAfterEnteringEditWhenOffByDefault() {
        let host = makeHost()
        host.coordinator.beginEditing()
        host.spin(0.05)

        XCTAssertTrue(host.coordinator.isEditing)
        XCTAssertFalse(host.coordinator.isJiggling)
        XCTAssertEqual(host.coordinator.editControls.count, 3, "Кнопки на месте")
        assertNoJiggle(in: host, "Вход в edit")
        host.coordinator.endEditing()
    }

    /// Drag, resize, unpin и создание папки (с переприменением после render, B5)
    /// не оставляют на слоях никакого покачивания.
    func testNoJiggleAfterDragResizeUnpinAndRenderWhenOff() throws {
        let host = makeHost()
        let recorder = UnpinRecorder()
        host.coordinator.delegate = recorder
        host.coordinator.beginEditing()
        host.spin(0.05)

        // Drag: подъём, отпускание.
        XCTAssertTrue(host.startDrag("a"))
        assertNoJiggle(in: host, "Во время drag")
        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { host.coordinator.editControls["a"] != nil })
        host.spin(0.05)
        assertNoJiggle(in: host, "После drag")

        // Resize.
        XCTAssertNotNil(host.coordinator.cycleSize(of: "b"))
        host.host.layout()
        host.spin(0.05)
        assertNoJiggle(in: host, "После resize")

        // Unpin.
        host.coordinator.unpin("c")
        XCTAssertTrue(host.waitUntil { recorder.unpins.count == 1 })
        host.host.layout()
        host.spin(0.05)
        assertNoJiggle(in: host, "После unpin")

        // Создание папки: ячейки пересоздаются, сетка переприменяет дим (B5).
        let folder = try XCTUnwrap(host.coordinator.createFolder(withTile: "a"))
        host.host.layout()
        XCTAssertTrue(host.waitUntil { host.host.cell(folder.id) != nil })
        host.spin(0.05)
        assertNoJiggle(in: host, "После создания папки")
        XCTAssertFalse(host.coordinator.isJiggling)
        host.coordinator.endEditing()
    }

    /// Выход из правки при выключенном «желе»: слои чистые.
    func testNoResidualTransformAfterLeavingEditWhenOff() {
        let host = makeHost()
        host.coordinator.beginEditing()
        host.spin(0.05)
        host.coordinator.endEditing()
        host.spin(0.05)

        XCTAssertFalse(host.coordinator.isEditing)
        assertNoJiggle(in: host, "После выхода")
    }

    // MARK: - Включено

    /// Явное включение: анимация на ячейке и на оверлее каждой плитки, как раньше
    /// (синусоида ±1,2°, цикл около 0,4 с), `isJiggling` истинен.
    func testJiggleInstalledWhenEnabled() throws {
        let host = makeHost(jiggle: true)
        host.coordinator.beginEditing()

        XCTAssertTrue(host.waitUntil {
            self.ids.allSatisfy { self.cellJiggle($0, in: host) != nil }
        }, "Ячейки получили «желе»")
        XCTAssertTrue(host.coordinator.isJiggling)
        for id in ids {
            let animation = try XCTUnwrap(controlJiggle(id, in: host) as? CAKeyframeAnimation, "\(id)")
            XCTAssertEqual(animation.keyPath, "transform.rotation.z")
            XCTAssertEqual(animation.repeatCount, .infinity)
            XCTAssertGreaterThanOrEqual(animation.duration, 0.4 * 0.85 - 0.001)
            XCTAssertLessThanOrEqual(animation.duration, 0.4 * 1.15 + 0.001)
        }
        host.coordinator.endEditing()
    }

    /// При включённом параметре выход из правки снимает покачивание и не
    /// оставляет повёрнутого слоя.
    func testNoResidualTransformAfterLeavingEditWhenOn() {
        let host = makeHost(jiggle: true)
        host.coordinator.beginEditing()
        XCTAssertTrue(host.waitUntil {
            self.ids.allSatisfy { self.cellJiggle($0, in: host) != nil }
        })
        host.coordinator.endEditing()
        host.spin(0.05)

        XCTAssertFalse(host.coordinator.isEditing)
        assertNoJiggle(in: host, "После выхода")
    }

    // MARK: - Reduce Motion

    /// Reduce Motion побеждает параметр: «желе» не ставится, `isJiggling` ложен,
    /// кнопки остаются.
    func testReduceMotionBeatsEnabledParameter() {
        let host = makeHost(jiggle: true, reduceMotion: true)
        host.coordinator.beginEditing()
        host.spin(0.05)

        XCTAssertFalse(host.coordinator.isJiggling)
        XCTAssertEqual(host.coordinator.editControls.count, 3)
        assertNoJiggle(in: host, "Reduce Motion при включённом параметре")
        host.coordinator.endEditing()
    }

    // MARK: - Смена параметра на лету

    /// Параметр можно менять во время правки: включение навешивает «желе»,
    /// выключение снимает без остаточного transform.
    func testTogglingParameterWhileEditingInstallsAndRemovesJiggle() {
        let host = makeHost(jiggle: false)
        host.coordinator.beginEditing()
        host.spin(0.05)
        assertNoJiggle(in: host, "До включения")

        var configuration = host.coordinator.configuration
        configuration.isJiggleEnabled = true
        host.coordinator.configuration = configuration
        XCTAssertTrue(host.waitUntil {
            self.ids.allSatisfy { self.cellJiggle($0, in: host) != nil }
        }, "Включили на лету")
        XCTAssertTrue(host.coordinator.isJiggling)

        configuration.isJiggleEnabled = false
        host.coordinator.configuration = configuration
        host.spin(0.05)
        XCTAssertFalse(host.coordinator.isJiggling)
        assertNoJiggle(in: host, "После выключения на лету")
        host.coordinator.endEditing()
    }

    /// Включение параметра на лету при Reduce Motion ничего не навешивает.
    func testTogglingParameterOnUnderReduceMotionStaysStatic() {
        let host = makeHost(jiggle: false, reduceMotion: true)
        host.coordinator.beginEditing()
        host.spin(0.05)

        var configuration = host.coordinator.configuration
        configuration.isJiggleEnabled = true
        host.coordinator.configuration = configuration
        host.spin(0.05)

        assertNoJiggle(in: host, "Параметр включён на лету, Reduce Motion")
        XCTAssertFalse(host.coordinator.isJiggling)
        host.coordinator.endEditing()
    }
}

#endif
