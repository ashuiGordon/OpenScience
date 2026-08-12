"""Source identity normalization, cross-provider merging, and evidence extraction.

This module is deliberately provider-neutral.  Adapters return ``SourceCandidate`` values and
all canonical identity and evidence rules live here, where they can be tested without network or
filesystem access.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Mapping
from typing import Any
from urllib.parse import urlsplit, urlunsplit

from .domain import (
    EvidenceRecord,
    EvidenceStance,
    RetrievalRecord,
    SourceCandidate,
    SourceRecord,
    SourceStatus,
)

_DOI_PREFIX = re.compile(r"^(?:doi\s*:\s*|https?://(?:dx\.)?doi\.org/)", re.IGNORECASE)
_ARXIV_PREFIX = re.compile(r"^(?:arxiv\s*:\s*|https?://arxiv\.org/(?:abs|pdf)/)", re.IGNORECASE)
_PMID_PREFIX = re.compile(r"^(?:pmid\s*:\s*|https?://pubmed\.ncbi\.nlm\.nih\.gov/)", re.IGNORECASE)
_PMCID_PREFIX = re.compile(r"^(?:pmcid\s*:\s*|https?://pmc\.ncbi\.nlm\.nih\.gov/articles/)", re.I)
_OPENALEX_PREFIX = re.compile(r"^https?://openalex\.org/", re.IGNORECASE)
_TOKEN = re.compile(r"[^\W_]+", re.UNICODE)
_SENTENCE_BOUNDARY = re.compile(r"(?<=[.!?。！？])\s+|[\r\n]+")
_STATUS_PRIORITY = {
    SourceStatus.UNKNOWN: 0,
    SourceStatus.ACTIVE: 1,
    SourceStatus.CORRECTED: 2,
    SourceStatus.WITHDRAWN: 3,
    SourceStatus.RETRACTED: 4,
}
_IDENTIFIER_PRIORITY = ("doi", "pmid", "pmcid", "arxiv", "openalex", "uri", "sha256")
_MAX_EVIDENCE_PASSAGE = 2_000


def normalize_identifier(kind: str, value: object) -> str:
    """Normalize a common scholarly identifier without guessing a missing identifier type.

    The returned value does not include the type prefix.  Invalid or empty values normalize to an
    empty string, making it safe for callers to discard them before constructing domain records.
    """

    key = str(kind).strip().casefold().replace("_", "-")
    aliases = {
        "url": "uri",
        "openalex-id": "openalex",
        "arxiv-id": "arxiv",
        "pubmed": "pmid",
        "pubmed-central": "pmcid",
        "content-hash": "sha256",
        "local-path": "local-path",
    }
    key = aliases.get(key, key)
    text = str(value).strip().strip("<>")
    if not text:
        return ""

    if key == "doi":
        normalized = _DOI_PREFIX.sub("", text).strip()
        return normalized.casefold() if normalized.startswith("10.") and "/" in normalized else ""
    if key == "arxiv":
        normalized = _ARXIV_PREFIX.sub("", text).removesuffix(".pdf")
        normalized = re.sub(r"v\d+$", "", normalized, flags=re.IGNORECASE)
        return normalized.casefold().strip("/")
    if key == "pmid":
        normalized = _PMID_PREFIX.sub("", text).strip("/ ")
        return normalized if normalized.isdigit() else ""
    if key == "pmcid":
        normalized = _PMCID_PREFIX.sub("", text).strip("/ ").upper()
        if normalized and not normalized.startswith("PMC"):
            normalized = f"PMC{normalized}"
        return normalized if re.fullmatch(r"PMC\d+", normalized) else ""
    if key == "openalex":
        normalized = _OPENALEX_PREFIX.sub("", text).strip("/ ").upper()
        return normalized if re.fullmatch(r"[WASICPFT]\d+", normalized) else ""
    if key in {"isbn", "issn"}:
        return re.sub(r"[^0-9Xx]", "", text).upper()
    if key == "sha256":
        normalized = text.casefold()
        return normalized if re.fullmatch(r"[a-f0-9]{64}", normalized) else ""
    if key == "uri":
        return _normalize_uri(text)
    # Provider-specific identifiers and relative local provenance are trimmed but otherwise kept.
    return text


def merge_source_candidates(
    candidates: Iterable[SourceCandidate | Mapping[str, Any]],
) -> list[SourceRecord]:
    """Normalize candidates and deterministically merge observations of the same work."""

    normalized_candidates = [_coerce_candidate(candidate) for candidate in candidates]
    normalized_candidates.sort(
        key=lambda item: (item.provider.casefold(), item.provider_id, item.title)
    )
    groups: dict[str, list[tuple[SourceCandidate, dict[str, str]]]] = {}
    for candidate in normalized_candidates:
        candidate_identifiers = _normalized_identifiers(candidate)
        canonical_id = _canonical_id(candidate, candidate_identifiers)
        groups.setdefault(canonical_id, []).append((candidate, candidate_identifiers))

    records: list[SourceRecord] = []
    for canonical_id in sorted(groups):
        observations = groups[canonical_id]
        primary = max(
            observations,
            key=lambda item: (
                bool(item[0].abstract_or_excerpt),
                len(item[0].abstract_or_excerpt),
                len(item[0].title),
                -normalized_candidates.index(item[0]),
            ),
        )[0]
        identifiers: dict[str, str] = {}
        for _, candidate_identifiers in observations:
            for key, value in sorted(candidate_identifiers.items()):
                identifiers.setdefault(key, value)
        authors: list[str] = []
        for candidate, _ in observations:
            for author in candidate.authors:
                normalized_author = " ".join(str(author).split())
                if normalized_author and normalized_author.casefold() not in {
                    existing.casefold() for existing in authors
                }:
                    authors.append(normalized_author)
        retrievals = _retrievals(observations)
        statuses = [_coerce_status(candidate.status) for candidate, _ in observations]
        status = max(statuses, key=_STATUS_PRIORITY.__getitem__)
        publication_dates = [
            candidate.publication_date
            for candidate, _ in observations
            if candidate.publication_date
        ]
        publication_date = max(
            publication_dates, key=lambda value: (len(value), value), default=None
        )
        licenses = [candidate.license for candidate, _ in observations if candidate.license]
        landing_urls = [
            candidate.landing_url for candidate, _ in observations if candidate.landing_url
        ]
        source_types = [
            candidate.source_type for candidate, _ in observations if candidate.source_type
        ]
        records.append(
            SourceRecord(
                canonical_id=canonical_id,
                title=" ".join(primary.title.split()),
                source_type=source_types[0] if source_types else "unknown",
                providers=tuple(sorted({candidate.provider for candidate, _ in observations})),
                abstract_or_excerpt=" ".join(primary.abstract_or_excerpt.split()),
                identifiers=identifiers,
                authors=tuple(authors),
                publication_date=publication_date,
                landing_url=_preferred_url(landing_urls, identifiers),
                license=licenses[0] if licenses else None,
                status=status,
                retrievals=tuple(retrievals),
            )
        )
    return records


def extract_evidence(
    question: str,
    sources: Iterable[SourceRecord | Mapping[str, Any]],
    *,
    created_by_step: str = "extract",
) -> list[EvidenceRecord]:
    """Select one bounded, exact normalized passage per source.

    Source text is only tokenized and ranked.  It is never interpreted as an instruction or
    interpolated into executable input.
    """

    question_tokens = _tokens(question)
    evidence: list[EvidenceRecord] = []
    coerced_sources = [_coerce_source(source) for source in sources]
    coerced_sources.sort(key=lambda source: source.source_id)
    for source in coerced_sources:
        passage, locator, relevance = _best_passage(source, question_tokens)
        if not passage:
            continue
        evidence.append(
            EvidenceRecord(
                source_id=source.source_id,
                passage=passage[:_MAX_EVIDENCE_PASSAGE],
                locator=locator,
                relevance=relevance,
                # Passage selection establishes provenance and relevance, not semantic
                # agreement. A later, explicitly reviewed analysis may classify stance.
                stance=EvidenceStance.UNCLEAR,
                created_by_step=created_by_step,
                license=source.license,
            )
        )
    return evidence


def _coerce_candidate(candidate: SourceCandidate | Mapping[str, Any]) -> SourceCandidate:
    if isinstance(candidate, SourceCandidate):
        return candidate
    if not isinstance(candidate, Mapping):
        raise TypeError(f"expected SourceCandidate or mapping, got {type(candidate).__name__}")
    return SourceCandidate.from_dict(dict(candidate))


def _coerce_source(source: SourceRecord | Mapping[str, Any]) -> SourceRecord:
    if isinstance(source, SourceRecord):
        return source
    if not isinstance(source, Mapping):
        raise TypeError(f"expected SourceRecord or mapping, got {type(source).__name__}")
    return SourceRecord.from_dict(dict(source))


def _coerce_status(value: SourceStatus | str) -> SourceStatus:
    return value if isinstance(value, SourceStatus) else SourceStatus(str(value))


def _normalized_identifiers(candidate: SourceCandidate) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw_key, raw_value in candidate.identifiers.items():
        key = str(raw_key).strip().casefold().replace("_", "-")
        key = {
            "url": "uri",
            "openalex-id": "openalex",
            "arxiv-id": "arxiv",
            "pubmed": "pmid",
            "pubmed-central": "pmcid",
            "content-hash": "sha256",
        }.get(key, key)
        normalized = normalize_identifier(key, raw_value)
        if normalized:
            result[key] = normalized
    provider_id = str(candidate.provider_id).strip()
    if provider_id:
        result.setdefault(candidate.provider.casefold(), provider_id)
    return result


def _canonical_id(candidate: SourceCandidate, identifiers: Mapping[str, str]) -> str:
    for key in _IDENTIFIER_PRIORITY:
        if value := identifiers.get(key):
            return f"{key}:{value}"
    return f"provider:{candidate.provider.casefold()}:{candidate.provider_id.strip()}"


def _retrievals(
    observations: list[tuple[SourceCandidate, dict[str, str]]],
) -> list[RetrievalRecord]:
    result: list[RetrievalRecord] = []
    seen: set[tuple[str, str, str | None, str]] = set()
    for candidate, _ in observations:
        identity = (
            candidate.provider,
            candidate.query,
            candidate.landing_url,
            candidate.response_hash,
        )
        if identity in seen:
            continue
        seen.add(identity)
        result.append(
            RetrievalRecord(
                provider=candidate.provider,
                query=candidate.query,
                retrieved_at=candidate.retrieved_at,
                url=candidate.landing_url,
                response_hash=candidate.response_hash,
            )
        )
    return result


def _preferred_url(urls: list[str], identifiers: Mapping[str, str]) -> str | None:
    https_urls = sorted({url for url in urls if url.startswith("https://")})
    if https_urls:
        return https_urls[0]
    if doi := identifiers.get("doi"):
        return f"https://doi.org/{doi}"
    return sorted(set(urls))[0] if urls else None


def _best_passage(source: SourceRecord, question_tokens: set[str]) -> tuple[str, str, float]:
    excerpt = " ".join(source.abstract_or_excerpt.split())
    if not excerpt:
        title = " ".join(source.title.split())
        return title, "title", _relevance(title, question_tokens)
    passages = [" ".join(item.split()) for item in _SENTENCE_BOUNDARY.split(excerpt)]
    passages = [item for item in passages if item]
    if not passages:
        passages = [excerpt]
    indexed = list(enumerate(passages, start=1))
    sentence_number, passage = max(
        indexed,
        key=lambda item: (_relevance(item[1], question_tokens), len(_tokens(item[1])), -item[0]),
    )
    return passage, f"abstract:sentence-{sentence_number}", _relevance(passage, question_tokens)


def _relevance(text: str, question_tokens: set[str]) -> float:
    if not question_tokens:
        return 0.5
    passage_tokens = _tokens(text)
    if not passage_tokens:
        return 0.0
    overlap = len(question_tokens & passage_tokens)
    # Coverage of the question is the most interpretable deterministic baseline.
    return round(min(1.0, overlap / len(question_tokens)), 6)


def _tokens(text: str) -> set[str]:
    return {match.group(0).casefold() for match in _TOKEN.finditer(text)}


def _normalize_uri(value: str) -> str:
    try:
        parts = urlsplit(value)
        if parts.scheme.casefold() not in {"http", "https"} or not parts.hostname:
            return ""
        scheme = parts.scheme.casefold()
        host = parts.hostname.casefold()
        port = parts.port
        if port and not ((scheme == "http" and port == 80) or (scheme == "https" and port == 443)):
            host = f"{host}:{port}"
        path = parts.path or "/"
        return urlunsplit((scheme, host, path, parts.query, ""))
    except ValueError:
        return ""


__all__ = ["extract_evidence", "merge_source_candidates", "normalize_identifier"]
