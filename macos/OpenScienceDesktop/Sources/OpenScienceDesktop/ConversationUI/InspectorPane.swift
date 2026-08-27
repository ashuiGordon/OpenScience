import OpenScienceCore
import OpenScienceDesktopLogic
import SwiftUI

enum WorkbenchInspectorSection: String, CaseIterable, Identifiable {
    case context
    case plan
    case evidence
    case artifacts

    var id: Self { self }

    var title: String {
        switch self {
        case .context: return "上下文"
        case .plan: return "计划"
        case .evidence: return "证据"
        case .artifacts: return "产物"
        }
    }
}

struct WorkbenchCitationViewData: Identifiable, Equatable {
    var id: String { "\(claimID):\(evidenceID):\(sourceID)" }
    let claimID: String
    let evidenceID: String
    let sourceID: String
    let runID: String
    let label: String
}

struct WorkbenchEvidenceViewData: Identifiable, Equatable {
    let id: String
    let sourceID: String
    let title: String
    let citation: String
    let passage: String
    let locator: String
    let url: URL?
    let stance: String
    let relevance: String
    let claimKind: String
    let confidence: String
    let limitations: [String]
    let license: String
    let sourceStatus: String
    let retrievalProvenance: [String]
    let createdByStep: String
    let contentHash: String
}

struct WorkbenchArtifactViewData: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
}

struct InspectorPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var conversations: ConversationStore
    @State private var isEvidenceDetailExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            inspectorTabs
            Divider()
            Group {
                switch model.inspectorSection {
                case .context: contextPane
                case .plan: planPane
                case .evidence: evidencePane
                case .artifacts: artifactsPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: model.isDesignPreview ? WorkbenchTheme.inspectorWidth : 460,
            idealWidth: WorkbenchTheme.inspectorWidth,
            maxWidth: model.isDesignPreview ? WorkbenchTheme.inspectorWidth : 508
        )
        .background(WorkbenchTheme.canvas)
        .onChange(of: model.workbenchEvidenceRows) {
            if model.workbenchSelectedEvidenceID == nil
                || !model.workbenchEvidenceRows.contains(where: {
                    $0.id == model.workbenchSelectedEvidenceID
                })
            {
                model.workbenchSelectedEvidenceID = model.workbenchEvidenceRows.first?.id
            }
        }
        .onAppear {
            model.workbenchSelectedEvidenceID =
                conversations.inspectorSelection?.artifactID
                ?? model.workbenchEvidenceRows.first?.id
        }
    }

    private var inspectorTabs: some View {
        HStack(spacing: 0) {
            ForEach(WorkbenchInspectorSection.allCases) { section in
                Button {
                    model.showInspector(section)
                } label: {
                    VStack(spacing: 7) {
                        HStack(spacing: 5) {
                            Text(section.title)
                            if section == .evidence, !model.workbenchEvidenceRows.isEmpty {
                                Text("\(model.workbenchEvidenceRows.count)")
                                    .font(.caption2.monospacedDigit())
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(WorkbenchTheme.raised)
                                    .clipShape(Capsule())
                            }
                        }
                        .font(
                            .system(
                                size: 11, weight: model.inspectorSection == section ? .semibold : .regular))
                        Rectangle()
                            .fill(model.inspectorSection == section ? WorkbenchTheme.accent : Color.clear)
                            .frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    model.inspectorSection == section ? WorkbenchTheme.primary : WorkbenchTheme.secondary
                )
                .frame(maxWidth: .infinity)
            }
            Button {
                model.toggleInspectorPresentation()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 30, height: 28)
                    .background(WorkbenchTheme.panel)
                    .clipShape(
                        RoundedRectangle(cornerRadius: WorkbenchTheme.compactRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("收起预览")
            .accessibilityLabel("收起预览")
            .padding(.horizontal, 7)
        }
        .frame(height: 47)
    }

    private var contextPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                inspectorSectionTitle("当前会话", symbol: "bubble.left.and.text.bubble.right")
                WorkbenchCard {
                    VStack(alignment: .leading, spacing: 9) {
                        inspectorValue("项目", conversations.selectedProject?.title ?? "OpenScience")
                        inspectorValue("会话", conversations.selectedSession?.title ?? "未选择")
                        inspectorValue("状态", model.workbenchSessionStatusText)
                        inspectorValue("消息", "\(conversations.selectedSession?.messages.count ?? 0)")
                    }
                }

                inspectorSectionTitle("研究边界", symbol: "scope")
                WorkbenchCard {
                    VStack(alignment: .leading, spacing: 9) {
                        inspectorValue("问题", model.workbenchQuestion)
                        inspectorValue("来源", model.workbenchSourceNames)
                        inspectorValue("模型", model.workbenchModelName)
                        inspectorValue("记录上限", "\(model.draft.maxRecords)")
                        inspectorValue("网络请求", "\(model.draft.maxNetworkRequests)")
                        inspectorValue("超时", "\(model.draft.timeoutSeconds) 秒")
                    }
                }

                inspectorSectionTitle("运行时", symbol: "terminal")
                WorkbenchCard {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 7) {
                            WorkbenchStatusDot(
                                color: model.engineAvailable ? WorkbenchTheme.success : WorkbenchTheme.danger)
                            Text(model.engineStatusText)
                                .font(.caption)
                                .foregroundStyle(WorkbenchTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let runID = model.activeRunDirectory?.lastPathComponent ?? model.selectedRun?.runID
                        {
                            inspectorValue("Run ID", runID, monospaced: true)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var planPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    inspectorSectionTitle("运行计划", symbol: "list.bullet.clipboard")
                    Spacer()
                    Text("\(model.workbenchPlanSteps.count) 步")
                        .font(.caption)
                        .foregroundStyle(WorkbenchTheme.secondary)
                }

                WorkbenchCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.workbenchPlanSteps.enumerated()), id: \.element.id) {
                            index, step in
                            HStack(alignment: .top, spacing: 9) {
                                Image(
                                    systemName: model.workbenchStepState(step.id) == .completed
                                        ? "checkmark.circle.fill" : "\(index + 1).circle"
                                )
                                .foregroundStyle(
                                    model.workbenchStepState(step.id) == .completed
                                        ? WorkbenchTheme.success : WorkbenchTheme.secondary
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(step.title)
                                        .font(.system(size: 11, weight: .medium))
                                    Text(
                                        step.purpose.isEmpty
                                            ? "unknown — purpose not recorded" : step.purpose
                                    )
                                    .font(.system(size: 9))
                                    .foregroundStyle(WorkbenchTheme.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    inspectorValue(
                                        "依赖",
                                        step.dependencies.isEmpty
                                            ? "none recorded" : step.dependencies.joined(separator: ", "),
                                        monospaced: true
                                    )
                                    inspectorValue("能力", step.capability, monospaced: true)
                                    inspectorValue("完成条件", step.completionCondition)
                                    inspectorValue("记录状态", step.recordedStatus, monospaced: true)
                                }
                                Spacer(minLength: 6)
                            }
                            .padding(11)
                            if index < model.workbenchPlanSteps.count - 1 { Divider().padding(.leading, 34) }
                        }
                    }
                }

                inspectorSectionTitle("能力审阅", symbol: "checkmark.shield")
                WorkbenchCard {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(model.workbenchPlanCapabilities, id: \.self) { capability in
                            Label(capability, systemImage: "shield.lefthalf.filled")
                                .font(.caption)
                                .foregroundStyle(WorkbenchTheme.secondary)
                        }
                        if model.workbenchPlanCapabilities.isEmpty {
                            Text("提交研究问题后，会在这里显示 Provider 与能力边界。")
                                .font(.caption)
                                .foregroundStyle(WorkbenchTheme.tertiary)
                        }
                    }
                }

                inspectorSectionTitle("执行限制", symbol: "gauge.with.dots.needle.67percent")
                WorkbenchCard {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(model.workbenchPlanLimits.enumerated()), id: \.offset) {
                            _, limit in
                            inspectorValue(limit.label, limit.value, monospaced: true)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var evidencePane: some View {
        VStack(spacing: 0) {
            if model.evidenceJoinError != nil {
                Label(
                    "证据关联未通过完整性检查；引用跳转已禁用。",
                    systemImage: "exclamationmark.shield.fill"
                )
                .font(.caption)
                .foregroundStyle(WorkbenchTheme.danger)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            if model.workbenchEvidenceRows.isEmpty {
                ContentUnavailableView(
                    "尚无证据",
                    systemImage: "quote.bubble",
                    description: Text("研究提取出的原文段落与精确定位会显示在这里。")
                )
            } else {
                HStack {
                    Text("证据 \(selectedEvidencePosition) / \(model.workbenchEvidenceRows.count)")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button {
                        model.navigateWorkbenchEvidence(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canNavigateWorkbenchEvidence(by: -1))
                    .help("上一条精确证据")
                    Button {
                        model.navigateWorkbenchEvidence(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canNavigateWorkbenchEvidence(by: 1))
                    .help("下一条精确证据")
                    Menu {
                        ForEach(model.workbenchEvidenceRows) { evidence in
                            Button(evidence.title) {
                                if let index = model.workbenchEvidenceRows.firstIndex(where: {
                                    $0.id == evidence.id
                                }) {
                                    model.selectWorkbenchEvidence(at: index)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                }
                .padding(.horizontal, 13)
                .frame(height: 40)
                Divider()

                if let evidence = selectedEvidence {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(evidence.title)
                                .font(.system(size: 17, weight: .semibold, design: .serif))
                                .textSelection(.enabled)
                            Text(evidence.citation)
                                .font(.caption)
                                .foregroundStyle(WorkbenchTheme.secondary)
                                .textSelection(.enabled)
                            if let url = evidence.url {
                                Button(url.absoluteString) { model.requestExternalOpen(url) }
                                    .buttonStyle(.link)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            Divider()
                            inspectorValue("定位", evidence.locator)
                            Text("精确引文")
                                .font(.system(size: 11, weight: .semibold))
                            Text(evidence.passage)
                                .font(.system(size: 11))
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(WorkbenchTheme.panel)
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: WorkbenchTheme.compactRadius, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(
                                        cornerRadius: WorkbenchTheme.compactRadius, style: .continuous
                                    )
                                    .stroke(WorkbenchTheme.separator, lineWidth: 1)
                                }

                            DisclosureGroup(
                                "证据详情与检索溯源",
                                isExpanded: $isEvidenceDetailExpanded
                            ) {
                                WorkbenchCard {
                                    VStack(alignment: .leading, spacing: 8) {
                                        inspectorValue("立场", evidence.stance)
                                        inspectorValue("相关性", evidence.relevance, monospaced: true)
                                        inspectorValue(
                                            "Claim 类型", evidence.claimKind, monospaced: true)
                                        inspectorValue("置信度", evidence.confidence, monospaced: true)
                                        inspectorValue("许可", evidence.license)
                                        inspectorValue("来源状态", evidence.sourceStatus)
                                        inspectorValue(
                                            "生成步骤", evidence.createdByStep, monospaced: true)
                                        inspectorValue("内容哈希", evidence.contentHash, monospaced: true)

                                        Divider()
                                        Text("限制")
                                            .font(.system(size: 11, weight: .semibold))
                                        ForEach(evidence.limitations, id: \.self) { limitation in
                                            Label(
                                                limitation,
                                                systemImage: "exclamationmark.triangle"
                                            )
                                            .font(.caption)
                                            .foregroundStyle(WorkbenchTheme.secondary)
                                        }

                                        Divider()
                                        Text("检索溯源")
                                            .font(.system(size: 11, weight: .semibold))
                                        ForEach(
                                            evidence.retrievalProvenance,
                                            id: \.self
                                        ) { provenance in
                                            Text(verbatim: provenance)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(WorkbenchTheme.secondary)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                            .font(.system(size: 11, weight: .semibold))

                            Divider()
                            Text("证据 \(evidence.id)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(WorkbenchTheme.tertiary)
                            Text("来源 \(evidence.sourceID)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(WorkbenchTheme.tertiary)

                            Divider()
                            inspectorSectionTitle("运行溯源", symbol: "clock.arrow.circlepath")
                            WorkbenchCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(
                                        Array(model.workbenchProvenanceRows.enumerated()), id: \.offset
                                    ) { _, row in
                                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                                            Text(row.label)
                                                .frame(width: 54, alignment: .leading)
                                                .foregroundStyle(WorkbenchTheme.tertiary)
                                            Text(verbatim: row.value)
                                                .textSelection(.enabled)
                                                .foregroundStyle(WorkbenchTheme.secondary)
                                            Spacer(minLength: 0)
                                        }
                                        .font(.system(size: 10))
                                    }
                                }
                            }

                            if !model.workbenchArtifacts.isEmpty {
                                inspectorSectionTitle("相关产物", symbol: "shippingbox")
                                ForEach(model.workbenchArtifacts.prefix(2)) { artifact in
                                    WorkbenchCard {
                                        HStack(spacing: 9) {
                                            Image(systemName: artifact.symbol)
                                                .foregroundStyle(WorkbenchTheme.accent)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(artifact.title)
                                                    .font(.system(size: 10, weight: .semibold))
                                                Text(artifact.subtitle)
                                                    .font(.caption2)
                                                    .foregroundStyle(WorkbenchTheme.tertiary)
                                            }
                                            Spacer()
                                            artifactMenu
                                        }
                                    }
                                }
                            }
                        }
                        .padding(13)
                    }
                }
            }
        }
    }

    private var artifactsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                inspectorSectionTitle("相关产物", symbol: "shippingbox")
                ForEach(model.workbenchArtifacts) { artifact in
                    WorkbenchCard {
                        HStack(spacing: 10) {
                            Image(systemName: artifact.symbol)
                                .font(.title3)
                                .foregroundStyle(WorkbenchTheme.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(artifact.title)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(artifact.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(WorkbenchTheme.tertiary)
                            }
                            Spacer()
                            artifactMenu
                        }
                    }
                }

                if model.workbenchArtifacts.isEmpty {
                    ContentUnavailableView(
                        "尚无研究产物",
                        systemImage: "doc.richtext",
                        description: Text("报告、manifest 与导出包会显示在这里。")
                    )
                    .frame(maxWidth: .infinity)
                }

                if !model.workbenchReportMarkdown.isEmpty {
                    inspectorSectionTitle("报告预览", symbol: "doc.text.magnifyingglass")
                    WorkbenchCard {
                        Text(verbatim: model.workbenchReportMarkdown)
                            .font(.system(size: 10))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(12)
        }
    }

    private var selectedEvidence: WorkbenchEvidenceViewData? {
        model.workbenchEvidenceRows.first { $0.id == model.workbenchSelectedEvidenceID }
            ?? model.workbenchEvidenceRows.first
    }

    private var selectedEvidencePosition: Int {
        guard let selectedID = model.workbenchSelectedEvidenceID,
            let index = model.workbenchEvidenceRows.firstIndex(where: { $0.id == selectedID })
        else { return model.workbenchEvidenceRows.isEmpty ? 0 : 1 }
        return index + 1
    }

    private func inspectorSectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(WorkbenchTheme.secondary)
    }

    private func inspectorValue(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(WorkbenchTheme.tertiary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(WorkbenchTheme.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var artifactMenu: some View {
        Menu {
            Button("在 Finder 中显示 Run", systemImage: "folder") {
                model.revealActiveRun()
            }
            .disabled(model.activeRunDirectory == nil && model.selectedRun == nil)
            Button("导出经过验证的研究包…", systemImage: "square.and.arrow.up") {
                model.presentExportPanel()
            }
            .disabled(model.selectedRun == nil)
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(WorkbenchTheme.tertiary)
        }
        .menuStyle(.borderlessButton)
        .help("产物操作")
    }
}
