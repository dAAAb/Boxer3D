---
title: Gotchas
updated: 2026-04-23
---

# Gotchas

Foot-guns, surprising behaviours, and things that have wasted time
before. If you're stuck, grep here first.

## Simulator doesn't work

`ARWorldTrackingConfiguration` + `.sceneDepth` require a physical LiDAR
device. The app will crash on launch in the simulator. Always run on
iPhone 12 Pro or newer.

## fp16 softmax collapse

If you re-convert BoxerNet and see every detection's centre collapse to
one point (or the whole OBB being tiny at origin), you used
`--precision fp16`. Softmax over 3600 (or 900 at imageSize=480) tokens
saturates in fp16 during conversion — **all** query rows output
identical values.

Use `--precision fp32` when running `convert/convert.py`. Runtime stays
fp16 on ANE, that's fine; the saturation is specifically a coremltools
tracing artefact.

See [concepts/coreml-native.md](concepts/coreml-native.md).

## New detections render in wrong palette

If you cycle into `.whiteOnDark` and new boxes born during that cycle
render as white ghosts (inconsistent with older boxes), check that
`placeBoxes` is calling `applyBoxerPalette(renderMode.boxerPalette, ...)`
on newly-created tracks. That single call is what keeps the palette
consistent. Was the root cause of the v0 "mixed palette" bug.

## `scene.background.contents = nil` is non-deterministic

In ARSCNView, setting the background to `nil` *mostly* restores the
camera feed, but not reliably. Don't use nil as "go back to camera mode"
logic — the 4-state FSDRenderMode enum handles this explicitly and
you should route all background changes through `applyRenderMode`.

## SourceKit false positives

Opening a Swift file in Xcode might show dozens of "Cannot find type in
scope" errors even when `xcodebuild` succeeds. SourceKit's async indexer
is stale. `xcodebuild` is ground truth; ignore SourceKit or relaunch
Xcode if it bothers you. Never "fix" phantom errors.

## MeshLibrary: sibling tinting bleed

`SCNNode.clone()` shares geometry across siblings. If `MeshLibrary`
stopped deep-copying materials (`geometry.copy()`), tinting one cup would
tint all of them. This is a latent bug waiting to happen if anyone
"simplifies" `MeshLibrary.installMaterial`. The deep-copy is load-bearing.

## Xcode 16 project sync

`boxer/` is a `PBXFileSystemSynchronizedRootGroup`. Drop files in, they
auto-include. Do **not** manually edit `project.pbxproj` to add files —
you'll corrupt the sync state. Let Xcode 16 handle it.

If Xcode fails to pick up a new file, clean the build folder (Shift+Cmd+K)
and reopen the project; the sync state rebuilds from the filesystem.

## App size {#app-size}

The repo currently ships three ONNX files that aren't loaded at runtime:

```
boxer/BoxerNet.onnx         (~400 MB)
boxer/BoxerNet_static.onnx  (~400 MB)
boxer/BoxerNet_static_fp16.onnx (~200 MB)
```

These are legacy reference dumps from the pre-native era. Runtime uses
`BoxerNetModel.mlpackage`. Before any public release, strip these from
the bundle (they'll still live in git history for reference). They bloat
the IPA from ~200 MB to well over 1 GB.

TODO in [todos.md](todos.md).

## Memory {#memory}

The app registers a `didReceiveMemoryWarning` handler that force-stops
stream mode and abandons any in-flight detection cycle. This was added
after the ORT era where stream mode could run the device OOM.

Native CoreML dropped per-cycle memory pressure dramatically but the
safety net is still valuable; don't remove it.

## ARKit coordinate-frame confusion

Three frames in play — [architecture.md](architecture.md#coordinate-frames)
has the summary. Common mistake: passing ARKit camera transform directly
to BoxerNet expecting OpenCV convention. The `flipYZ` multiply in
`prepareDepthInputs` bridges them. Don't bypass it.

## YOLO vs BoxerNet size normalisation

YOLO runs at 640×640, BoxerNet at 480×480. YOLO boxes are in pixel coords
at 640-space; they need `× (480/640)` scaling before packing into
`bb2d_norm`. Easy to forget if you refactor the pipeline.

## COCO labels are positional

`YOLODetector.classNames` is indexed by position into the 84-row output
tensor. Don't reorder. Don't remove entries — append only (and bump the
class-count check if you add beyond 80).

## USDZ real-world size

Meshes must be authored at real-world size. `MeshLibrary` does no runtime
scaling — it just clones and re-skins. If you export a laptop at 62 cm
instead of 31 cm, every detection of a laptop will render a mesh twice
the detected OBB.

See [workflows/mesh-authoring.md](workflows/mesh-authoring.md#blender-scale-bug).

## `Signing.xcconfig` is gitignored

`.gitignore` excludes `Signing.xcconfig` because it contains your personal
team ID. Use `Signing.xcconfig.template` as the starting point. If you
accidentally committed signing info, `git rm --cached Signing.xcconfig`
and rotate it.

## Git LFS? No.

This repo uses plain git for the onnx/mlpackage/usdz files. The onnx
files are huge (200–400 MB) and slow to clone. Consider migrating to
git-lfs if the repo starts to annoy contributors — but note that Hugging
Face is the canonical storage for the onnx weights anyway (see
`README.md`).
