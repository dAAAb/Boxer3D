---
title: MeshLibrary.swift
updated: 2026-04-23
source: boxer/MeshLibrary.swift
---

# MeshLibrary

Class → canonical USDZ mesh lookup. Loaded once at `ARViewModel` init; each
`node(for:)` call returns a fresh clone with a deep-copied material.

## Registered labels

```swift
private static let registeredLabels = ["cup", "laptop", "keyboard", "bottle"]
```

To add a new class:

1. Author a USDZ at real-world size (see
   [workflows/mesh-authoring.md](../workflows/mesh-authoring.md)).
2. Drop it into `boxer/<label>.usdz`. The label must match the YOLO /
   COCO lowercase class name.
3. Add the label to `registeredLabels`.

Xcode 16's `PBXFileSystemSynchronizedRootGroup` auto-picks up the new file;
no pbxproj edits.

## Why `flattenedClone`

```swift
cache[label] = scene.rootNode.flattenedClone()
```

Blender-exported USDZ usually wraps the mesh under one or more intermediate
transform nodes. `flattenedClone` collapses those into a single mesh node,
which makes `clone()` on subsequent calls cheap and makes simd transforms
work against a known root.

## Deep-copy per instance

`node(for:)`:
1. `mesh = root.clone()` — shares geometry with siblings.
2. `applyGhostMaterial(to:)` walks the node tree, `.copy()`-ing every
   `SCNGeometry` so per-instance material writes don't leak to siblings.
3. Wraps the mesh in an empty container node and returns the container.

The container is what `ARViewModel` writes `simdWorldTransform` onto every
tick — the mesh inside stays at identity so any scale tweaks or palette
swaps don't fight with the transform animation.

## Ghost material

Blinn-shaded. Key fields:

```swift
mat.diffuse.contents = bakedDiffuse ?? UIColor.white
mat.ambient.contents = UIColor.white   // lift shadow side
mat.specular.contents = UIColor(white: 0.15, alpha: 1.0)
mat.shininess = 0.25
mat.transparency = 0.80                // 20% transparent
mat.isDoubleSided = true
```

If the USDZ ships a diffuse texture (e.g. baked AO), it's kept on the
diffuse channel — cup AO gradient shows through the ghost. Selection
tint (yellow) is applied via `.multiply.contents` so it composes over the
AO gradient rather than replacing it. Palette swap (FSD mode) writes
`.diffuse.contents` (+ `transparency` + `ambient`) directly — see
[dual-palette-swap.md](../concepts/dual-palette-swap.md).

## Bundle lookup fallback

If `<label>.usdz` isn't in the bundle, `MeshLibrary` prints
`[MeshLibrary] skipped — <label>.usdz not in bundle` and `node(for:)`
returns `nil`. `ARViewModel` catches `nil` and falls back to just the
wireframe OBB — no crash, just "that class doesn't have a mesh yet".
