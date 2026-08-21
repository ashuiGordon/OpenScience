import CryptoKit
import Darwin
import Foundation

public struct ExecutableIdentity: Equatable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let sha256: String

    public init(device: UInt64, inode: UInt64, size: UInt64, sha256: String) {
        self.device = device
        self.inode = inode
        self.size = size
        self.sha256 = sha256
    }
}

func executableIdentity(at url: URL) throws -> ExecutableIdentity {
    guard url.isFileURL, url.path.hasPrefix("/"),
        FileManager.default.isExecutableFile(atPath: url.path)
    else {
        throw EngineResolutionError.unsafeExecutable(url)
    }
    let read: (data: Data, identity: SecureFileIdentity)
    do {
        read = try SecureFileAccess.readRegularFile(
            url,
            within: url.deletingLastPathComponent(),
            maximumBytes: 256 * 1_024 * 1_024
        )
    } catch {
        throw EngineResolutionError.unsafeExecutable(url)
    }
    let digest = SHA256.hash(data: read.data).map { String(format: "%02x", $0) }.joined()
    return ExecutableIdentity(
        device: read.identity.device,
        inode: read.identity.inode,
        size: UInt64(read.data.count),
        sha256: digest
    )
}

public struct EngineVersion: Equatable, Hashable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

public enum EngineSource: String, Equatable, Sendable {
    case bundled
    case explicitDevelopment
}

public struct ResolvedEngine: Equatable, Sendable {
    public let executableURL: URL
    public let version: EngineVersion
    public let source: EngineSource
    public let identity: ExecutableIdentity

    public init(
        executableURL: URL,
        version: EngineVersion,
        source: EngineSource,
        identity: ExecutableIdentity
    ) {
        self.executableURL = executableURL
        self.version = version
        self.source = source
        self.identity = identity
    }
}

public enum EngineResolutionError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case unsafeExecutable(URL)
    case unavailable(URL)
    case invalidVersionOutput
    case incompatibleVersion(String)
    case probeFailed(Int32)
    case timedOut
    case launchFailed
    case executableChanged

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "未找到内置 helper，也未配置显式开发引擎路径。"
        case let .unsafeExecutable(url): "引擎路径不是安全的普通可执行文件：\(url.path)"
        case let .unavailable(url): "引擎不可用：\(url.path)"
        case .invalidVersionOutput: "引擎 --version 输出不符合严格协议。"
        case let .incompatibleVersion(version): "引擎版本 \(version) 与客户端要求的 0.1.x 不兼容。"
        case let .probeFailed(code): "引擎版本探测失败，退出码 \(code)。"
        case .timedOut: "引擎版本探测超时。"
        case .launchFailed: "无法启动配置的引擎。"
        case .executableChanged: "引擎在版本探测期间被替换。"
        }
    }
}

public struct EngineResolver: Sendable {
    public let bundleURL: URL
    public let explicitDevelopmentURL: URL?
    public let timeout: TimeInterval

    public init(
        bundleURL: URL = Bundle.main.bundleURL,
        explicitDevelopmentURL: URL? = nil,
        timeout: TimeInterval = 5
    ) {
        self.bundleURL = bundleURL
        self.explicitDevelopmentURL = explicitDevelopmentURL
        self.timeout = timeout
    }

    public func resolve() async throws -> ResolvedEngine {
        guard timeout.isFinite, timeout > 0 else { throw EngineResolutionError.timedOut }
        let bundled = bundleURL.appendingPathComponent(
            "Contents/Helpers/openscience",
            isDirectory: false
        )
        if pathEntryExists(bundled) {
            return try await probe(bundled, source: .bundled)
        }
        guard let explicitDevelopmentURL else { throw EngineResolutionError.notConfigured }
        return try await probe(explicitDevelopmentURL, source: .explicitDevelopment)
    }

    private func probe(_ candidate: URL, source: EngineSource) async throws -> ResolvedEngine {
        let executable = try validatedExecutable(candidate)
        let identity = try executableIdentity(at: executable)
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        process.environment = CLIEnvironmentBuilder.sanitized(
            host: ProcessInfo.processInfo.environment,
            explicit: [:]
        )

        let termination: BoundedProcessTermination
        do {
            termination = try await BoundedProcess.run(process, timeout: timeout) {
                try? output.fileHandleForWriting.close()
                try? error.fileHandleForWriting.close()
            }
        } catch {
            throw EngineResolutionError.launchFailed
        }
        let outputData = BoundedProcess.drainAvailable(
            from: output.fileHandleForReading,
            maximumBytes: 4_097
        )
        let errorData = BoundedProcess.drainAvailable(
            from: error.fileHandleForReading,
            maximumBytes: 4_097
        )
        try? output.fileHandleForReading.close()
        try? error.fileHandleForReading.close()
        if termination.timedOut { throw EngineResolutionError.timedOut }
        guard termination.exitCode == 0 else {
            throw EngineResolutionError.probeFailed(termination.exitCode)
        }
        guard (try? executableIdentity(at: executable)) == identity else {
            throw EngineResolutionError.executableChanged
        }
        guard outputData.count <= 4_096, errorData.count <= 4_096,
            let outputText = String(data: outputData, encoding: .utf8),
            String(data: errorData, encoding: .utf8) != nil
        else {
            throw EngineResolutionError.invalidVersionOutput
        }
        let rendered = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rendered.split(whereSeparator: \.isNewline).count == 1,
            let version = parseVersion(rendered)
        else {
            throw EngineResolutionError.invalidVersionOutput
        }
        guard version.major == 0, version.minor == 1 else {
            throw EngineResolutionError.incompatibleVersion(rendered)
        }
        return ResolvedEngine(
            executableURL: executable,
            version: version,
            source: source,
            identity: identity
        )
    }

    private func validatedExecutable(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw EngineResolutionError.unsafeExecutable(url)
        }
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw EngineResolutionError.unavailable(url) }
        guard status.st_mode & S_IFMT == S_IFREG,
            status.st_mode & S_IFMT != S_IFLNK,
            FileManager.default.isExecutableFile(atPath: url.path)
        else {
            throw EngineResolutionError.unsafeExecutable(url)
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func pathEntryExists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    private func parseVersion(_ value: String) -> EngineVersion? {
        let pattern = #"^openscience ([0-9]+)\.([0-9]+)\.([0-9]+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
            ),
            match.range == NSRange(value.startIndex..., in: value),
            let majorRange = Range(match.range(at: 1), in: value),
            let minorRange = Range(match.range(at: 2), in: value),
            let patchRange = Range(match.range(at: 3), in: value),
            let major = Int(value[majorRange]),
            let minor = Int(value[minorRange]),
            let patch = Int(value[patchRange])
        else {
            return nil
        }
        return EngineVersion(major: major, minor: minor, patch: patch)
    }
}
