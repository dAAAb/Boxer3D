---
title: Decisions (ADR-style)
updated: 2026-04-23
---

# Decisions

Non-obvious choices with the rationale that led to them. When a future
question comes up ("why did we do it this way?"), read here first. When a
decision is reversed, mark it **Superseded** and link forward.

---

## D-001 · Native CoreML for BoxerNet, ORT for YOLO

**Date**: 2026-04-21 · **Status**: accepted

Two ML models in the app. Chose different runtimes per model:

- **BoxerNet** → native `.mlpackage` via custom `convert/` pipeline.
- **YOLO11n** → ONNX Runtime + CoreML EP (CPUAndGPU).

**Why different.** BoxerNet is 200 MB of DINOv3 weights; running it
through ORT + CoreML EP produced 136 partitions, 211 CPU-fallback nodes,
2× memory duplication (ORT + CoreML compiled cache), and ~380 ms/cycle.
Native mlpackage with `computeUnits = .all` lands 815/815 ops on ANE,
one copy in memory, ~180 ms/cycle.

YOLO is 10 MB. The partitioning pain with ORT is real but the absolute
memory cost is negligible and its graph optimizer maps cleanly to CoreML
EP with `CPUAndGPU` units. Rebuilding the conversion pipeline for both
models wasn't worth it. See
[coreml-native.md](concepts/coreml-native.md) and
[workflows/model-conversion.md](workflows/model-conversion.md).

**If we revisit.** A unified native pipeline (both models as .mlpackage)
would drop the ORT dependency, but that's cosmetic; ship-blocking reasons
would need to emerge.

---

## D-002 · Static `numBoxes = 3`

**Date**: 2026-04-21 · **Status**: accepted

BoxerNet's converted `.mlpackage` has a baked-in `numBoxes = 3`. See
[static-num-boxes.md](concepts/static-num-boxes.md) for the full
reasoning. Summary: dynamic shapes were the main reason coremltools
conversion choked, and 3 covers the 95th-percentile kitchen scene.

If we scale to warehouse / inspection use cases with routinely 10+
objects in view, revisit.

---

## D-003 · `imageSize = 480` (halved from paper's 960)

**Date**: 2026-04-21 · **Status**: accepted

DINOv3's self-attention is O(N²) in token count. Halving side length
quarters tokens. ~4–6× inference speedup. Accuracy drift exists but is
acceptable for AR scan.

**If we revisit.** Fine-tune on 480×480 data for the specific classes
we care about. Current model is still the 960-trained checkpoint run at
480 — we're accepting a distribution shift.

---

## D-004 · FSD 4-state enum (not a Bool)

**Date**: 2026-04-23 · **Status**: accepted

`FSDRenderMode.{camera, whiteOnWhite, whiteOnDark, blackOnWhite}`. See
[fsd-palette.md](concepts/fsd-palette.md) for each state's semantics.

**Why.** The v0 Bool `fsdMode` accidentally produced a 3-state cycle
because `scene.background.contents = nil` doesn't reliably restore the
ARSCNView camera feed on ARKit iOS 18. User liked the 3 states *and*
asked for a 4th (`whiteOnWhite`). An explicit enum with a
`next` method is the simplest thing that makes the cycle deterministic.

---

## D-005 · Drop `.floor / .wall / .table` from scene-recon, add plane overlay

**Date**: 2026-04-23 · **Status**: accepted

ARKit scene reconstruction mesh has per-face classification. The raw mesh
is noisy on flat surfaces (ragged triangles, per-frame classifier flicker,
objects-on-surface tagged `.none` and rendered as "bumps"). ARPlaneAnchor
is much cleaner. We render plane anchors with a Tesla-style dot overlay
and drop those classes from the raw mesh.

Kept classes: `.ceiling / .seat / .window / .door` (plane detection
under-covers these).

See [classification-filter.md](concepts/classification-filter.md).

---

## D-006 · Robust plane Y from classified vertex percentile

**Date**: 2026-04-23 · **Status**: accepted · **Supersedes** the −2 cm
heuristic from 2026-04-22.

For horizontal ARPlaneAnchors, compute the 10th-percentile world-space Y
of `.floor / .table` classified vertices within the plane's footprint
(±25 cm Y window). Falls back to the old −2 cm heuristic if fewer than
30 samples qualify.

Why 10th percentile: clutter biases ARKit's plane fit upward; real
surface lives at the bottom of the Y distribution. 10 % gives noise
immunity vs 0 %.

See [robust-plane-y.md](concepts/robust-plane-y.md).

---

## D-007 · Critically-damped spring for per-track position tween

**Date**: 2026-04-20 · **Status**: accepted

33 Hz integrator pulls each track's rendered position toward the latest
BoxerNet observation with `omega = 14 rad/s` (≈ 200 ms settle for 10 cm
step). See [spring-tween.md](concepts/spring-tween.md).

**Rejected alternatives.**

- **SCNAction / CoreAnimation** — can't retarget mid-animation without
  popping.
- **Linear lerp** — looks robotic, settling time depends on delta.
- **Kalman filter** — overkill, doesn't give us the animation curve we
  actually want.

---

## D-008 · Rotation yaw-only (defer 3-DoF)

**Date**: 2026-04-22 · **Status**: parked

BoxerNet only outputs yaw. Two paths to get 3-DoF rotation (retrain as
Cube R-CNN, or LiDAR-mesh PCA) were discussed and **parked** at the
user's request. Kitchen / AR use cases don't need it.

Unpark if:
- Scene coverage extends to toppled objects / tilted items.
- A customer explicitly asks.

See [rotation-1axis.md](concepts/rotation-1axis.md).

---

## D-009 · LLM wiki for handoff (this document, etc.)

**Date**: 2026-04-23 · **Status**: accepted

Adopted the [Karpathy LLM Wiki pattern](../raw/karpathy-llm-wiki.md) to
hand the project off to another collaborator. Three layers: `raw/`
(immutable sources), `wiki/` (LLM-maintained markdown), `CLAUDE.md`
(schema).

Expected payoff: a new engineer + their LLM agent can get context on
the full codebase in ~30 minutes instead of rediscovering every
trade-off from git archaeology.
