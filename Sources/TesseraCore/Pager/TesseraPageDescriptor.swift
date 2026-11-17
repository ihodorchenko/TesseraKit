// Page descriptor for the TesseraCore pager.
// Design document: docs/CORE-IOS-DESIGN.md (key contracts:
// the progress invariant and the single writer of contentOffset; conceptual
// API surface: TesseraPageDescriptor is an id, a title, and makeContent()).

#if canImport(UIKit)
import UIKit

/// Describes a single page of `TesseraPagerViewController`.
///
/// Pages are passed in reading order: the first element of the array is the first
/// page for the user. In RTL the pager mirrors the physical layout and
/// normalizes the index and progress through `TesseraRTL`
/// (see the progress invariant in docs/CORE-IOS-DESIGN.md).
///
/// - Important: `id` must be unique within a single pager: `TesseraContentHosting`
///   uses it to reuse the content controller. Behavior with
///   duplicate identifiers is undefined.
/// - Note: All methods and properties are intended for the main thread: Core does not
///   spread UI state across modules (docs/CORE-IOS-DESIGN.md).
public struct TesseraPageDescriptor {
    /// A stable page identifier.
    ///
    /// Used to reuse the controller through
    /// `TesseraContentHosting`: as long as the identifier is present in the pager,
    /// hosting may return the same controller instance.
    public let id: AnyHashable

    /// The page title.
    ///
    /// The pager stores the title as part of the page description; components build
    /// accessibility text and captions from it themselves.
    public let title: String

    /// The provider of the page's content controller.
    public let content: TesseraContentProviding

    /// Creates a page descriptor with a ready content provider.
    ///
    /// - Parameters:
    ///   - id: A page identifier unique within the pager.
    ///   - title: The page title.
    ///   - content: A `UIViewController` provider (UIKit or a SwiftUI facade).
    public init(id: AnyHashable, title: String, content: TesseraContentProviding) {
        self.id = id
        self.title = title
        self.content = content
    }

    /// Creates a page descriptor on top of a UIKit controller factory.
    ///
    /// The counterpart of a convenience initializer: a struct does not support
    /// `convenience init`, so this is an ordinary additional initializer.
    /// The closure is wrapped in ``TesseraViewControllerProvider`` and called
    /// lazily, when the pager first requests the page.
    ///
    /// - Parameters:
    ///   - id: A page identifier unique within the pager.
    ///   - title: The page title.
    ///   - makeContent: The content controller factory; called on the main thread.
    public init(
        id: AnyHashable,
        title: String,
        makeContent: @escaping () -> UIViewController
    ) {
        self.init(
            id: id,
            title: title,
            content: TesseraViewControllerProvider(makeContent)
        )
    }
}
#endif
