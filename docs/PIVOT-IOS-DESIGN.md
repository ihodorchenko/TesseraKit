# TesseraPivot design

> Design document for the Pivot component: a Windows Phone style pivot for iOS.
> Constraints: **iOS 15+**, **Swift 5.9+**, UIKit and SwiftUI.
> Companion documents: [PANORAMA-IOS-DESIGN.md](PANORAMA-IOS-DESIGN.md), [STARTSCREEN-IOS-DESIGN.md](STARTSCREEN-IOS-DESIGN.md). Shared layer: [CORE-IOS-DESIGN.md](CORE-IOS-DESIGN.md) (`TesseraCore`).

## 0. What Pivot is and how it differs from Panorama

| Property | Panorama | Pivot |
|---|---|---|
| Section width | narrower than the screen (peek) | full screen width |
| Background | shared background with parallax | plain background, no parallax |
| Section headers | float over the content | a separate horizontal strip on top, interactive (tap = jump) |
| Snapping | custom | native `isPagingEnabled`, for free |
| Vertical scrolling | inside a section | inside a page (the header strip stays in place) |
| Large app title | no | yes, static above the strip |

The key feature of the Windows Phone Pivot is **two-way synchronization**: swipe the content and the highlight in the strip moves continuously; tap a header and the content jumps to that page. Nearly all the design work is about this synchronization.

## 1. Target UX properties

1. Full-screen pages with horizontal paging and native snapping.
2. **A header strip on top:** the active header is emphasized (accent color / weight) and inactive ones are muted; with many sections the strip scrolls horizontally on its own.
3. **The indicator / highlight moves continuously** with swipe progress instead of switching after the fact.
4. Tapping a header jumps straight to the page (without flying through intermediate pages), and the strip re-centers so that the active header is visible.
5. Vertical scrolling inside a page while the strip stays pinned.
6. A large static app title above the strip.

## 2. Foundation

A pleasant surprise: **snapping does not need to be designed at all.** Pages are full width, so `UIScrollView.isPagingEnabled = true` provides inertia, snapping and bounce for free. Panorama had to give up `isPagingEnabled` only because of the peek.

A UIKit core is still required because of the continuous strip synchronization:

- the swipe progress `t = offset.x / pageWidth` is available only from `scrollViewDidScroll`;
- `UIPageViewController` does not fit: it does not expose a continuous offset (its inner `UIScrollView` is a private detail and digging in the hierarchy is fragile), and its transitions are hard to customize;
- plain SwiftUI on iOS 15 (`TabView` with the `.page` style) gives paging but **no drag progress**, so the indicator could only jump after a swipe finishes rather than follow the finger.

Same conclusion as Panorama: **UIKit core, SwiftUI facade** (`TesseraPivotView: UIViewControllerRepresentable`).

## 3. Architecture

```
TesseraPivotView (SwiftUI facade)               declarative API
    └─ TesseraPivotViewController (UIKit)       orchestration, single source of truth
        ├─ app title label                      large app title (optional)
        ├─ TesseraPivotHeaderStripView          UICollectionView of headers + indicator
        └─ TesseraPagerViewController (Core)    UIScrollView, isPagingEnabled = true, child VC pages, lazy loading
```

The model mirrors Panorama:

- `TesseraPivotSection`: id, title and a content provider (`TesseraContentProviding`: a `UIViewController` factory or a SwiftUI view);
- `TesseraPivotStyle`: header font and colors, indicator style (`.underline`, `.accentText` or `.underlineAndText`), strip mode (`.content` for content width or `.fill` for equal widths), optional `appTitle`;
- `TesseraPivotDelegate`: `didSelectSectionAt`, `didChangeProgress(_ t:)` and an optional `didShowSectionAt`.

## 4. Core math

- **Progress:** `t = offset.x / pageWidth`, the same invariant as in Panorama; the integer part is the page index and the fractional part the transition progress.
- **Indicator:** the indicator center is a linear interpolation between the centers of neighbouring headers:

  ```
  indicatorCenter = lerp(center[i], center[i+1], frac(t))
  ```

- **An important subtlety (unlike Panorama):** in Panorama everything had equal width, so the indicator moved at constant speed. Here headers have **different widths** (they follow the text), so interpolation must happen between header centers rather than as `t × constWidth`; otherwise the indicator drifts away from the text mid-swipe.
- **Text coloring:** active and inactive colors are interpolated by the header's distance from `t` (the header closest to `t` is the most active). This gives the Windows Phone effect of smoothly handing over the accent.
- **Auto-centering of the strip:** `scrollToCenter` moves the strip only if it is overflowing and the header is fully or partly beyond the visible edge; for a strip that fits, any residual offset is reset to the start. On a width change (rotation) or a layout-direction change, the strip rebuilds its geometry and returns the selected header to the visible area without animation. `selectSection(at:animated: false)` does not animate the strip.

The performance rule from Panorama applies unchanged: in `scrollViewDidScroll` only `frame` / `transform` / `alpha`, no layout pass.

## 5. Strip and pager synchronization (the heart of the component)

Rule: **one source of truth and one writer.** The source is the pager's `contentOffset`; only the pager (the gesture) and the controller (a header tap) write to it.

- **Swipe → strip:** `scrollViewDidScroll` drives the indicator and the coloring (section 4). There is no write back, hence no loops.
- **Tap → pager:** the pager is moved with an animated `setContentOffset`. While it animates, the scroll delegate keeps firing on every frame, so **the strip animates by itself**; no separate indicator animation is needed. A `UICollectionView` separates tap from scroll natively, so the tap handler does not interfere with strip scrolling.
- **Snapping behaviour:** `isPagingEnabled` moves by one page per swipe, which is exactly the Windows Phone behaviour; no custom snapping is needed.
- **Interrupted transitions.** When a new animated transition interrupts a previous one, UIKit synchronously completes the old animation, and the Core pager reports `didShowPageAt` for the intermediate page. `TesseraPivotViewController` keeps a generation counter of programmatic transitions and drops shows that arrive during `go(toPage:animated:)` for anything but the target, as well as shows during `reload(sections:)`. The delegate therefore sees only real completions.
- **Far taps.** The Core pager jumps farther than ±1 through the target's neighbour (see [CORE-IOS-DESIGN.md](CORE-IOS-DESIGN.md)), so raw progress arrives with a jump. The strip is not put on the target in advance (that made the indicator flicker for a frame); it receives progress linearly remapped from the segment `[neighbour, target]` to `[source header, target]`, so the indicator travels continuously from the source header to the target during the single animated step, and intermediate headers are briefly highlighted on the way. The external delegate receives the raw pager progress (with the jump). The remapping is dropped on `didShowPageAt`, at the start of a pan, on `reload` and on the next `selectSection`. It is a progress transformation, not a separate animation.

## 6. Vertical scrolling inside a page

The same option B as Panorama, but simpler: the pager scrolls **only horizontally** and pages own the vertical axis. The header strip lives outside the pager, so it stays pinned vertically with no extra work.

**Axis arbitration.** `TesseraPagerViewController` does not expose its `UIScrollView`, so `TesseraPivotViewController` finds it by walking the direct subviews of the pager's root view. It then adds a target to the pager's pan recognizer (`addTarget`, without replacing the delegate) and decides on `.began` with `TesseraGestureArbiter.axisDecision(forVelocity:)`: for a horizontal axis it builds a `TesseraGestureArbiter` and blocks the vertical children (`prepareForHorizontalScroll()`), restoring them when the gesture ends (`endHorizontalScroll()`). Children register through the public `registerVerticalOwner(_:)` / `unregisterVerticalOwner(_:)`; references are weak and lazily unloaded pages drop out of the registry on their own. A public hook in Core (for instance a `horizontalScrollView` accessor) is a possible future improvement.

**When to register.** Only the current page receives appearance callbacks; the ±1 neighbours are loaded without `viewDidAppear`. Pages should therefore call `registerVerticalOwner(_:)` from `viewDidLoad`, not from `viewDidAppear`.

## 7. Performance

- Lazy loading of pages ±1 (as in Panorama).
- The strip is a regular reusable `UICollectionView`, scaling to hundreds of headers for free.
- The indicator is a separate `CALayer` / view driven by transforms only.
- Page prefetch so that an inertial swipe does not stall on lazy loading.

## 8. Accessibility and system integration

- **VoiceOver:** pages are paged with `UIAccessibilityScrollDirection.left/right`; headers in the strip are regular buttons (a tap works); the section name is announced on change (by the host).
- **Reduce Motion:** with `isReduceMotionEnabled` the jump on tap is not animated; the continuous indicator during a swipe stays (it follows the user's gesture and is not a self-driven animation).
- **Dynamic Type:** header fonts scale; the `fill` strip mode falls back to truncation or to content-width mode at large font sizes, otherwise the headers would run together.
- **RTL:** everything mirrors, both the header order and the swipe direction. `UICollectionViewFlowLayout` is not mirrored by default when RTL is set locally (`flipsHorizontallyInOppositeLayoutDirection == false`), and the collection does not inherit the strip's `semanticContentAttribute`, so the header order used to disagree with the pager's swipe direction. The strip therefore uses its own layout with the flag enabled (`developmentLayoutDirection = .leftToRight`) and forwards `semanticContentAttribute` to the collection. Application-wide RTL (double mirroring is excluded by the layout flag) has not been verified on a device.

## 9. Adaptivity

- **Rotation / iPad:** recompute `pageWidth` and `contentSize` and restore the page index; the strip rebuilds itself (it is a collection).
- **Many sections:** the strip scrolls and pages are lazy, so there are practically no limits.
- **One section / empty:** the strip is hidden when `sections.count <= 1`. `TesseraPivotDelegate` has no empty-state event and the controller draws no placeholder: with no sections, the large app title (if `TesseraPivotStyle.appTitle` is set) and an empty pager remain. The host detects the empty state from `sections` / `reload(sections:)` and shows its own state. Adding a delegate hook would be a breaking change to a public protocol.
- **App title:** a built-in static title inside the component (Windows Phone behaviour).
- **Content updates from SwiftUI.** When the set of ids or titles changes, `TesseraPivotView` calls `reload(sections:)` immediately. With the same ids and titles it hands the sections to the core on every update; at rest this is a `reload` that preserves the current page, controllers, scroll position and `@State` and refreshes the SwiftUI hosting `rootView` in place. During a gesture, inertia or an animated transition the update is deferred until the motion ends (a pager `reload` would cut the motion short). Progress that changed during `reload` is delivered to the delegate asynchronously (on the next main-queue pass) and only if it changed, never inside `updateUIViewController`. Updating content without stopping motion would need a public Core API.

## 10. Scope of the first release

**Included:**

1. A pager on `isPagingEnabled`.
2. A header strip with an indicator and continuous highlighting.
3. Tap navigation with strip auto-centering.
4. Vertical scrolling per page (option B).
5. Lazy loading ±1.
6. SwiftUI facade and UIKit API.
7. Accessibility (VoiceOver and Reduce Motion).

**Out of scope:** a looping / infinite strip (Windows Phone had a "wrap-around" effect, a debatable feature), custom page transitions, captions under the strip, iOS 17+ features.

## 11. Risks

- **Interpolation with different header widths** (section 4) is the likeliest source of visual bugs; it is addressed by tests on random header sets.
- **Animated `setContentOffset` plus the delegate** can produce a double animation; the single-writer rule prevents it.
- **iOS guidelines:** Pivot is much closer to native patterns (segmented control plus paging) than Panorama, so users understand it without instruction; the risk of cultural rejection is low.
- **`isPagingEnabled` is a black box:** it does not allow changing the deceleration speed or intercepting the snap as finely as in Panorama. That is acceptable for Pivot, but if "jump over several pages" on a fast swipe is ever wanted, the custom snapping from Panorama would have to return.

## 12. Summary

Pivot is noticeably cheaper than Panorama: free snapping, no background layer, and a tappable strip built on an ordinary `UICollectionView`. All the complexity sits in one place, the continuous synchronization of `contentOffset` and the indicator. The math (`t` and interpolation) is reused from Panorama almost verbatim.
