---
title: Architecture — end-to-end data flow
updated: 2026-04-23
---

# Architecture

One AR frame → one detection cycle → possibly new/updated tracks →
SceneKit render. Stream mode chains these cycles continuously.

## Pipeline

```
ARFrame (60 Hz)
 │
 ├─ capturedImage (YpCbCr)  ──► pixelBufferToFloatArray × 2 (CHW, [0,1])
 │                               ├── 480×480 for BoxerNet
 │                               └── 640×640 for YOLO11n
 │
 ├─ sceneDepth.depthMap     ──► extractDepthMap [[Float]]
 │
 ├─ camera.transform                ─┐
 ├─ camera.intrinsics (scaled)      ─┤
 └─ camera.imageResolution          ─┘
                                     │
                                     ▼
   ┌─────────────────────────┐   ┌─────────────────────────┐
   │ YOLO11n.detect          │   │ BoxerNet.prepareDepth   │
   │  (ONNX Runtime,         │   │  ├─ gravityAlign → T_wv │
   │   CoreML EP CPUAndGPU)  │   │  ├─ buildSDPPatches     │
   │  out: [YOLOBox]         │   │  └─ buildRayEncoding    │
   └──────────┬──────────────┘   └───────────┬─────────────┘
              │                              │
              ▼                              │
   drop boxes overlapping                    │
   existing confirmed tracks                 │
   (label + 2D-projection test)              │
              │                              │
              ▼                              │
   top 3 by score → scale to 480             │
              │                              │
              └──────────┬───────────────────┘
                         ▼
              ┌────────────────────────────┐
              │ BoxerNet.runInference      │
              │  (CoreML .all compute)     │
              │  in:  image 1×3×480×480    │
              │       sdp   1×1×30×30      │
              │       rays  1×900×6        │
              │       bb2d  1×3×4          │
              │  out: params 1×3×7         │
              │       prob   1×3           │
              └────────────┬───────────────┘
                           │ voxel-frame OBB
                           ▼
              voxel → world transform (T_wv)
                           │
                           ▼
              [Detection3D]  (MainActor)
                           │
                           ▼
              placeBoxes(): match → new / update
                           │
                           ▼
              known: [KnownDetection]
                      │
                      │ 33 Hz tickTracks
                      ▼
              critical-damped spring tween
                      │
                      ▼
              SceneKit wireframe + ghost mesh + contact shadow
```

## Per-cycle timeline (iPhone 15 Pro Max, flash mode `imageSize = 480`)

Wall-clock rough numbers:

| Stage | Time | Thread |
|---|---|---|
| Image resize × 2 + depth extract (parallel) | ~6 ms | `.userInitiated` detached tasks |
| YOLO inference + BoxerNet depth prep (parallel) | ~20 ms | same |
| BoxerNet inference | ~160–180 ms | ANE (via CoreML `.all`) |
| `placeBoxes` + match + SCNNode ops | ~2 ms | MainActor |
| **Total** | **~180–210 ms / cycle** | |

That's the gated minimum between stream-mode cycles; add the 30 ms cooldown
(`cycleCooldownMs`) and you get ~4 Hz end-to-end, which is what the FSD-style
perception loop feels like in practice. See
[components/arviewmodel.md](components/arviewmodel.md) for the orchestration
details and [components/boxernet.md](components/boxernet.md) for the inference
internals.

## Render loop (decoupled from detection)

- ARKit drives `ARSCNView` at the device refresh rate (60 Hz typically).
- `ARViewModel` conforms to `ARSCNViewDelegate`; `didAdd/didUpdate/didRemove`
  route `ARMeshAnchor` and `ARPlaneAnchor` events back to MainActor to
  rebuild scene-recon geometry and dot overlays ([fsd-palette.md](concepts/fsd-palette.md)).
- `ContentView` runs a 33 Hz `Timer.publish` that calls
  `viewModel.tickTracks()`, which advances the spring integrator
  ([spring-tween.md](concepts/spring-tween.md)) and reaps stale tracks
  ([track-hysteresis.md](concepts/track-hysteresis.md)).
- When a detection is selected, the same 33 Hz tick updates the off-screen
  arrow hint ([offscreen-arrow.md](concepts/offscreen-arrow.md)).

## Coordinate frames

- **ARKit world**: `-Z` forward, `+Y` up, right-handed. What `ARFrame.camera.transform` lives in.
- **OpenCV camera**: `+Z` forward, `+Y` down. Intermediate in BoxerNet math;
  converted via `flipYZ` in `prepareDepthInputs`.
- **Voxel frame**: gravity-aligned world. BoxerNet's input and output live
  here; `T_wv` maps back to ARKit world. Z-grav convention — see
  `gravityAlign` in `boxer/BoxerNet.swift:405`.
- **SceneKit**: same as ARKit world because `ARSCNView` bridges them
  automatically.

## Memory layout (deployed binary)

Model weights shipped in the bundle (after conversion to CoreML):

| File | Size | Notes |
|---|---|---|
| `BoxerNetModel.mlpackage` / `.mlmodelc` | ~190 MB | fp16-weight mlpackage, 815/815 ops on ANE |
| `yolo11n.onnx` | 10 MB | ONNX Runtime CoreML EP CPUAndGPU |
| `cup/laptop/keyboard/bottle.usdz` | <200 KB each | Blender-authored ghost meshes |
| `BoxerNet*.onnx` | 200–400 MB | Reference dumps only. Not loaded at runtime — legacy from pre-native era. TODO: strip before public release. |

See [gotchas.md](gotchas.md#app-size) for the shipped-size cleanup item.
