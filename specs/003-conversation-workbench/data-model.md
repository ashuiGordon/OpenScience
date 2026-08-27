# Data Model: Conversation Research Workbench

## Authority and Persistence Classes

Every field belongs to one of four classes. A type may combine them only through explicit typed
references.

| Class | Authority | Persisted in conversation store? | Examples |
|-------|-----------|----------------------------------|----------|
| User-authored session data | Conversation envelope | Yes, after validation/redaction | message text, title, archive state, unsent non-secret draft |
| Engine research data | Validated managed run artifacts | Reference only | plan, events, evidence passage, report, manifest, artifact hash |
| Derived presentation | Pure projector | No; safe hint may be cached but never trusted | timeline card, relative date group, progress fraction, result excerpt |
| Ephemeral authority/secret | Existing runtime/Keychain/in-memory grant | Never | credential value, network grant, plan approval, child environment, active PID |

## Identifier Rules

- `ConversationID`: `conversation-` plus lowercase UUID.
- `ResearchTurnID`: `turn-` plus lowercase UUID, unique within all envelopes.
- `UserMessageID`: `message-` plus lowercase UUID.
- `AttemptBindingID`: `attempt-` plus lowercase UUID; it is not an engine run ID.
- Engine request, plan, run, event, claim, evidence, source, and artifact IDs retain their existing
  exact values and are never rewritten as conversation IDs.
- IDs are non-empty, normalized at creation, immutable, and compared exactly. Duplicate persisted
  IDs invalidate the containing envelope.

## Entity: ResearchWorkspace

Presentation scope for the sidebar. First release has exactly one local workspace.

| Field | Type | Rules |
|-------|------|-------|
| `workspace_id` | string | Constant local workspace ID for v1 |
| `display_name` | string | 1–80 Unicode grapheme clusters; default `OpenScience` |
| `conversation_root` | URL | Resolved internally under Application Support; never accepted from JSON |
| `projects` | ordered array of ResearchProject | Maximum 64; project metadata only |
| `selected_project_id` | ResearchProjectID? | Must reference an active project; otherwise first active/default project |
| `selected_conversation_id` | ConversationID? | May point only to a readable non-archived envelope; otherwise cleared |
| `selected_preview_tab` | PreviewTab | Safe persisted preference; defaults to `context` |
| `sidebar_visibility` | enum | `shown` or `collapsed` |
| `preview_visibility` | enum | `shown` or `collapsed` |
| `sidebar_width` | finite number | Clamped to 220–340 points before use/persistence |
| `preview_width` | finite number | Clamped to 360–560 points before use/persistence |
| `schema_version` | integer | Exact supported layout schema version |

`ResearchWorkspace` expands no filesystem authority. Invalid layout values reset independently to
safe defaults and do not invalidate projects/conversations.

## Entity: ResearchProject

Local organizational scope matching the project selector in the selected mock.

| Field | Type | Rules |
|-------|------|-------|
| `project_id` | `project-` plus lowercase UUID | Immutable and unique |
| `title` | string | 1–80 grapheme clusters; user-authored |
| `created_at` | RFC 3339 timestamp | Immutable local metadata |
| `updated_at` | RFC 3339 timestamp | Monotonic on project metadata or child conversation mutation |
| `archived_at` | RFC 3339 timestamp? | Archived projects are excluded from the normal selector |

Projects own conversation organization only. They do not own/delete engine runs, add filesystem
roots, store provider/model settings, or create network authority. Archiving a project archives its
navigation scope but does not rewrite child conversations or runs. Destructive metadata deletion
requires explicit confirmation and leaves all referenced engine runs/exports untouched.

## Entity: ConversationEnvelope

One bounded crash-isolated file per conversation.

| Field | Type | Rules |
|-------|------|-------|
| `schema_version` | integer | v1 is `1`; newer unsupported versions are read-only diagnostics |
| `conversation` | Conversation | Required and exact ID must match filename |
| `turns` | ordered array of ResearchTurn | Maximum 1,000 in v1; unique IDs; chronological stable order |
| `draft` | ConversationDraft? | Non-secret only; roots/fixtures stored as display/reselection references, never durable authority |
| `bindings` | array of RunBinding | Unique attempt binding IDs; managed reference only |
| `revision` | nonnegative integer | Increments on every successful atomic mutation |
| `written_at` | RFC 3339 timestamp | Store clock; not research provenance |

Maximum decoded envelope size is 8 MiB. Unknown compatible fields are ignored on read and not
allowed to create authority. The store does not persist projected evidence/report text.

## Entity: Conversation

| Field | Type | Rules |
|-------|------|-------|
| `conversation_id` | ConversationID | Immutable |
| `project_id` | ResearchProjectID | Must reference an active or archived workspace project |
| `title` | string | 1–160 grapheme clusters; user rename or bounded first-question derivative |
| `created_at` | RFC 3339 timestamp | Immutable local session metadata |
| `updated_at` | RFC 3339 timestamp | Monotonic per envelope; updated on user/session mutation |
| `archived_at` | RFC 3339 timestamp? | `nil` when active; archive never mutates engine runs |
| `status_hint` | SafeStatusHint | Rebuildable only; cannot grant actions or claim terminal validity |

### SafeStatusHint

`draft`, `planning`, `awaiting_approval`, `running`, `completed`, `partial`, `failed`, `cancelled`,
`interrupted`, `invalid`, or `unknown`. On relaunch, `planning`, `awaiting_approval`, and `running`
become `unknown` until runtime/repository reconciliation; persisted hints never establish authority.

### Conversation state transitions

```text
active ──archive──▶ archived ──restore──▶ active
  │                                      │
  └────explicit confirmed delete────────┘──▶ metadata removed
```

Delete removes only the envelope/index entry. It never recursively deletes engine run directories
or exports.

## Entity: ConversationDraft

| Field | Type | Rules |
|-------|------|-------|
| `text` | string | 0–10,000 characters; trimmed/validated only on send |
| `scope` | string | Existing feature-002 bound |
| `constraints` | array of string | Existing feature-002 validation |
| `assumptions` | array of string | Existing feature-002 validation |
| `source_names` | array of string | Provider names only, no descriptors or credentials |
| `synthesis_name` | string | Provider name only |
| `local_root_hints` | array of ReselectionHint | Bookmark-free display identity; exact root must be reselected if authority is needed after relaunch |
| `fixture_hints` | array of ReselectionHint | Test/development only; never treated as current file authority after relaunch |
| `max_records` | integer | Existing feature-002 range |
| `max_network_requests` | integer | Existing feature-002 range |
| `timeout_seconds` | integer | Existing feature-002 range |
| `contact_email` | string | Non-secret preference/draft value |
| `updated_at` | RFC 3339 timestamp | Session metadata |

`ReselectionHint` may contain only a last path component and redacted/display path. It never grants
read access, bypasses the native chooser, or becomes a CLI argument without fresh validation.

Forbidden keys/values include credential-like keys, secret values, grant/approval booleans,
environment maps, PID/process handles, raw stderr/stdout, and arbitrary evidence/report bodies.

## Entity: ResearchTurn

One user request and its governed research lifecycle.

| Field | Type | Rules |
|-------|------|-------|
| `turn_id` | ResearchTurnID | Immutable |
| `message` | UserMessage | Exactly one initial user request in v1 |
| `created_at` | RFC 3339 timestamp | Immutable |
| `plan_reference` | PlanReference? | Engine plan identity/file reference, never plan body |
| `attempt_binding_ids` | ordered array | May contain retry/resume attempts; no duplicate |
| `state_hint` | TurnStateHint | Rebuildable, never terminal authority |

### Turn state machine

```text
draft
  └─send──▶ planning
             ├─plan error────────────▶ failed_safe
             └─plan ready────────────▶ awaiting_plan_approval
                 ├─reject/edit───────▶ rejected_or_draft
                 └─approve───────────▶ awaiting_network? ──decline──▶ awaiting_plan_approval
                                            │ allow / not needed
                                            ▼
                                         running
                                            ├─cancel request──▶ stopping
                                            ├─interrupt───────▶ interrupted
                                            └─reconcile───────▶ completed | partial | failed | cancelled | invalid
```

Only current in-memory coordinator state and validated engine records establish states after
`planning`. On relaunch, transient approval states are re-reviewed.

## Entity: UserMessage

| Field | Type | Rules |
|-------|------|-------|
| `message_id` | UserMessageID | Immutable |
| `text` | string | 1–10,000 characters after trim; user-authored provenance |
| `created_at` | RFC 3339 timestamp | Session time, not a source retrieval time |
| `attachment_hints` | array | Safe names/kinds only; local authority requires reselection |

Messages are not editable after a plan/run binding is created. A correction becomes a follow-up
turn, preserving the audit trail. A pre-plan message may be explicitly withdrawn only if no engine
invocation occurred; the store retains a tombstone rather than renumbering later turns.

## Entity: PlanReference

| Field | Type | Rules |
|-------|------|-------|
| `request_id` | existing engine ID | Exact, non-empty |
| `plan_id` | existing engine ID | Exact, non-empty |
| `plan_sha256` | lowercase SHA-256 | Exact reviewed plan fingerprint |
| `attempt_private_path_hint` | string? | Safe diagnostic reference; must be re-contained/reopened by existing coordinator |

No `approved` field is permitted. Approval is a transient binding to the exact IDs/hash and current
draft/risk/limits.

## Entity: RunBinding

| Field | Type | Rules |
|-------|------|-------|
| `binding_id` | AttemptBindingID | Immutable UI identity |
| `turn_id` | ResearchTurnID | Must exist in same envelope |
| `attempt_ordinal` | positive integer | Strictly increasing within turn |
| `run_id` | existing engine run ID? | `nil` before unique discovery; exact thereafter |
| `managed_relative_reference` | string? | Path relative to configured managed run root; no absolute authority from JSON |
| `request_id` | existing engine ID | Must match turn plan/reference when known |
| `plan_id` | existing engine ID | Must match reviewed plan when known |
| `plan_sha256` | SHA-256 | Binding/fresh validation input |
| `last_validated_fingerprint` | SafeArtifactFingerprint? | Rebuild hint only; mutation/export requires fresh validation |
| `status_hint` | SafeStatusHint | Presentation hint only |
| `created_at` | RFC 3339 timestamp | Attempt session time |

Resolution joins `managed_relative_reference` to the internally configured run root, refuses root
escape/symlink/replacement, and requires run ID plus request/plan identity consistency. Conversation
data cannot add a run outside the feature-002 repository authority.

## Entity: TimelineItem *(derived, never persisted as scientific truth)*

| Field | Type | Rules |
|-------|------|-------|
| `timeline_id` | stable derived ID | Composed from turn/binding/event/record identity; no array-index identity |
| `kind` | TimelineKind | Closed taxonomy below; unknown engine events map only to generic activity |
| `timestamp` | timestamp | User/store time or exact engine/artifact time with provenance label |
| `provenance` | ProvenanceClass | `user`, `engine_record`, `validated_artifact`, or `ui_projection` |
| `status` | DisplayStatus | Textual state plus severity; color is supplemental |
| `selection_target` | PreviewSelection? | Exact typed target; no arbitrary path/URL |
| `actions` | set of WorkbenchAction | Derived from current validated eligibility only |

### TimelineKind

- `userMessage`
- `agentNotice`
- `planReview`
- `networkApproval`
- `runProgress`
- `researchResult`
- `safeError`
- `recovery`
- `artifactSummary`

### WorkbenchAction

`editDraft`, `rejectPlan`, `approvePlan`, `rejectNetwork`, `allowNetworkOnce`, `cancel`, `resume`,
`retry`, `validate`, `inspect`, `replay`, `export`, `openPreview`, `openSettings`, and `none`.
Action availability is recomputed; it is never decoded as authority from the conversation envelope.

## Entity: PreviewSelection

| Variant | Required identity | Resolution |
|---------|-------------------|------------|
| `context` | conversation/turn/binding ID | Safe user/config metadata plus validated run summary |
| `plan` | exact plan ID and binding | Existing reviewed/recorded plan, read-only |
| `evidence` | run + claim/evidence/source IDs | Exact `RunDetail` joins; missing link is integrity error |
| `artifact` | run + artifact ID | Manifest/root-contained artifact lookup, identity/size recheck |

The selected tab may persist. Record IDs may persist as safe references. Passage/report bytes,
temporary URLs, security tokens, open file handles, and validation authority do not persist.

## Entity: SessionIssue

| Field | Type | Rules |
|-------|------|-------|
| `code` | stable string | Examples: `conversation.schema_newer`, `conversation.corrupt`, `conversation.root_escape`, `run.reference_invalid` |
| `outcome` | bounded string | What was not loaded/started/validated |
| `safe_detail` | bounded redacted string | Maximum 8 KiB; no retrieved passage by default |
| `recovery` | typed actions | Ignore/isolate, rebuild index, reselect root, open settings, or none |

## Persistence Files

```text
<Application Support>/OpenScience/Conversations/
├── workspace-v1.json
├── index-v1.json                     # rebuildable; no authority expansion
└── conversations/
    └── conversation-<uuid>.json      # ConversationEnvelope
```

All roots are internally constructed. Files must be regular, non-symlinked, owner-readable/writable,
bounded, strict UTF-8, and valid JSON. Temporary names contain random UUIDs in the same directory.
The store rejects unexpected hard-link/identity changes where the platform check is available.

## Validation Invariants

1. Envelope filename, `conversation_id`, turn IDs, and references agree and are unique.
2. `revision` never decreases within one loaded store lifetime.
3. Conversation/turn ordering is stable; timestamps do not establish research truth.
4. Every binding refers to a turn in the same envelope; every plan identity matches the turn.
5. No persisted field grants network, plan approval, filesystem access, credential use, or process
   ownership.
6. No persisted content duplicates evidence passages, source bodies, reports, manifests, or event
   payload streams.
7. Rebuild resolves only through the existing managed run repository and never follows a session
   path outside its configured root.
8. Current actions/states are recomputed from runtime and fresh validation, never from `status_hint`.
9. Failed writes leave the last complete envelope readable; a corrupt envelope does not poison the
   index or unrelated envelopes.
10. Redaction/secret-canary tests run over every written conversation/layout/index byte.
