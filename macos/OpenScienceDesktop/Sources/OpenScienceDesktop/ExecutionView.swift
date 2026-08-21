import AppKit
import OpenScienceCore
import OpenScienceDesktopLogic
import SwiftUI

struct ExecutionView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isRunning {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        ProgressView(value: model.progress.fraction)
                            .frame(maxWidth: 260)
                            .accessibilityLabel("研究执行进度")
                            .accessibilityValue(
                                "完成 \(model.progress.completedSteps) / \(model.progress.totalSteps) 步")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.activeRunDirectory?.lastPathComponent ?? "正在创建 Run ID")
                                .font(.headline)
                                .textSelection(.enabled)
                            Text(
                                "\(model.progress.completedSteps)/\(model.progress.totalSteps) · \(model.progress.lastEvent)"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let started = model.runStartedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                Text(elapsed(from: started, to: timeline.date))
                                    .font(.caption.monospacedDigit())
                                    .accessibilityLabel("已运行 \(elapsed(from: started, to: timeline.date))")
                            }
                        }
                        Button(role: .destructive) {
                            model.cancelActive()
                        } label: {
                            Label("取消", systemImage: "stop.fill")
                        }
                        .keyboardShortcut(".", modifiers: .command)
                        .disabled(model.cancellationRequested)
                        .accessibilityLabel("取消当前精确 Run ID")
                    }

                    HStack(spacing: 8) {
                        ForEach(ActiveRunProjector.stepIDs, id: \.self) { step in
                            stepBadge(step, state: model.activeProjection.steps[step] ?? .pending)
                        }
                        Spacer()
                        Label("\(model.activeProjection.sources)", systemImage: "doc.text")
                        Label("\(model.activeProjection.evidence)", systemImage: "quote.bubble")
                        Label("\(model.activeProjection.claims)", systemImage: "checkmark.seal")
                    }
                    .font(.caption)
                    if !model.cancellationStatus.isEmpty {
                        Label(model.cancellationStatus, systemImage: "stop.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
                .padding()
            } else {
                HStack {
                    Label("准备就绪", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
            }

            Divider()

            if model.logs.isEmpty {
                ContentUnavailableView(
                    "尚无执行日志",
                    systemImage: "text.alignleft",
                    description: Text("配置研究后按 ⌘↩ 开始。")
                )
            } else {
                ScrollViewReader { proxy in
                    List(model.logs) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.timestamp, style: .time)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            if let stream = entry.stream {
                                Text(stream == .stderr ? "ERR" : "OUT")
                                    .font(.caption2.monospaced().bold())
                                    .foregroundStyle(stream == .stderr ? .red : .secondary)
                            }
                            Text(entry.message)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        .id(entry.id)
                        .accessibilityElement(children: .combine)
                    }
                    .onChange(of: model.logs.count) {
                        if let last = model.logs.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .navigationTitle("执行与日志")
        .toolbar {
            if let directory = model.activeRunDirectory {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                .accessibilityLabel("在 Finder 中显示当前运行目录")
            }
        }
    }

    private func stepBadge(_ name: String, state: DesktopStepState) -> some View {
        HStack(spacing: 4) {
            Image(systemName: stepSymbol(state))
            Text(name)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(stepColor(state).opacity(0.13), in: Capsule())
        .foregroundStyle(stepColor(state))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("步骤 \(name)，\(state.rawValue)")
    }

    private func stepSymbol(_ state: DesktopStepState) -> String {
        switch state {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    private func stepColor(_ state: DesktopStepState) -> Color {
        switch state {
        case .pending: return .secondary
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }
}
