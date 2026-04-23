---
title: Dual-palette material swap
updated: 2026-04-23
source: boxer/FSDMode.swift (applyBoxerPalette)
---

# Dual-palette swap

Tracked-object meshes have two visual states:

- **`.cameraGhost`** — the 2026-04-21 look: white Blinn-shaded,
  80 % opaque, bright ambient reflectivity. Reads well against the
  real-camera RGB feed.
- **`.fsdSolid`** — the Tesla daylight look: dark grey (white 0.32),
  fully opaque, medium ambient. Reads well against a bright void.

`applyBoxerPalette(palette:to:)` swaps an existing node's materials in
place. No geometry reload, no reparenting.

## Wireframe vs mesh-container distinction

Tracked objects in `KnownDetection` come in two topologies:

- **Wireframe node** (`wireframeNode`) — carries an `SCNGeometry` of line
  primitives directly. Single `SCNMaterial`. Swap is a one-liner:
  `mat.diffuse.contents = ...`.

- **Mesh container** (`node`, when a USDZ is available) — an empty
  `SCNNode` (no geometry) with geometry-bearing children from
  `MeshLibrary.node(for:)`. Swap iterates `enumerateChildNodes` and
  rewrites each child's material.

`applyBoxerPalette` detects which by checking `node.geometry == nil`.

## Why it doesn't fight the yellow selection tint

`paintHighlight(on:selected:)` writes to `material.multiply.contents`.
`applyBoxerPalette` writes to `material.diffuse.contents` (+ transparency
+ ambient). The two channels compose — diffuse × multiply — so the yellow
selection survives a palette flip and vice versa.

## When new tracks are born

`placeBoxes` calls `applyBoxerPalette(renderMode.boxerPalette, ...)` right
after creating the wireframe and attaching the mesh. Without this, a box
born during `.whiteOnDark` would render as `.cameraGhost` (because that's
what `MeshLibrary.applyGhostMaterial` sets up by default) and sit
inconsistently next to older, correctly-palette-d boxes.

This was the root cause of the v0 "palette looks wrong on new detections"
bug.

## Deep-copy requirement

For mesh containers, the per-child material rewrite relies on
[`MeshLibrary`](../components/meshlibrary.md) having `.copy()`'d each
`SCNGeometry` at clone time. If that deep-copy is skipped, tinting one
instance tints all siblings sharing the geometry — `SCNNode.clone()`
shares geometry by default.

## Future work

A third palette (e.g. `.selected` or classification-color) could be added
by extending the enum. The single-point rewrite in `applyRenderMode` means
you don't need to hunt down caller sites.
