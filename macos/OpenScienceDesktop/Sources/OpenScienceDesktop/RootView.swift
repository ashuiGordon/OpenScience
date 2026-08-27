import OpenScienceCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ConversationWorkbenchView()
            .preferredColorScheme(model.isDesignPreview ? .dark : nil)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("OpenScience Desktop")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(WorkbenchTheme.secondary)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        model.toggleSidebarPresentation()
                    } label: {
                        Label(
                            model.isSidebarEffectivelyVisible ? "收起会话栏" : "显示会话栏",
                            systemImage: "sidebar.left"
                        )
                    }
                    .help(model.isSidebarEffectivelyVisible ? "收起会话栏" : "显示会话栏")
                    Button {
                        model.toggleInspectorPresentation()
                    } label: {
                        Label(
                            model.isInspectorEffectivelyVisible ? "收起预览" : "显示预览",
                            systemImage: "sidebar.right"
                        )
                    }
                    .help(model.isInspectorEffectivelyVisible ? "收起预览" : "显示预览")
                }
            }
            .sheet(isPresented: sectionPresentation(.settings)) {
                NavigationStack {
                    SettingsView(settings: model.settings)
                        .frame(minWidth: 620, minHeight: 560)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { model.selectedSection = .newResearch }
                            }
                        }
                }
            }
            .sheet(isPresented: sectionPresentation(.providers)) {
                NavigationSplitView {
                    ProvidersView()
                } detail: {
                    ProvidersSummaryView()
                }
                .frame(minWidth: 760, minHeight: 560)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { model.selectedSection = .newResearch }
                    }
                }
            }
            .sheet(isPresented: sectionPresentation(.history)) {
                NavigationSplitView {
                    HistoryListView()
                } detail: {
                    HistoryDetailContainer()
                }
                .frame(minWidth: 900, minHeight: 650)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { model.selectedSection = .newResearch }
                    }
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
                Text(verbatim: model.errorMessage ?? "未知错误")
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
                    Text(verbatim: message)
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

    private func sectionPresentation(_ section: WorkspaceSection) -> Binding<Bool> {
        Binding(
            get: { model.selectedSection == section },
            set: { if !$0 { model.selectedSection = .newResearch } }
        )
    }
}
