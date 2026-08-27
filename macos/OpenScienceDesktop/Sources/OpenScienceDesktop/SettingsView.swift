import AppKit
import OpenScienceCore
import SwiftUI

private struct SecretEditRequest: Identifiable {
    let id = UUID()
    let kind: SecretKind
    let replacing: Bool
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var settings: ClientSettings
    @State private var secretEdit: SecretEditRequest?
    @State private var secretToRemove: SecretKind?
    @State private var credentialRefresh = UUID()

    init(settings: ClientSettings? = nil) {
        _settings = ObservedObject(wrappedValue: settings ?? ClientSettings())
    }

    var body: some View {
        Form {
            Section("CLI 引擎") {
                PathSettingRow(
                    title: "开发模式 openscience",
                    path: $settings.cliExecutablePath,
                    choose: chooseCLI
                )
                LabeledContent("当前状态") {
                    Label(
                        model.engineStatusText,
                        systemImage: model.engineAvailable ? "checkmark.circle.fill" : "xmark.octagon.fill"
                    )
                    .foregroundStyle(model.engineAvailable ? .green : .red)
                }
                Button("重新探测兼容引擎") { model.probeEngine() }
                    .accessibilityLabel("重新探测 bundled helper 或开发模式 CLI")
                PathSettingRow(
                    title: "工作目录",
                    path: $settings.workingDirectoryPath,
                    choose: { chooseDirectory(binding: $settings.workingDirectoryPath) }
                )
                PathSettingRow(
                    title: "运行记录根目录",
                    path: $settings.runRootPath,
                    choose: { chooseDirectory(binding: $settings.runRootPath) }
                )
            }

            Section("模型") {
                PathSettingRow(
                    title: "模型配置 JSON",
                    path: $settings.modelConfigPath,
                    choose: chooseModelConfig,
                    canClear: true
                )
                LabeledContent("密钥环境变量") {
                    Text("OPENSCIENCE_MODEL_API_KEY")
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                Text("配置文件不应包含密钥。真实密钥只保存在 macOS Keychain。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keychain 凭据") {
                credentialRow("模型 API Key", kind: .modelAPIKey)
                credentialRow("OpenAlex API Key", kind: .openAlexAPIKey)
                credentialRow("Crossref API Key", kind: .crossrefAPIKey)
                Text("客户端不会读取并回显已保存的密钥；这里只显示是否存在。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .id(credentialRefresh)
        .formStyle(.grouped)
        .navigationTitle("设置")
        .navigationSplitViewColumnWidth(min: 420, ideal: 520)
        .sheet(item: $secretEdit) { request in
            SecretEditorSheet(request: request) { value in
                do {
                    try settings.writeSecret(value, kind: request.kind)
                    credentialRefresh = UUID()
                } catch {
                    model.errorMessage = error.localizedDescription
                }
            }
        }
        .confirmationDialog(
            "移除 Keychain 凭据？",
            isPresented: Binding(
                get: { secretToRemove != nil },
                set: { if !$0 { secretToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移除", role: .destructive) {
                guard let kind = secretToRemove else { return }
                do {
                    try settings.removeSecret(kind)
                    credentialRefresh = UUID()
                } catch {
                    model.errorMessage = error.localizedDescription
                }
                secretToRemove = nil
            }
            Button("取消", role: .cancel) { secretToRemove = nil }
        } message: {
            Text("该操作只移除所选凭据，不影响其他 Keychain 项。")
        }
    }

    private func credentialRow(_ title: String, kind: SecretKind) -> some View {
        let present = settings.hasSecret(kind)
        return LabeledContent(title) {
            HStack {
                Label(present ? "已保存" : "未保存", systemImage: present ? "key.fill" : "key.slash")
                    .foregroundStyle(present ? .green : .secondary)
                Button(present ? "替换…" : "添加…") {
                    secretEdit = SecretEditRequest(kind: kind, replacing: present)
                }
                if present {
                    Button("移除…", role: .destructive) { secretToRemove = kind }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title)，\(present ? "已保存" : "未保存")")
        }
    }

    private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.title = "选择开发模式 openscience 可执行文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.cliExecutablePath = url.path
            model.probeEngine()
        }
    }

    private func chooseDirectory(binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { binding.wrappedValue = url.path }
    }

    private func chooseModelConfig() {
        let panel = NSOpenPanel()
        panel.title = "选择 OpenAI-compatible 模型配置"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { settings.modelConfigPath = url.path }
    }
}

private struct SecretEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: SecretEditRequest
    let save: (String) -> Void
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.replacing ? "替换 Keychain 凭据" : "添加 Keychain 凭据")
                .font(.title2.bold())
            Text("现有值不会被读取或显示。新值只会写入 macOS Keychain。")
                .foregroundStyle(.secondary)
            SecureField("输入新密钥", text: $value)
                .textContentType(.newPassword)
                .accessibilityLabel("新 API 密钥")
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(request.replacing ? "确认替换" : "确认添加") {
                    save(value)
                    value = ""
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(value.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(!value.isEmpty)
    }
}

private struct PathSettingRow: View {
    let title: String
    @Binding var path: String
    let choose: () -> Void
    var canClear = false

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: $path)
                    .font(.caption.monospaced())
                    .accessibilityLabel(title)
                if canClear && !path.isEmpty {
                    Button {
                        path = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除 \(title)")
                }
                Button("选择…", action: choose).accessibilityLabel("选择 \(title)")
            }
        }
    }
}

struct SettingsSummaryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("本地优先的科研工作区", systemImage: "lock.shield")
                .font(.title2.bold())
            GroupBox("引擎门禁") {
                Label(
                    model.engineStatusText,
                    systemImage: model.engineAvailable ? "checkmark.seal.fill" : "xmark.seal.fill"
                )
                .foregroundStyle(model.engineAvailable ? .green : .red)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("隐私边界") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("本地目录必须逐次明确授权", systemImage: "folder.badge.person.crop")
                    Label("本地证据与网络模型组合会被拒绝", systemImage: "hand.raised")
                    Label("网络能力在每次计划或恢复中单独确认", systemImage: "network")
                    Label("密钥只按本次所需 Provider 从 Keychain 注入", systemImage: "key")
                    Label("CLI 不经过 shell，输出有上限且会脱敏", systemImage: "terminal")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
        .padding(28)
        .navigationTitle("运行环境")
    }
}
