import Foundation
import XCTest
@testable import HarnessCore

final class PackageTests: XCTestCase {
    private let packageSource = "npm:@vigolium/piolium"

    func testScopedNpmDeclarationsGroupAndInventoryAllResourceKindsWithoutExecutingExtensions() throws {
        try withTemporaryDirectory { home in
            let piHome = home + "/.pi/agent"
            let packageRoot = piHome + "/npm/node_modules/@vigolium/piolium"
            try write("""
            {"name":"@vigolium/piolium","version":"0.0.15","scripts":{"preuninstall":"THROW_SENTINEL"},
             "pi":{"skills":["./skills"],"extensions":["./extensions"],"prompts":["./prompts"],"themes":["./themes"]}}
            """, to: packageRoot + "/package.json")
            try write("---\nname: one\n---\n", to: packageRoot + "/skills/one/SKILL.md")
            try write("throw new Error('EXTENSION_THROW_SENTINEL')", to: packageRoot + "/extensions/audit/index.ts")
            try write("Synthetic prompt", to: packageRoot + "/prompts/audit.md")
            try write("{}", to: packageRoot + "/themes/night.json")
            try write(try json(["packages": ["npm:@vigolium/piolium@0.0.15", ["source": packageSource,
                                                                           "skills": [], "extensions": [], "prompts": [], "themes": []]]]),
                      to: piHome + "/settings.json")

            var warnings: [ScanWarning] = []
            let options = options(home: home)
            let installed = try NativePackages.discover(options: options, piHome: piHome, repositories: [], warnings: &warnings)

            XCTAssertEqual(installed.count, 1)
            XCTAssertEqual(installed[0].sources, ["npm:@vigolium/piolium@0.0.15", packageSource])
            XCTAssertEqual(installed[0].indexes, [0, 1])
            XCTAssertEqual(installed[0].info.name, "@vigolium/piolium")
            XCTAssertEqual(installed[0].info.version, "0.0.15")
            XCTAssertEqual(installed[0].info.resources["skills"]?.installed, 1)
            XCTAssertEqual(installed[0].info.resources["skills"]?.enabled, 0)
            XCTAssertEqual(installed[0].info.resources["extensions"]?.installed, 1)
            XCTAssertEqual(installed[0].info.resources["extensions"]?.enabled, 0)
            XCTAssertEqual(installed[0].info.resources["prompts"]?.installed, 1)
            XCTAssertEqual(installed[0].info.resources["prompts"]?.enabled, 0)
            XCTAssertEqual(installed[0].info.resources["themes"]?.installed, 1)
            XCTAssertEqual(installed[0].info.resources["themes"]?.enabled, 0)
            XCTAssertTrue(installed[0].info.cachePresent)
            XCTAssertTrue(installed[0].info.inventoryComplete)

            var registry = Registry()
            try NativePackages.addSources(to: &registry, options: options, repositories: [], warnings: &warnings)
            XCTAssertTrue(registry.skills.contains { $0.packageName == "@vigolium/piolium" && $0.packageID == installed[0].info.id })
            XCTAssertEqual(try String(contentsOfFile: packageRoot + "/extensions/audit/index.ts", encoding: .utf8),
                           "throw new Error('EXTENSION_THROW_SENTINEL')")
            XCTAssertFalse(warnings.contains { $0.message.contains("EXTENSION_THROW_SENTINEL") })
        }
    }

    func testGlobalAndRepositoryDeclarationsShareIdentityAndReportOtherScopes() throws {
        try withTemporaryDirectory { home in
            let piHome = home + "/.pi/agent"
            let repoPath = home + "/repo/project"
            try write("{}", to: piHome + "/npm/node_modules/shared/package.json")
            try write(try json(["packages": ["npm:shared@1.0.0"]]), to: piHome + "/settings.json")
            try write(try json(["packages": [["source": "npm:shared", "skills": ["skills"]]]]),
                      to: repoPath + "/.pi/settings.json")
            let repository = Repository(id: "repo-project", name: "project", path: repoPath, displayPath: "~/repo/project")

            var warnings: [ScanWarning] = []
            let installed = try NativePackages.discover(options: options(home: home), piHome: piHome,
                                                        repositories: [repository], warnings: &warnings)
            XCTAssertEqual(installed.count, 2)
            let global = try XCTUnwrap(installed.first { $0.info.scopeID == "global" })
            let local = try XCTUnwrap(installed.first { $0.info.scopeID == repository.id })
            XCTAssertEqual(global.info.identityKey, local.info.identityKey)
            XCTAssertEqual(global.info.otherScopes, [repository.id])
            XCTAssertEqual(local.info.otherScopes, ["global"])
        }
    }

    func testMissingCacheIsReportedWithoutFetching() throws {
        try withTemporaryDirectory { home in
            let piHome = home + "/.pi/agent"
            try write(try json(["packages": ["npm:offline-only"]]), to: piHome + "/settings.json")
            var warnings: [ScanWarning] = []
            let installed = try NativePackages.discover(options: options(home: home), piHome: piHome,
                                                        repositories: [], warnings: &warnings)
            let package = try XCTUnwrap(installed.first)
            XCTAssertFalse(package.info.cachePresent)
            XCTAssertTrue(package.info.inventoryComplete)
            XCTAssertTrue(package.info.resources.values.allSatisfy { $0.installed == 0 && $0.enabled == 0 })
            XCTAssertEqual(package.roots.count, 1)
        }
    }

    func testSymlinkedSettingsAndDirectResourceReferencesBlockUnregister() throws {
        try withTemporaryDirectory { home in
            let piHome = home + "/.pi/agent"
            let packageRoot = piHome + "/npm/node_modules/tool"
            try write("{\"name\":\"tool\",\"pi\":{\"extensions\":[\"extensions\"]}}", to: packageRoot + "/package.json")
            let owner = home + "/settings-owner.json"
            try write(try json(["packages": ["npm:tool"]]), to: owner)
            try FileManager.default.createDirectory(atPath: piHome, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: piHome + "/settings.json", withDestinationPath: owner)

            var warnings: [ScanWarning] = []
            var installed = try NativePackages.discover(options: options(home: home), piHome: piHome,
                                                        repositories: [], warnings: &warnings)
            XCTAssertFalse(try XCTUnwrap(installed.first).info.canUninstall)
            XCTAssertTrue(try XCTUnwrap(installed.first).info.readOnlyReason?.contains("symlink") == true)

            try FileManager.default.removeItem(atPath: piHome + "/settings.json")
            try write(try json(["packages": ["npm:tool"], "extensions": [packageRoot + "/extensions/audit/index.ts"]]),
                      to: piHome + "/settings.json")
            try write("export const audit = true", to: packageRoot + "/extensions/audit/index.ts")
            installed = try NativePackages.discover(options: options(home: home), piHome: piHome,
                                                    repositories: [], warnings: &warnings)
            XCTAssertFalse(try XCTUnwrap(installed.first).info.canUninstall)
            XCTAssertTrue(try XCTUnwrap(installed.first).info.readOnlyReason?.contains("direct resource paths") == true)
        }
    }

    func testEscapingManifestPathsAndSymlinksAreNotTraversed() throws {
        try withTemporaryDirectory { home in
            let piHome = home + "/.pi/agent"
            let packageRoot = piHome + "/npm/node_modules/tool"
            try write("{\"name\":\"tool\",\"pi\":{\"skills\":[\"skills\",\"../outside\"]}}", to: packageRoot + "/package.json")
            try write("---\nname: outside\n---\n", to: home + "/.pi/agent/npm/node_modules/outside/evil/SKILL.md")
            try FileManager.default.createDirectory(atPath: packageRoot + "/skills", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: packageRoot + "/skills/escaped",
                                                       withDestinationPath: home + "/.pi/agent/npm/node_modules/outside/evil")
            try write(try json(["packages": ["npm:tool"]]), to: piHome + "/settings.json")

            var warnings: [ScanWarning] = []
            let installed = try NativePackages.discover(options: options(home: home), piHome: piHome,
                                                        repositories: [], warnings: &warnings)
            let package = try XCTUnwrap(installed.first)
            XCTAssertTrue(package.info.cachePresent)
            XCTAssertFalse(package.info.inventoryComplete)
            XCTAssertEqual(package.info.resources["skills"]?.installed, 0)
            XCTAssertTrue(package.info.resources["skills"]?.names.isEmpty == true)
        }
    }

    func testFingerprintChangesForSettingsManifestAndResourceContent() throws {
        try withTemporaryDirectory { home in
            let piHome = home + "/.pi/agent"
            let packageRoot = piHome + "/npm/node_modules/tool"
            let manifest = "{\"name\":\"tool\",\"version\":\"1\",\"pi\":{\"skills\":[\"skills\"]}}"
            let skillPath = packageRoot + "/skills/one/SKILL.md"
            try write(manifest, to: packageRoot + "/package.json")
            try write("first", to: skillPath)
            let settings = piHome + "/settings.json"
            try write(try json(["packages": ["npm:tool"], "theme": "one"]), to: settings)
            var warnings: [ScanWarning] = []
            func fingerprint() throws -> String {
                try XCTUnwrap(NativePackages.discover(options: options(home: home), piHome: piHome,
                                                      repositories: [], warnings: &warnings).first?.info.fingerprint)
            }

            let initial = try fingerprint()
            try write("second", to: skillPath)
            let resourceChanged = try fingerprint()
            XCTAssertNotEqual(initial, resourceChanged)
            try write(manifest.replacingOccurrences(of: "\"version\":\"1\"", with: "\"version\":\"2\""),
                      to: packageRoot + "/package.json")
            let manifestChanged = try fingerprint()
            XCTAssertNotEqual(resourceChanged, manifestChanged)
            try write(try json(["packages": ["npm:tool"], "theme": "two"]), to: settings)
            XCTAssertNotEqual(manifestChanged, try fingerprint())
        }
    }

    func testResolveRootSupportsScopedAndVersionedNpmNames() throws {
        try withTemporaryDirectory { home in
            let folder = home + "/.pi/agent"
            let cached = folder + "/npm/node_modules/@scope/tool"
            try FileManager.default.createDirectory(atPath: cached, withIntermediateDirectories: true)
            XCTAssertEqual(NativePackages.resolveRoot(source: "npm:@scope/tool@^2.0.0", folder: folder,
                                                      piHome: folder, home: home), cached)
            XCTAssertNil(NativePackages.resolveRoot(source: "npm:@scope/tool/extra", folder: folder,
                                                     piHome: folder, home: home))
        }
    }

    private func options(home: String) -> ManagerOptions {
        ManagerOptions(home: home, scanRoots: [], stateDir: home + "/state", environment: [:])
    }

    private func withTemporaryDirectory<T>(_ body: (String) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harness-packages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory.path)
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                               withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
