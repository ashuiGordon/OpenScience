# Research: Conversation Research Workbench

## Decision 1: Use the selected option 3 mock as the single visual baseline

**Decision**: Bind dark-appearance acceptance to
`design/conversation-workbench/selected-option-3.png` at 1487 × 1058. Measure its approximate
262 px left, 741 px center, and 484 px right hierarchy with spec tolerances; compare a deterministic
seeded capture after masking dynamic text rasterization.

**Rationale**: The user explicitly chose option 3. A single checked-in target prevents later style
drift or accidental blending of rejected directions.

**Alternatives considered**: Treat all three drafts as inspiration (ambiguous); copy Codex or the
reference repository exactly (unnecessary, brand/copyright risk, and not the user's unique product).

## Decision 2: Preserve native adaptive panes rather than recreate a fixed canvas

**Decision**: Implement three native resizable panes with the center invariant, preview collapsing
first, then sidebar. Clamp/persist only safe widths and visibility.

**Rationale**: It matches the selected composition while retaining macOS window, full-screen,
keyboard, focus, accessibility, and multi-display behavior.

**Alternatives considered**: Fixed HStack pixel layout (fragile and inaccessible); browser shell
(adds active-content and distribution complexity); modal preview (does not meet the requested
simultaneous workbench).

## Decision 3: Make Conversation a presentation entity, not a research record

**Decision**: A conversation owns user-authored messages, UI organization, non-secret draft, and
typed references. Existing run directories own scientific plan/event/evidence/report/artifact data.

**Rationale**: This preserves evidence provenance, reproducibility, run validation, and feature-002
security guarantees while enabling pre-run and multi-turn UI state.

**Alternatives considered**: Copy full reports/evidence into conversation JSON (duplication and
staleness); derive all conversations from runs (cannot represent drafts, rejected plans, or multiple
turn grouping); modify run manifests with UI data (breaks immutability/hash chains).

## Decision 4: Use versioned, atomic local JSON envelopes for conversation persistence

**Decision**: Store one bounded schema-versioned envelope per conversation plus a rebuildable index
under a confined Application Support conversation root. Write a same-directory temporary regular
file with restrictive permissions, synchronize, atomically replace, and validate after read. Isolate
one corrupt/newer envelope instead of making all conversations unusable.

**Rationale**: The scale is modest, models are naturally codable, no migration framework or new
dependency is needed, and per-conversation isolation limits corruption impact.

**Alternatives considered**: UserDefaults (poor for structured/durable data); SQLite/Core Data
(unneeded complexity for current scale); one monolithic JSON file (larger blast radius); append-only
chat event log (more recovery/compaction complexity than justified for non-scientific UI metadata).

## Decision 5: Project the timeline through pure typed mappings

**Decision**: Define a closed taxonomy of user message, agent notice/result, plan, network approval,
run progress, error/recovery, and artifact summary items. A pure projector maps conversation turns,
transient approvals, bounded engine events, and validated `RunDetail` into this taxonomy.

**Rationale**: Pure mappings are deterministic, testable, stable across UI recomposition, and can
label provenance without inventing chat content.

**Alternatives considered**: Store every UI card verbatim (stale/unsafe); generate assistant chat
from raw logs (unbounded and may fabricate interpretation); let each SwiftUI view infer state
independently (terminology and action drift).

## Decision 6: Keep existing `AppModel` orchestration behind a workbench coordinator

**Decision**: Add a coordinator that binds conversation/turn IDs to existing plan/run/resume/export
operations and dispatches existing actions. Do not reimplement the CLI bridge or research engine.

**Rationale**: Feature 002 already enforces unique workspaces, one active process, event cursor,
terminal reconciliation, grants, Keychain, and run validation. An adapter changes presentation
without weakening those boundaries.

**Alternatives considered**: Rewrite `AppModel` and bridge together (high regression risk); call the
Python CLI directly from cards (duplicates security/reconciliation logic); local HTTP service
(explicitly excluded by existing contracts).

## Decision 7: Inline approvals remain consequential controls, not ordinary messages

**Decision**: Plan and network cards are semantic approval groups bound to exact turn/attempt/plan
identities. Network grants remain in-memory and one-time; approval controls never become restored
conversation state or default-focused allow actions.

**Rationale**: Moving controls into a timeline must not make consent look like passive prose or
survive beyond its reviewed conditions.

**Alternatives considered**: Slash-command approval (ambiguous and hard to make accessible);
remembered allow toggle (violates constitution and feature 002); modal-only review (breaks the
selected inline interaction, though native confirmations remain for destructive file operations).

## Decision 8: Use a read-only four-tab preview with explicit selection routing

**Decision**: Context, Plan, Evidence, and Artifacts each consume a typed `PreviewSelection`. Inline
citations/artifacts explicitly select the matching tab/item. The panel never executes content or
mutates engine files.

**Rationale**: This gives the requested side-by-side workflow, keeps selection predictable, and
lets exact evidence integrity checks remain visible.

**Alternatives considered**: Automatically follow every event (focus churn); generic file browser
(weak provenance and unsafe formats); one large mixed inspector (poor hierarchy and scaling).

## Decision 9: Preview Markdown/PDF through bounded inert native paths

**Decision**: Render validated Markdown as native inert text and supported PDFs through a bounded
native viewer after identity/size checks. Other artifacts receive metadata, reveal, and export
actions. No WebView, scripts, remote resources, or executable notebook/code preview.

**Rationale**: Native rendering meets the visual need while preserving retrieved-content distrust,
URL confirmation, containment, and no-active-content rules.

**Alternatives considered**: WKWebView Markdown/PDF (active resource and navigation risks); custom
full document editor (out of scope); previewing any file bytes as text (encoding/size and trust
hazards).

## Decision 10: Persist safe layout/session state only

**Decision**: Persist selected conversation, clamped pane widths/visibility, selected preview tab,
archive/rename state, and non-secret draft. Never persist credentials, environments, network grants,
plan approvals, raw diagnostics/evidence, or active-run claims.

**Rationale**: Restoring ergonomic state is useful; restoring authority or sensitive content is
unsafe and factually wrong after relaunch.

**Alternatives considered**: Persist whole observable model (secret/authority leakage); restore
nothing (unnecessarily poor workflow); persist cached run status as authoritative (can be stale).

## Decision 11: Test fidelity with structure plus perceptual comparison

**Decision**: Use deterministic fixture data, fixed reference window/appearance, structural geometry
assertions, and a 0.90 masked perceptual threshold. Also perform keyboard/VoiceOver/minimum-size
acceptance; screenshot similarity alone cannot establish accessibility or behavior.

**Rationale**: Native font rendering varies, while column/card hierarchy is stable and measurable.
Combining methods avoids both brittle exact pixels and subjective “looks similar” claims.

**Alternatives considered**: Exact pixel equality (brittle across OS/display); manual review only
(not repeatable); view-unit tests only (cannot prove the selected visual target).

## Decision 12: Treat light appearance as semantic compatibility, not a second design

**Decision**: Dark option 3 remains the binding visual target. Existing system/light settings use
the same hierarchy with semantic colors and contrast, verified functionally/accessibly rather than
against an invented light mock.

**Rationale**: This satisfies both the user's selected design and feature-002 appearance contract
without adding an unapproved visual direction.

**Alternatives considered**: Dark-only app (regresses existing setting/accessibility); create an
unreviewed light design (violates the single-target decision).

## Decision 13: Migrate incrementally and retain secondary feature-002 views

**Decision**: Switch `RootView` to the new workbench after foundation tests, while reusing or
wrapping existing provider/settings/resume/export controls from contextual routes. The old large
New Research form stops being primary but may temporarily back the advanced-settings presentation
until all fields have dedicated compact controls.

**Rationale**: This achieves the requested information architecture without deleting validated
capabilities or requiring a risky all-at-once orchestration rewrite.

**Alternatives considered**: Keep both roots as equal modes (unclear product direction); delete old
views immediately (regression risk); reskin the form (does not meet the goal).

## Decision 14: Use no copied external implementation or brand material

**Decision**: Implement from the local spec and selected original mock using Apple-native controls
and OpenScience naming/assets. Document high-level inspiration only.

**Rationale**: The objective is an OpenScience workbench, not a clone, and existing project
clean-room/license boundaries remain intact.

**Alternatives considered**: Vendor UI source reuse or screenshot asset extraction (unnecessary and
legally/technically risky).
