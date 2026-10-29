//
//  LiveTileEngine.swift
//  TesseraStartScreen
//
//  Движок живых плиток рабочего стола: контент, подписки, флипы, стахгер и
//  паузы.
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md — §2 «Архитектура»
//  (LiveTileEngine — таймеры флипа и контент-провайдеры), §4 «Live-плитки
//  (движок)» (контентная модель, флип, стахгер, паузы, бэйдж, Reduce Motion),
//  §9 «Accessibility» (Reduce Motion, VoiceOver) и §10 «MVP» (флип простых
//  текстовых плиток, без push-обновлений). Уточнения пользователя — D12 и D15
//  в docs/STATE.md: ярлык-действие с бэйджем, live-плитки закладываются в E4.3.
//  Задача плана: E4.3 «LiveTileEngine (волна 1)».
//
//  Границы ответственности:
//  - движок не рисует плитку и не участвует в раскладке сетки: он читает
//    контент провайдера, подписывается на обновления и просит
//    ``TesseraLiveTileView`` показать нужную сторону;
//  - флип выполняется только трансформами слоёв (`CATransform3D` + m34) —
//    layout в горячем пути не участвует (§4, дисциплина из
//    CORE-IOS-DESIGN.md §2 и RISK.md R10);
//  - паузы: плитка вне экрана (visibility-колбэк хоста), приложение в фоне,
//    Reduce Motion (§4) — во всех трёх случаях новые флипы не запускаются;
//  - стахгер считается чистыми функциями ``TesseraLiveTileStaggerPlanner`` с
//    seedable-генератором: поведение воспроизводимо в тестах E4.7.
//

#if canImport(UIKit)
import UIKit
import TesseraCore

// MARK: - Контентная модель

/// Содержимое одной стороны live-плитки: фронта или бэка (§4, «Контентная
/// модель»).
///
/// Модель намеренно минимальна: MVP §10 ограничивает live-флип «простыми
/// текстовыми плитками». Иконка, заголовок и подпись покрывают фронт рабочего
/// стола (D12: `title`, `icon` ярлыка) и текстовый бэк. Цвета сторон —
/// презентационные: движок не знает о стилях сетки и не диктует палитру.
///
/// Бэйдж в содержимое стороны **не входит**: по §4 и D15 он живёт отдельным
/// view поверх контейнера и не участвует во флипе
/// (``TesseraLiveTileBadgeView``).
///
/// - Note: Значения читаются на главном потоке: `UIImage` и `UIColor` —
///   UIKit-объекты.
public struct TesseraLiveTileFace {

    /// Заголовок стороны: главная строка плитки.
    public var title: String

    /// Подпись стороны (`nil` — без подписи). На фронте обычно пусто, на бэке —
    /// короткая деталь: «3 новых», «Почта», дата.
    public var detail: String?

    /// Иконка стороны (`nil` — без иконки). View стороны рисует её шаблоном в
    /// цвете ``foregroundColor``, поэтому иконка должна быть одноцветной.
    public var icon: UIImage?

    /// Цвет фона стороны.
    public var backgroundColor: UIColor

    /// Цвет текста и иконки стороны.
    public var foregroundColor: UIColor

    /// Создаёт содержимое стороны live-плитки.
    ///
    /// - Parameters:
    ///   - title: Заголовок стороны.
    ///   - detail: Подпись стороны, по умолчанию `nil`.
    ///   - icon: Иконка стороны, по умолчанию `nil`.
    ///   - backgroundColor: Цвет фона, по умолчанию системный синий.
    ///   - foregroundColor: Цвет текста и иконки, по умолчанию белый.
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

// MARK: - Провайдер контента

/// Источник «живого» контента плитки (§4, «Контентная модель»).
///
/// Провайдер отдаёт две стороны и — опционально — подписку на обновления.
/// Движок вызывает ``startObservingChanges(_:)`` один раз при регистрации
/// плитки и отписывается при ``TesseraLiveTileEngine/unregister(_:)`` или
/// деинициализации. Для v1 достаточно таймера провайдера или явного
/// ``TesseraLiveTileEngine/refresh(_:)``: push-обновления отрезаны в §10.
///
/// - Important: Все методы вызываются на главном потоке. Провайдер не должен
///   удерживать плитку или движок: это создаёт цикл (движок удерживает
///   провайдера на время регистрации).
public protocol TesseraLiveTileContentProvider: AnyObject {

    /// Содержимое фронта. Читается движком при регистрации, обновлении и
    /// подписке `onChange`; в момент флипа используется уже прочитанное
    /// содержимое — путь флипа не перечитывает контент.
    var frontFace: TesseraLiveTileFace { get }

    /// Содержимое бэка; `nil` — у плитки нет обратной стороны, флипы не
    /// выполняются (§4: «опциональный бэк»).
    var backFace: TesseraLiveTileFace? { get }

    /// Подписка на обновления контента.
    ///
    /// Замыкание `onChange` может вызываться с любого потока: движок сам
    /// переадресует чтение контента на главный. Возвращаемая функция отмены
    /// вызывается один раз; `nil` — подписки нет (статичный контент или
    /// обновление только через ``TesseraLiveTileEngine/refresh(_:)``).
    ///
    /// - Parameter onChange: Колбэк «контент изменился».
    /// - Returns: Функция отмены подписки либо `nil`.
    func startObservingChanges(_ onChange: @escaping () -> Void) -> (() -> Void)?
}

public extension TesseraLiveTileContentProvider {

    /// По умолчанию у плитки нет бэка: одна сторона — статичная плитка.
    var backFace: TesseraLiveTileFace? { nil }

    /// По умолчанию подписки нет: контент обновляется явным
    /// ``TesseraLiveTileEngine/refresh(_:)`` (v1, §10).
    func startObservingChanges(_ onChange: @escaping () -> Void) -> (() -> Void)? { nil }
}

// MARK: - Планировщик стахгера

/// План одного цикла флипов: какие плитки, в каком пакете и с какой задержкой
/// стартуют (§4, «Стахгер»).
///
/// План — чистая функция от количества плиток и seed: одинаковый seed даёт
/// одинаковый план. Этим пользуются тесты E4.7 и ``TesseraLiveTileEngine``.
struct TesseraLiveTileFlipPlan {

    /// Запланированный флип одной плитки входного массива.
    struct Entry: Equatable {

        /// Индекс плитки во входном массиве (порядок регистрации).
        let index: Int

        /// Номер пакета: пакеты стартуют друг за другом через
        /// ``TesseraLiveTileStaggerPlanner/batchStagger``.
        let batch: Int

        /// Задержка старта от начала цикла: `batch × batchStagger + jitter`.
        let delay: TimeInterval
    }

    /// Запланированные флипы в порядке перемешивания.
    let entries: [Entry]

    /// Максимальная задержка цикла; по ней движок рассчитывает паузу до
    /// следующего цикла, чтобы флипы не накладывались.
    let maximumDelay: TimeInterval
}

/// Чистый расчёт стахгера: батчи и случайный разброс фаз (§4).
///
/// WP-поведение: плитки флипаются не одновременно, а пакетами; внутри пакета
/// старт дополнительно размазывается на случайную величину, иначе экран
/// выглядит синхронно и дёшево (§4). Планировщик не хранит состояние и не
/// трогает UI — это позволяет тестировать распределение без таймеров.
///
/// Порядок обхода плиток — детерминированная перестановка Фишера–Йетса на
/// ``TesseraSeededGenerator``. От неё зависит только визуальный порядок
/// пакетов; сама перестановка воспроизводима по seed.
struct TesseraLiveTileStaggerPlanner {

    /// Максимальное число плиток в одном пакете; минимум — 1.
    let batchSize: Int

    /// Пауза между стартами соседних пакетов.
    let batchStagger: TimeInterval

    /// Максимальная случайная добавка к старту плитки внутри пакета.
    let jitter: TimeInterval

    /// Seed генератора: одинаковый seed — одинаковый план.
    let seed: UInt64

    /// Создаёт планировщик; отрицательные значения зажимаются к нулю,
    /// `batchSize` — не меньше единицы.
    init(batchSize: Int, batchStagger: TimeInterval, jitter: TimeInterval, seed: UInt64) {
        self.batchSize = max(1, batchSize)
        self.batchStagger = max(0, batchStagger)
        self.jitter = max(0, jitter)
        self.seed = seed
    }

    /// Строит план флипов для `tileCount` плиток.
    ///
    /// Алгоритм:
    /// 1. перемешать индексы детерминированной перестановкой;
    /// 2. нарезать перемешанный порядок на пакеты по ``batchSize``;
    /// 3. пакет `k` стартует через `k × batchStagger`;
    /// 4. внутри пакета добавить каждому плитке случайную фазу `0...jitter`.
    ///
    /// Все плитки получают ровно один флип за цикл; стахгер меняет только
    /// моменты старта, а не число флипов.
    ///
    /// - Parameter tileCount: Число плиток в цикле; `0` — пустой план.
    /// - Returns: План с задержками и максимальной задержкой цикла.
    func plan(tileCount: Int) -> TesseraLiveTileFlipPlan {
        guard tileCount > 0 else {
            return TesseraLiveTileFlipPlan(entries: [], maximumDelay: 0)
        }

        var generator = TesseraSeededGenerator(seed: seed)
        var order = Array(0..<tileCount)

        // Перестановка Фишера–Йетса: не полагаемся на stdlib `shuffle`, чтобы
        // план не менялся между версиями Swift и в тестах.
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
            // 53 старших бита — равномерная дробь [0, 1) без потери точности.
            let fraction = Double(generator.next() >> 11) / 9_007_199_254_740_992.0
            let delay = Double(batch) * batchStagger + fraction * jitter
            entries.append(.init(index: index, batch: batch, delay: delay))
            maximumDelay = max(maximumDelay, delay)
        }

        return TesseraLiveTileFlipPlan(entries: entries, maximumDelay: maximumDelay)
    }
}

/// Seedable-генератор SplitMix64 для стахгера и тестов (§4).
///
/// Один и тот же seed даёт одну и ту же последовательность; это единственное,
/// что требуется от генератора планировщику. Реализация — SplitMix64: быстрая,
/// без состояния вне структуры и пригодная для детерминированных тестов.
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

    /// Равномерное значение `0..<upperBound` без modulo-смещения.
    ///
    /// Отбрасывание «хвоста» делает распределение точным; для визуального
    /// разброса это не принципиально, но тесты не должны зависеть от смещения.
    mutating func next(upperBound: UInt64) -> UInt64 {
        precondition(upperBound > 0, "upperBound должен быть положительным")
        let threshold = (0 &- upperBound) % upperBound
        while true {
            let value = next()
            if value >= threshold {
                return value % upperBound
            }
        }
    }
}

// MARK: - Движок

/// Движок живых плиток: подписки на контент, таймер флипов, стахгер и паузы
/// (docs/STARTSCREEN-IOS-DESIGN.md §2, §4).
///
/// Движок владеет расписанием, но не представлениями: хост регистрирует пару
/// «плитка + провайдер», сообщает видимость и при необходимости обновляет
/// контент явно. ``TesseraLiveTileView`` выполняет сам флип только
/// трансформами (§4), движок решает, *когда* его запускать.
///
/// ## Жизненный цикл и паузы (§4)
///
/// - плитка вне экрана: хост вызывает ``setVisible(_:for:)`` — новые флипы
///   плитки не запускаются, незавершённый флип сбрасывается без анимации;
/// - приложение в фоне: движок сам подписан на
///   `UIApplication.didEnterBackgroundNotification` / `willEnterForegroundNotification`
///   и замораживает все флипы;
/// - Reduce Motion: флипов нет, показывается статичный фронт. Провайдер
///   настройки инжектируется в инициализаторе; по умолчанию читается
///   ``TesseraAccessibility/isReduceMotionEnabled`` (та же системная
///   `UIAccessibility.isReduceMotionEnabled`, §9). Значение запрашивается в
///   момент решения, поэтому включение Reduce Motion «на лету» срабатывает
///   сразу — движок также слушает
///   `UIAccessibility.reduceMotionStatusDidChangeNotification`.
///
/// ## Стахгер (§4)
///
/// Раз в ``Configuration/cycleInterval`` движок строит план
/// ``TesseraLiveTileStaggerPlanner``: плитки делятся на пакеты, стартуют с
/// задержкой и случайным разбросом. План детерминирован seed'ом
/// ``Configuration/seed``. Следующий цикл планируется не раньше, чем
/// закончится текущий (`maximumDelay + flipDuration`), поэтому флипы не
/// накладываются.
///
/// ## Потоки
///
/// Вся работа — на главном потоке: таймер, уведомления и `DispatchWorkItem`
/// выполняются в main queue. Провайдер может вызывать `onChange` с любого
/// потока — движок переадресует чтение контента на главный.
///
/// - Important: Движок удерживает зарегистрированные плитки и провайдеров.
///   Переиспользуемая ячейка обязана вызвать ``unregister(_:)`` в
///   `prepareForReuse`, иначе движок будет держать её до деинициализации.
public final class TesseraLiveTileEngine {

    // MARK: - Конфигурация

    /// Параметры расписания флипов (§4).
    ///
    /// Все значения — «запросы»: движок зажимает их к безопасным границам,
    /// чтобы отрицательные или нулевые интервалы не сломали таймер и не
    /// зациклили планировщик. Конфигурация не хранит состояние и может
    /// меняться на лету — движок перепланирует цикл.
    public struct Configuration {

        /// Интервал между циклами флипов, секунды. По умолчанию 8 с: реже, чем
        /// у WP, чтобы не отвлекать, но заметно. Движок использует не меньше
        /// 0.5 с.
        public var cycleInterval: TimeInterval

        /// Длительность полного флипа одной плитки (половина — на одну
        /// сторону), секунды. По умолчанию 0.45 с; движок зажимает к
        /// `0.1...3`.
        public var flipDuration: TimeInterval

        /// Максимум плиток в одном пакете. По умолчанию 3; минимум — 1.
        public var batchSize: Int

        /// Пауза между стартами пакетов, секунды. По умолчанию 0.35 с;
        /// отрицательное значение — 0.
        public var batchStagger: TimeInterval

        /// Максимальная случайная добавка к фазе внутри пакета, секунды. По
        /// умолчанию 0.35 с; отрицательное значение — 0.
        public var jitter: TimeInterval

        /// Seed перестановки и фаз. По умолчанию фиксированный — так план
        /// воспроизводим в тестах; хост может передать случайное значение,
        /// чтобы при каждом запуске порядок пакетов был разным.
        ///
        /// Движок использует `seed` как базу: каждый следующий цикл сдвигает
        /// его на номер цикла (см. расчёт расписания), иначе порядок пакетов
        /// повторялся бы каждые `cycleInterval` секунд. Последовательность при
        /// этом остаётся полностью воспроизводимой.
        public var seed: UInt64

        /// Создаёт конфигурацию расписания.
        ///
        /// - Parameters:
        ///   - cycleInterval: Интервал между циклами, по умолчанию 8 с.
        ///   - flipDuration: Длительность флипа, по умолчанию 0.45 с.
        ///   - batchSize: Максимум плиток в пакете, по умолчанию 3.
        ///   - batchStagger: Пауза между пакетами, по умолчанию 0.35 с.
        ///   - jitter: Случайный разброс фазы внутри пакета, по умолчанию
        ///     0.35 с.
        ///   - seed: Seed плана, по умолчанию фиксированный.
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

    // MARK: - Внутреннее состояние

    /// Запись о зарегистрированной плите: движок удерживает её и провайдера.
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

    /// Расписание флипов; присваивание перепланирует цикл и длительность
    /// анимации у зарегистрированных плиток.
    public var configuration: Configuration {
        didSet {
            registrations.forEach { $0.view.flipAnimationDuration = effectiveFlipDuration }
            cycleTimer?.invalidate()
            cycleTimer = nil
            scheduleIfPossible()
        }
    }

    /// Настройка Reduce Motion; инжектируется для тестов и для окружений без
    /// UIKit-настроек. Читается в момент решения, а не кешируется.
    private let reduceMotionProvider: () -> Bool

    private var registrations: [Registration] = []

    /// Таймер следующего цикла; `nil` — движок на паузе или нет подходящих
    /// плиток.
    private var cycleTimer: Timer?

    /// Отложенные флипы текущего цикла: отменяются при паузе.
    private var pendingFlips: [DispatchWorkItem] = []

    /// Поколение цикла: отложенный флип из прошлого поколения игнорируется.
    private var cycleGeneration: UInt64 = 0

    /// Приложение активно (не в фоне). В фоне таймер и флипы заморожены.
    private var isApplicationActive: Bool

    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var reduceMotionObserver: NSObjectProtocol?

    // MARK: - Инициализация

    /// Создаёт движок.
    ///
    /// - Parameters:
    ///   - configuration: Параметры стахгера и таймера, по умолчанию — 8 с
    ///     между циклами, пакеты по 3 плитки.
    ///   - isReduceMotionEnabled: Провайдер Reduce Motion. По умолчанию —
    ///     системная настройка через ``TesseraAccessibility/isReduceMotionEnabled``.
    ///     При `true` движок не запускает флипы и держит плитки на фронте (§4).
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

    // MARK: - Публичный API

    /// Регистрирует плитку и её провайдера (§2, §4).
    ///
    /// Движок сразу читает обе стороны, подписывается на обновления и
    /// запускает расписание, если плитка видима и у неё есть бэк. Повторная
    /// регистрация того же view заменяет прежнюю запись.
    ///
    /// - Parameters:
    ///   - view: Контейнер плитки; движок удерживает его до
    ///     ``unregister(_:)``.
    ///   - provider: Источник контента; удерживается до ``unregister(_:)``.
    ///   - isVisible: Видима ли плитка в момент регистрации. Хост обязан
    ///     обновлять это значение через ``setVisible(_:for:)`` при появлении и
    ///     уходе с экрана (§4, «Паузы»).
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

    /// Снимает регистрацию плитки и отписывается от обновлений.
    ///
    /// Незавершённый флип сбрасывается без анимации, чтобы ячейка ушла в
    /// переиспользование в устоявшемся состоянии.
    ///
    /// - Parameter view: Ранее зарегистрированный контейнер плитки. Для
    ///   незарегистрированного view вызов ничего не делает.
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

    /// Сообщает движку, видима ли плитка на экране (§4, «Паузы»).
    ///
    /// Невидимая плитка не флипается; её незавершённый флип сбрасывается.
    /// Когда видимость возвращается, плитка снова попадает в расписание.
    ///
    /// - Parameters:
    ///   - isVisible: Видимость, вычисленная хостом по `layoutAttributes`.
    ///   - view: Зарегистрированный контейнер плитки; для незарегистрированного
    ///     view вызов ничего не делает.
    public func setVisible(_ isVisible: Bool, for view: TesseraLiveTileView) {
        guard let registration = registration(for: view), registration.isVisible != isVisible else { return }

        registration.isVisible = isVisible
        if !isVisible && view.isFlipping {
            view.cancelFlip()
        }
        scheduleIfPossible()
    }

    /// Явно перечитывает контент провайдера и обновляет стороны плитки.
    ///
    /// Нужен провайдерам без подписки (v1, §10): после изменения своего
    /// состояния провайдер просит хост вызвать этот метод. Подписанные
    /// провайдеры получают то же самое через `onChange` автоматически.
    ///
    /// Обновление не запускает флип: расписание остаётся прежним.
    ///
    /// - Parameter view: Зарегистрированный контейнер плитки.
    public func refresh(_ view: TesseraLiveTileView) {
        guard let registration = registration(for: view) else { return }
        reloadContent(for: registration)
    }

    // MARK: - Расписание

    private var effectiveFlipDuration: TimeInterval {
        min(max(configuration.flipDuration, 0.1), 3)
    }

    private var effectiveCycleInterval: TimeInterval {
        max(configuration.cycleInterval, 0.5)
    }

    /// Есть ли что флипать и можно ли это делать сейчас.
    ///
    /// Проверка видимости `window` здесь намеренно не делается: плитка может
    /// быть зарегистрирована до добавления в иерархию, и тогда таймер не
    /// запустится вовсе. Окно проверяется непосредственно перед флипом.
    private var canSchedule: Bool {
        !isPaused && registrations.contains { $0.isVisible && $0.provider.backFace != nil }
    }

    private var isPaused: Bool {
        !isApplicationActive || reduceMotionProvider()
    }

    /// Перезапускает или останавливает таймер под текущее состояние.
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
        // .common — таймер продолжает идти во время трекинга скролла таблицы
        // или коллекции, иначе Live-плитки «замирают» под пальцем.
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

        // Номер цикла — и для защиты от устаревших отложенных флипов, и для
        // эволюции seed: с фиксированным seed порядок пакетов повторялся бы
        // каждые cycleInterval секунд.
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

        // К этому моменту отложенные флипы прошлого цикла уже отработали:
        // следующий цикл планируется не раньше их максимальной задержки.
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

        // Следующий цикл — не раньше конца текущего, иначе пакеты наложатся
        // и стахгер превратится в синхронный флип всего экрана.
        let nextCycle = max(effectiveCycleInterval, plan.maximumDelay + effectiveFlipDuration + 0.1)
        scheduleCycle(after: nextCycle)
    }

    /// Выполняет один запланированный флип с повторной проверкой всех пауз
    /// (§4): за время задержки плитка могла уйти с экрана или приложение — в фон.
    ///
    /// Контент здесь не перечитывается: стороны уже обновлены подпиской
    /// `onChange` или явным ``refresh(_:)``. Это принципиально для дисциплины
    /// §4 — путь флипа не должен приводить к layout-проходу плитки.
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

    // MARK: - Контент

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

    // MARK: - Паузы

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

    /// Замораживает всё: таймер, отложенные флипы и текущие анимации.
    ///
    /// Текущий флип сбрасывается без анимации на устоявшуюся сторону — иначе
    /// при возврате из фона плитка могла бы остаться «ребром» или с
    /// недорисованной стороной.
    private func freezeAllFlips() {
        cycleTimer?.invalidate()
        cycleTimer = nil
        cancelPendingFlips()

        for registration in registrations where registration.view.isFlipping {
            registration.view.cancelFlip()
        }
    }

    // MARK: - Потоки

    private func performOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

#endif
