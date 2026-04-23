---
title: FSDMode.swift
updated: 2026-04-23
source: boxer/FSDMode.swift
---

# FSDMode

Everything Tesla-FSD-screen related. Self-contained file; no other component
depends on its internals — they only touch the exposed enums and the five
free functions below.

## Public surface

- `enum BoxerPalette` — `.cameraGhost` (white translucent) / `.fsdSolid` (dark grey).
- `enum FSDRenderMode` — 4-state cycle: `.camera`, `.whiteOnWhite`, `.whiteOnDark`, `.blackOnWhite`.
  - `.next` → next enum case (wrap-around)
  - `.showsEnvironmentOverlay: Bool`
  - `.boxerPalette: BoxerPalette`
  - `.backgroundContents: Any?` — `nil` means "show camera feed"
  - `.fogColor: UIColor` + `.usesFog: Bool`
  - `.buttonLabel: String` — `FSD / W·W / W·D / B·W`
- `enum FSDStyle` — namespaced tuning constants (below).
- `func makeSceneReconGeometry(from:) -> SCNGeometry`
- `func installDotOverlay(on:anchor:meshAnchors:)`
- `func robustPlaneY(for:meshAnchors:) -> Float?`
- `func contactShadowImage() -> UIImage`
- `func addContactShadow(to:size:) -> SCNNode`
- `func applyBoxerPalette(_:to:)`

All `@MainActor` — SceneKit mutation is main-thread-only anyway.

## FSDStyle constants

| Constant | Value | What it controls |
|---|---|---|
| `backgroundColor` | white 0.96 | "White void" background in W·W / W·D modes. |
| `fogColor` | white 0.99 | Fog fades distance **to white** (not black). |
| `fogStart / fogEnd` | 3 / 9 m | Kitchen-scale range. |
| `objectSolidColor` | white 0.32 | Dark-grey solid palette for `.fsdSolid`. |
| `sceneReconColor` | white 0.82 | Scene-recon mesh tint. |
| `dotColor` | white 0.72 | Plane overlay dot colour (tuned 2026-04-23 from 0.45). |
| `dotSpacingM` | 0.05 m | 5 cm between dots, metric regardless of plane size. |
| `dotFrac` | 0.10 | Dot radius = 10 % of cell (tuned from 0.18). |
| `dotFadeStart` | 0.65 | Radial alpha fade begins at 65 % toward edge. |
| `planeHeightOffsetM` | −0.02 m | Fallback offset when robustPlaneY can't collect enough samples. |
| `robustPlaneMinSamples` | 30 | Below this → fall back to `planeHeightOffsetM`. |
| `robustPlanePercentile` | 0.10 | 10th percentile of `.floor/.table` vertex Ys. |
| `robustPlaneYWindowM` | 0.25 m | ±25 cm vertical window around ARKit's fitted Y. |
| `contactShadowSizeMultiplier` | 1.35 | Shadow decal = max(w, d) × this. |
| `contactShadowOpacity` | 0.45 | Peak alpha of the radial gradient. |

## Function roles

- **`makeSceneReconGeometry`** — builds an `SCNGeometry` from an
  `ARMeshGeometry`. Calls `makeFilteredFaceElement` internally, which drops
  `.none / .floor / .wall / .table` classified faces. See
  [classification-filter.md](../concepts/classification-filter.md).

- **`installDotOverlay`** — attaches a dot-grid SCNPlane to a plane anchor
  node. Metal shader modifier draws the dots + radial fade. For horizontal
  planes, Y is overridden by `robustPlaneY` output when enough samples are
  available. See [plane-dot-overlay.md](../concepts/plane-dot-overlay.md)
  and [robust-plane-y.md](../concepts/robust-plane-y.md).

- **`robustPlaneY`** — returns the 10th-percentile world-space Y of
  `.floor / .table` classified vertices within the plane's XZ footprint
  (+10 % pad) and ±25 cm vertical window. Returns `nil` when fewer than
  30 samples qualify — caller falls back to `planeHeightOffsetM`.

- **`contactShadowImage`** — lazy-cached `UIImage` of a radial gradient
  (alpha `contactShadowOpacity` → 0). One allocation for the app lifetime.

- **`addContactShadow`** — SCNPlane decal, `-size.y/2 + 0.001` in local Y
  so it sits at the object's bottom, flat on XZ. `renderingOrder = 50`
  (between dot overlay at 100 and default at 0). Returns the node so the
  caller can toggle visibility when mode changes.

- **`applyBoxerPalette`** — swaps the ghost/solid palette on a tracked
  object's mesh container or wireframe. Mesh containers (`geometry == nil`)
  deep-recurse into children's materials; wireframes (carry geometry
  directly) write one diffuse. See
  [dual-palette-swap.md](../concepts/dual-palette-swap.md).

## Metal shader modifier

Dot grid + radial fade, inline as a `String` constant `Self_dotShader`.
Entry point `.surface`. Writes `_surface.diffuse.a` based on `fract(uv *
cells)` distance from cell centre, then radial fade. RGB comes from the
material's diffuse contents.

Tiny enough that pulling it into a standalone `.metal` file isn't worth
the build-system friction.
