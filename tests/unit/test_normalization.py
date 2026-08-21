from __future__ import annotations

from openscience_agent.domain import SourceCandidate, SourceStatus
from openscience_agent.evidence import merge_source_candidates, normalize_identifier


def test_normalize_common_identifiers() -> None:
    assert normalize_identifier("doi", "https://doi.org/10.1000/ABC") == "10.1000/abc"
    assert normalize_identifier("arxiv", "arXiv:2401.00001v3") == "2401.00001"
    assert normalize_identifier("pmid", "https://pubmed.ncbi.nlm.nih.gov/12345/") == "12345"
    assert normalize_identifier("openalex", "https://openalex.org/w123") == "W123"


def test_merge_deduplicates_doi_and_keeps_provenance_and_retraction() -> None:
    candidates = [
        SourceCandidate(
            provider="openalex",
            provider_id="W1",
            title="A study",
            authors=("A. Author",),
            abstract_or_excerpt="short",
            identifiers={"doi": "https://doi.org/10.1/ABC"},
            status=SourceStatus.ACTIVE,
            retrieved_at="2026-08-12T00:00:00Z",
        ),
        SourceCandidate(
            provider="crossref",
            provider_id="10.1/abc",
            title="A study with details",
            authors=("B. Author",),
            abstract_or_excerpt="A longer evidence-bearing abstract.",
            identifiers={"doi": "10.1/abc"},
            status=SourceStatus.RETRACTED,
            retrieved_at="2026-08-12T00:00:01Z",
        ),
    ]

    merged = merge_source_candidates(candidates)

    assert len(merged) == 1
    assert merged[0].canonical_id == "doi:10.1/abc"
    assert merged[0].providers == ("crossref", "openalex")
    assert len(merged[0].retrievals) == 2
    assert merged[0].status is SourceStatus.RETRACTED
    assert merged[0].abstract_or_excerpt.startswith("A longer")
