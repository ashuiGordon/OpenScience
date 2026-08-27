# CLI Bridge Contract: Native macOS Desktop Client

**Contract ID**: `openscience-desktop-cli/1`

This contract is additive to [the existing command-line contract](../../001-general-research-agent/contracts/cli.md).
The Python CLI and validated run artifacts remain authoritative. The desktop app MUST NOT invoke a
shell, scrape human output, import Python, or expose a local network service.

## Compatibility and Executable Resolution

The app probes an executable with:

```text
<executable> --version
```

Expected output is exactly one bounded UTF-8 line:

```text
openscience <semantic-version>
```

The app ships an expected contract major and compatible engine version interval. An unknown major,
unparseable line, missing execute permission, or version outside that interval disables mutating
commands and produces a typed compatibility error. Read-only access to already decoded local
history may remain available, clearly marked as not freshly validated.

Resolution order:

1. `<App>.app/Contents/Helpers/openscience`, when present. A packaged helper is a fixed build input
   and MUST take precedence over development overrides.
2. An explicit absolute development CLI URL, only in a build configuration that exposes that
   setting.
3. No implicit PATH or shell lookup. Absence is `engine.unavailable`.

The project MUST be able to build and launch an unsandboxed `.app` without the optional helper for
development. In that variant, execution remains disabled until a compatible external CLI is
configured. The assembly script MUST also support placing a self-contained fixed-version helper at
`Contents/Helpers/openscience`. Neither variant implies Developer ID distribution signing,
notarization, App Store sandboxing, or Gatekeeper readiness; a local ad-hoc seal does not change
that boundary.

## Process Contract

For every command:

- Launch the resolved absolute executable directly with an argument array.
- Use a fresh, attempt-specific working directory under Application Support.
- Start from a minimal inherited environment required for locale/runtime behavior; add only selected
  credential variables described below.
- Do not serialize or log the full environment.
- Capture stdout and stderr asynchronously off the main thread to prevent pipe deadlock.
- Bound stdout to 1 MiB and retained/redacted stderr to 256 KiB per process. Exceeding a bound is a
  typed failure and stops further capture.
- Decode UTF-8 strictly. Invalid output is a bridge failure, never replacement text accepted as
  valid JSON.
- Apply the engine/run timeout plus a 10-second launch/reconciliation allowance. Provider calls
  remain subject to engine limits.
- On normal app termination, request engine cancellation after a run target exists and allow a
  bounded graceful interval; do not claim cancellation from process termination alone.

No secret value may appear in argv, current directory, plan/config path, persisted invocation,
stdout, retained stderr, event presentation, app log, run artifact, or export.

## JSON Result Contract

Every command invoked with `--json`, including `run` and `resume`, emits exactly one JSON object to
stdout followed by optional trailing whitespace and EOF.

Specifically, `run --json` is a **terminal result channel only**:

- it emits no progress object;
- the app waits for EOF before decoding it;
- multiple objects or non-whitespace before/after the object are `stdout.multiple_objects`;
- a process can produce progress while stdout remains empty;
- the app obtains progress exclusively from the attempt's unique recorded event file.

JSON errors retain the current form:

```json
{
  "error": {
    "code": "validation.invalid",
    "message": "redacted safe message",
    "type": "ValidationError"
  }
}
```

Unknown object fields are ignored for compatible minor versions. Required fields, types, exit-code
consistency, maximum sizes, and safe path containment are validated.

## Unique Workspace and Run Discovery

For every new research task, the app creates an empty unique directory:

```text
<Application Support>/OpenScience/Runs/Tasks/task-<uuid>/
```

The absolute directory is passed to `run` as `--workspace`. The app watches only that directory and
accepts exactly one immediate child matching `run-*` that is a real directory contained by the task
workspace. It never selects “newest” or follows a symlink outside the root.

Discovery rules:

1. Zero candidates while the process is starting means `Preparing run workspace`, not an error.
2. One contained candidate publishes the immutable `run_directory` and enables persisted cancel.
3. More than one candidate fails closed with `workspace.multiple_runs`.
4. Process exit without a candidate is `workspace.no_run` unless the command returned a documented
   pre-run policy/usage error.
5. A candidate created after the startup deadline is not silently adopted.

After discovery, the sole progress input is:

```text
<task-workspace>/run-*/events.jsonl
```

For `resume`, the run directory is already known and freshly validated. The app still creates a
unique working directory for process-local desktop files, but it tails the exact existing
`<run-directory>/events.jsonl`; `resume` receives no synthetic/new workspace argument.

History scanning accepts only the managed shape `Runs/Tasks/task-*/run-*` and exact existing resumed
run directories. Cache/index entries do not expand this authority.

## Event Progress Contract

Each line follows the engine `RunEvent` contract:

```json
{
  "sequence": 5,
  "event_id": "event-...",
  "run_id": "run-...",
  "type": "step.started",
  "timestamp": "2026-08-21T08:00:00Z",
  "step_id": "extract",
  "payload": {"capability": "evidence.extract"},
  "previous_hash": "...",
  "event_hash": "..."
}
```

Desktop decoding requirements:

- Read only newline-terminated records up to 1 MiB per line.
- Retain a bounded incomplete final line while the writer is active; do not decode it or advance the
  cursor.
- Require nonnegative integer sequence, non-empty run/event/type IDs, matching discovered `run_id`,
  RFC 3339 timestamp, object payload, and string hash fields.
- Accept only the next expected sequence. An exact already-seen sequence/hash is a no-op; a
  conflicting duplicate or gap stops trusted progress and surfaces an issue.
- Unknown `type` values may display as generic activity but cannot grant permission, execute an
  action, or establish terminal success.
- Event-file identity/size regression or replacement invalidates the cursor and requires whole-run
  validation rather than automatic rewind.
- File notifications may coalesce. The reader drains all complete new lines on notification,
  process transition, wake, and a bounded fallback poll.

Known presentation mappings include:

| Event type | Desktop effect |
|------------|----------------|
| `run.created` | Publish created state and bind request/plan identity |
| `run.resumed` | Mark a new resume attempt without erasing history |
| `run.awaiting_approval` | Show awaiting approval; desktop normally plans/approves first |
| `run.started` | Show running |
| `step.started` | Mark exact step running |
| `step.completed` | Mark exact step completed and update available counts |
| `step.failed` | Mark exact step failed; show safe payload context |
| `step.cancelled` | Mark exact step cancelled but await run terminal event |
| `run.finalizing` | Show validation/finalization, not completed |
| `run.completed` | Candidate terminal completed pending process/artifact reconciliation |
| `run.partial` | Candidate terminal partial pending reconciliation |
| `run.failed` | Candidate terminal failed pending reconciliation |
| `run.cancelled` | Candidate terminal cancelled pending reconciliation |
| `run.interrupted` | Show interrupted/resumable candidate pending validation |

The event reader is for responsive presentation. It does not replace the engine's event hash-chain
or whole-run validator.

## Credential Environment Contract

Keychain values are injected only for providers selected by the current plan/attempt:

| Keychain credential | Environment variable | CLI consumer |
|---------------------|----------------------|--------------|
| OpenAlex API key | `OPENSCIENCE_OPENALEX_API_KEY` | OpenAlex source composition |
| Crossref API key | `OPENSCIENCE_CROSSREF_API_KEY` | Crossref source composition |
| Model API key | `OPENSCIENCE_MODEL_API_KEY` | OpenAI-compatible synthesis composition |

CLI composition rules:

1. When the corresponding legacy command-line key option is absent, OpenAlex and Crossref adapters
   read the exact environment names above. Model synthesis uses
   `OPENSCIENCE_MODEL_API_KEY` through the non-secret model configuration.
2. The desktop client MUST NOT use `--openalex-api-key` or `--crossref-api-key` and MUST NOT put a
   model key into `--model-config`.
3. The desktop may inspect a model config containing endpoint, model, timeout, and the fixed
   non-secret `api_key_env` name, but execution MUST pass the reviewed values with
   `--model-endpoint`, `--model-name`, and `--model-timeout`; it MUST NOT reopen the external file.
4. Missing required environment values produce a typed JSON usage/configuration error without
   echoing names plus values or any secret fragment.
5. The CLI's existing persistence redactor and the desktop redactor both include selected secret
   values before any diagnostic/artifact write.
6. A child receives no credential for an unselected provider. Provider discovery, validation,
   inspect, cancel, replay, and export receive no credential environment entries.

Environment variables are transient process input, not durable authorization. `--allow-network`
remains separately required after a current `NetworkGrant`.

## Command Matrix

### Version probe

```text
openscience --version
```

No network, credential, or run mutation. Uses the bounded one-line contract above.

### Provider discovery

```text
openscience providers --json
```

Optional fixture/local arguments are allowed only in deterministic tests/draft previews. Never pass
`--allow-network` or secrets. Required success payload:

```json
{
  "providers": [
    {
      "name": "openalex",
      "version": "1.0.0",
      "kind": "source",
      "risk": "network_read",
      "available": true,
      "health_error": null
    }
  ]
}
```

### Plan generation

```text
openscience plan <QUESTION> \
  [--scope <TEXT>] [--constraint <TEXT>]... [--assumption <TEXT>]... \
  --max-records <N> --max-network-requests <N> --timeout <SECONDS> \
  --output <attempt-dir>/plan.json --json
```

No provider, network grant, or secret. Success object requires `request`, `plan`, and absolute
`output`. The plan file must be a regular contained file with restrictive permissions and must match
the returned plan identity/content.

### New run

```text
openscience run <QUESTION> \
  --plan <attempt-dir>/plan.json \
  --workspace <unique-task-workspace> \
  --source <NAME>... [--local-root <PATH>]... \
  [--fixture <PATH>]... [--email <ADDRESS>] \
  [--synthesizer <NAME>] [--model-endpoint <URL> --model-name <NAME> \
  --model-timeout <SECONDS>] \
  [--allow-network] --max-records <N> --max-network-requests <N> \
  --timeout <SECONDS> --yes --json
```

`--allow-network` appears only with the attempt grant. Secrets appear only in selected environment
keys. Required terminal success/partial payload:

```json
{
  "run_id": "run-...",
  "run_directory": "/absolute/managed/task-.../run-...",
  "status": "completed",
  "report": "/absolute/managed/task-.../run-.../report.md",
  "manifest": "/absolute/managed/task-.../run-.../manifest.json",
  "sources": 3,
  "evidence": 3,
  "claims": 3,
  "limitations": 0
}
```

The app requires `run_id`/directory to match the discovered run and paths to remain contained.
Counts are nonnegative. Terminal status remains provisional until validation/reconciliation.

### Resume

```text
openscience resume <validated-run-directory> \
  --source <NAME>... [--local-root <reselected-PATH>]... \
  [--fixture <PATH>]... [--email <ADDRESS>] \
  [--synthesizer <NAME>] [--model-endpoint <URL> --model-name <NAME> \
  --model-timeout <SECONDS>] \
  [--allow-network] --yes --json
```

The exact existing run directory is the progress/cancel target. The client reacquires local roots,
credentials, and network grant. The terminal payload has the same fields as New run and must point
to the same run directory.

### Validate

```text
openscience validate <run-directory> --json
```

No providers, network, or secrets. Required fields are `valid`, `errors`, and `warnings`; each issue
has a stable code and safe message/context. A false result prevents valid resume/export state.

### Inspect

```text
openscience inspect <run-directory> --json
```

No providers, network, or secrets. Requires `summary`, request, plan, execution, capabilities,
records, artifacts, and limitations fields supported by the engine version. All artifact paths are
root-contained before use.

### Cancel

```text
openscience cancel <exact-discovered-run-directory> --json
```

No providers, network, or secrets. Required success fields are exact `run_directory` and
`requested_at`. Repeating the command must return the same recorded request time. Exit success means
request recorded, not terminal cancellation.

### Replay

```text
openscience replay <run-directory> --json
```

Optional read-only summary/recovery support. No provider, network, or credential input.

### Export

```text
openscience export <validated-run-directory> --output <chosen-zip> --json
```

No providers, network, or secrets. Required success fields are absolute `output` matching the chosen
target and positive integer `size`. The app validates the run immediately before invocation and
does not infer bundle validity solely from exit success.

## Exit Code Mapping

| Exit | Engine meaning | Desktop handling |
|------|----------------|------------------|
| 0 | Command success or documented awaiting approval | Decode one object, verify required fields, then reconcile recorded state where applicable |
| 1 | Other failure | Decode error object; preserve safe typed context; inspect recorded run if discovered |
| 2 | Invalid input/configuration | Return to relevant fields/settings; no automatic retry |
| 3 | Policy denial | Show denial and permission/settings recovery; never broaden grant automatically |
| 4 | Partial run | Decode outcome, validate artifacts, show `partial`, preserve resume eligibility |
| signal/unknown | Process termination | Typed bridge failure; validate any discovered run before presenting status |

An exit code and JSON shape that disagree is `terminal.exit_mismatch`. The app never changes a
nonzero exit into success because parseable JSON exists.

## Reconciliation Algorithm

For run/resume terminal handling:

1. Finish bounded stdout/stderr reads and wait for process termination.
2. Decode exactly one terminal object and map exit code.
3. Require the terminal run ID/directory to match unique discovery or exact resume target.
4. Drain complete event lines without accepting a partial tail.
5. Run `openscience validate <run> --json` without credentials/network.
6. Optionally run `inspect` to obtain the canonical desktop summary.
7. Compare terminal status, manifest/execution status, and terminal event.
8. Publish completed/partial/failed/cancelled only if compatible; otherwise publish
   `integrity_warning` with no valid resume/export action.

## File and Output Safety Limits

Initial desktop decoder limits (stricter engine errors may apply):

| Input | Maximum |
|-------|---------|
| Process stdout | 1 MiB |
| Retained redacted stderr | 256 KiB |
| One event JSONL line | 1 MiB |
| Event pending partial line | 1 MiB |
| One JSON artifact read for UI | 64 MiB |
| Markdown report read for UI | 32 MiB |
| Displayed diagnostic message | 8 KiB |

Exceeding a limit is explicit and never silently truncates research evidence into a verified view.
Diagnostics may be safely truncated and labeled; evidence/artifact decoding fails.

## Security Test Obligations

Contract tests MUST prove:

1. run stdout contains one terminal JSON object and no progress objects;
2. progress remains available from exactly one `run-*/events.jsonl` in the unique task workspace;
3. cancellation targets that directory and no other candidate;
4. each Keychain canary enters only its documented child environment variable;
5. canaries are absent from argv, non-secret config, stdout/stderr, OSLog capture, event/run artifacts,
   history index, support export, and research ZIP;
6. no credential is passed to provider listing/validate/inspect/cancel/replay/export;
7. declining network confirmation omits `--allow-network` and produces zero request in fixtures;
8. partial line, duplicate event, gap, malformed JSON, output overflow, exit mismatch, symlink escape,
   zero/multiple run candidates, process crash, and terminal-state disagreement fail transparently;
9. unknown compatible fields/events are safe and an incompatible engine version fails before run;
10. a packaged helper, when present, is resolved before a development override.
