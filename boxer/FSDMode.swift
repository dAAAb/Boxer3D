import ARKit
import SceneKit
import UIKit
import simd

/// Which palette the tracked-object meshes (cups, wireframes) render with.
/// `cameraGhost` is the original 2026-04-21 look (white translucent ghost
/// against the real-camera RGB). `fsdSolid` is the Tesla-screen look (dark
/// solid silhouette against a bright void), used in FSD mode.
enum BoxerPalette {
    case cameraGhost
    case fsdSolid
}

/// Four-state render cycle driven by the FSD button. Replaces the Bool toggle
/// whose behaviour on ARSCNView was inconsistent (setting
/// `scene.background.contents = nil` doesn't always restore the camera feed,
/// so we accidentally got a 3-state cycle that the user liked). This makes
/// the cycle explicit and stable at 4 deterministic states.
enum FSDRenderMode: Int, CaseIterable {
    /// Real camera feed showing through + white ghost meshes. Default.
    case camera
    /// White void background + white ghost meshes. Minimal Apple look —
    /// meshes read as translucent outlines on paper.
    case whiteOnWhite
    /// White void + dark solid meshes. Tesla FSD daylight screen.
    case whiteOnDark
    /// Black void + white meshes. Tesla FSD night / negative screen.
    case blackOnWhite

    var next: FSDRenderMode {
        let all = Self.allCases
        let nextIdx = (all.firstIndex(of: self)! + 1) % all.count
        return all[nextIdx]
    }

    /// Whether scene-reconstruction mesh + plane overlays are visible.
    var showsEnvironmentOverlay: Bool { self != .camera }

    /// Palette to apply to tracked-object meshes in this mode.
    var boxerPalette: BoxerPalette {
        self == .whiteOnDark ? .fsdSolid : .cameraGhost
    }

    /// Background contents. `nil` means "let ARSCNView show the camera feed".
    var backgroundContents: Any? {
        switch self {
        case .camera:        return nil
        case .whiteOnWhite,
             .whiteOnDark:   return FSDStyle.backgroundColor
        case .blackOnWhite:  return UIColor.black
        }
    }

    /// Fog colour matching the background for a smooth fade-to-horizon.
    var fogColor: UIColor {
        switch self {
        case .camera:        return UIColor.black          // unused
        case .whiteOnWhite,
             .whiteOnDark:   return FSDStyle.fogColor
        case .blackOnWhite:  return UIColor.black
        }
    }

    var usesFog: Bool { self != .camera }

    /// Short label for the FSD button (keeps UX discoverable).
    var buttonLabel: String {
        switch self {
        case .camera:       return "FSD"
        case .whiteOnWhite: return "W·W"
        case .whiteOnDark:  return "W·D"
        case .blackOnWhite: return "B·W"
        }
    }
}

/// Tesla-FSD-screen constants. Palette reference: see
/// `memory/project_boxer3d_fsd_palette.md` (2026-04-22).
enum FSDStyle {
    /// Flat bright background — the "void" Tesla cars float in on the FSD
    /// screen. Slightly off-white so the mesh silhouettes still read.
    static let backgroundColor = UIColor(white: 0.96, alpha: 1.0)
    /// Fog fades distant geometry TO WHITE (not black). Kitchen-scale range.
    static let fogColor = UIColor(white: 0.99, alpha: 1.0)
    static let fogStart: CGFloat = 3.0
    static let fogEnd: CGFloat = 9.0

    /// Dark-gray solid for tracked object meshes in FSD mode (Tesla "cars").
    static let objectSolidColor = UIColor(white: 0.32, alpha: 1.0)
    /// Default scene-recon mesh tint — light gray, slightly darker than the
    /// fog/background so surfaces read as surfaces.
    static let sceneReconColor = UIColor(white: 0.82, alpha: 1.0)

    /// Dot overlay on detected ARPlaneAnchor (Q4 — "feel the road" vibe).
    static let dotColor = UIColor(white: 0.72, alpha: 1.0)   // lighter (2026-04-23 tune)
    static let dotSpacingM: CGFloat = 0.05          // 5 cm between dots
    static let dotFrac: CGFloat = 0.10              // dot radius = 10% of cell (smaller)
    static let dotFadeStart: CGFloat = 0.65         // begin alpha fade at 65% to edge

    /// Fallback fixed offset if robustPlaneY can't collect enough classified
    /// vertices (cold start, sparse scene recon). Pulls the dot grid down to
    /// compensate for ARKit's upward plane-fit bias from tabletop objects.
    static let planeHeightOffsetM: Float = -0.02

    /// Minimum `.floor` / `.table` vertex samples to trust the robust percentile.
    /// Below this we fall back to `planeHeightOffsetM` above.
    static let robustPlaneMinSamples: Int = 30
    /// Percentile used for the robust plane Y. Low percentile pulls below the
    /// noise tail from objects sitting on the surface.
    static let robustPlanePercentile: Float = 0.10
    /// Vertical window (metres) around the plane's ARKit-estimated Y to accept
    /// classified vertices — wider = more samples, but also more risk of
    /// swallowing a neighbouring higher / lower surface.
    static let robustPlaneYWindowM: Float = 0.25

    /// Contact-shadow decal under every tracked object.
    /// Size = objectWidth × this multiplier (>1 so the blur extends past
    /// the object's silhouette). 1.35 looks grounded without reading as a halo.
    static let contactShadowSizeMultiplier: Float = 1.35
    /// Peak opacity of the shadow gradient at the centre (fades to 0 at edge).
    static let contactShadowOpacity: CGFloat = 0.45
}

/// Builds the SCNGeometry that renders a single ARMeshAnchor's tessellated
/// chunk of the real environment. ARKit updates these chunks ~1-2 Hz; each
/// call is followed by an `applyFSDMaterial` pass to install the light-gray
/// Tesla material.
///
/// Vertex / normal sources reference the Metal buffer directly (cheap). Face
/// indices are copied into CPU memory because the buffer may be repurposed on
/// the next anchor update.
@MainActor
func makeSceneReconGeometry(from meshGeom: ARMeshGeometry) -> SCNGeometry {
    let verts = meshGeom.vertices
    let norms = meshGeom.normals
    let faces = meshGeom.faces

    let vertexSource = SCNGeometrySource(
        buffer: verts.buffer,
        vertexFormat: verts.format,
        semantic: .vertex,
        vertexCount: verts.count,
        dataOffset: verts.offset,
        dataStride: verts.stride
    )
    let normalSource = SCNGeometrySource(
        buffer: norms.buffer,
        vertexFormat: norms.format,
        semantic: .normal,
        vertexCount: norms.count,
        dataOffset: norms.offset,
        dataStride: norms.stride
    )

    let element = makeFilteredFaceElement(meshGeom: meshGeom)

    let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
    geometry.materials = [makeSceneReconMaterial()]
    return geometry
}

/// Build the triangle-index element for a scene-recon anchor, keeping only
/// faces whose ARMeshClassification is *not* `.none`. Objects sitting on a
/// table / floor (cups, bottles, clutter) are almost always tagged `.none`
/// because they're too small or irregular for the classifier — dropping them
/// is what removes the "bumps" from the environment mesh. Classified faces
/// (floor / wall / ceiling / table / seat / window / door) stay.
///
/// Tesla-analogue: OccNet renders ground-class occupancy cleanly; foreground
/// objects are a separate channel handled by the agent-mesh pipeline — which
/// for us is BoxerNet + the ghost / fsdSolid meshes on tracked detections.
@MainActor
private func makeFilteredFaceElement(meshGeom: ARMeshGeometry) -> SCNGeometryElement {
    let faces = meshGeom.faces
    let bytesPerIndex = faces.bytesPerIndex
    let indicesPerFace = faces.indexCountPerPrimitive   // 3 for triangles
    let faceCount = faces.count

    // Without classification, pass every face through unchanged.
    guard let cls = meshGeom.classification else {
        let indexBytes = faceCount * indicesPerFace * bytesPerIndex
        let facesData = Data(bytes: faces.buffer.contents(), count: indexBytes)
        return SCNGeometryElement(
            data: facesData,
            primitiveType: .triangles,
            primitiveCount: faceCount,
            bytesPerIndex: bytesPerIndex
        )
    }

    let classBase = cls.buffer.contents().advanced(by: cls.offset)
    let classStride = cls.stride

    // Classes to drop. `.none` = unclassified clutter (cups, books on table).
    // `.floor / .wall / .table` are handled by the ARPlaneAnchor dot-grid
    // overlay now, so we mute them in the raw mesh too (otherwise the ragged
    // per-frame classifier flicker on the same surface keeps adding noise).
    // Kept: `.ceiling / .seat / .window / .door` — rarer, usually not planes.
    let droppedClasses: Set<UInt8> = [
        UInt8(ARMeshClassification.none.rawValue),
        UInt8(ARMeshClassification.floor.rawValue),
        UInt8(ARMeshClassification.wall.rawValue),
        UInt8(ARMeshClassification.table.rawValue),
    ]

    let facesBase = faces.buffer.contents()
    let faceStrideBytes = indicesPerFace * bytesPerIndex

    // Build a kept-face index list as UInt32 regardless of input width.
    var kept = [UInt32]()
    kept.reserveCapacity(faceCount * indicesPerFace)

    for faceIdx in 0..<faceCount {
        let classByte = classBase.advanced(by: faceIdx * classStride)
            .assumingMemoryBound(to: UInt8.self).pointee
        if droppedClasses.contains(classByte) { continue }

        let src = facesBase.advanced(by: faceIdx * faceStrideBytes)
        if bytesPerIndex == 4 {
            let tri = src.assumingMemoryBound(to: UInt32.self)
            kept.append(tri[0]); kept.append(tri[1]); kept.append(tri[2])
        } else {
            let tri = src.assumingMemoryBound(to: UInt16.self)
            kept.append(UInt32(tri[0])); kept.append(UInt32(tri[1])); kept.append(UInt32(tri[2]))
        }
    }

    let data = Data(bytes: kept, count: kept.count * MemoryLayout<UInt32>.stride)
    return SCNGeometryElement(
        data: data,
        primitiveType: .triangles,
        primitiveCount: kept.count / 3,
        bytesPerIndex: MemoryLayout<UInt32>.stride
    )
}

@MainActor
func makeSceneReconMaterial() -> SCNMaterial {
    let mat = SCNMaterial()
    mat.diffuse.contents = FSDStyle.sceneReconColor
    mat.lightingModel = .blinn
    // Low specular + strong ambient so the environment reads as "matte paper" —
    // the Tesla screen vibe, not a glossy studio render.
    mat.ambient.contents = UIColor(white: 0.6, alpha: 1.0)
    mat.specular.contents = UIColor(white: 0.05, alpha: 1.0)
    mat.shininess = 0.08
    mat.isDoubleSided = true
    mat.writesToDepthBuffer = true
    mat.readsFromDepthBuffer = true
    return mat
}

/// Attach (or refresh) the Tesla-style dot-grid overlay on an ARPlaneAnchor's
/// anchor node. Removes any previous overlay so `didUpdate` simply calls this
/// again — cheap, planes update at ~1 Hz.
///
/// The overlay is a single SCNPlane sized to the anchor's planeExtent, with
/// a shader modifier that paints a UV-space dot pattern and fades the alpha
/// radially toward the edges. Works for both horizontal and vertical plane
/// anchors (both expose local +Y as the plane's normal, so the same rotation
/// applies). Fixed mid-gray dot so it reads on both whiteVoid and blackVoid
/// backgrounds without per-mode swapping.
///
/// `meshAnchors` is used to compute a robust surface Y for horizontal planes
/// — we scan `.floor` / `.table` classified vertices in the plane's footprint
/// and take a low percentile, which sidesteps ARKit's upward plane-fit bias
/// from objects sitting on the surface. Falls back to `planeHeightOffsetM`
/// when too few classified samples are available.
@MainActor
func installDotOverlay(
    on node: SCNNode,
    anchor: ARPlaneAnchor,
    meshAnchors: [ARMeshAnchor] = []
) {
    // Tear down previous overlay — simpler than in-place mutation.
    node.enumerateChildNodes { child, _ in child.removeFromParentNode() }

    let extent = anchor.planeExtent
    let widthM = CGFloat(extent.width)
    let heightM = CGFloat(extent.height)
    guard widthM > 0.01, heightM > 0.01 else { return }

    let plane = SCNPlane(width: widthM, height: heightM)
    let material = SCNMaterial()
    material.lightingModel = .constant      // flat dot colour, no shading
    material.diffuse.contents = FSDStyle.dotColor
    material.isDoubleSided = true
    // Overlay is a decal — don't occlude ghost / solid objects behind it.
    material.writesToDepthBuffer = false
    material.readsFromDepthBuffer = true
    material.blendMode = .alpha
    material.transparency = 1.0

    // UV-space dot grid with radial edge fade. `cellsU/cellsV` ensure dot
    // spacing is metric (same on a 4 m floor vs a 40 cm tabletop).
    let cellsU = Float(widthM / FSDStyle.dotSpacingM)
    let cellsV = Float(heightM / FSDStyle.dotSpacingM)
    material.setValue(NSNumber(value: cellsU),                       forKey: "cellsU")
    material.setValue(NSNumber(value: cellsV),                       forKey: "cellsV")
    material.setValue(NSNumber(value: Float(FSDStyle.dotFrac)),      forKey: "dotFrac")
    material.setValue(NSNumber(value: Float(FSDStyle.dotFadeStart)), forKey: "fadeStart")
    material.shaderModifiers = [.surface: Self_dotShader]

    plane.materials = [material]

    let planeNode = SCNNode(geometry: plane)
    // SCNPlane lies in local XY with normal +Z. ARPlaneAnchor (both horizontal
    // and vertical) puts its plane in local XZ with normal +Y. Rotate −90° on
    // X to align: +Z of the SCNPlane maps to +Y of the anchor (correct normal),
    // height axis maps from +Y to -Z (correct extent direction).
    planeNode.eulerAngles.x = -.pi / 2

    // Y correction in the anchor's local frame.
    let offsetY: Float
    if anchor.alignment == .horizontal,
       let robustY = robustPlaneY(for: anchor, meshAnchors: meshAnchors) {
        // Override: set the overlay's world Y to the classified-surface
        // percentile, regardless of what ARKit thinks the plane height is.
        // Anchor's +Y is world-up for horizontal planes, so delta along local
        // Y == delta along world Y.
        let currentWorldY = (anchor.transform * simd_float4(anchor.center, 1)).y
        offsetY = robustY - currentWorldY
    } else if anchor.alignment == .horizontal {
        // Fallback: the -2 cm heuristic until enough samples accumulate.
        offsetY = FSDStyle.planeHeightOffsetM
    } else {
        offsetY = 0
    }
    planeNode.simdPosition = anchor.center + simd_float3(0, offsetY, 0)
    // Render after scene-recon mesh so dots composite on top of any residual
    // ceiling / seat / etc faces that happen to share the plane.
    planeNode.renderingOrder = 100

    node.addChildNode(planeNode)
}

/// Robust surface Y for a horizontal ARPlaneAnchor. Scans `.floor` / `.table`
/// classified vertices in the plane's XZ footprint and within ±25 cm of the
/// anchor's fitted Y, returns the 10th-percentile world-space Y. That cuts
/// the upward bias from objects on the surface whose base vertices sneak
/// into the plane fit. Returns nil if fewer than `robustPlaneMinSamples`
/// qualifying vertices are found — caller falls back to a fixed offset.
@MainActor
func robustPlaneY(for planeAnchor: ARPlaneAnchor, meshAnchors: [ARMeshAnchor]) -> Float? {
    guard planeAnchor.alignment == .horizontal, !meshAnchors.isEmpty else { return nil }

    let planeCenterWorld = planeAnchor.transform * simd_float4(planeAnchor.center, 1)
    let planeWorldY = planeCenterWorld.y
    let planeCx = planeCenterWorld.x
    let planeCz = planeCenterWorld.z

    let extent = planeAnchor.planeExtent
    let halfW = extent.width  * 0.55   // 10 % pad — accept slightly beyond fit
    let halfH = extent.height * 0.55
    let yLo = planeWorldY - FSDStyle.robustPlaneYWindowM
    let yHi = planeWorldY + FSDStyle.robustPlaneYWindowM

    let floorRaw = UInt8(ARMeshClassification.floor.rawValue)
    let tableRaw = UInt8(ARMeshClassification.table.rawValue)

    var ys: [Float] = []
    ys.reserveCapacity(2048)

    for meshAnchor in meshAnchors {
        let geom = meshAnchor.geometry
        guard let cls = geom.classification else { continue }

        let classBase   = cls.buffer.contents().advanced(by: cls.offset)
        let classStride = cls.stride

        let faces           = geom.faces
        let faceCount       = faces.count
        let indicesPerFace  = faces.indexCountPerPrimitive
        let bytesPerIndex   = faces.bytesPerIndex
        let facesBase       = faces.buffer.contents()
        let faceStrideBytes = indicesPerFace * bytesPerIndex

        let verts     = geom.vertices
        let vertsBase = verts.buffer.contents().advanced(by: verts.offset)
        let vertStride = verts.stride

        let t = meshAnchor.transform
        let vertexCount = verts.count

        for faceIdx in 0..<faceCount {
            let classByte = classBase.advanced(by: faceIdx * classStride)
                .assumingMemoryBound(to: UInt8.self).pointee
            if classByte != floorRaw && classByte != tableRaw { continue }

            let src = facesBase.advanced(by: faceIdx * faceStrideBytes)
            var idx = (UInt32(0), UInt32(0), UInt32(0))
            if bytesPerIndex == 4 {
                let tri = src.assumingMemoryBound(to: UInt32.self)
                idx = (tri[0], tri[1], tri[2])
            } else {
                let tri = src.assumingMemoryBound(to: UInt16.self)
                idx = (UInt32(tri[0]), UInt32(tri[1]), UInt32(tri[2]))
            }
            for vi in [idx.0, idx.1, idx.2] {
                guard Int(vi) < vertexCount else { continue }
                let p = vertsBase.advanced(by: Int(vi) * vertStride)
                    .assumingMemoryBound(to: Float.self)
                let lx = p[0], ly = p[1], lz = p[2]
                let wx = t[0][0]*lx + t[1][0]*ly + t[2][0]*lz + t[3][0]
                let wy = t[0][1]*lx + t[1][1]*ly + t[2][1]*lz + t[3][1]
                let wz = t[0][2]*lx + t[1][2]*ly + t[2][2]*lz + t[3][2]
                if wy < yLo || wy > yHi { continue }
                if abs(wx - planeCx) > halfW { continue }
                if abs(wz - planeCz) > halfH { continue }
                ys.append(wy)
            }
        }
    }

    guard ys.count >= FSDStyle.robustPlaneMinSamples else { return nil }
    ys.sort()
    let pIdx = min(ys.count - 1, Int(Float(ys.count) * FSDStyle.robustPlanePercentile))
    return ys[pIdx]
}

// MARK: - Contact shadow

/// Lazy-built radial gradient UIImage for the contact-shadow decal. Cached
/// on first call — UIGraphicsImageRenderer is cheap but not free.
@MainActor private var _cachedContactShadowImage: UIImage?

@MainActor
func contactShadowImage() -> UIImage {
    if let img = _cachedContactShadowImage { return img }
    let size = CGSize(width: 256, height: 256)
    let renderer = UIGraphicsImageRenderer(size: size)
    let img = renderer.image { ctx in
        let cg = ctx.cgContext
        let colors = [
            UIColor(white: 0, alpha: FSDStyle.contactShadowOpacity).cgColor,
            UIColor(white: 0, alpha: 0).cgColor,
        ] as CFArray
        let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0.0, 1.0])!
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        cg.drawRadialGradient(
            gradient,
            startCenter: centre, startRadius: 0,
            endCenter:   centre, endRadius:   size.width / 2,
            options: []
        )
    }
    _cachedContactShadowImage = img
    return img
}

/// Add a soft radial-gradient shadow decal under a tracked object so it
/// visually "sits" on the surface instead of floating. The decal is a flat
/// SCNPlane lying on the object's bottom-Y level (XZ plane), slightly larger
/// than the object's footprint so the blur extends past the silhouette.
/// Returns the shadow node so the caller can track it for visibility toggling.
@MainActor
@discardableResult
func addContactShadow(to parent: SCNNode, size: simd_float3) -> SCNNode {
    let footprint = max(size.x, size.z) * FSDStyle.contactShadowSizeMultiplier
    let plane = SCNPlane(width: CGFloat(footprint), height: CGFloat(footprint))
    let mat = SCNMaterial()
    mat.lightingModel = .constant
    mat.diffuse.contents = contactShadowImage()
    mat.diffuse.mipFilter = .linear
    mat.isDoubleSided = false
    mat.writesToDepthBuffer = false   // don't occlude what's below the shadow
    mat.readsFromDepthBuffer = true
    mat.blendMode = .alpha
    plane.materials = [mat]

    let node = SCNNode(geometry: plane)
    node.eulerAngles.x = -.pi / 2                   // lie flat (XZ)
    node.simdPosition = simd_float3(0, -size.y / 2 + 0.001, 0)  // at object bottom, tiny epsilon up
    node.renderingOrder = 50                         // between plane overlay (100) and default (0)
    parent.addChildNode(node)
    return node
}

/// Metal shader-modifier body for the plane dot grid. Entry point: `.surface`.
/// Writes alpha based on the UV-space dot mask × radial fade; RGB comes from
/// the material's diffuse contents (FSDStyle.dotColor).
private let Self_dotShader = """
#pragma arguments
float cellsU;
float cellsV;
float dotFrac;
float fadeStart;

#pragma body
float2 uv = _surface.diffuseTexcoord;
float2 cell = uv * float2(cellsU, cellsV);
float2 f = fract(cell) - 0.5;
float d = length(f);
float dot = 1.0 - smoothstep(dotFrac * 0.85, dotFrac * 1.15, d);

float2 rel = abs(uv - 0.5) * 2.0;
float edge = max(rel.x, rel.y);
float fade = 1.0 - smoothstep(fadeStart, 1.0, edge);

_surface.diffuse.a = dot * fade;
"""

/// Swap a tracked-object node's visual palette. Wireframe nodes carry
/// geometry directly (diffuse swap); mesh-container nodes wrap geometry-bearing
/// children (multiply channel swap — matches `paintHighlight` convention so
/// the yellow selection tint on top still composes correctly).
@MainActor
func applyBoxerPalette(_ palette: BoxerPalette, to wireframeOrMesh: SCNNode) {
    let isMesh = wireframeOrMesh.geometry == nil
    if isMesh {
        // Mesh container: rewrite diffuse on each child's deep-copied material.
        wireframeOrMesh.enumerateChildNodes { child, _ in
            guard let geom = child.geometry, let mat = geom.firstMaterial else { return }
            switch palette {
            case .cameraGhost:
                mat.diffuse.contents = UIColor.white
                mat.transparency = 0.80
                mat.ambient.contents = UIColor.white
            case .fsdSolid:
                mat.diffuse.contents = FSDStyle.objectSolidColor
                mat.transparency = 1.0
                mat.ambient.contents = UIColor(white: 0.5, alpha: 1.0)
            }
        }
    } else {
        // Wireframe tube geometry — single material, flat colour.
        guard let mat = wireframeOrMesh.geometry?.firstMaterial else { return }
        switch palette {
        case .cameraGhost:
            mat.diffuse.contents = UIColor.white
        case .fsdSolid:
            mat.diffuse.contents = FSDStyle.objectSolidColor
        }
    }
}
