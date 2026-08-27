import Foundation

private final class SecretEnvironmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]

    init(_ environment: [String: String]) { storage = environment }

    func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func consume() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        let value = storage
        storage.removeAll(keepingCapacity: false)
        return value
    }
}

public struct CLIInvocation: Equatable, @unchecked Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectory: URL
    public let timeout: TimeInterval?
    public let expectedExecutableIdentity: ExecutableIdentity?
    private let environmentBox: SecretEnvironmentBox

    public var environment: [String: String] { environmentBox.snapshot() }

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: URL,
        timeout: TimeInterval? = nil,
        expectedExecutableIdentity: ExecutableIdentity? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.expectedExecutableIdentity = expectedExecutableIdentity
        environmentBox = SecretEnvironmentBox(environment)
    }

    public static func == (lhs: CLIInvocation, rhs: CLIInvocation) -> Bool {
        lhs.executableURL == rhs.executableURL
            && lhs.arguments == rhs.arguments
            && lhs.workingDirectory == rhs.workingDirectory
            && lhs.timeout == rhs.timeout
            && lhs.expectedExecutableIdentity == rhs.expectedExecutableIdentity
            && lhs.environment == rhs.environment
    }

    func consumeEnvironment() -> [String: String] { environmentBox.consume() }

    /// Safe for UI logs. Secret values are never included.
    public var redactedDescription: String {
        ([executableURL.path] + arguments).map(Self.quoteForDisplay).joined(separator: " ")
    }

    private static func quoteForDisplay(_ argument: String) -> String {
        guard argument.contains(where: { $0.isWhitespace }) else { return argument }
        return "\"" + argument.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public enum CLICommandError: LocalizedError, Equatable {
    case emptyQuestion
    case noSource
    case fixtureCombinationUnsupported
    case localEvidenceWithNetworkModel
    case missingModelConfiguration
    case invalidModelKeyEnvironment
    case invalidReviewedModelConfiguration

    public var errorDescription: String? {
        switch self {
        case .emptyQuestion: return "请输入研究问题。"
        case .noSource: return "请至少选择一个来源、本地目录或 fixture。"
        case .fixtureCombinationUnsupported:
            return "当前 CLI 无法在不知道 fixture provider 名称时把 fixture 与其他来源混合使用。"
        case .localEvidenceWithNetworkModel:
            return "隐私策略禁止把本地证据发送给网络模型。请改用本地 extractive 合成器。"
        case .missingModelConfiguration: return "使用网络模型前必须选择模型配置文件。"
        case .invalidModelKeyEnvironment: return "模型密钥环境变量名称无效。"
        case .invalidReviewedModelConfiguration: return "已审阅模型 endpoint、name 或 timeout 无效或不完整。"
        }
    }
}

public enum CLICommandBuilder {
    public static func plan(
        draft: ResearchDraft,
        configuration: ClientConfiguration,
        output: URL,
        jobWorkspace: URL
    ) throws -> CLIInvocation {
        let question = draft.question.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateDraft(draft, configuration: configuration)
        var arguments = ["plan", "--json", "--output", output.path]
        appendRequestOptions(draft, workspace: jobWorkspace, to: &arguments)
        arguments += ["--", question]
        return invocation(
            arguments: arguments,
            configuration: configuration,
            credentials: CredentialSet(),
            workingDirectory: jobWorkspace
        )
    }

    public static func run(
        draft: ResearchDraft,
        configuration: ClientConfiguration,
        credentials: CredentialSet,
        jobWorkspace: URL,
        reviewedPlan: URL
    ) throws -> CLIInvocation {
        let question = draft.question.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateDraft(draft, configuration: configuration)

        var arguments = ["run", "--json", "--yes", "--plan", reviewedPlan.path]
        appendRequestOptions(draft, workspace: jobWorkspace, to: &arguments)
        try appendProviderOptions(
            draft, configuration: configuration, credentials: credentials, to: &arguments)
        // `--` prevents a question beginning with '-' from becoming an option.
        arguments += ["--", question]
        return invocation(
            arguments: arguments,
            configuration: configuration,
            credentials: requiredCredentials(for: draft, from: credentials),
            timeout: TimeInterval(draft.timeoutSeconds) + 30,
            workingDirectory: jobWorkspace
        )
    }

    public static func resume(
        runDirectory: URL,
        draft: ResearchDraft,
        configuration: ClientConfiguration,
        credentials: CredentialSet
    ) throws -> CLIInvocation {
        try enforceSynthesisPolicy(draft: draft, configuration: configuration)
        var arguments = ["resume", runDirectory.path, "--json", "--yes"]
        try appendProviderOptions(
            draft, configuration: configuration, credentials: credentials, to: &arguments)
        return invocation(
            arguments: arguments,
            configuration: configuration,
            credentials: requiredCredentials(for: draft, from: credentials),
            timeout: TimeInterval(draft.timeoutSeconds) + 30,
            workingDirectory: runDirectory
        )
    }

    public static func validate(runDirectory: URL, configuration: ClientConfiguration) -> CLIInvocation {
        return invocation(
            arguments: ["validate", runDirectory.path, "--json"],
            configuration: configuration,
            credentials: CredentialSet()
        )
    }

    public static func inspect(runDirectory: URL, configuration: ClientConfiguration) -> CLIInvocation {
        return invocation(
            arguments: ["inspect", runDirectory.path, "--json"],
            configuration: configuration,
            credentials: CredentialSet()
        )
    }

    public static func replay(runDirectory: URL, configuration: ClientConfiguration) -> CLIInvocation {
        invocation(
            arguments: ["replay", runDirectory.path, "--json"],
            configuration: configuration,
            credentials: CredentialSet()
        )
    }

    public static func cancel(runDirectory: URL, configuration: ClientConfiguration) -> CLIInvocation {
        invocation(
            arguments: ["cancel", runDirectory.path, "--json"],
            configuration: configuration,
            credentials: CredentialSet()
        )
    }

    public static func export(
        runDirectory: URL,
        output: URL,
        configuration: ClientConfiguration
    ) -> CLIInvocation {
        invocation(
            arguments: ["export", runDirectory.path, "--output", output.path, "--json"],
            configuration: configuration,
            credentials: CredentialSet()
        )
    }

    public static func providers(
        configuration: ClientConfiguration,
        fixtureFiles: [URL] = []
    ) -> CLIInvocation {
        var arguments = ["providers"]
        for fixture in fixtureFiles { arguments += ["--fixture", fixture.path] }
        arguments.append("--json")
        return invocation(
            arguments: arguments,
            configuration: configuration,
            credentials: CredentialSet()
        )
    }

    private static func appendRequestOptions(
        _ draft: ResearchDraft,
        workspace: URL,
        to arguments: inout [String]
    ) {
        if !draft.scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--scope", draft.scope]
        }
        for value in draft.constraints where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--constraint", value]
        }
        for value in draft.assumptions where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--assumption", value]
        }
        arguments += [
            "--max-records", String(draft.maxRecords),
            "--max-network-requests", String(draft.maxNetworkRequests),
            "--timeout", String(draft.timeoutSeconds),
            "--workspace", workspace.path,
        ]
    }

    private static func appendProviderOptions(
        _ draft: ResearchDraft,
        configuration: ClientConfiguration,
        credentials _: CredentialSet,
        to arguments: inout [String]
    ) throws {
        for fixture in draft.fixtureFiles { arguments += ["--fixture", fixture.path] }
        for root in draft.localRoots { arguments += ["--local-root", root.path] }
        for source in draft.sourceNames { arguments += ["--source", source] }
        // When explicit remote sources exist, CLI defaults are not used; name the local adapter too.
        if !draft.localRoots.isEmpty && !draft.sourceNames.contains("local-files") {
            arguments += ["--source", "local-files"]
        }
        if draft.allowNetwork { arguments.append("--allow-network") }
        if !draft.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--email", draft.email]
        }
        if draft.useNetworkModel, let inline = try reviewedInlineModel(configuration) {
            arguments += [
                "--model-endpoint", inline.endpoint,
                "--model-name", inline.name,
                "--model-timeout", String(inline.timeout),
                "--synthesizer", "openai-compatible",
            ]
        } else if draft.useNetworkModel, let config = configuration.modelConfig {
            arguments += ["--model-config", config.path, "--synthesizer", "openai-compatible"]
        } else {
            arguments += ["--synthesizer", "extractive"]
        }
    }

    private static func enforceSynthesisPolicy(
        draft: ResearchDraft,
        configuration: ClientConfiguration
    ) throws {
        if draft.useNetworkModel && !draft.localRoots.isEmpty {
            throw CLICommandError.localEvidenceWithNetworkModel
        }
        let inline = draft.useNetworkModel ? try reviewedInlineModel(configuration) : nil
        if draft.useNetworkModel && inline == nil && configuration.modelConfig == nil {
            throw CLICommandError.missingModelConfiguration
        }
        let name = configuration.modelKeyEnvironment
        if !CLIEnvironmentBuilder.isAllowedExplicitKey(name) {
            throw CLICommandError.invalidModelKeyEnvironment
        }
    }

    private static func reviewedInlineModel(
        _ configuration: ClientConfiguration
    ) throws -> (endpoint: String, name: String, timeout: Double)? {
        let values: [Any?] = [
            configuration.reviewedModelEndpoint,
            configuration.reviewedModelName,
            configuration.reviewedModelTimeout,
        ]
        if values.allSatisfy({ $0 == nil }) { return nil }
        guard let endpoint = configuration.reviewedModelEndpoint,
            let name = configuration.reviewedModelName,
            let timeout = configuration.reviewedModelTimeout,
            endpoint == endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            name == name.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty,
            timeout.isFinite,
            timeout > 0,
            timeout <= 300,
            let components = URLComponents(string: endpoint),
            components.scheme?.lowercased() == "https",
            components.host?.isEmpty == false,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil
        else {
            throw CLICommandError.invalidReviewedModelConfiguration
        }
        return (endpoint, name, timeout)
    }

    private static func validateDraft(
        _ draft: ResearchDraft,
        configuration: ClientConfiguration
    ) throws {
        guard !draft.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLICommandError.emptyQuestion
        }
        guard !draft.sourceNames.isEmpty || !draft.localRoots.isEmpty || !draft.fixtureFiles.isEmpty else {
            throw CLICommandError.noSource
        }
        if !draft.fixtureFiles.isEmpty && (!draft.sourceNames.isEmpty || !draft.localRoots.isEmpty) {
            throw CLICommandError.fixtureCombinationUnsupported
        }
        try enforceSynthesisPolicy(draft: draft, configuration: configuration)
    }

    private static func invocation(
        arguments: [String],
        configuration: ClientConfiguration,
        credentials: CredentialSet,
        timeout: TimeInterval? = nil,
        workingDirectory: URL? = nil
    ) -> CLIInvocation {
        var environment: [String: String] = [:]
        if let value = credentials.modelAPIKey, !value.isEmpty {
            environment[configuration.modelKeyEnvironment] = value
        }
        // Supported by the Python CLI without exposing secrets in argv/process listings.
        if let value = credentials.openAlexAPIKey, !value.isEmpty {
            environment["OPENSCIENCE_OPENALEX_API_KEY"] = value
        }
        if let value = credentials.crossrefAPIKey, !value.isEmpty {
            environment["OPENSCIENCE_CROSSREF_API_KEY"] = value
        }
        return CLIInvocation(
            executableURL: configuration.cliExecutable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory ?? configuration.workingDirectory,
            timeout: timeout,
            expectedExecutableIdentity: configuration.expectedExecutableIdentity
        )
    }

    private static func requiredCredentials(
        for draft: ResearchDraft,
        from credentials: CredentialSet
    ) -> CredentialSet {
        CredentialSet(
            modelAPIKey: draft.useNetworkModel ? credentials.modelAPIKey : nil,
            openAlexAPIKey: draft.sourceNames.contains("openalex") ? credentials.openAlexAPIKey : nil,
            crossrefAPIKey: draft.sourceNames.contains("crossref") ? credentials.crossrefAPIKey : nil
        )
    }
}
