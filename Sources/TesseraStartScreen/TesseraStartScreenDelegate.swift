// The start screen delegate.
//
// Design document: docs/STARTSCREEN-IOS-DESIGN.md
//  - §2 (architecture): `TesseraStartScreenDelegate` carries start screen events (taps, page
//    transitions, the hook); the model and the layout live separately;
//  - §6 (the right page: app list + settings) and §7 (the left page: the hook): tile actions and
//    navigation are the host's concern, the component only reports intent;
//  - §9 (Accessibility): accessibility of tiles, edit mode and page announcements is handled by the
//    UIKit core (`TesseraTileGridView`, `TesseraTileEditCoordinator`,
//    `TesseraStartScreenViewController`); the delegate is an observer and neither duplicates nor
//    announces anything;
//  - §14 (MVP clarifications) and D12/D13 in docs/STATE.md: a shortcut is just an action (no `type`
//    field), side pages are optional.
//
// The delegate is the only event channel of the facade: the UIKit core reports grid taps and pager
// transitions, and the facade translates them into this protocol. All methods are called on the main
// thread; there are no required methods, so the host subscribes only to the events it needs (empty
// implementations are in the extension).

#if canImport(UIKit)
import UIKit

/// An observer of start screen events (docs/STARTSCREEN-IOS-DESIGN.md §2).
///
/// The delegate only reads state and reacts to user actions: it does not change the model
/// (`TesseraTileStore`) or the layout (`TileGridView`). This is the "single writer" rule from §6
/// and `docs/CORE-IOS-DESIGN.md` §2. To change the set of shortcuts (pin/unpin, resize, folders),
/// the host does it through `TesseraTileStore` and passes the facade a new grid snapshot.
///
/// ## What the facade does NOT do by itself (D12)
///
/// A tap on a shortcut is the ``startScreen(_:didTapShortcut:)`` event, **not** a call to
/// `TesseraTileDescriptor.action`. The host runs the shortcut action: this keeps D12 ("a shortcut is
/// just an action") in one place, and lets the host add analytics, double-tap protection or
/// navigation before running the action. If the facade also called `action`, the action would run
/// twice.
///
/// ```swift
/// final class Host: TesseraStartScreenDelegate {
///     func startScreen(
///         _ screen: TesseraStartScreenViewController,
///         didTapShortcut shortcut: TesseraTileDescriptor
///     ) {
///         shortcut.action()
///     }
/// }
/// ```
///
/// ## Accessibility (§9)
///
/// A VoiceOver activation of a tile arrives the same way as a finger tap (the cell's
/// `accessibilityActivate` -> the grid's `onTap`), so the delegate does not need to distinguish
/// input methods:
///
/// - a tile is a single element with a title and a badge counter;
/// - in edit mode `resize`/`unpin` are available as `UIAccessibilityCustomAction`, and entering and
///   leaving are announced;
/// - paging with the VoiceOver gesture and announcing the page name are done by the controller; the
///   facade only does not override this behavior, forwarding pager events to the controller.
///
/// - Note: In edit mode the grid keeps reporting taps: the edit coordinator does not intercept them.
///   If the host attached `TesseraTileEditCoordinator`, it decides whether to react using its own
///   `isEditing` (docs/STARTSCREEN-IOS-DESIGN.md §5).
///
/// - Note: The facade holds the delegate with a strong reference (a SwiftUI struct cannot store a
///   `weak` one). If the delegate holds SwiftUI state, use an intermediate object to avoid a cycle.
public protocol TesseraStartScreenDelegate: AnyObject {

    /// The user selected a shortcut (finger tap or VoiceOver activation).
    ///
    /// The shortcut comes from the grid snapshot, with its identifier, title, icon, badge, size and
    /// action (D12). The facade does **not** call `TesseraTileDescriptor.action`: that is the host's
    /// decision (see the protocol documentation). Folders arrive as a separate event,
    /// ``startScreen(_:didTapFolder:)``.
    ///
    /// - Parameters:
    ///   - screen: The controller that is the source of the event.
    ///   - shortcut: The selected shortcut.
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didTapShortcut shortcut: TesseraTileDescriptor
    )

    /// The user selected a folder on the grid.
    ///
    /// Opening a folder is host navigation (D14): the facade does not show its own folder screen. If
    /// the host uses `TesseraTileEditCoordinator`, it can pass the folder to
    /// ``TesseraTileEditCoordinator/openFolder(_:)``; otherwise it shows its own controller.
    ///
    /// - Note: Since D17, by default the folder is additionally expanded by the grid's native
    ///   panel, so the event means "a finger touched the folder", not a command to show a screen. To
    ///   keep the previous behavior (a custom screen without the built-in panel), set an interceptor
    ///   in `TesseraStartScreenView`.
    ///
    /// - Parameters:
    ///   - screen: The controller that is the source of the event.
    ///   - folder: The selected folder with its shortcuts.
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didTapFolder folder: TesseraTileFolder
    )

    /// The grid expanded a folder with the native panel (D17).
    ///
    /// The event arrives after the expansion animation: the panel is already inserted, the rows below
    /// are shifted, and the icons start their cascade. The host can use it for analytics or to sync
    /// its own state; there is no need to change the grid snapshot in the callback, because the
    /// expansion is already done.
    ///
    /// - Parameters:
    ///   - screen: The controller that is the source of the event.
    ///   - folder: The expanded folder.
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didExpandFolder folder: TesseraTileFolder
    )

    /// The grid collapsed the native folder panel (D17).
    ///
    /// It arrives both when the panel is closed by a repeated tap, a tap on empty space, a call to
    /// ``TesseraTileGridView/closeFolder(animated:)`` or `Back`, and when the open folder disappears
    /// from the snapshot (the model dissolved the folder).
    ///
    /// - Parameters:
    ///   - screen: The controller that is the source of the event.
    ///   - folder: The collapsed folder.
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didCollapseFolder folder: TesseraTileFolder
    )

    /// The pager finished a transition and shows a new page.
    ///
    /// The index is in reading order (Core normalizes it for RTL): `0` is the first page for the
    /// user, regardless of LTR/RTL. The set of pages depends on the configuration (D13): side pages
    /// exist only if the host provided them, so index `0` is either the hook or START.
    ///
    /// The event arrives when a transition completes (by gesture or programmatically), not on scroll
    /// frames: the start screen does not need continuous progress, and per-frame calls would make
    /// SwiftUI redraw on every frame.
    ///
    /// - Parameters:
    ///   - screen: The controller that is the source of the event.
    ///   - page: The page now shown, in reading order.
    ///   - index: The page index in reading order.
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didChangePage page: TesseraStartScreenPage,
        index: Int
    )

    /// The visibility of the hook page changed (§7).
    ///
    /// `true` means the hook is on screen now (the user pages the pager or the host showed it
    /// programmatically), `false` means it left the screen. The event is for lazy loading of hook
    /// content at the screen level; ``TesseraQuickPanelProviding`` itself additionally receives
    /// `quickPanelWillAppear` / `quickPanelDidDisappear` from the controller, so those are usually
    /// enough.
    ///
    /// The event arrives only when the value changes: on the first transition to START, if the hook
    /// was never shown, there is no call.
    ///
    /// - Parameters:
    ///   - screen: The controller that is the source of the event.
    ///   - isVisible: `true` if the hook page is on screen now.
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didChangeHookVisibility isVisible: Bool
    )
}

public extension TesseraStartScreenDelegate {

    /// By default a tap on a shortcut is ignored: the host subscribes selectively to the events it
    /// needs (docs/STARTSCREEN-IOS-DESIGN.md §2).
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didTapShortcut shortcut: TesseraTileDescriptor
    ) {}

    /// By default a folder is not opened: navigation is up to the host (D14).
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didTapFolder folder: TesseraTileFolder
    ) {}

    /// By default the delegate is not interested in folder expansion (D17).
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didExpandFolder folder: TesseraTileFolder
    ) {}

    /// By default the delegate is not interested in folder collapse (D17).
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didCollapseFolder folder: TesseraTileFolder
    ) {}

    /// By default the delegate is not interested in page changes.
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didChangePage page: TesseraStartScreenPage,
        index: Int
    ) {}

    /// By default the delegate is not interested in hook visibility.
    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didChangeHookVisibility isVisible: Bool
    ) {}
}
#endif
