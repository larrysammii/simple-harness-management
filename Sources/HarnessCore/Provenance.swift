import Foundation

/// Resolves declared ownership metadata without contacting a source or executing package code.
public enum ProvenanceResolver {
    private static let publicGitHosts: Set<String> = ["github.com", "gitlab.com", "bitbucket.org", "codeberg.org"]

    public static func publicSource(_ value: ConfigValue?, type: String? = nil) -> Provenance? {
        var raw: String?
        if case .object(let fields)? = value {
            raw = fields["url"]?.string
        } else {
            raw = value?.string
        }
        guard var source = raw, source.utf8.count <= 4096 else { return nil }
        source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !["local", "file", "path"].contains(type ?? "") else { return nil }

        if source.hasPrefix("npm:") || type == "npm" {
            let package = source.hasPrefix("npm:") ? String(source.dropFirst(4)) : source
            guard let name = firstCapture(in: package, pattern: "^(@[a-z\\d._-]+/[a-z\\d._-]+|[a-z\\d._-]+)(?:@[^/]+)?$", options: [.caseInsensitive]) else { return nil }
            let creator = name.hasPrefix("@") ? String(name.dropFirst()).split(separator: "/").first.map(String.init) : nil
            return Provenance(creator: creator, sourceLabel: "npm:\(name)", sourceURL: "https://www.npmjs.com/package/\(name)")
        }

        if source.hasPrefix("git+") { source = String(source.dropFirst(4)) }
        if source.hasPrefix("git:") { source = String(source.dropFirst(4)) }
        if source.hasPrefix("github:") { source = "https://github.com/" + String(source.dropFirst("github:".count)) }
        if let match = firstMatch(in: source, pattern: "^git@(github\\.com|gitlab\\.com|bitbucket\\.org|codeberg\\.org):", options: [.caseInsensitive]),
           let fullRange = Range(match.range(at: 0), in: source), let hostRange = Range(match.range(at: 1), in: source) {
            let host = String(source[hostRange])
            source = "https://\(host)/" + source[fullRange.upperBound...]
        }
        if firstMatch(in: source, pattern: "^(github\\.com|gitlab\\.com|bitbucket\\.org|codeberg\\.org)/", options: [.caseInsensitive]) != nil {
            source = "https://" + source
        }
        if firstMatch(in: source, pattern: "^[a-z\\d-]+/[a-z\\d._-]+(?:@[^/]+)?$", options: [.caseInsensitive]) != nil {
            let hostByType = ["github": "github.com", "gitlab": "gitlab.com", "bitbucket": "bitbucket.org", "codeberg": "codeberg.org"]
            let host: String
            if let type {
                guard let typedHost = hostByType[type] else { return nil }
                host = typedHost
            } else {
                host = "github.com"
            }
            source = "https://\(host)/\(source)"
        }

        guard let components = URLComponents(string: source),
              let scheme = components.scheme?.lowercased(), ["https", "http", "ssh"].contains(scheme),
              let hostname = components.host?.lowercased(), publicGitHosts.contains(hostname) else { return nil }
        let pathBeforeSubpath = components.percentEncodedPath.components(separatedBy: "/-/" ).first ?? components.percentEncodedPath
        var parts = pathBeforeSubpath.split(separator: "/").map(String.init)
        if hostname != "gitlab.com" { parts = Array(parts.prefix(2)) }
        guard parts.count >= 2, let last = parts.indices.last else { return nil }
        parts[last] = parts[last].replacingOccurrences(of: #"\.git(?:@.*)?$"#, with: "", options: .regularExpression)
        parts[last] = parts[last].replacingOccurrences(of: #"@[^/]+$"#, with: "", options: .regularExpression)
        guard parts.allSatisfy({ firstMatch(in: $0, pattern: "^[a-z\\d._-]+$", options: [.caseInsensitive]) != nil }) else { return nil }
        let label = parts.joined(separator: "/")
        let sourceLabel = hostname == "github.com" ? label : "\(hostname)/\(label)"
        let encodedParts = parts.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
        return Provenance(creator: parts[0], sourceLabel: sourceLabel,
                          sourceURL: "https://\(hostname)/" + encodedParts.joined(separator: "/"))
    }

    public static func package(_ manifest: ConfigValue?, declaration: String, name: String) -> Provenance {
        let declared = ConfigValue.string(declaration)
        let source = publicSource(declared, type: declaration.hasPrefix("npm:") ? "npm" : nil)
            ?? publicSource(manifest?["repository"])
            ?? publicSource(manifest?["homepage"])
        let author = creatorName(manifest?["author"])
        return Provenance(creator: source?.creator ?? author,
                          sourceLabel: source?.sourceLabel ?? String(name.prefix(180)),
                          sourceURL: source?.sourceURL,
                          evidence: "package")
    }

    /// Skill frontmatter is intentionally internal: callers receive only sanitized display metadata.
    static func declared(_ data: ConfigValue?) -> Provenance? {
        guard let object = data?.object else { return nil }
        let metadata = object["metadata"]?.object ?? [:]
        let sourceValue = coalescing(metadata["source"], metadata["repository"], object["repository"], object["source"])
        let authorValue = coalescing(metadata["creator"], metadata["author"], object["creator"], object["author"])
        let source = publicSource(sourceValue)
        let author = creatorName(authorValue)
        guard source != nil || author != nil else { return nil }
        return Provenance(creator: author ?? source?.creator,
                          sourceLabel: source?.sourceLabel ?? "Declared in SKILL.md",
                          sourceURL: source?.sourceURL,
                          evidence: "frontmatter")
    }

    static func merging(_ declared: Provenance?, provided: Provenance?) -> Provenance {
        guard let provided else { return declared ?? Provenance() }
        return Provenance(creator: provided.creator ?? declared?.creator,
                          sourceLabel: provided.sourceLabel ?? declared?.sourceLabel,
                          sourceURL: provided.sourceURL ?? declared?.sourceURL,
                          evidence: provided.evidence ?? declared?.evidence)
    }

    private static func coalescing(_ values: ConfigValue?...) -> ConfigValue? {
        values.first { value in
            guard let value else { return false }
            if case .null = value { return false }
            return true
        } ?? nil
    }

    private static func creatorName(_ value: ConfigValue?) -> String? {
        let candidate: String?
        if case .object(let object)? = value { candidate = object["name"]?.string }
        else { candidate = value?.string }
        guard let candidate else { return nil }
        var name = candidate.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\b[\w.+-]+@[\w.-]+\.[a-z]{2,}\b"#, with: "", options: [.regularExpression, .caseInsensitive])
        name = name.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return String(name.prefix(120))
    }

    private static func firstMatch(in string: String, pattern: String, options: NSRegularExpression.Options = []) -> NSTextCheckingResult? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        return expression.firstMatch(in: string, range: NSRange(string.startIndex..., in: string))
    }

    private static func firstCapture(in string: String, pattern: String, options: NSRegularExpression.Options = []) -> String? {
        guard let match = firstMatch(in: string, pattern: pattern, options: options),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: string) else { return nil }
        return String(string[range])
    }
}
