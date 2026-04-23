---
title: Overview
updated: 2026-04-23
---

# Boxer3D overview

Boxer3D is a SwiftUI + ARKit + SceneKit iOS app that detects objects in the
camera stream and lifts them to 7-DoF 3D oriented bounding boxes (OBBs) in
the real world. Two neural nets on device:

- **YOLO11n** (10 MB, ONNX Runtime + CoreML EP) — 2D class + box detector.
- **BoxerNet** (Meta Reality Labs, [paper](https://facebookresearch.github.io/boxer/),
  CC-BY-NC) — 3D lifting. Consumes a 960×960 (or 480×480 "flash" variant) RGB
  crop, a 60×60 LiDAR depth patch grid, camera intrinsics/gravity, and up to
  three 2D boxes. Outputs `(cx, cy, cz, w, h, d, yaw)` per box in a gravity-
  aligned voxel frame, which the Swift side transforms to ARKit world.

The app renders each confirmed detection as a wireframe OBB plus — when
available — a canonical USDZ ghost mesh (cup, laptop, keyboard, bottle). A
critically-damped spring tween smooths per-cycle position jitter. Tesla-style
"FSD mode" optionally replaces the camera feed with scene-reconstruction
mesh + plane dot overlay, in four cycling palette states.

## Target device

- iPhone 15 Pro Max (A17 Pro ANE, LiDAR, iOS 18+).
- No simulator support — needs `ARWorldTrackingConfiguration` +
  `sceneDepth`.

## Source tree at a glance

| Path | What it is |
|---|---|
| `boxer/` | Xcode target. Swift source + mlpackage + USDZ meshes + onnx. |
| `convert/` | Offline Python pipeline: BoxerNet PyTorch → CoreML mlpackage. Not shipped. |
| `wiki/` | This knowledge base. LLM-maintained. |
| `raw/` | Immutable source docs (Karpathy gist, etc.). |
| `CLAUDE.md` | Schema — tells the LLM how `wiki/` is organised. |
| `Signing.xcconfig` | Local-only file (gitignored). See [`Signing.xcconfig.template`](../Signing.xcconfig.template). |
| `boxer.xcodeproj` | Xcode 16+ synchronized project. No pbxproj surgery needed. |

## Read order for a new collaborator

1. This page (you're here).
2. [architecture.md](architecture.md) — draws the pipeline on one page.
3. [components/arviewmodel.md](components/arviewmodel.md) — the orchestrator; read its companions as they come up.
4. [concepts/fsd-palette.md](concepts/fsd-palette.md) — main unique piece of UX.
5. [decisions.md](decisions.md) — the "why"s for odd-looking choices.
6. [gotchas.md](gotchas.md) — before you touch the conversion pipeline.
7. [workflows/build-install.md](workflows/build-install.md) — get it running on a device.

~30 minutes end-to-end.

## What this is *not*

- Not a multi-object tracker in the DeepSORT / ByteTrack sense — track
  association is greedy nearest-centroid with label gating and hysteresis
  ([track-hysteresis.md](concepts/track-hysteresis.md)).
- Not a SLAM implementation — ARKit provides pose; we consume.
- Not 3-DoF rotation — BoxerNet outputs yaw only, so the OBB's pitch/roll
  follow gravity. See [rotation-1axis.md](concepts/rotation-1axis.md).
- Not cloud-assisted. Both models run on the Neural Engine on-device.
