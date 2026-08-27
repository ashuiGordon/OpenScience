# Implementation Plan: Conversation Research Workbench

**Feature Directory**: `specs/003-conversation-workbench` | **Date**: 2026-08-27 | **Spec**:
[spec.md](spec.md)

**Input**: Feature specification from `specs/003-conversation-workbench/spec.md`

## Summary

Replace the native macOS client's form-first `NavigationSplitView` root with a conversation-first,
three-column research workbench faithful to the selected option 3 mock. The left column becomes a
durable/searchable conversation sidebar, the center becomes a typed timeline plus composer and
inline plan/network/run/result cards, and the right becomes a collapsible Context/Plan/Evidence/
Artifacts preview. Reuse the existing `AppModel`, CLI bridge, event cursor, run repository,
Keychain, policy, validation, resume, replay, and export paths through typed presentation adapters;
the Python engine and immutable run artifacts remain the research authority.

## Technical Context

**Language/Version**: Swift 5.10; existing Python ≥3.11 engine remains unchanged
**Primary Dependencies**: SwiftUI, AppKit, Foundation, PDFKit/Quick Look only where a bounded native
preview is appropriate; existing `OpenScienceCore` and `OpenScienceDesktopLogic`; no new third-party
runtime dependency
**Storage**: Versioned JSON conversation envelopes and rebuildable index under the existing
Application Support root; atomic confined writes; typed references to existing managed run
directories; Keychain remains the only credential store
**Testing**: XCTest for models/store/projections/coordinators, deterministic Swift integration
tests, snapshot/geometry acceptance harness, existing Python pytest suite, explicit opt-in live
tests unchanged
**Target Platform**: Native macOS 14+ direct-development application, arm64 first with architecture-
neutral Swift sources
**Project Type**: Existing local desktop executable plus local CLI helper; no backend service
**Performance Goals**: p95 ≤500 ms for local search/conversation/preview selection with 200
conversations, 1,000 selected timeline items, and 1,000 evidence records; citation selection ≤2 s;
interactive lazy scrolling
**Constraints**: One active mutating execution; no cloud/account; no WebView or active retrieved
content; one-object CLI terminal channel; event-log-only progress; bounded reads; no secret/grant/
approval persistence; minimum 1180 × 720; selected mock is sole visual target
**Scale/Scope**: One primary window, one local workspace in first release, ≥200 conversations,
multiple research turns/attempts per conversation, existing app-managed runs only

## Constitution Check

*Gate evaluated before Phase 0 and repeated after Phase 1.*

| Principle / gate | Design evidence | Result |
|------------------|-----------------|--------|
| I. Evidence Before Narrative | Timeline agent prose is a labeled deterministic projection or validated report content; citation activation preserves exact claim/evidence/source joins; retrieved instructions remain inert. | PASS |
| II. Reproducibility by Construction | Conversations keep immutable typed run/request/plan references; run manifests/events/artifact hashes remain authoritative; resume/replay/export are preserved. | PASS |
| III. Human Authority and Bounded Autonomy | Plan and network approvals move inline but remain explicit, ephemeral, and blocking; one mutating run; destructive actions stay confirmed. | PASS |
| IV. Modular, Provider-Neutral Core | New session store, projection, and UI contracts depend on typed engine mappings rather than provider/vendor UI logic; CLI/runtime interfaces are unchanged. | PASS |
| V. Verification and Transparent Failure | TDD tasks precede each implementation slice; all run states and integrity failures remain textual; deterministic offline, performance, accessibility, and visual gates are defined. | PASS |
| Data governance | Conversation files exclude secrets, grants, approvals, retrieved passages, and arbitrary diagnostics; Keychain/local-root/external URL rules remain intact. | PASS |
| Workflow gates | Spec contains independent stories/outcomes/exclusions; this plan documents data flow, trust boundaries, alternatives, contracts, and release gates. | PASS |

No constitution exception is requested.

## Architecture

### Presentation and authority layers

```text
SwiftUI workbench
  ├─ Conversation sidebar          (local session metadata)
  ├─ Typed timeline + composer     (session + safe projections)
  └─ Research preview              (read-only validated projections)
                │ user intents / selections
                ▼
Workbench coordinator / timeline projector / preview router
                │ typed calls and references only
                ├───────────────┐
                ▼               ▼
ConversationStore actor     Existing AppModel / desktop coordinators
(non-scientific metadata)       │
                               ▼
                 OpenScienceCore CLI bridge + RunRepository
                               │
                  immutable managed engine run artifacts
```

The presentation may cache a safe display projection but never promotes it to scientific
authority. `ConversationStore` owns user-authored messages and UI organization. Existing engine
artifacts own plans, events, evidence, reports, manifests, validation, replay, resume, and exports.

### State/data flow

1. Selecting/creating a conversation loads its versioned safe envelope on a store actor.
2. Sending validates and atomically appends one user message/research turn, then invokes existing
   local plan generation via an intent carrying conversation/turn IDs.
3. The reviewed plan produces an inline `planReview` projection. Plan edits expire the binding.
4. If needed, a transient network approval projection wraps the existing one-time grant; the grant
   itself is never in `ConversationStore`.
5. Existing unique-workspace execution starts. The bound event cursor feeds a pure timeline
   projector and existing `AppModel` simultaneously; no stdout progress parsing is added.
6. Terminal reconciliation and fresh validation select the correct result/error projection. The
   session stores only the managed run binding and safe status cache.
7. Explicit inline selections route to the right preview, which reuses validated `RunDetail` joins
   and root-contained artifact loaders.
8. Follow-ups append a new turn and repeat the same lifecycle; earlier bindings remain immutable.

### Trust boundaries

| Boundary | Untrusted/input data | Enforcement |
|----------|----------------------|-------------|
| Composer → plan | User text, selected files/roots, limits | Existing draft validation; explicit root chooser; no provider call during plan |
| Retrieved records → timeline/preview | Evidence/report/source text and URLs | Strict bounded decoding, inert native text, exact joins, redaction, HTTP(S)-only confirmation |
| Conversation file → app state | Local JSON that may be corrupt/replaced/newer | Confined regular-file checks, schema validation, size limits, atomic writes, isolate failures |
| Conversation binding → run repository | Run path/ID/fingerprint | Managed-root containment, no symlinks, fresh validate/reconcile before consequential actions |
| Inline network card → runtime | Human approval intent | One-time in-memory attempt/plan/risk/limits binding; no persistence or default allow |
| Preview artifact → renderer | Markdown/PDF/unsupported files | Fresh identity/size check, inert bounded native renderer or metadata fallback; no active HTML/code |

## Visual Acceptance Strategy

The 1487 × 1058 option 3 image is the sole target. A deterministic seeded state will capture the
workbench in dark appearance. Acceptance combines structural geometry (column widths, dividers,
composer visibility, tab placement, card bounds, 8–16 px rhythm) with a perceptual comparison that
masks dynamic times and font antialiasing. Native controls and semantic system colors may vary
slightly by supported macOS version; geometry tolerances in FR-030 remain binding. The visual gate
must not add third-party assets or emulate another product's brand.

## Adaptive Layout and Accessibility

- Three panes are visible at the reference viewport. The right preview is independently collapsible
  and collapses first below the comfort width; the left sidebar collapses next. The center timeline
  and composer remain the invariant workspace.
- Divider positions are clamped before restoration. Persist only safe widths/visibility/tab.
- Timeline uses lazy rendering, stable IDs, focus preservation, and an explicit scroll-to-latest
  affordance when the reader has scrolled away.
- Approvals never depend on color or swipe. Each card is a semantic group with heading, status,
  help, and contextual actions. Status announcements are coalesced by meaningful transition.
- System/light/dark, increased contrast, reduced motion, keyboard traversal, and larger text retain
  access to content; dark reference capture remains the sole visual comparison.

## Project Structure

### Documentation (this feature)

```text
specs/003-conversation-workbench/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── ui-contract.md
│   ├── session-persistence.md
│   └── engine-mapping.md
├── checklists/
│   ├── requirements.md
│   └── interaction-ux.md
└── tasks.md
```

### Source code (repository root)

```text
macos/OpenScienceDesktop/
├── Sources/
│   └── OpenScienceDesktop/
│       ├── RootView.swift
│       ├── AppModel.swift
│       ├── ConversationUI/
│       │   ├── WorkbenchTheme.swift
│       │   ├── ConversationSidebar.swift
│       │   ├── ConversationTimeline.swift
│       │   ├── ConversationCards.swift
│       │   └── InspectorPane.swift
│       └── Logic/
│           ├── ConversationModels.swift
│           ├── ConversationStore.swift
│           ├── ConversationTimelineProjector.swift
│           ├── WorkbenchCoordinator.swift
│           └── PreviewRouter.swift
└── Tests/
    └── OpenScienceDesktopTests/
        ├── ConversationModelsTests.swift
        ├── ConversationStoreTests.swift
        ├── ConversationTimelineProjectorTests.swift
        ├── WorkbenchCoordinatorTests.swift
        ├── ConversationWorkbenchFlowTests.swift
        ├── ConversationWorkbenchAccessibilityTests.swift
        └── ConversationWorkbenchVisualTests.swift
```

**Structure Decision**: Keep conversation persistence, value types, pure mapping, and coordination
in the existing `OpenScienceDesktopLogic` boundary because they are desktop-session concerns, not
provider-neutral engine domain models. Keep SwiftUI presentation in one focused `ConversationUI`
directory. Existing feature-002 views remain reusable for secondary provider/settings/recovery
presentations during migration, but `RootView` routes the primary window to the new workbench.

## Implementation Phases

### Phase 0 - Research and freeze contracts

Finalize the single visual target, authority split, session format, timeline taxonomy, adaptive
collapse behavior, safe preview strategy, migration boundary, accessibility model, performance
fixtures, and no-copy provenance. Output: [research.md](research.md).

### Phase 1 - Models, interfaces, and validation guide

Define conversation entities/state transitions, UI/persistence/engine contracts, and runnable
offline acceptance. Output: [data-model.md](data-model.md), [contracts/](contracts/), and
[quickstart.md](quickstart.md).

### Phase 2 - TDD foundations

Write red tests for schema validation, atomic confinement, projection purity, binding/selection,
one-active-run routing, approval non-persistence, corrupt recovery, and performance fixtures. Then
implement the model/store/projector/coordinator foundation without changing engine authority.

### Phase 3 - Conversation shell and inline research lifecycle

Implement the option 3 shell, sidebar, timeline/composer, inline plan/network/run/result/error cards,
and follow-up turns. Maintain a usable offline vertical slice after each user story.

### Phase 4 - Preview and existing controls

Implement synchronized Context/Plan/Evidence/Artifacts tabs and route cancel/resume/validate/
inspect/replay/export/providers/settings through existing coordinators.

### Phase 5 - Fidelity, accessibility, performance, and release gates

Complete deterministic visual capture, geometry/perceptual checks, minimum-size/collapse paths,
keyboard/VoiceOver/contrast/reduced-motion tests, scale performance, secret scan, fresh offline
run/replay/resume/export, documentation, and traceability audit.

## Post-Design Constitution Re-evaluation

The Phase 1 data model stores no scientific duplicate; contracts make the validator and exact event
record authoritative; approval state is explicitly non-persistable; all retrieved content stays
inert; provider-neutral engine mappings remain unchanged; and tasks require TDD plus full existing
regressions. All seven pre-design gates remain **PASS**. There are no unresolved clarifications or
constitution violations.

## Complexity Tracking

| Added complexity | Why required | Rejected simpler alternative |
|------------------|--------------|------------------------------|
| Separate versioned conversation store | A durable multi-turn conversation list cannot be reconstructed solely from run artifacts, especially before/without a run. | Store chats inside run directories would mutate scientific artifacts and cannot represent drafts/no-run turns. |
| Typed timeline projection layer | One UI stream must truthfully combine user input, approval state, events, and validated results without treating UI cards as authority. | Directly reading `AppModel` flags in every card would duplicate state logic and invite inconsistent/fabricated status. |
| Four-tab preview router | The requested simultaneous conversation/research inspection requires stable cross-links and collapsible context. | Modal inspectors or replacing the center view would not satisfy the three-pane target. |
