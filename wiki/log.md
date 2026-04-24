---
title: Boxer3D wiki — log
updated: 2026-04-24
---

# Log

Append-only. Newest on top. Format: `## [YYYY-MM-DD] <kind> | <title>`.
`<kind>` ∈ { `ingest`, `decision`, `ship`, `bug`, `lint`, `handoff`, `note` }.

Grep: `grep "^## \[" wiki/log.md | head -20`.

---

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
