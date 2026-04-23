---
title: Robust plane Y (10th-percentile surface fit)
updated: 2026-04-23
source: boxer/FSDMode.swift (robustPlaneY)
---

# Robust plane Y

Horizontal ARPlaneAnchors systematically fit *above* the true surface when
there's clutter on top (cups, books, laptop on a desk). ARKit's plane
fitter treats those object-base vertices as plane samples, and because
they're all slightly above the real surface, the regression pulls Y
upward by ~1–5 cm depending on scene.

Our dot overlay is supposed to read as "the surface". Floating 3 cm above
the table makes objects look like they hover.

## Fix: 10th-percentile scan over classified vertices

`robustPlaneY(for:meshAnchors:)`:

1. For each `ARMeshAnchor` in the live set, iterate faces.
2. Keep only faces classified `.floor` or `.table`.
3. For each kept face's 3 vertices, transform local → world.
4. Keep vertices within:
   - XZ: `planeExtent × 0.55` of the anchor centre (10 % pad)
   - Y: `±robustPlaneYWindowM (0.25 m)` of the anchor's fitted Y
5. If count `< robustPlaneMinSamples (30)` → return `nil` (caller falls
   back to `planeHeightOffsetM = −0.02`).
6. Sort, return the 10th percentile (`robustPlanePercentile = 0.10`).

The low percentile is the key insight: clutter biases Y upward, so the
real surface lives at the *bottom* of the Y distribution. 10 % (not 0 %)
gives noise immunity — a single mesh-reconstruction glitch that
undershoots by 3 cm won't drag the estimate down.

## Why `.floor` and `.table` (and not `.none`)

`.none` includes the clutter we're trying to exclude — using it would
defeat the point. Only the faces the classifier thinks are "plane
surface" count.

## Why ±25 cm window

Wider = more samples, more robust. Too wide = swallows a neighbouring
higher/lower surface (e.g. a chair seat ~45 cm above the floor). 25 cm is
the empirical sweet spot for kitchen / living-room scenes on iPhone 15
Pro Max; re-tune for warehouse / outdoor.

## Applying the correction

```swift
if anchor.alignment == .horizontal,
   let robustY = robustPlaneY(for: anchor, meshAnchors: meshAnchors) {
    let currentWorldY = (anchor.transform * simd_float4(anchor.center, 1)).y
    offsetY = robustY - currentWorldY
} else if anchor.alignment == .horizontal {
    offsetY = FSDStyle.planeHeightOffsetM   // -2 cm fallback
}
```

Offset is applied in the plane node's local frame — correct because the
anchor's local +Y is world +Y for horizontal planes.

## Vertical planes

Not corrected. No analogous upward bias on walls (clutter usually isn't
pressed flat against a wall in the same way).

## History

v0: nothing. Visible overshoot on every table.
v1: fixed `-0.02 m` heuristic. Good enough for most tables, wrong for floors.
v2 (this): vertex-based percentile. Scales correctly because every
surface gets its own sample-based Y.

## Cost

One linear pass over live mesh faces per plane didUpdate (~1 Hz). On
iPhone 15 Pro Max with typical room-scale scene (~10 k mesh faces, 4
planes) it's under 1 ms. Negligible.
