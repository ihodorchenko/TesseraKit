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

Отдельный референс — как рабочий стол Windows 10 Mobile устроен и работает на реальном устройстве: сетка и размеры плиток, правила раскладки и пустоты, обычный режим, режим редактирования, папки, жесты; каждое утверждение размечено по достоверности источников — [docs/W10M-STARTSCREEN.md](docs/W10M-STARTSCREEN.md).

## Статус

Реализован. **Последний выпущенный релиз — v0.3.0** (`main`): четыре библиотеки, Example-хост для ручной проверки, папки в духе WP, физика drag по спеке WP и исправления по ревью (эпики E0–E10). В ветке `dev` закрыты E11–E17, готовится релиз 0.4.0 (предложение, тег ставит владелец; до мерджа релизного PR последний тег на `main` — v0.3.0): drag&drop папок (E11), находки ручного тестирования Example (E12), 6 колонок по умолчанию (E13), настоящие пустоты на сетке (E14: явные ячейки `row`/`column`, `tiles.json` версии 2, дыры, выталкивание вниз, папка не бывает из 0–1 ярлыков), сверка с W10M (E15: углы badge и кнопки открепления, цикл размеров, `.dot` в VoiceOver, переименование папки, «желе» как параметр хоста, badge папки как сумма, кнопка открепления на ярлыках папки) и перестановка ярлыков внутри панели папки (E16). Архитектура и контракты — в проектных документах `docs/`; ход работ — [docs/PLAN.md](docs/PLAN.md), состояние и решения — [docs/STATE.md](docs/STATE.md), риски — [docs/RISK.md](docs/RISK.md).

- `TesseraCore` — пейджер `paged`/`snapping`, снап-политика, параллакс, арбитраж жестов, хостинг контента, accessibility/RTL;
- `TesseraPivot` — лента заголовков с непрерывным индикатором, синхронизация ленты и пейджера, SwiftUI-фасад;
- `TesseraPanorama` — peek-снап, параллакс фона, заголовки по прогрессу, SwiftUI-фасад;
- `TesseraStartScreen` — рабочий стол с ярлыками-действиями и папками, live-плитки, режим редактирования, опциональные боковые страницы, SwiftUI-фасад; user-facing строки по умолчанию локализованы (51 dotted-ключ, en/ru, SPM-ресурсы, fallback — английский), подписи страниц и хост-тексты — дефолты/параметры хоста;
- Папки — WP-поведение: инлайн-раскрытие под плиткой (рост 0→панель, каскад), плитки small внутри, превью 2×2; переопределение тапа — через `folderTapHandler`;
- Физика drag по спеке WP: масштаб 0.95, димминг, push-вниз, drop по клетке под пальцем (дыры сохраняются, мешающие плитки выталкиваются вниз), слияние в папку по таймеру 600 мс, resize-выталкивание, bounce-кривая, магнитизм к ячейкам;
- Плавное «желе» (±1.2°, 0.4 с) — параметр `isJiggleEnabled` (по умолчанию выключено, D39).

Example-хост — [`Example/TesseraKitExample`](Example/TesseraKitExample) (ручная проверка на симуляторе). Полный набор тестов зелёный: **1243/1243, 0 провалов** на `dev` (Core 124, Pivot 77, Panorama 93, StartScreen 949; `xcodebuild test -scheme TesseraKit-Package -destination 'platform=iOS Simulator,name=iPhone 17'`, прогон 16.11.2026; на v0.3.0 было 685/685); `swift test` на macOS-хосте UIKit-код не исполняет (D10 в [docs/STATE.md](docs/STATE.md)). Пакет — iOS 15+; Mac — только совместимость через Mac Catalyst (D9).

## Подключение

```swift
.package(url: "https://github.com/ihodorchenko/TesseraKit.git", from: "0.3.0"),
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
