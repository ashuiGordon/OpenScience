import Foundation
import OpenScienceCore
import OpenScienceDesktopLogic
import Security

@MainActor
final class ClientSettings: ObservableObject {
    private enum Key {
        static let cli = "client.cliExecutable"
        static let working = "client.workingDirectory"
        static let runs = "client.runRoot"
        static let modelConfig = "client.modelConfig"
        static let modelEnvironment = "client.modelKeyEnvironment"
    }

    @Published var cliExecutablePath: String { didSet { save(Key.cli, cliExecutablePath) } }
    @Published var workingDirectoryPath: String { didSet { save(Key.working, workingDirectoryPath) } }
    @Published var runRootPath: String { didSet { save(Key.runs, runRootPath) } }
    @Published var modelConfigPath: String { didSet { save(Key.modelConfig, modelConfigPath) } }
    @Published var modelKeyEnvironment: String { didSet { save(Key.modelEnvironment, modelKeyEnvironment) } }

    private let defaults: UserDefaults
    private let keychain = KeychainStore()
    private let keychainService = "org.openscience.desktop"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let home = FileManager.default.homeDirectoryForCurrentUser
        cliExecutablePath = defaults.string(forKey: Key.cli) ?? "/opt/homebrew/bin/openscience"
        workingDirectoryPath = defaults.string(forKey: Key.working) ?? home.path
        runRootPath =
            defaults.string(forKey: Key.runs)
            ?? home.appendingPathComponent("Documents/OpenScience/Runs", isDirectory: true).path
        modelConfigPath = defaults.string(forKey: Key.modelConfig) ?? ""
        modelKeyEnvironment =
            defaults.string(forKey: Key.modelEnvironment)
            ?? "OPENSCIENCE_MODEL_API_KEY"
    }

    func configuration(engine: ResolvedEngine?) -> ClientConfiguration {
        ClientConfiguration(
            cliExecutable: engine?.executableURL ?? URL(fileURLWithPath: cliExecutablePath),
            workingDirectory: URL(fileURLWithPath: workingDirectoryPath, isDirectory: true),
            runRoot: URL(fileURLWithPath: runRootPath, isDirectory: true),
            modelConfig: modelConfigPath.isEmpty ? nil : URL(fileURLWithPath: modelConfigPath),
            modelKeyEnvironment: "OPENSCIENCE_MODEL_API_KEY",
            expectedExecutableIdentity: engine?.identity
        )
    }

    func credentials(for draft: ResearchDraft) throws -> CredentialSet {
        try CredentialSet(
            modelAPIKey: draft.useNetworkModel ? keychain.read(.modelAPIKey) : nil,
            openAlexAPIKey: draft.sourceNames.contains("openalex")
                ? keychain.read(.openAlexAPIKey) : nil,
            crossrefAPIKey: draft.sourceNames.contains("crossref")
                ? keychain.read(.crossrefAPIKey) : nil
        )
    }

    func writeSecret(_ value: String, kind: SecretKind) throws { try keychain.write(value, for: kind) }

    func hasSecret(_ kind: SecretKind) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: kind.rawValue,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    func hasCredential(_ requirement: DesktopCredentialRequirement) -> Bool {
        switch requirement {
        case .model: return hasSecret(.modelAPIKey)
        case .openAlex: return hasSecret(.openAlexAPIKey)
        case .crossref: return hasSecret(.crossrefAPIKey)
        }
    }

    func removeSecret(_ kind: SecretKind) throws { try keychain.delete(kind) }

    private func save(_ key: String, _ value: String) { defaults.set(value, forKey: key) }
}
