---
title: BoxerNet.swift
updated: 2026-04-23
source: boxer/BoxerNet.swift
---

# BoxerNet

Native CoreML wrapper around the Meta BoxerNet model. Lifts 2D YOLO boxes
to 7-DoF oriented 3D boxes using DINOv3 features + LiDAR depth + camera
pose.

Upstream: [facebookresearch/boxer](https://github.com/facebookresearch/boxer).
Weights are **CC-BY-NC-4.0** — non-commercial only. See
[decisions.md](../decisions.md) for the native-CoreML vs ONNX Runtime
switch.

## Loading

```swift
init() throws {
    let config = MLModelConfiguration()
    config.computeUnits = .all   // 815/815 ops land on ANE for this model.
    ...
}
```

Tries `BoxerNetModel.mlmodelc` first (Xcode's pre-compiled form after drag
& drop), falls back to on-device `MLModel.compileModel(at:)` on the raw
`.mlpackage`. Either one works in the bundle.

## Static config

```swift
static let imageSize = 480       // halved from 960 → 4-6× inference speedup
static let patchSize = 16        // DINOv3 patch
static let gridH = 30            // imageSize / patchSize
static let numPatches = 900
static let numBoxes = 3          // baked into the mlpackage — see note
```

`imageSize = 480` is the "Boxer3D Flash Lv 2" setting. DINOv3 self-attention
is O(N²) in token count — halving side length ≈ quartering tokens, and the
net is still usable (some drift vs 960-trained checkpoint — acceptable for
AR scan, retrain for precision work).

`numBoxes = 3` is **static**. The converted mlpackage has a fixed input
shape `(1, 3, 4)` for `bb2d_norm` and output `(1, 3, 7)` for `params`. Up
to 3 YOLO boxes per cycle; unused slots are zero-padded and discarded. See
[static-num-boxes.md](../concepts/static-num-boxes.md) — this is the single
most constraining design choice in the app.

## Public API

### `prepareDepthInputs(depthMap:intrinsics:cameraTransform:)` (nonisolated)

Pure CPU preprocess — can run in parallel with YOLO inference.

Steps:
1. ARKit → OpenCV camera (flip Y/Z).
2. Gravity-align world → voxel frame. Z-grav convention. Returns `T_wv`.
3. SDP patches: project each LiDAR depth pixel to 480-space, median-pool per 16×16 patch → `(1, 1, 30, 30)`.
4. Plücker ray encoding: 6D per patch (direction unit-vector + moment `origin × direction`), in voxel frame → `(1, 900, 6)`.

Returns `(sdpPatches, rayEncoding, T_wv)`.

### `predict(image:sdpPatches:rayEncoding:T_wv:boxes2D:confidenceThreshold:)` (nonisolated)

Main inference path. Normalises 2D boxes into `(1, 3, 4)` with the
`(xmin + 0.5) / W` half-pixel correction, zero-pads unused slots, packs
everything into an `MLDictionaryFeatureProvider`, calls
`model.prediction(from:)`, and decodes.

Output shape:
```
params: (1, 3, 7)   = [cx, cy, cz, w, h, d, yaw]  in voxel frame
prob:   (1, 3)      confidence
```

Only the first `min(boxes2D.count, 3)` slots are decoded. For each kept
detection, rotation is built as `R_world = R_wv · R_yaw` where `R_yaw` is
a Z-axis rotation (voxel frame's Z is gravity, so yaw is
around-gravity-axis). The final `worldTransform` is `[R_world | center_world]`.

### Back-compat overload

`predict(image:depthMap:intrinsics:cameraTransform:boxes2D:confidenceThreshold:)`
calls `prepareDepthInputs` internally. Kept so the old single-call site
from the ORT era still compiles.

## fp16 gotcha

BoxerNet's attention softmax operates over 3600 patches (at 960) or 900
(at 480). In fp16, many rows saturate — all columns emit the same value,
boxes collapse to garbage centres.

**Conversion must use `--precision fp32`.** Inference runs fp16 on ANE at
runtime because `computeUnits = .all` puts the mul/adds in fp16 but CoreML
preserves the softmax numerics itself. If you re-convert and see boxes
collapsing to a single point, that's the symptom.

See [convert/README.md](../../convert/README.md) and
[gotchas.md](../gotchas.md#fp16-softmax-collapse).

## simd helpers

Private file-scope helpers for `upperLeft3x3`, `rotationZ(angle:)`, and
`simd_float4.xyz`. Nothing surprising.
