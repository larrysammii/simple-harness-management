import Darwin
import Foundation
import XCTest
@testable import HarnessCore

final class SafetyRegressionTests: XCTestCase, @unchecked Sendable {
    func testPiSettingsWithoutSkillFiltersDoNotDisableGlobalSkills() async throws {
        let f = try DemoEnvironment.create(); defer { try? f.cleanUp() }
        let state = try await InventoryManager(options: f.options).snapshot()
        let sharedPi = state.items.filter { $0.scopeID == "global" && $0.harnessID == "pi" && $0.kind == .skill && $0.packageName == nil }
        XCTAssertFalse(sharedPi.isEmpty); XCTAssertTrue(sharedPi.allSatisfy(\.enabled))
        let packaged = state.items.filter { $0.harnessID == "pi" && $0.scopeID == "global" && $0.packageName == "@example/engineering-kit" }
        let scan = try InventoryScanner.scan(options: f.options, explicitRepositories: [])
        let rules = scan.registry.skills.first { $0.packageName == "@example/engineering-kit" && $0.scopeID == "global" }?.rules ?? []
        XCTAssertEqual(packaged.first { $0.name == "change-review" }?.enabled, true, "Package rules: \(rules); item: \(packaged.first { $0.name == "change-review" }?.sourcePath ?? "missing")")
        XCTAssertEqual(packaged.first { $0.name == "release-notes" }?.enabled, false)
    }
    func testPackageContentChangesInvalidateConfirmationEvenWhenCountsMatch() async throws {
        let f = try DemoEnvironment.create(); defer { try? f.cleanUp() }
        let manager = InventoryManager(options: f.options), state = try await manager.snapshot()
        let package = try XCTUnwrap(state.packages.first { $0.name == "@example/engineering-kit" && $0.scopeID == "global" })
        let settings = try FS.readText(package.settingsPath)
        let file = FS.join(f.options.home, ".pi/agent/npm/node_modules/@example/engineering-kit/extensions/audit/index.ts")
        try FS.atomicWrite(file, text: "throw new Error('CHANGED_BUT_NEVER_EXECUTED');\n")
        do {
            _ = try await manager.removePackage(id: package.id, fingerprint: package.fingerprint, scopeID: "global", confirmation: package.name)
            XCTFail("A stale package confirmation was accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertEqual(try FS.readText(package.settingsPath), settings)
    }
    func testChangedSkillBackupPayloadIsNotRestored() async throws {
        let f = try DemoEnvironment.create(); defer { try? f.cleanUp() }
        let manager = InventoryManager(options: f.options), state = try await manager.snapshot()
        let item = try XCTUnwrap(state.items.first { $0.name == "project-planning" && $0.harnessID == "claude" })
        let result = try await manager.remove(requests: [.init(item)], scopeID: "global", confirmation: "UNINSTALL 1")
        let payload = FS.join(f.options.stateDir, "backups", result.backupIDs[0], "payload", "SKILL.md")
        try FS.atomicWrite(payload, text: "Changed recovery content")
        do { _ = try await manager.restore(id: result.backupIDs[0]); XCTFail("Modified backup content was restored") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertFalse(FS.exists(item.sourcePath))
    }
    func testOverlappingPathsAreRejectedBeforeRemoval() async throws {
        let f = try DemoEnvironment.create(); defer { try? f.cleanUp() }
        var paths: [String] = []
        for name in ["parent", "parent-a", "parent/child"] {
            let folder = FS.join(f.options.home, "custom", name); paths.append(folder)
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try FS.atomicWrite(FS.join(folder, "SKILL.md"), text: "---\nname: \(name.replacingOccurrences(of: "/", with: "-"))\n---\n")
        }
        let data = try JSONSerialization.data(withJSONObject: ["skills": paths])
        try FS.atomicWrite(FS.join(f.options.home, ".pi/agent/settings.json"), data: data)
        let manager = InventoryManager(options: f.options)
        let selected = try await manager.snapshot().items.filter { ["parent", "parent-a", "parent-child"].contains($0.name) && $0.harnessID == "pi" }
        XCTAssertEqual(selected.count, 3)
        do { _ = try await manager.remove(requests: selected.map(RemovalRequest.init), scopeID: "global", confirmation: "UNINSTALL 3"); XCTFail("Overlapping sources were accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("overlap")) }
        XCTAssertTrue(paths.allSatisfy(FS.exists))
    }
    func testMidBatchFailureReportsPartialCompletionAndKeepsBackups() async throws {
        guard geteuid() != 0 else { return }
        let f = try DemoEnvironment.create(); defer { try? f.cleanUp() }
        var paths: [String] = []
        for name in ["a/one", "b/two", "c/three"] {
            let folder = FS.join(f.options.home, "custom", name); paths.append(folder)
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try FS.atomicWrite(FS.join(folder, "SKILL.md"), text: "---\nname: \(FS.name(name))\n---\n")
        }
        try FS.atomicWrite(FS.join(f.options.home, ".pi/agent/settings.json"), data: JSONSerialization.data(withJSONObject: ["skills": paths]))
        let manager = InventoryManager(options: f.options)
        let items = try await manager.snapshot().items.filter { ["one", "two", "three"].contains($0.name) && $0.harnessID == "pi" }
        XCTAssertEqual(items.count, 3)
        let blockedParent = FS.parent(paths[1]); XCTAssertEqual(chmod(blockedParent, 0o500), 0)
        defer { _ = chmod(blockedParent, 0o700) }
        let report = try await manager.remove(requests: items.map(RemovalRequest.init), scopeID: "global", confirmation: "UNINSTALL 3")
        XCTAssertTrue(report.isPartial); XCTAssertEqual(report.removedCount, 1); XCTAssertEqual(report.notProcessedCount, 2)
        XCTAssertEqual(report.backupIDs.count, 1); XCTAssertTrue(FS.exists(paths[1])); XCTAssertTrue(FS.exists(paths[2]))
        _ = try await manager.restore(id: report.backupIDs[0]); XCTAssertTrue(FS.exists(paths[0]))
    }
}
