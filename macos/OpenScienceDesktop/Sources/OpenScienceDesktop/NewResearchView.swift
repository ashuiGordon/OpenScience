import AppKit
import OpenScienceCore
import OpenScienceDesktopLogic
import SwiftUI

struct NewResearchView: View {
    @EnvironmentObject private var model: AppModel

    private var constraintsText: Binding<String> {
        Binding(
            get: { model.draft.constraints.joined(separator: "\n") },
            set: { model.draft.constraints = lines($0) }
        )
    }

    private var assumptionsText: Binding<String> {
        Binding(
            get: { model.draft.assumptions.joined(separator: "\n") },
            set: { model.draft.assumptions = lines($0) }
        )
    }

    var body: some View {
        Form {
            Section("研究问题") {
                TextEditor(text: $model.draft.question)
                    .font(.body)
                    .frame(minHeight: 95)
                    .accessibilityLabel("研究问题")
                TextField("范围（可选）", text: $model.draft.scope, axis: .vertical)
                    .accessibilityLabel("研究范围")
            }

            Section("来源") {
                providerToggle("OpenAlex", source: "openalex")
                providerToggle("Crossref", source: "crossref")
                Label("网络能力将在计划审阅中单独确认，授权仅对一次执行有效。", systemImage: "network.badge.shield.half.filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("学术 API 联系邮箱（可选）", text: $model.draft.email)
                    .textContentType(.emailAddress)
                    .accessibilityLabel("API 联系邮箱")

                LabeledContent("本地目录") {
                    Button("添加目录…") { chooseLocalDirectory() }
                        .accessibilityLabel("添加允许读取的本地目录")
                }
                ForEach(model.draft.localRoots, id: \.self) { root in
                    pathRow(root) { model.draft.localRoots.removeAll { $0 == root } }
                }

                LabeledContent("Fixture") {
                    Button("添加 JSON…") { chooseFixture() }
                        .accessibilityLabel("添加确定性 fixture JSON")
                }
                ForEach(model.draft.fixtureFiles, id: \.self) { file in
                    pathRow(file) { model.draft.fixtureFiles.removeAll { $0 == file } }
                }
            }

            Section("合成") {
                Picker("合成器", selection: $model.draft.useNetworkModel) {
                    Text("本地 Extractive").tag(false)
                    Text("OpenAI-compatible 网络模型").tag(true)
                }
                .pickerStyle(.radioGroup)
                .accessibilityLabel("研究合成器")
                if model.draft.useNetworkModel && !model.draft.localRoots.isEmpty {
                    Label(
                        "隐私保护已阻止此组合：本地证据不会发送给网络模型。",
                        systemImage: "hand.raised.fill"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityLabel("隐私阻止：本地证据不能发送给网络模型")
                }
            }

            Section("边界") {
                Stepper("最多记录：\(model.draft.maxRecords)", value: $model.draft.maxRecords, in: 1...10_000)
                Stepper(
                    "最多网络请求：\(model.draft.maxNetworkRequests)",
                    value: $model.draft.maxNetworkRequests,
                    in: 0...10_000
                )
                Stepper(
                    "超时：\(model.draft.timeoutSeconds) 秒",
                    value: $model.draft.timeoutSeconds,
                    in: 1...86_400,
                    step: 30
                )
                TextField("约束（每行一项）", text: constraintsText, axis: .vertical)
                    .lineLimit(2...6)
                TextField("假设（每行一项）", text: assumptionsText, axis: .vertical)
                    .lineLimit(2...6)
            }

            Section {
                HStack {
                    Label(
                        model.engineStatusText,
                        systemImage: model.engineAvailable ? "checkmark.circle" : "xmark.octagon"
                    )
                    .font(.caption)
                    .foregroundStyle(model.engineAvailable ? Color.secondary : Color.red)
                    Spacer()
                    Button {
                        model.startRun()
                    } label: {
                        if model.isPreparingPlan {
                            ProgressView().controlSize(.small)
                            Text("正在生成计划…")
                        } else {
                            Label("生成并审阅计划", systemImage: "list.bullet.clipboard")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(
                        model.isRunning || model.isPreparingPlan || privacyBlocked
                            || !model.engineAvailable
                    )
                    .accessibilityLabel("生成并审阅研究计划，快捷键 Command Return")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("新研究")
        .navigationSplitViewColumnWidth(min: 350, ideal: 430)
        .sheet(isPresented: $model.isShowingPlanReview) {
            if let context = model.pendingPlanContext {
                PlanReviewView(context: context)
                    .environmentObject(model)
            }
        }
    }

    private var privacyBlocked: Bool {
        model.draft.useNetworkModel && !model.draft.localRoots.isEmpty
    }

    private func providerToggle(_ title: String, source: String) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { model.draft.sourceNames.contains(source) },
                set: { enabled in
                    if enabled {
                        if !model.draft.sourceNames.contains(source) {
                            model.draft.sourceNames.append(source)
                        }
                    } else {
                        model.draft.sourceNames.removeAll { $0 == source }
                    }
                }
            )
        )
        .accessibilityLabel("使用 \(title) 来源")
    }

    private func pathRow(_ url: URL, remove: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "folder")
            Text(url.path)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(role: .destructive, action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除 \(url.lastPathComponent)")
        }
    }

    private func chooseLocalDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择允许 OpenScience 读取的目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !model.draft.localRoots.contains(url.standardizedFileURL) {
                model.draft.localRoots.append(url.standardizedFileURL)
            }
        }
    }

    private func chooseFixture() {
        let panel = NSOpenPanel()
        panel.title = "选择 fixture JSON"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK {
            for url in panel.urls where !model.draft.fixtureFiles.contains(url.standardizedFileURL) {
                model.draft.fixtureFiles.append(url.standardizedFileURL)
            }
        }
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct PlanReviewView: View {
    @EnvironmentObject private var model: AppModel
    let context: PlanReviewContext

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("审阅研究计划", systemImage: "checklist")
                    .font(.title2.bold())
                Text("Provider 尚未被调用。请确认每一步的目的、能力与完成条件。")
                    .foregroundStyle(.secondary)
                Text(context.plan.planID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            Divider()
            ScrollView {
                LazyVStack(spacing: 12) {
                    GroupBox("执行摘要") {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("研究问题") { Text(context.question).textSelection(.enabled) }
                            LabeledContent("合成器") {
                                riskLabel(context.synthesizer)
                            }
                            if let modelConfig = context.modelConfig {
                                LabeledContent("模型目标") {
                                    Text("\(modelConfig.origin) · \(modelConfig.model)")
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                }
                                LabeledContent("配置指纹") {
                                    Text(String(modelConfig.sha256.prefix(16)) + "…")
                                        .font(.caption.monospaced())
                                }
                            }
                            LabeledContent("限制") {
                                Text(
                                    "最多 \(context.maxRecords) 条记录 · \(context.maxNetworkRequests) 次网络请求 · \(context.timeoutSeconds) 秒"
                                )
                            }
                            if context.localRoots.isEmpty {
                                LabeledContent("本地目录") { Text("无") }
                            } else {
                                ForEach(context.localRoots, id: \.self) { root in
                                    LabeledContent("本地目录") {
                                        Text(root.path).font(.caption.monospaced()).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("来源与风险") {
                        VStack(spacing: 8) {
                            ForEach(context.sources) { source in
                                LabeledContent(source.name) { riskLabel(source) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if context.requiresNetworkGrant {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("本计划包含网络能力", systemImage: "network.badge.shield.half.filled")
                                    .font(.headline)
                                    .foregroundStyle(.orange)
                                ForEach(context.networkCapabilities) { capability in
                                    Text("• \(capability.networkSummary ?? capability.name)")
                                }
                                Text("研究问题及上述有限输入可能离开本机。此授权不会保存，也不会成为默认值。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Toggle(
                                    "仅允许本次计划使用上述网络能力",
                                    isOn: Binding(
                                        get: { model.planNetworkAcknowledged },
                                        set: { model.setPlanNetworkApproval($0) }
                                    )
                                )
                                .toggleStyle(.checkbox)
                                .accessibilityLabel("仅本次允许计划列出的网络能力")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    ForEach(Array(context.plan.steps.enumerated()), id: \.element.id) { index, step in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 9) {
                                Text(step.purpose).textSelection(.enabled)
                                LabeledContent("能力") {
                                    Text(step.capability).font(.caption.monospaced())
                                }
                                LabeledContent("依赖") {
                                    Text(
                                        step.dependencies.isEmpty
                                            ? "无" : step.dependencies.joined(separator: ", ")
                                    )
                                    .font(.caption.monospaced())
                                }
                                LabeledContent("完成条件") {
                                    Text(step.completionCondition)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            HStack {
                                Text("\(index + 1). \(step.title)")
                                Spacer()
                                Text(step.status).font(.caption.monospaced())
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "第 \(index + 1) 步，\(step.title)。目的：\(step.purpose)。完成条件：\(step.completionCondition)"
                        )
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Button("不批准") { model.rejectPendingPlan() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("拒绝计划，不调用 Provider")
                Spacer()
                Text("批准后将按此计划执行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("批准并开始研究") { model.approvePlanAndRun() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(context.requiresNetworkGrant && !model.planNetworkAcknowledged)
                    .accessibilityLabel("明确批准计划并开始研究")
            }
            .padding(18)
        }
        .frame(minWidth: 720, minHeight: 620)
        .interactiveDismissDisabled()
    }

    private func riskLabel(_ provider: ProviderReview) -> some View {
        HStack(spacing: 6) {
            Text(provider.name).font(.caption.monospaced())
            Text(provider.risk.replacingOccurrences(of: "_", with: " "))
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    provider.usesNetwork ? Color.orange.opacity(0.16) : Color.secondary.opacity(0.12),
                    in: Capsule()
                )
                .foregroundStyle(provider.usesNetwork ? .orange : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider.name)，风险 \(provider.risk)")
    }
}
