#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceDesktopLogic

    @MainActor
    final class ConversationIndexScaleTests: XCTestCase {
        func testEmptyStoreAndBoundedScanCeilingAreExplicit() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "openscience-index-empty-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try ConversationStore(
                fileURL: directory.appendingPathComponent("workspace-v1.json")
            )
            XCTAssertTrue(store.projects.isEmpty)
            XCTAssertEqual(ConversationStoreLimits.maximumTotalSessions, 10_000)
        }

        func testTenThousandEnvelopeScanIsBoundedAndTenThousandOneFailsClosed() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "openscience-index-boundary-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let workspace = directory.appendingPathComponent("workspace-v1.json")
            let initial = try ConversationStore(fileURL: workspace)
            let corrupt = Data("{".utf8)
            for index in 0..<ConversationStoreLimits.maximumTotalSessions {
                let name = String(
                    format: "conversation-00000000-0000-0000-0000-%012llx.json",
                    UInt64(index + 1)
                )
                XCTAssertTrue(
                    FileManager.default.createFile(
                        atPath: initial.conversationsDirectory.appendingPathComponent(name).path,
                        contents: corrupt
                    )
                )
            }

            let bounded = try ConversationStore(fileURL: workspace)
            XCTAssertEqual(
                bounded.issues.filter { $0.code == "conversation.corrupt" }.count,
                ConversationStoreLimits.maximumTotalSessions,
                "bounded scan issues=\(bounded.issues.count)"
            )
            XCTAssertTrue(bounded.projects.isEmpty)

            let overflowName = "conversation-00000000-0000-0000-0000-000000002711.json"
            XCTAssertTrue(
                FileManager.default.createFile(
                    atPath: bounded.conversationsDirectory.appendingPathComponent(overflowName).path,
                    contents: corrupt
                )
            )
            XCTAssertThrowsError(try ConversationStore(fileURL: workspace)) { error in
                XCTAssertEqual(
                    error as? ConversationStoreError,
                    .limitExceeded("conversation scan", 10_000),
                    "unexpected overflow error: \(error)"
                )
            }
        }

        func testRebuildsTwoHundredConversationsAndOneThousandTimelineItemsWithoutLoss() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "openscience-index-scale-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let workspaceURL = directory.appendingPathComponent("workspace-v1.json")
            try WorkbenchFixtureFactory.writeLegacyScaleSnapshot(to: workspaceURL)
            let store = try ConversationStore(fileURL: workspaceURL)

            XCTAssertEqual(store.projects.flatMap(\.sessions).count, 200)
            XCTAssertEqual(store.selectedSession?.messages.count, 1_000)
            XCTAssertEqual(store.search("fixture question 0-").count, 1)
            XCTAssertEqual(
                store.search("run-fixture-199").map(\.session.title),
                [
                    "Deterministic conversation 199"
                ])
            XCTAssertEqual(
                Set(store.projects.flatMap(\.sessions).map(\.id)).count,
                200
            )

            let reloaded = try ConversationStore(fileURL: workspaceURL)
            XCTAssertEqual(reloaded.projects.flatMap(\.sessions).count, 200)
            XCTAssertEqual(reloaded.selectedSession?.messages.count, 1_000)
        }

        func testSearchOrderingUsesUpdatedDateThenStableIdentifier() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "openscience-index-order-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let workspaceURL = directory.appendingPathComponent("workspace-v1.json")
            try WorkbenchFixtureFactory.writeLegacyScaleSnapshot(
                to: workspaceURL,
                conversationCount: 200,
                selectedTimelineCount: 1_000
            )
            let store = try ConversationStore(fileURL: workspaceURL)
            let results = store.search("Deterministic conversation")

            XCTAssertEqual(results.count, 200)
            for pair in zip(results, results.dropFirst()) {
                if pair.0.session.updatedAt == pair.1.session.updatedAt {
                    XCTAssertLessThan(
                        pair.0.session.id.uuidString,
                        pair.1.session.id.uuidString
                    )
                } else {
                    XCTAssertGreaterThan(pair.0.session.updatedAt, pair.1.session.updatedAt)
                }
            }
        }
    }
#endif
