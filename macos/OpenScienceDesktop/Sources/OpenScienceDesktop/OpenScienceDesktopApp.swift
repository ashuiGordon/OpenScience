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
                .frame(minWidth: 1_080, minHeight: 700)
                .onAppear {
                    appDelegate.hasActiveRun = { model.hasActiveAttempt }
                    appDelegate.requestCancellation = { model.cancelActive() }
                }
        }
        .defaultSize(width: 1_280, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建研究") { model.selectedSection = .newResearch }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.selectedSection = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("研究") {
                Button("生成并审阅计划") { model.startRun() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(
                        model.isRunning || model.isPreparingPlan || model.pendingPlan != nil
                            || model.selectedSection != .newResearch || !model.engineAvailable
                    )
                Button("取消运行") { model.cancelActive() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isRunning)
                Divider()
                Button("验证所选运行") { model.validateSelected() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(model.selectedRun == nil || !model.engineAvailable)
                Button("刷新历史") { model.refreshHistory() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("显示 Providers") { model.selectedSection = .providers }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}
