#if canImport(XCTest)
    import Foundation
    import XCTest

    final class ConversationWorkbenchVisualTests: XCTestCase {
        func testComparisonPassesIdenticalTargetAndRejectsVisibleMismatch() throws {
            guard toolExists("ffmpeg"), toolExists("ffprobe") else {
                throw XCTSkip("ffmpeg and ffprobe are required for deterministic visual comparison.")
            }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
                "openscience-visual-test-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }

            let source = Self.repositoryRoot.appendingPathComponent(
                "design/conversation-workbench/selected-option-3.png"
            )
            let script = Self.projectRoot.appendingPathComponent(
                "scripts/compare-workbench-reference.sh"
            )
            let identicalComparison = temporary.appendingPathComponent("identical.png")
            try XCTAssertEqual(
                try run(script, [source.path, source.path, identicalComparison.path]).status,
                0
            )

            let mismatch = temporary.appendingPathComponent("mismatch.png")
            let generate = try run(
                URL(fileURLWithPath: "/usr/bin/env"),
                [
                    "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                    "-i", "color=c=black:s=1487x1058", "-frames:v", "1", mismatch.path,
                ]
            )
            XCTAssertEqual(generate.status, 0, generate.output)
            let failed = try run(
                script,
                [source.path, mismatch.path, temporary.appendingPathComponent("failed.png").path]
            )
            XCTAssertEqual(failed.status, 1, failed.output)
            XCTAssertTrue(failed.output.contains("below 0.90"), failed.output)

            let oversizedMask = temporary.appendingPathComponent("oversized-mask.png")
            let generateMask = try run(
                URL(fileURLWithPath: "/usr/bin/env"),
                [
                    "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                    "-i", "color=c=white:s=1487x1058", "-frames:v", "1", oversizedMask.path,
                ]
            )
            XCTAssertEqual(generateMask.status, 0, generateMask.output)
            let rejectedMask = try run(
                script,
                [
                    source.path, source.path, temporary.appendingPathComponent("masked.png").path,
                    oversizedMask.path,
                ]
            )
            XCTAssertEqual(rejectedMask.status, 2, rejectedMask.output)
            XCTAssertTrue(rejectedMask.output.contains("anti-gaming ceiling"), rejectedMask.output)
        }

        private func toolExists(_ name: String) -> Bool {
            (try? run(URL(fileURLWithPath: "/usr/bin/env"), ["which", name]).status) == 0
        }

        private func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            let output =
                String(
                    data: pipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
            return (process.terminationStatus, output)
        }

        private static var projectRoot: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }

        private static var repositoryRoot: URL {
            projectRoot.deletingLastPathComponent().deletingLastPathComponent()
        }
    }
#endif
