//
//  LiveTileLayoutAndImageTests.swift
//  TesseraStartScreenTests
//
//  Тесты контейнера живой плитки (E10.9, трек T2).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §4 «Live-плитки
//  (движок)»: флип — только трансформы, layout посреди флипа не должен
//  ломать геометрию сторон; «изображения декодируются в размер плитки и
//  кешируются».
//
//  Тесты не поднимают окно и не ждут анимаций: флип стартует с длинной
//  длительностью, и проверяется модельное состояние слоёв в его середине.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class LiveTileLayoutAndImageTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Стороны плитки в порядке добавления: фронт, затем бэк.
    private func faceViews(of tile: TesseraLiveTileView) -> [TesseraLiveTileFaceView] {
        tile.subviews.compactMap { $0 as? TesseraLiveTileFaceView }
    }

    /// Иконка стороны — единственный `UIImageView` среди её подпредставлений.
    private func iconView(of face: TesseraLiveTileFaceView) -> UIImageView? {
        face.subviews.compactMap { $0 as? UIImageView }.first
    }

    /// Крупная растровая иконка, как «сырая» картинка приложения.
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

    /// Масштаб экрана, которым пользуется сторона плитки.
    private func displayScale(of view: UIView) -> CGFloat {
        let scale = view.traitCollection.displayScale
        return scale > 0 ? scale : UIScreen.main.scale
    }

    // MARK: - Layout посреди флипа (задача 1)

    /// Во время флипа у уходящей стороны неединичный 3D-`transform`; `frame`
    /// при таком трансформе не определён. Layout плитки (например, при смене
    /// размера ячейки посреди флипа) обязан задавать `bounds` + `center`, а не
    /// `frame`, — иначе сторона получает вырожденные `bounds`.
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
            "Посреди флипа у уходящей стороны должен быть поворот"
        )
        let flipTransform = front.layer.transform

        // Ячейка поменяла размер посреди флипа.
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
        // Layout трансформ не трогает: флип продолжается с той же фазы.
        XCTAssertTrue(CATransform3DEqualToTransform(front.layer.transform, flipTransform))
    }

    /// Повторный layout того же размера посреди флипа не искажает стороны.
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

    // MARK: - Даунсемплинг иконок (задача 2)

    /// §4: изображение стороны декодируется под размер плитки × scale, а не
    /// показывается «как есть» (1024×1024 пикселя на плитке 200 pt).
    func testFaceIconIsDownsampledToTileSize() {
        let tile = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        tile.setFaces(front: TesseraLiveTileFace(title: "Mail", icon: makeLargeIcon()), back: nil)
        tile.layoutIfNeeded()

        guard let front = faceViews(of: tile).first else {
            return XCTFail("Нет стороны плитки")
        }
        front.layoutIfNeeded()

        guard let image = iconView(of: front)?.image else {
            return XCTFail("Иконка стороны не показана")
        }
        let scale = displayScale(of: front)
        XCTAssertLessThanOrEqual(image.size.width * image.scale, 200 * scale + 0.5)
        XCTAssertLessThanOrEqual(image.size.height * image.scale, 200 * scale + 0.5)
        XCTAssertLessThan(image.size.width * image.scale, 1024)
        // Глиф по-прежнему перекрашивается цветом стороны.
        XCTAssertEqual(image.renderingMode, .alwaysTemplate)
    }

    /// Две плитки с одной и той же иконкой одного размера получают один и тот
    /// же даунсемплированный объект — из общего кеша.
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
        XCTAssertTrue(firstImage === secondImage, "Повторный запрос должен прийти из кеша")
    }

    /// Кеш: размер результата ≤ запрошенного × scale, пропорции сохранены,
    /// повторный запрос не рисует заново, другой размер — новый рендер.
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
        XCTAssertEqual(cache.renderCount, 1, "Повторный запрос не должен рисовать заново")

        _ = cache.image(for: icon, fitting: CGSize(width: 18, height: 18), scale: 3, renderingMode: .alwaysTemplate)
        XCTAssertEqual(cache.renderCount, 2)
    }

    /// Неквадратная иконка вписывается с сохранением пропорций.
    func testImageCacheKeepsAspectRatio() {
        let cache = TesseraLiveTileImageCache()
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400), format: format).image { _ in }

        let result = cache.image(for: wide, fitting: CGSize(width: 28, height: 28), scale: 2, renderingMode: .automatic)
        XCTAssertEqual(result.size.width * result.scale, 56, accuracy: 1)
        XCTAssertEqual(result.size.height * result.scale, 28, accuracy: 1)
    }

    /// Маленькая иконка (уже в размер) не перерисовывается.
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
