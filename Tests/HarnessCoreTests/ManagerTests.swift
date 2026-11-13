import Darwin
import Foundation
import XCTest
@testable import HarnessCore

final class ManagerTests: XCTestCase, @unchecked Sendable {
    private func write(_ fixture: DemoEnvironment, _ path: String, _ text: String) throws -> String {
        let file = FS.join(fixture.options.home, path)
        try FileManager.default.createDirectory(atPath: FS.parent(file), withIntermediateDirectories: true)
        try FS.atomicWrite(file, text: text); return file
    }
    private func mustRefuse(_ contains: String? = nil, _ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Unsafe operation was accepted") }
        catch { if let contains { XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains(contains), error.localizedDescription) } }
    }
    func testSkillRemovalHasPrivateBackupAndExactRestore() async throws {
        let f = try DemoEnvironment.create(); defer { try? f.cleanUp() }
        let manager = InventoryManager(options: f.options)
        let before = try await manager.snapshot()
        let item = try XCTUnwrap(before.items.first { $0.name == "project-planning" && $0.harnessID == "claude" })
        let original = try FS.readText(FS.join(item.sourcePath, "SKILL.md"))
        let result = try await manager.remove(requests: [.init(item)], scopeID: "global", confirmation: "UNINSTALL 1")
        XCTAssertFalse(FS.exists(item.sourcePath)); XCTAssertEqual(result.removedCount, 1); XCTAssertNil(result.error)
        XCTAssertEqual(try FS.mode(f.options.stateDir), 0o700)
        let backups = try await manager.listBackups(); let backup = try XCTUnwrap(backups.first)
        XCTAssertTrue(backup.canRestore)
        _ = try await manager.restore(id: backup.id)
        XCTAssertEqual(try FS.readText(FS.join(item.sourcePath, "SKILL.md")), original)
        let after = try await manager.listBackups(); XCTAssertEqual(after.first?.status, .restored)
    }
    func testGlobalLinkRemovalDoesNotDeleteTarget() async throws {
        let f = try DemoEnvironment.create(); defer { try? f.cleanUp() }
        let manager = InventoryManager(options: f.options)
        let state = try await manager.snapshot()
        let item = try XCTUnwrap(state.items.first { $0.name == "code-review" && $0.sourceType == .symlink })
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: item.sourcePath)
        let removed = try await manager.remove(requests: [.init(item)], scopeID: "global", confirmation: "UNINSTALL 1")
        XCTAssertFalse(FS.exists(item.sourcePath)); XCTAssertTrue(FS.exists(target))
        _ = try await manager.restore(id: removed.backupIDs[0])
        XCTAssertTrue(FS.isSymlink(item.sourcePath)); XCTAssertTrue(FS.exists(target))
    }
    func testSharedPhysicalRegistrationsAreMovedOnlyOnce() async throws {
        let f = try DemoEnvironment.create(); defer { try? f.cleanUp() }
        let manager = InventoryManager(options: f.options)
        let selected = try await manager.snapshot().items.filter { $0.name == "design-system" && $0.scopeID == "global" }
        XCTAssertGreaterThan(selected.count, 1)
        let result = try await manager.remove(requests: selected.map(RemovalRequest.init), scopeID: "global", confirmation: "UNINSTALL \(selected.count)")
        XCTAssertEqual(result.removedCount, 1); XCTAssertEqual(result.backupIDs.count, 1)
    }
    func testJSONBatchSavesOnePrivateExactRestorableBackupAndNoSecrets() async throws {
        let f = try DemoEnvironment.create(); defer { try? f.cleanUp() }
        let original = "{\n\"mcpServers\":{\"one\":{\"command\":\"private-command\",\"env\":{\"TOKEN\":\"SECRET_MUST_STAY_LOCAL\"}},\"two\":{\"command\":\"two\"},\"keep\":{\"url\":\"https://private.invalid/token\"}},\"theme\":\"light\"\n}"
        let file = try write(f, ".claude.json", original)
        let manager = InventoryManager(options: f.options)
        let state = try await manager.snapshot()
        let encoded = String(decoding: try JSONEncoder().encode(state.items), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SECRET_MUST_STAY_LOCAL")); XCTAssertFalse(encoded.contains("private-command")); XCTAssertFalse(encoded.contains("private.invalid"))
        let selected = state.items.filter { $0.harnessID == "claude" && ["one", "two"].contains($0.name) }
        XCTAssertEqual(selected.count, 2)
        let result = try await manager.remove(requests: selected.map(RemovalRequest.init), scopeID: "global", confirmation: "UNINSTALL 2")
        XCTAssertEqual(result.removedCount, 2); XCTAssertEqual(result.backupIDs.count, 1)
        let updated = try Configuration.parse(FS.readText(file), format: .json)
        XCTAssertEqual(Set(updated["mcpServers"]?.object?.keys.map { $0 } ?? []), ["keep"])
        let payload = FS.join(f.options.stateDir, "backups", result.backupIDs[0], "payload")
        XCTAssertEqual(try FS.mode(payload), 0o600)
        _ = try await manager.restore(id: result.backupIDs[0]); XCTAssertEqual(try FS.readText(file), original)
    }
    func testTOMLAndYAMLBatchEditsRestoreOriginalBytes() async throws {
        let f = try DemoEnvironment.create(); defer { try? f.cleanUp() }
        let manager = InventoryManager(options: f.options)
        for (harness, relative) in [("codex", ".codex/config.toml"), ("continue", ".continue/config.yaml")] {
            let file = FS.join(f.options.home, relative), original = try FS.readText(file)
            let items = try await manager.snapshot().items.filter { $0.harnessID == harness && $0.kind == .mcp && $0.scopeID == "global" }
            XCTAssertEqual(items.count, 2); XCTAssertTrue(items.allSatisfy(\.canUninstall))
            let result = try await manager.remove(requests: items.map(RemovalRequest.init), scopeID: "global", confirmation: "UNINSTALL 2")
            XCTAssertNil(result.error); XCTAssertEqual(result.removedCount, 2); XCTAssertEqual(result.backupIDs.count, 1)
            _ = try await manager.restore(id: result.backupIDs[0]); XCTAssertEqual(try FS.readText(file), original)
        }
    }
    func testStaleConfigMemberRefusesWholeBatch() async throws {
        let f = try DemoEnvironment.create(); defer { try? f.cleanUp() }
        let manager = InventoryManager(options: f.options), state = try await manager.snapshot()
        let skill = try XCTUnwrap(state.items.first { $0.name == "project-planning" && $0.harnessID == "claude" })
        let mcp = try XCTUnwrap(state.items.first { $0.harnessID == "cursor" && $0.kind == .mcp })
        let original = try FS.readText(mcp.sourcePath)
        try FS.atomicWrite(mcp.sourcePath, text: original + "\n")
        await mustRefuse("changed") { _ = try await manager.remove(requests: [.init(skill), .init(mcp)], scopeID: "global", confirmation: "UNINSTALL 2") }
        XCTAssertTrue(FS.exists(skill.sourcePath)); let backups = try await manager.listBackups(); XCTAssertTrue(backups.isEmpty)
    }
    func testChangedSkillContentsInvalidateConfirmation() async throws {
        let f = try DemoEnvironment.create(); defer { try? f.cleanUp() }
        let manager = InventoryManager(options: f.options)
        let current = try await manager.snapshot()
        let item = try XCTUnwrap(current.items.first { $0.name == "project-planning" && $0.harnessID == "claude" })
        let document = FS.join(item.sourcePath, "SKILL.md")
        try FS.atomicWrite(document, text: FS.readText(document) + "\nNewer edits\n")
        await mustRefuse("changed") { _ = try await manager.remove(requests: [.init(item)], scopeID: "global", confirmation: "UNINSTALL 1") }
        XCTAssertTrue(FS.exists(item.sourcePath))
    }
    func testProtectedAndWrongScopeEntriesRejectWholeSelection() async throws {
        let f = try DemoEnvironment.create(); defer { try? f.cleanUp() }
        let manager = InventoryManager(options: f.options), state = try await manager.snapshot()
        let ordinary = try XCTUnwrap(state.items.first { $0.name == "project-planning" && $0.harnessID == "claude" })
        let protected = try XCTUnwrap(state.items.first { $0.name == "skill-installer" })
        await mustRefuse { _ = try await manager.remove(requests: [.init(ordinary), .init(protected)], scopeID: "global", confirmation: "UNINSTALL 2") }
        let repo = try XCTUnwrap(state.repositories.first)
        await mustRefuse("scope") { _ = try await manager.remove(requests: [.init(ordinary)], scopeID: repo.id, confirmation: "UNINSTALL 1") }
        XCTAssertTrue(FS.exists(ordinary.sourcePath))
    }
    func testRestoreRefusesNewerConfigurationAndOccupiedSkill() async throws {
        let f = try DemoEnvironment.create(); defer { try? f.cleanUp() }
        let manager = InventoryManager(options: f.options), state = try await manager.snapshot()
        let mcp = try XCTUnwrap(state.items.first { $0.harnessID == "cursor" && $0.kind == .mcp })
        let result = try await manager.remove(requests: [.init(mcp)], scopeID: "global", confirmation: "UNINSTALL 1")
        let newer = "{\"mcpServers\":{},\"newer\":true}"
        try FS.atomicWrite(mcp.sourcePath, text: newer)
        await mustRefuse("changed") { _ = try await manager.restore(id: result.backupIDs[0]) }
        XCTAssertEqual(try FS.readText(mcp.sourcePath), newer)
        let skill = try XCTUnwrap(state.items.first { $0.name == "project-planning" && $0.harnessID == "claude" })
        let removed = try await manager.remove(requests: [.init(skill)], scopeID: "global", confirmation: "UNINSTALL 1")
        try FileManager.default.createDirectory(atPath: skill.sourcePath, withIntermediateDirectories: true)
        await mustRefuse("occupies") { _ = try await manager.restore(id: removed.backupIDs[0]) }
    }
    func testRestoreRefusesParentRedirectAndConfigurationSymlink() async throws {
        let f = try DemoEnvironment.create(); defer { try? f.cleanUp() }
        let manager = InventoryManager(options: f.options), state = try await manager.snapshot()
        let item = try XCTUnwrap(state.items.first { $0.name == "project-planning" && $0.harnessID == "claude" })
        let result = try await manager.remove(requests: [.init(item)], scopeID: "global", confirmation: "UNINSTALL 1")
        let parent = FS.parent(item.sourcePath), previous = parent + "-original", redirect = FS.join(f.root, "redirect")
        try FileManager.default.moveItem(atPath: parent, toPath: previous)
        try FileManager.default.createDirectory(atPath: redirect, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: parent, withDestinationPath: redirect)
        await mustRefuse("parent") { _ = try await manager.restore(id: result.backupIDs[0]) }
        XCTAssertFalse(FS.exists(FS.join(redirect, FS.name(item.sourcePath))))
    }
    func testPackageUnregisterPreservesCacheAndOtherScopeAndRestoresExactly() async throws {
        let f = try DemoEnvironment.create(); defer { try? f.cleanUp() }
        let manager = InventoryManager(options: f.options), state = try await manager.snapshot()
        let package = try XCTUnwrap(state.packages.first { $0.name == "@example/engineering-kit" && $0.scopeID == "global" })
        let original = try FS.readText(package.settingsPath)
        let cache = FS.join(f.options.home, ".pi/agent/npm/node_modules/@example/engineering-kit")
        let result = try await manager.removePackage(id: package.id, fingerprint: package.fingerprint, scopeID: "global", confirmation: package.name)
        XCTAssertTrue(FS.exists(cache)); XCTAssertTrue(FS.exists(FS.join(cache, "extensions/audit/index.ts")))
        let after = try await manager.snapshot()
        XCTAssertFalse(after.packages.contains { $0.id == package.id })
        XCTAssertTrue(after.packages.contains { $0.name == package.name && $0.scopeID != "global" })
        _ = try await manager.restore(id: result.backupIDs[0]); XCTAssertEqual(try FS.readText(package.settingsPath), original)
    }
    func testInvalidSelectionsAndBackupTraversalAreRefused() async throws {
        let f = try DemoEnvironment.create(); defer { try? f.cleanUp() }
        let manager = InventoryManager(options: f.options)
        await mustRefuse { _ = try await manager.remove(requests: [], scopeID: "global", confirmation: "UNINSTALL 0") }
        let current = try await manager.snapshot()
        let item = try XCTUnwrap(current.items.first { $0.canUninstall })
        await mustRefuse { _ = try await manager.remove(requests: [.init(item), .init(item)], scopeID: "global", confirmation: "UNINSTALL 2") }
        await mustRefuse { _ = try await manager.remove(requests: [.init(item)], scopeID: "global", confirmation: "UNINSTALL 2") }
        await mustRefuse("identifier") { _ = try await manager.restore(id: "../../payload") }
        XCTAssertTrue(FS.exists(item.sourcePath)); let backups = try await manager.listBackups(); XCTAssertTrue(backups.isEmpty)
    }
    func testAddRepositoryOutsideDefaultRoots() async throws {
        let f = try DemoEnvironment.create(); defer { try? f.cleanUp() }
        let extra = FS.join(f.options.home, "elsewhere", "extra-project")
        try FileManager.default.createDirectory(atPath: extra, withIntermediateDirectories: true)
        let manager = InventoryManager(options: f.options)
        try await manager.addRepository(path: extra)
        let state = try await manager.snapshot(); XCTAssertTrue(state.repositories.contains { $0.path == (try? FS.realPath(extra)) })
        await mustRefuse { try await manager.addRepository(path: "relative/path") }
    }
}
