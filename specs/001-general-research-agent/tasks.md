# Tasks: General Research Agent

**Input**: Design documents from `specs/001-general-research-agent/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Required by the project constitution. Tests are written before or alongside the
behavior they validate and include deterministic contract, integration, and end-to-end coverage.

**Organization**: Tasks are grouped by user story so that each research capability can be
validated as a usable increment.

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create an installable, checked Python project and safe repository defaults.

- [X] T001 Create Python package metadata, CLI entry point, dev groups, and tool configuration in pyproject.toml
- [X] T002 [P] Create universal and Python ignore rules in .gitignore
- [X] T003 [P] Add clean-room project overview, scope, architecture, and usage in README.md
- [X] T004 [P] Add Apache-2.0 project license in LICENSE
- [X] T005 Create package and test directory skeleton in src/openscience_agent/ and tests/

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Implement shared domain contracts, serialization, policy, and registration required by
every user story.

**CRITICAL**: No user-story implementation begins until this phase is complete.

- [X] T006 [P] Write strict domain-model tests in tests/unit/test_domain.py
- [X] T007 [P] Write policy and redaction tests in tests/unit/test_policy.py
- [X] T008 [P] Write provider registration contract tests in tests/contract/test_provider_contract.py
- [X] T009 Implement typed entities, IDs, canonical JSON, and validation in src/openscience_agent/domain.py
- [X] T010 [P] Implement project error hierarchy in src/openscience_agent/errors.py
- [X] T011 [P] Define source, synthesis, repository, policy, validation, report-renderer, clock, and event ports in src/openscience_agent/ports.py
- [X] T012 Implement capability policy, approval outcomes, path boundaries, and secret redaction in src/openscience_agent/policy.py
- [X] T013 Implement built-in and entry-point provider registry with descriptor validation in src/openscience_agent/registry.py
- [X] T014 Expose version and stable public API symbols in src/openscience_agent/__init__.py

**Checkpoint**: Domain objects reject invalid state, risky capabilities are policy-gated, and
providers can be registered without importing the orchestrator.

---

## Phase 3: User Story 1 - Produce an Evidence-Backed Research Brief (Priority: P1) MVP

**Goal**: Turn a question and deterministic corpus into a plan, normalized multi-source evidence,
validated claims, and a cited report.

**Independent Test**: Run the packaged offline request and corpus and obtain a complete cited report
using at least two fixture providers.

- [X] T015 [P] [US1] Write fixture/local provider contract tests in tests/contract/test_offline_providers.py
- [X] T016 [P] [US1] Write source normalization and deduplication tests in tests/unit/test_normalization.py
- [X] T017 [P] [US1] Write evidence extraction and deterministic synthesis tests in tests/unit/test_synthesis.py
- [X] T018 [P] [US1] Write offline research journey test in tests/integration/test_offline_run.py
- [X] T019 [US1] Implement deterministic multi-provider fixture adapter in src/openscience_agent/adapters/fixtures.py
- [X] T020 [US1] Implement identifier normalization, cross-provider merge, and evidence extraction in src/openscience_agent/evidence.py
- [X] T021 [US1] Implement deterministic extractive synthesis and model-output boundary in src/openscience_agent/adapters/model.py
- [X] T022 [US1] Implement finite research planning and step execution kernel in src/openscience_agent/orchestrator.py
- [X] T023 [US1] Implement citation-preserving Markdown report renderer in src/openscience_agent/report.py
- [X] T024 [US1] Implement editable plan command, explicit approval, run command, and provider selection in src/openscience_agent/cli.py
- [X] T025 [US1] Add two-provider research corpus and request in examples/corpus.json and examples/research-request.json

**Checkpoint**: The offline command independently delivers an inspectable research brief.

---

## Phase 4: User Story 2 - Audit Claims and Provenance (Priority: P1)

**Goal**: Persist immutable run activity and let an auditor verify every claim, event, source, and
artifact without trusting the final prose.

**Independent Test**: Validate a completed fixture run, then tamper with one event/evidence link and
prove that validation fails with the exact broken invariant.

- [X] T026 [P] [US2] Write event-chain and atomic projection tests in tests/unit/test_storage.py
- [X] T027 [P] [US2] Write claim/evidence, retraction, and artifact validation tests in tests/unit/test_validation.py
- [X] T028 [P] [US2] Write manifest schema contract tests in tests/contract/test_manifest_contract.py
- [X] T029 [US2] Implement hash-chained events, atomic projections, checkpoints, and object storage in src/openscience_agent/storage.py
- [X] T030 [US2] Implement claim/evidence, event-chain, manifest, and artifact validators in src/openscience_agent/validation.py
- [X] T031 [US2] Integrate persisted policy decisions, sources, evidence, claims, report, and manifest in src/openscience_agent/orchestrator.py
- [X] T032 [US2] Implement validate and inspect command output in src/openscience_agent/cli.py

**Checkpoint**: Valid runs pass a full audit; tampering, fabricated citations, and unsupported
retracted evidence fail visibly.

---

## Phase 5: User Story 3 - Research Across Local Materials (Priority: P2)

**Goal**: Read supported files only within explicitly approved roots and preserve file-level
provenance without changing source material.

**Independent Test**: Search an approved local fixture tree, reject a symlink/path escape, and cite
the accepted file separately from remote or corpus records.

- [X] T033 [P] [US3] Write approved-root, symlink escape, size, and format tests in tests/contract/test_local_files.py
- [X] T034 [P] [US3] Add safe local document fixtures in tests/fixtures/local_corpus/
- [X] T035 [US3] Implement bounded read-only local text/Markdown/JSON provider in src/openscience_agent/adapters/local_files.py
- [X] T036 [US3] Integrate repeatable local roots and local-source limitations in src/openscience_agent/cli.py

**Checkpoint**: Local research works within approved roots and denies all tested boundary escapes.

---

## Phase 6: User Story 4 - Extend Models and Research Sources (Priority: P2)

**Goal**: Use declared provider contracts for both live scholarly metadata and optional model
synthesis without changing the orchestration kernel.

**Independent Test**: Swap between fixture, OpenAlex, Crossref, and a fake JSON model adapter through
registration/configuration while the orchestrator remains unchanged.

- [X] T037 [P] [US4] Write mocked OpenAlex mapping, timeout, and failure tests in tests/contract/test_openalex.py
- [X] T038 [P] [US4] Write mocked Crossref mapping, attribution, and failure tests in tests/contract/test_crossref.py
- [X] T039 [P] [US4] Write model JSON output and evidence-ID guard tests in tests/contract/test_model_adapter.py
- [X] T040 [US4] Implement polite, bounded OpenAlex source adapter in src/openscience_agent/adapters/openalex.py
- [X] T041 [US4] Implement polite, bounded Crossref source adapter in src/openscience_agent/adapters/crossref.py
- [X] T042 [US4] Implement optional OpenAI-compatible JSON synthesis adapter in src/openscience_agent/adapters/model.py
- [X] T043 [US4] Integrate live sources, contact identity, model config, and network policy in src/openscience_agent/cli.py

**Checkpoint**: Providers are replaceable through configuration and contract-tested adapters.

---

## Phase 7: User Story 5 - Resume, Replay, and Export Research (Priority: P3)

**Goal**: Resume valid checkpoints, reconstruct a run offline, and export a portable research object
with native and interoperable provenance.

**Independent Test**: Interrupt a fixture run, resume without repeating completed steps, replay it
without providers, and validate the exported ZIP and RO-Crate metadata.

- [X] T044 [P] [US5] Write five-point resume, no-duplicate-step, invalid-state, and cancellation tests in tests/integration/test_resume.py
- [X] T045 [P] [US5] Write offline replay and tamper detection tests in tests/integration/test_replay.py
- [X] T046 [P] [US5] Write ZIP content, redaction, checksums, and RO-Crate tests in tests/integration/test_export.py
- [X] T047 [US5] Implement hash-verified event-and-projection offline replay in src/openscience_agent/replay.py
- [X] T048 [US5] Implement resumable orchestration with provider compatibility checks in src/openscience_agent/orchestrator.py
- [X] T049 [US5] Implement sanitized ZIP and RO-Crate 1.3 export in src/openscience_agent/export.py
- [X] T050 [US5] Implement resume, inspect, cancel, replay, and export commands in src/openscience_agent/cli.py

**Checkpoint**: Interrupted work resumes safely and completed work is portable and audit-ready.

---

## Phase 8: Polish & Cross-Cutting Quality

**Purpose**: Prove the complete specification, security posture, and contributor workflow.

- [X] T051 [P] Add prompt-injection, malicious model output, local-data egress denial, network-budget, and secret persistence/export tests in tests/integration/test_security.py
- [X] T052 [P] Add CLI JSON/exit-code contract tests in tests/contract/test_cli.py
- [X] T053 Add continuous integration for lint, format, types, tests, and secret-pattern scan in .github/workflows/ci.yml
- [X] T054 Add architecture decisions, extension guide, security model, and reference attribution in docs/architecture.md and docs/extensions.md
- [X] T055 Run the quickstart and inspect walk-through end to end and update README.md with verified output counts, audit path, and limitations
- [X] T056 Run ruff, mypy, full pytest coverage, the 1,000-link benchmark, build/install/offline package smoke, and Spec Kit consistency audit

---

## Dependencies & Execution Order

### Phase Dependencies

- Setup has no dependencies.
- Foundational depends on Setup and blocks every user story.
- US1 depends on Foundational and is the first usable MVP.
- US2 depends on US1 outputs but validates them independently.
- US3 depends only on Foundational plus US1 source normalization.
- US4 depends on Foundational provider contracts plus US1 orchestration.
- US5 depends on US2 persistence and can use fixture providers for deterministic tests.
- Polish depends on all selected stories.

### User Story Flow

```text
Foundation -> US1 -> US2 -> US5
              |      |
              +-> US3
              +-> US4
```

### Parallel Opportunities

- Setup documentation and ignore/license tasks can run in parallel.
- Foundational tests target separate modules and can run in parallel before implementation.
- Provider adapters (US3/US4) use independent files after contracts stabilize.
- Storage/validation test authoring can occur independently of adapter work.
- Resume, replay, and export tests target separate components.

## Implementation Strategy

1. Establish strict domain and capability contracts.
2. Deliver the offline US1 vertical slice before any live integration.
3. Add audit persistence and make it a release gate.
4. Add local and live adapters without changing orchestration domain types.
5. Add replay/export only after persisted invariants are stable.
6. Finish with adversarial security tests and a clean-environment quickstart.

Every completed task is marked `[X]` only after its tests or direct validation pass.

## Requirement Traceability

| Requirement(s) | Primary tasks |
|----------------|---------------|
| FR-001–FR-003 | T009, T022, T024, T044, T048, T050 |
| FR-004–FR-006 | T015–T020, T033–T041 |
| FR-007–FR-010 | T017, T021, T023, T027, T030, T039, T051 |
| FR-011–FR-012 | T007, T012, T032–T036, T043, T051 |
| FR-013 | T033–T036 |
| FR-014–FR-015 | T008, T011, T013, T037–T043 |
| FR-016 | T026, T029, T044, T048, T050 |
| FR-017–FR-019 | T028–T032, T045–T050 |
| FR-020–FR-022 | T007, T012, T022, T029, T037–T043, T046, T051 |
| FR-023 | T023, T027, T030, T054 |
| FR-024 | T018, T025, T055–T056 |
| SC-001–SC-003 | T018, T023, T026–T032, T055–T056 |
| SC-004–SC-005 | T008, T013, T037–T050 |
| SC-006–SC-009 | T007, T012, T027, T030, T037–T043, T046, T051–T056 |
