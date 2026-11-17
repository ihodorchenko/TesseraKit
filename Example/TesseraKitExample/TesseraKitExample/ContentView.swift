//
//  ContentView.swift
//  TesseraKitExample
//
//  Demo host for the TesseraKit libraries, for manual testing in the iOS Simulator.
//
//  Compatibility: iOS 15+, Swift 5.9. Only APIs no newer than iOS 15 are used:
//  ObservableObject/@Published instead of @Observable, foregroundColor instead of
//  foregroundStyle, classic .overlay/.background modifiers, and so on.
//
//  Tabs:
//  1. "Desktop"  - TesseraTileStore + TesseraTileGridView + TesseraTileEditCoordinator
//                   in a UIViewControllerRepresentable (edit mode).
//  2. "Start"    - the full TesseraStartScreenViewController (hook page, START, apps list,
//                   parallax, edit mode and folders).
//  3. "Pivot"    - TesseraPivotView with four sections and a large title.
//  4. "Panorama" - TesseraPanoramaView with three sections and a generated background.
//  5. "Core"     - two TesseraPagerViewController instances (.paged and .snapping) and
//                   programmatic transitions go(toPage:animated:).
//

import Foundation
import SwiftUI
import UIKit
import Combine
import TesseraCore
import TesseraPanorama
import TesseraPivot
import TesseraStartScreen

// MARK: - Root screen

struct ContentView: View {
    var body: some View {
        TabView {
            DeskDemoView()
                .tabItem {
                    Label("Desktop", systemImage: "square.grid.2x2.fill")
                }

            StartDemoView()
                .tabItem {
                    Label("Start", systemImage: "rectangle.grid.2x2")
                }

            PivotDemoView()
                .tabItem {
                    Label("Pivot", systemImage: "rectangle.split.3x1.fill")
                }

            PanoramaDemoView()
                .tabItem {
                    Label("Panorama", systemImage: "rectangle.on.rectangle")
                }

            CorePagerDemoView()
                .tabItem {
                    Label("Core", systemImage: "arrow.left.and.right")
                }
        }
    }
}

// MARK: - Shared demo elements

/// A simple message for a demo action's alert.
struct DemoAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// A capsule demo button: one style for all tabs.
struct DemoCapsuleButtonStyle: ButtonStyle {
    var tint: Color = .blue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundColor(.white)
            .background(tint.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(Capsule())
    }
}

/// Generated images: the demo uses no external resources.
enum DemoVisuals {

    /// The panorama background: a gradient with translucent circles.
    ///
    /// Created once and passed to `TesseraPanoramaStyle` as a stable
    /// instance: the facade compares wallpapers by reference and does not reassign them on
    /// every SwiftUI redraw.
    static let panoramaBackground: UIImage = makePanoramaBackground()

    /// An SF Symbol in a given color for a tile icon.
    static func symbol(_ name: String, tint: UIColor) -> UIImage? {
        UIImage(systemName: name)?
            .withTintColor(tint, renderingMode: .alwaysOriginal)
    }

    private static func makePanoramaBackground() -> UIImage {
        let size = CGSize(width: 1024, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            let context = rendererContext.cgContext

            let colors: [CGColor] = [
                UIColor(red: 0.08, green: 0.10, blue: 0.28, alpha: 1).cgColor,
                UIColor(red: 0.30, green: 0.10, blue: 0.42, alpha: 1).cgColor,
                UIColor(red: 0.04, green: 0.36, blue: 0.44, alpha: 1).cgColor,
            ]

            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: [0, 0.55, 1]
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }

            context.setFillColor(UIColor.white.withAlphaComponent(0.07).cgColor)
            context.fillEllipse(in: CGRect(x: -120, y: 80, width: 620, height: 620))
            context.fillEllipse(in: CGRect(x: 620, y: 300, width: 520, height: 520))
            context.fillEllipse(in: CGRect(x: 260, y: 700, width: 420, height: 420))

            context.setStrokeColor(UIColor.white.withAlphaComponent(0.18).cgColor)
            context.setLineWidth(2)
            context.move(to: CGPoint(x: 0, y: 760))
            context.addCurve(
                to: CGPoint(x: size.width, y: 640),
                control1: CGPoint(x: 320, y: 700),
                control2: CGPoint(x: 720, y: 760)
            )
            context.strokePath()
        }
    }
}

// MARK: - "Desktop" tab

struct DeskDemoView: View {
    @StateObject private var model = DemoDeskModel()
    @Environment(\.sizeCategory) private var sizeCategory

    /// The height of the floating hint/button block: the grid reserves
    /// a bottom margin for it so that the last row of tiles does not end up under it.
    @State private var overlayHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            DemoDeskRepresentable(
                model: model,
                isEditing: model.isEditing,
                bottomReserve: overlayHeight
            )

            VStack(alignment: .trailing, spacing: 10) {
                // At accessibility sizes the hint is not shown:
                // large text turned it into a block over the grid.
                if !sizeCategory.isAccessibilityCategory {
                    Text(
                        model.isEditing
                            ? "Drag a tile, resize it, or unpin it"
                            : "Long-press a tile to enter edit mode"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(UIColor.secondarySystemBackground))
                    .clipShape(Capsule())
                }

                Button {
                    model.isEditing.toggle()
                } label: {
                    Label(
                        model.isEditing ? "Done" : "Edit",
                        systemImage: model.isEditing ? "checkmark.circle.fill" : "square.and.pencil"
                    )
                }
                .buttonStyle(DemoCapsuleButtonStyle(tint: model.isEditing ? .green : .blue))
            }
            .padding(16)
            // The button does not grow beyond xxxLarge, otherwise at accessibility
            // sizes it takes half the screen over the grid.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: DemoDeskOverlayHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .onPreferenceChange(DemoDeskOverlayHeightKey.self) { overlayHeight = $0 }
        .alert(item: $model.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

/// The height of the floating hint/button block of the "Desktop" tab.
private struct DemoDeskOverlayHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A SwiftUI → UIKit bridge for the start screen desktop.
///
/// The `TesseraStartScreenView` facade is not used in this tab: it does not expose
/// `TesseraTileEditCoordinator`, while manual testing must show edit mode.
/// So the allowed public UIKit layer is assembled directly: grid + store +
/// the edit coordinator.
struct DemoDeskRepresentable: UIViewControllerRepresentable {
    let model: DemoDeskModel
    let isEditing: Bool
    /// The height of the floating block over the grid: the bottom margin.
    let bottomReserve: CGFloat

    func makeUIViewController(context: Context) -> DemoDeskHostController {
        DemoDeskHostController(model: model)
    }

    func updateUIViewController(_ uiViewController: DemoDeskHostController, context: Context) {
        uiViewController.bottomReserve = bottomReserve
        uiViewController.applyEditingState(isEditing)
    }
}

/// The "Desktop" tab model: a tile catalog, a folder, and a live tile.
final class DemoDeskModel: ObservableObject {
    let store: TesseraTileStore

    @Published var isEditing = false
    @Published var alert: DemoAlert?

    private let liveTileProvider = DemoLiveTileProvider()

    init() {
        // A separate temporary directory per launch: the demo always starts in
        // the same state and does not depend on edits from a previous session.
        // To test TesseraTileStore persistence, the directory can be replaced with
        // TesseraTileStore.defaultDirectoryURL().
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TesseraKitExample", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = TesseraTileStore(directoryURL: directory)

        // The catalog is registered before load(): actions and icons are the runtime part
        // of a tile and are not serialized to JSON.
        store.setCatalog(makeCatalog())
        try? store.load()
        seedFolderIfNeeded()
    }

    deinit {
        store.onChange = nil
    }

    /// The four D15 sizes, D12 badges, one folder, and one live tile.
    private func makeCatalog() -> [TesseraTileDescriptor] {
        [
            TesseraTileDescriptor(
                id: "mail",
                title: "Mail",
                icon: DemoVisuals.symbol("envelope.fill", tint: .systemBlue),
                action: makeAction(for: "Mail"),
                badge: .count(3),
                size: .small
            ),
            TesseraTileDescriptor(
                id: "calendar",
                title: "Calendar",
                icon: DemoVisuals.symbol("calendar", tint: .systemRed),
                action: makeAction(for: "Calendar"),
                badge: .dot,
                size: .medium
            ),
            TesseraTileDescriptor(
                id: "weather",
                title: "Weather",
                icon: DemoVisuals.symbol("cloud.sun.fill", tint: .systemTeal),
                action: makeAction(for: "Weather"),
                size: .wide,
                liveContent: liveTileProvider
            ),
            TesseraTileDescriptor(
                id: "notes",
                title: "Notes",
                icon: DemoVisuals.symbol("note.text", tint: .systemYellow),
                action: makeAction(for: "Notes"),
                size: .small
            ),
            TesseraTileDescriptor(
                id: "photos",
                title: "Photos",
                icon: DemoVisuals.symbol("photo.fill", tint: .systemGreen),
                action: makeAction(for: "Photos"),
                size: .small
            ),
            TesseraTileDescriptor(
                id: "music",
                title: "Music",
                icon: DemoVisuals.symbol("music.note", tint: .systemPink),
                action: makeAction(for: "Music"),
                badge: .count(5),
                size: .large
            ),
            TesseraTileDescriptor(
                id: "settings",
                title: "Settings",
                icon: DemoVisuals.symbol("gearshape.fill", tint: .systemGray),
                action: makeAction(for: "Settings"),
                badge: .dot,
                size: .small
            ),
        ]
    }

    /// The whole catalog is registered, so on first launch the tiles
    /// automatically land on the grid. The folder is created through the public
    /// D14 approval (by default `TesseraTileStore.approval` allows everything).
    /// Store operations are cell-based; the grid width is known only
    /// after the view is created, so the seed uses the D26 default (6 columns),
    /// like the Example grid.
    private func seedFolderIfNeeded() {
        guard store.snapshot().folders.isEmpty else { return }
        let columns = TesseraTileLayoutEngine.defaultColumns

        if !store.isPinned("notes") {
            store.pinTile("notes", columns: columns)
        }

        guard let folder = store.createFolder(withTile: "notes", title: "Work", columns: columns) else {
            return
        }

        if !store.isPinned("photos") {
            store.pinTile("photos", columns: columns)
        }
        store.addToFolder("photos", folderID: folder.id, columns: columns)
        store.collapseEmptyRows(columns: columns)
    }

    /// A tile action: printing to the console and an alert. D12: the action is invoked by the host,
    /// not by the grid.
    private func makeAction(for title: String) -> () -> Void {
        { [weak self] in
            print("[TesseraKitExample] Tap shortcut: \(title)")
            self?.alert = DemoAlert(
                title: title,
                message: "Demo tile action: \(title)."
            )
        }
    }
}

/// The live provider of the "Weather" tile: two sides and a subscription to updates.
final class DemoLiveTileProvider: NSObject, TesseraLiveTileContentProvider {
    private var updateCount = 0
    private var timer: Timer?

    deinit {
        timer?.invalidate()
    }

    var frontFace: TesseraLiveTileFace {
        TesseraLiveTileFace(
            title: "Weather",
            detail: "Minsk",
            icon: UIImage(systemName: "cloud.sun.fill"),
            backgroundColor: .systemTeal,
            foregroundColor: .white
        )
    }

    var backFace: TesseraLiveTileFace? {
        TesseraLiveTileFace(
            title: "\(18 + updateCount % 5)°",
            detail: updateCount == 0 ? "Clear" : "Update \(updateCount)",
            icon: UIImage(systemName: "sun.max.fill"),
            backgroundColor: .systemIndigo,
            foregroundColor: .white
        )
    }

    func startObservingChanges(_ onChange: @escaping () -> Void) -> (() -> Void)? {
        let timer = Timer(timeInterval: 12, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateCount += 1
            onChange()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer?.invalidate()
        self.timer = timer

        return { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }
}

/// The start screen UIKit container: the grid, the edit coordinator, and
/// forwarding of tile actions to the demo model.
final class DemoDeskHostController: UIViewController, TesseraTileEditCoordinatorDelegate {
    private let model: DemoDeskModel
    private let store: TesseraTileStore
    private let gridView = TesseraTileGridView()
    private var editCoordinator: TesseraTileEditCoordinator?

    /// The height of the SwiftUI layer's floating hint/button.
    var bottomReserve: CGFloat = 124 {
        didSet {
            guard bottomReserve != oldValue, isViewLoaded else { return }
            updateGridInsets()
        }
    }

    init(model: DemoDeskModel) {
        self.model = model
        self.store = model.store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground

        gridView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gridView)
        NSLayoutConstraint.activate([
            gridView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gridView.topAnchor.constraint(equalTo: view.topAnchor),
            gridView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // A snapshot with a table of explicit cells: the grid shows the model's holes.
        gridView.reload(snapshot: store.snapshot(columns: gridView.columns))
        gridView.onTap = { [weak self] item in
            self?.handleTap(item)
        }

        // The host is a typical TesseraTileStore subscriber: it applies the snapshot after every
        // edit (the "single writer" rule: only the store writes).
        store.onChange = { [weak self] snapshot in
            self?.gridView.update(snapshot: snapshot, animated: true)
        }

        // The coordinator sets the long-press gesture, jiggle, close buttons, and
        // size arrows itself; there is no need to set grid.onLongPress.
        let coordinator = TesseraTileEditCoordinator(grid: gridView, store: store)
        coordinator.delegate = self
        editCoordinator = coordinator

        applyEditingState(model.isEditing)
        updateGridInsets()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateGridInsets()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateGridInsets()

        // Rotation/width change: the edit buttons are recomputed off
        // the scroll hot path.
        if editCoordinator?.isEditing == true {
            editCoordinator?.refreshEditControls()
        }
    }

    /// Applies the edit mode initiated by the SwiftUI button.
    func applyEditingState(_ isEditing: Bool) {
        guard let editCoordinator else { return }

        if isEditing, !editCoordinator.isEditing {
            editCoordinator.beginEditing()
        } else if !isEditing, editCoordinator.isEditing {
            editCoordinator.endEditing()
        }
    }

    /// The grid does not mix in the safe area itself: the host sets the insets.
    private func updateGridInsets() {
        let safeArea = view.safeAreaInsets
        // The bottom margin is for the floating hint and the "Edit" button,
        // which lie over the representable in the SwiftUI layer; the block height
        // is measured by SwiftUI (at accessibility sizes it is different).
        let insets = UIEdgeInsets(
            top: max(safeArea.top, 0) + 8,
            left: 16,
            bottom: max(safeArea.bottom, 0) + bottomReserve + 8,
            right: 16
        )

        if gridView.contentInsets != insets {
            gridView.contentInsets = insets
        }
    }

    private func handleTap(_ item: TesseraTileGridItem) {
        switch item {
        case .tile(let tile):
            // In edit mode a tap does not run the action: the tile
            // gets the resize/unpin custom actions and close buttons.
            guard editCoordinator?.isEditing != true else { return }
            tile.action()
        case .folder:
            // The grid itself performs the native Windows Phone folder expansion (D17).
            // To restore the old behavior (a folder screen sheet), the host sets
            // gridView.folderTapHandler = { folder in
            //     editCoordinator?.openFolder(folder); return true
            // } - returning true cancels the native expansion.
            break
        case .folderContent:
            // The expanded folder's panel is an internal grid element, no tap is needed.
            break
        }
    }

    // MARK: TesseraTileEditCoordinatorDelegate

    func tileEditCoordinatorDidBeginEditing(_ coordinator: TesseraTileEditCoordinator) {
        updateEditingFlag(true)
    }

    func tileEditCoordinatorDidEndEditing(_ coordinator: TesseraTileEditCoordinator) {
        updateEditingFlag(false)
    }

    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didUnpin tileID: AnyHashable
    ) {
        print("[TesseraKitExample] Unpin tile: \(tileID)")
    }

    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didResize tileID: AnyHashable,
        to size: TesseraTileSize
    ) {
        print("[TesseraKitExample] Resize tile: \(tileID) → \(size.rawValue)")
    }

    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didMove tileID: AnyHashable,
        toCell cell: TesseraTileGridPlacement
    ) {
        print("[TesseraKitExample] Move tile: \(tileID) → (\(cell.row), \(cell.column))")
    }

    /// Do not publish the change again if the flag already matches: otherwise
    /// `@Published` could send an event during a SwiftUI update.
    private func updateEditingFlag(_ isEditing: Bool) {
        if model.isEditing != isEditing {
            model.isEditing = isEditing
        }
    }
}

// MARK: - "Start" tab (the full start screen)

/// The "Start" tab: the full public `TesseraStartScreenViewController`:
/// a pager of three pages (hook / START / app list), wallpaper parallax,
/// a live tile, a folder, and edit mode. The "Desktop" tab stays as
/// it is: a grid and a coordinator without a pager.
struct StartDemoView: View {
    @StateObject private var model = StartDemoModel()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            StartDemoRepresentable(model: model, isEditing: model.isEditing)
                // The wallpaper goes under the status bar, while the tabs' safe area remains at the bottom:
                // the grid gets its bottom margin from the screen itself.
                .ignoresSafeArea(.container, edges: .top)

            // The button to exit edit mode over the screen: the mode is also enabled
            // by a long press on a tile and disabled by a tap on the background.
            if model.isEditing {
                Button {
                    model.isEditing = false
                } label: {
                    Label("Done", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(DemoCapsuleButtonStyle(tint: .green))
                .padding(.bottom, 8)
                .padding(.trailing, 16)
            }
        }
        .alert(item: $model.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

/// A SwiftUI bridge to the full start screen.
struct StartDemoRepresentable: UIViewControllerRepresentable {
    let model: StartDemoModel
    let isEditing: Bool

    func makeUIViewController(context: Context) -> StartDemoHostController {
        StartDemoHostController(model: model)
    }

    func updateUIViewController(_ uiViewController: StartDemoHostController, context: Context) {
        uiViewController.applyEditingState(isEditing)
    }
}

/// The "Start" tab model: a catalog of 7 demo tiles and 18 additional
/// apps (unpinned in the list), a folder, and a live tile.
final class StartDemoModel: ObservableObject {
    let store: TesseraTileStore

    @Published var isEditing = false
    @Published var alert: DemoAlert?

    private let liveTileProvider = DemoLiveTileProvider()

    /// Additional apps: only in the list, not pinned to the grid.
    private static let extraApps: [(id: String, title: String, symbol: String, tint: UIColor)] = [
        ("camera", "Camera", "camera.fill", .systemGray),
        ("maps", "Maps", "map.fill", .systemGreen),
        ("clock", "Clock", "clock.fill", .systemOrange),
        ("contacts", "Contacts", "person.2.fill", .systemBrown),
        ("phone", "Phone", "phone.fill", .systemGreen),
        ("messages", "Messages", "message.fill", .systemBlue),
        ("browser", "Browser", "safari.fill", .systemBlue),
        ("files", "Files", "folder.fill", .systemCyan),
        ("books", "Books", "book.fill", .systemOrange),
        ("calc", "Calculator", "plus.forwardslash.minus", .systemGray),
        ("wallet", "Wallet", "creditcard.fill", .systemIndigo),
        ("health", "Health", "heart.fill", .systemRed),
        ("video", "Video", "play.rectangle.fill", .systemPurple),
        ("podcasts", "Podcasts", "mic.fill", .systemPurple),
        ("translate", "Translate", "character.bubble.fill", .systemTeal),
        ("voice", "Voice Memos", "waveform", .systemRed),
        ("stocks", "Stocks", "chart.line.uptrend.xyaxis", .systemGreen),
        ("tips", "Tips", "lightbulb.fill", .systemYellow),
        // Deliberately Cyrillic (and "Zoom" below is Latin): exercises the mixed-script
        // collation and the section index of the app list.
        ("zeta", "Ёж", "hare.fill", .systemMint),
        ("latin", "Zoom", "video.fill", .systemBlue),
    ]

    init() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TesseraKitExampleStart", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = TesseraTileStore(directoryURL: directory)

        store.setCatalog(makeCatalog())
        try? store.load()
        seedIfNeeded()
    }

    deinit {
        store.onChange = nil
    }

    private func makeCatalog() -> [TesseraTileDescriptor] {
        var catalog: [TesseraTileDescriptor] = [
            TesseraTileDescriptor(
                id: "mail", title: "Mail",
                icon: DemoVisuals.symbol("envelope.fill", tint: .systemBlue),
                action: makeAction(for: "Mail"), badge: .count(3), size: .small),
            TesseraTileDescriptor(
                id: "calendar", title: "Calendar",
                icon: DemoVisuals.symbol("calendar", tint: .systemRed),
                action: makeAction(for: "Calendar"), badge: .dot, size: .medium),
            TesseraTileDescriptor(
                id: "weather", title: "Weather",
                icon: DemoVisuals.symbol("cloud.sun.fill", tint: .systemTeal),
                action: makeAction(for: "Weather"), size: .wide,
                liveContent: liveTileProvider),
            TesseraTileDescriptor(
                id: "notes", title: "Notes",
                icon: DemoVisuals.symbol("note.text", tint: .systemYellow),
                action: makeAction(for: "Notes"), size: .small),
            TesseraTileDescriptor(
                id: "photos", title: "Photos",
                icon: DemoVisuals.symbol("photo.fill", tint: .systemGreen),
                action: makeAction(for: "Photos"), size: .small),
            TesseraTileDescriptor(
                id: "music", title: "Music",
                icon: DemoVisuals.symbol("music.note", tint: .systemPink),
                action: makeAction(for: "Music"), badge: .count(5), size: .large),
            TesseraTileDescriptor(
                id: "settings", title: "Settings",
                icon: DemoVisuals.symbol("gearshape.fill", tint: .systemGray),
                action: makeAction(for: "Settings"), badge: .dot, size: .small),
        ]
        for app in Self.extraApps {
            catalog.append(
                TesseraTileDescriptor(
                    id: app.id, title: app.title,
                    icon: DemoVisuals.symbol(app.symbol, tint: app.tint),
                    action: makeAction(for: app.title), size: .small)
            )
        }
        return catalog
    }

    /// The "Work" folder of two tiles; the additional apps are unpinned
    /// so that the list has both pinned and free rows.
    private func seedIfNeeded() {
        guard store.snapshot().folders.isEmpty else { return }

        let columns = TesseraTileLayoutEngine.defaultColumns
        for app in Self.extraApps where store.isPinned(app.id) {
            _ = store.unpin(app.id, columns: columns)
        }

        if let folder = store.createFolder(withTile: "notes", title: "Work", columns: columns) {
            store.addToFolder("photos", folderID: folder.id, columns: columns)
        }
        store.collapseEmptyRows(columns: columns)
    }

    private func makeAction(for title: String) -> () -> Void {
        { [weak self] in
            print("[TesseraKitExample] Start tap shortcut: \(title)")
            self?.alert = DemoAlert(
                title: title,
                message: "Demo tile action: \(title)."
            )
        }
    }

    func showSettingsAlert() {
        alert = DemoAlert(title: "Settings", message: "A settings section row of the app list.")
    }
}

/// A simple hook page: a title and a couple of lines, so there is something to scroll.
final class StartDemoHookController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.35)

        let title = UILabel()
        title.text = "Quick panel"
        title.font = .preferredFont(forTextStyle: .largeTitle)
        title.textColor = .white
        title.adjustsFontForContentSizeCategory = true

        let detail = UILabel()
        detail.text = "Hook page (TesseraQuickPanelProviding): the host puts search, quick settings, and a profile here."
        detail.font = .preferredFont(forTextStyle: .body)
        detail.textColor = .white
        detail.numberOfLines = 0
        detail.adjustsFontForContentSizeCategory = true

        let stack = UIStackView(arrangedSubviews: [title, detail])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 48),
        ])
    }
}

/// The UIKit container of the full start screen: the pager, the grid, the edit
/// coordinator; everything goes through the public API.
final class StartDemoHostController: UIViewController,
    TesseraStartScreenDelegate, TesseraTileEditCoordinatorDelegate
{
    private let model: StartDemoModel
    private let store: TesseraTileStore
    private let screen = TesseraStartScreenViewController()
    private var editCoordinator: TesseraTileEditCoordinator?

    init(model: StartDemoModel) {
        self.model = model
        self.store = model.store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(screen)
        screen.view.frame = view.bounds
        screen.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(screen.view)
        screen.didMove(toParent: self)

        screen.delegate = self
        screen.wallpaperImage = DemoVisuals.panoramaBackground
        screen.wallpaperParallaxFactor = 0.5
        screen.quickPanelTitle = "Quick panel"
        screen.startPageTitle = "Start"
        screen.applicationsPageTitle = "Apps"

        // A snapshot with a table of explicit cells: the grid shows the model's holes.
        screen.reload(grid: store.snapshot(columns: screen.gridView.columns))

        let store = self.store
        let model = self.model
        screen.configure(
            leftPanel: TesseraQuickPanelProvider(makeViewController: { StartDemoHookController() }),
            rightPage: { [model] in
                TesseraAppsListPageViewController.make(
                    store: store,
                    settings: [
                        TesseraAppsListSettingsItem(
                            id: "settings",
                            title: "Settings",
                            subtitle: "Demo settings row",
                            icon: UIImage(systemName: "gearshape"),
                            action: { [weak model] in model?.showSettingsAlert() }
                        ),
                    ]
                )
            }
        )

        // Data comes only from the store (a single writer): the snapshot is applied on
        // every change, including pin/unpin from the list page.
        store.onChange = { [weak self] snapshot in
            self?.screen.reload(grid: snapshot)
        }

        // Grid taps stay with the host (the screen controller does not forward them):
        // we invoke the tile action ourselves, and not in edit mode.
        screen.gridView.onTap = { [weak self] item in
            guard case .tile(let tile) = item,
                  self?.editCoordinator?.isEditing != true else { return }
            tile.action()
        }

        let coordinator = TesseraTileEditCoordinator(grid: screen.gridView, store: store)
        coordinator.delegate = self
        editCoordinator = coordinator
        applyEditingState(model.isEditing)
    }

    /// Applies the edit mode initiated by the SwiftUI button.
    func applyEditingState(_ isEditing: Bool) {
        guard let editCoordinator else { return }

        if isEditing, !editCoordinator.isEditing {
            editCoordinator.beginEditing()
        } else if !isEditing, editCoordinator.isEditing {
            editCoordinator.endEditing()
        }
    }

    // MARK: TesseraStartScreenDelegate

    func startScreen(
        _ screen: TesseraStartScreenViewController,
        didChangePage page: TesseraStartScreenPage,
        index: Int
    ) {
        print("[TesseraKitExample] Start page: \(page) index \(index)")
    }

    // MARK: TesseraTileEditCoordinatorDelegate

    func tileEditCoordinatorDidBeginEditing(_ coordinator: TesseraTileEditCoordinator) {
        if !model.isEditing { model.isEditing = true }
    }

    func tileEditCoordinatorDidEndEditing(_ coordinator: TesseraTileEditCoordinator) {
        if model.isEditing { model.isEditing = false }
    }
}

// MARK: - "Pivot" tab

struct PivotDemoView: View {
    var body: some View {
        TesseraPivotView(
            sections: makeSections(),
            style: TesseraPivotStyle(
                activeColor: .systemOrange,
                inactiveColor: .secondaryLabel,
                indicatorStyle: .underlineAndText,
                stripMode: .content,
                appTitle: "Tessera Pivot"
            )
        )
    }

    /// SwiftUI section content through the real TesseraCore factory.
    private func makeSections() -> [TesseraPivotSection] {
        [
            TesseraPivotSection(
                id: "pivot-home",
                title: "Home",
                content: TesseraSwiftUIContentProvider {
                    DemoPivotPage(
                        index: 0,
                        title: "Home",
                        subtitle: "The first pivot section. The header strip is synchronized with the pager, and the large title is set via TesseraPivotStyle.appTitle."
                    )
                }
            ),
            TesseraPivotSection(
                id: "pivot-feed",
                title: "Feed",
                content: TesseraSwiftUIContentProvider {
                    DemoPivotPage(
                        index: 1,
                        title: "Feed",
                        subtitle: "The second section. The horizontal swipe, a tap on a header, and the indicator run on the UIKit core of TesseraPivot."
                    )
                }
            ),
            TesseraPivotSection(
                id: "pivot-overview",
                title: "Overview",
                content: TesseraSwiftUIContentProvider {
                    DemoPivotPage(
                        index: 2,
                        title: "Overview",
                        subtitle: "The third section. The pager takes the horizontal axis; the demo has no nested vertical scroll so that the swipe is not intercepted."
                    )
                }
            ),
            TesseraPivotSection(
                id: "pivot-profile",
                title: "Profile",
                content: TesseraSwiftUIContentProvider {
                    DemoPivotPage(
                        index: 3,
                        title: "Profile",
                        subtitle: "The fourth section. Try Dynamic Type and VoiceOver: the headers and pages adapt."
                    )
                }
            ),
        ]
    }
}

struct DemoPivotPage: View {
    let index: Int
    let title: String
    let subtitle: String

    private var tint: Color {
        switch index {
        case 0: return .blue
        case 1: return .orange
        case 2: return .purple
        default: return .green
        }
    }

    var body: some View {
        // Deliberately without a vertical ScrollView: a SwiftUI scroll would intercept
        // the pager's horizontal gesture, and the vertical owner is registered
        // by the host only through a UIKit controller. For testing the pivot a
        // reliable horizontal swipe matters more.
        VStack(alignment: .leading, spacing: 18) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [tint.opacity(0.95), tint.opacity(0.55)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 150)
                .overlay(
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TesseraPivot")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white.opacity(0.85))
                        Text(title)
                            .font(.largeTitle.bold())
                            .foregroundColor(.white)
                    }
                    .padding(20),
                    alignment: .bottomLeading
                )

            Text(subtitle)
                .font(.body)
                .foregroundColor(.secondary)

            ForEach(0..<3) { row in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.15))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "circle.fill")
                                .font(.caption)
                                .foregroundColor(tint)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Row \(row + 1)")
                            .font(.subheadline.weight(.semibold))
                        Text("Demo content of the \(title) section.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(UIColor.systemBackground))
    }
}

// MARK: - "Panorama" tab

struct PanoramaDemoView: View {
    var body: some View {
        TesseraPanoramaView(
            sections: makeSections(),
            style: TesseraPanoramaStyle(
                peek: 56,
                parallaxFactor: 0.5,
                headerFont: .systemFont(ofSize: 34, weight: .bold),
                headerColor: .white,
                headerActiveColor: .systemYellow,
                backgroundBehavior: .image(DemoVisuals.panoramaBackground)
            ),
            snapPolicy: TesseraSnapPolicy(velocityThreshold: 500, alignment: .center)
        )
    }

    /// Three sections over one generated image: no external resources.
    private func makeSections() -> [TesseraPanoramaSection] {
        [
            TesseraPanoramaSection(
                id: "pano-start",
                title: "Start",
                content: TesseraSwiftUIContentProvider {
                    DemoPanoramaPage(
                        index: 0,
                        title: "Start",
                        text: "Sections are narrower than the screen: a peek band is visible on the right, and the parallax background moves slower than the content."
                    )
                }
            ),
            TesseraPanoramaSection(
                id: "pano-news",
                title: "News",
                content: TesseraSwiftUIContentProvider {
                    DemoPanoramaPage(
                        index: 1,
                        title: "News",
                        text: "The section header is animated by the same scalar t as the background. A swipe, a tap on a header, and VoiceOver all lead to a single programmatic transition point."
                    )
                }
            ),
            TesseraPanoramaSection(
                id: "pano-about",
                title: "About the panorama",
                content: TesseraSwiftUIContentProvider {
                    DemoPanoramaPage(
                        index: 2,
                        title: "About the panorama",
                        text: "The background is a generated gradient (DemoVisuals), with no resources in Assets. Under Reduce Motion the core disables the parallax and the header animations."
                    )
                }
            ),
        ]
    }
}

struct DemoPanoramaPage: View {
    let index: Int
    let title: String
    let text: String

    var body: some View {
        // Without a vertical ScrollView: the inner UIScrollView would intercept
        // the panorama's horizontal gesture, and the vertical owner is registered
        // by the host only through a UIKit controller. The card fills the page,
        // and the background image stays visible at the edges and in the peek band.
        VStack(alignment: .leading, spacing: 16) {
            Text("Section \(index + 1) of 3")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            Text(title)
                .font(.title2.bold())
                .foregroundColor(.primary)

            Text(text)
                .font(.body)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                demoStat(value: "3", caption: "sections")
                demoStat(value: "56", caption: "peek, pt")
                demoStat(value: "0.5", caption: "parallax")
            }

            Text("The card is translucent: the background image shows in the peek band and at the edges.")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(UIColor.systemBackground).opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    private func demoStat(value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline)
                .foregroundColor(.primary)
            Text(caption)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - "Core" tab

struct CorePagerDemoView: View {
    @StateObject private var model = DemoPagerModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TesseraCore pager")
                        .font(.title2.bold())
                    Text("Two TesseraPagerViewController instances: .paged and .snapping. The buttons call the public go(toPage:animated:).")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                pagerBlock(
                    title: "The .paged mode",
                    subtitle: "Snapping is provided by isPagingEnabled: pages are exactly the screen width.",
                    pager: model.pagedPager,
                    index: model.pagedIndex
                )

                pagerBlock(
                    title: "The .snapping mode",
                    subtitle: "Custom snapping via TesseraSnapPolicy: decelerationRate = .fast and the target offset by the velocity threshold.",
                    pager: model.snappingPager,
                    index: model.snappingIndex
                )
            }
            .padding(20)
        }
    }

    private func pagerBlock(
        title: String,
        subtitle: String,
        pager: TesseraPagerViewController,
        index: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
                Text("\(index + 1) / \(DemoPagerModel.pageCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            PagerHostView(pager: pager)
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(UIColor.separator), lineWidth: 1)
                )

            HStack(spacing: 8) {
                Button("Back") {
                    pager.go(toPage: max(index - 1, 0), animated: true)
                }
                .disabled(index <= 0)

                Button("Forward") {
                    pager.go(toPage: min(index + 1, DemoPagerModel.pageCount - 1), animated: true)
                }
                .disabled(index >= DemoPagerModel.pageCount - 1)

                Button("To page 3") {
                    pager.go(toPage: DemoPagerModel.pageCount - 1, animated: true)
                }
                .disabled(index >= DemoPagerModel.pageCount - 1)
            }
            .buttonStyle(DemoCapsuleButtonStyle())

            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// A wrapper around a ready pager instance from the demo model.
///
/// The instance is created once in `DemoPagerModel` so that the buttons can
/// call its public `go(toPage:animated:)`.
struct PagerHostView: UIViewControllerRepresentable {
    let pager: TesseraPagerViewController

    func makeUIViewController(context: Context) -> PagerContainerController {
        PagerContainerController(pager: pager)
    }

    func updateUIViewController(
        _ uiViewController: PagerContainerController,
        context: Context
    ) {
        // The pager configuration is set at creation; there is nothing to update.
    }
}

/// A container for a ready pager from the model.
///
/// The instance is created once (the buttons call its `go(toPage:animated:)`),
/// so when the tab is shown again the container carefully reattaches the
/// child controller if it was still someone's child.
final class PagerContainerController: UIViewController {
    private let pager: TesseraPagerViewController

    init(pager: TesseraPagerViewController) {
        self.pager = pager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .clear

        if pager.parent != nil {
            pager.willMove(toParent: nil)
            pager.view.removeFromSuperview()
            pager.removeFromParent()
        }

        addChild(pager)
        pager.view.frame = view.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        if pager.view.frame != view.bounds {
            pager.view.frame = view.bounds
        }
    }
}

/// The demo pager model: two instances, their pages, and the current indexes.
final class DemoPagerModel: ObservableObject, TesseraPagerDelegate {
    static let pageCount = 3

    let pagedPager: TesseraPagerViewController
    let snappingPager: TesseraPagerViewController

    @Published private(set) var pagedIndex = 0
    @Published private(set) var snappingIndex = 0

    init() {
        let paged = TesseraPagerViewController(
            mode: .paged,
            pages: DemoPagerModel.makePages(prefix: "paged")
        )
        let snapping = TesseraPagerViewController(
            mode: .snapping,
            pages: DemoPagerModel.makePages(prefix: "snapping"),
            snapPolicy: TesseraSnapPolicy(velocityThreshold: 400, alignment: .center)
        )

        pagedPager = paged
        snappingPager = snapping
        paged.delegate = self
        snapping.delegate = self
    }

    func pager(_ pager: TesseraPagerViewController, didShowPageAt index: Int) {
        if pager === pagedPager {
            if pagedIndex != index {
                pagedIndex = index
            }
        } else if pager === snappingPager {
            if snappingIndex != index {
                snappingIndex = index
            }
        }
    }

    /// The pager's pages: SwiftUI content through the standard TesseraCore factory.
    private static func makePages(prefix: String) -> [TesseraPageDescriptor] {
        (0..<pageCount).map { index in
            TesseraPageDescriptor(
                id: "\(prefix)-page-\(index)",
                title: "Page \(index + 1)",
                content: TesseraSwiftUIContentProvider {
                    DemoPagerPage(pageIndex: index)
                }
            )
        }
    }
}

struct DemoPagerPage: View {
    let pageIndex: Int

    private var colors: [Color] {
        switch pageIndex {
        case 0: return [.blue, .purple]
        case 1: return [.orange, .pink]
        default: return [.teal, .blue]
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: colors),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 8) {
                Text("Page \(pageIndex + 1)")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                Text("TesseraPagerViewController")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.9))
            }
            .padding()
        }
    }
}

// MARK: - Previews

#Preview {
    ContentView()
}
