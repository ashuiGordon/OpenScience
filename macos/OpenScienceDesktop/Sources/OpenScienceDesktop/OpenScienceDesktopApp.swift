import OpenScienceCore
import SwiftUI

@main
struct OpenScienceDesktopApp: App {
    @NSApplicationDelegateAdaptor(DesktopAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("OpenScience") {
            RootView()
                .environmentObject(model)
                .environmentObject(model.conversations)
                .frame(minWidth: 760, minHeight: 620)
                .onAppear {
                    appDelegate.hasActiveRun = { model.hasActiveAttempt }
                    appDelegate.requestCancellation = { model.cancelActive() }
                }
        }
        .defaultSize(width: 1_440, height: 900)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建对话") { model.createConversationSession() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("搜索会话") { model.focusConversationSearch() }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("查找当前研究内容") { model.focusConversationContentFind() }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.selectedSection = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("研究") {
                Button("取消运行") { model.cancelActive() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isRunning)
                Divider()
                Button("验证所选运行") { model.validateSelected() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(model.selectedRun == nil || !model.engineAvailable)
                Button("导出经过验证的研究包…") { model.presentExportPanel() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!model.workbenchCanOfferExport)
                Button("刷新历史") { model.refreshHistory() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("显示 Providers") { model.selectedSection = .providers }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button(model.isInspectorEffectivelyVisible ? "收起预览" : "显示预览") {
                    model.toggleInspectorPresentation()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Button(model.isSidebarEffectivelyVisible ? "收起会话栏" : "显示会话栏") {
                    model.toggleSidebarPresentation()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("关闭查找或非破坏性界面") { model.handleSafeEscape() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}
