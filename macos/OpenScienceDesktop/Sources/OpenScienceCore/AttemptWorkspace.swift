import Darwin
import Foundation

public enum AttemptWorkspaceError: LocalizedError, Equatable, Sendable {
    case unsafeRoot(URL)
    case creationFailed
    case workspaceNotEmpty
    case missingRunDirectory
    case multipleRunDirectories(Int)
    case unsafeRunDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case let .unsafeRoot(url): "任务根目录不安全：\(url.path)"
        case .creationFailed: "无法创建唯一任务工作区。"
        case .workspaceNotEmpty: "新任务工作区不是空目录。"
        case .missingRunDirectory: "任务工作区中尚无唯一的 run-* 目录。"
        case let .multipleRunDirectories(count): "任务工作区包含 \(count) 个 run-* 目录。"
        case let .unsafeRunDirectory(url): "检测到不安全的运行目录：\(url.path)"
        }
    }
}

public struct AttemptWorkspace: Equatable, Sendable {
    public let jobDirectory: URL
    public let runsDirectory: URL

    public static func create(under root: URL) throws -> AttemptWorkspace {
        guard root.isFileURL, root.path.hasPrefix("/") else {
            throw AttemptWorkspaceError.unsafeRoot(root)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let canonicalRoot = try SecureFileAccess.canonicalDirectory(root)
            let jobs = canonicalRoot.appendingPathComponent("jobs", isDirectory: true)
            try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
            let canonicalJobs = try SecureFileAccess.canonicalDirectory(jobs)
            guard SecureFileAccess.contains(canonicalJobs, in: canonicalRoot) else {
                throw AttemptWorkspaceError.unsafeRoot(root)
            }

            for _ in 0..<8 {
                let job = canonicalJobs.appendingPathComponent(
                    UUID().uuidString.lowercased(),
                    isDirectory: true
                )
                do {
                    try FileManager.default.createDirectory(
                        at: job,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
                    )
                } catch CocoaError.fileWriteFileExists {
                    continue
                }
                let runs = job.appendingPathComponent("runs", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: runs,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
                )
                guard try FileManager.default.contentsOfDirectory(atPath: runs.path).isEmpty else {
                    throw AttemptWorkspaceError.workspaceNotEmpty
                }
                return AttemptWorkspace(
                    jobDirectory: job.resolvingSymlinksInPath(),
                    runsDirectory: runs.resolvingSymlinksInPath()
                )
            }
            throw AttemptWorkspaceError.creationFailed
        } catch let error as AttemptWorkspaceError {
            throw error
        } catch {
            throw AttemptWorkspaceError.creationFailed
        }
    }

    public func resolveRunDirectory() throws -> URL {
        try Self.resolveImmediateRun(in: runsDirectory)
    }

    static func resolveImmediateRun(in runsDirectory: URL) throws -> URL {
        let canonicalRuns: URL
        do {
            canonicalRuns = try SecureFileAccess.canonicalDirectory(runsDirectory)
        } catch {
            throw AttemptWorkspaceError.unsafeRoot(runsDirectory)
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: canonicalRuns,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var candidates: [URL] = []
        for child in children where child.lastPathComponent.hasPrefix("run-") {
            var status = stat()
            guard lstat(child.path, &status) == 0,
                status.st_mode & S_IFMT == S_IFDIR,
                status.st_mode & S_IFMT != S_IFLNK
            else {
                throw AttemptWorkspaceError.unsafeRunDirectory(child)
            }
            let canonicalChild = child.resolvingSymlinksInPath().standardizedFileURL
            guard SecureFileAccess.contains(canonicalChild, in: canonicalRuns),
                canonicalChild.deletingLastPathComponent() == canonicalRuns
            else {
                throw AttemptWorkspaceError.unsafeRunDirectory(child)
            }
            candidates.append(canonicalChild)
        }
        guard !candidates.isEmpty else { throw AttemptWorkspaceError.missingRunDirectory }
        guard candidates.count == 1 else {
            throw AttemptWorkspaceError.multipleRunDirectories(candidates.count)
        }
        return candidates[0]
    }
}
