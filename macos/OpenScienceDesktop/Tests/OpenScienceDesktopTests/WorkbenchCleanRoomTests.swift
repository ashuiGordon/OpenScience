#if canImport(XCTest)
    import Foundation
    import XCTest

    final class WorkbenchCleanRoomTests: XCTestCase {
        func testConversationImplementationContainsNoExternalProductBrandOrSourceMarkers() throws {
            let root = Self.projectRoot
            let directories = [
                root.appendingPathComponent("Sources/OpenScienceDesktop/ConversationUI", isDirectory: true),
                root.appendingPathComponent("Sources/OpenScienceDesktop/Logic", isDirectory: true),
            ]
            let swiftFiles = try directories.flatMap { directory in
                try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey]
                ).filter { $0.pathExtension == "swift" }
            }
            let forbidden = [
                "chatgpt",
                "codex",
                "github.com/ai4s-research",
                "github.com/github/spec-kit",
            ]
            for file in swiftFiles {
                let text = try String(contentsOf: file, encoding: .utf8).lowercased()
                for marker in forbidden {
                    XCTAssertFalse(
                        text.contains(marker), "external marker \(marker) in \(file.lastPathComponent)")
                }
            }
        }

        func testConversationDesignAssetsAreOnlyDeclaredLocalReviewArtifacts() throws {
            let directory = Self.projectRoot
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("design/conversation-workbench", isDirectory: true)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            let unexpected = names.filter { name in
                let lower = name.lowercased()
                return lower.contains("chatgpt") || lower.contains("codex") || lower.contains("third-party")
            }
            XCTAssertTrue(unexpected.isEmpty, "unexpected external design assets: \(unexpected)")
            let allowedImagePrefixes = ["selected-option-", "before-form-", "implementation-", "comparison-"]
            let undeclaredImages = names.filter { name in
                name.lowercased().hasSuffix(".png")
                    && !allowedImagePrefixes.contains(where: { name.hasPrefix($0) })
            }
            XCTAssertTrue(
                undeclaredImages.isEmpty,
                "undeclared conversation design images: \(undeclaredImages)"
            )

            let provenance = try String(
                contentsOf: directory.appendingPathComponent("README.md"),
                encoding: .utf8
            )
            XCTAssertTrue(provenance.contains("chosen by the user"))
            XCTAssertTrue(provenance.contains("does not authorize"))
            XCTAssertTrue(provenance.contains("copying another project's logo"))
        }

        private static var projectRoot: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }
    }
#endif
