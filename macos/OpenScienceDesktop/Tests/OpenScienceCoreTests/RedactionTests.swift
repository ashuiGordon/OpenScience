#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore

    private final class ThreadSafeStrings: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ value: String) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }
        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    final class RedactionTests: XCTestCase {
        func testRedactsKnownSecretsAssignmentsAndBearerTokens() {
            let secret = "sk-super-secret"
            let input = "api_key=visible authorization: Bearer abc.def OPENSCIENCE_MODEL_API_KEY=\(secret)"
            let output = Redactor.redact(input, secrets: [secret])
            XCTAssertFalse(output.contains(secret))
            XCTAssertFalse(output.contains("abc.def"))
            XCTAssertFalse(output.contains("visible"))
            XCTAssertTrue(output.contains("[REDACTED]"))
        }

        func testClientRedactsCallbackResultAndFailure() async throws {
            let secret = "very-private-token"
            let output = ThreadSafeStrings()
            let root = try makeSecurityTestDirectory("redaction-client")
            defer { try? FileManager.default.removeItem(at: root) }
            let successExecutable = root.appendingPathComponent("success")
            try writeExecutable(
                "printf '{\"message\":\"%s\"}\\n' \"$OPENSCIENCE_MODEL_API_KEY\"",
                to: successExecutable
            )
            let success = CLIInvocation(
                executableURL: successExecutable,
                arguments: ["custom"],
                environment: ["OPENSCIENCE_MODEL_API_KEY": secret],
                workingDirectory: root
            )
            let client = OpenScienceCLIClient()
            let result = try await client.execute(success) { _, text in output.append(text) }
            XCTAssertFalse(result.stdout.contains(secret))
            XCTAssertFalse(output.values.joined().contains(secret))

            let failureExecutable = root.appendingPathComponent("failure")
            try writeExecutable(
                "printf '{\"error\":{\"code\":\"bad\",\"message\":\"%s\"}}\\n' \"$OPENSCIENCE_MODEL_API_KEY\"; exit 2",
                to: failureExecutable
            )
            let failure = CLIInvocation(
                executableURL: failureExecutable,
                arguments: ["custom"],
                environment: ["OPENSCIENCE_MODEL_API_KEY": secret],
                workingDirectory: root
            )
            do {
                _ = try await client.execute(failure)
                XCTFail("Expected failure")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains(secret))
            }
        }

        func testNonzeroTypedJSONIsReturnedForCommandSpecificInterpretation() async throws {
            let root = try makeSecurityTestDirectory("validation-result")
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("validate")
            try writeExecutable(
                "printf '{\"valid\":false,\"errors\":[\"broken\"],\"warnings\":[]}\\n'; exit 1",
                to: executable
            )
            let invocation = CLIInvocation(
                executableURL: executable,
                arguments: ["validate"],
                workingDirectory: root
            )
            let result = try await OpenScienceCLIClient().execute(invocation)
            XCTAssertEqual(result.exitCode, 1)
            XCTAssertFalse(try CLIResponseDecoder.decode(ValidationReport.self, from: result.stdout).valid)
        }

        func testClientEnforcesOutputLimit() async throws {
            let invocation = CLIInvocation(
                executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: [String(repeating: "x", count: 128)],
                workingDirectory: URL(fileURLWithPath: "/tmp")
            )
            let client = OpenScienceCLIClient(stdoutLimit: 32, stderrLimit: 32)
            do {
                _ = try await client.execute(invocation)
                XCTFail("Expected output limit failure")
            } catch let error as CLIOutputLimitExceeded {
                XCTAssertEqual(error.stream, .stdout)
                XCTAssertEqual(error.limit, 32)
            }
        }
    }
#endif
