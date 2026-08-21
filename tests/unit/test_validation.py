from __future__ import annotations

import json
from pathlib import Path

import pytest

from openscience_agent.cli import main
from openscience_agent.storage import ZERO_HASH, canonical_json, sha256_bytes, sha256_file
from openscience_agent.validation import validate_claim_evidence, validate_run


def _source(source_id: str = "source-one", status: str = "active") -> dict[str, object]:
    return {"source_id": source_id, "status": status, "title": "A source"}


def _evidence(
    evidence_id: str = "evidence-one", source_id: str = "source-one"
) -> dict[str, object]:
    return {
        "evidence_id": evidence_id,
        "source_id": source_id,
        "passage": "A concrete observation.",
    }


def _claim(**overrides: object) -> dict[str, object]:
    claim: dict[str, object] = {
        "claim_id": "claim-one",
        "text": "A concrete observation.",
        "kind": "sourced_fact",
        "evidence_ids": ["evidence-one"],
        "limitations": [],
    }
    claim.update(overrides)
    return claim


def test_sourced_facts_require_known_evidence() -> None:
    missing = validate_claim_evidence([_claim(evidence_ids=[])], [_evidence()], [_source()])
    unknown = validate_claim_evidence(
        [_claim(evidence_ids=["evidence-missing"])], [_evidence()], [_source()]
    )

    assert any(issue.code == "claim.unsupported_fact" for issue in missing.errors)
    assert any(issue.code == "claim.unknown_evidence" for issue in unknown.errors)


def test_retracted_only_support_requires_a_limitation() -> None:
    invalid = validate_claim_evidence([_claim()], [_evidence()], [_source(status="retracted")])
    valid = validate_claim_evidence(
        [_claim(limitations=["The only source is retracted."])],
        [_evidence()],
        [_source(status="retracted")],
    )

    assert any(issue.code == "claim.retracted_only_support" for issue in invalid.errors)
    assert not any(issue.code == "claim.retracted_only_support" for issue in valid.errors)


def test_evidence_must_reference_an_existing_source() -> None:
    result = validate_claim_evidence([], [_evidence(source_id="unknown")], [_source()])

    assert any(issue.code == "evidence.unknown_source" for issue in result.errors)


def _build_valid_run(tmp_path: Path) -> Path:
    workspace = tmp_path / "runs"
    corpus = Path(__file__).parents[2] / "examples" / "corpus.json"
    result = main(
        [
            "run",
            "What practices make computational research results easier to reproduce?",
            "--fixture",
            str(corpus),
            "--workspace",
            str(workspace),
            "--yes",
            "--json",
        ]
    )
    assert result == 0
    return next(workspace.iterdir())


def test_whole_run_validation_detects_projection_tampering(tmp_path: Path) -> None:
    run = _build_valid_run(tmp_path)
    assert validate_run(run).valid

    evidence_path = run / "evidence.json"
    evidence_path.write_text(json.dumps([_evidence(evidence_id="forged")]) + "\n")
    result = validate_run(run)

    assert not result.valid
    assert any(issue.code == "records.hash" for issue in result.errors)
    assert (
        sha256_file(evidence_path)
        != json.loads((run / "manifest.json").read_text())["records"]["evidence"]["sha256"]
    )


def test_whole_run_validation_detects_persisted_secret(tmp_path: Path) -> None:
    run = _build_valid_run(tmp_path)
    (run / "leak.txt").write_text("sk-abcdefghijklmnopqrstuvwxyz123456")

    result = validate_run(run)

    assert any(issue.code == "security.persisted_secret" for issue in result.errors)


def test_sourced_fact_must_be_directly_attributable() -> None:
    result = validate_claim_evidence(
        [_claim(text="A novel conclusion not present in the cited passage.")],
        [_evidence()],
        [_source()],
    )

    assert any(issue.code == "claim.text_not_attributable" for issue in result.errors)


def test_sourced_fact_requires_exact_normalized_evidence_text() -> None:
    result = validate_claim_evidence(
        [_claim(text="A concrete observation. Added interpretation.")],
        [_evidence()],
        [_source()],
    )

    assert any(issue.code == "claim.text_not_attributable" for issue in result.errors)


def test_whole_run_detects_request_plan_and_checkpoint_tampering(tmp_path: Path) -> None:
    for filename in ("request.json", "plan.json", "checkpoint.json"):
        run = _build_valid_run(tmp_path / filename.removesuffix(".json"))
        path = run / filename
        value = json.loads(path.read_text())
        value["tampered"] = True
        path.write_text(json.dumps(value) + "\n")

        result = validate_run(run)

        assert not result.valid
        assert any(issue.code == "state.hash" for issue in result.errors)


def test_whole_run_binds_created_event_to_request_and_plan(tmp_path: Path) -> None:
    run = _build_valid_run(tmp_path)
    event_path = run / "events.jsonl"
    events = [json.loads(line) for line in event_path.read_text().splitlines()]
    events[0]["payload"]["request_hash"] = "0" * 64
    previous = ZERO_HASH
    for event in events:
        event["previous_hash"] = previous
        event.pop("event_hash", None)
        event["event_hash"] = sha256_bytes(canonical_json(event).encode())
        previous = event["event_hash"]
    event_path.write_text("".join(canonical_json(event) + "\n" for event in events))
    manifest_path = run / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["event_log"]["head_hash"] = previous
    manifest_path.write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")

    result = validate_run(run)

    assert any(issue.code == "events.run_created_request_hash" for issue in result.errors)


def test_whole_run_derives_network_usage_from_events(tmp_path: Path) -> None:
    run = _build_valid_run(tmp_path)
    manifest_path = run / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    for name in ("checkpoint", "execution"):
        path = run / f"{name}.json"
        value = json.loads(path.read_text())
        value["network_requests_used"] = 1
        path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
        manifest["state"][name]["sha256"] = sha256_file(path)
        if name == "execution":
            manifest["execution"] = value
    manifest_path.write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")

    result = validate_run(run)

    assert {issue.code for issue in result.errors} >= {
        "network.checkpoint_usage",
        "network.execution_usage",
    }


@pytest.mark.parametrize("tampered_status", ["cancelled", "running", "created"])
def test_whole_run_binds_terminal_status_to_final_event(
    tmp_path: Path, tampered_status: str
) -> None:
    run = _build_valid_run(tmp_path)
    manifest_path = run / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    for name in ("checkpoint", "execution"):
        path = run / f"{name}.json"
        value = json.loads(path.read_text())
        value["status"] = tampered_status
        path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
        manifest["state"][name]["sha256"] = sha256_file(path)
        if name == "execution":
            manifest["execution"] = value
    manifest["status"] = tampered_status
    manifest_path.write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")

    result = validate_run(run)

    assert any(issue.code == "events.terminal_status" for issue in result.errors)


def test_whole_run_requires_an_errors_projection_in_the_manifest(tmp_path: Path) -> None:
    run = _build_valid_run(tmp_path)
    manifest_path = run / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    del manifest["errors"]
    manifest_path.write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")

    result = validate_run(run)

    assert any(
        issue.code == "manifest.missing_field" and "errors" in issue.message
        for issue in result.errors
    )
