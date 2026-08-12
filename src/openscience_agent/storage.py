"""Durable local run storage with append-only, hash-chained events."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from collections.abc import Callable, Iterable, Mapping
from pathlib import Path
from typing import Any

ZERO_HASH = "0" * 64


def canonical_json(value: Any) -> str:
    """Return stable UTF-8 JSON used for persisted hashes."""

    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    )


def sha256_bytes(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _identity(value: Any) -> Any:
    return value


class RunStore:
    """Owns one run directory and its immutable activity history.

    JSON projections are conveniences for inspection and resume. ``events.jsonl`` is append-only
    and every event includes the hash of its predecessor, so mutation is detectable.
    """

    def __init__(
        self,
        run_directory: Path,
        *,
        redactor: Callable[[Any], Any] | None = None,
    ) -> None:
        self.run_directory = run_directory.resolve()
        self.objects_directory = self.run_directory / "objects" / "sha256"
        self.events_path = self.run_directory / "events.jsonl"
        self._redactor = redactor or _identity

    @classmethod
    def create(
        cls,
        workspace: Path,
        run_id: str,
        *,
        redactor: Callable[[Any], Any] | None = None,
    ) -> RunStore:
        if not run_id or run_id in {".", ".."} or "/" in run_id or "\\" in run_id:
            raise ValueError("run_id must be a non-empty path-safe name")
        root = workspace.expanduser().resolve()
        root.mkdir(parents=True, exist_ok=True)
        target = root / run_id
        target.mkdir(mode=0o700, parents=False, exist_ok=False)
        store = cls(target, redactor=redactor)
        store.objects_directory.mkdir(parents=True, exist_ok=True)
        return store

    @classmethod
    def open(
        cls,
        run_directory: Path,
        *,
        redactor: Callable[[Any], Any] | None = None,
    ) -> RunStore:
        target = run_directory.expanduser().resolve()
        if not target.is_dir():
            raise FileNotFoundError(f"run directory does not exist: {target}")
        return cls(target, redactor=redactor)

    def path_for(self, relative_name: str) -> Path:
        if not relative_name or Path(relative_name).is_absolute():
            raise ValueError("run paths must be non-empty and relative")
        candidate = (self.run_directory / relative_name).resolve()
        if candidate != self.run_directory and self.run_directory not in candidate.parents:
            raise ValueError("run path escapes the run directory")
        return candidate

    def write_json(self, relative_name: str, value: Any) -> Path:
        target = self.path_for(relative_name)
        target.parent.mkdir(parents=True, exist_ok=True)
        redacted = self._redactor(value)
        payload = json.dumps(redacted, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
        self._atomic_write(target, payload.encode("utf-8"))
        return target

    def read_json(self, relative_name: str) -> Any:
        with self.path_for(relative_name).open(encoding="utf-8") as handle:
            return json.load(handle)

    def write_text(self, relative_name: str, content: str) -> Path:
        target = self.path_for(relative_name)
        target.parent.mkdir(parents=True, exist_ok=True)
        redacted = self._redactor(content)
        if not isinstance(redacted, str):
            raise TypeError("the configured redactor must return text for text input")
        self._atomic_write(target, redacted.encode("utf-8"))
        return target

    def append_event(
        self,
        event_type: str,
        payload: Mapping[str, Any] | None = None,
        *,
        timestamp: str,
        step_id: str | None = None,
        event_id: str | None = None,
    ) -> dict[str, Any]:
        if not event_type:
            raise ValueError("event_type is required")
        events = self.read_events()
        previous_hash = events[-1]["event_hash"] if events else ZERO_HASH
        sequence = len(events) + 1
        body: dict[str, Any] = {
            "sequence": sequence,
            "event_id": event_id or f"evt-{sequence:06d}",
            "run_id": self.run_directory.name,
            "type": event_type,
            "timestamp": timestamp,
            "step_id": step_id,
            "payload": self._redactor(dict(payload or {})),
            "previous_hash": previous_hash,
        }
        body["event_hash"] = sha256_bytes(canonical_json(body).encode("utf-8"))
        events_path = self.path_for("events.jsonl")
        events_path.parent.mkdir(parents=True, exist_ok=True)
        encoded = (canonical_json(body) + "\n").encode("utf-8")
        descriptor = os.open(
            events_path,
            os.O_WRONLY | os.O_CREAT | os.O_APPEND,
            0o600,
        )
        try:
            os.write(descriptor, encoded)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        return body

    def read_events(self) -> list[dict[str, Any]]:
        events_path = self.path_for("events.jsonl")
        if not events_path.exists():
            return []
        result: list[dict[str, Any]] = []
        with events_path.open(encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, start=1):
                if not line.strip():
                    continue
                value = json.loads(line)
                if not isinstance(value, dict):
                    raise ValueError(f"event {line_number} is not an object")
                result.append(value)
        return result

    def verify_event_chain(self) -> list[str]:
        issues: list[str] = []
        expected_previous = ZERO_HASH
        for expected_sequence, event in enumerate(self.read_events(), start=1):
            if event.get("run_id") != self.run_directory.name:
                issues.append(f"event {expected_sequence} has an invalid run_id")
            if event.get("sequence") != expected_sequence:
                issues.append(
                    f"event sequence {event.get('sequence')!r} is not {expected_sequence}"
                )
            if event.get("previous_hash") != expected_previous:
                issues.append(f"event {expected_sequence} has an invalid previous_hash")
            supplied_hash = event.get("event_hash")
            unhashed = {key: value for key, value in event.items() if key != "event_hash"}
            calculated = sha256_bytes(canonical_json(unhashed).encode("utf-8"))
            if supplied_hash != calculated:
                issues.append(f"event {expected_sequence} has an invalid event_hash")
            expected_previous = str(supplied_hash or "")
        return issues

    def store_object(self, content: bytes) -> tuple[str, Path]:
        digest = sha256_bytes(content)
        target = self.path_for(f"objects/sha256/{digest[:2]}/{digest[2:]}")
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            self._atomic_write(target, content, mode=0o600)
        elif sha256_file(target) != digest:
            raise OSError(f"content-addressed object is corrupted: {digest}")
        return digest, target

    def add_artifact(
        self,
        *,
        name: str,
        content: bytes,
        media_type: str,
        produced_by_step: str,
        input_ids: Iterable[str] = (),
    ) -> dict[str, Any]:
        if not name or Path(name).name != name:
            raise ValueError("artifact name must be a plain filename")
        if media_type.startswith("text/") or Path(name).suffix.casefold() in {
            ".csv",
            ".json",
            ".jsonl",
            ".md",
            ".txt",
        }:
            try:
                text = content.decode("utf-8")
            except UnicodeDecodeError as error:
                raise ValueError("text artifacts must contain valid UTF-8") from error
            redacted = self._redactor(text)
            if not isinstance(redacted, str):
                raise TypeError("the configured redactor must return text for text input")
            content = redacted.encode("utf-8")
        digest, object_path = self.store_object(content)
        identity = {
            "name": name,
            "sha256": digest,
            "produced_by_step": produced_by_step,
        }
        return {
            "artifact_id": "artifact-" + sha256_bytes(canonical_json(identity).encode("utf-8")),
            "name": name,
            "sha256": digest,
            "size": len(content),
            "media_type": media_type,
            "produced_by_step": produced_by_step,
            "input_ids": list(input_ids),
            "object_path": object_path.relative_to(self.run_directory).as_posix(),
        }

    def projection_index(self, relative_name: str, *, count: int) -> dict[str, Any]:
        target = self.path_for(relative_name)
        return {
            "path": relative_name,
            "count": count,
            "sha256": sha256_file(target),
        }

    def _atomic_write(self, target: Path, content: bytes, *, mode: int = 0o600) -> None:
        target.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
        temporary = Path(temporary_name)
        try:
            os.fchmod(descriptor, mode)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, target)
        except BaseException:
            try:
                os.close(descriptor)
            except OSError:
                pass
            temporary.unlink(missing_ok=True)
            raise
