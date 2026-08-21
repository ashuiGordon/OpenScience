"""Bounded, read-only ingestion of approved local text research materials."""

from __future__ import annotations

import errno
import hashlib
import json
import os
import re
import stat
from collections.abc import Iterable
from pathlib import Path
from typing import Any

from ..domain import (
    CapabilityDescriptor,
    CapabilityKind,
    RiskLevel,
    SearchRequest,
    SourceCandidate,
    SourceStatus,
    ToolContext,
    utc_now,
)
from ..errors import ConfigurationError, PathBoundaryError, PolicyError, ProviderError

DEFAULT_EXTENSIONS = (".txt", ".md", ".json")
_MAX_EXCERPT_CHARS = 50_000
_TOKEN = re.compile(r"[^\W_]+", re.UNICODE)


class LocalFileSourceProvider:
    """Search supported files below resolved roots without modifying them."""

    def __init__(
        self,
        roots: Iterable[Path | str],
        *,
        max_file_bytes: int = 1_000_000,
        max_total_bytes: int = 10_000_000,
        extensions: Iterable[str] = DEFAULT_EXTENSIONS,
    ) -> None:
        if max_file_bytes <= 0 or max_total_bytes <= 0:
            raise ConfigurationError("local file byte limits must be positive")
        resolved_roots: list[Path] = []
        for raw_root in roots:
            try:
                root = Path(raw_root).expanduser().resolve(strict=True)
            except OSError as error:
                raise ConfigurationError(f"approved local root is unavailable: {error}") from error
            if not root.is_dir():
                raise ConfigurationError("approved local roots must be directories")
            if root not in resolved_roots:
                resolved_roots.append(root)
        if not resolved_roots:
            raise ConfigurationError("at least one approved local root is required")
        normalized_extensions = tuple(
            sorted(
                {
                    extension.casefold()
                    if extension.startswith(".")
                    else f".{extension.casefold()}"
                    for extension in extensions
                    if extension
                }
            )
        )
        if not normalized_extensions:
            raise ConfigurationError("at least one local file extension is required")
        unsupported = set(normalized_extensions) - set(DEFAULT_EXTENSIONS)
        if unsupported:
            raise ConfigurationError(
                "unsupported local file extensions: " + ", ".join(sorted(unsupported))
            )
        self._roots = tuple(resolved_roots)
        self._root_identities = tuple(
            (root_stat.st_dev, root_stat.st_ino)
            for root in self._roots
            for root_stat in (root.stat(),)
        )
        self.max_file_bytes = max_file_bytes
        self.max_total_bytes = max_total_bytes
        self.extensions = normalized_extensions

    @property
    def roots(self) -> tuple[Path, ...]:
        return self._roots

    def descriptor(self) -> CapabilityDescriptor:
        return CapabilityDescriptor(
            name="local-files",
            version="1.0.0",
            kind=CapabilityKind.SOURCE,
            risk=RiskLevel.LOCAL_READ,
            input_schema={
                "type": "object",
                "required": ["query", "limit"],
                "properties": {
                    "query": {"type": "string"},
                    "limit": {"type": "integer", "minimum": 1},
                    "filters": {"type": "object"},
                },
            },
            output_schema={"type": "array", "items": {"type": "object"}},
            permissions=("filesystem.read", "filesystem.read.approved_roots"),
        )

    def search(self, request: SearchRequest, context: ToolContext) -> list[SourceCandidate]:
        context.require_active()
        opened_roots: list[tuple[int, Path, int]] = []
        for root_index, (root, identity) in enumerate(
            zip(self._roots, self._root_identities, strict=True)
        ):
            self._require_path_authorized(context, root, ".", action="list")
            try:
                root_fd = _open_root(root, identity)
            except BaseException:
                for _, _, opened_fd in opened_roots:
                    os.close(opened_fd)
                raise
            opened_roots.append((root_index, root, root_fd))

        total_bytes = 0
        candidates: list[SourceCandidate] = []
        query_tokens = _tokens(request.query)
        try:
            selected, paths_were_explicit = self._selected_paths(request, opened_roots, context)
            for alternatives in selected:
                context.require_active()
                found = False
                for root_index, root, root_fd, display_path in alternatives:
                    found, candidate, bytes_read = self._read_candidate(
                        context,
                        root_index,
                        root,
                        root_fd,
                        display_path,
                        query=request.query,
                        total_bytes=total_bytes,
                    )
                    if not found:
                        continue
                    if candidate is not None:
                        candidates.append(candidate)
                        total_bytes += bytes_read
                    break
                if paths_were_explicit and not found:
                    display_path = alternatives[0][3]
                    raise ProviderError(
                        f"local path was not found in approved roots: {display_path}"
                    )
        finally:
            for _, _, root_fd in opened_roots:
                os.close(root_fd)

        ranked = sorted(
            candidates,
            key=lambda item: (-_score(item, query_tokens), item.provider_id.casefold()),
        )[: request.limit]
        context.emit(
            "local_file.search",
            {"roots": len(self._roots), "files": len(ranked), "bytes": total_bytes},
        )
        return ranked

    def _read_candidate(
        self,
        context: ToolContext,
        root_index: int,
        root: Path,
        root_fd: int,
        display_path: str,
        *,
        query: str,
        total_bytes: int,
    ) -> tuple[bool, SourceCandidate | None, int]:
        target = root.joinpath(*display_path.split("/"))
        self._require_path_authorized(context, target, display_path, action="stat")
        try:
            first_fd = _open_beneath(root_fd, display_path)
        except FileNotFoundError:
            return False, None, 0
        except PathBoundaryError:
            raise
        except OSError as error:
            context.emit(
                "local_file.skipped",
                {"path": display_path, "reason": f"unreadable:{type(error).__name__}"},
            )
            return True, None, 0
        try:
            try:
                file_stat = os.fstat(first_fd)
                size = file_stat.st_size
                if not stat.S_ISREG(file_stat.st_mode):
                    context.emit(
                        "local_file.skipped",
                        {"path": display_path, "reason": "not_regular_file"},
                    )
                    return True, None, 0
                suffix = Path(display_path).suffix.casefold()
                if suffix not in self.extensions:
                    context.emit(
                        "local_file.skipped",
                        {"path": display_path, "reason": "unsupported_format"},
                    )
                    return True, None, 0
                if size > self.max_file_bytes:
                    context.emit(
                        "local_file.skipped",
                        {"path": display_path, "reason": "file_size_limit", "bytes": size},
                    )
                    return True, None, 0
                if total_bytes + size > self.max_total_bytes:
                    context.emit(
                        "local_file.skipped",
                        {"path": display_path, "reason": "total_size_limit", "bytes": size},
                    )
                    return True, None, 0

                self._require_path_authorized(context, target, display_path, action="read")
                second_fd = _open_beneath(root_fd, display_path)
                try:
                    second_stat = os.fstat(second_fd)
                    if (
                        second_stat.st_dev,
                        second_stat.st_ino,
                    ) != (file_stat.st_dev, file_stat.st_ino) or not stat.S_ISREG(
                        second_stat.st_mode
                    ):
                        raise PathBoundaryError(
                            f"local path changed while being authorized: {display_path}"
                        )
                    if second_stat.st_size > self.max_file_bytes:
                        context.emit(
                            "local_file.skipped",
                            {
                                "path": display_path,
                                "reason": "file_size_limit",
                                "bytes": second_stat.st_size,
                            },
                        )
                        return True, None, 0
                    raw = _read_bounded(second_fd, self.max_file_bytes, context)
                finally:
                    os.close(second_fd)
                if len(raw) > self.max_file_bytes:
                    context.emit(
                        "local_file.skipped",
                        {
                            "path": display_path,
                            "reason": "file_size_limit",
                            "bytes": len(raw),
                        },
                    )
                    return True, None, 0
                _verify_path_identity(root_fd, display_path, file_stat)
                if total_bytes + len(raw) > self.max_total_bytes:
                    context.emit(
                        "local_file.skipped",
                        {
                            "path": display_path,
                            "reason": "total_size_limit",
                            "bytes": len(raw),
                        },
                    )
                    return True, None, 0
                text = _decode_document(raw, suffix)
            except PolicyError:
                raise
            except (OSError, UnicodeError, json.JSONDecodeError) as error:
                context.emit(
                    "local_file.skipped",
                    {"path": display_path, "reason": f"unreadable:{type(error).__name__}"},
                )
                return True, None, 0
        finally:
            os.close(first_fd)

        digest = hashlib.sha256(raw).hexdigest()
        return (
            True,
            SourceCandidate(
                provider="local-files",
                provider_id=f"root-{root_index}/{display_path}",
                title=display_path,
                source_type="local-document",
                abstract_or_excerpt=" ".join(text.split())[:_MAX_EXCERPT_CHARS],
                identifiers={"sha256": digest, "local-path": display_path},
                license=None,
                status=SourceStatus.ACTIVE,
                retrieved_at=utc_now(),
                query=query,
                response_hash=digest,
            ),
            len(raw),
        )

    def _require_path_authorized(
        self,
        context: ToolContext,
        target: Path,
        display_path: str,
        *,
        action: str,
    ) -> None:
        try:
            context.require_authorized(
                self.descriptor(),
                action,
                target=str(target),
                risk=RiskLevel.LOCAL_READ,
            )
        except PolicyError:
            context.emit(
                "local_file.skipped",
                {"path": display_path, "reason": "authorization_denied", "action": action},
            )
            raise

    def _selected_paths(
        self,
        request: SearchRequest,
        opened_roots: list[tuple[int, Path, int]],
        context: ToolContext,
    ) -> tuple[list[list[tuple[int, Path, int, str]]], bool]:
        requested = request.filters.get("paths")
        if requested is not None:
            if isinstance(requested, str) or not isinstance(requested, (list, tuple)):
                raise ProviderError("local paths filter must be a list of relative paths")
            result: list[list[tuple[int, Path, int, str]]] = []
            for raw_path in requested:
                display_path = _validated_relative_path(raw_path)
                result.append(
                    [
                        (root_index, root, root_fd, display_path)
                        for root_index, root, root_fd in opened_roots
                    ]
                )
            return result, True

        result = []
        for root_index, root, root_fd in opened_roots:
            for display_path in _walk_files(root_fd, context):
                result.append([(root_index, root, root_fd, display_path)])
        result.sort(key=lambda group: (group[0][0], group[0][3].casefold()))
        return result, False


def _validated_relative_path(raw_path: object) -> str:
    value = str(raw_path)
    if not value or "\x00" in value:
        raise PathBoundaryError("local path must be a non-empty relative path")
    relative = Path(value)
    if (
        relative.is_absolute()
        or not relative.parts
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise PathBoundaryError(f"local path escapes approved roots: {value}")
    return "/".join(relative.parts)


def _secure_flags(*, directory: bool) -> int:
    required: tuple[str, ...] = ("O_NOFOLLOW", "O_CLOEXEC")
    if directory:
        required += ("O_DIRECTORY",)
    if any(not hasattr(os, name) for name in required) or os.open not in os.supports_dir_fd:
        raise ConfigurationError(
            "secure local file ingestion requires openat, O_NOFOLLOW, and O_CLOEXEC support"
        )
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
    if directory:
        flags |= os.O_DIRECTORY
    return flags


def _open_root(root: Path, expected_identity: tuple[int, int]) -> int:
    try:
        root_fd = os.open(root, _secure_flags(directory=True))
    except OSError as error:
        raise PathBoundaryError(
            f"approved local root changed or is unreadable: {root.name}"
        ) from error
    root_stat = os.fstat(root_fd)
    if (
        not stat.S_ISDIR(root_stat.st_mode)
        or (
            root_stat.st_dev,
            root_stat.st_ino,
        )
        != expected_identity
    ):
        os.close(root_fd)
        raise PathBoundaryError(f"approved local root changed after configuration: {root.name}")
    return root_fd


def _open_beneath(root_fd: int, display_path: str, *, directory: bool = False) -> int:
    parts = _validated_relative_path(display_path).split("/")
    current_fd = os.dup(root_fd)
    try:
        for index, part in enumerate(parts):
            final = index == len(parts) - 1
            flags = _secure_flags(directory=not final or directory)
            next_fd = os.open(part, flags, dir_fd=current_fd)
            os.close(current_fd)
            current_fd = next_fd
        return current_fd
    except OSError as error:
        os.close(current_fd)
        if error.errno in {errno.ELOOP, errno.ENOTDIR}:
            raise PathBoundaryError(
                f"local path contains a symlink or unsafe component: {display_path}"
            ) from error
        raise
    except BaseException:
        os.close(current_fd)
        raise


def _walk_files(root_fd: int, context: ToolContext) -> list[str]:
    result: list[str] = []

    def visit(directory_fd: int, prefix: tuple[str, ...]) -> None:
        context.require_active()
        with os.scandir(directory_fd) as iterator:
            entries = sorted(iterator, key=lambda entry: entry.name.casefold())
        for entry in entries:
            context.require_active()
            display_path = "/".join((*prefix, entry.name))
            try:
                if entry.is_symlink():
                    raise PathBoundaryError(
                        f"local path contains a symlink or unsafe component: {display_path}"
                    )
                is_directory = entry.is_dir(follow_symlinks=False)
            except FileNotFoundError:
                continue
            if not is_directory:
                result.append(display_path)
                continue
            child_fd = _open_beneath(directory_fd, entry.name, directory=True)
            try:
                visit(child_fd, (*prefix, entry.name))
            finally:
                os.close(child_fd)

    visit(root_fd, ())
    return result


def _read_bounded(file_fd: int, limit: int, context: ToolContext) -> bytes:
    chunks: list[bytes] = []
    remaining = limit + 1
    while remaining > 0:
        context.require_active()
        chunk = os.read(file_fd, min(65_536, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _verify_path_identity(root_fd: int, display_path: str, expected: os.stat_result) -> None:
    verification_fd = _open_beneath(root_fd, display_path)
    try:
        current = os.fstat(verification_fd)
        if (current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino):
            raise PathBoundaryError(f"local path changed while it was being read: {display_path}")
    finally:
        os.close(verification_fd)


def _decode_document(raw: bytes, suffix: str) -> str:
    text = raw.decode("utf-8")
    if suffix != ".json":
        return text
    value: Any = json.loads(text)
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _score(candidate: SourceCandidate, query_tokens: set[str]) -> int:
    if not query_tokens:
        return 0
    title_tokens = _tokens(candidate.title)
    body_tokens = _tokens(candidate.abstract_or_excerpt)
    return 3 * len(title_tokens & query_tokens) + len(body_tokens & query_tokens)


def _tokens(text: str) -> set[str]:
    return {match.group(0).casefold() for match in _TOKEN.finditer(text)}


__all__ = ["DEFAULT_EXTENSIONS", "LocalFileSourceProvider"]
