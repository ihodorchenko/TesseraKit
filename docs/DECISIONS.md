# Decision log

Design and product decisions that shaped TesseraKit. Ids (`D<n>`) are referenced from the design documents
and from code comments. Status values: **confirmed** (explicitly approved by the maintainer), **proposed**
(made during implementation, built upon, not explicitly confirmed), **superseded by D<n>**. D8 was never
assigned.

## Decisions

| Id | Decision | Rationale | Status |
|---|---|---|---|
| D1 | Work is tracked in plain files with three states: done, partial, not started. | Keeps "what is left" visible in the repository. | confirmed |
| D2 | Components are built in dependency order (Core, Pivot, Panorama, StartScreen); parallelism only inside a stage, on disjoint files. | Dependencies on Core dictate the order; simpler review and history. | confirmed |
| D3 | No CI service in v1; every change is verified locally with `swift build` and `xcodebuild test`. | Maintainer's call at the time. | confirmed (CI was added later for the public release) |
| D4 | Changes reach `main` only through a pull request from `dev`; direct pushes to `main` are not allowed. | Keeps `main` stable. | confirmed |
| D5 | An example app is out of scope. | An SPM package does not need one. | superseded by D16 |
| D6 | Each task is described and approved before work starts. | Process rule. | confirmed |
| D7 | Work is executed by delegated agents, supervised by a lead. | Process rule. | confirmed |
| D9 | The package targets iOS only (iOS 15+); Mac Catalyst is declared for compatibility only (`.macCatalyst(.v15)`). Compile checks on a Mac host use the Catalyst triple. | iOS is the only supported platform. | confirmed |
| D10 | `swift test` cannot run UIKit code on a macOS host; tests run through `xcodebuild test -scheme TesseraKit-Package -destination 'platform=iOS Simulator,name=iPhone 17'`. | Loading Catalyst test bundles on macOS is rejected as an incompatible platform. | proposed |
| D11 | Commit messages and pull requests are written in English. | Maintainer's requirement. | confirmed |
| D12 | StartScreen tiles are plain actions: `id`, `title`, `icon`, `action`, `badge`. There is no tile "type". | Keeps the model minimal; behaviour lives in the host. | confirmed |
| D13 | Both side pages of the start screen pager are optional: the hook page (left) and the apps list (right) exist only if the host supplies them; the pager has 1 to 3 pages. | Hosts may want a start screen alone. | confirmed |
| D14 | Creating a folder, adding a tile to a folder and moving a tile between folders go through a host approval function (default: allowed). | The host owns domain rules about grouping. | confirmed |
| D15 | Live tiles (flips, staggered updates, pauses, Reduce Motion) are part of the first StartScreen release; tiles have four sizes (1x1, 2x2, 4x2, 4x4). | Live tiles are the defining feature of the component. | confirmed |
| D16 | An Xcode example host lives in `Example/TesseraKitExample` and is committed. It is the only `.xcodeproj` allowed in the repository. | Components must be tried by hand on a simulator. | confirmed |
| D17 | Folders behave like Windows Phone: the panel opens below the folder tile, the tile stays, height grows from 0 to the panel, icons cascade in without re-layout, the folder tile hides its 2x2 preview while open. The panel sits under the "folder band": the folder rows plus any tile that starts in them and extends lower. | Matches the reference behaviour. | confirmed |
| D18 | A folder expands inline. A host that wants other behaviour overrides the tap with `folderTapHandler` (returning `true` skips the built-in expansion). | Inline matches the reference; the hook keeps it flexible. | confirmed |
| D19 | Review fixes were delivered in shared waves by layer (Core, tile model, grid, drag, final) with parallel tracks for the other components, not epic by epic. | The fixes touched the same files; critical defects could not wait. | confirmed |
| D20 | A new folder is always medium (2x2), regardless of the target tile size. A folder can still be resized; a stored size is not normalised on load. | Windows 10 Mobile folders are always medium. | confirmed |
| D21 | The drag target is chosen by the finger point, not the dragged snapshot's centre. Over an empty area the target is the cell under the finger. | Users expect the drop to follow the finger. | confirmed (refined by D30: cells instead of order slots) |
| D22 | The merge hold is re-armed on movement: a displacement of 10 pt or more cancels the hold (even an elapsed one) and restarts a 600 ms count at the new point. | A finger that settles after approaching must be able to merge. | confirmed |
| D23 | Layout is strictly compact; a drop position is a slot in reading order. | Simplest model. | superseded by D30 |
| D24 | The Example app has a second tab, "Start", with a complete `TesseraStartScreenViewController`, next to the grid-only tab. | The full screen must be verified by hand. | proposed |
| D25 | Conformance items against Windows 10 Mobile are decided one by one, never as a batch. | Each is a product decision. | confirmed |
| D26 | The default grid has 6 small columns (three medium tiles per row), as on Windows 10 Mobile; hosts may set their own `columns`. The "show more tiles" 8-column mode is not provided. The single source of the default is `TesseraTileLayoutEngine.defaultColumns`. | With 4 columns a 2x2 folder left dead gaps beside it. | confirmed |
| D27 | Edit buttons (unpin, size arrow) stay on all tiles at once, not only on the held one; edit mode does not end after a size step. | Simpler and predictable. | confirmed |
| D28 | The size-arrow cycle is small, wide, medium, large, back to small; the four sizes of D15 stay. | Matches Windows 10 Mobile. | confirmed |
| D29 | The badge sits at the bottom-right of the tile (bottom-left in RTL). The unpin button is top-right in LTR (top-left in RTL); the size arrow stays bottom-right. | Matches Windows 10 Mobile. | confirmed |
| D30 | The grid has real holes: every top-level item has an explicit cell (`row`, `column`). | Lets a drop choose an exact cell, as on Windows 10 Mobile. | confirmed (replaces D23) |
| D31 | Collisions (drop on an occupied cell, a growing tile, a merge into a 2x2 folder on a small tile's cell) push blocking tiles down in a cascade by the needed number of rows; holes outside the affected area stay. A row collapses only if no tile (including tall ones) occupies it, and only on drop, never during a drag. | Predictable placement without surprising reflows. | confirmed |
| D32 | When the host's `columns` differs from the width the saved cells were computed for, a reading-order repack without holes is shown; the file is not rewritten until the user edits, and returning to the old width restores the holes. | Rotation or width changes must not destroy a layout. | confirmed |
| D33 | `tiles.json` is schema version 2 with `row`/`column` and the canvas width; v1 files migrate once through the old compact packer. The older index-based StartScreen API is replaced without deprecated shims. A drop picks the cell under the finger; a "new row" target exists at the bottom. | The library had no external users yet. | confirmed |
| D34 | A `.dot` badge is announced by VoiceOver: a localized phrase goes into `accessibilityValue`; the label is unchanged. | Reference conformance. | confirmed |
| D35 | Folders can be renamed: tap or hold on the name in the open panel; an empty name restores the default; `TesseraTileStore` owns the rename. | Matches Windows 10 Mobile. | confirmed |
| D36 | Live updates keep a stagger (batches with spread). It is the library's own choice, not a claim about Windows Phone. | Avoids all tiles flipping at once. | confirmed |
| D37 | Live tiles keep flipping in edit mode. | Not specified by the reference; kept simple. | confirmed |
| D38 | A folder itself has no unpin button in edit mode; it only has the size arrow. | A folder lives while it has tiles. | confirmed |
| D39 | The edit-mode "jiggle" is off by default and opt-in through `TesseraTileEditConfiguration.isJiggleEnabled`; always off with Reduce Motion. | The Windows 10 Mobile grid is static in edit mode. | confirmed (parameter placement proposed) |
| D40 | Reordering tiles inside an open folder panel is supported, after the explicit-cell model. | Folder order is a first-class part of the model. | confirmed |
| D41 | Moving a tile from one folder to another stays one gesture (not two steps as on Windows 10 Mobile). | Fewer steps. | confirmed |
| D42 | The scale of a lifted tile stays 0.95. | Kept as designed. | confirmed |
| D43 | A folder tile shows up to 4 thumbnails regardless of its size. | Kept as designed. | confirmed |
| D44 | A folder tile badge is the sum of its tiles' numeric badges; with no numbers but at least one dot, a dot; above 99 it reads "99+". | Matches Windows 10 Mobile. | confirmed |
| D45 | A folder never holds 0 or 1 tiles. When one tile is left, the folder dissolves: the tile takes the folder's cell with its own size (a larger one pushes neighbours down per D31, a smaller one leaves a hole); an empty folder disappears. This applies to take-out, unpin, moves between folders, catalog cleanup and file load. The host learns about it from `didDissolveFolder`. The transitional state of `createFolder(withTile:title:columns:)` is the exception. | The reference does not describe the one-tile state; a dissolving folder is the clearer rule. A deliberate deviation. | confirmed |
| D46 | Tiles in an open folder panel get the same unpin button as grid tiles in edit mode; a tap unpins immediately (no confirmation). Panel tiles have no size arrow, and the folder has no button (D38). The VoiceOver "Unpin" action stays. | Same widgets inside folders as on the grid. | confirmed |
| D47 | A small 1x1 tile with a visible badge shows the icon and the badge but no caption; without a badge (or with a zero) the caption stays; larger sizes are unchanged. The caption is hidden visually only; VoiceOver still reads it. | A caption above the badge squeezed the icon out. | confirmed |
| D48 | The edit buttons' `cornerOverhang` is 4 pt (was 6): circles of vertically adjacent tiles touch without overlapping. Hit zones and badge shifts were recomputed. | Cleaner look; side effects accepted. | confirmed |
| D49 | In-panel reordering details: dragging happens while the panel is open; leaving the panel by 16 pt (`panelReorderExitMargin`) replaces the reorder with a take-out and there is no way back within the same drag; the slot is the panel slot under the finger, or the nearest one outside slots; a drop on the own slot is a no-op; the host approval of D14 is not consulted and the delegate gets `didReorderTile(_:inFolder:toIndex:)`; success haptic on drop, no tick per slot; VoiceOver offers "Move earlier/later" one step at a time. | Chosen during implementation and approved. | confirmed |
| D50 | Creating a folder by drag is made easy: the merge entry zone is the centre of the target, `max(50 % of the side, 36 pt)` per axis; a merge target is kept while the finger stays inside the frame minus 6 pt (hysteresis); neighbours are pushed away only after a 0.2 s dwell (`reorderPreviewDwell`) on an occupied cell. The 600 ms hold of D22 is unchanged. The numbers are estimates, tunable through `TesseraTileMergeZone` constants. | Hand testing showed merging 1x1 tiles was too hard. | confirmed (values not yet verified on a device) |
| D51 | Every public top-level type has the `Tessera` prefix (`TesseraTileStore`, `TesseraPivotView`, `TesseraPanoScrollView`, ...); nested types do not. | Generic names such as `TileStore` or `TileSize` collide with host types; a breaking rename was free before 1.0. | confirmed |

## Resolved questions

Questions that were open during development and are now folded into decisions:

- Phases in parallel or in sequence: D2.
- CI: not in v1 (D3), added for the public release.
- Example host: yes (D16).
- Folder expansion inline or full screen: inline, hosts may override (D18).
- Choosing a specific hole on drop: explicit cells (D30); the order-canonicalising store API and its question disappeared with it.
- Live tiles in edit mode: they keep flipping (D37).

## Known limitations

- **Verification gaps.** Several behaviours were verified by tests and on a simulator but not on a physical
  device: haptics, merge highlight while holding, rotation in the middle of a drag, VoiceOver focus after
  operations, RTL and Dynamic Type on the full start screen. See [MANUAL-TESTING.md](MANUAL-TESTING.md).
- **`startDrag` contract.** When a drag begins, the grid snapshot must match the model; otherwise the drag does
  not start (an assertion fires in debug builds). Hosts apply store snapshots.
- **Two `onChange` calls on a collapsing drop.** A drop that collapses an empty row delivers two change
  callbacks to the host.
- **Tiles missing from the catalog.** They keep their cell in the store but do not take part in layout.
- **Layout warnings in windowed tests.** A transient `invalid index path` warning from a custom layout can
  appear in tests around count-changing batch updates; it does not reproduce deterministically.
- **Resources.** `TesseraStartScreen` reads strings through `Bundle.module`; a consumer that copies the module
  without its resource bundle crashes on string lookup.
- **Localization.** Built-in strings exist in English and Russian; the folder screen and accessibility strings
  cannot be overridden by the host, so another language needs new tables and plural rules.
- **Folder size.** A folder is created medium; its stored size is not normalised on load.
- **Not provided.** Photo slideshows in tiles, push updates, an edge-swipe plugin, a standalone performance kit
  module, a repeating Pivot header strip, a per-section Panorama background, and the "show more tiles" mode.
