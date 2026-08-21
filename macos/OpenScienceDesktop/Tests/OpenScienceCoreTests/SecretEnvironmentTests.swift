#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore

    final class SecretEnvironmentTests: XCTestCase {
        func testInvocationCopiesShareConsumeOnceEnvironmentAndClearAfterSpawn() async throws {
            let root = try makeSecurityTestDirectory("secret-consume")
            defer { try? FileManager.default.removeItem(at: root) }
            let marker = root.appendingPathComponent("spawned")
            let executable = root.appendingPathComponent("provider")
            try writeExecutable(
                "test -n \"$OPENSCIENCE_MODEL_API_KEY\"; : > '\(marker.path)'; /bin/sleep 0.3; printf '{\"providers\":[]}\\n'",
                to: executable
            )
            let secret = "consume-once-secret"
            let invocation = CLIInvocation(
                executableURL: executable,
                arguments: ["providers"],
                environment: ["OPENSCIENCE_MODEL_API_KEY": secret],
                workingDirectory: root,
                timeout: 2
            )
            let retainedCopy = invocation
            XCTAssertEqual(retainedCopy.environment["OPENSCIENCE_MODEL_API_KEY"], secret)

            let task = Task { try await OpenScienceCLIClient().execute(invocation) }
            for _ in 0..<40 where !FileManager.default.fileExists(atPath: marker.path) {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertTrue(invocation.environment.isEmpty)
            XCTAssertTrue(retainedCopy.environment.isEmpty)

            let result = try await task.value
            XCTAssertFalse(result.stdout.contains(secret))
            XCTAssertTrue(invocation.environment.isEmpty)
        }
    }
#endif
