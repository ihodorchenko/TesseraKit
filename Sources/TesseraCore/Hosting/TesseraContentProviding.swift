// TesseraCore content hosting: the content provider contract.
// Design document: docs/CORE-IOS-DESIGN.md (package composition;
// conceptual API surface).
//
// Hosting is part of the UIKit core, so the types in this file are available only on platforms with UIKit.
// On a macOS host, where SwiftPM builds the package for `swift build`, the file compiles
// empty: this keeps the core buildable outside iOS while the public surface on iOS is unchanged.

#if canImport(UIKit)
import UIKit
import SwiftUI

/// A content provider for Core containers (docs/CORE-IOS-DESIGN.md: conceptual API surface).
///
/// Lets the pager and other containers obtain a `UIViewController` without knowing whether
/// it is UIKit or a SwiftUI facade. A controller is returned rather than a `UIView`
/// so that the container can use child view controller containment.
///
/// - Important: The method is called on the main thread: all UI work in Core is
///   main-thread, and state is not spread across modules.
public protocol TesseraContentProviding {
    /// Creates a new content controller.
    ///
    /// The controller is created on the first request for an `id` in `TesseraContentHosting`
    /// and again after `TesseraContentHosting.removeContent(for:)`/`removeAll()`.
    func makeContentViewController() -> UIViewController
}

/// A `TesseraContentProviding` implementation for UIKit content.
///
/// A thin wrapper over a factory: Core does not impose a base class on the controller,
/// so any `UIViewController` works (docs/CORE-IOS-DESIGN.md: conceptual API surface).
public struct TesseraViewControllerProvider: TesseraContentProviding {
    private let makeViewController: () -> UIViewController

    /// - Parameter makeViewController: The controller factory; called on the main thread.
    public init(_ makeViewController: @escaping () -> UIViewController) {
        self.makeViewController = makeViewController
    }

    public func makeContentViewController() -> UIViewController {
        makeViewController()
    }
}

/// A `TesseraContentProviding` implementation for SwiftUI content
/// (docs/CORE-IOS-DESIGN.md).
///
/// Wraps `Content` in a `UIHostingController`: SwiftUI is allowed only
/// in the facades, so the UIKit core sees an ordinary `UIViewController`.
public struct TesseraSwiftUIContentProvider<Content: View>: TesseraContentProviding {
    private let makeContent: () -> Content

    /// - Parameter makeContent: The SwiftUI content factory; called on the main thread.
    public init(_ makeContent: @escaping () -> Content) {
        self.makeContent = makeContent
    }

    public func makeContentViewController() -> UIViewController {
        UIHostingController(rootView: makeContent())
    }
}

/// An internal contract for updating content without recreating the controller.
///
/// Not part of Core's public surface: from outside, hosting works only through
/// `TesseraContentProviding` (delegate-driven, with a minimal public surface).
protocol TesseraContentUpdating {
    /// Tries to update the content of an existing controller.
    ///
    /// - Returns: `true` if the controller was created by this provider and updated;
    ///   `false` if the content type did not match and the controller should be left as is.
    func updateContent(of viewController: UIViewController) -> Bool
}

extension TesseraSwiftUIContentProvider: TesseraContentUpdating {
    func updateContent(of viewController: UIViewController) -> Bool {
        guard let hostingController = viewController as? UIHostingController<Content> else {
            return false
        }

        // Replacing rootView makes SwiftUI rebuild the hierarchy in place:
        // the UIHostingController itself and its identity are preserved, and no new hosting is created.
        hostingController.rootView = makeContent()
        return true
    }
}
#endif
