from __future__ import annotations

import json
from pathlib import Path

from jsonschema import Draft202012Validator

from openscience_agent.cli import main

SCHEMA_PATH = Path("specs/001-general-research-agent/contracts/run-manifest.schema.json")


def test_manifest_schema_is_valid_json_and_has_required_indices() -> None:
    schema = json.loads(SCHEMA_PATH.read_text())

    Draft202012Validator.check_schema(schema)
    assert schema["$schema"].endswith("2020-12/schema")
    assert schema["properties"]["schema_version"]["const"] == "1.0"
    assert {"sources", "evidence", "claims", "policy_decisions"} <= set(
        schema["properties"]["records"]["properties"]
    )
    assert "head_hash" in schema["properties"]["event_log"]["required"]
    assert schema["properties"]["state"]["additionalProperties"] is False
    assert set(schema["properties"]["state"]["required"]) == {
        "request",
        "plan",
        "checkpoint",
        "execution",
    }


def test_generated_terminal_manifest_conforms_to_schema(tmp_path: Path) -> None:
    workspace = tmp_path / "runs"
    exit_code = main(
        [
            "run",
            "What practices make computational research results easier to reproduce?",
            "--fixture",
            "examples/corpus.json",
            "--workspace",
            str(workspace),
            "--yes",
            "--json",
        ]
    )
    manifest = json.loads((next(workspace.iterdir()) / "manifest.json").read_text())
    schema = json.loads(SCHEMA_PATH.read_text())

    assert exit_code == 0
    Draft202012Validator(schema).validate(manifest)
