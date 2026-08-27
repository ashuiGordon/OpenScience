#if canImport(XCTest)
    import CryptoKit
    import Darwin
    import Foundation
    import XCTest

    @testable import OpenScienceCore

    final class ArtifactPreviewTests: XCTestCase {
        func testLoadsExactManifestMarkdownAndPrefersDeclaredNameProjection() throws {
            let sandbox = try makeSandbox("markdown")
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let fixture = try fixtureData("inert.md")
            let staleObject = Data("# stale object".utf8)
            let artifact = artifactJSON(
                id: "artifact-markdown",
                name: "report.md",
                mediaType: "text/markdown",
                data: fixture,
                objectPath: "objects/report-object"
            )
            let item = try makeRun(
                in: sandbox,
                runID: "run-markdown",
                artifacts: [artifact],
                files: ["report.md": fixture, "objects/report-object": staleObject]
            )
            let repository = RunRepository(root: sandbox)

            let descriptor = try repository.artifactDescriptor(
                artifactID: "artifact-markdown", in: item)
            let payload = try repository.loadPreviewArtifact(descriptor, in: item)

            XCTAssertEqual(descriptor.artifactID, "artifact-markdown")
            XCTAssertEqual(descriptor.name, "report.md")
            guard case let .markdown(text) = payload else {
                return XCTFail("Expected inert Markdown")
            }
            XCTAssertEqual(text, String(decoding: fixture, as: UTF8.self))
            XCTAssertTrue(text.contains("<script>"))
            XCTAssertTrue(text.contains("file:///etc/passwd"))
        }

        func testLoadsExactPDFObjectWhenNamedProjectionIsAbsent() throws {
            let sandbox = try makeSandbox("pdf")
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let fixture = try fixtureData("minimal.pdf")
            let artifact = artifactJSON(
                id: "artifact-pdf",
                name: "paper.pdf",
                mediaType: "application/pdf",
                data: fixture,
                objectPath: "objects/sha256/paper"
            )
            let item = try makeRun(
                in: sandbox,
                runID: "run-pdf",
                artifacts: [artifact],
                files: ["objects/sha256/paper": fixture]
            )

            let repository = RunRepository(root: sandbox)
            let descriptor = try repository.artifactDescriptor(artifactID: "artifact-pdf", in: item)
            let payload = try repository.loadPreviewArtifact(descriptor, in: item)

            XCTAssertEqual(payload, .pdf(fixture))
        }

        func testRejectsUnsupportedTypeInvalidUTF8AndMalformedOrActivePDF() throws {
            let invalidUTF8 = Data([0x23, 0x20, 0xFF])
            try assertLoadError(
                id: "artifact-invalid-utf8",
                name: "invalid.md",
                mediaType: "text/markdown",
                data: invalidUTF8,
                expected: .invalidUTF8("invalid.md")
            )
            let fakePDF = Data("not a pdf\n%%EOF\n".utf8)
            try assertLoadError(
                id: "artifact-fake-pdf",
                name: "fake.pdf",
                mediaType: "application/pdf",
                data: fakePDF,
                expected: .invalidPDF("fake.pdf")
            )
            let activePDF = Data(
                "%PDF-1.7\n1 0 obj << /OpenAction 2 0 R /URI (file:///etc/passwd) >> endobj\n%%EOF\n".utf8)
            try assertLoadError(
                id: "artifact-active-pdf",
                name: "active.pdf",
                mediaType: "application/pdf",
                data: activePDF,
                expected: .activeArtifactContent("active.pdf")
            )
            let html = Data("<script>run()</script>".utf8)
            try assertLoadError(
                id: "artifact-html",
                name: "page.html",
                mediaType: "text/html",
                data: html,
                expected: .unsupportedArtifact("page.html", mediaType: "text/html")
            )
        }

        func testRejectsSymlinkHardLinkDirectoryAndOversizedArtifact() throws {
            let fixture = try fixtureData("inert.md")

            for unsafeKind in ["symlink", "hardlink", "directory"] {
                let sandbox = try makeSandbox(unsafeKind)
                defer { try? FileManager.default.removeItem(at: sandbox) }
                let artifact = artifactJSON(
                    id: "artifact-\(unsafeKind)",
                    name: "unsafe.md",
                    mediaType: "text/markdown",
                    data: fixture,
                    objectPath: "objects/unsafe"
                )
                let item = try makeRun(
                    in: sandbox,
                    runID: "run-\(unsafeKind)",
                    artifacts: [artifact],
                    files: [:]
                )
                let target = item.directory.appendingPathComponent("unsafe.md")
                switch unsafeKind {
                case "symlink":
                    let outside = sandbox.appendingPathComponent("outside.md")
                    try fixture.write(to: outside)
                    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
                case "hardlink":
                    let original = sandbox.appendingPathComponent("original.md")
                    try fixture.write(to: original)
                    XCTAssertEqual(link(original.path, target.path), 0)
                default:
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                }

                let repository = RunRepository(root: sandbox)
                let descriptor = try repository.artifactDescriptor(
                    artifactID: "artifact-\(unsafeKind)", in: item)
                XCTAssertThrowsError(try repository.loadPreviewArtifact(descriptor, in: item)) {
                    error in
                    if unsafeKind == "hardlink" {
                        XCTAssertEqual(error as? RunRepositoryError, .hardLinkedFile("unsafe.md"))
                    } else {
                        XCTAssertEqual(error as? RunRepositoryError, .unsafeFile("unsafe.md"))
                    }
                }
            }

            let sandbox = try makeSandbox("oversized")
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let artifact = artifactJSON(
                id: "artifact-large",
                name: "large.md",
                mediaType: "text/markdown",
                data: fixture,
                objectPath: "objects/large"
            )
            let item = try makeRun(
                in: sandbox,
                runID: "run-large",
                artifacts: [artifact],
                files: ["large.md": fixture]
            )
            let repository = RunRepository(
                root: sandbox,
                limits: RunRepositoryLimits(artifactBytes: fixture.count - 1)
            )
            let descriptor = try repository.artifactDescriptor(artifactID: "artifact-large", in: item)
            XCTAssertThrowsError(try repository.loadPreviewArtifact(descriptor, in: item)) { error in
                XCTAssertEqual(
                    error as? RunRepositoryError,
                    .fileTooLarge("large.md", limit: fixture.count - 1)
                )
            }
        }

        func testRejectsSizeChecksumAndManifestIdentityChanges() throws {
            let fixture = try fixtureData("inert.md")
            let sandbox = try makeSandbox("integrity")
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let path = "report.md"

            var artifact = artifactJSON(
                id: "artifact-integrity",
                name: path,
                mediaType: "text/markdown",
                data: fixture,
                objectPath: "objects/report"
            )
            artifact["size"] = .number(Double(fixture.count + 1))
            var item = try makeRun(
                in: sandbox,
                runID: "run-size",
                artifacts: [artifact],
                files: [path: fixture]
            )
            var repository = RunRepository(root: sandbox)
            var descriptor = try repository.artifactDescriptor(
                artifactID: "artifact-integrity", in: item)
            XCTAssertThrowsError(try repository.loadPreviewArtifact(descriptor, in: item)) { error in
                XCTAssertEqual(
                    error as? RunRepositoryError,
                    .artifactSizeMismatch("report.md", declared: fixture.count + 1, actual: fixture.count)
                )
            }

            let checksumRoot = try makeSandbox("checksum")
            defer { try? FileManager.default.removeItem(at: checksumRoot) }
            artifact["size"] = .number(Double(fixture.count))
            artifact["sha256"] = .string(String(repeating: "0", count: 64))
            item = try makeRun(
                in: checksumRoot,
                runID: "run-checksum",
                artifacts: [artifact],
                files: [path: fixture]
            )
            repository = RunRepository(root: checksumRoot)
            descriptor = try repository.artifactDescriptor(artifactID: "artifact-integrity", in: item)
            XCTAssertThrowsError(try repository.loadPreviewArtifact(descriptor, in: item)) { error in
                XCTAssertEqual(error as? RunRepositoryError, .artifactChecksumMismatch("report.md"))
            }

            let changedRoot = try makeSandbox("changed")
            defer { try? FileManager.default.removeItem(at: changedRoot) }
            var original = artifactJSON(
                id: "artifact-integrity",
                name: path,
                mediaType: "text/markdown",
                data: fixture,
                objectPath: "objects/report"
            )
            item = try makeRun(
                in: changedRoot,
                runID: "run-changed",
                artifacts: [original],
                files: [path: fixture]
            )
            repository = RunRepository(root: changedRoot)
            descriptor = try repository.artifactDescriptor(artifactID: "artifact-integrity", in: item)
            original["name"] = .string("replacement.md")
            try writeManifest(runDirectory: item.directory, runID: item.runID, artifacts: [original])
            XCTAssertThrowsError(try repository.loadPreviewArtifact(descriptor, in: item)) { error in
                XCTAssertEqual(error as? RunRepositoryError, .artifactChanged("artifact-integrity"))
            }
        }

        func testRejectsDuplicateArtifactIdentityAndRunOutsideRoot() throws {
            let fixture = try fixtureData("inert.md")
            let sandbox = try makeSandbox("duplicates")
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let artifact = artifactJSON(
                id: "artifact-duplicate",
                name: "report.md",
                mediaType: "text/markdown",
                data: fixture,
                objectPath: "objects/report"
            )
            let item = try makeRun(
                in: sandbox,
                runID: "run-duplicate",
                artifacts: [artifact, artifact],
                files: ["report.md": fixture]
            )
            XCTAssertThrowsError(
                try RunRepository(root: sandbox).artifactDescriptor(
                    artifactID: "artifact-duplicate", in: item)
            ) { error in
                XCTAssertEqual(error as? RunRepositoryError, .duplicateArtifactID("artifact-duplicate"))
            }

            let otherRoot = try makeSandbox("other-root")
            defer { try? FileManager.default.removeItem(at: otherRoot) }
            XCTAssertThrowsError(
                try RunRepository(root: otherRoot).artifactDescriptor(
                    artifactID: "artifact-duplicate", in: item)
            ) { error in
                guard case .outsideRoot = error as? RunRepositoryError else {
                    return XCTFail("Expected outside-root rejection, got \(error)")
                }
            }
        }

        func testRejectsTraversalAndSymlinkedObjectPathComponents() throws {
            let fixture = try fixtureData("inert.md")
            let traversalRoot = try makeSandbox("traversal")
            defer { try? FileManager.default.removeItem(at: traversalRoot) }
            var traversal = artifactJSON(
                id: "artifact-traversal",
                name: "missing.md",
                mediaType: "text/markdown",
                data: fixture,
                objectPath: "objects/content"
            )
            traversal["object_path"] = .string("../outside.md")
            let traversalItem = try makeRun(
                in: traversalRoot,
                runID: "run-traversal",
                artifacts: [traversal],
                files: [:]
            )
            XCTAssertThrowsError(
                try RunRepository(root: traversalRoot).artifactDescriptor(
                    artifactID: "artifact-traversal", in: traversalItem)
            ) { error in
                XCTAssertEqual(
                    error as? RunRepositoryError,
                    .invalidArtifactMetadata("artifact-traversal")
                )
            }

            let symlinkRoot = try makeSandbox("symlink-component")
            defer { try? FileManager.default.removeItem(at: symlinkRoot) }
            let artifact = artifactJSON(
                id: "artifact-component",
                name: "missing.md",
                mediaType: "text/markdown",
                data: fixture,
                objectPath: "objects/link/content.md"
            )
            let item = try makeRun(
                in: symlinkRoot,
                runID: "run-component",
                artifacts: [artifact],
                files: [:]
            )
            let outside = symlinkRoot.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try fixture.write(to: outside.appendingPathComponent("content.md"))
            let objects = item.directory.appendingPathComponent("objects", isDirectory: true)
            try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(
                at: objects.appendingPathComponent("link"),
                withDestinationURL: outside
            )
            let repository = RunRepository(root: symlinkRoot)
            let descriptor = try repository.artifactDescriptor(
                artifactID: "artifact-component", in: item)
            XCTAssertThrowsError(try repository.loadPreviewArtifact(descriptor, in: item)) { error in
                XCTAssertEqual(error as? RunRepositoryError, .unsafeFile("missing.md"))
            }
        }

        private func assertLoadError(
            id: String,
            name: String,
            mediaType: String,
            data: Data,
            expected: RunRepositoryError
        ) throws {
            let sandbox = try makeSandbox(id)
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let artifact = artifactJSON(
                id: id,
                name: name,
                mediaType: mediaType,
                data: data,
                objectPath: "objects/content"
            )
            let item = try makeRun(
                in: sandbox,
                runID: "run-\(id)",
                artifacts: [artifact],
                files: [name: data]
            )
            let repository = RunRepository(root: sandbox)
            let descriptor = try repository.artifactDescriptor(artifactID: id, in: item)
            XCTAssertThrowsError(try repository.loadPreviewArtifact(descriptor, in: item)) { error in
                XCTAssertEqual(error as? RunRepositoryError, expected)
            }
        }

        private func fixtureData(_ name: String) throws -> Data {
            let directory = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/ArtifactPreview", isDirectory: true)
            return try Data(contentsOf: directory.appendingPathComponent(name))
        }

        private func makeSandbox(_ name: String) throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "OpenScienceArtifactPreview-\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            return root
        }

        private func makeRun(
            in root: URL,
            runID: String,
            artifacts: [[String: JSONValue]],
            files: [String: Data]
        ) throws -> RunListItem {
            let directory = root.appendingPathComponent(runID, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try writeManifest(runDirectory: directory, runID: runID, artifacts: artifacts)
            for (relativePath, data) in files {
                let target = directory.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target)
            }
            return RunListItem(
                runID: runID,
                directory: directory,
                question: "Preview artifact",
                status: .completed,
                updatedAt: .distantPast,
                sourceCount: 0,
                evidenceCount: 0,
                claimCount: 0
            )
        }

        private func writeManifest(
            runDirectory: URL,
            runID: String,
            artifacts: [[String: JSONValue]]
        ) throws {
            let manifest = JSONValue.object([
                "run_id": .string(runID),
                "status": .string("completed"),
                "artifacts": .array(artifacts.map(JSONValue.object)),
            ])
            try JSONEncoder().encode(manifest).write(
                to: runDirectory.appendingPathComponent("manifest.json"))
        }

        private func artifactJSON(
            id: String,
            name: String,
            mediaType: String,
            data: Data,
            objectPath: String
        ) -> [String: JSONValue] {
            [
                "artifact_id": .string(id),
                "name": .string(name),
                "media_type": .string(mediaType),
                "sha256": .string(digest(data)),
                "size": .number(Double(data.count)),
                "object_path": .string(objectPath),
            ]
        }

        private func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
#endif
