#if canImport(XCTest)
    import Foundation

    @testable import OpenScienceCore
    @testable import OpenScienceDesktopLogic

    enum WorkbenchFixtureFactory {
        static let epoch = Date(timeIntervalSince1970: 1_777_777_000)

        static func makeConversationSnapshot(
            conversationCount: Int = 200,
            selectedTimelineCount: Int = 1_000
        ) -> ConversationStoreSnapshot {
            precondition(conversationCount > 0)
            precondition(
                (1...ConversationStoreLimits.maximumMessagesPerSession).contains(selectedTimelineCount))

            let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
            let sessions = (0..<conversationCount).map { index in
                let sessionID = deterministicUUID(namespace: 0x2000, index: index)
                let messageCount = index == 0 ? selectedTimelineCount : 1
                let messages = (0..<messageCount).map { messageIndex in
                    ConversationMessage(
                        id: deterministicUUID(namespace: 0x3000 + index, index: messageIndex),
                        role: .user,
                        kind: .text,
                        text: "fixture question \(index)-\(messageIndex)",
                        timestamp: epoch.addingTimeInterval(Double(index * 2_000 + messageIndex))
                    )
                }
                return ConversationSession(
                    id: sessionID,
                    projectID: projectID,
                    title: String(format: "Deterministic conversation %03d", index),
                    createdAt: epoch.addingTimeInterval(Double(index)),
                    updatedAt: epoch.addingTimeInterval(Double(index + messageCount)),
                    status: index.isMultiple(of: 11) ? .partial : .completed,
                    messages: messages,
                    linkedRunIDs: [String(format: "run-fixture-%03d", index)]
                )
            }
            let project = ConversationProject(
                id: projectID,
                title: "Scale Fixture",
                createdAt: epoch,
                updatedAt: epoch.addingTimeInterval(Double(conversationCount + selectedTimelineCount)),
                sessions: sessions
            )
            return ConversationStoreSnapshot(
                projects: [project],
                selectedProjectID: projectID,
                selectedSessionID: sessions[0].id,
                inspectorSelection: InspectorSelection(tab: .context, sessionID: sessions[0].id)
            )
        }

        static func writeLegacyScaleSnapshot(
            to url: URL,
            conversationCount: Int = 200,
            selectedTimelineCount: Int = 1_000
        ) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(
                makeConversationSnapshot(
                    conversationCount: conversationCount,
                    selectedTimelineCount: selectedTimelineCount
                )
            ).write(to: url, options: .atomic)
        }

        static func makeEvidenceDetail(count: Int = 1_000) throws -> RunDetail {
            precondition(count > 0)
            var sourceObjects: [[String: Any]] = []
            var evidenceObjects: [[String: Any]] = []
            var claimObjects: [[String: Any]] = []
            sourceObjects.reserveCapacity(count)
            evidenceObjects.reserveCapacity(count)
            claimObjects.reserveCapacity(count)

            for index in 0..<count {
                let sourceID = String(format: "source-%04d", index)
                let evidenceID = String(format: "evidence-%04d", index)
                let claimID = String(format: "claim-%04d", index)
                let passage = "Deterministic evidence passage \(index)."
                sourceObjects.append([
                    "source_id": sourceID,
                    "canonical_id": "fixture:\(sourceID)",
                    "title": "Fixture source \(index)",
                    "authors": ["Fixture Author"],
                    "publication_date": "2026-08-27",
                    "landing_url": "https://example.invalid/source/\(index)",
                    "license": "CC0-1.0",
                    "status": "active",
                    "providers": ["fixture"],
                    "identifiers": ["fixture": sourceID],
                    "retrievals": [
                        [
                            "retrieval_id": "retrieval-\(sourceID)",
                            "provider": "fixture",
                            "query": "deterministic query \(index)",
                            "retrieved_at": "2026-08-27T09:43:00Z",
                            "url": "https://example.invalid/source/\(index)",
                            "response_hash": String(repeating: "a", count: 64),
                        ]
                    ],
                ])
                evidenceObjects.append([
                    "evidence_id": evidenceID,
                    "source_id": sourceID,
                    "passage": passage,
                    "locator": "line \(index + 1)",
                    "relevance": 1.0,
                    "stance": index.isMultiple(of: 2) ? "supports" : "neutral",
                    "license": "CC0-1.0",
                    "created_by_step": "extract",
                ])
                claimObjects.append([
                    "claim_id": claimID,
                    "text": passage,
                    "kind": "sourced_fact",
                    "evidence_ids": [evidenceID],
                    "confidence": 0.9,
                    "limitations": [],
                    "created_by": "fixture",
                ])
            }

            let decoder = JSONDecoder()
            let sources = try decoder.decode(
                [SourceRecord].self,
                from: JSONSerialization.data(withJSONObject: sourceObjects, options: [.sortedKeys])
            )
            let evidence = try decoder.decode(
                [EvidenceRecord].self,
                from: JSONSerialization.data(withJSONObject: evidenceObjects, options: [.sortedKeys])
            )
            let claims = try decoder.decode(
                [ClaimRecord].self,
                from: JSONSerialization.data(withJSONObject: claimObjects, options: [.sortedKeys])
            )
            let item = RunListItem(
                runID: "run-fixture-scale",
                directory: URL(fileURLWithPath: "/managed-fixture/run-fixture-scale"),
                question: "Scale fixture question",
                status: .completed,
                updatedAt: epoch,
                sourceCount: count,
                evidenceCount: count,
                claimCount: count
            )
            return RunDetail(
                item: item,
                reportMarkdown: "Fixture report. No scientific assertion.",
                sources: sources,
                evidence: evidence,
                claims: claims,
                manifest: .object(["fixture": .bool(true)])
            )
        }

        static func percentile95(_ values: [Duration]) -> Duration {
            precondition(!values.isEmpty)
            let sorted = values.sorted()
            let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
            return sorted[index]
        }

        private static func deterministicUUID(namespace: Int, index: Int) -> UUID {
            let suffix = String(format: "%012llx", UInt64(namespace) << 20 | UInt64(index))
            return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
        }
    }
#endif
