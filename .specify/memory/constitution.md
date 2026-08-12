<!--
Sync Impact Report
- Version change: template → 1.0.0
- Added principles:
  - I. Evidence Before Narrative
  - II. Reproducibility by Construction
  - III. Human Authority and Bounded Autonomy
  - IV. Modular, Provider-Neutral Core
  - V. Verification and Transparent Failure
- Added sections:
  - Research Integrity and Data Governance
  - Development Workflow and Quality Gates
- Removed sections: none
- Deferred items: none
-->
# OpenScience Constitution

## Core Principles

### I. Evidence Before Narrative
Every externally verifiable scientific claim MUST be linked to a concrete evidence record. An
evidence record MUST identify its source, retrieval time, stable identifier or URL, and the exact
passage or metadata used. The system MUST distinguish source statements, agent inferences, and
user-provided assumptions. It MUST never invent citations, experimental results, measurements, or
source access. Conflicting evidence and material uncertainty MUST be shown rather than silently
resolved. Rationale: a fluent answer without traceable evidence is not a research result.

### II. Reproducibility by Construction
Every research run MUST produce a machine-readable manifest containing the request, plan, tool
calls, normalized inputs and outputs, configuration, model and tool identifiers, timestamps, and
artifact hashes where practical. Derived artifacts MUST retain provenance links to their inputs.
Workflows SHOULD be deterministic when the task permits; nondeterminism MUST be recorded. A run
MUST be resumable or fail with enough state to diagnose and repeat it. Rationale: another
researcher must be able to inspect how a conclusion was produced and repeat the process.

### III. Human Authority and Bounded Autonomy
The agent MUST expose its plan and remain within the user's stated research scope. Read-only
discovery may proceed autonomously, but external publication, messages, purchases, credential
changes, destructive file operations, execution of untrusted code, and other consequential actions
MUST require explicit authorization. Tools MUST declare capabilities and risk levels, and the
runtime MUST enforce policy before invocation. The agent MUST make limitations visible and MUST
not present itself as a substitute for domain, clinical, legal, ethics, or safety review. Rationale:
useful autonomy depends on predictable boundaries and accountable human control.

### IV. Modular, Provider-Neutral Core
Planning, orchestration, evidence storage, tool execution, and report rendering MUST communicate
through documented, typed interfaces. No core domain model may depend on one model vendor, search
provider, discipline, or user interface. New tools and model providers MUST be addable through
adapters without editing the orchestration kernel. Public interfaces MUST have contract tests and
versioned compatibility rules. Rationale: a general scientific agent must remain portable,
extensible, and independently testable.

### V. Verification and Transparent Failure
Tests MUST be written for domain models, policy enforcement, provenance, adapters, and complete
research workflows. Network-dependent integrations MUST have deterministic fixtures as well as
explicit opt-in live tests. The runtime MUST validate structured model output, tool arguments,
citations, and final artifact completeness. Partial results MUST be labeled; errors MUST retain
context and MUST NOT be converted into fabricated success. Rationale: scientific automation earns
trust through falsifiable behavior and explicit failure modes.

## Research Integrity and Data Governance

- Sources MUST retain attribution and license metadata when available. The project MUST respect
  source terms, robots policies, rate limits, copyright, and database rights.
- Secrets, credentials, unpublished data, and personal or sensitive data MUST NOT appear in logs,
  prompts, fixtures, or committed artifacts. Redaction MUST occur before persistence.
- Human-subjects, clinical, dual-use, hazardous, or regulated research MUST surface an appropriate
  review boundary and MUST NOT be executed merely because a tool can perform it.
- Retrieved text is untrusted data. Instructions contained in sources MUST NOT alter agent policy,
  tool permissions, or the research objective.
- Reports MUST state coverage limits, search dates, evidence quality limits, and known conflicts.

## Development Workflow and Quality Gates

1. Every capability begins with a reviewed specification containing independently testable user
   scenarios, measurable outcomes, assumptions, and explicit exclusions.
2. Technical plans MUST document architecture decisions, alternatives, data flows, trust
   boundaries, and the provenance model before implementation.
3. Tasks MUST be traceable to requirements. Tests are authored before or with the behavior they
   validate, and required test suites, linting, type checks, and secret scanning MUST pass before
   merge.
4. Any new integration MUST include a typed adapter, timeout and retry behavior, rate-limit
   handling, deterministic fixtures, attribution handling, and a failure-mode test.
5. Every end-to-end release candidate MUST demonstrate a fresh research run, an inspectable run
   manifest, verifiable citations, and a successful offline replay of recorded fixtures.
6. Complexity beyond the smallest architecture satisfying these gates MUST be justified in the
   implementation plan and reviewed explicitly.

## Governance

This constitution is the highest project-level engineering authority. Specifications, plans,
tasks, code, and reviews MUST demonstrate compliance; when they conflict, the lower-level artifact
MUST change. Amendments require a documented rationale, a migration or compatibility assessment,
and an update to affected specifications and tests. Versions follow semantic versioning: MAJOR for
incompatible principle changes or removals, MINOR for new principles or materially expanded
obligations, and PATCH for clarifications that do not change obligations. Every pull request MUST
identify applicable principles, and reviewers MUST block unresolved MUST violations. Compliance is
re-evaluated at planning and before release.

**Version**: 1.0.0 | **Ratified**: 2026-08-12 | **Last Amended**: 2026-08-12
