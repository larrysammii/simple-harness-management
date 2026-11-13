import Foundation

public enum ResourceKind: String, Codable, CaseIterable, Sendable { case skill, mcp }
public enum SourceType: String, Codable, Sendable { case directory, symlink, config, package }
public enum BackupKind: String, Codable, Sendable { case skill, mcp, package }
public enum BackupStatus: String, Codable, Sendable { case pending, ready, restored }
public enum ConfigFormat: String, Codable, Sendable { case json, jsonc, toml, yaml }
public enum PathKey: Hashable, Codable, Sendable {
    case key(String), index(Int)
    public var label: String { switch self { case .key(let s): s; case .index(let n): String(n) } }
}

/// Values never contain executable objects. Numeric spelling is retained by the JSON parser.
public indirect enum ConfigValue: Equatable, Sendable {
    case object([String: ConfigValue]), array([ConfigValue]), string(String), number(String), bool(Bool), null
    public var object: [String: ConfigValue]? { if case .object(let v) = self { return v }; return nil }
    public var array: [ConfigValue]? { if case .array(let v) = self { return v }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public subscript(_ key: String) -> ConfigValue? { object?[key] }
    public var strings: [String] { array?.compactMap(\.string) ?? [] }
    public func at(_ path: [PathKey]) -> ConfigValue? {
        var current = self
        for key in path {
            switch key {
            case .key(let name): guard let value = current.object?[name] else { return nil }; current = value
            case .index(let index): guard let values = current.array, values.indices.contains(index) else { return nil }; current = values[index]
            }
        }
        return current
    }
}

public struct Harness: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public init(id: String, name: String, description: String = "") { self.id = id; self.name = name; self.description = description }
}

public struct Repository: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var displayPath: String
    public init(id: String, name: String, path: String, displayPath: String) {
        self.id = id; self.name = name; self.path = path; self.displayPath = displayPath
    }
}

public struct Provenance: Hashable, Codable, Sendable {
    public var creator: String?
    public var sourceLabel: String?
    public var sourceURL: String?
    public var evidence: String?
    public init(creator: String? = nil, sourceLabel: String? = nil, sourceURL: String? = nil, evidence: String? = nil) {
        self.creator = creator; self.sourceLabel = sourceLabel; self.sourceURL = sourceURL; self.evidence = evidence
    }
}

public struct InventoryItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String = ""
    public var fingerprint: String = ""
    public var kind: ResourceKind
    public var name: String
    public var title: String
    public var description: String = ""
    public var harnessID: String
    public var scopeID: String
    public var sourcePath: String
    public var displayPath: String
    public var sourceType: SourceType = .directory
    public var enabled: Bool = true
    public var canUninstall: Bool = true
    public var readOnlyReason: String?
    public var inherited: Bool = false
    public var inheritedIn: [String] = []
    public var globalSourceID: String?
    public var overridesGlobal: Bool = false
    public var packageName: String?
    public var packageID: String?
    public var transport: String?
    public var provenance: Provenance = .init()
    public init(kind: ResourceKind, name: String, harnessID: String, scopeID: String, sourcePath: String, displayPath: String) {
        self.kind = kind; self.name = name; self.title = name; self.harnessID = harnessID
        self.scopeID = scopeID; self.sourcePath = sourcePath; self.displayPath = displayPath
    }
}

public struct ScanWarning: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path + message }
    public var path: String
    public var message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
}

public struct PackageResourceSummary: Hashable, Codable, Sendable {
    public var installed: Int = 0
    public var enabled: Int = 0
    public var names: [String] = []
    public init(installed: Int = 0, enabled: Int = 0, names: [String] = []) {
        self.installed = installed; self.enabled = enabled; self.names = names
    }
}

public struct PackageInstallation: Identifiable, Hashable, Codable, Sendable {
    public var id: String = ""
    public var identityKey: String = ""
    public var fingerprint: String = ""
    public var name: String
    public var version: String?
    public var scopeID: String
    public var settingsPath: String
    public var displayPath: String
    public var cachePath: String?
    public var provenance: Provenance = .init()
    public var canUninstall: Bool = true
    public var readOnlyReason: String?
    public var cachePresent: Bool = false
    public var inventoryComplete: Bool = true
    public var resources: [String: PackageResourceSummary] = [:]
    public var otherScopes: [String] = []
    public var inherited: Bool = false
    public init(name: String, scopeID: String, settingsPath: String, displayPath: String) {
        self.name = name; self.scopeID = scopeID; self.settingsPath = settingsPath; self.displayPath = displayPath
    }
}

public struct BackupInfo: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var kind: BackupKind
    public var harness: String
    public var scopeName: String
    public var sourcePath: String
    public var createdAt: Date
    public var status: BackupStatus
    public var canRestore: Bool
    public var reason: String?
    public var batchID: String?
    public var itemTitles: [String]
}

public struct InventorySnapshot: Sendable {
    public var scannedAt: Date = .now
    public var scanRoots: [String] = []
    public var repositories: [Repository] = []
    public var harnesses: [Harness] = []
    public var items: [InventoryItem] = []
    public var packages: [PackageInstallation] = []
    public var backups: [BackupInfo] = []
    public var warnings: [ScanWarning] = []
    public init() {}
    public func items(in scopeID: String) -> [InventoryItem] {
        var local = items.filter { $0.scopeID == scopeID }
        guard scopeID != "global" else { return local.sorted(by: Self.itemOrder) }
        let localKeys = Set(local.map { "\($0.harnessID):\($0.kind):\($0.name)" })
        local += items.filter {
            $0.scopeID == "global" && $0.enabled && $0.inheritedIn.contains(scopeID)
            && !localKeys.contains("\($0.harnessID):\($0.kind):\($0.name)")
        }.map { item in
            var inherited = item; inherited.inherited = true; inherited.canUninstall = false
            inherited.globalSourceID = item.id
            inherited.readOnlyReason = "Manage this installation in Global installations"
            return inherited
        }
        return local.sorted(by: Self.itemOrder)
    }
    public func packages(in scopeID: String) -> [PackageInstallation] {
        let local = packages.filter { $0.scopeID == scopeID }
        guard scopeID != "global" else { return local }
        let keys = Set(local.map(\.identityKey))
        return local + packages.filter { $0.scopeID == "global" && !keys.contains($0.identityKey) }.map {
            var p = $0; p.inherited = true; p.canUninstall = false
            p.readOnlyReason = "Manage this package in Global installations"; return p
        }
    }
    private static func itemOrder(_ a: InventoryItem, _ b: InventoryItem) -> Bool {
        if a.inherited != b.inherited { return !a.inherited }
        let order = a.title.localizedStandardCompare(b.title)
        return order == .orderedSame ? a.harnessID < b.harnessID : order == .orderedAscending
    }
}

public struct ResourceRule: Sendable {
    public var baseDir: String
    public var patterns: [String]
    public var defaultEnabled: Bool
    public init(baseDir: String, patterns: [String], defaultEnabled: Bool = true) {
        self.baseDir = baseDir; self.patterns = patterns; self.defaultEnabled = defaultEnabled
    }
}

public struct SkillSource: Sendable {
    public var harnessID: String
    public var scopeID: String
    public var directory: String
    public var inherits: Bool = true
    public var packageName: String?
    public var packageID: String?
    public var readOnlyReason: String?
    public var singleSkill: Bool = false
    public var rules: [ResourceRule] = []
    public var provenance: Provenance?
    public init(harnessID: String, scopeID: String, directory: String, inherits: Bool = true) {
        self.harnessID = harnessID; self.scopeID = scopeID; self.directory = directory; self.inherits = inherits
    }
}

public struct MCPSource: Sendable {
    public var harnessID: String
    public var scopeID: String
    public var file: String
    public var format: ConfigFormat
    public var mapPath: [PathKey]
    public var inherits: Bool = true
    public var readOnlyReason: String?
    public var packageName: String?
    public var packageID: String?
    public init(harnessID: String, scopeID: String, file: String, format: ConfigFormat = .jsonc,
                mapPath: [PathKey] = [.key("mcpServers")], inherits: Bool = true) {
        self.harnessID = harnessID; self.scopeID = scopeID; self.file = file; self.format = format
        self.mapPath = mapPath; self.inherits = inherits
    }
}

public struct ConfigEntry: Sendable {
    public var format: ConfigFormat
    public var keyPath: [PathKey]
    public init(format: ConfigFormat, keyPath: [PathKey]) { self.format = format; self.keyPath = keyPath }
}
public struct InstalledTarget: Sendable {
    public var item: InventoryItem
    public var parentRealPath: String
    public var canonicalPath: String
    public var config: ConfigEntry?
    public init(item: InventoryItem, parentRealPath: String, canonicalPath: String, config: ConfigEntry? = nil) {
        self.item = item; self.parentRealPath = parentRealPath; self.canonicalPath = canonicalPath; self.config = config
    }
}
public struct InstalledPackage: Sendable {
    public var info: PackageInstallation
    public var settingsFile: String
    public var configFingerprint: String
    public var parentRealPath: String
    public var canonicalPath: String
    public var indexes: [Int]
    public var sources: [String]
    public var roots: [String: String]
    public init(info: PackageInstallation, settingsFile: String, configFingerprint: String, parentRealPath: String,
                canonicalPath: String, indexes: [Int], sources: [String], roots: [String: String]) {
        self.info = info; self.settingsFile = settingsFile; self.configFingerprint = configFingerprint
        self.parentRealPath = parentRealPath; self.canonicalPath = canonicalPath; self.indexes = indexes
        self.sources = sources; self.roots = roots
    }
}
public struct Registry: Sendable {
    public var harnesses: [Harness] = []
    public var skills: [SkillSource] = []
    public var mcps: [MCPSource] = []
    public var packages: [InstalledPackage] = []
    public init() {}
}
public struct ScanResult: Sendable {
    public var repositories: [Repository]
    public var registry: Registry
    public var targets: [InstalledTarget]
    public var warnings: [ScanWarning]
    public init(repositories: [Repository], registry: Registry, targets: [InstalledTarget], warnings: [ScanWarning]) {
        self.repositories = repositories; self.registry = registry; self.targets = targets; self.warnings = warnings
    }
}

public struct ManagerOptions: Sendable {
    public var home: String
    public var scanRoots: [String]
    public var stateDir: String
    public var environment: [String: String]
    public init(home: String, scanRoots: [String], stateDir: String, environment: [String: String] = [:]) {
        self.home = home; self.scanRoots = scanRoots; self.stateDir = stateDir; self.environment = environment
    }
    public static func live() -> ManagerOptions {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return .init(home: home, scanRoots: [home + "/repo", home + "/repos", home + "/Projects", home + "/Developer"],
                     stateDir: home + "/Library/Application Support/Harness Manager", environment: ProcessInfo.processInfo.environment)
    }
}

public struct RemovalRequest: Hashable, Sendable {
    public var id: String
    public var fingerprint: String
    public init(id: String, fingerprint: String) { self.id = id; self.fingerprint = fingerprint }
    public init(_ item: InventoryItem) { id = item.id; fingerprint = item.fingerprint }
}
public struct MutationReport: Sendable {
    public var message: String
    public var removedCount: Int
    public var notProcessedCount: Int
    public var backupIDs: [String]
    public var error: String?
    public var isPartial: Bool { error != nil }
    public init(message: String, removedCount: Int = 0, notProcessedCount: Int = 0, backupIDs: [String] = [], error: String? = nil) {
        self.message = message; self.removedCount = removedCount; self.notProcessedCount = notProcessedCount
        self.backupIDs = backupIDs; self.error = error
    }
}
public struct ManagerError: LocalizedError, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
