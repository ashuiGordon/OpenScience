import OpenScienceDesktopLogic
import SwiftUI

struct ConversationSidebar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var conversations: ConversationStore
    @State private var searchText = ""
    @State private var isShowingArchived = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            projectPicker
                .padding(.horizontal, 10)
                .padding(.top, 10)

            Button {
                model.createConversationSession()
            } label: {
                Label("新建对话", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11)
                    .frame(height: 36)
                    .foregroundStyle(.white)
                    .background(WorkbenchTheme.accent)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: WorkbenchTheme.cardRadius, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .accessibilityHint("创建一个空白科研会话")

            searchField
                .padding(.horizontal, 10)
                .padding(.top, 10)

            if let issue = conversations.issues.first {
                Label("已隔离 \(conversations.issues.count) 个会话存储问题", systemImage: "exclamationmark.shield")
                    .font(.caption2)
                    .foregroundStyle(WorkbenchTheme.warning)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .help("\(issue.outcome)：\(issue.safeDetail)")
            }

            sessionList

            Button {
                isShowingArchived.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox")
                    Text(isShowingArchived ? "返回活动会话" : "已归档")
                    Spacer()
                    Text("\(archivedSessionCount)")
                        .font(.caption2.monospacedDigit())
                }
                .font(.system(size: 11))
                .foregroundStyle(WorkbenchTheme.secondary)
                .padding(.horizontal, 12)
                .frame(height: 32)
            }
            .buttonStyle(.plain)
            .disabled(archivedSessionCount == 0 && !isShowingArchived)

            sidebarFooter
        }
        .frame(
            minWidth: model.isDesignPreview ? WorkbenchTheme.sidebarWidth : 246,
            idealWidth: WorkbenchTheme.sidebarWidth,
            maxWidth: model.isDesignPreview ? WorkbenchTheme.sidebarWidth : 278
        )
        .background(WorkbenchTheme.canvas)
    }

    private var projectPicker: some View {
        Menu {
            ForEach(conversations.projects.filter { !$0.isArchived }) { project in
                Button {
                    model.selectConversationProject(project.id)
                } label: {
                    if project.id == conversations.selectedProjectID {
                        Label(project.title, systemImage: "checkmark")
                    } else {
                        Text(project.title)
                    }
                }
            }
            Divider()
            if let project = conversations.selectedProject {
                Button("重命名当前项目…", systemImage: "pencil") {
                    model.renameSelectedConversationProject()
                }
                Button("归档当前项目", systemImage: "archivebox") {
                    model.archiveConversationProject(project.id)
                }
            }
            Button("新建项目…", systemImage: "folder.badge.plus") {
                model.createConversationProject()
            }
            if conversations.projects.contains(where: \.isArchived) {
                Divider()
                Menu("已归档项目") {
                    ForEach(conversations.projects.filter(\.isArchived)) { project in
                        Button("恢复 \(project.title)") {
                            model.archiveConversationProject(project.id, archived: false)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "atom")
                    .foregroundStyle(WorkbenchTheme.accent)
                    .frame(width: 20)
                Text(conversations.selectedProject?.title ?? "OpenScience")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WorkbenchTheme.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(WorkbenchTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: WorkbenchTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: WorkbenchTheme.cardRadius, style: .continuous)
                    .stroke(WorkbenchTheme.separator, lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("当前项目：\(conversations.selectedProject?.title ?? "OpenScience")")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(WorkbenchTheme.tertiary)
            TextField("搜索会话", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isSearchFocused)
                .accessibilityLabel("搜索会话")
            Text("⌘K")
                .font(.caption2.monospaced())
                .foregroundStyle(WorkbenchTheme.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(WorkbenchTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: WorkbenchTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: WorkbenchTheme.cardRadius, style: .continuous)
                .stroke(WorkbenchTheme.separator, lineWidth: 1)
        }
        .onChange(of: model.conversationSearchFocusToken) {
            isSearchFocused = true
        }
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text("会话")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WorkbenchTheme.secondary)
                    .padding(.horizontal, 8)

                if visibleSessions.isEmpty {
                    VStack(spacing: 9) {
                        Image(
                            systemName: searchText.isEmpty
                                ? "bubble.left.and.bubble.right" : "magnifyingglass"
                        )
                        .font(.title2)
                        .foregroundStyle(WorkbenchTheme.tertiary)
                        Text(searchText.isEmpty ? "还没有研究会话" : "没有匹配的会话")
                            .font(.caption)
                            .foregroundStyle(WorkbenchTheme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                } else {
                    ForEach(groupedSessions, id: \.title) { group in
                        sessionGroup(group.title, sessions: group.sessions)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 18)
        }
        .scrollIndicators(.hidden)
    }

    private func sessionGroup(_ title: String, sessions: [ConversationSession]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(WorkbenchTheme.tertiary)
                .padding(.horizontal, 3)
                .padding(.bottom, 2)
            ForEach(sessions) { session in
                sessionRow(session)
            }
        }
    }

    private func sessionRow(_ session: ConversationSession) -> some View {
        Button {
            model.selectConversationSession(session.id)
        } label: {
            HStack(spacing: 8) {
                WorkbenchStatusDot(color: statusColor(session.status))
                Text(session.title)
                    .font(
                        .system(
                            size: 12,
                            weight: session.id == conversations.selectedSessionID ? .semibold : .regular)
                    )
                    .lineLimit(1)
                    .foregroundStyle(WorkbenchTheme.primary)
                Spacer(minLength: 4)
                Text(session.updatedAt, format: sessionTimeFormat(session.updatedAt))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(WorkbenchTheme.tertiary)
            }
            .padding(.horizontal, 9)
            .frame(height: 31)
            .contentShape(Rectangle())
            .background(
                session.id == conversations.selectedSessionID
                    ? WorkbenchTheme.selection : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: WorkbenchTheme.compactRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if session.isArchived {
                Button("恢复", systemImage: "arrow.uturn.backward") {
                    model.archiveConversationSession(session.id, archived: false)
                }
                Button("重命名…", systemImage: "pencil") {
                    model.renameConversationSession(session.id)
                }
            } else {
                Button("重命名…", systemImage: "pencil") {
                    model.renameConversationSession(session.id)
                }
                Button("归档", systemImage: "archivebox") {
                    model.archiveConversationSession(session.id)
                }
            }
            Divider()
            Button("删除会话元数据…", systemImage: "trash", role: .destructive) {
                model.confirmDeleteConversationMetadata(session.id)
            }
        }
        .accessibilityLabel("\(session.title)，\(statusText(session.status))")
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 0) {
                footerRow(
                    "运行时",
                    value: model.engineAvailable ? "本地优先" : "不可用",
                    symbol: "desktopcomputer",
                    status: model.engineAvailable ? WorkbenchTheme.success : WorkbenchTheme.danger
                )
                footerRow(
                    "模型",
                    value: model.workbenchModelName,
                    symbol: "cpu",
                    status: model.draft.useNetworkModel ? WorkbenchTheme.warning : WorkbenchTheme.success
                )
                footerRow(
                    "工具",
                    value: model.workbenchToolAvailabilityText,
                    symbol: "hammer",
                    status: model.isDesignPreview || model.providers.contains(where: \.available)
                        ? WorkbenchTheme.success : WorkbenchTheme.tertiary
                )
                footerRow(
                    "网络",
                    value: model.workbenchNetworkStatus,
                    symbol: "network",
                    status: model.pendingPlanContext?.requiresNetworkGrant == true
                        ? WorkbenchTheme.warning : WorkbenchTheme.secondary
                )
                Divider().padding(.vertical, 6)
                Button {
                    model.selectedSection = .history
                } label: {
                    Label("运行历史", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                        .frame(height: 28)
                }
                .buttonStyle(.plain)
                Button {
                    model.selectedSection = .providers
                } label: {
                    Label("Providers", systemImage: "shippingbox")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                        .frame(height: 28)
                }
                .buttonStyle(.plain)
                Button {
                    model.presentSettings()
                } label: {
                    Label("设置", systemImage: "gearshape")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                        .frame(height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(10)
        }
    }

    private func footerRow(
        _ title: String,
        value: String,
        symbol: String,
        status: Color
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .frame(width: 13)
                .foregroundStyle(WorkbenchTheme.secondary)
            Text(title)
                .foregroundStyle(WorkbenchTheme.secondary)
            Spacer(minLength: 4)
            WorkbenchStatusDot(color: status)
            Text(value)
                .lineLimit(1)
                .foregroundStyle(WorkbenchTheme.tertiary)
        }
        .font(.system(size: 10))
        .frame(height: 24)
    }

    private var visibleSessions: [ConversationSession] {
        let sessions =
            conversations.selectedProject?.sessions.filter {
                isShowingArchived ? $0.isArchived : !$0.isArchived
            } ?? []
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sessions.sorted { $0.updatedAt > $1.updatedAt } }
        return sessions.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(needle) }
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var archivedSessionCount: Int {
        conversations.selectedProject?.sessions.filter(\.isArchived).count ?? 0
    }

    private var groupedSessions: [(title: String, sessions: [ConversationSession])] {
        let calendar = Calendar.current
        let today = visibleSessions.filter { calendar.isDateInToday($0.updatedAt) }
        let yesterday = visibleSessions.filter { calendar.isDateInYesterday($0.updatedAt) }
        let earlier = visibleSessions.filter {
            !calendar.isDateInToday($0.updatedAt) && !calendar.isDateInYesterday($0.updatedAt)
        }
        return [("今天", today), ("昨天", yesterday), ("更早", earlier)]
            .filter { !$0.sessions.isEmpty }
    }

    private func statusColor(_ status: SessionStatus) -> Color {
        switch status {
        case .draft: return WorkbenchTheme.tertiary
        case .planning, .awaitingApproval: return WorkbenchTheme.warning
        case .running: return WorkbenchTheme.accent
        case .completed: return WorkbenchTheme.success
        case .partial: return WorkbenchTheme.warning
        case .failed: return WorkbenchTheme.danger
        case .cancelled: return .orange
        case .interrupted: return .orange
        case .invalid: return WorkbenchTheme.danger
        case .unknown: return WorkbenchTheme.tertiary
        }
    }

    private func statusText(_ status: SessionStatus) -> String {
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

    private func sessionTimeFormat(_ date: Date) -> Date.FormatStyle {
        if Calendar.current.isDateInToday(date) {
            return .dateTime.hour().minute()
        }
        return .dateTime.month(.twoDigits).day(.twoDigits)
    }
}
