#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore

    final class CLIClientSecurityTests: XCTestCase {
        func testRejectsInvalidUTF8AndMultipleOrNonObjectJSONValues() async throws {
            let root = try makeSecurityTestDirectory("cli-protocol")
            defer { try? FileManager.default.removeItem(at: root) }

            let invalidUTF8 = root.appendingPathComponent("invalid-utf8")
            try writeExecutable("printf '\\377'", to: invalidUTF8)
            await assertProtocolError(
                executable: invalidUTF8,
                arguments: ["providers"],
                expected: .invalidUTF8(.stdout)
            )

            let multiple = root.appendingPathComponent("multiple-json")
            try writeExecutable("printf '%s\\n%s\\n' '{\"providers\":[]}' '{\"extra\":true}'", to: multiple)
            await assertProtocolError(
                executable: multiple,
                arguments: ["providers"],
                expected: .invalidJSON
            )

            let array = root.appendingPathComponent("array-json")
            try writeExecutable("printf '[]\\n'", to: array)
            await assertProtocolError(
                executable: array,
                arguments: ["providers"],
                expected: .topLevelNotObject
            )
        }

        func testTimeoutTerminatesHungProcess() async throws {
            let root = try makeSecurityTestDirectory("cli-timeout")
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("hang")
            try writeExecutable("exec /bin/sleep 10", to: executable)
            let client = OpenScienceCLIClient(timeout: 0.1)

            do {
                _ = try await client.execute(
                    CLIInvocation(
                        executableURL: executable,
                        arguments: ["providers"],
                        workingDirectory: root
                    ))
                XCTFail("Expected timeout")
            } catch let error as CLIProtocolError {
                guard case .timedOut = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }

        func testExitCodeMustMatchTypedCommandShape() async throws {
            let root = try makeSecurityTestDirectory("cli-shape")
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("wrong-run")
            try writeExecutable(
                "printf '{\"run_id\":\"r\",\"run_directory\":\"/tmp/r\",\"status\":\"partial\",\"sources\":1,\"evidence\":1,\"claims\":1,\"limitations\":[]}\\n'",
                to: executable
            )

            do {
                _ = try await OpenScienceCLIClient().execute(
                    CLIInvocation(
                        executableURL: executable,
                        arguments: ["run"],
                        workingDirectory: root
                    ))
                XCTFail("Expected exit/status mismatch")
            } catch let error as CLIProtocolError {
                guard case .responseShape = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }

        func testExitOneAcceptsRecordedFailedAndCancelledRunOutcomes() async throws {
            let root = try makeSecurityTestDirectory("cli-terminal-outcomes")
            defer { try? FileManager.default.removeItem(at: root) }

            for status in ["failed", "cancelled"] {
                let executable = root.appendingPathComponent(status)
                try writeExecutable(
                    "printf '{\"run_id\":\"run-1\",\"run_directory\":\"/tmp/run-1\",\"status\":\"\(status)\",\"sources\":0,\"evidence\":0,\"claims\":0,\"limitations\":[]}\\n'; exit 1",
                    to: executable
                )
                let result = try await OpenScienceCLIClient().execute(
                    CLIInvocation(
                        executableURL: executable,
                        arguments: ["run"],
                        workingDirectory: root
                    ))
                XCTAssertEqual(result.exitCode, 1)
                XCTAssertEqual(
                    try CLIResponseDecoder.decode(RunOutcome.self, from: result.stdout).status,
                    status
                )
            }
        }

        func testDefaultsAndEnvironmentAreBoundedAndMinimal() {
            let client = OpenScienceCLIClient()
            XCTAssertEqual(client.stdoutLimitForTesting, 1_024 * 1_024)
            XCTAssertEqual(client.stderrLimitForTesting, 256 * 1_024)

            let environment = CLIEnvironmentBuilder.sanitized(
                host: [
                    "PATH": "/attacker", "HOME": "/Users/test", "TMPDIR": "/tmp",
                    "LANG": "en_US.UTF-8", "LC_ALL": "C", "DYLD_INSERT_LIBRARIES": "/tmp/a.dylib",
                    "AWS_SECRET_ACCESS_KEY": "secret",
                ],
                explicit: [
                    "OPENSCIENCE_MODEL_API_KEY": "allowed",
                    "DYLD_LIBRARY_PATH": "/tmp/evil",
                ]
            )

            XCTAssertNil(environment["PATH"])
            XCTAssertEqual(environment["HOME"], "/Users/test")
            XCTAssertEqual(environment["OPENSCIENCE_MODEL_API_KEY"], "allowed")
            XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
            XCTAssertNil(environment["DYLD_LIBRARY_PATH"])
            XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
        }

        private func assertProtocolError(
            executable: URL,
            arguments: [String],
            expected: CLIProtocolError
        ) async {
            do {
                _ = try await OpenScienceCLIClient().execute(
                    CLIInvocation(
                        executableURL: executable,
                        arguments: arguments,
                        workingDirectory: executable.deletingLastPathComponent()
                    ))
                XCTFail("Expected protocol error")
            } catch let error as CLIProtocolError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }
#endif
