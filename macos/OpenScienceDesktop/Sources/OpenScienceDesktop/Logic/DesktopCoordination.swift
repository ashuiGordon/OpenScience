import Foundation
import OpenScienceCore

public struct ProviderReview: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let risk: String
    public let kind: String
    public let networkSummary: String?
    public let destination: String?

    public init(
        name: String,
        risk: String,
        kind: String,
        networkSummary: String? = nil,
        destination: String? = nil
    ) {
        self.name = name
        self.risk = risk
        self.kind = kind
        self.networkSummary = networkSummary
        self.destination = destination
    }

    public var usesNetwork: Bool { risk == "network_read" || networkSummary != nil }
}

public struct PlanReviewContext: Equatable, Sendable {
    public let question: String
    public let sources: [ProviderReview]
    public let synthesizer: ProviderReview
    public let localRoots: [URL]
    public let maxRecords: Int
    public let maxNetworkRequests: Int
    public let timeoutSeconds: Int
    public let plan: ResearchPlanRecord
    public let modelConfig: ModelConfigSummary?

    public init(
        question: String,
        sources: [ProviderReview],
        synthesizer: ProviderReview,
        localRoots: [URL],
        maxRecords: Int,
        maxNetworkRequests: Int,
        timeoutSeconds: Int,
        plan: ResearchPlanRecord,
        modelConfig: ModelConfigSummary? = nil
    ) {
        self.question = question
        self.sources = sources
        self.synthesizer = synthesizer
        self.localRoots = localRoots
        self.maxRecords = maxRecords
        self.maxNetworkRequests = maxNetworkRequests
        self.timeoutSeconds = timeoutSeconds
        self.plan = plan
        self.modelConfig = modelConfig
    }

    public var networkCapabilities: [ProviderReview] {
        (sources + [synthesizer]).filter(\.usesNetwork)
    }

    public var requiresNetworkGrant: Bool { !networkCapabilities.isEmpty }

    public var networkGrantScope: NetworkGrantScope {
        return NetworkGrantScope(
            capabilityNames: networkCapabilities.map(\.name),
            destinations: networkCapabilities.compactMap(\.destination),
            maxNetworkRequests: maxNetworkRequests,
            timeoutSeconds: timeoutSeconds,
            includesLocalData: !localRoots.isEmpty,
            configurationSHA256: modelConfig?.sha256
        )
    }
}

public struct NetworkGrantScope: Equatable, Sendable {
    public let capabilityNames: [String]
    public let destinations: [String]
    public let maxNetworkRequests: Int
    public let timeoutSeconds: Int
    public let includesLocalData: Bool
    public let configurationSHA256: String?

    public init(
        capabilityNames: [String],
        destinations: [String] = [],
        maxNetworkRequests: Int,
        timeoutSeconds: Int,
        includesLocalData: Bool,
        configurationSHA256: String? = nil
    ) {
        self.capabilityNames = capabilityNames
        self.destinations = destinations
        self.maxNetworkRequests = maxNetworkRequests
        self.timeoutSeconds = timeoutSeconds
        self.includesLocalData = includesLocalData
        self.configurationSHA256 = configurationSHA256
    }
}

/// An in-memory, single-use approval. It is intentionally neither Codable nor persisted.
public struct OneTimeNetworkGrant: Equatable, Sendable {
    private var capabilityFingerprint: String?

    public init() {}

    public mutating func approve(scope: NetworkGrantScope) {
        capabilityFingerprint = Self.fingerprint(scope)
    }

    public mutating func consume(scope: NetworkGrantScope) -> Bool {
        let matches = capabilityFingerprint == Self.fingerprint(scope)
        capabilityFingerprint = nil
        return matches
    }

    public mutating func revoke() { capabilityFingerprint = nil }

    public var isApproved: Bool { capabilityFingerprint != nil }

    private static func fingerprint(_ scope: NetworkGrantScope) -> String {
        [
            scope.capabilityNames.sorted().joined(separator: "\u{1f}"),
            scope.destinations.sorted().joined(separator: "\u{1f}"),
            String(scope.maxNetworkRequests),
            String(scope.timeoutSeconds),
            String(scope.includesLocalData),
            scope.configurationSHA256 ?? "none",
        ].joined(separator: "\u{1e}")
    }
}

public enum HistorySort: String, CaseIterable, Sendable {
    case newest
    case oldest
    case question
}

public struct HistoryQuery: Equatable, Sendable {
    public var text: String
    public var statuses: Set<RunStatus>
    public var sort: HistorySort

    public init(text: String = "", statuses: Set<RunStatus> = [], sort: HistorySort = .newest) {
        self.text = text
        self.statuses = statuses
        self.sort = sort
    }

    public func apply(to runs: [RunListItem]) -> [RunListItem] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let filtered = runs.filter { run in
            (needle.isEmpty
                || run.question.localizedLowercase.contains(needle)
                || run.runID.localizedLowercase.contains(needle))
                && (statuses.isEmpty || statuses.contains(run.status))
        }
        switch sort {
        case .newest: return filtered.sorted { $0.updatedAt > $1.updatedAt }
        case .oldest: return filtered.sorted { $0.updatedAt < $1.updatedAt }
        case .question:
            return filtered.sorted {
                $0.question.localizedCaseInsensitiveCompare($1.question) == .orderedAscending
            }
        }
    }
}

public enum FreshValidationState: Equatable, Sendable {
    case unknown
    case checking
    case valid(manifestDate: Date, warnings: [String])
    case invalid(manifestDate: Date, errors: [String], warnings: [String])

    public func isFresh(for manifestDate: Date) -> Bool {
        switch self {
        case let .valid(date, _), let .invalid(date, _, _): return date == manifestDate
        case .unknown, .checking: return false
        }
    }

    public var permitsMutation: Bool {
        if case .valid = self { return true }
        return false
    }
}

public enum RunStructuralPolicy {
    public static func validationState(for item: RunListItem) -> FreshValidationState? {
        guard let issue = item.structuralIssue else { return nil }
        return .invalid(
            manifestDate: item.updatedAt,
            errors: ["\(issue.code): \(issue.message)"],
            warnings: []
        )
    }

    public static func permitsLoading(_ item: RunListItem) -> Bool {
        item.structuralIssue == nil
    }
}

public enum ResumeReviewError: LocalizedError, Equatable {
    case malformedManifest(String)

    public var errorDescription: String? {
        switch self {
        case let .malformedManifest(field): return "运行清单缺少或损坏：\(field)"
        }
    }
}

public enum DesktopCredentialRequirement: String, CaseIterable, Equatable, Sendable {
    case model
    case openAlex
    case crossref
}

public struct ProviderIdentity: Equatable, Sendable {
    public let name: String
    public let version: String
    public let available: Bool

    public init(name: String, version: String, available: Bool) {
        self.name = name
        self.version = version
        self.available = available
    }
}

public struct SavedProviderRequirement: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct ProviderPreflightResult: Equatable, Sendable {
    public let missing: [SavedProviderRequirement]
    public let versionMismatches: [SavedProviderRequirement]
    public let unavailable: [SavedProviderRequirement]

    public var valid: Bool {
        missing.isEmpty && versionMismatches.isEmpty && unavailable.isEmpty
    }
}

public struct ResumeReviewContext: Equatable, Sendable {
    public let runDirectory: URL
    public let status: RunStatus
    public let question: String
    public let plan: ResearchPlanRecord
    public let completedStepIDs: [String]
    public let remainingStepIDs: [String]
    public let limitations: [String]
    public let sourceNames: [String]
    public let synthesizerName: String
    public let exactLocalRoots: [URL]
    public let maxRecords: Int
    public let maxNetworkRequests: Int
    public let timeoutSeconds: Int
    public let requiresNetworkGrant: Bool
    public let credentialRequirements: Set<DesktopCredentialRequirement>
    public let savedSourceProviders: [SavedProviderRequirement]

    public var canResumeStatus: Bool {
        [.awaitingApproval, .partial, .failed].contains(status) && !remainingStepIDs.isEmpty
    }

    public static func parse(manifest: JSONValue, runDirectory: URL) throws -> Self {
        guard let statusText = manifest["status"]?.stringValue else {
            throw ResumeReviewError.malformedManifest("status")
        }
        guard let request = manifest["request"]?.objectValue,
            let question = request["question"]?.stringValue,
            let planValue = manifest["plan"]
        else { throw ResumeReviewError.malformedManifest("request/plan") }
        let planData = try JSONEncoder().encode(planValue)
        let plan = try JSONDecoder().decode(ResearchPlanRecord.self, from: planData)
        let completed =
            manifest["execution"]?["completed_steps"]?.arrayValue?
            .compactMap(\.stringValue) ?? []
        let completedSet = Set(completed)
        let remaining = plan.steps.map(\.stepID).filter { !completedSet.contains($0) }
        let limitations = manifest["limitations"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let sourceNames = request["source_names"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let roots =
            request["approved_local_roots"]?.arrayValue?.compactMap(\.stringValue)
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL } ?? []
        let limits = request["limits"]
        let capabilities = manifest["capabilities"]?.arrayValue ?? []
        let synthesis = capabilities.first { $0["kind"]?.stringValue == "synthesis" }
        let synthesizerName = synthesis?["name"]?.stringValue ?? "extractive"
        let hasNetworkCapability = capabilities.contains { $0["risk"]?.stringValue == "network_read" }
        var credentials = Set<DesktopCredentialRequirement>()
        // Scholarly source keys are optional optimizations; the model key is required to resume
        // an OpenAI-compatible synthesizer. Selected optional source keys are still injected when
        // present, but their absence must not block anonymous provider access.
        if synthesizerName == "openai-compatible" { credentials.insert(.model) }
        let savedSourceProviders = capabilities.compactMap { capability -> SavedProviderRequirement? in
            guard capability["kind"]?.stringValue == "source",
                let name = capability["name"]?.stringValue,
                let version = capability["version"]?.stringValue
            else { return nil }
            return SavedProviderRequirement(name: name, version: version)
        }
        return ResumeReviewContext(
            runDirectory: runDirectory,
            status: RunStatus(rawOrUnknown: statusText),
            question: question,
            plan: plan,
            completedStepIDs: completed,
            remainingStepIDs: remaining,
            limitations: limitations,
            sourceNames: sourceNames,
            synthesizerName: synthesizerName,
            exactLocalRoots: roots,
            maxRecords: limits?["max_records"]?.intValue ?? 50,
            maxNetworkRequests: limits?["max_network_requests"]?.intValue ?? 10,
            timeoutSeconds: limits?["timeout_seconds"]?.intValue ?? 300,
            requiresNetworkGrant: hasNetworkCapability
                || sourceNames.contains(where: { ["openalex", "crossref"].contains($0) })
                || synthesizerName == "openai-compatible",
            credentialRequirements: credentials,
            savedSourceProviders: savedSourceProviders
        )
    }

    public func rootsMatch(_ selected: [URL]) -> Bool {
        selected.map(\.standardizedFileURL.path) == exactLocalRoots.map(\.standardizedFileURL.path)
    }

    public func networkGrantScope(modelConfig: ModelConfigSummary?) -> NetworkGrantScope {
        var destinations: [String] = []
        if sourceNames.contains("openalex") { destinations.append("https://api.openalex.org") }
        if sourceNames.contains("crossref") { destinations.append("https://api.crossref.org") }
        if let modelConfig { destinations.append(modelConfig.origin) }
        return NetworkGrantScope(
            capabilityNames: sourceNames + [synthesizerName],
            destinations: destinations,
            maxNetworkRequests: maxNetworkRequests,
            timeoutSeconds: timeoutSeconds,
            includesLocalData: !exactLocalRoots.isEmpty,
            configurationSHA256: modelConfig?.sha256
        )
    }

    public func providerPreflight(available providers: [ProviderIdentity]) -> ProviderPreflightResult {
        var missing: [SavedProviderRequirement] = []
        var mismatches: [SavedProviderRequirement] = []
        var unavailable: [SavedProviderRequirement] = []
        for requirement in savedSourceProviders {
            let named = providers.filter { $0.name == requirement.name }
            guard !named.isEmpty else {
                missing.append(requirement)
                continue
            }
            guard let exact = named.first(where: { $0.version == requirement.version }) else {
                mismatches.append(requirement)
                continue
            }
            if !exact.available { unavailable.append(requirement) }
        }
        return ProviderPreflightResult(
            missing: missing,
            versionMismatches: mismatches,
            unavailable: unavailable
        )
    }
}

public struct DesktopRunEvent: Equatable, Sendable {
    public let type: String
    public let stepID: String?
    public let payload: JSONValue

    public init(type: String, stepID: String?, payload: JSONValue) {
        self.type = type
        self.stepID = stepID
        self.payload = payload
    }
}

public enum DesktopStepState: String, Equatable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

public struct ActiveRunProjection: Equatable, Sendable {
    public let steps: [String: DesktopStepState]
    public let sources: Int
    public let evidence: Int
    public let claims: Int
    public let cancellationRequested: Bool
}

public enum ActiveRunProjector {
    public static let stepIDs = ["discover", "extract", "synthesize", "validate", "report"]

    public static func project(_ events: [DesktopRunEvent]) -> ActiveRunProjection {
        var steps = Dictionary(uniqueKeysWithValues: stepIDs.map { ($0, DesktopStepState.pending) })
        var sources = 0
        var evidence = 0
        var claims = 0
        var cancellation = false
        for event in events {
            if let step = event.stepID, steps[step] != nil {
                if event.type == "step.started" { steps[step] = .running }
                if event.type == "step.completed" { steps[step] = .completed }
                if event.type == "step.failed" { steps[step] = .failed }
            }
            if event.type == "run.cancelled" { cancellation = true }
            if event.type == "run.cancellation_requested" { cancellation = true }
            let outputs = event.payload["outputs"]
            sources = max(sources, outputs?["source_ids"]?.arrayValue?.count ?? 0)
            evidence = max(evidence, outputs?["evidence_ids"]?.arrayValue?.count ?? 0)
            claims = max(claims, outputs?["claim_ids"]?.arrayValue?.count ?? 0)
        }
        if cancellation {
            for step in stepIDs where steps[step] == .running { steps[step] = .cancelled }
        }
        return ActiveRunProjection(
            steps: steps,
            sources: sources,
            evidence: evidence,
            claims: claims,
            cancellationRequested: cancellation
        )
    }
}

public struct TerminalReconciliation: Equatable, Sendable {
    public let isConsistent: Bool
    public let messages: [String]

    public static func evaluate(
        outcome: RunOutcome,
        validation: ValidationReport,
        inspect: JSONValue
    ) -> Self {
        var messages = validation.errors
        guard let summary = inspect["summary"]?.objectValue else {
            return TerminalReconciliation(
                isConsistent: false,
                messages: messages + ["inspect 响应缺少 summary"]
            )
        }
        let checks: [(String, Bool)] = [
            ("run_id 不一致", summary["run_id"]?.stringValue == outcome.runID),
            ("status 不一致", summary["status"]?.stringValue == outcome.status),
            ("sources 计数不一致", summary["sources"]?.intValue == outcome.sources),
            ("evidence 计数不一致", summary["evidence"]?.intValue == outcome.evidence),
            ("claims 计数不一致", summary["claims"]?.intValue == outcome.claims),
        ]
        messages += checks.filter { !$0.1 }.map(\.0)
        return TerminalReconciliation(isConsistent: validation.valid && messages.isEmpty, messages: messages)
    }
}

public enum DesktopExternalURLPolicy {
    public static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return false
        }
        return url.host != nil && url.user == nil && url.password == nil
    }
}

public struct AttemptBinding: Equatable, Sendable {
    public private(set) var attemptID: UUID?
    public private(set) var workspace: URL?
    public private(set) var runDirectory: URL?

    public init() {}

    @discardableResult
    public mutating func begin(workspace: URL, fixedRunDirectory: URL? = nil) -> UUID {
        let identifier = UUID()
        attemptID = identifier
        self.workspace = workspace.standardizedFileURL
        runDirectory = fixedRunDirectory?.standardizedFileURL
        return identifier
    }

    public mutating func bind(runDirectory: URL, for identifier: UUID) -> Bool {
        guard attemptID == identifier else { return false }
        let candidate = runDirectory.standardizedFileURL
        if let existing = self.runDirectory { return existing == candidate }
        self.runDirectory = candidate
        return true
    }

    public func cancelTarget(for identifier: UUID) -> URL? {
        guard attemptID == identifier else { return nil }
        return runDirectory
    }

    public mutating func finish(_ identifier: UUID) {
        guard attemptID == identifier else { return }
        attemptID = nil
        workspace = nil
        runDirectory = nil
    }
}
