---
title: ARViewContainer.swift
updated: 2026-04-23
source: boxer/ARViewContainer.swift
---

# ARViewContainer

`UIViewRepresentable` that wires a fresh `ARSCNView` into the SwiftUI
hierarchy and hands it to [`ARViewModel.setup`](arviewmodel.md).

## What gets configured

```swift
sceneView.autoenablesDefaultLighting = true
sceneView.antialiasingMode = .multisampling2X    // 4× drops FPS noticeably
```

Extra ambient fill light (white 0.7) is added as a child of the root node so
the shadowed side of the ghost mesh doesn't go pitch-black. Pairs with the
`applyGhostMaterial` settings in [MeshLibrary](meshlibrary.md) (bright ambient
reflectivity on the material itself).

## ARWorldTrackingConfiguration

```swift
config.frameSemantics  = [.sceneDepth]                          // LiDAR depth
config.planeDetection  = [.horizontal, .vertical]               // FSD overlay
config.sceneReconstruction = .meshWithClassification            // if supported
```

All three are always on. Scene reconstruction is enabled even in `.camera`
mode (not just FSD) so the first FSD toggle is instant — the mesh is already
populated. Cost on A17 is a few ms/frame; acceptable.

Plane detection drives the Tesla "feel the road" dot overlay
([plane-dot-overlay.md](../concepts/plane-dot-overlay.md)); scene
reconstruction feeds the environment mesh for surfaces the plane fit
doesn't cover (ceilings, curved furniture — see
[classification-filter.md](../concepts/classification-filter.md) for which
classes survive the filter).

## updateUIView

Empty. The view model retains a reference to the `ARSCNView`; SwiftUI
re-renders don't recreate the scene.

## Why `sceneView.delegate = viewModel`

`ARSCNViewDelegate` needs an `NSObject` subclass. That's why `ARViewModel`
inherits `NSObject, ObservableObject` and has an `override init()` — see
[arviewmodel.md](arviewmodel.md#nsobject-subclass) for the rationale.
