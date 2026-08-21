"""Deterministic source adapters backed by an explicitly supplied fixture corpus."""

from __future__ import annotations

import hashlib
import json
import re
from collections.abc import Iterable, Mapping
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
)
from ..errors import ConfigurationError

FIXTURE_RETRIEVED_AT = "2000-01-01T00:00:00Z"
_TOKEN = re.compile(r"[^\W_]+", re.UNICODE)


class FixtureSourceProvider:
    """A contract-compatible provider with deterministic ranking and timestamps."""

    def __init__(
        self,
        provider_name: str,
        records: Iterable[Mapping[str, Any] | SourceCandidate],
        *,
        version: str = "1.0.0",
    ) -> None:
        self.provider_name = provider_name.strip()
        self.version = version.strip()
        if not self.provider_name:
            raise ConfigurationError("fixture provider_name is required")
        if not self.version:
            raise ConfigurationError("fixture provider version is required")
        self._records = tuple(self._candidate(item, index) for index, item in enumerate(records))

    @classmethod
    def from_corpus(cls, path: Path | str, provider_name: str) -> FixtureSourceProvider:
        providers = load_fixture_providers(path)
        try:
            return providers[provider_name]
        except KeyError as error:
            raise ConfigurationError(
                f"fixture corpus has no provider named {provider_name!r}"
            ) from error

    def descriptor(self) -> CapabilityDescriptor:
        return CapabilityDescriptor(
            name=self.provider_name,
            version=self.version,
            kind=CapabilityKind.SOURCE,
            risk=RiskLevel.LOCAL_READ,
            input_schema={
                "type": "object",
                "required": ["query", "limit"],
                "properties": {
                    "query": {"type": "string"},
                    "limit": {"type": "integer", "minimum": 1},
                },
            },
            output_schema={"type": "array", "items": {"type": "object"}},
            permissions=("fixture.read",),
        )

    def search(self, request: SearchRequest, context: ToolContext) -> list[SourceCandidate]:
        context.require_active()
        query_tokens = _tokens(request.query)
        filtered = [item for item in self._records if _matches_filters(item, request.filters)]
        ranked = sorted(
            filtered,
            key=lambda item: (
                -_score(item, query_tokens),
                item.title.casefold(),
                item.provider_id,
            ),
        )
        result = [
            SourceCandidate(
                provider=item.provider,
                provider_id=item.provider_id,
                title=item.title,
                authors=item.authors,
                publication_date=item.publication_date,
                source_type=item.source_type,
                abstract_or_excerpt=item.abstract_or_excerpt,
                landing_url=item.landing_url,
                identifiers=item.identifiers,
                license=item.license,
                status=item.status,
                retrieved_at=item.retrieved_at,
                query=request.query,
                response_hash=item.response_hash,
            )
            for item in ranked[: request.limit]
        ]
        context.require_active()
        context.emit(
            "fixture.search",
            {"provider": self.provider_name, "query": request.query, "records": len(result)},
        )
        return result

    def _candidate(self, item: Mapping[str, Any] | SourceCandidate, index: int) -> SourceCandidate:
        data: dict[str, Any]
        if isinstance(item, SourceCandidate):
            data = item.to_dict()
        elif isinstance(item, Mapping):
            data = dict(item)
        else:
            raise ConfigurationError(
                f"fixture record {index} must be a mapping, got {type(item).__name__}"
            )
        data.pop("provider", None)
        title = str(data.get("title", "")).strip()
        if not title:
            raise ConfigurationError(f"fixture record {index} has no title")
        provider_id = str(data.get("provider_id") or data.get("id") or "").strip()
        if not provider_id:
            provider_id = f"record-{_hash_payload(data)[:16]}"
        identifiers = data.get("identifiers") or {}
        if not isinstance(identifiers, Mapping):
            raise ConfigurationError(f"fixture record {index} identifiers must be an object")
        raw_authors: Any = data.get("authors") or ()
        if isinstance(raw_authors, str):
            raw_authors = (raw_authors,)
        if not isinstance(raw_authors, (list, tuple)):
            raise ConfigurationError(f"fixture record {index} authors must be a list")
        response_hash = str(data.get("response_hash") or _hash_payload(data))
        return SourceCandidate(
            provider=self.provider_name,
            provider_id=provider_id,
            title=title,
            authors=tuple(str(author).strip() for author in raw_authors if str(author).strip()),
            publication_date=_optional_text(data.get("publication_date")),
            source_type=str(data.get("source_type") or "article"),
            abstract_or_excerpt=str(
                data.get("abstract_or_excerpt") or data.get("abstract") or data.get("excerpt") or ""
            ),
            landing_url=_optional_text(data.get("landing_url") or data.get("url")),
            identifiers={str(key): str(value) for key, value in identifiers.items()},
            license=_optional_text(data.get("license")),
            status=SourceStatus(str(data.get("status") or SourceStatus.UNKNOWN.value)),
            retrieved_at=str(data.get("retrieved_at") or FIXTURE_RETRIEVED_AT),
            query=str(data.get("query") or ""),
            response_hash=response_hash,
        )


def load_fixture_providers(path: Path | str) -> dict[str, FixtureSourceProvider]:
    """Load one provider per corpus group without retaining the source path."""

    corpus_path = Path(path).expanduser()
    try:
        payload = json.loads(corpus_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ConfigurationError(f"cannot load fixture corpus: {error}") from error

    grouped: dict[str, list[Mapping[str, Any]]] = {}
    if isinstance(payload, Mapping) and isinstance(payload.get("providers"), Mapping):
        raw_providers = payload["providers"]
        for raw_name, provider_records in raw_providers.items():
            if not isinstance(provider_records, list):
                raise ConfigurationError(f"fixture provider {raw_name!r} must contain a list")
            grouped[str(raw_name)] = _mapping_records(provider_records, str(raw_name))
    else:
        raw_records: Any
        if isinstance(payload, Mapping):
            raw_records = payload.get("records", payload.get("sources"))
        else:
            raw_records = payload
        if not isinstance(raw_records, list):
            raise ConfigurationError("fixture corpus must contain a records list or providers map")
        for index, raw_record in enumerate(raw_records):
            if not isinstance(raw_record, Mapping):
                raise ConfigurationError(f"fixture record {index} must be an object")
            provider = str(raw_record.get("provider") or "fixture")
            grouped.setdefault(provider, []).append(raw_record)
    if not grouped:
        raise ConfigurationError("fixture corpus contains no providers")
    return {name: FixtureSourceProvider(name, grouped[name]) for name in sorted(grouped)}


def _mapping_records(records: list[Any], provider: str) -> list[Mapping[str, Any]]:
    result: list[Mapping[str, Any]] = []
    for index, record in enumerate(records):
        if not isinstance(record, Mapping):
            raise ConfigurationError(
                f"fixture provider {provider!r} record {index} is not an object"
            )
        result.append(record)
    return result


def _matches_filters(candidate: SourceCandidate, filters: Mapping[str, Any]) -> bool:
    year = None
    if candidate.publication_date:
        match = re.match(r"^(\d{4})", candidate.publication_date)
        year = int(match.group(1)) if match else None
    from_year = filters.get("from_year")
    to_year = filters.get("to_year")
    source_type = filters.get("source_type") or filters.get("type")
    if from_year is not None and (year is None or year < int(str(from_year))):
        return False
    if to_year is not None and (year is None or year > int(str(to_year))):
        return False
    return not source_type or candidate.source_type == str(source_type)


def _score(candidate: SourceCandidate, query_tokens: set[str]) -> int:
    if not query_tokens:
        return 0
    title_tokens = _tokens(candidate.title)
    excerpt_tokens = _tokens(candidate.abstract_or_excerpt)
    return 3 * len(query_tokens & title_tokens) + len(query_tokens & excerpt_tokens)


def _tokens(text: str) -> set[str]:
    return {match.group(0).casefold() for match in _TOKEN.finditer(text)}


def _hash_payload(value: object) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        default=str,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _optional_text(value: object) -> str | None:
    text = str(value).strip() if value is not None else ""
    return text or None


__all__ = ["FIXTURE_RETRIEVED_AT", "FixtureSourceProvider", "load_fixture_providers"]
