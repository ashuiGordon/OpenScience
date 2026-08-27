#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore

    final class EventLogCursorTests: XCTestCase {
        func testConsumesOnlyCompleteNewlineTerminatedEventsAndResumesPartialLine() throws {
            let root = try makeSecurityTestDirectory("events-partial")
            defer { try? FileManager.default.removeItem(at: root) }
            let log = root.appendingPathComponent("events.jsonl")
            let first = try makeEvent(sequence: 1, previousHash: EventLogCursor.zeroHash)
            let second = try makeEvent(
                sequence: 2,
                previousHash: try XCTUnwrap(first["event_hash"]?.stringValue)
            )
            let firstLine = try EventLogCursor.canonicalData(for: first) + Data([0x0A])
            let secondData = try EventLogCursor.canonicalData(for: second)
            try (firstLine + secondData).write(to: log)
            var cursor = EventLogCursor(runID: "run-test")

            let initial = try cursor.read(from: log)

            XCTAssertEqual(initial.events.map(\.sequence), [1])
            XCTAssertEqual(initial.nextOffset, UInt64(firstLine.count))
            XCTAssertEqual(initial.issue, .partialLine(offset: UInt64(firstLine.count)))

            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x0A]))
            try handle.close()
            let resumed = try cursor.read(from: log)
            XCTAssertEqual(resumed.events.map(\.sequence), [2])
            XCTAssertNil(resumed.issue)
        }

        func testRejectsSequenceGapRunMismatchMalformedAndOversizedLines() throws {
            let root = try makeSecurityTestDirectory("events-invalid")
            defer { try? FileManager.default.removeItem(at: root) }
            let log = root.appendingPathComponent("events.jsonl")
            let first = try makeEvent(sequence: 1, previousHash: EventLogCursor.zeroHash)
            let third = try makeEvent(
                sequence: 3,
                previousHash: try XCTUnwrap(first["event_hash"]?.stringValue)
            )
            try writeEvents([first, third], to: log)
            var gapCursor = EventLogCursor(runID: "run-test")
            XCTAssertThrowsError(try gapCursor.read(from: log)) { error in
                XCTAssertEqual(error as? EventLogIssue, .sequenceGap(expected: 2, actual: 3))
            }

            let wrongRun = try makeEvent(
                sequence: 1,
                previousHash: EventLogCursor.zeroHash,
                runID: "run-other"
            )
            try writeEvents([wrongRun], to: log)
            var runCursor = EventLogCursor(runID: "run-test")
            XCTAssertThrowsError(try runCursor.read(from: log)) { error in
                XCTAssertEqual(
                    error as? EventLogIssue,
                    .runIDMismatch(expected: "run-test", actual: "run-other")
                )
            }

            try Data("{not-json}\n".utf8).write(to: log, options: .atomic)
            var malformedCursor = EventLogCursor(runID: "run-test")
            XCTAssertThrowsError(try malformedCursor.read(from: log)) { error in
                guard case .malformedLine = error as? EventLogIssue else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }

            try Data((String(repeating: "x", count: 65) + "\n").utf8).write(to: log, options: .atomic)
            var boundedCursor = EventLogCursor(runID: "run-test", maxLineBytes: 64)
            XCTAssertThrowsError(try boundedCursor.read(from: log)) { error in
                XCTAssertEqual(error as? EventLogIssue, .lineTooLarge(limit: 64))
            }
        }

        func testDetectsHashTamperingAndFileReplacement() throws {
            let root = try makeSecurityTestDirectory("events-replacement")
            defer { try? FileManager.default.removeItem(at: root) }
            let log = root.appendingPathComponent("events.jsonl")
            let first = try makeEvent(sequence: 1, previousHash: EventLogCursor.zeroHash)
            try writeEvents([first], to: log)
            var cursor = EventLogCursor(runID: "run-test")
            XCTAssertEqual(try cursor.read(from: log).events.count, 1)

            let replacement = try makeEvent(sequence: 1, previousHash: EventLogCursor.zeroHash)
            try writeEvents([replacement], to: log, atomic: true)
            XCTAssertThrowsError(try cursor.read(from: log)) { error in
                XCTAssertEqual(error as? EventLogIssue, .fileReplaced)
            }

            var tampered = first
            tampered["type"] = .string("tampered")
            try writeEvents([tampered], to: log, atomic: true)
            var tamperCursor = EventLogCursor(runID: "run-test")
            XCTAssertThrowsError(try tamperCursor.read(from: log)) { error in
                XCTAssertEqual(error as? EventLogIssue, .eventHashMismatch(sequence: 1))
            }
        }

        private func makeEvent(
            sequence: Int,
            previousHash: String,
            runID: String = "run-test"
        ) throws -> [String: JSONValue] {
            var event: [String: JSONValue] = [
                "sequence": .number(Double(sequence)),
                "event_id": .string(String(format: "evt-%06d", sequence)),
                "run_id": .string(runID),
                "type": .string("step.completed"),
                "timestamp": .string("2026-08-21T00:00:00.000000Z"),
                "step_id": .string("discover"),
                "payload": .object(["completed_steps": .array([.string("discover")])]),
                "previous_hash": .string(previousHash),
            ]
            event["event_hash"] = .string(try EventLogCursor.eventHash(for: event))
            return event
        }

        private func writeEvents(
            _ events: [[String: JSONValue]],
            to url: URL,
            atomic: Bool = false
        ) throws {
            var data = Data()
            for event in events {
                data.append(try EventLogCursor.canonicalData(for: event))
                data.append(0x0A)
            }
            try data.write(to: url, options: atomic ? .atomic : [])
        }
    }
#endif
