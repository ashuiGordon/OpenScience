#if canImport(XCTest)
    import XCTest

    @testable import OpenScienceCore

    final class EvidencePreviewTests: XCTestCase {
        func testOneThousandClaimEvidenceSourceLinksResolveExactIDs() throws {
            let fixture = try WorkbenchFixtureFactory.makeEvidenceDetail()
            let detail = RunDetail(
                item: fixture.item,
                reportMarkdown: fixture.reportMarkdown,
                sources: Array(fixture.sources.reversed()),
                evidence: Array(fixture.evidence.reversed()),
                claims: Array(fixture.claims.reversed()),
                manifest: fixture.manifest
            )

            let links = try RunRepository().joinEvidence(in: detail)
            XCTAssertEqual(links.count, 1_000)
            XCTAssertEqual(Set(links.map { $0.claim.claimID }).count, 1_000)
            XCTAssertEqual(Set(links.map { $0.evidence.evidenceID }).count, 1_000)
            XCTAssertEqual(Set(links.map { $0.source.sourceID }).count, 1_000)

            for link in links {
                XCTAssertEqual(link.claim.evidenceIDs, [link.evidence.evidenceID])
                XCTAssertEqual(link.evidence.sourceID, link.source.sourceID)
                XCTAssertEqual(link.claim.text, link.evidence.passage)
                XCTAssertTrue(["supports", "neutral"].contains(link.evidence.stance))
                XCTAssertEqual(link.evidence.license, "CC0-1.0")
                XCTAssertEqual(link.source.status, "active")
                XCTAssertEqual(link.source.license, "CC0-1.0")
                XCTAssertEqual(link.source.authors, ["Fixture Author"])
                XCTAssertEqual(link.source.providers, ["fixture"])
                XCTAssertEqual(link.source.retrievals.count, 1)
                XCTAssertEqual(link.source.retrievals[0].provider, "fixture")
                XCTAssertEqual(link.source.retrievals[0].retrievedAt, "2026-08-27T09:43:00Z")
            }
        }

        func testMissingOrDuplicateEvidenceNeverFallsBackByPosition() throws {
            let fixture = try WorkbenchFixtureFactory.makeEvidenceDetail(count: 3)
            let missing = RunDetail(
                item: fixture.item,
                reportMarkdown: fixture.reportMarkdown,
                sources: fixture.sources,
                evidence: Array(fixture.evidence.dropFirst()),
                claims: fixture.claims,
                manifest: fixture.manifest
            )
            XCTAssertThrowsError(try RunRepository().joinEvidence(in: missing)) { error in
                guard case RunRepositoryError.missingEvidence = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }

            let duplicate = RunDetail(
                item: fixture.item,
                reportMarkdown: fixture.reportMarkdown,
                sources: fixture.sources,
                evidence: fixture.evidence + [fixture.evidence[0]],
                claims: fixture.claims,
                manifest: fixture.manifest
            )
            XCTAssertThrowsError(try RunRepository().joinEvidence(in: duplicate)) { error in
                guard case RunRepositoryError.duplicateID = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }
#endif
