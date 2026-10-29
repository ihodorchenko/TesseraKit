import XCTest
@testable import TesseraPanorama

/// Санити-тест скелета пакета (E0). Заменяется/дополняется тестами E3.7.
final class TesseraPanoramaSanityTests: XCTestCase {
    func testModuleSkeletonExists() {
        _ = TesseraPanorama.self
    }
}
