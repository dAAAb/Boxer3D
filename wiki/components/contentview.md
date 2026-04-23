---
title: ContentView.swift
updated: 2026-04-23
source: boxer/ContentView.swift
---

# ContentView

SwiftUI root. ZStack of:

1. [`ARViewContainer`](arviewcontainer.md) — the AR scene (fills screen).
2. Top-centre "just added" toast (green pill, auto-dismisses).
3. Bottom-left detection card stack + "Clear all" button.
4. Off-screen arrow pointer when a detection is selected but out of frame.
5. Bottom-right confidence slider (0.1–0.9, step 0.1).
6. Right-edge button column: FSD button, stream toggle, big "detect now" cube button.

All state is owned by `@StateObject var viewModel = ARViewModel()`.
ContentView is purely presentational — every button is a thin wrapper around
an `ARViewModel` method call.

## 33 Hz ticker

```swift
private let uiTick = Timer.publish(every: 1.0 / 33.0, on: .main, in: .common).autoconnect()
```

`.onReceive(uiTick)` calls `viewModel.tickTracks()` every 30 ms — this is
what drives the [spring tween](../concepts/spring-tween.md) per tracked
object. When a detection is selected, the same tick also updates the
off-screen hint ([offscreen-arrow.md](../concepts/offscreen-arrow.md)).

## FSDToggleButton

Four-state button. Centre colour + text label reflect the current
`FSDRenderMode`:

| State | Label | Inner colour |
|---|---|---|
| `.camera` | `FSD` | black 0.7 |
| `.whiteOnWhite` | `W·W` | light blue |
| `.whiteOnDark` | `W·D` | cyan |
| `.blackOnWhite` | `B·W` | dark blue |

See [fsd-palette.md](../concepts/fsd-palette.md) for what each mode does.

## DetectionCard

One pill per live track. Shows: class colour dot, `<label> #<instance>`,
size in cm (`WxHxD`). Long-press (0.35 s) selects/deselects — selected card
goes yellow, the corresponding wireframe pulses, and an off-screen arrow
points at it when it leaves the viewport.

Max scroll height is 320 pt; above that the list scrolls vertically.

## Detect button states

- Streaming on: solid blue, disabled, 35 % opacity. The cube icon stays
  instead of the progress spinner to avoid a misleading per-cycle flash.
- Streaming off + processing: grey with spinner.
- Idle: blue with cube icon.

See `detectButtonFill(_:)` in `ContentView.swift:259`.

## Class colour mapping

```swift
func boxColor(_ index: Int) -> Color {
    [.red, .green, .blue][index % 3]
}
```

Indexed by enumeration order of `viewModel.detections`. `ARViewModel.placeBoxes`
uses the same three colours for the wireframe tint — the `// Must match
colors in ARViewModel.placeBoxes` comment flags the duplication. If you add
a fourth colour, update both sites.
