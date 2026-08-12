"""Capability policy, filesystem boundaries, and persistence-safe redaction."""

from __future__ import annotations

import re
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from .domain import (
    CapabilityDescriptor,
    PolicyDecision,
    PolicyOutcome,
    RiskLevel,
)
from .errors import ApprovalRequiredError, PathBoundaryError, PolicyDeniedError, ValidationError

REDACTED = "[REDACTED]"
_SENSITIVE_KEYS = {
    "access_key",
    "access_token",
    "api_key",
    "apikey",
    "authorization",
    "client_secret",
    "credential",
    "credentials",
    "password",
    "private_key",
    "refresh_token",
    "secret",
    "token",
}
_SECRET_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (
        re.compile(
            r"(?i)(\b(?:password|passwd|api[_-]?key|token|secret|client[_-]?secret)\s*[=:]\s*)([^\s,;&]+)"
        ),
        rf"\1{REDACTED}",
    ),
    (re.compile(r"(?i)(\bAuthorization\s*:\s*(?:Bearer|Basic)\s+)[^\s,;]+"), rf"\1{REDACTED}"),
    (re.compile(r"(?i)(\bBearer\s+)[A-Za-z0-9._~+/=-]{8,}"), rf"\1{REDACTED}"),
    (re.compile(r"(?i)([?&](?:token|api[_-]?key|secret|password)=)[^&#\s]+"), rf"\1{REDACTED}"),
    (re.compile(r"(?<=://)[^/@\s:]+:[^/@\s]+@"), f"{REDACTED}@"),
    (re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"), REDACTED),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"), REDACTED),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"), REDACTED),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), REDACTED),
    (
        re.compile(
            r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----",
            re.DOTALL,
        ),
        REDACTED,
    ),
)
_RISK_ORDER = {
    RiskLevel.LOCAL_READ: 0,
    RiskLevel.NETWORK_READ: 1,
    RiskLevel.WORKSPACE_WRITE: 2,
    RiskLevel.EXECUTE: 3,
    RiskLevel.CONSEQUENTIAL: 4,
}


def redact_text(value: str) -> str:
    """Redact common credential assignments, headers, URLs, and token shapes."""

    if not isinstance(value, str):
        raise TypeError("redact_text expects a string")
    result = value
    for pattern, replacement in _SECRET_PATTERNS:
        result = pattern.sub(replacement, result)
    return result


def _key_is_sensitive(key: str) -> bool:
    normalized = re.sub(r"[^a-z0-9]+", "_", key.casefold()).strip("_")
    return (
        normalized in _SENSITIVE_KEYS
        or normalized.endswith(("_password", "_secret", "_token", "_api_key"))
        or normalized.startswith(("password_", "secret_", "token_"))
    )


def redact_secrets(value: Any) -> Any:
    """Recursively redact secrets before values enter logs, prompts, or artifacts."""

    if isinstance(value, Mapping):
        result: dict[Any, Any] = {}
        for key, item in value.items():
            if isinstance(key, str) and _key_is_sensitive(key):
                result[key] = REDACTED
            else:
                result[key] = redact_secrets(item)
        return result
    if isinstance(value, list):
        return [redact_secrets(item) for item in value]
    if isinstance(value, tuple):
        return tuple(redact_secrets(item) for item in value)
    if isinstance(value, set):
        return {redact_secrets(item) for item in value}
    if isinstance(value, str):
        return redact_text(value)
    return value


def is_path_within(path: str | Path, root: str | Path) -> bool:
    """Return whether the fully resolved path is the root or a descendant of it."""

    try:
        candidate = Path(path).expanduser().resolve(strict=False)
        boundary = Path(root).expanduser().resolve(strict=False)
    except (OSError, RuntimeError):
        return False
    return candidate == boundary or boundary in candidate.parents


def resolve_approved_path(
    path: str | Path,
    approved_roots: Iterable[str | Path],
    *,
    must_exist: bool = False,
) -> Path:
    """Resolve a path, including symlinks, and require it beneath an approved root."""

    roots = tuple(Path(root).expanduser().resolve(strict=False) for root in approved_roots)
    if not roots:
        raise PathBoundaryError("no local filesystem roots have been approved")
    try:
        candidate = Path(path).expanduser().resolve(strict=must_exist)
    except (FileNotFoundError, OSError, RuntimeError) as error:
        raise PathBoundaryError(
            f"local path could not be resolved: {redact_text(str(path))}"
        ) from error
    if not any(candidate == root or root in candidate.parents for root in roots):
        raise PathBoundaryError(
            f"resolved path is outside approved roots: {redact_text(str(path))}",
            context={"path": redact_text(str(path))},
        )
    return candidate


@dataclass(frozen=True, slots=True)
class PolicyConfig:
    allow_network: bool = False
    approved_local_roots: tuple[Path, ...] = ()
    workspace_root: Path | None = None
    allowed_network_hosts: tuple[str, ...] = ()
    approved_actions: frozenset[str] = frozenset()


class PolicyEngine:
    """Evaluate every capability action before a side effect is attempted."""

    def __init__(
        self,
        *,
        allow_network: bool = False,
        approved_local_roots: Iterable[str | Path] = (),
        workspace_root: str | Path | None = None,
        allowed_network_hosts: Iterable[str] = (),
        approved_actions: Iterable[str] = (),
    ) -> None:
        if not isinstance(allow_network, bool):
            raise ValidationError("allow_network must be a boolean")
        roots = tuple(
            Path(item).expanduser().resolve(strict=False) for item in approved_local_roots
        )
        hosts = tuple(item.strip().casefold() for item in allowed_network_hosts)
        if any(not host or "://" in host or "/" in host for host in hosts):
            raise ValidationError("allowed_network_hosts must contain hostnames only")
        actions = frozenset(item.strip() for item in approved_actions)
        if "" in actions:
            raise ValidationError("approved_actions must not contain empty values")
        self.config = PolicyConfig(
            allow_network=allow_network,
            approved_local_roots=roots,
            workspace_root=(
                Path(workspace_root).expanduser().resolve(strict=False)
                if workspace_root is not None
                else None
            ),
            allowed_network_hosts=hosts,
            approved_actions=actions,
        )

    @property
    def allow_network(self) -> bool:
        return self.config.allow_network

    @property
    def approved_local_roots(self) -> tuple[Path, ...]:
        return self.config.approved_local_roots

    def evaluate(
        self,
        descriptor: CapabilityDescriptor,
        action: str,
        *,
        target: str = "",
        risk: RiskLevel | None = None,
    ) -> PolicyDecision:
        """Return an explicit allow, deny, or approval-required decision."""

        if not isinstance(descriptor, CapabilityDescriptor):
            raise ValidationError("policy requires a CapabilityDescriptor")
        normalized_action = action.strip() if isinstance(action, str) else ""
        if not normalized_action:
            raise ValidationError("policy action must be non-empty")
        requested_risk = descriptor.risk if risk is None else RiskLevel(risk)
        effective_risk = max(
            (descriptor.risk, requested_risk),
            key=lambda item: _RISK_ORDER[item],
        )
        display_target = redact_text(target)

        if not descriptor.available:
            return self._decision(
                descriptor,
                normalized_action,
                display_target,
                effective_risk,
                PolicyOutcome.DENY,
                descriptor.health_error or "capability is unavailable",
            )

        missing_permission = self._missing_permission(descriptor, effective_risk, target)
        if missing_permission:
            return self._decision(
                descriptor,
                normalized_action,
                display_target,
                effective_risk,
                PolicyOutcome.DENY,
                f"capability did not declare required permission {missing_permission}",
            )

        if effective_risk is RiskLevel.EXECUTE:
            return self._decision(
                descriptor,
                normalized_action,
                display_target,
                effective_risk,
                PolicyOutcome.DENY,
                "arbitrary process or code execution is not available in the MVP",
            )

        if effective_risk is RiskLevel.NETWORK_READ:
            if not self.config.allow_network:
                return self._decision(
                    descriptor,
                    normalized_action,
                    display_target,
                    effective_risk,
                    PolicyOutcome.DENY,
                    "network access requires explicit opt-in",
                )
            network_error = self._network_target_error(target)
            if network_error:
                return self._decision(
                    descriptor,
                    normalized_action,
                    display_target,
                    effective_risk,
                    PolicyOutcome.DENY,
                    network_error,
                )

        if effective_risk is RiskLevel.LOCAL_READ and self._looks_like_path(target):
            try:
                resolved = resolve_approved_path(target, self.config.approved_local_roots)
            except PathBoundaryError as error:
                return self._decision(
                    descriptor,
                    normalized_action,
                    display_target,
                    effective_risk,
                    PolicyOutcome.DENY,
                    str(error),
                )
            display_target = redact_text(str(resolved))

        approval_key = f"{descriptor.name}:{normalized_action}"
        explicitly_approved = (
            approval_key in self.config.approved_actions
            or descriptor.name in self.config.approved_actions
            or normalized_action in self.config.approved_actions
        )

        if effective_risk is RiskLevel.WORKSPACE_WRITE:
            if not target or self.config.workspace_root is None:
                return self._decision(
                    descriptor,
                    normalized_action,
                    display_target,
                    effective_risk,
                    PolicyOutcome.DENY,
                    "workspace write requires a declared workspace root and target",
                )
            try:
                resolved = resolve_approved_path(target, (self.config.workspace_root,))
            except PathBoundaryError as error:
                return self._decision(
                    descriptor,
                    normalized_action,
                    display_target,
                    effective_risk,
                    PolicyOutcome.DENY,
                    str(error),
                )
            display_target = redact_text(str(resolved))
            if not explicitly_approved:
                return self._decision(
                    descriptor,
                    normalized_action,
                    display_target,
                    effective_risk,
                    PolicyOutcome.APPROVAL_REQUIRED,
                    "workspace modification requires explicit approval",
                )

        if effective_risk is RiskLevel.CONSEQUENTIAL and not explicitly_approved:
            return self._decision(
                descriptor,
                normalized_action,
                display_target,
                effective_risk,
                PolicyOutcome.APPROVAL_REQUIRED,
                "consequential action requires explicit human approval",
            )

        return self._decision(
            descriptor,
            normalized_action,
            display_target,
            effective_risk,
            PolicyOutcome.ALLOW,
            "action is within the declared capability and current policy",
        )

    def require_allowed(
        self,
        descriptor: CapabilityDescriptor,
        action: str,
        *,
        target: str = "",
        risk: RiskLevel | None = None,
    ) -> PolicyDecision:
        decision = self.evaluate(descriptor, action, target=target, risk=risk)
        context = {"capability": descriptor.name, "action": action, "target": decision.target}
        if decision.outcome is PolicyOutcome.DENY:
            raise PolicyDeniedError(decision.reason, context=context)
        if decision.outcome is PolicyOutcome.APPROVAL_REQUIRED:
            raise ApprovalRequiredError(decision.reason, context=context)
        return decision

    @staticmethod
    def _decision(
        descriptor: CapabilityDescriptor,
        action: str,
        target: str,
        risk: RiskLevel,
        outcome: PolicyOutcome,
        reason: str,
    ) -> PolicyDecision:
        return PolicyDecision(
            capability=descriptor.name,
            action=action,
            target=target,
            risk=risk,
            outcome=outcome,
            reason=reason,
        )

    @staticmethod
    def _missing_permission(
        descriptor: CapabilityDescriptor,
        risk: RiskLevel,
        target: str,
    ) -> str | None:
        required: str | None = None
        if risk is RiskLevel.NETWORK_READ:
            required = "network.read"
        elif risk is RiskLevel.WORKSPACE_WRITE:
            required = "filesystem.write"
        elif risk is RiskLevel.EXECUTE:
            required = "process.execute"
        elif risk is RiskLevel.LOCAL_READ and PolicyEngine._looks_like_path(target):
            required = "filesystem.read"
        if required and required not in descriptor.permissions:
            return required
        return None

    def _network_target_error(self, target: str) -> str | None:
        if not target or "://" not in target:
            # The orchestrator may authorize a provider name before the adapter authorizes each URL.
            return None
        parsed = urlsplit(target)
        if parsed.scheme.casefold() != "https" or not parsed.hostname:
            return "network reads require an absolute HTTPS target"
        host = parsed.hostname.casefold()
        if self.config.allowed_network_hosts and host not in self.config.allowed_network_hosts:
            return f"network host is not approved: {host}"
        if parsed.username is not None or parsed.password is not None:
            return "credentials must not be embedded in network targets"
        return None

    @staticmethod
    def _looks_like_path(target: str) -> bool:
        if not target:
            return False
        parsed = urlsplit(target)
        return (
            parsed.scheme == "file"
            or Path(target).is_absolute()
            or target.startswith(("./", "../", "~/"))
        )


CapabilityPolicy = PolicyEngine


__all__ = [
    "CapabilityPolicy",
    "PolicyConfig",
    "PolicyEngine",
    "REDACTED",
    "is_path_within",
    "redact_secrets",
    "redact_text",
    "resolve_approved_path",
]
