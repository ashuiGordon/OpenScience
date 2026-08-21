from __future__ import annotations

import os
from datetime import UTC, datetime, timedelta

import pytest

from openscience_agent.adapters.crossref import CrossrefSourceProvider
from openscience_agent.adapters.model import OpenAICompatibleSynthesizer
from openscience_agent.adapters.openalex import OpenAlexSourceProvider
from openscience_agent.domain import (
    EvidenceRecord,
    EvidenceStance,
    SearchRequest,
    SourceRecord,
    ToolContext,
)
from openscience_agent.policy import PolicyEngine


def _live_context() -> ToolContext:
    if os.environ.get("OPENSCIENCE_RUN_LIVE_TESTS") != "1":
        pytest.skip("set OPENSCIENCE_RUN_LIVE_TESTS=1 to opt in to live provider smoke tests")
    return ToolContext(
        deadline=datetime.now(UTC) + timedelta(seconds=30),
        remaining_network_requests=2,
        authorize=PolicyEngine(allow_network=True).evaluate,
        user_agent="openscience-agent-live-smoke/0.1",
    )


def _contact_email() -> str:
    value = os.environ.get("OPENSCIENCE_LIVE_EMAIL", "").strip()
    if not value:
        pytest.skip("set OPENSCIENCE_LIVE_EMAIL to a real contact address for live API etiquette")
    return value


def _required_environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        pytest.skip(f"set {name} to opt in to the live model smoke test")
    return value


@pytest.mark.live
def test_openalex_live_smoke_is_explicitly_opt_in() -> None:
    records = OpenAlexSourceProvider(mailto=_contact_email(), timeout=10).search(
        SearchRequest("computational reproducibility", limit=1), _live_context()
    )

    assert len(records) <= 1
    assert all(item.provider == "openalex" and item.response_hash for item in records)


@pytest.mark.live
def test_crossref_live_smoke_is_explicitly_opt_in() -> None:
    records = CrossrefSourceProvider(mailto=_contact_email(), timeout=10).search(
        SearchRequest("computational reproducibility", limit=1), _live_context()
    )

    assert len(records) <= 1
    assert all(item.provider == "crossref" and item.response_hash for item in records)


@pytest.mark.live
def test_openai_compatible_model_live_smoke_is_explicitly_opt_in() -> None:
    source = SourceRecord(
        canonical_id="doi:10.0000/live-smoke",
        title="Synthetic public live-smoke source",
        source_type="article",
        providers=("live-smoke",),
    )
    evidence = EvidenceRecord(
        source_id=source.source_id,
        passage="Recorded workflows retain provenance.",
        locator="synthetic:sentence-1",
        relevance=1.0,
        stance=EvidenceStance.SUPPORTS,
        created_by_step="extract",
    )
    provider = OpenAICompatibleSynthesizer(
        endpoint=_required_environment("OPENSCIENCE_LIVE_MODEL_ENDPOINT"),
        model=_required_environment("OPENSCIENCE_LIVE_MODEL_NAME"),
        api_key=_required_environment("OPENSCIENCE_LIVE_MODEL_API_KEY"),
        timeout=20,
    )

    claims = provider.synthesize(
        {"question": "What retains provenance?"},
        [source],
        [evidence],
        _live_context(),
    )

    assert all(
        claim.kind.value != "sourced_fact" or claim.text == evidence.passage for claim in claims
    )
