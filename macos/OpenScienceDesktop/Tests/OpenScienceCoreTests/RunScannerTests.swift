#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore

    final class RunScannerTests: XCTestCase {
        private var temporaryRoot: URL!

        override func setUpWithError() throws {
            temporaryRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("openscience-scanner-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        }

        override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temporaryRoot) }

        func testScansNestedPerJobWorkspaceAndReadsCounts() throws {
            let run = temporaryRoot.appendingPathComponent("jobs/job-1/runs/run-abc", isDirectory: true)
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            let manifest =
                #"{"request":{"question":"How reproducible is X?"},"records":{"claims":{"count":2},"evidence":{"count":4},"sources":{"count":3}},"run_id":"run-abc","status":"partial"}"#
            try Data(manifest.utf8).write(to: run.appendingPathComponent("manifest.json"))

            let items = try RunScanner().scan(root: temporaryRoot)
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items[0].runID, "run-abc")
            XCTAssertEqual(items[0].question, "How reproducible is X?")
            XCTAssertEqual(items[0].status, .partial)
            XCTAssertEqual(items[0].sourceCount, 3)
            XCTAssertEqual(items[0].evidenceCount, 4)
            XCTAssertEqual(items[0].claimCount, 2)
        }

        func testDiscoversActiveRunBeforeManifestExists() throws {
            let workspace = temporaryRoot.appendingPathComponent("job/runs", isDirectory: true)
            let run = workspace.appendingPathComponent("run-in-flight", isDirectory: true)
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: run.appendingPathComponent("events.jsonl"))
            XCTAssertEqual(
                try RunScanner().discoverActiveRun(jobWorkspace: workspace), run.standardizedFileURL)
            XCTAssertTrue(try RunScanner().scan(root: workspace).isEmpty)
        }

        func testActiveDiscoveryRejectsSymlinksAndUninitializedDirectories() throws {
            let workspace = temporaryRoot.appendingPathComponent("job/runs", isDirectory: true)
            let external = temporaryRoot.appendingPathComponent("external", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: external.appendingPathComponent("events.jsonl"))
            try FileManager.default.createSymbolicLink(
                at: workspace.appendingPathComponent("run-link"),
                withDestinationURL: external
            )
            try FileManager.default.createDirectory(
                at: workspace.appendingPathComponent("run-empty"),
                withIntermediateDirectories: true
            )
            XCTAssertThrowsError(try RunScanner().discoverActiveRun(jobWorkspace: workspace)) {
                guard case .unsafeRunDirectory = $0 as? AttemptWorkspaceError else {
                    return XCTFail("Unexpected error: \($0)")
                }
            }
        }

        func testActiveDiscoveryRejectsMultipleCandidatesInsteadOfSelectingNewest() throws {
            let workspace = temporaryRoot.appendingPathComponent("job/runs", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            for name in ["run-old", "run-new"] {
                let run = workspace.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
                try Data("{}\n".utf8).write(to: run.appendingPathComponent("events.jsonl"))
            }

            XCTAssertThrowsError(try RunScanner().discoverActiveRun(jobWorkspace: workspace)) {
                XCTAssertEqual($0 as? AttemptWorkspaceError, .multipleRunDirectories(2))
            }
        }

        func testScanIsolatesMalformedRunAndReturnsOtherValidRuns() throws {
            try writeManifestRun(name: "run-good-one", under: temporaryRoot)
            try writeManifestRun(name: "run-good-two", under: temporaryRoot)
            let bad = temporaryRoot.appendingPathComponent("run-bad", isDirectory: true)
            try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: false)
            try Data("{broken\n".utf8).write(to: bad.appendingPathComponent("manifest.json"))

            let items = try RunScanner().scan(root: temporaryRoot)

            XCTAssertEqual(items.count, 3)
            XCTAssertNil(items.first(where: { $0.runID == "run-good-one" })?.structuralIssue)
            XCTAssertNil(items.first(where: { $0.runID == "run-good-two" })?.structuralIssue)
            let badItem = try XCTUnwrap(items.first(where: { $0.directory.lastPathComponent == "run-bad" }))
            XCTAssertEqual(badItem.status, .unknown)
            XCTAssertEqual(badItem.structuralIssue?.code, "malformed_json")
        }

        func testDuplicateRunIDsMarkEveryDuplicateWithoutStoppingScan() throws {
            let firstRoot = temporaryRoot.appendingPathComponent("jobs/one", isDirectory: true)
            let secondRoot = temporaryRoot.appendingPathComponent("jobs/two", isDirectory: true)
            try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
            try writeManifestRun(name: "run-duplicate", under: firstRoot)
            try writeManifestRun(name: "run-duplicate", under: secondRoot)
            try writeManifestRun(name: "run-unique", under: temporaryRoot)

            let items = try RunScanner().scan(root: temporaryRoot)
            let duplicates = items.filter { $0.runID == "run-duplicate" }

            XCTAssertEqual(items.count, 3)
            XCTAssertEqual(duplicates.count, 2)
            XCTAssertTrue(duplicates.allSatisfy { $0.structuralIssue?.code == "duplicate_run_id" })
            XCTAssertNil(items.first(where: { $0.runID == "run-unique" })?.structuralIssue)
        }

        func testSymlinkedRunProducesInvalidRowWithoutFollowingTarget() throws {
            let outside = temporaryRoot.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let link = temporaryRoot.appendingPathComponent("run-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

            let items = try RunScanner().scan(root: temporaryRoot)

            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items[0].directory, link.standardizedFileURL)
            XCTAssertEqual(items[0].structuralIssue?.code, "unsafe_run_directory")
        }

        private func writeManifestRun(name: String, under root: URL) throws {
            let run = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
            let manifest =
                #"{"request":{"question":"Valid question"},"records":{"claims":{"count":0},"evidence":{"count":0},"sources":{"count":0}},"run_id":"\#(name)","status":"completed"}"#
            try Data(manifest.utf8).write(to: run.appendingPathComponent("manifest.json"))
        }
    }
#endif
