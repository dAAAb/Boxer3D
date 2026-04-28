---
title: MOT tracklet graveyard
updated: 2026-04-28
source: boxer/ARViewModel.swift
---

# MOT tracklet graveyard

Short-occlusion identity preservation for BoxerNet's multi-object tracker.

## Why this exists

Each frame, BoxerNet detects objects independently and the matcher binds
detections to existing tracks via geometric similarity (`matchScore`,
gates from Step 3.11). When a single noisy frame fails to match — gate
slip, momentary depth dropout, hand jitter — the existing track fails
hysteresis and dies; the next frame the same object reappears at
basically the same spot, but the matcher has nothing live to bind to,
so it allocates a fresh UUID.

For UI-only consumers a UUID rotation is cosmetic. For downstream
consumers keyed on UUID, it's an identity break:

- Bridge spawns a fresh `stream_{label}_{newUUID}` MuJoCo body; the old
  `stream_{label}_{oldUUID}` body sits unused until reap.
- Gemini's plan referenced `oldUUID`. By execute time, that ID isn't in
  the sim. `expect_holding(oldUUID)` raises *body not in current sim*.
- Future replan loops (Step 4B) would chase old UUIDs forever.

The graveyard is the minimum-viable fix: dead tracks aren't immediately
released; their identity waits a couple of seconds for a re-detection
that geometrically lines up.

## Mechanism

Two complementary parts, both in `boxer/ARViewModel.swift`:

### 1. Restore reaping-track revival in matching

`placeBoxes` loops over `known` to score detection ↔ track pairs. Until
3.14 it filtered `where !k.reaping` — but the partner code in
`updateTrack` (cancel `fadeOut`, opacity back to 1, `reaping = false`)
was specifically meant to revive a fading track that got matched again.
The filter blocked the matching half from ever feeding the revival half.
Dropping the filter restores the intended behaviour. Cost: zero. Wins
back the 0.3 s fade-out window.

### 2. Graveyard with TTL + extrapolated re-ID

Once a track makes it through fade-out, `finalReap` snapshots:

| Field | Source | Use |
|---|---|---|
| `id` | dying track | reused on resurrection |
| `label` | dying track | resurrection only allowed within same label |
| `instanceIndex` | dying track | preserves `cup #1` / `cup #2` numbering |
| `size` | dying track | resurrection vol-ratio gate |
| `lastWorldCenter` | spring-tweened position | predicted-position basis |
| `lastVelocity` | spring-damped velocity | extrapolation term |
| `timeOfDeath` | `CACurrentMediaTime()` | TTL aging |

`tryResurrect(label, center, size, now)` runs before `UUID()` for any
unclaimed detection. For each in-graveyard candidate of matching label:

```
predicted = lastWorldCenter + lastVelocity * (now - timeOfDeath)
gate      = max(0.15, 0.5 * max(newMaxDim, gMaxDim))
volRatio  = min(newVol, gVol) / max(newVol, gVol)
score     = dist / gate + 0.5 * (1 - volRatio)
```

Accept if `dist < gate AND volRatio ≥ 0.7 AND score ≤ 1.5`; pick the
lowest-score candidate.

`tickTracks` calls `cleanGraveyard(now:)` which drops entries older than
`graveyardTTL` (2 s). The graveyard is therefore strictly bounded.

## Tunable constants & rationale

Defined as private statics on `ARViewModel`:

| Constant | Value | Rationale |
|---|---|---|
| `graveyardTTL` | 2.0 s | ByteTrack / Tesla AI day reference 1–3 s for short-occlusion stitching. Above this, a different physical object may legitimately enter the same spot. |
| Resurrection gate | `max(0.15 m, 0.5 × maxDim)` | Slightly looser than live (`0.4 × maxDim`, 0.12 m floor) — death itself signals matcher noise. |
| Resurrection vol-ratio | 0.7 | Tighter than live (0.6). False resurrection *silently* corrupts identity; missed resurrection only re-allocates a UUID. Bias toward missing. |
| Cross-label resurrection | disabled | A laptop-shaped detection should never inherit a cup's UUID. |
| Resurrection initial `hits` | 2 | Resurrected tracks were once confirmed; start at confirmed-state hysteresis (20 s reap timeout) immediately. |

## What this does *not* do

- **Tentative-confirmed births.** New tracks still appear immediately as
  `hits = 1`. Adding a "must be observed N frames before emission" gate
  would suppress single-frame ghosts at the cost of latency on
  legitimate new objects. Separate decision.
- **Appearance-feature re-ID.** Resurrection is purely geometric. Two
  physically-different cups at the same spot within 2 s will alias. A
  ResNet/CLIP descriptor pass would close this, but is much heavier.
- **Per-class TTL.** A laptop probably wants longer than a cup. v1
  ships a single 2 s default.
- **Bridge-side fallback.** Bridge could maintain its own alias map as
  defence in depth; for now iOS owns identity end-to-end.

## Code references

- Struct + property: `boxer/ARViewModel.swift` near `KnownDetection`,
  `private struct GraveyardEntry`, `private var graveyard:`,
  `private static let graveyardTTL`.
- Match-loop fix: `placeBoxes`, dropped `where !k.reaping`.
- Death snapshot: `finalReap`.
- Aging: `cleanGraveyard`, called from `tickTracks`.
- Re-ID: `tryResurrect`, called from the unclaimed-detection branch in
  `placeBoxes`.

## Related

- [components/ARViewModel](../components/ARViewModel.md) — owning class
- [decisions](../decisions.md) — Step 3.11 same-label gate tightening
  (this graveyard is its complement: 3.11 makes live matching pickier,
  so 3.14 is needed to recover when picky matching drops a frame)
- [log: 2026-04-28](../log.md) — ship entry
