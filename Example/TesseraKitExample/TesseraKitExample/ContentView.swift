//
//  ContentView.swift
//  TesseraKitExample
//
//  Демо-хост четырёх библиотек TesseraKit для ручной проверки на iOS-симуляторе.
//
//  Совместимость: iOS 15+, Swift 5.9. Используется только API не новее iOS 15:
//  ObservableObject/@Published вместо @Observable, foregroundColor вместо
//  foregroundStyle, классические модификаторы .overlay/.background и т. п.
//
//  Вкладки:
//  1. «Стол»      — TileStore + TesseraTileGridView + TesseraTileEditCoordinator
//                   в UIViewControllerRepresentable (режим редактирования).
//  2. «Пивот»     — PivotView с четырьмя секциями и крупным заголовком.
//  3. «Панорама»  — PanoramaView с тремя секциями и сгенерированным фоном.
//  4. «Ядро»      — два TesseraPagerViewController (.paged и .snapping) и
//                   программные переходы go(toPage:animated:).
//

import Foundation
import SwiftUI
import UIKit
import Combine
import TesseraCore
import TesseraPanorama
import TesseraPivot
import TesseraStartScreen

// MARK: - Корневой экран

struct ContentView: View {
    var body: some View {
        TabView {
            DeskDemoView()
                .tabItem {
                    Label("Стол", systemImage: "square.grid.2x2.fill")
                }

            StartDemoView()
                .tabItem {
                    Label("Старт", systemImage: "rectangle.grid.2x2")
                }

            PivotDemoView()
                .tabItem {
                    Label("Пивот", systemImage: "rectangle.split.3x1.fill")
                }

            PanoramaDemoView()
                .tabItem {
                    Label("Панорама", systemImage: "rectangle.on.rectangle")
                }

            CorePagerDemoView()
                .tabItem {
                    Label("Ядро", systemImage: "arrow.left.and.right")
                }
        }
    }
}

// MARK: - Общие демо-элементы

/// Простое сообщение для алерта демо-действия.
struct DemoAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Капсульная кнопка демо: один стиль на все вкладки.
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

/// Сгенерированные картинки: внешних ресурсов демо не использует.
enum DemoVisuals {

    /// Фон панорамы: градиент с полупрозрачными кругами.
    ///
    /// Создаётся один раз и передаётся в `PanoramaStyle` стабильным
    /// экземпляром: фасад сравнивает обои по ссылке и не переназначает их на
    /// каждой перерисовке SwiftUI.
    static let panoramaBackground: UIImage = makePanoramaBackground()

    /// SF Symbol в заданном цвете для иконки ярлыка.
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

// MARK: - Вкладка «Стол»

struct DeskDemoView: View {
    @StateObject private var model = DemoDeskModel()
    @Environment(\.sizeCategory) private var sizeCategory

    /// Высота плавающего блока подсказки/кнопки (E12.6): сетка резервирует
    /// под него нижнее поле, чтобы последний ряд плиток не оказывался под ним.
    @State private var overlayHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            DemoDeskRepresentable(
                model: model,
                isEditing: model.isEditing,
                bottomReserve: overlayHeight
            )

            VStack(alignment: .trailing, spacing: 10) {
                // E12.6: на accessibility-размерах подсказка не показывается —
                // крупный текст превращал её в блок поверх сетки.
                if !sizeCategory.isAccessibilityCategory {
                    Text(
                        model.isEditing
                            ? "Перетащите плитку, измените размер или открепите её"
                            : "Долгое нажатие по плитке — режим редактирования"
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
                        model.isEditing ? "Готово" : "Изменить",
                        systemImage: model.isEditing ? "checkmark.circle.fill" : "square.and.pencil"
                    )
                }
                .buttonStyle(DemoCapsuleButtonStyle(tint: model.isEditing ? .green : .blue))
            }
            .padding(16)
            // E12.6: кнопка не растёт выше xxxLarge — иначе на accessibility-
            // размерах она занимает пол-экрана поверх сетки.
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

/// Высота плавающего блока подсказки/кнопки вкладки «Стол» (E12.6).
private struct DemoDeskOverlayHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Мост SwiftUI → UIKit-слой рабочего стола.
///
/// Фасад `StartScreenView` в этой вкладке не используется: он не отдаёт
/// `TesseraTileEditCoordinator`, а ручная проверка должна показать edit-режим.
/// Поэтому собираем разрешённый публичный UIKit-слой напрямую: сетка + стор +
/// координатор редактирования.
struct DemoDeskRepresentable: UIViewControllerRepresentable {
    let model: DemoDeskModel
    let isEditing: Bool
    /// Высота плавающего блока поверх сетки — нижнее поле (E12.6).
    let bottomReserve: CGFloat

    func makeUIViewController(context: Context) -> DemoDeskHostController {
        DemoDeskHostController(model: model)
    }

    func updateUIViewController(_ uiViewController: DemoDeskHostController, context: Context) {
        uiViewController.bottomReserve = bottomReserve
        uiViewController.applyEditingState(isEditing)
    }
}

/// Модель вкладки «Стол»: каталог ярлыков, папка и live-плитка.
final class DemoDeskModel: ObservableObject {
    let store: TileStore

    @Published var isEditing = false
    @Published var alert: DemoAlert?

    private let liveTileProvider = DemoLiveTileProvider()

    init() {
        // Отдельный временный каталог на запуск: демо всегда стартует в
        // одинаковом состоянии и не зависит от правок прошлой проверки.
        // Для проверки персистентности TileStore каталог можно заменить на
        // TileStore.defaultDirectoryURL().
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TesseraKitExample", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = TileStore(directoryURL: directory)

        // Каталог регистрируется до load(): действия и иконки — runtime-часть
        // ярлыка, в JSON они не сериализуются.
        store.setCatalog(makeCatalog())
        try? store.load()
        seedFolderIfNeeded()
    }

    deinit {
        store.onChange = nil
    }

    /// Четыре размера D15, бейджи D12, одна папка и одна live-плитка.
    private func makeCatalog() -> [TileDescriptor] {
        [
            TileDescriptor(
                id: "mail",
                title: "Почта",
                icon: DemoVisuals.symbol("envelope.fill", tint: .systemBlue),
                action: makeAction(for: "Почта"),
                badge: .count(3),
                size: .small
            ),
            TileDescriptor(
                id: "calendar",
                title: "Календарь",
                icon: DemoVisuals.symbol("calendar", tint: .systemRed),
                action: makeAction(for: "Календарь"),
                badge: .dot,
                size: .medium
            ),
            TileDescriptor(
                id: "weather",
                title: "Погода",
                icon: DemoVisuals.symbol("cloud.sun.fill", tint: .systemTeal),
                action: makeAction(for: "Погода"),
                size: .wide,
                liveContent: liveTileProvider
            ),
            TileDescriptor(
                id: "notes",
                title: "Заметки",
                icon: DemoVisuals.symbol("note.text", tint: .systemYellow),
                action: makeAction(for: "Заметки"),
                size: .small
            ),
            TileDescriptor(
                id: "photos",
                title: "Фото",
                icon: DemoVisuals.symbol("photo.fill", tint: .systemGreen),
                action: makeAction(for: "Фото"),
                size: .small
            ),
            TileDescriptor(
                id: "music",
                title: "Музыка",
                icon: DemoVisuals.symbol("music.note", tint: .systemPink),
                action: makeAction(for: "Музыка"),
                badge: .count(5),
                size: .large
            ),
            TileDescriptor(
                id: "settings",
                title: "Настройки",
                icon: DemoVisuals.symbol("gearshape.fill", tint: .systemGray),
                action: makeAction(for: "Настройки"),
                badge: .dot,
                size: .small
            ),
        ]
    }

    /// Каталог регистрируется целиком, поэтому при первом запуске ярлыки
    /// автоматически попадают на сетку. Папка создаётся через публичное
    /// одобрение D14 (по умолчанию `TileStore.approval` разрешает всё).
    private func seedFolderIfNeeded() {
        guard store.snapshot().folders.isEmpty else { return }

        if !store.isPinned("notes") {
            store.pin("notes")
        }

        guard let folder = store.createFolder(withTile: "notes", title: "Работа") else {
            return
        }

        if !store.isPinned("photos") {
            store.pin("photos")
        }
        store.addToFolder("photos", folderID: folder.id)
    }

    /// Действие ярлыка: печать в консоль и алерт. D12: действие вызывает хост,
    /// а не сетка.
    private func makeAction(for title: String) -> () -> Void {
        { [weak self] in
            print("[TesseraKitExample] Tap shortcut: \(title)")
            self?.alert = DemoAlert(
                title: title,
                message: "Демо-действие ярлыка «\(title)»."
            )
        }
    }
}

/// Live-провайдер плитки «Погода»: две стороны и подписка на обновления.
final class DemoLiveTileProvider: NSObject, TesseraLiveTileContentProvider {
    private var updateCount = 0
    private var timer: Timer?

    deinit {
        timer?.invalidate()
    }

    var frontFace: TesseraLiveTileFace {
        TesseraLiveTileFace(
            title: "Погода",
            detail: "Минск",
            icon: UIImage(systemName: "cloud.sun.fill"),
            backgroundColor: .systemTeal,
            foregroundColor: .white
        )
    }

    var backFace: TesseraLiveTileFace? {
        TesseraLiveTileFace(
            title: "\(18 + updateCount % 5)°",
            detail: updateCount == 0 ? "Ясно" : "Обновление \(updateCount)",
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

/// UIKit-контейнер рабочего стола: сетка, координатор редактирования и
/// проброс действий ярлыков в демо-модель.
final class DemoDeskHostController: UIViewController, TesseraTileEditCoordinatorDelegate {
    private let model: DemoDeskModel
    private let store: TileStore
    private let gridView = TesseraTileGridView()
    private var editCoordinator: TesseraTileEditCoordinator?

    /// Высота плавающей подсказки/кнопки SwiftUI-слоя (E12.6).
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

        // E14.5: снимок с таблицей явных ячеек — сетка показывает дыры модели.
        gridView.reload(snapshot: store.snapshot(columns: gridView.columns))
        gridView.onTap = { [weak self] item in
            self?.handleTap(item)
        }

        // Хост — типичный подписчик TileStore: применяет снимок после каждой
        // правки (правило «один писатель»: пишет только хранилище).
        store.onChange = { [weak self] snapshot in
            self?.gridView.update(snapshot: snapshot, animated: true)
        }

        // Координатор сам ставит жест долгого нажатия, «желе», крестики и
        // стрелки размера; grid.onLongPress задавать не нужно.
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

        // Поворот/смена ширины: кнопки редактирования пересчитываются вне
        // горячего пути прокрутки.
        if editCoordinator?.isEditing == true {
            editCoordinator?.refreshEditControls()
        }
    }

    /// Применяет режим редактирования, инициированный кнопкой SwiftUI.
    func applyEditingState(_ isEditing: Bool) {
        guard let editCoordinator else { return }

        if isEditing, !editCoordinator.isEditing {
            editCoordinator.beginEditing()
        } else if !isEditing, editCoordinator.isEditing {
            editCoordinator.endEditing()
        }
    }

    /// Сетка не подмешивает safe area сама — поля задаёт хост.
    private func updateGridInsets() {
        let safeArea = view.safeAreaInsets
        // Нижний запас — под плавающую подсказку и кнопку «Изменить»,
        // которые лежат поверх представителя в SwiftUI-слое; высоту блока
        // измеряет SwiftUI (на accessibility-размерах она другая, E12.6).
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

    private func handleTap(_ item: TileGridItem) {
        switch item {
        case .tile(let tile):
            // В режиме редактирования тап не запускает действие: у плитки
            // появляются custom actions resize/unpin и крестики.
            guard editCoordinator?.isEditing != true else { return }
            tile.action()
        case .folder:
            // Нативное WP-раскрытие папки выполняет сама сетка (D17).
            // Чтобы вернуть старое поведение (sheet экрана папки), хост задаёт
            // gridView.folderTapHandler = { folder in
            //     editCoordinator?.openFolder(folder); return true
            // } — true отменяет нативное раскрытие.
            break
        case .folderContent:
            // Панель раскрытой папки — внутренний элемент сетки, тап не нужен.
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
        to size: TileSize
    ) {
        print("[TesseraKitExample] Resize tile: \(tileID) → \(size.rawValue)")
    }

    func tileEditCoordinator(
        _ coordinator: TesseraTileEditCoordinator,
        didMove tileID: AnyHashable,
        toIndex index: Int
    ) {
        print("[TesseraKitExample] Move tile: \(tileID) → \(index)")
    }

    /// Не публикуем изменение повторно, если флаг уже совпадает: иначе
    /// `@Published` мог бы отправить событие во время обновления SwiftUI.
    private func updateEditingFlag(_ isEditing: Bool) {
        if model.isEditing != isEditing {
            model.isEditing = isEditing
        }
    }
}

// MARK: - Вкладка «Старт» (полный рабочий стол, E12.8)

/// Вкладка «Старт»: полный публичный `TesseraStartScreenViewController` —
/// пейджер из трёх страниц (хук / START / список приложений), параллакс обоев,
/// живая плитка, папка и режим редактирования. Вкладка «Стол» остаётся как
/// есть: там сетка и координатор без пейджера.
struct StartDemoView: View {
    @StateObject private var model = StartDemoModel()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            StartDemoRepresentable(model: model, isEditing: model.isEditing)
                // Обои идут под статус-бар, а снизу остаётся safe area вкладок:
                // сетка получает нижнее поле от самого экрана.
                .ignoresSafeArea(.container, edges: .top)

            // Кнопка выхода из edit поверх экрана: режим также включается
            // долгим нажатием по плитке и выключается тапом по фону.
            if model.isEditing {
                Button {
                    model.isEditing = false
                } label: {
                    Label("Готово", systemImage: "checkmark.circle.fill")
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

/// Мост SwiftUI → полный рабочий стол.
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

/// Модель вкладки «Старт»: каталог из 7 демо-плиток и 18 дополнительных
/// приложений (в списке они откреплены), папка и live-плитка.
final class StartDemoModel: ObservableObject {
    let store: TileStore

    @Published var isEditing = false
    @Published var alert: DemoAlert?

    private let liveTileProvider = DemoLiveTileProvider()

    /// Дополнительные приложения: только в списке, на сетке не закреплены.
    private static let extraApps: [(id: String, title: String, symbol: String, tint: UIColor)] = [
        ("camera", "Камера", "camera.fill", .systemGray),
        ("maps", "Карты", "map.fill", .systemGreen),
        ("clock", "Часы", "clock.fill", .systemOrange),
        ("contacts", "Контакты", "person.2.fill", .systemBrown),
        ("phone", "Телефон", "phone.fill", .systemGreen),
        ("messages", "Сообщения", "message.fill", .systemBlue),
        ("browser", "Браузер", "safari.fill", .systemBlue),
        ("files", "Файлы", "folder.fill", .systemCyan),
        ("books", "Книги", "book.fill", .systemOrange),
        ("calc", "Калькулятор", "plus.forwardslash.minus", .systemGray),
        ("wallet", "Кошелёк", "creditcard.fill", .systemIndigo),
        ("health", "Здоровье", "heart.fill", .systemRed),
        ("video", "Видео", "play.rectangle.fill", .systemPurple),
        ("podcasts", "Подкасты", "mic.fill", .systemPurple),
        ("translate", "Переводчик", "character.bubble.fill", .systemTeal),
        ("voice", "Диктофон", "waveform", .systemRed),
        ("stocks", "Акции", "chart.line.uptrend.xyaxis", .systemGreen),
        ("tips", "Советы", "lightbulb.fill", .systemYellow),
        ("zeta", "Ёж", "hare.fill", .systemMint),
        ("latin", "Zoom", "video.fill", .systemBlue),
    ]

    init() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TesseraKitExampleStart", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = TileStore(directoryURL: directory)

        store.setCatalog(makeCatalog())
        try? store.load()
        seedIfNeeded()
    }

    deinit {
        store.onChange = nil
    }

    private func makeCatalog() -> [TileDescriptor] {
        var catalog: [TileDescriptor] = [
            TileDescriptor(
                id: "mail", title: "Почта",
                icon: DemoVisuals.symbol("envelope.fill", tint: .systemBlue),
                action: makeAction(for: "Почта"), badge: .count(3), size: .small),
            TileDescriptor(
                id: "calendar", title: "Календарь",
                icon: DemoVisuals.symbol("calendar", tint: .systemRed),
                action: makeAction(for: "Календарь"), badge: .dot, size: .medium),
            TileDescriptor(
                id: "weather", title: "Погода",
                icon: DemoVisuals.symbol("cloud.sun.fill", tint: .systemTeal),
                action: makeAction(for: "Погода"), size: .wide,
                liveContent: liveTileProvider),
            TileDescriptor(
                id: "notes", title: "Заметки",
                icon: DemoVisuals.symbol("note.text", tint: .systemYellow),
                action: makeAction(for: "Заметки"), size: .small),
            TileDescriptor(
                id: "photos", title: "Фото",
                icon: DemoVisuals.symbol("photo.fill", tint: .systemGreen),
                action: makeAction(for: "Фото"), size: .small),
            TileDescriptor(
                id: "music", title: "Музыка",
                icon: DemoVisuals.symbol("music.note", tint: .systemPink),
                action: makeAction(for: "Музыка"), badge: .count(5), size: .large),
            TileDescriptor(
                id: "settings", title: "Настройки",
                icon: DemoVisuals.symbol("gearshape.fill", tint: .systemGray),
                action: makeAction(for: "Настройки"), badge: .dot, size: .small),
        ]
        for app in Self.extraApps {
            catalog.append(
                TileDescriptor(
                    id: app.id, title: app.title,
                    icon: DemoVisuals.symbol(app.symbol, tint: app.tint),
                    action: makeAction(for: app.title), size: .small)
            )
        }
        return catalog
    }

    /// Папка «Работа» из двух ярлыков; дополнительные приложения откреплены,
    /// чтобы в списке были и закреплённые, и свободные строки.
    private func seedIfNeeded() {
        guard store.snapshot().folders.isEmpty else { return }

        for app in Self.extraApps where store.isPinned(app.id) {
            _ = store.unpin(app.id)
        }

        if let folder = store.createFolder(withTile: "notes", title: "Работа") {
            store.addToFolder("photos", folderID: folder.id)
        }
    }

    private func makeAction(for title: String) -> () -> Void {
        { [weak self] in
            print("[TesseraKitExample] Start tap shortcut: \(title)")
            self?.alert = DemoAlert(
                title: title,
                message: "Демо-действие ярлыка «\(title)»."
            )
        }
    }

    func showSettingsAlert() {
        alert = DemoAlert(title: "Настройки", message: "Строка секции настроек списка приложений.")
    }
}

/// Простая страница-хук: заголовок и пара строк, чтобы было что листать.
final class StartDemoHookController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.35)

        let title = UILabel()
        title.text = "Быстрая панель"
        title.font = .preferredFont(forTextStyle: .largeTitle)
        title.textColor = .white
        title.adjustsFontForContentSizeCategory = true

        let detail = UILabel()
        detail.text = "Страница-хук (QuickPanelProviding): сюда хост кладёт поиск, быстрые настройки, профиль."
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

/// UIKit-контейнер полного рабочего стола: пейджер, сетка, координатор
/// редактирования; всё через публичный API.
final class StartDemoHostController: UIViewController,
    StartScreenDelegate, TesseraTileEditCoordinatorDelegate
{
    private let model: StartDemoModel
    private let store: TileStore
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
        screen.quickPanelTitle = "Быстрая панель"
        screen.startPageTitle = "Начало"
        screen.applicationsPageTitle = "Приложения"

        // E14.5: снимок с таблицей явных ячеек — сетка показывает дыры модели.
        screen.reload(grid: store.snapshot(columns: screen.gridView.columns))

        let store = self.store
        let model = self.model
        screen.configure(
            leftPanel: QuickPanelProvider(makeViewController: { StartDemoHookController() }),
            rightPage: {
                TesseraAppsListPageViewController.make(
                    store: store,
                    settings: [
                        TesseraAppsListSettingsItem(
                            id: "settings",
                            title: "Настройки",
                            subtitle: "Демо-строка настроек",
                            icon: UIImage(systemName: "gearshape"),
                            action: { [weak model] in model?.showSettingsAlert() }
                        ),
                    ]
                )
            }
        )

        // Данные только из хранилища (один писатель): применяем снимок на
        // каждое изменение, в том числе pin/unpin со страницы списка.
        store.onChange = { [weak self] snapshot in
            self?.screen.reload(grid: snapshot)
        }

        // Тапы сетки остаются за хостом (контроллер экрана их не пересылает):
        // действие ярлыка вызываем сами, в режиме редактирования — нет.
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

    /// Применяет режим редактирования, инициированный кнопкой SwiftUI.
    func applyEditingState(_ isEditing: Bool) {
        guard let editCoordinator else { return }

        if isEditing, !editCoordinator.isEditing {
            editCoordinator.beginEditing()
        } else if !isEditing, editCoordinator.isEditing {
            editCoordinator.endEditing()
        }
    }

    // MARK: StartScreenDelegate

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

// MARK: - Вкладка «Пивот»

struct PivotDemoView: View {
    var body: some View {
        PivotView(
            sections: makeSections(),
            style: PivotStyle(
                activeColor: .systemOrange,
                inactiveColor: .secondaryLabel,
                indicatorStyle: .underlineAndText,
                stripMode: .content,
                appTitle: "Tessera Пивот"
            )
        )
    }

    /// SwiftUI-контент секций через реальную фабрику TesseraCore.
    private func makeSections() -> [PivotSection] {
        [
            PivotSection(
                id: "pivot-home",
                title: "Главная",
                content: TesseraSwiftUIContentProvider {
                    DemoPivotPage(
                        index: 0,
                        title: "Главная",
                        subtitle: "Первая секция пивота. Лента заголовков синхронизирована с пейджером, крупный заголовок задан через PivotStyle.appTitle."
                    )
                }
            ),
            PivotSection(
                id: "pivot-feed",
                title: "Лента",
                content: TesseraSwiftUIContentProvider {
                    DemoPivotPage(
                        index: 1,
                        title: "Лента",
                        subtitle: "Вторая секция. Свайп по горизонтали, тап по заголовку и индикатор работают на UIKit-ядре TesseraPivot."
                    )
                }
            ),
            PivotSection(
                id: "pivot-overview",
                title: "Обзор",
                content: TesseraSwiftUIContentProvider {
                    DemoPivotPage(
                        index: 2,
                        title: "Обзор",
                        subtitle: "Третья секция. Горизонталь забирает пейджер; вложенного вертикального скролла в демо нет, чтобы свайп не перехватывался."
                    )
                }
            ),
            PivotSection(
                id: "pivot-profile",
                title: "Профиль",
                content: TesseraSwiftUIContentProvider {
                    DemoPivotPage(
                        index: 3,
                        title: "Профиль",
                        subtitle: "Четвёртая секция. Проверьте Dynamic Type и VoiceOver: заголовки и страницы подстраиваются."
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
        // Намеренно без вертикального ScrollView: SwiftUI-скролл перехватил бы
        // горизонтальный жест пейджера, а вертикальный владелец регистрируется
        // хостом только через UIKit-контроллер. Для проверки пивота важнее
        // надёжный горизонтальный свайп.
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
                        Text("Строка \(row + 1)")
                            .font(.subheadline.weight(.semibold))
                        Text("Демонстрационное содержимое секции «\(title)».")
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

// MARK: - Вкладка «Панорама»

struct PanoramaDemoView: View {
    var body: some View {
        PanoramaView(
            sections: makeSections(),
            style: PanoramaStyle(
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

    /// Три секции поверх одной сгенерированной картинки: внешних ресурсов нет.
    private func makeSections() -> [PanoramaSection] {
        [
            PanoramaSection(
                id: "pano-start",
                title: "Начало",
                content: TesseraSwiftUIContentProvider {
                    DemoPanoramaPage(
                        index: 0,
                        title: "Начало",
                        text: "Секции уже, чем экран: справа видна полоса peek, а фон с параллаксом сдвигается медленнее контента."
                    )
                }
            ),
            PanoramaSection(
                id: "pano-news",
                title: "Новости",
                content: TesseraSwiftUIContentProvider {
                    DemoPanoramaPage(
                        index: 1,
                        title: "Новости",
                        text: "Заголовок секции анимируется тем же скаляром t, что и фон. Свайп, тап по заголовку и VoiceOver ведут к одной программной точке перехода."
                    )
                }
            ),
            PanoramaSection(
                id: "pano-about",
                title: "О панораме",
                content: TesseraSwiftUIContentProvider {
                    DemoPanoramaPage(
                        index: 2,
                        title: "О панораме",
                        text: "Фон — сгенерированный градиент (DemoVisuals), без ресурсов в Assets. При Reduce Motion параллакс и анимации заголовков отключаются ядром."
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
        // Без вертикального ScrollView: внутренний UIScrollView перехватил бы
        // горизонтальный жест панорамы, а вертикальный владелец регистрируется
        // хостом только через UIKit-контроллер. Карточка заполняет страницу,
        // фоновая картинка остаётся видна по краям и в полосе peek.
        VStack(alignment: .leading, spacing: 16) {
            Text("Секция \(index + 1) из 3")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            Text(title)
                .font(.title2.bold())
                .foregroundColor(.primary)

            Text(text)
                .font(.body)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                demoStat(value: "3", caption: "секции")
                demoStat(value: "56", caption: "peek, pt")
                demoStat(value: "0.5", caption: "параллакс")
            }

            Text("Карточка полупрозрачная: в полосе peek и по краям видна фоновая картинка.")
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

// MARK: - Вкладка «Ядро»

struct CorePagerDemoView: View {
    @StateObject private var model = DemoPagerModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Пейджер TesseraCore")
                        .font(.title2.bold())
                    Text("Два экземпляра TesseraPagerViewController: .paged и .snapping. Кнопки вызывают публичный go(toPage:animated:).")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                pagerBlock(
                    title: "Режим .paged",
                    subtitle: "Снап даёт isPagingEnabled: страницы ровно по ширине экрана.",
                    pager: model.pagedPager,
                    index: model.pagedIndex
                )

                pagerBlock(
                    title: "Режим .snapping",
                    subtitle: "Кастомный снап через TesseraSnapPolicy: decelerationRate = .fast и целевой offset по порогу скорости.",
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
                Button("Назад") {
                    pager.go(toPage: max(index - 1, 0), animated: true)
                }
                .disabled(index <= 0)

                Button("Вперёд") {
                    pager.go(toPage: min(index + 1, DemoPagerModel.pageCount - 1), animated: true)
                }
                .disabled(index >= DemoPagerModel.pageCount - 1)

                Button("На 3-ю") {
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

/// Обёртка вокруг готового экземпляра пейджера из демо-модели.
///
/// Экземпляр создаётся один раз в `DemoPagerModel`, чтобы кнопки могли
/// вызывать его публичный `go(toPage:animated:)`.
struct PagerHostView: UIViewControllerRepresentable {
    let pager: TesseraPagerViewController

    func makeUIViewController(context: Context) -> PagerContainerController {
        PagerContainerController(pager: pager)
    }

    func updateUIViewController(
        _ uiViewController: PagerContainerController,
        context: Context
    ) {
        // Конфигурация пейджера задана при создании; обновлять нечего.
    }
}

/// Контейнер для готового пейджера из модели.
///
/// Экземпляр создаётся один раз (кнопки вызывают его `go(toPage:animated:)`),
/// поэтому при повторном показе вкладки контейнер аккуратно переподключает
/// child-контроллер, если тот ещё был чьим-то ребёнком.
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

/// Демо-модель пейджера: два экземпляра, их страницы и текущие индексы.
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

    /// Страницы пейджера — SwiftUI-контент через штатную фабрику TesseraCore.
    private static func makePages(prefix: String) -> [TesseraPageDescriptor] {
        (0..<pageCount).map { index in
            TesseraPageDescriptor(
                id: "\(prefix)-page-\(index)",
                title: "Страница \(index + 1)",
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
                Text("Страница \(pageIndex + 1)")
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

// MARK: - Превью

#Preview {
    ContentView()
}
