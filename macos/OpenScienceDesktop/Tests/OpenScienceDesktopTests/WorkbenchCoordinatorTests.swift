#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceDesktopLogic

    final class WorkbenchCoordinatorTests: XCTestCase {
        private var directory: URL!

        override func setUpWithError() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "openscience-workbench-coordinator-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        override func tearDownWithError() throws {
            try? FileManager.default.removeItem(at: directory)
        }

        @MainActor
        func testExactResultBindingSurvivesSelectionChangeAndRejectsEveryStaleIdentity() throws {
            let store = try ConversationStore(
                fileURL: directory.appendingPathComponent("workspace-v1.json"))
            let project = try store.createProject(title: "P")
            let origin = try store.createSession(projectID: project.id, title: "Origin")
            let other = try store.createSession(projectID: project.id, title: "Other")
            let coordinator = WorkbenchCoordinator(store: store)
            let turn = try coordinator.appendTurn(
                conversationID: origin.id,
                message: UserMessage(text: "Question", createdAt: Self.date(1)),
                expectedRevision: try XCTUnwrap(store.revision(for: origin.id)))
            let plan = try PlanReference(
                requestID: "request-1", planID: "plan-1",
                planSHA256: String(repeating: "d", count: 64))
            _ = try coordinator.bindPlan(
                conversationID: origin.id,
                turnID: turn.id,
                planReference: plan,
                expectedRevision: try XCTUnwrap(store.revision(for: origin.id)))
            let binding = try RunBinding(
                bindingID: AttemptBindingID(), turnID: turn.id, attemptOrdinal: 1,
                runID: "run-1", managedRelativeReference: "run-1",
                requestID: plan.requestID, planID: plan.planID,
                planSHA256: plan.planSHA256, statusHint: .running,
                createdAt: Self.date(2))
            _ = try coordinator.bindAttempt(
                conversationID: origin.id,
                turnID: turn.id,
                binding: binding,
                expectedRevision: try XCTUnwrap(store.revision(for: origin.id)))
            try store.selectSession(other.id)

            let exact = WorkbenchResultIdentity(
                conversationID: origin.id,
                turnID: turn.id,
                attemptBindingID: binding.id,
                requestID: plan.requestID,
                planID: plan.planID,
                planSHA256: plan.planSHA256,
                runID: "run-1",
                managedRelativeReference: "run-1")
            XCTAssertEqual(try coordinator.validateResult(exact), binding)

            let stale: [WorkbenchResultIdentity] = [
                exact.replacing(conversationID: other.id),
                exact.replacing(turnID: ResearchTurnID()),
                exact.replacing(attemptBindingID: AttemptBindingID()),
                exact.replacing(requestID: "request-stale"),
                exact.replacing(planID: "plan-stale"),
                exact.replacing(planSHA256: String(repeating: "e", count: 64)),
                exact.replacing(runID: "run-stale"),
                exact.replacing(managedRelativeReference: "run-stale"),
            ]
            let revision = store.revision(for: origin.id)
            for identity in stale {
                XCTAssertThrowsError(try coordinator.validateResult(identity)) { error in
                    XCTAssertEqual(error as? WorkbenchCoordinatorError, .bindingStale)
                }
            }
            XCTAssertEqual(store.revision(for: origin.id), revision)
        }

        @MainActor
        func testOlderAttemptResultExpiresWhenRetryIsBound() throws {
            let store = try ConversationStore(
                fileURL: directory.appendingPathComponent("workspace-v1.json"))
            let coordinator = WorkbenchCoordinator(store: store)
            let session = try store.createSession(title: "Retry")
            let turn = try coordinator.appendTurn(
                conversationID: session.id,
                message: UserMessage(text: "Question"),
                expectedRevision: try XCTUnwrap(store.revision(for: session.id)))
            let plan = try PlanReference(
                requestID: "request-1", planID: "plan-1",
                planSHA256: String(repeating: "f", count: 64))
            _ = try coordinator.bindPlan(
                conversationID: session.id, turnID: turn.id, planReference: plan,
                expectedRevision: try XCTUnwrap(store.revision(for: session.id)))
            let first = try RunBinding(
                bindingID: AttemptBindingID(), turnID: turn.id, attemptOrdinal: 1,
                runID: "run-1", managedRelativeReference: "run-1",
                requestID: plan.requestID, planID: plan.planID, planSHA256: plan.planSHA256)
            _ = try coordinator.bindAttempt(
                conversationID: session.id, turnID: turn.id, binding: first,
                expectedRevision: try XCTUnwrap(store.revision(for: session.id)))
            let firstResult = WorkbenchResultIdentity(binding: first, conversationID: session.id)
            XCTAssertEqual(try coordinator.validateResult(firstResult), first)

            let retry = try RunBinding(
                bindingID: AttemptBindingID(), turnID: turn.id, attemptOrdinal: 2,
                runID: "run-1", managedRelativeReference: "run-1",
                requestID: plan.requestID, planID: plan.planID, planSHA256: plan.planSHA256)
            _ = try coordinator.bindAttempt(
                conversationID: session.id, turnID: turn.id, binding: retry,
                expectedRevision: try XCTUnwrap(store.revision(for: session.id)))

            XCTAssertThrowsError(try coordinator.validateResult(firstResult)) { error in
                XCTAssertEqual(error as? WorkbenchCoordinatorError, .bindingStale)
            }
            XCTAssertEqual(
                try coordinator.validateResult(
                    WorkbenchResultIdentity(binding: retry, conversationID: session.id)),
                retry)
        }

        private static func date(_ interval: TimeInterval) -> Date {
            Date(timeIntervalSince1970: interval)
        }
    }
#endif
