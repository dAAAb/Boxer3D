---
title: ARViewModel.swift
updated: 2026-04-23
source: boxer/ARViewModel.swift
---

# ARViewModel

The orchestrator. Single `@MainActor` class holding:

- the `ARSCNView` reference,
- loaded [`YOLODetector`](yolodetector.md) and [`BoxerNet`](boxernet.md) instances,
- the [`MeshLibrary`](meshlibrary.md),
- the track list `[KnownDetection]`,
- render state (`renderMode`, scene-recon nodes, plane overlay nodes),
- all SwiftUI-observable properties that [`ContentView`](contentview.md) reads.

## NSObject subclass

```swift
final class ARViewModel: NSObject, ObservableObject {
    override init() { super.init() }
    ...
}
```

Needs to be `NSObject` so it can conform to `ARSCNViewDelegate`
(Objective-C protocol). The manual `override init()` is required because a
custom `NSObject` subclass doesn't synthesize one.

## KnownDetection

Private struct. Represents one live tracked OBB.

```swift
struct KnownDetection {
    let id: UUID
    let label: String
    let instanceIndex: Int     // "bottle #3"
    var worldCenter: simd_float3   // rendered position — driven by spring
    let size: simd_float3           // frozen on creation
    let node: SCNNode               // mesh OR empty container (used as parent)
    let wireframeNode: SCNNode      // line-geometry OBB frame
    let shadowNode: SCNNode?        // radial-gradient decal
    var targetTransform: simd_float4x4   // latest observation; spring goal
    var velocity: simd_float3 = .zero
    var lastSeen: CFTimeInterval
    var hits: Int = 1                // track-confirmation counter
    var reaping: Bool = false        // fade-out scheduled
}
```

Concepts this touches:
[spring-tween](../concepts/spring-tween.md),
[track-hysteresis](../concepts/track-hysteresis.md),
[mot-graveyard](../concepts/mot-graveyard.md),
[contact-shadow](../concepts/contact-shadow.md).

## Main flows

### `detectNow()`
Read the current `ARFrame`, bump `cycleToken`, spawn a detached `Task` that
calls `runPipeline`. Completions with a stale token are dropped on
MainActor — this is how `abandonInFlightCycle()` (called from memory-warning
handler) cancels in-progress work cleanly.

### `runPipeline(frame:boxer:yolo:)` (nonisolated)
The inference pipeline. Three parallel preprocess tasks, then YOLO and
BoxerNet depth-prep in parallel, then the BoxerNet forward. See
[architecture.md](../architecture.md) for the full diagram. One important
detail: YOLO boxes that project into an existing confirmed track's
2D-projected footprint are dropped — this prevents the fixed
`numBoxes = 3` budget being spent re-detecting things we already track. See
[static-num-boxes.md](../concepts/static-num-boxes.md).

### `placeBoxes(_:in:)` (MainActor)
Greedy nearest-centroid matching (label-gated) between new detections and
existing tracks. Unmatched detections first probe the
[mot-graveyard](../concepts/mot-graveyard.md) via `tryResurrect` to
recover a recently-dead UUID; only on a graveyard miss do they become
brand-new tracks. New tracks get a wireframe, an optional USDZ ghost
mesh from [`MeshLibrary`](meshlibrary.md), and a contact-shadow decal.
Palette is applied on creation so new boxes match the current render
mode — crucial for stable FSD mode visuals (see
[fsd-palette.md](../concepts/fsd-palette.md)).

### `tickTracks()` (called 33 Hz from ContentView)
Advances the critical-damped spring on every non-reaping track, snaps to
target when both delta and velocity are below 0.5 mm, then ages out
tracks. See [spring-tween.md](../concepts/spring-tween.md) and
[track-hysteresis.md](../concepts/track-hysteresis.md).

### `toggleFsdMode()` / `applyRenderMode(_:)`
4-state cycle. `applyRenderMode` is the single point that touches every
visual side-effect: background, fog, scene-recon visibility, plane overlay
visibility, per-object palette, per-object shadow visibility. Safe to call
from init or after a state change. See
[fsd-palette.md](../concepts/fsd-palette.md).

### `toggleStream()`
Flips `streamMode`. On activation: clears the "last detection camera
transform" so the first cycle always fires, then calls `detectNow`. On
deactivation: cancels the pending motion-check task. See
[stream-mode.md](../concepts/stream-mode.md).

### `toggleSelect(_:)` + `setHighlight(_:)`
Long-press toggles selection on a detection card. Selected wireframe gets a
yellow tint + a repeated scale pulse (`1.00 → 1.12 → 1.00` over 0.9 s). The
mesh inside gets a warm yellow `.multiply` tint so any baked AO texture on
the diffuse channel still shows through.

### `updateOffscreenHint()`
See [offscreen-arrow.md](../concepts/offscreen-arrow.md).

## Scene-reconstruction & plane delegate methods

```swift
extension ARViewModel: ARSCNViewDelegate {
    func renderer(_:didAdd:for:) { ... }    // ARMeshAnchor / ARPlaneAnchor
    func renderer(_:didUpdate:for:) { ... }
    func renderer(_:didRemove:for:) { ... }
}
```

All three are `nonisolated` (ARKit calls on its render thread) and
immediately `Task { @MainActor in ... }` into main to mutate
`sceneReconNodes` / `meshAnchors` / `planeOverlayNodes`.

Scene-recon updates rebuild the `SCNGeometry` via
[`makeSceneReconGeometry`](fsdmode.md); plane updates refresh the dot
overlay via `installDotOverlay` which calls
[`robustPlaneY`](../concepts/robust-plane-y.md) with the current
`meshAnchors` snapshot.

## Key constants

| Name | Value | Why |
|---|---|---|
| `maxKnown` | 50 | Hard cap on accumulated tracks. Native CoreML + 2-node line wireframes give us much more head-room than the old ORT era. |
| `motionTranslationThreshold` | 0.20 m | (legacy — no longer gates stream mode, see `scheduleNextWhenMoving`) |
| `motionRotationThreshold` | 0.35 rad (~20°) | same |
| `cycleCooldownMs` | 30 | Avoid back-to-back ANE submissions. |

## Memory warning handler

Registered on `setup(sceneView:)`. On low-memory notification: force stream
off, abandon in-flight cycle, surface "Low memory — stream paused" status.
Observer is removed in `deinit`. See [gotchas.md](../gotchas.md#memory).
