# Feature Specification: Conversation Research Workbench

**Feature Directory**: `specs/003-conversation-workbench`

**Created**: 2026-08-27

**Status**: Implementation in progress — three-pane development candidate

**Input**: User description: "Refactor the native macOS client into the selected option 3
Codex/Open Science-style interaction: conversations on the left, a conversation timeline in the
center, and a collapsible research preview on the right."

**Binding Visual Target**: [`design/conversation-workbench/selected-option-3.png`](../../design/conversation-workbench/selected-option-3.png)
at its reference viewport of 1487 × 1058 pixels. This selected mock is the sole visual target for
this feature. Codex and `ai4s-research/open-science` are interaction references only; no third-party
logo, product name, text, icon asset, source code, or distinctive brand treatment may be copied.

The current branch contains a buildable three-pane development candidate. It is not yet a complete
implementation of this specification: the full `ResearchTurn`/attempt contract, transactional
session-recovery coverage, reference-size visual acceptance, accessibility, performance, and
moderated-usability gates remain pending. Build success or a constrained-host screenshot MUST NOT
be treated as feature completion.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Work in a Conversation-First Research Shell (Priority: P1)

A researcher opens the native app into one continuous three-column workspace. They create or select
a conversation in the left sidebar, read its chronological research discussion in the center, and
continue it from the bottom composer without first navigating through a configuration form.

**Why this priority**: The requested product identity depends on replacing the form-first console
with a conversation-first workbench. Without this shell, the interaction remains the old product.

**Independent Test**: Launch with deterministic seeded projects/conversations at the reference
viewport, create and switch a project, create a conversation, switch among
Today/Yesterday/Earlier groups, search by title or message, archive and restore a conversation,
type a draft, relaunch, and verify that the selected project/
conversation and non-secret draft return while no run or network approval is invented.

**Acceptance Scenarios**:

1. **Given** a compatible local engine and at least one conversation, **When** the app opens,
   **Then** the selected option 3 three-column workbench is the primary window and the old New
   Research form is not the primary destination.
2. **Given** no conversations, **When** the app opens, **Then** the left column offers New
   Conversation, the center explains how to start, and the preview remains available without
   presenting a fabricated run or result.
3. **Given** saved conversations spanning multiple dates, **When** the researcher searches or
   changes selection, **Then** matching conversations remain grouped by Today, Yesterday, and
   Earlier and the center timeline changes without mutating any run artifact.
4. **Given** an unsent non-secret draft in conversation A, **When** the researcher selects B and
   later returns to A or relaunches, **Then** A's draft is restored; network grants, plan approval,
   credentials, and active-process claims are not restored.
5. **Given** an archived conversation, **When** the researcher opens Archived and restores it,
   **Then** its ordered turns and run references return without copying or rewriting engine data.
6. **Given** two local research projects, **When** the researcher switches the project selector,
   **Then** the sidebar shows only that project's active/archived conversations and the prior
   project's run artifacts remain unchanged.

---

### User Story 2 - Conduct Governed Research Inside the Timeline (Priority: P1)

A researcher asks a question in the composer and follows the entire governed research lifecycle as
inline timeline content: their message, the agent's bounded response, plan review, network
permission, live run progress, partial/error states, and the evidence-backed result. Advanced scope
and provider settings remain available from the composer without making a form the main workflow.

**Why this priority**: Conversation styling is useful only if it preserves explicit plan approval,
network authority, truthful execution state, and evidence-first results in the new interaction.

**Independent Test**: In a new conversation, submit an offline fixture question, inspect and
approve the inline plan, observe exact recorded progress, open the validated result, ask a follow-up,
then repeat with a network-read fixture and decline permission to prove zero network requests.

**Acceptance Scenarios**:

1. **Given** a valid composer message, **When** it is submitted, **Then** one user timeline item is
   persisted and an inline plan card is generated before any provider or model call.
2. **Given** a pending plan card, **When** the researcher edits advanced settings, rejects, or
   dismisses it, **Then** no source/model is invoked and affected plan approval expires.
3. **Given** a plan with network-read capabilities, **When** approval is requested, **Then** an
   inline blocking network card names providers, destinations, outbound data categories, limits,
   and risk, and offers explicit Reject and Allow for This Run actions with no remembered approval.
4. **Given** an approved run, **When** recorded events arrive, **Then** a single inline run card
   shows ordered steps, tool activity, elapsed time, counts, safe status, and cancellation state
   derived from the bound event log rather than simulated chat text.
5. **Given** a completed or partial validated run, **When** reconciliation finishes, **Then** an
   inline result card presents the recorded evidence-backed summary, citations, limitations,
   conflicts, and artifact links; partial remains visibly partial.
6. **Given** a failed, interrupted, cancelled, or integrity-invalid run, **When** it appears in the
   timeline, **Then** the card retains safe diagnostic context and only the valid recovery actions
   (resume, retry, inspect, settings, or none) are offered.
7. **Given** one active mutating run, **When** another conversation tries to start one, **Then** the
   second conversation remains draft/planned and links to the active run rather than starting a
   concurrent mutation.

---

### User Story 3 - Inspect Context, Plan, Evidence, and Artifacts Beside the Conversation (Priority: P1)

A researcher keeps the conversation visible while inspecting structured research material in a
right-hand preview. The preview has Context, Plan, Evidence, and Artifacts tabs, follows explicit
selections from the timeline, and never changes the engine's recorded files.

**Why this priority**: Simultaneous discussion and inspectable research output is the defining
benefit of the requested three-pane workbench.

**Independent Test**: Open a seeded validated run containing a plan, 12 sources, claims, exact
evidence passages, a report, and a PDF; navigate from an inline citation and artifact link to the
correct preview item, switch tabs, collapse/reopen the panel, and verify the selected item and
read-only integrity state remain stable offline.

**Acceptance Scenarios**:

1. **Given** a selected conversation item, **When** Context is active, **Then** the preview shows
   only recorded or user-authored scope, providers, model identity, limits, run identity, hashes,
   and timestamps, with provenance labels.
2. **Given** a bound plan, **When** Plan is active, **Then** its immutable ordered steps,
   dependencies, capabilities, completion conditions, and recorded step state are shown.
3. **Given** a selected citation, **When** it is activated, **Then** Evidence becomes active and
   shows the exact passage, locator, stance, source identity/status, retrieval time, attribution,
   license, and safe landing URL; missing links appear as integrity errors.
4. **Given** report, PDF, data, or export artifacts, **When** Artifacts is active, **Then** the user
   sees a bounded inert preview or metadata fallback and can reveal/export only through existing
   validated actions.
5. **Given** retrieved text that resembles instructions, HTML, script, a file URL, or an unsafe
   scheme, **When** it is previewed, **Then** it remains inert and cannot change policy, execute,
   navigate, or gain permission.
6. **Given** the preview is collapsed and later reopened, **When** the conversation selection has
   not changed, **Then** the prior tab and safe selection return without retaining sensitive
   transient content.

---

### User Story 4 - Return to Durable, Searchable Research Conversations (Priority: P2)

A researcher can relaunch after normal exit, crash, or sleep, find earlier conversations, and
continue from an accurate timeline reconstructed from the session store plus validated engine
artifacts. One conversation may contain multiple research turns and attempts without duplicating
scientific records.

**Why this priority**: A conversation workbench must be durable and trustworthy across long-running
research, while the engine remains the scientific source of truth.

**Independent Test**: Seed 200 conversations and 1,000 timeline items, bind completed, partial,
interrupted, invalid, and missing runs, interrupt a session-store write, relaunch, rebuild from the
last valid state, and confirm ordering, search, status, and run links without network access.

**Acceptance Scenarios**:

1. **Given** a conversation with several research turns, **When** the app relaunches, **Then** user
   messages and non-secret UI metadata restore in order while plan/run/result cards are revalidated
   against their engine references before being called current.
2. **Given** a crash during a session write, **When** the app relaunches, **Then** the last complete
   version is retained or the affected conversation is isolated with a diagnostic; unrelated
   conversations remain usable.
3. **Given** a missing, replaced, symlinked, or integrity-invalid referenced run, **When** history is
   rebuilt, **Then** the timeline displays a read-only broken/invalid reference and does not repair,
   import, or trust it silently.
4. **Given** a follow-up question in a completed conversation, **When** it is submitted, **Then** a
   new research turn and approval lifecycle are appended; earlier artifacts remain immutable.
5. **Given** a conversation is deleted after explicit confirmation, **When** deletion completes,
   **Then** only the rebuildable conversation index and user-authored session metadata are removed;
   referenced engine run directories remain untouched.

---

### User Story 5 - Preserve Every Existing Research Control (Priority: P2)

A researcher can still cancel and resume eligible work, validate, replay, inspect evidence, export
a portable bundle, manage providers and Keychain credentials, and edit safe settings from the
conversation workbench.

**Why this priority**: The redesign must change information architecture without weakening the
security, reproducibility, recovery, or provider-neutral capabilities already delivered.

**Independent Test**: Execute the complete deterministic desktop regression suite through the new
shell: cancel twice, relaunch/resume without repeating a completed step, validate, replay, export,
list providers offline, add/remove credential canaries, and prove all prior safety invariants.

**Acceptance Scenarios**:

1. **Given** an eligible active or interrupted run, **When** Cancel or Resume is chosen from its
   inline card, **Then** the exact existing cancellation/resume contract, revalidation, root
   reselection, credential reacquisition, and fresh network approval are preserved.
2. **Given** a completed or partial valid result, **When** Validate, Replay, Inspect, or Export is
   chosen from the timeline or preview, **Then** the existing no-network/no-secret engine command
   and reconciliation rules remain authoritative.
3. **Given** provider or runtime status in the sidebar, **When** the researcher opens its control,
   **Then** the existing provider descriptor, health, Keychain presence-only, model, tool, network,
   and settings workflows remain reachable without becoming conversation content.
4. **Given** an integrity-invalid run, **When** any workbench action is considered, **Then** no UI
   rearrangement makes mutation or valid export available.

---

### User Story 6 - Use a Faithful, Adaptive, Accessible Native Workspace (Priority: P3)

A researcher operates the three-column workbench with pointer, keyboard, and assistive technology,
resizes or collapses columns, and retains the selected option 3 hierarchy in supported window
sizes and appearances.

**Why this priority**: Visual fidelity must coexist with native macOS behavior, readable research
content, and accessibility rather than becoming a fixed screenshot reproduction.

**Independent Test**: Compare a deterministic seeded state to the selected mock at 1487 × 1058 in
dark appearance, then complete the main flow keyboard-only at minimum size under increased contrast,
reduced motion, and larger text while collapsing and restoring both side columns.

**Acceptance Scenarios**:

1. **Given** dark appearance at 1487 × 1058, **When** the seeded reference state is shown, **Then**
   its column geometry, visual hierarchy, spacing, card grouping, tabs, composer placement, and
   status treatment match the selected option 3 acceptance measurements.
2. **Given** a narrower supported window, **When** space becomes constrained, **Then** the preview
   collapses before the conversation sidebar, the timeline/composer remain usable, and explicit
   toolbar controls restore either column.
3. **Given** keyboard-only operation, **When** focus traverses the workbench, **Then** New
   Conversation, search, timeline cards, approvals, composer, preview tabs, and actions are reachable
   in logical order with visible focus and standard shortcuts.
4. **Given** VoiceOver, increased contrast, reduced motion, or larger text, **When** statuses change,
   **Then** meaning remains available in text and semantic values, announcements are coalesced, and
   controls do not overlap or become unreachable.
5. **Given** light/system appearance is selected, **When** the app follows that preference, **Then**
   the same hierarchy and semantic contrast remain usable; the binding screenshot comparison
   remains the dark option 3 target.

### Edge Cases

- The session store is empty, corrupt, newer than the supported schema, read-only, out of disk
  space, or replaced by a symlink between discovery and write.
- A conversation references no run, one run, multiple attempts for one run, a removed run, a run
  outside the managed root, duplicate run IDs, or an integrity-invalid artifact.
- A user submits whitespace, a 10,000-character question, rapid duplicate submits, a follow-up
  while planning, or a new request while another conversation owns the active mutation.
- Plan generation finishes after the user switches conversations, archives the conversation, edits
  a plan-affecting draft, or closes the window.
- Network permission is declined, its provider risk changes, limits change, the card scrolls off
  screen, or the app relaunches while permission was pending.
- An event log has an incomplete tail, unknown event, gap, conflicting duplicate, replacement, or
  terminal disagreement while its run card is visible.
- A timeline has zero, 1,000, or more items; a conversation title is long or contains emoji,
  right-to-left text, combining marks, or non-UTF-8 data from an invalid artifact.
- Evidence includes 1,000 records, no passage, missing source, contradictory stances, retracted
  source status, unsafe URL schemes, or content resembling an instruction.
- A PDF/report is missing, oversized, unsupported, malformed, or changed after validation; Quick
  Look is unavailable; the selected artifact is removed while previewed.
- The window starts below the minimum size, moves between displays/scales, enters full screen,
  restores invalid divider positions, or has both optional columns collapsed.
- VoiceOver focus is inside a card when that card reconciles to a different state or becomes
  unavailable.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The primary macOS window MUST use the selected option 3 conversation workbench as its
  default root: conversation/project sidebar, conversation timeline and composer, and collapsible
  research preview. The legacy form-first New Research destination MUST NOT remain the main entry.
- **FR-002**: The selected mock at `design/conversation-workbench/selected-option-3.png` MUST be the
  only binding visual target; external products MAY inform high-level interaction patterns but
  their brand assets, names, copy, code, and distinctive trade dress MUST NOT be reproduced.
- **FR-003**: The sidebar MUST provide a local research-project selector with create/select/rename/
  archive controls, New Conversation, search, grouped active conversations, Archived,
  runtime/model/tool/network status, and Settings. Project organization MUST NOT expand filesystem
  or engine authority.
- **FR-004**: Conversation grouping MUST include Today, Yesterday, and Earlier, preserve stable
  ordering by most recent activity within the selected project, show truthful text status in
  addition to color, and support an empty state, archive, restore, rename, and explicitly confirmed
  delete.
- **FR-005**: Search MUST match conversation title, user-authored message text, and safe run ID,
  update locally without a provider request, and return a usable empty result within SC-006.
- **FR-006**: The center column MUST present an ordered timeline of typed items: user message, agent
  notice/result, plan review, network approval, run progress, error/recovery, and artifact summary.
- **FR-007**: Agent-authored timeline prose MUST be either a labeled deterministic UI projection or
  content loaded from a validated recorded artifact; the UI MUST NOT invent scientific narrative,
  citations, tool activity, completion, or source access.
- **FR-008**: The bottom composer MUST support multiline text, attachments/local-root selection,
  advanced research settings, explicit model selection, send, keyboard shortcuts, and a clear
  active/blocked state without exposing secrets.
- **FR-009**: Advanced settings MUST preserve all draft fields from feature 002 (scope,
  constraints, assumptions, sources, synthesis, local roots, limits, timeout, and contact email)
  without restoring the full form as the primary route.
- **FR-010**: Sending a valid message MUST append exactly one user message and initiate only local
  plan generation; provider/model calls MUST remain impossible until the bound inline plan is
  explicitly approved.
- **FR-011**: Plan cards MUST show the immutable question, ordered steps, dependencies, completion
  conditions, capabilities, providers, local roots, limits, and risk; any plan-affecting edit MUST
  expire its approval.
- **FR-012**: Network-read work MUST show an inline blocking approval card with providers,
  destination category, outbound data categories, request/time limits, risk, Reject, and Allow for
  This Run. Approval MUST be ephemeral and MUST NOT survive relaunch, resume, plan change, or risk
  change.
- **FR-013**: A run card MUST bind to exactly one attempt/run identity and derive step/status/count
  progress solely from the existing bounded append-only event contract; unknown or inconsistent
  events MUST fail transparently.
- **FR-014**: The workbench MUST preserve the application-wide limit of one active mutating
  research execution while allowing read-only conversation, report, evidence, provider, and
  settings activity.
- **FR-015**: Terminal result cards MUST remain provisional until the existing terminal JSON,
  events, manifest, and validator reconcile and MUST distinguish completed, partial, failed,
  cancelled, interrupted, awaiting approval, and integrity warning in text.
- **FR-016**: Each conversation MUST support multiple ordered research turns and attempts. Adding a
  follow-up MUST append a new lifecycle without altering prior user messages, plans, runs, evidence,
  or artifacts.
- **FR-017**: The right preview MUST provide Context, Plan, Evidence, and Artifacts tabs with visible
  counts when applicable and synchronize only from an explicit conversation/timeline selection.
- **FR-018**: Context MUST distinguish user input, engine records, and derived UI metadata and show
  run/provider/model/limit/hash/time information only when recorded or configured.
- **FR-019**: Plan MUST show the immutable engine plan beside recorded execution state without
  changing the plan file or using UI order as execution authority.
- **FR-020**: Evidence MUST preserve exact claim-to-evidence-to-source ID joins, passages, locators,
  stances, source status, retrieval/attribution/license data, conflicts, and integrity errors.
- **FR-021**: Artifacts MUST render bounded validated Markdown, PDF, and supported local previews as
  inert content; unsupported/oversized/invalid artifacts MUST show metadata and safe actions rather
  than fabricated previews.
- **FR-022**: External destinations MUST remain HTTP(S)-only, display the host, and require explicit
  confirmation; retrieved content and previews MUST never execute instructions or active content.
- **FR-023**: The preview MUST be explicitly collapsible and restorable, preserve only its
  non-sensitive selected tab and safe width, and collapse before the sidebar under width pressure.
- **FR-024**: The session store MUST persist schema-versioned non-secret conversation metadata,
  user-authored messages, safe draft text, typed references, archive state, selection, and layout
  preferences using confined crash-safe writes.
- **FR-025**: The session store MUST NOT persist credentials, child environments, network grants,
  plan approvals, unredacted diagnostics, arbitrary retrieved passages, or an active-process claim.
- **FR-026**: Engine run directories and validated artifacts MUST remain authoritative and
  immutable; conversation records MUST store typed root-contained references rather than duplicate
  or silently repair scientific records.
- **FR-027**: On launch and before consequential actions, referenced run/card state MUST be rebuilt
  or freshly validated. Missing, escaped, replaced, or invalid references MUST be isolated in a
  safe read-only state.
- **FR-028**: Conversation deletion MUST require explicit confirmation and MUST NOT delete engine
  runs or exported research bundles. Existing destructive file policy remains unchanged.
- **FR-029**: Cancel, resume, validate, inspect, replay, export, provider discovery, Keychain
  credential management, local-root authority, model privacy restrictions, and settings from
  feature 002 MUST remain reachable and MUST retain their existing contracts and tests.
- **FR-030**: At the 1487 × 1058 dark reference viewport, the shell MUST satisfy the visual
  acceptance geometry: left column 262 ± 16 px, right column 484 ± 24 px, center consumes the
  remainder with no clipped composer, persistent 1 px-equivalent separators, compact 8–16 px
  spacing rhythm, and card/tabs hierarchy matching the selected mock.
- **FR-031**: The workbench MUST support a 1180 × 720 minimum content size. Below the full
  three-column comfort width, preview collapses first; sidebar may then collapse; timeline and
  composer remain reachable without overlap or horizontal page scrolling.
- **FR-032**: The UI MUST preserve system/light/dark appearance, increased contrast, reduced motion,
  larger text, semantic colors, text status, visible focus, and meaningful accessibility names,
  values, help, headings, lists, and coalesced announcements.
- **FR-033**: Standard commands MUST include New Conversation (Command-N), search (Command-K),
  primary composer/approval action (Command-Return in context), find in visible content (Command-F),
  export (Command-E when eligible), Settings (Command-,), and explicit preview/sidebar toggles;
  Escape MUST never approve, grant, delete, replace, export, or cancel.
- **FR-034**: Timeline and list rendering MUST remain responsive for at least 200 conversations,
  1,000 timeline items in the selected conversation, and 1,000 evidence records under SC-006,
  without truncating a record into a verified state.
- **FR-035**: All new domain models, persistence, projections, engine mappings, permissions, and
  end-to-end workbench journeys MUST be developed test-first; existing deterministic Python and
  Swift regressions MUST remain green and live network tests remain explicit opt-in.
- **FR-036**: Visible error states MUST contain a stable safe category/code, user outcome, bounded
  redacted detail, and valid next action; they MUST NOT be converted into assistant success prose.

### Key Entities

- **Research Workspace**: Application-level local presentation/storage scope; it owns project and
  conversation metadata but does not expand engine filesystem authority.
- **Research Project**: User-named local organizer for conversations with identity, timestamps, and
  archive state; it has no provider credential or engine run ownership.
- **Conversation**: Durable UI container with identity, title, timestamps, archive state, safe
  draft, ordered turns, typed run references, and one parent project.
- **Research Turn**: One user request plus its plan/authorization/attempt/result lifecycle within a
  conversation.
- **Timeline Item**: Typed chronological projection with a stable ID, provenance class, display
  state, and optional engine reference.
- **Conversation Draft**: Unsent non-secret question, attachments/reselected roots, and advanced
  parameters; secret material and approvals are excluded.
- **Run Binding**: Immutable link from a research turn/attempt to a validated managed run directory,
  request/plan identity, and last known integrity state.
- **Preview Selection**: Ephemeral pointer to Context, Plan, Evidence, or Artifact content with a
  safe persistable tab but no duplicated retrieved content.
- **Workbench Layout State**: Non-secret selected conversation, collapsed columns, selected preview
  tab, and clamped column widths.

### Dependencies

- Feature 001 engine contracts and immutable run/evidence/artifact formats remain unchanged.
- Feature 002 CLI bridge, UI safety, Keychain, run repository, event cursor, and orchestration remain
  authoritative and are refactored behind new presentation adapters rather than replaced.
- The selected visual target is stored locally at
  `design/conversation-workbench/selected-option-3.png` and must remain available to visual review.
- No cloud backend, account, remote conversation sync, collaboration, or third-party UI asset is
  required.

### Assumptions

- First release remains a native, unsandboxed direct-development macOS 14+ client with one primary
  window, multiple local organizational projects, and one active mutating execution per app
  instance.
- The local application-support directory is the only conversation persistence authority; engine
  records continue in their existing managed run roots.
- Conversation titles may begin as a bounded derivative of the first user question and remain
  explicitly renameable; title generation makes no scientific claim.
- Dark appearance is the binding screenshot baseline. Existing system/light choices continue with
  semantic equivalents but do not introduce an alternate visual mock.
- The right preview uses native inert renderers or metadata fallbacks; a full code editor,
  executable notebook, browser, or remote webview is outside this feature.

### Out of Scope

- Copying, embedding, or reverse engineering Codex/Open Science brand assets or proprietary UI.
- Cloud accounts, conversation synchronization, multi-user collaboration, sharing permissions, or
  remote session execution.
- Multiple simultaneous mutating research runs, background daemon execution, or distributed jobs.
- Changing research planning, evidence semantics, provider contracts, artifact formats, or CLI
  authority solely to support a visual interaction.
- Editing engine report/evidence/artifact content in the preview, executing notebooks, running
  retrieved code, or loading arbitrary remote HTML.
- Developer ID signing, notarization, App Store sandboxing, auto-update, or production distribution
  claims.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a five-participant moderated usability check, at least four participants can create
  a conversation, submit a question, approve an offline plan, identify live progress, open one exact
  citation, and locate an artifact without opening the legacy form or receiving assistance.
- **SC-002**: A deterministic dark reference capture at 1487 × 1058 satisfies all FR-030 geometry
  tolerances and reaches at least 0.90 perceptual similarity to the selected option 3 mock. Masking
  is limited to dynamic timestamp glyph bounds and a one-pixel subpixel-antialiasing fringe around
  text; pane, card, tab, composer, status, and content geometry MUST remain compared, and no other
  mock is used as a competing target.
- **SC-003**: Every supported run state and every approval/recovery decision appears in the center
  timeline with a textual label, valid action set, and matching recorded state in 100% of fixture
  cases.
- **SC-004**: Activating any of 1,000 fixture claim citations selects the exact evidence/source in
  the right preview within 2 seconds, with zero mismatched or fabricated links.
- **SC-005**: Declining or dismissing any plan/network card produces zero provider/model requests;
  after relaunch, zero fixture network grants, plan approvals, credentials, or active-process claims
  are restored.
- **SC-006**: With 200 conversations, 1,000 timeline items, and 1,000 evidence records, after five
  warm-ups and at least 30 measured operations per class on an Apple M1-or-newer Mac with at least
  8 GiB RAM, macOS 14+, and no thermal-pressure warning, conversation selection/search and preview
  selection each complete within 500 ms at p95; deterministic timeline scrolling has no main-thread
  stall over 100 ms and loses zero records.
- **SC-007**: The app recovers the last complete session version after each deterministic interrupted
  write fixture; corrupt conversations are isolated and all unaffected conversations remain
  accessible in 100% of cases.
- **SC-008**: At 1180 × 720 and at the reference size, all primary controls remain visible or
  keyboard-reachable with no overlapping text; preview collapse/restore takes at most one explicit
  action and retains the prior safe tab/selection.
- **SC-009**: Keyboard-only and VoiceOver acceptance completes New Conversation → plan approval →
  run → evidence → export with no pointer-only control, color-only status, focus trap, or unannounced
  consequential action.
- **SC-010**: The full existing deterministic Python suite, Swift suite, new conversation contract
  tests, formatting/type checks, secret scan, fresh offline run, validation, replay, resume, and
  export all pass with zero security or research-integrity regression.
- **SC-011**: A repository scan finds zero copied external brand assets, third-party UI strings,
  third-party source fragments, credentials, or newly persisted evidence passages in conversation
  files.
