---
title: Stream mode (continuous detection)
updated: 2026-04-23
source: boxer/ARViewModel.swift (toggleStream, scheduleNextWhenMoving)
---

# Stream mode

Toggles detection from "tap-to-detect" to "always on". When enabled,
`detectNow()` chains cycles back-to-back with a 30 ms cooldown between
ANE submissions.

## Activation

```swift
func toggleStream() {
    streamMode.toggle()
    if streamMode {
        lastDetectionCameraTransform = nil  // force first cycle
        if !isProcessing { detectNow() }
    } else {
        motionCheckTask?.cancel()
        setStatusIdle("Ready")
    }
}
```

## Cycle chaining

At the end of each successful (or failed) cycle:

```swift
if self.streamMode { self.scheduleNextWhenMoving() }
```

`scheduleNextWhenMoving` schedules the next `detectNow` after a
`cycleCooldownMs = 30 ms` sleep. The name is legacy — earlier versions
gated on camera motion; current behaviour is "always chain" because MOT
needs continuous updates so moving objects keep track even when the
phone is still. See the `hasMovedEnough()` helper for the old logic
(still present but unused).

## Effective rate

BoxerNet inference ≈ 160–180 ms + 20 ms preprocess + 30 ms cooldown ≈
210 ms/cycle → **~4–5 Hz**. Feels like a perception loop, not discrete
taps.

## UI feedback

`ContentView`'s detect button:

- Streaming on → solid blue, disabled, 35 % opacity, cube icon (no
  spinner — a per-cycle spinner flash makes the button look like it's
  auto-firing, confusing).
- Streaming off + processing → grey with spinner.
- Idle → blue with cube icon.

## Stopping criteria

- User taps the stream toggle off.
- Memory warning fires (`UIApplication.didReceiveMemoryWarningNotification`)
  — force `streamMode = false`, abandon in-flight cycle, status updates to
  "Low memory — stream paused".
- App backgrounded (ARKit auto-pauses the session, no explicit handling).

## Known limitations

- No frame-rate adaptive tuning. If the device thermals throttle and
  cycle time doubles, we still chain at the old rate and just observe
  slower.
- `motionCheckTask` uses `Task.sleep` + a cancellation guard; under
  rapid stream on/off toggling you can get a missed wake-up, but the
  next `detectNow` reschedules correctly.
