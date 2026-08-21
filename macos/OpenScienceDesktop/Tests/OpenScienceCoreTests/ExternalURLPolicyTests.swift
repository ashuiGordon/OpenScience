#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore

    final class ExternalURLPolicyTests: XCTestCase {
        func testAllowsOnlyAbsoluteHTTPAndHTTPSWithoutCredentials() throws {
            XCTAssertEqual(
                try ExternalURLPolicy.validate("https://example.org/paper?q=1").absoluteString,
                "https://example.org/paper?q=1"
            )
            XCTAssertEqual(
                try ExternalURLPolicy.validate(URL(string: "HTTP://example.org")!).scheme?.lowercased(),
                "http"
            )

            for value in [
                "file:///etc/passwd", "javascript:alert(1)", "data:text/html,hello",
                "//example.org/path", "/relative", "https://user:pass@example.org/private",
                "https:///missing-host",
            ] {
                XCTAssertThrowsError(try ExternalURLPolicy.validate(value), "Expected rejection: \(value)")
            }
        }
    }
#endif
