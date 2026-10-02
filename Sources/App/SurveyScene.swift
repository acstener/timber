import SceneKit
import SwiftUI

/// The 3D survey: a low-poly island under a lidar sweep, where every folder that finishes
/// measuring sprouts as a tree. Pure SceneKit — no web view.
@MainActor
final class SurveyScene: NSObject {
    static weak var current: SurveyScene?

    let scene = SCNScene()
    let view: SCNView
    private let orbit = SCNNode()
    private let cameraNode = SCNNode()
    private let lookTarget = SCNNode()
    private let sun = SCNNode()
    private var terrainMaterial: SCNMaterial!
    private var motes: SCNParticleSystem!
    private var treesByPath: [String: SCNNode] = [:]
    private var labelled: [String: SCNNode] = [:]
    private var placed: [(x: Float, z: Float, r: Float)] = []
    private var lastFiles = 0
    private var lastFilesAt = Date()
    private var finished = false
    private let palette: Palette

    static let radius: Float = 13
    static let maxTrees = 60

    init(palette: Palette) {
        self.palette = palette
        view = SCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        super.init()
        SurveyScene.current = self
        view.scene = scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.allowsCameraControl = false
        build()
    }

    // MARK: - Build

    private func build() {
        let pal = palette
        scene.background.contents = gradientImage(top: NSColor(pal.skyTop), bottom: NSColor(pal.skyBottom))
        scene.fogColor = NSColor(pal.haze)
        scene.fogStartDistance = 34
        scene.fogEndDistance = 95
        scene.fogDensityExponent = 1.4

        // Camera on a slow orbit
        let cam = SCNCamera()
        cam.fieldOfView = 38
        cam.zNear = 0.1
        cam.zFar = 400
        cam.wantsHDR = true
        cam.bloomIntensity = 1.1
        cam.bloomThreshold = 0.75
        cam.bloomBlurRadius = 10
        cam.vignettingIntensity = 0.6
        cam.vignettingPower = 0.9
        cam.wantsExposureAdaptation = false
        cam.exposureOffset = pal.isNight ? -0.2 : 0
        cameraNode.camera = cam
        cameraNode.position = SCNVector3(0, 13, 30)
        lookTarget.position = SCNVector3(0, 1.2, 0)
        scene.rootNode.addChildNode(lookTarget)
        let look = SCNLookAtConstraint(target: lookTarget)
        look.isGimbalLockEnabled = true
        cameraNode.constraints = [look]
        orbit.addChildNode(cameraNode)
        scene.rootNode.addChildNode(orbit)
        orbit.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 80)))
        // gentle dolly in while surveying
        cameraNode.runAction(.sequence([.wait(duration: 0.3), .move(to: SCNVector3(0, 10, 24), duration: 14)]))

        // Lights
        let sunLight = SCNLight()
        sunLight.type = .directional
        sunLight.color = pal.isNight ? NSColor(srgbRed: 0.6, green: 0.7, blue: 1, alpha: 1) : NSColor(srgbRed: 1, green: 0.95, blue: 0.85, alpha: 1)
        sunLight.intensity = pal.isNight ? 350 : 1150
        sunLight.castsShadow = true
        sunLight.shadowMode = .deferred
        sunLight.shadowSampleCount = 12
        sunLight.shadowRadius = 4
        sunLight.shadowColor = NSColor(white: 0, alpha: pal.isNight ? 0.5 : 0.35)
        sunLight.orthographicScale = 20
        sunLight.shadowMapSize = CGSize(width: 2048, height: 2048)
        sunLight.zFar = 120
        sun.light = sunLight
        sun.position = SCNVector3(-20, 30, 14)
        sun.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(sun)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = pal.isNight ? 220 : 480
        ambient.light!.color = NSColor(pal.skyBottom)
        scene.rootNode.addChildNode(ambient)

        // Water
        let water = SCNNode(geometry: SCNPlane(width: 600, height: 600))
        water.eulerAngles.x = -.pi / 2
        water.position.y = 0.02
        let wm = SCNMaterial()
        wm.lightingModel = .physicallyBased
        wm.diffuse.contents = NSColor(pal.isNight ? Color(hex: 0x0E1E3A) : Color(hex: 0x4F9FD6))
        wm.roughness.contents = 0.25
        wm.metalness.contents = 0.1
        water.geometry!.materials = [wm]
        scene.rootNode.addChildNode(water)

        // Island
        let island = SCNNode(geometry: terrain())
        island.castsShadow = true
        scene.rootNode.addChildNode(island)

        // Clouds or fireflies
        if pal.isNight { addFireflies() } else { addClouds() }
        addPollen()
        addMotes()
    }

    private func gradientImage(top: NSColor, bottom: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 4, height: 256))
        img.lockFocus()
        NSGradient(starting: bottom, ending: top)?.draw(in: NSRect(x: 0, y: 0, width: 4, height: 256), angle: 90)
        img.unlockFocus()
        return img
    }

    static func height(_ x: Float, _ z: Float) -> Float {
        let r = (x * x + z * z).squareRoot()
        let hills = 0.55 * sin(x * 0.33 + 1.3) * cos(z * 0.29 - 0.4) + 0.35 * sin(x * 0.7 + z * 0.55) + 0.2 * cos(x * 1.5 - z * 1.2)
        let t = max(0, min(1, (r - radius * 0.68) / (radius * 0.32)))
        let fall = t * t * (3 - 2 * t)
        return (1.0 + hills * 0.7) * (1 - fall) + (-0.9) * fall
    }

    /// Flat-shaded low-poly terrain with per-face colours and the lidar sweep shader.
    private func terrain() -> SCNGeometry {
        let R = Self.radius + 1.2
        let n = 64
        let step = 2 * R / Float(n)
        var verts: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var colors: [Float] = []
        var rng = Seeded("terrain")
        let sand = SIMD3<Float>(0.90, 0.83, 0.60)
        let low = SIMD3<Float>(0.49, 0.74, 0.36)
        let high = SIMD3<Float>(0.30, 0.58, 0.29)

        func push(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            let centre = (a + b + c) / 3
            if (centre.x * centre.x + centre.z * centre.z).squareRoot() > R { return }
            let nrm = simd_normalize(simd_cross(b - a, c - a))
            var col: SIMD3<Float>
            if centre.y < 0.2 { col = sand }
            else {
                let k = max(0, min(1, (centre.y - 0.2) / 1.4))
                col = low + (high - low) * k
            }
            col *= Float(rng.range(0.92, 1.08))
            for v in [a, b, c] {
                verts.append(SCNVector3(v.x, v.y, v.z))
                normals.append(SCNVector3(nrm.x, nrm.y, nrm.z))
                colors += [col.x, col.y, col.z, 1]
            }
        }

        // Jitter lives on integer grid points so neighbouring cells share vertices exactly (no cracks).
        func p(_ i: Int, _ j: Int) -> SIMD3<Float> {
            var jr = Seeded("\(i),\(j)")
            let edge = i == 0 || j == 0 || i == n || j == n
            let x = -R + Float(i) * step + (edge ? 0 : Float(jr.range(-0.12, 0.12)))
            let z = -R + Float(j) * step + (edge ? 0 : Float(jr.range(-0.12, 0.12)))
            return SIMD3(x, Self.height(x, z), z)
        }
        for i in 0..<n {
            for j in 0..<n {
                let a = p(i, j), b = p(i, j + 1), c = p(i + 1, j), d = p(i + 1, j + 1)
                push(a, b, c)
                push(c, b, d)
            }
        }

        let vs = SCNGeometrySource(vertices: verts)
        let ns = SCNGeometrySource(normals: normals)
        let cd = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let cs = SCNGeometrySource(data: cd, semantic: .color, vectorCount: verts.count, usesFloatComponents: true,
                                   componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let idx = (0..<Int32(verts.count)).map { $0 }
        let el = SCNGeometryElement(indices: idx, primitiveType: .triangles)
        let g = SCNGeometry(sources: [vs, ns, cs], elements: [el])

        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = NSColor.white
        m.multiply.contents = palette.isNight ? NSColor(white: 0.55, alpha: 1) : NSColor.white
        m.shaderModifiers = [.surface: Self.sweepShader]
        m.setValue(NSNumber(value: 1.0), forKey: "scanActive")
        terrainMaterial = m
        g.materials = [m]
        return g
    }

    /// Lidar sweep: a rotating beam that lights topographic contour lines, plus ring pulses.
    private static let sweepShader = """
    #pragma arguments
    float scanActive;
    #pragma body
    float3 wp = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    float t = scn_frame.time;
    float ang = atan2(wp.z, wp.x);
    float sweep = fmod(t * 1.15, 6.2831853);
    float d = fmod(sweep - ang + 12.5663706, 6.2831853);
    float trail = exp(-d * 1.9);
    float edge = exp(-d * 40.0);
    float r = length(wp.xz);
    float ph = fract(t * 0.2);
    float ring = exp(-pow((r - ph * 16.0) * 2.2, 2.0)) * (1.0 - ph);
    float contour = smoothstep(0.86, 1.0, fract(wp.y * 6.0));
    float grid = smoothstep(0.94, 1.0, fract(r * 1.2));
    float glow = trail * (0.18 + contour * 1.4 + grid * 0.5) + edge * 1.6 + ring * (0.6 + contour);
    _surface.emission.rgb += float3(1.0, 0.45, 0.12) * glow * scanActive;
    """

    // MARK: - Ambient life

    private func dot(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 32, height: 32))
        img.lockFocus()
        let g = NSGradient(colors: [color, color.withAlphaComponent(0)])!
        g.draw(in: NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 32, height: 32)), relativeCenterPosition: .zero)
        img.unlockFocus()
        return img
    }

    private func addPollen() {
        let p = SCNParticleSystem()
        p.birthRate = 18
        p.particleLifeSpan = 7
        p.particleLifeSpanVariation = 2
        p.emitterShape = SCNBox(width: 30, height: 6, length: 30, chamferRadius: 0)
        p.birthLocation = .volume
        p.particleImage = dot(.white)
        p.particleSize = 0.05
        p.particleColor = NSColor(white: 1, alpha: 0.7)
        p.particleVelocity = 0.25
        p.particleVelocityVariation = 0.2
        p.spreadingAngle = 180
        p.blendMode = .additive
        p.isLightingEnabled = false
        p.warmupDuration = 5
        let n = SCNNode(); n.position = SCNVector3(0, 4, 0)
        n.addParticleSystem(p)
        scene.rootNode.addChildNode(n)
    }

    private func addFireflies() {
        let p = SCNParticleSystem()
        p.birthRate = 14
        p.particleLifeSpan = 6
        p.emitterShape = SCNBox(width: 24, height: 3, length: 24, chamferRadius: 0)
        p.birthLocation = .volume
        p.particleImage = dot(NSColor(srgbRed: 0.93, green: 1, blue: 0.55, alpha: 1))
        p.particleSize = 0.12
        p.particleSizeVariation = 0.06
        p.particleVelocity = 0.3
        p.spreadingAngle = 180
        p.blendMode = .additive
        p.isLightingEnabled = false
        p.warmupDuration = 6
        let anim = CAKeyframeAnimation()
        anim.values = [0, 1, 0.2, 1, 0]
        anim.duration = 6
        p.propertyControllers = [.opacity: SCNParticlePropertyController(animation: anim)]
        let n = SCNNode(); n.position = SCNVector3(0, 2.5, 0)
        n.addParticleSystem(p)
        scene.rootNode.addChildNode(n)
    }

    private func addMotes() {
        let p = SCNParticleSystem()
        p.birthRate = 30
        p.particleLifeSpan = 2.6
        p.particleLifeSpanVariation = 0.8
        p.emitterShape = SCNCylinder(radius: CGFloat(Self.radius) * 0.75, height: 0.01)
        p.birthLocation = .surface
        p.particleImage = dot(NSColor(srgbRed: 1, green: 0.55, blue: 0.2, alpha: 1))
        p.particleSize = 0.045
        p.particleSizeVariation = 0.02
        p.particleColor = NSColor(srgbRed: 1, green: 0.6, blue: 0.25, alpha: 1)
        p.emittingDirection = SCNVector3(0, 1, 0)
        p.spreadingAngle = 8
        p.particleVelocity = 1.8
        p.particleVelocityVariation = 0.9
        p.blendMode = .additive
        p.isLightingEnabled = false
        let fade = CAKeyframeAnimation()
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.6, 1]
        fade.duration = 1
        p.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
        motes = p
        let n = SCNNode(); n.position = SCNVector3(0, 1.1, 0)
        n.addParticleSystem(p)
        scene.rootNode.addChildNode(n)
    }

    private func addClouds() {
        var rng = Seeded("clouds3d")
        let mat = SCNMaterial()
        mat.lightingModel = .lambert
        mat.diffuse.contents = NSColor(white: 1, alpha: 0.95)
        mat.emission.contents = NSColor(white: 0.35, alpha: 1)
        for i in 0..<7 {
            let cloud = SCNNode()
            for k in 0..<5 {
                let s = SCNSphere(radius: CGFloat(rng.range(0.9, 1.7)))
                s.segmentCount = 10
                s.materials = [mat]
                let puff = SCNNode(geometry: s)
                puff.position = SCNVector3(Float(k) * 1.1 - 2.2, Float(rng.range(-0.3, 0.4)), Float(rng.range(-0.5, 0.5)))
                puff.scale = SCNVector3(1, 0.62, 1)
                cloud.addChildNode(puff)
            }
            let a = Float(i) / 7 * .pi * 2
            let dist = Float(rng.range(36, 52))
            cloud.position = SCNVector3(cos(a) * dist, Float(rng.range(15, 20)), sin(a) * dist)
            cloud.castsShadow = false
            scene.rootNode.addChildNode(cloud)
            cloud.runAction(.repeatForever(.sequence([
                .moveBy(x: 3, y: 0, z: 1, duration: rng.range(14, 22)),
                .moveBy(x: -3, y: 0, z: -1, duration: rng.range(14, 22)),
            ])))
        }
    }

    // MARK: - Trees

    private func material(_ hex: UInt32, jitter: Double = 0, seed: String = "") -> SCNMaterial {
        var rng = Seeded(seed)
        let base = Color(hex: hex).shaded(jitter == 0 ? 0 : rng.range(-jitter, jitter)).shaded(palette.isNight ? -0.35 : 0)
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = NSColor(base)
        return m
    }

    private func part(_ g: SCNGeometry, _ m: SCNMaterial, y: Float, x: Float = 0, z: Float = 0) -> SCNNode {
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.position = SCNVector3(x, y, z)
        n.castsShadow = true
        return n
    }

    private func makeTree(_ species: Species, height h: Float, seed: String) -> SCNNode {
        let root = SCNNode()
        let bark = material(0x6B4A32, jitter: 0.08, seed: seed + "b")
        switch species {
        case .pine:
            let leaf = material([0x2F7D4F, 0x3A8A55, 0x2C6E4A, 0x45935A][abs(seed.hashValue) % 4], jitter: 0.06, seed: seed)
            let trunk = SCNCylinder(radius: CGFloat(h * 0.05), height: CGFloat(h * 0.3)); trunk.radialSegmentCount = 6
            root.addChildNode(part(trunk, bark, y: h * 0.15))
            for i in 0..<3 {
                let c = SCNCone(topRadius: 0, bottomRadius: CGFloat(h * (0.3 - Float(i) * 0.065)), height: CGFloat(h * 0.42))
                c.radialSegmentCount = 7
                root.addChildNode(part(c, leaf, y: h * (0.4 + Float(i) * 0.2)))
            }
        case .oak, .blossom, .maple, .birch, .bush:
            let hexes: [UInt32]
            switch species {
            case .blossom: hexes = [0xF4A6C0, 0xEE93B3]
            case .maple: hexes = [0xE2582E, 0xD9462B]
            case .birch: hexes = [0xF2C14E, 0xE9B53F]
            default: hexes = [0x5DA84E, 0x4C9A45]
            }
            let leaf = material(hexes[abs(seed.hashValue) % hexes.count], jitter: 0.06, seed: seed)
            let trunkMat = species == .birch ? material(0xF1EEE6) : bark
            let trunk = SCNCylinder(radius: CGFloat(h * (species == .birch ? 0.035 : 0.055)), height: CGFloat(h * 0.55)); trunk.radialSegmentCount = 6
            root.addChildNode(part(trunk, trunkMat, y: h * 0.275))
            var rng = Seeded(seed)
            let main = SCNSphere(radius: CGFloat(h * 0.3)); main.segmentCount = 7
            let crown = part(main, leaf, y: h * 0.7)
            if species == .birch { crown.scale = SCNVector3(0.85, 1.25, 0.85) }
            root.addChildNode(crown)
            for _ in 0..<3 {
                let s = SCNSphere(radius: CGFloat(h * Float(rng.range(0.15, 0.21)))); s.segmentCount = 6
                let a = Float(rng.range(0, 6.28))
                root.addChildNode(part(s, leaf, y: h * Float(rng.range(0.6, 0.85)), x: cos(a) * h * 0.24, z: sin(a) * h * 0.24))
            }
        case .dead:
            let wood = material(0x8A7563, jitter: 0.05, seed: seed)
            let trunk = SCNCylinder(radius: CGFloat(h * 0.05), height: CGFloat(h * 0.75)); trunk.radialSegmentCount = 5
            root.addChildNode(part(trunk, wood, y: h * 0.375))
            var rng = Seeded(seed)
            for i in 0..<4 {
                let b = SCNCylinder(radius: CGFloat(h * 0.022), height: CGFloat(h * 0.35)); b.radialSegmentCount = 4
                let n = part(b, wood, y: h * (0.5 + Float(i) * 0.1))
                n.eulerAngles = SCNVector3(Float(rng.range(-0.3, 0.3)), Float(rng.range(0, 6.28)), (i.isMultiple(of: 2) ? 1 : -1) * Float(rng.range(0.6, 0.95)))
                n.position.x += (i.isMultiple(of: 2) ? -1 : 1) * CGFloat(h * 0.1)
                root.addChildNode(n)
            }
        }
        return root
    }

    private func treeHeight(_ bytes: Int64) -> Float {
        // Power curve: 10 MB ≈ 0.7, 1 GB ≈ 1.8, 10 GB ≈ 3.2, 100 GB ≈ 5.9
        let gb = max(0, Double(bytes) / 1_000_000_000)
        return Float(max(0.45, min(6.4, 0.45 + 5.4 * pow(gb / 100, 0.32))))
    }

    private func spot(for path: String, radius r: Float) -> (Float, Float) {
        var rng = Seeded(path)
        let R = Self.radius * 0.78
        var best: (Float, Float) = (0, 0)
        var bestGap: Float = -.infinity
        for _ in 0..<28 {
            let a = Float(rng.range(0, 6.28))
            let d = R * Float(rng.next()).squareRoot()
            let x = cos(a) * d, z = sin(a) * d
            var gap: Float = 10
            for p in placed {
                let dx: Float = p.x - x, dz: Float = p.z - z
                let dist: Float = (dx * dx + dz * dz).squareRoot()
                gap = min(gap, dist - (p.r + r) * 0.75)
            }
            if gap > 0 { return (x, z) }
            if gap > bestGap { bestGap = gap; best = (x, z) }
        }
        return best
    }

    private func sprout(_ node: Node) {
        let h = treeHeight(node.size)
        let species = Species.of(node, deadwood: Deadwood.classify(node) != nil)
        let footprint = h * 0.32
        let (x, z) = spot(for: node.path, radius: footprint)
        placed.append((x, z, footprint))
        let tree = makeTree(species, height: h, seed: node.path)
        tree.position = SCNVector3(x, Self.height(x, z) - 0.05, z)
        tree.eulerAngles.y = CGFloat(Seeded(node.path).hashValueish * 6.28)
        tree.scale = SCNVector3(0.001, 0.001, 0.001)
        scene.rootNode.addChildNode(tree)
        treesByPath[node.path] = tree

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.9
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.7, 0.55, 1)
        tree.scale = SCNVector3(1, 1, 1)
        SCNTransaction.commit()

        let sway = Double.random(in: 2.4...3.6)
        tree.runAction(.repeatForever(.sequence([
            .rotateBy(x: 0.025, y: 0, z: 0.02, duration: sway),
            .rotateBy(x: -0.025, y: 0, z: -0.02, duration: sway),
        ])))

        // leaf burst + ground ring
        let burst = SCNParticleSystem()
        burst.birthRate = 260
        burst.emissionDuration = 0.08
        burst.loops = false
        burst.particleLifeSpan = 1.1
        burst.particleImage = dot(.white)
        burst.particleSize = CGFloat(0.06 + h * 0.012)
        burst.particleColor = species == .blossom ? NSColor(srgbRed: 1, green: 0.75, blue: 0.85, alpha: 1)
            : species == .birch ? NSColor(srgbRed: 1, green: 0.85, blue: 0.35, alpha: 1)
            : NSColor(srgbRed: 0.6, green: 0.95, blue: 0.5, alpha: 1)
        burst.particleColorVariation = SCNVector4(0.05, 0.1, 0.1, 0)
        burst.emittingDirection = SCNVector3(0, 1, 0)
        burst.spreadingAngle = 70
        burst.particleVelocity = CGFloat(1.2 + h * 0.3)
        burst.acceleration = SCNVector3(0, -3.5, 0)
        burst.isLightingEnabled = false
        burst.blendMode = .alpha
        let bn = SCNNode(); bn.position = SCNVector3(x, Self.height(x, z) + h * 0.5, z)
        scene.rootNode.addChildNode(bn)
        bn.addParticleSystem(burst)
        bn.runAction(.sequence([.wait(duration: 1.5), .removeFromParentNode()]))

        let ringG = SCNTorus(ringRadius: CGFloat(footprint), pipeRadius: 0.025)
        let rm = SCNMaterial(); rm.lightingModel = .constant
        rm.emission.contents = NSColor(srgbRed: 0.75, green: 0.32, blue: 0.08, alpha: 1)
        rm.diffuse.contents = NSColor.black
        ringG.materials = [rm]
        let ring = SCNNode(geometry: ringG)
        ring.position = SCNVector3(x, Self.height(x, z) + 0.05, z)
        scene.rootNode.addChildNode(ring)
        ring.runAction(.sequence([
            .group([.scale(to: 2.2, duration: 0.7), .fadeOut(duration: 0.6)]),
            .removeFromParentNode(),
        ]))
    }

    private func wither(_ path: String) {
        guard let tree = treesByPath.removeValue(forKey: path) else { return }
        placed.removeAll { abs($0.x - Float(tree.position.x)) < 0.001 && abs($0.z - Float(tree.position.z)) < 0.001 }
        tree.runAction(.sequence([.scale(to: 0.001, duration: 0.4), .removeFromParentNode()]))
        labelled.removeValue(forKey: path)?.removeFromParentNode()
    }

    private func label(for node: Node, on tree: SCNNode, lift: Float) -> SCNNode {
        let text = SCNText(string: "\(node.displayName)  \(Fmt.bytes(node.size))", extrusionDepth: 0)
        text.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        text.flatness = 0.15
        let tm = SCNMaterial(); tm.lightingModel = .constant
        tm.diffuse.contents = NSColor.white
        tm.readsFromDepthBuffer = false
        text.materials = [tm]
        let tn = SCNNode(geometry: text)
        let (minB, maxB) = tn.boundingBox
        let w = maxB.x - minB.x, hgt = maxB.y - minB.y
        tn.pivot = SCNMatrix4MakeTranslation((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, 0)

        let plate = SCNPlane(width: w + 10, height: hgt + 7)
        plate.cornerRadius = (hgt + 7) / 2
        let pm = SCNMaterial(); pm.lightingModel = .constant
        pm.diffuse.contents = NSColor(white: 0.05, alpha: 0.7)
        pm.isDoubleSided = true
        pm.writesToDepthBuffer = false
        pm.readsFromDepthBuffer = false
        plate.materials = [pm]
        let pn = SCNNode(geometry: plate)
        pn.position.z = -0.5
        pn.renderingOrder = 10
        tn.renderingOrder = 11

        let holder = SCNNode()
        holder.addChildNode(pn)
        holder.addChildNode(tn)
        holder.scale = SCNVector3(0.035, 0.035, 0.035)
        let bb = SCNBillboardConstraint(); bb.freeAxes = .all
        holder.constraints = [bb]
        let top = Float(tree.boundingBox.max.y)
        holder.position = SCNVector3(tree.position.x, tree.position.y + CGFloat(top + 0.6 + lift), tree.position.z)
        holder.opacity = 0
        holder.runAction(.sequence([.wait(duration: 0.6), .fadeIn(duration: 0.4)]))
        holder.renderingOrder = 10
        return holder
    }

    // MARK: - Sync from the model

    func sync(sprouts: [Node], files: Int, finishing: Bool) {
        let wanted = Array(sprouts.filter { $0.size > 0 }.prefix(Self.maxTrees))
        let wantedPaths = Set(wanted.map(\.path))
        for path in treesByPath.keys where !wantedPaths.contains(path) { wither(path) }
        for n in wanted where treesByPath[n.path] == nil { sprout(n) }

        // Labels on the five biggest.
        let top = Set(wanted.prefix(3).map(\.path))
        for (path, l) in labelled where !top.contains(path) {
            l.runAction(.sequence([.fadeOut(duration: 0.3), .removeFromParentNode()]))
            labelled[path] = nil
        }
        for (rank, n) in wanted.prefix(3).enumerated() where labelled[n.path] == nil {
            if let tree = treesByPath[n.path] {
                let l = label(for: n, on: tree, lift: Float(rank) * 0.45)
                scene.rootNode.addChildNode(l)
                labelled[n.path] = l
            }
        }

        // Motes rise faster the faster files are being measured.
        let now = Date()
        let dt = now.timeIntervalSince(lastFilesAt)
        if dt > 0.25 {
            let rate = Double(files - lastFiles) / dt
            motes.birthRate = CGFloat(max(12, min(140, rate / 1200)))
            lastFiles = files
            lastFilesAt = now
        }

        if finishing && !finished { finish() }
    }

    private func finish() {
        finished = true
        motes.birthRate = 0
        terrainMaterial.setValue(NSNumber(value: 0.0), forKey: "scanActive")
        orbit.removeAllActions()
        cameraNode.removeAllActions()
        // Swoop down into the forest.
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 1.3
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.6, 0, 0.2, 1)
        cameraNode.position = SCNVector3(0, 2.6, 9)
        lookTarget.position = SCNVector3(0, 2.2, 0)
        SCNTransaction.commit()
        for (_, tree) in treesByPath {
            tree.runAction(.sequence([
                .wait(duration: Double.random(in: 0...0.3)),
                .scale(to: 1.12, duration: 0.15),
                .scale(to: 1, duration: 0.25),
            ]))
        }
    }
}

struct SurveyView: NSViewRepresentable {
    let sprouts: [Node]
    let files: Int
    let finishing: Bool
    @Environment(\.palette) private var palette

    func makeCoordinator() -> SurveyScene { SurveyScene(palette: palette) }
    func makeNSView(context: Context) -> SCNView { context.coordinator.view }
    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.sync(sprouts: sprouts, files: files, finishing: finishing)
    }
}
