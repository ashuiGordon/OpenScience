"""Application-owned research planning and execution state machine."""

from __future__ import annotations

import platform
import sys
import threading
import uuid
from collections.abc import Callable, Mapping
from dataclasses import asdict, dataclass, field, is_dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, cast

from .domain import (
    CapabilityDescriptor,
    Claim,
    PlanStatus,
    PlanStep,
    PolicyDecision,
    PolicyOutcome,
    ResearchPlan,
    ResearchRequest,
    RunStatus,
    SearchRequest,
    ToolContext,
    sha256_json,
    utc_now,
)
from .errors import (
    ConfigurationError,
    IntegrityError,
    LimitExceededError,
    ProviderError,
    RunCancelledError,
)
from .evidence import extract_evidence, merge_source_candidates
from .policy import redact_secrets, redact_text
from .ports import (
    ClaimValidator,
    PolicyPort,
    ReportRenderer,
    RunRepository,
    RunRepositoryFactory,
    RunValidator,
    ValidationOutcome,
)
from .registry import ProviderRegistry


@dataclass(frozen=True, slots=True)
class RunOutcome:
    run_id: str
    run_directory: Path
    status: RunStatus
    report_path: Path | None
    manifest_path: Path
    source_count: int
    evidence_count: int
    claim_count: int
    limitations: tuple[str, ...] = ()

    def to_dict(self) -> dict[str, Any]:
        return {
            "run_id": self.run_id,
            "run_directory": str(self.run_directory),
            "status": self.status.value,
            "report": str(self.report_path) if self.report_path else None,
            "manifest": str(self.manifest_path),
            "sources": self.source_count,
            "evidence": self.evidence_count,
            "claims": self.claim_count,
            "limitations": list(self.limitations),
        }


@dataclass(slots=True)
class _NetworkBudget:
    """One application-owned, thread-safe budget shared by every provider in an attempt."""

    total: int
    used: int
    deadline: datetime
    store: RunRepository
    is_cancelled: Callable[[], bool]
    _lock: threading.Lock = field(default_factory=threading.Lock)

    @property
    def remaining(self) -> int:
        return max(0, self.total - self.used)

    def consume(self, target: str, *, step_id: str, provider: str) -> int:
        with self._lock:
            if self.is_cancelled():
                raise RunCancelledError("research run was cancelled")
            if datetime.now(UTC) >= self.deadline:
                raise LimitExceededError("run timeout exceeded before a network request")
            if self.used >= self.total:
                raise LimitExceededError("network request budget is exhausted")
            self.used += 1
            remaining = self.remaining
            self.store.append_event(
                "network.request_consumed",
                {
                    "target": redact_text(target),
                    "provider": provider,
                    "used": self.used,
                    "remaining": remaining,
                    "limit": self.total,
                },
                timestamp=utc_now(),
                step_id=step_id,
            )
            return remaining


class ResearchOrchestrator:
    """Execute a finite evidence-first workflow through declared provider and storage ports."""

    STEP_IDS = ("discover", "extract", "synthesize", "validate", "report")
    STEP_CAPABILITIES = {
        "discover": "research.sources",
        "extract": "research.evidence.extract",
        "synthesize": "research.synthesis",
        "validate": "research.validation",
        "report": "research.export",
    }
    STEP_DEPENDENCIES = {
        "discover": (),
        "extract": ("discover",),
        "synthesize": ("extract",),
        "validate": ("synthesize",),
        "report": ("validate",),
    }

    def __init__(
        self,
        *,
        registry: ProviderRegistry,
        policy: PolicyPort,
        store_factory: RunRepositoryFactory,
        run_validator: RunValidator,
        claim_validator: ClaimValidator,
        report_renderer: ReportRenderer,
        software_version: str = "0.1.0",
        is_cancelled: Callable[[], bool] | None = None,
    ) -> None:
        self.registry = registry
        self.policy = policy
        self.store_factory = store_factory
        self.run_validator = run_validator
        self.claim_validator = claim_validator
        self.report_renderer = report_renderer
        self.software_version = software_version
        self.is_cancelled = is_cancelled or (lambda: False)

    def create_plan(self, request: ResearchRequest) -> ResearchPlan:
        if request.limits.max_steps < len(self.STEP_IDS):
            raise LimitExceededError(
                f"max_steps={request.limits.max_steps} cannot run the required "
                f"{len(self.STEP_IDS)}-step workflow"
            )
        return ResearchPlan(
            steps=(
                PlanStep(
                    step_id="discover",
                    title="Discover and normalize sources",
                    purpose="Search only enabled providers and merge stable scholarly identities.",
                    capability=self.STEP_CAPABILITIES["discover"],
                    completion_condition="Provider outcomes and normalized source records are persisted.",
                ),
                PlanStep(
                    step_id="extract",
                    title="Extract source-bound evidence",
                    purpose="Select relevant passages without interpreting them as instructions.",
                    capability=self.STEP_CAPABILITIES["extract"],
                    dependencies=("discover",),
                    completion_condition="Every evidence record has a source and locator.",
                ),
                PlanStep(
                    step_id="synthesize",
                    title="Create typed candidate claims",
                    purpose="Produce claims that cite only evidence from this run.",
                    capability=self.STEP_CAPABILITIES["synthesize"],
                    dependencies=("extract",),
                    completion_condition="Candidate claims conform to the claim contract.",
                ),
                PlanStep(
                    step_id="validate",
                    title="Audit evidence and claims",
                    purpose="Reject fabricated links and expose retractions, conflicts, and gaps.",
                    capability=self.STEP_CAPABILITIES["validate"],
                    dependencies=("synthesize",),
                    completion_condition="Scientific and integrity validators have no errors.",
                ),
                PlanStep(
                    step_id="report",
                    title="Render report and manifest",
                    purpose="Publish human-readable findings with machine-readable provenance.",
                    capability=self.STEP_CAPABILITIES["report"],
                    dependencies=("validate",),
                    completion_condition="Report artifact and run manifest are persisted.",
                ),
            )
        )

    def execute(
        self,
        request: ResearchRequest,
        *,
        workspace: Path,
        source_names: tuple[str, ...] | None = None,
        synthesizer_name: str = "extractive",
        plan: ResearchPlan | None = None,
        approved: bool = False,
        resume_directory: Path | None = None,
        stop_after_step: str | None = None,
    ) -> RunOutcome:
        request = _safe_request(request)
        selected_sources = tuple(source_names or request.source_names)
        if not selected_sources:
            raise ConfigurationError("at least one source provider is required")
        if stop_after_step is not None and stop_after_step not in self.STEP_IDS:
            raise ConfigurationError(f"unknown stop_after_step: {stop_after_step}")

        capabilities = self._capabilities(selected_sources, synthesizer_name)
        capability_identities = [_capability_identity(item) for item in capabilities]

        if resume_directory is None:
            run_id = _new_run_id()
            active_plan = _safe_plan(plan or self.create_plan(request))
            self._validate_plan(active_plan)
            store = self.store_factory.create(workspace, run_id, redactor=redact_secrets)
            completed_steps: list[str] = []
            network_requests_used = 0
            self._initialize_store(store, request, active_plan)
            self._write_checkpoint(
                store,
                completed_steps,
                RunStatus.CREATED,
                selected_sources,
                synthesizer_name,
                capability_identities,
                network_requests_used,
            )
            store.append_event(
                "run.created",
                {
                    "request_id": request.request_id,
                    "request_hash": sha256_json(request.to_dict()),
                    "plan_id": active_plan.plan_id,
                    "plan_hash": sha256_json(active_plan.to_dict()),
                    "source_names": list(selected_sources),
                    "synthesizer": synthesizer_name,
                    "capabilities": capability_identities,
                },
                timestamp=utc_now(),
            )
        else:
            integrity = self.run_validator(resume_directory)
            if not integrity.valid:
                raise IntegrityError(
                    "cannot resume an invalid run: " + _validation_messages(integrity)
                )
            store = self.store_factory.open(resume_directory, redactor=redact_secrets)
            stored_request = ResearchRequest.from_dict(store.read_json("request.json"))
            if stored_request.request_id != request.request_id:
                raise ConfigurationError("resume request does not match the recorded request")
            request = stored_request
            active_plan = ResearchPlan.from_dict(store.read_json("plan.json"))
            self._validate_plan(active_plan)
            checkpoint = _dict(store.read_json("checkpoint.json"), "checkpoint")
            completed_steps = _completed_prefix(checkpoint, self.STEP_IDS)
            expected_sources = tuple(checkpoint.get("source_names", []))
            if expected_sources != selected_sources:
                raise ConfigurationError(
                    "resume providers do not match the recorded provider selection: "
                    f"expected {expected_sources}, received {selected_sources}"
                )
            if checkpoint.get("synthesizer") != synthesizer_name:
                raise ConfigurationError("resume synthesizer does not match the recorded run")
            if checkpoint.get("capabilities") != capability_identities:
                raise ConfigurationError(
                    "resume provider versions or contract identities do not match the recorded run"
                )
            network_requests_used = _nonnegative(
                checkpoint.get("network_requests_used", 0), "network_requests_used"
            )
            run_id = store.run_directory.name
            store.append_event(
                "run.resumed",
                {
                    "completed_steps": completed_steps,
                    "request_hash": sha256_json(request.to_dict()),
                    "plan_hash": sha256_json(active_plan.to_dict()),
                    "network_requests_used": network_requests_used,
                },
                timestamp=utc_now(),
            )

        checkpoint = _dict(store.read_json("checkpoint.json"), "checkpoint")
        completed_steps = _completed_prefix(checkpoint, self.STEP_IDS)
        sources = _list(store.read_json("sources.json"), "sources")
        evidence = _list(store.read_json("evidence.json"), "evidence")
        claims = _list(store.read_json("claims.json"), "claims")
        decisions = _list(store.read_json("policy_decisions.json"), "policy decisions")
        artifacts: list[dict[str, Any]] = []
        previous_manifest = store.run_directory / "manifest.json"
        if previous_manifest.exists():
            artifacts = list(
                _dict(store.read_json("manifest.json"), "manifest").get("artifacts", [])
            )
        limitations: list[str] = list(
            _dict(store.read_json("manifest.json"), "manifest").get("limitations", [])
            if previous_manifest.exists()
            else []
        )
        if resume_directory is not None:
            limitations = [
                item
                for item in limitations
                if not item.startswith("Run intentionally interrupted after step ")
            ]
        errors: list[dict[str, Any]] = []

        if not approved:
            store.append_event(
                "run.awaiting_approval",
                {"plan_id": active_plan.plan_id, "plan_hash": sha256_json(active_plan.to_dict())},
                timestamp=utc_now(),
            )
            self._write_checkpoint(
                store,
                completed_steps,
                RunStatus.AWAITING_APPROVAL,
                selected_sources,
                synthesizer_name,
                capability_identities,
                network_requests_used,
            )
            self._write_manifest(
                store=store,
                request=request,
                plan=active_plan,
                status=RunStatus.AWAITING_APPROVAL,
                capabilities=capabilities,
                sources=sources,
                evidence=evidence,
                claims=claims,
                decisions=decisions,
                artifacts=artifacts,
                limitations=limitations,
                errors=errors,
            )
            self._require_valid(store, "awaiting-approval run")
            return self._outcome(
                store, RunStatus.AWAITING_APPROVAL, sources, evidence, claims, limitations
            )

        deadline = datetime.now(UTC) + timedelta(seconds=request.limits.timeout_seconds)
        network_budget = _NetworkBudget(
            total=request.limits.max_network_requests,
            used=network_requests_used,
            deadline=deadline,
            store=store,
            is_cancelled=lambda: self.is_cancelled() or _cancel_marker_exists(store),
        )
        store.append_event(
            "run.started",
            {
                "deadline": deadline.isoformat().replace("+00:00", "Z"),
                "network_requests_remaining": network_budget.remaining,
            },
            timestamp=utc_now(),
        )

        active_step_id: str | None = None
        try:
            for step_id in self.STEP_IDS:
                if step_id in completed_steps:
                    continue
                self._require_active(deadline, store)
                step = next(item for item in active_plan.steps if item.step_id == step_id)
                active_step_id = step_id
                store.append_event(
                    "step.started",
                    {
                        "capability": step.capability,
                        "dependencies": list(step.dependencies),
                        "input_hashes": self._step_input_hashes(store, step_id),
                    },
                    timestamp=utc_now(),
                    step_id=step_id,
                )
                if step_id == "discover":
                    candidates: list[Any] = []
                    per_provider_limit = max(
                        1,
                        (request.limits.max_records + len(selected_sources) - 1)
                        // len(selected_sources),
                    )
                    for name in selected_sources:
                        self._require_active(deadline, store)
                        provider = self.registry.get_source(name)
                        descriptor = _descriptor(provider)
                        decision = self._record_decision(
                            store, decisions, descriptor, "select", name, step_id
                        )
                        if decision.outcome is not PolicyOutcome.ALLOW:
                            _add_limitation(
                                limitations,
                                f"Source {name} was not called: policy outcome "
                                f"{decision.outcome.value} ({decision.reason}).",
                            )
                            continue
                        search_request = SearchRequest(
                            query=request.question, limit=per_provider_limit
                        )
                        store.append_event(
                            "provider.started",
                            {
                                "provider": name,
                                "descriptor": _capability_identity(descriptor),
                                "input": search_request.to_dict(),
                                "input_hash": sha256_json(search_request.to_dict()),
                            },
                            timestamp=utc_now(),
                            step_id=step_id,
                        )
                        context = self._tool_context(
                            deadline=deadline,
                            network_budget=network_budget,
                            store=store,
                            step_id=step_id,
                            decisions=decisions,
                            limitations=limitations,
                            provider_name=name,
                        )
                        try:
                            found = provider.search(search_request, context)
                            safe_found = [_safe_mapping(item) for item in found]
                            candidates.extend(safe_found)
                            store.append_event(
                                "provider.completed",
                                {
                                    "provider": name,
                                    "records": len(safe_found),
                                    "output_ids": [
                                        f"{item.get('provider', name)}:{item.get('provider_id', '')}"
                                        for item in safe_found
                                    ],
                                    "output_hash": sha256_json(safe_found),
                                },
                                timestamp=utc_now(),
                                step_id=step_id,
                            )
                        except RunCancelledError:
                            raise
                        except Exception as error:
                            message = redact_text(str(error))
                            _add_limitation(
                                limitations,
                                f"Source {name} failed: {type(error).__name__}: {message}",
                            )
                            store.append_event(
                                "provider.failed",
                                {
                                    "provider": name,
                                    "error_type": type(error).__name__,
                                    "message": message,
                                },
                                timestamp=utc_now(),
                                step_id=step_id,
                            )
                    sources = [item.to_dict() for item in merge_source_candidates(candidates)][
                        : request.limits.max_records
                    ]
                    store.write_json("sources.json", sources)
                elif step_id == "extract":
                    evidence = [
                        item.to_dict()
                        for item in extract_evidence(
                            request.question, sources, created_by_step="extract"
                        )
                    ]
                    store.write_json("evidence.json", evidence)
                    if not evidence:
                        _add_limitation(limitations, "No source-bound evidence could be extracted.")
                elif step_id == "synthesize":
                    synthesizer = self.registry.get_synthesizer(synthesizer_name)
                    descriptor = _descriptor(synthesizer)
                    decision = self._record_decision(
                        store, decisions, descriptor, "select", synthesizer_name, step_id
                    )
                    if decision.outcome is not PolicyOutcome.ALLOW:
                        _add_limitation(
                            limitations,
                            f"Synthesis {synthesizer_name} blocked by policy: {decision.reason}.",
                        )
                        claims = []
                    else:
                        synthesis_input = {
                            "request_hash": sha256_json(request.to_dict()),
                            "source_ids": [item.get("source_id") for item in sources],
                            "evidence_ids": [item.get("evidence_id") for item in evidence],
                        }
                        store.append_event(
                            "provider.started",
                            {
                                "provider": synthesizer_name,
                                "descriptor": _capability_identity(descriptor),
                                "input": synthesis_input,
                                "input_hash": sha256_json(synthesis_input),
                            },
                            timestamp=utc_now(),
                            step_id=step_id,
                        )
                        context = self._tool_context(
                            deadline=deadline,
                            network_budget=network_budget,
                            store=store,
                            step_id=step_id,
                            decisions=decisions,
                            limitations=limitations,
                            provider_name=synthesizer_name,
                        )
                        generated = synthesizer.synthesize(request, sources, evidence, context)
                        claims = [_safe_claim(item) for item in generated]
                        store.append_event(
                            "provider.completed",
                            {
                                "provider": synthesizer_name,
                                "records": len(claims),
                                "output_ids": [item.get("claim_id") for item in claims],
                                "output_hash": sha256_json(claims),
                            },
                            timestamp=utc_now(),
                            step_id=step_id,
                        )
                    store.write_json("claims.json", claims)
                elif step_id == "validate":
                    validation = self.claim_validator(claims, evidence, sources)
                    for warning in validation.warnings:
                        _add_limitation(limitations, warning.message)
                    if not validation.valid:
                        raise ProviderError(
                            "claim/evidence validation failed: "
                            + "; ".join(issue.message for issue in validation.errors)
                        )
                    if not claims:
                        _add_limitation(limitations, "The run produced no validated claims.")
                elif step_id == "report":
                    provisional_status = (
                        RunStatus.PARTIAL if limitations or not claims else RunStatus.COMPLETED
                    )
                    report_text = redact_text(
                        self.report_renderer(
                            request=request,
                            sources=sources,
                            evidence=evidence,
                            claims=claims,
                            limitations=limitations,
                            status=provisional_status.value,
                            run_id=run_id,
                        )
                    )
                    store.write_text("report.md", report_text)
                    artifacts = [
                        store.add_artifact(
                            name="report.md",
                            content=report_text.encode("utf-8"),
                            media_type="text/markdown",
                            produced_by_step="report",
                            input_ids=[item.get("evidence_id", "") for item in evidence],
                        )
                    ]
                completed_steps.append(step_id)
                store.append_event(
                    "step.completed",
                    {
                        "completed_steps": list(completed_steps),
                        "outputs": self._step_outputs(
                            step_id, sources, evidence, claims, artifacts
                        ),
                    },
                    timestamp=utc_now(),
                    step_id=step_id,
                )
                active_step_id = None
                self._write_checkpoint(
                    store,
                    completed_steps,
                    RunStatus.RUNNING,
                    selected_sources,
                    synthesizer_name,
                    capability_identities,
                    network_budget.used,
                )
                if stop_after_step == step_id:
                    _add_limitation(
                        limitations, f"Run intentionally interrupted after step {step_id}."
                    )
                    store.append_event(
                        "run.interrupted",
                        {"after_step": step_id},
                        timestamp=utc_now(),
                    )
                    status = RunStatus.PARTIAL
                    self._write_checkpoint(
                        store,
                        completed_steps,
                        status,
                        selected_sources,
                        synthesizer_name,
                        capability_identities,
                        network_budget.used,
                    )
                    self._write_manifest(
                        store=store,
                        request=request,
                        plan=active_plan,
                        status=status,
                        capabilities=capabilities,
                        sources=sources,
                        evidence=evidence,
                        claims=claims,
                        decisions=decisions,
                        artifacts=artifacts,
                        limitations=limitations,
                        errors=errors,
                    )
                    self._require_valid(store, "interrupted run")
                    return self._outcome(store, status, sources, evidence, claims, limitations)
        except (RunCancelledError, KeyboardInterrupt):
            status = RunStatus.CANCELLED
            _add_limitation(limitations, "The research run was cancelled by the user.")
            if active_step_id is not None:
                store.append_event(
                    "step.cancelled",
                    {"completed_steps": list(completed_steps)},
                    timestamp=utc_now(),
                    step_id=active_step_id,
                )
            store.append_event("run.cancelled", {}, timestamp=utc_now())
            self._write_checkpoint(
                store,
                completed_steps,
                status,
                selected_sources,
                synthesizer_name,
                capability_identities,
                network_budget.used,
                step_terminal=(active_step_id, "cancelled") if active_step_id else None,
            )
            self._write_manifest(
                store=store,
                request=request,
                plan=active_plan,
                status=status,
                capabilities=capabilities,
                sources=sources,
                evidence=evidence,
                claims=claims,
                decisions=decisions,
                artifacts=artifacts,
                limitations=limitations,
                errors=errors,
            )
            self._require_valid(store, "cancelled run")
            return self._outcome(store, status, sources, evidence, claims, limitations)
        except Exception as error:
            safe_error = {
                "type": type(error).__name__,
                "message": redact_text(str(error)),
            }
            errors.append(safe_error)
            if active_step_id is not None:
                store.append_event(
                    "step.failed",
                    safe_error,
                    timestamp=utc_now(),
                    step_id=active_step_id,
                )
            store.append_event("run.failed", safe_error, timestamp=utc_now())
            status = RunStatus.FAILED
            self._write_checkpoint(
                store,
                completed_steps,
                status,
                selected_sources,
                synthesizer_name,
                capability_identities,
                network_budget.used,
                step_terminal=(active_step_id, "failed") if active_step_id else None,
            )
            self._write_manifest(
                store=store,
                request=request,
                plan=active_plan,
                status=status,
                capabilities=capabilities,
                sources=sources,
                evidence=evidence,
                claims=claims,
                decisions=decisions,
                artifacts=artifacts,
                limitations=limitations,
                errors=errors,
            )
            raise

        status = RunStatus.PARTIAL if limitations or not claims else RunStatus.COMPLETED
        store.append_event(
            "run.finalizing",
            {"candidate_status": status.value},
            timestamp=utc_now(),
        )
        self._write_checkpoint(
            store,
            completed_steps,
            RunStatus.RUNNING,
            selected_sources,
            synthesizer_name,
            capability_identities,
            network_budget.used,
        )
        self._write_manifest(
            store=store,
            request=request,
            plan=active_plan,
            status=RunStatus.RUNNING,
            capabilities=capabilities,
            sources=sources,
            evidence=evidence,
            claims=claims,
            decisions=decisions,
            artifacts=artifacts,
            limitations=limitations,
            errors=errors,
        )
        self._require_valid(store, "pre-finalized run")

        store.append_event(
            "run.completed" if status is RunStatus.COMPLETED else "run.partial",
            {"status": status.value, "limitations": len(limitations)},
            timestamp=utc_now(),
        )
        self._write_checkpoint(
            store,
            completed_steps,
            status,
            selected_sources,
            synthesizer_name,
            capability_identities,
            network_budget.used,
        )
        self._write_manifest(
            store=store,
            request=request,
            plan=active_plan,
            status=status,
            capabilities=capabilities,
            sources=sources,
            evidence=evidence,
            claims=claims,
            decisions=decisions,
            artifacts=artifacts,
            limitations=limitations,
            errors=errors,
        )
        self._require_valid(store, "finalized run")
        return self._outcome(store, status, sources, evidence, claims, limitations)

    def resume(
        self,
        run_directory: Path,
        *,
        source_names: tuple[str, ...],
        synthesizer_name: str = "extractive",
        approved: bool = True,
    ) -> RunOutcome:
        integrity = self.run_validator(run_directory)
        if not integrity.valid:
            raise IntegrityError("cannot resume an invalid run: " + _validation_messages(integrity))
        store = self.store_factory.open(run_directory, redactor=redact_secrets)
        manifest = _dict(store.read_json("manifest.json"), "manifest")
        if manifest.get("status") == RunStatus.COMPLETED.value:
            return self._outcome(
                store,
                RunStatus.COMPLETED,
                _list(store.read_json("sources.json"), "sources"),
                _list(store.read_json("evidence.json"), "evidence"),
                _list(store.read_json("claims.json"), "claims"),
                list(manifest.get("limitations", [])),
            )
        request = ResearchRequest.from_dict(store.read_json("request.json"))
        return self.execute(
            request,
            workspace=store.run_directory.parent,
            source_names=source_names,
            synthesizer_name=synthesizer_name,
            approved=approved,
            resume_directory=store.run_directory,
        )

    def _initialize_store(
        self, store: RunRepository, request: ResearchRequest, plan: ResearchPlan
    ) -> None:
        store.write_json("request.json", request.to_dict())
        store.write_json("plan.json", plan.to_dict())
        store.write_json("sources.json", [])
        store.write_json("evidence.json", [])
        store.write_json("claims.json", [])
        store.write_json("policy_decisions.json", [])
        store.write_json("execution.json", {})

    def _tool_context(
        self,
        *,
        deadline: datetime,
        network_budget: _NetworkBudget,
        store: RunRepository,
        step_id: str,
        decisions: list[Any],
        limitations: list[str],
        provider_name: str,
    ) -> ToolContext:
        def emit(event_type: str, payload: Mapping[str, Any]) -> None:
            safe_payload = cast(dict[str, Any], redact_secrets(dict(payload)))
            store.append_event(event_type, safe_payload, timestamp=utc_now(), step_id=step_id)
            if event_type.endswith(".skipped"):
                reason = safe_payload.get("reason", "unspecified")
                location = safe_payload.get("path") or safe_payload.get("index")
                suffix = f" ({location})" if location is not None else ""
                _add_limitation(limitations, f"{event_type}: {reason}{suffix}.")

        def authorize(
            descriptor: CapabilityDescriptor,
            action: str,
            *,
            target: str = "",
            risk: Any = None,
        ) -> PolicyDecision:
            decision = self.policy.evaluate(descriptor, action, target=target, risk=risk)
            decisions.append(decision.to_dict())
            store.append_event(
                "policy.decided", decision.to_dict(), timestamp=utc_now(), step_id=step_id
            )
            return decision

        return ToolContext(
            deadline=deadline,
            remaining_network_requests=network_budget.remaining,
            authorize=authorize,
            user_agent=f"openscience-agent/{self.software_version}",
            emit=emit,
            is_cancelled=lambda: self.is_cancelled() or _cancel_marker_exists(store),
            network_consumer=lambda target: network_budget.consume(
                target, step_id=step_id, provider=provider_name
            ),
        )

    def _record_decision(
        self,
        store: RunRepository,
        decisions: list[Any],
        descriptor: CapabilityDescriptor,
        action: str,
        target: str,
        step_id: str,
    ) -> PolicyDecision:
        decision = self.policy.evaluate(descriptor, action, target=target)
        decisions.append(decision.to_dict())
        store.append_event(
            "policy.decided", decision.to_dict(), timestamp=utc_now(), step_id=step_id
        )
        return decision

    def _capabilities(
        self, source_names: tuple[str, ...], synthesizer_name: str
    ) -> list[CapabilityDescriptor]:
        return [
            *(_descriptor(self.registry.get_source(name)) for name in source_names),
            _descriptor(self.registry.get_synthesizer(synthesizer_name)),
        ]

    def _write_checkpoint(
        self,
        store: RunRepository,
        completed_steps: list[str],
        status: RunStatus,
        source_names: tuple[str, ...],
        synthesizer_name: str,
        capabilities: list[dict[str, Any]],
        network_requests_used: int,
        step_terminal: tuple[str, str] | None = None,
    ) -> None:
        checkpoint = {
            "completed_steps": list(completed_steps),
            "status": status.value,
            "source_names": list(source_names),
            "synthesizer": synthesizer_name,
            "capabilities": capabilities,
            "network_requests_used": network_requests_used,
        }
        step_statuses = {
            step_id: ("completed" if step_id in completed_steps else "pending")
            for step_id in self.STEP_IDS
        }
        if step_terminal is not None:
            step_statuses[step_terminal[0]] = step_terminal[1]
        execution = {
            "status": status.value,
            "completed_steps": list(completed_steps),
            "step_statuses": step_statuses,
            "network_requests_used": network_requests_used,
        }
        store.write_json("checkpoint.json", checkpoint)
        store.write_json("execution.json", execution)

    def _write_manifest(
        self,
        *,
        store: RunRepository,
        request: ResearchRequest,
        plan: ResearchPlan,
        status: RunStatus,
        capabilities: list[CapabilityDescriptor],
        sources: list[Any],
        evidence: list[Any],
        claims: list[Any],
        decisions: list[Any],
        artifacts: list[dict[str, Any]],
        limitations: list[str],
        errors: list[dict[str, Any]],
    ) -> None:
        projections = {
            "sources": sources,
            "evidence": evidence,
            "claims": claims,
            "policy_decisions": decisions,
        }
        for name, records in projections.items():
            store.write_json(f"{name}.json", records)
        events = store.read_events()
        execution = _dict(store.read_json("execution.json"), "execution")
        state = {
            name: store.projection_index(f"{name}.json", count=1)
            for name in ("request", "plan", "checkpoint", "execution")
        }
        report_path = store.run_directory / "report.md"
        manifest: dict[str, Any] = {
            "schema_version": "1.0",
            "run_id": store.run_directory.name,
            "status": status.value,
            "created_at": request.created_at,
            "updated_at": utc_now(),
            "request": {**request.to_dict(), "hash": sha256_json(request.to_dict())},
            "plan": {**plan.to_dict(), "hash": sha256_json(plan.to_dict())},
            "software": {
                "name": "openscience-agent",
                "version": self.software_version,
                "python": platform.python_version(),
                "platform": sys.platform,
            },
            "capabilities": [item.to_dict() for item in capabilities],
            "state": state,
            "execution": execution,
            "records": {
                name: store.projection_index(f"{name}.json", count=len(records))
                for name, records in projections.items()
            },
            "artifacts": artifacts,
            "event_log": {
                "path": "events.jsonl",
                "events": len(events),
                "head_hash": events[-1]["event_hash"] if events else "0" * 64,
            },
            "limitations": list(dict.fromkeys(redact_text(item) for item in limitations)),
            "errors": cast(list[Any], redact_secrets(errors)),
        }
        if report_path.is_file() and not report_path.is_symlink():
            manifest["report"] = store.projection_index("report.md", count=1)
        store.write_json("manifest.json", manifest)

    def _outcome(
        self,
        store: RunRepository,
        status: RunStatus,
        sources: list[Any],
        evidence: list[Any],
        claims: list[Any],
        limitations: list[str],
    ) -> RunOutcome:
        report_path = store.run_directory / "report.md"
        return RunOutcome(
            run_id=store.run_directory.name,
            run_directory=store.run_directory,
            status=status,
            report_path=report_path
            if report_path.is_file() and not report_path.is_symlink()
            else None,
            manifest_path=store.run_directory / "manifest.json",
            source_count=len(sources),
            evidence_count=len(evidence),
            claim_count=len(claims),
            limitations=tuple(dict.fromkeys(redact_text(item) for item in limitations)),
        )

    def _validate_plan(self, plan: ResearchPlan) -> None:
        step_ids = [step.step_id for step in plan.steps]
        if step_ids != list(self.STEP_IDS):
            raise ConfigurationError(
                f"plan must contain the fixed MVP workflow {self.STEP_IDS}, received {step_ids}"
            )
        for step in plan.steps:
            if step.status is not PlanStatus.PENDING:
                raise ConfigurationError(
                    f"approved plan step {step.step_id} status must remain 'pending'; "
                    "runtime status is recorded in execution.json"
                )
            if step.capability != self.STEP_CAPABILITIES[step.step_id]:
                raise ConfigurationError(
                    f"step {step.step_id} capability must be "
                    f"{self.STEP_CAPABILITIES[step.step_id]!r}"
                )
            if step.dependencies != self.STEP_DEPENDENCIES[step.step_id]:
                raise ConfigurationError(
                    f"step {step.step_id} dependencies must be "
                    f"{self.STEP_DEPENDENCIES[step.step_id]!r}"
                )

    def _require_active(self, deadline: datetime, store: RunRepository) -> None:
        if self.is_cancelled() or _cancel_marker_exists(store):
            raise RunCancelledError("research run was cancelled")
        if datetime.now(UTC) >= deadline:
            raise LimitExceededError("run timeout exceeded")

    def _require_valid(self, store: RunRepository, stage: str) -> None:
        result = self.run_validator(store.run_directory)
        if not result.valid:
            raise IntegrityError(
                f"{stage} failed integrity validation: {_validation_messages(result)}"
            )

    @staticmethod
    def _step_input_hashes(store: RunRepository, step_id: str) -> dict[str, str]:
        names = {
            "discover": ("request", "plan"),
            "extract": ("request", "sources"),
            "synthesize": ("request", "sources", "evidence"),
            "validate": ("sources", "evidence", "claims"),
            "report": ("request", "sources", "evidence", "claims"),
        }[step_id]
        return {
            name: store.projection_index(f"{name}.json", count=1).get("sha256", "")
            for name in names
        }

    @staticmethod
    def _step_outputs(
        step_id: str,
        sources: list[Any],
        evidence: list[Any],
        claims: list[Any],
        artifacts: list[dict[str, Any]],
    ) -> dict[str, list[Any]]:
        if step_id == "discover":
            return {"source_ids": [item.get("source_id") for item in sources]}
        if step_id == "extract":
            return {"evidence_ids": [item.get("evidence_id") for item in evidence]}
        if step_id in {"synthesize", "validate"}:
            return {"claim_ids": [item.get("claim_id") for item in claims]}
        return {"artifact_ids": [item.get("artifact_id") for item in artifacts]}


def _new_run_id() -> str:
    return f"run-{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:8]}"


def _descriptor(provider: Any) -> CapabilityDescriptor:
    value = (
        provider.descriptor()
        if callable(getattr(provider, "descriptor", None))
        else provider.descriptor
    )
    if not isinstance(value, CapabilityDescriptor):
        raise ConfigurationError(f"provider descriptor has invalid type: {type(value).__name__}")
    return value


def _to_dict(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    if hasattr(value, "to_dict"):
        result = value.to_dict()
        if isinstance(result, dict):
            return result
    if is_dataclass(value) and not isinstance(value, type):
        return asdict(cast(Any, value))
    raise TypeError(f"cannot serialize {type(value).__name__}")


def _safe_mapping(value: Any) -> dict[str, Any]:
    result = redact_secrets(_to_dict(value))
    if not isinstance(result, dict):
        raise TypeError("redacted provider record is not a mapping")
    return result


def _safe_claim(value: Any) -> dict[str, Any]:
    payload = _safe_mapping(value)
    payload.pop("claim_id", None)
    return cast(dict[str, Any], Claim.from_dict(payload).to_dict())


def _safe_request(request: ResearchRequest) -> ResearchRequest:
    payload = redact_secrets(request.to_dict())
    if not isinstance(payload, dict):
        raise ConfigurationError("request redaction did not produce a mapping")
    payload.pop("request_id", None)
    return ResearchRequest.from_dict(payload)


def _safe_plan(plan: ResearchPlan) -> ResearchPlan:
    payload = redact_secrets(plan.to_dict())
    if not isinstance(payload, dict):
        raise ConfigurationError("plan redaction did not produce a mapping")
    payload.pop("plan_id", None)
    return ResearchPlan.from_dict(payload)


def _capability_identity(descriptor: CapabilityDescriptor) -> dict[str, Any]:
    return {
        "name": descriptor.name,
        "version": descriptor.version,
        "kind": descriptor.kind.value,
        "risk": descriptor.risk.value,
        "contract_version": descriptor.contract_version,
    }


def _completed_prefix(checkpoint: Mapping[str, Any], step_ids: tuple[str, ...]) -> list[str]:
    raw = checkpoint.get("completed_steps", [])
    if not isinstance(raw, list) or not all(isinstance(item, str) for item in raw):
        raise IntegrityError("checkpoint completed_steps must be a string array")
    completed = list(raw)
    if completed != list(step_ids[: len(completed)]):
        raise IntegrityError("checkpoint completed_steps are not a valid workflow prefix")
    return completed


def _nonnegative(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise IntegrityError(f"{name} must be a non-negative integer")
    return int(value)


def _dict(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise IntegrityError(f"{name} projection must be an object")
    return value


def _list(value: Any, name: str) -> list[Any]:
    if not isinstance(value, list):
        raise IntegrityError(f"{name} projection must be an array")
    return value


def _add_limitation(limitations: list[str], message: str) -> None:
    safe = redact_text(message)
    if safe not in limitations:
        limitations.append(safe)


def _validation_messages(result: ValidationOutcome) -> str:
    messages = [str(getattr(issue, "message", issue)) for issue in result.errors]
    return "; ".join(messages) or "unknown integrity error"


def _cancel_marker_exists(store: RunRepository) -> bool:
    return (store.run_directory / "cancel-requested.json").is_file()


__all__ = ["ResearchOrchestrator", "RunOutcome"]
