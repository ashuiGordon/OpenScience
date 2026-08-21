#if canImport(XCTest)
    import XCTest

    @testable import OpenScienceCore

    final class JSONDecodingTests: XCTestCase {
        func testDecodesRunOutcome() throws {
            let text =
                #"{"claims":2,"evidence":3,"limitations":[],"manifest":"/tmp/run/manifest.json","report":"/tmp/run/report.md","run_directory":"/tmp/run","run_id":"run-123","sources":1,"status":"completed"}"#
            let outcome = try CLIResponseDecoder.decode(RunOutcome.self, from: text)
            XCTAssertEqual(outcome.runID, "run-123")
            XCTAssertEqual(outcome.status, "completed")
            XCTAssertEqual(outcome.evidence, 3)
        }

        func testDecodesRealPlanEnvelope() throws {
            let text =
                #"{"request":{"question":"Q"},"plan":{"plan_id":"plan-1","request_id":"request-1","status":"pending","steps":[{"capability":"research.sources","completion_condition":"Sources found","dependencies":[],"purpose":"Find evidence","status":"pending","step_id":"discover","title":"Discover"}]}}"#
            let envelope = try CLIResponseDecoder.decode(PlanEnvelope.self, from: text)
            XCTAssertEqual(envelope.plan.planID, "plan-1")
            XCTAssertEqual(envelope.plan.steps.first?.stepID, "discover")
            XCTAssertEqual(envelope.plan.steps.first?.completionCondition, "Sources found")
        }

        func testDecodesErrorEnvelopeAndArbitraryJSON() throws {
            let text = #"{"error":{"code":"usage.invalid","message":"bad input","type":"CLIError"}}"#
            let envelope = try CLIResponseDecoder.decode(CLIErrorEnvelope.self, from: text)
            XCTAssertEqual(envelope.error.code, "usage.invalid")
            let value = try CLIResponseDecoder.decodeJSON(
                from: #"{"array":[true,null,2],"nested":{"name":"OpenScience"}}"#
            )
            XCTAssertEqual(value["nested"]?["name"]?.stringValue, "OpenScience")
            XCTAssertEqual(value["array"]?.arrayValue?.count, 3)
        }

        func testDecodesSourceRetrievalAttributionAndEvidenceIdentity() throws {
            let source = try CLIResponseDecoder.decode(
                SourceRecord.self,
                from:
                    #"{"authors":["Researcher"],"canonical_id":"doi:10.1/example","content_hash":"abc","identifiers":{"doi":"10.1/example"},"providers":["fixture"],"retrievals":[{"provider":"fixture","query":"Q","response_hash":"def","retrieval_id":"retrieval-1","retrieved_at":"2026-01-01T00:00:00Z","url":"https://example.org/source"}],"source_id":"source-1","status":"active","title":"Example"}"#
            )
            XCTAssertEqual(source.identifiers["doi"], "10.1/example")
            XCTAssertEqual(source.retrievals.first?.retrievedAt, "2026-01-01T00:00:00Z")
            XCTAssertEqual(source.contentHash, "abc")

            let evidence = try CLIResponseDecoder.decode(
                EvidenceRecord.self,
                from:
                    #"{"content_hash":"evidence-hash","created_by_step":"extract","evidence_id":"evidence-1","locator":"abstract","passage":"Exact passage","relevance":1,"source_id":"source-1","stance":"supports"}"#
            )
            XCTAssertEqual(evidence.contentHash, "evidence-hash")
            XCTAssertEqual(evidence.createdByStep, "extract")
        }
    }
#endif
