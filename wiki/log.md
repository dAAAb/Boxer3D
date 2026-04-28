---
title: Boxer3D wiki — log
updated: 2026-04-28
---

# Log

Append-only. Newest on top. Format: `## [YYYY-MM-DD] <kind> | <title>`.
`<kind>` ∈ { `ingest`, `decision`, `ship`, `bug`, `lint`, `handoff`, `note` }.

Grep: `grep "^## \[" wiki/log.md | head -20`.

---

## [2026-04-28] ship | Step 3.14 — MOT tracklet graveyard (UUID stitching)

Fixed cup-blinks-and-gets-renamed every few seconds even with phone +
cup both still. Two complementary changes in `boxer/ARViewModel.swift`:

1. Dropped `where !k.reaping` filter from the matching loop. The
   `updateTrack` revival path (cancel fadeOut, opacity → 1,
   `reaping = false`) was already there but unreachable; reaping
   tracks now compete for matches and revive in the 0.3 s fade window.
2. Added `graveyard: [GraveyardEntry]` parallel to `known`. On
   `finalReap`, the dying track's UUID + label + size + last
   centre/velocity is stashed for `graveyardTTL = 2 s`. New unclaimed
   detections call `tryResurrect` first; geometric match (label,
   distance with velocity extrapolation, vol-ratio ≥ 0.7) revives the
   old UUID instead of allocating a new one. `cleanGraveyard` ages
   entries via `tickTracks`.

Resurrection thresholds intentionally stricter than live `matchScore`
on shape (vol-ratio 0.7 vs 0.6) and looser on distance (gate 0.5 ×
maxDim, 0.15 m floor vs 0.4 × maxDim / 0.12 m). False resurrection
silently corrupts identity; missed resurrection only costs a visible
UUID rotation, so we'd rather miss than alias.

Touched: `boxer/ARViewModel.swift`, `wiki/concepts/mot-graveyard.md` (new),
`wiki/components/ARViewModel.md` (cross-link).

## [2026-04-25] ship | Bridge live tracking + direct pickup + UUID body naming

Iterations on the Step 2d baseline to get real-world-to-sim tracking
usable: cup moves in reality → cup moves in sim, two cups in the scene
can be pickup-targeted individually.

Three root causes surfaced and got fixed:

1. BoxerNet MOT reaps silent tracks → the detections array shifts
   indexes → body names keyed on index stopped matching. Switched to
   `stream_{label}_{trackUUID}`; reorders now harmless.
2. 10 Hz qpos teleport left 100 ms gaps where gravity visibly pulled
   freejoint bodies. Moved the teleport inside the `mj_step` inner loop
   so it runs at physics rate; paused during `sequenceAnimator.running`
   so pickup animations can actually carry.
3. `isIdleTimerDisabled = true` on `SceneReportStreamer.start()` — iOS
   lock-screen was pausing ARKit after ~30 s and freezing tracks.

Added `worldYawDeg` 0/90/180/270 picker in the Bridge settings sheet:
ARKit's world +X depends on whatever direction the iPhone faces at
session start, so without AprilTag calibration the scene can land
rotated. User flips to the matching option once per session.

Swift side also refined the ARKit→MuJoCo swap math (verified
right-handedness preserved under each yaw rotation) and honours the
yaw offset via `BridgeCoord.arkitToMujoco(p, yawDeg:)`.

Touched: `boxer/bridge/SceneReportStreamer.swift` (idle timer, text
frame — `.string` not `.data`), `boxer/bridge/BridgeTypes.swift`
(yawDeg parameter, still right-handed at every rotation),
`boxer/bridge/BridgeSettings.swift` + `BridgeStatusButton.swift` (yaw
picker), `boxer/ARViewModel.swift` (`bridgeSnapshot` passes track UUID
instead of array index, reads yawDeg from settings).

## [2026-04-24] ship | Bridge end-to-end verified on real iPhone (Step 2d)

Text-frame fix: `task.send(.string(...))` instead of `.data(...)`. Browser
`JSON.parse` needs a string; binary frames arrived as Blob and silently
failed the try/catch, leaving `client.latest = null` so the toolbar Radio
button stayed disabled even though the WS itself was connected.

Second landmine: ATS. `NSAllowsLocalNetworking = YES` is **required** for
cleartext `ws://` to private LAN IPs under URLSession (Safari is exempt, but
in-app sessions are not). Complex plist keys can't be set via
`INFOPLIST_KEY_*` — the string-form `"{... = YES;}"` silently drops. Fix:
add a real `Info.plist` at project root (outside the
`PBXFileSystemSynchronizedRootGroup` — any file named `Info.plist` inside
`boxer/` collides with the auto-generated bundle plist) and set
`INFOPLIST_FILE = Info.plist`. With `GENERATE_INFOPLIST_FILE = YES` still
on, the two plists merge cleanly.

Verified: 4 objects detected on iPhone (cup / bottle / laptop / person
inferred from user's own hand) appear in the Vite sim as coloured boxes
at positions consistent with their real-world positions relative to the
ARKit session origin. Sizes correct (37×26×21 cm laptop reads the same
in sim).

Touched: `boxer/bridge/SceneReportStreamer.swift` (.string frame),
`Boxer3D-Bridge/SceneReportClient.ts` (Blob/ArrayBuffer fallback),
`Info.plist` (new), `boxer.xcodeproj/project.pbxproj` (INFOPLIST_FILE).

## [2026-04-24] ship | SceneReport bridge (Step 2b+2c of Boxer3D→Gemini MVP)

Added `boxer/bridge/` with a SwiftUI-visible WebSocket streamer that publishes
`BridgeSceneReport` snapshots to a host at 1–30 Hz. Companion repo
`Boxer3D-Bridge` (forked from the Google AI Studio Franka pick-and-place demo)
hosts the relay server and the Vite/MuJoCo browser sim that consumes the
stream. This is Step 2 of the plan captured in session memory
`project_boxer3d_gemini_bridge.md`.

Scope intentionally minimal: no AprilTag calibration yet (Step 2e). Until then
ARKit world is mapped to MuJoCo world via a fixed axis swap in
`BridgeCoord.arkitToMujoco`, arm base assumed at origin of whatever direction
the iPhone was facing at ARKit session start. `yaw_rad` is 0 and
`confidence` is derived from MOT `hits` count — real per-track confidence is
not stored on `KnownDetection`.

Touched: `boxer/bridge/BridgeTypes.swift` (new), `boxer/bridge/BridgeSettings.swift`
(new), `boxer/bridge/SceneReportStreamer.swift` (new),
`boxer/bridge/BridgeStatusButton.swift` (new), `boxer/ARViewModel.swift`
(+`bridgeSnapshot()`), `boxer/ContentView.swift` (streamer @StateObject +
toolbar button + settings bindings), `boxer.xcodeproj/project.pbxproj`
(`INFOPLIST_KEY_NSLocalNetworkUsageDescription`).

## [2026-04-23] handoff | Seed LLM wiki per Karpathy pattern

Bootstrapped `wiki/` and `raw/` to hand the project off to another
collaborator. Pattern follows Karpathy's LLM Wiki gist, captured in
[../raw/karpathy-llm-wiki.md](../raw/karpathy-llm-wiki.md). Index, log,
overview, architecture, component pages, concept pages, workflows, decisions,
gotchas, todos, glossary all written from current state of `boxer/` +
`convert/` + session memory.

Touched: `CLAUDE.md`, entire `wiki/` tree, `raw/`.

## [2026-04-23] ship | Robust plane Y + contact shadow (FSD v2)

Replaced the −2 cm `planeHeightOffsetM` heuristic for horizontal
ARPlaneAnchor overlays with a 10th-percentile scan over `.floor`/`.table`
classified vertices within ±25 cm of the anchor's fitted Y. Falls back to
the old heuristic if fewer than `robustPlaneMinSamples = 30` qualifying
vertices are collected (cold start, sparse scene recon). Added radial
gradient contact-shadow decal under every tracked object, hidden in
`.camera` mode to avoid double-shadowing against the real scene.

Touched: `boxer/FSDMode.swift`, `boxer/ARViewModel.swift`,
`wiki/concepts/robust-plane-y.md`, `wiki/concepts/contact-shadow.md`.

## [2026-04-23] ship | FSD v1 — 4-state enum + plane dot overlay

Formalised the accidental 3-state FSD toggle into an explicit 4-state
`FSDRenderMode` enum (`camera → whiteOnWhite → whiteOnDark → blackOnWhite`).
Added Metal shader-modifier dot grid on every `ARPlaneAnchor`. Dropped
`.floor/.wall/.table` from scene-recon rendering so the plane overlay owns
those surfaces. Tuned `dotFrac 0.18→0.10`, `dotColor white 0.45→0.72`,
`planeHeightOffsetM 0→-0.02`.

Touched: `boxer/FSDMode.swift`, `boxer/ARViewModel.swift`,
`boxer/ARViewContainer.swift`, `boxer/ContentView.swift`.

## [2026-04-22] ship | FSD v0 — Tesla-screen mode first cut

Camera feed replacement with scene-reconstruction mesh on light background,
dual material palette (`cameraGhost` vs `fsdSolid`) swapping on FSD toggle,
`meshWithClassification` enabled. User's Tesla screenshot corrected the
palette direction — originally planned white-ghost-on-black-void, shipped
dark-solid-on-light-void.

Touched: `boxer/FSDMode.swift` (new), `boxer/ARViewModel.swift`,
`boxer/ARViewContainer.swift`.

## [2026-04-22] ingest | Canonical USDZ meshes — laptop, keyboard, bottle

Added three Tesla-minimalist canonical meshes for YOLO classes the app
detects: `laptop.usdz` (hinged at 105°), `keyboard.usdz` (frame + 7 mm
raised deck), `bottle.usdz` (Screw-revolved 18-point profile). Blender
scripts live under `~/Downloads/build_*.py` (not in repo). `cup.usdz`
already existed from 2026-04-21.

Touched: `boxer/MeshLibrary.swift`, `boxer/{laptop,keyboard,bottle}.usdz`.

## [2026-04-21] ship | Native CoreML BoxerNet

Replaced ONNX Runtime + CoreML EP execution (136 partitions, 211 CPU-fallback
nodes) with a native `.mlpackage` produced by `convert/convert.py`. 815/815
ops land on ANE, single copy in memory, full-graph optimization. fp16 compute
causes softmax collapse — `--precision fp32` required at conversion time.

Touched: `convert/` (entire directory), `boxer/BoxerNet.swift`,
`boxer/BoxerNetModel.mlpackage`.
