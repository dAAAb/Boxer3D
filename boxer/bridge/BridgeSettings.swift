import Foundation
import Combine

/// UserDefaults-backed configuration for the SceneReport bridge.
///
/// Singleton because the streamer and the settings sheet both need to read
/// the same live state, and the bridge is a single feature scoped to the
/// running app. Changes propagate via `@Published` so the SwiftUI sheet
/// reacts immediately and the streamer's next tick picks up the new rate /
/// URL without an explicit reconnect call.
@MainActor
final class BridgeSettings: ObservableObject {
    static let shared = BridgeSettings()

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Keys.enabled) }
    }
    @Published var urlString: String {
        didSet { UserDefaults.standard.set(urlString, forKey: Keys.url) }
    }
    @Published var rateHz: Double {
        didSet { UserDefaults.standard.set(rateHz, forKey: Keys.rateHz) }
    }
    /// Extra yaw (around +Z) applied to every object position before sending.
    /// Without AprilTag calibration (Step 2e), ARKit's world +X depends on
    /// which direction the iPhone happens to face at session start — this
    /// lets the user rotate the scene 0°/90°/180°/270° until sim matches
    /// reality. Degrees, not radians.
    @Published var worldYawDeg: Int {
        didSet { UserDefaults.standard.set(worldYawDeg, forKey: Keys.yawDeg) }
    }

    private enum Keys {
        static let enabled = "bridge.enabled"
        static let url = "bridge.url"
        static let rateHz = "bridge.rateHz"
        static let yawDeg = "bridge.yawDeg"
    }

    private init() {
        self.enabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        self.urlString = UserDefaults.standard.string(forKey: Keys.url)
            ?? "ws://192.168.22.92:8787"
        let hz = UserDefaults.standard.double(forKey: Keys.rateHz)
        self.rateHz = hz > 0 ? hz : 10.0
        let yaw = UserDefaults.standard.integer(forKey: Keys.yawDeg)
        self.worldYawDeg = [0, 90, 180, 270].contains(yaw) ? yaw : 0
    }

    var url: URL? { URL(string: urlString) }
}
