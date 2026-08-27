---

description: "TDD implementation tasks for the native macOS conversation research workbench"
---

# Tasks: Conversation Research Workbench

**Input**: Design documents from `specs/003-conversation-workbench/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: TDD is mandatory under FR-035 and the constitution. In every phase, write the named tests,
run them, and observe the intended red result before implementation. A task is complete only when
its direct tests and relevant existing feature-001/002 regressions pass.

**Organization**: Setup and foundational phases establish typed, safe presentation boundaries.
Each user-story phase remains independently demonstrable with deterministic fixtures. Exact paths
and FR/SC references are part of each task contract.

## Format: `[ID] [P?] [Story?] Description with file path`

- **[P]**: May run in parallel because it targets different files and has no incomplete dependency.
- **[Story]**: Required only for user-story phases and maps to `US1`–`US6` in [spec.md](spec.md).

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Establish deterministic fixture, test, and source structure without changing existing
engine/runtime behavior.

- [x] T001 Add the conversation logic/UI/test source groups to `macos/OpenScienceDesktop/Package.swift`
- [ ] T002 [P] Add the selected-option-3 deterministic fixture schema and seeded data for FR-002/SC-002 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/Fixtures/workbench-option-3.json`
- [ ] T003 [P] Add corrupt/newer/large conversation envelope and managed-run reference fixtures for FR-024–FR-027/SC-007 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/Fixtures/ConversationStore/`
- [ ] T004 [P] Add generated 200-conversation, 1,000-timeline, and 1,000-evidence fixture builders for FR-034/SC-004/SC-006 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/WorkbenchFixtureFactory.swift`
- [ ] T005 Record the pre-feature Swift/Python green baseline and selected mock dimensions in `specs/003-conversation-workbench/quickstart.md`

**Checkpoint**: Existing code still builds/tests; all new fixtures are deterministic, sanitized,
and make no scientific assertion.

---

## Phase 2: Foundational Conversation Boundaries

**Purpose**: Define and test safe models, persistence, timeline projection, engine identity binding,
preview routing, and one-active-run coordination used by every story.

**⚠️ CRITICAL**: T006–T014 MUST fail for the intended missing behavior before T015 begins.

### Failing Foundational Tests

- [ ] T006 [P] Write failing project/conversation/turn/ID/envelope/state-transition tests for FR-003/FR-016/FR-024–FR-026 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationModelsTests.swift`
- [ ] T007 [P] Write failing strict UTF-8/schema/size/duplicate/timestamp/relationship decode tests for FR-024/FR-027 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationStoreTests.swift`
- [ ] T008 [P] Write failing confinement tests for traversal, absolute reference, symlink, non-regular file, parent replacement, and run-root escape under FR-026/FR-027 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationStoreSecurityTests.swift`
- [ ] T009 [P] Write failing injected-write tests for temporary creation, partial write, sync, replace, revision conflict, duplicate append, and last-complete recovery under SC-007 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationStoreRecoveryTests.swift`
- [ ] T010 [P] Write failing canary tests proving credentials, environments, grants, approvals, raw diagnostics, evidence/report bodies, and active-process claims are non-persistable under FR-025/SC-005/SC-011 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationPersistencePrivacyTests.swift`
- [ ] T011 [P] Write failing pure timeline taxonomy/provenance/stable-ID/unknown-event/terminal-state tests for FR-006/FR-007/FR-013/FR-015 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationTimelineProjectorTests.swift`
- [ ] T012 [P] Write failing exact conversation/turn/attempt/plan/run stale-result binding tests for FR-010–FR-016 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/WorkbenchCoordinatorTests.swift`
- [ ] T013 [P] Write failing Context/Plan/Evidence/Artifact exact-selection and missing/duplicate/unsafe reference tests for FR-017–FR-022 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/PreviewRouterTests.swift`
- [ ] T014 [P] Write failing one-active-mutation cross-conversation and read-only concurrency tests for FR-014 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/WorkbenchActiveRunTests.swift`

### Foundational Implementation

- [ ] T015 Implement validated workspace/project/conversation/turn/message/draft/run-binding/preview/session-issue value types from `data-model.md` in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/ConversationModels.swift`
- [ ] T016 Implement actor-isolated schema-versioned envelope/workspace/index APIs and revision/idempotence rules from `contracts/session-persistence.md` in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/ConversationStore.swift`
- [ ] T017 Implement confined bounded regular-file reads and crash-safe same-directory atomic write/replace recovery for FR-024/FR-027 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/ConversationStore.swift`
- [ ] T018 Implement deterministic grouping/search/index rebuild, corrupt-envelope isolation, and transient-hint downgrade for FR-004/FR-005/FR-027 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/ConversationStore.swift`
- [ ] T019 Implement central persistence allowlist/forbidden-field/canary validation for FR-025/SC-011 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/ConversationStore.swift`
- [ ] T020 Implement pure typed timeline projection with provenance/action eligibility and no scientific prose invention for FR-006/FR-007/FR-013/FR-015 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/ConversationTimelineProjector.swift`
- [ ] T021 Implement exact workbench-to-feature-002 plan/run/reconcile identity adapter and stale-result rejection from `contracts/engine-mapping.md` in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/WorkbenchCoordinator.swift`
- [ ] T022 Implement exact typed preview routing and safe empty/integrity selections for FR-017–FR-022 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/PreviewRouter.swift`
- [ ] T023 Integrate the coordinator/store/projector lifecycle without duplicating CLI/run authority in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/AppModel.swift`
- [ ] T024 Run T006–T014 plus existing feature-002 Swift and deterministic Python suites and record the foundational green baseline in `specs/003-conversation-workbench/quickstart.md`

**Checkpoint**: Conversation data is durable but non-authoritative; no story UI is needed to prove
store, binding, projection, preview, and one-active-run safety.

---

## Phase 3: User Story 1 - Conversation-First Research Shell (Priority: P1) 🎯 MVP

**Goal**: Make the selected option 3 workbench the default native window with durable/searchable
sidebar, center timeline, and bottom composer; the old form is no longer primary.

**Independent Test**: Seed/create/search/select/archive/restore/rename/delete conversations, switch
drafts, relaunch, and observe safe restoration in the three-column shell without starting a run.

### Failing Tests for User Story 1

- [ ] T025 [P] [US1] Write failing project create/select/rename/archive plus Today/Yesterday/Earlier grouping, stable sort, search, empty/no-match, conversation archive/restore/rename/delete tests for FR-003–FR-005 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationSidebarTests.swift`
- [ ] T026 [P] [US1] Write failing non-secret per-conversation draft/selection/layout restoration and no-authority-relaunch tests for FR-023–FR-025 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/WorkbenchRestorationTests.swift`
- [ ] T027 [P] [US1] Write failing three-pane root/default-route/legacy-form-not-primary tests for FR-001/FR-002 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/WorkbenchRootTests.swift`
- [ ] T028 [P] [US1] Write failing composer multiline/send-once/blocked-state/advanced-fields/attachment-hint tests for FR-008–FR-010 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationComposerTests.swift`
- [ ] T029 [P] [US1] Write a failing create/select/search/archive/relaunch keyboard journey for SC-001 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationShellFlowTests.swift`

### Implementation for User Story 1

- [ ] T030 [P] [US1] Implement option-3 surface, spacing, status, typography, card, and focus tokens without copied brand assets for FR-002/FR-030 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/WorkbenchTheme.swift`
- [ ] T031 [US1] Implement local project selector/create/select/rename/archive, New Conversation, scoped search, date groups, rows, empty/no-match state, and selection for FR-003–FR-005 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/ConversationSidebar.swift`
- [ ] T032 [US1] Implement rename/archive/restore/confirmed metadata-delete menus that preserve engine runs for FR-004/FR-028 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/ConversationSidebar.swift`
- [ ] T033 [US1] Implement runtime/model/tools/network footer routes without persistent authorization claims for FR-003/FR-029 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/ConversationSidebar.swift`
- [ ] T034 [P] [US1] Implement lazy stable-ID timeline, provenance headers, empty state, preserved reader position, and Jump to Latest for FR-006/FR-007/FR-034 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/ConversationTimeline.swift`
- [ ] T035 [US1] Implement pinned multiline composer, Command-Return send-once, attachments/root chooser, model state, and block reasons for FR-008/FR-010 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/ConversationTimeline.swift`
- [ ] T036 [US1] Implement compact advanced-settings presentation for every feature-002 draft field and plan-expiration callbacks for FR-009/FR-011 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/ConversationTimeline.swift`
- [ ] T037 [US1] Wire project and conversation create/search/select/archive/restore/rename/delete/draft operations through the typed store in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/AppModel.swift`
- [ ] T038 [US1] Replace stable-destination form routing with the three-pane workbench and explicit pane bindings for FR-001/FR-023 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/RootView.swift`
- [ ] T039 [US1] Route feature-002 Providers/Settings views from sidebar footer/secondary presentation without restoring them as primary columns in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/RootView.swift`
- [ ] T040 [US1] Add Command-N, Command-K, contextual Command-Return, safe Escape, and pane-toggle command wiring for FR-033 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/OpenScienceDesktopApp.swift`
- [ ] T041 [US1] Make T025–T029 green and record the independently usable conversation-shell acceptance evidence in `specs/003-conversation-workbench/quickstart.md`

**Checkpoint**: US1 is a useful local conversation workspace with no research execution dependency.

---

## Phase 4: User Story 2 - Governed Research Inside the Timeline (Priority: P1)

**Goal**: Deliver message → inline plan → inline network approval → recorded run progress → truthful
result/error/recovery and follow-up turns without weakening engine authority.

**Independent Test**: Run one offline fixture lifecycle and one declined network fixture entirely in
the center timeline, prove exact events/results and zero request on decline, then append a follow-up.

### Failing Tests for User Story 2

- [ ] T042 [P] [US2] Write failing send→local-plan-only, exact one-message, plan identity, stale result, reject/edit expiration tests for FR-010/FR-011 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/InlinePlanFlowTests.swift`
- [ ] T043 [P] [US2] Write failing provider/outbound-category/risk/limits display, decline-zero-request, exact grant, risk/limit change, and no-relaunch-grant tests for FR-012/SC-005 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/InlineNetworkApprovalTests.swift`
- [ ] T044 [P] [US2] Write failing unique binding/event-only progress/unknown-event/incomplete-tail/gap/duplicate/terminal provisional tests for FR-013/FR-015 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/InlineRunCardTests.swift`
- [ ] T045 [P] [US2] Write failing completed/partial/failed/cancelled/interrupted/invalid result text/action matrix tests for FR-015/FR-036/SC-003 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/InlineTerminalCardsTests.swift`
- [ ] T046 [P] [US2] Write failing follow-up/multiple-attempt/prior-immutability and active-run-elsewhere tests for FR-014/FR-016 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationTurnFlowTests.swift`
- [ ] T047 [P] [US2] Write a failing offline and network-decline end-to-end timeline journey for US2/SC-003/SC-005 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationResearchFlowTests.swift`

### Implementation for User Story 2

- [ ] T048 [P] [US2] Implement semantic inline plan and exact immutable five/variable-step review presentation for FR-011 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/ConversationCards.swift`
- [ ] T049 [P] [US2] Implement blocking inline network card with exact one-time consent copy/actions and no default Allow focus for FR-012 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/ConversationCards.swift`
- [ ] T050 [P] [US2] Implement bound run progress card with exact step states, elapsed time, counts, activity, cancellation, and safe meaningful event for FR-013 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/ConversationCards.swift`
- [ ] T051 [P] [US2] Implement validated result, partial/limitations/citations, and safe error/recovery cards for FR-007/FR-015/FR-036 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/ConversationCards.swift`
- [ ] T052 [US2] Integrate typed cards into the chronological timeline with in-place high-frequency updates and stable focus for FR-006/FR-032 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/ConversationTimeline.swift`
- [ ] T053 [US2] Bind composer send to atomic message append then existing local plan generation with exact turn identity for FR-010 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/WorkbenchCoordinator.swift`
- [ ] T054 [US2] Bind plan rejection/edit expiration and explicit approval to the existing reviewed-plan coordinator for FR-011 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/WorkbenchCoordinator.swift`
- [ ] T055 [US2] Bind inline Reject/Allow to existing one-time grant identity/consumption and zero-request denial for FR-012 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/WorkbenchCoordinator.swift`
- [ ] T056 [US2] Bind unique-workspace execution/event cursor/terminal reconciliation to one originating turn and run card for FR-013–FR-015 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/AppModel.swift`
- [ ] T057 [US2] Implement application-wide active-run ownership and deep link from blocked conversations to the owner for FR-014 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/AppModel.swift`
- [ ] T058 [US2] Implement follow-up turn creation and immutable prior-turn/attempt projection for FR-016 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/WorkbenchCoordinator.swift`
- [ ] T059 [US2] Coalesce meaningful status announcements and preserve focus as card actions reconcile for FR-032 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/ConversationCards.swift`
- [ ] T060 [US2] Make T042–T047 green and record exact request/plan/run/event/result plus zero-request evidence in `specs/003-conversation-workbench/quickstart.md`

**Checkpoint**: US2 independently conducts a truthful offline run and denies network without a
request, entirely within a conversation timeline.

---

## Phase 5: User Story 3 - Context, Plan, Evidence, and Artifact Preview (Priority: P1)

**Goal**: Keep conversation visible while exact context, immutable plan, evidence/source joins, and
inert artifacts are selected and inspected in the collapsible right pane.

**Independent Test**: From a seeded validated run, activate a citation and PDF/report, switch all
tabs, collapse/reopen, and prove exact IDs, safe inert content, and stable selection offline.

### Failing Tests for User Story 3

- [ ] T061 [P] [US3] Write failing Context provenance/identity/hash/config/no-fabricated-field tests for FR-018 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ContextPreviewTests.swift`
- [ ] T062 [P] [US3] Write failing immutable plan/step/event exact-ID join and unknown/missing-step tests for FR-019 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/PlanPreviewTests.swift`
- [ ] T063 [P] [US3] Write failing 1,000 exact claim/evidence/source selection, missing/duplicate join, stance/status/attribution/license tests for FR-020/SC-004 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/EvidencePreviewTests.swift`
- [ ] T064 [P] [US3] Write failing bounded Markdown/PDF/unsupported/missing/oversized/replaced artifact and active-content-inertness tests for FR-021/FR-022 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ArtifactPreviewTests.swift`
- [ ] T065 [P] [US3] Write failing tab/count/explicit-selection/empty-state/collapse-safe-restoration tests for FR-017/FR-023 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/InspectorPaneTests.swift`
- [ ] T066 [P] [US3] Write a failing citation→exact Evidence and artifact→preview keyboard journey for US3/SC-004 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationPreviewFlowTests.swift`

### Implementation for User Story 3

- [ ] T067 [P] [US3] Implement stable Context/Plan/Evidence/Artifacts tab strip, counts, collapse, restore, and selection-specific empty states for FR-017/FR-023 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/InspectorPane.swift`
- [ ] T068 [P] [US3] Implement provenance-labeled conversation/turn/run/provider/model/limit/hash/time Context presentation for FR-018 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/InspectorPane.swift`
- [ ] T069 [P] [US3] Implement immutable ordered plan plus exact recorded step-state presentation for FR-019 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/InspectorPane.swift`
- [ ] T070 [US3] Implement exact evidence passage/locator/stance/claim/source/retrieval/license and warning presentation for FR-020 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/InspectorPane.swift`
- [ ] T071 [US3] Implement previous/next source navigation and exact count without fallback joins for FR-020/SC-004 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/InspectorPane.swift`
- [ ] T072 [US3] Implement bounded inert native Markdown and PDF preview plus unsupported/invalid metadata fallback for FR-021 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/InspectorPane.swift`
- [ ] T073 [US3] Reuse existing HTTP(S)-only host confirmation and retrieved-instruction inertness for FR-022 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/InspectorPane.swift`
- [ ] T074 [US3] Map citation/artifact actions to exact typed preview selections instead of passage/path payloads for FR-017/FR-020/FR-021 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/PreviewRouter.swift`
- [ ] T075 [US3] Recheck run/artifact identity, containment, size, and validation through existing repository before preview/action for FR-021/FR-026/FR-027 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/PreviewRouter.swift`
- [ ] T076 [US3] Connect result citations and artifact summaries to the preview router in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/ConversationCards.swift`
- [ ] T077 [US3] Persist only safe selected tab/record IDs/clamped preview width and clear stale cross-conversation selection for FR-023–FR-025 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/AppModel.swift`
- [ ] T078 [US3] Integrate preview column visibility and focus-safe restore control into the primary split for FR-023/FR-031 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/RootView.swift`
- [ ] T079 [US3] Add semantic headings/lists/tab values/warning severities for the full inspector under FR-032 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/InspectorPane.swift`
- [ ] T080 [US3] Make T061–T066 green and record exact 1,000-link, inert preview, and collapse/restoration evidence in `specs/003-conversation-workbench/quickstart.md`

**Checkpoint**: US3 is independently demonstrable from seeded validated run artifacts with no
conversation execution or network requirement.

---

## Phase 6: User Story 4 - Durable Searchable Multi-Turn Sessions (Priority: P2)

**Goal**: Rebuild 200 multi-turn conversations and their safe run references after relaunch/crash,
isolate corrupt state, preserve engine immutability, and support continued research.

**Independent Test**: Seed scale and failure fixtures, interrupt every write stage, relaunch/rebuild,
and prove ordering/search/status/reference safety and unaffected-conversation availability offline.

### Failing Tests for User Story 4

- [ ] T081 [P] [US4] Write failing 0/200/10,000-bounded envelope scan, index rebuild/staleness, date grouping, and deterministic search tests for FR-004/FR-005/FR-034 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationIndexScaleTests.swift`
- [ ] T082 [P] [US4] Write failing missing/replaced/symlinked/mismatched/invalid managed-run reference and read-only issue tests for FR-026/FR-027 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationRunReferenceTests.swift`
- [ ] T083 [P] [US4] Write failing relaunch projection tests proving transient state downgrade and fresh validation before actions for FR-025/FR-027 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationRelaunchTests.swift`
- [ ] T084 [P] [US4] Write failing metadata-delete/run-preservation and archive/restore byte-identity tests for FR-028 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationDeletionTests.swift`
- [ ] T085 [P] [US4] Write a failing crash/corrupt/newer-schema/multi-turn/follow-up recovery journey for US4/SC-007 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationRecoveryFlowTests.swift`

### Implementation for User Story 4

- [ ] T086 [US4] Implement bounded parallel-safe envelope scan and deterministic rebuildable index for FR-004/FR-005/FR-034 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/ConversationStore.swift`
- [ ] T087 [US4] Implement per-envelope corrupt/newer/oversized isolation and safe `SessionIssue` rows for FR-027/SC-007 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/ConversationStore.swift`
- [ ] T088 [US4] Implement lazy existing-repository run resolution and current validation projection on open/action for FR-026/FR-027 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/WorkbenchCoordinator.swift`
- [ ] T089 [US4] Implement restored transient-hint downgrade and never-restore grant/approval/process behavior for FR-025/SC-005 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/AppModel.swift`
- [ ] T090 [US4] Implement multi-turn/attempt reconstruction with immutable prior items and broken-reference cards for FR-016/FR-027 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/ConversationTimelineProjector.swift`
- [ ] T091 [US4] Implement archive/restore/delete index consistency while preserving exact engine/export bytes for FR-028 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/ConversationStore.swift`
- [ ] T092 [US4] Implement store read-only/disk-full/parent-replacement user outcomes and valid next actions for FR-036 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/AppModel.swift`
- [ ] T093 [US4] Optimize lazy sidebar/timeline/index projections for 200/1,000/1,000 scale without record loss for FR-034/SC-006 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/ConversationTimelineProjector.swift`
- [ ] T094 [US4] Make T081–T085 green and record crash recovery, corruption isolation, engine-byte preservation, and p95 data in `specs/003-conversation-workbench/quickstart.md`

**Checkpoint**: US4 independently restores/rebuilds long-lived local conversations and keeps every
scientific record external, immutable, and revalidated.

---

## Phase 7: User Story 5 - Preserve Existing Research Controls (Priority: P2)

**Goal**: Route cancel/resume/validate/inspect/replay/export/providers/settings through the new
workbench with no feature-002 security, privacy, integrity, or authority regression.

**Independent Test**: Execute the full deterministic feature-002 lifecycle through inline cards and
preview, including cancel twice, relaunch/resume, replay/export, provider/Keychain, and invalid run.

### Failing Tests for User Story 5

- [ ] T095 [P] [US5] Write failing pre/post-discovery exact cancel/idempotence/no-fake-terminal inline-card tests for FR-029 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/WorkbenchCancellationTests.swift`
- [ ] T096 [P] [US5] Write failing fresh resume validation/roots/credentials/network/provider/completed-step attempt-binding tests for FR-029 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/WorkbenchResumeTests.swift`
- [ ] T097 [P] [US5] Write failing credential-free/no-network validate/inspect/replay/export routing and invalid-action tests for FR-029 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/WorkbenchRunActionsTests.swift`
- [ ] T098 [P] [US5] Write failing local provider/runtime/settings/Keychain presence-only route and selected-secret canary tests for FR-025/FR-029 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/WorkbenchProviderSettingsTests.swift`
- [ ] T099 [P] [US5] Write a failing cancel/resume/validate/replay/export/provider/settings keyboard regression journey for US5/SC-010 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/WorkbenchLegacyFlowsTests.swift`

### Implementation for User Story 5

- [ ] T100 [US5] Route inline Cancel through existing exact pre/post-discovery lifecycle and display request versus recorded status for FR-029 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/WorkbenchCoordinator.swift`
- [ ] T101 [US5] Route inline Resume through existing fresh review/root/credential/network/provider path and append a new exact attempt binding for FR-016/FR-029 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/WorkbenchCoordinator.swift`
- [ ] T102 [US5] Route Validate/Inspect/Replay from result/error/preview actions through existing credential-free CLI/repository paths for FR-029 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/WorkbenchCoordinator.swift`
- [ ] T103 [US5] Route Export through fresh validation/native save/replacement/engine bundle result and exact artifact card update for FR-021/FR-029 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/WorkbenchCoordinator.swift`
- [ ] T104 [US5] Integrate existing Resume review and Export destination/result presentations with originating timeline focus/context in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/ConversationCards.swift`
- [ ] T105 [US5] Route runtime footer provider discovery/health/risk/Keychain presence and credential sheets without network calls in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/ConversationSidebar.swift`
- [ ] T106 [US5] Route Settings/engine/model/tool/network summaries and retain local-evidence/network-model privacy block for FR-029 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/RootView.swift`
- [ ] T107 [US5] Preserve integrity-invalid read-only action removal across every card/preview route for FR-015/FR-027/FR-029 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/PreviewRouter.swift`
- [ ] T108 [US5] Make T095–T099 and all feature-002 bridge/security/resume/export tests green and record full regression evidence in `specs/003-conversation-workbench/quickstart.md`

**Checkpoint**: US5 proves the information-architecture change removed no validated capability and
weakened no authority/security boundary.

---

## Phase 8: User Story 6 - Faithful Adaptive Accessible Native Workspace (Priority: P3)

**Goal**: Meet option 3 geometry/perceptual fidelity and native keyboard/VoiceOver/appearance/
minimum-size behavior while keeping center work usable through pane collapse.

**Independent Test**: Capture seeded dark state at 1487 × 1058, compare to the sole target, then
complete the primary journey at 1180 × 720 with keyboard/VoiceOver and accessibility settings.

### Failing Tests for User Story 6

- [ ] T109 [P] [US6] Write failing reference/minimum column-width, center-invariant, divider-clamp, and preview-first-collapse geometry tests for FR-030/FR-031 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationWorkbenchVisualTests.swift`
- [ ] T110 [P] [US6] Write failing deterministic capture-seed and sole-target ≥0.90 masked comparison tests for FR-002/SC-002 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationWorkbenchSnapshotTests.swift`
- [ ] T111 [P] [US6] Write failing Command-N/K/Return/F/E/comma, pane-toggle, multiline Enter, and safe Escape tests for FR-033 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/WorkbenchCommandTests.swift`
- [ ] T112 [P] [US6] Write failing semantic role/name/value/help/order/status/coalescing/focus-reconciliation tests for FR-032 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationWorkbenchAccessibilityTests.swift`
- [ ] T113 [P] [US6] Write failing dark/light/system/increased-contrast/reduced-motion/larger-text behavior tests for FR-032 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/WorkbenchAppearanceTests.swift`
- [ ] T114 [P] [US6] Write failing 200/1,000/1,000 p95 selection/search/scroll/link benchmarks for FR-034/SC-004/SC-006 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationWorkbenchPerformanceTests.swift`
- [ ] T115 [P] [US6] Write a failing keyboard-only minimum-size conversation→plan→run→evidence→export journey for US6/SC-008/SC-009 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/ConversationWorkbenchKeyboardFlowTests.swift`

### Implementation for User Story 6

- [ ] T116 [P] [US6] Implement reference geometry, 8–16 point rhythm, dividers, compact cards/tabs/composer hierarchy, and semantic appearance tokens for FR-030 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/WorkbenchTheme.swift`
- [ ] T117 [US6] Implement preview-first then sidebar adaptive collapse, clamped divider restoration, and explicit focus-safe restore controls for FR-023/FR-031 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/RootView.swift`
- [ ] T118 [P] [US6] Add semantic labels/values/help/headings/lists/status text and non-color warnings across FR-032 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/ConversationSidebar.swift`
- [ ] T119 [P] [US6] Add semantic timeline/card/composer focus order, action disappearance recovery, and coalesced announcements for FR-032 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/ConversationTimeline.swift`
- [ ] T120 [P] [US6] Add semantic tab/evidence/artifact values, severity, and collapse focus behavior for FR-032 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/InspectorPane.swift`
- [ ] T121 [US6] Implement complete menu/shortcut availability and safe Escape behavior for FR-033 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/OpenScienceDesktopApp.swift`
- [ ] T122 [US6] Implement larger-text scroll safety, increased-contrast treatment, and reduced-motion transitions without hidden progress for FR-032 in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/ConversationUI/WorkbenchTheme.swift`
- [ ] T123 [P] [US6] Implement deterministic dark reference capture with fixed fixture/locale/time and no live claims in `macos/OpenScienceDesktop/scripts/capture-workbench-reference.sh`
- [ ] T124 [P] [US6] Implement geometry and masked perceptual comparison against only `design/conversation-workbench/selected-option-3.png` in `macos/OpenScienceDesktop/scripts/compare-workbench-reference.sh`
- [ ] T125 [US6] Optimize lazy sidebar/timeline/evidence selection to meet p95 targets without dropping/truncating records in `macos/OpenScienceDesktop/Sources/OpenScienceDesktop/Logic/ConversationTimelineProjector.swift`
- [ ] T126 [US6] Make T109–T115 green and record capture similarity, geometry, Accessibility Inspector, VoiceOver, minimum-size, appearance, and performance evidence in `specs/003-conversation-workbench/quickstart.md`

**Checkpoint**: US6 meets the selected visual target and native accessibility/adaptive contract;
screenshot similarity is not used as a substitute for functional/accessibility evidence.

---

## Phase 9: Polish and Cross-Cutting Release Gates

**Purpose**: Prove complete traceability, clean-room implementation, security, performance,
reproducibility, packaging, and usability across the requested end state.

- [ ] T127 [P] Add explicit fixture assertions that retrieved instructions/HTML/script/file URLs remain inert in every timeline/preview path for FR-021/FR-022 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/WorkbenchRetrievedContentSecurityTests.swift`
- [ ] T128 [P] Add candidate conversation/index/layout/support/export secret-and-authority canary scanning for FR-025/SC-011 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/WorkbenchPersistenceSecretScanTests.swift`
- [ ] T129 [P] Add repository provenance scan assertions for no copied external logo/name/string/source/screenshot asset under FR-002/SC-011 in `macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/WorkbenchCleanRoomTests.swift`
- [ ] T130 Run the fresh deterministic Python suite, Ruff format/check, strict mypy, live-test deselection, and record results in `specs/003-conversation-workbench/quickstart.md`
- [ ] T131 Run the full Swift suite, formatter lint, debug/release builds, and record exact counts/results in `specs/003-conversation-workbench/quickstart.md`
- [ ] T132 Run a fresh offline workbench run plus validate/inspect/replay/cancel/resume/export and record IDs/hashes/results in `specs/003-conversation-workbench/quickstart.md`
- [ ] T133 Run the 200/1,000/1,000 performance gate and 1,000 exact citation joins on the declared test Mac and record p95/max/mismatch evidence in `specs/003-conversation-workbench/quickstart.md`
- [ ] T134 Conduct the five-participant moderated usability check for SC-001 and record anonymized task-completion results in `specs/003-conversation-workbench/quickstart.md`
- [ ] T135 Conduct dark reference, minimum-size, light/system, increased-contrast, reduced-motion, larger-text, keyboard, VoiceOver, and focus manual acceptance and record evidence in `specs/003-conversation-workbench/quickstart.md`
- [ ] T136 Update macOS usage/security/development-boundary documentation for the conversation workbench in `docs/macos-client.md`
- [ ] T137 Update feature status and complete the authoritative release gate table only from fresh evidence in `specs/003-conversation-workbench/spec.md` and `specs/003-conversation-workbench/quickstart.md`
- [ ] T138 Build and smoke-test the self-contained development `.app` without signing/notarization/sandbox claims using `macos/OpenScienceDesktop/scripts/build-app.sh`
- [ ] T139 Run `.specify/scripts/bash/check-prerequisites.sh --json --require-tasks --include-tasks` plus `$speckit-analyze`, resolve all CRITICAL/HIGH findings, and record 100% buildable FR/SC coverage in `specs/003-conversation-workbench/quickstart.md`
- [ ] T140 Review the pull request against all five constitution principles, selected-mock sole-target/no-copy rule, and feature-001/002 non-regression evidence in `specs/003-conversation-workbench/quickstart.md`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 Setup** has no dependencies.
- **Phase 2 Foundation** depends on Setup and blocks all stories.
- **US1, US2, and US3 (P1)** can be tested independently after Foundation using their own fixtures;
  recommended integration order is US1 → US2 → US3 because they compose the requested workspace.
- **US4 and US5 (P2)** depend on Foundation and may proceed in parallel after stable store/engine
  contracts; final UI integration uses the P1 shell.
- **US6 (P3)** depends on the desired P1/P2 surfaces being present so fidelity/accessibility tests
  cover real controls rather than placeholders.
- **Polish** depends on all in-scope stories and never converts pending manual evidence into pass.

### User Story Independence

- **US1**: Uses only conversation fixtures; no engine run required.
- **US2**: Uses one seeded conversation plus deterministic engine/event fixtures; preview not required.
- **US3**: Uses seeded validated run detail; sending/execution not required.
- **US4**: Uses store/run-reference fixtures; live UI execution not required.
- **US5**: Uses seeded eligible runs/fake bridge; conversation creation not required.
- **US6**: Uses the selected option 3 seeded state and deterministic accessibility/performance data.

### Within Every Story

1. Write each listed test and observe the intended red state.
2. Implement models/services/projections before UI integration.
3. Make direct tests green, then run affected feature-002 regressions.
4. Execute the independent acceptance criterion and record authoritative evidence.

## Parallel Examples

### User Story 1

```text
T025 sidebar behavior tests || T026 restoration tests || T027 root tests || T028 composer tests
T030 theme tokens || T034 timeline lazy/provenance presentation
```

### User Story 2

```text
T042 plan tests || T043 network tests || T044 run tests || T045 terminal tests || T046 turn tests
T048 plan card || T049 network card || T050 run card || T051 terminal/error cards
```

### User Story 3

```text
T061 context tests || T062 plan tests || T063 evidence tests || T064 artifact tests || T065 pane tests
T068 context presentation || T069 plan presentation
```

### User Stories 4 and 5

```text
US4 store/recovery implementation may proceed in parallel with US5 feature-002 action routing after Phase 2.
```

## Implementation Strategy

### MVP First

1. Complete Setup and Foundation.
2. Complete US1 and demonstrate the option 3 conversation shell locally.
3. Add US2 to produce the first governed offline conversation research lifecycle.
4. Add US3 to satisfy the complete three-pane requested interaction.
5. Stop and audit the P1 end state before recovery/control/fidelity expansion.

### Incremental Delivery

- US1: conversation-first shell, safely durable with no engine dependency.
- US2: plan/network/run/result lifecycle inside the timeline.
- US3: synchronized research preview and collapsible third pane.
- US4: robust scale/crash/relaunch/multi-turn behavior.
- US5: all existing desktop capabilities through the new shell.
- US6: binding visual, native adaptive, keyboard, accessibility, and performance proof.

## Format Validation

All 140 tasks use the required checkbox + sequential `T###` + optional `[P]` + story-only `[US#]`
format and include at least one exact repository file/directory path. No story implementation task
precedes its story's red-test tasks.
