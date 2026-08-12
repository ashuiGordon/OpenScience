# OpenScience

OpenScience is an original, headless research agent for producing evidence-backed, auditable,
and replayable research briefs. The Python distribution is `openscience-agent`, the import package
is `openscience_agent`, and the command-line program is `openscience`.

The project puts evidence before narrative: sources, exact evidence passages, claims, policy
decisions, events, and output artifacts remain separate records connected by stable identifiers.
The default workflow is deterministic and works offline; live scholarly APIs and model-assisted
synthesis are optional adapters behind the same contracts.

> OpenScience provides research assistance, not expert, clinical, legal, ethics, safety, or
> regulatory review. Users remain responsible for source rights, interpretation, validation, and
> decisions based on generated work.

## Current MVP boundary

The first release is intentionally a local Python library and CLI for one researcher. Its scope is:

- finite plans that a user can inspect and explicitly approve;
- deterministic fixture research requiring neither an API key nor network access;
- read-only ingestion of text, Markdown, and JSON beneath explicitly approved local roots;
- normalized records from fixture, local-file, OpenAlex, and Crossref source adapters;
- deterministic extractive synthesis, with an optional OpenAI-compatible JSON adapter;
- evidence-linked Markdown reports, append-only hash-chained events, checkpoints, validation,
  offline replay, and portable ZIP/RO-Crate metadata export;
- capability policy, network opt-in, bounded provider use, and redaction before persistence.
- safe local/model separation: the optional network model refuses local-file evidence before any
  transport; offline extractive synthesis remains available for private materials.

The supported first-release platforms are macOS and Linux with Python 3.11+. The local-file adapter
uses POSIX descriptor-relative, no-follow reads to defend against path replacement races; Windows
support is deferred until it can provide the same boundary guarantee.

The MVP does **not** execute arbitrary shell/Python/R code, control a browser or laboratory,
publish remotely, bypass access controls, expose a generic MCP surface, or provide a desktop UI,
multi-user service, or regulated decision support. Those capabilities require separate sandbox,
authorization, and governance specifications.

## Architecture at a glance

```text
CLI / Python API
        |
Application commands (run, resume, inspect, cancel, validate, replay, export)
        |
Research orchestrator ----- capability policy
        |                         |
        +-- typed source and synthesis ports
        +-- run repository and artifact-store ports
        +-- validation and event ports
        |
Adapters: fixtures, local files, OpenAlex, Crossref,
          extractive/model synthesis, filesystem persistence
```

The domain and orchestration kernel do not import provider implementations. Side effects stay
behind typed ports, provider content is always untrusted data, and each state-changing step is
recorded before it is reported as complete. See [Architecture](docs/architecture.md) and
[Extension guide](docs/extensions.md).

## CLI surface

| Command | Purpose |
|---------|---------|
| `openscience plan QUESTION` | Create a finite plan without invoking providers |
| `openscience run QUESTION` | Start an approved, bounded research run |
| `openscience resume RUN_DIRECTORY` | Continue from a validated checkpoint |
| `openscience inspect RUN_DIRECTORY` | Show request, plan, execution, capabilities, records, and artifacts |
| `openscience cancel RUN_DIRECTORY` | Idempotently request cancellation before the next governed action |
| `openscience validate RUN_DIRECTORY` | Audit hashes, policy, records, claims, and artifacts offline |
| `openscience replay RUN_DIRECTORY` | Reconstruct a summary from recorded state without providers |
| `openscience export RUN_DIRECTORY --output PATH` | Create a sanitized ZIP with native records and RO-Crate metadata |
| `openscience providers` | List provider descriptors and health without network calls |

The command contract uses exit code `0` for success, `2` for invalid input, `3` for policy denial,
`4` for a labeled partial run, and `1` for other failures. Add `--json` to commands that support a
machine-readable response; it emits exactly one success or error object to stdout, while human-mode
diagnostics use stderr.

## Verified quickstart

> **Verification status (2026-08-12):** this sequence was run from the built wheel in a clean
> CPython 3.11.15 environment with networking disabled. It completed with 3 normalized sources,
> 3 evidence records, and 3 cited claims; validation passed, replay was verified, and export
> produced a self-validating ZIP.

Prerequisites are Python 3.11+ and [`uv`](https://docs.astral.sh/uv/). The primary scenario needs
no API key and no network connection.

```bash
uv sync --frozen --all-groups
uv run openscience providers

uv run openscience run \
  "What practices make computational research results easier to reproduce?" \
  --fixture examples/corpus.json \
  --yes \
  --workspace .demo-runs
```

The completed run is expected to contain `plan.json`, `sources.json`, `evidence.json`,
`claims.json`, `report.md`, `events.jsonl`, and `manifest.json`. Replace `<run-id>` below with the
directory printed by `run`:

```bash
uv run openscience validate .demo-runs/<run-id>
uv run openscience inspect .demo-runs/<run-id>
uv run openscience replay .demo-runs/<run-id>
uv run openscience export .demo-runs/<run-id> \
  --output .demo-runs/<run-id>.zip
```

Live sources are denied unless the user opts in. For example, `--source openalex` requires
`--allow-network`; use `--email` to supply the polite contact identity expected by scholarly APIs.

## Development

Runtime code has no third-party dependencies. Development dependencies are isolated in the `dev`
group:

```bash
uv sync --frozen --all-groups
uv run ruff format --check .
uv run ruff check .
uv run mypy src
uv run pytest --cov=openscience_agent --cov-report=term-missing
```

Live integration tests remain explicit opt-in tests; the default quality gate is deterministic.

## Clean-room relationship to reference projects

The product brief was informed by public, high-level patterns visible in
[`aipoch/open-science`](https://github.com/aipoch/open-science) (Apache-2.0) and
[`proma-ai/Proma`](https://github.com/proma-ai/Proma) (AGPL-3.0): local-first operation,
provider adapters, durable activity, declared tools, and visible permission boundaries.

This repository is **not** a fork, port, reskin, or derivative integration of either project. It
does not copy their source code, prompts, schemas, field names, tests, UI, internal directory
structure, or branded assets. Its requirements, interfaces, data model, CLI, tests, and
implementation were designed independently for evidence traceability and reproducible research.
The reference projects are not affiliated with or responsible for this project.

## License

Copyright 2026 OpenScience contributors.

Licensed under the [Apache License 2.0](LICENSE).
