# UI Contract: Native macOS Desktop Client

## Scope and Authority

This contract defines visible states, actions, navigation, accessibility, and permission prompts.
It does not authorize the UI to change engine records or infer research conclusions. The local
engine and validated run artifacts remain authoritative.

The first release has one primary window and one active mutating execution per app instance. It is
an unsandboxed development/direct-distribution client. UI copy MUST NOT claim App Store sandboxing,
durable security-scoped file access, Developer ID distribution signing, notarization, Gatekeeper
readiness, or automatic updates. A local ad-hoc bundle seal is not represented as release signing.

## Primary Navigation

The primary window uses stable destinations:

| Destination | Purpose | Empty state | Primary action |
|-------------|---------|-------------|----------------|
| New Research | Compose, plan, approve, and observe one run | Guidance plus engine/provider status | Generate Plan |
| Runs | Filter and open app-managed history | “No research runs yet” plus New Research action | Open selected run |
| Providers | Inspect local registry descriptors/health | Diagnostic if engine unavailable | Refresh locally |
| Settings | Edit non-secret defaults and Keychain entries | Defaults remain usable | Save/remove setting |

Window restoration may restore the selected destination and non-secret draft text. It must never
restore network authorization, credentials in fields, plan approval, or an active-process claim.

## Global Engine State

Before research actions are enabled, the title/toolbar exposes one of:

- `Checking engine`: local version probe in progress.
- `Ready`: compatible engine identity and path detected.
- `Unavailable`: no executable at the resolved location; show path candidates and remediation.
- `Incompatible`: detected and expected versions shown; research actions disabled.
- `Active run`: one attempt with current safe status; selecting it returns to progress.

Packaged resolution checks `Contents/Helpers/openscience` first when present. Development builds may
use an explicit external CLI path. A buildable app without the optional helper launches normally but
shows `Unavailable` until a compatible development engine is configured.

## New Research Contract

### Composer

Required visible fields and controls:

- Research question (required, 10–10,000 characters)
- Expandable scope, constraints, and assumptions
- Source provider multi-selection with risk and availability
- Synthesis provider selection
- Local roots list with Add Directory and Remove actions
- Limits for records, network requests, and timeout
- Generate Plan action

Rules:

1. Field errors appear adjacent to the field and in an accessible summary; focus moves only when the
   user explicitly requests the first error.
2. Unavailable providers remain visible with health reason but cannot be selected.
3. Adding a local root uses a native directory chooser and creates only an attempt-scoped selection.
   No persistent-authorization claim appears.
4. Generating a plan performs no provider/model request and moves to Plan Review only after a valid
   machine response.
5. Non-secret valid draft content survives a recoverable plan-generation error.

### Plan Review

The review shows:

- question and scope;
- ordered step number/title/purpose;
- dependencies and completion condition;
- capability name/version and risk;
- selected source/synthesis providers and local roots;
- limits and a clear “No network” or “Network confirmation required” summary;
- Back to Edit, Reject, and Approve & Run actions.

Structural engine plan fields are read-only in the first release. Back to Edit expires the current
review if a plan-affecting draft field changes. Reject returns to the draft without invoking a
provider.

### Network Confirmation

If any selected capability is `network_read`, Approve & Run first opens a blocking confirmation that
lists:

- each provider and declared risk;
- destination/API category;
- which local categories may leave the Mac (question, source metadata/evidence, or none);
- maximum requests and attempt timeout;
- explicit Cancel and Allow for This Run actions.

There is no “Always allow” option, remembered checkbox, or default-focused Allow button. Resume uses
a new confirmation. Declining returns to Plan Review and causes no network request.

## Active Run Contract

The active-run view contains:

- question, validated run ID once discovered, status badge, elapsed time;
- ordered plan steps with pending/running/completed/partial/failed/cancelled presentation;
- current provider activity category without secret or raw credential-bearing diagnostic;
- available source/evidence/claim counts;
- last bounded, redacted meaningful event message;
- Cancel action while eligible;
- Inspect Partial Result, Resume, Open Report, or Retry/Settings actions only when supported.

Progress comes from complete records in the one discovered `events.jsonl`. The UI may say
`Preparing run workspace` before discovery. It must not display a fabricated run ID or choose among
multiple candidates.

Status visual treatment always includes text and accessibility value; color/icon alone is
insufficient. Material status changes are announced, but high-frequency count changes are not.

### Cancellation

- Before discovery: Cancel changes to `Stopping before run creation`; process termination may occur,
  but no persisted `cancelled` state is claimed.
- After discovery: Cancel invokes the exact run-directory cancellation command, changes to
  `Cancellation requested`, and becomes disabled while safe termination is pending.
- A second cancel route is idempotent and has no distinct result.
- The view continues to show the bounded current operation until the engine records a terminal
  status or process reconciliation yields an error.

### Terminal Reconciliation

After process exit, the view shows `Validating recorded state` until terminal JSON, exit code,
events, and engine validation reconcile. Outcomes:

| Outcome | UI behavior |
|---------|-------------|
| completed | Success badge; report/export available |
| partial | Amber/neutral partial badge; report, errors, limitations, resume when eligible |
| failed | Failure badge; safe error and eligible recovery |
| cancelled | Cancelled badge only when recorded/reconciled |
| integrity mismatch | High-priority read-only warning; no resume/export-as-valid |
| bridge failure before run | Draft/attempt diagnostic; no fabricated History row |

## Runs and History Contract

The Runs destination provides:

- text search over question and run ID;
- All, Active/Interrupted, Completed, Partial, Failed, Cancelled, Invalid filters;
- newest and oldest sort;
- rows with question, status, creation time, provider names, counts, and validation indicator;
- local Refresh/Validate action that performs no provider call.

For duplicate run IDs, replaced files, symlink/root escape, or invalid artifacts, show a distinct
invalid row with a safe issue. Do not merge records by question or silently remove invalid runs.

Opening a run presents Summary, Report, Evidence, Provenance, and Errors/Limitations sections as
available. The underlying files remain read-only.

## Report and Evidence Contract

### Report

The report view displays validated recorded Markdown as inert native content. It includes persistent
coverage/search-date/limitations context and visually distinguishes claim kinds:

- sourced fact;
- inference;
- assumption;
- hypothesis;
- unsupported.

No report text is executed, loaded as remote HTML, or treated as an instruction.

### Claim-to-evidence navigation

Selecting an evidence reference opens an inspector with:

1. exact evidence passage without paraphrase;
2. locator and stance;
3. claim kind, confidence, and limitations;
4. source title, canonical ID, authors/date/status;
5. providers, retrieval time, license, and safe landing URL.

Contradictory/unclear stances and corrected/retracted/withdrawn source states produce textual
warnings at both list and detail levels. A missing evidence/source link is an integrity error, not an
empty panel.

External URL action is enabled only for a parseable HTTP(S) URL, shows the destination host in an
accessible confirmation, and requires explicit Open. Other schemes render as non-actionable text.

## Resume Contract

Resume is enabled only after fresh validation for supported non-completed states. Its review shows:

- saved question and immutable plan;
- completed step prefix and remaining steps;
- previous status, errors, limitations, and provider identities;
- local roots that must be reselected;
- missing selected-provider credentials;
- a fresh network confirmation if any network-read provider remains.

Approval creates a new attempt state and process but keeps the same engine run directory/history.
The UI does not imply completed steps will run again.

## Export Contract

1. Export begins with fresh run validation.
2. A native save panel suggests `<run-id>.zip` and ZIP content type.
3. Existing-target replacement uses the native destructive confirmation with target name.
4. Progress is `Validating`, `Exporting`, or terminal; no guessed percentage is shown.
5. Success shows resolved path and byte size plus Reveal in Finder.
6. Cancel/failure does not add a success item. A validation-invalid run cannot be exported as valid.

## Providers Contract

Provider rows show descriptor name/version, kind, declared risk, availability, health error, and one
of `No credential`, `Credential saved`, `Credential missing`, or `Credential requirement unknown`.
Refreshing runs local discovery only and displays no network activity indicator because none is
allowed.

Credential actions:

- Add/Replace opens a secure text entry that never pre-fills or reveals the existing value.
- Save writes to the provider-specific Keychain item, clears the field, and reports only presence.
- Remove requires confirmation naming the credential kind and deletes only that Keychain item.
- Keychain denial/lock shows an actionable local error and never falls back to preferences or file.

## Settings Contract

Allowed settings:

- system/light/dark appearance;
- default limits;
- non-secret contact email;
- default provider names and synthesis provider;
- development engine location where the build configuration permits;
- support-export research-content opt-in, default off.

Forbidden settings:

- saved network approval;
- secret values or “show saved secret”;
- sandbox, Developer ID signing, notarization, or Gatekeeper-readiness claims;
- automatic remote telemetry or crash reporting;
- broad default local-root permission.

## Standard Commands and Keyboard Behavior

| Command | Default shortcut/behavior | Availability |
|---------|---------------------------|--------------|
| New Research | Command-N | Compatible engine, no modal blocking |
| Generate Plan / primary action | Command-Return | Valid composer or plan review context |
| Runs | Standard sidebar selection | Always |
| Find in Runs/Report | Command-F | Relevant destination |
| Cancel Active Run | Explicit menu item; no single-key destructive shortcut | Eligible active attempt |
| Export | Command-E | Valid completed/partial run |
| Settings | Command-, | Always |

Escape dismisses only non-destructive transient presentation; it never grants network, approves a
plan, replaces a file, deletes a credential, or cancels a run.

## Accessibility Contract

- All controls use semantic roles, unique names, current values, help where necessary, and logical
  keyboard order.
- Step progress is represented as an accessible list with status values, not a decorative graphic.
- Claims expose kind; evidence exposes stance/source status; warnings expose severity in text.
- Status announcements are coalesced to meaningful transitions and never move focus.
- System colors support light/dark and increased contrast. Meaning is not color-only.
- Reduced motion removes nonessential transitions without hiding progress.
- At the minimum supported window size, primary actions and errors remain reachable without
  overlapping or clipped text; larger text can scroll.

## Error Presentation Contract

Every error presentation contains:

- stable safe category/code;
- concise user outcome (“run was not started”, “recorded state is invalid”);
- bounded redacted detail;
- one or more valid next actions;
- Copy Diagnostic action only after redaction.

No error reveals a credential, full child environment, arbitrary research passage by default, or an
unbounded stdout/stderr dump. Unknown failures are labeled unknown; they are never rewritten as a
provider or user error without evidence.
