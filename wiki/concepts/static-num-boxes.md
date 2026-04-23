---
title: Static numBoxes = 3
updated: 2026-04-23
source: boxer/BoxerNet.swift, convert/
---

# Static `numBoxes = 3`

The converted BoxerNet `.mlpackage` has a **fixed** input shape for the
`bb2d_norm` tensor: `(1, 3, 4)`. The output `params` is likewise `(1, 3, 7)`.
Each inference call processes up to 3 YOLO boxes; unused slots are
zero-padded and the corresponding outputs discarded.

## Why static

Dynamic-shape ops (`Size`, `Clip` with dynamic bounds, etc.) were the main
reason ONNX → CoreML conversion choked. Making `numBoxes` a graph
constant sidesteps several of those ops entirely.

## Why 3

Empirical. In typical kitchen / desk scenes, 2–3 objects in view is the
common case, 4+ is rare. A static budget must cover the common case
without being so large that padding dominates compute time. 3 was the
sweet spot for latency vs. coverage.

If the scene has more than 3 candidate YOLO boxes, `ARViewModel` picks
the top 3 by YOLO confidence *after* dropping boxes that project into an
existing confirmed track (see
[track-hysteresis.md](track-hysteresis.md)). So tracked objects don't
waste slots on themselves.

## Consequences

- **Upper-bound 3 new detections per cycle.** A room full of cups gets
  painted 3-at-a-time across cycles.
- **Cycle time is constant** regardless of scene complexity (unlike a
  dynamic-shape model where 1 box would be faster than 6).
- **No "one cycle re-detects everything"** — the tracker is the
  persistence layer.

## Changing it

If you need to bump to `numBoxes = 5` or `10`:

1. In `convert/convert.py` / `wrapper.py`, change the traced shape for
   `bb2d_norm` and re-export.
2. Update `BoxerNet.swift:numBoxes` to match.
3. Re-benchmark — not free, the DINOv3 attention cost doesn't scale with
   numBoxes but the head output layers do.

Don't try to make it dynamic unless you're ready to re-validate the whole
coremltools conversion path.

## Related

[coreml-native.md](coreml-native.md),
[components/boxernet.md](../components/boxernet.md),
[decisions.md](../decisions.md).
