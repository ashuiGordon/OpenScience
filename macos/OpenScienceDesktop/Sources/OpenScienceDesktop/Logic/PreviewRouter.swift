import Foundation
import OpenScienceCore

/// Exact typed identity for an artifact preview. Paths and URLs are intentionally not selectable.
public struct ArtifactPreviewSelection: Equatable, Hashable, Sendable {
    public let runID: String
    public let artifactID: String

    public init(runID: String, artifactID: String) {
        self.runID = runID
        self.artifactID = artifactID
    }
}

public enum ArtifactPreviewRenderingPolicy: String, Equatable, Sendable {
    case inertNativeOnly = "inert_native_only"
}

/// Path-free metadata suitable for an unsupported/invalid preview fallback.
public struct ArtifactPreviewMetadata: Equatable, Sendable {
    public let runID: String
    public let artifactID: String
    public let name: String?
    public let mediaType: String?
    public let size: Int?
    public let sha256: String?
    public let renderingPolicy: ArtifactPreviewRenderingPolicy

    public init(
        runID: String,
        artifactID: String,
        name: String? = nil,
        mediaType: String? = nil,
        size: Int? = nil,
        sha256: String? = nil,
        renderingPolicy: ArtifactPreviewRenderingPolicy = .inertNativeOnly
    ) {
        self.runID = runID
        self.artifactID = artifactID
        self.name = name
        self.mediaType = mediaType
        self.size = size
        self.sha256 = sha256
        self.renderingPolicy = renderingPolicy
    }

    /// The preview layer never exposes a local file URL as content or navigation authority.
    public var fileURL: URL? { nil }

    public var summary: String {
        let safeName = name ?? "未解析产物"
        let safeType = mediaType ?? "未知类型"
        let safeSize = size.map { "\($0) bytes" } ?? "大小未知"
        return "\(safeName) · \(safeType) · \(safeSize)"
    }
}

public enum ArtifactPreviewFallbackReason: String, Equatable, Sendable {
    case invalidSelection = "invalid_selection"
    case runNotFound = "run_not_found"
    case runAmbiguous = "run_ambiguous"
    case runInvalid = "run_invalid"
    case artifactNotFound = "artifact_not_found"
    case artifactAmbiguous = "artifact_ambiguous"
    case unsupportedType = "unsupported_type"
    case fileMissing = "file_missing"
    case oversized
    case invalidEncoding = "invalid_encoding"
    case invalidPDF = "invalid_pdf"
    case activeContent = "active_content"
    case unsafeFile = "unsafe_file"
    case integrityChanged = "integrity_changed"
    case invalidManifest = "invalid_manifest"
    case unavailable

    public var safeMessage: String {
        switch self {
        case .invalidSelection: "预览选择无效，请重新选择产物。"
        case .runNotFound: "找不到此会话引用的运行。"
        case .runAmbiguous: "运行 ID 不唯一，已阻止预览。"
        case .runInvalid: "运行结构未通过校验，已阻止预览。"
        case .artifactNotFound: "manifest 中找不到该产物。"
        case .artifactAmbiguous: "manifest 中的产物 ID 不唯一。"
        case .unsupportedType: "此产物类型不支持安全内嵌预览。"
        case .fileMissing: "产物文件缺失。"
        case .oversized: "产物超过安全预览大小上限。"
        case .invalidEncoding: "Markdown 不是严格 UTF-8。"
        case .invalidPDF: "PDF 文件头或结尾无效。"
        case .activeContent: "产物包含主动内容，已切换为元数据预览。"
        case .unsafeFile: "产物路径或文件类型不安全。"
        case .integrityChanged: "产物身份、大小或校验和已变化。"
        case .invalidManifest: "manifest 产物元数据无效。"
        case .unavailable: "暂时无法安全预览此产物。"
        }
    }
}

/// An in-memory, inert preview or a metadata-only fallback. No variant carries a URL, HTML view,
/// executable action, or persisted validation grant.
public enum ArtifactPreviewResolution: Equatable, Sendable {
    case markdown(metadata: ArtifactPreviewMetadata, text: String)
    case pdf(metadata: ArtifactPreviewMetadata, data: Data)
    case metadata(ArtifactPreviewMetadata, reason: ArtifactPreviewFallbackReason)
}

public struct PreviewRouter: Sendable {
    private let repository: RunRepository

    /// A configured managed root is mandatory so a run reference can never authorize an arbitrary
    /// directory supplied by a conversation envelope.
    public init(root: URL, limits: RunRepositoryLimits = RunRepositoryLimits()) {
        repository = RunRepository(root: root, limits: limits)
    }

    public func resolveArtifact(
        _ selection: ArtifactPreviewSelection,
        from runs: [RunListItem]
    ) -> ArtifactPreviewResolution {
        let safeRunID =
            Self.isSafeIdentifier(selection.runID)
            ? selection.runID : "invalid-run-selection"
        let safeArtifactID =
            Self.isSafeIdentifier(selection.artifactID)
            ? selection.artifactID : "invalid-artifact-selection"
        var metadata = ArtifactPreviewMetadata(runID: safeRunID, artifactID: safeArtifactID)
        guard safeRunID == selection.runID, safeArtifactID == selection.artifactID else {
            return .metadata(metadata, reason: .invalidSelection)
        }

        let matchingRuns = runs.filter { $0.runID == selection.runID }
        guard !matchingRuns.isEmpty else {
            return .metadata(metadata, reason: .runNotFound)
        }
        guard matchingRuns.count == 1 else {
            return .metadata(metadata, reason: .runAmbiguous)
        }
        let run = matchingRuns[0]
        guard run.structuralIssue == nil else {
            return .metadata(metadata, reason: .runInvalid)
        }

        let descriptor: RunArtifactDescriptor
        do {
            descriptor = try repository.artifactDescriptor(
                artifactID: selection.artifactID,
                in: run
            )
            metadata = ArtifactPreviewMetadata(
                runID: run.runID,
                artifactID: descriptor.artifactID,
                name: descriptor.name,
                mediaType: descriptor.mediaType,
                size: descriptor.size,
                sha256: descriptor.sha256
            )
        } catch {
            return .metadata(metadata, reason: Self.fallbackReason(for: error))
        }

        do {
            switch try repository.loadPreviewArtifact(descriptor, in: run) {
            case let .markdown(text): return .markdown(metadata: metadata, text: text)
            case let .pdf(data): return .pdf(metadata: metadata, data: data)
            }
        } catch {
            return .metadata(metadata, reason: Self.fallbackReason(for: error))
        }
    }

    private static func fallbackReason(for error: Error) -> ArtifactPreviewFallbackReason {
        guard let repositoryError = error as? RunRepositoryError else { return .unavailable }
        switch repositoryError {
        case .missingArtifactID: return .artifactNotFound
        case .duplicateArtifactID: return .artifactAmbiguous
        case .unsupportedArtifact: return .unsupportedType
        case .missingFile: return .fileMissing
        case .fileTooLarge: return .oversized
        case .invalidUTF8: return .invalidEncoding
        case .invalidPDF: return .invalidPDF
        case .activeArtifactContent: return .activeContent
        case .outsideRoot, .unsafeFile, .hardLinkedFile: return .unsafeFile
        case .artifactSizeMismatch, .artifactChecksumMismatch, .artifactChanged:
            return .integrityChanged
        case .invalidArtifactMetadata, .malformedJSON, .runIdentityMismatch:
            return .invalidManifest
        default: return .unavailable
        }
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255 else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
