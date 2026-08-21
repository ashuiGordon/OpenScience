# Command-Line Contract

Executable name: `openscience`

All commands exit `0` on success, `2` for invalid user input, `3` for policy denial, `4` for a run
that completed only partially, and `1` for other failures. Human-readable output is the default;
`--json` emits exactly one success or error object to stdout. Human-mode diagnostics use stderr.
A policy denial that prevents command fulfillment returns `3`; a denied optional provider within a
run is recorded and contributes to a labeled partial result (`4`) when useful work can continue.

## `openscience plan QUESTION`

Creates a finite plan without invoking sources or models and writes it to stdout or `--output`.
The JSON plan includes stable step IDs, purposes, capabilities, dependencies, completion
conditions, and immutable `pending` approval status. Users may edit titles, purposes, completion
conditions, and provider selection supplied to `run`; step IDs, dependencies, capability bindings,
and plan status are fixed in the first release and structural validation rejects edits before
execution. Actual attempt state is recorded separately in `execution.json`.

## `openscience run QUESTION`

Creates and executes a research run.

Key options:

```text
--fixture PATH            Load one or more deterministic providers from a corpus
--local-root PATH         Approve and search a local document root (repeatable)
--source NAME             Enable a registered provider (repeatable)
--allow-network           Permit network-read providers
--email ADDRESS           Contact identity for polite scholarly API usage
OPENSCIENCE_OPENALEX_API_KEY
                          Optional OpenAlex credential supplied through the process environment
OPENSCIENCE_CROSSREF_API_KEY
                          Optional Crossref Plus credential supplied through the process environment
--max-records N           Bound normalized source count
--max-network-requests N  Bound provider requests
--timeout SECONDS         Bound elapsed run time
--workspace PATH          Parent directory for run records
--model-config PATH       Optional JSON model adapter configuration
--model-endpoint URL      Reviewed inline OpenAI-compatible endpoint (mutually exclusive with file)
--model-name NAME         Reviewed inline model identifier
--model-timeout SECONDS   Reviewed inline model request timeout in (0, 300]
--synthesizer NAME        Select a registered synthesis provider by descriptor name
--plan PATH               Execute a previously reviewed plan
--yes                     Explicitly approve the displayed/supplied plan non-interactively
--json                    Machine-readable completion response
```

The legacy `--openalex-api-key` and `--crossref-api-key` options remain accepted for compatibility,
but interactive applications MUST prefer the environment variables above so credentials do not
appear in the process argument list. Model configuration names its credential environment variable
with `api_key_env`; the default is `OPENSCIENCE_MODEL_API_KEY`. Credential values MUST NOT be
persisted in request, plan, run, log, or export records.

Interactive clients SHOULD inspect a non-secret model configuration during plan review and execute
with the three inline model options. This binds the approved endpoint/model/timeout values to the
process invocation and avoids reopening a replaceable configuration file after authorization.

In an interactive terminal, omission of `--yes` displays the plan and asks for approval. In a
non-interactive session, omission of `--yes` stops in `awaiting_approval` before any provider call.
The saved run can then be resumed with approval.

Successful output identifies `run_id`, `run_directory`, `status`, `report`, `manifest`, and source,
evidence, claim, and limitation counts. A partial run returns the same fields with status `partial`.

## `openscience resume RUN_DIRECTORY`

Loads request, plan, checkpoint, and hash-validated events, then continues incomplete steps.
Provider options are accepted again because secrets and live credentials are not stored. Completed
steps are not repeated. A mismatch between supplied providers and the saved run is reported before
execution.

## `openscience validate RUN_DIRECTORY`

Validates event-chain integrity, projection hashes, claim/evidence links, policy records, manifest
schema, and artifact identities. It never contacts external services. Output contains a structured
list of errors and warnings.

## `openscience replay RUN_DIRECTORY`

Reads the append-only event history and recorded projections to reconstruct a run summary without
executing providers or models. It fails if the hash chain is invalid.

## `openscience inspect RUN_DIRECTORY`

Validates and reconstructs recorded state, then displays the request, plan, execution status,
capability identities, record indices, artifacts, and limitations. `--json` emits the same view as
one machine-readable object and never contacts a provider.

## `openscience cancel RUN_DIRECTORY`

Atomically records an idempotent cancellation request. An active or subsequently resumed attempt
checks the marker before each step and network action, records a `cancelled` terminal state, and
does not start another step. A transport already in progress remains subject to its finite timeout.

## `openscience export RUN_DIRECTORY --output PATH`

Creates a ZIP research bundle containing the human report, export-specific integrity manifest,
evidence and claim records, rehashed event log, checksums, and `ro-crate-metadata.json`. Credentials,
caches, approved absolute local roots, and unrelated workspace data are excluded. Sanitization is
performed before export hashes are calculated so the bundle validates independently.

## `openscience providers`

Lists built-in and discovered providers with name, version, kind, risk, availability, and health
error. This command performs no provider network calls.
