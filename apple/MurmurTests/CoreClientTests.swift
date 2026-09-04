import XCTest

@testable import Murmur
import MurmurShared

/// These run on the simulator, so they exercise the real xcframework: if the Rust
/// core, the UniFFI bindings, or the linkage were broken, both cases would fail.
final class CoreClientTests: XCTestCase {
    func testKeyPageIsGroqConsole() {
        XCTAssertEqual(CoreClient.groqKeyPage(), "https://console.groq.com/keys")
    }

    func testRulesCleanupThroughFFI() async {
        let r = await CoreClient.cleanLocally("um hello world")
        XCTAssertEqual(r.clean, "Hello world.")
        XCTAssertFalse(r.usedCloud)
    }
}
