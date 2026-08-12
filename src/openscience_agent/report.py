"""Human-readable research report rendering."""

from __future__ import annotations

import html
from collections import Counter
from dataclasses import asdict, is_dataclass
from typing import Any, cast

HIGH_RISK_TERMS = {
    "clinical",
    "diagnosis",
    "patient",
    "treatment",
    "human subject",
    "hazardous",
    "dual-use",
    "regulated",
    "medical",
}


def render_report(
    *,
    request: Any,
    sources: list[Any],
    evidence: list[Any],
    claims: list[Any],
    limitations: list[str],
    status: str,
    run_id: str,
) -> str:
    request_data = _mapping(request)
    source_by_id = {_mapping(item).get("source_id"): _mapping(item) for item in sources}
    evidence_by_id = {_mapping(item).get("evidence_id"): _mapping(item) for item in evidence}
    status_value = _value(status)
    question = _plain(request_data.get("question", ""))
    scope = request_data.get("scope")
    constraints = request_data.get("constraints") or []
    assumptions = request_data.get("assumptions") or []
    desired_output = request_data.get("desired_output", "research brief")
    retrieval_times = sorted(
        str(retrieval.get("retrieved_at"))
        for raw_source in sources
        for retrieval in _retrievals(_mapping(raw_source))
        if retrieval.get("retrieved_at")
    )
    provider_names = sorted(
        {
            str(provider)
            for raw_source in sources
            for provider in _providers(_mapping(raw_source))
            if str(provider).strip()
        }
    )
    source_statuses = Counter(_value(_mapping(item).get("status", "unknown")) for item in sources)
    evidence_stances = Counter(_value(_mapping(item).get("stance", "unclear")) for item in evidence)
    unknown_license_count = sum(not bool(_mapping(item).get("license")) for item in sources)
    low_relevance_count = sum(_low_relevance(_mapping(item).get("relevance")) for item in evidence)
    conflict_evidence = [
        _mapping(item)
        for item in evidence
        if _value(_mapping(item).get("stance", "unclear")) == "contradicts"
    ]
    concerning_sources = [
        _mapping(item)
        for item in sources
        if _value(_mapping(item).get("status", "unknown"))
        in {"corrected", "retracted", "withdrawn"}
    ]

    lines = [
        "# OpenScience Research Brief",
        "",
        f"**Run**: `{_plain(run_id)}`  ",
        f"**Status**: `{_plain(status_value)}`  ",
        "**Assurance level**: Evidence-linked research assistance; not independent expert review",
        "",
        "## Research Question",
        "",
        question,
        "",
    ]
    if scope:
        lines.extend(("**Scope**", "", _plain(scope), ""))
    lines.extend(("**Requested output**", "", _plain(desired_output), ""))
    lines.extend(("**Constraints**", ""))
    lines.extend(f"- {_plain(item)}" for item in constraints)
    if not constraints:
        lines.append(
            "- No explicit constraints were supplied; provider and run limits still apply."
        )
    lines.extend(("", "**Assumptions**", ""))
    lines.extend(f"- {_plain(item)}" for item in assumptions)
    if not assumptions:
        lines.append("- No explicit assumptions were supplied.")
    lines.append("")

    lines.extend(("## Findings", ""))
    if not claims:
        lines.extend(("No validated claims were produced.", ""))
    for index, raw_claim in enumerate(claims, start=1):
        claim = _mapping(raw_claim)
        kind = _value(claim.get("kind", "unsupported"))
        claim_text = _plain(claim.get("text", ""))
        evidence_ids = list(claim.get("evidence_ids") or [])
        references = " ".join(
            f"[^{_footnote_id(item)}]" for item in evidence_ids if item in evidence_by_id
        )
        lines.extend(
            (
                f"### {index}. {claim_text}",
                "",
                f"**Classification**: `{_plain(kind)}`"
                + (f"  \n**Evidence**: {references}" if references else ""),
            )
        )
        confidence = claim.get("confidence")
        if confidence is not None:
            lines.extend(("", f"**Confidence**: {float(confidence):.2f}"))
        claim_limits = claim.get("limitations") or []
        if claim_limits:
            lines.extend(("", "**Claim limitations**:", ""))
            lines.extend(f"- {_plain(item)}" for item in claim_limits)
        lines.append("")

    lines.extend(
        (
            "## Search Coverage",
            "",
            f"- Configured providers represented in retained sources: "
            f"{_plain(', '.join(provider_names) or 'none')}",
            f"- Retrieval window (UTC): {_retrieval_window(retrieval_times)}",
            f"- Source-status distribution: {_plain(_counts(source_statuses))}",
            "- Coverage is bounded by the recorded query, configured providers, access policy, "
            "request limits, and retrieval window.",
            "",
            "## Evidence Quality and Conflict Signals",
            "",
            f"- Evidence-stance distribution: {_plain(_counts(evidence_stances))}",
            f"- Sources without a recorded license: {unknown_license_count} of {len(sources)}",
            f"- Evidence records below relevance 0.50: {low_relevance_count} of {len(evidence)}",
        )
    )
    if conflict_evidence:
        lines.append(f"- Explicitly contradictory evidence records: {len(conflict_evidence)}")
        for item in conflict_evidence[:10]:
            lines.append(
                f"  - `{_plain(item.get('evidence_id', 'unknown'))}`: "
                f"{_plain(item.get('passage', ''))}"
            )
    else:
        lines.append(
            "- No evidence record was explicitly classified as contradictory; this is not proof "
            "that the literature contains no conflict."
        )
    if concerning_sources:
        lines.append("- Corrected, retracted, or withdrawn sources requiring review:")
        for source in concerning_sources[:10]:
            lines.append(
                f"  - {_plain(source.get('title', 'Unknown source'))} "
                f"(`{_plain(_value(source.get('status', 'unknown')))}`)"
            )
    else:
        lines.append("- No retained source was marked corrected, retracted, or withdrawn.")
    lines.extend(
        (
            "- Stance and relevance metadata are provider/extractor signals, not an independent "
            "semantic or methodological quality review.",
            "",
            "## Coverage and Limitations",
            "",
        )
    )
    combined_limits = list(dict.fromkeys(str(item) for item in limitations if str(item).strip()))
    if not combined_limits:
        combined_limits.append(
            "The search covers only the configured providers, query, limits, and retrieval time."
        )
    for limitation in combined_limits:
        lines.append(f"- {_plain(limitation)}")
    if _is_high_risk(question):
        lines.append(
            "- This topic requires qualified domain, ethics, safety, or regulatory review before "
            "decisions or real-world action."
        )
    lines.extend(
        (
            "",
            "## Method and Audit Trail",
            "",
            f"- Normalized sources: {len(sources)}",
            f"- Evidence records: {len(evidence)}",
            f"- Claims: {len(claims)}",
            "- Source text was treated as untrusted data, not as agent instructions.",
            "- See `manifest.json` and `events.jsonl` for configuration, activity, hashes, and "
            "provenance.",
            "",
            "## Evidence Ledger",
            "",
        )
    )
    if not evidence:
        lines.extend(("No evidence records were retained.", ""))
    for raw_evidence in evidence:
        item = _mapping(raw_evidence)
        evidence_id = item.get("evidence_id")
        source = source_by_id.get(item.get("source_id"), {})
        title = _plain(source.get("title", "Unknown source"))
        provider_names = source.get("providers") or []
        if isinstance(provider_names, str):
            provider_names = [provider_names]
        citation = title
        authors = source.get("authors") or []
        if authors:
            citation = f"{', '.join(_plain(author) for author in authors)}. {citation}"
        publication_date = source.get("publication_date")
        if publication_date:
            citation += f" ({_plain(publication_date)})"
        url = source.get("landing_url") or source.get("url")
        if url:
            citation += f". <{_safe_url(url)}>"
        lines.extend(
            (
                f"[^{_footnote_id(evidence_id)}]: {_plain(item.get('passage', ''))}",
                f"    Source: {citation}",
                f"    Locator: {_plain(item.get('locator', 'unspecified'))}; providers: "
                f"{_plain(', '.join(provider_names) or 'unknown')}; status: "
                f"{_plain(_value(source.get('status', 'unknown')))}; license: "
                f"{_plain(source.get('license') or 'unknown')}",
                "",
            )
        )

    lines.extend(
        (
            "## Responsible Use",
            "",
            "This report is generated research assistance. Verify primary sources and involve "
            "qualified experts before publication, policy, clinical, safety-critical, or regulated "
            "decisions.",
            "",
        )
    )
    return "\n".join(lines)


def _mapping(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    if hasattr(value, "to_dict"):
        result = value.to_dict()
        if isinstance(result, dict):
            return result
    if is_dataclass(value) and not isinstance(value, type):
        return asdict(cast(Any, value))
    raise TypeError(f"expected mapping-compatible value, got {type(value).__name__}")


def _plain(value: Any) -> str:
    escaped = html.escape(str(value).replace("\r", " ").replace("\n", " ").strip(), quote=False)
    for character in "\\`*_{}[]()#+-.!|<>":
        escaped = escaped.replace(character, f"\\{character}")
    return escaped


def _safe_url(value: Any) -> str:
    text = str(value).strip().replace(">", "%3E").replace("<", "%3C")
    if not text.startswith(("https://", "http://", "file://")):
        return "about:invalid"
    return text


def _footnote_id(value: Any) -> str:
    return re_safe(str(value))


def re_safe(value: str) -> str:
    return "".join(char if char.isalnum() or char in "-_" else "-" for char in value)


def _is_high_risk(question: str) -> bool:
    lowered = question.casefold()
    return any(term in lowered for term in HIGH_RISK_TERMS)


def _value(value: Any) -> str:
    return str(getattr(value, "value", value))


def _retrievals(source: dict[str, Any]) -> list[dict[str, Any]]:
    raw = source.get("retrievals") or []
    if not isinstance(raw, (list, tuple)):
        return []
    return [item for item in raw if isinstance(item, dict)]


def _providers(source: dict[str, Any]) -> list[Any]:
    raw = source.get("providers") or []
    if isinstance(raw, str):
        return [raw]
    if isinstance(raw, (list, tuple)):
        return list(raw)
    return []


def _retrieval_window(retrieval_times: list[str]) -> str:
    if not retrieval_times:
        return "not recorded"
    if retrieval_times[0] == retrieval_times[-1]:
        return _plain(retrieval_times[0])
    return f"{_plain(retrieval_times[0])} to {_plain(retrieval_times[-1])}"


def _counts(counts: Counter[str]) -> str:
    if not counts:
        return "none"
    return ", ".join(f"{key}={counts[key]}" for key in sorted(counts))


def _low_relevance(value: Any) -> bool:
    try:
        return float(value) < 0.5
    except (TypeError, ValueError):
        return True
