from __future__ import annotations

import json
from pathlib import Path

import pytest

from openscience_agent.cli import EXIT_FAILURE, EXIT_PARTIAL, main
from openscience_agent.validation import validate_run

QUESTION = "What practices make computational research results easier to reproduce?"


@pytest.mark.parametrize(
    "stop_after",
    ["discover", "extract", "synthesize", "validate", "report"],
)
def test_resume_matrix_never_repeats_completed_steps(tmp_path: Path, stop_after: str) -> None:
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
                "--stop-after-step",
                stop_after,
                "--json",
            ]
        )
        == EXIT_PARTIAL
    )
    run = next(workspace.iterdir())
    before = [json.loads(line) for line in (run / "events.jsonl").read_text().splitlines()]
    completed_before = {
        event["step_id"]: sum(
            candidate["type"] == "step.completed" and candidate.get("step_id") == event["step_id"]
            for candidate in before
        )
        for event in before
        if event["type"] == "step.completed"
    }

    assert (
        main(
            [
                "resume",
                str(run),
                "--fixture",
                "examples/corpus.json",
                "--yes",
                "--json",
            ]
        )
        == 0
    )
    after = [json.loads(line) for line in (run / "events.jsonl").read_text().splitlines()]

    for step_id, count_before in completed_before.items():
        count_after = sum(
            event["type"] == "step.completed" and event.get("step_id") == step_id for event in after
        )
        assert count_after == count_before == 1
    assert validate_run(run).valid
    assert json.loads((run / "manifest.json").read_text())["status"] == "completed"


def test_resume_does_not_repeat_a_completed_discovery_step(tmp_path: Path) -> None:
    workspace = tmp_path / "runs"
    first = main(
        [
            "run",
            QUESTION,
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
    run = next(workspace.iterdir())
    before = [json.loads(line) for line in (run / "events.jsonl").read_text().splitlines()]
    discovery_completions_before = sum(
        event["type"] == "step.completed" and event["step_id"] == "discover" for event in before
    )

    resumed = main(
        [
            "resume",
            str(run),
            "--fixture",
            "examples/corpus.json",
            "--yes",
            "--json",
        ]
    )
    after = [json.loads(line) for line in (run / "events.jsonl").read_text().splitlines()]
    discovery_completions_after = sum(
        event["type"] == "step.completed" and event["step_id"] == "discover" for event in after
    )

    assert first == EXIT_PARTIAL
    assert resumed == 0
    assert discovery_completions_before == discovery_completions_after == 1
    assert validate_run(run).valid
    assert json.loads((run / "manifest.json").read_text())["status"] == "completed"


def test_cancel_marker_stops_resume_before_the_next_step(tmp_path: Path) -> None:
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
                "--stop-after-step",
                "discover",
                "--json",
            ]
        )
        == EXIT_PARTIAL
    )
    run = next(workspace.iterdir())
    events_before = len((run / "events.jsonl").read_text().splitlines())

    assert main(["cancel", str(run), "--json"]) == 0
    resumed = main(
        [
            "resume",
            str(run),
            "--fixture",
            "examples/corpus.json",
            "--yes",
            "--json",
        ]
    )

    manifest = json.loads((run / "manifest.json").read_text())
    events = [json.loads(line) for line in (run / "events.jsonl").read_text().splitlines()]
    assert resumed == EXIT_FAILURE
    assert manifest["status"] == "cancelled"
    assert len(events) > events_before
    assert events[-1]["type"] == "run.cancelled"
    assert not any(
        event["type"] == "step.started" and event.get("step_id") == "extract"
        for event in events[events_before:]
    )
    assert validate_run(run).valid


def test_resuming_a_completed_run_is_idempotent(tmp_path: Path) -> None:
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
    before = (run / "events.jsonl").read_bytes()

    assert (
        main(
            [
                "resume",
                str(run),
                "--fixture",
                "examples/corpus.json",
                "--yes",
                "--json",
            ]
        )
        == 0
    )

    assert (run / "events.jsonl").read_bytes() == before
    assert validate_run(run).valid
