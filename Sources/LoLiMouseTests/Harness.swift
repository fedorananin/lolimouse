// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation

/// A minimal test harness.
///
/// XCTest and swift-testing both ship inside Xcode, and LoLiMouse is built to
/// need nothing but the Command Line Tools. Rather than making a full Xcode
/// install a prerequisite for running the tests, the suite is an ordinary
/// executable and this is the handful of assertions it needs.
enum Harness {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var currentGroup = ""
}

func suite(_ name: String, _ body: () -> Void) {
    Harness.currentGroup = name
    print("\n\u{001B}[1m\(name)\u{001B}[0m")
    body()
}

func test(_ name: String, _ body: () -> Void) {
    let before = Harness.failures.count
    body()
    if Harness.failures.count == before {
        Harness.passed += 1
        print("  \u{001B}[32m✓\u{001B}[0m \(name)")
    } else {
        print("  \u{001B}[31m✗\u{001B}[0m \(name)")
        for failure in Harness.failures[before...] {
            print("      \(failure)")
        }
    }
}

func expect(
    _ condition: Bool,
    _ message: @autoclosure () -> String = "expectation failed",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard !condition else { return }
    Harness.failures.append("\(message()) (\(shortName(file)):\(line))")
}

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard actual != expected else { return }
    let note = message().isEmpty ? "" : " — \(message())"
    Harness.failures.append("expected \(expected), got \(actual)\(note) (\(shortName(file)):\(line))")
}

func expectClose(
    _ actual: Double,
    _ expected: Double,
    accuracy: Double = 0.0001,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard abs(actual - expected) > accuracy else { return }
    let note = message().isEmpty ? "" : " — \(message())"
    Harness.failures.append("expected \(expected) ± \(accuracy), got \(actual)\(note) "
        + "(\(shortName(file)):\(line))")
}

func expectNil<T>(
    _ value: T?,
    _ message: @autoclosure () -> String = "expected nil",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard value != nil else { return }
    Harness.failures.append("\(message()), got \(value!) (\(shortName(file)):\(line))")
}

func expectNotNil<T>(
    _ value: T?,
    _ message: @autoclosure () -> String = "expected a value",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard value == nil else { return }
    Harness.failures.append("\(message()), got nil (\(shortName(file)):\(line))")
}

private func shortName(_ file: StaticString) -> String {
    URL(fileURLWithPath: "\(file)").lastPathComponent
}

func report() -> Never {
    print("")
    if Harness.failures.isEmpty {
        print("\u{001B}[32m\(Harness.passed) tests passed\u{001B}[0m")
        exit(0)
    }
    print("\u{001B}[31m\(Harness.failures.count) failure(s), \(Harness.passed) passed\u{001B}[0m")
    exit(1)
}
