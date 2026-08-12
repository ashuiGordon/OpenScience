from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from openscience_agent.adapters.fixtures import FixtureSourceProvider
from openscience_agent.cli import _orchestrator, main
from openscience_agent.domain import (
    CapabilityDescriptor,
    CapabilityKind,
    ResearchRequest,
    RiskLevel,
    SourceCandidate,
)
from openscience_agent.errors import ProviderError
from openscience_agent.policy import PolicyEngine
from openscience_agent.registry import ProviderRegistry
from openscience_agent.validation import validate_run

QUESTION = "What practices make computational research results easier to reproduce?"


class _FailingSource:
    def descriptor(self) -> CapabilityDescriptor:
        return CapabilityDescriptor(
            name="test.failing-source",
            version="1.0.0",
            kind=CapabilityKind.SOURCE,
            risk=RiskLevel.LOCAL_READ,
            input_schema={"type": "object"},
            output_schema={"type": "array"},
        )

    def search(self, request: Any, context: Any) -> list[SourceCandidate]:
        del request, context
        raise ProviderError("deterministic source failure")


def test_packaged_corpus_produces_a_complete_evidence_backed_run(tmp_path: Path) -> None:
    workspace = tmp_path / "runs"
    exit_code = main(
        [
            "run",
            QUESTION,
            "--fixture",
            "examples/corpus.json",
            "--workspace",
            str(workspace),
            "--yes",
            "--json",
        ]
    )

    assert exit_code == 0
    run = next(workspace.iterdir())
    assert validate_run(run).valid
    manifest = json.loads((run / "manifest.json").read_text())
    report = (run / "report.md").read_text()
    sources = json.loads((run / "sources.json").read_text())
    evidence = json.loads((run / "evidence.json").read_text())
    claims = json.loads((run / "claims.json").read_text())

    assert manifest["status"] == "completed"
    assert len({provider for source in sources for provider in source["providers"]}) >= 2
    assert len(sources) == 3  # the duplicate DOI from two providers is merged
    assert evidence
    assert claims
    for claim in claims:
        if claim["kind"] == "sourced_fact":
            assert claim["evidence_ids"]
            assert all(f"[^{evidence_id}]" in report for evidence_id in claim["evidence_ids"])
    assert "retracted" in report.casefold()
    assert manifest["event_log"]["events"] >= 10


def test_noninteractive_run_without_yes_stops_before_provider_calls(tmp_path: Path) -> None:
    workspace = tmp_path / "runs"
    exit_code = main(
        [
            "run",
            QUESTION,
            "--fixture",
            "examples/corpus.json",
            "--workspace",
            str(workspace),
            "--json",
        ]
    )

    assert exit_code == 0
    run = next(workspace.iterdir())
    manifest = json.loads((run / "manifest.json").read_text())
    events = [json.loads(line) for line in (run / "events.jsonl").read_text().splitlines()]
    assert manifest["status"] == "awaiting_approval"
    assert not any(event["type"].startswith("provider.") for event in events)
    assert json.loads((run / "sources.json").read_text()) == []


def test_local_and_fixture_sources_remain_distinct_in_one_report(tmp_path: Path) -> None:
    workspace = tmp_path / "runs"
    local_root = Path(__file__).parents[1] / "fixtures" / "local_corpus"
    exit_code = main(
        [
            "run",
            QUESTION,
            "--fixture",
            "examples/corpus.json",
            "--local-root",
            str(local_root),
            "--workspace",
            str(workspace),
            "--yes",
            "--json",
        ]
    )
    run = next(workspace.iterdir())
    sources = json.loads((run / "sources.json").read_text())
    report = (run / "report.md").read_text()
    providers = {provider for source in sources for provider in source["providers"]}

    assert exit_code == 0
    assert validate_run(run).valid
    assert "local-files" in providers
    assert {"methods-index", "reproducibility-handbook"} <= providers
    assert "providers: local\\-files" in report
    assert (
        "providers: methods\\-index" in report or "providers: reproducibility\\-handbook" in report
    )


def test_one_source_failure_returns_a_labeled_partial_result_within_30_seconds(
    tmp_path: Path,
) -> None:
    registry = ProviderRegistry()
    registry.register_source(
        FixtureSourceProvider(
            "test.healthy-source",
            [
                SourceCandidate(
                    provider="test.healthy-source",
                    provider_id="one",
                    title="Recorded workflow evidence",
                    abstract_or_excerpt=(
                        "Recorded inputs and outputs make computational work reproducible."
                    ),
                    query=QUESTION,
                )
            ],
        )
    )
    registry.register_source(_FailingSource())
    from openscience_agent.adapters.model import ExtractiveSynthesizer

    registry.register_synthesizer(ExtractiveSynthesizer())
    request = ResearchRequest(
        question=QUESTION,
        source_names=("test.healthy-source", "test.failing-source"),
    )

    started = time.monotonic()
    outcome = _orchestrator(registry, PolicyEngine()).execute(
        request,
        workspace=tmp_path / "runs",
        source_names=request.source_names,
        approved=True,
    )
    elapsed = time.monotonic() - started

    assert elapsed < 30
    assert outcome.status.value == "partial"
    assert any("test.failing-source failed" in item for item in outcome.limitations)
    assert validate_run(outcome.run_directory).valid


def test_sampled_conclusion_traces_to_original_source_well_under_two_minutes(
    tmp_path: Path,
) -> None:
    workspace = tmp_path / "runs"
    assert (
        main(
            [
                "run",
                QUESTION,
                "--fixture",
                "examples/corpus.json",
                "--workspace",
                str(workspace),
                "--yes",
                "--json",
            ]
        )
        == 0
    )
    run = next(workspace.iterdir())

    started = time.monotonic()
    claims = json.loads((run / "claims.json").read_text(encoding="utf-8"))
    evidence = {
        item["evidence_id"]: item
        for item in json.loads((run / "evidence.json").read_text(encoding="utf-8"))
    }
    sources = {
        item["source_id"]: item
        for item in json.loads((run / "sources.json").read_text(encoding="utf-8"))
    }
    sampled_claim = next(item for item in claims if item["kind"] == "sourced_fact")
    linked_evidence = evidence[sampled_claim["evidence_ids"][0]]
    original_source = sources[linked_evidence["source_id"]]
    elapsed = time.monotonic() - started

    assert elapsed < 120
    assert sampled_claim["text"] == linked_evidence["passage"]
    assert original_source["retrievals"]
    assert original_source["canonical_id"]
