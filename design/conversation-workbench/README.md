# Conversation Workbench Visual Target

The selected source of visual truth is
[`selected-option-3.png`](selected-option-3.png), chosen by the user on 2026-08-27. The prior
form-first implementation is retained only as comparison evidence in
[`before-form-workbench.png`](before-form-workbench.png).

## Frame and regions

- Source pixels: 1487 × 1058, native macOS dark appearance.
- Left sessions/projects rail: approximately 267 px (18%).
- Center conversation: approximately 758 px (51%) and always the dominant region.
- Right contextual inspector: approximately 462 px (31%), collapsible.
- Top title bar: approximately 50 px.
- At a 1280 px app width, target 220–250 px left, at least 560 px center, and 340–410 px right.

## Visual system

| Token | Approximate value | Purpose |
|---|---:|---|
| Base | `#171A1F` | Window and conversation background |
| Raised surface | `#1D2127` | Sidebar, inspector, composer, inline cards |
| Divider | `#343942` | Split panes and row separation |
| Primary text | `#F1F3F5` | Titles and message content |
| Secondary text | `#A8AFB8` | Metadata and timestamps |
| Accent | `#2766E8` | Selection, approval, send, active tab |
| Success | `#55B871` | Completed steps and ready state |
| Warning | `#D5A42E` | Pending network approval and caution |

Use native system typography and SF Symbols. Corner radii stay in the 7–9 px range. Prefer
8/12/16 px spacing, lightweight dividers, and grouped rows over cards nested inside cards. Do not
introduce gradients, glass effects, decorative illustrations, or dashboard metrics.

## Required primary state

The fidelity capture must show one realistic active scientific session:

1. A selected project and dated searchable conversation history on the left.
2. A user research prompt and assistant response in the center.
3. An inline one-time network approval card.
4. A collapsible five-step run card with tool activity and real status.
5. An evidence-linked result and persistent composer at the bottom.
6. Right-side tabs for Context, Plan, Evidence, and Artifacts, with an exact evidence passage and
   report/file preview.
7. Runtime, model, tool availability, and network state visible without displacing the conversation.

The reference is an information-architecture and visual-density target. It does not authorize
copying another project's logo, brand, proprietary assets, or source code.

## QA evidence

- Equal-size implementation: `implementation-final-normalized.png` (1487 × 1058)
- Equal-size side-by-side: `comparison-final-1487x1058.png`
- Titlebar-free focused comparison: `comparison-final-content.png`
- Full findings and iteration history: [`../../design-qa.md`](../../design-qa.md)

The reference-size shell is implemented, but strict visual acceptance remains blocked: the current
unmasked SSIM is 0.579766 versus the specification's 0.90 target, and the selected fixture does not
yet provide a validated native PDF preview.
