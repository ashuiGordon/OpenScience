from __future__ import annotations

from pathlib import Path

import pytest

from openscience_agent.cli import main
from openscience_agent.replay import replay_run
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


def test_replay_requires_an_integrity_valid_run(tmp_path: Path) -> None:
    store = RunStore.create(tmp_path, "recorded")
    store.append_event("run.created", {}, timestamp="2026-08-12T00:00:00Z")

    with pytest.raises(ValueError, match="integrity validation failed"):
        replay_run(store.run_directory)


def test_replay_reconstructs_verified_projection_without_provider_calls(tmp_path: Path) -> None:
    run = _completed_run(tmp_path)

    replay = replay_run(run)

    assert replay["verified"] is True
    assert replay["replay_mode"] == "verified_projection"
    assert replay["question"] == QUESTION
    assert replay["completed_steps"] == replay["planned_steps"]
    assert replay["checkpoint_status"] == replay["status"]
    assert replay["execution_status"] == replay["status"]
    assert replay["sources"] == 3
    assert replay["evidence"] > 0
    assert replay["claims"] > 0
    assert replay["event_types"]["step.completed"] == len(replay["planned_steps"])
    assert {"request", "plan", "checkpoint", "execution"} <= set(replay["projection_hashes"])
