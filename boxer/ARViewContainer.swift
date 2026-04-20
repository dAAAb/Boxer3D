import SwiftUI
import ARKit
import SceneKit

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var viewModel: ARViewModel

    func makeUIView(context: Context) -> ARSCNView {
        let sceneView = ARSCNView()
        sceneView.autoenablesDefaultLighting = true
        sceneView.automaticallyUpdatesLighting = true

        // Configure AR session with LiDAR. Plane detection disabled — we don't
        // use planes, and it eats noticeable memory / compute per frame.
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]

        sceneView.session.run(config)
        viewModel.setup(sceneView: sceneView)

        return sceneView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
