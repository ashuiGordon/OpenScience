# OpenScience Architecture

## Purpose and design constraints

OpenScience turns a scoped research question into a reviewable plan, normalized sources, exact
evidence records, classified claims, a cited report, and an auditable run manifest. It is built as
an original provider-neutral kernel with a native macOS client. Scientific integrity, provenance,
policy, and replay remain owned by the kernel and testable independently of any model vendor or
user interface.

> **Current desktop boundary:** the macOS client is a development/direct-distribution build. It is
> not App Sandbox enabled, Developer ID signed, notarized, or ready for Mac App Store distribution.

The first-release runtime targets macOS and Linux. Safe local ingestion relies on POSIX
descriptor-relative, no-follow file opening; a Windows adapter is deferred until it can preserve
the same race-resistant approved-root invariant.

The architectural constraints are deliberate:

- Python 3.11+ and no third-party runtime dependencies;
- a SwiftUI client targeting macOS 14+ without a cloud backend or third-party UI runtime;
- a typed child-process/JSON bridge instead of duplicating orchestration in Swift;
- useful offline behavior with deterministic fixtures and extractive synthesis;
- no required model API or database;
- network access denied unless the user explicitly enables it;
- untrusted provider, document, and model content never changes policy or the objective;
- every externally verifiable claim either links to evidence or carries an explicit non-evidence
  classification;
- state-changing activity is persisted before the application reports completion.

## Layers and dependency direction

```text
┌──────────────────────────────────────────────────────────────────┐
│ Native macOS client                                             │
│ SwiftUI views, Keychain references, typed Process/JSON bridge,   │
│ read-only history/progress projections                           │
└──────────────────────────────┬───────────────────────────────────┘
                               │ openscience command + terminal JSON
┌──────────────────────────────▼───────────────────────────────────┐
│ CLI adapter / Python API                                        │
│ Parse input, collect approval, select adapters                   │
└──────────────────────────────┬───────────────────────────────────┘
                               │ application commands
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
Provider replacement therefore changes registration/configuration rather than the kernel. The
Swift client depends on the public CLI and persisted-record contracts, not Python implementation
modules.

## Core responsibilities

| Component | Owns | Must not own |
|-----------|------|--------------|
| macOS client | Native presentation, bounded process supervision, Keychain references, per-attempt workspaces, read-only history and progress views | Research orchestration, claim generation, record repair, or secret persistence outside Keychain |
| Typed CLI bridge | Argument-array construction, minimal child environment, bounded stdout/stderr, terminal JSON decoding, single active mutation | Shell evaluation, implicit network approval, interpreting report text as commands |
| Domain | Valid entities, transitions, canonical serialization, stable/content IDs | Filesystem, network, process state |
| Orchestrator | Finite plan execution, dependencies, limits, checkpoints, partial/failure semantics | Vendor payload schemas or secret storage |
| Policy | Capability risk, target normalization, approval outcomes, path/network boundaries | Executing the requested action |
| Provider registry | Built-ins, entry-point discovery, descriptor compatibility and health | Research workflow decisions |
| Source adapters | Retrieval and provider-to-domain normalization | Claims or report prose |
| Synthesis adapters | Candidate claims referencing known evidence IDs | Trusting or persisting unvalidated model output |
| Repository/artifact store | Append-only events, atomic projections, addressed bytes | Reinterpreting scientific meaning |
| Validator | Event chain, hashes, claim/evidence links, manifest and artifact invariants | Repairing failures silently |
| Renderer/exporter | Citation-preserving report and portable research object | Inventing evidence or credentials |

## Desktop integration flow

```text
macOS SwiftUI form
        |
        v
CLICommandBuilder -- argument array + non-secret paths/options
        |                         Keychain
        |                            |
        |                    selected secrets only
        v                            v
OpenScienceCLIClient actor ---- minimal child environment
        |
        | Process, no shell
        v
openscience CLI ----> orchestrator/policy/providers
        |                         |
        | one terminal JSON       | atomic projections + hash-chained events
        v                         v
Swift result model <-------- app-managed run store
                                  |
                                  +-- event tail for progress
                                  +-- read-only history/report/evidence views
                                  +-- CLI validate/replay/export authority
```

The app creates a unique empty workspace for each new execution because the CLI reports its
generated run directory only in the terminal response. It discovers the single `run-*` directory
inside that workspace and reads complete `events.jsonl` records for progress. The event stream is
not treated as a command channel, and the one terminal stdout JSON object is not treated as a
progress stream.

One actor-isolated client owns the mutating `run` or `resume` process. A separate control client may
write the CLI's idempotent cancellation marker after the exact run directory is known. History and
report views read recorded files without rewriting them; validation, replay, resume, cancellation,
and export continue to cross the CLI boundary.

During development, the executable may come from an explicit setting or a standard package-manager
path. A self-contained app places the pinned helper at `Contents/Helpers/openscience`, which takes
resolution priority. The Swift layer passes credentials selected from Keychain only in a minimized
child environment and redacts matching values from bounded diagnostics.

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
| Desktop form and selected paths | Untrusted, attempt-scoped input | Native pickers, argument arrays, field bounds, exact path display; no shell interpolation |
| CLI helper selection | Bundled helper first; external path permitted for development | Executable-file check, fixed expected CLI contract, no assumption that a user Python environment is trusted |
| Keychain to child process | Denied unless the selected provider needs a credential | Provider-specific environment names, minimal inherited environment, no secret in argv/preferences/logs |
| Child stdout/stderr | Untrusted and size-bounded | Concurrent pipe draining, one terminal JSON decoder, safe error envelope, centralized redaction |
| Desktop reads of run records | Read-only presentation input | Treat engine artifacts as authority, ignore incomplete event lines, use CLI validation for integrity decisions |
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

The research workflow intentionally has no arbitrary process execution, shell/Python/R tool,
browser control, remote write/publication, wet-lab control, or generic MCP bridge. The desktop
client launches only the selected `openscience` helper through `Process` without a shell; this is an
application integration boundary, not a research execution capability.

The current direct-distribution client is unsandboxed. Native file selection limits what the UI
passes to one attempt, but it is not an operating-system sandbox or persistent authorization.
Security-scoped bookmarks, App Sandbox entitlements, hardened-runtime signing, notarization, and
App Store packaging require a separate distribution specification. Future research compute still
requires a separately specified isolated, non-root runtime with explicit mounts, resource limits,
network policy, immutable environment identities, and secret brokerage.

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
| Product surface | Python library/CLI plus a native macOS SwiftUI client | Cloud service, Electron, or a second UI-owned research workflow |
| Runtime | Python 3.11 standard-library engine plus Swift 5.10/macOS 14+ client | Required model SDK or third-party desktop runtime |
| Desktop bridge | Typed argument-array `Process`, terminal JSON, and read-only run projections | Shell commands, Python embedding, or UI reimplementation of the orchestrator |
| Desktop distribution | Self-contained helper and ad hoc local assembly | Current claims of App Sandbox, Developer ID signing, notarization, or App Store readiness |
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
