---
title: Plane dot overlay
updated: 2026-04-23
source: boxer/FSDMode.swift (installDotOverlay, Self_dotShader)
---

# Plane dot overlay

The Tesla "feel the road" dot grid on detected ARPlaneAnchors. One SCNPlane
sized to the anchor's extent, painted with a Metal shader modifier that
writes alpha based on a UV-space dot mask × radial edge fade.

## Shader body

Entry point: `.surface`. Inline `String` in `FSDMode.swift`.

```metal
#pragma arguments
float cellsU;       // uv.x scales to this many dots across
float cellsV;       // uv.y likewise
float dotFrac;      // dot radius / cell half-width
float fadeStart;    // begin radial alpha fade at this fraction toward edge

#pragma body
float2 uv = _surface.diffuseTexcoord;
float2 cell = uv * float2(cellsU, cellsV);
float2 f = fract(cell) - 0.5;
float d = length(f);
float dot = 1.0 - smoothstep(dotFrac * 0.85, dotFrac * 1.15, d);

float2 rel = abs(uv - 0.5) * 2.0;
float edge = max(rel.x, rel.y);
float fade = 1.0 - smoothstep(fadeStart, 1.0, edge);

_surface.diffuse.a = dot * fade;
```

- `cellsU / cellsV` = `planeWidth / dotSpacingM` → 5 cm metric spacing
  regardless of plane size (4 m floor vs 40 cm tabletop → same visual
  density).
- `dotFrac * 0.85 / 1.15` → 30 % anti-alias band. No hard edge.
- Radial fade uses `max(|u|, |v|)` (square-distance) so a non-square plane
  fades to the nearest edge, not the geometric centre.

## Material flags

```swift
material.lightingModel = .constant     // flat dot colour, no shading
material.diffuse.contents = FSDStyle.dotColor   // white 0.72
material.writesToDepthBuffer = false   // don't occlude ghosts behind
material.readsFromDepthBuffer = true
material.blendMode = .alpha
```

The `writesToDepthBuffer = false` is important — otherwise a large floor
overlay z-tests out tracked objects that float above it.

`renderingOrder = 100` so the decal composites on top of any residual
scene-recon fragments (e.g. a leftover ceiling face that happens to share
the plane's Y).

## Why SCNPlane + rotate-to-horizontal

`SCNPlane` lies in local XY with normal `+Z`. `ARPlaneAnchor` (both
horizontal and vertical alignments) exposes its plane in local XZ with
normal `+Y`. Rotate `-π/2` on X to align — same rotation works for both
alignments.

## Vertical planes

Walls get the same dot treatment. No Y correction needed (there's no
plane-fit overshoot in the vertical direction). Floors and tables use
[robust-plane-y.md](robust-plane-y.md) to sidestep ARKit's upward bias
from surface clutter.

## didUpdate handling

`installDotOverlay` tears down any existing overlay and rebuilds. Cheap —
planes update at ~1 Hz and the overlay is a single quad with 4 vertices.
Simpler than in-place mutation.

## Tuning history (2026-04-23)

User feedback after first deploy:

| Constant | v0 | Tuned | Feedback |
|---|---|---|---|
| `dotFrac` | 0.18 | **0.10** | "too big" — dots shrank to ~half |
| `dotColor` | white 0.45 | **0.72** | "too dark" — lifted into light-grey |
| `planeHeightOffsetM` | 0 | **−0.02** | "estimated too high" — offset fallback |

The `planeHeightOffsetM` fix was later superseded by `robustPlaneY`, but
kept as a fallback path for cold-start / sparse-recon cases.
