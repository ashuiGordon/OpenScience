# Data Model: General Research Agent

## Design conventions

- IDs are opaque, stable strings. Content-derived IDs use lowercase SHA-256 with a type prefix.
- Timestamps are UTC RFC 3339 strings.
- Persisted mappings use sorted keys and canonical UTF-8 JSON when hashed.
- Evidence text is immutable after creation. Corrections create a new record and relation.
- Provider payloads are never treated as trusted instructions.

## ResearchRequest

| Field | Type | Rules |
|-------|------|-------|
| request_id | string | Content-derived from every persisted request field; revalidated on load |
| question | string | 10–10,000 characters |
| scope | string or null | Optional user boundary |
| constraints | list[string] | Each non-empty; maximum 100 |
| assumptions | list[string] | Explicit user or agent assumptions |
| desired_output | string | Defaults to `research brief` |
| source_names | list[string] | Must resolve to registered providers |
| approved_local_roots | list[path] | Resolved roots only; not exported verbatim by default |
| limits | RunLimits | Positive bounded values |
| created_at | timestamp | UTC |

## RunLimits

| Field | Type | Default |
|-------|------|---------|
| max_steps | integer | 20 |
| max_records | integer | 50 |
| max_network_requests | integer | 10 |
| timeout_seconds | integer | 300 |

## ResearchPlan and PlanStep

`ResearchPlan` owns an ordered list of `PlanStep` values. Its `plan_id` is derived from the complete
persisted plan content and revalidated on load. Each step contains `step_id`, `title`, `purpose`,
`capability`, dependency IDs, a completion condition, and a status.

The approved plan is immutable input and its persisted step statuses remain `pending`; actual
attempt state lives in the separately hashed `execution.step_statuses` projection. Allowed
execution-state transitions are:

```text
pending -> running -> completed
                   -> partial
                   -> failed
pending/running -> cancelled
completed/partial/failed -> no transition (a resumed attempt creates events, not history edits)
```

## CapabilityDescriptor

| Field | Type | Rules |
|-------|------|-------|
| name | string | Globally unique, namespaced |
| version | string | Semantic version or immutable revision |
| kind | enum | source, synthesis, analysis, export |
| risk | enum | local_read, network_read, workspace_write, execute, consequential |
| input_schema | mapping | JSON-compatible declaration |
| output_schema | mapping | JSON-compatible declaration |
| permissions | list[string] | Explicit capability grants |
| available | boolean | Health known before use |

## SourceRecord

| Field | Type | Rules |
|-------|------|-------|
| source_id | string | Content-derived from canonical identity |
| canonical_id | string | DOI, PMID, arXiv, OpenAlex ID, URI, or content hash |
| identifiers | mapping[string,string] | Normalized lowercase keys |
| title | string | Required |
| authors | list[string] | Ordered as supplied |
| publication_date | string or null | ISO date/year when known |
| source_type | string | article, preprint, dataset, local-document, etc. |
| abstract_or_excerpt | string | Plain untrusted data; size limited |
| landing_url | URI or null | HTTPS preferred |
| license | string or null | `unknown` is explicit, never inferred from access |
| status | enum | active, corrected, retracted, withdrawn, unknown |
| providers | list[string] | One or more observations merged by canonical ID |
| retrievals | list[RetrievalRecord] | Query, provider, URL, time, response hash |
| content_hash | string | Hash of normalized evidence-bearing content |

## EvidenceRecord

| Field | Type | Rules |
|-------|------|-------|
| evidence_id | string | Content-derived and immutable |
| source_id | string | Existing SourceRecord |
| passage | string | Exact normalized passage; non-empty and bounded |
| locator | string | Section/page/sentence or metadata field |
| relevance | number | 0.0–1.0 |
| stance | enum | supports, contradicts, contextual, unclear |
| license | string or null | Inherited only when declared by source |
| content_hash | string | SHA-256 of passage |
| created_by_step | string | Completed plan step |

Passage extraction assigns `unclear` unless a separate, explicit analysis classifies the stance.
The first release renders provided `contradicts` records and their uncertainty but deliberately
does not claim general-purpose semantic contradiction detection.

## Claim and ClaimEvidenceLink

| Field | Type | Rules |
|-------|------|-------|
| claim_id | string | Stable within run |
| text | string | Non-empty |
| kind | enum | sourced_fact, inference, assumption, hypothesis, unsupported |
| evidence_ids | list[string] | Required for sourced_fact; existing IDs only |
| confidence | number or null | 0.0–1.0 if present |
| limitations | list[string] | Explicit caveats |
| created_by | string | Synthesizer identity/version |

Each link may additionally record whether evidence supports, contradicts, or contextualizes the
claim. A sourced fact with zero valid supporting links is a validation error. Retracted or withdrawn
sources require an explicit limitation and cannot be the sole unqualified support.

## PolicyDecision

| Field | Type | Rules |
|-------|------|-------|
| decision_id | string | Unique |
| capability | string | Registered capability |
| action | string | Specific requested operation |
| target | string | Redacted, normalized target |
| risk | enum | Matches descriptor or stricter |
| outcome | enum | allow, deny, approval_required |
| reason | string | Human-readable and persisted |
| decided_at | timestamp | UTC |

## RunEvent

Append-only event fields: `sequence`, `event_id`, `run_id`, `type`, `timestamp`, `step_id`, redacted
`payload`, `previous_hash`, and `event_hash`. The event hash covers every field except itself. The
first event uses 64 zeroes for `previous_hash`.

## Artifact

An artifact contains `artifact_id`, media type, logical name, SHA-256, byte size, object-store path,
producer step, input entity IDs, created time, and optional export path. Bytes are immutable and
addressed by hash.

## RunManifest

The manifest indexes the request, plan, events, provider/synthesizer identities, policy decisions,
source/evidence/claim projections, artifact hashes, software/runtime metadata, status, start/end
times, errors, and limitations. It is the replay authority and is validated against
`contracts/run-manifest.schema.json`.

`state` is a map of projection names (`request`, `plan`, `checkpoint`, and `execution`) to their
relative path, SHA-256, and record count where applicable. `execution` records the terminal/current
status, the valid completed-step prefix, per-step projected statuses, and consumed network requests.
Terminal manifests require every state projection and a report projection when reporting completed
work. Resume validates these hashes, domain identities, event-chain prefix, capability
name/version/contract identities, and the checkpoint prefix before contacting a provider.

Run states:

```text
created -> awaiting_approval -> running -> completed
                                      -> partial
                                      -> failed
                                      -> cancelled
running/partial/failed -> running (explicit resume attempt, event history retained)
```

## RO-Crate projection

- Research request, sources, evidence ledgers, reports, and manifests map to data entities.
- The OpenScience software and user-declared researcher map to contextual agents.
- Plan steps map to activities using source/evidence entities and generating artifacts.
- `ro-crate-metadata.json` uses the RO-Crate 1.3 context and links generated artifacts to inputs.
- Native OpenScience event and claim schemas remain embedded artifacts rather than pretending they
  are standardized RO-Crate terms.
