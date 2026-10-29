# Core-пакет (TesseraCore) для iOS — проектный дизайн

> Проектный документ: теоретическое проектирование общего Core-пакета для компонентов по мотивам Windows Phone.
> Ограничения: **iOS 15+**, **Swift 5.9+**, UIKit-ядро + SwiftUI-фасады. Реализация в объём документа не входит.
> Парные документы: **PANORAMA-IOS-DESIGN.md**, **PIVOT-IOS-DESIGN.md**, **STARTSCREEN-IOS-DESIGN.md**. TesseraCore — общий target пакета **TesseraKit** для этих трёх библиотек.

## 0. Зачем Core

В трёх компонентах накопились одинаковые механики: пейджер с инвариантом `t`, параллакс фона, арбитраж жестов (вариант B), правило «никакого layout в скролле», SwiftUI-фасады, RTL/Reduce Motion. Дублировать это в трёх библиотеках — три места для одних и тех же багов.

**Критерий входа в Core (правило трёх):** механика попадает в Core только если используется минимум двумя компонентами. Всё остальное живёт в своих библиотеках. Core должен оставаться тонким — переабстракция опаснее дублирования.

## 1. Состав пакета

| Модуль | Откуда пришёл | Что делает |
|---|---|---|
| `TesseraPager` | Pivot | горизонтальный пейджер: `pagingEnabled`, инвариант `t = offset.x / pageWidth`, child-VC контейнеры, ленивая загрузка ±1 |
| `TesseraSnapPolicy` | Panorama | кастомный снап через `targetContentOffset(forProposedContentOffset:withScrollingVelocity:)` — для неполностраничных страниц (peek) и будущих «прыжков через страницы» |
| `TesseraParallaxLayer` | Panorama, StartScreen | фоновый слой, управляемый offset'ом: множитель, запас размера за пределами `contentSize`, обе оси, отсечка по Reduce Motion |
| `TesseraGestureArbiter` | вариант B (все) | арбитраж «родитель-ребёнок»: доминирующая ось в `gestureRecognizerShouldBegin`; горизонталь — пейджеру, вертикаль — ребёнку; поддержка нескольких детей |
| `TesseraContentHosting` | все фасады | фабрики контента: `UIViewController` / `UIHostingController`, переиспользование хостингов, мост состояния через `ObservableObject` (iOS 15 — без `@Observable`) |
| `TesseraEdgeSwipePlugin` | обсуждение edge pan | вспомогательный жест с кромки экрана, ведущий в тот же `contentOffset` через spring — для секций с собственным горизонтальным скроллом |
| `TesseraAccessibilityKit` | все | `accessibilityScroll` для пагинации, Reduce Motion-запросы, анонсы смены страницы, нормализация `t` для LTR/RTL |
| `TesseraPerformanceKit` | все | дисциплина «только трансформы в `scrollViewDidScroll`», трекер видимости секций (для пауз), prefetch-координатор |

## 2. Ключевые контракты

- **Инвариант прогресса**: `t = offset.x / pageWidth`; целая часть — индекс, дробная — прогресс перехода. В RTL `t` нормализуется от направления чтения. Все потребители (индикатор Pivot, заголовки Panorama, пейджер StartScreen) работают только с `t`, а не с сырым offset'ом.
- **Один писатель**: `contentOffset` пишут только пейджер (жест) и контроллер (программный переход). Программный переход — `setContentOffset(_:animated:)`, делегат продолжает вызываться на кадрах, поэтому все подписчики анимируются сами. Циклов нет, потому что подписчики не пишут обратно.
- **Два режима пейджера**: `paged` (страницы полной ширины, `pagingEnabled`) и `snapping` (ширина ≠ экрана, `TesseraSnapPolicy`: `decelerationRate = .fast`, ближайший центр + порог скорости). Pivot/StartScreen используют первый, Panorama — второй.
- **Арбитраж**: пейджер скроллит только горизонтально, дети — вертикально; решение по доминирующей оси жеста; масштабируется на нескольких детей (StartScreen: сетка и список).
- **Параллакс**: `backgroundOffset = offset × factor`, `factor ∈ (0, 1)`; слой заведомо больше `contentSize`; Reduce Motion → фактор 0.
- **Edge-хук**: опциональный; не второй движок, а «толчок» в тот же `contentOffset`; в навигационном стеке левый край уступается системе (в RTL — наоборот).

## 3. Концептуальная поверхность API

```
TesseraPagerViewController        ← пейджер (режим paged/snapping), child-VC контейнер
TesseraPageDescriptor             ← id, заголовок, makeContent()
TesseraContentProviding           ← UIViewController | UIHostingController
TesseraPagerDelegate              ← didShowPage, didChangeProgress(_ t:)
TesseraSnapPolicy                 ← конфиг снапа (порог скорости, выравнивание)
TesseraParallaxLayer              ← фон + фактор + ось
TesseraGestureArbiter             ← регистрация детей, решение по осям
TesseraAccessibility / TesseraRTL ← утилиты
```

Принципы: delegate-driven, никаких уведомлений «в никуда»; стили — конфиг-структуры; вся работа на главном потоке UI, состояние не размазывается по модулям.

## 4. Зависимости и структура

```
TesseraKit (Swift Package, iOS 15+, Swift 5.9, без внешних зависимостей)
├── TesseraCore
│   ├── Pager (paged | snapping)
│   ├── Parallax
│   ├── GestureArbiter
│   ├── Hosting (UIKit + SwiftUI-фасады)
│   ├── AccessibilityKit
│   └── PerformanceKit
├── TesseraPanorama ──┐
├── TesseraPivot ─────┼──► TesseraCore
└── TesseraStartScreen┘
```

- `TesseraKit` — один SPM-пакет, четыре library product'а: `TesseraCore`, `TesseraPanorama`, `TesseraPivot`, `TesseraStartScreen`.
- Компонентные target'ы зависят только от `TesseraCore` и не знают друг о друге.
- **Стабильность API** — отдельная ценность: `TesseraCore` — зависимость трёх библиотек, ломающее изменение бьёт по всем сразу. Политика: семвер, deprecations перед удалением, публичная поверхность минимальна.

## 5. MVP Core

**Входит:**

1. `TesseraPager` в двух режимах (paged + snapping).
2. `TesseraParallaxLayer` (обе оси, Reduce Motion).
3. `TesseraGestureArbiter` (несколько детей).
4. `TesseraContentHosting` (UIKit-контент + SwiftUI-фасад).
5. `TesseraAccessibilityKit` (scroll-пагинация, RTL-нормализация `t`).

**Отрезано в v1:** `TesseraEdgeSwipePlugin` (подключать по требованию, когда появится горизонтальный контент в секции), `TesseraPerformanceKit` как отдельный модуль (сначала — просто дисциплина в компонентах), обобщённый reorder из StartScreen (это специфика плиток, не общего пейджера).

## 6. Риски

- **Переабстракция**: Core рискует раздуться до «фреймворка всего». Защита — правило трёх и выпиливание всего, что не используется двумя компонентами.
- **Утечка специфики**: термины плиток/лент/холстов не должны появляться в Core — только страницы, прогресс, слои.
- **Хрупкость обновлений**: любое изменение Core регрессирует три библиотеки; обязательны контрактные тесты (прогресс, снап, арбитраж) на уровне Core.

## 7. Итог

Core — это четыре механики (пейджер, параллакс, арбитраж жестов, хостинг контента) плюс accessibility-утилиты, извлечённые по правилу трёх из Panorama, Pivot и StartScreen. Он тонкий, без внешних зависимостей, с жёсткой политикой стабильности API — и именно он делает три компонента одной экосистемой (**TesseraKit**), а не тремя копиями одних и тех же решений.

## Отступления реализации (v0.1, 29.10.2026)

> Сверка проектного документа с фактическим кодом релиза 0.1.0. Текст выше не переписывался: отступления зафиксированы отдельной секцией. Формат пункта: что обещал документ → что делает код → решение.

1. **§2/§5, режим `.snapping` пейджера.** Документ обещал второй режим пейджера — «ширина страницы ≠ ширины экрана», снап по неполностраничным страницам (peek) через `TesseraSnapPolicy`. Код: `TesseraPagerViewController.scrollViewWillEndDragging` подставляет `itemWidth = scrollView.bounds.width`, то есть шаг снапа всегда равен полной ширине вьюпорта; параметра ширины страницы/peek у пейджера нет, страницы раскладываются полноширинными фреймами в `layoutPager()`. Peek-геометрия реализована только в `TesseraPanorama`: `PanoScrollView` считает `itemWidth = bounds.width − peek` и вызывает ту же `TesseraSnapPolicy`. Решение: в v0.1 оставляем как есть — неполностраничная раскладка в Core не нужна ни одному компоненту; появится второй потребитель peek — добавим в пейджер параметр ширины страницы с дефолтом `bounds.width` (совместимое расширение). До этого §2/§5 в части «ширина ≠ экрана» читать как отступление.

2. **§1, состав модулей и источник `TesseraPager`.** Документ в §1 приписывает пейджеру источник «Pivot», а таблица состава читается так, будто обе механики (пейджер и снап) используются компонентами. Код: `TesseraPanorama` не использует `TesseraPagerViewController` вообще — у неё собственный публичный `PanoScrollView` (подкласс `UIScrollView` с self-delegation; публичные `peek`, `snapPolicy`, `sectionCount`, `itemWidth`, `currentProgress()`) плюс `TesseraSnapPolicy` из Core. Общими с Core у панорамы остались политика снапа, `TesseraContentHosting`, `TesseraAccessibility`/`TesseraRTL` и `TesseraGestureArbiter`. Режим `.snapping` не задействован ни одним компонентом: `PivotViewController` и `TesseraStartScreenViewController` создают пейджер в `.paged`, а `.snapping` встречается только в контрактных тестах `Tests/TesseraCoreTests/TesseraPagerTests.swift`. Решение: считать `.snapping` зарезервированным API Core (покрыт тестами, но в v0.1 не подключён); в §1 читать `TesseraPager` как механику полноширинных страниц, а Panorama — как независимый скролл с общей `TesseraSnapPolicy`.

3. **§2 «Арбитраж» и §3 поверхность API: точка принятия решения по оси.** Документ обещал, что решение по доминирующей оси принимается в `gestureRecognizerShouldBegin`, арбитр назначается делегатом пана родителя, дети регистрируются в арбитре. Код (одинаково во всех трёх компонентах): делегатом `panGestureRecognizer` арбитр не назначается — подмена делегата у `UIScrollView` отключила бы его собственную обработку одновременных жестов (вложенные скроллы, системный edge-swipe). Вместо этого контроллер подписывается на пан аддитивно (`addTarget`) и на состоянии `.began` вызывает чистую функцию `TesseraGestureArbiter.axisDecision(forVelocity:)`; при горизонтали собирает арбитр и вызывает `prepareForHorizontalScroll()` (блокировка вертикальных детей с запоминанием их `isScrollEnabled`), по завершении жеста — `endHorizontalScroll()` (восстановление прежних значений). Дети регистрируются вручную публичными `registerVerticalOwner(_:)` / `unregisterVerticalOwner(_:)` компонентов, ссылки слабые, выгруженные страницы выпадают из реестра сами. Скролл-вью пейджера публично не отдаётся (`private let scrollView` в `TesseraPagerViewController`), поэтому `PivotViewController` и `TesseraStartScreenViewController` находят его обходом прямых потомков корневого вида пейджера. Решение: обе половины контракта (решение по оси + блокировка детей) задействованы, но точка решения сдвинута с `gestureRecognizerShouldBegin` на `.began`; для полноценного §2 нужен публичный хук Core (аксессор горизонтального скролл-вью и/или назначение делегата пана) — открытый вопрос следующей версии, Core в v0.1 не менялся.
