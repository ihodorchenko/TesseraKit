//
//  TileGridView.swift
//  TesseraStartScreen
//
//  Grid of tiles and folders of the desktop: a UICollectionView with a custom
//  layout, plus a facade for the host and for edit mode.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md — §2 "Architecture"
//  (StartPage: TileGridView — UICollectionView + custom layout), §3
//  "Tile grid" (units, four sizes, custom layout, invalidation),
//  §4 "Live tiles" (a tile's live content is served by a single
//  `TesseraLiveTileEngine` per grid: stagger, flips, dwells, Reduce Motion;
//  the badge is a separate container view, not part of the flip), §5 "Edit
//  mode" (hooks for drag editing: snapshot, placeholder, invalidation), §8
//  "Background parallax" (the scroll callback hands the offset outward;
//  scrollViewDidScroll lays nothing out itself) and §9 "Accessibility"
//  (VoiceOver, Dynamic Type, RTL).
//  Clarifications: D12 (a tile is an action), D14 (folders are a grid
//  item), D15 (four sizes and live tiles) — docs/DECISIONS.md; §14
//  STARTSCREEN-IOS-DESIGN.md.
//
//  Neighbors move during reorder and resize along a bounce curve
//  `cubic-bezier(0.175, 0.885, 0.32, 1.1)` (``bounceTimingParameters()``),
//  over 0.26 s; with Reduce Motion changes are applied instantly. The folder panel
//  curve (0.1, 0.9, 0.2, 1) is unchanged.
//
//  The grid exposes the geometry of the virtual grid for magnetism:
//  ``magnetSlotCenters(for:)`` returns slot centers with the same dimensions as
//  the dragged tile (grid coordinates, including `contentOffset`).
//  The upper bound of the grid is the last occupied row of the base layout produced by
//  `TesseraTileLayoutEngine.pack`; no centers are returned while a folder is expanded,
//  because the panel shifts the rows.
//
//  D17 (docs/DECISIONS.md) — native Windows Phone folder expansion: below the folder tile
//  (which stays visible) a full-width panel
//  `TesseraTileGridItem.folderContent` is inserted — a separate row right after the row where
//  the folder ends. Scrolling is locked during the animation, icons cascade in
//  after the height grows, and the panel closes on a repeated tap, a tap on empty space, or Back;
//  the `folderTapHandler` interceptor is available to the host. The panel is a collection cell
//  (`TesseraFolderPanelCell`), so the rows below it are shifted by the standard batch-update
//  animation rather than by manual layout. While the folder is expanded, the 2×2 preview mini-tiles
//  on its tile are hidden (the backing and the title remain).
//
//  Folder panel animations are serialized by a state machine:
//  `idle`/`opening`/`closing` plus one deferred target and one deferred
//  snapshot. A single runloop pass runs either `reloadData` or
//  `performBatchUpdates`, never both (switching from folder A to B collapses A immediately and
//  defers opening B to the next pass). Grid scrolling has a single
//  owner — ``isScrollEnabled`` (the requested value) plus a counter of lock reasons
//  (the folder panel); scrolling is restored only once the reason is removed.
//  `clampContentOffsetAfterCollapse` and `.layoutChanged` run in all
//  expand/collapse branches, including Reduce Motion and the no-window case.
//  `update(snapshot:)`/`reload(snapshot:)` calls made during a transition are remembered and
//  applied after it.
//
//  A snapshot is applied as a diff (`performBatchUpdates`
//  insert/delete + reconfiguration of visible cells) rather than `reloadData`:
//  cells keep their live-tile registration and the folder preview phase. The move branch
//  remains for resize/reorder; if the order of common items changes along with the
//  set of items, `reloadData` is applied (mixing move with insert/delete in a single
//  batch is unreliable). The owner of the
//  0.7 edit-mode dimming is the grid (``setEditDimming(_:animated:)``,
//  the cell stores the target alpha and does not reset it in `configure`).
//  Tiles in an expanded folder's panel are activated through the shared `onTap` route
//  (they are not activated in edit mode). ``magnetSlotCenters(for:)``
//  computes the grid via `TesseraTileLayoutEngine.gridMetrics` and matches the layout frames
//  to the pixel. The grid's live content has a public pause
//  (``isLiveContentPaused``), which is taken into account in `configure(isVisible:)` and
//  is not lifted by `update` bypassing the controller.
//
//  Reduce Motion is checked via the internal provider
//  ``isReduceMotionEnabled``: the cross-fade on content changes is disabled, and Reduce Motion
//  is confirmed to work (the `animated: true` branch is reachable only after
//  `guard shouldAnimate`). The label of a live tile is built from
//  `liveContent.frontFace` (title + detail), and the value from the badge.
//
//  Responsibilities:
//  - the grid only displays a TesseraTileGridSnapshot and reports
//    taps/long presses; order, sizes, folders and actions belong to TesseraTileStore and the
//    host (the "single writer" rule, §6);
//  - a tile's live content (§4) is served by ``TesseraLiveTileEngine``: the grid
//    keeps one engine for all cells, registers the container when a
//    cell is shown and pauses it when it leaves the screen; flips, stagger, dwells and
//    Reduce Motion stay inside the engine, the cell only provides the container;
//  - `scrollViewDidScroll` performs only `onScrollOffsetChanged`:
//    no `layoutIfNeeded`, no `invalidateLayout`, no `reloadData` (§3, §8,
//    CORE-IOS-DESIGN.md §2). Parallax is frame/transform/alpha on the
//    subscriber side.
//

#if canImport(UIKit)
import UIKit
import TesseraCore

/// Grid of tiles and folders of the desktop (docs/STARTSCREEN-IOS-DESIGN.md §2, §3).
///
/// ## Usage
///
/// ```swift
/// let grid = TesseraTileGridView()
/// grid.onTap = { item in
///     switch item {
///     case .tile(let tile): tile.action()
///     case .folder(let folder): host.analytics.folderTapped(folder)  // D14/D17
///     default: break
///     }
/// }
/// grid.onLongPress = { item, point in editCoordinator.beginEditing(at: item, point: point) }
/// grid.onScrollOffsetChanged = { offset in background.apply(offsetY: offset.y) }
/// grid.reload(snapshot: store.snapshot(columns: grid.columns))   // with a cell table
/// ```
///
/// ## Data
///
/// The only data inputs are ``reload(snapshot:)`` and
/// ``update(snapshot:animated:)``. The grid never reads `TesseraTileStore` itself: the host
/// passes a snapshot after every change (`TesseraTileStore.onChange`), so the
/// screen and the app list (§6) read the same state.
///
/// ## Live tiles (§4)
///
/// Live content is supplied by a provider in ``TesseraTileDescriptor/liveContent``: the grid
/// creates one ``TesseraLiveTileEngine`` for itself, and a cell with such a tile
/// shows ``TesseraLiveTileView`` instead of a static icon and title.
/// The badge stays outside the flip (the container owns it).
///
/// Lifecycle:
/// - registration — in `willDisplay` (the cell is actually on screen);
/// - pause — in `didEndDisplaying` and ``setItemHidden(_:forItemID:)``:
///   the engine discards an unfinished flip and schedules no new ones;
/// - unregistration — in `prepareForReuse`, as the engine contract requires;
/// - Reduce Motion — the engine shows a static front face; the grid does not duplicate it.
///
/// The schedule (`cycleInterval`, `flipDuration`, etc.) is configured via
/// ``liveTileConfiguration``; for providers without a subscription an explicit
/// ``refreshLiveTile(forItemID:)``.
///
/// ## Scrolling and parallax
///
/// ``onScrollOffsetChanged`` is called from `scrollViewDidScroll` with the current
/// `contentOffset`. No layout operation runs inside the grid at that moment
/// (§3, §8): the subscriber decides what to move —
/// the `transform`/`frame`/`alpha` of the background. With Reduce Motion the subscriber must
/// disable parallax (§9); the grid does not check this setting.
///
/// ## Edit mode (groundwork for drag editing)
///
/// The grid does not implement jiggle, drag or resize — that is the job of `TileEditCoordinator`.
/// It exposes exactly the primitives the coordinator needs:
///
/// - ``frame(forItemID:)`` — a tile's frame in grid coordinates (for the drag
///   overlay layer and for computing how neighbors make room);
/// - ``magnetSlotCenters(for:)`` — centers of virtual slots with the same
///   dimensions, for magnetism (in grid coordinates);
/// - ``item(at:)`` — hit test of a point in grid coordinates (under the finger/cursor);
/// - ``snapshotView(forItemID:)`` — a snapshot of a visible cell for the drag; `nil`
///   if the cell is not visible;
/// - ``cellView(forItemID:)`` — the visible cell itself, for jiggle and highlighting
///   (only `transform`/`alpha` may be changed, never `frame`);
/// - ``placeholderView(forItemID:)`` — a ready-made placeholder view with the tile's frame
///   (not yet added to the hierarchy; the coordinator owns it);
/// - ``setItemHidden(_:forItemID:)`` — hide the source cell without changing the
///   layout (alpha 0 + excluded from VoiceOver);
/// - ``update(snapshot:animated:)`` — apply a new snapshot with a
///   resize/reorder animation (UICollectionView animates the shift of neighboring tiles
///   with the bounce curve);
/// - ``invalidateTileLayout(animated:)`` — recompute geometry without changing the
///   snapshot (for example, after the container width or grid settings change);
/// - ``contentOffset``/``setContentOffset(_:animated:)``/``contentSize``/
///   ``isScrollEnabled`` — for autoscroll at the edges while dragging.
///
/// The grid does not start the drag gesture itself: the long press only reports the start
/// point (``onLongPress``); tracking the finger is up to the coordinator,
/// otherwise the drag gesture would conflict with scrolling and with the host's right to
/// customize editing.
///
/// ## Folder expansion (D17)
///
/// A tap on a closed folder expands it natively, as in Windows Phone: below the
/// folder tile (which stays in place and visible) a full-width
/// panel is inserted with a title (lowercase) and a grid of tiles (the same number of columns as the desktop).
/// The panel takes a separate row right after the row where the folder
/// ends and grows downward, so everything that starts below that row
/// shifts down; icons appear in a cascade after the growth finishes. While the
/// folder is expanded, the 2×2 preview mini-tiles on its tile are hidden — the backing and the
/// title remain; the preview returns on close. The panel is a
/// UI state, not data: it does not enter the `TesseraTileStore` snapshot, and ``items``
/// does not contain it.
///
/// - ``toggleFolder(_:)`` / ``openFolder(_:animated:)`` / ``closeFolder(animated:)``
///   — programmatic control; the state is read via ``expandedFolderID``;
/// - ``folderTapHandler`` — interception: `true` cancels the native expansion;
/// - closing: a repeated tap on the panel, a tap on empty space of the collection,
///   ``accessibilityPerformEscape()`` (Back/two-finger scrub) or an explicit host call;
///   a folder disappearing from the snapshot also closes the panel;
/// - in edit mode (`TesseraTileEditCoordinator`) expansion works the same way:
///   a tile is picked from the panel with a long press and
///   dragged out of the folder; a tap on a folder does not interrupt edit mode;
/// - animation — `cubic-bezier(0.1, 0.9, 0.2, 1)`, 0.28 s
///   (``folderExpansionDuration``); with Reduce Motion (§9) expansion is instant.
///
/// ## Accessibility (§9)
///
/// - a tile is one VoiceOver element with the button trait; the title is the label,
///   the badge count is the value;
/// - a folder is one element with the tile count in its value;
/// - Dynamic Type: the title font is rebuilt when the category changes;
/// - RTL: element order is set by the layout; the icon and badge are mirrored;
/// - VoiceOver traversal order — the order of collection indexes (this is how
///   `UICollectionView` works; not verified on a device with VoiceOver):
///   the grid does not set `accessibilityElements` and does not sort frames; the layout provides attributes
///   by index. Indexes follow the reading order of explicit cells (row, then
///   logical column; in RTL the same order — column 0 is on the right), including
///   those with holes; the expanded folder's panel (D17) comes right after the last
///   element of the folder band, and its tiles are read inside the panel after the folder
///   tile. `TesseraTileStore` already returns the snapshot in this order, and for a host with a cell table
///   without `TesseraTileStore` the grid restores it itself; without an applicable table
///   (`pack` layout) the order stays as the host delivered it.
///
/// ## Insets and safe area
///
/// The grid does not mix in `safeAreaInsets` automatically
/// (`contentInsetAdjustmentBehavior = .never`): outer insets are set via
/// ``contentInsets``, and the host decides whether to add the safe area to them.
/// This keeps the unit formula of §3 in one place.
///
/// All methods are main-thread: a UIKit view is not designed for background calls
/// (docs/CORE-IOS-DESIGN.md §3).
public final class TesseraTileGridView: UIView {

    // MARK: - Public callbacks

    /// A tap on a tile or folder.
    ///
    /// The grid does not run a tile's action itself (D12): it hands over the item, and the
    /// host decides whether to call `TesseraTileDescriptor.action` or open a folder. The folder
    /// is chosen by the host — nesting and navigation are not part of the model
    /// (D14).
    ///
    /// Tiles inside an expanded folder's panel arrive here as well
    /// (`.tile(descriptor)`) — the panel used to call `TesseraTileDescriptor.action`
    /// directly. For integrators this is a breaking change: the host runs a tile's action in
    /// the panel from ``onTap``; voice activation takes the same
    /// path. In edit mode the panel does not activate the action.
    ///
    /// The callback is synchronous: do not call ``reload(snapshot:)``/
    /// ``update(snapshot:animated:)``/``openFolder(_:animated:)`` from it again —
    /// that re-enters the grid update, where `reloadData` and
    /// `performBatchUpdates` could end up in the same runloop pass.
    /// Defer such a reaction to the next pass (or to a `delegate` event).
    public var onTap: ((TesseraTileGridItem) -> Void)?

    /// A long press on an item enters edit mode.
    ///
    /// The second parameter is the press point in grid coordinates: the coordinator
    /// starts the snapshot and the drag from it. If the closure is not set, the long-press
    /// gesture is disabled and does not interfere with ordinary taps.
    public var onLongPress: ((TesseraTileGridItem, CGPoint) -> Void)? {
        didSet {
            longPressRecognizer.isEnabled = onLongPress != nil
        }
    }

    /// A change of `contentOffset` while the grid scrolls (§8).
    ///
    /// Called from `scrollViewDidScroll`; no layout operations run inside the grid
    /// at that moment, so the subscriber must restrict itself to
    /// `frame`/`transform`/`alpha` (CORE-IOS-DESIGN.md §2).
    public var onScrollOffsetChanged: ((CGPoint) -> Void)?

    /// Folder tap interceptor (D17).
    ///
    /// If the closure is set and returns `true`, the grid does **not** perform the native
    /// expansion: the decision and presenting a screen are up to the host (for example, a legacy
    /// folder screen). In that case ``onTap`` is not called either, so that the host does not
    /// handle the tap twice. `nil` or `false` — the folder expands with the built-in
    /// panel (``toggleFolder(_:)``), and the tap event is still delivered to
    /// ``onTap``.
    ///
    /// The rule is the same in normal and edit mode —
    /// the interceptor is called in edit mode too (it used not to be called there, and a
    /// folder tap only reached ``onTap``). A host that
    /// shows its own folder screen gets it during
    /// editing as well; the native panel in this mode opens and lets a tile be
    /// dragged out of the folder.
    public var folderTapHandler: ((TesseraTileFolder) -> Bool)?

    /// Folder rename handler (D35; Windows 10 Mobile §6.7).
    ///
    /// While a handler is set, the title of an open panel is editable: a long
    /// press on it (≈0.5 s) turns the caption into a single-line field; return
    /// ("Done") or a tap outside the field commits the name, and the folder tile and the
    /// panel title get a VoiceOver "Rename" action. Without a
    /// handler the title is static: the grid stays usable without a store.
    ///
    /// The callback receives the folder identifier and the **normalized** name
    /// (``TesseraTileFolder/normalizedTitle(_:)``: surrounding whitespace trimmed, a single
    /// line, no longer than ``TesseraTileFolder/maximumTitleLength`` characters); an empty
    /// string means "restore the default name" — the receiver supplies it
    /// (`TesseraTileStore.renameFolder(_:to:)`, the coordinator). Until a new
    /// snapshot is applied, the title shows the localized default name. The callback
    /// is called only if the name differs from the displayed one, synchronously, and after
    /// the panel has left editing; the host reacts with a new snapshot via
    /// ``update(snapshot:animated:)``.
    ///
    /// Closing the panel, leaving the window, and entering or leaving edit mode
    /// finish editing by **committing**, not cancelling. The property is taken by
    /// `TesseraTileEditCoordinator` (it installs a handler that calls
    /// `TesseraTileStore.renameFolder`); a host with a coordinator must not set it.
    public var folderRenameHandler: ((AnyHashable, String) -> Void)? {
        willSet {
            // The old handler still receives the name typed before the change.
            commitFolderNameEditing()
        }
        didSet {
            refreshVisibleCells()
        }
    }

    /// Event of a folder expanding/closing through the built-in panel (D17).
    ///
    /// An internal channel for the SwiftUI facade: a UIKit host reads the state via
    /// ``expandedFolderID`` and calls ``closeFolder(animated:)``. The first
    /// parameter is the folder, the second is whether it is expanded now.
    ///
    /// The callback is synchronous: re-entering ``reload(snapshot:)``/
    /// ``update(snapshot:animated:)``/``openFolder(_:animated:)`` from it may
    /// mix `reloadData` and `performBatchUpdates` in one runloop pass —
    /// defer the reaction to the next pass.
    var onFolderExpansionChanged: ((TesseraTileFolder, Bool) -> Void)?

    // MARK: - Public data

    /// The last snapshot applied to the grid.
    ///
    /// A snapshot is a value from `TesseraTileStore`: the grid does not change it, only
    /// displays it. The host passes a new snapshot via ``reload(snapshot:)`` or
    /// ``update(snapshot:animated:)``. Only ``items`` is exposed in the public API:
    /// the edit coordinator gets the snapshot inside the module,
    /// and the host needs only the items themselves.
    private(set) var snapshot: TesseraTileGridSnapshot?

    /// Grid items in display order (a convenient accessor for the snapshot).
    ///
    /// The panel of an expanded folder (``TesseraTileGridItem/folderContent(_:)``, D17) is not
    /// included: it is UI state, not data. The host and the edit coordinator
    /// need exactly the `TesseraTileStore` snapshot, so that model comparison does not depend on
    /// whether a folder is open. The expansion state is ``expandedFolderID``.
    public var items: [TesseraTileGridItem] {
        snapshot?.items ?? []
    }

    // MARK: - Folder expansion (D17)

    /// Duration of the folder panel expand/close animation, in seconds (D17).
    ///
    /// The curve is `cubic-bezier(0.1, 0.9, 0.2, 1)`: a fast start and a soft
    /// deceleration, as in Windows Phone.
    public static let folderExpansionDuration: TimeInterval = 0.28

    /// Per-index micro-delay of the icon cascade inside the panel, in seconds (D17).
    public static let folderIconStagger: TimeInterval = 0.035

    /// Delay before a panel icon appears, by its index (D17).
    ///
    /// A pure function of the index: negative values are treated as 0.
    /// A separate function is needed by tests — the cascade is verified without timers
    /// and without the UI loop.
    ///
    /// - Parameter index: The tile index in the panel content grid.
    /// - Returns: The animation start delay in seconds.
    public static func staggerDelay(index: Int) -> TimeInterval {
        TimeInterval(max(0, index)) * folderIconStagger
    }

    // MARK: - Bounce move curve

    /// Duration of neighbors moving during reorder, in seconds.
    ///
    /// 0.26 s is the middle of the 0.22–0.28 s range from the design brief. The previous
    /// motions took 0.24 s (the coordinator placeholder) and ~0.25 s (the standard
    /// UIKit batch), so the pace of the drag preview does not change — only the
    /// speed profile is new, with a slight overshoot at the end. Folder panel
    /// expand/close uses its own duration (``folderExpansionDuration``, 0.28 s) and
    /// its own curve; this constant does not affect it.
    static let tileMoveDuration: TimeInterval = 0.26

    /// The neighbor-move curve is `cubic-bezier(0.175, 0.885, 0.32, 1.1)`.
    ///
    /// The second control point has `y` above one (`1.1`): the curve
    /// overshoots the target by a few percent and returns — a slight
    /// "bounce" from the Windows Phone design, without abrupt jumps. The factory is shared by
    /// the grid batch animation (``update(snapshot:animated:)``) and the move of the
    /// coordinator's placeholder; otherwise neighbors and the grab spot would drift apart in the
    /// character of motion. A new object is created on every call:
    /// `UICubicTimingParameters` is an immutable value, so there is no need to
    /// cache it.
    ///
    /// - Returns: The curve parameters for `UIViewPropertyAnimator`.
    static func bounceTimingParameters() -> UICubicTimingParameters {
        UICubicTimingParameters(
            controlPoint1: CGPoint(x: 0.175, y: 0.885),
            controlPoint2: CGPoint(x: 0.32, y: 1.1)
        )
    }

    /// The identifier of the expanded folder; `nil` means all folders are closed (D17).
    ///
    /// Read-only in the public API: the state is changed by ``toggleFolder(_:)``,
    /// ``openFolder(_:animated:)`` and ``closeFolder(animated:)``. In edit
    /// mode native expansion is not triggered, but an explicit host call
    /// is not blocked: the decision stays with the host.
    public private(set) var expandedFolderID: AnyHashable?

    /// Toggles folder expansion (D17): opens a closed folder, closes an open one.
    /// Another expanded folder is closed first without animation:
    /// at most one folder is expanded at a time.
    ///
    /// A repeated tap on a folder that is already closing (for the first
    /// ~0.12 s the icons fade out and `expandedFolderID` is not yet cleared) means "open
    /// again", not "close once more" — the last target wins.
    ///
    /// - Parameter folder: A folder from the grid's current snapshot.
    public func toggleFolder(_ folder: TesseraTileFolder) {
        if folderTransition == .closing, expandedFolderID == folder.id {
            pendingFolderChange = .open(folder, animated: true)
            return
        }
        if expandedFolderID == folder.id {
            closeFolder(animated: true)
        } else {
            openFolder(folder, animated: true)
        }
    }

    /// Expands a folder with the built-in panel (D17).
    ///
    /// A full-width panel ``TesseraTileGridItem/folderContent(_:)`` appears below
    /// the folder tile: in the collection's item set it is inserted as a
    /// separate element right after the folder tile, while the tile itself stays in
    /// place and visible throughout the expansion. Geometrically the panel occupies the row
    /// right after the row where the folder ends and stretches to the full
    /// width. The batch update only inserts the panel: its height grows
    /// 0 → `panelHeight`, and rows that start below the folder shift down to make room.
    /// Grid scrolling is blocked during the animation (`isScrollEnabled = false`),
    /// and icons appear in a cascade of ~35 ms per index after the growth finishes.
    /// While the folder is expanded, the 2×2 preview mini-tiles on its tile are hidden. With
    /// Reduce Motion (§9) and when off-window the panel appears without animation.
    ///
    /// If the folder is not in the current snapshot, the call does nothing; if another folder is
    /// open, it is closed first.
    ///
    /// Panel transitions are serialized. If an animation is already running, the target
    /// is remembered (the last one wins) and executed after the current
    /// transition finishes; when switching from folder A to B, the open A collapses immediately
    /// and opening B is deferred to the next runloop pass — `reloadData` and
    /// `performBatchUpdates` never end up in the same pass.
    ///
    /// - Parameters:
    ///   - folder: A folder from the grid's current snapshot.
    ///   - animated: Whether to animate the panel appearing (ignored with
    ///     Reduce Motion).
    public func openFolder(_ folder: TesseraTileFolder, animated: Bool = true) {
        // An explicit host command cancels a deferred one: the last action wins.
        if folderTransition == .idle {
            pendingFolderChange = nil
        }
        guard currentFolder(withID: folder.id) != nil else { return }

        // While a transition is running (including the first ~0.12 s of closing, when the folder
        // is still considered expanded), a repeated tap on it is an "open" target,
        // not a no-op: the last target wins.
        if folderTransition != .idle {
            pendingFolderChange = .open(folder, animated: animated)
            return
        }

        guard expandedFolderID != folder.id else { return }

        if expandedFolderID != nil {
            // Another folder is expanded: collapse it instantly (reloadData).
            // The animated opening of the target is deferred to the next runloop
            // pass so the batch insertion of the panel does not mix with reloadData.
            let deferOpen = animated && canAnimateFolderChange
            collapseExpansion(animated: false, notify: true)
            if deferOpen {
                pendingFolderChange = .open(folder, animated: animated)
                scheduleDeferredFolderWork()
                return
            }
        }

        performOpen(folder, animated: animated)
    }

    /// Closes the panel of the expanded folder (D17).
    ///
    /// The panel icons fade out, then its height collapses and the panel itself is
    /// removed from the item set: the folder tile stays in place the whole time, and the
    /// items below the panel move up. On close the preview mini-tiles
    /// return on the tile. When done, scrolling is unblocked and
    /// `contentOffset` is clamped to the new content bounds. The host can
    /// call this method to close on Back without waiting for a tap.
    ///
    /// Closing during a running transition is deferred (the last target
    /// wins); the non-animated branch also clamps `contentOffset` and
    /// posts `.layoutChanged`.
    ///
    /// - Parameter animated: Whether to animate closing (ignored with
    ///   Reduce Motion).
    public func closeFolder(animated: Bool = true) {
        if folderTransition == .idle {
            pendingFolderChange = nil
        }
        collapseExpansion(animated: animated, notify: true)
    }

    // MARK: - Live tiles (§4)

    /// Schedule parameters of live flips (§4).
    ///
    /// Defaults to the values of ``TesseraLiveTileEngine/Configuration``. A change
    /// is applied immediately to an already created ``liveTileEngine``: the engine
    /// reschedules the cycle and updates the flip duration of registered
    /// tiles. For a grid without live tiles the setting creates nothing.
    public var liveTileConfiguration: TesseraLiveTileEngine.Configuration {
        get { storedLiveTileConfiguration }
        set {
            storedLiveTileConfiguration = newValue
            storedLiveTileEngine?.configuration = newValue
        }
    }

    /// The grid's live tile engine (docs/STARTSCREEN-IOS-DESIGN.md §4).
    ///
    /// One per grid: cells are reused, the engine is not. It is created on
    /// first access, that is, on the first live tile in the snapshot: a static
    /// desktop needs no timers or subscriptions. The engine computes the stagger itself,
    /// holds the pauses (off-screen, background, Reduce Motion) and retains the
    /// registered containers — the grid must unregister when a cell
    /// leaves the screen, which it does in `didEndDisplaying`/`prepareForReuse`.
    public var liveTileEngine: TesseraLiveTileEngine {
        if let engine = storedLiveTileEngine {
            return engine
        }
        let engine = TesseraLiveTileEngine(configuration: storedLiveTileConfiguration)
        storedLiveTileEngine = engine
        return engine
    }

    /// Pause of the grid's live content (§4, "Pauses").
    ///
    /// `true` — live tiles and the idle flip of folder previews are frozen but stay
    /// registered: lifting the pause resumes the schedule without
    /// recreating cells. The host enables the pause while the START page is not shown
    /// (the pager forwards appearance only to the current page): otherwise flips
    /// run off-screen and drain the battery.
    ///
    /// The pause is honored in ``configure(_:with:isVisible:)`` (new and
    /// reused cells are not registered as visible) and is applied to
    /// visible cells when toggled. Therefore `update(snapshot:)`/`reload`
    /// that arrive bypassing the controller do not resume tiles while the pause
    /// is on. Cells hidden during a drag (`setItemHidden`) are not
    /// "resurrected" by the pause.
    public var isLiveContentPaused: Bool = false {
        didSet {
            guard isLiveContentPaused != oldValue else { return }
            applyLiveContentPause()
        }
    }

    /// Re-reads the live content of a visible tile (§4).
    ///
    /// Needed by providers without a `startObservingChanges` subscription (§10): after
    /// their state changes they ask the host to refresh the tile. Providers
    /// with a subscription get the same automatically. The refresh does not start a
    /// flip — the schedule stays as it was.
    ///
    /// - Parameter id: The tile identifier. For a static tile, a folder, or an
    ///   off-screen item the call does nothing.
    public func refreshLiveTile(forItemID id: AnyHashable) {
        guard let cell = cellView(forItemID: id) as? TesseraTileCell,
              let liveTileView = cell.liveTileView,
              let engine = storedLiveTileEngine else {
            return
        }
        engine.refresh(liveTileView)
    }

    // MARK: - Layout configuration

    /// Number of grid columns; defaults to 6 small columns (D26,
    /// ``TesseraTileLayoutEngine/defaultColumns``): three medium tiles per row, as in
    /// Windows 10 Mobile. The host may set its own value.
    ///
    /// Change before display or together with a screen width change: the grid
    /// invalidates the layout immediately but does not animate the change —
    /// animating the column count is not required in v1.
    public var columns: Int {
        get { tileLayout.columns }
        set {
            guard newValue != tileLayout.columns else { return }
            // The position and height of an expanded folder's panel depend on the column count:
            // together with the unit, the width of the content cell and the packing of
            // neighbors change. Reset the item cache and, if a folder is open,
            // rebuild the whole set, otherwise the panel and neighbors drift apart.
            invalidateDisplayItems()
            tileLayout.columns = newValue
            // The applicability of the cell table depends on the column count, and with it
            // the reading order; if it changed, the collection's item set is rebuilt.
            let orderChanged = reorderSnapshotForCurrentColumns()
            if expandedFolderID != nil || orderChanged {
                pushDisplayItemsToLayout(reason: .items)
                collectionView.reloadData()
            }
            columnsDidChange?(newValue)
        }
    }

    /// Internal callback for a column count change.
    ///
    /// The edit coordinator reports the new width to `TesseraTileStore` (cells
    /// are stored on a canvas of a specific width, D32) and, if editing is in progress,
    /// rebuilds the snapshot for it. Called after the layout has already
    /// received the new value; not public API.
    var columnsDidChange: ((Int) -> Void)?

    /// Outer grid insets in points. 16 on all sides by default.
    ///
    /// Set on the layout, not on `collectionView.contentInset`: the grid has a single
    /// source of insets, otherwise the unit formula of §3 would start to fork.
    public var contentInsets: UIEdgeInsets {
        get { tileLayout.contentInsets }
        set { tileLayout.contentInsets = newValue }
    }

    /// Gap between adjacent grid units in points. 8 by default.
    public var itemSpacing: CGFloat {
        get { tileLayout.itemSpacing }
        set { tileLayout.itemSpacing = newValue }
    }

    // MARK: - Scrolling

    /// The current scroll offset of the grid.
    public var contentOffset: CGPoint {
        collectionView.contentOffset
    }

    /// The size of the grid's scrollable content.
    ///
    /// Taken from the layout rather than `collectionView.contentSize`: UICollectionView
    /// updates its `contentSize` at the end of the layout pass, while the drag
    /// coordinator needs the value right after ``update(snapshot:animated:)``.
    public var contentSize: CGSize {
        tileLayout.collectionViewContentSize
    }

    /// Whether grid scrolling is enabled.
    ///
    /// The edit coordinator disables it during a drag
    /// if it drives autoscroll at the edges itself; otherwise the finger would scroll the grid and
    /// drag the tile at the same time.
    ///
    /// The grid is the sole owner of the flag. The property sets the
    /// *requested* state; the actual one (`collectionView.isScrollEnabled`)
    /// additionally accounts for temporary lock reasons — the expanded
    /// folder panel during its animation. Removing a reason does not "resurrect" a stale
    /// value: if the coordinator keeps scrolling off, it stays
    /// off after the animation finishes.
    ///
    /// The getter returns the actual state, not the requested one. The getter/setter
    /// pair is therefore asymmetric, and the read-modify-write pattern
    /// (`snapshot = grid.isScrollEnabled; …; grid.isScrollEnabled = snapshot`)
    /// does not guarantee restoration during the panel animation: the panel
    /// lock is a reason, not a request. A host that temporarily disables
    /// scrolling should store its own intent instead of reading the getter.
    public var isScrollEnabled: Bool {
        get { collectionView.isScrollEnabled }
        set {
            isScrollEnabledRequested = newValue
            updateScrollEnabled()
        }
    }

    // MARK: - Internal state

    /// The grid layout; not exposed — it is configured by the properties above.
    private let tileLayout: TesseraTileCollectionViewLayout

    /// The collection of cells.
    private let collectionView: UICollectionView

    /// The long-press gesture (enabled only when ``onLongPress`` is set).
    private let longPressRecognizer = UILongPressGestureRecognizer()

    /// A tap on empty grid space closes an expanded folder (D17).
    ///
    /// Attached to the collection rather than the grid itself: the handler checks
    /// the hit test itself, so a tap on a cell (including the panel) does not close it.
    private let backgroundTapRecognizer = UITapGestureRecognizer()

    /// A passive observer of the touch offset: a collection cell selection
    /// does not fire as a tap if the finger moved beyond the tolerance.
    ///
    /// `UICollectionView` selection itself does not check the offset: when the collection's own pan
    /// did not begin (a horizontal swipe over a vertical grid, a host
    /// without a pager), releasing over a tile still delivered `didSelect`.
    /// Internal — tests set the flag without real touches.
    let tapSlopRecognizer = TesseraTileTapSlopRecognizer()

    /// The item cache with the expanded folder's panel inserted.
    ///
    /// Recomputed rarely — when the snapshot changes, when a folder expands/closes, and when the
    /// column count changes — rather than on every collection query: the insertion looks up the folder's index
    /// in the snapshot.
    private var cachedDisplayItems: [TesseraTileGridItem]?

    /// The folder panel transition.
    ///
    /// A state machine instead of a flag: a single runloop pass runs either
    /// `reloadData` or `performBatchUpdates`, and competing commands
    /// (a second folder, closing, `update(snapshot:)`) wait for the transition to finish.
    private enum FolderTransitionState: Equatable {
        /// The panel is stable: a transition can begin.
        case idle
        /// The panel is expanding (the batch insertion has already been sent).
        case opening
        /// The panel is closing (the icons fade out, then the cell is removed).
        case closing
    }

    /// A deferred panel command: the last target wins.
    private enum FolderChange {
        case open(TesseraTileFolder, animated: Bool)
        case close(animated: Bool)
    }

    /// The current panel transition.
    private var folderTransition = FolderTransitionState.idle

    /// A deferred panel target if the command arrived during a transition.
    private var pendingFolderChange: FolderChange?

    /// A snapshot that arrived during a panel transition.
    ///
    /// Applied after the transition finishes: UICollectionView does not tolerate a `reloadData`/diff on top of an unfinished
    /// batch update.
    private var pendingSnapshot: TesseraTileGridSnapshot?

    /// Whether to animate the deferred snapshot.
    private var pendingSnapshotAnimated = false

    /// Whether the last snapshot was applied with a cross-fade.
    ///
    /// An internal flag for tests: confirms that with Reduce Motion
    /// the cross-fade branch does not run. Has no public value.
    private(set) var didApplyLastSnapshotWithCrossfade = false

    /// Whether the last snapshot was applied in a "no animation" context.
    ///
    /// An internal flag for tests: the non-animated path must go through
    /// `UIView.performWithoutAnimation`, otherwise `performBatchUpdates` animates
    /// the content change with the default duration. Has no public value.
    private(set) var didApplyLastSnapshotWithoutAnimation = false

    /// Whether processing of deferred commands is scheduled for the next runloop pass.
    private var hasScheduledFolderWork = false

    /// Actions waiting for the panel transition to finish and for the deferred
    /// snapshot and command to be applied (D45).
    ///
    /// An internal seam for the edit coordinator: after the panel of a dissolved
    /// folder closes, the VoiceOver focus must move to the remaining tile **after**
    /// the grid applied the deferred snapshot, not to the folder tile
    /// that is about to disappear (``postFolderLayoutChanged(expanded:folderID:)`` at the
    /// end of closing puts the focus on it).
    private var folderSettleActions: [() -> Void] = []

    /// The scroll state requested from outside.
    private var isScrollEnabledRequested = true

    /// A scroll lock reason: the folder panel animation.
    private var isFolderPanelScrollLocked = false

    /// Whether a folder panel expand/close animation is running (D17).
    ///
    /// An internal flag (read by tests): the panel insertion uses it to prepare the
    /// cascade, and tests wait for the transition to finish without timers.
    private(set) var isFolderChangeAnimating = false

    /// The Reduce Motion provider (§9).
    ///
    /// The system setting by default. An internal seam for tests: to check
    /// the Reduce Motion branches deterministically without changing the system setting.
    var isReduceMotionEnabled: () -> Bool = {
        TesseraAccessibility.isReduceMotionEnabled
    }

    /// Posting of accessibility notifications (§9).
    ///
    /// `UIAccessibility.post(notification:argument:)` by default.
    /// An internal seam for tests: `.layoutChanged` in the panel expand/close
    /// branches cannot be observed by system means without VoiceOver enabled.
    var accessibilityNotificationPoster: (UIAccessibility.Notification, Any?) -> Void = {
        UIAccessibility.post(notification: $0, argument: $1)
    }

    /// Called after the expanded folder's panel is configured.
    ///
    /// An internal seam for the edit coordinator: it receives the folder and the cells of its
    /// tiles in order to set VoiceOver custom actions on them.
    var panelShortcutsDidConfigure: ((TesseraTileFolder, [TesseraTileCell]) -> Void)?

    /// Called when the expanded folder's panel changes its stable state
    /// (D46): an animated transition began, it finished, or the panel
    /// opened/closed without animation.
    ///
    /// An internal seam for the edit coordinator: it synchronously shows the
    /// unpin buttons on the panel's tiles once it settles and removes them
    /// while the panel is moving (opening, closing). The callback is synchronous and must not
    /// change the grid snapshot (see `onFolderExpansionChanged`).
    var folderPanelStateDidChange: (() -> Void)?

    /// The expand/close animator of the panel (D17).
    ///
    /// Retained while the animation runs: this way it cannot be lost between frames,
    /// and completion is guaranteed to unblock scrolling.
    private var folderAnimator: UIViewPropertyAnimator?

    /// The animator of the last neighbor move.
    ///
    /// Retained for the duration of the animation, like ``folderAnimator``: the batch update
    /// must finish even if the calling code holds no local reference.
    /// Completion clears the property only for its own animator — a quick
    /// repeated update must not "lose" a newer one.
    private var tileMoveAnimator: UIViewPropertyAnimator?

    /// Items hidden by the edit coordinator.
    ///
    /// Stored by identifier, not by index: after a reorder
    /// or reload the index changes, but the same item must remain
    /// hidden. Hiding does not change the layout — the tile's place is kept.
    private var hiddenItemIDs: Set<AnyHashable> = []

    /// Target alpha values of tile content in edit mode.
    ///
    /// The grid owns the dimming: ``configure(_:with:isVisible:)`` applies the
    /// stored alpha after the cell content rather than resetting it
    /// to 1. The edit coordinator changes only this state
    /// (``setEditDimming(_:animated:)``), so the 0.7 dimming survives
    /// `update`/resize/drop and cell reuse. Hiding during a drag
    /// (`hiddenItemIDs`) overrides the dimming: `contentView.alpha` = 0.
    private var editDimmingAlphas: [AnyHashable: CGFloat] = [:]

    /// Badge insets from the edit mode size arrows (D29).
    ///
    /// Like the dimming, they belong to the grid: they survive snapshot updates and
    /// cell reuse. An empty entry means outside editing (0).
    private var badgeEditClearances: [AnyHashable: CGFloat] = [:]

    /// Alpha of an unselected tile in edit mode.
    ///
    /// 0.7 comes from the Windows Phone spec: tiles stay readable and available for actions,
    /// but the background visually recedes while the selected/dragged one comes forward.
    static let dimmedTileAlpha: CGFloat = 0.7

    /// Duration of the dimming transition.
    static let dimmingDuration: TimeInterval = 0.18

    /// The identifier of a grid cell.
    private static let cellReuseIdentifier = "TesseraTileCell"

    /// The identifier of the expanded folder's panel cell (D17).
    private static let folderPanelReuseIdentifier = "TesseraFolderPanelCell"

    /// The live tile engine; `nil` means the grid has not yet seen live content.
    ///
    /// Stored separately from the computed ``liveTileEngine`` so that
    /// ``liveTileConfiguration`` does not create an engine (and its observers) for a grid
    /// without live tiles.
    private var storedLiveTileEngine: TesseraLiveTileEngine?

    /// Parameters with which ``liveTileEngine`` will be created.
    private var storedLiveTileConfiguration = TesseraLiveTileEngine.Configuration()

    // MARK: - Initialization

    /// Creates an empty grid.
    ///
    /// - Parameter frame: The initial frame; the host usually lays out the grid.
    public override init(frame: CGRect) {
        let layout = TesseraTileCollectionViewLayout()
        tileLayout = layout
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        commonInit()
    }

    /// Creates a grid from an archive/storyboard.
    ///
    /// - Parameter coder: The archive decoder.
    public required init?(coder: NSCoder) {
        let layout = TesseraTileCollectionViewLayout()
        tileLayout = layout
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Shared setup: the collection, the cell, the gesture and Dynamic Type.
    private func commonInit() {
        backgroundColor = .clear
        // §9: the grid is a container, its items are cells; it is not an element itself.
        isAccessibilityElement = false

        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        // The grid insets live in the layout; do not touch the collection's contentInset,
        // otherwise the unit formula of §3 would get a second correction.
        collectionView.contentInset = .zero
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            TesseraTileCell.self,
            forCellWithReuseIdentifier: TesseraTileGridView.cellReuseIdentifier
        )
        // D17: the expanded folder's panel is a separate cell: on expansion it is
        // inserted below the folder tile with a standard batch update, so the neighbors
        // below the panel move with the UICollectionView animation, without manual geometry.
        collectionView.register(
            TesseraFolderPanelCell.self,
            forCellWithReuseIdentifier: TesseraTileGridView.folderPanelReuseIdentifier
        )

        // D17: a tap on empty space closes the expanded folder. The gesture does not cancel
        // touches (`cancelsTouchesInView = false`), otherwise cell
        // selection would stop working; the hit test in the handler filters out taps on items.
        backgroundTapRecognizer.cancelsTouchesInView = false
        backgroundTapRecognizer.delegate = self
        backgroundTapRecognizer.addTarget(self, action: #selector(handleBackgroundTap(_:)))
        collectionView.addGestureRecognizer(backgroundTapRecognizer)
        collectionView.addGestureRecognizer(tapSlopRecognizer)

        longPressRecognizer.minimumPressDuration = 0.45
        longPressRecognizer.delegate = self
        longPressRecognizer.addTarget(self, action: #selector(handleLongPress(_:)))
        // Until the host sets onLongPress, the gesture is off and does not steal
        // touches from ordinary taps.
        longPressRecognizer.isEnabled = false
        collectionView.addGestureRecognizer(longPressRecognizer)

        addSubview(collectionView)

        // §9, Dynamic Type: cell fonts are rebuilt when the category changes.
        // One observer per grid instead of an observer in every cell.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
        // Keyboard handling while renaming a folder. The observers are permanent —
        // see ``lastKeyboardFrame``.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    // MARK: - Size

    public override func layoutSubviews() {
        super.layoutSubviews()
        if collectionView.frame != bounds {
            collectionView.frame = bounds
        }
    }

    // MARK: - Data

    /// Replaces the grid snapshot without animation.
    ///
    /// Used on first display, after `TesseraTileStore.load()`, and wherever the
    /// host animates the change itself (for example, the fly-out on unpin).
    ///
    /// If a folder panel transition is running at that moment, the snapshot is remembered
    /// and applied right after it finishes — `reloadData`/a diff must not
    /// land inside an unfinished batch update.
    ///
    /// - Parameter snapshot: The new grid snapshot.
    public func reload(snapshot: TesseraTileGridSnapshot) {
        let snapshot = readingOrdered(snapshot)
        if deferSnapshotIfTransitioning(snapshot, animated: false) { return }
        apply(snapshot, animated: false)
    }

    /// Applies a snapshot with a resize/reorder animation (§5).
    ///
    /// If the set of items is the same (only sizes and order change), UICollectionView
    /// animates the cell reorder, and the layout is repacked through
    /// invalidation with a context (§3). The move uses the bounce curve
    /// (``bounceTimingParameters()``): neighbors slightly overshoot the target and
    /// return, without abrupt jumps. When the set of items changes (pin/unpin), the grid
    /// applies the snapshot as a diff with a cross-fade: point insert/delete
    /// is animated by the edit coordinator if it needs its own effect.
    ///
    /// A snapshot that arrives during a folder panel transition is remembered
    /// (the last one wins) and applied after the transition finishes.
    ///
    /// The table of explicit cells of the snapshot (``TesseraTileGridSnapshot/placementTable``)
    /// is part of the layout geometry key, so a snapshot in which only
    /// the cells changed (the same items in the same order) is a layout change:
    /// it takes the same "same set of items" branch as a reorder and moves with the
    /// batch animation on the bounce curve. An unchanged snapshot does not
    /// recompute the geometry (the key is equal).
    ///
    /// With Reduce Motion (§9) the animation is disabled: the snapshot is applied immediately,
    /// without a cross-fade.
    ///
    /// - Parameters:
    ///   - newSnapshot: The new grid snapshot.
    ///   - animated: Whether to animate the change if the grid is on screen.
    public func update(snapshot rawSnapshot: TesseraTileGridSnapshot, animated: Bool) {
        // Item order is the reading order of cells; the before/after comparison
        // below already works in that order.
        let newSnapshot = readingOrdered(rawSnapshot)
        if deferSnapshotIfTransitioning(newSnapshot, animated: animated) { return }

        let oldIDs = snapshot?.items.map { $0.id } ?? []
        let newIDs = newSnapshot.items.map { $0.id }
        let shouldAnimate = animated
            && window != nil
            && !isReduceMotionEnabled()

        hiddenItemIDs.formIntersection(newIDs)

        // D17: while a folder is expanded the item set contains the panel, and item indexes do not
        // match the snapshot indexes. Moves are not needed for the panel — the snapshot is
        // applied as a whole (a diff with a cross-fade if the grid is on screen),
        // and expansion is kept as long as the folder is in the new snapshot.
        if expandedFolderID != nil {
            apply(newSnapshot, animated: shouldAnimate)
            return
        }

        guard shouldAnimate, !oldIDs.isEmpty else {
            apply(newSnapshot, animated: shouldAnimate)
            return
        }

        if Set(oldIDs) == Set(newIDs) {
            // Same set of items: resize/reorder. The snapshot is updated before the batch updates
            // so that the dataSource already returns the new items, and the layout is
            // repacked within the same pass — then UICollectionView
            // animates the shift of neighboring tiles itself (§3, §5).
            snapshot = newSnapshot
            invalidateDisplayItems()

            // If the order did not change (only resize/badges), the cell content
            // can be updated right away — there is nothing for the cells to move with. On a reorder
            // the content travels with the cell and is updated on completion.
            if oldIDs == newIDs {
                refreshVisibleCells()
            }

            // A reorder uses the bounce curve, not a cross-fade; the flags
            // of snapshot application must not be left over from the previous call.
            didApplyLastSnapshotWithCrossfade = false
            didApplyLastSnapshotWithoutAnimation = false

            // A batch update inside a UIViewPropertyAnimator inherits the
            // duration and curve — UICollectionView moves each shifted
            // tile with a slight "bounce" rather than the standard UIKit curve.
            let animator = UIViewPropertyAnimator(
                duration: TesseraTileGridView.tileMoveDuration,
                timingParameters: TesseraTileGridView.bounceTimingParameters()
            )
            animator.addAnimations { [weak self] in
                guard let self else { return }
                self.collectionView.performBatchUpdates({
                    self.pushDisplayItemsToLayout(reason: .items)
                    self.applyIndexMoves(from: oldIDs, to: newIDs)
                }, completion: { [weak self] _ in
                    self?.refreshVisibleCells()
                })
            }
            animator.addCompletion { [weak self, weak animator] _ in
                guard let self, let animator, self.tileMoveAnimator === animator else {
                    return
                }
                self.tileMoveAnimator = nil
            }
            tileMoveAnimator = animator
            animator.startAnimation()
        } else {
            apply(newSnapshot, animated: true)
        }
    }

    /// Remembers the snapshot if a folder panel transition is running.
    ///
    /// - Parameters:
    ///   - snapshot: The snapshot to apply.
    ///   - animated: Whether to animate its application.
    /// - Returns: `true` if the snapshot was deferred.
    private func deferSnapshotIfTransitioning(
        _ snapshot: TesseraTileGridSnapshot,
        animated: Bool
    ) -> Bool {
        guard folderTransition != .idle else { return false }
        pendingSnapshot = snapshot
        pendingSnapshotAnimated = animated
        return true
    }

    /// Applies a snapshot to the collection.
    ///
    /// On screen, the set of items is applied as a diff (`performBatchUpdates`
    /// insert/delete; moves belong to the resize/reorder branch) rather than `reloadData`:
    /// cells that stay in place keep their live-tile registration and the phase of the
    /// folder preview idle flip. Visible cells are reconfigured on
    /// completion (badge, title, panel content). Off-window, on first
    /// display, and when the order of common items changes, `reloadData` is applied
    /// (mixing move with insert/delete is unreliable).
    ///
    /// - Parameters:
    ///   - newSnapshot: The new snapshot.
    ///   - animated: Cross-fade when the set of items changes; the call already accounts for Reduce
    ///     Motion.
    private func apply(_ newSnapshot: TesseraTileGridSnapshot, animated: Bool) {
        // A batch update relies on the previous number of collection items:
        // if the snapshot arrived before the first layout pass (a rare but
        // possible case for a just-created page), bring the layout up to date
        // before the model changes. Off-window no diff is needed — see below.
        if window != nil {
            collectionView.layoutIfNeeded()
        }

        // Keys of the "before" set: the diff is computed from them. The panel and its folder share
        // an identifier, so the key includes the panel flag.
        let oldKeys = displayItems.map(DisplayItemKey.init)

        // D17: if the open folder disappeared from the model (dissolved, unpinned),
        // expansion is cleared — a panel cannot remain without its folder. The host is
        // notified about the close only after the snapshot is applied.
        var collapsedFolder: TesseraTileFolder?
        if let expandedID = expandedFolderID,
           newSnapshot.items.compactMap({ $0.folder }).first(where: { $0.id == expandedID }) == nil {
            collapsedFolder = currentFolder(withID: expandedID)
            expandedFolderID = nil
        }

        snapshot = newSnapshot
        hiddenItemIDs.formIntersection(newSnapshot.items.map { $0.id })
        // The dimming belongs to the grid: entries of vanished items are not kept,
        // otherwise after a repeated pin the dimming would return to someone else's cell.
        editDimmingAlphas = editDimmingAlphas.filter { entry in
            newSnapshot.items.contains { $0.id == entry.key }
        }
        badgeEditClearances = badgeEditClearances.filter { entry in
            newSnapshot.items.contains { $0.id == entry.key }
        }
        invalidateDisplayItems()

        let update = { [weak self] in
            guard let self else { return }
            let newKeys = self.displayItems.map(DisplayItemKey.init)
            // Same set of items: only content/geometry change.
            if oldKeys == newKeys {
                self.pushDisplayItemsToLayout(reason: .items)
                self.refreshVisibleCells()
                return
            }
            // A diff is allowed only on screen and when common items keep their
            // relative order: then insertions and deletions suffice, and
            // UICollectionView does the shifts itself. The first display/full replacement,
            // the combined "set + reorder" case, and a grid off-window
            // (no visual state) go through `reloadData`:
            // mixing `move` with insert/delete in one batch is unreliable, and
            // the move branch already exists for resize/reorder
            // (``applyIndexMoves(from:to:)``).
            let canApplyDiff = self.window != nil
                && self.collectionView.bounds.width > 0
                && !oldKeys.isEmpty
                && !newKeys.isEmpty
                && TesseraTileGridView.preservesRelativeOrder(from: oldKeys, to: newKeys)
            guard canApplyDiff else {
                self.pushDisplayItemsToLayout(reason: .items)
                self.collectionView.reloadData()
                self.refreshVisibleCells()
                return
            }
            self.collectionView.performBatchUpdates({
                self.pushDisplayItemsToLayout(reason: .items)
                self.applyDisplayDiff(from: oldKeys, to: newKeys)
            }, completion: { [weak self] _ in
                self?.refreshVisibleCells()
            })
        }

        // A cross-fade only if the snapshot is actually animated;
        // with Reduce Motion the call arrives with animated == false from `update`.
        didApplyLastSnapshotWithCrossfade = animated && window != nil
        didApplyLastSnapshotWithoutAnimation = !didApplyLastSnapshotWithCrossfade
        if didApplyLastSnapshotWithCrossfade {
            UIView.transition(
                with: collectionView,
                duration: 0.2,
                options: [.transitionCrossDissolve, .allowUserInteraction],
                animations: update,
                completion: nil
            )
        } else {
            // Contract of `reload(snapshot:)`/`update(animated: false)`:
            // apply the snapshot without animation. `performBatchUpdates` outside an
            // animation block would otherwise animate insert/delete with the UIKit default
            // duration (~0.25 s); `performWithoutAnimation` suppresses both batch animations
            // and implicit layer actions (as in a diffable data
            // source).
            UIView.performWithoutAnimation {
                update()
            }
        }

        if let collapsedFolder {
            onFolderExpansionChanged?(collapsedFolder, false)
        }
    }

    /// Identity of a collection item for diff-applying a snapshot.
    ///
    /// The identifier of the expanded folder's panel matches the identifier of the
    /// folder itself, so a single "id" is not enough: the panel flag is part of the
    /// key, otherwise the panel and its folder would count as one item.
    private struct DisplayItemKey: Hashable {
        /// The item identifier.
        let id: AnyHashable

        /// Whether the item is an expanded folder's panel.
        let isPanel: Bool

        /// The key for a grid item.
        ///
        /// - Parameter item: A collection item.
        init(_ item: TesseraTileGridItem) {
            id = item.id
            isPanel = item.isFolderPanel
        }
    }

    /// Checks whether common items keep their relative order.
    ///
    /// If so, a change of the item set can be applied with insertions and deletions only:
    /// unchanged items are shifted by UICollectionView itself, and cells
    /// keep their live-tile registration and folder preview phase. If the order
    /// of common items changed, `move` is needed, and mixing it with
    /// insert/delete in one batch is unreliable — the caller applies the
    /// snapshot through `reloadData`.
    ///
    /// - Parameters:
    ///   - oldKeys: Item keys in the old order.
    ///   - newKeys: Item keys in the new order.
    /// - Returns: `true` if the order of common keys is the same.
    private static func preservesRelativeOrder(
        from oldKeys: [DisplayItemKey],
        to newKeys: [DisplayItemKey]
    ) -> Bool {
        var newIndexByKey: [DisplayItemKey: Int] = [:]
        newIndexByKey.reserveCapacity(newKeys.count)
        for (index, key) in newKeys.enumerated() {
            newIndexByKey[key] = index
        }

        var previousIndex = Int.min
        for key in oldKeys {
            guard let newIndex = newIndexByKey[key] else { continue }
            guard newIndex > previousIndex else { return false }
            previousIndex = newIndex
        }
        return true
    }

    /// Diff of the collection's item set.
    ///
    /// Called **inside** `performBatchUpdates` and only when common
    /// items kept their relative order (``preservesRelativeOrder(from:to:)``):
    /// deletions are in coordinates of the old set, insertions in those of the new one; items
    /// that stay in the set are not touched and keep their state, while the shift
    /// caused by insertions/deletions is done by UICollectionView itself.
    ///
    /// - Parameters:
    ///   - oldKeys: Item keys in the old order.
    ///   - newKeys: Item keys in the new order.
    private func applyDisplayDiff(
        from oldKeys: [DisplayItemKey],
        to newKeys: [DisplayItemKey]
    ) {
        let oldKeySet = Set(oldKeys)
        let newKeySet = Set(newKeys)

        let deleted = oldKeys.indices.filter { !newKeySet.contains(oldKeys[$0]) }
        let inserted = newKeys.indices.filter { !oldKeySet.contains(newKeys[$0]) }

        if !deleted.isEmpty {
            collectionView.deleteItems(
                at: deleted.map { IndexPath(item: $0, section: 0) }
            )
        }
        if !inserted.isEmpty {
            collectionView.insertItems(
                at: inserted.map { IndexPath(item: $0, section: 0) }
            )
        }
    }

    /// Reorders cells to follow the model so that the animation carries each tile
    /// with its content.
    ///
    /// For every tile that moved from its previous place, one
    /// `moveItem` is sent: `from` is the index in the original order, `to` is the index in the new one.
    /// This is the UICollectionView batch update contract (as in IGListKit): all
    /// moves are described in "before/after" coordinates as a single batch, not
    /// sequentially, so swapping two tiles is two opposing moves.
    /// The method is called only when the set of items is the same, so moves do not
    /// change the number of collection items.
    ///
    /// - Parameters:
    ///   - oldIDs: Identifiers in the old order.
    ///   - newIDs: Identifiers in the new order.
    private func applyIndexMoves(from oldIDs: [AnyHashable], to newIDs: [AnyHashable]) {
        for (oldIndex, itemID) in oldIDs.enumerated() {
            guard let newIndex = newIDs.firstIndex(of: itemID), newIndex != oldIndex else {
                continue
            }

            collectionView.moveItem(
                at: IndexPath(item: oldIndex, section: 0),
                to: IndexPath(item: newIndex, section: 0)
            )
        }
    }

    /// Re-reads the content of visible cells without reloading the collection.
    ///
    /// Needed after an animated resize/reorder and after a diff-applied
    /// snapshot: frames and order are already updated, but the badge/size/folder
    /// contents may have changed for cells that did not move. The layout is not
    /// invoked.
    private func refreshVisibleCells() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let item = displayItem(atIndex: indexPath.item) else { continue }

            if item.isFolderPanel {
                // An expanded folder's panel is reconfigured rather than just
                // rebuilding the font: the set/badges of its tiles may have changed
                // in the new snapshot, and `reloadData` no longer recreates the cell.
                guard let panelCell = collectionView.cellForItem(
                    at: indexPath
                ) as? TesseraFolderPanelCell else {
                    continue
                }
                configure(panelCell, with: item)
                panelCell.refreshTypography()
                continue
            }

            guard let cell = collectionView.cellForItem(at: indexPath) as? TesseraTileCell else {
                continue
            }
            configure(cell, with: item, isVisible: true)
        }
    }

    /// Configures the expanded folder's panel cell (D17).
    ///
    /// The panel is reused: with the same set of tiles `configure` only
    /// reconfigures the tiles, so a snapshot update does not "flicker".
    ///
    /// - Parameters:
    ///   - cell: The panel cell.
    ///   - item: The `folderContent` item from the collection's item set.
    private func configure(_ cell: TesseraFolderPanelCell, with item: TesseraTileGridItem) {
        guard let folder = item.panelFolder else { return }

        cell.configure(
            folder: folder,
            columns: tileLayout.columns,
            spacing: tileLayout.itemSpacing
        )
        // D17: a tap on the panel background/title closes the folder.
        cell.onBackgroundTap = { [weak self] in
            self?.closeFolder(animated: true)
        }
        // D35: renaming — the title is editable while the grid has a
        // handler. Editing can start only on a settled panel of the same folder.
        let folderID = folder.id
        cell.isTitleEditable = folderRenameHandler != nil
        cell.canBeginTitleEditing = { [weak self] in
            guard let self else { return false }
            return self.folderTransition == .idle && self.expandedFolderID == folderID
        }
        cell.onTitleCommit = { [weak self] name in
            self?.folderRenameHandler?(folderID, name)
        }
        cell.onTitleEditingChanged = { [weak self, weak cell] isEditing in
            guard let self, let cell else { return }
            self.folderNameEditingDidChange(isEditing, in: cell)
        }
        // A panel tile is activated through the same route as a grid tile
        // (the host's onTap), not by calling `action` bypassing the event. In edit
        // mode the action is not run: the panel is a presentation, and a
        // tap in edit mode belongs to the coordinator.
        cell.onTapShortcut = { [weak self] descriptor in
            guard let self, !self.isEditModeActive else { return }
            self.handleItemTap(.tile(descriptor))
        }
        // The panel is inserted by the expansion animation: icons are already hidden so that
        // the cascade after the height growth starts without a "flash".
        if isFolderChangeAnimating {
            cell.prepareIconCascade()
        }
        // The edit coordinator attaches VoiceOver custom actions to the panel's
        // tiles; the panel is reconfigured on every snapshot.
        panelShortcutsDidConfigure?(folder, cell.shortcutCells)
    }

    /// Tiles of the visible expanded folder's panel.
    ///
    /// - Returns: The folder from the snapshot and the cells of its tiles (in item order), or
    ///   `nil` if there is no panel.
    func panelShortcuts() -> (folder: TesseraTileFolder, cells: [TesseraTileCell])? {
        guard expandedFolderID != nil, let folder = expandedFolder,
              let panel = collectionView.visibleCells
                  .compactMap({ $0 as? TesseraFolderPanelCell }).first,
              panel.shortcutCells.count == folder.tiles.count else {
            return nil
        }
        return (folder, panel.shortcutCells)
    }

    /// Frames of the visible expanded folder panel's tiles in grid coordinates (D46).
    ///
    /// Needed by the edit coordinator to place the unpin buttons on the
    /// panel's tiles the same way as on grid tiles: the frame is computed from the center and
    /// bounds of the cell (without the appearance cascade `transform`) and accounts for
    /// scrolling, so it follows the panel on every call.
    ///
    /// - Returns: Tile identifiers, their frames in folder item order, and
    ///   the grid gap; `nil` if there is no panel or its cells do not yet match
    ///   the folder's contents.
    func panelShortcutGeometry() -> TesseraPanelShortcutGeometry? {
        guard let panel = panelShortcuts(),
              let cell = collectionView.visibleCells
                  .compactMap({ $0 as? TesseraFolderPanelCell }).first else {
            return nil
        }

        let frames: [CGRect] = panel.cells.map { shortcut in
            let size = shortcut.bounds.size
            let center = shortcut.superview?.convert(shortcut.center, to: self)
                ?? cell.contentView.convert(shortcut.center, to: self)
            return CGRect(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
        let slots = cell.slotFrames.map { cell.contentView.convert($0, to: self) }
        return TesseraPanelShortcutGeometry(
            folderID: panel.folder.id,
            tileIDs: panel.folder.tiles.map { $0.id },
            frames: frames,
            spacing: tileLayout.itemSpacing,
            slotFrames: slots.count == frames.count ? slots : frames,
            panelFrame: cell.convert(cell.bounds, to: self)
        )
    }

    /// Configures a cell for an item and wires up its VoiceOver activation.
    ///
    /// The cell is a single accessibility element (§9), so the VoiceOver double tap
    /// goes to it, not to `didSelectItemAt`. The closure routes the activation
    /// to the same ``onTap`` as an ordinary tap.
    ///
    /// The edit mode dimming (the grid is its owner) and the shared live content pause
    /// are applied here too: `configure` no longer resets either the alpha
    /// or the schedule.
    ///
    /// - Parameters:
    ///   - cell: The grid cell.
    ///   - item: The item it shows.
    ///   - isVisible: Whether the cell is on screen. For `false` the engine is not
    ///     created at all: `cellForItemAt` only prepares the cell, and registration
    ///     in the engine is done by `willDisplay`.
    private func configure(_ cell: TesseraTileCell, with item: TesseraTileGridItem, isVisible: Bool) {
        // An engine is created only for a live tile: a static tile and a folder
        // do not need a flip schedule.
        let engine = isVisible ? liveEngine(for: item) : nil
        // A cell hidden during a drag must not flip "into itself", but its
        // registration is needed: returning from hiding resumes the schedule without a
        // repeated `willDisplay`. The live content pause is stronger.
        let isHidden = hiddenItemIDs.contains(item.id)
        let isLiveVisible = isVisible && !isHidden && !isLiveContentPaused
        cell.configure(
            with: item,
            liveTileEngine: engine,
            isVisible: isLiveVisible,
            isFolderExpanded: item.id == expandedFolderID
        )
        // The dimming is applied after the cell content.
        cell.setDimmingAlpha(editDimmingAlpha(for: item.id))
        cell.setBadgeEditClearance(badgeEditClearances[item.id] ?? 0, animated: false)
        cell.setSourceHidden(isHidden)

        let itemID = item.id
        cell.onActivate = { [weak self] in
            self?.activate(itemID: itemID)
        }
        // D35: a folder tile gets the VoiceOver "Rename" action.
        if case .folder = item, folderRenameHandler != nil {
            cell.onRename = { [weak self] in
                _ = self?.beginRenamingFolder(itemID)
            }
        } else {
            cell.onRename = nil
        }
    }

    /// The engine for an item: `nil` means the tile is static or it is a folder.
    ///
    /// Accessing ``liveTileEngine`` lazily creates the engine, so a grid without
    /// live content creates no timers or observers.
    ///
    /// - Parameter item: A grid item.
    /// - Returns: The engine, or `nil` if the item has no live side.
    private func liveEngine(for item: TesseraTileGridItem) -> TesseraLiveTileEngine? {
        guard case .tile(let descriptor) = item, descriptor.liveContent != nil else {
            return nil
        }
        return liveTileEngine
    }

    /// Applies ``isLiveContentPaused`` to visible cells.
    ///
    /// Cells hidden during a drag stay paused; resuming lifts the
    /// pause only from visible, non-hidden cells. New cells get the state in
    /// ``configure(_:with:isVisible:)``, so `update`/`reload` bypassing the
    /// controller do not lift the pause.
    private func applyLiveContentPause() {
        let isPaused = isLiveContentPaused
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let item = displayItem(atIndex: indexPath.item),
                  !item.isFolderPanel,
                  let cell = collectionView.cellForItem(at: indexPath) as? TesseraTileCell else {
                continue
            }
            let isHidden = hiddenItemIDs.contains(item.id)
            cell.setLiveTileVisible(!isPaused && !isHidden)
        }
    }

    /// VoiceOver activation of an item: the same path as a finger tap.
    ///
    /// - Parameter itemID: The tile or folder identifier.
    private func activate(itemID: AnyHashable) {
        guard !hiddenItemIDs.contains(itemID),
              let index = index(ofItemID: itemID),
              let item = baseItem(atIndex: index) else {
            return
        }
        handleItemTap(item)
    }

    // MARK: - Queries for the host and for editing

    /// The index of an item in grid order.
    ///
    /// The index is computed from the `TesseraTileStore` snapshot, without the expanded folder's panel:
    /// it matches the reading order of the model's cells, and the coordinator
    /// reports the final position to the delegate with it (`didMove(_:toCell:)` carries the cell;
    /// the index remains for VoiceOver and announcements). The panel is addressed separately —
    /// ``expandedFolderID``.
    ///
    /// - Parameter id: The tile or folder identifier.
    /// - Returns: The index, or `nil` if the item is not in the snapshot.
    public func index(ofItemID id: AnyHashable) -> Int? {
        snapshot?.items.firstIndex { $0.id == id }
    }

    /// The item under a point in grid coordinates.
    ///
    /// The hit test uses the actual cell attributes: a hit in a gap or
    /// between rows gives `nil`. Used by the drag coordinator
    /// to find the tile under the finger.
    ///
    /// - Parameter point: A point in grid coordinates (not content coordinates).
    /// - Returns: The item or `nil`.
    public func item(at point: CGPoint) -> TesseraTileGridItem? {
        let pointInCollection = collectionView.convert(point, from: self)
        guard let indexPath = collectionView.indexPathForItem(at: pointInCollection) else {
            return nil
        }
        return displayItem(atIndex: indexPath.item)
    }

    /// The frame of an item in grid coordinates.
    ///
    /// Grid coordinates are the `bounds` of this view: the frame already accounts for
    /// `contentOffset` and insets. For off-screen cells the frame may be
    /// negative — that is fine, the drag layer decides what
    /// to show.
    ///
    /// - Parameter id: The tile or folder identifier.
    /// - Returns: The frame in points, or `nil` if the item is not in the snapshot or the grid
    ///   has never been laid out yet. For an expanded folder the frame of its
    ///   tile is returned: the tile stays in place and the panel sits below it.
    public func frame(forItemID id: AnyHashable) -> CGRect? {
        guard let contentFrame = tileLayout.frame(forItemID: id) else { return nil }
        return collectionView.convert(contentFrame, to: self)
    }

    /// Centers of virtual slots for a tile of the given size.
    ///
    /// The edit coordinator builds magnetism from them: if the finger enters
    /// the attraction radius of the nearest center, the drag image smoothly settles into the cell.
    /// Returns the centers of all cells of the virtual grid that can fit a
    /// tile of `size` (accounting for shrinking on a narrow grid), in grid coordinates.
    ///
    /// The grid is computed from the current geometry (``columns``, ``contentInsets``,
    /// ``itemSpacing``, ``contentOffset``) and the occupied layout rows: slots
    /// are enumerated in steps of one unit, so centers are found over empty
    /// cells too, but not below the last occupied row of the base layout.
    /// The reading direction (RTL) does not affect the result: mirroring
    /// permutes the columns, but the set of centers stays the same.
    ///
    /// The geometry comes from ``TesseraTileLayoutEngine/gridMetrics`` — exactly
    /// as `TesseraTileCollectionViewLayout` computes it (content edges and
    /// gap on the pixel grid, the unit rounded down to a pixel, the remaining width
    /// split evenly between the insets). So the slot centers match the layout frames to the
    /// pixel instead of differing from them by fractions of a point.
    ///
    /// With an expanded folder (D17) an empty array is returned: the panel shifts
    /// the rows, the virtual grid would stop matching the actual slots,
    /// and the drag image must not be attracted "into the void" under the panel.
    ///
    /// - Parameter size: The size of the dragged tile (D15).
    /// - Returns: Slot centers in grid coordinates.
    public func magnetSlotCenters(for size: TesseraTileSize) -> [CGPoint] {
        // D17: an expanded panel shifts the rows — a virtual grid from the base
        // layout would stop matching the screen.
        guard expandedFolderID == nil else { return [] }

        // Repeat the horizontal geometry of the layout exactly:
        // content edges are rounded to a pixel, the content width is their difference,
        // the unit and gap are computed by gridMetrics, and the remaining width goes to the insets.
        let insets = sanitized(contentInsets)
        let columnCount = columns
        let scale = TesseraTileCollectionViewLayout.resolvedDisplayScale(
            traitCollection.displayScale
        )
        let contentLeft = TesseraTileLayoutEngine.pixelRound(insets.left, scale: scale)
        let contentRight = TesseraTileLayoutEngine.pixelRound(
            bounds.width - insets.right,
            scale: scale
        )
        let contentWidth = contentRight - contentLeft
        guard let metrics = TesseraTileLayoutEngine.gridMetrics(
            contentWidth: contentWidth,
            columns: columnCount,
            spacing: sanitized(itemSpacing),
            scale: scale
        ) else {
            return []
        }

        let origin = CGPoint(
            x: contentLeft + metrics.leading,
            y: TesseraTileLayoutEngine.pixelRound(insets.top, scale: scale)
        )

        // The upper bound of the virtual grid is the last occupied row of the base
        // layout: there are no slots below it. The snapshot has no panel by construction, and
        // with an expanded folder the method would have returned earlier.
        // With an applicable table of explicit cells (`TesseraTileGridPlacementTable`)
        // the last occupied row is taken from the cells — holes inside the layout
        // are part of the virtual grid; without a table — packing in order.
        let rowCount: Int
        if let placements = explicitPlacements(for: items, table: snapshot?.placementTable) {
            rowCount = placements.reduce(0) { result, placed in
                let fitted = TesseraTileLayoutEngine.fittingSize(placed.size, columns: columnCount)
                return max(result, placed.cell.row + fitted.unitRows)
            }
        } else {
            let packedItems: [(id: AnyHashable, size: TesseraTileSize)] = items.map { item in
                (
                    id: item.id,
                    size: TesseraTileLayoutEngine.fittingSize(item.size, columns: columnCount)
                )
            }
            let slots = TesseraTileLayoutEngine.pack(
                items: packedItems,
                columns: columnCount,
                unit: metrics.unit
            )
            rowCount = slots.reduce(0) { result, slot in
                max(result, slot.row + slot.unitRows)
            }
        }
        guard rowCount > 0 else { return [] }

        return TesseraTileMagnet.slotCenters(
            for: size,
            columns: columnCount,
            unit: metrics.unit,
            gap: metrics.spacing,
            origin: origin,
            rowCount: rowCount
        ).map { point in
            collectionView.convert(point, to: self)
        }
    }

    /// The geometry key of the base layout.
    ///
    /// Everything the ``baseContentFrames(for:)`` frames depend on: the grid size,
    /// column count, reading direction, screen scale, insets and gap.
    /// The drag coordinator keeps the frames in its session and rebuilds them when the key
    /// changes (rotation, columns/insets changing on the fly).
    struct BaseFramesKey: Equatable {
        var size: CGSize
        var columns: Int
        var isRightToLeft: Bool
        var scale: CGFloat
        var insets: UIEdgeInsets
        var spacing: CGFloat
    }

    /// The current geometry key of the base layout.
    func baseFramesKey() -> BaseFramesKey {
        BaseFramesKey(
            size: collectionView.bounds.size,
            columns: columns,
            isRightToLeft: collectionView.effectiveUserInterfaceLayoutDirection == .rightToLeft,
            scale: tileLayout.displayScaleOverride
                ?? TesseraTileCollectionViewLayout.resolvedDisplayScale(traitCollection.displayScale),
            insets: sanitized(contentInsets),
            spacing: sanitized(itemSpacing)
        )
    }

    /// Item frames as the grid lays them out without the panel and the preview.
    ///
    /// Needed by the drag hit test: the `frame(forItemID:)` frames are already shifted by the push preview,
    /// while the target (center/edge, grouping) is decided by what the user
    /// saw before the shift — that is, by the base-order layout.
    /// The geometry repeats `TesseraTileCollectionViewLayout.rebuild` without the panel: pixel
    /// content edges, `gridMetrics`, `TesseraTileLayoutEngine.pack` packing over the
    /// shrunk sizes, and RTL mirroring within the grid width.
    ///
    /// The frames are in **content coordinates**: they do not change on scroll;
    /// ``gridFrame(fromContentFrame:)`` converts them to grid coordinates.
    ///
    /// The slot source is the same as the layout's. With an applicable table of
    /// explicit cells (`placementTable`: complete, valid for the current columns,
    /// ``TesseraTileGridPlacementTable``) slots are taken from cells, with holes; otherwise
    /// from packing `items` in order. So the frames match what the
    /// layout draws, including for a snapshot with holes. Without the parameter (the default) the behavior
    /// is as before: packing in order.
    ///
    /// - Parameters:
    ///   - items: Items in base order (without the panel).
    ///   - placementTable: The explicit cell table of the snapshot that `items`
    ///     belong to; `nil` means packing in order.
    /// - Returns: Frames by identifier, or `nil` if the geometry cannot be
    ///   computed (zero width).
    func baseContentFrames(
        for items: [TesseraTileGridItem],
        placementTable: TesseraTileGridPlacementTable? = nil
    ) -> [AnyHashable: CGRect]? {
        guard let geometry = baseLayoutGeometry() else { return nil }
        let key = geometry.key
        let metrics = geometry.metrics
        let slots: [TesseraTileLayoutSlot]
        if let placements = explicitPlacements(for: items, table: placementTable) {
            slots = TesseraTileLayoutEngine.slots(
                placements: placements,
                columns: key.columns,
                unit: metrics.unit,
                fitting: true
            )
        } else {
            let packed: [(id: AnyHashable, size: TesseraTileSize)] = items.map { item in
                (id: item.id, size: TesseraTileLayoutEngine.fittingSize(item.size, columns: key.columns))
            }
            slots = TesseraTileLayoutEngine.pack(items: packed, columns: key.columns, unit: metrics.unit)
        }
        guard slots.count == items.count else { return nil }

        var result: [AnyHashable: CGRect] = [:]
        result.reserveCapacity(items.count)
        for (item, slot) in zip(items, slots) {
            var rect = TesseraTileLayoutEngine.rect(
                for: slot,
                unit: metrics.unit,
                gap: metrics.spacing,
                origin: CGPoint(x: geometry.gridLeft, y: geometry.top)
            )
            if key.isRightToLeft {
                let localX = rect.minX - geometry.gridLeft
                rect.origin.x = geometry.gridLeft + metrics.width - localX - rect.width
            }
            result[item.id] = rect
        }
        return result
    }

    /// Shared geometry of the base layout: the key, the unit metrics and the grid origin
    /// in content coordinates.
    ///
    /// Repeats `TesseraTileCollectionViewLayout.rebuild` without the panel: pixel
    /// content edges and `gridMetrics`.
    ///
    /// - Returns: The geometry, or `nil` (zero width).
    private func baseLayoutGeometry() -> (
        key: BaseFramesKey,
        metrics: TesseraTileLayoutEngine.GridMetrics,
        gridLeft: CGFloat,
        top: CGFloat
    )? {
        let key = baseFramesKey()
        let contentLeft = TesseraTileLayoutEngine.pixelRound(key.insets.left, scale: key.scale)
        let contentRight = TesseraTileLayoutEngine.pixelRound(
            key.size.width - key.insets.right,
            scale: key.scale
        )
        let contentWidth = contentRight - contentLeft
        guard contentWidth.isFinite, contentWidth > 0,
              let metrics = TesseraTileLayoutEngine.gridMetrics(
                  contentWidth: contentWidth,
                  columns: key.columns,
                  spacing: key.spacing,
                  scale: key.scale
              ) else {
            return nil
        }
        return (
            key: key,
            metrics: metrics,
            gridLeft: contentLeft + metrics.leading,
            top: TesseraTileLayoutEngine.pixelRound(key.insets.top, scale: key.scale)
        )
    }

    /// The logical cell of the base layout under a point (D21, D33).
    ///
    /// The finger decides **which cell** an item lands in: the row and column
    /// are computed in steps of `unit + gap` from the grid origin (the gap between cells
    /// belongs to the cell on the left/above, as the tail of the cell). The column is
    /// logical, not mirrored: in RTL the point is reflected within the grid width, so
    /// column 0 is the start of reading. The result is **not clamped** to the canvas: over the
    /// insets and below the content it falls outside `0 ..< columns` / the occupied rows; the
    /// caller decides what to do (`clamped`, the "new row" target).
    ///
    /// - Parameter point: A point in grid coordinates.
    /// - Returns: The row and column, or `nil` if the layout cannot be computed
    ///   (zero width, a non-finite point).
    func baseCell(forGridPoint point: CGPoint) -> (row: Int, column: Int)? {
        guard let geometry = baseLayoutGeometry() else { return nil }
        let key = geometry.key
        let metrics = geometry.metrics
        let pitch = metrics.unit + metrics.spacing
        guard pitch.isFinite, pitch > 0 else { return nil }

        let content = contentPoint(fromGridPoint: point)
        let localX = key.isRightToLeft
            ? geometry.gridLeft + metrics.width - content.x
            : content.x - geometry.gridLeft
        guard localX.isFinite, content.y.isFinite else { return nil }

        // Bounds in Double before conversion to Int: with absurd coordinates
        // `Int(_:)` must not crash.
        let limit: CGFloat = 1_000_000
        let column = min(max((localX / pitch).rounded(.down), -limit), limit)
        let row = min(max(((content.y - geometry.top) / pitch).rounded(.down), -limit), limit)
        return (row: Int(row), column: Int(column))
    }

    /// The frame in grid coordinates that an item of size `size` will occupy at
    /// cell `cell` of the base layout.
    ///
    /// The cell is clamped to the canvas (`TesseraTileLayoutEngine.clamped`), the footprint shrinks
    /// for a narrow grid; RTL is mirrored within the grid width, as in the layout.
    /// The drag image's magnet pulls it to the center of this frame.
    ///
    /// - Parameters:
    ///   - cell: The desired cell of the top-left corner (logical).
    ///   - size: The item size (D15).
    /// - Returns: The frame, or `nil` if the geometry cannot be computed.
    func baseFrame(forCell cell: TesseraTileGridPlacement, size: TesseraTileSize) -> CGRect? {
        guard let geometry = baseLayoutGeometry() else { return nil }
        let key = geometry.key
        let metrics = geometry.metrics
        let fitted = TesseraTileLayoutEngine.fittingSize(size, columns: key.columns)
        let target = TesseraTileLayoutEngine.clamped(cell: cell, size: size, columns: key.columns)
        let slot = TesseraTileLayoutSlot(
            id: AnyHashable(0),
            size: fitted,
            column: target.column,
            row: target.row,
            unit: metrics.unit
        )
        var rect = TesseraTileLayoutEngine.rect(
            for: slot,
            unit: metrics.unit,
            gap: metrics.spacing,
            origin: CGPoint(x: geometry.gridLeft, y: geometry.top)
        )
        if key.isRightToLeft {
            let localX = rect.minX - geometry.gridLeft
            rect.origin.x = geometry.gridLeft + metrics.width - localX - rect.width
        }
        return gridFrame(fromContentFrame: rect)
    }

    /// Converts a frame from content coordinates to grid coordinates.
    ///
    /// Accounts for the current `contentOffset`, so an autoscroll frame sees
    /// the same base frames shifted by the actual offset.
    ///
    /// - Parameter frame: A frame in content coordinates.
    /// - Returns: The frame in grid coordinates.
    func gridFrame(fromContentFrame frame: CGRect) -> CGRect {
        collectionView.convert(frame, to: self)
    }

    /// Converts a point from grid coordinates to content coordinates.
    ///
    /// The inverse of ``gridFrame(fromContentFrame:)``: the drag compares the finger with
    /// cached content frames without recomputing them on every step.
    ///
    /// - Parameter point: A point in grid coordinates.
    /// - Returns: The same point in content coordinates.
    func contentPoint(fromGridPoint point: CGPoint) -> CGPoint {
        collectionView.convert(point, from: self)
    }

    /// Sanitizes the outer grid insets the same way the layout does.
    ///
    /// Negative and non-finite values are treated as 0: the virtual attraction
    /// grid must match the actual slots, and the layout
    /// computes the unit from already sanitized insets.
    ///
    /// - Parameter insets: The grid insets from ``contentInsets``.
    /// - Returns: Insets without negative or non-finite values.
    private func sanitized(_ insets: UIEdgeInsets) -> UIEdgeInsets {
        UIEdgeInsets(
            top: sanitized(insets.top),
            left: sanitized(insets.left),
            bottom: sanitized(insets.bottom),
            right: sanitized(insets.right)
        )
    }

    /// Sanitizes a single length: negative or non-finite becomes 0.
    ///
    /// - Parameter value: The value in points.
    /// - Returns: A non-negative finite value.
    private func sanitized(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    /// A snapshot of a visible cell for dragging.
    ///
    /// Returns `cell.snapshotView(afterScreenUpdates: false)`: a copy of the
    /// rendered cell. For an off-screen cell and for a collection not yet laid out
    /// returns `nil` — the coordinator must start a drag only on a
    /// visible tile (under the finger it is visible by definition). Take the copy
    /// **before** ``setItemHidden(_:forItemID:)``: a hidden cell yields an empty snapshot.
    ///
    /// - Parameter id: The tile or folder identifier.
    /// - Returns: The cell snapshot or `nil`.
    public func snapshotView(forItemID id: AnyHashable) -> UIView? {
        cellView(forItemID: id)?.snapshotView(afterScreenUpdates: false)
    }

    /// The visible cell of an item — for jiggle and highlighting while editing.
    ///
    /// The edit coordinator may attach animations to it (jiggle, §5:
    /// a `CAKeyframeAnimation` rotation of ±2°) or change `alpha`. Do not change `frame`
    /// or the nested layout: the position is owned by
    /// `TesseraTileCollectionViewLayout`, and a manual frame pass bypassing the layout
    /// would break the correspondence with the model. The coordinator removes animations itself when
    /// editing ends; for jiggle a `CAAnimation` on the cell/content layer
    /// is more reliable than `UIView.animate(transform:)`: UICollectionView
    /// applies layout attributes to the cell and resets `cell.transform`.
    ///
    /// - Parameter id: The tile or folder identifier.
    /// - Returns: The cell, or `nil` if the item is not on screen.
    public func cellView(forItemID id: AnyHashable) -> UIView? {
        guard let indexPath = indexPath(forItemID: id) else { return nil }
        return collectionView.cellForItem(at: indexPath)
    }

    /// A ready-made placeholder for a tile — the spot the tile was "picked up" from.
    ///
    /// Returns a new view with the tile's frame in grid coordinates, but **does not
    /// add it to the hierarchy**: the placeholder remains owned by the edit
    /// coordinator, which puts it under the drag layer and removes it
    /// on release. The view does not intercept touches and is hidden from VoiceOver.
    /// The placeholder does not follow scrolling: if the grid scrolls during a
    /// drag, the coordinator recomputes its `frame` from ``frame(forItemID:)``.
    ///
    /// - Parameter id: The tile or folder identifier.
    /// - Returns: The placeholder view or `nil` if the item is not in the snapshot.
    public func placeholderView(forItemID id: AnyHashable) -> UIView? {
        guard let frame = frame(forItemID: id) else { return nil }
        return TesseraTilePlaceholderView(frame: frame)
    }

    /// Hides the source cell while dragging.
    ///
    /// Hiding does not change the layout: the tile's place stays occupied, so the
    /// other tiles do not "jump". A hidden cell gets `alpha = 0` and is
    /// excluded from VoiceOver; after the snapshot state is shown, hiding
    /// persists until an explicit `false` or until the item disappears from the snapshot.
    ///
    /// - Parameters:
    ///   - hidden: `true` to hide, `false` to restore.
    ///   - id: The tile or folder identifier.
    public func setItemHidden(_ hidden: Bool, forItemID id: AnyHashable) {
        if hidden {
            hiddenItemIDs.insert(id)
        } else {
            hiddenItemIDs.remove(id)
        }

        guard let indexPath = indexPath(forItemID: id),
              let cell = collectionView.cellForItem(at: indexPath) as? TesseraTileCell else {
            return
        }
        cell.setSourceHidden(hidden)
        // A tile hidden during a drag must not flip "into itself": the engine
        // pause discards an unfinished flip and schedules no new ones (§4,
        // "Pauses"). Returning the cell resumes the schedule without re-registration,
        // but the shared live content pause is stronger.
        cell.setLiveTileVisible(!hidden && !isLiveContentPaused)
    }

    /// Applies the alpha values of tile content for edit mode.
    ///
    /// The grid is the sole owner of the dimming. The edit coordinator computes
    /// the target values (the selected tile / the target under the finger — 1, the others —
    /// ``dimmedTileAlpha``) and passes them here; the grid applies them to visible
    /// cells and stores them so that ``configure(_:with:isVisible:)`` does not erase the dimming
    /// on snapshot updates, resize and cell reuse.
    ///
    /// The semantics are merge: entries for the passed identifiers are updated,
    /// entries for other items are kept (the hot scroll path passes
    /// only tiles with buttons). Cells hidden during a drag stay
    /// transparent even if they were assigned a dimming.
    ///
    /// - Parameters:
    ///   - targetAlphas: Target content alpha by item
    ///     identifier (`1` is full brightness).
    ///   - animated: Animate the transition over ``dimmingDuration`` (with Reduce Motion
    ///     there is no animation, but the dimming itself is applied: it is not motion).
    func setEditDimming(_ targetAlphas: [AnyHashable: CGFloat], animated: Bool) {
        guard !targetAlphas.isEmpty else { return }

        var changes: [(cell: TesseraTileCell, alpha: CGFloat)] = []
        changes.reserveCapacity(targetAlphas.count)

        for (itemID, alpha) in targetAlphas {
            editDimmingAlphas[itemID] = alpha
            guard let indexPath = indexPath(forItemID: itemID),
                  let cell = collectionView.cellForItem(at: indexPath) as? TesseraTileCell,
                  cell.itemID == itemID else {
                continue
            }
            changes.append((cell, alpha))
        }

        guard !changes.isEmpty else { return }

        let apply = {
            for change in changes {
                change.cell.setDimmingAlpha(change.alpha)
            }
        }

        guard animated, !isReduceMotionEnabled() else {
            apply()
            return
        }

        UIView.animate(
            withDuration: TesseraTileGridView.dimmingDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
            animations: apply,
            completion: nil
        )
    }

    /// Tells cells how much of the corner the size arrow occupies (D29).
    ///
    /// A tile's badge avoids the edit mode arrow: the coordinator computes,
    /// for each tile with an arrow, the occupied part of the corner
    /// (``TesseraTileEditControlView/badgeClearance(forTileSize:maxDiameter:)``),
    /// the grid stores the values and applies them to cells, including ones created
    /// later. The semantics are merge, like ``setEditDimming(_:animated:)``; `0`
    /// returns the badge to the corner.
    ///
    /// - Parameters:
    ///   - clearances: The inset by item identifier, in pt.
    ///   - animated: A smooth shift (instant with Reduce Motion).
    func setBadgeEditClearances(_ clearances: [AnyHashable: CGFloat], animated: Bool) {
        guard !clearances.isEmpty else { return }

        let animates = animated && !isReduceMotionEnabled()
        for (itemID, clearance) in clearances {
            if clearance > 0 {
                badgeEditClearances[itemID] = clearance
            } else {
                badgeEditClearances.removeValue(forKey: itemID)
            }
            guard let indexPath = indexPath(forItemID: itemID),
                  let cell = collectionView.cellForItem(at: indexPath) as? TesseraTileCell,
                  cell.itemID == itemID else {
                continue
            }
            cell.setBadgeEditClearance(clearance, animated: animates)
        }
    }

    /// Returns all tiles' badges to the corner: editing has ended.
    ///
    /// - Parameter animated: A smooth shift (instant with Reduce Motion).
    func resetBadgeEditClearances(animated: Bool) {
        let ids = Set(badgeEditClearances.keys)
        guard !ids.isEmpty else { return }
        setBadgeEditClearances(Dictionary(uniqueKeysWithValues: ids.map { ($0, CGFloat(0)) }), animated: animated)
    }

    /// The target content alpha of an item.
    ///
    /// - Parameter itemID: The tile or folder identifier.
    /// - Returns: The stored alpha, or 1 if no dimming was
    ///   applied to the item.
    private func editDimmingAlpha(for itemID: AnyHashable) -> CGFloat {
        editDimmingAlphas[itemID] ?? 1
    }

    /// Recomputes the grid geometry without changing the snapshot (§3).
    ///
    /// Needed when the container width/height, insets, gap or column
    /// count changed: the model is the same, the frames differ. `animated` animates the move of
    /// cells through `performBatchUpdates`; with Reduce Motion the animation
    /// is disabled (§9, the internal ``isReduceMotionEnabled`` provider).
    ///
    /// - Parameter animated: Whether to animate the cell move.
    public func invalidateTileLayout(animated: Bool) {
        guard snapshot != nil else { return }

        let shouldAnimate = animated
            && window != nil
            && !isReduceMotionEnabled()

        if shouldAnimate {
            collectionView.performBatchUpdates({
                // displayItems, not snapshot.items: the open panel of an expanded
                // folder must stay in the set and move together with the grid.
                self.pushDisplayItemsToLayout(reason: .geometry)
            }, completion: { [weak self] _ in
                self?.refreshVisibleCells()
            })
        } else {
            pushDisplayItemsToLayout(reason: .geometry)
            refreshVisibleCells()
        }
    }

    /// Scrolls the grid. Used by autoscroll during a drag.
    ///
    /// - Parameters:
    ///   - offset: The target offset; UIKit does not clamp programmatic
    ///     values itself, so bounds are the caller's concern.
    ///   - animated: Whether to animate the scroll.
    public func setContentOffset(_ offset: CGPoint, animated: Bool) {
        collectionView.setContentOffset(offset, animated: animated)
    }

    // MARK: - Folder renaming (D35)

    /// The panel cell in which the name is currently being edited.
    private weak var renamingPanelCell: TesseraFolderPanelCell?

    /// A snapshot of the scroll state while the name is edited: the collection insets and
    /// the offset from before the grid made room for the keyboard.
    private struct RenameKeyboardState {
        /// The bottom collection inset before editing.
        var originalBottomInset: CGFloat
        /// The vertical offset before editing.
        var originalOffsetY: CGFloat
        /// The offset that the grid set itself (`nil` — it did not scroll).
        var appliedOffsetY: CGFloat?
    }

    /// Keyboard state while the name is edited; `nil` means outside editing.
    private var renameKeyboard: RenameKeyboardState?

    /// The last known keyboard frame in screen coordinates; `nil` means the
    /// keyboard is hidden. The observers are permanent (`commonInit`): the
    /// show notification can arrive during `becomeFirstResponder`, before
    /// editing has had time to register.
    private var lastKeyboardFrame: CGRect?

    /// Do not return VoiceOver focus to the title (editing ends by
    /// closing the panel: focus will go to the folder tile).
    private var suppressesRenameFocusReturn = false

    /// Whether a folder name is being edited in the open panel.
    var isEditingFolderName: Bool {
        renamingPanelCell?.isEditingTitle == true
    }

    /// The visible panel cell of the expanded folder.
    private var visiblePanelCell: TesseraFolderPanelCell? {
        collectionView.visibleCells.compactMap { $0 as? TesseraFolderPanelCell }.first
    }

    // MARK: - Reordering inside the panel (D40)

    /// Starts reordering a tile in the open panel: the tile is hidden and a placeholder
    /// appears in its slot (``TesseraFolderPanelCell/beginReorder(sourceIndex:)``).
    ///
    /// - Parameter sourceIndex: The index of the lifted tile in folder order.
    /// - Returns: `false` if there is no panel or the index is invalid.
    @discardableResult
    func beginPanelReorder(sourceIndex: Int) -> Bool {
        visiblePanelCell?.beginReorder(sourceIndex: sourceIndex) ?? false
    }

    /// Shifts the panel tiles to open the slot `slot`.
    ///
    /// - Parameters:
    ///   - slot: The index of the target slot.
    ///   - animated: Whether to animate the shift (bounce curve).
    func setPanelReorderSlot(_ slot: Int, animated: Bool) {
        visiblePanelCell?.setReorderSlot(slot, animated: animated)
    }

    /// The slot where the reorder placeholder currently sits; `nil` means no reorder is in progress.
    var panelReorderSlot: Int? {
        visiblePanelCell?.reorderSlot
    }

    /// Ends the reorder preview without animation: tiles are in the layout
    /// slots, the hidden one is shown, and there is no placeholder.
    func endPanelReorder() {
        for cell in collectionView.visibleCells.compactMap({ $0 as? TesseraFolderPanelCell }) {
            cell.endReorder()
        }
    }

    /// Hides or shows a panel tile by index: while the drag image flies
    /// into the new slot, the tile under it is not duplicated.
    ///
    /// - Parameters:
    ///   - hidden: `true` to hide.
    ///   - index: The tile index in folder order.
    func setPanelShortcutHidden(_ hidden: Bool, at index: Int) {
        guard let panel = visiblePanelCell, panel.shortcutCells.indices.contains(index) else { return }
        panel.shortcutCells[index].setSourceHidden(hidden)
    }

    /// Whether a point falls on the name of the expanded panel's folder.
    ///
    /// A long press on the name starts renaming: neither the grid gesture nor the
    /// coordinator gesture (entering editing, drag) accepts touches on it. The area is
    /// the whole title row (the full panel width, height `panelHeaderHeight`);
    /// outside the panel and without a rename handler the answer is always `false`.
    ///
    /// - Parameter point: A point in grid coordinates.
    func isFolderNameHit(at point: CGPoint) -> Bool {
        guard folderRenameHandler != nil, expandedFolderID != nil,
              let panel = visiblePanelCell else {
            return false
        }
        return panel.isTitleHit(convert(point, to: panel.contentView))
    }

    /// Starts renaming a folder (the VoiceOver "Rename" action on the
    /// folder tile comes here; on the panel title it goes directly to the cell).
    ///
    /// A closed folder is expanded first (without animation under Reduce Motion), and
    /// editing starts once the panel has settled.
    ///
    /// - Parameter folderID: The folder identifier from the snapshot.
    /// - Returns: `true` if editing started or is scheduled; `false` if there is
    ///   no handler or the folder is not in the snapshot.
    @discardableResult
    func beginRenamingFolder(_ folderID: AnyHashable) -> Bool {
        guard folderRenameHandler != nil,
              let folder = currentFolder(withID: folderID) else {
            return false
        }
        if expandedFolderID == folderID, folderTransition == .idle {
            return visiblePanelCell?.beginTitleEditing() ?? false
        }
        openFolder(folder, animated: true)
        performAfterFolderTransition { [weak self] in
            guard let self, self.expandedFolderID == folderID else { return }
            _ = self.visiblePanelCell?.beginTitleEditing()
        }
        return true
    }

    /// Commits the name edit if one is in progress (D35: closing the panel, entering and leaving
    /// edit mode, changing the handler).
    ///
    /// - Parameter restoresFocus: Whether to return VoiceOver focus to the title (when
    ///   closing the panel — no).
    func commitFolderNameEditing(restoresFocus: Bool = true) {
        guard let cell = renamingPanelCell, cell.isEditingTitle else { return }
        let saved = suppressesRenameFocusReturn
        suppressesRenameFocusReturn = !restoresFocus
        cell.endTitleEditing()
        suppressesRenameFocusReturn = saved
    }

    /// The panel reported the start or end of name editing.
    private func folderNameEditingDidChange(_ isEditing: Bool, in cell: TesseraFolderPanelCell) {
        if isEditing {
            renamingPanelCell = cell
            beginRenameKeyboardHandling()
            // VoiceOver: focus on the field, not on the hidden title.
            accessibilityNotificationPoster(.layoutChanged, cell.titleTextField)
        } else {
            if renamingPanelCell === cell { renamingPanelCell = nil }
            endRenameKeyboardHandling(restoresOffset: !suppressesRenameFocusReturn)
            // Focus returns to the title while the panel is in place.
            if !suppressesRenameFocusReturn, cell.superview != nil, expandedFolderID != nil {
                accessibilityNotificationPoster(.layoutChanged, cell.titleHeaderLabel)
            }
        }
    }

    /// Remembers the insets and offset and adjusts scrolling for the keyboard.
    private func beginRenameKeyboardHandling() {
        renameKeyboard = RenameKeyboardState(
            originalBottomInset: collectionView.contentInset.bottom,
            originalOffsetY: collectionView.contentOffset.y,
            appliedOffsetY: nil
        )
        if let frame = lastKeyboardFrame {
            applyKeyboardFrame(frame)
        } else {
            revealRenameField()
        }
    }

    /// Restores the collection insets and (if the user did not scroll
    /// themselves) the previous offset.
    private func endRenameKeyboardHandling(restoresOffset: Bool) {
        guard let state = renameKeyboard else { return }
        renameKeyboard = nil
        collectionView.contentInset.bottom = state.originalBottomInset
        guard restoresOffset, let applied = state.appliedOffsetY,
              abs(collectionView.contentOffset.y - applied) < 1 else {
            return
        }
        let maximumY = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        let target = min(max(state.originalOffsetY, 0), maximumY)
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: target),
            animated: window != nil && !isReduceMotionEnabled()
        )
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        lastKeyboardFrame = frame
        if renameKeyboard != nil {
            applyKeyboardFrame(frame)
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        lastKeyboardFrame = nil
        if renameKeyboard != nil {
            applyKeyboardOverlap(0)
        }
    }

    /// Applies the keyboard frame (screen coordinates): the overlap of the grid bottom
    /// becomes the collection's bottom inset, and the name field is scrolled into the
    /// visible part.
    ///
    /// - Parameter screenFrame: The final keyboard frame in screen coordinates.
    func applyKeyboardFrame(_ screenFrame: CGRect) {
        guard let screen = window?.screen else {
            applyKeyboardOverlap(0)
            return
        }
        let frame = convert(screenFrame, from: screen.coordinateSpace)
        applyKeyboardOverlap(max(0, min(bounds.height, bounds.maxY - frame.minY)))
    }

    /// The collection's bottom inset = the original one + the keyboard overlap.
    private func applyKeyboardOverlap(_ overlap: CGFloat) {
        guard let state = renameKeyboard else { return }
        collectionView.contentInset.bottom = state.originalBottomInset + overlap
        revealRenameField()
    }

    /// Scrolls the collection so the name field (with an 8 pt margin) is in the
    /// visible part above the keyboard; the title stays visible, and when there
    /// is not enough room the top of the field matters more than the bottom.
    private func revealRenameField() {
        guard var state = renameKeyboard, let cell = renamingPanelCell else { return }
        let field = cell.titleTextField
        let rect = field.convert(field.bounds, to: collectionView).insetBy(dx: 0, dy: -8)
        let offset = collectionView.contentOffset
        let bottomInset = collectionView.contentInset.bottom
        let visibleHeight = collectionView.bounds.height - bottomInset

        var y = offset.y
        if rect.maxY > y + visibleHeight { y = rect.maxY - visibleHeight }
        if rect.minY < y { y = rect.minY }
        let maximumY = max(0, collectionView.contentSize.height + bottomInset - collectionView.bounds.height)
        y = min(max(y, 0), maximumY)
        guard abs(y - offset.y) > 0.5 else { return }

        state.appliedOffsetY = y
        renameKeyboard = state
        collectionView.setContentOffset(
            CGPoint(x: offset.x, y: y),
            animated: window != nil && !isReduceMotionEnabled()
        )
    }

    // MARK: - Internal helpers

    /// Snapshot items in grid order (without the expanded folder's panel).
    private var baseItems: [TesseraTileGridItem] {
        snapshot?.items ?? []
    }

    /// Items in collection order: the snapshot with the panel added when a folder
    /// is expanded (D17).
    ///
    /// When expanded, the item count is `baseItems.count + 1`: the panel is a
    /// separate item right after the folder tile, and the tile itself stays in the
    /// set. The cache is reset only when the snapshot, expansion or column count
    /// changes — the insertion index is not recomputed on every collection query.
    /// Access is internal (not public): this is a grid representation, not data;
    /// ``items`` and ``expandedFolderID`` are exposed publicly. Tests need
    /// the collection's item set itself — it is used to check the panel insertion below the folder and
    /// its removal.
    var displayItems: [TesseraTileGridItem] {
        if let cachedDisplayItems {
            return cachedDisplayItems
        }
        let items = makeDisplayItems()
        cachedDisplayItems = items
        return items
    }

    /// Resets the item cache with the panel.
    private func invalidateDisplayItems() {
        cachedDisplayItems = nil
    }

    /// A snapshot with items in the reading order of explicit cells.
    ///
    /// The order of snapshot items is the order of collection indexes, which is the VoiceOver
    /// traversal order (see "Accessibility"): the grid does not set
    /// `accessibilityElements`, does not sort frames and does not override the cell
    /// order, and the layout's `layoutAttributesForElements(in:)` returns attributes
    /// by index. So the grid brings the set to the reading order itself
    /// (row, then logical column; the same order in RTL) if the snapshot
    /// carries a cell table applicable to the current columns. Without a table or with an
    /// inapplicable one the order stays as the host delivered it: packing works the same way,
    /// ``TesseraTileLayoutEngine/pack(items:columns:unit:)``. Internal: the coordinator
    /// uses it to compare expected snapshots with what the grid shows.
    ///
    /// - Parameter snapshot: The host snapshot.
    /// - Returns: The snapshot in reading order.
    func readingOrdered(_ snapshot: TesseraTileGridSnapshot) -> TesseraTileGridSnapshot {
        snapshot.readingOrdered(columns: columns)
    }

    /// Reorders the current snapshot for the current columns.
    ///
    /// Needed when the column count changed: the cell table may have become
    /// applicable (or stopped being so), and the reading order changes with it.
    ///
    /// - Returns: `true` if the order of snapshot items changed.
    private func reorderSnapshotForCurrentColumns() -> Bool {
        guard let current = snapshot else { return false }
        let ordered = readingOrdered(current)
        guard ordered.items.map({ $0.id }) != current.items.map({ $0.id }) else { return false }
        snapshot = ordered
        invalidateDisplayItems()
        return true
    }

    /// Passes the layout the collection's item set together with the snapshot's table of explicit cells.
    ///
    /// The only point through which the set reaches the layout: this way the
    /// cell table (``TesseraTileGridSnapshot/placementTable``) is not lost in any
    /// of the paths — `reloadData`, diff, reorder move, column change,
    /// folder expansion. The layout itself decides whether the table applies to the current
    /// columns.
    ///
    /// - Parameter reason: The reason for recomputation.
    private func pushDisplayItemsToLayout(reason: TesseraTileLayoutInvalidationReason) {
        tileLayout.setItems(displayItems, placements: snapshot?.placementTable, reason: reason)
    }

    /// Placements of items by the snapshot's explicit cells, or `nil` if the table
    /// does not apply.
    ///
    /// The fallback rule (no table, incomplete, a different width, fails
    /// ``TesseraTileLayoutEngine/validate(_:columns:)``) is one for the layout and for
    /// the grid's helper computations: ``TesseraTileGridPlacementTable/resolve(items:cells:placementColumns:columns:)``.
    ///
    /// - Parameters:
    ///   - items: Items in snapshot order; the expanded folder's panel is ignored.
    ///   - table: The table of explicit cells.
    /// - Returns: Placements in `items` order, or `nil` — packing in order.
    private func explicitPlacements(
        for items: [TesseraTileGridItem],
        table: TesseraTileGridPlacementTable?
    ) -> [TesseraTilePlacedItem]? {
        TesseraTileGridPlacementTable.resolve(
            items: items.compactMap { item in
                item.isFolderPanel ? nil : (id: item.id, size: item.size)
            },
            cells: table?.cells,
            placementColumns: table?.columns,
            columns: columns
        )
    }

    /// The insertion index of the expanded folder's panel into the set without the panel (D17).
    ///
    /// With an applicable table of explicit cells the index is computed from cells, without
    /// packing, so that the set order matches what the layout draws;
    /// otherwise — the previous computation by packing in order.
    ///
    /// - Parameter folderID: The identifier of the folder being expanded.
    /// - Returns: The insertion index, or `nil` if there is no such folder or the panel is already in
    ///   the set.
    private func panelInsertionIndex(forFolder folderID: AnyHashable) -> Int? {
        let items = baseItems
        if let placements = explicitPlacements(for: items, table: snapshot?.placementTable),
           !items.contains(where: { $0.isFolderPanel }),
           let index = TesseraTileLayoutEngine.folderPanelInsertionIndex(
               placements: placements,
               columns: columns,
               expandedFolderID: folderID
           ) {
            return index
        }
        return TesseraTileLayoutEngine.folderPanelInsertionIndex(
            items: items,
            columns: columns,
            expandedFolderID: folderID
        )
    }

    /// Builds the collection items: inserts the expanded folder's panel after its
    /// tile, without removing the tile itself.
    private func makeDisplayItems() -> [TesseraTileGridItem] {
        guard let snapshot else { return [] }
        guard let expandedID = expandedFolderID,
              let folder = snapshot.items.compactMap({ $0.folder }).first(where: { $0.id == expandedID }),
              let insertionIndex = panelInsertionIndex(forFolder: expandedID) else {
            return snapshot.items
        }

        // D17: the panel is a separate full-width row right after the
        // folder's row. The folder tile stays at its index; rows below the panel
        // are shifted by the layout.
        var items = snapshot.items
        items.insert(.folderContent(folder), at: insertionIndex)
        return items
    }

    /// A snapshot item by index (without the panel).
    private func baseItem(atIndex index: Int) -> TesseraTileGridItem? {
        guard let snapshot, snapshot.items.indices.contains(index) else { return nil }
        return snapshot.items[index]
    }

    /// A collection item by index (with the expanded folder's panel).
    private func displayItem(atIndex index: Int) -> TesseraTileGridItem? {
        let items = displayItems
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    /// The index of an item in the collection; the panel is skipped: it shares an
    /// identifier with the folder but is not an addressable model item.
    private func displayIndex(ofItemID id: AnyHashable) -> Int? {
        displayItems.firstIndex { !$0.isFolderPanel && $0.id == id }
    }

    /// The `IndexPath` of an item in the current collection.
    private func indexPath(forItemID id: AnyHashable) -> IndexPath? {
        guard let index = displayIndex(ofItemID: id) else { return nil }
        return IndexPath(item: index, section: 0)
    }

    /// A folder from the current snapshot by identifier.
    private func currentFolder(withID id: AnyHashable) -> TesseraTileFolder? {
        snapshot?.items.compactMap { $0.folder }.first { $0.id == id }
    }

    /// Whether the panel expand/close animation is allowed.
    ///
    /// Off-window and with Reduce Motion (§9) the panel changes state instantly:
    /// tests and the first layout do not wait for an animation cycle. Reduce Motion
    /// is queried through ``isReduceMotionEnabled`` (the internal provider).
    private var canAnimateFolderChange: Bool {
        window != nil && !isReduceMotionEnabled()
    }

    /// Recomputes the actual scroll state from the request and the lock
    /// reasons.
    ///
    /// The sole owner of `collectionView.isScrollEnabled`: it removes the
    /// panel lock and restores the requested value only
    /// when no reasons remain.
    private func updateScrollEnabled() {
        collectionView.isScrollEnabled = isScrollEnabledRequested && !isFolderPanelScrollLocked
    }

    /// Starts an animated panel transition: blocks scrolling.
    ///
    /// - Parameter state: `.opening` or `.closing`.
    private func beginAnimatedFolderTransition(_ state: FolderTransitionState) {
        folderTransition = state
        isFolderChangeAnimating = true
        isFolderPanelScrollLocked = true
        updateScrollEnabled()
        folderPanelStateDidChange?()
    }

    /// Ends the transition state without processing deferred commands.
    ///
    /// Called at the end of an animation: after this the deferred
    /// snapshot and the next panel target can be applied.
    private func completeFolderTransitionState() {
        folderTransition = .idle
        isFolderChangeAnimating = false
        isFolderPanelScrollLocked = false
        updateScrollEnabled()
        folderPanelStateDidChange?()
    }

    /// Schedules processing of a deferred panel command for the next runloop pass.
    ///
    /// Needed for switching from folder A to B: A collapses with an instant `reloadData`, and
    /// the batch insertion of B must not land in the same runloop pass.
    private func scheduleDeferredFolderWork() {
        guard !hasScheduledFolderWork else { return }
        hasScheduledFolderWork = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasScheduledFolderWork = false
            guard self.folderTransition == .idle else { return }
            self.runDeferredFolderWork()
        }
    }

    /// Applies the deferred snapshot and panel target.
    ///
    /// Order: first the snapshot (it may have removed the target folder), then the
    /// expand/close command. Both operations run only in the `idle` state.
    ///
    /// If a deferred snapshot was applied, the panel target is not executed in
    /// the same stack. The snapshot may have fallen back to `reloadData` (the diff fallback), and
    /// a synchronous batch insertion of the panel right after it would repeat the class of defect
    /// "reloadData + batch in one runloop pass". The target is deferred again to the
    /// next pass; `last-wins` is preserved because the target stays in
    /// `pendingFolderChange` until executed (there is no busy loop: the next pass
    /// will see that the snapshot is already applied).
    private func runDeferredFolderWork() {
        defer { flushFolderSettleActions() }
        guard folderTransition == .idle else { return }

        if let deferredSnapshot = pendingSnapshot {
            pendingSnapshot = nil
            // The application animation is recomputed at the time of application rather than
            // taken as "remembered": the window/Reduce Motion may have changed while the
            // snapshot waited for the transition to finish.
            let animated = pendingSnapshotAnimated
                && window != nil
                && !isReduceMotionEnabled()
            pendingSnapshotAnimated = false
            apply(deferredSnapshot, animated: animated)

            if pendingFolderChange != nil {
                scheduleDeferredFolderWork()
                return
            }
        }

        guard folderTransition == .idle, let change = pendingFolderChange else { return }
        pendingFolderChange = nil
        switch change {
        case .open(let folder, let animated):
            openFolder(folder, animated: animated)
        case .close(let animated):
            closeFolder(animated: animated)
        }
    }

    /// Runs an action when the folder panel transition has finished and no deferred
    /// snapshot or command is left (D45).
    ///
    /// If the grid is idle, the action goes to the **next runloop pass**
    /// (by then the collection has laid out the new frames); otherwise
    /// it waits for the end of the transition and for the deferred snapshot to be applied, and also
    /// runs on the next pass.
    ///
    /// - Parameter action: An action on the main thread.
    func performAfterFolderTransition(_ action: @escaping () -> Void) {
        folderSettleActions.append(action)
        if isFolderSettled {
            flushFolderSettleActions()
        } else if folderTransition == .idle {
            scheduleDeferredFolderWork()
        }
    }

    /// Whether the panel is idle: no transition and no deferred commands (D45).
    private var isFolderSettled: Bool {
        folderTransition == .idle && pendingSnapshot == nil && pendingFolderChange == nil
    }

    /// Runs pending actions if the panel is idle (D45).
    private func flushFolderSettleActions() {
        guard isFolderSettled, !folderSettleActions.isEmpty else { return }
        let actions = folderSettleActions
        folderSettleActions = []
        DispatchQueue.main.async { [weak self] in
            // The cells of the applied snapshot are created by the collection's layout pass: bring
            // it up to date before the actions so that VoiceOver focus points to an existing cell.
            self?.collectionView.layoutIfNeeded()
            for action in actions { action() }
        }
    }

    /// Expands a folder with the panel from the `idle` state.
    ///
    /// - Parameters:
    ///   - folder: A folder from the grid's current snapshot.
    ///   - animated: Whether to animate the panel appearing.
    private func performOpen(_ folder: TesseraTileFolder, animated: Bool) {
        guard folderTransition == .idle else { return }
        guard expandedFolderID != folder.id else { return }
        guard let currentFolder = currentFolder(withID: folder.id) else { return }

        // D17: the panel is inserted as a separate item right after the folder tile;
        // the tile itself stays in the set.
        guard let insertionIndex = panelInsertionIndex(forFolder: currentFolder.id) else {
            return
        }

        expandedFolderID = currentFolder.id
        invalidateDisplayItems()
        guard displayItems.count == baseItems.count + 1,
              displayItems.indices.contains(insertionIndex),
              displayItems[insertionIndex].isFolderPanel else {
            expandedFolderID = nil
            invalidateDisplayItems()
            return
        }

        setFolderCellExpanded(true, forItemID: currentFolder.id)

        guard animated, canAnimateFolderChange else {
            // The non-animated branch (Reduce Motion, off-window): the panel
            // appears immediately; `.layoutChanged` and the host event are as in the
            // animated branch.
            pushDisplayItemsToLayout(reason: .items)
            collectionView.reloadData()
            // The panel cell is created in the layout pass — bring it up to date, otherwise
            // `.layoutChanged` goes out with focus on the folder, not on the panel.
            collectionView.layoutIfNeeded()
            postFolderLayoutChanged(expanded: true, folderID: currentFolder.id)
            folderPanelStateDidChange?()
            onFolderExpansionChanged?(currentFolder, true)
            runDeferredFolderWork()
            return
        }

        // D17: the grid does not scroll during the animation — otherwise the items under
        // the panel would "fight" the finger for the same motion. The lock
        // is a reason, not a snapshot of the value.
        beginAnimatedFolderTransition(.opening)

        let panel = IndexPath(item: insertionIndex, section: 0)
        animateFolderChange { [weak self] in
            guard let self else { return }
            self.pushDisplayItemsToLayout(reason: .items)
            self.collectionView.performBatchUpdates({
                // The folder tile does not go anywhere: only the panel is inserted,
                // growing from zero height from its row (attributes are
                // in the layout), and rows below it shift down.
                self.collectionView.insertItems(at: [panel])
            }, completion: nil)
        } completion: { [weak self] in
            guard let self else { return }
            self.completeFolderTransitionState()

            if let panelCell = self.collectionView.cellForItem(at: panel) as? TesseraFolderPanelCell {
                // The cascade is triggered by the opening, not by the cell being shown: scrolling
                // and reuse must not repeat the animation.
                panelCell.playIconCascade()
            }
            self.postFolderLayoutChanged(expanded: true, folderID: currentFolder.id)
            self.onFolderExpansionChanged?(currentFolder, true)
            self.runDeferredFolderWork()
        }
    }

    /// Collapses the folder expansion; the common implementation of ``closeFolder(animated:)``.
    ///
    /// The panel collapses and is removed from the set; the folder tile stays
    /// in place the whole time. The batch update removes only the panel, so the
    /// rows below it rise as its height shrinks.
    ///
    /// If a panel transition is already running, closing is deferred (the last
    /// target wins); the non-animated branches also clamp `contentOffset` and
    /// post `.layoutChanged`.
    ///
    /// - Parameters:
    ///   - animated: Whether to animate the collapse.
    ///   - notify: Whether to report the close to the host (when switching to another folder
    ///     the event is needed too: one folder closed, another opened).
    private func collapseExpansion(animated: Bool, notify: Bool) {
        guard let expandedID = expandedFolderID else { return }

        // Closing the panel in the middle of a name edit commits the name (D35); VoiceOver
        // focus after closing goes to the folder tile, not to the title.
        commitFolderNameEditing(restoresFocus: false)

        if folderTransition != .idle {
            pendingFolderChange = .close(animated: animated)
            return
        }

        let folder = currentFolder(withID: expandedID)
            ?? displayItems.first(where: { $0.isFolderPanel })?.panelFolder

        guard let panelIndex = displayItems.firstIndex(where: {
            $0.isFolderPanel && $0.id == expandedID
        }) else {
            // The panel is no longer in the set (for example, the folder disappeared from the snapshot):
            // only the state needs synchronizing.
            performImmediateCollapse(
                expandedID: expandedID,
                folder: folder,
                notify: notify
            )
            return
        }

        guard animated, canAnimateFolderChange else {
            performImmediateCollapse(
                expandedID: expandedID,
                folder: folder,
                notify: notify
            )
            return
        }

        beginAnimatedFolderTransition(.closing)

        // The model state is cleared only before the batch update: while the
        // icons fade out, the dataSource must keep returning the previous item count,
        // otherwise UICollectionView would see a mismatch before `deleteItems`.
        let collapse = { [weak self] in
            guard let self else { return }
            self.expandedFolderID = nil
            self.invalidateDisplayItems()
            self.setFolderCellExpanded(false, forItemID: expandedID)

            let replacement = IndexPath(item: panelIndex, section: 0)
            self.animateFolderChange {
                self.pushDisplayItemsToLayout(reason: .items)
                self.collectionView.performBatchUpdates({
                    // D17: only the panel leaves — the folder tile was not removed
                    // from the set and stays in place.
                    self.collectionView.deleteItems(at: [replacement])
                }, completion: nil)
            } completion: { [weak self] in
                guard let self else { return }
                self.completeFolderTransitionState()
                self.clampContentOffsetAfterCollapse()
                self.postFolderLayoutChanged(expanded: false, folderID: expandedID)
                if let folder, notify {
                    self.onFolderExpansionChanged?(folder, false)
                }
                self.runDeferredFolderWork()
            }
        }

        // D17: first the icons fade out, then the panel height collapses and the
        // items under it rise. If the panel is already off-screen, only the height changes.
        if let panelCell = collectionView.cellForItem(
            at: IndexPath(item: panelIndex, section: 0)
        ) as? TesseraFolderPanelCell {
            panelCell.animateIconsOut(completion: collapse)
        } else {
            collapse()
        }
    }

    /// Instantly clears the panel expansion.
    ///
    /// A common branch for Reduce Motion, no window, and the case when the panel is
    /// already absent from the set: state, layout and `reloadData` in one pass,
    /// then `clamp`, `.layoutChanged` and the host event.
    ///
    /// - Parameters:
    ///   - expandedID: The identifier of the expanded folder.
    ///   - folder: The folder for the host event; `nil` means the folder is already not in the snapshot.
    ///   - notify: Whether to report the close to the host.
    private func performImmediateCollapse(
        expandedID: AnyHashable,
        folder: TesseraTileFolder?,
        notify: Bool
    ) {
        expandedFolderID = nil
        invalidateDisplayItems()
        setFolderCellExpanded(false, forItemID: expandedID)
        pushDisplayItemsToLayout(reason: .items)
        collectionView.reloadData()
        // Bring the layout up to date before posting `.layoutChanged` — focus must
        // go to a really existing folder cell.
        collectionView.layoutIfNeeded()
        clampContentOffsetAfterCollapse()
        postFolderLayoutChanged(expanded: false, folderID: expandedID)
        folderPanelStateDidChange?()
        if let folder, notify {
            onFolderExpansionChanged?(folder, false)
        }
        runDeferredFolderWork()
    }

    /// Posts `.layoutChanged` for VoiceOver (§9).
    ///
    /// Works in all expand/close branches: on expansion focus goes
    /// to the panel (if it is on screen), otherwise to the folder tile.
    ///
    /// - Parameters:
    ///   - expanded: Whether the folder is expanded now.
    ///   - folderID: The folder identifier.
    private func postFolderLayoutChanged(expanded: Bool, folderID: AnyHashable) {
        let argument: Any?
        if expanded,
           let panelIndex = displayItems.firstIndex(where: {
               $0.isFolderPanel && $0.id == folderID
           }),
           let panelCell = collectionView.cellForItem(
               at: IndexPath(item: panelIndex, section: 0)
           ) {
            argument = panelCell
        } else if let folderCell = cellView(forItemID: folderID) {
            argument = folderCell
        } else {
            argument = nil
        }

        accessibilityNotificationPoster(.layoutChanged, argument)
    }

    /// Whether the coordinator's edit mode is active.
    ///
    /// The grid holds no reference to `TesseraTileEditCoordinator` and has no public
    /// mode flag. The only signal the coordinator leaves on the grid is
    /// its own background tap gesture: it is enabled only
    /// in edit mode (`beginEditing`/`endEditing`), and the coordinator itself
    /// is its delegate. The grid puts its own gestures on the collection, so
    /// they are absent from `gestureRecognizers`, and the host's foreign tap gestures are not confused with the
    /// coordinator: both the type and the delegate are checked.
    private var isEditModeActive: Bool {
        gestureRecognizers?.contains { recognizer in
            recognizer.isEnabled
                && recognizer is UITapGestureRecognizer
                && recognizer.delegate is TesseraTileEditCoordinator
        } ?? false
    }

    /// Routing of a tap on an item (a finger or VoiceOver activation).
    ///
    /// A folder can be intercepted via ``folderTapHandler``; without interception it
    /// expands with the native panel (D17), and the ``onTap`` event still
    /// goes to the subscriber. The rule is the same in normal mode and in
    /// edit mode — in edit mode the panel opens too (a tile is picked
    /// from it with a finger and dragged out of the folder), and edit mode is not
    /// interrupted. A tile (`.tile`) in both modes produces only the ``onTap`` event.
    private func handleItemTap(_ item: TesseraTileGridItem) {
        switch item {
        case .tile:
            onTap?(item)

        case .folder(let folder):
            // When the interceptor returns true it fully owns the folder tap:
            // neither expansion nor the onTap event is performed.
            if folderTapHandler?(folder) == true {
                return
            }
            onTap?(item)
            toggleFolder(folder)

        case .folderContent:
            // The panel is a presentation, not a model item: selection on it
            // is disabled (`shouldSelectItemAt`), and a tap on the background/title
            // closes the folder via the gesture of the panel cell itself (D17).
            break
        }
    }

    /// Forwards a tile tap from another view into the common route.
    ///
    /// The built-in folder screen (`TesseraFolderViewController`) no longer
    /// calls `TesseraTileDescriptor.action` directly — the tap arrives here and
    /// goes to ``onTap`` exactly like a tap on a grid tile. The host
    /// handles the event once and through a single route.
    ///
    /// - Parameter descriptor: The tile that was tapped outside the grid.
    func forwardTileTap(_ descriptor: TesseraTileDescriptor) {
        handleItemTap(.tile(descriptor))
    }

    /// The tile of the expanded folder's panel under a point.
    ///
    /// Needed by the edit coordinator: a long press on a panel icon
    /// lifts the tile for moving. The snapshot is taken (as for grid cells — with
    /// a forced screen update) while the panel is still in place: after it
    /// closes the cell will disappear.
    ///
    /// - Parameter point: A point in grid coordinates.
    /// - Returns: The tile descriptor, or `nil` if the point is not over a panel icon
    ///   (the panel is closed, its transition is running, or the hit is on the title/background).
    func panelTile(at point: CGPoint) -> TesseraPanelTileHit? {
        guard expandedFolderID != nil, !isFolderChangeAnimating,
              let folder = expandedFolder,
              let panel = collectionView.visibleCells
                  .compactMap({ $0 as? TesseraFolderPanelCell }).first else {
            return nil
        }

        let pointInPanel = convert(point, to: panel.contentView)
        guard let hit = panel.shortcut(at: pointInPanel),
              let container = hit.cell.superview else {
            return nil
        }

        // The frame is based on the center and bounds, without the appearance cascade `transform`.
        let size = hit.cell.bounds.size
        let center = container.convert(hit.cell.center, to: self)
        let frame = CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        guard let snapshot = hit.cell.snapshotView(afterScreenUpdates: true)
            ?? hit.cell.resizableSnapshotView(
                from: hit.cell.bounds,
                afterScreenUpdates: true,
                withCapInsets: .zero
            ) else {
            return nil
        }
        return TesseraPanelTileHit(
            folder: folder,
            tile: hit.tile,
            frame: frame,
            snapshot: snapshot
        )
    }

    /// The expanded folder from the current snapshot.
    private var expandedFolder: TesseraTileFolder? {
        guard let expandedFolderID else { return nil }
        return snapshot?.items.compactMap { $0.folder }.first { $0.id == expandedFolderID }
    }

    /// A tap on empty grid space closes the expanded folder (D17).
    @objc private func handleBackgroundTap(_ recognizer: UITapGestureRecognizer) {
        // A tap outside the name field commits the name and does nothing else —
        // the folder stays open (a tap inside the panel is handled by the panel).
        if isEditingFolderName {
            let point = recognizer.location(in: collectionView)
            if let indexPath = collectionView.indexPathForItem(at: point),
               displayItem(atIndex: indexPath.item)?.isFolderPanel == true {
                return
            }
            commitFolderNameEditing()
            return
        }
        guard expandedFolderID != nil else { return }

        // Hit test on the collection: a tap on a cell (including the panel and its icons)
        // does not count as a close — the panel has its own handling, and so do the tiles.
        let point = recognizer.location(in: collectionView)
        guard collectionView.indexPathForItem(at: point) == nil else { return }

        closeFolder(animated: true)
    }

    /// Runs the expand/close animation with the D17 curve.
    ///
    /// `UIViewPropertyAnimator` with `UICubicTimingParameters` gives exactly
    /// `cubic-bezier(0.1, 0.9, 0.2, 1)`; `performBatchUpdates` inside its
    /// animation block inherits the duration and curve, so the appearance
    /// (collapse) of the panel and the shift of the items under it share one motion.
    ///
    /// - Parameters:
    ///   - changes: Collection model changes (batch updates and layout).
    ///   - completion: Animation completion (already on the main thread).
    private func animateFolderChange(
        changes: @escaping () -> Void,
        completion: @escaping () -> Void
    ) {
        let timing = UICubicTimingParameters(
            controlPoint1: CGPoint(x: 0.1, y: 0.9),
            controlPoint2: CGPoint(x: 0.2, y: 1)
        )
        let animator = UIViewPropertyAnimator(
            duration: TesseraTileGridView.folderExpansionDuration,
            timingParameters: timing
        )
        animator.addAnimations(changes)
        animator.addCompletion { [weak self] _ in
            self?.folderAnimator = nil
            completion()
        }
        folderAnimator = animator
        animator.startAnimation()
    }

    /// Clamps `contentOffset` after closing: the content became shorter, and the scroll
    /// position could end up beyond its bounds.
    private func clampContentOffsetAfterCollapse() {
        let maximumY = max(0, contentSize.height - collectionView.bounds.height)
        let offset = collectionView.contentOffset
        guard offset.y > maximumY else { return }
        collectionView.setContentOffset(
            CGPoint(x: offset.x, y: maximumY),
            animated: false
        )
    }

    /// Tells the visible folder cell about expansion/closing (D17).
    ///
    /// - Parameters:
    ///   - expanded: Whether the folder is expanded.
    ///   - id: The folder identifier.
    private func setFolderCellExpanded(_ expanded: Bool, forItemID id: AnyHashable) {
        guard let cell = cellView(forItemID: id) as? TesseraTileCell else { return }
        cell.setFolderExpanded(expanded)
    }

    /// Long press: reports the item and the start point; the host drives it from there.
    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, onLongPress != nil else { return }

        let point = recognizer.location(in: self)
        guard let item = item(at: point), !hiddenItemIDs.contains(item.id) else { return }
        onLongPress?(item, point)
    }

    /// Dynamic Type: rebuild the fonts of visible cells and of the folder panel.
    @objc private func contentSizeCategoryDidChange() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            if let tileCell = collectionView.cellForItem(at: indexPath) as? TesseraTileCell {
                tileCell.refreshTypography()
            } else if let panelCell = collectionView.cellForItem(at: indexPath) as? TesseraFolderPanelCell {
                panelCell.refreshTypography()
            }
        }
    }

    /// VoiceOver "two-finger scrub"/Back closes the expanded folder (D17).
    public override func accessibilityPerformEscape() -> Bool {
        guard expandedFolderID != nil else {
            return super.accessibilityPerformEscape()
        }
        closeFolder(animated: true)
        return true
    }

    /// RTL: the reading direction changed — recompute the layout and
    /// the mirroring of cell content.
    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard previousTraitCollection?.layoutDirection != traitCollection.layoutDirection else {
            return
        }

        // The layout itself notices the direction change in `shouldInvalidateLayout`,
        // but UICollectionView is not obliged to query it on trait changes,
        // so invalidate explicitly. The recomputation also reconfigures the cells
        // (the icon and badge are mirrored by reading direction).
        invalidateTileLayout(animated: false)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension TesseraTileGridView: UIGestureRecognizerDelegate {

    /// Allows the edit coordinator to run its own drag gesture
    /// simultaneously with the grid's long press.
    ///
    /// Simultaneity is allowed only for gestures on the grid itself or its collection
    /// (that is where the coordinator adds the drag pan). With grid scrolling
    /// simultaneity is forbidden: otherwise the long press would fire during
    /// ordinary scrolling; with a panorama pager parent it is too, otherwise the
    /// axis arbitration in Core would get two active gestures.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard otherGestureRecognizer !== collectionView.panGestureRecognizer else { return false }
        return otherGestureRecognizer.view === self || otherGestureRecognizer.view === collectionView
    }

    /// A long press on a folder name belongs to the panel title, not to the
    /// grid; a tap on the field itself during editing does not count as a "background" tap.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        if gestureRecognizer === longPressRecognizer {
            return !isFolderNameHit(at: touch.location(in: self))
        }
        if gestureRecognizer === backgroundTapRecognizer, isEditingFolderName {
            return !isFolderNameHit(at: touch.location(in: self))
        }
        return true
    }
}

// MARK: - UICollectionViewDataSource

extension TesseraTileGridView: UICollectionViewDataSource {

    /// Number of items in the collection: the snapshot plus the expanded folder's panel (D17).
    public func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        displayItems.count
    }

    /// The cell of a tile, a folder, or an expanded folder's panel.
    ///
    /// The tile content is prepared by ``configure(_:with:isVisible:)``: a static
    /// icon, title and badge, or a live container if the tile has
    /// ``TesseraTileDescriptor/liveContent``. Registering a live tile in the engine
    /// happens in `willDisplay`, not here: a cell prepared for
    /// prefetch may never appear on screen.
    ///
    /// The expanded folder's panel (D17) is a separate cell type: it does not intercept
    /// grid taps and draws the title with a grid of tiles in the desktop columns.
    public func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let item = displayItem(atIndex: indexPath.item) else {
            return collectionView.dequeueReusableCell(
                withReuseIdentifier: TesseraTileGridView.cellReuseIdentifier,
                for: indexPath
            )
        }

        if item.isFolderPanel {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TesseraTileGridView.folderPanelReuseIdentifier,
                for: indexPath
            )
            if let panelCell = cell as? TesseraFolderPanelCell {
                configure(panelCell, with: item)
            }
            return cell
        }

        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: TesseraTileGridView.cellReuseIdentifier,
            for: indexPath
        )
        if let tileCell = cell as? TesseraTileCell {
            configure(tileCell, with: item, isVisible: false)
        }
        return cell
    }
}

// MARK: - Tap movement tolerance

/// A passive recognizer: remembers whether the touch moved beyond the tap tolerance.
///
/// It never recognizes, never delays or cancels touches and does not interfere with the
/// other collection gestures — it only counts the offset from the touch-down point (in
/// window coordinates, so content scrolling does not distort the distance). The flag
/// is reset at the start of the next touch and persists after it ends:
/// `didSelectItemAt` arrives on release, when the flag is already set.
final class TesseraTileTapSlopRecognizer: UIGestureRecognizer {

    /// The movement tolerance in points — the same as the system tap.
    static let slop: CGFloat = 10

    /// Whether the last touch moved beyond the tolerance.
    var exceededSlop = false

    private var startPoint: CGPoint = .zero

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        exceededSlop = false
        startPoint = location(in: nil)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !exceededSlop else { return }
        let point = location(in: nil)
        if hypot(point.x - startPoint.x, point.y - startPoint.y) > TesseraTileTapSlopRecognizer.slop {
            exceededSlop = true
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }
}

// MARK: - UICollectionViewDelegate

extension TesseraTileGridView: UICollectionViewDelegate {

    /// Whether a collection item can be selected.
    ///
    /// The expanded folder's panel is a presentation, not a model item (D17):
    /// selection on it is not needed. The panel's own gesture has already handled a hit on a
    /// tile or a close on the background, and an extra `didSelect` after closing could
    /// arrive at an index where the panel no longer exists and trigger on someone else's item.
    public func collectionView(
        _ collectionView: UICollectionView,
        shouldSelectItemAt indexPath: IndexPath
    ) -> Bool {
        guard let item = displayItem(atIndex: indexPath.item) else { return false }
        return !item.isFolderPanel
    }

    /// A tap on an item: routing to ``handleItemTap(_:)`` (D12, D17).
    public func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        collectionView.deselectItem(at: indexPath, animated: false)

        // A touch that moved beyond the tolerance is not a tap (a long swipe
        // that neither the grid's pan nor the pager took).
        guard !tapSlopRecognizer.exceededSlop else { return }

        guard let item = displayItem(atIndex: indexPath.item),
              !hiddenItemIDs.contains(item.id) else {
            return
        }
        handleItemTap(item)
    }

    /// Cell display: registers a live tile in the engine and restores the hidden
    /// state after reuse.
    ///
    /// Registration happens here, not in `cellForItemAt`: UICollectionView
    /// reports the actual appearance of a cell on screen, including a return
    /// after scrolling. The single grid engine is not recreated by this — it
    /// only receives the container and the provider.
    ///
    /// The expanded folder's panel does not start the cascade here: the animation belongs
    /// to the folder opening, otherwise scrolling would repeat it on every display.
    public func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let item = displayItem(atIndex: indexPath.item) else { return }

        // The panel's title font is also rebuilt on display —
        // the Dynamic Type category may have changed while the cell was off-screen.
        if let panelCell = cell as? TesseraFolderPanelCell, item.isFolderPanel {
            configure(panelCell, with: item)
            panelCell.refreshTypography()
            return
        }

        guard let tileCell = cell as? TesseraTileCell, !item.isFolderPanel else {
            return
        }
        configure(tileCell, with: item, isVisible: true)
        // The dynamic font may have changed while the cell was off-screen
        // (for example, in prefetch): rebuild the metrics on display.
        tileCell.refreshTypography()
    }

    /// The cell leaves the screen: a live tile is paused (§4, "Pauses").
    ///
    /// The engine discards an unfinished flip and schedules no new ones, but
    /// keeps the provider subscription and the state of the faces — returning to the screen does not
    /// require re-registration. Registration is finally removed by
    /// `prepareForReuse`, as the engine contract requires.
    public func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let tileCell = cell as? TesseraTileCell else { return }
        // UIKit may call this after the cell has already been reused: if
        // it is back in the collection, the pause would apply to another (new) tile.
        guard collectionView.indexPath(for: cell) == nil else { return }
        tileCell.setLiveTileVisible(false)
    }

    /// Grid scrolling: only the offset is passed outward — no layout
    /// (§3, §8, CORE-IOS-DESIGN.md §2).
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onScrollOffsetChanged?(scrollView.contentOffset)
    }
}

// MARK: - Grid cell

/// The cell of a tile or folder.
///
/// One cell for both kinds of items: a tile and a folder have the same skeleton
/// (icon + title in a square), differing only in content and the presence of a
/// badge. This simplifies reuse when a folder appears in place of a tile
/// (D14: folder creation from a tile) — the cell type does not change.
///
/// The cell knows nothing about layout: the layout sets the frame, and
/// ``configure(with:liveTileEngine:isVisible:)`` sets the content. It does not take part
/// in the hot scroll path.
///
/// ## Live content (§4, D15)
///
/// If a tile has ``TesseraTileDescriptor/liveContent``, the static subviews
/// (icon, title, badge) give way to ``TesseraLiveTileView``: it
/// draws the front and back, and its badge lives above the faces and does not take part in the
/// flip. The container is created once and reused with the cell —
/// recreating it on every reuse would reset the flip and the provider subscription.
/// The engine of the grid drives the flip schedule; the cell only reports its visibility to it.
final class TesseraTileCell: UICollectionViewCell {

    /// The identifier of the item currently shown.
    private(set) var itemID: AnyHashable?

    /// The VoiceOver activation action (§9).
    ///
    /// The grid sets the closure when configuring the cell: the VoiceOver double tap
    /// lands on the tile's accessibility element, not on
    /// `collectionView(_:didSelectItemAt:)`.
    var onActivate: (() -> Void)?

    /// Folder rename (D35): the grid sets the closure on a folder tile
    /// while it has a rename handler. When not `nil`, a folder cell has the
    /// VoiceOver "Rename" action.
    var onRename: (() -> Void)?

    /// Whether the cell currently shows a folder (not a tile): the
    /// "Rename" action exists only for a folder.
    private var showsFolderItem = false

    /// Actions set by the edit coordinator (resize, unpin, "into
    /// folder"); "Rename" is added to them in ``accessibilityCustomActions``.
    private var assignedCustomActions: [UIAccessibilityCustomAction]?

    private lazy var renameAction = UIAccessibilityCustomAction(
        name: TesseraStartScreenStrings.string(.a11yActionRenameFolder),
        image: nil
    ) { [weak self] _ in
        guard let onRename = self?.onRename else { return false }
        onRename()
        return true
    }

    /// The cell's custom actions: the externally set ones plus "Rename" for a folder with a
    /// handler. The editor still assigns and removes **its own** actions
    /// (`= nil` does not erase "Rename"): it is available outside editing too (D35).
    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            var actions = assignedCustomActions ?? []
            if showsFolderItem, onRename != nil {
                actions.append(renameAction)
            }
            return actions.isEmpty ? nil : actions
        }
        set {
            assignedCustomActions = newValue
        }
    }

    private let iconView = UIImageView()
    private let titleLabel = UILabel()

    /// A tile's badge is a separate view above the tile (§4).
    ///
    /// The ready-made ``TesseraLiveTileBadgeView`` is reused: it already
    /// supports a dot/counter, "99+" and Dynamic Type and is not part of the flip. In
    /// live mode it is replaced by the ``TesseraLiveTileView`` badge.
    private let badgeView = TesseraLiveTileBadgeView()

    /// The live tile container; `nil` means the cell has not yet seen live content.
    private(set) var liveTileView: TesseraLiveTileView?

    /// Whether the cell currently shows live content.
    private var showsLiveContent = false

    /// The closed folder preview — a 2×2 mini-grid with an idle flip (D17).
    ///
    /// Created lazily: a tile and an empty folder have no preview. The view lives
    /// with the cell and is reused so the flip phase does not restart
    /// every time it appears on screen.
    private(set) var folderPreviewView: TesseraFolderPreviewView?

    /// Whether the cell currently shows a folder preview rather than a single icon.
    private var showsFolderPreview = false

    /// Whether the folder is expanded (D17).
    ///
    /// The expansion panel itself is drawn by the grid/host, not by the cell: the cell only needs to
    /// pause the preview and hide the 2×2 mini-tiles while the panel is open.
    /// The tile's backing and title stay — the panel sits below the tile, not
    /// in place of it.
    private var isFolderExpanded = false

    /// The engine in which ``liveTileView`` is registered.
    ///
    /// The reference is weak: the grid owns the engine. With `nil` (the grid has already
    /// been released) there is nothing to unregister from, and that is safe.
    private weak var liveTileEngine: TesseraLiveTileEngine?

    /// The provider with which the container is registered in the engine.
    ///
    /// Needed so that reconfiguring does not recreate the subscription:
    /// the same provider — only the visibility and badge are updated.
    private weak var registeredLiveProvider: TesseraLiveTileContentProvider?

    /// Whether ``liveTileView`` is registered in ``liveTileEngine``.
    private var isLiveRegistered = false

    /// The size bucket for which the font was built (0 — compact tiles,
    /// 1 — medium, 2 — large; the boundaries are by the actual side).
    private var titleFontBucket = -1

    /// The cap of the title font size (pt) for which it was built.
    private var titleFontCap: CGFloat = 0

    /// The Dynamic Type category for which the title font was built.
    private var titleFontCategory: UIContentSizeCategory?

    /// The title font before fitting to the tile width.
    ///
    /// `titleLabel.font` may be reduced in the layout so that the longest
    /// word fits on a line whole; the reduction is recomputed from this reference
    /// on every layout.
    private var titleBaseFont = UIFont.systemFont(ofSize: 12, weight: .semibold)

    /// The lower bound of fitting the title font to the width (a fraction of the base size).
    ///
    /// Below it the text is unreadable: then the title stays on one line and
    /// is truncated with an ellipsis, but is not broken mid-word.
    static let titleMinimumScaleFactor: CGFloat = 0.6

    /// The fraction of the tile's shorter side above which the title font does not grow
    /// as Dynamic Type increases: the caption must not eat up the tile.
    static let titleFontSideFraction: CGFloat = 0.2

    /// The target content alpha in edit mode.
    ///
    /// The grid owns the dimming: it passes the target value here
    /// (`TesseraTileGridView.setEditDimming(_:animated:)`), and the cell only
    /// stores it and does not reset it in ``configure(with:liveTileEngine:isVisible:isFolderExpanded:)``.
    private var dimmingAlpha: CGFloat = 1

    /// Whether the coordinator hid the cell during a drag.
    ///
    /// Hiding overrides the dimming: `contentView.alpha` = 0 while the flag is on.
    private var isSourceHidden = false

    /// The tile in the model is small (1×1, ``TesseraTileSize/small``), D47.
    ///
    /// A small tile with a visible badge and an icon shows the icon and badge without a
    /// caption (``TesseraTileBadgeLayout/Arrangement/iconAndBadge``). The flag
    /// comes from the model, not from geometry: at any grid width a small tile
    /// behaves the same, and 2×2 and larger are unaffected. Set by
    /// `configure`; for a folder and a reused cell — `false`.
    private(set) var isSmallTile = false

    /// The folder in the model is small (1×1, ``TesseraTileSize/small``).
    ///
    /// A small folder with a visible badge draws no caption (like a small tile with an
    /// icon, D47): the preview mini-grid sits above the badge row, and the badge is in the
    /// bottom corner. Without a badge, and for 2×2 and larger folders, the layout is as before.
    /// Set by `configure`; for a tile and a reused cell — `false`.
    private var isSmallFolder = false

    /// The text part of a folder tile's `accessibilityValue` for the aggregate badge
    /// (D44): a number for a sum, "has notification" for a dot; `nil` means
    /// no badge.
    private var folderAccessibilityBadgeText: String?

    /// The text part of `accessibilityValue` for a folder tile without the expansion
    /// state (the tile count).
    ///
    /// Stored separately so that ``setFolderExpanded(_:)`` can add the "expanded"
    /// state to the count without losing the existing value.
    private var folderAccessibilityCountText: String?

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    deinit {
        // A safeguard for the case of a collection reload without `prepareForReuse`:
        // the engine retains the container and the provider, so a vanished
        // cell must remove its own registration.
        if isLiveRegistered, let liveTileView {
            liveTileEngine?.unregister(liveTileView)
        }
    }

    /// Shared setup: a square tile, one accessibility element (§9).
    private func setUp() {
        backgroundColor = .clear
        contentView.backgroundColor = .secondarySystemBackground
        contentView.clipsToBounds = true

        // §9: a tile is one element; the icon, title and badge are its parts.
        isAccessibilityElement = true
        accessibilityTraits = .button

        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false
        iconView.clipsToBounds = true

        titleLabel.numberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textAlignment = .natural
        titleLabel.textColor = .label
        titleLabel.isAccessibilityElement = false
        // The font is built manually in `updateTitleFontIfNeeded()`: the grid
        // notifies cells of a category change (see `refreshTypography()`),
        // so UILabel automatic scaling is disabled — otherwise the
        // scale would be applied twice.
        titleLabel.adjustsFontForContentSizeCategory = false

        contentView.addSubview(iconView)
        contentView.addSubview(titleLabel)
        // The badge goes last: it must sit above the icon and the title.
        contentView.addSubview(badgeView)

        badgeView.onBadgeChange = { [weak self] in
            self?.setNeedsLayout()
        }
    }

    // MARK: - Content

    /// Applies a grid item.
    ///
    /// A static tile and a folder are drawn as before (icon + title +
    /// badge). If a tile has ``TesseraTileDescriptor/liveContent``, the content
    /// is handed to ``TesseraLiveTileView`` and registered in the engine.
    ///
    /// - Parameters:
    ///   - item: A tile or folder from the `TesseraTileStore` snapshot.
    ///   - engine: The live tile engine. `nil` means the cell is only being prepared for display
    ///     (`cellForItemAt`): the faces are rendered without a flip schedule.
    ///   - isVisible: Whether the cell is visible now; the engine does not flip invisible
    ///     tiles (§4, "Pauses").
    ///   - isFolderExpanded: Whether this folder is expanded by the panel (D17): an expanded
    ///     folder pauses the preview idle flip. Irrelevant for a tile.
    func configure(
        with item: TesseraTileGridItem,
        liveTileEngine engine: TesseraLiveTileEngine?,
        isVisible: Bool,
        isFolderExpanded: Bool = false
    ) {
        itemID = item.id
        isSmallTile = item.tile?.size == .small
        if case .folder(let folder) = item {
            showsFolderItem = true
            isSmallFolder = folder.size == .small
        } else {
            showsFolderItem = false
            isSmallFolder = false
        }

        switch item {
        case .tile(let descriptor):
            endFolderPreview()
            self.isFolderExpanded = false
            if let provider = descriptor.liveContent {
                configureLiveContent(
                    provider: provider,
                    badge: descriptor.badge,
                    engine: engine,
                    isVisible: isVisible
                )
            } else {
                endLiveContent()
                configureStaticTile(descriptor)
            }
            configureAccessibility(for: descriptor)

        case .folder(let folder):
            endLiveContent()
            configureStaticFolder(folder, isVisible: isVisible)
            configureAccessibility(for: folder)
            // D17: an expanded folder pauses the preview idle flip so that the
            // panel icon cascade does not compete with the mini-tile flip.
            setFolderExpanded(isFolderExpanded)

        case .folderContent(let folder):
            // The expanded folder's panel is drawn by a separate panel view,
            // not by the tile cell (D17). A defensive fallback path:
            // only the folder title — the cell does not pretend to be a closed folder
            // with a mini-grid and does not start the idle flip.
            endLiveContent()
            endFolderPreview()
            self.isFolderExpanded = false
            iconView.image = nil
            iconView.tintColor = nil
            iconView.isHidden = true
            titleLabel.text = folder.title
            badgeView.badge = .none
            badgeView.isHidden = true
            configureAccessibility(for: folder)
        }

        // The size may have changed (resize, D15): the font is rebuilt in layout.
        titleFontBucket = -1
        accessibilityElementsHidden = false
        // Alpha is not reset — the grid owns it (the 0.7 dimming of
        // edit mode survives snapshot updates and resize). The cell
        // only applies the stored target.
        updateContentAlpha()
        setNeedsLayout()
    }

    /// A static tile: the tile's icon, title and badge (the previous behavior).
    private func configureStaticTile(_ descriptor: TesseraTileDescriptor) {
        iconView.image = descriptor.icon
        iconView.tintColor = nil
        titleLabel.text = descriptor.title
        badgeView.badge = descriptor.badge
        // After a folder the cell may have kept its layout: return the badge
        // to the hierarchy (with `.none` it is invisible by itself).
        badgeView.isHidden = false
    }

    /// A folder: a mini-grid of content or a preview icon/placeholder, a title and
    /// the aggregate badge (D44).
    ///
    /// A folder's badge is the sum of the numeric badges of its tiles (a dot if there are
    /// no numeric ones): ``TesseraTileFolder/aggregateBadge(of:)``. It is computed here, when applying
    /// the snapshot, not in layout. Preview mini-icons keep their own badges.
    ///
    /// A closed folder shows up to the first four tile icons (D17): this is the
    /// Windows Phone content preview instead of a single icon. An empty folder keeps
    /// the previous behavior — the explicit preview icon ``TesseraTileFolder/icon``, or, without one,
    /// the `folder.fill` placeholder.
    ///
    /// - Parameters:
    ///   - folder: The folder model.
    ///   - isVisible: Whether the cell is visible: the preview idle flip runs only on screen.
    private func configureStaticFolder(_ folder: TesseraTileFolder, isVisible: Bool) {
        // A folder without a title is captioned with the localized default.
        titleLabel.text = folder.title.isEmpty
            ? TesseraStartScreenStrings.string(.folderScreenDefaultTitle)
            : folder.title
        let aggregate = folder.aggregateBadge
        badgeView.badge = aggregate
        badgeView.isHidden = !aggregate.isVisible

        guard !folder.tiles.isEmpty else {
            endFolderPreview()
            if let icon = folder.icon {
                iconView.image = icon
                iconView.tintColor = nil
            } else {
                // The folder placeholder icon; the template symbol is tinted
                // secondaryLabel and adapts to the dark theme.
                iconView.image = UIImage(systemName: "folder.fill")
                iconView.tintColor = .secondaryLabel
            }
            iconView.isHidden = false
            return
        }

        let preview = folderPreviewView ?? makeFolderPreviewView()
        preview.configure(
            tiles: Array(folder.tiles.prefix(4)),
            schedule: TesseraFolderFlipSchedule(folderID: folder.id)
        )
        preview.setExpanded(isFolderExpanded)
        preview.setVisible(isVisible)
        showsFolderPreview = true
        // D17: for an expanded folder the preview mini-tiles are hidden — the tile stays
        // a visible backing with a title.
        updateFolderPreviewVisibility()

        // The single icon gives way to the mini-grid; its mini-tiles have
        // their own icons, so the cell's shared icon is not needed.
        iconView.image = nil
        iconView.tintColor = nil
        iconView.isHidden = true
    }

    // MARK: - Live content

    /// Prepares the live side: the container, the badge and registration in the engine.
    ///
    /// - Parameters:
    ///   - provider: The tile's content provider.
    ///   - badge: The tile badge (D12/D15) — drawn by the container above the faces.
    ///   - engine: The grid engine; `nil` means a preview without a schedule.
    ///   - isVisible: Whether the cell is visible.
    private func configureLiveContent(
        provider: TesseraLiveTileContentProvider,
        badge: TesseraTileBadge,
        engine: TesseraLiveTileEngine?,
        isVisible: Bool
    ) {
        let liveView = liveTileView ?? makeLiveTileView()
        showsLiveContent = true

        // The container draws the front/back and the badge: the static subviews give
        // way to it. The container badge does not take part in the flip (§4, D15).
        iconView.isHidden = true
        titleLabel.isHidden = true
        badgeView.isHidden = true
        liveView.isHidden = false
        liveView.badge = badge
        liveView.isSmallTile = isSmallTile
        liveView.badgeEditClearance = badgeEditClearance

        guard let engine else {
            // The cell is not yet shown: faces without registration, so the engine does not
            // schedule flips for a cell that may never appear.
            if !isLiveRegistered {
                liveView.setFaces(front: provider.frontFace, back: provider.backFace)
                liveView.show(.front, animated: false)
            }
            return
        }

        attachLiveContent(
            of: provider,
            to: liveView,
            engine: engine,
            isVisible: isVisible
        )
    }

    /// Registers the container in the engine or, if the provider is the same,
    /// limits itself to updating visibility.
    ///
    /// Re-registering on every snapshot update is not needed: the engine
    /// retains the provider and re-reads the faces itself via the subscription.
    private func attachLiveContent(
        of provider: TesseraLiveTileContentProvider,
        to liveView: TesseraLiveTileView,
        engine: TesseraLiveTileEngine,
        isVisible: Bool
    ) {
        if isLiveRegistered,
           registeredLiveProvider !== provider || liveTileEngine !== engine {
            // The provider or the engine changed: the previous registration is stale.
            liveTileEngine?.unregister(liveView)
            isLiveRegistered = false
        }

        liveTileEngine = engine

        if isLiveRegistered {
            engine.setVisible(isVisible, for: liveView)
            return
        }

        registeredLiveProvider = provider
        // A new registration always starts from the front: the cell may have come from
        // reuse on the back (the engine does not change the face on `unregister`), and the front is
        // the settled state of a tile (§4).
        liveView.show(.front, animated: false)
        engine.register(liveView, provider: provider, isVisible: isVisible)
        isLiveRegistered = true
    }

    /// Creates the live tile container once per cell.
    ///
    /// The container does not intercept touches and is not a separate
    /// accessibility element: the tap and the spoken output stay with the cell (§9,
    /// "a tile is one element").
    private func makeLiveTileView() -> TesseraLiveTileView {
        let liveView = TesseraLiveTileView(frame: contentView.bounds)
        liveView.isAccessibilityElement = false
        liveView.isUserInteractionEnabled = false
        contentView.addSubview(liveView)
        liveTileView = liveView
        return liveView
    }

    /// Turns live mode off: the registration in the engine is cancelled, the static subviews
    /// return to the layout.
    ///
    /// The container itself is not destroyed — it is reused if the tile becomes
    /// live again.
    private func endLiveContent() {
        if isLiveRegistered, let liveTileView {
            liveTileEngine?.unregister(liveTileView)
        }
        isLiveRegistered = false
        registeredLiveProvider = nil
        liveTileEngine = nil
        showsLiveContent = false
        // A reused cell goes to the settled state: after
        // `unregister` the engine does not change the face, so set the front ourselves.
        liveTileView?.show(.front, animated: false)
        liveTileView?.isHidden = true
        badgeView.isHidden = false
        iconView.isHidden = false
        titleLabel.isHidden = false
    }

    /// Pauses or resumes a live tile and a folder's idle flip (§4).
    ///
    /// The engine does not flip an invisible tile and discards an unfinished flip, but
    /// keeps the provider subscription and the state of the faces — returning to the screen does not
    /// require re-registration. The folder preview runs its own timer, but
    /// the pause is the same: off-screen the mini-icons return to icons and do not
    /// flip (D17).
    ///
    /// - Parameter visible: Whether the cell is on screen.
    func setLiveTileVisible(_ visible: Bool) {
        folderPreviewView?.setVisible(visible)
        guard isLiveRegistered, let liveTileView, let liveTileEngine else { return }
        liveTileEngine.setVisible(visible, for: liveTileView)
    }

    /// Tells the cell that the folder is expanded by the panel (D17).
    ///
    /// The expansion is drawn by the grid's panel, not by the cell: the cell pauses the preview
    /// (the idle flip must not compete with the panel icon cascade) and hides the
    /// 2×2 mini-tiles, leaving the tile's backing and title. Closing the folder
    /// returns the preview to the schedule (if the cell is visible) and shows the
    /// mini-tiles again.
    ///
    /// The state is stored as a flag, not only on the preview: the cell
    /// is reused, and `configure(with:isFolderExpanded:)` reapplies the flag
    /// on every display, so another folder does not inherit a hidden or
    /// shown preview.
    ///
    /// - Parameter expanded: Whether the folder is expanded by this grid item.
    func setFolderExpanded(_ expanded: Bool) {
        isFolderExpanded = expanded
        folderPreviewView?.setExpanded(expanded)
        updateFolderPreviewVisibility()
        // The "expanded" state must be announced by VoiceOver. The tile
        // count in the value is kept, and the state is appended to it.
        updateFolderAccessibilityValue()
    }

    /// Shows the preview mini-tiles only for a closed folder (D17).
    ///
    /// The 2×2 mini-icon block (`TesseraFolderPreviewView`) is hidden, not
    /// the whole cell: the backing and the title stay. `isHidden` is more reliable than `alpha`:
    /// it excludes the preview from rendering and hit testing, and implicit animations
    /// of a reused cell cannot make it visible again.
    private func updateFolderPreviewVisibility() {
        folderPreviewView?.isHidden = !showsFolderPreview || isFolderExpanded
    }

    /// Creates the folder preview once per cell.
    ///
    /// The preview does not intercept touches and is not an accessibility element:
    /// the folder stays one VoiceOver element (§9). The layer is under the title,
    /// so the folder text always reads on top of the icon grid.
    private func makeFolderPreviewView() -> TesseraFolderPreviewView {
        let preview = TesseraFolderPreviewView(frame: .zero)
        contentView.insertSubview(preview, belowSubview: titleLabel)
        folderPreviewView = preview
        return preview
    }

    /// Removes the folder preview: returns to the icon/placeholder and stops the
    /// idle flip. The view itself is not destroyed — it is reused if the cell
    /// shows a folder again.
    private func endFolderPreview() {
        showsFolderPreview = false
        folderPreviewView?.stop()
        folderPreviewView?.isHidden = true
    }

    /// §9: a tile is one element; the label is the title (for a live tile — from the front),
    /// the value is the badge count.
    ///
    /// A live tile shows the front face, so the label is taken
    /// from ``TesseraTileDescriptor/liveContent`` (`frontFace.title` plus `detail`, joined
    /// with a comma): VoiceOver must read what is visible on the front face, not the
    /// previous static title. If the front is empty, the tile's `title` remains.
    private func configureAccessibility(for descriptor: TesseraTileDescriptor) {
        let frontFace = descriptor.liveContent?.frontFace
        var labelParts: [String] = []
        if let frontTitle = frontFace?.title, !frontTitle.isEmpty {
            labelParts.append(frontTitle)
        } else if !descriptor.title.isEmpty {
            labelParts.append(descriptor.title)
        }
        if let detail = frontFace?.detail, !detail.isEmpty {
            labelParts.append(detail)
        }
        accessibilityLabel = labelParts.isEmpty ? nil : labelParts.joined(separator: ", ")

        // D34: a dot without a number is spoken as the string "has notification",
        // a counter as a number, and `.none` has no value.
        accessibilityValue = descriptor.badge.accessibilityValueText
    }

    /// §9: a folder is one element; the tile count is in the value.
    private func configureAccessibility(for folder: TesseraTileFolder) {
        accessibilityLabel = folder.title.isEmpty
            ? TesseraStartScreenStrings.string(.folderScreenDefaultTitle)
            : folder.title
        folderAccessibilityCountText = folder.tiles.isEmpty ? nil : String(folder.tiles.count)
        // D44: the same helper as for a tile (D34): the sum number or
        // "has notification" for a dot.
        folderAccessibilityBadgeText = folder.aggregateBadge.accessibilityValueText
        updateFolderAccessibilityValue()
    }

    /// Builds the folder's `accessibilityValue` accounting for the badge and expansion.
    ///
    /// First comes the aggregate badge value (if there is one), then the tile
    /// count and the "expanded" state. A folder without a badge is spoken as
    /// before — the tile count, and when closed, only it.
    private func updateFolderAccessibilityValue() {
        var parts: [String] = []
        if let folderAccessibilityBadgeText {
            parts.append(folderAccessibilityBadgeText)
        }
        if let folderAccessibilityCountText {
            parts.append(folderAccessibilityCountText)
        }
        if isFolderExpanded {
            parts.append(TesseraStartScreenStrings.string(.panelExpanded))
        }
        accessibilityValue = parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Rebuilds the title font for the current Dynamic Type category.
    ///
    /// Called by the grid on a category change (one notification for the whole grid
    /// is cheaper than an observer in every cell) and before a cell is shown —
    /// the category may have changed while the cell was in prefetch.
    func refreshTypography() {
        titleFontBucket = -1
        setNeedsLayout()
    }

    /// VoiceOver activation of a tile (§9): a double tap runs the tile's action.
    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return super.accessibilityActivate() }
        onActivate()
        return true
    }

    /// Hides/shows the source cell during a drag.
    ///
    /// `alpha` is changed on `contentView`, not on the cell: UICollectionView
    /// applies layout attributes to the cell and may return `cell.alpha` to 1
    /// on the next layout pass, while `contentView` does not depend on attributes.
    /// The frame and place in the layout stay the same, so neighboring tiles
    /// do not shift.
    ///
    /// - Parameter hidden: `true` — the cell is invisible and not spoken.
    func setSourceHidden(_ hidden: Bool) {
        isSourceHidden = hidden
        updateContentAlpha()
        accessibilityElementsHidden = hidden
    }

    /// Applies the target content alpha in edit mode.
    ///
    /// The value owner is the grid: it passes the dimming here and does not reset it in
    /// `configure`, so neither a snapshot update, nor resize, nor cell reuse
    /// "lifts" the tile back to 1.
    ///
    /// - Parameter alpha: Content alpha: 1 is full brightness,
    ///   ``TesseraTileGridView/dimmedTileAlpha`` is the edit mode dimming.
    func setDimmingAlpha(_ alpha: CGFloat) {
        guard alpha.isFinite else { return }
        dimmingAlpha = min(max(alpha, 0), 1)
        updateContentAlpha()
    }

    /// How much of the bottom corner at the end of the line the edit mode size
    /// arrow occupies, in pt; `0` means outside editing or no arrow (D29).
    ///
    /// The badge avoids this area: it shifts from the corner along the bottom row
    /// (``TesseraTileBadgeLayout``). The value is owned by the grid
    /// (``TesseraTileGridView/setBadgeEditClearances(_:animated:)``), like
    /// the dimming: `configure` applies the stored value, and cell reuse
    /// returns 0.
    private(set) var badgeEditClearance: CGFloat = 0

    /// Applies the badge inset from the size arrow (D29).
    ///
    /// - Parameters:
    ///   - clearance: The part of the corner inside the tile occupied by the arrow, in pt.
    ///   - animated: Smoothly shift the badge and caption; without animation the layout
    ///     is updated on the next layout pass.
    func setBadgeEditClearance(_ clearance: CGFloat, animated: Bool) {
        let value = clearance.isFinite ? max(0, clearance) : 0
        guard value != badgeEditClearance else { return }
        badgeEditClearance = value
        liveTileView?.badgeEditClearance = value
        setNeedsLayout()

        guard animated, window != nil else { return }
        UIView.animate(
            withDuration: TesseraTileGridView.dimmingDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
            animations: { [weak self] in
                self?.layoutIfNeeded()
                self?.liveTileView?.layoutIfNeeded()
            },
            completion: nil
        )
    }

    /// Recomputes the actual content alpha.
    ///
    /// Hiding during a drag overrides the dimming: a hidden cell has `alpha` = 0, otherwise
    /// the stored target alpha.
    private func updateContentAlpha() {
        contentView.alpha = isSourceHidden ? 0 : dimmingAlpha
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()

        // The engine retains the container and the provider: without an explicit cancel the cell
        // would stay registered after reuse (§4).
        endLiveContent()
        // The folder preview must also return to icons: otherwise another folder
        // would inherit the counter and the flip phase (D17).
        endFolderPreview()
        isFolderExpanded = false

        // The jiggle of edit mode lives on the cell as layer animations.
        // A reused cell must not inherit someone else's animation or
        // rotation from the previous item.
        layer.removeAllAnimations()
        contentView.layer.removeAllAnimations()
        transform = .identity
        contentView.transform = .identity
        alpha = 1

        itemID = nil
        isSmallTile = false
        liveTileView?.isSmallTile = false
        onActivate = nil
        onRename = nil
        showsFolderItem = false
        isSmallFolder = false
        iconView.image = nil
        iconView.tintColor = nil
        titleLabel.text = nil
        badgeView.badge = .none
        accessibilityLabel = nil
        accessibilityValue = nil
        titleFontBucket = -1
        // The dimming and hiding belong to the grid: the clean state is full brightness.
        // The next `configure` applies the stored target.
        dimmingAlpha = 1
        badgeEditClearance = 0
        liveTileView?.badgeEditClearance = 0
        folderAccessibilityCountText = nil
        folderAccessibilityBadgeText = nil
        setSourceHidden(false)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        if showsLiveContent {
            // The container fills the whole tile; it lays out the face content, the badge and RTL
            // itself (§4), and the cell only gives it a frame.
            liveTileView?.frame = contentView.bounds
            return
        }

        updateTitleFontIfNeeded()
        layoutContent()
    }

    /// §9, RTL: a reading direction change swaps the icon and the badge.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard previousTraitCollection?.layoutDirection != traitCollection.layoutDirection else {
            return
        }
        setNeedsLayout()
    }

    /// Builds the title font for the actual tile size.
    ///
    /// The cell does not know the size model directly (the layout may have shrunk the footprint),
    /// so it relies on its own `bounds`: compact, medium and
    /// large tiles give different base sizes. Dynamic Type metrics
    /// are applied on top of the base size; rebuilding happens only when the
    /// bucket changes or via ``refreshTypography()``.
    private func updateTitleFontIfNeeded() {
        let side = min(contentView.bounds.width, contentView.bounds.height)
        let bucket: Int
        if side < 100 {
            bucket = 0
        } else if side < 220 {
            bucket = 1
        } else {
            bucket = 2
        }

        let baseSize: CGFloat
        switch bucket {
        case 0: baseSize = 12
        case 1: baseSize = 14
        default: baseSize = 17
        }

        // Dynamic Type grows, but not beyond a fraction of the tile side
        // (at accessibility sizes 12 pt would otherwise give ~30 pt on a 73 pt tile).
        let cap = max(baseSize, floor(side * TesseraTileCell.titleFontSideFraction))
        let category = traitCollection.preferredContentSizeCategory

        guard bucket != titleFontBucket
            || cap != titleFontCap
            || category != titleFontCategory
        else { return }
        titleFontBucket = bucket
        titleFontCap = cap
        titleFontCategory = category

        let font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: baseSize, weight: .semibold),
            maximumPointSize: cap,
            compatibleWith: traitCollection
        )
        titleBaseFont = font
        titleLabel.font = font
    }

    /// Fits the title font so that the longest word fits on a
    /// line whole.
    ///
    /// `UILabel` breaks a word that does not fit on a line in the middle of a character
    /// ("Calenda/r"). So the font is reduced (down to
    /// ``titleMinimumScaleFactor`` of the base) to fit the width of the longest
    /// word. If it still does not fit, `false` is returned: the caller
    /// sets a single line, and the title is truncated with an ellipsis instead of being broken.
    ///
    /// - Parameter width: The available line width.
    /// - Returns: Whether the longest word fits whole.
    @discardableResult
    private func fitTitleFont(toWidth width: CGFloat) -> Bool {
        titleLabel.font = titleBaseFont
        guard width > 0, let text = titleLabel.text, !text.isEmpty else { return true }

        let words = text.components(separatedBy: .whitespacesAndNewlines)
        func longest(_ font: UIFont) -> CGFloat {
            words.reduce(0) { widest, word in
                max(widest, ceil((word as NSString).size(withAttributes: [.font: font]).width))
            }
        }

        let widest = longest(titleBaseFont)
        guard widest > width else { return true }

        let scale = max(TesseraTileCell.titleMinimumScaleFactor, width / widest)
        let scaled = titleBaseFont.withSize(floor(titleBaseFont.pointSize * scale))
        titleLabel.font = scaled
        return longest(scaled) <= width
    }

    /// Lays out the icon, title and badge.
    ///
    /// Manual `frame`s only: the cell is a grid square, Auto Layout is
    /// redundant here and would add an extra pass on every resize.
    private func layoutContent() {
        let bounds = contentView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        if showsFolderPreview {
            layoutFolderPreview(in: bounds)
            return
        }

        let minimumSide = min(bounds.width, bounds.height)
        let inset = max(6, min(12, minimumSide * 0.08))
        let contentWidth = max(0, bounds.width - inset * 2)
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft

        // The badge is in the bottom corner at the end of the line (D29; §4, §9, RTL); in
        // editing it avoids the size arrow. The caption gives it room:
        // it narrows next to it or moves up above its row.
        let badgeSize = badgeView.intrinsicContentSize
        let hasImage = iconView.image != nil
        // D47: a small tile with a badge and an icon shows the icon and badge, no caption
        // (the VoiceOver label and value do not change). Without an icon the caption stays.
        let badgeLayout = TesseraTileBadgeLayout.make(
            tileSize: bounds.size,
            badgeSize: badgeSize,
            inset: inset,
            isRightToLeft: isRightToLeft,
            editClearance: badgeEditClearance,
            hidesTitle: isSmallTile && hasImage
        )
        badgeView.frame = badgeLayout.frame
        badgeView.alpha = badgeLayout.isHiddenByEditControls ? 0 : 1

        if badgeLayout.arrangement == .iconAndBadge {
            titleLabel.isHidden = true
            titleLabel.frame = .zero
            iconView.isHidden = false
            iconView.frame = TesseraTileBadgeLayout.smallTileIconFrame(
                tileSize: bounds.size,
                inset: inset,
                bottomReserve: badgeLayout.iconBottomReserve
            )
            return
        }
        titleLabel.isHidden = false

        let titleWidth = max(0, contentWidth - badgeLayout.titleTrailingReserve)
        let titleFits = fitTitleFont(toWidth: titleWidth)

        // The icon is in the top corner by reading direction (§9).
        var iconSide = hasImage ? max(14, min(34, minimumSide * 0.22)) : 0
        let lineHeight = titleLabel.font.lineHeight

        // The title is pinned to the bottom and does not enter the top zone occupied by the icon,
        // or the bottom badge row if the caption is above it. If there is no room for a line,
        // the icon is hidden — text matters more for 1×1 and for large Dynamic
        // Type.
        let bottomReserve = badgeLayout.titleBottomReserve
        var topReserve = hasImage ? iconSide : 0
        var titleHeightLimit = bounds.height - inset * 2 - bottomReserve
            - (topReserve > 0 ? topReserve + 4 : 0)
        if hasImage && titleHeightLimit < lineHeight {
            iconSide = 0
            topReserve = 0
            titleHeightLimit = bounds.height - inset * 2 - bottomReserve
        }

        let showsIcon = hasImage && iconSide > 0
        iconView.isHidden = !showsIcon
        if showsIcon {
            let iconX = isRightToLeft ? bounds.width - inset - iconSide : inset
            iconView.frame = CGRect(x: iconX, y: inset, width: iconSide, height: iconSide)
        } else {
            iconView.frame = .zero
        }

        guard titleWidth > 0 else {
            titleLabel.frame = .zero
            return
        }

        if !titleFits {
            // The word does not fit even at the minimum scale —
            // a single line with an ellipsis instead of a break mid-word.
            titleLabel.numberOfLines = 1
        } else if titleHeightLimit >= lineHeight * 2.5 {
            titleLabel.numberOfLines = 3
        } else if titleHeightLimit >= lineHeight * 1.5 {
            titleLabel.numberOfLines = 2
        } else {
            titleLabel.numberOfLines = 1
        }

        let measured = titleLabel.sizeThatFits(
            CGSize(width: titleWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        let titleHeight = min(ceil(measured.height), max(0, titleHeightLimit))
        // In RTL the badge is on the left, so a "nearby" caption shifts to the right.
        let titleX = isRightToLeft ? inset + badgeLayout.titleTrailingReserve : inset
        titleLabel.frame = CGRect(
            x: titleX,
            y: bounds.height - inset - bottomReserve - titleHeight,
            width: titleWidth,
            height: titleHeight
        )
    }

    /// Lays out the folder preview, the title under it and the aggregate badge (D17, D44).
    ///
    /// The preview is a 2×2 square pinned to the **top** corner of the tile by
    /// reading direction (§9): left in LTR, right in RTL. This way a closed folder
    /// reads like the desktop grid: mini-icons start from the same edge
    /// as tiles rather than hanging in the center. The edge inset is the same as for a tile
    /// (`inset`), so the preview does not stick to the cell border. The title is pinned
    /// to the bottom, like a tile's.
    ///
    /// The aggregate badge sits in the bottom corner at the end of the line and avoids the
    /// size arrow while editing — using the same ``TesseraTileBadgeLayout`` layout
    /// as a tile: the caption narrows next to it or moves up above its row,
    /// and the preview gives way to the caption and the badge row. A small (1×1) folder with a
    /// visible badge draws no caption (like a small tile with an icon, D47):
    /// the mini-grid sits centered above the badge row. A small folder without a badge and
    /// folders 2×2 and larger without a badge are laid out as before.
    ///
    /// If the tile is short (large Dynamic Type, a thin 1×1 folder), the title has
    /// priority: the preview shrinks together with its mini-tiles.
    ///
    /// - Parameter bounds: The cell content bounds.
    private func layoutFolderPreview(in bounds: CGRect) {
        guard let preview = folderPreviewView else { return }

        let minimumSide = min(bounds.width, bounds.height)
        let inset = max(6, min(12, minimumSide * 0.08))
        let contentWidth = max(0, bounds.width - inset * 2)
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft

        iconView.isHidden = true
        iconView.frame = .zero
        // The caption may have been hidden by a previous small tile (D47).
        titleLabel.isHidden = false

        // The aggregate badge is in the bottom corner at the end of the line; without a badge
        // `intrinsicContentSize` is zero and the layout is empty.
        let badgeSize = badgeView.intrinsicContentSize
        let hasBadge = badgeSize.width > 0 && badgeSize.height > 0
        let badgeLayout = TesseraTileBadgeLayout.make(
            tileSize: bounds.size,
            badgeSize: badgeSize,
            inset: inset,
            isRightToLeft: isRightToLeft,
            editClearance: badgeEditClearance,
            hidesTitle: isSmallFolder && hasBadge
        )
        badgeView.frame = badgeLayout.frame
        badgeView.alpha = badgeLayout.isHiddenByEditControls ? 0 : 1

        if badgeLayout.arrangement == .iconAndBadge {
            // 1×1 with a badge: no caption (the VoiceOver label and value are as before),
            // the mini-grid is centered in the top zone above the badge row.
            titleLabel.isHidden = true
            titleLabel.frame = .zero
            preview.frame = TesseraTileBadgeLayout.smallTileIconFrame(
                tileSize: bounds.size,
                inset: inset,
                bottomReserve: badgeLayout.iconBottomReserve
            )
            return
        }

        let titleWidth = max(0, contentWidth - badgeLayout.titleTrailingReserve)
        let titleFits = fitTitleFont(toWidth: titleWidth)
        titleLabel.numberOfLines = titleFits ? 2 : 1
        let measuredTitle = titleLabel.sizeThatFits(
            CGSize(width: titleWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        let bottomReserve = badgeLayout.titleBottomReserve
        let titleHeight = min(
            ceil(measuredTitle.height),
            titleLabel.font.lineHeight * 2,
            max(0, bounds.height - bottomReserve) * 0.32
        )
        // In RTL the badge is on the left, so a "nearby" caption shifts to the right.
        let titleX = isRightToLeft ? inset + badgeLayout.titleTrailingReserve : inset
        titleLabel.frame = CGRect(
            x: titleX,
            y: bounds.height - inset - bottomReserve - titleHeight,
            width: titleWidth,
            height: titleHeight
        )

        // The bottom row is the caption and the badge side by side: if the badge is taller than the caption (a single
        // line with a large capsule), the preview gives way to it.
        let bottomRowHeight = badgeLayout.arrangement == .beside
            ? max(titleHeight, badgeSize.height)
            : titleHeight
        let gap = max(2, minimumSide * 0.03)
        let available = max(0, bounds.height - inset * 2 - bottomRowHeight - bottomReserve - gap)
        let blockSide = min(contentWidth, available)
        guard blockSide > 0 else {
            preview.frame = .zero
            return
        }

        // RTL: the mini-grid is mirrored — pinned to the top right corner,
        // so the reading order stays the same. The title at the bottom is not mirrored:
        // its alignment is set by the caption itself (`.natural`).
        preview.frame = CGRect(
            x: isRightToLeft ? bounds.width - inset - blockSide : inset,
            y: inset,
            width: blockSide,
            height: blockSide
        )
    }
}

/// Geometry of the tiles of the visible expanded folder's panel (D46).
struct TesseraPanelShortcutGeometry {

    /// The expanded folder.
    let folderID: AnyHashable

    /// Tile identifiers in folder order.
    let tileIDs: [AnyHashable]

    /// Tile frames in grid coordinates (in ``tileIDs`` order).
    let frames: [CGRect]

    /// The gap between the panel's tiles (the grid's `itemSpacing`).
    let spacing: CGFloat

    /// Frames of the panel **slots** in grid coordinates (in ``tileIDs`` order).
    ///
    /// A slot is a tile's place in the panel layout (the grid columns, mirrored
    /// in RTL). Unlike ``frames`` it does not depend on the reorder preview:
    /// during a drag inside the panel the neighbor tiles are shifted, while the slots
    /// stay in place. The hit test uses them to pick the slot under the finger.
    let slotFrames: [CGRect]

    /// The frame of the panel itself (the expanded folder's cell) in grid coordinates.
    ///
    /// When the finger leaves it (with a margin), a drag inside the panel becomes taking
    /// the tile out onto the desktop.
    let panelFrame: CGRect
}

/// A tile of the expanded folder's panel found under the finger.
struct TesseraPanelTileHit {

    /// The expanded folder (from the grid snapshot).
    let folder: TesseraTileFolder

    /// The tile whose icon was pressed.
    let tile: TesseraTileDescriptor

    /// The icon frame in grid coordinates.
    let frame: CGRect

    /// A snapshot of the icon (a copy that outlives the panel closing).
    let snapshot: UIView
}

// MARK: - Expanded folder panel (D17)

/// The cell of the expanded folder's panel: a title and a grid of tiles (D17).
///
/// The panel is a full-width collection cell inserted as a separate
/// row right after the row where the folder tile ends
/// (``TesseraTileGridItem/folderContent(_:)``); the folder tile itself stays visible.
/// The geometry is set by `TesseraTileCollectionViewLayout` (the top edge is the row
/// right below the folder, the height follows the formula
/// ``TesseraTileLayoutEngine/panelHeight(for:width:columns:)``), so the cell only
/// lays out its content with the same constants. The constants themselves are taken
/// from the engine (`Metrics`): the height formula and the content layout must
/// be computed from the same numbers.
///
/// ## Drawing tiles
///
/// ``TesseraTileCell`` is reused inside — the same tile as on the grid:
/// backing, icon, title, badge. The cell is configured the same way as on the
/// desktop (the background is not cleared), and its side and columns are the same as the
/// grid's (``TesseraTileLayoutEngine/gridMetrics(contentWidth:columns:spacing:scale:)``
/// with the grid's `itemSpacing`), so a tile in the panel
/// is a real small 1×1 tile matching the tiles below the panel in size
/// and columns. A tap on a tile is reported through ``onTapShortcut`` and does **not**
/// close the folder (D17); VoiceOver activation takes the same path through
/// `TesseraTileCell.onActivate`. A tap on the background or title calls
/// ``onBackgroundTap`` — this is how the grid closes the folder on a repeated tap.
///
/// ## Animation
///
/// The appearance cascade (`playIconCascade`) and fade-out (`animateIconsOut`) are the
/// panel's only animations. The per-index delay is computed by the pure function
/// ``TesseraTileGridView/staggerDelay(index:)``; with Reduce Motion (§9) there is no
/// cascade. The panel does not touch the grid layout: neighbors are shifted by UICollectionView
/// when the cell is inserted/removed.
///
/// The panel height is animated too — but by the layout, not by the cell: on insertion
/// UICollectionView grows the frame from 0 to the full height
/// (``TesseraTileCollectionViewLayout``). The cell lays out its content **once**
/// by width and pins it to the top edge; the height does not take part in the calculation,
/// so during growth the inner layout is not run frame by frame, and
/// the cell only clips the content from below (`clipsToBounds`). Icons are hidden during
/// the growth (``prepareIconCascade()``) and appear in a cascade after it
/// finishes — without jumping from the old layout to the new one.
final class TesseraFolderPanelCell: UICollectionViewCell {

    // MARK: - Metrics

    /// The constants match the panel height formula in `TesseraTileLayoutEngine`.
    ///
    /// The values are taken from the engine rather than duplicated: the panel height and the layout of
    /// its content must be computed from the same numbers, otherwise the last row of
    /// tiles would either be clipped or not fill the panel.
    private enum Metrics {
        static let padding = TesseraTileLayoutEngine.panelPadding
        static let headerHeight = TesseraTileLayoutEngine.panelHeaderHeight
        static let headerSpacing = TesseraTileLayoutEngine.panelHeaderSpacing
        static let cascadeDuration: TimeInterval = 0.18
        static let cascadeOffset: CGFloat = 10
        static let collapseDuration: TimeInterval = 0.12
    }

    // MARK: - State

    /// The panel tile under a point.
    ///
    /// - Parameter point: A point in the panel's `contentView` coordinates.
    /// - Returns: The icon cell and its descriptor, or `nil`.
    func shortcut(at point: CGPoint) -> (cell: TesseraTileCell, tile: TesseraTileDescriptor)? {
        for (index, cell) in shortcutCells.enumerated() where tiles.indices.contains(index) {
            // The frame ignores the cascade transform: it moves the icon by 10 pt.
            let size = cell.bounds.size
            let frame = CGRect(
                x: cell.center.x - size.width / 2,
                y: cell.center.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            if frame.contains(point) {
                return (cell, tiles[index])
            }
        }
        return nil
    }

    /// The folder title (as typed; lowercasing is no longer applied).
    private let titleLabel = UILabel()

    // MARK: - Renaming (D35)

    /// The folder name field: during renaming it takes the title's frame
    /// (the same font and line height), so tiles under the panel do not
    /// shift. Outside renaming it is hidden and does not take part in the layout.
    private let titleField = UITextField()

    /// The field underline: a sign that "the name is being edited" (during editing).
    private let titleUnderline = UIView()

    /// A long press on the title enters renaming (Windows 10 Mobile §6.7).
    private let titleLongPress = UILongPressGestureRecognizer()

    /// The text the title currently shows: the folder name or the default
    /// name if the folder's is empty. It is used to filter out "nothing
    /// changed": the rename handler is not called needlessly.
    private var shownTitle = ""

    /// A tap touch on the panel began during renaming: such a tap
    /// only finishes the name edit, and neither closes the folder nor activates a tile.
    ///
    /// The flag is set in `shouldReceive` (on touch), not on recognition:
    /// the grid may finish editing with its own gesture before the panel's
    /// gesture fires.
    private var tapBeganWhileEditingTitle = false

    /// Whether the folder can be renamed: the grid enables it when it has a
    /// ``TesseraTileGridView/folderRenameHandler``. Without a handler the
    /// title does not react to a long press and has no VoiceOver action.
    var isTitleEditable = false {
        didSet {
            guard isTitleEditable != oldValue else { return }
            updateTitleEditability()
        }
    }

    /// Whether a name edit is in progress right now.
    private(set) var isEditingTitle = false

    /// Edit completion: the final **normalized** title
    /// (``TesseraTileFolder/normalizedTitle(_:)``); an empty string means "restore the default
    /// title". Called only if the title differs from the displayed one.
    var onTitleCommit: ((String) -> Void)?

    /// The start (`true`) and end (`false`) of editing: the grid watches the keyboard and
    /// restores VoiceOver focus. The end arrives before `onTitleCommit`.
    var onTitleEditingChanged: ((Bool) -> Void)?

    /// Whether the grid allows editing to begin now (the panel has settled, the folder is the same).
    var canBeginTitleEditing: (() -> Bool)?

    /// The name field — for VoiceOver focus and tests.
    var titleTextField: UITextField { titleField }

    /// The title — for VoiceOver focus and tests.
    var titleHeaderLabel: UILabel { titleLabel }

    /// The folder tiles in display order.
    private var tiles: [TesseraTileDescriptor] = []

    /// Reusable mini tile cells (the same rendering as on the grid).
    ///
    /// Internal read access: tests check the panel tile's caption and that
    /// activation goes through the grid's common route.
    private(set) var shortcutCells: [TesseraTileCell] = []

    /// The column count of the content grid (by default the same as the grid's — D26).
    private var columnCount = TesseraTileLayoutEngine.defaultColumns

    /// The desktop grid gap (`itemSpacing`): panel tiles
    /// sit in the same columns as the grid tiles.
    private var contentSpacing = TesseraTileLayoutEngine.panelContentSpacing

    /// A tap on the panel background or title (D17): the grid closes the folder.
    ///
    /// An internal channel for `TesseraTileGridView`: the cell does not know about
    /// the grid state, and its own gesture has already filtered out hits on tiles.
    var onBackgroundTap: (() -> Void)?

    /// Activation of a panel tile: the grid routes it into the common
    /// `onTap`/`handleItemTap` route and decides itself whether the action may be activated
    /// (in edit mode it may not).
    ///
    /// The panel does not call ``TesseraTileDescriptor/action`` directly: the action
    /// is run by the host on the tap event (D12), the same path as for a grid tile.
    var onTapShortcut: ((TesseraTileDescriptor) -> Void)?

    private let tapRecognizer = UITapGestureRecognizer()

    // MARK: - Internal layout

    /// A ready internal layout of the panel.
    ///
    /// Depends only on the width, column count, reading direction and the number
    /// of tiles — **but not on the height**. The panel grows from 0 to the final height in a
    /// batch animation, and UICollectionView calls `layoutSubviews` on every growth
    /// frame; computing from the height would shift the content frame by frame. So the layout
    /// is computed once per key and applied once, while the height works
    /// only as clipping (`clipsToBounds`).
    private struct ContentLayout: Equatable {

        /// The panel width the layout was computed for.
        var width: CGFloat

        /// The column count of the content grid.
        var columns: Int

        /// The reading direction: in RTL the columns are mirrored (§9).
        var rightToLeft: Bool

        /// The tile count: the set of frames depends on it.
        var tileCount: Int

        /// The grid gap.
        var spacing: CGFloat

        /// The pixel alignment scale.
        var scale: CGFloat

        /// The title frame.
        var titleFrame: CGRect

        /// The tile frames in order.
        var tileFrames: [CGRect]
    }

    /// The last computed layout (the key is width/columns/RTL/tile set).
    private var contentLayout: ContentLayout?

    /// The layout already applied to the subviews. Frames are not set again:
    /// height growth must not trigger the inner layout.
    private var appliedContentLayout: ContentLayout?

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // D17: the panel background is a system one so that it reads as a "pulled-out"
        // part of the desktop over the wallpaper in any theme.
        backgroundColor = .systemBackground
        contentView.backgroundColor = .clear
        isAccessibilityElement = false

        // On insertion the panel arrives with height 0 and grows to
        // full height in the grid's batch animation, and collapses back on close.
        // The content is pinned to the top (`layoutSubviews` computes frames from the
        // top edge), so clip it to the cell bounds: otherwise at
        // a small height the title and icons would stick out of the panel.
        clipsToBounds = true

        titleLabel.font = TesseraFolderPanelCell.makeTitleFont(compatibleWith: nil)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textAlignment = .natural
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.accessibilityTraits = .header
        contentView.addSubview(titleLabel)

        // The name field and the underline sit above the title and are hidden; a single
        // line, no autocorrection, return is "Done".
        titleField.font = TesseraFolderPanelCell.makeTitleFont(compatibleWith: nil)
        titleField.textColor = .label
        titleField.textAlignment = .natural
        titleField.borderStyle = .none
        titleField.backgroundColor = .clear
        titleField.returnKeyType = .done
        titleField.enablesReturnKeyAutomatically = false
        titleField.autocorrectionType = .no
        titleField.spellCheckingType = .no
        titleField.autocapitalizationType = .words
        titleField.adjustsFontForContentSizeCategory = false
        titleField.accessibilityLabel = TesseraStartScreenStrings.string(.folderNameFieldLabel)
        titleField.delegate = self
        titleField.isHidden = true
        contentView.addSubview(titleField)
        titleUnderline.backgroundColor = .secondaryLabel
        titleUnderline.isUserInteractionEnabled = false
        titleUnderline.isHidden = true
        contentView.addSubview(titleUnderline)

        // A long press on the title (≈0.5 s) is renaming. The gesture is on the
        // title itself; until renaming is enabled it is off and does not interfere with
        // an ordinary tap. A tap on the panel waits for its failure: a hold does not close
        // the folder, while a short touch fires right after release.
        titleLabel.isUserInteractionEnabled = true
        titleLongPress.minimumPressDuration = 0.5
        titleLongPress.delegate = self
        titleLongPress.isEnabled = false
        titleLongPress.addTarget(self, action: #selector(handleTitleLongPress(_:)))
        titleLabel.addGestureRecognizer(titleLongPress)

        // A tap on a tile is the tile's action; the panel stays open. A tap outside
        // tiles (background/title) closes the folder via `onBackgroundTap`.
        // The gesture does not cancel touches: collection cell selection for the panel is disabled anyway
        // (`shouldSelectItemAt`), and scrolling must not break.
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.delegate = self
        tapRecognizer.addTarget(self, action: #selector(handleTap(_:)))
        tapRecognizer.require(toFail: titleLongPress)
        contentView.addGestureRecognizer(tapRecognizer)
    }

    // MARK: - Content

    /// Applies a folder: the title and the grid of its tiles.
    ///
    /// The set is reused: with the same tile count the panel tiles are only
    /// reconfigured, so the panel does not "flicker" on a snapshot update.
    ///
    /// - Parameters:
    ///   - folder: The expanded folder.
    ///   - columns: The column count of the content grid (the desktop column
    ///     count; 6 by default).
    ///   - spacing: The desktop grid gap (`itemSpacing`).
    func configure(
        folder: TesseraTileFolder,
        columns: Int,
        spacing: CGFloat = TesseraTileLayoutEngine.panelContentSpacing
    ) {
        // Reconfiguration (a new snapshot) ends the reorder preview:
        // tiles are bound to slots by index again.
        endReorder()
        columnCount = max(1, columns)
        contentSpacing = spacing
        // The title is shown as typed (like a folder tile's caption);
        // the former lowercasing (D17) was removed. An empty name
        // (a folder from an old store/host) shows the localized default.
        let title = folder.title.isEmpty
            ? TesseraStartScreenStrings.string(.folderScreenDefaultTitle)
            : folder.title
        titleLabel.text = title
        titleLabel.accessibilityLabel = title
        shownTitle = title

        tiles = folder.tiles

        while shortcutCells.count > tiles.count {
            shortcutCells.removeLast().removeFromSuperview()
        }
        while shortcutCells.count < tiles.count {
            let cell = TesseraTileCell(frame: .zero)
            // D17: a tile in the panel is a real small tile, not an "icon with a
            // caption": the backing, badge, icon and title are drawn by the same
            // cell as on the grid, so the background is not cleared.
            contentView.addSubview(cell)
            shortcutCells.append(cell)
        }

        for (index, cell) in shortcutCells.enumerated() {
            let descriptor = tiles[index]
            cell.configure(with: .tile(descriptor), liveTileEngine: nil, isVisible: true)
            // Activation (a finger and VoiceOver) goes through the grid's common route.
            cell.onActivate = { [weak self] in
                self?.onTapShortcut?(descriptor)
            }
            // The cell may have arrived in the middle of a previous cascade. The reset happens without
            // implicit animation: configure is also called inside a batch update.
            withoutImplicitAnimations {
                cell.layer.removeAllAnimations()
                cell.alpha = 1
                cell.transform = .identity
            }
            // Hiding while the drag image flies during a reorder does not survive
            // reconfiguration.
            cell.setSourceHidden(false)
        }

        // The set/columns may have changed — the layout is recomputed once
        // and applied right away, before the height growth animation starts.
        invalidateContentLayout()
        applyContentLayoutIfNeeded()
        setNeedsLayout()
    }

    /// Rebuilds the fonts for the current Dynamic Type category (§9).
    func refreshTypography() {
        titleLabel.font = TesseraFolderPanelCell.makeTitleFont(
            compatibleWith: traitCollection
        )
        titleField.font = titleLabel.font
        shortcutCells.forEach { $0.refreshTypography() }
        // Frames do not depend on the font (the title is a single line of fixed
        // height), so the layout is not reset: a redraw is enough.
        setNeedsLayout()
    }

    // MARK: - Reordering tiles inside the panel (D40)

    /// The index of the tile currently being dragged inside the panel; `nil` means no reorder is in progress.
    private(set) var reorderSourceIndex: Int?

    /// The slot the placeholder currently occupies (an index in folder order).
    private(set) var reorderSlot: Int?

    /// The placeholder at the lifted tile's place: drawn in the slot it will "land" in.
    private var reorderPlaceholder: TesseraTilePlaceholderView?

    /// The animator of the neighbor shift: retained so that the next step
    /// stops the previous move at its current frame.
    private var reorderAnimator: UIViewPropertyAnimator?

    /// Frames of the panel layout slots in `contentView` coordinates.
    ///
    /// A slot is a tile's place in the layout (the grid columns; mirrored in RTL). It does not
    /// depend on the reorder preview.
    var slotFrames: [CGRect] {
        applyContentLayoutIfNeeded()
        return contentLayout?.tileFrames ?? []
    }

    /// Starts a reorder: the tile `sourceIndex` is hidden and a placeholder appears
    /// in its slot. Neighbors are moved by ``setReorderSlot(_:animated:)``.
    ///
    /// - Parameter sourceIndex: The index of the lifted tile in folder order.
    /// - Returns: `false` if the index is out of range or the layout is not ready.
    @discardableResult
    func beginReorder(sourceIndex: Int) -> Bool {
        endReorder()
        let slots = slotFrames
        guard shortcutCells.indices.contains(sourceIndex), slots.count == shortcutCells.count else {
            return false
        }
        reorderSourceIndex = sourceIndex
        reorderSlot = sourceIndex

        shortcutCells[sourceIndex].setSourceHidden(true)
        let placeholder = TesseraTilePlaceholderView(frame: slots[sourceIndex])
        // Under the tiles: shifting neighbors pass over, not under, the placeholder.
        contentView.insertSubview(placeholder, at: 0)
        reorderPlaceholder = placeholder
        return true
    }

    /// Puts the placeholder into the slot `slot` and shifts neighbors to free it.
    ///
    /// The layout is computed **from the base order**, not from the previous preview:
    /// the tile `sourceIndex` is taken out and inserted at `slot`, and the others follow
    /// in sequence through the free slots. The shift is a short batch animation with the
    /// bounce curve (``TesseraTileGridView/bounceTimingParameters()``); with `animated ==
    /// false` (Reduce Motion) it is instant. An out-of-range slot is clamped.
    ///
    /// - Parameters:
    ///   - slot: The index of the target slot in folder order.
    ///   - animated: Whether to animate the shift.
    func setReorderSlot(_ slot: Int, animated: Bool) {
        guard let source = reorderSourceIndex, let placeholder = reorderPlaceholder else { return }
        let slots = slotFrames
        guard slots.count == shortcutCells.count, !slots.isEmpty else { return }
        let target = min(max(slot, 0), slots.count - 1)
        guard target != reorderSlot else { return }
        reorderSlot = target

        var order = Array(shortcutCells.indices)
        order.remove(at: source)
        order.insert(source, at: target)
        var frames: [Int: CGRect] = [:]
        for (displayedSlot, cellIndex) in order.enumerated() where cellIndex != source {
            frames[cellIndex] = slots[displayedSlot]
        }
        let placeholderFrame = slots[target]

        // An unfinished move: freeze the frame the user sees and
        // start from it (otherwise the animation would begin from the end frame of the previous one).
        if reorderAnimator != nil {
            let presented = shortcutCells.map { $0.layer.presentation()?.frame ?? $0.frame }
            let placeholderPresented = placeholder.layer.presentation()?.frame ?? placeholder.frame
            reorderAnimator?.stopAnimation(true)
            reorderAnimator = nil
            withoutImplicitAnimations {
                for (index, cell) in shortcutCells.enumerated() { cell.frame = presented[index] }
                placeholder.frame = placeholderPresented
            }
        }

        let apply = { [weak self] in
            guard let self else { return }
            for (index, frame) in frames { self.shortcutCells[index].frame = frame }
            placeholder.frame = placeholderFrame
        }
        guard animated else {
            withoutImplicitAnimations(apply)
            return
        }
        let animator = UIViewPropertyAnimator(
            duration: TesseraTileGridView.tileMoveDuration,
            timingParameters: TesseraTileGridView.bounceTimingParameters()
        )
        animator.addAnimations(apply)
        animator.addCompletion { [weak self, weak animator] _ in
            guard let self, let animator, self.reorderAnimator === animator else { return }
            self.reorderAnimator = nil
        }
        reorderAnimator = animator
        animator.startAnimation()
    }

    /// Ends the reorder: tiles return to the layout slots, the lifted one
    /// is shown, the placeholder leaves. Without animation — the caller either
    /// applies the new order with a snapshot right away (drop), or restores the previous one
    /// (cancel), and the picture must not flicker.
    func endReorder() {
        reorderAnimator?.stopAnimation(true)
        reorderAnimator = nil
        reorderPlaceholder?.removeFromSuperview()
        reorderPlaceholder = nil
        guard let source = reorderSourceIndex else { return }
        if shortcutCells.indices.contains(source) {
            shortcutCells[source].setSourceHidden(false)
        }
        reorderSourceIndex = nil
        reorderSlot = nil
        let slots = slotFrames
        withoutImplicitAnimations {
            for (index, frame) in slots.enumerated() where shortcutCells.indices.contains(index) {
                shortcutCells[index].frame = frame
            }
        }
    }

    // MARK: - Cascade (D17)

    /// Hides the icons before the panel height grows (D17).
    ///
    /// Called by the grid on panel insertion. If the icons stayed visible
    /// during the growth, the cascade at the end would "re-hide" them and they would jump.
    /// The state is applied without implicit animation: this is frame preparation, not
    /// motion.
    func prepareIconCascade() {
        guard !shortcutCells.isEmpty, !TesseraAccessibility.isReduceMotionEnabled else { return }

        withoutImplicitAnimations {
            for cell in shortcutCells {
                cell.layer.removeAllAnimations()
                cell.alpha = 0
                cell.transform = CGAffineTransform(translationX: 0, y: Metrics.cascadeOffset)
            }
        }
    }

    /// Starts the icon appearance cascade: opacity 0 → 1, shift 10 → 0.
    ///
    /// Called by the grid when the panel height growth finishes. With Reduce Motion
    /// (§9) the icons are visible at once: motion is disabled, the state is settled.
    func playIconCascade() {
        guard !shortcutCells.isEmpty else { return }

        guard !TesseraAccessibility.isReduceMotionEnabled else {
            shortcutCells.forEach {
                $0.alpha = 1
                $0.transform = .identity
            }
            return
        }

        // Set the start state without animation so the cascade does not pick up
        // an unfinished panel motion.
        withoutImplicitAnimations {
            for cell in shortcutCells {
                cell.alpha = 0
                cell.transform = CGAffineTransform(translationX: 0, y: Metrics.cascadeOffset)
            }
        }

        for (index, cell) in shortcutCells.enumerated() {
            UIView.animate(
                withDuration: Metrics.cascadeDuration,
                delay: TesseraTileGridView.staggerDelay(index: index),
                options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
                animations: {
                    cell.alpha = 1
                    cell.transform = .identity
                },
                completion: nil
            )
        }
    }

    /// Fades the icons out before the panel collapses (D17).
    ///
    /// The grid performs the cell removal in `completion`, so the order of the reverse
    /// animation — "icons → height 0 → rows up" — is preserved.
    ///
    /// - Parameter completion: Called when the fade-out finishes (on the main
    ///   thread, synchronously with Reduce Motion).
    func animateIconsOut(completion: @escaping () -> Void) {
        guard !shortcutCells.isEmpty, !TesseraAccessibility.isReduceMotionEnabled else {
            shortcutCells.forEach { $0.alpha = 0 }
            completion()
            return
        }

        UIView.animate(
            withDuration: Metrics.collapseDuration,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState],
            animations: {
                for cell in self.shortcutCells {
                    cell.alpha = 0
                    cell.transform = CGAffineTransform(
                        translationX: 0,
                        y: Metrics.cascadeOffset / 2
                    )
                }
            },
            completion: { _ in completion() }
        )
    }

    // MARK: - Actions

    /// Activation of a tile inside the panel (D17): the folder stays open.
    ///
    /// The action itself is not run: the grid receives the descriptor via
    /// ``onTapShortcut`` and turns the event into the common `onTap` route (the action is
    /// run by the host, D12). In edit mode the grid does not
    /// perform the activation.
    ///
    /// - Parameter index: The tile index in the folder.
    private func activateTile(at index: Int) {
        guard tiles.indices.contains(index) else { return }
        onTapShortcut?(tiles[index])
    }

    /// A tap on the panel: if it hit a tile — run its action; outside tiles —
    /// close the folder (D17, a "repeated tap" on the panel).
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        // A tap that began during name editing (not on the field itself) only
        // finishes editing — it neither closes the folder nor activates a tile.
        if tapBeganWhileEditingTitle {
            tapBeganWhileEditingTitle = false
            endTitleEditing()
            return
        }
        let point = recognizer.location(in: contentView)
        for (index, cell) in shortcutCells.enumerated() where cell.frame.contains(point) {
            activateTile(at: index)
            return
        }
        onBackgroundTap?()
    }

    // MARK: - Renaming (D35)

    /// Enables or disables the long press and the VoiceOver "Rename" action
    /// on the title.
    private func updateTitleEditability() {
        titleLongPress.isEnabled = isTitleEditable
        if isTitleEditable {
            titleLabel.accessibilityCustomActions = [
                UIAccessibilityCustomAction(
                    name: TesseraStartScreenStrings.string(.a11yActionRenameFolder),
                    image: nil
                ) { [weak self] _ in
                    self?.beginTitleEditing() ?? false
                },
            ]
        } else {
            titleLabel.accessibilityCustomActions = nil
            endTitleEditing()
        }
    }

    @objc private func handleTitleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        beginTitleEditing()
    }

    /// Whether a point falls in the title area (a long press on it is neither entry
    /// into editing nor a drag).
    ///
    /// - Parameter point: A point in the panel's `contentView` coordinates.
    func isTitleHit(_ point: CGPoint) -> Bool {
        titleLabel.frame.contains(point)
    }

    /// Starts a name edit: the title turns into a field with the current name,
    /// all text selected (as when renaming in Files).
    ///
    /// - Returns: `true` if editing began (the field became the first responder).
    @discardableResult
    func beginTitleEditing() -> Bool {
        guard isTitleEditable, !isEditingTitle else { return isEditingTitle }
        guard canBeginTitleEditing?() ?? true else { return false }

        applyContentLayoutIfNeeded()
        titleField.text = shownTitle
        withoutImplicitAnimations {
            titleField.isHidden = false
            titleUnderline.isHidden = false
            titleLabel.isHidden = true
        }
        isEditingTitle = true
        guard titleField.becomeFirstResponder() else {
            isEditingTitle = false
            withoutImplicitAnimations {
                titleField.isHidden = true
                titleUnderline.isHidden = true
                titleLabel.isHidden = false
            }
            return false
        }
        titleField.selectedTextRange = titleField.textRange(
            from: titleField.beginningOfDocument,
            to: titleField.endOfDocument
        )
        onTitleEditingChanged?(true)
        return true
    }

    /// Ends a name edit by **committing** (D35): return, a tap outside, closing the
    /// panel, and entering/leaving edit mode all commit what was typed; there is no
    /// cancel. An empty name means "restore the default name".
    ///
    /// Order: the field hides and loses focus, the title shows the result,
    /// `onTitleEditingChanged(false)` (the grid releases the keyboard), and only then
    /// `onTitleCommit` — if the handler synchronously updates the grid snapshot, the panel
    /// is already out of editing.
    ///
    /// - Parameter deferringHandler: Call `onTitleCommit` on the next runloop
    ///   pass (cell reuse inside a collection update).
    func endTitleEditing(deferringHandler: Bool = false) {
        guard isEditingTitle else { return }
        let normalized = TesseraTileFolder.normalizedTitle(titleField.text ?? "")
        isEditingTitle = false
        titleField.resignFirstResponder()
        withoutImplicitAnimations {
            titleField.isHidden = true
            titleUnderline.isHidden = true
            titleLabel.isHidden = false
        }

        let display = normalized.isEmpty
            ? TesseraStartScreenStrings.string(.folderScreenDefaultTitle)
            : normalized
        let changed = display != shownTitle
        if changed {
            shownTitle = display
            titleLabel.text = display
            titleLabel.accessibilityLabel = display
        }

        onTitleEditingChanged?(false)

        guard changed, let handler = onTitleCommit else { return }
        if deferringHandler {
            DispatchQueue.main.async { handler(normalized) }
        } else {
            handler(normalized)
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // The panel height does not take part in the calculation: the content is pinned to the top
        // edge and computed by width. During height growth this method is called
        // every frame, but the layout is already applied — frames are neither recomputed nor
        // reassigned, so the content does not jitter.
        applyContentLayoutIfNeeded()
    }

    /// Applies the inner layout if it has not been applied yet.
    ///
    /// The key is the width, column count, reading direction and tile count.
    /// The height is intentionally not in the key: it changes on every frame of the growth
    /// animation, and the content does not depend on it.
    private func applyContentLayoutIfNeeded() {
        let width = contentView.bounds.width
        guard width.isFinite, width > 0 else { return }

        let layout: ContentLayout
        if let cached = contentLayout,
           cached.width == width,
           cached.columns == max(1, columnCount),
           cached.rightToLeft == isRightToLeft,
           cached.tileCount == shortcutCells.count,
           cached.spacing == contentSpacing,
           cached.scale == displayScale {
            layout = cached
        } else if let computed = makeContentLayout(width: width) {
            contentLayout = computed
            layout = computed
        } else {
            return
        }

        guard layout != appliedContentLayout else { return }

        // During a batch update UICollectionView turns on an animation
        // context: setting a subview frame normally would animate it from zero,
        // and the icons would "jump" on the first frame of the panel growth. Implicit
        // animations are disabled — this is frame preparation, not motion.
        withoutImplicitAnimations {
            titleLabel.frame = layout.titleFrame
            titleField.frame = layout.titleFrame
            titleUnderline.frame = CGRect(
                x: layout.titleFrame.minX,
                y: layout.titleFrame.maxY - 2,
                width: layout.titleFrame.width,
                height: 1
            )
            for (index, cell) in shortcutCells.enumerated()
            where layout.tileFrames.indices.contains(index) {
                cell.frame = layout.tileFrames[index]
            }
            // Child cells get frames immediately and lay out inside once
            // while layer actions are disabled: otherwise their icons/captions would also
            // arrive from a zero frame.
            for cell in shortcutCells {
                cell.layoutIfNeeded()
            }
        }

        appliedContentLayout = layout
    }

    /// Computes the inner layout from the panel width.
    ///
    /// The tile side and columns are the grid geometry
    /// (``TesseraTileLayoutEngine/gridMetrics(contentWidth:columns:spacing:scale:)``):
    /// a unit over the full panel width (equal to the grid content width) and the
    /// grid gap `itemSpacing`, on the pixel grid, with the remainder split evenly between the insets.
    /// So tiles sit in the same columns as the tiles below the
    /// panel. The `Metrics.padding` insets apply vertically and to the title.
    ///
    /// The height is not part of the calculation: the content is pinned to the top edge, and panel
    /// growth only clips it from below.
    ///
    /// - Parameter width: The current panel width (the full grid content width).
    /// - Returns: The layout, or `nil` for a degenerate width.
    private func makeContentLayout(width: CGFloat) -> ContentLayout? {
        let padding = Metrics.padding
        let innerWidth = max(0, width - padding * 2)
        let columns = max(1, columnCount)
        let scale = displayScale
        // The same geometry as the grid's (the unit and gap on the pixel
        // grid, the remaining width split evenly between the insets), so tile columns
        // match the columns of the tiles to the pixel.
        guard let metrics = TesseraTileLayoutEngine.gridMetrics(
            contentWidth: width,
            columns: columns,
            spacing: contentSpacing,
            scale: scale
        ) else {
            return nil
        }
        let side = metrics.unit
        let spacing = metrics.spacing

        let titleFrame = CGRect(
            x: padding,
            y: padding,
            width: innerWidth,
            height: Metrics.headerHeight
        )
        let originY = padding + Metrics.headerHeight + Metrics.headerSpacing
        let rightToLeft = isRightToLeft

        var tileFrames: [CGRect] = []
        tileFrames.reserveCapacity(shortcutCells.count)
        for index in shortcutCells.indices {
            let row = index / columns
            let logicalColumn = index % columns
            // RTL: the first tile is in the top right corner of the panel grid.
            let column = rightToLeft ? columns - 1 - logicalColumn : logicalColumn
            tileFrames.append(
                CGRect(
                    x: metrics.columnOffset(column),
                    y: originY + CGFloat(row) * (side + spacing),
                    width: side,
                    height: side
                )
            )
        }

        return ContentLayout(
            width: width,
            columns: columns,
            rightToLeft: rightToLeft,
            tileCount: shortcutCells.count,
            spacing: contentSpacing,
            scale: scale,
            titleFrame: titleFrame,
            tileFrames: tileFrames
        )
    }

    /// Resets the layout cache: the set, columns or direction changed.
    private func invalidateContentLayout() {
        contentLayout = nil
        appliedContentLayout = nil
    }

    /// The pixel alignment scale — the same rule as the layout of the
    /// grid.
    private var displayScale: CGFloat {
        TesseraTileCollectionViewLayout.resolvedDisplayScale(traitCollection.displayScale)
    }

    /// The panel's reading direction (§9, RTL).
    private var isRightToLeft: Bool {
        effectiveUserInterfaceLayoutDirection == .rightToLeft
    }

    /// Runs changes without implicit layer animations.
    ///
    /// The panel's `layoutSubviews` is also called inside a UICollectionView
    /// batch update, where an animation context is on: without disabling
    /// actions, setting subview frames would turn into a "from zero" animation and
    /// the panel content would move during the growth of its height.
    ///
    /// - Parameter changes: Changes that must not be animated.
    private func withoutImplicitAnimations(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    /// RTL: the reading direction changes the column order in the panel grid.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if previousTraitCollection?.layoutDirection != traitCollection.layoutDirection {
            invalidateContentLayout()
            setNeedsLayout()
        }
        // Dynamic Type: the panel may have been off-screen when the
        // category changed — update the font from its own trait, without waiting for the grid.
        if previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory {
            refreshTypography()
        }
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()

        // A reorder inside the panel does not survive reuse.
        endReorder()
        // The panel may have been removed in the middle of a cascade: the next folder must not
        // inherit invisible or shifted icons.
        withoutImplicitAnimations {
            for cell in shortcutCells {
                cell.layer.removeAllAnimations()
                cell.alpha = 1
                cell.transform = .identity
            }
        }
        // The panel went into reuse in the middle of a name edit — editing
        // ends with a commit (D35), and the handler is called on the next runloop
        // pass: reuse happens inside a collection update.
        endTitleEditing(deferringHandler: true)
        isTitleEditable = false
        onTitleCommit = nil
        onTitleEditingChanged = nil
        canBeginTitleEditing = nil
        tapBeganWhileEditingTitle = false
        shownTitle = ""
        titleField.text = nil
        tiles = []
        titleLabel.text = nil
        titleLabel.accessibilityLabel = nil
        onBackgroundTap = nil
        onTapShortcut = nil
        invalidateContentLayout()
    }

    // MARK: - Font

    /// The title font: scaled by Dynamic Type, but capped — the title line
    /// in the panel formula has a fixed height (44 pt).
    ///
    /// The cap is bounded by two conditions: the design intent (no larger than
    /// 28 pt for the lowercase Windows Phone title) and the title line height
    /// (`panelHeaderHeight`): a font taller than that would be clipped in its own frame
    /// at Dynamic Type accessibility sizes.
    ///
    /// - Parameter traitCollection: The panel's trait collection, from which the text size
    ///   category is taken; `nil` means the current system one. The explicit parameter
    ///   lets a test check scaling and the cap deterministically.
    /// - Returns: The scaled title font.
    static func makeTitleFont(compatibleWith traitCollection: UITraitCollection?) -> UIFont {
        let base = UIFont.systemFont(ofSize: 16, weight: .semibold)
        // 1.25 is a margin on the lineHeight/pointSize ratio of the system font:
        // even in the worst case the line fits in the title height.
        let heightLimit = floor(TesseraTileLayoutEngine.panelHeaderHeight / 1.25)
        let maximumPointSize = min(28, heightLimit)
        return UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: base,
            maximumPointSize: maximumPointSize,
            compatibleWith: traitCollection
        )
    }
}

// MARK: - Name field and panel gestures

extension TesseraFolderPanelCell: UITextFieldDelegate, UIGestureRecognizerDelegate {

    /// Return ("Done") commits the name.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        endTitleEditing()
        return false
    }

    /// The field lost focus not through our button (a responder change, leaving the window):
    /// editing also ends with a commit.
    func textFieldDidEndEditing(_ textField: UITextField) {
        endTitleEditing()
    }

    /// The length limit (``TesseraTileFolder/maximumTitleLength``): an edit after which
    /// the string would exceed the limit is not applied (deletion and replacement
    /// shorter than the limit go through).
    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        let current = textField.text ?? ""
        guard let swiftRange = Range(range, in: current) else { return false }
        let result = current.replacingCharacters(in: swiftRange, with: string)
        return result.count <= TesseraTileFolder.maximumTitleLength
    }

    /// The panel gestures decide per touch.
    ///
    /// A long press on the title works only outside editing. A tap on the panel does not
    /// accept touches on the field itself (the caret and selection live there), and a touch
    /// outside the field during editing is remembered as "finishing the edit".
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === titleLongPress {
            return isTitleEditable && !isEditingTitle
        }
        if gestureRecognizer === tapRecognizer {
            if isEditingTitle {
                if let view = touch.view, view.isDescendant(of: titleField) { return false }
                tapBeganWhileEditingTitle = true
            } else {
                tapBeganWhileEditingTitle = false
            }
        }
        return true
    }
}

// MARK: - Closed folder preview (D17)

/// The idle flip schedule of the folder preview (D17).
///
/// A closed folder flips its mini-icons neither simultaneously nor on a shared
/// timer: the phase depends on the folder identifier, so neighboring folders do not
/// "blink" in unison. The computation is a pure function of the seed: the same
/// identifier and cycle number give the same delays, which can be verified
/// without timers.
///
/// The seed is a stable FNV-1a over the string description of the identifier:
/// `hashValue` in Swift is randomized between launches, while the phase must stay
/// reproducible and predictable in tests.
struct TesseraFolderFlipSchedule {

    /// The minimum interval between flip cycles, in seconds (D17: 4–6 s).
    static let minimumInterval: TimeInterval = 4

    /// The maximum interval between flip cycles, in seconds.
    static let maximumInterval: TimeInterval = 6

    /// The minimum delay of the first cycle after the folder appears on screen:
    /// the flip must not coincide with the grid appearing.
    static let minimumInitialDelay: TimeInterval = 0.8

    /// The maximum spread of the mini-icon start within a single cycle, in seconds.
    static let maximumStagger: TimeInterval = 0.35

    /// How long a mini-icon holds the badge counter before returning to the icon, in seconds.
    static let dwellDuration: TimeInterval = 2.6

    /// The schedule seed.
    let seed: UInt64

    /// Creates a schedule from an explicit seed (tests, reuse).
    ///
    /// - Parameter seed: The seed of phases and intervals.
    init(seed: UInt64) {
        self.seed = seed
    }

    /// Creates a schedule for a folder: the phase deterministically depends on `id`.
    ///
    /// - Parameter folderID: The folder identifier on the desktop.
    init(folderID: AnyHashable) {
        self.init(seed: TesseraFolderFlipSchedule.seed(for: folderID))
    }

    /// A stable seed from the folder identifier (FNV-1a over `String(describing:)`).
    ///
    /// - Parameter folderID: The folder identifier.
    /// - Returns: A seed that is the same within and between launches.
    static func seed(for folderID: AnyHashable) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in String(describing: folderID).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash &+ 0xE7_0002_0000_0001
    }

    /// The delay before the first cycle after the folder appears on screen.
    ///
    /// - Returns: A value in the range
    ///   `minimumInitialDelay...maximumInterval`.
    func initialDelay() -> TimeInterval {
        let fraction = TesseraFolderFlipSchedule.fraction(seed: seed, salt: 0x1)
        let span = TesseraFolderFlipSchedule.maximumInterval
            - TesseraFolderFlipSchedule.minimumInitialDelay
        return TesseraFolderFlipSchedule.minimumInitialDelay + fraction * span
    }

    /// The interval before the next cycle.
    ///
    /// - Parameter cycle: The cycle number, starting from 1.
    /// - Returns: A value in the range `minimumInterval...maximumInterval`.
    func interval(cycle: Int) -> TimeInterval {
        let salt = UInt64(bitPattern: Int64(cycle)) &* 0x9E37_79B9_7F4A_7C15 &+ 0x2
        let fraction = TesseraFolderFlipSchedule.fraction(seed: seed, salt: salt)
        let span = TesseraFolderFlipSchedule.maximumInterval
            - TesseraFolderFlipSchedule.minimumInterval
        return TesseraFolderFlipSchedule.minimumInterval + fraction * span
    }

    /// The start delay of a mini-icon within a cycle.
    ///
    /// - Parameter miniIndex: The mini-tile index (0...3).
    /// - Returns: A value in the range `0...maximumStagger`.
    func stagger(miniIndex: Int) -> TimeInterval {
        let salt = UInt64(bitPattern: Int64(miniIndex)) &* 0xBF58_476D_1CE4_E5B9 &+ 0x3
        let fraction = TesseraFolderFlipSchedule.fraction(seed: seed, salt: salt)
        return fraction * TesseraFolderFlipSchedule.maximumStagger
    }

    /// A uniform fraction in `[0, 1)` from the seed and a salt.
    private static func fraction(seed: UInt64, salt: UInt64) -> Double {
        var generator = TesseraSeededGenerator(seed: seed &+ salt)
        // The top 53 bits — a uniform fraction without loss of precision.
        return Double(generator.next() >> 11) / 9_007_199_254_740_992.0
    }
}

/// The closed folder preview: a mini-grid of "up to four" icons and an idle flip of counters
/// (D17).
///
/// ## Why custom mechanics instead of ``TesseraLiveTileEngine``
///
/// The engine and ``TesseraLiveTileView`` are tailored to a full-size tile:
/// the engine's registration accepts a concrete ``TesseraLiveTileView`` (not
/// a protocol), and the container flips two faces around the **Y** axis and
/// lays out the face title/caption. A folder needs four independent
/// mini-tiles, a flip around the **X** axis and no text, so
/// the pair cannot be reused directly, and changing the engine's contract is
/// out of scope here.
///
/// The container follows the engine's principles: a timer in `.common`, a pause off-screen,
/// in the background and with Reduce Motion, only `layer.transform`/`isHidden` in the
/// hot path, a seedable schedule and a reset to the settled state on
/// reuse. The badge is the shared ``TesseraLiveTileBadgeView``.
///
/// ## Threading
///
/// Main thread only: the timer, notifications and deferred returns run
/// on the main queue.
final class TesseraFolderPreviewView: UIView {

    // MARK: - Metrics

    private enum Metrics {
        /// The gap between mini-tiles as a fraction of the block side: small but noticeable.
        static let spacingRatio: CGFloat = 0.05
        static let minimumSpacing: CGFloat = 2
    }

    // MARK: - State

    /// The mini-tiles in tile order (at most four).
    private(set) var miniTileViews: [TesseraFolderMiniTileView] = []

    /// The flip schedule; set in ``configure(tiles:schedule:)``.
    private(set) var schedule = TesseraFolderFlipSchedule(seed: 0)

    /// The content signature (id + badge): it catches a real change of the
    /// folder so the phase is not reset on every snapshot update.
    private var signature: [String] = []

    private var isVisible = false
    private var isExpanded = false
    private var isApplicationActive = UIApplication.shared.applicationState != .background

    /// Whether the schedule has started: the first start uses ``initialDelay()``,
    /// later ones use the cycle interval.
    private var hasStarted = false
    private var cycleIndex = 0

    private var cycleTimer: Timer?
    private var staggerWorkItems: [DispatchWorkItem] = []
    private var returnWorkItem: DispatchWorkItem?

    /// The schedule generation: deferred flips of a previous generation are ignored.
    private var generation: UInt64 = 0

    private var reduceMotionObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        cycleTimer?.invalidate()
        staggerWorkItems.forEach { $0.cancel() }
        returnWorkItem?.cancel()

        let center = NotificationCenter.default
        for observer in [reduceMotionObserver, backgroundObserver, foregroundObserver] {
            if let observer {
                center.removeObserver(observer)
            }
        }
    }

    private func commonInit() {
        // The preview is decoration: the folder stays a single accessibility element
        // of the cell (§9), and it needs no touches either.
        isAccessibilityElement = false
        isUserInteractionEnabled = false
        backgroundColor = .clear

        installObservers()
    }

    // MARK: - Configuration

    /// Applies the folder's first tiles and the flip schedule.
    ///
    /// Configuration is idempotent: if the set and badges did not change (for example,
    /// the grid updated the snapshot because of a resize), the phase and timer are not reset.
    /// A real change returns all mini-tiles to icons and restarts
    /// the schedule.
    ///
    /// - Parameters:
    ///   - tiles: The folder's tiles; the first four are taken.
    ///   - schedule: The flip schedule (phase by the folder identifier).
    func configure(tiles: [TesseraTileDescriptor], schedule: TesseraFolderFlipSchedule) {
        let limitedTiles = Array(tiles.prefix(4))
        let newSignature = limitedTiles.map { tile -> String in
            // Icon identity via ObjectIdentifier: swapping the image
            // of the same tile must redraw the mini-tile.
            let iconIdentity = tile.icon.map { String(describing: ObjectIdentifier($0)) } ?? "-"
            return "\(String(describing: tile.id))#\(String(describing: tile.badge))#\(iconIdentity)"
        }

        self.schedule = schedule
        guard newSignature != signature else { return }
        signature = newSignature

        stopAnimation()
        cycleIndex = 0

        while miniTileViews.count > limitedTiles.count {
            miniTileViews.removeLast().removeFromSuperview()
        }
        while miniTileViews.count < limitedTiles.count {
            let miniTile = TesseraFolderMiniTileView(frame: .zero)
            addSubview(miniTile)
            miniTileViews.append(miniTile)
        }
        for (miniTile, tile) in zip(miniTileViews, limitedTiles) {
            miniTile.configure(icon: tile.icon, badge: tile.badge)
        }

        setNeedsLayout()
        updateScheduling()
    }

    // MARK: - Lifecycle and pauses

    /// Reports whether the folder is visible on screen (§4, "Pauses").
    ///
    /// Called on every cell display/removal and when hidden during a drag.
    ///
    /// - Parameter visible: Whether the cell is visible.
    func setVisible(_ visible: Bool) {
        isVisible = visible
        updateScheduling()
    }

    /// Pauses the preview while the folder is expanded.
    ///
    /// - Parameter expanded: Whether the folder is expanded.
    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        updateScheduling()
    }

    /// Fully stops the flip and returns the icons.
    ///
    /// Used when the cell is reused: another folder must not
    /// inherit the phase and the counter.
    func stop() {
        isVisible = false
        isExpanded = false
        cycleIndex = 0
        stopAnimation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateScheduling()
    }

    /// RTL: the reading direction changes the order of mini-tiles in the block.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if previousTraitCollection?.layoutDirection != traitCollection.layoutDirection {
            setNeedsLayout()
        }
    }

    // MARK: - Schedule

    /// Whether the idle flip may run now.
    ///
    /// The conditions are the same as for ``TesseraLiveTileEngine`` (§4): the tile is visible, not
    /// hidden and in a window, the app is active, Reduce Motion is off, and at least one
    /// mini-tile has a visible badge. Tiles without a badge do not
    /// flip — they keep the icon (D17).
    private var isAnimationAllowed: Bool {
        isVisible
            && !isExpanded
            && !isHidden
            && window != nil
            && isApplicationActive
            && !TesseraAccessibility.isReduceMotionEnabled
            && miniTileViews.contains { $0.hasVisibleBadge }
    }

    /// Restarts or stops the schedule for the current state.
    private func updateScheduling() {
        guard isAnimationAllowed else {
            stopAnimation()
            return
        }

        guard cycleTimer == nil else { return }

        let delay = hasStarted ? schedule.interval(cycle: cycleIndex) : schedule.initialDelay()
        hasStarted = true
        scheduleCycle(after: delay)
    }

    private func scheduleCycle(after delay: TimeInterval) {
        cycleTimer?.invalidate()

        let timer = Timer(timeInterval: max(0.1, delay), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.cycleTimer = nil
            self.runCycle()
        }
        cycleTimer = timer
        // `.common` — the timer keeps running during collection scroll
        // tracking, otherwise the preview "freezes" under the finger (as in the engine).
        RunLoop.main.add(timer, forMode: .common)
    }

    private func runCycle() {
        guard isAnimationAllowed else {
            updateScheduling()
            return
        }

        cycleIndex += 1
        generation &+= 1
        let currentGeneration = generation

        staggerWorkItems.forEach { $0.cancel() }
        staggerWorkItems.removeAll()
        returnWorkItem?.cancel()
        returnWorkItem = nil

        var maximumStagger: TimeInterval = 0
        for (index, miniTile) in miniTileViews.enumerated() where miniTile.hasVisibleBadge {
            let delay = schedule.stagger(miniIndex: index)
            maximumStagger = max(maximumStagger, delay)

            let workItem = DispatchWorkItem { [weak self, weak miniTile] in
                guard let self,
                      let miniTile,
                      self.generation == currentGeneration,
                      self.isAnimationAllowed else { return }
                miniTile.showBadge(animated: true)
            }
            staggerWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        let returnDelay = maximumStagger
            + TesseraFolderMiniTileView.flipDuration
            + TesseraFolderFlipSchedule.dwellDuration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.generation == currentGeneration, self.isAnimationAllowed else {
                return
            }
            self.miniTileViews.forEach { $0.showIcon(animated: true) }
        }
        returnWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + returnDelay, execute: workItem)

        // The next cycle starts from the start of the current one: the period does not depend on
        // the duration of the return (D17: 4–6 s), and the return is guaranteed to be earlier.
        scheduleCycle(after: schedule.interval(cycle: cycleIndex))
    }

    /// Resets timers and deferred flips, returning the mini-tiles to icons.
    private func stopAnimation() {
        generation &+= 1
        cycleTimer?.invalidate()
        cycleTimer = nil
        staggerWorkItems.forEach { $0.cancel() }
        staggerWorkItems.removeAll()
        returnWorkItem?.cancel()
        returnWorkItem = nil
        hasStarted = false
        miniTileViews.forEach { $0.settleOnIcon() }
    }

    // MARK: - Observers

    private func installObservers() {
        let center = NotificationCenter.default

        reduceMotionObserver = center.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateScheduling()
        }

        backgroundObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isApplicationActive = false
            self?.updateScheduling()
        }

        foregroundObserver = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isApplicationActive = true
            self?.updateScheduling()
        }
    }

    // MARK: - Layout

    /// Lays out the 2×2 mini-grid from the top corner by reading direction.
    ///
    /// The block is no longer centered: the preview starts at the same point as the
    /// desktop tiles (top left in LTR, top right in RTL),
    /// so a closed folder reads like a miniature of the real grid, not like a
    /// "picture in the center". In RTL the block itself is mirrored by columns —
    /// the first tile stays first in reading order. If there are fewer than
    /// four tiles, the block is pinned to the same top corner, not to the center.
    override func layoutSubviews() {
        super.layoutSubviews()

        guard bounds.width > 0, bounds.height > 0, !miniTileViews.isEmpty else { return }

        let side = min(bounds.width, bounds.height)
        let spacing = max(Metrics.minimumSpacing, side * Metrics.spacingRatio)
        let miniSide = max(0, (side - spacing) / 2)
        guard miniSide > 0 else {
            miniTileViews.forEach { $0.frame = .zero }
            return
        }

        let columns = min(2, miniTileViews.count)
        let contentWidth = CGFloat(columns) * miniSide + CGFloat(columns - 1) * spacing
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        // The top corner by reading direction: left in LTR, right in RTL.
        let originX = isRightToLeft ? bounds.width - contentWidth : 0
        let originY: CGFloat = 0

        for (index, miniTile) in miniTileViews.enumerated() {
            let row = index / 2
            let logicalColumn = index % 2
            // RTL: the first tile is in the top right corner of the block.
            let column = isRightToLeft ? columns - 1 - logicalColumn : logicalColumn
            miniTile.frame = CGRect(
                x: originX + CGFloat(column) * (miniSide + spacing),
                y: originY + CGFloat(row) * (miniSide + spacing),
                width: miniSide,
                height: miniSide
            )
        }
    }
}

/// A single folder preview mini-tile: a tile's icon and its badge on the back side
/// (D17).
///
/// The flip is around the **X** axis (for a full-size tile it is around Y): in a closed folder
/// the mini-icons "tip over" downward, like Windows Phone cells. Two phases of half
/// ``flipDuration`` each: the outgoing face turns to the edge (+90°, `m34` perspective),
/// the swap, then the incoming face turns the rest of the way (−90° → 0°). Only
/// `layer.transform` and `isHidden` change; `frame`/`bounds` are not touched — the
/// discipline of §4 and RISKS.md R10.
final class TesseraFolderMiniTileView: UIView {

    /// The duration of a full flip around the X axis, in seconds.
    static let flipDuration: TimeInterval = 0.32

    private enum AnimationKey {
        static let outgoing = "tessera.folderMini.flip.outgoing"
        static let incoming = "tessera.folderMini.flip.incoming"
    }

    /// The distance to the perspective vanishing point. Smaller than for a full-size tile
    /// (500): on a small square strong perspective "turns the face inside out".
    private static let perspectiveDistance: CGFloat = 320

    private let frontView = UIView()
    private let backView = UIView()
    private let iconView = UIImageView()
    private let badgeView = TesseraLiveTileBadgeView()

    private(set) var badge: TesseraTileBadge = .none

    /// Whether the back side with the counter is currently shown.
    private(set) var showsBadgeSide = false

    private var flipGeneration: UInt64 = 0

    /// Whether there is anything to show on the back side.
    var hasVisibleBadge: Bool { badge.isVisible }

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // The mini-tile is decoration inside the folder's single accessibility element.
        isAccessibilityElement = false
        isUserInteractionEnabled = false
        backgroundColor = .clear

        frontView.isAccessibilityElement = false
        backView.isAccessibilityElement = false
        backView.backgroundColor = .tertiarySystemFill
        backView.clipsToBounds = true

        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false
        iconView.clipsToBounds = true
        frontView.addSubview(iconView)

        badgeView.isHidden = true
        backView.addSubview(badgeView)
        badgeView.onBadgeChange = { [weak self] in
            self?.setNeedsLayout()
        }

        backView.isHidden = true
        addSubview(frontView)
        addSubview(backView)
    }

    // MARK: - Content

    /// Applies a tile's icon and badge; always returns the tile to the icon.
    ///
    /// - Parameters:
    ///   - icon: The tile icon; `nil` means a neutral placeholder glyph.
    ///   - badge: The tile badge (a dot or a counter).
    func configure(icon: UIImage?, badge: TesseraTileBadge) {
        self.badge = badge

        if let icon {
            iconView.image = icon
            iconView.tintColor = nil
        } else {
            // A tile without an icon: the place in the mini-grid must not stay empty.
            iconView.image = UIImage(systemName: "app.fill")
            iconView.tintColor = .secondaryLabel
        }

        badgeView.badge = badge
        settleOnIcon()
        setNeedsLayout()
    }

    /// Returns the tile to the icon without animation (the settled state).
    func settleOnIcon() {
        flipGeneration &+= 1
        showsBadgeSide = false
        frontView.layer.removeAllAnimations()
        backView.layer.removeAllAnimations()
        frontView.layer.transform = CATransform3DIdentity
        backView.layer.transform = CATransform3DIdentity
        frontView.isHidden = false
        backView.isHidden = true
        badgeView.isHidden = true
    }

    /// Flips the mini-tile to the badge counter.
    ///
    /// - Parameter animated: `false` means an instant swap (Reduce Motion).
    func showBadge(animated: Bool) {
        transition(toBadgeSide: true, animated: animated)
    }

    /// Flips the mini-tile back to the icon.
    ///
    /// - Parameter animated: `false` means an instant swap.
    func showIcon(animated: Bool) {
        transition(toBadgeSide: false, animated: animated)
    }

    // MARK: - Flip

    private func transition(toBadgeSide: Bool, animated: Bool) {
        guard toBadgeSide != showsBadgeSide else { return }
        guard !toBadgeSide || hasVisibleBadge else { return }

        guard animated, Self.flipDuration > 0 else {
            settleOn(toBadgeSide: toBadgeSide)
            return
        }

        flipGeneration &+= 1
        let currentGeneration = flipGeneration

        let outgoing = toBadgeSide ? frontView : backView
        let incoming = toBadgeSide ? backView : frontView
        incoming.isHidden = true

        let halfDuration = max(0.04, Self.flipDuration / 2)
        let halfOut = Self.perspectiveRotation(by: .pi / 2)
        let halfIn = Self.perspectiveRotation(by: -.pi / 2)

        let outgoingAnimation = CABasicAnimation(keyPath: "transform")
        outgoingAnimation.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        outgoingAnimation.toValue = NSValue(caTransform3D: halfOut)
        outgoingAnimation.duration = halfDuration
        outgoingAnimation.timingFunction = CAMediaTimingFunction(name: .easeIn)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.flipGeneration == currentGeneration else { return }
            self.beginIncomingFlip(
                incoming: incoming,
                outgoing: outgoing,
                toBadgeSide: toBadgeSide,
                initialTransform: halfIn,
                duration: halfDuration,
                generation: currentGeneration
            )
        }
        outgoing.layer.add(outgoingAnimation, forKey: AnimationKey.outgoing)
        outgoing.layer.transform = halfOut
        CATransaction.commit()
    }

    private func beginIncomingFlip(
        incoming: UIView,
        outgoing: UIView,
        toBadgeSide: Bool,
        initialTransform: CATransform3D,
        duration: TimeInterval,
        generation: UInt64
    ) {
        // The moment of the swap: both faces are turned edge-on, so the visibility
        // change is not noticeable. The layout does not change — only hidden/transform.
        outgoing.isHidden = true
        outgoing.layer.transform = CATransform3DIdentity
        incoming.isHidden = false
        incoming.layer.transform = initialTransform
        // The badge is part of the back side: it appears and hides at the moment of
        // the swap so it does not "hang" on the turning face.
        badgeView.isHidden = !toBadgeSide

        let incomingAnimation = CABasicAnimation(keyPath: "transform")
        incomingAnimation.fromValue = NSValue(caTransform3D: initialTransform)
        incomingAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        incomingAnimation.duration = duration
        incomingAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.flipGeneration == generation else { return }
            self.settleOn(toBadgeSide: toBadgeSide)
        }
        incoming.layer.add(incomingAnimation, forKey: AnimationKey.incoming)
        incoming.layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// Brings the faces to the target face (instantly).
    private func settleOn(toBadgeSide: Bool) {
        showsBadgeSide = toBadgeSide
        frontView.layer.removeAllAnimations()
        backView.layer.removeAllAnimations()
        frontView.layer.transform = CATransform3DIdentity
        backView.layer.transform = CATransform3DIdentity
        frontView.isHidden = toBadgeSide
        backView.isHidden = !toBadgeSide
        badgeView.isHidden = !toBadgeSide
    }

    /// A `CATransform3D` rotation around the X axis with perspective (D17).
    ///
    /// `m34` is the perspective term of the matrix: without it the flip looks like flat
    /// scaling.
    private static func perspectiveRotation(by angle: CGFloat) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / perspectiveDistance
        return CATransform3DRotate(transform, angle, 1, 0, 0)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }

        frontView.frame = bounds
        backView.frame = bounds
        // Rounding like an app icon: the mini-tile reads as a tile.
        backView.layer.cornerRadius = side * 0.22

        let inset = side * 0.1
        iconView.frame = bounds.insetBy(dx: inset, dy: inset)

        let badgeSize = badgeView.intrinsicContentSize
        badgeView.frame = CGRect(
            x: (bounds.width - badgeSize.width) / 2,
            y: (bounds.height - badgeSize.height) / 2,
            width: badgeSize.width,
            height: badgeSize.height
        )
    }
}

// MARK: - Drag placeholder

/// A placeholder view for a tile while it is being dragged.
///
/// Handed to the edit coordinator through
/// `TesseraTileGridView.placeholderView(forItemID:)`. It does not add itself to the
/// hierarchy: the place, layer and lifetime are decided by the coordinator. It does not catch
/// touches and is hidden from VoiceOver — it is decoration, not a grid item.
final class TesseraTilePlaceholderView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = UIColor.label.withAlphaComponent(0.08)
        layer.borderWidth = 1
        layer.cornerRadius = 0
        updateBorderColor()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateBorderColor()
    }

    /// CGColor does not adapt automatically to a theme change — update it manually.
    private func updateBorderColor() {
        layer.borderColor = UIColor.label.withAlphaComponent(0.24).cgColor
    }
}

#endif
