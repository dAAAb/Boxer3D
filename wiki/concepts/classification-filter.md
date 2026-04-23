---
title: Scene-recon classification filter
updated: 2026-04-23
source: boxer/FSDMode.swift (makeFilteredFaceElement)
---

# Classification filter

ARKit's scene reconstruction outputs a rough tessellated mesh of the real
environment with a per-face `ARMeshClassification` label:
`.none / .floor / .wall / .ceiling / .table / .seat / .window / .door`.

We **drop** `.none + .floor + .wall + .table` before rendering.

## Why drop these four

- **`.none`** — unclassified clutter. The classifier tags small, irregular,
  or moving objects (cups, laptops, books on a desk, the cat) as `.none`
  because they don't match any trained class. Rendering them produces
  "bumps on the surface" that jitter every ARKit update — the user
  complained about "渣渣 on big planes that keep growing" in v0. Drop.

- **`.floor / .wall / .table`** — plane-friendly surfaces. These are
  already covered by the [plane dot overlay](plane-dot-overlay.md) on
  ARPlaneAnchors. Rendering both the raw scene-recon triangles *and* the
  clean plane overlay causes two problems:
  1. Per-frame classifier flicker — the same triangle flips between
     `.floor` and `.none` as the mesh updates, so the noise pattern
     visually "boils".
  2. The ragged scene-recon mesh contradicts the clean dot grid — looks
     worse than either alone.

  Drop from scene-recon and let the plane anchor own that surface.

## Why we keep these four

- **`.ceiling`** — rarely has a plane anchor (ARKit under-detects them;
  faces are usually out-of-frame until you look up).
- **`.seat / .window / .door`** — furniture curves, glass, door frames.
  Plane detection misses these; scene-recon is the only source of
  geometry for them.

## Implementation

`makeFilteredFaceElement` in `FSDMode.swift:174`. Walks the
`ARMeshGeometry.faces` index buffer, reads the classification byte for
each face, appends the triangle to a `[UInt32]` if the class is kept.
Returns an `SCNGeometryElement` pointing at the kept-indices `Data`.

The raw face buffer keeps its original stride (16 or 32-bit); we normalise
the output to `UInt32` regardless of input.

When `meshGeom.classification` is missing (shouldn't happen on supported
devices but defensive), we pass the full face list through unchanged.

## Tesla analogue

OccNet renders ground-class occupancy cleanly; foreground objects are a
separate channel handled by the agent-mesh pipeline. For us, BoxerNet +
USDZ ghost meshes on tracked detections occupy that foreground channel —
so dropping `.none` from the scene-recon mesh is analogous, not a loss.
