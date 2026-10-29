import XCTest
@testable import TesseraStartScreen

/// Санити-тест скелета пакета (E0). Заменяется/дополняется тестами E4.7.
final class TesseraStartScreenSanityTests: XCTestCase {
    func testModuleSkeletonExists() {
        _ = TesseraStartScreen.self
    }
}
