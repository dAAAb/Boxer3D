import Foundation
import Combine
import UIKit

/// Publishes `BridgeSceneReport` messages to a host WebSocket at a fixed rate.
///
/// The streamer is pull-based: on each tick it asks its `sceneProvider`
/// closure for the latest snapshot and sends it. The provider closure is
/// wired up by `ContentView` to call `ARViewModel.bridgeSnapshot()`, so the
/// streamer itself has no dependency on the AR stack.
@MainActor
final class SceneReportStreamer: ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var sentCount: Int = 0
    @Published private(set) var lastSentAt: Date?

    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var tickTimer: Timer?
    private var reconnectTask: Task<Void, Never>?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()

    var sceneProvider: (() -> BridgeSceneReport?)?

    /// Opens the WebSocket and starts the publish timer. Cancels any prior
    /// connection first. Safe to call repeatedly (e.g. on URL change).
    func start(url: URL, rateHz: Double) {
        stopInternal()
        state = .connecting
        // Prevent the screen from sleeping while streaming — otherwise
        // ARKit pauses after ~30 s of inactivity, knownDetections freeze,
        // and the sim-side live tracking stops reflecting real motion.
        UIApplication.shared.isIdleTimerDisabled = true

        let t = session.webSocketTask(with: url)
        self.task = t
        t.resume()
        receiveLoop(for: t)

        // URLSessionWebSocketTask surfaces failures only on the first send/
        // receive. We optimistically mark connected and let `handleError`
        // flip us back to `.failed` if the socket was never actually usable.
        state = .connected

        let period = max(0.05, 1.0 / rateHz)
        let timer = Timer(timeInterval: period, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func stop() {
        stopInternal()
        state = .idle
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func stopInternal() {
        tickTimer?.invalidate()
        tickTimer = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receiveLoop(for t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.task === t else { return }
                switch result {
                case .success:
                    self.receiveLoop(for: t)
                case .failure(let err):
                    self.handleError(err)
                }
            }
        }
    }

    private func tick() {
        guard let task, let report = sceneProvider?() else { return }
        do {
            let data = try encoder.encode(report)
            // Send as .string (text frame) so browsers receive `ev.data`
            // as a String and JSON.parse works without Blob handling.
            let json = String(data: data, encoding: .utf8) ?? ""
            task.send(.string(json)) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error {
                        self.handleError(error)
                    } else {
                        self.sentCount += 1
                        self.lastSentAt = Date()
                        if self.state != .connected { self.state = .connected }
                    }
                }
            }
        } catch {
            handleError(error)
        }
    }

    private func handleError(_ err: Error) {
        state = .failed(err.localizedDescription)
        tickTimer?.invalidate(); tickTimer = nil
        task?.cancel()
        task = nil

        let settings = BridgeSettings.shared
        guard settings.enabled, let url = settings.url else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.start(url: url, rateHz: settings.rateHz)
            }
        }
    }
}
