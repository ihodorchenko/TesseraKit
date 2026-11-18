# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## [1.0.0]

First stable release. TesseraKit is a Swift package (iOS 15+, Swift 5.9, no dependencies) with four libraries:
Windows Phone style UI components for iOS, built on a UIKit core with SwiftUI facades.

### Added

- **TesseraCore**: the shared layer.
  - A pager with two modes: `paged` (full-page pages) and `snapping` (custom snap through
    `targetContentOffset`), with lazy loading of neighbouring pages, prefetch and reusable content hosting for
    UIKit controllers and SwiftUI views.
  - A parallax layer driven by a single progress scalar, a gesture arbiter that gives horizontal gestures to the
    pager and vertical ones to children, and an accessibility kit (page-step scrolling, announcements,
    RTL normalisation of progress).
- **TesseraPanorama**: a panorama with a peeking next section, custom snapping, single-image background
  parallax and section headers interpolated by progress.
- **TesseraPivot**: a pivot with a header strip synchronised end to end with the pages, an indicator that follows
  progress across headers of different widths, and vertical scrolling inside pages. Dynamic Type switches the
  strip to a larger mode.
- **TesseraStartScreen**: a start screen with live tiles.
  - A tile grid with four sizes (1x1, 2x2, 4x2, 4x4), 6 columns by default, and an optional hook page and
    apps list around it (a pager of one to three pages).
  - Live tiles with 3D flips, staggered updates, pauses off screen and in the background, and a static face
    with Reduce Motion. Tile badges (counter, "99+", dot) sit at the bottom corner; a small tile with a badge
    shows icon and badge without a caption.
  - Edit mode: long press to pick up, unpin and size-cycle buttons, an optional jiggle
    (`TesseraTileEditConfiguration.isJiggleEnabled`, off by default and always off with Reduce Motion),
    push-down physics while dragging, a hold-to-merge gesture with highlight and haptics, and a magnet to the
    target cell.
  - Folders: expanding inline below the folder tile, rename in place, a badge that sums the tiles' badges, drag
    in and out, reorder inside the open panel, host approval of grouping, and automatic dissolution when only one
    tile is left.
  - An apps list with a jump list and a settings section, linked both ways to `TesseraTileStore`.
  - `TesseraTileStore`: JSON persistence, catalog cleanup and change callbacks. `TesseraStartScreenView` and
    `TesseraStartScreenViewController` expose the screen to SwiftUI and UIKit.
- **Explicit cells and holes.** Every top-level item has an explicit cell (`row`, `column`). Holes are kept
  after unpin, merge, drop and shrink; collisions push tiles down in a cascade; an empty row collapses only on
  drop; a drop picks the cell under the finger, with a "new row" target at the bottom. If the host's `columns`
  differs from the saved width, a reading-order projection without holes is shown and the file is left
  untouched until the user edits.
- **Persistence.** `tiles.json` is schema version 2: it stores `row`/`column` and the canvas width. Version 1
  files migrate automatically on first use. A file written by a newer version is kept as a backup and left
  unchanged.
- **Accessibility** is part of every component: VoiceOver (page scrolling, announcements, custom actions for
  unpin, resize, rename, move earlier/later, add to or take out of a folder, and reading order by cells),
  Reduce Motion, Dynamic Type and right-to-left layouts. Built-in strings are localized in English and Russian.
- An example app (`Example/TesseraKitExample`) with tabs for each component, including a full start screen.

### Changed

- **Breaking:** every public top-level type now has the `Tessera` prefix (for example `TileStore` became
  `TesseraTileStore`, `PivotView` became `TesseraPivotView`, `QuickPanelProvider` became
  `TesseraQuickPanelProvider`). Nested types keep their names.
- **Breaking:** the StartScreen delegate callbacks for moves are cell based: `tileEditCoordinator(_:didMove:toCell:)` and
  `tileEditCoordinator(_:didMove:toFolder:atCell:)` replace the index-based callbacks. `createFolder(withTile:title:columns:)` is
  public.
- The size cycle by the size arrow is small, wide, medium, large. The unpin button is at the top corner and the
  size arrow at the bottom corner (mirrored in RTL).
- New folders are always medium (2x2) and get a localized default name.
- Merging tiles into a folder by drag is easier: a larger entry zone, hysteresis on the merge target and a short
  dwell before neighbours are pushed away.
- Edit buttons protrude 4 pt beyond the tile corner (was 6 pt).

### Removed

- **Breaking:** the index-based StartScreen API (`pin(at:)`, `move(toIndex:)`, order-based `pack`/`repack`
  entry points, `previewOrder`, `canonicalizeVisibleOrder` and similar) is gone, with no deprecated shims. Use
  the cell-based operations on `TesseraTileStore` and `TesseraTileEditCoordinator`.
- The order-canonicalisation step that hosts previously had to call.

### Fixed

- Pager `reload` keeping the current page, snap velocity units, parallax direction, VoiceOver page direction,
  folder panel layout under tall neighbours, wrong drop positions, lost taps after swipes, live tile flip
  glitches, and many smaller defects found in independent reviews and hand testing of all four libraries.

## [0.4.0] - 2026-11-16

Folder and editing work on top of 0.3.0: drag and drop of tiles in and out of folders, the explicit-cell grid
model with real holes and `tiles.json` version 2, six default columns, folders that dissolve at one tile,
badge and edit-button corner rules, folder rename and badge sums, reordering inside the folder panel, and an
easier drag-to-merge gesture. No Git tag was created for this version before 1.0.0.

## [0.3.0] - 2026-11-02

Fixes from two independent reviews of all four libraries (pager reload, snapping, parallax direction,
VoiceOver, folder panel layout, grid state and drag coordination), plus localization of StartScreen strings.

## [0.2.0] - 2026-10-30

Folder behaviour like Windows Phone (inline expansion under the folder tile, folder preview, tap interception
hook) and drag physics following the Windows Phone reference.

## [0.1.0] - 2026-10-29

Initial release of the four libraries, with live tiles and an example app.
