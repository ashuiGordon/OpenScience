import Foundation
import OpenScienceCore

public enum ConversationTimelineProjector {
    public static func project(
        plan: ResearchPlanRecord,
        context: PlanReviewContext,
        sessionID: UUID,
        timestamp: Date = Date()
    ) -> ConversationTimelineProjection {
        let stepLines = plan.steps.enumerated().map { index, step in
            "\(index + 1). \(step.title)"
        }
        let planMessage = ConversationMessage(
            role: .assistant,
            kind: .plan,
            text: (["研究计划 · \(plan.steps.count) 个步骤"] + stepLines).joined(separator: "\n"),
            timestamp: timestamp
        )
        var messages: [ConversationMessage] = []
        if context.requiresNetworkGrant {
            let capabilities = context.networkCapabilities.map(\.name).joined(separator: "、")
            let destinations = context.networkCapabilities.compactMap(\.destination)
                .joined(separator: "、")
            var lines = [
                "需要一次性网络授权",
                "能力：\(capabilities)",
                "上限：\(context.maxNetworkRequests) 次请求 · \(context.timeoutSeconds) 秒",
            ]
            if !destinations.isEmpty { lines.append("目标：\(destinations)") }
            if !context.localRoots.isEmpty {
                lines.append("本次研究同时包含本地资料；授权前请确认数据边界。")
            }
            messages.append(
                ConversationMessage(
                    role: .assistant,
                    kind: .permission,
                    text: lines.joined(separator: "\n"),
                    timestamp: timestamp
                ))
        }
        messages.append(planMessage)
        return ConversationTimelineProjection(
            messages: messages,
            preview: .plan(context),
            selection: InspectorSelection(
                tab: .plan,
                sessionID: sessionID,
                messageID: planMessage.id
            )
        )
    }

    public static func project(
        activeRun: ActiveRunProjection,
        runID: String,
        sessionID: UUID,
        timestamp: Date = Date()
    ) -> ConversationTimelineProjection {
        let status = activeStatus(activeRun)
        let completed = activeRun.steps.values.filter { $0 == .completed }.count
        let total = activeRun.steps.count
        let running = activeRun.steps
            .filter { $0.value == .running }
            .map(\.key)
            .sorted()
        var lines = [
            status == .cancelled ? "正在取消研究" : "研究正在运行",
            "步骤 \(completed)/\(total)",
            "\(activeRun.sources) 个来源 · \(activeRun.evidence) 条证据 · \(activeRun.claims) 条结论",
        ]
        if !running.isEmpty { lines.append("当前：\(running.joined(separator: "、"))") }
        let message = ConversationMessage(
            role: .assistant,
            kind: status == .failed ? .error : .runProgress,
            text: lines.joined(separator: "\n"),
            timestamp: timestamp,
            runReference: ConversationRunReference(
                runID: runID,
                status: status,
                sources: activeRun.sources,
                evidence: activeRun.evidence,
                claims: activeRun.claims
            )
        )
        return ConversationTimelineProjection(
            messages: [message],
            preview: .activity(runID: Redactor.redact(runID), projection: activeRun),
            selection: InspectorSelection(
                tab: .context,
                sessionID: sessionID,
                messageID: message.id,
                runID: runID
            )
        )
    }

    public static func project(
        outcome: RunOutcome,
        detail: RunDetail?,
        sessionID: UUID,
        timestamp: Date = Date()
    ) -> ConversationTimelineProjection {
        let status = RunStatus(rawOrUnknown: outcome.status)
        let kind: MessageKind = status == .failed || status == .unknown ? .error : .result
        var lines = [
            resultHeading(status),
            "\(outcome.sources) 个来源 · \(outcome.evidence) 条证据 · \(outcome.claims) 条结论",
        ]
        if !outcome.limitations.isEmpty {
            lines.append("限制：\(outcome.limitations.joined(separator: "；"))")
        }
        let artifacts = artifactReferences(outcome: outcome, detail: detail)
        let message = ConversationMessage(
            role: .assistant,
            kind: kind,
            text: lines.joined(separator: "\n"),
            timestamp: timestamp,
            runReference: ConversationRunReference(
                runID: outcome.runID,
                status: status,
                sources: outcome.sources,
                evidence: outcome.evidence,
                claims: outcome.claims
            ),
            artifactReferences: artifacts
        )
        let tab: InspectorTab
        switch status {
        case .completed, .partial: tab = detail == nil ? .context : .artifacts
        case .created, .awaitingApproval, .running, .failed, .cancelled, .unknown: tab = .context
        }
        return ConversationTimelineProjection(
            messages: [message],
            preview: .result(outcome: outcome, detail: detail),
            selection: InspectorSelection(
                tab: tab,
                sessionID: sessionID,
                messageID: message.id,
                runID: outcome.runID,
                artifactID: tab == .artifacts
                    ? artifacts.first(where: { $0.kind == .report })?.id : nil
            )
        )
    }

    public static func project(
        detail: RunDetail,
        sessionID: UUID,
        timestamp: Date = Date()
    ) -> ConversationTimelineProjection {
        let outcomeJSON = JSONValue.object([
            "run_id": .string(detail.item.runID),
            "run_directory": .string(detail.item.directory.path),
            "status": .string(detail.item.status.rawValue),
            "sources": .number(Double(detail.item.sourceCount)),
            "evidence": .number(Double(detail.item.evidenceCount)),
            "claims": .number(Double(detail.item.claimCount)),
            "limitations": .array([]),
        ])
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        if let data = try? encoder.encode(outcomeJSON),
            let outcome = try? decoder.decode(RunOutcome.self, from: data)
        {
            return project(
                outcome: outcome,
                detail: detail,
                sessionID: sessionID,
                timestamp: timestamp
            )
        }
        let message = ConversationMessage(
            role: .assistant,
            kind: .error,
            text: "无法构建运行预览。",
            timestamp: timestamp,
            runReference: ConversationRunReference(
                runID: detail.item.runID,
                status: detail.item.status,
                sources: detail.item.sourceCount,
                evidence: detail.item.evidenceCount,
                claims: detail.item.claimCount
            )
        )
        return ConversationTimelineProjection(
            messages: [message],
            preview: .empty,
            selection: InspectorSelection(
                tab: .context,
                sessionID: sessionID,
                messageID: message.id,
                runID: detail.item.runID
            )
        )
    }

    private static func activeStatus(_ projection: ActiveRunProjection) -> RunStatus {
        if projection.cancellationRequested { return .cancelled }
        if projection.steps.values.contains(.failed) { return .failed }
        if !projection.steps.isEmpty, projection.steps.values.allSatisfy({ $0 == .completed }) {
            return .completed
        }
        return .running
    }

    private static func resultHeading(_ status: RunStatus) -> String {
        switch status {
        case .completed: return "研究已完成"
        case .partial: return "研究已部分完成"
        case .failed, .unknown: return "研究失败"
        case .cancelled: return "研究已取消"
        case .created: return "研究已创建"
        case .awaitingApproval: return "研究等待授权"
        case .running: return "研究正在运行"
        }
    }

    private static func artifactReferences(
        outcome: RunOutcome,
        detail: RunDetail?
    ) -> [ConversationArtifactReference] {
        if let records = detail?.manifest["artifacts"]?.arrayValue {
            let manifestArtifacts = records.compactMap { value -> ConversationArtifactReference? in
                guard let object = value.objectValue,
                    let id = object["artifact_id"]?.stringValue,
                    let name = object["name"]?.stringValue
                else { return nil }
                let mediaType = object["media_type"]?.stringValue?.lowercased() ?? ""
                let lowerName = name.lowercased()
                let kind: ArtifactKind
                if lowerName == "report.md" || mediaType == "application/pdf" {
                    kind = .report
                } else if lowerName == "manifest.json" {
                    kind = .manifest
                } else {
                    kind = .file
                }
                return try? ConversationArtifactReference(
                    id: id,
                    kind: kind,
                    title: name,
                    relativePath: name
                )
            }
            if !manifestArtifacts.isEmpty { return manifestArtifacts }
        }

        let values: [(String, ArtifactKind, String, String?)] = [
            ("report-\(outcome.runID)", .report, "研究报告", outcome.report),
            ("manifest-\(outcome.runID)", .manifest, "运行清单", outcome.manifest),
        ]
        return values.compactMap { id, kind, title, path in
            guard let path else { return nil }
            return try? ConversationArtifactReference(
                id: id,
                kind: kind,
                title: title,
                relativePath: relativePath(path, under: outcome.runDirectory)
            )
        }
    }

    private static func relativePath(_ path: String, under runDirectory: String) -> String {
        let root = URL(fileURLWithPath: runDirectory, isDirectory: true).standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if candidate.hasPrefix(prefix) {
            return String(candidate.dropFirst(prefix.count))
        }
        return URL(fileURLWithPath: candidate).lastPathComponent
    }
}
