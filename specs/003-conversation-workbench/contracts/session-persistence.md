# Session Persistence Contract: Conversation Research Workbench

**Contract ID**: `openscience-conversation-store/1`

## Purpose

The conversation store persists local, non-scientific presentation state for the macOS workbench.
It does not replace or extend the authority of engine run artifacts, Keychain, filesystem grants,
or live process state.

## Root and File Layout

The implementation constructs, rather than decodes, the root:

```text
<Application Support>/OpenScience/Conversations/
├── workspace-v1.json
├── index-v1.json
└── conversations/
    └── conversation-<lowercase-uuid>.json
```

- The root and `conversations` directory are real contained directories, not symlinks.
- Conversation envelopes are regular owner-controlled files. Filename and embedded conversation ID
  must match exactly.
- Unknown entries are ignored and reported safely; they never expand scan authority.
- Index content is rebuildable from valid envelopes and cannot authorize a path or run.

## Envelope Schema v1

Canonical shape (field order is not significant):

```json
{
  "schema_version": 1,
  "revision": 7,
  "written_at": "2026-08-27T09:41:00Z",
  "conversation": {
    "conversation_id": "conversation-00000000-0000-0000-0000-000000000001",
    "project_id": "project-00000000-0000-0000-0000-000000000001",
    "title": "Reproduce ESM-1b leaderboard",
    "created_at": "2026-08-27T09:40:00Z",
    "updated_at": "2026-08-27T09:41:00Z",
    "archived_at": null,
    "status_hint": "awaiting_approval"
  },
  "turns": [],
  "draft": null,
  "bindings": []
}
```

Exact nested models and invariants are defined in [data-model.md](../data-model.md). Encoders may
write compatible optional fields only after the schema contract is amended and tested.

## Bounded Decode

| Input | v1 maximum |
|-------|------------|
| One envelope | 8 MiB |
| Workspace state | 256 KiB |
| Rebuildable index | 2 MiB |
| Conversations discovered per scan | 10,000 |
| Turns per conversation | 1,000 |
| User message/draft text | 10,000 characters each |
| Safe diagnostic persisted | none; diagnostics are derived at read time |

Decode requires strict UTF-8, one top-level JSON object, exact supported schema version, required
types, finite/clamped numbers, RFC 3339 timestamps, valid IDs, unique relationships, and complete
consumption. Oversize/trailing/malformed inputs are isolated rather than truncated into a valid
conversation.

## Mutation API

The store exposes typed actor-isolated operations conceptually equivalent to:

```text
list(includeArchived, query) -> [ConversationSummary]
listProjects(includeArchived) -> [ResearchProject]
createProject(title) -> ResearchProject
renameProject(projectID, title) -> ResearchProject
archiveProject(projectID) -> ResearchProject
restoreProject(projectID) -> ResearchProject
selectProject(projectID) -> void
load(conversationID) -> ConversationEnvelope
create(projectID, initialDraft?) -> ConversationEnvelope
rename(conversationID, expectedRevision, title) -> ConversationEnvelope
saveDraft(conversationID, expectedRevision, draft?) -> ConversationEnvelope
appendTurn(conversationID, expectedRevision, userMessage) -> ConversationEnvelope
bindPlan(conversationID, turnID, expectedRevision, planReference) -> ConversationEnvelope
bindAttempt(conversationID, turnID, expectedRevision, runBinding) -> ConversationEnvelope
updateSafeHint(conversationID, expectedRevision, hint) -> ConversationEnvelope
archive(conversationID, expectedRevision) -> ConversationEnvelope
restore(conversationID, expectedRevision) -> ConversationEnvelope
deleteMetadata(conversationID, expectedRevision) -> void
loadWorkspaceState() -> WorkbenchLayoutState
saveWorkspaceState(safeState) -> void
rebuildIndex() -> StoreScanReport
```

- Every mutation validates the complete prospective envelope before writing.
- `expectedRevision` mismatch returns a typed conflict; no last-writer-wins merge is invented.
- `appendTurn` is idempotent by `message_id` and never produces two messages from rapid duplicate
  submit. A conflicting duplicate ID is an error.
- `deleteMetadata` names its target exactly and never accepts a path. It does not call run/export
  deletion.
- Listing/search operates on safe envelope/index fields only and performs no provider/engine call.

## Crash-Safe Write Protocol

For every envelope/workspace/index mutation:

1. Resolve the internally constructed parent and verify it remains the expected contained directory.
2. Encode the complete next value to bounded in-memory data; scan forbidden fields/canaries.
3. Create an exclusive random same-directory temporary regular file with owner-only permissions.
4. Write all bytes, synchronize the file, and close it; partial write is an error.
5. Recheck destination/parent identity and refuse symlink/non-regular replacement.
6. Atomically replace/rename the destination in the same directory.
7. Synchronize the containing directory where supported.
8. Update in-memory/index state only after replacement succeeds.
9. On any pre-replacement error, remove only the exact temporary file; the previous destination
   remains authoritative.

Temporary cleanup scans only exact store-owned random-name patterns and never recursively deletes a
broad directory. Test seams inject failures before/after write, sync, replace, and index update.

## Sensitive and Authoritative Data Denylist

Conversation/workspace/index bytes MUST NOT contain:

- provider/model credential values or a general environment dictionary;
- network grants, plan approvals, destructive confirmations, or `allow_network: true` authority;
- active PID/process/task handles or a persisted claim that a process is running;
- full child invocation, argv containing sensitive local paths, stdout/stderr dumps, or logs;
- raw evidence passages, source abstracts/bodies, full reports, manifests, event payload streams,
  artifact bytes, or copied research bundle content;
- security-scoped bookmarks, durable local-root authority, file descriptors, access tokens, or
  external URL authorization;
- unredacted error detail or secret-like dynamic keys.

The exact strings needed for user-authored questions/drafts remain allowed after redaction rules.
Tests inject independent canaries for all credential types, environment, grant, evidence, report,
and path categories and scan every persisted byte.

## Run Reference Resolution

`RunBinding.managed_relative_reference` is data, not authority.

1. Join it only against the existing internally configured managed run root.
2. Reject absolute paths, `..`, empty components, unexpected shapes, symlinks, non-directories,
   duplicate candidates, or root escape.
3. Load through the existing `RunRepository` bounded regular-file contract.
4. Require decoded run ID, request ID, plan ID/hash, and binding values to agree.
5. Before resume/export/terminal presentation, run fresh engine validation/reconciliation.
6. A cached fingerprint/status hint may decide that refresh is needed; it can never skip refresh or
   grant an action.

Missing/invalid/replaced references remain visible as safe read-only session issues. The store
does not remove, repair, rehash, import, or rewrite run files.

## Launch and Recovery

At launch:

1. Load safe workspace state; clamp or reset invalid layout fields independently.
2. Scan bounded envelope filenames, isolate invalid files, and rebuild the index when absent/stale.
3. Select the saved active conversation only if its envelope is valid and non-archived.
4. Downgrade persisted transient status hints (`planning`, `awaiting_approval`, `running`) to
   `unknown` in presentation until runtime/run reconciliation.
5. Do not restore plan/network approval, credentials, local-root authority, or process ownership.
6. Resolve referenced runs lazily/bounded; opening or consequential action triggers fresh checks.

Recovery outcomes:

| Condition | Outcome |
|-----------|---------|
| Orphan valid envelope absent from index | Include after rebuild |
| Index references missing envelope | Drop index entry; report rebuild note |
| One corrupt envelope | Isolate row/issue; other conversations usable |
| Unsupported newer envelope | Read-only `schema_newer`; never rewrite/downgrade |
| Interrupted temporary file | Ignore/remove exact stale temp after safety checks; keep last destination |
| Destination absent after pre-first-write crash | Conversation create failed; no fabricated row |
| Store root read-only/full | Existing data remains readable; mutations disabled with safe recovery |
| Store root/parent replaced or symlinked | Fail closed; no read/write outside expected root |

## Search and Index

- Searchable fields are normalized project title, conversation title, user-authored message text,
  and safe run ID; conversation results remain scoped to the selected project unless an explicit
  all-project search is requested.
- Evidence/report/source retrieved text is never copied into or indexed by the conversation store.
- Search is case/diacritic tolerant according to locale-independent safe normalization while
  retaining original display text.
- Result ordering is `updated_at` descending then conversation ID ascending.
- Index entries contain conversation ID, bounded title, updated/archive time, status hint, and safe
  normalized user-text tokens/summary needed for local search. The index is disposable.
- A result is opened only after its envelope loads and validates; an index hit alone is not enough.

## Migration and Compatibility

- v1 introduces no import from third-party chat stores and no network sync.
- Existing feature-002 runs are not automatically rewritten. The app may create a conversation with
  a typed reference when a user explicitly opens/adopts a managed run; the run remains unchanged.
- Unsupported schema versions are never overwritten. A future migration must read old → validate
  new → atomically write new and retain rollback evidence, with explicit migration tests.
- Removing the feature must not delete engine runs; conversation metadata may be archived/exported
  or left inert.

## Required Contract Tests

1. Strict encode/decode round trip and unknown-compatible-field behavior.
2. Duplicate/malformed IDs, invalid timestamps/numbers, oversize, trailing JSON, invalid UTF-8,
   newer schema, and mismatched filename failures.
3. Confinement against absolute/traversal/symlink/hard-link/root replacement and non-regular files.
4. Injected failure at every write protocol step preserves the prior complete version.
5. Revision conflict, rapid duplicate append idempotence, and deterministic ordering/search.
6. Corrupt/newer envelope isolation and index rebuild from 0/200/10,000 bounded cases.
7. Relaunch clears grant/approval/process authority and downgrades transient hints.
8. Independent canaries prove every denied class absent from envelopes, workspace state, index,
   diagnostics, support files, and exports.
9. Delete/archive/restore/rename never mutates or removes an engine run directory.
10. Bound run resolution rejects missing/replaced/escaped/mismatched records and requires fresh
    validation before consequential actions.
