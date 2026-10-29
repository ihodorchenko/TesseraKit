# План

Сводная таблица задач с отметкой, что сделано, а что нет. Источник истины по объёму работ —
проектные документы в `docs/` (Core, Panorama, Pivot, StartScreen); правила процесса — `AGENTS.md`
(ветка задачи от `dev`, саб-агенты на подпункты, апрув перед коммитом, PR в `dev`). Парный файл
рисков — [RISK.md](RISK.md).

**Обновляется после каждой задачи.**

Статусы: ✅ готово, 🔶 частично, ⬜ не начато.

**Сейчас (29.10.2026):** проектная документация в `docs/` — источник истины; **E0 смержен в `dev`
(PR #2)**; **E1 (TesseraCore) смержен в `dev` (PR #4)** — 86 тестов зелёные; **E2 (TesseraPivot)
смержен в `dev` (PR #5)** — 58 тестов зелёные; **E3 (TesseraPanorama) — в работе** в ветке
`task/tessera-panorama` (волны субагентов Flash). Реализация E4 не начата. Ветки `main` и `dev`
существуют, работа — от `dev` в ветках `task/*` (PR-процесс: ветка → PR в `dev` → мерж после
апрува). План согласован с пользователем: эпики выполняются **последовательно**, CI пока не
добавляем (D3), коммит и мерж — только после апрува. К следующей задаче приступаем только по
команде пользователя, с предварительным описанием работ на апрув (D6 в `STATE.md`).

## E0 — Фундамент пакета · ветка `task/package-foundation` ✅

| Задача | Что | Статус |
|---|---|---|
| E0.1 | Тестовые таргеты в `Package.swift`: `Tests/TesseraCoreTests`, `Tests/TesseraPivotTests`, `Tests/TesseraPanoramaTests`, `Tests/TesseraStartScreenTests` | ✅ |
| E0.2 | Скелет каталогов `Sources/TesseraCore/{Pager,Parallax,Gesture,Hosting,Accessibility}` + группы в тестах | ✅ |
| E0.3 | Санити-прогон `swift build` + `swift test` на пустом скелете | ✅ |

## E1 — TesseraCore · ветка `task/tessera-core` ✅

| Задача | Что | Статус |
|---|---|---|
| E1.1 | `TesseraPager`: режимы `paged`/`snapping`, child-VC контейнеры, ленивая загрузка ±1, `TesseraPageDescriptor`, `TesseraPagerDelegate` (`didShowPage`, `didChangeProgress(_ t:)`) | ✅ |
| E1.2 | `TesseraSnapPolicy`: конфиг (порог скорости, выравнивание), расчёт в `targetContentOffset(forProposedContentOffset:withScrollingVelocity:)`, `decelerationRate = .fast` | ✅ |
| E1.3 | `TesseraParallaxLayer`: `backgroundOffset = offset × factor`, `factor ∈ (0,1)`, обе оси, запас размера за пределами `contentSize`, Reduce Motion → factor 0 | ✅ |
| E1.4 | `TesseraGestureArbiter`: доминирующая ось в `gestureRecognizerShouldBegin`, горизонталь — пейджеру, вертикаль — детям, поддержка нескольких детей | ✅ |
| E1.5 | `TesseraContentHosting`: `TesseraContentProviding` (UIViewController / `UIHostingController`), переиспользование хостингов, мост состояния через `ObservableObject` | ✅ |
| E1.6 | `TesseraAccessibilityKit`: `accessibilityScroll` для пагинации, RTL-нормализация `t`, анонсы смены страницы | ✅ |
| E1.7 | Контрактные тесты Core: инвариант `t` (LTR + RTL), снап (порог скорости, границы), арбитраж осей (2+ детей), Reduce Motion | ✅ |

Не входит в v1 (по CORE-IOS-DESIGN §5): `TesseraEdgeSwipePlugin`, `TesseraPerformanceKit` как
отдельный модуль, обобщённый reorder из StartScreen.

## E2 — TesseraPivot · ветка `task/tessera-pivot` ✅

| Задача | Что | Статус |
|---|---|---|
| E2.1 | `PivotViewController` + пейджер на `pagingEnabled` (режим `paged` из E1.1), child-VC страниц | ✅ |
| E2.2 | `PivotHeaderStripView` (`UICollectionView`) + индикатор: `lerp(center[i], center[i+1], frac(t))`, окраска по расстоянию от `t` | ✅ |
| E2.3 | Синхронизация: свайп → лента (без обратной записи), тап → `setContentOffset(animated:)`, автоцентрирование ленты по завершении | ✅ |
| E2.4 | Вертикальный скролл страниц (вариант B через E1.4), ленивая загрузка ±1, prefetch | ✅ |
| E2.5 | SwiftUI-фасад `PivotView` + UIKit API (`PivotSection`, `PivotStyle`, `PivotDelegate`) | ✅ |
| E2.6 | Accessibility: VoiceOver (`accessibilityScroll`, озвучивание секции), Dynamic Type (режим ленты при крупном шрифте), RTL | ✅ |
| E2.7 | Тесты: интерполяция индикатора на случайных наборах заголовков, синхронизация тап/свайп, RTL | ✅ |

Отрезано в v1 (по PIVOT-IOS-DESIGN §10): повторяющаяся/бесконечная лента, кастомные переходы,
заголовки-подписи.

## E3 — TesseraPanorama · ветка `task/tessera-panorama` ✅

| Задача | Что | Статус |
|---|---|---|
| E3.1 | `PanoScrollView`: кастомный снап (E1.2), peek 16–64 pt, `itemWidth = screenWidth − peek`, bounce на границах | ✅ |
| E3.2 | `PanoBackgroundView`: параллакс фона одной картинкой (E1.3), множитель 0.4–0.6, декодирование в масштабе экрана | ✅ |
| E3.3 | `PanoHeaderView`: заголовки секций, кусочно-линейная интерполяция по дробной части `t` | ✅ |
| E3.4 | Вертикальный скролл секций (вариант B), ленивая загрузка ±1, prefetch | ✅ |
| E3.5 | SwiftUI-фасад `PanoramaView` + UIKit API (`PanoramaSection`, `PanoramaStyle`, `PanoramaDelegate`) | ✅ |
| E3.6 | Accessibility: VoiceOver, Reduce Motion (без параллакса и анимаций заголовков), Dynamic Type, RTL | ✅ |
| E3.7 | Тесты: геометрия снапа (порог скорости, границы), интерполяция заголовков, RTL-прогресс | ✅ |

Отрезано в v1 (по PANORAMA-IOS-DESIGN §9): фон на каждую секцию, «наклон холста», сложный
рециклинг, edge-pan плагин.

## E4 — TesseraStartScreen · ветка `task/tessera-start-screen` (после E3)

| Задача | Что | Статус |
|---|---|---|
| E4.1 | Пейджер 3 страниц (хук | START | приложения), политика левого края (корневой экран / уступка системному жесту) | ⬜ |
| E4.2 | `TileLayoutEngine` + кастомный `UICollectionViewLayout`: юниты, размеры 1×1/2×2/4×2/4×4, жадная упаковка с «честными дырами» | ⬜ |
| E4.3 | `LiveTileEngine`: флипы (`CATransform3D` + `m34`), стахгер батчами, паузы (вне экрана/фон), бейджи, Reduce Motion → статичный фронт | ⬜ |
| E4.4 | `TileEditCoordinator`: long-press + «желе» (`CAKeyframeAnimation`, случайная фаза), unpin с fly-out, resize по циклу, собственный drag-координатор («расступание») — после E4.2 | ⬜ |
| E4.5 | `AppsListPage`: `UITableView` с jump-list + секция настроек, pin/unpin двусторонне через `TileStore` — после E4.2 | ⬜ |
| E4.6 | Параллакс обоев по вертикали (E1.3), `TileStore`-персистентность (JSON), фасад `StartScreenView`, `QuickPanelProviding`, accessibility (VoiceOver, Reduce Motion, Dynamic Type, RTL) | ⬜ |
| E4.7 | Тесты: жадная упаковка, drag-перестановка и resize на случайных конфигурациях плиток, pin/unpin-консистентность | ⬜ |

Отрезано в v1 (по STARTSCREEN-IOS-DESIGN §10): фото-слайдшоу, push-обновления, «идеальная»
упаковка без дыр, peek-анимация, 6-колоночная адаптация, deep-links.

## E5 — Релиз

| Задача | Что | Статус |
|---|---|---|
| E5.1 | Актуализировать `README.md` и `docs/` (если реализация отклонилась от проектных документов) | ⬜ |
| E5.2 | Полный прогон `swift build` + `swift test` по всем таргетам | ⬜ |
| E5.3 | PR `dev → main` (апрув), тег `0.1.0` | ⬜ |

## Итого

| Эпик | Готово |
|---|---|
| E0 Фундамент пакета | ✅ 3 из 3 |
| E1 TesseraCore | ✅ 7 из 7 |
| E2 TesseraPivot | ✅ 7 из 7 |
| E3 TesseraPanorama | ✅ 7 из 7 |
| E4 TesseraStartScreen | ⬜ 0 из 7 |
| E5 Релиз | ⬜ 0 из 3 |

## Вне плана

- CI (GitHub Actions) — решено не добавлять (29.10.2026); локальные `swift build`/`swift test` перед
  коммитом.
- Пример-приложение (Example-хост) — не входит в MVP пакета; отдельная задача, если понадобится.
- Публикация пакета в индексах SPM / документации на веб-площадке.
- Фичи v2: `TesseraEdgeSwipePlugin`, `TesseraPerformanceKit`, повторяющаяся лента Pivot,
  фото-слайдшоу в плитках и прочее «отрезанное в v1».

## Как вести план

- Статус каждого пункта обновляется в этом файле по ходу работы (✅ / 🔶 / ⬜).
- После закрытия эпика его ветка помечается ✅ в заголовке.
- При изменении объёма работ — правки сюда же, с комментарием в PR.
- Новые риски — в [RISK.md](RISK.md); отклонение реализации от `docs/` → обновить документ в той же
  ветке.
