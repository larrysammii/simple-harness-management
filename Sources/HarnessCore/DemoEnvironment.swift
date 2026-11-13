import Foundation

/// Creates actual files in an isolated synthetic home. No real installations are read or changed.
public struct DemoEnvironment: Sendable {
    public let root: String
    public let options: ManagerOptions
    public static func create() throws -> DemoEnvironment {
        let requestedRoot = FS.join(FileManager.default.temporaryDirectory.path, "harness-manager-demo-" + UUID().uuidString.lowercased())
        try FS.privateDirectory(requestedRoot)
        let root = try FS.realPath(requestedRoot)
        let home = FS.join(root, "home")
        try FS.privateDirectory(home)
        func write(_ relative: String, _ text: String) throws {
            let file = FS.join(home, relative)
            try FileManager.default.createDirectory(atPath: FS.parent(file), withIntermediateDirectories: true)
            try FS.atomicWrite(file, text: text)
        }
        func skill(_ folder: String, _ name: String, _ description: String, author: String = "Example Studio") throws {
            try write(folder + "/SKILL.md", "---\nname: \(name)\ndescription: \(description)\nauthor: \(author)\n---\n# \(name)\n\nSynthetic instructions for native app testing\n")
        }
        let examples: [(String, String)] = [
            ("code-review", "Review changes for correctness, clarity, and maintainability"),
            ("design-system", "Apply a consistent visual language across interface components"),
            ("diagnosing-bugs", "Find the cause before changing the implementation"),
            ("documentation", "Write concise reference material for developers"),
            ("git-workflow", "Keep changes focused, reviewable, and recoverable"),
            ("release-checklist", "Verify tests, versioning, and distribution before a release"),
            ("swift-concurrency", "Review actor isolation and asynchronous state changes"),
            ("test-first", "Turn requirements into small executable regression tests"),
            ("ui-accessibility", "Check labels, contrast, focus, and keyboard interactions"),
            ("writing-for-agents", "Structure project guidance around clear tasks and constraints"),
            ("performance-review", "Measure rendering and resource use before optimizing"),
            ("security-review", "Check boundaries, validation, and safe failure behavior")
        ]
        var lock: [String: [String: String]] = [:]
        for (name, description) in examples {
            try skill(".agents/skills/" + name, name, description)
            lock[name] = ["source": "example-studio/developer-skills", "sourceType": "github"]
        }
        let lockData = try JSONSerialization.data(withJSONObject: ["version": 3, "skills": lock], options: [.prettyPrinted, .sortedKeys])
        try write(".agents/.skill-lock.json", String(decoding: lockData, as: UTF8.self))
        try skill(".claude/skills/project-planning", "project-planning", "Break a change into independently verifiable steps", author: "Sample Tools")
        try skill(".codex/skills/.system/skill-installer", "skill-installer", "Built-in skill distributed with the harness", author: "System")
        try write(".codex/config.toml", "# Synthetic configuration\nmodel = \"example-model\"\n\n[mcp_servers.documentation]\nurl = \"https://example.invalid/docs/mcp\"\n\n[mcp_servers.filesystem]\ncommand = \"never-executed\"\nargs = []\n")
        try write(".cursor/mcp.json", "{\n  \"mcpServers\": {\n    \"design-reference\": {\"url\": \"https://example.invalid/design/mcp\"},\n    \"repository-tools\": {\"command\": \"never-executed\", \"disabled\": true}\n  }\n}\n")
        try write(".continue/config.yaml", "name: Synthetic configuration\nmcpServers:\n  - name: documentation\n    command: never-executed\n  - name: local-search\n    command: never-executed\n")
        let package = ".pi/agent/npm/node_modules/@example/engineering-kit"
        try write(package + "/package.json", "{\"name\":\"@example/engineering-kit\",\"version\":\"1.2.0\",\"pi\":{\"skills\":[\"skills\"],\"extensions\":[\"extensions\"],\"prompts\":[\"prompts\"],\"themes\":[\"themes\"]}}")
        try skill(package + "/skills/change-review", "change-review", "A packaged review workflow", author: "Example")
        try skill(package + "/skills/release-notes", "release-notes", "A packaged release notes workflow", author: "Example")
        try write(package + "/extensions/audit/index.ts", "throw new Error('SYNTHETIC_PACKAGE_CODE_MUST_NEVER_EXECUTE');\n")
        try write(package + "/prompts/review.md", "Synthetic review prompt\n")
        try write(package + "/themes/editorial.json", "{}")
        try write(".pi/agent/settings.json", "{\n  \"packages\": [{\"source\":\"npm:@example/engineering-kit\",\"skills\":[\"**\",\"!**/release-notes/**\"]}, \"npm:uncached-example\"],\n  \"defaultModel\": \"synthetic-only\"\n}\n")
        for repository in ["atlas-cli", "design-system", "personal-site"] {
            try write("repo/" + repository + "/.git/HEAD", "ref: refs/heads/main\n")
        }
        try skill("repo/atlas-cli/.claude/skills/cli-conventions", "cli-conventions", "Repository-specific command-line conventions", author: "Atlas")
        try write("repo/atlas-cli/.mcp.json", "{\"mcpServers\":{\"project-search\":{\"command\":\"never-executed\"}}}")
        try write("repo/atlas-cli/.pi/settings.json", "{\"packages\":[\"npm:@example/engineering-kit\"]}")
        try FileManager.default.createSymbolicLink(atPath: FS.join(home, ".claude/skills/code-review"),
                                                   withDestinationPath: FS.join(home, ".agents/skills/code-review"))
        try write(".synthetic-home", "This directory contains disposable, synthetic test fixtures only\n")
        return .init(root: root, options: .init(home: home, scanRoots: [FS.join(home, "repo")], stateDir: FS.join(root, "state")))
    }
    public func cleanUp() throws {
        guard FS.name(root).hasPrefix("harness-manager-demo-"), FS.exists(FS.join(options.home, ".synthetic-home")),
              try FS.realPath(FS.parent(root)) == FS.realPath(FileManager.default.temporaryDirectory.path) else {
            throw ManagerError("Refusing cleanup outside a marked synthetic environment")
        }
        try FileManager.default.removeItem(atPath: root)
    }
}
