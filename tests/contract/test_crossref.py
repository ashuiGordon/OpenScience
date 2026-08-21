from __future__ import annotations

from datetime import UTC, datetime, timedelta
from email.utils import format_datetime
from typing import Any
from urllib.parse import parse_qs, urlsplit

import pytest

from openscience_agent.adapters.crossref import CrossrefSourceProvider
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


def test_crossref_maps_attribution_polite_identity_and_api_key() -> None:
    observed: dict[str, Any] = {}

    def transport(url: str, headers: dict[str, str], timeout: float) -> dict[str, Any]:
        observed.update(url=url, headers=headers, timeout=timeout)
        return {
            "status": "ok",
            "message": {
                "items": [
                    {
                        "DOI": "10.1/ABC",
                        "URL": "https://doi.org/10.1/ABC",
                        "title": ["Transparent results"],
                        "author": [{"given": "Ada", "family": "Researcher"}],
                        "published": {"date-parts": [[2025, 2, 3]]},
                        "type": "journal-article",
                        "abstract": "<jats:p>Evidence is retained.</jats:p>",
                        "license": [{"URL": "https://creativecommons.org/licenses/by/4.0/"}],
                    }
                ]
            },
        }

    result = CrossrefSourceProvider(
        api_key="crossref-key",
        mailto="researcher@example.test",
        transport=transport,
    ).search(SearchRequest("transparent results", 3), _context())

    query = parse_qs(urlsplit(observed["url"]).query)
    assert query["mailto"] == ["researcher@example.test"]
    assert observed["headers"]["Crossref-Plus-API-Token"] == "Bearer crossref-key"
    assert observed["headers"]["User-Agent"].startswith("test-client/1")
    assert result[0].authors == ("Ada Researcher",)
    assert result[0].publication_date == "2025-02-03"
    assert result[0].abstract_or_excerpt == "Evidence is retained."


def test_crossref_malformed_response_is_typed_failure() -> None:
    with pytest.raises(ProviderError, match="message.items"):
        CrossrefSourceProvider(transport=lambda *args: {"status": "ok"}).search(
            SearchRequest("evidence"), _context()
        )


def test_crossref_zero_budget_never_calls_transport() -> None:
    called = False

    def transport(*args: object) -> dict[str, object]:
        nonlocal called
        called = True
        return {"status": "ok", "message": {"items": []}}

    base = _context()
    context = ToolContext(
        deadline=base.deadline,
        remaining_network_requests=0,
        authorize=base.authorize,
        user_agent=base.user_agent,
    )

    with pytest.raises(LimitExceededError, match="budget"):
        CrossrefSourceProvider(transport=transport).search(SearchRequest("evidence"), context)

    assert called is False


def test_crossref_retries_429_only_once() -> None:
    calls = 0

    def transport(*args: object) -> dict[str, object]:
        nonlocal calls
        calls += 1
        if calls == 1:
            raise ProviderError("rate limited", context={"status": 429})
        return {"status": "ok", "message": {"items": []}}

    base = _context()
    context = ToolContext(
        deadline=base.deadline,
        remaining_network_requests=2,
        authorize=base.authorize,
        user_agent=base.user_agent,
    )
    result = CrossrefSourceProvider(
        transport=transport, sleeper=lambda _: None, retry_delay=0
    ).search(SearchRequest("evidence"), context)

    assert result == []
    assert calls == 2


def test_crossref_obeys_retry_after_http_date() -> None:
    calls = 0
    sleeps: list[float] = []
    retry_at = datetime.now(UTC) + timedelta(seconds=10)

    def transport(*args: object) -> dict[str, object]:
        nonlocal calls
        calls += 1
        if calls == 1:
            raise ProviderError(
                "rate limited",
                context={
                    "status": 429,
                    "retry_after": format_datetime(retry_at, usegmt=True),
                },
            )
        return {"status": "ok", "message": {"items": []}}

    base = _context()
    context = ToolContext(
        deadline=datetime.now(UTC) + timedelta(minutes=1),
        remaining_network_requests=2,
        authorize=base.authorize,
        user_agent=base.user_agent,
    )

    result = CrossrefSourceProvider(transport=transport, sleeper=sleeps.append).search(
        SearchRequest("evidence"), context
    )

    assert result == []
    assert calls == 2
    assert len(sleeps) == 1
    assert 8.0 <= sleeps[0] <= 10.0


def test_crossref_uses_typed_cancellation() -> None:
    base = _context()
    context = ToolContext(
        deadline=base.deadline,
        remaining_network_requests=1,
        authorize=base.authorize,
        user_agent=base.user_agent,
        is_cancelled=lambda: True,
    )

    with pytest.raises(RunCancelledError):
        CrossrefSourceProvider(
            transport=lambda *args: {"status": "ok", "message": {"items": []}}
        ).search(SearchRequest("evidence"), context)
