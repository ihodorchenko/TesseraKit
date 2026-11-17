//
//  TesseraPanoramaView.swift
//  TesseraPanorama
//
//  The SwiftUI facade of the panorama.
//  Design document: docs/PANORAMA-IOS-DESIGN.md (choice of foundation:
//  a UIKit core + a SwiftUI facade via `UIViewControllerRepresentable`; conceptual
//  architecture: a declarative API of sections, style, and delegate;
//  accessibility: the state bridge is only an `ObservableObject`, since iOS 15 does not
//  support the Observable macro; animations and VoiceOver stay in the UIKit core).
//
//  The facade does not duplicate mechanics: it creates and updates
//  `TesseraPanoramaViewController`. Snapping, parallax, headers, gesture arbitration, and
//  accessibility live in the UIKit core.
//

#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import TesseraCore
import UIKit

/// The SwiftUI view of the panorama (see docs/PANORAMA-IOS-DESIGN.md).
///
/// A wrapper over ``TesseraPanoramaViewController``. On iOS 15, pure SwiftUI does not expose
/// the progress of a page drag, so snapping, background parallax, and
/// header interpolation by `t` run in the UIKit core, and SwiftUI only
/// describes the state.
///
/// ```swift
/// TesseraPanoramaView(
///     sections: [
///         TesseraPanoramaSection(id: "start", title: "Home") { StartViewController() },
///         TesseraPanoramaSection(id: "news", title: "News") { NewsViewController() },
///     ],
///     style: TesseraPanoramaStyle(
///         peek: 48,
///         backgroundBehavior: .image(UIImage(named: "panorama-bg"))
///     )
/// )
/// ```
///
/// ## Updates
///
/// - ``TesseraPanoramaStyle`` is passed on every update, but the core compares it
///   with the current one and skips applying an identical style;
/// - when the set of `id`s or titles changes, the sections are rebuilt
///   (`reload(sections:)`; controllers whose `id` survives are reused);
/// - with the same `id`s and titles, new content reaches the already loaded
///   sections in place: the controller of a SwiftUI section
///   (`TesseraSwiftUIContentProvider`) receives a new `rootView`, and the scroll
///   position, the current section, and `@State` are preserved. A UIKit provider
///   (`TesseraViewControllerProvider`) cannot update a ready controller:
///   change its state through the controller itself or by changing the `id`.
///
/// ## Delegate
///
/// ``TesseraPanoramaDelegate`` is a class-bound protocol, and a SwiftUI struct cannot
/// hold a `weak` reference. The facade therefore hands the delegate to a coordinator,
/// which retains the latest ``TesseraPanoramaView`` value and forwards both
/// callbacks. The delegate is held by a strong reference while the view is
/// installed: if it holds SwiftUI state itself, use an intermediate
/// object to avoid a retain cycle.
public struct TesseraPanoramaView: UIViewControllerRepresentable {

    /// The sections in reading order.
    private let sections: [TesseraPanoramaSection]

    /// The appearance: peek, parallax factor, header font and colors, background.
    private let style: TesseraPanoramaStyle

    /// The snapping policy (see the snapping notes in the design document).
    ///
    /// ``TesseraPanoramaStyle`` has no snapping field, so the velocity threshold
    /// is passed separately and goes to the core as is.
    private let snapPolicy: TesseraSnapPolicy

    /// The observer of progress and section changes.
    private let delegate: TesseraPanoramaDelegate?

    /// Creates the panorama facade.
    ///
    /// - Parameters:
    ///   - sections: The sections in reading order; the first element is the first section for the
    ///     user (in RTL the core mirrors the physical order).
    ///   - style: The appearance; the system default if omitted.
    ///   - snapPolicy: The snapping policy; Core's parameters by default.
    ///   - delegate: The state observer; optional.
    public init(
        sections: [TesseraPanoramaSection],
        style: TesseraPanoramaStyle = TesseraPanoramaStyle(),
        snapPolicy: TesseraSnapPolicy = TesseraSnapPolicy(),
        delegate: TesseraPanoramaDelegate? = nil
    ) {
        self.sections = sections
        self.style = style
        self.snapPolicy = snapPolicy
        self.delegate = delegate
    }

    // MARK: - UIViewControllerRepresentable

    /// Creates the coordinator delegate (the bridge from UIKit callbacks to SwiftUI).
    ///
    /// - Returns: A coordinator retained by SwiftUI.
    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Creates the UIKit core of the panorama.
    ///
    /// - Parameter context: The SwiftUI context.
    /// - Returns: A configured ``TesseraPanoramaViewController``.
    public func makeUIViewController(context: Context) -> TesseraPanoramaViewController {
        let panorama = TesseraPanoramaViewController(sections: sections, style: style)
        panorama.snapPolicy = snapPolicy
        panorama.delegate = context.coordinator
        context.coordinator.panoramaViewController = panorama
        return panorama
    }

    /// Updates the sections, style, and snapping policy of an existing controller.
    ///
    /// A full rebuild (`reload`) happens only when the `id`s or
    /// titles change; otherwise new content reaches the loaded sections in place.
    /// The style and snapping policy are always passed; the core skips an identical style.
    ///
    /// - Parameters:
    ///   - uiViewController: The live ``TesseraPanoramaViewController``.
    ///   - context: The SwiftUI context with the coordinator.
    public func updateUIViewController(
        _ uiViewController: TesseraPanoramaViewController,
        context: Context
    ) {
        // The coordinator keeps the latest version of the description: otherwise the delegate would see
        // stale state after SwiftUI redraws.
        context.coordinator.parent = self
        context.coordinator.panoramaViewController = uiViewController

        uiViewController.delegate = context.coordinator
        uiViewController.style = style
        uiViewController.snapPolicy = snapPolicy

        // The same set of ids/titles: content is updated in place, without stopping scrolling
        // or resetting the shown section; otherwise reload with reuse by id.
        uiViewController.updateContent(of: sections)
    }

    // MARK: - Coordinator

    /// The UIKit core's delegate that forwards events to ``TesseraPanoramaDelegate``.
    ///
    /// It lives as long as the view: SwiftUI retains it, so the
    /// weak reference `TesseraPanoramaViewController.delegate` does not lose the observer
    /// between redraws.
    public final class Coordinator: NSObject, TesseraPanoramaDelegate {

        /// The latest description from SwiftUI: the source of the delegate and state.
        fileprivate var parent: TesseraPanoramaView

        /// The core this coordinator is bound to. Weak: the controller is already
        /// retained by the SwiftUI hierarchy.
        fileprivate weak var panoramaViewController: TesseraPanoramaViewController?

        /// Creates a coordinator over a panorama description.
        ///
        /// - Parameter parent: The description from `makeCoordinator()`.
        fileprivate init(parent: TesseraPanoramaView) {
            self.parent = parent
            super.init()
        }

        /// Forwards a section change to the external delegate.
        ///
        /// - Parameters:
        ///   - panorama: The panorama that emitted the event.
        ///   - index: The index of the shown section in reading order.
        public func panorama(_ panorama: TesseraPanoramaViewController, didShowSectionAt index: Int) {
            parent.delegate?.panorama(panorama, didShowSectionAt: index)
        }

        /// Forwards continuous progress to the external delegate.
        ///
        /// - Parameters:
        ///   - panorama: The panorama that emitted the event.
        ///   - t: The normalized progress in reading order.
        public func panorama(_ panorama: TesseraPanoramaViewController, didChangeProgress t: CGFloat) {
            parent.delegate?.panorama(panorama, didChangeProgress: t)
        }
    }
}
#endif
