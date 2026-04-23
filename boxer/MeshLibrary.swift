import Foundation
import SceneKit
import UIKit
import simd

/// Tesla-style class → canonical mesh lookup. USDZ files are authored at
/// real-world size (see `convert/process_cup.py` — TARGET_MAX_M), so at
/// render time we just clone + re-skin; no runtime scaling. If a class has
/// no mesh, callers fall back to the generic wireframe box.
///
/// Mesh files must live at the bundle root as `<label>.usdz` (matching the
/// YOLO / COCO label string, lowercased). Drag new USDZ files into the
/// Xcode target and add the label to `Self.registeredLabels`.
@MainActor
final class MeshLibrary {

    private var cache: [String: SCNNode] = [:]

    /// Labels to look up at init. Extend as you add USDZ files to the bundle.
    private static let registeredLabels = ["cup", "laptop", "keyboard", "bottle"]

    init() {
        for label in Self.registeredLabels {
            guard let url = Bundle.main.url(forResource: label, withExtension: "usdz") else {
                print("[MeshLibrary] skipped — \(label).usdz not in bundle")
                continue
            }
            guard let scene = try? SCNScene(url: url, options: nil) else {
                print("[MeshLibrary] failed to load \(label).usdz")
                continue
            }
            // USDZ from Blender usually wraps the mesh under the root in one or
            // more intermediate transform nodes. `flattenedClone` collapses
            // child transforms into one mesh node for cheap cloning later.
            cache[label] = scene.rootNode.flattenedClone()
        }
    }

    /// Build a ready-to-attach mesh node for `label`. The USDZ is already at
    /// real-world size, so no scaling happens here. Returns nil when the
    /// class has no mesh.
    ///
    /// The mesh is wrapped in an identity-transform *container* node because
    /// ARViewModel overwrites `simdWorldTransform` on the returned node every
    /// tick — writing onto the mesh directly would clobber any future scale
    /// tweaks. The material is deep-copied per instance so highlighting one
    /// cup doesn't repaint all of them (SCNNode.clone shares geometry).
    func node(for label: String) -> SCNNode? {
        guard let root = cache[label.lowercased()] else { return nil }

        let mesh = root.clone()
        applyGhostMaterial(to: mesh)

        let container = SCNNode()
        container.addChildNode(mesh)
        return container
    }

    /// Build a per-instance Blinn-shaded ghost material. If the USDZ ships a
    /// diffuse texture (e.g. baked ambient occlusion), we keep it on the
    /// diffuse channel so the cup shows the pre-baked crevice darkening; a
    /// white-plus-alpha fallback is used when there's no texture.
    ///
    /// Selection tint (yellow on long-press) is applied by ARViewModel via
    /// `material.multiply.contents` — that channel is a final multiply over
    /// the shaded result, so the AO gradient is preserved under the tint.
    ///
    /// Deep-copying each SCNGeometry is what makes every cup own its own
    /// material: `SCNNode.clone()` shares geometry across siblings, so
    /// without the copy tinting one cup would tint them all.
    private func applyGhostMaterial(to node: SCNNode) {
        installMaterial(on: node)
        node.enumerateChildNodes { child, _ in installMaterial(on: child) }
    }

    private func installMaterial(on node: SCNNode) {
        guard let original = node.geometry else { return }
        let copy = original.copy() as! SCNGeometry
        let bakedDiffuse = original.firstMaterial?.diffuse.contents

        let mat = SCNMaterial()
        mat.diffuse.contents = bakedDiffuse ?? UIColor.white
        mat.lightingModel = .blinn
        // Bright ambient reflectivity lifts the unlit side of the mesh so
        // shadows don't read as harsh black (paired with an ambient fill
        // light in ARViewContainer).
        mat.ambient.contents = UIColor.white
        mat.specular.contents = UIColor(white: 0.15, alpha: 1.0)
        mat.shininess = 0.25
        mat.transparency = 0.80  // 20% 透明
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = true
        mat.readsFromDepthBuffer = true

        copy.materials = [mat]
        node.geometry = copy
    }
}
