#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore
    @testable import OpenScienceDesktopLogic

    final class DesktopCoordinationTests: XCTestCase {
        func testNetworkGrantIsCapabilityBoundAndSingleUse() {
            var grant = OneTimeNetworkGrant()
            let scope = NetworkGrantScope(
                capabilityNames: ["openalex", "openai-compatible"],
                maxNetworkRequests: 10,
                timeoutSeconds: 300,
                includesLocalData: false
            )
            grant.approve(scope: scope)
            XCTAssertTrue(grant.isApproved)
            XCTAssertFalse(
                grant.consume(
                    scope: NetworkGrantScope(
                        capabilityNames: scope.capabilityNames,
                        maxNetworkRequests: 11,
                        timeoutSeconds: scope.timeoutSeconds,
                        includesLocalData: scope.includesLocalData
                    )
                )
            )
            XCTAssertFalse(grant.isApproved)
            grant.approve(scope: scope)
            XCTAssertTrue(grant.consume(scope: scope))
            XCTAssertFalse(grant.consume(scope: scope))
        }

        func testResumeReviewParsesSavedPlanAndExactRoots() throws {
            let manifest = try CLIResponseDecoder.decodeJSON(from: Self.partialManifest)
            let context = try ResumeReviewContext.parse(
                manifest: manifest,
                runDirectory: URL(fileURLWithPath: "/tmp/run-partial")
            )
            XCTAssertEqual(context.status, .partial)
            XCTAssertEqual(context.completedStepIDs, ["discover", "extract"])
            XCTAssertEqual(context.remainingStepIDs, ["synthesize", "validate", "report"])
            XCTAssertEqual(context.limitations, ["provider timed out"])
            XCTAssertTrue(context.requiresNetworkGrant)
            XCTAssertEqual(context.credentialRequirements, [.model])
            XCTAssertTrue(context.rootsMatch([URL(fileURLWithPath: "/tmp/papers")]))
            XCTAssertFalse(context.rootsMatch([URL(fileURLWithPath: "/tmp/other")]))
            XCTAssertTrue(context.canResumeStatus)
        }

        func testCompletedResumeIsDisabled() throws {
            let text = Self.partialManifest.replacingOccurrences(of: "\"partial\"", with: "\"completed\"")
                .replacingOccurrences(
                    of: "[\"discover\",\"extract\"]",
                    with: "[\"discover\",\"extract\",\"synthesize\",\"validate\",\"report\"]"
                )
            let context = try ResumeReviewContext.parse(
                manifest: CLIResponseDecoder.decodeJSON(from: text),
                runDirectory: URL(fileURLWithPath: "/tmp/run")
            )
            XCTAssertFalse(context.canResumeStatus)
        }

        func testCancelledResumeIsDisabledBecauseMarkerIsPersistent() throws {
            let text = Self.partialManifest.replacingOccurrences(of: "\"partial\"", with: "\"cancelled\"")
            let context = try ResumeReviewContext.parse(
                manifest: CLIResponseDecoder.decodeJSON(from: text),
                runDirectory: URL(fileURLWithPath: "/tmp/run")
            )
            XCTAssertFalse(context.canResumeStatus)
        }

        func testPartialFixtureResumeRequiresExactProviderVersion() throws {
            let manifest = Self.partialManifest.replacingOccurrences(
                of: "{\"kind\":\"source\",\"name\":\"openalex\",\"risk\":\"network_read\"}",
                with:
                    "{\"kind\":\"source\",\"name\":\"fixture-lab\",\"risk\":\"local_read\",\"version\":\"1.2.3\"}"
            ).replacingOccurrences(
                of: "\"source_names\":[\"openalex\"]", with: "\"source_names\":[\"fixture-lab\"]")
            let context = try ResumeReviewContext.parse(
                manifest: CLIResponseDecoder.decodeJSON(from: manifest),
                runDirectory: URL(fileURLWithPath: "/tmp/run")
            )
            XCTAssertFalse(context.providerPreflight(available: []).valid)
            XCTAssertFalse(
                context.providerPreflight(
                    available: [ProviderIdentity(name: "fixture-lab", version: "9.9.9", available: true)]
                ).valid
            )
            XCTAssertTrue(
                context.providerPreflight(
                    available: [ProviderIdentity(name: "fixture-lab", version: "1.2.3", available: true)]
                ).valid
            )
        }

        func testModelConfigHashAndDestinationInvalidateGrantAfterRewrite() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("openscience-model-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("model.json")
            try Data(#"{"endpoint":"https://model-a.example/v1","model":"alpha"}"#.utf8).write(to: file)
            let first = try ModelConfigInspector.inspect(file)
            let base = ClientConfiguration(
                cliExecutable: URL(fileURLWithPath: "/tmp/openscience"),
                workingDirectory: directory,
                runRoot: directory,
                modelConfig: file
            )
            let execution = ReviewedModelConfiguration.applying(first, to: base)
            XCTAssertNil(execution.modelConfig)
            var draft = ResearchDraft()
            draft.question = "Q"
            draft.sourceNames = ["openalex"]
            draft.allowNetwork = true
            draft.useNetworkModel = true
            let beforeRewrite = try CLICommandBuilder.run(
                draft: draft,
                configuration: execution,
                credentials: CredentialSet(),
                jobWorkspace: directory,
                reviewedPlan: directory.appendingPathComponent("plan.json")
            )
            XCTAssertTrue(beforeRewrite.arguments.contains("https://model-a.example/v1"))
            XCTAssertFalse(beforeRewrite.arguments.contains("--model-config"))
            let firstScope = NetworkGrantScope(
                capabilityNames: ["openai-compatible"],
                destinations: [first.origin],
                maxNetworkRequests: 10,
                timeoutSeconds: 300,
                includesLocalData: false,
                configurationSHA256: first.sha256
            )
            var grant = OneTimeNetworkGrant()
            grant.approve(scope: firstScope)
            try Data(#"{"endpoint":"https://model-b.example/v1","model":"beta"}"#.utf8).write(to: file)
            let second = try ModelConfigInspector.inspect(file)
            let afterRewrite = try CLICommandBuilder.run(
                draft: draft,
                configuration: execution,
                credentials: CredentialSet(),
                jobWorkspace: directory,
                reviewedPlan: directory.appendingPathComponent("plan.json")
            )
            XCTAssertEqual(afterRewrite.arguments, beforeRewrite.arguments)
            XCTAssertNotEqual(first.sha256, second.sha256, "pre-approval recheck must expire the plan")
            let changedScope = NetworkGrantScope(
                capabilityNames: ["openai-compatible"],
                destinations: [second.origin],
                maxNetworkRequests: 10,
                timeoutSeconds: 300,
                includesLocalData: false,
                configurationSHA256: second.sha256
            )
            XCTAssertFalse(grant.consume(scope: changedScope))
        }

        func testHistoryFiltersStatusTextAndSort() throws {
            let older = RunListItem(
                runID: "run-alpha",
                directory: URL(fileURLWithPath: "/tmp/a"),
                question: "Alpha evidence",
                status: .partial,
                updatedAt: Date(timeIntervalSince1970: 10),
                sourceCount: 1,
                evidenceCount: 1,
                claimCount: 1
            )
            let newer = RunListItem(
                runID: "run-beta",
                directory: URL(fileURLWithPath: "/tmp/b"),
                question: "Beta evidence",
                status: .completed,
                updatedAt: Date(timeIntervalSince1970: 20),
                sourceCount: 1,
                evidenceCount: 1,
                claimCount: 1
            )
            XCTAssertEqual(
                HistoryQuery(text: "alpha", statuses: [.partial], sort: .newest)
                    .apply(to: [newer, older]).map(\.runID),
                ["run-alpha"]
            )
            XCTAssertEqual(
                HistoryQuery(sort: .oldest).apply(to: [newer, older]).map(\.runID), ["run-alpha", "run-beta"])
        }

        func testValidationFreshnessControlsMutation() {
            let date = Date(timeIntervalSince1970: 100)
            XCTAssertTrue(FreshValidationState.valid(manifestDate: date, warnings: []).isFresh(for: date))
            XCTAssertTrue(FreshValidationState.valid(manifestDate: date, warnings: []).permitsMutation)
            XCTAssertFalse(
                FreshValidationState.invalid(manifestDate: date, errors: ["bad"], warnings: [])
                    .permitsMutation
            )
            XCTAssertFalse(
                FreshValidationState.valid(manifestDate: date, warnings: []).isFresh(
                    for: date.addingTimeInterval(1)))
        }

        func testStructuralIssueIsInvalidAndDoesNotHideValidRuns() {
            let date = Date(timeIntervalSince1970: 100)
            let bad = RunListItem(
                runID: "run-bad",
                directory: URL(fileURLWithPath: "/tmp/run-bad"),
                question: "Damaged",
                status: .unknown,
                updatedAt: date,
                sourceCount: 0,
                evidenceCount: 0,
                claimCount: 0,
                structuralIssue: RunStructuralIssue(code: "manifest.invalid", message: "bad JSON")
            )
            let good = RunListItem(
                runID: "run-good",
                directory: URL(fileURLWithPath: "/tmp/run-good"),
                question: "Healthy",
                status: .completed,
                updatedAt: date.addingTimeInterval(1),
                sourceCount: 1,
                evidenceCount: 1,
                claimCount: 1
            )
            XCTAssertFalse(RunStructuralPolicy.permitsLoading(bad))
            XCTAssertTrue(RunStructuralPolicy.permitsLoading(good))
            XCTAssertFalse(RunStructuralPolicy.validationState(for: bad)?.permitsMutation ?? true)
            XCTAssertEqual(HistoryQuery().apply(to: [bad, good]).count, 2)
        }

        func testActiveProjectionAndExactAttemptCancelBinding() throws {
            let outputs = try CLIResponseDecoder.decodeJSON(
                from: #"{"outputs":{"source_ids":["s1","s2"]}}"#
            )
            let projection = ActiveRunProjector.project([
                DesktopRunEvent(type: "step.started", stepID: "discover", payload: .object([:])),
                DesktopRunEvent(type: "step.completed", stepID: "discover", payload: outputs),
            ])
            XCTAssertEqual(projection.steps["discover"], .completed)
            XCTAssertEqual(projection.sources, 2)

            var binding = AttemptBinding()
            let first = binding.begin(workspace: URL(fileURLWithPath: "/tmp/job-1"))
            XCTAssertTrue(binding.bind(runDirectory: URL(fileURLWithPath: "/tmp/job-1/run-old"), for: first))
            let second = binding.begin(workspace: URL(fileURLWithPath: "/tmp/job-2"))
            XCTAssertNil(binding.cancelTarget(for: first))
            XCTAssertNil(binding.cancelTarget(for: second), "new attempt must not inherit old run")
            XCTAssertFalse(binding.bind(runDirectory: URL(fileURLWithPath: "/tmp/job-1/run-old"), for: first))
            XCTAssertTrue(binding.bind(runDirectory: URL(fileURLWithPath: "/tmp/job-2/run-new"), for: second))
            XCTAssertFalse(
                binding.bind(runDirectory: URL(fileURLWithPath: "/tmp/job-2/run-swapped"), for: second)
            )
            XCTAssertEqual(binding.cancelTarget(for: second)?.path, "/tmp/job-2/run-new")
        }

        func testTerminalReconciliationAndExternalURLPolicy() throws {
            let outcome = try CLIResponseDecoder.decode(
                RunOutcome.self,
                from:
                    #"{"claims":1,"evidence":2,"limitations":[],"run_directory":"/tmp/run","run_id":"run-1","sources":3,"status":"completed"}"#
            )
            let validation = try CLIResponseDecoder.decode(
                ValidationReport.self,
                from: #"{"valid":true,"errors":[],"warnings":[]}"#
            )
            let inspect = try CLIResponseDecoder.decodeJSON(
                from:
                    #"{"summary":{"claims":1,"evidence":2,"run_id":"run-1","sources":3,"status":"completed"}}"#
            )
            XCTAssertTrue(
                TerminalReconciliation.evaluate(outcome: outcome, validation: validation, inspect: inspect)
                    .isConsistent)
            let mismatch = try CLIResponseDecoder.decodeJSON(
                from:
                    #"{"summary":{"claims":0,"evidence":2,"run_id":"run-1","sources":3,"status":"completed"}}"#
            )
            XCTAssertFalse(
                TerminalReconciliation.evaluate(outcome: outcome, validation: validation, inspect: mismatch)
                    .isConsistent)
            XCTAssertTrue(DesktopExternalURLPolicy.allows(URL(string: "https://example.org/paper")!))
            XCTAssertFalse(DesktopExternalURLPolicy.allows(URL(string: "file:///etc/passwd")!))
            XCTAssertFalse(DesktopExternalURLPolicy.allows(URL(string: "https://user:pass@example.org")!))
        }

        private static let partialManifest =
            #"{"capabilities":[{"kind":"source","name":"openalex","risk":"network_read"},{"kind":"synthesis","name":"openai-compatible","risk":"network_read"}],"execution":{"completed_steps":["discover","extract"]},"limitations":["provider timed out"],"plan":{"plan_id":"plan-1","steps":[{"capability":"research.sources","completion_condition":"done","dependencies":[],"purpose":"discover","status":"pending","step_id":"discover","title":"Discover"},{"capability":"research.evidence.extract","completion_condition":"done","dependencies":["discover"],"purpose":"extract","status":"pending","step_id":"extract","title":"Extract"},{"capability":"research.synthesis","completion_condition":"done","dependencies":["extract"],"purpose":"synthesize","status":"pending","step_id":"synthesize","title":"Synthesize"},{"capability":"research.validation","completion_condition":"done","dependencies":["synthesize"],"purpose":"validate","status":"pending","step_id":"validate","title":"Validate"},{"capability":"research.export","completion_condition":"done","dependencies":["validate"],"purpose":"report","status":"pending","step_id":"report","title":"Report"}]},"request":{"approved_local_roots":["/tmp/papers"],"question":"Q","source_names":["openalex"]},"status":"partial"}"#
    }
#endif
