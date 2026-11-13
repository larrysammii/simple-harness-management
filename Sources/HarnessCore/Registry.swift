import Foundation

/// Builds declarative harness adapters. This only inspects paths and configuration references.
enum RegistryBuilder {
    static func build(options: ManagerOptions, repositories: [Repository], warnings: inout [ScanWarning]) throws -> Registry {
        let home = options.home
        let environment = options.environment
        let configHome = configured("XDG_CONFIG_HOME", environment: environment) ?? FS.join(home, ".config")
        let claudeHome = configured("CLAUDE_CONFIG_DIR", environment: environment) ?? FS.join(home, ".claude")
        let codexHome = configured("CODEX_HOME", environment: environment) ?? FS.join(home, ".codex")
        let piHome = configured("PI_CODING_AGENT_DIR", environment: environment) ?? FS.join(home, ".pi", "agent")
        let atHome: ([String]) -> String = { FS.join([home] + $0) }
        var registry = Registry()

        func addHarness(_ id: String, _ name: String, _ description: String) {
            registry.harnesses.append(Harness(id: id, name: name, description: description))
        }
        func skill(_ harnessID: String, _ scopeID: String, _ directory: String, _ inherits: Bool = true) {
            var source = SkillSource(harnessID: harnessID, scopeID: scopeID, directory: directory, inherits: inherits)
            source.singleSkill = false
            registry.skills.append(source)
        }
        func mcp(_ harnessID: String, _ scopeID: String, _ file: String, _ format: ConfigFormat = .jsonc,
                 _ mapPath: [PathKey] = [.key("mcpServers")], _ inherits: Bool = true) {
            registry.mcps.append(MCPSource(harnessID: harnessID, scopeID: scopeID, file: file,
                                           format: format, mapPath: mapPath, inherits: inherits))
        }
        func globalSkill(_ id: String, _ directory: String, _ inherits: Bool = true) { skill(id, "global", directory, inherits) }
        func globalMcp(_ id: String, _ file: String, _ format: ConfigFormat = .jsonc, _ mapPath: [PathKey] = [.key("mcpServers")]) {
            mcp(id, "global", file, format, mapPath)
        }

        let sharedIntegrationPaths: [(String, String)] = [
            ("codex", codexHome), ("pi", piHome), ("cursor", atHome([".cursor"])),
            ("gemini", atHome([".gemini"])), ("opencode", FS.join(configHome, "opencode")),
            ("amp", FS.join(configHome, "amp"))
        ]
        let sharedIntegrations = Set(sharedIntegrationPaths.compactMap { FS.exists($0.1) ? $0.0 : nil })
        let piAdapter = FS.exists(FS.join(piHome, "mcp-adapter.json"))
            || FS.exists(FS.join(piHome, "npm", "node_modules", "pi-mcp-adapter"))
        func sharedSkill(_ id: String) {
            if sharedIntegrations.contains(id) { globalSkill(id, atHome([".agents", "skills"])) }
        }

        addHarness("shared", "Shared resources", "Shared skill and MCP source directories. Harness integration determines availability.")
        globalSkill("shared", atHome([".agents", "skills"]), false)
        addHarness("claude", "Claude Code", "Claude Code skills and user, project, and local-scope MCP configuration.")
        globalSkill("claude", FS.join(claudeHome, "skills"))
        globalMcp("claude", environment["CLAUDE_CONFIG_DIR"]?.isEmpty == false
                   ? FS.join(claudeHome, ".claude.json") : atHome([".claude.json"]), .json)
        addHarness("codex", "Codex", "Codex skills and named MCP server tables.")
        globalSkill("codex", FS.join(codexHome, "skills"))
        sharedSkill("codex")
        globalMcp("codex", FS.join(codexHome, "config.toml"), .toml, [.key("mcp_servers")])
        addHarness("pi", "Pi", "Pi skills, native MCP configuration, and MCP adapter configuration.")
        globalSkill("pi", FS.join(piHome, "skills"))
        sharedSkill("pi")
        globalMcp("pi", FS.join(piHome, "mcp.json"))
        globalMcp("pi", FS.join(piHome, "mcp-adapter.json"))
        globalMcp("pi", FS.join(piHome, "mcp-adapter.json"), .jsonc, [.key("mcp-servers")])
        for file in [FS.join(configHome, "mcp", "mcp.json"), atHome([".agents", "mcp.json"]), atHome([".agents", "mcp", "mcp.json"])] {
            mcp("shared", "global", file, .jsonc, [.key("mcpServers")], false)
            if piAdapter { globalMcp("pi", file) }
        }
        addHarness("cursor", "Cursor", "Cursor user and project skills and MCP servers.")
        globalSkill("cursor", atHome([".cursor", "skills"]))
        sharedSkill("cursor")
        if sharedIntegrations.contains("cursor") {
            globalSkill("cursor", FS.join(claudeHome, "skills"))
            globalSkill("cursor", FS.join(codexHome, "skills"))
        }
        globalMcp("cursor", atHome([".cursor", "mcp.json"]))
        addHarness("gemini", "Gemini CLI", "Gemini skills and settings-based MCP servers.")
        globalSkill("gemini", atHome([".gemini", "skills"]))
        sharedSkill("gemini")
        globalMcp("gemini", atHome([".gemini", "settings.json"]))
        addHarness("opencode", "OpenCode", "OpenCode native and compatible Agent Skills and MCP configuration.")
        globalSkill("opencode", FS.join(configHome, "opencode", "skills"))
        if sharedIntegrations.contains("opencode") { globalSkill("opencode", FS.join(claudeHome, "skills")) }
        sharedSkill("opencode")
        for ext in ["json", "jsonc"] { globalMcp("opencode", FS.join(configHome, "opencode", "opencode.\(ext)"), .jsonc, [.key("mcp")]) }
        addHarness("windsurf", "Windsurf", "Windsurf skills and global MCP settings.")
        globalSkill("windsurf", atHome([".codeium", "windsurf", "skills"]))
        globalMcp("windsurf", atHome([".codeium", "windsurf", "mcp_config.json"]))
        addHarness("cline", "Cline", "Cline skills and editor-managed global MCP settings.")
        globalSkill("cline", atHome([".cline", "skills"]))
        globalSkill("cline", atHome(["Documents", "Cline", "Skills"]))
        addHarness("roo", "Roo Code", "Roo Code skills and global or project MCP settings.")
        globalSkill("roo", atHome([".roo", "skills"]))
        addHarness("continue", "Continue", "Continue skills and YAML/JSON MCP configuration.")
        globalSkill("continue", atHome([".continue", "skills"]))
        globalMcp("continue", atHome([".continue", "config.yaml"]), .yaml)
        globalMcp("continue", atHome([".continue", "config.json"]), .jsonc)
        addHarness("amp", "Amp", "Amp shared skills and settings-based MCP servers.")
        sharedSkill("amp")
        globalMcp("amp", FS.join(configHome, "amp", "settings.json"), .jsonc, [.key("amp.mcpServers")])
        addHarness("copilot", "GitHub Copilot / VS Code", "Copilot skills and VS Code MCP server configuration.")
        globalSkill("copilot", atHome([".copilot", "skills"]))
        let editorHomes = [
            atHome(["Library", "Application Support", "Code", "User"]),
            atHome(["Library", "Application Support", "Code - Insiders", "User"]),
            atHome(["Library", "Application Support", "Cursor", "User"])
        ]
        for editorHome in editorHomes {
            globalMcp("cline", FS.join(editorHome, "globalStorage", "saoudrizwan.claude-dev", "settings", "cline_mcp_settings.json"))
            globalMcp("roo", FS.join(editorHome, "globalStorage", "rooveterinaryinc.roo-cline", "settings", "mcp_settings.json"))
            if !editorHome.contains("Cursor") { globalMcp("copilot", FS.join(editorHome, "mcp.json"), .jsonc, [.key("servers")]) }
        }

        for repository in repositories {
            let root = repository.path
            let join: ([String]) -> String = { FS.join([root] + $0) }
            skill("shared", repository.id, join([".agents", "skills"]), false)
            skill("claude", repository.id, join([".claude", "skills"]))
            mcp("claude", repository.id, join([".mcp.json"]), .json)
            // Claude's local-scope MCP registrations live under the canonical project path in its user file.
            let claudeConfig = environment["CLAUDE_CONFIG_DIR"]?.isEmpty == false
                ? FS.join(claudeHome, ".claude.json") : atHome([".claude.json"])
            mcp("claude", repository.id, claudeConfig, .json,
                [.key("projects"), .key(repository.path), .key("mcpServers")])
            if sharedIntegrations.contains("codex") || FS.exists(join([".codex"])) {
                skill("codex", repository.id, join([".agents", "skills"]))
            }
            mcp("codex", repository.id, join([".codex", "config.toml"]), .toml, [.key("mcp_servers")])
            skill("pi", repository.id, join([".pi", "skills"]))
            if sharedIntegrations.contains("pi") || FS.exists(join([".pi"])) {
                skill("pi", repository.id, join([".agents", "skills"]))
            }
            if piAdapter || FS.exists(join([".pi", "mcp-adapter.json"])) { mcp("pi", repository.id, join([".mcp.json"])) }
            mcp("pi", repository.id, join([".pi", "mcp.json"]))
            mcp("pi", repository.id, join([".pi", "mcp-adapter.json"]))
            mcp("pi", repository.id, join([".pi", "mcp-adapter.json"]), .jsonc, [.key("mcp-servers")])
            skill("cursor", repository.id, join([".cursor", "skills"]))
            if sharedIntegrations.contains("cursor") || FS.exists(join([".cursor"])) {
                for directory in [".agents", ".claude", ".codex"] { skill("cursor", repository.id, join([directory, "skills"])) }
            }
            skill("gemini", repository.id, join([".gemini", "skills"]))
            if sharedIntegrations.contains("gemini") || FS.exists(join([".gemini"])) { skill("gemini", repository.id, join([".agents", "skills"])) }
            mcp("gemini", repository.id, join([".gemini", "settings.json"]))
            skill("opencode", repository.id, join([".opencode", "skills"]))
            if sharedIntegrations.contains("opencode") || FS.exists(join([".opencode"])) {
                for directory in [".claude", ".agents"] { skill("opencode", repository.id, join([directory, "skills"])) }
            }
            for ext in ["json", "jsonc"] {
                mcp("opencode", repository.id, join(["opencode.\(ext)"]), .jsonc, [.key("mcp")])
                mcp("opencode", repository.id, join([".opencode", "opencode.\(ext)"]), .jsonc, [.key("mcp")])
            }
            skill("windsurf", repository.id, join([".windsurf", "skills"]))
            skill("cline", repository.id, join([".cline", "skills"]))
            skill("roo", repository.id, join([".roo", "skills"]))
            mcp("roo", repository.id, join([".roo", "mcp.json"]))
            skill("continue", repository.id, join([".continue", "skills"]))
            mcp("continue", repository.id, join([".continue", "config.yaml"]), .yaml)
            mcp("continue", repository.id, join([".continue", "config.json"]))
            if sharedIntegrations.contains("amp") || FS.exists(join([".amp"])) { skill("amp", repository.id, join([".agents", "skills"])) }
            mcp("amp", repository.id, join([".amp", "settings.json"]), .jsonc, [.key("amp.mcpServers")])
            skill("copilot", repository.id, join([".github", "skills"]))
            mcp("copilot", repository.id, join([".vscode", "mcp.json"]), .jsonc, [.key("servers")])
        }

        let scopes: [(String, String)] = [("global", atHome([".continue", "mcpServers"]))]
            + repositories.map { ($0.id, FS.join($0.path, ".continue", "mcpServers")) }
        for (scopeID, directory) in scopes where FS.exists(directory) {
            do {
                for file in try FS.children(directory) where file.range(of: #"\.ya?ml$"#, options: .regularExpression) != nil {
                    mcp("continue", scopeID, FS.join(directory, file), .yaml)
                }
            } catch {
                warnings.append(ScanWarning(path: FS.friendly(directory, home: home), message: "Continue MCP directory could not be read."))
            }
        }

        // Imported MCP definitions are displayed through Pi but remain owned by their source harness.
        let ownSources = registry.mcps
        let importOwners = ["claude-code": "claude", "cursor": "cursor", "codex": "codex",
                            "opencode": "opencode", "vscode": "copilot", "windsurf": "windsurf"]
        let globalAdapter = FS.join(piHome, "mcp-adapter.json")
        let globalImports = readImports(globalAdapter)
        let importScopes = [("global", globalAdapter)] + repositories.map { ($0.id, FS.join($0.path, ".pi", "mcp-adapter.json")) }
        for (scopeID, file) in importScopes {
            let imports = Set(globalImports + readImports(file))
            for importedName in imports.sorted() {
                guard let owner = importOwners[importedName] else { continue }
                for source in ownSources where source.harnessID == owner && source.scopeID == scopeID {
                    var imported = source
                    imported.harnessID = "pi"
                    imported.readOnlyReason = "Imported from \(importedName). Manage this server in its owning harness/source configuration, not by deleting an imported reference."
                    registry.mcps.append(imported)
                }
            }
        }

        try NativePackages.addSources(to: &registry, options: options, repositories: repositories, warnings: &warnings)
        return registry
    }

    private static func configured(_ key: String, environment: [String: String]) -> String? {
        guard let value = environment[key], !value.isEmpty else { return nil }
        return value
    }

    private static func readImports(_ file: String) -> [String] {
        guard FS.exists(file), let text = try? FS.readText(file),
              let data = try? Configuration.parse(text, format: .jsonc),
              let values = data["imports"]?.array else { return [] }
        return values.compactMap(\.string)
    }
}
