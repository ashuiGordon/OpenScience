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

    let settings = ClientSettings()
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

    var filteredRuns: [RunListItem] { historyQuery.apply(to: runs) }
    var hasActiveAttempt: Bool { isRunning && attemptBinding.attemptID != nil }

    init() {
        draft.sourceNames = []
        Task { @MainActor in
            refreshHistory()
            probeEngine()
        }
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
                    self.pendingPlan = envelope.plan
                    self.pendingPlanContext = self.makePlanReviewContext(
                        plan: envelope.plan,
                        draft: draftSnapshot,
                        modelSummary: modelSummary
                    )
                    self.isShowingPlanReview = true
                    self.announce("研究计划已生成，请审阅后明确批准。")
                } catch {
                    self.errorMessage = "无法生成研究计划：\(error.localizedDescription)"
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
            isShowingPlanReview = false
            pendingPlan = nil
            pendingPlanContext = nil
            pendingDraft = nil
            pendingConfiguration = nil
            isRunning = true
            activeRunDirectory = nil
            activeProjection = ActiveRunProjector.project([])
            runStartedAt = Date()
            let attemptID = attemptBinding.begin(workspace: jobWorkspace)
            appendLog("已批准计划 \(plan.planID)。")
            appendLog("启动：\(invocation.redactedDescription)")
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
                if self.engineAvailable { _ = await self.validate(item, announce: false) }
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
            activeRunDirectory = outcomeDirectory
            let reconciliation = try await reconcileTerminal(outcome, directory: outcomeDirectory)
            guard attemptBinding.attemptID == attemptID else { return }
            if reconciliation.isConsistent {
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
            } else {
                errorMessage = "终态核验失败：" + reconciliation.messages.joined(separator: "；")
                appendLog(errorMessage ?? "终态核验失败", stream: .stderr)
            }
        } catch {
            guard attemptBinding.attemptID == attemptID else { return }
            if cancellationRequested {
                operationMessage = "取消请求已发送。运行记录会保留以供验证或恢复。"
            } else {
                errorMessage = error.localizedDescription
                appendLog(error.localizedDescription, stream: .stderr)
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
