import AppKit
import Foundation
import SwiftUI

private final class UnconstrainedPreviewWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@main
private struct WorkbenchPreviewRenderer {
    @MainActor
    static func main() throws {
        guard let outputArgument = CommandLine.arguments.last,
            outputArgument.hasSuffix(".png")
        else {
            throw NSError(domain: "OpenSciencePreview", code: 2)
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let model = AppModel()
        let root = RootView()
            .environmentObject(model)
            .environmentObject(model.conversations)
            .preferredColorScheme(.dark)

        let controller = NSHostingController(rootView: root)
        let window = UnconstrainedPreviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_487, height: 1_000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenScience"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)

        for _ in 0..<8 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        window.setFrame(NSRect(x: 0, y: 0, width: 1_487, height: 1_058), display: true)
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        for _ in 0..<4 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        guard let frameView = window.contentView?.superview else {
            throw NSError(domain: "OpenSciencePreview", code: 3)
        }
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        let bounds = frameView.bounds
        guard Int(bounds.width.rounded()) == 1_487,
            Int(bounds.height.rounded()) == 1_058,
            let representation = frameView.bitmapImageRepForCachingDisplay(in: bounds)
        else {
            throw NSError(
                domain: "OpenSciencePreview",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected frame \(bounds)"]
            )
        }
        frameView.cacheDisplay(in: bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "OpenSciencePreview", code: 5)
        }
        try png.write(to: URL(fileURLWithPath: outputArgument), options: .atomic)
        window.orderOut(nil)
    }
}
