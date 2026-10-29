# TesseraKit

Компоненты UI в духе Windows Phone для iOS: **Panorama**, **Pivot** и **Start Screen** с живыми плитками. UIKit-ядро + SwiftUI-фасады. Swift 5.9+, iOS 15+, без внешних зависимостей.

`tessera` (лат.) — кусочек мозаики: рабочий стол Windows Phone — это мозаичное панно из плиток, а панорама и пивот — способы ходить по нему.

## Состав пакета

| Библиотека | Описание | Документация |
|---|---|---|
| `TesseraCore` | Общий слой: пейджер `paged`/`snapping`, снап-политика, параллакс, арбитраж жестов, хостинг контента, accessibility/RTL | [docs/CORE-IOS-DESIGN.md](docs/CORE-IOS-DESIGN.md) |
| `TesseraPanorama` | Панорама: секции-холсты с peek, параллакс фона, заголовки по прогрессу, кастомный снап | [docs/PANORAMA-IOS-DESIGN.md](docs/PANORAMA-IOS-DESIGN.md) |
| `TesseraPivot` | Пивот: лента заголовков с индикатором и сквозной синхронизацией, полноэкранные страницы | [docs/PIVOT-IOS-DESIGN.md](docs/PIVOT-IOS-DESIGN.md) |
| `TesseraStartScreen` | Рабочий стол: ярлыки-действия и папки, live-плитки, режим редактирования, список приложений, страница-хук | [docs/STARTSCREEN-IOS-DESIGN.md](docs/STARTSCREEN-IOS-DESIGN.md) |

## Статус

Реализован, v0.1: все четыре библиотеки собраны, архитектура и контракты — в проектных документах `docs/`.

- `TesseraCore` — пейджер `paged`/`snapping`, снап-политика, параллакс, арбитраж жестов, хостинг контента, accessibility/RTL;
- `TesseraPivot` — лента заголовков с непрерывным индикатором, синхронизация ленты и пейджера, SwiftUI-фасад;
- `TesseraPanorama` — peek-снап, параллакс фона, заголовки по прогрессу, SwiftUI-фасад;
- `TesseraStartScreen` — рабочий стол с ярлыками-действиями и папками, live-плитки, режим редактирования, опциональные боковые страницы, SwiftUI-фасад.

Тесты — **271**, гоняются через `xcodebuild test -scheme TesseraKit-Package -destination 'platform=iOS Simulator,name=iPhone 17'`: `swift test` на macOS-хосте UIKit-код не исполняет (D10 в [docs/STATE.md](docs/STATE.md)). Пакет — iOS 15+; Mac — только совместимость через Mac Catalyst (D9).

## Подключение

```swift
.package(url: "https://github.com/ihodorchenko/TesseraKit.git", from: "0.1.0"),
```

и в зависимостях target'а, например:

```swift
.product(name: "TesseraPivot", package: "TesseraKit"),
```

Фасад в SwiftUI — секции задаются фабриками `UIViewController`:

```swift
import TesseraPivot

PivotView(
    sections: [PivotSection(id: "home", title: "Главная") { HomeViewController() }],
    style: PivotStyle(appTitle: "Приложение")
)
```

## Вдохновение

Дизайн-язык Windows Phone (Metro): панорама, пивот и рабочий стол с живыми плитками, воссозданные на публичных API UIKit/SwiftUI. Без аффилиации с Microsoft.

## Для AI-агентов

Инструкции для агентов, работающих с репозиторием: [AGENTS.md](AGENTS.md).

## Лицензия

MIT — см. [LICENSE](LICENSE).
