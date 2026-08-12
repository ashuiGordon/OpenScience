from __future__ import annotations

from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from openscience_agent.adapters import local_files as local_files_module
from openscience_agent.adapters.local_files import LocalFileSourceProvider
from openscience_agent.domain import (
    PolicyDecision,
    PolicyOutcome,
    RiskLevel,
    SearchRequest,
    ToolContext,
)
from openscience_agent.errors import PathBoundaryError, PolicyDeniedError, RunCancelledError


def _allow(*args: object, **kwargs: object) -> PolicyDecision:
    descriptor = args[0]
    return PolicyDecision(
        capability=descriptor.name,
        action=str(args[1]),
        target=str(kwargs.get("target", "")),
        risk=RiskLevel.LOCAL_READ,
        outcome=PolicyOutcome.ALLOW,
        reason="test",
    )


def _context(events: list[tuple[str, object]] | None = None) -> ToolContext:
    def emit(name: str, payload: object) -> None:
        if events is not None:
            events.append((name, payload))

    return ToolContext(
        deadline=datetime.now(UTC) + timedelta(minutes=1),
        remaining_network_requests=0,
        authorize=_allow,
        user_agent="test/1",
        emit=emit,
    )


def test_local_provider_reads_supported_files_without_modifying_them(tmp_path: Path) -> None:
    note = tmp_path / "note.md"
    note.write_text("# Note\nReproducible workflows record evidence.\n")
    before = note.read_bytes()

    result = LocalFileSourceProvider([tmp_path]).search(
        SearchRequest("record evidence", 10), _context()
    )

    assert note.read_bytes() == before
    assert result[0].title == "note.md"
    assert result[0].identifiers["local-path"] == "note.md"
    assert len(result[0].identifiers["sha256"]) == 64


def test_local_provider_denies_symlink_escape(tmp_path: Path) -> None:
    approved = tmp_path / "approved"
    approved.mkdir()
    outside = tmp_path / "outside.txt"
    outside.write_text("private outside material")
    (approved / "escape.txt").symlink_to(outside)

    with pytest.raises(PathBoundaryError):
        LocalFileSourceProvider([approved]).search(SearchRequest("private", 5), _context())


def test_local_provider_reports_size_and_format_limits(tmp_path: Path) -> None:
    (tmp_path / "too-big.txt").write_text("x" * 20)
    (tmp_path / "binary.pdf").write_bytes(b"%PDF")
    events: list[tuple[str, object]] = []

    result = LocalFileSourceProvider([tmp_path], max_file_bytes=10).search(
        SearchRequest("anything", 5), _context(events)
    )

    assert result == []
    assert "file_size_limit" in repr(events)
    assert "unsupported_format" in repr(events)


def test_local_provider_authorizes_real_resolved_path_before_stat(tmp_path: Path) -> None:
    note = tmp_path / "note.md"
    note.write_text("evidence")
    resolved = str(note.resolve())
    events: list[tuple[str, object]] = []
    attempted: list[tuple[str, str]] = []

    def deny_real_path(*args: object, **kwargs: object) -> PolicyDecision:
        descriptor = args[0]
        action = str(args[1])
        target = str(kwargs.get("target", ""))
        attempted.append((action, target))
        return PolicyDecision(
            capability=descriptor.name,
            action=action,
            target=target,
            risk=RiskLevel.LOCAL_READ,
            outcome=PolicyOutcome.ALLOW if action == "list" else PolicyOutcome.DENY,
            reason="test path denial",
        )

    context = ToolContext(
        deadline=datetime.now(UTC) + timedelta(minutes=1),
        remaining_network_requests=0,
        authorize=deny_real_path,
        user_agent="test/1",
        emit=lambda name, payload: events.append((name, payload)),
    )

    with pytest.raises(PolicyDeniedError, match="test path denial"):
        LocalFileSourceProvider([tmp_path]).search(SearchRequest("evidence"), context)

    assert attempted == [("list", str(tmp_path.resolve())), ("stat", resolved)]
    assert "authorization_denied" in repr(events)


def test_local_provider_reauthorizes_real_path_before_read(tmp_path: Path) -> None:
    note = tmp_path / "note.md"
    note.write_text("evidence")
    resolved = str(note.resolve())
    actions: list[str] = []
    events: list[tuple[str, object]] = []

    def allow_stat_deny_read(*args: object, **kwargs: object) -> PolicyDecision:
        descriptor = args[0]
        action = str(args[1])
        target = str(kwargs.get("target", ""))
        assert target == (str(tmp_path.resolve()) if action == "list" else resolved)
        actions.append(action)
        return PolicyDecision(
            capability=descriptor.name,
            action=action,
            target=target,
            risk=RiskLevel.LOCAL_READ,
            outcome=PolicyOutcome.DENY if action == "read" else PolicyOutcome.ALLOW,
            reason="test read denial",
        )

    context = ToolContext(
        deadline=datetime.now(UTC) + timedelta(minutes=1),
        remaining_network_requests=0,
        authorize=allow_stat_deny_read,
        user_agent="test/1",
        emit=lambda name, payload: events.append((name, payload)),
    )

    with pytest.raises(PolicyDeniedError, match="test read denial"):
        LocalFileSourceProvider([tmp_path]).search(SearchRequest("evidence"), context)

    assert actions == ["list", "stat", "read"]
    assert "authorization_denied" in repr(events)
    assert resolved not in repr(events)


def test_local_provider_rejects_symlink_swap_without_reading_outside(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    approved = tmp_path / "approved"
    approved.mkdir()
    note = approved / "note.md"
    note.write_text("approved evidence")
    outside = tmp_path / "outside.md"
    outside.write_text("private outside material")
    outside_identity = (outside.stat().st_dev, outside.stat().st_ino)
    read_identities: list[tuple[int, int]] = []
    original_read = local_files_module.os.read

    def observed_read(file_fd: int, size: int) -> bytes:
        file_stat = local_files_module.os.fstat(file_fd)
        read_identities.append((file_stat.st_dev, file_stat.st_ino))
        return original_read(file_fd, size)

    def swap_before_read(*args: object, **kwargs: object) -> PolicyDecision:
        descriptor = args[0]
        action = str(args[1])
        target = str(kwargs.get("target", ""))
        if action == "read":
            note.unlink()
            note.symlink_to(outside)
        return PolicyDecision(
            capability=descriptor.name,
            action=action,
            target=target,
            risk=RiskLevel.LOCAL_READ,
            outcome=PolicyOutcome.ALLOW,
            reason="test",
        )

    monkeypatch.setattr(local_files_module.os, "read", observed_read)
    context = ToolContext(
        deadline=datetime.now(UTC) + timedelta(minutes=1),
        remaining_network_requests=0,
        authorize=swap_before_read,
        user_agent="test/1",
    )

    with pytest.raises(PathBoundaryError, match="symlink|unsafe"):
        LocalFileSourceProvider([approved]).search(SearchRequest("evidence"), context)

    assert outside_identity not in read_identities


def test_local_provider_uses_typed_cancellation() -> None:
    context = ToolContext(
        deadline=datetime.now(UTC) + timedelta(minutes=1),
        remaining_network_requests=0,
        authorize=_allow,
        user_agent="test/1",
        is_cancelled=lambda: True,
    )

    with pytest.raises(RunCancelledError):
        LocalFileSourceProvider([Path.cwd()]).search(SearchRequest("evidence"), context)
