# Quickstart Validation: Native macOS Desktop Client

This guide validates the feature from a clean development checkout. It deliberately separates a
buildable/launchable unsandboxed `.app` from the optional self-contained helper assembly. Passing
these scenarios does **not** imply Developer ID distribution signing, notarization, App Store
sandboxing, security-scoped bookmark support, automatic updates, or Gatekeeper-ready distribution.

## Prerequisites

- macOS 14 or newer
- Xcode command-line tools with Swift 5.10 or newer selected with `xcode-select`
- Python 3.11+ and `uv` for engine development/tests
- No network connection or API key for the primary validation scenario

Confirm tools:

```bash
swift --version
python3 --version
uv --version
```

## Prepare the Existing Engine

```bash
uv sync --frozen --all-groups
uv run openscience --version
uv run openscience providers --json
```

Expected:

1. `.venv/bin/openscience` exists and reports a compatible version.
2. Provider discovery emits one JSON object and does not contact a provider.
3. Existing deterministic Python tests remain available.

## Run Contract Tests First

```bash
uv run pytest \
  tests/contract/test_cli.py \
  tests/integration/test_security.py

(cd macos/OpenScienceDesktop && swift test)
```

Expected: CLI terminal JSON/environment-secret tests plus Swift core/app-state tests pass without a
live network provider.

## Build a Launchable Development App

```bash
OUTPUT_DIR="$PWD/.build/macos-app" CONFIGURATION=debug \
  macos/OpenScienceDesktop/scripts/build-app.sh

open .build/macos-app/OpenScience.app
```

In Settings, choose the absolute development engine executable:

```text
<repository>/.venv/bin/openscience
```

Expected: the app launches as an unsandboxed development build, probes the external CLI, displays
its path/version, and enables New Research. A local ad-hoc seal may be present, but no bundled-helper,
Developer ID signing, notarization, Gatekeeper, or sandbox claim is shown.

## Optional Self-Contained Helper Assembly

Build the fixed-version helper and assemble a separate app copy:

```bash
OPENSCIENCE_HELPER_OUTPUT="$PWD/.build/engine-helper" \
  scripts/build-macos-helper.sh

OUTPUT_DIR="$PWD/.build/direct" CONFIGURATION=release \
OPENSCIENCE_HELPER_PATH="$PWD/.build/engine-helper/openscience" \
  macos/OpenScienceDesktop/scripts/build-app.sh

.build/direct/OpenScience.app/Contents/Helpers/openscience --version
open .build/direct/OpenScience.app
```

Expected:

1. The output app contains executable `Contents/Helpers/openscience` at the pinned compatible
   version.
2. The app resolves that helper before any configured development override.
3. The app can complete the offline scenario without a user-managed Python path.
4. Assembly emits no claim that the artifact is Developer ID-signed, notarized, sandboxed, or ready
   for App Store/Gatekeeper distribution; any local ad-hoc seal is identified as such.

## Scenario 1: Offline New Research to Evidence

1. Open **New Research**.
2. Enter: `What practices make computational studies easier to reproduce?`
3. Choose **Add Directory** and select `tests/fixtures/local_corpus`.
4. Select the local-files source and extractive synthesis, retain bounded default limits, and choose
   **Generate Plan**.
5. Review the five ordered steps and local-read/write risks. Confirm that no network dialog appears.
6. Choose **Approve & Run**.

Expected while running:

- The client creates one unique `Runs/Tasks/task-*/` workspace.
- Exactly one contained `run-*` directory appears and becomes the visible run/cancel target.
- stdout remains a terminal-only channel while step progress appears from complete
  `run-*/events.jsonl` records.
- The UI never blocks during process/file reads.

Expected at completion:

- Terminal JSON, exit code, terminal event, manifest, and fresh validation agree on `completed`.
- History contains the question, providers, counts, and validation state after relaunch.
- Each sourced claim opens its exact passage, locator, source, retrieval metadata, and license/status.
- No source or model network call occurred.

## Scenario 2: Cancellation and Resume

Run the deterministic cancellation/resume app-state integration test:

```bash
(cd macos/OpenScienceDesktop && swift test --filter CancelResumeFlowTests)
```

Expected:

1. Pre-discovery cancellation does not fabricate a run record.
2. Post-discovery cancellation invokes `openscience cancel` with the one exact run directory.
3. Repeating cancel returns the same request time and one consistent terminal state.
4. Resume shows completed/remaining steps, requires approval/root selection again, and does not
   repeat a completed step.

## Scenario 3: Network Authorization and Keychain Secrets

Run the deterministic fake-transport permission suite:

```bash
(cd macos/OpenScienceDesktop && swift test --filter NetworkGrantTests)
(cd macos/OpenScienceDesktop && swift test --filter CredentialEnvironmentTests)

uv run pytest tests/integration/test_security.py -k 'environment or secret'
```

Expected:

- Declining the per-run confirmation omits `--allow-network` and yields zero request.
- Resume asks again even after a previous grant.
- OpenAlex, Crossref, and model canaries enter only
  `OPENSCIENCE_OPENALEX_API_KEY`, `OPENSCIENCE_CROSSREF_API_KEY`, and
  `OPENSCIENCE_MODEL_API_KEY` in the selected child environment.
- No canary appears in argv, model config, preferences, logs, stdout/stderr, event/run records,
  support output, or export.

Live provider smoke tests remain separately opt-in and must never be part of the deterministic gate.

## Scenario 4: Validate, Inspect, and Export

1. Open the completed offline run in **Runs**.
2. Review Summary, Report, Evidence, Provenance, and Limitations.
3. Choose **Export**, select an unused ZIP destination, and complete export.
4. Repeat with the same destination and decline replacement.

Expected:

- Fresh validation occurs before export.
- Success reports exact resolved destination and positive size.
- The exported ZIP validates through the existing engine validator and contains report, claims,
  evidence, sources, provenance/checksums, and RO-Crate metadata.
- Credentials and absolute approved local roots are absent.
- Declining replacement leaves the original file byte-identical.

## Scenario 5: Corruption and Recovery Matrix

```bash
(cd macos/OpenScienceDesktop && swift test --filter EventLogCursorTests)
(cd macos/OpenScienceDesktop && swift test --filter TerminalReconciliationTests)
(cd macos/OpenScienceDesktop && swift test --filter IntegrityFailureFlowTests)
```

Expected explicit non-success states for partial final event line at terminal, malformed/gapped
events, multiple run candidates, symlink escape, oversized output, engine crash, disk full, and
terminal JSON/manifest/event disagreement. None is auto-repaired or displayed as completed.

## Scenario 6: Native Accessibility

```bash
(cd macos/OpenScienceDesktop && swift test --filter AccessibilityContractTests)
```

Also inspect the primary flow with Accessibility Inspector under light/dark appearance, increased
contrast, and reduced motion.

Expected: New Research, plan approval, progress, cancellation, report/evidence navigation, provider
credentials, and export are keyboard reachable with meaningful names/values and no critical issue.

## Complete Quality Gates

```bash
uv run ruff format --check .
uv run ruff check .
uv run mypy src
uv run pytest --cov=openscience_agent --cov-report=term-missing

(cd macos/OpenScienceDesktop && swift test)

OUTPUT_DIR="$PWD/.build/quality-app" CONFIGURATION=release \
  macos/OpenScienceDesktop/scripts/build-app.sh
test -x .build/quality-app/OpenScience.app/Contents/MacOS/OpenScienceDesktop
plutil -lint .build/quality-app/OpenScience.app/Contents/Info.plist
```

All deterministic gates must pass. The assembly checks prove app structure and launchability; they
must not report deferred Developer ID signing/notarization/sandbox gates as passed.

## Release Evidence to Record

- macOS, Swift, and Xcode command-line-tools versions, architecture, app/engine versions, build
  command, and artifact hashes
- Python and Swift test totals, failures/skips, and explicit live-test exclusion
- Offline run ID, source/evidence/claim counts, validation result, and event sequence count
- Cancellation/resume completed-step comparison
- Export checksum/RO-Crate validation and credential/path canary scan
- 100-run and 1,000-evidence timing results
- Keyboard/accessibility findings
- App bundle launch result for external-engine and optional bundled-helper variants
- Explicit statement that sandboxing, security-scoped bookmarks, Developer ID signing, notarization,
  automatic update, App Store distribution, and Gatekeeper readiness were not validated or delivered

## Recorded development-preview evidence (2026-08-21)

- Host: macOS 26.4.1, Apple silicon arm64; Swift 6.2.4; Python 3.11.15.
- Python gates: Ruff format/check and strict mypy passed; 140 deterministic tests passed and 3
  explicit live tests were deselected.
- Swift gates: strict formatting and a clean release/test-target compilation passed locally.
  GitHub full-Xcode macOS 15 CI executed 59 XCTest cases with zero failures, including the real CLI
  bridge and fixture resume integration tests.
- App bundle: 13 MB arm64, minimum macOS 14, valid `Info.plist`, locally ad-hoc signed. App executable
  SHA-256: `61648b476697e7561b21499b05b3360af43d607ceb4353248cca6efc4561ef25`.
- Bundled helper SHA-256:
  `92dd2a2280b0b69b5a71f1c2c73f6b762bebd1302d9a523e89916800b7663ff7`.
- Offline fixture run `run-20260821T051942Z-0f7b6f6e` completed with 3 sources, 3 evidence records,
  3 claims, and 26 hash-chained events. Validation and offline replay both returned `completed`.
- The exported 19,633-byte ZIP validated independently; SHA-256:
  `78521e4258f61ef0d130b1c6b4cdd11ecaa223e43dd353ab8c7592f34694935f`.
- Secret-canary scan reported zero matches in native run artifacts and the exported ZIP.
- Not executed: Computer Use visual inspection, Accessibility Inspector/screen-reader acceptance,
  10-person first-use study, performance acceptance, Developer ID signing, notarization, sandbox,
  App Store distribution, and Gatekeeper-readiness validation.
