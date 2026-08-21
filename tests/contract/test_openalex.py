from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any
from urllib.parse import parse_qs, urlsplit

import pytest

from openscience_agent.adapters.openalex import OpenAlexSourceProvider
from openscience_agent.domain import (
    PolicyDecision,
    PolicyOutcome,
    RiskLevel,
    SearchRequest,
    ToolContext,
)
from openscience_agent.errors import LimitExceededError, ProviderError, RunCancelledError


def _context() -> ToolContext:
    def allow(descriptor: Any, action: str, **kwargs: Any) -> PolicyDecision:
        return PolicyDecision(
            capability=descriptor.name,
            action=action,
            target=kwargs.get("target", ""),
            risk=RiskLevel.NETWORK_READ,
            outcome=PolicyOutcome.ALLOW,
            reason="test",
        )

    return ToolContext(
        deadline=datetime.now(UTC) + timedelta(minutes=1),
        remaining_network_requests=1,
        authorize=allow,
        user_agent="test-client/1",
    )


def test_openalex_maps_metadata_and_sends_identity() -> None:
    observed: dict[str, Any] = {}

    def transport(url: str, headers: dict[str, str], timeout: float) -> dict[str, Any]:
        observed.update(url=url, headers=headers, timeout=timeout)
        return {
            "results": [
                {
                    "id": "https://openalex.org/W123",
                    "doi": "https://doi.org/10.1/ABC",
                    "title": "Open evidence",
                    "publication_date": "2025-01-02",
                    "type": "article",
                    "is_retracted": True,
                    "authorships": [{"author": {"display_name": "Ada Researcher"}}],
                    "primary_location": {
                        "landing_page_url": "https://example.test/work",
                        "license": "cc-by",
                    },
                    "abstract_inverted_index": {"Evidence": [1], "Open": [0]},
                }
            ]
        }

    result = OpenAlexSourceProvider(
        api_key="oa-key",
        mailto="researcher@example.test",
        timeout=2,
        transport=transport,
    ).search(SearchRequest("open evidence", 2), _context())

    query = parse_qs(urlsplit(observed["url"]).query)
    assert query["api_key"] == ["oa-key"]
    assert query["mailto"] == ["researcher@example.test"]
    assert observed["headers"]["User-Agent"].startswith("test-client/1")
    assert result[0].authors == ("Ada Researcher",)
    assert result[0].abstract_or_excerpt == "Open Evidence"
    assert result[0].status.value == "retracted"


def test_openalex_timeout_is_typed() -> None:
    def timeout(*args: object) -> bytes:
        raise TimeoutError

    with pytest.raises(ProviderError, match="timed out"):
        OpenAlexSourceProvider(transport=timeout).search(SearchRequest("evidence"), _context())


def test_openalex_zero_budget_never_calls_transport() -> None:
    calls = 0

    def transport(*args: object) -> dict[str, object]:
        nonlocal calls
        calls += 1
        return {"results": []}

    base = _context()
    context = ToolContext(
        deadline=base.deadline,
        remaining_network_requests=0,
        authorize=base.authorize,
        user_agent=base.user_agent,
    )

    with pytest.raises(LimitExceededError, match="budget"):
        OpenAlexSourceProvider(transport=transport).search(SearchRequest("evidence"), context)

    assert calls == 0


def test_openalex_timeout_retries_once_when_budget_allows() -> None:
    sequence: list[str] = []
    remaining = 2

    def allow(descriptor: Any, action: str, **kwargs: Any) -> PolicyDecision:
        sequence.append(f"authorize:{kwargs['target']}")
        return PolicyDecision(
            capability=descriptor.name,
            action=action,
            target=kwargs["target"],
            risk=RiskLevel.NETWORK_READ,
            outcome=PolicyOutcome.ALLOW,
            reason="test",
        )

    def consume(target: str) -> int:
        nonlocal remaining
        sequence.append(f"consume:{target}")
        remaining -= 1
        return remaining

    def transport(*args: object) -> dict[str, object]:
        sequence.append("transport")
        if sequence.count("transport") == 1:
            raise TimeoutError
        return {"results": []}

    context = ToolContext(
        deadline=datetime.now(UTC) + timedelta(minutes=1),
        remaining_network_requests=2,
        authorize=allow,
        user_agent="test-client/1",
        network_consumer=consume,
    )
    result = OpenAlexSourceProvider(
        transport=transport, sleeper=lambda _: None, retry_delay=0
    ).search(SearchRequest("evidence"), context)

    assert result == []
    assert sequence == [
        "authorize:https://api.openalex.org",
        "consume:https://api.openalex.org",
        "transport",
        "authorize:https://api.openalex.org",
        "consume:https://api.openalex.org",
        "transport",
    ]


def test_openalex_does_not_retry_without_a_second_request_budget() -> None:
    calls = 0

    def transport(*args: object) -> bytes:
        nonlocal calls
        calls += 1
        raise TimeoutError

    with pytest.raises(ProviderError, match="timed out"):
        OpenAlexSourceProvider(transport=transport, sleeper=lambda _: None, retry_delay=0).search(
            SearchRequest("evidence"), _context()
        )

    assert calls == 1


def test_openalex_obeys_retry_after_seconds() -> None:
    calls = 0
    sleeps: list[float] = []

    def transport(*args: object) -> dict[str, object]:
        nonlocal calls
        calls += 1
        if calls == 1:
            raise ProviderError("rate limited", context={"status": 429, "retry_after": "3"})
        return {"results": []}

    base = _context()
    context = ToolContext(
        deadline=base.deadline,
        remaining_network_requests=2,
        authorize=base.authorize,
        user_agent=base.user_agent,
    )

    result = OpenAlexSourceProvider(transport=transport, sleeper=sleeps.append).search(
        SearchRequest("evidence"), context
    )

    assert result == []
    assert calls == 2
    assert sleeps == [3.0]


def test_openalex_does_not_wait_or_retry_beyond_deadline() -> None:
    calls = 0
    sleeps: list[float] = []

    def transport(*args: object) -> dict[str, object]:
        nonlocal calls
        calls += 1
        raise ProviderError("rate limited", context={"status": 429, "retry_after": "60"})

    base = _context()
    context = ToolContext(
        deadline=datetime.now(UTC) + timedelta(seconds=1),
        remaining_network_requests=2,
        authorize=base.authorize,
        user_agent=base.user_agent,
    )

    with pytest.raises(ProviderError, match="rate limited"):
        OpenAlexSourceProvider(transport=transport, sleeper=sleeps.append).search(
            SearchRequest("evidence"), context
        )

    assert calls == 1
    assert sleeps == []


def test_openalex_uses_typed_cancellation() -> None:
    base = _context()
    context = ToolContext(
        deadline=base.deadline,
        remaining_network_requests=1,
        authorize=base.authorize,
        user_agent=base.user_agent,
        is_cancelled=lambda: True,
    )

    with pytest.raises(RunCancelledError):
        OpenAlexSourceProvider(transport=lambda *args: {"results": []}).search(
            SearchRequest("evidence"), context
        )
