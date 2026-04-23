---
title: Glossary
updated: 2026-04-23
---

# Glossary

## Project terms

**FSD mode** — Full-Self-Driving-inspired render mode. Replaces the
camera feed with scene-reconstruction mesh + plane dot overlay. Four
states cycle on the FSD button.
See [fsd-palette.md](concepts/fsd-palette.md).

**Ghost mesh** — The white, translucent, Blinn-shaded USDZ that renders
inside a detected OBB. Named from "ghost of the detected object".
See [meshlibrary.md](components/meshlibrary.md).

**Wireframe** — Line-geometry rendering of the OBB frame. Always present;
tinted per-class (red/green/blue) or yellow (selected).

**Confirmed / provisional track** — Tracks that have been observed ≥2
cycles are confirmed and get a 20 s age-out; first-time tracks are
provisional and get 8 s. Tesla-style hysteresis.
See [track-hysteresis.md](concepts/track-hysteresis.md).

**OBB** — Oriented Bounding Box. Axis-aligned box with a rotation.
BoxerNet outputs 7-DoF OBBs (centre 3, size 3, yaw 1).

**Yaw-only rotation** — We only rotate boxes around the gravity axis.
See [rotation-1axis.md](concepts/rotation-1axis.md).

**Flash Lv 2** — Internal name for the `imageSize = 480` speedup
(halved from paper's 960).

**Palette** — Set of `SCNMaterial` settings for the tracked object's
visuals. Two of them: `.cameraGhost`, `.fsdSolid`. Swapped by FSD mode.
See [dual-palette-swap.md](concepts/dual-palette-swap.md).

**Dot overlay** — The Tesla-style dot grid painted on ARPlaneAnchors.
See [plane-dot-overlay.md](concepts/plane-dot-overlay.md).

## External / technical

**ARKit** — Apple's AR framework. Provides camera pose, LiDAR depth,
plane anchors, scene reconstruction mesh.

**ARSCNView** — `SCNView` with an `ARWorldTrackingConfiguration` wired
up. We render our boxes and overlays in the same scene.

**ARMeshAnchor** — ARKit's scene-reconstruction mesh chunk. Each anchor
covers a local region; the app sees these via `ARSCNViewDelegate` calls
and rebuilds SceneKit geometry from them.

**ARMeshClassification** — Per-face label on `ARMeshGeometry`:
`.none / .floor / .wall / .ceiling / .table / .seat / .window / .door`.

**ARPlaneAnchor** — ARKit's planar surface detection. Cleaner than raw
scene-recon mesh for large flat surfaces; we overlay dots on these.

**BoxerNet** — Meta Reality Labs model that lifts 2D boxes to 3D OBBs
using DINOv3 visual features + LiDAR depth + camera pose.
[Project page](https://facebookresearch.github.io/boxer/). CC-BY-NC-4.0.

**DINOv3** — Meta's self-supervised vision transformer. Patch size 16,
used as the visual backbone in BoxerNet.

**SDP patch** — "Sparse Depth Patch". LiDAR depth median-pooled over
each 16×16 DINOv3 patch. Fed to BoxerNet as `sdp_median` at
`(1, 1, 30, 30)` (at 480 input).

**Plücker ray encoding** — 6D per-patch encoding: direction unit vector
+ moment (`origin × direction`). Captures the ray-in-space for each
patch centre. Fed as `ray_enc` at `(1, 900, 6)`.

**Voxel frame** — Gravity-aligned world frame. Output of
`gravityAlign(T_worldCam:)`. BoxerNet's input rays and output boxes
live here; `T_wv` maps back to ARKit world.

**YOLO11n** — Ultralytics' nano-size YOLO11 detector. 10 MB, 80 COCO
classes, 640×640 input. Our 2D detection stage.

**NMS** — Non-Maximum Suppression. Post-processing step that drops
overlapping YOLO boxes of the same class (IoU > threshold).

**ONNX Runtime (ORT)** — Microsoft's cross-platform inference runtime.
Used for YOLO11n with CoreML EP (Execution Provider) for on-device GPU
acceleration.

**CoreML EP** — ONNX Runtime's CoreML Execution Provider. Partitions
the graph into CoreML sub-models with CPU fallback. Good for small
models (YOLO), bad for big ones (ex-BoxerNet).

**mlpackage** — CoreML's model container format. Directory, not a file.
Native to iOS.

**ANE** — Apple Neural Engine. The dedicated ML accelerator on A-series
/ M-series chips. BoxerNet lands 815/815 ops on ANE after native CoreML
conversion.

**SceneKit** — Apple's 3D rendering framework. `ARSCNView` bridges
ARKit's world coordinates to SceneKit's scene graph automatically.

**Shader modifier** — SceneKit feature for injecting Metal shader snippets
into specific pipeline entry points (`.geometry, .surface, .lighting,
.fragment`) without writing a full shader program. We use `.surface` for
the plane dot overlay.

**COCO** — Common Objects in Context. 80-class image dataset; YOLO11n's
training classes.

**USDZ** — Apple's AR-oriented 3D file format. Zip of USD. Blender and
most DCC tools can export it.

**LiDAR** — Light Detection And Ranging. iPhone Pro / Pro Max dedicated
depth sensor (~1 m range, sparse grid). `ARFrame.sceneDepth.depthMap`
exposes it.

**PBXFileSystemSynchronizedRootGroup** — Xcode 16 project-format feature
that auto-includes files based on filesystem contents. No manual
pbxproj surgery for adding/removing files.
