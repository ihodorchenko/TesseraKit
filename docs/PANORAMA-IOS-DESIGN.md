# TesseraPanorama design

> Design document for the Panorama component: a Windows Phone style panorama for iOS.
> Constraints: **iOS 15+**, **Swift 5.9+**, UIKit and SwiftUI. Shared layer: [CORE-IOS-DESIGN.md](CORE-IOS-DESIGN.md) (`TesseraCore`).

## 0. What is being reproduced

Windows Phone had two related controls:

- **Pivot**: tabs with a thin header, paging between pages;
- **Panorama**: a full-screen background with parallax, section "canvases" wider than the screen, section headers, and a peek of the next section at the right edge.

This document covers **Panorama**. Almost everything also applies to Pivot, which simply turns off parallax and peek (see [PIVOT-IOS-DESIGN.md](PIVOT-IOS-DESIGN.md)).

## 1. Target UX properties

The component must provide:

1. **Horizontal paging of sections** with inertia and snapping to a section.
2. **Peek**: a sliver of the next section is visible at the right edge (on Windows Phone a section did not fill the whole screen width).
3. **Background parallax**: the background image is wider than the screen and moves slower than the content; the farther the section, the "deeper" it feels.
4. **Vertical scrolling inside a section** when its content is taller than the screen.
5. **Section headers** that move and fade with animations bound to swipe progress.
6. Good gesture ergonomics: an elastic swipe that can be caught at any speed and does not conflict with inner scroll views or navigation.

**Main invariant:** everything in the component is a function of one scalar,

```
t = contentOffset.x / itemWidth
```

the global swipe progress. Every element (background, headers, sections) is a mapping `t → transform`. As long as the invariant holds, the component is predictable.

## 2. Foundation: UIKit or SwiftUI (iOS 15)

iOS 15 limits:

- no `scrollTargetBehavior` / `scrollTargetLayout` (iOS 17+);
- no `@Observable` (iOS 17+);
- in plain SwiftUI, `contentOffset` is reachable only through a `GeometryReader` and a named coordinate space.

**Conclusion:**

- **The scrolling and parallax core is UIKit.** `UIScrollView` provides a real `contentOffset`, `targetContentOffset(forProposedContentOffset:withScrollingVelocity:)` for custom snapping, and `scrollViewDidScroll` to drive parallax without hacks.
- **The external API has two facades:** a native UIKit container (`TesseraPanoramaViewController`) and a SwiftUI wrapper (`TesseraPanoramaView: UIViewControllerRepresentable`), both on top of the same core.

Plain SwiftUI on iOS 15 is possible (a `TabView` with the `.page` style plus `GeometryReader` parallax), but controlling snapping, velocity and the synchronization of vertical scrolling becomes a fight with the framework. Hence: **UIKit core, SwiftUI facade**.

## 3. Architecture

Three layers:

```
TesseraPanoramaView (SwiftUI facade)           declarative API
    └─ TesseraPanoramaViewController (UIKit)   orchestration, scroll delegate, snapping
        ├─ TesseraPanoScrollView               UIScrollView with custom deceleration
        ├─ background layer                    parallax transform (TesseraParallaxLayer from Core)
        ├─ TesseraPanoHeaderView               section headers animated by t
        └─ section containers                  child VC per section, lazy loading
```

The data model is an array of sections that are loaded lazily, so that not every section has to stay in memory:

- `TesseraPanoramaSection`: id, title and a content provider (`TesseraContentProviding`: a `UIViewController` factory or a SwiftUI view);
- `TesseraPanoramaStyle`: peek, parallax factor, header font and colors, background behaviour, `contentInsetAdjustmentBehavior`;
- `TesseraPanoramaDelegate`: `didShowSectionAt` and `didChangeProgress(_ t:)`.

## 4. Geometry and core math

- **Section width:** `itemWidth = screenWidth − peek`, where `peek ≈ 16–64 pt` (configurable). On Windows Phone a canvas was roughly 80–90% of the screen width.
- **Global progress:** `t = offset.x / itemWidth`. The integer part is the current section index, the fractional part is its show progress.
- **Background parallax:** `backgroundOffset = offset.x × parallaxFactor`, with `0 < parallaxFactor < 1` (typically 0.4–0.6). The background is an image that is always wider than `contentSize`, so no edges show at any `t`. The implementation uses only `frame.origin` / `transform`, no layout pass.
  - The layer is a sibling of the scroll view, not a subview, so its on-screen transform is `−backgroundOffset`: the background moves left together with the sections, but slower.
  - The layer starts `padding` to the left of the viewport (room for rubber-banding before the first section); the whole background travel (`maximumOffsetX × factor`) and the right-hand margin lie to the right. The viewport stays covered for offsets in `[−padding/factor, maximumOffsetX + padding/factor]`.
  - `parallaxFactor` is clamped to the open interval `(0, 1)`, represented as `0.01...0.99`; non-finite values fall back to 0.5. The typical 0.4–0.6 range is a recommendation, not a bound. So that rubber-banding never exposes the edges at high factors, the background margin grows with the factor: `padding = max(96, 0.35 × width, 0.6 × width × factor)`.
- **Snapping:** `isPagingEnabled` does not fit (it only supports screen-wide pages), so:
  - `decelerationRate = .fast`;
  - `targetContentOffset(forProposedContentOffset:withScrollingVelocity:)` finds the nearest section center, or the next/previous section on a fast swipe;
  - `UIScrollView` reports velocity in points/ms, while the policy threshold (`TesseraSnapPolicy.velocityThreshold`, default 600) is in points/s, so `TesseraPanoScrollView` multiplies by 1000;
  - the offset at the start of the drag is passed to the policy as `startOffset`, so a fast flick moves exactly one section from where it began (without unit conversion a short fast flick rolled back; without the start anchor it skipped a section);
  - at the boundaries the standard bounce provides the rubber band.
- **Drag without inertia.** With zero velocity UIKit ignores a modified `targetContentOffset`. `TesseraPanoScrollView` remembers the policy's target from `scrollViewWillEndDragging`; when `decelerate == false`, the controller (as the programmatic offset writer) animates the offset to that target (or to the nearest section if there is none) and reports the shown section only in `scrollViewDidEndScrollingAnimation`. With Reduce Motion the settling is instant.
- **Headers:** for each section the transform and alpha are a function of the fractional part of `t`, ideally piecewise-linear interpolation between keyframes (0, 0.5, 1) rather than a hard switch. The title color is interpolated too: `lerp(headerColor, headerActiveColor, w)` with `w = max(0, 1 − |i − t|)`, the same piecewise-linear phase as the alpha. It is implemented as an accent copy of the label inside the main one whose alpha carries the weight, so `scrollViewDidScroll` still changes only `alpha` / `transform`. With `headerActiveColor == headerColor` no copy is created. The default `headerActiveColor` is `.systemBlue`.

**Performance rule:** no layout pass while scrolling, only `frame` / `transform` / `alpha`. Autolayout of sections runs once at creation.

## 5. Vertical scrolling inside a section

The trickiest part. Two options:

**Option A, "one two-dimensional scroll"** (like the canvas tilt on Windows Phone): one `UIScrollView` with `contentSize = (sections × itemWidth, maxSectionHeight)`; all content lives in nested containers inside one tiled field.

- Pros: a diagonal swipe "just works", and the vertical position is shared and survives paging.
- Cons: nested `UITableView` / `UICollectionView` with cell reuse do not fit; sections would have to be rendered whole and a custom recycling scheme invented.

**Option B, "a section is its own vertical scroll" (chosen):** each section is a child view controller with its own `UIScrollView` / `UICollectionView`.

- The parent handles horizontal swipes and the child handles vertical ones; the direction is decided by gesture velocity (see below).
- Pros: regular `UITableView` / `UICollectionView` / `ScrollView` with all their optimizations; each section's vertical position is preserved because the child VC stays in memory.

**Where the axis decision is made.** `TesseraPanoScrollView` is its own delegate and keeps `isDirectionalLockEnabled = true`. `TesseraPanoramaViewController` adds a target to its pan recognizer (`addTarget`) and decides on `.began` using `TesseraGestureArbiter.axisDecision(forVelocity:)` (by `translation` when velocity is zero). For a horizontal axis it builds a `TesseraGestureArbiter` and blocks the children's scrolling via `prepareForHorizontalScroll()`, restoring it with `endHorizontalScroll()` when the gesture ends; for a vertical axis the children are not blocked. Children register with `registerVerticalOwner(_:)` / `unregisterVerticalOwner(_:)` (weak references). The pan recognizer's delegate is never replaced, so the scroll view keeps its own handling of simultaneous gestures. See [CORE-IOS-DESIGN.md](CORE-IOS-DESIGN.md), "Gesture arbitration".

## 6. Performance

- **Lazy loading:** the current section and its neighbours (±1) are in memory; others are created as they approach.
- **No layout in `scrollViewDidScroll`**, only transforms (see section 4).
- **Background:** one `UIImageView` for the whole layer; the image is decoded at screen scale (not a gigabyte original), optionally with a light blur on top for header legibility. Background memory is accounted separately from sections.
- **SwiftUI sections:** `UIHostingController` is not recreated on every state update.
  - `reload(sections:)` reuses the controllers of sections whose `id` survived in the new ±1 window (vertical position and `@State` are preserved), like the Core pager.
  - With unchanged `id`s and titles, `TesseraPanoramaView` delivers new content to already loaded sections in place (a new `rootView`, the same controller), without stopping the scroll or resetting the shown section. For UIKit providers the controller instance is kept and the host must update it.
  - Assigning an equivalent style (all fields equal, the same background image instance) does nothing.
- **Programmatic jumps** farther than a neighbour are direct: the ±1 window is loaded around the target, the offset is set without animation on the target's neighbour, and one step is animated. The delegate sees a single progress jump and `didShowSectionAt` only for the target.

## 7. Accessibility and system integration

- **VoiceOver:** the whole component is one accessibility page navigated with `UIAccessibilityScrollDirection.left/right` (three-finger swipe); inside sections the hierarchy is regular; the section title is announced on change. The announcement is the host's responsibility (see Core). The header layer is a separate accessibility element with the `.header` trait, and VoiceOver focus can rest on it; its `accessibilityScroll(_:)` forwards the swipe to the controller, which turns the direction into a section step and writes `contentOffset` itself, so paging from the header and from the section content behaves identically.
- **Reduce Motion:** with `isReduceMotionEnabled`, parallax and header animations are off; plain snapping remains.
- **Dynamic Type:** headers use text styles with scaling; check that headers are not cut off at large sizes (the peek can stay).
- **RTL:** `t` and the snap direction follow the reading direction (in RTL the "next section" is on the left).

## 8. Adaptivity and lifecycle

- **Rotation / iPad / split view:** on a geometry change (view width and height, reading direction, `peek`) the current section is restored by index and fraction. The fraction is taken in the previous slot direction and previous section width; otherwise a LTR↔RTL switch would open the mirrored section, and a `peek` change would leave the section between snap points. The root view's reading direction (`semanticContentAttribute` or the trait environment) is propagated to the strip and the header layer, since `semanticContentAttribute` is not inherited by subviews. Writing the frame, `contentSize` and offset in a layout pass does not emit `didChangeProgress`; a layout deferred during a gesture is applied when inertia ends.
- **Empty list / single section:** the delegate has no empty-state event and the controller does not draw a placeholder. With no sections only the background remains (the background layer is stretched to at least the viewport), headers are hidden and nothing scrolls. The host detects the empty state from `sections` after `reload(sections:)` and shows its own placeholder.
- **Many sections:** lazy loading is mandatory, otherwise memory is O(n).
- **Navigation bar:** the component works well under a large title; a true full-screen background needs a transparent bar or an inset. The style carries `contentInsetAdjustmentBehavior` (default `.never`), applied to the section strip; the background lies under the bar for the full height of the view. Snapping and progress are computed from `contentOffset` without horizontal `adjustedContentInset`, so values that produce side insets (`.always`, and in landscape with a notch also `.automatic` / `.scrollableAxes`) shift the strip by the side safe-area width. `.never` is recommended for a full-screen panorama.

## 9. Scope of the first release

**Included:**

1. UIKit core: horizontal scroll, custom snapping, peek.
2. Background parallax (one image, a factor).
3. Section headers interpolated by `t`.
4. Vertical scrolling by option B.
5. SwiftUI facade and UIKit API.
6. Accessibility (VoiceOver and Reduce Motion).

**Out of scope:** an arbitrary background per section (on Windows Phone the background was shared), canvas tilt, iOS 17+ features, complex recycling (sections with ±1 neighbours suffice for the typical 3–7 sections).

## 10. Risks

- **iOS guidelines:** Panorama is alien to iOS patterns; iOS users are used to `UIPageViewController` / `TabView(.page)`. The component should be an optional style, not a replacement for navigation.
- **Gesture conflicts** (option B) are the likeliest source of bugs: edge cases with an inner `UICollectionView`, bounce, and elasticity at the seam.
- **SwiftUI sections on iOS 15:** each `UIHostingController` has its own layout cycle; fast swipes may drop frames if sections are heavy.
- **Resilience to future iOS versions:** the component relies only on public `UIScrollView` API, so the risk is low.

## Appendix A. UIScreenEdgePanGestureRecognizer

- **As the main gesture it does not simplify anything.** It loses the free capabilities of `UIScrollView` (inertia, bounce, snapping via `targetContentOffset`, `contentOffset` as the source of truth, `accessibilityScroll`) and breaks the swipe "anywhere on the canvas" that is the essence of a panorama. It also conflicts with the system back gesture on the left edge and delays child scroll views near the edge (an edge pan stays in the "possible" state for a long time).
- **As an auxiliary gesture it is useful in one scenario:** a section that scrolls horizontally itself (a map, a gallery). The content owns the whole area while the screen edge always switches sections, so no direction conflict arises.
- **Decision:** the main gesture is the native `UIScrollView` pan; an edge pan would be an optional plugin that drives the same `contentOffset` (a spring animator), not a second engine. Inside a `UINavigationController` the left edge belongs to the system and the edge pan goes on the right (reversed in RTL). The plugin is not implemented.
