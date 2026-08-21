# OpenScience Architecture

## Purpose and design constraints

OpenScience turns a scoped research question into a reviewable plan, normalized sources, exact
evidence records, classified claims, a cited report, and an auditable run manifest. It is built as
an original headless kernel so scientific integrity, provenance, policy, and replay remain
testable independently of any model vendor or user interface.

The first-release runtime targets macOS and Linux. Safe local ingestion relies on POSIX
descriptor-relative, no-follow file opening; a Windows adapter is deferred until it can preserve
the same race-resistant approved-root invariant.

The architectural constraints are deliberate:

- Python 3.11+ and no third-party runtime dependencies;
- useful offline behavior with deterministic fixtures and extractive synthesis;
- no required model API, database, or desktop shell;
- network access denied unless the user explicitly enables it;
- untrusted provider, document, and model content never changes policy or the objective;
- every externally verifiable claim either links to evidence or carries an explicit non-evidence
  classification;
- state-changing activity is persisted before the application reports completion.

## Layers and dependency direction

```text
┌──────────────────────────────────────────────────────────────────┐
│ CLI / Python API                                                 │
│ Parse input, display plans, collect approval, select adapters    │
└──────────────────────────────┬───────────────────────────────────┘
                               │ commands
┌──────────────────────────────▼───────────────────────────────────┐
│ Application and orchestration                                   │
│ Plan, execute bounded steps, checkpoint, resume, replay, export  │
└──────────┬───────────────────┬────────────────────┬──────────────┘
           │ typed ports       │ policy decisions   │ validation
┌──────────▼──────────┐  ┌─────▼────────────┐  ┌────▼─────────────┐
│ Domain              │  │ Capability policy│  │ Provenance/store │
│ Requests, plans,    │  │ allow / deny /   │  │ events, objects, │
│ sources, evidence,  │  │ approval-required│  │ projections      │
│ claims, artifacts   │  └──────────────────┘  └──────────────────┘
└──────────┬──────────┘
           │ implemented by
┌──────────▼───────────────────────────────────────────────────────┐
│ Boundary adapters                                               │
│ fixture/local/OpenAlex/Crossref, synthesis, filesystem, clock   │
└──────────────────────────────────────────────────────────────────┘
```

Dependencies point inward. Domain objects do not import CLI, storage, network, or provider
implementations. The orchestrator depends on typed ports, and adapters implement those ports.
Provider replacement therefore changes registration/configuration rather than the kernel.

## Core responsibilities

| Component | Owns | Must not own |
|-----------|------|--------------|
| Domain | Valid entities, transitions, canonical serialization, stable/content IDs | Filesystem, network, process state |
| Orchestrator | Finite plan execution, dependencies, limits, checkpoints, partial/failure semantics | Vendor payload schemas or secret storage |
| Policy | Capability risk, target normalization, approval outcomes, path/network boundaries | Executing the requested action |
| Provider registry | Built-ins, entry-point discovery, descriptor compatibility and health | Research workflow decisions |
| Source adapters | Retrieval and provider-to-domain normalization | Claims or report prose |
| Synthesis adapters | Candidate claims referencing known evidence IDs | Trusting or persisting unvalidated model output |
| Repository/artifact store | Append-only events, atomic projections, addressed bytes | Reinterpreting scientific meaning |
| Validator | Event chain, hashes, claim/evidence links, manifest and artifact invariants | Repairing failures silently |
| Renderer/exporter | Citation-preserving report and portable research object | Inventing evidence or credentials |

## Research run flow

1. The CLI validates the question, roots, sources, limits, and output location.
2. The application creates a finite plan whose steps declare purpose, capability, dependencies,
   and completion conditions.
3. The user approves or revises descriptive plan fields and provider selection. The first-release
   step IDs, dependencies, and capability bindings are fixed and validated. A non-interactive
   invocation without `--yes` stops in `awaiting_approval` before provider activity.
4. Before every adapter action, policy evaluates the declared capability, risk, action, and
   normalized target. Denials and approval requirements are persisted.
5. Enabled source adapters return bounded candidates. Adapter-specific payloads become normalized
   source and retrieval records at the boundary.
6. Evidence extraction stores exact passages separately from prose. Identifier normalization and
   deduplication preserve every provider observation.
7. A deterministic or optional model synthesizer proposes typed claims. Unknown evidence IDs,
   unsupported sourced facts, and invalid confidence values are rejected.
8. Validation checks source/evidence/claim links and direct attribution of sourced facts,
   retraction limitations, event-chain integrity, state/checkpoint hashes, artifact hashes, and
   manifest completeness before a run can be `completed`.
9. The renderer writes an evidence-linked report. Replay uses recorded events/projections only;
   export packages native records, checksums, and an RO-Crate 1.3 projection.

A provider failure can yield a labeled `partial` result when useful evidence remains. Missing or
invalid evidence never becomes fabricated success.

## Persistence and provenance

Each run directory is an inspectable research record:

- `events.jsonl` is append-only. Every event includes sequence, previous hash, and its own SHA-256
  hash, making deletion, insertion, or mutation observable.
- current request, plan, source, evidence, claim, policy, and checkpoint projections are written
  atomically for convenient inspection;
- generated bytes are immutable objects addressed by SHA-256; artifact metadata links an object
  to its producer step and input entity IDs;
- `manifest.json` indexes identities, configuration, events, projections, artifacts, timestamps,
  errors, limitations, per-step state, and network usage and is the replay authority;
- request, plan, checkpoint, execution, and report projections are indexed by relative path and
  SHA-256; resume verifies their identities and the completed-step prefix before provider use;
- `ro-crate-metadata.json` is an interoperability projection. It does not replace the native event
  and claim contracts or imply conformance beyond the documented RO-Crate 1.3 mapping.

Derived artifacts retain input links. Nondeterministic provider/model identities and relevant
configuration are recorded, while credentials and unrelated absolute local paths are excluded.

## Security and trust model

### Boundaries

| Boundary | Default | Required control |
|----------|---------|------------------|
| CLI/configuration input | Untrusted | Strict parsing, bounded values, normalized paths |
| Local research files | Denied outside approved roots | Resolved-root containment, symlink-escape rejection, size/format limits, read-only access |
| Retrieved source text | Untrusted data | Delimiting and normalization; never interpreted as policy/instructions |
| Model output | Untrusted structured candidates | Schema/domain validation and known evidence-ID checks |
| Local evidence to network model | Denied in the MVP | A separately specified data-egress capability; `--allow-network` is insufficient |
| Network providers | Disabled | `network.read`, exact-origin authorization, explicit `--allow-network`, absolute timeout/shared budget, bounded retry, redirects disabled |
| Persisted/exported records | Potentially sensitive | Secret-pattern redaction before write/egress, path minimization, hashes after sanitization, exclusion lists |
| Extension packages | User-installed code | Descriptor/contract checks and normal Python package trust review |

Capability descriptors declare identity, version, kind, risk, schemas, and permissions before
invocation. Outcomes are `allow`, `deny`, or `approval_required`; an adapter cannot grant itself
permission. Policy decisions are first-class run records rather than log messages.

The MVP intentionally has no arbitrary process execution, shell/Python/R runtime, browser control,
remote write/publication, wet-lab control, or generic MCP bridge. A path allowlist is not a sandbox.
Future compute requires a separately specified isolated, non-root runtime with explicit mounts,
resource limits, network policy, immutable environment identities, and secret brokerage.

### Research integrity and data governance

- Attribution, retrieval time, stable identifiers/URLs, source status, and license metadata are
  retained when available; unknown licenses remain explicitly unknown.
- Paywalls and access controls are never bypassed. Provider terms, rate limits, copyright, and
  database rights remain user and adapter obligations.
- Secrets, unpublished/sensitive data, and personal data must not enter fixtures, prompts, logs,
  manifests, or exports. Known credential patterns are redacted before persistence.
- The optional network model refuses evidence derived from local files before transport; users can
  retain local synthesis by selecting the deterministic extractive adapter.
- Clinical, human-subjects, hazardous, dual-use, or regulated work must surface an appropriate
  human review boundary; generated research is assistance, not expert review.
- Coverage dates, unavailable material, conflicts, retractions, and evidence-quality limits remain
  visible in reports.

## Architectural decisions

| Decision | Chosen approach | Deferred/rejected alternative |
|----------|-----------------|-------------------------------|
| Product surface | Headless library and CLI | Electron/desktop UI before scientific contracts |
| Runtime | Python 3.11 standard library | Required framework or model SDK |
| Workflow | Application-owned finite state machine | Provider-owned prompt workflow |
| Default synthesis | Deterministic extractive adapter | Required cloud model or unchecked prose |
| Persistence | Hash-chained JSONL, atomic JSON, content-addressed objects | Mutable-only files, premature distributed event store |
| Provenance export | Native manifest plus W3C PROV-inspired RO-Crate 1.3 mapping | Private-only vocabulary or overstated profile conformance |
| Execution safety | Dangerous execution absent from MVP | Host subprocesses described as a sandbox |

## Clean-room references and attribution

The architecture was designed independently. Two public projects informed only general product
patterns (public repository descriptions and license labels checked 2026-08-12):

- [aipoch/open-science](https://github.com/aipoch/open-science), Apache-2.0: a local-first,
  model-agnostic scientific research workbench with inspectable activity and permissioned tools;
- [proma-ai/Proma](https://github.com/proma-ai/Proma), AGPL-3.0: a local-first general-agent
  workbench using adapters, durable JSON/JSONL state, workspaces, and explicit permissions.

No source code, prompts, schema names, tests, UI, internal file layout, or branded asset from either
repository is copied into OpenScience. The shared ideas—ports/adapters, application-owned
orchestration, durable events, declared capabilities, and human approval boundaries—are general
architectural patterns independently expressed here for the project's scientific contracts.

Normative and interoperability references are the
[W3C PROV Data Model](https://www.w3.org/TR/prov-dm/),
[RO-Crate 1.3](https://w3id.org/ro/crate/1.3),
[OpenAlex API documentation](https://help.openalex.org/api/), and
[Crossref REST API documentation](https://www.crossref.org/documentation/retrieve-metadata/rest-api/).
