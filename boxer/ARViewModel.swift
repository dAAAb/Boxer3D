import Foundation
import ARKit
import Combine
import CoreImage
import SceneKit
import simd
import UIKit

struct DetectionInfo: Identifiable {
    let id: UUID
    let label: String
    let instanceIndex: Int
    let size: simd_float3
    let confidence: Float

    init(id: UUID = UUID(), label: String, instanceIndex: Int, size: simd_float3, confidence: Float) {
        self.id = id
        self.label = label
        self.instanceIndex = instanceIndex
        self.size = size
        self.confidence = confidence
    }

    /// First 4 alphanumeric chars of the track UUID, uppercased. Identical
    /// algorithm to the browser-side label sprite, so an object reads the
    /// same on both screens — `cup #1A2B` on the iPhone is the same object
    /// as `cup #1A2B` in the sim. Stable across frames; changes only when
    /// BoxerNet's MOT reaps and respawns the track (then both screens show
    /// the new id together).
    var shortId: String {
        let alnum = id.uuidString.filter { $0.isLetter || $0.isNumber }
        return String(alnum.prefix(4)).uppercased()
    }
}

private struct KnownDetection {
    let id: UUID
    let label: String
    let instanceIndex: Int
    /// Rendered position — driven by the spring tween toward `targetTransform`.
    var worldCenter: simd_float3
    /// Frozen on creation; we don't regenerate geometry per cycle.
    let size: simd_float3
    let node: SCNNode
    let wireframeNode: SCNNode
    /// Soft radial shadow decal under the object, hidden in camera mode.
    /// nil only if contact-shadow creation was skipped.
    let shadowNode: SCNNode?
    /// Latest observed transform (match target for the tween).
    var targetTransform: simd_float4x4
    /// Spring-damped velocity per axis (m/s).
    var velocity: simd_float3 = .zero
    /// CACurrentMediaTime() of last match — used for age-out.
    var lastSeen: CFTimeInterval
    /// Number of detection matches so far. Hysteresis: confirmed tracks
    /// (hits ≥ 2) survive long silent gaps; provisional (hits == 1) tracks
    /// expire fast to kill single-frame spurious detections.
    var hits: Int = 1
    /// True once a fade-out action is scheduled, to prevent re-triggering.
    var reaping: Bool = false
}

/// Screen-space guidance for an off-screen selected object.
struct OffscreenHint {
    /// Angle in radians from screen centre to the clamped arrow position.
    let angle: Double
    /// Clamped position along the screen edge (in view points).
    let position: CGPoint
    /// True when the target is behind the camera (arrow should flip / show 180°).
    let behind: Bool
}

@MainActor
final class ARViewModel: NSObject, ObservableObject {
    @Published var status: String = "Initializing..."
    @Published var isProcessing: Bool = false
    @Published var detections: [DetectionInfo] = []
    @Published var confidenceThreshold: Float = 0.8
    @Published var streamMode: Bool = false
    @Published var lastAdded: String? = nil
    @Published var lastCycleMs: Int = 0
    @Published var selectedId: UUID? = nil
    @Published var offscreenHint: OffscreenHint? = nil
    /// Explicit 4-state cycle replaces the old Bool toggle (which gave an
    /// accidental 3-state behaviour because `scene.background.contents = nil`
    /// doesn't reliably restore the ARSCNView camera feed). See FSDRenderMode.
    @Published var renderMode: FSDRenderMode = .camera

    /// Scene-reconstruction mesh nodes keyed by ARMeshAnchor.identifier.
    /// Populated regardless of render mode (so the mesh is ready the moment
    /// the user toggles in), but hidden unless the mode shows environment.
    private var sceneReconNodes: [UUID: SCNNode] = [:]

    /// Live ARMeshAnchor references kept in sync with sceneReconNodes — the
    /// plane overlay needs to read `.floor/.table` classified vertices to
    /// compute a robust surface Y, sidestepping ARKit's plane-fit upward
    /// bias from objects sitting on the surface.
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]

    /// ARPlaneAnchor-backed dot overlay nodes keyed by anchor identifier.
    /// Enables the Tesla "feel the road" look on detected horizontal /
    /// vertical planes.
    private var planeOverlayNodes: [UUID: SCNNode] = [:]

    var sceneView: ARSCNView?
    private var boxerNet: BoxerNet?
    private var yoloDetector: YOLODetector?
    private let meshLibrary = MeshLibrary()
    private var known: [KnownDetection] = []
    private var cycleStart: Date?
    private var lastAddedClearTask: Task<Void, Never>?
    /// Running count of detections per class, used to number instances
    /// ("bottle #3"). Reset on clearBoxes.
    private var instanceCountByLabel: [String: Int] = [:]
    /// Timestamp of the previous `tickTracks()` call; used to compute dt for
    /// the spring integrator. Reset on clearBoxes so the first tick after a
    /// reset is a no-op.
    private var lastTickTime: CFTimeInterval? = nil
    private var memoryWarningObserver: NSObjectProtocol?
    private var lastDetectionCameraTransform: simd_float4x4?
    private var motionCheckTask: Task<Void, Never>?
    /// Incremented each cycle. If memory warning fires mid-predict, we bump this so
    /// the in-flight Task's completion is discarded instead of updating the scene.
    private var cycleToken: Int = 0

    override init() { super.init() }

    /// Hard cap on accumulated detections. With native CoreML (single 192 MB
    /// mlpackage, no ORT doubling) + line-primitive wireframes (2 nodes/box
    /// instead of 14), memory and rendering head-room are both much larger.
    private static let maxKnown = 50
    /// Minimum camera translation (m) since last detection before triggering next cycle.
    private static let motionTranslationThreshold: Float = 0.20   // 20 cm
    /// Minimum camera rotation (rad) since last detection before triggering next cycle.
    private static let motionRotationThreshold: Float = 0.35      // ~20°
    /// Minimum delay between cycles (ms). With native CoreML the old ORT
    /// buffer-release reason no longer applies; tiny cooldown lets the ARKit
    /// frame update between cycles without hammering ANE back-to-back.
    private static let cycleCooldownMs: Int = 30

    func setup(sceneView: ARSCNView) {
        self.sceneView = sceneView
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.streamMode { self.streamMode = false }
                self.abandonInFlightCycle()
                self.status = "Low memory — stream paused"
            }
        }
        Task.detached { await self.loadModelsInBackground() }
    }

    deinit {
        if let obs = memoryWarningObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Model Loading

    nonisolated private func loadModelsInBackground() async {
        let yoloPath = Bundle.main.path(forResource: "yolo11n", ofType: "onnx")

        await MainActor.run { self.status = "Loading YOLO..." }
        guard let yoloPath else {
            await MainActor.run { self.status = "yolo11n.onnx not found" }
            return
        }
        let yolo: YOLODetector
        do { yolo = try YOLODetector(modelPath: yoloPath) }
        catch {
            await MainActor.run { self.status = "YOLO failed: \(error.localizedDescription)" }
            return
        }

        await MainActor.run { self.status = "Loading BoxerNet (CoreML)…" }
        let boxer: BoxerNet
        do { boxer = try BoxerNet() }
        catch {
            await MainActor.run { self.status = "BoxerNet failed: \(error.localizedDescription)" }
            return
        }

        await MainActor.run {
            self.yoloDetector = yolo
            self.boxerNet = boxer
            self.status = "Ready — tap Detect 3D"
        }
    }

    // MARK: - Detection

    func detectNow() {
        guard let sceneView, let frame = sceneView.session.currentFrame,
              let boxerNet, let yoloDetector else {
            status = "Not ready"; return
        }
        guard frame.sceneDepth != nil else {
            status = "No LiDAR depth"; return
        }

        isProcessing = true
        cycleStart = Date()
        setStatusIdle("Detecting...")

        let capturedTransform = frame.camera.transform
        cycleToken &+= 1
        let myToken = cycleToken

        Task.detached {
            do {
                let results = try await self.runPipeline(frame: frame, boxer: boxerNet, yolo: yoloDetector)
                await MainActor.run {
                    guard myToken == self.cycleToken else { return }   // abandoned
                    self.placeBoxes(results, in: sceneView)
                    self.finishCycle()
                    self.lastDetectionCameraTransform = capturedTransform
                    if self.streamMode { self.scheduleNextWhenMoving() }
                }
            } catch {
                await MainActor.run {
                    guard myToken == self.cycleToken else { return }
                    self.status = "Error: \(error.localizedDescription)"
                    self.finishCycle()
                    self.lastDetectionCameraTransform = capturedTransform
                    if self.streamMode { self.scheduleNextWhenMoving() }
                }
            }
        }
    }

    /// Abandon any in-flight cycle — UI returns to idle, results dropped when they arrive.
    private func abandonInFlightCycle() {
        cycleToken &+= 1
        motionCheckTask?.cancel()
        motionCheckTask = nil
        isProcessing = false
    }

    /// Schedule the next cycle. Tesla-style: perception always-on while the
    /// stream is active. The old motion-gate "idle" behaviour is gone — MOT
    /// needs continuous updates so objects moving in view keep their tracks
    /// refreshed even when the camera is still. Only the inter-cycle cooldown
    /// remains, to avoid back-to-back ANE submissions.
    private func scheduleNextWhenMoving() {
        motionCheckTask?.cancel()
        let cooldown = UInt64(Self.cycleCooldownMs) * 1_000_000
        motionCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: cooldown)
            guard let self else { return }
            await MainActor.run {
                guard self.streamMode, !self.isProcessing else { return }
                self.detectNow()
            }
        }
    }

    private func hasMovedEnough() -> Bool {
        guard let sceneView, let frame = sceneView.session.currentFrame else { return false }
        guard let last = lastDetectionCameraTransform else { return true }
        let current = frame.camera.transform

        let cPos = simd_make_float3(current.columns.3)
        let lPos = simd_make_float3(last.columns.3)
        if simd_distance(cPos, lPos) > Self.motionTranslationThreshold { return true }

        // Relative rotation angle between the two 3×3 rotation blocks.
        let r1 = simd_float3x3(simd_make_float3(current.columns.0),
                               simd_make_float3(current.columns.1),
                               simd_make_float3(current.columns.2))
        let r2 = simd_float3x3(simd_make_float3(last.columns.0),
                               simd_make_float3(last.columns.1),
                               simd_make_float3(last.columns.2))
        let rel = r1 * r2.transpose
        let tr = rel[0, 0] + rel[1, 1] + rel[2, 2]
        let cosTheta = max(-1, min(1, (tr - 1) * 0.5))
        return acos(cosTheta) > Self.motionRotationThreshold
    }

    private func finishCycle() {
        isProcessing = false
        if let s = cycleStart {
            lastCycleMs = Int(Date().timeIntervalSince(s) * 1000)
        }
    }

    /// Toggle long-press selection on a detection. Yellow pulsing wireframe
    /// when selected; plain white when deselected.
    func toggleSelect(_ id: UUID) {
        if selectedId == id {
            setHighlight(nil)
            selectedId = nil
        } else {
            setHighlight(id)
            selectedId = id
        }
    }

    private func setHighlight(_ id: UUID?) {
        // Reset all highlights.
        for k in known {
            k.wireframeNode.removeAction(forKey: "pulse")
            k.wireframeNode.simdScale = simd_float3(1, 1, 1)
            paintHighlight(on: k.wireframeNode, selected: false)
        }
        guard let id, let target = known.first(where: { $0.id == id }) else { return }
        paintHighlight(on: target.wireframeNode, selected: true)
        let pulse = SCNAction.sequence([
            SCNAction.scale(to: 1.12, duration: 0.45),
            SCNAction.scale(to: 1.00, duration: 0.45),
        ])
        target.wireframeNode.runAction(SCNAction.repeatForever(pulse), forKey: "pulse")
    }

    /// Wireframe nodes carry their SCNGeometry directly; mesh nodes from
    /// MeshLibrary are an empty container wrapping geometry-bearing children.
    /// For meshes we tint via `.multiply` so any baked AO texture on the
    /// diffuse channel still shows through; wireframes have no texture and
    /// swap `.diffuse.contents` directly.
    private func paintHighlight(on node: SCNNode, selected: Bool) {
        let isMesh = node.geometry == nil
        if isMesh {
            let tint: UIColor = selected
                ? UIColor(red: 1.0, green: 0.92, blue: 0.55, alpha: 1.0)  // 淡鵝黃
                : UIColor.white
            node.enumerateChildNodes { child, _ in
                child.geometry?.firstMaterial?.multiply.contents = tint
            }
        } else {
            node.geometry?.firstMaterial?.diffuse.contents =
                selected ? UIColor.systemYellow : UIColor.white
        }
    }

    /// Called from a 20 Hz timer in ContentView — compute off-screen hint for
    /// the currently selected object, or clear it when selected is visible.
    func updateOffscreenHint() {
        guard let sceneView, let id = selectedId,
              let k = known.first(where: { $0.id == id }),
              let frame = sceneView.session.currentFrame else {
            if offscreenHint != nil { offscreenHint = nil }
            return
        }
        let bounds = sceneView.bounds
        guard bounds.width > 1 else { return }

        // World → camera-local. ARKit: -Z forward, +Y up in camera space.
        let camInv = frame.camera.transform.inverse
        let p4 = simd_float4(k.worldCenter.x, k.worldCenter.y, k.worldCenter.z, 1)
        let pCam = camInv * p4
        let behind = pCam.z >= 0   // +z is behind in ARKit camera local

        let projected = sceneView.projectPoint(
            SCNVector3(k.worldCenter.x, k.worldCenter.y, k.worldCenter.z))
        let screenX = CGFloat(projected.x)
        let screenY = CGFloat(projected.y)

        // On-screen and in front → no hint.
        let onScreen = !behind
            && screenX >= 0 && screenX <= bounds.width
            && screenY >= 0 && screenY <= bounds.height
        if onScreen {
            if offscreenHint != nil { offscreenHint = nil }
            return
        }

        // Compute direction from screen centre toward the target (flip if behind).
        let cx = bounds.midX, cy = bounds.midY
        var dx = screenX - cx
        var dy = screenY - cy
        if behind {
            dx = -dx; dy = -dy
            if dx == 0 && dy == 0 { dy = 1 }
        }
        let angle = atan2(dy, dx)

        // Clamp arrow position to a ring just inside the screen edge.
        let margin: CGFloat = 46
        let maxX = bounds.width - margin
        let maxY = bounds.height - margin
        let scale = min(
            (dx > 0 ? (maxX - cx) : (margin - cx)) / (dx == 0 ? 1 : dx),
            (dy > 0 ? (maxY - cy) : (margin - cy)) / (dy == 0 ? 1 : dy)
        )
        let edgeX = cx + dx * max(0, scale)
        let edgeY = cy + dy * max(0, scale)

        offscreenHint = OffscreenHint(
            angle: Double(angle),
            position: CGPoint(x: edgeX, y: edgeY),
            behind: behind
        )
    }

    /// Per-frame update driven by ContentView's 33 Hz timer.
    /// Runs the critical-damped spring on each live track, then ages out
    /// tracks not matched in the last 5 seconds.
    func tickTracks() {
        let now = CACurrentMediaTime()
        let dtRaw = lastTickTime.map { now - $0 } ?? 0
        let dt = Float(min(dtRaw, 1.0 / 20.0))   // cap at 50 ms for stability
        lastTickTime = now

        if dt > 0 && !known.isEmpty {
            let omega: Float = 14.0   // rad/s → ~200 ms settle for a 10 cm step
            for i in known.indices where !known[i].reaping {
                let goal = simd_make_float3(known[i].targetTransform.columns.3)
                let delta = goal - known[i].worldCenter
                // Critical-damped spring, semi-implicit Euler.
                let accel = -2 * omega * known[i].velocity + omega * omega * delta
                known[i].velocity += accel * dt
                known[i].worldCenter += known[i].velocity * dt
                // Snap when we're within 0.5 mm + essentially stopped.
                if simd_length(delta) < 5e-4 && simd_length(known[i].velocity) < 5e-4 {
                    known[i].worldCenter = goal
                    known[i].velocity = .zero
                }
                // Compose rendered transform: rotation from target, translation tweened.
                var m = known[i].targetTransform
                m.columns.3 = simd_float4(known[i].worldCenter, 1)
                known[i].node.simdWorldTransform = m
            }
        }
        reapStaleTracks(now: now)
    }

    private func reapStaleTracks(now: CFTimeInterval) {
        for i in known.indices where !known[i].reaping {
            // Tesla-style hysteresis: confirmed tracks (seen ≥ 2 cycles) coast
            // for a long time; provisional tracks still get 8 s so a brief
            // phone shake / motion-blur doesn't pop a newly-seen box. Only
            // truly ghost single-frame detections age out.
            let timeout: CFTimeInterval = known[i].hits >= 2 ? 20.0 : 8.0
            if now - known[i].lastSeen > timeout {
                known[i].reaping = true
                let id = known[i].id
                let node = known[i].node
                node.runAction(SCNAction.fadeOut(duration: 0.3)) { [weak self] in
                    Task { @MainActor in self?.finalReap(id: id, node: node) }
                }
            }
        }
    }

    private func finalReap(id: UUID, node: SCNNode) {
        node.removeFromParentNode()
        known.removeAll { $0.id == id }
        detections.removeAll { $0.id == id }
        if selectedId == id {
            selectedId = nil
            offscreenHint = nil
        }
    }

    func toggleStream() {
        streamMode.toggle()
        if streamMode {
            lastDetectionCameraTransform = nil  // force first cycle
            if !isProcessing { detectNow() }
        } else {
            motionCheckTask?.cancel()
            motionCheckTask = nil
            setStatusIdle("Ready")
        }
    }

    /// Cycle the FSD render mode one step: camera → whiteOnWhite →
    /// whiteOnDark → blackOnWhite → camera. All three non-camera modes
    /// show the environment overlay (scene recon + plane dots); only
    /// whiteOnDark repaints objects to fsdSolid — the others keep the
    /// white ghost so you can still read them on the coloured background.
    func toggleFsdMode() {
        applyRenderMode(renderMode.next)
    }

    /// Apply a render mode without assuming the previous one — safe to call
    /// from init or after state changes. Centralises every visual side-effect
    /// of the mode (background, fog, overlay visibility, object palette).
    func applyRenderMode(_ mode: FSDRenderMode) {
        renderMode = mode
        guard let sceneView else { return }

        sceneView.scene.background.contents = mode.backgroundContents
        if mode.usesFog {
            sceneView.scene.fogColor = mode.fogColor
            sceneView.scene.fogStartDistance = FSDStyle.fogStart
            sceneView.scene.fogEndDistance = FSDStyle.fogEnd
            sceneView.scene.fogDensityExponent = 2.0
        } else {
            sceneView.scene.fogStartDistance = 0
            sceneView.scene.fogEndDistance = 0
        }

        let showEnv = mode.showsEnvironmentOverlay
        for node in sceneReconNodes.values { node.isHidden = !showEnv }
        for node in planeOverlayNodes.values { node.isHidden = !showEnv }

        for k in known {
            applyBoxerPalette(mode.boxerPalette, to: k.wireframeNode)
            // Contact shadow makes objects "sit on" a surface. In camera mode
            // the real scene's real shadows already do this job, so hide ours
            // to avoid double-shadowing; show in all FSD modes.
            k.shadowNode?.isHidden = !showEnv
        }
    }

    /// Stream-mode aware status: while streaming, show known count and cycle time.
    fileprivate func setStatusIdle(_ fallback: String) {
        if streamMode {
            let tail = lastCycleMs > 0 ? " · \(lastCycleMs) ms" : ""
            status = "Streaming · \(known.count) known\(tail)"
        } else {
            status = fallback
        }
    }

    nonisolated private func runPipeline(
        frame: ARFrame, boxer: BoxerNet, yolo: YOLODetector
    ) async throws -> [Detection3D] {
        // 1. Preprocess in parallel: two image resizes + depth extraction are
        //    independent and CPU-bound on different data.
        let capturedImage = frame.capturedImage
        let sceneDepthMap = frame.sceneDepth!.depthMap
        async let boxerImageT = Task.detached(priority: .userInitiated) {
            pixelBufferToFloatArray(capturedImage, targetSize: BoxerNet.imageSize).0
        }.value
        async let yoloImageT = Task.detached(priority: .userInitiated) {
            pixelBufferToFloatArray(capturedImage, targetSize: 640).0
        }.value
        async let depthMapT = Task.detached(priority: .userInitiated) {
            extractDepthMap(sceneDepthMap)
        }.value
        let boxerImage = await boxerImageT
        let yoloImage = await yoloImageT
        let depthMap = await depthMapT

        // 2. Run in parallel: YOLO 2D detection AND depth-map-heavy BoxerNet
        //    prep (gravity align + SDP patches + Plücker rays). They don't
        //    depend on each other — only bb2d couples them downstream.
        let camTransform = frame.camera.transform
        let scaledIntrinsics = scaleIntrinsicsWithCrop(
            frame.camera.intrinsics,
            from: frame.camera.imageResolution,
            toSize: BoxerNet.imageSize
        )
        async let yoloT = Task.detached(priority: .userInitiated) {
            try yolo.detect(image: yoloImage, imageWidth: 640, imageHeight: 640)
        }.value
        async let prepT = Task.detached(priority: .userInitiated) {
            boxer.prepareDepthInputs(depthMap: depthMap, intrinsics: scaledIntrinsics,
                                     cameraTransform: camTransform)
        }.value
        let yoloBoxes = try await yoloT
        let prep = await prepT

        guard !yoloBoxes.isEmpty else {
            await MainActor.run { self.setStatusIdle("No objects detected") }
            return []
        }

        // 2b. Drop YOLO boxes that cover a known 3D detection.
        let knownSnapshot = await MainActor.run { self.known }
        let camIntrinsics = frame.camera.intrinsics
        let imageSize = frame.camera.imageResolution
        let filteredYolo = yoloBoxes.filter { yBox in
            !knownSnapshot.contains { k in
                guard k.label == yBox.label else { return false }
                guard let p = projectWorldToYolo640(k.worldCenter, cameraTransform: camTransform,
                                                    intrinsics: camIntrinsics, imageResolution: imageSize)
                else { return false }
                return p.x >= CGFloat(yBox.xmin) && p.x <= CGFloat(yBox.xmax)
                    && p.y >= CGFloat(yBox.ymin) && p.y <= CGFloat(yBox.ymax)
            }
        }
        guard !filteredYolo.isEmpty else {
            await MainActor.run { self.setStatusIdle("No new objects") }
            return []
        }
        let topBoxes = Array(filteredYolo.sorted { $0.score > $1.score }.prefix(BoxerNet.numBoxes))

        // 3. Scale YOLO boxes (640 → imageSize) for BoxerNet.
        let scale = Float(BoxerNet.imageSize) / 640.0
        let boxes2D = topBoxes.map { box in
            Box2D(xmin: box.xmin * scale, ymin: box.ymin * scale,
                  xmax: box.xmax * scale, ymax: box.ymax * scale,
                  label: box.label, score: box.score)
        }

        // 4. BoxerNet 3D lifting using pre-computed prep.
        let conf = await MainActor.run { self.confidenceThreshold }
        let detections = try boxer.predict(
            image: boxerImage,
            sdpPatches: prep.sdpPatches,
            rayEncoding: prep.rayEncoding,
            T_wv: prep.T_wv,
            boxes2D: boxes2D,
            confidenceThreshold: conf
        )

        await MainActor.run { self.setStatusIdle("Ready") }
        return detections
    }

    // MARK: - 3D Box Rendering

    private func placeBoxes(_ detections: [Detection3D], in sceneView: ARSCNView) {
        let now = CACurrentMediaTime()

        // 1. Score all (detection, existing-track) pairs, greedy-match by ascending score.
        struct Pair { let d: Int; let t: Int; let score: Float }
        var pairs: [Pair] = []
        for (d, det) in detections.enumerated() {
            let newCenter = simd_make_float3(det.worldTransform.columns.3)
            let label = det.label ?? "object"
            for (t, k) in known.enumerated() where !k.reaping {
                if let s = matchScore(label: label, center: newCenter, size: det.size,
                                      against: k) {
                    pairs.append(Pair(d: d, t: t, score: s))
                }
            }
        }
        pairs.sort { $0.score < $1.score }

        var claimedDet = Set<Int>(); var claimedTrack = Set<Int>()
        for p in pairs where p.score <= 1.5 {
            if claimedDet.contains(p.d) || claimedTrack.contains(p.t) { continue }
            updateTrack(at: p.t, with: detections[p.d], now: now)
            claimedDet.insert(p.d); claimedTrack.insert(p.t)
        }

        // 2. Unclaimed detections → new tracks (existing creation path).
        var addedTags: [String] = []
        for (d, det) in detections.enumerated() where !claimedDet.contains(d) {
            let label = det.label ?? "object"
            let center = simd_make_float3(det.worldTransform.columns.3)

            let nextIdx = (instanceCountByLabel[label] ?? 0) + 1
            instanceCountByLabel[label] = nextIdx
            // Allocate the track UUID up-front so the on-screen tag (here)
            // and the bridge / sim sprite (computed from the same UUID
            // browser-side) read the same shortId.
            let trackId = UUID()
            let info = DetectionInfo(id: trackId, label: label, instanceIndex: nextIdx,
                                     size: det.size, confidence: det.confidence)
            let tag = "\(label) #\(info.shortId)"
            addedTags.append(tag)

            // Anchor node: empty, carries the detection's world transform. The
            // visual child is either a class-specific mesh (Tesla "ghost-proxy"
            // look) or the generic translucent-box + wireframe fallback.
            let node = SCNNode()
            node.simdWorldTransform = det.worldTransform

            let wireframeNode: SCNNode
            if let meshNode = meshLibrary.node(for: label) {
                node.addChildNode(meshNode)
                // Highlight + pulse still target this node so long-press works.
                wireframeNode = meshNode
            } else {
                let box = SCNBox(width: CGFloat(det.size.x), height: CGFloat(det.size.y),
                                 length: CGFloat(det.size.z), chamferRadius: 0)
                let mat = SCNMaterial()
                mat.diffuse.contents = UIColor.white.withAlphaComponent(0.15)
                mat.isDoubleSided = true
                box.materials = [mat]
                node.addChildNode(SCNNode(geometry: box))
                wireframeNode = addWireframe(to: node, size: det.size, color: .white, radius: 0.005)
            }
            // Apply the *current* render mode's palette so a detection made
            // while in FSD whiteOnDark comes up dark immediately, not as a
            // white ghost that only darkens on the next mode toggle.
            applyBoxerPalette(renderMode.boxerPalette, to: wireframeNode)
            // Soft radial shadow decal grounding the object on its surface
            // — visible in FSD modes, hidden in camera mode (real shadows
            // from the live scene already do this work there).
            let shadowNode = addContactShadow(to: node, size: det.size)
            shadowNode.isHidden = !renderMode.showsEnvironmentOverlay
            addLabel(tag, to: node, offset: det.size.y / 2 + 0.03)

            sceneView.scene.rootNode.addChildNode(node)

            known.append(KnownDetection(
                id: trackId, label: label, instanceIndex: nextIdx,
                worldCenter: center, size: det.size,
                node: node, wireframeNode: wireframeNode,
                shadowNode: shadowNode,
                targetTransform: det.worldTransform,
                velocity: .zero, lastSeen: now, reaping: false
            ))
            self.detections.append(info)

            if known.count >= Self.maxKnown {
                if streamMode { toggleStream() }
                status = "Reached \(Self.maxKnown) objects — stream stopped"
                break
            }
        }
        if !addedTags.isEmpty {
            flashAdded(addedTags.joined(separator: ", "))
        }
    }

    /// Score a candidate (new-detection, existing-track) pair. Returns nil if
    /// the pair isn't a plausible match at all; lower score means better.
    ///
    /// Same-label gate tightened from 0.75 → 0.4 × maxDim and volRatio ≥ 0.6
    /// (from 0.35) to fix Mickey-mug ↔ Coca-Cola-can ID switching observed
    /// 2026-04-27. Earlier wider gate (25 cm absolute floor on max(0.25,
    /// 0.75 × maxDim)) was associating two genuinely-different cup-shaped
    /// objects under the same track when BoxerNet at 480-px input
    /// momentarily mis-classified the can as "cup". Tighter gate + stricter
    /// vol ratio means a same-label match now needs the new detection both
    /// near the existing track AND of similar size.
    /// Cross-label soft-merge unchanged (already tight at 0.5 × maxDim).
    private func matchScore(label: String, center: simd_float3, size: simd_float3,
                            against k: KnownDetection) -> Float? {
        let newMaxDim = max(size.x, max(size.y, size.z))
        let kMaxDim = max(k.size.x, max(k.size.y, k.size.z))
        let dist = simd_distance(k.worldCenter, center)
        let newVol = size.x * size.y * size.z
        let kVol = k.size.x * k.size.y * k.size.z
        let volRatio = min(newVol, kVol) / max(newVol, kVol)
        let gate = max(Float(0.12), 0.4 * max(newMaxDim, kMaxDim))

        if k.label == label {
            guard dist < gate, volRatio >= 0.6 else { return nil }
            return dist / gate + 0.5 * (1 - volRatio)
        } else {
            // Soft cross-class merge — catches cup/bottle YOLO flips.
            guard dist < 0.5 * max(newMaxDim, kMaxDim), volRatio >= 0.5 else { return nil }
            return dist / gate + 0.5 * (1 - volRatio) + 0.3  // small cross-class penalty
        }
    }

    /// Update an existing track with a new observation. Size is frozen on
    /// creation; we only push the target transform and refresh lastSeen. The
    /// DetectionInfo row stays the same (same UUID → selection sticks).
    private func updateTrack(at idx: Int, with det: Detection3D, now: CFTimeInterval) {
        known[idx].targetTransform = det.worldTransform
        known[idx].lastSeen = now
        known[idx].hits += 1
        // If the track was fading out, cancel that — it's been seen again.
        if known[idx].reaping {
            known[idx].node.removeAllActions()
            known[idx].node.opacity = 1.0
            known[idx].reaping = false
        }
    }

    private func flashAdded(_ text: String) {
        lastAdded = "+ \(text)"
        lastAddedClearTask?.cancel()
        lastAddedClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.lastAdded = nil }
        }
    }


    /// Build a thick wireframe by rendering each of the 12 edges as a 4-sided
    /// triangular tube (radius = `radius` metres). All 12 tubes merge into a
    /// single SCNGeometry so it stays 1 node + 1 draw call per box — same cost
    /// as the line-primitive version but with configurable line thickness.
    /// Returns the attached wireframe node so callers can animate / recolour it.
    @discardableResult
    private func addWireframe(to parent: SCNNode, size: simd_float3, color: UIColor, radius: Float) -> SCNNode {
        let hw = size.x / 2, hh = size.y / 2, hd = size.z / 2
        let corners: [simd_float3] = [
            simd_float3(-hw, -hh, -hd), simd_float3( hw, -hh, -hd),
            simd_float3( hw, -hh,  hd), simd_float3(-hw, -hh,  hd),
            simd_float3(-hw,  hh, -hd), simd_float3( hw,  hh, -hd),
            simd_float3( hw,  hh,  hd), simd_float3(-hw,  hh,  hd),
        ]
        let edgeIdx: [(Int, Int)] = [
            (0,1), (1,2), (2,3), (3,0),
            (4,5), (5,6), (6,7), (7,4),
            (0,4), (1,5), (2,6), (3,7),
        ]

        var verts: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [Int32] = []
        verts.reserveCapacity(12 * 8)
        normals.reserveCapacity(12 * 8)
        indices.reserveCapacity(12 * 24)

        for (a, b) in edgeIdx {
            let p0 = corners[a], p1 = corners[b]
            let dir = simd_normalize(p1 - p0)
            // Pick a stable reference axis non-parallel to dir.
            let refUp = abs(dir.y) < 0.99 ? simd_float3(0, 1, 0) : simd_float3(1, 0, 0)
            let right = simd_normalize(simd_cross(dir, refUp)) * radius
            let up = simd_normalize(simd_cross(right, dir)) * radius

            let offsets: [simd_float3] = [right, up, -right, -up]
            let base = Int32(verts.count)

            for off in offsets {
                let world = p0 + off
                verts.append(SCNVector3(world.x, world.y, world.z))
                let n = simd_normalize(off)
                normals.append(SCNVector3(n.x, n.y, n.z))
            }
            for off in offsets {
                let world = p1 + off
                verts.append(SCNVector3(world.x, world.y, world.z))
                let n = simd_normalize(off)
                normals.append(SCNVector3(n.x, n.y, n.z))
            }
            // 4 side quads (each = 2 triangles) around the tube.
            for i in 0..<4 {
                let next = (i + 1) % 4
                let v0 = base + Int32(i)
                let v1 = base + Int32(next)
                let v2 = base + 4 + Int32(next)
                let v3 = base + 4 + Int32(i)
                indices.append(contentsOf: [v0, v1, v2, v0, v2, v3])
            }
        }

        let vertexSource = SCNGeometrySource(vertices: verts)
        let normalSource = SCNGeometrySource(normals: normals)
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.stride)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .constant

        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
        geometry.materials = [material]
        let wireframeNode = SCNNode(geometry: geometry)
        parent.addChildNode(wireframeNode)
        return wireframeNode
    }

    private func addLabel(_ text: String, to parent: SCNNode, offset: Float) {
        // SCNText.font sizes in typographic points — NOT world metres.
        // Build at a normal font size, then scale the node down to the
        // desired world-space height.
        let scnText = SCNText(string: text, extrusionDepth: 0.0)
        scnText.font = UIFont.monospacedSystemFont(ofSize: 48, weight: .medium)
        scnText.flatness = 0.1
        scnText.firstMaterial?.diffuse.contents = UIColor.white
        scnText.firstMaterial?.lightingModel = .constant  // no shading; crisp edges

        let (bMin, bMax) = scnText.boundingBox
        let localW = Float(bMax.x - bMin.x)
        let localH = Float(bMax.y - bMin.y)
        let desiredWorldHeight: Float = 0.006   // 6 mm — subtle HUD-style tag
        let scale = desiredWorldHeight / max(localH, 1)

        let node = SCNNode(geometry: scnText)
        node.scale = SCNVector3(scale, scale, scale)
        node.position = SCNVector3(-localW * scale / 2, offset, 0)
        node.constraints = [SCNBillboardConstraint()]
        parent.addChildNode(node)
    }

    func clearBoxes() {
        known.forEach { $0.node.removeFromParentNode() }
        known.removeAll()
        detections.removeAll()
        instanceCountByLabel.removeAll()
        selectedId = nil
        offscreenHint = nil
        lastTickTime = nil
    }

    // MARK: - Bridge snapshot (for SceneReportStreamer)

    /// Build a transport-ready snapshot of the current perception state for
    /// the bridge WebSocket. Returns nil if there's no ARKit session yet —
    /// we never publish without a camera pose, so the host can always rely
    /// on `camera.pose_world` being meaningful when present.
    ///
    /// Coordinates are converted from ARKit world → MuJoCo world via a fixed
    /// axis swap (see ``BridgeCoord/arkitToMujoco(_:)``). This is the
    /// identity-calibration fallback used until Step 2e introduces AprilTag
    /// hand-eye calibration; once that lands, the swap is the first stage of
    /// a two-stage transform (arkit → session-arkit-base → arm-base).
    ///
    /// Size is forwarded as-is in `[x, y, z]` order because `KnownDetection`
    /// doesn't separate object-local from world-aligned extents. Yaw is
    /// currently zeroed for the same reason — recovering a faithful yaw from
    /// `targetTransform` under the ARKit→MuJoCo swap is TODO for Step 2e.
    func bridgeSnapshot(includeImage: Bool = false) -> BridgeSceneReport? {
        guard let frame = sceneView?.session.currentFrame else { return nil }

        let cam = frame.camera.transform
        let nativeRes = frame.camera.imageResolution
        let poseMujoco = BridgeCamera(
            pose_world: Self.serializeTransform(cam),
            image_size: [Int(nativeRes.width), Int(nativeRes.height)]
        )

        // Pinhole intrinsics for the NATIVE camera image (the unrotated
        // capturedImage CVPixelBuffer). The browser uses these to project
        // 3D OBB centres into the same image Gemini sees, so 2D detections
        // can be matched to track UUIDs by closest-pixel distance.
        let intr = frame.camera.intrinsics
        let intrinsics = BridgeCameraIntrinsics(
            fxfycxcy: [intr[0, 0], intr[1, 1], intr[2, 0], intr[2, 1]],
            image_size_native: [Int(nativeRes.width), Int(nativeRes.height)]
        )

        let yawDeg = BridgeSettings.shared.worldYawDeg
        let objects: [BridgeObject] = known.map { k in
            let centerMj = BridgeCoord.arkitToMujoco(k.worldCenter, yawDeg: yawDeg)
            return BridgeObject(
                id: k.id.uuidString,
                label: k.label,
                center_world: [centerMj.x, centerMj.y, centerMj.z],
                size_m: [k.size.x, k.size.y, k.size.z],
                yaw_rad: 0.0,
                confidence: BridgeCoord.confidenceFromHits(k.hits)
            )
        }

        let image: BridgeImage? = includeImage ? Self.captureFrameJPEG(from: frame) : nil

        return BridgeSceneReport(
            version: 1,
            coordinate_frame: "mujoco_world",
            timestamp: Date().timeIntervalSince1970,
            camera: poseMujoco,
            objects: objects,
            camera_intrinsics: intrinsics,
            image: image,
            world_yaw_deg: yawDeg
        )
    }

    private static func serializeTransform(_ m: simd_float4x4) -> [Float] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w,
        ]
    }

    /// Encode the current ARFrame's camera image as a base64 JPEG, downscaled
    /// so its longer side is at most ~640 px. Lossy q=0.6 gives ~30–80 KB —
    /// plenty for Gemini-ER 1.6 spatial reasoning, tiny on a LAN WebSocket.
    /// Runs on whichever queue called bridgeSnapshot (typically MainActor);
    /// JPEG encoding is hardware-accelerated, ~10 ms.
    private static func captureFrameJPEG(from frame: ARFrame, maxDim: CGFloat = 640, quality: CGFloat = 0.6) -> BridgeImage? {
        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let nativeW = ciImage.extent.width
        let nativeH = ciImage.extent.height
        let scale = min(maxDim / nativeW, maxDim / nativeH, 1.0)
        let scaled: CIImage = scale < 1
            ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ciImage
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: quality) else { return nil }
        return BridgeImage(
            base64: jpegData.base64EncodedString(),
            mime: "image/jpeg",
            width: Int(scaled.extent.width),
            height: Int(scaled.extent.height)
        )
    }

    // MARK: - Scene Reconstruction (FSD mode mesh)

    fileprivate func attachSceneReconMesh(node: SCNNode, anchor: ARMeshAnchor) {
        node.geometry = makeSceneReconGeometry(from: anchor.geometry)
        node.isHidden = !renderMode.showsEnvironmentOverlay
        sceneReconNodes[anchor.identifier] = node
        meshAnchors[anchor.identifier] = anchor
    }

    fileprivate func refreshSceneReconMesh(node: SCNNode, anchor: ARMeshAnchor) {
        node.geometry = makeSceneReconGeometry(from: anchor.geometry)
        node.isHidden = !renderMode.showsEnvironmentOverlay
        meshAnchors[anchor.identifier] = anchor
    }

    fileprivate func detachSceneReconMesh(anchor: ARMeshAnchor) {
        sceneReconNodes.removeValue(forKey: anchor.identifier)
        meshAnchors.removeValue(forKey: anchor.identifier)
    }

    // MARK: - Plane Overlay (Q4 — Tesla dot-grid on detected planes)

    fileprivate func attachPlaneOverlay(node: SCNNode, anchor: ARPlaneAnchor) {
        installDotOverlay(on: node, anchor: anchor,
                          meshAnchors: Array(meshAnchors.values))
        node.isHidden = !renderMode.showsEnvironmentOverlay
        planeOverlayNodes[anchor.identifier] = node
    }

    fileprivate func refreshPlaneOverlay(node: SCNNode, anchor: ARPlaneAnchor) {
        installDotOverlay(on: node, anchor: anchor,
                          meshAnchors: Array(meshAnchors.values))
        node.isHidden = !renderMode.showsEnvironmentOverlay
    }

    fileprivate func detachPlaneOverlay(anchor: ARPlaneAnchor) {
        planeOverlayNodes.removeValue(forKey: anchor.identifier)
    }
}

// MARK: - ARSCNViewDelegate (scene reconstruction mesh lifecycle)

extension ARViewModel: ARSCNViewDelegate {
    nonisolated func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        if let meshAnchor = anchor as? ARMeshAnchor {
            Task { @MainActor [weak self] in
                self?.attachSceneReconMesh(node: node, anchor: meshAnchor)
            }
        } else if let planeAnchor = anchor as? ARPlaneAnchor {
            Task { @MainActor [weak self] in
                self?.attachPlaneOverlay(node: node, anchor: planeAnchor)
            }
        }
    }

    nonisolated func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        if let meshAnchor = anchor as? ARMeshAnchor {
            Task { @MainActor [weak self] in
                self?.refreshSceneReconMesh(node: node, anchor: meshAnchor)
            }
        } else if let planeAnchor = anchor as? ARPlaneAnchor {
            Task { @MainActor [weak self] in
                self?.refreshPlaneOverlay(node: node, anchor: planeAnchor)
            }
        }
    }

    nonisolated func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        if let meshAnchor = anchor as? ARMeshAnchor {
            Task { @MainActor [weak self] in
                self?.detachSceneReconMesh(anchor: meshAnchor)
            }
        } else if let planeAnchor = anchor as? ARPlaneAnchor {
            Task { @MainActor [weak self] in
                self?.detachPlaneOverlay(anchor: planeAnchor)
            }
        }
    }
}

// MARK: - Image Helpers

nonisolated func pixelBufferToFloatArray(
    _ pixelBuffer: CVPixelBuffer,
    targetSize: Int = BoxerNet.imageSize
) -> ([Float], Int, Int) {
    var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext()

    // Center-crop to square.
    let w = ciImage.extent.width, h = ciImage.extent.height
    let side = min(w, h)
    ciImage = ciImage.cropped(to: CGRect(x: (w - side) / 2, y: (h - side) / 2,
                                          width: side, height: side))

    // Resize to target.
    let scale = CGFloat(targetSize) / side
    let resized = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    // Render to RGBA.
    var rgba = [UInt8](repeating: 0, count: targetSize * targetSize * 4)
    context.render(resized, toBitmap: &rgba, rowBytes: targetSize * 4,
                   bounds: CGRect(x: resized.extent.origin.x, y: resized.extent.origin.y,
                                  width: CGFloat(targetSize), height: CGFloat(targetSize)),
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

    // RGBA → CHW float32.
    let n = targetSize * targetSize
    var result = [Float](repeating: 0, count: 3 * n)
    for i in 0..<n {
        result[i]         = Float(rgba[i * 4])     / 255.0
        result[n + i]     = Float(rgba[i * 4 + 1]) / 255.0
        result[2 * n + i] = Float(rgba[i * 4 + 2]) / 255.0
    }
    return (result, targetSize, targetSize)
}

nonisolated func extractDepthMap(_ depthBuffer: CVPixelBuffer) -> [[Float]] {
    CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }

    let h = CVPixelBufferGetHeight(depthBuffer)
    let w = CVPixelBufferGetWidth(depthBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(depthBuffer)
    let base = CVPixelBufferGetBaseAddress(depthBuffer)!

    var result = [[Float]](repeating: [Float](repeating: 0, count: w), count: h)
    for y in 0..<h {
        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
        for x in 0..<w { result[y][x] = row[x] }
    }
    return result
}

/// Project a world-space point into the YOLO 640×640 image space (center-crop square + scale).
/// Returns nil if the point is behind the camera.
nonisolated func projectWorldToYolo640(
    _ world: simd_float3,
    cameraTransform: simd_float4x4,
    intrinsics: simd_float3x3,
    imageResolution: CGSize
) -> CGPoint? {
    let camInv = cameraTransform.inverse
    let pCam4 = camInv * simd_float4(world.x, world.y, world.z, 1)
    // ARKit cam: +X right, +Y up, -Z forward. Intrinsics expect OpenCV (+Y down, +Z forward).
    let pCV = simd_float3(pCam4.x, -pCam4.y, -pCam4.z)
    guard pCV.z > 0.01 else { return nil }
    let uvw = intrinsics * pCV
    let u = uvw.x / uvw.z
    let v = uvw.y / uvw.z
    let w = Float(imageResolution.width)
    let h = Float(imageResolution.height)
    let side = min(w, h)
    let s = Float(640) / side
    return CGPoint(x: CGFloat((u - (w - side) / 2) * s),
                   y: CGFloat((v - (h - side) / 2) * s))
}

nonisolated func scaleIntrinsicsWithCrop(
    _ intrinsics: simd_float3x3, from: CGSize, toSize: Int
) -> simd_float3x3 {
    let w = Float(from.width), h = Float(from.height)
    let side = min(w, h)
    let scale = Float(toSize) / side

    var s = intrinsics
    s[0][0] *= scale                                     // fx
    s[1][1] *= scale                                     // fy
    s[2][0] = (intrinsics[2][0] - (w - side) / 2) * scale  // cx
    s[2][1] = (intrinsics[2][1] - (h - side) / 2) * scale  // cy
    return s
}
