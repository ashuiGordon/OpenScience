# Feature Specification: General Research Agent

**Feature Branch**: `agent/general-research-agent`

**Created**: 2026-08-12

**Status**: Implemented and verified

**Input**: User description: "构造一个科研通用 Agent，参考 aipoch/open-science 和
proma-ai/Proma 的通用框架，但不直接照抄。"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Produce an Evidence-Backed Research Brief (Priority: P1)

A researcher describes a question, scope, constraints, and desired output. The agent proposes a
reviewable plan, discovers relevant material, records evidence, and produces a structured brief
whose verifiable claims can be traced to sources.

**Why this priority**: Turning a question into a traceable synthesis is the smallest complete unit
of value for a general research agent.

**Independent Test**: Submit the packaged example question with the offline example corpus and
verify that the run produces a plan, evidence ledger, cited report, and completion summary without
requiring any other user story.

**Acceptance Scenarios**:

1. **Given** a well-scoped research question and enabled sources, **When** the user starts a run,
   **Then** the agent presents a finite plan, executes permitted steps, and returns a report with
   inline source references.
2. **Given** a broad or ambiguous question, **When** material choices would change the result,
   **Then** the agent records its assumptions or requests focused clarification before synthesis.
3. **Given** evidence records explicitly classified as disagreeing, **When** the report is
   produced, **Then** the disagreement, evidence strength, and unresolved uncertainty remain
   visible. The first release does not infer semantic contradiction from arbitrary prose; an
   unclassified extracted passage remains `unclear` rather than being mislabeled as support.

---

### User Story 2 - Audit Claims and Provenance (Priority: P1)

A researcher inspects any important claim and can follow it to the supporting evidence, original
source, retrieval context, and run activity that produced it. The researcher can run a validation
check before relying on or sharing the result.

**Why this priority**: Inspectability is necessary for scientific trust and differentiates a
research agent from an ordinary answer generator.

**Independent Test**: Open a completed packaged run, select each claim, and verify that the audit
view identifies its evidence or explicitly labels it as inference, assumption, or unsupported.

**Acceptance Scenarios**:

1. **Given** a completed report, **When** the user validates it, **Then** every externally
   verifiable claim is linked to at least one accessible evidence record or is flagged.
2. **Given** missing, withdrawn, or unreachable source material, **When** validation runs, **Then**
   the limitation is reported without inventing replacement evidence.
3. **Given** a derived artifact, **When** the user inspects provenance, **Then** its inputs,
   producing step, configuration, and content identity are available.

---

### User Story 3 - Research Across Local Materials (Priority: P2)

A researcher adds local notes, papers, tabular data, or prior outputs to the approved workspace and
asks the agent to combine them with other enabled evidence while preserving source boundaries.

**Why this priority**: Real research begins with a mix of private project material and public
literature rather than a blank prompt.

**Independent Test**: Run a question over the packaged local document set and verify that the
report cites local and remote records distinctly, leaves source files unchanged, and does not read
outside the approved paths.

**Acceptance Scenarios**:

1. **Given** supported files inside an approved workspace, **When** a run references them, **Then**
   their contents are searchable and their derived evidence retains file-level provenance.
2. **Given** an unreadable, unsupported, or oversized file, **When** ingestion is attempted,
   **Then** the run continues with a clear limitation and does not silently omit the failure.
3. **Given** a path outside the approved workspace, **When** a tool attempts access, **Then** the
   access is denied and recorded.

---

### User Story 4 - Extend Models and Research Sources (Priority: P2)

A maintainer can add or replace a synthesis model or research source through a declared extension
contract without changing the orchestration core. General analysis-tool and discipline-specific
workflow extensions are deliberately deferred until they have a separately reviewed execution and
data-governance contract.

**Why this priority**: Generality requires replaceable capabilities rather than a fixed collection
of vendor-specific or discipline-specific behavior.

**Independent Test**: Install a minimal example extension, enable it for a run, and verify that the
core discovers its declared capabilities, applies policy, and records its activity in the same
provenance format as built-in capabilities.

**Acceptance Scenarios**:

1. **Given** a valid extension, **When** it is registered, **Then** its identity, inputs, outputs,
   permissions, and health are visible before use.
2. **Given** an incompatible or malformed extension, **When** registration is attempted, **Then**
   it is rejected with actionable validation errors and cannot execute.
3. **Given** two interchangeable providers, **When** the selected provider changes, **Then** the
   research workflow and artifact formats remain consistent.

---

### User Story 5 - Resume, Replay, and Export Research (Priority: P3)

A researcher can stop an in-progress run, resume it later without repeating completed work, replay
recorded activity for inspection, and export both human-readable results and machine-readable
records.

**Why this priority**: Long-running research must survive interruptions and remain portable, but a
single uninterrupted run already provides initial value.

**Independent Test**: Interrupt the packaged workflow after evidence collection, resume it, and
verify that completed steps are reused and the exported report and manifest match the final run.

**Acceptance Scenarios**:

1. **Given** an interrupted run with a valid checkpoint, **When** the user resumes it, **Then**
   completed steps are not repeated and pending steps continue under the current policy.
2. **Given** a recorded offline run, **When** the user replays it, **Then** the system reconstructs
   the plan, tool activity, evidence, and artifacts without contacting external services.
3. **Given** a completed or partial run, **When** the user exports it, **Then** the package includes
   the report, evidence, configuration summary, limitations, and provenance manifest.

### Edge Cases

- A search returns no relevant sources, only duplicates, or results outside the requested dates.
- A source changes, is retracted, becomes unreachable, or lacks a stable identifier.
- Different records refer to the same work with inconsistent titles, authors, or dates.
- A model returns malformed structured output, invalid tool arguments, or a nonexistent citation.
- A retrieved document contains instructions intended to redirect the agent or obtain credentials.
- The user cancels while a tool is running or changes the permission policy before resume.
- A network request times out, is rate-limited, or exhausts the configured cost or step budget.
- A local input contains secrets, personal data, binary content, or a path traversal reference.
- A network synthesis model is selected for evidence derived from a private local file.
- Evidence supports correlation but the requested report asks for a causal conclusion.
- The available literature is too sparse, too old, or too domain-specific for a reliable synthesis.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST accept a research question together with optional scope, constraints,
  assumptions, source preferences, and desired output.
- **FR-002**: The system MUST create a finite, reviewable research plan whose steps declare their
  purpose, required capability, dependencies, and completion condition.
- **FR-003**: Users MUST be able to inspect and approve a finite plan, revise its descriptive fields
  and provider selection before execution, request cancellation, and resume a valid interrupted
  run. Step identities, dependencies, and capability bindings in the first-release workflow MUST
  remain fixed and be rejected if edited.
- **FR-004**: The system MUST discover material only through enabled sources and approved local
  paths while honoring declared limits and permissions.
- **FR-005**: The system MUST normalize each used source into a record containing identity,
  attribution, retrieval context, availability, and license information when available.
- **FR-006**: The system MUST store evidence separately from narrative output and link each evidence
  record to the exact source material or metadata from which it was derived.
- **FR-007**: Every externally verifiable claim in a final report MUST cite supporting evidence or
  be labeled as inference, assumption, hypothesis, or unsupported.
- **FR-008**: The system MUST expose conflicting evidence, uncertainty, coverage limits, and
  material gaps instead of resolving them invisibly.
- **FR-009**: The system MUST validate that cited evidence exists, belongs to the run, and supports
  the associated claim before marking a report complete.
- **FR-010**: The system MUST treat retrieved content as untrusted data and MUST prevent embedded
  instructions from changing the objective, policy, or tool permissions.
- **FR-011**: The system MUST enforce capability-specific policies before every tool action and
  require explicit approval for actions classified as consequential or outside read-only research.
- **FR-012**: The system MUST deny undeclared file, network, process, or credential access and record
  the denial as part of the run history.
- **FR-013**: Users MUST be able to supply supported local research materials without modifying the
  originals, and derived records MUST preserve their file provenance.
- **FR-014**: Synthesis-model providers and research-source providers MUST be replaceable through
  documented extension contracts without changing the orchestration core. Arbitrary analysis,
  execution, and specialist-workflow extensions are outside the first release and MUST NOT be
  accepted by the registry.
- **FR-015**: Each extension MUST declare its identity, version, capabilities, input and output
  contract, required permissions, and availability before it can be used.
- **FR-016**: The system MUST checkpoint completed work and resume from the latest valid checkpoint
  without silently repeating completed consequential actions.
- **FR-017**: Every run MUST produce an inspectable manifest covering the request, plan, policy,
  configuration identifiers, activity, evidence, artifacts, timing, errors, and limitations.
- **FR-018**: The system MUST support replay from recorded activity without requiring access to the
  original external providers.
- **FR-019**: Users MUST be able to export human-readable findings and machine-readable evidence and
  provenance records without exposing stored credentials or unrelated local data.
- **FR-020**: The system MUST enforce configurable limits on steps, elapsed time, retrieved volume,
  and provider usage, and MUST report which limit ended a run.
- **FR-021**: Provider, source, or tool failures MUST yield an explicit failure or clearly labeled
  partial result; the system MUST NOT fabricate successful activity or missing evidence.
- **FR-022**: The system MUST redact known credential patterns and sensitive configuration values
  before persistence or network egress. The first release MUST refuse to send evidence derived
  from approved local files to a network synthesis model because it has no separately reviewed
  private-data-egress capability.
- **FR-023**: The system MUST state that generated research is assistance rather than expert review
  and MUST surface additional review boundaries for clinical, human-subjects, hazardous, dual-use,
  or regulated decisions.
- **FR-024**: The project MUST include a self-contained example that demonstrates the complete
  workflow without paid services or network access.

### Key Entities

- **Research Request**: The user's question, intended audience, scope, constraints, assumptions,
  source preferences, output requirements, and configured limits.
- **Research Plan**: An ordered dependency graph of research steps and their completion conditions.
- **Run**: The stateful execution of one request, including status, policy, checkpoints, events,
  costs or limits, errors, and timestamps.
- **Capability**: In the first release, a synthesis model or research source with a declared
  contract, permissions, health, and version. Reserved analysis/export kinds are not executable
  extension points.
- **Source Record**: A normalized bibliographic or local-document identity with attribution,
  retrieval context, availability, and licensing metadata.
- **Evidence Record**: A source-bound excerpt, observation, or metadata fact used during reasoning.
- **Claim**: A report statement classified as sourced fact, inference, assumption, hypothesis, or
  unsupported, with links to evidence and confidence or limitation notes.
- **Artifact**: A versioned report, dataset, table, figure, or intermediate output with content
  identity and links to its producing step and inputs.
- **Policy Decision**: An allow, deny, or approval-required result for a requested capability action.
- **Run Manifest**: The portable, machine-readable index of the request, plan, events, evidence,
  claims, artifacts, configuration, and limitations required for audit and replay.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A first-time user can run the self-contained example and obtain a cited report,
  evidence ledger, and manifest within five minutes.
- **SC-002**: In the acceptance corpus, 100% of externally verifiable report claims either link to
  supporting evidence or carry an explicit non-evidence classification.
- **SC-003**: For every acceptance run, an auditor can trace 100% of tool activity and generated
  artifacts to the responsible plan step and recorded inputs.
- **SC-004**: Across the interruption test matrix, at least 95% of valid checkpoints resume without
  repeating a completed step; invalid checkpoints fail visibly and preserve prior records.
- **SC-005**: A maintainer can replace one model provider and one research-source provider using
  configuration and declared extensions, with no changes to the orchestration core.
- **SC-006**: In policy tests, 100% of undeclared or approval-required consequential actions are
  denied or paused before execution.
- **SC-007**: When one enabled source fails, the user receives a labeled partial result or actionable
  error within 30 seconds after the configured request timeout.
- **SC-008**: In usability validation, a researcher can follow a sampled conclusion to the relevant
  evidence and original source in under two minutes.
- **SC-009**: Secret-scanning acceptance tests find zero unredacted fixture credentials in persisted
  run records and export packages.

## Assumptions

- The first release serves individual researchers in a local workspace; shared multi-user editing
  and a graphical desktop interface are outside this feature.
- The default interaction is a command-oriented application plus reusable programmatic interfaces.
- Users remain responsible for expert interpretation, research ethics, source access rights, and
  decisions based on generated work.
- Public metadata and abstracts may be retrieved when terms allow; the system will not bypass
  paywalls, access controls, or source restrictions.
- English-language discovery is the initial quality baseline, while records and outputs preserve
  Unicode and may contain other languages.
- External model and literature services are optional. The self-contained example and automated
  acceptance tests remain usable offline.
- Arbitrary code execution, remote compute, wet-lab control, automated publication, and regulated
  decision support require later, separately reviewed capabilities and are not enabled by default.
- The project is an original implementation. Reference projects inform product principles only;
  their source code, prompts, branding, and internal file structures are not copied.
