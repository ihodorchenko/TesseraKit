import UIKit

/// Нормализация прогресса пейджера по направлению чтения (LTR/RTL).
///
/// Контракт §2 `docs/Core-iOS-Design.md`: «в RTL `t` нормализуется от направления
/// чтения». Сырой `t = contentOffset.x / pageWidth` в RTL растёт против направления
/// чтения, поэтому его нельзя отдавать потребителям напрямую. После нормализации
/// `0` — первая страница в порядке чтения, `pageCount - 1` — последняя; индикатор
/// Pivot, заголовки Panorama и пейджер StartScreen работают с одним и тем же
/// знанием о направлении и не дублируют зеркалирование у себя.
///
/// Функции чистые: не читают состояние, не пишут `contentOffset` (§2 — единственные
/// писатели это пейджер и контроллер), не требуют главного потока, поэтому
/// пригодны для контрактных тестов E1.7.
public enum TesseraRTL {

    /// Переводит сырой прогресс пейджера в прогресс по направлению чтения.
    ///
    /// - LTR: `t` возвращается без изменений.
    /// - RTL: `CGFloat(pageCount - 1) - t` — зеркалирование относительно середины
    ///   ленты, чтобы крайние страницы поменялись местами, а дробная часть
    ///   (непрерывный прогресс перехода) сохранилась.
    /// - `pageCount <= 1`: возвращается `t` без изменений — нормализовывать нечего,
    ///   единственная страница всегда «первая» и «последняя» одновременно.
    ///
    /// Функция непрерывна и не округляет `t`: используется для анимаций
    /// (`frame`/`transform`/`alpha`, §2). Для дискретного индекса страницы есть
    /// ``pageIndex(for:pageCount:layoutDirection:)`` — у него другое правило
    /// округления, см. документацию метода.
    ///
    /// - Parameters:
    ///   - t: Сырой прогресс `contentOffset.x / pageWidth`.
    ///   - pageCount: Число страниц; значения `<= 1` трактуются как «нормализация
    ///     не нужна».
    ///   - layoutDirection: Направление раскладки интерфейса.
    /// - Returns: Прогресс по направлению чтения.
    public static func normalizedProgress(
        _ t: CGFloat,
        pageCount: Int,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> CGFloat {
        guard pageCount > 1 else { return t }
        guard layoutDirection == .rightToLeft else { return t }

        return CGFloat(pageCount - 1) - t
    }

    /// Индекс страницы для сырого прогресса `t` с учётом направления чтения.
    ///
    /// Правило (`docs/Core-iOS-Design.md` §2, «целая часть — индекс»):
    /// - LTR: `clamp(Int(t.rounded(.down)), 0, pageCount - 1)`.
    /// - RTL: `pageCount - 1 - <тот же clamp>` — сначала берётся индекс страницы,
    ///   занимающей видимую область, затем он зеркалится в порядок чтения.
    /// - `pageCount <= 1`: всегда `0`.
    ///
    /// Округление идёт до зеркалирования намеренно: индекс — это страница, которая
    /// сейчас в кадре, а не прогресс входа следующей. На дробном `t` это даёт
    /// `pageCount - 1 - floor(t)`, что на середине перехода отличается от
    /// `floor(normalizedProgress(t))` на единицу; для непрерывных анимаций нужно
    /// ``normalizedProgress(_:pageCount:layoutDirection:)``, а не этот метод.
    ///
    /// Защитные случаи: `NaN` даёт `0` (неопределённый прогресс трактуется как
    /// первая страница); бесконечности зажимаются границами, благодаря чему
    /// `Int(_:)` не может переполниться на мусорных промежуточных значениях.
    ///
    /// - Parameters:
    ///   - t: Сырой прогресс `contentOffset.x / pageWidth`.
    ///   - pageCount: Число страниц; значения `<= 1` дают `0`.
    ///   - layoutDirection: Направление раскладки интерфейса.
    /// - Returns: Индекс страницы в порядке чтения.
    public static func pageIndex(
        for t: CGFloat,
        pageCount: Int,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> Int {
        guard pageCount > 1 else { return 0 }

        let index = clampedIndex(for: t, pageCount: pageCount)
        guard layoutDirection == .rightToLeft else { return index }

        return pageCount - 1 - index
    }

    /// Дискретный индекс страницы в сырых координатах контента (LTR-порядок).
    ///
    /// Зажимает результат в `0...pageCount - 1` до преобразования в `Int`: так
    /// бесконечности и очень большие `t` не приводят к переполнению.
    ///
    /// - Parameters:
    ///   - t: Сырой прогресс.
    ///   - pageCount: Число страниц, строго больше единицы (проверяется вызывающим).
    /// - Returns: Индекс в `0...pageCount - 1`.
    private static func clampedIndex(for t: CGFloat, pageCount: Int) -> Int {
        guard !t.isNaN else { return 0 }

        let upperBound = CGFloat(pageCount - 1)
        let clamped = min(max(t.rounded(.down), 0), upperBound)

        return Int(clamped)
    }
}
