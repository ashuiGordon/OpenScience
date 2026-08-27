# Design QA: Conversation Research Workbench

## Comparison target

- Source visual truth: `design/conversation-workbench/selected-option-3.png`
- Final implementation capture: `design/conversation-workbench/implementation-final-normalized.png`
- Full-view comparison: `design/conversation-workbench/comparison-final-1487x1058.png`
- Content-focused comparison: `design/conversation-workbench/comparison-final-content.png`
- Last real-window capture: `design/conversation-workbench/implementation-pass-3-visible.png`
- Viewport: 1487 × 1058 logical points, dark appearance, deterministic `--design-preview` state
- State: selected `Protein LM Repro` project and `Reproduce ESM-1b leaderboard` conversation;
  inline network review, five-step plan, event-derived activity, result, populated composer, and
  Evidence preview selected

## Density normalization

- Source: 1487 × 1058 pixels at 1×.
- Implementation offscreen native `NSWindow` render: 2974 × 2116 pixels at 2× Retina.
- Implementation comparison copy: Lanczos-normalized to 1487 × 1058 without changing aspect ratio.
- The normal app-window capture on this host is limited to 1487 × 865 logical points. That real
  window is retained as pass-3 evidence, but it is not used as the reference-size comparison.
- The offscreen theme frame paints inactive toolbar materials as white capsules. The content-only
  comparison removes the 36-pixel titlebar from both sides; the real-window pass-3 capture is the
  evidence for native titlebar appearance.

## Findings

- [P2] Reference-size perceptual threshold is not met.
  Location: whole workbench.
  Evidence: the final equal-size unmasked FFmpeg SSIM is `0.559633`; the feature specification
  requires masked perceptual similarity of at least `0.90`, with masking restricted to timestamp
  glyphs and a one-pixel text fringe. The implementation matches the three-region structure and
  accepted widths, but surface fills, typography rasterization, content density, and card geometry
  still differ too much to infer a compliant masked score.
  Impact: the implementation is a faithful native interaction direction, but it cannot be called a
  pixel-faithful acceptance of the sole target.
  Fix: add the declared masked comparison harness, then continue token/spacing/type tuning against
  that measured output on a full-size capture host.

## Required fidelity surfaces

- Fonts and typography: both use native macOS system type, compact 9–13-point UI hierarchy, and a
  serif evidence title. Remaining raster/weight differences contribute to the failed similarity
  threshold.
- Spacing and layout rhythm: final implementation fixes the sidebar and inspector at 262 and 484
  points in design-preview mode, keeps a 520-point minimum center, uses compact 8–16-point rhythm,
  and keeps the composer pinned and visible. No overlap is visible in the exact-size render.
- Colors and tokens: semantic system dark colors, blue action/selection, green success, yellow
  network warning, and restrained separators match the direction. Source-specific charcoal values
  are not yet pixel-matched.
- Image quality and asset fidelity: no external logo or copied product asset is used. SF Symbols
  remain sharp at Retina density. A real deterministic PDF fixture is resolved through bounded
  manifest validation and rendered as a non-interactive first-page thumbnail.
- Copy and content: product copy is coherent and independently identifies OpenScience. Fixture
  scientific text is explicitly deterministic preview data; retrieved content uses inert native
  text.
- Icons: SF Symbols are consistent and aligned; consequential state is also expressed in text.
- Responsiveness/accessibility: panes collapse explicitly and reduced motion is honored in code.
  Full VoiceOver, larger-text, increased-contrast, and 1180 × 720 manual acceptance remain release
  gates rather than visual-QA evidence.

## Focused comparison evidence

`comparison-final-content.png` removes only the native titlebar from both images. It confirms:

- left project/new/search/date-group/runtime hierarchy is aligned;
- center user → permission → plan → event activity → result → composer sequence is visible;
- right Context/Plan/Evidence/Artifacts tabs and evidence/provenance/artifact hierarchy are aligned;
- the remaining major visible difference is the missing rendered PDF artifact and finer token/type
  fidelity.

## Comparison history

1. Pass 1
   - Evidence: `implementation-pass-1.png`, `comparison-pass-1-review.png`.
   - Findings: right column too narrow, loose center density, gray oversized New Conversation,
     sparse evidence preview, inactive titlebar.
   - Fixes: fixed 262/484 design widths, populated provenance/artifacts, blue primary actions,
     denser semantic cards, active-window capture.

2. Pass 2
   - Evidence: `implementation-pass-2.png`, `comparison-pass-2-review.png`.
   - Findings: edge panes expanded to maximum widths, New Conversation remained capsule-like, and
     the composer greedily consumed its maximum height.
   - Fixes: exact preview widths, 36-point rounded-rectangle action, compact ideal composer height.

3. Pass 3
   - Evidence: `implementation-pass-3-visible.png`, `comparison-pass-3-review.png`.
   - Findings: primary shell, tool activity, result, and composer fit the host's 1487 × 865 visible
     window; evidence completeness initially pushed provenance and artifacts below the fold.
   - Fixes: exact-ID evidence fields moved into a collapsed disclosure after the exact passage,
     preserving reachability while restoring the reference hierarchy.

4. Final equal-size pass
   - Evidence: `implementation-final-normalized.png`,
     `comparison-final-1487x1058.png`, and `comparison-final-content.png`.
   - Result: no P0/P1 layout or core interaction mismatch remains. The PDF-preview P2 was resolved;
     the perceptual-threshold P2 remains actionable and exact SSIM is `0.559633`.

## Implementation checklist

- [x] Three-column default native workbench
- [x] Option-3 pane proportions and compact composer
- [x] Four stable preview tabs
- [x] Real inline permission/plan/event/result states
- [x] Exact citation ID routing and inert retrieved content
- [x] Dark reference fixture and equal-size comparison artifacts
- [ ] Masked similarity ≥0.90
- [x] Validated, inert native PDF artifact preview

## Follow-up polish

- [P3] Tune charcoal tokens and small-label optical weights after the masked comparison harness is
  available.
- [P3] Align minor toolbar icon spacing while preserving native macOS toolbar behavior.

final result: blocked
