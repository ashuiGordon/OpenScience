#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore
    @testable import OpenScienceDesktopLogic

    final class FixtureResumeIntegrationTests: XCTestCase {
        func testPartialFixtureRunCanBePreflightedAndResumedAfterRelaunch() async throws {
            let environment = ProcessInfo.processInfo.environment
            guard let cliPath = environment["OPENSCIENCE_E2E_CLI"],
                let fixturePath = environment["OPENSCIENCE_E2E_FIXTURE"]
            else {
                throw XCTSkip("Set OPENSCIENCE_E2E_CLI and OPENSCIENCE_E2E_FIXTURE")
            }
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("openscience-fixture-resume-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let cli = URL(fileURLWithPath: cliPath)
            let fixture = URL(fileURLWithPath: fixturePath)
            let configuration = ClientConfiguration(
                cliExecutable: cli,
                workingDirectory: root,
                runRoot: root
            )
            let client = OpenScienceCLIClient(timeout: 30)
            let question = "What fixture evidence supports reproducibility?"
            let plan = root.appendingPathComponent("plan.json")
            _ = try await client.execute(
                CLIInvocation(
                    executableURL: cli,
                    arguments: ["plan", "--output", plan.path, "--json", "--", question],
                    workingDirectory: root
                )
            )
            let partial = try await client.execute(
                CLIInvocation(
                    executableURL: cli,
                    arguments: [
                        "run", "--fixture", fixture.path, "--workspace", root.path,
                        "--plan", plan.path, "--stop-after-step", "extract", "--yes", "--json",
                        "--", question,
                    ],
                    workingDirectory: root
                )
            )
            let partialOutcome = try CLIResponseDecoder.decode(RunOutcome.self, from: partial.stdout)
            XCTAssertEqual(partialOutcome.status, "partial")

            // Simulate a fresh app process: reconstruct only from the durable run and registry probes.
            let item = try XCTUnwrap(
                RunScanner().scan(root: root).first { $0.runID == partialOutcome.runID }
            )
            let detail = try RunRepository(root: root).load(item)
            let context = try ResumeReviewContext.parse(
                manifest: detail.manifest,
                runDirectory: item.directory
            )
            let baseResult = try await client.execute(
                CLICommandBuilder.providers(configuration: configuration)
            )
            let base = try CLIResponseDecoder.decode(ProvidersEnvelope.self, from: baseResult.stdout)
            XCTAssertFalse(
                context.providerPreflight(
                    available: base.providers.map {
                        ProviderIdentity(name: $0.name, version: $0.version ?? "", available: $0.available)
                    }
                ).valid
            )
            let fixtureResult = try await client.execute(
                CLICommandBuilder.providers(configuration: configuration, fixtureFiles: [fixture])
            )
            let fixtureProviders = try CLIResponseDecoder.decode(
                ProvidersEnvelope.self,
                from: fixtureResult.stdout
            )
            XCTAssertTrue(
                context.providerPreflight(
                    available: fixtureProviders.providers.map {
                        ProviderIdentity(name: $0.name, version: $0.version ?? "", available: $0.available)
                    }
                ).valid
            )

            var resumeDraft = ResearchDraft()
            resumeDraft.question = context.question
            resumeDraft.sourceNames = context.sourceNames
            resumeDraft.fixtureFiles = [fixture]
            resumeDraft.timeoutSeconds = context.timeoutSeconds
            let resumed = try await client.execute(
                CLICommandBuilder.resume(
                    runDirectory: item.directory,
                    draft: resumeDraft,
                    configuration: configuration,
                    credentials: CredentialSet()
                )
            )
            XCTAssertEqual(
                try CLIResponseDecoder.decode(RunOutcome.self, from: resumed.stdout).status,
                "completed"
            )
        }
    }
#endif
