---
title: YOLODetector.swift
updated: 2026-04-23
source: boxer/YOLODetector.swift
---

# YOLODetector

ONNX Runtime wrapper around `yolo11n.onnx`. Why still ONNX Runtime here
(vs native CoreML like [`BoxerNet`](boxernet.md)): YOLO11n is small (10 MB),
fits ONNX Runtime's CoreML EP partitioning cleanly, and rebuilding the
whole conversion pipeline for a second model wasn't worth it. If you port
it later, follow the same pattern as `convert/` and drop the ORT dependency
entirely.

## Session construction

```swift
let opts = try ORTSessionOptions()
try opts.setGraphOptimizationLevel(.all)
try opts.setOptimizedModelFilePath(yoloOptimizedModelPath())
try opts.appendCoreMLExecutionProvider(withOptionsV2: [
    "MLComputeUnits": "CPUAndGPU",              // not ANE — see note
    "ModelCacheDirectory": cacheDir,
])
```

**MLComputeUnits = `CPUAndGPU`.** Explicit — ANE is excluded. Reason:
several YOLO11n ops (e.g. slices with non-constant shapes after NMS-related
preprocessing) don't map cleanly to ANE; forcing `.all` partitions the
graph into many sub-models with CPU fallbacks at every boundary, losing
more time to bridging than it saves on ANE. `CPUAndGPU` leaves it on the
GPU with a single CoreML compiled model. See
[decisions.md](../decisions.md).

Optimized model is persisted to `Caches/ort-optimized/yolo11n.ort` so the
next launch skips the graph-optimizer warm-up.

## detect(image:imageWidth:imageHeight:confThreshold:iouThreshold:)

`nonisolated` — call from any task.

Input: CHW float32 `[0, 1]`, length `3 * 640 * 640`. Fed as a
`(1, 3, 640, 640)` ORTValue.

Output decoding:
```
output0 shape:  (1, 84, 8400)
stride:          8400 (one anchor per column)
row  0..3:       cx, cy, w, h (pixel coords, 640-space)
row  4..83:      80 class scores
```

Decoding loop picks `argmax` over 80 classes per anchor, keeps anchors
where `max ≥ confThreshold` (default 0.25), converts `xywh → xyxy`, then
runs NMS with label-gated IoU suppression (`iouThreshold` default 0.45).

Result is `[YOLOBox]` with pixel-space coords in 640-space — the downstream
BoxerNet caller scales by `480 / 640` before packing into `bb2d_norm`.

## COCO classes

Hardcoded `classNames: [String]` in order. Don't reorder — indices are
positional into the 84-row output tensor.

## Sendable

`@unchecked Sendable` because the `ORTSession` + `ORTEnv` are thread-safe
by design but not annotated that way in the Swift package. Fine for our
usage (single-reader).
