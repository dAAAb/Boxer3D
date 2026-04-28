import SwiftUI
import ARKit
import SceneKit

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var viewModel: ARViewModel

    func makeUIView(context: Context) -> ARSCNView {
        let sceneView = ARSCNView()
        sceneView.autoenablesDefaultLighting = true
        sceneView.automaticallyUpdatesLighting = true
        // 2× MSAA softens silhouette aliasing on the low-poly ghost meshes
        // without the GPU cost of 4× (4× was perceptibly dropping frame rate).
        sceneView.antialiasingMode = .multisampling2X

        // Extra ambient fill so the unlit side of the ghost mesh doesn't go
        // pitch-black. The default-lighting omnidirectional alone produces
        // very high shadow contrast on the cup's handle/side.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.color = UIColor(white: 0.7, alpha: 1.0)
        sceneView.scene.rootNode.addChildNode(ambient)

        // Configure AR session with LiDAR.
        let config = ARWorldTrackingConfiguration()
        // .sceneDepth is per-frame raw LiDAR; .smoothedSceneDepth is the
        // multi-frame temporally-fused version. On a stationary device
        // the raw depth occasionally returns nil for runs of frames
        // (ARKit drops single-frame depth when LiDAR/vSLAM fusion can't
        // reach high confidence — most often when the user has the
        // phone on a tripod with no motion at all). Smoothed depth
        // holds a fused buffer across recent frames, so we fall back
        // to it whenever the per-frame is missing. Cost is negligible
        // on A17.
        if ARWorldTrackingConfiguration.supportsFrameSemantics([.sceneDepth, .smoothedSceneDepth]) {
            config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        } else {
            config.frameSemantics = [.sceneDepth]
        }
        // Plane detection drives the Tesla "feel the road" dot overlay in FSD
        // mode — clean flat planes from ARKit beat the raw jagged scene-recon
        // mesh on floors / tables / walls. Horizontal = floors + tables + seat
        // tops, vertical = walls. Cost is a few ms/frame, acceptable on A17.
        config.planeDetection = [.horizontal, .vertical]
        // Scene reconstruction feeds FSD mode's environment mesh (for things
        // plane detection doesn't cover — ceilings, furniture curves). Always
        // on so the first FSD toggle is instant; iPhone 15 Pro Max supports it.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        }

        sceneView.delegate = viewModel
        sceneView.session.run(config)
        viewModel.setup(sceneView: sceneView)

        return sceneView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
