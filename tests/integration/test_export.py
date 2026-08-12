from __future__ import annotations

import json
import zipfile
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

from openscience_agent.cli import main
from openscience_agent.domain import PolicyDecision, sha256_json
from openscience_agent.export import RO_CRATE_CONTEXT, export_run, validate_export_bundle
from openscience_agent.storage import RunStore

QUESTION = "What practices make computational research results easier to reproduce?"


def _completed_run(tmp_path: Path) -> Path:
    workspace = tmp_path / "runs"
    corpus = Path(__file__).parents[2] / "examples" / "corpus.json"
    result = main(
        [
            "run",
            QUESTION,
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


def test_export_refuses_a_run_without_a_valid_manifest(tmp_path: Path) -> None:
    store = RunStore.create(tmp_path, "invalid")
    store.append_event("run.created", {}, timestamp="2026-08-12T00:00:00Z")

    with pytest.raises(ValueError, match="invalid run"):
        export_run(store.run_directory, tmp_path / "bundle.zip")


def test_ro_crate_constant_targets_current_contract() -> None:
    assert RO_CRATE_CONTEXT == "https://w3id.org/ro/crate/1.3/context"


def test_export_is_self_validating_and_contains_provenance_graph(tmp_path: Path) -> None:
    run = _completed_run(tmp_path)
    bundle = export_run(run, tmp_path / "bundle.zip")

    assert validate_export_bundle(bundle).valid
    with zipfile.ZipFile(bundle) as archive:
        names = set(archive.namelist())
        assert {
            "checksums.txt",
            "manifest.json",
            "events.jsonl",
            "report.md",
            "ro-crate-metadata.json",
        } <= names
        manifest = json.loads(archive.read("manifest.json"))
        crate = json.loads(archive.read("ro-crate-metadata.json"))
        checksum_lines = archive.read("checksums.txt").decode().splitlines()
        assert len(checksum_lines) == len(names) - 1
        assert all(item["object_path"].startswith("artifacts/") for item in manifest["artifacts"])
        assert manifest["request"]["approved_local_roots"] == []
        entity_ids = {item.get("@id") for item in crate["@graph"]}
        assert "#plan" in entity_ids
        assert any(str(value).startswith("#source-") for value in entity_ids)
        assert any(str(value).startswith("#evidence-") for value in entity_ids)
        assert any(str(value).startswith("#claim-") for value in entity_ids)
        assert b"sk-abcdefghijklmnopqrstuvwxyz123456" not in bundle.read_bytes()


def test_export_refuses_symlinked_report(tmp_path: Path) -> None:
    run = _completed_run(tmp_path)
    report = run / "report.md"
    target = tmp_path / "outside-report.md"
    target.write_text(report.read_text())
    report.unlink()
    report.symlink_to(target)

    with pytest.raises(ValueError, match="symlink"):
        export_run(run, tmp_path / "bundle.zip")


def test_bundle_validator_detects_checksum_tampering(tmp_path: Path) -> None:
    run = _completed_run(tmp_path)
    bundle = export_run(run, tmp_path / "bundle.zip")
    tampered = tmp_path / "tampered.zip"
    with zipfile.ZipFile(bundle) as source, zipfile.ZipFile(tampered, "w") as destination:
        for info in source.infolist():
            content = source.read(info)
            if info.filename == "report.md":
                content += b"tampered"
            destination.writestr(info, content)

    result = validate_export_bundle(tampered)

    assert not result.valid
    assert any(issue.code == "bundle.checksum" for issue in result.errors)


def test_local_export_removes_host_roots_and_rebinds_sanitized_identities(
    tmp_path: Path,
) -> None:
    local_root = tmp_path / "private-corpus"
    local_root.mkdir()
    (local_root / "note.md").write_text(
        "Reproducible computational research records environments, inputs, and outputs."
    )
    workspace = tmp_path / "runs"
    exit_code = main(
        [
            "run",
            QUESTION,
            "--local-root",
            str(local_root),
            "--workspace",
            str(workspace),
            "--yes",
            "--json",
        ]
    )
    assert exit_code in {0, 4}
    bundle = export_run(next(workspace.iterdir()), tmp_path / "local.zip")

    with zipfile.ZipFile(bundle) as archive:
        payloads = {name: archive.read(name) for name in archive.namelist()}
        manifest = json.loads(payloads["manifest.json"])
        request = json.loads(payloads["request.json"])
        plan = json.loads(payloads["plan.json"])
        events = [json.loads(line) for line in payloads["events.jsonl"].splitlines()]
        decisions = json.loads(payloads["policy_decisions.json"])

    assert all(str(local_root).encode() not in content for content in payloads.values())
    assert set(manifest["state"]) == {"request", "plan", "checkpoint", "execution"}
    assert all(index["count"] == 1 for index in manifest["state"].values())
    created = next(event for event in events if event["type"] == "run.created")["payload"]
    assert created["request_id"] == request["request_id"]
    assert created["request_hash"] == sha256_json(request)
    assert created["plan_id"] == plan["plan_id"]
    assert created["plan_hash"] == sha256_json(plan)
    for raw in decisions:
        rebuilt = dict(raw)
        rebuilt.pop("decision_id")
        assert raw["decision_id"] == PolicyDecision.from_dict(rebuilt).decision_id
        assert not str(raw["target"]).startswith("/")
    schema = json.loads(
        Path("specs/001-general-research-agent/contracts/run-manifest.schema.json").read_text()
    )
    Draft202012Validator(schema).validate(manifest)
    assert validate_export_bundle(bundle).valid


def test_export_rebinds_resume_events_after_request_sanitization(tmp_path: Path) -> None:
    corpus = Path(__file__).parents[2] / "examples" / "corpus.json"
    workspace = tmp_path / "runs"
    first = main(
        [
            "run",
            QUESTION,
            "--fixture",
            str(corpus),
            "--workspace",
            str(workspace),
            "--yes",
            "--json",
            "--stop-after-step",
            "discover",
        ]
    )
    run = next(workspace.iterdir())
    resumed = main(["resume", str(run), "--fixture", str(corpus), "--yes", "--json"])
    assert first == 4
    assert resumed in {0, 4}

    bundle = export_run(run, tmp_path / "resumed.zip")
    with zipfile.ZipFile(bundle) as archive:
        request = json.loads(archive.read("request.json"))
        plan = json.loads(archive.read("plan.json"))
        events = [json.loads(line) for line in archive.read("events.jsonl").splitlines()]
    resume_payloads = [event["payload"] for event in events if event["type"] == "run.resumed"]

    assert resume_payloads
    assert all(payload["request_id"] == request["request_id"] for payload in resume_payloads)
    assert all(payload["request_hash"] == sha256_json(request) for payload in resume_payloads)
    assert all(payload["plan_id"] == plan["plan_id"] for payload in resume_payloads)
    assert all(payload["plan_hash"] == sha256_json(plan) for payload in resume_payloads)
    assert validate_export_bundle(bundle).valid
