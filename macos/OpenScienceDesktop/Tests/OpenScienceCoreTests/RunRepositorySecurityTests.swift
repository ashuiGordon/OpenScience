#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore

    final class RunRepositorySecurityTests: XCTestCase {
        func testRejectsRunOutsideConfiguredRootAndSymlinkedProjection() throws {
            let root = try makeSecurityTestDirectory("repository-root")
            defer { try? FileManager.default.removeItem(at: root) }
            let allowed = root.appendingPathComponent("allowed", isDirectory: true)
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let outsideItem = try makeRun(in: outside, runID: "run-outside")
            let repository = RunRepository(root: allowed)

            XCTAssertThrowsError(try repository.load(outsideItem)) { error in
                guard case .outsideRoot = error as? RunRepositoryError else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }

            let allowedItem = try makeRun(in: allowed, runID: "run-allowed")
            let source = allowedItem.directory.appendingPathComponent("sources.json")
            try FileManager.default.removeItem(at: source)
            try FileManager.default.createSymbolicLink(
                at: source,
                withDestinationURL: outside.appendingPathComponent("sources.json")
            )
            XCTAssertThrowsError(try repository.load(allowedItem)) { error in
                guard case .unsafeFile = error as? RunRepositoryError else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }

        func testEnforcesReportProjectionAndRecordCountLimits() throws {
            let root = try makeSecurityTestDirectory("repository-limits")
            defer { try? FileManager.default.removeItem(at: root) }
            let item = try makeRun(in: root, runID: "run-limits")
            let report = item.directory.appendingPathComponent("report.md")
            try Data(repeating: 0x61, count: 65).write(to: report)
            let reportBounded = RunRepository(
                root: root,
                limits: RunRepositoryLimits(
                    manifestBytes: 1_024,
                    reportBytes: 64,
                    recordFileBytes: 1_024,
                    maximumRecordsPerFile: 10
                )
            )
            XCTAssertThrowsError(try reportBounded.load(item)) { error in
                XCTAssertEqual(error as? RunRepositoryError, .fileTooLarge("report.md", limit: 64))
            }

            try Data("ok".utf8).write(to: report)
            try Data("[{},{}]".utf8).write(to: item.directory.appendingPathComponent("sources.json"))
            let countBounded = RunRepository(
                root: root,
                limits: RunRepositoryLimits(
                    manifestBytes: 1_024,
                    reportBytes: 64,
                    recordFileBytes: 1_024,
                    maximumRecordsPerFile: 1
                )
            )
            XCTAssertThrowsError(try countBounded.load(item)) { error in
                XCTAssertEqual(
                    error as? RunRepositoryError,
                    .tooManyRecords("sources.json", limit: 1)
                )
            }
        }

        func testExactClaimEvidenceSourceJoinRejectsMissingAndDuplicateIDs() throws {
            let source = try decode(
                SourceRecord.self,
                #"{"source_id":"source-1","title":"Source","authors":[],"providers":["fixture"]}"#
            )
            let evidence = try decode(
                EvidenceRecord.self,
                #"{"evidence_id":"evidence-1","source_id":"source-1","passage":"Exact passage","locator":"p1","relevance":1,"stance":"supports"}"#
            )
            let claim = try decode(
                ClaimRecord.self,
                #"{"claim_id":"claim-1","text":"Exact passage","kind":"sourced_fact","evidence_ids":["evidence-1"],"limitations":[]}"#
            )
            let item = RunListItem(
                runID: "run-join",
                directory: URL(fileURLWithPath: "/tmp/run-join"),
                question: "question",
                status: .completed,
                updatedAt: .distantPast,
                sourceCount: 1,
                evidenceCount: 1,
                claimCount: 1
            )
            let detail = RunDetail(
                item: item,
                reportMarkdown: "report",
                sources: [source],
                evidence: [evidence],
                claims: [claim],
                manifest: .object([:])
            )

            let links = try RunRepository().joinEvidence(in: detail)
            XCTAssertEqual(links, [ClaimEvidenceSourceLink(claim: claim, evidence: evidence, source: source)])

            let missingDetail = RunDetail(
                item: item,
                reportMarkdown: "report",
                sources: [source],
                evidence: [],
                claims: [claim],
                manifest: .object([:])
            )
            XCTAssertThrowsError(try RunRepository().joinEvidence(in: missingDetail)) { error in
                XCTAssertEqual(
                    error as? RunRepositoryError,
                    .missingEvidence(claimID: "claim-1", evidenceID: "evidence-1")
                )
            }

            let duplicateDetail = RunDetail(
                item: item,
                reportMarkdown: "report",
                sources: [source, source],
                evidence: [evidence],
                claims: [claim],
                manifest: .object([:])
            )
            XCTAssertThrowsError(try RunRepository().joinEvidence(in: duplicateDetail)) { error in
                XCTAssertEqual(error as? RunRepositoryError, .duplicateID("source-1"))
            }
        }

        private func makeRun(in root: URL, runID: String) throws -> RunListItem {
            let directory = root.appendingPathComponent(runID, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let manifest =
                #"{"request":{"question":"How secure is this run?"},"records":{"claims":{"count":0},"evidence":{"count":0},"sources":{"count":0}},"run_id":"\#(runID)","status":"completed"}"#
            try Data(manifest.utf8).write(to: directory.appendingPathComponent("manifest.json"))
            for name in ["sources.json", "evidence.json", "claims.json"] {
                try Data("[]".utf8).write(to: directory.appendingPathComponent(name))
            }
            return RunListItem(
                runID: runID,
                directory: directory,
                question: "How secure is this run?",
                status: .completed,
                updatedAt: .distantPast,
                sourceCount: 0,
                evidenceCount: 0,
                claimCount: 0
            )
        }

        private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
            try JSONDecoder().decode(type, from: Data(text.utf8))
        }
    }
#endif
