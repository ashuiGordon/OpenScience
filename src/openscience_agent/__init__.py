"""Stable public API for the OpenScience research-agent core."""

from __future__ import annotations

from importlib.metadata import PackageNotFoundError, version

from .domain import (
    Artifact,
    ArtifactRecord,
    CapabilityDescriptor,
    CapabilityKind,
    Claim,
    ClaimKind,
    EvidenceRecord,
    EvidenceStance,
    PlanStatus,
    PlanStep,
    PolicyDecision,
    PolicyOutcome,
    ResearchPlan,
    ResearchRequest,
    RetrievalRecord,
    RiskLevel,
    RunLimits,
    RunStatus,
    SearchRequest,
    SourceCandidate,
    SourceRecord,
    SourceStatus,
    ToolContext,
    canonical_json,
    sha256_json,
    stable_id,
    utc_now,
)
from .errors import (
    ApprovalRequiredError,
    ConfigurationError,
    IntegrityError,
    LimitExceededError,
    OpenScienceError,
    PathBoundaryError,
    PersistenceError,
    PolicyDeniedError,
    ProviderError,
    ProviderRegistrationError,
    ValidationError,
)
from .policy import PolicyEngine, redact_secrets, resolve_approved_path
from .ports import SourceProvider, SynthesisProvider
from .registry import ProviderRegistry

try:
    __version__ = version("openscience-agent")
except PackageNotFoundError:
    __version__ = "0.1.0"

__all__ = [
    "ApprovalRequiredError",
    "Artifact",
    "ArtifactRecord",
    "CapabilityDescriptor",
    "CapabilityKind",
    "Claim",
    "ClaimKind",
    "ConfigurationError",
    "EvidenceRecord",
    "EvidenceStance",
    "IntegrityError",
    "LimitExceededError",
    "OpenScienceError",
    "PathBoundaryError",
    "PersistenceError",
    "PlanStatus",
    "PlanStep",
    "PolicyDecision",
    "PolicyDeniedError",
    "PolicyEngine",
    "PolicyOutcome",
    "ProviderError",
    "ProviderRegistrationError",
    "ProviderRegistry",
    "ResearchPlan",
    "ResearchRequest",
    "RetrievalRecord",
    "RiskLevel",
    "RunLimits",
    "RunStatus",
    "SearchRequest",
    "SourceCandidate",
    "SourceProvider",
    "SourceRecord",
    "SourceStatus",
    "SynthesisProvider",
    "ToolContext",
    "ValidationError",
    "__version__",
    "canonical_json",
    "redact_secrets",
    "resolve_approved_path",
    "sha256_json",
    "stable_id",
    "utc_now",
]
