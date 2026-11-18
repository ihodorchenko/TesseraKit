# AGENTS.md

A short guide for AI agents and contributors. Read it and the relevant document in `docs/` before changing code.

## Project

TesseraKit is one Swift package with four libraries: Windows Phone style UI components for iOS.

- `Sources/TesseraCore`: pager, parallax, gesture arbitration, content hosting, accessibility.
- `Sources/TesseraPanorama`, `Sources/TesseraPivot`: the panorama and pivot components.
- `Sources/TesseraStartScreen`: tile grid, live tiles, folders, apps list, `TesseraTileStore`.
- `Tests/<Target>Tests`: XCTest suites. `Example/`: a host app for manual checks.
- `docs/`: design documents, decision log, risk register, manual testing checklist.

## Hard constraints

- iOS 15+, Swift 5.9, `swift-tools-version: 5.9`. No API newer than iOS 15: no `@Observable`,
  `scrollTargetBehavior`, `@Entry` and similar.
- UIKit core with SwiftUI facades (`UIViewControllerRepresentable`).
- No external dependencies, system frameworks only.
- No `.xcodeproj` files except the Example host (`Example/TesseraKitExample`).

## Key contracts

1. **Progress invariant**: everything animates from one scalar `t = contentOffset.x / pageWidth`; in RTL `t` is
   normalized by reading direction.
2. **Single writer of `contentOffset`**: only the pager (gesture) and the controller (programmatic transitions).
   Subscribers only read; do not create write-back loops.
3. **Two pager modes**: `paged` (full-page pages) and `snapping` (custom snap through
   `targetContentOffset(forProposedContentOffset:withScrollingVelocity:)`).
4. **Gesture arbitration**: horizontal goes to the pager, vertical to the child, decided by the dominant axis
   in `gestureRecognizerShouldBegin`.
5. **Performance discipline**: `scrollViewDidScroll` only touches `frame`, `transform` and `alpha`; no layout.
6. **Reduce Motion**: parallax, flips and the jiggle are disabled when it is on (the jiggle is also a host
   option, off by default).
7. **Rule of three**: a mechanism goes into `TesseraCore` only if at least two components need it.
8. **API stability**: `TesseraCore` is a dependency of the other libraries; change its public surface only
   through deprecation. Every public top-level type has the `Tessera` prefix; nested types do not need it.

## StartScreen model

- A top-level item's position is an explicit cell (`row`, `column`), not an index. There is no index-based
  public API; reading order is derived from cells.
- `TesseraTileStore` operations take the grid width `columns`. Holes are kept; only an empty row collapses,
  and only on drop.
- A folder never holds fewer than two tiles. Persistence is `tiles.json`, schema version 2.

## Build and test

```bash
swift build --triple arm64-apple-ios15.0-simulator
xcodebuild test -scheme TesseraKit-Package -destination 'platform=iOS Simulator,name=<an available iPhone>'
```

`swift test` does not run UIKit code on a macOS host; use `xcodebuild` with a simulator.

## Tests and accessibility

- Add tests under `Tests/<Target>Tests`. Core contract tests (progress, snap, arbitration) are mandatory.
- Accessibility (VoiceOver, Reduce Motion, Dynamic Type, RTL) is part of every component.
- An architecture change updates the matching document in `docs/`; record notable decisions in
  `docs/DECISIONS.md` and risks in `docs/RISKS.md`.

## Commits and pull requests

English messages, small focused pull requests, `main` changes only through a pull request.

## Links

[README](README.md), [CONTRIBUTING](CONTRIBUTING.md), [docs/DECISIONS.md](docs/DECISIONS.md),
[docs/CORE-IOS-DESIGN.md](docs/CORE-IOS-DESIGN.md), [docs/STARTSCREEN-IOS-DESIGN.md](docs/STARTSCREEN-IOS-DESIGN.md),
[docs/MANUAL-TESTING.md](docs/MANUAL-TESTING.md).
