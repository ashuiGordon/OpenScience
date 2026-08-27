import AppKit
import SwiftUI

enum WorkbenchTheme {
    static let sidebarWidth: CGFloat = 262
    static let inspectorWidth: CGFloat = 484
    static let contentMinimumWidth: CGFloat = 520

    static let canvas = adaptive(light: 0xF5F6F8, dark: 0x1E2225)
    static let panel = adaptive(light: 0xFFFFFF, dark: 0x161A1D)
    static let raised = adaptive(light: 0xECEFF3, dark: 0x1C2227)
    static let selection = adaptive(light: 0xD7E7FF, dark: 0x203E5B)
    static let separator = adaptive(light: 0xD4D8DE, dark: 0x343942)
    static let primary = adaptive(light: 0x17202A, dark: 0xF1F3F5)
    static let secondary = adaptive(light: 0x4E5967, dark: 0xA8AFB8)
    static let tertiary = adaptive(light: 0x707B88, dark: 0x7D848C)
    static let success = adaptive(light: 0x27864B, dark: 0x55B871)
    static let warning = adaptive(light: 0x946B00, dark: 0xD5A42E)
    static let danger = adaptive(light: 0xB93636, dark: 0xE06262)
    static let accent = adaptive(light: 0x185BC7, dark: 0x2766E8)

    static let cardRadius: CGFloat = 8
    static let compactRadius: CGFloat = 6
    static let hairline: CGFloat = 1

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let matched = appearance.bestMatch(from: [.darkAqua, .aqua])
                return color(matched == .darkAqua ? dark : light)
            })
    }

    private static func color(_ rgb: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
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
