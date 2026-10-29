import XCTest
@testable import TesseraPivot

/// Санити-тест скелета пакета (E0). Заменяется/дополняется тестами E2.7.
final class TesseraPivotSanityTests: XCTestCase {
    func testModuleSkeletonExists() {
        _ = TesseraPivot.self
    }
}
