import Foundation
import TOML
import Yams

private extension Yams.Tag {
    var semanticName: Yams.Tag.Name { .init(rawValue: rawValue) }
}

/// Parses supported configuration formats and performs verified, source-preserving deletions.
public enum Configuration {
    fileprivate static let maximumBytes = 4 * 1024 * 1024
    fileprivate static let maximumDepth = 128
    fileprivate static let maximumNodes = 100_000
    fileprivate static let maximumYAMLAliases = 20
    private static let protectedKeys: Set<String> = ["__proto__", "prototype", "constructor"]

    public static func parse(_ text: String, format: ConfigFormat) throws -> ConfigValue {
        guard text.utf8.count <= maximumBytes else {
            throw ManagerError("Configuration exceeds the safe size limit")
        }
        let value: ConfigValue
        do {
            switch format {
            case .json, .jsonc:
                var parser = JSONConfigParser(text: text, allowsComments: format == .jsonc,
                                              allowsTrailingCommas: format == .jsonc)
                value = try parser.parse().value
            case .toml:
                let decoder = TOMLDecoder()
                decoder.limits.maxInputSize = maximumBytes
                decoder.limits.maxDepth = maximumDepth
                decoder.limits.maxArrayLength = maximumNodes
                decoder.limits.maxTableKeys = maximumNodes
                value = try decoder.decode(TOMLDynamicValue.self, from: text).value
            case .yaml:
                value = try YAMLConfigParser(text: text).parse()
            }
        } catch let error as ManagerError {
            throw error
        } catch {
            throw ManagerError("Invalid \(format.rawValue.uppercased()) configuration")
        }
        guard value.object != nil else { throw ManagerError("Expected a configuration object") }
        return value
    }

    /// Removes one object key or array element without reformatting unrelated source text.
    /// The result is reparsed and compared to the expected semantic deletion before it is returned.
    public static func removing(_ text: String, format: ConfigFormat, path: [PathKey]) throws -> String {
        guard path.count >= 2,
              !path.contains(where: { part in
                  switch part {
                  case .key(let key): return protectedKeys.contains(key) || key.isEmpty
                  case .index(let index): return index < 0
                  }
              }) else {
            throw ManagerError("This configuration entry cannot be edited safely")
        }

        let original = try parse(text, format: format)
        guard original.at(path) != nil else {
            throw ManagerError("The entry no longer exists. Refresh the inventory")
        }
        var expected = original
        guard removeValue(at: path, from: &expected) else {
            throw ManagerError("This configuration structure is read-only")
        }

        let updated: String
        switch format {
        case .json, .jsonc:
            var parser = JSONConfigParser(text: text, allowsComments: format == .jsonc,
                                          allowsTrailingCommas: format == .jsonc)
            let parsed = try parser.parse()
            guard let range = parsed.deletionRange(for: path) else {
                throw ManagerError("This configuration structure is read-only")
            }
            updated = try replacing(text, range: range, with: "")
        case .toml:
            updated = try removeTOML(text, path: path, expected: expected)
        case .yaml:
            updated = try YAMLConfigParser(text: text).removing(path: path)
        }

        let actual = try parse(updated, format: format)
        guard actual == expected else {
            throw ManagerError("Safe edit verification failed. No configuration was changed")
        }
        return updated
    }

    private static func removeValue(at path: [PathKey], from value: inout ConfigValue) -> Bool {
        guard let first = path.first else { return false }
        if path.count == 1 {
            switch (value, first) {
            case (.object(var object), .key(let key)) where object.removeValue(forKey: key) != nil:
                value = .object(object)
                return true
            case (.array(var array), .index(let index)) where array.indices.contains(index):
                array.remove(at: index)
                value = .array(array)
                return true
            default:
                return false
            }
        }
        switch (value, first) {
        case (.object(var object), .key(let key)):
            guard var child = object[key], removeValue(at: Array(path.dropFirst()), from: &child) else { return false }
            object[key] = child
            value = .object(object)
            return true
        case (.array(var array), .index(let index)) where array.indices.contains(index):
            guard removeValue(at: Array(path.dropFirst()), from: &array[index]) else { return false }
            value = .array(array)
            return true
        default:
            return false
        }
    }

    private static func replacing(_ text: String, range: Range<Int>, with replacement: String) throws -> String {
        let bytes = Array(text.utf8)
        guard range.lowerBound >= 0, range.upperBound <= bytes.count, range.lowerBound <= range.upperBound,
              let prefix = String(bytes: bytes[..<range.lowerBound], encoding: .utf8),
              let suffix = String(bytes: bytes[range.upperBound...], encoding: .utf8) else {
            throw ManagerError("This configuration structure is read-only")
        }
        return prefix + replacement + suffix
    }

    // MARK: TOML source edits

    private static func quotedTOMLKey(_ key: String) -> String {
        var result = "\""
        for scalar in key.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0...0x1F, 0x7F:
                let digits = String(scalar.value, radix: 16, uppercase: true)
                let width = scalar.value <= 0xFFFF ? 4 : 8
                result += (width == 4 ? "\\u" : "\\U") + String(repeating: "0", count: max(0, width - digits.count)) + digits
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private static func removeTOML(_ text: String, path: [PathKey], expected: ConfigValue) throws -> String {
        var stringPath: [String] = []
        for part in path {
            guard case .key(let key) = part else { throw ManagerError("This TOML structure is read-only") }
            stringPath.append(key)
        }
        let scan = try TOMLSourceScanner(text: text).scan()
        let lines = scan.lines
        guard !lines.isEmpty else { throw ManagerError("This TOML structure is read-only") }

        var startLine: Int?
        var boundaryLine: Int?
        if let header = scan.statements.first(where: { statement in
            if case .header(let keyPath, _) = statement.kind { return keyPath == stringPath }
            return false
        }) {
            startLine = header.line
            boundaryLine = scan.statements.first(where: { statement in
                guard statement.line > header.line, case .header(let keyPath, _) = statement.kind else { return false }
                return !keyPath.starts(with: stringPath)
            })?.line ?? lines.count
        } else if let assignment = scan.statements.first(where: { statement in
            if case .assignment(let keyPath) = statement.kind { return keyPath == stringPath }
            return false
        }) {
            startLine = assignment.line
            boundaryLine = scan.statements.first(where: { $0.line > assignment.line })?.line ?? lines.count
        }
        guard let start = startLine, var end = boundaryLine else {
            throw ManagerError("This TOML entry is inline or otherwise read-only")
        }

        while end > start + 1, lines[end - 1].isTrivia { end -= 1 }
        let byteStart = lines[start].start
        let byteEnd = end < lines.count ? lines[end].start : text.utf8.count
        var updated = try replacing(text, range: byteStart..<byteEnd, with: "")

        // Removing the final named table would otherwise discard TOML's implicit parent table.
        let parentPath = Array(path.dropLast())
        if expected.at(parentPath) != nil, try parse(updated, format: .toml).at(parentPath) == nil {
            let eol = text.contains("\r\n") ? "\r\n" : "\n"
            if !updated.isEmpty, !updated.hasSuffix("\n") { updated += eol }
            let encodedPath = try parentPath.map { part -> String in
                guard case .key(let key) = part else { throw ManagerError("This TOML structure is read-only") }
                return quotedTOMLKey(key)
            }.joined(separator: ".")
            updated += "[\(encodedPath)]\(eol)"
        }
        return updated
    }
}

// MARK: - JSON / JSONC lexical parser

private final class JSONConfigNode {
    enum Children {
        case object([JSONConfigMember], trailingComma: Int?)
        case array([JSONConfigElement], trailingComma: Int?)
        case none
    }
    let value: ConfigValue
    let start: Int
    let end: Int
    let children: Children
    init(value: ConfigValue, start: Int, end: Int, children: Children = .none) {
        self.value = value; self.start = start; self.end = end; self.children = children
    }

    func deletionRange(for path: [PathKey]) -> Range<Int>? {
        guard let parent = node(at: Array(path.dropLast()), from: self) else { return nil }
        switch (parent.children, path.last) {
        case (.object(let members, _), .key(let key)):
            guard let itemIndex = members.firstIndex(where: { $0.key == key }) else { return nil }
            let item = members[itemIndex]
            if itemIndex < members.count - 1, let comma = item.commaAfter {
                return item.keyStart..<(comma + 1)
            }
            if itemIndex > 0, let comma = members[itemIndex - 1].commaAfter {
                return comma..<item.value.end
            }
            if case .object(_, let trailing) = parent.children, let trailing {
                return item.keyStart..<(trailing + 1)
            }
            return item.keyStart..<item.value.end
        case (.array(let elements, _), .index(let index)) where elements.indices.contains(index):
            let item = elements[index]
            if index < elements.count - 1, let comma = item.commaAfter {
                return item.value.start..<(comma + 1)
            }
            if index > 0, let comma = elements[index - 1].commaAfter {
                return comma..<item.value.end
            }
            if case .array(_, let trailing) = parent.children, let trailing {
                return item.value.start..<(trailing + 1)
            }
            return item.value.start..<item.value.end
        default:
            return nil
        }
    }

    private func node(at path: [PathKey], from root: JSONConfigNode) -> JSONConfigNode? {
        var current = root
        for part in path {
            switch (current.children, part) {
            case (.object(let members, _), .key(let key)):
                guard let next = members.first(where: { $0.key == key })?.value else { return nil }
                current = next
            case (.array(let elements, _), .index(let index)) where elements.indices.contains(index):
                current = elements[index].value
            default: return nil
            }
        }
        return current
    }
}

private struct JSONConfigMember {
    let key: String
    let keyStart: Int
    let value: JSONConfigNode
    let commaAfter: Int?
}
private struct JSONConfigElement {
    let value: JSONConfigNode
    let commaAfter: Int?
}

private struct JSONConfigParser {
    private let bytes: [UInt8]
    private let allowsComments: Bool
    private let allowsTrailingCommas: Bool
    private var index = 0
    private var nodeCount = 0

    init(text: String, allowsComments: Bool, allowsTrailingCommas: Bool) {
        self.bytes = Array(text.utf8)
        self.allowsComments = allowsComments
        self.allowsTrailingCommas = allowsTrailingCommas
    }

    mutating func parse() throws -> JSONConfigNode {
        try skipTrivia()
        let root = try parseValue(depth: 0)
        try skipTrivia()
        guard index == bytes.count else { throw ManagerError("Invalid JSON configuration") }
        guard root.value.object != nil else { throw ManagerError("Expected a configuration object") }
        return root
    }

    private mutating func parseValue(depth: Int) throws -> JSONConfigNode {
        guard depth <= Configuration.maximumDepth else { throw ManagerError("Configuration exceeds the safe nesting limit") }
        nodeCount += 1
        guard nodeCount <= Configuration.maximumNodes, index < bytes.count else {
            throw ManagerError("Invalid JSON configuration")
        }
        try skipTrivia()
        let start = index
        switch bytes[index] {
        case 0x7B: return try parseObject(depth: depth, start: start)
        case 0x5B: return try parseArray(depth: depth, start: start)
        case 0x22:
            let value = try parseString()
            return JSONConfigNode(value: .string(value), start: start, end: index)
        case 0x74:
            try consumeLiteral(Array("true".utf8))
            return JSONConfigNode(value: .bool(true), start: start, end: index)
        case 0x66:
            try consumeLiteral(Array("false".utf8))
            return JSONConfigNode(value: .bool(false), start: start, end: index)
        case 0x6E:
            try consumeLiteral(Array("null".utf8))
            return JSONConfigNode(value: .null, start: start, end: index)
        case 0x2D, 0x30...0x39:
            let number = try parseNumber()
            return JSONConfigNode(value: .number(number), start: start, end: index)
        default:
            throw ManagerError("Invalid JSON configuration")
        }
    }

    private mutating func parseObject(depth: Int, start: Int) throws -> JSONConfigNode {
        index += 1
        try skipTrivia()
        var members: [JSONConfigMember] = []
        var seen = Set<String>()
        if consume(0x7D) {
            return JSONConfigNode(value: .object([:]), start: start, end: index, children: .object([], trailingComma: nil))
        }
        var trailingComma: Int?
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else { throw ManagerError("Invalid JSON configuration") }
            let keyStart = index
            let key = try parseString()
            guard seen.insert(key).inserted else { throw ManagerError("Duplicate JSON object key") }
            try skipTrivia()
            guard consume(0x3A) else { throw ManagerError("Invalid JSON configuration") }
            try skipTrivia()
            let value = try parseValue(depth: depth + 1)
            try skipTrivia()
            var comma: Int?
            if index < bytes.count, bytes[index] == 0x2C {
                comma = index
                index += 1
                try skipTrivia()
                if index < bytes.count, bytes[index] == 0x7D {
                    guard allowsTrailingCommas else { throw ManagerError("Invalid JSON configuration") }
                    trailingComma = comma
                    members.append(JSONConfigMember(key: key, keyStart: keyStart, value: value, commaAfter: comma))
                    index += 1
                    let object = Dictionary(uniqueKeysWithValues: members.map { ($0.key, $0.value.value) })
                    return JSONConfigNode(value: .object(object), start: start, end: index,
                                          children: .object(members, trailingComma: trailingComma))
                }
            } else if index < bytes.count, bytes[index] == 0x7D {
                members.append(JSONConfigMember(key: key, keyStart: keyStart, value: value, commaAfter: nil))
                index += 1
                let object = Dictionary(uniqueKeysWithValues: members.map { ($0.key, $0.value.value) })
                return JSONConfigNode(value: .object(object), start: start, end: index, children: .object(members, trailingComma: nil))
            } else {
                throw ManagerError("Invalid JSON configuration")
            }
            members.append(JSONConfigMember(key: key, keyStart: keyStart, value: value, commaAfter: comma))
        }
    }

    private mutating func parseArray(depth: Int, start: Int) throws -> JSONConfigNode {
        index += 1
        try skipTrivia()
        var elements: [JSONConfigElement] = []
        if consume(0x5D) {
            return JSONConfigNode(value: .array([]), start: start, end: index, children: .array([], trailingComma: nil))
        }
        var trailingComma: Int?
        while true {
            let value = try parseValue(depth: depth + 1)
            try skipTrivia()
            if index < bytes.count, bytes[index] == 0x2C {
                let comma = index
                index += 1
                try skipTrivia()
                if index < bytes.count, bytes[index] == 0x5D {
                    guard allowsTrailingCommas else { throw ManagerError("Invalid JSON configuration") }
                    trailingComma = comma
                    elements.append(JSONConfigElement(value: value, commaAfter: comma))
                    index += 1
                    return JSONConfigNode(value: .array(elements.map { $0.value.value }), start: start, end: index,
                                          children: .array(elements, trailingComma: trailingComma))
                }
                elements.append(JSONConfigElement(value: value, commaAfter: comma))
            } else if consume(0x5D) {
                elements.append(JSONConfigElement(value: value, commaAfter: nil))
                return JSONConfigNode(value: .array(elements.map { $0.value.value }), start: start, end: index,
                                      children: .array(elements, trailingComma: nil))
            } else {
                throw ManagerError("Invalid JSON configuration")
            }
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        guard consume(0x22) else { throw ManagerError("Invalid JSON configuration") }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                let data = Data(bytes[start..<index])
                do { return try JSONDecoder().decode(String.self, from: data) }
                catch { throw ManagerError("Invalid JSON configuration") }
            }
            if byte < 0x20 { throw ManagerError("Invalid JSON configuration") }
            if byte == 0x5C {
                index += 1
                guard index < bytes.count else { throw ManagerError("Invalid JSON configuration") }
                index += 1
            } else {
                index += 1
            }
        }
        throw ManagerError("Invalid JSON configuration")
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        _ = consume(0x2D)
        guard index < bytes.count else { throw ManagerError("Invalid JSON configuration") }
        if consume(0x30) {
            if index < bytes.count, isDigit(bytes[index]) { throw ManagerError("Invalid JSON configuration") }
        } else {
            guard consumeDigit(minimum: 1) else { throw ManagerError("Invalid JSON configuration") }
        }
        if consume(0x2E) { guard consumeDigit(minimum: 1) else { throw ManagerError("Invalid JSON configuration") } }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
            guard consumeDigit(minimum: 1) else { throw ManagerError("Invalid JSON configuration") }
        }
        guard index == bytes.count || isValueDelimiter(bytes[index]) else { throw ManagerError("Invalid JSON configuration") }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func consumeDigit(minimum count: Int) -> Bool {
        let start = index
        while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        return index - start >= count
    }

    private mutating func consumeLiteral(_ literal: [UInt8]) throws {
        guard bytes[index...].starts(with: literal) else { throw ManagerError("Invalid JSON configuration") }
        index += literal.count
        guard index == bytes.count || isValueDelimiter(bytes[index]) else { throw ManagerError("Invalid JSON configuration") }
    }

    private mutating func skipTrivia() throws {
        while index < bytes.count {
            if isJSONWhitespace(bytes[index]) { index += 1; continue }
            guard bytes[index] == 0x2F else { return }
            guard allowsComments, index + 1 < bytes.count else { throw ManagerError("Invalid JSON configuration") }
            if bytes[index + 1] == 0x2F {
                index += 2
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
            } else if bytes[index + 1] == 0x2A {
                index += 2
                var closed = false
                while index + 1 < bytes.count {
                    if bytes[index] == 0x2A, bytes[index + 1] == 0x2F { index += 2; closed = true; break }
                    index += 1
                }
                guard closed else { throw ManagerError("Invalid JSON configuration") }
            } else {
                throw ManagerError("Invalid JSON configuration")
            }
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    private func isJSONWhitespace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
    private func isValueDelimiter(_ byte: UInt8) -> Bool {
        isJSONWhitespace(byte) || byte == 0x2C || byte == 0x5D || byte == 0x7D || byte == 0x2F
    }
}

// MARK: - TOML dynamic decoding and lexical spans

private struct TOMLDynamicKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue) }
}

private struct TOMLDynamicValue: Decodable {
    let value: ConfigValue

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: TOMLDynamicKey.self) {
            var object: [String: ConfigValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(TOMLDynamicValue.self, forKey: key).value
            }
            value = .object(object)
            return
        }
        if var container = try? decoder.unkeyedContainer() {
            var array: [ConfigValue] = []
            while !container.isAtEnd {
                guard array.count < Configuration.maximumNodes else { throw ManagerError("Configuration exceeds the safe item limit") }
                array.append(try container.decode(TOMLDynamicValue.self).value)
            }
            value = .array(array)
            return
        }
        let scalar = try decoder.singleValueContainer()
        if let boolean = try? scalar.decode(Bool.self) { value = .bool(boolean); return }
        if let integer = try? scalar.decode(Int64.self) { value = .number(String(integer)); return }
        if let float = try? scalar.decode(Double.self) { value = .number(String(float)); return }
        if let string = try? scalar.decode(String.self) { value = .string(string); return }
        if let date = try? scalar.decode(LocalDate.self) {
            value = .string(String(format: "%04d-%02d-%02d", date.year, date.month, date.day)); return
        }
        if let time = try? scalar.decode(LocalTime.self) {
            value = .string(Self.formatLocalTime(time.hour, time.minute, time.second, time.nanosecond)); return
        }
        if let dateTime = try? scalar.decode(LocalDateTime.self) {
            value = .string(String(format: "%04d-%02d-%02dT%@", dateTime.year, dateTime.month, dateTime.day,
                                   Self.formatLocalTime(dateTime.hour, dateTime.minute, dateTime.second, dateTime.nanosecond))); return
        }
        if let date = try? scalar.decode(Date.self) {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            value = .string(formatter.string(from: date)); return
        }
        throw ManagerError("Unsupported TOML value")
    }

    private static func formatLocalTime(_ hour: Int, _ minute: Int, _ second: Int, _ nanos: Int) -> String {
        var result = String(format: "%02d:%02d:%02d", hour, minute, second)
        if nanos != 0 {
            var fraction = String(format: "%09d", nanos)
            while fraction.last == "0" { fraction.removeLast() }
            result += "." + fraction
        }
        return result
    }
}

private struct TOMLSourceScanner {
    struct Line {
        let start: Int
        let contentEnd: Int
        let end: Int
        let isTrivia: Bool
    }
    enum Kind { case header([String], isArray: Bool), assignment([String]) }
    struct Statement { let line: Int; let kind: Kind }
    struct Result { let lines: [Line]; let statements: [Statement] }
    private enum StringMode: Equatable { case none, basic, literal, multilineBasic, multilineLiteral }

    private let bytes: [UInt8]
    private let text: String
    init(text: String) { self.text = text; bytes = Array(text.utf8) }

    func scan() throws -> Result {
        let lines = makeLines()
        var statements: [Statement] = []
        var currentTable: [String] = []
        var mode = StringMode.none
        var squareDepth = 0
        var curlyDepth = 0

        for (lineIndex, line) in lines.enumerated() {
            let first = firstNonWhitespace(in: line)
            if mode == .none && squareDepth == 0 && curlyDepth == 0, let first {
                if bytes[first] == 0x5B, let header = try parseHeader(line, first: first) {
                    statements.append(Statement(line: lineIndex, kind: .header(header.path, isArray: header.isArray)))
                    currentTable = header.path
                } else if let equals = findAssignmentEquals(in: line) {
                    let keyBytes = bytes[first..<equals]
                    if let keyPath = try? parseKeyPath(Array(keyBytes)) {
                        statements.append(Statement(line: lineIndex, kind: .assignment(currentTable + keyPath)))
                    }
                }
            }
            scanLine(line, mode: &mode, squareDepth: &squareDepth, curlyDepth: &curlyDepth)
        }
        return Result(lines: lines, statements: statements)
    }

    private func makeLines() -> [Line] {
        var lines: [Line] = []
        var start = 0
        for index in bytes.indices where bytes[index] == 0x0A {
            var contentEnd = index
            if contentEnd > start, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            lines.append(Line(start: start, contentEnd: contentEnd, end: index + 1,
                              isTrivia: isTrivia(start..<contentEnd)))
            start = index + 1
        }
        if start < bytes.count || bytes.isEmpty {
            var contentEnd = bytes.count
            if contentEnd > start, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            lines.append(Line(start: start, contentEnd: contentEnd, end: bytes.count,
                              isTrivia: isTrivia(start..<contentEnd)))
        }
        return lines
    }

    private func isTrivia(_ range: Range<Int>) -> Bool {
        var cursor = range.lowerBound
        while cursor < range.upperBound && (bytes[cursor] == 0x20 || bytes[cursor] == 0x09) { cursor += 1 }
        return cursor == range.upperBound || bytes[cursor] == 0x23
    }

    private func firstNonWhitespace(in line: Line) -> Int? {
        var cursor = line.start
        while cursor < line.contentEnd && (bytes[cursor] == 0x20 || bytes[cursor] == 0x09) { cursor += 1 }
        return cursor < line.contentEnd && bytes[cursor] != 0x23 ? cursor : nil
    }

    private func parseHeader(_ line: Line, first: Int) throws -> (path: [String], isArray: Bool)? {
        var cursor = first + 1
        let isArray = cursor < line.contentEnd && bytes[cursor] == 0x5B
        if isArray { cursor += 1 }
        let keyStart = cursor
        var quote: UInt8 = 0
        var escaped = false
        while cursor < line.contentEnd {
            let byte = bytes[cursor]
            if quote == 0 {
                if byte == 0x22 || byte == 0x27 { quote = byte }
                else if byte == 0x5D { break }
            } else if quote == 0x22 {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == quote { quote = 0 }
            } else if byte == quote { quote = 0 }
            cursor += 1
        }
        guard cursor < line.contentEnd, quote == 0 else { return nil }
        let keyEnd = cursor
        if isArray {
            guard cursor + 1 < line.contentEnd, bytes[cursor + 1] == 0x5D else { return nil }
            cursor += 2
        } else { cursor += 1 }
        while cursor < line.contentEnd, bytes[cursor] == 0x20 || bytes[cursor] == 0x09 { cursor += 1 }
        guard cursor == line.contentEnd || bytes[cursor] == 0x23 else { return nil }
        let path = try parseKeyPath(Array(bytes[keyStart..<keyEnd]))
        return (path, isArray)
    }

    private func findAssignmentEquals(in line: Line) -> Int? {
        var cursor = line.start
        var quote: UInt8 = 0
        var escaped = false
        while cursor < line.contentEnd {
            let byte = bytes[cursor]
            if quote == 0 {
                if byte == 0x23 { return nil }
                if byte == 0x22 || byte == 0x27 { quote = byte }
                else if byte == 0x3D { return cursor }
            } else if quote == 0x22 {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == quote { quote = 0 }
            } else if byte == quote { quote = 0 }
            cursor += 1
        }
        return nil
    }

    private func parseKeyPath(_ source: [UInt8]) throws -> [String] {
        var cursor = 0
        var result: [String] = []
        func skipSpace() { while cursor < source.count && (source[cursor] == 0x20 || source[cursor] == 0x09) { cursor += 1 } }
        skipSpace()
        while cursor < source.count {
            let start = cursor
            let key: String
            if source[cursor] == 0x22 || source[cursor] == 0x27 {
                let quote = source[cursor]
                cursor += 1
                var escaped = false
                while cursor < source.count {
                    let byte = source[cursor]
                    if quote == 0x22 {
                        if escaped { escaped = false }
                        else if byte == 0x5C { escaped = true }
                        else if byte == quote { break }
                    } else if byte == quote { break }
                    cursor += 1
                }
                guard cursor < source.count, source[cursor] == quote else { throw ManagerError("Invalid TOML key") }
                cursor += 1
                let token = String(decoding: source[start..<cursor], as: UTF8.self)
                guard let decoded = try? TOMLDecoder().decode([String: Int].self, from: "\(token) = 0"),
                      let name = decoded.keys.first else { throw ManagerError("Invalid TOML key") }
                key = name
            } else {
                while cursor < source.count {
                    let byte = source[cursor]
                    let valid = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) ||
                        (byte >= 0x30 && byte <= 0x39) || byte == 0x5F || byte == 0x2D
                    if !valid { break }
                    cursor += 1
                }
                guard cursor > start else { throw ManagerError("Invalid TOML key") }
                key = String(decoding: source[start..<cursor], as: UTF8.self)
            }
            result.append(key)
            skipSpace()
            if cursor == source.count { break }
            guard source[cursor] == 0x2E else { throw ManagerError("Invalid TOML key") }
            cursor += 1
            skipSpace()
        }
        return result
    }

    private func scanLine(_ line: Line, mode: inout StringMode, squareDepth: inout Int, curlyDepth: inout Int) {
        var cursor = line.start
        while cursor < line.contentEnd {
            let byte = bytes[cursor]
            switch mode {
            case .none:
                if byte == 0x23 { return }
                if byte == 0x22 {
                    if cursor + 2 < line.contentEnd, bytes[cursor + 1] == 0x22, bytes[cursor + 2] == 0x22 {
                        mode = .multilineBasic; cursor += 3; continue
                    }
                    mode = .basic
                } else if byte == 0x27 {
                    if cursor + 2 < line.contentEnd, bytes[cursor + 1] == 0x27, bytes[cursor + 2] == 0x27 {
                        mode = .multilineLiteral; cursor += 3; continue
                    }
                    mode = .literal
                } else if byte == 0x5B { squareDepth += 1 }
                else if byte == 0x5D { squareDepth = max(0, squareDepth - 1) }
                else if byte == 0x7B { curlyDepth += 1 }
                else if byte == 0x7D { curlyDepth = max(0, curlyDepth - 1) }
            case .basic:
                if byte == 0x5C { cursor += 2; continue }
                if byte == 0x22 { mode = .none }
            case .literal:
                if byte == 0x27 { mode = .none }
            case .multilineBasic:
                if byte == 0x5C { cursor += 2; continue }
                if byte == 0x22, cursor + 2 < line.contentEnd,
                   bytes[cursor + 1] == 0x22, bytes[cursor + 2] == 0x22 { mode = .none; cursor += 3; continue }
            case .multilineLiteral:
                if byte == 0x27, cursor + 2 < line.contentEnd,
                   bytes[cursor + 1] == 0x27, bytes[cursor + 2] == 0x27 { mode = .none; cursor += 3; continue }
            }
            cursor += 1
        }
    }
}

// MARK: - YAML AST and source edits

private struct YAMLConfigParser {
    private let text: String
    private let sourceLines: [YAMLLine]
    private var aliasCount = 0
    private var visitedNodes = 0
    private var anchorVisits: [String: Int] = [:]

    init(text: String) {
        self.text = text
        self.sourceLines = YAMLLine.make(text)
    }

    func parse() throws -> ConfigValue {
        var parser = self
        let root: Node
        do {
            guard let node = try compose(yaml: text) else { throw ManagerError("Expected a configuration object") }
            root = node
        } catch let error as ManagerError { throw error }
        catch { throw ManagerError("Invalid YAML configuration") }
        let value = try parser.convert(root, depth: 0)
        guard value.object != nil else { throw ManagerError("Expected a configuration object") }
        return value
    }

    func removing(path: [PathKey]) throws -> String {
        var parser = self
        let root: Node
        do {
            guard let node = try compose(yaml: text) else { throw ManagerError("Expected a configuration object") }
            root = node
        } catch let error as ManagerError { throw error }
        catch { throw ManagerError("Invalid YAML configuration") }
        _ = try parser.convert(root, depth: 0)
        guard parser.aliasCount == 0 else {
            throw ManagerError("YAML entries using aliases are read-only")
        }
        guard let parent = parser.node(at: Array(path.dropLast()), from: root), let last = path.last,
              let range = parser.deletionRange(parent: parent, key: last) else {
            throw ManagerError("This YAML structure is read-only")
        }
        let bytes = Array(text.utf8)
        guard range.lowerBound >= 0, range.upperBound <= bytes.count,
              let before = String(bytes: bytes[..<range.lowerBound], encoding: .utf8),
              let after = String(bytes: bytes[range.upperBound...], encoding: .utf8) else {
            throw ManagerError("This YAML structure is read-only")
        }
        let replacement: String
        switch parent {
        case .mapping(let mapping) where mapping.count == 1:
            let start = sourceLines.first { $0.start == range.lowerBound }
            replacement = String(repeating: " ", count: start?.indent ?? 0) + "{}" + (text.contains("\r\n") ? "\r\n" : "\n")
        case .sequence(let sequence) where sequence.count == 1:
            let start = sourceLines.first { $0.start == range.lowerBound }
            replacement = String(repeating: " ", count: start?.indent ?? 0) + "[]" + (text.contains("\r\n") ? "\r\n" : "\n")
        default: replacement = ""
        }
        return before + replacement + after
    }

    private mutating func convert(_ node: Node, depth: Int) throws -> ConfigValue {
        visitedNodes += 1
        guard visitedNodes <= Configuration.maximumNodes, depth <= Configuration.maximumDepth else {
            throw ManagerError("YAML configuration exceeds the safe complexity limit")
        }
        if let anchor = node.anchor, let mark = node.mark {
            let identity = "\(anchor.rawValue):\(mark.line):\(mark.column)"
            anchorVisits[identity, default: 0] += 1
            aliasCount += max(0, anchorVisits[identity, default: 0] - 1)
            guard aliasCount <= Configuration.maximumYAMLAliases else {
                throw ManagerError("YAML configuration exceeds the safe alias limit")
            }
        }

        switch node {
        case .scalar(let scalar):
            switch node.tag.semanticName {
            case .str, .implicit: return .string(scalar.string)
            case .bool:
                let raw = scalar.string.lowercased()
                if ["true", "yes", "on"].contains(raw) { return .bool(true) }
                if ["false", "no", "off"].contains(raw) { return .bool(false) }
                throw ManagerError("Unsupported YAML boolean")
            case .null: return .null
            case .int, .float: return .number(scalar.string)
            case .timestamp: return .string(scalar.string)
            default: throw ManagerError("Unsupported YAML scalar tag")
            }
        case .sequence(let sequence):
            guard node.tag.semanticName == .seq || node.tag.semanticName == .implicit else { throw ManagerError("Unsupported YAML sequence tag") }
            var values: [ConfigValue] = []
            values.reserveCapacity(sequence.count)
            for item in sequence { values.append(try convert(item, depth: depth + 1)) }
            return .array(values)
        case .mapping(let mapping):
            guard node.tag.semanticName == .map || node.tag.semanticName == .implicit else { throw ManagerError("Unsupported YAML mapping tag") }
            var values: [String: ConfigValue] = [:]
            for (keyNode, valueNode) in mapping {
                guard case .scalar(let keyScalar) = keyNode, keyNode.tag.semanticName == .str else {
                    throw ManagerError("YAML mapping keys must be strings")
                }
                let key = keyScalar.string
                guard values[key] == nil else { throw ManagerError("Duplicate YAML mapping key") }
                values[key] = try convert(valueNode, depth: depth + 1)
            }
            return .object(values)
        case .alias:
            throw ManagerError("Unsupported unresolved YAML alias")
        }
    }

    private func node(at path: [PathKey], from root: Node) -> Node? {
        var current = root
        for part in path {
            switch (current, part) {
            case (.mapping(let mapping), .key(let name)):
                guard let pair = mapping.first(where: { pair in
                    guard case .scalar(let scalar) = pair.key, pair.key.tag.semanticName == .str else { return false }
                    return scalar.string == name
                }) else { return nil }
                current = pair.value
            case (.sequence(let sequence), .index(let index)) where sequence.indices.contains(index):
                current = sequence[index]
            default: return nil
            }
        }
        return current
    }

    private func deletionRange(parent: Node, key: PathKey) -> Range<Int>? {
        switch (parent, key) {
        case (.mapping(let mapping), .key(let name)):
            guard mapping.style != .flow,
                  let pair = mapping.first(where: { pair in
                      guard case .scalar(let scalar) = pair.key, pair.key.tag.semanticName == .str else { return false }
                      return scalar.string == name
                  }), let mark = pair.key.mark else { return nil }
            return blockRange(startLine: mark.line - 1, requireSequenceDash: false)
        case (.sequence(let sequence), .index(let index)) where sequence.indices.contains(index):
            guard sequence.style != .flow, let mark = sequence[index].mark else { return nil }
            return blockRange(startLine: mark.line - 1, requireSequenceDash: true)
        default:
            return nil
        }
    }

    private func blockRange(startLine: Int, requireSequenceDash: Bool) -> Range<Int>? {
        guard sourceLines.indices.contains(startLine) else { return nil }
        let start = sourceLines[startLine]
        let indent = start.indent
        let content = start.content
        if requireSequenceDash {
            guard content.count > indent, content[indent] == 0x2D,
                  content.count == indent + 1 || content[indent + 1] == 0x20 || content[indent + 1] == 0x09 else { return nil }
        } else {
            guard content.count > indent, content[indent] != 0x3F,
                  !(content[indent] == 0x2D && (content.count == indent + 1 || content[indent + 1] == 0x20 || content[indent + 1] == 0x09)) else { return nil }
        }

        var boundary = sourceLines.count
        if startLine + 1 < sourceLines.count {
            for lineIndex in (startLine + 1)..<sourceLines.count {
                let line = sourceLines[lineIndex]
                if line.isBlank || line.isComment { continue }
                if line.indent <= indent { boundary = lineIndex; break }
            }
        }
        var endLine = boundary
        while endLine > startLine + 1 {
            let previous = sourceLines[endLine - 1]
            if previous.isBlank || (previous.isComment && previous.indent <= indent) { endLine -= 1 }
            else { break }
        }
        let endOffset = endLine < sourceLines.count ? sourceLines[endLine].start : text.utf8.count
        return start.start..<endOffset
    }
}

private struct YAMLLine {
    let start: Int
    let content: [UInt8]
    let indent: Int
    let isBlank: Bool
    let isComment: Bool

    static func make(_ text: String) -> [YAMLLine] {
        let bytes = Array(text.utf8)
        var result: [YAMLLine] = []
        var start = 0
        for index in bytes.indices where bytes[index] == 0x0A {
            append(bytes: bytes, start: start, end: index, into: &result)
            start = index + 1
        }
        if start < bytes.count || bytes.isEmpty { append(bytes: bytes, start: start, end: bytes.count, into: &result) }
        return result
    }

    private static func append(bytes: [UInt8], start: Int, end: Int, into result: inout [YAMLLine]) {
        var contentEnd = end
        if contentEnd > start, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
        let content = Array(bytes[start..<contentEnd])
        var indent = 0
        while indent < content.count, content[indent] == 0x20 { indent += 1 }
        var first = indent
        while first < content.count, content[first] == 0x09 { first += 1 }
        let isBlank = first == content.count
        let isComment = !isBlank && content[first] == 0x23
        result.append(YAMLLine(start: start, content: content, indent: indent, isBlank: isBlank, isComment: isComment))
    }
}
