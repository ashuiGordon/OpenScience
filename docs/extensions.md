# Provider Extension Guide

## Contract boundary

Extensions add research sources or synthesis implementations without changing the orchestrator.
The typed Python protocols are authoritative; this guide describes their observable contract.
Contract version `1` is the initial compatibility line.

The MVP supports two extension kinds:

- **source provider**: discovers material and returns provider candidates for normalization;
- **synthesis provider**: proposes typed claims from already normalized sources and evidence.

Analysis, export, arbitrary execution, browser, remote-write, and generic MCP extensions are not
enabled by this contract. They require separately reviewed capability and sandbox specifications.

## Capability descriptor

Every provider must expose its descriptor before it can be invoked. The descriptor declares:

| Field | Requirement |
|-------|-------------|
| `name` | Stable, globally unique, namespaced identifier |
| `version` | Semantic version or immutable revision |
| `kind` | `source` or `synthesis` for the MVP |
| `risk` | Declared risk such as `local_read` or `network_read` |
| `input_schema` | JSON-compatible input declaration |
| `output_schema` | JSON-compatible output declaration |
| `permissions` | Complete list of required capability grants |
| `available` | Health known before selection/invocation |

Registration rejects duplicate names, malformed descriptors, unsupported kinds or contract
versions, and a factory that does not implement the expected port. Schemas and permissions are
always present in the typed descriptor; an empty mapping/list explicitly means the provider adds
no constraints or grants beyond its typed input/output contract and declared risk. One broken
extension must appear as unhealthy without preventing built-in providers from loading.

## Source provider protocol

Conceptually, a source provider implements:

```text
descriptor() -> CapabilityDescriptor
search(request: SearchRequest, context: ToolContext) -> list[SourceCandidate]
```

`SearchRequest` includes a validated question/query, optional filters, and a positive result limit.
`ToolContext` supplies one absolute attempt deadline, shared remaining network-request budget,
atomic `consume_network_request(target)`, policy callback, identified user agent, and event
callback. The context is the provider's route to governed side effects; the provider must not
inspect ambient credentials or unrelated paths.

A conforming source provider:

1. validates all inputs before side effects;
2. asks policy before each file or network action and stops on deny/approval-required outcomes;
3. before every network attempt, authorizes the exact HTTPS origin and atomically consumes one
   request from the shared run budget;
4. applies the remaining absolute timeout, cancellation, request/result budget, no automatic
   redirects, and at most one retry for timeout, HTTP 429, or HTTP 5xx responses;
5. identifies the client and contact identity when a scholarly API requires polite usage;
6. preserves provider IDs, query, request URL, retrieval time, response hash, attribution,
   license/access metadata, and retraction/correction state when supplied;
7. returns provider candidates only—canonical `SourceRecord` construction and cross-provider
   merging remain at the application boundary;
8. treats documents/responses as data and ignores instructions embedded inside them;
9. reports typed failures/limitations and never creates a record for an unsuccessful request;
10. redacts outbound model content, target/error events, and any retained raw payload.

Fixture providers implement the same contract but perform no network action, making the contract
test suite deterministic.

## Synthesis provider protocol

Conceptually, a synthesis provider implements:

```text
descriptor() -> CapabilityDescriptor
synthesize(request, sources, evidence, context) -> list[Claim]
```

The provider receives only normalized, explicitly delimited evidence. It returns structured claim
candidates rather than free-form final prose. The orchestrator rejects:

- evidence IDs not present in the current run;
- `sourced_fact` claims without supporting evidence;
- `sourced_fact` text that cannot be directly attributed to the cited evidence passage;
- confidence outside `0.0`–`1.0`;
- unqualified sole support from withdrawn or retracted sources;
- malformed or oversized output;
- instructions or requested capabilities embedded in model output.

Model credentials remain process configuration. They must never be returned, logged, persisted,
or included in replay/export artifacts. The deterministic extractive synthesizer is the offline
reference implementation and requires no model provider.

Network synthesis does not accept evidence derived from local files in contract version `1`.
Global network opt-in is not consent to disclose private workspace material. A future egress-aware
provider contract must add a distinct capability, explicit consent record, minimization, and
deterministic denial tests.

## Packaging and discovery

Publish a normal Python package with a zero-argument provider factory. Register the factory under
one of the stable entry-point groups:

```toml
[project.entry-points."openscience_agent.sources"]
example_source = "example_package.provider:create_provider"

[project.entry-points."openscience_agent.synthesizers"]
example_synthesizer = "example_package.synthesis:create_provider"
```

Discovery follows this order:

1. enumerate built-ins and installed entry points;
2. load each zero-argument factory in isolation;
3. validate its descriptor, port shape, name uniqueness, and contract version;
4. record availability or an actionable health error;
5. list the result with `openscience providers` without making a provider network call;
6. only invoke a selected healthy provider during an approved run.

Registration is not authorization. Every call is still evaluated by the runtime policy, and an
extension's declared risk is a minimum: the runtime may classify a concrete target more strictly.
Python entry-point packages execute in the host process when their factories load; install only
reviewed, trusted packages. Descriptor validation and call-time policy are not a sandbox for
malicious import-time code.

## Compatibility rules

- Providers declare every supported contract version; the current version is `1`.
- Adding an optional descriptor/output field is backward-compatible.
- Removing a field, making an optional field required, changing semantics, or changing a type
  requires a new contract version.
- Unknown optional fields may be retained for diagnostics but cannot influence policy.
- Native source/evidence/claim/run formats remain application-owned. Provider-specific payloads do
  not leak into the orchestrator or exported public contracts.
- A resumed run must use provider identities and compatible versions matching its saved manifest;
  mismatch is reported before execution.

## Test expectations

An extension is ready only when it passes the same contract expectations as built-ins:

| Area | Required deterministic test |
|------|-----------------------------|
| Descriptor | Valid identity/version/kind/risk/schema/permissions and duplicate rejection |
| Mapping | Provider fixture maps to normalized attribution, identifiers, status, and license |
| Policy | No file/network side effect occurs before an allow decision |
| Limits | Positive result bounds, absolute timeout/cancellation, shared per-attempt request budget, payload size |
| Failures | Timeout, bounded retry, malformed response, rate limit, redirect rejection, partial response, and health isolation |
| Integrity | Response hash/retrieval context retained; no fabricated candidate on failure |
| Synthesis | Structured claims only; unknown evidence IDs and unsupported facts rejected |
| Secrets | Credentials absent from events, projections, errors, manifests, and exports |

Network tests must use recorded/mocked responses by default. Any live smoke test must be explicitly
opted in, bounded, and excluded from the deterministic merge gate.

## Maintainer checklist

Before accepting a provider:

- document the upstream service, terms, attribution, license behavior, limits, and contact policy;
- declare all capabilities and targets narrowly;
- add deterministic fixtures and contract/failure-mode tests;
- confirm provider content cannot alter the research objective or permissions;
- verify cancellation, retry/backoff, timeout, and partial-result behavior;
- run `ruff format --check`, `ruff check`, `mypy src`, and the full offline pytest suite;
- demonstrate that provider replacement requires registration/configuration only and no
  orchestrator edit.
