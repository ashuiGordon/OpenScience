from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from typing import Any
from urllib.request import Request

import pytest

from openscience_agent.adapters.model import OpenAICompatibleSynthesizer
from openscience_agent.adapters.openalex import _NoRedirectHandler
from openscience_agent.domain import (
    ClaimKind,
    EvidenceRecord,
    EvidenceStance,
    PolicyDecision,
    PolicyOutcome,
    RiskLevel,
    SourceRecord,
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
        user_agent="test/1",
    )


def _records() -> tuple[list[SourceRecord], list[EvidenceRecord]]:
    source = SourceRecord(
        canonical_id="doi:10.1/example",
        title="Evidence source",
        source_type="article",
        providers=("fixture",),
    )
    evidence = EvidenceRecord(
        source_id=source.source_id,
        passage="Recorded workflows retain provenance.",
        locator="abstract:sentence-1",
        relevance=1.0,
        stance=EvidenceStance.SUPPORTS,
        created_by_step="extract",
    )
    return [source], [evidence]


def test_model_accepts_strict_json_claims_and_delimits_evidence() -> None:
    sources, evidence = _records()
    observed: dict[str, Any] = {}

    def transport(url: str, headers: dict[str, str], timeout: float, body: bytes) -> dict[str, Any]:
        observed["payload"] = json.loads(body)
        return {
            "claims": [
                {
                    "text": "Recorded workflows retain provenance.",
                    "kind": "sourced_fact",
                    "evidence_ids": [evidence[0].evidence_id],
                    "confidence": 0.9,
                    "limitations": [],
                }
            ]
        }

    result = OpenAICompatibleSynthesizer(
        endpoint="https://model.example.test/v1/chat/completions",
        model="example",
        api_key="secret",
        transport=transport,
    ).synthesize({"question": "What retains provenance?"}, sources, evidence, _context())

    assert result[0].evidence_ids == (evidence[0].evidence_id,)
    assert result[0].kind is ClaimKind.SOURCED_FACT
    user_data = json.loads(observed["payload"]["messages"][1]["content"])
    assert user_data["evidence_records"][0]["passage"] == evidence[0].passage


def test_model_rejects_unknown_evidence_id() -> None:
    sources, evidence = _records()
    provider = OpenAICompatibleSynthesizer(
        endpoint="https://model.example.test/v1/chat/completions",
        model="example",
        api_key="secret",
        transport=lambda *args: {
            "claims": [
                {
                    "text": "Fabricated support",
                    "kind": "sourced_fact",
                    "evidence_ids": ["evidence-does-not-exist"],
                    "confidence": 1,
                    "limitations": [],
                }
            ]
        },
    )

    with pytest.raises(ProviderError, match="unknown evidence"):
        provider.synthesize({}, sources, evidence, _context())


def test_model_zero_budget_never_calls_transport() -> None:
    sources, evidence = _records()
    called = False

    def transport(*args: object) -> dict[str, object]:
        nonlocal called
        called = True
        return {"claims": []}

    base = _context()
    context = ToolContext(
        deadline=base.deadline,
        remaining_network_requests=0,
        authorize=base.authorize,
        user_agent=base.user_agent,
    )
    provider = OpenAICompatibleSynthesizer(
        endpoint="https://model.example.test/v1/chat/completions",
        model="example",
        api_key="secret",
        transport=transport,
    )

    with pytest.raises(LimitExceededError, match="budget"):
        provider.synthesize({}, sources, evidence, context)

    assert called is False


def test_model_redacts_question_and_evidence_before_transport() -> None:
    source = SourceRecord(
        canonical_id="doi:10.1/secret-example",
        title="Credential test",
        source_type="article",
        providers=("fixture",),
    )
    evidence = EvidenceRecord(
        source_id=source.source_id,
        passage="Authorization: Bearer abcdefghijklmnopqrstuvwxyz",
        locator="api_key=do-not-send-this",
        relevance=1.0,
        stance=EvidenceStance.SUPPORTS,
        created_by_step="extract",
    )
    observed_body = b""

    def transport(*args: object) -> dict[str, object]:
        nonlocal observed_body
        observed_body = args[3]  # type: ignore[assignment]
        return {"claims": []}

    provider = OpenAICompatibleSynthesizer(
        endpoint="https://model.example.test/v1/chat/completions",
        model="example",
        api_key="test-transport-secret",
        transport=transport,
    )
    provider.synthesize(
        {"question": "Review this api_key=question-secret"},
        [source],
        [evidence],
        _context(),
    )

    decoded = observed_body.decode("utf-8")
    assert "question-secret" not in decoded
    assert "abcdefghijklmnopqrstuvwxyz" not in decoded
    assert "do-not-send-this" not in decoded
    assert "[REDACTED]" in decoded


def test_model_refuses_local_file_evidence_before_transport() -> None:
    source = SourceRecord(
        canonical_id="file:private-note",
        title="Private note",
        source_type="local-document",
        providers=("local-files",),
        landing_url="file:///private/research/note.md",
    )
    evidence = EvidenceRecord(
        source_id=source.source_id,
        passage="An unpublished observation belongs in the local workspace only.",
        locator="file:sentence:1",
        relevance=1.0,
        stance=EvidenceStance.SUPPORTS,
        created_by_step="extract",
    )
    transport_called = False

    def transport(*args: object) -> dict[str, object]:
        nonlocal transport_called
        transport_called = True
        return {"claims": []}

    provider = OpenAICompatibleSynthesizer(
        endpoint="https://model.example.test/v1/chat/completions",
        model="example",
        api_key="secret",
        transport=transport,
    )

    with pytest.raises(ProviderError, match="refuses local-file evidence"):
        provider.synthesize({}, [source], [evidence], _context())

    assert transport_called is False


def test_model_downgrades_sourced_fact_not_present_in_evidence() -> None:
    sources, evidence = _records()
    provider = OpenAICompatibleSynthesizer(
        endpoint="https://model.example.test/v1/chat/completions",
        model="example",
        api_key="secret",
        transport=lambda *args: {
            "claims": [
                {
                    "text": "A fabricated result not found in the supplied passage.",
                    "kind": "sourced_fact",
                    "evidence_ids": [evidence[0].evidence_id],
                    "confidence": 0.8,
                    "limitations": [],
                }
            ]
        },
    )

    result = provider.synthesize({}, sources, evidence, _context())

    assert result[0].kind is ClaimKind.INFERENCE
    assert "not independently verified" in result[0].limitations[0]


def test_model_downgrades_passage_with_fabricated_suffix() -> None:
    sources, evidence = _records()
    provider = OpenAICompatibleSynthesizer(
        endpoint="https://model.example.test/v1/chat/completions",
        model="example",
        api_key="secret",
        transport=lambda *args: {
            "claims": [
                {
                    "text": evidence[0].passage + " This fabricated result was never observed.",
                    "kind": "sourced_fact",
                    "evidence_ids": [evidence[0].evidence_id],
                    "confidence": 0.8,
                    "limitations": [],
                }
            ]
        },
    )

    result = provider.synthesize({}, sources, evidence, _context())

    assert result[0].kind is ClaimKind.INFERENCE
    assert "not independently verified" in result[0].limitations[0]


def test_model_obeys_retry_after_seconds() -> None:
    sources, evidence = _records()
    calls = 0
    sleeps: list[float] = []

    def transport(*args: object) -> dict[str, object]:
        nonlocal calls
        calls += 1
        if calls == 1:
            raise ProviderError("rate limited", context={"status": 429, "retry_after": "2"})
        return {"claims": []}

    base = _context()
    context = ToolContext(
        deadline=base.deadline,
        remaining_network_requests=2,
        authorize=base.authorize,
        user_agent=base.user_agent,
    )
    provider = OpenAICompatibleSynthesizer(
        endpoint="https://model.example.test/v1/chat/completions",
        model="example",
        api_key="secret",
        transport=transport,
        sleeper=sleeps.append,
    )

    assert provider.synthesize({}, sources, evidence, context) == []
    assert calls == 2
    assert sleeps == [2.0]


def test_model_does_not_retry_past_deadline() -> None:
    sources, evidence = _records()
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
    provider = OpenAICompatibleSynthesizer(
        endpoint="https://model.example.test/v1/chat/completions",
        model="example",
        api_key="secret",
        transport=transport,
        sleeper=sleeps.append,
    )

    with pytest.raises(ProviderError, match="rate limited"):
        provider.synthesize({}, sources, evidence, context)

    assert calls == 1
    assert sleeps == []


def test_model_uses_typed_cancellation_before_retry() -> None:
    sources, evidence = _records()
    cancelled = False
    calls = 0

    def transport(*args: object) -> dict[str, object]:
        nonlocal cancelled, calls
        calls += 1
        cancelled = True
        raise ProviderError("temporary", context={"retryable": True})

    base = _context()
    context = ToolContext(
        deadline=base.deadline,
        remaining_network_requests=2,
        authorize=base.authorize,
        user_agent=base.user_agent,
        is_cancelled=lambda: cancelled,
    )
    provider = OpenAICompatibleSynthesizer(
        endpoint="https://model.example.test/v1/chat/completions",
        model="example",
        api_key="secret",
        transport=transport,
        sleeper=lambda _: None,
    )

    with pytest.raises(RunCancelledError):
        provider.synthesize({}, sources, evidence, context)

    assert calls == 1


def test_model_descriptor_exposes_only_safe_endpoint_and_model_identity() -> None:
    provider = OpenAICompatibleSynthesizer(
        endpoint="https://model.example.test/v1/chat/completions",
        model="research-model-v1",
        api_key="test-api-key-must-not-appear",
        transport=lambda *args: {"claims": []},
    )

    descriptor = provider.descriptor().to_dict()
    serialized = json.dumps(descriptor)

    assert descriptor["input_schema"]["x-openscience-model"] == "research-model-v1"
    assert descriptor["input_schema"]["x-openscience-endpoint-host"] == "model.example.test"
    assert "test-api-key-must-not-appear" not in serialized
    assert "/v1/chat/completions" not in serialized


def test_default_redirect_handler_never_clones_authorization_header() -> None:
    request = Request(
        "https://model.example.test/v1/chat/completions",
        headers={"Authorization": "Bearer credential"},
    )

    redirected = _NoRedirectHandler().redirect_request(
        request,
        None,
        307,
        "Temporary Redirect",
        {},
        "https://attacker.example.test/collect",
    )

    assert redirected is None
