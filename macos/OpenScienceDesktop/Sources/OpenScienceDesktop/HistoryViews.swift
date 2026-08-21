import AppKit
import OpenScienceCore
import OpenScienceDesktopLogic
import SwiftUI

struct HistoryListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.filteredRuns.isEmpty {
                ContentUnavailableView(
                    model.runs.isEmpty ? "没有研究记录" : "没有匹配记录",
                    systemImage: "clock",
                    description: Text("运行完成后，记录会出现在这里。")
                )
            } else {
                List(
                    selection: Binding(
                        get: { model.selectedRun },
                        set: { model.selectRun($0) }
                    )
                ) {
                    ForEach(model.filteredRuns) { run in
                        RunRow(
                            run: run,
                            validation: model.validationStates[run.directory] ?? .unknown
                        )
                        .tag(run)
                        .accessibilityLabel(
                            "\(run.question)，状态 \(run.status.rawValue)，\(run.claimCount) 条主张"
                        )
                    }
                }
            }
        }
        .navigationTitle("历史记录")
        .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        .searchable(text: $model.historyQuery.text, prompt: "搜索问题或 Run ID")
        .toolbar {
            Menu {
                ForEach(RunStatus.allCases, id: \.self) { status in
                    Toggle(
                        status.rawValue.replacingOccurrences(of: "_", with: " "),
                        isOn: Binding(
                            get: { model.historyQuery.statuses.contains(status) },
                            set: { enabled in
                                if enabled {
                                    model.historyQuery.statuses.insert(status)
                                } else {
                                    model.historyQuery.statuses.remove(status)
                                }
                            }
                        )
                    )
                }
                Divider()
                Picker("排序", selection: $model.historyQuery.sort) {
                    Text("最新优先").tag(HistorySort.newest)
                    Text("最旧优先").tag(HistorySort.oldest)
                    Text("问题名称").tag(HistorySort.question)
                }
            } label: {
                Label("筛选和排序", systemImage: "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("筛选并排序研究历史")
            Button {
                model.refreshHistory()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .accessibilityLabel("刷新研究历史")
        }
    }
}

private struct RunRow: View {
    let run: RunListItem
    let validation: FreshValidationState

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(run.question)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                validationBadge
                StatusBadge(status: run.status)
            }
            HStack(spacing: 12) {
                Label(String(run.sourceCount), systemImage: "doc.text")
                Label(String(run.evidenceCount), systemImage: "quote.bubble")
                Label(String(run.claimCount), systemImage: "checkmark.seal")
                Spacer()
                Text(run.updatedAt, style: .relative)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var validationBadge: some View {
        switch validation {
        case .unknown:
            Image(systemName: "questionmark.shield")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("尚未验证")
        case .checking:
            ProgressView().controlSize(.mini).accessibilityLabel("正在验证")
        case .valid:
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("最新验证通过")
        case .invalid:
            Image(systemName: "xmark.shield.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("最新验证未通过，只读")
        }
    }
}

struct StatusBadge: View {
    let status: RunStatus

    var body: some View {
        Text(status.rawValue.replacingOccurrences(of: "_", with: " "))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .completed: return .green
        case .partial, .awaitingApproval: return .orange
        case .failed: return .red
        case .cancelled: return .secondary
        case .running: return .blue
        case .created, .unknown: return .secondary
        }
    }
}

struct HistoryDetailContainer: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.isLoadingDetail {
                ProgressView("正在读取并解析运行记录……")
                    .accessibilityLabel("正在加载运行记录")
            } else if let issue = model.selectedRun?.structuralIssue {
                ContentUnavailableView {
                    Label("损坏的运行记录", systemImage: "xmark.shield.fill")
                } description: {
                    Text("\(issue.code)：\(issue.message)\n此记录已隔离为只读，未加载任何内容。")
                }
            } else if let detail = model.runDetail {
                RunDetailView(detail: detail)
            } else {
                ContentUnavailableView(
                    "选择一条研究记录",
                    systemImage: "sidebar.right",
                    description: Text("可查看报告、主张、证据、来源和完整性信息。")
                )
            }
        }
    }
}

private enum DetailTab: String, CaseIterable, Identifiable {
    case report = "报告"
    case claims = "主张"
    case evidence = "证据"
    case sources = "来源"
    case provenance = "溯源"
    var id: Self { self }
}

struct RunDetailView: View {
    @EnvironmentObject private var model: AppModel
    let detail: RunDetail
    @State private var tab: DetailTab = .report
    @State private var inspectedClaim: ClaimRecord?

    private var validation: FreshValidationState {
        model.validationStates[detail.item.directory] ?? .unknown
    }

    private var permitsMutation: Bool {
        validation.isFresh(for: detail.item.updatedAt) && validation.permitsMutation
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(detail.item.question)
                        .font(.title2.bold())
                        .textSelection(.enabled)
                    Spacer()
                    StatusBadge(status: detail.item.status)
                }
                HStack(spacing: 16) {
                    Label("\(detail.sources.count) 来源", systemImage: "doc.text")
                    Label("\(detail.evidence.count) 证据", systemImage: "quote.bubble")
                    Label("\(detail.claims.count) 主张", systemImage: "checkmark.seal")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                validationBanner
                Picker("内容", selection: $tab) {
                    ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("运行详情视图")
            }
            .padding()
            Divider()
            detailContent
        }
        .navigationTitle(detail.item.runID)
        .toolbar { actionMenu }
        .sheet(item: $inspectedClaim) { claim in
            ClaimEvidenceInspector(claim: claim)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.isShowingResumeReview) {
            if let context = model.pendingResume {
                ResumeReviewView(context: context)
                    .environmentObject(model)
            }
        }
    }

    @ViewBuilder
    private var validationBanner: some View {
        switch validation {
        case .unknown:
            Label("等待最新完整性验证，变更操作已禁用。", systemImage: "questionmark.shield")
                .foregroundStyle(.secondary)
        case .checking:
            Label("正在执行离线完整性验证…", systemImage: "shield")
                .foregroundStyle(.secondary)
        case let .valid(_, warnings):
            Label(
                warnings.isEmpty ? "最新完整性验证通过" : "验证通过，含 \(warnings.count) 条警告",
                systemImage: "checkmark.shield.fill"
            )
            .foregroundStyle(.green)
        case let .invalid(_, errors, _):
            Label("完整性验证失败（\(errors.count) 项），当前为只读模式。", systemImage: "xmark.shield.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch tab {
        case .report:
            ScrollView {
                // Report text is untrusted research data. Render it inertly so Markdown links,
                // images, and custom schemes cannot bypass the explicit source URL confirmation.
                Text(verbatim: detail.reportMarkdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .textSelection(.enabled)
                    .accessibilityLabel("Markdown 研究报告")
            }
        case .claims:
            RecordList(records: detail.claims) { claim in
                ClaimCard(claim: claim) { inspectedClaim = claim }
            }
        case .evidence:
            RecordList(records: detail.evidence) { evidence in EvidenceCard(evidence: evidence) }
        case .sources:
            RecordList(records: detail.sources) { source in
                SourceCard(source: source) { model.requestExternalOpen($0) }
            }
        case .provenance:
            ScrollView {
                Text(detail.manifest.prettyPrinted)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .textSelection(.enabled)
                    .accessibilityLabel("运行清单 JSON")
            }
        }
    }

    @ToolbarContentBuilder
    private var actionMenu: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.validateSelected()
            } label: {
                Label("验证", systemImage: "checkmark.shield")
            }
            .accessibilityLabel("验证运行完整性")
            .disabled(!model.engineAvailable)
            Menu {
                Button("审阅并恢复运行") { model.prepareResumeSelected() }
                    .disabled(
                        model.isRunning || !permitsMutation || detail.item.status == .completed
                            || !model.engineAvailable
                            || ![RunStatus.awaitingApproval, .partial, .failed].contains(
                                detail.item.status
                            )
                    )
                Button("离线回放") { model.replaySelected() }
                    .disabled(!model.engineAvailable)
                Button("验证后导出 RO-Crate ZIP…") {
                    Task {
                        if await model.prepareExportSelected() { chooseExportURL() }
                    }
                }
                .disabled(!permitsMutation || !model.engineAvailable)
                Divider()
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([detail.item.directory])
                }
            } label: {
                Label("更多操作", systemImage: "ellipsis.circle")
            }
            .accessibilityLabel("运行操作")
        }
    }

    private func chooseExportURL() {
        let panel = NSSavePanel()
        panel.title = "导出可验证研究包"
        panel.nameFieldStringValue = "\(detail.item.runID).zip"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            let confirmation = NSAlert()
            confirmation.messageText = "替换现有导出文件？"
            confirmation.informativeText = url.path
            confirmation.alertStyle = .warning
            confirmation.addButton(withTitle: "替换并导出")
            confirmation.addButton(withTitle: "取消")
            guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        }
        model.exportSelected(to: url)
    }
}

private struct RecordList<Record: Identifiable, Content: View>: View {
    let records: [Record]
    @ViewBuilder let content: (Record) -> Content

    var body: some View {
        if records.isEmpty {
            ContentUnavailableView("没有记录", systemImage: "tray")
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(records) { content($0) }
                }
                .padding()
            }
        }
    }
}

private struct ClaimCard: View {
    let claim: ClaimRecord
    let inspect: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(claim.text).font(.body).textSelection(.enabled)
                HStack {
                    Label(claim.kind, systemImage: "tag")
                    if let confidence = claim.confidence {
                        Label(
                            confidence.formatted(.percent.precision(.fractionLength(0))), systemImage: "gauge"
                        )
                    }
                    Spacer()
                    Button("检查 \(claim.evidenceIDs.count) 个证据链接", action: inspect)
                        .buttonStyle(.link)
                        .accessibilityLabel("检查主张关联的精确证据和来源")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(claim.limitations, id: \.self) { limitation in
                    Label(limitation, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(claim.claimID).font(.caption.monospaced())
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EvidenceCard: View {
    let evidence: EvidenceRecord

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(evidence.passage).textSelection(.enabled)
                HStack {
                    Label(evidence.locator, systemImage: "mappin")
                    Label(evidence.stance, systemImage: "arrow.left.arrow.right")
                    Label(
                        evidence.relevance.formatted(.percent.precision(.fractionLength(0))),
                        systemImage: "scope")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(evidence.evidenceID).font(.caption.monospaced())
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SourceCard: View {
    let source: SourceRecord
    let openURL: (URL) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(source.title).font(.headline).textSelection(.enabled)
                if !source.authors.isEmpty {
                    Text(source.authors.joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let excerpt = source.abstractOrExcerpt, !excerpt.isEmpty {
                    Text(excerpt).lineLimit(5).textSelection(.enabled)
                }
                if let canonicalID = source.canonicalID {
                    LabeledContent("Canonical ID") {
                        Text(canonicalID).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                HStack {
                    if let type = source.sourceType { Label(type, systemImage: "doc") }
                    if let date = source.publicationDate { Label(date, systemImage: "calendar") }
                    if let license = source.license { Label(license, systemImage: "checkmark.seal") }
                    if let status = source.status {
                        Label(status, systemImage: sourceStatusSymbol(status))
                            .foregroundStyle(sourceStatusColor(status))
                    }
                    Spacer()
                    if let value = source.landingURL, let url = URL(string: value) {
                        if (try? ExternalURLPolicy.validate(url)) != nil {
                            Button("确认后打开来源") { openURL(url) }
                                .buttonStyle(.link)
                                .accessibilityLabel("请求打开外部来源 \(url.host ?? "")")
                        } else {
                            Label("不安全链接已阻止", systemImage: "hand.raised")
                                .foregroundStyle(.red)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let retrieval = source.retrievals.last {
                    Text("由 \(retrieval.provider) 检索于 \(retrieval.retrievedAt)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(source.sourceID).font(.caption.monospaced())
        }
        .accessibilityElement(children: .combine)
    }

    private func sourceStatusSymbol(_ status: String) -> String {
        ["retracted", "withdrawn"].contains(status) ? "exclamationmark.octagon.fill" : "info.circle"
    }

    private func sourceStatusColor(_ status: String) -> Color {
        ["retracted", "withdrawn"].contains(status) ? .red : .secondary
    }
}

private struct ClaimEvidenceInspector: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let claim: ClaimRecord

    private var links: [ClaimEvidenceSourceLink] {
        model.claimEvidenceLinks.filter { $0.claim.claimID == claim.claimID }
    }

    private var missingEvidenceIDs: [String] {
        claim.evidenceIDs.filter { id in !links.contains(where: { $0.evidence.evidenceID == id }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("主张证据检查器").font(.title2.bold())
                    Text(claim.claimID).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox("主张") {
                        Text(claim.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    if !missingEvidenceIDs.isEmpty {
                        Label(
                            "缺少证据记录：\(missingEvidenceIDs.joined(separator: ", "))",
                            systemImage: "exclamationmark.octagon.fill"
                        )
                        .foregroundStyle(.red)
                        .accessibilityLabel("完整性错误，主张引用了缺失证据")
                    }
                    ForEach(links, id: \.evidence.evidenceID) { link in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(link.evidence.passage).textSelection(.enabled)
                                LabeledContent("定位") { Text(link.evidence.locator) }
                                LabeledContent("立场") { Text(link.evidence.stance) }
                                Divider()
                                LabeledContent("精确来源") { Text(link.source.title) }
                                Text(link.source.sourceID)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                if let canonicalID = link.source.canonicalID {
                                    LabeledContent("Canonical ID") {
                                        Text(canonicalID).font(.caption.monospaced())
                                    }
                                }
                                if let license = link.source.license {
                                    LabeledContent("License") { Text(license) }
                                }
                                if let status = link.source.status {
                                    LabeledContent("来源状态") { Text(status) }
                                }
                                if !link.source.retrievals.isEmpty {
                                    Divider()
                                    Text("检索记录").font(.caption.bold())
                                    ForEach(link.source.retrievals) { retrieval in
                                        Text("\(retrieval.provider) · \(retrieval.retrievedAt)")
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                    }
                                }
                                if let value = link.source.landingURL,
                                    let url = try? ExternalURLPolicy.validate(value)
                                {
                                    Button("确认后打开来源") { model.requestExternalOpen(url) }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            Text(link.evidence.evidenceID).font(.caption.monospaced())
                        }
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 720, minHeight: 620)
    }
}

private struct ResumeReviewView: View {
    @EnvironmentObject private var model: AppModel
    let context: ResumeReviewContext

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("重新审阅恢复运行", systemImage: "arrow.clockwise.circle")
                    .font(.title2.bold())
                Text("恢复前已重新验证。保存的计划、剩余步骤和权限必须再次确认。")
                    .foregroundStyle(.secondary)
                HStack {
                    StatusBadge(status: context.status)
                    Text(context.runDirectory.lastPathComponent).font(.caption.monospaced())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox("保存的计划") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(context.plan.steps) { step in
                                HStack {
                                    Image(
                                        systemName: context.completedStepIDs.contains(step.stepID)
                                            ? "checkmark.circle.fill" : "circle"
                                    )
                                    .foregroundStyle(
                                        context.completedStepIDs.contains(step.stepID) ? .green : .secondary
                                    )
                                    VStack(alignment: .leading) {
                                        Text(step.title)
                                        Text(step.stepID).font(.caption.monospaced()).foregroundStyle(
                                            .secondary)
                                    }
                                    Spacer()
                                    Text(
                                        context.completedStepIDs.contains(step.stepID)
                                            ? "已完成" : "待执行"
                                    )
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !context.limitations.isEmpty {
                        GroupBox("现有限制") {
                            VStack(alignment: .leading) {
                                ForEach(context.limitations, id: \.self) {
                                    Label($0, systemImage: "exclamationmark.triangle")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    GroupBox("恢复 Provider 身份") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(context.savedSourceProviders) { provider in
                                Text("\(provider.name) @ \(provider.version)")
                                    .font(.caption.monospaced())
                            }
                            Label(
                                model.resumeProviderPreflightMessage,
                                systemImage: model.resumeProviderPreflight?.valid == true
                                    ? "checkmark.shield.fill" : "xmark.shield.fill"
                            )
                            .foregroundStyle(
                                model.resumeProviderPreflight?.valid == true ? .green : .red
                            )
                            if model.isCheckingResumeProviders { ProgressView() }
                            Button("选择 fixture JSON 并本地预检…") { chooseResumeFixtures() }
                            ForEach(model.resumeFixtureFiles, id: \.self) { file in
                                Text(file.path)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Text("缺失的保存 Provider 必须由至少一份 fixture 恢复，且名称与 checkpoint 版本必须精确匹配。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("重新选择本地权限") {
                        VStack(alignment: .leading, spacing: 8) {
                            if context.exactLocalRoots.isEmpty {
                                Label("保存的运行未使用本地目录", systemImage: "checkmark.circle")
                            } else {
                                Text("必须重新选择且精确匹配：")
                                ForEach(context.exactLocalRoots, id: \.self) { root in
                                    Text(root.path).font(.caption.monospaced()).textSelection(.enabled)
                                }
                                Button("重新选择目录…") { chooseExactRoots() }
                                Label(
                                    model.resumeRootsMatch ? "目录精确匹配" : "尚未精确匹配",
                                    systemImage: model.resumeRootsMatch
                                        ? "checkmark.circle.fill" : "xmark.circle"
                                )
                                .foregroundStyle(model.resumeRootsMatch ? .green : .red)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !context.credentialRequirements.isEmpty {
                        GroupBox("重新授权凭据") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(
                                    context.credentialRequirements.sorted { $0.rawValue < $1.rawValue },
                                    id: \.self
                                ) { requirement in
                                    Label(
                                        "\(requirement.rawValue)：\(model.settings.hasCredential(requirement) ? "Keychain 已存在" : "缺失")",
                                        systemImage: model.settings.hasCredential(requirement)
                                            ? "key.fill" : "key.slash"
                                    )
                                }
                                Toggle(
                                    "仅本次使用当前 Keychain 凭据",
                                    isOn: $model.resumeCredentialAcknowledged
                                )
                                .toggleStyle(.checkbox)
                                .disabled(!model.resumeCredentialsPresent)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if context.requiresNetworkGrant {
                        GroupBox("重新授权网络") {
                            VStack(alignment: .leading, spacing: 8) {
                                if let modelConfig = model.resumeModelConfig {
                                    LabeledContent("模型目标") {
                                        Text("\(modelConfig.origin) · \(modelConfig.model)")
                                            .font(.caption.monospaced())
                                    }
                                    LabeledContent("配置指纹") {
                                        Text(String(modelConfig.sha256.prefix(16)) + "…")
                                            .font(.caption.monospaced())
                                    }
                                }
                                Toggle(
                                    "仅本次恢复允许保存计划中的网络能力",
                                    isOn: Binding(
                                        get: { model.resumeNetworkAcknowledged },
                                        set: { model.setResumeNetworkApproval($0) }
                                    )
                                )
                                .toggleStyle(.checkbox)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
            }
            Divider()
            HStack {
                Button("取消") { model.rejectResume() }.keyboardShortcut(.cancelAction)
                Spacer()
                Text("剩余 \(context.remainingStepIDs.count) 步")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("重新批准并恢复") { model.approveResume() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.resumeCanApprove)
            }
            .padding()
        }
        .frame(minWidth: 760, minHeight: 680)
        .interactiveDismissDisabled()
    }

    private func chooseExactRoots() {
        let panel = NSOpenPanel()
        panel.title = "重新选择保存运行使用的全部本地目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let selected = Set(panel.urls.map(\.standardizedFileURL.path))
        model.resumeSelectedRoots = context.exactLocalRoots.filter {
            selected.contains($0.standardizedFileURL.path)
        }
    }

    private func chooseResumeFixtures() {
        let panel = NSOpenPanel()
        panel.title = "选择恢复保存 Provider 所需的 fixture JSON"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK else { return }
        model.preflightResumeFixtures(panel.urls.map(\.standardizedFileURL))
    }
}
