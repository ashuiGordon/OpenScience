# Implementation Plan: General Research Agent

**Branch**: `agent/general-research-agent` | **Date**: 2026-08-12 | **Spec**:
[spec.md](spec.md)

**Input**: Feature specification from `specs/001-general-research-agent/spec.md`

## Summary

Build an original, headless scientific-research agent that turns a scoped question into a
reviewable plan, searches interchangeable scholarly sources, normalizes evidence, creates a
claim–evidence graph, validates citations, and exports a replayable research bundle. The first
vertical slice is a Python library and CLI with deterministic offline operation, local-file input,
live OpenAlex and Crossref adapters, append-only hash-chained events, content-addressed artifacts,
explicit capability policy, checkpoint/resume, and RO-Crate 1.3-compatible export metadata.

The implementation borrows only general patterns from the references: provider adapters,
application-owned orchestration, declared tools, durable events, and explicit approval boundaries.
No source code, prompts, UI, schema names, or branded assets are copied from either project.

## Technical Context

**Language/Version**: Python 3.11+

**Primary Dependencies**: Python standard library at runtime; `pytest`, `pytest-cov`, `mypy`,
`ruff`, and `jsonschema` as development-only dependencies

**Storage**: Local append-only JSONL event stream, atomic JSON projections, and SHA-256
content-addressed artifact objects. No database is required for the single-user MVP.

**Testing**: pytest unit, contract, integration, and end-to-end suites; deterministic fixtures;
opt-in live network smoke tests

**Target Platform**: macOS and Linux command-line environments with Python 3.11+. The first-release
local-file boundary depends on POSIX descriptor-relative, no-follow file opening; Windows support is
deferred until an equivalently race-resistant filesystem adapter is available.

**Project Type**: Installable library and CLI

**Performance Goals**: Create an offline evidence-backed demo report in under 30 seconds on a
typical laptop; validate 1,000 evidence/claim links in under 2 seconds; stream and persist every
state-changing event before reporting step completion

**Constraints**: Offline-capable core; no required model API; no arbitrary code execution in the
MVP; network disabled unless explicitly allowed; deterministic replay never contacts providers;
all persisted values pass through secret redaction; runtime package remains provider-neutral

**Scale/Scope**: One researcher, tens of providers/extensions, up to 1,000 normalized sources and
10,000 evidence records per run; CLI and programmatic API only for the first release

## Constitution Check

*GATE: Must pass before Phase 0 research and after Phase 1 design.*

| Principle | Design evidence | Status |
|-----------|-----------------|--------|
| Evidence Before Narrative | Claims have typed classifications and evidence IDs; completion runs a citation-support validator. | PASS |
| Reproducibility by Construction | Request, plan, events, providers, evidence, artifacts, hashes, and limitations are exported in a manifest and RO-Crate metadata. | PASS |
| Human Authority and Bounded Autonomy | Policy evaluates each capability; live network is opt-in; code execution and consequential actions are absent from the MVP. | PASS |
| Modular, Provider-Neutral Core | Domain and orchestrator depend on protocols; source/model adapters and extensions sit at the boundary. | PASS |
| Verification and Transparent Failure | Structured validation, deterministic fixtures, partial-result status, and explicit source failures are required tests. | PASS |
| Research Integrity and Data Governance | Source license/access metadata, prompt-injection separation, local-root checks, and secret redaction are first-class. | PASS |

Post-design re-check: PASS. The contracts retain provider neutrality, the data model includes
provenance and policy decisions, and the quickstart contains an offline audit scenario. There are
no justified constitution violations.

## Architecture

```text
CLI / Python API
        |
Application service (commands, resume, replay, export)
        |
Research orchestrator ───── Policy engine
        |                         |
        +── SourceProvider ports  +── approval/deny decisions
        +── Synthesizer port
        +── RunRepository port (including content-addressed artifacts)
        +── run/claim Validator ports
        +── ReportRenderer port
        |
Adapters: fixtures, local files, OpenAlex, Crossref, extractive synthesis,
          OpenAI-compatible JSON synthesis, filesystem store
```

The domain layer has no imports from adapters or the CLI. Side effects occur only behind ports.
Each orchestrator step writes a hash-chained event and an atomic checkpoint. Provider errors are
collected as limitations unless no useful evidence can be produced.

## Trust Boundaries

1. CLI input and configuration are untrusted and validated before a run is created.
2. Local paths must resolve beneath explicitly approved roots; symlink escape is rejected.
3. Provider responses and document text are data, never executable instructions.
4. Model output is untrusted structured data; only known evidence IDs survive validation.
5. Secrets remain in process configuration, are redacted before persistence/egress, and are
   excluded from replay/export. Network synthesis refuses local-file evidence in the first release.
6. Network adapters cannot run unless policy grants the `network.read` capability.
7. The MVP does not provide shell, Python, R, browser automation, remote publication, or arbitrary
   MCP execution. Those require a later sandboxed capability specification.

## Project Structure

### Documentation (this feature)

```text
specs/001-general-research-agent/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── cli.md
│   ├── provider.md
│   └── run-manifest.schema.json
├── checklists/
│   └── requirements.md
└── tasks.md
```

### Source Code (repository root)

```text
src/openscience_agent/
├── __init__.py
├── cli.py
├── domain.py
├── errors.py
├── orchestrator.py
├── policy.py
├── ports.py
├── registry.py
├── replay.py
├── report.py
├── storage.py
├── validation.py
└── adapters/
    ├── crossref.py
    ├── fixtures.py
    ├── local_files.py
    ├── model.py
    └── openalex.py

tests/
├── contract/
├── integration/
├── unit/
└── fixtures/

examples/
├── corpus.json
└── research-request.json
```

**Structure Decision**: A single installable Python package keeps the headless domain and
orchestration kernel small while preserving strict internal ports. A web or desktop client can be
added later as another application adapter without changing the research model.

## Complexity Tracking

No constitution violations require exceptions. Content-addressed storage and hash-chained events
add modest complexity, but they directly satisfy immutable provenance, replay integrity, and audit
requirements that atomic overwrite-only files cannot meet.
