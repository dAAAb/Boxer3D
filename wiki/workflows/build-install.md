---
title: Build & install on device
updated: 2026-04-23
---

# Build & install on device

Boxer3D needs an actual iPhone with LiDAR. Simulator won't run.

## Prerequisites

- iPhone 12 Pro or newer (LiDAR required). Project tested on iPhone 15 Pro Max.
- iOS 18.0+.
- Xcode 16+.
- Apple Developer team ID (free personal works; free-tier provisioning profiles
  expire every 7 days).

## First-time setup

1. Clone: `git clone git@github.com:Barath19/Boxer3D.git && cd Boxer3D`.
2. Copy the signing template:
   ```bash
   cp Signing.xcconfig.template Signing.xcconfig
   ```
   Edit `Signing.xcconfig` with your team ID and bundle ID. This file is
   gitignored.
3. Download models from Hugging Face:
   ```bash
   pip install huggingface_hub
   huggingface-cli download Barath/boxer3d --local-dir boxer/
   ```
   Drops `BoxerNet.onnx` (391 MB) and `yolo11n.onnx` (10 MB) into `boxer/`.
   Note: the shipping app uses `BoxerNetModel.mlpackage` (native CoreML) —
   see [model-conversion.md](model-conversion.md) for how it was built.
   The `.onnx` files are legacy / reference.
4. `open boxer.xcodeproj`. SPM will auto-resolve
   [onnxruntime-swift-package-manager](https://github.com/microsoft/onnxruntime-swift-package-manager)
   v1.24.2 on first open.

## Build & run

- **From Xcode**: select your iPhone, Cmd+R.
- **From CLI**:
  ```bash
  xcodebuild \
    -project boxer.xcodeproj \
    -scheme boxer \
    -destination 'id=<your-device-udid>' \
    -configuration Debug \
    build
  ```

## Installing to device without Xcode UI

```bash
xcrun devicectl device install app \
  --device <device-udid> \
  build/Debug-iphoneos/boxer.app
```

Getting the UDID:

```bash
xcrun devicectl list devices
```

## Adding new files

Xcode 16+ uses `PBXFileSystemSynchronizedRootGroup` for the `boxer/` folder
— **just drop the file into that folder** and it's picked up automatically
on next build. No pbxproj surgery.

That applies to `.swift`, `.usdz`, `.onnx`, `.mlpackage`, assets — anything
under `boxer/` except things matched by the group's exclusion filter.

## Common build failures

- **"Cannot find type 'ARViewModel' in scope"** and similar SourceKit errors
  that `xcodebuild` doesn't reproduce → SourceKit stale index. Clean and
  reopen Xcode, or just ignore — `xcodebuild` is the source of truth.
- **"Code signing is required for product type 'Application'"** → you
  haven't set `Signing.xcconfig`. See step 2 above.
- **"No such file or directory: BoxerNetModel.mlpackage"** → drag the
  mlpackage (from `convert/output/`) into the `boxer/` folder in Xcode
  so it gets bundled. See [model-conversion.md](model-conversion.md).
