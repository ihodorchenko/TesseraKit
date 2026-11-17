import XCTest
@testable import TesseraCore

/// Sanity test for the package skeleton. Complemented by the contract tests:
/// progress invariant, snapping, gesture arbitration, RTL, Reduce Motion.
final class TesseraCoreSanityTests: XCTestCase {
    func testModuleSkeletonExists() {
        _ = TesseraCore.self
    }
}
