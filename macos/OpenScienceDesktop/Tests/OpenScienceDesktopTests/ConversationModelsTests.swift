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
    }
#endif
