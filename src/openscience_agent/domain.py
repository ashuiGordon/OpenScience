"""Provider-neutral domain records and deterministic serialization primitives.

The domain module intentionally depends only on the Python standard library.  Persisted records
are immutable dataclasses, timestamps are normalized UTC RFC 3339 strings, and every derived
identity is calculated from canonical UTF-8 JSON.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass, field, replace
from datetime import UTC, datetime
from enum import Enum, StrEnum
from pathlib import Path
from typing import Any, Protocol, Self, TypeAlias, TypeVar, cast
from urllib.parse import urlsplit

from .errors import (
    ApprovalRequiredError,
    LimitExceededError,
    PolicyDeniedError,
    RunCancelledError,
    ValidationError,
)

JSONScalar: TypeAlias = None | bool | int | float | str
JSONValue: TypeAlias = JSONScalar | list["JSONValue"] | dict[str, "JSONValue"]
SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
DATE_RE = re.compile(r"^\d{4}(?:-(?:0[1-9]|1[0-2])(?:-(?:0[1-9]|[12]\d|3[01]))?)?$")
NAME_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,254})$")


class CapabilityKind(StrEnum):
    SOURCE = "source"
    SYNTHESIS = "synthesis"
    ANALYSIS = "analysis"
    EXPORT = "export"


class RiskLevel(StrEnum):
    LOCAL_READ = "local_read"
    NETWORK_READ = "network_read"
    WORKSPACE_WRITE = "workspace_write"
    EXECUTE = "execute"
    CONSEQUENTIAL = "consequential"


class SourceStatus(StrEnum):
    ACTIVE = "active"
    CORRECTED = "corrected"
    RETRACTED = "retracted"
    WITHDRAWN = "withdrawn"
    UNKNOWN = "unknown"


class EvidenceStance(StrEnum):
    SUPPORTS = "supports"
    CONTRADICTS = "contradicts"
    CONTEXTUAL = "contextual"
    UNCLEAR = "unclear"


class ClaimKind(StrEnum):
    SOURCED_FACT = "sourced_fact"
    INFERENCE = "inference"
    ASSUMPTION = "assumption"
    HYPOTHESIS = "hypothesis"
    UNSUPPORTED = "unsupported"


class PolicyOutcome(StrEnum):
    ALLOW = "allow"
    DENY = "deny"
    APPROVAL_REQUIRED = "approval_required"


class PlanStatus(StrEnum):
    PENDING = "pending"
    RUNNING = "running"
    COMPLETED = "completed"
    PARTIAL = "partial"
    FAILED = "failed"
    CANCELLED = "cancelled"


class RunStatus(StrEnum):
    CREATED = "created"
    AWAITING_APPROVAL = "awaiting_approval"
    RUNNING = "running"
    COMPLETED = "completed"
    PARTIAL = "partial"
    FAILED = "failed"
    CANCELLED = "cancelled"


# Compatibility name used by extension authors who prefer an entity-specific enum name.
StepStatus = PlanStatus
PlanStepStatus = PlanStatus


def format_datetime(value: datetime) -> str:
    """Normalize an aware datetime as a UTC RFC 3339 string."""

    if value.tzinfo is None or value.utcoffset() is None:
        raise ValidationError("timestamp must include a timezone")
    normalized = value.astimezone(UTC)
    rendered = normalized.isoformat(timespec="microseconds")
    return rendered.replace("+00:00", "Z")


def parse_datetime(value: str, *, field_name: str = "timestamp") -> datetime:
    """Parse an RFC 3339 timestamp and reject timezone-naive values."""

    if not isinstance(value, str) or not value.strip():
        raise ValidationError(f"{field_name} must be a non-empty RFC 3339 string")
    candidate = value.strip()
    try:
        parsed = datetime.fromisoformat(
            candidate[:-1] + "+00:00" if candidate.endswith("Z") else candidate
        )
    except ValueError as error:
        raise ValidationError(f"{field_name} must be a valid RFC 3339 timestamp") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValidationError(f"{field_name} must include a timezone")
    return parsed.astimezone(UTC)


def normalize_timestamp(value: str | datetime, *, field_name: str = "timestamp") -> str:
    if isinstance(value, datetime):
        return format_datetime(value)
    return format_datetime(parse_datetime(value, field_name=field_name))


def utc_now() -> str:
    """Return the current time as an aware UTC RFC 3339 string."""

    return format_datetime(datetime.now(UTC))


def _json_ready(value: Any, *, path: str = "$") -> JSONValue:
    if value is None or isinstance(value, (str, bool, int)):
        return cast(JSONScalar, value)
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError(f"{path} contains a non-finite float")
        return value
    if isinstance(value, Enum):
        return _json_ready(value.value, path=path)
    if isinstance(value, datetime):
        return format_datetime(value)
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, Mapping):
        result: dict[str, JSONValue] = {}
        for key, item in value.items():
            if not isinstance(key, str):
                raise TypeError(f"{path} has a non-string mapping key")
            result[key] = _json_ready(item, path=f"{path}.{key}")
        return result
    if isinstance(value, (list, tuple)):
        return [_json_ready(item, path=f"{path}[{index}]") for index, item in enumerate(value)]
    to_dict = getattr(value, "to_dict", None)
    if callable(to_dict):
        return _json_ready(to_dict(), path=path)
    raise TypeError(f"{path} contains non-JSON value {type(value).__name__}")


def canonical_json(value: Any) -> str:
    """Serialize a value using stable sorted canonical UTF-8 JSON conventions."""

    return json.dumps(
        _json_ready(value),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    )


def sha256_bytes(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def sha256_text(content: str) -> str:
    if not isinstance(content, str):
        raise TypeError("sha256_text content must be a string")
    return sha256_bytes(content.encode("utf-8"))


def sha256_json(value: Any) -> str:
    return sha256_text(canonical_json(value))


def stable_id(prefix: str, value: Any) -> str:
    """Return a type-prefixed, full SHA-256 content identity."""

    normalized_prefix = prefix.strip().lower().replace("_", "-")
    if not normalized_prefix or not re.fullmatch(r"[a-z][a-z0-9-]*", normalized_prefix):
        raise ValidationError("stable ID prefix must start with a lowercase ASCII letter")
    return f"{normalized_prefix}-{sha256_json(value)}"


def _non_empty(value: str, name: str, *, maximum: int = 10_000) -> str:
    if not isinstance(value, str):
        raise ValidationError(f"{name} must be a string")
    normalized = value.strip()
    if not normalized:
        raise ValidationError(f"{name} must be non-empty")
    if len(normalized) > maximum:
        raise ValidationError(f"{name} must not exceed {maximum} characters")
    return normalized


def _optional_text(value: str | None, name: str, *, maximum: int = 10_000) -> str | None:
    if value is None:
        return None
    return _non_empty(value, name, maximum=maximum)


def _strings(
    values: Iterable[str],
    name: str,
    *,
    maximum_items: int = 100,
    item_maximum: int = 10_000,
    unique: bool = False,
) -> tuple[str, ...]:
    if isinstance(values, (str, bytes)):
        raise ValidationError(f"{name} must be a sequence of strings")
    result = tuple(_non_empty(item, f"{name} item", maximum=item_maximum) for item in values)
    if len(result) > maximum_items:
        raise ValidationError(f"{name} must have no more than {maximum_items} items")
    if unique and len(set(result)) != len(result):
        raise ValidationError(f"{name} must not contain duplicates")
    return result


def _name(value: str, name: str) -> str:
    normalized = _non_empty(value, name, maximum=255)
    if not NAME_RE.fullmatch(normalized):
        raise ValidationError(f"{name} contains unsupported characters")
    return normalized


def _positive_int(value: int, name: str, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValidationError(f"{name} must be an integer")
    if not 1 <= value <= maximum:
        raise ValidationError(f"{name} must be between 1 and {maximum}")
    return value


def _nonnegative_int(value: int, name: str, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValidationError(f"{name} must be an integer")
    if not 0 <= value <= maximum:
        raise ValidationError(f"{name} must be between 0 and {maximum}")
    return value


def _score(value: float, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValidationError(f"{name} must be a number")
    result = float(value)
    if not math.isfinite(result) or not 0.0 <= result <= 1.0:
        raise ValidationError(f"{name} must be between 0.0 and 1.0")
    return result


def _sha256(value: str, name: str) -> str:
    if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
        raise ValidationError(f"{name} must be a lowercase SHA-256 digest")
    return value


EnumT = TypeVar("EnumT", bound=Enum)


def _enum(enum_type: type[EnumT], value: EnumT | str, name: str) -> EnumT:
    if isinstance(value, enum_type):
        return value
    try:
        return enum_type(value)
    except (TypeError, ValueError) as error:
        choices = ", ".join(str(item.value) for item in enum_type)
        raise ValidationError(f"{name} must be one of: {choices}") from error


def _mapping(value: Mapping[str, Any], name: str) -> dict[str, JSONValue]:
    if not isinstance(value, Mapping):
        raise ValidationError(f"{name} must be a mapping")
    try:
        ready = _json_ready(value, path=name)
    except (TypeError, ValueError) as error:
        raise ValidationError(f"{name} must contain only JSON-compatible values") from error
    if not isinstance(ready, dict):
        raise ValidationError(f"{name} must be a mapping")
    return ready


def _uri(value: str | None, name: str) -> str | None:
    if value is None:
        return None
    normalized = _non_empty(value, name, maximum=8_192)
    parsed = urlsplit(normalized)
    if not parsed.scheme:
        raise ValidationError(f"{name} must be an absolute URI")
    if parsed.scheme in {"http", "https"} and not parsed.netloc:
        raise ValidationError(f"{name} must include a host")
    return normalized


def _dict_input(data: Mapping[str, Any], record: str) -> dict[str, Any]:
    if not isinstance(data, Mapping):
        raise ValidationError(f"{record} must be decoded from an object")
    return dict(data)


class JSONRecord:
    """Mixin shared by stable JSON domain records."""

    def to_dict(self) -> dict[str, JSONValue]:
        raise NotImplementedError

    def to_json(self) -> str:
        return canonical_json(self.to_dict())

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> Self:
        raise NotImplementedError

    @classmethod
    def from_json(cls, payload: str | bytes | bytearray) -> Self:
        try:
            value = json.loads(payload)
        except (TypeError, json.JSONDecodeError) as error:
            raise ValidationError(f"{cls.__name__} JSON is invalid") from error
        if not isinstance(value, dict):
            raise ValidationError(f"{cls.__name__} JSON must contain an object")
        return cls.from_dict(value)


@dataclass(frozen=True, slots=True)
class RunLimits(JSONRecord):
    max_steps: int = 20
    max_records: int = 50
    max_network_requests: int = 10
    timeout_seconds: int = 300

    def __post_init__(self) -> None:
        object.__setattr__(self, "max_steps", _positive_int(self.max_steps, "max_steps", 10_000))
        object.__setattr__(
            self, "max_records", _positive_int(self.max_records, "max_records", 1_000_000)
        )
        object.__setattr__(
            self,
            "max_network_requests",
            _nonnegative_int(self.max_network_requests, "max_network_requests", 100_000),
        )
        object.__setattr__(
            self,
            "timeout_seconds",
            _positive_int(self.timeout_seconds, "timeout_seconds", 86_400),
        )

    def to_dict(self) -> dict[str, JSONValue]:
        return {
            "max_steps": self.max_steps,
            "max_records": self.max_records,
            "max_network_requests": self.max_network_requests,
            "timeout_seconds": self.timeout_seconds,
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> RunLimits:
        values = _dict_input(data, cls.__name__)
        return cls(
            max_steps=values.get("max_steps", 20),
            max_records=values.get("max_records", 50),
            max_network_requests=values.get("max_network_requests", 10),
            timeout_seconds=values.get("timeout_seconds", 300),
        )


@dataclass(frozen=True, slots=True)
class ResearchRequest(JSONRecord):
    question: str
    request_id: str = ""
    scope: str | None = None
    constraints: tuple[str, ...] = ()
    assumptions: tuple[str, ...] = ()
    desired_output: str = "research brief"
    source_names: tuple[str, ...] = ()
    approved_local_roots: tuple[str, ...] = ()
    limits: RunLimits = field(default_factory=RunLimits)
    created_at: str = field(default_factory=utc_now)

    def __post_init__(self) -> None:
        question = _non_empty(self.question, "question", maximum=10_000)
        if len(question) < 10:
            raise ValidationError("question must contain at least 10 characters")
        object.__setattr__(self, "question", question)
        object.__setattr__(self, "scope", _optional_text(self.scope, "scope"))
        object.__setattr__(self, "constraints", _strings(self.constraints, "constraints"))
        object.__setattr__(self, "assumptions", _strings(self.assumptions, "assumptions"))
        object.__setattr__(
            self, "desired_output", _non_empty(self.desired_output, "desired_output")
        )
        object.__setattr__(
            self,
            "source_names",
            _strings(
                self.source_names, "source_names", maximum_items=100, item_maximum=255, unique=True
            ),
        )
        roots = _strings(
            self.approved_local_roots,
            "approved_local_roots",
            maximum_items=100,
            item_maximum=32_768,
            unique=True,
        )
        resolved_roots = tuple(str(Path(item).expanduser().resolve(strict=False)) for item in roots)
        if len(set(resolved_roots)) != len(resolved_roots):
            raise ValidationError("approved_local_roots must resolve to unique paths")
        object.__setattr__(self, "approved_local_roots", resolved_roots)
        limits_value: Any = self.limits
        if not isinstance(limits_value, RunLimits):
            if isinstance(limits_value, Mapping):
                object.__setattr__(self, "limits", RunLimits.from_dict(limits_value))
            else:
                raise ValidationError("limits must be RunLimits")
        object.__setattr__(
            self, "created_at", normalize_timestamp(self.created_at, field_name="created_at")
        )
        calculated_id = stable_id("request", self._identity_dict())
        if self.request_id and _name(self.request_id, "request_id") != calculated_id:
            raise ValidationError("request_id does not match request content")
        object.__setattr__(self, "request_id", calculated_id)

    def _identity_dict(self) -> dict[str, JSONValue]:
        return {
            "question": self.question,
            "scope": self.scope,
            "constraints": list(self.constraints),
            "assumptions": list(self.assumptions),
            "desired_output": self.desired_output,
            "source_names": list(self.source_names),
            "approved_local_roots": list(self.approved_local_roots),
            "limits": self.limits.to_dict(),
            "created_at": self.created_at,
        }

    @property
    def hash(self) -> str:
        return sha256_json(self.to_dict())

    def to_dict(self) -> dict[str, JSONValue]:
        return {"request_id": self.request_id, **self._identity_dict()}

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> ResearchRequest:
        values = _dict_input(data, cls.__name__)
        values.pop("hash", None)
        return cls(
            question=values.get("question", ""),
            request_id=values.get("request_id", ""),
            scope=values.get("scope"),
            constraints=tuple(values.get("constraints") or ()),
            assumptions=tuple(values.get("assumptions") or ()),
            desired_output=values.get("desired_output", "research brief"),
            source_names=tuple(values.get("source_names") or ()),
            approved_local_roots=tuple(values.get("approved_local_roots") or ()),
            limits=RunLimits.from_dict(values.get("limits") or {}),
            created_at=values.get("created_at", utc_now()),
        )


_TERMINAL_PLAN_STATUSES = {
    PlanStatus.COMPLETED,
    PlanStatus.PARTIAL,
    PlanStatus.FAILED,
    PlanStatus.CANCELLED,
}
_PLAN_TRANSITIONS: dict[PlanStatus, frozenset[PlanStatus]] = {
    PlanStatus.PENDING: frozenset({PlanStatus.RUNNING, PlanStatus.CANCELLED}),
    PlanStatus.RUNNING: frozenset(
        {PlanStatus.COMPLETED, PlanStatus.PARTIAL, PlanStatus.FAILED, PlanStatus.CANCELLED}
    ),
}


@dataclass(frozen=True, slots=True)
class PlanStep(JSONRecord):
    title: str
    purpose: str
    capability: str
    completion_condition: str
    step_id: str = ""
    dependencies: tuple[str, ...] = ()
    status: PlanStatus = PlanStatus.PENDING

    def __post_init__(self) -> None:
        object.__setattr__(self, "title", _non_empty(self.title, "title", maximum=1_000))
        object.__setattr__(self, "purpose", _non_empty(self.purpose, "purpose"))
        object.__setattr__(self, "capability", _name(self.capability, "capability"))
        object.__setattr__(
            self,
            "completion_condition",
            _non_empty(self.completion_condition, "completion_condition"),
        )
        dependencies = _strings(
            self.dependencies,
            "dependencies",
            maximum_items=1_000,
            item_maximum=255,
            unique=True,
        )
        object.__setattr__(self, "dependencies", dependencies)
        object.__setattr__(self, "status", _enum(PlanStatus, self.status, "status"))
        if self.step_id:
            step_id = _name(self.step_id, "step_id")
        else:
            step_id = stable_id(
                "step",
                {
                    "title": self.title,
                    "purpose": self.purpose,
                    "capability": self.capability,
                    "completion_condition": self.completion_condition,
                    "dependencies": list(self.dependencies),
                },
            )
        if step_id in dependencies:
            raise ValidationError("a plan step cannot depend on itself")
        object.__setattr__(self, "step_id", step_id)

    def transition(self, status: PlanStatus | str) -> PlanStep:
        next_status = _enum(PlanStatus, status, "status")
        if next_status is self.status:
            return self
        if self.status in _TERMINAL_PLAN_STATUSES:
            raise ValidationError(f"plan step status {self.status.value} is terminal")
        if next_status not in _PLAN_TRANSITIONS.get(self.status, frozenset()):
            raise ValidationError(
                f"invalid plan step transition: {self.status.value} -> {next_status.value}"
            )
        return replace(self, status=next_status)

    def to_dict(self) -> dict[str, JSONValue]:
        return {
            "step_id": self.step_id,
            "title": self.title,
            "purpose": self.purpose,
            "capability": self.capability,
            "dependencies": list(self.dependencies),
            "completion_condition": self.completion_condition,
            "status": self.status.value,
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> PlanStep:
        values = _dict_input(data, cls.__name__)
        return cls(
            step_id=values.get("step_id", ""),
            title=values.get("title", ""),
            purpose=values.get("purpose", ""),
            capability=values.get("capability", ""),
            dependencies=tuple(values.get("dependencies") or ()),
            completion_condition=values.get("completion_condition", ""),
            status=values.get("status", PlanStatus.PENDING.value),
        )


@dataclass(frozen=True, slots=True)
class ResearchPlan(JSONRecord):
    steps: tuple[PlanStep, ...]
    plan_id: str = ""
    created_at: str = field(default_factory=utc_now)

    def __post_init__(self) -> None:
        steps_value: Any = self.steps
        if isinstance(steps_value, list):
            object.__setattr__(self, "steps", tuple(steps_value))
        if not self.steps:
            raise ValidationError("research plan must contain at least one step")
        if len(self.steps) > 10_000:
            raise ValidationError("research plan must contain at most 10000 steps")
        if not all(isinstance(item, PlanStep) for item in self.steps):
            raise ValidationError("research plan steps must be PlanStep values")
        ids = tuple(item.step_id for item in self.steps)
        if len(set(ids)) != len(ids):
            raise ValidationError("research plan step IDs must be unique")
        known = set(ids)
        for step in self.steps:
            unknown = set(step.dependencies) - known
            if unknown:
                raise ValidationError(
                    f"step {step.step_id} has unknown dependency: {sorted(unknown)[0]}"
                )
        self._assert_acyclic()
        object.__setattr__(
            self, "created_at", normalize_timestamp(self.created_at, field_name="created_at")
        )
        calculated_id = stable_id(
            "plan",
            {
                "steps": [item.to_dict() for item in self.steps],
                "created_at": self.created_at,
            },
        )
        if self.plan_id and _name(self.plan_id, "plan_id") != calculated_id:
            raise ValidationError("plan_id does not match plan content")
        object.__setattr__(self, "plan_id", calculated_id)

    def _assert_acyclic(self) -> None:
        graph = {item.step_id: item.dependencies for item in self.steps}
        visiting: set[str] = set()
        visited: set[str] = set()

        def visit(step_id: str) -> None:
            if step_id in visiting:
                raise ValidationError("research plan dependency graph contains a cycle")
            if step_id in visited:
                return
            visiting.add(step_id)
            for dependency in graph[step_id]:
                visit(dependency)
            visiting.remove(step_id)
            visited.add(step_id)

        for step_id in graph:
            visit(step_id)

    @property
    def hash(self) -> str:
        return sha256_json(self.to_dict())

    def to_dict(self) -> dict[str, JSONValue]:
        return {
            "plan_id": self.plan_id,
            "steps": [item.to_dict() for item in self.steps],
            "created_at": self.created_at,
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> ResearchPlan:
        values = _dict_input(data, cls.__name__)
        values.pop("hash", None)
        raw_steps = values.get("steps") or ()
        if not isinstance(raw_steps, (list, tuple)):
            raise ValidationError("steps must be a sequence")
        return cls(
            plan_id=values.get("plan_id", ""),
            steps=tuple(
                item if isinstance(item, PlanStep) else PlanStep.from_dict(item)
                for item in raw_steps
            ),
            created_at=values.get("created_at", utc_now()),
        )


@dataclass(frozen=True, slots=True)
class CapabilityDescriptor(JSONRecord):
    name: str
    version: str
    kind: CapabilityKind
    risk: RiskLevel
    input_schema: Mapping[str, Any] = field(default_factory=dict)
    output_schema: Mapping[str, Any] = field(default_factory=dict)
    permissions: tuple[str, ...] = ()
    available: bool = True
    contract_version: int = 1
    supported_contract_versions: tuple[int, ...] = (1,)
    health_error: str | None = None

    def __post_init__(self) -> None:
        object.__setattr__(self, "name", _name(self.name, "capability name"))
        object.__setattr__(self, "version", _non_empty(self.version, "version", maximum=255))
        object.__setattr__(self, "kind", _enum(CapabilityKind, self.kind, "kind"))
        object.__setattr__(self, "risk", _enum(RiskLevel, self.risk, "risk"))
        object.__setattr__(self, "input_schema", _mapping(self.input_schema, "input_schema"))
        object.__setattr__(self, "output_schema", _mapping(self.output_schema, "output_schema"))
        object.__setattr__(
            self,
            "permissions",
            _strings(
                self.permissions,
                "permissions",
                maximum_items=100,
                item_maximum=255,
                unique=True,
            ),
        )
        if not isinstance(self.available, bool):
            raise ValidationError("available must be a boolean")
        object.__setattr__(
            self,
            "contract_version",
            _positive_int(self.contract_version, "contract_version", 1_000),
        )
        versions = tuple(self.supported_contract_versions)
        if not versions or any(
            isinstance(item, bool) or not isinstance(item, int) or item < 1 for item in versions
        ):
            raise ValidationError("supported_contract_versions must contain positive integers")
        if len(set(versions)) != len(versions):
            raise ValidationError("supported_contract_versions must not contain duplicates")
        if self.contract_version not in versions:
            raise ValidationError(
                "contract_version must be included in supported_contract_versions"
            )
        object.__setattr__(self, "supported_contract_versions", versions)
        object.__setattr__(
            self,
            "health_error",
            _optional_text(self.health_error, "health_error", maximum=10_000),
        )

    def to_dict(self) -> dict[str, JSONValue]:
        return {
            "name": self.name,
            "version": self.version,
            "kind": self.kind.value,
            "risk": self.risk.value,
            "input_schema": dict(self.input_schema),
            "output_schema": dict(self.output_schema),
            "permissions": list(self.permissions),
            "available": self.available,
            "contract_version": self.contract_version,
            "supported_contract_versions": list(self.supported_contract_versions),
            "health_error": self.health_error,
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> CapabilityDescriptor:
        values = _dict_input(data, cls.__name__)
        contract_version = values.get("contract_version", 1)
        return cls(
            name=values.get("name", ""),
            version=values.get("version", ""),
            kind=values.get("kind", ""),
            risk=values.get("risk", ""),
            input_schema=values.get("input_schema") or {},
            output_schema=values.get("output_schema") or {},
            permissions=tuple(values.get("permissions") or ()),
            available=values.get("available", True),
            contract_version=contract_version,
            supported_contract_versions=tuple(
                values.get("supported_contract_versions") or (contract_version,)
            ),
            health_error=values.get("health_error"),
        )


@dataclass(frozen=True, slots=True)
class SearchRequest(JSONRecord):
    query: str
    limit: int = 10
    filters: Mapping[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        object.__setattr__(self, "query", _non_empty(self.query, "query", maximum=10_000))
        object.__setattr__(self, "limit", _positive_int(self.limit, "limit", 10_000))
        object.__setattr__(self, "filters", _mapping(self.filters, "filters"))

    @property
    def question(self) -> str:
        return self.query

    def to_dict(self) -> dict[str, JSONValue]:
        return {"query": self.query, "limit": self.limit, "filters": dict(self.filters)}

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> SearchRequest:
        values = _dict_input(data, cls.__name__)
        return cls(
            query=values.get("query", values.get("question", "")),
            limit=values.get("limit", 10),
            filters=values.get("filters") or {},
        )


@dataclass(frozen=True, slots=True)
class SourceCandidate(JSONRecord):
    provider: str
    provider_id: str
    title: str
    authors: tuple[str, ...] = ()
    publication_date: str | None = None
    source_type: str = "article"
    abstract_or_excerpt: str = ""
    landing_url: str | None = None
    identifiers: Mapping[str, str] = field(default_factory=dict)
    license: str | None = None
    status: SourceStatus = SourceStatus.UNKNOWN
    retrieved_at: str = field(default_factory=utc_now)
    query: str = ""
    response_hash: str = ""

    def __post_init__(self) -> None:
        object.__setattr__(self, "provider", _name(self.provider, "provider"))
        object.__setattr__(self, "provider_id", _non_empty(self.provider_id, "provider_id"))
        object.__setattr__(self, "title", _non_empty(self.title, "title", maximum=10_000))
        object.__setattr__(
            self,
            "authors",
            _strings(self.authors, "authors", maximum_items=10_000, item_maximum=1_000),
        )
        if self.publication_date is not None:
            publication_date = _non_empty(self.publication_date, "publication_date", maximum=10)
            if not DATE_RE.fullmatch(publication_date):
                raise ValidationError("publication_date must be an ISO year, month, or date")
            object.__setattr__(self, "publication_date", publication_date)
        object.__setattr__(self, "source_type", _name(self.source_type, "source_type"))
        if not isinstance(self.abstract_or_excerpt, str):
            raise ValidationError("abstract_or_excerpt must be a string")
        if len(self.abstract_or_excerpt) > 1_000_000:
            raise ValidationError("abstract_or_excerpt exceeds the one-megabyte character limit")
        object.__setattr__(self, "landing_url", _uri(self.landing_url, "landing_url"))
        if not isinstance(self.identifiers, Mapping):
            raise ValidationError("identifiers must be a mapping")
        identifiers: dict[str, str] = {}
        for key, value in self.identifiers.items():
            normalized_key = _name(str(key).casefold(), "identifier key")
            identifiers[normalized_key] = _non_empty(value, f"identifier {normalized_key}")
        object.__setattr__(self, "identifiers", identifiers)
        object.__setattr__(self, "license", _optional_text(self.license, "license", maximum=1_000))
        object.__setattr__(self, "status", _enum(SourceStatus, self.status, "status"))
        object.__setattr__(
            self,
            "retrieved_at",
            normalize_timestamp(self.retrieved_at, field_name="retrieved_at"),
        )
        if not isinstance(self.query, str):
            raise ValidationError("query must be a string")
        if len(self.query) > 10_000:
            raise ValidationError("query must not exceed 10000 characters")
        if self.response_hash:
            object.__setattr__(self, "response_hash", _sha256(self.response_hash, "response_hash"))
        else:
            object.__setattr__(
                self,
                "response_hash",
                sha256_json(
                    {
                        "provider": self.provider,
                        "provider_id": self.provider_id,
                        "title": self.title,
                        "authors": list(self.authors),
                        "publication_date": self.publication_date,
                        "abstract_or_excerpt": self.abstract_or_excerpt,
                        "landing_url": self.landing_url,
                        "identifiers": dict(self.identifiers),
                        "status": self.status.value,
                    }
                ),
            )

    def to_dict(self) -> dict[str, JSONValue]:
        return {
            "provider": self.provider,
            "provider_id": self.provider_id,
            "title": self.title,
            "authors": list(self.authors),
            "publication_date": self.publication_date,
            "source_type": self.source_type,
            "abstract_or_excerpt": self.abstract_or_excerpt,
            "landing_url": self.landing_url,
            "identifiers": dict(self.identifiers),
            "license": self.license,
            "status": self.status.value,
            "retrieved_at": self.retrieved_at,
            "query": self.query,
            "response_hash": self.response_hash,
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> SourceCandidate:
        values = _dict_input(data, cls.__name__)
        return cls(
            provider=values.get("provider", ""),
            provider_id=values.get("provider_id", ""),
            title=values.get("title", ""),
            authors=tuple(values.get("authors") or ()),
            publication_date=values.get("publication_date"),
            source_type=values.get("source_type", "article"),
            abstract_or_excerpt=values.get("abstract_or_excerpt", ""),
            landing_url=values.get("landing_url"),
            identifiers=values.get("identifiers") or {},
            license=values.get("license"),
            status=values.get("status", SourceStatus.UNKNOWN.value),
            retrieved_at=values.get("retrieved_at", utc_now()),
            query=values.get("query", ""),
            response_hash=values.get("response_hash", ""),
        )


@dataclass(frozen=True, slots=True)
class RetrievalRecord(JSONRecord):
    provider: str
    query: str = ""
    retrieved_at: str = field(default_factory=utc_now)
    url: str | None = None
    response_hash: str = ""
    retrieval_id: str = ""

    def __post_init__(self) -> None:
        object.__setattr__(self, "provider", _name(self.provider, "provider"))
        if not isinstance(self.query, str) or len(self.query) > 10_000:
            raise ValidationError("query must be a string of at most 10000 characters")
        object.__setattr__(
            self,
            "retrieved_at",
            normalize_timestamp(self.retrieved_at, field_name="retrieved_at"),
        )
        object.__setattr__(self, "url", _uri(self.url, "url"))
        response_hash = (
            _sha256(self.response_hash, "response_hash")
            if self.response_hash
            else sha256_json(
                {
                    "provider": self.provider,
                    "query": self.query,
                    "retrieved_at": self.retrieved_at,
                    "url": self.url,
                }
            )
        )
        object.__setattr__(self, "response_hash", response_hash)
        if self.retrieval_id:
            object.__setattr__(self, "retrieval_id", _name(self.retrieval_id, "retrieval_id"))
        else:
            object.__setattr__(
                self,
                "retrieval_id",
                stable_id(
                    "retrieval",
                    {
                        "provider": self.provider,
                        "query": self.query,
                        "retrieved_at": self.retrieved_at,
                        "url": self.url,
                        "response_hash": self.response_hash,
                    },
                ),
            )

    def to_dict(self) -> dict[str, JSONValue]:
        return {
            "retrieval_id": self.retrieval_id,
            "provider": self.provider,
            "query": self.query,
            "retrieved_at": self.retrieved_at,
            "url": self.url,
            "response_hash": self.response_hash,
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> RetrievalRecord:
        values = _dict_input(data, cls.__name__)
        return cls(
            provider=values.get("provider", ""),
            query=values.get("query", ""),
            retrieved_at=values.get("retrieved_at", utc_now()),
            url=values.get("url"),
            response_hash=values.get("response_hash", ""),
            retrieval_id=values.get("retrieval_id", ""),
        )


@dataclass(frozen=True, slots=True)
class SourceRecord(JSONRecord):
    canonical_id: str
    title: str
    source_type: str
    providers: tuple[str, ...]
    abstract_or_excerpt: str = ""
    source_id: str = ""
    identifiers: Mapping[str, str] = field(default_factory=dict)
    authors: tuple[str, ...] = ()
    publication_date: str | None = None
    landing_url: str | None = None
    license: str | None = None
    status: SourceStatus = SourceStatus.UNKNOWN
    retrievals: tuple[RetrievalRecord, ...] = ()
    content_hash: str = ""

    def __post_init__(self) -> None:
        object.__setattr__(self, "canonical_id", _non_empty(self.canonical_id, "canonical_id"))
        object.__setattr__(self, "title", _non_empty(self.title, "title", maximum=10_000))
        object.__setattr__(self, "source_type", _name(self.source_type, "source_type"))
        object.__setattr__(
            self,
            "providers",
            _strings(
                self.providers,
                "providers",
                maximum_items=1_000,
                item_maximum=255,
                unique=True,
            ),
        )
        if not self.providers:
            raise ValidationError("providers must identify at least one observation")
        if not isinstance(self.abstract_or_excerpt, str):
            raise ValidationError("abstract_or_excerpt must be a string")
        if len(self.abstract_or_excerpt) > 1_000_000:
            raise ValidationError("abstract_or_excerpt exceeds the one-megabyte character limit")
        if not isinstance(self.identifiers, Mapping):
            raise ValidationError("identifiers must be a mapping")
        identifiers: dict[str, str] = {}
        for key, value in self.identifiers.items():
            normalized_key = _name(str(key).casefold(), "identifier key")
            identifiers[normalized_key] = _non_empty(value, f"identifier {normalized_key}")
        object.__setattr__(self, "identifiers", identifiers)
        object.__setattr__(
            self,
            "authors",
            _strings(self.authors, "authors", maximum_items=10_000, item_maximum=1_000),
        )
        if self.publication_date is not None:
            publication_date = _non_empty(self.publication_date, "publication_date", maximum=10)
            if not DATE_RE.fullmatch(publication_date):
                raise ValidationError("publication_date must be an ISO year, month, or date")
            object.__setattr__(self, "publication_date", publication_date)
        object.__setattr__(self, "landing_url", _uri(self.landing_url, "landing_url"))
        object.__setattr__(self, "license", _optional_text(self.license, "license", maximum=1_000))
        object.__setattr__(self, "status", _enum(SourceStatus, self.status, "status"))
        retrievals = tuple(self.retrievals)
        if not all(isinstance(item, RetrievalRecord) for item in retrievals):
            raise ValidationError("retrievals must contain RetrievalRecord values")
        object.__setattr__(self, "retrievals", retrievals)
        calculated_hash = sha256_json(
            {
                "canonical_id": self.canonical_id.casefold(),
                "title": self.title,
                "authors": list(self.authors),
                "publication_date": self.publication_date,
                "source_type": self.source_type,
                "abstract_or_excerpt": self.abstract_or_excerpt,
            }
        )
        if self.content_hash and _sha256(self.content_hash, "content_hash") != calculated_hash:
            raise ValidationError("content_hash does not match normalized source content")
        object.__setattr__(self, "content_hash", calculated_hash)
        calculated_id = stable_id("source", {"canonical_id": self.canonical_id.casefold()})
        if self.source_id and _name(self.source_id, "source_id") != calculated_id:
            raise ValidationError("source_id does not match canonical source identity")
        object.__setattr__(self, "source_id", calculated_id)

    def to_dict(self) -> dict[str, JSONValue]:
        return {
            "source_id": self.source_id,
            "canonical_id": self.canonical_id,
            "identifiers": dict(self.identifiers),
            "title": self.title,
            "authors": list(self.authors),
            "publication_date": self.publication_date,
            "source_type": self.source_type,
            "abstract_or_excerpt": self.abstract_or_excerpt,
            "landing_url": self.landing_url,
            "license": self.license,
            "status": self.status.value,
            "providers": list(self.providers),
            "retrievals": [item.to_dict() for item in self.retrievals],
            "content_hash": self.content_hash,
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> SourceRecord:
        values = _dict_input(data, cls.__name__)
        raw_retrievals = values.get("retrievals") or ()
        return cls(
            canonical_id=values.get("canonical_id", ""),
            title=values.get("title", ""),
            source_type=values.get("source_type", ""),
            providers=tuple(values.get("providers") or ()),
            abstract_or_excerpt=values.get("abstract_or_excerpt", ""),
            source_id=values.get("source_id", ""),
            identifiers=values.get("identifiers") or {},
            authors=tuple(values.get("authors") or ()),
            publication_date=values.get("publication_date"),
            landing_url=values.get("landing_url"),
            license=values.get("license"),
            status=values.get("status", SourceStatus.UNKNOWN.value),
            retrievals=tuple(
                item if isinstance(item, RetrievalRecord) else RetrievalRecord.from_dict(item)
                for item in raw_retrievals
            ),
            content_hash=values.get("content_hash", ""),
        )


@dataclass(frozen=True, slots=True)
class EvidenceRecord(JSONRecord):
    source_id: str
    passage: str
    locator: str
    relevance: float
    stance: EvidenceStance
    created_by_step: str
    license: str | None = None
    content_hash: str = ""
    evidence_id: str = ""

    def __post_init__(self) -> None:
        object.__setattr__(self, "source_id", _name(self.source_id, "source_id"))
        object.__setattr__(self, "passage", _non_empty(self.passage, "passage", maximum=100_000))
        object.__setattr__(self, "locator", _non_empty(self.locator, "locator", maximum=10_000))
        object.__setattr__(self, "relevance", _score(self.relevance, "relevance"))
        object.__setattr__(self, "stance", _enum(EvidenceStance, self.stance, "stance"))
        object.__setattr__(
            self,
            "created_by_step",
            _name(self.created_by_step, "created_by_step"),
        )
        object.__setattr__(self, "license", _optional_text(self.license, "license", maximum=1_000))
        calculated_hash = sha256_text(self.passage)
        if self.content_hash and _sha256(self.content_hash, "content_hash") != calculated_hash:
            raise ValidationError("content_hash does not match the evidence passage")
        object.__setattr__(self, "content_hash", calculated_hash)
        calculated_id = stable_id(
            "evidence",
            {
                "source_id": self.source_id,
                "content_hash": self.content_hash,
                "locator": self.locator,
            },
        )
        if self.evidence_id and _name(self.evidence_id, "evidence_id") != calculated_id:
            raise ValidationError("evidence_id does not match evidence content")
        object.__setattr__(self, "evidence_id", calculated_id)

    def to_dict(self) -> dict[str, JSONValue]:
        return {
            "evidence_id": self.evidence_id,
            "source_id": self.source_id,
            "passage": self.passage,
            "locator": self.locator,
            "relevance": self.relevance,
            "stance": self.stance.value,
            "license": self.license,
            "content_hash": self.content_hash,
            "created_by_step": self.created_by_step,
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> EvidenceRecord:
        values = _dict_input(data, cls.__name__)
        return cls(
            source_id=values.get("source_id", ""),
            passage=values.get("passage", ""),
            locator=values.get("locator", ""),
            relevance=values.get("relevance", -1),
            stance=values.get("stance", ""),
            created_by_step=values.get("created_by_step", ""),
            license=values.get("license"),
            content_hash=values.get("content_hash", ""),
            evidence_id=values.get("evidence_id", ""),
        )


@dataclass(frozen=True, slots=True)
class Claim(JSONRecord):
    text: str
    kind: ClaimKind
    evidence_ids: tuple[str, ...] = ()
    confidence: float | None = None
    limitations: tuple[str, ...] = ()
    created_by: str = "unknown"
    claim_id: str = ""

    def __post_init__(self) -> None:
        object.__setattr__(self, "text", _non_empty(self.text, "text", maximum=100_000))
        object.__setattr__(self, "kind", _enum(ClaimKind, self.kind, "kind"))
        evidence_ids = _strings(
            self.evidence_ids,
            "evidence_ids",
            maximum_items=10_000,
            item_maximum=255,
            unique=True,
        )
        if self.kind is ClaimKind.SOURCED_FACT and not evidence_ids:
            raise ValidationError("a sourced_fact claim requires supporting evidence IDs")
        object.__setattr__(self, "evidence_ids", evidence_ids)
        if self.confidence is not None:
            object.__setattr__(self, "confidence", _score(self.confidence, "confidence"))
        object.__setattr__(
            self,
            "limitations",
            _strings(self.limitations, "limitations", maximum_items=1_000),
        )
        object.__setattr__(
            self, "created_by", _non_empty(self.created_by, "created_by", maximum=1_000)
        )
        calculated_id = stable_id(
            "claim",
            {
                "text": self.text,
                "kind": self.kind.value,
                "evidence_ids": list(self.evidence_ids),
                "created_by": self.created_by,
            },
        )
        if self.claim_id and _name(self.claim_id, "claim_id") != calculated_id:
            raise ValidationError("claim_id does not match claim content")
        object.__setattr__(self, "claim_id", calculated_id)

    def to_dict(self) -> dict[str, JSONValue]:
        return {
            "claim_id": self.claim_id,
            "text": self.text,
            "kind": self.kind.value,
            "evidence_ids": list(self.evidence_ids),
            "confidence": self.confidence,
            "limitations": list(self.limitations),
            "created_by": self.created_by,
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> Claim:
        values = _dict_input(data, cls.__name__)
        return cls(
            text=values.get("text", ""),
            kind=values.get("kind", ""),
            evidence_ids=tuple(values.get("evidence_ids") or ()),
            confidence=values.get("confidence"),
            limitations=tuple(values.get("limitations") or ()),
            created_by=values.get("created_by", "unknown"),
            claim_id=values.get("claim_id", ""),
        )


@dataclass(frozen=True, slots=True)
class PolicyDecision(JSONRecord):
    capability: str
    action: str
    target: str
    risk: RiskLevel
    outcome: PolicyOutcome
    reason: str
    decision_id: str = ""
    decided_at: str = field(default_factory=utc_now)

    def __post_init__(self) -> None:
        object.__setattr__(self, "capability", _name(self.capability, "capability"))
        object.__setattr__(self, "action", _non_empty(self.action, "action", maximum=1_000))
        if not isinstance(self.target, str) or len(self.target) > 32_768:
            raise ValidationError("target must be a string of at most 32768 characters")
        object.__setattr__(self, "risk", _enum(RiskLevel, self.risk, "risk"))
        object.__setattr__(self, "outcome", _enum(PolicyOutcome, self.outcome, "outcome"))
        object.__setattr__(self, "reason", _non_empty(self.reason, "reason", maximum=10_000))
        object.__setattr__(
            self,
            "decided_at",
            normalize_timestamp(self.decided_at, field_name="decided_at"),
        )
        if self.decision_id:
            object.__setattr__(self, "decision_id", _name(self.decision_id, "decision_id"))
        else:
            object.__setattr__(
                self,
                "decision_id",
                stable_id(
                    "decision",
                    {
                        "capability": self.capability,
                        "action": self.action,
                        "target": self.target,
                        "risk": self.risk.value,
                        "outcome": self.outcome.value,
                        "reason": self.reason,
                        "decided_at": self.decided_at,
                    },
                ),
            )

    def to_dict(self) -> dict[str, JSONValue]:
        return {
            "decision_id": self.decision_id,
            "capability": self.capability,
            "action": self.action,
            "target": self.target,
            "risk": self.risk.value,
            "outcome": self.outcome.value,
            "reason": self.reason,
            "decided_at": self.decided_at,
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> PolicyDecision:
        values = _dict_input(data, cls.__name__)
        return cls(
            capability=values.get("capability", ""),
            action=values.get("action", ""),
            target=values.get("target", ""),
            risk=values.get("risk", ""),
            outcome=values.get("outcome", ""),
            reason=values.get("reason", ""),
            decision_id=values.get("decision_id", ""),
            decided_at=values.get("decided_at", utc_now()),
        )


@dataclass(frozen=True, slots=True)
class ArtifactRecord(JSONRecord):
    name: str
    media_type: str
    sha256: str
    size: int
    object_path: str
    produced_by_step: str
    input_ids: tuple[str, ...] = ()
    created_at: str = field(default_factory=utc_now)
    export_path: str | None = None
    artifact_id: str = ""

    def __post_init__(self) -> None:
        name = _non_empty(self.name, "name", maximum=1_000)
        if Path(name).name != name:
            raise ValidationError("artifact name must be a plain filename")
        object.__setattr__(self, "name", name)
        object.__setattr__(
            self, "media_type", _non_empty(self.media_type, "media_type", maximum=255)
        )
        object.__setattr__(self, "sha256", _sha256(self.sha256, "sha256"))
        if isinstance(self.size, bool) or not isinstance(self.size, int) or self.size < 0:
            raise ValidationError("size must be a non-negative integer")
        object.__setattr__(
            self, "object_path", _non_empty(self.object_path, "object_path", maximum=32_768)
        )
        object.__setattr__(
            self,
            "produced_by_step",
            _name(self.produced_by_step, "produced_by_step"),
        )
        object.__setattr__(
            self,
            "input_ids",
            _strings(
                self.input_ids, "input_ids", maximum_items=100_000, item_maximum=255, unique=True
            ),
        )
        object.__setattr__(
            self, "created_at", normalize_timestamp(self.created_at, field_name="created_at")
        )
        object.__setattr__(
            self, "export_path", _optional_text(self.export_path, "export_path", maximum=32_768)
        )
        calculated_id = stable_id(
            "artifact",
            {"name": self.name, "sha256": self.sha256, "produced_by_step": self.produced_by_step},
        )
        if self.artifact_id and _name(self.artifact_id, "artifact_id") != calculated_id:
            raise ValidationError("artifact_id does not match artifact content")
        object.__setattr__(self, "artifact_id", calculated_id)

    def to_dict(self) -> dict[str, JSONValue]:
        return {
            "artifact_id": self.artifact_id,
            "name": self.name,
            "media_type": self.media_type,
            "sha256": self.sha256,
            "size": self.size,
            "object_path": self.object_path,
            "produced_by_step": self.produced_by_step,
            "input_ids": list(self.input_ids),
            "created_at": self.created_at,
            "export_path": self.export_path,
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> ArtifactRecord:
        values = _dict_input(data, cls.__name__)
        return cls(
            name=values.get("name", ""),
            media_type=values.get("media_type", ""),
            sha256=values.get("sha256", ""),
            size=values.get("size", -1),
            object_path=values.get("object_path", ""),
            produced_by_step=values.get("produced_by_step", ""),
            input_ids=tuple(values.get("input_ids") or ()),
            created_at=values.get("created_at", utc_now()),
            export_path=values.get("export_path"),
            artifact_id=values.get("artifact_id", ""),
        )


# Short public name mirrors the entity name used by the specification.
Artifact = ArtifactRecord


class AuthorizationCallback(Protocol):
    def __call__(
        self,
        descriptor: CapabilityDescriptor,
        action: str,
        *,
        target: str = "",
        risk: RiskLevel | None = None,
    ) -> PolicyDecision: ...


class EventCallback(Protocol):
    def __call__(self, event_type: str, payload: Mapping[str, Any]) -> None: ...


class NetworkConsumeCallback(Protocol):
    """Atomically consume one governed network request and return the remaining budget."""

    def __call__(self, target: str) -> int: ...


def _never_cancelled() -> bool:
    return False


def _ignore_event(_event_type: str, _payload: Mapping[str, Any]) -> None:
    return None


@dataclass(frozen=True, slots=True)
class ToolContext:
    deadline: datetime
    remaining_network_requests: int
    authorize: AuthorizationCallback
    user_agent: str
    emit: EventCallback = cast(EventCallback, _ignore_event)
    is_cancelled: Callable[[], bool] = _never_cancelled
    network_consumer: NetworkConsumeCallback | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.deadline, datetime):
            raise ValidationError("deadline must be a datetime")
        if self.deadline.tzinfo is None or self.deadline.utcoffset() is None:
            raise ValidationError("deadline must include a timezone")
        object.__setattr__(self, "deadline", self.deadline.astimezone(UTC))
        if (
            isinstance(self.remaining_network_requests, bool)
            or not isinstance(self.remaining_network_requests, int)
            or self.remaining_network_requests < 0
        ):
            raise ValidationError("remaining_network_requests must be a non-negative integer")
        if not callable(self.authorize):
            raise ValidationError("authorize must be callable")
        object.__setattr__(
            self, "user_agent", _non_empty(self.user_agent, "user_agent", maximum=1_000)
        )
        if not callable(self.emit) or not callable(self.is_cancelled):
            raise ValidationError("emit and is_cancelled must be callable")
        if self.network_consumer is not None and not callable(self.network_consumer):
            raise ValidationError("network_consumer must be callable")

    def require_active(self) -> None:
        if self.is_cancelled():
            raise RunCancelledError("provider operation was cancelled")
        if datetime.now(UTC) >= self.deadline:
            raise LimitExceededError("provider operation deadline was exceeded")

    def require_network_budget(self) -> None:
        self.require_active()
        if self.remaining_network_requests <= 0:
            raise LimitExceededError("network request budget is exhausted")

    def consume_network_request(self, target: str) -> int:
        """Consume one request immediately before transport I/O.

        Application contexts provide an atomic shared consumer. Standalone provider tests and
        extensions that omit it still receive the immutable one-call budget guard.
        """

        self.require_network_budget()
        if self.network_consumer is None:
            return self.remaining_network_requests - 1
        remaining = self.network_consumer(_non_empty(target, "network target", maximum=32_768))
        if isinstance(remaining, bool) or not isinstance(remaining, int) or remaining < 0:
            raise ValidationError("network_consumer must return a non-negative integer")
        return remaining

    def require_authorized(
        self,
        descriptor: CapabilityDescriptor,
        action: str,
        *,
        target: str = "",
        risk: RiskLevel | None = None,
    ) -> PolicyDecision:
        self.require_active()
        decision = self.authorize(descriptor, action, target=target, risk=risk)
        if decision.outcome is PolicyOutcome.DENY:
            raise PolicyDeniedError(
                decision.reason,
                context={"capability": descriptor.name, "action": action},
            )
        if decision.outcome is PolicyOutcome.APPROVAL_REQUIRED:
            raise ApprovalRequiredError(
                decision.reason,
                context={"capability": descriptor.name, "action": action},
            )
        return decision

    def emit_event(self, event_type: str, payload: Mapping[str, Any]) -> None:
        self.emit(_non_empty(event_type, "event_type", maximum=1_000), payload)


__all__ = [
    "Artifact",
    "ArtifactRecord",
    "AuthorizationCallback",
    "CapabilityDescriptor",
    "CapabilityKind",
    "Claim",
    "ClaimKind",
    "EvidenceRecord",
    "EvidenceStance",
    "EventCallback",
    "JSONScalar",
    "JSONValue",
    "NetworkConsumeCallback",
    "PlanStatus",
    "PlanStep",
    "PlanStepStatus",
    "PolicyDecision",
    "PolicyOutcome",
    "ResearchPlan",
    "ResearchRequest",
    "RetrievalRecord",
    "RiskLevel",
    "RunLimits",
    "RunStatus",
    "SearchRequest",
    "SourceCandidate",
    "SourceRecord",
    "SourceStatus",
    "StepStatus",
    "ToolContext",
    "canonical_json",
    "format_datetime",
    "normalize_timestamp",
    "parse_datetime",
    "sha256_bytes",
    "sha256_json",
    "sha256_text",
    "stable_id",
    "utc_now",
]
