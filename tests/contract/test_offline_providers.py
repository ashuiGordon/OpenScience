from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from openscience_agent.adapters.fixtures import FixtureSourceProvider, load_fixture_providers
from openscience_agent.domain import (
    PolicyDecision,
    PolicyOutcome,
    RiskLevel,
    SearchRequest,
    ToolContext,
)
from openscience_agent.errors import RunCancelledError


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


def test_fixture_provider_is_deterministic_and_contract_compatible() -> None:
    provider = FixtureSourceProvider(
        "fixture-alpha",
        [
            {"id": "less", "title": "Unrelated record", "abstract": "nothing"},
            {
                "id": "best",
                "title": "Reproducible computational research",
                "abstract": "Workflows preserve evidence.",
                "identifiers": {"doi": "10.1/example"},
            },
        ],
    )
    request = SearchRequest(query="reproducible research", limit=1)

    first = provider.search(request, _context())
    second = provider.search(request, _context())

    assert provider.descriptor().name == "fixture-alpha"
    assert first == second
    assert first[0].provider_id == "best"
    assert first[0].query == request.query


def test_fixture_corpus_loads_multiple_provider_instances(tmp_path: Path) -> None:
    corpus = tmp_path / "corpus.json"
    corpus.write_text(
        json.dumps(
            {
                "providers": {
                    "fixture-a": [{"id": "a", "title": "Alpha record"}],
                    "fixture-b": [{"id": "b", "title": "Beta record"}],
                }
            }
        )
    )

    providers = load_fixture_providers(corpus)

    assert list(providers) == ["fixture-a", "fixture-b"]
    assert (
        providers["fixture-b"].search(SearchRequest("Beta", 2), _context())[0].provider
        == "fixture-b"
    )


def test_fixture_provider_uses_typed_cancellation() -> None:
    provider = FixtureSourceProvider("fixture", [{"id": "one", "title": "Evidence"}])
    context = ToolContext(
        deadline=datetime.now(UTC) + timedelta(minutes=1),
        remaining_network_requests=0,
        authorize=_allow,
        user_agent="test/1",
        is_cancelled=lambda: True,
    )

    with pytest.raises(RunCancelledError):
        provider.search(SearchRequest("evidence"), context)
