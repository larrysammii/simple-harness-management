import Foundation

/// Evaluates Pi resource filters as inert path metadata; patterns are never executed.
public enum ResourceFilters {
    private static let maximumPatternLength = 4096
    private static let maximumBraceAlternatives = 256
    private static let maximumMatchCells = 1_000_000

    public static func enabled(file: String, rules: [ResourceRule]) -> Bool {
        let normalizedFile = normalize(file)
        let directory = normalize((file as NSString).deletingLastPathComponent)
        for rule in rules {
            var isEnabled = rule.defaultEnabled
            for raw in rule.patterns {
                let exclusion = raw.hasPrefix("!") || raw.hasPrefix("-")
                let pattern = raw.first == "!" || raw.first == "+" || raw.first == "-" ? String(raw.dropFirst()) : raw
                let absolute = resolve(pattern, relativeTo: rule.baseDir)
                let hasWildcard = pattern.contains(where: { "*?{[".contains($0) })
                if matches(normalizedFile, pattern: absolute)
                    || matches(directory, pattern: absolute)
                    || (!hasWildcard && normalizedFile.hasPrefix(absolute + "/")) {
                    isEnabled = !exclusion
                }
            }
            if !isEnabled { return false }
        }
        return true
    }

    public static func rule(patterns: [String], baseDir: String) -> ResourceRule {
        let defaultEnabled = !patterns.isEmpty && !patterns.contains { !$0.hasPrefix("!") && !$0.hasPrefix("-") }
        return ResourceRule(baseDir: baseDir, patterns: patterns, defaultEnabled: defaultEnabled)
    }

    private static func resolve(_ pattern: String, relativeTo baseDir: String) -> String {
        let candidate = pattern.hasPrefix("/") ? pattern : FS.join(baseDir, pattern)
        return normalize(candidate)
    }

    private static func normalize(_ path: String) -> String { FS.normalized(path) }

    private enum Token {
        case literal(Character)
        case one
        case star
        case globstar
        case globstarDirectory
        case characterClass([Character], negated: Bool)
    }

    private static func matches(_ path: String, pattern: String) -> Bool {
        guard pattern.count <= maximumPatternLength, path.count <= maximumPatternLength else { return false }
        for alternative in braceAlternatives(pattern, limit: maximumBraceAlternatives) {
            let tokens = tokenize(alternative)
            let characters = Array(path)
            guard tokens.count * (characters.count + 1) <= maximumMatchCells else { continue }
            var memo: [UInt64: Bool] = [:]

            func match(_ tokenIndex: Int, _ characterIndex: Int) -> Bool {
                if tokenIndex == tokens.count { return characterIndex == characters.count }
                let key = (UInt64(tokenIndex) << 32) | UInt64(characterIndex)
                if let cached = memo[key] { return cached }
                let result: Bool
                switch tokens[tokenIndex] {
                case .literal(let expected):
                    result = characterIndex < characters.count && characters[characterIndex] == expected
                        && match(tokenIndex + 1, characterIndex + 1)
                case .one:
                    result = characterIndex < characters.count && characters[characterIndex] != "/"
                        && match(tokenIndex + 1, characterIndex + 1)
                case .star:
                    result = match(tokenIndex + 1, characterIndex)
                        || (characterIndex < characters.count && characters[characterIndex] != "/"
                            && match(tokenIndex, characterIndex + 1))
                case .globstar:
                    result = match(tokenIndex + 1, characterIndex)
                        || (characterIndex < characters.count && match(tokenIndex, characterIndex + 1))
                case .globstarDirectory:
                    if match(tokenIndex + 1, characterIndex) {
                        result = true
                    } else {
                        var separator = characterIndex
                        while separator < characters.count, characters[separator] != "/" { separator += 1 }
                        result = separator < characters.count && match(tokenIndex, separator + 1)
                    }
                case .characterClass(let members, let negated):
                    let contains = characterIndex < characters.count && classContains(characters[characterIndex], members: members)
                    result = characterIndex < characters.count && characters[characterIndex] != "/"
                        && (contains != negated) && match(tokenIndex + 1, characterIndex + 1)
                }
                memo[key] = result
                return result
            }

            if match(0, 0) { return true }
        }
        return false
    }

    private static func tokenize(_ pattern: String) -> [Token] {
        let characters = Array(pattern)
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*" {
                var end = index
                while end < characters.count, characters[end] == "*" { end += 1 }
                if end - index >= 2 {
                    if end < characters.count, characters[end] == "/" {
                        tokens.append(.globstarDirectory)
                        index = end + 1
                    } else {
                        tokens.append(.globstar)
                        index = end
                    }
                } else {
                    tokens.append(.star)
                    index += 1
                }
            } else if character == "?" {
                tokens.append(.one)
                index += 1
            } else if character == "[", let close = characters[(index + 1)...].firstIndex(of: "]"), close > index + 1 {
                var members = Array(characters[(index + 1)..<close])
                let negated = members.first == "!" || members.first == "^"
                if negated { members.removeFirst() }
                if members.isEmpty {
                    tokens.append(.literal("["))
                    index += 1
                } else {
                    tokens.append(.characterClass(members, negated: negated))
                    index = close + 1
                }
            } else {
                tokens.append(.literal(character))
                index += 1
            }
        }
        return tokens
    }

    private static func classContains(_ character: Character, members: [Character]) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        var index = 0
        while index < members.count {
            if index + 2 < members.count, members[index + 1] == "-",
               let lower = members[index].unicodeScalars.first?.value,
               let upper = members[index + 2].unicodeScalars.first?.value {
                if lower <= value && value <= upper { return true }
                index += 3
            } else {
                if members[index] == character { return true }
                index += 1
            }
        }
        return false
    }

    private static func braceAlternatives(_ pattern: String, limit: Int) -> [String] {
        guard pattern.count <= maximumPatternLength else { return [] }
        let characters = Array(pattern)
        var searchFrom = 0
        while searchFrom < characters.count {
            guard let open = characters[searchFrom...].firstIndex(of: "{"),
                  let close = matchingBrace(in: characters, from: open) else { break }
            let contents = Array(characters[(open + 1)..<close])
            let branches = splitBraceAlternatives(contents)
            let range = branches == nil ? braceRange(String(contents)) : nil
            let choices = branches ?? range
            if let choices, !choices.isEmpty {
                guard choices.count <= limit else { return [] }
                let prefix = String(characters[..<open])
                let suffix = String(characters[(close + 1)...])
                var result: [String] = []
                for choice in choices {
                    let nested = braceAlternatives(prefix + choice + suffix, limit: limit)
                    guard result.count + nested.count <= limit else { return [] }
                    result.append(contentsOf: nested)
                }
                return result
            }
            searchFrom = close + 1
        }
        return [pattern]
    }

    private static func matchingBrace(in characters: [Character], from start: Int) -> Int? {
        var depth = 0
        for index in start..<characters.count {
            if characters[index] == "{" { depth += 1 }
            if characters[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private static func splitBraceAlternatives(_ contents: [Character]) -> [String]? {
        var choices = [String]()
        var branch = [Character]()
        var depth = 0
        for character in contents {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if character == ",", depth == 0 {
                choices.append(String(branch))
                branch.removeAll(keepingCapacity: true)
            } else {
                branch.append(character)
            }
        }
        guard !choices.isEmpty else { return nil }
        choices.append(String(branch))
        return choices
    }

    private static func braceRange(_ value: String) -> [String]? {
        let parts = value.components(separatedBy: "..")
        guard (2...3).contains(parts.count), let first = parts.first, let last = parts.dropFirst().first else { return nil }
        let rawStep = parts.count == 3 ? (Int(parts[2]) ?? 0) : 1
        guard rawStep != 0, (-1000...1000).contains(rawStep),
              let lower = Int(first), let upper = Int(last),
              (-100_000...100_000).contains(lower), (-100_000...100_000).contains(upper),
              abs(Double(upper) - Double(lower)) <= 256 else { return characterRange(parts, step: rawStep) }
        let step = lower <= upper ? abs(rawStep) : -abs(rawStep)
        return Array(stride(from: lower, through: upper, by: step)).map(String.init)
    }

    private static func characterRange(_ parts: [String], step: Int) -> [String]? {
        guard (2...3).contains(parts.count), step != 0,
              parts[0].count == 1, parts[1].count == 1,
              let lower = parts[0].unicodeScalars.first?.value,
              let upper = parts[1].unicodeScalars.first?.value,
              lower < 128, upper < 128, abs(Int(upper) - Int(lower)) <= 256 else { return nil }
        let strideValue = lower <= upper ? abs(step) : -abs(step)
        return Array(stride(from: Int(lower), through: Int(upper), by: strideValue))
            .compactMap { UnicodeScalar($0).map { String($0) } }
    }
}
