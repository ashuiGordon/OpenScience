import OpenScienceCore
import SwiftUI

struct ProvidersView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if !model.engineAvailable {
                ContentUnavailableView(
                    "引擎不可用",
                    systemImage: "exclamationmark.octagon",
                    description: Text(model.engineStatusText)
                )
            } else if model.providers.isEmpty {
                ContentUnavailableView(
                    "没有可用 Provider",
                    systemImage: "shippingbox",
                    description: Text("重新探测引擎或检查 Provider 扩展。")
                )
            } else {
                List(model.providers) { provider in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(
                                systemName: provider.available
                                    ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .foregroundStyle(provider.available ? .green : .red)
                            Text(provider.name).font(.headline.monospaced())
                            Spacer()
                            Text(provider.risk ?? "unknown")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.12), in: Capsule())
                        }
                        HStack {
                            Text(provider.kind ?? "unknown")
                            Text("v\(provider.version ?? "unknown")")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let error = provider.healthError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 5)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "Provider \(provider.name)，\(provider.available ? "可用" : "不可用")，风险 \(provider.risk ?? "未知")"
                    )
                }
            }
        }
        .navigationTitle("Providers")
        .toolbar {
            Button {
                model.probeEngine()
            } label: {
                Label("重新探测", systemImage: "arrow.clockwise")
            }
            .accessibilityLabel("重新探测引擎和 Providers")
        }
    }
}

struct ProvidersSummaryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Provider 能力目录", systemImage: "shippingbox.fill")
                .font(.title2.bold())
            Label(
                model.engineStatusText, systemImage: model.engineAvailable ? "checkmark.seal" : "xmark.seal"
            )
            .foregroundStyle(model.engineAvailable ? .green : .red)
            GroupBox("风险说明") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("local_read：只读取明确授权的本地输入", systemImage: "internaldrive")
                    Label("network_read：必须在每次计划中单独确认", systemImage: "network")
                    Label("不可用或未知风险的 Provider 不应执行", systemImage: "hand.raised")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(
                "共发现 \(model.providers.count) 个 Provider，其中 \(model.providers.filter(\.available).count) 个可用。"
            )
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(28)
        .navigationTitle("能力与风险")
    }
}
