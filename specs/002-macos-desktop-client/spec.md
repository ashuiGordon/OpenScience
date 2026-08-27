# Feature Specification: Native macOS Desktop Client

**Feature Branch**: `agent/macos-desktop-client`

**Created**: 2026-08-21

**Status**: Development preview implemented; release validation pending

**Input**: User description: "Develop a native macOS desktop client for OpenScience that reuses the local research engine and covers research creation, live progress, history, evidence-backed reports, cancellation, resume, export, providers, and settings without a cloud backend."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Create and Run a Research Task (Priority: P1)

A researcher opens OpenScience, enters a research question and optional scope and limits, chooses
local or network-capable sources, reviews the finite plan, and explicitly approves it. The client
starts the local research engine and presents understandable progress until the run reaches a
truthful terminal state.

**Why this priority**: Starting and understanding a research run is the minimum useful desktop
experience and the entry point for every later workflow.

**Independent Test**: From a fresh installation with the deterministic fixture source, create a
question, review and approve its plan, run it to completion, and observe every plan step and final
record count without an account or network connection.

**Acceptance Scenarios**:

1. **Given** a valid question and an offline source, **When** the researcher approves the displayed
   plan, **Then** exactly one local run starts and the interface shows its current step, elapsed
   time, and eventual status.
2. **Given** a plan awaiting review, **When** the researcher rejects or closes it, **Then** no source
   or model is invoked and the draft remains editable.
3. **Given** one or more selected network-read providers, **When** the researcher starts the run,
   **Then** the client shows the providers, data categories, request limit, and destination risk and
   requires a per-run confirmation before any network permission is granted.
4. **Given** a provider failure after useful evidence was collected, **When** the engine returns a
   partial result, **Then** the client labels it `partial`, preserves the useful artifacts, and shows
   the recorded error and limitations without presenting success.

---

### User Story 2 - Review History, Reports, and Evidence (Priority: P1)

A researcher can return after an app relaunch, find earlier runs, open a report, and move from each
sourced claim to its exact evidence passage and source attribution. Conflicts, uncertainty, and
integrity problems remain visible.

**Why this priority**: A research client is trustworthy only when results remain inspectable and
their evidence can be audited after execution.

**Independent Test**: Seed the app-managed workspace with completed, partial, and integrity-invalid
fixture runs, relaunch the client, locate each run, and inspect a claim, evidence passage, source,
license, retrieval date, limitations, and validation state without contacting any provider.

**Acceptance Scenarios**:

1. **Given** valid recorded runs, **When** the researcher opens History after relaunch, **Then** each
   run is listed with question, creation time, status, providers, and source/evidence/claim counts.
2. **Given** a sourced claim, **When** the researcher selects its evidence reference, **Then** the
   exact passage, locator, source identity, retrieval time, stance, and available attribution are
   shown together.
3. **Given** contradictory, retracted, corrected, unsupported, or uncertain material, **When** the
   report is viewed, **Then** the relevant warning and limitation is visible at the claim and report
   level.
4. **Given** a run whose integrity validation fails, **When** it is opened, **Then** the client enters
   a read-only warning state, identifies the validation issues, and does not silently repair or
   render the run as verified.

---

### User Story 3 - Cancel and Resume Work Safely (Priority: P2)

A researcher can request cancellation of an active run and later resume an eligible interrupted,
partial, or failed run after reviewing its saved plan and restoring required permissions.

**Why this priority**: Scientific retrieval may be slow or interrupted; controlled cancellation and
non-duplicating resume protect both user time and reproducibility.

**Independent Test**: Stop an offline fixture run after its first completed step, request
cancellation twice, relaunch the app, resume it, and prove from the event history that the completed
step was not repeated.

**Acceptance Scenarios**:

1. **Given** an active run with a known run directory, **When** the researcher requests cancellation,
   **Then** the request is acknowledged immediately, repeated requests are harmless, and the UI does
   not claim terminal cancellation until the engine records it.
2. **Given** a resumable run, **When** the researcher selects Resume, **Then** the saved plan,
   completed steps, remaining work, and permissions that must be restored are shown before approval.
3. **Given** a resumed run that previously used a network provider or credential, **When** resume is
   approved, **Then** network authorization is requested again and required secrets are reacquired
   without being read from run artifacts.
4. **Given** a completed or integrity-invalid run, **When** Resume is considered, **Then** the action
   is unavailable with a specific explanation.

---

### User Story 4 - Export a Portable Research Bundle (Priority: P2)

A researcher chooses a valid run, selects a destination, and exports a portable research bundle
that retains report, evidence, provenance, and checksums while excluding credentials and host-only
paths.

**Why this priority**: Portable, self-validating artifacts are central to sharing and reproducing
scientific work.

**Independent Test**: Export a deterministic completed run, validate the bundle offline, inspect its
contents, and confirm that a seeded credential and approved absolute local root are absent.

**Acceptance Scenarios**:

1. **Given** a valid completed or partial run, **When** the researcher chooses an unused destination,
   **Then** one ZIP bundle is created and the client reports its location and byte size.
2. **Given** a destination that already exists, **When** export is requested, **Then** replacement
   requires an explicit native confirmation and cancellation leaves the existing file unchanged.
3. **Given** a run that fails pre-export validation, **When** export is requested, **Then** no bundle
   is presented as valid and the actionable validation errors remain visible.

---

### User Story 5 - Configure Providers and Local Preferences (Priority: P2)

A researcher can inspect available source and synthesis providers, set non-secret defaults, add or
remove provider credentials, choose local document roots for a draft, and understand which choices
require network access.

**Why this priority**: Provider-neutral configuration makes the existing research engine usable
without sacrificing explicit permissions or credential hygiene.

**Independent Test**: With network access disabled, list providers, change non-secret defaults,
store and remove three fixture credentials, relaunch the app, and demonstrate that provider listing
performs no network call and no secret appears in preferences, process arguments, logs, or run data.

**Acceptance Scenarios**:

1. **Given** the Providers view, **When** it is opened, **Then** registered providers are listed with
   name, version, kind, risk, availability, and health error without contacting them.
2. **Given** a provider credential, **When** it is saved, **Then** the client stores it in the user's
   protected credential store, displays only presence or absence, and never reveals it after entry.
3. **Given** saved credentials, **When** a run starts, **Then** only credentials needed by selected
   providers are injected transiently into the child process and are absent from arguments,
   configuration files, logs, persisted artifacts, and exports.
4. **Given** a local source selection, **When** the researcher chooses a directory, **Then** that
   exact directory is shown in the draft and approved only for that run.

---

### User Story 6 - Use an Accessible Native macOS Workflow (Priority: P3)

A researcher can complete the primary workflow with standard macOS window, menu, keyboard, focus,
appearance, and assistive-technology conventions. The client clearly explains local engine or file
access failures.

**Why this priority**: A desktop client must remain operable beyond pointer-only happy paths and
must communicate failures at the same quality as successful states.

**Independent Test**: Complete the offline new-run, report inspection, cancellation, and export
flows using only the keyboard and screen-reader labels, then repeat under dark appearance,
increased contrast, and reduced motion.

**Acceptance Scenarios**:

1. **Given** the primary window, **When** the researcher uses standard menu commands and keyboard
   traversal, **Then** every primary action is reachable with a visible focus state and meaningful
   accessible name.
2. **Given** an active run, **When** its step or terminal status changes, **Then** the status is
   announced without repeatedly stealing focus.
3. **Given** an unavailable or incompatible local engine, **When** the client launches, **Then** it
   shows a diagnostic state with the detected version/path and recovery guidance rather than a
   nonfunctional research form.

### Edge Cases

- A run process exits before creating a run directory, creates no matching run directory within the
  startup deadline, or more than one run directory appears in its unique task workspace.
- The process emits a valid terminal JSON object but the recorded manifest or final event disagrees
  with it.
- The event log ends with a partially written line, contains an unknown event type, skips a sequence,
  or grows while the app is asleep.
- The app is closed normally during a run, is force-quit, or the Mac sleeps and wakes during a
  bounded provider request.
- Disk space is exhausted, the app-managed workspace becomes read-only, or a run directory/file is
  removed, replaced, or symlinked while visible in History.
- The credential store is locked, access is denied, a credential is removed during a run, or a
  selected provider requires a missing credential.
- Network permission is denied, revoked before resume, or requested for a provider whose declared
  risk changes after an engine update.
- The selected local root becomes unavailable or is replaced between plan review and execution.
- Cancellation is requested before the run directory is discovered, during a provider timeout,
  after terminal completion, or repeatedly from two UI actions.
- A history contains zero runs, duplicate run IDs, more than 100 runs, a report with 1,000 evidence
  records, non-UTF-8 text, or a source URL with a non-HTTP scheme.
- An export destination already exists, resides on an unavailable volume, or cannot be written.
- The report contains retrieved text that looks like an instruction, executable link, or credential.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The client MUST provide a native macOS application for macOS 14 or newer and MUST
  complete its offline primary workflow without an account or cloud service.
- **FR-002**: The client MUST use the existing local OpenScience research engine as the authority
  for plans, execution, validation, reports, replay state, and exports rather than reimplementing
  research orchestration in the UI.
- **FR-003**: The primary window MUST provide stable destinations for New Research, Runs, Providers,
  and Settings and MUST preserve the selected destination across ordinary relaunches.
- **FR-004**: A research draft MUST support a question, optional scope, constraints, assumptions,
  record and request limits, timeout, source providers, synthesis provider, and zero or more local
  roots.
- **FR-005**: The client MUST validate draft fields before plan generation, show field-specific
  errors, and retain valid input while errors are corrected.
- **FR-006**: The client MUST generate and display a finite plan before any source or model call.
- **FR-007**: Plan review MUST show ordered steps, dependencies, completion conditions, selected
  capabilities, risk levels, limits, and whether each provider reads local data or the network.
- **FR-008**: Plan approval MUST be an explicit action; rejection or dismissal MUST cause no source
  or model invocation.
- **FR-009**: The client MUST create a unique workspace for each execution attempt so that exactly
  one run directory can be associated with its process and UI task.
- **FR-010**: Only one mutating research execution MAY be active per app instance in the first
  release; report inspection, validation, and provider listing MUST remain available during it.
- **FR-011**: During execution the client MUST show the run identifier once known, current plan step,
  completed steps, elapsed time, provider activity category, source/evidence/claim counts when
  available, and last meaningful message.
- **FR-012**: Progress MUST be derived from the append-only event record inside the attempt's unique
  workspace; a process's terminal machine-readable result MUST NOT be treated as a progress stream.
- **FR-013**: The UI MUST distinguish `created`, `awaiting_approval`, `running`, `completed`,
  `partial`, `failed`, and `cancelled` without converting partial or failed work into success.
- **FR-014**: Provider, policy, validation, and engine failures MUST retain their error code and
  safe context and MUST offer an action appropriate to retry, resume, inspect, or change settings.
- **FR-015**: The client MUST reconcile the terminal process result with validated persisted state;
  disagreement MUST produce an integrity warning rather than an assumed terminal status.
- **FR-016**: History MUST be rebuilt from app-managed run directories after relaunch and MUST NOT
  depend solely on a mutable cache.
- **FR-017**: History MUST support status and text filtering plus newest/oldest sorting for at least
  100 recorded runs.
- **FR-018**: A run summary MUST show question, created and updated times, status, selected
  capabilities, completed steps, counts, limitations, errors, and validation state.
- **FR-019**: A report view MUST present the rendered report and a structured claims/evidence/source
  inspector without modifying recorded artifacts.
- **FR-020**: Every sourced claim shown by the client MUST link to each recorded evidence ID and show
  the exact immutable passage, locator, stance, source title, canonical identifier, retrieval time,
  and available license and URL.
- **FR-021**: The client MUST visibly distinguish sourced facts, inferences, assumptions,
  hypotheses, and unsupported claims and MUST surface contradictory, corrected, retracted,
  withdrawn, or unclear evidence and associated limitations.
- **FR-022**: Opening a recorded source URL MUST be a separate user action, MUST allow only HTTP or
  HTTPS destinations, and MUST never interpret retrieved report text as an app command.
- **FR-023**: An integrity-invalid run MUST open read-only with errors and warnings visible; the
  client MUST NOT auto-repair, rewrite, resume, or export it as valid.
- **FR-024**: Cancellation MUST be idempotent, provide immediate `requesting cancellation` feedback,
  and target the exact discovered run directory for the active attempt.
- **FR-025**: Before a run directory exists, cancelling MAY stop the pending child process but MUST
  not fabricate a persisted `cancelled` run; after discovery, the engine's recorded terminal state
  is authoritative.
- **FR-026**: Resume MUST be offered only for validated, non-completed states supported by the local
  engine and MUST display completed and remaining steps before approval.
- **FR-027**: Resume MUST require explicit approval again and MUST reacquire all network grants,
  local roots, and required credentials rather than treating prior access as current authority.
- **FR-028**: A resumed run MUST preserve event history and MUST NOT repeat a step already recorded
  as completed.
- **FR-029**: Export MUST use a native destination chooser and MUST require explicit confirmation
  before replacing an existing file.
- **FR-030**: Export MUST validate the selected run first and use the engine's export capability to
  create a portable ZIP with report, evidence, claims, provenance, checksums, and research-object
  metadata.
- **FR-031**: Export success MUST report the resolved destination and byte size; cancellation and
  failure MUST leave no new artifact presented as successful.
- **FR-032**: Providers MUST be listed through a local, non-networking discovery operation and show
  name, immutable version, kind, risk, availability, and health error.
- **FR-033**: Non-secret preferences MAY include appearance, default limits, contact email, default
  provider names, and a development engine location; they MUST NOT include credentials or implicit
  network approval.
- **FR-034**: OpenAlex, Crossref, and model credentials MUST be stored only in the macOS credential
  store, represented in UI only by presence/absence, and removable independently.
- **FR-035**: For a selected provider, its credential MUST be injected only into the launched child
  process environment under the documented provider-specific name; it MUST NOT appear in process
  arguments, model configuration, preferences, logs, progress messages, run records, or exports.
- **FR-036**: The client MUST scrub credential values from its in-memory launch environment as soon
  as practical after process creation and MUST redact matching values from all diagnostics before
  persistence or display.
- **FR-037**: Network access MUST default to denied. Every new run and every resume using a
  network-read capability MUST require a confirmation summarizing providers, destination category,
  local data exposure, and maximum requests before the client grants network access.
- **FR-038**: A prior network confirmation MUST NOT become a permanent or preselected grant, and the
  client MUST pass network authorization to the engine only after the current confirmation.
- **FR-039**: Local document roots MUST be selected through a native directory chooser, displayed
  before plan approval, and granted to the engine only for the current run or resume attempt.
- **FR-040**: The first release MUST NOT claim App Store sandbox containment or persistent
  security-scoped file authorization; those capabilities require a later, separately specified
  release.
- **FR-041**: The client MUST detect an unavailable or incompatible engine before enabling run
  creation and show detected path, version, expected compatibility, and recovery guidance.
- **FR-042**: The client MUST launch the engine without a shell, pass each argument as a distinct
  value, use an attempt-specific working directory, bound captured output, and handle timeout,
  termination, malformed output, and unexpected exit as typed failures.
- **FR-043**: Terminal machine-readable mode MUST accept exactly one final JSON object on standard
  output; additional output, invalid UTF-8, or an object inconsistent with the exit code MUST be
  treated as a bridge error.
- **FR-044**: The event reader MUST consume only newline-terminated records, tolerate a partial final
  line while the file is growing, deduplicate already consumed sequence numbers, and identify gaps
  or malformed records without inventing progress.
- **FR-045**: Normal app termination during an active run MUST ask whether to remain or request
  cancellation; forced termination or process crash MUST leave recorded state available for later
  validation and resume.
- **FR-046**: The client MUST support standard macOS menu commands, keyboard traversal, visible focus,
  light and dark appearances, increased contrast, and reduced motion for primary workflows.
- **FR-047**: Every interactive control, progress status, claim type, evidence stance, warning, and
  error MUST expose a meaningful accessible name/value, and material asynchronous status changes
  MUST be announced without moving keyboard focus.
- **FR-048**: Window restoration MAY retain navigation and non-secret draft content but MUST NOT
  restore credentials, network grants, plan approvals, or a false active-run state.
- **FR-049**: The client MUST send no telemetry, analytics, research content, or crash report to a
  remote service in the first release.
- **FR-050**: User-facing diagnostics and optional local support exports MUST be redacted, bounded,
  and explicit about which local files are included.

### Key Entities

- **Research Draft**: Mutable, non-secret user input and provider selections before a plan exists.
- **Plan Review**: Immutable engine-generated plan plus displayed risks and a current explicit
  approval decision.
- **Execution Attempt**: One client-launched process, its unique task workspace, discovered run
  directory, lifecycle, and terminal result.
- **Desktop Run Summary**: Read-only projection of a validated recorded run for History.
- **Progress Cursor**: Last complete event sequence consumed for one run and any detected gap or
  decode issue.
- **Claim View**: A claim classification, limitations, confidence, and links to evidence records.
- **Evidence View**: Exact passage, locator, stance, content identity, and linked source.
- **Source View**: Attribution, identifiers, status, retrievals, license, and safe landing URL.
- **Provider Profile**: Provider identity, kind, risk, availability, health, and non-secret defaults.
- **Network Grant**: Ephemeral, per-attempt user authorization for named network capabilities and
  bounded requests.
- **Credential Reference**: Provider-specific presence metadata pointing to protected credential
  storage, never the secret value itself.
- **Export Job**: A run, chosen destination, replacement decision, validation outcome, and result.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a clean first-use study with at least 10 first-time participants, at least 90%
  complete an offline fixture research run without command-line assistance within 3 minutes.
- **SC-002**: For 100 deterministic runs, 95% of persisted step events are reflected in the visible
  progress state within 500 milliseconds of a complete event line becoming readable; all are
  reflected within 2 seconds.
- **SC-003**: Across the deterministic acceptance corpus, 100% of displayed sourced claims navigate
  to the correct exact evidence passage and source attribution.
- **SC-004**: After relaunch, a history of 100 valid runs becomes searchable and usable within 2
  seconds on the supported baseline Mac.
- **SC-005**: A cancellation action displays acknowledgement within 1 second, and 100% of repeated
  cancellation requests leave one consistent terminal record once the engine reaches a safe stop.
- **SC-006**: In every interruption checkpoint acceptance case, resume completes without repeating
  any step already recorded as completed.
- **SC-007**: 100% of exported acceptance bundles validate offline and contain no seeded credential,
  transient environment value, or approved absolute local-root path.
- **SC-008**: In automated and manual permission tests, zero network request is sent before a
  per-run or per-resume confirmation, and declining confirmation causes zero network request.
- **SC-009**: Secret canary scans find zero credential value in process arguments, configuration,
  preferences, app logs, progress UI, run artifacts, and export bundles.
- **SC-010**: All primary workflows—new run, plan approval, progress inspection, cancellation,
  history/report inspection, resume, provider configuration, and export—are completable using only
  the keyboard and have no critical screen-reader accessibility finding.
- **SC-011**: In forced-quit, engine-crash, sleep/wake, disk-full, and malformed-event acceptance
  tests, 100% of affected runs are labeled with their actual validated state and none is shown as a
  fabricated success.
- **SC-012**: A report containing 1,000 evidence records opens with its first usable content within
  2 seconds and evidence selection responds within 250 milliseconds on the supported baseline Mac.
- **SC-013**: Provider discovery completes without observed network traffic and reports all built-in
  provider health records in 100% of fixture tests.
- **SC-014**: The first release generates zero automatic telemetry, analytics, research-content, or
  crash-report request in a monitored end-to-end session.

## Assumptions

- The first release targets a single local macOS user on macOS 14 or newer.
- Performance acceptance uses an Apple M1 Mac with 8 GB memory, local SSD, and macOS 14 as the
  supported baseline; equivalent or faster supported Macs may be reported separately.
- The application is built with the system-native macOS UI stack and invokes the existing Python
  engine through its versioned command-line and JSON contracts.
- Development builds may resolve an explicitly configured engine from the repository environment.
  The app-bundle script also supports an optional fixed-version self-contained helper at
  `Contents/Helpers/openscience`; that variant requires no user-managed Python, while a bundle built
  without it truthfully requires a compatible development engine before run creation is enabled.
- The first release is an unsandboxed development/direct-distribution build. App Store sandboxing,
  persistent security-scoped bookmarks, Developer ID distribution signing, notarization, and
  automatic updates are not delivered or claimed by this feature. A local ad-hoc bundle seal is not
  represented as distribution signing.
- One mutating research run at a time is sufficient; users may inspect any recorded run concurrently.
- The app-managed workspace is the source for History. Importing arbitrary external run folders is
  deferred.
- Simplified Chinese is the initial user-interface language; text is externalized so English and
  additional localization can follow without changing research or bridge contracts.
- Existing provider contracts and run formats remain authoritative and may receive only additive,
  versioned desktop-bridge behavior.
- Users understand that research output requires human scientific and domain review.

## Out of Scope

- Windows, Linux, iOS, iPadOS, and web clients.
- User accounts, cloud execution, remote storage, sync, collaboration, or team administration.
- App Store sandboxing, persistent security-scoped bookmarks, Developer ID distribution signing,
  notarization, auto-update, and claims of Gatekeeper-ready distribution.
- Multiple simultaneous mutating research runs in one app instance.
- Editing the structural plan graph, writing or modifying source documents, or auto-repairing run
  artifacts.
- External publication, messaging, purchases, destructive source-file operations, or unreviewed
  execution of retrieved instructions.
- A provider marketplace, credential synchronization, or browser-based authentication.
- General semantic contradiction detection beyond faithfully displaying recorded stances and
  limitations.
