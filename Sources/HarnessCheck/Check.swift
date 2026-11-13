import Foundation
import HarnessCore

@main
struct HarnessCheck {
    static func main() async throws {
        let live = CommandLine.arguments.contains("--live")
        let exercise = CommandLine.arguments.contains("--exercise")
        guard !(live && exercise) else { throw ManagerError("Mutation exercises are only allowed in a synthetic environment") }
        let fixture = live ? nil : try DemoEnvironment.create()
        defer { try? fixture?.cleanUp() }
        let manager = InventoryManager(options: fixture?.options ?? .live())
        let state = try await manager.snapshot()
        let physical = Set(state.items.map { "\($0.kind):\($0.sourcePath):\($0.name)" }).count
        print("Native discovery: \(physical) resources · \(state.repositories.count) repositories · \(state.packages.count) package registrations · \(state.warnings.count) notices")
        print(live ? "Read-only check; no names, credentials, or configuration values are printed" : "Synthetic home only; real installations were not accessed")
        guard exercise else { return }
        guard let skill = state.items.first(where: { $0.name == "project-planning" && $0.canUninstall }) else { throw ManagerError("Synthetic skill was not discovered") }
        let skillResult = try await manager.remove(requests: [.init(skill)], scopeID: "global", confirmation: "UNINSTALL 1")
        guard skillResult.error == nil, !FS.exists(skill.sourcePath), let skillBackup = skillResult.backupIDs.first else { throw ManagerError("Skill removal exercise failed") }
        _ = try await manager.restore(id: skillBackup)
        guard FS.exists(skill.sourcePath) else { throw ManagerError("Skill restore exercise failed") }
        print("PASS skill removal and restore")
        for harness in ["cursor", "codex", "continue"] {
            let items = state.items.filter { $0.kind == .mcp && $0.harnessID == harness && $0.scopeID == "global" }
            guard !items.isEmpty, items.allSatisfy(\.canUninstall) else { throw ManagerError("Synthetic \(harness) configuration is not manageable") }
            let file = items[0].sourcePath, original = try FS.readData(file)
            let result = try await manager.remove(requests: items.map(RemovalRequest.init), scopeID: "global", confirmation: "UNINSTALL \(items.count)")
            guard result.error == nil, result.backupIDs.count == 1 else { throw ManagerError("Grouped \(harness) removal failed") }
            _ = try await manager.restore(id: result.backupIDs[0])
            guard try FS.readData(file) == original else { throw ManagerError("\(harness) did not restore original bytes") }
        }
        print("PASS JSON, TOML, and YAML grouped edits with byte-exact restore")
        guard let package = state.packages.first(where: { $0.scopeID == "global" && $0.name == "@example/engineering-kit" }) else { throw ManagerError("Synthetic package was not discovered") }
        let original = try FS.readData(package.settingsPath)
        let result = try await manager.removePackage(id: package.id, fingerprint: package.fingerprint, scopeID: "global", confirmation: package.name)
        guard let backup = result.backupIDs.first else { throw ManagerError("Package backup was not created") }
        _ = try await manager.restore(id: backup)
        guard try FS.readData(package.settingsPath) == original else { throw ManagerError("Package registration did not restore exactly") }
        print("PASS package unregister and exact restore; downloaded code was never run")
    }
}
