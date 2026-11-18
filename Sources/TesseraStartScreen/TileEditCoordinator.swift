//
//  TileEditCoordinator.swift
//  TesseraStartScreen
//
//  Start screen edit-mode coordinator: jiggle, unpin, resize,
//  a custom drag and folder operations through the host approval function.
//
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md
//  - §5 "Edit mode": long press → jiggle (a soft sinusoidal
//    `CAKeyframeAnimation` rotation of ±1.2° over 0.4 s with a random phase), unpin
//    with a fly-out, dimming of all tiles except the selected one, resize through the cycle
//    small → wide → medium → large in place (D28; growth pushes
//    neighbors down),
//    a custom drag coordinator (snapshot + placeholder + preview on cells without
//    writing to the model + layout invalidation) instead of native `UICollectionView` interactive movement;
//  - §3 "Tile grid": cells and push-down are computed by `TesseraTileLayoutEngine`; the animation
//    of neighbors shifting is `TesseraTileGridView.update(snapshot:animated:)` through
//    batch updates;
//  - §9 "Accessibility": in edit mode a tile gets custom actions
//    resize/unpin, the mode change is announced; Reduce Motion disables the jiggle,
//    fly-out, the dimming animation and parallax-like effects, keeping the unpin
//    buttons, the dimming itself and the highlight;
//  - §14 "MVP clarifications": D12 (a tile is just an action), D14 (folders only
//    through the `TesseraTileStore.approval` function), D15 (four sizes).
//
//  "Single writer" rule (§6): only `TesseraTileStore` changes the model; the coordinator
//  stores neither order nor sizes, it reads a snapshot and calls store operations.
//  The grid never reaches into the store itself: after each mutation the coordinator applies
//  the new snapshot through `update(snapshot:animated:)`, but only if the host has not
//  done so already from its own `TesseraTileStore.onChange` (comparing snapshots is cheap).
//
//  The coordinator works entirely on cells (D30–D33). The drag target is the cell
//  under the finger in the base layout (`HoverTarget.cell`/`.newRow`; the center of
//  a tile/folder means merge); the preview shows the same elements on other cells
//  (`TesseraTileLayoutEngine.inserting` applied to the base placements, the cell table in the grid
//  snapshot); on merge and with no target the preview is the base layout. The drop is committed by `TesseraTileStore`
//  operations by cell followed by `collapseEmptyRows`; the edit buttons and the public
//  methods use the same operations. There is no index-based API (D33): the delegate
//  receives a cell, not an index. See STARTSCREEN-IOS-DESIGN,
//  section "Implementation notes and deviations", for details.
//
//  The model is NOT changed during a drag. The neighbor layout is a
//  preview that lives only in the grid (`grid.update(snapshot:animated:)`); the change is
//  written to `TesseraTileStore` once, on drop, and a cancel simply returns the
//  snapshot taken at the grab to the grid. The host does not receive `onChange` on every drag
//  step, and autosave does not fire.
//
//  Resize push-down. When a tile grows it stays in place
//  and conflicting tiles are pushed down in a cascade
//  (`TesseraTileStore.resize(_:to:columns:)`); the coordinator passes the real
//  number of grid columns. The size cycle D15/D28 (small → wide → medium → large →
//  small, order — `TesseraTileSize.cycleOrder`) is unchanged.
//
//  A folder of two tiles is no longer created instantly on a drop onto
//  the center of a target tile. The dragged tile must be held over the target for longer than
//  `mergeHoverDuration` (600 ms) with the finger displacement strictly below
//  `mergeHoverDisplacement` (10 pt); then the target is highlighted with an "absorb" effect
//  (scale 1.08 + an accent border, ~0.2 s) and the drop creates a folder. If the timer has not
//  expired or the finger moved by the tolerance or more, the target does not group: a drop onto
//  the center of a tile/folder returns the tile to its original place,
//  and in other zones the regular drag applies.
//  The "merge or not" decision is made by the pure state machine
//  ``TesseraMergeHoverTracker``: it has no UIKit and no system clock, so it is
//  testable without a simulator.
//
//  The merge-hold bounds are strict (`<10 pt`, `>600 ms`). After the finger moves beyond the tolerance
//  the hold is cancelled but does not stay cancelled forever: returning the finger within the tolerance
//  starts a new 600 ms countdown, and so does leaving the zone or changing the target.
//
//  The center of a target tile is the only zone where a drop does not reorder the
//  tile. Without a completed merge hold, a drop onto the center returns the tile to its original
//  place (no-op/cancel); there is no push preview for the center zone. The same rule
//  applies to the center zone of a folder tile (add to folder by hold).
//
//  Tile movements during a reorder (neighbors moving in
//  `TesseraTileGridView.update(snapshot:animated:)` and the placeholder under the lifted
//  tile) use the bounce curve `cubic-bezier(0.175, 0.885, 0.32, 1.1)`,
//  0.26 s. The factory is shared: `TesseraTileGridView.bounceTimingParameters()`;
//  the folder panel open/close curve (0.1, 0.9, 0.2, 1) is unchanged.
//
//  Magnetism to cells. The snapshot is attracted to the frame of the target cell for
//  its size (`TesseraTileGridView.baseFrame(forCell:size:)`), and the "within the radius or not"
//  decision is made by the pure function
//  `TesseraTileMagnet.magnetTarget(for:slotCenters:snapRadius:)`. The reference point is the
//  **center of the snapshot** (`point + grabOffset`), not the finger: otherwise a tile
//  grabbed off-center would "jump" to the slot by up to half a tile. The attraction is disabled in the start zone,
//  for special targets (a folder/the center of a tile) and over the panel; with
//  Reduce Motion it is disabled entirely. Targets and the merge timer are still computed
//  from the finger point, so the magnet changes neither the order nor the merge.
//
//  Drag targets and geometry:
//  - A folder tile has edge placement zones: the left/right half
//    (outside the center zone) is `.cell` with the folder's cell (before the cell model it was `.reorder` with
//    a base index), the center zone is add-to-folder by hold
//    (D14). A source folder is not dragged into a folder (`session.isTile`).
//  - The magnet computes the slot from the snapshot center (`grabOffset`), not from the finger.
//  - The hold is re-armed after the finger returns within the tolerance / the target changes.
//  - When edit mode is entered and when a drag starts, an expanded folder panel is closed
//    with the regular `closeFolder`; a drag does not start from panel cells (`.folderContent`).
//  - An external model/snapshot during a drag causes a deterministic safe
//    cancel and syncs the grid with the model (rather than rolling back to a stale base).
//  - `deinit` and the fly-out restore the hidden cell, `isScrollEnabled`,
//    `autosaves`, and remove overlays and animators.
//  - A double fast unpin is guarded by an in-flight check per tileID: one fly-out,
//    one mutation, one callback.
//  - Changing `controlDiameter`/`jiggle*`/`mergeHover*` on the fly rebuilds
//    the controls, phases and the hold.
//  - After `render` (unpin/folder creation) the jiggle and dimming are re-applied.
//  - `.layoutChanged` after unpin/resize/move is posted on the next runloop pass,
//    when the focus cell already exists. After an unpin the focus goes to the next
//    element in the cell reading order (the previous one if the tile was the last, the
//    grid itself if no elements are left); after resize/move/drop/take-out it goes to
//    the element that changed or moved, and after a merge to the folder.
//  - The delegate receives the actual cell, and the grid is synchronized with the store
//    snapshot (operations are by cell, not by order index).
//  - The built-in folder screen activates a tile through the shared `grid.onTap` route
//    rather than by calling `action` directly; in edit mode it does not activate.
//
//  Reordering tiles inside an open folder panel (D40). A long press on a
//  panel tile in edit mode starts a drag during which the panel **stays open**:
//  the slot under the finger is found from the slot frames of the panel layout
//  (`TesseraPanelShortcutGeometry.slotFrames`), neighbors shift relative to the base
//  order (the preview lives only in the panel, the model is not written), the drop commits
//  `TesseraTileStore.moveWithinFolder` and calls the delegate's `didReorderTile`; there is no host
//  approval (the composition does not change). When the finger leaves the panel frame plus
//  `panelReorderExitMargin`, the session is replaced by a take-out to the desktop (D45;
//  the panel closes immediately); there is no return to reordering within the same
//  drag. VoiceOver offers "Move earlier"/"Move later" on panel tiles.
//  See STARTSCREEN-IOS-DESIGN, section "Implementation notes and deviations", for details.
//
//  Scrolling discipline (§3, CORE-IOS-DESIGN.md §2): in the `contentOffset` callback
//  the coordinator touches only `frame`/`isHidden` of the button views over the grid and
//  `alpha` of the cell content (dimming) — all properties that are allowed on the hot path;
//  grid and cell layout is not recalculated.
//
//  Responsibilities:
//  - the grid (`TesseraTileGridView`) renders a snapshot and provides geometry;
//  - `TesseraTileStore` is the only writer of the model;
//  - the coordinator owns gestures, the unpin/size button overlays,
//    the drag session and a minimal folder screen;
//  - opening a tile/folder on tap stays with the host (the grid's `onTap`).
//
//  All methods run on the main thread: UIKit views and `TesseraTileStore` are not designed for
//  background calls (CORE-IOS-DESIGN.md §3).
//
//  The unpin button shows a pin glyph instead of a cross.
//

#if canImport(UIKit)
import Combine
import UIKit
import TesseraCore

// MARK: - Delegate

/// Observer of start screen edit mode (docs/STARTSCREEN-IOS-DESIGN.md §5).
///
/// The delegate only learns what the coordinator has already done through `TesseraTileStore`.
/// Returning values and changing the model from callbacks is not allowed: the only writer
/// is `TesseraTileStore` (§6), and the coordinator has already applied the snapshot to the grid.
///
/// All methods are called on the main thread. There are no required methods: any
/// event can be ignored, the default implementations are empty.
public protocol TesseraTileEditCoordinatorDelegate: AnyObject {

    /// The coordinator entered edit mode.
    ///
    /// - Parameter coordinator: The coordinator that raised the event.
    func tileEditCoordinatorDidBeginEditing(_ coordinator: TesseraTileEditCoordinator)

    /// The coordinator left edit mode.
    ///
    /// - Parameter coordinator: The coordinator that raised the event.
    func tileEditCoordinatorDidEndEditing(_ coordinator: TesseraTileEditCoordinator)

    /// A tile was unpinned from the grid (``TesseraTileEditCoordinator/unpin(_:)``).
    ///
    /// - Parameters:
    ///   - coordinator: The coordinator that raised the event.
    ///   - tileID: The identifier of the unpinned tile.
    func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didUnpin tileID: AnyHashable)

    /// The size of a tile or folder changed (``TesseraTileEditCoordinator/cycleSize(of:)``).
    ///
    /// - Parameters:
    ///   - coordinator: The coordinator that raised the event.
    ///   - tileID: The identifier of the tile or folder.
    ///   - size: The new size (D15).
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didResize tileID: AnyHashable,
        to size: TesseraTileSize
    )

    /// An element was moved on the grid.
    ///
    /// - Parameters:
    ///   - coordinator: The coordinator that raised the event.
    ///   - tileID: The identifier of the tile or folder.
    ///   - cell: The top-left cell of the element after the operation (after
    ///     push-down, clamping to the canvas and collapsing of empty rows).
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didMove tileID: AnyHashable,
        toCell cell: TesseraTileGridPlacement
    )

    /// A folder was created (D14).
    ///
    /// - Parameters:
    ///   - coordinator: The coordinator that raised the event.
    ///   - folder: The created folder.
    func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didCreateFolder folder: TesseraTileFolder)

    /// A tile was added to a folder (D14).
    ///
    /// - Parameters:
    ///   - coordinator: The coordinator that raised the event.
    ///   - tileID: The identifier of the tile.
    ///   - folderID: The identifier of the target folder.
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didAdd tileID: AnyHashable,
        toFolder folderID: AnyHashable
    )

    /// A tile was moved between folders or to the desktop (D14).
    ///
    /// - Parameters:
    ///   - coordinator: The coordinator that raised the event.
    ///   - tileID: The identifier of the tile.
    ///   - folderID: The target folder; `nil` means the tile returned to the desktop.
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didMove tileID: AnyHashable,
        toFolder folderID: AnyHashable?
    )

    /// A tile was moved between folders or to the desktop, with a cell.
    ///
    /// The coordinator calls this variant when it moves a tile (from a
    /// drag gesture and from ``TesseraTileEditCoordinator/moveBetweenFolders(_:to:)``) —
    /// **exactly once per operation**. The default implementation forwards the
    /// event to ``tileEditCoordinator(_:didMove:toFolder:)``, so a delegate that
    /// does not need the cell implements only that one; a delegate that does
    /// need it implements this method (and then the other one is not called).
    ///
    /// - Parameters:
    ///   - coordinator: The coordinator that raised the event.
    ///   - tileID: The identifier of the tile.
    ///   - folderID: The target folder; `nil` means the tile was taken out to the desktop.
    ///   - cell: The tile's cell on the desktop after the operation (when
    ///     `folderID == nil`); `nil` when moved into a folder.
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didMove tileID: AnyHashable,
        toFolder folderID: AnyHashable?,
        atCell cell: TesseraTileGridPlacement?
    )

    /// A folder was dissolved: one tile remained in it and took the folder's place (D45).
    ///
    /// A folder never holds 0–1 tiles: when a coordinator operation (unpin,
    /// take-out to the desktop, move to another folder — including a drop from
    /// the panel) leaves one tile in a folder, the folder disappears and that tile
    /// becomes a top-level element in its cell with **its own** size
    /// (a larger tile pushes neighbors down). The method is called **after** a
    /// successful operation and after its main callback
    /// (`didUnpin`, `didMove(_:toFolder:atCell:)`), once per dissolved
    /// folder. A folder that disappeared empty does not raise the event. A dissolution caused by
    /// catalog cleanup (``TesseraTileStore/setCatalog(_:)``), by loading a file, or by calls to
    /// `TesseraTileStore` that bypass the coordinator does not arrive here — the host sees it in the
    /// `TesseraTileStore.onChange` snapshot.
    ///
    /// - Parameters:
    ///   - coordinator: The coordinator that raised the event.
    ///   - folderID: The identifier of the dissolved folder (it is no longer in the model).
    ///   - tileID: The identifier of the remaining tile that became top-level.
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didDissolveFolder folderID: AnyHashable,
        remainingTile tileID: AnyHashable
    )

    /// A folder was renamed (D35).
    ///
    /// Called after a successful
    /// ``TesseraTileEditCoordinator/renameFolder(_:to:)`` — including from the
    /// built-in name editing in an open panel (long press on the
    /// name, the VoiceOver "Rename" action). Not called if the name did not
    /// change. By the time of the call the model and the grid already show the new name.
    ///
    /// - Parameters:
    ///   - coordinator: The coordinator that raised the event.
    ///   - folderID: The identifier of the renamed folder.
    ///   - title: The new folder name as `TesseraTileStore` stores it (normalized;
    ///     empty input means the default name).
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didRenameFolder folderID: AnyHashable,
        to title: String
    )

    /// A tile was reordered inside a folder (D40).
    ///
    /// Called after a successful ``TesseraTileEditCoordinator/moveWithinFolder(_:to:)``
    /// — from a drag inside an open panel, from the VoiceOver "Move
    /// earlier/later" actions and from the public call. Not called if the position
    /// did not change. The folder composition does not change, so the host approval function
    /// (D14) is not consulted. By the time of the call the model and the grid already show the
    /// new order.
    ///
    /// - Parameters:
    ///   - coordinator: The coordinator that raised the event.
    ///   - tileID: The identifier of the reordered tile.
    ///   - folderID: The identifier of the folder.
    ///   - index: The new index of the tile among the folder's tiles (after clamping to
    ///     the bounds).
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didReorderTile tileID: AnyHashable,
        inFolder folderID: AnyHashable,
        toIndex index: Int
    )

    /// The host approval function (D14) rejected a folder operation.
    ///
    /// The model state is unchanged (except when the folder has already been created
    /// and only adding the second tile was rejected — see
    /// ``TesseraTileEditCoordinator``).
    ///
    /// - Parameters:
    ///   - coordinator: The coordinator that raised the event.
    ///   - action: The rejected grouping operation.
    ///   - tileID: The tile the operation was attempted with.
    ///   - folderID: The target folder; `nil` for folder creation.
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didFailGrouping action: TesseraTileGroupingAction,
        tileID: AnyHashable,
        folderID: AnyHashable?
    )
}

public extension TesseraTileEditCoordinatorDelegate {

    func tileEditCoordinatorDidBeginEditing(_ coordinator: TesseraTileEditCoordinator) {}

    func tileEditCoordinatorDidEndEditing(_ coordinator: TesseraTileEditCoordinator) {}

    func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didUnpin tileID: AnyHashable) {}

    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didResize tileID: AnyHashable,
        to size: TesseraTileSize
    ) {}

    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didMove tileID: AnyHashable,
        toCell cell: TesseraTileGridPlacement
    ) {}

    func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didCreateFolder folder: TesseraTileFolder) {}

    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didAdd tileID: AnyHashable,
        toFolder folderID: AnyHashable
    ) {}

    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didMove tileID: AnyHashable,
        toFolder folderID: AnyHashable?
    ) {}

    /// By default it forwards to the callback without a cell, so that a delegate
    /// that does not need the position does not miss the event.
    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didMove tileID: AnyHashable,
        toFolder folderID: AnyHashable?,
        atCell cell: TesseraTileGridPlacement?
    ) {
        tileEditCoordinator(coordinator, didMove: tileID, toFolder: folderID)
    }

    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didDissolveFolder folderID: AnyHashable,
        remainingTile tileID: AnyHashable
    ) {}

    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didRenameFolder folderID: AnyHashable,
        to title: String
    ) {}

    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didReorderTile tileID: AnyHashable,
        inFolder folderID: AnyHashable,
        toIndex index: Int
    ) {}

    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didFailGrouping action: TesseraTileGroupingAction,
        tileID: AnyHashable,
        folderID: AnyHashable?
    ) {}
}

// MARK: - Configuration

/// Edit mode parameters (docs/STARTSCREEN-IOS-DESIGN.md §5).
///
/// Defaults: the jiggle is **off** (``isJiggleEnabled`` — D39: in
/// Windows 10 Mobile (W10M) the grid is static in edit mode); if the host enables it, it is a soft
/// sinusoidal rotation of ±1.2° with a 0.4 s cycle and a separate phase for each
/// tile (seedable — deterministic for tests); auto-scroll at the edges while dragging; the parameters of
/// merge into a folder by hold: 600 ms hold, a 10 pt tolerance and
/// a 0.2 s "absorb" highlight animation with a scale of 1.08; and the parameters of
/// magnetism to cells: a 28 pt radius, a 0.2 s spring with damping
/// 0,82.
public struct TesseraTileEditConfiguration {

    /// Whether the jiggle — the tiles swaying in edit mode — is enabled (D39).
    ///
    /// `false` by default: in W10M the grid is static in edit mode, and swaying is
    /// borrowed from iOS. The host enables it explicitly; then
    /// ``jiggleAngle``, ``jiggleDuration`` and ``seed`` apply. With Reduce Motion the jiggle
    /// is off regardless of the value (§9). Changing the value on the fly while
    /// editing takes effect immediately: the coordinator rebuilds the controls and
    /// attaches or removes the animations (see ``TesseraTileEditCoordinator/configuration``).
    public var isJiggleEnabled: Bool

    /// The jiggle and phase seed: the same seed produces the same sway pattern.
    ///
    /// A tile's phase is computed as a stable hash of its identifier mixed with the seed,
    /// so it does not depend on `hashValue` (which is randomized between
    /// launches) and is reproducible in tests.
    public var seed: UInt64

    /// The jiggle amplitude in degrees (±1.2° by default).
    ///
    /// A small amplitude with a soft sinusoidal animation reads as the tile "breathing"
    /// rather than twitching: a sharp sway is unpleasant to the eye, and the point
    /// of the effect is to show that the element is "alive" and can be moved.
    public var jiggleAngle: CGFloat

    /// The base duration of one sway cycle in seconds.
    ///
    /// 0.4 s by default; with the phase/duration spread (0.85–1.15) the tiles'
    /// cycles diverge to 0.34–0.46 s, so the grid does not sway in sync.
    public var jiggleDuration: TimeInterval

    /// The scale of a lifted tile while dragging.
    ///
    /// The tile shrinks slightly, separating from the plane (the Windows Phone spec uses scale 0.95):
    /// this way the grabbed tile reads as "picked up" and does not overlap its neighbors,
    /// whereas growth of 1.04 would run over them and look like moving closer.
    /// With Reduce Motion the lift is not animated (the tile follows the finger 1:1).
    /// The value need not be greater than one: the animation code works with any
    /// scale, and the frame/center of the snapshot are set through `bounds`/`center`,
    /// so shrinking (< 1) is safe.
    public var liftScale: CGFloat

    /// The largest diameter of the round unpin/size buttons in points.
    ///
    /// This is a ceiling, not a fixed size. The actual diameter
    /// scales with the shorter side of the tile (≈ 24 % of the side) and is no less than
    /// 20 pt: on a small tile the buttons are compact (≈ 22 pt), on a medium and larger one they are
    /// up to `controlDiameter`. The touch area of every button is at least 44 × 44 pt
    /// regardless of the diameter (a `hitTest` extension).
    public var controlDiameter: CGFloat

    /// The width of the auto-scroll zone at the top and bottom edges of the grid in points.
    public var autoScrollEdge: CGFloat

    /// The maximum auto-scroll speed in points per frame.
    public var autoScrollMaximumSpeed: CGFloat

    /// The title of a folder created by dragging a tile onto a tile.
    ///
    /// An empty string (the default) means the localized "Folder" name from the module's
    /// strings; a non-empty value overrides it.
    public var folderTitle: String

    /// How long the dragged tile must be held over the center of the target tile
    /// (or the center zone of a folder tile) for the drop to group the tiles.
    ///
    /// 0.6 s by default (600 ms — the Windows Phone spec); the threshold is strict (`>600 ms`).
    /// Until this time elapses the target is only highlighted with the regular
    /// border and the drop does not group: outside the center zone it is a regular
    /// reorder, in the center it is a no-op. A zero value brings back
    /// an almost instant merge
    /// (the original behavior): readiness is reached on the very first frame after
    /// hovering, and on release the finger gets there first.
    public var mergeHoverDuration: TimeInterval

    /// The allowed finger displacement during the hold, in points.
    ///
    /// 10 pt by default; the tolerance is strict (`<10 pt`). A displacement of the tolerance
    /// or more cancels the hold: the gesture remains a regular drag
    /// even if the finger is still over the center of the target tile. The threshold is deliberately
    /// small: it separates "the finger stopped to build a folder" from "the finger keeps
    /// leading the tile on". Returning the finger within the tolerance after a cancel starts a new
    /// 600 ms countdown.
    public var mergeHoverDisplacement: CGFloat

    /// The scale of the target tile highlight in the "absorb" state.
    ///
    /// 1.08 by default — the middle of the 1.06–1.1 range from the Windows Phone spec. Above
    /// 1.1 the target would read as "the tile grew" rather than "the tile draws
    /// the neighboring one in". Values below 1 are not forbidden but pointless:
    /// "absorbing" is a slight enlargement. With Reduce Motion the scale
    /// is applied without animation.
    public var mergeHighlightScale: CGFloat

    /// The duration of the "absorb" highlight animation in seconds.
    ///
    /// 0.2 s by default: long enough to read as a reaction to the hold, yet
    /// not lagging behind the finger release. With Reduce Motion
    /// the animation is not played — the border and scale are set immediately.
    public var mergeHighlightDuration: TimeInterval

    /// The dwell before the target's "push-down" preview at a tile edge, in seconds (D50).
    ///
    /// While the finger is over the edge of an **occupied** cell, a drop places the dragged
    /// element there and pushes the target down (D31). Showing this shift immediately
    /// is not acceptable: on the way to the center of a tile (to build a folder) the finger first
    /// crosses its edge, and the target would "run away" from under the finger before it
    /// got there. So the push-down preview appears only after the finger
    /// has stayed on this cell for `reorderPreviewDwell`; until then the grid shows the
    /// base layout. Changing the cell restarts the countdown; empty cells and
    /// "new row" (which displace no one) are shown immediately. The drop itself does not
    /// depend on the dwell: it commits the target cell even if the preview is not shown yet.
    ///
    /// 0.2 s by default. `0` (and negative/non-numeric values) means no dwell,
    /// the preview is immediate. With Reduce Motion the dwell remains: it is about
    /// not moving tiles on the approach, not about animation.
    public var reorderPreviewDwell: TimeInterval

    /// The radius within which the snapshot is attracted to a slot center, in points.
    ///
    /// 28 pt by default — the middle of the 24–32 pt range from the Windows Phone spec.
    /// The attraction engages when the **center of the snapshot** (finger + `grabOffset`)
    /// is closer than this radius to the center of a virtual slot
    /// of the same size as the dragged tile: the snapshot smoothly
    /// glides to the center instead of "jumping" there.
    /// Below 24 pt the attraction is barely noticeable; above 32 pt it starts to
    /// "take" the tile from the finger halfway between slots.
    ///
    /// `0` disables the attraction; negative and non-numeric values are also
    /// treated as disabled.
    public var magnetSnapRadius: CGFloat

    /// The duration of the spring glide of the snapshot to the slot center, in seconds.
    ///
    /// 0.2 s by default: a short spring reads as "the tile settled into the
    /// cell" without making the snapshot lag behind the finger. `0` means the snapshot
    /// is moved instantly (no attraction animation).
    ///
    /// With Reduce Motion the attraction is disabled entirely: the snapshot stays strictly
    /// under the finger (the same rule as for the tile lift),
    /// so the duration is not used.
    public var magnetSpringDuration: TimeInterval

    /// The damping of the attraction spring animation.
    ///
    /// 0.82 by default — almost critical, with a barely noticeable bounce:
    /// a strong bounce (below 0.6) looks like jitter on the grid. The value
    /// is clamped to the range 0.01…1; a non-numeric value is treated as 0.82.
    public var magnetSpringDamping: CGFloat

    /// Creates a configuration.
    ///
    /// - Parameters:
    ///   - isJiggleEnabled: Whether the jiggle is enabled, `false` by default (D39).
    ///   - seed: The jiggle phase seed; fixed by default.
    ///   - jiggleAngle: The amplitude in degrees, 1.2 by default.
    ///   - jiggleDuration: The cycle duration in seconds, 0.4 by default.
    ///   - liftScale: The scale of a lifted tile, 0.95 by default (the tile
    ///     shrinks slightly, separating from the plane — the Windows Phone spec).
    ///   - controlDiameter: The largest button diameter (small tiles get
    ///     smaller ones, see ``controlDiameter``), 28 by default.
    ///   - autoScrollEdge: The auto-scroll zone, 64 by default.
    ///   - autoScrollMaximumSpeed: The maximum speed, 9 by default.
    ///   - folderTitle: The title of a new folder; empty means the localized default.
    ///   - mergeHoverDuration: The hold before merging, 0.6 s by default.
    ///   - mergeHoverDisplacement: The displacement tolerance, 10 pt by default.
    ///   - mergeHighlightScale: The "absorb" scale, 1.08 by default.
    ///   - mergeHighlightDuration: The highlight duration, 0.2 s by default.
    ///   - magnetSnapRadius: The slot attraction radius, 28 pt by default.
    ///   - magnetSpringDuration: The spring glide duration, 0.2 s by default.
    ///   - magnetSpringDamping: The spring damping, 0.82 by default.
    ///   - reorderPreviewDwell: The dwell before the push-down preview of the target, 0.2 s by default.
    public init(
        isJiggleEnabled: Bool = false,
        seed: UInt64 = 0xE4_0004_0000_0001,
        jiggleAngle: CGFloat = 1.2,
        jiggleDuration: TimeInterval = 0.4,
        liftScale: CGFloat = 0.95,
        controlDiameter: CGFloat = 28,
        autoScrollEdge: CGFloat = 64,
        autoScrollMaximumSpeed: CGFloat = 9,
        folderTitle: String = "",
        mergeHoverDuration: TimeInterval = 0.6,
        mergeHoverDisplacement: CGFloat = 10,
        mergeHighlightScale: CGFloat = 1.08,
        mergeHighlightDuration: TimeInterval = 0.2,
        magnetSnapRadius: CGFloat = 28,
        magnetSpringDuration: TimeInterval = 0.2,
        magnetSpringDamping: CGFloat = 0.82,
        reorderPreviewDwell: TimeInterval = 0.2
    ) {
        self.isJiggleEnabled = isJiggleEnabled
        self.seed = seed
        self.jiggleAngle = jiggleAngle
        self.jiggleDuration = jiggleDuration
        self.liftScale = liftScale
        self.controlDiameter = controlDiameter
        self.autoScrollEdge = autoScrollEdge
        self.autoScrollMaximumSpeed = autoScrollMaximumSpeed
        self.folderTitle = folderTitle
        self.mergeHoverDuration = mergeHoverDuration
        self.mergeHoverDisplacement = mergeHoverDisplacement
        self.mergeHighlightScale = mergeHighlightScale
        self.mergeHighlightDuration = mergeHighlightDuration
        self.magnetSnapRadius = magnetSnapRadius
        self.magnetSpringDuration = magnetSpringDuration
        self.magnetSpringDamping = magnetSpringDamping
        self.reorderPreviewDwell = reorderPreviewDwell
    }
}

// MARK: - Coordinator

/// The start screen edit-mode coordinator
/// (docs/STARTSCREEN-IOS-DESIGN.md §5; D14/D15 in docs/DECISIONS.md).
///
/// ## Usage
///
/// ```swift
/// let editor = TesseraTileEditCoordinator(grid: grid, store: store)
/// editor.delegate = self
/// grid.onTap = { item in
///     switch item {
///     case .tile(let tile) where !editor.isEditing: tile.action()
///     case .folder(let folder): editor.openFolder(folder)   // D14: folder screen
///     default: break
///     }
/// }
/// // The coordinator installs the long-press gesture itself; there is no need
/// // to set `grid.onLongPress` separately.
/// ```
///
/// ## What the coordinator does
///
/// - **entering**: a long press on a tile or an empty spot → edit mode;
///   on a tile a drag session is lifted immediately (as on the iOS home screen);
/// - **jiggle** (off by default, ``TesseraTileEditConfiguration/isJiggleEnabled``,
///   D39): a soft sinusoidal `CAKeyframeAnimation` rotation of ±1.2°
///   with a 0.4 s cycle and a deterministic phase per tile; with Reduce
///   Motion there is no animation — only the unpin buttons remain;
/// - **dimming**: on entering the mode all tiles except the selected one
///   (the one that was long-pressed) fade to opacity 0.7; during a
///   drag the snapshot and the target tile under the finger stay at full brightness, and on
///   exit the brightness is restored;
/// - **unpin**: a pin (`pin.slash`) → a fly-out of the tile snapshot, then
///   `TesseraTileStore.unpin(_:columns:)` (the cell is left as a hole, an empty row
///   collapses);
/// - **resize**: an arrow → a cyclic size change among the supported ones
///   (by default all four that fit the current number of columns) through
///   `TesseraTileStore.resize(_:to:columns:)`; when a tile grows it stays
///   in place and conflicting neighbors are pushed down;
/// - **drag**: a custom coordinator — the snapshot follows the finger and shrinks slightly
///   (0.95, the Windows Phone spec: the tile "separates" from the plane rather than
///   coming closer), a placeholder stays in its place; when hovering over a target tile
///   the layout is rebuilt as a preview: the dragged tile takes the
///   cell under the finger (the target's cell if the finger is at the edge of an occupied cell), and
///   obstructing tiles are pushed down in a cascade (D31); the place the tile was
///   taken from stays a hole. This is a **preview with no model writes**; on release
///   the layout is committed by a single `TesseraTileStore` operation by cell
///   (`moveItem(_:toCell:columns:)`, `moveItemToNewRow`) and an empty
///   row collapses; auto-scroll at the edges; when the finger approaches the frame of the target cell
///   the snapshot is attracted to it — a short spring that does not affect the
///   targets and the merge timer;
/// - **folders** (D14): dragging a tile onto a folder is `addToFolder`; onto the center
///   of a tile it is a hold: while the finger stays over the target for less than 600 ms or
///   moves away by more than 10 pt, the drop does not group (in the center it is a no-op), and
///   after
///   the hold the target is highlighted with an "absorb" effect and the drop calls `createFolder`
///   + `addToFolder`. All through `TesseraTileStore.approval`; a rejection → a return animation
///   to the original place. The folder screen is a minimal sheet (`TesseraFolderViewController`),
///   where a long press on a tile opens a "move to another folder /
///   to the desktop" menu that calls `TesseraTileStore.moveBetweenFolders` (also
///   through approval);
/// - **folder renaming** (D35): the coordinator sets
///   ``TesseraTileGridView/folderRenameHandler`` — a long press on the name in an
///   open panel (and the VoiceOver "Rename" action on the folder tile and
///   its title) turns the name into a text field; the result goes to
///   `TesseraTileStore.renameFolder(_:to:)`, then to the delegate (`didRenameFolder`).
///   It also works outside edit mode; the public API is ``renameFolder(_:to:)``;
/// - **taking a tile out of a folder**: in edit mode a tap on a folder
///   expands the panel, and a long press on an icon in the panel closes
///   it instantly and lifts the tile (the drag source is the folder, `TesseraTileDragSession.sourceFolderID`).
///   It can be dropped onto the grid / an empty spot — the tile takes the preview cell
///   (`TesseraTileStore.extractFromFolder(_:toCell:columns:)`; D45: taking a tile out of a
///   two-tile folder dissolves it — the remaining tile takes its place, and the preview
///   of the placement target already shows this result); onto the center of another folder with a hold —
///   a move into it; the center of a regular tile does not create a folder here (it works as
///   placement onto its cell); the center of the original folder, the panel and a cancel return
///   the tile, the model does not change;
///   the delegate receives exactly one
///   `didMove(_:toFolder:atCell:)`.
///
/// ## Limitations
///
/// - the grid must not use its own `onLongPress` for another
///   purpose: the coordinator installs its own long-press gesture; if the host has still
///   set `grid.onLongPress`, forward `handleLongPress(on:at:)` from there —
///   a duplicate call is ignored;
/// - in edit mode the host must decide for itself what to do with a tap on a
///   tile (`editor.isEditing`); the coordinator does not intercept taps, so as not to
///   take navigation away from the host. A tap on a folder in edit mode
///   expands the native panel, just as outside it.
/// - inside the panel, tiles can be reordered by dragging only in edit mode (D40);
///   beyond the panel a drag takes the tile out onto the grid or moves it to
///   another folder.
public final class TesseraTileEditCoordinator: NSObject {

    // MARK: - Public settings

    /// The observer of editing events.
    public weak var delegate: TesseraTileEditCoordinatorDelegate?

    /// The jiggle, drag and folder parameters.
    ///
    /// Changing it on the fly restarts the animations: phases are recomputed from the new
    /// seed, and the buttons are recreated with the new diameter. The current hold
    /// is cancelled as well: the threshold and tolerance may have changed, and continuing the countdown
    /// with the old values would be unfair.
    public var configuration: TesseraTileEditConfiguration {
        didSet {
            jiggleSpecs.removeAll()
            // The hold threshold and tolerance may have changed — recomputing the current
            // hold would be unfair, so it is simply cancelled: the highlight
            // goes back to the regular one, and a new hold is armed when the finger
            // re-enters the center of a tile.
            resetMergeHover()
            // The preview dwell may have changed — the countdown is re-armed on the
            // next drag step.
            resetReorderDwell()
            // The magnet radius and spring may have changed — the current
            // attraction is cancelled so that the next drag step starts from the
            // frame the user actually sees.
            resetDragMagnet()
            guard isEditing else { return }
            for control in editControls.values {
                control.layer.removeAnimation(forKey: TesseraTileEditCoordinator.jiggleKey)
            }
            for item in grid.items {
                if let cell = grid.cellView(forItemID: item.id) as? TesseraTileCell {
                    cell.contentView.layer.removeAnimation(
                        forKey: TesseraTileEditCoordinator.jiggleKey
                    )
                }
            }
            // The button diameter is part of the overlay initializer, so the
            // controls are recreated entirely, and the jiggle/custom actions are attached
            // again with the new phase and duration. The magnet radius/spring and the
            // hold thresholds are read at the time of use — it is enough to cancel
            // them (see above).
            removeAllEditControls()
            reconcileEditControls(animated: false)
        }
    }

    /// Whether edit mode is enabled (gestures and buttons).
    ///
    /// When `false` the coordinator ignores long presses and collapses the current
    /// edit mode. `true` by default.
    public var isEnabled: Bool = true {
        didSet {
            guard oldValue != isEnabled else { return }
            longPressRecognizer.isEnabled = isEnabled
            // While the coordinator is disabled, folder names are not editable
            // (the handler is removed — the title is static); the text typed so far is committed.
            updateRenameHandler()
            if !isEnabled {
                endEditing()
            }
        }
    }

    /// An additional filter of supported sizes for a specific element.
    ///
    /// The tile model has no list of supported sizes (D12), so by
    /// default the coordinator allows all D15 sizes that fit into the
    /// current number of grid columns. The host can narrow the set: for example, forbid
    /// `large` for the tiles of a specific app. An empty array is treated as
    /// "use the default set". The host specifies the **set**, not the order:
    /// the cycle order — small → wide → medium → large — is fixed
    /// (D28), and unavailable sizes are skipped in it.
    public var supportedSizesProvider: ((TesseraTileGridItem) -> [TesseraTileSize])?

    /// The controller to present the folder screen from.
    ///
    /// If not set, the coordinator walks the responder chain from the grid
    /// (`UIView.next`) and presents the sheet from the nearest `UIViewController`.
    public var presentingViewControllerProvider: (() -> UIViewController?)?

    /// The host handler for opening a folder.
    ///
    /// If set, the coordinator does not show the built-in screen but hands the folder
    /// to the host (for example, for its own folder controller). If not set,
    /// the minimal `TesseraFolderViewController` is opened.
    public var onFolderOpen: ((TesseraTileFolder) -> Void)?

    /// The Reduce Motion provider (docs/STARTSCREEN-IOS-DESIGN.md §9).
    ///
    /// By default the system setting is read through
    /// ``TesseraAccessibility/isReduceMotionEnabled``. The value is queried at
    /// decision time: enabling Reduce Motion during an editing session
    /// immediately removes the jiggle and shortens animations.
    public var isReduceMotionEnabled: () -> Bool = {
        TesseraAccessibility.isReduceMotionEnabled
    }

    /// The current edit mode.
    public private(set) var isEditing: Bool = false

    /// Whether a drag is in progress right now.
    public var isDragging: Bool {
        dragSession != nil
    }

    /// Whether the tiles are swaying right now (edit mode, the jiggle enabled
    /// by the parameter and no Reduce Motion).
    public var isJiggling: Bool {
        isEditing && configuration.isJiggleEnabled && !isReduceMotionEnabled()
    }

    // MARK: - Internal state

    /// The grid whose gestures and overlays the coordinator owns.
    private let grid: TesseraTileGridView

    /// The only writer of the model (§6).
    private let store: TesseraTileStore

    /// The "enter editing + drag" gesture.
    private let longPressRecognizer = UILongPressGestureRecognizer()

    /// The "tap on an empty spot — leave editing" gesture.
    private let backgroundTapRecognizer = UITapGestureRecognizer()

    /// Observation of the collection scrolling: the buttons must move together with the tiles.
    private var scrollObservation: NSKeyValueObservation?

    /// A subscription to `TesseraTileStore` changes made not by the coordinator (the host,
    /// the folder screen): the buttons must appear/disappear without scrolling.
    private var storeCancellable: AnyCancellable?

    /// The edge auto-scroll ticker during a drag.
    private var displayLink: CADisplayLink?

    /// A weak bridge to the coordinator for `CADisplayLink` (no retain cycle).
    private let displayLinkProxy = TesseraTileEditTickerProxy()

    /// The active drag session; `nil` means there is no drag.
    ///
    /// An internal seam for tests (windowed sessions verify the target zones,
    /// the magnet's `grabOffset`, hold re-arming and the snapshot position). It is not
    /// public API: only ``isDragging`` is exposed.
    private(set) var dragSession: TesseraTileDragSession?

    /// The animator of the placeholder's move.
    ///
    /// It is retained so that the next target under the finger can stop the previous
    /// move at its current point: `UIViewPropertyAnimator` does not support
    /// `.beginFromCurrentState`, and without stopping, the new animation would start from
    /// the final frame of the previous one (the layer model is updated immediately) — the placeholder
    /// would jump on a quick target change.
    private var placeholderAnimator: UIViewPropertyAnimator?

    /// The hold state machine over a target tile.
    ///
    /// It lives only during a drag and only while the finger is over the center of a tile
    /// on which a folder can be built. `nil` means there is no hold (a different target,
    /// the timer is not armed yet, or the hold has already been reset).
    private(set) var mergeTracker: TesseraMergeHoverTracker?

    /// The frame the drag snapshot last collapsed into; a seam for tests.
    private(set) var lastCollapseTargetFrame: CGRect?

    /// The hold timer; `nil` means no countdown is running.
    ///
    /// A separate `Timer` rather than the auto-scroll ticker: `CADisplayLink` fires
    /// every frame even when idle, while the "hold completed" decision is needed exactly
    /// once, after `mergeHoverDuration`.
    private var mergeTimer: Timer?

    /// The timer of the dwell before the push-down preview (D50); `nil` means no countdown.
    ///
    /// A one-shot `Timer` in `.common` mode (like ``mergeTimer``): it is needed so that the
    /// preview appears even when the finger rests and there are no touch events.
    /// The countdown state (the cell and the "completed" flag) lives in the session
    /// (``TesseraTileDragSession/reorderDwellCell``), the timer lives here, and it is cancelled
    /// together with the merge hold on every exit from a drag.
    private var reorderDwellTimer: Timer?

    /// The unpin/size buttons over the visible tiles, by identifier.
    private(set) var editControls: [AnyHashable: TesseraTileEditControlView] = [:]

    /// The unpin buttons on the tiles of an expanded folder's panel, by the tile
    /// identifier (D46).
    ///
    /// They live in the same clipping container as ``editControls``; only in
    /// edit mode and only while the panel has settled (is not opening or
    /// closing). There is no size button for them: a folder member has no
    /// size of its own.
    private(set) var panelEditControls: [AnyHashable: TesseraTileEditControlView] = [:]

    /// The clipping container of the buttons: its frame equals the grid's `bounds`.
    ///
    /// A tile is clipped by the collection bounds (= the grid's `bounds`), while the buttons are
    /// subviews of the grid itself, so they used to stick out past the edge. A container
    /// with `clipsToBounds` clips them at the same boundary. It is created lazily.
    private(set) var editControlsHost: TesseraTileEditControlsHostView?

    /// The jiggle phases by tile identifier (cached until the configuration changes).
    private var jiggleSpecs: [AnyHashable: TesseraJiggleSpec] = [:]

    /// The cells the coordinator set custom actions on (so they can be removed at the end).
    private var cellsWithEditActions: [ObjectIdentifier: TesseraTileCell] = [:]

    /// The signature of a cell's custom actions: the tile identifier, the owning folder (for
    /// a panel tile) and the set of available folders — it skips repeats but not
    /// stale actions after a folder is created/deleted.
    private var editActionsItemByCell: [ObjectIdentifier: [AnyHashable]] = [:]

    /// The maximum number of "to folder"/"to another folder" items for a single tile:
    /// a VoiceOver rotor with dozens of actions is inconvenient, so the first
    /// folders in grid order are taken.
    static let maxFolderActions = 6

    /// The highlight of the target tile during a drag.
    private var dropHighlightView: TesseraTileDropHighlightView?

    /// The tile that stays at full brightness in the dim field.
    ///
    /// Set when entering editing with a long press on a tile and when a
    /// drag starts; when entering from an empty spot it is `nil`, and then all
    /// tiles fade. During a drag it is overridden by the dragged tile: the snapshot and the
    /// target under the finger stay at full brightness (see
    /// ``dimmingTargetAlpha(for:)``).
    private var dimmingFocusID: AnyHashable?

    /// A deferred button reconcile: it does not perform layout inside the scroll callback.
    private var hasScheduledReconcile = false

    /// The value of ``TesseraTileStore/autosaves`` before the drag began.
    ///
    /// The model does not change at all during a drag: the neighbor order is a preview
    /// in the grid. But a drop may consist of several mutations (folder creation +
    /// adding a tile) or a single reorder, and the state must be saved
    /// once at the end, not after every operation. So for the duration of a drag
    /// autosave is turned off and restored in
    /// ``endDragStoreTransaction(saveIfNeeded:)``.
    private var autosavesBeforeDrag: Bool?

    /// Whether an external model change is in progress during a drag.
    ///
    /// `TesseraTileStore` reports a mutation before it is applied (`objectWillChange`),
    /// so the coordinator's subscriber only raises a flag: the snapshots are compared
    /// on the next drag step. The coordinator's own mutations happen
    /// after `dragSession = nil`, so the flag is raised only by someone else's write.
    private var storeChangedDuringDrag = false

    /// The tiles for which the unpin fly-out is already playing.
    ///
    /// A fast double tap on the pin must not start a second animation and
    /// a second mutation: while the snapshot is flying, a repeated call to ``unpin(_:)`` for
    /// the same tile is ignored.
    private var unpinsInFlight: Set<AnyHashable> = []

    /// Publishing the accessibility notifications of edit mode.
    ///
    /// `UIAccessibility.post(notification:argument:)` by default.
    /// An internal seam for tests: `.layoutChanged` after unpin/resize/move
    /// cannot be observed by system means without VoiceOver enabled.
    var accessibilityNotificationPoster: (UIAccessibility.Notification, Any?) -> Void = {
        UIAccessibility.post(notification: $0, argument: $1)
    }

    /// The animation key of the jiggle on the layer.
    static let jiggleKey = "tessera.edit.jiggle"

    // MARK: - Initialization

    /// Creates the coordinator and installs gestures on the grid.
    ///
    /// - Parameters:
    ///   - grid: The start screen grid. The coordinator holds it strongly:
    ///     the gesture and the overlays cannot exist without it.
    ///   - store: The only writer of the model (§6).
    ///   - configuration: The jiggle, drag and folder parameters.
    public init(
        grid: TesseraTileGridView,
        store: TesseraTileStore,
        configuration: TesseraTileEditConfiguration = TesseraTileEditConfiguration()
    ) {
        self.grid = grid
        self.store = store
        self.configuration = configuration
        super.init()

        displayLinkProxy.coordinator = self
        setUpGestures()
        observeScrollView()
        observeStore()
        observeNotifications()
        reportGridWidthToStore()
        // A change in the grid's column count changes the canvas width — pass it
        // to the store (cells are stored on a canvas of a specific width, D32).
        grid.columnsDidChange = { [weak self] _ in
            self?.gridColumnsDidChange()
        }
        // The expanded folder panel is reconfigured on every snapshot —
        // the custom actions of its tiles are picked up by the deferred reconcile.
        grid.panelShortcutsDidConfigure = { [weak self] _, _ in
            self?.scheduleReconcile()
        }
        // D46: the unpin buttons on panel tiles appear when the panel
        // has settled and go away as soon as it starts closing.
        grid.folderPanelStateDidChange = { [weak self] in
            guard let self, self.isEditing else { return }
            self.reconcilePanelEditControls(fadesIn: true)
        }
        // D35: renaming a folder from the panel goes through the coordinator.
        updateRenameHandler()
    }

    deinit {
        grid.folderRenameHandler = nil
        grid.folderPanelStateDidChange = nil
        grid.panelShortcutsDidConfigure = nil
        grid.columnsDidChange = nil
        NotificationCenter.default.removeObserver(self)
        scrollObservation?.invalidate()
        scrollObservation = nil
        displayLink?.invalidate()
        displayLink = nil

        // The hold timer retains a closure over the coordinator — cancel it
        // before the overlays go away.
        mergeTimer?.invalidate()
        mergeTimer = nil
        mergeTracker = nil
        reorderDwellTimer?.invalidate()
        reorderDwellTimer = nil

        // The magnet spring retains a closure over the session with the snapshot view —
        // stop it before the grid and the overlays leave the hierarchy.
        dragSession?.magnetAnimator?.stopAnimation(true)
        dragSession?.magnetAnimator = nil

        if let wasEnabled = autosavesBeforeDrag {
            autosavesBeforeDrag = nil
            store.autosaves = wasEnabled
        }

        grid.removeGestureRecognizer(longPressRecognizer)
        grid.removeGestureRecognizer(backgroundTapRecognizer)

        // An unfinished drag session is grid state, not model state.
        // Tear it down entirely: the base order, the hidden cell, scrolling,
        // overlays and trailing animators. Otherwise the coordinator may disappear,
        // leaving the grid with an invisible cell, scrolling disabled and a foreign
        // order — with no owner to fix it.
        let interruptedSession = dragSession
        dragSession = nil
        stopPlaceholderAnimation()
        interruptedSession?.dragView.removeFromSuperview()
        interruptedSession?.placeholder.removeFromSuperview()
        if let session = interruptedSession {
            if !gridMatches(session.baseSnapshot) {
                grid.update(snapshot: session.baseSnapshot, animated: false)
            }
            grid.setItemHidden(false, forItemID: session.itemID)
            if session.panelReorder != nil { grid.endPanelReorder() }
            // Only a drag session disables scrolling,
            // so it is restored only after an interrupted drag, not
            // unconditionally (otherwise deinit would overwrite the host's intent).
            grid.isScrollEnabled = true
        }

        // The overlays are subviews of the grid: if they are not removed, they outlive the coordinator.
        for control in editControls.values {
            control.removeFromSuperview()
        }
        editControls.removeAll()
        dropHighlightView?.removeFromSuperview()
        dropHighlightView = nil

        for cell in cellsWithEditActions.values {
            cell.accessibilityCustomActions = nil
        }
        cellsWithEditActions.removeAll()
        editActionsItemByCell.removeAll()

        for item in grid.items {
            if let cell = grid.cellView(forItemID: item.id) as? TesseraTileCell {
                // The jiggle lives on the layer of the cell content (see applyJiggle).
                cell.contentView.layer.removeAnimation(
                    forKey: TesseraTileEditCoordinator.jiggleKey
                )
            }
        }
        // The grid removes the dimming — it owns the opacity.
        grid.setEditDimming(liftedDimmingTargets(), animated: false)
        dimmingFocusID = nil
    }

    /// Installs the gestures: long press (enter + drag) and tap on the background (exit).
    private func setUpGestures() {
        longPressRecognizer.minimumPressDuration = 0.45
        longPressRecognizer.allowableMovement = 12
        longPressRecognizer.delegate = self
        longPressRecognizer.addTarget(
            self,
            action: #selector(handleLongPressGesture(_:))
        )
        grid.addGestureRecognizer(longPressRecognizer)

        backgroundTapRecognizer.delegate = self
        backgroundTapRecognizer.cancelsTouchesInView = false
        backgroundTapRecognizer.isEnabled = false
        backgroundTapRecognizer.addTarget(
            self,
            action: #selector(handleBackgroundTap(_:))
        )
        grid.addGestureRecognizer(backgroundTapRecognizer)
    }

    /// Subscribes to the scrolling of the collection inside the grid.
    ///
    /// The grid does not expose a host scroll callback free of parallax (§8), while
    /// the edit buttons need to move together with the tiles. So the coordinator
    /// listens to the `contentOffset` of the collection itself: the handler touches only `frame` and
    /// `isHidden`, without recalculating layout (§3, CORE-IOS-DESIGN.md §2).
    private func observeScrollView() {
        guard let scrollView = TesseraTileEditCoordinator.findScrollView(in: grid) else {
            return
        }
        scrollObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            self?.scrollOffsetDidChange()
        }
    }

    /// Subscribes to store changes to reconcile the buttons after
    /// external edits (pin/unpin from the app list, the folder screen).
    ///
    /// `objectWillChange` fires before the change and without a snapshot, so the reconcile
    /// is deferred to the next runloop pass — by then the host has already
    /// applied the snapshot to the grid.
    private func observeStore() {
        storeCancellable = store.objectWillChange.sink { [weak self] in
            guard let self, self.isEditing else { return }
            // A model mutation during a drag raises a flag — on the
            // next step the session compares the snapshot with the base and safely cancels.
            // `objectWillChange` fires before the change, so the comparison itself
            // is done by the deferred ``scheduleReconcile()`` (the host has time to
            // apply the snapshot to the grid).
            if self.dragSession != nil {
                self.storeChangedDuringDrag = true
            }
            self.scheduleReconcile()
        }
    }

    /// Subscriptions to Reduce Motion and the app moving to the background.
    private func observeNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reduceMotionStatusDidChange),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    // MARK: - Edit mode

    /// Enters edit mode: the jiggle, dimming and buttons.
    ///
    /// A repeated call does nothing. With Reduce Motion the jiggle and the dimming
    /// animation are not started, but the dimming itself, the buttons and custom actions appear
    /// (§9).
    public func beginEditing() {
        beginEditing(focusing: nil)
    }

    /// The shared implementation of entering with a "selected" tile.
    ///
    /// - Parameter itemID: The tile that was long-pressed to enter; it stays
    ///   at full brightness, the others fade to ``TesseraTileGridView/dimmedTileAlpha``. `nil` means entering
    ///   from an empty spot, and all tiles fade.
    private func beginEditing(focusing itemID: AnyHashable?) {
        guard !isEditing, isEnabled else { return }

        // Entering edit mode commits the folder name if it is
        // being typed right now.
        grid.commitFolderNameEditing()
        isEditing = true
        dimmingFocusID = itemID
        backgroundTapRecognizer.isEnabled = true
        // An expanded folder panel is closed on entering edit mode with the regular
        // `closeFolder` (instantly with Reduce Motion). Otherwise a drag starts
        // over the panel: its place in the layout is fixed, and the rows under it
        // are shifted. After a non-animated (reloadData) close the cells
        // are recreated — the deferred reconcile restores their jiggle and dimming.
        closeExpandedFolderForEditing()
        // The grid width goes to the store, and the grid shows its cells: a future
        // drag, including from a folder panel, computes targets from the same cells.
        prepareModelForEditing()
        reconcileEditControls(animated: false, dimAnimated: true)
        // The cells may not be created yet (first layout/presentation): the
        // buttons, jiggle and dimming are picked up on the next runloop pass.
        scheduleReconcile()

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        announce(TesseraStartScreenStrings.string(.a11yEditingEntered))
        delegate?.tileEditCoordinatorDidBeginEditing(self)
    }

    /// Closes the expanded folder's panel if it is open.
    ///
    /// Called when entering editing and when a drag starts: the panel is
    /// a full-width row that shifts the layout, and dragging over it is forbidden.
    /// The panel has its own animation (D17); with Reduce Motion and outside a window `closeFolder`
    /// picks the instant branch itself.
    private func closeExpandedFolderForEditing() {
        guard grid.expandedFolderID != nil else { return }
        grid.closeFolder(animated: !isReduceMotionEnabled())
    }

    /// Leaves edit mode and cancels the active drag.
    ///
    /// The model did not change during the drag (the order is a preview in the grid),
    /// so the rollback is just returning the snapshot taken at the grab to the grid, without writing to
    /// `TesseraTileStore`: an unfinished drag does not leave the model in an intermediate
    /// state. The dimming is removed with a short animation; with Reduce
    /// Motion the brightness is restored immediately.
    public func endEditing() {
        guard isEditing else { return }

        // Leaving edit mode commits the name being typed.
        grid.commitFolderNameEditing()
        cancelDragImmediately()
        isEditing = false
        dimmingFocusID = nil
        backgroundTapRecognizer.isEnabled = false
        removeAllEditControls()
        removeAllJiggle()
        // Restore brightness on all tiles; by now the drag has already been cancelled and
        // there are no cells hidden by the coordinator.
        applyEditDimming(animated: true)

        announce(TesseraStartScreenStrings.string(.a11yEditingExited))
        delegate?.tileEditCoordinatorDidEndEditing(self)
    }

    /// Toggles edit mode.
    public func toggleEditing() {
        if isEditing {
            endEditing()
        } else {
            beginEditing()
        }
    }

    /// Enters editing and immediately drags an element (for a host that leads
    /// its own long press instead of the built-in one).
    ///
    /// The coordinator's built-in gesture calls this same method; a repeated call
    /// during an already started drag is ignored, so duplication is safe.
    /// The tile is passed to ``beginEditing(focusing:)`` as the selected one: before the
    /// drag starts it is at full brightness and the others fade immediately.
    ///
    /// - Parameters:
    ///   - item: The element that was long-pressed.
    ///   - point: The press point in grid coordinates (as in
    ///     `TesseraTileGridView.onLongPress`).
    public func handleLongPress(on item: TesseraTileGridItem, at point: CGPoint) {
        guard isEnabled, grid.window != nil, dragSession == nil else { return }

        // The panel is not a tile, its place is fixed by the layout.
        // Outside editing, a long press on the panel only enters
        // editing (and closes the panel in the regular way).
        // In edit mode a long press on a panel icon
        // lifts the tile (the source is the folder); on anything else in the panel (the title,
        // the background) nothing happens. The lift starts a reorder inside
        // the panel (the panel stays open); a take-out to the desktop starts
        // when the finger leaves the panel (``startPanelDrag(at:)``).
        guard !item.isFolderPanel else {
            if isEditing {
                startPanelDrag(at: point)
            } else {
                beginEditing()
            }
            return
        }
        guard grid.index(ofItemID: item.id) != nil else { return }

        // The drag starts right after the long press, so the panel
        // closes **instantly** (`closeFolder(animated: false)`) rather than
        // animated: otherwise the first drag frames would run over the shifting
        // layout, and previews would end up in the deferred grid snapshot.
        // For the public `beginEditing()` without a drag the closing animation stays.
        closeExpandedFolderInstantlyIfNeeded()
        // Model and grid cells come before capturing the drag base (also when
        // edit mode is already on: the host may have changed the model while edit mode was open).
        prepareModelForEditing()
        if !isEditing {
            beginEditing(focusing: item.id)
        }
        startDrag(itemID: item.id, at: point)
    }

    /// Closes the folder panel instantly before a drag starts.
    ///
    /// If the panel is already closing with an animation (the panel transition is in progress), the grid
    /// defers the close command (last wins); this is not an error — the guard
    /// in ``syncGridWithModel(animated:)``/``render(animated:)`` prevents a
    /// stale preview from being applied after the transition.
    private func closeExpandedFolderInstantlyIfNeeded() {
        guard grid.expandedFolderID != nil else { return }
        grid.closeFolder(animated: false)
    }

    /// Recomputes the position of the edit buttons.
    ///
    /// Needed after a screen rotation, a container width change or
    /// `invalidateTileLayout(animated:)` — the coordinator does not observe the grid
    /// bounds, to avoid duplicating layout passes.
    public func refreshEditControls() {
        guard isEditing else { return }
        reconcileEditControls(animated: false)
    }

    // MARK: - Unpin

    /// Unpins a tile with a fly-out animation (§5).
    ///
    /// First the cell snapshot animation plays, then
    /// ``TesseraTileStore/unpin(_:columns:)`` is called — the model changes when the tile has already
    /// flown away. The tile's cell is left as a hole (D30); a fully emptied row
    /// collapses (``TesseraTileStore/collapseEmptyRows(columns:)``, D31). If the
    /// store refuses, the cell returns to its place.
    ///
    /// A folder cannot be unpinned (it exists while it has tiles), so
    /// the method does nothing for a folder. A tile inside a folder is not shown on the grid:
    /// for it the operation goes straight to the store; if the folder had two tiles,
    /// it is dissolved (D45): the expanded panel closes, the remaining tile
    /// takes the folder's place, after `didUnpin` the delegate receives `didDissolveFolder`,
    /// and VoiceOver focus moves to the remaining tile (with three or more — to a neighboring
    /// panel tile: the next one, and for the last one the previous).
    ///
    /// - Parameter tileID: The tile identifier.
    public func unpin(_ tileID: AnyHashable) {
        guard dragSession == nil else { return }
        // While the tile snapshot is flying, a repeated tap on the pin
        // is ignored — one fly-out, one mutation, one callback.
        guard !unpinsInFlight.contains(tileID) else { return }
        unpinsInFlight.insert(tileID)

        guard let item = grid.items.first(where: { $0.id == tileID }) else {
            // The tile is in a folder or already unpinned — there is nothing to animate.
            performImmediateUnpin(tileID)
            return
        }
        guard item.tile != nil else {
            unpinsInFlight.remove(tileID)
            return
        }

        guard let cell = grid.cellView(forItemID: tileID) as? TesseraTileCell,
              let frame = grid.frame(forItemID: tileID),
              let snapshot = TesseraTileEditCoordinator.makeSnapshot(of: cell) else {
            performImmediateUnpin(tileID)
            return
        }

        // The focus target is chosen before the removal, in reading order: the next
        // element after the tile (or the previous one if it was the last). An index
        // "in place of the removed one" does not work: holes and row collapsing do not change
        // the order of the remaining ones, but the tile's place may stay empty.
        let focus = UnpinFocus.gridItem(focusTarget(afterRemoving: tileID))

        removeControl(for: tileID)
        cell.contentView.layer.removeAnimation(forKey: TesseraTileEditCoordinator.jiggleKey)
        grid.setItemHidden(true, forItemID: tileID)

        snapshot.frame = frame
        snapshot.isUserInteractionEnabled = false
        snapshot.layer.zPosition = 1000
        snapshot.layer.shadowColor = UIColor.black.cgColor
        snapshot.layer.shadowOpacity = 0.2
        snapshot.layer.shadowRadius = 12
        snapshot.layer.shadowOffset = CGSize(width: 0, height: 6)
        grid.addSubview(snapshot)

        let reduceMotion = isReduceMotionEnabled()
        UIView.animate(
            withDuration: reduceMotion ? 0.12 : 0.22,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseIn],
            animations: {
                snapshot.alpha = 0
                if !reduceMotion {
                    // The frame is undefined under a non-identity transform — change
                    // bounds/center, as UIKit requires.
                    snapshot.bounds = CGRect(
                        origin: .zero,
                        size: CGSize(width: frame.width * 0.35, height: frame.height * 0.35)
                    )
                    snapshot.center = CGPoint(x: frame.midX, y: frame.midY - 48)
                }
            },
            completion: { [weak self, weak grid] _ in
                snapshot.removeFromSuperview()
                // The coordinator may have disappeared mid fly-out
                // (deinit) — the cell is returned anyway, otherwise the tile
                // would stay invisible and the model would stay pinned.
                guard let self else {
                    grid?.setItemHidden(false, forItemID: tileID)
                    return
                }

                self.unpinsInFlight.remove(tileID)
                let removed = self.store.unpin(tileID, columns: self.storeColumns)
                self.grid.setItemHidden(false, forItemID: tileID)

                guard removed else {
                    self.reconcileEditControls(animated: false)
                    return
                }

                // The tile's departure left a hole; the empty row collapses,
                // then the grid is synchronized with the store snapshot.
                self.store.collapseEmptyRows(columns: self.storeColumns)
                self.render(animated: true)
                self.delegate?.tileEditCoordinator(self, didUnpin: tileID)
                self.postLayoutChanged(afterUnpinning: focus)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.announce(TesseraStartScreenStrings.string(.a11yTileUnpinned))
            }
        )
    }

    /// Unpinning a tile of the expanded panel with the button on it (D46).
    ///
    /// The same scenario as for the button on a grid tile: the tile flies away (the icon
    /// snapshot shrinks and fades), then the regular folder tile unpin
    /// ``performImmediateUnpin(_:)`` — ``TesseraTileStore/unpin(_:columns:)``, `didUnpin`,
    /// the D45 rule (in a two-tile folder it is dissolved, the panel
    /// closes, the remaining tile takes the folder's place, `didDissolveFolder`)
    /// and VoiceOver focus (the remaining tile / the next one in the panel, for the last one the
    /// previous one). There is no confirmation. With Reduce Motion — no flight, instant.
    ///
    /// The public ``unpin(_:)`` (including the VoiceOver action) stays
    /// synchronous and without a flight: the animation applies only to a tap on the button.
    ///
    /// - Parameter tileID: The folder tile identifier.
    func unpinPanelTile(_ tileID: AnyHashable) {
        guard isEditing, dragSession == nil, unpinsInFlight.isEmpty else { return }

        guard !isReduceMotionEnabled(),
              let panel = grid.panelShortcuts(),
              let index = panel.folder.tiles.firstIndex(where: { $0.id == tileID }),
              panel.cells.indices.contains(index),
              let geometry = grid.panelShortcutGeometry(),
              geometry.tileIDs == panel.folder.tiles.map({ $0.id }),
              let snapshot = TesseraTileEditCoordinator.makeSnapshot(of: panel.cells[index]) else {
            unpin(tileID)
            reconcilePanelEditControls(fadesIn: false)
            return
        }

        let cell = panel.cells[index]
        let frame = geometry.frames[index]
        unpinsInFlight.insert(tileID)
        removePanelControl(for: tileID)
        cell.alpha = 0

        snapshot.frame = frame
        snapshot.isUserInteractionEnabled = false
        snapshot.layer.zPosition = 1000
        snapshot.layer.shadowColor = UIColor.black.cgColor
        snapshot.layer.shadowOpacity = 0.2
        snapshot.layer.shadowRadius = 12
        snapshot.layer.shadowOffset = CGSize(width: 0, height: 6)
        grid.addSubview(snapshot)

        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseIn],
            animations: {
                snapshot.alpha = 0
                // The frame is undefined under a non-identity transform — bounds/center.
                snapshot.bounds = CGRect(
                    origin: .zero,
                    size: CGSize(width: frame.width * 0.35, height: frame.height * 0.35)
                )
                snapshot.center = CGPoint(x: frame.midX, y: frame.midY - 48)
            },
            completion: { [weak self] _ in
                snapshot.removeFromSuperview()
                // The cell is transparent during the flight: without a model mutation it must be
                // returned, otherwise the tile stays invisible. On success the cell
                // is reconfigured by the grid (`configure` resets the transparency).
                guard let self else {
                    cell.alpha = 1
                    return
                }

                let stillInPanel = self.isEditing && self.dragSession == nil
                    && self.grid.panelShortcuts()?.folder.tiles.contains { $0.id == tileID } == true
                guard stillInPanel else {
                    // The panel was closed or the tile left while it was flying: no mutation.
                    cell.alpha = 1
                    self.unpinsInFlight.remove(tileID)
                    self.reconcilePanelEditControls(fadesIn: false)
                    return
                }

                // `performImmediateUnpin` removes `unpinsInFlight` itself.
                self.performImmediateUnpin(tileID)
                if self.store.isPinned(tileID) {
                    // The store refused: the tile stays in the folder.
                    cell.alpha = 1
                }
                self.reconcilePanelEditControls(fadesIn: false)
            }
        )
    }

    /// Immediate unpin without animation (the cell is off screen / the tile is in a folder).
    ///
    /// A tile inside a folder (including in an expanded panel, where the
    /// VoiceOver "Unpin" action removes it) follows the D45 rule: if one tile
    /// remains in the folder, the folder is **dissolved** — the panel closes (with the regular
    /// `closeFolder`, animated, instantly with Reduce Motion), and the remaining
    /// tile takes the folder's place; VoiceOver focus moves to it. If two or more
    /// remain in the folder, the panel stays and the focus goes to the **next** tile
    /// of the panel in display order (to the previous one for the last tile). The delegate
    /// receives `didUnpin`, then `didDissolveFolder`.
    ///
    /// - Parameter tileID: The tile identifier.
    private func performImmediateUnpin(_ tileID: AnyHashable) {
        // The entry is removed in any outcome: a repeated unpin after a store
        // refusal must be allowed to try again.
        defer { unpinsInFlight.remove(tileID) }

        // D45: the focus target is chosen before the removal. A grid tile (the cell
        // is off screen) is a reading-order neighbor; a tile in a folder is the remaining
        // tile of the dissolved folder or a neighboring panel tile.
        let dissolution = dissolutionPlan(whenRemoving: tileID)
        let focus = unpinFocus(for: tileID, dissolution: dissolution)
        guard store.unpin(tileID, columns: storeColumns) else { return }
        // The hole stays, the empty row collapses (D31).
        store.collapseEmptyRows(columns: storeColumns)
        // D45: the panel of the dissolved folder closes before the grid applies
        // the snapshot without the folder (the grid defers the snapshot until the close animation ends).
        closePanel(ofDissolving: dissolution)
        render(animated: true)
        delegate?.tileEditCoordinator(self, didUnpin: tileID)
        notifyDissolution(dissolution)
        postLayoutChanged(afterUnpinning: focus)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        announce(TesseraStartScreenStrings.string(.a11yTileUnpinned))
    }

    // MARK: - Resize

    /// Cycles the size of an element: small → wide → medium → large → small
    /// (docs/STARTSCREEN-IOS-DESIGN.md §5, D15, D28).
    ///
    /// The cycle order is set explicitly in `TesseraTileSize.cycleOrder` (the W10M order with `large`
    /// last), not by the `allCases` order or by the order of the host's list.
    /// By default the supported sizes are all four that fit into
    /// the grid's column count (a wide tile needs four). The host can narrow
    /// the set through ``supportedSizesProvider``: the cycle skips unsupported
    /// sizes. The VoiceOver "Change size" action performs the same step
    /// (it calls this method). The repacking is done by
    /// `TesseraTileStore` + `TesseraTileGridView.update(snapshot:animated:)`: the layout
    /// is recomputed by `TesseraTileLayoutEngine`, and neighbors move with a batch animation.
    ///
    /// Resize goes through ``TesseraTileStore/resize(_:to:columns:)`` —
    /// the anchor cell stays, growth pushes obstructing tiles down in a cascade
    /// (D31), shrinking leaves a hole; then only a fully
    /// empty row collapses (``TesseraTileStore/collapseEmptyRows(columns:)``).
    ///
    /// - Parameter itemID: The identifier of the tile or folder.
    /// - Returns: The new size, or `nil` if there is nothing to change.
    @discardableResult
    public func cycleSize(of itemID: AnyHashable) -> TesseraTileSize? {
        guard dragSession == nil,
              let item = grid.items.first(where: { $0.id == itemID }) else {
            return nil
        }

        let sizes = supportedSizes(for: item)
        guard sizes.count > 1 else { return nil }

        let next = item.size.next(among: sizes)
        guard next != item.size,
              store.resize(itemID, to: next, columns: storeColumns) else {
            return nil
        }

        store.collapseEmptyRows(columns: storeColumns)
        render(animated: true)
        delegate?.tileEditCoordinator(self, didResize: itemID, to: next)
        // After a resize the tile has moved — VoiceOver focus is moved
        // to its new frame (on the next runloop pass, when the cell has already been
        // laid out).
        postLayoutChanged(focusing: itemID)
        UISelectionFeedbackGenerator().selectionChanged()
        let sizeName = TesseraTileEditCoordinator.name(for: next)
        announce(String(format: TesseraStartScreenStrings.string(.a11yResizeFormat), sizeName))
        return next
    }

    /// The list of sizes available to an element.
    ///
    /// - Parameter item: A tile or folder.
    /// - Returns: The supported sizes (the cycle order is set by `TesseraTileSize.cycleOrder`,
    ///   D28); never empty.
    private func supportedSizes(for item: TesseraTileGridItem) -> [TesseraTileSize] {
        if let provider = supportedSizesProvider {
            let custom = provider(item)
            if !custom.isEmpty {
                return custom
            }
        }

        let columns = max(1, grid.columns)
        let fits = TesseraTileSize.allCases.filter { $0.unitColumns <= columns }
        return fits.isEmpty ? [.small] : fits
    }

    // MARK: - Reordering

    /// Moves a grid element to a cell through `TesseraTileStore` (§6).
    ///
    /// A layout operation does not require approval (D14). The element lands on `cell`,
    /// clamped to the canvas; obstructing tiles are pushed down in a cascade (D31),
    /// a hole is left in the old place, and a fully empty row collapses
    /// (``TesseraTileStore/moveItem(_:toCell:columns:)``,
    /// ``TesseraTileStore/collapseEmptyRows(columns:)``). The delegate receives the element's
    /// resulting cell; the grid is synchronized with the store snapshot.
    ///
    /// - Parameters:
    ///   - itemID: The identifier of a tile or folder on the grid.
    ///   - cell: The desired top-left cell (logical coordinates).
    /// - Returns: `true` if the layout changed.
    @discardableResult
    public func move(_ itemID: AnyHashable, toCell cell: TesseraTileGridPlacement) -> Bool {
        finishMove(of: itemID, moved: store.moveItem(itemID, toCell: cell, columns: storeColumns))
    }

    /// Moves a grid element to a new row at the end of the canvas (D33).
    ///
    /// Like ``move(_:toCell:)``, but the target is ``TesseraTileStore/moveItemToNewRow(_:columns:)``.
    ///
    /// - Parameter itemID: The identifier of a tile or folder on the grid.
    /// - Returns: `true` if the layout changed.
    @discardableResult
    public func moveToNewRow(_ itemID: AnyHashable) -> Bool {
        finishMove(of: itemID, moved: store.moveItemToNewRow(itemID, columns: storeColumns))
    }

    /// The shared tail of ``move(_:toCell:)`` and ``moveToNewRow(_:)``: collapsing an empty
    /// row, grid synchronization, the delegate, VoiceOver focus.
    private func finishMove(of itemID: AnyHashable, moved: Bool) -> Bool {
        guard moved else { return false }

        let columns = storeColumns
        store.collapseEmptyRows(columns: columns)
        render(animated: true)
        if let cell = store.placements(forColumns: columns)[itemID] {
            delegate?.tileEditCoordinator(self, didMove: itemID, toCell: cell)
        }
        // The element has moved — VoiceOver focus is moved to its cell
        // after layout.
        postLayoutChanged(focusing: itemID)
        return true
    }

    // MARK: - Folders (D14: only through the host approval function)

    /// Creates a folder from a tile on the grid.
    ///
    /// All validation is inside the store: the host receives
    /// `TesseraTileGroupingAction.createFolder`; a rejection leaves the model untouched.
    /// The folder takes the tile's cell (2×2, D20) and neighbors are pushed down
    /// (D31). Creating a folder from two tiles by a drop is done by
    /// ``TesseraTileEditCoordinator`` itself (two approved steps: creation,
    /// then adding).
    ///
    /// - Parameters:
    ///   - tileID: The tile that becomes the folder's first content.
    ///   - title: The title; `nil` means ``TesseraTileEditConfiguration/folderTitle``.
    /// - Returns: The created folder, or `nil` if the host rejected it.
    @discardableResult
    public func createFolder(withTile tileID: AnyHashable, title: String? = nil) -> TesseraTileFolder? {
        let folder = store.createFolder(
            withTile: tileID,
            title: resolvedNewFolderTitle(title ?? configuration.folderTitle),
            columns: storeColumns
        )
        guard let folder else {
            if grid.index(ofItemID: tileID) != nil {
                notifyGroupingFailure(.createFolder, tileID: tileID, folderID: nil)
            }
            return nil
        }

        render(animated: true)
        delegate?.tileEditCoordinator(self, didCreateFolder: folder)
        postLayoutChanged(focusing: folder.id)
        announce(TesseraStartScreenStrings.string(.a11yFolderCreated))
        return folder
    }

    /// Adds a tile from the grid to a folder through the approval function (D14).
    ///
    /// - Parameters:
    ///   - tileID: The tile on the grid.
    ///   - folderID: The target folder.
    /// - Returns: `true` if the tile was added.
    @discardableResult
    public func addToFolder(_ tileID: AnyHashable, folderID: AnyHashable) -> Bool {
        guard store.addToFolder(tileID, folderID: folderID, columns: storeColumns) else {
            notifyGroupingFailure(.addToFolder, tileID: tileID, folderID: folderID)
            return false
        }

        // The tile's cell was left as a hole; the empty row collapses.
        store.collapseEmptyRows(columns: storeColumns)
        render(animated: true)
        delegate?.tileEditCoordinator(self, didAdd: tileID, toFolder: folderID)
        postLayoutChanged(focusing: folderID)
        announce(TesseraStartScreenStrings.string(.a11yFolderTileAdded))
        return true
    }

    /// Renames a folder (D35).
    ///
    /// The same path as the built-in name editing in an open panel:
    /// ``TesseraTileStore/renameFolder(_:to:)`` (normalization, the limit
    /// ``TesseraTileFolder/maximumTitleLength``), grid synchronization, then the delegate
    /// (`didRenameFolder`). An empty name returns the **default name** — the same
    /// as for a new folder: ``TesseraTileEditConfiguration/folderTitle`` if it is
    /// set, otherwise the localized default "Folder". The size, cell and composition do not
    /// change; the operation does not require host approval (D14); it is not
    /// tied to edit mode.
    ///
    /// - Parameters:
    ///   - folderID: The identifier of a folder on the desktop.
    ///   - newTitle: The new name (as typed).
    /// - Returns: `true` if the name changed; `false` if there is no such folder or the name is the same.
    @discardableResult
    public func renameFolder(_ folderID: AnyHashable, to newTitle: String) -> Bool {
        let normalized = TesseraTileFolder.normalizedTitle(newTitle)
        let requested = normalized.isEmpty
            ? resolvedNewFolderTitle(configuration.folderTitle)
            : normalized
        guard store.renameFolder(folderID, to: requested) else { return false }

        render(animated: false)
        let stored = store.snapshot(columns: storeColumns).folders
            .first { $0.id == folderID }?.title ?? requested
        delegate?.tileEditCoordinator(self, didRenameFolder: folderID, to: stored)
        return true
    }

    /// Reorders a tile inside its folder (D40).
    ///
    /// The same path as a drop inside an open panel and the VoiceOver
    /// "Move earlier/later" actions: ``TesseraTileStore/moveWithinFolder(_:folderID:toIndex:)``
    /// (the index is among the folder's tiles, an out-of-bounds value is clamped), grid
    /// synchronization (the panel is reconfigured in place, the folder's preview icons take the
    /// new order), the delegate's `didReorderTile`, announcing the new position and
    /// VoiceOver focus on the tile in its new panel cell. The folder composition and
    /// the desktop cells do not change, so the operation does not require
    /// host approval (D14). It is not tied to edit mode; it is not
    /// performed during a drag (the drag session's model must not change).
    ///
    /// - Parameters:
    ///   - tileID: A tile in a folder.
    ///   - index: The new index among the folder's tiles.
    /// - Returns: `true` if the order changed; `false` if the tile is not in the folder,
    ///   the position does not change, or a drag is in progress.
    @discardableResult
    public func moveWithinFolder(_ tileID: AnyHashable, to index: Int) -> Bool {
        guard dragSession == nil, let folder = store.folderContaining(tileID) else { return false }
        guard store.moveWithinFolder(tileID, folderID: folder.id, toIndex: index) else { return false }

        render(animated: false)
        finishReorder(of: tileID, inFolder: folder.id)
        return true
    }

    /// The shared tail of reordering inside a folder: the delegate, announcement,
    /// focus. Called after the model and the grid already show the new
    /// order.
    ///
    /// - Parameters:
    ///   - tileID: The reordered tile.
    ///   - folderID: Its folder.
    private func finishReorder(of tileID: AnyHashable, inFolder folderID: AnyHashable) {
        let tiles = store.folderContaining(tileID)?.tiles ?? []
        let position = tiles.firstIndex { $0.id == tileID } ?? 0
        delegate?.tileEditCoordinator(
            self,
            didReorderTile: tileID,
            inFolder: folderID,
            toIndex: position
        )
        announce(
            String(
                format: TesseraStartScreenStrings.string(.a11yFolderTilePositionFormat),
                position + 1,
                tiles.count
            )
        )
        // Focus stays on the reordered tile — now in a different panel
        // cell; if there is no panel, the folder tile receives the focus.
        postLayoutChanged(afterUnpinning: .panelTile(tileID, folderID: folderID))
    }

    /// Sets or removes the grid's rename handler: an active
    /// coordinator wires up in-panel name editing, a disabled one does not.
    private func updateRenameHandler() {
        if isEnabled {
            grid.folderRenameHandler = { [weak self] folderID, name in
                self?.renameFolder(folderID, to: name)
            }
        } else {
            grid.folderRenameHandler = nil
        }
    }

    /// Moves a tile between folders or from a folder to the desktop (D14).
    ///
    /// A take-out to the desktop goes by cells
    /// (``TesseraTileStore/extractFromFolder(_:toCell:columns:)``): the tile takes the
    /// folder's cell (if it is the last one in it) or the first free cell
    /// after the folder's cell in reading order (after a folder dissolution, see below —
    /// taking into account the tile that took its place). A move to another folder is
    /// ``TesseraTileStore/moveBetweenFolders(_:to:columns:)``. After the operation
    /// an empty row collapses, and VoiceOver focus goes to the tile.
    ///
    /// D45: if the source folder had two tiles, it is dissolved — the remaining
    /// tile takes its place with its own size, the expanded panel closes, and the
    /// delegate receives `didDissolveFolder` after `didMove`.
    ///
    /// - Parameters:
    ///   - tileID: A tile in a folder.
    ///   - folderID: The target folder; `nil` means the desktop.
    /// - Returns: `true` if the move was performed.
    @discardableResult
    public func moveBetweenFolders(_ tileID: AnyHashable, to folderID: AnyHashable?) -> Bool {
        let columns = storeColumns
        let dissolution = dissolutionPlan(whenRemoving: tileID)
        let moved: Bool
        if let folderID {
            moved = store.moveBetweenFolders(tileID, to: folderID, columns: columns)
        } else if let cell = extractionCell(forTile: tileID, columns: columns) {
            moved = store.extractFromFolder(tileID, toCell: cell, columns: columns)
        } else {
            moved = store.extractFromFolderToNewRow(tileID, columns: columns)
        }
        guard moved else {
            notifyGroupingFailure(.moveBetweenFolders, tileID: tileID, folderID: folderID)
            return false
        }

        store.collapseEmptyRows(columns: columns)
        closePanel(ofDissolving: dissolution)
        render(animated: true)
        // A single callback with the cell (by default it forwards to
        // `didMove(_:toFolder:)`).
        delegate?.tileEditCoordinator(
            self,
            didMove: tileID,
            toFolder: folderID,
            atCell: folderID == nil ? store.placements(forColumns: columns)[tileID] : nil
        )
        notifyDissolution(dissolution)
        // The decision is made from the model, not the grid: when the dissolved folder's
        // panel closes the grid defers the snapshot, and the taken-out tile is not in it yet.
        if folderID == nil {
            postLayoutChanged(focusing: tileID)
        } else if let folderID = folderID {
            postLayoutChanged(focusing: folderID)
        }
        announce(TesseraStartScreenStrings.string(folderID == nil ? .a11yFolderTileOnStart : .a11yFolderTileMoved))
        return true
    }

    /// The cell for a tile taken out of a folder without a gesture.
    ///
    /// - Parameters:
    ///   - tileID: A tile in a folder.
    ///   - columns: The number of grid columns.
    /// - Returns: The source folder's cell if the tile is the last one in it (the folder
    ///   will disappear), otherwise the first free cell after it; `nil` means only
    ///   a new row fits (there is no source folder).
    private func extractionCell(
        forTile tileID: AnyHashable,
        columns: Int
    ) -> TesseraTileGridPlacement? {
        let snapshot = store.snapshot(columns: columns)
        let placed = placedItems(of: snapshot)

        guard let folder = store.folderContaining(tileID),
              let folderCell = placed.first(where: { $0.id == folder.id })?.cell,
              let tile = folder.tiles.first(where: { $0.id == tileID }) else {
            return nil
        }
        // The folder's last tile: the folder will disappear and the tile takes its cell.
        if folder.tiles.count == 1 { return folderCell }
        // D45: when one tile leaves a two-tile folder, the folder dissolves and the remaining
        // tile takes its cell with its own size; the free cell is searched for in
        // that layout, so the taken-out tile does not land on the remaining one.
        var layout = placed
        if folder.tiles.count == 2, let remaining = folder.tiles.first(where: { $0.id != tileID }) {
            layout = TesseraTileLayoutEngine.inserting(
                id: remaining.id,
                size: remaining.size,
                at: folderCell,
                into: TesseraTileLayoutEngine.removing(id: folder.id, from: placed),
                columns: columns
            )
        }
        return firstFreeCell(for: tile.size, after: folderCell, in: layout, columns: columns)
    }

    /// Activates a tile from the built-in folder screen through the shared grid route
    ///
    /// A tap on a tile inside `TesseraFolderViewController` is an event of
    /// ``TesseraTileGridView/onTap``, not a direct call of `TesseraTileDescriptor.action`:
    /// the host receives the tap once and through the same route as a tap on a
    /// grid tile. In edit mode the action is not performed (the tap
    /// belongs to the coordinator).
    ///
    /// - Parameter tile: A tile from the folder's content.
    /// - Returns: `true` if the event was passed to the host.
    @discardableResult
    func activateTileFromFolder(_ tile: TesseraTileDescriptor) -> Bool {
        guard !isEditing else { return false }
        grid.forwardTileTap(tile)
        return true
    }

    /// Opens the folder screen.
    ///
    /// If ``onFolderOpen`` is set, the folder is handed to the host. Otherwise the
    /// minimal `TesseraFolderViewController` (a sheet) is shown with the folder content:
    /// a tap opens a tile, a long press opens a menu for moving between folders
    /// (through ``moveBetweenFolders(_:to:)``, that is, with host approval).
    ///
    /// - Parameter folder: A folder from the `TesseraTileStore` snapshot.
    public func openFolder(_ folder: TesseraTileFolder) {
        if let onFolderOpen {
            onFolderOpen(folder)
            return
        }

        guard let presenter = presentingViewController() else { return }

        // The folder in the snapshot may have changed between the tap and the opening.
        let fresh = store.snapshot().folders.first { $0.id == folder.id } ?? folder
        let controller = TesseraFolderViewController(
            folder: fresh,
            store: store,
            coordinator: self
        )
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(controller, animated: !isReduceMotionEnabled())
    }

    /// The controller to present the folder screen from.
    ///
    /// - Returns: The nearest `UIViewController` up from the grid, or the host's provider.
    private func presentingViewController() -> UIViewController? {
        if let provider = presentingViewControllerProvider {
            return provider()
        }

        var responder: UIResponder? = grid
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller
            }
            responder = current.next
        }
        return nil
    }

    /// Reports a rejection by the approval function to the host (D14).
    ///
    /// - Parameters:
    ///   - action: The rejected operation.
    ///   - tileID: The initiating tile.
    ///   - folderID: The target folder; `nil` for creation.
    private func notifyGroupingFailure(
        _ action: TesseraTileGroupingAction,
        tileID: AnyHashable,
        folderID: AnyHashable?
    ) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        announce(TesseraStartScreenStrings.string(.a11yFolderUnavailable))
        delegate?.tileEditCoordinator(
            self,
            didFailGrouping: action,
            tileID: tileID,
            folderID: folderID
        )
    }

    // MARK: - Folder dissolution (D45)

    /// The dissolution of a folder that a tile leaving it will cause (D45).
    private struct FolderDissolutionPlan {

        /// The folder with two tiles.
        let folderID: AnyHashable

        /// The tile that will remain and take its place.
        let remainingTileID: AnyHashable
    }

    /// Where VoiceOver focus goes after an unpin (D45).
    private enum UnpinFocus {

        /// The tile was on the grid: the reading-order neighbor (`nil` means no target).
        case gridItem(AnyHashable?)

        /// The folder dissolved: the remaining tile that became a grid element.
        case dissolvedTile(AnyHashable)

        /// The folder survived the unpin: a neighboring tile of its panel.
        case panelTile(AnyHashable, folderID: AnyHashable)
    }

    /// Whether a folder will dissolve if a tile is removed from it (D45).
    ///
    /// A folder with two tiles dissolves after losing one (``TesseraTileStore``:
    /// `minimumFolderTileCount`). It is computed **before** the store operation, from its
    /// snapshot: after the operation the folder is no longer in the model.
    ///
    /// - Parameter tileID: The tile that will leave the folder.
    /// - Returns: The dissolution plan, or `nil` (the tile is not in a folder or the folder survives the departure).
    private func dissolutionPlan(whenRemoving tileID: AnyHashable) -> FolderDissolutionPlan? {
        guard let folder = store.folderContaining(tileID),
              folder.tiles.count == 2,
              let remaining = folder.tiles.first(where: { $0.id != tileID }) else {
            return nil
        }
        return FolderDissolutionPlan(folderID: folder.id, remainingTileID: remaining.id)
    }

    /// Closes the expanded folder panel that is about to dissolve (D45).
    ///
    /// Called **before** `render`: while the grid shows the previous snapshot, the regular
    /// `closeFolder` animates the close (instantly with Reduce Motion and outside
    /// a window), and the grid defers the snapshot without the folder until the transition ends.
    ///
    /// - Parameter plan: The dissolution plan.
    private func closePanel(ofDissolving plan: FolderDissolutionPlan?) {
        guard let plan, grid.expandedFolderID == plan.folderID else { return }
        grid.closeFolder(animated: !isReduceMotionEnabled())
    }

    /// Notifies the delegate about the dissolution of the drag session's source folder after a successful
    /// drop (D45): a folder dissolves if it had two tiles.
    private func notifyDissolution(of session: TesseraTileDragSession) {
        guard let dissolution = session.folderDissolution else { return }
        delegate?.tileEditCoordinator(
            self,
            didDissolveFolder: dissolution.folderID,
            remainingTile: dissolution.remaining.id
        )
    }

    /// Notifies the delegate about a folder dissolution after a successful operation (D45).
    private func notifyDissolution(_ plan: FolderDissolutionPlan?) {
        guard let plan else { return }
        delegate?.tileEditCoordinator(
            self,
            didDissolveFolder: plan.folderID,
            remainingTile: plan.remainingTileID
        )
    }

    /// The VoiceOver focus target after a tile is unpinned (D45).
    ///
    /// - Parameters:
    ///   - tileID: The tile being unpinned.
    ///   - dissolution: The dissolution plan of its folder, if it dissolves.
    /// - Returns: The target: the remaining tile of a dissolved folder; a neighboring
    ///   panel tile (the next in display order, the previous for the last one);
    ///   for a grid tile, the reading-order neighbor (``focusTarget(afterRemoving:)``).
    private func unpinFocus(for tileID: AnyHashable, dissolution: FolderDissolutionPlan?) -> UnpinFocus {
        if let dissolution { return .dissolvedTile(dissolution.remainingTileID) }
        if let folder = store.folderContaining(tileID) {
            let tiles = folder.tiles
            if let index = tiles.firstIndex(where: { $0.id == tileID }) {
                if tiles.indices.contains(index + 1) { return .panelTile(tiles[index + 1].id, folderID: folder.id) }
                if index > 0 { return .panelTile(tiles[index - 1].id, folderID: folder.id) }
            }
            // The only tile of a transitional folder: the folder disappears without a remainder.
            return .gridItem(nil)
        }
        return .gridItem(focusTarget(afterRemoving: tileID))
    }

    // MARK: - Applying the snapshot

    /// Applies the model to the grid if the host has not already done so from `onChange`.
    ///
    /// The comparison is cheap and avoids a double update: a typical host
    /// subscribes to ``TesseraTileStore/onChange`` and calls
    /// `update(snapshot:animated:)` itself, while the coordinator calls this method right
    /// after a mutation.
    ///
    /// - Parameter animated: Whether to animate the reorder/resize.
    private func render(animated: Bool) {
        let snapshot = modelSnapshot()

        // While a folder panel transition is in progress the grid may have
        // a deferred (pending) snapshot; the model snapshot is always passed
        // to replace it (last wins).
        if !gridMatches(snapshot) || grid.isFolderChangeAnimating {
            grid.update(snapshot: snapshot, animated: animated && !isReduceMotionEnabled())
        }

        if isEditing {
            reconcileEditControls(animated: animated)
            // The collection creates new cells in its own layout pass: a repeated
            // reconcile after it adds custom actions and the jiggle to them.
            scheduleReconcile()
        }
    }

    /// The number of columns for store operations: the grid's real width.
    ///
    /// Cells are stored on a canvas of this width (D32), so it is passed to all
    /// cell-based operations and to the `snapshot(columns:)` snapshot.
    private var storeColumns: Int {
        max(1, grid.columns)
    }

    /// The model snapshot for the grid: the order, sizes, folders and the cell table for
    /// the grid width (``TesseraTileStore/snapshot(columns:)``).
    private func modelSnapshot() -> TesseraTileGridSnapshot {
        store.snapshot(columns: storeColumns)
    }

    /// Whether the current grid snapshot matches the model (the order, sizes, folders and
    /// cells).
    ///
    /// - Parameter snapshot: A snapshot from `TesseraTileStore`.
    /// - Returns: `true` if there is nothing for the grid to update.
    private func gridMatches(_ snapshot: TesseraTileGridSnapshot) -> Bool {
        gridItemsMatch(snapshot) && gridPlacementsMatch(snapshot)
    }

    /// Whether the grid's order, sizes and folders match the model (without cells).
    ///
    /// - Parameter snapshot: A snapshot from `TesseraTileStore`.
    /// - Returns: `true` if the composition and the folder contents are the same.
    private func gridItemsMatch(_ snapshot: TesseraTileGridSnapshot) -> Bool {
        // The grid keeps elements in the cell reading order; the expected snapshot
        // is brought to it by the same rule.
        let expectedItems = grid.readingOrdered(snapshot).items
        let currentItems = grid.items
        guard currentItems.count == expectedItems.count else { return false }

        for (current, expected) in zip(currentItems, expectedItems) {
            guard current.id == expected.id, current.size == expected.size else {
                return false
            }
            if let currentFolder = current.folder, let expectedFolder = expected.folder {
                guard currentFolder.title == expectedFolder.title,
                      currentFolder.tiles.map({ $0.id }) == expectedFolder.tiles.map({ $0.id }) else {
                    return false
                }
            }
        }
        return true
    }

    /// Whether the grid shows the same cell table as the snapshot.
    ///
    /// Without it a preview in which only the cells changed (the same elements in the same
    /// order) would look like "nothing changed" and be silently discarded.
    ///
    /// - Parameter snapshot: The expected snapshot.
    /// - Returns: `true` if the tables are equal (including both being absent).
    private func gridPlacementsMatch(_ snapshot: TesseraTileGridSnapshot) -> Bool {
        grid.snapshot?.placementTable == snapshot.placementTable
    }

    // MARK: - Synchronization and accessibility

    /// Tells `TesseraTileStore` the grid width (D33).
    ///
    /// The store learns the width only from the host: it uses it to assign cells
    /// to a version 1 file and to the first-launch layout (``TesseraTileStore/placeItems(columns:)``,
    /// once and without notifying subscribers), and then recomputes cells
    /// after operations. Called when the coordinator is created and on entering
    /// edit mode/drag.
    private func reportGridWidthToStore() {
        guard grid.columns > 0 else { return }
        store.placeItems(columns: grid.columns)
    }

    /// Prepares the model and the grid for editing.
    ///
    /// Tells the store the grid width and, if the grid shows the same elements
    /// but without the model's cell table (the host built it from `snapshot()` or
    /// ``TesseraTileStore/snapshot(columns:)`` with a different width), pulls it in
    /// without animation: drag targets and previews are computed from cells, and they must
    /// match the frames on screen. A composition mismatch introduced by the host
    /// is still caught by the consistency check at the grab.
    private func prepareModelForEditing() {
        reportGridWidthToStore()
        let snapshot = modelSnapshot()
        guard gridItemsMatch(snapshot), !gridPlacementsMatch(snapshot) else { return }
        grid.update(snapshot: snapshot, animated: false)
        // A cell change is applied as a collection batch: the frames are needed immediately —
        // the drag grab in this same runloop pass relies on them.
        grid.layoutIfNeeded()
    }

    /// The reaction to a change in the grid's column count (D32).
    ///
    /// The store learns the width; during editing the grid is rebuilt for it
    /// (for a different canvas width — a projection in reading order without holes), and
    /// a drag in progress is cancelled: its base was computed with the previous columns.
    private func gridColumnsDidChange() {
        reportGridWidthToStore()
        guard isEditing else { return }
        if dragSession != nil {
            cancelDragForExternalChange()
        } else {
            syncGridWithModel(animated: false)
            reconcileEditControls(animated: false)
        }
    }

    /// Applies the current model snapshot to the grid.
    ///
    /// The source of truth is ``TesseraTileStore``: after external changes and on a
    /// drag cancel the grid is brought to the current snapshot rather than to the stale grab
    /// base.
    ///
    /// Even if the grid already shows this order, during
    /// a folder panel animation it may hold a deferred (pending)
    /// snapshot — for example, the last step of a drag preview. `grid.update` replaces it
    /// by the last-wins rule, so the model snapshot is always passed
    /// while the panel transition is in progress: otherwise, after the animation ends the grid
    /// would apply the stale preview, and the visible order would diverge from
    /// the model.
    ///
    /// - Parameter animated: Whether to animate the reorder.
    private func syncGridWithModel(animated: Bool) {
        let snapshot = modelSnapshot()
        guard !gridMatches(snapshot) || grid.isFolderChangeAnimating else { return }
        grid.update(snapshot: snapshot, animated: animated && !isReduceMotionEnabled())
    }

    /// Posts `.layoutChanged` with the focus on an element.
    ///
    /// The post is deferred to the next runloop pass: by then the collection
    /// has laid out the new frames, and the argument cell exists. A synchronous post
    /// from a batch-update callback could point at a removed element.
    ///
    /// - Parameter itemID: The element the focus should move to; `nil` means no
    ///   argument.
    private func postLayoutChanged(focusing itemID: AnyHashable?) {
        // D45: if the panel of a dissolved folder is closing, the post waits for the end of the
        // transition and of the deferred snapshot (the grid itself puts focus on the folder
        // tile, which no longer exists); a calm grid takes the same single runloop pass.
        grid.performAfterFolderTransition { [weak self] in
            guard let self else { return }
            let argument = itemID.flatMap { self.grid.cellView(forItemID: $0) }
            self.accessibilityNotificationPoster(.layoutChanged, argument)
        }
    }

    /// The element VoiceOver focus will move to after an unpin.
    ///
    /// The grid order is the cell reading order (row, then column), so
    /// "next" is the next element in it: it stays on the grid after
    /// the unpin (an unpin moves nobody, and collapsing an empty row
    /// and pushing down do not change the order of the remaining ones). If the tile being unpinned was
    /// the last, the previous one is taken. With no neighbors, and for a tile that is not on
    /// the grid (it is in a folder), there is no target — `nil`.
    ///
    /// - Parameter itemID: The tile being unpinned.
    /// - Returns: The identifier of the neighboring element, or `nil`.
    private func focusTarget(afterRemoving itemID: AnyHashable) -> AnyHashable? {
        let items = grid.items
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return nil }
        if items.indices.contains(index + 1) { return items[index + 1].id }
        if index > 0 { return items[index - 1].id }
        return nil
    }

    /// Posts `.layoutChanged` after an unpin.
    ///
    /// The post is deferred to the next runloop pass: by then the
    /// grid has applied the snapshot and the focus cell exists. The target is the
    /// neighbor chosen in advance (``focusTarget(afterRemoving:)``); if it is no longer on the
    /// grid or there was no target (a tile from a folder), the focus goes to the last
    /// grid element, and if the grid is empty — to the grid itself. Focus never
    /// moves to a removed element.
    ///
    /// - Parameter focusID: The neighbor chosen in advance; `nil` means no target.
    private func postLayoutChanged(afterUnpinningFocusing focusID: AnyHashable?) {
        grid.performAfterFolderTransition { [weak self] in
            guard let self else { return }
            let items = self.grid.items
            let resolvedID: AnyHashable?
            if let focusID, items.contains(where: { $0.id == focusID }) {
                resolvedID = focusID
            } else {
                resolvedID = items.last?.id
            }
            let argument: Any? = resolvedID.flatMap { self.grid.cellView(forItemID: $0) }
                ?? (items.isEmpty ? self.grid : nil)
            self.accessibilityNotificationPoster(.layoutChanged, argument)
        }
    }

    /// Posts `.layoutChanged` after an unpin for a pre-selected target (D45).
    ///
    /// The "grid neighbor" and "remaining tile of a dissolved folder" targets are grid
    /// elements (``postLayoutChanged(afterUnpinningFocusing:)``). The "panel tile" target is
    /// a cell of the expanded folder's panel; if there is no panel (it is closed) or the cell
    /// does not exist yet, the focus goes to the folder tile, and if that is absent — the same
    /// fallback path as for the grid. The post happens on the next runloop pass.
    ///
    /// - Parameter focus: The focus target.
    private func postLayoutChanged(afterUnpinning focus: UnpinFocus) {
        switch focus {
        case .gridItem(let itemID):
            postLayoutChanged(afterUnpinningFocusing: itemID)
        case .dissolvedTile(let itemID):
            postLayoutChanged(afterUnpinningFocusing: itemID)
        case .panelTile(let tileID, let folderID):
            grid.performAfterFolderTransition { [weak self] in
                guard let self else { return }
                if let panel = self.grid.panelShortcuts(),
                   panel.folder.id == folderID,
                   let index = panel.folder.tiles.firstIndex(where: { $0.id == tileID }),
                   panel.cells.indices.contains(index) {
                    self.accessibilityNotificationPoster(.layoutChanged, panel.cells[index])
                    return
                }
                if let folderCell = self.grid.cellView(forItemID: folderID) {
                    self.accessibilityNotificationPoster(.layoutChanged, folderCell)
                    return
                }
                let items = self.grid.items
                let argument: Any? = items.last.flatMap { self.grid.cellView(forItemID: $0.id) }
                    ?? (items.isEmpty ? self.grid : nil)
                self.accessibilityNotificationPoster(.layoutChanged, argument)
            }
        }
    }

    // MARK: - Drag session consistency

    /// Whether the model matches the drag base structurally.
    ///
    /// Identifiers, sizes, folder contents and cells are compared:
    /// badges/labels do not change the layout, and a drag
    /// must not be cancelled because of them.
    ///
    /// - Parameter session: The active drag session.
    /// - Returns: `true` if the model is still the one from the grab.
    private func modelMatchesBase(_ session: TesseraTileDragSession) -> Bool {
        // For a drag from a folder the preview base contains a synthetic tile, and
        // the model does not match it — compare against the real model snapshot.
        let base = session.modelBaseSnapshot.items
        let current = store.snapshot().items
        guard base.count == current.count else { return false }
        // Cells are part of the model; someone else's edit that only moved
        // tiles also makes the base stale.
        guard store.placements(forColumns: session.columns) == session.modelPlacements else {
            return false
        }

        for (baseItem, currentItem) in zip(base, current) {
            guard baseItem.id == currentItem.id, baseItem.size == currentItem.size else {
                return false
            }
            guard (baseItem.folder == nil) == (currentItem.folder == nil) else { return false }
            let baseTiles = baseItem.folder?.tiles.map { $0.id } ?? []
            let currentTiles = currentItem.folder?.tiles.map { $0.id } ?? []
            guard baseTiles == currentTiles else { return false }
        }
        return true
    }

    /// Whether the grid shows exactly this order and set of elements.
    ///
    /// Identifiers, their order, sizes and the cell table are compared:
    /// this is what a preview and a `TesseraTileStore` snapshot do. Badges/labels are not included.
    ///
    /// - Parameter snapshot: The expected snapshot.
    /// - Returns: `true` if the grid shows it.
    private func gridMatchesDragSnapshot(_ snapshot: TesseraTileGridSnapshot) -> Bool {
        let current = grid.items
        // See `gridItemsMatch` — the grid order is the cell reading order.
        let expectedItems = grid.readingOrdered(snapshot).items
        guard current.count == expectedItems.count else { return false }

        for (currentItem, expectedItem) in zip(current, expectedItems) {
            guard currentItem.id == expectedItem.id,
                  currentItem.size == expectedItem.size else {
                return false
            }
        }
        return gridPlacementsMatch(snapshot)
    }

    /// Whether the drag session is consistent with the model and the grid.
    ///
    /// The grid must show either the last preview applied by the coordinator
    /// (``TesseraTileDragSession/expectedSnapshot``) or a deferred one — the grid
    /// may have remembered it during the folder panel animation and apply it later.
    /// Any other order/set is an external `grid.update` bypassing the coordinator.
    /// A deferred preview that matches becomes the expected one.
    ///
    /// - Parameter session: The active drag session.
    /// - Returns: `true` if the drag can continue.
    private func dragStateIsConsistent(_ session: TesseraTileDragSession) -> Bool {
        if storeChangedDuringDrag, !modelMatchesBase(session) {
            return false
        }
        if gridMatchesDragSnapshot(session.expectedSnapshot) {
            return true
        }
        if let pending = session.pendingSnapshot, gridMatchesDragSnapshot(pending) {
            session.expectedSnapshot = pending
            session.pendingSnapshot = nil
            return true
        }
        return false
    }

    /// Safely cancels a drag on an external model/snapshot change.
    ///
    /// The order matters: first the session and its overlays are torn down, then the grid
    /// is brought to the current model — so the cancel does not roll back someone else's changes
    /// to the stale grab snapshot. An external mutation may have happened while
    /// autosave was disabled by the drag transaction, so it is saved.
    private func cancelDragForExternalChange() {
        guard let session = dragSession else { return }

        stopTicker()
        resetMergeHover()
        resetReorderDwell()
        stopMagnetAnimation(session)
        session.magnetTarget = nil
        dragSession = nil
        storeChangedDuringDrag = false

        grid.isScrollEnabled = true
        hideDropHighlight()
        session.dragView.removeFromSuperview()
        session.placeholder.removeFromSuperview()
        stopPlaceholderAnimation()
        grid.setItemHidden(false, forItemID: session.itemID)
        if session.panelReorder != nil { grid.endPanelReorder() }

        syncGridWithModel(animated: true)
        reconcileEditControls(animated: false)
        endDragStoreTransaction(saveIfNeeded: true)
        announce(TesseraStartScreenStrings.string(.a11yDragCancelled))
    }

    // MARK: - Drag: start and movement

    /// Lifts a tile and starts a drag.
    ///
    /// Takes a copy of the cell **before** hiding it, puts a placeholder in its place and hangs
    /// the snapshot over the grid. The model does not change at this step.
    ///
    /// The model snapshot with cells is also captured here — the base for
    /// hit testing, the preview and the rollback. `TesseraTileStore` is not written during a drag, so
    /// these cells stay in the model until the drop itself.
    ///
    /// The snapshot is always at full brightness — if the tile was in the dim field
    /// (editing started from an empty spot), the transparency is removed before
    /// the copy is taken, otherwise the copy would have alpha 0.7.
    ///
    /// - Parameters:
    ///   - itemID: The identifier of a tile or folder.
    ///   - point: The grab point in grid coordinates.
    private func startDrag(itemID: AnyHashable, at point: CGPoint) {
        guard dragSession == nil else { return }

        // The host contract: by the time of the grab the grid must
        // show the current `TesseraTileStore` snapshot. If the snapshot and the model
        // have diverged (an external update bypassing the coordinator, a store
        // snapshot that was not applied), the drag does not start: otherwise the preview would be computed from
        // someone else's base, and the drop/cancel could diverge from the model. In DEBUG
        // a contract violation shows up as an assertion rather than as a "swallowed"
        // long-press.
        // The host may have shown the same elements without a cell table — pull it
        // in before the comparison (otherwise hit testing would use different frames).
        prepareModelForEditing()
        let modelSnapshot = self.modelSnapshot()
        if !gridMatches(modelSnapshot) {
            #if DEBUG
            assertionFailure(
                "TesseraTileEditCoordinator.startDrag: the grid snapshot does not match "
                    + "the TesseraTileStore model at capture time; the drag will not begin. "
                    + "The host must apply store snapshots to the grid."
            )
            #endif
            return
        }
        guard let item = grid.items.first(where: { $0.id == itemID }),
              let frame = grid.frame(forItemID: itemID),
              frame.intersects(grid.bounds),
              let placeholder = grid.placeholderView(forItemID: itemID) else {
            return
        }

        // The tile under the finger becomes "selected" and gets full brightness.
        // The jiggle is removed before the snapshot: the copy must inherit neither the dimming nor
        // the current sway angle. The grid changes the transparency — it owns the dimming.
        if let cell = grid.cellView(forItemID: itemID) as? TesseraTileCell {
            cell.contentView.layer.removeAnimation(forKey: TesseraTileEditCoordinator.jiggleKey)
        }
        grid.setEditDimming([itemID: 1], animated: false)
        guard let dragView = makeDragView(forItemID: itemID) else {
            // The snapshot failed: restore the dimming so the tile does not stay brighter
            // than its neighbors without a drag having started.
            applyEditDimming(animated: false)
            return
        }
        dimmingFocusID = itemID

        installDragSession(
            itemID: itemID,
            isTile: item.tile != nil,
            slotFrame: frame,
            liftFrame: frame,
            placeholder: placeholder,
            dragView: dragView,
            point: point,
            baseSnapshot: modelSnapshot,
            basePlacements: placedItems(of: modelSnapshot),
            modelBaseSnapshot: nil,
            sourceFolderID: nil,
            magnetSize: item.size
        )
    }

    /// Lifts a tile from the expanded folder's panel and starts a drag.
    ///
    /// The drag source is the folder (``TesseraTileDragSession/sourceFolderID``), not a
    /// grid element. The model does not change during the drag: the grid is shown the
    /// **display** snapshot — the model one in which the tile is removed from the folder's composition and
    /// inserted as a separate tile. The synthetic tile has no base
    /// cell in the model — it takes the first free cell after the folder's
    /// cell (``firstFreeCell(for:after:in:columns:)``), so the placeholder and the
    /// preview work as for a regular tile; the targets are the same as for a drag on the grid.
    /// The model check (``modelMatchesBase(_:)``) uses the real snapshot and the
    /// real cells.
    ///
    /// The panel closes **instantly** (as in any drag started by a long press): the icon snapshot is taken before
    /// closing, and the icon frame and the grab offset are computed in the same
    /// coordinates, so the tile stays under the finger.
    ///
    /// - Parameter point: The press point in grid coordinates.
    func startDragFromPanel(at point: CGPoint) {
        guard dragSession == nil, isEditing,
              let hit = grid.panelTile(at: point) else {
            return
        }
        startDragFromPanel(hit: hit, at: point)
    }

    /// Takes a tile out of the panel for an already found tile.
    ///
    /// - Parameters:
    ///   - hit: The panel tile under the finger (snapshot, frame, folder).
    ///   - point: The finger point in grid coordinates.
    ///   - isHandover: The take-out starts from a reorder inside the panel:
    ///     the snapshot is already lifted and follows the finger, so the lift is
    ///     not repeated (neither the scale nor the haptic).
    private func startDragFromPanel(hit: TesseraPanelTileHit, at point: CGPoint, isHandover: Bool = false) {
        // The host contract — the grid shows the current model snapshot.
        prepareModelForEditing()
        let modelSnapshot = self.modelSnapshot()
        guard gridMatches(modelSnapshot) else {
            #if DEBUG
            assertionFailure(
                "TesseraTileEditCoordinator.startDragFromPanel: the grid snapshot "
                    + "differs from the TesseraTileStore model at grab time; drag will not "
                    + "start."
            )
            #endif
            return
        }
        var items = modelSnapshot.items
        guard let folderIndex = items.firstIndex(where: { $0.folder?.id == hit.folder.id }),
              var displayFolder = items[folderIndex].folder,
              displayFolder.tiles.contains(where: { $0.id == hit.tile.id }) else {
            return
        }

        // The display snapshot: the tile is pulled out of the folder and sits right after it in
        // the snapshot order, and on the grid — on a free cell after the folder. The size
        // is taken from the descriptor, as `TesseraTileStore` will resolve it on take-out.
        let modelPlaced = placedItems(of: modelSnapshot)
        guard let folderCell = modelPlaced.first(where: { $0.id == hit.folder.id })?.cell else {
            return
        }
        let tileCell = firstFreeCell(
            for: hit.tile.size,
            after: folderCell,
            in: modelPlaced,
            columns: storeColumns
        )
        var displayCells: [AnyHashable: TesseraTileGridPlacement] = [:]
        for placed in modelPlaced { displayCells[placed.id] = placed.cell }
        displayCells[hit.tile.id] = tileCell

        displayFolder.tiles.removeAll { $0.id == hit.tile.id }
        items[folderIndex] = .folder(displayFolder)
        items.insert(.tile(hit.tile), at: folderIndex + 1)
        let displaySnapshot = TesseraTileGridSnapshot(
            items: items,
            unpinned: modelSnapshot.unpinned,
            placementTable: TesseraTileGridPlacementTable(cells: displayCells, columns: storeColumns)
        )
        let displayPlaced = modelPlaced + [
            TesseraTilePlacedItem(id: hit.tile.id, size: hit.tile.size, cell: tileCell),
        ]

        // D45: taking one tile out of a two-tile folder dissolves it — prepare
        // the "resulting picture" (the remaining tile on the folder's cell) for the preview. `TesseraTileStore`
        // does the same steps: without the taken-out tile and without the folder, the remaining one on
        // the folder's cell via `inserting`.
        var dissolution: DragFolderDissolution?
        if let modelFolder = modelSnapshot.folders.first(where: { $0.id == hit.folder.id }),
           modelFolder.tiles.count == 2,
           let remaining = modelFolder.tiles.first(where: { $0.id != hit.tile.id }) {
            var dissolvedItems = displaySnapshot.items
            if let index = dissolvedItems.firstIndex(where: { $0.folder?.id == hit.folder.id }) {
                dissolvedItems[index] = .tile(remaining)
            }
            dissolution = DragFolderDissolution(
                folderID: hit.folder.id,
                remaining: remaining,
                items: dissolvedItems,
                placements: TesseraTileLayoutEngine.inserting(
                    id: remaining.id,
                    size: remaining.size,
                    at: folderCell,
                    into: TesseraTileLayoutEngine.removing(id: hit.folder.id, from: modelPlaced),
                    columns: storeColumns
                )
            )
        }

        // The panel closes instantly — the drag starts right after the long press.
        grid.closeFolder(animated: false)
        guard grid.expandedFolderID == nil else { return }

        dimmingFocusID = hit.tile.id
        grid.update(snapshot: displaySnapshot, animated: !isReduceMotionEnabled())
        guard let slotFrame = grid.frame(forItemID: hit.tile.id),
              let placeholder = grid.placeholderView(forItemID: hit.tile.id) else {
            // The grid did not accept the display snapshot: restore the model.
            syncGridWithModel(animated: false)
            dimmingFocusID = nil
            return
        }

        installDragSession(
            itemID: hit.tile.id,
            isTile: true,
            slotFrame: slotFrame,
            liftFrame: hit.frame,
            placeholder: placeholder,
            dragView: hit.snapshot,
            point: point,
            baseSnapshot: displaySnapshot,
            basePlacements: displayPlaced,
            modelBaseSnapshot: modelSnapshot,
            sourceFolderID: hit.folder.id,
            magnetSize: hit.tile.size,
            folderDissolution: dissolution,
            isHandover: isHandover
        )
    }

    // MARK: - Reordering inside a folder panel (D40)

    /// The margin around the panel within which the finger still reorders a tile
    /// inside it, in pt. Leaving the panel frame plus this margin turns the
    /// drag into a take-out to the desktop (``switchPanelReorderToTakeOut(_:at:)``):
    /// a small margin keeps finger jitter at the panel edge from taking a tile out
    /// by accident.
    static let panelReorderExitMargin: CGFloat = 16

    /// The panel slot under the finger: an index among the folder's tiles.
    ///
    /// The slot under a point is chosen by the **slot frames of the panel layout**
    /// (``TesseraPanelShortcutGeometry/slotFrames``), expanded by half the
    /// gap so that the gaps between tiles are not "dead". Outside the frames
    /// (the title, the margins, the empty space of the last row, the area below the panel)
    /// the slot of the **nearest row** is chosen, and within it the horizontally nearest one:
    /// a finger to the right of the last tile yields the last slot, not a tile
    /// one row up. RTL is accounted for by the frames themselves (the panel columns are mirrored by the layout).
    ///
    /// - Parameters:
    ///   - point: The finger point in grid coordinates.
    ///   - slotFrames: The slot frames in grid coordinates, in the folder's order.
    ///   - spacing: The gap between panel tiles.
    /// - Returns: The slot index; `nil` if there are no slots.
    static func panelReorderSlot(at point: CGPoint, slotFrames: [CGRect], spacing: CGFloat) -> Int? {
        guard !slotFrames.isEmpty else { return nil }
        let half = max(0, spacing) / 2
        var best = 0
        var bestDistance = (dy: CGFloat.greatestFiniteMagnitude, dx: CGFloat.greatestFiniteMagnitude)
        for (index, frame) in slotFrames.enumerated() {
            let expanded = frame.insetBy(dx: -half, dy: -half)
            let dy = max(expanded.minY - point.y, 0, point.y - expanded.maxY)
            let dx = max(expanded.minX - point.x, 0, point.x - expanded.maxX)
            // The row matters more than the column; within the row tolerance the rows are equal.
            let isCloser = dy < bestDistance.dy - 0.01
                || (abs(dy - bestDistance.dy) <= 0.01 && dx < bestDistance.dx)
            if isCloser {
                best = index
                bestDistance = (dy, dx)
            }
        }
        return best
    }

    /// A long press on a tile of an open panel in edit mode.
    ///
    /// If the tile can be reordered (the folder has at least two tiles, the panel
    /// has settled, the geometry is known), a **reorder inside the
    /// panel** starts: the panel stays open, and the finger leaving it turns the drag
    /// into a take-out (``switchPanelReorderToTakeOut(_:at:)``). Otherwise a
    /// take-out starts immediately: the panel closes instantly.
    ///
    /// - Parameter point: The press point in grid coordinates.
    private func startPanelDrag(at point: CGPoint) {
        guard dragSession == nil, isEditing,
              let hit = grid.panelTile(at: point) else {
            return
        }
        if beginPanelReorder(hit: hit, at: point) { return }
        startDragFromPanel(hit: hit, at: point)
    }

    /// Starts a reorder inside the panel.
    ///
    /// The model does not change during the drag: the preview lives only in the panel
    /// (neighbor shift and placeholder), and `TesseraTileStore` is written once, on drop. The tile
    /// snapshot follows the finger over the panel; the tile under it is hidden, and a
    /// placeholder sits in its slot.
    ///
    /// - Parameters:
    ///   - hit: The panel tile under the finger.
    ///   - point: The press point in grid coordinates.
    /// - Returns: `false` if a reorder is impossible — then the caller
    ///   starts a take-out.
    private func beginPanelReorder(hit: TesseraPanelTileHit, at point: CGPoint) -> Bool {
        prepareModelForEditing()
        let modelSnapshot = self.modelSnapshot()
        guard gridMatches(modelSnapshot),
              let geometry = grid.panelShortcutGeometry(),
              geometry.folderID == hit.folder.id,
              geometry.tileIDs.count >= 2,
              geometry.slotFrames.count == geometry.tileIDs.count,
              let sourceIndex = geometry.tileIDs.firstIndex(of: hit.tile.id),
              grid.beginPanelReorder(sourceIndex: sourceIndex) else {
            return false
        }

        dimmingFocusID = hit.tile.id
        let reorder = TesseraPanelReorder(
            folder: hit.folder,
            tile: hit.tile,
            baseTileIDs: geometry.tileIDs,
            sourceIndex: sourceIndex,
            slot: sourceIndex
        )
        installDragSession(
            itemID: hit.tile.id,
            isTile: true,
            slotFrame: geometry.slotFrames[sourceIndex],
            liftFrame: hit.frame,
            placeholder: UIView(),
            dragView: hit.snapshot,
            point: point,
            baseSnapshot: modelSnapshot,
            basePlacements: placedItems(of: modelSnapshot),
            modelBaseSnapshot: nil,
            sourceFolderID: nil,
            magnetSize: hit.tile.size,
            panelReorder: reorder
        )
        return true
    }

    /// A reorder step: the slot under the finger, the neighbor shift, take-out on leaving.
    ///
    /// The slot is computed by ``panelReorderSlot(at:slotFrames:spacing:)`` from the panel
    /// geometry **on the current frame** (the panel may have moved with auto-scroll);
    /// the preview is built from the base order each time. If the finger leaves the
    /// panel frame plus ``panelReorderExitMargin``, the session is replaced by a take-out
    /// (there is no return to reordering within the same drag). A panel that disappeared or
    /// changed cancels the drag, like an external change.
    ///
    /// - Parameters:
    ///   - point: The finger point in grid coordinates.
    ///   - session: The reorder session.
    private func updatePanelReorder(at point: CGPoint, session: TesseraTileDragSession) {
        guard var reorder = session.panelReorder else { return }
        guard let geometry = grid.panelShortcutGeometry(),
              geometry.folderID == reorder.folder.id,
              geometry.tileIDs == reorder.baseTileIDs,
              geometry.slotFrames.count == reorder.baseTileIDs.count else {
            cancelDragForExternalChange()
            return
        }

        let margin = Self.panelReorderExitMargin
        if !geometry.panelFrame.insetBy(dx: -margin, dy: -margin).contains(point) {
            switchPanelReorderToTakeOut(session, at: point)
            return
        }

        if let slot = Self.panelReorderSlot(
            at: point,
            slotFrames: geometry.slotFrames,
            spacing: geometry.spacing
        ), slot != reorder.slot {
            reorder.slot = slot
            session.panelReorder = reorder
            grid.setPanelReorderSlot(slot, animated: !isReduceMotionEnabled())
        }
        session.dragView.center = CGPoint(
            x: point.x + session.grabOffset.x,
            y: point.y + session.grabOffset.y
        )
    }

    /// Turns a reorder into a take-out to the desktop.
    ///
    /// The reorder session is torn down (neighbors return to their slots, the tile
    /// is shown) and a regular take-out from the panel begins right away:
    /// the panel closes instantly, the targets are desktop
    /// cells, merge, and dissolution of a two-tile folder (D45). The same snapshot follows
    /// the finger without lifting again. There is no return to reordering in this drag.
    ///
    /// - Parameters:
    ///   - session: The reorder session.
    ///   - point: The finger point in grid coordinates.
    private func switchPanelReorderToTakeOut(_ session: TesseraTileDragSession, at point: CGPoint) {
        guard let reorder = session.panelReorder else { return }

        stopTicker()
        stopMagnetAnimation(session)
        session.magnetTarget = nil
        dragSession = nil
        grid.endPanelReorder()
        storeChangedDuringDrag = false
        endDragStoreTransaction(saveIfNeeded: false)

        // The frame without the lift transform: the lifted snapshot stays as it is.
        let view = session.dragView
        let size = view.bounds.size
        let lifted = CGRect(
            x: view.center.x - size.width / 2,
            y: view.center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        let hit = TesseraPanelTileHit(
            folder: reorder.folder,
            tile: reorder.tile,
            frame: lifted,
            snapshot: view
        )
        startDragFromPanel(hit: hit, at: point, isHandover: true)
        if dragSession == nil {
            // The take-out did not start (the grid did not accept the display snapshot): the snapshot
            // is removed, and the grid already shows the model.
            view.removeFromSuperview()
            grid.isScrollEnabled = true
            reconcileEditControls(animated: false)
        }
    }

    /// Finishes a reorder inside the panel: a drop or a cancel.
    ///
    /// Called from ``finishDrag(commit:)`` after the consistency check.
    /// A drop on a different slot commits the order with a single
    /// ``TesseraTileStore/moveWithinFolder(_:folderID:toIndex:)`` operation (there is no host approval:
    /// the folder composition does not change), the panel immediately shows the new order in the same
    /// places where the preview showed it (without flicker), and the snapshot "settles" into the
    /// slot; the delegate, announcement and focus are handled by ``finishReorder(of:inFolder:)``.
    /// A drop on its own slot, a cancel and a model refusal return the neighbors to their places,
    /// and the snapshot returns to its original slot; the model and the delegate are not touched.
    ///
    /// - Parameters:
    ///   - session: The reorder session (already detached from ``dragSession``).
    ///   - commit: `true` to commit, `false` to cancel the gesture.
    private func finishPanelReorder(_ session: TesseraTileDragSession, commit: Bool) {
        guard let reorder = session.panelReorder else { return }
        let geometry = grid.panelShortcutGeometry()
        let slots = geometry?.slotFrames ?? []
        let target = reorder.slot

        guard commit, target != reorder.sourceIndex, slots.indices.contains(target),
              geometry?.folderID == reorder.folder.id else {
            settlePanelReorder(session, in: slots, toSlot: reorder.sourceIndex)
            return
        }

        // The order is committed before the snapshot animation (as with other drops): the panel
        // preview is removed and the panel is immediately reconfigured from the model — the frame is
        // the same as the preview showed.
        let destination = slots[target]
        grid.endPanelReorder()
        guard store.moveWithinFolder(session.itemID, folderID: reorder.folder.id, toIndex: target) else {
            settlePanelReorder(session, in: slots, toSlot: reorder.sourceIndex)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        session.modelChanged = true
        render(animated: false)
        grid.setPanelShortcutHidden(true, at: target)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        finishReorder(of: session.itemID, inFolder: reorder.folder.id)

        moveDragView(session, to: destination) { [weak self] in
            guard let self else { return }
            self.grid.setPanelShortcutHidden(false, at: target)
            self.cleanupDrag(session, unhide: false)
        }
    }

    /// Returns the snapshot to slot `slot` and the neighbors to their base places:
    /// a cancel, a drop on its own slot, a model refusal.
    ///
    /// - Parameters:
    ///   - session: The reorder session.
    ///   - slots: The panel slot frames in grid coordinates (empty means there is no panel).
    ///   - slot: The slot the snapshot returns to (the original one).
    private func settlePanelReorder(_ session: TesseraTileDragSession, in slots: [CGRect], toSlot slot: Int) {
        grid.setPanelReorderSlot(slot, animated: !isReduceMotionEnabled())
        guard slots.indices.contains(slot) else {
            grid.endPanelReorder()
            cleanupDrag(session, unhide: false)
            return
        }
        moveDragView(session, to: slots[slot]) { [weak self] in
            guard let self else { return }
            self.grid.endPanelReorder()
            self.cleanupDrag(session, unhide: false)
        }
    }

    /// Installs the overlays, creates the drag session and starts the lift (the shared tail
    /// of drag start for a grid cell and for a tile from a folder).
    ///
    /// - Parameters:
    ///   - itemID: The identifier of the dragged tile/folder.
    ///   - isTile: Whether it is a tile.
    ///   - slotFrame: The slot frame in the grid (the placeholder).
    ///   - liftFrame: The frame the snapshot starts from (for a tile from a folder —
    ///     the panel icon frame).
    ///   - placeholder: The placeholder.
    ///   - dragView: The snapshot.
    ///   - point: The grab point in grid coordinates.
    ///   - baseSnapshot: The preview base (with the cell table).
    ///   - basePlacements: The base placements by cell.
    ///   - modelBaseSnapshot: The model snapshot, if it differs from the base.
    ///   - sourceFolderID: The source folder (a drag from the panel).
    ///   - magnetSize: The size class for the magnet.
    ///   - folderDissolution: The resulting picture of the source folder's dissolution (D45),
    ///     if it has two tiles.
    ///   - panelReorder: A reorder inside an open panel: the session
    ///     neither hides the grid element nor puts a placeholder on the grid (the placeholder and
    ///     the neighbor shift are driven by the panel itself).
    ///   - isHandover: The snapshot is already lifted (a take-out after a reorder):
    ///     the lift scale and haptic are not repeated, and the frame is not repositioned.
    private func installDragSession(
        itemID: AnyHashable,
        isTile: Bool,
        slotFrame: CGRect,
        liftFrame: CGRect,
        placeholder: UIView,
        dragView: UIView,
        point: CGPoint,
        baseSnapshot: TesseraTileGridSnapshot,
        basePlacements: [TesseraTilePlacedItem],
        modelBaseSnapshot: TesseraTileGridSnapshot?,
        sourceFolderID: AnyHashable?,
        magnetSize: TesseraTileSize,
        folderDissolution: DragFolderDissolution? = nil,
        panelReorder: TesseraPanelReorder? = nil,
        isHandover: Bool = false
    ) {
        beginDragStoreTransaction()

        if panelReorder == nil {
            grid.setItemHidden(true, forItemID: itemID)
        }
        removeControl(for: itemID)
        // D46: during a drag there are no buttons on panel tiles (on a take-out the panel is already
        // closed instantly; on a reorder they are removed while the tiles shift).
        removeAllPanelEditControls()

        if panelReorder == nil {
            placeholder.frame = slotFrame
            placeholder.layer.zPosition = 500
            grid.addSubview(placeholder)
        }

        if !isHandover {
            dragView.frame = liftFrame
        }
        dragView.isUserInteractionEnabled = false
        dragView.layer.zPosition = 1000
        dragView.layer.shadowColor = UIColor.black.cgColor
        dragView.layer.shadowOpacity = 0.22
        dragView.layer.shadowRadius = 14
        dragView.layer.shadowOffset = CGSize(width: 0, height: 8)
        grid.addSubview(dragView)

        // The preview base is the model cells at the moment of the grab. The grid and the
        // model coincide by now, so the store snapshot is exactly
        // what the user sees.
        let session = TesseraTileDragSession(
            itemID: itemID,
            isTile: isTile,
            grabOffset: CGPoint(x: liftFrame.midX - point.x, y: liftFrame.midY - point.y),
            dragView: dragView,
            placeholder: placeholder,
            lastPoint: point,
            baseSnapshot: baseSnapshot,
            magnetSize: magnetSize,
            columns: storeColumns,
            basePlacements: basePlacements,
            modelPlacements: store.placements(forColumns: storeColumns),
            modelBaseSnapshot: modelBaseSnapshot,
            sourceFolderID: sourceFolderID,
            folderDissolution: folderDissolution
        )
        session.panelReorder = panelReorder
        dragSession = session
        storeChangedDuringDrag = false
        grid.isScrollEnabled = false

        updateHoverTargets(at: point)

        if isHandover {
            startTickerIfNeeded()
            return
        }

        if !isReduceMotionEnabled() {
            dragView.transform = .identity
            // The lift scale is captured into a local constant: the animation block
            // lives until the animation ends, and a strong capture of `self` would delay
            // the coordinator's `deinit` (which must be in time to restore the grid).
            let liftScale = configuration.liftScale
            UIView.animate(
                withDuration: 0.16,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut],
                animations: {
                    dragView.transform = CGAffineTransform(
                        scaleX: liftScale,
                        y: liftScale
                    )
                },
                completion: nil
            )
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        startTickerIfNeeded()
    }

    /// The placements of a snapshot's top-level elements by its cell table.
    ///
    /// The fallback rule is the same as for the grid layout
    /// (``TesseraTileGridPlacementTable/resolve(items:cells:placementColumns:columns:)``):
    /// there is no table, it is incomplete, of a different width, or fails `validate` —
    /// cells are taken from in-order packing, as the grid will draw them.
    ///
    /// - Parameter snapshot: The grid snapshot (an expanded folder's panel is not counted in it).
    /// - Returns: The placements in the snapshot's element order.
    private func placedItems(of snapshot: TesseraTileGridSnapshot) -> [TesseraTilePlacedItem] {
        let columns = storeColumns
        let items: [(id: AnyHashable, size: TesseraTileSize)] = snapshot.items.compactMap { item in
            item.isFolderPanel ? nil : (id: item.id, size: item.size)
        }
        if let placed = TesseraTileGridPlacementTable.resolve(
            items: items,
            cells: snapshot.placementTable?.cells,
            placementColumns: snapshot.placementTable?.columns,
            columns: columns
        ) {
            return placed
        }
        let packed = TesseraTileLayoutEngine.pack(
            items: items.map { (id: $0.id, size: TesseraTileLayoutEngine.fittingSize($0.size, columns: columns)) },
            columns: columns,
            unit: 1
        )
        return packed.map {
            TesseraTilePlacedItem(id: $0.id, size: $0.size, cell: TesseraTileGridPlacement(row: $0.row, column: $0.column))
        }
    }

    /// The first free cell for a size no earlier than `origin` in reading order.
    ///
    /// Needed for the starting cell of the synthetic tile in a drag from a folder panel:
    /// the slot appears next to the folder (if there is room to its right, there), rather than
    /// in the "topmost hole". If there is no free cell up to the end of the canvas —
    /// a new row (`TesseraTileLayoutEngine.newRowCell`).
    ///
    /// - Parameters:
    ///   - size: The size of the tile being placed.
    ///   - origin: The cell before which the reading-order search does not look.
    ///   - placements: The occupied cells.
    ///   - columns: The number of grid columns.
    /// - Returns: The top-left cell.
    private func firstFreeCell(
        for size: TesseraTileSize,
        after origin: TesseraTileGridPlacement,
        in placements: [TesseraTilePlacedItem],
        columns: Int
    ) -> TesseraTileGridPlacement {
        let fitted = TesseraTileLayoutEngine.fittingSize(size, columns: columns)
        let width = fitted.unitColumns
        let height = fitted.unitRows
        var lastRow = 0
        for placed in placements {
            let footprint = TesseraTileLayoutEngine.fittingSize(placed.size, columns: columns)
            lastRow = max(lastRow, placed.cell.row + footprint.unitRows)
        }

        guard width > 0, width <= columns, origin.row <= lastRow else {
            return TesseraTileLayoutEngine.newRowCell(size: size, columns: columns, placements: placements)
        }
        for row in origin.row...lastRow {
            for column in 0...(columns - width) {
                if row == origin.row, column < origin.column { continue }
                let isFree = !placements.contains { placed in
                    let footprint = TesseraTileLayoutEngine.fittingSize(placed.size, columns: columns)
                    return row < placed.cell.row + footprint.unitRows
                        && placed.cell.row < row + height
                        && column < placed.cell.column + footprint.unitColumns
                        && placed.cell.column < column + width
                }
                if isFree { return TesseraTileGridPlacement(row: row, column: column) }
            }
        }
        return TesseraTileLayoutEngine.newRowCell(size: size, columns: columns, placements: placements)
    }

    /// Creates a cell snapshot for dragging.
    ///
    /// First a copy of the cell itself is taken with a forced screen update
    /// (`afterScreenUpdates: true`): by this time the coordinator has already removed the
    /// dimming from it, and the snapshot must be at full brightness. Then a fallback
    /// `resizableSnapshotView`; the last resort is a ready grid snapshot (it is
    /// cheaper but may not show the removed dimming in time). For an off-screen cell
    /// it returns `nil`, and the drag does not start.
    ///
    /// - Parameter itemID: The element identifier.
    /// - Returns: The snapshot view.
    private func makeDragView(forItemID itemID: AnyHashable) -> UIView? {
        if let cell = grid.cellView(forItemID: itemID),
           let snapshot = cell.snapshotView(afterScreenUpdates: true) {
            return snapshot
        }
        if let cell = grid.cellView(forItemID: itemID),
           let snapshot = cell.resizableSnapshotView(
               from: cell.bounds,
               afterScreenUpdates: true,
               withCapInsets: .zero
           ) {
            return snapshot
        }
        return grid.snapshotView(forItemID: itemID)
    }

    /// Moves the snapshot with the finger and updates the target under it.
    ///
    /// An internal step of the drag session: the coordinator's gesture calls it from `.changed`,
    /// and the tests call it directly through `@testable import` to run
    /// a reorder without simulating touches.
    ///
    /// The snapshot position is set by ``updateHoverTargets(at:)`` — after the target
    /// is chosen: the magnet attraction depends on the merge-hold zone under the finger and must not
    /// fire over an expanded folder's panel.
    ///
    /// - Parameter point: The finger point in grid coordinates.
    func updateDrag(to point: CGPoint) {
        guard let session = dragSession else { return }

        session.lastPoint = point
        updateHoverTargets(at: point)
    }

    /// Recomputes the target under the finger, the layout preview and the highlight.
    ///
    /// The decision is made from the **base** layout (``hoverTarget(at:session:)``),
    /// not from `grid.item(at:)`: the source cell is hidden but stays in the layout and
    /// would intercept the hit test, while the grid frames are already shifted by the preview.
    ///
    /// The target is the cell under the finger (``HoverTarget/cell(_:)``), "new row"
    /// or merge (the center of a tile/folder). The preview is computed from the base
    /// placements every time, not from the previous preview (shifts do not accumulate), and
    /// returns to the base when the target is a merge or there is none.
    ///
    /// D50: if the target is ``HoverTarget/cell(_:)`` of an occupied cell (the preview
    /// would push the neighbor out), the preview is shown only after the dwell
    /// ``TesseraTileEditConfiguration/reorderPreviewDwell`` on this cell, see
    /// ``reorderPreviewTarget(for:session:)``.
    ///
    /// At the end of the step the snapshot is placed under the finger (or attracted to the target
    /// cell). The "finger over the folder panel" flag is also reset here:
    /// the attraction does not work over the panel.
    ///
    /// - Parameter point: The finger point in grid coordinates.
    private func updateHoverTargets(at point: CGPoint) {
        guard let session = dragSession else { return }

        // An external model mutation or someone else's `grid.update` during a
        // drag makes the preview base and the grid inconsistent — the drag
        // is safely cancelled without waiting for the drop.
        guard dragStateIsConsistent(session) else {
            cancelDragForExternalChange()
            return
        }

        // A reorder inside the panel — the slot under the finger, not the
        // desktop targets.
        if session.panelReorder != nil {
            updatePanelReorder(at: point, session: session)
            return
        }

        // The flag is recomputed on every step, not only when the target
        // changes: the panel may have moved with auto-scroll. The grid hit test
        // is needed because `item(under:)` sees only the model's elements.
        session.isOverFolderPanel = isPointOverFolderPanel(point)

        // At the lift the finger stands where the panel icon was (after the panel
        // closes this is usually an empty spot): the preview stays in the base
        // layout until the finger moves a noticeable distance.
        if !session.hasMovedFromOrigin {
            let dx = point.x - session.originPoint.x
            let dy = point.y - session.originPoint.y
            if dx * dx + dy * dy > Self.emptySlotActivationDistance * Self.emptySlotActivationDistance {
                session.hasMovedFromOrigin = true
            }
        }

        let target = hoverTarget(at: point, session: session)

        // D50: the push-down preview of an occupied cell appears after the dwell; until then
        // the grid stays at the base. The target (and the drop) do not depend on the dwell.
        applyDragPreview(for: reorderPreviewTarget(for: target, session: session), session: session)

        // The hold over the center of a tile/folder is armed, re-armed and
        // reset on every step — before the highlight is updated, so that it immediately
        // shows the "absorb" effect if the hold has already completed.
        let hoverChanged = session.hover != target
        session.hover = target
        updateMergeHover(for: target, at: point)

        if hoverChanged {
            updateDropHighlight(for: target)
        } else {
            updateDropHighlightFrame()
        }

        // The snapshot follows the finger after the target is chosen. The attraction is
        // a visual layer only: targets are computed from the finger point, so
        // the layout and the merge timer do not depend on it.
        updateDragViewPosition(for: point, session: session)
    }

    // MARK: - Dwell before the push-down preview (D50)

    /// The dwell before the push-down preview in seconds (the sanitized setting).
    private var reorderDwellDuration: TimeInterval {
        let value = configuration.reorderPreviewDwell
        return value.isFinite ? max(0, value) : 0
    }

    /// The target the layout preview is built from: the target itself or the base.
    ///
    /// For a ``HoverTarget/cell(_:)`` whose preview would shift **other**
    /// elements (an occupied cell: the dragged one takes it, the target goes down,
    /// D31), the preview is allowed only when the finger has stayed on this cell for
    /// ``TesseraTileEditConfiguration/reorderPreviewDwell``. Until then
    /// ``HoverTarget/none`` is returned — the base: on the way to the center of a tile to build a folder,
    /// the finger first crosses its edge, and the target must not run away from under it.
    ///
    /// The session keeps the countdown (``TesseraTileDragSession/reorderDwellCell``), and the one-shot
    /// timer ``reorderDwellTimer`` fires it: the preview appears even when the
    /// finger rests. Changing the cell restarts the countdown; any other target (merge,
    /// an empty cell, "new row", no target) cancels it. Empty cells and
    /// `.newRow` displace nobody, so they are shown immediately. A dwell of 0 means no
    /// waiting. The drop ignores the dwell: it commits ``HoverTarget/cell(_:)``.
    ///
    /// - Parameters:
    ///   - target: The target under the finger.
    ///   - session: The active drag session.
    /// - Returns: The target for the preview.
    private func reorderPreviewTarget(
        for target: HoverTarget,
        session: TesseraTileDragSession
    ) -> HoverTarget {
        guard case .cell(let cell) = target,
              reorderDwellDuration > 0,
              previewDisplacesNeighbours(for: target, session: session) else {
            resetReorderDwell()
            return target
        }

        if session.reorderDwellCell != cell {
            // A new cell is a new countdown; the previous preview (if any) goes back to the base.
            cancelReorderDwellTimer()
            session.reorderDwellCell = cell
            session.isReorderDwellElapsed = false
            let timer = Timer(timeInterval: reorderDwellDuration, repeats: false) { [weak self] _ in
                self?.reorderDwellTimerDidFire()
            }
            RunLoop.main.add(timer, forMode: .common)
            reorderDwellTimer = timer
        }
        return session.isReorderDwellElapsed ? target : .none
    }

    /// Whether the target's preview will shift **other** elements relative to the base.
    ///
    /// The cells of all elements except the dragged one are compared, in the preview layout
    /// and in its basis (the base or the picture of the source folder's dissolution, D45).
    ///
    /// - Parameters:
    ///   - target: The placement target.
    ///   - session: The active drag session.
    /// - Returns: `true` if at least one element changed its cell.
    private func previewDisplacesNeighbours(
        for target: HoverTarget,
        session: TesseraTileDragSession
    ) -> Bool {
        let layout = previewLayout(for: target, session: session)
        var baseCells: [AnyHashable: TesseraTileGridPlacement] = [:]
        for placed in layout.basis { baseCells[placed.id] = placed.cell }
        return layout.placements.contains {
            $0.id != session.itemID && baseCells[$0.id] != $0.cell
        }
    }

    /// The dwell has completed: shows the push-down preview for the target under the finger.
    private func reorderDwellTimerDidFire() {
        reorderDwellTimer = nil

        guard let session = dragSession,
              session.panelReorder == nil,
              case .cell(let cell) = session.hover,
              session.reorderDwellCell == cell else {
            return
        }

        session.isReorderDwellElapsed = true
        // The same step as from a touch: the finger point is the same, the target is the same, and
        // the countdown has already completed — the preview will be applied.
        updateHoverTargets(at: session.lastPoint)
    }

    /// Cancels the dwell countdown: the timer and the session state.
    private func resetReorderDwell() {
        cancelReorderDwellTimer()
        dragSession?.reorderDwellCell = nil
        dragSession?.isReorderDwellElapsed = false
    }

    /// Stops the dwell timer.
    private func cancelReorderDwellTimer() {
        reorderDwellTimer?.invalidate()
        reorderDwellTimer = nil
    }

    /// An internal test seam: whether a dwell countdown or the tail of the hold timer is in progress.
    var hasPendingDragTimersForTesting: (merge: Bool, reorderDwell: Bool) {
        (mergeTimer != nil, reorderDwellTimer != nil)
    }

    // MARK: - Magnetism to cells

    /// Places the snapshot under the finger or attracts it to the center of the nearest slot.
    ///
    /// Without attraction the snapshot follows the finger 1:1.
    /// Within a slot's radius it glides smoothly to the center with a short spring; while
    /// the target is the same, the animation is not restarted — otherwise the tile would
    /// "twitch" on every touch event. Outside the radius the spring is removed and the snapshot
    /// again follows the finger rigidly.
    ///
    /// - Parameters:
    ///   - point: The finger point in grid coordinates.
    ///   - session: The active drag session.
    private func updateDragViewPosition(for point: CGPoint, session: TesseraTileDragSession) {
        let followCenter = CGPoint(
            x: point.x + session.grabOffset.x,
            y: point.y + session.grabOffset.y
        )

        // Until the finger has left the attraction radius around the grab point even once,
        // the magnet is not engaged: the snapshot already sits in the original slot, and without this
        // rule the tile would "stick" at the grab place for the first ~28 pt
        // of movement.
        updateMagnetEngagement(for: point, session: session)

        guard let target = magnetTarget(for: point, session: session) else {
            stopMagnetAnimation(session)
            session.magnetTarget = nil
            if session.dragView.center != followCenter {
                session.dragView.center = followCenter
            }
            return
        }

        // The same target: the spring is already moving to it (or has arrived) — leave it alone.
        guard session.magnetTarget != target else { return }
        session.magnetTarget = target

        // The cell under the snapshot matches the target — there is nothing to animate (for example,
        // a grab exactly by the tile's center on its own slot).
        guard session.dragView.center != target else { return }

        animateDragView(session, to: target)
    }

    /// Enables the attraction after the finger has left the starting zone.
    ///
    /// At the grab the snapshot already sits in the original slot, so there is nothing to
    /// "attract" the tile to: without this flag the snapshot would stay
    /// pinned to the starting center until the finger moved away from it by
    /// a full radius — the first points of movement would not follow the finger.
    /// The flag is raised once per session and is never cleared afterwards.
    ///
    /// - Parameters:
    ///   - point: The finger point in grid coordinates.
    ///   - session: The active drag session.
    private func updateMagnetEngagement(for point: CGPoint, session: TesseraTileDragSession) {
        guard !session.hasLeftOriginSlot else { return }

        let radius = configuration.magnetSnapRadius
        guard radius.isFinite, radius > 0 else { return }

        let dx = point.x - session.originPoint.x
        let dy = point.y - session.originPoint.y
        guard dx * dx + dy * dy > radius * radius else { return }

        session.hasLeftOriginSlot = true
    }

    /// The center of the target cell the snapshot should be attracted to, or `nil`.
    ///
    /// The snapshot is attracted to the frame of the **target cell** (for the size of
    /// the dragged element on a cell clamped to the canvas, see
    /// ``TesseraTileGridView/baseFrame(forCell:size:)``): to the cell of
    /// ``HoverTarget/cell(_:)``, to the start of a new row for
    /// ``HoverTarget/newRow`` and to its own base cell while there is no target.
    ///
    /// The distance is computed from the **center of the snapshot**
    /// (`point + grabOffset`), not from the finger point. Otherwise a tile grabbed off
    /// center would be attracted with an error of up to half a tile and "jump";
    /// the snapshot must also move no more than the attraction radius.
    ///
    /// The attraction is disabled:
    /// - with Reduce Motion — the snapshot stays strictly under the finger;
    /// - with a zero/non-numeric ``TesseraTileEditConfiguration/magnetSnapRadius``;
    /// - until the finger has left the starting grab zone (``TesseraTileDragSession/hasLeftOriginSlot``);
    /// - over an expanded folder's panel;
    /// - over merge-hold targets (the center zone of a tile/folder): in these
    ///   places the snapshot must not move out from under the finger while the user
    ///   holds or aims at a folder.
    ///
    /// - Parameters:
    ///   - point: The finger point in grid coordinates.
    ///   - session: The active drag session.
    /// - Returns: The center of the target cell's frame within the radius, or `nil`.
    private func magnetTarget(for point: CGPoint, session: TesseraTileDragSession) -> CGPoint? {
        guard configuration.magnetSnapRadius > 0, !isReduceMotionEnabled() else { return nil }
        guard !session.isOverFolderPanel else { return nil }
        guard session.hasLeftOriginSlot else { return nil }

        let cell: TesseraTileGridPlacement
        switch session.hover {
        case .folder, .group, .sourceFolder:
            return nil
        case .none:
            guard let own = session.basePlacements.first(where: { $0.id == session.itemID }) else {
                return nil
            }
            cell = own.cell
        case .cell(let target):
            cell = target
        case .newRow:
            cell = session.newRowCell
        }
        guard let frame = grid.baseFrame(forCell: cell, size: session.magnetSize) else { return nil }

        let snapshotCenter = CGPoint(
            x: point.x + session.grabOffset.x,
            y: point.y + session.grabOffset.y
        )
        return TesseraTileMagnet.magnetTarget(
            for: snapshotCenter,
            slotCenters: [CGPoint(x: frame.midX, y: frame.midY)],
            snapRadius: configuration.magnetSnapRadius
        )
    }

    /// An internal test seam: the magnet target for the active drag session.
    ///
    /// It allows verifying the snapshot center computation (`grabOffset`) and RTL behavior
    /// without simulating touches; it is not used in production. The gating (Reduce Motion,
    /// the panel, hold targets) stays the same as on the real path.
    ///
    /// - Parameter point: The finger point in grid coordinates.
    /// - Returns: The slot center, or `nil`.
    func dragMagnetTargetForTesting(at point: CGPoint) -> CGPoint? {
        guard let session = dragSession else { return nil }
        return magnetTarget(for: point, session: session)
    }

    /// Glides the snapshot smoothly to the slot center.
    ///
    /// The previous spring is stopped at the current presentation frame so that
    /// the new animation starts without a jump (the same technique as for the placeholder
    /// move). The duration and damping come from
    /// ``TesseraTileEditConfiguration/magnetSpringDuration`` and
    /// ``TesseraTileEditConfiguration/magnetSpringDamping``; a zero
    /// duration gives an instant reposition.
    ///
    /// - Parameters:
    ///   - session: The active drag session.
    ///   - center: The target center of the snapshot in grid coordinates.
    private func animateDragView(_ session: TesseraTileDragSession, to center: CGPoint) {
        stopMagnetAnimation(session)

        let duration = configuration.magnetSpringDuration
        guard duration.isFinite, duration > 0 else {
            session.dragView.center = center
            return
        }

        let damping = configuration.magnetSpringDamping.isFinite
            ? min(max(configuration.magnetSpringDamping, 0.01), 1)
            : 0.82
        // The closure captures only the snapshot view: the animator belongs to the session, and
        // capturing the session itself would create a "session → animator → session" cycle.
        let dragView = session.dragView
        let animator = UIViewPropertyAnimator(
            duration: duration,
            timingParameters: UISpringTimingParameters(dampingRatio: damping)
        )
        animator.addAnimations {
            dragView.center = center
        }
        animator.startAnimation()
        session.magnetAnimator = animator
    }

    /// Stops the attraction spring, leaving the snapshot at the current frame.
    ///
    /// After `stopAnimation(true)` the layer model may remain at the previous animation's
    /// target, so it is explicitly returned to the presentation frame: the next
    /// movement (to the finger or to a new slot) starts without a jump.
    ///
    /// - Parameter session: The active drag session.
    private func stopMagnetAnimation(_ session: TesseraTileDragSession) {
        guard let animator = session.magnetAnimator else { return }

        session.magnetAnimator = nil
        let visibleCenter = session.dragView.layer.presentation()?.position ?? session.dragView.center
        animator.stopAnimation(true)

        if session.dragView.center != visibleCenter {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            session.dragView.center = visibleCenter
            CATransaction.commit()
        }
    }

    /// Cancels the current attraction without ending the drag.
    ///
    /// Needed when the configuration changes: the radius and spring may have changed, and
    /// continuing the movement with the old parameters would be unfair.
    private func resetDragMagnet() {
        guard let session = dragSession else { return }
        stopMagnetAnimation(session)
        session.magnetTarget = nil
    }

    /// The preview layout for a target: placements, snapshot elements and their basis.
    ///
    /// The basis (`basis`) is the placements the insertion is computed from: the base or
    /// the picture of the source folder's dissolution (D45). For a merge, the original folder and
    /// no target the layout is the whole base (`placements == basePlacements`).
    ///
    /// - Parameters:
    ///   - target: The target for the preview.
    ///   - session: The active drag session.
    /// - Returns: The preview placements, the preview snapshot elements and the calculation basis.
    private func previewLayout(
        for target: HoverTarget,
        session: TesseraTileDragSession
    ) -> (placements: [TesseraTilePlacedItem], items: [TesseraTileGridItem], basis: [TesseraTilePlacedItem]) {
        var previewItems = session.baseSnapshot.items
        var basis = session.basePlacements
        if let dissolution = session.folderDissolution {
            switch target {
            case .cell, .newRow:
                basis = dissolution.placements
                previewItems = dissolution.items
            case .none, .folder, .group, .sourceFolder:
                break
            }
        }

        let desired: [TesseraTilePlacedItem]
        switch target {
        case .cell(let cell):
            desired = TesseraTileLayoutEngine.inserting(
                id: session.itemID,
                size: session.magnetSize,
                at: cell,
                into: basis,
                columns: session.columns
            )
        case .newRow:
            desired = TesseraTileLayoutEngine.inserting(
                id: session.itemID,
                size: session.magnetSize,
                at: session.newRowCell,
                into: basis,
                columns: session.columns
            )
        case .none, .folder, .group, .sourceFolder:
            desired = session.basePlacements
        }
        return (desired, previewItems, basis)
    }

    /// Rebuilds the grid layout preview for the target under the finger.
    ///
    /// Writes **only to the grid** — `grid.update(snapshot:animated:)` runs a
    /// ~0.26 s batch animation with the bounce curve, and the neighbors "make room" without
    /// writing to `TesseraTileStore`. The snapshot carries a cell table
    /// (``TesseraTileGridPlacementTable``), so the preview is the same elements on
    /// other cells, not a different order.
    ///
    /// Placements are computed from ``TesseraTileDragSession/basePlacements`` every time,
    /// not from the previous preview: when moving between targets the shifts do not
    /// accumulate. For ``HoverTarget/cell(_:)`` this is
    /// `TesseraTileLayoutEngine.inserting` (the element takes the cell, obstructing ones
    /// are pushed down in a cascade, D31), for ``HoverTarget/newRow`` — an insertion
    /// onto the new row's cell. For a merge (the center of a tile/folder), the original folder and
    /// no target the preview **returns to the base placements**: the target
    /// stays under the finger and the highlight is drawn on it (previously the old preview
    /// stayed here, and the target "ran away" from under the finger). Empty rows
    /// do not collapse during a drag (D31) — only on drop.
    ///
    /// D45: a drag of a tile from a two-tile folder onto a placement target
    /// (`.cell`/`.newRow`) shows the **result**: the folder element is replaced by the remaining
    /// tile on its cell (``TesseraTileDragSession/folderDissolution``);
    /// while the target is a merge, the original folder or there is none, the base is shown (the folder with
    /// one tile, as at the lift), and a cancel or a host refusal return
    /// the model with the original folder to the grid (``restore()``).
    ///
    /// - Parameters:
    ///   - target: The target under the finger.
    ///   - session: The active drag session.
    private func applyDragPreview(for target: HoverTarget, session: TesseraTileDragSession) {
        // D45: when dragging from a two-tile folder, a placement target shows
        // the resulting picture: the folder is already dissolved, the remaining tile stands on its
        // cell, and the dragged one lands by the usual rules (the same order
        // of steps as in `TesseraTileStore.extractFromFolder`). The other targets (merge,
        // the original folder, no target) show the base: the folder with its second tile in place, as
        // at the lift.
        let layout = previewLayout(for: target, session: session)
        let desired = layout.placements
        let previewItems = layout.items

        guard desired != session.previewPlacements else {
            animatePlaceholder(to: currentFrame(of: session))
            return
        }
        session.previewPlacements = desired

        var cells: [AnyHashable: TesseraTileGridPlacement] = [:]
        for placed in desired { cells[placed.id] = placed.cell }
        let previewSnapshot = TesseraTileGridSnapshot(
            items: previewItems,
            unpinned: session.baseSnapshot.unpinned,
            placementTable: TesseraTileGridPlacementTable(cells: cells, columns: session.columns)
        )
        // The grid must show exactly this snapshot; a mismatch on the
        // next step means an external `grid.update`. If the grid deferred the
        // snapshot for the duration of a panel transition, it is remembered as pending and becomes
        // the expected one when it arrives.
        session.pendingSnapshot = previewSnapshot
        grid.update(snapshot: previewSnapshot, animated: !isReduceMotionEnabled())
        if gridMatchesDragSnapshot(previewSnapshot) {
            session.expectedSnapshot = previewSnapshot
            session.pendingSnapshot = nil
        }
        if isEditing {
            // The buttons over the tiles are repositioned simultaneously with the neighbors:
            // their own short move (0.24 s) starts together with the grid's batch
            // animation.
            reconcileEditControls(animated: true)
            scheduleReconcile()
        }
        animatePlaceholder(to: currentFrame(of: session))
    }

    /// Animates the placeholder to a new frame as neighbors "make room".
    ///
    /// The curve and duration are shared with the grid's batch animation
    /// (``TesseraTileGridView/bounceTimingParameters()``): the place the tile
    /// was taken from moves with the same slight bounce as the neighbors, so
    /// the picture does not split into two different motions.
    ///
    /// - Parameter frame: The new frame in grid coordinates.
    private func animatePlaceholder(to frame: CGRect) {
        guard let placeholder = dragSession?.placeholder else { return }
        guard placeholder.frame != frame else { return }

        // §9: with Reduce Motion the movement is instant, as in the grid.
        guard !isReduceMotionEnabled() else {
            stopPlaceholderAnimation()
            placeholder.frame = frame
            return
        }

        // A new drag step may arrive in the middle of the previous move.
        // Remember the frame the user sees, stop the previous
        // animation and start from that point: the layer model already sits at the target, and
        // without returning to the presentation frame the new animation would start with
        // a "jump" to the end of the previous one.
        let currentFrame = placeholder.layer.presentation()?.frame ?? placeholder.frame
        stopPlaceholderAnimation()
        if placeholder.frame != currentFrame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            placeholder.frame = currentFrame
            CATransaction.commit()
        }

        let animator = UIViewPropertyAnimator(
            duration: TesseraTileGridView.tileMoveDuration,
            timingParameters: TesseraTileGridView.bounceTimingParameters()
        )
        animator.addAnimations {
            placeholder.frame = frame
        }
        animator.startAnimation()
        placeholderAnimator = animator
    }

    /// Stops an unfinished placeholder move.
    ///
    /// `stopAnimation(true)` leaves the view at its current position — the next
    /// animation continues from it, not from the final frame.
    private func stopPlaceholderAnimation() {
        placeholderAnimator?.stopAnimation(true)
        placeholderAnimator = nil
    }

    /// The finger displacement from the grab point after which cell selection
    /// is enabled over an empty spot, in pt.
    static let emptySlotActivationDistance: CGFloat = 12

    /// The target under the finger: a grid cell by the base layout (D21, D33).
    ///
    /// The hit test uses the **base** layout (``TesseraTileDragSession/basePlacements``,
    /// the same frames the user saw before the preview shifts), not the
    /// grid frames. The finger determines the cell (row/column in logical,
    /// non-mirrored coordinates: the grid accounts for RTL,
    /// ``TesseraTileGridView/baseCell(forGridPoint:)``); the column is clamped to
    /// `0 ..< columns`, the row to no less than 0.
    ///
    /// If the cell is occupied by another element of the base layout, the zone of its
    /// base frame decides (``TesseraTileMergeZone``, D50):
    /// - the center of a tile is `.group` (folder creation by hold, D14; only
    ///   for a tile not taken from a folder);
    /// - the center of a folder is `.folder` (adding by hold; a folder cannot be
    ///   dropped into a folder) or `.sourceFolder` for the original folder of a drag from the panel;
    /// - the edge (everything else, including gaps) is `.cell` with the **target element's cell**:
    ///   the dragged one takes it, and the target is pushed down (D31).
    ///
    /// Over its own base cell there is no target (`.none`, the preview is the base). Over an
    /// empty cell the target is that cell; below the last occupied row it is
    /// ``HoverTarget/newRow``. Until the finger has moved from the grab point
    /// (``TesseraTileDragSession/hasMovedFromOrigin``), empty cells give
    /// no target.
    ///
    /// While a folder panel is expanded (including during an animated close),
    /// the grid layout does not match the base one: cells are not computed, and the element
    /// under the finger is looked up by the grid frames (a fallback path); its cell is taken from the
    /// base placements. Over the panel itself and over an empty spot there is no target.
    ///
    /// - Parameters:
    ///   - point: The finger point in grid coordinates.
    ///   - session: The active drag session.
    /// - Returns: The target under the finger.
    private func hoverTarget(at point: CGPoint, session: TesseraTileDragSession) -> HoverTarget {
        guard !session.isOverFolderPanel,
              grid.bounds.insetBy(dx: -8, dy: -8).contains(point) else {
            return .none
        }

        if grid.expandedFolderID != nil {
            guard let hovered = item(under: point, excluding: session.itemID),
                  let frame = grid.frame(forItemID: hovered.id),
                  let placed = session.basePlacements.first(where: { $0.id == hovered.id }) else {
                return .none
            }
            return zoneTarget(for: hovered, at: placed.cell, frame: frame, point: point, session: session)
        }

        guard let frames = baseFrames(for: session),
              let finger = grid.baseCell(forGridPoint: point) else {
            return .none
        }

        let columns = session.columns
        let row = max(0, finger.row)
        let column = min(max(0, finger.column), columns - 1)

        var bottom = 0
        var occupant: TesseraTilePlacedItem?
        for placed in session.basePlacements {
            let footprint = TesseraTileLayoutEngine.fittingSize(placed.size, columns: columns)
            bottom = max(bottom, placed.cell.row + footprint.unitRows)
            if occupant == nil,
               row >= placed.cell.row, row < placed.cell.row + footprint.unitRows,
               column >= placed.cell.column, column < placed.cell.column + footprint.unitColumns {
                occupant = placed
            }
        }

        guard let occupant else {
            guard session.hasMovedFromOrigin else { return .none }
            return row >= bottom
                ? .newRow
                : .cell(TesseraTileGridPlacement(row: row, column: column))
        }
        // Its own base cell is not a target (no reorder with itself).
        if occupant.id == session.itemID { return .none }

        guard let contentFrame = frames[occupant.id],
              let item = session.baseSnapshot.items.first(where: { $0.id == occupant.id }) else {
            return .cell(occupant.cell)
        }
        return zoneTarget(
            for: item,
            at: occupant.cell,
            frame: grid.gridFrame(fromContentFrame: contentFrame),
            point: point,
            session: session
        )
    }

    /// The target over an occupied cell by the zone of the element's frame.
    ///
    /// The center (``TesseraTileMergeZone``: the entry zone, with hysteresis after entry,
    /// D50) is a merge, the edge is placement onto the target element's cell
    /// (``HoverTarget/cell(_:)``).
    ///
    /// - Parameters:
    ///   - item: The element under the finger.
    ///   - cell: Its cell in the base layout.
    ///   - frame: The frame the zone is decided by, in grid coordinates.
    ///   - point: The finger point in grid coordinates.
    ///   - session: The active drag session.
    /// - Returns: The target under the finger.
    private func zoneTarget(
        for item: TesseraTileGridItem,
        at cell: TesseraTileGridPlacement,
        frame: CGRect,
        point: CGPoint,
        session: TesseraTileDragSession
    ) -> HoverTarget {
        let edgeTarget = HoverTarget.cell(cell)

        // D50: hysteresis. If the target is already a merge with this element, it
        // holds while the finger is inside the frame shrunk by 6 pt; entering a merge
        // is possible only through the (enlarged) entry zone.
        let isEngaged: Bool
        switch session.hover {
        case .group(let id), .folder(let id):
            isEngaged = id == item.id
        case .sourceFolder:
            isEngaged = session.sourceFolderID == item.id
        case .none, .cell, .newRow:
            isEngaged = false
        }
        let isCenter = TesseraTileMergeZone.contains(point, in: frame, isEngaged: isEngaged)

        switch item {
        case .folder(let folder):
            // A folder cannot be dropped into a folder (no nesting) — a reorder.
            guard session.isTile else { return edgeTarget }
            if folder.id == session.sourceFolderID {
                // The center of the original folder means "return to the folder" (no-op), the edge is
                // a regular take-out onto the folder's cell.
                return isCenter ? .sourceFolder : edgeTarget
            }
            // The center zone of a folder: adding a tile inside by
            // hold (D14); without a hold the drop is a no-op.
            return isCenter ? .folder(folder.id) : edgeTarget

        case .tile(let tile):
            // The center of a tile creates a folder from two tiles (D14). For
            // a tile taken from a folder no folder is created — the center works as
            // a regular placement onto the cell (a take-out onto the grid).
            if session.isTile, session.sourceFolderID == nil, isCenter {
                return .group(tile.id)
            }
            return edgeTarget

        case .folderContent:
            // There is no panel in the base layout (it would shift the rows).
            return .none
        }
    }

    /// The base frames of the session's elements in content coordinates.
    ///
    /// Computed once per session and rebuilt if the grid
    /// geometry changed (width, columns, insets, direction). The scroll offset
    /// is not part of the cache: frames are stored in content coordinates and on
    /// every step (including an auto-scroll frame) are converted by
    /// `grid.gridFrame(fromContentFrame:)` with the current `contentOffset`.
    /// The frames are taken from the cell table of the base snapshot.
    ///
    /// - Parameter session: The active drag session.
    /// - Returns: The frames by identifier, or `nil` if they cannot be computed.
    private func baseFrames(for session: TesseraTileDragSession) -> [AnyHashable: CGRect]? {
        let key = grid.baseFramesKey()
        if let cached = session.baseFrames, cached.key == key {
            return cached.frames
        }
        guard let frames = grid.baseContentFrames(
            for: session.baseSnapshot.items,
            placementTable: session.baseSnapshot.placementTable
        ) else {
            session.baseFrames = nil
            return nil
        }
        session.baseFrames = (key: key, frames: frames)
        return frames
    }

    /// The element under a point, other than the dragged one (grid frames; a fallback path
    /// when a folder panel is expanded).
    ///
    /// - Parameters:
    ///   - point: The point in grid coordinates.
    ///   - excludedID: The identifier to ignore (the drag itself).
    /// - Returns: The element or `nil`.
    private func item(under point: CGPoint, excluding excludedID: AnyHashable) -> TesseraTileGridItem? {
        for item in grid.items where item.id != excludedID {
            guard let frame = grid.frame(forItemID: item.id) else { continue }
            if frame.contains(point) {
                return item
            }
        }
        return nil
    }

    /// Whether a point is over an expanded folder's panel.
    ///
    /// `item(under:)` iterates only the model's elements, while the panel is a presentation
    /// element, so it is looked up with the grid hit test (`grid.item(at:)`):
    /// the panel has its own `IndexPath` in the collection. It is needed both in
    /// ``updateHoverTargets(at:)`` (to remove the magnet / show that the target is not a tile)
    /// and in ``finishDrag(commit:)`` (a drop over the panel is a no-op).
    ///
    /// - Parameter point: The point in grid coordinates.
    /// - Returns: `true` if the point falls on the expanded folder's panel.
    private func isPointOverFolderPanel(_ point: CGPoint) -> Bool {
        guard grid.expandedFolderID != nil else { return false }
        return grid.item(at: point)?.isFolderPanel == true
    }

    // MARK: - Hold over the target

    /// Arms, advances, re-arms or resets the hold.
    ///
    /// The hold targets are the center of a tile (folder creation) and the center zone of
    /// a folder tile (adding inside); one state machine,
    /// ``TesseraMergeHoverTracker``, serves both. It is called on every drag step (and on every
    /// auto-scroll frame) right after the target under the finger is computed, so
    /// it must be cheap: in the steady state it does a single
    /// displacement comparison.
    ///
    /// - Parameters:
    ///   - target: The target under the finger.
    ///   - point: The finger point in grid coordinates.
    private func updateMergeHover(for target: HoverTarget, at point: CGPoint) {
        guard let targetID = target.mergeTargetID else {
            // The center of a tile and the center zone of a folder are hold targets; any
            // other target (a reorder, an empty spot) cancels the hold.
            resetMergeHover()
            return
        }

        guard mergeTracker?.targetID == targetID else {
            // A target change is a new countdown: the hold must be over this
            // particular tile, not "somewhere nearby".
            armMergeHover(on: targetID, at: point)
            return
        }

        let wasReady = mergeTracker?.state == .fired
        guard mergeTracker?.update(point: point) == true else { return }

        // The finger moved by the tolerance or more — the previous hold is
        // cancelled, the anchor is moved to the current point, and the 600 ms countdown
        // starts anew. The old timer is cancelled (`scheduleMergeTimer` does
        // this itself), and the "absorb" effect already shown is rolled back.
        scheduleMergeTimer()
        if wasReady {
            refreshMergeHighlight(animated: true)
        }
    }

    /// Starts a new hold countdown over a tile.
    ///
    /// The threshold and tolerance are read from ``configuration`` at arming time: changing the
    /// configuration on the fly cancels the current hold (see `didSet`).
    ///
    /// - Parameters:
    ///   - targetID: The tile whose center the finger is over.
    ///   - point: The finger point in grid coordinates (the anchor for the displacement tolerance).
    private func armMergeHover(on targetID: AnyHashable, at point: CGPoint) {
        resetMergeHover()

        var tracker = TesseraMergeHoverTracker(
            hoverDuration: max(0, configuration.mergeHoverDuration),
            displacementThreshold: max(0, configuration.mergeHoverDisplacement)
        )
        tracker.beginHover(targetID: targetID, point: point)
        mergeTracker = tracker
        scheduleMergeTimer()
    }

    /// Schedules the hold timer to fire after the remainder of the interval.
    ///
    /// The `.common` mode rather than `.default`: during a drag the collection
    /// is in tracking mode, and a `.default` timer would not fire until
    /// the finger is released — that is, never.
    private func scheduleMergeTimer() {
        cancelMergeTimer()
        guard let tracker = mergeTracker, tracker.isArmed else { return }

        // The remainder, not the full interval: if the timer fired a hair
        // before the threshold, the next one finishes the countdown.
        let interval = max(0.01, tracker.remainingDuration)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.mergeTimerDidFire()
        }
        RunLoop.main.add(timer, forMode: .common)
        mergeTimer = timer
    }

    /// The hold timer fired: checks the threshold and shows the "absorb" effect.
    ///
    /// Merge readiness is the only thing that distinguishes a drop that creates a
    /// folder from a regular reorder, so before switching
    /// the state it is checked once more that the finger is still over the same tile
    /// (the target may have changed through auto-scroll or the finger moving away).
    private func mergeTimerDidFire() {
        mergeTimer = nil

        guard let session = dragSession,
              let targetID = session.hover.mergeTargetID,
              mergeTracker?.targetID == targetID else {
            return
        }

        guard mergeTracker?.timerFired() == true else {
            // The threshold has not elapsed yet — count down the remainder.
            scheduleMergeTimer()
            return
        }

        refreshMergeHighlight(animated: true)

        // The "ready" haptic is optional, from the Windows Phone spec (a light tap).
        // The gesture does not change: the signal only confirms that a folder
        // will be created if the finger is released now. With Reduce Motion it
        // stays: it is feedback, not motion.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if case .folder = session.hover {
            announce(TesseraStartScreenStrings.string(.a11yDragHoldToAddToFolder))
        } else {
            announce(TesseraStartScreenStrings.string(.a11yDragHoldToCreateFolder))
        }
    }

    /// Cancels the hold: the timer, the state machine and the "absorb" effect of the highlight.
    ///
    /// The highlight's visibility is not touched — the caller either hides it or
    /// redraws it. If the finger is still over the center of a tile, the view returns
    /// to the regular target highlight (`.group`) and the scale to 1: a reset must not
    /// leave a merge promise on the screen.
    private func resetMergeHover() {
        cancelMergeTimer()
        mergeTracker = nil

        guard let view = dropHighlightView else { return }
        if let style = dragSession?.hover.baseHighlightStyle {
            view.apply(style)
        }
        view.transform = .identity
    }

    /// Stops the hold timer.
    private func cancelMergeTimer() {
        mergeTimer?.invalidate()
        mergeTimer = nil
    }

    // MARK: - Target highlight

    /// Shows/hides the highlight of the target tile.
    ///
    /// The target is the only tile that stays at full brightness in the dim field
    /// during a drag (``dimmingTargetAlpha(for:)``), so the highlight
    /// border reads against the dimmed neighbors. The transparency is also updated here:
    /// a new target briefly "flashes", and a tile that stops
    /// being the target returns to the dimming.
    ///
    /// For the center of a tile the view depends on the hold — a regular border before
    /// the threshold and the "absorb" effect after it (``refreshMergeHighlight(animated:)``).
    ///
    /// - Parameter target: The current target under the finger.
    private func updateDropHighlight(for target: HoverTarget) {
        switch target {
        case .none, .cell, .newRow, .sourceFolder:
            hideDropHighlight()

        case .folder(let itemID):
            showDropHighlight(for: itemID, style: .folder)

        case .group:
            refreshMergeHighlight(animated: false)
        }

        applyEditDimming(animated: true)
    }

    /// Updates the tile center highlight view to match the hold state.
    ///
    /// The only place that owns the highlight's `transform`: a scale of
    /// 1.08 when ready to merge and 1 in all other states. The `.merge` style
    /// adds an accent border — a second, non-animation indicator of
    /// the state, so with Reduce Motion it stays visible: only the
    /// border and the scale change, without playing an animation.
    ///
    /// The highlight overlay is scaled, not the target cell: the cell's `transform`
    /// is occupied by the jiggle and the collection layout, while the overlay repeats the
    /// tile's frame, so visually the "absorb" effect reads as the target itself growing.
    ///
    /// - Parameter animated: Animate the transition over ``TesseraTileEditConfiguration/mergeHighlightDuration``.
    private func refreshMergeHighlight(animated: Bool) {
        var ready = false

        if let session = dragSession, let targetID = session.hover.mergeTargetID {
            ready = mergeTracker?.isMergeReady == true
            // The "absorb" effect amplifies the same target style: for the center of a tile —
            // the orange `.merge`, for the center of a folder — the blue `.mergeFolder`.
            let baseStyle = session.hover.baseHighlightStyle ?? .group
            let style: TesseraTileDropHighlightView.Style
            if ready {
                style = baseStyle == .folder ? .mergeFolder : .merge
            } else {
                style = baseStyle
            }
            showDropHighlight(for: targetID, style: style)
        }

        guard let view = dropHighlightView else { return }

        let scale = ready ? max(1, configuration.mergeHighlightScale) : 1
        let apply: () -> Void = {
            view.transform = CGAffineTransform(scaleX: scale, y: scale)
        }

        // Reduce Motion disables only the animation: the border and scale
        // are set immediately, and the state is still readable.
        guard animated, !isReduceMotionEnabled() else {
            apply()
            return
        }

        UIView.animate(
            withDuration: max(0, configuration.mergeHighlightDuration),
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
            animations: apply,
            completion: nil
        )
    }

    /// Recomputes the frame of an already shown highlight (after a repack).
    ///
    /// The frame is set through `bounds`/`center`, not `frame`: in the
    /// "absorb" state the view has a non-identity `transform`, and `frame` is
    /// undefined for it.
    private func updateDropHighlightFrame() {
        guard let session = dragSession, let view = dropHighlightView, !view.isHidden else {
            return
        }

        switch session.hover {
        case .folder(let itemID), .group(let itemID):
            if let frame = grid.frame(forItemID: itemID) {
                view.bounds = CGRect(origin: .zero, size: frame.size)
                view.center = CGPoint(x: frame.midX, y: frame.midY)
            }
        case .none, .cell, .newRow, .sourceFolder:
            break
        }
    }

    /// Shows the highlight on an element's frame.
    ///
    /// - Parameters:
    ///   - itemID: The target element.
    ///   - style: The target type (folder, folder creation, "absorb").
    private func showDropHighlight(
        for itemID: AnyHashable,
        style: TesseraTileDropHighlightView.Style
    ) {
        guard let frame = grid.frame(forItemID: itemID) else {
            hideDropHighlight()
            return
        }

        let view: TesseraTileDropHighlightView
        if let existing = dropHighlightView {
            view = existing
        } else {
            view = TesseraTileDropHighlightView(frame: frame)
            view.layer.zPosition = 600
            grid.addSubview(view)
            dropHighlightView = view
        }

        view.apply(style)
        // `bounds`/`center` instead of `frame`: the view may be scaled
        // by the "absorb" effect.
        view.bounds = CGRect(origin: .zero, size: frame.size)
        view.center = CGPoint(x: frame.midX, y: frame.midY)
        view.isHidden = false
    }

    /// Hides the target highlight and cancels the "absorb" effect.
    private func hideDropHighlight() {
        guard let view = dropHighlightView else { return }
        view.isHidden = true
        view.transform = .identity
    }

    // MARK: - Dimming

    /// Applies the edit-mode transparency to the visible cells.
    ///
    /// These stay at full brightness:
    /// - the tile used to enter the mode (``dimmingFocusID``), while there is no drag;
    /// - the dragged tile (its cell is hidden — the snapshot carries the brightness);
    /// - the target tile under the finger (a folder or the center of a tile) — so that the existing
    ///   drop highlight does not get lost in the dim field.
    ///
    /// The others fade to ``TesseraTileGridView/dimmedTileAlpha`` (0.7). Cells hidden
    /// by the coordinator (`alpha == 0`: drag/unpin) are left alone — their
    /// visibility is owned by `TesseraTileGridView.setItemHidden`, and "raising"
    /// such a tile to 0.7 would show it ahead of time. The dimming is applied and
    /// stored in the grid
    /// (`TesseraTileGridView.setEditDimming(_:animated:)`): a cell's `configure`
    /// no longer resets the transparency, so the dimming survives
    /// update/resize/drop.
    ///
    /// - Parameters:
    ///   - animated: Animate the transition or set the transparency immediately.
    ///     With Reduce Motion there is no animation, but the dimming itself is applied: it is not
    ///     motion, so it must not be removed (the duration belongs to the grid).
    ///   - itemIDs: Restricts the set of cells (the scroll hot path passes
    ///     only tiles with buttons). `nil` means all elements of the snapshot.
    private func applyEditDimming(animated: Bool, limitedTo itemIDs: [AnyHashable]? = nil) {
        // The dimming owner is the grid. The coordinator only computes targets:
        // the grid applies them to the visible cells and stores them, so `configure`
        // (update/resize/drop/reuse) no longer erases the dimming.
        let candidates = itemIDs ?? grid.items.map { $0.id }
        var targets: [AnyHashable: CGFloat] = [:]
        targets.reserveCapacity(candidates.count)

        for itemID in candidates {
            // The alpha of the hidden dragged cell belongs to the drag session:
            // hiding beats dimming, the grid will keep it transparent itself.
            if itemID == dragSession?.itemID { continue }
            targets[itemID] = dimmingTargetAlpha(for: itemID)
        }

        guard !targets.isEmpty else { return }
        grid.setEditDimming(targets, animated: animated && !isReduceMotionEnabled())
    }

    /// The full-brightness targets for all grid elements.
    ///
    /// Used when removing the dimming: the grid owns the transparency, and the coordinator
    /// only passes "all 1".
    ///
    /// - Returns: Transparency 1 by identifier of each snapshot element.
    private func liftedDimmingTargets() -> [AnyHashable: CGFloat] {
        var targets: [AnyHashable: CGFloat] = [:]
        targets.reserveCapacity(grid.items.count)
        for item in grid.items {
            targets[item.id] = 1
        }
        return targets
    }

    /// The target transparency of a tile's content in the current state.
    ///
    /// During a drag the dragged tile and the target under the
    /// finger count as "selected"; outside a drag it is the tile used to enter editing.
    ///
    /// - Parameter itemID: The tile identifier.
    /// - Returns: 1 for full brightness, ``TesseraTileGridView/dimmedTileAlpha`` for the dimming.
    private func dimmingTargetAlpha(for itemID: AnyHashable) -> CGFloat {
        guard isEditing else { return 1 }

        if let session = dragSession {
            if itemID == session.itemID { return 1 }

            switch session.hover {
            case .folder(let targetID), .group(let targetID):
                if targetID == itemID { return 1 }
            case .none, .cell, .newRow, .sourceFolder:
                break
            }
            return TesseraTileGridView.dimmedTileAlpha
        }

        if itemID == dimmingFocusID { return 1 }
        return TesseraTileGridView.dimmedTileAlpha
    }

    // MARK: - Drag: finish

    /// Finishes the drag.
    ///
    /// An internal step of the drag session (the gesture — `.ended`/`.cancelled`); tests
    /// call it through `@testable import` to finish a reorder without
    /// simulating touches.
    ///
    /// By this time the grid shows the layout preview, while the model
    /// is still in its state at the grab. The drop commits the target under the finger with
    /// a single `TesseraTileStore` operation by cell: ``HoverTarget/cell(_:)`` —
    /// ``TesseraTileStore/moveItem(_:toCell:columns:)`` (from a folder —
    /// ``TesseraTileStore/extractFromFolder(_:toCell:columns:)``), ``HoverTarget/newRow`` —
    /// ``TesseraTileStore/moveItemToNewRow(_:columns:)`` / ``TesseraTileStore/extractFromFolderToNewRow(_:columns:)``,
    /// ``HoverTarget/group`` — folder creation on the target's cell (D20), ``HoverTarget/folder`` —
    /// ``TesseraTileStore/addToFolder(_:folderID:columns:)`` (from a folder —
    /// ``TesseraTileStore/moveBetweenFolders(_:to:columns:)``). After a successful operation
    /// an empty row collapses (``TesseraTileStore/collapseEmptyRows(columns:)``,
    /// D31). A cancel, a drop without a target and a drop with no changes return the base
    /// layout to the grid and do not write to the model at all. A drop on the center without a
    /// completed hold is a no-op.
    ///
    /// - Parameter commit: `true` to commit the preview, `false` to restore
    ///   the order at the grab (the gesture was cancelled).
    func finishDrag(commit: Bool) {
        guard let session = dragSession else { return }

        // The model/snapshot diverged from the grab base — the preview
        // must not be committed; cancel safely and synchronize with the model.
        guard dragStateIsConsistent(session) else {
            cancelDragForExternalChange()
            return
        }

        defer {
            storeChangedDuringDrag = false
            endDragStoreTransaction(saveIfNeeded: session.modelChanged)
        }

        // Merge readiness is cleared before the hold is reset — the drop uses this
        // flag to choose between creating a folder and a regular reorder.
        let isMergeReady = mergeTracker?.isMergeReady == true

        stopTicker()
        resetMergeHover()
        resetReorderDwell()
        // Returning the snapshot to its place (moveDragView/collapseDragView) must
        // start from the current frame, not from the target of an unfinished spring.
        stopMagnetAnimation(session)
        session.magnetTarget = nil
        dragSession = nil
        grid.isScrollEnabled = true
        hideDropHighlight()

        // A reorder inside the panel finishes its own way.
        if session.panelReorder != nil {
            finishPanelReorder(session, commit: commit)
            return
        }

        guard commit else {
            restore()
            settleDragView(session) {
                self.cleanupDrag(session, unhide: true)
            }
            return
        }

        // An expanded folder panel is not a drop target. If the host opened
        // the panel during a drag (a long press usually closes it, but the host
        // may open it itself), the hover stays `.none`, and the default branch
        // would commit the last push preview. Releasing over the panel
        // returns the tile to its original place: the store and the delegate are not touched.
        // The check against the last point is needed if the panel appeared under the finger
        // after the last drag step.
        if session.isOverFolderPanel || isPointOverFolderPanel(session.lastPoint) {
            returnAfterNoOpDrop(session)
            return
        }

        switch session.hover {
        case .sourceFolder:
            // The center of the original folder — the tile returns, the model does not change.
            returnAfterNoOpDrop(session)

        case .folder(let folderID) where session.isTile && isMergeReady:
            // The center of a folder with a completed hold — add the
            // tile inside (D14). For a tile from a folder this is a move.
            if session.sourceFolderID != nil {
                dropFromFolderIntoFolder(session, folderID: folderID)
            } else {
                dropIntoFolder(session, folderID: folderID)
            }

        case .group(let targetID) where session.isTile && isMergeReady:
            // A folder is created only if the hold has completed (the highlight
            // has already shown the "absorb" effect).
            dropIntoNewFolder(session, targetID: targetID)

        case .folder where session.isTile, .group where session.isTile:
            // A drop on the center without a 600 ms hold returns the tile to its original
            // place (no-op/cancel). No push preview is made for the center zone.
            returnAfterNoOpDrop(session)

        case .cell(let cell):
            dropOntoGrid(session, cell: cell)

        case .newRow:
            dropOntoGrid(session, cell: nil)

        default:
            // There is no target (outside the grid, over its own cell, a lift without movement):
            // the layout does not change, the element returns to its place / to the folder.
            returnAfterNoOpDrop(session)
        }
    }

    /// Returns a tile to its original place on a no-op drop.
    ///
    /// Called when a drop is released over the center of a tile/folder without a completed
    /// hold, and also over an expanded folder's panel.
    /// The model does not change, and the delegate does not receive `didMove`.
    /// The grid returns to the model order (if the finger had visited the reorder
    /// zone, the preview is removed), and the snapshot moves back into place.
    ///
    /// - Parameter session: The drag session.
    private func returnAfterNoOpDrop(_ session: TesseraTileDragSession) {
        restore()
        settleDragView(session) {
            self.cleanupDrag(session, unhide: true)
        }
    }

    /// Returns the snapshot to its place after a cancel/no-op/refusal.
    ///
    /// A regular element moves to its slot. A tile taken from a folder is, after
    /// `restore()`, no longer a grid element (the synthetic slot was removed together with the
    /// display snapshot) — it is "absorbed" back into the source folder.
    ///
    /// - Parameters:
    ///   - session: The drag session.
    ///   - completion: The completion (remove the overlays).
    private func settleDragView(
        _ session: TesseraTileDragSession,
        completion: @escaping () -> Void
    ) {
        if let sourceID = session.sourceFolderID,
           grid.index(ofItemID: session.itemID) == nil,
           let folderFrame = grid.frame(forItemID: sourceID) {
            collapseDragView(session, into: folderFrame, completion: completion)
        } else {
            moveDragView(session, to: currentFrame(of: session), completion: completion)
        }
    }

    /// Finishes a drop onto a cell or into a new row (D21, D33).
    ///
    /// A grid element is moved by ``TesseraTileStore/moveItem(_:toCell:columns:)`` /
    /// ``TesseraTileStore/moveItemToNewRow(_:columns:)``: the old place is left as a hole,
    /// obstructing tiles are pushed down in a cascade (D31). A tile from a folder panel
    /// is taken out by ``TesseraTileStore/extractFromFolder(_:toCell:columns:)`` /
    /// ``TesseraTileStore/extractFromFolderToNewRow(_:columns:)``: host
    /// approval is requested there (D14), and a folder with one remaining tile
    /// is dissolved (D45: the tile takes its cell, the delegate receives
    /// `didDissolveFolder` after `didMove`).
    /// After a successful operation a fully empty row collapses. If the
    /// layout did not change (the element is already on this cell), it is a no-op.
    /// Then as with the other drops: `render`, the frame is read after it, VoiceOver
    /// focus goes to the element.
    ///
    /// - Parameters:
    ///   - session: The drag session.
    ///   - cell: The desired cell; `nil` means a new row at the end of the canvas.
    private func dropOntoGrid(_ session: TesseraTileDragSession, cell: TesseraTileGridPlacement?) {
        let columns = session.columns

        if session.sourceFolderID != nil {
            let extracted: Bool
            if let cell {
                extracted = store.extractFromFolder(session.itemID, toCell: cell, columns: columns)
            } else {
                extracted = store.extractFromFolderToNewRow(session.itemID, columns: columns)
            }
            guard extracted else {
                failGroupingDrop(
                    .moveBetweenFolders,
                    session: session,
                    folderID: nil,
                    reason: TesseraStartScreenStrings.string(.a11yGroupingReasonMoveDenied)
                )
                return
            }

            session.modelChanged = true
            store.collapseEmptyRows(columns: columns)
            render(animated: true)
            let frame = currentFrame(of: session)
            delegate?.tileEditCoordinator(
                self,
                didMove: session.itemID,
                toFolder: nil,
                atCell: store.placements(forColumns: columns)[session.itemID]
            )
            notifyDissolution(of: session)
            announce(TesseraStartScreenStrings.string(.a11yFolderTileOnStart))
            UINotificationFeedbackGenerator().notificationOccurred(.success)

            moveDragView(session, to: frame) {
                self.cleanupDrag(session, unhide: true)
                self.postLayoutChanged(focusing: session.itemID)
            }
            return
        }

        let moved: Bool
        if let cell {
            moved = store.moveItem(session.itemID, toCell: cell, columns: columns)
        } else {
            moved = store.moveItemToNewRow(session.itemID, columns: columns)
        }
        guard moved else {
            // The layout did not change (or the element vanished from the model): the grid
            // returns to the model, the delegate and saving are not touched.
            returnAfterNoOpDrop(session)
            return
        }

        session.modelChanged = true
        store.collapseEmptyRows(columns: columns)
        render(animated: true)
        let actualCell = store.placements(forColumns: columns)[session.itemID]
        let frame = currentFrame(of: session)
        moveDragView(session, to: frame) {
            self.cleanupDrag(session, unhide: true)
            if let actualCell {
                self.delegate?.tileEditCoordinator(
                    self,
                    didMove: session.itemID,
                    toCell: actualCell
                )
            }
            // After the move, VoiceOver focus goes to the tile that moved.
            self.postLayoutChanged(focusing: session.itemID)
        }
    }

    /// Finishes a drop of a tile from the panel onto the center of another folder.
    ///
    /// Called only when the hold has completed. The move goes through
    /// ``TesseraTileStore/moveBetweenFolders(_:to:columns:)`` (host approval, D14);
    /// a two-tile source folder is dissolved (D45): the remaining tile takes
    /// its place, and the delegate receives `didDissolveFolder` after `didMove`.
    ///
    /// - Parameters:
    ///   - session: The drag session (the source is a folder).
    ///   - folderID: The target folder.
    private func dropFromFolderIntoFolder(_ session: TesseraTileDragSession, folderID: AnyHashable) {
        guard store.moveBetweenFolders(session.itemID, to: folderID, columns: session.columns) else {
            failGroupingDrop(
                .moveBetweenFolders,
                session: session,
                folderID: folderID,
                reason: TesseraStartScreenStrings.string(.a11yGroupingReasonMoveDenied)
            )
            return
        }

        session.modelChanged = true
        store.collapseEmptyRows(columns: session.columns)
        render(animated: true)
        // The target frame is read after synchronization: collapsing rows may have shifted
        // the folder.
        let folderFrame = grid.frame(forItemID: folderID) ?? session.placeholder.frame
        delegate?.tileEditCoordinator(
            self,
            didMove: session.itemID,
            toFolder: folderID,
            atCell: nil
        )
        notifyDissolution(of: session)
        announce(TesseraStartScreenStrings.string(.a11yFolderTileMoved))
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        collapseDragView(session, into: folderFrame) {
            self.cleanupDrag(session, unhide: false)
            self.postLayoutChanged(focusing: folderID)
        }
    }

    /// Finishes a drop onto an existing folder (D14).
    ///
    /// - Parameters:
    ///   - session: The drag session.
    ///   - folderID: The target folder.
    private func dropIntoFolder(_ session: TesseraTileDragSession, folderID: AnyHashable) {
        guard store.addToFolder(session.itemID, folderID: folderID, columns: session.columns) else {
            failGroupingDrop(
                .addToFolder,
                session: session,
                folderID: folderID,
                reason: TesseraStartScreenStrings.string(.a11yGroupingReasonAddDenied)
            )
            return
        }

        session.modelChanged = true
        // The tile's cell was left as a hole; the empty row collapses.
        store.collapseEmptyRows(columns: session.columns)
        render(animated: true)
        // The folder frame is read after synchronization: collapsing a row may have
        // shifted the folder up, and the snapshot must fly into its current slot.
        let folderFrame = grid.frame(forItemID: folderID) ?? session.placeholder.frame
        delegate?.tileEditCoordinator(self, didAdd: session.itemID, toFolder: folderID)
        announce(TesseraStartScreenStrings.string(.a11yFolderTileAdded))
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        collapseDragView(session, into: folderFrame) {
            self.cleanupDrag(session, unhide: false)
            self.postLayoutChanged(focusing: folderID)
        }
    }

    /// Finishes a drop onto the center of another tile: creates a folder from two tiles.
    ///
    /// Called only from ``finishDrag(commit:)`` and only when the
    /// hold has completed (`TesseraMergeHoverTracker/isMergeReady`) — the
    /// "absorb" effect has already been shown to the user. A drop onto the center without a hold
    /// does not get here: it returns the tile to its original place (a no-op).
    ///
    /// The folder takes the target's cell and is always 2×2 (D20), neighbors are
    /// pushed down in a cascade (D31), and the dragged tile's cell is left
    /// as a hole (``TesseraTileStore/createFolder(from:onto:title:columns:)``).
    ///
    /// The D14 operation consists of two approved steps (creating a folder from
    /// the target tile, adding the dragged one), but it is performed atomically:
    /// ``TesseraTileStore`` does not change the model if the host refuses at any step,
    /// — the model stays exactly as before the drop, and the delegate receives only
    /// `didFailGrouping` (the folder did not exist, so `folderID == nil`).
    /// `didCreateFolder` arrives only after both steps succeed, before
    /// `didAdd`.
    ///
    /// - Parameters:
    ///   - session: The drag session.
    ///   - targetID: The tile whose center the drop landed on.
    private func dropIntoNewFolder(_ session: TesseraTileDragSession, targetID: AnyHashable) {
        let folder: TesseraTileFolder
        switch store.createFolder(
            from: session.itemID,
            onto: targetID,
            title: resolvedNewFolderTitle(configuration.folderTitle),
            columns: session.columns
        ) {
        case .created(let created):
            folder = created
        case .createDenied:
            failGroupingDrop(
                .createFolder,
                session: session,
                folderID: nil,
                reason: TesseraStartScreenStrings.string(.a11yGroupingReasonCreateDenied)
            )
            return
        case .addDenied:
            failGroupingDrop(
                .addToFolder,
                session: session,
                folderID: nil,
                reason: TesseraStartScreenStrings.string(.a11yGroupingReasonTileAddDenied)
            )
            return
        }

        session.modelChanged = true
        store.collapseEmptyRows(columns: session.columns)
        render(animated: true)
        // The folder frame is read after `render` — before it there is no new tile in
        // the grid, and the snapshot would fly to the placeholder's old slot.
        let folderFrame = grid.frame(forItemID: folder.id) ?? session.placeholder.frame
        delegate?.tileEditCoordinator(self, didCreateFolder: folder)
        delegate?.tileEditCoordinator(self, didAdd: session.itemID, toFolder: folder.id)
        announce(TesseraStartScreenStrings.string(.a11yFolderCreatedFromTwoTiles))
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        collapseDragView(session, into: folderFrame) {
            self.cleanupDrag(session, unhide: false)
            self.postLayoutChanged(focusing: folder.id)
        }
    }

    /// Returns a tile to its place after the approval function refused (D14).
    ///
    /// The order preview did not write to the model; the grid is synchronized with the current
    /// `TesseraTileStore` state, not with the base snapshot: the model may have changed
    /// externally, and otherwise the screen would diverge from it. A two-step folder creation
    /// is rolled back in the store as a whole, so if it refuses the model
    /// matches the state before the drop.
    ///
    /// - Parameters:
    ///   - action: The rejected operation.
    ///   - session: The drag session.
    ///   - folderID: The target folder.
    ///   - reason: The reason for the announcement.
    private func failGroupingDrop(
        _ action: TesseraTileGroupingAction,
        session: TesseraTileDragSession,
        folderID: AnyHashable?,
        reason: String
    ) {
        render(animated: true)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        announce(String(format: TesseraStartScreenStrings.string(.a11yGroupingFailedFormat), reason))
        delegate?.tileEditCoordinator(
            self,
            didFailGrouping: action,
            tileID: session.itemID,
            folderID: folderID
        )

        settleDragView(session) {
            self.cleanupDrag(session, unhide: true)
        }
    }

    /// Returns the model order to the grid (a drag cancel).
    ///
    /// The model did not change during the drag — the preview lives only in the grid, so
    /// the rollback does not write to `TesseraTileStore` and does not call the host's `onChange`. The source
    /// of truth is the current model snapshot, not the grab base: if the model has managed to
    /// change externally, the grid must not roll back to a stale order.
    private func restore() {
        syncGridWithModel(animated: true)
    }

    /// The current frame of the dragged element (after a repack).
    ///
    /// - Parameter session: The drag session.
    /// - Returns: The frame in grid coordinates.
    private func currentFrame(of session: TesseraTileDragSession) -> CGRect {
        grid.frame(forItemID: session.itemID) ?? session.placeholder.frame
    }

    /// Removes the snapshot, the placeholder and the highlight, and returns the source cell.
    ///
    /// - Parameters:
    ///   - session: The drag session.
    ///   - unhide: Whether to show the source cell (the element stayed on the grid).
    private func cleanupDrag(_ session: TesseraTileDragSession, unhide: Bool) {
        // The attraction spring may not have finished playing — it is removed together with
        // the overlays so that it does not revive an already removed snapshot.
        stopMagnetAnimation(session)
        session.magnetTarget = nil
        session.dragView.removeFromSuperview()
        session.placeholder.removeFromSuperview()
        stopPlaceholderAnimation()
        hideDropHighlight()

        if unhide {
            grid.setItemHidden(false, forItemID: session.itemID)
        }
        reconcileEditControls(animated: false)
    }

    /// Cancels the drag immediately (leaving edit mode, backgrounding).
    ///
    /// A cancel is only a return to the grid's base order; the model is not
    /// written, so the rollback is instant and does not depend on `TesseraTileStore`.
    private func cancelDragImmediately() {
        guard let session = dragSession else { return }

        stopTicker()
        resetMergeHover()
        resetReorderDwell()
        // An unfinished attraction spring must not outlive the session —
        // the snapshot is removed immediately, without a tail animation.
        stopMagnetAnimation(session)
        session.magnetTarget = nil
        dragSession = nil
        grid.isScrollEnabled = true
        hideDropHighlight()

        if session.panelReorder != nil { grid.endPanelReorder() }
        restore()
        session.dragView.removeFromSuperview()
        session.placeholder.removeFromSuperview()
        stopPlaceholderAnimation()
        grid.setItemHidden(false, forItemID: session.itemID)
        reconcileEditControls(animated: false)
        endDragStoreTransaction(saveIfNeeded: session.modelChanged)
    }

    /// Plays the snapshot's return to its place and calls the completion.
    ///
    /// - Parameters:
    ///   - session: The drag session.
    ///   - frame: Where to return.
    ///   - completion: The completion (remove the overlays).
    private func moveDragView(
        _ session: TesseraTileDragSession,
        to frame: CGRect,
        completion: @escaping () -> Void
    ) {
        UIView.animate(
            withDuration: isReduceMotionEnabled() ? 0.1 : 0.2,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut],
            animations: {
                session.dragView.transform = .identity
                session.dragView.bounds = CGRect(origin: .zero, size: frame.size)
                session.dragView.center = CGPoint(x: frame.midX, y: frame.midY)
                session.dragView.alpha = 1
            },
            completion: { _ in completion() }
        )
    }

    /// Shrinks the snapshot into the folder and removes it (a drop onto a folder).
    ///
    /// - Parameters:
    ///   - session: The drag session.
    ///   - frame: The folder frame.
    ///   - completion: The completion.
    private func collapseDragView(
        _ session: TesseraTileDragSession,
        into frame: CGRect,
        completion: @escaping () -> Void
    ) {
        lastCollapseTargetFrame = frame
        let reduceMotion = isReduceMotionEnabled()
        UIView.animate(
            withDuration: reduceMotion ? 0.12 : 0.22,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseIn],
            animations: {
                session.dragView.bounds = CGRect(origin: .zero, size: frame.size)
                session.dragView.center = CGPoint(x: frame.midX, y: frame.midY)
                session.dragView.alpha = 0
                if !reduceMotion {
                    session.dragView.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
                }
            },
            completion: { _ in completion() }
        )
    }

    // MARK: - Drag autosave transaction

    /// Turns autosave off for the duration of a drag.
    ///
    /// The order preview does not touch the model, but a drop may consist of
    /// several mutations (folder creation + adding a tile), and
    /// `TesseraTileStore.save()` is synchronous: without a transaction each of them would write
    /// the JSON separately. The state is saved once in
    /// ``endDragStoreTransaction(saveIfNeeded:)``.
    private func beginDragStoreTransaction() {
        guard autosavesBeforeDrag == nil else { return }
        autosavesBeforeDrag = store.autosaves
        store.autosaves = false
    }

    /// Restores autosave and writes the state if needed.
    ///
    /// - Parameter saveIfNeeded: Whether the model changed during the drag (including the drop).
    private func endDragStoreTransaction(saveIfNeeded: Bool) {
        guard let wasEnabled = autosavesBeforeDrag else { return }
        autosavesBeforeDrag = nil
        store.autosaves = wasEnabled

        guard wasEnabled, saveIfNeeded else { return }
        // A write error must not break the gesture: the store remains the in-memory source
        // of truth, and diagnostics are the host's concern (see TesseraTileStore.save()).
        try? store.save()
    }

    // MARK: - Auto-scroll while dragging

    /// Starts the ticker while a drag is in progress.
    private func startTickerIfNeeded() {
        guard displayLink == nil else { return }

        let link = CADisplayLink(
            target: displayLinkProxy,
            selector: #selector(TesseraTileEditTickerProxy.tick(_:))
        )
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Stops the auto-scroll ticker.
    private func stopTicker() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// A ticker frame: edge scrolling and recomputing the target under the finger.
    ///
    /// The ticker runs only during a drag (not throughout the whole editing session),
    /// so it does not spend frames while idle.
    ///
    /// - Parameter link: The ticker.
    fileprivate func displayLinkDidFire(_ link: CADisplayLink) {
        guard let session = dragSession else {
            stopTicker()
            return
        }
        // Auto-scroll is also a drag step; an external change cancels
        // the session before the targets are recomputed.
        guard dragStateIsConsistent(session) else {
            cancelDragForExternalChange()
            return
        }

        let bounds = grid.bounds
        let edge = max(1, configuration.autoScrollEdge)
        let point = session.lastPoint

        var delta: CGFloat = 0
        if point.y < edge {
            delta = -autoScrollSpeed(distance: edge - point.y)
        } else if point.y > bounds.height - edge {
            delta = autoScrollSpeed(distance: point.y - (bounds.height - edge))
        }

        guard delta != 0 else { return }

        let offset = grid.contentOffset
        let maximumY = max(0, grid.contentSize.height - bounds.height)
        let newY = min(max(offset.y + delta, 0), maximumY)
        guard abs(newY - offset.y) > 0.01 else { return }

        // The offset moves the content under the stationary finger; the snapshot stays
        // under the finger, while the placeholder and the target are recomputed.
        grid.setContentOffset(CGPoint(x: offset.x, y: newY), animated: false)
        session.placeholder.frame = currentFrame(of: session)
        updateHoverTargets(at: point)
    }

    /// The auto-scroll speed by distance to the edge.
    ///
    /// - Parameter distance: The distance to the edge in points.
    /// - Returns: The displacement per frame.
    private func autoScrollSpeed(distance: CGFloat) -> CGFloat {
        let edge = max(1, configuration.autoScrollEdge)
        let ratio = min(1, max(0, distance / edge))
        let speed = configuration.autoScrollMaximumSpeed * ratio
        return max(1, speed)
    }

    // MARK: - Edit overlays

    /// Creates or updates the unpin/size buttons for the visible tiles.
    ///
    /// The buttons are subviews of the grid, not of the cells: this way they do not suffer from
    /// cell reuse and move together with the tile by updating `frame`
    /// in the scroll handler (without grid layout).
    ///
    /// The dimming is also re-applied here: new and reused cells
    /// may have appeared at full brightness, so the transparency is set
    /// after configuration. The dimming owner is the grid.
    ///
    /// - Parameters:
    ///   - animated: Whether to animate the buttons moving on resize/reorder.
    ///   - dimAnimated: Whether to animate the transparency transition (entering the mode).
    private func reconcileEditControls(animated: Bool, dimAnimated: Bool = false) {
        guard isEditing else {
            removeAllEditControls()
            return
        }

        syncEditControlsHost()
        let items = grid.items
        let actualIDs = Set(items.map { $0.id })

        for itemID in editControls.keys where !actualIDs.contains(itemID) {
            editControls[itemID]?.removeFromSuperview()
        }
        editControls = editControls.filter { actualIDs.contains($0.key) }

        let reduceMotion = isReduceMotionEnabled()
        // D39: the jiggle applies only with an explicit host parameter and not with Reduce Motion.
        let jiggleEnabled = configuration.isJiggleEnabled && !reduceMotion
        let folderTargets = store.snapshot().folders
        // Overlays are created only for tiles near the screen (and one screen height
        // of margin): there is no point keeping buttons for a hundred distant tiles.
        let creationBounds = grid.bounds.insetBy(dx: 0, dy: -grid.bounds.height)
        // D29: a tile's badge steps around the size arrow — the grid is told
        // how much of the corner it occupies.
        var badgeClearances: [AnyHashable: CGFloat] = [:]

        for item in items {
            guard let frame = grid.frame(forItemID: item.id) else { continue }

            // The dragged tile is hidden: its overlay is not needed until the drag ends.
            if item.id == dragSession?.itemID {
                editControls[item.id]?.removeFromSuperview()
                editControls.removeValue(forKey: item.id)
                continue
            }

            let control: TesseraTileEditControlView
            if let existing = editControls[item.id] {
                control = existing
            } else {
                guard frame.intersects(creationBounds) else { continue }
                control = makeControl(for: item)
                // A new overlay immediately takes the tile's place — otherwise the
                // animated pass would animate it from a zero frame
                // (flying in from the grid's top-left corner).
                control.frame = frame
                editControls[item.id] = control
            }

            let canUnpin = item.tile != nil
            let canResize = supportedSizes(for: item).count > 1
            control.configure(canUnpin: canUnpin, canResize: canResize)
            control.layer.zPosition = 200
            badgeClearances[item.id] = canResize
                ? TesseraTileEditControlView.badgeClearance(
                    forTileSize: frame.size,
                    maxDiameter: configuration.controlDiameter
                )
                : 0

            let isDragged = dragSession?.itemID == item.id
            control.isHidden = isDragged || !frame.intersects(grid.bounds)
            control.tileSize = frame.size

            if animated, !reduceMotion, control.frame != frame {
                UIView.animate(
                    withDuration: 0.24,
                    delay: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction],
                    animations: {
                        control.frame = frame
                    },
                    completion: nil
                )
            } else {
                control.frame = frame
            }

            // The jiggle goes on the cell's content layer, as expected (otherwise
            // UICollectionView would reset the cell's own transform). The overlay with
            // the buttons gets the same animation and phase so that the
            // unpin/size buttons rotate together with the tile around its center.
            if let cell = grid.cellView(forItemID: item.id) as? TesseraTileCell,
               cell.itemID == item.id {
                applyJiggle(
                    to: cell.contentView,
                    itemID: item.id,
                    enabled: jiggleEnabled
                )
            }
            applyJiggle(to: control, itemID: item.id, enabled: jiggleEnabled)
            applyEditActions(to: item, folders: folderTargets)
        }
        applyPanelEditActions(folders: folderTargets)
        reconcilePanelEditControls(fadesIn: false)
        grid.setBadgeEditClearances(badgeClearances, animated: animated || dimAnimated)

        // After configuring the cells — set the transparency again.
        applyEditDimming(animated: dimAnimated)
    }

    /// Creates an overlay with buttons and subscribes them to actions.
    ///
    /// - Parameter item: The element (the closures need only the identifier).
    /// - Returns: The new overlay, already added to the grid.
    private func makeControl(for item: TesseraTileGridItem) -> TesseraTileEditControlView {
        let control = TesseraTileEditControlView(diameter: configuration.controlDiameter)
        let itemID = item.id
        control.onUnpin = { [weak self] in
            self?.unpin(itemID)
        }
        control.onResize = { [weak self] in
            self?.cycleSize(of: itemID)
        }
        editControlsContainer().addSubview(control)
        return control
    }

    /// Returns the buttons' clipping container, creating it if needed.
    ///
    /// The container sits above the collection (`zPosition` 200, as the buttons
    /// themselves used to: below the drag snapshot and the placeholder) and mirrors the `bounds`
    /// of the grid.
    private func editControlsContainer() -> TesseraTileEditControlsHostView {
        if let host = editControlsHost, host.superview === grid {
            syncEditControlsHost()
            return host
        }
        let host = TesseraTileEditControlsHostView()
        host.layer.zPosition = 200
        grid.addSubview(host)
        editControlsHost = host
        syncEditControlsHost()
        return host
    }

    /// Aligns the button container with the grid's `bounds` (`frame` only).
    private func syncEditControlsHost() {
        guard let host = editControlsHost, host.frame != grid.bounds else { return }
        host.frame = grid.bounds
    }

    // MARK: - Buttons on folder panel tiles (D46)

    /// Creates, moves and removes the unpin buttons on the panel's tiles.
    ///
    /// The buttons exist only when: editing is on, there is no drag, the panel is visible,
    /// its cells match the folder's composition and it is **not moving** (not
    /// opening or closing). Otherwise all panel buttons are removed. The button
    /// of a tile that is currently flying away (``unpinPanelTile(_:)``) is not shown.
    /// This is the same overlay as on grid tiles (the shared size and corner —
    /// ``TesseraTileEditControlView/unpinButtonFrame(inTileBounds:side:isRightToLeft:)``),
    /// but only with the unpin button and with a reduced touch area.
    ///
    /// - Parameter fadesIn: Whether to fade the new buttons in smoothly (panel expansion);
    ///   with Reduce Motion they appear immediately.
    private func reconcilePanelEditControls(fadesIn: Bool) {
        guard isEditing, dragSession == nil, !grid.isFolderChangeAnimating,
              let geometry = grid.panelShortcutGeometry(),
              geometry.frames.count == geometry.tileIDs.count else {
            removeAllPanelEditControls()
            return
        }

        syncEditControlsHost()
        let liveIDs = Set(geometry.tileIDs)
        for (tileID, control) in panelEditControls where !liveIDs.contains(tileID) {
            control.removeFromSuperview()
        }
        panelEditControls = panelEditControls.filter { liveIDs.contains($0.key) }

        let animatesAppearance = fadesIn && !isReduceMotionEnabled()
        let outset = min(
            TesseraTileEditControlView.cornerOverhang,
            max(0, geometry.spacing)
        )
        for (index, tileID) in geometry.tileIDs.enumerated() {
            // The tile is flying away: its button has already been removed and does not return until the end.
            if unpinsInFlight.contains(tileID) {
                removePanelControl(for: tileID)
                continue
            }

            let frame = geometry.frames[index]
            let control: TesseraTileEditControlView
            if let existing = panelEditControls[tileID] {
                control = existing
            } else {
                control = makePanelControl(for: tileID)
                control.frame = frame
                control.tileSize = frame.size
                panelEditControls[tileID] = control
                if animatesAppearance {
                    control.alpha = 0
                    UIView.animate(
                        withDuration: 0.18,
                        delay: 0,
                        options: [.allowUserInteraction, .curveEaseOut],
                        animations: { control.alpha = 1 },
                        completion: nil
                    )
                }
            }
            control.panelHitOutset = outset
            control.tileSize = frame.size
            control.frame = frame
            control.isHidden = !frame.intersects(grid.bounds)
        }
    }

    /// Moves the panel buttons along with the tiles on scroll (`frame` only).
    private func updatePanelEditControlFrames() {
        guard !panelEditControls.isEmpty else { return }
        guard let geometry = grid.panelShortcutGeometry(),
              !grid.isFolderChangeAnimating else {
            for control in panelEditControls.values { control.isHidden = true }
            return
        }

        syncEditControlsHost()
        for (index, tileID) in geometry.tileIDs.enumerated() {
            guard let control = panelEditControls[tileID] else { continue }
            let frame = geometry.frames[index]
            control.frame = frame
            control.tileSize = frame.size
            control.isHidden = !frame.intersects(grid.bounds)
        }
    }

    /// Creates a panel tile's overlay: only the unpin button.
    ///
    /// - Parameter tileID: The identifier of the folder's tile.
    /// - Returns: The overlay, already added to the button container.
    private func makePanelControl(for tileID: AnyHashable) -> TesseraTileEditControlView {
        let control = TesseraTileEditControlView(diameter: configuration.controlDiameter)
        control.isPanelMember = true
        // No size arrow: a folder member has no size of its own; the folder
        // itself has no unpin per D38, so a folder overlay does not get here.
        control.configure(canUnpin: true, canResize: false)
        control.layer.zPosition = 200
        control.onUnpin = { [weak self] in
            self?.unpinPanelTile(tileID)
        }
        editControlsContainer().addSubview(control)
        return control
    }

    /// Removes a panel tile's button.
    private func removePanelControl(for tileID: AnyHashable) {
        panelEditControls[tileID]?.removeFromSuperview()
        panelEditControls.removeValue(forKey: tileID)
    }

    /// Removes all panel buttons.
    private func removeAllPanelEditControls() {
        for control in panelEditControls.values {
            control.removeFromSuperview()
        }
        panelEditControls.removeAll()
    }

    /// Removes an element's overlay.
    ///
    /// - Parameter itemID: The element identifier.
    private func removeControl(for itemID: AnyHashable) {
        editControls[itemID]?.removeFromSuperview()
        editControls.removeValue(forKey: itemID)
    }

    /// Removes all overlays and custom actions.
    private func removeAllEditControls() {
        for control in editControls.values {
            control.removeFromSuperview()
        }
        editControls.removeAll()
        removeAllPanelEditControls()
        editControlsHost?.removeFromSuperview()
        editControlsHost = nil
        // The arrows are gone — badges return to the corner (D29).
        grid.resetBadgeEditClearances(animated: true)

        for cell in cellsWithEditActions.values {
            cell.accessibilityCustomActions = nil
        }
        cellsWithEditActions.removeAll()
        editActionsItemByCell.removeAll()
    }

    /// Updates the overlays' `frame`/visibility and the dimming on scroll.
    ///
    /// Called from the `contentOffset` observation; only the
    /// `frame`/`isHidden` of the buttons and the `alpha` of the cell content change here — layout is not
    /// recalculated (CORE-IOS-DESIGN.md §2).
    private func scrollOffsetDidChange() {
        guard isEditing else { return }

        syncEditControlsHost()
        for (itemID, control) in editControls {
            guard let frame = grid.frame(forItemID: itemID) else {
                control.isHidden = true
                continue
            }
            control.frame = frame
            control.tileSize = frame.size
            control.isHidden = dragSession?.itemID == itemID
                || !frame.intersects(grid.bounds)
        }

        updatePanelEditControlFrames()

        // `prepareForReuse` on a reused cell returned alpha 1 —
        // restore the dimming. This is only `alpha` (a property allowed on the hot
        // path), no layout. We limit it to tiles with buttons
        // (the visible area + a margin) so as not to copy the whole snapshot every frame.
        applyEditDimming(animated: false, limitedTo: Array(editControls.keys))

        // Buttons for tiles that came into the frame while scrolling are created outside
        // the scroll callback — to avoid performing layout inside it.
        scheduleReconcile()
    }

    /// Schedules a button reconcile for the next runloop pass.
    private func scheduleReconcile() {
        guard isEditing, !hasScheduledReconcile else { return }
        hasScheduledReconcile = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasScheduledReconcile = false
            guard self.isEditing else { return }
            // By this time the host has already applied the external snapshot —
            // an active drag with a diverged state is safely cancelled.
            if let session = self.dragSession, !self.dragStateIsConsistent(session) {
                self.cancelDragForExternalChange()
                return
            }
            self.reconcileEditControls(animated: false)
        }
    }

    // MARK: - Jiggle and accessibility

    /// Attaches/removes the jiggle on a view's layer.
    ///
    /// - Parameters:
    ///   - view: The cell layer (content) or the button overlay.
    ///   - itemID: The tile identifier — the phase depends on it.
    ///   - enabled: Whether the jiggle is enabled (Reduce Motion turns it off).
    private func applyJiggle(to view: UIView, itemID: AnyHashable, enabled: Bool) {
        guard enabled else {
            view.layer.removeAnimation(forKey: TesseraTileEditCoordinator.jiggleKey)
            return
        }
        guard view.layer.animation(forKey: TesseraTileEditCoordinator.jiggleKey) == nil else {
            return
        }

        let spec = jiggleSpec(for: itemID)
        view.layer.add(
            TesseraTileEditCoordinator.makeJiggleAnimation(spec: spec),
            forKey: TesseraTileEditCoordinator.jiggleKey
        )
    }

    /// Removes the jiggle from all visible cells.
    private func removeAllJiggle() {
        for item in grid.items {
            if let cell = grid.cellView(forItemID: item.id) as? TesseraTileCell {
                cell.contentView.layer.removeAnimation(
                    forKey: TesseraTileEditCoordinator.jiggleKey
                )
            }
            editControls[item.id]?.layer.removeAnimation(
                forKey: TesseraTileEditCoordinator.jiggleKey
            )
        }
        jiggleSpecs.removeAll()
    }

    /// The jiggle parameters for a tile (deterministic by seed and id).
    ///
    /// - Parameter itemID: The tile identifier.
    /// - Returns: The amplitude, duration and phase.
    private func jiggleSpec(for itemID: AnyHashable) -> TesseraJiggleSpec {
        if let cached = jiggleSpecs[itemID] {
            return cached
        }

        let identity = String(describing: itemID.base)
        let hash = TesseraTileEditCoordinator.stableHash(identity)
        var generator = TesseraSeededGenerator(seed: configuration.seed ^ hash)

        let amplitudeFactor = 0.85 + 0.3 * TesseraTileEditCoordinator.unitRandom(&generator)
        let durationFactor = 0.85 + 0.3 * TesseraTileEditCoordinator.unitRandom(&generator)
        let phaseFactor = TesseraTileEditCoordinator.unitRandom(&generator)

        let degrees = max(0.5, configuration.jiggleAngle) * CGFloat(amplitudeFactor)
        let duration = max(0.08, configuration.jiggleDuration * durationFactor)
        let spec = TesseraJiggleSpec(
            angle: degrees * .pi / 180,
            duration: duration,
            timeOffset: TimeInterval(phaseFactor) * duration
        )
        jiggleSpecs[itemID] = spec
        return spec
    }

    /// Sets resize/unpin/"add to folder" custom actions on a cell (§9).
    ///
    /// The cell is a single accessibility element, so VoiceOver does not see
    /// the button subviews; the actions are added to the cell itself. For a tile on the grid,
    /// "Add to folder <name>" is added to "Unpin"/"Change size",
    /// one per folder (no more than ``maxFolderActions``). The operations go through
    /// the public ``addToFolder(_:folderID:)`` — the host approval function (D14),
    /// the announcement and the focus are already there. A folder tile has no new actions.
    ///
    /// - Parameters:
    ///   - item: The grid element.
    ///   - folders: The model's folders in grid order.
    private func applyEditActions(to item: TesseraTileGridItem, folders: [TesseraTileFolder]) {
        guard let cell = grid.cellView(forItemID: item.id) as? TesseraTileCell,
              cell.itemID == item.id else {
            return
        }

        let key = ObjectIdentifier(cell)
        let targets = item.tile != nil ? Array(folders.prefix(TesseraTileEditCoordinator.maxFolderActions)) : []
        let signature: [AnyHashable] = [item.id] + targets.map { $0.id }
        guard editActionsItemByCell[key] != signature else { return }

        var actions: [UIAccessibilityCustomAction] = []
        if item.tile != nil {
            actions.append(
                UIAccessibilityCustomAction(name: TesseraStartScreenStrings.string(.a11yActionUnpin), image: nil) { [weak self] _ in
                    guard let self else { return false }
                    self.unpin(item.id)
                    return true
                }
            )
        }
        if supportedSizes(for: item).count > 1 {
            actions.append(
                UIAccessibilityCustomAction(name: TesseraStartScreenStrings.string(.a11yActionResize), image: nil) { [weak self] _ in
                    guard let self else { return false }
                    self.cycleSize(of: item.id)
                    return true
                }
            )
        }
        for folder in targets {
            let name = String(
                format: TesseraStartScreenStrings.string(.a11yActionAddToFolderFormat),
                folderActionTitle(folder)
            )
            let folderID = folder.id
            actions.append(
                UIAccessibilityCustomAction(name: name, image: nil) { [weak self] _ in
                    guard let self else { return false }
                    return self.addToFolder(item.id, folderID: folderID)
                }
            )
        }

        cell.accessibilityCustomActions = actions.isEmpty ? nil : actions
        cellsWithEditActions[key] = cell
        editActionsItemByCell[key] = signature
    }

    /// Sets custom actions on the tiles of an expanded folder's panel.
    ///
    /// "Remove from folder" is ``moveBetweenFolders(_:to:)`` with `nil`: the tile
    /// lands right after the folder (or in its place if it dissolved).
    /// "Unpin" is ``unpin(_:)`` (D45: with two tiles the folder dissolves).
    /// "Move earlier"/"Move later" is ``moveWithinFolder(_:to:)`` by
    /// one position (the first tile has no "earlier", the last has no "later").
    /// "Move to folder <name>" — one per other folder (no more than
    /// ``maxFolderActions``). Outside edit mode there are no actions.
    ///
    /// - Parameter folders: The model's folders in grid order.
    private func applyPanelEditActions(folders: [TesseraTileFolder]) {
        guard isEditing, let panel = grid.panelShortcuts() else { return }

        let targets = folders
            .filter { $0.id != panel.folder.id }
            .prefix(TesseraTileEditCoordinator.maxFolderActions)
        for (index, cell) in panel.cells.enumerated() where panel.folder.tiles.indices.contains(index) {
            let tileID = panel.folder.tiles[index].id
            let key = ObjectIdentifier(cell)
            // The tile's position in the folder is part of the signature: after a reorder
            // or a neighbor leaving, the "earlier/later" set changes.
            let signature: [AnyHashable] = [tileID, panel.folder.id, index, panel.folder.tiles.count]
                + targets.map { $0.id }
            guard editActionsItemByCell[key] != signature else { continue }

            var actions: [UIAccessibilityCustomAction] = [
                UIAccessibilityCustomAction(
                    name: TesseraStartScreenStrings.string(.a11yActionRemoveFromFolder),
                    image: nil
                ) { [weak self] _ in
                    guard let self else { return false }
                    return self.moveBetweenFolders(tileID, to: nil)
                },
                // D45: "Unpin" for a folder tile is the path by which a folder dissolves
                // "one by one" (as in Windows 10 Mobile); with two tiles the panel closes and the
                // remaining tile takes the folder's place.
                UIAccessibilityCustomAction(
                    name: TesseraStartScreenStrings.string(.a11yActionUnpin),
                    image: nil
                ) { [weak self] _ in
                    guard let self else { return false }
                    self.unpin(tileID)
                    return true
                },
            ]
            // D40: the order inside a folder changes in steps of one position;
            // an impossible action (the first one — "earlier", the last — "later") is not
            // offered.
            if index > 0 {
                actions.append(
                    UIAccessibilityCustomAction(
                        name: TesseraStartScreenStrings.string(.a11yActionMoveEarlier),
                        image: nil
                    ) { [weak self] _ in
                        guard let self else { return false }
                        return self.moveWithinFolder(tileID, to: index - 1)
                    }
                )
            }
            if index < panel.folder.tiles.count - 1 {
                actions.append(
                    UIAccessibilityCustomAction(
                        name: TesseraStartScreenStrings.string(.a11yActionMoveLater),
                        image: nil
                    ) { [weak self] _ in
                        guard let self else { return false }
                        return self.moveWithinFolder(tileID, to: index + 1)
                    }
                )
            }
            for folder in targets {
                let name = String(
                    format: TesseraStartScreenStrings.string(.a11yActionMoveToFolderFormat),
                    folderActionTitle(folder)
                )
                let folderID = folder.id
                actions.append(
                    UIAccessibilityCustomAction(name: name, image: nil) { [weak self] _ in
                        guard let self else { return false }
                        return self.moveBetweenFolders(tileID, to: folderID)
                    }
                )
            }
            cell.accessibilityCustomActions = actions
            cellsWithEditActions[key] = cell
            editActionsItemByCell[key] = signature
        }
    }

    /// The title of a new folder: empty means the localized default.
    ///
    /// The default value lives in the module's strings
    /// (`folderScreen.defaultTitle`, en/ru), not in the configuration:
    /// ``TesseraTileEditConfiguration/folderTitle`` merely overrides it.
    /// `TesseraTileStore` still accepts an empty title — the substitution is only
    /// on the editor's folder creation path.
    private func resolvedNewFolderTitle(_ title: String) -> String {
        title.isEmpty ? TesseraStartScreenStrings.string(.folderScreenDefaultTitle) : title
    }

    /// The folder title for custom action items: empty means from the configuration,
    /// then the shared label for an untitled folder.
    private func folderActionTitle(_ folder: TesseraTileFolder) -> String {
        if !folder.title.isEmpty { return folder.title }
        if !configuration.folderTitle.isEmpty { return configuration.folderTitle }
        return TesseraStartScreenStrings.string(.folderScreenDefaultTitle)
    }

    /// Announces a message with VoiceOver.
    ///
    /// - Parameter message: A ready localized string (``TesseraStartScreenStrings``).
    private func announce(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    // MARK: - Gestures

    /// Long press: entering editing and/or lifting a tile.
    ///
    /// - Parameter recognizer: The coordinator's gesture.
    @objc private func handleLongPressGesture(_ recognizer: UILongPressGestureRecognizer) {
        guard isEnabled else { return }

        let point = recognizer.location(in: grid)
        switch recognizer.state {
        case .began:
            guard grid.window != nil else { return }
            if let item = grid.item(at: point) {
                handleLongPress(on: item, at: point)
            } else {
                beginEditing()
            }

        case .changed:
            updateDrag(to: point)

        case .ended:
            finishDrag(commit: true)

        case .cancelled, .failed:
            finishDrag(commit: false)

        default:
            break
        }
    }

    /// A tap on an empty spot leaves editing.
    ///
    /// - Parameter recognizer: The coordinator's gesture.
    @objc private func handleBackgroundTap(_ recognizer: UITapGestureRecognizer) {
        performBackgroundTap(at: recognizer.location(in: grid))
    }

    /// The "tap on the background" gesture decision: whether a tap at the point leaves editing.
    ///
    /// Extracted from the handler so that a test can run "touch → `shouldReceive`
    /// decision → action" without a real `UITapGestureRecognizer`.
    ///
    /// - Parameter point: The tap point in grid coordinates.
    func performBackgroundTap(at point: CGPoint) {
        guard isEditing, dragSession == nil else { return }
        guard grid.item(at: point) == nil else { return }
        endEditing()
    }

    /// Whether a touch falls in an edit button's zone.
    ///
    /// The decision is made by the button container itself with the same `hitTest` the buttons
    /// use to receive touches (touch areas, RTL mirroring, visibility, overlaps
    /// of neighboring overlays), so the background gesture and the buttons cannot diverge.
    ///
    /// - Parameter touch: The background gesture's touch.
    /// - Returns: `true` if the touch lands on an unpin or size button.
    private func isEditControlHit(by touch: UITouch) -> Bool {
        guard let host = editControlsHost, host.superview === grid else { return false }
        return host.hitTest(touch.location(in: host), with: nil) != nil
    }

    /// The "tap on the background" gesture (for tests: checking `isEnabled` and `shouldReceive`).
    var backgroundTapGestureRecognizer: UIGestureRecognizer { backgroundTapRecognizer }

    // MARK: - Notifications

    /// Reduce Motion was toggled on the fly: restart/remove the jiggle.
    @objc private func reduceMotionStatusDidChange() {
        guard isEditing else { return }
        jiggleSpecs.removeAll()
        reconcileEditControls(animated: false)
    }

    /// The app goes to the background: an unfinished drag is rolled back.
    @objc private func applicationDidEnterBackground() {
        guard dragSession != nil else { return }
        cancelDragImmediately()
    }

    // MARK: - Helpers

    /// Finds the scrollable collection in the grid's hierarchy.
    ///
    /// - Parameter view: The search root.
    /// - Returns: The first `UIScrollView`, depth-first.
    private static func findScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }

    /// A cell snapshot for the fly-out (unpin) with a fallback.
    ///
    /// - Parameter cell: The visible cell.
    /// - Returns: A snapshot or `nil`.
    private static func makeSnapshot(of cell: TesseraTileCell) -> UIView? {
        if let snapshot = cell.snapshotView(afterScreenUpdates: false) {
            return snapshot
        }
        return cell.resizableSnapshotView(
            from: cell.bounds,
            afterScreenUpdates: true,
            withCapInsets: .zero
        )
    }

    /// A stable hash of a string (FNV-1a): the same across launches.
    ///
    /// - Parameter string: The string.
    /// - Returns: A 64-bit hash.
    private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// A uniform number in `0..<1` from a seedable generator.
    ///
    /// - Parameter generator: A `TesseraSeededGenerator` generator.
    /// - Returns: A number in the range `[0, 1)`.
    private static func unitRandom(_ generator: inout TesseraSeededGenerator) -> Double {
        Double(generator.next()) / Double(UInt64.max)
    }

    /// Creates the jiggle animation.
    ///
    /// The sway is a sinusoid, not three keyframes "−amplitude / +amplitude /
    /// −amplitude" with `easeInEaseOut`. A sine's speed at the extremes
    /// (`sin = ±1`) is zero and changes continuously, so at the turnaround there is no
    /// sharp braking followed by a jerk — which is exactly what read as
    /// "twitching" in the three-keyframe variant.
    ///
    /// The cycle is split into `N = 12` equal steps and sampled by the formula
    ///
    ///     values[i] = angle * sin(2π * i / N),   i = 0…N
    ///     keyTimes[i] = i / N
    ///
    /// Frame `i = N` closes the cycle: `sin(2π) = 0` matches `i = 0`, and
    /// `keyTimes` end exactly at 1.0 — Core Animation requires this;
    /// without the closing frame the last value would be held until the end of
    /// the duration and a jerk would appear at the cycle seam. Between frames the interpolation
    /// is linear: the shape of the curve is set by the sine samples themselves, and any
    /// extra nonlinearity would only distort it. A step of `1/12` with a cycle of
    /// 0.34–0.46 s is about 0.03 s, finer than a screen frame (60 Hz), so the polyline
    /// of 12 samples is visually indistinguishable from a sinusoid.
    ///
    /// `N = 12` is a compromise: 6–8 samples visibly "facet" on a slow cycle, while
    /// 24+ add extra interpolation computation on every layer of every tile
    /// with no visible difference.
    ///
    /// - Parameter spec: The sway parameters.
    /// - Returns: An infinitely repeating rotation animation.
    private static func makeJiggleAnimation(spec: TesseraJiggleSpec) -> CAKeyframeAnimation {
        let steps = 12

        // A sinusoid sampled at equal fractions of the cycle; the `steps` frame
        // closes it to zero so that `keyTimes` end at 1.0.
        let values: [CGFloat] = (0...steps).map { step in
            let phase = 2 * Double.pi * Double(step) / Double(steps)
            return CGFloat(sin(phase)) * spec.angle
        }
        let keyTimes: [NSNumber] = (0...steps).map { step in
            NSNumber(value: Double(step) / Double(steps))
        }

        // Linear segments: the sine samples themselves are interpolated, and the segments
        // need no easing of their own.
        let linear = CAMediaTimingFunction(name: .linear)

        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = values
        animation.keyTimes = keyTimes
        animation.timingFunctions = Array(repeating: linear, count: steps)
        animation.duration = spec.duration
        animation.timeOffset = spec.timeOffset
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// The localized size name for announcements.
    ///
    /// - Parameter size: The tile size.
    /// - Returns: The name for VoiceOver.
    private static func name(for size: TesseraTileSize) -> String {
        switch size {
        case .small: return TesseraStartScreenStrings.string(.a11ySizeSmall)
        case .medium: return TesseraStartScreenStrings.string(.a11ySizeMedium)
        case .wide: return TesseraStartScreenStrings.string(.a11ySizeWide)
        case .large: return TesseraStartScreenStrings.string(.a11ySizeLarge)
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension TesseraTileEditCoordinator: UIGestureRecognizerDelegate {

    /// Keeps the coordinator's long press from intercepting the overlay buttons.
    ///
    /// A button is a `UIControl`, its tap must reach it rather than start a drag.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard isEnabled else { return false }

        if gestureRecognizer === backgroundTapRecognizer {
            // A touch in the zone of any edit button (a grid tile or a panel tile,
            // including the part that sticks out into the gap and the zone enlarged to 44 pt) belongs
            // to the button: otherwise a tap on the protruding part would also fire as a "tap on an
            // empty spot" and leave editing.
            // While a folder name is being typed, a tap elsewhere only commits it
            // (the grid's gesture) and does not leave editing.
            return isEditing && dragSession == nil && !isEditControlHit(by: touch)
                && !grid.isEditingFolderName
        }
        if gestureRecognizer === longPressRecognizer {
            // A long press on a folder name is a rename, not entering
            // editing and not a drag.
            if grid.isFolderNameHit(at: touch.location(in: grid)) {
                return false
            }
            var view: UIView? = touch.view
            while let current = view {
                if current is UIControl {
                    return false
                }
                view = current.superview
            }
        }
        return true
    }

    /// Allows working simultaneously with the grid's own long press.
    ///
    /// The grid installs its own gesture only when the host has set `onLongPress`; if it
    /// delegates it to the coordinator, the two gestures must not "eat" each other.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard otherGestureRecognizer is UILongPressGestureRecognizer,
              let view = otherGestureRecognizer.view else {
            return false
        }
        // The grid's gesture lives on its collection, while the coordinator's gesture lives on the grid itself.
        return view.isDescendant(of: grid)
    }
}

// MARK: - Coordinator internal types

/// A pure state machine for the hold over a target tile.
///
/// It answers one question: "has the finger stayed over the center of a tile long enough and
/// still enough that releasing creates a folder?". There is no UIKit here,
/// so the machine is testable without a simulator (`TileMergeHoverTests`).
///
/// States:
/// - ``State/idle`` — there is no hold;
/// - ``State/armed`` — the finger is over the center of a tile, the countdown is running;
/// - ``State/fired`` — the threshold has elapsed, the drop creates a folder (``isMergeReady``).
///
/// The hold contract: "the finger stays within the tolerance (<10 pt)
/// for longer than the threshold (>600 ms), **counting from the last noticeable movement**".
/// A displacement from the anchor of the tolerance or more cancels the hold (including one that has
/// already completed) and **moves the anchor to the current point with a new countdown** — a finger
/// that reached the target's center in several steps is re-armed where it
/// stopped, rather than waiting for a return to the first point of entering the zone.
///
/// Time is read through the ``now`` closure rather than directly from the system clock:
/// tests substitute a controllable clock and check the threshold without `sleep`.
/// In production `CACurrentMediaTime()` is supplied — the same monotonic timebase
/// as `CADisplayLink` and Core Animation, so an app pause does not
/// shift the timer.
///
/// Transitions:
/// - ``beginHover(targetID:point:)``: a new tile —
///   `armed` with the anchor at the point and the countdown from the current moment; a repeated call
///   for the same tile in `armed`/`fired` does nothing, so that per-frame
///   calls do not restart the timer;
/// - ``update(point:)``: a displacement from the anchor of the tolerance or more — a cancel and
///   re-arm: `armed` with the anchor at the current point and the countdown from the current moment
///   (this replaces "cancelled until returning to the old anchor");
/// - ``timerFired()``: strictly more than the threshold has passed (`>600 ms`) —
///   `fired`, otherwise it stays `armed` (the timer may have fired slightly early because of
///   runloop rounding);
/// - ``reset()`` — `idle`.
///
/// The bounds are strict: a displacement of exactly the tolerance cancels the hold
/// (it must be "less than 10 pt"), and the time threshold must be exceeded (it must be
/// "more than 600 ms"). A constantly moving finger (every step ≥10 pt) does not
/// manage to complete the threshold — there is no readiness; a target change arrives through
/// ``beginHover(targetID:point:)`` or ``reset()``.
struct TesseraMergeHoverTracker {

    /// The hold state.
    enum State: Equatable {

        /// There is no hold.
        case idle

        /// The finger is over a tile, the countdown is running.
        case armed

        /// The threshold has elapsed: the drop will create a folder.
        case fired
    }

    /// How long the finger must be held (``TesseraTileEditConfiguration/mergeHoverDuration``).
    private let hoverDuration: TimeInterval

    /// The allowed finger displacement from the anchor in points
    /// (``TesseraTileEditConfiguration/mergeHoverDisplacement``).
    ///
    /// The radius is strict — the hold lives while the displacement is **less than**
    /// the tolerance. The value is sanitized: negative/non-numeric becomes 0.
    private let displacementThreshold: CGFloat

    /// A monotonic clock; injected for tests.
    private let now: () -> TimeInterval

    /// The moment the countdown was armed, by the ``now`` clock.
    private var startedAt: TimeInterval?

    /// The current state.
    private(set) var state: State = .idle

    /// The tile the hold is over.
    private(set) var targetID: AnyHashable?

    /// The point the finger displacement is measured from.
    private(set) var anchor: CGPoint?

    /// Creates the hold machine.
    ///
    /// - Parameters:
    ///   - hoverDuration: The hold threshold in seconds; negative values
    ///     are treated as 0 (merge immediately on hover).
    ///   - displacementThreshold: The displacement tolerance in points.
    ///   - now: A monotonic time provider; the system clock by default.
    init(
        hoverDuration: TimeInterval,
        displacementThreshold: CGFloat,
        now: @escaping () -> TimeInterval = { CACurrentMediaTime() }
    ) {
        self.hoverDuration = hoverDuration.isFinite ? max(0, hoverDuration) : 0
        self.displacementThreshold = displacementThreshold.isFinite
            ? max(0, displacementThreshold)
            : 0
        self.now = now
    }

    /// Whether a drop is ready to create a folder.
    var isMergeReady: Bool {
        state == .fired
    }

    /// Whether the hold countdown is running.
    var isArmed: Bool {
        state == .armed
    }

    /// How much remains until readiness; 0 if no countdown is running.
    ///
    /// Needed by the coordinator: the timer is scheduled for the remainder, so a repeated
    /// start after an early firing does not extend the hold.
    var remainingDuration: TimeInterval {
        guard state == .armed, let startedAt else { return 0 }
        return max(0, hoverDuration - (now() - startedAt))
    }

    /// Starts (or continues) a hold over a tile.
    ///
    /// A repeated call for the same tile in the `armed`/`fired` states is
    /// ignored: the coordinator calls the method on every finger step, and
    /// restarting the countdown would never let the hold complete.
    ///
    /// - Parameters:
    ///   - targetID: The tile under the finger.
    ///   - point: The finger point in grid coordinates — the displacement tolerance anchor.
    mutating func beginHover(targetID: AnyHashable, point: CGPoint) {
        if self.targetID == targetID, state == .armed || state == .fired {
            return
        }

        self.targetID = targetID
        anchor = point
        startedAt = now()
        state = .armed
    }

    /// Checks the finger displacement from the anchor and re-arms the hold.
    ///
    /// A displacement of the tolerance or more cancels the hold in both `armed` and
    /// `fired` (the "absorb" highlight promises a merge only while the finger
    /// stays still) and immediately starts a new one: the anchor moves to the current point,
    /// the countdown runs from the current moment, the state is `armed`. This way
    /// the hold is counted from the last noticeable movement; there is no need to return to the
    /// old anchor, and a constantly moving finger will not accumulate the threshold.
    ///
    /// - Parameter point: The current finger point in grid coordinates.
    /// - Returns: `true` if the hold was re-armed (the previous countdown and
    ///   readiness are invalid — the coordinator must recreate the timer and,
    ///   if it was `fired`, roll back the highlight).
    @discardableResult
    mutating func update(point: CGPoint) -> Bool {
        guard let anchor, state == .armed || state == .fired else { return false }

        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        // Comparing squares: hypot/`sqrt` is not needed here, the threshold is in points too.
        let distanceSquared = dx * dx + dy * dy
        let thresholdSquared = displacementThreshold * displacementThreshold
        // The tolerance is strict (`<10 pt`); with a zero tolerance only
        // the anchor point is allowed.
        let isWithinTolerance = displacementThreshold > 0
            ? distanceSquared < thresholdSquared
            : distanceSquared == 0

        guard !isWithinTolerance else { return false }

        // Moving the anchor and a new countdown from the current point.
        self.anchor = point
        startedAt = now()
        state = .armed
        return true
    }

    /// The hold timer fired.
    ///
    /// The threshold is strict — readiness comes only after `>600 ms`; at
    /// exactly 600 ms the hold has not completed yet, and the coordinator counts down the remainder.
    ///
    /// - Returns: `true` if the threshold has elapsed and the state became `fired`;
    ///   `false` if it is too early (the state stayed `armed`) or no countdown is running.
    @discardableResult
    mutating func timerFired() -> Bool {
        guard state == .armed, let startedAt else { return false }
        let elapsed = now() - startedAt
        let hasElapsed = hoverDuration == 0 ? elapsed >= 0 : elapsed > hoverDuration
        guard hasElapsed else { return false }

        state = .fired
        return true
    }

    /// Resets the hold to the initial state.
    mutating func reset() {
        state = .idle
        targetID = nil
        anchor = nil
        startedAt = nil
    }
}

/// The merge zone of a tile/folder: where the finger must land for the target to become
/// `.group`/`.folder`, and where it is held (D50).
///
/// Pure geometry with no UIKit state, so it is testable without a simulator
/// (`TileMergeZoneTests`).
///
/// - **Entry** (``entryRect(in:)``): a rectangle at the center of the frame; along each axis
///   its side is `max(50 % of the frame side, 36 pt)`, but no more than the side itself.
///   On a small 55 pt tile that is 36 pt (it used to be 27.5 pt), on a medium 118 pt tile it is
///   59 pt (as before), for a wide/large tile each axis is computed separately,
///   so the zone is no smaller than the former half of the frame.
/// - **Retention** (``retainRect(in:)``): when the target is already `.group`/`.folder`,
///   it holds while the finger is inside the frame shrunk by 6 pt — almost the whole tile.
///   This is hysteresis: finger jitter at the edge of the entry zone does not switch the target
///   between merge and placement (and so does not shuffle the preview back and forth or
///   restart the hold). The retention area is no smaller than the entry one.
enum TesseraTileMergeZone {

    /// The fraction of the frame side that the entry zone occupies.
    static let entryFraction: CGFloat = 0.5

    /// The minimum side of the entry zone per axis, in pt: the finger does not land in
    /// 27 pt on a small tile.
    static let entryMinimumSide: CGFloat = 36

    /// The inset of the retention area from the frame edges, in pt.
    static let retainInset: CGFloat = 6

    /// The merge entry zone in a frame.
    ///
    /// - Parameter frame: The tile/folder frame.
    /// - Returns: A rectangle at the center of the frame; empty if the frame is degenerate.
    static func entryRect(in frame: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let width = min(frame.width, max(frame.width * entryFraction, entryMinimumSide))
        let height = min(frame.height, max(frame.height * entryFraction, entryMinimumSide))
        return CGRect(
            x: frame.midX - width / 2,
            y: frame.midY - height / 2,
            width: width,
            height: height
        )
    }

    /// The merge target retention area in a frame.
    ///
    /// - Parameter frame: The tile/folder frame.
    /// - Returns: The frame shrunk by ``retainInset``, united with the entry zone.
    static func retainRect(in frame: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return frame.insetBy(dx: retainInset, dy: retainInset).union(entryRect(in: frame))
    }

    /// Whether the finger lies in the merge zone.
    ///
    /// - Parameters:
    ///   - point: The finger point in grid coordinates.
    ///   - frame: The tile/folder frame.
    ///   - isEngaged: The target was already a merge on this element (hysteresis):
    ///     then the retention area is checked, otherwise the entry zone.
    /// - Returns: `true` if the point is in the zone.
    static func contains(_ point: CGPoint, in frame: CGRect, isEngaged: Bool) -> Bool {
        (isEngaged ? retainRect(in: frame) : entryRect(in: frame)).contains(point)
    }
}

/// Pure magnetism-to-cells math.
///
/// It answers one question: "is there a slot center within the attraction radius that the
/// snapshot should glide to?". UIKit and the grid geometry are not part of it:
/// the coordinator passes the already computed centers
/// (`TesseraTileGridView.magnetSlotCenters(for:)`), so the function
/// is testable without a simulator (`TileMagnetTests`).
///
/// The attraction is only a visual layer (the Windows Phone spec): the push-physics targets and the
/// merge timer are computed from the finger point, not from the snapshot center,
/// so the magnet cannot change the order or create a folder.
enum TesseraTileMagnet {

    /// The center of the nearest slot within the attraction radius.
    ///
    /// The distance is plain Euclidean (by squares, without `sqrt`:
    /// the threshold is in points too — squares are comparable). The radius is inclusive:
    /// a center exactly at `snapRadius` still attracts. At equal distance
    /// the slot that comes earlier in the array wins — the result
    /// is deterministic and does not depend on the iteration order.
    ///
    /// - Parameters:
    ///   - point: The finger point in grid coordinates.
    ///   - slotCenters: The centers of virtual slots of the same size class.
    ///   - snapRadius: The attraction radius in points; `0`, negative and
    ///     non-numeric values disable the attraction.
    /// - Returns: The center of the nearest slot, or `nil` if there are no slots within the radius.
    static func magnetTarget(
        for point: CGPoint,
        slotCenters: [CGPoint],
        snapRadius: CGFloat
    ) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        guard snapRadius.isFinite, snapRadius > 0 else { return nil }

        let radiusSquared = snapRadius * snapRadius
        var best: CGPoint?
        var bestDistanceSquared = CGFloat.greatestFiniteMagnitude

        for center in slotCenters {
            guard center.x.isFinite, center.y.isFinite else { continue }

            let dx = center.x - point.x
            let dy = center.y - point.y
            let distanceSquared = dx * dx + dy * dy
            guard distanceSquared <= radiusSquared, distanceSquared < bestDistanceSquared else {
                continue
            }

            best = center
            bestDistanceSquared = distanceSquared
        }

        return best
    }

    /// The centers of virtual slots of size `size`.
    ///
    /// The grid is virtual: slots are iterated with a step of one unit
    /// vertically and horizontally, so cells that are currently empty
    /// are included in the result as well. A tile's footprint is clamped for a narrow grid by the same rule
    /// as in the layout (``TesseraTileLayoutEngine/fittingSize(_:columns:)``).
    ///
    /// The function knows nothing about `contentOffset` and RTL: the coordinator and the layout
    /// pass the content origin, and mirroring permutes
    /// the columns but leaves the set of centers the same.
    ///
    /// - Parameters:
    ///   - size: The size of the dragged tile (D15).
    ///   - columns: The number of grid columns, greater than zero.
    ///   - unit: The unit size in points.
    ///   - gap: The gap between neighboring units in points.
    ///   - origin: The origin of the grid's content.
    ///   - rowCount: The number of occupied grid rows in units.
    /// - Returns: The slot centers in the same coordinate space as `origin`;
    ///   an empty array for degenerate geometry.
    static func slotCenters(
        for size: TesseraTileSize,
        columns: Int,
        unit: CGFloat,
        gap: CGFloat,
        origin: CGPoint,
        rowCount: Int
    ) -> [CGPoint] {
        guard columns > 0, unit.isFinite, unit > 0, rowCount > 0,
              origin.x.isFinite, origin.y.isFinite else {
            return []
        }

        let fittedSize = TesseraTileLayoutEngine.fittingSize(size, columns: columns)
        let width = fittedSize.unitColumns
        let height = fittedSize.unitRows
        guard width > 0, height > 0, width <= columns, rowCount >= height else { return [] }

        let spacing = gap.isFinite ? max(gap, 0) : 0
        var centers: [CGPoint] = []
        centers.reserveCapacity((rowCount - height + 1) * (columns - width + 1))

        for row in 0...(rowCount - height) {
            for column in 0...(columns - width) {
                let slot = TesseraTileLayoutSlot(
                    id: AnyHashable(0),
                    size: fittedSize,
                    column: column,
                    row: row,
                    unit: unit
                )
                let rect = TesseraTileLayoutEngine.rect(
                    for: slot,
                    unit: unit,
                    gap: spacing,
                    origin: origin
                )
                centers.append(CGPoint(x: rect.midX, y: rect.midY))
            }
        }

        return centers
    }
}

/// The sway parameters of a single tile.
private struct TesseraJiggleSpec {

    /// The rotation amplitude in radians.
    let angle: CGFloat

    /// The cycle duration in seconds.
    let duration: TimeInterval

    /// The phase shift in seconds.
    let timeOffset: TimeInterval
}

/// The target under the finger during a drag.
///
/// The target is the **grid cell under the finger** (D21, D33), not an order slot.
/// Over an occupied cell the zone decides: the center is a merge (`.group`/`.folder`, by
/// hold, D14), the edge is `.cell` with the target element's cell (the dragged one
/// takes it, the target is pushed down in a cascade, D31). Over an empty cell
/// the target is exactly that cell; below the last occupied row it is "new row".
/// A drop onto the center without a completed hold returns the tile to its original place
/// (no-op).
enum HoverTarget: Equatable {

    /// There is no target (outside the grid, over its own base cell, over the panel of
    /// an expanded folder, the lift has not moved yet). The preview is the base
    /// layout, the drop is a no-op.
    case none

    /// Put the element on a cell (logical coordinates, not clamped to
    /// the canvas: that is done by `TesseraTileLayoutEngine.inserting` and the cell-based
    /// `TesseraTileStore` operations). For the edge zone of an occupied cell it is the target
    /// element's cell in the base layout; for an empty cell it is the cell under the finger.
    case cell(TesseraTileGridPlacement)

    /// A new row at the end of the canvas (the finger is below the last occupied row).
    case newRow

    /// The center zone of folder `id`: adding a tile to the folder by hold
    /// (D14). Without a hold the drop is a no-op.
    case folder(AnyHashable)

    /// Folder creation from tile `id` (a drop onto its center). Without a completed hold
    /// the drop is a no-op.
    case group(AnyHashable)

    /// The center of the source folder when dragging a tile out of it: there is no target, the drop
    /// returns the tile to the folder, the model does not change.
    case sourceFolder

    /// The identifier of the hold target, if the target supports one.
    ///
    /// The hold is armed both for the center of a tile (folder creation) and for the center of
    /// a folder tile (adding to a folder): it is one and the same machine
    /// ``TesseraMergeHoverTracker``.
    var mergeTargetID: AnyHashable? {
        switch self {
        case .folder(let itemID), .group(let itemID):
            return itemID
        case .none, .cell, .newRow, .sourceFolder:
            return nil
        }
    }

    /// The target highlight style before merge readiness.
    var baseHighlightStyle: TesseraTileDropHighlightView.Style? {
        switch self {
        case .folder:
            return .folder
        case .group:
            return .group
        case .none, .cell, .newRow, .sourceFolder:
            return nil
        }
    }
}

/// The resulting picture of the source folder's dissolution during a drag of a tile from the panel (D45).
///
/// The folder has two tiles: when the one being taken out leaves, the folder dissolves and the remaining
/// one takes its cell with its own size. The placement target's preview shows exactly
/// this, so the set is computed once at the grab — from the model placements, not
/// from the previous preview.
struct DragFolderDissolution {

    /// The folder that will dissolve.
    let folderID: AnyHashable

    /// The remaining tile that takes the folder's place.
    let remaining: TesseraTileDescriptor

    /// The grid elements after the dissolution: the folder is replaced by the remaining tile; the tile
    /// being taken out (the synthetic base element) stays in place.
    let items: [TesseraTileGridItem]

    /// The model placements **without** the tile being taken out: the folder is removed, the remaining
    /// tile is put on its cell by `TesseraTileLayoutEngine.inserting` (a larger one
    /// pushes neighbors down). The preview and "new row" are computed from them.
    let placements: [TesseraTilePlacedItem]
}

/// The state of reordering a tile inside an open folder panel (D40).
///
/// It lives in ``TesseraTileDragSession/panelReorder`` from the tile's lift until the finger
/// leaves the panel (then the session is replaced by a take-out) or until the drop/cancel.
/// The order and slots are computed from the folder's **base** order at the grab.
struct TesseraPanelReorder {

    /// The folder (from the grid snapshot at the grab).
    let folder: TesseraTileFolder

    /// The lifted tile.
    let tile: TesseraTileDescriptor

    /// The identifiers of the folder's tiles in the base order.
    let baseTileIDs: [AnyHashable]

    /// The index of the lifted tile in the base order.
    let sourceIndex: Int

    /// The slot the preview shows now (an index among the folder's tiles).
    var slot: Int
}

/// The active drag session.
///
/// A class, not a struct: the coordinator and the timer change `lastPoint`/`hover`
/// from different places, and copies of a value would diverge.
final class TesseraTileDragSession {

    /// The identifier of the dragged element.
    let itemID: AnyHashable

    /// Whether it is a tile (a folder cannot be dropped into a folder — there is no nesting).
    let isTile: Bool

    /// The source folder, if the tile is taken from an expanded folder's panel.
    ///
    /// `nil` means a regular drag of a grid element. For a drag from a folder ``itemID`` is a
    /// tile that is not among the model's elements on the grid: in ``baseSnapshot``
    /// it is inserted as a synthetic element right after the folder, and the model does not
    /// change until the drop.
    let sourceFolderID: AnyHashable?

    /// The real model snapshot at the grab.
    ///
    /// It equals ``baseSnapshot`` for a regular drag; for a drag from a folder it is
    /// without the synthetic tile. ``TesseraTileEditCoordinator`` uses it
    /// to check that the model has not changed externally.
    let modelBaseSnapshot: TesseraTileGridSnapshot

    /// The size class of the dragged element.
    ///
    /// The virtual slot grid is built from it: a tile can be attracted
    /// only to cells of the same size class (D15).
    let magnetSize: TesseraTileSize

    /// The offset of the snapshot center relative to the finger.
    let grabOffset: CGPoint

    /// The snapshot that follows the finger.
    let dragView: UIView

    /// The placeholder in the tile's place.
    let placeholder: UIView

    /// The last finger point in grid coordinates.
    var lastPoint: CGPoint

    /// The grab point in grid coordinates.
    ///
    /// The starting zone, in which the attraction is not engaged, is measured from it:
    /// the snapshot already stands in the original slot, and without this zone the tile
    /// would not follow the finger for the first ~28 pt of movement.
    let originPoint: CGPoint

    /// Whether the finger has left the starting grab zone.
    ///
    /// While `false` the attraction is off; it is raised once per session.
    var hasLeftOriginSlot = false

    /// The finger has moved from the grab point by more than
    /// ``TesseraTileEditCoordinator/emptySlotActivationDistance``.
    ///
    /// Until then the preview is not touched over an empty spot: at a tile lift from the
    /// panel the finger stands where the icon was, and the placeholder must not "run away"
    /// from under it in the same frame. It is raised once per session.
    var hasMovedFromOrigin = false

    /// The model snapshot at the grab: the elements and the cell table.
    ///
    /// The base for the layout preview (``basePlacements``) and for the
    /// "the model did not change externally" check: there are no own mutations during a drag,
    /// but an external writer (the host, the folder screen) may change the model —
    /// then the session is safely cancelled. It also stores `unpinned` —
    /// the grid's preview snapshots must preserve the list of tiles off the desktop, otherwise
    /// `update` would reset it.
    let baseSnapshot: TesseraTileGridSnapshot

    /// The snapshot the coordinator last asked the grid to show.
    ///
    /// At the grab it equals ``baseSnapshot``, then it is updated with every applied
    /// preview. The grid must show either it or the base: a divergence in composition
    /// and sizes means an external `grid.update` bypassing the coordinator.
    var expectedSnapshot: TesseraTileGridSnapshot

    /// A preview the coordinator asked to show but the grid deferred
    /// (a folder panel transition). It becomes ``expectedSnapshot`` when
    /// the grid applies it.
    var pendingSnapshot: TesseraTileGridSnapshot?

    /// A reorder inside an open folder panel; `nil` means a regular drag
    /// or a take-out of a tile from the panel. While it is not `nil`, the desktop targets, merge and
    /// grid previews do not work: the finger picks a panel slot.
    var panelReorder: TesseraPanelReorder?

    /// The current target under the finger.
    var hover: HoverTarget = .none

    /// The cell on which the dwell before the push-down preview is counting (D50);
    /// `nil` means no countdown (the target is not an occupied `.cell`, or the dwell is disabled).
    var reorderDwellCell: TesseraTileGridPlacement?

    /// The dwell on ``reorderDwellCell`` has completed: the push-down preview is shown.
    /// It is reset together with the cell.
    var isReorderDwellElapsed = false

    /// The finger is currently over an expanded folder's panel (D17).
    ///
    /// The attraction does not work over the panel: its place in the layout is fixed,
    /// and "sticking" the snapshot to the grid under the panel would look like a glitch.
    var isOverFolderPanel = false

    /// The center of the slot the snapshot is attracted to now.
    ///
    /// `nil` means no attraction, the snapshot follows the finger. It is stored so that
    /// per-frame updates do not restart the spring on every touch event.
    var magnetTarget: CGPoint?

    /// The active attraction spring animator.
    ///
    /// It is retained like the placeholder animator: the next target must
    /// stop the previous spring at the current frame rather than let it play to the end.
    var magnetAnimator: UIViewPropertyAnimator?

    /// The cache of base hit-test frames in content coordinates.
    ///
    /// Built lazily and reset when the grid geometry key changes.
    var baseFrames: (key: TesseraTileGridView.BaseFramesKey, frames: [AnyHashable: CGRect])?

    /// Whether the model changed during the drag (needed for the single save).
    ///
    /// Always `false` during a drag; set only on drop.
    var modelChanged = false

    /// The number of grid columns at the grab.
    ///
    /// Cells are computed on a canvas of this width; a change of grid columns in the middle of a drag
    /// cancels the session (``TesseraTileEditCoordinator``).
    let columns: Int

    /// The base placements of the top-level elements at the grab.
    ///
    /// The order is as in ``baseSnapshot``. The hit test and the preview are always computed from
    /// them, not from the previous preview: shifts do not accumulate. For a drag from a
    /// folder panel it includes the synthetic tile on the starting free cell.
    let basePlacements: [TesseraTilePlacedItem]

    /// The placements the grid shows now: the base ones or the
    /// result of `TesseraTileLayoutEngine.inserting` for the current target. They are needed so as not to
    /// send the grid the same preview twice.
    var previewPlacements: [TesseraTilePlacedItem]

    /// The model cells at the grab.
    ///
    /// Needed by the "the model did not change externally" check: for a drag from a folder
    /// ``basePlacements`` has a synthetic tile, while the model does not.
    let modelPlacements: [AnyHashable: TesseraTileGridPlacement]

    /// The resulting picture of the source folder's dissolution (D45): it has two tiles, and
    /// after one is taken out it dissolves. `nil` means the folder survives the take-out,
    /// the drag is not from a folder, or the folder has one tile (``dissolvingFolderID``).
    let folderDissolution: DragFolderDissolution?

    /// The source folder that will disappear on the drop: the tile in it is the last one.
    ///
    /// `TesseraTileStore` removes such a folder **before** computing the new row, so
    /// the preview and the magnet for the "new row" target do not count it either. D45: such a
    /// folder is only ever transitional (``TesseraTileStore/createFolder(withTile:title:columns:)``);
    /// a dissolution of a two-tile folder is ``folderDissolution``.
    var dissolvingFolderID: AnyHashable? {
        guard let sourceFolderID,
              let folder = modelBaseSnapshot.folders.first(where: { $0.id == sourceFolderID }),
              folder.tiles.count == 1 else {
            return nil
        }
        return sourceFolderID
    }

    /// The cell of the "new row" target for the dragged element: the first
    /// row after the last occupied one, column 0 — as `TesseraTileStore` will compute it
    /// (without the element itself and without the disappearing source folder).
    var newRowCell: TesseraTileGridPlacement {
        // D45: after a folder dissolution the rows are computed with the remaining tile in its
        // place, the same as in `TesseraTileStore.extractFromFolderToNewRow`.
        TesseraTileLayoutEngine.newRowCell(
            size: magnetSize,
            columns: columns,
            placements: folderDissolution?.placements
                ?? basePlacements.filter { $0.id != dissolvingFolderID },
            excluding: itemID
        )
    }

    init(
        itemID: AnyHashable,
        isTile: Bool,
        grabOffset: CGPoint,
        dragView: UIView,
        placeholder: UIView,
        lastPoint: CGPoint,
        baseSnapshot: TesseraTileGridSnapshot,
        magnetSize: TesseraTileSize,
        columns: Int,
        basePlacements: [TesseraTilePlacedItem],
        modelPlacements: [AnyHashable: TesseraTileGridPlacement],
        modelBaseSnapshot: TesseraTileGridSnapshot? = nil,
        sourceFolderID: AnyHashable? = nil,
        folderDissolution: DragFolderDissolution? = nil
    ) {
        self.folderDissolution = folderDissolution
        self.modelBaseSnapshot = modelBaseSnapshot ?? baseSnapshot
        self.sourceFolderID = sourceFolderID
        self.itemID = itemID
        self.columns = columns
        self.basePlacements = basePlacements
        self.previewPlacements = basePlacements
        self.modelPlacements = modelPlacements
        self.isTile = isTile
        self.grabOffset = grabOffset
        self.dragView = dragView
        self.placeholder = placeholder
        self.lastPoint = lastPoint
        self.originPoint = lastPoint
        self.baseSnapshot = baseSnapshot
        self.expectedSnapshot = baseSnapshot
        self.magnetSize = magnetSize
    }
}

/// A weak bridge `CADisplayLink` → coordinator.
private final class TesseraTileEditTickerProxy {

    /// The coordinator that receives frames.
    weak var coordinator: TesseraTileEditCoordinator?

    /// A ticker frame.
    ///
    /// - Parameter link: The ticker.
    @objc func tick(_ link: CADisplayLink) {
        coordinator?.displayLinkDidFire(link)
    }
}

// MARK: - Edit buttons

/// The clipping container of the edit buttons.
///
/// It matches the grid's `bounds` and clips the buttons (`clipsToBounds`) at the same
/// boundary at which the collection clips the tiles themselves: the button of a tile that has gone
/// under an edge (for example, under the status bar) is not drawn over neighboring UI.
/// The container itself does not intercept touches.
final class TesseraTileEditControlsHostView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Lets touches pass through the container if they did not hit a button.
    ///
    /// If the touch areas of several overlays overlap, the button
    /// **whose center is closer to the point** wins; on a tie, the topmost in subview
    /// order. Overlaps occur between neighbors: the size arrow of the upper tile and the
    /// unpin button of the tile below it stand in one column at the end of the row
    /// (D29), and the buttons of folder panel tiles (D46) stand close together. Within a single
    /// overlay the zones of its two buttons do not intersect
    /// (``TesseraTileEditControlView/gridHitZone(buttonFrame:tileBounds:isRightToLeft:ownsUpperHalf:)``).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled,
              self.point(inside: point, with: event) else {
            return nil
        }

        var claims: [(control: TesseraTileEditControlView, view: UIView)] = []
        for subview in subviews.reversed() {
            guard let control = subview as? TesseraTileEditControlView else { continue }
            let local = control.convert(point, from: self)
            if let hit = control.hitTest(local, with: event) {
                claims.append((control, hit))
            }
        }
        guard claims.count > 1 else {
            return claims.first?.view
        }

        // The distance is from the point to the center of the claimed button (in its overlay's coordinates).
        func distance(_ claim: (control: TesseraTileEditControlView, view: UIView)) -> CGFloat {
            let local = claim.control.convert(point, from: self)
            return hypot(local.x - claim.view.frame.midX, local.y - claim.view.frame.midY)
        }
        var best = claims[0]
        var bestDistance = distance(best)
        for claim in claims.dropFirst() {
            let candidate = distance(claim)
            if candidate < bestDistance {
                best = claim
                bestDistance = candidate
            }
        }
        return best.view
    }
}

/// The overlay of the "unpin" and "size" buttons over a tile.
///
/// It occupies the tile's frame so that the buttons and the jiggle rotate around its center, but
/// intercepts touches only in the buttons themselves: a tap on the rest of the area
/// passes through to the collection (and on to the host).
///
/// In the spirit of Windows 10 Mobile: the buttons are compact, the diameter scales
/// with the tile size (``diameter(forTileSize:maxDiameter:)``), and they sit on the
/// corners, protruding slightly past the frame (``cornerOverhang``), to cover as
/// little content as possible. The overhang is limited to 4 pt (D48): the default gap between grid
/// tiles is 8 pt, so a button does not reach the neighboring tile, and for
/// edge tiles it stays within the margins (≥ 16 pt). An overhang of half the gap is needed
/// between the buttons too: the size arrow of the upper tile and the unpin of the lower one stand in one
/// column, and their circles (4 + 4 pt) exactly touch in an 8 pt gap and do not overlap.
/// A light fill with a dark symbol, a thin
/// ring and a shadow read on tiles of any color in light and dark themes.
/// A visible button may be small, while the touch area expands to
/// ``minimumHitSide`` (`hitTest`).
///
/// D29: both buttons of a grid tile stand at the end of the row — unpin in the
/// upper corner, the size arrow in the lower one — and on a small tile their touch areas
/// are split by halves of the height
/// (``gridHitZone(buttonFrame:tileBounds:isRightToLeft:ownsUpperHalf:)``).
final class TesseraTileEditControlView: UIView {

    /// A tap on the unpin button.
    var onUnpin: (() -> Void)?

    /// A tap on the size arrow.
    var onResize: (() -> Void)?

    /// The smallest side of a button's touch area (HIG), in pt.
    static let minimumHitSide: CGFloat = 44

    /// The smallest diameter of a visible button, in pt.
    static let minimumDiameter: CGFloat = 20

    /// The fraction of the tile's smaller side the diameter is computed from.
    static let diameterFraction: CGFloat = 0.24

    /// The button's overhang past the tile frame along each axis, in pt (D48).
    ///
    /// 4 pt = half the default grid gap (8 pt): the button circles of neighboring
    /// tiles in one column (the upper one's arrow and the lower one's unpin) touch but
    /// do not overlap. The button frames, touch zones,
    /// badge clearance (``badgeClearance(forTileSize:maxDiameter:)``) and the folder panel
    /// tile's button zone (``panelHitOutset``) all depend on this value — there are no separate constants.
    static let cornerOverhang: CGFloat = 4

    /// The visible button diameter for a tile of a given size.
    ///
    /// - Parameters:
    ///   - tileSize: The tile size.
    ///   - maxDiameter: The ceiling from ``TesseraTileEditConfiguration/controlDiameter``.
    /// - Returns: A diameter from 20 pt up to the ceiling (a ceiling below 20 pt is raised to 20).
    static func diameter(forTileSize tileSize: CGSize, maxDiameter: CGFloat) -> CGFloat {
        let ceiling = max(minimumDiameter, maxDiameter)
        let scaled = (min(tileSize.width, tileSize.height) * diameterFraction).rounded()
        return min(ceiling, max(minimumDiameter, scaled))
    }

    /// The frame of the unpin button in a tile's top corner (D29, D46).
    ///
    /// **The only place where the unpin button's corner is chosen.** The grid and the
    /// folder panel build the button with this helper, so their corner is shared.
    /// The button is in the top corner **at the end of the row** (right in LTR, left in RTL, as
    /// in W10M), its center right at the frame's corner, slightly outward (``cornerOverhang``).
    /// The size arrow sits in the bottom corner of the same side
    /// (``resizeButtonFrame(inTileBounds:side:isRightToLeft:)``): the two buttons
    /// of one tile overlay stand one above the other.
    ///
    /// - Parameters:
    ///   - bounds: The tile bounds (the overlay's origin).
    ///   - side: The button diameter.
    ///   - isRightToLeft: The reading direction.
    /// - Returns: The button frame in overlay coordinates.
    static func unpinButtonFrame(
        inTileBounds bounds: CGRect,
        side: CGFloat,
        isRightToLeft: Bool
    ) -> CGRect {
        let overhang = cornerOverhang
        let x = isRightToLeft ? -overhang : bounds.width - side + overhang
        return CGRect(x: x, y: -overhang, width: side, height: side)
    }

    /// The frame of the size arrow in the tile's bottom corner at the end of the row (D29).
    ///
    /// The bottom right corner in LTR, the bottom left in RTL; the center right at the frame's corner,
    /// slightly outward (``cornerOverhang``). The same helper is used by the tile badge
    /// layout to clear the button (``badgeClearance(forTileSize:maxDiameter:)``).
    ///
    /// - Parameters:
    ///   - bounds: The tile bounds (the overlay's origin).
    ///   - side: The button diameter.
    ///   - isRightToLeft: The reading direction.
    /// - Returns: The button frame in overlay coordinates.
    static func resizeButtonFrame(
        inTileBounds bounds: CGRect,
        side: CGFloat,
        isRightToLeft: Bool
    ) -> CGRect {
        let overhang = cornerOverhang
        let x = isRightToLeft ? -overhang : bounds.width - side + overhang
        return CGRect(x: x, y: bounds.height - side + overhang, width: side, height: side)
    }

    /// How much of the tile's bottom corner on the end-of-row side the size arrow
    /// occupies **inside** the tile, in pt.
    ///
    /// This is the inset by which the badge moves away from the edge in edit mode: an arrow of diameter
    /// `side` reaches `side − cornerOverhang` into the tile along each axis.
    ///
    /// - Parameters:
    ///   - tileSize: The tile size.
    ///   - maxDiameter: The ceiling from ``TesseraTileEditConfiguration/controlDiameter``.
    /// - Returns: The width of the occupied corner inside the tile.
    static func badgeClearance(forTileSize tileSize: CGSize, maxDiameter: CGFloat) -> CGFloat {
        max(0, diameter(forTileSize: tileSize, maxDiameter: maxDiameter) - cornerOverhang)
    }

    /// The touch zone of a **grid** tile's button.
    ///
    /// Both tile buttons stand at the end of the row, one above the other, and on a small tile
    /// (≈ 50–55 pt) their 44 × 44 pt zones would intersect. The rule is deterministic and
    /// does not give the buttons the tile's center:
    /// 1. the zone is the button's visible frame expanded to ``minimumHitSide`` around
    ///    its center;
    /// 2. **vertical**: the unpin button owns the **upper half** of the tile's
    ///    height (its zone does not go below the middle), the size arrow owns the **lower** one
    ///    (does not go above the middle): the two buttons' zones never intersect;
    /// 3. **horizontal**: the zone does not go past the tile's vertical axis (minus 1 pt)
    ///    on the end-of-row side, so the center and body of the tile (tap, long press,
    ///    drag) belong to the tile. For tiles wider than ≈ 52 pt rule 3 clips nothing.
    ///
    /// - Parameters:
    ///   - buttonFrame: The visible button frame in overlay coordinates.
    ///   - tileBounds: The tile bounds (the overlay's origin).
    ///   - isRightToLeft: The reading direction.
    ///   - ownsUpperHalf: `true` for the unpin button (the upper half),
    ///     `false` for the size arrow (the lower half).
    /// - Returns: The touch zone (zero if it is degenerate).
    static func gridHitZone(
        buttonFrame: CGRect,
        tileBounds: CGRect,
        isRightToLeft: Bool,
        ownsUpperHalf: Bool
    ) -> CGRect {
        let dx = max(0, (minimumHitSide - buttonFrame.width) / 2)
        let dy = max(0, (minimumHitSide - buttonFrame.height) / 2)
        var zone = buttonFrame.insetBy(dx: -dx, dy: -dy)

        let midX = tileBounds.midX
        let midY = tileBounds.midY
        var minX = zone.minX
        var maxX = zone.maxX
        var minY = zone.minY
        var maxY = zone.maxY
        if isRightToLeft {
            maxX = min(maxX, midX - 1)
        } else {
            minX = max(minX, midX + 1)
        }
        if ownsUpperHalf {
            maxY = min(maxY, midY)
        } else {
            minY = max(minY, midY)
        }
        zone = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return zone.width <= 0 || zone.height <= 0 ? .zero : zone
    }

    /// The touch zone of the unpin button of a folder panel tile (D46).
    ///
    /// The rule is deterministic and takes nothing away from the tile and its neighbors:
    /// 1. the allowed area is the **corner quarter** of the tile where the button sits
    ///    (the upper one at the end of the row: right in LTR, left in RTL), plus an overhang
    ///    outward of no more than `outset` (the button does not reach the neighbor); beyond the tile's
    ///    axes of symmetry (minus 1 pt) there is no zone, so the center and the rest of the body
    ///    of the tile belong to the tile itself (a tap — nothing new, a long press —
    ///    a drag out of the folder);
    /// 2. within this area the zone is a square of at least 44 × 44 pt (HIG), pressed
    ///    against the outer corner and growing into the tile, but no further than the axes: for a small
    ///    tile (≈ 55 pt) it is ≈ 32 pt, for a large one the full 44 pt. The visible
    ///    button is always inside the zone.
    ///
    /// - Parameters:
    ///   - buttonFrame: The visible button frame in overlay coordinates.
    ///   - tileBounds: The tile bounds (the overlay's origin).
    ///   - isRightToLeft: The reading direction: in RTL the quarter is the left one.
    ///   - outset: The allowed extent of the zone beyond the tile frame.
    /// - Returns: The touch zone (zero if it is degenerate).
    static func panelUnpinHitZone(
        buttonFrame: CGRect,
        tileBounds: CGRect,
        isRightToLeft: Bool,
        outset: CGFloat
    ) -> CGRect {
        let clip = max(0, outset)
        let quadrantWidth = max(0, tileBounds.width / 2 - 1) + clip
        let quadrantHeight = max(0, tileBounds.height / 2 - 1) + clip
        let quadrant = CGRect(
            x: isRightToLeft ? tileBounds.minX - clip : tileBounds.midX + 1,
            y: tileBounds.minY - clip,
            width: quadrantWidth,
            height: quadrantHeight
        )

        let width = min(quadrant.width, max(minimumHitSide, buttonFrame.width))
        let height = min(quadrant.height, max(minimumHitSide, buttonFrame.height))
        let zone = CGRect(
            x: isRightToLeft ? quadrant.minX : quadrant.maxX - width,
            y: quadrant.minY,
            width: width,
            height: height
        )
        return zone.isNull || zone.width <= 0 || zone.height <= 0 ? .zero : zone
    }

    /// The SF Symbol of the "unpin" button.
    ///
    /// A crossed-out pin was chosen rather than a cross: the action is not deletion but
    /// unpinning from the desktop (the tile stays in the app list).
    /// `pin.slash` is the canonical "unpin" symbol; a plain `pin` denotes the
    /// "pinned" state and would read as the opposite action. The symbol
    /// is available since iOS 13, so it is within the iOS 15 target.
    private static let unpinSymbolName = "pin.slash"

    /// The button fill: light in both themes (contrast with dark and colored
    /// tiles), slightly muted in the dark one so it does not "glow".
    private static let fillColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.92, alpha: 1)
            : UIColor(white: 1, alpha: 1)
    }

    /// The button symbol: dark on a light fill.
    private static let glyphColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.08, alpha: 1)
            : UIColor(white: 0.12, alpha: 1)
    }

    /// A thin ring: separates the light fill from light tiles.
    static let ringColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0, alpha: 0.6)
            : UIColor(white: 0, alpha: 0.35)
    }

    private let unpinButton = UIButton(type: .system)
    private let resizeButton = UIButton(type: .system)

    /// The diameter ceiling from the configuration.
    let diameter: CGFloat

    /// The tile size: the actual button diameter depends on it.
    ///
    /// Updated by the coordinator together with `frame`; a change of the tile size
    /// (resize) rebuilds the buttons on the next layout.
    var tileSize: CGSize = .zero {
        didSet {
            guard tileSize != oldValue else { return }
            setNeedsLayout()
        }
    }

    private var showsUnpin = true
    private var showsResize = true

    /// An overlay of a tile in an expanded folder's panel, not of a grid tile (D46).
    ///
    /// Such an overlay has only the unpin button, and its touch zone is reduced
    /// (``panelUnpinHitZone(buttonFrame:tileBounds:isRightToLeft:outset:)``),
    /// so as not to take taps away from the tile itself and its neighbors. The button's layout and
    /// size are the same as on the grid (``unpinButtonFrame(inTileBounds:side:isRightToLeft:)``).
    var isPanelMember = false

    /// How far the panel tile button's touch zone may extend beyond the tile frame
    /// (D46): no more than the button's overhang and no more than the gap between tiles.
    var panelHitOutset: CGFloat = TesseraTileEditControlView.cornerOverhang

    /// Creates the overlay.
    ///
    /// - Parameter diameter: The largest button diameter in points.
    init(diameter: CGFloat) {
        self.diameter = max(TesseraTileEditControlView.minimumDiameter, diameter)
        super.init(frame: .zero)

        isAccessibilityElement = false
        backgroundColor = .clear

        setUpButton(
            unpinButton,
            symbolName: TesseraTileEditControlView.unpinSymbolName,
            action: #selector(unpinTapped)
        )
        setUpButton(
            resizeButton,
            symbolName: "arrow.up.left.and.arrow.down.right",
            action: #selector(resizeTapped)
        )
        addSubview(unpinButton)
        addSubview(resizeButton)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Shows/hides the buttons according to the element's capabilities.
    ///
    /// - Parameters:
    ///   - canUnpin: Whether to show the unpin button (a folder has none).
    ///   - canResize: Whether to show the size arrow.
    func configure(canUnpin: Bool, canResize: Bool) {
        guard canUnpin != showsUnpin || canResize != showsResize else { return }
        showsUnpin = canUnpin
        showsResize = canResize
        unpinButton.isHidden = !canUnpin
        resizeButton.isHidden = !canResize
        setNeedsLayout()
    }

    /// The visible frame of the unpin button in overlay coordinates.
    var unpinButtonFrame: CGRect { unpinButton.frame }

    /// The visible frame of the size button in overlay coordinates.
    var resizeButtonFrame: CGRect { resizeButton.frame }

    /// The touch zone of the unpin button (at least 44 × 44 pt).
    var unpinHitFrame: CGRect { hitFrame(for: unpinButton) }

    /// The touch zone of the size button (at least 44 × 44 pt).
    var resizeHitFrame: CGRect { hitFrame(for: resizeButton) }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard bounds.width > 0, bounds.height > 0 else { return }

        let side = TesseraTileEditControlView.diameter(
            forTileSize: bounds.size,
            maxDiameter: diameter
        )
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft

        // Both buttons are at the end of the row (the right edge in LTR, the left in RTL, as in
        // W10M): unpin on top, the size arrow below (D29). The button's
        // center lies right at the frame's corner, slightly outward: half the diameter
        // stays over the tile. The corners are chosen by the shared helpers — unpin
        // is used by the folder panel as well.
        unpinButton.frame = TesseraTileEditControlView.unpinButtonFrame(
            inTileBounds: bounds,
            side: side,
            isRightToLeft: isRightToLeft
        )
        resizeButton.frame = TesseraTileEditControlView.resizeButtonFrame(
            inTileBounds: bounds,
            side: side,
            isRightToLeft: isRightToLeft
        )
        for button in [unpinButton, resizeButton] {
            button.layer.cornerRadius = side / 2
            button.layer.shadowPath = UIBezierPath(
                ovalIn: button.bounds
            ).cgPath
        }
        updateColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    /// The button's touch zone.
    ///
    /// A grid tile: the visible frame expanded to 44 pt around the center and
    /// split between the buttons by halves of the tile
    /// (``gridHitZone(buttonFrame:tileBounds:isRightToLeft:ownsUpperHalf:)``).
    /// For the unpin button of a folder panel tile (D46) the zone is reduced to the corner
    /// quarter of the tile (``panelUnpinHitZone(buttonFrame:tileBounds:isRightToLeft:outset:)``).
    private func hitFrame(for button: UIButton) -> CGRect {
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        if isPanelMember, button === unpinButton {
            return TesseraTileEditControlView.panelUnpinHitZone(
                buttonFrame: button.frame,
                tileBounds: bounds,
                isRightToLeft: isRightToLeft,
                outset: panelHitOutset
            )
        }
        return TesseraTileEditControlView.gridHitZone(
            buttonFrame: button.frame,
            tileBounds: bounds,
            isRightToLeft: isRightToLeft,
            ownsUpperHalf: button === unpinButton
        )
    }

    /// The button whose touch zone contains the point (overlay coordinates).
    private func button(at point: CGPoint) -> UIButton? {
        for button in [resizeButton, unpinButton]
        where !button.isHidden && hitFrame(for: button).contains(point) {
            return button
        }
        return nil
    }

    /// Buttons may protrude past the tile frame, and a touch zone is wider than the visible
    /// button, so a hit is computed by touch zones, not by `bounds`.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        button(at: point) != nil
    }

    /// Lets touches pass through the overlay if they did not hit a button zone.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
        return button(at: point)
    }

    /// Applies dynamic colors (the layer does not learn about a theme change by itself).
    private func updateColors() {
        for button in [unpinButton, resizeButton] {
            button.tintColor = TesseraTileEditControlView.glyphColor
            button.backgroundColor = TesseraTileEditControlView.fillColor
            button.layer.borderColor = TesseraTileEditControlView.ringColor
                .resolvedColor(with: traitCollection).cgColor
        }
    }

    /// Configures a round button.
    ///
    /// - Parameters:
    ///   - button: The button.
    ///   - symbolName: The SF Symbol name.
    ///   - action: The tap selector.
    private func setUpButton(_ button: UIButton, symbolName: String, action: Selector) {
        button.setImage(UIImage(systemName: symbolName), for: .normal)
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 10, weight: .bold),
            forImageIn: .normal
        )
        button.layer.cornerRadius = diameter / 2
        button.layer.borderWidth = 1
        // The shadow is not clipped: `clipsToBounds` is off, the rounding comes from the background.
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.35
        button.layer.shadowRadius = 2
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.isAccessibilityElement = false
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    /// Unpin.
    @objc private func unpinTapped() {
        onUnpin?()
    }

    /// The size arrow.
    @objc private func resizeTapped() {
        onResize?()
    }
}

// MARK: - Target highlight

/// The highlight of the target tile during a drag.
///
/// It does not intercept touches and is not announced: it is a visual hint.
/// The target stays at full brightness against the dimmed neighbors
/// (``TesseraTileEditCoordinator``), so the border and fill read
/// on a light tile without strengthening the color.
final class TesseraTileDropHighlightView: UIView {

    /// The target type.
    enum Style {

        /// A folder: the tile will be added.
        case folder

        /// A tile: the hold has not completed yet, the drop is a no-op.
        case group

        /// The center of a tile: the hold has completed, the drop will create a folder.
        ///
        /// The same accent as `.group` (orange), but the border is thicker and the fill
        /// denser, and the coordinator additionally scales the view up to
        /// ``TesseraTileEditConfiguration/mergeHighlightScale``. The state
        /// reads without animation too: with Reduce Motion only the border and
        /// scale change.
        case merge

        /// The folder's center zone: the hold has completed, the drop will add the tile to the
        /// folder (D14).
        ///
        /// It keeps the folder's base accent (blue) rather than recoloring to
        /// orange: "absorbing" is a strengthening of the same target, not a different target;
        /// the border thickness and the fill density differ.
        case mergeFolder
    }

    /// The current style.
    private(set) var style: Style = .folder

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        layer.cornerRadius = 4
        layer.borderWidth = 3
        updateColors()
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Applies the style.
    ///
    /// - Parameter style: The target type.
    func apply(_ style: Style) {
        guard style != self.style else { return }
        self.style = style
        updateColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    /// Updates the adaptive colors and the border thickness.
    ///
    /// The "base style → absorb state" pair keeps the same accent
    /// (`.group → .merge` is orange, `.folder → .mergeFolder` is blue):
    /// "absorbing" must read as a strengthening of the same target, not as a different
    /// target. The border thickness and the fill density differ — indicators that are visible
    /// without animation too (Reduce Motion).
    private func updateColors() {
        let color: UIColor
        let borderWidth: CGFloat
        let fillAlpha: CGFloat

        switch style {
        case .folder:
            color = .systemBlue
            borderWidth = 3
            fillAlpha = 0.12
        case .group:
            color = .systemOrange
            borderWidth = 3
            fillAlpha = 0.12
        case .merge:
            color = .systemOrange
            borderWidth = 4
            fillAlpha = 0.24
        case .mergeFolder:
            color = .systemBlue
            borderWidth = 4
            fillAlpha = 0.24
        }

        layer.borderColor = color.cgColor
        layer.borderWidth = borderWidth
        backgroundColor = color.withAlphaComponent(fillAlpha)
    }
}

// MARK: - Folder screen

/// The minimal folder screen (D14): the contents and moving tiles between folders.
///
/// Design decision: a folder opens as a **modal sheet**, not by expanding in place.
/// Reasons: the grid stays the sole owner of the drag coordinator, and the sheet
/// provides a ready close button and VoiceOver focus. Inside:
///
/// - a tap on a tile closes the folder and hands the event to the host through
///   ``TesseraTileGridView/onTap`` (D12) — there is no direct call of
///   `TesseraTileDescriptor.action`: the event is handled once and through the same
///   route as a tap on a grid tile;
/// - a long press (and the VoiceOver "Move" custom action) opens a
///   "to another folder / to the desktop" menu; each operation goes through
///   `TesseraTileStore.moveBetweenFolders` and therefore through the host approval function (D14);
/// - after a move the screen rereads the folder from `TesseraTileStore`; if the folder
///   became empty and dissolved, the sheet closes.
///
/// There are no nested folders (`TesseraTileFolder.tiles` holds only tiles), so the list
/// of "other folders" is flat.
final class TesseraFolderViewController: UIViewController {

    /// The store is the only writer of the model (§6).
    private let store: TesseraTileStore

    /// The coordinator through which moves are performed (D14).
    private weak var coordinator: TesseraTileEditCoordinator?

    /// The identifier of the open folder.
    private let folderID: AnyHashable

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    /// Creates the folder screen.
    ///
    /// - Parameters:
    ///   - folder: A folder from the `TesseraTileStore` snapshot.
    ///   - store: The store.
    ///   - coordinator: The edit coordinator.
    init(folder: TesseraTileFolder, store: TesseraTileStore, coordinator: TesseraTileEditCoordinator) {
        self.folderID = folder.id
        self.store = store
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        view.accessibilityViewIsModal = true

        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.textColor = .label

        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel

        closeButton.setTitle(TesseraStartScreenStrings.string(.folderScreenDone), for: .normal)
        closeButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityLabel = TesseraStartScreenStrings.string(.folderScreenClose)

        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true

        stackView.axis = .vertical
        stackView.spacing = 12

        [titleLabel, subtitleLabel, closeButton, scrollView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor,
                constant: -12
            ),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -16
            ),

            scrollView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stackView.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: 4
            ),
            stackView.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: 16
            ),
            stackView.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -16
            ),
            stackView.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -24
            ),
            stackView.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                constant: -32
            ),
        ])

        rebuild()
    }

    /// Rereads the folder from the store and rebuilds the contents.
    ///
    /// If the folder no longer exists (it dissolved after the last tile was moved),
    /// the screen closes.
    private func rebuild() {
        guard let folder = currentFolder() else {
            dismiss(animated: !reduceMotion)
            return
        }

        titleLabel.text = folder.title.isEmpty ? TesseraStartScreenStrings.string(.folderScreenDefaultTitle) : folder.title
        subtitleLabel.text = TesseraFolderViewController.tilesText(folder.tiles.count)

        for arranged in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }

        let columns = 2
        var index = 0
        while index < folder.tiles.count {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 12
            row.distribution = .fillEqually

            for _ in 0..<columns {
                if index < folder.tiles.count {
                    let tile = folder.tiles[index]
                    index += 1
                    let tileView = makeTileView(for: tile)
                    row.addArrangedSubview(tileView)
                    tileView.heightAnchor.constraint(equalToConstant: 108).isActive = true
                } else {
                    let spacer = UIView()
                    spacer.isUserInteractionEnabled = false
                    row.addArrangedSubview(spacer)
                    spacer.heightAnchor.constraint(equalToConstant: 108).isActive = true
                }
            }

            stackView.addArrangedSubview(row)
        }
    }

    /// Whether the screen honors Reduce Motion (the coordinator provider's value takes precedence).
    private var reduceMotion: Bool {
        coordinator?.isReduceMotionEnabled() ?? TesseraAccessibility.isReduceMotionEnabled
    }

    /// The current version of the folder from the store.
    ///
    /// - Returns: The folder, or `nil` if it has already dissolved.
    private func currentFolder() -> TesseraTileFolder? {
        store.snapshot().folders.first { $0.id == folderID }
    }

    /// Creates a folder content tile with a tap and a move menu.
    ///
    /// - Parameter tile: The tile.
    /// - Returns: The tile view.
    private func makeTileView(for tile: TesseraTileDescriptor) -> TesseraFolderTileView {
        let tileView = TesseraFolderTileView(tile: tile)
        tileView.addTarget(self, action: #selector(tileTapped(_:)), for: .touchUpInside)

        let longPress = UILongPressGestureRecognizer(
            target: self,
            action: #selector(tileLongPressed(_:))
        )
        longPress.minimumPressDuration = 0.45
        tileView.addGestureRecognizer(longPress)

        tileView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: TesseraStartScreenStrings.string(.folderScreenMoveAction), image: nil) { [weak self, weak tileView] _ in
                guard let self, let tileView, let tile = tileView.tile else { return false }
                self.presentMoveMenu(for: tile, sourceView: tileView)
                return true
            }
        ]
        return tileView
    }

    /// A tap on a tile: close the folder, then activate the event through the shared route.
    ///
    /// The tile's action is performed by the host through
    /// ``TesseraTileGridView/onTap`` (D12), not by the folder screen. The activation is in the
    /// completion of the sheet's close, as `action` used to be: otherwise the host
    /// event arrives before the folder screen has started to leave, and the host's navigation
    /// conflicts with the dismiss animation. In edit mode there is
    /// no activation.
    ///
    /// - Parameter sender: The content tile.
    @objc private func tileTapped(_ sender: TesseraFolderTileView) {
        guard let tile = sender.tile else { return }
        dismiss(animated: !reduceMotion) { [weak self] in
            self?.performActivation(tile)
        }
    }

    /// Activates a tile after the folder screen closes.
    ///
    /// The main path is the shared `grid.onTap` through the coordinator (in edit mode
    /// the coordinator does not perform the activation). Fallback: if the coordinator/grid
    /// no longer exists (the screen outlived its owner), the tile's action is performed directly,
    /// as it used to be, so that the tap is not "lost".
    ///
    /// - Parameter tile: The folder content tile.
    func performActivation(_ tile: TesseraTileDescriptor) {
        if let coordinator {
            coordinator.activateTileFromFolder(tile)
            return
        }
        tile.action()
    }

    /// Passes a tile tap to the coordinator (the shared `onTap` route).
    ///
    /// An internal seam: the contract "the folder screen does not call `action` directly"
    /// is checked by a test without actually presenting a sheet.
    ///
    /// - Parameter tile: The folder content tile.
    /// - Returns: `true` if the coordinator passed the event to the host.
    @discardableResult
    func activateTile(_ tile: TesseraTileDescriptor) -> Bool {
        coordinator?.activateTileFromFolder(tile) ?? false
    }

    /// A long press on a tile: a menu for moving between folders (D14).
    ///
    /// - Parameter recognizer: The gesture.
    @objc private func tileLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              let tileView = recognizer.view as? TesseraFolderTileView,
              let tile = tileView.tile else {
            return
        }
        presentMoveMenu(for: tile, sourceView: tileView)
    }

    /// Shows the "where to move the tile" menu.
    ///
    /// - Parameters:
    ///   - tile: The tile.
    ///   - sourceView: The source view for the popover on iPad.
    private func presentMoveMenu(for tile: TesseraTileDescriptor, sourceView: UIView) {
        let alert = UIAlertController(
            title: String(
                format: TesseraStartScreenStrings.string(.folderScreenMoveMenuTitleFormat),
                tile.title
            ),
            message: nil,
            preferredStyle: .actionSheet
        )

        let otherFolders = store.snapshot().folders.filter { $0.id != folderID }
        for folder in otherFolders {
            let name = folder.title.isEmpty ? TesseraStartScreenStrings.string(.folderScreenDefaultTitle) : folder.title
            let title = String(
                format: TesseraStartScreenStrings.string(.folderScreenMoveMenuIntoFormat),
                name
            )
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.move(tileID: tile.id, to: folder.id)
            })
        }

        alert.addAction(UIAlertAction(title: TesseraStartScreenStrings.string(.folderScreenMoveMenuToStart), style: .default) { [weak self] _ in
            self?.move(tileID: tile.id, to: nil)
        })
        alert.addAction(UIAlertAction(title: TesseraStartScreenStrings.string(.commonCancel), style: .cancel, handler: nil))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }
        present(alert, animated: !reduceMotion)
    }

    /// Performs the move through the coordinator (and the D14 approval function).
    ///
    /// - Parameters:
    ///   - tileID: The tile.
    ///   - folderID: The target folder; `nil` means the desktop.
    private func move(tileID: AnyHashable, to folderID: AnyHashable?) {
        guard let coordinator else { return }

        guard coordinator.moveBetweenFolders(tileID, to: folderID) else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        rebuild()
    }

    /// Closes the screen.
    @objc private func closeTapped() {
        dismiss(animated: !reduceMotion)
    }

    /// Pluralizes the tile count for the subtitle.
    ///
    /// The plural rules and the forms themselves are in ``TesseraStartScreenStrings``: the
    /// Russian language has three forms, English has two.
    ///
    /// - Parameter count: The tile count.
    /// - Returns: A string like "3 shortcuts" (the form depends on the language).
    private static func tilesText(_ count: Int) -> String {
        TesseraStartScreenStrings.folderTilesCountText(count)
    }
}

// MARK: - Tile inside a folder

/// A folder content tile: an icon, a label, a badge.
///
/// A `UIControl` to catch the tap; the long press and the VoiceOver "Move"
/// action are attached by the folder screen.
final class TesseraFolderTileView: UIControl {

    /// The tile this view shows.
    private(set) var tile: TesseraTileDescriptor?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let badgeView = TesseraLiveTileBadgeView()

    /// Creates the tile.
    ///
    /// - Parameter tile: The tile.
    init(tile: TesseraTileDescriptor) {
        self.tile = tile
        super.init(frame: .zero)
        setUp()
        update(with: tile)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Updates the content.
    ///
    /// - Parameter tile: The tile.
    func update(with tile: TesseraTileDescriptor) {
        self.tile = tile

        if let icon = tile.icon {
            iconView.image = icon
            iconView.tintColor = nil
        } else {
            iconView.image = UIImage(systemName: "square.grid.2x2.fill")
            iconView.tintColor = .secondaryLabel
        }

        titleLabel.text = tile.title
        badgeView.badge = tile.badge

        accessibilityLabel = tile.title
        accessibilityValue = tile.badge.accessibilityValueText
        setNeedsLayout()
    }

    /// Shared view setup.
    private func setUp() {
        isAccessibilityElement = true
        accessibilityTraits = .button
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 10
        clipsToBounds = true

        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false

        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        titleLabel.textAlignment = .center
        titleLabel.textColor = .label
        titleLabel.isAccessibilityElement = false

        badgeView.isAccessibilityElement = false

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(badgeView)
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.7 : 1
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let bounds = contentBounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let inset: CGFloat = 10
        let iconSide = min(38, bounds.width * 0.45)
        let titleHeight = min(36, max(16, bounds.height * 0.32))

        iconView.frame = CGRect(
            x: (bounds.width - iconSide) / 2,
            y: inset,
            width: iconSide,
            height: iconSide
        )
        titleLabel.frame = CGRect(
            x: inset,
            y: bounds.height - inset - titleHeight,
            width: bounds.width - inset * 2,
            height: titleHeight
        )

        let badgeSize = badgeView.intrinsicContentSize
        let showsBadge = badgeSize.width > 0 && badgeSize.height > 0
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        badgeView.frame = showsBadge
            ? CGRect(
                x: isRightToLeft ? inset : bounds.width - inset - badgeSize.width,
                y: inset,
                width: badgeSize.width,
                height: badgeSize.height
            )
            : .zero
    }

    /// Bounds without the possible offset from the highlight.
    private var contentBounds: CGRect {
        CGRect(origin: .zero, size: bounds.size)
    }
}

#endif
