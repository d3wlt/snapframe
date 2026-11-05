import AppKit
import SnapframeCore

// Minimal test harness. Each feature area owns one file defining `SelfTests.<area>`;
// add cases there, not here. Run: `swift run SnapframeSelfTest [filter]`.

struct TestCase {
    let name: String
    let body: @MainActor () async throws -> Void
    init(_ name: String, _ body: @escaping @MainActor () async throws -> Void) {
        self.name = name
        self.body = body
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

/// Throws (failing the current test) when the condition is false.
func check(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
           file: StaticString = #fileID, line: UInt = #line) throws {
    if try !condition() { throw CheckFailure(description: "\(file):\(line) \(message())") }
}

func checkEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #fileID, line: UInt = #line) throws {
    if a != b { throw CheckFailure(description: "\(file):\(line) expected \(b), got \(a)") }
}

enum SelfTests {}

/// Isolated defaults + history dir so tests never touch the user's real settings or files.
@MainActor func useScratchEnvironment() {
    let suite = "snapframe.selftest.\(UUID().uuidString)"
    Prefs.store = UserDefaults(suiteName: suite)!
    Prefs.register()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snapframe-selftest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    HistoryStore.directory = dir
}

@MainActor func runAll() async -> Int32 {
    let filter = CommandLine.arguments.dropFirst().first
    let all = SelfTests.output + SelfTests.capture + SelfTests.quickAccess + SelfTests.annotate
        + SelfTests.recording + SelfTests.settings + SelfTests.update
    var failed = 0, ran = 0
    for test in all where filter == nil || test.name.localizedCaseInsensitiveContains(filter!) {
        ran += 1
        useScratchEnvironment()
        do {
            try await test.body()
            print("PASS  \(test.name)")
        } catch {
            failed += 1
            print("FAIL  \(test.name): \(error)")
        }
    }
    print("\n\(ran - failed)/\(ran) passed")
    return failed == 0 ? 0 : 1
}

_ = NSApplication.shared
let code = await MainActor.run { Task { await runAll() } }.value
exit(code)
