from __future__ import annotations

from datetime import UTC, datetime, timedelta

from openscience_agent.adapters.model import ExtractiveSynthesizer
from openscience_agent.domain import (
    ClaimKind,
    PolicyDecision,
    PolicyOutcome,
    RiskLevel,
    SearchRequest,
    SourceCandidate,
    ToolContext,
)
from openscience_agent.evidence import extract_evidence, merge_source_candidates


def _allow(*args: object, **kwargs: object) -> PolicyDecision:
    descriptor = args[0]
    return PolicyDecision(
        capability=descriptor.name,
        action=str(args[1]),
        target=str(kwargs.get("target", "")),
        risk=RiskLevel.LOCAL_READ,
        outcome=PolicyOutcome.ALLOW,
        reason="test",
    )


def _context() -> ToolContext:
    return ToolContext(
        deadline=datetime.now(UTC) + timedelta(minutes=1),
        remaining_network_requests=0,
        authorize=_allow,
        user_agent="test/1",
    )


def test_extract_evidence_and_synthesis_are_deterministic() -> None:
    sources = merge_source_candidates(
        [
            SourceCandidate(
                provider="fixture",
                provider_id="one",
                title="Transparent research workflows",
                abstract_or_excerpt=(
                    "Unrelated sentence. Transparent workflows preserve computational evidence."
                ),
                retrieved_at="2026-08-12T00:00:00Z",
            )
        ]
    )
    evidence = extract_evidence("How do workflows preserve computational evidence?", sources)

    first = ExtractiveSynthesizer().synthesize(
        SearchRequest("How do workflows preserve computational evidence?"),
        sources,
        evidence,
        _context(),
    )
    second = ExtractiveSynthesizer().synthesize({}, sources, evidence, _context())

    assert evidence[0].passage == "Transparent workflows preserve computational evidence."
    assert first == second
    assert first[0].kind is ClaimKind.SOURCED_FACT
    assert first[0].evidence_ids == (evidence[0].evidence_id,)
