---
title: Native CoreML vs ONNX Runtime
updated: 2026-04-23
source: convert/README.md, boxer/BoxerNet.swift
---

# Native CoreML (for BoxerNet)

BoxerNet used to run through ONNX Runtime's CoreML Execution Provider on
the ONNX export. It now runs as a native `.mlpackage`. YOLO11n is still
ORT + CoreML EP — the costs justify the switch only for the large model.

## The ORT + CoreML EP problem (for BoxerNet)

ONNX Runtime's CoreML EP partitions the graph into sub-models that CoreML
can handle, falling back to CPU for the rest. For BoxerNet:

- **136 partitions**.
- **211 CPU-fallback nodes**.
- Model duplicated in memory: ONNX Runtime holds the original graph, CoreML
  holds a compiled cache. ≈ 2× weight memory.
- Every partition boundary is a GPU ↔ CPU bridge.

Symptoms on iPhone 15 Pro Max: ~380 ms/cycle, memory pressure, occasional
`didReceiveMemoryWarning` under stream mode.

## Native `.mlpackage` benefits

- Whole graph in one model.
- Single copy in memory (~190 MB fp16 weights).
- **815/815 ops on ANE** when `computeUnits = .all`.
- ~180 ms/cycle — ~2× speedup.

## The conversion pipeline

Lives in `convert/`. See [workflows/model-conversion.md](../workflows/model-conversion.md)
for the step-by-step.

Dead ends hit on the way:

- **ONNX → CoreML via coremltools**: choked on `Size` (dynamic shape),
  `Clip` with dynamic bounds, `FusedMatMul`.
- **fp16 compute at conversion**: softmax over 3600 tokens collapses —
  all rows output identical values.
- **int8 weight quantization**: `params` diverge by up to 22 cm / 13° vs
  fp32 — borderline acceptable, kept optional.

Solutions in `convert/wrapper.py` and `convert/convert.py`:

- `BoxerNetTensorOnly` wrapper strips the camera/pose dict plumbing, takes
  4 plain tensors.
- Monkey-patched `F.scaled_dot_product_attention` to explicit
  `softmax(QK^T/√d) V` form (fused op didn't trace cleanly under
  coremltools 9).
- `--precision fp32` at conversion. Runtime still fp16 on ANE — CoreML
  preserves softmax numerics itself.

## Why YOLO11n stayed on ORT

- Small (10 MB). Memory benefit of native CoreML is marginal.
- ORT's graph optimizer partitions cleanly with `CPUAndGPU` units (no ANE
  fallback churn — ANE-unfriendly ops push the whole thing to GPU cleanly).
- Rebuilding the conversion pipeline for a second model wasn't worth it.
- Optimized ORT graph cached to `Caches/ort-optimized/yolo11n.ort`, so
  startup is fast.

If you ever do port YOLO to native CoreML, follow the same `convert/`
pattern.

## BoxerNet fp16 at runtime vs fp32 at conversion

Important distinction:

- **Conversion precision = `fp32`** — model weights exported in fp32.
  Ensures softmax doesn't collapse during graph construction.
- **Runtime precision = fp16** — CoreML's `computeUnits = .all` runs fp16
  on ANE. That's OK because CoreML's softmax kernel maintains higher
  internal precision; the original PyTorch softmax-over-3600 saturation
  was a coremltools tracing issue, not a runtime one.

If you re-convert and see detections collapsing to a single point, check
your `--precision` flag.
