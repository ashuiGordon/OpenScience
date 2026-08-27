#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore
    @testable import OpenScienceDesktopLogic

    final class ConversationTimelineProjectorTests: XCTestCase {
        func testPlanProjectionCreatesPlanAndScopedPermissionCards() throws {
            let plan = try Self.plan()
            let context = PlanReviewContext(
                question: "How reliable is the evidence?",
                sources: [
                    ProviderReview(
                        name: "openalex",
                        risk: "network_read",
                        kind: "source",
                        networkSummary: "Search scholarly records",
                        destination: "https://api.openalex.org"
                    )
                ],
                synthesizer: ProviderReview(name: "extractive", risk: "local", kind: "synthesis"),
                localRoots: [],
                maxRecords: 25,
                maxNetworkRequests: 8,
                timeoutSeconds: 120,
                plan: plan
            )
            let sessionID = UUID()
            let projection = ConversationTimelineProjector.project(
                plan: plan,
                context: context,
                sessionID: sessionID,
                timestamp: Date(timeIntervalSince1970: 1)
            )

            XCTAssertEqual(projection.messages.map(\.kind), [.permission, .plan])
            XCTAssertTrue(projection.messages[0].text.contains("openalex"))
            XCTAssertEqual(projection.selection.tab, .plan)
            XCTAssertEqual(projection.selection.sessionID, sessionID)
            guard case let .plan(previewContext) = projection.preview else {
                return XCTFail("expected plan preview")
            }
            XCTAssertEqual(previewContext, context)
        }

        func testOfflinePlanDoesNotInventAPermissionCard() throws {
            let plan = try Self.plan()
            let context = PlanReviewContext(
                question: "Offline question",
                sources: [ProviderReview(name: "fixture", risk: "local_read", kind: "source")],
                synthesizer: ProviderReview(name: "extractive", risk: "local", kind: "synthesis"),
                localRoots: [],
                maxRecords: 5,
                maxNetworkRequests: 0,
                timeoutSeconds: 60,
                plan: plan
            )
            let result = ConversationTimelineProjector.project(
                plan: plan,
                context: context,
                sessionID: UUID(),
                timestamp: Date(timeIntervalSince1970: 1)
            )
            XCTAssertEqual(result.messages.map(\.kind), [.plan])
        }

        func testActiveProjectionCreatesProgressCardAndActivityPreview() {
            let active = ActiveRunProjector.project([
                DesktopRunEvent(type: "step.started", stepID: "discover", payload: .object([:])),
                DesktopRunEvent(
                    type: "step.completed",
                    stepID: "discover",
                    payload: .object([
                        "outputs": .object(["source_ids": .array([.string("s1"), .string("s2")])])
                    ])
                ),
                DesktopRunEvent(type: "step.started", stepID: "extract", payload: .object([:])),
            ])
            let sessionID = UUID()
            let result = ConversationTimelineProjector.project(
                activeRun: active,
                runID: "run-live",
                sessionID: sessionID,
                timestamp: Date(timeIntervalSince1970: 2)
            )

            XCTAssertEqual(result.messages.map(\.kind), [.runProgress])
            XCTAssertEqual(result.messages[0].runReference?.status, .running)
            XCTAssertEqual(result.messages[0].runReference?.sources, 2)
            XCTAssertEqual(result.selection.tab, .context)
            guard case let .activity(runID, preview) = result.preview else {
                return XCTFail("expected activity preview")
            }
            XCTAssertEqual(runID, "run-live")
            XCTAssertEqual(preview, active)
        }

        func testOutcomeAndDetailCreateResultArtifactsAndReportPreview() throws {
            let outcome = try CLIResponseDecoder.decode(
                RunOutcome.self,
                from:
                    #"{"run_id":"run-done","run_directory":"/private/run-done","status":"completed","report":"/private/run-done/report/report.md","manifest":"/private/run-done/manifest.json","sources":3,"evidence":7,"claims":2,"limitations":[]}"#
            )
            let item = RunListItem(
                runID: "run-done",
                directory: URL(fileURLWithPath: "/private/run-done"),
                question: "Question",
                status: .completed,
                updatedAt: Date(timeIntervalSince1970: 3),
                sourceCount: 3,
                evidenceCount: 7,
                claimCount: 2
            )
            let detail = RunDetail(
                item: item,
                reportMarkdown: "# Result",
                sources: [],
                evidence: [],
                claims: [],
                manifest: .object([:])
            )
            let sessionID = UUID()
            let result = ConversationTimelineProjector.project(
                outcome: outcome,
                detail: detail,
                sessionID: sessionID,
                timestamp: Date(timeIntervalSince1970: 3)
            )

            XCTAssertEqual(result.messages.map(\.kind), [.result])
            XCTAssertEqual(result.messages[0].artifactReferences.map(\.kind), [.report, .manifest])
            XCTAssertEqual(
                result.messages[0].artifactReferences.compactMap(\.relativePath),
                ["report/report.md", "manifest.json"]
            )
            XCTAssertFalse(result.messages[0].text.contains("/private/run-done"))
            XCTAssertEqual(result.selection.tab, .artifacts)
            guard case let .result(previewOutcome, previewDetail) = result.preview else {
                return XCTFail("expected result preview")
            }
            XCTAssertEqual(previewOutcome, outcome)
            XCTAssertEqual(previewDetail, detail)
        }

        func testFailedOutcomeCreatesErrorCardAndActivitySelection() throws {
            let outcome = try CLIResponseDecoder.decode(
                RunOutcome.self,
                from:
                    #"{"run_id":"run-failed","run_directory":"/tmp/run","status":"failed","sources":0,"evidence":0,"claims":0,"limitations":["provider timed out"]}"#
            )
            let result = ConversationTimelineProjector.project(
                outcome: outcome,
                detail: nil,
                sessionID: UUID(),
                timestamp: Date(timeIntervalSince1970: 4)
            )
            XCTAssertEqual(result.messages.first?.kind, .error)
            XCTAssertTrue(result.messages.first?.text.contains("provider timed out") == true)
            XCTAssertEqual(result.selection.tab, .context)
        }

        func testRunDetailAloneProjectsAResultPreview() {
            let item = RunListItem(
                runID: "run-detail",
                directory: URL(fileURLWithPath: "/tmp/run-detail"),
                question: "Question",
                status: .completed,
                updatedAt: Date(timeIntervalSince1970: 5),
                sourceCount: 1,
                evidenceCount: 2,
                claimCount: 1
            )
            let detail = RunDetail(
                item: item,
                reportMarkdown: "# Detail",
                sources: [],
                evidence: [],
                claims: [],
                manifest: .object([:])
            )
            let result = ConversationTimelineProjector.project(
                detail: detail,
                sessionID: UUID(),
                timestamp: Date(timeIntervalSince1970: 5)
            )
            XCTAssertEqual(result.messages.first?.kind, .result)
            XCTAssertEqual(result.selection.tab, .artifacts)
            guard case let .result(outcome, projectedDetail) = result.preview else {
                return XCTFail("expected result preview")
            }
            XCTAssertEqual(outcome.runID, "run-detail")
            XCTAssertEqual(projectedDetail, detail)
        }

        private static func plan() throws -> ResearchPlanRecord {
            try CLIResponseDecoder.decode(
                ResearchPlanRecord.self,
                from:
                    #"{"plan_id":"plan-1","request_id":"request-1","status":"pending","steps":[{"step_id":"discover","title":"Discover","purpose":"Find sources","capability":"source","dependencies":[],"completion_condition":"Sources found","status":"pending"},{"step_id":"report","title":"Report","purpose":"Write report","capability":"synthesis","dependencies":["discover"],"completion_condition":"Report written","status":"pending"}]}"#
            )
        }
    }
#endif
