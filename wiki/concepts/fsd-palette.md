---
title: FSD palette — 4-state render cycle
updated: 2026-04-23
source: boxer/FSDMode.swift, boxer/ARViewModel.swift
---

# FSD palette

The FSD button cycles through four render modes. Each mode is a combination
of (background, fog, environment overlay visibility, tracked-object palette).

## The four states

| State | Background | Fog | Env overlay | Object palette | Label |
|---|---|---|---|---|---|
| `.camera` | camera feed | off | hidden | `.cameraGhost` (white, 80 %) | `FSD` |
| `.whiteOnWhite` | white 0.96 | white 0.99 | visible | `.cameraGhost` | `W·W` |
| `.whiteOnDark` | white 0.96 | white 0.99 | visible | `.fsdSolid` (grey 0.32) | `W·D` |
| `.blackOnWhite` | black | black | visible | `.cameraGhost` | `B·W` |

`.whiteOnDark` is the canonical Tesla FSD look: dark-grey solid cars
floating on a bright void. `.blackOnWhite` is the Tesla night / negative
variant. `.whiteOnWhite` was an accidentally-good intermediate state that
the user specifically asked to keep.

## Why it's an enum (not a Bool)

Originally this was a Bool `fsdMode`. Toggling off set
`sceneView.scene.background.contents = nil`, which ARSCNView sometimes
honored (restoring the camera feed) and sometimes didn't. The visual
side-effect was a surprise 3-state cycle. User liked it, asked us to keep
it and add the missing "whiteOnWhite" state. Explicit enum with
deterministic transitions was safer than continuing to rely on nil
behaviour.

## applyRenderMode — single source of truth

```swift
func applyRenderMode(_ mode: FSDRenderMode) {
    renderMode = mode
    sceneView.scene.background.contents = mode.backgroundContents
    // fog on/off + colour
    // scene-recon & plane overlay visibility
    // per-object palette via applyBoxerPalette
    // per-object shadow visibility
}
```

Critical rule: **`placeBoxes` also calls `applyBoxerPalette` on newly-created
detections**, passing `renderMode.boxerPalette`. Without that, a detection
that lands during `.whiteOnDark` would render as a white ghost because
`MeshLibrary.applyGhostMaterial` is always the initial state. The v0 bug
was exactly this — mixed-palette visuals as new boxes kept the old look.

## Palette ≠ background

`.whiteOnWhite` and `.blackOnWhite` intentionally keep the `cameraGhost`
palette on objects — the white ghost reads well on both a bright void
(translucent outline) and on pure black (glowing silhouette). Only
`.whiteOnDark` swaps to `.fsdSolid` because that's the specific Tesla
daylight look.

See [dual-palette-swap.md](dual-palette-swap.md) for how the swap actually
touches the `SCNMaterial`.

## Reference

Tesla FSD 10.69.3 screenshot (Ann Arbor intersection) was the design
target. See memory note `project_boxer3d_fsd_palette.md` (external to
repo; user's `.claude/projects/` memory).
