#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore

    final class CLICommandTests: XCTestCase {
        private let configuration = ClientConfiguration(
            cliExecutable: URL(fileURLWithPath: "/usr/local/bin/openscience"),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            runRoot: URL(fileURLWithPath: "/tmp/runs"),
            modelConfig: URL(fileURLWithPath: "/tmp/model.json")
        )

        func testPlanWritesReviewablePlanWithoutImplicitApproval() throws {
            var draft = ResearchDraft()
            draft.question = "--help; study evidence"
            draft.sourceNames = ["openalex"]
            let invocation = try CLICommandBuilder.plan(
                draft: draft,
                configuration: configuration,
                output: URL(fileURLWithPath: "/tmp/job/reviewed-plan.json"),
                jobWorkspace: URL(fileURLWithPath: "/tmp/job")
            )
            XCTAssertEqual(invocation.arguments.first, "plan")
            XCTAssertTrue(invocation.arguments.contains("--output"))
            XCTAssertFalse(invocation.arguments.contains("--yes"))
            XCTAssertEqual(Array(invocation.arguments.suffix(2)), ["--", "--help; study evidence"])
            XCTAssertEqual(invocation.workingDirectory.path, "/tmp/job")
        }

        func testRunUsesReviewedPlanAndOnlyRequiredCredential() throws {
            var draft = ResearchDraft()
            draft.question = "--help; rm -rf /"
            draft.sourceNames = ["openalex"]
            draft.allowNetwork = true
            let invocation = try CLICommandBuilder.run(
                draft: draft,
                configuration: configuration,
                credentials: CredentialSet(
                    modelAPIKey: "model-secret",
                    openAlexAPIKey: "oa-secret",
                    crossrefAPIKey: "cr-secret"
                ),
                jobWorkspace: URL(fileURLWithPath: "/tmp/jobs/one/runs"),
                reviewedPlan: URL(fileURLWithPath: "/tmp/jobs/one/runs/reviewed-plan.json")
            )

            XCTAssertEqual(invocation.executableURL.path, "/usr/local/bin/openscience")
            XCTAssertEqual(Array(invocation.arguments.suffix(2)), ["--", "--help; rm -rf /"])
            XCTAssertTrue(invocation.arguments.contains("--plan"))
            XCTAssertEqual(invocation.workingDirectory.path, "/tmp/jobs/one/runs")
            XCTAssertFalse(invocation.arguments.contains("oa-secret"))
            XCTAssertEqual(invocation.environment["OPENSCIENCE_OPENALEX_API_KEY"], "oa-secret")
            XCTAssertNil(invocation.environment["OPENSCIENCE_MODEL_API_KEY"])
            XCTAssertNil(invocation.environment["OPENSCIENCE_CROSSREF_API_KEY"])
        }

        func testNetworkModelAndCrossrefReceiveOnlyTheirCredentials() throws {
            var draft = ResearchDraft()
            draft.question = "question"
            draft.sourceNames = ["crossref"]
            draft.allowNetwork = true
            draft.useNetworkModel = true
            let invocation = try CLICommandBuilder.run(
                draft: draft,
                configuration: configuration,
                credentials: CredentialSet(
                    modelAPIKey: "model-secret",
                    openAlexAPIKey: "oa-secret",
                    crossrefAPIKey: "cr-secret"
                ),
                jobWorkspace: URL(fileURLWithPath: "/tmp/job"),
                reviewedPlan: URL(fileURLWithPath: "/tmp/job/plan.json")
            )
            XCTAssertEqual(invocation.environment["OPENSCIENCE_MODEL_API_KEY"], "model-secret")
            XCTAssertEqual(invocation.environment["OPENSCIENCE_CROSSREF_API_KEY"], "cr-secret")
            XCTAssertNil(invocation.environment["OPENSCIENCE_OPENALEX_API_KEY"])
            XCTAssertTrue(invocation.arguments.contains("--model-config"))
            XCTAssertTrue(invocation.arguments.contains("/tmp/model.json"))
        }

        func testReviewedInlineModelValuesOverrideFilePathWithoutPassingItToChild() throws {
            let inlineConfiguration = ClientConfiguration(
                cliExecutable: URL(fileURLWithPath: "/usr/local/bin/openscience"),
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                runRoot: URL(fileURLWithPath: "/tmp/runs"),
                modelConfig: URL(fileURLWithPath: "/tmp/mutable-model.json"),
                reviewedModelEndpoint: "https://models.example.test/v1/responses",
                reviewedModelName: "reviewed-research-model",
                reviewedModelTimeout: 12.5
            )
            var draft = ResearchDraft()
            draft.question = "What reviewed model configuration is used?"
            draft.sourceNames = ["crossref"]
            draft.allowNetwork = true
            draft.useNetworkModel = true

            let invocation = try CLICommandBuilder.run(
                draft: draft,
                configuration: inlineConfiguration,
                credentials: CredentialSet(modelAPIKey: "model-secret"),
                jobWorkspace: URL(fileURLWithPath: "/tmp/job"),
                reviewedPlan: URL(fileURLWithPath: "/tmp/job/plan.json")
            )

            XCTAssertFalse(invocation.arguments.contains("--model-config"))
            XCTAssertFalse(invocation.arguments.contains("/tmp/mutable-model.json"))
            XCTAssertEqual(
                option("--model-endpoint", in: invocation.arguments),
                "https://models.example.test/v1/responses")
            XCTAssertEqual(option("--model-name", in: invocation.arguments), "reviewed-research-model")
            XCTAssertEqual(option("--model-timeout", in: invocation.arguments), "12.5")
        }

        func testIncompleteReviewedInlineModelDoesNotFallBackToMutableFile() {
            let incomplete = ClientConfiguration(
                cliExecutable: URL(fileURLWithPath: "/usr/local/bin/openscience"),
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                runRoot: URL(fileURLWithPath: "/tmp/runs"),
                modelConfig: URL(fileURLWithPath: "/tmp/model.json"),
                reviewedModelEndpoint: "https://models.example.test",
                reviewedModelName: nil,
                reviewedModelTimeout: 30
            )
            var draft = ResearchDraft()
            draft.question = "What configuration is incomplete?"
            draft.sourceNames = ["crossref"]
            draft.useNetworkModel = true

            XCTAssertThrowsError(
                try CLICommandBuilder.run(
                    draft: draft,
                    configuration: incomplete,
                    credentials: CredentialSet(modelAPIKey: "secret"),
                    jobWorkspace: URL(fileURLWithPath: "/tmp/job"),
                    reviewedPlan: URL(fileURLWithPath: "/tmp/job/plan.json")
                )
            ) { error in
                XCTAssertEqual(error as? CLICommandError, .invalidReviewedModelConfiguration)
            }
        }

        func testLocalEvidenceCannotUseNetworkModel() {
            var draft = ResearchDraft()
            draft.question = "question"
            draft.localRoots = [URL(fileURLWithPath: "/tmp/private")]
            draft.useNetworkModel = true
            XCTAssertThrowsError(
                try CLICommandBuilder.run(
                    draft: draft,
                    configuration: configuration,
                    credentials: CredentialSet(modelAPIKey: "secret"),
                    jobWorkspace: URL(fileURLWithPath: "/tmp/job"),
                    reviewedPlan: URL(fileURLWithPath: "/tmp/job/plan.json")
                )
            ) { error in
                XCTAssertEqual(error as? CLICommandError, .localEvidenceWithNetworkModel)
            }
        }

        func testEnvironmentUsesMinimalAllowlist() {
            let environment = CLIEnvironmentBuilder.sanitized(
                host: [
                    "PATH": "/bin", "HOME": "/Users/test", "LANG": "en_US.UTF-8", "LC_ALL": "C",
                    "AWS_SECRET_ACCESS_KEY": "must-not-pass", "GITHUB_TOKEN": "must-not-pass",
                ],
                explicit: ["OPENSCIENCE_MODEL_API_KEY": "allowed-secret"]
            )
            XCTAssertNil(environment["PATH"])
            XCTAssertEqual(environment["LC_ALL"], "C")
            XCTAssertEqual(environment["OPENSCIENCE_MODEL_API_KEY"], "allowed-secret")
            XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
            XCTAssertNil(environment["GITHUB_TOKEN"])
        }

        private func option(_ name: String, in arguments: [String]) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }
    }
#endif
