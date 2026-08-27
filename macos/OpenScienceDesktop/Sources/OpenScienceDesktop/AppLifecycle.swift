import AppKit

@MainActor
final class DesktopAppDelegate: NSObject, NSApplicationDelegate {
    var hasActiveRun: () -> Bool = { false }
    var requestCancellation: () -> Void = {}

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard hasActiveRun() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "研究仍在运行"
        alert.informativeText = "关闭应用会终止客户端进程。你可以留在应用中，或先写入精确 Run 的取消标记。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保持打开")
        alert.addButton(withTitle: "请求取消并保持打开")
        alert.addButton(withTitle: "仍然退出")
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            requestCancellation()
            return .terminateCancel
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
