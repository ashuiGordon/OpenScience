from __future__ import annotations

import json
import os
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Any

import pytest

import openscience_agent.cli as cli_module
from openscience_agent.export import validate_export_bundle

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
FIXTURE = REPOSITORY_ROOT / "examples" / "corpus.json"
QUESTION = "What practices make computational studies easier to reproduce?"


def _run_json(
    arguments: list[str],
    *,
    environment: dict[str, str] | None = None,
    expected_exit_codes: frozenset[int] = frozenset({0}),
) -> tuple[dict[str, Any], subprocess.CompletedProcess[str]]:
    completed = subprocess.run(
        [sys.executable, "-m", "openscience_agent.cli", *arguments],
        cwd=REPOSITORY_ROOT,
        env=environment,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="strict",
        timeout=30,
        check=False,
    )

    assert completed.returncode in expected_exit_codes, completed
    assert completed.stderr == "", completed.stderr
    lines = completed.stdout.splitlines()
    assert len(lines) == 1, f"expected one JSON object, got {len(lines)} lines"
    payload = json.loads(lines[0])
    assert isinstance(payload, dict)
    return payload, completed


def test_desktop_provider_credentials_use_environment_fallback_without_key_arguments(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    openalex_canary = "desktop-openalex-canary-721d7062"
    crossref_canary = "desktop-crossref-canary-2ec804a7"
    monkeypatch.setenv("OPENSCIENCE_OPENALEX_API_KEY", openalex_canary)
    monkeypatch.setenv("OPENSCIENCE_CROSSREF_API_KEY", crossref_canary)

    desktop_arguments = [
        "run",
        "--json",
        "--yes",
        "--fixture",
        str(FIXTURE),
        "--workspace",
        "/tmp/desktop-bridge-contract",
        "--",
        QUESTION,
    ]
    parsed = cli_module.build_parser().parse_args(desktop_arguments)
    registry, _ = cli_module._build_registry(parsed)

    assert registry.get_source("openalex")._api_key == openalex_canary
    assert registry.get_source("crossref")._api_key == crossref_canary
    assert "--openalex-api-key" not in desktop_arguments
    assert "--crossref-api-key" not in desktop_arguments
    assert openalex_canary not in desktop_arguments
    assert crossref_canary not in desktop_arguments


def test_desktop_cli_full_offline_json_journey_and_secret_absence(tmp_path: Path) -> None:
    canaries = {
        "OPENSCIENCE_OPENALEX_API_KEY": "desktop-openalex-canary-260331d9",
        "OPENSCIENCE_CROSSREF_API_KEY": "desktop-crossref-canary-968a0c93",
        "OPENSCIENCE_MODEL_API_KEY": "desktop-model-canary-125416cd",
        "AWS_SECRET_ACCESS_KEY": "desktop-unrelated-canary-40e819c0",
    }
    sensitive_markers = ("KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL")
    base_environment = {
        name: value
        for name, value in os.environ.items()
        if not any(marker in name.upper() for marker in sensitive_markers)
    }
    credential_environment = base_environment | canaries
    workspace = tmp_path / "task-workspace"
    plan_path = tmp_path / "reviewed-plan.json"

    plan_arguments = [
        "plan",
        "--json",
        "--output",
        str(plan_path),
        "--workspace",
        str(workspace),
        "--max-records",
        "50",
        "--max-network-requests",
        "0",
        "--timeout",
        "30",
        "--",
        QUESTION,
    ]
    plan, _ = _run_json(plan_arguments, environment=base_environment)
    assert plan["output"] == str(plan_path.resolve())
    assert plan["plan"]["plan_id"].startswith("plan-")
    assert len(plan["plan"]["steps"]) == 5
    assert json.loads(plan_path.read_text(encoding="utf-8"))["plan_id"] == plan["plan"]["plan_id"]

    run_arguments = [
        "run",
        "--json",
        "--yes",
        "--plan",
        str(plan_path),
        "--fixture",
        str(FIXTURE),
        "--workspace",
        str(workspace),
        "--max-records",
        "50",
        "--max-network-requests",
        "0",
        "--timeout",
        "30",
        "--synthesizer",
        "extractive",
        "--",
        QUESTION,
    ]
    for option in ("--openalex-api-key", "--crossref-api-key"):
        assert option not in run_arguments
    for canary in canaries.values():
        assert canary not in run_arguments

    outcome, _ = _run_json(run_arguments, environment=credential_environment)
    assert outcome["status"] == "completed"
    assert outcome["sources"] > 0
    assert outcome["evidence"] > 0
    assert outcome["claims"] > 0
    run_directory = Path(outcome["run_directory"])
    assert run_directory.parent == workspace.resolve()

    validation, _ = _run_json(
        ["validate", str(run_directory), "--json"], environment=base_environment
    )
    assert validation == {"errors": [], "valid": True, "warnings": []}

    inspection, _ = _run_json(
        ["inspect", str(run_directory), "--json"], environment=base_environment
    )
    assert inspection["summary"]["run_id"] == outcome["run_id"]
    assert inspection["summary"]["status"] == "completed"
    assert inspection["request"]["question"] == QUESTION

    replay, _ = _run_json(["replay", str(run_directory), "--json"], environment=base_environment)
    assert replay["run_id"] == outcome["run_id"]
    assert replay["status"] == "completed"
    assert replay["sources"] == outcome["sources"]
    assert replay["evidence"] == outcome["evidence"]
    assert replay["claims"] == outcome["claims"]

    export_path = tmp_path / "research-bundle.zip"
    exported, _ = _run_json(
        ["export", str(run_directory), "--output", str(export_path), "--json"],
        environment=base_environment,
    )
    assert exported["output"] == str(export_path.resolve())
    assert exported["size"] == export_path.stat().st_size > 0
    assert validate_export_bundle(export_path).valid

    encoded_canaries = [value.encode() for value in canaries.values()]
    for artifact in run_directory.rglob("*"):
        if artifact.is_file():
            contents = artifact.read_bytes()
            assert all(canary not in contents for canary in encoded_canaries), artifact

    with zipfile.ZipFile(export_path) as archive:
        for name in archive.namelist():
            contents = archive.read(name)
            assert all(canary not in contents for canary in encoded_canaries), name
