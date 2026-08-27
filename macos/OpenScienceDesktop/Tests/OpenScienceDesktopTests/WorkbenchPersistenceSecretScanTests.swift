#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore
    @testable import OpenScienceDesktopLogic

    @MainActor
    final class WorkbenchPersistenceSecretScanTests: XCTestCase {
        func testEveryConversationPersistenceFileExcludesAuthorityAndResearchCanaries() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "openscience-secret-scan-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let workspace = directory.appendingPathComponent("workspace-v1.json")
            let store = try ConversationStore(fileURL: workspace)
            let session = try store.createSession(title: "Canary", prompt: "safe user question")
            let forbidden = [
                "CREDENTIAL-CANARY-4101",
                "ENVIRONMENT-CANARY-4102",
                "NETWORK-GRANT-CANARY-4103",
                "PLAN-APPROVAL-CANARY-4104",
                "EVIDENCE-PASSAGE-CANARY-4105",
                "REPORT-BODY-CANARY-4106",
                "STDERR-CANARY-4107",
                "/private/absolute-path-canary-4108",
            ]
            for value in forbidden {
                _ = try store.appendMessage(
                    sessionID: session.id,
                    role: .assistant,
                    kind: .result,
                    text: value
                )
            }
            _ = try store.setDraftText(
                sessionID: session.id,
                text: "Authorization: Bearer CREDENTIAL-CANARY-4101"
            )
            _ = try store.setSessionStatus(
                sessionID: session.id,
                status: .running,
                linkedRunID: "run-safe-canary"
            )

            let persisted = try allPersistedBytes(in: directory)
            for value in forbidden {
                XCTAssertNil(persisted.range(of: Data(value.utf8)), "persisted forbidden category")
            }
            XCTAssertNil(persisted.range(of: Data(#""allow_network":true"#.utf8)))
            XCTAssertNotNil(persisted.range(of: Data("[REDACTED]".utf8)))
            XCTAssertNotNil(persisted.range(of: Data("run-safe-canary".utf8)))
        }

        func testCandidateScannerCoversConversationSupportAndExportSurfaces() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "openscience-candidate-scan-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let candidates = [
                ("Conversations/workspace-v1.json", "CANDIDATE-CONVERSATION-5101"),
                ("Support/diagnostic.txt", "CANDIDATE-SUPPORT-5102"),
                ("Exports/export-metadata.json", "CANDIDATE-EXPORT-5103"),
            ]
            for (relativePath, marker) in candidates {
                let file = directory.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(marker.utf8).write(to: file)
            }

            let findings = try candidateFindings(
                in: directory,
                markers: candidates.map(\.1)
            )
            print("candidate scan file/count findings: \(findings)")
            XCTAssertEqual(
                Set(findings.keys),
                Set(candidates.map(\.0)),
                "candidate file/count findings: \(findings)"
            )
            XCTAssertTrue(findings.values.allSatisfy { $0 == 1 })
        }

        private func allPersistedBytes(in directory: URL) throws -> Data {
            let enumerator = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            )
            var result = Data()
            for case let file as URL in enumerator {
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    result.append(try Data(contentsOf: file))
                }
            }
            return result
        }

        private func candidateFindings(
            in directory: URL,
            markers: [String]
        ) throws -> [String: Int] {
            let enumerator = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            )
            var findings: [String: Int] = [:]
            for case let file as URL in enumerator {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    continue
                }
                let data = try Data(contentsOf: file)
                let count = markers.reduce(into: 0) { total, marker in
                    if data.range(of: Data(marker.utf8)) != nil { total += 1 }
                }
                if count > 0 {
                    let baseComponents = directory.resolvingSymlinksInPath().pathComponents
                    let fileComponents = file.resolvingSymlinksInPath().pathComponents
                    let relative = fileComponents.dropFirst(baseComponents.count).joined(separator: "/")
                    findings[relative] = count
                }
            }
            return findings
        }
    }
#endif
