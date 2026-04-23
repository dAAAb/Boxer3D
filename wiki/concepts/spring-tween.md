---
title: Spring tween (critically damped MOT)
updated: 2026-04-23
source: boxer/ARViewModel.swift (tickTracks)
---

# Spring tween

BoxerNet outputs new positions at ~4 Hz. If we snapped each track to the
latest observation every cycle, boxes would teleport — distracting and
looks wrong in AR. Instead each track has a rendered position (`worldCenter`)
that's pulled toward the observation (`targetTransform`) through a
critically-damped spring integrated at 33 Hz.

## Why critically damped

Critically damped = fastest settle without overshoot. For a chase like
this ("get to the new position ASAP, don't bounce"), it's the canonical
choice. Under-damped would oscillate; over-damped would feel sluggish.

## Parameters

- `omega = 14.0 rad/s` → ~200 ms settle for a 10 cm step. Feels snappy
  but still clearly animated.
- `dt = min(lastTickTime delta, 1/20)` — cap at 50 ms to avoid huge
  accelerations after a pause.

## Integration (semi-implicit Euler)

```swift
let delta = goal - worldCenter
let accel = -2 * omega * velocity + omega * omega * delta
velocity += accel * dt
worldCenter += velocity * dt
```

Classic under-damped / critically-damped / over-damped spring:
`ẍ + 2ζω·ẋ + ω²·x = 0`. Here `ζ = 1` (critical) so the `2·ω` coefficient.

## Snap threshold

When both `|delta| < 0.5 mm` and `|velocity| < 0.5 mm/s`:

```swift
worldCenter = goal
velocity = .zero
```

Kills micro-jitter and gives the CPU a break (no more per-tick writes).

## Composing the rendered transform

```swift
var m = targetTransform
m.columns.3 = simd_float4(worldCenter, 1)
node.simdWorldTransform = m
```

Rotation comes straight from the target (no rotational tween — yaw
changes between cycles are already small and tweening them would make the
box feel rubbery). Translation is tweened.

## Why not CoreAnimation or SCNAction?

Both exist but don't let you update the target mid-animation without
popping. With an explicit integrator we can replace `targetTransform`
every detection cycle and the spring naturally re-targets toward the new
goal with the velocity it already has.

## Interaction with tick cadence

`ContentView`'s 33 Hz timer drives `tickTracks`. If the cadence changes,
the `omega = 14` tune still works (springs are cadence-independent as
long as `dt` reflects wall clock) but perceived smoothness degrades below
~20 Hz.

## Related

- Track creation / match / reap: [track-hysteresis.md](track-hysteresis.md).
- Off-screen arrow uses the same 33 Hz tick: [offscreen-arrow.md](offscreen-arrow.md).
