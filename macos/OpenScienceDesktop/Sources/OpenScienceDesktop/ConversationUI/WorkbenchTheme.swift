import AppKit
import SwiftUI

enum WorkbenchTheme {
    static let sidebarWidth: CGFloat = 262
    static let inspectorWidth: CGFloat = 484
    static let contentMinimumWidth: CGFloat = 520

    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let raised = Color(nsColor: .underPageBackgroundColor)
    static let selection = Color(nsColor: .systemBlue).opacity(0.28)
    static let separator = Color(nsColor: .separatorColor)
    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemYellow)
    static let danger = Color(nsColor: .systemRed)
    static let accent = Color(nsColor: .systemBlue)

    static let cardRadius: CGFloat = 8
    static let compactRadius: CGFloat = 6
    static let hairline: CGFloat = 1
}

struct WorkbenchCard<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .background(WorkbenchTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: WorkbenchTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: WorkbenchTheme.cardRadius, style: .continuous)
                    .stroke(WorkbenchTheme.separator, lineWidth: WorkbenchTheme.hairline)
            }
    }
}

struct WorkbenchStatusDot: View {
    let color: Color
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct WorkbenchIconButton: View {
    let title: String
    let symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(WorkbenchTheme.secondary)
        .help(title)
        .accessibilityLabel(title)
    }
}
