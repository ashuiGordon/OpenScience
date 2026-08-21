import OpenScienceCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var visibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(WorkspaceSection.allCases, selection: $model.selectedSection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
                    .accessibilityLabel(section.title)
            }
            .navigationTitle("OpenScience")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } content: {
            switch model.selectedSection ?? .newResearch {
            case .newResearch: NewResearchView()
            case .history: HistoryListView()
            case .providers: ProvidersView()
            case .settings: SettingsView(settings: model.settings)
            }
        } detail: {
            switch model.selectedSection ?? .newResearch {
            case .newResearch: ExecutionView()
            case .history: HistoryDetailContainer()
            case .providers: ProvidersSummaryView()
            case .settings: SettingsSummaryView()
            }
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
        .confirmationDialog(
            "打开外部网站？",
            isPresented: Binding(
                get: { model.pendingExternalURL != nil },
                set: { if !$0 { model.pendingExternalURL = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("仅本次打开") { model.confirmExternalOpen() }
            Button("取消", role: .cancel) { model.pendingExternalURL = nil }
        } message: {
            Text("OpenScience 不会向该网站发送凭据。目标主机：\(model.pendingExternalURL?.host ?? "")")
        }
        .overlay(alignment: .bottom) {
            if let message = model.operationMessage {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                    .accessibilityLabel("操作结果：\(message)")
                    .onTapGesture { model.operationMessage = nil }
            }
        }
    }
}
