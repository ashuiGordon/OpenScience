---

description: "TDD implementation tasks for the native macOS OpenScience desktop client"
---

# Tasks: Native macOS Desktop Client

**Input**: Design documents from `specs/002-macos-desktop-client/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: TDD is mandatory. Within every user-story phase, author the listed failing tests and
observe the expected red state before implementing behavior. A task is marked complete only after
its direct tests and relevant existing regression tests pass.

**Organization**: Setup and foundational phases establish typed boundaries. Each subsequent phase
is an independently testable user-story slice. Exact paths are part of every task contract.

**Current status (2026-08-21)**: 59/97 tasks are complete for the development preview. Pending
items intentionally include visual/accessibility inspection, user and performance studies,
resilience/support-export work, localization/assets, and final release
traceability. An unchecked item is not implied complete by a successful local app build.

## Format: `[ID] [P?] [Story?] Description with file path`

- **[P]**: May run in parallel because it targets different files and has no incomplete dependency.
- **[Story]**: Required only in user-story phases and maps to `US1`–`US6` in [spec.md](spec.md).

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create a buildable native application skeleton and deterministic test targets without
changing existing engine behavior.

- [X] T001 Create the macOS app, unit-test, and UI-test targets in `macos/OpenScienceDesktop/Package.swift`
- [X] T002 Configure macOS 14 deployment, Swift tools/language mode 5.10, products, test targets, and unsandboxed build policy in `macos/OpenScienceDesktop/Package.swift`
- [X] T003 [P] Create the app/feature/infrastructure/test directory groups and initial source manifests under `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/`, `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/`, and `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/`
- [ ] T004 [P] Add app icons, system-color assets, and externalized Simplified Chinese strings in `macos/OpenScienceDesktop/App/Assets.xcassets/` and `macos/OpenScienceDesktop/App/Resources/Localizable.xcstrings`
- [ ] T005 [P] Add deterministic engine fixture scripts and sanitized fake run artifacts in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/Fixtures/`
- [X] T006 [P] Create external-engine and optional fixed-helper build script interfaces in `scripts/build-macos-helper.sh` and `macos/OpenScienceDesktop/scripts/build-app.sh`
- [X] T007 Add macOS build/test jobs that preserve existing Python gates and exclude live providers in `.github/workflows/ci.yml`

**Checkpoint**: `swift build` and `macos/OpenScienceDesktop/scripts/build-app.sh` produce and launch an
empty unsandboxed app target; no research behavior or distribution-security claim exists.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Test first, then implement the process, workspace, event, security, persistence, and
app-environment boundaries used by every story.

**⚠️ CRITICAL**: All T008–T018 tests MUST fail for the intended missing behavior before T019+ begins.

### Failing Foundational Contract Tests

- [X] T008 [P] Write failing CLI tests for OpenAlex/Crossref environment credential fallback and secret-free JSON errors in `tests/contract/test_cli.py`
- [X] T009 [P] Write failing CLI integration canaries proving run stdout is terminal-only and all three secrets are absent from args/config/events/run/export artifacts in `tests/integration/test_security.py`
- [X] T010 [P] Write failing executable-resolution tests for bundled-helper priority, compatible development override, no PATH lookup, and unavailable/incompatible states in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/EngineResolverTests.swift`
- [X] T011 [P] Write failing process-runner tests for argument-array launch, bounded async pipes, timeout, exit mapping, minimal environment, and redacted diagnostics in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/FoundationProcessRunnerTests.swift`
- [X] T012 [P] Write failing one-object terminal decoder tests for empty, multiple, invalid UTF-8/JSON, oversized, unknown-field, and exit-mismatch cases in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/TerminalJSONDecoderTests.swift`
- [X] T013 [P] Write failing unique-workspace tests for empty creation, one `run-*`, zero/multiple candidates, wrong shape, symlink escape, and cleanup policy in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/AttemptWorkspaceTests.swift`
- [X] T014 [P] Write failing event-cursor tests for partial lines, coalesced appends, duplicates, gaps, malformed/oversized records, run-ID mismatch, replacement, and wake recovery in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/EventLogCursorTests.swift`
- [ ] T015 [P] Write failing desktop-domain state-machine/decoding tests for drafts, plan reviews, attempts, run summaries, and export jobs in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/DesktopModelTests.swift`
- [ ] T016 [P] Write failing Keychain/redactor tests for independent credential items, presence-only metadata, denial, deletion, and canary removal in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/KeychainSecretStoreTests.swift`
- [ ] T017 [P] Write failing preference/history tests proving secrets/grants/approvals are non-persistable and history cache is rebuildable in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/DesktopPersistenceTests.swift`
- [X] T018 [P] Write failing managed-run repository tests for root containment, regular-file checks, size limits, immutable reads, cache invalidation, and validator authority in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/ManagedRunRepositoryTests.swift`

### Foundational Implementation

- [X] T019 Implement OpenAlex/Crossref environment fallback using `OPENSCIENCE_OPENALEX_API_KEY` and `OPENSCIENCE_CROSSREF_API_KEY` without changing domain/provider interfaces in `src/openscience_agent/cli.py`
- [ ] T020 [P] Implement desktop value types, strict decoders, validation, and state machines in `macos/OpenScienceDesktop/Sources/OpenScienceCore/DesktopModels.swift`, `macos/OpenScienceDesktop/Sources/OpenScienceCore/BridgeModels.swift`, and `macos/OpenScienceDesktop/Sources/OpenScienceCore/RunState.swift`
- [X] T021 Implement bundled `Contents/Helpers/openscience` priority, development override, exact version probing, and compatibility diagnostics in `macos/OpenScienceDesktop/Sources/OpenScienceCore/EngineResolver.swift`
- [X] T022 Implement no-shell async process launch, bounded pipe capture, timeout/termination, minimal environment, and redacted invocation in `macos/OpenScienceDesktop/Sources/OpenScienceCore/CLIClient.swift`
- [X] T023 [P] Implement strict exactly-one-object/exit consistency decoding in `macos/OpenScienceDesktop/Sources/OpenScienceCore/CLIClient.swift`
- [X] T024 [P] Implement unique task workspace allocation and exact contained run discovery in `macos/OpenScienceDesktop/Sources/OpenScienceCore/AttemptWorkspace.swift`
- [X] T025 Implement newline-safe sequence cursor, file observation, bounded fallback polling, and wake drain in `macos/OpenScienceDesktop/Sources/OpenScienceCore/EventLogCursor.swift`
- [X] T026 [P] Implement Security-framework Keychain storage, three fixed environment mappings, and central bounded secret redaction in `macos/OpenScienceDesktop/Sources/OpenScienceCore/KeychainStore.swift` and `macos/OpenScienceDesktop/Sources/OpenScienceCore/SecretRedactor.swift`
- [ ] T027 [P] Implement non-secret preferences, restorable draft storage, and schema-versioned rebuildable history index in `macos/OpenScienceDesktop/Sources/OpenScienceCore/DesktopPersistence.swift`
- [X] T028 Implement root-contained artifact loading plus validate/inspect/replay bridge calls in `macos/OpenScienceDesktop/Sources/OpenScienceCore/RunRepository.swift`
- [ ] T029 Wire fakeable process, filesystem, clock, Keychain, URL opener, and repository protocols into `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/AppModel.swift`
- [ ] T030 Re-run T008–T018 and the existing Python suite, recording the foundational green baseline in `specs/002-macos-desktop-client/quickstart.md`

**Checkpoint**: Typed foundations are green, no secret persists, and no story UI is required to test
the bridge/security boundaries.

---

## Phase 3: User Story 1 - Create and Run a Research Task (Priority: P1) 🎯 MVP

**Goal**: Deliver the offline composer → plan review → explicit approval → unique-workspace run →
event progress → reconciled terminal result vertical slice, with per-run network gating available.

**Independent Test**: Select `tests/fixtures/local_corpus`, approve the finite plan, complete one
local run, and observe exact step progress/counts and validated completion with no network/account.

### Failing Tests for User Story 1

- [ ] T031 [P] [US1] Write failing composer validation/default/provider-selection tests in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/ResearchComposerViewModelTests.swift`
- [X] T032 [P] [US1] Write failing plan command/response/file-identity and review-expiration tests in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/PlanCoordinatorTests.swift`
- [X] T033 [P] [US1] Write failing network-grant tests for per-attempt summary, decline, no remembered grant, changed risk/limits, and exact `--allow-network` mapping in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/NetworkGrantTests.swift`
- [X] T034 [P] [US1] Write failing run coordinator tests for unique workspace, one `run-*` discovery, terminal-only stdout, event progress, and reconciliation mismatch in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/RunCoordinatorTests.swift`
- [ ] T035 [P] [US1] Write a failing offline keyboard UI journey from draft through evidence-ready completion in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/NewResearchFlowTests.swift`

### Implementation for User Story 1

- [ ] T036 [P] [US1] Implement field validation, constraints/assumptions, limits, provider selection, and non-secret draft restoration in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ResearchComposerViewModel.swift`
- [X] T037 [P] [US1] Implement native composer fields, local directory chooser, errors, and Generate Plan action in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ResearchComposerView.swift`
- [X] T038 [US1] Implement plan command construction, private plan file validation, immutable review state, and reject/expire behavior in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/PlanCoordinator.swift`
- [X] T039 [P] [US1] Implement ordered plan/risk/provider/local-root review UI in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/PlanReviewView.swift`
- [X] T040 [US1] Implement ephemeral per-attempt network grants and non-default Allow-for-This-Run confirmation in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/NetworkConfirmationView.swift`
- [X] T041 [US1] Implement run argument/environment construction, attempt lifecycle, event updates, and terminal validation reconciliation in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/RunCoordinator.swift`
- [X] T042 [US1] Implement active-run step list, status/counts, safe diagnostics, cancellation entry point, and terminal actions in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ActiveRunView.swift`
- [X] T043 [US1] Implement primary navigation, active-attempt ownership, New Research routing, and compatible-engine gating in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/OpenScienceDesktopApp.swift` and `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/RootView.swift`
- [ ] T044 [US1] Make T031–T035 green and capture a fresh offline run/event/reconciliation acceptance result in `specs/002-macos-desktop-client/quickstart.md`

**Checkpoint**: US1 is a usable offline desktop MVP and can be demonstrated without any later story.

---

## Phase 4: User Story 2 - Review History, Reports, and Evidence (Priority: P1)

**Goal**: Rebuild and filter local history, validate a run, and traverse every claim to exact
evidence/source metadata while surfacing conflicts, limitations, and integrity failure.

**Independent Test**: Seed completed/partial/invalid fixture runs, relaunch, filter/open each, and
inspect exact evidence and source attribution without a provider call.

### Failing Tests for User Story 2

- [ ] T045 [P] [US2] Write failing 0/100-run rebuild, duplicate-ID, filtering, sorting, invalidation, and no-network history tests in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/RunHistoryViewModelTests.swift`
- [X] T046 [P] [US2] Write failing claim/evidence/source join tests for exact IDs, missing links, kinds, stances, source states, attribution, and limits in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/ReportProjectionTests.swift`
- [X] T047 [P] [US2] Write failing HTTP(S)-only external URL policy and retrieved-instruction inertness tests in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/ExternalURLPolicyTests.swift`
- [ ] T048 [P] [US2] Write failing integrity-invalid read-only and terminal/manifest/event disagreement UI tests in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/IntegrityFailureFlowTests.swift`
- [ ] T049 [P] [US2] Write a failing history-to-exact-evidence keyboard UI journey in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/HistoryEvidenceFlowTests.swift`

### Implementation for User Story 2

- [ ] T050 [P] [US2] Implement app-managed history rebuild, search/filter/sort, fingerprints, and validation indicators in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/RunHistoryViewModel.swift`
- [X] T051 [P] [US2] Implement history rows, empty/invalid states, local refresh, and run selection in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/RunHistoryView.swift`
- [X] T052 [US2] Implement bounded immutable report/claim/evidence/source decoding and exact-ID joins in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ReportViewModel.swift`
- [X] T053 [US2] Implement inert report presentation, claim-kind styling, evidence/source inspector, conflicts/limitations, and missing-link errors in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ReportEvidenceView.swift`
- [X] T054 [P] [US2] Implement explicit validated HTTP(S) destination confirmation and opener in `macos/OpenScienceDesktop/Sources/OpenScienceCore/ExternalURLPolicy.swift`
- [ ] T055 [US2] Make T045–T049 green and record 100-run/1,000-evidence timing plus exact-link acceptance evidence in `specs/002-macos-desktop-client/quickstart.md`

**Checkpoint**: US2 is independently demonstrable with seeded run fixtures and no execution/network.

---

## Phase 5: User Story 3 - Cancel and Resume Work Safely (Priority: P2)

**Goal**: Request exact/idempotent cancellation, recover recorded state, review resume work, reacquire
authority, and continue without repeating completed steps.

**Independent Test**: Cancel a fixture run twice after one completed step, relaunch, resume after new
approval/root selection, and compare events to prove that step was not repeated.

### Failing Tests for User Story 3

- [X] T056 [P] [US3] Write failing pre-discovery stop, exact post-discovery cancel target, idempotence, grace timeout, and no-fake-terminal tests in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/CancellationCoordinatorTests.swift`
- [X] T057 [P] [US3] Write failing resume eligibility/validation, fresh plan/network/root/credential approval, exact provider identity, and completed-step preservation tests in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/ResumeCoordinatorTests.swift`
- [ ] T058 [P] [US3] Write a failing cancel-twice/relaunch/resume keyboard UI journey in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/CancelResumeFlowTests.swift`

### Implementation for User Story 3

- [X] T059 [US3] Implement pre-discovery process stop and exact run-directory `cancel --json` lifecycle without fabricated terminal status in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/CancellationCoordinator.swift`
- [X] T060 [US3] Implement fresh validation, resume review, root reselection, Keychain reacquisition, grant renewal, and exact resume invocation in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ResumeCoordinator.swift`
- [X] T061 [P] [US3] Implement completed/remaining step, permission, provider, limitation, and approval presentation in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ResumeReviewView.swift`
- [X] T062 [US3] Integrate active-run app termination confirmation and bounded graceful cancellation in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/AppTerminationCoordinator.swift`
- [ ] T063 [US3] Make T056–T058 green and record event-prefix/no-repeat resume evidence in `specs/002-macos-desktop-client/quickstart.md`

**Checkpoint**: US3 operates on seeded valid interrupted runs even when US1 UI is replaced by a test
fixture.

---

## Phase 6: User Story 4 - Export a Portable Research Bundle (Priority: P2)

**Goal**: Validate, choose a destination, confirm replacement, invoke engine export, and expose an
honest portable bundle result.

**Independent Test**: Export one valid fixture run, validate it offline, seed a secret/root canary,
and decline replacement of an existing byte fixture.

### Failing Tests for User Story 4

- [ ] T064 [P] [US4] Write failing fresh-validation, allowed-status, native-destination, replacement, containment, cancellation, and result-size tests in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/ExportCoordinatorTests.swift`
- [ ] T065 [P] [US4] Write a failing valid/invalid/replacement export UI journey in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ExportFlowTests.swift`

### Implementation for User Story 4

- [X] T066 [US4] Implement fresh validation plus no-secret/no-network `export --json` command coordination in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ExportCoordinator.swift`
- [X] T067 [US4] Implement native ZIP save panel, replacement confirmation, progress/result/error, and Reveal in Finder UI in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ExportView.swift`
- [X] T068 [US4] Add offline bundle validation and secret/local-root canary assertions in `tests/integration/test_export.py`
- [ ] T069 [US4] Make T064–T065 and Python export security tests green and record checksum/RO-Crate evidence in `specs/002-macos-desktop-client/quickstart.md`

**Checkpoint**: US4 is independently demonstrable from a seeded valid run without New Research.

---

## Phase 7: User Story 5 - Configure Providers and Local Preferences (Priority: P2)

**Goal**: Inspect providers locally, manage three protected credentials, edit only non-secret
defaults, and inject selected secrets into exact child environment keys.

**Independent Test**: List providers offline; add/remove three canary credentials; relaunch; launch
selected fake providers; prove canaries exist only in their child environment entries.

### Failing Tests for User Story 5

- [X] T070 [P] [US5] Write failing provider-discovery decode/refresh/no-network/health tests in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/ProviderListViewModelTests.swift`
- [ ] T071 [P] [US5] Write failing settings allowlist/default validation/no-secret/no-grant restoration tests in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/SettingsViewModelTests.swift`
- [X] T072 [P] [US5] Write failing selected-only OpenAlex/Crossref/model environment injection and post-spawn clearing canaries in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/CredentialEnvironmentTests.swift`
- [ ] T073 [P] [US5] Write a failing provider/settings/secure-entry/removal keyboard UI journey in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ProviderSettingsFlowTests.swift`

### Implementation for User Story 5

- [X] T074 [P] [US5] Implement local-only provider discovery, descriptor/health decoding, credential-requirement mapping, and refresh in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ProviderListViewModel.swift`
- [X] T075 [P] [US5] Implement provider risk/availability/health rows and presence-only credential actions in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ProviderListView.swift`
- [X] T076 [US5] Implement allowlisted non-secret defaults, engine-path selection for development builds, and validation in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/SettingsViewModel.swift`
- [X] T077 [US5] Implement appearance/default/provider/engine settings plus secure add/replace/remove credential sheets in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/SettingsView.swift`
- [X] T078 [US5] Integrate selected-only Keychain fetch/environment creation and immediate retained-value clearing into `macos/OpenScienceDesktop/Sources/OpenScienceCore/EngineInvocationBuilder.swift`
- [ ] T079 [US5] Make T070–T073 green and record offline discovery plus three-canary absence evidence in `specs/002-macos-desktop-client/quickstart.md`

**Checkpoint**: US5 is independently usable with provider fixtures and a fake process runner.

---

## Phase 8: User Story 6 - Accessible Native macOS Workflow (Priority: P3)

**Goal**: Complete primary workflows through standard macOS commands, keyboard, focus, semantic
accessibility, appearance/contrast, reduced motion, and truthful engine diagnostics.

**Independent Test**: Run New Research, evidence inspection, cancellation, and export using keyboard
and accessibility queries under supported appearance/accessibility settings.

### Failing Tests for User Story 6

- [ ] T080 [P] [US6] Write failing app-command enablement, destructive-action shortcut, focus restoration, and window-state safety tests in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/AppCommandTests.swift`
- [ ] T081 [P] [US6] Write failing unavailable/incompatible/external/bundled engine diagnostic UI tests in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/EngineDiagnosticFlowTests.swift`
- [ ] T082 [P] [US6] Write failing keyboard labels/values/status-announcement/reduced-motion/contrast UI checks in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/KeyboardAccessibilityFlowTests.swift`

### Implementation for User Story 6

- [ ] T083 [P] [US6] Implement standard app commands, context enablement, safe shortcuts, focus restoration, and non-secret window restoration in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/AppCommands.swift`
- [X] T084 [US6] Implement engine checking/ready/unavailable/incompatible diagnostics and recovery actions in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/EngineStatusView.swift`
- [X] T085 [P] [US6] Add semantic labels/values/help, coalesced status announcements, focus order, and text alternatives across `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Features/`
- [ ] T086 [P] [US6] Add system appearance, increased-contrast, reduced-motion, minimum-size, and scroll-safe layout behavior in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/RootView.swift`
- [ ] T087 [US6] Make T080–T082 green and record Accessibility Inspector/manual keyboard findings in `specs/002-macos-desktop-client/quickstart.md`

**Checkpoint**: US6 meets the native accessibility contract without relying on pointer-only or
color-only interactions.

---

## Phase 9: Polish and Cross-Cutting Release Gates

**Purpose**: Prove performance, resilience, privacy, reproducible packaging, and specification
traceability across the selected release scope.

- [ ] T088 [P] Add 100-run history and 1,000-evidence report performance fixtures/threshold tests in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/PerformanceAcceptanceTests.swift`
- [ ] T089 [P] Add force-quit, sleep/wake, disk-full/read-only, file replacement, output overflow, and malformed-state acceptance matrices in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/ResilienceAcceptanceTests.swift`
- [ ] T090 [P] Add local support-export preview, size bounds, research-content default exclusion, and central redaction tests in `macos/OpenScienceDesktop/Tests/OpenScienceCoreTests/SupportExportTests.swift`
- [ ] T091 Implement privacy-marked bounded local diagnostics and opt-in redacted support export in `macos/OpenScienceDesktop/Sources/OpenScienceCore/SupportDiagnostics.swift`
- [X] T092 Make `scripts/build-macos-helper.sh` reproducibly assemble a fixed-version optional `Contents/Helpers/openscience` payload without embedding caches, source secrets, or user paths
- [X] T093 Make `macos/OpenScienceDesktop/scripts/build-app.sh` produce/validate a launchable unsandboxed `.app`, prioritize an optional `OPENSCIENCE_HELPER_PATH`, and explicitly report Developer ID signing/notarization/sandbox gates as deferred
- [X] T094 Run Ruff format/check, strict mypy, deterministic pytest, Swift unit/UI tests, and secret scanning; record exact totals and opt-in live exclusions in `specs/002-macos-desktop-client/quickstart.md`
- [ ] T095 Execute the clean external-engine and optional bundled-helper quickstart journeys and record app/engine versions, architectures, commands, hashes, run IDs/counts, and bundle validation in `specs/002-macos-desktop-client/quickstart.md`
- [X] T096 [P] Document build, external-engine setup, optional helper assembly, privacy, and deferred distribution claims in `README.md` and `docs/macos-client.md`
- [ ] T097 Perform final requirements/tasks/constitution traceability and zero-CRITICAL/zero-HIGH consistency audit in `specs/002-macos-desktop-client/checklists/requirements.md`

---

## Dependencies and Execution Order

### Phase Dependencies

- Phase 1 has no implementation dependency.
- Phase 2 depends on Phase 1 and blocks all user stories.
- US1–US6 depend on Phase 2. Each has seeded/fake inputs that permit independent testing.
- US2 may consume US1-created runs in an integrated demo but its independent test uses seeded runs.
- US3/US4 use seeded valid run fixtures and do not require the US1 composer implementation.
- US5 uses provider/process fakes and does not require a completed run.
- US6 can exercise minimal harness screens, then integrates across selected stories.
- Phase 9 depends on all user stories selected for the release.

### User Story Dependency Graph

```text
Setup -> Foundation -> US1 (offline MVP)
                    -> US2 (seeded history/evidence)
                    -> US3 (seeded cancel/resume)
                    -> US4 (seeded export)
                    -> US5 (provider/settings fixtures)
                    -> US6 (native/accessibility harness)

US1 + US2 + US3 + US4 + US5 + US6 -> Cross-cutting release gates
```

## Parallel Opportunities

### Foundation

After T001–T007, T008–T018 target separate test files and may be authored in parallel. After their
red state is recorded, domain, terminal decoder, workspace, Keychain, and persistence
implementations may proceed in parallel; process/event/repository integration remains ordered.

### US1

```text
T031 composer tests       -> T036/T037 composer
T032 plan tests           -> T038/T039 plan review
T033 grant tests          -> T040 network confirmation
T034 coordinator tests    -> T041/T042 execution/progress
T035 UI test              -> T043 integration
```

### US2

```text
T045 history tests        -> T050/T051 history
T046 projection tests     -> T052/T053 report/evidence
T047 URL tests            -> T054 external URL policy
T048/T049 UI tests        -> integration after above
```

### US3

```text
T056 cancellation tests   -> T059/T062 cancellation/lifecycle
T057 resume tests         -> T060/T061 resume
T058 UI test              -> integration after both tracks
```

### US4

T064 coordinator tests and T065 UI tests can be authored in parallel; T066/T067 implement separate
coordination/presentation files before the cross-language security assertion in T068.

### US5

T070–T073 are parallel test tracks. Provider views T074/T075, settings T076/T077, and invocation
environment T078 target independent files before story integration.

### US6

T080–T082 are parallel; commands, engine diagnostics, semantic accessibility, and appearance layout
target separate files in T083–T086.

## Implementation Strategy

### MVP First

1. Complete Setup and Foundation with every boundary test green.
2. Complete US1 using only local fixture/local-root providers and extractive synthesis.
3. Stop and demonstrate a validated offline run with live event-file progress.

### Incremental Delivery

1. Add US2 so the MVP's output becomes durable and auditable.
2. Add US3 and US4 for recovery and portable artifacts.
3. Add US5 without weakening per-attempt network authority.
4. Complete US6 and cross-cutting resilience/privacy/performance gates.
5. Produce a launchable unsandboxed app; validate the optional self-contained helper variant; retain
   explicit deferred claims for sandboxing, Developer ID signing, notarization, and App Store
   distribution.

## Requirement Traceability

| Requirement / outcome | Primary tasks |
|-----------------------|---------------|
| FR-001–FR-003 | T001–T007, T021, T029, T043, T083–T086, T093 |
| FR-004–FR-008 | T031–T040, T043–T044 |
| FR-009–FR-015 | T009, T011–T014, T022–T025, T034, T041–T044 |
| FR-016–FR-023 | T017–T018, T027–T028, T045–T055 |
| FR-024–FR-028 | T056–T063 |
| FR-029–FR-031 | T064–T069 |
| FR-032–FR-040 | T008–T009, T016, T019, T026, T033, T070–T079 |
| FR-041–FR-045 | T010–T014, T021–T25, T034, T041, T056, T080–T087, T089 |
| FR-046–FR-048 | T080–T087 |
| FR-049–FR-050 | T009, T011, T016, T026, T090–T091, T094–T095 |
| SC-001–SC-003 | T035, T044, T046, T049, T052–T055, T095 |
| SC-004, SC-012 | T045, T050–T055, T088 |
| SC-005–SC-006 | T056–T063 |
| SC-007 | T009, T064–T069, T094–T095 |
| SC-008–SC-009 | T008–T009, T016, T019, T026, T033, T040, T070–T079, T094 |
| SC-010 | T035, T049, T058, T065, T073, T080–T087 |
| SC-011 | T012–T014, T034, T041, T048, T056, T089 |
| SC-013–SC-014 | T070, T074–T075, T090–T095 |

## Task Completion Rules

- Preserve the exact checklist syntax and sequential IDs.
- For each story, observe its listed tests fail for the intended missing behavior before implementing.
- Never weaken or delete an existing test to obtain green without documenting a changed requirement.
- Do not use live credentials/providers in deterministic tests or default CI.
- Do not mark a process result completed until recorded state validation/reconciliation passes.
- Do not add a secret to argv, model config, preferences, logs, fixture artifacts, or committed output.
- Do not claim sandboxing, security-scoped bookmarks, Developer ID signing, notarization,
  auto-update, App Store, or Gatekeeper readiness from a successful development/direct build.
- Commit after a tested logical slice and stop at any checkpoint for independent demonstration.
