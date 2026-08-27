# OpenScience macOS desktop client

> **Distribution boundary:** this is a macOS 14+ development/direct-distribution client. The build
> script creates only a local ad hoc code signature. It does not provide App Sandbox containment,
> security-scoped bookmarks, Developer ID signing, notarization, Gatekeeper-ready distribution,
> automatic updates, or App Store delivery.

The native SwiftUI client runs the existing OpenScience engine locally. It has no account, cloud
backend, telemetry, analytics, or automatic crash-report upload. The Python engine remains the
authority for planning, execution, validation, replay, reports, and export.

## Verify a checkout

The release verification script is the shortest way to validate the complete local boundary:

```bash
./scripts/verify-macos-client.sh
```

It performs these checks in order:

1. frozen Python dependency sync, formatting, lint, strict typing, and deterministic tests;
2. Swift formatting and release build;
3. Swift test discovery and execution;
4. standalone engine-helper assembly;
5. `.app` assembly, `Info.plist` validation, helper placement, and ad hoc signature validation;
6. a real offline `plan → run → validate → inspect → replay → export` journey;
7. run and ZIP validation plus secret-canary scanning.

Swift test discovery is deliberately fail-closed. A local Command Line Tools installation without
an XCTest runtime is reported as `SKIP`, never as a test pass. CI and a full Xcode installation must
discover at least one Swift test or the script fails.

The verification script uses a temporary directory and removes its build/journey artifacts when it
finishes. It never interprets a successful ad hoc seal as distribution signing or notarization.

### Latest development-preview evidence

Conversation-workbench candidate validated locally on 2026-08-27:

| Gate | Result |
|---|---|
| Primary UI | Native three-column project/conversation, timeline/composer, and research preview |
| Python deterministic suite | 140 passed; 3 explicit live tests deselected |
| Python format/lint/types | Ruff format/check and strict mypy passed |
| Swift format/build | Strict format plus warnings-as-errors Debug and Release builds passed |
| Swift XCTest execution | GitHub full-Xcode macOS CI: 83 passed, 0 failures |
| App bundle | Embedded helper, `Info.plist`, helper JSON response, and deep ad hoc signature verified |
| Visual QA | Exact 1487 × 1058 comparison and inert PDF preview recorded; strict 0.90 similarity remains blocked |

The candidate closes reviewed cross-conversation action and exact-citation binding failures. It is
not a claim that the complete feature-003 transaction, VoiceOver, performance, moderated-usability,
or production-distribution gates have passed. See [`design-qa.md`](../design-qa.md) and the
[conversation-workbench quickstart](../specs/003-conversation-workbench/quickstart.md).

Previous feature-002 baseline evidence follows for the unchanged engine bridge:

Validated locally on 2026-08-21 with macOS 26.4.1 on Apple silicon, Swift 6.2.4, and Python
3.11.15:

| Gate | Result |
|---|---|
| Python deterministic suite | 140 passed; 3 explicit live tests deselected |
| Swift format and clean release build | Passed; every app and test target compiled |
| Swift XCTest execution | GitHub full-Xcode macOS 15 CI: 59 passed, 0 failures |
| App bundle | 13 MB arm64 bundle; `Info.plist` and deep strict ad hoc signature verified |
| App executable SHA-256 | `61648b476697e7561b21499b05b3360af43d607ceb4353248cca6efc4561ef25` |
| Bundled helper SHA-256 | `92dd2a2280b0b69b5a71f1c2c73f6b762bebd1302d9a523e89916800b7663ff7` |
| Offline run | `run-20260821T051942Z-0f7b6f6e`: completed; 3 sources, 3 evidence, 3 claims, 26 events |
| Validate and replay | Both passed with `completed` status |
| Export | 19,633-byte self-validating ZIP; SHA-256 `78521e4258f61ef0d130b1c6b4cdd11ecaa223e43dd353ab8c7592f34694935f` |

Local Command Line Tools cannot execute XCTest, but GitHub full-Xcode CI executed all 59 tests.
Computer Use and Accessibility Inspector were unavailable in this session. Visual layout, real
screen-reader behavior, Developer ID signing, notarization, and App Sandbox remain explicit manual
or later-release gates.

## Run a development client

Prerequisites:

- macOS 14 or newer;
- Swift 5.10 or newer;
- Python 3.11 or newer;
- [`uv`](https://docs.astral.sh/uv/).

Prepare the engine and confirm its machine-readable contract:

```bash
uv sync --frozen --all-groups
uv run openscience --version
uv run openscience providers --json
```

Build an app without an embedded helper:

```bash
OUTPUT_DIR="$PWD/.build/macos-development" \
CONFIGURATION=debug \
  ./macos/OpenScienceDesktop/scripts/build-app.sh

open .build/macos-development/OpenScience.app
```

In **Settings**, choose the absolute development engine path:

```text
<checkout>/.venv/bin/openscience
```

The client probes `openscience --version` before enabling mutating research actions. The current
desktop contract accepts compatible `0.1.x` engines. An absent, non-executable, malformed, or
incompatible engine leaves existing local history readable but disables new execution.

## Build a self-contained development app

The helper build uses PyInstaller to package the current architecture's Python engine. Build the
helper and place it into a separate app bundle:

```bash
OPENSCIENCE_HELPER_OUTPUT="$PWD/.build/macos-helper" \
OPENSCIENCE_HELPER_WORK="$PWD/.build/macos-helper-work" \
  ./scripts/build-macos-helper.sh

OUTPUT_DIR="$PWD/.build/macos-self-contained" \
CONFIGURATION=release \
OPENSCIENCE_HELPER_PATH="$PWD/.build/macos-helper/openscience" \
  ./macos/OpenScienceDesktop/scripts/build-app.sh

.build/macos-self-contained/OpenScience.app/Contents/Helpers/openscience --version
open .build/macos-self-contained/OpenScience.app
```

When present, `Contents/Helpers/openscience` takes precedence over a configured development path.
The helper is a fixed build input, but the resulting app remains an architecture-specific,
non-notarized development/direct build.

## Use the research workflow

The app opens into one native workbench:

- **Left:** local research projects, New Conversation, local search, dated/archived sessions, and
  runtime/Providers/History/Settings routes.
- **Center:** chronological user and OpenScience items, inline plan/network/run/result/error cards,
  and a pinned multiline composer. Advanced research fields remain in **Research Settings** beside
  the composer rather than replacing the conversation.
- **Right:** collapsible Context, Plan, Evidence, and Artifacts tabs. Retrieved material is inert;
  exact citation selection uses run, claim, evidence, and source IDs.

Conversation metadata is stored below Application Support as a safe workspace index plus one
owner-only envelope per conversation. Only user-authored text, safe drafts/layout, and typed
run/artifact identifiers persist. Credentials, approvals, network grants, active-process claims,
stdout/stderr, evidence passages, and report bodies do not enter conversation storage. Engine run
artifacts remain authoritative and are revalidated before consequential actions.

| Task | Desktop behavior | Engine authority |
|---|---|---|
| Create research | Start a conversation, compose a question, and optionally edit Research Settings | `plan --json` creates the finite reviewed plan |
| Approve a plan | Review steps, provider risks, local roots, and limits; approve explicitly | `run --plan … --yes --json` executes only after approval |
| Allow network access | Confirm named network providers and the per-attempt request bound | `--allow-network` is omitted unless the one-time grant is consumed |
| Follow progress | View one bound inline run card with steps, counts, and trusted activity | Complete records from the exact run's `events.jsonl` are the only timeline progress source |
| Inspect history | Filter local runs and inspect claims, evidence, sources, and provenance | Recorded artifacts are validated before mutation or verified presentation |
| Cancel | Request cancellation for the exact run discovered for the active attempt | `cancel <run-directory> --json` writes the durable request |
| Resume | Revalidate, review completed/remaining steps, and restore permissions | `resume … --yes --json` continues the same recorded run |
| Export | Validate, choose a ZIP destination, and confirm replacement | `export … --json` creates and self-validates the portable RO-Crate bundle |

The app allows one mutating run at a time. Read-only history, provider discovery, and validation may
remain available while that run is active. Completed, partial, failed, and cancelled outcomes are
not converted into one generic success state.

By default, run records are stored below:

```text
~/Documents/OpenScience/Runs
```

The location can be changed in development settings. A run contains machine-readable request,
plan, execution, event, evidence, claim, source, policy, provenance, and checksum information.

## Understand the security boundaries

### Credentials and Keychain

OpenAlex, Crossref, and model credentials are stored as separate generic-password items in the
macOS Keychain service `org.openscience.desktop`. The UI reports only whether each credential is
present; add/replace fields are not prefilled with a saved value.

Only credentials required by the selected providers are read and injected into the child process:

| Provider | Child environment variable |
|---|---|
| OpenAlex | `OPENSCIENCE_OPENALEX_API_KEY` |
| Crossref | `OPENSCIENCE_CROSSREF_API_KEY` |
| OpenAI-compatible synthesis | `OPENSCIENCE_MODEL_API_KEY` |

Credential values are not command-line arguments, preferences, model configuration, run records,
diagnostics, or export entries. Provider discovery, validation, inspection, cancellation, replay,
and export receive no credential environment. The desktop and engine both redact diagnostics, but
redaction is not a substitute for avoiding unnecessary secret access.

### Network permission

Network access starts denied. A network-capable new run or resume requires a blocking confirmation
for that attempt. The confirmation identifies providers, declared risk, data category, destination
category, timeout, and maximum request count. There is no remembered or “always allow” grant.

Declining confirmation omits `--allow-network`; the engine's policy layer then prevents provider
network calls. Keychain presence does not itself authorize network access.

### Local documents and research records

Local directories are selected with the native directory chooser and apply only to the current run
or resume approval. The engine receives the exact selected roots and enforces its local-path policy.
Exports remove host-only absolute local roots and credentials.

This first release is unsandboxed. macOS therefore does not provide App Sandbox containment for
those paths, and the app does not persist security-scoped bookmarks. Install only trusted engine
and provider code and review local-root selections before approval.

Recorded Markdown and provider text are untrusted data. They do not become commands. External
source opening is a separate action restricted to HTTP or HTTPS destinations.

## Troubleshoot the client

| Symptom | Likely cause | Recovery |
|---|---|---|
| Composer Send is disabled | Engine path is absent/unsafe/incompatible, another mutation owns the runtime, or privacy validation blocks the draft | Open Settings/runtime status, verify the helper, or return to the active conversation; confirm `openscience --version` prints one `0.1.x` line |
| Provider list is empty | Engine probe or local provider discovery failed | Run `uv run openscience providers --json`, then use **Refresh Providers** |
| A network provider is denied | The per-attempt grant was declined, expired, or not requested | Return to plan/resume review and explicitly allow only the current attempt |
| A local source is unavailable on resume | Roots are not persisted as durable authorization | Reselect the exact directory before approving resume |
| Keychain save/read fails | Keychain is locked or access was denied | Unlock Keychain, retry the one credential action, and do not move the value into a file or preference |
| A run opens read-only | Fresh validation failed or recorded files changed | Review the validation issues; do not resume or export it as valid |
| Swift verification says `SKIP` | Command Line Tools lacks a discoverable XCTest runtime | Install/select full Xcode and rerun; CI must never report zero tests as pass |
| Helper assembly fails | Python 3.11, the desktop dependency group, or PyInstaller is unavailable | Run `uv sync --frozen --all-groups`, then rerun `scripts/build-macos-helper.sh` |
| macOS warns about distribution trust | The app has only a local ad hoc seal and is not notarized | Use it as a local development build; complete Developer ID signing and notarization before external distribution |

For the precise process, event, credential, and reconciliation rules, see the
[desktop CLI bridge contract](../specs/002-macos-desktop-client/contracts/cli-bridge.md). For the
visible permission and accessibility behavior, see the
[conversation workbench UI contract](../specs/003-conversation-workbench/contracts/ui-contract.md).
