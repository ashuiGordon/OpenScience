import AppKit
import OpenScienceDesktopLogic
import SwiftUI

struct ConversationTimeline: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var conversations: ConversationStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var composerText = ""
    @State private var isShowingResearchSettings = false
    @State private var isTimelineAtBottom = true
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var findText = ""
    @State private var isShowingFindBar = false
    @FocusState private var isFindFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            conversationHeader
            if isShowingFindBar {
                Divider()
                currentContentFindBar
            }
            Divider()

            if let session = conversations.selectedSession {
                messages(session)
            } else {
                emptyConversation
            }

            Divider()
            ComposerView(
                text: $composerText,
                isShowingResearchSettings: $isShowingResearchSettings,
                send: submitPrompt
            )
        }
        .frame(minWidth: WorkbenchTheme.contentMinimumWidth, maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkbenchTheme.canvas)
        .onAppear {
            if model.isDesignPreview, composerText.isEmpty {
                composerText = "Compare this result with ESM-2 and explain the remaining gap."
            } else {
                composerText = model.restoreConversationDraftForSelection()
            }
        }
        .onChange(of: composerText) {
            scheduleDraftSave()
        }
        .onChange(of: conversations.selectedSessionID) { oldSessionID, _ in
            draftSaveTask?.cancel()
            if let oldSessionID {
                model.saveConversationDraft(text: composerText, sessionID: oldSessionID)
            }
            composerText = model.restoreConversationDraftForSelection()
        }
        .onChange(of: model.conversationContentFindFocusToken) {
            isShowingFindBar = true
            isFindFocused = true
        }
        .onChange(of: model.safeEscapeToken) {
            if isShowingFindBar {
                isShowingFindBar = false
                findText = ""
                isFindFocused = false
            }
        }
        .onDisappear {
            draftSaveTask?.cancel()
            if !model.isDesignPreview {
                model.saveConversationDraft(text: composerText)
            }
        }
    }

    private var conversationHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversations.selectedSession?.title ?? "新研究")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(
                        systemName: model.conversationPersistenceIssue == nil
                            ? "checkmark.circle" : "exclamationmark.triangle")
                    Text(model.conversationPersistenceIssue == nil ? "已保存 · 本地优先" : "会话存储需要注意")
                }
                .font(.system(size: 9))
                .foregroundStyle(
                    model.conversationPersistenceIssue == nil
                        ? WorkbenchTheme.tertiary : WorkbenchTheme.warning)
            }
            Spacer()
            WorkbenchIconButton(title: "收藏会话", symbol: "star") {}
            WorkbenchIconButton(title: "导出研究包", symbol: "square.and.arrow.up") {
                model.presentExportPanel()
            }
            Menu {
                Button("重命名…", systemImage: "pencil") { model.renameSelectedConversation() }
                Button("在 Finder 中显示 Run", systemImage: "folder") { model.revealActiveRun() }
                    .disabled(model.activeRunDirectory == nil && model.selectedRun == nil)
                Divider()
                Button("归档会话", systemImage: "archivebox") { model.archiveSelectedConversation() }
                    .disabled(conversations.selectedSession == nil)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .help("会话操作")
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(WorkbenchTheme.canvas)
    }

    private var currentContentFindBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(WorkbenchTheme.secondary)
            TextField("查找当前会话、报告与证据", text: $findText)
                .textFieldStyle(.plain)
                .focused($isFindFocused)
                .accessibilityLabel("查找当前可见研究内容")
            if !findText.isEmpty {
                Text("\(model.workbenchFindMatchCount(findText)) 个匹配")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(WorkbenchTheme.tertiary)
            }
            Button {
                isShowingFindBar = false
                findText = ""
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("关闭查找；不会取消计划或运行")
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(WorkbenchTheme.panel)
    }

    private func messages(_ session: ConversationSession) -> some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(session.messages) { message in
                            ConversationMessageView(message: message)
                                .id(message.id)
                                .onTapGesture {
                                    model.selectConversationMessage(message)
                                }
                        }
                        if model.isPreparingPlan && model.isSelectedActiveConversation {
                            assistantThinking
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("timeline-bottom")
                            .onAppear { isTimelineAtBottom = true }
                            .onDisappear { isTimelineAtBottom = false }
                    }
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.visible)
                .onChange(of: session.messages.count) {
                    if isTimelineAtBottom {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                            proxy.scrollTo("timeline-bottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: model.activeProjection.activityRows.count) {
                    if isTimelineAtBottom, model.isRunning {
                        proxy.scrollTo("timeline-bottom", anchor: .bottom)
                    }
                }

                if !isTimelineAtBottom {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                            proxy.scrollTo("timeline-bottom", anchor: .bottom)
                        }
                    } label: {
                        Label("跳到最新", systemImage: "arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(12)
                    .accessibilityHint("不改变当前会话内容，只移动阅读位置")
                }
            }
        }
    }

    private var assistantThinking: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenScience Agent")
                    .font(.system(size: 11, weight: .semibold))
                Text("正在生成可审阅的研究计划…")
                    .font(.system(size: 11))
                    .foregroundStyle(WorkbenchTheme.secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("OpenScience Agent 正在生成研究计划")
    }

    private var emptyConversation: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "atom")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(WorkbenchTheme.accent)
            VStack(spacing: 6) {
                Text("和 OpenScience Agent 一起研究")
                    .font(.title2.weight(.semibold))
                Text("描述研究问题。计划、权限、工具执行与可追溯证据都会出现在这条对话中。")
                    .font(.callout)
                    .foregroundStyle(WorkbenchTheme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 470)
            }
            HStack(spacing: 8) {
                suggestion("复现一项公开基准")
                suggestion("综述某个研究方向")
                suggestion("核验一条科学结论")
            }
            Spacer()
        }
        .padding(32)
    }

    private func suggestion(_ text: String) -> some View {
        Button(text) { composerText = text }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private func submitPrompt() {
        let prompt = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        if model.submitConversationPrompt(prompt) {
            composerText = ""
        }
    }

    private func scheduleDraftSave() {
        guard !model.isDesignPreview else { return }
        draftSaveTask?.cancel()
        let text = composerText
        let sessionID = conversations.selectedSessionID
        draftSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let sessionID else { return }
            model.saveConversationDraft(text: text, sessionID: sessionID)
        }
    }
}

private struct ConversationMessageView: View {
    @EnvironmentObject private var model: AppModel
    let message: ConversationMessage

    var body: some View {
        switch message.kind {
        case .text:
            textMessage
        case .permission:
            NetworkPermissionCard(message: message)
        case .plan:
            PlanApprovalCard(message: message)
        case .runProgress:
            RunProgressCard(message: message)
        case .result:
            ResearchResultCard(message: message)
        case .error:
            WorkbenchCard {
                HStack(alignment: .top, spacing: 10) {
                    Label(message.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(WorkbenchTheme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if message.runReference != nil {
                        Button("恢复选项…") { model.selectedSection = .history }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var textMessage: some View {
        if message.role == .user {
            VStack(alignment: .leading, spacing: 7) {
                messageHeader(title: "你", symbol: "person.crop.circle", alignment: .leading)
                Text(verbatim: message.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(WorkbenchTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: WorkbenchTheme.cardRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: WorkbenchTheme.cardRadius, style: .continuous)
                            .stroke(WorkbenchTheme.separator, lineWidth: 1)
                    }
                    .frame(maxWidth: 650, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            assistantContainer {
                Text(verbatim: message.text)
                    .font(.system(size: 12))
                    .foregroundStyle(
                        message.role == .system ? WorkbenchTheme.secondary : WorkbenchTheme.primary
                    )
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func assistantContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            messageHeader(
                title: message.role == .system ? "OpenScience" : "OpenScience Agent",
                symbol: message.role == .system ? "info.circle" : "atom",
                alignment: .leading
            )
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func messageHeader(title: String, symbol: String, alignment: Alignment) -> some View {
        HStack(spacing: 7) {
            if alignment == .trailing { Spacer() }
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(
                    title == "OpenScience Agent" ? WorkbenchTheme.accent : WorkbenchTheme.secondary)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(message.timestamp, style: .time)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(WorkbenchTheme.tertiary)
            if alignment == .leading { Spacer() }
        }
    }
}

private struct ComposerView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var text: String
    @Binding var isShowingResearchSettings: Bool
    let send: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if model.hasActiveRunInAnotherConversation {
                HStack(spacing: 8) {
                    Label("另一个会话正在运行", systemImage: "gearshape.2")
                        .font(.caption)
                        .foregroundStyle(WorkbenchTheme.warning)
                    Spacer()
                    Button("返回运行会话") { model.openActiveConversation() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("继续研究或提出新的问题…")
                            .font(.system(size: 12))
                            .foregroundStyle(WorkbenchTheme.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .frame(
                            minHeight: 48,
                            idealHeight: model.isDesignPreview ? 52 : 58,
                            maxHeight: model.isDesignPreview ? 52 : 110
                        )
                        .accessibilityLabel("发送给 OpenScience Agent 的消息")
                }

                HStack(spacing: 8) {
                    WorkbenchIconButton(title: "添加文件或目录", symbol: "paperclip") {
                        chooseAttachment()
                    }
                    WorkbenchIconButton(title: "斜杠命令", symbol: "slash") {
                        if text.isEmpty { text = "/" } else { text += " /" }
                    }
                    Button {
                        isShowingResearchSettings.toggle()
                    } label: {
                        Label("研究设置", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .popover(isPresented: $isShowingResearchSettings, arrowEdge: .bottom) {
                        ResearchSettingsPopover(composerText: text)
                    }

                    if !model.draft.localRoots.isEmpty || !model.draft.fixtureFiles.isEmpty {
                        Text("\(model.draft.localRoots.count + model.draft.fixtureFiles.count) 个附件")
                            .font(.caption2)
                            .foregroundStyle(WorkbenchTheme.secondary)
                    } else if !model.conversationReselectionNotice.isEmpty {
                        Text(model.conversationReselectionNotice)
                            .font(.caption2)
                            .foregroundStyle(WorkbenchTheme.warning)
                            .lineLimit(1)
                            .help(model.conversationReselectionNotice)
                    }

                    Spacer()

                    Menu {
                        Button {
                            model.draft.useNetworkModel = false
                        } label: {
                            Label(
                                "本地 Extractive", systemImage: model.draft.useNetworkModel ? "" : "checkmark")
                        }
                        Button {
                            model.draft.useNetworkModel = true
                        } label: {
                            Label(
                                "OpenAI-compatible",
                                systemImage: model.draft.useNetworkModel ? "checkmark" : "")
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(model.workbenchModelName).lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .frame(minWidth: 120, alignment: .leading)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("研究模型：\(model.workbenchModelName)")

                    Button(action: send) {
                        if model.isPreparingPlan {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("发送", systemImage: "arrow.up")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(WorkbenchTheme.accent)
                    .controlSize(.regular)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(
                        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !model.workbenchCanSubmit
                    )
                    .accessibilityHint("快捷键 Command Return")
                }
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
            }
            .background(WorkbenchTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: WorkbenchTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: WorkbenchTheme.cardRadius, style: .continuous)
                    .stroke(WorkbenchTheme.separator, lineWidth: 1)
            }

            Text("OpenScience Agent 可能会出错，请核查重要信息。")
                .font(.system(size: 9))
                .foregroundStyle(WorkbenchTheme.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 7)
        .background(WorkbenchTheme.canvas)
    }

    private func chooseAttachment() {
        let panel = NSOpenPanel()
        panel.title = "添加研究文件或允许读取的目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        model.addConversationAttachments(panel.urls)
    }
}

private struct ResearchSettingsPopover: View {
    @EnvironmentObject private var model: AppModel
    let composerText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("研究设置")
                .font(.headline)
            TextField("研究范围（可选）", text: $model.draft.scope, axis: .vertical)
                .lineLimit(1...3)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("OpenAlex", isOn: providerBinding("openalex"))
                Toggle("Crossref", isOn: providerBinding("crossref"))
                Toggle("使用网络模型", isOn: $model.draft.useNetworkModel)
            }
            TextField("学术 API 联系邮箱（可选）", text: $model.draft.email)
                .textContentType(.emailAddress)
            Divider()
            Stepper("最多记录：\(model.draft.maxRecords)", value: $model.draft.maxRecords, in: 1...10_000)
            Stepper(
                "网络请求上限：\(model.draft.maxNetworkRequests)",
                value: $model.draft.maxNetworkRequests,
                in: 0...10_000
            )
            Stepper(
                "超时：\(model.draft.timeoutSeconds) 秒",
                value: $model.draft.timeoutSeconds,
                in: 1...86_400,
                step: 30
            )
            DisclosureGroup("约束与假设") {
                VStack(spacing: 8) {
                    TextField("约束（每行一项）", text: constraintsText, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("假设（每行一项）", text: assumptionsText, axis: .vertical)
                        .lineLimit(2...4)
                }
                .padding(.top, 6)
            }
            if model.draft.useNetworkModel && !model.draft.localRoots.isEmpty {
                Label("本地证据不能发送给网络模型。", systemImage: "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(WorkbenchTheme.warning)
            }
        }
        .padding(16)
        .frame(width: 285)
        .onChange(of: model.draft) {
            model.conversationDraftDidChange(composerText: composerText)
        }
    }

    private func providerBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { model.draft.sourceNames.contains(name) },
            set: { enabled in
                if enabled, !model.draft.sourceNames.contains(name) {
                    model.draft.sourceNames.append(name)
                } else if !enabled {
                    model.draft.sourceNames.removeAll { $0 == name }
                }
            }
        )
    }

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

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
