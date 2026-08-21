"""Polite, bounded OpenAlex scholarly metadata adapter."""

from __future__ import annotations

import hashlib
import json
import math
import time
from collections.abc import Callable, Mapping
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

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
from ..errors import ConfigurationError, LimitExceededError, ProviderError

JSONMapping = Mapping[str, Any]
SourceTransport = Callable[[str, Mapping[str, str], float], bytes | JSONMapping]
Sleeper = Callable[[float], None]
_MAX_RESPONSE_BYTES = 5_000_000
_MAX_RETRIES = 1
_MAX_RETRY_DELAY = 5.0


class _NoRedirectHandler(HTTPRedirectHandler):
    """Refuse redirects so credentials are never replayed to another location."""

    def redirect_request(
        self,
        req: Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> None:
        del req, fp, code, msg, headers, newurl
        return None


class OpenAlexSourceProvider:
    def __init__(
        self,
        *,
        api_key: str | None = None,
        mailto: str | None = None,
        timeout: float = 10.0,
        user_agent: str = "openscience-agent/0.1",
        transport: SourceTransport | None = None,
        base_url: str = "https://api.openalex.org",
        sleeper: Sleeper = time.sleep,
        retry_delay: float = 0.25,
    ) -> None:
        if timeout <= 0 or timeout > 120:
            raise ConfigurationError("OpenAlex timeout must be in (0, 120] seconds")
        if not user_agent.strip():
            raise ConfigurationError("OpenAlex user_agent is required")
        base_url = base_url.rstrip("/")
        parsed = urlsplit(base_url)
        if parsed.scheme != "https" or not parsed.hostname:
            raise ConfigurationError("OpenAlex base_url must be HTTPS")
        if not callable(sleeper):
            raise ConfigurationError("OpenAlex sleeper must be callable")
        if retry_delay < 0 or retry_delay > _MAX_RETRY_DELAY:
            raise ConfigurationError(
                f"OpenAlex retry_delay must be in [0, {_MAX_RETRY_DELAY:g}] seconds"
            )
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
            name="openalex",
            version="1.0.0",
            kind=CapabilityKind.SOURCE,
            risk=RiskLevel.NETWORK_READ,
            input_schema={
                "type": "object",
                "required": ["query", "limit"],
                "properties": {
                    "query": {"type": "string"},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100},
                    "filters": {"type": "object"},
                },
            },
            output_schema={"type": "array", "items": {"type": "object"}},
            permissions=("network.read", "network.read:api.openalex.org"),
        )

    def search(self, request: SearchRequest, context: ToolContext) -> list[SourceCandidate]:
        context.require_active()
        url = self._search_url(request)
        headers = {
            "Accept": "application/json",
            "User-Agent": _user_agent(context.user_agent, self.user_agent, self._mailto),
        }
        payload = _request_json(
            self._transport,
            url,
            headers,
            self.timeout,
            "OpenAlex",
            context=context,
            descriptor=self.descriptor(),
            sleeper=self._sleeper,
            retry_delay=self._retry_delay,
        )
        results = payload.get("results")
        if not isinstance(results, list):
            raise ProviderError("OpenAlex response has no results list")
        candidates: list[SourceCandidate] = []
        for index, raw_item in enumerate(results[: request.limit]):
            context.require_active()
            if not isinstance(raw_item, Mapping):
                context.emit("openalex.record_skipped", {"index": index, "reason": "not_object"})
                continue
            candidate = _map_work(raw_item, request.query)
            if candidate is None:
                context.emit(
                    "openalex.record_skipped", {"index": index, "reason": "missing_identity"}
                )
                continue
            candidates.append(candidate)
        context.emit("openalex.search", {"records": len(candidates)})
        return candidates

    def _search_url(self, request: SearchRequest) -> str:
        parameters: list[tuple[str, str]] = [
            ("search", request.query),
            ("per_page", str(min(request.limit, 100))),
        ]
        filter_value = _openalex_filter(request.filters)
        if filter_value:
            parameters.append(("filter", filter_value))
        if self._mailto:
            parameters.append(("mailto", self._mailto))
        if self._api_key:
            parameters.append(("api_key", self._api_key))
        return f"{self.base_url}/works?{urlencode(parameters)}"


def _map_work(item: Mapping[str, Any], query: str) -> SourceCandidate | None:
    openalex_id = _optional_text(item.get("id"))
    doi = _optional_text(item.get("doi"))
    provider_id = (openalex_id or doi or "").rstrip("/").rsplit("/", 1)[-1]
    title = _optional_text(item.get("title") or item.get("display_name"))
    if not provider_id or not title:
        return None
    identifiers: dict[str, str] = {}
    raw_ids = item.get("ids")
    if isinstance(raw_ids, Mapping):
        for key in ("openalex", "doi", "pmid", "pmcid", "mag"):
            if value := _optional_text(raw_ids.get(key)):
                identifiers[key] = value
    if openalex_id:
        identifiers.setdefault("openalex", openalex_id)
    if doi:
        identifiers.setdefault("doi", doi)
    authors: list[str] = []
    raw_authorships = item.get("authorships")
    if isinstance(raw_authorships, list):
        for authorship in raw_authorships:
            if not isinstance(authorship, Mapping):
                continue
            author = authorship.get("author")
            name = author.get("display_name") if isinstance(author, Mapping) else None
            name = name or authorship.get("raw_author_name")
            if value := _optional_text(name):
                authors.append(value)
    primary_location = item.get("primary_location")
    best_location = item.get("best_oa_location")
    landing_url = None
    license_name = None
    for location in (primary_location, best_location):
        if not isinstance(location, Mapping):
            continue
        landing_url = landing_url or _optional_text(location.get("landing_page_url"))
        license_name = license_name or _optional_text(location.get("license"))
    landing_url = landing_url or doi or openalex_id
    abstract = _abstract_from_inverted_index(item.get("abstract_inverted_index"))
    response_hash = _hash_mapping(item)
    return SourceCandidate(
        provider="openalex",
        provider_id=provider_id,
        title=title,
        authors=tuple(authors),
        publication_date=_optional_text(
            item.get("publication_date") or item.get("publication_year")
        ),
        source_type=_optional_text(item.get("type")) or "article",
        abstract_or_excerpt=abstract,
        landing_url=landing_url,
        identifiers=identifiers,
        license=license_name,
        status=SourceStatus.RETRACTED if item.get("is_retracted") is True else SourceStatus.ACTIVE,
        retrieved_at=utc_now(),
        query=query,
        response_hash=response_hash,
    )


def _abstract_from_inverted_index(value: object) -> str:
    if not isinstance(value, Mapping):
        return ""
    positioned: list[tuple[int, str]] = []
    for raw_word, raw_positions in value.items():
        if not isinstance(raw_positions, list):
            continue
        for raw_position in raw_positions:
            if isinstance(raw_position, int) and 0 <= raw_position <= 100_000:
                positioned.append((raw_position, str(raw_word)))
    positioned.sort(key=lambda item: item[0])
    return " ".join(word for _, word in positioned)[:50_000]


def _openalex_filter(filters: Mapping[str, Any]) -> str:
    values: list[str] = []
    if value := filters.get("from_year"):
        values.append(f"from_publication_date:{int(str(value)):04d}-01-01")
    if value := filters.get("to_year"):
        values.append(f"to_publication_date:{int(str(value)):04d}-12-31")
    if value := filters.get("type") or filters.get("source_type"):
        values.append(f"type:{str(value)}")
    return ",".join(values)


def _request_json(
    transport: SourceTransport,
    url: str,
    headers: Mapping[str, str],
    configured_timeout: float,
    provider: str,
    *,
    context: ToolContext,
    descriptor: CapabilityDescriptor,
    sleeper: Sleeper,
    retry_delay: float,
) -> Mapping[str, Any]:
    target = _endpoint_origin(url)
    remaining = context.remaining_network_requests
    last_error: ProviderError | None = None
    for attempt in range(_MAX_RETRIES + 1):
        context.require_active()
        if attempt and remaining <= 0:
            assert last_error is not None
            raise last_error
        context.require_authorized(descriptor, "search", target=target)
        remaining = context.consume_network_request(target)
        timeout = _effective_timeout(configured_timeout, context.deadline)
        try:
            return _request_json_once(transport, url, headers, timeout, provider)
        except ProviderError as error:
            last_error = error
            if attempt >= _MAX_RETRIES or not _retryable(error) or remaining <= 0:
                raise
            if not _wait_before_retry(
                error,
                context=context,
                sleeper=sleeper,
                fallback_delay=retry_delay,
            ):
                raise
    raise AssertionError("bounded request loop exhausted")


def _request_json_once(
    transport: SourceTransport,
    url: str,
    headers: Mapping[str, str],
    timeout: float,
    provider: str,
) -> Mapping[str, Any]:
    try:
        raw = transport(url, headers, timeout)
    except ProviderError:
        raise
    except HTTPError as error:
        raise _http_provider_error(provider, error) from error
    except TimeoutError as error:
        raise ProviderError(
            f"{provider} request timed out after {timeout:g}s",
            context={"retryable": True},
        ) from error
    except URLError as error:
        if isinstance(error.reason, TimeoutError):
            raise ProviderError(
                f"{provider} request timed out after {timeout:g}s",
                context={"retryable": True},
            ) from error
        raise ProviderError(f"{provider} request failed: URLError") from error
    except OSError as error:
        raise ProviderError(f"{provider} request failed: {type(error).__name__}") from error
    if isinstance(raw, Mapping):
        return raw
    if not isinstance(raw, bytes):
        raise ProviderError(f"{provider} transport returned {type(raw).__name__}, expected bytes")
    if len(raw) > _MAX_RESPONSE_BYTES:
        raise ProviderError(f"{provider} response exceeded {_MAX_RESPONSE_BYTES} bytes")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ProviderError(f"{provider} returned invalid JSON") from error
    if not isinstance(value, Mapping):
        raise ProviderError(f"{provider} response must be a JSON object")
    return value


def _default_transport(url: str, headers: Mapping[str, str], timeout: float) -> bytes:
    request = Request(url, headers=dict(headers), method="GET")
    opener = build_opener(_NoRedirectHandler())
    try:
        with opener.open(request, timeout=timeout) as response:  # noqa: S310 - HTTPS only
            length = response.headers.get("Content-Length")
            if length and int(length) > _MAX_RESPONSE_BYTES:
                raise ProviderError("OpenAlex response is too large")
            content = bytes(response.read(_MAX_RESPONSE_BYTES + 1))
    except HTTPError as error:
        raise _http_provider_error("OpenAlex", error) from error
    if len(content) > _MAX_RESPONSE_BYTES:
        raise ProviderError("OpenAlex response is too large")
    return content


def _effective_timeout(configured: float, deadline: datetime) -> float:
    remaining = (deadline - datetime.now(UTC)).total_seconds()
    if remaining <= 0:
        raise LimitExceededError("provider deadline has elapsed")
    return max(0.001, min(configured, remaining))


def _user_agent(context_value: str, configured: str, mailto: str | None) -> str:
    base = context_value.strip() or configured
    return f"{base} (mailto:{mailto})" if mailto else base


def _hash_mapping(value: Mapping[str, Any]) -> str:
    encoded = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), default=str
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _optional_text(value: object) -> str | None:
    text = str(value).strip() if value is not None else ""
    return text or None


def _endpoint_origin(url: str) -> str:
    parsed = urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ConfigurationError("provider request URL must be HTTPS")
    port = f":{parsed.port}" if parsed.port is not None else ""
    return f"https://{parsed.hostname}{port}"


def _http_provider_error(provider: str, error: HTTPError) -> ProviderError:
    retry_after = error.headers.get("Retry-After") if error.headers else None
    message = f"{provider} HTTP {error.code}"
    if retry_after:
        message += f"; retry-after={retry_after}"
    return ProviderError(
        message,
        context={
            "status": error.code,
            "retry_after": retry_after,
            "retryable": error.code == 429 or 500 <= error.code <= 599,
        },
    )


def _retryable(error: ProviderError) -> bool:
    if error.context.get("retryable") is True:
        return True
    status = error.context.get("status")
    return isinstance(status, int) and (status == 429 or 500 <= status <= 599)


def _retry_wait_seconds(
    error: ProviderError,
    fallback: float,
    *,
    now: datetime | None = None,
) -> float:
    """Return a standards-aware Retry-After delay, falling back when absent/invalid."""

    raw = error.context.get("retry_after")
    current = now or datetime.now(UTC)
    if isinstance(raw, (int, float)) and not isinstance(raw, bool):
        value = float(raw)
        return value if math.isfinite(value) and value >= 0 else fallback
    if isinstance(raw, str):
        retry_after_text = raw.strip()
        try:
            seconds = float(retry_after_text)
        except ValueError:
            seconds = -1
        if math.isfinite(seconds) and seconds >= 0:
            return seconds
        try:
            retry_at = parsedate_to_datetime(retry_after_text)
        except (TypeError, ValueError, OverflowError):
            return fallback
        if retry_at.tzinfo is None or retry_at.utcoffset() is None:
            retry_at = retry_at.replace(tzinfo=UTC)
        return max(0.0, (retry_at.astimezone(UTC) - current).total_seconds())
    return fallback


def _wait_before_retry(
    error: ProviderError,
    *,
    context: ToolContext,
    sleeper: Sleeper,
    fallback_delay: float,
) -> bool:
    """Wait only when another attempt can begin before the absolute deadline."""

    context.require_active()
    now = datetime.now(UTC)
    delay = _retry_wait_seconds(error, fallback_delay, now=now)
    if delay >= (context.deadline - now).total_seconds():
        return False
    if delay:
        sleeper(delay)
    context.require_active()
    return True


__all__ = ["OpenAlexSourceProvider", "Sleeper", "SourceTransport"]
