# Research: Native macOS Desktop Client

## Decision 1: Native UI stack

**Decision**: Use SwiftUI in Swift tools/language mode 5.10 for macOS 14+, with narrow AppKit interop only for
open/save panels, application termination coordination, and behaviors SwiftUI does not expose
reliably.

**Rationale**: This produces native controls, accessibility semantics, system appearance support,
menus, window behavior, and a maintainable first-party stack without a browser runtime.

**Alternatives considered**:

- Electron or another web shell: rejected because it duplicates platform behavior, increases the
  runtime/security surface, and adds no value to this local-first UI.
- AppKit-only UI: rejected because it adds boilerplate where SwiftUI already satisfies the target.
- Catalyst: rejected because the product is macOS-first rather than an iPad port.

## Decision 2: Engine integration boundary

**Decision**: Treat the installed or packaged `openscience` executable, its JSON outputs, and its
recorded artifacts as the only macOS-to-engine integration boundary. Never import Python into the
Swift process and never create a local HTTP service.

**Rationale**: The CLI is already tested, provider-neutral, policy-enforcing, and artifact-oriented.
A process boundary contains crashes and preserves the constitution's typed modular core.

**Alternatives considered**:

- Embed CPython and call package functions directly: rejected because interpreter lifecycle, GIL,
  extension loading, and mixed crash domains produce a larger integration surface.
- Local REST/WebSocket daemon: rejected because it adds ports, authentication, lifecycle, and
  another protocol without a remote-service requirement.
- Reimplement orchestration in Swift: rejected because it would split provenance and policy
  authority and immediately violate provider neutrality.

## Decision 3: Terminal result and progress channels

**Decision**: Keep `run --json` and `resume --json` stdout as exactly one terminal JSON object. For
each task the client creates a unique empty workspace, passes it with `--workspace` for a new run,
discovers exactly one immediate `run-*` directory, and tails only that directory's `events.jsonl`.
The discovered directory becomes the cancel target and recorded-state authority.

**Rationale**: The event log is append-only, auditable, replayable, and already binds progress to a
specific run. A unique workspace removes ambiguous directory correlation without weakening the
existing one-object CLI JSON contract.

**Alternatives considered**:

- Convert stdout into NDJSON progress: rejected because it breaks the established single-object
  machine output and duplicates persisted events.
- Parse human-readable stderr: rejected because diagnostics are not a versioned state protocol.
- Poll a shared workspace for the newest run: rejected because concurrent or stale directories can
  associate the UI with the wrong cancellation target.

## Decision 4: Event file monitoring

**Decision**: Implement a cursor that reads only complete newline-terminated JSON records, records
the last accepted sequence and byte offset, ignores duplicate sequences, flags gaps/malformed
records, and re-reads after coalesced file-system notifications and wake events. A short bounded
fallback poll may recover missed notifications; it never invents state.

**Rationale**: File notifications signal that content may have changed but do not guarantee one
notification per append. Cursor semantics must survive partial writes, sleep/wake, and app relaunch.

**Alternatives considered**:

- Decode the entire file after every change: rejected due avoidable work for long runs and weaker
  partial-line behavior.
- Treat a partial final line as corruption immediately: rejected because a writer may still be
  completing an append.
- Trust event messages without terminal validation: rejected because presentation cannot replace
  whole-run integrity validation.

## Decision 5: Credential storage and injection

**Decision**: Store OpenAlex, Crossref, and model secrets as separate generic-password Keychain
items. At launch time fetch only selected-provider secrets, create a fresh child environment, and
set `OPENSCIENCE_OPENALEX_API_KEY`, `OPENSCIENCE_CROSSREF_API_KEY`, and
`OPENSCIENCE_MODEL_API_KEY`. Never pass secret values in argv or a model configuration file. Remove
the values from retained launch state immediately after process creation and redact canary matches
from all diagnostics.

**Rationale**: Keychain provides platform-protected local storage. Environment injection avoids
command-line disclosure and keeps secrets out of the engine's persisted configuration and artifact
model. The Python CLI needs only an additive composition-layer fallback for the two source keys;
the model adapter already supports its environment variable.

**Alternatives considered**:

- Command-line credential flags: rejected because process arguments can be inspected and are easy
  to log.
- Plain configuration or UserDefaults: rejected because they are not secret stores.
- A temporary plaintext secret file: rejected because cleanup after crash is not reliable.
- Credential synchronization: rejected because the feature has no account or cloud scope.

## Decision 6: Network authorization lifetime

**Decision**: Construct a `NetworkGrant` only after a run/resume confirmation that names the selected
network providers, destination category, local-data exposure, and request cap. The grant lives only
for that execution attempt and controls whether `--allow-network` is passed.

**Rationale**: Provider selection is not permission. Per-attempt approval preserves human authority
when providers, data, limits, or risk descriptors change.

**Alternatives considered**:

- A permanent “always allow network” preference: rejected because it turns a consequential grant
  into an invisible default.
- Rely only on provider settings: rejected because a configured credential is not authorization to
  transmit.
- Ask once per individual HTTP request: rejected as unusable; bounded per-attempt capability
  approval is specific and reviewable.

## Decision 7: Local file authorization in the first release

**Decision**: Use the native directory chooser, retain the chosen URL only for the draft/attempt,
and pass the exact root to the engine. The first release is unsandboxed and does not store or claim
security-scoped bookmarks.

**Rationale**: This truthfully matches development/direct-distribution capabilities. Requiring the
researcher to reselect roots on resume keeps authorization current and avoids pretending a later
sandbox model already exists.

**Alternatives considered**:

- Persist ordinary paths as durable authorization: rejected because a saved string is not a current
  user grant and may refer to replaced content.
- Implement security-scoped bookmarks immediately: rejected because App Store sandboxing is
  explicitly deferred and bookmark correctness belongs to that follow-up design.
- Grant broad home-directory access: rejected because it violates least scope and user intent.

## Decision 8: Local persistence and history

**Decision**: Place app attempts/runs under Application Support. Treat engine artifacts as the source
of truth and maintain only a rebuildable, schema-versioned history index containing non-secret
summary fields and artifact fingerprints. Validate a run before enabling resume/export and
invalidate cached summaries when fingerprints change.

**Rationale**: A cache improves relaunch performance but cannot supersede provenance records.
Rebuilding from run directories handles cache deletion or corruption without data loss.

**Alternatives considered**:

- Core Data/SQLite as run authority: rejected because it creates a second mutable representation of
  immutable JSON artifacts.
- No index: viable at tiny scale but rejected because the acceptance scope requires responsive
  filtering across 100 runs.
- Import arbitrary run folders in v1: deferred to avoid broad path-trust and lifecycle scope.

## Decision 9: Report and evidence presentation

**Decision**: Render recorded Markdown with a constrained native presentation and build the evidence
inspector from decoded claims/evidence/sources. Retrieved content is inert. Only explicit HTTP(S)
source-link actions may leave the app, after scheme and URL validation.

**Rationale**: Structured records provide exact attribution and accessible navigation. Avoiding a
general WebView prevents report text, scripts, custom schemes, or remote content from becoming an
execution surface.

**Alternatives considered**:

- Load report HTML in an unrestricted WebView: rejected because it expands the untrusted-content
  boundary.
- Show only the prose report: rejected because it hides claim kinds and exact evidence linkage.
- Re-synthesize summaries in the app: rejected because it creates unrecorded claims.

## Decision 10: Process supervision and concurrency

**Decision**: Permit one active mutating engine process per app instance. Use an actor-isolated
supervisor with a state machine, bounded stdout/stderr capture, explicit startup/terminal deadlines,
and a separate `openscience cancel <run-dir> --json` process after run discovery. Before discovery,
cancel may terminate the pending process but cannot create a fake run state.

**Rationale**: One execution makes permissions, Keychain lifetime, progress ownership, and app
termination predictable while still allowing read-only report inspection.

**Alternatives considered**:

- Unlimited concurrent runs: deferred because it adds scheduling and cross-run permission/error UI
  without first-release value.
- Use process termination as normal cancellation: rejected because it bypasses the engine's
  idempotent cancellation record once a run exists.
- Keep runs alive after the app exits: deferred because a helper/daemon lifecycle is out of scope.

## Decision 11: Development and direct-distribution runtime

**Decision**: During development, resolve the CLI from an explicit non-secret absolute path. Build
the SwiftPM executable into an unsandboxed `OpenScience.app` with
`macos/OpenScienceDesktop/scripts/build-app.sh`. Optionally create a fixed-version PyInstaller helper
through `scripts/build-macos-helper.sh` and place it at `Contents/Helpers/openscience`; the resolver
always prefers it when present. Do not claim Developer ID distribution signing, notarization,
sandboxing, Gatekeeper readiness, or automatic updating. A local ad-hoc bundle seal is not such a
claim.

**Rationale**: Developers retain a fast edit/test loop, while a desktop artifact can pin the engine
without requiring end-user Python setup. Deferred security/distribution claims remain honest.

**Alternatives considered**:

- Require every user to install Python and the package: rejected because first-use compatibility is
  fragile and not a complete desktop experience.
- Produce a Developer ID-signed/notarized installer in this feature: rejected because credentials,
  entitlements, release identity, and hardened-runtime validation require separate authorization
  and scope.
- Mac App Store packaging now: rejected because sandbox file/process behavior needs its own design.

## Decision 12: Testing strategy

**Decision**: Use TDD at each boundary: pure Swift domain and decoder tests, fake process/file/clock/
Keychain adapters, SwiftPM app-state integration tests with deterministic workspaces, Python CLI
contract tests for environment credentials and terminal output, fixture end-to-end runs, secret
canaries, corruption matrices, and performance fixtures. Verify native keyboard/assistive behavior
with a recorded manual Accessibility Inspector gate. Live providers remain explicit opt-in tests.

**Rationale**: Desktop failures cross process, filesystem, security, and UI boundaries. Deterministic
fixtures make those failures reproducible while retaining small opt-in live smoke tests.

**Alternatives considered**:

- UI snapshots alone: rejected because they do not test provenance, permissions, process behavior,
  or accessibility semantics.
- Live-provider end-to-end tests by default: rejected because they are nondeterministic and can send
  data without an interactive grant.
- Manual testing only: rejected under the constitution's verification gate.

## Decision 13: Accessibility and native behavior

**Decision**: Use semantic controls and labels, keyboard-first focus order, standard commands, status
announcements for material asynchronous changes, reduced-motion alternatives, contrast-aware system
colors, and a minimum resizable layout rather than custom-drawn controls.

**Rationale**: Native accessibility is a release behavior, not a post-hoc visual check. Standard
semantics also reduce implementation complexity and improve testability.

**Alternatives considered**:

- Defer accessibility until visual polish: rejected because retrofitting semantics and focus order
  is costly and violates the independently testable user story.
- Custom canvas-based UI: rejected because it loses native semantics without a research need.

## Decision 14: Privacy and diagnostics

**Decision**: Send no telemetry or crash reports. Use privacy-marked local diagnostics with bounded
buffers and a central redactor seeded by selected Keychain values. Any support export is local,
previewable, opt-in, and excludes research content by default.

**Rationale**: Research questions and unpublished sources may be sensitive; no remote diagnostic
service is required for a local-first first release.

**Alternatives considered**:

- Default analytics/crash SDK: rejected because it adds an undisclosed network path and third-party
  data processor.
- Unbounded verbose engine logs: rejected because they can leak source content and harm performance.
