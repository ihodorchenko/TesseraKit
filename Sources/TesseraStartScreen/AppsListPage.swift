// The right page of the start screen: the app list and settings.
//
// Design document: docs/STARTSCREEN-IOS-DESIGN.md
//  - §1 "The key architectural idea: three pages": the app list lives to the
//    right of START; a right-to-left swipe leads to it;
//  - §6 "The right page: app list + settings": a UITableView with
//    letter sections and `sectionIndexTitles` (jump list); settings are a
//    list section, with two-way sync with tiles through TesseraTileStore;
//  - §9 "Accessibility": rows are standard elements, the jump list is available,
//    Dynamic Type, RTL;
//  - §14 "MVP clarifications" and D12/D13 in docs/DECISIONS.md: a tile is just an
//    action (no `type` field), and the page itself is optional — the host creates it
//    if it wants a third pager page;
//  - D14: the page does nothing with folders by itself — all folder operations
//    go through TesseraTileStore and the host approval function (this list has no such
//    operations: pin/unpin is layout, not grouping).
//
// The source of truth is TesseraTileStore (§6, the "single writer" rule). The page
// holds no start screen state of its own: it reads `snapshot()` and
// rebuilds the sections after every store change, and performs pin/unpin
// with TesseraTileStore methods. So the grid and the list do not diverge:
// a pin from the list appears in the grid via the host's `onChange`, and an unpin on the grid
// changes the row state here — by subscribing to changes of the same store.
//
// Pin goes through `TesseraTileStore.pinTile(_:columns:)` (a new row at the
// end of the canvas, D33), unpin through `TesseraTileStore.unpin(_:columns:)` followed by
// `collapseEmptyRows(columns:)` (a hole stays, an empty row collapses, D31).
// The host reports the real grid's column count to the factory (`columns`); if it is absent,
// the width known to the store is used. The column count is fixed when the
// page is created: when the grid's column count changes, the host must recreate the page —
// the page does not recompute the layout by itself.
//
// The subscription is to `objectWillChange` (`ObservableObject`; iOS 15 — per the rule in
// AGENTS.md), not to `onChange`: `onChange` is a single closure, held
// by the host, which uses it to update the grid. A subscription to objectWillChange
// is ownerless and allows several observers, so the page does not take the
// channel away from the grid.
//
// Page geometry: there are no gesture recognizers of its own here. The pager
// (docs/CORE-IOS-DESIGN.md §2) takes the horizontal axis, and this UITableView takes the
// vertical one; arbitration by the dominant axis is done by the pager, and the page receives
// the finished decision. So the table simply scrolls vertically.

#if canImport(UIKit)
import Combine
import UIKit

// MARK: - Page settings (list items)

/// An item of the settings section of the right page (docs/STARTSCREEN-IOS-DESIGN.md §6).
///
/// "Settings are a section/item of the list": the component does not know what exactly
/// is being configured — it shows the rows the host passed and calls their
/// ``action``. This way a separate settings screen stays with the app (§6), and the
/// page does not turn into yet another source of state.
///
/// Settings rows are not tied to `TesseraTileStore`: they are ordinary host actions.
public struct TesseraAppsListSettingsItem {

    /// A stable row identifier; unique within the settings section.
    ///
    /// The page uses it only to compare state on reload,
    /// so any hashable value will do.
    public let id: AnyHashable

    /// The main row title.
    public var title: String

    /// An explanation below the title; `nil` means a single-line row.
    public var subtitle: String?

    /// The row icon; `nil` means no icon (the text snaps to the edge).
    public var icon: UIImage?

    /// The tap action. Called on the main thread, like `TesseraTileDescriptor.action`.
    public let action: () -> Void

    /// Creates a settings section row.
    ///
    /// - Parameters:
    ///   - id: A unique row identifier.
    ///   - title: The main title.
    ///   - subtitle: An explanation; none by default.
    ///   - icon: The icon; none by default.
    ///   - action: The tap action.
    public init(
        id: AnyHashable,
        title: String,
        subtitle: String? = nil,
        icon: UIImage? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.action = action
    }
}

/// The localizable strings of the right page.
///
/// The default values come from the module's resource tables
/// (`Resources/en.lproj|ru.lproj/Localizable.strings`) and are resolved by the system
/// language: on a Russian-language device the Russian strings, on an English one
/// "Settings". For an unsupported language the base locale `en` applies.
/// The host may replace any string entirely — as with the titles of other
/// components; the passed value is used unchanged.
public struct TesseraAppsListTexts: Equatable {

    /// The settings section title.
    public var settingsSectionTitle: String

    /// The empty state text: the catalog has neither tiles nor settings.
    public var emptyTitle: String

    /// The name of the "pin the tile to the start screen" action (the button and the custom action).
    public var pinActionTitle: String

    /// The name of the "unpin the tile from the start screen" action.
    public var unpinActionTitle: String

    /// The VoiceOver value of a pinned tile's row.
    public var pinnedValue: String

    /// Creates a set of strings.
    ///
    /// The parameters kept their signature and default values; the values themselves
    /// now come from the module's resource tables by the system language,
    /// so `TesseraAppsListTexts()` gives Russian
    /// strings on a Russian-language device and English ones on an English device.
    ///
    /// - Parameters:
    ///   - settingsSectionTitle: The settings section title.
    ///   - emptyTitle: The empty state text.
    ///   - pinActionTitle: The "pin" action.
    ///   - unpinActionTitle: The "unpin" action.
    ///   - pinnedValue: The VoiceOver value of a pinned row.
    public init(
        settingsSectionTitle: String = TesseraStartScreenStrings.appsListSettingsSectionTitle,
        emptyTitle: String = TesseraStartScreenStrings.appsListEmptyTitle,
        pinActionTitle: String = TesseraStartScreenStrings.appsListPinActionTitle,
        unpinActionTitle: String = TesseraStartScreenStrings.appsListUnpinActionTitle,
        pinnedValue: String = TesseraStartScreenStrings.appsListPinnedValue
    ) {
        self.settingsSectionTitle = settingsSectionTitle
        self.emptyTitle = emptyTitle
        self.pinActionTitle = pinActionTitle
        self.unpinActionTitle = unpinActionTitle
        self.pinnedValue = pinnedValue
    }
}

// MARK: - Page

/// The optional right page of the start screen pager (§6; D13).
///
/// The page shows the **whole catalog** of tiles, grouped by the letters of
/// the locale's alphabetical index (`UILocalizedIndexedCollation`), and a separate
/// settings section. A tile row is a standard
/// list element: a tap runs `TesseraTileDescriptor.action` (D12: a tile is just an
/// action), a pushpin-style button in the accessory pins or
/// unpins the tile, and the row state always reflects `TesseraTileStore`.
///
/// ## Usage
///
/// ```swift
/// let page = TesseraAppsListPageViewController.make(
///     store: store,
///     settings: [
///         TesseraAppsListSettingsItem(id: "settings", title: "Desktop settings") {
///             host.presentSettings()
///         }
///     ],
///     // The real grid's column count: pin puts a tile in a new row, unpin
///     // leaves a hole (cells are stored on a canvas of this width).
///     columns: screen.gridView.columns
/// )
/// // The host connects the page with a closure: the page knows no references to the pager type.
/// ```
///
/// The page does not subscribe to `TesseraTileStore.onChange` and does not change the
/// tile catalog: `setCatalog(_:)`, `load()`, and the layout remain the host's business.
/// Everything it does with the store is `snapshot()`,
/// `pinTile(_:columns:)`, `unpin(_:columns:)`, and
/// `collapseEmptyRows(columns:)`; folder operations (D14) go
/// through the host's `approval` and are not initiated here. The column count for
/// cell-based operations is taken by the page from the factory (``make(store:settings:texts:columns:)``);
/// it does not compute the layout itself and does not know the screen grid (D13).
///
/// The page adds no gesture recognizers of its own: vertical scrolling is
/// the table, horizontal is the pager. The scroll view is exposed through
/// ``scrollView`` so that the host can register it as the vertical owner
/// in `TesseraGestureArbiter` (docs/CORE-IOS-DESIGN.md §2).
///
/// ## Accessibility (§9)
///
/// - rows are real `UITableViewCell`s: the title is `title`, the value is
///   "Pinned" (``TesseraAppsListTexts/pinnedValue``), and the indicator is the button;
/// - the accessory button is a standalone VoiceOver element with a clear
///   action ("Pin"/"Unpin"), and the same action is also available
///   as a `UIAccessibilityCustomAction` on the row itself;
/// - the jump list is the native `sectionIndexTitles`; RTL mirroring of the index
///   and rows is done by UIKit (a forced `semanticContentAttribute`
///   is not set, so as not to break the direction set by the host);
/// - Dynamic Type: row and empty state fonts are text styles;
/// - on pin/unpin the visible rows are rebuilt in place, so VoiceOver
///   does not lose focus, unlike with `reloadData`.
///
/// - Note: All methods and callbacks are called on the main thread.
public final class TesseraAppsListPageViewController: UIViewController {

    // MARK: - Public interface

    /// The settings section rows; changing them rebuilds the section.
    ///
    /// An empty array means no settings section (§14: the page does not impose
    /// sections on the host that the app does not have).
    public var settingsItems: [TesseraAppsListSettingsItem] {
        didSet {
            // Settings rows are not store state, so there is nothing to compare
            // titles/explanations against in a snapshot: we reload the whole section.
            refreshTable(forceReload: true)
        }
    }

    /// The localizable strings of the page.
    public var texts: TesseraAppsListTexts {
        didSet {
            guard texts != oldValue else { return }
            refreshTable(forceReload: true)
        }
    }

    /// The page's scroll view — the vertical owner for `TesseraGestureArbiter`
    /// (docs/CORE-IOS-DESIGN.md §2 "Arbitration", §3).
    ///
    /// The page does not configure arbitration itself: the gesture between the horizontal
    /// pager and the vertical list is distributed by the host, which has both
    /// scroll views. Exactly a `UIScrollView` is exposed — that is enough for the arbiter,
    /// while the table's internal type remains an implementation detail.
    public var scrollView: UIScrollView { tableView }

    /// Creates the page — the only supported entry point.
    ///
    /// A static factory is needed so that in `StartScreenViewController` the page
    /// is connected by the closure `{ TesseraAppsListPageViewController.make(store: store) }`
    /// and the page type does not leak into the pager API (D13).
    ///
    /// - Parameters:
    ///   - store: The start screen store — the single source of truth (§6).
    ///   - settings: The settings section rows; no section by default.
    ///   - texts: The localizable strings; by default the module's strings,
    ///     localized by the system language.
    ///   - columns: The real grid's column count (for example,
    ///     `TesseraTileGridView.columns`) at the moment of page creation. With it
    ///     pin puts a tile in a new row at the end of the canvas, and unpin leaves
    ///     a hole and collapses a fully empty row (cell-based operations).
    ///     `nil` means the host did not report the layout: the width the coordinator
    ///     reported to the store is used, otherwise the default. A non-positive
    ///     value is treated as `nil`.
    ///
    ///     The column count is fixed when the page is created and is not updated
    ///     on the fly: when the grid's column count changes (rotation, width change)
    ///     the host must recreate the page — the factory of the right page
    ///     is called by the pager when it recreates the page and must pass
    ///     the current column count.
    /// - Returns: The ready page.
    public static func make(
        store: TesseraTileStore,
        settings: [TesseraAppsListSettingsItem] = [],
        texts: TesseraAppsListTexts = TesseraAppsListTexts(),
        columns: Int? = nil
    ) -> TesseraAppsListPageViewController {
        TesseraAppsListPageViewController(
            store: store,
            settings: settings,
            texts: texts,
            columns: columns
        )
    }

    // MARK: - Data

    /// The start screen store (§6: the source of truth).
    private let store: TesseraTileStore

    /// The real grid's column count for cell-based operations.
    ///
    /// `nil` means the host did not report the layout: ``TesseraTileStore/effectiveColumns`` is used
    /// (``make(store:settings:texts:columns:)``). Fixed when the page is created:
    /// when the grid's column count changes the host recreates the page, otherwise
    /// cells would be computed for a stale width.
    private let columns: Int?

    /// The table of the app list and settings.
    private let tableView = UITableView(frame: .zero, style: .plain)

    /// The subscription to store changes.
    private var storeSubscription: AnyCancellable?

    /// The tile sections by letter in display order (non-empty ones only).
    private var sections: [AppSection] = []

    /// The alphabetical index of the current locale (§6: "letter sections +
    /// `sectionIndexTitles`" is the native pattern). Refreshed on every
    /// section rebuild, so that a language change does not leave the old alphabet.
    private var collation = UILocalizedIndexedCollation.current()

    /// The structure of the last rendered table — to tell a change of the row
    /// set (a reload is needed) from a state change (visible cells suffice).
    private var lastStructure: [SectionSignature] = []

    /// The tile row state (pinned, icon) of the last render.
    private var lastRowStates: [[RowState]] = []

    /// The icon thumbnail cache: a standard cell takes the image size in layout,
    /// so large app icons are scaled to the row size once.
    private let iconCache: NSCache<UIImage, UIImage> = {
        let cache = NSCache<UIImage, UIImage>()
        cache.countLimit = 128
        return cache
    }()

    /// The empty state caption (created once).
    private var emptyStateLabel: UILabel?

    /// The empty state container for `tableView.backgroundView`.
    private lazy var emptyStateView: UIView = makeEmptyStateView()

    /// The row icon size in points (the standard icon size in iOS lists).
    private static let iconSide: CGFloat = 29

    /// Cell reuse identifiers.
    private static let defaultCellIdentifier = "TesseraAppsListDefaultCell"
    private static let subtitleCellIdentifier = "TesseraAppsListSubtitleCell"

    // MARK: - Row model

    /// A tile in the list together with its state on the start screen.
    private struct AppEntry {
        /// A tile from the store snapshot (action, icon, badge, size).
        let descriptor: TesseraTileDescriptor

        /// Whether the tile is pinned to the grid or in a folder.
        let isPinned: Bool

        /// The tile identifier (D12: stable, unique within the start screen).
        var id: AnyHashable { descriptor.id }

        /// The title — also the alphabetical key and the accessibility label.
        var title: String { descriptor.title }

        /// The tile icon.
        var icon: UIImage? { descriptor.icon }
    }

    /// A tile section for one letter.
    private struct AppSection {
        /// The section header letter (or "#") — the collation section title.
        let title: String

        /// The section index in `UILocalizedIndexedCollation.sectionTitles`: the
        /// jump list uses it to find the nearest non-empty section.
        let collationIndex: Int

        /// Rows in alphabetical order.
        var entries: [AppEntry]
    }

    /// The row state for comparing "whether the table changed in its set of rows".
    private struct RowSignature: Equatable {
        let id: AnyHashable
        let title: String
    }

    /// The mutable tile row state with an unchanged row set: a change of
    /// any field rebuilds the visible rows in place (without `reloadData`).
    ///
    /// The icon is compared by the **identity** of the `UIImage` object: a host
    /// that replaced the icon with the same `id`/`title` gets a redrawn
    /// row, while the comparison does not pay for comparing pixels.
    private struct RowState: Equatable {
        let isPinned: Bool
        let icon: UIImage?

        static func == (lhs: RowState, rhs: RowState) -> Bool {
            lhs.isPinned == rhs.isPinned && lhs.icon === rhs.icon
        }
    }

    /// A wrapper of the title for `UILocalizedIndexedCollation`: collation reads
    /// the string of the object via an Objective-C selector.
    private final class CollationKey: NSObject {
        @objc let title: String

        init(_ title: String) {
            self.title = title
        }
    }

    /// The section state for comparing "whether the table changed in its set of rows".
    private struct SectionSignature: Equatable {
        let title: String
        let rows: [RowSignature]
    }

    // MARK: - Initialization

    /// Creates the page; use ``make(store:settings:texts:)``.
    ///
    /// - Parameters:
    ///   - store: The start screen store.
    ///   - settings: The settings section rows.
    ///   - texts: The localizable strings.
    ///   - columns: The real grid's column count; `nil` means unknown.
    private init(
        store: TesseraTileStore,
        settings: [TesseraAppsListSettingsItem],
        texts: TesseraAppsListTexts,
        columns: Int?
    ) {
        self.store = store
        self.settingsItems = settings
        self.texts = texts
        // A grid always has at least one column: a non-positive value
        // does not describe a layout and is treated as "columns unknown".
        self.columns = columns.flatMap { $0 > 0 ? $0 : nil }
        super.init(nibName: nil, bundle: nil)
    }

    /// The page does not support creation from an archive/storyboard: it needs a
    /// store, which is passed only through
    /// ``make(store:settings:texts:columns:)``.
    ///
    /// - Parameter coder: The archive decoder.
    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("TesseraAppsListPageViewController must be created via make(store:settings:texts:columns:)")
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        setUpTableView()

        // §6: the only update channel is the store. A subscription to
        // objectWillChange does not take onChange away from the grid (see the file header).
        storeSubscription = store.objectWillChange.sink { [weak self] _ in
            self?.refreshTable(forceReload: false)
        }

        // §9, Dynamic Type: a standard cell is not obliged to rebuild its font
        // on the fly, so we recompute the visible rows and heights when the text
        // size category changes. One observer per page.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )

        refreshTable(forceReload: true)
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The page might have been unloaded by the pager and rebuilt, and the store
        // may have changed in the meantime; a rebuild is cheap and idempotent.
        refreshTable(forceReload: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Rebuilds the visible rows and their heights for a new Dynamic Type category.
    @objc private func contentSizeCategoryDidChange() {
        guard isViewLoaded else { return }
        // Beginning/ending updates makes the table re-query row heights
        // under `automaticDimension`; the data does not change.
        tableView.beginUpdates()
        tableView.endUpdates()
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath) else { continue }
            configure(cell, at: indexPath)
        }
        // The empty state is the only page label outside the cells.
        emptyStateLabel?.font = UIFont.preferredFont(forTextStyle: .body)
    }

    // MARK: - Table setup

    /// Builds the table: delegates, styles, safe area.
    private func setUpTableView() {
        view.backgroundColor = .systemBackground

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .systemBackground
        tableView.dataSource = self
        tableView.delegate = self
        tableView.alwaysBounceVertical = true
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        // On iPad rows do not stretch to the full width — a readable column.
        tableView.cellLayoutMarginsFollowReadableWidth = true
        // §9: the container is not a single element — the elements are the rows.
        tableView.isAccessibilityElement = false

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Data and reload

    /// Rebuilds the sections from the current store snapshot.
    ///
    /// The **whole** catalog goes into the list: both pinned tiles (`items`,
    /// including folder contents) and unpinned ones (`unpinned`). This way the
    /// §6 requirement "unpin on the grid → the list item changes state" is met without
    /// a second data source: the state is a flag from the same snapshot.
    private func rebuildSections() {
        let snapshot = store.snapshot()

        var pinnedIDs = Set<AnyHashable>()
        var catalog: [AnyHashable: TesseraTileDescriptor] = [:]

        for item in snapshot.items {
            switch item {
            case .tile(let descriptor):
                pinnedIDs.insert(descriptor.id)
                catalog[descriptor.id] = descriptor
            case .folder(let folder):
                // Folder tiles are pinned too: the grid shows them through the folder,
                // so the list marks them as pinned. Unpinning such a
                // tile is done by TesseraTileStore itself (it removes it from the folder; D14 — this is
                // a consequence of unpinning, not a grouping operation).
                for tile in folder.tiles {
                    pinnedIDs.insert(tile.id)
                    catalog[tile.id] = tile
                }
            case .folderContent:
                // The panel of an expanded folder is UI state (D17), it is not in the
                // data; the folder's tiles are already counted via the `.folder` element.
                break
            }
        }

        for descriptor in snapshot.unpinned {
            catalog[descriptor.id] = descriptor
        }

        let entries = catalog.values
            .map { AppEntry(descriptor: $0, isPinned: pinnedIDs.contains($0.id)) }
            .sorted { lhs, rhs in
                lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }

        // Sections come from the `UILocalizedIndexedCollation` of the current locale (§6,
        // a native pattern): "É" goes with "E", ideographs do not produce a section
        // per character, and digits and symbols go to "#". The row order within a section is
        // `localizedStandardCompare`: bucketing preserves the order of the
        // already sorted array.
        let collation = UILocalizedIndexedCollation.current()
        self.collation = collation
        let titles = collation.sectionTitles
        var buckets = [[AppEntry]](repeating: [], count: titles.count)
        for entry in entries {
            let index = Self.collationSection(for: entry.title, collation: collation)
            buckets[index].append(entry)
        }

        sections = buckets.enumerated().compactMap { index, entries in
            entries.isEmpty ? nil : AppSection(title: titles[index], collationIndex: index, entries: entries)
        }
    }

    /// Rebuilds the table from the store.
    ///
    /// - Parameter forceReload: `true` reloads the table even with an
    ///   unchanged structure (a change of page rows/texts).
    private func refreshTable(forceReload: Bool) {
        guard isViewLoaded else { return }

        let previousStructure = lastStructure
        let previousRowStates = lastRowStates

        rebuildSections()
        let structure = makeStructure()
        let rowStates = makeRowStates()

        if !forceReload, structure == previousStructure, rowStates == previousRowStates {
            return
        }

        lastStructure = structure
        lastRowStates = rowStates

        if forceReload || structure != previousStructure {
            let previousOffset = tableView.contentOffset
            tableView.reloadData()
            updateEmptyState()
            // §6, two-way sync: an unpin on the grid must not make the
            // list "jump" to the top — we restore the reading position if UIKit
            // reset it. But only within the new content: if the catalog
            // shrank, the previous offset may point past its end.
            // `contentSize` is recomputed by reloadData synchronously (from the height
            // estimates), a separate layout pass is not needed here.
            let target = clampedContentOffset(previousOffset)
            if tableView.contentOffset != target {
                tableView.setContentOffset(target, animated: false)
            }
        } else {
            // Only the state changed (pin/unpin, icon): we rebuild
            // the visible rows. reloadData is not needed here, and in VoiceOver
            // mode it would also reset the focus from the row being read.
            for indexPath in tableView.indexPathsForVisibleRows ?? [] {
                guard let cell = tableView.cellForRow(at: indexPath) else { continue }
                configure(cell, at: indexPath)
            }
        }
    }

    /// The table composition (sections and rows) for comparison, including the settings section.
    private func makeStructure() -> [SectionSignature] {
        var result = sections.map { section in
            SectionSignature(
                title: section.title,
                rows: section.entries.map { RowSignature(id: $0.id, title: $0.title) }
            )
        }
        if !settingsItems.isEmpty {
            result.append(
                SectionSignature(
                    title: texts.settingsSectionTitle,
                    rows: settingsItems.map { RowSignature(id: $0.id, title: $0.title) }
                )
            )
        }
        return result
    }

    /// The tile row state — what changes without changing the row set:
    /// "pinned" (unpin via the grid, pin via the page) and the tile icon.
    private func makeRowStates() -> [[RowState]] {
        sections.map { section in
            section.entries.map { RowState(isPinned: $0.isPinned, icon: $0.icon) }
        }
    }

    /// Clamps an offset to the valid range of the current table content.
    ///
    /// - Parameter offset: The desired offset (the reading position before the reload).
    /// - Returns: The nearest offset within `contentSize`, taking into account
    ///   `adjustedContentInset`.
    private func clampedContentOffset(_ offset: CGPoint) -> CGPoint {
        let inset = tableView.adjustedContentInset
        let size = tableView.contentSize
        let visible = tableView.bounds.size
        let minX = -inset.left
        let minY = -inset.top
        let maxX = max(minX, size.width + inset.right - visible.width)
        let maxY = max(minY, size.height + inset.bottom - visible.height)
        return CGPoint(
            x: min(max(offset.x, minX), maxX),
            y: min(max(offset.y, minY), maxY)
        )
    }

    /// Pins or unpins a tile through the store (§6).
    ///
    /// Pin goes through ``TesseraTileStore/pinTile(_:columns:)`` — the tile
    /// lands in a new row at the end of the canvas (D33), holes above are not filled.
    /// The list sections are built from the catalog and do not depend on the position on the grid —
    /// the grid learns the new layout through the host's `onChange`.
    ///
    /// Unpin goes through ``TesseraTileStore/unpin(_:columns:)``: the tile's cell stays
    /// as a hole, and then ``TesseraTileStore/collapseEmptyRows(columns:)`` removes only a
    /// fully empty row (D31). These are two model changes (the second is a no-op
    /// without a notification if there are no empty rows).
    ///
    /// The method is internal (not `private`) because the same action is performed by the
    /// row button and the VoiceOver custom action; page tests call
    /// it directly (UI events in the test runner are unreliable) and separately
    /// check the button wiring through metadata (target-action, accessibility).
    ///
    /// - Parameters:
    ///   - pinned: `true` to pin, `false` to unpin.
    ///   - tileID: The tile identifier from the catalog.
    /// - Returns: `true` if the store changed state.
    @discardableResult
    func setPinned(_ pinned: Bool, for tileID: AnyHashable) -> Bool {
        // Cell-based operations. The width is the page's columns, and if the host did not
        // pass them, the one the coordinator reported to the store (otherwise a foreign width
        // would overwrite the canvas, D32).
        let width = columns ?? store.effectiveColumns
        if pinned {
            return store.pinTile(tileID, columns: width)
        }
        guard store.unpin(tileID, columns: width) else { return false }
        // An emptied row collapses, a hole within a row stays (D31).
        store.collapseEmptyRows(columns: width)
        return true
    }

    // MARK: - Empty state

    /// Shows a placeholder when the list has neither tiles nor settings.
    private func updateEmptyState() {
        let hasRows = !sections.isEmpty || !settingsItems.isEmpty
        if hasRows {
            tableView.backgroundView = nil
            tableView.separatorStyle = .singleLine
        } else {
            emptyStateLabel?.text = texts.emptyTitle
            emptyStateLabel?.accessibilityLabel = texts.emptyTitle
            tableView.backgroundView = emptyStateView
            tableView.separatorStyle = .none
        }
    }

    /// Builds the empty state view (§9: an ordinary accessibility element).
    private func makeEmptyStateView() -> UIView {
        let container = UIView()

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = texts.emptyTitle
        label.textAlignment = .center
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.isAccessibilityElement = true
        label.accessibilityLabel = texts.emptyTitle
        emptyStateLabel = label

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -32),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])
        return container
    }

    // MARK: - Cells

    /// Dequeues a cell of the needed style, creating it on first use.
    ///
    /// Class registration does not fit: a registered `UITableViewCell`
    /// is created only in the `.default` style, while a settings row with an explanation needs
    /// `.subtitle`. The style is fixed by the identifier, so there is no mixing.
    private func dequeueCell(
        in tableView: UITableView,
        identifier: String,
        style: UITableViewCell.CellStyle
    ) -> UITableViewCell {
        tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: style, reuseIdentifier: identifier)
    }

    /// Configures a row by its position.
    ///
    /// - Parameters:
    ///   - cell: A reusable cell.
    ///   - indexPath: The row position.
    private func configure(_ cell: UITableViewCell, at indexPath: IndexPath) {
        if indexPath.section < sections.count {
            configureAppCell(cell, entry: sections[indexPath.section].entries[indexPath.row])
        } else {
            configureSettingsCell(cell, item: settingsItems[indexPath.section - sections.count])
        }
    }

    /// Configures a tile row.
    ///
    /// - Parameters:
    ///   - cell: The cell.
    ///   - entry: A tile with the "pinned" state.
    private func configureAppCell(_ cell: UITableViewCell, entry: AppEntry) {
        // Full configuration: the cell may previously have shown a settings row.
        cell.imageView?.image = iconImage(for: entry.icon)
        cell.imageView?.contentMode = .scaleAspectFit
        cell.textLabel?.text = entry.title
        cell.detailTextLabel?.text = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default
        cell.accessibilityHint = nil

        // §9: the row is a standard element; the tile title and state.
        cell.accessibilityLabel = entry.title
        cell.accessibilityValue = entry.isPinned ? texts.pinnedValue : nil
        cell.accessibilityTraits = .button

        let actionTitle = entry.isPinned ? texts.unpinActionTitle : texts.pinActionTitle
        let tileID = entry.id
        let isPinned = entry.isPinned

        // The same action is available through the VoiceOver rotor — the small button
        // in the accessory does not have to be found by touch.
        cell.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: actionTitle) { [weak self] _ in
                guard let self else { return false }
                return self.setPinned(!isPinned, for: tileID)
            },
        ]

        let button = pinButton(in: cell)
        button.setImage(Self.pinImage(pinned: entry.isPinned), for: .normal)
        button.accessibilityLabel = actionTitle
        button.onTap = { [weak self] in
            self?.setPinned(!isPinned, for: tileID)
        }
    }

    /// Configures a settings section row.
    ///
    /// - Parameters:
    ///   - cell: The cell.
    ///   - item: A row set by the host.
    private func configureSettingsCell(_ cell: UITableViewCell, item: TesseraAppsListSettingsItem) {
        cell.imageView?.image = iconImage(for: item.icon)
        cell.imageView?.contentMode = .scaleAspectFit
        cell.textLabel?.text = item.title
        cell.detailTextLabel?.text = item.subtitle
        cell.accessoryView = nil
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        cell.accessibilityLabel = item.title
        cell.accessibilityValue = item.subtitle
        cell.accessibilityHint = nil
        cell.accessibilityTraits = .button
        cell.accessibilityCustomActions = nil
    }

    /// Returns the row's accessory button, creating it if needed.
    ///
    /// - Parameter cell: A tile cell.
    /// - Returns: The pin button.
    private func pinButton(in cell: UITableViewCell) -> TesseraAppsListPinButton {
        if let existing = cell.accessoryView as? TesseraAppsListPinButton {
            return existing
        }
        let button = TesseraAppsListPinButton()
        cell.accessoryView = button
        return button
    }

    /// The pin button symbol.
    ///
    /// - Parameter pinned: The current state.
    /// - Returns: A pinned button is filled, an unpinned one is outlined.
    private static func pinImage(pinned: Bool) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        let name = pinned ? "pin.circle.fill" : "pin.circle"
        return UIImage(systemName: name, withConfiguration: configuration)
            ?? UIImage(systemName: "checkmark.circle", withConfiguration: configuration)
    }

    /// Fits a tile icon to the row size.
    ///
    /// A standard cell takes the natural `UIImage` size into account in layout,
    /// so a 1024×1024 icon would stretch the row to the full screen. We draw
    /// a thumbnail preserving proportions and cache it by the icon object.
    ///
    /// - Parameter icon: The original tile icon.
    /// - Returns: A thumbnail for the row's `imageView`.
    private func iconImage(for icon: UIImage?) -> UIImage? {
        guard let icon, icon.size.width > 0, icon.size.height > 0 else { return nil }
        if let cached = iconCache.object(forKey: icon) {
            return cached
        }

        let side = Self.iconSide
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let thumbnail = renderer.image { _ in
            let scale = min(side / icon.size.width, side / icon.size.height)
            let size = CGSize(width: icon.size.width * scale, height: icon.size.height * scale)
            let rect = CGRect(
                x: (side - size.width) / 2,
                y: (side - size.height) / 2,
                width: size.width,
                height: size.height
            )
            icon.draw(in: rect)
        }

        iconCache.setObject(thumbnail, forKey: icon)
        return thumbnail
    }

    // MARK: - Alphabetical index

    /// The collation section index for a tile title.
    ///
    /// Grouping is done by the `UILocalizedIndexedCollation` of the current locale: it
    /// folds diacritics ("É" → "E"), assigns ideographs to the sections of its own
    /// alphabet (in en/ru — "#", in zh — by pinyin), and puts digits, symbols,
    /// and emoji into the last section "#". An empty title also goes to "#".
    ///
    /// - Parameters:
    ///   - title: The tile title.
    ///   - collation: The index of the current locale.
    /// - Returns: The index in `collation.sectionTitles`.
    private static func collationSection(for title: String, collation: UILocalizedIndexedCollation) -> Int {
        let lastIndex = max(0, collation.sectionTitles.count - 1)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return lastIndex }
        let index = collation.section(
            for: CollationKey(trimmed),
            collationStringSelector: #selector(getter: CollationKey.title)
        )
        return min(max(0, index), lastIndex)
    }
}

// MARK: - UITableViewDataSource

extension TesseraAppsListPageViewController: UITableViewDataSource {

    /// The number of sections: the alphabet letters plus (if the host set it) the settings section.
    ///
    /// - Parameter tableView: The page table.
    /// - Returns: The number of sections.
    public func numberOfSections(in tableView: UITableView) -> Int {
        sections.count + (settingsItems.isEmpty ? 0 : 1)
    }

    /// The number of rows in a section.
    ///
    /// - Parameters:
    ///   - tableView: The page table.
    ///   - section: The section index.
    /// - Returns: The number of rows.
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section < sections.count {
            return sections[section].entries.count
        }
        return settingsItems.count
    }

    /// The section header: a letter or the settings section title.
    ///
    /// - Parameters:
    ///   - tableView: The page table.
    ///   - section: The section index.
    /// - Returns: The header, or `nil` if there is no settings section.
    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section < sections.count {
            return sections[section].title
        }
        return settingsItems.isEmpty ? nil : texts.settingsSectionTitle
    }

    /// The jump list titles (§6, §9): the full alphabet of the current
    /// locale's `UILocalizedIndexedCollation`, as in system lists;
    /// the settings section is not part of the index.
    ///
    /// - Parameter tableView: The page table.
    /// - Returns: The index titles, or `nil` if there are no tiles.
    public func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        sections.isEmpty ? nil : collation.sectionIndexTitles
    }

    /// Handles a jump on the jump list.
    ///
    /// The returned index is enough: UITableView scrolls the table to the section
    /// itself (document §6 — "a native pattern, nothing to invent").
    /// The index shows the whole alphabet while the table has only non-empty sections,
    /// so a letter without tiles leads to the nearest following non-empty section
    /// (after the last non-empty one — to the last).
    ///
    /// - Parameters:
    ///   - tableView: The page table.
    ///   - title: The letter the index was touched at.
    ///   - index: The title index in ``sectionIndexTitles(for:)``.
    /// - Returns: The index of the section jumped to.
    public func tableView(
        _ tableView: UITableView,
        sectionForSectionIndexTitle title: String,
        at index: Int
    ) -> Int {
        guard !sections.isEmpty else { return 0 }
        let target = collation.section(forSectionIndexTitle: index)
        return sections.firstIndex { $0.collationIndex >= target } ?? sections.count - 1
    }

    /// Creates and configures a list row.
    ///
    /// - Parameters:
    ///   - tableView: The page table.
    ///   - indexPath: The row position.
    /// - Returns: The ready cell.
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section < sections.count {
            let entry = sections[indexPath.section].entries[indexPath.row]
            let cell = dequeueCell(
                in: tableView,
                identifier: Self.defaultCellIdentifier,
                style: .default
            )
            configureAppCell(cell, entry: entry)
            return cell
        }

        let item = settingsItems[indexPath.section - sections.count]
        let hasSubtitle = item.subtitle != nil
        let cell = dequeueCell(
            in: tableView,
            identifier: hasSubtitle ? Self.subtitleCellIdentifier : Self.defaultCellIdentifier,
            style: hasSubtitle ? .subtitle : .default
        )
        configureSettingsCell(cell, item: item)
        return cell
    }
}

// MARK: - UITableViewDelegate

extension TesseraAppsListPageViewController: UITableViewDelegate {

    /// A tap on a row: a tile performs its action (D12), a setting performs its own.
    ///
    /// - Parameters:
    ///   - tableView: The page table.
    ///   - indexPath: The row position.
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if indexPath.section < sections.count {
            // D12: a tile is just an action; app cards and deep links
            // are cut from v1 (§10), so the page opens nothing by itself.
            sections[indexPath.section].entries[indexPath.row].descriptor.action()
            return
        }

        let settingsIndex = indexPath.section - sections.count
        guard settingsItems.indices.contains(settingsIndex) else { return }
        settingsItems[settingsIndex].action()
    }
}

// MARK: - Pin button

/// The row accessory button: pin or unpin a tile.
///
/// A separate accessibility element: VoiceOver announces the button by its action
/// ("Pin to start screen" / "Unpin"), while the row stays a button
/// for launching the app. The size is 44×44 points, the minimum touch target (§9).
private final class TesseraAppsListPinButton: UIButton {

    /// The tap action; updated when the cell is configured.
    var onTap: (() -> Void)?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    /// The button is not created from an archive.
    ///
    /// - Parameter coder: The archive decoder.
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TesseraAppsListPinButton can only be created programmatically")
    }

    /// Keeps a 44×44 point touch target (§9), even if the cell asks for the
    /// "natural" size from the image.
    override var intrinsicContentSize: CGSize {
        CGSize(width: 44, height: 44)
    }

    /// Keeps a 44×44 point touch target when the cell lays out the accessory.
    ///
    /// - Parameter size: The proposed size.
    /// - Returns: A fixed touch target size.
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: 44, height: 44)
    }

    /// Calls the row action.
    @objc private func handleTap() {
        onTap?()
    }
}

#endif
