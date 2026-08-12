from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

import openscience_agent.cli as cli_module
from openscience_agent.adapters.fixtures import load_fixture_providers
from openscience_agent.cli import EXIT_PARTIAL, EXIT_USAGE, main
from openscience_agent.domain import (
    CapabilityDescriptor,
    CapabilityKind,
    Claim,
    ClaimKind,
    RiskLevel,
)
from openscience_agent.registry import ProviderRegistry


class _SelectableSynthesizer:
    def descriptor(self) -> CapabilityDescriptor:
        return CapabilityDescriptor(
            name="test.selectable-synthesis",
            version="1.0.0",
            kind=CapabilityKind.SYNTHESIS,
            risk=RiskLevel.LOCAL_READ,
            input_schema={"type": "object"},
            output_schema={"type": "array"},
        )

    def synthesize(
        self,
        request: Any,
        sources: list[Any],
        evidence: list[Any],
        context: Any,
    ) -> list[Claim]:
        del request, sources
        context.require_active()
        context.emit("synthesis.test", {"claims": len(evidence)})
        return [
            Claim(
                text=str(item["passage"]),
                kind=ClaimKind.SOURCED_FACT,
                evidence_ids=(str(item["evidence_id"]),),
                limitations=("Source status and evidence quality require human review.",),
                created_by="test.selectable-synthesis/1.0.0",
            )
            for item in evidence
        ]


def test_plan_json_has_stable_finite_steps(capsys: object) -> None:
    exit_code = main(
        [
            "plan",
            "What practices make computational studies reproducible?",
            "--json",
        ]
    )
    output = json.loads(capsys.readouterr().out)  # type: ignore[attr-defined]

    assert exit_code == 0
    assert [step["step_id"] for step in output["plan"]["steps"]] == [
        "discover",
        "extract",
        "synthesize",
        "validate",
        "report",
    ]


def test_cli_json_mode_emits_one_object(capsys: object) -> None:
    exit_code = main(["providers", "--json"])
    captured = capsys.readouterr()  # type: ignore[attr-defined]

    assert exit_code == 0
    assert captured.err == ""
    assert isinstance(json.loads(captured.out), dict)
    assert len(captured.out.strip().splitlines()) == 1


def test_missing_question_is_usage_error(capsys: object) -> None:
    exit_code = main(["plan", "--json"])
    captured = capsys.readouterr()  # type: ignore[attr-defined]

    assert exit_code == EXIT_USAGE
    assert captured.err == ""
    payload = json.loads(captured.out)
    assert "QUESTION" in payload["error"]["message"] or "question" in payload["error"]["message"]


def test_invalid_domain_input_is_usage_error_json(capsys: object) -> None:
    exit_code = main(["plan", "short", "--json"])
    captured = capsys.readouterr()  # type: ignore[attr-defined]

    assert exit_code == EXIT_USAGE
    assert captured.err == ""
    assert json.loads(captured.out)["error"]["code"] == "validation.invalid"


def test_parser_error_returns_usage_without_raising_system_exit(capsys: object) -> None:
    exit_code = main(["run", "A sufficiently long research question?", "--unknown", "--json"])
    captured = capsys.readouterr()  # type: ignore[attr-defined]

    assert exit_code == EXIT_USAGE
    assert captured.err == ""
    assert json.loads(captured.out)["error"]["code"] == "usage.invalid"


def test_inspect_and_cancel_commands_are_machine_readable(tmp_path: Path, capsys: object) -> None:
    workspace = tmp_path / "runs"
    first = main(
        [
            "run",
            "What practices make computational studies reproducible?",
            "--fixture",
            "examples/corpus.json",
            "--workspace",
            str(workspace),
            "--yes",
            "--stop-after-step",
            "discover",
            "--json",
        ]
    )
    capsys.readouterr()  # type: ignore[attr-defined]
    run_directory = next(workspace.iterdir())

    inspected = main(["inspect", str(run_directory), "--json"])
    inspect_payload = json.loads(capsys.readouterr().out)  # type: ignore[attr-defined]
    cancelled = main(["cancel", str(run_directory), "--json"])
    first_cancel = json.loads(capsys.readouterr().out)  # type: ignore[attr-defined]
    repeated = main(["cancel", str(run_directory), "--json"])
    second_cancel = json.loads(capsys.readouterr().out)  # type: ignore[attr-defined]

    assert first == EXIT_PARTIAL
    assert inspected == cancelled == repeated == 0
    assert inspect_payload["summary"]["status"] == "partial"
    assert inspect_payload["request"]["question"].startswith("What practices")
    assert first_cancel["requested_at"] == second_cancel["requested_at"]
    assert (run_directory / "cancel-requested.json").is_file()


def test_structural_plan_edit_is_rejected_before_a_run_is_created(
    tmp_path: Path, capsys: object
) -> None:
    plan_path = tmp_path / "plan.json"
    assert (
        main(
            [
                "plan",
                "What practices make computational studies reproducible?",
                "--output",
                str(plan_path),
                "--json",
            ]
        )
        == 0
    )
    capsys.readouterr()  # type: ignore[attr-defined]
    plan = json.loads(plan_path.read_text())
    plan["steps"][0]["capability"] = "unreviewed.execute"
    plan_path.write_text(json.dumps(plan))
    workspace = tmp_path / "runs"

    result = main(
        [
            "run",
            "What practices make computational studies reproducible?",
            "--fixture",
            "examples/corpus.json",
            "--workspace",
            str(workspace),
            "--plan",
            str(plan_path),
            "--yes",
            "--json",
        ]
    )
    captured = capsys.readouterr()  # type: ignore[attr-defined]

    assert result == EXIT_USAGE
    payload = json.loads(captured.out)
    assert "capability" in payload["error"]["message"]
    assert not workspace.exists()


def test_dependency_edit_is_rejected_before_a_run_is_created(
    tmp_path: Path, capsys: object
) -> None:
    plan_path = tmp_path / "plan.json"
    assert (
        main(
            [
                "plan",
                "What practices make computational studies reproducible?",
                "--output",
                str(plan_path),
                "--json",
            ]
        )
        == 0
    )
    capsys.readouterr()  # type: ignore[attr-defined]
    plan = json.loads(plan_path.read_text())
    plan["steps"][1]["dependencies"] = []
    plan_path.write_text(json.dumps(plan))
    workspace = tmp_path / "runs"

    result = main(
        [
            "run",
            "What practices make computational studies reproducible?",
            "--fixture",
            "examples/corpus.json",
            "--workspace",
            str(workspace),
            "--plan",
            str(plan_path),
            "--yes",
            "--json",
        ]
    )
    captured = capsys.readouterr()  # type: ignore[attr-defined]

    assert result == EXIT_USAGE
    assert "dependencies" in json.loads(captured.out)["error"]["message"]
    assert not workspace.exists()


def test_plan_status_edit_is_rejected_before_a_run_is_created(
    tmp_path: Path, capsys: object
) -> None:
    plan_path = tmp_path / "plan.json"
    assert (
        main(
            [
                "plan",
                "What practices make computational studies reproducible?",
                "--output",
                str(plan_path),
                "--json",
            ]
        )
        == 0
    )
    capsys.readouterr()  # type: ignore[attr-defined]
    plan = json.loads(plan_path.read_text())
    plan["steps"][0]["status"] = "completed"
    plan_path.write_text(json.dumps(plan))
    workspace = tmp_path / "runs"

    result = main(
        [
            "run",
            "What practices make computational studies reproducible?",
            "--fixture",
            "examples/corpus.json",
            "--workspace",
            str(workspace),
            "--plan",
            str(plan_path),
            "--yes",
            "--json",
        ]
    )
    captured = capsys.readouterr()  # type: ignore[attr-defined]

    assert result == EXIT_USAGE
    assert "status" in json.loads(captured.out)["error"]["message"]
    assert not workspace.exists()


def test_cli_selects_a_registered_synthesis_extension(
    tmp_path: Path, capsys: object, monkeypatch: pytest.MonkeyPatch
) -> None:
    registry = ProviderRegistry()
    defaults: list[str] = []
    for name, provider in load_fixture_providers(Path("examples/corpus.json")).items():
        registry.register_source(provider)
        defaults.append(name)
    registry.register_synthesizer(_SelectableSynthesizer())
    monkeypatch.setattr(cli_module, "_build_registry", lambda _args: (registry, defaults))

    result = main(
        [
            "run",
            "What practices make computational studies reproducible?",
            "--fixture",
            "examples/corpus.json",
            "--synthesizer",
            "test.selectable-synthesis",
            "--workspace",
            str(tmp_path / "runs"),
            "--yes",
            "--json",
        ]
    )
    payload = json.loads(capsys.readouterr().out)  # type: ignore[attr-defined]

    assert result == 0, payload
    assert payload["status"] == "completed"
    claims = json.loads(
        (Path(payload["run_directory"]) / "claims.json").read_text(encoding="utf-8")
    )
    assert claims
    assert {claim["created_by"] for claim in claims} == {"test.selectable-synthesis/1.0.0"}


def test_unexpected_extension_failure_still_emits_one_json_error(
    tmp_path: Path, capsys: object, monkeypatch: pytest.MonkeyPatch
) -> None:
    class ExplodingSynthesizer(_SelectableSynthesizer):
        def synthesize(self, *args: Any, **kwargs: Any) -> list[Claim]:
            del args, kwargs
            raise RuntimeError("unexpected extension failure")

    registry = ProviderRegistry()
    defaults: list[str] = []
    for name, provider in load_fixture_providers(Path("examples/corpus.json")).items():
        registry.register_source(provider)
        defaults.append(name)
    registry.register_synthesizer(ExplodingSynthesizer())
    monkeypatch.setattr(cli_module, "_build_registry", lambda _args: (registry, defaults))

    result = main(
        [
            "run",
            "What practices make computational studies reproducible?",
            "--fixture",
            "examples/corpus.json",
            "--synthesizer",
            "test.selectable-synthesis",
            "--workspace",
            str(tmp_path / "runs"),
            "--yes",
            "--json",
        ]
    )
    captured = capsys.readouterr()  # type: ignore[attr-defined]

    assert result == 1
    assert captured.err == ""
    assert len(captured.out.strip().splitlines()) == 1
    assert json.loads(captured.out)["error"]["code"] == "internal.failure"
