import Foundation

public enum InventoryScanner {
    private static let skippedDirectories: Set<String> = ["node_modules", "vendor", "dist", "build", "target", "Library", "Applications", "__pycache__"]
    private static let repositoryMarkers: Set<String> = [
        ".git", "package.json", "Cargo.toml", "pyproject.toml", "go.mod", ".claude", ".codex", ".pi",
        ".cursor", ".gemini", ".mcp.json", ".agents", "opencode.json", "opencode.jsonc"
    ]
    static let lockSkillDirectories = [".agents", ".claude", ".codex", ".pi", ".cursor", ".opencode",
                                                ".windsurf", ".roo", ".continue", ".github", ".gemini", ".cline"]

    public static func discoverRepositories(roots: [String], explicit: [String], home: String,
                                            warnings: inout [ScanWarning]) -> [Repository] {
        var found: [String: Repository] = [:]
        var visited = 0

        func register(_ input: String) throws {
            let resolved = try FS.realPath(input)
            guard FS.isDirectory(resolved), found[resolved] == nil else { return }
            found[resolved] = Repository(id: FS.id("repository", resolved), name: FS.name(input), path: resolved,
                                         displayPath: FS.friendly(resolved, home: home))
        }

        func walk(_ directory: String, depth: Int) {
            visited += 1
            guard visited <= 2500 else { return }
            guard FS.exists(directory) else { return }
            let entries: [String]
            do { entries = try FS.children(directory) }
            catch {
                warnings.append(ScanWarning(path: FS.friendly(directory, home: home), message: "Repository folder could not be read."))
                return
            }
            if entries.contains(where: repositoryMarkers.contains) {
                do { try register(directory) }
                catch { warnings.append(ScanWarning(path: FS.friendly(directory, home: home), message: "Repository folder could not be resolved.")) }
                return
            }
            if depth >= 3 { return }
            let previousCount = found.count
            for entry in entries {
                guard !entry.hasPrefix("."), !skippedDirectories.contains(entry) else { continue }
                let child = FS.join(directory, entry)
                // Discovery follows ordinary directories only; explicit paths may still name a symlink.
                guard !FS.isSymlink(child), FS.isDirectory(child) else { continue }
                walk(child, depth: depth + 1)
            }
            if depth == 1, found.count == previousCount {
                try? register(directory)
            }
        }

        for root in roots { walk(root, depth: 0) }
        for input in explicit {
            let expanded = FS.expand(input, home: home)
            do { try register(expanded) }
            catch {
                warnings.append(ScanWarning(path: FS.friendly(expanded, home: home), message: "Added repository is missing or unreadable."))
            }
        }
        if visited > 2500 {
            warnings.append(ScanWarning(path: "Repository discovery", message: "Scan limit reached. Add a specific repository to include it."))
        }
        return found.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }

    public static func scan(options: ManagerOptions, explicitRepositories: [String]) throws -> ScanResult {
        var warnings: [ScanWarning] = []
        let repositories = discoverRepositories(roots: options.scanRoots, explicit: explicitRepositories,
                                                home: options.home, warnings: &warnings)
        let registry = try RegistryBuilder.build(options: options, repositories: repositories, warnings: &warnings)
        let provenance = ProvenanceLookup(home: options.home, repositories: repositories, warnings: &warnings)
        var targets: [InstalledTarget] = []

        func warning(_ file: String, _ message: String) {
            warnings.append(ScanWarning(path: FS.friendly(file, home: options.home), message: message))
        }

        func baseItem(source: SkillSource, file: String, name: String) -> InventoryItem {
            var item = InventoryItem(kind: .skill, name: name, harnessID: source.harnessID,
                                     scopeID: source.scopeID, sourcePath: file, displayPath: FS.friendly(file, home: options.home))
            item.sourceType = source.packageName == nil ? .directory : .package
            item.canUninstall = source.readOnlyReason == nil && source.packageName == nil
            item.readOnlyReason = source.readOnlyReason
            item.packageName = source.packageName
            item.packageID = source.packageID
            return item
        }

        func scanSkill(_ source: SkillSource, folder: String, protectedContainer: Bool) {
            let skillFile = FS.join(folder, "SKILL.md")
            let document: String
            do { document = try FS.readText(skillFile, maxBytes: 256 * 1024) }
            catch {
                warning(skillFile, "Skill metadata is unreadable, invalid, or larger than 256 KB.")
                return
            }
            let metadata = parseFrontmatter(document)
            var name = FS.name(folder)
            var description = ""
            if let metadata {
                if let value = metadata["name"]?.string {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { name = String(trimmed.prefix(160)) }
                }
                if let value = metadata["description"]?.string {
                    description = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    description = String(description.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
                }
            }
            do {
                var item = baseItem(source: source, file: folder, name: name)
                let declared = ProvenanceResolver.declared(metadata)
                let supplied = source.provenance ?? source.packageName.map { Provenance(sourceLabel: $0, evidence: "package") }
                item.provenance = provenance.resolve(folder: folder, metadata: metadata, declared: declared, supplied: supplied)
                if FS.isSymlink(folder) { item.sourceType = .symlink }
                item.description = description.isEmpty ? "Agent instructions and reusable workflows." : description
                item.enabled = ResourceFilters.enabled(file: skillFile, rules: source.rules)
                item.fingerprint = try FS.fingerprint(folder)
                let location = try FS.canonical(folder)
                item.id = FS.id(source.harnessID, source.scopeID, "skill", location.path)
                if protectedContainer || (folder == source.directory && !source.singleSkill) {
                    item.canUninstall = false
                    item.sourceType = .package
                    item.readOnlyReason = folder == source.directory && !source.singleSkill
                        ? "The skill source root cannot be removed as an individual skill."
                        : "Bundled with the harness. Manage this skill through its package or harness."
                }
                if let packageName = source.packageName {
                    item.readOnlyReason = item.readOnlyReason ?? "Provided by \(packageName). Manage it through the harness package manager."
                }
                if source.inherits && source.scopeID == "global" { item.inheritedIn = repositories.map(\.id) }
                targets.append(InstalledTarget(item: item, parentRealPath: location.parent, canonicalPath: location.path))
            } catch {
                warning(skillFile, "Skill metadata is unreadable, invalid, or larger than 256 KB.")
            }
        }

        func walkSkills(_ source: SkillSource, directory: String, depth: Int, seen: Set<String>, protectedContainer: Bool = false) {
            guard FS.exists(directory) else { return }
            if depth > 5 {
                warning(directory, "Skill nesting exceeds the scan limit.")
                return
            }
            let resolved: String
            do { resolved = try FS.realPath(directory) }
            catch {
                if FS.exists(directory) { warning(directory, "Skill directory could not be read.") }
                return
            }
            guard !seen.contains(resolved) else { return }
            var branch = seen
            branch.insert(resolved)
            if FS.exists(FS.join(directory, "SKILL.md")) {
                scanSkill(source, folder: directory, protectedContainer: protectedContainer)
                return
            }
            let entries: [String]
            do { entries = try FS.children(directory) }
            catch {
                warning(directory, "Skill directory could not be read.")
                return
            }
            for entry in entries {
                guard (entry != ".git"), !skippedDirectories.contains(entry) else { continue }
                let next = FS.join(directory, entry)
                guard FS.isDirectory(next) else {
                    if FS.isSymlink(next), !FS.exists(next) { warning(next, "Broken or unreadable skill link.") }
                    continue
                }
                walkSkills(source, directory: next, depth: depth + 1, seen: branch,
                           protectedContainer: protectedContainer || entry == ".system")
            }
        }

        for source in registry.skills {
            walkSkills(source, directory: source.directory, depth: 0, seen: [])
        }

        struct CachedConfiguration {
            var text: String
            var value: ConfigValue
            var symlink: Bool
        }
        enum ConfigurationCacheEntry {
            case loaded(CachedConfiguration)
            case failed
        }
        var configCache: [String: ConfigurationCacheEntry] = [:]
        for source in registry.mcps {
            guard FS.exists(source.file) else { continue }
            let cacheKey = source.file + "\u{0}" + source.format.rawValue
            if configCache[cacheKey] == nil {
                do {
                    let text = try FS.readText(source.file)
                    let value = try Configuration.parse(text, format: source.format)
                    configCache[cacheKey] = .loaded(CachedConfiguration(text: text, value: value, symlink: FS.isSymlink(source.file)))
                } catch {
                    configCache[cacheKey] = .failed
                    warning(source.file, "Configuration is unreadable, invalid, or too large. It was left untouched.")
                }
            }
            guard case .loaded(let cached)? = configCache[cacheKey],
                  let collection = cached.value.at(source.mapPath) else { continue }
            let entries: [(PathKey, ConfigValue)]
            switch collection {
            case .object(let object):
                entries = object.keys.sorted().compactMap { key in object[key].map { (.key(key), $0) } }
            case .array(let array):
                entries = array.enumerated().map { (.index($0.offset), $0.element) }
            default: continue
            }
            let location: (parent: String, path: String)
            let fingerprint: String
            do {
                location = try FS.canonical(source.file)
                fingerprint = try FS.fingerprint(source.file, content: cached.text)
            } catch {
                warning(source.file, "MCP source could not be scanned safely. It was left untouched.")
                continue
            }
            for (key, value) in entries {
                guard let fields = value.object else { continue }
                let name: String
                if case .index(let index) = key { name = fields["name"]?.string ?? "Server \(index + 1)" }
                else if case .key(let entryName) = key { name = entryName }
                else { continue }
                var item = InventoryItem(kind: .mcp, name: name, harnessID: source.harnessID,
                                         scopeID: source.scopeID, sourcePath: source.file,
                                         displayPath: FS.friendly(source.file, home: options.home))
                item.sourceType = source.packageName == nil ? .config : .package
                item.packageName = source.packageName
                item.packageID = source.packageID
                item.canUninstall = source.readOnlyReason == nil && source.packageName == nil
                item.readOnlyReason = source.readOnlyReason
                let keyPath = source.mapPath + [key]
                item.id = FS.id(source.harnessID, source.scopeID, "mcp", location.path, pathJSON(keyPath))
                item.fingerprint = fingerprint
                item.enabled = fields["enabled"]?.bool != false && fields["disabled"]?.bool != true
                if let type = fields["type"]?.string { item.transport = String(type.prefix(40)) }
                else if truthy(fields["url"]) || truthy(fields["serverUrl"]) { item.transport = "HTTP" }
                else { item.transport = "stdio" }
                item.description = item.enabled ? "Configured MCP server. Credentials stay on this machine." : "Disabled in the harness configuration."
                if !truthy(fields["command"]) && !truthy(fields["url"]) && !truthy(fields["serverUrl"]) {
                    item.canUninstall = false
                    item.description = "Configuration override; the connection is defined in another source."
                    item.readOnlyReason = "This entry only overrides another MCP definition. Removing it could re-enable a server or change its tools. Manage its owning configuration."
                }
                if cached.symlink {
                    item.canUninstall = false
                    item.readOnlyReason = "This configuration is a symlink. Edit its owning configuration to avoid changing another installation."
                }
                if let packageName = source.packageName {
                    item.readOnlyReason = item.readOnlyReason ?? "Provided by \(packageName). Manage it through the harness package manager."
                }
                if item.canUninstall {
                    do { _ = try Configuration.removing(cached.text, format: source.format, path: keyPath) }
                    catch {
                        item.canUninstall = false
                        item.readOnlyReason = "This configuration layout cannot be safely edited automatically. Manage it in the source file."
                    }
                }
                if source.inherits && source.scopeID == "global" { item.inheritedIn = repositories.map(\.id) }
                targets.append(InstalledTarget(item: item, parentRealPath: location.parent,
                                               canonicalPath: location.path,
                                               config: ConfigEntry(format: source.format, keyPath: keyPath)))
            }
        }

        var seenIDs: Set<String> = []
        var unique = targets.filter { seenIDs.insert($0.item.id).inserted }
        var globalSkills: [String: InstalledTarget] = [:]
        for target in unique where target.item.scopeID == "global" && target.item.kind == .skill {
            if let resolved = try? FS.realPath(target.item.sourcePath), globalSkills[resolved] == nil {
                globalSkills[resolved] = target
            }
        }
        for index in unique.indices where unique[index].item.scopeID != "global" {
            if unique[index].item.kind == .skill,
               let resolved = try? FS.realPath(unique[index].item.sourcePath),
               let global = globalSkills[resolved], unique[index].item.packageID == nil {
                unique[index].item.inherited = true
                unique[index].item.globalSourceID = global.item.id
                unique[index].item.canUninstall = false
                unique[index].item.readOnlyReason = "This repository links to a global installation. Manage it in Global installations."
            }
            let item = unique[index].item
            unique[index].item.overridesGlobal = !item.inherited && unique.contains { global in
                global.item.scopeID == "global" && global.item.harnessID == item.harnessID && global.item.kind == item.kind
                    && global.item.name == item.name && global.item.inheritedIn.contains(item.scopeID)
            }
        }

        // Pi project exclusions also hide otherwise inherited global skills in that repository.
        for repository in repositories {
            let settingsPath = FS.join(repository.path, ".pi", "settings.json")
            guard FS.exists(settingsPath) else { continue }
            do {
                let settings = try Configuration.parse(FS.readText(settingsPath), format: .jsonc)
                guard let values = settings["skills"]?.array else { continue }
                let patterns = values.compactMap(\.string).map { raw -> String in
                    let prefix = raw.first.map { "!+-".contains($0) } == true ? String(raw.prefix(1)) : ""
                    let value = prefix.isEmpty ? raw : String(raw.dropFirst())
                    let expanded = value.hasPrefix("~")
                        ? FS.expand(value, home: options.home)
                        : FS.expand(value, home: options.home, base: FS.parent(settingsPath))
                    return prefix + expanded
                }
                let rule = ResourceRule(baseDir: FS.parent(settingsPath), patterns: patterns, defaultEnabled: true)
                for index in unique.indices where unique[index].item.scopeID == "global"
                    && unique[index].item.harnessID == "pi" && unique[index].item.kind == .skill {
                    let skillFile = FS.join(unique[index].item.sourcePath, "SKILL.md")
                    if !ResourceFilters.enabled(file: skillFile, rules: [rule]) {
                        unique[index].item.inheritedIn.removeAll { $0 == repository.id }
                    }
                }
            } catch {
                warning(settingsPath, "Project skill filters could not be read; runtime availability may differ.")
            }
        }
        return ScanResult(repositories: repositories, registry: registry, targets: unique, warnings: warnings)
    }

    private static func parseFrontmatter(_ document: String) -> ConfigValue? {
        let pattern = #"^\uFEFF?---\s*\r?\n([\s\S]*?)\r?\n---(?:\s|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: document, range: NSRange(document.startIndex..., in: document)),
              let range = Range(match.range(at: 1), in: document) else { return nil }
        return try? Configuration.parse(String(document[range]), format: .yaml)
    }

    private static func pathJSON(_ path: [PathKey]) -> String {
        let values: [Any] = path.map { key in
            switch key { case .key(let value): value as Any; case .index(let value): value as Any }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    private static func truthy(_ value: ConfigValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .null: return false
        case .bool(let value): return value
        case .string(let value): return !value.isEmpty
        case .number(let value): return (Double(value) ?? 0) != 0
        case .object, .array: return true
        }
    }
}

private struct ProvenanceLookup {
    private struct Root {
        var path: String
        var records: [String: Provenance]
    }
    private var roots: [Root] = []

    init(home: String, repositories: [Repository], warnings: inout [ScanWarning]) {
        func load(_ file: String, directories: [String]) {
            guard FS.exists(file) else { return }
            do {
                let parsed = try Configuration.parse(FS.readText(file), format: .json)
                guard let skills = parsed["skills"]?.object else { throw ManagerError("Invalid lock metadata") }
                var records: [String: Provenance] = [:]
                for (name, value) in skills {
                    guard let source = value.object else { continue }
                    let provenance = ProvenanceResolver.publicSource(source["source"], type: source["sourceType"]?.string)
                        ?? ProvenanceResolver.publicSource(source["sourceUrl"])
                    if var provenance {
                        provenance.evidence = "lockfile"
                        records[name] = provenance
                    }
                }
                for directory in directories {
                    guard FS.exists(directory), let resolved = try? FS.realPath(directory) else { continue }
                    roots.append(Root(path: resolved, records: records))
                }
            } catch {
                warnings.append(ScanWarning(path: FS.friendly(file, home: home),
                                            message: "Skill source/creator metadata is invalid or unreadable. Unrecorded creators are shown as Unknown."))
            }
        }

        load(FS.join(home, ".agents", ".skill-lock.json"), directories: [FS.join(home, ".agents", "skills")])
        for repository in repositories {
            let directories = InventoryScanner.lockSkillDirectories.map { FS.join(repository.path, $0, "skills") }
            for file in [FS.join(repository.path, "skills-lock.json"),
                         FS.join(repository.path, ".agents", ".skill-lock.json"),
                         FS.join(repository.path, ".agents", "skills-lock.json")] {
                load(file, directories: directories)
            }
        }
        roots.sort { $0.path.count > $1.path.count }
    }

    func resolve(folder: String, metadata: ConfigValue?, declared: Provenance?, supplied: Provenance?) -> Provenance {
        guard let resolved = try? FS.realPath(folder) else { return ProvenanceResolver.merging(declared, provided: supplied) }
        for root in roots where resolved.hasPrefix(root.path + "/") {
            if let record = root.records[FS.name(resolved)] { return record }
        }
        return ProvenanceResolver.merging(declared, provided: supplied)
    }
}
