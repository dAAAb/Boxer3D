---
title: Rotation is yaw-only (why)
updated: 2026-04-23
source: boxer/BoxerNet.swift, BoxerNet paper
---

# Rotation is yaw-only

BoxerNet's output is `(cx, cy, cz, w, h, d, yaw)` — 7 numbers per box.
Pitch and roll are *not* predicted. The OBB's orientation is fully
determined by `yaw` plus the gravity-aligned voxel frame (`T_wv`).

## What this means visually

An OBB's "up" axis always points along world gravity. The box can spin
around the vertical axis (that's yaw) but cannot tilt. A laptop lying at
a 30° angle on a couch still gets an axis-aligned-to-gravity OBB that
spins to the laptop's facing direction.

For most kitchen / desk objects (cups, bottles, laptops, keyboards,
plates) this is fine — their natural orientation is gravity-aligned.

## Where it breaks

Anything lying on its side or tilted:

- A book dropped at an angle on a chair.
- A toppled bottle.
- A wall-mounted monitor.
- Anything on a slope.

These cases get a box whose orientation is "roughly right but clearly
wrong" — centre is correct, yaw is correct, but the box walls don't align
with the object walls.

## Why the model doesn't do pitch/roll

It's a model architecture choice from the paper. The regression head
(`AleHead`) outputs 7 floats and assumes gravity alignment — simpler loss,
better data efficiency, matches the use cases Meta targeted (robotics
and AR tabletop).

## Options if we ever need full 3-DoF rotation

Discussed, parked at the user's request. Summary:

1. **Retrain / replace with Cube R-CNN** — full 6-DoF rotation output,
   larger model, more COCO-like data. Trade-offs: bigger model, different
   license, loses Boxer's LiDAR-depth integration.
2. **LiDAR-PCA hack** — after BoxerNet gives us a centre + size, sample
   the scene-recon mesh inside that volume, PCA the vertices, use the
   principal axes as rotation. Precision depends on mesh quality (noisy
   around object edges). Doesn't need retraining.

Neither is implemented. If you need them, see decisions.md for the
decision to defer.
