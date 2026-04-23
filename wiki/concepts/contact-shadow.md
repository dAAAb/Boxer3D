---
title: Contact shadow decal
updated: 2026-04-23
source: boxer/FSDMode.swift (contactShadowImage, addContactShadow)
---

# Contact shadow

Soft radial-gradient decal directly under each tracked object, so meshes
visually sit on the surface instead of floating. Tesla FSD uses the same
trick under cars on their render.

## Visual recipe

- Plane size = `max(object.w, object.d) × 1.35` so the blur extends past
  the silhouette.
- Diffuse = `contactShadowImage()` — a 256×256 `UIImage` with a radial
  gradient, peak alpha `0.45` at centre, 0 at edge.
- Flat on XZ (`-π/2` rotation on X).
- Positioned at `(0, -size.y/2 + 0.001, 0)` in the parent container's
  local frame — bottom-of-object plus a 1 mm epsilon to avoid Z-fighting.
- `writesToDepthBuffer = false` — don't occlude surfaces below.
- `renderingOrder = 50` — after the plane-overlay dots (100) but before
  default (0).

## Why a UIImage + UIGraphicsImageRenderer

Could use a Metal shader modifier (as the dot overlay does). Chose a cached
UIImage because:

1. The gradient is constant — allocate once in `_cachedContactShadowImage`,
   reuse.
2. No per-frame params needed.
3. Debuggable — dump the image to disk and inspect.

`UIGraphicsImageRenderer` + `CGGradient` with two colour stops (black at α
0.45, black at α 0) is trivial. One allocation for the app lifetime.

## Visibility toggle

Shadow nodes are hidden in `.camera` mode:

```swift
for k in known {
    k.shadowNode?.isHidden = !showEnv   // showEnv = (mode != .camera)
}
```

Reason: in camera-feed mode the real scene's real shadows already do this
job. Adding a synthetic shadow under the ghost mesh double-shadows and
looks wrong.

## Where it's created

`placeBoxes` in `ARViewModel` — only when a new track is born, not per
cycle. The returned `SCNNode` is stored in `KnownDetection.shadowNode`.
When the track is reaped, the shadow is removed as a child of the parent
node (automatic via `node.removeFromParentNode()`).

## Size is frozen, not animated

Object size can drift slightly between detection cycles (BoxerNet is
probabilistic), but we freeze `KnownDetection.size` on creation to keep
the wireframe and shadow sizes stable. Prevents the shadow from "breathing".
