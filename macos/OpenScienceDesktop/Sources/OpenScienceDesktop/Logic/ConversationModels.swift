import Foundation
import OpenScienceCore

public enum ConversationRole: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case user
    case assistant
    case system
}

public enum MessageKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case text
    case plan
    case permission
    case runProgress = "run_progress"
    case result
    case error
}

public enum SessionStatus: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case draft
    case planning
    case awaitingApproval = "awaiting_approval"
    case running
    case completed
    case partial
    case failed
    case cancelled
    case interrupted
    case invalid
    case unknown

    public init(runStatus: RunStatus) {
        switch runStatus {
        case .created: self = .draft
        case .awaitingApproval: self = .awaitingApproval
        case .running: self = .running
        case .completed: self = .completed
        case .partial: self = .partial
        case .failed: self = .failed
        case .unknown: self = .unknown
        case .cancelled: self = .cancelled
        }
    }
}

public enum ArtifactKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case report
    case manifest
    case source
    case evidence
    case export
    case file
}

public struct ConversationRunReference: Codable, Equatable, Hashable, Sendable {
    public let runID: String
    public let status: RunStatus
    public let sources: Int
    public let evidence: Int
    public let claims: Int

    public init(
        runID: String,
        status: RunStatus,
        sources: Int = 0,
        evidence: Int = 0,
        claims: Int = 0
    ) {
        self.runID = Redactor.redact(runID)
        self.status = status
        self.sources = max(0, sources)
        self.evidence = max(0, evidence)
        self.claims = max(0, claims)
    }
}

public struct ConversationArtifactReference: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let kind: ArtifactKind
    public let title: String
    public let relativePath: String?

    public init(
        id: String,
        kind: ArtifactKind,
        title: String,
        relativePath: String? = nil
    ) throws {
        let cleanID = Redactor.redact(id).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = Redactor.redact(title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty, !cleanTitle.isEmpty else {
            throw ConversationStoreError.invalidValue("artifact id/title")
        }
        if let relativePath {
            guard Self.isSafeRelativePath(relativePath) else {
                throw ConversationStoreError.invalidValue("artifact relative path")
            }
        }
        self.id = cleanID
        self.kind = kind
        self.title = cleanTitle
        self.relativePath = relativePath
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title
        case relativePath = "relative_path"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            kind: container.decode(ArtifactKind.self, forKey: .kind),
            title: container.decode(String.self, forKey: .title),
            relativePath: container.decodeIfPresent(String.self, forKey: .relativePath)
        )
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.hasPrefix("~") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
}

public struct ConversationMessage: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let role: ConversationRole
    public let kind: MessageKind
    public let text: String
    public let timestamp: Date
    public let runReference: ConversationRunReference?
    public let artifactReferences: [ConversationArtifactReference]

    public init(
        id: UUID = UUID(),
        role: ConversationRole,
        kind: MessageKind,
        text: String,
        timestamp: Date = Date(),
        runReference: ConversationRunReference? = nil,
        artifactReferences: [ConversationArtifactReference] = []
    ) {
        self.id = id
        self.role = role
        self.kind = kind
        self.text = Redactor.redact(text)
        self.timestamp = timestamp
        self.runReference = runReference
        self.artifactReferences = artifactReferences
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, kind, text, timestamp
        case runReference = "run_reference"
        case artifactReferences = "artifact_references"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            role: try container.decode(ConversationRole.self, forKey: .role),
            kind: try container.decode(MessageKind.self, forKey: .kind),
            text: try container.decode(String.self, forKey: .text),
            timestamp: try container.decode(Date.self, forKey: .timestamp),
            runReference: try container.decodeIfPresent(
                ConversationRunReference.self, forKey: .runReference),
            artifactReferences: try container.decodeIfPresent(
                [ConversationArtifactReference].self, forKey: .artifactReferences) ?? []
        )
    }
}

public enum ReselectionHintKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case localRoot = "local_root"
    case fixture
}

/// Display-only identity for a previously selected resource. It deliberately contains no path,
/// bookmark, token, descriptor, or other filesystem authority.
public struct ConversationReselectionHint: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String { "\(kind.rawValue):\(name)" }
    public let name: String
    public let kind: ReselectionHintKind

    public init(name: String, kind: ReselectionHintKind) {
        self.name = Redactor.redact(URL(fileURLWithPath: name).lastPathComponent)
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case name, kind }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            kind: try container.decode(ReselectionHintKind.self, forKey: .kind))
    }
}

public struct ConversationDraft: Codable, Equatable, Hashable, Sendable {
    public let text: String
    public let scope: String
    public let constraints: [String]
    public let assumptions: [String]
    public let sourceNames: [String]
    public let synthesisName: String
    public let localRootHints: [ConversationReselectionHint]
    public let fixtureHints: [ConversationReselectionHint]
    public let maxRecords: Int
    public let maxNetworkRequests: Int
    public let timeoutSeconds: Int
    public let contactEmail: String
    public let updatedAt: Date

    public init(
        text: String = "",
        scope: String = "",
        constraints: [String] = [],
        assumptions: [String] = [],
        sourceNames: [String] = [],
        synthesisName: String = "extractive",
        localRootHints: [ConversationReselectionHint] = [],
        fixtureHints: [ConversationReselectionHint] = [],
        maxRecords: Int = 50,
        maxNetworkRequests: Int = 10,
        timeoutSeconds: Int = 300,
        contactEmail: String = "",
        updatedAt: Date = Date()
    ) {
        self.text = Redactor.redact(text)
        self.scope = Redactor.redact(scope)
        self.constraints = constraints.map { Redactor.redact($0) }
        self.assumptions = assumptions.map { Redactor.redact($0) }
        self.sourceNames = sourceNames.map { Redactor.redact($0) }
        self.synthesisName = Redactor.redact(synthesisName)
        self.localRootHints = localRootHints
        self.fixtureHints = fixtureHints
        self.maxRecords = maxRecords
        self.maxNetworkRequests = maxNetworkRequests
        self.timeoutSeconds = timeoutSeconds
        self.contactEmail = Redactor.redact(contactEmail)
        self.updatedAt = updatedAt
    }

    public init(
        text: String,
        researchDraft: ResearchDraft,
        synthesisName: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.init(
            text: text,
            scope: researchDraft.scope,
            constraints: researchDraft.constraints,
            assumptions: researchDraft.assumptions,
            sourceNames: researchDraft.sourceNames,
            synthesisName: synthesisName
                ?? (researchDraft.useNetworkModel ? "openai-compatible" : "extractive"),
            localRootHints: researchDraft.localRoots.map {
                ConversationReselectionHint(name: $0.lastPathComponent, kind: .localRoot)
            },
            fixtureHints: researchDraft.fixtureFiles.map {
                ConversationReselectionHint(name: $0.lastPathComponent, kind: .fixture)
            },
            maxRecords: researchDraft.maxRecords,
            maxNetworkRequests: researchDraft.maxNetworkRequests,
            timeoutSeconds: researchDraft.timeoutSeconds,
            contactEmail: researchDraft.email,
            updatedAt: updatedAt
        )
    }
}

public struct ConversationSession: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var status: SessionStatus
    public var isArchived: Bool
    public var messages: [ConversationMessage]
    public var linkedRunIDs: [String]
    public var draft: ConversationDraft?
    public var runReferences: [ConversationRunReference]
    public var artifactReferences: [ConversationArtifactReference]

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: SessionStatus = .draft,
        isArchived: Bool = false,
        messages: [ConversationMessage] = [],
        linkedRunIDs: [String] = [],
        draft: ConversationDraft? = nil,
        runReferences: [ConversationRunReference] = [],
        artifactReferences: [ConversationArtifactReference] = []
    ) {
        self.id = id
        self.projectID = projectID
        self.title = Redactor.redact(title)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.isArchived = isArchived
        self.messages = messages
        self.linkedRunIDs = linkedRunIDs.map { Redactor.redact($0) }
        self.draft = draft
        self.runReferences = runReferences
        self.artifactReferences = artifactReferences
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case status
        case isArchived = "is_archived"
        case messages
        case linkedRunIDs = "linked_run_ids"
        case draft
        case runReferences = "run_references"
        case artifactReferences = "artifact_references"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            projectID: try container.decode(UUID.self, forKey: .projectID),
            title: try container.decode(String.self, forKey: .title),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            status: try container.decodeIfPresent(SessionStatus.self, forKey: .status) ?? .draft,
            isArchived: try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false,
            messages: try container.decodeIfPresent([ConversationMessage].self, forKey: .messages) ?? [],
            linkedRunIDs: try container.decodeIfPresent([String].self, forKey: .linkedRunIDs) ?? [],
            draft: try container.decodeIfPresent(ConversationDraft.self, forKey: .draft),
            runReferences: try container.decodeIfPresent(
                [ConversationRunReference].self, forKey: .runReferences) ?? [],
            artifactReferences: try container.decodeIfPresent(
                [ConversationArtifactReference].self, forKey: .artifactReferences) ?? []
        )
    }
}

public struct ConversationProject: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var isArchived: Bool
    public var sessions: [ConversationSession]

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isArchived: Bool = false,
        sessions: [ConversationSession] = []
    ) {
        self.id = id
        self.title = Redactor.redact(title)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
        self.sessions = sessions
    }
}

public enum InspectorTab: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case context
    case plan
    case evidence
    case artifacts
}

public struct InspectorSelection: Codable, Equatable, Hashable, Sendable {
    public let tab: InspectorTab
    public let sessionID: UUID
    public let messageID: UUID?
    public let runID: String?
    public let artifactID: String?

    public init(
        tab: InspectorTab,
        sessionID: UUID,
        messageID: UUID? = nil,
        runID: String? = nil,
        artifactID: String? = nil
    ) {
        self.tab = tab
        self.sessionID = sessionID
        self.messageID = messageID
        self.runID = runID.map { Redactor.redact($0) }
        self.artifactID = artifactID.map { Redactor.redact($0) }
    }
}

public enum ConversationColumnVisibility: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case shown
    case collapsed
}

public struct ConversationLayoutState: Codable, Equatable, Hashable, Sendable {
    public let selectedPreviewTab: InspectorTab
    public let sidebarVisibility: ConversationColumnVisibility
    public let previewVisibility: ConversationColumnVisibility
    public let sidebarWidth: Double
    public let previewWidth: Double

    public init(
        selectedPreviewTab: InspectorTab = .context,
        sidebarVisibility: ConversationColumnVisibility = .shown,
        previewVisibility: ConversationColumnVisibility = .shown,
        sidebarWidth: Double = 262,
        previewWidth: Double = 484
    ) {
        self.selectedPreviewTab = selectedPreviewTab
        self.sidebarVisibility = sidebarVisibility
        self.previewVisibility = previewVisibility
        self.sidebarWidth = sidebarWidth.isFinite ? min(340, max(220, sidebarWidth)) : 262
        self.previewWidth = previewWidth.isFinite ? min(560, max(360, previewWidth)) : 484
    }

    private enum CodingKeys: String, CodingKey {
        case selectedPreviewTab, sidebarVisibility, previewVisibility, sidebarWidth, previewWidth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            selectedPreviewTab: try container.decodeIfPresent(
                InspectorTab.self, forKey: .selectedPreviewTab) ?? .context,
            sidebarVisibility: try container.decodeIfPresent(
                ConversationColumnVisibility.self, forKey: .sidebarVisibility) ?? .shown,
            previewVisibility: try container.decodeIfPresent(
                ConversationColumnVisibility.self, forKey: .previewVisibility) ?? .shown,
            sidebarWidth: try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 262,
            previewWidth: try container.decodeIfPresent(Double.self, forKey: .previewWidth) ?? 484)
    }
}

public struct ConversationSessionIssue: Identifiable, Equatable, Sendable {
    public var id: String { "\(code):\(envelopeName)" }
    public let code: String
    public let envelopeName: String
    public let outcome: String
    public let safeDetail: String

    public init(code: String, envelopeName: String, outcome: String, safeDetail: String) {
        self.code = Redactor.redact(code)
        self.envelopeName = URL(fileURLWithPath: envelopeName).lastPathComponent
        self.outcome = String(Redactor.redact(outcome).prefix(1_024))
        self.safeDetail = String(Redactor.redact(safeDetail).prefix(8_192))
    }
}

public struct ConversationStoreSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var projects: [ConversationProject]
    public var selectedProjectID: UUID?
    public var selectedSessionID: UUID?
    public var inspectorSelection: InspectorSelection?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        projects: [ConversationProject] = [],
        selectedProjectID: UUID? = nil,
        selectedSessionID: UUID? = nil,
        inspectorSelection: InspectorSelection? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.projects = projects
        self.selectedProjectID = selectedProjectID
        self.selectedSessionID = selectedSessionID
        self.inspectorSelection = inspectorSelection
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case projects
        case selectedProjectID = "selected_project_id"
        case selectedSessionID = "selected_session_id"
        case inspectorSelection = "inspector_selection"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        projects = try container.decodeIfPresent([ConversationProject].self, forKey: .projects) ?? []
        selectedProjectID = try container.decodeIfPresent(UUID.self, forKey: .selectedProjectID)
        selectedSessionID = try container.decodeIfPresent(UUID.self, forKey: .selectedSessionID)
        inspectorSelection = try container.decodeIfPresent(
            InspectorSelection.self, forKey: .inspectorSelection)
    }
}

public struct ConversationSearchResult: Identifiable, Equatable, Sendable {
    public var id: UUID { session.id }
    public let project: ConversationProject
    public let session: ConversationSession

    public init(project: ConversationProject, session: ConversationSession) {
        self.project = project
        self.session = session
    }
}

public enum ConversationDateBucket: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case today
    case yesterday
    case previous7Days = "previous_7_days"
    case previous30Days = "previous_30_days"
    case older
}

public struct ConversationSessionGroup: Identifiable, Equatable, Sendable {
    public var id: ConversationDateBucket { bucket }
    public let bucket: ConversationDateBucket
    public let sessions: [ConversationSession]

    public init(bucket: ConversationDateBucket, sessions: [ConversationSession]) {
        self.bucket = bucket
        self.sessions = sessions
    }
}

public enum ConversationInspectorPreview: Equatable, Sendable {
    case empty
    case plan(PlanReviewContext)
    case activity(runID: String, projection: ActiveRunProjection)
    case result(outcome: RunOutcome, detail: RunDetail?)
}

public struct ConversationTimelineProjection: Equatable, Sendable {
    public let messages: [ConversationMessage]
    public let preview: ConversationInspectorPreview
    public let selection: InspectorSelection

    public init(
        messages: [ConversationMessage],
        preview: ConversationInspectorPreview,
        selection: InspectorSelection
    ) {
        self.messages = messages
        self.preview = preview
        self.selection = selection
    }
}
