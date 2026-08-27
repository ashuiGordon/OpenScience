import CryptoKit
import Darwin
import Foundation

public struct RunRepositoryLimits: Equatable, Sendable {
    public let manifestBytes: Int
    public let reportBytes: Int
    public let recordFileBytes: Int
    public let maximumRecordsPerFile: Int
    public let artifactBytes: Int

    public init(
        manifestBytes: Int = 1 * 1_024 * 1_024,
        reportBytes: Int = 4 * 1_024 * 1_024,
        recordFileBytes: Int = 16 * 1_024 * 1_024,
        maximumRecordsPerFile: Int = 10_000,
        artifactBytes: Int = 32 * 1_024 * 1_024
    ) {
        self.manifestBytes = max(1, manifestBytes)
        self.reportBytes = max(1, reportBytes)
        self.recordFileBytes = max(1, recordFileBytes)
        self.maximumRecordsPerFile = max(1, maximumRecordsPerFile)
        self.artifactBytes = max(1, artifactBytes)
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
    case missingArtifactID(String)
    case duplicateArtifactID(String)
    case invalidArtifactMetadata(String)
    case unsupportedArtifact(String, mediaType: String)
    case hardLinkedFile(String)
    case invalidPDF(String)
    case activeArtifactContent(String)
    case artifactSizeMismatch(String, declared: Int, actual: Int)
    case artifactChecksumMismatch(String)
    case artifactChanged(String)

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
        case let .missingArtifactID(id): "manifest 不包含产物 ID：\(id)"
        case let .duplicateArtifactID(id): "manifest 包含重复产物 ID：\(id)"
        case let .invalidArtifactMetadata(id): "manifest 产物元数据无效：\(id)"
        case let .unsupportedArtifact(name, mediaType):
            "产物 \(name) 的类型不支持安全预览：\(mediaType)"
        case let .hardLinkedFile(name): "产物文件存在硬链接，已阻止预览：\(name)"
        case let .invalidPDF(name): "产物 \(name) 不是有效的受支持 PDF。"
        case let .activeArtifactContent(name): "产物 \(name) 包含不允许的主动内容。"
        case let .artifactSizeMismatch(name, declared, actual):
            "产物 \(name) 大小与 manifest 不一致（声明 \(declared)，实际 \(actual)）。"
        case let .artifactChecksumMismatch(name): "产物 \(name) 的校验和与 manifest 不一致。"
        case let .artifactChanged(id): "产物在预览校验期间发生变化：\(id)"
        }
    }
}

private struct ManifestArtifactRecord: Equatable, Sendable {
    let descriptor: RunArtifactDescriptor
    let objectPath: String
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

    /// Resolves one exact manifest-declared artifact without exposing a local file path.
    ///
    /// This is intentionally separate from the byte read. `loadPreviewArtifact` resolves the same
    /// record again and rejects metadata changes, so a UI selection can never become path authority.
    public func artifactDescriptor(
        artifactID: String,
        in item: RunListItem
    ) throws -> RunArtifactDescriptor {
        try manifestArtifact(artifactID: artifactID, in: item).descriptor
    }

    /// Loads one exact Markdown or PDF artifact into an inert in-memory representation.
    ///
    /// The manifest, run identity, artifact metadata, path components, link count, file identity,
    /// size, and checksum are freshly checked on every call. No URL or executable representation is
    /// returned to the caller.
    public func loadPreviewArtifact(
        _ expected: RunArtifactDescriptor,
        in item: RunListItem
    ) throws -> RunArtifactPreviewPayload {
        let directory = try validatedRunDirectory(item.directory)
        let record = try manifestArtifact(
            artifactID: expected.artifactID,
            in: item,
            validatedDirectory: directory
        )
        guard record.descriptor == expected else {
            throw RunRepositoryError.artifactChanged(expected.artifactID)
        }

        let kind = try previewKind(for: record.descriptor)
        guard record.descriptor.size <= limits.artifactBytes else {
            throw RunRepositoryError.fileTooLarge(
                record.descriptor.name,
                limit: limits.artifactBytes
            )
        }

        // Prefer the manifest-declared artifact name when the engine created a run-root projection
        // (for example report.md). Content-addressed object_path is an exact manifest fallback.
        let namedProjection = directory.appendingPathComponent(
            record.descriptor.name,
            isDirectory: false
        )
        let relativePath =
            pathEntryExists(namedProjection)
            ? record.descriptor.name : record.objectPath
        let data = try readPreviewArtifact(
            relativePath: relativePath,
            directory: directory,
            descriptor: record.descriptor
        )

        guard data.count == record.descriptor.size else {
            throw RunRepositoryError.artifactSizeMismatch(
                record.descriptor.name,
                declared: record.descriptor.size,
                actual: data.count
            )
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == record.descriptor.sha256 else {
            throw RunRepositoryError.artifactChecksumMismatch(record.descriptor.name)
        }

        switch kind {
        case .markdown:
            guard let text = String(data: data, encoding: .utf8) else {
                throw RunRepositoryError.invalidUTF8(record.descriptor.name)
            }
            return .markdown(text)
        case .pdf:
            guard Self.hasValidPDFEnvelope(data) else {
                throw RunRepositoryError.invalidPDF(record.descriptor.name)
            }
            guard !Self.containsActivePDFContent(data) else {
                throw RunRepositoryError.activeArtifactContent(record.descriptor.name)
            }
            return .pdf(data)
        }
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

    private enum PreviewKind {
        case markdown
        case pdf
    }

    private func manifestArtifact(
        artifactID: String,
        in item: RunListItem,
        validatedDirectory suppliedDirectory: URL? = nil
    ) throws -> ManifestArtifactRecord {
        guard Self.isSafeIdentifier(artifactID) else {
            throw RunRepositoryError.invalidArtifactMetadata("selection")
        }
        let directory = try suppliedDirectory ?? validatedRunDirectory(item.directory)
        let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
        try rejectHardLink(manifestURL, displayName: "manifest.json")
        let manifest = try decodeJSON(
            at: manifestURL,
            within: directory,
            name: "manifest.json",
            maximumBytes: limits.manifestBytes
        )
        try rejectHardLink(manifestURL, displayName: "manifest.json")
        guard manifest["run_id"]?.stringValue == item.runID,
            item.runID == directory.lastPathComponent
        else {
            throw RunRepositoryError.runIdentityMismatch
        }

        let matching = (manifest["artifacts"]?.arrayValue ?? []).filter {
            $0["artifact_id"]?.stringValue == artifactID
        }
        guard !matching.isEmpty else { throw RunRepositoryError.missingArtifactID(artifactID) }
        guard matching.count == 1 else { throw RunRepositoryError.duplicateArtifactID(artifactID) }
        return try parseArtifact(matching[0], expectedID: artifactID)
    }

    private func parseArtifact(
        _ value: JSONValue,
        expectedID: String
    ) throws -> ManifestArtifactRecord {
        guard value.objectValue != nil,
            let artifactID = value["artifact_id"]?.stringValue,
            artifactID == expectedID,
            Self.isSafeIdentifier(artifactID),
            let name = value["name"]?.stringValue,
            Self.isSafeArtifactName(name),
            let mediaType = value["media_type"]?.stringValue,
            Self.isSafeMediaType(mediaType),
            let sha256 = value["sha256"]?.stringValue?.lowercased(),
            Self.isSHA256(sha256),
            let sizeValue = value["size"],
            let size = Self.nonnegativeInt(sizeValue),
            let objectPath = value["object_path"]?.stringValue,
            Self.isSafeRelativePath(objectPath)
        else {
            throw RunRepositoryError.invalidArtifactMetadata(expectedID)
        }
        return ManifestArtifactRecord(
            descriptor: RunArtifactDescriptor(
                artifactID: artifactID,
                name: name,
                mediaType: mediaType.lowercased(),
                sha256: sha256,
                size: size
            ),
            objectPath: objectPath
        )
    }

    private func previewKind(for descriptor: RunArtifactDescriptor) throws -> PreviewKind {
        let suffix = URL(fileURLWithPath: descriptor.name).pathExtension.lowercased()
        switch (descriptor.mediaType.lowercased(), suffix) {
        case ("text/markdown", "md"), ("text/markdown", "markdown"):
            return .markdown
        case ("application/pdf", "pdf"):
            return .pdf
        default:
            throw RunRepositoryError.unsupportedArtifact(
                descriptor.name,
                mediaType: descriptor.mediaType
            )
        }
    }

    private func readPreviewArtifact(
        relativePath: String,
        directory: URL,
        descriptor: RunArtifactDescriptor
    ) throws -> Data {
        guard Self.isSafeRelativePath(relativePath) else {
            throw RunRepositoryError.invalidArtifactMetadata(descriptor.artifactID)
        }
        let url = directory.appendingPathComponent(relativePath, isDirectory: false)
        try validateArtifactPathComponents(
            relativePath,
            directory: directory,
            displayName: descriptor.name
        )
        let before: SecureFileMetadata
        do {
            before = try SecureFileAccess.regularFileMetadata(
                url,
                within: directory,
                maximumBytes: limits.artifactBytes
            )
        } catch {
            throw mapPreviewFileViolation(error, url: url, name: descriptor.name)
        }
        guard before.size == UInt64(descriptor.size) else {
            throw RunRepositoryError.artifactSizeMismatch(
                descriptor.name,
                declared: descriptor.size,
                actual: Int(clamping: before.size)
            )
        }

        let read: (data: Data, identity: SecureFileIdentity)
        do {
            read = try SecureFileAccess.readRegularFile(
                url,
                within: directory,
                maximumBytes: limits.artifactBytes
            )
        } catch {
            throw mapPreviewFileViolation(error, url: url, name: descriptor.name)
        }
        try rejectHardLink(url, displayName: descriptor.name)

        let after: SecureFileMetadata
        do {
            after = try SecureFileAccess.regularFileMetadata(
                url,
                within: directory,
                maximumBytes: limits.artifactBytes
            )
        } catch {
            throw mapPreviewFileViolation(error, url: url, name: descriptor.name)
        }
        guard before == after,
            read.identity == before.identity,
            read.data.count == Int(clamping: after.size)
        else {
            throw RunRepositoryError.artifactChanged(descriptor.artifactID)
        }
        try validateArtifactPathComponents(
            relativePath,
            directory: directory,
            displayName: descriptor.name
        )
        return read.data
    }

    private func validateArtifactPathComponents(
        _ relativePath: String,
        directory: URL,
        displayName: String
    ) throws {
        var current = directory
        let components = relativePath.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component, isDirectory: index < components.count - 1)
            var metadata = stat()
            guard lstat(current.path, &metadata) == 0 else {
                if errno == ENOENT { throw RunRepositoryError.missingFile(displayName) }
                throw RunRepositoryError.unsafeFile(displayName)
            }
            let type = metadata.st_mode & S_IFMT
            guard type != S_IFLNK else { throw RunRepositoryError.unsafeFile(displayName) }
            if index < components.count - 1 {
                guard type == S_IFDIR else { throw RunRepositoryError.unsafeFile(displayName) }
            } else {
                guard type == S_IFREG else { throw RunRepositoryError.unsafeFile(displayName) }
                guard metadata.st_nlink == 1 else {
                    throw RunRepositoryError.hardLinkedFile(displayName)
                }
            }
        }
    }

    private func rejectHardLink(_ url: URL, displayName: String) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { throw RunRepositoryError.missingFile(displayName) }
            throw RunRepositoryError.unsafeFile(displayName)
        }
        guard metadata.st_mode & S_IFMT != S_IFLNK,
            metadata.st_mode & S_IFMT == S_IFREG
        else {
            throw RunRepositoryError.unsafeFile(displayName)
        }
        guard metadata.st_nlink == 1 else {
            throw RunRepositoryError.hardLinkedFile(displayName)
        }
    }

    private func mapPreviewFileViolation(
        _ error: Error,
        url: URL,
        name: String
    ) -> RunRepositoryError {
        guard let violation = error as? SecureFileViolation else {
            return .unsafeFile(name)
        }
        switch violation {
        case .outsideRoot: return .outsideRoot(url)
        case .tooLarge: return .fileTooLarge(name, limit: limits.artifactBytes)
        case .missing: return .missingFile(name)
        case .changed: return .artifactChanged(name)
        default: return .unsafeFile(name)
        }
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255 else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isSafeArtifactName(_ value: String) -> Bool {
        guard !value.isEmpty,
            value.utf8.count <= 1_000,
            value != ".",
            value != "..",
            !value.contains("/"),
            !value.contains("\\"),
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return false
        }
        return URL(fileURLWithPath: value).lastPathComponent == value
    }

    private static func isSafeMediaType(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
            value.utf8.count <= 32_768,
            !value.hasPrefix("/"),
            !value.hasPrefix("~"),
            !value.contains("\\"),
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                ("0"..."9").contains(Character(String($0)))
                    || ("a"..."f").contains(Character(String($0)))
            }
    }

    private static func nonnegativeInt(_ value: JSONValue?) -> Int? {
        guard case let .number(number) = value,
            number.isFinite,
            number >= 0,
            number.rounded() == number,
            number <= Double(Int.max)
        else {
            return nil
        }
        return Int(exactly: number)
    }

    private static func hasValidPDFEnvelope(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(8))
        guard bytes.count == 8,
            bytes[0...4].elementsEqual([0x25, 0x50, 0x44, 0x46, 0x2D]),
            bytes[5] == 0x31 || bytes[5] == 0x32,
            bytes[6] == 0x2E,
            (0x30...0x39).contains(bytes[7])
        else {
            return false
        }
        return data.suffix(1_024).range(of: Data("%%EOF".utf8)) != nil
    }

    private static func containsActivePDFContent(_ data: Data) -> Bool {
        let forbidden = [
            "/OpenAction", "/AA", "/JavaScript", "/JS", "/Launch", "/SubmitForm",
            "/ImportData", "/GoToR", "/URI", "/EmbeddedFile", "/RichMedia", "file://",
        ]
        return forbidden.contains { data.range(of: Data($0.utf8)) != nil }
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
