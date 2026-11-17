//
//  TesseraPivotView.swift
//  TesseraPivot
//
//  The SwiftUI facade of the pivot.
//  Contract: docs/PIVOT-IOS-DESIGN.md (choice of foundation: a UIKit core +
//  a SwiftUI facade via `UIViewControllerRepresentable`; architecture:
//  a declarative API of sections, style, and delegate; accessibility: the state
//  bridge is only an `ObservableObject`, since iOS 15 does not support the
//  Observable macro).
//
//  The facade does not duplicate mechanics: it only creates and updates
//  `TesseraPivotViewController`. All synchronization of the strip and the pager, gesture arbitration, and
//  accessibility live in the UIKit core.
//

#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit

/// The SwiftUI view of the pivot (see docs/PIVOT-IOS-DESIGN.md).
///
/// A wrapper over ``TesseraPivotViewController``: SwiftUI describes the state
/// declaratively, while the UIKit core performs the continuous synchronization of the strip with
/// `contentOffset`; on iOS 15, pure SwiftUI does not expose the progress of a page drag,
/// so the indicator could not follow the finger.
///
/// ```swift
/// TesseraPivotView(
///     sections: [
///         TesseraPivotSection(id: "home", title: "Home") { HomeViewController() },
///         TesseraPivotSection(id: "news", title: "News") { NewsViewController() },
///     ],
///     style: TesseraPivotStyle(appTitle: "My App")
/// )
/// ```
///
/// ## Updates
///
/// - ``TesseraPivotStyle`` is applied on every update; the strip setters in the core
///   compare values with the previous ones, so there is no redundant cell reloading;
/// - when the set of `id`s or titles changes, the sections are rebuilt immediately
///   (`reload(sections:)`);
///   (`reload(sections:)`);
/// - with the same `id`s and titles, new content still reaches the
///   pages: content providers (`TesseraContentProviding`) cannot be compared,
///   so the sections are passed to the core on every update. The pager reuses controllers whose
///   `id` survives and updates the `rootView` of SwiftUI pages in place, so the current page,
///   scroll position, and `@State` of the content are preserved. During a gesture, inertia, or
///   an animated transition, the update is deferred until it finishes
///   so as not to cut the motion short;
/// - the progress callback is not called synchronously inside
///   `updateUIViewController`: progress that changed during a rebuild
///   arrives on the next pass of the main queue.
///
/// ## Delegate
///
/// `TesseraPivotDelegate` is a class-bound protocol, and a SwiftUI struct cannot
/// hold a `weak` reference. The facade therefore hands the delegate to a coordinator,
/// which retains the latest `TesseraPivotView` value and forwards all three
/// callbacks. The delegate is held by a strong reference while the view is
/// installed: if it holds SwiftUI state itself, use an intermediate
/// object to avoid a retain cycle.
public struct TesseraPivotView: UIViewControllerRepresentable {

    /// The sections in reading order (see docs/PIVOT-IOS-DESIGN.md).
    private let sections: [TesseraPivotSection]

    /// The appearance: the strip fonts and colors, the indicator style, the width mode,
    /// the large app title.
    private let style: TesseraPivotStyle

    /// The observer of selection, progress, and section changes.
    private let delegate: TesseraPivotDelegate?

    /// Creates the pivot facade.
    ///
    /// - Parameters:
    ///   - sections: The sections in reading order; the first element is the first page
    ///     for the user (in RTL the core mirrors the order).
    ///   - style: The appearance; the system default if omitted.
    ///   - delegate: The state observer; optional.
    public init(
        sections: [TesseraPivotSection],
        style: TesseraPivotStyle = TesseraPivotStyle(),
        delegate: TesseraPivotDelegate? = nil
    ) {
        self.sections = sections
        self.style = style
        self.delegate = delegate
    }

    // MARK: - UIViewControllerRepresentable

    /// Creates the coordinator delegate (the bridge from UIKit callbacks to SwiftUI).
    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Creates the UIKit core of the pivot.
    ///
    /// - Parameter context: The SwiftUI context.
    /// - Returns: A configured ``TesseraPivotViewController``.
    public func makeUIViewController(context: Context) -> TesseraPivotViewController {
        let pivot = TesseraPivotViewController(sections: sections, style: style)
        pivot.delegate = context.coordinator
        context.coordinator.pivotViewController = pivot
        return pivot
    }

    /// Updates the sections and style of an existing controller.
    ///
    /// A structural change (`id`s or titles) triggers an immediate `reload`; the same
    /// set updates content through
    /// ``TesseraPivotViewController/refreshSectionContent(_:)`` (deferred
    /// while pages are moving). The style is always applied; its setters in
    /// the core are idempotent.
    ///
    /// - Parameters:
    ///   - uiViewController: The live ``TesseraPivotViewController``.
    ///   - context: The SwiftUI context with the coordinator.
    public func updateUIViewController(
        _ uiViewController: TesseraPivotViewController,
        context: Context
    ) {
        // The coordinator keeps the latest version of the description: otherwise the delegate would see
        // stale state after SwiftUI redraws.
        context.coordinator.parent = self
        context.coordinator.pivotViewController = uiViewController

        uiViewController.delegate = context.coordinator
        uiViewController.style = style

        if Self.sectionsDiffer(uiViewController.sections, sections) {
            uiViewController.reload(sections: sections)
        } else {
            uiViewController.refreshSectionContent(sections)
        }
    }

    /// Compares the structure of the section sets.
    ///
    /// `TesseraPivotSection` is not `Equatable`: a content provider is a protocol with a factory
    /// that has no equality semantics. The structure is therefore defined by the
    /// `id` + `title` pair; when they match, content is updated by a separate path
    /// (see the documentation of ``TesseraPivotView``).
    ///
    /// - Parameters:
    ///   - lhs: The controller's current sections.
    ///   - rhs: The new sections from SwiftUI.
    /// - Returns: `true` if a `reload` is required.
    private static func sectionsDiffer(
        _ lhs: [TesseraPivotSection],
        _ rhs: [TesseraPivotSection]
    ) -> Bool {
        guard lhs.count == rhs.count else { return true }

        for (current, updated) in zip(lhs, rhs) {
            if current.id != updated.id || current.title != updated.title {
                return true
            }
        }
        return false
    }

    // MARK: - Coordinator

    /// The UIKit core's delegate that forwards events to `TesseraPivotDelegate`.
    ///
    /// It lives as long as the view: SwiftUI retains it, so the
    /// weak reference `TesseraPivotViewController.delegate` does not lose the observer between
    /// redraws.
    public final class Coordinator: NSObject, TesseraPivotDelegate {

        /// The latest description from SwiftUI: the source of the delegate and state.
        fileprivate var parent: TesseraPivotView

        /// The core this coordinator is bound to. Weak: the controller is already
        /// retained by the SwiftUI hierarchy.
        fileprivate weak var pivotViewController: TesseraPivotViewController?

        /// Creates a coordinator over a pivot description.
        ///
        /// - Parameter parent: The description from `makeCoordinator()`.
        fileprivate init(parent: TesseraPivotView) {
            self.parent = parent
            super.init()
        }

        /// Forwards a section selection to the external delegate.
        ///
        /// - Parameters:
        ///   - pivot: The pivot that emitted the event.
        ///   - index: The index of the selected section in reading order.
        public func pivot(_ pivot: TesseraPivotViewController, didSelectSectionAt index: Int) {
            parent.delegate?.pivot(pivot, didSelectSectionAt: index)
        }

        /// Forwards continuous progress to the external delegate.
        ///
        /// - Parameters:
        ///   - pivot: The pivot that emitted the event.
        ///   - t: The normalized progress in reading order.
        public func pivot(_ pivot: TesseraPivotViewController, didChangeProgress t: CGFloat) {
            parent.delegate?.pivot(pivot, didChangeProgress: t)
        }

        /// Forwards transition completion to the external delegate.
        ///
        /// - Parameters:
        ///   - pivot: The pivot that emitted the event.
        ///   - index: The index of the shown section in reading order.
        public func pivot(_ pivot: TesseraPivotViewController, didShowSectionAt index: Int) {
            parent.delegate?.pivot(pivot, didShowSectionAt: index)
        }
    }
}
#endif
