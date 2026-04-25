//
//  ContentView.swift
//  boxer
//
//  Created by Bharath Kumar Adinarayan on 09.04.26.
//

import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var viewModel = ARViewModel()
    @StateObject private var bridgeSettings = BridgeSettings.shared
    @StateObject private var bridgeStreamer = SceneReportStreamer()
    /// 33 Hz tick — drives the MOT spring tween for every live track, and
    /// (when a detection is selected) also updates the off-screen arrow.
    private let uiTick = Timer.publish(every: 1.0 / 33.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            ARViewContainer(viewModel: viewModel)

            // Top: "just added" toast
            VStack {
                if let last = viewModel.lastAdded {
                    Text(last)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.green.opacity(0.8))
                        .cornerRadius(20)
                        .padding(.top, 60)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .animation(.easeInOut(duration: 0.25), value: viewModel.lastAdded)

            // Detection cards at bottom left (scrollable)
            if !viewModel.detections.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(viewModel.detections.enumerated()), id: \.element.id) { i, det in
                                        DetectionCard(
                                            detection: det,
                                            color: boxColor(i),
                                            selected: viewModel.selectedId == det.id
                                        )
                                        .onLongPressGesture(minimumDuration: 0.35) {
                                            viewModel.toggleSelect(det.id)
                                        }
                                    }
                                }
                            }
                            .frame(maxHeight: 320)
                            Button(action: { viewModel.clearBoxes() }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12))
                                    Text("Clear all")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.red.opacity(0.7))
                                .cornerRadius(6)
                            }
                        }
                        .padding(.leading, 16)
                        Spacer()
                    }
                    .padding(.bottom, 80)
                }
            }

            // Off-screen arrow pointing to selected object.
            if let hint = viewModel.offscreenHint {
                OffscreenArrow(hint: hint)
                    .allowsHitTesting(false)
            }

            // Confidence slider bottom right
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 2) {
                        Text(String(format: "conf: %.1f", viewModel.confidenceThreshold))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                        Slider(value: $viewModel.confidenceThreshold, in: 0.1...0.9, step: 0.1)
                            .frame(width: 120)
                            .tint(.white)
                    }
                }
                .padding(.trailing, 20)
                .padding(.bottom, 30)
            }

            // Capture button right centre + tip
            HStack {
                Spacer()
                Text(viewModel.status)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.trailing, 12)
                VStack(spacing: 10) {
                    BridgeStatusButton(streamer: bridgeStreamer, settings: bridgeSettings)
                    FSDToggleButton(renderMode: viewModel.renderMode,
                                    action: { viewModel.toggleFsdMode() })
                    StreamToggleButton(streamMode: viewModel.streamMode,
                                       action: { viewModel.toggleStream() })
                    Button(action: { viewModel.detectNow() }) {
                        ZStack {
                            Circle()
                                .fill(.white)
                                .frame(width: 70, height: 70)
                            // In stream mode: stay solid blue (no per-cycle gray flash)
                            // so the button doesn't look like it's auto-firing.
                            Circle()
                                .fill(detectButtonFill(viewModel))
                                .frame(width: 60, height: 60)
                            if viewModel.isProcessing && !viewModel.streamMode {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "cube.transparent.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.white)
                            }
                        }
                        .opacity(viewModel.streamMode ? 0.35 : 1.0)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isProcessing || viewModel.streamMode)
                }
                .padding(.trailing, 20)
            }
        }
        .onReceive(uiTick) { _ in
            viewModel.tickTracks()
            if viewModel.selectedId != nil {
                viewModel.updateOffscreenHint()
            }
        }
        .onAppear {
            bridgeStreamer.sceneProvider = { [weak viewModel] include in
                viewModel?.bridgeSnapshot(includeImage: include)
            }
            applyBridgeSettings()
        }
        .onChange(of: bridgeSettings.enabled) { _, _ in applyBridgeSettings() }
        .onChange(of: bridgeSettings.urlString) { _, _ in applyBridgeSettings() }
        .onChange(of: bridgeSettings.rateHz) { _, _ in applyBridgeSettings() }
    }

    private func applyBridgeSettings() {
        guard bridgeSettings.enabled, let url = bridgeSettings.url else {
            bridgeStreamer.stop()
            return
        }
        bridgeStreamer.start(url: url, rateHz: bridgeSettings.rateHz)
    }
}

struct DetectionCard: View {
    let detection: DetectionInfo
    let color: Color
    var selected: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text("\(detection.label) #\(detection.shortId)")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
            Text(String(format: "%.0fx%.0fx%.0f",
                        detection.size.x * 100,
                        detection.size.y * 100,
                        detection.size.z * 100))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
            Text("cm")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.yellow.opacity(0.85) : .black.opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.yellow, lineWidth: selected ? 2 : 0)
        )
        .cornerRadius(6)
        .animation(.easeInOut(duration: 0.15), value: selected)
    }
}

struct OffscreenArrow: View {
    let hint: OffscreenHint

    var body: some View {
        Image(systemName: hint.behind ? "arrow.uturn.backward.circle.fill" : "arrowtriangle.right.fill")
            .font(.system(size: 36, weight: .bold))
            .foregroundStyle(Color.yellow)
            .shadow(color: .black.opacity(0.5), radius: 4)
            .rotationEffect(.radians(hint.behind ? 0 : hint.angle))
            .position(hint.position)
    }
}

struct StreamToggleButton: View {
    let streamMode: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.white).frame(width: 54, height: 54)
                Circle()
                    .fill(streamMode ? Color.red : Color.black.opacity(0.7))
                    .frame(width: 46, height: 46)
                Image(systemName: streamMode ? "stop.fill" : "infinity")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// FSD 4-state cycle button. Centre colour + label hint which state we're in:
/// camera (black/"FSD") → whiteOnWhite (light blue/"W·W") → whiteOnDark
/// (cyan/"W·D") → blackOnWhite (dark blue/"B·W") → back to camera.
struct FSDToggleButton: View {
    let renderMode: FSDRenderMode
    let action: () -> Void

    private var innerFill: Color {
        switch renderMode {
        case .camera:       return .black.opacity(0.7)
        case .whiteOnWhite: return Color(red: 0.55, green: 0.85, blue: 1.0)
        case .whiteOnDark:  return Color(red: 0.00, green: 0.70, blue: 1.0)
        case .blackOnWhite: return Color(red: 0.10, green: 0.25, blue: 0.55)
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.white).frame(width: 54, height: 54)
                Circle()
                    .fill(innerFill)
                    .frame(width: 46, height: 46)
                Text(renderMode.buttonLabel)
                    .font(.system(size: renderMode == .camera ? 13 : 11,
                                  weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Solid blue while streaming (button is disabled anyway and shouldn't flash),
/// gray while a single-shot is running, blue when idle.
@MainActor
private func detectButtonFill(_ vm: ARViewModel) -> Color {
    if vm.streamMode { return .blue }
    return vm.isProcessing ? .gray : .blue
}

// Must match colors in ARViewModel.placeBoxes
func boxColor(_ index: Int) -> Color {
    let colors: [Color] = [.red, .green, .blue]
    return colors[index % colors.count]
}
