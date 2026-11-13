import XCTest
@testable import HarnessCore

final class FilesystemTests: XCTestCase {
    func testPathsAndStableIdentifiers() {
        XCTAssertEqual(FS.join("/tmp", "harness", "config.json"), "/tmp/harness/config.json")
        XCTAssertEqual(FS.friendly("/Users/example/.pi", home: "/Users/example"), "~/.pi")
        XCTAssertEqual(FS.id("a", "b"), FS.id("a", "b"))
        XCTAssertNotEqual(FS.id("a", "b"), FS.id("ab"))
    }
}
