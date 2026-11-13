// The Command Line Tools omit Apple's XCTest framework. This small assertion adapter
// lets the *same* test methods run natively there; Xcode/CI still uses real XCTest.
import Foundation

public final class CheckReport: @unchecked Sendable {
    public static let shared = CheckReport()
    private let lock = NSLock()
    private var failures: [String] = []
    public var count: Int { lock.lock(); defer { lock.unlock() }; return failures.count }
    public func record(_ message: String, file: StaticString, line: UInt) {
        let location = (String(describing: file) as NSString).lastPathComponent
        let entry = "\(location):\(line): \(message)"
        lock.lock(); failures.append(entry); lock.unlock()
        print("FAIL " + entry)
    }
}
open class XCTestCase: @unchecked Sendable { public init() {} }
public struct UnwrapFailure: Error {}
public func XCTFail(_ message: String = "Assertion failed", file: StaticString = #filePath, line: UInt = #line) {
    CheckReport.shared.record(message, file: file, line: line)
}
public func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try !value() { XCTFail("Expected true. " + message(), file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error). " + message(), file: file, line: line) }
}
public func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() { XCTFail("Expected false. " + message(), file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error). " + message(), file: file, line: line) }
}
public func XCTAssertEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { let a = try left(), b = try right(); if a != b { XCTFail("Not equal: \(a) / \(b). " + message(), file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error). " + message(), file: file, line: line) }
}
public func XCTAssertNotEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try left() == right() { XCTFail("Expected different values. " + message(), file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
public func XCTAssertGreaterThan<T: Comparable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try left() <= right() { XCTFail("Expected a greater value. " + message(), file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
public func XCTAssertNil<T>(_ value: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() != nil { XCTFail("Expected nil. " + message(), file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
public func XCTAssertNotNil<T>(_ value: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() == nil { XCTFail("Expected a value. " + message(), file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
public func XCTUnwrap<T>(_ value: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    if let result = try value() { return result }
    XCTFail("Required value is missing. " + message(), file: file, line: line); throw UnwrapFailure()
}
public func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line, _ handler: (Error) -> Void = { _ in }) {
    do { _ = try value(); XCTFail("Expected refusal. " + message(), file: file, line: line) }
    catch { handler(error) }
}
