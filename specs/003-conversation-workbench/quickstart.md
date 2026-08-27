# Quickstart: Validate the Conversation Research Workbench

This guide is executable after [tasks.md](tasks.md) is complete. It validates the selected option 3
interaction, research/security invariants, persistence, accessibility, performance, and packaging.
It does not authorize live provider calls; live tests remain explicit opt-in.

Current status: implementation is in progress. A buildable three-pane development candidate exists,
but the complete feature-003 contract and its release evidence are not yet complete.

## 1. Prerequisites

- macOS 14 or newer on a supported test Mac
- Xcode command-line tools with Swift 5.10+
- Python 3.11+ and `uv`
- Repository root: `/Users/bytedance/Desktop/OpenScience` (substitute the actual clone path)
- Binding visual target:
  `design/conversation-workbench/selected-option-3.png` (1487 × 1058)

Do not add provider keys for deterministic validation. If the app has existing Keychain values,
the fixture paths below must still prove no provider call occurs before approval.

## 2. Verify Spec Kit Artifacts

```bash
cd /Users/bytedance/Desktop/OpenScience
.specify/scripts/bash/check-prerequisites.sh --json --require-tasks --include-tasks
```

Expected:

- `FEATURE_DIR` resolves to `specs/003-conversation-workbench`.
- `spec.md`, `plan.md`, and `tasks.md` exist.
- No unresolved `[NEEDS CLARIFICATION]`, placeholder, or unchecked requirements-quality item exists.

## 3. Run Deterministic Code Gates

```bash
cd /Users/bytedance/Desktop/OpenScience
uv run ruff format --check .
uv run ruff check .
uv run mypy src
uv run pytest -m "not live"
```

Expected: all existing Python gates pass; live OpenAlex/Crossref/model tests are deselected.

```bash
cd /Users/bytedance/Desktop/OpenScience/macos/OpenScienceDesktop
swift test
swift build -c release
```

Expected: existing feature-002 and new conversation model/store/projector/coordinator/flow tests all
pass. Test output includes zero real network request and secret-canary assertions.

If the repository formatter is available, run it in lint mode without modifying files:

```bash
cd /Users/bytedance/Desktop/OpenScience/macos/OpenScienceDesktop
swift format lint --recursive Sources Tests Package.swift
```

## 4. Build the Self-Contained Development App

```bash
cd /Users/bytedance/Desktop/OpenScience
macos/OpenScienceDesktop/scripts/build-app.sh
open macos/OpenScienceDesktop/dist/OpenScience.app
```

Expected:

- The app opens the conversation workbench, not the legacy New Research form.
- Bundled helper resolution remains authoritative.
- The build makes no Developer ID, notarization, sandbox, or production-distribution claim.

## 5. Run the Offline Conversation Vertical Slice

Use a clean temporary application-support test root through the test harness, never by deleting a
real user root. Launch the deterministic fixture configured by
`macos/OpenScienceDesktop/Tests/OpenScienceDesktopTests/Fixtures/workbench-option-3.json`.

Acceptance journey:

1. Observe a left project/conversation sidebar, center timeline/composer, and right preview.
2. Create/switch between two local projects and confirm each project scopes its conversation list
   without changing any referenced run.
3. Press Command-N and enter an offline question using `examples/corpus.json` or
   `tests/fixtures/local_corpus` through the native chooser.
4. Press Command-Return. Confirm the user message appears exactly once and an inline plan card
   appears before any provider/model call.
5. Expand the five-step plan, inspect risks/limits, and approve it.
6. Observe one inline run card update from the exact event file; run stdout remains terminal-only.
7. Wait for reconciliation and confirm completed/partial is truthful.
8. Activate one citation. Evidence tab must show the exact passage/source/locator/attribution.
9. Open the report/PDF from the Artifacts tab; retrieved content remains inert.
10. Ask a follow-up. A new research turn is appended and the earlier run remains unchanged.

Evidence to retain in the release record:

- conversation/turn/plan/run IDs and run directory;
- event count and terminal reconciliation outcome;
- exact claim/evidence/source IDs selected;
- validation/replay/export output paths and hashes;
- assertion that no account/network/key was required.

## 6. Prove Network Approval Is Inline and Ephemeral

Use the deterministic fake network provider/counter, not a live provider:

1. Submit a plan with one `network_read` source.
2. Confirm the inline card lists provider, destination category, outbound categories, limits, and
   risk.
3. Reject it; assert the request counter is exactly zero and no `--allow-network` argument exists.
4. Reopen/approve the same plan and allow once; assert only the exact attempt receives the grant.
5. Change a plan-affecting limit; assert the prior plan/grant expires.
6. Relaunch; assert the conversation returns but approval/grant/process claim does not.

Run the named contract tests:

```bash
cd /Users/bytedance/Desktop/OpenScience/macos/OpenScienceDesktop
swift test --filter WorkbenchCoordinatorTests
swift test --filter ConversationWorkbenchFlowTests
```

## 7. Prove Durable Session Recovery and Isolation

Run the store suite:

```bash
cd /Users/bytedance/Desktop/OpenScience/macos/OpenScienceDesktop
swift test --filter ConversationStoreTests
```

Expected fixtures cover strict schema/UTF-8/size/ID validation, revision conflicts, duplicate send,
root escape/symlink/replacement, interrupted write at every step, corrupt/newer-envelope isolation,
index rebuild, archive/restore/delete, and forbidden canaries.

Manual seeded acceptance:

1. Create conversations across Today/Yesterday/Earlier, archive one, and leave drafts in two.
2. Relaunch and verify selection/grouping/drafts; no grant/approval/active process is restored.
3. Restore the archived conversation.
4. Delete one conversation after confirmation and verify its referenced run directory still exists
   byte-for-byte.
5. Introduce one corrupt envelope only in the isolated test root; other conversations remain usable
   and the corrupt one has a safe diagnostic.

## 8. Prove Existing Research Controls Did Not Regress

Through inline cards/right preview, execute deterministic flows for:

- cancel twice before/after run discovery;
- relaunch and resume after new root/credential/network review, without repeating a completed step;
- validate and inspect;
- replay offline;
- export to a new ZIP and validate bundle checksums/RO-Crate;
- existing-target export cancellation;
- provider discovery with zero network;
- Keychain presence/add/remove using independent test canaries;
- integrity-invalid run with no resume/valid export action.

Run both bridge-level suites:

```bash
cd /Users/bytedance/Desktop/OpenScience/macos/OpenScienceDesktop
swift test --filter CLIBridgeIntegrationTests
swift test --filter FixtureResumeIntegrationTests
```

Expected: every feature-002 safety invariant remains green.

## 9. Capture and Compare the Selected Visual Target

The visual harness must use the seeded option 3 fixture, dark appearance, 1487 × 1058 content area,
and fixed locale/time. It must not use live scientific data.

```bash
cd /Users/bytedance/Desktop/OpenScience
OPENSCIENCE_STRICT_CAPTURE_SIZE=1 \
  macos/OpenScienceDesktop/scripts/capture-workbench-reference.sh \
  "$PWD/macos/OpenScienceDesktop/.build/workbench-option-3-actual.png"

macos/OpenScienceDesktop/scripts/compare-workbench-reference.sh \
  "$PWD/design/conversation-workbench/selected-option-3.png" \
  "$PWD/macos/OpenScienceDesktop/.build/workbench-option-3-actual.png" \
  "$PWD/macos/OpenScienceDesktop/.build/workbench-option-3-comparison.png"

# Display-independent geometry/debug render (not a substitute for real-window chrome acceptance):
macos/OpenScienceDesktop/scripts/render-workbench-offscreen.sh \
  "$PWD/macos/OpenScienceDesktop/.build/workbench-option-3-offscreen.png"
```

Both scripts use positional path arguments. The capture script launches the app's built-in
`--design-preview` seed; it does not accept a fixture flag. Strict size mode is required for
SC-002 so a display-constrained capture cannot be mistaken for reference-size evidence.

Expected:

- left 246–278 px, right 460–508 px, center remaining and ≥520 px;
- composer and all panes visible without overlap;
- separators/card/tab hierarchy and 8–16 point rhythm pass structural checks;
- masked perceptual similarity ≥0.90, with masks limited to dynamic timestamp glyph bounds and a
  one-pixel text antialiasing fringe (never pane/card/tab/composer/content geometry);
- no asset/mock other than selected option 3 is accepted as an alternate target.

Store the actual capture as a CI artifact, not as a replacement for the approved design file.

Current-host note (2026-08-27): the available display constrains the logical app window to
1487 × 865. With `OPENSCIENCE_STRICT_CAPTURE_SIZE=1`, capture therefore exits non-zero as intended.
That host cannot supply SC-002 evidence; a Mac/display capable of the full 1487 × 1058 content area
is still required. The offscreen renderer does produce an exact 1487 × 1058 native SwiftUI theme
frame for geometry and focused content QA, but inactive toolbar materials render differently and
therefore cannot replace the real-window SC-002 capture.

## 10. Accessibility and Adaptive Layout

Run automated semantics first:

```bash
cd /Users/bytedance/Desktop/OpenScience/macos/OpenScienceDesktop
swift test --filter ConversationWorkbenchAccessibilityTests
swift test --filter ConversationWorkbenchVisualTests
```

Then inspect the built app with keyboard and Accessibility Inspector:

1. At 1487 × 1058, traverse sidebar → timeline/cards → composer → preview tabs/actions.
2. At 1180 × 720, verify preview collapses first and explicit controls restore preview/sidebar.
3. Repeat with increased contrast, reduced motion, larger text, and VoiceOver.
4. Complete New Conversation → plan → network reject/allow fixture → run → evidence → export.
5. Confirm no pointer-only control, color-only state, focus trap, clipped primary action, or
   approval triggered by Escape.

Record macOS/build version, display scale, pass/fail, and any exception. A screenshot alone is not
evidence of accessibility completion.

## 11. Performance Acceptance

Use deterministic generated data only:

```bash
cd /Users/bytedance/Desktop/OpenScience/macos/OpenScienceDesktop
swift test --filter ConversationWorkbenchPerformanceTests
```

Expected on an Apple M1-or-newer test Mac with at least 8 GiB RAM, macOS 14+, and no reported
thermal pressure, after five warm-ups and at least 30 measured operations per class:

- 200 conversations, 1,000 selected timeline items, 1,000 evidence records;
- local search, conversation switch, and preview selection p95 ≤500 ms;
- exact citation activation ≤2 seconds and zero mismatches;
- no main-thread timeline scroll stall over 100 ms;
- no evidence/timeline record silently dropped or truncated into a verified state.

## 12. Secret, Persistence, and No-Copy Audit

The deterministic tests inject unique credential, environment, network-grant, evidence-passage,
report, and absolute-path canaries. Scan candidate text artifacts and all test conversation files.

Expected:

- credentials/environment/grants/approvals/raw diagnostics absent everywhere forbidden;
- evidence/report canaries absent from conversation/index/layout files but present in authoritative
  fixture run artifacts as expected;
- no external product logo, name, UI string corpus, extracted screenshot asset, or source fragment
  added; OpenScience/Apple-native assets only.

Do not print discovered secret-like values. Report only file/category/count and remediate before
release.

## 13. Final Completion Record

Fill this table only with fresh evidence from the release candidate:

### Current development-candidate evidence (2026-08-27)

- The native three-column shell, conversation timeline/composer, and four-tab inspector are present
  as a development candidate; this is not evidence that every feature-003 contract is implemented.
- `ruff format --check`, `ruff check`, and strict `mypy` are green. The deterministic Python run
  reported **140 passed, 3 deselected**.
- Strict Swift debug and release builds are green. The local Command Line Tools environment could
  only compile/link the test targets; GitHub full-Xcode macOS CI run `33066601956` then executed
  **83 tests with 0 failures**.
- P0 review fixes were applied for cross-conversation state isolation and exact citation routing.
  These fixes remove identified candidate defects; they do not substitute for the unexecuted full
  contract and journey suites.
- The full `ResearchTurn`/attempt model and mapping contract, deterministic interrupted-write/
  transaction recovery, SC-002 reference capture/similarity, VoiceOver/manual accessibility,
  performance, and five-participant moderated usability evidence remain pending.

| Gate | Required result | Evidence |
|------|-----------------|----------|
| Spec Kit prerequisite/analysis | 100% buildable FR/SC coverage, 0 CRITICAL/HIGH | Pending implementation audit |
| Python deterministic suite | Pass, live excluded | 2026-08-27: PASS — Ruff format/check and strict mypy green; 140 passed, 3 deselected |
| Swift full suite | Pass | 2026-08-27: PASS — GitHub full-Xcode macOS CI executed 83 tests with 0 failures; release and app assembly passed |
| Offline conversation journey | Pass | Pending full `ResearchTurn`/attempt contract and journey execution; three-pane candidate only |
| Network decline/ephemeral grant | 0 requests on decline; no restored authority | Pending |
| Session crash/corrupt recovery | 100% fixtures preserve/isolate correctly | PARTIAL — corrupt/missing/newer workspace/envelope, migration, revision conflict, and metadata-delete tests passed in full-Xcode CI; every write-step transaction injection remains pending |
| Feature-002 cancel/resume/validate/replay/export/providers | Pass | 2026-08-27: real offline plan/run/validate/inspect/replay/export and helper/provider probes passed; cancel/resume UI regression remains pending full-Xcode/manual acceptance |
| Option 3 geometry/perceptual fidelity | All geometry; similarity ≥0.90 | BLOCKED — exact 1487 × 1058 native offscreen comparison exists, but unmasked SSIM is 0.579766 and the validated PDF preview remains pending |
| Keyboard/VoiceOver/minimum-size/appearances | Pass | Pending VoiceOver and manual adaptive/appearance acceptance |
| 200/1,000/1,000 performance | p95 targets met | Pending benchmark and exact 1,000-citation run |
| Secret/no-copy scan | 0 findings | 2026-08-27: PASS for CI secret-pattern scan and verification canaries; formal clean-room provenance test remains an unchecked feature task |
| `.app` package smoke | Pass, truthful development boundary | 2026-08-27: PASS — self-contained helper, metadata, JSON probe, and deep strict ad hoc signature verified |

This feature is complete only when every row has authoritative fresh evidence and every applicable
task is checked. A build or screenshot by itself is insufficient.
