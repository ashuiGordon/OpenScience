import Foundation

public enum Redactor {
    private static let assignmentPattern = try! NSRegularExpression(
        pattern:
            #"(?i)\b(api[_-]?key|authorization|token|secret|password|OPENSCIENCE_[A-Z0-9_]*KEY)\b(\s*[:=]\s*)(?:Bearer\s+)?([^\s,;\"']+)"#
    )
    private static let bearerPattern = try! NSRegularExpression(
        pattern: #"(?i)\bBearer\s+[A-Za-z0-9._~+\-/]+=*"#
    )

    public static func redact(_ text: String, secrets: [String] = []) -> String {
        var result = text
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        let range = NSRange(result.startIndex..., in: result)
        result = assignmentPattern.stringByReplacingMatches(
            in: result,
            range: range,
            withTemplate: "$1$2[REDACTED]"
        )
        let bearerRange = NSRange(result.startIndex..., in: result)
        return bearerPattern.stringByReplacingMatches(
            in: result,
            range: bearerRange,
            withTemplate: "Bearer [REDACTED]"
        )
    }
}
