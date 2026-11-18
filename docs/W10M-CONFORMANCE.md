# TesseraStartScreen vs. the Windows 10 Mobile start screen

This document compares the behaviour of `TesseraStartScreen` with the Windows 10 Mobile (W10M) start screen (builds 10586 and 14393). The reference is [W10M-STARTSCREEN.md](W10M-STARTSCREEN.md) (§1–§9, referred to below as "ref §n"); facts about our implementation come from the code and from [STARTSCREEN-IOS-DESIGN.md](STARTSCREEN-IOS-DESIGN.md); decisions are in [DECISIONS.md](DECISIONS.md) (D-numbers); manual verification status is in [MANUAL-TESTING.md](MANUAL-TESTING.md). The review answers what matches, what does not, and what is done differently. It is not a specification and not a verdict: a difference is not a defect, it is either a deliberate decision or a known gap.

TesseraKit is an independent project and is not affiliated with Microsoft. Windows Phone and Windows 10 Mobile are trademarks of Microsoft Corporation.

## Contents

- [How to read this](#how-to-read-this)
- [Scope of the comparison](#scope-of-the-comparison)
- [Summary table](#summary-table)
- [Notes by group](#notes-by-group)
- [Deliberate departures](#deliberate-departures)
- [Known gaps](#known-gaps)
- [Apps list: outside the comparison](#apps-list-outside-the-comparison)
- [What the review does not cover](#what-the-review-does-not-cover)
- [Sources](#sources)

## How to read this

Statuses in the summary table:

- ✅ **matches**: behaviour and meaning are the same; differences are only in units, timing estimates or technique.
- 🔶 **partly**: the mechanic exists, but part of it differs or is not covered by the reference (stated in the comment).
- ❌ **differs**: the mechanic exists but follows different rules (order, model, object of the action).
- ➖ **not implemented**: we do not have it; the W10M column says what existed in the OS and how reliably it is known.
- ➕ **added by us**: absent in W10M or not described by the reference; an extension, not a divergence. If the reference says nothing about the aspect and there is nothing to compare with, the status is ❔, not ➕.
- ❔ **not comparable**: the reference is silent on the aspect (the W10M column says "not recorded / not described") while we have our own behaviour. The row is information, not a grade: with nothing to compare, ✅/❌/➖ would be a grade without a reference. Border with ➕: ➕ means the reference records the aspect's absence (or it is reliably absent), ❔ means the reference says nothing at all.

Some of our behaviour is a **host parameter**, not a built-in value: `columns`, `onTap` (D12), `beginEditing`/`toggleEditing`, the `onLongPress` threshold, `supportedSizesProvider`, the wallpaper and parallax, the side pages (D13) and texts. Such rows say "host parameter"; without that note, the component sets the value. "We have 4 columns" and "4 by default, the host may set 6" are different statements.

The reference marks reliability: `[spec]`, `[observed]`, `[undocumented]`. An `[undocumented]` mark does not by itself devalue a row: if the reference describes a working model, the status follows it (usually 🔶 or ❌) and the comment says so. If the reference is entirely silent and has no section, the row gets ❔.

## Scope of the comparison

Only the start screen itself is compared: grid and sizes, layout, normal mode and editing, folders, gestures. The left hook and the right apps-list page are package extensions (D13): W10M Start has neither, so they are not graded on an "as in W10M" scale; the absence of search, "Recently installed" and a context menu on the right page is not a defect of the start screen. The component is generic: a tile is an action (`TesseraTileDescriptor.action`); app, file and link are indistinguishable to it, so the W10M tile kinds (normal, secondary, web) are not a benchmark. W10M system screens (the apps list, Settings, Continuum, the lock screen) are out of scope.

## Summary table

Rows are grouped by layer, from model to accessibility.

### Model and data

| Aspect | W10M | TesseraKit | Status | Comment |
|---|---|---|---|---|
| Model composition | App tile, secondary tile, web link, folder `start:Folder` (ref §1, §6.1) | A `TesseraTileDescriptor` tile and a `TesseraTileFolder` folder; no separate types | ➕ | Separate types are not needed: any item (app, file, link) is an equal tile with an action. This is generality, not a limitation. |
| What a tile represents | App, secondary tile or web link; the type comes from the manifest and markup (ref §1, §6.1) | Any item: app, file or arbitrary action; the type is not distinguished, `action` is a host closure (D12) | ➕ | Deliberate: the component does not know what a tile launches. |
| Position storage | `Row`, `Column`, `Size`: absolute coordinates in the layout markup (ref §1, §3) | `tiles.json` version 2: an explicit `row`/`column` cell per top-level item (logical coordinates, 0 is the start of reading order), canvas width `columns`, `sizes`, folders; reading order is derived from cells | ✅ | D30, D33. Matches for the top level; folder contents have no cells, whereas in W10M nested tiles have coordinates relative to the folder (ref §6.1); ours keep an order, which can be changed (D40). |
| Size set | Three in the UI: 1×1, 2×2, 4×2; 4×4 is schema and desktop only (ref §1, §5) | Four sizes, `.medium` by default (D15) | ❌ | `large` is available in the UI, which the phone Start did not offer. |

### Grid and geometry

| Aspect | W10M | TesseraKit | Status | Comment |
|---|---|---|---|---|
| Column count | 6 by default, 8 with "Show more tiles"; depends on DPI and scale (ref §2) | 6 by default (D26); `columns` is a host parameter, no auto-selection | ✅ | `TesseraTileLayoutEngine.defaultColumns`; screen width does not change the column count. For 8 columns see the next row. |
| "Show more tiles" | A 6↔8 toggle, smaller tiles, layout recomputed (ref §2–§3) | Neither toggle nor recomputation | ➖ | Reachable only by the host changing `columns`; deliberately not built (D26). |
| Proportions and gaps | Assets 71/150/310 epx, gap 6–10, margins about 12: a reconstruction (ref §2) | Unit derived from width, 8 pt gap, 16 pt margins plus safe area, pixel alignment | 🔶 | Cell multiples and proportions match; absolute values differ. |
| Orientation | Start is portrait; the grid is not rebuilt on rotation (ref §2) | Rotation recomputes frames from `bounds`; columns do not change | ❌ | Landscape is not forbidden; the host restricts orientation if needed. |

### Layout and holes

| Aspect | W10M | TesseraKit | Status | Comment |
|---|---|---|---|---|
| Holes and packing | The grid is not repacked, holes remain, Start is a canvas (ref §3) | Tiles anchor to their cells and holes remain (after unpin, merge, shrink and drop); there is no back-filling; packing by order is only a fallback (no usable cell table, v1 migration, first-launch layout) | ✅ | D30. Compositions with holes ("column at the edge", "L") are reachable. Exception: at a different canvas width a hole-free projection is shown (see "Different canvas width"). |
| Collapse after unpin | Neighbours do not move up; only a fully empty row collapses (ref §3, §5) | Neighbours stay and a hole remains; a row that no tile occupies (tall tiles included) collapses right after unpin and on drop, not during a drag | ✅ | D31. |
| Adding a new tile | Appended to the end of the feed as a new row, not into the first hole (ref §3, [undocumented]) | `pinTile(_:columns:)` and pin from the apps list go to a new row at the end of the canvas | ✅ | The reference is silent on user-initiated "Pin to start"; the match is with the indirect working model (ref §3, OEM markup). |
| Drop and collisions | A tile takes the cell under the finger, neighbours move apart, others are repacked in the affected rows; dropping into emptiness is possible (ref §5) | A drop picks the cell under the finger (empty, occupied or "new row" below); an occupied target and colliding tiles are pushed down in a cascade in their own columns, everything else stays | 🔶 | D31. "Cell under the finger" and "into emptiness" match; W10M repacks the affected rows (horizontally too), ours only shifts down. Exact W10M behaviour is undocumented. |
| Different canvas width | Layout is recomputed, some positions "move", no compaction, holes remain (ref §3, "Show more tiles", [observed]) | If the stored canvas width differs from the host's `columns`, a projection is shown: a reading-order repack without holes; the file is not rewritten, returning to the old width restores the holes, the first edit adopts the new width | ❌ | D32. Host parameter (`columns`); the width normally does not change. The rules differ: W10M does not compact, our projection does. |

### Pages and scrolling

| Aspect | W10M | TesseraKit | Status | Comment |
|---|---|---|---|---|
| One feed or pages | One vertical feed; no horizontal pages (ref §1, §3) | A pager of 1–3 full-screen pages, START in the center (D13) | ➕ | A package extension, not a different way to build the feed: START scrolls vertically without paging. |
| Swipe left to the list | Start slides left and the list enters from the right; swipe right and Back return (ref §4) | The right page of the pager if the host provides a factory; swipe right returns | 🔶 | Swipes match; iOS has no hardware Back, so return is by swipe or `showPage`. |
| Hook on the left | None (ref §1) | A left page, `TesseraQuickPanelProviding` (D13) | ➕ | Extension; no analogue in W10M. |
| Wallpaper parallax | The background moves slower than content when scrolling vertically and on transitions (ref §4) | Vertical parallax, factor 0.5 clamped to 0.4–0.6; horizontally 1:1 | 🔶 | No parallax on page transitions; with Reduce Motion the factor is 0. |

### Normal mode

| Aspect | W10M | TesseraKit | Status | Comment |
|---|---|---|---|---|
| Tap on a tile | A press animation and the app launches (ref §4) | `onTap(.tile)` is an event; the host runs the action (D12) | 🔶 | Launching is a host parameter; the component does not do it. |
| Tap on a folder | Expands a panel with tiles (ref §6.4) | Toggles the panel; `folderTapHandler` may cancel the expansion and `onTap` | ✅ | The gesture matches; `folderTapHandler` (D18) is a host parameter. |
| Wallpaper, transparency, accent | A full-screen or tiled picture, a transparency slider, a theme accent (ref §4) | `wallpaper` and a factor; no tiling, transparency or accent | 🔶 | The library draws a full-screen wallpaper with parallax; tiling, transparency and accent are left to the host. |

### Edit mode

| Aspect | W10M | TesseraKit | Status | Comment |
|---|---|---|---|---|
| Entry | Long press only, about 1 s (actually 0.4–0.8); no button (ref §4, §5) | A 0.45 s long press if the host set `onLongPress`; `beginEditing`/`toggleEditing` are host API | 🔶 | The coordinator is attached by the host; an "Edit" button, if any, is the host's. |
| Edit widgets | Two corner widgets only on the held tile; the rest are dimmed without widgets (ref §5) | Unpin and resize buttons on all visible tiles at once; no unpin on a folder; unpin (without resize) on tiles of an open folder panel (D46) | ❌ | There is no "selected tile" state: overlays are mounted on every cell. Kept as is (D27). Both buttons of a tile stand at the end of the line, one above the other. |
| Unpin button corner | Top right (ref §5, §9) | The top corner **at the end of the line**: right in LTR, left in RTL; the resize arrow is the bottom corner of the same side | ✅ | One helper chooses the corner for the grid and the folder panel (D46); D29. On a small tile (about 50–55 pt) the touch zones of the two buttons split the height (unpin the upper half, resize the lower half); circles of neighbouring tiles touch without overlapping (4 pt overhang against an 8 pt gap, D48), and a touch in an intersection goes to the nearest center. |
| Dimming | The rest are dimmed; the amount is undocumented (ref §5) | Alpha 0.7 for everything except the dragged tile and the target; 0.18 s animation | 🔶 | The mechanic matches; the amount is ours; with Reduce Motion the dim stays. |
| Jiggle | Tiles do not wobble; the grid is static (ref §5) | The grid is static by default; the host may enable a ±1.2° sine over 0.4 s with phase offsets (`TesseraTileEditConfiguration.isJiggleEnabled`); always off with Reduce Motion | ✅ by default; ➕ when enabled | D39. Without the parameter it matches W10M; enabled, it is an iOS borrowing. |
| Size cycle and exit | Small → wide → medium → small; one tap is a step, editing ends (ref §5) | small → wide → medium → large → small; editing continues after a step | 🔶 | `TesseraTileSize.cycleOrder`, `TesseraTileSize.next(among:)`. W10M order with `large` appended (D28); the host sets the set (`supportedSizesProvider`), not the order; the VoiceOver action does the same step. Editing not ending after a step is deliberate (D27); the fourth size is D15. |
| Unpin | Immediate, no confirmation; the tile disappears and a hole remains (ref §5) | A 0.22 s fly-out, `store.unpin(_:columns:)`, no confirmation; a hole remains, an empty row collapses | ✅ | The animation is ours. |
| Exit | Tap on the screen or Back; no "Done" button (ref §5) | Tap on the background and `endEditing`; a Done button exists only in the Example host | 🔶 | The library draws no "Done"; a host button must not be counted as a match. |

### Folders

| Aspect | W10M | TesseraKit | Status | Comment |
|---|---|---|---|---|
| Creation and size | Drag and hold over a tile; a 2×2 folder (ref §6.2, §6.8) | Drop on the center with a 0.6 s hold and movement under 10 pt; always `.medium` (D20). Easing (our decisions, D50): the merge entry zone is `max(50 % of the side, 36 pt)` per axis, once in, the target holds across almost the whole tile (6 pt hysteresis), and the push-away preview of the target's edge appears only after a 0.2 s dwell | ✅; ➕ zone, hysteresis and dwell | From wide/large the folder replaces the slot with a medium one; host approval (D14) defaults to allowed. W10M ("hold for a moment", "the target swells") does not give zone or dwell sizes `[undocumented]`: 36 pt, 6 pt and 0.2 s are our estimates, not yet verified on a device. |
| Preview | A mosaic of thumbnails: 4 in 1×1, up to 8 in 2×2 (an estimate); live (ref §6.3) | Up to 4 mini icons with independent flips and badges; the count does not depend on size | 🔶 | A mosaic and "liveness" exist; the count is fixed (D43). |
| Folder badge | Not recorded (ref §6.3, [undocumented]) | The sum of numeric badges of the contained tiles; no counts but a dot gives a dot; a sum above 99 shows "99+"; no badges means no widget. Place, size and rules (corner, avoiding the resize arrow, hiding "99+" on 1×1) match a tile's badge; a 1×1 folder with a badge has no label and its mini grid sits above the badge row | ❔ | `TesseraTileFolder.aggregateBadge(of:)`; our decision D44, neither a match nor a divergence. The sum covers all tiles of the folder, not only the four preview icons; mini icons keep their own badges. VoiceOver: the folder's value combines the badge value, tile count and "expanded". |
| Panel | An overlay above Start, 4 columns, grows out of the tile (ref §6.4) | An inline row in the grid under the "folder band"; 1×1 tiles in the grid's columns | ❌ | D17/D18: the panel pushes tiles apart instead of covering them; the column count is the same as the grid's. |
| Renaming | Tap and hold the name in an open folder (in 8.1 a field above the folder); one line, truncated to the header width, no character limit; an empty string probably restores the default (ref §6.7) | A long press (about 0.5 s) on the name in an open inline panel gives a one-line field in place (all selected, Return is "Done"); an empty name returns the default title ("Folder", or `folderTitle`), limit 64 characters; size and composition do not change; works outside editing too; VoiceOver "Rename" | 🔶 | D35. Gesture and meaning are the same. Ours where the reference is silent: the 64-character limit (layout protection), select-all on entry, committing on tap away, panel close and entering or leaving editing (no cancel). The built-in `TesseraFolderViewController` (sheet) does not rename; it is for hosts that run their own folder screen. Not verified on a device. |
| Unpinning a folder | There is no separate delete command; folders have markers in edit mode (ref §6.7, §6.9) | No unpin button on a folder, only the resize arrow | ➖ | Deliberately not built (D38): a folder lives while it holds tiles (D45). |
| Take-out and moving | Add by dropping onto a closed folder; take out from the panel to the grid; between folders in two steps (ref §6.6) | From the panel in edit mode: onto the cell under the finger (empty, or occupied with push-down) or a "new row", onto another folder with a hold; between folders in one gesture | 🔶 | The set of operations is the same, but moving between folders takes one gesture, not two (D41). |
| Dissolving a folder | An empty folder does not exist; "one tile left" is not described, by analogy with desktop the folder stays with one thumbnail (ref §6.9, [undocumented]) | A folder never has 0–1 tiles: with one left it dissolves and the tile takes the folder's cell with its own size; an empty one disappears (D45) | ❔ | The reference is silent on the one-tile case; our deliberate departure from the analogy "a one-tile folder stays". A larger tile pushes neighbours down (D31), `didDissolveFolder` informs the host. For a sighted user the way to "unpin tiles one by one" (ref §6.9) is the unpin button on panel tiles (D46). |
| Reordering inside the panel | Free reordering of tiles inside (ref §6.5) | In edit mode, long press and drag inside the open panel: the panel stays open, the tile is hidden behind a placeholder, neighbours shift (0.26 s bounce; instant with Reduce Motion), a drop commits the order (`TesseraTileStore.moveWithinFolder`, delegate `didReorderTile`, no host approval); moving the finger outside the panel (+16 pt) switches to take-out; VoiceOver "Move earlier/later" | ✅ | D40, D49. The meaning is the same ("free ordering"); mechanics and thresholds are ours: the slot comes from the panel's slot frames, 16 pt of slack before take-out, no return to reordering within one drag, no haptic tick per slot change. The reference does not fix gesture details, so behaviour at the edge and in a tall panel (auto-scroll) is our decision. Not verified on a device. |

### Live tiles and badges

| Aspect | W10M | TesseraKit | Status | Comment |
|---|---|---|---|---|
| Flip | A turn about the horizontal axis, content from a queue (ref §4) | `CATransform3D` with `m34`, front/back; an 8 s cycle, 0.45 s flip | ✅ | The turn and side swap match; timings are ours. |
| Notification queue | Up to five, cycled; the interval is system policy (ref §4) | Two faces (front/back), no queue | ➖ | The host may change content, but a queue is not modelled. |
| Update synchrony | In 14393 tiles update all at once, not one by one (ref §4, §8) | Stagger in batches of 3 with spread: deliberately not synchronous | ❌ | The stagger stays as our own decision (D36). |
| Badge: corner and range | Bottom right; 1–99, 0 clears (ref §1) | The bottom corner at the end of the line (right in LTR, left in RTL); capsule or dot; above 99 "99+", 0 hidden | ✅ | Corner as in W10M (D29); range matches; the badge is a separate widget, not part of the flip. The label yields (beside or above the badge), in edit mode the badge shifts away from the resize arrow; "99+" on 1×1 is hidden in edit mode (the tile is only 58 pt wide). A small tile with a badge and an icon is the next row. |
| Small tile (1×1) with a badge | An icon and a badge; the label of a small tile is not described in the reference (ref §1, §2: small 71×71, badge bottom right) `[undocumented]` | A small tile with a visible badge and an icon: icon centered at the top, badge in the bottom corner, no label; a small tile without a badge (or without an icon) keeps its label; 2×2 and larger keep their label | 🔶 | D47. The "icon and badge" variant follows W10M; the label on a small tile without a badge is not changed by D47, so in one row small tiles with a badge (no label) and without one (label) look different. A live 1×1 tile follows the rule per side (a side without an icon keeps its text). |
| Live content pauses | Not described; the system updates content (ref §4) | Paused off screen, in the background and with Reduce Motion; public `isLiveContentPaused` | ❔ | Nothing to compare against: the reference does not describe pauses. |

### Accessibility and localization

| Aspect | W10M | TesseraKit | Status | Comment |
|---|---|---|---|---|
| Tile and folder as one element | The reference does not cover Narrator (ref §1–§9) | One element: the label from a live tile's front, the value is the count; custom actions "Unpin", "Resize", folder actions | ❔ | Not compared: the reference has no such topic. |
| `.dot` in VoiceOver | Whether Narrator reads a glyph or a number is not described | `.dot` reads "has a notification" in `accessibilityValue`; the number is read as before; the label does not change | ❔ | D34. A separate accessibility matter, not a divergence from W10M. |
| Reduce Motion, Dynamic Type, RTL | OS settings exist; Start is not analyzed in the reference | Reduce Motion turns off jiggle, lift, magnet, bounce, parallax and flips; Dynamic Type with a cap and fitting; RTL mirrors frames and buttons | ❔ | The reference is silent on these settings. |
| Localization | The UI is localized by the OS; tile names come from apps | en/ru string tables with English fallback; page titles and `TesseraStartScreenStyle` are English host-owned defaults | 🔶 | Interface strings are localized (including the default folder title); page titles and style stay English defaults of the host. |

## Notes by group

### Layout and holes

The model is explicit cells (D30): every top-level item has a `row` and `column`, and the `tiles.json` schema (version 2) carries the canvas width. Reading order, used for VoiceOver and delegates, is derived from the cells. Holes remain after unpin, merge, shrink and drop; a drop picks the cell under the finger and a "new row" target exists at the bottom; a newly pinned tile goes into a new row at the end. Collisions (a drop on an occupied cell, a growing tile, a merge into 2×2, a dissolving folder) are resolved by a push-down cascade (D31); in W10M the affected rows are repacked, which is the one remaining mechanical difference. A row collapses only if empty and only on drop or after unpin, never during a drag. At a canvas width different from the host's `columns` a hole-free projection is shown (D32) and the file is not rewritten. The VoiceOver order by cells, migration of a real v1 file and preview animations are listed in [MANUAL-TESTING.md](MANUAL-TESTING.md).

### Edit mode: focus and session

The key difference is not the hold threshold or the animations but the absence of a "selected tile" state. In W10M editing starts from one tile, which gets the widgets while the others are only dimmed. Here the coordinator mounts an overlay with unpin and resize on every visible cell at once, and the only "selected" tile is the dragged one, for the duration of the drag. Three consequences follow: widgets on all tiles, a global 0.7 dim instead of a single focus, and no exit after a size change. The size cycle is an independent model operation (`cycleSize`), not a "tile plus its next state" session, so editing continues after a step. Jiggle is an iOS borrowing; in W10M the grid is static in edit mode, and ours is static by default.

### Folders: the price of the inline panel

The inline panel (D17) is the main reason for the differences in this group. The panel is not an overlay but a full-width row in the layout: it takes space in the grid, its content shares the grid's geometry (unit, gap, columns) and the tiles below shift down. Hence panel columns equal to grid columns rather than a fixed four, 1×1 tiles without sizes of their own, no separate scroll (the whole page scrolls), and empty space under shorter tiles of the "folder band". Reordering inside the panel is built on the same model: the panel is a view of the folder snapshot, the order of tiles is stored by `TesseraTileStore`, and a drag inside the panel only moves panel cells in the preview and writes the order once on drop. Folders cannot be unpinned for model reasons (D38, D45). Renaming exists (D35) and happens in place of the panel title.

### Pages: the price of the pager

The pager is an architectural frame into which W10M behaviour does not fit completely. W10M has one vertical surface and the list is an adjacent screen entered by a swipe; here START, the list and the hook are equal pages of a pager and the feed lives inside the central one. So "swipe left to the list" matches, while "one feed" does not: there is a horizontal axis W10M did not have, and a left hook. Consequences: parallax works only within a page (wallpaper moves 1:1 across transitions), `currentPage` is confirmed by the pager, and the left edge is a host parameter (on iOS the system gesture owns it).

## Deliberate departures

- **D12: a tile is an action.** `id`, `title`, `icon`, `action`, `badge`, `size`, `liveContent`; there is no `type` field. The host launches; the component only reports the tap. Secondary tiles and web links are plain tiles. Parity with W10M tile kinds is not a goal.
- **D15: four tile sizes.** 1×1, 2×2, 4×2, 4×4. `large` is available in the UI though the phone W10M did not offer it; the cycle has four steps.
- **D13: three pages.** Hook on the left, START in the center, list on the right. A horizontal axis and a left-edge policy appear; parallax lives only within a page.
- **D17/D18: folders expand inline.** The panel is a row in the grid under the "folder band", not an overlay; a host that wants something else intercepts the tap with `folderTapHandler`. There is no separate scroll and no "growing out of the tile" over content.
- **D20: a folder is always 2×2,** as in W10M, regardless of the target's size. A folder from wide/large changes size on the target's cell; neighbours are pushed down when needed. A stored size is not normalized on load, to avoid discarding a deliberate choice.
- **D30–D33: explicit cells and real holes.** Collisions are pushed down in a cascade (D31) rather than repacked by affected rows; a different canvas width shows a hole-free projection (D32), which W10M does not do; there is no index-based public API (D33).
- **D45: a folder never has 0–1 tiles.** W10M does not describe the one-tile case (by analogy the folder stays). Here it dissolves and the tile takes the folder's cell with its own size; a tile may change its on-screen size on dissolve, pushing neighbours down.
- **D27: widgets on all tiles and no exit after a size step.** Kept as an architectural choice of the overlays.
- **D36: stagger of live updates.** The library's own decision, not "as in WP".
- **D37, D41, D42, D43:** live tiles keep flipping in edit mode; moving between folders is one gesture; the grab scale is 0.95 (the reference says tiles grow 5–10 %, `[undocumented]`); up to 4 mini icons per folder regardless of size.
- **D38: no unpinning of folders.**
- **Edit coordinator owned by the host.** The screen does not create `TesseraTileEditCoordinator`; the host creates `TesseraTileStore` and a coordinator over `gridView`. Without a host there is no entry, no widgets and no dim; an app that does not edit pays nothing for overlays.

## Known gaps

- No "Show more tiles" (8 columns) and no notification queue per tile.
- No tile-kind distinctions (secondary tiles, web links) by design.
- No wallpaper tiling, transparency or accent; no parallax on page transitions.
- Collisions are resolved only by shifting down; W10M's horizontal repack of affected rows is not reproduced.
- The hold threshold, dwell, zone sizes and timings are estimates; several behaviours (take-out and reorder in the folder panel, folder renaming, folder badge, merge zone, VoiceOver order by cells, migration of a real v1 file) are not yet verified on a physical device (see [MANUAL-TESTING.md](MANUAL-TESTING.md)).
- Narrator-specific behaviour of W10M is not covered by the reference, so accessibility rows are information only.

## Apps list: outside the comparison

In W10M this is a separate system screen, not a part of Start; here it is the optional right page of the pager, `TesseraAppsListPageViewController` (D13). Parity with the system list is not a goal, and the table is information without statuses.

| Aspect | W10M | Ours | Note |
|---|---|---|---|
| Sections and index | Alphabetical order with letter separators (ref §1) | `UILocalizedIndexedCollation` sections, a jump list with the full alphabet | The reference does not describe the index. |
| Search | A search box at the top of the system list, see the Lumia guide, p. 14 (https://mcgrp.ru/files/viewer/146152/14) | None | Outside Start; not described in the reference. |
| "Recently installed" | A section of recently installed apps on top, see the 2015 review (https://techbang.com/posts/22370-windows-10-for-phone) | None | Outside Start; needs an install history. |
| Context menu and pinning | Long press gives `Pin to start` / `Uninstall` (ref §1, §5) | A 44×44 accessory button for pin/unpin, no menu | `Uninstall` is unavailable on iOS. |
| Settings section | Start personalization is in system Settings (ref §4) | An optional settings section at the bottom of the page | Rows are supplied by the host. |

## What the review does not cover

- **System gestures and the edge:** the presence of a policy (`yieldsLeftEdgeToSystemGesture`) was checked, not behaviour inside a navigation stack.
- **Continuum and the desktop Start:** the desktop layout, `large` on a monitor, OEM partner slots.
- **Secondary tiles and deep links as entities:** they are not in the model; they are expressed as a tile with an action and are not compared in that form.
- **Apps list:** the reference describes it in a single paragraph of §1, without search, "Recently installed" or an index.
- **Themes, accent, transparency, tiling:** styling is a host parameter; in the reference these are OS settings.
- **Sound and haptics:** W10M's merge sound is undocumented; our haptic was not compared.
- **Exact timings:** all milliseconds in the reference are estimates and cannot be compared.
- **W10M Narrator:** the reference has no accessibility section, so rows in that group are information, marked ❔.
- **W10M localization:** string sets, pluralization and RTL are not analyzed in the reference.

## Sources

Repository documents:

- [W10M-STARTSCREEN.md](W10M-STARTSCREEN.md): the reference, §1–§9.
- [DECISIONS.md](DECISIONS.md): decisions D1–D51.
- [STARTSCREEN-IOS-DESIGN.md](STARTSCREEN-IOS-DESIGN.md): design and implementation notes.
- [MANUAL-TESTING.md](MANUAL-TESTING.md): manual verification checklist.
- [CORE-IOS-DESIGN.md](CORE-IOS-DESIGN.md): pager, parallax, arbitration (for pages and scrolling).

Key code files (under `Sources/TesseraStartScreen/`): `TesseraTileDescriptor.swift`, `TesseraTileFolder.swift`, `TesseraTileStore.swift`, `TesseraTileLayoutEngine.swift`, `TileCollectionViewLayout.swift`, `TileGridView.swift`, `TileEditCoordinator.swift`, `LiveTileEngine.swift`, `LiveTileView.swift`, `AppsListPage.swift`, `StartScreenViewController.swift`, `TesseraStartScreenView.swift`, `TesseraStartScreenStrings.swift`; and in `Sources/TesseraCore/`: `Pager/TesseraPagerViewController.swift`, `Parallax/TesseraParallaxLayer.swift`.

External sources for gaps in the reference: the Lumia user guide (p. 14) and a 2015 review; links are in the apps list table.
