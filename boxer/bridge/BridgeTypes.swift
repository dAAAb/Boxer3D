import Foundation
import simd

/// Wire format for SceneReport messages sent over the bridge WebSocket.
/// Mirrors the TypeScript `SceneReport` type in Boxer3D-Bridge/SceneReport.ts.
///
/// Coordinate frame is currently ``mujoco_world``: +X forward from Franka base,
/// +Y left, +Z up, meters. Until AprilTag calibration lands (Step 2e), this
/// frame is produced by a fixed ARKit → MuJoCo axis swap, so "forward" means
/// "whatever direction the iPhone was facing at ARKit session start".

struct BridgeObject: Codable, Sendable {
    let id: String
    let label: String
    let center_world: [Float]
    let size_m: [Float]
    let yaw_rad: Float
    let confidence: Float
}

struct BridgeCamera: Codable, Sendable {
    /// 4×4 transform serialised column-major (16 floats). Present when the
    /// streamer had access to the latest ARFrame at snapshot time.
    let pose_world: [Float]?
    let image_size: [Int]?
}

struct BridgeSceneReport: Codable, Sendable {
    let version: Int
    let coordinate_frame: String
    let timestamp: Double
    let camera: BridgeCamera?
    let objects: [BridgeObject]
}

enum BridgeCoord {
    /// ARKit (right-handed, +Y up, +X right, +Z backward from camera) →
    /// MuJoCo (right-handed, +Z up, +X forward from arm, +Y left).
    ///   mujocoX = -arkitZ   (forward from "rest pose")
    ///   mujocoY = -arkitX
    ///   mujocoZ =  arkitY
    /// Chosen so that objects sitting in front of the iPhone at session start
    /// appear in front of the Franka base under identity calibration.
    @inline(__always)
    static func arkitToMujoco(_ p: simd_float3) -> simd_float3 {
        simd_float3(-p.z, -p.x, p.y)
    }

    /// Derived confidence from MOT hits count (real per-track confidence is
    /// not stored on KnownDetection; hits is the next-best proxy).
    @inline(__always)
    static func confidenceFromHits(_ hits: Int) -> Float {
        switch hits {
        case ..<2: return 0.5
        case 2: return 0.75
        default: return 0.9
        }
    }
}
