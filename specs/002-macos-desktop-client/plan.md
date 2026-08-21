# Implementation Plan: Native macOS Desktop Client

**Branch**: `agent/macos-desktop-client` | **Date**: 2026-08-21 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/002-macos-desktop-client/spec.md`

## Summary

Build a native SwiftUI macOS 14+ client around the existing provider-neutral Python research
engine. The app owns presentation, per-attempt workspace allocation, local preferences, Keychain
references, process supervision, event-log tailing, history projections, and accessible macOS
interactions. The Python engine remains authoritative for plans, execution, policy, evidence,
validation, replay, reports, and export.

Every `run --json` or `resume --json` process writes exactly one terminal JSON object to stdout.
The app obtains progress by giving that process a unique empty workspace, discovering the single
`run-*` child directory created there, and incrementally reading that run's `events.jsonl`.
Cancellation targets that exact directory. OpenAlex, Crossref, and model credentials are loaded
from Keychain and injected only into the child environment as
`OPENSCIENCE_OPENALEX_API_KEY`, `OPENSCIENCE_CROSSREF_API_KEY`, and
`OPENSCIENCE_MODEL_API_KEY`.

The first release is an unsandboxed development/direct-distribution build with no cloud backend or
telemetry. App Store sandboxing, persistent security-scoped bookmarks, Developer ID distribution
signing, notarization, and auto-update remain follow-up work and are not release claims. A local
ad-hoc bundle seal, when added by the build toolchain, is not a distribution-security claim.

## Technical Context

**Language/Version**: Swift tools/language mode 5.10 for the macOS package; existing Python 3.11+
engine

**Primary Dependencies**: SwiftUI, AppKit where native panels/lifecycle integration are required,
Foundation, Security, UniformTypeIdentifiers, OSLog; existing `openscience-agent` Python package;
no third-party macOS runtime dependency

**Storage**: Engine-owned immutable run directories and JSON/JSONL/Markdown artifacts under
Application Support; a rebuildable desktop history index; UserDefaults for non-secret preferences;
macOS Keychain for credentials; temporary attempt/plan files with restrictive permissions

**Testing**: SwiftPM/XCTest unit and app-state integration targets, deterministic fake process and
file-system adapters, existing pytest contract/integration suites, `swift test`, manual native
accessibility inspection, and shell-driven app/helper packaging smoke tests

**Target Platform**: macOS 14.0+ on Apple silicon and Intel Macs supported by that OS release;
development and direct-distribution builds

**Project Type**: Native desktop application plus additive adapters on an existing CLI/library

**Performance Goals**: Complete event lines reflected within 500 ms at p95 and 2 seconds maximum;
100-run history usable within 2 seconds; 1,000-evidence report first content within 2 seconds and
selection response within 250 ms; no main-thread process or file parsing

**Constraints**: Zero cloud backend and telemetry; one active mutating run; terminal stdout is one
JSON object; progress comes only from the unique run event file; network denied by default;
credentials absent from argv/config/logs/artifacts; bounded subprocess output; retrieved text is
untrusted; app remains useful offline

**Scale/Scope**: One local user, one primary app window, one active execution, 100 indexed runs,
1,000 evidence records per report acceptance fixture, built-in and entry-point providers exposed
through the current registry

## Constitution Check

*GATE: Evaluated before Phase 0 research and re-checked after Phase 1 design.*

| Principle / Gate | Pre-research result | Post-design result | Design evidence |
|------------------|---------------------|--------------------|-----------------|
| I. Evidence Before Narrative | PASS | PASS | The report inspector preserves claim kinds and exact evidence/source links; invalid or conflicting evidence is visibly labeled. |
| II. Reproducibility by Construction | PASS | PASS | The engine remains the run authority; the desktop reads immutable artifacts/events and validates before resume/export. |
| III. Human Authority and Bounded Autonomy | PASS | PASS | Plan approval, per-attempt network grants, local-root selection, cancel, resume, URL opening, and replacement export are explicit actions. |
| IV. Modular, Provider-Neutral Core | PASS | PASS | Swift depends on documented CLI/artifact contracts, not Python internals or a vendor-specific provider. |
| V. Verification and Transparent Failure | PASS | PASS | Deterministic process/file fixtures, CLI contract tests, UI tests, typed bridge errors, partial states, and integrity reconciliation are required. |
| Secrets and sensitive data absent from persisted artifacts | PASS | PASS | Keychain references and child-only environment injection are specified; canary scans cover args, logs, configs, runs, and exports. |
| Retrieved data cannot change policy or execute actions | PASS | PASS | Reports are rendered as inert text/structured records; only allowlisted HTTP(S) links may be opened by explicit action. |
| New integration has typed contract and failure tests | PASS | PASS | `contracts/cli-bridge.md` versions every command, artifact, exit, secret, and failure boundary. |
| End-to-end release candidate is inspectable and replayable | PASS | PASS | Quickstart requires a fresh fixture run, validation, exact citation traversal, cancellation/resume, and offline export validation. |

No constitution violation or unresolved clarification remains.

## Architecture

### Components

1. **App Shell**: Window, navigation split view, commands, scene restoration, onboarding, and global
   active-attempt presentation.
2. **Feature Views**: Composer/plan review, active run, history, report/evidence inspector,
   providers/settings, and export presentation.
3. **Desktop Domain**: Value types and state machines that mirror, but do not replace, versioned
   engine records.
4. **Engine Bridge**: Executable resolution, argument construction, environment construction,
   process lifecycle, one-object terminal decoding, bounded diagnostics, and exit-code mapping.
5. **Attempt Workspace Monitor**: Unique workspace allocation, single `run-*` discovery,
   newline-safe `events.jsonl` cursoring, deduplication, gap detection, and cancellation target
   publication.
6. **Run Repository**: Safe read-only artifact loading, engine validation/inspect calls, rebuildable
   index, file change invalidation, and report projections.
7. **Security Services**: Keychain facade, secret redaction set, network grant lifetime, native file
   chooser, and HTTP(S)-only external-link policy.
8. **Distribution Support**: Development engine resolver, PyInstaller helper entry point, and
   direct app-bundle assembly. `Contents/Helpers/openscience` is optional but preferred when present.
   This layer explicitly does not provide sandbox, Developer ID distribution signing, notarization,
   or auto-update.

### Data Flow

```text
Researcher
  -> ResearchDraft
  -> openscience plan --json --output <attempt>/plan.json
  -> PlanReview + explicit approval
  -> per-run NetworkGrant + selected Keychain secret references
  -> unique <attempt-workspace>/ + child process environment
  -> openscience run --json --workspace <attempt-workspace> --plan ... --yes
       -> exactly one <attempt-workspace>/run-*/events.jsonl (progress authority)
       -> exactly one terminal JSON object on stdout
       -> immutable run artifacts/manifest (result authority after validation)
  -> validate + reconcile
  -> History / ReportEvidenceView / Resume / Export
```

### Trust Boundaries

- **UI to bridge**: Draft data is validated, arguments are passed as an array without a shell, and
  only known options are constructed.
- **App to child environment**: A fresh environment map receives only selected secrets under the
  three documented variable names; values are never copied into argv or persisted config and are
  removed from retained in-memory launch state after spawn.
- **App to network**: The child receives `--allow-network` only after a current per-attempt grant.
  Provider listing never receives it.
- **App to local files**: The unsandboxed first release uses a native chooser and passes only exact
  roots selected for the attempt. It does not claim security-scoped persistence.
- **Engine artifacts to UI**: JSON, JSONL, Markdown, retrieved text, paths, and URLs are untrusted
  input. Size limits, schema decoding, root containment, validation, inert rendering, and HTTP(S)
  allowlisting apply.
- **Terminal process to recorded state**: A successful exit/final JSON is necessary but not
  sufficient; manifest/event validation and status reconciliation determine the visible result.
- **Support diagnostics**: OSLog metadata and local support exports are bounded and redacted before
  display or persistence; research text is excluded unless the user explicitly includes it.

## Project Structure

### Documentation (this feature)

```text
specs/002-macos-desktop-client/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── cli-bridge.md
│   └── ui-contract.md
├── checklists/
│   └── requirements.md
└── tasks.md
```

### Source Code (repository root)

```text
macos/OpenScienceDesktop/
├── Package.swift
├── App/
│   ├── Info.plist
│   ├── Assets.xcassets/
│   └── Resources/
├── Sources/
│   ├── OpenScienceCore/
│   │   ├── CLIClient.swift
│   │   ├── CLICommand.swift
│   │   ├── JSONValue.swift
│   │   ├── Models.swift
│   │   ├── RunRepository.swift
│   │   ├── KeychainStore.swift
│   │   ├── Redactor.swift
│   │   └── [focused bridge/state/repository files]
│   └── OpenScienceDesktop/
│       ├── OpenScienceDesktopApp.swift
│       ├── AppModel.swift
│       ├── ClientSettings.swift
│       ├── RootView.swift
│       └── [feature views/coordinators]
├── Tests/
│   ├── OpenScienceCoreTests/
│   └── OpenScienceDesktopTests/
└── scripts/
    └── build-app.sh

packaging/macos/
└── openscience_helper.py

scripts/
└── build-macos-helper.sh

src/openscience_agent/
└── cli.py                         # additive env credential support only

tests/
├── contract/test_cli.py           # terminal JSON and environment contracts
└── integration/test_security.py   # cross-boundary secret canaries
```

**Structure Decision**: Keep the existing Python package and orchestration unchanged except for an
additive CLI composition adapter that reads OpenAlex/Crossref credentials from documented
environment variables. Use the repository's `macos/OpenScienceDesktop` Swift Package: a reusable
`OpenScienceCore` target owns typed bridge/security/storage behavior, and the `OpenScienceDesktop`
executable target owns SwiftUI/AppKit presentation. `build-app.sh` creates the unsandboxed app
bundle; the optional helper is built from `packaging/macos/openscience_helper.py` through
`scripts/build-macos-helper.sh`. Do not introduce a daemon, local HTTP server, web UI, database, or
vendor SDK.

## Phase 0: Research Outcomes

The decisions and rejected alternatives are recorded in [research.md](research.md). Key outcomes:

- SwiftUI with minimal AppKit interop is the first-party native UI path.
- The existing CLI plus files is a smaller and safer boundary than an embedded Python API or local
  server.
- Terminal stdout remains a one-object result channel; the unique workspace/event file is the
  progress and cancellation-discovery channel.
- Keychain-to-child-environment injection is the credential path for all three supported secrets.
- Application Support artifacts plus a rebuildable index preserve engine authority.
- Direct development/distribution is explicit; sandbox, Developer ID signing, notarization, and
  bookmarks are deferred rather than simulated.

## Phase 1: Design Outcomes

- [data-model.md](data-model.md) defines desktop state, validation, relationships, and transitions.
- [contracts/cli-bridge.md](contracts/cli-bridge.md) defines process, workspace, event, terminal,
  credential, exit, and compatibility contracts.
- [contracts/ui-contract.md](contracts/ui-contract.md) defines views, actions, state presentation,
  accessibility, permissions, and native interaction behavior.
- [quickstart.md](quickstart.md) defines deterministic build and end-to-end validation scenarios.

## Implementation Sequence

1. Establish the Xcode project, pure desktop domain types, and fakeable infrastructure protocols.
2. Write failing Python/Swift contract tests for terminal JSON, unique workspace discovery, event
   cursoring, environment secrets, redaction, and engine compatibility.
3. Implement the engine bridge, workspace monitor, run repository, Keychain facade, and app shell.
4. Deliver the offline New Research → Plan → Run → Progress vertical slice.
5. Add validated History and evidence-backed report inspection.
6. Add cancel/resume, export, providers/settings, and native accessibility behavior.
7. Run adversarial secret/integrity tests, performance fixtures, clean-machine direct build, and
   the complete quickstart. Do not add release claims for deferred distribution security work.

## Complexity Tracking

| Complexity | Why Needed | Simpler Alternative Rejected Because |
|------------|------------|--------------------------------------|
| Direct-distribution engine runtime assembly | A desktop build should run the pinned local engine without asking end users to install Python. | Requiring a user-managed interpreter makes engine compatibility and first-use behavior non-reproducible. |
| File-backed progress cursor alongside a terminal process result | The current CLI intentionally reserves JSON stdout for exactly one terminal object while persisted events are the audit authority. | Parsing human stderr or changing stdout to a stream would break the existing machine contract; adding a daemon/server creates a larger trust boundary. |

Neither item violates the constitution: both preserve the existing authority and are isolated behind
typed, testable adapters.
