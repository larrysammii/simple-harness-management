// Executes the existing XCTest-shaped methods using a native assertion adapter when
// only Command Line Tools are installed. Generated copies live outside the repository.
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default
let temporary = fm.temporaryDirectory.appendingPathComponent("harness-native-checks-" + UUID().uuidString)
try fm.createDirectory(at: temporary.appendingPathComponent("Sources/PortableAssertions"), withIntermediateDirectories: true)
try fm.createDirectory(at: temporary.appendingPathComponent("Sources/ChecksRunner"), withIntermediateDirectories: true)
defer { try? fm.removeItem(at: temporary) }
let manifest = """
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NativeChecks", platforms: [.macOS("14.4")], dependencies: [.package(path: \(String(reflecting: root.path)))], targets: [
    .target(name: "PortableAssertions"),
    .executableTarget(name: "ChecksRunner", dependencies: ["PortableAssertions", .product(name: "HarnessCore", package: \(String(reflecting: root.lastPathComponent.lowercased())))])
])
"""
try manifest.write(to: temporary.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
try fm.copyItem(at: root.appendingPathComponent("Validation/PortableAssertions.swift"), to: temporary.appendingPathComponent("Sources/PortableAssertions/Assertions.swift"))
let target = temporary.appendingPathComponent("Sources/ChecksRunner")
try fm.copyItem(at: root.appendingPathComponent("Sources/HarnessManager/AppModel.swift"), to: target.appendingPathComponent("AppModel.swift"))
var invocations: [String] = []
let classPattern = try NSRegularExpression(pattern: #"final class (\w+): XCTestCase"#)
let methodPattern = try NSRegularExpression(pattern: #"func\s+(test\w+)\s*\(\)\s*(async\s*)?(throws\s*)?\{"#)
for directory in ["Tests/HarnessCoreTests", "Tests/HarnessUITests"] {
    let files = try fm.contentsOfDirectory(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)
    for file in files.filter({ $0.pathExtension == "swift" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        var source = try String(contentsOf: file, encoding: .utf8)
        let original = source as NSString
        guard let typeMatch = classPattern.firstMatch(in: source, range: NSRange(location: 0, length: original.length)) else { continue }
        let suite = original.substring(with: typeMatch.range(at: 1))
        let methods = methodPattern.matches(in: source, range: NSRange(location: 0, length: original.length))
        for method in methods {
            let name = original.substring(with: method.range(at: 1))
            let async = method.range(at: 2).location != NSNotFound
            let throwing = method.range(at: 3).location != NSNotFound
            invocations.append("await run(\"\(suite).\(name)\") { \(throwing ? "try " : "")\(async ? "await " : "")\(suite)().\(name)() }")
        }
        source = source.replacingOccurrences(of: "import XCTest", with: "import PortableAssertions")
            .replacingOccurrences(of: "@testable import HarnessManager", with: "")
            .replacingOccurrences(of: ": XCTestCase {", with: ": XCTestCase, @unchecked Sendable {")
        try source.write(to: target.appendingPathComponent(file.lastPathComponent), atomically: true, encoding: .utf8)
    }
}
guard !invocations.isEmpty else { fatalError("No native checks were found") }
let main = """
import Foundation
import PortableAssertions
@main struct NativeCheckRunner {
    @MainActor static func main() async {
        var passed = 0
        func run(_ name: String, _ body: @MainActor () async throws -> Void) async {
            let before = CheckReport.shared.count
            do { try await body() }
            catch is UnwrapFailure { }
            catch { XCTFail("\\(name): \\(error)") }
            if CheckReport.shared.count == before { passed += 1; print("PASS " + name) }
        }
        \(invocations.joined(separator: "\n        "))
        print("Native checks: \\(passed)/\(invocations.count) passed · \\(CheckReport.shared.count) assertion failures")
        if CheckReport.shared.count > 0 { exit(1) }
    }
}
"""
try main.write(to: target.appendingPathComponent("CheckRunner.swift"), atomically: true, encoding: .utf8)
print("Command Line Tools: running \(invocations.count) native checks with the portable assertion adapter")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["swift", "run", "--package-path", temporary.path, "--scratch-path", root.appendingPathComponent(".build/portable-checks").path, "--skip-update", "ChecksRunner"]
process.standardOutput = FileHandle.standardOutput; process.standardError = FileHandle.standardError
try process.run(); process.waitUntilExit()
exit(process.terminationStatus)
