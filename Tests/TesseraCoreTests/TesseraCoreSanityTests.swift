import XCTest
@testable import TesseraCore

/// Санити-тест скелета пакета (E0). Заменяется/дополняется контрактными
/// тестами в E1.7: инвариант прогресса, снап, арбитраж жестов, RTL, Reduce Motion.
final class TesseraCoreSanityTests: XCTestCase {
    func testModuleSkeletonExists() {
        _ = TesseraCore.self
    }
}
