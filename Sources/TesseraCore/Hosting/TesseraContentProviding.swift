// Хостинг контента TesseraCore: контракт поставщика контента.
// Проектный документ: docs/Core-iOS-Design.md — §1 «Состав пакета»,
// §3 «Концептуальная поверхность API».
//
// Hosting — часть UIKit-ядра (§4), поэтому типы файла доступны только на платформах с UIKit.
// На macOS-хосте, где SwiftPM собирает пакет при `swift build`, файл компилируется
// пустым: так ядро остаётся сборным вне iOS, а публичная поверхность на iOS не меняется.

#if canImport(UIKit)
import UIKit
import SwiftUI

/// Поставщик контента для контейнеров Core (docs/Core-iOS-Design.md, §3).
///
/// Позволяет пейджеру и другим контейнерам получать `UIViewController`, не зная,
/// UIKit это или SwiftUI-фасад. Возвращается именно контроллер, а не `UIView`,
/// чтобы контейнер мог использовать child-VC containment (§1).
///
/// - Important: Метод вызывается на главном потоке: вся работа с UI в Core —
///   main-thread, состояние не размазывается по модулям (§3).
public protocol TesseraContentProviding {
    /// Создаёт новый контроллер контента.
    ///
    /// Контроллер создаётся при первом запросе `id` в `TesseraContentHosting`
    /// и заново — после `TesseraContentHosting.removeContent(for:)`/`removeAll()`.
    func makeContentViewController() -> UIViewController
}

/// Реализация `TesseraContentProviding` для UIKit-контента.
///
/// Тонкая обёртка над фабрикой: Core не навязывает контроллеру базовый класс,
/// поэтому подходит любой `UIViewController` (docs/Core-iOS-Design.md, §3).
public struct TesseraViewControllerProvider: TesseraContentProviding {
    private let makeViewController: () -> UIViewController

    /// - Parameter makeViewController: фабрика контроллера; вызывается на главном потоке.
    public init(_ makeViewController: @escaping () -> UIViewController) {
        self.makeViewController = makeViewController
    }

    public func makeContentViewController() -> UIViewController {
        makeViewController()
    }
}

/// Реализация `TesseraContentProviding` для SwiftUI-контента
/// (docs/Core-iOS-Design.md, §1).
///
/// Оборачивает `Content` в `UIHostingController`: SwiftUI допускается только
/// в фасадах, поэтому UIKit-ядро видит обычный `UIViewController`.
public struct TesseraSwiftUIContentProvider<Content: View>: TesseraContentProviding {
    private let makeContent: () -> Content

    /// - Parameter makeContent: фабрика SwiftUI-контента; вызывается на главном потоке.
    public init(_ makeContent: @escaping () -> Content) {
        self.makeContent = makeContent
    }

    public func makeContentViewController() -> UIViewController {
        UIHostingController(rootView: makeContent())
    }
}

/// Внутренний контракт обновления контента без пересоздания контроллера.
///
/// Не входит в публичную поверхность Core: снаружи хостинг работает только через
/// `TesseraContentProviding` (§3 — delegate-driven, §4 — публичная поверхность минимальна).
protocol TesseraContentUpdating {
    /// Пытается обновить контент существующего контроллера.
    ///
    /// - Returns: `true`, если контроллер создан этим поставщиком и обновлён;
    ///   `false`, если тип контента не совпал и контроллер нужно оставить как есть.
    func updateContent(of viewController: UIViewController) -> Bool
}

extension TesseraSwiftUIContentProvider: TesseraContentUpdating {
    func updateContent(of viewController: UIViewController) -> Bool {
        guard let hostingController = viewController as? UIHostingController<Content> else {
            return false
        }

        // Замена rootView заставляет SwiftUI пересобрать иерархию на месте:
        // сам UIHostingController и его идентичность сохраняются, новый хостинг не создаётся.
        hostingController.rootView = makeContent()
        return true
    }
}
#endif
