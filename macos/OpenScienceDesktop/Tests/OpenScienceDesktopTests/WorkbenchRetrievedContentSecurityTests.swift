#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore

    final class WorkbenchRetrievedContentSecurityTests: XCTestCase {
        func testRetrievedSchemesRemainBlockedByExternalURLPolicy() {
            for value in [
                "file:///private/tmp/report.html",
                "javascript:alert(1)",
                "data:text/html,<script>alert(1)</script>",
                "ftp://example.invalid/report",
            ] {
                XCTAssertThrowsError(try ExternalURLPolicy.validate(value), value)
            }
            XCTAssertNoThrow(try ExternalURLPolicy.validate("https://example.invalid/source"))
        }

        func testConversationRenderingUsesNoActiveWebContentSurface() throws {
            let root = Self.projectRoot
            let sourceFiles = [
                root.appendingPathComponent(
                    "Sources/OpenScienceDesktop/ConversationUI/ConversationTimeline.swift"),
                root.appendingPathComponent(
                    "Sources/OpenScienceDesktop/ConversationUI/ConversationCards.swift"),
                root.appendingPathComponent("Sources/OpenScienceDesktop/ConversationUI/InspectorPane.swift"),
                root.appendingPathComponent(
                    "Sources/OpenScienceDesktop/ConversationUI/ArtifactPreview.swift"),
                root.appendingPathComponent("Sources/OpenScienceDesktop/HistoryViews.swift"),
            ]
            let combined = try sourceFiles.map { try String(contentsOf: $0, encoding: .utf8) }
                .joined(separator: "\n")

            for forbidden in [
                "WKWebView", "WebView(", "PDFView(", "AttributedString(markdown:",
                "NSHTMLTextDocumentType",
            ] {
                XCTAssertFalse(combined.contains(forbidden), "active renderer found: \(forbidden)")
            }
            XCTAssertTrue(combined.contains("Text(verbatim: text)"))
            XCTAssertTrue(combined.contains("Text(verbatim: message.text)"))
            XCTAssertTrue(combined.contains("requestExternalOpen"))
        }

        private static var projectRoot: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }
    }
#endif
