# Technical Research: General Research Agent

## Decision 1: Original headless kernel before desktop UI

**Decision**: Build a Python library and CLI around an application-owned research state machine.

**Rationale**: Both reference projects demonstrate the value of runtime adapters, explicit tools,
durable state, and visible permissions, but their Electron-first architectures contain substantial
UI, IPC, and provider-runtime coupling. A headless core makes provenance and scientific contracts
testable before adding presentation layers.

**Alternatives considered**:

- Electron/React first: rejected because it delays verification of the scientific core.
- A thin prompt collection over an existing coding agent: rejected because plans, permissions,
  evidence, and replay would remain implicit and provider-owned.
- A workflow framework dependency: deferred until the domain state machine proves insufficient.

## Decision 2: Clean-room use of reference patterns

**Decision**: Treat `aipoch/open-science` and `proma-ai/Proma` as behavioral references only.

**Rationale**: The former is Apache-2.0 and the latter is AGPL-3.0. Independent interfaces, field
names, prompts, tests, UI, and code avoid license entanglement and product cloning while still
allowing established architectural ideas such as ports/adapters and append-only events.

**Alternatives considered**:

- Fork either project: rejected because the user explicitly requested an original construction.
- Copy selected adapters or prompts: rejected because it weakens clean-room provenance and adds
  upstream coupling.

## Decision 3: Python 3.11+ with a standard-library runtime

**Decision**: Use Python 3.11+ and keep runtime dependencies at zero for the first vertical slice.

**Rationale**: Python fits research tooling, ships typed dataclasses, protocols, enums, SQLite,
JSON, HTTP, hashing, ZIP, and CLI support, and makes the offline demo easy to install. Strict domain
constructors and validators provide runtime checking without making the core depend on one schema
framework.

**Alternatives considered**:

- TypeScript/Bun: good desktop ergonomics but weaker alignment with later scientific computing.
- Pydantic/FastAPI immediately: useful for a service, but unnecessary for the initial local CLI.
- LangChain/LangGraph or similar: not selected because core provenance and policy semantics should
  not inherit a third-party agent framework's state model.

## Decision 4: Scholarly provider adapters

**Decision**: Ship deterministic fixture/local providers and live OpenAlex and Crossref adapters.

**Rationale**: Two independent live metadata sources demonstrate provider replacement and
cross-source identifier normalization. OpenAlex exposes connected scholarly works and explicit
retraction/license fields; Crossref provides DOI metadata and update relationships. Network remains
optional, with configured timeout, budget, user agent, caching hooks, and backoff.

**Alternatives considered**:

- Browser scraping: rejected because academic APIs offer better contracts, identifiers, and usage
  policies.
- Four or more live APIs in v1: deferred; arXiv, PubMed, and DataCite can implement the same port
  after the contract and test fixtures stabilize.
- Full-text acquisition: deferred because access and redistribution rights differ from metadata
  availability.

## Decision 5: Evidence-first deterministic baseline plus optional model adapter

**Decision**: Make an extractive, deterministic synthesizer the default and expose a typed
`SynthesisProvider` port plus an optional OpenAI-compatible JSON adapter.

**Rationale**: The project must be demonstrable and testable without paid services. Model-generated
claims are useful, but they remain untrusted candidates and pass the same evidence-ID validator as
deterministic claims.

**Alternatives considered**:

- Require a cloud model: rejected because it breaks offline acceptance and reproducibility.
- No model port: rejected because a general agent must support richer synthesis through adapters.
- Accept model prose directly: rejected because citations and claim types would be unverifiable.

## Decision 6: File event store and content-addressed objects

**Decision**: Persist a hash-chained `events.jsonl`, atomic JSON projections, and SHA-256 addressed
artifact objects per run.

**Rationale**: A single-user CLI does not yet need a database. Append-only events preserve what
happened, projections make inspection simple, and object hashes detect artifact mutation. This
separates audit history from current state and permits deterministic offline replay.

**Alternatives considered**:

- SQLite from day one: viable, but adds migrations without improving the current single-writer use
  case; it remains the likely index for multi-project scale.
- Only mutable JSON files: rejected because past activity could be overwritten silently.
- A distributed event store: rejected as premature complexity.

## Decision 7: W3C PROV-inspired model and RO-Crate 1.3 export

**Decision**: Model sources/artifacts as entities, plan steps/tool calls as activities, and the user
and software as agents; export an RO-Crate 1.3 JSON-LD metadata projection with the native manifest.

**Rationale**: W3C PROV provides stable vocabulary for use, generation, and derivation. RO-Crate
provides a portable research-object package while allowing project-specific detailed records. The
native manifest remains authoritative for replay; RO-Crate is an interoperability projection.

**Alternatives considered**:

- Invent only a private provenance vocabulary: rejected because exports would be harder to reuse.
- Claim exact Process Run Crate conformance immediately: rejected until the implementation passes a
  profile-specific validator.

## Decision 8: Deny dangerous execution instead of simulating a sandbox

**Decision**: The MVP has no arbitrary shell, Python/R, browser, remote-write, or generic MCP tool.

**Rationale**: A prompt or path allowlist is not a sandbox. Proper scientific compute requires an
isolated, non-root runtime, read-only base, explicit mounts, resource limits, network policy,
dependency/image identities, and secret brokerage. Those will be a separate capability milestone.

**Alternatives considered**:

- Run subprocesses with timeouts: rejected because the host filesystem and credentials remain at
  risk.
- Require Docker: deferred because Docker is not universally available and the first research
  brief needs only read-only retrieval and synthesis.

## Source and standards notes

- OpenAlex API reference: <https://help.openalex.org/api/>
- Crossref REST API: <https://www.crossref.org/documentation/retrieve-metadata/rest-api/>
- W3C PROV-DM: <https://www.w3.org/TR/prov-dm/>
- RO-Crate 1.3: <https://w3id.org/ro/crate/1.3>
- Reference architecture snapshots and license notes are documented from:
  <https://github.com/aipoch/open-science> and <https://github.com/proma-ai/Proma>.
