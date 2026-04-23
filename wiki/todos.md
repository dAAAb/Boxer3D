---
title: TODOs / backlog
updated: 2026-04-23
---

# TODOs

Ordered roughly by priority. Each item should state **what** and **why**;
implementation details go in concept/workflow pages.

## FSD mode polish

- **Classification-tinted scene recon.** `.floor / .ceiling / .wall`
  all render as the same light grey. Subtle grey tiers (Tesla
  differentiates by context) would read better. Low priority polish.
- **Selection colour → cyan.** Current highlight is yellow. Reads OK in
  camera mode but clashes in `.whiteOnDark`. Change to Tesla-style cyan
  `UIColor(red: 0, green: 0.9, blue: 1)` — will need to update both
  `paintHighlight` paths and the yellow pill in DetectionCard.
- **Crease highlight.** Tesla draws a subtle silver edge on wall corners
  / table edges. Post-process Metal shader, non-trivial. Ship after
  everything else on this list.
- **Dot density map.** User suggestion: dots denser where objects were
  detected. Requires accumulating detection footprints into a 2D heatmap
  on the plane overlay. Cool but non-essential.

## App size / release hygiene

- **Strip legacy onnx files from bundle.** `BoxerNet.onnx`,
  `BoxerNet_static.onnx`, `BoxerNet_static_fp16.onnx` are ~1 GB combined
  and not loaded at runtime. Move to a `convert/reference/` subdirectory
  or just remove. See [gotchas.md#app-size](gotchas.md#app-size).
- **Public release readme + license review.** Check BoxerNet CC-BY-NC
  implications; add clear non-commercial banner; verify
  Signing.xcconfig.template is clean.
- **Git LFS for large binaries?** Onnx + mlpackage bloat the clone.
  Migrate if it starts costing time for new contributors.

## Detection quality

- **3-DoF rotation.** Yaw-only is a real limitation for tilted objects.
  Two paths: Cube R-CNN retrain, or LiDAR-mesh PCA inside the detected
  OBB. Parked pending a real use case.
  See [rotation-1axis.md](concepts/rotation-1axis.md).
- **Fine-tune BoxerNet at imageSize = 480.** Currently running the
  960-trained checkpoint at half resolution — accuracy drift is
  acceptable but not characterised. Would unlock a higher confidence
  threshold default.
- **More class meshes.** Keyboard, mouse, remote, book — YOLO detects
  them, MeshLibrary has no USDZ for them. Add progressively.

## Performance

- **Port YOLO to native CoreML.** Would drop the ORT SPM dependency and
  probably knock 5–10 ms off YOLO's ~15 ms inference. Low value unless
  we also remove ORT for other reasons.
- **Frame-rate adaptive stream cadence.** Under thermals, cycle time
  doubles but we still chain at the nominal rate. Adaptive throttling
  would smooth the UX.

## UX

- **Settings screen.** Confidence threshold is the only tweakable; also
  expose stream cadence, FSD default mode, dot density.
- **Portrait-mode optimisation.** In README's Roadmap. Landscape is the
  implicit assumption today; portrait half-crops badly.

## Gemini-ER robot arm bridge (planned, not started)

Full plan captured in memory `project_boxer3d_gemini_bridge.md`. Goal: use
Boxer3D (iPhone) as the sole perception source for a robot arm that has no
camera view. Stream 3D OBBs + RGB thumbs + surfaces over WebSocket to a
host; host relays to Gemini Robotics-ER 1.6 for planning; host sends grasp
goals to MoveIt.

MVP step order (lowest risk first):

1. **iPhone `SceneReportStreamer`** — serialize `known: [KnownDetection]`
   + plane anchors + camera pose into JSON, stream over WebSocket. No
   Gemini involvement yet.
2. **Host echo server** — Python `websockets` listener, `print()` incoming
   reports. Verify LAN stability.
3. **AprilTag hand-eye calibration** — iPhone sees a tag on robot base →
   compute `T_robotbase_from_arkit`. Critical: ARKit world origin is
   session-start, not robot base; skipping this makes every pick wrong.
4. **Gemini-ER REST bridge** — host sends RGB thumb + scene JSON + user
   intent, receives `{target_id}` response. Start with Google's official
   2-stage pick-and-place pattern (locate → function-call sequence).
5. **Sim test** — wire to PiPER IsaacLab sim (from OpenClown project)
   before touching real hardware.
6. **Real hardware** — PiPER first (safer), then UR10e (OpenEmily template).

Notes that are easy to get wrong:

- **Gemini-ER 1.6 has no Live API** — REST `generateContent` only. Can't
  stream. Only call when user issues intent, not every frame.
- **Gemini-ER is NOT a servo controller** — DeepMind explicit: "decision
  layer, not motor layer". Cloud round-trip 400–1000 ms + thinking; closed-
  loop servo stays local.
- **Gemini-ER doesn't accept point clouds / depth** — only text, image,
  video, audio. Embed Boxer3D's 3D context as JSON inside the text prompt.
  1M input token limit, plenty of room.
- **Z in Google's baseline demo is a boolean** (`high: bool`). Boxer3D
  gives real Z; upgrade the function signature.
- **BoxerNet is CC-BY-NC** — research/demo fine, swap detector before
  commercial deployment.

## Developer experience

- **Document build from scratch on a clean Mac.** Include Xcode version,
  Python version for convert/, Blender version for mesh-authoring.
- **Commit the Blender mesh-build scripts into `meshes/`.** Currently
  under `~/Downloads/`. If a collaborator picks up mesh work they'll
  need them. See
  [workflows/mesh-authoring.md](workflows/mesh-authoring.md).
- **Pre-commit hook for wiki lint.** Check: every `components/*.md` has
  a matching `boxer/*.swift`, every wiki page is linked from
  `index.md`, every code link of form `file:NN` resolves.

## Done recently (see [log.md](log.md))

- ✅ Robust plane Y via classified vertex percentile (2026-04-23)
- ✅ Contact shadow decals (2026-04-23)
- ✅ FSD 4-state enum (2026-04-23)
- ✅ Plane dot overlay (2026-04-23)
- ✅ Scene-recon classification filter (2026-04-23)
- ✅ Canonical USDZ meshes: laptop / keyboard / bottle (2026-04-22)
- ✅ Native CoreML for BoxerNet (2026-04-21)
