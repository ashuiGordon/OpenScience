import CryptoKit
import Darwin
import Foundation
import OpenScienceCore

public struct ModelConfigSummary: Equatable, Sendable {
    public let fileURL: URL
    public let endpoint: URL
    public let origin: String
    public let model: String
    public let timeout: Double
    public let sha256: String

    public init(
        fileURL: URL,
        endpoint: URL,
        origin: String,
        model: String,
        timeout: Double = 30,
        sha256: String
    ) {
        self.fileURL = fileURL
        self.endpoint = endpoint
        self.origin = origin
        self.model = model
        self.timeout = timeout
        self.sha256 = sha256
    }
}

public enum ModelConfigInspectionError: LocalizedError, Equatable {
    case unsafeFile
    case tooLarge
    case malformed
    case credentialField(String)
    case invalidEndpoint
    case invalidModel
    case invalidKeyEnvironment
    case changedDuringRead

    public var errorDescription: String? {
        switch self {
        case .unsafeFile: return "模型配置必须是安全的普通文件，不能是符号链接。"
        case .tooLarge: return "模型配置超过 64 KiB 上限。"
        case .malformed: return "模型配置必须是合法 JSON 对象。"
        case let .credentialField(field): return "模型配置不得包含凭据字段：\(field)"
        case .invalidEndpoint: return "模型 endpoint 必须是无内嵌凭据的 HTTP(S) URL。"
        case .invalidModel: return "模型配置缺少非空 model。"
        case .invalidKeyEnvironment:
            return "模型配置 api_key_env 必须是 OPENSCIENCE_MODEL_API_KEY。"
        case .changedDuringRead: return "模型配置在读取时发生变化，请重新审阅计划。"
        }
    }
}

public enum ModelConfigInspector {
    public static let maximumBytes = 64 * 1_024

    public static func inspect(_ url: URL) throws -> ModelConfigSummary {
        let data = try readRegularFile(url)
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ModelConfigInspectionError.malformed
            }
            object = decoded
        } catch let error as ModelConfigInspectionError {
            throw error
        } catch {
            throw ModelConfigInspectionError.malformed
        }
        let forbidden = ["api_key", "apikey", "token", "secret", "password", "authorization"]
        for key in object.keys {
            let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
            if forbidden.contains(normalized) { throw ModelConfigInspectionError.credentialField(key) }
        }
        guard let endpointText = object["endpoint"] as? String,
            let endpoint = try? ExternalURLPolicy.validate(endpointText),
            let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
            let scheme = components.scheme,
            let host = components.host,
            components.query == nil,
            components.fragment == nil
        else { throw ModelConfigInspectionError.invalidEndpoint }
        guard let model = object["model"] as? String,
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ModelConfigInspectionError.invalidModel }
        if let environment = object["api_key_env"] as? String,
            environment != "OPENSCIENCE_MODEL_API_KEY"
        {
            throw ModelConfigInspectionError.invalidKeyEnvironment
        }
        if object["timeout"] is Bool { throw ModelConfigInspectionError.malformed }
        let timeout = (object["timeout"] as? NSNumber)?.doubleValue ?? 30
        guard timeout.isFinite, timeout > 0, timeout <= 300 else {
            throw ModelConfigInspectionError.malformed
        }
        let port = components.port.map { ":\($0)" } ?? ""
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ModelConfigSummary(
            fileURL: url.standardizedFileURL,
            endpoint: endpoint,
            origin: "\(scheme.lowercased())://\(host.lowercased())\(port)",
            model: model,
            timeout: timeout,
            sha256: digest
        )
    }

    private static func readRegularFile(_ url: URL) throws -> Data {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw ModelConfigInspectionError.unsafeFile
        }
        var before = stat()
        guard lstat(url.path, &before) == 0,
            before.st_mode & S_IFMT == S_IFREG,
            before.st_mode & S_IFMT != S_IFLNK
        else { throw ModelConfigInspectionError.unsafeFile }
        guard before.st_size > 0, before.st_size <= maximumBytes else {
            throw ModelConfigInspectionError.tooLarge
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ModelConfigInspectionError.unsafeFile }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
            opened.st_dev == before.st_dev,
            opened.st_ino == before.st_ino,
            opened.st_size == before.st_size
        else { throw ModelConfigInspectionError.changedDuringRead }
        var data = Data(count: Int(opened.st_size))
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            let count = data.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress?.advanced(by: offset), remaining)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ModelConfigInspectionError.changedDuringRead }
            offset += count
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
            after.st_dev == opened.st_dev,
            after.st_ino == opened.st_ino,
            after.st_size == opened.st_size
        else { throw ModelConfigInspectionError.changedDuringRead }
        return data
    }
}

public enum ReviewedModelConfiguration {
    public static func applying(
        _ summary: ModelConfigSummary,
        to configuration: ClientConfiguration
    ) -> ClientConfiguration {
        var execution = configuration
        execution.modelConfig = nil
        execution.reviewedModelEndpoint = summary.endpoint.absoluteString
        execution.reviewedModelName = summary.model
        execution.reviewedModelTimeout = summary.timeout
        return execution
    }
}
