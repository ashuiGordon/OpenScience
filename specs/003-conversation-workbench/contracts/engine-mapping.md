# Engine Mapping Contract: Conversation Research Workbench

**Contract ID**: `openscience-workbench-engine-map/1`

## Additive Boundary

This contract is additive to feature 001's CLI/domain contracts and feature 002's
`openscience-desktop-cli/1`. It changes presentation and intent routing only. It does not add a
shell, import Python, expose a local service, stream multiple JSON objects, parse human output,
change provider contracts, or make conversation files research authority.

## Identity Binding

Every workbench intent carries:

```text
ConversationID + ResearchTurnID + optional AttemptBindingID
```

Engine operations add their existing exact identities:

```text
request_id + plan_id + plan_sha256 + attempt_id + optional run_id/run_directory
```

Results are applied only when all known workbench and engine identities match the current binding.
Late results from a stale plan, different conversation/turn, expired attempt, or replaced run are
discarded from mutation and surfaced as a safe diagnostic. Switching visible conversations does not
retarget an in-flight engine operation.

## Intent Matrix

| Workbench intent | Existing engine/coordinator operation | Authority/result mapping |
|------------------|---------------------------------------|--------------------------|
| `sendMessage` | Validate `ResearchDraft`; `openscience plan … --json` | Persist one user message first; bind exact returned request/plan/file identity; no provider call |
| `editAdvancedSettings` | Local draft mutation | Expire any affected reviewed plan/grant; no engine mutation |
| `rejectPlan` | Existing pending-plan rejection | Timeline marks rejected projection; no provider/model invocation |
| `approvePlan` | Existing reviewed-plan coordinator | If network risk exists, route to exact ephemeral network card; otherwise build run invocation |
| `allowNetworkOnce` | Existing `OneTimeNetworkGrant` | Bind to attempt/plan/provider risk/limits; add `--allow-network` only to exact run/resume |
| `startRun` | Existing unique attempt workspace + `openscience run … --yes --json` | Run card binds after exact one-child discovery; stdout remains terminal-only |
| `cancel` | Existing pre-discovery termination or `openscience cancel <exact-run> --json` | Card shows request vs recorded terminal cancellation truthfully |
| `resume` | Existing validate/inspect/review/reacquire + `openscience resume … --yes --json` | New attempt binding in same turn/run; completed steps retained |
| `validate` | `openscience validate <run> --json` | Updates fresh validation presentation only; no provider/secrets |
| `inspect` | `openscience inspect <run> --json` | Produces bounded read-only context/evidence/artifact projections |
| `replay` | `openscience replay <run> --json` | Read-only recovery/summary projection; no provider/secrets |
| `export` | Fresh validate then `openscience export … --json` | Artifact/result card gets path/size only after existing reconciliation |
| `listProviders` | `openscience providers --json` | Sidebar/settings local descriptors; no network/grants/secrets |

No UI intent may synthesize a CLI path, provider secret, grant, or run target from free-form message
text.

## Plan Mapping

1. `sendMessage` snapshots the exact current non-secret draft under the new research turn.
2. Existing `CLICommand.plan` writes the private plan file and returns typed request/plan values.
3. The workbench coordinator verifies returned/file identity using existing checks.
4. The timeline projector creates one `planReview` item keyed by `turn_id + plan_id + sha256`.
5. Displayed step order/title/purpose/dependencies/completion/capability/risk come from the decoded
   plan/context, not a workbench-authored plan.
6. Editing question/scope/constraints/assumptions/providers/roots/synthesis/limits/timeout expires
   approval and grant. UI-only title/layout edits do not.
7. Approval is held in memory by exact binding and is not written to the conversation envelope.

## Network Mapping

The network card is required when any selected capability/provider has existing `network_read` risk
or a network synthesis provider is selected.

The card content maps from the reviewed plan/provider descriptors and current draft:

- provider name/version/kind/risk;
- destination/API category;
- possible outbound question/source metadata/evidence categories;
- maximum requests and timeout;
- model endpoint origin/model identity where existing reviewed configuration permits;
- local-evidence-to-network-model privacy block.

`Allow for This Run` creates the existing ephemeral grant only after exact binding checks. It never
stores `allow_network`, a remembered provider permission, or a default. Decline/dismiss/relaunch/
plan change/risk change/limit change consumes or invalidates it and creates zero network request.

## Run and Event Mapping

### Before run discovery

- Card identity is the local attempt binding, not a fabricated run ID.
- Display is `Preparing run workspace` or safe launch error.
- Cancellation may terminate the exact child but cannot claim persisted `cancelled`.

### After exact discovery

- Require one contained `run-*` immediate child in the unique task workspace.
- Bind exact run ID/directory/request/plan identity; update only the originating conversation turn.
- Tail only `<exact-run>/events.jsonl` through the existing bounded `EventLogCursor`.

### Event-to-card mapping

| Event family | Run card effect | May establish terminal/action authority? |
|--------------|-----------------|------------------------------------------|
| `run.created`, `run.resumed`, `run.started` | Bind/show created/resumed/running after identity checks | No terminal authority |
| `run.awaiting_approval` | Show recorded awaiting state; require current human review | Cannot approve itself |
| `step.started` | Exact plan step → running; safe capability activity | No |
| `step.completed` | Exact plan step → completed; update recorded counts | No terminal authority |
| `step.failed`, `step.cancelled` | Exact step error/cancel presentation | Await run terminal/reconciliation |
| `run.finalizing` | Show validating/finalizing | No |
| terminal candidate events | Show provisional terminal state | Only after process/manifest/validate reconciliation |
| `run.interrupted` | Show interrupted/resume candidate | Resume only after fresh validation |
| unknown compatible event | Generic bounded activity | Never |

Partial/incomplete event lines are not mapped. Duplicate/gap/replacement/run-ID mismatch stops
trusted progress and produces an integrity issue. UI logs and terminal stdout never become progress.

## Terminal Reconciliation to Timeline

The existing feature-002 algorithm remains exact:

1. drain bounded pipes and process termination;
2. decode one terminal JSON object and exit mapping;
3. require exact run ID/directory match;
4. drain complete events;
5. run credential-free/network-free validation;
6. inspect canonical run detail as needed;
7. compare terminal JSON, execution/manifest status, and terminal event;
8. publish completed/partial/failed/cancelled only if compatible, otherwise integrity warning.

Mapping results:

| Reconciled outcome | Timeline | Preview/actions |
|--------------------|----------|-----------------|
| completed | `researchResult` + final run card | context/plan/evidence/artifacts; validate/replay/export |
| partial | visibly partial result + limitations/errors | inspect; resume/export only if existing eligibility permits |
| failed | safe error/recovery card | settings/retry/resume only if validated eligible |
| cancelled | recorded cancelled card | inspect/resume only if eligible |
| interrupted | recovery card | fresh resume review |
| integrity mismatch | high-severity read-only invalid card | no mutation or valid export |
| pre-run bridge failure | safe failure beneath user turn | no run binding/history fabrication |

The assistant/result card may excerpt only validated report/claims. It cannot convert terminal
machine fields or raw logs into new scientific prose.

## Preview Mapping

### Context

Sources are `ResearchDraft` user fields, reviewed model/provider configuration, validated run
summary, manifest hashes/timestamps, and safe UI metadata. Each field carries a provenance class.

### Plan

Source is exact reviewed plan/recorded plan plus projected event state. The projector joins by exact
step ID. Unknown/missing step IDs are integrity issues, not new steps.

### Evidence

Source is existing `RunDetail` exact ID maps:

```text
claim.evidence_ids[] -> EvidenceRecord.evidence_id -> SourceRecord.source_id
```

Missing/duplicate joins, unsafe URLs, contradictory/unclear stance, and retracted/corrected/
withdrawn status retain existing warnings. Activating a citation passes IDs, not passage text.

### Artifacts

Source is manifest/inspect artifact identity resolved via existing repository confinement and size
limits. Before preview, recheck regular file/root containment/identity/size. Preview bytes do not
enter the conversation store. Export remains a separate engine action after fresh validation.

## Resume Mapping

- Resume action is derived only from fresh feature-002 eligibility, never persisted `status_hint`.
- Show immutable plan, completed prefix, remaining work, status/errors/limitations, provider
  identities, exact local roots to reselect, missing credential presence, model config fingerprint,
  and network requirement.
- Reacquire fixture/provider compatibility, exact roots, selected Keychain credentials, and a new
  network grant. None is read from conversation/run artifact as a secret/permission.
- Append a new `RunBinding` attempt ordinal to the same research turn and keep the same engine run
  directory. Existing completed steps remain projected from recorded state and are not re-emitted as
  newly completed.

## Existing Safety Invariants

The workbench MUST NOT change these feature-002 invariants:

1. packaged helper resolution before development override; no PATH/shell lookup;
2. one bounded process and one mutating execution;
3. minimal environment and selected-only Keychain values;
4. no secret in argv/config/log/events/artifacts/conversations/export;
5. terminal stdout exactly one JSON object; event file is sole progress input;
6. exact unique workspace/run discovery and root containment;
7. no network without current exact grant;
8. local evidence cannot be sent to a network model under the existing privacy policy;
9. validate/inspect/cancel/replay/export/provider listing receive no credentials/network grant;
10. partial/failure/integrity mismatch remains transparent and never fabricated success.

## Coordinator Error Taxonomy

| Code | Meaning | Timeline outcome |
|------|---------|------------------|
| `workbench.binding_stale` | Result belongs to expired turn/plan/attempt | Safe stale-operation notice; no mutation |
| `workbench.active_elsewhere` | Another conversation owns active mutation | Link to active conversation/run; keep draft/plan |
| `workbench.plan_changed` | Reviewed inputs no longer match | Plan card requires regeneration/review |
| `workbench.selection_invalid` | Preview IDs absent/mismatched | Specific empty/integrity preview; no fallback record |
| `conversation.*` | Session persistence issue | Session issue, distinct from engine error |
| Existing `engine.*`, `workspace.*`, `terminal.*`, `validation.*` | Feature-002 typed error | Preserve original category/context/action rules |

## Required Contract Tests

1. Exact conversation/turn/attempt/plan/run binding rejects stale and cross-conversation results.
2. Send appends once and runs plan only; reject/edit/decline generates zero provider requests.
3. Grant binding/consumption/non-persistence and exact `--allow-network` behavior remain green.
4. One-active-run routing prevents a second run while leaving other conversations readable.
5. Every known/unknown/malformed event maps to its allowed projection and no extra authority.
6. Every reconciled terminal state produces the exact card/action matrix above.
7. Citation/artifact selection resolves exact IDs and rejects missing/duplicate/escaped/replaced data.
8. Resume appends a new attempt while preserving exact run and completed steps, with all authority
   reacquired.
9. Existing feature-002 security/bridge/repository/regression suites pass unchanged.
10. Independent secret/evidence/report canaries are absent from conversation/projected diagnostics
    and all existing forbidden surfaces.
