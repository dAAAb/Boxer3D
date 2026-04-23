---
title: Track hysteresis (provisional vs confirmed)
updated: 2026-04-23
source: boxer/ARViewModel.swift (reapStaleTracks, placeBoxes)
---

# Track hysteresis

Detection is noisy. A single-frame spurious box shouldn't persist forever;
a well-observed box shouldn't disappear after a brief phone-shake hides
it for 2 seconds. Hysteresis resolves the tension.

## States

Each `KnownDetection` has a `hits: Int` counter — incremented on every
successful match in `placeBoxes`.

- **Provisional** (`hits == 1`) — seen once. Short age-out.
- **Confirmed** (`hits ≥ 2`) — seen at least twice. Long age-out.

Tesla-inspired: consistent observation graduates a detection into
"permanent" status.

## Timeouts (`reapStaleTracks`)

```swift
let timeout: CFTimeInterval = known[i].hits >= 2 ? 20.0 : 8.0
if now - known[i].lastSeen > timeout {
    // schedule fade-out
}
```

- Provisional: **8 s** — kills one-shot phantoms without being jumpy on
  legitimate first detections.
- Confirmed: **20 s** — covers a long pan-away or a brief occlusion
  (walking past a table, looking at something else) without losing the
  track.

## Fade-out

Not an instant removal. When the timeout triggers, we:

1. Mark `reaping = true` (spring tween and matcher skip reaping tracks).
2. Run a 0.3 s `SCNAction.fadeOut`.
3. On completion, `finalReap(id:node:)` removes the node, the track, the
   detection card, and clears selection if the reaped track was selected.

The two-phase reap prevents a flashing reappearance if the object gets
re-detected mid-fade.

## Match scoring

`matchScore(label:center:size:against:)`:

- Label must equal the track's label (strict gating).
- Euclidean distance between proposed centre and track's `worldCenter`
  in metres.
- Size-ratio check (within some tolerance) — not full IoU; we don't
  want a 10 cm cup collapsing into a 30 cm mug even if centres coincide.
- Returns a score (lower = better) or `nil` if the pair is rejected.

`placeBoxes` collects all `(detection, track)` scores, sorts ascending,
and greedily assigns — each detection and each track claimed at most once.

## `instanceIndex`

On new-track creation, `instanceCountByLabel[label]` is incremented and
the current count becomes the track's `instanceIndex` ("bottle #3"). This
counter is persistent across reaps — a reaped "cup #1" doesn't free up
its number. Simpler UX: numbers never collide.

`clearBoxes()` resets the counter map.

## Why not proper DeepSORT / ByteTrack?

At 4 Hz detection and 3-box-max per cycle, the greedy matcher is fine.
Full Kalman + Hungarian + re-ID embedding is overkill for the data scale
and would slow the pipeline down. If we scale to 10+ classes and dense
scenes, revisit.
