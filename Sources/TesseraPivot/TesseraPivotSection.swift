// The Pivot section model.
// Design document: docs/PIVOT-IOS-DESIGN.md (architecture:
// TesseraPivotSection is an id, a title, and a content factory; target UX properties:
// full-screen pages, a header strip on top).

#if canImport(UIKit)
import UIKit
import TesseraCore

/// Describes a single pivot section: a page of the full-screen pager
/// (see docs/PIVOT-IOS-DESIGN.md).
///
/// Sections are passed in reading order: the first element of the array is the first
/// page for the user. In RTL the order of headers in the strip and the swipe direction
/// are mirrored by the component, not by the model (see the RTL notes in the design document).
///
/// Content is provided through ``TesseraContentProviding`` from TesseraCore,
/// so the section does not know whether it is UIKit or a SwiftUI facade: the controller is created
/// on the first request and reused by hosting during lazy ±1 loading
/// (see lazy page loading in the design document).
///
/// - Important: `id` must be unique within a single pivot: hosting uses it
///   to reuse the content controller. Behavior with duplicate
///   identifiers is undefined.
/// - Note: All methods and properties are intended for the main thread: the component does not
///   spread UI state across modules (docs/CORE-IOS-DESIGN.md).
public struct TesseraPivotSection {
    /// A stable section identifier.
    ///
    /// Used to reuse the controller through
    /// ``TesseraContentHosting``: as long as the identifier is present in the pivot,
    /// hosting may return the same controller instance
    /// (see lazy page loading in docs/PIVOT-IOS-DESIGN.md).
    public let id: AnyHashable

    /// The section title in the strip.
    ///
    /// The component builds the accessibility text and the announcement on a section
    /// change from it (see the VoiceOver notes in the design document).
    public let title: String

    /// The provider of the section's content controller.
    public let content: TesseraContentProviding

    /// Creates a section with a ready content provider.
    ///
    /// - Parameters:
    ///   - id: A section identifier unique within the pivot.
    ///   - title: The section title.
    ///   - content: A `UIViewController` provider (UIKit or a SwiftUI facade).
    public init(id: AnyHashable, title: String, content: TesseraContentProviding) {
        self.id = id
        self.title = title
        self.content = content
    }

    /// Creates a section on top of a UIKit controller factory.
    ///
    /// The counterpart of a convenience initializer: a struct does not support
    /// `convenience init`, so this is an ordinary additional initializer.
    /// The closure is wrapped in ``TesseraViewControllerProvider`` and called
    /// lazily, when the pivot first requests the page
    /// (see lazy page loading in docs/PIVOT-IOS-DESIGN.md).
    ///
    /// - Parameters:
    ///   - id: A section identifier unique within the pivot.
    ///   - title: The section title.
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
