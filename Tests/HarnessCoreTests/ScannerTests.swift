import Foundation
import XCTest
@testable import HarnessCore

final class ScannerTests: XCTestCase {
    func testRepositoryInheritanceSymlinkDistinctionAndSharedDeduplication() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let globalShared = FS.parent(try writeSkill(home, ".agents/skills/shared", name: "shared"))
        _ = try writeSkill(home, ".agents/skills/same", name: "same")
        try makeDirectory(home, ".pi/agent")
        try writeSkill(home, "repos/project", name: "placeholder", file: "package.json", contents: "{}")
        let repo = FS.join(home, "repos", "project")
        try makeDirectory(home, "repos/project/.pi/skills")
        try FileManager.default.createSymbolicLink(atPath: FS.join(repo, ".pi/skills/shared-link"),
                                                   withDestinationPath: globalShared)
        _ = try writeSkill(home, "repos/project/.pi/skills/same", name: "same")

        let result = try scan(home: home, roots: [FS.join(home, "repos")])
        let repository = try XCTUnwrap(result.repositories.first)
        let globalSharedRows = result.targets.filter {
            $0.item.harnessID == "pi" && $0.item.scopeID == "global" && $0.item.name == "shared"
        }
        XCTAssertEqual(globalSharedRows.count, 1, "The shared Pi path should not produce duplicate registrations.")
        XCTAssertTrue(globalSharedRows[0].item.inheritedIn.contains(repository.id))

        let linked = try XCTUnwrap(result.targets.first { $0.item.harnessID == "pi" && $0.item.sourcePath == FS.join(repo, ".pi/skills/shared-link") })
        XCTAssertTrue(linked.item.inherited)
        XCTAssertFalse(linked.item.canUninstall)
        let referenced = try XCTUnwrap(result.targets.first { $0.item.id == linked.item.globalSourceID })
        XCTAssertEqual(referenced.item.scopeID, "global")
        XCTAssertEqual(try FS.realPath(referenced.item.sourcePath), try FS.realPath(globalShared))

        let localCopy = try XCTUnwrap(result.targets.first { $0.item.harnessID == "pi" && $0.item.sourcePath == FS.join(repo, ".pi/skills/same") })
        XCTAssertFalse(localCopy.item.inherited)
        XCTAssertTrue(localCopy.item.overridesGlobal)
        XCTAssertTrue(localCopy.item.canUninstall)
    }

    func testSystemSkillsAreProtectedAndMalformedConfigsOnlyWarnSafely() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        _ = try writeSkill(home, ".codex/skills/.system/built-in", name: "built-in")
        try write(home, ".claude.json", "{\"mcpServers\": {\"DO_NOT_EXPOSE_SECRET\" broken")

        let result = try scan(home: home, roots: [])
        let bundled = try XCTUnwrap(result.targets.first { $0.item.name == "built-in" })
        XCTAssertFalse(bundled.item.canUninstall)
        XCTAssertTrue(bundled.item.readOnlyReason?.contains("Bundled") == true)
        XCTAssertFalse(result.targets.contains { $0.item.kind == .mcp })
        XCTAssertTrue(result.warnings.contains { $0.message.contains("Configuration is unreadable") })
        XCTAssertFalse(String(describing: result.warnings).contains("DO_NOT_EXPOSE_SECRET"))
    }

    func testRepositoryLockfilesArePathScopedAndDoNotBorrowGlobalCreators() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        _ = try writeSkill(home, ".agents/skills/review", name: "review")
        _ = try writeSkill(home, "repos/project/.agents/skills/review", name: "review")
        _ = try writeSkill(home, "repos/project/.claude/skills/custom-folder", name: "review")
        try write(home, "repos/project/package.json", "{}")
        try write(home, ".agents/.skill-lock.json",
                  #"{"skills":{"review":{"source":"GlobalOwner/tools","sourceType":"github"}}}"#)
        try write(home, "repos/project/skills-lock.json",
                  #"{"skills":{"review":{"source":"RepoOwner/tools","sourceType":"github"}}}"#)

        let result = try scan(home: home, roots: [FS.join(home, "repos")])
        let local = try XCTUnwrap(result.targets.first { $0.item.sourcePath == FS.join(home, "repos/project/.agents/skills/review") })
        let global = try XCTUnwrap(result.targets.first { $0.item.scopeID == "global" && $0.item.name == "review" })
        let unrelated = try XCTUnwrap(result.targets.first { $0.item.sourcePath == FS.join(home, "repos/project/.claude/skills/custom-folder") })
        XCTAssertEqual(local.item.provenance.creator, "RepoOwner")
        XCTAssertEqual(global.item.provenance.creator, "GlobalOwner")
        XCTAssertNil(unrelated.item.provenance.creator)
        XCTAssertNil(unrelated.item.provenance.sourceLabel)
    }

    func testImportedAndOverrideOnlyMCPEntriesAndSymlinkConfigsAreReadOnly() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try write(home, ".pi/agent/mcp-adapter.json",
                  #"{"imports":["codex"],"mcpServers":{"override":{"disabled":true}}}"#)
        try write(home, ".codex/config.toml", "[mcp_servers.imported]\ncommand = \"not-executed\"\n")
        try write(home, "owned.json", #"{"mcpServers":{"remote":{"url":"https://example.invalid"}}}"#)
        try makeDirectory(home, ".cursor")
        try FileManager.default.createSymbolicLink(atPath: FS.join(home, ".cursor/mcp.json"),
                                                   withDestinationPath: FS.join(home, "owned.json"))

        let result = try scan(home: home, roots: [])
        let override = try XCTUnwrap(result.targets.first { $0.item.name == "override" && $0.item.harnessID == "pi" })
        XCTAssertFalse(override.item.enabled)
        XCTAssertFalse(override.item.canUninstall)
        XCTAssertTrue(override.item.readOnlyReason?.contains("re-enable") == true)

        let imported = try XCTUnwrap(result.targets.first { $0.item.name == "imported" && $0.item.harnessID == "pi" })
        XCTAssertFalse(imported.item.canUninstall)
        XCTAssertTrue(imported.item.readOnlyReason?.contains("Imported from codex") == true)

        let symlinked = try XCTUnwrap(result.targets.first { $0.item.name == "remote" && $0.item.harnessID == "cursor" })
        XCTAssertFalse(symlinked.item.canUninstall)
        XCTAssertTrue(symlinked.item.readOnlyReason?.contains("configuration is a symlink") == true)
    }

    func testPublicSourceRemovesCredentialsAndOrderedFiltersSupportGlobsAndBraces() throws {
        let source = ProvenanceResolver.publicSource(
            .string("https://token:PRIVATE_TOKEN@github.com/Publisher/tools.git?key=PRIVATE_QUERY#fragment"), type: "github")
        XCTAssertEqual(source?.creator, "Publisher")
        XCTAssertEqual(source?.sourceLabel, "Publisher/tools")
        XCTAssertEqual(source?.sourceURL, "https://github.com/Publisher/tools")
        XCTAssertFalse(String(describing: source).contains("PRIVATE"))

        let base = "/tmp/filter-fixture"
        let rule = ResourceFilters.rule(patterns: ["!**/skills/**", "+**/skills/allowed/{one,two}/SKILL.md"], baseDir: base)
        XCTAssertTrue(ResourceFilters.enabled(file: FS.join(base, "skills/allowed/one/SKILL.md"), rules: [rule]))
        XCTAssertTrue(ResourceFilters.enabled(file: FS.join(base, "skills/allowed/two/SKILL.md"), rules: [rule]))
        XCTAssertFalse(ResourceFilters.enabled(file: FS.join(base, "skills/blocked/SKILL.md"), rules: [rule]))

        let ordered = ResourceFilters.rule(patterns: ["**/skills/**", "!**/skills/blocked/**"], baseDir: base)
        XCTAssertTrue(ResourceFilters.enabled(file: FS.join(base, "skills/allowed/SKILL.md"), rules: [ordered]))
        XCTAssertFalse(ResourceFilters.enabled(file: FS.join(base, "skills/blocked/SKILL.md"), rules: [ordered]))
    }

    private func makeHome() throws -> String {
        let home = FS.join(FileManager.default.temporaryDirectory.path, "harness-scanner-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        return try FS.realPath(home)
    }

    @discardableResult
    private func writeSkill(_ home: String, _ relative: String, name: String,
                            file: String = "SKILL.md", contents: String? = nil) throws -> String {
        let text = contents ?? "---\nname: \(name)\ndescription: Example skill\n---\n"
        return try write(home, FS.join(relative, file), text)
    }

    private func write(_ home: String, _ relative: String, _ contents: String) throws -> String {
        let path = FS.join(home, relative)
        try FileManager.default.createDirectory(atPath: FS.parent(path), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func makeDirectory(_ home: String, _ relative: String) throws {
        try FileManager.default.createDirectory(atPath: FS.join(home, relative), withIntermediateDirectories: true)
    }

    private func scan(home: String, roots: [String]) throws -> ScanResult {
        try InventoryScanner.scan(options: ManagerOptions(home: home, scanRoots: roots,
                                                         stateDir: FS.join(home, "state")),
                                  explicitRepositories: [])
    }
}
