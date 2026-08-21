from __future__ import annotations

import json
from pathlib import Path

import pytest

from openscience_agent.policy import redact_secrets
from openscience_agent.storage import RunStore, sha256_bytes, sha256_file


def test_event_chain_is_append_only_and_verifiable(tmp_path: Path) -> None:
    store = RunStore.create(tmp_path, "run-one")
    first = store.append_event(
        "run.created", {"token": "visible"}, timestamp="2026-08-12T00:00:00Z"
    )
    second = store.append_event(
        "step.completed",
        {"records": 2},
        timestamp="2026-08-12T00:00:01Z",
        step_id="discover",
    )

    assert first["previous_hash"] == "0" * 64
    assert first["run_id"] == "run-one"
    assert second["run_id"] == "run-one"
    assert second["previous_hash"] == first["event_hash"]
    assert store.verify_event_chain() == []


def test_event_mutation_is_detected(tmp_path: Path) -> None:
    store = RunStore.create(tmp_path, "run-one")
    store.append_event("run.created", {}, timestamp="2026-08-12T00:00:00Z")
    event = json.loads(store.events_path.read_text())
    event["payload"]["forged"] = True
    store.events_path.write_text(json.dumps(event) + "\n")

    assert "invalid event_hash" in " ".join(store.verify_event_chain())


def test_projections_are_atomic_and_indexed(tmp_path: Path) -> None:
    store = RunStore.create(tmp_path, "run-one")
    store.write_json("sources.json", [{"source_id": "one"}])

    assert store.read_json("sources.json") == [{"source_id": "one"}]
    index = store.projection_index("sources.json", count=1)
    assert index["count"] == 1
    assert index["sha256"] == sha256_file(store.run_directory / "sources.json")
    assert len(index["sha256"]) == 64


def test_content_addressed_object_and_artifact_identity(tmp_path: Path) -> None:
    store = RunStore.create(tmp_path, "run-one")
    content = b"research report"
    artifact = store.add_artifact(
        name="report.md",
        content=content,
        media_type="text/markdown",
        produced_by_step="report",
        input_ids=("evidence-one",),
    )

    assert artifact["sha256"] == sha256_bytes(content)
    assert artifact["size"] == len(content)
    assert (store.run_directory / artifact["object_path"]).read_bytes() == content


def test_run_and_artifact_paths_cannot_escape(tmp_path: Path) -> None:
    with pytest.raises(ValueError):
        RunStore.create(tmp_path, "../escape")

    store = RunStore.create(tmp_path, "safe")
    with pytest.raises(ValueError):
        store.write_json("../escape.json", {})
    with pytest.raises(ValueError):
        store.add_artifact(
            name="../report.md",
            content=b"x",
            media_type="text/plain",
            produced_by_step="report",
        )


def test_store_redacts_every_projection_and_event(tmp_path: Path) -> None:
    def redact(value: object) -> object:
        if isinstance(value, dict):
            return {
                key: ("[REDACTED]" if key == "api_key" else item) for key, item in value.items()
            }
        return value

    store = RunStore.create(tmp_path, "run-one", redactor=redact)
    store.write_json("config.json", {"api_key": "secret"})
    store.append_event(
        "configured",
        {"api_key": "secret"},
        timestamp="2026-08-12T00:00:00Z",
    )

    assert store.read_json("config.json")["api_key"] == "[REDACTED]"
    assert store.read_events()[0]["payload"]["api_key"] == "[REDACTED]"


def test_store_redacts_text_projection_and_text_artifact(tmp_path: Path) -> None:
    secret = "sk-abcdefghijklmnopqrstuvwxyz123456"
    store = RunStore.create(tmp_path, "run-one", redactor=redact_secrets)

    store.write_text("report.md", f"Report carried {secret}")
    artifact = store.add_artifact(
        name="report.md",
        content=f"Report carried {secret}".encode(),
        media_type="text/markdown",
        produced_by_step="report",
    )

    assert secret not in (store.run_directory / "report.md").read_text()
    assert secret.encode() not in (store.run_directory / artifact["object_path"]).read_bytes()


def test_event_run_id_tampering_is_detected(tmp_path: Path) -> None:
    store = RunStore.create(tmp_path, "run-one")
    store.append_event("run.created", {}, timestamp="2026-08-12T00:00:00Z")
    event = json.loads(store.events_path.read_text())
    event["run_id"] = "another-run"
    unhashed = {key: value for key, value in event.items() if key != "event_hash"}
    event["event_hash"] = sha256_bytes(
        json.dumps(
            unhashed,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
    )
    store.events_path.write_text(json.dumps(event) + "\n")

    assert "invalid run_id" in " ".join(store.verify_event_chain())


def test_read_rejects_a_symlink_that_escapes_the_run(tmp_path: Path) -> None:
    store = RunStore.create(tmp_path, "run-one")
    outside = tmp_path / "outside.json"
    outside.write_text("{}\n")
    (store.run_directory / "request.json").symlink_to(outside)

    with pytest.raises(ValueError, match="escapes"):
        store.read_json("request.json")
