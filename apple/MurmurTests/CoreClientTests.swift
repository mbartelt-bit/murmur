import XCTest

@testable import Murmur
import MurmurShared

/// One end-to-end call through the Rust core, on the simulator, against the real
/// xcframework: if `murmur-core`, the UniFFI bindings or the linkage were broken, this is the
/// test that would say so before any of the view-model suites got confusing.
final class CoreClientTests: XCTestCase {
    func testRulesCleanupThroughFFI() async {
        let result = await CoreClient.cleanLocally("um hello world")
        XCTAssertEqual(result.clean, "Hello world.")
        XCTAssertFalse(result.usedCloud)
    }
}
