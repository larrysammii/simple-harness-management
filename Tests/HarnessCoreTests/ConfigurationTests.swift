import Foundation
import XCTest
@testable import HarnessCore

final class ConfigurationTests: XCTestCase {
    func testJSONCCommentsTrailingCommasUnicodeAndNumbersArePreserved() throws {
        let text = "// Keep this comment\n{\"mcpServers\":{\"remove\":{\"command\":\"x\"},\"保留\":{\"command\":\"y\"},},\"large\":900719925474099312345,\"decimal\":0.12345678901234567890,}\n"
        let result = try Configuration.removing(text, format: .jsonc, path: [.key("mcpServers"), .key("remove")])
        XCTAssertTrue(result.hasPrefix("// Keep this comment\n"))
        XCTAssertTrue(result.contains("900719925474099312345")); XCTAssertTrue(result.contains("0.12345678901234567890"))
        let parsed = try Configuration.parse(result, format: .jsonc)
        XCTAssertNil(parsed["mcpServers"]?["remove"]); XCTAssertNotNil(parsed["mcpServers"]?["保留"])
    }
    func testJSONDeletionAtEveryObjectAndArrayPosition() throws {
        for index in 0..<4 {
            let object = "{\"servers\":{\"a\":1,\"b\":2,\"c\":3,\"d\":4},\"packages\":[\"a\",\"b\",\"c\",\"d\"]}"
            let keys = ["a", "b", "c", "d"]
            let edited = try Configuration.removing(object, format: .json, path: [.key("servers"), .key(keys[index])])
            XCTAssertNil(try Configuration.parse(edited, format: .json)["servers"]?[keys[index]])
            let array = try Configuration.removing(object, format: .json, path: [.key("packages"), .index(index)])
            XCTAssertEqual(try Configuration.parse(array, format: .json)["packages"]?.strings, keys.enumerated().filter { $0.offset != index }.map(\.element))
        }
    }
    func testLastJSONEntryLeavesEmptyParent() throws {
        let result = try Configuration.removing("{\"mcpServers\":{\"only\":{\"command\":\"x\"}}}", format: .json, path: [.key("mcpServers"), .key("only")])
        XCTAssertEqual(try Configuration.parse(result, format: .json)["mcpServers"], .object([:]))
    }
    func testStrictJSONRejectsCommentsTrailingCommasDuplicatesAndBadEscapes() {
        for text in ["{/* no */}", "{\"a\":1,}", "{\"a\":1,\"a\":2}", "{\"a\":\"\\x\"}", "[]", "{\"a\":01}", "{\"a\":1e}"] {
            XCTAssertThrowsError(try Configuration.parse(text, format: .json))
        }
    }
    func testInvalidAndRootDeletionPathsAreRefused() {
        let text = "{\"mcpServers\":{\"one\":{\"command\":\"x\"}}}"
        for path: [PathKey] in [[], [.key("mcpServers")], [.key("mcpServers"), .key("absent")], [.key("constructor"), .key("one")], [.key("mcpServers"), .index(-1)]] {
            XCTAssertThrowsError(try Configuration.removing(text, format: .json, path: path))
        }
    }
    func testQuotedTOMLTablesAndNestedSettings() throws {
        let text = "# Kept\nmodel = \"example\"\n[mcp_servers.\"a.b\"]\ncommand = \"x\"\n[mcp_servers.\"a.b\".env]\nTOKEN = \"synthetic-secret\"\n[mcp_servers.keep]\nurl = \"https://example.invalid\"\n"
        let result = try Configuration.removing(text, format: .toml, path: [.key("mcp_servers"), .key("a.b")])
        XCTAssertTrue(result.contains("# Kept")); XCTAssertTrue(result.contains("model = \"example\""))
        let parsed = try Configuration.parse(result, format: .toml)
        XCTAssertNil(parsed["mcp_servers"]?["a.b"]); XCTAssertNotNil(parsed["mcp_servers"]?["keep"])
    }
    func testLastTOMLServerRetainsImplicitParentAndOtherTypedValues() throws {
        let text = "day = 2026-11-13\nratio = inf\nflag = true\n[mcp_servers.only]\ncommand = \"x\"\n"
        let before = try Configuration.parse(text, format: .toml)
        let result = try Configuration.removing(text, format: .toml, path: [.key("mcp_servers"), .key("only")])
        let after = try Configuration.parse(result, format: .toml)
        XCTAssertEqual(after["mcp_servers"], .object([:])); XCTAssertEqual(after["day"], before["day"])
        XCTAssertEqual(after["ratio"], before["ratio"]); XCTAssertEqual(after["flag"], before["flag"])
    }
    func testTOMLMultilineStringsDoNotBecomeTableBoundaries() throws {
        let text = "[mcp_servers.one]\ncommand = \"x\"\nnote = '''\n[mcp_servers.fake]\nnot a table\n'''\n[mcp_servers.keep]\ncommand=\"y\"\n"
        let result = try Configuration.removing(text, format: .toml, path: [.key("mcp_servers"), .key("one")])
        XCTAssertNil(try Configuration.parse(result, format: .toml)["mcp_servers"]?["one"])
        XCTAssertNotNil(try Configuration.parse(result, format: .toml)["mcp_servers"]?["keep"])
    }
    func testInlineTOMLIsReadableButRefusesUnsafeEdit() throws {
        let text = "mcp_servers = {one = {command = \"x\"}, keep = {command = \"y\"}}\n"
        XCTAssertNotNil(try Configuration.parse(text, format: .toml)["mcp_servers"]?["one"])
        XCTAssertThrowsError(try Configuration.removing(text, format: .toml, path: [.key("mcp_servers"), .key("one")]))
    }
    func testYAMLMappingAndSequenceEditsPreserveCommentsAndTypedValues() throws {
        let text = "# Keep comment\nname: synthetic\nflag: true\nmcpServers:\n  - name: one\n    command: x\n  - name: keep\n    command: y\n"
        let result = try Configuration.removing(text, format: .yaml, path: [.key("mcpServers"), .index(0)])
        XCTAssertTrue(result.contains("# Keep comment")); XCTAssertTrue(result.contains("name: keep"))
        let parsed = try Configuration.parse(result, format: .yaml)
        XCTAssertEqual(parsed["flag"], .bool(true)); XCTAssertEqual(parsed["mcpServers"]?.array?.count, 1)
    }
    func testLastYAMLMemberLeavesEmptyContainerNotNull() throws {
        for (text, key, expected) in [("mcpServers:\n  only:\n    command: x\n", PathKey.key("only"), ConfigValue.object([:])),
                                      ("mcpServers:\n  - name: only\n    command: x\n", PathKey.index(0), ConfigValue.array([]))] {
            let result = try Configuration.removing(text, format: .yaml, path: [.key("mcpServers"), key])
            XCTAssertEqual(try Configuration.parse(result, format: .yaml)["mcpServers"], expected)
        }
    }
    func testDuplicateYAMLKeysAndExcessiveNestingAreRefused() {
        XCTAssertThrowsError(try Configuration.parse("a: 1\na: 2\n", format: .yaml))
        let deep = "{\"x\":" + String(repeating: "[", count: 150) + "0" + String(repeating: "]", count: 150) + "}"
        XCTAssertThrowsError(try Configuration.parse(deep, format: .json))
    }
    func testFlowYAMLIsReadableButNotEdited() throws {
        let text = "mcpServers: {one: {command: x}, keep: {command: y}}\n"
        XCTAssertNotNil(try Configuration.parse(text, format: .yaml)["mcpServers"]?["one"])
        XCTAssertThrowsError(try Configuration.removing(text, format: .yaml, path: [.key("mcpServers"), .key("one")]))
    }
}
