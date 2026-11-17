//
//  TesseraGestureTargetRetentionTests.swift
//  TesseraCoreTests
//
//  Evidence test: does `UIGestureRecognizer` retain
//  its target? Pivot, Panorama and StartScreen subscribe to the pan of the pager's scroll view
//  via `pan.addTarget(self, …)` and remove the target in `deinit`. If
//  UIKit retained the target strongly, there would be a cycle "controller -> pager ->
//  scroll view -> pan -> controller", and `deinit` would be unreachable.
//
//  Conclusion (fixed by the tests below): UIKit does NOT retain the target. The reference is
//  weak and zeroing; there is no cycle and the controller's `deinit` runs. So a
//  weak proxy target is not needed in Core.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraCore

/// A placeholder target: it only accepts the action.
private final class TargetProbe: NSObject {
    @objc func handle(_ sender: UIGestureRecognizer) {}
}

/// A host for the real scenario: it embeds the Core pager and subscribes to the pan of its
/// scroll view exactly as the component controllers do
/// (`addTarget(self, …)` + `removeTarget` in `deinit`).
private final class PagerHostProbe: UIViewController {
    let pager = TesseraPagerViewController(
        mode: .paged,
        pages: (0..<3).map { index in
            TesseraPageDescriptor(id: index, title: "Page \(index)") { UIViewController() }
        }
    )
    private weak var observedPan: UIPanGestureRecognizer?
    private let onDeinit: () -> Void

    init(onDeinit: @escaping () -> Void) {
        self.onDeinit = onDeinit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(pager)
        pager.view.frame = view.bounds
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
    }

    /// Finds the pager's scroll view (the same traversal as in Pivot/StartScreen)
    /// and subscribes to its pan.
    func attachToPagerPan() -> Bool {
        guard let scrollView = pager.view.subviews.compactMap({ $0 as? UIScrollView }).first else {
            return false
        }
        let pan = scrollView.panGestureRecognizer
        pan.addTarget(self, action: #selector(pagerPanDidChange(_:)))
        observedPan = pan
        return true
    }

    @objc private func pagerPanDidChange(_ pan: UIPanGestureRecognizer) {}

    deinit {
        observedPan?.removeTarget(self, action: #selector(pagerPanDidChange(_:)))
        onDeinit()
    }
}

final class TesseraGestureTargetRetentionTests: XCTestCase {

    // MARK: - UIKit behavior

    /// `addTarget(_:action:)` does not retain the target: after leaving the pool
    /// the target is released although the recognizer is alive and the target was not removed.
    func testGestureRecognizerDoesNotRetainAddedTarget() {
        let pan = UIPanGestureRecognizer()
        weak var weakTarget: TargetProbe?

        autoreleasepool {
            let target = TargetProbe()
            weakTarget = target
            pan.addTarget(target, action: #selector(TargetProbe.handle(_:)))
        }

        XCTAssertNil(weakTarget, "UIGestureRecognizer must not retain its target")
        withExtendedLifetime(pan) {}
    }

    /// The same for a target passed to `init(target:action:)`.
    func testGestureRecognizerDoesNotRetainInitTarget() {
        var pan: UIPanGestureRecognizer?
        weak var weakTarget: TargetProbe?

        autoreleasepool {
            let target = TargetProbe()
            weakTarget = target
            pan = UIPanGestureRecognizer(target: target, action: #selector(TargetProbe.handle(_:)))
        }

        XCTAssertNotNil(pan)
        XCTAssertNil(weakTarget, "init(target:action:) must not retain its target")
    }

    /// The built-in `UIScrollView` pan behaves the same way: an external target
    /// added additively is not retained.
    func testScrollViewPanDoesNotRetainAddedTarget() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        weak var weakTarget: TargetProbe?

        autoreleasepool {
            let target = TargetProbe()
            weakTarget = target
            scrollView.panGestureRecognizer.addTarget(target, action: #selector(TargetProbe.handle(_:)))
        }

        XCTAssertNil(weakTarget, "The UIScrollView pan must not retain an external target")
        withExtendedLifetime(scrollView) {}
    }

    /// A released target does not interfere with the recognizer's further operation:
    /// removing targets and adding them again does not crash.
    func testRecognizerStaysUsableAfterTargetDeallocates() {
        let pan = UIPanGestureRecognizer()

        autoreleasepool {
            let target = TargetProbe()
            pan.addTarget(target, action: #selector(TargetProbe.handle(_:)))
        }

        pan.removeTarget(nil, action: nil)
        let survivor = TargetProbe()
        pan.addTarget(survivor, action: #selector(TargetProbe.handle(_:)))
        pan.removeTarget(survivor, action: #selector(TargetProbe.handle(_:)))
    }

    // MARK: - The real scenario

    /// A controller that embeds the Core pager and subscribes with a target to the pan of its
    /// scroll view is released: there is no retain cycle, `deinit` is reachable
    /// (and removes the target). Checked both outside a window and inside one.
    func testHostSubscribedToPagerPanIsDeallocated() throws {
        for inWindow in [false, true] {
            var deinitCalled = false
            weak var weakHost: PagerHostProbe?
            var attached = false

            autoreleasepool {
                let host = PagerHostProbe { deinitCalled = true }
                weakHost = host
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
                if inWindow {
                    window.rootViewController = host
                    window.isHidden = false
                } else {
                    host.loadViewIfNeeded()
                    host.view.frame = window.bounds
                }
                host.view.layoutIfNeeded()
                attached = host.attachToPagerPan()
                if inWindow {
                    window.isHidden = true
                    window.rootViewController = nil
                }
            }

            XCTAssertTrue(attached, "The pager's scroll view must be found by walking the hierarchy (inWindow=\(inWindow))")
            XCTAssertNil(weakHost, "A host with a target on the pager's pan must be released (inWindow=\(inWindow))")
            XCTAssertTrue(deinitCalled, "The host's deinit must be reachable (inWindow=\(inWindow))")
        }
    }
}

#endif
