import AppKit
import SwiftUI

/// Makes the design-review launch reproducible without affecting production window restoration.
struct PreviewWindowConfigurator: NSViewRepresentable {
    final class Coordinator {
        var configuredWindow: NSWindow?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window, coordinator: context.coordinator) }
    }

    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window, coordinator.configuredWindow !== window else { return }
        coordinator.configuredWindow = window
        let requestedSize = NSSize(width: 1_487, height: 1_058)
        // Keep deterministic previews on the primary captureable display. A restored window can
        // otherwise land on a virtual/secondary Space that `screencapture` cannot address.
        let screenFrame = NSScreen.screens.first?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = NSSize(
            width: requestedSize.width,
            height: min(requestedSize.height, screenFrame.height)
        )
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: max(screenFrame.minY, screenFrame.maxY - size.height)
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }
}
