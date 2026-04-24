import SwiftUI

/// Toolbar button showing bridge connection state. Tap opens the settings
/// sheet. Visual language matches `StreamToggleButton` / `FSDToggleButton`:
/// white 54×54 outer circle with a 46×46 coloured inner disc.
struct BridgeStatusButton: View {
    @ObservedObject var streamer: SceneReportStreamer
    @ObservedObject var settings: BridgeSettings
    @State private var showSettings = false

    private var innerFill: Color {
        guard settings.enabled else { return .black.opacity(0.7) }
        switch streamer.state {
        case .idle:              return .black.opacity(0.7)
        case .connecting:        return .orange
        case .connected:         return .green
        case .failed:            return .red
        }
    }

    private var iconName: String {
        guard settings.enabled else { return "wifi.slash" }
        switch streamer.state {
        case .idle, .failed: return "wifi.exclamationmark"
        case .connecting:    return "wifi"
        case .connected:     return "dot.radiowaves.left.and.right"
        }
    }

    var body: some View {
        Button(action: { showSettings = true }) {
            ZStack {
                Circle().fill(.white).frame(width: 54, height: 54)
                Circle().fill(innerFill).frame(width: 46, height: 46)
                Image(systemName: iconName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSettings) {
            BridgeSettingsView(streamer: streamer, settings: settings)
        }
    }
}

struct BridgeSettingsView: View {
    @ObservedObject var streamer: SceneReportStreamer
    @ObservedObject var settings: BridgeSettings
    @Environment(\.dismiss) private var dismiss

    private var stateText: String {
        switch streamer.state {
        case .idle:              return "Off"
        case .connecting:        return "Connecting…"
        case .connected:         return "Connected"
        case .failed(let msg):   return "Failed: \(msg)"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bridge") {
                    Toggle("Stream detections", isOn: $settings.enabled)
                    HStack {
                        Text("WebSocket URL")
                        Spacer()
                        TextField("ws://host:8787", text: $settings.urlString)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.URL)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Rate")
                        Spacer()
                        Text("\(settings.rateHz, specifier: "%.0f") Hz")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.rateHz, in: 1...30, step: 1)
                }
                Section("Status") {
                    LabeledContent("State", value: stateText)
                    LabeledContent("Sent", value: "\(streamer.sentCount)")
                    if let t = streamer.lastSentAt {
                        LabeledContent("Last sent", value: t.formatted(date: .omitted, time: .standard))
                    }
                }
                Section {
                    Text("Coordinate frame is ARKit → MuJoCo via fixed axis swap until AprilTag calibration lands. Arm base is assumed at the origin of whatever direction the iPhone was pointing when ARKit started.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Bridge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
