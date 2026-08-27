#if canImport(XCTest)
    import Foundation
    import XCTest

    @testable import OpenScienceCore

    final class EngineResolverTests: XCTestCase {
        func testBundledHelperTakesPriorityOverExplicitDevelopmentPath() async throws {
            let root = try makeSecurityTestDirectory("engine-priority")
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = root.appendingPathComponent("OpenScience.app", isDirectory: true)
            let helpers = bundle.appendingPathComponent("Contents/Helpers", isDirectory: true)
            try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
            let bundled = helpers.appendingPathComponent("openscience")
            let explicit = root.appendingPathComponent("development-openscience")
            try writeExecutable("printf 'openscience 0.1.9\\n'", to: bundled)
            try writeExecutable("printf 'openscience 0.1.8\\n'", to: explicit)

            let result = try await EngineResolver(
                bundleURL: bundle,
                explicitDevelopmentURL: explicit,
                timeout: 2
            ).resolve()

            XCTAssertEqual(result.executableURL, bundled.resolvingSymlinksInPath())
            XCTAssertEqual(result.version, EngineVersion(major: 0, minor: 1, patch: 9))
            XCTAssertEqual(result.source, .bundled)
            XCTAssertEqual(result.identity.sha256.count, 64)
        }

        func testExplicitDevelopmentPathIsUsedOnlyWhenBundleHasNoHelper() async throws {
            let root = try makeSecurityTestDirectory("engine-explicit")
            defer { try? FileManager.default.removeItem(at: root) }
            let explicit = root.appendingPathComponent("openscience")
            try writeExecutable("printf 'openscience 0.1.4\\n'", to: explicit)

            let result = try await EngineResolver(
                bundleURL: root.appendingPathComponent("Missing.app"),
                explicitDevelopmentURL: explicit,
                timeout: 2
            ).resolve()

            XCTAssertEqual(result.source, .explicitDevelopment)
            XCTAssertEqual(result.version.patch, 4)
        }

        func testIncompatibleOrSymlinkedHelperFailsClosed() async throws {
            let root = try makeSecurityTestDirectory("engine-invalid")
            defer { try? FileManager.default.removeItem(at: root) }
            let incompatible = root.appendingPathComponent("incompatible")
            try writeExecutable("printf 'openscience 0.2.0\\n'", to: incompatible)

            do {
                _ = try await EngineResolver(
                    bundleURL: root.appendingPathComponent("Missing.app"),
                    explicitDevelopmentURL: incompatible,
                    timeout: 2
                ).resolve()
                XCTFail("Expected incompatible engine rejection")
            } catch let error as EngineResolutionError {
                guard case .incompatibleVersion = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }

            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: incompatible)
            do {
                _ = try await EngineResolver(
                    bundleURL: root.appendingPathComponent("Missing.app"),
                    explicitDevelopmentURL: link,
                    timeout: 2
                ).resolve()
                XCTFail("Expected symlink rejection")
            } catch let error as EngineResolutionError {
                guard case .unsafeExecutable = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }

        func testResolverNeverSearchesPATH() async throws {
            let root = try makeSecurityTestDirectory("engine-path")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeExecutable(
                "printf 'openscience 0.1.0\\n'",
                to: root.appendingPathComponent("openscience")
            )

            do {
                _ = try await EngineResolver(
                    bundleURL: root.appendingPathComponent("Missing.app"),
                    explicitDevelopmentURL: nil,
                    timeout: 2
                ).resolve()
                XCTFail("Expected no configured engine")
            } catch let error as EngineResolutionError {
                XCTAssertEqual(error, .notConfigured)
            }
        }

        func testResolverRejectsExecutableChangedDuringProbe() async throws {
            let root = try makeSecurityTestDirectory("engine-probe-swap")
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("openscience")
            try writeExecutable(
                "printf 'openscience 0.1.0\\n'; printf '#!/bin/sh\\nprintf hacked\\n' > \"$0.next\"; /bin/chmod 700 \"$0.next\"; /bin/mv -f \"$0.next\" \"$0\"",
                to: executable
            )

            do {
                _ = try await EngineResolver(
                    bundleURL: root.appendingPathComponent("Missing.app"),
                    explicitDevelopmentURL: executable,
                    timeout: 2
                ).resolve()
                XCTFail("Expected probe swap rejection")
            } catch let error as EngineResolutionError {
                XCTAssertEqual(error, .executableChanged)
            }
        }

        func testClientRejectsPostProbeExecutableSwapBeforeOrAfterSpawn() async throws {
            let root = try makeSecurityTestDirectory("engine-launch-swap")
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("openscience")
            let replacement = root.appendingPathComponent("openscience.replacement")
            try writeExecutable(
                "if [ \"${1:-}\" = '--version' ]; then printf 'openscience 0.1.0\\n'; exit 0; fi; /bin/cp \"$0.replacement\" \"$0.next\"; /bin/chmod 700 \"$0.next\"; /bin/mv -f \"$0.next\" \"$0\"; printf '{\"providers\":[]}\\n'",
                to: executable
            )
            try writeExecutable("printf '{\"providers\":[]}\\n'", to: replacement)
            let resolved = try await EngineResolver(
                bundleURL: root.appendingPathComponent("Missing.app"),
                explicitDevelopmentURL: executable,
                timeout: 2
            ).resolve()
            let invocation = CLIInvocation(
                executableURL: resolved.executableURL,
                arguments: ["providers"],
                workingDirectory: root,
                expectedExecutableIdentity: resolved.identity
            )

            do {
                _ = try await OpenScienceCLIClient().execute(invocation)
                XCTFail("Expected launch swap rejection")
            } catch let error as CLIProtocolError {
                XCTAssertEqual(error, .executableIdentityMismatch)
            }
        }
    }
#endif
