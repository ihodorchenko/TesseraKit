import XCTest
@testable import TesseraPivot

/// Sanity test for the package skeleton. Complemented by the component tests.
final class TesseraPivotSanityTests: XCTestCase {
    func testModuleSkeletonExists() {
        _ = TesseraPivot.self
    }
}
