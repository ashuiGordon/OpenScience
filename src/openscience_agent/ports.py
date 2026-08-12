"""Typed ports at every side-effect boundary of the research kernel."""

from __future__ import annotations

from collections.abc import Callable, Iterable, Mapping, Sequence
from pathlib import Path
from typing import Any, Protocol, runtime_checkable

from .domain import (
    ArtifactRecord,
    CapabilityDescriptor,
    Claim,
    EvidenceRecord,
    PolicyDecision,
    ResearchRequest,
    RiskLevel,
    SearchRequest,
    SourceCandidate,
    SourceRecord,
    ToolContext,
)


@runtime_checkable
class SourceProvider(Protocol):
    """Discover provider-specific candidates without owning orchestration state."""

    def descriptor(self) -> CapabilityDescriptor: ...

    def search(self, request: SearchRequest, context: ToolContext) -> list[SourceCandidate]: ...


@runtime_checkable
class SynthesisProvider(Protocol):
    """Create typed candidate claims from explicitly delimited evidence."""

    def descriptor(self) -> CapabilityDescriptor: ...

    def synthesize(
        self,
        request: ResearchRequest,
        sources: Sequence[SourceRecord] | Sequence[Mapping[str, Any]],
        evidence: Sequence[EvidenceRecord] | Sequence[Mapping[str, Any]],
        context: ToolContext,
    ) -> list[Claim]: ...


@runtime_checkable
class PolicyPort(Protocol):
    """Authorize one concrete action immediately before invocation."""

    def evaluate(
        self,
        descriptor: CapabilityDescriptor,
        action: str,
        *,
        target: str = "",
        risk: RiskLevel | None = None,
    ) -> PolicyDecision: ...


@runtime_checkable
class Clock(Protocol):
    """Injectable clock for deterministic planning and persistence tests."""

    def now(self) -> str: ...


@runtime_checkable
class EventSink(Protocol):
    """Append redacted activity before a state transition is reported complete."""

    def append_event(
        self,
        event_type: str,
        payload: Mapping[str, Any] | None = None,
        *,
        timestamp: str,
        step_id: str | None = None,
        event_id: str | None = None,
    ) -> Mapping[str, Any]: ...


@runtime_checkable
class RunRepository(Protocol):
    """Persist requests, plans, projections, checkpoints, and immutable events."""

    @property
    def run_directory(self) -> Path: ...

    def write_json(self, relative_name: str, value: Any) -> Path: ...

    def read_json(self, relative_name: str) -> Any: ...

    def write_text(self, relative_name: str, content: str) -> Path: ...

    def append_event(
        self,
        event_type: str,
        payload: Mapping[str, Any] | None = None,
        *,
        timestamp: str,
        step_id: str | None = None,
        event_id: str | None = None,
    ) -> Mapping[str, Any]: ...

    def read_events(self) -> list[dict[str, Any]]: ...

    def verify_event_chain(self) -> list[str]: ...

    def add_artifact(
        self,
        *,
        name: str,
        content: bytes,
        media_type: str,
        produced_by_step: str,
        input_ids: Iterable[str] = (),
    ) -> dict[str, Any]: ...

    def projection_index(self, relative_name: str, *, count: int) -> dict[str, Any]: ...


@runtime_checkable
class RunRepositoryFactory(Protocol):
    """Construct or reopen the application-owned repository adapter."""

    def create(
        self,
        workspace: Path,
        run_id: str,
        *,
        redactor: Callable[[Any], Any] | None = None,
    ) -> RunRepository: ...

    def open(
        self,
        run_directory: Path,
        *,
        redactor: Callable[[Any], Any] | None = None,
    ) -> RunRepository: ...


@runtime_checkable
class ArtifactStore(Protocol):
    """Store immutable content-addressed bytes and return their provenance record."""

    def put(
        self,
        *,
        name: str,
        content: bytes,
        media_type: str,
        produced_by_step: str,
        input_ids: Sequence[str] = (),
    ) -> ArtifactRecord: ...

    def read(self, artifact: ArtifactRecord) -> bytes: ...


@runtime_checkable
class RunValidator(Protocol):
    """Validate a recorded run without contacting providers."""

    def __call__(self, run_directory: Path) -> ValidationOutcome: ...


@runtime_checkable
class ValidationOutcome(Protocol):
    """Small shared result surface for scientific and persisted-run validators."""

    @property
    def valid(self) -> bool: ...

    @property
    def errors(self) -> tuple[Any, ...]: ...

    @property
    def warnings(self) -> tuple[Any, ...]: ...


@runtime_checkable
class ClaimValidator(Protocol):
    """Audit candidate claims against the run's normalized evidence and sources."""

    def __call__(
        self,
        claims: list[Any],
        evidence: list[Any],
        sources: list[Any],
    ) -> ValidationOutcome: ...


@runtime_checkable
class ReportRenderer(Protocol):
    """Render a human-facing report without owning persistence or orchestration state."""

    def __call__(
        self,
        *,
        request: Any,
        sources: list[Any],
        evidence: list[Any],
        claims: list[Any],
        limitations: list[str],
        status: str,
        run_id: str,
    ) -> str: ...


# Concise compatibility aliases used by architecture documents and third-party extensions.
EventPort = EventSink
Policy = PolicyPort
Repository = RunRepository
Validator = RunValidator


__all__ = [
    "ArtifactStore",
    "ClaimValidator",
    "Clock",
    "EventPort",
    "EventSink",
    "Policy",
    "PolicyPort",
    "Repository",
    "ReportRenderer",
    "RunRepository",
    "RunRepositoryFactory",
    "RunValidator",
    "SourceProvider",
    "SynthesisProvider",
    "ValidationOutcome",
    "Validator",
]
