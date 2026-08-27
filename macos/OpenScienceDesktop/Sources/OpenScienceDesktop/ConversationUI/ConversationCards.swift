import AppKit
import OpenScienceCore
import OpenScienceDesktopLogic
import SwiftUI

struct WorkbenchPlanStepViewData: Identifiable, Equatable {
    let id: String
    let title: String
    let purpose: String
    let dependencies: [String]
    let capability: String
    let completionCondition: String
    let recordedStatus: String
}

struct NetworkPermissionCard: View {
    @EnvironmentObject private var model: AppModel
    let message: ConversationMessage

    var body: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.title3)
                        .foregroundStyle(WorkbenchTheme.warning)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("网络访问需要你的批准")
                            .font(.system(size: 13, weight: .semibold))
                        Text(message.text)
                            .font(.system(size: 11))
                            .foregroundStyle(WorkbenchTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if model.isActivePlanMessage(message) || model.isDesignPreview {
                        Button("拒绝", role: .destructive) {
                            if model.isDesignPreview {
                                model.operationMessage = "设计预览不会执行网络请求。"
                            } else {
                                model.rejectPendingPlan()
                            }
                        }
                        .buttonStyle(.bordered)
                        Button(model.planNetworkAcknowledged ? "已批准" : "批准") {
                            if model.isDesignPreview {
                                model.operationMessage = "设计预览中的授权不会产生网络访问。"
                            } else {
                                model.setPlanNetworkApproval(!model.planNetworkAcknowledged)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(WorkbenchTheme.accent)
                    } else {
                        Label("已记录", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(WorkbenchTheme.secondary)
                    }
                }

                if model.isActivePlanMessage(message) || model.isDesignPreview,
                    !model.workbenchNetworkDestinations.isEmpty
                {
                    HStack(spacing: 6) {
                        ForEach(model.workbenchNetworkDestinations, id: \.self) { destination in
                            Text(destination)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(WorkbenchTheme.raised)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("网络访问审批")
    }
}

struct PlanApprovalCard: View {
    @EnvironmentObject private var model: AppModel
    let message: ConversationMessage

    var body: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("运行计划（\(steps.count) 步）")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if model.isActivePlanMessage(message) {
                        Text("等待批准")
                            .font(.caption)
                            .foregroundStyle(WorkbenchTheme.warning)
                    } else if model.isRunning && model.isCurrentPlanMessage(message) {
                        Text("运行中")
                            .font(.caption)
                            .foregroundStyle(WorkbenchTheme.accent)
                    } else {
                        Text("已保存")
                            .font(.caption)
                            .foregroundStyle(WorkbenchTheme.secondary)
                    }
                }

                VStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        planStep(step, index: index)
                        if index < steps.count - 1 {
                            Divider().padding(.leading, 25)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .background(WorkbenchTheme.raised.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: WorkbenchTheme.compactRadius, style: .continuous))

                if model.isActivePlanMessage(message) {
                    HStack {
                        Text("Provider 尚未调用。批准后才会开始研究。")
                            .font(.caption)
                            .foregroundStyle(WorkbenchTheme.secondary)
                        Spacer()
                        Button("拒绝", role: .destructive) { model.rejectPendingPlan() }
                            .buttonStyle(.bordered)
                        Button("批准并运行") { model.approvePlanAndRun() }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                model.pendingPlanContext?.requiresNetworkGrant == true
                                    && !model.planNetworkAcknowledged
                            )
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("研究运行计划")
    }

    private func planStep(_ step: WorkbenchPlanStepViewData, index: Int) -> some View {
        let state =
            model.isCurrentPlanMessage(message) || model.isDesignPreview
            ? model.workbenchStepState(step.id) : .pending
        return HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(stepColor(state).opacity(state == .pending ? 0.08 : 0.18))
                    .frame(width: 17, height: 17)
                Image(systemName: stepSymbol(state, index: index))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(stepColor(state))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .font(.system(size: 11, weight: .medium))
            }
            Spacer(minLength: 8)
            Text(stepStateText(state))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(stepColor(state))
        }
        .frame(minHeight: 28)
    }

    private func stepSymbol(_ state: DesktopStepState, index: Int) -> String {
        switch state {
        case .pending: return "\(index + 1).circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    private func stepColor(_ state: DesktopStepState) -> Color {
        switch state {
        case .pending: return WorkbenchTheme.tertiary
        case .running: return WorkbenchTheme.accent
        case .completed: return WorkbenchTheme.success
        case .failed: return WorkbenchTheme.danger
        case .cancelled: return .orange
        }
    }

    private func stepStateText(_ state: DesktopStepState) -> String {
        switch state {
        case .pending: return "等待中"
        case .running: return "运行中"
        case .completed: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    private var steps: [WorkbenchPlanStepViewData] {
        model.workbenchPlanSteps(for: message)
    }
}

struct RunProgressCard: View {
    @EnvironmentObject private var model: AppModel
    let message: ConversationMessage

    var body: some View {
        ToolActivityCard(
            runReference: message.runReference,
            recordedText: message.text,
            isLive: model.isActiveRunMessage(message)
        )
    }
}

struct ToolActivityCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true
    let runReference: ConversationRunReference?
    let recordedText: String
    let isLive: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 7) {
                        Label("工具活动", systemImage: "hammer")
                            .font(.system(size: 10, weight: .medium))
                        Spacer()
                        Text("\(sourceCount) 来源 · \(evidenceCount) 证据 · \(claimCount) 结论")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(WorkbenchTheme.tertiary)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(WorkbenchTheme.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if isLive && model.isRunning {
                    Button(role: .destructive) {
                        model.cancelActive()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.cancellationRequested)
                    .help("取消当前运行")
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 24)

            if isExpanded {
                Divider()
                VStack(spacing: 0) {
                    if !isLive {
                        Text(verbatim: recordedText)
                            .font(.system(size: 9))
                            .foregroundStyle(WorkbenchTheme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                    } else if activityRows.isEmpty {
                        HStack {
                            WorkbenchStatusDot(color: WorkbenchTheme.tertiary)
                            Text("等待可信事件记录")
                            Spacer()
                            Text("—")
                        }
                        .font(.caption2)
                        .foregroundStyle(WorkbenchTheme.tertiary)
                        .frame(height: 20)
                        .padding(.horizontal, 9)
                    } else {
                        ForEach(activityRows.suffix(5)) { row in
                            HStack(spacing: 7) {
                                Image(systemName: activitySymbol(row.state))
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(activityColor(row.state))
                                    .frame(width: 10)
                                Text(row.title)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if let detail = row.detail {
                                    Text(detail)
                                        .lineLimit(1)
                                        .foregroundStyle(WorkbenchTheme.tertiary)
                                }
                            }
                            .font(.system(size: 9))
                            .foregroundStyle(WorkbenchTheme.secondary)
                            .frame(height: 20)
                            .padding(.horizontal, 9)
                            if row.id != activityRows.last?.id { Divider().padding(.leading, 26) }
                        }
                    }
                }
            }
        }
        .background(WorkbenchTheme.raised.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: WorkbenchTheme.compactRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: WorkbenchTheme.compactRadius, style: .continuous)
                .stroke(WorkbenchTheme.separator, lineWidth: 1)
        }
    }

    private var sourceCount: Int { runReference?.sources ?? model.activeProjection.sources }
    private var evidenceCount: Int { runReference?.evidence ?? model.activeProjection.evidence }
    private var claimCount: Int { runReference?.claims ?? model.activeProjection.claims }
    private var activityRows: [DesktopActivityRow] {
        isLive ? model.activeProjection.activityRows : []
    }

    private func activitySymbol(_ state: DesktopStepState?) -> String {
        switch state {
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "stop.fill"
        case .pending, nil: return "circle"
        }
    }

    private func activityColor(_ state: DesktopStepState?) -> Color {
        switch state {
        case .running: return WorkbenchTheme.accent
        case .completed: return WorkbenchTheme.success
        case .failed: return WorkbenchTheme.danger
        case .cancelled: return .orange
        case .pending, nil: return WorkbenchTheme.secondary
        }
    }
}

struct ResearchResultCard: View {
    @EnvironmentObject private var model: AppModel
    let message: ConversationMessage

    var body: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("研究结果", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WorkbenchTheme.success)
                    Spacer()
                    if let reference = message.runReference {
                        Text(reference.runID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(WorkbenchTheme.tertiary)
                    }
                }

                Text(verbatim: message.text.replacingOccurrences(of: "**", with: ""))
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !citations.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(citations.prefix(3).enumerated()), id: \.element.id) {
                            index, citation in
                            Button {
                                model.selectWorkbenchEvidence(
                                    evidenceID: citation.evidenceID,
                                    sourceID: citation.sourceID,
                                    runID: citation.runID
                                )
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("[\(index + 1)]")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(WorkbenchTheme.accent)
                                    Text(citation.label)
                                        .font(.caption)
                                        .foregroundStyle(WorkbenchTheme.secondary)
                                        .lineLimit(2)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("在证据预览中打开精确来源")
                        }
                    }
                }

                HStack(spacing: 14) {
                    Label(
                        "\(message.runReference?.sources ?? model.runDetail?.sources.count ?? 0) 来源",
                        systemImage: "doc.text")
                    Label(
                        "\(message.runReference?.evidence ?? model.runDetail?.evidence.count ?? 0) 证据",
                        systemImage: "quote.bubble")
                    Spacer()
                    WorkbenchIconButton(title: "复制", symbol: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    }
                    WorkbenchIconButton(
                        title: model.isLoadedResultMessage(message) ? "查看报告" : "加载此运行",
                        symbol: model.isLoadedResultMessage(message) ? "sidebar.right" : "arrow.down.circle"
                    ) {
                        if model.isLoadedResultMessage(message) {
                            model.showInspector(.artifacts)
                        } else {
                            model.loadRunReference(message.runReference)
                        }
                    }
                    Menu {
                        Button("验证运行", systemImage: "checkmark.shield") {
                            model.validateSelected()
                        }
                        Button("离线回放", systemImage: "play.circle") {
                            model.replaySelected()
                        }
                        Button("导出研究包…", systemImage: "square.and.arrow.up") {
                            model.presentExportPanel()
                        }
                        .disabled(!model.workbenchCanOfferExport)
                        if let status = model.selectedRun?.status,
                            [.awaitingApproval, .partial, .failed].contains(status)
                        {
                            Button("重新审阅并恢复…", systemImage: "arrow.clockwise.circle") {
                                model.selectedSection = .history
                                model.prepareResumeSelected()
                            }
                        }
                        Divider()
                        Button("打开运行历史", systemImage: "clock.arrow.circlepath") {
                            model.selectedSection = .history
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(!model.isLoadedResultMessage(message))
                    .help("运行操作")
                }
                .font(.caption)
                .foregroundStyle(WorkbenchTheme.secondary)
            }
        }
    }

    private var citations: [WorkbenchCitationViewData] {
        model.workbenchCitations(for: message)
    }
}
