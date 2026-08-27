import CryptoKit
import Foundation

public struct EventLogRecord: Equatable, Sendable {
    public let sequence: Int
    public let eventID: String
    public let runID: String
    public let type: String
    public let timestamp: String
    public let stepID: String?
    public let payload: JSONValue
    public let previousHash: String
    public let eventHash: String

    public init(
        sequence: Int,
        eventID: String,
        runID: String,
        type: String,
        timestamp: String,
        stepID: String?,
        payload: JSONValue,
        previousHash: String,
        eventHash: String
    ) {
        self.sequence = sequence
        self.eventID = eventID
        self.runID = runID
        self.type = type
        self.timestamp = timestamp
        self.stepID = stepID
        self.payload = payload
        self.previousHash = previousHash
        self.eventHash = eventHash
    }
}

public enum EventLogIssue: LocalizedError, Equatable, Sendable {
    case partialLine(offset: UInt64)
    case malformedLine(offset: UInt64)
    case lineTooLarge(limit: Int)
    case fileTooLarge(limit: Int)
    case fileReplaced
    case fileTruncated
    case unsafeFile
    case sequenceGap(expected: Int, actual: Int)
    case runIDMismatch(expected: String, actual: String)
    case previousHashMismatch(sequence: Int)
    case eventHashMismatch(sequence: Int)

    public var errorDescription: String? {
        switch self {
        case let .partialLine(offset): "事件日志在字节 \(offset) 处有未完成行。"
        case let .malformedLine(offset): "事件日志在字节 \(offset) 处不是合法事件。"
        case let .lineTooLarge(limit): "事件行超过 \(limit) 字节上限。"
        case let .fileTooLarge(limit): "事件日志超过 \(limit) 字节上限。"
        case .fileReplaced: "事件日志文件已被替换。"
        case .fileTruncated: "事件日志文件已被截断。"
        case .unsafeFile: "事件日志不是安全的普通文件。"
        case let .sequenceGap(expected, actual): "事件序号应为 \(expected)，实际为 \(actual)。"
        case let .runIDMismatch(expected, actual): "事件 run_id \(actual) 不匹配 \(expected)。"
        case let .previousHashMismatch(sequence): "事件 \(sequence) 的 previous_hash 不匹配。"
        case let .eventHashMismatch(sequence): "事件 \(sequence) 的 event_hash 不匹配。"
        }
    }
}

public struct EventLogReadResult: Equatable, Sendable {
    public let events: [EventLogRecord]
    public let nextOffset: UInt64
    public let issue: EventLogIssue?

    public init(events: [EventLogRecord], nextOffset: UInt64, issue: EventLogIssue?) {
        self.events = events
        self.nextOffset = nextOffset
        self.issue = issue
    }
}

public struct EventLogCursor: Sendable {
    public static let zeroHash = String(repeating: "0", count: 64)

    public let runID: String
    public let maxLineBytes: Int
    public let maximumFileBytes: Int
    public private(set) var offset: UInt64
    public private(set) var expectedSequence: Int
    public private(set) var expectedPreviousHash: String
    private var identity: SecureFileIdentity?

    public init(
        runID: String,
        maxLineBytes: Int = 256 * 1_024,
        maximumFileBytes: Int = 64 * 1_024 * 1_024
    ) {
        self.runID = runID
        self.maxLineBytes = max(1, maxLineBytes)
        self.maximumFileBytes = max(1, maximumFileBytes)
        offset = 0
        expectedSequence = 1
        expectedPreviousHash = Self.zeroHash
    }

    public mutating func read(from url: URL) throws -> EventLogReadResult {
        let read: (data: Data, identity: SecureFileIdentity)
        do {
            read = try SecureFileAccess.readRegularFile(
                url,
                within: url.deletingLastPathComponent(),
                maximumBytes: maximumFileBytes
            )
        } catch let error as SecureFileViolation {
            if case .tooLarge = error { throw EventLogIssue.fileTooLarge(limit: maximumFileBytes) }
            throw EventLogIssue.unsafeFile
        }
        if let identity, identity != read.identity { throw EventLogIssue.fileReplaced }
        guard UInt64(read.data.count) >= offset else { throw EventLogIssue.fileTruncated }

        let start = Int(offset)
        let tail = read.data.subdata(in: start..<read.data.count)
        var lineStart = 0
        var localSequence = expectedSequence
        var localPreviousHash = expectedPreviousHash
        var records: [EventLogRecord] = []
        var consumed = 0

        while let relativeNewline = tail[lineStart...].firstIndex(of: 0x0A) {
            let lineEnd = relativeNewline
            let line = tail.subdata(in: lineStart..<lineEnd)
            guard line.count <= maxLineBytes else {
                throw EventLogIssue.lineTooLarge(limit: maxLineBytes)
            }
            let absoluteLineOffset = offset + UInt64(lineStart)
            let (record, object) = try decodeEvent(line, offset: absoluteLineOffset)
            guard record.sequence == localSequence else {
                throw EventLogIssue.sequenceGap(expected: localSequence, actual: record.sequence)
            }
            guard record.runID == runID else {
                throw EventLogIssue.runIDMismatch(expected: runID, actual: record.runID)
            }
            guard record.previousHash == localPreviousHash else {
                throw EventLogIssue.previousHashMismatch(sequence: record.sequence)
            }
            guard try Self.eventHash(for: object) == record.eventHash else {
                throw EventLogIssue.eventHashMismatch(sequence: record.sequence)
            }
            records.append(record)
            localSequence += 1
            localPreviousHash = record.eventHash
            consumed = lineEnd + 1
            lineStart = lineEnd + 1
        }

        let incompleteCount = tail.count - consumed
        if incompleteCount > maxLineBytes { throw EventLogIssue.lineTooLarge(limit: maxLineBytes) }
        let nextOffset = offset + UInt64(consumed)
        identity = read.identity
        offset = nextOffset
        expectedSequence = localSequence
        expectedPreviousHash = localPreviousHash
        let issue: EventLogIssue? = incompleteCount > 0 ? .partialLine(offset: nextOffset) : nil
        return EventLogReadResult(events: records, nextOffset: nextOffset, issue: issue)
    }

    static func eventHash(for event: [String: JSONValue]) throws -> String {
        var unhashed = event
        unhashed.removeValue(forKey: "event_hash")
        let digest = SHA256.hash(data: try canonicalData(for: unhashed))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalData(for object: [String: JSONValue]) throws -> Data {
        let foundation = object.mapValues(foundationValue)
        guard JSONSerialization.isValidJSONObject(foundation) else {
            throw EventLogIssue.malformedLine(offset: 0)
        }
        return try JSONSerialization.data(
            withJSONObject: foundation,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func decodeEvent(
        _ line: Data,
        offset: UInt64
    ) throws -> (EventLogRecord, [String: JSONValue]) {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: line)
        } catch {
            throw EventLogIssue.malformedLine(offset: offset)
        }
        guard let object = value.objectValue,
            let sequence = object["sequence"]?.intValue,
            let eventID = object["event_id"]?.stringValue,
            let eventRunID = object["run_id"]?.stringValue,
            let type = object["type"]?.stringValue,
            let timestamp = object["timestamp"]?.stringValue,
            let stepValue = object["step_id"],
            let payload = object["payload"],
            payload.objectValue != nil,
            let previousHash = object["previous_hash"]?.stringValue,
            let eventHash = object["event_hash"]?.stringValue,
            Self.isSHA256(previousHash),
            Self.isSHA256(eventHash)
        else {
            throw EventLogIssue.malformedLine(offset: offset)
        }
        let stepID: String?
        if case .null = stepValue {
            stepID = nil
        } else {
            guard let value = stepValue.stringValue else {
                throw EventLogIssue.malformedLine(offset: offset)
            }
            stepID = value
        }
        return (
            EventLogRecord(
                sequence: sequence,
                eventID: eventID,
                runID: eventRunID,
                type: type,
                timestamp: timestamp,
                stepID: stepID,
                payload: payload,
                previousHash: previousHash,
                eventHash: eventHash
            ),
            object
        )
    }

    private static func foundationValue(_ value: JSONValue) -> Any {
        switch value {
        case .null: NSNull()
        case let .bool(value): NSNumber(value: value)
        case let .number(value):
            value.rounded() == value && value >= Double(Int64.min) && value <= Double(Int64.max)
                ? NSNumber(value: Int64(value)) : NSNumber(value: value)
        case let .string(value): value
        case let .array(values): values.map(foundationValue)
        case let .object(values): values.mapValues(foundationValue)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}
