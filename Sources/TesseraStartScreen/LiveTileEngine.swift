//
//  LiveTileEngine.swift
//  TesseraStartScreen
//
//  The live tile engine of the start screen: content, subscriptions, flips, stagger, and
//  pauses.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md — §2 "Architecture"
//  (LiveTileEngine — flip timers and content providers), §4 "Live tiles
//  (engine)" (content model, flip, stagger, pauses, badge, Reduce Motion),
//  §9 "Accessibility" (Reduce Motion, VoiceOver), and §10 "MVP" (flip of simple
//  text tiles, no push updates). User clarifications — D12 and D15
//  in docs/DECISIONS.md: an action tile with a badge; live tiles are part of the design.
//
//  Responsibilities:
//  - the engine neither draws a tile nor takes part in the grid layout: it reads the
//    provider content, subscribes to updates, and asks
//    ``TesseraLiveTileView`` to show the right face;
//  - a flip is performed only by layer transforms (`CATransform3D` + m34) —
//    layout is not involved in the hot path (§4, the discipline from
//    CORE-IOS-DESIGN.md §2 and RISKS.md R10);
//  - pauses: a tile off screen (the host's visibility callback), the app in the background,
//    Reduce Motion (§4) — in all three cases no new flips are started;
//  - stagger is computed by the pure functions of ``TesseraLiveTileStaggerPlanner`` with a
//    seedable generator: the behavior is reproducible in tests.
//

#if canImport(UIKit)
import UIKit
import TesseraCore

// MARK: - Content model

/// The content of one face of a live tile: the front or the back (§4, "Content
/// model").
///
/// The model is intentionally minimal: the MVP (§10) limits the live flip to "simple
/// text tiles". The icon, title, and detail cover the start screen front
/// (D12: the tile's `title` and `icon`) and a text back. The face colors are
/// presentational: the engine knows nothing about grid styles and does not dictate a palette.
///
/// The badge is **not part** of a face's content: per §4 and D15 it lives in a separate
/// view above the container and does not take part in the flip
/// (``TesseraLiveTileBadgeView``).
///
/// - Note: Values are read on the main thread: `UIImage` and `UIColor` are
///   UIKit objects.
public struct TesseraLiveTileFace {

    /// The face title: the main line of the tile.
    public var title: String

    /// The face detail (`nil` means no detail). Usually empty on the front, on the back a
    /// short note: "3 new", "Mail", a date.
    public var detail: String?

    /// The face icon (`nil` means no icon). The face view draws it as a template in
    /// ``foregroundColor``, so the icon must be single-color.
    ///
    /// A large icon is not stored on the tile at its original size: the face
    /// decodes it for its slot × the screen scale and caches the copy by the
    /// **identity** of the `UIImage` object (§4, "Memory"). So it pays
    /// for the provider to return the same object rather than creating a new `UIImage`
    /// on every face read — otherwise every content update is
    /// a cache miss and a new render.
    public var icon: UIImage?

    /// The face background color.
    public var backgroundColor: UIColor

    /// The face text and icon color.
    public var foregroundColor: UIColor

    /// Creates the content of a live tile face.
    ///
    /// - Parameters:
    ///   - title: The face title.
    ///   - detail: The face detail; `nil` by default.
    ///   - icon: The face icon; `nil` by default.
    ///   - backgroundColor: The background color; the system blue by default.
    ///   - foregroundColor: The text and icon color; white by default.
    public init(
        title: String,
        detail: String? = nil,
        icon: UIImage? = nil,
        backgroundColor: UIColor = .systemBlue,
        foregroundColor: UIColor = .white
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
    }
}

// MARK: - Content provider

/// The source of a tile's "live" content (§4, "Content model").
///
/// A provider supplies two faces and, optionally, a subscription to updates.
/// The engine calls ``startObservingChanges(_:)`` once when the tile is
/// registered and unsubscribes on ``TesseraLiveTileEngine/unregister(_:)`` or
/// deinitialization. For v1 a provider timer or an explicit
/// ``TesseraLiveTileEngine/refresh(_:)`` is enough: push updates are out of scope (§10).
///
/// - Important: All methods are called on the main thread. A provider must not
///   retain the tile or the engine: that creates a cycle (the engine retains the
///   provider for the duration of the registration).
public protocol TesseraLiveTileContentProvider: AnyObject {

    /// The front content. Read by the engine on registration, on update, and on the
    /// `onChange` subscription; at flip time the already-read
    /// content is used — the flip path does not re-read content.
    var frontFace: TesseraLiveTileFace { get }

    /// The back content; `nil` means the tile has no back side and no flips
    /// are performed (§4: "optional back").
    var backFace: TesseraLiveTileFace? { get }

    /// A subscription to content updates.
    ///
    /// The `onChange` closure may be called from any thread: the engine itself
    /// forwards the content read to the main thread. The returned cancel function
    /// is called once; `nil` means no subscription (static content or
    /// an update only via ``TesseraLiveTileEngine/refresh(_:)``).
    ///
    /// - Parameter onChange: The "content changed" callback.
    /// - Returns: A cancel function for the subscription, or `nil`.
    func startObservingChanges(_ onChange: @escaping () -> Void) -> (() -> Void)?
}

public extension TesseraLiveTileContentProvider {

    /// By default a tile has no back: one face means a static tile.
    var backFace: TesseraLiveTileFace? { nil }

    /// By default there is no subscription: content is updated by an explicit
    /// ``TesseraLiveTileEngine/refresh(_:)`` (v1, §10).
    func startObservingChanges(_ onChange: @escaping () -> Void) -> (() -> Void)? { nil }
}

// MARK: - Stagger planner

/// The plan of one flip cycle: which tiles, in which batch, and with what delay
/// start (§4, "Stagger").
///
/// The plan is a pure function of the tile count and the seed: the same seed gives
/// the same plan. Tests and ``TesseraLiveTileEngine`` rely on this.
struct TesseraLiveTileFlipPlan {

    /// A scheduled flip of one tile of the input array.
    struct Entry: Equatable {

        /// The tile index in the input array (the registration order).
        let index: Int

        /// The batch number: batches start one after another with
        /// ``TesseraLiveTileStaggerPlanner/batchStagger``.
        let batch: Int

        /// The start delay from the cycle start: `batch × batchStagger + jitter`.
        let delay: TimeInterval
    }

    /// The scheduled flips in shuffled order.
    let entries: [Entry]

    /// The maximum delay of the cycle; the engine uses it to compute the pause before
    /// the next cycle so that flips do not overlap.
    let maximumDelay: TimeInterval
}

/// A pure stagger calculation: batches and a random phase spread (§4).
///
/// Windows Phone behavior: tiles do not flip simultaneously but in batches; within a batch
/// the start is additionally smeared by a random amount, otherwise the screen
/// looks synchronous and cheap (§4). The planner holds no state and
/// does not touch the UI — this allows testing the distribution without timers.
///
/// The tile traversal order is a deterministic Fisher–Yates shuffle on
/// ``TesseraSeededGenerator``. Only the visual order of the batches depends on it;
/// the shuffle itself is reproducible from the seed.
struct TesseraLiveTileStaggerPlanner {

    /// The maximum number of tiles in one batch; the minimum is 1.
    let batchSize: Int

    /// The pause between the starts of adjacent batches.
    let batchStagger: TimeInterval

    /// The maximum random addition to a tile's start within a batch.
    let jitter: TimeInterval

    /// The generator seed: the same seed gives the same plan.
    let seed: UInt64

    /// Creates a planner; negative values are clamped to zero,
    /// `batchSize` is at least one.
    init(batchSize: Int, batchStagger: TimeInterval, jitter: TimeInterval, seed: UInt64) {
        self.batchSize = max(1, batchSize)
        self.batchStagger = max(0, batchStagger)
        self.jitter = max(0, jitter)
        self.seed = seed
    }

    /// Builds the flip plan for `tileCount` tiles.
    ///
    /// The algorithm:
    /// 1. shuffle the indices with a deterministic permutation;
    /// 2. cut the shuffled order into batches of ``batchSize``;
    /// 3. batch `k` starts after `k × batchStagger`;
    /// 4. within a batch add a random phase `0...jitter` to each tile.
    ///
    /// Every tile gets exactly one flip per cycle; stagger changes only
    /// the start moments, not the number of flips.
    ///
    /// - Parameter tileCount: The number of tiles in the cycle; `0` means an empty plan.
    /// - Returns: A plan with delays and the maximum delay of the cycle.
    func plan(tileCount: Int) -> TesseraLiveTileFlipPlan {
        guard tileCount > 0 else {
            return TesseraLiveTileFlipPlan(entries: [], maximumDelay: 0)
        }

        var generator = TesseraSeededGenerator(seed: seed)
        var order = Array(0..<tileCount)

        // Fisher–Yates shuffle: we do not rely on the stdlib `shuffle`, so that the
        // plan does not change between Swift versions and in tests.
        if tileCount > 1 {
            for position in stride(from: tileCount - 1, through: 1, by: -1) {
                let swapIndex = Int(generator.next(upperBound: UInt64(position + 1)))
                order.swapAt(position, swapIndex)
            }
        }

        var entries: [TesseraLiveTileFlipPlan.Entry] = []
        entries.reserveCapacity(tileCount)
        var maximumDelay: TimeInterval = 0

        for (position, index) in order.enumerated() {
            let batch = position / batchSize
            // The top 53 bits give a uniform fraction in [0, 1) without losing precision.
            let fraction = Double(generator.next() >> 11) / 9_007_199_254_740_992.0
            let delay = Double(batch) * batchStagger + fraction * jitter
            entries.append(.init(index: index, batch: batch, delay: delay))
            maximumDelay = max(maximumDelay, delay)
        }

        return TesseraLiveTileFlipPlan(entries: entries, maximumDelay: maximumDelay)
    }
}

/// A seedable SplitMix64 generator for stagger and tests (§4).
///
/// The same seed gives the same sequence; this is the only thing
/// the planner needs from a generator. The implementation is SplitMix64: fast,
/// with no state outside the struct and suitable for deterministic tests.
struct TesseraSeededGenerator: RandomNumberGenerator {

    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// A uniform value in `0..<upperBound` without modulo bias.
    ///
    /// Rejecting the "tail" makes the distribution exact; for visual
    /// spread this is not essential, but tests must not depend on bias.
    mutating func next(upperBound: UInt64) -> UInt64 {
        precondition(upperBound > 0, "upperBound must be positive")
        let threshold = (0 &- upperBound) % upperBound
        while true {
            let value = next()
            if value >= threshold {
                return value % upperBound
            }
        }
    }
}

// MARK: - Engine

/// The live tile engine: content subscriptions, the flip timer, stagger, and pauses
/// (docs/STARTSCREEN-IOS-DESIGN.md §2, §4).
///
/// The engine owns the schedule but not the views: the host registers a "tile + provider"
/// pair, reports visibility, and updates content explicitly when needed.
/// ``TesseraLiveTileView`` performs the flip itself using
/// transforms only (§4); the engine decides *when* to start it.
///
/// ## Lifecycle and pauses (§4)
///
/// - tile off screen: the host calls ``setVisible(_:for:)`` — new flips of
///   the tile are not started, and an unfinished flip is reset without animation;
/// - app in the background: the engine itself subscribes to
///   `UIApplication.didEnterBackgroundNotification` / `willEnterForegroundNotification`
///   and freezes all flips;
/// - Reduce Motion: no flips, a static front is shown. The setting
///   provider is injected in the initializer; by default
///   ``TesseraAccessibility/isReduceMotionEnabled`` is read (the same system
///   `UIAccessibility.isReduceMotionEnabled`, §9). The value is queried at the
///   moment of decision, so enabling Reduce Motion on the fly takes effect
///   immediately — the engine also listens to
///   `UIAccessibility.reduceMotionStatusDidChangeNotification`.
///
/// ## Stagger (§4)
///
/// Once per ``Configuration/cycleInterval`` the engine builds a plan with
/// ``TesseraLiveTileStaggerPlanner``: tiles are divided into batches, start with
/// a delay and a random spread. The plan is deterministic by the seed
/// ``Configuration/seed``. The next cycle is scheduled no earlier than
/// the current one ends (`maximumDelay + flipDuration`), so flips do not
/// overlap.
///
/// ## Threads
///
/// All work is on the main thread: the timer, notifications, and `DispatchWorkItem`
/// run on the main queue. A provider may call `onChange` from any
/// thread — the engine forwards the content read to the main one.
///
/// - Important: The engine retains the registered tiles and providers.
///   A reusable cell must call ``unregister(_:)`` in
///   `prepareForReuse`, otherwise the engine will hold it until deinitialization.
public final class TesseraLiveTileEngine {

    // MARK: - Configuration

    /// The flip schedule parameters (§4).
    ///
    /// All values are "requests": the engine clamps them to safe bounds
    /// so that negative or zero intervals do not break the timer or
    /// make the planner loop. The configuration holds no state and may
    /// change on the fly — the engine reschedules the cycle.
    public struct Configuration {

        /// The interval between flip cycles, in seconds. 8 s by default: less frequent than
        /// on Windows Phone so as not to distract, but still noticeable. The engine uses at least
        /// 0.5 s.
        public var cycleInterval: TimeInterval

        /// The duration of a full flip of one tile (half of it for one
        /// face), in seconds. 0.45 s by default; the engine clamps it to
        /// `0.1...3`.
        public var flipDuration: TimeInterval

        /// The maximum number of tiles in one batch. 3 by default; the minimum is 1.
        public var batchSize: Int

        /// The pause between batch starts, in seconds. 0.35 s by default;
        /// a negative value means 0.
        public var batchStagger: TimeInterval

        /// The maximum random addition to the phase within a batch, in seconds.
        /// 0.35 s by default; a negative value means 0.
        public var jitter: TimeInterval

        /// The seed of the shuffle and phases. Fixed by default, so the plan
        /// is reproducible in tests; the host may pass a random value
        /// so that the batch order differs on every launch.
        ///
        /// The engine uses `seed` as a base: every next cycle shifts
        /// it by the cycle number (see the schedule computation), otherwise the batch order
        /// would repeat every `cycleInterval` seconds. The sequence
        /// still remains fully reproducible.
        public var seed: UInt64

        /// Creates the schedule configuration.
        ///
        /// - Parameters:
        ///   - cycleInterval: The interval between cycles; 8 s by default.
        ///   - flipDuration: The flip duration; 0.45 s by default.
        ///   - batchSize: The maximum number of tiles in a batch; 3 by default.
        ///   - batchStagger: The pause between batches; 0.35 s by default.
        ///   - jitter: The random phase spread within a batch;
        ///     0.35 s by default.
        ///   - seed: The plan seed; fixed by default.
        public init(
            cycleInterval: TimeInterval = 8,
            flipDuration: TimeInterval = 0.45,
            batchSize: Int = 3,
            batchStagger: TimeInterval = 0.35,
            jitter: TimeInterval = 0.35,
            seed: UInt64 = 0xE4_0003_0000_0001
        ) {
            self.cycleInterval = cycleInterval
            self.flipDuration = flipDuration
            self.batchSize = batchSize
            self.batchStagger = batchStagger
            self.jitter = jitter
            self.seed = seed
        }
    }

    // MARK: - Internal state

    /// A record of a registered tile: the engine retains it and its provider.
    private final class Registration {

        let view: TesseraLiveTileView
        let provider: TesseraLiveTileContentProvider

        var isVisible: Bool
        var isActive = true
        var cancelObservation: (() -> Void)?

        init(view: TesseraLiveTileView, provider: TesseraLiveTileContentProvider, isVisible: Bool) {
            self.view = view
            self.provider = provider
            self.isVisible = isVisible
        }
    }

    /// The flip schedule; assigning to it reschedules the cycle and the
    /// animation duration of the registered tiles.
    public var configuration: Configuration {
        didSet {
            registrations.forEach { $0.view.flipAnimationDuration = effectiveFlipDuration }
            cycleTimer?.invalidate()
            cycleTimer = nil
            scheduleIfPossible()
        }
    }

    /// The Reduce Motion setting; injected for tests and for environments without
    /// UIKit settings. Read at the moment of decision, not cached.
    private let reduceMotionProvider: () -> Bool

    private var registrations: [Registration] = []

    /// The timer of the next cycle; `nil` means the engine is paused or there are no suitable
    /// tiles.
    private var cycleTimer: Timer?

    /// Deferred flips of the current cycle: cancelled on pause.
    private var pendingFlips: [DispatchWorkItem] = []

    /// The cycle generation: a deferred flip from a previous generation is ignored.
    private var cycleGeneration: UInt64 = 0

    /// The app is active (not in the background). In the background the timer and flips are frozen.
    private var isApplicationActive: Bool

    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var reduceMotionObserver: NSObjectProtocol?

    // MARK: - Initialization

    /// Creates the engine.
    ///
    /// - Parameters:
    ///   - configuration: The stagger and timer parameters; by default 8 s
    ///     between cycles, batches of 3 tiles.
    ///   - isReduceMotionEnabled: The Reduce Motion provider. By default
    ///     the system setting via ``TesseraAccessibility/isReduceMotionEnabled``.
    ///     With `true` the engine does not start flips and keeps tiles on the front (§4).
    public init(
        configuration: Configuration = Configuration(),
        isReduceMotionEnabled: @escaping () -> Bool = { TesseraAccessibility.isReduceMotionEnabled }
    ) {
        self.configuration = configuration
        self.reduceMotionProvider = isReduceMotionEnabled
        self.isApplicationActive = UIApplication.shared.applicationState != .background
        installObservers()
    }

    deinit {
        cycleTimer?.invalidate()
        pendingFlips.forEach { $0.cancel() }
        registrations.forEach { registration in
            registration.isActive = false
            registration.cancelObservation?()
        }
        let center = NotificationCenter.default
        if let backgroundObserver { center.removeObserver(backgroundObserver) }
        if let foregroundObserver { center.removeObserver(foregroundObserver) }
        if let reduceMotionObserver { center.removeObserver(reduceMotionObserver) }
    }

    // MARK: - Public API

    /// Registers a tile and its provider (§2, §4).
    ///
    /// The engine immediately reads both faces, subscribes to updates, and
    /// starts the schedule if the tile is visible and has a back. Registering
    /// the same view again replaces the previous record.
    ///
    /// - Parameters:
    ///   - view: The tile container; the engine retains it until
    ///     ``unregister(_:)``.
    ///   - provider: The content source; retained until ``unregister(_:)``.
    ///   - isVisible: Whether the tile is visible at registration time. The host must
    ///     update this value through ``setVisible(_:for:)`` when the tile appears and
    ///     leaves the screen (§4, "Pauses").
    public func register(
        _ view: TesseraLiveTileView,
        provider: TesseraLiveTileContentProvider,
        isVisible: Bool = true
    ) {
        unregister(view)

        let registration = Registration(view: view, provider: provider, isVisible: isVisible)
        view.flipAnimationDuration = effectiveFlipDuration
        view.setFaces(front: provider.frontFace, back: provider.backFace)
        if reduceMotionProvider() {
            view.show(.front, animated: false)
        }

        registration.cancelObservation = provider.startObservingChanges { [weak self, weak registration] in
            guard let self, let registration else { return }
            self.performOnMain { [weak self, weak registration] in
                guard let self, let registration else { return }
                self.reloadContent(for: registration)
            }
        }

        registrations.append(registration)
        scheduleIfPossible()
    }

    /// Unregisters a tile and unsubscribes from updates.
    ///
    /// An unfinished flip is reset without animation so that the cell goes to
    /// reuse in a settled state.
    ///
    /// - Parameter view: A previously registered tile container. For an
    ///   unregistered view the call does nothing.
    public func unregister(_ view: TesseraLiveTileView) {
        guard let index = registrations.firstIndex(where: { $0.view === view }) else { return }

        let registration = registrations.remove(at: index)
        registration.isActive = false
        registration.cancelObservation?()
        registration.cancelObservation = nil

        if view.isFlipping {
            view.cancelFlip()
        }
        scheduleIfPossible()
    }

    /// Tells the engine whether a tile is visible on screen (§4, "Pauses").
    ///
    /// An invisible tile does not flip; its unfinished flip is reset.
    /// When visibility returns, the tile gets back into the schedule.
    ///
    /// - Parameters:
    ///   - isVisible: The visibility computed by the host from `layoutAttributes`.
    ///   - view: A registered tile container; for an unregistered
    ///     view the call does nothing.
    public func setVisible(_ isVisible: Bool, for view: TesseraLiveTileView) {
        guard let registration = registration(for: view), registration.isVisible != isVisible else { return }

        registration.isVisible = isVisible
        if !isVisible && view.isFlipping {
            view.cancelFlip()
        }
        scheduleIfPossible()
    }

    /// Explicitly re-reads the provider content and updates the tile faces.
    ///
    /// Needed for providers without a subscription (v1, §10): after its own state
    /// changes, the provider asks the host to call this method. Subscribed
    /// providers get the same through `onChange` automatically.
    ///
    /// An update does not start a flip: the schedule stays as it was.
    ///
    /// - Parameter view: A registered tile container.
    public func refresh(_ view: TesseraLiveTileView) {
        guard let registration = registration(for: view) else { return }
        reloadContent(for: registration)
    }

    // MARK: - Schedule

    private var effectiveFlipDuration: TimeInterval {
        min(max(configuration.flipDuration, 0.1), 3)
    }

    private var effectiveCycleInterval: TimeInterval {
        max(configuration.cycleInterval, 0.5)
    }

    /// Whether there is anything to flip and whether it can be done now.
    ///
    /// The visibility of the `window` is intentionally not checked here: a tile may
    /// be registered before being added to the hierarchy, and then the timer would
    /// never start. The window is checked right before the flip.
    private var canSchedule: Bool {
        !isPaused && registrations.contains { $0.isVisible && $0.provider.backFace != nil }
    }

    private var isPaused: Bool {
        !isApplicationActive || reduceMotionProvider()
    }

    /// Restarts or stops the timer for the current state.
    private func scheduleIfPossible() {
        guard canSchedule else {
            cycleTimer?.invalidate()
            cycleTimer = nil
            cancelPendingFlips()
            return
        }

        guard cycleTimer == nil else { return }
        scheduleCycle(after: effectiveCycleInterval)
    }

    private func scheduleCycle(after interval: TimeInterval) {
        cycleTimer?.invalidate()

        let timer = Timer(timeInterval: max(0.1, interval), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.cycleTimer = nil
            self.runCycle()
        }
        cycleTimer = timer
        // .common — the timer keeps running while a table or collection scroll
        // is tracking, otherwise live tiles "freeze" under the finger.
        RunLoop.main.add(timer, forMode: .common)
    }

    private func runCycle() {
        guard canSchedule else {
            scheduleIfPossible()
            return
        }

        let eligible = registrations.filter { registration in
            registration.isActive
                && registration.isVisible
                && !registration.view.isFlipping
                && registration.provider.backFace != nil
        }
        guard !eligible.isEmpty else {
            scheduleIfPossible()
            return
        }

        // The cycle number serves both to guard against stale deferred flips and for
        // seed evolution: with a fixed seed the batch order would repeat
        // every cycleInterval seconds.
        cycleGeneration &+= 1
        let generation = cycleGeneration
        let plannerSeed = configuration.seed &+ generation &* 0x9E37_79B9_7F4A_7C15

        let planner = TesseraLiveTileStaggerPlanner(
            batchSize: configuration.batchSize,
            batchStagger: configuration.batchStagger,
            jitter: configuration.jitter,
            seed: plannerSeed
        )
        let plan = planner.plan(tileCount: eligible.count)

        // By this moment the deferred flips of the previous cycle have already run:
        // the next cycle is scheduled no earlier than their maximum delay.
        pendingFlips.removeAll()

        for entry in plan.entries {
            let registration = eligible[entry.index]
            let workItem = DispatchWorkItem { [weak self, weak registration] in
                guard let self, let registration, self.cycleGeneration == generation else { return }
                self.flip(registration)
            }
            pendingFlips.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + entry.delay, execute: workItem)
        }

        // The next cycle is no earlier than the end of the current one, otherwise batches overlap
        // and stagger turns into a synchronous flip of the whole screen.
        let nextCycle = max(effectiveCycleInterval, plan.maximumDelay + effectiveFlipDuration + 0.1)
        scheduleCycle(after: nextCycle)
    }

    /// Performs one scheduled flip, re-checking all pauses
    /// (§4): during the delay the tile may have left the screen or the app gone to the background.
    ///
    /// Content is not re-read here: the faces were already updated by the `onChange`
    /// subscription or an explicit ``refresh(_:)``. This is essential for the discipline of
    /// §4 — the flip path must not lead to a layout pass of the tile.
    private func flip(_ registration: Registration) {
        guard registration.isActive,
              registration.isVisible,
              !registration.view.isFlipping,
              isApplicationActive,
              !reduceMotionProvider(),
              registration.view.window != nil,
              registration.provider.backFace != nil
        else { return }

        let target: TesseraLiveTileView.Side = registration.view.side == .front ? .back : .front
        registration.view.show(target, animated: true)
    }

    private func cancelPendingFlips() {
        cycleGeneration &+= 1
        pendingFlips.forEach { $0.cancel() }
        pendingFlips.removeAll()
    }

    // MARK: - Content

    private func reloadContent(for registration: Registration) {
        guard registration.isActive,
              registrations.contains(where: { $0 === registration })
        else { return }

        registration.view.setFaces(
            front: registration.provider.frontFace,
            back: registration.provider.backFace
        )

        if reduceMotionProvider() {
            registration.view.show(.front, animated: false)
        }
        scheduleIfPossible()
    }

    private func registration(for view: TesseraLiveTileView) -> Registration? {
        registrations.first { $0.view === view }
    }

    // MARK: - Pauses

    private func installObservers() {
        let center = NotificationCenter.default

        backgroundObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applicationDidEnterBackground()
        }

        foregroundObserver = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applicationWillEnterForeground()
        }

        reduceMotionObserver = center.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reduceMotionStatusDidChange()
        }
    }

    private func applicationDidEnterBackground() {
        isApplicationActive = false
        freezeAllFlips()
    }

    private func applicationWillEnterForeground() {
        isApplicationActive = true
        scheduleIfPossible()
    }

    private func reduceMotionStatusDidChange() {
        if reduceMotionProvider() {
            freezeAllFlips()
            registrations.forEach { $0.view.show(.front, animated: false) }
        } else {
            scheduleIfPossible()
        }
    }

    /// Freezes everything: the timer, deferred flips, and current animations.
    ///
    /// The current flip is reset without animation to the settled face — otherwise
    /// on return from the background the tile might stay "edge-on" or with an
    /// unfinished face.
    private func freezeAllFlips() {
        cycleTimer?.invalidate()
        cycleTimer = nil
        cancelPendingFlips()

        for registration in registrations where registration.view.isFlipping {
            registration.view.cancelFlip()
        }
    }

    // MARK: - Threads

    private func performOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

#endif
