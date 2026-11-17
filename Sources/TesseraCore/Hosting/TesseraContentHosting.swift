// TesseraCore content hosting: the reuse registry and the state bridge
// (the `TesseraStateBridge` bridge is deprecated and will be removed in a major release).
// Design document: docs/CORE-IOS-DESIGN.md (package composition;
// conceptual API surface).

#if canImport(UIKit)
import UIKit
#endif

#if canImport(Combine)
import Combine

/// A state bridge between the UIKit core and the SwiftUI facades
/// (docs/CORE-IOS-DESIGN.md: "state bridge via `ObservableObject`").
///
/// iOS 15 does not support `@Observable`, so state is passed
/// through `ObservableObject`: the SwiftUI facade subscribes to the bridge, and the core notifies
/// it with the `update(_:)` method. `@Published` itself tells SwiftUI about the change,
/// so no separate notification channel is needed (no notifications "into the void").
///
/// The bridge does not copy the object or replace its observability: the facade receives
/// the original `Object`, and the bridge only publishes the fact that it was replaced.
///
/// - Important: **Deprecated.** No TesseraKit component uses the bridge:
///   the Pivot, Panorama, and StartScreen facades pass state
///   directly through `UIViewControllerRepresentable` and their own
///   `ObservableObject`s. The type violates the rule of three for Core (a mechanism belongs in Core
///   only if at least two components need it), so it is marked
///   `@available(*, deprecated)` and will be removed in the next major release
///   (the public surface of Core changes only through deprecation).
///   The replacement is your own `ObservableObject` on the app side or
///   `@ObservedObject` directly on the original object.
@available(*, deprecated, message: "TesseraStateBridge is not used by TesseraKit components and will be removed in the next major release. Observe the original ObservableObject directly (@ObservedObject / @StateObject).")
public final class TesseraStateBridge<Object: ObservableObject>: ObservableObject {
    /// The current observed object. It changes only through `init(_:)` and `update(_:)`,
    /// so the facade cannot silently swap the source of state.
    @Published public private(set) var object: Object

    /// Creates a bridge over an existing observable object.
    public init(_ object: Object) {
        self.object = object
    }

    /// Publishes a replacement of the observed object.
    ///
    /// The SwiftUI facade is notified through `objectWillChange` and redraws.
    public func update(_ object: Object) {
        self.object = object
    }
}
#endif

#if canImport(UIKit)
/// The reuse registry for content controllers
/// (docs/CORE-IOS-DESIGN.md: package composition and conceptual API surface).
///
/// One `id`, one controller: a repeated request returns the same instance
/// instead of creating a new one. For `TesseraSwiftUIContentProvider`, a repeated request
/// updates the `rootView` of the existing `UIHostingController`: hosting
/// is reused across hierarchy rebuilds, and the controller is not recreated.
///
/// The registry is part of the UIKit core: SwiftUI facades pass providers here
/// and get back ordinary `UIViewController`s.
///
/// - Important:
///   - Works only on the main thread: UI state is not spread across modules.
///   - Holds strong references to the controllers: release them through
///     `removeContent(for:)` or `removeAll()` when the content is no longer needed.
public final class TesseraContentHosting {
    /// Controllers by identifier: the dictionary itself is the "one id, one controller" contract.
    private var controllers: [AnyHashable: UIViewController] = [:]

    /// Creates an empty registry.
    public init() {}

    /// Returns the controller for `id`, creating it on the first request.
    ///
    /// A repeated request with the same `id` does not create a new controller:
    /// for a SwiftUI provider the `rootView` is updated, and other providers
    /// return the already created instance unchanged.
    ///
    /// - Parameters:
    ///   - id: The content identifier (for example, a pager page identifier).
    ///   - provider: The content factory; called only on the first request.
    /// - Returns: The same controller instance for the same `id`.
    ///
    /// - Note: Changing the provider or the content type for an occupied `id` is not supported
    ///   (the registry keeps the first controller): remove the entry with `removeContent(for:)`
    ///   and request the content again.
    public func viewController(
        for id: AnyHashable,
        provider: TesseraContentProviding
    ) -> UIViewController {
        if let existing = controllers[id] {
            // Repeated request: a SwiftUI provider updates its rootView in place.
            // Other providers cannot update an arbitrary controller, so
            // return the stored instance, preserving the "one id, one controller" invariant.
            _ = (provider as? TesseraContentUpdating)?.updateContent(of: existing)
            return existing
        }

        let controller = provider.makeContentViewController()
        controllers[id] = controller
        return controller
    }

    /// Removes the controller for `id` from the registry.
    ///
    /// The controller itself is not forcibly destroyed: the registry only stops
    /// holding a strong reference to it; the next request creates a new instance.
    public func removeContent(for id: AnyHashable) {
        controllers.removeValue(forKey: id)
    }

    /// Clears the registry: no controller is reused any more.
    public func removeAll() {
        controllers.removeAll()
    }
}
#endif
