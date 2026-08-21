import Darwin
import Foundation

public enum CLIStream: String, Sendable { case stdout, stderr }

public struct CLIExecutionResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let json: JSONValue?
    public let startedAt: Date
    public let finishedAt: Date

    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        json: JSONValue?,
        startedAt: Date,
        finishedAt: Date
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.json = json
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public struct CLIExecutionFailure: LocalizedError, Equatable, Sendable {
    public let exitCode: Int32
    public let message: String
    public let code: String?

    public init(exitCode: Int32, message: String, code: String?) {
        self.exitCode = exitCode
        self.message = message
        self.code = code
    }

    public var errorDescription: String? {
        if let code { return "\(message) (\(code), exit \(exitCode))" }
        return "\(message) (exit \(exitCode))"
    }
}

public struct CLIOutputLimitExceeded: LocalizedError, Equatable, Sendable {
    public let stream: CLIStream
    public let limit: Int

    public init(stream: CLIStream, limit: Int) {
        self.stream = stream
        self.limit = limit
    }

    public var errorDescription: String? {
        "CLI \(stream.rawValue) 超过 \(limit) 字节安全上限，进程已终止。"
    }
}

public enum CLIProtocolError: LocalizedError, Equatable, Sendable {
    case invalidUTF8(CLIStream)
    case invalidJSON
    case topLevelNotObject
    case responseShape(String)
    case timedOut
    case unsafeInvocation
    case executableIdentityMismatch

    public var errorDescription: String? {
        switch self {
        case let .invalidUTF8(stream): "CLI \(stream.rawValue) 不是严格 UTF-8。"
        case .invalidJSON: "CLI stdout 必须恰好包含一个 JSON 值。"
        case .topLevelNotObject: "CLI stdout 顶层必须是一个 JSON object。"
        case let .responseShape(message): "CLI 响应与命令契约不匹配：\(message)"
        case .timedOut: "CLI 超过客户端进程时限并已终止。"
        case .unsafeInvocation: "CLI 可执行文件或工作目录不安全。"
        case .executableIdentityMismatch: "CLI 可执行文件身份与已探测引擎不匹配。"
        }
    }
}

public enum CLIEnvironmentBuilder {
    /// Avoid forwarding PATH, loader controls, unrelated credentials, or provider-extension state.
    public static func sanitized(
        host: [String: String],
        explicit: [String: String]
    ) -> [String: String] {
        let inherited = Set(["HOME", "TMPDIR", "LANG"])
        var result = host.filter { inherited.contains($0.key) || $0.key.hasPrefix("LC_") }
        for (key, value) in explicit where isAllowedExplicitKey(key) {
            result[key] = value
        }
        result["PYTHONDONTWRITEBYTECODE"] = "1"
        return result
    }

    static func isAllowedExplicitKey(_ key: String) -> Bool {
        guard key.hasPrefix("OPENSCIENCE_"), key.hasSuffix("_API_KEY"), key.utf8.count <= 128 else {
            return false
        }
        return key.utf8.allSatisfy {
            (65...90).contains($0) || (48...57).contains($0) || $0 == 95
        }
    }
}

private final class LockedStreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var value = Data()
    private(set) var overflowed = false

    init(limit: Int) { self.limit = limit }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !overflowed else { return }
        guard data.count <= limit, value.count <= limit - data.count else {
            overflowed = true
            return
        }
        value.append(data)
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class CLILaunchMaterial: @unchecked Sendable {
    private let lock = NSLock()
    private var launchEnvironment: [String: String]
    private var redactionTokens: [String]

    init(explicit: [String: String]) {
        launchEnvironment = CLIEnvironmentBuilder.sanitized(
            host: ProcessInfo.processInfo.environment,
            explicit: explicit
        )
        redactionTokens = Array(explicit.values)
    }

    func environmentSnapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return launchEnvironment
    }

    func redactionSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return redactionTokens
    }

    func clearLaunchEnvironment() {
        lock.lock()
        launchEnvironment.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func clearAll() {
        lock.lock()
        launchEnvironment.removeAll(keepingCapacity: false)
        redactionTokens.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

private final class ExecutableIdentityCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var mismatch = false

    func markMismatch() {
        lock.lock()
        mismatch = true
        lock.unlock()
    }

    var hasMismatch: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mismatch
    }
}

private final class SpawnedPIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: pid_t?

    func set(_ pid: pid_t) {
        lock.lock()
        storage = pid
        lock.unlock()
    }

    var pid: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func terminateAfterGrace(_ pid: pid_t) {
    Darwin.kill(pid, SIGTERM)
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
        Darwin.kill(pid, SIGKILL)
    }
}

private func spawnCLI(
    invocation: CLIInvocation,
    environment: [String: String],
    output: Pipe,
    error: Pipe
) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw CLIProtocolError.unsafeInvocation }
    defer { posix_spawn_file_actions_destroy(&actions) }
    let input = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
    guard input >= 0 else { throw CLIProtocolError.unsafeInvocation }
    defer { Darwin.close(input) }
    let changeDirectoryResult: Int32
    if #available(macOS 26.0, *) {
        changeDirectoryResult = posix_spawn_file_actions_addchdir(
            &actions,
            invocation.workingDirectory.path
        )
    } else {
        changeDirectoryResult = posix_spawn_file_actions_addchdir_np(
            &actions,
            invocation.workingDirectory.path
        )
    }
    guard posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO) == 0,
        posix_spawn_file_actions_adddup2(
            &actions,
            output.fileHandleForWriting.fileDescriptor,
            STDOUT_FILENO
        ) == 0,
        posix_spawn_file_actions_adddup2(
            &actions,
            error.fileHandleForWriting.fileDescriptor,
            STDERR_FILENO
        ) == 0,
        posix_spawn_file_actions_addclose(&actions, output.fileHandleForReading.fileDescriptor) == 0,
        posix_spawn_file_actions_addclose(&actions, error.fileHandleForReading.fileDescriptor) == 0,
        changeDirectoryResult == 0
    else {
        throw CLIProtocolError.unsafeInvocation
    }

    var arguments = ([invocation.executableURL.path] + invocation.arguments).map { strdup($0) }
    arguments.append(nil)
    defer { for pointer in arguments where pointer != nil { free(pointer) } }
    var environmentValues = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
    environmentValues.append(nil)
    defer { for pointer in environmentValues where pointer != nil { free(pointer) } }

    var pid: pid_t = 0
    let result = posix_spawn(
        &pid,
        invocation.executableURL.path,
        &actions,
        nil,
        &arguments,
        &environmentValues
    )
    guard result == 0 else { throw CLIProtocolError.unsafeInvocation }
    return pid
}

private enum CLICommandKind {
    case plan, run, resume, validate, providers, inspect, replay, cancel, export, generic

    init(arguments: [String]) {
        switch arguments.first {
        case "plan": self = .plan
        case "run": self = .run
        case "resume": self = .resume
        case "validate": self = .validate
        case "providers": self = .providers
        case "inspect": self = .inspect
        case "replay": self = .replay
        case "cancel": self = .cancel
        case "export": self = .export
        default: self = .generic
        }
    }
}

/// Runs exactly one bounded CLI process at a time without invoking a shell.
public actor OpenScienceCLIClient {
    private var currentPID: pid_t?
    private let stdoutLimit: Int
    private let stderrLimit: Int
    private let timeout: TimeInterval

    public init(
        stdoutLimit: Int = 1_024 * 1_024,
        stderrLimit: Int = 256 * 1_024,
        timeout: TimeInterval = 900
    ) {
        self.stdoutLimit = max(1, stdoutLimit)
        self.stderrLimit = max(1, stderrLimit)
        self.timeout = timeout.isFinite && timeout > 0 ? timeout : 900
    }

    nonisolated var stdoutLimitForTesting: Int { stdoutLimit }
    nonisolated var stderrLimitForTesting: Int { stderrLimit }

    public var hasActiveProcess: Bool { currentPID != nil }

    public func execute(
        _ invocation: CLIInvocation,
        onOutput: (@Sendable (CLIStream, String) -> Void)? = nil
    ) async throws -> CLIExecutionResult {
        guard currentPID == nil else {
            throw CLIExecutionFailure(exitCode: -1, message: "已有 CLI 任务正在运行。", code: "client.busy")
        }
        let launchIdentity = try validate(invocation)

        var consumedEnvironment = invocation.consumeEnvironment()
        let launchMaterial = CLILaunchMaterial(explicit: consumedEnvironment)
        consumedEnvironment.removeAll(keepingCapacity: false)
        let identityCheck = ExecutableIdentityCheck()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputData = LockedStreamCollector(limit: stdoutLimit)
        let errorData = LockedStreamCollector(limit: stderrLimit)
        let startedAt = Date()
        let pidBox = SpawnedPIDBox()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputData.append(data)
            if outputData.overflowed, let pid = pidBox.pid { terminateAfterGrace(pid) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            errorData.append(data)
            if errorData.overflowed, let pid = pidBox.pid { terminateAfterGrace(pid) }
        }

        defer {
            launchMaterial.clearAll()
            cleanup(output: outputPipe, error: errorPipe)
            currentPID = nil
        }

        let pid = try spawnCLI(
            invocation: invocation,
            environment: launchMaterial.environmentSnapshot(),
            output: outputPipe,
            error: errorPipe
        )
        launchMaterial.clearLaunchEnvironment()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        pidBox.set(pid)
        currentPID = pid
        if (try? executableIdentity(at: invocation.executableURL)) != launchIdentity {
            identityCheck.markMismatch()
            terminateAfterGrace(pid)
        }

        let termination = await withTaskCancellationHandler(
            operation: {
                await BoundedPIDProcess.wait(pid: pid, timeout: invocation.timeout ?? timeout)
            },
            onCancel: {
                terminateAfterGrace(pid)
            }
        )

        guard !identityCheck.hasMismatch,
            (try? executableIdentity(at: invocation.executableURL)) == launchIdentity
        else {
            throw CLIProtocolError.executableIdentityMismatch
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        outputData.append(
            BoundedProcess.drainAvailable(
                from: outputPipe.fileHandleForReading,
                maximumBytes: stdoutLimit + 1
            ))
        errorData.append(
            BoundedProcess.drainAvailable(
                from: errorPipe.fileHandleForReading,
                maximumBytes: stderrLimit + 1
            ))

        if termination.timedOut { throw CLIProtocolError.timedOut }
        if outputData.overflowed {
            throw CLIOutputLimitExceeded(stream: .stdout, limit: stdoutLimit)
        }
        if errorData.overflowed {
            throw CLIOutputLimitExceeded(stream: .stderr, limit: stderrLimit)
        }

        guard let rawStdout = String(data: outputData.snapshot(), encoding: .utf8) else {
            throw CLIProtocolError.invalidUTF8(.stdout)
        }
        guard let rawStderr = String(data: errorData.snapshot(), encoding: .utf8) else {
            throw CLIProtocolError.invalidUTF8(.stderr)
        }
        _ = try CLIResponseDecoder.decodeJSON(from: rawStdout)

        var redactionTokens = launchMaterial.redactionSnapshot()
        let stdout = Redactor.redact(rawStdout, secrets: redactionTokens)
        let stderr = Redactor.redact(rawStderr, secrets: redactionTokens)
        redactionTokens.removeAll(keepingCapacity: false)
        launchMaterial.clearAll()
        let json = try CLIResponseDecoder.decodeJSON(from: stdout)
        emit(stdout, stream: .stdout, callback: onOutput)
        emit(stderr, stream: .stderr, callback: onOutput)

        try validateResponse(
            invocation: invocation,
            exitCode: termination.exitCode,
            stdout: stdout,
            json: json
        )
        return CLIExecutionResult(
            exitCode: termination.exitCode,
            stdout: stdout,
            stderr: stderr,
            json: json,
            startedAt: startedAt,
            finishedAt: Date()
        )
    }

    public func cancelCurrent() {
        guard let pid = currentPID else { return }
        terminateAfterGrace(pid)
    }

    private func validate(_ invocation: CLIInvocation) throws -> ExecutableIdentity {
        guard invocation.executableURL.isFileURL,
            invocation.executableURL.path.hasPrefix("/"),
            invocation.workingDirectory.isFileURL,
            invocation.workingDirectory.path.hasPrefix("/"),
            invocation.timeout == nil
                || (invocation.timeout?.isFinite == true && (invocation.timeout ?? 0) > 0)
        else {
            throw CLIProtocolError.unsafeInvocation
        }
        var executableStatus = stat()
        var directoryStatus = stat()
        guard lstat(invocation.executableURL.path, &executableStatus) == 0,
            executableStatus.st_mode & S_IFMT == S_IFREG,
            executableStatus.st_mode & S_IFMT != S_IFLNK,
            FileManager.default.isExecutableFile(atPath: invocation.executableURL.path),
            lstat(invocation.workingDirectory.path, &directoryStatus) == 0,
            directoryStatus.st_mode & S_IFMT == S_IFDIR,
            directoryStatus.st_mode & S_IFMT != S_IFLNK
        else {
            throw CLIProtocolError.unsafeInvocation
        }
        guard let identity = try? executableIdentity(at: invocation.executableURL),
            invocation.expectedExecutableIdentity == nil
                || invocation.expectedExecutableIdentity == identity
        else {
            throw CLIProtocolError.executableIdentityMismatch
        }
        return identity
    }

    private func validateResponse(
        invocation: CLIInvocation,
        exitCode: Int32,
        stdout: String,
        json: JSONValue
    ) throws {
        if json["error"] != nil {
            guard exitCode != 0,
                let envelope = try? CLIResponseDecoder.decode(CLIErrorEnvelope.self, from: stdout)
            else {
                throw CLIProtocolError.responseShape("error envelope must use a non-zero exit")
            }
            throw CLIExecutionFailure(
                exitCode: exitCode,
                message: envelope.error.message,
                code: envelope.error.code
            )
        }

        switch CLICommandKind(arguments: invocation.arguments) {
        case .plan:
            guard exitCode == 0,
                (try? CLIResponseDecoder.decode(PlanEnvelope.self, from: stdout)) != nil
            else { throw CLIProtocolError.responseShape("plan") }
            try validatePlanBinding(invocation: invocation, json: json)
        case .providers:
            guard exitCode == 0,
                (try? CLIResponseDecoder.decode(ProvidersEnvelope.self, from: stdout)) != nil
            else { throw CLIProtocolError.responseShape("providers") }
        case .run, .resume:
            guard let outcome = try? CLIResponseDecoder.decode(RunOutcome.self, from: stdout) else {
                throw CLIProtocolError.responseShape("run outcome")
            }
            let validPair =
                (exitCode == 0 && ["completed", "awaiting_approval"].contains(outcome.status))
                || (exitCode == 4 && outcome.status == "partial")
                || (exitCode == 1 && ["failed", "cancelled"].contains(outcome.status))
            guard validPair else { throw CLIProtocolError.responseShape("run status/exit") }
        case .validate:
            guard let report = try? CLIResponseDecoder.decode(ValidationReport.self, from: stdout),
                (report.valid && exitCode == 0) || (!report.valid && exitCode == 1)
            else { throw CLIProtocolError.responseShape("validation status/exit") }
        case .inspect:
            guard exitCode == 0, json["summary"]?.objectValue != nil else {
                throw CLIProtocolError.responseShape("inspect")
            }
        case .replay:
            guard exitCode == 0, json["run_id"]?.stringValue != nil else {
                throw CLIProtocolError.responseShape("replay")
            }
        case .cancel:
            guard exitCode == 0, json["run_directory"]?.stringValue != nil,
                json["requested_at"]?.stringValue != nil
            else { throw CLIProtocolError.responseShape("cancel") }
            try validateCancelBinding(invocation: invocation, json: json)
        case .export:
            guard exitCode == 0,
                (try? CLIResponseDecoder.decode(ExportEnvelope.self, from: stdout)) != nil
            else {
                throw CLIProtocolError.responseShape("export")
            }
            try validateExportBinding(invocation: invocation, json: json)
        case .generic:
            guard exitCode == 0 else { throw CLIProtocolError.responseShape("generic exit") }
        }
    }

    private func validatePlanBinding(invocation: CLIInvocation, json: JSONValue) throws {
        guard let requestedPath = uniqueOption("--output", in: invocation.arguments),
            requestedPath.hasPrefix("/"),
            let returnedPath = json["output"]?.stringValue,
            returnedPath.hasPrefix("/"),
            let returnedPlan = json["plan"]?.objectValue
        else {
            throw CLIProtocolError.responseShape("plan output binding")
        }
        let requested = URL(fileURLWithPath: requestedPath).resolvingSymlinksInPath().standardizedFileURL
        let returned = URL(fileURLWithPath: returnedPath).resolvingSymlinksInPath().standardizedFileURL
        guard requested == returned else {
            throw CLIProtocolError.responseShape("plan output path")
        }
        let persisted: Data
        do {
            persisted = try SecureFileAccess.readRegularFile(
                requested,
                within: requested.deletingLastPathComponent(),
                maximumBytes: 1 * 1_024 * 1_024
            ).data
        } catch {
            throw CLIProtocolError.responseShape("persisted plan file")
        }
        guard let persistedPlan = try? JSONDecoder().decode(JSONValue.self, from: persisted),
            persistedPlan.objectValue != nil,
            persistedPlan == .object(returnedPlan)
        else {
            throw CLIProtocolError.responseShape("persisted plan content")
        }
    }

    private func validateCancelBinding(invocation: CLIInvocation, json: JSONValue) throws {
        guard invocation.arguments.count >= 2,
            invocation.arguments[1].hasPrefix("/"),
            let returnedPath = json["run_directory"]?.stringValue,
            returnedPath.hasPrefix("/"),
            let requested = try? SecureFileAccess.canonicalDirectory(
                URL(fileURLWithPath: invocation.arguments[1], isDirectory: true)
            ),
            let returned = try? SecureFileAccess.canonicalDirectory(
                URL(fileURLWithPath: returnedPath, isDirectory: true)
            ),
            requested == returned
        else {
            throw CLIProtocolError.responseShape("cancel run directory")
        }
    }

    private func validateExportBinding(invocation: CLIInvocation, json: JSONValue) throws {
        guard let requestedPath = uniqueOption("--output", in: invocation.arguments),
            requestedPath.hasPrefix("/"),
            let returnedPath = json["output"]?.stringValue,
            returnedPath.hasPrefix("/"),
            let returnedSize = json["size"]?.intValue,
            returnedSize > 0
        else {
            throw CLIProtocolError.responseShape("export output binding")
        }
        let requested = URL(fileURLWithPath: requestedPath).resolvingSymlinksInPath().standardizedFileURL
        let returned = URL(fileURLWithPath: returnedPath).resolvingSymlinksInPath().standardizedFileURL
        guard requested == returned,
            let metadata = try? SecureFileAccess.regularFileMetadata(
                requested,
                within: requested.deletingLastPathComponent(),
                maximumBytes: 2_000_000_000
            ),
            metadata.size == UInt64(returnedSize)
        else {
            throw CLIProtocolError.responseShape("export file identity/size")
        }
    }

    private func uniqueOption(_ name: String, in arguments: [String]) -> String? {
        let positions = arguments.indices.filter { arguments[$0] == name }
        guard positions.count == 1, positions[0] + 1 < arguments.count else { return nil }
        return arguments[positions[0] + 1]
    }

    private func emit(
        _ text: String,
        stream: CLIStream,
        callback: (@Sendable (CLIStream, String) -> Void)?
    ) {
        guard let callback else { return }
        for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
            callback(stream, String(line))
        }
    }

    private func cleanup(output: Pipe, error: Pipe) {
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForReading.close()
        try? error.fileHandleForWriting.close()
    }
}

public enum CLIResponseDecoder {
    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let data = Data(text.utf8)
        _ = try decodeObject(from: data)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CLIProtocolError.invalidJSON
        }
    }

    public static func decodeJSON(from text: String) throws -> JSONValue {
        try decodeObject(from: Data(text.utf8))
    }

    static func decodeObject(from data: Data) throws -> JSONValue {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw CLIProtocolError.invalidJSON
        }
        guard value.objectValue != nil else { throw CLIProtocolError.topLevelNotObject }
        return value
    }
}
