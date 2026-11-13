import Darwin
import Foundation
import XCTest
@testable import HarnessCore

final class AccessControlTests: XCTestCase, @unchecked Sendable {
    private func aclText(_ path: String) throws -> String {
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else {
            if FS.exists(path), errno == ENOENT { return "" }
            throw ManagerError("Cannot inspect synthetic ACL")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        guard let text = acl_to_text(acl, &length) else { throw ManagerError("Cannot describe synthetic ACL") }
        defer { acl_free(text) }
        return String(cString: text)
    }
    func testConfigRemovalAndRestorePreserveACLsXattrsAndPermissions() async throws {
        let fixture = try DemoEnvironment.create(); defer { try? fixture.cleanUp() }
        let file = FS.join(fixture.options.home, ".cursor/mcp.json")
        XCTAssertEqual(chmod(file, 0o644), 0)
        let chmodACL = Process(); chmodACL.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmodACL.arguments = ["+a", "user:daemon deny read", file]
        try chmodACL.run(); chmodACL.waitUntilExit(); XCTAssertEqual(chmodACL.terminationStatus, 0)
        let value = Data("synthetic-xattr".utf8)
        let set = value.withUnsafeBytes { setxattr(file, "org.harnessmanager.fixture", $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(set, 0)
        let beforeACL = try aclText(file), original = try FS.readData(file)
        let manager = InventoryManager(options: fixture.options)
        let state = try await manager.snapshot()
        let item = try XCTUnwrap(state.items.first { $0.harnessID == "cursor" && $0.kind == .mcp })
        let result = try await manager.remove(requests: [.init(item)], scopeID: "global", confirmation: "UNINSTALL 1")
        XCTAssertNil(result.error); XCTAssertEqual(try aclText(file), beforeACL); XCTAssertEqual(try FS.mode(file), 0o644)
        var bytes = [UInt8](repeating: 0, count: value.count)
        XCTAssertEqual(getxattr(file, "org.harnessmanager.fixture", &bytes, bytes.count, 0, 0), value.count)
        XCTAssertEqual(Data(bytes), value)
        // A user tightening permissions after removal must not be undone by restore.
        XCTAssertEqual(chmod(file, 0o600), 0)
        _ = try await manager.restore(id: result.backupIDs[0])
        XCTAssertEqual(try FS.readData(file), original); XCTAssertEqual(try aclText(file), beforeACL)
        XCTAssertEqual(try FS.mode(file), 0o600)
    }
    func testPrivateStorageDoesNotRetainInheritedACLGrants() throws {
        let fixture = try DemoEnvironment.create(); defer { try? fixture.cleanUp() }
        let folder = FS.join(fixture.root, "private-storage")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let command = Process(); command.executableURL = URL(fileURLWithPath: "/bin/chmod")
        command.arguments = ["+a", "user:daemon allow read,search", folder]
        try command.run(); command.waitUntilExit(); XCTAssertEqual(command.terminationStatus, 0)
        XCTAssertTrue(try aclText(folder).contains("allow"))
        try FS.privateDirectory(folder)
        XCTAssertFalse(try aclText(folder).contains("allow")); XCTAssertEqual(try FS.mode(folder), 0o700)
    }
}
