# TesseraKit

Компоненты UI в духе Windows Phone для iOS: **Panorama**, **Pivot** и **Start Screen** с живыми плитками. UIKit-ядро + SwiftUI-фасады. Swift 5.9+, iOS 15+.

`tessera` (лат.) — кусочек мозаики: рабочий стол Windows Phone — это мозаичное панно из плиток, а панорама и пивот — способы ходить по нему.

## Состав пакета

| Библиотека | Описание | Документация |
|---|---|---|
| `TesseraCore` | Общий слой: пейджер, параллакс, арбитраж жестов, хостинг контента, accessibility | [docs/CORE-IOS-DESIGN.md](docs/CORE-IOS-DESIGN.md) |
| `TesseraPanorama` | Панорама: секции-холсты, peek, параллакс фона, кастомный снап | [docs/PANORAMA-IOS-DESIGN.md](docs/PANORAMA-IOS-DESIGN.md) |
| `TesseraPivot` | Пивот: лента заголовков со сквозной синхронизацией + страницы | [docs/PIVOT-IOS-DESIGN.md](docs/PIVOT-IOS-DESIGN.md) |
| `TesseraStartScreen` | Рабочий стол: сетка живых плиток, список приложений, страница-хук | [docs/STARTSCREEN-IOS-DESIGN.md](docs/STARTSCREEN-IOS-DESIGN.md) |

## Статус

Проект на стадии проектирования — реализация ещё не начата. Проектные документы в `docs/` фиксируют архитектуру, контракты, MVP и риски каждого модуля.

## Подключение

```swift
.package(url: "https://github.com/ihodorchenko/TesseraKit.git", from: "0.1.0"),
```

и в зависимостях target'а, например:

```swift
.product(name: "TesseraPivot", package: "TesseraKit"),
```

## Вдохновение

Дизайн-язык Windows Phone (Metro): панорама, пивот и рабочий стол с живыми плитками, воссозданные на публичных API UIKit/SwiftUI. Без аффилиации с Microsoft.

## Для AI-агентов

Инструкции для агентов, работающих с репозиторием: [AGENTS.md](AGENTS.md).

## Лицензия

MIT — см. [LICENSE](LICENSE).
