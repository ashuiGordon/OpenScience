import AppKit
import Foundation
import OpenScienceCore
import OpenScienceDesktopLogic

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case newResearch
    case history
    case providers
    case settings

    var id: Self { self }
    var title: String {
        switch self {
        case .newResearch: return "新研究"
        case .history: return "历史记录"
        case .providers: return "Providers"
        case .settings: return "设置"
        }
    }
    var symbol: String {
        switch self {
        case .newResearch: return "sparkles"
        case .history: return "clock.arrow.circlepath"
        case .providers: return "shippingbox"
        case .settings: return "gearshape"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct ActivityLog: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let stream: CLIStream?
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedSection: WorkspaceSection? = .newResearch
    @Published var draft = ResearchDraft()
    @Published var runs: [RunListItem] = []
    @Published var selectedRun: RunListItem?
    @Published var runDetail: RunDetail?
    @Published var isLoadingDetail = false
    @Published var isPreparingPlan = false
    @Published var isRunning = false
    @Published var pendingPlan: ResearchPlanRecord?
    @Published var pendingPlanContext: PlanReviewContext?
    @Published var isShowingPlanReview = false
    @Published var planNetworkAcknowledged = false
    @Published var pendingResume: ResumeReviewContext?
    @Published var isShowingResumeReview = false
    @Published var resumeSelectedRoots: [URL] = []
    @Published var resumeCredentialAcknowledged = false
    @Published var resumeNetworkAcknowledged = false
    @Published var resumeFixtureFiles: [URL] = []
    @Published var resumeProviderPreflight: ProviderPreflightResult?
    @Published var resumeProviderPreflightMessage = ""
    @Published var isCheckingResumeProviders = false
    @Published var resumeModelConfig: ModelConfigSummary?
    @Published var activeRunDirectory: URL?
    @Published var progress = RunProgressSnapshot(completedSteps: 0, totalSteps: 5, lastEvent: "就绪")
    @Published var activeProjection = ActiveRunProjector.project([])
    @Published var runStartedAt: Date?
    @Published var cancellationStatus = ""
    @Published private(set) var cancellationRequested = false
    @Published var logs: [ActivityLog] = []
    @Published var errorMessage: String?
    @Published var operationMessage: String?
    @Published var providers: [ProviderDescriptor] = []
    @Published var historyQuery = HistoryQuery()
    @Published var validationStates: [URL: FreshValidationState] = [:]
    @Published var pendingExternalURL: URL?
    @Published var engineStatusText = "正在检查 CLI 引擎…"
    @Published var engineAvailable = false
    @Published var resolvedEngine: ResolvedEngine?
    @Published var claimEvidenceLinks: [ClaimEvidenceSourceLink] = []
    @Published var evidenceJoinError: String?
    @Published var isInspectorPresented = true
    @Published var isSidebarPresented = true
    @Published var workbenchAvailableWidth: CGFloat = 1_440
    @Published var prioritizesInspectorAtNarrowWidth = false
    @Published var inspectorSection: WorkbenchInspectorSection = .context
    @Published var conversationPersistenceIssue: String?
    @Published var designPreviewEvidenceRows: [WorkbenchEvidenceViewData] = []
    @Published var designPreviewArtifacts: [WorkbenchArtifactViewData] = []
    @Published var designPreviewReportMarkdown = ""
    @Published var conversationSearchFocusToken = UUID()
    @Published var conversationContentFindFocusToken = UUID()
    @Published var safeEscapeToken = UUID()
    @Published var conversationReselectionNotice = ""
    @Published var workbenchSelectedEvidenceID: String?
    @Published var workbenchSelectedArtifactID: String?
    @Published var workbenchArtifactPreview: ArtifactPreviewResolution?

    let settings = ClientSettings()
    let conversations: ConversationStore
    let isDesignPreview: Bool
    private let client = OpenScienceCLIClient()
    private let controlClient = OpenScienceCLIClient()
    private let terminalClient = OpenScienceCLIClient()
    private let scanner = RunScanner()
    private let repository = RunRepository()
    private var executionTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var activeJobWorkspace: URL?
    private var activeWorkspace: AttemptWorkspace?
    private var reviewedPlanURL: URL?
    private var pendingDraft: ResearchDraft?
    private var pendingConfiguration: ClientConfiguration?
    private var pendingResumeConfiguration: ClientConfiguration?
    private var networkGrant = OneTimeNetworkGrant()
    private var resumeNetworkGrant = OneTimeNetworkGrant()
    private var attemptBinding = AttemptBinding()
    private var engineProbeID = UUID()
    private var activeConversationSessionID: UUID?
    private var activeConversationRunMessageID: UUID?
    private var lastPersistedProjection: ActiveRunProjection?
    private var activeResearchTurnID: ResearchTurnID?
    private var activeWorkbenchBinding: RunBinding?
    private var activePlanReference: PlanReference?
    private lazy var workbenchCoordinator = WorkbenchCoordinator(store: conversations)

    var filteredRuns: [RunListItem] { historyQuery.apply(to: runs) }
    var hasActiveAttempt: Bool { isRunning && attemptBinding.attemptID != nil }

    init() {
        isDesignPreview = CommandLine.arguments.contains("--design-preview")
        let storeResult = Self.makeConversationStore(isDesignPreview: isDesignPreview)
        conversations = storeResult.store
        conversationPersistenceIssue =
            storeResult.issue
            ?? storeResult.store.issues.first.map {
                "\($0.outcome)：\($0.safeDetail)"
            }
        draft.sourceNames = []
        if isDesignPreview {
            seedDesignPreview()
            return
        }
        restoreConversationLayout()
        _ = restoreConversationDraftForSelection()
        Task { @MainActor in
            refreshHistory()
            probeEngine()
        }
    }

    var workbenchCanSubmit: Bool {
        engineAvailable && !isPreparingPlan && !isRunning && pendingPlan == nil
            && !(draft.useNetworkModel && !draft.localRoots.isEmpty)
    }

    var workbenchCanOfferExport: Bool {
        guard engineAvailable, let run = selectedRun,
            [.completed, .partial].contains(run.status),
            run.structuralIssue == nil,
            let state = validationStates[run.directory], state.isFresh(for: run.updatedAt)
        else { return false }
        return state.permitsMutation
    }

    func workbenchFindMatchCount(_ query: String) -> Int {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return 0 }
        var values = conversations.selectedSession?.messages.map(\.text) ?? []
        if let detail = runDetail {
            values.append(detail.reportMarkdown)
            values.append(
                contentsOf: detail.sources.flatMap {
                    [$0.title, $0.abstractOrExcerpt ?? ""]
                })
            values.append(contentsOf: detail.evidence.map(\.passage))
            values.append(contentsOf: detail.claims.map(\.text))
        }
        return values.reduce(0) { total, value in
            let source = value as NSString
            var count = 0
            var searchRange = NSRange(location: 0, length: source.length)
            while searchRange.length > 0 {
                let found = source.range(
                    of: needle,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                )
                if found.location == NSNotFound { break }
                count += 1
                let nextLocation = found.location + max(found.length, 1)
                searchRange = NSRange(
                    location: nextLocation,
                    length: max(0, source.length - nextLocation)
                )
            }
            return total + count
        }
    }

    var hasActiveRunInAnotherConversation: Bool {
        isRunning && activeConversationSessionID != nil
            && activeConversationSessionID != conversations.selectedSessionID
    }

    var isSelectedActiveConversation: Bool {
        conversations.selectedSessionID != nil
            && conversations.selectedSessionID == activeConversationSessionID
    }

    var isSidebarEffectivelyVisible: Bool {
        isDesignPreview
            || (isSidebarPresented && workbenchAvailableWidth >= 820
                && !prioritizesInspectorAtNarrowWidth)
    }

    var isInspectorEffectivelyVisible: Bool {
        isDesignPreview
            || (isInspectorPresented
                && (workbenchAvailableWidth >= 1_220
                    || (prioritizesInspectorAtNarrowWidth && workbenchAvailableWidth >= 984)))
    }

    var workbenchComposerDraftText: String {
        conversations.selectedSession?.draft?.text ?? ""
    }

    var workbenchModelName: String {
        if !draft.useNetworkModel { return "本地 Extractive" }
        guard !settings.modelConfigPath.isEmpty else { return "OpenAI-compatible" }
        return URL(fileURLWithPath: settings.modelConfigPath).deletingPathExtension().lastPathComponent
    }

    var workbenchToolAvailabilityText: String {
        if isDesignPreview { return "5/5 可用" }
        return "\(providers.filter(\.available).count)/\(providers.count) 可用"
    }

    var workbenchNetworkStatus: String {
        if isSelectedActiveConversation, pendingPlanContext?.requiresNetworkGrant == true {
            return planNetworkAcknowledged ? "本次已批准" : "待批准访问"
        }
        return draft.sourceNames.contains(where: { ["openalex", "crossref"].contains($0) })
            || draft.useNetworkModel
            ? "按计划授权" : "离线"
    }

    var workbenchNetworkDestinations: [String] {
        if isSelectedActiveConversation, let context = pendingPlanContext {
            return context.networkCapabilities.compactMap(\.destination)
        }
        if isDesignPreview {
            return ["cafa.org", "proteingym.org", "pubmed.ncbi.nlm.nih.gov", "arxiv.org"]
        }
        return []
    }

    var workbenchPlanSteps: [WorkbenchPlanStepViewData] {
        if isSelectedActiveConversation, let steps = pendingPlanContext?.plan.steps, !steps.isEmpty {
            return steps.map {
                WorkbenchPlanStepViewData(
                    id: $0.stepID,
                    title: $0.title,
                    purpose: $0.purpose,
                    dependencies: $0.dependencies,
                    capability: $0.capability.nilIfEmpty ?? "unknown — capability not recorded",
                    completionCondition: $0.completionCondition.nilIfEmpty
                        ?? "unknown — completion condition not recorded",
                    recordedStatus: $0.status.nilIfEmpty ?? "unknown — status not recorded"
                )
            }
        }
        if let planValue = runDetail?.manifest["plan"],
            let data = try? JSONEncoder().encode(planValue),
            let plan = try? JSONDecoder().decode(ResearchPlanRecord.self, from: data),
            !plan.steps.isEmpty
        {
            return plan.steps.map {
                WorkbenchPlanStepViewData(
                    id: $0.stepID,
                    title: $0.title,
                    purpose: $0.purpose,
                    dependencies: $0.dependencies,
                    capability: $0.capability.nilIfEmpty ?? "unknown — capability not recorded",
                    completionCondition: $0.completionCondition.nilIfEmpty
                        ?? "unknown — completion condition not recorded",
                    recordedStatus: $0.status.nilIfEmpty ?? "unknown — status not recorded"
                )
            }
        }
        if let planMessage = conversations.selectedSession?.messages.last(where: { $0.kind == .plan }) {
            let titles = planMessage.text.split(whereSeparator: \.isNewline).dropFirst()
            if !titles.isEmpty {
                return titles.enumerated().map { index, line in
                    WorkbenchPlanStepViewData(
                        id: index < ActiveRunProjector.stepIDs.count
                            ? ActiveRunProjector.stepIDs[index] : "step-\(index + 1)",
                        title: line.replacingOccurrences(
                            of: #"^\d+\.\s*"#,
                            with: "",
                            options: .regularExpression
                        ),
                        purpose: "unknown — purpose not available in recorded timeline text",
                        dependencies: [
                            "unknown — dependencies not available in recorded timeline text"
                        ],
                        capability: "unknown — capability not available in recorded timeline text",
                        completionCondition:
                            "unknown — completion condition not available in recorded timeline text",
                        recordedStatus: "unknown — status not available in recorded timeline text"
                    )
                }
            }
        }
        return []
    }

    var workbenchPlanCapabilities: [String] {
        guard isSelectedActiveConversation, let context = pendingPlanContext else {
            if let capabilities = runDetail?.manifest["capabilities"]?.arrayValue {
                let values: [String] = capabilities.compactMap { capability -> String? in
                    guard let name = capability["name"]?.stringValue else { return nil }
                    let risk = capability["risk"]?.stringValue ?? "recorded"
                    return "\(name) · \(risk.replacingOccurrences(of: "_", with: " "))"
                }
                return values.isEmpty
                    ? ["unknown — provider capability and risk not recorded"] : values
            }
            if isDesignPreview {
                return ["公开网络读取 · 一次性授权", "本地计算 · 无外发", "报告写入 · Run 工作区"]
            }
            return workbenchPlanSteps.isEmpty
                ? [] : ["unknown — provider capability and risk not recorded"]
        }
        return (context.sources + [context.synthesizer]).map {
            "\($0.name) · \($0.risk.replacingOccurrences(of: "_", with: " "))"
        }
    }

    var workbenchPlanLimits: [(label: String, value: String)] {
        if isSelectedActiveConversation, let context = pendingPlanContext {
            return [
                ("记录上限", "\(context.maxRecords)"),
                ("网络请求上限", "\(context.maxNetworkRequests)"),
                ("超时", "\(context.timeoutSeconds) 秒"),
            ]
        }
        if let limits = runDetail?.manifest["request"]?["limits"] {
            return [
                ("记录上限", limits["max_records"]?.intValue.map(String.init) ?? "unknown"),
                (
                    "网络请求上限",
                    limits["max_network_requests"]?.intValue.map(String.init) ?? "unknown"
                ),
                (
                    "超时",
                    limits["timeout_seconds"]?.intValue.map { "\($0) 秒" } ?? "unknown"
                ),
            ]
        }
        if isDesignPreview {
            return [
                ("记录上限", "92"),
                ("网络请求上限", "16"),
                ("超时", "300 秒"),
            ]
        }
        return [
            ("记录上限", "unknown — not recorded"),
            ("网络请求上限", "unknown — not recorded"),
            ("超时", "unknown — not recorded"),
        ]
    }

    var workbenchSourceNames: String {
        var names = draft.sourceNames
        if !draft.localRoots.isEmpty { names.append("本地目录") }
        if !draft.fixtureFiles.isEmpty { names.append("Fixture") }
        return names.isEmpty ? "尚未选择" : names.joined(separator: "、")
    }

    var workbenchQuestion: String {
        if isSelectedActiveConversation, let question = pendingPlanContext?.question, !question.isEmpty {
            return question
        }
        if let question = runDetail?.item.question, !question.isEmpty { return question }
        return conversations.selectedSession?.messages.last(where: { $0.role == .user })?.text
            ?? "尚未提交"
    }

    var workbenchSessionStatusText: String {
        guard let status = conversations.selectedSession?.status else { return "未选择" }
        switch status {
        case .draft: return "草稿"
        case .planning: return "正在规划"
        case .awaitingApproval: return "等待批准"
        case .running: return "正在运行"
        case .completed: return "已完成"
        case .partial: return "部分完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .interrupted: return "已中断"
        case .invalid: return "完整性无效"
        case .unknown: return "待重新核验"
        }
    }

    var workbenchEvidenceRows: [WorkbenchEvidenceViewData] {
        if let detail = runDetail {
            guard Set(detail.sources.map(\.sourceID)).count == detail.sources.count,
                Set(detail.evidence.map(\.evidenceID)).count == detail.evidence.count
            else { return [] }
            let sources = Dictionary(uniqueKeysWithValues: detail.sources.map { ($0.sourceID, $0) })
            let links = Dictionary(grouping: claimEvidenceLinks, by: { $0.evidence.evidenceID })
            return detail.evidence.map { evidence in
                let source = sources[evidence.sourceID]
                let evidenceLinks = links[evidence.evidenceID] ?? []
                let authorText =
                    source?.authors.prefix(3).joined(separator: ", ")
                    .nilIfEmpty ?? "unknown — authors not recorded"
                let publication =
                    source?.publicationDate?.nilIfEmpty
                    ?? "unknown — publication date not recorded"
                let citation = "\(authorText) (\(publication)). \(source?.title ?? evidence.sourceID)"
                let claimKinds = Set(evidenceLinks.map(\.claim.kind).filter { !$0.isEmpty })
                    .sorted()
                let confidences = evidenceLinks.compactMap(\.claim.confidence)
                    .map { String(format: "%.3f", $0) }
                let limitations = Array(
                    Set(evidenceLinks.flatMap(\.claim.limitations).filter { !$0.isEmpty })
                ).sorted()
                let retrievals: [String] =
                    source?.retrievals.map { retrieval in
                        let provider =
                            retrieval.provider.nilIfEmpty
                            ?? "unknown provider"
                        let timestamp =
                            retrieval.retrievedAt.nilIfEmpty
                            ?? "unknown retrieval time"
                        return "\(provider) · \(timestamp)"
                    } ?? []
                return WorkbenchEvidenceViewData(
                    id: evidence.evidenceID,
                    sourceID: evidence.sourceID,
                    title: source?.title.nilIfEmpty ?? "unknown — source title not recorded",
                    citation: citation,
                    passage: evidence.passage.nilIfEmpty ?? "unknown — evidence passage not recorded",
                    locator: evidence.locator.nilIfEmpty ?? "unknown — locator not recorded",
                    url: source?.landingURL.flatMap(URL.init(string:)),
                    stance: evidence.stance.nilIfEmpty ?? "unknown — stance not recorded",
                    relevance: String(format: "%.3f", evidence.relevance),
                    claimKind: claimKinds.isEmpty
                        ? "unknown — no joined claim kind" : claimKinds.joined(separator: ", "),
                    confidence: confidences.isEmpty
                        ? "unknown — confidence not recorded" : confidences.joined(separator: ", "),
                    limitations: evidenceLinks.isEmpty
                        ? ["unknown — no joined claim limitations"]
                        : (limitations.isEmpty ? ["none recorded"] : limitations),
                    license: evidence.license?.nilIfEmpty ?? source?.license?.nilIfEmpty
                        ?? "unknown — license not recorded",
                    sourceStatus: source?.status?.nilIfEmpty
                        ?? "unknown — source status not recorded",
                    retrievalProvenance: retrievals.isEmpty
                        ? ["unknown — retrieval provenance not recorded"] : retrievals,
                    createdByStep: evidence.createdByStep?.nilIfEmpty
                        ?? "unknown — producing step not recorded",
                    contentHash: evidence.contentHash?.nilIfEmpty ?? source?.contentHash?.nilIfEmpty
                        ?? "unknown — content hash not recorded"
                )
            }
        }
        return designPreviewEvidenceRows
    }

    var workbenchArtifacts: [WorkbenchArtifactViewData] {
        if isDesignPreview { return designPreviewArtifacts }
        var values: [WorkbenchArtifactViewData] = []
        if let detail = runDetail {
            values = manifestArtifactRows(detail)
        }
        let fallbackRunID = runDetail?.item.runID ?? conversations.selectedSession?.linkedRunIDs.last
        let referenced =
            conversations.selectedSession?.messages
            .flatMap(\.artifactReferences)
            .map {
                WorkbenchArtifactViewData(
                    id: $0.id,
                    title: $0.title,
                    subtitle: $0.kind.rawValue.capitalized,
                    symbol: artifactSymbol($0.kind),
                    runID: fallbackRunID
                )
            } ?? []
        if values.isEmpty {
            for value in referenced where !values.contains(where: { $0.id == value.id }) {
                values.append(value)
            }
        }
        return values
    }

    var workbenchReportMarkdown: String {
        if let report = runDetail?.reportMarkdown, !report.isEmpty { return report }
        return designPreviewReportMarkdown
    }

    func workbenchCitations(for message: ConversationMessage) -> [WorkbenchCitationViewData] {
        guard let runID = message.runReference?.runID, isLoadedResultMessage(message) else { return [] }
        if isDesignPreview {
            return designPreviewEvidenceRows.prefix(3).enumerated().map { index, evidence in
                WorkbenchCitationViewData(
                    claimID: "preview-claim-\(index + 1)",
                    evidenceID: evidence.id,
                    sourceID: evidence.sourceID,
                    runID: runID,
                    label: evidence.citation
                )
            }
        }
        guard evidenceJoinError == nil, runDetail?.item.runID == runID else { return [] }
        return claimEvidenceLinks.map { link in
            let authors =
                link.source.authors.isEmpty
                ? "Unknown author" : link.source.authors.joined(separator: ", ")
            return WorkbenchCitationViewData(
                claimID: link.claim.claimID,
                evidenceID: link.evidence.evidenceID,
                sourceID: link.source.sourceID,
                runID: runID,
                label: "\(authors). \(link.source.title)."
            )
        }
    }

    var workbenchProvenanceRows: [(label: String, value: String)] {
        if isDesignPreview {
            return [
                ("时间", "今天 09:43"),
                ("模型", "ESM-1b · CAFA-5"),
                ("参数", "batch_size=64 · max_tokens=1024"),
                ("数据", "CAFA-5 v1.0 · 官方测试集"),
                ("Run ID", "7af3b8c"),
                ("状态", "completed · 已核验"),
            ]
        }
        guard let item = runDetail?.item ?? selectedRun else { return [] }
        return [
            ("时间", item.updatedAt.formatted(date: .abbreviated, time: .shortened)),
            ("模型", workbenchModelName),
            ("Run ID", item.runID),
            ("状态", item.status.rawValue),
            ("来源", "\(item.sourceCount)"),
            ("证据 / 结论", "\(item.evidenceCount) / \(item.claimCount)"),
        ]
    }

    func workbenchStepState(_ stepID: String) -> DesktopStepState {
        if isSelectedActiveConversation || isDesignPreview,
            let state = activeProjection.steps[stepID], state != .pending
        {
            return state
        }
        if runDetail?.manifest["execution"]?["completed_steps"]?.arrayValue?
            .compactMap(\.stringValue).contains(stepID) == true
        {
            return .completed
        }
        return isDesignPreview ? previewStepState(stepID) : .pending
    }

    func workbenchPlanSteps(for message: ConversationMessage) -> [WorkbenchPlanStepViewData] {
        if isActivePlanMessage(message) || isDesignPreview { return workbenchPlanSteps }
        let titles = message.text.split(whereSeparator: \.isNewline).dropFirst()
        return titles.enumerated().map { index, line in
            WorkbenchPlanStepViewData(
                id: index < ActiveRunProjector.stepIDs.count
                    ? ActiveRunProjector.stepIDs[index] : "recorded-step-\(index + 1)",
                title: line.replacingOccurrences(
                    of: #"^\d+\.\s*"#,
                    with: "",
                    options: .regularExpression
                ),
                purpose: "unknown — purpose not available in recorded timeline text",
                dependencies: ["unknown — dependencies not available in recorded timeline text"],
                capability: "unknown — capability not available in recorded timeline text",
                completionCondition:
                    "unknown — completion condition not available in recorded timeline text",
                recordedStatus: "unknown — status not available in recorded timeline text"
            )
        }
    }

    func isActivePlanMessage(_ message: ConversationMessage) -> Bool {
        guard let session = conversations.selectedSession,
            session.id == activeConversationSessionID,
            pendingPlan != nil
        else { return false }
        return session.messages.last(where: { $0.kind == message.kind })?.id == message.id
    }

    func isMessageFromActiveConversation(_ message: ConversationMessage) -> Bool {
        guard conversations.selectedSessionID == activeConversationSessionID else { return false }
        return conversations.selectedSession?.messages.contains(where: { $0.id == message.id }) == true
    }

    func isCurrentPlanMessage(_ message: ConversationMessage) -> Bool {
        guard isMessageFromActiveConversation(message), message.kind == .plan else { return false }
        return conversations.selectedSession?.messages.last(where: { $0.kind == .plan })?.id == message.id
    }

    func isActiveRunMessage(_ message: ConversationMessage) -> Bool {
        if isDesignPreview { return true }
        guard conversations.selectedSessionID == activeConversationSessionID,
            message.id == activeConversationRunMessageID,
            let reference = message.runReference
        else { return false }
        if reference.runID.hasPrefix("pending-") { return activeRunDirectory == nil }
        return activeRunDirectory?.lastPathComponent == reference.runID
    }

    func isLoadedResultMessage(_ message: ConversationMessage) -> Bool {
        if isDesignPreview { return true }
        guard let runID = message.runReference?.runID else { return false }
        return selectedRun?.runID == runID && runDetail?.item.runID == runID
    }

    func loadRunReference(_ reference: ConversationRunReference?) {
        guard let runID = reference?.runID else { return }
        let matches = runs.filter { $0.runID == runID }
        guard matches.count == 1 else {
            selectedRun = nil
            runDetail = nil
            claimEvidenceLinks = []
            evidenceJoinError =
                matches.isEmpty
                ? "找不到会话引用的运行 \(runID)。" : "运行引用 \(runID) 不唯一，已阻止预览。"
            errorMessage = evidenceJoinError
            return
        }
        selectRun(matches[0])
    }

    func createConversationProject() {
        do {
            let index = conversations.projects.filter { !$0.isArchived }.count + 1
            _ = try conversations.createProject(title: "OpenScience 项目 \(index)")
            selectedSection = .newResearch
        } catch {
            handleConversationError(error)
        }
    }

    func renameSelectedConversationProject() {
        guard let project = conversations.selectedProject else { return }
        let alert = NSAlert()
        alert.messageText = "重命名项目"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: project.title)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try conversations.renameProject(project.id, title: field.stringValue)
        } catch {
            handleConversationError(error)
        }
    }

    func archiveConversationProject(_ projectID: UUID, archived: Bool = true) {
        if archived, isRunning,
            conversations.projects.first(where: { $0.id == projectID })?.sessions
                .contains(where: { $0.id == activeConversationSessionID }) == true
        {
            errorMessage = "包含运行中会话的项目不能归档。"
            return
        }
        do {
            try conversations.archiveProject(projectID, archived: archived)
        } catch {
            handleConversationError(error)
        }
    }

    func selectConversationProject(_ projectID: UUID) {
        do {
            try conversations.select(projectID: projectID, sessionID: nil)
            selectedSection = .newResearch
            selectedRun = nil
            runDetail = nil
            workbenchSelectedArtifactID = nil
            workbenchArtifactPreview = nil
        } catch {
            handleConversationError(error)
        }
    }

    func createConversationSession() {
        do {
            if conversations.selectedProject == nil {
                _ = try conversations.createProject(title: "OpenScience")
            }
            _ = try conversations.createSession(title: "新研究")
            selectedSection = .newResearch
            selectedRun = nil
            runDetail = nil
            workbenchSelectedArtifactID = nil
            workbenchArtifactPreview = nil
            inspectorSection = .context
        } catch {
            handleConversationError(error)
        }
    }

    func selectConversationSession(_ sessionID: UUID) {
        do {
            try conversations.selectSession(sessionID)
            selectedSection = .newResearch
            workbenchSelectedArtifactID = nil
            workbenchArtifactPreview = nil
            if let runID = conversations.selectedSession?.linkedRunIDs.last {
                let matches = runs.filter { $0.runID == runID }
                if matches.count == 1 {
                    selectRun(matches[0])
                } else {
                    selectedRun = nil
                    runDetail = nil
                    claimEvidenceLinks = []
                    evidenceJoinError =
                        matches.isEmpty
                        ? "找不到会话引用的运行 \(runID)。" : "运行引用 \(runID) 不唯一，已阻止预览。"
                    errorMessage = evidenceJoinError
                }
            } else {
                selectedRun = nil
                runDetail = nil
                claimEvidenceLinks = []
            }
        } catch {
            handleConversationError(error)
        }
    }

    func archiveConversationSession(_ sessionID: UUID, archived: Bool = true) {
        guard !isRunning || sessionID != activeConversationSessionID else {
            errorMessage = "运行中的会话不能归档。"
            return
        }
        do {
            try conversations.archiveSession(sessionID, archived: archived)
        } catch {
            handleConversationError(error)
        }
    }

    func archiveSelectedConversation() {
        guard let sessionID = conversations.selectedSessionID else { return }
        archiveConversationSession(sessionID)
    }

    func renameSelectedConversation() {
        guard let sessionID = conversations.selectedSessionID else { return }
        renameConversationSession(sessionID)
    }

    func renameConversationSession(_ sessionID: UUID) {
        guard
            let session = conversations.projects.lazy.flatMap(\.sessions)
                .first(where: { $0.id == sessionID })
        else { return }
        let alert = NSAlert()
        alert.messageText = "重命名会话"
        alert.informativeText = "名称只保存在本机的会话索引中。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: session.title)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try conversations.renameSession(sessionID, title: field.stringValue)
        } catch {
            handleConversationError(error)
        }
    }

    func confirmDeleteConversationMetadata(_ sessionID: UUID) {
        guard
            let session = conversations.projects.lazy.flatMap(\.sessions)
                .first(where: { $0.id == sessionID })
        else { return }
        guard !isRunning || sessionID != activeConversationSessionID else {
            errorMessage = "运行中的会话不能删除。请先安全取消或等待运行结束。"
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除“\(session.title)”的会话元数据？"
        alert.informativeText =
            "只会删除本机的会话索引、用户消息和安全草稿。关联的 Run、报告、证据与导出文件会继续保留。此操作无法撤销。"
        alert.addButton(withTitle: "删除会话元数据")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let revision = conversations.revision(for: sessionID)
            try conversations.deleteSessionMetadata(sessionID, expectedRevision: revision)
            if activeConversationSessionID == sessionID {
                activeConversationSessionID = nil
                activeConversationRunMessageID = nil
                lastPersistedProjection = nil
            }
            selectedRun = nil
            runDetail = nil
            claimEvidenceLinks = []
            operationMessage = "会话元数据已删除；关联研究 Run 与产物未被删除。"
        } catch {
            handleConversationError(error)
        }
    }

    func submitConversationPrompt(_ prompt: String) -> Bool {
        guard workbenchCanSubmit else {
            if draft.useNetworkModel && !draft.localRoots.isEmpty {
                errorMessage = "隐私保护已阻止本地证据发送给网络模型。"
            }
            return false
        }
        do {
            let session: ConversationSession
            let userMessage: ConversationMessage
            if let selected = conversations.selectedSession {
                userMessage = try conversations.appendMessage(
                    sessionID: selected.id,
                    role: .user,
                    kind: .text,
                    text: prompt
                )
                session = conversations.selectedSession ?? selected
            } else {
                session = try conversations.createSession(title: prompt, prompt: prompt)
                guard let created = session.messages.last(where: { $0.role == .user }) else {
                    throw ConversationStoreError.notFound("created user message")
                }
                userMessage = created
            }
            guard let turn = session.turns.first(where: { $0.message.uuid == userMessage.id }) else {
                throw ConversationStoreError.notFound("research turn")
            }
            activeConversationSessionID = session.id
            activeConversationRunMessageID = nil
            lastPersistedProjection = nil
            activeResearchTurnID = turn.id
            activePlanReference = nil
            activeWorkbenchBinding = nil
            try conversations.setSessionStatus(sessionID: session.id, status: .planning)
            _ = try conversations.appendMessage(
                sessionID: session.id,
                role: .assistant,
                kind: .text,
                text: "我会先生成一份可审阅的五步研究计划；任何网络访问都会单独请求一次性授权。"
            )
            draft.question = prompt
            _ = try conversations.setDraft(
                sessionID: session.id,
                draft: ConversationDraft(text: "", researchDraft: draft)
            )
            selectedSection = .newResearch
            inspectorSection = .context
            startRun()
            return true
        } catch {
            handleConversationError(error)
            return false
        }
    }

    func addConversationAttachments(_ urls: [URL]) {
        for url in urls.map(\.standardizedFileURL) {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                if !draft.localRoots.contains(url) { draft.localRoots.append(url) }
            } else if url.pathExtension.lowercased() == "json", !draft.fixtureFiles.contains(url) {
                draft.fixtureFiles.append(url)
            }
        }
    }

    func presentSettings() { selectedSection = .settings }

    func focusConversationSearch() {
        isSidebarPresented = true
        persistConversationLayout()
        conversationSearchFocusToken = UUID()
    }

    func focusConversationContentFind() {
        conversationContentFindFocusToken = UUID()
    }

    func handleSafeEscape() {
        pendingExternalURL = nil
        operationMessage = nil
        safeEscapeToken = UUID()
    }

    func openActiveConversation() {
        guard let activeConversationSessionID else { return }
        selectConversationSession(activeConversationSessionID)
    }

    func conversationDraftDidChange(composerText: String) {
        if pendingPlan != nil {
            expirePendingPlan("研究设置发生变化。")
        }
        saveConversationDraft(text: composerText)
    }

    @discardableResult
    func restoreConversationDraftForSelection() -> String {
        guard let saved = conversations.selectedSession?.draft else {
            var empty = ResearchDraft()
            empty.sourceNames = []
            draft = empty
            conversationReselectionNotice = ""
            return ""
        }
        var restored = ResearchDraft()
        restored.scope = saved.scope
        restored.constraints = saved.constraints
        restored.assumptions = saved.assumptions
        restored.sourceNames = saved.sourceNames
        restored.email = saved.contactEmail
        restored.maxRecords = saved.maxRecords
        restored.maxNetworkRequests = saved.maxNetworkRequests
        restored.timeoutSeconds = saved.timeoutSeconds
        restored.useNetworkModel = saved.synthesisName == "openai-compatible"
        // Hints are display-only. Filesystem authority is always reacquired from NSOpenPanel.
        restored.localRoots = []
        restored.fixtureFiles = []
        draft = restored
        let hints = saved.localRootHints.map(\.name) + saved.fixtureHints.map(\.name)
        conversationReselectionNotice =
            hints.isEmpty
            ? "" : "需重新选择：" + hints.joined(separator: "、")
        return saved.text
    }

    func saveConversationDraft(text: String, sessionID: UUID? = nil) {
        guard let sessionID = sessionID ?? conversations.selectedSessionID else { return }
        do {
            _ = try conversations.setDraft(
                sessionID: sessionID,
                draft: ConversationDraft(text: text, researchDraft: draft)
            )
        } catch {
            handleConversationError(error)
        }
    }

    func toggleSidebarPresentation() {
        if isSidebarPresented, !isSidebarEffectivelyVisible {
            prioritizesInspectorAtNarrowWidth = false
            if workbenchAvailableWidth < 820 {
                operationMessage = "窗口过窄；请放大窗口以恢复会话栏。"
            }
        } else {
            isSidebarPresented.toggle()
        }
        persistConversationLayout()
    }

    func toggleInspectorPresentation() {
        if isInspectorPresented, !isInspectorEffectivelyVisible {
            prioritizesInspectorAtNarrowWidth = true
            if workbenchAvailableWidth < 984 {
                operationMessage = "窗口过窄；请放大窗口以恢复预览。"
            }
        } else {
            isInspectorPresented.toggle()
            if !isInspectorPresented { prioritizesInspectorAtNarrowWidth = false }
        }
        persistConversationLayout()
    }

    func updateWorkbenchWidth(_ width: CGFloat) {
        workbenchAvailableWidth = width
        if width >= 1_220 { prioritizesInspectorAtNarrowWidth = false }
    }

    func showInspector(_ section: WorkbenchInspectorSection) {
        inspectorSection = section
        isInspectorPresented = true
        if section == .artifacts { refreshWorkbenchArtifactPreview() }
        if workbenchAvailableWidth >= 984, workbenchAvailableWidth < 1_220 {
            prioritizesInspectorAtNarrowWidth = true
        }
        persistConversationLayout()
        guard let sessionID = conversations.selectedSessionID else { return }
        do {
            try conversations.selectInspector(
                InspectorSelection(
                    tab: inspectorTab(for: section),
                    sessionID: sessionID,
                    runID: conversations.selectedSession?.linkedRunIDs.last
                ))
        } catch {
            handleConversationError(error)
        }
    }

    func selectConversationMessage(_ message: ConversationMessage) {
        let section: WorkbenchInspectorSection
        switch message.kind {
        case .plan: section = .plan
        case .permission: section = .context
        case .runProgress, .error: section = .context
        case .result: section = .artifacts
        case .text: return
        }
        if message.runReference != nil, !isActiveRunMessage(message) {
            loadRunReference(message.runReference)
        }
        inspectorSection = section
        isInspectorPresented = true
        if workbenchAvailableWidth >= 984, workbenchAvailableWidth < 1_220 {
            prioritizesInspectorAtNarrowWidth = true
        }
        guard let sessionID = conversations.selectedSessionID else { return }
        do {
            try conversations.selectInspector(
                InspectorSelection(
                    tab: inspectorTab(for: section),
                    sessionID: sessionID,
                    messageID: message.id,
                    runID: message.runReference?.runID,
                    artifactID: message.artifactReferences.first?.id
                ))
            persistConversationLayout()
        } catch {
            handleConversationError(error)
        }
    }

    func selectWorkbenchEvidence(at index: Int) {
        guard workbenchEvidenceRows.indices.contains(index) else { return }
        let evidence = workbenchEvidenceRows[index]
        guard let runID = isDesignPreview ? "7af3b8c" : runDetail?.item.runID else {
            errorMessage = "尚未加载可验证的运行，不能选择证据。"
            return
        }
        selectWorkbenchEvidence(
            evidenceID: evidence.id,
            sourceID: evidence.sourceID,
            runID: runID
        )
    }

    func selectWorkbenchEvidence(evidenceID: String, sourceID: String, runID: String) {
        guard isDesignPreview || runDetail?.item.runID == runID else {
            errorMessage = "证据选择与当前加载的运行不一致。"
            return
        }
        let matches = workbenchEvidenceRows.filter {
            $0.id == evidenceID && $0.sourceID == sourceID
        }
        guard matches.count == 1 else {
            errorMessage =
                matches.isEmpty
                ? "找不到引用的精确证据与来源。" : "证据与来源关联不唯一，已阻止选择。"
            return
        }
        workbenchSelectedEvidenceID = evidenceID
        inspectorSection = .evidence
        isInspectorPresented = true
        if workbenchAvailableWidth >= 984, workbenchAvailableWidth < 1_220 {
            prioritizesInspectorAtNarrowWidth = true
        }
        persistConversationLayout()
        guard let sessionID = conversations.selectedSessionID else { return }
        do {
            try conversations.selectInspector(
                InspectorSelection(
                    tab: .evidence,
                    sessionID: sessionID,
                    runID: runID,
                    artifactID: evidenceID
                ))
        } catch {
            handleConversationError(error)
        }
    }

    func canNavigateWorkbenchEvidence(by offset: Int) -> Bool {
        guard let selectedID = workbenchSelectedEvidenceID,
            let index = workbenchEvidenceRows.firstIndex(where: { $0.id == selectedID })
        else { return false }
        return workbenchEvidenceRows.indices.contains(index + offset)
    }

    func navigateWorkbenchEvidence(by offset: Int) {
        guard let selectedID = workbenchSelectedEvidenceID,
            let index = workbenchEvidenceRows.firstIndex(where: { $0.id == selectedID }),
            workbenchEvidenceRows.indices.contains(index + offset)
        else { return }
        let evidence = workbenchEvidenceRows[index + offset]
        guard let runID = isDesignPreview ? "7af3b8c" : runDetail?.item.runID else {
            errorMessage = "尚未加载可验证的运行，不能导航证据。"
            return
        }
        selectWorkbenchEvidence(
            evidenceID: evidence.id,
            sourceID: evidence.sourceID,
            runID: runID
        )
    }

    func selectWorkbenchArtifact(_ artifact: WorkbenchArtifactViewData) {
        workbenchSelectedArtifactID = artifact.id
        inspectorSection = .artifacts
        isInspectorPresented = true
        resolveWorkbenchArtifact(artifact)
        persistConversationLayout()
        guard let sessionID = conversations.selectedSessionID else { return }
        do {
            try conversations.selectInspector(
                InspectorSelection(
                    tab: .artifacts,
                    sessionID: sessionID,
                    runID: artifact.runID,
                    artifactID: artifact.id
                ))
        } catch {
            handleConversationError(error)
        }
    }

    private func refreshWorkbenchArtifactPreview() {
        let artifacts = workbenchArtifacts
        guard !artifacts.isEmpty else {
            workbenchSelectedArtifactID = nil
            workbenchArtifactPreview = nil
            return
        }
        let selected = artifacts.first(where: { $0.id == workbenchSelectedArtifactID }) ?? artifacts[0]
        workbenchSelectedArtifactID = selected.id
        resolveWorkbenchArtifact(selected)
    }

    private func resolveWorkbenchArtifact(_ artifact: WorkbenchArtifactViewData) {
        if isDesignPreview {
            workbenchArtifactPreview = designPreviewArtifactResolution(for: artifact)
            return
        }
        guard let runID = artifact.runID else {
            workbenchArtifactPreview = .metadata(
                ArtifactPreviewMetadata(
                    runID: "unbound",
                    artifactID: artifact.id,
                    name: artifact.title,
                    mediaType: artifact.mediaType,
                    size: artifact.size,
                    sha256: artifact.sha256
                ),
                reason: .invalidSelection
            )
            return
        }
        let selectedArtifactID = artifact.id
        let root = runtimeConfiguration.runRoot
        var candidates = runs
        if let selectedRun,
            !candidates.contains(where: { $0.directory == selectedRun.directory })
        {
            candidates.append(selectedRun)
        }
        workbenchArtifactPreview = .metadata(
            ArtifactPreviewMetadata(
                runID: runID,
                artifactID: artifact.id,
                name: artifact.title,
                mediaType: artifact.mediaType,
                size: artifact.size,
                sha256: artifact.sha256
            ),
            reason: .unavailable
        )
        Task { [weak self] in
            let resolution = await Task.detached {
                PreviewRouter(root: root).resolveArtifact(
                    ArtifactPreviewSelection(runID: runID, artifactID: selectedArtifactID),
                    from: candidates
                )
            }.value
            guard let self, self.workbenchSelectedArtifactID == selectedArtifactID else { return }
            self.workbenchArtifactPreview = resolution
        }
    }

    private func designPreviewArtifactResolution(
        for artifact: WorkbenchArtifactViewData
    ) -> ArtifactPreviewResolution {
        let metadata = ArtifactPreviewMetadata(
            runID: artifact.runID ?? "7af3b8c",
            artifactID: artifact.id,
            name: artifact.title,
            mediaType: artifact.mediaType,
            size: artifact.size,
            sha256: artifact.sha256
        )
        if artifact.mediaType == "application/pdf", let data = Self.designPreviewPDFData() {
            return .pdf(metadata: metadata, data: data)
        }
        if artifact.mediaType == "text/markdown" {
            return .markdown(metadata: metadata, text: designPreviewReportMarkdown)
        }
        return .metadata(metadata, reason: .unsupportedType)
    }

    private static func designPreviewPDFData() -> Data? {
        let name = "cafa5-esm1b-report"
        if let bundled = Bundle.main.url(
            forResource: name,
            withExtension: "pdf",
            subdirectory: "DesignPreview"
        ) {
            return try? Data(contentsOf: bundled)
        }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/DesignPreview/\(name).pdf")
        return try? Data(contentsOf: source)
    }

    func presentExportPanel() {
        guard selectedRun != nil else {
            showInspector(.artifacts)
            operationMessage = "研究完成后可导出经过验证的研究包。"
            return
        }
        Task { [weak self] in
            guard let self, await self.prepareExportSelected() else { return }
            let panel = NSSavePanel()
            panel.title = "导出 OpenScience 研究包"
            panel.nameFieldStringValue = "\(self.selectedRun?.runID ?? "research").zip"
            guard panel.runModal() == .OK, let output = panel.url else { return }
            self.exportSelected(to: output)
        }
    }

    func revealActiveRun() {
        guard let directory = activeRunDirectory ?? selectedRun?.directory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func probeEngine() {
        let probeID = UUID()
        engineProbeID = probeID
        engineAvailable = false
        resolvedEngine = nil
        engineStatusText = "正在验证引擎版本和安全属性…"
        let explicit =
            settings.cliExecutablePath.isEmpty
            ? nil : URL(fileURLWithPath: settings.cliExecutablePath)
        Task { [weak self] in
            guard let self else { return }
            do {
                let engine = try await EngineResolver(
                    bundleURL: Bundle.main.bundleURL,
                    explicitDevelopmentURL: explicit,
                    timeout: 5
                ).resolve()
                guard self.engineProbeID == probeID else { return }
                self.resolvedEngine = engine
                self.engineAvailable = true
                self.engineStatusText =
                    "兼容引擎 \(engine.version.major).\(engine.version.minor).\(engine.version.patch) · \(engine.source.rawValue)"
                self.refreshProviders()
            } catch {
                guard self.engineProbeID == probeID else { return }
                self.engineAvailable = false
                self.resolvedEngine = nil
                self.providers = []
                self.engineStatusText = error.localizedDescription
            }
        }
    }

    private var runtimeConfiguration: ClientConfiguration {
        settings.configuration(engine: resolvedEngine)
    }

    func startRun() {
        guard engineAvailable else {
            errorMessage = engineStatusText
            return
        }
        guard !isRunning, !isPreparingPlan, pendingPlan == nil else { return }
        errorMessage = nil
        operationMessage = nil
        cancellationRequested = false
        cancellationStatus = ""
        networkGrant.revoke()
        planNetworkAcknowledged = false
        logs.removeAll(keepingCapacity: true)
        progress = RunProgressSnapshot(completedSteps: 0, totalSteps: 5, lastEvent: "准备运行")

        let configuration = runtimeConfiguration
        let draftSnapshot = draft
        do {
            let modelSummary: ModelConfigSummary?
            if draftSnapshot.useNetworkModel {
                guard let modelConfig = configuration.modelConfig else {
                    throw CLICommandError.missingModelConfiguration
                }
                modelSummary = try ModelConfigInspector.inspect(modelConfig)
            } else {
                modelSummary = nil
            }
            let workspace = try AttemptWorkspace.create(under: configuration.runRoot)
            let jobWorkspace = workspace.runsDirectory
            let planURL = jobWorkspace.appendingPathComponent("reviewed-plan.json")
            let invocation = try CLICommandBuilder.plan(
                draft: draftSnapshot,
                configuration: configuration,
                output: planURL,
                jobWorkspace: jobWorkspace
            )
            activeJobWorkspace = jobWorkspace
            activeWorkspace = workspace
            reviewedPlanURL = planURL
            pendingDraft = draftSnapshot
            pendingConfiguration = configuration
            isPreparingPlan = true
            appendLog("生成计划：\(invocation.redactedDescription)")
            Task { [weak self] in
                guard let self else { return }
                defer { self.isPreparingPlan = false }
                do {
                    let result = try await self.controlClient.execute(invocation) { stream, text in
                        Task { @MainActor in self.appendOutput(stream, text) }
                    }
                    let envelope = try CLIResponseDecoder.decode(PlanEnvelope.self, from: result.stdout)
                    if let sessionID = self.activeConversationSessionID,
                        let turnID = self.activeResearchTurnID
                    {
                        guard
                            let requestID =
                                envelope.plan.requestID
                                ?? envelope.request["request_id"]?.stringValue,
                            let revision = self.conversations.revision(for: sessionID)
                        else {
                            throw ConversationStoreError.invalidValue("plan request identity")
                        }
                        let planSHA256 = try SecureFileDigest.sha256(
                            of: planURL,
                            within: jobWorkspace,
                            maximumBytes: 1 * 1_024 * 1_024
                        )
                        let reference = try PlanReference(
                            requestID: requestID,
                            planID: envelope.plan.planID,
                            planSHA256: planSHA256,
                            attemptPrivatePathHint: planURL.lastPathComponent
                        )
                        _ = try self.workbenchCoordinator.bindPlan(
                            conversationID: sessionID,
                            turnID: turnID,
                            planReference: reference,
                            expectedRevision: revision
                        )
                        self.activePlanReference = reference
                    }
                    self.pendingPlan = envelope.plan
                    self.pendingPlanContext = self.makePlanReviewContext(
                        plan: envelope.plan,
                        draft: draftSnapshot,
                        modelSummary: modelSummary
                    )
                    self.isShowingPlanReview = self.activeConversationSessionID == nil
                    if let sessionID = self.activeConversationSessionID,
                        let context = self.pendingPlanContext
                    {
                        let projection = ConversationTimelineProjector.project(
                            plan: envelope.plan,
                            context: context,
                            sessionID: sessionID
                        )
                        self.persistConversationProjection(projection, sessionID: sessionID)
                        _ = try? self.conversations.setSessionStatus(
                            sessionID: sessionID,
                            status: .awaitingApproval
                        )
                        if self.conversations.selectedSessionID == sessionID {
                            self.inspectorSection = .plan
                        }
                    }
                    self.announce("研究计划已生成，请审阅后明确批准。")
                } catch {
                    self.errorMessage = "无法生成研究计划：\(error.localizedDescription)"
                    self.persistConversationFailure("无法生成研究计划：\(error.localizedDescription)")
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func approvePlanAndRun() {
        guard let plan = pendingPlan, let context = pendingPlanContext,
            var approvedDraft = pendingDraft, let planURL = reviewedPlanURL,
            let jobWorkspace = activeJobWorkspace,
            let approvedConfiguration = pendingConfiguration, !isRunning
        else { return }
        guard runtimeConfiguration == approvedConfiguration else {
            expirePendingPlan("运行设置已在计划审阅后改变。")
            return
        }
        if let reviewedModel = context.modelConfig {
            guard let current = try? ModelConfigInspector.inspect(reviewedModel.fileURL),
                current.sha256 == reviewedModel.sha256
            else {
                expirePendingPlan("模型配置已在计划审阅后改变。")
                return
            }
        }
        let executionConfiguration =
            context.modelConfig.map {
                ReviewedModelConfiguration.applying($0, to: approvedConfiguration)
            } ?? approvedConfiguration
        if context.requiresNetworkGrant {
            guard planNetworkAcknowledged, networkGrant.consume(scope: context.networkGrantScope) else {
                errorMessage = "必须独立确认仅本次网络访问后才能执行计划。"
                return
            }
            approvedDraft.allowNetwork = true
        } else {
            approvedDraft.allowNetwork = false
        }
        do {
            let invocation = try CLICommandBuilder.run(
                draft: approvedDraft,
                configuration: executionConfiguration,
                credentials: try settings.credentials(for: approvedDraft),
                jobWorkspace: jobWorkspace,
                reviewedPlan: planURL
            )
            let attemptID = attemptBinding.begin(workspace: jobWorkspace)
            if let sessionID = activeConversationSessionID {
                do {
                    guard let turnID = activeResearchTurnID,
                        let planReference = activePlanReference,
                        let revision = conversations.revision(for: sessionID),
                        let session = conversations.projects.lazy.flatMap(\.sessions)
                            .first(where: { $0.id == sessionID })
                    else { throw ConversationStoreError.notFound("active workbench binding") }
                    let ordinal = session.bindings.filter { $0.turnID == turnID }.count + 1
                    let binding = try RunBinding(
                        bindingID: AttemptBindingID(uuid: attemptID),
                        turnID: turnID,
                        attemptOrdinal: ordinal,
                        requestID: planReference.requestID,
                        planID: planReference.planID,
                        planSHA256: planReference.planSHA256,
                        statusHint: .running
                    )
                    _ = try workbenchCoordinator.bindAttempt(
                        conversationID: sessionID,
                        turnID: turnID,
                        binding: binding,
                        expectedRevision: revision
                    )
                    activeWorkbenchBinding = binding
                } catch {
                    attemptBinding.finish(attemptID)
                    throw error
                }
            }
            isShowingPlanReview = false
            pendingPlan = nil
            pendingPlanContext = nil
            pendingDraft = nil
            pendingConfiguration = nil
            isRunning = true
            activeRunDirectory = nil
            activeProjection = ActiveRunProjector.project([])
            runStartedAt = Date()
            appendLog("已批准计划 \(plan.planID)。")
            appendLog("启动：\(invocation.redactedDescription)")
            if let sessionID = activeConversationSessionID {
                do {
                    try conversations.setSessionStatus(sessionID: sessionID, status: .running)
                    syncConversationRunProgress(runID: "pending-\(plan.planID)", force: true)
                } catch {
                    handleConversationError(error)
                }
            }
            announce("研究已开始，共五个步骤。")
            beginMonitoring(jobWorkspace, attemptID: attemptID)
            executionTask = Task { [weak self] in
                guard let self else { return }
                await self.executeResearch(invocation, attemptID: attemptID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rejectPendingPlan() {
        let rejectedSessionID = activeConversationSessionID
        pendingPlan = nil
        pendingPlanContext = nil
        pendingDraft = nil
        pendingConfiguration = nil
        isShowingPlanReview = false
        networkGrant.revoke()
        planNetworkAcknowledged = false
        reviewedPlanURL = nil
        activeJobWorkspace = nil
        activeWorkspace = nil
        operationMessage = "计划未批准，未调用任何研究 Provider。"
        if let rejectedSessionID {
            do {
                try conversations.setSessionStatus(sessionID: rejectedSessionID, status: .draft)
                _ = try conversations.appendMessage(
                    sessionID: rejectedSessionID,
                    role: .system,
                    kind: .text,
                    text: "计划已拒绝；没有调用任何研究 Provider。"
                )
            } catch {
                handleConversationError(error)
            }
        }
    }

    func setPlanNetworkApproval(_ approved: Bool) {
        planNetworkAcknowledged = approved
        guard let context = pendingPlanContext else { return }
        if approved {
            networkGrant.approve(scope: context.networkGrantScope)
        } else {
            networkGrant.revoke()
        }
    }

    private func expirePendingPlan(_ reason: String) {
        networkGrant.revoke()
        planNetworkAcknowledged = false
        errorMessage = "计划已过期：\(reason) 请重新生成并审阅。"
        pendingPlan = nil
        pendingPlanContext = nil
        pendingDraft = nil
        pendingConfiguration = nil
        reviewedPlanURL = nil
        activeWorkspace = nil
        activeJobWorkspace = nil
        isShowingPlanReview = false
        persistConversationFailure("计划已过期：\(reason)")
    }

    func cancelActive() {
        guard isRunning, let attemptID = attemptBinding.attemptID else { return }
        cancellationRequested = true
        cancellationStatus = "正在定位当前运行…"
        appendLog("正在请求安全取消……")
        Task { [weak self] in
            guard let self else { return }
            // Discover the run from its unique per-job workspace before falling back to termination.
            var runURL = self.attemptBinding.cancelTarget(for: attemptID)
            if runURL == nil, let workspace = self.attemptBinding.workspace {
                for _ in 0..<8 where runURL == nil {
                    let discovered: URL?
                    do {
                        discovered = try self.discoverRunDirectory(in: workspace)
                    } catch {
                        self.errorMessage = "取消已停止：attempt workspace 不唯一或不安全。\(error.localizedDescription)"
                        self.cancellationStatus = "工作区完整性失败"
                        await self.client.cancelCurrent()
                        return
                    }
                    if let discovered,
                        self.attemptBinding.bind(runDirectory: discovered, for: attemptID)
                    {
                        runURL = discovered
                        self.activeRunDirectory = discovered
                    }
                    if runURL == nil { try? await Task.sleep(for: .milliseconds(150)) }
                }
            }
            guard self.attemptBinding.attemptID == attemptID else { return }
            if let runURL, self.attemptBinding.cancelTarget(for: attemptID) == runURL {
                do {
                    let invocation = CLICommandBuilder.cancel(
                        runDirectory: runURL,
                        configuration: self.runtimeConfiguration
                    )
                    _ = try await self.controlClient.execute(invocation) { stream, text in
                        Task { @MainActor in
                            guard self.attemptBinding.attemptID == attemptID else { return }
                            self.appendOutput(stream, text)
                        }
                    }
                    guard self.attemptBinding.attemptID == attemptID else { return }
                    self.cancellationStatus = "取消标记已写入，等待安全边界…"
                    self.appendLog("取消标记已由 CLI 写入运行目录。")
                    self.announce("取消请求已安全写入当前运行。")
                } catch {
                    self.appendLog("写入取消标记失败：\(error.localizedDescription)", stream: .stderr)
                }
                // Give the orchestrator time to observe its durable marker at a safe boundary.
                try? await Task.sleep(for: .seconds(5))
                if self.attemptBinding.attemptID == attemptID, await self.client.hasActiveProcess {
                    self.cancellationStatus = "取消超时，正在终止子进程…"
                    self.appendLog("CLI 未在取消宽限期内退出，正在终止子进程。", stream: .stderr)
                    await self.client.cancelCurrent()
                }
            } else {
                guard self.attemptBinding.attemptID == attemptID else { return }
                self.cancellationStatus = "初始化阶段取消"
                self.appendLog("运行目录尚未创建，将终止初始化进程。", stream: .stderr)
                await self.client.cancelCurrent()
            }
        }
    }

    func refreshHistory() {
        let root = runtimeConfiguration.runRoot
        guard FileManager.default.fileExists(atPath: root.path) else {
            runs = []
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let items = try await Task.detached { try RunScanner().scan(root: root) }.value
                self.runs = items
                for item in items {
                    if let state = RunStructuralPolicy.validationState(for: item) {
                        self.validationStates[item.directory] = state
                    }
                }
                if let selected = self.selectedRun,
                    let updated = items.first(where: { $0.directory == selected.directory })
                {
                    self.selectedRun = updated
                }
            } catch CocoaError.fileReadNoSuchFile {
                self.runs = []
            } catch {
                self.errorMessage = "扫描历史记录失败：\(error.localizedDescription)"
            }
        }
    }

    func selectRun(_ item: RunListItem?) {
        selectedRun = item
        runDetail = nil
        claimEvidenceLinks = []
        evidenceJoinError = nil
        guard let item else { return }
        if let state = RunStructuralPolicy.validationState(for: item) {
            validationStates[item.directory] = state
            isLoadingDetail = false
            if let session = conversations.selectedSession,
                session.linkedRunIDs.contains(item.runID),
                !session.messages.contains(where: { $0.runReference?.runID == item.runID })
            {
                do {
                    _ = try conversations.setSessionStatus(
                        sessionID: session.id,
                        status: .invalid,
                        linkedRunID: item.runID,
                        updatedAt: item.updatedAt
                    )
                    _ = try conversations.appendMessage(
                        sessionID: session.id,
                        role: .assistant,
                        kind: .error,
                        text: "关联运行未通过结构完整性检查，只能只读查看。",
                        runReference: ConversationRunReference(
                            runID: item.runID,
                            status: item.status,
                            sources: item.sourceCount,
                            evidence: item.evidenceCount,
                            claims: item.claimCount
                        )
                    )
                } catch {
                    handleConversationError(error)
                }
            }
            return
        }
        isLoadingDetail = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let root = self.runtimeConfiguration.runRoot
                let detail = try await Task.detached {
                    try RunRepository(root: root).load(item)
                }.value
                guard self.selectedRun?.directory == item.directory else { return }
                self.runDetail = detail
                let freshValidation =
                    self.engineAvailable ? await self.validate(item, announce: false) : nil
                guard self.selectedRun?.directory == item.directory else { return }
                do {
                    self.claimEvidenceLinks = try RunRepository(root: root).joinEvidence(in: detail)
                } catch {
                    self.evidenceJoinError = error.localizedDescription
                    self.validationStates[item.directory] = .invalid(
                        manifestDate: item.updatedAt,
                        errors: [error.localizedDescription],
                        warnings: []
                    )
                }
                self.refreshWorkbenchArtifactPreview()
                if let session = self.conversations.selectedSession,
                    session.linkedRunIDs.contains(item.runID),
                    !session.messages.contains(where: { $0.runReference?.runID == item.runID })
                {
                    let projection = ConversationTimelineProjector.project(
                        detail: detail,
                        sessionID: session.id,
                        timestamp: item.updatedAt
                    )
                    self.persistConversationProjection(projection, sessionID: session.id)
                }
                if let session = self.conversations.selectedSession,
                    session.linkedRunIDs.contains(item.runID),
                    let freshValidation
                {
                    _ = try? self.conversations.setSessionStatus(
                        sessionID: session.id,
                        status: freshValidation.valid && self.evidenceJoinError == nil
                            ? SessionStatus(runStatus: item.status) : .invalid,
                        linkedRunID: item.runID,
                        updatedAt: item.updatedAt
                    )
                }
            } catch {
                self.errorMessage = "读取运行记录失败：\(error.localizedDescription)"
            }
            self.isLoadingDetail = false
        }
    }

    func prepareResumeSelected() {
        guard engineAvailable else {
            errorMessage = engineStatusText
            return
        }
        guard let run = selectedRun, let detail = runDetail, !isRunning else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let report = await self.validate(run, announce: true), report.valid else {
                self.errorMessage = "运行未通过最新完整性验证，只能只读查看。"
                return
            }
            do {
                let context = try ResumeReviewContext.parse(
                    manifest: detail.manifest,
                    runDirectory: run.directory
                )
                guard context.canResumeStatus else {
                    self.errorMessage =
                        context.status == .completed
                        ? "已完成的运行不能恢复。"
                        : "此运行没有可恢复的剩余步骤。"
                    return
                }
                let resumeConfiguration = self.runtimeConfiguration
                let modelSummary: ModelConfigSummary?
                if context.synthesizerName == "openai-compatible" {
                    guard let modelConfig = resumeConfiguration.modelConfig else {
                        throw CLICommandError.missingModelConfiguration
                    }
                    modelSummary = try ModelConfigInspector.inspect(modelConfig)
                } else {
                    modelSummary = nil
                }
                self.pendingResume = context
                self.pendingResumeConfiguration = resumeConfiguration
                self.resumeModelConfig = modelSummary
                self.resumeSelectedRoots = []
                self.resumeCredentialAcknowledged = false
                self.resumeNetworkAcknowledged = false
                self.resumeFixtureFiles = []
                self.resumeProviderPreflight = context.providerPreflight(
                    available: self.providerIdentities(self.providers)
                )
                self.resumeProviderPreflightMessage = self.preflightMessage(
                    self.resumeProviderPreflight
                )
                self.resumeNetworkGrant.revoke()
                self.isShowingResumeReview = true
            } catch {
                self.errorMessage = "无法审阅恢复信息：\(error.localizedDescription)"
            }
        }
    }

    var resumeRootsMatch: Bool {
        pendingResume?.rootsMatch(resumeSelectedRoots) ?? false
    }

    var resumeCredentialsPresent: Bool {
        guard let context = pendingResume else { return false }
        return context.credentialRequirements.allSatisfy(settings.hasCredential)
    }

    var resumeCanApprove: Bool {
        guard let context = pendingResume, context.canResumeStatus, resumeRootsMatch else { return false }
        let credentialsOK =
            context.credentialRequirements.isEmpty
            || (resumeCredentialsPresent && resumeCredentialAcknowledged)
        let networkOK = !context.requiresNetworkGrant || resumeNetworkAcknowledged
        let providersOK = resumeProviderPreflight?.valid == true
        return credentialsOK && networkOK && providersOK && !isCheckingResumeProviders
    }

    func setResumeNetworkApproval(_ approved: Bool) {
        resumeNetworkAcknowledged = approved
        guard let context = pendingResume else { return }
        if approved {
            resumeNetworkGrant.approve(
                scope: context.networkGrantScope(modelConfig: resumeModelConfig)
            )
        } else {
            resumeNetworkGrant.revoke()
        }
    }

    func rejectResume() {
        isShowingResumeReview = false
        pendingResume = nil
        pendingResumeConfiguration = nil
        resumeModelConfig = nil
        resumeSelectedRoots = []
        resumeFixtureFiles = []
        resumeProviderPreflight = nil
        resumeProviderPreflightMessage = ""
        resumeCredentialAcknowledged = false
        resumeNetworkAcknowledged = false
        resumeNetworkGrant.revoke()
        operationMessage = "恢复未批准，未调用任何 Provider。"
    }

    func preflightResumeFixtures(_ files: [URL]) {
        guard let context = pendingResume else { return }
        resumeFixtureFiles = files
        isCheckingResumeProviders = true
        resumeProviderPreflightMessage = "正在本地检查 fixture providers…"
        let invocation = CLICommandBuilder.providers(
            configuration: pendingResumeConfiguration ?? runtimeConfiguration,
            fixtureFiles: files
        )
        Task { [weak self] in
            guard let self else { return }
            defer { self.isCheckingResumeProviders = false }
            do {
                let result = try await self.controlClient.execute(invocation)
                let envelope = try CLIResponseDecoder.decode(
                    ProvidersEnvelope.self,
                    from: result.stdout
                )
                guard self.pendingResume?.runDirectory == context.runDirectory,
                    self.resumeFixtureFiles == files
                else { return }
                self.resumeProviderPreflight = context.providerPreflight(
                    available: self.providerIdentities(envelope.providers)
                )
                self.resumeProviderPreflightMessage = self.preflightMessage(
                    self.resumeProviderPreflight
                )
            } catch {
                self.resumeProviderPreflight = nil
                self.resumeProviderPreflightMessage = "fixture 预检失败：\(error.localizedDescription)"
            }
        }
    }

    func approveResume() {
        guard let context = pendingResume, let resumeConfiguration = pendingResumeConfiguration,
            resumeCanApprove
        else { return }
        guard runtimeConfiguration == resumeConfiguration else {
            errorMessage = "恢复审阅已过期：运行设置发生变化，请重新打开恢复审阅。"
            resumeNetworkGrant.revoke()
            resumeNetworkAcknowledged = false
            return
        }
        if let reviewedModel = resumeModelConfig {
            guard let current = try? ModelConfigInspector.inspect(reviewedModel.fileURL),
                current.sha256 == reviewedModel.sha256
            else {
                errorMessage = "恢复审阅已过期：模型配置发生变化。"
                resumeNetworkGrant.revoke()
                resumeNetworkAcknowledged = false
                return
            }
        }
        let executionConfiguration =
            resumeModelConfig.map {
                ReviewedModelConfiguration.applying($0, to: resumeConfiguration)
            } ?? resumeConfiguration
        var resumeDraft = ResearchDraft()
        resumeDraft.question = context.question
        resumeDraft.sourceNames = context.sourceNames
        resumeDraft.localRoots = resumeSelectedRoots
        resumeDraft.fixtureFiles = resumeFixtureFiles
        resumeDraft.email = draft.email
        resumeDraft.maxRecords = context.maxRecords
        resumeDraft.maxNetworkRequests = context.maxNetworkRequests
        resumeDraft.timeoutSeconds = context.timeoutSeconds
        resumeDraft.useNetworkModel = context.synthesizerName == "openai-compatible"
        if context.requiresNetworkGrant {
            guard
                resumeNetworkGrant.consume(
                    scope: context.networkGrantScope(modelConfig: resumeModelConfig)
                )
            else {
                errorMessage = "本次网络授权已失效，请重新确认。"
                return
            }
            resumeDraft.allowNetwork = true
        }
        do {
            let invocation = try CLICommandBuilder.resume(
                runDirectory: context.runDirectory,
                draft: resumeDraft,
                configuration: executionConfiguration,
                credentials: try settings.credentials(for: resumeDraft)
            )
            isShowingResumeReview = false
            pendingResume = nil
            pendingResumeConfiguration = nil
            resumeModelConfig = nil
            isRunning = true
            cancellationRequested = false
            cancellationStatus = ""
            activeRunDirectory = context.runDirectory
            activeJobWorkspace = context.runDirectory.deletingLastPathComponent()
            activeWorkspace = nil
            runStartedAt = Date()
            let attemptID = attemptBinding.begin(
                workspace: context.runDirectory.deletingLastPathComponent(),
                fixedRunDirectory: context.runDirectory
            )
            let resumedRunID = context.runDirectory.lastPathComponent
            let boundSessions = conversations.projects.flatMap(\.sessions)
                .filter { $0.linkedRunIDs.contains(resumedRunID) }
            activeConversationSessionID = boundSessions.count == 1 ? boundSessions[0].id : nil
            activeConversationRunMessageID = nil
            lastPersistedProjection = nil
            activeResearchTurnID = nil
            activePlanReference = nil
            activeWorkbenchBinding = nil
            if boundSessions.count > 1 {
                appendLog(
                    "恢复运行的会话绑定不唯一；本次结果不会投影到任何会话。",
                    stream: .stderr
                )
            }
            if let session = boundSessions.count == 1 ? boundSessions[0] : nil {
                var establishedTypedBinding = false
                if let prior = session.bindings.last(where: { $0.runID == resumedRunID }),
                    let turn = session.turns.first(where: { $0.id == prior.turnID }),
                    let planReference = turn.planReference,
                    let revision = conversations.revision(for: session.id)
                {
                    do {
                        let ordinal = session.bindings.filter { $0.turnID == turn.id }.count + 1
                        let binding = try RunBinding(
                            bindingID: AttemptBindingID(uuid: attemptID),
                            turnID: turn.id,
                            attemptOrdinal: ordinal,
                            runID: resumedRunID,
                            managedRelativeReference: resumedRunID,
                            requestID: planReference.requestID,
                            planID: planReference.planID,
                            planSHA256: planReference.planSHA256,
                            statusHint: .running
                        )
                        _ = try workbenchCoordinator.bindAttempt(
                            conversationID: session.id,
                            turnID: turn.id,
                            binding: binding,
                            expectedRevision: revision
                        )
                        activeResearchTurnID = turn.id
                        activePlanReference = planReference
                        activeWorkbenchBinding = binding
                        establishedTypedBinding = true
                    } catch {
                        attemptBinding.finish(attemptID)
                        isRunning = false
                        throw error
                    }
                }
                if !establishedTypedBinding {
                    activeConversationSessionID = nil
                    appendLog(
                        "恢复运行缺少可验证的 ResearchTurn/Attempt 绑定；本次结果不会写入会话。",
                        stream: .stderr
                    )
                }
                if establishedTypedBinding {
                    activeConversationRunMessageID =
                        session.messages.last(where: {
                            $0.runReference?.runID == resumedRunID
                                && $0.kind == .runProgress
                        })?.id
                    _ = try? conversations.setSessionStatus(
                        sessionID: session.id,
                        status: .running,
                        linkedRunID: resumedRunID
                    )
                    syncConversationRunProgress(runID: resumedRunID, force: true)
                }
            }
            selectedSection = .newResearch
            appendLog("已重新批准保存的计划，恢复：\(invocation.redactedDescription)")
            beginMonitoring(context.runDirectory.deletingLastPathComponent(), attemptID: attemptID)
            executionTask = Task { [weak self] in
                guard let self else { return }
                await self.executeResearch(invocation, attemptID: attemptID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func validateSelected() {
        guard engineAvailable else {
            errorMessage = engineStatusText
            return
        }
        guard let run = selectedRun else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await self.validate(run, announce: true)
        }
    }

    func replaySelected() {
        guard engineAvailable else {
            errorMessage = engineStatusText
            return
        }
        guard let run = selectedRun else { return }
        runControl(
            CLICommandBuilder.replay(runDirectory: run.directory, configuration: runtimeConfiguration),
            success: "离线回放完成"
        )
    }

    func prepareExportSelected() async -> Bool {
        guard engineAvailable else {
            errorMessage = engineStatusText
            return false
        }
        guard let run = selectedRun else { return false }
        guard let report = await validate(run, announce: true), report.valid else {
            errorMessage = "导出已阻止：运行未通过最新完整性验证。"
            return false
        }
        return true
    }

    func exportSelected(to output: URL) {
        guard let run = selectedRun else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let report = await self.validate(run, announce: true), report.valid else {
                self.errorMessage = "导出已阻止：确认目标后运行不再通过验证。"
                return
            }
            do {
                let invocation = CLICommandBuilder.export(
                    runDirectory: run.directory,
                    output: output,
                    configuration: self.runtimeConfiguration
                )
                let result = try await self.controlClient.execute(invocation) { stream, text in
                    Task { @MainActor in self.appendOutput(stream, text) }
                }
                let envelope = try CLIResponseDecoder.decode(
                    ExportEnvelope.self,
                    from: result.stdout
                )
                let size = ByteCountFormatter.string(
                    fromByteCount: Int64(envelope.size),
                    countStyle: .file
                )
                self.operationMessage = "研究包已导出：\(envelope.output)（\(size)）"
                self.appendLog("导出完成：\(envelope.output)，\(envelope.size) bytes")
            } catch {
                self.errorMessage = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    func refreshProviders() {
        guard engineAvailable else {
            providers = []
            return
        }
        let invocation = CLICommandBuilder.providers(configuration: runtimeConfiguration)
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.controlClient.execute(invocation)
                self.providers = try CLIResponseDecoder.decode(ProvidersEnvelope.self, from: result.stdout)
                    .providers
            } catch {
                // Provider discovery is informative; an unset CLI path should not block app launch.
                self.providers = []
            }
        }
    }

    func requestExternalOpen(_ url: URL) {
        guard let safeURL = try? ExternalURLPolicy.validate(url) else {
            errorMessage = "仅允许在明确确认后打开无凭据的 HTTP(S) 来源链接。"
            return
        }
        pendingExternalURL = safeURL
    }

    func confirmExternalOpen() {
        guard let url = pendingExternalURL, (try? ExternalURLPolicy.validate(url)) != nil else {
            pendingExternalURL = nil
            return
        }
        pendingExternalURL = nil
        NSWorkspace.shared.open(url)
    }

    func appendLog(_ message: String, stream: CLIStream? = nil) {
        let safe = Redactor.redact(message)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return }
        let bounded =
            safe.count > 8_192
            ? String(safe.prefix(8_192)) + "… [diagnostic truncated]" : safe
        logs.append(ActivityLog(timestamp: Date(), stream: stream, message: bounded))
        if logs.count > 2_000 { logs.removeFirst(logs.count - 2_000) }
    }

    private func executeResearch(_ invocation: CLIInvocation, attemptID: UUID) async {
        defer {
            if attemptBinding.attemptID == attemptID {
                monitorTask?.cancel()
                monitorTask = nil
                isRunning = false
                executionTask = nil
                attemptBinding.finish(attemptID)
                activeWorkbenchBinding = nil
                activeWorkspace = nil
                activeJobWorkspace = nil
                refreshHistory()
            }
        }
        do {
            let result = try await client.execute(invocation) { [weak self] stream, text in
                Task { @MainActor in
                    guard self?.attemptBinding.attemptID == attemptID else { return }
                    self?.appendOutput(stream, text)
                }
            }
            guard attemptBinding.attemptID == attemptID else { return }
            let outcome = try CLIResponseDecoder.decode(RunOutcome.self, from: result.stdout)
            let outcomeDirectory = URL(fileURLWithPath: outcome.runDirectory, isDirectory: true)
                .standardizedFileURL
            let authoritativeDirectory: URL
            if let safeWorkspace = activeWorkspace {
                authoritativeDirectory = try safeWorkspace.resolveRunDirectory()
            } else if let bound = attemptBinding.cancelTarget(for: attemptID) {
                authoritativeDirectory = bound
            } else {
                throw CLIExecutionFailure(
                    exitCode: result.exitCode,
                    message: "当前 attempt 没有权威运行目录。",
                    code: "desktop.attempt_missing"
                )
            }
            guard outcomeDirectory == authoritativeDirectory,
                attemptBinding.bind(runDirectory: outcomeDirectory, for: attemptID)
            else {
                throw CLIExecutionFailure(
                    exitCode: result.exitCode,
                    message: "CLI 返回的运行目录不属于当前不可变 attempt workspace。",
                    code: "desktop.attempt_mismatch"
                )
            }
            try bindDiscoveredWorkbenchRun(
                runID: outcome.runID,
                attemptID: attemptID
            )
            activeRunDirectory = outcomeDirectory
            let reconciliation = try await reconcileTerminal(outcome, directory: outcomeDirectory)
            guard attemptBinding.attemptID == attemptID else { return }
            if reconciliation.isConsistent {
                try validateActiveWorkbenchResult(runID: outcome.runID)
                cancellationStatus = outcome.status == "cancelled" ? "已取消" : ""
                let limitationText =
                    outcome.limitations.isEmpty
                    ? "无已记录限制"
                    : "限制：" + outcome.limitations.joined(separator: "；")
                operationMessage = "运行 \(outcome.runID) 已核验，终态 \(outcome.status)。\(limitationText)"
                announce("研究运行已核验，状态 \(outcome.status)。")
                appendLog(
                    "核验终态：\(outcome.status)，\(outcome.sources) sources / \(outcome.evidence) evidence / \(outcome.claims) claims\n\(limitationText)"
                )
                let detail = await loadConversationRunDetail(
                    outcome: outcome,
                    directory: outcomeDirectory
                )
                persistConversationOutcome(outcome, detail: detail)
            } else {
                errorMessage = "终态核验失败：" + reconciliation.messages.joined(separator: "；")
                appendLog(errorMessage ?? "终态核验失败", stream: .stderr)
                persistConversationFailure(errorMessage ?? "终态核验失败")
            }
        } catch let error as WorkbenchCoordinatorError {
            errorMessage = "\(error.code)：\(error.localizedDescription)"
            appendLog(errorMessage ?? error.code, stream: .stderr)
        } catch {
            guard attemptBinding.attemptID == attemptID else { return }
            if cancellationRequested {
                operationMessage = "取消请求已发送。运行记录会保留以供验证或恢复。"
            } else {
                errorMessage = error.localizedDescription
                appendLog(error.localizedDescription, stream: .stderr)
                persistConversationFailure(error.localizedDescription)
            }
        }
    }

    private func runControl(_ invocation: CLIInvocation, success: String) {
        operationMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.controlClient.execute(invocation) { stream, text in
                    Task { @MainActor in self.appendOutput(stream, text) }
                }
                self.operationMessage = success
                if let json = result.json { self.appendLog(json.prettyPrinted) }
                self.refreshHistory()
                if let selected = self.selectedRun { self.selectRun(selected) }
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func beginMonitoring(_ workspace: URL, attemptID: UUID) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            var cursor: EventLogCursor?
            var projectedEvents: [DesktopRunEvent] = []
            while !Task.isCancelled, self.attemptBinding.attemptID == attemptID {
                var discovered = self.attemptBinding.cancelTarget(for: attemptID)
                if discovered == nil {
                    do {
                        discovered = try self.discoverRunDirectory(in: workspace)
                    } catch {
                        self.errorMessage =
                            "attempt workspace 完整性检查失败：\(error.localizedDescription)"
                        self.appendLog(self.errorMessage ?? "工作区失败", stream: .stderr)
                        await self.client.cancelCurrent()
                        return
                    }
                }
                if let directory = discovered,
                    self.attemptBinding.bind(runDirectory: directory, for: attemptID)
                {
                    do {
                        try self.bindDiscoveredWorkbenchRun(
                            runID: directory.lastPathComponent,
                            attemptID: attemptID
                        )
                    } catch {
                        self.errorMessage = "会话运行绑定失败：\(error.localizedDescription)"
                        self.appendLog(self.errorMessage ?? "会话运行绑定失败", stream: .stderr)
                        await self.client.cancelCurrent()
                        return
                    }
                    self.activeRunDirectory = directory
                    if cursor == nil { cursor = EventLogCursor(runID: directory.lastPathComponent) }
                    let eventsURL = directory.appendingPathComponent("events.jsonl")
                    if FileManager.default.fileExists(atPath: eventsURL.path) {
                        do {
                            let read = try cursor?.read(from: eventsURL)
                            let newEvents =
                                read?.events.map {
                                    DesktopRunEvent(type: $0.type, stepID: $0.stepID, payload: $0.payload)
                                } ?? []
                            projectedEvents.append(contentsOf: newEvents)
                            self.activeProjection = ActiveRunProjector.project(projectedEvents)
                            let completed = self.activeProjection.steps.values.filter { $0 == .completed }
                                .count
                            self.progress = RunProgressSnapshot(
                                completedSteps: completed,
                                totalSteps: ActiveRunProjector.stepIDs.count,
                                lastEvent: read?.events.last?.type ?? self.progress.lastEvent
                            )
                            self.syncConversationRunProgress(
                                runID: directory.lastPathComponent,
                                force: false
                            )
                            if self.activeProjection.cancellationRequested {
                                self.cancellationStatus = "运行已记录取消终态"
                            }
                        } catch {
                            self.errorMessage = "事件日志完整性检查失败：\(error.localizedDescription)"
                            self.appendLog(self.errorMessage ?? "事件日志失败", stream: .stderr)
                            return
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    private func appendOutput(_ stream: CLIStream, _ text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            appendLog(String(line), stream: stream)
        }
    }

    private func discoverRunDirectory(in workspace: URL) throws -> URL? {
        if let safeWorkspace = activeWorkspace, safeWorkspace.runsDirectory == workspace {
            do {
                return try safeWorkspace.resolveRunDirectory()
            } catch AttemptWorkspaceError.missingRunDirectory {
                return nil
            }
        }
        return try scanner.discoverActiveRun(jobWorkspace: workspace)
    }

    private func bindDiscoveredWorkbenchRun(runID: String, attemptID: UUID) throws {
        guard let sessionID = activeConversationSessionID,
            let turnID = activeResearchTurnID,
            let current = activeWorkbenchBinding,
            current.id.uuid == attemptID
        else { return }
        if current.runID == runID, current.managedRelativeReference == runID { return }
        guard let revision = conversations.revision(for: sessionID) else {
            throw ConversationStoreError.notFound("active workbench revision")
        }
        let bound = try RunBinding(
            bindingID: current.id,
            turnID: turnID,
            attemptOrdinal: current.attemptOrdinal,
            runID: runID,
            managedRelativeReference: runID,
            requestID: current.requestID,
            planID: current.planID,
            planSHA256: current.planSHA256,
            lastValidatedFingerprint: current.lastValidatedFingerprint,
            statusHint: .running,
            createdAt: current.createdAt
        )
        _ = try workbenchCoordinator.bindAttempt(
            conversationID: sessionID,
            turnID: turnID,
            binding: bound,
            expectedRevision: revision
        )
        activeWorkbenchBinding = bound
    }

    private func validateActiveWorkbenchResult(runID: String) throws {
        guard let conversationID = activeConversationSessionID else { return }
        guard let binding = activeWorkbenchBinding else {
            throw WorkbenchCoordinatorError.bindingStale
        }
        let identity = WorkbenchResultIdentity(
            conversationID: conversationID,
            turnID: binding.turnID,
            attemptBindingID: binding.id,
            requestID: binding.requestID,
            planID: binding.planID,
            planSHA256: binding.planSHA256,
            runID: runID,
            managedRelativeReference: runID
        )
        _ = try workbenchCoordinator.validateResult(identity)
    }

    private func validate(_ run: RunListItem, announce: Bool) async -> ValidationReport? {
        validationStates[run.directory] = .checking
        let invocation = CLICommandBuilder.validate(
            runDirectory: run.directory,
            configuration: runtimeConfiguration
        )
        do {
            let result = try await OpenScienceCLIClient().execute(invocation)
            let report = try CLIResponseDecoder.decode(ValidationReport.self, from: result.stdout)
            validationStates[run.directory] =
                report.valid
                ? .valid(manifestDate: run.updatedAt, warnings: report.warnings)
                : .invalid(
                    manifestDate: run.updatedAt,
                    errors: report.errors,
                    warnings: report.warnings
                )
            if announce {
                var details = [
                    report.valid ? "验证通过" : "验证未通过",
                    "错误 \(report.errors.count) 条，警告 \(report.warnings.count) 条",
                ]
                details.append(contentsOf: report.errors.map { "ERROR: \($0)" })
                details.append(contentsOf: report.warnings.map { "WARNING: \($0)" })
                operationMessage = report.valid ? "完整性验证通过。" : "完整性验证未通过，只读模式。"
                self.announce(report.valid ? "完整性验证通过。" : "完整性验证失败，已切换为只读模式。")
                appendLog(details.joined(separator: "\n"), stream: report.valid ? nil : .stderr)
            }
            return report
        } catch {
            validationStates[run.directory] = .invalid(
                manifestDate: run.updatedAt,
                errors: [error.localizedDescription],
                warnings: []
            )
            if announce { errorMessage = error.localizedDescription }
            return nil
        }
    }

    private func reconcileTerminal(
        _ outcome: RunOutcome,
        directory: URL
    ) async throws -> TerminalReconciliation {
        var eventCursor = EventLogCursor(runID: outcome.runID)
        let eventRead = try eventCursor.read(from: directory.appendingPathComponent("events.jsonl"))
        guard eventRead.issue == nil, let terminalEvent = eventRead.events.last else {
            throw CLIExecutionFailure(
                exitCode: 1,
                message: "终态事件记录不完整或没有完整换行结尾。",
                code: "desktop.terminal_event_incomplete"
            )
        }
        let expectedTerminalEvent = [
            "completed": "run.completed",
            "partial": "run.partial",
            "failed": "run.failed",
            "cancelled": "run.cancelled",
            "awaiting_approval": "run.awaiting_approval",
        ][outcome.status]
        guard terminalEvent.type == expectedTerminalEvent else {
            throw CLIExecutionFailure(
                exitCode: 1,
                message: "终态事件 \(terminalEvent.type) 与结果状态 \(outcome.status) 不一致。",
                code: "desktop.terminal_event_mismatch"
            )
        }
        let validateResult = try await terminalClient.execute(
            CLICommandBuilder.validate(runDirectory: directory, configuration: runtimeConfiguration)
        )
        let validation = try CLIResponseDecoder.decode(
            ValidationReport.self,
            from: validateResult.stdout
        )
        let inspectResult = try await terminalClient.execute(
            CLICommandBuilder.inspect(runDirectory: directory, configuration: runtimeConfiguration)
        )
        let inspect = try CLIResponseDecoder.decodeJSON(from: inspectResult.stdout)
        let date =
            (try? directory.appendingPathComponent("manifest.json").resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
        validationStates[directory] =
            validation.valid
            ? .valid(manifestDate: date, warnings: validation.warnings)
            : .invalid(
                manifestDate: date,
                errors: validation.errors,
                warnings: validation.warnings
            )
        return TerminalReconciliation.evaluate(
            outcome: outcome,
            validation: validation,
            inspect: inspect
        )
    }

    private func makePlanReviewContext(
        plan: ResearchPlanRecord,
        draft: ResearchDraft,
        modelSummary: ModelConfigSummary?
    ) -> PlanReviewContext {
        var sourceReviews = draft.sourceNames.map { name in
            providerReview(name: name, kind: "source")
        }
        if !draft.localRoots.isEmpty, !sourceReviews.contains(where: { $0.name == "local-files" }) {
            sourceReviews.append(
                ProviderReview(name: "local-files", risk: "local_read", kind: "source")
            )
        }
        sourceReviews += draft.fixtureFiles.map {
            ProviderReview(name: "fixture:\($0.lastPathComponent)", risk: "local_read", kind: "source")
        }
        let synthesizer =
            draft.useNetworkModel
            ? ProviderReview(
                name: "openai-compatible",
                risk: "network_read",
                kind: "synthesis",
                networkSummary: "会向 \(modelSummary?.origin ?? "未解析 endpoint") 发送来源与证据",
                destination: modelSummary?.origin
            )
            : ProviderReview(name: "extractive", risk: "local_read", kind: "synthesis")
        return PlanReviewContext(
            question: draft.question,
            sources: sourceReviews,
            synthesizer: synthesizer,
            localRoots: draft.localRoots,
            maxRecords: draft.maxRecords,
            maxNetworkRequests: draft.maxNetworkRequests,
            timeoutSeconds: draft.timeoutSeconds,
            plan: plan,
            modelConfig: modelSummary
        )
    }

    private func providerReview(name: String, kind: String) -> ProviderReview {
        let fixedDestination: String?
        switch name {
        case "openalex": fixedDestination = "https://api.openalex.org"
        case "crossref": fixedDestination = "https://api.crossref.org"
        default: fixedDestination = nil
        }
        if let descriptor = providers.first(where: { $0.name == name }) {
            let network =
                descriptor.risk == "network_read"
                ? "会向 \(fixedDestination ?? name) 发送研究问题与有限检索参数"
                : nil
            return ProviderReview(
                name: name,
                risk: descriptor.risk ?? "unknown",
                kind: descriptor.kind ?? kind,
                networkSummary: network,
                destination: fixedDestination
            )
        }
        let network = ["openalex", "crossref", "openai-compatible"].contains(name)
        return ProviderReview(
            name: name,
            risk: network ? "network_read" : "unknown",
            kind: kind,
            networkSummary: network ? "会向 \(fixedDestination ?? name) 发送研究问题与有限输入" : nil,
            destination: fixedDestination
        )
    }

    private func providerIdentities(_ descriptors: [ProviderDescriptor]) -> [ProviderIdentity] {
        descriptors.map {
            ProviderIdentity(
                name: $0.name,
                version: $0.version ?? "",
                available: $0.available
            )
        }
    }

    private func preflightMessage(_ result: ProviderPreflightResult?) -> String {
        guard let result else { return "尚未检查保存的 Provider 身份。" }
        if result.valid { return "保存的 source provider 名称与版本已精确匹配。" }
        var parts: [String] = []
        if !result.missing.isEmpty {
            parts.append("缺失：" + result.missing.map { "\($0.name)@\($0.version)" }.joined(separator: ", "))
        }
        if !result.versionMismatches.isEmpty {
            parts.append(
                "版本不匹配："
                    + result.versionMismatches.map { "\($0.name)@\($0.version)" }.joined(separator: ", ")
            )
        }
        if !result.unavailable.isEmpty {
            parts.append("不可用：" + result.unavailable.map(\.name).joined(separator: ", "))
        }
        return parts.joined(separator: "；")
    }

    private static func makeConversationStore(
        isDesignPreview: Bool
    ) -> (store: ConversationStore, issue: String?) {
        if isDesignPreview {
            let previewURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "OpenScienceDesignPreview-\(UUID().uuidString)", isDirectory: true
                )
                .appendingPathComponent("workspace-v1.json")
            if let store = try? ConversationStore(fileURL: previewURL, loadIfPresent: false) {
                return (store, nil)
            }
        }

        let applicationSupport =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory =
            applicationSupport
            .appendingPathComponent("OpenScience", isDirectory: true)
            .appendingPathComponent("Conversations", isDirectory: true)
        let storeURL = directory.appendingPathComponent("workspace-v1.json")
        do {
            return (try ConversationStore(fileURL: storeURL), nil)
        } catch {
            let recoveryURL = directory.deletingLastPathComponent()
                .appendingPathComponent(
                    "Conversations-Recovery-\(UUID().uuidString)", isDirectory: true
                )
                .appendingPathComponent("workspace-v1.json")
            if let recovery = try? ConversationStore(fileURL: recoveryURL, loadIfPresent: false) {
                return (
                    recovery,
                    "\(error.localizedDescription) 已切换到新的恢复存储，原文件保持不变。"
                )
            }
        }

        let fallbackURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OpenScienceConversationFallback-\(UUID().uuidString)", isDirectory: true
            )
            .appendingPathComponent("workspace-v1.json")
        guard let fallback = try? ConversationStore(fileURL: fallbackURL, loadIfPresent: false) else {
            preconditionFailure("Unable to initialize a file-backed conversation store")
        }
        return (fallback, "无法访问应用支持目录；本次会话使用临时恢复存储。")
    }

    private func seedDesignPreview() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let date: (String) -> Date = { formatter.date(from: $0) ?? Date(timeIntervalSince1970: 0) }
        let identifier: (String) -> UUID = { UUID(uuidString: $0) ?? UUID() }
        let mainSessionID = identifier("786A1696-A479-4D7F-8D69-A74C0396C700")

        do {
            let project = try conversations.createProject(
                title: "Protein LM Repro",
                now: date("2026-08-27T09:40:00+08:00"),
                id: identifier("29D5A6C7-C9BE-4BB6-9A3F-D29929C73F20")
            )
            let main = try conversations.createSession(
                projectID: project.id,
                title: "Reproduce ESM-1b leaderboard",
                prompt:
                    "Reproduce the ESM-1b results on the latest CAFA-5 leaderboard. Use official splits and report exact metrics with citations.",
                now: date("2026-08-27T09:41:00+08:00"),
                id: mainSessionID
            )
            _ = try conversations.appendMessage(
                sessionID: main.id,
                role: .assistant,
                kind: .text,
                text: "我将复现 ESM-1b 在 CAFA-5 上的结果：获取官方数据与分割，运行蛋白功能预测，计算并复核指标，再与排行榜对比并给出精确引用。",
                timestamp: date("2026-08-27T09:41:08+08:00"),
                id: identifier("949C049E-C3A6-4B48-BA3B-D8F7463A1087")
            )
            _ = try conversations.appendMessage(
                sessionID: main.id,
                role: .assistant,
                kind: .permission,
                text: "计划需要访问 4 个公开来源以获取数据与文献。授权仅适用于这一次运行，凭据不会写入会话。",
                timestamp: date("2026-08-27T09:41:12+08:00"),
                id: identifier("A43B80CE-B0A4-4BE8-B6FE-146038145DAB")
            )
            _ = try conversations.appendMessage(
                sessionID: main.id,
                role: .assistant,
                kind: .plan,
                text: [
                    "研究计划 · 5 个步骤",
                    "1. 获取 CAFA-5 官方数据与分割",
                    "2. 检索并复核相关文献与基线",
                    "3. 运行 ESM-1b 推理",
                    "4. 计算指标并与排行榜对比",
                    "5. 生成报告与引用清单",
                ].joined(separator: "\n"),
                timestamp: date("2026-08-27T09:41:15+08:00"),
                id: identifier("4F1B3CB3-7731-41B7-A433-73D80E2D6CF3")
            )
            _ = try conversations.appendMessage(
                sessionID: main.id,
                role: .assistant,
                kind: .runProgress,
                text: "研究运行已完成\n步骤 5/5\n12 个来源 · 18 条证据 · 3 条结论",
                runReference: ConversationRunReference(
                    runID: "7af3b8c",
                    status: .completed,
                    sources: 12,
                    evidence: 18,
                    claims: 3
                ),
                timestamp: date("2026-08-27T09:43:00+08:00"),
                id: identifier("57A58CC1-8E12-4771-B93F-913E4862C3E6")
            )
            let report = try ConversationArtifactReference(
                id: "report-7af3b8c",
                kind: .report,
                title: "CAFA-5 ESM-1b 复现报告",
                relativePath: "report.md"
            )
            let manifest = try ConversationArtifactReference(
                id: "manifest-7af3b8c",
                kind: .manifest,
                title: "运行清单",
                relativePath: "manifest.json"
            )
            let result = try conversations.appendMessage(
                sessionID: main.id,
                role: .assistant,
                kind: .result,
                text: "已复现 ESM-1b 在 CAFA-5 上的结果。平均 Fmax 为 **0.665 ± 0.004**，与官方排行榜一致；在 92 个提交中排名第 2。",
                runReference: ConversationRunReference(
                    runID: "7af3b8c",
                    status: .completed,
                    sources: 12,
                    evidence: 18,
                    claims: 3
                ),
                artifactReferences: [report, manifest],
                timestamp: date("2026-08-27T09:46:00+08:00"),
                id: identifier("91912D8F-B6CA-463D-A082-EAAFA2ED8792")
            )
            _ = try conversations.setSessionStatus(
                sessionID: main.id,
                status: .completed,
                linkedRunID: "7af3b8c",
                updatedAt: date("2026-08-27T09:41:00+08:00")
            )

            let samples: [(String, String, String, SessionStatus)] = [
                (
                    "C92DC153-E55D-490E-A2DD-F16D6961E18A", "Atlas figure callouts",
                    "2026-08-27T09:12:00+08:00", .completed
                ),
                (
                    "F7500676-9559-4D7A-92C2-60F9130D5E34", "Cross-species atlas review",
                    "2026-08-27T08:57:00+08:00", .completed
                ),
                (
                    "92A9EC70-039C-401D-A61E-B61267585B4D", "Dose-response replication",
                    "2026-08-27T08:34:00+08:00", .completed
                ),
                (
                    "3C77E2E4-130C-4B71-A03D-CEDFD90348D6", "CAFA-5 benchmark audit",
                    "2026-08-26T17:32:00+08:00", .completed
                ),
                (
                    "B598F36E-C310-45E4-B9F2-C0CF0C08EFBD", "ProtTrans reproduction check",
                    "2026-08-26T14:11:00+08:00", .partial
                ),
                (
                    "21C15F75-10A4-45A1-8CB0-6A6B97D4495F", "SCVI hyperparameter sweep",
                    "2026-08-26T10:05:00+08:00", .completed
                ),
                (
                    "63C901B3-B885-4D9C-8BE9-B2BD66E4A479", "UniRef50 masking analysis",
                    "2026-05-17T16:00:00+08:00", .completed
                ),
                (
                    "943FF1F2-7430-4644-A824-E26AF7DE68E4", "BioRxiv preprints scan",
                    "2026-05-16T12:00:00+08:00", .completed
                ),
            ]
            for sample in samples {
                let session = try conversations.createSession(
                    projectID: project.id,
                    title: sample.1,
                    prompt: sample.1,
                    now: date(sample.2),
                    id: identifier(sample.0)
                )
                _ = try conversations.setSessionStatus(
                    sessionID: session.id,
                    status: sample.3,
                    updatedAt: date(sample.2)
                )
            }
            try conversations.select(projectID: project.id, sessionID: main.id)
            try conversations.selectInspector(
                InspectorSelection(
                    tab: .evidence,
                    sessionID: main.id,
                    messageID: result.id,
                    runID: "7af3b8c"
                ))
        } catch {
            conversationPersistenceIssue = "无法生成设计预览：\(error.localizedDescription)"
        }

        draft.question = "Reproduce the ESM-1b results on the latest CAFA-5 leaderboard."
        draft.sourceNames = ["openalex", "crossref"]
        draft.maxRecords = 92
        draft.maxNetworkRequests = 16
        draft.timeoutSeconds = 300
        engineAvailable = true
        engineStatusText = "兼容引擎 0.1.0 · bundled"
        activeConversationSessionID = mainSessionID
        inspectorSection = .evidence
        isInspectorPresented = true
        let completedEvents: [DesktopRunEvent] = [
            DesktopRunEvent(
                type: "provider.completed",
                stepID: "discover",
                payload: .object(["provider": .string("openalex"), "records": .number(46)])
            ),
            DesktopRunEvent(
                type: "provider.completed",
                stepID: "discover",
                payload: .object(["provider": .string("crossref"), "records": .number(46)])
            ),
            DesktopRunEvent(
                type: "provider.completed",
                stepID: "synthesize",
                payload: .object(["provider": .string("extractive"), "records": .number(3)])
            ),
            DesktopRunEvent(
                type: "step.completed", stepID: "discover", payload: .object([:])),
            DesktopRunEvent(
                type: "step.completed", stepID: "extract", payload: .object([:])),
            DesktopRunEvent(
                type: "step.completed", stepID: "synthesize", payload: .object([:])),
            DesktopRunEvent(
                type: "step.completed", stepID: "validate", payload: .object([:])),
            DesktopRunEvent(
                type: "step.completed", stepID: "report", payload: .object([:])),
        ]
        activeProjection = ActiveRunProjector.project(completedEvents)
        progress = RunProgressSnapshot(
            completedSteps: ActiveRunProjector.stepIDs.count,
            totalSteps: ActiveRunProjector.stepIDs.count,
            lastEvent: "run.completed"
        )
        logs = []
        let primaryEvidence = WorkbenchEvidenceViewData(
            id: "ev-cafa5-fmax",
            sourceID: "src-cafa5-paper",
            title: "The CAFA challenges: competition and evaluation",
            citation: "Ofer, D. et al. Proteins 87, 3–16 (2019).",
            passage:
                "ESM-1b achieved an average Fmax of 0.665 on the CAFA-5 server, ranking second overall among 92 submissions.",
            locator: "第 7 页 · Results 部分",
            url: URL(string: "https://doi.org/10.1002/prot.25691"),
            stance: "supports",
            relevance: "0.982",
            claimKind: "sourced_fact",
            confidence: "0.940",
            limitations: ["榜单结果只覆盖记录的 CAFA-5 测试条件。"],
            license: "unknown — license not recorded",
            sourceStatus: "recorded",
            retrievalProvenance: ["crossref · 2026-08-27T09:42:12Z"],
            createdByStep: "extract",
            contentHash: "unknown — content hash not recorded"
        )
        let supportingTitles = [
            "Biological structure and function emerge from scaling unsupervised learning",
            "Evaluating protein transfer learning with TAPE",
            "ProteinGym: large-scale benchmarks for protein fitness prediction",
            "Critical assessment of protein function annotation",
            "Learning the protein language: evolution, structure, and function",
            "UniRef clusters: a comprehensive and scalable alternative",
            "Assessment of computational methods in CAFA",
            "Deep learning for protein function prediction",
            "Ontology-aware evaluation of protein predictions",
            "Benchmarking sequence representation learning",
            "Reproducible evaluation for protein language models",
        ]
        designPreviewEvidenceRows =
            [primaryEvidence]
            + supportingTitles.enumerated().map { index, title in
                WorkbenchEvidenceViewData(
                    id: "ev-support-\(index + 1)",
                    sourceID: "src-support-\(index + 1)",
                    title: title,
                    citation: "Recorded source \(index + 2) · CAFA-5 reproduction corpus.",
                    passage:
                        "This recorded passage supports the benchmark setup, comparison baseline, or evaluation protocol used by the reproduced run.",
                    locator: "Recorded source locator \(index + 2)",
                    url: nil,
                    stance: "unknown — stance not recorded",
                    relevance: "unknown — relevance not recorded",
                    claimKind: "unknown — no joined claim kind",
                    confidence: "unknown — confidence not recorded",
                    limitations: ["unknown — no joined claim limitations"],
                    license: "unknown — license not recorded",
                    sourceStatus: "recorded fixture",
                    retrievalProvenance: ["unknown — retrieval provenance not recorded"],
                    createdByStep: "unknown — producing step not recorded",
                    contentHash: "unknown — content hash not recorded"
                )
            }
        designPreviewArtifacts = [
            WorkbenchArtifactViewData(
                id: "artifact-preview-pdf",
                title: "cafa5_esm1b_report.pdf",
                subtitle: "PDF · 1 页 · 静态预览",
                symbol: "doc.richtext.fill",
                runID: "7af3b8c",
                mediaType: "application/pdf",
                size: Self.designPreviewPDFData()?.count
            ),
            WorkbenchArtifactViewData(
                id: "artifact-preview-markdown",
                title: "report.md",
                subtitle: "Markdown · 3 条结论",
                symbol: "doc.richtext",
                runID: "7af3b8c",
                mediaType: "text/markdown"
            ),
        ]
        designPreviewReportMarkdown = """
            # CAFA-5 Leaderboard — ESM-1b Reproduction

            | Model | Average Fmax | Rank |
            |---|---:|---:|
            | ESM-2 | 0.670 ± 0.004 | 1 |
            | **ESM-1b** | **0.665 ± 0.004** | **2** |
            | DeepSeqPan 3.0 | 0.620 ± 0.006 | 3 |

            The reproduced result matches the official leaderboard within the stated tolerance.
            """
        workbenchSelectedArtifactID = designPreviewArtifacts.first?.id
        refreshWorkbenchArtifactPreview()
    }

    private func persistConversationProjection(
        _ projection: ConversationTimelineProjection,
        sessionID: UUID
    ) {
        do {
            for message in projection.messages {
                let persisted = try conversations.appendMessage(
                    sessionID: sessionID,
                    role: message.role,
                    kind: message.kind,
                    text: message.text,
                    runReference: message.runReference,
                    artifactReferences: message.artifactReferences,
                    timestamp: message.timestamp,
                    id: message.id
                )
                if persisted.kind == .runProgress { activeConversationRunMessageID = persisted.id }
            }
            if conversations.selectedSessionID == sessionID {
                try conversations.selectInspector(projection.selection)
            }
        } catch {
            handleConversationError(error)
        }
    }

    private func syncConversationRunProgress(runID: String, force: Bool) {
        guard let sessionID = activeConversationSessionID else { return }
        if !force, lastPersistedProjection == activeProjection { return }
        lastPersistedProjection = activeProjection
        let projection = ConversationTimelineProjector.project(
            activeRun: activeProjection,
            runID: runID,
            sessionID: sessionID
        )
        guard let message = projection.messages.first else { return }
        do {
            let persisted: ConversationMessage
            if let messageID = activeConversationRunMessageID {
                persisted = try conversations.updateMessage(
                    sessionID: sessionID,
                    messageID: messageID,
                    kind: message.kind,
                    text: message.text,
                    runReference: message.runReference,
                    artifactReferences: message.artifactReferences,
                    timestamp: message.timestamp
                )
            } else {
                persisted = try conversations.appendMessage(
                    sessionID: sessionID,
                    role: message.role,
                    kind: message.kind,
                    text: message.text,
                    runReference: message.runReference,
                    artifactReferences: message.artifactReferences,
                    timestamp: message.timestamp,
                    id: message.id
                )
                activeConversationRunMessageID = persisted.id
            }
            try conversations.setSessionStatus(
                sessionID: sessionID,
                status: .running,
                linkedRunID: runID.hasPrefix("pending-") ? nil : runID
            )
            if conversations.selectedSessionID == sessionID {
                try conversations.selectInspector(
                    InspectorSelection(
                        tab: .context,
                        sessionID: sessionID,
                        messageID: persisted.id,
                        runID: runID
                    ))
            }
        } catch {
            handleConversationError(error)
        }
    }

    private func persistConversationOutcome(_ outcome: RunOutcome, detail: RunDetail?) {
        guard let sessionID = activeConversationSessionID else { return }
        let projection = ConversationTimelineProjector.project(
            outcome: outcome,
            detail: detail,
            sessionID: sessionID
        )
        persistConversationProjection(projection, sessionID: sessionID)
        do {
            try conversations.setSessionStatus(
                sessionID: sessionID,
                status: SessionStatus(runStatus: RunStatus(rawOrUnknown: outcome.status)),
                linkedRunID: outcome.runID
            )
        } catch {
            handleConversationError(error)
        }
        if conversations.selectedSessionID == sessionID {
            inspectorSection = detail == nil ? .context : .artifacts
        }
        activeConversationRunMessageID = nil
        lastPersistedProjection = nil
    }

    private func persistConversationFailure(_ message: String) {
        guard let sessionID = activeConversationSessionID else { return }
        do {
            _ = try conversations.appendMessage(
                sessionID: sessionID,
                role: .assistant,
                kind: .error,
                text: message
            )
            try conversations.setSessionStatus(sessionID: sessionID, status: .failed)
        } catch {
            handleConversationError(error)
        }
    }

    private func loadConversationRunDetail(
        outcome: RunOutcome,
        directory: URL
    ) async -> RunDetail? {
        let status = RunStatus(rawOrUnknown: outcome.status)
        let updatedAt =
            (try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date()
        let item = RunListItem(
            runID: outcome.runID,
            directory: directory,
            question: draft.question,
            status: status,
            updatedAt: updatedAt,
            sourceCount: outcome.sources,
            evidenceCount: outcome.evidence,
            claimCount: outcome.claims
        )
        let root = runtimeConfiguration.runRoot
        do {
            let detail = try await Task.detached {
                try RunRepository(root: root).load(item)
            }.value
            if let index = runs.firstIndex(where: { $0.runID == item.runID }) {
                runs[index] = item
            } else {
                runs.insert(item, at: 0)
            }
            if conversations.selectedSessionID == activeConversationSessionID {
                selectedRun = item
                runDetail = detail
                claimEvidenceLinks = (try? RunRepository(root: root).joinEvidence(in: detail)) ?? []
                evidenceJoinError = nil
                refreshWorkbenchArtifactPreview()
            }
            return detail
        } catch {
            appendLog("运行完成，但加载预览失败：\(error.localizedDescription)", stream: .stderr)
            return nil
        }
    }

    private func handleConversationError(_ error: Error) {
        let message = error.localizedDescription
        errorMessage = "会话操作失败：\(message)"
        if case ConversationStoreError.ioFailure = error {
            conversationPersistenceIssue = message
        }
    }

    private func inspectorTab(for section: WorkbenchInspectorSection) -> InspectorTab {
        switch section {
        case .context: return .context
        case .plan: return .plan
        case .evidence: return .evidence
        case .artifacts: return .artifacts
        }
    }

    private func restoreConversationLayout() {
        let state = conversations.layoutState
        isSidebarPresented = state.sidebarVisibility == .shown
        isInspectorPresented = state.previewVisibility == .shown
        inspectorSection = workbenchInspectorSection(for: state.selectedPreviewTab)
    }

    private func persistConversationLayout() {
        do {
            try conversations.setLayoutState(
                ConversationLayoutState(
                    selectedPreviewTab: inspectorTab(for: inspectorSection),
                    sidebarVisibility: isSidebarPresented ? .shown : .collapsed,
                    previewVisibility: isInspectorPresented ? .shown : .collapsed,
                    sidebarWidth: conversations.layoutState.sidebarWidth,
                    previewWidth: conversations.layoutState.previewWidth
                ))
        } catch {
            handleConversationError(error)
        }
    }

    private func workbenchInspectorSection(for tab: InspectorTab) -> WorkbenchInspectorSection {
        switch tab {
        case .context: return .context
        case .plan: return .plan
        case .evidence: return .evidence
        case .artifacts: return .artifacts
        }
    }

    private func artifactSymbol(_ kind: ArtifactKind) -> String {
        switch kind {
        case .report: return "doc.richtext"
        case .manifest: return "checkmark.shield"
        case .source: return "doc.text"
        case .evidence: return "quote.bubble"
        case .export: return "shippingbox"
        case .file: return "doc"
        }
    }

    private func manifestArtifactRows(_ detail: RunDetail) -> [WorkbenchArtifactViewData] {
        guard let artifacts = detail.manifest["artifacts"]?.arrayValue else { return [] }
        return artifacts.compactMap { value in
            guard let object = value.objectValue,
                let artifactID = object["artifact_id"]?.stringValue,
                let name = object["name"]?.stringValue,
                let mediaType = object["media_type"]?.stringValue
            else { return nil }
            let size = object["size"]?.intValue
            let sha256 = object["sha256"]?.stringValue
            let typeLabel: String
            switch mediaType.lowercased() {
            case "text/markdown": typeLabel = "Markdown"
            case "application/pdf": typeLabel = "PDF"
            default: typeLabel = mediaType
            }
            let sizeLabel = size.map {
                ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
            }
            return WorkbenchArtifactViewData(
                id: artifactID,
                title: name,
                subtitle: [typeLabel, sizeLabel, sha256.map { "SHA-256 \($0.prefix(8))…" }]
                    .compactMap { $0 }
                    .joined(separator: " · "),
                symbol: artifactSymbol(mediaType: mediaType, name: name),
                runID: detail.item.runID,
                mediaType: mediaType,
                size: size,
                sha256: sha256
            )
        }
    }

    private func artifactSymbol(mediaType: String, name: String) -> String {
        switch mediaType.lowercased() {
        case "application/pdf": return "doc.richtext.fill"
        case "text/markdown": return "doc.richtext"
        case "application/json": return "checkmark.shield"
        default: return name.lowercased().hasSuffix(".zip") ? "shippingbox" : "doc"
        }
    }

    private func previewStepState(_ stepID: String) -> DesktopStepState {
        ActiveRunProjector.stepIDs.contains(stepID) ? .completed : .pending
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
