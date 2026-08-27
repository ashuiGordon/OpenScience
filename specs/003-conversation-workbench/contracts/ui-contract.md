# UI Contract: Conversation Research Workbench

**Contract ID**: `openscience-conversation-ui/1`

## Scope and Authority

This contract replaces feature 002's primary navigation layout while preserving every feature 002
permission, process, run, evidence, resume, export, provider, settings, accessibility, and error
contract. The engine and freshly validated run artifacts remain authoritative. A timeline card or
preview may project that state but may not create or repair it.

The only binding visual target is
`design/conversation-workbench/selected-option-3.png` at 1487 × 1058 in dark appearance. External
product names are not visible styling requirements and provide no permission to copy brand assets,
copy, code, or distinctive trade dress.

## Primary Window Geometry

At the reference viewport:

| Region | Target | Accepted range | Required content |
|--------|--------|----------------|------------------|
| Conversation sidebar | 262 px | 246–278 px | workspace, new/search, grouped rows, archive, runtime/settings |
| Conversation column | remaining ≈741 px | never below 520 px at full three-pane mode | header, lazy timeline, pinned bottom composer |
| Research preview | 484 px | 460–508 px | four tabs, selection content, collapse control |

Adjacent regions have a 1 px-equivalent semantic separator. Primary spacing follows a compact 8,
12, and 16 point rhythm. Cards use restrained borders/surfaces and 8–12 point corner treatment;
status colors supplement text/icons. The composer remains completely visible at the bottom and the
timeline scrolls behind neither it nor the title bar.

At 1180 × 720, primary content and controls remain reachable. When the window cannot satisfy the
three-pane minimum, the preview collapses first, then the sidebar. The center never collapses. Each
optional pane has an explicit toolbar toggle, current accessibility value, and restoration action.
Divider widths restored from preferences are clamped before layout.

## Left Column: Conversation Sidebar

### Project/workspace header

- Shows the selected local research project and a selector/action entry for create, switch, rename,
  and archive project commands.
- Conversation groups and Archived are scoped to the selected project. Switching projects does not
  stop, retarget, or hide the identity of an active run in another project.
- Does not imply cloud synchronization, account ownership, or access outside Application Support.
- A compact titlebar control exposes sidebar collapse without hiding it from keyboard users.

### Primary controls

1. `New Conversation` is the visually primary sidebar action and uses Command-N.
2. `Search conversations` uses Command-K, searches locally, and exposes clear/cancel semantics.
3. Search never invokes a provider, indexes retrieved passages, or treats unsafe artifact text as a
   conversation message.

### Conversation groups and rows

- Non-archived rows are grouped as Today, Yesterday, and Earlier by local `updated_at` only.
- Groups are collapsible presentation state; collapsing never archives or deletes.
- Rows show bounded title, truthful text/accessibility status, last activity time/date, and selected
  treatment. Status color dots always have equivalent text/accessibility values.
- Sort is newest activity first with stable ID tie-break, unaffected by localized display strings.
- A row context menu supports Rename, Archive, and Delete. Delete is destructive, names the
  conversation, requires confirmation, and explicitly states engine runs remain.
- `Archived` shows a count and a separate list with Restore/Delete. It is not mixed into search
  results unless Archived is active.
- Empty and no-match states keep New Conversation and clear search available.

### Runtime footer

- Shows local runtime readiness, selected model label, tool availability summary, and network
  posture with text plus icon/color.
- These controls route to existing Providers/Settings/active-run information; they do not become
  conversation messages or silently change a reviewed plan.
- Network posture never means persistent authorization. Pending authorization is shown only in the
  exact inline network card.

## Center Column: Conversation

### Header

- Shows the selected conversation title, safe save/local status, and contextual rename,
  archive/export/share-equivalent actions only when valid. No cloud/share claim is made.
- Conversation title edits are local metadata and cannot rename run IDs or report content.
- Header remains visible while the timeline scrolls.

### Timeline behavior

- Items are chronological, use stable IDs, and are rendered lazily.
- User messages, OpenScience agent projections, and engine/validated artifact content have visibly
  distinct author/provenance labels.
- On first load or send, scroll to latest. If the reader scrolls away, new activity does not steal
  position; show an accessible `Jump to latest` control.
- Selection remains explicit. High-frequency event changes update a bound run card in place rather
  than appending log spam.
- A reconciled state change may alter actions/status inside one card but never changes the original
  user message, plan identity, evidence passage, or earlier research result.
- Raw stdout/stderr and unbounded logs are not conversation prose. Safe bounded diagnostics may
  appear in an error disclosure with Copy Diagnostic after redaction.

### User message item

- Displays exact user-authored text and session timestamp.
- May show safe attachment/reselection hints, never an implied durable local-root authorization.
- Once plan/run bound, text is immutable. A correction is a follow-up turn.

### Agent notice/result item

- `agentNotice` contains only deterministic process language such as preparing plan, awaiting
  approval, validating, or engine unavailable and is labeled as a UI projection.
- `researchResult` loads validated report/claim content and preserves citations, limitations,
  conflicts, coverage, and partial/integrity state. It may render a bounded excerpt while linking to
  exact preview records.
- The UI never invents a claim, citation, source access, metric, tool result, or completion message.

### Inline plan card

Required visible content:

- immutable question/scope;
- ordered step count, step titles, dependencies, completion conditions;
- capability/provider names, versions where recorded, risk, local/network categories;
- limits and local roots/reselection state;
- Edit Settings, Reject, and Approve actions.

Approve is explicit and cannot be triggered by Escape or mere send. Edit of any plan-affecting
field expires the card's approval/binding. Reject causes no provider/model call. A stale card shows
`Plan changed—review again` and has no run action.

### Inline network approval card

The card blocks execution and lists every provider/destination category, outbound data category,
risk, maximum network requests, timeout, and whether local content could leave the Mac. It provides
`Reject` and `Allow for This Run`. Allow is not default-focused, has no remembered option, and binds
to exact attempt, plan hash, provider risk, and limits. Switching conversations does not lose the
pending card but grants nothing; relaunch invalidates it.

### Inline run card

Required visible content:

- run ID after unique discovery or `Preparing run workspace` before it;
- textual run status and elapsed time;
- ordered plan steps with pending/running/completed/failed/cancelled state;
- current safe capability/provider activity;
- source/evidence/claim counts when recorded;
- last meaningful bounded event;
- exact valid actions such as Cancel, Inspect Partial, Resume, Settings, or Open Result.

Progress comes only from complete trusted lines in the bound event file. Unknown events may show
generic activity but cannot add actions or establish success. Terminal events remain provisional
until process/artifact reconciliation. Repeated Cancel is idempotent; pre-discovery termination and
recorded cancellation remain visibly different.

### Inline error/recovery card

- Shows stable safe code/category, what did not happen, bounded redacted context, validation state,
  and only valid next actions.
- Failed/partial/invalid is never restyled as assistant completion.
- Resume routes to the feature-002 fresh review/reselection/credential/network flow, which may be
presented inline or in an explicit blocking native sheet while retaining the originating card.

### Composer

- Pinned below timeline with multiline text, attachment/local-root chooser, advanced settings,
  model selection/status, and Send.
- Enter inserts a newline; Command-Return invokes the valid primary action for the current turn.
- The composer shows a clear reason when planning/running/engine/privacy/validation constraints
  block send. It never consumes a message twice during rapid input.
- Advanced settings expose every feature-002 draft field in a compact disclosure/popover/sheet.
  Closing it preserves valid non-secret edits; plan-affecting edits invalidate a pending plan.
- Attachments are local selections/reselection inputs, not automatically uploaded. Network-bound
  data remains declared in the approval card.
- While another conversation owns the one active mutation, the composer may save a draft/prepare a
  local plan when safe but cannot start a second run.

## Right Column: Research Preview

The right column has a stable tab strip ordered Context, Plan, Evidence, Artifacts, plus an explicit
collapse control. Evidence/Artifacts may show bounded counts. Switching tabs never invokes a
provider. When no compatible selection exists, each tab uses a specific empty state instead of
showing stale content from another conversation.

### Context tab

Shows selected conversation/turn/run identity and only recorded or user-configured question,
scope, constraints, assumptions, provider/model identities, limits, timestamps, hashes, and
validation state. Each block labels whether it is user input, engine record, or UI metadata.

### Plan tab

Shows immutable ordered engine steps, dependencies, completion conditions, capability/risk, and
the exact recorded execution state beside each step. It has no reorder/edit affordance. Plan
approval remains in the center card.

### Evidence tab

Activating a citation routes here and selects the exact evidence record. It shows:

1. source title/status/canonical ID/authors/date;
2. exact citation and safe HTTP(S) landing URL;
3. exact passage and locator;
4. stance, claim kind/confidence/limitations;
5. retrieval provider/time, attribution, and license;
6. contradiction, retraction/withdrawal/correction, missing-link, or integrity warning.

Source navigation exposes previous/next and count without changing the claim join. External URL
requires host confirmation. Retrieved instructions remain inert selectable text.

### Artifacts tab

- Lists manifest-declared artifacts with name, kind, size, hash/validation, creation time, and safe
  actions.
- Valid bounded Markdown is inert native content. A valid bounded PDF uses a native read-only
  preview. Other/invalid/missing/changed/oversized formats show metadata and explicit reason.
- `Reveal in Finder`, validated export, and download/save-equivalent actions reuse existing policy;
  preview never executes code, remote HTML, file URLs, or embedded scripts.

### Collapse and restoration

Collapse is one action and moves focus predictably to its restore control. Safe selected tab,
record IDs, and clamped width may restore. Preview bytes/open handles/validation authority do not.
Under automatic width collapse, restoring at an insufficient width may temporarily overlay or
replace the sidebar only through an explicit user action; center content remains usable.

## Existing Workflow Routing

| Existing capability | Workbench entry | Preserved authority |
|---------------------|-----------------|---------------------|
| Cancel | Active inline run card/menu | Exact discovered run directory and recorded terminal state |
| Resume | Recovery card/run context action | Fresh validate, immutable plan, roots/credentials/network reacquired |
| Validate/Inspect/Replay | Result/error card and preview action menu | Credential-free/no-network CLI bridge |
| Export | Result/artifact/header action | Fresh validation, native destination/replacement, engine bundle |
| Providers | Runtime footer and Settings | Local discovery, risk/health, presence-only Keychain |
| Settings | Sidebar footer / Command-, | Non-secret preferences and secure credential sheets |

No route is removed until its new workbench entry and existing regression suite are green.

## Keyboard and Accessibility Contract

| Command | Shortcut | Rule |
|---------|----------|------|
| New Conversation | Command-N | Available without modal blocking |
| Search conversations | Command-K | Focuses local search; Escape clears/dismisses only search |
| Primary contextual action | Command-Return | Send or explicit current review action, never network allow by surprise |
| Find visible research content | Command-F | Timeline/report/evidence context, not provider network search |
| Export | Command-E | Only freshly valid completed/partial target |
| Settings | Command-, | Always |
| Toggle sidebar | Standard/custom menu command | State announced |
| Toggle preview | Menu/toolbar command | State announced |

- Panes, groups, timeline, cards, lists, tab strip, evidence, and composer expose semantic roles,
  headings, names, values, help, and logical order.
- Status changes announce only meaningful transitions and never steal focus. Count ticks are not
  individually announced.
- When a focused action disappears due to reconciliation, focus moves to that card heading/status,
  not an unrelated pane.
- Reduced motion removes nonessential transitions. Increased contrast and light/dark appearance use
  semantic colors. No state is color/icon-only.
- At minimum size and larger text, panes scroll internally; primary controls/errors remain
  reachable and do not overlap.

## Error Presentation Contract

Every workbench error contains a stable code/category, concise outcome, bounded redacted detail,
validation/trust state, and valid next action. Unknown errors remain unknown. A session-store error
does not become an engine error; an engine error does not silently delete the conversation. Copy
Diagnostic performs redaction and excludes credentials, full environments, arbitrary retrieved
passages, and unbounded stdout/stderr.

## Visual Acceptance Seed

The deterministic reference state contains:

- selected local project `Protein LM Repro`;
- grouped conversation list with selected `Reproduce ESM-1b leaderboard…`;
- one user message and one OpenScience agent response;
- a network approval card, five-step plan with mixed states, tool activity rows, and cited result;
- Evidence tab selected with source/citation/passage/provenance and one PDF artifact preview;
- local runtime/model/tools/network summaries and a populated composer.

Fixture text is test data only and does not assert those scientific results. Dynamic timestamps and
model/source values are labeled fixture data in the capture harness.
