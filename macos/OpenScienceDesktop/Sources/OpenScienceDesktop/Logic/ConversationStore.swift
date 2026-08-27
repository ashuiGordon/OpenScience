import Combine
import Darwin
import Foundation
import OpenScienceCore

public enum ConversationStoreLimits {
    public static let maximumFileBytes = 8 * 1_024 * 1_024
    public static let maximumWorkspaceBytes = 2 * 1_024 * 1_024
    public static let maximumProjects = 64
    public static let maximumSessionsPerProject = 10_000
    public static let maximumTotalSessions = 10_000
    public static let maximumMessagesPerSession = 1_000
    public static let maximumTotalMessages = 1_000_000
    public static let maximumMessageBytes = 10_000
    public static let maximumMessageCharacters = 10_000
    public static let maximumDraftCharacters = 10_000
    public static let maximumTitleBytes = 512
    public static let maximumReferenceBytes = 4 * 1_024
    public static let maximumArtifactsPerMessage = 256
    public static let maximumLinkedRunsPerSession = 256
}

public enum ConversationStoreError: LocalizedError, Equatable {
    case corruptStore
    case unsupportedSchema(Int)
    case limitExceeded(String, Int)
    case invalidValue(String)
    case notFound(String)
    case revisionConflict(expected: Int, actual: Int)
    case unsafeStoreFile
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .corruptStore: return "会话索引已损坏，原文件未被修改。"
        case let .unsupportedSchema(version): return "不支持会话存储版本 \(version)。"
        case let .limitExceeded(field, limit): return "\(field) 超过限制 \(limit)。"
        case let .invalidValue(field): return "会话数据无效：\(field)。"
        case let .notFound(value): return "未找到会话数据：\(value)。"
        case let .revisionConflict(expected, actual):
            return "会话已更新（期望版本 \(expected)，当前版本 \(actual)）。"
        case .unsafeStoreFile: return "会话存储不是安全的普通文件或目录。"
        case let .ioFailure(message): return "无法保存会话：\(message)"
        }
    }
}

@MainActor
public final class ConversationStore: ObservableObject {
    @Published public private(set) var projects: [ConversationProject]
    @Published public private(set) var selectedProjectID: UUID?
    @Published public private(set) var selectedSessionID: UUID?
    @Published public private(set) var inspectorSelection: InspectorSelection?
    @Published public private(set) var layoutState: ConversationLayoutState
    @Published public private(set) var issues: [ConversationSessionIssue]

    public let fileURL: URL
    public let conversationsDirectory: URL
    public var schemaVersion: Int { 1 }
    private var revisions: [UUID: Int]

    public var selectedProject: ConversationProject? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    public var selectedSession: ConversationSession? {
        guard let selectedSessionID else { return nil }
        return projects.lazy.flatMap(\.sessions).first { $0.id == selectedSessionID }
    }

    public func revision(for sessionID: UUID) -> Int? {
        revisions[sessionID]
    }

    public init(fileURL: URL, loadIfPresent: Bool = true) throws {
        guard fileURL.isFileURL else { throw ConversationStoreError.invalidValue("store URL") }
        let workspace = fileURL.standardizedFileURL
        let envelopes = workspace.deletingLastPathComponent().appendingPathComponent(
            "conversations", isDirectory: true)
        if !loadIfPresent, Self.exists(workspace.path) {
            throw ConversationStoreError.invalidValue("store already exists")
        }
        let loaded = try Self.load(workspace: workspace, envelopes: envelopes, enabled: loadIfPresent)
        self.fileURL = workspace
        conversationsDirectory = envelopes
        projects = loaded.projects
        selectedProjectID = loaded.selectedProjectID
        selectedSessionID = loaded.selectedSessionID
        inspectorSelection = loaded.inspectorSelection
        layoutState = loaded.layoutState
        issues = loaded.issues
        revisions = loaded.revisions
    }

    @discardableResult
    public func createProject(
        title: String,
        now: Date = Date(),
        id: UUID = UUID()
    ) throws -> ConversationProject {
        var next = projects
        guard next.count < ConversationStoreLimits.maximumProjects else {
            throw ConversationStoreError.limitExceeded(
                "projects", ConversationStoreLimits.maximumProjects)
        }
        guard !next.contains(where: { $0.id == id }) else {
            throw ConversationStoreError.invalidValue("duplicate project id")
        }
        let value = ConversationProject(
            id: id,
            title: try Self.title(title, fallback: "OpenScience"),
            createdAt: now,
            updatedAt: now
        )
        next.append(value)
        try commit(next, envelopes: [], projectID: id, sessionID: nil, inspector: nil)
        return value
    }

    @discardableResult
    public func createSession(
        projectID requestedProjectID: UUID? = nil,
        title: String,
        prompt: String? = nil,
        now: Date = Date(),
        id: UUID = UUID()
    ) throws -> ConversationSession {
        var next = projects
        var owner = requestedProjectID ?? selectedProjectID
        if owner == nil {
            guard next.count < ConversationStoreLimits.maximumProjects else {
                throw ConversationStoreError.limitExceeded(
                    "projects", ConversationStoreLimits.maximumProjects)
            }
            let project = ConversationProject(title: "OpenScience", createdAt: now, updatedAt: now)
            next.append(project)
            owner = project.id
        }
        guard let owner, let projectIndex = next.firstIndex(where: { $0.id == owner }),
            !next[projectIndex].isArchived
        else { throw ConversationStoreError.notFound("active project") }
        guard next.lazy.flatMap(\.sessions).count < ConversationStoreLimits.maximumTotalSessions else {
            throw ConversationStoreError.limitExceeded(
                "conversations", ConversationStoreLimits.maximumTotalSessions)
        }
        guard !next.lazy.flatMap(\.sessions).contains(where: { $0.id == id }) else {
            throw ConversationStoreError.invalidValue("duplicate session id")
        }
        let cleanPrompt = prompt.map { Redactor.redact($0) }?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        var messages: [ConversationMessage] = []
        var turns: [ResearchTurn] = []
        if let cleanPrompt, !cleanPrompt.isEmpty {
            try Self.validateUserText(cleanPrompt)
            let user = try UserMessage(text: cleanPrompt, createdAt: now)
            messages.append(Self.conversationMessage(user))
            turns.append(
                try ResearchTurn(message: user, createdAt: now, stateHint: .planning))
        }
        let session = ConversationSession(
            id: id,
            projectID: owner,
            title: try Self.title(
                title, fallback: cleanPrompt.map { String($0.prefix(72)) } ?? "新研究"),
            createdAt: now,
            updatedAt: now,
            messages: messages,
            turns: turns
        )
        next[projectIndex].sessions.append(session)
        next[projectIndex].updatedAt = now
        try commit(next, envelopes: [id], projectID: owner, sessionID: id, inspector: nil)
        return session
    }

    @discardableResult
    public func appendMessage(
        sessionID: UUID,
        role: ConversationRole,
        kind: MessageKind,
        text: String,
        runReference: ConversationRunReference? = nil,
        artifactReferences: [ConversationArtifactReference] = [],
        timestamp: Date = Date(),
        id: UUID = UUID(),
        expectedRevision: Int? = nil
    ) throws -> ConversationMessage {
        if role == .user {
            guard kind == .text, runReference == nil, artifactReferences.isEmpty else {
                throw ConversationStoreError.invalidValue("user message kind/references")
            }
            guard let revision = expectedRevision ?? revisions[sessionID] else {
                throw ConversationStoreError.notFound("session revision")
            }
            let turn = try appendTurn(
                sessionID: sessionID,
                message: UserMessage(
                    id: UserMessageID(uuid: id), text: text, createdAt: timestamp),
                expectedRevision: revision)
            return Self.conversationMessage(turn.message)
        }
        try checkRevision(sessionID, expected: expectedRevision)
        var next = projects
        let location = try Self.location(sessionID, in: next)
        let candidate = ConversationMessage(
            id: id,
            role: role,
            kind: kind,
            text: text,
            timestamp: timestamp,
            runReference: runReference,
            artifactReferences: artifactReferences
        )
        if let existing = next.lazy.flatMap(\.sessions).flatMap(\.messages).first(where: {
            $0.id == id
        }) {
            guard existing == candidate else {
                throw ConversationStoreError.invalidValue("conflicting duplicate message id")
            }
            return existing
        }
        next[location.project].sessions[location.session].messages.append(candidate)
        Self.merge(runReference, artifactReferences, into: &next[location.project].sessions[location.session])
        try Self.validate(next)
        projects = next
        return candidate
    }

    /// Atomically appends one immutable user-authored research turn. Replaying the exact same
    /// message ID is idempotent even when the caller still holds the pre-commit revision.
    @discardableResult
    public func appendTurn(
        sessionID: UUID,
        message: UserMessage,
        turnID: ResearchTurnID? = nil,
        stateHint: TurnStateHint = .planning,
        expectedRevision: Int
    ) throws -> ResearchTurn {
        let currentLocation = try Self.location(sessionID, in: projects)
        if let existing = projects.lazy.flatMap(\.sessions).flatMap(\.turns).first(where: {
            $0.message.id == message.id
        }) {
            guard
                projects[currentLocation.project].sessions[currentLocation.session].turns.contains(
                    where: { $0.id == existing.id }),
                existing.message == message,
                turnID == nil || existing.id == turnID
            else {
                throw ConversationStoreError.invalidValue("conflicting duplicate message id")
            }
            return existing
        }
        try checkRevision(sessionID, expected: expectedRevision)
        var next = projects
        let location = try Self.location(sessionID, in: next)
        let turn = try ResearchTurn(
            id: turnID ?? ResearchTurnID(),
            message: message,
            createdAt: message.createdAt,
            stateHint: stateHint)
        guard !next.lazy.flatMap(\.sessions).flatMap(\.turns).contains(where: { $0.id == turn.id }) else {
            throw ConversationStoreError.invalidValue("duplicate turn id")
        }
        next[location.project].sessions[location.session].turns.append(turn)
        next[location.project].sessions[location.session].messages.append(
            Self.conversationMessage(message))
        let updatedAt = max(
            next[location.project].sessions[location.session].updatedAt, message.createdAt)
        next[location.project].sessions[location.session].updatedAt = updatedAt
        next[location.project].updatedAt = max(next[location.project].updatedAt, updatedAt)
        try commitCurrent(next, envelopes: [sessionID])
        return turn
    }

    @discardableResult
    public func bindPlan(
        sessionID: UUID,
        turnID: ResearchTurnID,
        planReference: PlanReference,
        expectedRevision: Int
    ) throws -> ResearchTurn {
        try checkRevision(sessionID, expected: expectedRevision)
        var next = projects
        let location = try Self.location(sessionID, in: next)
        guard
            let index = next[location.project].sessions[location.session].turns.firstIndex(
                where: { $0.id == turnID })
        else { throw ConversationStoreError.notFound("research turn") }
        guard next[location.project].sessions[location.session].turns[index].attemptBindingIDs.isEmpty
        else { throw ConversationStoreError.invalidValue("plan already has attempts") }
        if let existing = next[location.project].sessions[location.session].turns[index].planReference,
            existing != planReference
        {
            throw ConversationStoreError.invalidValue("conflicting plan binding")
        }
        next[location.project].sessions[location.session].turns[index].planReference = planReference
        next[location.project].sessions[location.session].turns[index].stateHint = .awaitingPlanApproval
        next[location.project].sessions[location.session].status = .awaitingApproval
        let timestamp = Date()
        next[location.project].sessions[location.session].updatedAt = timestamp
        next[location.project].updatedAt = timestamp
        try commitCurrent(next, envelopes: [sessionID])
        return next[location.project].sessions[location.session].turns[index]
    }

    @discardableResult
    public func bindAttempt(
        sessionID: UUID,
        turnID: ResearchTurnID,
        binding: RunBinding,
        expectedRevision: Int
    ) throws -> RunBinding {
        try checkRevision(sessionID, expected: expectedRevision)
        var next = projects
        let location = try Self.location(sessionID, in: next)
        guard binding.turnID == turnID,
            let turnIndex = next[location.project].sessions[location.session].turns.firstIndex(
                where: { $0.id == turnID })
        else { throw ConversationStoreError.invalidValue("attempt turn identity") }
        let turn = next[location.project].sessions[location.session].turns[turnIndex]
        guard let plan = turn.planReference,
            binding.requestID == plan.requestID,
            binding.planID == plan.planID,
            binding.planSHA256 == plan.planSHA256
        else { throw ConversationStoreError.invalidValue("attempt plan identity") }
        let sessionBindings = next[location.project].sessions[location.session].bindings
        if let existing = next.lazy.flatMap(\.sessions).flatMap(\.bindings).first(where: {
            $0.id == binding.id
        }) {
            guard
                let bindingIndex = sessionBindings.firstIndex(where: { $0.id == binding.id }),
                existing.turnID == binding.turnID,
                existing.attemptOrdinal == binding.attemptOrdinal,
                existing.requestID == binding.requestID,
                existing.planID == binding.planID,
                existing.planSHA256 == binding.planSHA256,
                existing.createdAt == binding.createdAt,
                existing.runID == nil || existing.runID == binding.runID,
                existing.managedRelativeReference == nil
                    || existing.managedRelativeReference == binding.managedRelativeReference
            else { throw ConversationStoreError.invalidValue("conflicting attempt binding id") }
            next[location.project].sessions[location.session].bindings[bindingIndex] = binding
        } else {
            let attempts = sessionBindings.filter { $0.turnID == turnID }
            guard binding.attemptOrdinal == attempts.count + 1 else {
                throw ConversationStoreError.invalidValue("attempt ordinal")
            }
            next[location.project].sessions[location.session].bindings.append(binding)
            next[location.project].sessions[location.session].turns[turnIndex].attemptBindingIDs.append(
                binding.id)
        }
        next[location.project].sessions[location.session].turns[turnIndex].stateHint = TurnStateHint(
            sessionStatus: binding.statusHint)
        next[location.project].sessions[location.session].status = binding.statusHint
        let updatedAt = max(
            next[location.project].sessions[location.session].updatedAt, binding.createdAt)
        next[location.project].sessions[location.session].updatedAt = updatedAt
        next[location.project].updatedAt = max(next[location.project].updatedAt, updatedAt)
        if let runID = binding.runID {
            Self.merge(
                ConversationRunReference(runID: runID, status: .unknown), [],
                into: &next[location.project].sessions[location.session])
        }
        try commitCurrent(next, envelopes: [sessionID])
        return binding
    }

    @discardableResult
    public func updateMessage(
        sessionID: UUID,
        messageID: UUID,
        kind: MessageKind,
        text: String,
        runReference: ConversationRunReference? = nil,
        artifactReferences: [ConversationArtifactReference] = [],
        timestamp: Date = Date(),
        expectedRevision: Int? = nil
    ) throws -> ConversationMessage {
        try checkRevision(sessionID, expected: expectedRevision)
        var next = projects
        let location = try Self.location(sessionID, in: next)
        guard
            let index = next[location.project].sessions[location.session].messages.firstIndex(
                where: { $0.id == messageID })
        else { throw ConversationStoreError.notFound("message") }
        let old = next[location.project].sessions[location.session].messages[index]
        guard old.role != .user else {
            throw ConversationStoreError.invalidValue("immutable user message")
        }
        let value = ConversationMessage(
            id: old.id,
            role: old.role,
            kind: kind,
            text: text,
            timestamp: timestamp,
            runReference: runReference,
            artifactReferences: artifactReferences
        )
        next[location.project].sessions[location.session].messages[index] = value
        Self.merge(runReference, artifactReferences, into: &next[location.project].sessions[location.session])
        try Self.validate(next)
        projects = next
        return value
    }

    public func draft(for sessionID: UUID) throws -> ConversationDraft? {
        let at = try Self.location(sessionID, in: projects)
        return projects[at.project].sessions[at.session].draft
    }

    @discardableResult
    public func setDraft(
        sessionID: UUID,
        draft: ConversationDraft?,
        expectedRevision: Int? = nil
    ) throws -> ConversationSession {
        try checkRevision(sessionID, expected: expectedRevision)
        var next = projects
        let at = try Self.location(sessionID, in: next)
        if let draft { try Self.validateDraft(draft) }
        next[at.project].sessions[at.session].draft = draft
        let date = draft?.updatedAt ?? Date()
        next[at.project].sessions[at.session].updatedAt = date
        next[at.project].updatedAt = date
        try commitCurrent(next, envelopes: [sessionID])
        return next[at.project].sessions[at.session]
    }

    @discardableResult
    public func setDraftText(
        sessionID: UUID,
        text: String,
        updatedAt: Date = Date(),
        expectedRevision: Int? = nil
    ) throws -> ConversationSession {
        let old = try draft(for: sessionID)
        return try setDraft(
            sessionID: sessionID,
            draft: ConversationDraft(
                text: text,
                scope: old?.scope ?? "",
                constraints: old?.constraints ?? [],
                assumptions: old?.assumptions ?? [],
                sourceNames: old?.sourceNames ?? [],
                synthesisName: old?.synthesisName ?? "extractive",
                localRootHints: old?.localRootHints ?? [],
                fixtureHints: old?.fixtureHints ?? [],
                maxRecords: old?.maxRecords ?? 50,
                maxNetworkRequests: old?.maxNetworkRequests ?? 10,
                timeoutSeconds: old?.timeoutSeconds ?? 300,
                contactEmail: old?.contactEmail ?? "",
                updatedAt: updatedAt
            ),
            expectedRevision: expectedRevision)
    }

    @discardableResult
    public func setSessionStatus(
        sessionID: UUID,
        status: SessionStatus,
        linkedRunID: String? = nil,
        updatedAt: Date = Date(),
        expectedRevision: Int? = nil
    ) throws -> ConversationSession {
        try checkRevision(sessionID, expected: expectedRevision)
        var next = projects
        let at = try Self.location(sessionID, in: next)
        next[at.project].sessions[at.session].status = status
        next[at.project].sessions[at.session].updatedAt = updatedAt
        if let linkedRunID {
            let id = try Self.reference(linkedRunID, field: "run id")
            Self.merge(
                ConversationRunReference(runID: id, status: .unknown), [],
                into: &next[at.project].sessions[at.session])
        }
        next[at.project].updatedAt = updatedAt
        try commitCurrent(next, envelopes: [sessionID])
        return next[at.project].sessions[at.session]
    }

    public func renameProject(_ projectID: UUID, title: String, now: Date = Date()) throws {
        var next = projects
        guard let index = next.firstIndex(where: { $0.id == projectID }) else {
            throw ConversationStoreError.notFound("project")
        }
        next[index].title = try Self.title(title, fallback: "OpenScience")
        next[index].updatedAt = now
        try commitCurrent(next, envelopes: [])
    }

    public func renameSession(
        _ sessionID: UUID,
        title: String,
        now: Date = Date(),
        expectedRevision: Int? = nil
    ) throws {
        try checkRevision(sessionID, expected: expectedRevision)
        var next = projects
        let at = try Self.location(sessionID, in: next)
        next[at.project].sessions[at.session].title = try Self.title(title, fallback: "新研究")
        next[at.project].sessions[at.session].updatedAt = now
        next[at.project].updatedAt = now
        try commitCurrent(next, envelopes: [sessionID])
    }

    public func archiveProject(
        _ projectID: UUID,
        archived: Bool = true,
        now: Date = Date()
    ) throws {
        var next = projects
        guard let index = next.firstIndex(where: { $0.id == projectID }) else {
            throw ConversationStoreError.notFound("project")
        }
        next[index].isArchived = archived
        next[index].updatedAt = now
        try commit(
            next,
            envelopes: [],
            projectID: archived && selectedProjectID == projectID ? nil : selectedProjectID,
            sessionID: archived && selectedProjectID == projectID ? nil : selectedSessionID,
            inspector: archived && selectedProjectID == projectID ? nil : inspectorSelection
        )
    }

    public func archiveSession(
        _ sessionID: UUID,
        archived: Bool = true,
        now: Date = Date(),
        expectedRevision: Int? = nil
    ) throws {
        try checkRevision(sessionID, expected: expectedRevision)
        var next = projects
        let at = try Self.location(sessionID, in: next)
        next[at.project].sessions[at.session].isArchived = archived
        next[at.project].sessions[at.session].updatedAt = now
        next[at.project].updatedAt = now
        let clear = archived && selectedSessionID == sessionID
        try commit(
            next,
            envelopes: [sessionID],
            projectID: selectedProjectID,
            sessionID: clear ? nil : selectedSessionID,
            inspector: clear ? nil : inspectorSelection
        )
    }

    /// Deletes only the internally named conversation metadata envelope and workspace/index row.
    /// It accepts no path and never resolves, mutates, or removes a run/export reference.
    public func deleteSessionMetadata(
        _ sessionID: UUID,
        expectedRevision: Int? = nil
    ) throws {
        try checkRevision(sessionID, expected: expectedRevision)
        var next = projects
        let at = try Self.location(sessionID, in: next)
        next[at.project].sessions.remove(at: at.session)
        next[at.project].updatedAt = Date()
        let clearsSelection = selectedSessionID == sessionID
        let source = conversationsDirectory.appendingPathComponent(
            "\(Self.conversationID(sessionID)).json")
        let staged = conversationsDirectory.appendingPathComponent(
            ".\(Self.conversationID(sessionID)).\(UUID().uuidString.lowercased()).delete")
        try Self.stageMetadataDeletion(source: source, staged: staged)
        do {
            try commit(
                next,
                envelopes: [],
                projectID: selectedProjectID,
                sessionID: clearsSelection ? nil : selectedSessionID,
                inspector: clearsSelection ? nil : inspectorSelection)
        } catch {
            do {
                try Self.restoreStagedDeletion(source: source, staged: staged)
            } catch let rollbackError {
                throw ConversationStoreError.ioFailure(
                    "workspace update failed; metadata rollback also failed: \(rollbackError.localizedDescription)"
                )
            }
            throw error
        }
        guard unlink(staged.path) == 0 else {
            throw ConversationStoreError.ioFailure(Self.errnoText())
        }
        Self.syncDirectory(conversationsDirectory)
        revisions.removeValue(forKey: sessionID)
    }

    public func select(projectID: UUID?, sessionID: UUID?) throws {
        if let projectID {
            guard let project = projects.first(where: { $0.id == projectID }), !project.isArchived else {
                throw ConversationStoreError.notFound("selectable project")
            }
            if let sessionID {
                guard project.sessions.contains(where: { $0.id == sessionID && !$0.isArchived }) else {
                    throw ConversationStoreError.notFound("selectable session")
                }
            }
        } else if sessionID != nil {
            throw ConversationStoreError.invalidValue("session without project")
        }
        try commit(
            projects,
            envelopes: [],
            projectID: projectID,
            sessionID: sessionID,
            inspector: inspectorSelection?.sessionID == sessionID ? inspectorSelection : nil
        )
    }

    public func selectSession(_ sessionID: UUID?) throws {
        guard let sessionID else {
            return try select(projectID: selectedProjectID, sessionID: nil)
        }
        guard
            let owner = projects.first(where: {
                $0.sessions.contains(where: { $0.id == sessionID })
            })
        else { throw ConversationStoreError.notFound("session") }
        try select(projectID: owner.id, sessionID: sessionID)
    }

    public func selectInspector(_ selection: InspectorSelection?) throws {
        if let selection { _ = try Self.location(selection.sessionID, in: projects) }
        let nextLayout =
            selection.map {
                ConversationLayoutState(
                    selectedPreviewTab: $0.tab,
                    sidebarVisibility: layoutState.sidebarVisibility,
                    previewVisibility: layoutState.previewVisibility,
                    sidebarWidth: layoutState.sidebarWidth,
                    previewWidth: layoutState.previewWidth)
            } ?? layoutState
        try commit(
            projects,
            envelopes: [],
            projectID: selectedProjectID,
            sessionID: selectedSessionID,
            inspector: selection,
            layout: nextLayout
        )
    }

    public func setLayoutState(_ state: ConversationLayoutState) throws {
        try commit(
            projects,
            envelopes: [],
            projectID: selectedProjectID,
            sessionID: selectedSessionID,
            inspector: inspectorSelection,
            layout: state)
    }

    public func search(
        _ query: String,
        includeArchived: Bool = false
    ) -> [ConversationSearchResult] {
        let needle = Self.normalized(query)
        var results: [ConversationSearchResult] = []
        for project in projects where includeArchived || !project.isArchived {
            for session in project.sessions where includeArchived || !session.isArchived {
                let fields =
                    [project.title, session.title]
                    + session.messages.filter { $0.role == .user }.map(\.text)
                    + session.linkedRunIDs
                if needle.isEmpty || fields.contains(where: { Self.normalized($0).contains(needle) }) {
                    results.append(ConversationSearchResult(project: project, session: session))
                }
            }
        }
        return results.sorted {
            $0.session.updatedAt == $1.session.updatedAt
                ? $0.session.id.uuidString < $1.session.id.uuidString
                : $0.session.updatedAt > $1.session.updatedAt
        }
    }

    public func groupedSessions(
        projectID: UUID,
        referenceDate: Date = Date(),
        calendar: Calendar = .current,
        includeArchived: Bool = false
    ) throws -> [ConversationSessionGroup] {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw ConversationStoreError.notFound("project")
        }
        let values = Dictionary(grouping: project.sessions.filter { includeArchived || !$0.isArchived }) {
            Self.bucket($0.updatedAt, reference: referenceDate, calendar: calendar)
        }
        return ConversationDateBucket.allCases.compactMap { bucket in
            values[bucket].map {
                ConversationSessionGroup(
                    bucket: bucket,
                    sessions: $0.sorted { $0.updatedAt > $1.updatedAt })
            }
        }
    }

    @discardableResult
    public func importRun(
        _ run: RunListItem,
        projectID: UUID? = nil
    ) throws -> ConversationSession {
        let id = try Self.reference(run.runID, field: "run id")
        if let existing = projects.lazy.flatMap(\.sessions).first(where: {
            $0.linkedRunIDs.contains(id)
        }) {
            _ = try setSessionStatus(
                sessionID: existing.id,
                status: SessionStatus(runStatus: run.status),
                linkedRunID: id,
                updatedAt: run.updatedAt)
            let card = Self.runCard(run)
            if let old = projects.lazy.flatMap(\.sessions).first(where: { $0.id == existing.id })?
                .messages.first(where: { $0.runReference?.runID == id })
            {
                _ = try updateMessage(
                    sessionID: existing.id,
                    messageID: old.id,
                    kind: card.kind,
                    text: card.text,
                    runReference: card.runReference,
                    timestamp: run.updatedAt)
            } else {
                _ = try appendMessage(
                    sessionID: existing.id,
                    role: .assistant,
                    kind: card.kind,
                    text: card.text,
                    runReference: card.runReference,
                    timestamp: run.updatedAt)
            }
            return projects.lazy.flatMap(\.sessions).first(where: { $0.id == existing.id })!
        }
        let session = try createSession(
            projectID: projectID,
            title: run.question,
            prompt: run.question,
            now: run.updatedAt)
        _ = try setSessionStatus(
            sessionID: session.id,
            status: SessionStatus(runStatus: run.status),
            linkedRunID: id,
            updatedAt: run.updatedAt)
        let card = Self.runCard(run)
        _ = try appendMessage(
            sessionID: session.id,
            role: .assistant,
            kind: card.kind,
            text: card.text,
            runReference: card.runReference,
            timestamp: run.updatedAt)
        return projects.lazy.flatMap(\.sessions).first(where: { $0.id == session.id })!
    }

    public func save() throws {
        try commitCurrent(projects, envelopes: Set(projects.lazy.flatMap(\.sessions).map(\.id)))
    }

    private func commitCurrent(_ next: [ConversationProject], envelopes: Set<UUID>) throws {
        try commit(
            next,
            envelopes: envelopes,
            projectID: selectedProjectID,
            sessionID: selectedSessionID,
            inspector: inspectorSelection)
    }

    private func checkRevision(_ sessionID: UUID, expected: Int?) throws {
        guard let expected else { return }
        guard let actual = revisions[sessionID] else {
            throw ConversationStoreError.notFound("session revision")
        }
        guard actual == expected else {
            throw ConversationStoreError.revisionConflict(expected: expected, actual: actual)
        }
    }

    private func commit(
        _ next: [ConversationProject],
        envelopes: Set<UUID>,
        projectID: UUID?,
        sessionID: UUID?,
        inspector: InspectorSelection?,
        layout: ConversationLayoutState? = nil
    ) throws {
        try Self.validate(next)
        var nextRevisions = revisions
        for id in envelopes.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let session = next.lazy.flatMap(\.sessions).first(where: { $0.id == id }) else {
                throw ConversationStoreError.notFound("envelope session")
            }
            let revision = (nextRevisions[id] ?? 0) + 1
            try Self.writeEnvelope(
                try Self.envelope(session, revision: revision),
                id: id,
                directory: conversationsDirectory)
            nextRevisions[id] = revision
        }
        let nextLayout = layout ?? layoutState
        let persistedInspector = Self.persistableInspector(inspector, in: next)
        try Self.writeWorkspace(
            WorkspaceFile(
                projects: next.map(ProjectFile.init),
                selectedProjectID: projectID,
                selectedSessionID: sessionID,
                inspectorSelection: persistedInspector,
                layoutState: nextLayout,
                conversationIDs: next.lazy.flatMap(\.sessions).map(\.id)),
            url: fileURL)
        projects = next
        selectedProjectID = projectID
        selectedSessionID = sessionID
        inspectorSelection = inspector
        layoutState = nextLayout
        revisions = nextRevisions
    }

    private static func load(
        workspace: URL,
        envelopes: URL,
        enabled: Bool
    ) throws -> LoadedStore {
        try directory(workspace.deletingLastPathComponent())
        try directory(envelopes)
        try cleanupStagedDeletions(in: envelopes)
        var discoveredNames = try names(envelopes)
        var index = WorkspaceFile.empty
        var migrationIssue: ConversationSessionIssue?
        var recoveryIssue: ConversationSessionIssue?
        var rebuildWorkspace = false
        if enabled, exists(workspace.path) {
            do {
                let data = try read(workspace, max: ConversationStoreLimits.maximumWorkspaceBytes)
                if let version = declaredSchema(in: data), version > 1 {
                    throw ConversationStoreError.unsupportedSchema(version)
                }
                if Self.isWorkspace(data) {
                    do {
                        index = try decodeWorkspace(data)
                    } catch ConversationStoreError.unsupportedSchema(let version) {
                        throw ConversationStoreError.unsupportedSchema(version)
                    } catch {
                        rebuildWorkspace = true
                    }
                } else if let legacy = try? decodeLegacy(data) {
                    index = try migrate(legacy, workspace: workspace, envelopes: envelopes)
                    discoveredNames = try names(envelopes)
                    migrationIssue = ConversationSessionIssue(
                        code: "conversation.migrated_v1",
                        envelopeName: workspace.lastPathComponent,
                        outcome: "旧版单文件会话已迁移。",
                        safeDetail: "助手投影未复制。")
                } else {
                    rebuildWorkspace = true
                }
            } catch ConversationStoreError.unsupportedSchema(let version) {
                throw ConversationStoreError.unsupportedSchema(version)
            } catch ConversationStoreError.unsafeStoreFile {
                throw ConversationStoreError.unsafeStoreFile
            } catch {
                rebuildWorkspace = true
            }
            if rebuildWorkspace {
                recoveryIssue = ConversationSessionIssue(
                    code: "conversation.workspace_corrupt_rebuilt",
                    envelopeName: workspace.lastPathComponent,
                    outcome: "工作区索引已忽略，并从独立会话 envelope 重建。",
                    safeDetail: "损坏或超限的工作区状态未被信任。")
            }
        } else if enabled, !discoveredNames.isEmpty {
            rebuildWorkspace = true
            recoveryIssue = ConversationSessionIssue(
                code: "conversation.workspace_missing_rebuilt",
                envelopeName: workspace.lastPathComponent,
                outcome: "缺失的工作区索引已从独立会话 envelope 重建。",
                safeDetail: "选择与布局已安全重置。")
        }
        guard index.schemaVersion == 1 else {
            throw ConversationStoreError.unsupportedSchema(index.schemaVersion)
        }
        var projects = try index.projects.map { try $0.value }
        var problems = [migrationIssue, recoveryIssue].compactMap { $0 }
        var revisions: [UUID: Int] = [:]
        for name in discoveredNames {
            do {
                let value = try loadEnvelope(envelopes.appendingPathComponent(name), name: name)
                var session = try value.value
                if [.planning, .awaitingApproval, .running].contains(session.status) {
                    session.status = .unknown
                }
                revisions[session.id] = value.revision
                if let p = projects.firstIndex(where: { $0.id == session.projectID }) {
                    projects[p].sessions.append(session)
                } else {
                    projects.append(
                        ConversationProject(
                            id: session.projectID,
                            title: "Recovered project",
                            createdAt: session.createdAt,
                            updatedAt: session.updatedAt,
                            sessions: [session]))
                }
            } catch let error as ConversationStoreError {
                let code: String
                if case .unsupportedSchema = error {
                    code = "conversation.schema_newer"
                } else {
                    code = "conversation.corrupt"
                }
                problems.append(
                    ConversationSessionIssue(
                        code: code,
                        envelopeName: name,
                        outcome: "该会话已隔离；其他会话仍可使用。",
                        safeDetail: error.localizedDescription))
            }
        }
        try validate(projects)
        let sessionIDs = Set(projects.lazy.flatMap(\.sessions).map(\.id))
        let discoveredIDs = Set(
            discoveredNames.compactMap { name -> UUID? in
                let raw = String(name.dropFirst("conversation-".count).dropLast(".json".count))
                return UUID(uuidString: raw)
            })
        if Set(index.conversationIDs) != discoveredIDs {
            if !rebuildWorkspace {
                problems.append(
                    ConversationSessionIssue(
                        code: "conversation.workspace_stale_rebuilt",
                        envelopeName: workspace.lastPathComponent,
                        outcome: "工作区索引与独立 envelope 不一致，已安全重建。",
                        safeDetail: "缺失或孤立的索引引用未被当作文件系统授权。"))
            }
            rebuildWorkspace = true
        }
        let selectedSession = index.selectedSessionID.flatMap { sessionIDs.contains($0) ? $0 : nil }
        let selectedProject =
            selectedSession.flatMap { id in
                projects.first(where: { $0.sessions.contains(where: { $0.id == id }) })?.id
            }
            ?? index.selectedProjectID.flatMap { id in
                projects.contains(where: { $0.id == id && !$0.isArchived }) ? id : nil
            }
        if rebuildWorkspace {
            index = WorkspaceFile(
                projects: projects.map(ProjectFile.init),
                selectedProjectID: selectedProject,
                selectedSessionID: selectedSession,
                inspectorSelection: index.inspectorSelection.flatMap {
                    sessionIDs.contains($0.sessionID) ? $0 : nil
                },
                layoutState: recoveryIssue == nil ? index.layoutState : ConversationLayoutState(),
                conversationIDs: projects.lazy.flatMap(\.sessions).map(\.id))
            try writeWorkspace(index, url: workspace)
        }
        return LoadedStore(
            projects: projects,
            selectedProjectID: selectedProject,
            selectedSessionID: selectedSession,
            inspectorSelection: index.inspectorSelection.flatMap {
                sessionIDs.contains($0.sessionID) ? $0 : nil
            },
            layoutState: index.layoutState,
            issues: problems.sorted { $0.envelopeName < $1.envelopeName },
            revisions: revisions)
    }

    private static func migrate(
        _ legacy: ConversationStoreSnapshot,
        workspace: URL,
        envelopes: URL
    ) throws -> WorkspaceFile {
        guard legacy.schemaVersion == 1 else {
            throw ConversationStoreError.unsupportedSchema(legacy.schemaVersion)
        }
        for project in legacy.projects {
            for original in project.sessions {
                var session = original
                let all = session.messages
                session.messages = all.filter { $0.role == .user }
                for message in all where message.role != .user {
                    merge(message.runReference, message.artifactReferences, into: &session)
                }
                try writeEnvelope(try envelope(session, revision: 1), id: session.id, directory: envelopes)
            }
        }
        let workspaceValue = WorkspaceFile(
            projects: legacy.projects.map(ProjectFile.init),
            selectedProjectID: legacy.selectedProjectID,
            selectedSessionID: legacy.selectedSessionID,
            inspectorSelection: persistableInspector(
                legacy.inspectorSelection, in: legacy.projects),
            layoutState: ConversationLayoutState(
                selectedPreviewTab: legacy.inspectorSelection?.tab ?? .context),
            conversationIDs: legacy.projects.lazy.flatMap(\.sessions).map(\.id))
        try writeWorkspace(workspaceValue, url: workspace)
        return workspaceValue
    }

    private static func envelope(_ session: ConversationSession, revision: Int) throws -> EnvelopeFile {
        let turns = try canonicalTurns(session)
        let runIDs = unique(
            session.linkedRunIDs + session.runReferences.map(\.runID)
                + session.messages.compactMap { $0.runReference?.runID }
                + session.bindings.compactMap(\.runID))
        let artifacts = uniqueArtifacts(
            session.artifactReferences + session.messages.flatMap(\.artifactReferences))
        return EnvelopeFile(
            revision: revision,
            conversation: ConversationFile(session),
            turns: turns,
            bindings: session.bindings,
            draft: session.draft,
            runReferences: try runIDs.map { RunIDFile(runID: try reference($0, field: "run id")) },
            artifactReferences: try artifacts.map {
                ArtifactIDFile(artifactID: try reference($0.id, field: "artifact id"), kind: $0.kind)
            })
    }

    private static func writeEnvelope(_ value: EnvelopeFile, id: UUID, directory: URL) throws {
        guard value.conversation.conversationID == conversationID(id) else {
            throw ConversationStoreError.invalidValue("envelope identity")
        }
        try validateEnvelope(value)
        try atomic(
            try encoded(value, max: ConversationStoreLimits.maximumFileBytes),
            to: directory.appendingPathComponent("\(conversationID(id)).json"))
    }

    private static func writeWorkspace(_ value: WorkspaceFile, url: URL) throws {
        try atomic(try encoded(value, max: ConversationStoreLimits.maximumWorkspaceBytes), to: url)
    }

    private static func loadEnvelope(_ url: URL, name: String) throws -> EnvelopeFile {
        let data = try read(url, max: ConversationStoreLimits.maximumFileBytes)
        let version = try schema(data)
        guard version == 1 else { throw ConversationStoreError.unsupportedSchema(version) }
        let value: EnvelopeFile
        do { value = try jsonDecoder().decode(EnvelopeFile.self, from: data) } catch {
            throw ConversationStoreError.corruptStore
        }
        guard name == "\(value.conversation.conversationID).json" else {
            throw ConversationStoreError.invalidValue("filename identity")
        }
        try validateEnvelope(value)
        _ = try value.value
        return value
    }

    private static func validateEnvelope(_ value: EnvelopeFile) throws {
        guard value.schemaVersion == 1, value.revision >= 0 else {
            throw ConversationStoreError.invalidValue("envelope version/revision")
        }
        _ = try parse(value.conversation.conversationID, prefix: "conversation-")
        _ = try parse(value.conversation.projectID, prefix: "project-")
        try text(value.conversation.title, field: "conversation title", limit: 512)
        guard value.turns.count <= ConversationStoreLimits.maximumMessagesPerSession,
            value.userMessages.count <= ConversationStoreLimits.maximumMessagesPerSession
        else {
            throw ConversationStoreError.limitExceeded(
                "research turns", ConversationStoreLimits.maximumMessagesPerSession)
        }
        guard value.turns.isEmpty || value.userMessages.isEmpty else {
            throw ConversationStoreError.invalidValue("ambiguous turn encoding")
        }
        var legacyMessageIDs = Set<UUID>()
        for message in value.userMessages {
            guard legacyMessageIDs.insert(message.id).inserted else {
                throw ConversationStoreError.invalidValue("duplicate user message")
            }
            try validateUserText(message.text)
        }
        var turnIDs = Set<ResearchTurnID>()
        var messageIDs = Set<UserMessageID>()
        for turn in value.turns {
            guard turnIDs.insert(turn.id).inserted, messageIDs.insert(turn.message.id).inserted else {
                throw ConversationStoreError.invalidValue("duplicate turn/message identity")
            }
            try validateUserText(turn.message.text)
        }
        let bindingIDs = value.bindings.map(\.id)
        guard Set(bindingIDs).count == bindingIDs.count else {
            throw ConversationStoreError.invalidValue("duplicate attempt binding id")
        }
        for turn in value.turns {
            let bindings = value.bindings.filter { $0.turnID == turn.id }
            guard bindings.map(\.id) == turn.attemptBindingIDs,
                bindings.enumerated().allSatisfy({ pair in
                    pair.offset + 1 == pair.element.attemptOrdinal
                })
            else { throw ConversationStoreError.invalidValue("turn attempt relationship") }
            for binding in bindings {
                guard let plan = turn.planReference,
                    binding.requestID == plan.requestID,
                    binding.planID == plan.planID,
                    binding.planSHA256 == plan.planSHA256
                else { throw ConversationStoreError.invalidValue("attempt plan identity") }
            }
        }
        guard value.bindings.allSatisfy({ turnIDs.contains($0.turnID) }) else {
            throw ConversationStoreError.invalidValue("orphan attempt binding")
        }
        if let draft = value.draft { try validateDraft(draft) }
        let runIDs = value.runReferences.map(\.runID)
        guard Set(runIDs).count == runIDs.count else {
            throw ConversationStoreError.invalidValue("duplicate run id")
        }
        for id in runIDs { _ = try reference(id, field: "run id") }
        let artifactIDs = value.artifactReferences.map(\.artifactID)
        guard Set(artifactIDs).count == artifactIDs.count else {
            throw ConversationStoreError.invalidValue("duplicate artifact id")
        }
        for id in artifactIDs { _ = try reference(id, field: "artifact id") }
    }

    private static func validate(_ projects: [ConversationProject]) throws {
        guard projects.count <= ConversationStoreLimits.maximumProjects else {
            throw ConversationStoreError.limitExceeded("projects", ConversationStoreLimits.maximumProjects)
        }
        var sessions = Set<UUID>()
        var messages = Set<UUID>()
        var turnIDs = Set<ResearchTurnID>()
        var userMessageIDs = Set<UserMessageID>()
        var bindingIDs = Set<AttemptBindingID>()
        for project in projects {
            try text(project.title, field: "project title", limit: 512)
            for session in project.sessions {
                guard session.projectID == project.id, sessions.insert(session.id).inserted else {
                    throw ConversationStoreError.invalidValue("session identity")
                }
                try text(session.title, field: "session title", limit: 512)
                guard session.messages.count <= ConversationStoreLimits.maximumMessagesPerSession else {
                    throw ConversationStoreError.limitExceeded(
                        "messages", ConversationStoreLimits.maximumMessagesPerSession)
                }
                for message in session.messages {
                    guard messages.insert(message.id).inserted else {
                        throw ConversationStoreError.invalidValue("duplicate message")
                    }
                    if message.role == .user {
                        try validateUserText(message.text)
                    } else if message.text.utf8.count > 64 * 1_024 {
                        throw ConversationStoreError.limitExceeded("transient message", 64 * 1_024)
                    }
                    guard
                        message.artifactReferences.count
                            <= ConversationStoreLimits.maximumArtifactsPerMessage
                    else {
                        throw ConversationStoreError.limitExceeded(
                            "transient artifacts", ConversationStoreLimits.maximumArtifactsPerMessage)
                    }
                }
                guard session.turns.count <= ConversationStoreLimits.maximumMessagesPerSession else {
                    throw ConversationStoreError.limitExceeded(
                        "research turns", ConversationStoreLimits.maximumMessagesPerSession)
                }
                for turn in session.turns {
                    guard turnIDs.insert(turn.id).inserted,
                        userMessageIDs.insert(turn.message.id).inserted
                    else { throw ConversationStoreError.invalidValue("turn/message identity") }
                    try validateUserText(turn.message.text)
                    let attempts = session.bindings.filter { $0.turnID == turn.id }
                    guard attempts.map(\.id) == turn.attemptBindingIDs,
                        attempts.enumerated().allSatisfy({ pair in
                            pair.offset + 1 == pair.element.attemptOrdinal
                        })
                    else { throw ConversationStoreError.invalidValue("turn attempt relationship") }
                    for binding in attempts {
                        guard let plan = turn.planReference,
                            binding.requestID == plan.requestID,
                            binding.planID == plan.planID,
                            binding.planSHA256 == plan.planSHA256
                        else { throw ConversationStoreError.invalidValue("attempt plan identity") }
                    }
                }
                for binding in session.bindings {
                    guard bindingIDs.insert(binding.id).inserted,
                        session.turns.contains(where: { $0.id == binding.turnID })
                    else { throw ConversationStoreError.invalidValue("attempt binding identity") }
                }
                let durableMessages = session.messages.filter { $0.role == .user }
                guard durableMessages.count == session.turns.count,
                    zip(durableMessages, session.turns).allSatisfy({ message, turn in
                        message.id == turn.message.uuid && message.text == turn.message.text
                            && message.timestamp == turn.message.createdAt
                    })
                else { throw ConversationStoreError.invalidValue("turn message projection") }
                if let draft = session.draft { try validateDraft(draft) }
            }
        }
        guard sessions.count <= ConversationStoreLimits.maximumTotalSessions else {
            throw ConversationStoreError.limitExceeded(
                "conversations", ConversationStoreLimits.maximumTotalSessions)
        }
    }

    private static func validateDraft(_ value: ConversationDraft) throws {
        guard value.text.count <= ConversationStoreLimits.maximumDraftCharacters else {
            throw ConversationStoreError.limitExceeded(
                "draft", ConversationStoreLimits.maximumDraftCharacters)
        }
        let values =
            [value.text, value.scope, value.synthesisName, value.contactEmail]
            + value.constraints + value.assumptions + value.sourceNames
        guard values.allSatisfy({ $0 == Redactor.redact($0) }) else {
            throw ConversationStoreError.invalidValue("unredacted draft")
        }
        guard (1...10_000).contains(value.maxRecords),
            (0...10_000).contains(value.maxNetworkRequests),
            (1...86_400).contains(value.timeoutSeconds)
        else { throw ConversationStoreError.invalidValue("draft limits") }
        for hint in value.localRootHints + value.fixtureHints {
            guard !hint.name.isEmpty,
                !hint.name.contains("/"),
                !hint.name.contains("\\"),
                hint.name != ".",
                hint.name != "..",
                hint.name == Redactor.redact(hint.name)
            else { throw ConversationStoreError.invalidValue("reselection hint") }
        }
    }

    private static func validateUserText(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= ConversationStoreLimits.maximumMessageCharacters,
            value == Redactor.redact(value)
        else { throw ConversationStoreError.invalidValue("user message") }
    }

    private static func canonicalTurns(_ session: ConversationSession) throws -> [ResearchTurn] {
        if !session.turns.isEmpty { return session.turns }
        return try session.messages.filter { $0.role == .user }.map { message in
            try validateUserText(message.text)
            let user = try UserMessage(
                id: UserMessageID(uuid: message.id),
                text: message.text,
                createdAt: message.timestamp)
            return try ResearchTurn(
                id: ResearchTurnID(uuid: message.id),
                message: user,
                createdAt: message.timestamp,
                stateHint: .unknown)
        }
    }

    nonisolated fileprivate static func conversationMessage(
        _ value: UserMessage
    ) -> ConversationMessage {
        ConversationMessage(
            id: value.uuid,
            role: .user,
            kind: .text,
            text: value.text,
            timestamp: value.createdAt)
    }

    private static func merge(
        _ run: ConversationRunReference?,
        _ artifacts: [ConversationArtifactReference],
        into session: inout ConversationSession
    ) {
        if let run {
            session.linkedRunIDs = unique(session.linkedRunIDs + [run.runID])
            session.runReferences.removeAll { $0.runID == run.runID }
            session.runReferences.append(run)
        }
        session.artifactReferences = uniqueArtifacts(session.artifactReferences + artifacts)
    }

    private static func persistableInspector(
        _ selection: InspectorSelection?,
        in projects: [ConversationProject]
    ) -> InspectorSelection? {
        guard let selection else { return nil }
        let messageIsUser =
            projects.lazy.flatMap(\.sessions)
            .first(where: { $0.id == selection.sessionID })?
            .messages.first(where: { $0.id == selection.messageID })?.role == .user
        return InspectorSelection(
            tab: selection.tab,
            sessionID: selection.sessionID,
            messageID: messageIsUser ? selection.messageID : nil,
            runID: selection.runID,
            artifactID: selection.artifactID)
    }

    private static func runCard(_ run: RunListItem) -> ConversationMessage {
        let kind: MessageKind
        switch run.status {
        case .failed, .unknown: kind = .error
        case .created, .awaitingApproval, .running: kind = .runProgress
        case .completed, .partial, .cancelled: kind = .result
        }
        return ConversationMessage(
            role: .assistant,
            kind: kind,
            text:
                "研究运行 \(run.status.rawValue)\n\(run.sourceCount) 个来源 · \(run.evidenceCount) 条证据 · \(run.claimCount) 条结论",
            timestamp: run.updatedAt,
            runReference: ConversationRunReference(
                runID: run.runID,
                status: run.status,
                sources: run.sourceCount,
                evidence: run.evidenceCount,
                claims: run.claimCount))
    }

    private static func location(
        _ id: UUID,
        in projects: [ConversationProject]
    ) throws -> (project: Int, session: Int) {
        for p in projects.indices {
            if let s = projects[p].sessions.firstIndex(where: { $0.id == id }) { return (p, s) }
        }
        throw ConversationStoreError.notFound("session")
    }

    private static func title(_ value: String, fallback: String) throws -> String {
        let clean = Redactor.redact(value).trimmingCharacters(in: .whitespacesAndNewlines)
        let result = clean.isEmpty ? fallback : clean
        try text(result, field: "title", limit: ConversationStoreLimits.maximumTitleBytes)
        return result
    }

    private static func text(_ value: String, field: String, limit: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            value.utf8.count <= limit
        else { throw ConversationStoreError.invalidValue(field) }
    }

    private static func reference(_ value: String, field: String) throws -> String {
        let clean = Redactor.redact(value).trimmingCharacters(in: .whitespacesAndNewlines)
        try text(clean, field: field, limit: ConversationStoreLimits.maximumReferenceBytes)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
        guard clean.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ConversationStoreError.invalidValue(field)
        }
        return clean
    }

    nonisolated fileprivate static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func uniqueArtifacts(
        _ values: [ConversationArtifactReference]
    ) -> [ConversationArtifactReference] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bucket(
        _ value: Date,
        reference: Date,
        calendar: Calendar
    ) -> ConversationDateBucket {
        let days =
            calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: value), to: calendar.startOfDay(for: reference)
            ).day ?? 0
        switch days {
        case ...0: return .today
        case 1: return .yesterday
        case 2...7: return .previous7Days
        case 8...30: return .previous30Days
        default: return .older
        }
    }

    private static func isWorkspace(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["workspace_id"] != nil
    }

    private static func decodeWorkspace(_ data: Data) throws -> WorkspaceFile {
        let version = try schema(data)
        guard version == 1 else { throw ConversationStoreError.unsupportedSchema(version) }
        do { return try jsonDecoder().decode(WorkspaceFile.self, from: data) } catch {
            throw ConversationStoreError.corruptStore
        }
    }

    /// The immediately previous implementation used the same schema number but camel-cased nested
    /// session keys and six preview-tab names. Normalize only those known presentation fields,
    /// then decode through the current bounded value model before migrating.
    private static func decodeLegacy(_ data: Data) throws -> ConversationStoreSnapshot {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConversationStoreError.corruptStore
        }
        if var inspector = root["inspector_selection"] as? [String: Any],
            let tab = inspector["tab"] as? String
        {
            switch tab {
            case "activity", "sources": inspector["tab"] = "context"
            case "report", "files": inspector["tab"] = "artifacts"
            default: break
            }
            root["inspector_selection"] = inspector
        }
        if var projects = root["projects"] as? [[String: Any]] {
            for projectIndex in projects.indices {
                guard var sessions = projects[projectIndex]["sessions"] as? [[String: Any]] else {
                    continue
                }
                for sessionIndex in sessions.indices {
                    let aliases = [
                        "projectID": "project_id",
                        "createdAt": "created_at",
                        "updatedAt": "updated_at",
                        "isArchived": "is_archived",
                        "linkedRunIDs": "linked_run_ids",
                        "runReferences": "run_references",
                        "artifactReferences": "artifact_references",
                    ]
                    for (old, new) in aliases where sessions[sessionIndex][new] == nil {
                        sessions[sessionIndex][new] = sessions[sessionIndex].removeValue(forKey: old)
                    }
                }
                projects[projectIndex]["sessions"] = sessions
            }
            root["projects"] = projects
        }
        return try jsonDecoder().decode(
            ConversationStoreSnapshot.self,
            from: JSONSerialization.data(withJSONObject: root))
    }

    private static func schema(_ data: Data) throws -> Int {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = object["schema_version"] as? Int
        else { throw ConversationStoreError.corruptStore }
        return value
    }

    private static func declaredSchema(in data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["schema_version"] as? Int
    }

    private static func encoded<T: Encodable>(_ value: T, max: Int) throws -> Data {
        let data = try jsonEncoder().encode(value)
        guard data.count <= max else { throw ConversationStoreError.limitExceeded("bytes", max) }
        try scan(data)
        return data
    }

    private static func scan(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        let denied = [
            "credential", "api_key", "access_token", "password", "secret", "environment",
            "network_grant", "plan_approval", "allow_network", "pid", "process_handle", "stdout",
            "stderr", "diagnostic", "evidence_passage", "report_text", "manifest_body",
            "event_payload", "run_directory", "absolute_path", "security_bookmark",
        ]
        func visit(_ value: Any) throws {
            if let dictionary = value as? [String: Any] {
                for (key, nested) in dictionary {
                    guard !denied.contains(where: { key.lowercased().contains($0) }) else {
                        throw ConversationStoreError.invalidValue("forbidden persistence field")
                    }
                    try visit(nested)
                }
            } else if let array = value as? [Any] {
                for nested in array { try visit(nested) }
            }
        }
        try visit(object)
    }

    private static func atomic(_ data: Data, to url: URL) throws {
        try directory(url.deletingLastPathComponent())
        if exists(url.path) { try regular(url) }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString.lowercased()).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ConversationStoreError.ioFailure(errnoText()) }
        var cleanup = true
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { _ = close(fd) }
            if cleanup { _ = unlink(temporary.path) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw ConversationStoreError.ioFailure(errnoText()) }
                offset += amount
            }
        }
        guard fsync(fd) == 0, fchmod(fd, 0o600) == 0 else {
            throw ConversationStoreError.ioFailure(errnoText())
        }
        guard close(fd) == 0 else { throw ConversationStoreError.ioFailure(errnoText()) }
        descriptorIsOpen = false
        if exists(url.path) { try regular(url) }
        guard rename(temporary.path, url.path) == 0 else {
            throw ConversationStoreError.ioFailure(errnoText())
        }
        cleanup = false
        let directoryFD = open(url.deletingLastPathComponent().path, O_RDONLY | O_NOFOLLOW)
        if directoryFD >= 0 {
            _ = fsync(directoryFD)
            _ = close(directoryFD)
        }
    }

    private static func stageMetadataDeletion(source: URL, staged: URL) throws {
        try regular(source)
        guard !exists(staged.path), rename(source.path, staged.path) == 0 else {
            throw ConversationStoreError.ioFailure(errnoText())
        }
        syncDirectory(source.deletingLastPathComponent())
    }

    private static func restoreStagedDeletion(source: URL, staged: URL) throws {
        guard !exists(source.path), exists(staged.path), rename(staged.path, source.path) == 0 else {
            throw ConversationStoreError.ioFailure(errnoText())
        }
        syncDirectory(source.deletingLastPathComponent())
    }

    private static func syncDirectory(_ directory: URL) {
        let descriptor = open(directory.path, O_RDONLY | O_NOFOLLOW)
        if descriptor >= 0 {
            _ = fsync(descriptor)
            _ = close(descriptor)
        }
    }

    private static func read(_ url: URL, max: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ELOOP { throw ConversationStoreError.unsafeStoreFile }
            throw ConversationStoreError.ioFailure(errnoText())
        }
        defer { _ = close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_nlink == 1
        else { throw ConversationStoreError.unsafeStoreFile }
        guard metadata.st_size <= off_t(max) else {
            throw ConversationStoreError.limitExceeded("file bytes", max)
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ConversationStoreError.ioFailure(errnoText()) }
            if count == 0 { break }
            guard result.count + count <= max else {
                throw ConversationStoreError.limitExceeded("file bytes", max)
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private static func directory(_ url: URL) throws {
        if !exists(url.path) {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            throw ConversationStoreError.unsafeStoreFile
        }
    }

    private static func regular(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_nlink == 1
        else { throw ConversationStoreError.unsafeStoreFile }
    }

    private static func names(_ directory: URL) throws -> [String] {
        let values = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            guard $0.hasPrefix("conversation-"), $0.hasSuffix(".json") else { return false }
            let raw = String($0.dropFirst(13).dropLast(5))
            return raw == raw.lowercased() && UUID(uuidString: raw) != nil
        }.sorted()
        guard values.count <= ConversationStoreLimits.maximumTotalSessions else {
            throw ConversationStoreError.limitExceeded(
                "conversation scan", ConversationStoreLimits.maximumTotalSessions)
        }
        return values
    }

    private static func cleanupStagedDeletions(in directory: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var removedAny = false
        for name in entries {
            guard name.hasPrefix(".conversation-"), name.hasSuffix(".delete") else { continue }
            let body = String(name.dropFirst(".conversation-".count).dropLast(".delete".count))
            let components = body.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 2,
                let conversationUUID = UUID(uuidString: String(components[0])),
                let temporaryUUID = UUID(uuidString: String(components[1])),
                String(components[0]) == conversationUUID.uuidString.lowercased(),
                String(components[1]) == temporaryUUID.uuidString.lowercased()
            else { continue }
            let url = directory.appendingPathComponent(name)
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0,
                metadata.st_mode & S_IFMT == S_IFREG,
                metadata.st_nlink == 1
            else { continue }
            guard unlink(url.path) == 0 else {
                throw ConversationStoreError.ioFailure(errnoText())
            }
            removedAny = true
        }
        if removedAny { syncDirectory(directory) }
    }

    private static func jsonEncoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.prettyPrinted, .sortedKeys]
        return value
    }

    private static func jsonDecoder() -> JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }

    private static func exists(_ path: String) -> Bool {
        var value = stat()
        return lstat(path, &value) == 0
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }
    nonisolated fileprivate static func conversationID(_ id: UUID) -> String {
        "conversation-\(id.uuidString.lowercased())"
    }
    nonisolated fileprivate static func projectID(_ id: UUID) -> String {
        "project-\(id.uuidString.lowercased())"
    }
    nonisolated fileprivate static func parse(_ value: String, prefix: String) throws -> UUID {
        guard value.hasPrefix(prefix) else { throw ConversationStoreError.invalidValue("id prefix") }
        let raw = String(value.dropFirst(prefix.count))
        guard raw == raw.lowercased(), let id = UUID(uuidString: raw) else {
            throw ConversationStoreError.invalidValue("id")
        }
        return id
    }
}

private struct LoadedStore {
    let projects: [ConversationProject]
    let selectedProjectID: UUID?
    let selectedSessionID: UUID?
    let inspectorSelection: InspectorSelection?
    let layoutState: ConversationLayoutState
    let issues: [ConversationSessionIssue]
    let revisions: [UUID: Int]
}

private struct WorkspaceFile: Codable {
    static let empty = WorkspaceFile(
        projects: [], selectedProjectID: nil, selectedSessionID: nil,
        inspectorSelection: nil, layoutState: ConversationLayoutState(), conversationIDs: [])
    let schemaVersion: Int
    let workspaceID: String
    let projects: [ProjectFile]
    let selectedProjectID: UUID?
    let selectedSessionID: UUID?
    let inspectorSelection: InspectorSelection?
    let layoutState: ConversationLayoutState
    let conversationIDs: [UUID]

    init(
        projects: [ProjectFile], selectedProjectID: UUID?, selectedSessionID: UUID?,
        inspectorSelection: InspectorSelection?, layoutState: ConversationLayoutState,
        conversationIDs: [UUID]
    ) {
        schemaVersion = 1
        workspaceID = "local"
        self.projects = projects
        self.selectedProjectID = selectedProjectID
        self.selectedSessionID = selectedSessionID
        self.inspectorSelection = inspectorSelection
        self.layoutState = layoutState
        self.conversationIDs = conversationIDs.sorted { $0.uuidString < $1.uuidString }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", workspaceID = "workspace_id", projects
        case selectedProjectID = "selected_project_id"
        case selectedSessionID = "selected_conversation_id"
        case inspectorSelection = "inspector_selection"
        case layoutState = "layout_state"
        case conversationIDs = "conversation_ids"
    }
}

private struct ProjectFile: Codable {
    let id: String
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let archivedAt: Date?
    init(_ value: ConversationProject) {
        id = ConversationStore.projectID(value.id)
        title = value.title
        createdAt = value.createdAt
        updatedAt = value.updatedAt
        archivedAt = value.isArchived ? value.updatedAt : nil
    }
    var value: ConversationProject {
        get throws {
            ConversationProject(
                id: try ConversationStore.parse(id, prefix: "project-"), title: title,
                createdAt: createdAt, updatedAt: updatedAt, isArchived: archivedAt != nil)
        }
    }
    private enum CodingKeys: String, CodingKey {
        case id = "project_id", title, createdAt = "created_at", updatedAt = "updated_at"
        case archivedAt = "archived_at"
    }
}

private struct EnvelopeFile: Codable {
    let schemaVersion: Int
    let revision: Int
    let writtenAt: Date
    let conversation: ConversationFile
    let turns: [ResearchTurn]
    let bindings: [RunBinding]
    /// Read-only compatibility with the pre-ResearchTurn v1 envelope.
    let userMessages: [UserMessageFile]
    let draft: ConversationDraft?
    let runReferences: [RunIDFile]
    let artifactReferences: [ArtifactIDFile]

    init(
        revision: Int, conversation: ConversationFile, turns: [ResearchTurn],
        bindings: [RunBinding],
        draft: ConversationDraft?, runReferences: [RunIDFile],
        artifactReferences: [ArtifactIDFile]
    ) {
        schemaVersion = 1
        self.revision = revision
        writtenAt = Date()
        self.conversation = conversation
        self.turns = turns
        self.bindings = bindings
        userMessages = []
        self.draft = draft
        self.runReferences = runReferences
        self.artifactReferences = artifactReferences
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        revision = try values.decode(Int.self, forKey: .revision)
        writtenAt = try values.decode(Date.self, forKey: .writtenAt)
        conversation = try values.decode(ConversationFile.self, forKey: .conversation)
        turns = try values.decodeIfPresent([ResearchTurn].self, forKey: .turns) ?? []
        bindings = try values.decodeIfPresent([RunBinding].self, forKey: .bindings) ?? []
        userMessages = try values.decodeIfPresent([UserMessageFile].self, forKey: .userMessages) ?? []
        draft = try values.decodeIfPresent(ConversationDraft.self, forKey: .draft)
        runReferences = try values.decodeIfPresent([RunIDFile].self, forKey: .runReferences) ?? []
        artifactReferences =
            try values.decodeIfPresent(
                [ArtifactIDFile].self, forKey: .artifactReferences) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(revision, forKey: .revision)
        try values.encode(writtenAt, forKey: .writtenAt)
        try values.encode(conversation, forKey: .conversation)
        try values.encode(turns, forKey: .turns)
        try values.encode(bindings, forKey: .bindings)
        try values.encodeIfPresent(draft, forKey: .draft)
        try values.encode(runReferences, forKey: .runReferences)
        try values.encode(artifactReferences, forKey: .artifactReferences)
    }

    var value: ConversationSession {
        get throws {
            let durableTurns: [ResearchTurn]
            if turns.isEmpty, !userMessages.isEmpty {
                durableTurns = try userMessages.map { message in
                    let user = try UserMessage(
                        id: UserMessageID(uuid: message.id),
                        text: message.text,
                        createdAt: message.createdAt)
                    return try ResearchTurn(
                        id: ResearchTurnID(uuid: message.id),
                        message: user,
                        createdAt: message.createdAt,
                        stateHint: .unknown)
                }
            } else {
                durableTurns = turns.map { original in
                    var turn = original
                    turn.stateHint = turn.stateHint.downgradedForRelaunch
                    return turn
                }
            }
            let durableBindings = try bindings.map { try $0.downgradedForRelaunch }
            let runIDs = ConversationStore.unique(
                runReferences.map(\.runID) + durableBindings.compactMap(\.runID))
            let runs = runIDs.map {
                ConversationRunReference(runID: $0, status: .unknown)
            }
            let artifacts = try artifactReferences.map {
                try ConversationArtifactReference(
                    id: $0.artifactID, kind: $0.kind, title: $0.artifactID)
            }
            return ConversationSession(
                id: try ConversationStore.parse(conversation.conversationID, prefix: "conversation-"),
                projectID: try ConversationStore.parse(conversation.projectID, prefix: "project-"),
                title: conversation.title,
                createdAt: conversation.createdAt,
                updatedAt: conversation.updatedAt,
                status: conversation.statusHint,
                isArchived: conversation.archivedAt != nil,
                messages: durableTurns.map { ConversationStore.conversationMessage($0.message) },
                linkedRunIDs: runs.map(\.runID),
                draft: draft,
                runReferences: runs,
                artifactReferences: artifacts,
                turns: durableTurns,
                bindings: durableBindings)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", revision, writtenAt = "written_at", conversation
        case turns, bindings, userMessages = "user_messages", draft
        case runReferences = "run_references"
        case artifactReferences = "artifact_references"
    }
}

private struct ConversationFile: Codable {
    let conversationID: String
    let projectID: String
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let archivedAt: Date?
    let statusHint: SessionStatus
    init(_ value: ConversationSession) {
        conversationID = ConversationStore.conversationID(value.id)
        projectID = ConversationStore.projectID(value.projectID)
        title = value.title
        createdAt = value.createdAt
        updatedAt = value.updatedAt
        archivedAt = value.isArchived ? value.updatedAt : nil
        statusHint = value.status
    }
    private enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id", projectID = "project_id", title
        case createdAt = "created_at", updatedAt = "updated_at", archivedAt = "archived_at"
        case statusHint = "status_hint"
    }
}

private struct UserMessageFile: Codable {
    let id: UUID
    let text: String
    let createdAt: Date
    private enum CodingKeys: String, CodingKey {
        case id = "message_id", text, createdAt = "created_at"
    }
}

private struct RunIDFile: Codable {
    let runID: String
    private enum CodingKeys: String, CodingKey { case runID = "run_id" }
}

private struct ArtifactIDFile: Codable {
    let artifactID: String
    let kind: ArtifactKind
    private enum CodingKeys: String, CodingKey { case artifactID = "artifact_id", kind }
}
