# Manual testing checklist

Automated tests cover logic and windowed UIKit behaviour on the simulator, but several things need a real
device or a hands-on run: haptics, VoiceOver, live gestures, rotation and animation quality. Nothing below has
been verified on a physical device yet; tick an item only after an actual run.

## Running the Example app

1. Open `Example/TesseraKitExample/TesseraKitExample.xcodeproj` in Xcode (it uses the local package).
2. Pick an iPhone simulator or a connected device and run.
3. Tabs: **Grid** is a bare tile grid with `TesseraTileStore` and an edit coordinator; **Start** is a full
   `TesseraStartScreenViewController` (hook page, start screen, apps list, wallpaper parallax). Use **Start**
   unless an item says otherwise. The default grid has 6 columns, so a 1x1 tile is about 55 pt wide on a
   375 pt screen.
4. Haptics and VoiceOver need a device. For right-to-left runs switch the language or use the
   "Right-to-Left Pseudolanguage" scheme option.

## VoiceOver

- [ ] Swipe through a grid that has holes, a tall tile and a wide tile (also after scrolling): focus goes row by
  row, left to right, by each tile's top-left cell. The open folder panel is read after the last element of the
  folder band; panel tiles come after the folder tile. Repeat in RTL: same order, mirrored frames.
- [ ] After "Unpin", focus goes to the next element in reading order (the previous one if it was last; the grid
  itself if it is empty). After "Change size", a drop or a take-out, focus is on the changed element; after a
  merge, on the folder.
- [ ] Unpin a tile inside an open panel: if the folder dissolved, focus is on the remaining tile; otherwise on
  the next panel tile (the previous one for the last). The "Unpin" action exists on panel tiles.
- [ ] "Change size" performs the same step as the size arrow and announces the new size.
- [ ] On an open folder panel's tile, the actions rotor offers "Move earlier" and "Move later" (no "earlier" on
  the first, no "later" on the last). The action moves the tile one position, announces "Position N of M", and
  keeps focus on the same tile in its new cell. After a neighbour leaves the folder the action set updates.
- [ ] A folder tile and an open panel title offer "Rename". On a closed folder it opens the panel and starts
  editing; the field reads as "Folder name"; after return, focus goes back to the title and the folder is read
  with the new name without extra announcements.
- [ ] A folder tile reads its title, then a value with the badge number (or "has a notification"), then the
  tile count, plus "expanded" when open. The number is the sum, not "99+".
- [ ] A tile with a dot badge reads the "has a notification" value; a small 1x1 tile with a badge still reads
  the caption and count ("Mail, 3").

## Drag and drop

- [ ] **Empty cells and new row.** In edit mode drag a tile into a hole (for example after unpinning a
  neighbour), below the last row, and onto an occupied cell. The occupied cell and the tiles below it are
  pushed down in a cascade; on drop the tile lands exactly where the preview showed. An empty row collapses
  only after the drop, never during the drag.
- [ ] **Preview animation.** Move the finger slowly and quickly across different cells: neighbours move smoothly
  without flicker, jumps or ghost tiles; cancelling the drag restores the original layout.
- [ ] **Merge highlight.** Hold a tile over the centre of another tile and over a folder: the highlight is
  visible, does not slide away from the finger, and disappears when the finger leaves; the grid base does not
  shift.
- [ ] **Haptics (device).** Pick up a tile, hover a merge target for 0.6 s and release: a haptic fires when the
  merge becomes ready. Picking up a panel tile gives an impact; dropping into another slot gives a success;
  there is no tick per slot change and no second impact when a panel reorder turns into a take-out.
- [ ] **Two 1x1 tiles into a folder.** On a 6-column grid drag a 1x1 onto a neighbouring 1x1 from the side and
  from above/below and keep the finger in the centre: the target does not slip away on approach, the highlight
  does not flicker when the finger trembles, after about 0.6 s the tile is absorbed and the release creates a
  2x2 folder on the target's cell. Sweeping quickly across the target's edge and releasing reorders instead.
  Judge whether the entry zone (36 pt), hold zone (6 pt) and dwell (0.2 s) feel comfortable.
- [ ] **Wide and large tiles and folders.** Drop a 4x2 or 2x2 on the centre of a small tile: merge works. A folder
  dropped on a folder reorders; a tile held on a closed folder is added to it; from a panel onto the centre of
  its own folder it returns. A slow approach to an edge shows the push-away preview; the 0.2 s dwell does not
  make edge reordering feel sluggish.
- [ ] **Scrolling and mid-drag changes.** Drag near the top and bottom edges of a tall grid (auto-scroll) and
  press Home or trigger a system gesture mid-drag: the layout is restored with no stray snapshot or placeholder.

## Folders

- [ ] **Take-out from a panel.** In edit mode open a folder with three tiles and drag one tile out onto an
  empty cell, onto a new row, onto another folder, and back onto its own folder (cancel). Then take one tile out
  of a folder with two tiles: the folder dissolves and the remaining tile takes its cell (preview and result
  match).
- [ ] **Dissolution animation.** Unpin or take out a tile of a two-tile folder while its panel is open: the
  panel closes with animation and the folder is replaced by the remaining tile, with its own size (a larger one
  pushes neighbours down, a smaller one leaves a hole), without artifacts. With Reduce Motion it is instant.
- [ ] **Unpin button on panel tiles.** In edit mode open a folder of three tiles: each panel tile has an unpin
  button in its corner, comfortable at 55 pt (6 columns), and it does not steal taps from neighbours or the
  long press on the tile body. Tapping it flies the tile out, the rest close ranks, the panel stays open; in a
  two-tile folder it dissolves the folder. Reduce Motion: no flight. VoiceOver: buttons are not in the traversal
  order. RTL: mirrored corner.
- [ ] **Reorder inside the panel.** In edit mode open a folder with 3+ tiles, long-press a tile body (not the
  corner button) and drag within the panel: the panel stays open, the tile is hidden, a placeholder sits in the
  slot under the finger, neighbours shift smoothly, release puts the tile in the slot (the order survives
  closing the panel and a relaunch). Cancelling (app to background, system gesture) restores the order; a drop
  on its own slot changes nothing; unpin buttons return after the drop. Repeat on a long panel taller than the
  screen with auto-scroll at the edges, in RTL (slot 0 on the right) and with Reduce Motion (shift without
  animation).
- [ ] **Take-out after entering the panel.** Pick up a panel tile, move it inside the panel, then move the finger
  out of the panel frame (about 16 pt margin): the panel closes immediately, the snapshot stays under the finger
  without a second "lift", and the usual targets work (empty cell, new row, another folder, cancel). Returning
  the finger over the old panel area does not resume reordering.
- [ ] **Rename.** Hold the folder name in the open panel for about 0.5 s: it becomes an editable field in place
  with all text selected, and the tiles below do not jump. Input works with software and hardware keyboards;
  return commits; tapping empty grid space commits without closing the folder; an empty name restores "Folder";
  more than 64 characters are not accepted; a long name truncates with an ellipsis. Closing the panel, entering
  or leaving edit mode, or tapping a panel tile mid-typing commits the name. A long press on the name does not
  enter edit mode or start a drag; a long press on a panel tile still takes it out. The name survives a
  relaunch.
- [ ] **Keyboard and long panels.** With a panel of 12+ tiles and the header near the bottom edge: showing the
  keyboard scrolls the grid so the field is above it, and the position returns after return; rotation, keyboard
  size changes (QuickType, emoji) and a floating iPad keyboard keep the field visible; with Reduce Motion the
  scroll is not animated.

## Badges and edit buttons

- [ ] **Badge versus size arrow.** On a narrow device (375 pt) and a wide one (414 pt): in normal mode the badge
  is at the bottom right (bottom left in RTL) and the caption does not touch it; in edit mode the badge shifts
  away from the size arrow on 1x1, 2x2 and 4x2 (capsule, two-digit counter, dot) without overlapping it; the
  "99+" capsule on 1x1 is hidden during edit mode and returns afterwards. Live tiles behave the same; with
  Reduce Motion the shift is not animated.
- [ ] **Unpin above size arrow.** On a 1x1 tile (about 50-55 pt) a tap on the upper half near the right edge
  unpins, the lower half changes size; a tap at the centre acts as a tap on the tile, and long press and drag
  from the centre work. Between vertical neighbours (the circles touch and the hit zones overlap) a tap closer
  to a button's centre hits that button. In RTL everything is mirrored.
- [ ] **Edge of a button in the gap.** In edit mode tap exactly on the part of an unpin or size button that
  protrudes into the gap between tiles: the action runs and edit mode stays active. A tap in empty gap space
  away from buttons still leaves edit mode. Same in RTL and on panel tiles.
- [ ] **Button overhang.** On a grid of small and medium tiles the circles of vertical neighbours touch but do
  not overlap; hit zones on 1x1 (about 40-43 pt on the short side) are easy to hit on the first try.
- [ ] **Size cycle.** Tapping the arrow goes small, wide, medium, large, small (only allowed sizes on a narrow
  grid). The size survives a relaunch.
- [ ] **1x1 with a badge.** A small "Mail" tile with badge "3", "99+" and a dot shows the icon at the top centre
  and the badge at the bottom right with no caption; the icon is large enough and not hidden by the badge. A
  small tile without a badge keeps its caption, and 2x2 and 4x2 tiles with a badge keep theirs. A live 1x1 tile
  with an icon on one side shows icon and badge; a side without an icon keeps its text. In edit mode the icon
  does not move, and the badge moves away from the arrow. With Dynamic Type (XXL, AX1-AX5) the icon does not
  disappear and the badge does not leave the tile.
- [ ] **Folder badge.** Add "Mail" (counter 3) to a folder: its tile shows a "3" capsule at the bottom right
  (bottom left in RTL), the caption narrows to fit and the mini grid does not touch the capsule. Add "Music"
  (5): the capsule shows 8. Push the sum above 99: "99+". A folder whose tiles have only dots shows a red dot;
  a folder without badges shows none. The badge follows counter changes and disappears when all are cleared.
  Dissolving the folder leaves the badge on the remaining tile.
- [ ] **Folder badge and size.** Resize a badged folder through 2x2, 4x4, 1x1 and 4x2: the capsule stays at the
  bottom corner; on 1x1 there is no caption and the mini grid shrinks without touching the capsule; "99+" on
  1x1 is hidden in edit mode and returns after it; in edit mode the capsule moves away from the arrow
  smoothly (without animation under Reduce Motion).
- [ ] **Jiggle off by default.** On both tabs enter edit mode with a long press: tiles and buttons are still,
  with no rotation on entering or after drag, unpin, resize, folder creation or leaving edit mode. Set
  `TesseraTileEditConfiguration.isJiggleEnabled = true` in the host: tiles sway with different phases, buttons
  rotate with the tile, and layers are unrotated after leaving edit mode. With Reduce Motion on, nothing sways
  even with the parameter set (toggling the setting mid-edit stops it at once).

## Rotation, RTL and Dynamic Type

- [ ] **Rotation.** Rotate to landscape and back (a) in normal mode, (b) in edit mode, (c) in the middle of a
  live drag and right after a drop: tiles stay on their cells, holes persist, no snapshot or placeholder is
  left behind, and the column count does not change.
- [ ] **RTL.** Switch to an RTL language: cells mirror (column 0 on the right); dragging by cells, edit
  buttons and VoiceOver order show no inversions.
- [ ] **Dynamic Type.** Try sizes XXL and AX1-AX5: tile captions do not break mid-word, edit buttons do not
  overlap captions, folder panel and title stay readable, the folder badge does not overlap caption or
  preview, and the preview does not vanish.
- [ ] **Folder badge accessibility under large type.** At XXL and AX1-AX5 the capsule of 2x2 and 4x2 folders
  does not overlap caption or preview.
- [ ] **Rename in RTL and large type.** In RTL the field and title have the same frame and alignment; at XXL
  and AX1-AX5 the field font matches the title, the line is not clipped by the header and the underline does not
  reach the panel tiles.

## Persistence and migration

- [ ] **v1 to v2 migration.** Put a version 1 `tiles.json` (keys in order, no `row`/`column`) into the Example's
  store directory and launch **Start**: the layout looks as before, without holes. After the app is left, the
  file is version 2 with `row`/`column` and the canvas width. Relaunching gives the same layout.
- [ ] **Width change.** Run with a different `columns` than the saved width: a reading-order projection without
  holes is shown and the file is not rewritten until the first edit; returning to the original width brings the
  holes back.
- [ ] **Holes in everyday use.** Unpin a tile in the middle of the grid: the hole stays and lower tiles do not
  move up. Unpin the only tile of a row: the empty row collapses right away. Pinning from the apps list puts the
  tile in a new row at the end.

## Live tiles

- [ ] Live tiles (and folder mini tiles) flip on **Start**; flips pause while the apps list or hook page is
  shown and when the app is in the background, and resume after.
- [ ] Live tiles keep flipping in edit mode; with Reduce Motion they show a static front face.
- [ ] Merge highlight, haptics and live flips together: while hovering a merge target a flipping tile does not
  glitch or lose its face state.
