import XCTest
@testable import TesseraPanorama

/// Sanity test for the package skeleton. Complemented by the component tests.
final class TesseraPanoramaSanityTests: XCTestCase {
    func testModuleSkeletonExists() {
        _ = TesseraPanorama.self
    }
}
