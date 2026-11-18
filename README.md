# TesseraKit

[![CI](https://github.com/ihodorchenko/TesseraKit/actions/workflows/ci.yml/badge.svg)](https://github.com/ihodorchenko/TesseraKit/actions/workflows/ci.yml)

TesseraKit is a Swift package of Windows Phone style UI components for iOS: a panorama, a pivot, and a full start
screen with live tiles, folders and an apps list. It has a UIKit core with SwiftUI facades, a shared pager and
parallax layer, first-class accessibility, and no third-party dependencies.

> TesseraKit is an independent project and is not affiliated with, endorsed by, or sponsored by Microsoft.
> Windows Phone and Windows 10 Mobile are trademarks of Microsoft Corporation.

## Requirements

- iOS 15 or later (Mac Catalyst 15 is declared for compatibility only)
- Swift 5.9 or later
- No external dependencies, only system frameworks

## Libraries

| Product | What it is |
|---|---|
| `TesseraCore` | The shared layer: a pager with `paged` and `snapping` modes, a parallax layer driven by one progress scalar, gesture arbitration, content hosting for UIKit and SwiftUI, and an accessibility kit. |
| `TesseraPanorama` | A panorama: a peeking next section, custom snapping, single-image background parallax, section headers interpolated by progress. |
| `TesseraPivot` | A pivot: a header strip synchronized with the pages, an indicator that follows progress across headers of different widths, vertical scrolling inside pages, a larger strip mode for big Dynamic Type sizes. |
| `TesseraStartScreen` | A start screen: a grid of live tiles in four sizes, edit mode, folders with drag and drop, an apps list with a jump list, an optional hook page, and persistence through `TesseraTileStore`. |

`TesseraPanorama`, `TesseraPivot` and `TesseraStartScreen` depend only on `TesseraCore`, never on each other.

## Installation

Add the package with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/ihodorchenko/TesseraKit.git", from: "1.0.0")
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "TesseraPanorama", package: "TesseraKit"),
            .product(name: "TesseraPivot", package: "TesseraKit"),
            .product(name: "TesseraStartScreen", package: "TesseraKit"),
            // .product(name: "TesseraCore", package: "TesseraKit"),
        ]
    )
]
```

In Xcode use File > Add Package Dependencies and enter the repository URL.

## Quick start

### Panorama

```swift
import SwiftUI
import TesseraCore
import TesseraPanorama

struct PanoramaScreen: View {
    var body: some View {
        TesseraPanoramaView(sections: [
            TesseraPanoramaSection(id: "news", title: "news",
                                   content: TesseraSwiftUIContentProvider { Text("News") }),
            TesseraPanoramaSection(id: "photos", title: "photos") { UIViewController() },
        ])
    }
}
```

### Pivot

```swift
import SwiftUI
import TesseraCore
import TesseraPivot

struct PivotScreen: View {
    var body: some View {
        TesseraPivotView(sections: [
            TesseraPivotSection(id: "all", title: "all",
                                content: TesseraSwiftUIContentProvider { Text("All") }),
            TesseraPivotSection(id: "unread", title: "unread",
                                content: TesseraSwiftUIContentProvider { Text("Unread") }),
        ])
    }
}
```

Both components also ship as UIKit view controllers (`TesseraPanoramaViewController`,
`TesseraPivotViewController`).

### Start screen

```swift
import SwiftUI
import TesseraStartScreen

struct StartScreen: View {
    @StateObject private var store: TesseraTileStore = {
        let store = TesseraTileStore()                    // persists to Application Support
        store.setCatalog([
            TesseraTileDescriptor(id: "mail", title: "Mail", action: { print("open mail") }),
            TesseraTileDescriptor(id: "weather", title: "Weather", action: { }, size: .wide),
        ])
        try? store.load()                                 // restore the saved layout
        _ = store.placeItems(columns: 6)                  // lay out first-launch tiles
        return store
    }()

    var body: some View {
        TesseraStartScreenView(snapshot: store.snapshot(columns: 6))
    }
}
```

The store is an `ObservableObject`: the view re-renders when tiles change. The full screen is also available
as `TesseraStartScreenViewController`. See the Example app for live tiles, the apps list, the hook page and
folder handling.

## Accessibility, RTL and Reduce Motion

Accessibility is part of every component, not an option:

- **VoiceOver**: page scrolling, announcements on section changes, and custom actions on tiles (unpin, resize,
  rename, move earlier or later, add to or take out of a folder). Reading order follows grid cells.
- **Reduce Motion**: parallax, live tile flips and the optional jiggle are disabled.
- **Dynamic Type**: the pivot header strip switches to a larger mode.
- **Right-to-left**: the pager normalizes progress by reading direction, and the grid and lists mirror.

Built-in strings are localized in English and Russian.

## Example app

`Example/TesseraKitExample/TesseraKitExample.xcodeproj` is a host app with a tab per component, including a
full start screen. Open the project in Xcode, choose an iOS Simulator and run the `TesseraKitExample` scheme.

## Building and testing

```bash
swift build --triple arm64-apple-ios15.0-simulator
xcodebuild test -scheme TesseraKit-Package -destination 'platform=iOS Simulator,name=<an available iPhone>'
```

The package targets iOS: a plain `swift build` or `swift test` on a macOS host does not compile or run the
UIKit code. Pick a simulator name from `xcrun simctl list devices available`.

## Documentation

- [Core design](docs/CORE-IOS-DESIGN.md)
- [Panorama design](docs/PANORAMA-IOS-DESIGN.md)
- [Pivot design](docs/PIVOT-IOS-DESIGN.md)
- [Start screen design](docs/STARTSCREEN-IOS-DESIGN.md)
- [Windows 10 Mobile start screen reference](docs/W10M-STARTSCREEN.md) and
  [conformance review](docs/W10M-CONFORMANCE.md)
- [Decision log](docs/DECISIONS.md), [risk register](docs/RISKS.md), [manual testing checklist](docs/MANUAL-TESTING.md)
- [Changelog](CHANGELOG.md)

## Status and API stability

The project is feature complete for 1.0.0. The test suite has 1243 tests as of the last full run; see CI for
the current state.

TesseraKit follows [Semantic Versioning](https://semver.org/). From 1.0.0 the public API of `TesseraCore`
changes only through deprecation; all public top-level types carry the `Tessera` prefix.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow and [SECURITY.md](SECURITY.md) to report a vulnerability.
AI agents and contributors working on the code should also read [AGENTS.md](AGENTS.md).

## License

MIT. See [LICENSE](LICENSE).
