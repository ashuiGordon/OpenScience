# Quickstart Validation: General Research Agent

**Release verification (2026-08-12)**: Completed from the built wheel in clean CPython 3.11.15.
The offline corpus produced 3 normalized sources, 3 evidence records, and 3 cited claims;
`validate` passed, `replay` reported verified state, and the exported ZIP passed its internal
checksum/provenance validator.

## Prerequisites

- Python 3.11+
- `uv` (recommended) or a standard virtual environment
- No API key or network connection for the primary scenario

## Install development environment

```bash
uv sync --frozen --all-groups
uv run openscience providers
```

Expected: built-in offline and live providers are listed without making network requests.

## Scenario 1: Complete offline research run

```bash
uv run openscience run \
  "What practices make computational research results easier to reproduce?" \
  --fixture examples/corpus.json \
  --yes \
  --workspace .demo-runs
```

Expected:

1. The command prints the created run directory and `completed` status.
2. The run contains a reviewable plan, `sources.json`, `evidence.json`, `claims.json`, `report.md`,
   `events.jsonl`, and `manifest.json`.
3. Every sourced finding in `report.md` references an evidence ID.
4. At least two fixture providers appear in the manifest.

## Scenario 2: Validate and replay without providers

```bash
uv run openscience validate .demo-runs/<run-id>
uv run openscience replay .demo-runs/<run-id>
```

Expected: validation succeeds, the event hash chain is intact, and replay reconstructs the same
counts and final status without reading the fixture or contacting a network.

## Scenario 3: Export a portable research object

```bash
uv run openscience export .demo-runs/<run-id> \
  --output .demo-runs/<run-id>.zip
```

Expected: the ZIP contains the report, evidence/claim records, native manifest, event log,
checksums, and an RO-Crate 1.3 `ro-crate-metadata.json` file. It does not contain credentials or
absolute approved-root paths.

## Scenario 4: Policy blocks an undeclared live request

```bash
uv run openscience run \
  "What is the current evidence on reproducible computational workflows?" \
  --source openalex \
  --yes \
  --workspace .demo-runs
```

Expected: the network capability is denied before a request is sent and the run records the policy
decision. Re-run with `--allow-network` to authorize read-only scholarly API access.

## Quality gates

```bash
uv run ruff check .
uv run ruff format --check .
uv run mypy src
uv run pytest --cov=openscience_agent --cov-report=term-missing
```

All commands must pass. Live provider tests remain opt-in so this gate is deterministic.
