---
title: Off-screen arrow
updated: 2026-04-23
source: boxer/ARViewModel.swift (updateOffscreenHint), boxer/ContentView.swift (OffscreenArrow)
---

# Off-screen arrow

When a detection is selected but currently out of frame (pan away, or
behind the phone), we draw an arrow on the screen edge pointing at its
world position.

## Computation (33 Hz)

`updateOffscreenHint()` runs from the `ContentView` ticker whenever
`selectedId != nil`.

Steps:

1. Project `worldCenter` to screen with `sceneView.projectPoint(...)`.
2. Compute `pCam = camera.transform.inverse × worldCenter`. ARKit camera
   local has `-Z` forward, so `pCam.z >= 0` means the target is behind
   us.
3. If the projected point is inside the bounds **and** not behind → hide
   the arrow.
4. Otherwise compute the direction from screen centre to the projected
   point. If behind, flip (the projected point is in the wrong direction;
   real bearing is `-dx, -dy`).
5. Clamp the arrow to a 46-point margin ring along the screen edge.

## Rendering

`OffscreenArrow` in `ContentView.swift`:

```swift
Image(systemName: hint.behind ? "arrow.uturn.backward.circle.fill"
                              : "arrowtriangle.right.fill")
    .rotationEffect(.radians(hint.behind ? 0 : hint.angle))
    .position(hint.position)
```

- "behind" arrow is a U-turn icon (no rotation — "turn around to find it").
- "off-screen ahead" arrow is a rotating triangle pointing in the computed
  direction.

## Edge clamping math

```swift
let scale = min(
    (dx > 0 ? (maxX - cx) : (margin - cx)) / (dx == 0 ? 1 : dx),
    (dy > 0 ? (maxY - cy) : (margin - cy)) / (dy == 0 ? 1 : dy)
)
let edgeX = cx + dx * max(0, scale)
let edgeY = cy + dy * max(0, scale)
```

Finds the smaller of the two axis intersections with the edge rectangle.
The `dx == 0 ? 1 : dx` guard avoids division by zero when the target is
directly above / below centre.

## Why 33 Hz

Matches the tween cadence; good enough — a 30 ms arrow lag is
imperceptible. Could drop to 20 Hz if we ever need to save cycles.
