"""Offline reconstruction of a recorded run from verified projections and events."""

from __future__ import annotations

from collections.abc import Mapping
from pathlib import Path
from typing import Any

from .storage import ZERO_HASH, RunStore
from .validation import ValidationReport, validate_run


def replay_run(run_directory: Path, *, require_valid: bool = True) -> dict[str, Any]:
    """Return a verified replay projection without invoking a provider or model.

    Provider responses and generated records are intentionally persisted as projections rather
    than repeated in every event.  Replay therefore verifies the event chain and the hashes of
    those projections, then reconstructs a consistent summary from both sources.  It does not
    claim to re-execute external calls.
    """

    store = RunStore.open(run_directory)
    report: ValidationReport = validate_run(store.run_directory)
    if require_valid and not report.valid:
        messages = "; ".join(issue.message for issue in report.errors)
        raise ValueError(f"run integrity validation failed: {messages}")
    manifest = store.read_json("manifest.json")
    events = store.read_events()
    state = manifest.get("state", {})
    records = manifest.get("records", {})

    request = _read_projection(store, state, "request", "request.json")
    plan = _read_projection(store, state, "plan", "plan.json")
    checkpoint = _read_projection(store, state, "checkpoint", "checkpoint.json")
    execution = _read_projection(store, state, "execution", "execution.json")
    sources = _read_projection(store, records, "sources", "sources.json", default=[])
    evidence = _read_projection(store, records, "evidence", "evidence.json", default=[])
    claims = _read_projection(store, records, "claims", "claims.json", default=[])

    completed_steps: list[str] = []
    failed_steps: list[str] = []
    event_types: dict[str, int] = {}
    for event in events:
        event_type = str(event.get("type", "unknown"))
        event_types[event_type] = event_types.get(event_type, 0) + 1
        step_id = event.get("step_id")
        if event_type == "step.completed" and step_id:
            completed_steps.append(str(step_id))
        if event_type == "step.failed" and step_id:
            failed_steps.append(str(step_id))

    plan_steps = plan.get("steps", []) if isinstance(plan, dict) else []
    projection_hashes: dict[str, str] = {}
    for group in (state, records):
        if not isinstance(group, Mapping):
            continue
        for name, raw_index in group.items():
            if isinstance(raw_index, Mapping) and isinstance(raw_index.get("sha256"), str):
                projection_hashes[str(name)] = str(raw_index["sha256"])

    return {
        "replay_mode": "verified_projection",
        "replay_note": (
            "External provider/model calls were not re-executed; their persisted projections "
            "were accepted only after hash, domain, and event-chain validation."
        ),
        "verified": report.valid,
        "run_id": manifest.get("run_id"),
        "status": manifest.get("status"),
        "created_at": manifest.get("created_at"),
        "updated_at": manifest.get("updated_at"),
        "question": request.get("question") if isinstance(request, dict) else None,
        "events": len(events),
        "event_head_hash": events[-1].get("event_hash") if events else ZERO_HASH,
        "event_types": event_types,
        "completed_steps": completed_steps,
        "failed_steps": failed_steps,
        "planned_steps": [item.get("step_id") for item in plan_steps if isinstance(item, dict)],
        "checkpoint_status": (checkpoint.get("status") if isinstance(checkpoint, dict) else None),
        "execution_status": execution.get("status") if isinstance(execution, dict) else None,
        "sources": len(sources) if isinstance(sources, list) else 0,
        "evidence": len(evidence) if isinstance(evidence, list) else 0,
        "claims": len(claims) if isinstance(claims, list) else 0,
        "artifacts": [
            artifact.get("name")
            for artifact in manifest.get("artifacts", [])
            if isinstance(artifact, dict)
        ],
        "limitations": list(manifest.get("limitations", [])),
        "projection_hashes": projection_hashes,
        "validation": report.to_dict(),
    }


def _read_projection(
    store: RunStore,
    indexes: Any,
    name: str,
    fallback_path: str,
    *,
    default: Any = None,
) -> Any:
    path = fallback_path
    if isinstance(indexes, Mapping):
        index = indexes.get(name)
        if isinstance(index, Mapping) and isinstance(index.get("path"), str):
            path = str(index["path"])
    candidate = store.path_for(path)
    if not candidate.is_file() or candidate.is_symlink():
        return default
    return store.read_json(path)
