import Darwin
import Foundation

public struct RunRepositoryLimits: Equatable, Sendable {
    public let manifestBytes: Int
    public let reportBytes: Int
    public let recordFileBytes: Int
    public let maximumRecordsPerFile: Int

    public init(
        manifestBytes: Int = 1 * 1_024 * 1_024,
        reportBytes: Int = 4 * 1_024 * 1_024,
        recordFileBytes: Int = 16 * 1_024 * 1_024,
        maximumRecordsPerFile: Int = 10_000
    ) {
        self.manifestBytes = max(1, manifestBytes)
        self.reportBytes = max(1, reportBytes)
        self.recordFileBytes = max(1, recordFileBytes)
        self.maximumRecordsPerFile = max(1, maximumRecordsPerFile)
    }
}

public enum RunRepositoryError: LocalizedError, Equatable, Sendable {
    case outsideRoot(URL)
    case unsafeFile(String)
    case missingFile(String)
    case fileTooLarge(String, limit: Int)
    case invalidUTF8(String)
    case malformedJSON(String)
    case tooManyRecords(String, limit: Int)
    case runIdentityMismatch
    case duplicateID(String)
    case missingEvidence(claimID: String, evidenceID: String)
    case missingSource(evidenceID: String, sourceID: String)
    case claimTextMismatch(claimID: String, evidenceID: String)

    public var errorDescription: String? {
        switch self {
        case let .outsideRoot(url): "运行目录越过允许根目录：\(url.path)"
        case let .unsafeFile(name): "运行文件不是安全的普通文件：\(name)"
        case let .missingFile(name): "运行文件缺失：\(name)"
        case let .fileTooLarge(name, limit): "运行文件 \(name) 超过 \(limit) 字节上限。"
        case let .invalidUTF8(name): "运行文件 \(name) 不是严格 UTF-8。"
        case let .malformedJSON(name): "运行文件 \(name) 不是合法的预期 JSON。"
        case let .tooManyRecords(name, limit): "运行文件 \(name) 超过 \(limit) 条记录上限。"
        case .runIdentityMismatch: "manifest run_id 与运行目录不匹配。"
        case let .duplicateID(id): "运行记录包含重复 ID：\(id)"
        case let .missingEvidence(claimID, evidenceID):
            "claim \(claimID) 引用了缺失 evidence \(evidenceID)。"
        case let .missingSource(evidenceID, sourceID):
            "evidence \(evidenceID) 引用了缺失 source \(sourceID)。"
        case let .claimTextMismatch(claimID, evidenceID):
            "sourced claim \(claimID) 与 evidence \(evidenceID) 的原文不一致。"
        }
    }
}

public struct ClaimEvidenceSourceLink: Equatable, Sendable {
    public let claim: ClaimRecord
    public let evidence: EvidenceRecord
    public let source: SourceRecord

    public init(claim: ClaimRecord, evidence: EvidenceRecord, source: SourceRecord) {
        self.claim = claim
        self.evidence = evidence
        self.source = source
    }
}

public struct RunScanner: Sendable {
    public let maximumDepth: Int
    public let limits: RunRepositoryLimits

    public init(maximumDepth: Int = 6, limits: RunRepositoryLimits = RunRepositoryLimits()) {
        self.maximumDepth = max(0, maximumDepth)
        self.limits = limits
    }

    public func scan(root: URL) throws -> [RunListItem] {
        let canonicalRoot: URL
        do {
            canonicalRoot = try SecureFileAccess.canonicalDirectory(root)
        } catch {
            throw RunRepositoryError.outsideRoot(root)
        }
        var result: [RunListItem] = []
        try walk(directory: canonicalRoot, root: canonicalRoot, depth: 0, into: &result)
        let duplicateIDs = Set(
            Dictionary(grouping: result.indices, by: { result[$0].runID })
                .filter { $0.value.count > 1 }
                .keys
        )
        let isolated = result.map { item in
            guard duplicateIDs.contains(item.runID) else { return item }
            return replacingIssue(
                item,
                with: RunStructuralIssue(
                    code: "duplicate_run_id",
                    message: "发现多个目录声明相同 run_id：\(item.runID)"
                )
            )
        }
        return isolated.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.runID < $1.runID
        }
    }

    /// Compatibility API: zero candidates returns nil; unsafe or multiple candidates throw.
    public func discoverActiveRun(jobWorkspace: URL) throws -> URL? {
        do {
            return try AttemptWorkspace.resolveImmediateRun(in: jobWorkspace)
        } catch AttemptWorkspaceError.missingRunDirectory {
            return nil
        }
    }

    private func walk(
        directory: URL,
        root: URL,
        depth: Int,
        into result: inout [RunListItem]
    ) throws {
        guard depth <= maximumDepth else { return }
        guard SecureFileAccess.contains(directory, in: root) else {
            throw RunRepositoryError.outsideRoot(directory)
        }
        let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
        if pathEntryExists(manifestURL) {
            do {
                result.append(try parse(directory: directory, manifestURL: manifestURL))
            } catch {
                result.append(invalidItem(directory: directory, error: error))
            }
            return
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isHiddenKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            if ["objects", ".build", ".git"].contains(child.lastPathComponent) { continue }
            var status = stat()
            guard lstat(child.path, &status) == 0 else { continue }
            if status.st_mode & S_IFMT == S_IFLNK {
                if child.lastPathComponent.hasPrefix("run-") {
                    result.append(
                        invalidItem(
                            directory: child.standardizedFileURL,
                            error: RunRepositoryError.unsafeFile("run directory symlink")
                        )
                    )
                }
                continue
            }
            guard status.st_mode & S_IFMT == S_IFDIR else { continue }
            let canonicalChild = child.resolvingSymlinksInPath().standardizedFileURL
            guard SecureFileAccess.contains(canonicalChild, in: root) else {
                throw RunRepositoryError.outsideRoot(child)
            }
            try walk(directory: canonicalChild, root: root, depth: depth + 1, into: &result)
        }
    }

    private func parse(directory: URL, manifestURL: URL) throws -> RunListItem {
        let data = try read(manifestURL, within: directory, name: "manifest.json")
        let manifest: JSONValue
        do {
            manifest = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw RunRepositoryError.malformedJSON("manifest.json")
        }
        guard manifest.objectValue != nil else {
            throw RunRepositoryError.malformedJSON("manifest.json")
        }
        guard let runID = manifest["run_id"]?.stringValue,
            runID == directory.lastPathComponent
        else {
            throw RunRepositoryError.runIdentityMismatch
        }
        let status = RunStatus(rawOrUnknown: manifest["status"]?.stringValue ?? "unknown")
        let question = manifest["request"]?["question"]?.stringValue ?? "Untitled research"
        let records = manifest["records"]
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        let updatedAt = attributes[.modificationDate] as? Date ?? .distantPast
        return RunListItem(
            runID: runID,
            directory: directory,
            question: question,
            status: status,
            updatedAt: updatedAt,
            sourceCount: records?["sources"]?["count"]?.intValue ?? 0,
            evidenceCount: records?["evidence"]?["count"]?.intValue ?? 0,
            claimCount: records?["claims"]?["count"]?.intValue ?? 0
        )
    }

    private func read(_ url: URL, within root: URL, name: String) throws -> Data {
        do {
            return try SecureFileAccess.readRegularFile(
                url,
                within: root,
                maximumBytes: limits.manifestBytes
            ).data
        } catch let error as SecureFileViolation {
            switch error {
            case .outsideRoot: throw RunRepositoryError.outsideRoot(url)
            case .tooLarge: throw RunRepositoryError.fileTooLarge(name, limit: limits.manifestBytes)
            case .missing: throw RunRepositoryError.missingFile(name)
            default: throw RunRepositoryError.unsafeFile(name)
            }
        }
    }

    private func pathEntryExists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    private func invalidItem(directory: URL, error: Error) -> RunListItem {
        let issue: RunStructuralIssue
        switch error as? RunRepositoryError {
        case .malformedJSON:
            issue = RunStructuralIssue(code: "malformed_json", message: error.localizedDescription)
        case .runIdentityMismatch:
            issue = RunStructuralIssue(code: "run_identity_mismatch", message: error.localizedDescription)
        case .outsideRoot:
            issue = RunStructuralIssue(code: "outside_root", message: error.localizedDescription)
        case .unsafeFile:
            issue = RunStructuralIssue(code: "unsafe_run_directory", message: error.localizedDescription)
        case .fileTooLarge:
            issue = RunStructuralIssue(code: "file_too_large", message: error.localizedDescription)
        default:
            issue = RunStructuralIssue(code: "invalid_run", message: error.localizedDescription)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path)
        return RunListItem(
            runID: directory.lastPathComponent,
            directory: directory,
            question: "Invalid research run",
            status: .unknown,
            updatedAt: attributes?[.modificationDate] as? Date ?? .distantPast,
            sourceCount: 0,
            evidenceCount: 0,
            claimCount: 0,
            structuralIssue: issue
        )
    }

    private func replacingIssue(_ item: RunListItem, with issue: RunStructuralIssue) -> RunListItem {
        RunListItem(
            runID: item.runID,
            directory: item.directory,
            question: item.question,
            status: item.status,
            updatedAt: item.updatedAt,
            sourceCount: item.sourceCount,
            evidenceCount: item.evidenceCount,
            claimCount: item.claimCount,
            structuralIssue: issue
        )
    }
}

public struct RunRepository: Sendable {
    public let root: URL?
    public let limits: RunRepositoryLimits

    public init(root: URL? = nil, limits: RunRepositoryLimits = RunRepositoryLimits()) {
        self.root = root
        self.limits = limits
    }

    public func load(_ item: RunListItem) throws -> RunDetail {
        let directory = try validatedRunDirectory(item.directory)
        let manifest = try decodeJSON(
            at: directory.appendingPathComponent("manifest.json"),
            within: directory,
            name: "manifest.json",
            maximumBytes: limits.manifestBytes
        )
        guard manifest["run_id"]?.stringValue == item.runID,
            item.runID == directory.lastPathComponent
        else {
            throw RunRepositoryError.runIdentityMismatch
        }
        let reportURL = directory.appendingPathComponent("report.md")
        let report: String
        if pathEntryExists(reportURL) {
            let data = try read(
                reportURL,
                within: directory,
                name: "report.md",
                maximumBytes: limits.reportBytes
            )
            guard let text = String(data: data, encoding: .utf8) else {
                throw RunRepositoryError.invalidUTF8("report.md")
            }
            report = text
        } else {
            report = "报告尚未生成。"
        }
        return RunDetail(
            item: item,
            reportMarkdown: report,
            sources: try decodeArray(
                SourceRecord.self,
                at: directory.appendingPathComponent("sources.json"),
                within: directory,
                name: "sources.json"
            ),
            evidence: try decodeArray(
                EvidenceRecord.self,
                at: directory.appendingPathComponent("evidence.json"),
                within: directory,
                name: "evidence.json"
            ),
            claims: try decodeArray(
                ClaimRecord.self,
                at: directory.appendingPathComponent("claims.json"),
                within: directory,
                name: "claims.json"
            ),
            manifest: manifest
        )
    }

    public func progress(runDirectory: URL) -> RunProgressSnapshot {
        (try? progressValidated(runDirectory: runDirectory))
            ?? RunProgressSnapshot(completedSteps: 0, totalSteps: 5, lastEvent: "事件记录不可验证")
    }

    public func progressValidated(runDirectory: URL) throws -> RunProgressSnapshot {
        let directory = try validatedRunDirectory(runDirectory)
        var cursor = EventLogCursor(runID: directory.lastPathComponent)
        let result = try cursor.read(from: directory.appendingPathComponent("events.jsonl"))
        var completed = Set<String>()
        var last = "正在初始化"
        for event in result.events {
            last = event.type
            if event.type == "step.completed", let stepID = event.stepID { completed.insert(stepID) }
        }
        return RunProgressSnapshot(
            completedSteps: completed.count,
            totalSteps: 5,
            lastEvent: last
        )
    }

    public func joinEvidence(in detail: RunDetail) throws -> [ClaimEvidenceSourceLink] {
        let sources = try unique(detail.sources, id: \.sourceID)
        let evidence = try unique(detail.evidence, id: \.evidenceID)
        _ = try unique(detail.claims, id: \.claimID)
        var result: [ClaimEvidenceSourceLink] = []
        for claim in detail.claims {
            for evidenceID in claim.evidenceIDs {
                guard let record = evidence[evidenceID] else {
                    throw RunRepositoryError.missingEvidence(
                        claimID: claim.claimID,
                        evidenceID: evidenceID
                    )
                }
                guard let source = sources[record.sourceID] else {
                    throw RunRepositoryError.missingSource(
                        evidenceID: record.evidenceID,
                        sourceID: record.sourceID
                    )
                }
                if claim.kind == "sourced_fact", claim.text != record.passage {
                    throw RunRepositoryError.claimTextMismatch(
                        claimID: claim.claimID,
                        evidenceID: record.evidenceID
                    )
                }
                result.append(ClaimEvidenceSourceLink(claim: claim, evidence: record, source: source))
            }
        }
        return result
    }

    private func validatedRunDirectory(_ url: URL) throws -> URL {
        let directory: URL
        do {
            directory = try SecureFileAccess.canonicalDirectory(url)
        } catch {
            throw RunRepositoryError.unsafeFile(url.lastPathComponent)
        }
        if let root {
            let canonicalRoot: URL
            do {
                canonicalRoot = try SecureFileAccess.canonicalDirectory(root)
            } catch {
                throw RunRepositoryError.outsideRoot(url)
            }
            guard SecureFileAccess.contains(directory, in: canonicalRoot) else {
                throw RunRepositoryError.outsideRoot(url)
            }
        }
        return directory
    }

    private func decodeArray<T: Decodable>(
        _ type: T.Type,
        at url: URL,
        within root: URL,
        name: String
    ) throws -> [T] {
        guard pathEntryExists(url) else { throw RunRepositoryError.missingFile(name) }
        let data = try read(
            url,
            within: root,
            name: name,
            maximumBytes: limits.recordFileBytes
        )
        let rawRecords: [JSONValue]
        do {
            rawRecords = try JSONDecoder().decode([JSONValue].self, from: data)
        } catch {
            throw RunRepositoryError.malformedJSON(name)
        }
        guard rawRecords.count <= limits.maximumRecordsPerFile else {
            throw RunRepositoryError.tooManyRecords(name, limit: limits.maximumRecordsPerFile)
        }
        let result: [T]
        do {
            result = try JSONDecoder().decode([T].self, from: data)
        } catch {
            throw RunRepositoryError.malformedJSON(name)
        }
        return result
    }

    private func decodeJSON(
        at url: URL,
        within root: URL,
        name: String,
        maximumBytes: Int
    ) throws -> JSONValue {
        let data = try read(url, within: root, name: name, maximumBytes: maximumBytes)
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            guard value.objectValue != nil else { throw RunRepositoryError.malformedJSON(name) }
            return value
        } catch let error as RunRepositoryError {
            throw error
        } catch {
            throw RunRepositoryError.malformedJSON(name)
        }
    }

    private func read(
        _ url: URL,
        within root: URL,
        name: String,
        maximumBytes: Int
    ) throws -> Data {
        do {
            return try SecureFileAccess.readRegularFile(
                url,
                within: root,
                maximumBytes: maximumBytes
            ).data
        } catch let error as SecureFileViolation {
            switch error {
            case .outsideRoot: throw RunRepositoryError.outsideRoot(url)
            case .tooLarge: throw RunRepositoryError.fileTooLarge(name, limit: maximumBytes)
            case .missing: throw RunRepositoryError.missingFile(name)
            default: throw RunRepositoryError.unsafeFile(name)
            }
        }
    }

    private func unique<T>(_ values: [T], id: KeyPath<T, String>) throws -> [String: T] {
        var result: [String: T] = [:]
        for value in values {
            let key = value[keyPath: id]
            guard result.updateValue(value, forKey: key) == nil else {
                throw RunRepositoryError.duplicateID(key)
            }
        }
        return result
    }

    private func pathEntryExists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }
}
