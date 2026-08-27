#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore
    @testable import OpenScienceDesktopLogic

    final class ConversationModelsTests: XCTestCase {
        func testConversationModelsRoundTripWithoutCredentialFields() throws {
            let projectID = UUID()
            let sessionID = UUID()
            let message = ConversationMessage(
                id: UUID(),
                role: .assistant,
                kind: .result,
                text: "API_KEY=top-secret",
                timestamp: Date(timeIntervalSince1970: 123),
                runReference: ConversationRunReference(
                    runID: "run-123",
                    status: .completed,
                    sources: 4,
                    evidence: 8,
                    claims: 2
                ),
                artifactReferences: [
                    try ConversationArtifactReference(
                        id: "report",
                        kind: .report,
                        title: "Report",
                        relativePath: "report/report.md"
                    )
                ]
            )
            let session = ConversationSession(
                id: sessionID,
                projectID: projectID,
                title: "Evidence review",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 123),
                status: .completed,
                isArchived: false,
                messages: [message],
                linkedRunIDs: ["run-123"]
            )
            let project = ConversationProject(
                id: projectID,
                title: "OpenScience",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 123),
                isArchived: false,
                sessions: [session]
            )
            let snapshot = ConversationStoreSnapshot(
                projects: [project],
                selectedProjectID: projectID,
                selectedSessionID: sessionID,
                inspectorSelection: InspectorSelection(
                    tab: .artifacts,
                    sessionID: sessionID,
                    messageID: message.id,
                    runID: "run-123"
                )
            )

            let data = try JSONEncoder().encode(snapshot)
            let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(encoded.localizedCaseInsensitiveContains("top-secret"))
            XCTAssertFalse(encoded.contains("apiKey"))
            XCTAssertFalse(encoded.contains("credential"))
            XCTAssertEqual(try JSONDecoder().decode(ConversationStoreSnapshot.self, from: data), snapshot)
        }

        func testArtifactReferenceRejectsAbsoluteAndTraversalPaths() {
            XCTAssertThrowsError(
                try ConversationArtifactReference(
                    id: "absolute", kind: .file, title: "Bad", relativePath: "/tmp/private"
                )
            )
            XCTAssertThrowsError(
                try ConversationArtifactReference(
                    id: "traversal", kind: .file, title: "Bad", relativePath: "../private"
                )
            )
            XCTAssertNoThrow(
                try ConversationArtifactReference(
                    id: "good", kind: .evidence, title: "Evidence", relativePath: "evidence/e-1.json"
                )
            )
        }

        func testEveryInlineAndInspectorKindIsCodable() throws {
            XCTAssertEqual(
                Set(MessageKind.allCases),
                Set([.text, .plan, .permission, .runProgress, .result, .error])
            )
            XCTAssertEqual(
                Set(InspectorTab.allCases),
                Set([.context, .plan, .evidence, .artifacts])
            )
            XCTAssertEqual(
                Set(SessionStatus.allCases),
                Set([
                    .draft, .planning, .awaitingApproval, .running, .completed, .partial,
                    .failed, .cancelled, .interrupted, .invalid, .unknown,
                ])
            )
        }

        func testTypedWorkbenchIdentitiesRoundTripAndRejectMalformedValues() throws {
            let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let turnID = ResearchTurnID(uuid: uuid)
            let messageID = UserMessageID(uuid: uuid)
            let attemptID = AttemptBindingID(uuid: uuid)
            let encoder = JSONEncoder()
            let turnData = try encoder.encode(turnID)
            let messageData = try encoder.encode(messageID)
            let attemptData = try encoder.encode(attemptID)
            XCTAssertEqual(
                String(data: turnData, encoding: .utf8),
                #""turn-00000000-0000-0000-0000-000000000001""#)
            XCTAssertEqual(
                String(data: messageData, encoding: .utf8),
                #""message-00000000-0000-0000-0000-000000000001""#)
            XCTAssertEqual(
                String(data: attemptData, encoding: .utf8),
                #""attempt-00000000-0000-0000-0000-000000000001""#)
            let decoder = JSONDecoder()
            XCTAssertEqual(try decoder.decode(ResearchTurnID.self, from: turnData), turnID)
            XCTAssertEqual(try decoder.decode(UserMessageID.self, from: messageData), messageID)
            XCTAssertEqual(try decoder.decode(AttemptBindingID.self, from: attemptData), attemptID)

            XCTAssertThrowsError(
                try ResearchTurnID(
                    rawValue: "turn-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
            XCTAssertThrowsError(try UserMessageID(rawValue: "message-not-a-uuid"))
            XCTAssertThrowsError(
                try AttemptBindingID(rawValue: "run-" + uuid.uuidString.lowercased()))
        }

        func testPlanAndRunBindingRequireExactSafeIdentity() throws {
            let sha = String(repeating: "a", count: 64)
            let turnID = ResearchTurnID()
            let plan = try PlanReference(
                requestID: "request:exact-1",
                planID: "plan-exact-1",
                planSHA256: sha,
                attemptPrivatePathHint: "plan-exact-1.json")
            XCTAssertEqual(plan.planSHA256, sha)

            let binding = try RunBinding(
                bindingID: AttemptBindingID(),
                turnID: turnID,
                attemptOrdinal: 1,
                runID: "run-exact-1",
                managedRelativeReference: "run-exact-1",
                requestID: plan.requestID,
                planID: plan.planID,
                planSHA256: plan.planSHA256,
                lastValidatedFingerprint: String(repeating: "b", count: 64),
                statusHint: .completed,
                createdAt: Date(timeIntervalSince1970: 10))
            XCTAssertEqual(binding.managedRelativeReference, binding.runID)

            XCTAssertThrowsError(
                try PlanReference(
                    requestID: "request-1", planID: "plan-1",
                    planSHA256: String(repeating: "A", count: 64)))
            XCTAssertThrowsError(
                try PlanReference(
                    requestID: "request-1", planID: "plan-1",
                    planSHA256: String(repeating: "a", count: 63)))
            XCTAssertThrowsError(
                try PlanReference(
                    requestID: "request-1", planID: "plan-1", planSHA256: sha,
                    attemptPrivatePathHint: "/private/plan.json"))
            for unsafe in ["/tmp/run-exact-1", "../run-exact-1", "run/../run-exact-1", "~/.runs"] {
                XCTAssertThrowsError(
                    try RunBinding(
                        bindingID: AttemptBindingID(), turnID: turnID, attemptOrdinal: 1,
                        runID: "run-exact-1", managedRelativeReference: unsafe,
                        requestID: plan.requestID, planID: plan.planID,
                        planSHA256: plan.planSHA256))
            }
            XCTAssertThrowsError(
                try RunBinding(
                    bindingID: AttemptBindingID(), turnID: turnID, attemptOrdinal: 0,
                    requestID: plan.requestID, planID: plan.planID,
                    planSHA256: plan.planSHA256))
        }

        func testResearchTurnContainsExactlyOneImmutableUserMessage() throws {
            let message = try UserMessage(
                id: UserMessageID(),
                text: "  Compare the exact evidence  ",
                createdAt: Date(timeIntervalSince1970: 12))
            let turn = try ResearchTurn(
                id: ResearchTurnID(),
                message: message,
                createdAt: Date(timeIntervalSince1970: 12),
                stateHint: .planning)
            XCTAssertEqual(turn.message.text, "Compare the exact evidence")
            XCTAssertEqual(turn.stateHint, .planning)
            XCTAssertTrue(turn.attemptBindingIDs.isEmpty)
        }
    }
#endif
