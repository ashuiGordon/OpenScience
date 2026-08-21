import Foundation

public enum ExternalURLPolicyError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case unsupportedScheme
    case missingHost
    case embeddedCredentials

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "外部链接无效。"
        case .unsupportedScheme: "只允许打开 HTTP 或 HTTPS 外部链接。"
        case .missingHost: "外部链接缺少主机名。"
        case .embeddedCredentials: "外部链接不得包含用户名或密码。"
        }
    }
}

public enum ExternalURLPolicy {
    public static func validate(_ value: String) throws -> URL {
        guard !value.isEmpty,
            value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
            let url = URL(string: value)
        else {
            throw ExternalURLPolicyError.invalidURL
        }
        return try validate(url)
    }

    public static func validate(_ url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw ExternalURLPolicyError.unsupportedScheme
        }
        guard let host = url.host, !host.isEmpty else { throw ExternalURLPolicyError.missingHost }
        guard url.user == nil, url.password == nil else {
            throw ExternalURLPolicyError.embeddedCredentials
        }
        return url
    }
}
