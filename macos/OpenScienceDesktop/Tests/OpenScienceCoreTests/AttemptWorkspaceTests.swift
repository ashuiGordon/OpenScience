#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore

    final class AttemptWorkspaceTests: XCTestCase {
        func testCreateProducesUniqueEmptyRunsDirectories() throws {
            let root = try makeSecurityTestDirectory("attempt-create")
            defer { try? FileManager.default.removeItem(at: root) }

            let first = try AttemptWorkspace.create(under: root)
            let second = try AttemptWorkspace.create(under: root)

            XCTAssertNotEqual(first.jobDirectory, second.jobDirectory)
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(atPath: first.runsDirectory.path).isEmpty)
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(atPath: second.runsDirectory.path).isEmpty)
            XCTAssertTrue(first.runsDirectory.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"))
        }

        func testResolutionRequiresExactlyOneImmediateRunDirectory() throws {
            let root = try makeSecurityTestDirectory("attempt-exact")
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = try AttemptWorkspace.create(under: root)

            XCTAssertThrowsError(try workspace.resolveRunDirectory()) { error in
                XCTAssertEqual(error as? AttemptWorkspaceError, .missingRunDirectory)
            }

            let nested = workspace.runsDirectory
                .appendingPathComponent("nested", isDirectory: true)
                .appendingPathComponent("run-hidden", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            XCTAssertThrowsError(try workspace.resolveRunDirectory()) { error in
                XCTAssertEqual(error as? AttemptWorkspaceError, .missingRunDirectory)
            }

            let first = workspace.runsDirectory.appendingPathComponent("run-first", isDirectory: true)
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
            XCTAssertEqual(try workspace.resolveRunDirectory(), first.resolvingSymlinksInPath())

            let second = workspace.runsDirectory.appendingPathComponent("run-second", isDirectory: true)
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
            XCTAssertThrowsError(try workspace.resolveRunDirectory()) { error in
                XCTAssertEqual(error as? AttemptWorkspaceError, .multipleRunDirectories(2))
            }
        }

        func testSymlinkedRunFailsClosedEvenWhenAnotherCandidateIsValid() throws {
            let root = try makeSecurityTestDirectory("attempt-symlink")
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = try AttemptWorkspace.create(under: root)
            let valid = workspace.runsDirectory.appendingPathComponent("run-valid", isDirectory: true)
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(
                at: workspace.runsDirectory.appendingPathComponent("run-link"),
                withDestinationURL: outside
            )

            XCTAssertThrowsError(try workspace.resolveRunDirectory()) { error in
                guard case .unsafeRunDirectory = error as? AttemptWorkspaceError else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }
#endif
