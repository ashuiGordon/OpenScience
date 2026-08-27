import Foundation

/// The complete identity carried by an asynchronous engine result before it may affect the
/// originating workbench turn. It contains no filesystem authority, approval, or grant.
public struct WorkbenchResultIdentity: Equatable, Hashable, Sendable {
    public let conversationID: UUID
    public let turnID: ResearchTurnID
    public let attemptBindingID: AttemptBindingID
    public let requestID: String
    public let planID: String
    public let planSHA256: String
    public let runID: String?
    public let managedRelativeReference: String?

    public init(
        conversationID: UUID,
        turnID: ResearchTurnID,
        attemptBindingID: AttemptBindingID,
        requestID: String,
        planID: String,
        planSHA256: String,
        runID: String? = nil,
        managedRelativeReference: String? = nil
    ) {
        self.conversationID = conversationID
        self.turnID = turnID
        self.attemptBindingID = attemptBindingID
        self.requestID = requestID
        self.planID = planID
        self.planSHA256 = planSHA256
        self.runID = runID
        self.managedRelativeReference = managedRelativeReference
    }

    public init(binding: RunBinding, conversationID: UUID) {
        self.init(
            conversationID: conversationID,
            turnID: binding.turnID,
            attemptBindingID: binding.id,
            requestID: binding.requestID,
            planID: binding.planID,
            planSHA256: binding.planSHA256,
            runID: binding.runID,
            managedRelativeReference: binding.managedRelativeReference)
    }

    public func replacing(
        conversationID: UUID? = nil,
        turnID: ResearchTurnID? = nil,
        attemptBindingID: AttemptBindingID? = nil,
        requestID: String? = nil,
        planID: String? = nil,
        planSHA256: String? = nil,
        runID: String? = nil,
        managedRelativeReference: String? = nil
    ) -> Self {
        Self(
            conversationID: conversationID ?? self.conversationID,
            turnID: turnID ?? self.turnID,
            attemptBindingID: attemptBindingID ?? self.attemptBindingID,
            requestID: requestID ?? self.requestID,
            planID: planID ?? self.planID,
            planSHA256: planSHA256 ?? self.planSHA256,
            runID: runID ?? self.runID,
            managedRelativeReference: managedRelativeReference ?? self.managedRelativeReference)
    }
}

public enum WorkbenchCoordinatorError: LocalizedError, Equatable, Sendable {
    case bindingStale

    public var code: String { "workbench.binding_stale" }

    public var errorDescription: String? {
        "结果与当前对话、研究轮次、计划或运行尝试不匹配，未应用任何更改。"
    }
}

/// Actor-isolated identity adapter between the conversation envelope and feature-002 engine work.
/// This type deliberately owns no process, credential, approval, grant, or run-directory URL.
@MainActor
public final class WorkbenchCoordinator {
    public let store: ConversationStore

    public init(store: ConversationStore) { self.store = store }

    @discardableResult
    public func appendTurn(
        conversationID: UUID,
        message: UserMessage,
        turnID: ResearchTurnID? = nil,
        expectedRevision: Int
    ) throws -> ResearchTurn {
        try store.appendTurn(
            sessionID: conversationID,
            message: message,
            turnID: turnID,
            expectedRevision: expectedRevision)
    }

    @discardableResult
    public func bindPlan(
        conversationID: UUID,
        turnID: ResearchTurnID,
        planReference: PlanReference,
        expectedRevision: Int
    ) throws -> ResearchTurn {
        try store.bindPlan(
            sessionID: conversationID,
            turnID: turnID,
            planReference: planReference,
            expectedRevision: expectedRevision)
    }

    @discardableResult
    public func bindAttempt(
        conversationID: UUID,
        turnID: ResearchTurnID,
        binding: RunBinding,
        expectedRevision: Int
    ) throws -> RunBinding {
        try store.bindAttempt(
            sessionID: conversationID,
            turnID: turnID,
            binding: binding,
            expectedRevision: expectedRevision)
    }

    /// Returns the current exact binding only when every known identity still agrees. Older retry
    /// results and results from a different conversation are intentionally indistinguishable.
    public func validateResult(_ identity: WorkbenchResultIdentity) throws -> RunBinding {
        guard
            let session = store.projects.lazy.flatMap(\.sessions).first(where: {
                $0.id == identity.conversationID
            }),
            let turn = session.turns.first(where: { $0.id == identity.turnID }),
            turn.attemptBindingIDs.last == identity.attemptBindingID,
            let binding = session.bindings.first(where: { $0.id == identity.attemptBindingID }),
            binding.turnID == identity.turnID,
            binding.requestID == identity.requestID,
            binding.planID == identity.planID,
            binding.planSHA256 == identity.planSHA256,
            binding.runID == identity.runID,
            binding.managedRelativeReference == identity.managedRelativeReference,
            let plan = turn.planReference,
            plan.requestID == identity.requestID,
            plan.planID == identity.planID,
            plan.planSHA256 == identity.planSHA256
        else { throw WorkbenchCoordinatorError.bindingStale }
        return binding
    }
}
