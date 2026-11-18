# Start Screen (Windows Phone style) for iOS: design

> Design document for `TesseraStartScreen`, a start screen component inspired by Windows 10 Mobile (W10M).
> Constraints: **iOS 15+**, **Swift 5.9+**, UIKit core with SwiftUI facades.
> Related documents: [PANORAMA-IOS-DESIGN.md](PANORAMA-IOS-DESIGN.md), [PIVOT-IOS-DESIGN.md](PIVOT-IOS-DESIGN.md). The shared mechanics (pager, parallax, gesture arbitration) live in the common layer described in [CORE-IOS-DESIGN.md](CORE-IOS-DESIGN.md) (package **TesseraKit**, target `TesseraCore`).
> Platform reference: [W10M-STARTSCREEN.md](W10M-STARTSCREEN.md). Conformance review: [W10M-CONFORMANCE.md](W10M-CONFORMANCE.md). Decision log: [DECISIONS.md](DECISIONS.md) (D-numbers below).

## 0. What the component is

A Windows 10 Mobile style start screen:

- a vertically scrolling grid of tiles over a wallpaper with parallax;
- live tiles: flips (two-sided), badges, live content;
- four tile sizes: small 1×1, medium 2×2, wide 4×2, large 4×4;
- **swipe right-to-left: the apps list (settings live there too)**;
- **swipe left-to-right: a hook page for anything the host wants** (W10M has no such page; this is an extension);
- edit mode: unpin, resize, drag, optional "jiggle".

## 1. Key architectural idea: three pages

The horizontal world of the start screen is a **pager of three full-screen pages**:

```
[ Left page (hook) ]  [ START ]  [ All apps + Settings ]
```

START is the center page. Swiping right-to-left leads to the apps list (as on Windows Phone), left-to-right to the hook page. Everything designed for Pivot works unchanged: `UIScrollView.isPagingEnabled = true`, full-screen pages give snapping for free, and the same invariant `t = offset.x / pageWidth` holds. **The Pivot core is reused almost verbatim**, which is a strong argument for the shared core package (see §12).

Two differences from Pivot:

1. **Gesture arbitration is three-way**: the pager wants horizontal, the tile grid wants vertical, the apps list wants vertical. The solution is the same as in Panorama (variant B): `gestureRecognizerShouldBegin` of the pager hands the gesture to the dominant axis, horizontal to the pager and vertical to the child. The rule simply applies to two children.
2. **The left screen edge belongs to the system**: inside a `UINavigationController` the left-to-right swipe competes with `interactivePopGestureRecognizer`. Policy: the start screen is a **root screen without back navigation** (as on Windows Phone), so both edges are ours; when embedded in a stack the system gesture is disabled or the component yields to it (`yieldsLeftEdgeToSystemGesture`, a host parameter).

## 2. Architecture

```
TesseraStartScreenView (SwiftUI facade)
    └─ TesseraStartScreenViewController (UIKit)
        ├─ pager (TesseraCore, 1–3 pages)
        │    ├─ quick panel page      ← left hook page (absent unless the host provides it)
        │    ├─ START page
        │    │    ├─ TesseraTileGridView   ← UICollectionView + custom layout
        │    │    └─ wallpaper + vertical parallax layer
        │    └─ apps list page        ← TesseraAppsListPageViewController or any host view controller
        └─ TesseraLiveTileEngine      ← flip timers, content providers

Host-owned:
    TesseraTileStore                  ← cells, sizes, folders, persistence (single writer)
    TesseraTileEditCoordinator        ← edit mode, drag, resize, unpin (attached to the grid)
```

Model:

- `TesseraTileDescriptor`: id, title, icon, size, badge, live content, and an `action`. A tile is **just an action** (D12): the descriptor has no `type` field, and the component does not know whether it launches an app, a file or a link.
- `TesseraTileFolder`: a folder of tiles.
- `TesseraTileGridSnapshot`: what the grid shows, produced by the store; optionally carries a `TesseraTileGridPlacementTable` with explicit cells.
- `TesseraTileLayoutEngine`: layout in grid units (placement by cell, collisions, row collapse).
- `TesseraLiveTileContentProvider`: source of live content (front/back faces, updates).
- `TesseraStartScreenDelegate`: page and tap events (§14 notes the exact contract).

Both side pages are **optional** (D13): the left hook (`TesseraQuickPanelProviding`) and the right page (a factory returning any view controller) exist only if the host supplies them, so the pager runs with one to three pages.

## 3. The tile grid: the hardest part

**Layout model.** The grid has `N` columns (**6 small columns by default**, so three medium tiles fit in a row, as in W10M, D26; the host may set its own `columns`, for example 4). A unit is:

```
unit = (screenWidth - margins - gaps × (N-1)) / N
```

Tile sizes in units: 1×1, 2×2, 4×2 (wide), 4×4 (large). With six columns a wide tile takes 4 of 6 (with four columns it would fill the row), a large tile is 4×4. Unit and gap are aligned to device pixels, and the grid is centered in the leftover width.

**Position is an explicit cell.** Every top-level item (tile or folder) has a `row`/`column` in logical unit coordinates (0 is the start of reading order; in RTL only the view layer mirrors) plus the canvas width `columns` they were laid out for (D30, D33; file schema in §5). Unit coordinates do not depend on pixels, so the grid adapts to any screen width.

**Placement by cells (D30–D33).** A tile **anchors to its own cell**; there is no back-filling and **holes are real**, as in W10M ([W10M-STARTSCREEN.md](W10M-STARTSCREEN.md) §3). Holes remain after unpinning, merging into a folder, shrinking a tile and dropping. A row collapses only if no tile occupies it (tall tiles included), and only on drop or after unpin, never during a drag. A newly pinned tile (for example from the apps list) goes into a **new row at the end** of the canvas, not into a hole.

**Collisions** (dropping onto an occupied cell, growing a tile, merging into a 2×2 folder in place of a small tile, dissolving a folder) are resolved by **pushing down in a cascade** (D31): overlapping tiles move down in their own columns by the needed number of rows; holes outside the affected area are untouched, and nobody moves horizontally. A cell is clamped to the canvas (the column only shifts left), and a tile too wide for the grid is shrunk to fit.

**Different canvas width (D32).** If the stored canvas width differs from the host's `columns`, the grid shows a projection: a reading-order repack without holes. The file is not rewritten; returning to the original width brings the holes back, and the first edit adopts the new width as the new canvas.

**Packing by order** (`TesseraTileLayoutEngine.pack`: greedy, left to right, top to bottom, strictly compact) survives only as a fallback: when no usable cell table exists, for migrating a version 1 file, for the D32 projection, and for the first-launch layout.

**Folder panel.** The expanded folder's panel (D17) is a full-width row under the "folder band". The band is the folder's rows extended down to the bottom of every tile that starts inside them. Tiles in the band and above stay put; tiles below keep their cells and shift down by the panel height plus the item spacing, without a repack. Empty space may remain under shorter tiles of the band.

**Implementation.** A custom `UICollectionViewLayout`:

- layout attributes are computed from the model (units to rects);
- changes (resize, reorder) go through invalidation plus `performBatchUpdates`, so `UICollectionView` animates the neighbours' shift itself;
- the Panorama performance rule stands: `scrollViewDidScroll` does **only the background parallax, never layout**.

**Why not a stock flow layout:** variable sizes, push-down on drag and the Windows Phone look of the shift are not something stock layouts provide, and a custom layout turns out simpler than bending one.

## 4. Live tiles (engine)

- **Content model:** a tile has a front (icon/title/counter/background) and an optional back. `TesseraLiveTileContentProvider` supplies content and update subscriptions (timer, push, scene phase).
- **Flip:** a container with two layers, `CATransform3D` with perspective (`m34`), a 90° rotation about Y, a side swap, and the second half of the turn. Transforms only; layout is untouched.
- **Stagger:** tiles flip in randomized batches rather than all at once. This is the library's own decision (D36), not a copy of W10M: in build 14393 all tiles update together, but a synchronous flip of the whole screen looks cheap.
- **Pauses:** a tile outside the screen has its flip frozen; so does everything while the app is in the background; the grid exposes a public `isLiveContentPaused` that the controller sets while START is not the visible page. **With Reduce Motion on there are no flips at all**; a static front is shown. Live tiles keep flipping in edit mode (D37).
- **Badge:** a small counter in the bottom corner at the end of the line (right in LTR, left in RTL; D29). It is a separate view, not part of the flip. A folder's badge is the sum of its tiles' badges (D44).
- **Memory:** images are downsampled to the icon slot and cached, otherwise a dozen live tiles would eat hundreds of megabytes.

## 5. Edit mode

Four sub-problems, in ascending difficulty:

1. **Entering edit mode.** A long press enters edit mode: the other tiles dim, unpin and resize buttons appear, and the grid is **static** (as in W10M). "Jiggle", a wobble like the iOS home screen, is a **host parameter, off by default** (D39): `TesseraTileEditConfiguration.isJiggleEnabled = true`. When on, it is a `CAKeyframeAnimation` rotating each tile ±1.2° over 0.4 s with a random phase (`jiggleAngle`, `jiggleDuration`, `seed`). With Reduce Motion nothing wobbles regardless of the parameter. The parameter can change on the fly.
2. **Unpin and resize.** The unpin button sits in the top corner at the end of the line (right in LTR, left in RTL; D29) and removes the tile with a fly-out animation. The resize arrow sits in the bottom corner on the same side and cycles the size small → wide → medium → large → small (D28, limited to the sizes the tile supports). Resize happens **in place**: growth pushes neighbours down (D31), shrinking leaves a hole (§3), unpin leaves a hole and the row collapses right after it if it became empty. The buttons are shown on all visible tiles at once (D27) and have a touch target of at least 44 pt; the buttons' circles overhang the tile corner by 4 pt, half of the 8 pt gap, so circles of neighbouring tiles touch but never overlap (D48).
3. **Dragging** is the most bug-prone part. The snapshot of the tile follows the finger, neighbours make way with animation, and on release the tile lands **on the cell under the finger**. Strategy: **a custom drag coordinator** (snapshot, placeholder, preview on cells, layout invalidation), not native `UICollectionView` interactive movement, which is built for equal cells and produces ragged animations on a variable grid. The drag target is the cell under the finger on the **base** layout captured at pickup. It is one of:
   - an empty cell (the tile lands in the hole);
   - an occupied cell (the target and any colliding tiles are pushed down in a cascade, D31);
   - a "new row" below the last occupied row;
   - a merge: the center of a tile or folder, with a hold of 600 ms, creates or fills a folder.

   The preview is recomputed from the base every time (colliding tiles go down); during a merge target, or with no target, the base is shown. The model does not change during the drag and is written once on drop (`TesseraTileStore.moveItem(_:toCell:columns:)` and friends, then collapse of empty rows). Cancel returns the snapshot taken at pickup. Dragging from the folder panel uses the same targets once the finger leaves the panel; while it stays inside, the drag reorders the folder's tiles (D40, D49).

   Tuning that makes folder creation reachable on small tiles (D50): the **merge entry zone** is a centered rectangle of `max(50 % of the side, 36 pt)` per axis; once merging, the target is **held with hysteresis** until the finger leaves the tile inset by 6 pt; and the push-down preview of the target's edge appears only after a **dwell** of 0.2 s (`TesseraTileEditConfiguration.reorderPreviewDwell`), so the target does not run away while the finger approaches its center. The drop itself ignores the dwell.
4. **Folders.** A folder is a top-level 2×2 item (always medium on creation, D20) with its own cell. It is created by merging (holding over a tile's center) and expands inline under the folder band (D17/D18; `folderTapHandler` lets the host override the tap). The host approves creating a folder, adding to it and moving between folders through the `approval` callback (D14, default allow). **A folder never has 0 or 1 tiles (D45):** when the second-to-last tile leaves, the folder dissolves, the remaining tile takes the folder's cell **with its own size** (a larger one pushes neighbours down, a smaller one leaves a hole), and an empty folder disappears; the host learns about it from `didDissolveFolder(_:remainingTile:)`. The one exception is the transient folder produced by the public `createFolder(withTile:title:columns:)` before `addToFolder`. A tile moves from one folder to another in a single gesture (D41). A folder can be renamed (D35) by long-pressing its title in the open panel.

`TesseraTileStore` persists cells, sizes, pins and folders (JSON file `tiles.json`) across launches. **Schema version 2 (D33):** every top-level item has an explicit `row`/`column` in logical coordinates, and the document carries the canvas width `columns` those cells were computed for; `sizes` and `folders` are unchanged, keys are sorted and writes are atomic. Folder contents have no coordinates. A version 1 file (no cells) migrates **lazily and once**: `load()` runs before the grid width is known, so the first host call that carries a width (`TesseraTileStore.placeItems(columns:)`, which the edit coordinator makes, or any operation taking `columns`) runs the legacy compact packing over the stored order and writes version 2 right away; visually nothing changes. The first-launch layout (seeding from the catalog) works the same way. New catalog keys appearing after cells exist go into a new row at the end; tiles outside the catalog keep their cell but do not take part in layout, and on return they take it if free, otherwise a new row at the end. If the stored canvas width differs from the host's, `placements(forColumns:)` returns the D32 projection and the file is not rewritten. On load the model is reduced to its invariants: cells inside the canvas, no overlaps among visible items (offenders go to new rows at the end); a file without a canvas width or with a partial cell set is read as unplaced (lazy migration follows). A file with a newer schema than supported is backed up and the state is not changed. A corrupt or unreadable file is renamed to `<name>.unreadable-<ISO date>.json` before any write, and the path is available as `lastUnreadableFileBackupURL`; `load()` still throws.

## 6. Right page: apps list and settings

- `UITableView` with letter sections and `sectionIndexTitles` (jump list): a native pattern, nothing to invent. Sections use `UILocalizedIndexedCollation`, so diacritics fold to the base letter and non-alphabetic titles go to "#".
- **Settings are a section/item of the list** (as on Windows Phone); a separate settings screen inside the same page is possible.
- **Two-way link with tiles:** pin from the list makes a tile appear on the grid; unpin on the grid changes the list item's state. The source of truth is `TesseraTileStore`; both pages only read and write it, the same single-writer rule as in Pivot.

## 7. Left page: the hook

- A container with the `TesseraQuickPanelProviding` protocol (or a closure); an empty placeholder by default.
- Example content: quick settings, search, profile, recent apps: whatever the app wants.
- Mechanics: the pager does not care what is on the page; the hook gets appear/disappear callbacks to load content lazily.

## 8. Wallpaper parallax

The Panorama approach, applied vertically: the wallpaper layer is taller than the grid's `contentSize`, and `scrollViewDidScroll` sets `backgroundOffset = offset.y × factor` (factor about 0.4–0.6), touching only `frame`/`transform`. With Reduce Motion it is static. On screen the layer moves up with the tiles but more slowly (projection `−offset × factor`). The layer starts one `padding` above the viewport (room for rubber-banding at the top), the whole parallax travel and the bottom margin lie below it, and the reserve is recomputed when the content height changes (folder expansion, grid updates). Horizontally (page transitions) the wallpaper moves 1:1.

## 9. Accessibility

- **A tile is a single element:** the label comes from the tile's front face (title, then detail) and the value from the badge (a count; a `.dot` reads "has a notification", D34); `UIAccessibilityCustomAction`s offer resize and unpin, and entering and leaving edit mode is announced. In a folder panel the tiles get "Remove from folder", "Move to folder…" and "Unpin", and "Move earlier"/"Move later" for reordering (D40). On a folder, "Rename" is offered. A folder's value combines its badge, tile count and "expanded".
- **Traversal order:** the order of collection indices equals the reading order of cells (row, then logical column; the same in RTL), holes included; a folder panel follows the last item of the folder band. Focus after edit operations: after unpin, the next item in reading order (the previous one if it was last); after resize, drop or take-out, the changed item; after a merge, the folder; after a folder dissolves, the remaining tile. The traversal order is derived from the code and **has not been verified on a device with VoiceOver** (see [MANUAL-TESTING.md](MANUAL-TESTING.md)).
- **Pages:** paging through `accessibilityScroll`; the page title is announced.
- **Reduce Motion:** no flips, jiggle or parallax.
- **Dynamic Type:** tile and list text scale, capped relative to tile size, then shrunk to fit the longest word, then truncated with an ellipsis rather than broken mid-word; the folder panel title scales within its fixed header height.
- **RTL:** the grid, pager and jump list mirror.

## 10. Scope: what is in and what is cut

**In:**

1. A pager of up to three pages (Pivot core).
2. A grid with four sizes, explicit cells with holes and push-down, custom layout.
3. Edit mode: unpin, resize, drag, optional jiggle, folders.
4. Live flips for simple text tiles, plus badges, stagger and pauses.
5. An apps list with letters and a settings section, two-way pin/unpin.
6. The left hook page.
7. Wallpaper and parallax.
8. A SwiftUI facade, VoiceOver and Reduce Motion, `TesseraTileStore` persistence.

**Cut:** photo slideshows in tiles, push-driven content updates, a notification queue per tile, "Show more tiles" (8 columns), automatic column count by screen size (the host sets `columns`, 6 by default, D26), peek animation, deep links from tiles, folder unpinning (D38).

## 11. Risks

- **Drag reordering on a variable grid** is the main source of bugs; tests on random tile configurations are essential.
- **The gesture stack** is the hardest in the project: horizontal pager × vertical grid × vertical list × system edge gesture. It is resolved by the dominant-axis rule plus the "root screen" policy.
- **Flips vs scrolling:** jitter if done carelessly; cured only by transforms and pauses.
- **Cultural risk:** a live start screen is the most "foreign" thing for iOS among the three components, so it should be an optional mode, not default navigation.

The project-wide register is in [RISKS.md](RISKS.md).

## 12. Project structure: the shared Core

The three components accumulated a shared layer: the invariant `t`, the pager with `pagingEnabled`, gesture arbitration (variant B), the "no layout in scrolling" rule, and the SwiftUI facade (details and contracts in [CORE-IOS-DESIGN.md](CORE-IOS-DESIGN.md)):

```
TesseraKit (SPM package)
├── TesseraCore        ← pager, parallax, gesture arbitration, facades
├── TesseraPanorama    (own snap, peek, background)
├── TesseraPivot       (header strip, indicator)
└── TesseraStartScreen (tile grid, live engine, 3 pages)
```

## 13. Summary

The start screen composes mechanics that already exist (the Pivot pager, Panorama parallax, variant B for the vertical axis) plus two genuinely new beasts: a tile grid with variable sizes and a live-tile engine. The complexity concentrates in three places: placement by cells with push-down, drag reordering with the "making way" animation, and flip discipline (transforms only, stagger, pauses). If those three hold, the rest is assembled from ready parts.

## 14. Public contract

- **Tile and folder model.** A tile has `id`, `title`, `icon`, `action: () -> Void` and an optional `badge` (red dot or attention counter, as on Windows Phone); sizes are the four above. Grouping by type is not used.
- **Optional side pages.** The pager scales from one page (START only) to three.
- **Folder approval.** Creating a folder, adding a tile to it and moving between folders are allowed by a host callback (`TesseraTileStore.approval`, default allow).
- **`TesseraStartScreenDelegate`** has four events, all with empty default implementations: `startScreen(_:didTapShortcut:)`, `startScreen(_:didTapFolder:)`, `startScreen(_:didChangePage:index:)`, `startScreen(_:didChangeHookVisibility:)`. Pin and unpin are model operations (`TesseraTileStore.pinTile`/`unpin`); edit-mode changes are reported through `TesseraTileEditCoordinatorDelegate` (`didUnpin`, `didResize`, `didMove`, folder events). A tap on a tile is an event, not a call of `TesseraTileDescriptor.action` (D12): the host runs the action.

## Implementation notes and deviations

Where the implementation departs from, refines or adds to the design above, the notes here are authoritative. They describe the current behaviour.

### Ownership and composition

1. **Editing is attached by the host.** `TesseraStartScreenViewController` and `TesseraStartScreenView` neither create the edit coordinator nor have their own entry API. The host creates a `TesseraTileStore` and a `TesseraTileEditCoordinator(grid:store:configuration:)` over the screen's grid (`gridView` of the controller). The coordinator installs the long press (0.45 s) and a background tap itself; the host calls `beginEditing()`, `endEditing()` or `toggleEditing()` when it sees fit. An app that does not need editing pays for neither the coordinator nor its overlays.
2. **The screen is a presentation layer.** The right page is any `() -> UIViewController` factory (D13); `TesseraAppsListPageViewController` is an optional ready-made class. The screen does not hold data: it receives a `TesseraTileGridSnapshot` (`reload(grid:)` in UIKit, `snapshot:` in SwiftUI). The store lives in the host as the single writer. Settings rows are host data (`TesseraAppsListSettingsItem`).
3. **Pages and callbacks.** After any rebuild of the page set the controller puts the pager on the confirmed page (Core is the source of truth); `currentPage` changes only when the pager confirms a transition, and an animated `showPage` does not change it until it finishes. Hook and right-page identifiers carry a generation counter, so a new provider or factory recreates the page. `quickPanelWillAppear` fires as soon as the hook starts to appear (by pager progress, before a programmatic transition, or when the screen appears with the hook open); `quickPanelDidDisappear` fires once the hook is fully gone or the screen is hidden, always on the same instance that received `willAppear`. The UIKit controller exposes a weak `delegate`; the SwiftUI facade uses it internally. Taps still arrive through `gridView.onTap`.
4. **Grid scrolling is gated through its pan recognizer,** not `isScrollEnabled`, during horizontal arbitration, so the arbiter never fights the folder animation or the edit coordinator for that flag. The public `isScrollEnabled` is the *requested* value; the effective value also accounts for the folder-panel animation, and a getter read during an animation does not guarantee restoration (keep your own intent).
5. **SwiftUI facade.** Redrawing does not reload the grid or the pager. The snapshot signature covers live content (by reference) and, for folders, each tile's title, badge, icon and live content; `action` is not comparable, so the delegate receives the tile or folder from the last snapshot by `id`. Side pages rebuild only when the presence or type of the hook provider changes; a new instance of the same type, or a new `rightPage` factory, is picked up for the next page creation. To recreate an already loaded side page the host recreates the view (`.id(…)`).
6. **Tile activation goes through `onTap`.** Tapping a tile in the folder panel or on the built-in folder screen reaches the host as `.tile(descriptor)` through `grid.onTap`, the same route as a grid tile; it does not call `action` directly and does nothing in edit mode (the host runs the action, D12). Tapping empty space in the panel closes the folder. `onTap` and `onFolderExpansionChanged` are synchronous: re-entering `reload`/`update`/`openFolder` from them can mix `reloadData` and a batch update in one runloop pass, so defer such reactions. The built-in folder screen activates a tile after the sheet dismisses.

### Layout and the grid

7. **Cells are the model; order is derived (D30–D33).** `TesseraTileStore` keeps an explicit cell per top-level item. `snapshot()` and `snapshot(columns:)` order items by cells (reading order: row, then logical column), and the grid itself also sorts a snapshot into reading order when it carries an applicable cell table. There is no index-based public API, so the store, layout engine, grid and coordinator work in cells and `TesseraTileStore` operations take the grid width `columns` (D33). `gridOrder` only fixes the file's write order and tie-breaking. The old compaction and canonicalization of order are gone.
8. **The cell table in the snapshot.** `TesseraTileGridSnapshot.placementTable` (`TesseraTileGridPlacementTable`: id to `TesseraTileGridPlacement` in logical, unmirrored coordinates, plus the declared canvas width) is a side table; `TesseraTileGridItem` is unchanged. The layout uses it when it is usable: declared width equals the grid's `columns`, every item has a cell, and the set passes `TesseraTileLayoutEngine.validate` (inside the canvas, non-negative, no overlaps). Otherwise the **whole table is ignored** and tiles are packed by order (`pack`); there is no partial substitution. Content height is the bottom of the lowest occupied row (empty trailing rows do not count). Hosts that build snapshots by hand get the packed fallback; `TesseraTileStore.snapshot(columns:)`, the coordinator and the SwiftUI facade attach the table.
9. **Placement engine.** `TesseraTileLayoutEngine` offers placement operations over `TesseraTilePlacedItem` sets: slots by cell, `validate`/`hasOverlaps`, clamping a cell to the canvas, `inserting` (push-down cascade), `resizing` in place, `removing` (leaves a hole), `collapsingEmptyRows`, `newRowCell`/`firstFreeCell`. The push-down cascade visits items in reading order and lowers each one overlapping an already placed rectangle in its own column to the bottom of the lowest obstacle until nothing overlaps (D31).
10. **Store operations.** Every operation works on visible top-level items and takes `columns`: `moveItem(_:toCell:columns:)`, `moveItemToNewRow(_:columns:)`, `resize(_:to:columns:)`, `pinTile(_:columns:)`, `unpin(_:columns:)`, `createFolder(withTile:title:columns:)`, `addToFolder(_:folderID:columns:)`, `extractFromFolder(_:toCell:columns:)`, `extractFromFolderToNewRow(_:columns:)`, `moveBetweenFolders(_:to:columns:)`, `moveWithinFolder(_:folderID:toIndex:)`, `renameFolder(_:to:)`, `collapseEmptyRows(columns:)`. Invalid input (unknown item, `columns <= 0`, host refusal) returns `false` with no change and no notification. Each successful operation is one notification and one write. A new canvas width is adopted only by a successful operation; a refused or no-op call leaves the file alone (D32). Moving, extracting and pinning go through `inserting`, growth through in-place resizing; a removed item (unpin, added to a folder, merged, emptied folder) leaves a hole. A new folder is always `.medium` (2×2) on the target's cell (D20): a folder made from a wide or large target replaces its slot with a medium tile. A stored folder size is not normalized on load, because folders can be resized and a stored size may be a deliberate choice.
11. **Atomic folder creation by drop.** Creating a folder by dropping a tile onto a tile involves two host approvals (D14, `.createFolder`, then `.addToFolder`). The first step is applied in memory only; if the second is refused, the target's slot is restored and the folder record removed, without any `onChange`, autosave or `objectWillChange` for the intermediate state. On success there is one notification; the coordinator sends `didCreateFolder` only after both steps succeed. On refusal the delegate receives only `didFailGrouping`.
12. **Persistence and the catalog.** Cleanup against the catalog runs in both `setCatalog` and `load()`: unknown tiles are removed from folders, a folder without catalog tiles dissolves, orphaned folders go to the end. The catalog is authoritative, so folders hold no invisible members after cleanup. A file whose folders hold 0 or 1 tiles is repaired on load as described in note 21; if the catalog is not yet registered, a one-tile folder waits for `setCatalog`, so a removed app does not become an invisible key.
13. **Pixel alignment.** `unit(screenWidth:columns:gaps:scale:)` rounds the unit down to `1/scale` and the gap to the nearest pixel; the leftover width is split into margins (left `floor(leftover/2)`, right the rest) and the grid is centered. `magnetSlotCenters` uses the same metrics, so slot centers match layout frames to the pixel.
14. **Folder panel.** The panel gap equals `itemSpacing`; inner panel padding (12 pt) and the title-to-grid gap (8 pt) are constants. Panel transitions are serialized by a small state machine (`idle`/`opening`/`closing`) with one deferred target and one deferred snapshot (last wins). Switching from folder A to B collapses A with an instant reload and opens B on the next runloop pass, so one pass contains either `reloadData` or `performBatchUpdates`, never both. A repeat tap in the first ~0.12 s of closing means "open again". The panel title scales with Dynamic Type within its 44 pt header.
15. **Snapshots are applied as a diff.** A change of composition is applied with `performBatchUpdates` keyed by id plus a panel flag, then visible cells are reconfigured, so unchanged tiles keep their live-tile registration and the idle flip phase of folder previews; frequent badge updates no longer prevent flips. If the order of common elements also changed, the snapshot goes through `reloadData` (mixing moves with inserts and deletes in one batch is unreliable). The cross-fade for composition changes lasts 0.2 s and is off with Reduce Motion; the non-animated path runs inside `performWithoutAnimation`. `isLiveContentPaused` is honoured by `configure`, so updates applied while START is off screen do not restart flips.
16. **Dim ownership.** The grid owns tile alpha: `setEditDimming(_:animated:)` stores target values and reapplies them after every `configure`; a cell's effective alpha is `isSourceHidden ? 0 : dimmingAlpha`, so the hidden state of a dragged tile beats dim.
17. **Names and tap slop.** A new folder gets the localized default title ("Folder"; `TesseraTileEditConfiguration.folderTitle` overrides it), and a folder with an empty title is labelled the same way on the tile, in the panel and in accessibility; the store itself permits empty titles. The panel title keeps the case typed by the user. A passive recognizer on the collection rejects a `didSelectItemAt` whose touch moved more than 10 pt, so a swipe on the grid is not a tap.
18. **Default grid width is 6 (D26).** `TesseraTileLayoutEngine.defaultColumns` is the single default used by the grid, layout, the store when no grid width is known, and the folder panel grid. At 6 columns on a 402 pt screen (margins 16, gap 8) a unit is about 55 pt: tile content adapts (icon at least 14 pt, inset at least 6 pt, scaling title) and edit buttons stay at least 20 pt with a 44 pt touch target.
19. **Public API prefix (D51).** Every public top-level type has the `Tessera` prefix; nested types do not need it.

### Drag and edit mode

20. **Targets and preview.** Targets (`HoverTarget`) are `.cell`, `.newRow`, `.group(id)`, `.folder(id)`, `.sourceFolder` and `.none`. Hit testing uses the **base** layout captured at pickup, so tiles pushed away by the preview never move the target. Over an occupied cell the center merges (`.group` for a tile not taken from a folder, `.folder` for another folder, `.sourceFolder` for the folder it came from; folders cannot be dropped into folders), and anything else, gaps included, targets the occupied cell (`.cell`: the dragged item takes that cell and the occupant is pushed down). An empty cell targets itself; below the last occupied row is `.newRow`; the item's own base cell and anything outside the grid give `.none`. Until the finger has moved 12 pt from the pickup point, empty cells do not become targets (lifting from a panel must not make the slot run away). The preview is always computed from the base; for `.group`/`.folder`/`.sourceFolder`/`.none` it is the base itself. Dropping with a merge target but no completed hold is a no-op and returns the tile to its place (the center of a tile means "merge or nothing"); the folder panel itself is not a drop target.
21. **Dissolving a folder (D45).** When an operation removes a tile and leaves one, the folder dissolves: the remaining tile becomes a top-level item on the folder's cell with its own size via `inserting` (a larger one pushes neighbours down, at the right edge the column shifts left, a smaller one leaves a hole); an empty folder disappears. The rule applies to `extractFromFolder`/`extractFromFolderToNewRow` (the remaining tile is placed **before** the extracted one, so extracting onto the folder's own cell pushes it down), `unpin` of a folder tile, `moveBetweenFolders`, catalog cleanup and file load. `didDissolveFolder(_:remainingTile:)` fires once after a successful coordinator operation and its main callback. While dragging a tile out of a two-tile folder, the preview shows the dissolved result for cell and new-row targets so that the drop lands exactly where the preview showed; while the target is a merge with another folder, the source folder or nothing, the base is shown, and the dissolution is applied only on drop. If an unpin empties the open panel's folder, the panel closes first (animated, instantly with Reduce Motion) and the snapshot without the folder is applied after the transition; VoiceOver focus goes to the remaining tile.
22. **Hold-to-merge (D22).** A merge needs the finger to stay within 10 pt for longer than 600 ms **counted from the last noticeable movement**: a displacement of 10 pt or more cancels the earlier hold (even a completed one, and the "absorb" highlight rolls back) and immediately starts a new one at the current point. Constant movement therefore never produces readiness. The 10 pt and 600 ms bounds are strict, a change of target restarts the hold, and haptics and announcements happen only when the hold is actually completed.
23. **Easier folder creation (D50).** The merge entry zone is `max(50 % of the side, 36 pt)` per axis (clamped to the side), for tiles, folders and the source folder alike; once a merge target is acquired it is held while the finger stays inside the rect inset by 6 pt (hysteresis; never smaller than the entry zone); the push-down preview of an occupied cell appears only after a dwell of 0.2 s on that cell (`reorderPreviewDwell`; zero or negative disables it; Reduce Motion does not shorten it). Empty cells and "new row" displace nobody and are shown immediately. The magnet (below) is off over merge targets and inside the hold area. The 36 pt, 6 pt and 0.2 s values are estimates not yet verified on a device.
24. **Magnet.** The snap-to-slot magnet measures from the **center of the snapshot** (finger plus grab offset), so the snapshot never shifts more than the attraction radius; it targets the frame of the target cell for the dragged size and is off over merge targets and with Reduce Motion. The grab scale is 0.95 (D42).
25. **Edit buttons.** The unpin and resize buttons live in a clipping container (`clipsToBounds`, frame equal to the grid's bounds, z-position 200, never intercepts touches by itself), so a tile partly under the top or bottom edge does not draw a button over the status bar. The diameter is about 24 % of the tile's shorter side, at least 20 pt, at most `controlDiameter`; the circle overhangs the corner by `cornerOverhang` = 4 pt (D48). The look is a light fill with a dark glyph, a 1 pt ring and a shadow, adapting to both themes. Touch zones are at least 44 pt; on a small tile the two buttons share the tile's height (unpin owns the upper half, resize the lower half) and neither crosses the vertical axis of the tile, so the center and body of the tile belong to tap, long press and drag. When zones of different overlays intersect (the resize button of one tile and the unpin button of the tile below), the **nearest center** wins. The corner is chosen in one place, `TesseraTileEditControlView.unpinButtonFrame(inTileBounds:side:isRightToLeft:)`, shared by grid tiles and folder-panel tiles. Buttons are not accessibility elements; their actions are custom actions.
26. **Background tap ignores button zones.** The tap-on-background recognizer (which leaves edit mode) rejects a touch that falls in the zone of any edit button (grid or panel, overhang and extended zone included), decided by the same `hitTest` the buttons use, so an unpin tap in the gap between tiles does not also end editing.
27. **Unpin buttons in the folder panel (D46).** In edit mode each tile of the open panel shows the same overlay with only the unpin button (no resize arrow, and no unpin on the folder tile itself, D38). The touch zone is the corner quarter of the tile plus an overhang of at most the grid gap, at least 44 pt where the tile allows and not past the tile's axes (about 30 pt on a 55 pt tile); the body of a panel tile is not part of the button. Buttons appear when the panel settles (0.18 s fade, instant with Reduce Motion) and are removed at the start of closing, on dissolve, on drag from the panel and outside editing. A tap flies the snapshot out and then takes the usual unpin path; public `unpin(_:)` and the VoiceOver action stay instantaneous.
28. **Panel reorder (D40, D49).** In edit mode a long press on a tile of the open panel starts a **reorder inside the panel**: the panel stays open, the tile is hidden and replaced by a placeholder, the snapshot follows the finger, and neighbours shift with the bounce curve (instantly with Reduce Motion). The slot comes from the panel's slot frames (in gaps, the nearest row, then the nearest slot horizontally); the model is not written during the drag and a drop commits once through `TesseraTileStore.moveWithinFolder(_:folderID:toIndex:)` (no host approval; the same position is a no-op with no write or `onChange`). Moving the finger beyond the panel frame by `panelReorderExitMargin` (16 pt) **replaces the session by a take-out** to the desk (panel closes instantly, same snapshot); there is no return to reordering within the same drag. Auto-scroll at the edge works. The coordinator method is `moveWithinFolder(_:to:)` and the delegate event is `didReorderTile(_:inFolder:toIndex:)`; VoiceOver offers "Move earlier"/"Move later" (impossible ones hidden). Success haptic on drop; no tick on slot change.
29. **Take-out and folder-to-folder moves.** A long press on a panel tile outside reordering lifts it for take-out: the dragged tile is removed from the displayed folder snapshot and inserted as a separate tile after the folder, and the same cell targets apply. A tile dropped on another folder's center after a hold moves there in one gesture (D41); a take-out source never creates a folder by merging onto a plain tile (that would need a tile on the grid). The delegate receives `didMove(_:toFolder:atCell:)` (the cell on take-out to the desk, otherwise `nil`; the default implementation forwards to `didMove(_:toFolder:)`).
30. **Edit entry and tap on folders.** Tapping a folder in edit mode opens the panel and does not interrupt editing (`folderTapHandler` is consulted in both modes); `beginEditing()` closes an already open panel. A long press that starts a drag closes the panel instantly so the first frames do not run over a shifting layout; a public `beginEditing()` closes it with animation. A drag starts only if the grid snapshot matches the model at the moment of pickup; the drag cancels safely when the model or grid changes externally, returning the hidden cell and scrolling and syncing the grid with the **current** store snapshot. `deinit` and fly-out completion after the coordinator is gone restore the hidden cell, scrolling and autosave. A second quick unpin of the same tile is ignored. Changing the configuration on the fly rebuilds controls, restarts jiggle and resets hold and magnet. After a render caused by unpin or folder creation, jiggle and dim are reapplied.
31. **Cycle order and sizes (D28).** `TesseraTileSize.cycleOrder` is small → wide → medium → large; `TesseraTileSize.next(among:)` advances to the first size in the supported set, skipping unavailable ones. The host's `supportedSizesProvider` sets the set, not the order. The arrow and the VoiceOver "Resize" action both call `cycleSize(of:)`. Editing continues after a step (D27).
32. **Jiggle is a host parameter, off by default (D39).** `TesseraTileEditConfiguration.isJiggleEnabled` defaults to `false`; with it off, neither cells nor button overlays get an animation. The amplitude, period and seed live in the same configuration. Reduce Motion disables jiggle regardless. The parameter is read on every control reconciliation, so changing the configuration during editing applies immediately.
33. **Public edit grouping.** Besides the drag gestures, VoiceOver users get "Add to folder <name>" on grid tiles (up to `maxFolderActions` = 6 folders), and "Remove from folder", "Move to folder <name>", "Unpin" on folder-panel tiles. All of them go through the coordinator's public `addToFolder`/`moveBetweenFolders`, so host approval (D14), announcements and focus apply; a refusal returns `false` and calls `didFailGrouping`. "Create folder with…" is not provided (it would need a second-tile picker); `createFolder(withTile:title:columns:)` does it without dragging.

### Badges, tiles and live content

34. **Badge corner and label (D29).** The badge (capsule and `.dot`, laid out by the shared `TesseraTileBadgeLayout` for grid cells and live tiles) sits in the bottom corner at the end of the line. The label shares the bottom row and yields: if at least 60 % of the content width and 40 pt remain, it stays in the row beside the badge ("beside"); otherwise it keeps full width and rises above the badge row ("above"). In edit mode the badge slides along the bottom row away from the resize arrow, leaving a 2 pt gap on all tiles and widths (animated 0.18 s, instant with Reduce Motion), and the "99+" capsule on a 1×1 tile is hidden for the duration of editing because it cannot fit beside the arrow.
35. **Small tile with a badge (D47, as in W10M).** A 1×1 tile (by model size) with an icon and a visible badge ("0" is not a badge) shows the icon and the badge without a visible label: the icon sits centered above the badge row, with a side of at most 45 % of the shorter side, 34 pt and the space between the edit buttons, and at least 12 pt. The label stays for VoiceOver. A small tile without a badge, with "0", or without an icon keeps its label; larger tiles are unaffected. On a live tile each side decides for itself (a side with an icon and a badge drops its text; a side without an icon keeps it).
36. **Folder badge (D44).** The sum of the positive counts of the folder's tiles; if there are no counts but a `.dot`, a dot (a count beats a dot); sums above 99 show "99+"; otherwise no badge. The value is computed once when a snapshot is applied to a cell (never in scroll callbacks) and laid out with the same `TesseraTileBadgeLayout`. A 1×1 folder with a badge draws no label and centers its mini-grid above the badge row. The mini badges inside the preview stay (partly duplicating the sum); the panel header has no badge. VoiceOver reads the badge value, the tile count and "expanded".
37. **Folder preview.** Up to four mini icons with independent idle flips and badges, regardless of the folder's size (D43).
38. **Live tile accessibility.** A live tile's label is built from `liveContent.frontFace` (title, then detail, falling back to the descriptor's title); the live view itself stays a decoration of a single element.
39. **Image memory.** A live-tile face keeps a copy downsampled to the icon slot (18–28 pt × screen scale) from `TesseraLiveTileImageCache` (`NSCache`, at most 256 entries and 32 MB). The key is the identity of the `UIImage` object (held weakly), the pixel size and the rendering mode; an icon that already fits is not redrawn. Rendering happens in the face's layout pass, never on the flip or scroll path. A host provider should hand out the same `UIImage` object, otherwise every content update is a cache miss.
40. **Flip container layout.** A tile's flip container sets `bounds` plus `center` on its sides rather than `frame`, because mid-flip a side has a non-identity 3D transform where `frame` is undefined.

### Folder management

41. **Renaming (D35).** A long press (≈0.5 s) on the name in an open panel turns the title into a one-line text field in place (the header's frame and height are unchanged; the grid scrolls the field above the keyboard and restores insets after). Return, a tap away, closing the panel, and entering or leaving edit mode **commit** the name; there is no cancel. The name is normalized (trimmed, single line) and capped at `TesseraTileFolder.maximumTitleLength` = 64 characters; an empty name resets to the default title. The grid reports the result through `TesseraTileGridView.folderRenameHandler`; without a handler the title is static. The coordinator forwards it to `TesseraTileStore.renameFolder(_:to:)` and the delegate's `didRenameFolder` (the public `renameFolder(_:to:)` does the same and also works outside edit mode). VoiceOver: a "Rename" action on the folder tile and its title; the field is labelled "Folder name". A long press in the name zone starts neither edit mode nor a drag.
42. **No unpinning of folders (D38).** A folder tile has only the resize button; a folder lives while it holds tiles (D45), and its tiles are unpinned from the panel.

### Localization and accessibility details

43. **UI strings.** Default strings live in SPM resources (`Localizable.strings` for `en` and `ru`, with stable dotted keys such as `a11y.editing.entered`, `folderScreen.done`, `appsList.pinActionTitle`), resolved through `Bundle.module`; key parity between the two tables is tested and other locales fall back to English. The resource bundle is part of the package: a consumer who copies the module without it gets a `fatalError` on first string use. Plural forms of "tile" are separate keys with the selection rule in code (en: one/many; ru: one/few/many including 11–14); a new language needs its own rule or `.stringsdict`. Page titles (`startPageTitle`, `quickPanelTitle`, `applicationsPageTitle`) and `TesseraStartScreenStyle` are English defaults owned by the host, and host-supplied texts (`TesseraAppsListTexts`, `folderTitle`) override only the strings they accept. Internal VoiceOver strings and the built-in folder screen's strings cannot be overridden by the host.
44. **Apps list alphabet.** Sections use `UILocalizedIndexedCollation.current()`: diacritics fold to the base letter, ideographs go to their alphabet's section ("#" in en/ru, pinyin in zh), and digits, symbols and emoji go to "#". Order within a section is `localizedStandardCompare`. The jump list shows the locale's full alphabet while the table holds only non-empty sections (tapping an empty letter jumps to the next non-empty one). The set of sections therefore depends on the device language. A changed icon with the same id and title updates visible rows in place; after a reload the reading position is kept within the new content.
45. **Dynamic Type for tile titles.** The tile cell caps the font at `max(base, 20 % of the shorter side)`, shrinks it to 0.6 of the base if the longest word does not fit, and as a last resort truncates to one line with an ellipsis. `accessibilityLabel` stays complete. The host app's hint block and Done/Edit button are part of the Example host, not the library.
46. **VoiceOver focus after edits.** `.layoutChanged` is posted on the next runloop pass with a focus target chosen by id before the mutation (not by index, because unpin leaves a hole). A custom action refers to the same public coordinator operations as gestures, so announcements and focus are identical.

### Historical notes

47. Earlier iterations of the design used strictly compact packing, an index-based model order, canonicalization of order, `HoverTarget.slot` with a preview order, and folders that survived with a single tile. All of these were replaced by the explicit-cell model described above and are not part of the current behaviour.
