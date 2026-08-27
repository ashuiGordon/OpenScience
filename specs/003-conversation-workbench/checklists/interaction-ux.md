# Interaction & UX Requirements Checklist: Conversation Research Workbench

**Purpose**: Reviewer-grade unit tests for the completeness, clarity, consistency, measurability,
and safety of the selected option 3 workbench requirements

**Created**: 2026-08-27

**Feature**: [spec.md](../spec.md)

**Depth / actor / timing**: Standard rigor; product/design/accessibility/security reviewers during
spec and PR review. Focus areas are visual/interaction fidelity and preservation of research safety.

## Requirement Completeness

- [x] CHK001 Are all three requested regions, their primary contents, and their authority boundaries explicitly defined? [Completeness, Spec §FR-001, §FR-003, §FR-006, §FR-017]
- [x] CHK002 Is the transition away from the legacy form-first entry explicitly required without deleting advanced settings? [Completeness, Spec §FR-001, §FR-009]
- [x] CHK003 Are requirements present for zero, one, archived, searched, and date-grouped conversations? [Coverage, Spec §FR-004, §US1]
- [x] CHK004 Are all timeline item classes and their provenance expectations specified? [Completeness, Spec §FR-006, §FR-007]
- [x] CHK005 Are inline plan, network, run, result, error, and recovery card contents/actions fully enumerated? [Completeness, Spec §FR-011–FR-015, §US2]
- [x] CHK006 Are Context, Plan, Evidence, and Artifacts requirements separately defined, including empty and invalid states? [Completeness, Spec §FR-017–FR-022, §US3]
- [x] CHK007 Are persistence requirements defined for safe data, denied data, crash recovery, indexing, deletion, and run references? [Completeness, Spec §FR-024–FR-028, §US4]
- [x] CHK008 Are every feature-002 capability and safety boundary explicitly carried into the new entry points? [Completeness, Spec §FR-029, §US5]

## Requirement Clarity

- [x] CHK009 Is the sole visual target identified by exact path, viewport, appearance, and no-copy boundary? [Clarity, Spec §FR-002, §Binding Visual Target]
- [x] CHK010 Are reference column dimensions, tolerances, spacing, separators, and composer visibility objectively stated? [Clarity, Spec §FR-030]
- [x] CHK011 Is the adaptive collapse order and invariant center region unambiguous at the minimum size? [Clarity, Spec §FR-023, §FR-031]
- [x] CHK012 Is “conversation” distinguished from engine run, research turn, attempt, timeline item, and preview selection? [Clarity, Spec §Key Entities]
- [x] CHK013 Is agent-authored content constrained enough to prevent raw logs or UI inference from becoming scientific narrative? [Clarity, Spec §FR-007, §FR-036]
- [x] CHK014 Is “ephemeral approval” defined across relaunch, resume, plan/risk/limit changes, and conversation switching? [Clarity, Spec §FR-012, §FR-025]
- [x] CHK015 Are “inert preview” and allowed external navigation defined with explicit unsafe-content boundaries? [Clarity, Spec §FR-021, §FR-022]

## Requirement Consistency

- [x] CHK016 Do visual fidelity requirements remain consistent with native resizing, larger text, light/system appearance, and accessibility? [Consistency, Spec §FR-030–FR-032, §US6]
- [x] CHK017 Do inline approval requirements preserve the constitution’s explicit authority model and feature-002 no-default-allow rule? [Consistency, Spec §FR-010–FR-012, Constitution §III]
- [x] CHK018 Do session persistence requirements consistently exclude all data that existing Keychain, grant, process, event, and run stores own? [Consistency, Spec §FR-024–FR-027]
- [x] CHK019 Do result/timeline and preview requirements agree that validation and exact joins remain authoritative? [Consistency, Spec §FR-015, §FR-020, §FR-026]
- [x] CHK020 Do keyboard shortcuts avoid conflict between multiline input, contextual approval, destructive actions, and Escape? [Consistency, Spec §FR-033]
- [x] CHK021 Does one-active-run behavior remain consistent with concurrent read-only work in other conversations? [Consistency, Spec §FR-014, §US2 scenario 7]

## Acceptance Criteria Quality

- [x] CHK022 Can visual fidelity be measured without requiring exact font antialiasing or accepting another mock? [Measurability, Spec §SC-002]
- [x] CHK023 Can truthful card/state coverage be measured against the full fixture state/action matrix? [Measurability, Spec §SC-003]
- [x] CHK024 Can citation correctness and selection time be measured across a 1,000-record fixture? [Measurability, Spec §SC-004]
- [x] CHK025 Can approval denial and relaunch safety be measured as zero requests and zero restored authority? [Measurability, Spec §SC-005]
- [x] CHK026 Are scale/performance targets defined with counts, p95 latency, and a supported test environment requirement? [Measurability, Spec §SC-006]
- [x] CHK027 Is session recovery success measurable across every interrupted-write fixture and unaffected conversation? [Measurability, Spec §SC-007]
- [x] CHK028 Is accessibility completion defined as an end-to-end outcome rather than only labels or a screenshot? [Measurability, Spec §SC-009]
- [x] CHK029 Is regression completion broad enough to cover deterministic Python/Swift, offline run, resume, replay, export, security, and integrity? [Measurability, Spec §SC-010]

## Scenario and Edge-Case Coverage

- [x] CHK030 Are alternate flows covered for rejected/edited plans, declined network, follow-up turns, collapsed preview, archive/restore, and light appearance? [Coverage, Spec §US1–US6]
- [x] CHK031 Are exception flows covered for stale async results, duplicate sends, active run elsewhere, missing run/artifact, malformed event, and unsafe URL/content? [Coverage, Spec §Edge Cases]
- [x] CHK032 Are recovery flows covered for interrupted writes, corrupt/newer session schemas, sleep/relaunch, interrupted/partial runs, and resume authority reacquisition? [Coverage, Spec §US4, §US5, §Edge Cases]
- [x] CHK033 Are boundary cases stated for 0/200 conversations, 0/1,000 timeline/evidence items, long Unicode text, and minimum/reference viewport? [Coverage, Spec §FR-034, §Edge Cases, §SC-006]
- [x] CHK034 Are focus-preservation requirements defined when cards change state, actions disappear, panes collapse, or new events arrive? [Coverage, Spec §US6, UI Contract §Keyboard and Accessibility]

## Non-Functional and Safety Requirements

- [x] CHK035 Are keyboard, VoiceOver, increased contrast, reduced motion, text scaling, semantic status, and announcements all specified? [Coverage, Spec §FR-032, §FR-033]
- [x] CHK036 Are active-content, remote HTML, retrieved-instruction, unsafe-scheme, and executable-artifact exclusions explicit? [Security, Spec §FR-021, §FR-022, §Out of Scope]
- [x] CHK037 Are secret, credential, environment, grant, approval, diagnostic, passage, report, and path persistence boundaries explicit and testable? [Security, Spec §FR-024–FR-027, §SC-011]
- [x] CHK038 Is the workbench’s local/no-account/no-cloud and truthful development-distribution boundary explicit? [Scope, Spec §Dependencies, §Assumptions, §Out of Scope]
- [x] CHK039 Are no-copy requirements explicit enough to distinguish high-level interaction inspiration from prohibited assets/copy/code/trade dress? [Legal/Provenance, Spec §FR-002, §SC-011]

## Dependencies, Assumptions, and Conflicts

- [x] CHK040 Are feature 001 engine and feature 002 desktop contracts named as authoritative dependencies rather than assumed reimplementations? [Dependency, Spec §Dependencies, §FR-026, §FR-029]
- [x] CHK041 Are first-release constraints for one local workspace/window/run, macOS 14+, and no cloud/backend stated? [Assumption, Spec §Assumptions]
- [x] CHK042 Are deferred capabilities—sync, collaboration, executable notebooks/code, engine semantics, distribution signing—not accidentally implied by the selected visual? [Scope, Spec §Out of Scope]
- [x] CHK043 Is the apparent conflict between a dark-only visual target and retained system/light appearance explicitly resolved? [Conflict resolved, Spec §US6 scenario 5, §Assumptions]

## Notes

- 43/43 requirement-quality checks pass on the planning baseline dated 2026-08-27.
- Traceability references appear on every item.
- This checklist validates the written requirements; implementation evidence belongs in
  [quickstart.md](../quickstart.md) and task completion, not here.
