//
//  TesseraStartScreenView.swift
//  TesseraStartScreen
//
//  The SwiftUI facade of the start screen.
//  Contract: docs/STARTSCREEN-IOS-DESIGN.md, §2 (architecture: TesseraStartScreenView ->
//  StartScreenViewController; TesseraStartScreenDelegate carries tap and transition events), §3
//  (the tile grid: the grid snapshot is the only data input), §6 (the right page) and §7 (the left
//  page; side pages exist only if the host provided them, D13), §8 (background parallax: wallpaper
//  and multiplier), §9 (Accessibility: VoiceOver, Dynamic Type, RTL) and §14 (MVP clarifications;
//  D12–D15 in docs/STATE.md).
//
//  Responsibilities:
//  - the facade does not duplicate mechanics: the pager, the grid, parallax, edit mode and folders
//    live in the UIKit core, while the SwiftUI struct only creates and updates
//    `TesseraStartScreenViewController` and translates its events into
//    `TesseraStartScreenDelegate` (the same as `TesseraPivotView`);
//  - data arrives by value as a `TesseraTileGridSnapshot`; the facade does not own
//    `TesseraTileStore` and does not subscribe to it (the "single writer" rule, §6);
//  - `updateUIViewController` is the only place where the configuration is applied: each field is
//    compared with the controller's current state, so a SwiftUI redraw does not reload pages and
//    does not recreate the pager.
//
//  iOS 15 APIs only: `UIViewControllerRepresentable` and a plain `ObservableObject` in the core;
//  `@Observable`, `@Entry` and other APIs newer than iOS 15 are not used.
//

#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit
import TesseraCore

// MARK: - Style

/// The start screen appearance (docs/STARTSCREEN-IOS-DESIGN.md §8, §9).
///
/// A style is a value: the facade applies it on every update, and the controller setters are
/// idempotent, so setting the same values again does not touch the hierarchy and does not restart
/// animations.
///
/// Page titles are needed by VoiceOver (§9): the controller announces the page name when a
/// transition completes. Inside the component the default strings are English (the values match the
/// defaults of ``TesseraStartScreenViewController``); the host localizes them by passing its own
/// style.
public struct TesseraStartScreenStyle {

    /// The start screen wallpaper (§8).
    ///
    /// `nil` (the default) means no wallpaper: the system page backdrop is visible. The facade
    /// compares wallpapers by reference: pass a stable `UIImage` instance, otherwise the image is
    /// reassigned on every redraw.
    public var wallpaper: UIImage?

    /// The wallpaper parallax multiplier (§8).
    ///
    /// The document defines the range `0.4...0.6`; the core clamps the value to the nearest bound,
    /// and `NaN` is treated as `0.5`. Under Reduce Motion the effective multiplier is zero (§9), but
    /// the background overscan is computed from the configured value, so turning the setting on live
    /// leaves no empty strips.
    public var wallpaperParallaxFactor: CGFloat

    /// The hook page title for VoiceOver (§7, §9).
    public var quickPanelTitle: String

    /// The START page title for VoiceOver (§9).
    public var startPageTitle: String

    /// The right page (app list) title for VoiceOver (§6, §9).
    public var applicationsPageTitle: String

    /// Creates a start screen style.
    ///
    /// - Parameters:
    ///   - wallpaper: The wallpaper; none by default.
    ///   - wallpaperParallaxFactor: The parallax multiplier, `0.5` by default.
    ///   - quickPanelTitle: The hook page title, the controller's default by default.
    ///   - startPageTitle: The START page title, the controller's default by default.
    ///   - applicationsPageTitle: The right page title, the controller's default by default.
    public init(
        wallpaper: UIImage? = nil,
        wallpaperParallaxFactor: CGFloat = 0.5,
        quickPanelTitle: String = "Quick panel",
        startPageTitle: String = "Start",
        applicationsPageTitle: String = "Applications"
    ) {
        self.wallpaper = wallpaper
        self.wallpaperParallaxFactor = wallpaperParallaxFactor
        self.quickPanelTitle = quickPanelTitle
        self.startPageTitle = startPageTitle
        self.applicationsPageTitle = applicationsPageTitle
    }
}

// MARK: - Facade

/// The SwiftUI view of the start screen (docs/STARTSCREEN-IOS-DESIGN.md §2).
///
/// A wrapper over ``TesseraStartScreenViewController``: the pager (START and two optional side
/// pages, D13), the vertical shortcut grid with wallpaper parallax, and edit mode stay in the UIKit
/// core. The facade declaratively sets the grid snapshot, the side pages and the style, and reports
/// events through ``TesseraStartScreenDelegate``.
///
/// ```swift
/// @StateObject private var store = TesseraTileStore()
///
/// var body: some View {
///     TesseraStartScreenView(
///         snapshot: store.snapshot(columns: 6),   // the grid width; cells and holes
///         style: TesseraStartScreenStyle(startPageTitle: "Start"),
///         rightPage: { TesseraAppsListPageViewController.make(store: store) },
///         delegate: host
///     )
/// }
/// ```
///
/// ## Updates
///
/// - the grid snapshot is applied only if the visible state of the items actually changed: the set,
///   sizes, captions, badges, icons, the live provider (`liveContent`, by reference), and the same
///   for shortcuts inside folders. A SwiftUI redraw does not call `reloadData` and does not reset
///   the scroll position or the VoiceOver focus. The `action` closure cannot be compared, and the
///   grid is not reloaded because of it: the delegate receives the shortcut (and the folder) from
///   the latest snapshot by `id`, that is, with the current `action`;
/// - side pages are rebuilt when they go from present to absent or back, and when the hook provider
///   type changes. A new instance of the same type (for example, a `TesseraQuickPanelProvider`
///   created in `body`) and a new `rightPage` factory do not rebuild the pager: they are swapped
///   "silently" and used the next time a page is created and for the hook callbacks. To recreate an
///   already loaded side page, recreate the view (`.id(…)`) or temporarily pass `nil`;
/// - the style is always applied, but each field is compared with the controller's current value,
///   so there are no extra layout passes. Wallpapers are compared by reference: pass a stable
///   `UIImage` instance rather than creating a new one on every redraw.
///
/// If the host also owns a `TileEditCoordinator`, it animates resize, reorder and drag itself. The
/// facade compares the snapshot with the actual grid state, so a change already applied by the
/// coordinator is not reloaded again; update the SwiftUI state after `TesseraTileStore.onChange` so
/// that the "coordinator -> SwiftUI" order is preserved.
///
/// ## Folder expansion (D17)
///
/// By default a tap on a folder expands it with the grid's built-in panel: the title (lowercase) and
/// the shortcut grid (the same column count as the desktop) appear under the folder row, the rows
/// below shift down, and the icons cascade in. A repeated tap, a tap on empty space and
/// `Back`/VoiceOver escape close the panel; the state is also cleared if the folder disappears from
/// the snapshot.
///
/// A host that shows its own folder screen must pass a `folderTapHandler` that returns `true`: the
/// native panel is then not opened and `didTapFolder` does not arrive, because the interceptor
/// itself performs the navigation. Expansion and collapse are reported to the delegate with the
/// `didExpandFolder`/`didCollapseFolder` events.
///
/// ## Delegate
///
/// ``TesseraStartScreenDelegate`` is a class-bound protocol, and a SwiftUI struct cannot store a
/// `weak` reference. So the facade passes the delegate to the coordinator, which holds the latest
/// value of ``TesseraStartScreenView`` and forwards all callbacks. The delegate is held by a strong
/// reference while the view is installed (as in `TesseraPivotView`/`TesseraPanoramaView`).
///
/// ## Accessibility (§9)
///
/// The facade does not duplicate the core's accessibility but preserves it:
///
/// - a tile is a single VoiceOver element with a title and a badge counter, entering and leaving
///   edit mode are announced, and `resize`/`unpin` are available as `UIAccessibilityCustomAction`;
/// - page transitions and hook visibility come from the controller through its UIKit
///   ``TesseraStartScreenViewController/delegate`` (the facade's coordinator is that delegate): the
///   pager is not intercepted, so `accessibilityScroll`, the page name announcement and the hook
///   page callbacks (§7, §9) work the same way as in UIKit. The controller remains the single
///   writer of its state;
/// - VoiceOver activation of a tile follows the same path as a finger tap (`gridView.onTap` ->
///   delegate), so the host handles both the same way;
/// - Dynamic Type and RTL reach UIKit from the trait environment (the system/SwiftUI hosting): the
///   facade does not fix fonts and does not force `semanticContentAttribute`, so as not to break the
///   direction set by the host. Mirroring of the grid, the pager and the jump list is done by the
///   core (§9, `TesseraRTL`);
/// - Reduce Motion is read by the core from the system (§9); the facade has no animations of its own
///   that would need to be disabled.
///
/// - Note: All callbacks and updates run on the main thread.
public struct TesseraStartScreenView: UIViewControllerRepresentable {

    // MARK: - Inputs

    /// The grid snapshot: items, their order and sizes (§3, D15).
    ///
    /// The snapshot is a value from `TesseraTileStore`: the facade only displays it.
    private let snapshot: TesseraTileGridSnapshot

    /// The wallpaper, the parallax multiplier and the page titles.
    private let style: TesseraStartScreenStyle

    /// The provider of the left hook page (§7); `nil` means no page (D13).
    private let leftPanel: TesseraQuickPanelProviding?

    /// The factory of the right page, the app list (§6); `nil` means no page (D13). The pager lazily
    /// unloads pages ±1, so the factory may be called repeatedly and must return a controller that
    /// can be embedded again.
    private let rightPage: (() -> UIViewController)?

    /// Whether to yield the leading edge to the system navigation gesture (§1).
    ///
    /// `false` (the default): the start screen is meant to be a root screen. The policy cannot be
    /// undone after the first display: UIKit cannot remove `require(toFail:)`, so set it right away,
    /// not on the fly.
    private let yieldsLeftEdgeToSystemGesture: Bool

    /// The folder tap interceptor (D17).
    ///
    /// `nil` (the default) means the folder is expanded by the grid's native panel. If the closure
    /// returned `true`, native expansion is not performed: the host handles the tap itself (for
    /// example, shows the previous folder screen). With `true`, the
    /// ``TesseraStartScreenDelegate/startScreen(_:didTapFolder:)`` event does not arrive, so that
    /// the navigation does not happen twice.
    private let folderTapHandler: ((TesseraTileFolder) -> Bool)?

    /// The start screen event observer.
    private let delegate: TesseraStartScreenDelegate?

    /// Creates the start screen facade.
    ///
    /// - Parameters:
    ///   - snapshot: The grid snapshot (§3); the only data input.
    ///   - style: The appearance and page titles; the system one by default.
    ///   - leftPanel: The hook page provider (§7); `nil` means no hook (D13).
    ///   - rightPage: The right page factory (§6); `nil` means no page (D13).
    ///   - yieldsLeftEdgeToSystemGesture: The leading edge policy (§1); `false` by default: the
    ///     start screen is a root screen.
    ///   - folderTapHandler: The folder tap interceptor (D17); `nil` means native expansion with the
    ///     panel.
    ///   - delegate: The tap and transition observer; optional.
    public init(
        snapshot: TesseraTileGridSnapshot,
        style: TesseraStartScreenStyle = TesseraStartScreenStyle(),
        leftPanel: TesseraQuickPanelProviding? = nil,
        rightPage: (() -> UIViewController)? = nil,
        yieldsLeftEdgeToSystemGesture: Bool = false,
        folderTapHandler: ((TesseraTileFolder) -> Bool)? = nil,
        delegate: TesseraStartScreenDelegate? = nil
    ) {
        self.snapshot = snapshot
        self.style = style
        self.leftPanel = leftPanel
        self.rightPage = rightPage
        self.yieldsLeftEdgeToSystemGesture = yieldsLeftEdgeToSystemGesture
        self.folderTapHandler = folderTapHandler
        self.delegate = delegate
    }

    // MARK: - UIViewControllerRepresentable

    /// Creates the coordinator, the bridge from UIKit callbacks to ``TesseraStartScreenDelegate``.
    ///
    /// - Returns: The coordinator held by SwiftUI.
    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Creates the UIKit core of the start screen.
    ///
    /// The configuration is applied **before** the view loads: the controller assembles the pages
    /// from `leftPanel`/`rightPage` already in `viewDidLoad` (D13), so side pages must not be
    /// attached after the first layout.
    ///
    /// - Parameter context: The SwiftUI context.
    /// - Returns: The configured ``TesseraStartScreenViewController``.
    public func makeUIViewController(
        context: Context
    ) -> TesseraStartScreenViewController {
        let screen = TesseraStartScreenViewController()
        context.coordinator.screenViewController = screen
        context.coordinator.applyConfiguration(self, to: screen, isInitial: true)
        context.coordinator.attach(to: screen)
        return screen
    }

    /// Applies a changed configuration to the live controller.
    ///
    /// The method is called on every SwiftUI redraw, so every application compares values with the
    /// current state (see the documentation of ``TesseraStartScreenView``): page rebuilds and grid
    /// reloads happen only on real changes.
    ///
    /// - Parameters:
    ///   - uiViewController: The live ``TesseraStartScreenViewController``.
    ///   - context: The SwiftUI context with the coordinator.
    public func updateUIViewController(
        _ uiViewController: TesseraStartScreenViewController,
        context: Context
    ) {
        // The coordinator keeps the latest version of the description: otherwise the delegate would
        // see a stale state after a SwiftUI redraw.
        context.coordinator.parent = self
        context.coordinator.screenViewController = uiViewController

        context.coordinator.applyConfiguration(self, to: uiViewController, isInitial: false)
        // Safety net: the host may have reassigned the controller's UIKit delegate.
        context.coordinator.ensureScreenDelegate(on: uiViewController)
    }

    /// Releases the coordinator's links when the view is torn down.
    ///
    /// The coordinator detaches from the controller's UIKit delegate and releases the grid closures:
    /// a screen that outlives the view does not retain SwiftUI state.
    ///
    /// - Parameters:
    ///   - uiViewController: The controller being torn down.
    ///   - coordinator: The view's coordinator.
    public static func dismantleUIViewController(
        _ uiViewController: TesseraStartScreenViewController,
        coordinator: Coordinator
    ) {
        coordinator.detach()
    }

    // MARK: - Snapshot comparison

    /// The compared shortcut attributes: what is visible, announced and live.
    ///
    /// `action` is not included: closures are not comparable, and the grid does not run the action;
    /// the delegate receives the shortcut from the latest snapshot (see `Coordinator`).
    /// `liveContent` is compared by reference: a provider change (or its appearance) must reach the
    /// grid, otherwise the tile does not become live.
    fileprivate struct ShortcutSignature: Equatable {
        let id: AnyHashable
        let size: TesseraTileSize
        let title: String
        let badge: TesseraTileBadge
        let iconIdentifier: ObjectIdentifier?
        let liveContentIdentifier: ObjectIdentifier?

        init(shortcut: TesseraTileDescriptor) {
            id = shortcut.id
            size = shortcut.size
            title = shortcut.title
            badge = shortcut.badge
            iconIdentifier = shortcut.icon.map { ObjectIdentifier($0) }
            liveContentIdentifier = shortcut.liveContent.map { ObjectIdentifier($0) }
        }
    }

    /// The compared grid item attributes.
    ///
    /// `TesseraTileGridSnapshot` and `TesseraTileGridItem` are not `Equatable`: a shortcut has an
    /// `action` closure, which has no equality semantics. So "the same" is defined by what is
    /// visible and announced: the identifier, size (D15), caption, badge (D12), the icon reference,
    /// the live provider and the folder content, with the captions and badges of its shortcuts (the
    /// folder preview and panel show them). The expanded folder panel flag (D17) is included in the
    /// signature as a separate field: the panel and the folder tile share one identifier, but they
    /// are different screen states.
    fileprivate struct ItemSignature: Equatable {
        let id: AnyHashable
        let size: TesseraTileSize
        let title: String
        let badge: TesseraTileBadge
        let iconIdentifier: ObjectIdentifier?
        let liveContentIdentifier: ObjectIdentifier?
        let folderContents: [ShortcutSignature]
        let isFolderPanel: Bool

        init(item: TesseraTileGridItem) {
            id = item.id
            size = item.size

            switch item {
            case .tile(let shortcut):
                title = shortcut.title
                badge = shortcut.badge
                iconIdentifier = shortcut.icon.map { ObjectIdentifier($0) }
                liveContentIdentifier = shortcut.liveContent.map { ObjectIdentifier($0) }
                folderContents = []
                isFolderPanel = false
            case .folder(let folder):
                title = folder.title
                // D44: the folder badge is the aggregate of its shortcut badges.
                badge = folder.aggregateBadge
                iconIdentifier = folder.icon.map { ObjectIdentifier($0) }
                liveContentIdentifier = nil
                folderContents = folder.tiles.map { ShortcutSignature(shortcut: $0) }
                isFolderPanel = false
            case .folderContent(let folder):
                title = folder.title
                badge = .none
                iconIdentifier = folder.icon.map { ObjectIdentifier($0) }
                liveContentIdentifier = nil
                folderContents = folder.tiles.map { ShortcutSignature(shortcut: $0) }
                isFolderPanel = true
            }
        }
    }

    /// The attributes of the item array: the input of snapshot comparison.
    fileprivate static func signatures(for items: [TesseraTileGridItem]) -> [ItemSignature] {
        items.map { ItemSignature(item: $0) }
    }

    /// Clamps the parallax multiplier the same way as the core (§8: `0.4...0.6`).
    ///
    /// Needed for comparison: the controller already stores the clamped value, so a style with `0.9`
    /// must not be applied on every update.
    fileprivate static func sanitizedParallaxFactor(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0.4), 0.6)
    }

    /// The hook provider type: a stable attribute for comparison between redraws.
    ///
    /// A provider instance created in `body` is new on every redraw, so comparing by reference would
    /// rebuild the pager on every frame. A type change is a page change; a new instance of the same
    /// type is swapped in without a rebuild.
    fileprivate static func providerType(of value: TesseraQuickPanelProviding) -> ObjectIdentifier {
        ObjectIdentifier(type(of: value))
    }

    // MARK: - Coordinator

    /// The bridge from the UIKit core events to ``TesseraStartScreenDelegate``.
    ///
    /// It lives as long as the view: SwiftUI retains it, so the controller's weak reference
    /// (``TesseraStartScreenViewController/delegate``) does not lose the observer between redraws.
    /// The coordinator itself is the controller's UIKit delegate: pages and hook visibility are
    /// forwarded to the host as is, and grid taps (`onTap`) with the shortcut from the latest
    /// snapshot.
    public final class Coordinator: NSObject, TesseraStartScreenDelegate, TesseraPagerDelegate {

        /// The latest description from SwiftUI: the source of the delegate and the configuration.
        fileprivate var parent: TesseraStartScreenView

        /// The screen controller. Weak: SwiftUI owns the hierarchy.
        fileprivate weak var screenViewController: TesseraStartScreenViewController?

        /// Whether side pages exist in the last applied configuration (D13).
        ///
        /// Needed to avoid rebuilding pages on every SwiftUI redraw: a rebuild stops a pager swipe in
        /// progress.
        private var appliedHasLeftPanel: Bool?
        private var appliedHasRightPage: Bool?

        /// The type of the last applied hook provider (a stable attribute).
        private var appliedLeftPanelType: ObjectIdentifier?

        /// Creates a coordinator over a start screen description.
        ///
        /// - Parameter parent: The description from `makeCoordinator()`.
        fileprivate init(parent: TesseraStartScreenView) {
            self.parent = parent
            super.init()
        }

        // MARK: Applying the configuration

        /// Applies the description to the controller.
        ///
        /// The order matters: page titles are set before the pager is rebuilt, the edge policy before
        /// the first display (§1), and the grid snapshot after the pages, so as not to touch the
        /// layout twice.
        ///
        /// - Parameters:
        ///   - description: The current description from SwiftUI.
        ///   - screen: The live screen controller.
        ///   - isInitial: `true` when the view is created: all fields are applied without
        ///     comparisons.
        fileprivate func applyConfiguration(
            _ description: TesseraStartScreenView,
            to screen: TesseraStartScreenViewController,
            isInitial: Bool
        ) {
            apply(style: description.style, to: screen)
            applyEdgePolicy(description.yieldsLeftEdgeToSystemGesture, to: screen)
            applySidePages(
                leftPanel: description.leftPanel,
                rightPage: description.rightPage,
                to: screen,
                force: isInitial
            )
            applyGrid(description.snapshot, to: screen, force: isInitial)
            applyFolderTapHandler(description.folderTapHandler, to: screen)
        }

        /// Applies the style without touching unchanged fields.
        private func apply(style: TesseraStartScreenStyle, to screen: TesseraStartScreenViewController) {
            if screen.wallpaperImage !== style.wallpaper {
                screen.wallpaperImage = style.wallpaper
            }

            let factor = TesseraStartScreenView.sanitizedParallaxFactor(style.wallpaperParallaxFactor)
            if factor != screen.wallpaperParallaxFactor {
                screen.wallpaperParallaxFactor = style.wallpaperParallaxFactor
            }

            if screen.quickPanelTitle != style.quickPanelTitle {
                screen.quickPanelTitle = style.quickPanelTitle
            }
            if screen.startPageTitle != style.startPageTitle {
                screen.startPageTitle = style.startPageTitle
            }
            if screen.applicationsPageTitle != style.applicationsPageTitle {
                screen.applicationsPageTitle = style.applicationsPageTitle
            }
        }

        /// Applies the leading edge policy (§1).
        ///
        /// The controller itself ignores setting the same value again.
        private func applyEdgePolicy(
            _ yieldsEdge: Bool,
            to screen: TesseraStartScreenViewController
        ) {
            guard screen.yieldsLeftEdgeToSystemGesture != yieldsEdge else { return }
            screen.yieldsLeftEdgeToSystemGesture = yieldsEdge
        }

        /// Rebuilds the side pages only when the configuration changes (D13).
        ///
        /// `configure` is the "cold" path: it rebuilds the pager (and stops a swipe in progress), so
        /// it is called only when the presence of pages or the hook provider type changes. New
        /// instances under the same configuration (a provider and a factory created in `body`) are
        /// swapped in without a rebuild.
        private func applySidePages(
            leftPanel: TesseraQuickPanelProviding?,
            rightPage: (() -> UIViewController)?,
            to screen: TesseraStartScreenViewController,
            force: Bool
        ) {
            let hasLeftPanel = leftPanel != nil
            let hasRightPage = rightPage != nil
            let leftPanelType = leftPanel.map { TesseraStartScreenView.providerType(of: $0) }

            let needsRebuild = force
                || appliedHasLeftPanel != hasLeftPanel
                || appliedHasRightPage != hasRightPage
                || leftPanelType != appliedLeftPanelType

            appliedHasLeftPanel = hasLeftPanel
            appliedHasRightPage = hasRightPage
            appliedLeftPanelType = leftPanelType

            if needsRebuild {
                screen.configure(leftPanel: leftPanel, rightPage: rightPage)
            } else {
                screen.updateSidePageSources(leftPanel: leftPanel, rightPage: rightPage)
            }
        }

        /// Applies the grid snapshot if it differs from the shown one (§3).
        ///
        /// What is compared is not the previous SwiftUI description but the actual grid state: the
        /// edit coordinator may animate a change before the SwiftUI redraw arrives, and then there
        /// is no second `reloadData` and the animation is not broken.
        private func applyGrid(
            _ snapshot: TesseraTileGridSnapshot,
            to screen: TesseraStartScreenViewController,
            force: Bool
        ) {
            if !force {
                let desired = TesseraStartScreenView.signatures(for: snapshot.items)
                let current = TesseraStartScreenView.signatures(for: screen.gridView.items)
                // A snapshot with an explicit cell table (`TesseraTileStore.snapshot(columns:)`)
                // changes the layout even when the set and sizes are the same, for example a hole
                // remains after an unpin. A snapshot without a table does not define the layout and
                // does not overwrite the shown table.
                let placementsChanged = snapshot.placementTable != nil
                    && snapshot.placementTable != screen.gridView.snapshot?.placementTable
                guard desired != current || placementsChanged else { return }
            }
            screen.reload(grid: snapshot)
        }

        /// Passes the folder tap interceptor to the grid (D17).
        ///
        /// The closure is not compared: it is small, and assigning the grid property rebuilds
        /// nothing. The host may change the interceptor between SwiftUI redraws.
        private func applyFolderTapHandler(
            _ handler: ((TesseraTileFolder) -> Bool)?,
            to screen: TesseraStartScreenViewController
        ) {
            screen.gridView.folderTapHandler = handler
        }

        // MARK: Connecting to the core

        /// Connects the coordinator to the live controller.
        ///
        /// The grid reports taps only through `onTap`, so the facade takes this closure for itself:
        /// otherwise neither a finger tap nor a VoiceOver activation would reach the delegate. A host
        /// that needs its own tap behavior should use ``TesseraStartScreenDelegate`` rather than
        /// override `onTap` (see the documentation of ``TesseraStartScreenView``). Page transitions
        /// and hook visibility arrive through the controller's UIKit delegate.
        ///
        /// - Parameter screen: The controller created in `makeUIViewController`.
        fileprivate func attach(to screen: TesseraStartScreenViewController) {
            screenViewController = screen

            screen.gridView.onTap = { [weak self] item in
                self?.handleTap(item)
            }
            // D17: expanding and closing the folder panel are delegate events.
            screen.gridView.onFolderExpansionChanged = { [weak self] folder, expanded in
                self?.handleFolderExpansion(folder, expanded: expanded)
            }
            ensureScreenDelegate(on: screen)
        }

        /// Releases the links when the view is torn down.
        fileprivate func detach() {
            if let screen = screenViewController, screen.delegate === self {
                screen.delegate = nil
            }
            screenViewController?.gridView.onTap = nil
            screenViewController?.gridView.onFolderExpansionChanged = nil
            // The interceptor belongs to the host view: a screen that outlives SwiftUI must not
            // retain a closure with its state.
            screenViewController?.gridView.folderTapHandler = nil
            screenViewController = nil
        }

        /// Sets the coordinator as the controller's UIKit delegate (if it was replaced).
        fileprivate func ensureScreenDelegate(on screen: TesseraStartScreenViewController) {
            if screen.delegate !== self {
                screen.delegate = self
            }
        }

        // MARK: Events

        /// A tap on a grid item (finger or VoiceOver activation).
        ///
        /// The shortcut action is not run (D12): the component reports the event, and the host calls
        /// `TesseraTileDescriptor.action`, otherwise the action would run twice if the host is also
        /// subscribed to it. The shortcut and the folder are taken from the latest SwiftUI snapshot by
        /// `id`: the grid is not reloaded for a new `action` closure (it is not comparable), but the
        /// delegate receives the current one.
        private func handleTap(_ item: TesseraTileGridItem) {
            guard let screen = screenViewController else { return }

            switch item {
            case .tile(let shortcut):
                parent.delegate?.startScreen(screen, didTapShortcut: latestShortcut(for: shortcut))
            case .folder(let folder):
                // D14/D17: the folder tap event. The grid performs native panel expansion (unless
                // the interceptor forbade it).
                parent.delegate?.startScreen(screen, didTapFolder: latestFolder(for: folder))
            case .folderContent:
                // The expanded folder panel (D17): a tap on its title/empty space changes nothing;
                // the shortcuts inside are handled by the panel.
                break
            }
        }

        /// The grid expanded or closed a folder panel (D17).
        ///
        /// - Parameters:
        ///   - folder: The folder the event refers to.
        ///   - expanded: `true` if the panel is expanded, `false` if collapsed.
        private func handleFolderExpansion(_ folder: TesseraTileFolder, expanded: Bool) {
            guard let screen = screenViewController else { return }
            let latest = latestFolder(for: folder)
            if expanded {
                parent.delegate?.startScreen(screen, didExpandFolder: latest)
            } else {
                parent.delegate?.startScreen(screen, didCollapseFolder: latest)
            }
        }

        /// The shortcut with the same `id` from the latest snapshot (including inside a folder).
        private func latestShortcut(for shortcut: TesseraTileDescriptor) -> TesseraTileDescriptor {
            for item in parent.snapshot.items {
                switch item {
                case .tile(let candidate) where candidate.id == shortcut.id:
                    return candidate
                case .folder(let folder), .folderContent(let folder):
                    if let candidate = folder.tiles.first(where: { $0.id == shortcut.id }) {
                        return candidate
                    }
                default:
                    continue
                }
            }
            return shortcut
        }

        /// The folder with the same `id` from the latest snapshot.
        private func latestFolder(for folder: TesseraTileFolder) -> TesseraTileFolder {
            for item in parent.snapshot.items {
                if case .folder(let candidate) = item, candidate.id == folder.id {
                    return candidate
                }
            }
            return folder
        }

        // MARK: TesseraStartScreenDelegate (the UIKit -> host bridge)

        /// A page change, forwarded to the host delegate as is.
        ///
        /// - Parameters:
        ///   - screen: The controller that is the source of the event.
        ///   - page: The page now shown.
        ///   - index: The index in reading order.
        public func startScreen(
            _ screen: TesseraStartScreenViewController,
            didChangePage page: TesseraStartScreenPage,
            index: Int
        ) {
            parent.delegate?.startScreen(screen, didChangePage: page, index: index)
        }

        /// The hook visibility, forwarded to the host delegate as is (including when the screen
        /// appears and leaves, §7).
        ///
        /// - Parameters:
        ///   - screen: The controller that is the source of the event.
        ///   - isVisible: Whether the hook page is visible.
        public func startScreen(
            _ screen: TesseraStartScreenViewController,
            didChangeHookVisibility isVisible: Bool
        ) {
            parent.delegate?.startScreen(screen, didChangeHookVisibility: isVisible)
        }

        // MARK: The deprecated pager proxy

        /// A deprecated path: the coordinator is no longer the pager's delegate.
        ///
        /// Transitions arrive through ``TesseraStartScreenViewController/delegate``. The method is kept
        /// for the stability of the public surface and only forwards the event to the controller.
        ///
        /// - Parameters:
        ///   - pager: The pager that is the source of the event.
        ///   - index: The shown page in reading order.
        @available(*, deprecated, message: "Page transitions are delivered through TesseraStartScreenViewController.delegate")
        public func pager(
            _ pager: TesseraPagerViewController,
            didShowPageAt index: Int
        ) {
            screenViewController?.pager(pager, didShowPageAt: index)
        }
    }
}
#endif
