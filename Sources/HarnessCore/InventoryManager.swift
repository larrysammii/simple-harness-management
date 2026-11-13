import Darwin
import Foundation

/// One native actor owns mutations. An advisory lock also excludes other app instances.
/// Discovery never launches a harness, loads an extension, or contacts an MCP server.
public actor InventoryManager {
    public let options: ManagerOptions
    public init(options: ManagerOptions) { self.options = options }
    private var backupDirectory: String { FS.join(options.stateDir, "backups") }
    private var settingsFile: String { FS.join(options.stateDir, "settings.json") }

    private struct Settings: Codable { var repositories: [String] = [] }
    private struct BackupRecord: Codable {
        var version = 1
        var id: String
        var title: String
        var kind: BackupKind
        var harness: String
        var scopeName: String
        var sourcePath: String
        var parentRealPath: String
        var canonicalPath: String
        var createdAt: Date
        var status: BackupStatus
        var mode: UInt16
        var beforeHash: String?
        var afterHash: String?
        var payloadFingerprint: String?
        var batchID: String?
        var itemTitles: [String]
    }
    private struct Target {
        var title: String
        var kind: BackupKind
        var harnessID: String
        var scopeID: String
        var sourcePath: String
        var fingerprint: String
        var parentRealPath: String
        var canonicalPath: String
        var config: ConfigEntry?
        init(_ installed: InstalledTarget) {
            let i = installed.item
            title = i.title; kind = i.kind == .skill ? .skill : .mcp; harnessID = i.harnessID
            scopeID = i.scopeID; sourcePath = i.sourcePath; fingerprint = i.fingerprint
            parentRealPath = installed.parentRealPath; canonicalPath = installed.canonicalPath; config = installed.config
        }
        init(package: InstalledPackage) {
            title = package.info.name; kind = .package; harnessID = "pi"; scopeID = package.info.scopeID
            sourcePath = package.settingsFile; fingerprint = package.configFingerprint
            parentRealPath = package.parentRealPath; canonicalPath = package.canonicalPath
            config = .init(format: .jsonc, keyPath: [.key("packages"), .index(package.indexes[0])])
        }
    }
    private struct Operation {
        var targets: [Target]
        var original: String?
        var updated: String?
    }
    private struct Outcome { var changed = false; var backupID: String?; var error: String? }

    public func snapshot() throws -> InventorySnapshot {
        let result = try scan()
        var state = InventorySnapshot()
        state.scanRoots = options.scanRoots.map { FS.friendly($0, home: options.home) }
        state.repositories = result.repositories; state.harnesses = result.registry.harnesses
        state.items = result.targets.map(\.item); state.packages = result.registry.packages.map(\.info)
        state.warnings = result.warnings; state.backups = try listBackups()
        return state
    }
    private func scan() throws -> ScanResult {
        try InventoryScanner.scan(options: options, explicitRepositories: loadSettings().repositories)
    }
    private func loadSettings() throws -> Settings {
        guard FS.exists(settingsFile) else { return Settings() }
        guard !FS.isSymlink(settingsFile), let settings = try? JSONDecoder().decode(Settings.self, from: FS.readData(settingsFile)),
              settings.repositories.count <= 500, settings.repositories.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 }) else {
            throw ManagerError("App settings are unreadable. Repair settings.json in the app data folder before making changes")
        }
        return settings
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    private func withMutation<T>(_ body: () throws -> T) throws -> T {
        try FS.privateDirectory(options.stateDir)
        let path = FS.join(options.stateDir, "mutation.lock")
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ManagerError("The app mutation lock cannot be opened safely") }
        defer { _ = flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw ManagerError("Another app instance is making a change. Wait for it to finish")
        }
        return try body()
    }
    public func addRepository(path input: String) throws {
        try withMutation {
            let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty, input.utf8.count <= 4096,
                  input.hasPrefix("/") || input == "~" || input.hasPrefix("~/") else {
                throw ManagerError("Choose an absolute repository folder")
            }
            let path = try FS.realPath(FS.expand(input, home: options.home))
            guard FS.isDirectory(path) else { throw ManagerError("The selected repository is not a readable folder") }
            var settings = try loadSettings()
            if !settings.repositories.contains(path) { settings.repositories.append(path) }
            guard settings.repositories.count <= 500 else { throw ManagerError("The repository limit is 500") }
            try FS.atomicWrite(settingsFile, data: encoded(settings))
        }
    }

    private func verify(_ target: Target, content: String? = nil) throws {
        let location = try FS.canonical(target.sourcePath)
        guard location.parent == target.parentRealPath, location.path == target.canonicalPath,
              try FS.fingerprint(target.sourcePath, content: content) == target.fingerprint else {
            throw ManagerError("The installation changed after the scan. Refresh before uninstalling")
        }
        if target.config != nil, FS.isSymlink(target.sourcePath) {
            throw ManagerError("Symbolic-link configurations cannot be changed automatically")
        }
    }
    private func keyOrder(_ a: Target, _ b: Target) -> Bool {
        let left = a.config?.keyPath ?? [], right = b.config?.keyPath ?? []
        if Array(left.dropLast()) == Array(right.dropLast()), case .index(let l) = left.last, case .index(let r) = right.last { return l > r }
        return left.map(\.label).joined(separator: "/") > right.map(\.label).joined(separator: "/")
    }
    private func removalPlan(_ requests: [RemovalRequest], scopeID: String) throws -> (operations: [Operation], total: Int, scopeName: String) {
        guard (1...1000).contains(requests.count), Set(requests.map(\.id)).count == requests.count else {
            throw ManagerError("Select between 1 and 1,000 distinct removable installations")
        }
        let current = try scan()
        guard scopeID == "global" || current.repositories.contains(where: { $0.id == scopeID }) else {
            throw ManagerError("Choose an existing Global or repository scope")
        }
        let byID = Dictionary(uniqueKeysWithValues: current.targets.map { ($0.item.id, $0) })
        var physical: [String: Target] = [:]
        for request in requests {
            guard let installed = byID[request.id] else { throw ManagerError("An installation is no longer present. Nothing was changed") }
            let item = installed.item
            guard item.scopeID == scopeID else { throw ManagerError("Uninstall is limited to the current scope. Nothing was changed") }
            guard item.canUninstall, !item.inherited else { throw ManagerError(item.readOnlyReason ?? "This installation is protected") }
            guard item.fingerprint == request.fingerprint else { throw ManagerError("An installation changed. Refresh before uninstalling. Nothing was changed") }
            let pathData = try JSONEncoder().encode(installed.config?.keyPath ?? [])
            let identity = "\(item.kind):\(installed.canonicalPath):\(FS.hash(pathData))"
            physical[identity] = Target(installed)
        }
        var grouped: [String: [Target]] = [:]
        for target in physical.values { grouped["\(target.kind):\(target.canonicalPath)", default: []].append(target) }
        let paths = Set(physical.values.map(\.canonicalPath))
        for path in paths {
            var ancestor = FS.parent(path)
            while ancestor != FS.parent(ancestor) {
                guard !paths.contains(ancestor) else { throw ManagerError("Selected paths overlap. Unselect the nested installation. Nothing was changed") }
                ancestor = FS.parent(ancestor)
            }
        }
        var operations: [Operation] = []
        for key in grouped.keys.sorted() {
            let targets = grouped[key]!.sorted(by: keyOrder)
            var op = Operation(targets: targets)
            if targets[0].config != nil {
                let original = try FS.readText(targets[0].sourcePath)
                var updated = original
                for target in targets {
                    try verify(target, content: original)
                    let config = target.config!
                    updated = try Configuration.removing(updated, format: config.format, path: config.keyPath)
                }
                op.original = original; op.updated = updated
            } else { try verify(targets[0]) }
            operations.append(op)
        }
        let scopeName = scopeID == "global" ? "Global installations" : current.repositories.first { $0.id == scopeID }?.name ?? "Repository"
        return (operations, physical.count, scopeName)
    }
    private func apply(_ operation: Operation, scopeName: String, batchID: String?) -> Outcome {
        let target = operation.targets[0]
        var outcome = Outcome()
        let backupID = UUID().uuidString.lowercased()
        let directory = FS.join(backupDirectory, backupID)
        do {
            try verify(target, content: operation.original == nil ? nil : FS.readText(target.sourcePath))
            try FS.privateDirectory(backupDirectory)
            try FS.privateDirectory(directory)
            var record = BackupRecord(id: backupID,
                title: operation.targets.count == 1 ? target.title : "\(operation.targets.count) MCP servers",
                kind: target.kind, harness: Set(operation.targets.map(\.harnessID)).sorted().joined(separator: ", "),
                scopeName: scopeName, sourcePath: target.sourcePath, parentRealPath: target.parentRealPath,
                canonicalPath: target.canonicalPath, createdAt: .now, status: .pending, mode: try FS.mode(target.sourcePath),
                beforeHash: operation.original.map(FS.hash), afterHash: operation.updated.map(FS.hash),
                batchID: batchID, itemTitles: operation.targets.map(\.title))
            let manifest = FS.join(directory, "manifest.json"), payload = FS.join(directory, "payload")
            try FS.atomicWrite(manifest, data: encoded(record))
            if let original = operation.original, let updated = operation.updated {
                try FS.atomicWrite(payload, text: original)
                try verify(target, content: FS.readText(target.sourcePath))
                try FS.atomicWrite(target.sourcePath, text: updated, mode: record.mode)
            } else {
                try verify(target)
                try FS.moveExclusive(target.sourcePath, to: payload)
            }
            outcome.changed = true; outcome.backupID = backupID
            if target.kind == .skill { record.payloadFingerprint = try FS.fingerprint(payload) }
            record.status = .ready
            try FS.atomicWrite(manifest, data: encoded(record))
        } catch {
            outcome.error = (error as? ManagerError)?.message ?? "The source could not be safely changed or its backup finalized"
            if outcome.changed { outcome.backupID = backupID }
        }
        return outcome
    }

    public func remove(requests: [RemovalRequest], scopeID: String, confirmation: String) throws -> MutationReport {
        try withMutation {
            guard confirmation == "UNINSTALL \(requests.count)" else { throw ManagerError("The confirmation does not match the selected count") }
            let plan = try removalPlan(requests, scopeID: scopeID)
            let batchID = UUID().uuidString.lowercased()
            var removed = 0; var backups: [String] = []; var errorMessage: String?
            for operation in plan.operations {
                let result = apply(operation, scopeName: plan.scopeName, batchID: batchID)
                if result.changed { removed += operation.targets.count; if let id = result.backupID { backups.append(id) } }
                if let error = result.error { errorMessage = "\(operation.targets[0].title): \(error)"; break }
            }
            let message = errorMessage == nil ? "\(removed) installation\(removed == 1 ? "" : "s") uninstalled · recoverable in Backups"
                : "Stopped after \(removed) of \(plan.total) installations · completed changes remain recoverable in Backups"
            return .init(message: message, removedCount: removed, notProcessedCount: plan.total - removed, backupIDs: backups, error: errorMessage)
        }
    }
    public func removePackage(id: String, fingerprint: String, scopeID: String, confirmation: String) throws -> MutationReport {
        try withMutation {
            let current = try scan()
            guard let package = current.registry.packages.first(where: { $0.info.id == id }) else { throw ManagerError("This package registration is no longer present") }
            let info = package.info
            guard info.scopeID == scopeID else { throw ManagerError("Package uninstall is limited to its own scope") }
            guard info.canUninstall, !info.inherited else { throw ManagerError(info.readOnlyReason ?? "The package registration is protected") }
            guard info.fingerprint == fingerprint else { throw ManagerError("The package or its resource inventory changed. Refresh before uninstalling") }
            guard confirmation == info.name else { throw ManagerError("Type the exact package name to confirm") }
            guard !package.indexes.isEmpty else { throw ManagerError("The package registration has no editable declaration") }
            let target = Target(package: package), original = try FS.readText(package.settingsFile)
            try verify(target, content: original)
            var updated = original
            for index in package.indexes.sorted(by: >) {
                updated = try Configuration.removing(updated, format: .jsonc, path: [.key("packages"), .index(index)])
            }
            let scopeName = scopeID == "global" ? "Global installations" : current.repositories.first { $0.id == scopeID }?.name ?? "Repository"
            let outcome = apply(.init(targets: [target], original: original, updated: updated), scopeName: scopeName, batchID: nil)
            if let error = outcome.error { throw ManagerError(error + (outcome.changed ? " · registration removed; a recovery backup is available" : "")) }
            return .init(message: "\(info.name) unregistered · cache kept · reload Pi to apply", removedCount: 1, backupIDs: outcome.backupID.map { [$0] } ?? [])
        }
    }

    private func readBackup(_ id: String) throws -> BackupRecord {
        guard UUID(uuidString: id) != nil, id.lowercased() == id else { throw ManagerError("Invalid backup identifier") }
        let directory = FS.join(backupDirectory, id), manifest = FS.join(directory, "manifest.json")
        guard !FS.isSymlink(directory), FS.isDirectory(directory), !FS.isSymlink(manifest) else { throw ManagerError("Backup storage cannot be a symbolic link") }
        let record = try JSONDecoder().decode(BackupRecord.self, from: FS.readData(manifest))
        guard record.version == 1, record.id == id, record.sourcePath.hasPrefix("/"), record.parentRealPath.hasPrefix("/"),
              record.canonicalPath == FS.join(record.parentRealPath, FS.name(record.sourcePath)),
              record.mode <= 0o777, !record.itemTitles.isEmpty else { throw ManagerError("Backup metadata is invalid") }
        return record
    }
    private func restoreReason(_ record: BackupRecord) -> String? {
        if record.status == .restored { return "Already restored" }
        let payload = FS.join(backupDirectory, record.id, "payload")
        guard FS.exists(payload) else { return "Backup preparation did not finish; the original may be unchanged" }
        do {
            let location = try FS.canonical(record.sourcePath)
            guard location.parent == record.parentRealPath, location.path == record.canonicalPath else {
                return "The original parent directory changed; automatic restore is blocked"
            }
            if record.kind == .skill {
                if FS.exists(record.sourcePath) { return "An installation occupies the original path; it will not be overwritten" }
                guard let fingerprint = record.payloadFingerprint else { return "Skill backup finalization did not finish; restore its saved payload manually" }
                guard try FS.fingerprint(payload) == fingerprint else { return "Skill backup content changed; automatic restore is blocked" }
            } else {
                guard !FS.isSymlink(record.sourcePath), !FS.isSymlink(payload) else { return "The configuration or backup became a symbolic link" }
                let current = FS.hash(try FS.readData(record.sourcePath))
                guard current == record.afterHash || (record.status == .pending && current == record.beforeHash) else {
                    return "The configuration changed after uninstall; restore manually to preserve newer edits"
                }
                guard FS.hash(try FS.readData(payload)) == record.beforeHash else { return "Backup content is missing or changed" }
            }
        } catch { return "The original parent or configuration is missing or unreadable" }
        return nil
    }
    public func listBackups() throws -> [BackupInfo] {
        guard FS.exists(backupDirectory) else { return [] }
        guard !FS.isSymlink(backupDirectory) else { throw ManagerError("Backup storage cannot be a symbolic link") }
        var result: [BackupInfo] = []
        for id in try FS.children(backupDirectory) where UUID(uuidString: id) != nil {
            guard let record = try? readBackup(id) else { continue }
            let reason = restoreReason(record)
            result.append(.init(id: id, title: record.title, kind: record.kind, harness: record.harness, scopeName: record.scopeName,
                                sourcePath: FS.friendly(record.sourcePath, home: options.home), createdAt: record.createdAt,
                                status: record.status, canRestore: reason == nil, reason: reason, batchID: record.batchID, itemTitles: record.itemTitles))
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }
    public func restore(id: String) throws -> MutationReport {
        try withMutation {
            var record = try readBackup(id)
            if let reason = restoreReason(record) { throw ManagerError(reason) }
            let directory = FS.join(backupDirectory, id), payload = FS.join(directory, "payload")
            if record.kind == .skill { try FS.moveExclusive(payload, to: record.sourcePath) }
            else {
                let data = try FS.readData(payload)
                if let reason = restoreReason(record) { throw ManagerError(reason) }
                try FS.atomicWrite(record.sourcePath, data: data, mode: record.mode)
            }
            record.status = .restored
            try FS.atomicWrite(FS.join(directory, "manifest.json"), data: encoded(record))
            return .init(message: "\(record.title) restored · reload the affected harness")
        }
    }
}
