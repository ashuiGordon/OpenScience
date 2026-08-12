"""Polite, bounded Crossref REST API scholarly metadata adapter."""

from __future__ import annotations

import html
import re
import time
from collections.abc import Mapping
from typing import Any
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, build_opener

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
from ..errors import ConfigurationError, ProviderError
from .openalex import (
    Sleeper,
    SourceTransport,
    _hash_mapping,
    _http_provider_error,
    _NoRedirectHandler,
    _optional_text,
    _request_json,
    _user_agent,
)

_MAX_RESPONSE_BYTES = 5_000_000
_TAG = re.compile(r"<[^>]+>")


class CrossrefSourceProvider:
    def __init__(
        self,
        *,
        api_key: str | None = None,
        mailto: str | None = None,
        timeout: float = 10.0,
        user_agent: str = "openscience-agent/0.1",
        transport: SourceTransport | None = None,
        base_url: str = "https://api.crossref.org",
        sleeper: Sleeper = time.sleep,
        retry_delay: float = 0.25,
    ) -> None:
        if timeout <= 0 or timeout > 120:
            raise ConfigurationError("Crossref timeout must be in (0, 120] seconds")
        if not user_agent.strip():
            raise ConfigurationError("Crossref user_agent is required")
        base_url = base_url.rstrip("/")
        parsed = urlsplit(base_url)
        if parsed.scheme != "https" or not parsed.hostname:
            raise ConfigurationError("Crossref base_url must be HTTPS")
        if not callable(sleeper):
            raise ConfigurationError("Crossref sleeper must be callable")
        if retry_delay < 0 or retry_delay > 5:
            raise ConfigurationError("Crossref retry_delay must be in [0, 5] seconds")
        self._api_key = api_key.strip() if api_key else None
        self._mailto = mailto.strip() if mailto else None
        self.timeout = float(timeout)
        self.user_agent = user_agent.strip()
        self.base_url = base_url
        self._transport = transport or _default_transport
        self._sleeper = sleeper
        self._retry_delay = float(retry_delay)

    def descriptor(self) -> CapabilityDescriptor:
        return CapabilityDescriptor(
            name="crossref",
            version="1.0.0",
            kind=CapabilityKind.SOURCE,
            risk=RiskLevel.NETWORK_READ,
            input_schema={
                "type": "object",
                "required": ["query", "limit"],
                "properties": {
                    "query": {"type": "string"},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 1000},
                    "filters": {"type": "object"},
                },
            },
            output_schema={"type": "array", "items": {"type": "object"}},
            permissions=("network.read", "network.read:api.crossref.org"),
        )

    def search(self, request: SearchRequest, context: ToolContext) -> list[SourceCandidate]:
        context.require_active()
        url = self._search_url(request)
        headers = {
            "Accept": "application/json",
            "User-Agent": _user_agent(context.user_agent, self.user_agent, self._mailto),
        }
        if self._api_key:
            headers["Crossref-Plus-API-Token"] = f"Bearer {self._api_key}"
        payload = _request_json(
            self._transport,
            url,
            headers,
            self.timeout,
            "Crossref",
            context=context,
            descriptor=self.descriptor(),
            sleeper=self._sleeper,
            retry_delay=self._retry_delay,
        )
        if payload.get("status") not in {None, "ok"}:
            raise ProviderError(f"Crossref returned status {payload.get('status')!r}")
        message = payload.get("message")
        if not isinstance(message, Mapping) or not isinstance(message.get("items"), list):
            raise ProviderError("Crossref response has no message.items list")
        raw_items = message["items"]
        candidates: list[SourceCandidate] = []
        for index, raw_item in enumerate(raw_items[: request.limit]):
            context.require_active()
            if not isinstance(raw_item, Mapping):
                context.emit("crossref.record_skipped", {"index": index, "reason": "not_object"})
                continue
            candidate = _map_work(raw_item, request.query)
            if candidate is None:
                context.emit(
                    "crossref.record_skipped", {"index": index, "reason": "missing_identity"}
                )
                continue
            candidates.append(candidate)
        context.emit("crossref.search", {"records": len(candidates)})
        return candidates

    def _search_url(self, request: SearchRequest) -> str:
        parameters: list[tuple[str, str]] = [
            ("query.bibliographic", request.query),
            ("rows", str(min(request.limit, 1_000))),
        ]
        filter_value = _crossref_filter(request.filters)
        if filter_value:
            parameters.append(("filter", filter_value))
        if self._mailto:
            parameters.append(("mailto", self._mailto))
        return f"{self.base_url}/works?{urlencode(parameters)}"


def _map_work(item: Mapping[str, Any], query: str) -> SourceCandidate | None:
    doi = _optional_text(item.get("DOI") or item.get("doi"))
    url = _optional_text(item.get("URL") or item.get("url"))
    provider_id = doi or url
    title = _first_text(item.get("title"))
    if not provider_id or not title:
        return None
    authors: list[str] = []
    raw_authors = item.get("author")
    if isinstance(raw_authors, list):
        for author in raw_authors:
            if not isinstance(author, Mapping):
                continue
            literal = _optional_text(author.get("name"))
            if not literal:
                literal = " ".join(
                    value
                    for value in (
                        _optional_text(author.get("given")),
                        _optional_text(author.get("family")),
                    )
                    if value
                )
            if literal:
                authors.append(literal)
    identifiers: dict[str, str] = {"doi": doi} if doi else {}
    issn = item.get("ISSN")
    if isinstance(issn, list) and issn:
        identifiers["issn"] = str(issn[0])
    if url:
        identifiers["uri"] = url
    return SourceCandidate(
        provider="crossref",
        provider_id=provider_id,
        title=title,
        authors=tuple(authors),
        publication_date=_publication_date(item),
        source_type=_source_type(_optional_text(item.get("type"))),
        abstract_or_excerpt=_plain_abstract(item.get("abstract")),
        landing_url=url or (f"https://doi.org/{doi}" if doi else None),
        identifiers=identifiers,
        license=_license(item.get("license")),
        status=_status(item),
        retrieved_at=utc_now(),
        query=query,
        response_hash=_hash_mapping(item),
    )


def _publication_date(item: Mapping[str, Any]) -> str | None:
    for key in ("published-print", "published-online", "published", "issued", "created"):
        value = item.get(key)
        if not isinstance(value, Mapping):
            continue
        date_parts = value.get("date-parts")
        if (
            not isinstance(date_parts, list)
            or not date_parts
            or not isinstance(date_parts[0], list)
        ):
            continue
        parts = date_parts[0]
        if not parts or not isinstance(parts[0], int):
            continue
        year = parts[0]
        if len(parts) >= 3 and all(isinstance(part, int) for part in parts[:3]):
            return f"{year:04d}-{parts[1]:02d}-{parts[2]:02d}"
        if len(parts) >= 2 and isinstance(parts[1], int):
            return f"{year:04d}-{parts[1]:02d}"
        return f"{year:04d}"
    return None


def _status(item: Mapping[str, Any]) -> SourceStatus:
    explicit = str(item.get("status") or "").casefold()
    relation = item.get("relation")
    if item.get("is-retracted") is True or explicit == "retracted":
        return SourceStatus.RETRACTED
    if isinstance(relation, Mapping) and relation.get("is-retracted-by"):
        return SourceStatus.RETRACTED
    if explicit == "withdrawn":
        return SourceStatus.WITHDRAWN
    if explicit == "corrected" or (
        isinstance(relation, Mapping) and relation.get("is-corrected-by")
    ):
        return SourceStatus.CORRECTED
    return SourceStatus.ACTIVE


def _license(value: object) -> str | None:
    if not isinstance(value, list):
        return None
    for record in value:
        if isinstance(record, Mapping) and (url := _optional_text(record.get("URL"))):
            return url
    return None


def _plain_abstract(value: object) -> str:
    if not isinstance(value, str):
        return ""
    return " ".join(html.unescape(_TAG.sub(" ", value)).split())[:50_000]


def _first_text(value: object) -> str | None:
    if isinstance(value, list):
        return _optional_text(value[0]) if value else None
    return _optional_text(value)


def _source_type(value: str | None) -> str:
    return {
        "journal-article": "article",
        "posted-content": "preprint",
        "proceedings-article": "conference-paper",
        "book-chapter": "book-chapter",
        "dataset": "dataset",
    }.get(value or "", value or "article")


def _crossref_filter(filters: Mapping[str, Any]) -> str:
    result: list[str] = []
    if value := filters.get("from_year"):
        result.append(f"from-pub-date:{int(str(value)):04d}-01-01")
    if value := filters.get("to_year"):
        result.append(f"until-pub-date:{int(str(value)):04d}-12-31")
    if value := filters.get("type") or filters.get("source_type"):
        result.append(f"type:{str(value)}")
    return ",".join(result)


def _default_transport(url: str, headers: Mapping[str, str], timeout: float) -> bytes:
    request = Request(url, headers=dict(headers), method="GET")
    opener = build_opener(_NoRedirectHandler())
    try:
        with opener.open(request, timeout=timeout) as response:  # noqa: S310 - HTTPS only
            length = response.headers.get("Content-Length")
            if length and int(length) > _MAX_RESPONSE_BYTES:
                raise ProviderError("Crossref response is too large")
            content = bytes(response.read(_MAX_RESPONSE_BYTES + 1))
    except HTTPError as error:
        raise _http_provider_error("Crossref", error) from error
    if len(content) > _MAX_RESPONSE_BYTES:
        raise ProviderError("Crossref response is too large")
    return content


__all__ = ["CrossrefSourceProvider"]
