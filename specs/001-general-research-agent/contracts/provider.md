# Provider Extension Contract

## Purpose

Providers add scholarly sources or synthesis implementations without changing the orchestrator.
The Python protocol is authoritative; this document specifies observable behavior.

## Source provider

A source provider exposes:

```text
descriptor() -> CapabilityDescriptor
search(request: SearchRequest, context: ToolContext) -> list[SourceCandidate]
```

`SearchRequest` includes the question/query, optional filters, and a positive result limit.
`ToolContext` includes one absolute attempt deadline, the shared network-request budget and atomic
`consume_network_request(target)` callback, policy callback, user-agent, and an event callback.
Providers MUST NOT persist secrets or access undeclared paths/network targets.

### Required behavior

1. Descriptor name is unique and stable; version and risk are declared before invocation.
2. Inputs are validated before side effects.
3. Before every network attempt (including a retry), the provider validates cancellation and the
   absolute deadline, requests policy authorization for the exact HTTPS origin, and atomically
   consumes one request from the shared run budget.
4. Network providers use a finite remaining timeout, identify this client, and disable automatic
   redirects so credentials cannot cross origins. Only timeouts, HTTP 429, and HTTP 5xx may be
   retried, at most once, with bounded backoff; each attempt consumes budget.
5. Outbound model inputs, target/event data, errors, and retained payloads are redacted before they
   leave their trust boundary. API keys and sensitive endpoint paths never appear in descriptors.
6. Results preserve provider IDs, landing URL, attribution, license/access metadata when supplied,
   status/retraction data when supplied, retrieval time, query, and response hash.
7. Provider-specific payloads are normalized at the adapter boundary. Raw payloads are optional and
   MUST be size-limited and redacted if retained.
8. Partial provider failure is returned as a typed error/limitation and MUST NOT create fabricated
   records.
9. A deterministic fixture implementation MUST pass the same provider contract tests. Because it
   operates only on supplied in-memory records, it requires no per-record side-effect authorization.

## Synthesis provider

A synthesis provider exposes:

```text
descriptor() -> CapabilityDescriptor
synthesize(request, sources, evidence, context) -> list[Claim]
```

It receives only normalized, explicitly delimited evidence data. Returned claims MUST conform to
the Claim model. The orchestrator rejects unknown evidence IDs, missing support for sourced facts,
invalid confidence values, and unqualified sole reliance on withdrawn/retracted sources. A model
claim labeled `sourced_fact` whose text cannot be directly attributed to its cited passage is
downgraded to a limited `inference` or rejected by core validation.

The first-release network model adapter MUST reject evidence derived from `local-files`, a
`local-document` source, or a `file:` source before transport. A future opt-in private-data-egress
feature requires its own capability, consent record, minimization rules, and tests; `--allow-network`
alone is not that consent.

## Extension discovery

The package checks Python entry points:

```text
openscience_agent.sources
openscience_agent.synthesizers
```

An entry point loads a zero-argument factory. Registration validates the descriptor before making
the provider available. Loading errors isolate that extension and appear in the provider health
list; they do not prevent built-in providers from running.

## Compatibility

- Contract version begins at `1`.
- Additive optional fields are backward-compatible.
- Removing or redefining fields requires a new contract version.
- Providers declare supported contract versions; incompatible providers are rejected before use.
