#if canImport(XCTest)
    import Foundation
    import XCTest

    final class WorkbenchFixtureTests: XCTestCase {
        func testOptionThreeFixtureIsDeterministicAndSanitized() throws {
            let fixture = try object(at: "Fixtures/workbench-option-3.json")
            XCTAssertEqual(fixture["schema_version"] as? Int, 1)
            XCTAssertEqual(fixture["fixture_only"] as? Bool, true)
            XCTAssertEqual(fixture["reference_time"] as? String, "2026-08-27T09:43:00Z")
            let viewport = try XCTUnwrap(fixture["viewport"] as? [String: Any])
            XCTAssertEqual(viewport["width"] as? Int, 1_487)
            XCTAssertEqual(viewport["height"] as? Int, 1_058)
            XCTAssertEqual(viewport["appearance"] as? String, "dark")
            let text = String(data: try data(at: "Fixtures/workbench-option-3.json"), encoding: .utf8)!
            for forbidden in ["api_key", "password", "credential", "Bearer ", "/Users/"] {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden))
            }
        }

        func testConversationStoreFailureFixturesDeclareExactBoundaries() throws {
            let newer = try object(at: "Fixtures/ConversationStore/newer-envelope.json")
            XCTAssertEqual(newer["schema_version"] as? Int, 2)

            let recipe = try object(at: "Fixtures/ConversationStore/oversized-envelope.recipe.json")
            XCTAssertEqual(recipe["expected_limit_bytes"] as? Int, 8 * 1_024 * 1_024)
            XCTAssertEqual(recipe["generated_byte_count"] as? Int, 8 * 1_024 * 1_024 + 1)

            let references = try object(at: "Fixtures/ConversationStore/managed-run-references.json")
            XCTAssertEqual((references["valid"] as? [String])?.count, 2)
            XCTAssertEqual((references["invalid"] as? [String])?.count, 4)

            XCTAssertThrowsError(
                try JSONSerialization.jsonObject(
                    with: data(at: "Fixtures/ConversationStore/corrupt-envelope.json")
                )
            )
        }

        private func object(at relativePath: String) throws -> [String: Any] {
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: data(at: relativePath)) as? [String: Any]
            )
        }

        private func data(at relativePath: String) throws -> Data {
            try Data(contentsOf: Self.testDirectory.appendingPathComponent(relativePath))
        }

        private static var testDirectory: URL {
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        }
    }
#endif
