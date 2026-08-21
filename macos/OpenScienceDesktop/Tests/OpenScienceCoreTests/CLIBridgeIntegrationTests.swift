#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore

    /// Opt-in real bridge contract. CI sets both variables after installing the Python package.
    final class CLIBridgeIntegrationTests: XCTestCase {
        func testRealProvidersPlanRunInspectAndValidateContract() async throws {
            let environment = ProcessInfo.processInfo.environment
            guard let executablePath = environment["OPENSCIENCE_E2E_CLI"],
                let fixturePath = environment["OPENSCIENCE_E2E_FIXTURE"]
            else {
                throw XCTSkip("Set OPENSCIENCE_E2E_CLI and OPENSCIENCE_E2E_FIXTURE to enable")
            }

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("openscience-e2e-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let executable = URL(fileURLWithPath: executablePath)
            let fixture = URL(fileURLWithPath: fixturePath)
            let client = OpenScienceCLIClient()

            let providers = try await client.execute(
                CLIInvocation(
                    executableURL: executable,
                    arguments: ["providers", "--fixture", fixture.path, "--json"],
                    workingDirectory: root
                )
            )
            XCTAssertEqual(providers.exitCode, 0)
            XCTAssertNoThrow(try CLIResponseDecoder.decode(ProvidersEnvelope.self, from: providers.stdout))

            let planPath = root.appendingPathComponent("reviewed-plan.json")
            let plan = try await client.execute(
                CLIInvocation(
                    executableURL: executable,
                    arguments: [
                        "plan", "--output", planPath.path, "--workspace", root.path,
                        "--json", "--", "What evidence is in the fixture?",
                    ],
                    workingDirectory: root
                )
            )
            XCTAssertEqual(plan.exitCode, 0)
            XCTAssertNoThrow(try CLIResponseDecoder.decode(PlanEnvelope.self, from: plan.stdout))
            XCTAssertTrue(FileManager.default.fileExists(atPath: planPath.path))

            let run = try await client.execute(
                CLIInvocation(
                    executableURL: executable,
                    arguments: [
                        "run", "--fixture", fixture.path, "--workspace", root.path,
                        "--plan", planPath.path, "--yes", "--json", "--",
                        "What evidence is in the fixture?",
                    ],
                    workingDirectory: root
                )
            )
            XCTAssertTrue([Int32(0), Int32(4)].contains(run.exitCode))
            let outcome = try CLIResponseDecoder.decode(RunOutcome.self, from: run.stdout)
            let runDirectory = URL(fileURLWithPath: outcome.runDirectory, isDirectory: true)

            let inspect = try await client.execute(
                CLIInvocation(
                    executableURL: executable,
                    arguments: ["inspect", runDirectory.path, "--json"],
                    workingDirectory: root
                )
            )
            XCTAssertEqual(inspect.exitCode, 0)
            XCTAssertNotNil(try CLIResponseDecoder.decodeJSON(from: inspect.stdout)["summary"])

            let validate = try await client.execute(
                CLIInvocation(
                    executableURL: executable,
                    arguments: ["validate", runDirectory.path, "--json"],
                    workingDirectory: root
                )
            )
            XCTAssertEqual(validate.exitCode, 0)
            XCTAssertTrue(try CLIResponseDecoder.decode(ValidationReport.self, from: validate.stdout).valid)
        }
    }
#endif
