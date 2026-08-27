#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore
    @testable import OpenScienceDesktopLogic

    @MainActor
    final class ConversationWorkbenchPerformanceTests: XCTestCase {
        func testP95SearchSelectionAndExactEvidenceLookupOnDeclaredMac() throws {
            try requireDeclaredPerformancePlatform()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "openscience-performance-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let workspace = directory.appendingPathComponent("workspace-v1.json")
            try WorkbenchFixtureFactory.writeLegacyScaleSnapshot(to: workspace)
            let store = try ConversationStore(fileURL: workspace)
            let evidence = try WorkbenchFixtureFactory.makeEvidenceDetail()
            let links = try RunRepository().joinEvidence(in: evidence)
            let byEvidenceID = Dictionary(uniqueKeysWithValues: links.map { ($0.evidence.evidenceID, $0) })

            for _ in 0..<5 {
                _ = store.search("fixture question 0-999")
                try store.selectSession(store.projects[0].sessions[199].id)
                _ = byEvidenceID["evidence-0999"]
            }

            let search = samples(30) {
                XCTAssertEqual(store.search("fixture question 0-999").count, 1)
            }
            let selection = try samples(30) {
                try store.selectSession(store.projects[0].sessions[199].id)
                try store.selectSession(store.projects[0].sessions[0].id)
            }
            let evidenceLookup = try samples(30) {
                let link = try XCTUnwrap(byEvidenceID["evidence-0999"])
                XCTAssertEqual(link.source.sourceID, "source-0999")
            }

            let searchP95 = WorkbenchFixtureFactory.percentile95(search)
            let selectionP95 = WorkbenchFixtureFactory.percentile95(selection)
            let evidenceP95 = WorkbenchFixtureFactory.percentile95(evidenceLookup)
            print(
                "SC-006 deterministic p95: search=\(searchP95), selection=\(selectionP95), evidence=\(evidenceP95)"
            )
            XCTAssertLessThanOrEqual(searchP95, .milliseconds(500))
            XCTAssertLessThanOrEqual(selectionP95, .milliseconds(500))
            XCTAssertLessThanOrEqual(evidenceP95, .seconds(2))
        }

        private func samples(
            _ count: Int,
            operation: () throws -> Void
        ) rethrows -> [Duration] {
            let clock = ContinuousClock()
            return try (0..<count).map { _ in
                let start = clock.now
                try operation()
                return start.duration(to: clock.now)
            }
        }

        private func requireDeclaredPerformancePlatform() throws {
            #if !arch(arm64)
                throw XCTSkip("SC-006 requires an Apple M1-or-newer Mac.")
            #endif
            guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14 else {
                throw XCTSkip("SC-006 requires macOS 14 or newer.")
            }
            guard ProcessInfo.processInfo.physicalMemory >= 8 * 1_024 * 1_024 * 1_024 else {
                throw XCTSkip("SC-006 requires at least 8 GiB RAM.")
            }
            guard ProcessInfo.processInfo.thermalState == .nominal else {
                throw XCTSkip("SC-006 measurement skipped under thermal pressure.")
            }
        }
    }
#endif
