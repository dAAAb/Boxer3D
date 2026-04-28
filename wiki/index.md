---
title: Boxer3D wiki — index
updated: 2026-04-23
---

# Boxer3D wiki

Catalog. Start at [overview.md](overview.md) if you're new; pick a section
below if you know what you're looking for.

Schema and conventions: [../CLAUDE.md](../CLAUDE.md).
Chronological event log: [log.md](log.md).

## Top-level

- [overview.md](overview.md) — one-page "what is this" for a new collaborator.
- [architecture.md](architecture.md) — end-to-end data flow from ARKit frame to SceneKit box.
- [decisions.md](decisions.md) — ADR-style record of non-obvious choices + rationale.
- [gotchas.md](gotchas.md) — foot-guns (fp16 softmax collapse, static num_boxes, etc.).
- [todos.md](todos.md) — backlog, prioritised.
- [glossary.md](glossary.md) — terms and acronyms (BoxerNet, Plücker, SDP patch, FSD, OBB…).

## Components — one page per Swift file

- [components/boxerapp.md](components/boxerapp.md) — app entry point.
- [components/contentview.md](components/contentview.md) — SwiftUI root, buttons, detection cards.
- [components/arviewcontainer.md](components/arviewcontainer.md) — UIViewRepresentable wrapping ARSCNView.
- [components/arviewmodel.md](components/arviewmodel.md) — brain: session, tracks, render loop.
- [components/yolodetector.md](components/yolodetector.md) — ONNX Runtime YOLO11n wrapper.
- [components/boxernet.md](components/boxernet.md) — CoreML BoxerNet wrapper + pre/post-processing.
- [components/meshlibrary.md](components/meshlibrary.md) — class→USDZ canonical mesh lookup.
- [components/fsdmode.md](components/fsdmode.md) — Tesla FSD palette, plane overlay, contact shadow.

## Concepts — the non-obvious mechanisms

- [concepts/fsd-palette.md](concepts/fsd-palette.md) — 4-state render cycle, palette rationale.
- [concepts/plane-dot-overlay.md](concepts/plane-dot-overlay.md) — dot-grid shader on ARPlaneAnchor.
- [concepts/classification-filter.md](concepts/classification-filter.md) — dropping `.none/.floor/.wall/.table`.
- [concepts/robust-plane-y.md](concepts/robust-plane-y.md) — 10th-percentile fix for plane overshoot.
- [concepts/contact-shadow.md](concepts/contact-shadow.md) — radial gradient decal under objects.
- [concepts/dual-palette-swap.md](concepts/dual-palette-swap.md) — ghost↔solid material swap.
- [concepts/spring-tween.md](concepts/spring-tween.md) — critically damped MOT tween.
- [concepts/track-hysteresis.md](concepts/track-hysteresis.md) — provisional vs confirmed tracks.
- [concepts/mot-graveyard.md](concepts/mot-graveyard.md) — short-occlusion UUID stitching (Step 3.14).
- [concepts/rotation-1axis.md](concepts/rotation-1axis.md) — why we only rotate on yaw.
- [concepts/offscreen-arrow.md](concepts/offscreen-arrow.md) — edge-clamped pointer to selected object.
- [concepts/stream-mode.md](concepts/stream-mode.md) — continuous detection loop.
- [concepts/coreml-native.md](concepts/coreml-native.md) — why we ditched ONNX Runtime for BoxerNet.
- [concepts/static-num-boxes.md](concepts/static-num-boxes.md) — why `numBoxes = 3` is baked in.

## Workflows — how to do things

- [workflows/build-install.md](workflows/build-install.md) — xcodebuild, signing, device install.
- [workflows/model-conversion.md](workflows/model-conversion.md) — BoxerNet PyTorch → mlpackage.
- [workflows/mesh-authoring.md](workflows/mesh-authoring.md) — adding a new USDZ class mesh in Blender.

## Raw sources (read-only)

- [../raw/karpathy-llm-wiki.md](../raw/karpathy-llm-wiki.md) — the gist this wiki pattern comes from.
