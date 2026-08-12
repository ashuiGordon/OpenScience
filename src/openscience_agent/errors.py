"""Typed failures exposed by the provider-neutral OpenScience core."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any


class OpenScienceError(Exception):
    """Base class for an expected, actionable OpenScience failure."""

    default_code = "openscience.error"

    def __init__(
        self,
        message: str,
        *,
        code: str | None = None,
        context: Mapping[str, Any] | None = None,
    ) -> None:
        if not message:
            message = type(self).__name__
        super().__init__(message)
        self.message = message
        self.code = code or self.default_code
        self.context = dict(context or {})

    def to_dict(self) -> dict[str, Any]:
        """Return a JSON-ready diagnostic without a traceback."""

        result: dict[str, Any] = {
            "type": type(self).__name__,
            "code": self.code,
            "message": self.message,
        }
        if self.context:
            result["context"] = dict(self.context)
        return result


class ValidationError(OpenScienceError, ValueError):
    """An input or domain value violates a declared invariant."""

    default_code = "validation.invalid"


class ConfigurationError(OpenScienceError, ValueError):
    """Configuration is missing, inconsistent, or unsafe."""

    default_code = "configuration.invalid"


class ProviderError(OpenScienceError):
    """A provider failed without fabricating a successful result."""

    default_code = "provider.failed"


class ProviderRegistrationError(ProviderError, TypeError):
    """A provider does not satisfy the extension contract."""

    default_code = "provider.registration_invalid"


class PolicyError(OpenScienceError):
    """Base class for a policy result that prevents execution."""

    default_code = "policy.prevented"


class PolicyDeniedError(PolicyError, PermissionError):
    """Policy explicitly denied an attempted action."""

    default_code = "policy.denied"


class ApprovalRequiredError(PolicyError, PermissionError):
    """An action is paused until a human explicitly approves it."""

    default_code = "policy.approval_required"


class PathBoundaryError(PolicyDeniedError):
    """A resolved path is outside every approved filesystem root."""

    default_code = "policy.path_boundary"


class LimitExceededError(OpenScienceError):
    """A configured step, time, record, or provider budget ended work."""

    default_code = "run.limit_exceeded"


class RunCancelledError(OpenScienceError):
    """The user or embedding application cancelled a research run."""

    default_code = "run.cancelled"


class PersistenceError(OpenScienceError, OSError):
    """Durable state could not be written or read safely."""

    default_code = "persistence.failed"


class IntegrityError(OpenScienceError):
    """Recorded provenance, an artifact, or an event chain failed verification."""

    default_code = "integrity.failed"


# Stable, descriptive aliases for extension authors.
DomainValidationError = ValidationError
ProviderContractError = ProviderRegistrationError


__all__ = [
    "ApprovalRequiredError",
    "ConfigurationError",
    "DomainValidationError",
    "IntegrityError",
    "LimitExceededError",
    "OpenScienceError",
    "PathBoundaryError",
    "PersistenceError",
    "PolicyDeniedError",
    "PolicyError",
    "ProviderContractError",
    "ProviderError",
    "ProviderRegistrationError",
    "RunCancelledError",
    "ValidationError",
]
