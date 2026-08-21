import Foundation

public enum RunStatus: String, Codable, CaseIterable, Sendable {
    case created
    case awaitingApproval = "awaiting_approval"
    case running
    case completed
    case partial
    case failed
    case cancelled
    case unknown

    public init(rawOrUnknown value: String) {
        self = RunStatus(rawValue: value) ?? .unknown
    }
}

public struct RunOutcome: Codable, Equatable, Sendable {
    public let runID: String
    public let runDirectory: String
    public let status: String
    public let report: String?
    public let manifest: String?
    public let sources: Int
    public let evidence: Int
    public let claims: Int
    public let limitations: [String]

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case runDirectory = "run_directory"
        case status, report, manifest, sources, evidence, claims, limitations
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        runID = try values.decode(String.self, forKey: .runID)
        runDirectory = try values.decode(String.self, forKey: .runDirectory)
        status = try values.decode(String.self, forKey: .status)
        report = try values.decodeIfPresent(String.self, forKey: .report)
        manifest = try values.decodeIfPresent(String.self, forKey: .manifest)
        sources = try values.decodeIfPresent(Int.self, forKey: .sources) ?? 0
        evidence = try values.decodeIfPresent(Int.self, forKey: .evidence) ?? 0
        claims = try values.decodeIfPresent(Int.self, forKey: .claims) ?? 0
        limitations = try values.decodeIfPresent([String].self, forKey: .limitations) ?? []
    }
}

public struct ProviderDescriptor: Codable, Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let version: String?
    public let kind: String?
    public let risk: String?
    public let available: Bool
    public let healthError: String?

    enum CodingKeys: String, CodingKey {
        case name, version, kind, risk, available
        case healthError = "health_error"
    }
}

public struct ProvidersEnvelope: Codable, Equatable, Sendable {
    public let providers: [ProviderDescriptor]
}

public struct ExportEnvelope: Codable, Equatable, Sendable {
    public let output: String
    public let size: Int

    public init(output: String, size: Int) {
        self.output = output
        self.size = size
    }
}

public struct PlanEnvelope: Codable, Equatable, Sendable {
    public let request: JSONValue
    public let plan: ResearchPlanRecord
}

public struct ResearchPlanRecord: Codable, Equatable, Sendable {
    public let planID: String
    public let requestID: String?
    public let createdAt: String?
    public let status: String
    public let steps: [PlanStepRecord]

    enum CodingKeys: String, CodingKey {
        case planID = "plan_id"
        case requestID = "request_id"
        case createdAt = "created_at"
        case status, steps
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        planID = try values.decode(String.self, forKey: .planID)
        requestID = try values.decodeIfPresent(String.self, forKey: .requestID)
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        steps = try values.decode([PlanStepRecord].self, forKey: .steps)
    }
}

public struct PlanStepRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String { stepID }
    public let stepID: String
    public let title: String
    public let purpose: String
    public let capability: String
    public let dependencies: [String]
    public let completionCondition: String
    public let status: String

    enum CodingKeys: String, CodingKey {
        case stepID = "step_id"
        case title, purpose, capability, dependencies, status
        case completionCondition = "completion_condition"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stepID = try values.decode(String.self, forKey: .stepID)
        title = try values.decode(String.self, forKey: .title)
        purpose = try values.decode(String.self, forKey: .purpose)
        capability = try values.decode(String.self, forKey: .capability)
        dependencies = try values.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        completionCondition = try values.decode(String.self, forKey: .completionCondition)
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "pending"
    }
}

public struct CLIErrorDetail: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let type: String?
}

public struct CLIErrorEnvelope: Codable, Equatable, Sendable {
    public let error: CLIErrorDetail
}

public struct ValidationReport: Codable, Equatable, Sendable {
    public let valid: Bool
    public let errors: [String]
    public let warnings: [String]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        valid = try container.decodeIfPresent(Bool.self, forKey: .valid) ?? false
        errors = Self.decodeMessages(container, key: .errors)
        warnings = Self.decodeMessages(container, key: .warnings)
    }

    private enum CodingKeys: String, CodingKey { case valid, errors, warnings }

    private static func decodeMessages(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> [String] {
        if let strings = try? container.decode([String].self, forKey: key) { return strings }
        if let values = try? container.decode([JSONValue].self, forKey: key) {
            return values.map { $0.stringValue ?? $0.prettyPrinted }
        }
        return []
    }
}

public struct ResearchDraft: Equatable, Sendable {
    public var question = ""
    public var scope = ""
    public var constraints: [String] = []
    public var assumptions: [String] = []
    public var fixtureFiles: [URL] = []
    public var localRoots: [URL] = []
    public var sourceNames: [String] = []
    public var allowNetwork = false
    public var email = ""
    public var maxRecords = 50
    public var maxNetworkRequests = 10
    public var timeoutSeconds = 300
    public var useNetworkModel = false

    public init() {}
}

public struct ClientConfiguration: Equatable, Sendable {
    public var cliExecutable: URL
    public var workingDirectory: URL
    public var runRoot: URL
    public var modelConfig: URL?
    public var modelKeyEnvironment: String
    public var expectedExecutableIdentity: ExecutableIdentity?
    public var reviewedModelEndpoint: String?
    public var reviewedModelName: String?
    public var reviewedModelTimeout: Double?

    public init(
        cliExecutable: URL,
        workingDirectory: URL,
        runRoot: URL,
        modelConfig: URL? = nil,
        modelKeyEnvironment: String = "OPENSCIENCE_MODEL_API_KEY",
        expectedExecutableIdentity: ExecutableIdentity? = nil,
        reviewedModelEndpoint: String? = nil,
        reviewedModelName: String? = nil,
        reviewedModelTimeout: Double? = nil
    ) {
        self.cliExecutable = cliExecutable
        self.workingDirectory = workingDirectory
        self.runRoot = runRoot
        self.modelConfig = modelConfig
        self.modelKeyEnvironment = modelKeyEnvironment
        self.expectedExecutableIdentity = expectedExecutableIdentity
        self.reviewedModelEndpoint = reviewedModelEndpoint
        self.reviewedModelName = reviewedModelName
        self.reviewedModelTimeout = reviewedModelTimeout
    }
}

public struct CredentialSet: Equatable, Sendable {
    public var modelAPIKey: String?
    public var openAlexAPIKey: String?
    public var crossrefAPIKey: String?

    public init(modelAPIKey: String? = nil, openAlexAPIKey: String? = nil, crossrefAPIKey: String? = nil) {
        self.modelAPIKey = modelAPIKey
        self.openAlexAPIKey = openAlexAPIKey
        self.crossrefAPIKey = crossrefAPIKey
    }
}

public struct SourceRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String { sourceID }
    public let sourceID: String
    public let canonicalID: String?
    public let title: String
    public let authors: [String]
    public let publicationDate: String?
    public let sourceType: String?
    public let abstractOrExcerpt: String?
    public let landingURL: String?
    public let license: String?
    public let status: String?
    public let providers: [String]
    public let identifiers: [String: String]
    public let retrievals: [RetrievalRecord]
    public let contentHash: String?

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case canonicalID = "canonical_id"
        case title, authors
        case publicationDate = "publication_date"
        case sourceType = "source_type"
        case abstractOrExcerpt = "abstract_or_excerpt"
        case landingURL = "landing_url"
        case license, status, providers, identifiers, retrievals
        case contentHash = "content_hash"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try values.decode(String.self, forKey: .sourceID)
        canonicalID = try values.decodeIfPresent(String.self, forKey: .canonicalID)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "Untitled source"
        authors = try values.decodeIfPresent([String].self, forKey: .authors) ?? []
        publicationDate = try values.decodeIfPresent(String.self, forKey: .publicationDate)
        sourceType = try values.decodeIfPresent(String.self, forKey: .sourceType)
        abstractOrExcerpt = try values.decodeIfPresent(String.self, forKey: .abstractOrExcerpt)
        landingURL = try values.decodeIfPresent(String.self, forKey: .landingURL)
        license = try values.decodeIfPresent(String.self, forKey: .license)
        status = try values.decodeIfPresent(String.self, forKey: .status)
        providers = try values.decodeIfPresent([String].self, forKey: .providers) ?? []
        identifiers = try values.decodeIfPresent([String: String].self, forKey: .identifiers) ?? [:]
        retrievals = try values.decodeIfPresent([RetrievalRecord].self, forKey: .retrievals) ?? []
        contentHash = try values.decodeIfPresent(String.self, forKey: .contentHash)
    }
}

public struct RetrievalRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String { retrievalID }
    public let retrievalID: String
    public let provider: String
    public let query: String
    public let retrievedAt: String
    public let url: String?
    public let responseHash: String?

    enum CodingKeys: String, CodingKey {
        case provider, query, url
        case retrievalID = "retrieval_id"
        case retrievedAt = "retrieved_at"
        case responseHash = "response_hash"
    }
}

public struct EvidenceRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String { evidenceID }
    public let evidenceID: String
    public let sourceID: String
    public let passage: String
    public let locator: String
    public let relevance: Double
    public let stance: String
    public let license: String?
    public let contentHash: String?
    public let createdByStep: String?

    enum CodingKeys: String, CodingKey {
        case evidenceID = "evidence_id"
        case sourceID = "source_id"
        case passage, locator, relevance, stance, license
        case contentHash = "content_hash"
        case createdByStep = "created_by_step"
    }
}

public struct ClaimRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String { claimID }
    public let claimID: String
    public let text: String
    public let kind: String
    public let evidenceIDs: [String]
    public let confidence: Double?
    public let limitations: [String]
    public let createdBy: String?

    enum CodingKeys: String, CodingKey {
        case claimID = "claim_id"
        case text, kind, confidence, limitations
        case evidenceIDs = "evidence_ids"
        case createdBy = "created_by"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        claimID = try values.decode(String.self, forKey: .claimID)
        text = try values.decode(String.self, forKey: .text)
        kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? "unknown"
        evidenceIDs = try values.decodeIfPresent([String].self, forKey: .evidenceIDs) ?? []
        confidence = try values.decodeIfPresent(Double.self, forKey: .confidence)
        limitations = try values.decodeIfPresent([String].self, forKey: .limitations) ?? []
        createdBy = try values.decodeIfPresent(String.self, forKey: .createdBy)
    }
}

public struct RunStructuralIssue: Equatable, Hashable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct RunListItem: Identifiable, Equatable, Hashable, Sendable {
    public var id: URL { directory }
    public let runID: String
    public let directory: URL
    public let question: String
    public let status: RunStatus
    public let updatedAt: Date
    public let sourceCount: Int
    public let evidenceCount: Int
    public let claimCount: Int
    public let structuralIssue: RunStructuralIssue?

    public init(
        runID: String,
        directory: URL,
        question: String,
        status: RunStatus,
        updatedAt: Date,
        sourceCount: Int,
        evidenceCount: Int,
        claimCount: Int,
        structuralIssue: RunStructuralIssue? = nil
    ) {
        self.runID = runID
        self.directory = directory
        self.question = question
        self.status = status
        self.updatedAt = updatedAt
        self.sourceCount = sourceCount
        self.evidenceCount = evidenceCount
        self.claimCount = claimCount
        self.structuralIssue = structuralIssue
    }
}

public struct RunDetail: Equatable, Sendable {
    public let item: RunListItem
    public let reportMarkdown: String
    public let sources: [SourceRecord]
    public let evidence: [EvidenceRecord]
    public let claims: [ClaimRecord]
    public let manifest: JSONValue
}

public struct RunProgressSnapshot: Equatable, Sendable {
    public let completedSteps: Int
    public let totalSteps: Int
    public let lastEvent: String

    public init(completedSteps: Int, totalSteps: Int, lastEvent: String) {
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
        self.lastEvent = lastEvent
    }

    public var fraction: Double {
        guard totalSteps > 0 else { return 0 }
        return min(1, Double(completedSteps) / Double(totalSteps))
    }
}
