import SwiftUI

struct ConversationWorkbenchView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.isDesignPreview {
                HStack(spacing: 0) {
                    ConversationSidebar()
                        .frame(width: WorkbenchTheme.sidebarWidth)
                    Divider()
                    ConversationTimeline()
                        .frame(minWidth: WorkbenchTheme.contentMinimumWidth, maxWidth: .infinity)
                    Divider()
                    InspectorPane()
                        .frame(width: WorkbenchTheme.inspectorWidth)
                }
            } else {
                adaptiveWorkbench
            }
        }
        .background(WorkbenchTheme.canvas)
        .background {
            if model.isDesignPreview { PreviewWindowConfigurator() }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.isInspectorPresented)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.isSidebarPresented)
    }

    private var adaptiveWorkbench: some View {
        GeometryReader { geometry in
            HSplitView {
                if model.isSidebarEffectivelyVisible {
                    ConversationSidebar()
                        .frame(
                            minWidth: 246,
                            idealWidth: WorkbenchTheme.sidebarWidth,
                            maxWidth: 278,
                            maxHeight: .infinity
                        )
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                ConversationTimeline()
                    .frame(
                        minWidth: min(WorkbenchTheme.contentMinimumWidth, geometry.size.width),
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )

                if model.isInspectorEffectivelyVisible {
                    InspectorPane()
                        .frame(
                            minWidth: 460,
                            idealWidth: WorkbenchTheme.inspectorWidth,
                            maxWidth: 508,
                            maxHeight: .infinity
                        )
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .onAppear { model.updateWorkbenchWidth(geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in
                model.updateWorkbenchWidth(width)
            }
        }
    }
}
