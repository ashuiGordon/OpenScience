#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore
    @testable import OpenScienceDesktopLogic

    final class ConversationStoreTests: XCTestCase {
        private var directory: URL!
        private var storeURL: URL!

        override func setUpWithError() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("openscience-conversations-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            storeURL = directory.appendingPathComponent("workspace-v1.json")
        }

        override func tearDownWithError() throws {
            try? FileManager.default.removeItem(at: directory)
        }

        @MainActor
        func testIndexAndPerConversationEnvelopeAreAtomic0600AndAssistantIsTransient() throws {
            let store = try ConversationStore(fileURL: storeURL)
            let project = try store.createProject(title: "My project", now: Self.date(1))
            let session = try store.createSession(
                projectID: project.id,
                title: "Climate evidence",
                prompt: "Compare the evidence",
                now: Self.date(2)
            )
            let assistant = try store.appendMessage(
                sessionID: session.id,
                role: .assistant,
                kind: .plan,
                text: "PLAN-PROSE-MUST-NOT-PERSIST",
                timestamp: Self.date(3)
            )
            try store.selectInspector(
                InspectorSelection(tab: .plan, sessionID: session.id, messageID: assistant.id))

            let envelope = Self.envelopeURL(store, session.id)
            XCTAssertEqual(try Self.mode(storeURL), 0o600)
            XCTAssertEqual(try Self.mode(envelope), 0o600)
            let workspaceText = try Self.text(storeURL)
            let envelopeText = try Self.text(envelope)
            XCTAssertFalse(workspaceText.contains("Compare the evidence"))
            XCTAssertFalse(workspaceText.contains("messages"))
            XCTAssertTrue(envelopeText.contains("Compare the evidence"))
            XCTAssertFalse(envelopeText.contains("PLAN-PROSE-MUST-NOT-PERSIST"))
            XCTAssertFalse(envelopeText.contains(#""role""#))

            let reloaded = try ConversationStore(fileURL: storeURL)
            XCTAssertEqual(reloaded.selectedProject?.id, project.id)
            XCTAssertEqual(reloaded.selectedSession?.messages.count, 1)
            XCTAssertEqual(reloaded.selectedSession?.messages.first?.role, .user)
            XCTAssertNil(reloaded.inspectorSelection?.messageID)
            XCTAssertEqual(reloaded.inspectorSelection?.tab, .plan)
            XCTAssertEqual(reloaded.schemaVersion, 1)
        }

        @MainActor
        func testCorruptWorkspaceRebuildsFromBoundedValidEnvelopesWithSafeIssue() throws {
            let store = try ConversationStore(fileURL: storeURL)
            let session = try store.createSession(title: "Recover me", prompt: "durable user text")
            try Data("{ definitely-not-json".utf8).write(to: storeURL)

            let recovered = try ConversationStore(fileURL: storeURL)
            XCTAssertEqual(recovered.projects.flatMap(\.sessions).map(\.id), [session.id])
            XCTAssertEqual(
                recovered.projects.flatMap(\.sessions).first?.messages.first?.text, "durable user text")
            XCTAssertEqual(recovered.issues.map(\.code), ["conversation.workspace_corrupt_rebuilt"])
            XCTAssertTrue(try Self.text(storeURL).contains(#""workspace_id""#))
            XCTAssertNil(recovered.selectedSessionID)
        }

        @MainActor
        func testMissingWorkspaceRebuildsFromEnvelopeAndResetsSelection() throws {
            let store = try ConversationStore(fileURL: storeURL)
            let session = try store.createSession(title: "Orphan", prompt: "still visible")
            try FileManager.default.removeItem(at: storeURL)

            let recovered = try ConversationStore(fileURL: storeURL)
            XCTAssertEqual(recovered.projects.flatMap(\.sessions).map(\.id), [session.id])
            XCTAssertEqual(recovered.issues.map(\.code), ["conversation.workspace_missing_rebuilt"])
            XCTAssertNil(recovered.selectedProjectID)
            XCTAssertNil(recovered.selectedSessionID)
            XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        }

        @MainActor
        func testExistingWorkspaceCannotBeSkippedAndSymlinkIsRejected() throws {
            let original = Data(
                #"{"schema_version":1,"workspace_id":"local","projects":[],"layout_state":{"selectedPreviewTab":"context","sidebarVisibility":"shown","previewVisibility":"shown","sidebarWidth":262,"previewWidth":484},"conversation_ids":[]}"#
                    .utf8)
            try original.write(to: storeURL)
            XCTAssertThrowsError(try ConversationStore(fileURL: storeURL, loadIfPresent: false))
            XCTAssertEqual(try Data(contentsOf: storeURL), original)

            try FileManager.default.removeItem(at: storeURL)
            let target = directory.appendingPathComponent("target.json")
            try original.write(to: target)
            try FileManager.default.createSymbolicLink(at: storeURL, withDestinationURL: target)
            XCTAssertThrowsError(try ConversationStore(fileURL: storeURL)) { error in
                XCTAssertEqual(error as? ConversationStoreError, .unsafeStoreFile)
            }
        }

        @MainActor
        func testUnsupportedWorkspaceSchemaFailsClosedAndIsNotOverwritten() throws {
            let newer = Data(#"{"schema_version":2,"workspace_id":"local","projects":[]}"#.utf8)
            try newer.write(to: storeURL)
            XCTAssertThrowsError(try ConversationStore(fileURL: storeURL)) { error in
                XCTAssertEqual(error as? ConversationStoreError, .unsupportedSchema(2))
            }
            XCTAssertEqual(try Data(contentsOf: storeURL), newer)
        }

        @MainActor
        func testOversizedWorkspaceIsIgnoredAndSafelyRebuilt() throws {
            let oversized = Data(
                repeating: 0x20, count: ConversationStoreLimits.maximumWorkspaceBytes + 1)
            try oversized.write(to: storeURL)
            let recovered = try ConversationStore(fileURL: storeURL)
            XCTAssertTrue(recovered.projects.isEmpty)
            XCTAssertEqual(recovered.issues.map(\.code), ["conversation.workspace_corrupt_rebuilt"])
            XCTAssertLessThan(
                try Data(contentsOf: storeURL).count,
                ConversationStoreLimits.maximumWorkspaceBytes)
        }

        @MainActor
        func testRenameArchiveSearchSelectionAndDateGrouping() throws {
            let store = try ConversationStore(fileURL: storeURL)
            let calendar = Calendar(identifier: .gregorian)
            let now = Self.date(40 * 86_400)
            let project = try store.createProject(title: "Original", now: Self.date(0))
            let old = try store.createSession(
                projectID: project.id, title: "Historic evidence", prompt: "old question",
                now: Self.date(86_400))
            let recent = try store.createSession(
                projectID: project.id, title: "Recent climate session", prompt: "climate question",
                now: now.addingTimeInterval(-2 * 86_400))
            try store.renameProject(project.id, title: "Renamed", now: now)
            try store.renameSession(recent.id, title: "Climate synthesis", now: now)
            XCTAssertEqual(store.search("climate").map(\.session.id), [recent.id])

            let groups = try store.groupedSessions(
                projectID: project.id, referenceDate: now, calendar: calendar)
            XCTAssertEqual(groups.map(\.bucket), [.today, .older])
            XCTAssertEqual(groups.flatMap(\.sessions).map(\.id), [recent.id, old.id])

            try store.archiveSession(recent.id, archived: true, now: now)
            XCTAssertTrue(store.search("climate").isEmpty)
            XCTAssertEqual(store.search("climate", includeArchived: true).map(\.session.id), [recent.id])
            XCTAssertNil(store.selectedSessionID)
            try store.archiveProject(project.id, archived: true, now: now)
            XCTAssertTrue(store.projects.first?.isArchived == true)
            XCTAssertNil(store.selectedProjectID)
        }

        @MainActor
        func testDraftRoundTripUsesDisplayOnlyHintsAndDowngradesTransientStatus() throws {
            let store = try ConversationStore(fileURL: storeURL)
            let session = try store.createSession(title: "Draft", prompt: nil, now: Self.date(1))
            var research = ResearchDraft()
            research.scope = "peer reviewed"
            research.constraints = ["since 2020"]
            research.sourceNames = ["openalex"]
            research.localRoots = [URL(fileURLWithPath: "/private/secret-root")]
            research.fixtureFiles = [URL(fileURLWithPath: "/private/fixture.json")]
            let draft = ConversationDraft(
                text: "unsent question",
                researchDraft: research,
                updatedAt: Self.date(2))
            _ = try store.setDraft(sessionID: session.id, draft: draft)
            _ = try store.setSessionStatus(
                sessionID: session.id, status: .running, linkedRunID: "run-live",
                updatedAt: Self.date(3))
            let envelopeText = try Self.text(Self.envelopeURL(store, session.id))
            XCTAssertFalse(envelopeText.contains("/private/"))
            XCTAssertTrue(envelopeText.contains("secret-root"))

            let reloaded = try ConversationStore(fileURL: storeURL)
            XCTAssertEqual(reloaded.selectedSession?.draft?.text, "unsent question")
            XCTAssertEqual(reloaded.selectedSession?.draft?.localRootHints.first?.name, "secret-root")
            XCTAssertEqual(reloaded.selectedSession?.status, .unknown)
            XCTAssertEqual(reloaded.selectedSession?.linkedRunIDs, ["run-live"])
        }

        @MainActor
        func testAssistantCanariesNeverEnterAnyPersistedByte() throws {
            let store = try ConversationStore(fileURL: storeURL)
            let session = try store.createSession(title: "Canary", prompt: "safe question")
            let forbidden = [
                "PLAN-CANARY-781", "GRANT-CANARY-782", "EVIDENCE-PASSAGE-CANARY-783",
                "REPORT-TEXT-CANARY-784", "STDERR-CANARY-785", "/private/run-canary-786",
            ]
            for (index, value) in forbidden.enumerated() {
                _ = try store.appendMessage(
                    sessionID: session.id,
                    role: .assistant,
                    kind: index == 0 ? .plan : (index == 1 ? .permission : .result),
                    text: value)
            }
            let artifact = try ConversationArtifactReference(
                id: "artifact-safe-1", kind: .report, title: "REPORT-TITLE-CANARY-787",
                relativePath: "report/report.md")
            _ = try store.appendMessage(
                sessionID: session.id, role: .assistant, kind: .result, text: "RESULT-CANARY-788",
                runReference: ConversationRunReference(runID: "run-safe-1", status: .completed),
                artifactReferences: [artifact])
            _ = try store.setSessionStatus(
                sessionID: session.id, status: .completed, linkedRunID: "run-safe-1")
            _ = try store.setDraftText(
                sessionID: session.id, text: "API_KEY=draft-secret-canary")

            let persisted = try Self.allPersistedText(store)
            for value in forbidden + [
                "REPORT-TITLE-CANARY-787", "RESULT-CANARY-788", "draft-secret-canary",
                "report/report.md",
            ] {
                XCTAssertFalse(persisted.contains(value), "persisted forbidden canary: \(value)")
            }
            XCTAssertTrue(persisted.contains("[REDACTED]"))
            XCTAssertTrue(persisted.contains("run-safe-1"))
            XCTAssertTrue(persisted.contains("artifact-safe-1"))
        }

        @MainActor
        func testCorruptAndNewerEnvelopesAreIsolatedWithoutHidingValidConversation() throws {
            let store = try ConversationStore(fileURL: storeURL)
            let project = try store.createProject(title: "P")
            let corrupt = try store.createSession(
                projectID: project.id, title: "Corrupt", prompt: "one")
            let newer = try store.createSession(
                projectID: project.id, title: "Newer", prompt: "two")
            let valid = try store.createSession(
                projectID: project.id, title: "Valid", prompt: "three")
            try Data("{broken".utf8).write(to: Self.envelopeURL(store, corrupt.id))
            let newerURL = Self.envelopeURL(store, newer.id)
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: newerURL)) as? [String: Any])
            object["schema_version"] = 2
            try JSONSerialization.data(withJSONObject: object).write(to: newerURL)

            let reloaded = try ConversationStore(fileURL: storeURL)
            XCTAssertEqual(reloaded.projects.flatMap(\.sessions).map(\.id), [valid.id])
            XCTAssertEqual(
                Set(reloaded.issues.map(\.code)),
                Set([
                    "conversation.corrupt", "conversation.schema_newer",
                ]))
            XCTAssertTrue(try Self.text(Self.envelopeURL(store, corrupt.id)).contains("{broken"))
            XCTAssertEqual(
                try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: newerURL)) as? [String: Any]
                )["schema_version"] as? Int,
                2)
        }

        @MainActor
        func testLegacyMonolithMigratesUserTextAndTypedIDsButDropsAssistantProse() throws {
            let projectID = UUID()
            let sessionID = UUID()
            let user = ConversationMessage(
                role: .user, kind: .text, text: "legacy user question", timestamp: Self.date(1))
            let assistant = ConversationMessage(
                role: .assistant, kind: .result, text: "LEGACY-ASSISTANT-CANARY",
                timestamp: Self.date(2),
                runReference: ConversationRunReference(runID: "run-legacy", status: .completed))
            let session = ConversationSession(
                id: sessionID, projectID: projectID, title: "Legacy", createdAt: Self.date(1),
                updatedAt: Self.date(2), status: .completed, messages: [user, assistant],
                linkedRunIDs: ["run-legacy"])
            let project = ConversationProject(
                id: projectID, title: "Legacy Project", createdAt: Self.date(1),
                updatedAt: Self.date(2), sessions: [session])
            let legacy = ConversationStoreSnapshot(
                projects: [project], selectedProjectID: projectID, selectedSessionID: sessionID,
                inspectorSelection: InspectorSelection(
                    tab: .artifacts, sessionID: sessionID, messageID: assistant.id,
                    runID: "run-legacy"))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(legacy).write(to: storeURL)

            let migrated = try ConversationStore(fileURL: storeURL)
            XCTAssertEqual(migrated.selectedSession?.messages.map(\.text), ["legacy user question"])
            XCTAssertEqual(migrated.selectedSession?.linkedRunIDs, ["run-legacy"])
            XCTAssertNil(migrated.inspectorSelection?.messageID)
            XCTAssertTrue(try Self.text(storeURL).contains(#""workspace_id""#))
            let envelope = try Self.text(Self.envelopeURL(migrated, sessionID))
            XCTAssertFalse(envelope.contains("LEGACY-ASSISTANT-CANARY"))
            XCTAssertTrue(envelope.contains("legacy user question"))
            XCTAssertTrue(envelope.contains("run-legacy"))
            XCTAssertEqual(migrated.issues.map(\.code), ["conversation.migrated_v1"])
        }

        @MainActor
        func testInvalidMutationPreservesLastCompleteEnvelope() throws {
            let store = try ConversationStore(fileURL: storeURL)
            let session = try store.createSession(title: "Stable", prompt: "stable user text")
            let envelope = Self.envelopeURL(store, session.id)
            let before = try Data(contentsOf: envelope)
            XCTAssertThrowsError(
                try store.appendMessage(
                    sessionID: session.id,
                    role: .user,
                    kind: .text,
                    text: String(
                        repeating: "x", count: ConversationStoreLimits.maximumMessageCharacters + 1)))
            XCTAssertEqual(try Data(contentsOf: envelope), before)
            XCTAssertEqual(store.selectedSession?.messages.count, 1)
        }

        @MainActor
        func testExpectedRevisionRejectsStaleSessionMutationWithoutChangingEnvelope() throws {
            let store = try ConversationStore(fileURL: storeURL)
            let session = try store.createSession(title: "Revision", prompt: "first")
            let firstRevision = try XCTUnwrap(store.revision(for: session.id))
            _ = try store.setDraftText(
                sessionID: session.id,
                text: "draft one",
                expectedRevision: firstRevision)
            let currentRevision = try XCTUnwrap(store.revision(for: session.id))
            XCTAssertEqual(currentRevision, firstRevision + 1)
            let envelope = Self.envelopeURL(store, session.id)
            let before = try Data(contentsOf: envelope)

            XCTAssertThrowsError(
                try store.renameSession(
                    session.id,
                    title: "stale rename",
                    expectedRevision: firstRevision)
            ) { error in
                XCTAssertEqual(
                    error as? ConversationStoreError,
                    .revisionConflict(expected: firstRevision, actual: currentRevision))
            }
            XCTAssertEqual(try Data(contentsOf: envelope), before)
            XCTAssertEqual(store.selectedSession?.title, "Revision")

            _ = try store.appendMessage(
                sessionID: session.id,
                role: .assistant,
                kind: .text,
                text: "transient",
                expectedRevision: currentRevision)
            XCTAssertEqual(store.revision(for: session.id), currentRevision)
        }

        @MainActor
        func testDeleteSessionMetadataRemovesOnlyExactEnvelopeAndLeavesRunsExportsUnchanged() throws {
            let store = try ConversationStore(fileURL: storeURL)
            let project = try store.createProject(title: "Delete")
            let retained = try store.createSession(
                projectID: project.id, title: "Keep", prompt: "keep me")
            let removed = try store.createSession(
                projectID: project.id, title: "Delete", prompt: "delete metadata")
            _ = try store.setSessionStatus(
                sessionID: removed.id,
                status: .completed,
                linkedRunID: "run-owned")
            let removedEnvelope = Self.envelopeURL(store, removed.id)
            let retainedEnvelope = Self.envelopeURL(store, retained.id)
            let retainedBytes = try Data(contentsOf: retainedEnvelope)

            let runDirectory = directory.appendingPathComponent("runs/run-owned", isDirectory: true)
            let exportDirectory = directory.appendingPathComponent("exports", isDirectory: true)
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            let runFile = runDirectory.appendingPathComponent("manifest.json")
            let exportFile = exportDirectory.appendingPathComponent("bundle.zip")
            let runBytes = Data("RUN-FIXTURE-BYTES".utf8)
            let exportBytes = Data("EXPORT-FIXTURE-BYTES".utf8)
            try runBytes.write(to: runFile)
            try exportBytes.write(to: exportFile)

            let revision = try XCTUnwrap(store.revision(for: removed.id))
            try store.deleteSessionMetadata(removed.id, expectedRevision: revision)

            XCTAssertFalse(FileManager.default.fileExists(atPath: removedEnvelope.path))
            XCTAssertEqual(try Data(contentsOf: retainedEnvelope), retainedBytes)
            XCTAssertEqual(try Data(contentsOf: runFile), runBytes)
            XCTAssertEqual(try Data(contentsOf: exportFile), exportBytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: runDirectory.path))
            XCTAssertNil(store.revision(for: removed.id))
            XCTAssertNil(store.selectedSessionID)
            XCTAssertFalse(try Self.text(storeURL).contains(removed.id.uuidString.lowercased()))
            XCTAssertTrue(try Self.text(storeURL).contains(retained.id.uuidString.lowercased()))
            XCTAssertEqual(
                try ConversationStore(fileURL: storeURL).projects.flatMap(\.sessions).map(\.id),
                [
                    retained.id
                ])
        }

        @MainActor
        private static func envelopeURL(_ store: ConversationStore, _ id: UUID) -> URL {
            store.conversationsDirectory.appendingPathComponent(
                "conversation-\(id.uuidString.lowercased()).json")
        }

        private static func mode(_ url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
        }

        private static func text(_ url: URL) throws -> String {
            try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))
        }

        @MainActor
        private static func allPersistedText(_ store: ConversationStore) throws -> String {
            var values = [try text(store.fileURL)]
            for name in try FileManager.default.contentsOfDirectory(atPath: store.conversationsDirectory.path)
            where name.hasSuffix(".json") {
                values.append(try text(store.conversationsDirectory.appendingPathComponent(name)))
            }
            return values.joined(separator: "\n")
        }

        private static func date(_ interval: TimeInterval) -> Date {
            Date(timeIntervalSince1970: interval)
        }
    }
#endif
