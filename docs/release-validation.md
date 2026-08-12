# Release validation evidence

This document records the release-candidate checks executed on 2026-08-12 from the
`agent/general-research-agent` working tree. It is evidence for this exact candidate, not a claim
that live OpenAlex, Crossref, or model services were contacted. Live-provider behavior remains an
explicit opt-in activity; all results below are deterministic and offline unless stated otherwise.

## Verification environment

| Item | Observed value |
|------|----------------|
| Host | macOS 26.4.1, arm64 |
| Development gate interpreter | CPython 3.12.13 |
| Clean-install interpreter | CPython 3.11.15 |
| `uv` | 0.12.3 |
| Candidate branch | `agent/general-research-agent` |
| Baseline commit before candidate changes | `3b1354f297fe` |
| Runtime dependencies | None |

The candidate was still an uncommitted working tree when these measurements were captured. CI
must repeat the deterministic gates on the committed tree.

## Gate summary

| Gate | Result | Recorded evidence |
|------|--------|-------------------|
| Offline quickstart | PASS | Final clean wheel run completed in 0.39 s with 3 sources, 3 evidence records, 3 claims, and 26 events |
| `validate` | PASS | No errors or warnings; 0.09 s from the final clean installation |
| `inspect` | PASS | Completed status, 3/3/3 record counts, 26 events, and one report artifact; 0.07 s |
| Offline `replay` | PASS | `verified=true`, all five planned steps completed, and projection hashes present; 0.07 s |
| Portable `export` | PASS | 19,622-byte ZIP; internal checksum/provenance validation passed; 0.09 s |
| Five interruption points | PASS | `discover`, `extract`, `synthesize`, `validate`, and `report` all resumed without duplicate completed steps |
| Cancellation | PASS | Cancel marker stopped resume before the next step and produced a valid `cancelled` run |
| Completed-run resume | PASS | Resume was idempotent and did not append events |
| Secret and local-path protection | PASS | Targeted persistence/export tests passed; candidate secret-pattern scan found zero findings |
| Claim–evidence performance | PASS | 1,000 links, 20 rounds: 1.068 ms median and 1.777 ms maximum, below the 2 s target |
| One-provider failure | PASS | Simulated OpenAlex timeout yielded a valid labeled `partial` run in 0.454 s, below the 30 s target |
| Python 3.11 build/install | PASS | Offline sdist and wheel build, no-index wheel install, CLI run, validation, replay, and export all passed |
| Format, lint, types | PASS | 71 files formatted; Ruff clean; strict Mypy clean across 20 source files |
| Tests and coverage | PASS | 133 selected tests passed, 3 opt-in live tests deselected; 77% branch-aware total coverage |
| Spec Kit prerequisite/structure | PASS | Feature artifacts resolved; 24 FRs, 9 SCs, 56 unique sequential tasks, no unresolved placeholders |
| Spec Kit semantic release audit | PASS | Final read-only freeze audit reported 0 CRITICAL and 0 HIGH findings; live smokes are explicitly gated |

## 1. Clean Python 3.11 build and offline journey

The strongest quickstart evidence came from an isolated CPython 3.11 virtual environment created
outside the repository. The wheel was installed with `--no-index`; the installed CLI, rather than
the source checkout, performed the journey.

```bash
set -euo pipefail
verify_dir=$(mktemp -d /tmp/openscience-clean311.XXXXXX)

UV_OFFLINE=1 uv build --out-dir "$verify_dir/dist"
UV_OFFLINE=1 uv venv --python 3.11 "$verify_dir/venv"
wheel_path=$(find "$verify_dir/dist" -maxdepth 1 -name '*.whl' -print -quit)
UV_OFFLINE=1 uv pip install \
  --python "$verify_dir/venv/bin/python" \
  --no-index "$wheel_path"

"$verify_dir/venv/bin/python" --version
"$verify_dir/venv/bin/openscience" --version
"$verify_dir/venv/bin/openscience" run \
  "What practices make computational research results easier to reproduce?" \
  --fixture "$PWD/examples/corpus.json" \
  --yes \
  --workspace "$verify_dir/runs" \
  --json

run_dir=$(find "$verify_dir/runs" -mindepth 1 -maxdepth 1 -type d -print -quit)
"$verify_dir/venv/bin/openscience" validate "$run_dir" --json
"$verify_dir/venv/bin/openscience" inspect "$run_dir" --json
"$verify_dir/venv/bin/openscience" replay "$run_dir" --json
"$verify_dir/venv/bin/openscience" export "$run_dir" \
  --output "$verify_dir/bundle.zip" \
  --json
```

Observed versions were Python 3.11.15 and OpenScience 0.1.0. The final source distribution and
wheel built offline in 5.20 s and the no-index wheel install took 0.17 s. The installed run
completed in 0.39 s. `validate` returned `valid: true` with no issues, replay returned
`replay_mode: verified_projection`, and the export validator accepted the bundle.

The bundle contained:

```text
artifacts/report.md        checkpoint.json          checksums.txt
claims.json                events.jsonl              evidence.json
execution.json             manifest.json            plan.json
policy_decisions.json      report.md                 request.json
ro-crate-metadata.json     sources.json
```

No provider/model calls are replayed: replay accepts persisted projections only after domain,
hash, and event-chain validation.

## 2. Resume, cancellation, secrets, and local paths

The following focused gate exercises every planned interruption point plus the cancellation and
local-data export controls:

```bash
set -euo pipefail
test_tmp=$(mktemp -d /tmp/openscience-resume-security.XXXXXX)
PYTEST_ADDOPTS='-p no:cacheprovider' uv run pytest -q \
  tests/integration/test_resume.py \
  tests/integration/test_security.py::test_local_secret_is_redacted_from_every_run_and_export_artifact \
  tests/integration/test_export.py::test_local_export_removes_host_roots_and_rebinds_sanitized_identities \
  --basetemp "$test_tmp"
```

Final result: 10 passed in 3.81 s. The five-point matrix asserts that a step already represented by a
`step.completed` event is never repeated. The cancellation case asserts that `extract` never
starts after the marker, the terminal event is `run.cancelled`, and the resulting run still passes
offline validation. A separate case confirms that resuming a completed run leaves `events.jsonl`
byte-for-byte unchanged.

The local-secret acceptance test scans every persisted file and every ZIP member for its unique
fixture secret. The local-path export test checks every ZIP payload for the approved host root,
rebuilds sanitized request and policy identities, validates the exported manifest against the
JSON Schema, and runs the independent bundle validator.

The candidate-wide secret-pattern probe scanned tracked files and unignored candidate files, not
only the baseline commit:

```bash
git ls-files --cached --others --exclude-standard -z
```

Using the same fixed credential/private-key and assigned-secret rules as CI, it scanned 94 text
files and reported zero findings. The committed-tree CI scanner remains the authoritative repeat
of this gate.

## 3. Claim–evidence performance

This deterministic probe builds 1,000 source/evidence/claim triples and validates each exact
claim-to-passage link. Run it from the repository root:

```bash
uv run python - <<'PY'
from statistics import median
from time import perf_counter
from openscience_agent.validation import validate_claim_evidence

count = 1000
sources = [
    {"source_id": f"source-{i}", "status": "active", "title": f"Source {i}"}
    for i in range(count)
]
evidence = [
    {
        "evidence_id": f"evidence-{i}",
        "source_id": f"source-{i}",
        "passage": f"Observation {i}.",
    }
    for i in range(count)
]
claims = [
    {
        "claim_id": f"claim-{i}",
        "text": f"Observation {i}.",
        "kind": "sourced_fact",
        "evidence_ids": [f"evidence-{i}"],
        "limitations": [],
    }
    for i in range(count)
]

measurements = []
for _ in range(20):
    started = perf_counter()
    result = validate_claim_evidence(claims, evidence, sources)
    measurements.append(perf_counter() - started)
    assert result.valid

print(
    f"links={count} rounds={len(measurements)} "
    f"min={min(measurements):.6f}s median={median(measurements):.6f}s "
    f"max={max(measurements):.6f}s"
)
PY
```

Final observed result: minimum 0.000906 s, median 0.001068 s, maximum 0.001777 s. This is substantially
below the plan's two-second target.

## 4. One-provider failure time

The failure probe registered one healthy fixture source and an OpenAlex adapter whose injected
transport deterministically raises `TimeoutError`. The adapter timeout was 0.05 s, the run timeout
was 5 s, and the network budget allowed the initial request plus its bounded retry. It exercised
the real registry, policy engine, orchestrator, adapter, persistence, and whole-run validator.

The probe is reproducible without network access:

```bash
failure_dir=$(mktemp -d /tmp/openscience-provider-failure.XXXXXX)
uv run python - "$failure_dir" <<'PY'
import json
import sys
from pathlib import Path
from time import perf_counter

from openscience_agent.adapters.fixtures import FixtureSourceProvider
from openscience_agent.adapters.model import ExtractiveSynthesizer
from openscience_agent.adapters.openalex import OpenAlexSourceProvider
from openscience_agent.cli import _orchestrator
from openscience_agent.domain import ResearchRequest, RunLimits, SourceCandidate
from openscience_agent.policy import PolicyEngine
from openscience_agent.registry import ProviderRegistry
from openscience_agent.validation import validate_run

workspace = Path(sys.argv[1])
registry = ProviderRegistry()
registry.register_source(FixtureSourceProvider("healthy-fixture", [SourceCandidate(
    provider="healthy-fixture",
    provider_id="one",
    title="Recorded workflows",
    abstract_or_excerpt="Recording inputs and outputs improves reproducibility.",
    query="reproducibility",
)]))

def timeout_transport(*args: object) -> bytes:
    raise TimeoutError("deterministic simulated provider timeout")

registry.register_source(OpenAlexSourceProvider(timeout=0.05, transport=timeout_transport))
registry.register_synthesizer(ExtractiveSynthesizer())
request = ResearchRequest(
    question="What practices improve computational reproducibility?",
    source_names=("healthy-fixture", "openalex"),
    limits=RunLimits(max_network_requests=2, timeout_seconds=5),
)
started = perf_counter()
outcome = _orchestrator(registry, PolicyEngine(allow_network=True)).execute(
    request,
    workspace=workspace,
    source_names=request.source_names,
    synthesizer_name="extractive",
    approved=True,
)
elapsed = perf_counter() - started
manifest = json.loads((outcome.run_directory / "manifest.json").read_text())
events = [
    json.loads(line)
    for line in (outcome.run_directory / "events.jsonl").read_text().splitlines()
]
validation = validate_run(outcome.run_directory)
print(json.dumps({
    "elapsed_seconds": round(elapsed, 6),
    "failed_provider_events": sum(event["type"] == "provider.failed" for event in events),
    "limitations": manifest["limitations"],
    "network_requests_used": manifest["execution"]["network_requests_used"],
    "run_valid": validation.valid,
    "status": manifest["status"],
    "validation_errors": len(validation.errors),
}, sort_keys=True))
PY
```

Observed result:

```json
{
  "elapsed_seconds": 0.454273,
  "failed_provider_events": 1,
  "limitations": [
    "Source openalex failed: ProviderError: OpenAlex request timed out after 0.05s"
  ],
  "network_requests_used": 2,
  "run_valid": true,
  "status": "partial",
  "validation_errors": 0
}
```

This satisfies SC-007 for the deterministic failure case: a useful source remained available, the
failed source was retained as an explicit limitation, and a valid labeled partial result returned
well within 30 seconds. It does not measure third-party service latency.

## 5. Full local quality gate

Caches and generated test data were directed outside the repository:

```bash
set -euo pipefail
gate_tmp=$(mktemp -d /tmp/openscience-gates.XXXXXX)
export RUFF_CACHE_DIR="$gate_tmp/ruff-cache"
export MYPY_CACHE_DIR="$gate_tmp/mypy-cache"
export COVERAGE_FILE="$gate_tmp/coverage"
export PYTEST_ADDOPTS='-p no:cacheprovider'

uv run ruff format --check .
uv run ruff check .
uv run mypy src
uv run pytest \
  --basetemp "$gate_tmp/pytest" \
  --cov=openscience_agent \
  --cov-report=term-missing
```

Observed results:

- Ruff format: 71 files already formatted.
- Ruff lint: all checks passed.
- Mypy strict mode: no issues in 20 source files.
- Pytest: 136 collected, 3 live tests deselected, and 133 passed in 10.55 s.
- Coverage: 77% total with branch measurement enabled.

The deterministic suite excludes the registered `live` marker by project configuration.

## 6. Inspectable provenance walkthrough

For one sampled sourced fact from the clean offline run, the persisted identifiers resolved in
this order:

```text
claim-b77d...58b5a3f
  -> evidence-0259...51a644d
  -> source-a0fc...0677314
  -> A Practical Handbook for Reproducible Computational Research
  -> https://example.org/research/reproducibility-handbook
```

The source record retained two retrieval observations. Programmatic resolution of the sampled
path took 0.002702 s. This proves that the provenance graph is navigable and comfortably supports
the two-minute target; it is not a substitute for a timed human usability study.

## 7. Spec Kit consistency audit

The project-local `speckit-analyze` instructions require a read-only audit after task generation.
The prerequisite check succeeded:

```bash
.specify/scripts/bash/check-prerequisites.sh \
  --json \
  --require-tasks \
  --include-tasks
```

It resolved `specs/001-general-research-agent` and found `research.md`, `data-model.md`,
`contracts/`, `quickstart.md`, and `tasks.md`. A structural inventory found 24 functional
requirements, 9 measurable success criteria, and 56 unique sequential tasks (`T001`–`T056`), with
no unresolved `TODO`, `TKTK`, question-mark, or placeholder markers. The traceability table spans
all FR and SC ranges.

The first semantic pass found one constitution-level release blocker: the constitution requires
every network-dependent integration to include deterministic fixtures **and explicit opt-in live
tests**, and the implementation plan repeats that promise. OpenAlex and Crossref had extensive
mocked contract coverage, but no test was initially marked `live`.

That blocker was subsequently remediated with explicitly marked OpenAlex, Crossref, and
OpenAI-compatible model smokes. A collection-only check found all three tests, and an invocation
with every opt-in environment variable removed skipped all three tests without contacting a
service:

```bash
uv run pytest --collect-only -q -m live tests/integration/test_live_sources.py
env -u OPENSCIENCE_RUN_LIVE_TESTS \
  -u OPENSCIENCE_LIVE_EMAIL \
  -u OPENSCIENCE_LIVE_MODEL_ENDPOINT \
  -u OPENSCIENCE_LIVE_MODEL_NAME \
  -u OPENSCIENCE_LIVE_MODEL_API_KEY \
  uv run pytest -q -m live tests/integration/test_live_sources.py
```

Observed results: 3 tests collected; 3 tests safely skipped. Actual live execution was not part of
this offline release validation.

After the live-smoke and terminal-state remediations, a final read-only freeze audit reported
**0 CRITICAL and 0 HIGH findings**. In particular, it re-ran the terminal-state tamper: changing a
completed run's manifest, checkpoint, and execution status together to `running`, while preserving
the final `run.completed` event and recalculating state hashes, now fails validation with
`events.terminal_status`. The freeze audit also confirmed the declared unknown-extension boundary,
machine-readable CLI exception handling, required manifest error projection, typed fixture
cancellation, and the documented Windows local-material scope.

At the time of that audit, `spec.md` still said `Draft` and all 56 task checkboxes remained open.
Those were classified as non-semantic release bookkeeping, not unresolved implementation defects.
After the final clean-install journey, quality gate, and 94-file candidate secret scan passed, the
specification was marked `Implemented and verified` and T001–T056 were closed. No source behavior
changed during this documentation-only closeout.
