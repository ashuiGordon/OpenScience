"""Portable, sanitized, internally verifiable research-bundle and RO-Crate export."""

from __future__ import annotations

import json
import os
import stat
import tempfile
import zipfile
from collections.abc import Mapping
from pathlib import Path, PurePosixPath
from typing import Any

from .domain import (
    ArtifactRecord,
    Claim,
    EvidenceRecord,
    PolicyDecision,
    ResearchPlan,
    ResearchRequest,
    SourceRecord,
    sha256_json,
)
from .policy import redact_text
from .storage import ZERO_HASH, RunStore, canonical_json, sha256_bytes
from .validation import (
    SECRET_PATTERNS,
    ValidationIssue,
    ValidationReport,
    validate_claim_evidence,
    validate_manifest_shape,
    validate_persisted_semantics,
    validate_run,
)

RO_CRATE_CONTEXT = "https://w3id.org/ro/crate/1.3/context"
JSON_PROJECTIONS = (
    "request",
    "plan",
    "checkpoint",
    "execution",
    "sources",
    "evidence",
    "claims",
    "policy_decisions",
)
RECORD_PROJECTIONS = ("sources", "evidence", "claims", "policy_decisions")
SENSITIVE_KEYS = {
    "api_key",
    "apikey",
    "authorization",
    "credential",
    "credentials",
    "password",
    "secret",
    "token",
}


def export_run(run_directory: Path, output: Path) -> Path:
    """Export a validated run without leaking credentials or host filesystem roots."""

    store = RunStore.open(run_directory)
    raw_report = store.run_directory / "report.md"
    if raw_report.is_symlink():
        raise ValueError("cannot export a run whose report.md is a symlink")
    validation = validate_run(store.run_directory)
    if not validation.valid:
        message = "; ".join(issue.message for issue in validation.errors)
        raise ValueError(f"cannot export an invalid run: {message}")

    output = output.expanduser().resolve()
    if output == store.run_directory or store.run_directory in output.parents:
        raise ValueError("export must be outside the run directory")
    output.parent.mkdir(parents=True, exist_ok=True)

    native_manifest = store.read_json("manifest.json")
    local_roots = _local_roots(store)
    documents = _sanitized_documents(store, local_roots)
    events = _rechain_events(store.read_events(), documents, local_roots)
    entries: dict[str, bytes] = {
        f"{name}.json": _json_bytes(value) for name, value in documents.items()
    }
    entries["events.jsonl"] = _event_bytes(events)

    artifacts, artifact_entries = _export_artifacts(store, native_manifest, local_roots)
    entries.update(artifact_entries)
    report_artifact = next((item for item in artifacts if item.get("name") == "report.md"), None)
    if report_artifact is not None:
        entries["report.md"] = entries[str(report_artifact["object_path"])]

    manifest = _export_manifest(native_manifest, documents, events, artifacts, entries, local_roots)
    entries["manifest.json"] = _json_bytes(manifest)
    entries["ro-crate-metadata.json"] = _json_bytes(
        _ro_crate_metadata(manifest, documents, entries)
    )
    entries["checksums.txt"] = _checksum_bytes(entries)
    _assert_roots_removed(entries, local_roots)

    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output.name}.", dir=output.parent)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, content in sorted(entries.items()):
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100600 << 16
                archive.writestr(info, content)
        bundle_report = validate_export_bundle(temporary)
        if not bundle_report.valid:
            message = "; ".join(issue.message for issue in bundle_report.errors)
            raise ValueError(f"generated export failed self-validation: {message}")
        os.replace(temporary, output)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    return output


def validate_export_bundle(bundle: Path) -> ValidationReport:
    """Validate checksums, projections, event chain, artifacts, and RO-Crate in a ZIP."""

    issues: list[ValidationIssue] = []
    try:
        entries = _read_zip_safely(bundle, issues)
    except (OSError, zipfile.BadZipFile, ValueError) as error:
        return ValidationReport(
            (ValidationIssue("error", "bundle.unreadable", str(error), str(bundle)),)
        )
    if issues:
        return ValidationReport(tuple(issues))

    _validate_checksums(entries, issues)
    _scan_export_secrets(entries, issues)
    manifest = _entry_json(entries, "manifest.json", issues, expected=dict)
    if not isinstance(manifest, dict):
        return ValidationReport(tuple(issues))
    issues.extend(validate_manifest_shape(manifest).issues)

    documents: dict[str, Any] = {}
    for name in JSON_PROJECTIONS:
        filename = f"{name}.json"
        if filename in entries:
            documents[name] = _entry_json(entries, filename, issues)

    events = _entry_events(entries, issues)
    _validate_export_events(events, manifest, issues)
    _validate_export_indexes(entries, manifest, documents, issues)
    _validate_export_domains(documents, manifest, issues)
    issues.extend(validate_persisted_semantics(manifest, documents, events).issues)
    _validate_export_artifacts(entries, manifest, issues)
    _validate_export_ro_crate(entries, documents, issues)
    return ValidationReport(tuple(issues))


def _local_roots(store: RunStore) -> tuple[str, ...]:
    request = store.read_json("request.json")
    if not isinstance(request, dict):
        return ()
    roots = request.get("approved_local_roots", [])
    if not isinstance(roots, list):
        return ()
    return tuple(
        item for item in roots if isinstance(item, str) and item and Path(item).is_absolute()
    )


def _sanitized_documents(store: RunStore, local_roots: tuple[str, ...]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for name in JSON_PROJECTIONS:
        relative = f"{name}.json"
        raw = store.run_directory / relative
        if not raw.exists():
            continue
        if raw.is_symlink():
            raise ValueError(f"cannot export symlinked projection: {relative}")
        value = _sanitize(store.read_json(relative), local_roots)
        if name == "request":
            if not isinstance(value, dict):
                raise ValueError("request.json must contain an object")
            value["approved_local_roots"] = []
            value.pop("request_id", None)
            value = ResearchRequest.from_dict(value).to_dict()
        elif name == "plan":
            if not isinstance(value, dict):
                raise ValueError("plan.json must contain an object")
            value.pop("plan_id", None)
            value = ResearchPlan.from_dict(value).to_dict()
        elif name == "policy_decisions":
            if not isinstance(value, list):
                raise ValueError("policy_decisions.json must contain an array")
            value = [_sanitize_policy_decision(item, local_roots) for item in value]
        result[name] = value
    return result


def _rechain_events(
    events: list[dict[str, Any]],
    documents: dict[str, Any],
    local_roots: tuple[str, ...],
) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    previous_hash = ZERO_HASH
    request = documents.get("request")
    plan = documents.get("plan")
    identities = _projection_identities(request, plan)
    for event in events:
        sanitized = _sanitize(event, local_roots)
        if not isinstance(sanitized, dict):
            raise ValueError("event is not an object")
        payload = sanitized.get("payload")
        if isinstance(payload, dict):
            _rewrite_projection_references(payload, identities)
            if sanitized.get("type") in {"run.created", "run.resumed"}:
                payload.update(identities)
            elif sanitized.get("type") == "run.awaiting_approval":
                payload["plan_id"] = identities["plan_id"]
                payload["plan_hash"] = identities["plan_hash"]
            if sanitized.get("type") == "policy.decided":
                sanitized["payload"] = _sanitize_policy_decision(payload, local_roots)
        sanitized.pop("event_hash", None)
        sanitized["previous_hash"] = previous_hash
        sanitized["event_hash"] = sha256_bytes(canonical_json(sanitized).encode("utf-8"))
        previous_hash = sanitized["event_hash"]
        result.append(sanitized)
    return result


def _export_artifacts(
    store: RunStore,
    manifest: dict[str, Any],
    local_roots: tuple[str, ...],
) -> tuple[list[dict[str, Any]], dict[str, bytes]]:
    exported: list[dict[str, Any]] = []
    entries: dict[str, bytes] = {}
    used_paths: set[str] = set()
    for position, raw in enumerate(manifest.get("artifacts", [])):
        if not isinstance(raw, Mapping):
            raise ValueError(f"artifact {position} is not an object")
        artifact = dict(raw)
        object_path = artifact.get("object_path")
        if not isinstance(object_path, str) or not object_path:
            raise ValueError(f"artifact {position} has no object_path")
        source = store.path_for(object_path)
        if source.is_symlink() or not source.is_file():
            raise ValueError(f"artifact object is not a regular file: {object_path}")
        content = source.read_bytes()  # The immutable CAS copy is authoritative.
        media_type = str(artifact.get("media_type", "application/octet-stream"))
        content = _sanitize_artifact(content, media_type, local_roots)
        digest = sha256_bytes(content)
        safe = _safe_name(str(artifact.get("name", "artifact")))
        export_path = f"artifacts/{safe}"
        if export_path in used_paths:
            export_path = f"artifacts/{digest[:12]}-{safe}"
        used_paths.add(export_path)
        entries[export_path] = content
        artifact.update(
            {
                "sha256": digest,
                "size": len(content),
                "object_path": export_path,
                "export_path": export_path,
            }
        )
        artifact["artifact_id"] = _artifact_id(artifact)
        exported.append(_sanitize(artifact, local_roots))
    return exported, entries


def _export_manifest(
    native: dict[str, Any],
    documents: dict[str, Any],
    events: list[dict[str, Any]],
    artifacts: list[dict[str, Any]],
    entries: dict[str, bytes],
    local_roots: tuple[str, ...],
) -> dict[str, Any]:
    manifest = _sanitize(native, local_roots)
    if not isinstance(manifest, dict):
        raise ValueError("manifest is not an object")
    request = documents.get("request")
    plan = documents.get("plan")
    if isinstance(request, dict):
        manifest["request"] = {**request, "hash": sha256_json(request)}
    if isinstance(plan, dict):
        manifest["plan"] = {**plan, "hash": sha256_json(plan)}
    state: dict[str, dict[str, Any]] = {}
    for name in ("request", "plan", "checkpoint", "execution"):
        filename = f"{name}.json"
        if filename in entries:
            state[name] = _file_index(filename, entries[filename], count=1)
    manifest["state"] = state
    if "execution" in documents:
        manifest["execution"] = documents["execution"]
    else:
        manifest.pop("execution", None)
    manifest["records"] = {
        name: {
            **_file_index(f"{name}.json", entries[f"{name}.json"]),
            "count": len(documents.get(name, [])),
        }
        for name in RECORD_PROJECTIONS
        if f"{name}.json" in entries
    }
    manifest["artifacts"] = artifacts
    manifest["event_log"] = {
        "path": "events.jsonl",
        "events": len(events),
        "head_hash": events[-1]["event_hash"] if events else ZERO_HASH,
    }
    if "report.md" in entries:
        manifest["report"] = _file_index("report.md", entries["report.md"], count=1)
    else:
        manifest.pop("report", None)
    return manifest


def _ro_crate_metadata(
    manifest: dict[str, Any], documents: dict[str, Any], entries: dict[str, bytes]
) -> dict[str, Any]:
    run_id = str(manifest.get("run_id", "unknown"))
    request = documents.get("request", {})
    question = (
        str(request.get("question", "Research run"))
        if isinstance(request, dict)
        else "Research run"
    )
    graph: list[dict[str, Any]] = [
        {
            "@id": "ro-crate-metadata.json",
            "@type": "CreativeWork",
            "about": {"@id": "./"},
            "conformsTo": {"@id": "https://w3id.org/ro/crate/1.3"},
        },
        {
            "@id": "./",
            "@type": "Dataset",
            "name": f"OpenScience research run {run_id}",
            "description": question,
            "datePublished": manifest.get("updated_at"),
            "hasPart": [{"@id": name} for name in sorted(entries)],
            "mentions": [{"@id": "#run"}, {"@id": "#plan"}],
        },
        {
            "@id": "#openscience-agent",
            "@type": "SoftwareApplication",
            "name": "OpenScience Agent",
            "softwareVersion": manifest.get("software", {}).get("version", "unknown"),
        },
        {
            "@id": "#run",
            "@type": "CreateAction",
            "name": "Evidence-backed research synthesis",
            "actionStatus": _action_status(str(manifest.get("status", "unknown"))),
            "startTime": manifest.get("created_at"),
            "endTime": manifest.get("updated_at"),
            "instrument": {"@id": "#openscience-agent"},
            "object": {"@id": "#plan"},
            "result": {"@id": "report.md"},
        },
    ]
    for name, content in sorted(entries.items()):
        graph.append(
            {
                "@id": name,
                "@type": "File",
                "name": name,
                "contentSize": len(content),
                "sha256": sha256_bytes(content),
                "encodingFormat": _media_type(name),
            }
        )

    plan = documents.get("plan", {})
    raw_steps = plan.get("steps", []) if isinstance(plan, dict) else []
    step_refs: list[dict[str, str]] = []
    for position, step in enumerate(raw_steps, start=1):
        if not isinstance(step, dict):
            continue
        step_id = f"#plan-step-{step.get('step_id', position)}"
        step_refs.append({"@id": step_id})
        graph.append(
            {
                "@id": step_id,
                "@type": "HowToStep",
                "position": position,
                "name": step.get("title"),
                "description": step.get("purpose"),
            }
        )
    graph.append(
        {
            "@id": "#plan",
            "@type": "HowTo",
            "name": "Approved research plan",
            "step": step_refs,
        }
    )

    for source in documents.get("sources", []):
        if not isinstance(source, dict):
            continue
        graph.append(
            {
                "@id": f"#source-{source.get('source_id')}",
                "@type": "ScholarlyArticle",
                "name": source.get("title"),
                "identifier": source.get("canonical_id"),
                "url": source.get("landing_url"),
            }
        )
    for evidence in documents.get("evidence", []):
        if not isinstance(evidence, dict):
            continue
        graph.append(
            {
                "@id": f"#evidence-{evidence.get('evidence_id')}",
                "@type": "CreativeWork",
                "text": evidence.get("passage"),
                "isBasedOn": {"@id": f"#source-{evidence.get('source_id')}"},
            }
        )
    for claim in documents.get("claims", []):
        if not isinstance(claim, dict):
            continue
        graph.append(
            {
                "@id": f"#claim-{claim.get('claim_id')}",
                "@type": "Claim",
                "text": claim.get("text"),
                "citation": [
                    {"@id": f"#evidence-{evidence_id}"}
                    for evidence_id in claim.get("evidence_ids", [])
                ],
            }
        )
    return {"@context": RO_CRATE_CONTEXT, "@graph": graph}


def _read_zip_safely(bundle: Path, issues: list[ValidationIssue]) -> dict[str, bytes]:
    entries: dict[str, bytes] = {}
    with zipfile.ZipFile(bundle) as archive:
        total_size = 0
        for info in archive.infolist():
            name = info.filename
            pure = PurePosixPath(name)
            if (
                not name
                or pure.is_absolute()
                or ".." in pure.parts
                or "\\" in name
                or name in entries
            ):
                issues.append(
                    ValidationIssue(
                        "error", "bundle.path", f"Unsafe or duplicate ZIP path: {name}", name
                    )
                )
                continue
            mode = info.external_attr >> 16
            if stat.S_ISLNK(mode):
                issues.append(
                    ValidationIssue(
                        "error", "bundle.symlink", f"ZIP entry is a symlink: {name}", name
                    )
                )
                continue
            total_size += info.file_size
            if info.file_size > 1_000_000_000 or total_size > 2_000_000_000:
                raise ValueError("bundle exceeds the validation size limit")
            entries[name] = archive.read(info)
    return entries


def _validate_checksums(entries: dict[str, bytes], issues: list[ValidationIssue]) -> None:
    payload = entries.get("checksums.txt")
    if payload is None:
        issues.append(
            ValidationIssue("error", "bundle.checksums_missing", "checksums.txt is missing", None)
        )
        return
    try:
        lines = payload.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        issues.append(ValidationIssue("error", "bundle.checksums", str(error), "checksums.txt"))
        return
    listed: dict[str, str] = {}
    for line in lines:
        digest, separator, name = line.partition("  ")
        if not separator or len(digest) != 64 or name in listed:
            issues.append(
                ValidationIssue(
                    "error", "bundle.checksums", "Malformed checksum line", "checksums.txt"
                )
            )
            continue
        listed[name] = digest
    expected_names = set(entries) - {"checksums.txt"}
    if set(listed) != expected_names:
        issues.append(
            ValidationIssue(
                "error",
                "bundle.checksums_index",
                "checksums.txt does not list every bundle entry exactly once",
                "checksums.txt",
            )
        )
    for name, digest in listed.items():
        content = entries.get(name)
        if content is not None and sha256_bytes(content) != digest:
            issues.append(
                ValidationIssue(
                    "error", "bundle.checksum", f"Checksum mismatch for {name}", "checksums.txt"
                )
            )


def _validate_export_events(
    events: list[dict[str, Any]], manifest: dict[str, Any], issues: list[ValidationIssue]
) -> None:
    previous_hash = ZERO_HASH
    run_id = manifest.get("run_id")
    for sequence, event in enumerate(events, start=1):
        if event.get("sequence") != sequence:
            issues.append(
                ValidationIssue(
                    "error", "events.sequence", "Invalid event sequence", "events.jsonl"
                )
            )
        if event.get("run_id") != run_id:
            issues.append(
                ValidationIssue("error", "events.run_id", "Event run_id mismatch", "events.jsonl")
            )
        if event.get("previous_hash") != previous_hash:
            issues.append(
                ValidationIssue(
                    "error", "events.previous_hash", "Invalid previous hash", "events.jsonl"
                )
            )
        supplied = event.get("event_hash")
        unhashed = {key: value for key, value in event.items() if key != "event_hash"}
        calculated = sha256_bytes(canonical_json(unhashed).encode("utf-8"))
        if supplied != calculated:
            issues.append(
                ValidationIssue("error", "events.hash", "Invalid event hash", "events.jsonl")
            )
        previous_hash = str(supplied or "")
    event_index = manifest.get("event_log", {})
    if not isinstance(event_index, dict):
        issues.append(
            ValidationIssue("error", "events.index", "Invalid event index", "manifest.json")
        )
        return
    if event_index.get("events") != len(events):
        issues.append(
            ValidationIssue("error", "events.count", "Event count mismatch", "manifest.json")
        )
    if event_index.get("head_hash") != (events[-1].get("event_hash") if events else ZERO_HASH):
        issues.append(
            ValidationIssue("error", "events.head", "Event head mismatch", "manifest.json")
        )


def _validate_export_indexes(
    entries: dict[str, bytes],
    manifest: dict[str, Any],
    documents: dict[str, Any],
    issues: list[ValidationIssue],
) -> None:
    state = manifest.get("state", {})
    if not isinstance(state, dict):
        return
    expected_state = {"request", "plan", "checkpoint", "execution"}
    if set(state) != expected_state:
        issues.append(
            ValidationIssue(
                "error",
                "state.projections",
                "State must contain exactly request, plan, checkpoint, and execution",
                "manifest.json",
            )
        )
    for name in expected_state:
        index = state.get(name)
        if not isinstance(index, dict):
            issues.append(
                ValidationIssue("error", "state.index", f"Invalid {name} index", "manifest.json")
            )
            continue
        path = index.get("path")
        content = entries.get(path) if isinstance(path, str) else None
        if (
            content is None
            or index.get("sha256") != sha256_bytes(content)
            or index.get("count") != 1
        ):
            issues.append(
                ValidationIssue(
                    "error", "state.hash", f"Invalid {name} state hash", "manifest.json"
                )
            )
    records = manifest.get("records", {})
    if not isinstance(records, dict):
        return
    for name in RECORD_PROJECTIONS:
        index = records.get(name)
        records_value = documents.get(name)
        if not isinstance(index, dict) or not isinstance(records_value, list):
            issues.append(
                ValidationIssue("error", "records.index", f"Invalid {name} index", "manifest.json")
            )
            continue
        path = index.get("path")
        content = entries.get(path) if isinstance(path, str) else None
        if content is None or index.get("sha256") != sha256_bytes(content):
            issues.append(
                ValidationIssue("error", "records.hash", f"Invalid {name} hash", "manifest.json")
            )
        if index.get("count") != len(records_value):
            issues.append(
                ValidationIssue("error", "records.count", f"Invalid {name} count", "manifest.json")
            )
    report = manifest.get("report")
    if report is not None:
        if not isinstance(report, dict):
            issues.append(
                ValidationIssue("error", "report.index", "Invalid report index", "manifest.json")
            )
        else:
            report_path = report.get("path")
            content = entries.get(report_path) if isinstance(report_path, str) else None
            if (
                content is None
                or report.get("sha256") != sha256_bytes(content)
                or report.get("count") != 1
            ):
                issues.append(
                    ValidationIssue("error", "report.hash", "Invalid report index", "manifest.json")
                )


def _validate_export_domains(
    documents: dict[str, Any], manifest: dict[str, Any], issues: list[ValidationIssue]
) -> None:
    request = documents.get("request")
    plan = documents.get("plan")
    _validate_domain("request", ResearchRequest, request, issues)
    _validate_domain("plan", ResearchPlan, plan, issues)
    for name, record_type in (
        ("sources", SourceRecord),
        ("evidence", EvidenceRecord),
        ("claims", Claim),
        ("policy_decisions", PolicyDecision),
    ):
        values = documents.get(name)
        if not isinstance(values, list):
            continue
        for position, value in enumerate(values):
            _validate_domain(f"{name}[{position}]", record_type, value, issues)
    if isinstance(request, dict):
        embedded = manifest.get("request", {})
        if not isinstance(embedded, dict):
            issues.append(
                ValidationIssue(
                    "error", "request.embedded", "Invalid embedded request", "manifest.json"
                )
            )
        else:
            data = {key: value for key, value in embedded.items() if key != "hash"}
            if data != request or embedded.get("hash") != sha256_json(request):
                issues.append(
                    ValidationIssue(
                        "error", "request.hash", "Embedded request mismatch", "manifest.json"
                    )
                )
    if isinstance(plan, dict):
        embedded = manifest.get("plan", {})
        if not isinstance(embedded, dict):
            issues.append(
                ValidationIssue("error", "plan.embedded", "Invalid embedded plan", "manifest.json")
            )
        else:
            data = {key: value for key, value in embedded.items() if key != "hash"}
            if data != plan or embedded.get("hash") != sha256_json(plan):
                issues.append(
                    ValidationIssue("error", "plan.hash", "Embedded plan mismatch", "manifest.json")
                )
    sources = documents.get("sources")
    evidence = documents.get("evidence")
    claims = documents.get("claims")
    if isinstance(sources, list) and isinstance(evidence, list) and isinstance(claims, list):
        issues.extend(validate_claim_evidence(claims, evidence, sources).issues)


def _validate_export_execution(
    documents: dict[str, Any],
    events: list[dict[str, Any]],
    manifest: dict[str, Any],
    issues: list[ValidationIssue],
) -> None:
    completed = [
        event.get("step_id")
        for event in events
        if event.get("type") == "step.completed" and event.get("step_id")
    ]
    checkpoint = documents.get("checkpoint")
    execution = documents.get("execution")
    if isinstance(checkpoint, dict) and checkpoint.get("completed_steps") != completed:
        issues.append(
            ValidationIssue(
                "error", "checkpoint.steps", "Checkpoint step mismatch", "checkpoint.json"
            )
        )
    if isinstance(execution, dict):
        if execution.get("completed_steps") != completed:
            issues.append(
                ValidationIssue(
                    "error", "execution.steps", "Execution step mismatch", "execution.json"
                )
            )
        if manifest.get("execution") != execution:
            issues.append(
                ValidationIssue(
                    "error", "execution.embedded", "Embedded execution mismatch", "manifest.json"
                )
            )


def _validate_export_artifacts(
    entries: dict[str, bytes], manifest: dict[str, Any], issues: list[ValidationIssue]
) -> None:
    artifacts = manifest.get("artifacts", [])
    if not isinstance(artifacts, list):
        issues.append(
            ValidationIssue(
                "error", "artifact.index", "Artifacts must be an array", "manifest.json"
            )
        )
        return
    report_content: bytes | None = None
    for position, artifact in enumerate(artifacts):
        _validate_domain(f"artifacts[{position}]", ArtifactRecord, artifact, issues)
        if not isinstance(artifact, dict):
            continue
        path = artifact.get("object_path")
        content = entries.get(path) if isinstance(path, str) else None
        if content is None:
            issues.append(
                ValidationIssue(
                    "error", "artifact.missing", "Artifact entry is missing", "manifest.json"
                )
            )
            continue
        if artifact.get("sha256") != sha256_bytes(content) or artifact.get("size") != len(content):
            issues.append(
                ValidationIssue(
                    "error", "artifact.hash", "Artifact digest or size mismatch", str(path)
                )
            )
        if artifact.get("name") == "report.md":
            report_content = content
    if report_content is not None and entries.get("report.md") != report_content:
        issues.append(
            ValidationIssue(
                "error", "report.artifact_mismatch", "Report copy mismatch", "report.md"
            )
        )


def _validate_export_ro_crate(
    entries: dict[str, bytes], documents: dict[str, Any], issues: list[ValidationIssue]
) -> None:
    crate = _entry_json(entries, "ro-crate-metadata.json", issues, expected=dict)
    if not isinstance(crate, dict):
        return
    if crate.get("@context") != RO_CRATE_CONTEXT or not isinstance(crate.get("@graph"), list):
        issues.append(
            ValidationIssue(
                "error", "ro_crate.shape", "Invalid RO-Crate metadata", "ro-crate-metadata.json"
            )
        )
        return
    identifiers = {item.get("@id") for item in crate["@graph"] if isinstance(item, dict)}
    required = {"./", "#run", "#plan", "report.md"}
    if "report.md" not in entries:
        required.remove("report.md")
    for source in documents.get("sources", []):
        if isinstance(source, dict):
            required.add(f"#source-{source.get('source_id')}")
    for evidence in documents.get("evidence", []):
        if isinstance(evidence, dict):
            required.add(f"#evidence-{evidence.get('evidence_id')}")
    for claim in documents.get("claims", []):
        if isinstance(claim, dict):
            required.add(f"#claim-{claim.get('claim_id')}")
    if not required <= identifiers:
        issues.append(
            ValidationIssue(
                "error",
                "ro_crate.entities",
                "RO-Crate omits provenance entities",
                "ro-crate-metadata.json",
            )
        )


def _entry_json(
    entries: dict[str, bytes],
    name: str,
    issues: list[ValidationIssue],
    *,
    expected: type[Any] | None = None,
) -> Any:
    payload = entries.get(name)
    if payload is None:
        issues.append(ValidationIssue("error", "bundle.missing", f"{name} is missing", name))
        return None
    try:
        value = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        issues.append(ValidationIssue("error", "bundle.json", str(error), name))
        return None
    if expected is not None and not isinstance(value, expected):
        issues.append(
            ValidationIssue("error", "bundle.json_type", f"{name} has the wrong JSON type", name)
        )
        return None
    return value


def _entry_events(entries: dict[str, bytes], issues: list[ValidationIssue]) -> list[dict[str, Any]]:
    payload = entries.get("events.jsonl")
    if payload is None:
        issues.append(ValidationIssue("error", "bundle.missing", "events.jsonl is missing", None))
        return []
    result: list[dict[str, Any]] = []
    try:
        lines = payload.decode("utf-8").splitlines()
        for line in lines:
            value = json.loads(line)
            if not isinstance(value, dict):
                raise ValueError("event is not an object")
            result.append(value)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        issues.append(ValidationIssue("error", "events.unreadable", str(error), "events.jsonl"))
    return result


def _validate_domain(
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
        issues.append(ValidationIssue("error", "domain.invalid", str(error), location))


def _scan_export_secrets(entries: dict[str, bytes], issues: list[ValidationIssue]) -> None:
    for name, content in entries.items():
        text = content.decode("utf-8", errors="ignore")
        if any(pattern.search(text) for pattern in SECRET_PATTERNS):
            issues.append(
                ValidationIssue(
                    "error", "security.exported_secret", "Credential-like text is present", name
                )
            )


def _sanitize(
    value: Any,
    local_roots: tuple[str, ...] = (),
    *,
    field_name: str | None = None,
) -> Any:
    if isinstance(value, Mapping):
        result: dict[str, Any] = {}
        for key, item in value.items():
            normalized = str(key).casefold().replace("-", "_")
            if normalized in SENSITIVE_KEYS or normalized.endswith(
                ("_token", "_secret", "_password")
            ):
                continue
            if normalized == "approved_local_roots":
                result[str(key)] = []
            else:
                result[str(key)] = _sanitize(item, local_roots, field_name=normalized)
        return result
    if isinstance(value, (list, tuple)):
        return [_sanitize(item, local_roots, field_name=field_name) for item in value]
    if isinstance(value, str):
        text = _remove_local_roots(redact_text(value), local_roots)
        if field_name in {"target", "path"} and _is_absolute_local_path(text):
            return "[LOCAL_PATH_REDACTED]"
        return text
    return value


def _sanitize_artifact(content: bytes, media_type: str, local_roots: tuple[str, ...]) -> bytes:
    textual = media_type.startswith("text/") or media_type in {
        "application/json",
        "application/x-ndjson",
    }
    if not textual:
        return content
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError("text artifact is not valid UTF-8") from error
    if media_type == "application/json":
        try:
            return _json_bytes(_sanitize(json.loads(text), local_roots))
        except json.JSONDecodeError:
            pass
    return _remove_local_roots(redact_text(text), local_roots).encode("utf-8")


def _sanitize_policy_decision(value: Any, local_roots: tuple[str, ...]) -> dict[str, Any]:
    sanitized = _sanitize(value, local_roots)
    if not isinstance(sanitized, dict):
        raise ValueError("policy decision must be an object")
    target = sanitized.get("target")
    if isinstance(target, str) and (
        _is_absolute_local_path(target)
        or "[LOCAL_ROOT_REDACTED]" in target
        or any(root and root in target for root in local_roots)
    ):
        sanitized["target"] = "[LOCAL_PATH_REDACTED]"
    sanitized.pop("decision_id", None)
    return PolicyDecision.from_dict(sanitized).to_dict()


def _projection_identities(request: Any, plan: Any) -> dict[str, Any]:
    if not isinstance(request, dict) or not isinstance(plan, dict):
        raise ValueError("request and plan projections must be objects")
    return {
        "request_id": request.get("request_id"),
        "request_hash": sha256_json(request),
        "plan_id": plan.get("plan_id"),
        "plan_hash": sha256_json(plan),
    }


def _rewrite_projection_references(value: Any, identities: Mapping[str, Any]) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            if key in identities:
                value[key] = identities[key]
            elif key == "input_hashes" and isinstance(item, dict):
                if "request" in item:
                    item["request"] = identities["request_hash"]
                if "plan" in item:
                    item["plan"] = identities["plan_hash"]
                _rewrite_projection_references(item, identities)
            else:
                _rewrite_projection_references(item, identities)
    elif isinstance(value, list):
        for item in value:
            _rewrite_projection_references(item, identities)


def _remove_local_roots(value: str, local_roots: tuple[str, ...]) -> str:
    result = value
    for root in sorted(set(local_roots), key=len, reverse=True):
        if root:
            result = result.replace(root, "[LOCAL_ROOT_REDACTED]")
    return result


def _is_absolute_local_path(value: str) -> bool:
    if not value or "://" in value:
        return False
    return Path(value).is_absolute()


def _assert_roots_removed(entries: Mapping[str, bytes], local_roots: tuple[str, ...]) -> None:
    for root in local_roots:
        encoded = root.encode("utf-8")
        if encoded and any(encoded in content for content in entries.values()):
            raise ValueError("generated export still contains an approved local root")


def _artifact_id(artifact: Mapping[str, Any]) -> str:
    identity = {
        "name": artifact.get("name"),
        "sha256": artifact.get("sha256"),
        "produced_by_step": artifact.get("produced_by_step"),
    }
    return "artifact-" + sha256_bytes(canonical_json(identity).encode("utf-8"))


def _file_index(path: str, content: bytes, *, count: int | None = None) -> dict[str, Any]:
    result: dict[str, Any] = {"path": path, "sha256": sha256_bytes(content)}
    if count is not None:
        result["count"] = count
    return result


def _json_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def _event_bytes(events: list[dict[str, Any]]) -> bytes:
    return b"".join(canonical_json(event).encode("utf-8") + b"\n" for event in events)


def _checksum_bytes(entries: dict[str, bytes]) -> bytes:
    return "".join(
        f"{sha256_bytes(content)}  {name}\n" for name, content in sorted(entries.items())
    ).encode("utf-8")


def _safe_name(value: str) -> str:
    name = Path(value).name
    return name if name not in {"", ".", ".."} else "artifact"


def _action_status(status: str) -> str:
    if status == "completed":
        return "CompletedActionStatus"
    if status in {"cancelled", "failed"}:
        return "FailedActionStatus"
    return "PotentialActionStatus"


def _media_type(name: str) -> str:
    suffix = Path(name).suffix.casefold()
    return {
        ".json": "application/json",
        ".jsonl": "application/x-ndjson",
        ".md": "text/markdown",
        ".txt": "text/plain",
    }.get(suffix, "application/octet-stream")
