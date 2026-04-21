// BoxerNet.swift
// ONNX Runtime inference wrapper for BoxerNet on iOS.
//
// Dependencies (add to Package.swift or Podfile):
//   - onnxruntime-objc (via SPM: https://github.com/microsoft/onnxruntime-swift-package-manager)
//
// Usage:
//   let boxer = try BoxerNet(modelPath: Bundle.main.path(forResource: "BoxerNet", ofType: "onnx")!)
//   let results = try boxer.predict(
//       pixelBuffer: frame.capturedImage,
//       depthMap: frame.sceneDepth!.depthMap,
//       cameraIntrinsics: frame.camera.intrinsics,
//       cameraTransform: frame.camera.transform,
//       boxes2D: yoloDetections
//   )

import Foundation
import Accelerate
import simd
import CoreML

// MARK: - Data Types

/// A single 3D bounding box detection.
struct Detection3D {
    /// Centre position in ARKit world coordinates (metres).
    let center: simd_float3
    /// Box dimensions (width, height, depth) in metres.
    let size: simd_float3
    /// Yaw angle in radians [-pi/2, pi/2].
    let yaw: Float
    /// Detection confidence [0, 1].
    let confidence: Float
    /// Full 4x4 transform for placing in ARKit scene.
    let worldTransform: simd_float4x4
    /// Object class label from YOLO.
    let label: String?
}

/// A 2D bounding box from YOLO in pixel coordinates.
struct Box2D {
    let xmin: Float
    let ymin: Float
    let xmax: Float
    let ymax: Float
    var label: String? = nil
    var score: Float = 0
}

// MARK: - BoxerNet

final class BoxerNet: @unchecked Sendable {
    private let model: MLModel

    /// Image size the model expects. Halved from 960 to 480 (Boxer3D Flash Lv 2)
    /// — 4-6× speedup since DINOv3 self-attn is O(N²) in token count.
    /// Accuracy may drift vs. the 960-trained checkpoint until fine-tuned.
    static let imageSize: Int = 480
    /// Patch size used by DINOv3.
    static let patchSize: Int = 16
    /// Feature grid dimensions.
    static let gridH: Int = imageSize / patchSize  // 30
    static let gridW: Int = imageSize / patchSize  // 30
    static let numPatches: Int = gridH * gridW     // 900

    /// Fixed number of boxes this (static-shape) model expects per call.
    /// Must match `num_boxes` baked into the converted .mlpackage.
    /// Unused slots get padded with zero boxes and their outputs are discarded.
    static let numBoxes: Int = 3

    /// Loads the .mlmodelc Xcode produced from the dragged-in BoxerNet.mlpackage.
    /// Falls back to on-device compilation of .mlpackage if only that is present.
    init() throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all   // 815/815 ops land on ANE for this model.

        let url: URL
        if let compiled = Bundle.main.url(forResource: "BoxerNetModel", withExtension: "mlmodelc") {
            url = compiled
        } else if let pkg = Bundle.main.url(forResource: "BoxerNetModel", withExtension: "mlpackage") {
            url = try MLModel.compileModel(at: pkg)
        } else {
            throw NSError(domain: "BoxerNet", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "BoxerNetModel.mlpackage not in bundle — drag it into the Xcode project."])
        }
        model = try MLModel(contentsOf: url, configuration: config)
    }

    // MARK: - Public API

    /// Run full pipeline: preprocess, infer, postprocess.
    ///
    /// - Parameters:
    ///   - image: RGB pixel data resized to 960x960, float32 in [0, 1], shape (3, 960, 960) in CHW.
    ///   - depthMap: LiDAR depth map from ARKit (metres). Can be smaller than 960x960.
    ///   - intrinsics: 3x3 camera intrinsics matrix from ARFrame.camera.intrinsics.
    ///   - cameraTransform: 4x4 world transform from ARFrame.camera.transform.
    ///   - boxes2D: Array of YOLO 2D detections in pixel coords (for the 960x960 image).
    ///   - confidenceThreshold: Minimum confidence to keep a detection.
    /// - Returns: Array of 3D detections in world coordinates.
    /// Depth-map-heavy preprocessing that can run in parallel with YOLO:
    /// gravity-aligned voxel frame, SDP patches, Plücker ray encoding.
    /// Returns everything the inference step needs plus the voxel→world
    /// transform for post-processing.
    nonisolated func prepareDepthInputs(
        depthMap: [[Float]],
        intrinsics: simd_float3x3,
        cameraTransform: simd_float4x4
    ) -> (sdpPatches: [Float], rayEncoding: [Float], T_wv: simd_float4x4) {
        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]

        // ARKit (-Z forward, +Y up) → OpenCV (+Z forward, +Y down) camera local.
        let flipYZ = simd_float4x4(columns: (
            simd_float4( 1,  0,  0, 0),
            simd_float4( 0, -1,  0, 0),
            simd_float4( 0,  0, -1, 0),
            simd_float4( 0,  0,  0, 1)
        ))
        let T_wc = cameraTransform * flipYZ
        let T_wv = gravityAlign(T_worldCam: T_wc)
        let T_vc = T_wv.inverse * T_wc

        let sdp = buildSDPPatches(depthMap: depthMap, fx: fx, fy: fy, cx: cx, cy: cy)
        let ray = buildRayEncoding(T_vc: T_vc, fx: fx, fy: fy, cx: cx, cy: cy)
        return (sdp, ray, T_wv)
    }

    /// Back-compat: do the prep here, then run inference. Kept so the old
    /// call-site signature still works.
    nonisolated func predict(
        image: [Float],
        depthMap: [[Float]],
        intrinsics: simd_float3x3,
        cameraTransform: simd_float4x4,
        boxes2D: [Box2D],
        confidenceThreshold: Float = 0.3
    ) throws -> [Detection3D] {
        guard !boxes2D.isEmpty else { return [] }
        let prep = prepareDepthInputs(depthMap: depthMap, intrinsics: intrinsics,
                                      cameraTransform: cameraTransform)
        return try predict(image: image, sdpPatches: prep.sdpPatches,
                           rayEncoding: prep.rayEncoding, T_wv: prep.T_wv,
                           boxes2D: boxes2D, confidenceThreshold: confidenceThreshold)
    }

    /// Main inference path — takes pre-computed depth-map prep tensors so the
    /// caller can overlap this step with an independent task (e.g. YOLO).
    nonisolated func predict(
        image: [Float],
        sdpPatches: [Float],
        rayEncoding: [Float],
        T_wv: simd_float4x4,
        boxes2D: [Box2D],
        confidenceThreshold: Float = 0.3
    ) throws -> [Detection3D] {
        guard !boxes2D.isEmpty else { return [] }

        // Normalise 2D boxes. Model input shape is [1, numBoxes, 4]; pad slots.
        let W = Float(Self.imageSize)
        let H = Float(Self.imageSize)
        let validM = min(boxes2D.count, Self.numBoxes)
        var bb2dFlat = [Float](repeating: 0, count: Self.numBoxes * 4)
        for idx in 0..<validM {
            let box = boxes2D[idx]
            bb2dFlat[idx * 4 + 0] = (box.xmin + 0.5) / W
            bb2dFlat[idx * 4 + 1] = (box.xmax + 0.5) / W
            bb2dFlat[idx * 4 + 2] = (box.ymin + 0.5) / H
            bb2dFlat[idx * 4 + 3] = (box.ymax + 0.5) / H
        }

        let (centers, sizes, yaws, confidences) = try runInference(
            image: image,
            sdpPatches: sdpPatches,
            bb2d: bb2dFlat,
            rayEncoding: rayEncoding,
            numBoxes: Self.numBoxes
        )

        var detections: [Detection3D] = []
        for i in 0..<validM {
            let conf = confidences[i]
            guard conf >= confidenceThreshold else { continue }

            let centerVoxel = simd_float3(centers[i * 3], centers[i * 3 + 1], centers[i * 3 + 2])
            let size = simd_float3(sizes[i * 3], sizes[i * 3 + 1], sizes[i * 3 + 2])
            let yaw = yaws[i]

            // Transform centre: voxel → world.
            let centerWorld = (T_wv * simd_float4(centerVoxel, 1.0)).xyz

            // Build world rotation: T_world_voxel.R * R_yaw.
            let R_wv = upperLeft3x3(T_wv)
            let R_yaw = rotationZ(angle: yaw)
            let R_world = R_wv * R_yaw

            // Build 4x4 transform for ARKit placement.
            var transform = simd_float4x4(1.0)
            transform[0] = simd_float4(R_world[0], 0)
            transform[1] = simd_float4(R_world[1], 0)
            transform[2] = simd_float4(R_world[2], 0)
            transform[3] = simd_float4(centerWorld, 1)

            detections.append(Detection3D(
                center: centerWorld,
                size: size,
                yaw: yaw,
                confidence: conf,
                worldTransform: transform,
                label: boxes2D[i].label
            ))
        }

        return detections
    }

    // MARK: - ONNX Inference

    private func runInference(
        image: [Float],
        sdpPatches: [Float],
        bb2d: [Float],
        rayEncoding: [Float],
        numBoxes: Int
    ) throws -> (centers: [Float], sizes: [Float], yaws: [Float], confidences: [Float]) {
        let S = Self.imageSize
        let gH = Self.gridH
        let gW = Self.gridW
        let N = Self.numPatches

        let imageArr = try mlArrayFromFloat(image, shape: [1, 3, S, S])
        let sdpArr = try mlArrayFromFloat(sdpPatches, shape: [1, 1, gH, gW])
        let bb2dArr = try mlArrayFromFloat(bb2d, shape: [1, numBoxes, 4])
        let rayArr = try mlArrayFromFloat(rayEncoding, shape: [1, N, 6])

        let features = try MLDictionaryFeatureProvider(dictionary: [
            "image": imageArr,
            "sdp_median": sdpArr,
            "bb2d_norm": bb2dArr,
            "ray_enc": rayArr,
        ])
        let out = try model.prediction(from: features)

        // params: (1, M, 7) = [cx, cy, cz, w, h, d, yaw] in voxel frame, fp16.
        // prob:   (1, M)    fp16.
        guard let params = out.featureValue(for: "params")?.multiArrayValue,
              let prob = out.featureValue(for: "prob")?.multiArrayValue
        else {
            throw NSError(domain: "BoxerNet", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Missing params/prob outputs"])
        }

        // Split params into center/size/yaw. head.py stores [center_xyz, size_whd, yaw]
        // where size_whd is actually [h, w, d] per AleHead.forward — match the ONNX
        // output convention this codebase already consumes.
        var centers = [Float](repeating: 0, count: numBoxes * 3)
        var sizes = [Float](repeating: 0, count: numBoxes * 3)
        var yaws = [Float](repeating: 0, count: numBoxes)
        for i in 0..<numBoxes {
            for k in 0..<3 {
                centers[i * 3 + k] = params[[0, i, k] as [NSNumber]].floatValue
                sizes[i * 3 + k] = params[[0, i, 3 + k] as [NSNumber]].floatValue
            }
            yaws[i] = params[[0, i, 6] as [NSNumber]].floatValue
        }
        var confs = [Float](repeating: 0, count: numBoxes)
        for i in 0..<numBoxes {
            confs[i] = prob[[0, i] as [NSNumber]].floatValue
        }
        return (centers, sizes, yaws, confs)
    }

    /// Allocate an MLMultiArray and copy a contiguous Float32 payload in via pointer.
    private func mlArrayFromFloat(_ src: [Float], shape: [Int]) throws -> MLMultiArray {
        let arr = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        let ptr = arr.dataPointer.assumingMemoryBound(to: Float.self)
        src.withUnsafeBufferPointer { buf in
            ptr.update(from: buf.baseAddress!, count: src.count)
        }
        return arr
    }

    // MARK: - Preprocessing: SDP Patches

    /// Project LiDAR depth to 960x960 image, compute median depth per 16x16 patch.
    private func buildSDPPatches(
        depthMap: [[Float]],
        fx: Float, fy: Float, cx: Float, cy: Float
    ) -> [Float] {
        let S = Self.imageSize
        let P = Self.patchSize
        let gH = Self.gridH
        let gW = Self.gridW

        // Accumulate depths per patch.
        var patchDepths = [[Float]](repeating: [], count: gH * gW)

        let depthH = depthMap.count
        guard depthH > 0 else {
            return [Float](repeating: -1.0, count: gH * gW)
        }
        let depthW = depthMap[0].count

        // Scale factors from depth map to 960x960.
        let scaleX = Float(S) / Float(depthW)
        let scaleY = Float(S) / Float(depthH)

        // Scale intrinsics to 960x960.
        let fxS = fx * scaleX
        let fyS = fy * scaleY
        let cxS = cx * scaleX
        let cyS = cy * scaleY

        // For each depth pixel, project to 960x960 and assign to a patch.
        let step = max(1, Int(sqrt(Float(depthH * depthW) / 20000.0)))
        for v in stride(from: 0, to: depthH, by: step) {
            for u in stride(from: 0, to: depthW, by: step) {
                let z = depthMap[v][u]
                guard z > 0 else { continue }

                // Pixel in 960x960 space.
                let px = Float(u) * scaleX
                let py = Float(v) * scaleY

                let pi = Int(py) / P
                let pj = Int(px) / P
                guard pi >= 0, pi < gH, pj >= 0, pj < gW else { continue }

                patchDepths[pi * gW + pj].append(z)
            }
        }

        // Compute median per patch.
        var result = [Float](repeating: -1.0, count: gH * gW)
        for idx in 0..<(gH * gW) {
            var depths = patchDepths[idx]
            guard !depths.isEmpty else { continue }
            depths.sort()
            result[idx] = depths[depths.count / 2]
        }
        return result
    }

    // MARK: - Preprocessing: Plucker Ray Encoding

    /// Compute 6D Plucker ray encoding for each patch centre.
    private func buildRayEncoding(
        T_vc: simd_float4x4,
        fx: Float, fy: Float, cx: Float, cy: Float
    ) -> [Float] {
        let P = Float(Self.patchSize)
        let gH = Self.gridH
        let gW = Self.gridW

        // Scale intrinsics to 960x960 (assuming fx/fy/cx/cy are for original camera res).
        // NOTE: Caller should provide intrinsics already scaled to 960x960.

        let R_vc = upperLeft3x3(T_vc)
        let originCam = simd_float3(0, 0, 0)
        let originVoxel = (T_vc * simd_float4(originCam, 1.0)).xyz

        var result = [Float](repeating: 0, count: gH * gW * 6)

        for i in 0..<gH {
            for j in 0..<gW {
                let u = Float(j) * P + P / 2.0
                let v = Float(i) * P + P / 2.0

                // Unproject to camera frame (pinhole).
                var dirCam = simd_float3(
                    (u - cx) / fx,
                    (v - cy) / fy,
                    1.0
                )
                dirCam = simd_normalize(dirCam)

                // Rotate to voxel frame.
                var dirVoxel = R_vc * dirCam
                dirVoxel = simd_normalize(dirVoxel)

                // Moment: m = origin x direction.
                let moment = simd_cross(originVoxel, dirVoxel)

                let idx = (i * gW + j) * 6
                result[idx + 0] = dirVoxel.x
                result[idx + 1] = dirVoxel.y
                result[idx + 2] = dirVoxel.z
                result[idx + 3] = moment.x
                result[idx + 4] = moment.y
                result[idx + 5] = moment.z
            }
        }
        return result
    }

    // MARK: - Preprocessing: Gravity Alignment

    /// Compute gravity-aligned voxel frame matching Python's
    /// `gravity_align_T_world_cam(T_wc, z_grav=True)`.
    ///
    /// - Parameter gravity_w: Gravity direction in world frame.
    ///   ARKit uses (0, -1, 0).  The original Aria VIO uses (0, 0, -1).
    private func gravityAlign(
        T_worldCam: simd_float4x4,
        gravity_w: simd_float3 = simd_float3(0, -1, 0)
    ) -> simd_float4x4 {
        let R_wc = upperLeft3x3(T_worldCam)
        let t_wc = simd_float3(T_worldCam[3].x, T_worldCam[3].y, T_worldCam[3].z)

        let g_w = simd_normalize(gravity_w)

        // Camera forward (col 2 of R_wc) in world, projected orthogonal to gravity.
        let camZ_w = R_wc * simd_float3(0, 0, 1)
        var d3 = camZ_w - g_w * simd_dot(camZ_w, g_w) // reject gravity component
        if simd_length(d3) < 1e-6 {
            d3 = d3 + simd_float3(0, 0.001, 0) // tiny offset to avoid degenerate cross
        }

        let d2 = simd_cross(d3, g_w)

        // R_world_cg: columns are [g_w, d2, d3] (gravity is X axis — Aria convention)
        var R_wcg = simd_float3x3(columns: (g_w, d2, d3))
        // Normalize columns
        R_wcg[0] = simd_normalize(R_wcg[0])
        R_wcg[1] = simd_normalize(R_wcg[1])
        R_wcg[2] = simd_normalize(R_wcg[2])

        // Extra rotation to make Z the gravity axis (z_grav=True).
        // Python: R_cg_cgz = [[0,-1,0],[0,0,1],[-1,0,0]]
        // R_world_cgz = R_world_cg @ R_cg_cgz.inverse()
        let R_cg_cgz = simd_float3x3(columns: (
            simd_float3( 0,  0, -1),
            simd_float3(-1,  0,  0),
            simd_float3( 0,  1,  0)
        ))
        let R_world_cgz = R_wcg * R_cg_cgz.inverse

        // Build 4x4.
        var T_wv = simd_float4x4(1.0)
        T_wv[0] = simd_float4(R_world_cgz[0], 0)
        T_wv[1] = simd_float4(R_world_cgz[1], 0)
        T_wv[2] = simd_float4(R_world_cgz[2], 0)
        T_wv[3] = simd_float4(t_wc, 1)
        return T_wv
    }
}

// MARK: - simd Helpers

private func upperLeft3x3(_ m: simd_float4x4) -> simd_float3x3 {
    return simd_float3x3(
        simd_float3(m[0].x, m[0].y, m[0].z),
        simd_float3(m[1].x, m[1].y, m[1].z),
        simd_float3(m[2].x, m[2].y, m[2].z)
    )
}

private func rotationZ(angle: Float) -> simd_float3x3 {
    let c = cos(angle)
    let s = sin(angle)
    return simd_float3x3(
        simd_float3(c, s, 0),
        simd_float3(-s, c, 0),
        simd_float3(0, 0, 1)
    )
}

private extension simd_float4 {
    var xyz: simd_float3 { simd_float3(x, y, z) }
}
