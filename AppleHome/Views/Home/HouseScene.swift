import SwiftUI
import RealityKit

/// Per-room glow, eased toward `target` every frame by RoomGlowSystem so lights fade smoothly.
struct RoomGlowComponent: Component {
    var target: Float = 0
    var current: Float = -1 // forces the first frame to apply
}

final class RoomGlowSystem: System {
    private static let query = EntityQuery(where: .has(RoomGlowComponent.self))

    required init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let step = min(1, Float(context.deltaTime) * 5)
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var glow = entity.components[RoomGlowComponent.self], glow.current != glow.target else { continue }
            let diff = glow.target - glow.current
            glow.current = abs(diff) < 0.003 || glow.current < 0 ? glow.target : glow.current + diff * step
            entity.components.set(glow)
            HouseScene.applyGlow(glow.current, to: entity)
        }
    }
}

/// Builds a cut-away "dollhouse" from the list of rooms: one cell per room on a plinth,
/// low walls, windows and a floating lamp orb whose light spills onto the floor.
final class HouseScene {
    let root = Entity()
    /// Spins around Y when the user drags; the camera stays put.
    private let pivot = Entity()
    private let house = Entity()
    private let camera = PerspectiveCamera()
    private var layout: [String] = []
    private var rooms: [String: Entity] = [:]
    private var iblEntity: Entity?
    private static var registered = false

    private static let cell: Float = 1.0
    private static let wallHeight: Float = 0.34
    private static let wall: Float = 0.04
    private static let maxLumens: Float = 16000

    private var yaw: Float = -.pi / 5
    private let pitch: Float = 0.68
    private var dragStart: (yaw: Float, pitch: Float)?
    private static let cameraDistance: Float = 5.5

    init() {
        if !Self.registered {
            RoomGlowComponent.registerComponent()
            RoomGlowSystem.registerSystem()
            Self.registered = true
        }
        pivot.addChild(house)
        root.addChild(pivot)
        camera.camera.fieldOfViewInDegrees = 36
        root.addChild(camera)
        applyOrbit()
    }

    // MARK: Orbit

    /// Horizontal drag spins the house (vertical drags are left to the page's scroll view).
    func drag(by translation: CGSize) {
        let start = dragStart ?? (yaw, pitch)
        dragStart = start
        yaw = start.yaw + Float(translation.width) * 0.009
        applyOrbit()
    }

    /// Carries the fling on with an ease-out so the house glides to a stop.
    func endDrag(predictedTranslation: CGSize) {
        guard let start = dragStart else { return }
        dragStart = nil
        yaw = start.yaw + Float(predictedTranslation.width) * 0.009
        var transform = pivot.transform
        transform.rotation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        pivot.move(to: transform, relativeTo: root, duration: 0.7, timingFunction: .easeOut)
    }

    private func applyOrbit() {
        pivot.stopAllAnimations()
        pivot.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        let d = Self.cameraDistance
        camera.look(at: [0, -0.28, 0], from: [0, d * sin(pitch), d * cos(pitch)], relativeTo: root)
    }

    /// Dim night sky lighting + cool moonlight so unlit rooms read as "night", lit ones pop.
    func prepareLighting() async {
        guard iblEntity == nil else { return }
        let ibl = Entity()
        if let image = Self.nightSkyImage(), let env = try? await EnvironmentResource(equirectangular: image) {
            ibl.components.set(ImageBasedLightComponent(source: .single(env), intensityExponent: -0.4))
        }
        root.addChild(ibl)
        iblEntity = ibl

        let moon = Entity()
        var light = DirectionalLightComponent(color: UIColor(red: 0.62, green: 0.72, blue: 1.0, alpha: 1), intensity: 450)
        light.isRealWorldProxy = false
        moon.components.set(light)
        moon.components.set(DirectionalLightComponent.Shadow(maximumDistance: 6, depthBias: 2))
        moon.look(at: .zero, from: [-1.5, 3, 2.2], relativeTo: nil)
        root.addChild(moon)
        applyIBL(to: house)
    }

    func sync(rooms glows: [RoomGlow], selected: String?) {
        let names = glows.map(\.name)
        if names != layout {
            rebuild(names)
            layout = names
        }
        for glow in glows {
            guard let entity = rooms[glow.name] else { continue }
            if var component = entity.components[RoomGlowComponent.self], component.target != Float(glow.level) {
                component.target = Float(glow.level)
                entity.components.set(component)
            }
            entity.findEntity(named: "selection")?.isEnabled = glow.name == selected
        }
    }

    /// Room name for a tapped entity, if it belongs to a room floor.
    static func roomName(for entity: Entity) -> String? {
        var node: Entity? = entity
        while let current = node {
            if current.name.hasPrefix("floor:") { return String(current.name.dropFirst(6)) }
            node = current.parent
        }
        return nil
    }

    // MARK: Building

    private func rebuild(_ names: [String]) {
        house.children.removeAll()
        rooms.removeAll()

        let count = max(names.count, 1)
        let cols = count <= 2 ? count : Int(Double(count).squareRoot().rounded(.up))
        let rows = Int((Double(count) / Double(cols)).rounded(.up))
        let c = Self.cell
        house.scale = .init(repeating: 2.1 / Float(max(cols, rows)) / c)

        let plinth = ModelEntity(
            mesh: .generateBox(width: Float(cols) * c + 0.36, height: 0.1, depth: Float(rows) * c + 0.36, cornerRadius: 0.05),
            materials: [Self.material(UIColor(red: 0.10, green: 0.13, blue: 0.21, alpha: 1), roughness: 0.9)]
        )
        plinth.position.y = -0.05
        house.addChild(plinth)

        for (index, name) in names.enumerated() {
            let col = index % cols, row = index / cols
            let x = (Float(col) - Float(cols - 1) / 2) * c
            let z = (Float(row) - Float(rows - 1) / 2) * c
            let room = makeRoom(name: name)
            room.position = [x, 0, z]

            // Walls: back & left always, right/front only on the outer edge or next to an empty cell.
            let hasRight = col + 1 < cols && index + 1 < names.count
            let hasFront = index + cols < names.count
            room.addChild(makeWall(length: c, outer: row == 0, along: .x, offset: [0, 0, -c / 2]))
            room.addChild(makeWall(length: c, outer: col == 0, along: .z, offset: [-c / 2, 0, 0]))
            if !hasRight { room.addChild(makeWall(length: c, outer: true, along: .z, offset: [c / 2, 0, 0])) }
            if !hasFront { room.addChild(makeWall(length: c, outer: true, along: .x, offset: [0, 0, c / 2])) }

            house.addChild(room)
            rooms[name] = room
        }
        if iblEntity != nil { applyIBL(to: house) }
    }

    private func makeRoom(name: String) -> Entity {
        let room = Entity()
        room.name = "room:\(name)"
        let c = Self.cell

        let floor = ModelEntity(
            mesh: .generateBox(width: c - Self.wall, height: 0.03, depth: c - Self.wall),
            materials: [Self.material(UIColor(red: 0.33, green: 0.25, blue: 0.19, alpha: 1), roughness: 0.75)]
        )
        floor.name = "floor:\(name)"
        floor.position.y = 0.015
        floor.components.set(CollisionComponent(shapes: [.generateBox(width: c, height: 0.4, depth: c)]))
        floor.components.set(InputTargetComponent())
        room.addChild(floor)

        let selection = Entity()
        selection.name = "selection"
        let inset = c / 2 - 0.06
        let frame = UnlitMaterial(color: UIColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 1))
        for (size, pos) in [
            (SIMD3<Float>(c - 0.12, 0.006, 0.02), SIMD3<Float>(0, 0.034, -inset)),
            (SIMD3<Float>(c - 0.12, 0.006, 0.02), SIMD3<Float>(0, 0.034, inset)),
            (SIMD3<Float>(0.02, 0.006, c - 0.12), SIMD3<Float>(-inset, 0.034, 0)),
            (SIMD3<Float>(0.02, 0.006, c - 0.12), SIMD3<Float>(inset, 0.034, 0)),
        ] {
            let bar = ModelEntity(mesh: .generateBox(size: size), materials: [frame])
            bar.position = pos
            selection.addChild(bar)
        }
        selection.isEnabled = false
        room.addChild(selection)

        for piece in Self.furniture(for: name) { room.addChild(piece) }

        let orb = ModelEntity(mesh: .generateSphere(radius: 0.05), materials: [Self.orbMaterial(0)])
        orb.name = "orb"
        orb.position = [0, 0.5, 0]
        room.addChild(orb)

        let lamp = Entity()
        lamp.name = "lamp"
        lamp.position = [0, 0.42, 0]
        var point = PointLightComponent(cgColor: UIColor(red: 1, green: 0.72, blue: 0.4, alpha: 1).cgColor, intensity: 0, attenuationRadius: 1.5)
        point.attenuationFalloffExponent = 1.4
        lamp.components.set(point)
        room.addChild(lamp)

        room.components.set(RoomGlowComponent())
        return room
    }

    private enum Axis { case x, z }

    private func makeWall(length: Float, outer: Bool, along axis: Axis, offset: SIMD3<Float>) -> Entity {
        let h = Self.wallHeight, t = Self.wall
        let wall = Entity()
        wall.position = offset
        let color = outer ? UIColor(red: 0.84, green: 0.82, blue: 0.78, alpha: 1) : UIColor(red: 0.74, green: 0.72, blue: 0.69, alpha: 1)
        let size: SIMD3<Float> = axis == .x ? [length + t, h, t] : [t, h, length + t]

        if outer {
            let body = ModelEntity(mesh: .generateBox(size: size), materials: [Self.material(color, roughness: 0.85)])
            body.position.y = h / 2
            wall.addChild(body)
            // Window pane pokes through both faces so it reads from inside and out.
            let paneSize: SIMD3<Float> = axis == .x ? [length * 0.46, h * 0.44, t + 0.012] : [t + 0.012, h * 0.44, length * 0.46]
            let pane = ModelEntity(mesh: .generateBox(size: paneSize), materials: [Self.windowMaterial(0)])
            pane.name = "window"
            pane.position.y = h * 0.58
            wall.addChild(pane)
        } else {
            // Interior partition with a doorway in the middle.
            let gap: Float = 0.3
            let segment = (length + t - gap) / 2
            for sign: Float in [-1, 1] {
                let segSize: SIMD3<Float> = axis == .x ? [segment, h, t] : [t, h, segment]
                let seg = ModelEntity(mesh: .generateBox(size: segSize), materials: [Self.material(color, roughness: 0.85)])
                let shift = sign * (gap / 2 + segment / 2)
                seg.position = axis == .x ? [shift, h / 2, 0] : [0, h / 2, shift]
                wall.addChild(seg)
            }
        }
        return wall
    }

    // MARK: Glow

    static func applyGlow(_ level: Float, to room: Entity) {
        let level = max(0, level)
        if let lamp = room.findEntity(named: "lamp"), var point = lamp.components[PointLightComponent.self] {
            point.intensity = level * maxLumens
            lamp.components.set(point)
        }
        if let orb = room.findEntity(named: "orb") as? ModelEntity {
            orb.model?.materials = [orbMaterial(level)]
            orb.scale = .init(repeating: 0.8 + 0.35 * level)
        }
        room.visit { entity in
            if entity.name == "window", let pane = entity as? ModelEntity {
                pane.model?.materials = [windowMaterial(level)]
            }
        }
    }

    private static func orbMaterial(_ level: Float) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: level > 0.01 ? UIColor(red: 1, green: 0.9, blue: 0.7, alpha: 1) : UIColor(red: 0.25, green: 0.28, blue: 0.36, alpha: 1))
        m.roughness = 0.2
        m.metallic = 0.0
        m.emissiveColor = .init(color: UIColor(red: 1, green: 0.72, blue: 0.35, alpha: 1))
        m.emissiveIntensity = level * 4
        return m
    }

    private static func windowMaterial(_ level: Float) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: 0.16, green: 0.22, blue: 0.34, alpha: 1))
        m.roughness = 0.15
        m.metallic = 0.1
        m.emissiveColor = .init(color: UIColor(red: 1, green: 0.7, blue: 0.32, alpha: 1))
        m.emissiveIntensity = level * 2.2
        return m
    }

    private static func material(_ color: UIColor, roughness: Float) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.roughness = .init(floatLiteral: roughness)
        m.metallic = 0.0
        return m
    }

    private func applyIBL(to entity: Entity) {
        guard let iblEntity else { return }
        entity.visit { node in
            if node is ModelEntity {
                node.components.set(ImageBasedLightReceiverComponent(imageBasedLight: iblEntity))
                node.components.set(GroundingShadowComponent(castsShadow: true))
            }
        }
    }

    // MARK: Furniture

    private static func box(_ size: SIMD3<Float>, _ pos: SIMD3<Float>, _ color: UIColor, radius: Float = 0.012) -> ModelEntity {
        let e = ModelEntity(mesh: .generateBox(size: size, cornerRadius: radius), materials: [material(color, roughness: 0.7)])
        e.position = pos
        e.position.y += size.y / 2 + 0.03
        return e
    }

    private static func furniture(for room: String) -> [Entity] {
        let n = room.lowercased()
        func has(_ words: String...) -> Bool { words.contains { n.contains($0) } }
        let wood = UIColor(red: 0.52, green: 0.38, blue: 0.27, alpha: 1)
        let fabric = UIColor(red: 0.34, green: 0.40, blue: 0.54, alpha: 1)
        let white = UIColor(red: 0.92, green: 0.91, blue: 0.88, alpha: 1)
        let green = UIColor(red: 0.26, green: 0.52, blue: 0.36, alpha: 1)

        if has("bed", "นอน") {
            return [
                box([0.38, 0.08, 0.5], [0, 0, -0.15], white),
                box([0.4, 0.16, 0.035], [0, 0, -0.41], wood),
                box([0.3, 0.03, 0.09], [0, 0.08, -0.33], white),
                box([0.1, 0.08, 0.1], [0.3, 0, -0.38], wood),
            ]
        }
        if has("kitchen", "ครัว") {
            return [
                box([0.8, 0.15, 0.15], [0, 0, -0.37], white),
                box([0.34, 0.15, 0.18], [0.05, 0, 0.12], wood),
            ]
        }
        if has("bath", "น้ำ") {
            return [box([0.24, 0.1, 0.44], [-0.28, 0, -0.1], white, radius: 0.04)]
        }
        if has("porch", "garden", "patio", "outdoor", "ระเบียง", "สวน", "หน้าบ้าน") {
            let plant: (SIMD3<Float>) -> ModelEntity = { pos in
                let e = ModelEntity(mesh: .generateSphere(radius: 0.08), materials: [material(green, roughness: 0.9)])
                e.position = pos + [0, 0.11, 0]
                return e
            }
            return [
                plant([-0.3, 0, -0.3]), plant([0.3, 0, -0.32]), plant([-0.32, 0, 0.25]),
                box([0.4, 0.06, 0.12], [0, 0, -0.34], wood),
            ]
        }
        if has("office", "study", "ทำงาน") {
            return [box([0.45, 0.14, 0.2], [0, 0, -0.33], wood), box([0.14, 0.09, 0.14], [0, 0, -0.1], fabric)]
        }
        // Living room / default: sofa + coffee table.
        return [
            box([0.5, 0.09, 0.18], [0, 0, -0.3], fabric),
            box([0.5, 0.1, 0.05], [0, 0.07, -0.37], fabric),
            box([0.26, 0.05, 0.14], [0, 0, -0.02], wood),
        ]
    }

    private static func nightSkyImage() -> CGImage? {
        let w = 64, h = 32
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [
            CGColor(red: 0.30, green: 0.36, blue: 0.62, alpha: 1),
            CGColor(red: 0.12, green: 0.15, blue: 0.28, alpha: 1),
            CGColor(red: 0.03, green: 0.035, blue: 0.06, alpha: 1),
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) else { return nil }
        // CoreGraphics' origin is bottom-left: draw sky (top) at y = h.
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        return ctx.makeImage()
    }
}

private extension Entity {
    func visit(_ body: (Entity) -> Void) {
        body(self)
        for child in children { child.visit(body) }
    }
}
