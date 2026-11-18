# TesseraCore design

> Design document for the shared `TesseraCore` target of TesseraKit: the mechanics that `TesseraPanorama`, `TesseraPivot` and `TesseraStartScreen` have in common.
> Constraints: **iOS 15+**, **Swift 5.9+**, UIKit core with SwiftUI facades, no external dependencies.
> Companion documents: [PANORAMA-IOS-DESIGN.md](PANORAMA-IOS-DESIGN.md), [PIVOT-IOS-DESIGN.md](PIVOT-IOS-DESIGN.md), [STARTSCREEN-IOS-DESIGN.md](STARTSCREEN-IOS-DESIGN.md).

## 0. Why a Core

The three components share the same mechanics: a pager built around the progress scalar `t`, background parallax, gesture arbitration between a horizontal parent and vertical children, the "no layout while scrolling" rule, SwiftUI facades and RTL / Reduce Motion handling. Duplicating them in three libraries would mean three places for the same bugs.

**Admission rule (the rule of three):** a mechanic enters Core only if at least two components use it. Everything else stays in the component's own library. Core must stay thin; over-abstraction is more dangerous than duplication.

## 1. Contents

| Area | Public types | Purpose |
|---|---|---|
| Pager | `TesseraPagerViewController`, `TesseraPageDescriptor`, `TesseraPagerDelegate`, `TesseraPagerMode` | Horizontal pager with child view controller containers, lazy ±1 loading and the `t = offset.x / pageWidth` progress invariant |
| Snapping | `TesseraSnapPolicy`, `TesseraSnapAlignment` | Custom snapping through `targetContentOffset(forProposedContentOffset:withScrollingVelocity:)` for pages narrower than the viewport (peek) |
| Parallax | `TesseraParallaxLayer` | Background layer driven by a content offset: factor, extra size beyond `contentSize`, both axes, Reduce Motion cut-off |
| Gestures | `TesseraGestureArbiter`, `TesseraGestureAxis` | Parent/child arbitration by dominant axis: horizontal goes to the pager, vertical to the child; supports several children |
| Hosting | `TesseraContentHosting`, `TesseraContentProviding`, `TesseraViewControllerProvider`, `TesseraSwiftUIContentProvider` | Content factories for `UIViewController` and `UIHostingController`, hosting reuse |
| Accessibility | `TesseraAccessibility`, `TesseraRTL` | `accessibilityScroll` to page-step mapping, Reduce Motion query, page-change announcement helper, LTR/RTL normalization of `t` |

Two ideas from the original design are **not** part of Core:

- an edge-swipe helper (a gesture from the screen edge that drives the same `contentOffset`) was considered, but no component needs it; it can be added when a section with its own horizontal scrolling appears;
- performance discipline (only `frame`/`transform`/`alpha` in `scrollViewDidScroll`) is a rule followed by the components rather than a separate module.

A generic reorder mechanic is also out: drag-and-drop of tiles is specific to the start screen, not to a general pager.

## 2. Key contracts

- **Progress invariant.** `t = offset.x / pageWidth`; the integer part is the page index, the fractional part is the transition progress. In RTL `t` is normalized by the reading direction. All consumers (the Pivot header strip, Panorama headers, the StartScreen pager) work with `t`, never with the raw offset.
- **Single writer.** `contentOffset` is written only by the pager (the user's gesture) and by its controller (a programmatic transition). A programmatic transition is `setContentOffset(_:animated:)`; the scroll delegate keeps firing on every frame, so all subscribers animate by themselves. There are no feedback loops because subscribers never write back.
- **Two pager modes.** `paged` uses full-width pages and `isPagingEnabled`. `snapping` uses `TesseraSnapPolicy`: `decelerationRate = .fast`, the nearest page center plus a velocity threshold. Pivot and StartScreen use `paged`. Panorama has its own scroll view (see below) and uses only the snap policy.
- **Arbitration.** The pager scrolls horizontally only, children scroll vertically; the decision is made by the dominant axis of the gesture and scales to several children (StartScreen: the tile grid and the apps list).
- **Parallax.** `backgroundOffset = offset × factor`, `factor ∈ (0, 1)`; the layer is always larger than `contentSize`; Reduce Motion forces the factor to 0.
- **Edge cases of programmatic navigation** are part of the contract (section 3).

## 3. Behaviour of the implementation

This section records where the implementation is more specific than the sketch above. It is the authoritative description.

### Pager

- **Page width in `snapping` mode.** `TesseraPagerViewController` always snaps by the full viewport width and has no page-width parameter; pages are laid out as full-width frames. The peek geometry lives only in `TesseraPanorama`: `TesseraPanoScrollView` computes `itemWidth = bounds.width − peek` and calls the same `TesseraSnapPolicy`. `.snapping` is therefore a reserved mode of the pager (covered by contract tests, not used by a shipped component). If a second consumer of peek appears, the pager can gain a page-width parameter defaulting to `bounds.width`, which is a source-compatible change.
- **Velocity units.** `UIScrollViewDelegate.scrollViewWillEndDragging` reports velocity in points per millisecond, while `TesseraSnapPolicy.velocityThreshold` is in points per second (default 600). Consumers multiply by 1000 before calling the policy. `targetContentOffset` accepts an optional `startOffset` (the offset at the start of the drag): a fast gesture then moves exactly one step from the section where the drag began, instead of from the section nearest to the proposed offset (which already includes inertia and could skip a section). One gesture moves at most one section.
- **Drag without inertia.** If a drag ends with `willDecelerate == false`, UIKit does not apply the snap and the offset stays between pages. In `.snapping` mode the pager settles it itself with an animated `setContentOffset`, and the transition (index, `didShowPageAt`) completes in `scrollViewDidEndScrollingAnimation`.
- **Programmatic jumps farther than one page.** An animated `go(toPage:animated:)` beyond ±1 first moves the offset instantly to the neighbour of the target (so the slots around the target are loaded), then runs one animated step; empty slots never fly past. Progress is not suppressed, so subscribers see a single jump, and `didShowPageAt` is delivered only for the target. An animated `go` to the current page completes immediately.
- **Page lifecycle.** `reload(pages:)` keeps the current page by `id` and reuses the controllers of pages whose `id` survived, so scroll position and state are preserved (SwiftUI content is refreshed through `TesseraContentHosting`). Appearance callbacks are forwarded manually (`shouldAutomaticallyForwardAppearanceMethods = false`): only the current page receives `viewWillAppear` / `viewDidAppear`, while the ±1 neighbours are loaded without them. The current index is captured before a frame change (rotation), so intermediate `scrollViewDidScroll` calls cannot corrupt it. A change of `semanticContentAttribute` re-lays out the slots.
- **Interrupted animated transitions.** When an animated `go` interrupts another animated transition, UIKit synchronously delivers `scrollViewDidEndScrollingAnimation` for the interrupted one, and the pager reports `didShowPageAt` for the intermediate page. `TesseraPivotViewController` filters these out with a transition counter. Ignoring the completion of an interrupted animation inside `go` is a possible future improvement in Core.
- **Updating content without stopping the scroll.** There is no public API to refresh the content of pages that keep their `id` without a `reload(pages:)`, which stops the gesture, inertia and animation. The facades therefore postpone content updates until the motion ends.

### Gesture arbitration

`TesseraGestureArbiter` is **not** installed as the delegate of a `UIScrollView`'s pan gesture recognizer: replacing that delegate would disable the scroll view's own handling of simultaneous gestures (nested scrolling, the system edge swipe). Instead each component:

1. adds a target to the pan recognizer (`addTarget`, additive);
2. on `.began` calls the pure function `TesseraGestureArbiter.axisDecision(forVelocity:)`;
3. for a horizontal gesture builds the arbiter and calls `prepareForHorizontalScroll()`, which disables the vertical children while remembering their `isScrollEnabled`;
4. when the gesture ends calls `endHorizontalScroll()`, restoring the previous values.

Children register themselves through the component's `registerVerticalOwner(_:)` / `unregisterVerticalOwner(_:)`; references are weak, so unloaded pages drop out of the registry on their own. The pager's scroll view is private, so `TesseraPivotViewController` and `TesseraStartScreenViewController` find it by walking the direct subviews of the pager's root view. A public accessor for the horizontal scroll view, or a hook that lets the decision be made in `gestureRecognizerShouldBegin`, is a possible future addition.

Gesture recognizers hold their targets weakly (including the built-in pan of `UIScrollView`), so adding a controller as a pan target does not create a retain cycle; no proxy target is needed.

### Parallax

`TesseraParallaxLayer.effectiveOffset = contentOffset × factor` is the background offset in content coordinates. The layer sits next to the scroll view (in a shared superview), not inside it, so its screen projection is `transform = −backgroundOffset`: the background moves in the same direction as the content, but `factor` times slower. Consumers start the layer `padding` above/left of the viewport (a margin for rubber-banding at negative offsets); the whole travel of the background and a second margin lie below/right. The viewport stays covered for offsets in `[−padding/factor, max + padding/factor]`.

### Accessibility

- **`accessibilityScroll` direction.** By UIKit convention a three-finger swipe left pages forward: in LTR `.left` is +1 and `.right` is −1 (`TesseraAccessibility.pageStep`). In RTL the physical directions are mirrored; `.next` / `.previous` are expressed in reading order and are never mirrored. The mirroring in RTL is inferred by analogy and has not been confirmed on a device with VoiceOver. UIKit's header suggests posting `UIAccessibility.Notification.pageScrolled` after a successful `accessibilityScroll`; the components do not do this yet.
- **Page-change announcement.** The pager does not announce page changes. Core provides `TesseraAccessibility.announcePageChange(_:)`, and the host calls it (typically from `pager(_:didShowPageAt:)`), because only the host knows the text and can avoid double announcements.

### Hosting

`TesseraStateBridge` (an `ObservableObject` bridge in the hosting area) is no longer used by any component and is marked `@available(*, deprecated)`; it will be removed in the next major release. Observe the original `ObservableObject` directly with `@ObservedObject` / `@StateObject`.

## 4. Conceptual API surface

```
TesseraPagerViewController        pager (paged/snapping), child-VC container
TesseraPageDescriptor             id, title, content provider
TesseraContentProviding           UIViewController | UIHostingController
TesseraPagerDelegate              didShowPageAt, didChangeProgress(_ t:)
TesseraSnapPolicy                 snap configuration (velocity threshold, alignment)
TesseraParallaxLayer              background + factor + axis
TesseraGestureArbiter             child registration, axis decision
TesseraAccessibility / TesseraRTL utilities
```

Principles: delegate-driven communication, configuration structs for styling, all work on the main thread, no state smeared across modules.

## 5. Dependencies and structure

```
TesseraKit (Swift Package, iOS 15+, Swift 5.9, no external dependencies)
├── TesseraCore
│   ├── Pager (paged | snapping) + SnapPolicy
│   ├── Parallax
│   ├── Gesture (arbiter)
│   ├── Hosting (UIKit + SwiftUI content providers)
│   └── Accessibility (+ RTL)
├── TesseraPanorama ──┐
├── TesseraPivot ─────┼──► TesseraCore
└── TesseraStartScreen┘
```

- `TesseraKit` is one SPM package with four library products: `TesseraCore`, `TesseraPanorama`, `TesseraPivot`, `TesseraStartScreen`.
- Component targets depend only on `TesseraCore` and know nothing about each other.
- **API stability matters:** `TesseraCore` is a dependency of three libraries, so a breaking change hits all of them at once. Policy: semantic versioning, deprecation before removal, a minimal public surface.

## 6. Risks

- **Over-abstraction.** Core can swell into a framework for everything. Defence: the rule of three, and removing whatever two components do not use.
- **Leaking specifics.** Tile, strip and canvas vocabulary must not appear in Core, only pages, progress and layers.
- **Fragile updates.** Any change to Core regresses three libraries, so contract tests for progress, snapping and arbitration are mandatory at the Core level.

## 7. Summary

Core is four mechanics (pager, parallax, gesture arbitration, content hosting) plus accessibility utilities, extracted by the rule of three from Panorama, Pivot and StartScreen. It is thin, has no external dependencies and follows a strict API stability policy. That is what makes the components one ecosystem rather than three copies of the same solutions.
