"""Scientific, provenance, and integrity validation for persisted research runs."""

from __future__ import annotations

import json
import re
import unicodedata
from collections.abc import Mapping
from dataclasses import asdict, dataclass, is_dataclass
from pathlib import Path
from typing import Any, cast

from .domain import (
    ArtifactRecord,
    CapabilityDescriptor,
    Claim,
    EvidenceRecord,
    PolicyDecision,
    ResearchPlan,
    ResearchRequest,
    SourceRecord,
    sha256_json,
)
from .storage import ZERO_HASH, RunStore, sha256_file

SHA256_PATTERN = re.compile(r"^[a-f0-9]{64}$")
SECRET_PATTERNS = (
    re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
)
RUN_STATUSES = {
    "created",
    "awaiting_approval",
    "running",
    "completed",
    "partial",
    "failed",
    "cancelled",
}
STATE_PROJECTIONS = ("request", "plan", "checkpoint", "execution")
RECORD_PROJECTIONS = ("sources", "evidence", "claims", "policy_decisions")


@dataclass(frozen=True, slots=True)
class ValidationIssue:
    severity: str
    code: str
    message: str
    location: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True, slots=True)
class ValidationReport:
    issues: tuple[ValidationIssue, ...] = ()

    @property
    def valid(self) -> bool:
        return not any(issue.severity == "error" for issue in self.issues)

    @property
    def errors(self) -> tuple[ValidationIssue, ...]:
        return tuple(issue for issue in self.issues if issue.severity == "error")

    @property
    def warnings(self) -> tuple[ValidationIssue, ...]:
        return tuple(issue for issue in self.issues if issue.severity == "warning")

    def to_dict(self) -> dict[str, Any]:
        return {
            "valid": self.valid,
            "errors": [issue.to_dict() for issue in self.errors],
            "warnings": [issue.to_dict() for issue in self.warnings],
        }


def _mapping(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    if hasattr(value, "to_dict"):
        result = value.to_dict()
        if isinstance(result, dict):
            return result
    if is_dataclass(value) and not isinstance(value, type):
        return asdict(cast(Any, value))
    raise TypeError(f"expected a mapping-compatible record, got {type(value).__name__}")


def validate_claim_evidence(
    claims: list[Any], evidence: list[Any], sources: list[Any]
) -> ValidationReport:
    issues: list[ValidationIssue] = []
    evidence_by_id = {_mapping(item).get("evidence_id"): _mapping(item) for item in evidence}
    source_by_id = {_mapping(item).get("source_id"): _mapping(item) for item in sources}

    for evidence_id, record in evidence_by_id.items():
        location = f"evidence:{evidence_id}"
        if not evidence_id:
            issues.append(
                ValidationIssue("error", "evidence.missing_id", "Evidence has no ID", location)
            )
        source_id = record.get("source_id")
        if source_id not in source_by_id:
            issues.append(
                ValidationIssue(
                    "error",
                    "evidence.unknown_source",
                    f"Evidence references unknown source {source_id!r}",
                    location,
                )
            )
        passage = record.get("passage")
        if not isinstance(passage, str) or not passage.strip():
            issues.append(
                ValidationIssue(
                    "error", "evidence.empty_passage", "Evidence passage is empty", location
                )
            )

    for raw_claim in claims:
        claim = _mapping(raw_claim)
        claim_id = claim.get("claim_id")
        location = f"claim:{claim_id}"
        kind = _enum_value(claim.get("kind"))
        evidence_ids = claim.get("evidence_ids") or []
        if not isinstance(evidence_ids, list):
            evidence_ids = list(evidence_ids)
        unknown = [item for item in evidence_ids if item not in evidence_by_id]
        if unknown:
            issues.append(
                ValidationIssue(
                    "error",
                    "claim.unknown_evidence",
                    f"Claim references unknown evidence: {', '.join(map(str, unknown))}",
                    location,
                )
            )
        if kind == "sourced_fact" and not evidence_ids:
            issues.append(
                ValidationIssue(
                    "error",
                    "claim.unsupported_fact",
                    "A sourced fact must reference at least one evidence record",
                    location,
                )
            )
        if (
            kind == "sourced_fact"
            and evidence_ids
            and not _claim_text_is_attributable(
                str(claim.get("text", "")), evidence_ids, evidence_by_id
            )
        ):
            issues.append(
                ValidationIssue(
                    "error",
                    "claim.text_not_attributable",
                    "A sourced fact must be directly attributable to a cited evidence passage; "
                    "classify paraphrases or synthesis as an inference",
                    location,
                )
            )
        if kind != "sourced_fact" and not claim.get("limitations"):
            issues.append(
                ValidationIssue(
                    "warning",
                    "claim.unqualified_non_fact",
                    "A non-factual claim should explain its limitation",
                    location,
                )
            )
        supporting_sources = {
            evidence_by_id[item].get("source_id") for item in evidence_ids if item in evidence_by_id
        }
        statuses = {
            _enum_value(source_by_id[item].get("status"))
            for item in supporting_sources
            if item in source_by_id
        }
        if statuses and statuses <= {"retracted", "withdrawn"} and not claim.get("limitations"):
            issues.append(
                ValidationIssue(
                    "error",
                    "claim.retracted_only_support",
                    "Retracted or withdrawn evidence cannot be sole unqualified support",
                    location,
                )
            )
    return ValidationReport(tuple(issues))


def validate_manifest_shape(manifest: dict[str, Any]) -> ValidationReport:
    issues: list[ValidationIssue] = []
    required = {
        "schema_version",
        "run_id",
        "status",
        "created_at",
        "updated_at",
        "request",
        "plan",
        "software",
        "capabilities",
        "state",
        "execution",
        "records",
        "artifacts",
        "event_log",
        "limitations",
        "errors",
    }
    for key in sorted(required - manifest.keys()):
        issues.append(
            ValidationIssue("error", "manifest.missing_field", f"Missing field {key}", "manifest")
        )
    if manifest.get("schema_version") != "1.0":
        issues.append(
            ValidationIssue(
                "error",
                "manifest.schema_version",
                "Unsupported manifest schema version",
                "manifest",
            )
        )
    status = _enum_value(manifest.get("status"))
    if status not in RUN_STATUSES:
        issues.append(ValidationIssue("error", "manifest.status", "Invalid run status", "manifest"))
    state = manifest.get("state")
    if not isinstance(state, dict):
        issues.append(
            ValidationIssue(
                "error",
                "manifest.missing_state",
                "Runs must index request, plan, checkpoint, and execution state",
                "manifest",
            )
        )
    else:
        missing_state = set(STATE_PROJECTIONS) - state.keys()
        extra_state = state.keys() - set(STATE_PROJECTIONS)
        for name in sorted(missing_state):
            issues.append(
                ValidationIssue(
                    "error",
                    "manifest.missing_state_projection",
                    f"State is missing {name}",
                    "manifest",
                )
            )
        for name in sorted(extra_state):
            issues.append(
                ValidationIssue(
                    "error",
                    "manifest.extra_state_projection",
                    f"State contains unsupported projection {name}",
                    "manifest",
                )
            )
        for name in STATE_PROJECTIONS:
            if name in state:
                _validate_index_shape(name, state[name], issues, expected_count=1)

    execution = manifest.get("execution")
    if not isinstance(execution, dict):
        issues.append(
            ValidationIssue(
                "error",
                "manifest.missing_execution",
                "Runs must embed execution state",
                "manifest",
            )
        )
    else:
        required_execution = {
            "status",
            "completed_steps",
            "step_statuses",
            "network_requests_used",
        }
        for key in sorted(required_execution - execution.keys()):
            issues.append(
                ValidationIssue(
                    "error",
                    "execution.missing_field",
                    f"Execution is missing {key}",
                    "manifest",
                )
            )
        if _enum_value(execution.get("status")) not in RUN_STATUSES:
            issues.append(
                ValidationIssue("error", "execution.status", "Invalid execution status", "manifest")
            )
        completed = execution.get("completed_steps")
        if not isinstance(completed, list) or not all(isinstance(item, str) for item in completed):
            issues.append(
                ValidationIssue(
                    "error",
                    "execution.completed_steps_shape",
                    "Execution completed_steps must be a string array",
                    "manifest",
                )
            )
        elif len(completed) != len(set(completed)):
            issues.append(
                ValidationIssue(
                    "error",
                    "execution.completed_steps_unique",
                    "Execution completed_steps must be unique",
                    "manifest",
                )
            )
        network_used = execution.get("network_requests_used")
        if isinstance(network_used, bool) or not isinstance(network_used, int) or network_used < 0:
            issues.append(
                ValidationIssue(
                    "error",
                    "execution.network_usage_shape",
                    "Execution network_requests_used must be a non-negative integer",
                    "manifest",
                )
            )

    records = manifest.get("records")
    if isinstance(records, dict):
        for name in RECORD_PROJECTIONS:
            if name not in records:
                issues.append(
                    ValidationIssue(
                        "error", "records.missing_path", f"Missing {name} path", "manifest"
                    )
                )
            else:
                _validate_index_shape(name, records[name], issues)

    event_head = _mapping_or_empty(manifest.get("event_log")).get("head_hash")
    if event_head is not None and not SHA256_PATTERN.fullmatch(str(event_head)):
        issues.append(
            ValidationIssue("error", "manifest.event_hash", "Invalid event head hash", "manifest")
        )
    return ValidationReport(tuple(issues))


def _validate_index_shape(
    name: str,
    raw_index: Any,
    issues: list[ValidationIssue],
    *,
    expected_count: int | None = None,
) -> None:
    if not isinstance(raw_index, Mapping):
        issues.append(
            ValidationIssue("error", "index.shape", f"{name} index is not an object", "manifest")
        )
        return
    path = raw_index.get("path")
    digest = raw_index.get("sha256")
    count = raw_index.get("count")
    if (
        not isinstance(path, str)
        or not path
        or Path(path).is_absolute()
        or ".." in Path(path).parts
    ):
        issues.append(
            ValidationIssue("error", "index.path", f"{name} index has an unsafe path", "manifest")
        )
    if not isinstance(digest, str) or not SHA256_PATTERN.fullmatch(digest):
        issues.append(
            ValidationIssue("error", "index.hash", f"{name} index has an invalid hash", "manifest")
        )
    if isinstance(count, bool) or not isinstance(count, int) or count < 0:
        issues.append(
            ValidationIssue(
                "error", "index.count", f"{name} index has an invalid count", "manifest"
            )
        )
    elif expected_count is not None and count != expected_count:
        issues.append(
            ValidationIssue(
                "error",
                "index.count",
                f"{name} state index must have count={expected_count}",
                "manifest",
            )
        )


def validate_run(run_directory: Path) -> ValidationReport:
    """Validate a native run and every integrity link needed for replay/export."""

    issues: list[ValidationIssue] = []
    try:
        store = RunStore.open(run_directory)
    except (OSError, ValueError) as error:
        return ValidationReport(
            (ValidationIssue("error", "run.unreadable", str(error), str(run_directory)),)
        )

    try:
        issues.extend(
            ValidationIssue("error", "events.integrity", message, "events.jsonl")
            for message in store.verify_event_chain()
        )
        events = store.read_events()
    except (OSError, ValueError, json.JSONDecodeError) as error:
        issues.append(ValidationIssue("error", "events.unreadable", str(error), "events.jsonl"))
        events = []

    manifest_path = store.run_directory / "manifest.json"
    if not manifest_path.exists():
        issues.append(
            ValidationIssue(
                "error", "manifest.missing", "manifest.json is missing", "manifest.json"
            )
        )
        issues.extend(_scan_for_secrets(store.run_directory))
        return ValidationReport(tuple(issues))
    if manifest_path.is_symlink():
        issues.append(
            ValidationIssue(
                "error", "security.symlink", "manifest.json must not be a symlink", "manifest.json"
            )
        )

    try:
        manifest = store.read_json("manifest.json")
        if not isinstance(manifest, dict):
            raise TypeError("manifest root is not an object")
    except (OSError, ValueError, json.JSONDecodeError, TypeError) as error:
        issues.append(ValidationIssue("error", "manifest.unreadable", str(error), "manifest.json"))
        issues.extend(_scan_for_secrets(store.run_directory))
        return ValidationReport(tuple(issues))
    issues.extend(validate_manifest_shape(manifest).issues)

    run_id = manifest.get("run_id")
    if run_id != store.run_directory.name:
        issues.append(
            ValidationIssue(
                "error",
                "manifest.run_id",
                "Manifest run_id does not match the run directory",
                "manifest.json",
            )
        )

    status = str(_enum_value(manifest.get("status")))
    state = _mapping_or_empty(manifest.get("state"))
    state_documents: dict[str, Any] = {}
    for name in STATE_PROJECTIONS:
        index = state.get(name)
        if index is None:
            issues.append(
                ValidationIssue(
                    "error",
                    "state.missing",
                    f"Missing {name} state index",
                    "manifest.json",
                )
            )
            continue
        document = _load_indexed_json(store, name, index, issues)
        if document is not None:
            state_documents[name] = document

    request_data = state_documents.get("request")
    plan_data = state_documents.get("plan")
    execution = state_documents.get("execution")
    _validate_embedded_state("request", request_data, manifest.get("request"), issues)
    _validate_embedded_state("plan", plan_data, manifest.get("plan"), issues)
    if request_data is not None:
        _deserialize_one("request", ResearchRequest, request_data, issues)
    if plan_data is not None:
        _deserialize_one("plan", ResearchPlan, plan_data, issues)
    if execution is not None and manifest.get("execution") != execution:
        issues.append(
            ValidationIssue(
                "error",
                "execution.embedded_mismatch",
                "Embedded execution state does not match execution.json",
                "manifest.json",
            )
        )

    records = _mapping_or_empty(manifest.get("records"))
    loaded: dict[str, list[dict[str, Any]]] = {}
    record_types: dict[str, type[Any]] = {
        "sources": SourceRecord,
        "evidence": EvidenceRecord,
        "claims": Claim,
        "policy_decisions": PolicyDecision,
    }
    for name, record_type in record_types.items():
        index = records.get(name)
        if not isinstance(index, Mapping):
            issues.append(
                ValidationIssue("error", "records.missing_path", f"Missing {name} path", "manifest")
            )
            continue
        data = _load_indexed_json(store, name, index, issues, require_array=True)
        if not isinstance(data, list):
            continue
        loaded[name] = data
        if index.get("count") != len(data):
            issues.append(
                ValidationIssue(
                    "error",
                    "records.count",
                    f"{name} count does not match manifest",
                    str(index.get("path")),
                )
            )
        for position, item in enumerate(data):
            _deserialize_one(f"{name}[{position}]", record_type, item, issues)

    if {"claims", "evidence", "sources"} <= loaded.keys():
        issues.extend(
            validate_claim_evidence(loaded["claims"], loaded["evidence"], loaded["sources"]).issues
        )

    capabilities = manifest.get("capabilities", [])
    if not isinstance(capabilities, list):
        issues.append(
            ValidationIssue(
                "error", "domain.capabilities", "Capabilities must be an array", "manifest.json"
            )
        )
    else:
        for position, capability in enumerate(capabilities):
            _deserialize_one(f"capabilities[{position}]", CapabilityDescriptor, capability, issues)

    artifacts = manifest.get("artifacts", [])
    if not isinstance(artifacts, list):
        issues.append(
            ValidationIssue("error", "domain.artifacts", "Artifacts must be an array", "manifest")
        )
        artifacts = []
    artifact_contents: dict[str, bytes] = {}
    for position, raw_artifact in enumerate(artifacts):
        try:
            artifact = _mapping(raw_artifact)
        except TypeError as error:
            issues.append(
                ValidationIssue("error", "domain.artifact", str(error), f"artifacts[{position}]")
            )
            continue
        _deserialize_one(f"artifacts[{position}]", ArtifactRecord, artifact, issues)
        object_path = artifact.get("object_path")
        if not object_path:
            issues.append(
                ValidationIssue(
                    "error", "artifact.missing_object", "Artifact has no object path", "manifest"
                )
            )
            continue
        try:
            path = store.path_for(str(object_path))
        except (OSError, ValueError) as error:
            issues.append(ValidationIssue("error", "artifact.path", str(error), "manifest"))
            continue
        if path.is_symlink():
            issues.append(
                ValidationIssue(
                    "error",
                    "security.symlink",
                    f"Artifact object must not be a symlink: {object_path}",
                    str(object_path),
                )
            )
            continue
        if not path.is_file():
            issues.append(
                ValidationIssue(
                    "error", "artifact.missing", f"Missing artifact {object_path}", "manifest"
                )
            )
            continue
        content = path.read_bytes()
        artifact_contents[str(artifact.get("name", ""))] = content
        if len(content) != artifact.get("size"):
            issues.append(
                ValidationIssue(
                    "error", "artifact.size", f"Artifact size mismatch: {object_path}", "manifest"
                )
            )
        if sha256_file(path) != artifact.get("sha256"):
            issues.append(
                ValidationIssue(
                    "error", "artifact.hash", f"Artifact hash mismatch: {object_path}", "manifest"
                )
            )

    _validate_report_copy(store, status, artifact_contents, issues)
    report_index = manifest.get("report")
    if report_index is not None:
        _validate_file_index(store, "report", report_index, issues)
    issues.extend(validate_persisted_semantics(manifest, state_documents, events).issues)

    event_index = _mapping_or_empty(manifest.get("event_log"))
    if event_index.get("path") not in {None, "events.jsonl"}:
        issues.append(
            ValidationIssue(
                "error", "events.path", "Event log path must be events.jsonl", "manifest.json"
            )
        )
    if event_index.get("events") != len(events):
        issues.append(
            ValidationIssue(
                "error", "events.count", "Event count does not match manifest", "manifest"
            )
        )
    head_hash = events[-1].get("event_hash") if events else ZERO_HASH
    if event_index.get("head_hash") != head_hash:
        issues.append(
            ValidationIssue("error", "events.head", "Event head hash does not match", "manifest")
        )

    issues.extend(_scan_for_secrets(store.run_directory))
    return ValidationReport(tuple(issues))


def _load_indexed_json(
    store: RunStore,
    name: str,
    raw_index: Any,
    issues: list[ValidationIssue],
    *,
    require_array: bool = False,
) -> Any | None:
    if not isinstance(raw_index, Mapping):
        issues.append(
            ValidationIssue("error", "state.index", f"{name} index is not an object", "manifest")
        )
        return None
    relative_path = raw_index.get("path")
    if not isinstance(relative_path, str) or not relative_path:
        issues.append(
            ValidationIssue("error", "state.path", f"Missing {name} state path", "manifest")
        )
        return None
    try:
        path = store.path_for(relative_path)
        if path.is_symlink():
            raise ValueError(f"{relative_path} must not be a symlink")
        data = store.read_json(relative_path)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        issues.append(ValidationIssue("error", "state.unreadable", str(error), relative_path))
        return None
    if raw_index.get("sha256") != sha256_file(path):
        code = "records.hash" if require_array else "state.hash"
        issues.append(
            ValidationIssue("error", code, f"{name} hash does not match manifest", relative_path)
        )
    if not require_array and raw_index.get("count") != 1:
        issues.append(
            ValidationIssue(
                "error",
                "state.count",
                f"{name} state index must have count=1",
                relative_path,
            )
        )
    if require_array and not isinstance(data, list):
        issues.append(
            ValidationIssue("error", "records.not_array", f"{name} is not an array", relative_path)
        )
        return None
    return data


def _validate_file_index(
    store: RunStore, name: str, raw_index: Any, issues: list[ValidationIssue]
) -> None:
    if not isinstance(raw_index, Mapping):
        issues.append(ValidationIssue("error", "state.index", f"Invalid {name} index", "manifest"))
        return
    path_value = raw_index.get("path")
    if not isinstance(path_value, str) or not path_value:
        issues.append(ValidationIssue("error", "state.path", f"Missing {name} path", "manifest"))
        return
    try:
        path = store.path_for(path_value)
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"{path_value} is not a regular file")
    except (OSError, ValueError) as error:
        issues.append(ValidationIssue("error", "state.unreadable", str(error), path_value))
        return
    if raw_index.get("sha256") != sha256_file(path):
        issues.append(
            ValidationIssue(
                "error", "state.hash", f"{name} hash does not match manifest", path_value
            )
        )


def _validate_embedded_state(
    name: str,
    projection: Any,
    embedded: Any,
    issues: list[ValidationIssue],
) -> None:
    if projection is None:
        return
    if not isinstance(projection, dict) or not isinstance(embedded, dict):
        issues.append(
            ValidationIssue(
                "error", f"{name}.embedded", f"Embedded {name} is not an object", "manifest.json"
            )
        )
        return
    supplied_hash = embedded.get("hash")
    embedded_data = {key: value for key, value in embedded.items() if key != "hash"}
    if embedded_data != projection:
        issues.append(
            ValidationIssue(
                "error",
                f"{name}.embedded_mismatch",
                f"Embedded {name} does not match {name}.json",
                "manifest.json",
            )
        )
    calculated_hash = sha256_json(projection)
    if supplied_hash != calculated_hash:
        issues.append(
            ValidationIssue(
                "error",
                f"{name}.embedded_hash",
                f"Embedded {name} hash does not match {name}.json",
                "manifest.json",
            )
        )


def _deserialize_one(
    location: str,
    record_type: type[Any],
    value: Any,
    issues: list[ValidationIssue],
) -> None:
    if not isinstance(value, Mapping):
        issues.append(
            ValidationIssue("error", "domain.invalid", f"{location} is not an object", location)
        )
        return
    try:
        record_type.from_dict(value)
    except (TypeError, ValueError) as error:
        issues.append(
            ValidationIssue(
                "error",
                "domain.invalid",
                f"{location} does not satisfy {record_type.__name__}: {error}",
                location,
            )
        )


def validate_persisted_semantics(
    manifest: dict[str, Any],
    documents: Mapping[str, Any],
    events: list[dict[str, Any]],
) -> ValidationReport:
    """Validate cross-projection facts that file hashes alone cannot establish."""

    issues: list[ValidationIssue] = []
    request = documents.get("request")
    plan = documents.get("plan")
    checkpoint = documents.get("checkpoint")
    execution = documents.get("execution")
    _validate_event_identity_bindings(request, plan, events, issues)
    _validate_network_usage(request, checkpoint, execution, events, issues)
    _validate_execution(plan, checkpoint, execution, events, manifest, issues)
    _validate_terminal_status(manifest, events, issues)
    return ValidationReport(tuple(issues))


def _validate_terminal_status(
    manifest: Mapping[str, Any],
    events: list[dict[str, Any]],
    issues: list[ValidationIssue],
) -> None:
    """Bind persisted terminal state to the authoritative final activity event."""

    status = _enum_value(manifest.get("status"))
    expected_events = {
        "created": {"run.created"},
        "running": {"run.finalizing"},
        "completed": {"run.completed"},
        "partial": {"run.partial", "run.interrupted"},
        "failed": {"run.failed"},
        "cancelled": {"run.cancelled"},
        "awaiting_approval": {"run.awaiting_approval"},
    }
    expected = expected_events.get(str(status))
    if expected is None:
        return
    final_type = events[-1].get("type") if events else None
    if final_type not in expected:
        issues.append(
            ValidationIssue(
                "error",
                "events.terminal_status",
                f"Run status {status!r} does not match the final event {final_type!r}",
                "events.jsonl",
            )
        )
        return
    payload = _mapping_or_empty(events[-1].get("payload"))
    if final_type in {"run.completed", "run.partial"} and payload.get("status") != status:
        issues.append(
            ValidationIssue(
                "error",
                "events.terminal_payload",
                "The final run event payload does not match the persisted terminal status",
                "events.jsonl",
            )
        )


def _validate_event_identity_bindings(
    request: Any,
    plan: Any,
    events: list[dict[str, Any]],
    issues: list[ValidationIssue],
) -> None:
    if not isinstance(request, dict) or not isinstance(plan, dict):
        return
    expected = {
        "request_id": request.get("request_id"),
        "request_hash": sha256_json(request),
        "plan_id": plan.get("plan_id"),
        "plan_hash": sha256_json(plan),
    }
    created = [event for event in events if event.get("type") == "run.created"]
    if len(created) != 1:
        issues.append(
            ValidationIssue(
                "error",
                "events.run_created_count",
                "A run must contain exactly one run.created event",
                "events.jsonl",
            )
        )
    elif events and events[0] is not created[0]:
        issues.append(
            ValidationIssue(
                "error",
                "events.run_created_order",
                "run.created must be the first event",
                "events.jsonl",
            )
        )
    for event in created:
        payload = _mapping_or_empty(event.get("payload"))
        for key, value in expected.items():
            if payload.get(key) != value:
                issues.append(
                    ValidationIssue(
                        "error",
                        f"events.run_created_{key}",
                        f"run.created {key} does not match the persisted projection",
                        "events.jsonl",
                    )
                )
    for event in events:
        if event.get("type") != "run.resumed":
            continue
        payload = _mapping_or_empty(event.get("payload"))
        for key in ("request_hash", "plan_hash"):
            if payload.get(key) != expected[key]:
                issues.append(
                    ValidationIssue(
                        "error",
                        f"events.run_resumed_{key}",
                        f"run.resumed {key} does not match the persisted projection",
                        "events.jsonl",
                    )
                )
        for key in ("request_id", "plan_id"):
            if key in payload and payload.get(key) != expected[key]:
                issues.append(
                    ValidationIssue(
                        "error",
                        f"events.run_resumed_{key}",
                        f"run.resumed {key} does not match the persisted projection",
                        "events.jsonl",
                    )
                )


def _validate_network_usage(
    request: Any,
    checkpoint: Any,
    execution: Any,
    events: list[dict[str, Any]],
    issues: list[ValidationIssue],
) -> None:
    if not isinstance(request, dict):
        return
    limits = _mapping_or_empty(request.get("limits"))
    limit = limits.get("max_network_requests")
    if isinstance(limit, bool) or not isinstance(limit, int) or limit < 0:
        return
    used = 0
    for event in events:
        event_type = event.get("type")
        payload = _mapping_or_empty(event.get("payload"))
        if event_type == "network.request_consumed":
            used += 1
            if payload.get("used") != used:
                issues.append(
                    ValidationIssue(
                        "error",
                        "network.usage_not_monotonic",
                        "Network request usage must increase by exactly one",
                        "events.jsonl",
                    )
                )
            if payload.get("limit") != limit or payload.get("remaining") != limit - used:
                issues.append(
                    ValidationIssue(
                        "error",
                        "network.budget_event",
                        "Network request event does not match the approved request limit",
                        "events.jsonl",
                    )
                )
            if used > limit:
                issues.append(
                    ValidationIssue(
                        "error",
                        "network.budget_exceeded",
                        "Recorded network requests exceed the approved request limit",
                        "events.jsonl",
                    )
                )
        elif event_type == "run.resumed" and payload.get("network_requests_used") != used:
            issues.append(
                ValidationIssue(
                    "error",
                    "network.resume_usage",
                    "run.resumed network usage does not match preceding request events",
                    "events.jsonl",
                )
            )
        elif (
            event_type == "run.started"
            and payload.get("network_requests_remaining") != limit - used
        ):
            issues.append(
                ValidationIssue(
                    "error",
                    "network.start_remaining",
                    "run.started remaining network budget is inconsistent",
                    "events.jsonl",
                )
            )
    for name, value in (("checkpoint", checkpoint), ("execution", execution)):
        if isinstance(value, dict) and value.get("network_requests_used") != used:
            issues.append(
                ValidationIssue(
                    "error",
                    f"network.{name}_usage",
                    f"{name} network usage does not match network request events",
                    f"{name}.json",
                )
            )


def _validate_execution(
    plan_data: Any,
    checkpoint: Any,
    execution: Any,
    events: list[dict[str, Any]],
    manifest: dict[str, Any],
    issues: list[ValidationIssue],
) -> None:
    completed_from_events: list[str] = []
    for event in events:
        if event.get("type") != "step.completed":
            continue
        step_id = event.get("step_id")
        if not isinstance(step_id, str) or not step_id:
            issues.append(
                ValidationIssue(
                    "error",
                    "execution.step_event",
                    "A step.completed event has no step_id",
                    "events.jsonl",
                )
            )
            continue
        completed_from_events.append(step_id)
        payload_steps = _mapping_or_empty(event.get("payload")).get("completed_steps")
        if payload_steps is not None and payload_steps != completed_from_events:
            issues.append(
                ValidationIssue(
                    "error",
                    "execution.event_prefix",
                    "step.completed payload is not the completed event prefix",
                    "events.jsonl",
                )
            )
    if len(set(completed_from_events)) != len(completed_from_events):
        issues.append(
            ValidationIssue(
                "error",
                "execution.duplicate_step",
                "A step completed more than once",
                "events.jsonl",
            )
        )

    checkpoint_steps: Any = None
    if isinstance(checkpoint, dict):
        checkpoint_steps = checkpoint.get("completed_steps")
        if checkpoint_steps != completed_from_events:
            issues.append(
                ValidationIssue(
                    "error",
                    "checkpoint.completed_steps",
                    "checkpoint completed_steps do not match step.completed events",
                    "checkpoint.json",
                )
            )
        if checkpoint.get("status") != manifest.get("status"):
            issues.append(
                ValidationIssue(
                    "error",
                    "checkpoint.status",
                    "Checkpoint status does not match manifest status",
                    "checkpoint.json",
                )
            )
    if isinstance(execution, dict):
        if execution.get("completed_steps") != completed_from_events:
            issues.append(
                ValidationIssue(
                    "error",
                    "execution.completed_steps",
                    "Execution completed_steps do not match step.completed events",
                    "execution.json",
                )
            )
        if execution.get("status") != manifest.get("status"):
            issues.append(
                ValidationIssue(
                    "error",
                    "execution.status",
                    "Execution status does not match manifest status",
                    "execution.json",
                )
            )
        if checkpoint_steps is not None and execution.get("completed_steps") != checkpoint_steps:
            issues.append(
                ValidationIssue(
                    "error",
                    "execution.checkpoint_mismatch",
                    "Execution and checkpoint completed steps differ",
                    "execution.json",
                )
            )
        step_statuses = execution.get("step_statuses")
        if not isinstance(step_statuses, dict):
            issues.append(
                ValidationIssue(
                    "error",
                    "execution.step_statuses",
                    "Execution step_statuses must be an object",
                    "execution.json",
                )
            )

    if isinstance(plan_data, dict):
        raw_steps = plan_data.get("steps", [])
        if isinstance(raw_steps, list):
            plan_steps = [item.get("step_id") for item in raw_steps if isinstance(item, dict)]
            if completed_from_events != plan_steps[: len(completed_from_events)]:
                issues.append(
                    ValidationIssue(
                        "error",
                        "execution.plan_prefix",
                        "Completed steps are not a prefix of the approved plan",
                        "events.jsonl",
                    )
                )
            if isinstance(execution, dict):
                step_statuses = execution.get("step_statuses")
                if isinstance(step_statuses, dict):
                    if set(step_statuses) != set(plan_steps):
                        issues.append(
                            ValidationIssue(
                                "error",
                                "execution.step_status_keys",
                                "Execution step statuses do not match the approved plan",
                                "execution.json",
                            )
                        )
                    for step_id in completed_from_events:
                        if step_statuses.get(step_id) != "completed":
                            issues.append(
                                ValidationIssue(
                                    "error",
                                    "execution.completed_step_status",
                                    f"Completed step {step_id} is not marked completed",
                                    "execution.json",
                                )
                            )
                if manifest.get("status") == "completed" and (
                    completed_from_events != plan_steps
                    or not isinstance(step_statuses, dict)
                    or any(step_statuses.get(step_id) != "completed" for step_id in plan_steps)
                ):
                    issues.append(
                        ValidationIssue(
                            "error",
                            "execution.incomplete_completed_run",
                            "A completed run must mark every approved plan step completed",
                            "execution.json",
                        )
                    )


def _validate_report_copy(
    store: RunStore,
    status: str,
    artifact_contents: dict[str, bytes],
    issues: list[ValidationIssue],
) -> None:
    raw_report = store.run_directory / "report.md"
    artifact_content = artifact_contents.get("report.md")
    if raw_report.is_symlink():
        issues.append(
            ValidationIssue(
                "error", "security.symlink", "report.md must not be a symlink", "report.md"
            )
        )
        return
    if raw_report.exists() and not raw_report.is_file():
        issues.append(
            ValidationIssue("error", "report.type", "report.md is not a regular file", "report.md")
        )
        return
    if raw_report.is_file():
        content = raw_report.read_bytes()
        if artifact_content is None:
            issues.append(
                ValidationIssue(
                    "error",
                    "report.missing_artifact",
                    "report.md has no corresponding manifest artifact",
                    "report.md",
                )
            )
        elif content != artifact_content:
            issues.append(
                ValidationIssue(
                    "error",
                    "report.artifact_mismatch",
                    "report.md differs from its content-addressed artifact",
                    "report.md",
                )
            )
    elif artifact_content is not None:
        issues.append(
            ValidationIssue(
                "error", "report.missing", "The report artifact has no report.md copy", "report.md"
            )
        )
    elif status == "completed":
        issues.append(
            ValidationIssue(
                "error", "report.missing", "A completed run must contain report.md", "report.md"
            )
        )


def _scan_for_secrets(root: Path) -> list[ValidationIssue]:
    issues: list[ValidationIssue] = []
    for path in root.rglob("*"):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            try:
                resolved = path.resolve(strict=True)
            except (OSError, RuntimeError):
                resolved = None
            if resolved is None or (resolved != root and root not in resolved.parents):
                issues.append(
                    ValidationIssue(
                        "error",
                        "security.symlink_escape",
                        "A persisted symlink resolves outside the run directory",
                        relative,
                    )
                )
            continue
        if not path.is_file():
            continue
        try:
            with path.open(encoding="utf-8", errors="ignore") as handle:
                carry = ""
                found = False
                while chunk := handle.read(1024 * 1024):
                    text = carry + chunk
                    if any(pattern.search(text) for pattern in SECRET_PATTERNS):
                        found = True
                        break
                    carry = text[-256:]
        except OSError:
            continue
        if found:
            issues.append(
                ValidationIssue(
                    "error",
                    "security.persisted_secret",
                    "A credential-like value is present in persisted data",
                    relative,
                )
            )
    return issues


def _mapping_or_empty(value: Any) -> dict[str, Any]:
    return dict(value) if isinstance(value, Mapping) else {}


def _enum_value(value: Any) -> Any:
    return getattr(value, "value", value)


def _claim_text_is_attributable(
    text: str,
    evidence_ids: list[Any],
    evidence_by_id: dict[Any, dict[str, Any]],
) -> bool:
    normalized_claim = " ".join(unicodedata.normalize("NFKC", text).casefold().split())
    if not normalized_claim:
        return False
    for evidence_id in evidence_ids:
        record = evidence_by_id.get(evidence_id)
        passage = record.get("passage") if record else None
        if not isinstance(passage, str):
            continue
        normalized_passage = " ".join(unicodedata.normalize("NFKC", passage).casefold().split())
        if normalized_claim == normalized_passage:
            return True
    return False
