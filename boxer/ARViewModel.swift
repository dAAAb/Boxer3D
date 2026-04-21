import Foundation
import ARKit
import Combine
import SceneKit
import simd

struct DetectionInfo: Identifiable {
    let id = UUID()
    let label: String
    let instanceIndex: Int
    let size: simd_float3
    let confidence: Float
}

private struct KnownDetection {
    let id: UUID
    let label: String
    let instanceIndex: Int
    let worldCenter: simd_float3
    let size: simd_float3
    let node: SCNNode
    let wireframeNode: SCNNode
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
final class ARViewModel: ObservableObject {
    @Published var status: String = "Initializing..."
    @Published var isProcessing: Bool = false
    @Published var detections: [DetectionInfo] = []
    @Published var confidenceThreshold: Float = 0.8
    @Published var streamMode: Bool = false
    @Published var lastAdded: String? = nil
    @Published var lastCycleMs: Int = 0
    @Published var selectedId: UUID? = nil
    @Published var offscreenHint: OffscreenHint? = nil

    var sceneView: ARSCNView?
    private var boxerNet: BoxerNet?
    private var yoloDetector: YOLODetector?
    private var known: [KnownDetection] = []
    private var cycleStart: Date?
    private var lastAddedClearTask: Task<Void, Never>?
    /// Running count of detections per class, used to number instances
    /// ("bottle #3"). Reset on clearBoxes.
    private var instanceCountByLabel: [String: Int] = [:]
    private var memoryWarningObserver: NSObjectProtocol?
    private var lastDetectionCameraTransform: simd_float4x4?
    private var motionCheckTask: Task<Void, Never>?
    /// Incremented each cycle. If memory warning fires mid-predict, we bump this so
    /// the in-flight Task's completion is discarded instead of updating the scene.
    private var cycleToken: Int = 0

    /// Hard cap on accumulated detections. With native CoreML (single 192 MB
    /// mlpackage, no ORT doubling) + line-primitive wireframes (2 nodes/box
    /// instead of 14), memory and rendering head-room are both much larger.
    private static let maxKnown = 50
    /// Minimum camera translation (m) since last detection before triggering next cycle.
    private static let motionTranslationThreshold: Float = 0.20   // 20 cm
    /// Minimum camera rotation (rad) since last detection before triggering next cycle.
    private static let motionRotationThreshold: Float = 0.35      // ~20°
    /// Minimum delay between cycles (ms) — lets ORT/CoreML release buffers.
    private static let cycleCooldownMs: Int = 600

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

    /// Poll camera motion until it exceeds threshold, then kick off next cycle.
    /// Enforces a minimum cooldown so ORT/CoreML can release buffers between cycles.
    private func scheduleNextWhenMoving() {
        motionCheckTask?.cancel()
        let cooldown = UInt64(Self.cycleCooldownMs) * 1_000_000
        motionCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: cooldown)
            while !Task.isCancelled {
                guard let self else { return }
                let go = await MainActor.run { () -> Bool in
                    guard self.streamMode else { return false }
                    return self.hasMovedEnough()
                }
                if go {
                    await MainActor.run {
                        guard self.streamMode, !self.isProcessing else { return }
                        self.detectNow()
                    }
                    return
                }
                await MainActor.run {
                    if self.streamMode {
                        self.status = "Streaming · \(self.known.count) known · idle"
                    }
                }
                try? await Task.sleep(nanoseconds: 250_000_000) // 250 ms poll
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
        // Reset all wireframes.
        for k in known {
            k.wireframeNode.removeAction(forKey: "pulse")
            k.wireframeNode.simdScale = simd_float3(1, 1, 1)
            k.wireframeNode.geometry?.firstMaterial?.diffuse.contents = UIColor.white
        }
        guard let id, let target = known.first(where: { $0.id == id }) else { return }
        target.wireframeNode.geometry?.firstMaterial?.diffuse.contents = UIColor.systemYellow
        let pulse = SCNAction.sequence([
            SCNAction.scale(to: 1.12, duration: 0.45),
            SCNAction.scale(to: 1.00, duration: 0.45),
        ])
        target.wireframeNode.runAction(SCNAction.repeatForever(pulse), forKey: "pulse")
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
        var addedTags: [String] = []
        for det in detections {
            let label = det.label ?? "object"
            let center = simd_make_float3(det.worldTransform.columns.3)
            if isDuplicate(label: label, center: center, size: det.size) { continue }

            // Next sequential index for this class: "bottle #1", "bottle #2", …
            let nextIdx = (instanceCountByLabel[label] ?? 0) + 1
            instanceCountByLabel[label] = nextIdx
            let tag = "\(label) #\(nextIdx)"
            addedTags.append(tag)

            // Semi-transparent white fill — Tesla-style proxy.
            let box = SCNBox(width: CGFloat(det.size.x), height: CGFloat(det.size.y),
                             length: CGFloat(det.size.z), chamferRadius: 0)
            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor.white.withAlphaComponent(0.15)
            mat.isDoubleSided = true
            box.materials = [mat]

            let node = SCNNode(geometry: box)
            node.simdWorldTransform = det.worldTransform

            let wireframeNode = addWireframe(to: node, size: det.size, color: .white, radius: 0.005)
            addLabel(tag, to: node, offset: det.size.y / 2 + 0.03)

            sceneView.scene.rootNode.addChildNode(node)

            let info = DetectionInfo(label: label, instanceIndex: nextIdx,
                                     size: det.size, confidence: det.confidence)
            known.append(KnownDetection(id: info.id, label: label, instanceIndex: nextIdx,
                                        worldCenter: center, size: det.size,
                                        node: node, wireframeNode: wireframeNode))
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

    private func flashAdded(_ text: String) {
        lastAdded = "+ \(text)"
        lastAddedClearTask?.cancel()
        lastAddedClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.lastAdded = nil }
        }
    }

    /// Dedup: two passes.
    /// 1. **Same label** — loose thresholds, tolerates position drift from the
    ///    480-input noise. Two same-class objects need to be >1 full extent
    ///    apart to count as distinct.
    /// 2. **Cross label** — tight overlap + similar volume. Catches YOLO class
    ///    flip-flops (cup ↔ bottle ↔ wine glass, which COCO classes routinely
    ///    confuse) on the same physical object.
    private func isDuplicate(label: String, center: simd_float3, size: simd_float3) -> Bool {
        let newVol = size.x * size.y * size.z
        let newMaxDim = max(size.x, max(size.y, size.z))
        for k in known {
            let kMaxDim = max(k.size.x, max(k.size.y, k.size.z))
            let dist = simd_distance(k.worldCenter, center)
            let kVol = k.size.x * k.size.y * k.size.z
            let volRatio = min(newVol, kVol) / max(newVol, kVol)

            if k.label == label {
                // Same label: overlap if centre distance < sum of half-max-dims.
                if dist < (newMaxDim + kMaxDim) * 0.5 && volRatio > 0.20 {
                    return true
                }
            } else {
                // Different label: stricter — centres must be well inside each
                // other's extent (avg half-max) and volumes within 2×.
                let avgHalf = (newMaxDim + kMaxDim) * 0.25
                if dist < avgHalf && volRatio > 0.5 {
                    return true
                }
            }
        }
        return false
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
        let scnText = SCNText(string: text, extrusionDepth: 0.003)
        scnText.font = UIFont.systemFont(ofSize: 0.022, weight: .semibold)
        scnText.firstMaterial?.diffuse.contents = UIColor.white
        scnText.firstMaterial?.lightingModel = .constant   // no shading, crisper
        scnText.flatness = 0.1
        let node = SCNNode(geometry: scnText)
        // Centre the text roughly above the box (SCNText origin is bottom-left).
        let bbox = scnText.boundingBox
        let textWidth = Float(bbox.max.x - bbox.min.x)
        node.position = SCNVector3(-textWidth / 2, offset, 0)
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
