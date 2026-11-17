// The Panorama section model.
// Design document: docs/PANORAMA-IOS-DESIGN.md (conceptual architecture:
// the data model, where TesseraPanoramaSection is an identifier, a title, and a content factory;
// vertical scrolling inside a section: a section is a child view controller with its own scroll).

#if canImport(UIKit)
import UIKit
import TesseraCore

/// Describes a single panorama section: a "canvas" that is paged horizontally.
///
/// Sections are passed in reading order: the first element of the array is the first section
/// for the user. In RTL the order and the snapping direction are mirrored by the component,
/// not by the model (see the RTL notes in docs/PANORAMA-IOS-DESIGN.md).
///
/// Content is provided through ``TesseraContentProviding`` from TesseraCore, so the
/// section does not know whether it is UIKit or a SwiftUI facade. The content controller
/// becomes a child view controller and keeps its own vertical position; the component
/// keeps the current section and its ±1 neighbors in memory and creates the others
/// lazily.
///
/// - Important: `id` must be unique within a single panorama: hosting uses it
///   to reuse the content controller. Behavior with duplicate
///   identifiers is undefined.
/// - Note: All methods and properties are intended for the main thread: the component does not
///   spread UI state across modules (docs/CORE-IOS-DESIGN.md).
public struct TesseraPanoramaSection {
    /// A stable section identifier.
    ///
    /// Used to reuse the controller through
    /// ``TesseraContentHosting``: as long as the identifier is present in the panorama,
    /// hosting may return the same controller instance
    /// (see lazy loading in docs/PANORAMA-IOS-DESIGN.md).
    public let id: AnyHashable

    /// The section title.
    ///
    /// The title is drawn above the section and animated by the progress `t`
    /// (see the headers notes in the design document) and is used for accessibility when the
    /// section changes (see the VoiceOver notes in the design document).
    public let title: String

    /// The provider of the section's content controller.
    public let content: TesseraContentProviding

    /// Creates a section with a ready content provider.
    ///
    /// - Parameters:
    ///   - id: A section identifier unique within the panorama.
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
    /// lazily, when the panorama first requests the section
    /// (see lazy loading in docs/PANORAMA-IOS-DESIGN.md).
    ///
    /// - Parameters:
    ///   - id: A section identifier unique within the panorama.
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
