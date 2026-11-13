import Foundation

/// Native, metadata-only discovery for Pi package registrations. Package contents are never loaded or run.
public enum NativePackages {
    private static let resourceTypes = ["skills", "extensions", "prompts", "themes"]
    private static let ignoredDirectories: Set<String> = ["node_modules", ".git", "dist", "build"]
    private static let maxResourceFiles = 5_000
    private static let maxResourceDepth = 8
    private static let maxResourceBytes = 128 * 1024 * 1024
    private static let maxSingleResourceBytes = 64 * 1024 * 1024

    private struct RegistrationGroup {
        var identity: String
        var indexes: [Int]
        var sources: [String]
        var roots: [String: String]
        var root: String?
        var name: String
        var declaration: ConfigValue
    }

    private struct ResourceRecord {
        var type: String
        var path: String
        var contentHash: String
        var linkTarget: String
    }

    private struct ResourceSummary {
        var resources: [String: PackageResourceSummary]
        var complete: Bool
        var records: [ResourceRecord]
    }

    /// Resolve only already-present package folders. This method never fetches a package.
    public static func resolveRoot(source: String, folder: String, piHome: String, home: String) -> String? {
        if source.hasPrefix("npm:"), let name = npmPackageName(source) {
            let local = FS.join(folder, "npm", "node_modules", name)
            return packagePathExists(local) ? local : FS.join(piHome, "npm", "node_modules", name)
        }

        if source.hasPrefix("https://") || source.hasPrefix("http://") || source.hasPrefix("git:https://")
            || source.hasPrefix("git:http://") || source.hasPrefix("git:github.com/") {
            guard let repository = gitRepository(source) else { return nil }
            let local = FS.join([folder, "git", repository.host] + repository.components)
            return packagePathExists(local) ? local : FS.join([piHome, "git", repository.host] + repository.components)
        }

        if source.hasPrefix(".") || source.hasPrefix("/") || source.hasPrefix("~/") || source == "~" {
            return FS.expand(source, home: home, base: source.hasPrefix(".") ? folder : nil)
        }
        return nil
    }

    /// Add Pi package registrations, explicit Pi skill paths, and generated/read-only caches to a registry.
    public static func addSources(
        to registry: inout Registry,
        options: ManagerOptions,
        repositories: [Repository],
        warnings: inout [ScanWarning]
    ) throws {
        let piHome = configuredHome(["PI_CODING_AGENT_DIR", "PI_HOME"], options: options, fallback: FS.join(options.home, ".pi", "agent"))
        let codexHome = configuredHome(["CODEX_HOME"], options: options, fallback: FS.join(options.home, ".codex"))
        registry.packages = try discover(options: options, piHome: piHome, repositories: repositories, warnings: &warnings)

        for scope in scopes(piHome: piHome, repositories: repositories) {
            let settingsFile = FS.join(scope.folder, "settings.json")
            guard let settings = readSettings(settingsFile) else { continue }

            let custom = strings(settings["skills"])
            let expanded = custom.map { expandRule($0, base: scope.folder, home: options.home) }
            for index in registry.skills.indices where registry.skills[index].harnessID == "pi" && registry.skills[index].scopeID == scope.id {
                registry.skills[index].rules = [ResourceRule(baseDir: scope.folder, patterns: expanded, defaultEnabled: true)]
            }

            for raw in expanded where isPositive(raw) {
                let value = removeRulePrefix(raw)
                let path = wildcardRoot(value, base: scope.folder)
                let isMarkdownFile = path.lowercased().hasSuffix(".md")
                if isMarkdownFile && FS.name(path) != "SKILL.md" {
                    warnings.append(.init(path: FS.friendly(path, home: options.home), message: "Standalone Markdown skill declared in Pi settings; directory-based SKILL.md discovery does not manage this resource."))
                    continue
                }
                let singleSkill = isMarkdownFile || FS.exists(FS.join(path, "SKILL.md"))
                var source = SkillSource(harnessID: "pi", scopeID: scope.id, directory: isMarkdownFile ? FS.parent(path) : path,
                                         inherits: scope.id == "global")
                source.singleSkill = singleSkill
                source.rules = [ResourceRule(baseDir: scope.folder, patterns: expanded, defaultEnabled: true)]
                registry.skills.append(source)
            }

            guard let declarations = settings["packages"]?.array else { continue }
            for (declarationIndex, declaration) in declarations.prefix(maxResourceFiles).enumerated() {
                guard let source = packageSource(declaration),
                      let registration = registry.packages.first(where: {
                          $0.settingsFile == settingsFile && $0.sources.contains(source)
                      }),
                      registration.indexes.last == declarationIndex else { continue }

                guard registration.info.inventoryComplete else { continue }
                let packageRoot = registration.roots[source] ?? resolveRoot(source: source, folder: scope.folder, piHome: piHome, home: options.home)
                guard let packageRoot, packagePathExists(packageRoot), let realRoot = try? FS.realPath(packageRoot), FS.isDirectory(packageRoot) else { continue }

                let manifestValue = readManifestValue(packageRoot: packageRoot, realRoot: realRoot)
                let packageName = registration.info.name.isEmpty
                    ? (manifestValue?["name"]?.string ?? FS.name(packageRoot))
                    : registration.info.name
                let pi = manifestValue?["pi"]
                let declaredSkills: [String]
                if pi?.object != nil {
                    declaredSkills = pi?["skills"]?.array == nil ? [] : strings(pi?["skills"])
                } else {
                    declaredSkills = ["skills"]
                }
                let filters = declaration.object?["skills"].map(strings)
                let rules = [ResourceFilters.rule(patterns: declaredSkills, baseDir: packageRoot)]
                    + (filters.map { [ResourceFilters.rule(patterns: $0, baseDir: packageRoot)] } ?? [])
                guard let packageRealRoot = try? FS.realPath(packageRoot) else { continue }

                for raw in declaredSkills.prefix(maxResourceFiles) where isPositive(raw) {
                    let resolved = wildcardRoot(removeRulePrefix(raw), base: packageRoot)
                    guard pathContains(resolved, root: packageRoot) else { continue }
                    if let resolvedReal = try? FS.realPath(resolved), !pathContains(resolvedReal, root: packageRealRoot) { continue }
                    let isSkillFile = FS.name(resolved) == "SKILL.md"
                    if isSkillFile && !safeRegularFile(resolved, within: packageRealRoot) { continue }
                    if !isSkillFile && FS.exists(FS.join(resolved, "SKILL.md"))
                        && !safeRegularFile(FS.join(resolved, "SKILL.md"), within: packageRealRoot) { continue }
                    var skill = SkillSource(harnessID: "pi", scopeID: scope.id, directory: isSkillFile ? FS.parent(resolved) : resolved,
                                            inherits: scope.id == "global")
                    skill.singleSkill = isSkillFile
                    skill.packageName = packageName
                    skill.packageID = registration.info.id
                    skill.rules = rules
                    skill.provenance = ProvenanceResolver.package(manifestValue, declaration: source, name: packageName)
                    skill.readOnlyReason = "Provided by \(packageName). Use Pi package resource settings to change it; deleting cached files would be undone on reload."
                    registry.skills.append(skill)
                }
            }
        }

        if let memoryPackage = registry.packages.first(where: { $0.info.scopeID == "global" && $0.info.name == "pi-hermes-memory" }) {
            var generated = SkillSource(harnessID: "pi", scopeID: "global", directory: FS.join(piHome, "pi-hermes-memory", "skills"), inherits: true)
            generated.packageName = "pi-hermes-memory"
            generated.packageID = memoryPackage.info.id
            generated.readOnlyReason = "Generated by pi-hermes-memory. Remove individual skills through its skill manager, or remove the entire package registration."
            registry.skills.append(generated)
        }

        var codexCache = SkillSource(harnessID: "codex", scopeID: "global", directory: FS.join(codexHome, "packages", "standalone"), inherits: true)
        codexCache.packageName = "Codex packages"
        codexCache.readOnlyReason = "Installed as a Codex package. Remove it through Codex rather than deleting cached resources."
        registry.skills.append(codexCache)
    }

    /// Catalog package registrations independently from their cached resource files.
    public static func discover(
        options: ManagerOptions,
        piHome: String,
        repositories: [Repository],
        warnings: inout [ScanWarning]
    ) throws -> [InstalledPackage] {
        var result: [InstalledPackage] = []
        for scope in scopes(piHome: piHome, repositories: repositories) {
            let settingsFile = FS.join(scope.folder, "settings.json")
            guard FS.exists(settingsFile) else { continue }

            let text: String
            let settings: ConfigValue
            do {
                text = try FS.readText(settingsFile)
                settings = try Configuration.parse(text, format: .jsonc)
            } catch {
                warnings.append(.init(path: FS.friendly(settingsFile, home: options.home), message: "Pi package registrations could not be read safely."))
                continue
            }
            guard let rawDeclarations = settings["packages"]?.array else { continue }
            let declarations = Array(rawDeclarations.prefix(maxResourceFiles))

            let parentRealPath: String
            do { parentRealPath = try FS.realPath(FS.parent(settingsFile)) }
            catch {
                warnings.append(.init(path: FS.friendly(settingsFile, home: options.home), message: "Pi package registrations could not be read safely."))
                continue
            }
            let canonicalPath = FS.join(parentRealPath, FS.name(settingsFile))
            let statFingerprint = (try? FS.fingerprint(settingsFile, content: text)) ?? ""
            let configFingerprint = statFingerprint.isEmpty ? FS.hash(text) : statFingerprint
            let settingsSymlink = FS.isSymlink(settingsFile)
            var groups: [RegistrationGroup] = []
            var groupIndexes: [String: Int] = [:]

            for (index, declaration) in declarations.enumerated() {
                guard let source = packageSource(declaration) else { continue }
                let root = resolveRoot(source: source, folder: scope.folder, piHome: piHome, home: options.home)
                let npmName = npmPackageName(source)
                let publicInfo = ProvenanceResolver.publicSource(.string(source))
                let identity: String
                if let npmName {
                    identity = "npm:\(npmName)"
                } else if isLocalSource(source) {
                    identity = "local:\(root ?? source)"
                } else {
                    identity = publicInfo?.sourceURL ?? source
                }
                let name = npmName ?? root.map(FS.name) ?? publicInfo?.sourceLabel ?? "Configured Pi package"
                if let groupIndex = groupIndexes[identity] {
                    groups[groupIndex].indexes.append(index)
                    groups[groupIndex].sources.append(source)
                    groups[groupIndex].declaration = declaration
                    if groups[groupIndex].root == nil { groups[groupIndex].root = root }
                    if let root { groups[groupIndex].roots[source] = root }
                } else {
                    var roots: [String: String] = [:]
                    if let root { roots[source] = root }
                    groupIndexes[identity] = groups.count
                    groups.append(RegistrationGroup(identity: identity, indexes: [index], sources: [source], roots: roots,
                                                    root: root, name: name, declaration: declaration))
                }
            }

            for group in groups {
                var manifestValue: ConfigValue?
                var manifestText = "<missing package manifest>"
                var inventoryComplete = true
                let realRoot = group.root.flatMap { try? FS.realPath($0) }
                let cachePresent = realRoot != nil
                if let root = group.root, let realRoot, FS.isDirectory(root) {
                    if let manifest = readManifest(packageRoot: root, realRoot: realRoot, complete: &inventoryComplete) {
                        manifestValue = manifest.value
                        manifestText = manifest.text
                    }
                }

                let name: String
                if group.name.hasPrefix("@") || group.sources.first?.hasPrefix("npm:") == true {
                    name = group.name
                } else if let declaredName = manifestValue?["name"]?.string {
                    name = String(declaredName.prefix(160))
                } else {
                    name = group.name
                }
                let provenance = ProvenanceResolver.package(manifestValue, declaration: group.sources[0], name: name)
                var resources = emptyResources()
                var resourceRecords: [ResourceRecord] = []
                if let root = group.root, cachePresent {
                    do {
                        let summary = try summarize(root: root, manifest: manifestValue, declaration: group.declaration,
                                                    realRoot: realRoot!)
                        resources = summary.resources
                        resourceRecords = summary.records
                        inventoryComplete = inventoryComplete && summary.complete
                    } catch {
                        inventoryComplete = false
                    }
                }
                let directReferences = hasDirectResourceReferences(settings, root: group.root, folder: scope.folder, home: options.home)
                let id = FS.id("pi-package", scope.id, canonicalPath, group.identity)
                var info = PackageInstallation(name: name, scopeID: scope.id, settingsPath: settingsFile,
                                                displayPath: FS.friendly(settingsFile, home: options.home))
                info.id = id
                info.identityKey = FS.id("pi-package-identity", group.identity)
                info.fingerprint = packageFingerprint(configFingerprint: configFingerprint, configText: text,
                                                      sources: group.sources, manifestText: manifestText, records: resourceRecords)
                info.version = manifestValue?["version"]?.string.map { String($0.prefix(80)) }
                info.cachePath = group.root.map { FS.friendly($0, home: options.home) }
                info.provenance = provenance
                info.canUninstall = !settingsSymlink && !directReferences
                info.readOnlyReason = settingsSymlink
                    ? "The Pi settings file is a symlink. Manage its owning configuration instead."
                    : directReferences
                        ? "Pi settings also contain direct resource paths into this package. Remove those explicit extensions/skills/prompts/themes references first; cached resources could otherwise remain active."
                        : nil
                info.cachePresent = cachePresent
                info.inventoryComplete = inventoryComplete
                info.resources = resources

                result.append(InstalledPackage(info: info, settingsFile: settingsFile, configFingerprint: configFingerprint,
                                               parentRealPath: parentRealPath, canonicalPath: canonicalPath, indexes: group.indexes,
                                               sources: group.sources, roots: group.roots))
            }
        }

        let identities = result.map { $0.info.identityKey }
        let scopeIDs = result.map { $0.info.scopeID }
        for index in result.indices {
            result[index].info.otherScopes = result.indices.filter { $0 != index && identities[$0] == identities[index] }.map { scopeIDs[$0] }
        }
        return result
    }

    private static func scopes(piHome: String, repositories: [Repository]) -> [(id: String, folder: String)] {
        [("global", piHome)] + repositories.map { ($0.id, FS.join($0.path, ".pi")) }
    }

    private static func configuredHome(_ names: [String], options: ManagerOptions, fallback: String) -> String {
        for name in names {
            if let value = options.environment[name], !value.isEmpty {
                return FS.expand(value, home: options.home)
            }
        }
        return fallback
    }

    private static func packagePathExists(_ path: String) -> Bool {
        (try? FS.realPath(path)) != nil
    }

    private static func npmPackageName(_ source: String) -> String? {
        guard source.hasPrefix("npm:") else { return nil }
        let value = String(source.dropFirst(4))
        let name: String
        let version: String?
        if value.hasPrefix("@"), let slash = value.firstIndex(of: "/") {
            let afterSlash = value.index(after: slash)
            if let separator = value[afterSlash...].firstIndex(of: "@") {
                name = String(value[..<separator])
                version = String(value[value.index(after: separator)...])
            } else {
                name = value
                version = nil
            }
        } else if let separator = value.firstIndex(of: "@") {
            name = String(value[..<separator])
            version = String(value[value.index(after: separator)...])
        } else {
            name = value
            version = nil
        }
        if let version, version.isEmpty || version.contains("/") { return nil }
        guard name.range(of: #"^(?:@[a-z\d._-]+/[a-z\d._-]+|[a-z\d._-]+)$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        return name
    }

    private static func gitRepository(_ source: String) -> (host: String, components: [String])? {
        var value = source
        if value.hasPrefix("git:"), !value.hasPrefix("git:https://"), !value.hasPrefix("git:http://") {
            value = String(value.dropFirst(4))
        } else if value.hasPrefix("git:") {
            value = String(value.dropFirst(4))
        }
        if value.hasPrefix("github.com/") { value = "https://" + value }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let rawHost = components.host?.lowercased() else { return nil }
        var parts = components.path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        if let last = parts.last {
            var repository = last.replacingOccurrences(of: #"\.git(?:@.*)?$"#, with: "", options: .regularExpression)
            repository = repository.replacingOccurrences(of: #"@[^/]+$"#, with: "", options: .regularExpression)
            parts[parts.count - 1] = repository
        }
        guard parts.count == 2, parts.allSatisfy({
            $0.range(of: #"^[a-z\d._-]+$"#, options: [.regularExpression, .caseInsensitive]) != nil && $0 != "." && $0 != ".."
        }), rawHost.range(of: #"^[a-z\d.-]+$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return (rawHost, parts)
    }

    private static func isLocalSource(_ source: String) -> Bool {
        source.hasPrefix(".") || source.hasPrefix("/") || source.hasPrefix("~/") || source == "~"
    }

    private static func packageSource(_ declaration: ConfigValue) -> String? {
        if let source = declaration.string { return source }
        return declaration.object?["source"]?.string
    }

    private static func strings(_ value: ConfigValue?) -> [String] {
        value?.array?.compactMap(\.string) ?? []
    }

    private static func readSettings(_ path: String) -> ConfigValue? {
        guard FS.exists(path), let text = try? FS.readText(path), let value = try? Configuration.parse(text, format: .jsonc) else { return nil }
        return value
    }

    private static func readManifestValue(packageRoot: String, realRoot: String) -> ConfigValue? {
        var complete = true
        return readManifest(packageRoot: packageRoot, realRoot: realRoot, complete: &complete)?.value
    }

    private static func readManifest(packageRoot: String, realRoot: String, complete: inout Bool) -> (value: ConfigValue?, text: String)? {
        let path = FS.join(packageRoot, "package.json")
        guard FS.exists(path) else { return nil }
        do {
            let realManifest = try FS.realPath(path)
            guard pathContains(realManifest, root: realRoot) else { complete = false; return nil }
            let text = try FS.readText(path)
            do {
                return (try Configuration.parse(text, format: .json), text)
            } catch {
                complete = false
                return (nil, text)
            }
        } catch {
            complete = false
            return nil
        }
    }

    private static func emptyResources() -> [String: PackageResourceSummary] {
        Dictionary(uniqueKeysWithValues: resourceTypes.map { ($0, PackageResourceSummary()) })
    }

    private static func summarize(root: String, manifest: ConfigValue?, declaration: ConfigValue, realRoot: String) throws -> ResourceSummary {
        var resources = emptyResources()
        var records: [ResourceRecord] = []
        var complete = true
        var visited = 0
        var totalBytes = 0
        let normalizedRoot = FS.normalized(root)

        if !FS.isDirectory(root) {
            guard isRegularFile(root) else {
                return ResourceSummary(resources: resources, complete: false, records: records)
            }
            let filters = declaration.object?["extensions"].map(strings)
            var enabled = true
            if let filters { enabled = ResourceFilters.enabled(file: root, rules: [ResourceFilters.rule(patterns: filters, baseDir: FS.parent(root))]) }
            do {
                let data = try FS.readData(root, maxBytes: maxSingleResourceBytes)
                totalBytes += data.count
                records.append(resourceRecord(type: "extensions", path: root, data: data))
            } catch {
                complete = false
            }
            resources["extensions"] = PackageResourceSummary(installed: 1, enabled: enabled ? 1 : 0, names: [FS.name(root)])
            return ResourceSummary(resources: resources, complete: complete, records: records)
        }

        for type in resourceTypes {
            let pi = manifest?["pi"]
            let patterns: [String]
            if pi?.object != nil {
                patterns = pi?[type]?.array == nil ? [] : strings(pi?[type])
            } else {
                patterns = [type]
            }
            let includeRule = ResourceFilters.rule(patterns: patterns, baseDir: root)
            let declaredFilters = declaration.object?[type].map(strings)
            let enabledRules = declaredFilters.map { [ResourceFilters.rule(patterns: $0, baseDir: root)] } ?? []
            var found: [String: ResourceRecord] = [:]
            var seen: Set<String> = []

            func add(_ file: String) {
                guard ResourceFilters.enabled(file: file, rules: [includeRule]), found[file] == nil else { return }
                do {
                    let real = try FS.realPath(file)
                    guard pathContains(real, root: realRoot) else { complete = false; return }
                    let data = try FS.readData(file, maxBytes: maxSingleResourceBytes)
                    totalBytes += data.count
                    if totalBytes > maxResourceBytes {
                        complete = false
                        found[file] = ResourceRecord(type: type, path: file, contentHash: "content-over-limit", linkTarget: "")
                        return
                    }
                    found[file] = resourceRecord(type: type, path: file, data: data)
                } catch {
                    complete = false
                    found[file] = ResourceRecord(type: type, path: file, contentHash: "unreadable", linkTarget: "")
                }
            }

            func walk(_ file: String, depth: Int) {
                visited += 1
                guard depth <= maxResourceDepth, visited <= maxResourceFiles else { complete = false; return }
                let real: String
                do { real = try FS.realPath(file) }
                catch {
                    if FS.exists(file) { complete = false }
                    return
                }
                guard pathContains(real, root: realRoot) else { complete = false; return }
                guard !seen.contains(real) else { return }
                seen.insert(real)

                if FS.isDirectory(file) {
                    if type == "skills", FS.exists(FS.join(file, "SKILL.md")) {
                        add(FS.join(file, "SKILL.md"))
                        return
                    }
                    if type == "extensions" {
                        for index in ["index.ts", "index.js", "index.mjs", "index.cjs"] {
                            let candidate = FS.join(file, index)
                            if FS.exists(candidate) {
                                add(candidate)
                                return
                            }
                        }
                    }
                    do {
                                for child in try FS.children(file) where !ignoredDirectories.contains(child) {
                            guard visited < maxResourceFiles else { complete = false; break }
                            let childPath = FS.join(file, child)
                            if FS.isDirectory(childPath) || isRegularFile(childPath) || FS.isSymlink(childPath) {
                                walk(childPath, depth: depth + 1)
                            }
                        }
                    } catch {
                        complete = false
                    }
                    return
                }

                guard isRegularFile(file) else {
                    if FS.exists(file) { complete = false }
                    return
                }
                if resourceFileMatches(file, type: type) { add(file) }
            }

            for raw in patterns.prefix(maxResourceFiles) where isPositive(raw) {
                guard visited < maxResourceFiles else { complete = false; break }
                let candidate = wildcardRoot(removeRulePrefix(raw), base: root)
                guard pathContains(candidate, root: normalizedRoot) else { complete = false; continue }
                walk(candidate, depth: 0)
            }

            let files = found.keys.sorted()
            let enabledCount = files.reduce(into: 0) { count, file in
                if declaredFilters == nil || ResourceFilters.enabled(file: file, rules: enabledRules) { count += 1 }
            }
            resources[type] = PackageResourceSummary(
                installed: files.count,
                enabled: enabledCount,
                names: files.map { type == "skills" ? FS.name(FS.parent($0)) : relativePath($0, from: normalizedRoot) }
            )
            records.append(contentsOf: files.compactMap { found[$0] })
        }
        return ResourceSummary(resources: resources, complete: complete, records: records)
    }

    private static func resourceRecord(type: String, path: String, data: Data) -> ResourceRecord {
        let linkTarget = FS.isSymlink(path) ? (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "" : ""
        return ResourceRecord(type: type, path: path, contentHash: FS.hash(data), linkTarget: linkTarget)
    }

    private static func resourceFileMatches(_ path: String, type: String) -> Bool {
        let name = FS.name(path)
        switch type {
        case "skills": return name == "SKILL.md"
        case "extensions":
            let lower = name.lowercased()
            return [".js", ".mjs", ".cjs", ".ts"].contains(where: { lower.hasSuffix($0) }) && !lower.hasSuffix(".d.ts")
        case "prompts": return name.lowercased().hasSuffix(".md")
        case "themes": return name.lowercased().hasSuffix(".json")
        default: return false
        }
    }

    private static func isRegularFile(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        return (attributes[.type] as? FileAttributeType) == .typeRegular
    }

    private static func safeRegularFile(_ path: String, within root: String) -> Bool {
        guard let real = try? FS.realPath(path), pathContains(real, root: root) else { return false }
        return isRegularFile(path)
    }

    private static func hasDirectResourceReferences(_ settings: ConfigValue, root: String?, folder: String, home: String) -> Bool {
        guard let root, let realRoot = try? FS.realPath(root) else { return false }
        for type in resourceTypes {
            for raw in strings(settings[type]) where isPositive(raw) {
                let expanded = expandRule(raw, base: folder, home: home)
                let candidate = wildcardCandidate(removeRulePrefix(expanded))
                let resolvedCandidate = (try? FS.realPath(candidate)) ?? FS.normalized(candidate)
                if pathContains(resolvedCandidate, root: realRoot) || pathContains(realRoot, root: resolvedCandidate) { return true }
            }
        }
        return false
    }

    private static func expandRule(_ raw: String, base: String, home: String) -> String {
        let prefix = raw.first.map { "!+-".contains($0) ? String($0) : "" } ?? ""
        let value = prefix.isEmpty ? raw : String(raw.dropFirst())
        return prefix + FS.expand(value, home: home, base: base)
    }

    private static func wildcardRoot(_ value: String, base: String) -> String {
        let wildcard = value.firstIndex(where: { "*?{[".contains($0) })
        let relative: String
        if let wildcard {
            let prefix = String(value[..<wildcard])
            relative = prefix.hasSuffix("/") ? String(prefix.dropLast()) : FS.parent(prefix)
        } else {
            relative = value
        }
        if relative.hasPrefix("/") { return FS.normalized(relative) }
        return FS.normalized(FS.join(base, relative.isEmpty ? "." : relative))
    }

    private static func wildcardCandidate(_ value: String) -> String {
        guard let wildcard = value.firstIndex(where: { "*?{[".contains($0) }) else { return FS.normalized(value) }
        let prefix = String(value[..<wildcard])
        let candidate = prefix.hasSuffix("/") ? String(prefix.dropLast()) : FS.parent(prefix)
        return FS.normalized(candidate)
    }

    private static func isPositive(_ pattern: String) -> Bool {
        !pattern.hasPrefix("!") && !pattern.hasPrefix("-")
    }

    private static func removeRulePrefix(_ pattern: String) -> String {
        guard let first = pattern.first, "!+-".contains(first) else { return pattern }
        return String(pattern.dropFirst())
    }

    private static func pathContains(_ candidate: String, root: String) -> Bool {
        let candidate = FS.normalized(candidate)
        let root = FS.normalized(root)
        if candidate == root { return true }
        let prefix = root == "/" ? "/" : root + "/"
        return candidate.hasPrefix(prefix)
    }

    private static func relativePath(_ path: String, from root: String) -> String {
        let normalized = FS.normalized(path)
        let prefix = root == "/" ? "/" : root + "/"
        return normalized.hasPrefix(prefix) ? String(normalized.dropFirst(prefix.count)) : FS.name(path)
    }

    private static func stableHash(_ parts: [String]) -> String {
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return FS.hash(data)
    }

    private static func packageFingerprint(configFingerprint: String, configText: String, sources: [String], manifestText: String,
                                           records: [ResourceRecord]) -> String {
        var parts = ["config", configFingerprint, configText, "manifest", manifestText]
        parts.append(contentsOf: sources.flatMap { ["source", $0] })
        for record in records.sorted(by: { ($0.type, $0.path) < ($1.type, $1.path) }) {
            parts.append(contentsOf: ["resource", record.type, record.path, record.contentHash, record.linkTarget])
        }
        return stableHash(parts)
    }
}
