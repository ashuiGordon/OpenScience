#if canImport(XCTest)
    import CryptoKit
    import Darwin
    import Foundation
    import XCTest

    @testable import OpenScienceCore
    @testable import OpenScienceDesktopLogic

    final class PreviewRouterTests: XCTestCase {
        func testResolvesOnlyExactRunAndArtifactTypedSelection() throws {
            let sandbox = try makeSandbox("exact")
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let first = try makeRun(
                in: sandbox, runID: "run-first", artifactID: "artifact-first",
                name: "first.md", mediaType: "text/markdown", data: Data("# First".utf8))
            let expectedData = Data("# Exact\n".utf8)
            let selected = try makeRun(
                in: sandbox, runID: "run-selected", artifactID: "artifact-exact",
                name: "exact.md", mediaType: "text/markdown", data: expectedData)
            let router = PreviewRouter(root: sandbox)

            let result = router.resolveArtifact(
                ArtifactPreviewSelection(runID: "run-selected", artifactID: "artifact-exact"),
                from: [first, selected]
            )

            guard case let .markdown(metadata, text) = result else {
                return XCTFail("Expected exact Markdown preview, got \(result)")
            }
            XCTAssertEqual(metadata.runID, "run-selected")
            XCTAssertEqual(metadata.artifactID, "artifact-exact")
            XCTAssertEqual(metadata.name, "exact.md")
            XCTAssertEqual(text, "# Exact\n")
        }

        func testMissingAmbiguousAndStructurallyInvalidRunsReturnSafeMetadataReasons() throws {
            let sandbox = try makeSandbox("run-routing")
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let item = try makeRun(
                in: sandbox, runID: "run-one", artifactID: "artifact-one",
                name: "one.md", mediaType: "text/markdown", data: Data("one".utf8))
            let duplicateDirectory = sandbox.appendingPathComponent("other", isDirectory: true)
            try FileManager.default.createDirectory(
                at: duplicateDirectory, withIntermediateDirectories: false)
            let duplicate = RunListItem(
                runID: item.runID,
                directory: duplicateDirectory,
                question: "duplicate",
                status: .completed,
                updatedAt: .distantPast,
                sourceCount: 0,
                evidenceCount: 0,
                claimCount: 0
            )
            let invalid = RunListItem(
                runID: "run-invalid",
                directory: sandbox.appendingPathComponent("run-invalid"),
                question: "invalid",
                status: .unknown,
                updatedAt: .distantPast,
                sourceCount: 0,
                evidenceCount: 0,
                claimCount: 0,
                structuralIssue: RunStructuralIssue(code: "manifest.invalid", message: "unsafe")
            )
            let router = PreviewRouter(root: sandbox)

            XCTAssertEqual(
                fallbackReason(
                    router.resolveArtifact(
                        ArtifactPreviewSelection(runID: "run-missing", artifactID: "artifact-one"),
                        from: [item])),
                .runNotFound
            )
            XCTAssertEqual(
                fallbackReason(
                    router.resolveArtifact(
                        ArtifactPreviewSelection(runID: item.runID, artifactID: "artifact-one"),
                        from: [item, duplicate])),
                .runAmbiguous
            )
            XCTAssertEqual(
                fallbackReason(
                    router.resolveArtifact(
                        ArtifactPreviewSelection(
                            runID: "run-invalid", artifactID: "artifact-one"),
                        from: [invalid])),
                .runInvalid
            )
        }

        func testFallbackRetainsManifestMetadataForUnsupportedMissingAndOversizedArtifacts() throws {
            let unsupportedRoot = try makeSandbox("unsupported")
            defer { try? FileManager.default.removeItem(at: unsupportedRoot) }
            let unsupported = try makeRun(
                in: unsupportedRoot, runID: "run-unsupported", artifactID: "artifact-html",
                name: "page.html", mediaType: "text/html", data: Data("<script/>".utf8))
            var result = PreviewRouter(root: unsupportedRoot).resolveArtifact(
                ArtifactPreviewSelection(
                    runID: "run-unsupported", artifactID: "artifact-html"),
                from: [unsupported]
            )
            assertFallback(
                result,
                reason: .unsupportedType,
                artifactID: "artifact-html",
                name: "page.html"
            )

            let missingRoot = try makeSandbox("missing")
            defer { try? FileManager.default.removeItem(at: missingRoot) }
            let missing = try makeRun(
                in: missingRoot, runID: "run-missing-file", artifactID: "artifact-missing",
                name: "missing.md", mediaType: "text/markdown", data: Data("missing".utf8))
            try FileManager.default.removeItem(
                at: missing.directory.appendingPathComponent("missing.md"))
            result = PreviewRouter(root: missingRoot).resolveArtifact(
                ArtifactPreviewSelection(
                    runID: "run-missing-file", artifactID: "artifact-missing"),
                from: [missing]
            )
            assertFallback(
                result, reason: .fileMissing, artifactID: "artifact-missing", name: "missing.md")

            let largeRoot = try makeSandbox("large")
            defer { try? FileManager.default.removeItem(at: largeRoot) }
            let bytes = Data(repeating: 0x61, count: 64)
            let large = try makeRun(
                in: largeRoot, runID: "run-large", artifactID: "artifact-large",
                name: "large.md", mediaType: "text/markdown", data: bytes)
            result = PreviewRouter(
                root: largeRoot,
                limits: RunRepositoryLimits(artifactBytes: 32)
            ).resolveArtifact(
                ArtifactPreviewSelection(runID: "run-large", artifactID: "artifact-large"),
                from: [large]
            )
            assertFallback(
                result, reason: .oversized, artifactID: "artifact-large", name: "large.md")
        }

        func testRejectsInvalidSelectionDuplicateArtifactAndUnsafeFileWithoutLeakingPaths() throws {
            let sandbox = try makeSandbox("invalid")
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let item = try makeRun(
                in: sandbox, runID: "run-valid", artifactID: "artifact-valid",
                name: "valid.md", mediaType: "text/markdown", data: Data("valid".utf8))
            let router = PreviewRouter(root: sandbox)

            var result = router.resolveArtifact(
                ArtifactPreviewSelection(runID: "../run-valid", artifactID: "artifact-valid"),
                from: [item]
            )
            XCTAssertEqual(fallbackReason(result), .invalidSelection)

            try duplicateArtifact(in: item.directory, runID: item.runID)
            result = router.resolveArtifact(
                ArtifactPreviewSelection(runID: item.runID, artifactID: "artifact-valid"),
                from: [item]
            )
            XCTAssertEqual(fallbackReason(result), .artifactAmbiguous)

            let unsafeRoot = try makeSandbox("unsafe")
            defer { try? FileManager.default.removeItem(at: unsafeRoot) }
            let unsafe = try makeRun(
                in: unsafeRoot, runID: "run-unsafe", artifactID: "artifact-unsafe",
                name: "unsafe.md", mediaType: "text/markdown", data: Data("unsafe".utf8))
            let target = unsafe.directory.appendingPathComponent("unsafe.md")
            let original = unsafeRoot.appendingPathComponent("original.md")
            try FileManager.default.moveItem(at: target, to: original)
            XCTAssertEqual(link(original.path, target.path), 0)
            result = PreviewRouter(root: unsafeRoot).resolveArtifact(
                ArtifactPreviewSelection(runID: "run-unsafe", artifactID: "artifact-unsafe"),
                from: [unsafe]
            )
            XCTAssertEqual(fallbackReason(result), .unsafeFile)
            guard case let .metadata(metadata, _) = result else {
                return XCTFail("Expected metadata fallback")
            }
            XCTAssertFalse(metadata.summary.contains(unsafeRoot.path))
            XCTAssertNil(metadata.fileURL)
        }

        func testMarkdownWithHTMLAndFileURLRemainsInertTextOnly() throws {
            let sandbox = try makeSandbox("inert")
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let text = "<script>alert(1)</script> [open](file:///etc/passwd)"
            let item = try makeRun(
                in: sandbox, runID: "run-inert", artifactID: "artifact-inert",
                name: "inert.md", mediaType: "text/markdown", data: Data(text.utf8))

            let result = PreviewRouter(root: sandbox).resolveArtifact(
                ArtifactPreviewSelection(runID: "run-inert", artifactID: "artifact-inert"),
                from: [item]
            )
            guard case let .markdown(metadata, returned) = result else {
                return XCTFail("Expected inert text")
            }
            XCTAssertEqual(returned, text)
            XCTAssertNil(metadata.fileURL)
            XCTAssertEqual(metadata.renderingPolicy, .inertNativeOnly)
        }

        private func fallbackReason(_ result: ArtifactPreviewResolution) -> ArtifactPreviewFallbackReason? {
            guard case let .metadata(_, reason) = result else { return nil }
            return reason
        }

        private func assertFallback(
            _ result: ArtifactPreviewResolution,
            reason: ArtifactPreviewFallbackReason,
            artifactID: String,
            name: String
        ) {
            guard case let .metadata(metadata, actualReason) = result else {
                return XCTFail("Expected metadata fallback, got \(result)")
            }
            XCTAssertEqual(actualReason, reason)
            XCTAssertEqual(metadata.artifactID, artifactID)
            XCTAssertEqual(metadata.name, name)
            XCTAssertNil(metadata.fileURL)
        }

        private func makeSandbox(_ name: String) throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "OpenSciencePreviewRouter-\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            return root
        }

        private func makeRun(
            in root: URL,
            runID: String,
            artifactID: String,
            name: String,
            mediaType: String,
            data: Data
        ) throws -> RunListItem {
            let directory = root.appendingPathComponent(runID, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let artifact = artifactObject(
                id: artifactID, name: name, mediaType: mediaType, data: data)
            try writeManifest(runDirectory: directory, runID: runID, artifacts: [artifact])
            try data.write(to: directory.appendingPathComponent(name))
            return RunListItem(
                runID: runID,
                directory: directory,
                question: "Preview",
                status: .completed,
                updatedAt: .distantPast,
                sourceCount: 0,
                evidenceCount: 0,
                claimCount: 0
            )
        }

        private func duplicateArtifact(in directory: URL, runID: String) throws {
            let data = try Data(contentsOf: directory.appendingPathComponent("valid.md"))
            let artifact = artifactObject(
                id: "artifact-valid", name: "valid.md", mediaType: "text/markdown", data: data)
            try writeManifest(runDirectory: directory, runID: runID, artifacts: [artifact, artifact])
        }

        private func artifactObject(
            id: String,
            name: String,
            mediaType: String,
            data: Data
        ) -> JSONValue {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return .object([
                "artifact_id": .string(id),
                "name": .string(name),
                "media_type": .string(mediaType),
                "sha256": .string(digest),
                "size": .number(Double(data.count)),
                "object_path": .string("objects/content"),
            ])
        }

        private func writeManifest(
            runDirectory: URL,
            runID: String,
            artifacts: [JSONValue]
        ) throws {
            let manifest = JSONValue.object([
                "run_id": .string(runID),
                "status": .string("completed"),
                "artifacts": .array(artifacts),
            ])
            try JSONEncoder().encode(manifest).write(
                to: runDirectory.appendingPathComponent("manifest.json"))
        }
    }
#endif
