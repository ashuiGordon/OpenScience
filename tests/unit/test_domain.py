from __future__ import annotations

import json
from dataclasses import replace

import pytest

from openscience_agent.domain import (
    ArtifactRecord,
    CapabilityDescriptor,
    CapabilityKind,
    Claim,
    ClaimKind,
    EvidenceRecord,
    EvidenceStance,
    PlanStatus,
    PlanStep,
    ResearchPlan,
    ResearchRequest,
    RetrievalRecord,
    RiskLevel,
    RunLimits,
    SourceRecord,
    SourceStatus,
    canonical_json,
    sha256_json,
)
from openscience_agent.errors import ValidationError

FIXED_TIME = "2026-08-12T09:30:00Z"


def test_canonical_json_is_unicode_stable_and_rejects_non_json_values() -> None:
    first = {"z": [3, 2], "question": "可重复吗？", "nested": {"b": True, "a": None}}
    second = {"nested": {"a": None, "b": True}, "question": "可重复吗？", "z": [3, 2]}

    assert canonical_json(first) == canonical_json(second)
    assert "可重复吗" in canonical_json(first)
    assert sha256_json(first) == sha256_json(second)
    assert len(sha256_json(first)) == 64
    with pytest.raises((TypeError, ValueError)):
        canonical_json({"bad": float("nan")})


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("max_steps", 0),
        ("max_records", -1),
        ("max_network_requests", True),
        ("timeout_seconds", 86_401),
    ],
)
def test_run_limits_reject_non_positive_or_unbounded_values(field: str, value: object) -> None:
    values: dict[str, object] = {
        "max_steps": 20,
        "max_records": 50,
        "max_network_requests": 10,
        "timeout_seconds": 300,
    }
    values[field] = value
    with pytest.raises(ValidationError):
        RunLimits(**values)  # type: ignore[arg-type]


def test_run_limits_allow_zero_network_requests_for_offline_runs() -> None:
    assert RunLimits(max_network_requests=0).max_network_requests == 0


def test_request_round_trip_has_stable_identity_and_hash() -> None:
    request = ResearchRequest(
        question="What practices make computational research reproducible?",
        scope="Peer-reviewed workflow studies",
        constraints=("English language",),
        assumptions=("Metadata are incomplete",),
        source_names=("fixture.alpha", "fixture.beta"),
        limits=RunLimits(max_records=12),
        created_at=FIXED_TIME,
    )

    encoded = request.to_json()
    restored = ResearchRequest.from_json(encoded)

    assert restored == request
    assert restored.to_dict() == request.to_dict()
    assert json.loads(encoded)["limits"]["max_records"] == 12
    assert request.hash == sha256_json(request.to_dict())


def test_request_rejects_short_questions_and_duplicate_sources() -> None:
    with pytest.raises(ValidationError, match="question"):
        ResearchRequest(question="Too short")
    with pytest.raises(ValidationError, match="source_names"):
        ResearchRequest(
            question="This research question is sufficiently long.",
            source_names=("fixture", "fixture"),
        )


def test_plan_is_a_valid_acyclic_graph_and_enforces_terminal_status() -> None:
    discover = PlanStep(
        step_id="discover",
        title="Discover",
        purpose="Find relevant records",
        capability="fixture.search",
        completion_condition="Search results recorded",
    )
    synthesize = PlanStep(
        step_id="synthesize",
        title="Synthesize",
        purpose="Create linked claims",
        capability="extractive.synthesize",
        dependencies=("discover",),
        completion_condition="Claims recorded",
    )
    plan = ResearchPlan(steps=(discover, synthesize), created_at=FIXED_TIME)

    assert ResearchPlan.from_json(plan.to_json()) == plan
    assert (
        discover.transition(PlanStatus.RUNNING).transition(PlanStatus.COMPLETED).status
        is PlanStatus.COMPLETED
    )
    with pytest.raises(ValidationError, match="terminal"):
        replace(discover, status=PlanStatus.COMPLETED).transition(PlanStatus.RUNNING)
    with pytest.raises(ValidationError, match="unknown dependency"):
        ResearchPlan(steps=(replace(synthesize, dependencies=("missing",)),))
    with pytest.raises(ValidationError, match="cycle"):
        ResearchPlan(
            steps=(
                replace(discover, dependencies=("synthesize",)),
                synthesize,
            )
        )


def test_request_and_plan_reject_ids_not_bound_to_their_content() -> None:
    with pytest.raises(ValidationError, match="request_id"):
        ResearchRequest(
            question="What practices make computational research reproducible?",
            request_id="request-stale",
            created_at=FIXED_TIME,
        )
    step = PlanStep(
        step_id="discover",
        title="Discover",
        purpose="Find relevant records",
        capability="fixture.search",
        completion_condition="Search results recorded",
    )
    with pytest.raises(ValidationError, match="plan_id"):
        ResearchPlan(steps=(step,), plan_id="plan-stale", created_at=FIXED_TIME)


def test_capability_descriptor_is_typed_and_json_compatible() -> None:
    descriptor = CapabilityDescriptor(
        name="fixture.alpha",
        version="1.2.0",
        kind=CapabilityKind.SOURCE,
        risk=RiskLevel.LOCAL_READ,
        input_schema={"type": "object"},
        output_schema={"type": "array"},
        permissions=("filesystem.read",),
    )

    restored = CapabilityDescriptor.from_dict(descriptor.to_dict())

    assert restored == descriptor
    assert restored.kind is CapabilityKind.SOURCE
    assert restored.risk is RiskLevel.LOCAL_READ
    with pytest.raises(ValidationError, match="schema"):
        CapabilityDescriptor(
            name="bad.provider",
            version="1",
            kind="source",
            risk="local_read",
            input_schema={"bad": object()},
        )


def test_source_evidence_claim_and_artifact_round_trip() -> None:
    retrieval = RetrievalRecord(
        provider="fixture.alpha",
        query="reproducibility",
        retrieved_at=FIXED_TIME,
        url="https://example.test/work/1",
        response_hash="a" * 64,
    )
    source = SourceRecord(
        canonical_id="doi:10.1234/example",
        title="Reproducible Workflows",
        source_type="article",
        providers=("fixture.alpha",),
        identifiers={"DOI": "10.1234/example"},
        authors=("A. Researcher",),
        publication_date="2025-06-01",
        abstract_or_excerpt="The workflow records its inputs and environment.",
        landing_url="https://example.test/work/1",
        license="CC-BY-4.0",
        status=SourceStatus.ACTIVE,
        retrievals=(retrieval,),
    )
    evidence = EvidenceRecord(
        source_id=source.source_id,
        passage="The workflow records its inputs and environment.",
        locator="abstract:sentence:1",
        relevance=0.95,
        stance=EvidenceStance.SUPPORTS,
        created_by_step="extract",
        license=source.license,
    )
    claim = Claim(
        text="The evaluated workflow records inputs and environments.",
        kind=ClaimKind.SOURCED_FACT,
        evidence_ids=(evidence.evidence_id,),
        confidence=0.8,
        created_by="extractive/1.0",
    )
    artifact = ArtifactRecord(
        name="report.md",
        media_type="text/markdown",
        sha256="b" * 64,
        size=42,
        object_path="objects/sha256/bb/example",
        produced_by_step="report",
        input_ids=(evidence.evidence_id,),
        created_at=FIXED_TIME,
    )

    assert SourceRecord.from_json(source.to_json()) == source
    assert EvidenceRecord.from_json(evidence.to_json()) == evidence
    assert Claim.from_json(claim.to_json()) == claim
    assert ArtifactRecord.from_json(artifact.to_json()) == artifact
    assert source.source_id.startswith("source-")
    assert evidence.evidence_id.startswith("evidence-")
    assert claim.claim_id.startswith("claim-")
    assert artifact.artifact_id.startswith("artifact-")
    assert source.identifiers == {"doi": "10.1234/example"}


def test_scientific_records_reject_invalid_or_unsupported_state() -> None:
    with pytest.raises(ValidationError, match="relevance"):
        EvidenceRecord(
            source_id="source-a",
            passage="A concrete observation.",
            locator="p. 1",
            relevance=1.1,
            stance=EvidenceStance.SUPPORTS,
            created_by_step="extract",
        )
    with pytest.raises(ValidationError, match="evidence"):
        Claim(
            text="An externally verifiable assertion.",
            kind=ClaimKind.SOURCED_FACT,
            created_by="fixture/1",
        )
    with pytest.raises(ValidationError, match="sha256"):
        ArtifactRecord(
            name="report.md",
            media_type="text/markdown",
            sha256="not-a-hash",
            size=1,
            object_path="objects/bad",
            produced_by_step="report",
        )
