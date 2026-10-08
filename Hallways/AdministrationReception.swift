import SceneKit
import UIKit

/// Oct 5 -- ADMINISTRATION, first interior slice (Floor 2).
///
/// Floor 2's authored layout (DefaultMazes.json) is: the elevator nook
/// (10,6), the vestibule (10,7) with the Double Glass ADMINISTRATION
/// entrance on its east wall, and a 3 x 3 reception room (rows 9-11,
/// cols 8-10). The room's east column is the staff side: part of the room
/// you SEE (one open space, no walls) but not part of where you can WALK --
/// the tall reception counter stands on that line, so you approach the
/// desk and stop at it, and the Administrator waits behind it.
///
/// This file places the set pieces the cell data cannot express (visual
/// direction: Sancho's concept -- dark wood, brass, warm, official): the
/// vestibule planters, the entry mat, the counter and its clutter, a
/// glimpse of back-office life (cabinets, a clock), and a temporary
/// stand-in for the Administrator (not designed yet). The painting behind
/// the desk is ordinary authored picture data. Built into the floor's
/// scene on every Floor 2 build, before SceneKit prepares it.
enum AdministrationReception {
    static let floor = 2
    /// Behind the counter -- open to the eye, closed to navigation.
    static let staffCells: Set<GridCoordinate> = [
        GridCoordinate(row: 9, col: 10), GridCoordinate(row: 10, col: 10), GridCoordinate(row: 11, col: 10)
    ]
    static let counterRow = 10
    static let publicCol = 9
    static let vestibule = GridCoordinate(row: 10, col: 7)
    /// The photo station hangs on this cell's north wall (the visitor's left
    /// at the desk).
    static let photoStationCell = GridCoordinate(row: 9, col: 9)
    /// Where a visitor is received: the centre of the public cell in front of
    /// the counter, facing the counter (east) -- i.e. the wall-face pose the
    /// existing wall-interaction landing composes for the staff-side line.
    static let deskLanding = WallFace(coord: GridCoordinate(row: counterRow, col: publicCol), direction: .east)
    /// Oct 5 (polish): the desk pose sits this far BACK from the cell centre
    /// (2.36 m from the counter line instead of 1.76) so the Administrator's
    /// whole pointing arm stays in view.
    static let deskStandOff: Double = -0.6
    /// The ID terminal pose: facing the north wall, 1.45 m from it (a little
    /// closer than the cell centre so the screen reads comfortably; still
    /// clear of the walking clearance).
    static let terminalLanding = WallFace(coord: photoStationCell, direction: .north)
    static let terminalStandOff: Double = 0.3

    /// Oct 5: the private office behind the four-panel door in the south
    /// wall of (11,9) -- a one-cell anteroom (12,9), then a 2 x 2 room. (Two
    /// walkable cells side by side are always open to each other in this
    /// grid, so the office cannot touch row 11 anywhere but the door.)
    static let officeAnteroom = GridCoordinate(row: 12, col: 9)
    static let officeCells: Set<GridCoordinate> = [
        GridCoordinate(row: 13, col: 8), GridCoordinate(row: 13, col: 9),
        GridCoordinate(row: 14, col: 8), GridCoordinate(row: 14, col: 9)
    ]
    /// Oct 5 (office dressing): the desk bay at the far end of the office --
    /// the desk, its chair and the space around it -- seen, not walked (like
    /// the staff side of reception), so a tap or free walk never ends inside
    /// the desk. The office's occupant is not bound by this.
    static let officeDeskBayCells: Set<GridCoordinate> = [GridCoordinate(row: 14, col: 9)]

    /// The cells this dressing is laid out for (vestibule + 3 x 3 room +
    /// the office behind the south door).
    static let expectedCells: Set<GridCoordinate> = {
        var cells: Set<GridCoordinate> = [GridCoordinate(row: 10, col: 6), vestibule, officeAnteroom]
        for row in 9...11 { for col in 8...10 { cells.insert(GridCoordinate(row: row, col: col)) } }
        return cells.union(officeCells)
    }()

    static func install(into root: SCNNode, cellSize: CGFloat, cells: Set<GridCoordinate>) {
        // Never place a counter/clerk/cabinets inside solid building: if
        // the floor being built is not the Administration layout (e.g. a
        // stale device copy), say so and install nothing.
        guard expectedCells.isSubset(of: cells) else {
            diag("administration.layoutMismatch", ["cells": cells.count,
                                                   "missing": expectedCells.subtracting(cells).count])
            return
        }
        cancelPatienceTimer()                              // Oct 7: never carried across builds
        let s = Float(cellSize)
        let half = s / 2
        let boundaryX = (Float(publicCol) + 0.5) * s       // public | staff line
        let z = Float(counterRow) * s
        let faceWest = Float(Direction.east.yaw)           // local +Z (front) toward the entrance

        // Vestibule: tall planters either side of the entrance.
        let entranceWallX = Float(vestibule.col) * s + half
        for side: Float in [-1, 1] {
            let planter = makePlanter()
            planter.position = SCNVector3(entranceWallX - 0.32, 0, Float(vestibule.row) * s + side * 1.32)
            root.addChildNode(planter)
        }

        // Entry mat between the doors and the desk.
        let mat = SCNNode(geometry: SCNBox(width: 3.0, height: 0.012, length: 2.2, chamferRadius: 0.004))
        mat.geometry?.materials = [material(UIColor(red: 0.16, green: 0.15, blue: 0.15, alpha: 1), rough: 0.95)]
        mat.position = SCNVector3((Float(publicCol) - 0.6) * s, 0.056, z)
        mat.name = "administrationMat"
        root.addChildNode(mat)

        // The counter, its clutter, and the Administrator.
        let desk = makeCounter()
        desk.position = SCNVector3(boundaryX - 0.12, 0, z)
        desk.eulerAngles.y = faceWest
        root.addChildNode(desk)

        let clerk = makeAdministratorStandIn()
        clerk.position = SCNVector3(boundaryX + 0.6, 0, z)
        clerk.eulerAngles.y = faceWest
        root.addChildNode(clerk)

        // Back-office life: a row of filing cabinets against the back wall
        // of the south staff bay with a clock above (the north bay's back
        // wall carries the authored skyline painting).
        let backWallX = Float(publicCol + 1) * s + half
        for row in [11] {
            for offset: Float in [-0.5, 0, 0.5] {
                let cabinet = makeCabinet()
                cabinet.position = SCNVector3(backWallX - 0.3, 0, Float(row) * s + offset)
                cabinet.eulerAngles.y = faceWest
                root.addChildNode(cabinet)
            }
        }
        let clock = makeClock()
        clock.position = SCNVector3(backWallX - 0.06, 2.2, Float(11) * s)
        clock.eulerAngles.y = faceWest
        root.addChildNode(clock)

        // The ID-photo terminal: on the north wall of the public cell beside
        // the reception position -- off the visitor's LEFT shoulder in the
        // desk-landing pose. Faces into the room (south).
        let terminal = AdministrationIDTerminal.makeNode()
        terminal.root.position = SCNVector3(Float(photoStationCell.col) * s, 0, (Float(photoStationCell.row) - 0.5) * s + 0.05)
        terminal.root.eulerAngles.y = Float(Direction.north.yaw)     // local +Z (its face) toward the room
        root.addChildNode(terminal.root)
        AdministrationIDTerminal.current = AdministrationIDTerminal(screen: terminal.screen)
        // Oct 6 (polish): the office door itself gets its makeover and its
        // ORIENTATION nameplate (on the leaf, so it swings with the door).
        dressOrientationDoor(in: root)
        installOffice(into: root, s: s)
        diag("administration.receptionInstalled", ["counterX": Double(boundaryX - 0.12), "z": Double(z)])
    }

    // MARK: Materials

    static func material(_ color: UIColor, metal: CGFloat = 0, rough: CGFloat = 0.6, glow: UIColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metal
        m.roughness.contents = rough
        if let glow { m.emission.contents = glow }
        return m
    }
    static let cherry = UIColor(red: 0.36, green: 0.16, blue: 0.1, alpha: 1)
    static let darkCherry = UIColor(red: 0.24, green: 0.11, blue: 0.07, alpha: 1)
    static let brass = UIColor(red: 0.74, green: 0.58, blue: 0.3, alpha: 1)

    static func box(_ w: CGFloat, _ h: CGFloat, _ d: CGFloat, _ m: SCNMaterial,
                            _ x: Float, _ y: Float, _ z: Float, in root: SCNNode, chamfer: CGFloat = 0.006) {
        let g = SCNBox(width: w, height: h, length: d, chamferRadius: chamfer)
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.position = SCNVector3(x, y, z)
        root.addChildNode(n)
    }

    // MARK: Office door plaque (Oct 6 polish)

    /// The office door: the four-panel Room Entrance in (11,9)'s south wall.
    static let officeDoorCell = GridCoordinate(row: 11, col: 9)

    /// Oct 6 (polish): the office door, made into a door someone actually
    /// specified -- the existing four-panel leaf (its hinge, swing, hit
    /// testing and doorway are untouched) refinished in the reception's
    /// cherry: darker stiles and rails, warmer recessed panels; its knob in
    /// brass; a brushed-brass kick plate; and, at eye height on the
    /// reception face, a brass department nameplate: ORIENTATION. Everything
    /// added is a child of the leaf, so it swings with the door, and is only
    /// millimetres proud of its face (the leaf's swing clearance and the
    /// doorway are unchanged).
    static func dressOrientationDoor(in root: SCNNode) {
        guard let hinge = root.childNode(withName: "roomEntranceDoor_\(officeDoorCell.row)_\(officeDoorCell.col)", recursively: true),
              let leaf = hinge.childNodes.first else {
            diag("administration.orientationDoor.missing", [:])
            return
        }
        // Refinish the leaf's own pieces: proud frame (stiles, rails) vs.
        // recessed panels (the frame material is the one with the multiply tint).
        let stileWood = material(UIColor(red: 0.3, green: 0.13, blue: 0.08, alpha: 1), rough: 0.5)
        let panelWood = material(UIColor(red: 0.42, green: 0.2, blue: 0.12, alpha: 1), rough: 0.45)
        var leafBoxes: [SCNNode] = []
        for piece in leaf.childNodes {
            guard let box = piece.geometry as? SCNBox, let m = box.firstMaterial else { continue }
            box.materials = [m.multiply.contents != nil ? stileWood : panelWood]
            leafBoxes.append(piece)
        }
        // The knob assembly (everything else on the leaf) in brass.
        let brassHardware = material(brass, metal: 0.85, rough: 0.28)
        for child in leaf.childNodes where !leafBoxes.contains(where: { $0 === child }) {
            child.enumerateHierarchy { n, _ in
                if let g = n.geometry { g.materials = g.materials.map { _ in brassHardware } }
            }
        }
        // The leaf's reception face: the door faces south, so the room side
        // is local -Z; the frame's face is at -thickness/2 (0.03 m).
        guard let frameDepth = leafBoxes.compactMap({ ($0.geometry as? SCNBox)?.length }).max() else { return }
        let faceZ = -Float(frameDepth / 2)
        let doorCenterY = hinge.position.y                         // leaf-local y 0 = the doorway's centre height
        // Brushed-brass kick plate across the bottom.
        let kick = SCNNode(geometry: SCNBox(width: 0.86, height: 0.22, length: 0.004, chamferRadius: 0.001))
        kick.geometry?.materials = [material(brass, metal: 0.75, rough: 0.42)]
        kick.position = SCNVector3(0, -doorCenterY + 0.02 + 0.13, faceZ - 0.002)
        kick.name = "orientationDoorKickPlate"
        leaf.addChildNode(kick)
        // The nameplate, centred on the leaf at eye height, readable from the room.
        let plate = makeDepartmentPlaque("ORIENTATION", width: 0.62, height: 0.15)
        plate.position = SCNVector3(0, 1.5 - doorCenterY, faceZ - 0.001)
        plate.eulerAngles.y = .pi                                   // its face (+Z) toward the room (-Z)
        leaf.addChildNode(plate)
        diag("administration.orientationDoor.dressed", ["pieces": leafBoxes.count])
    }

    /// A department nameplate of the kind screwed onto office doors: a thin
    /// dark walnut backing, a brushed brass face with the name in dark
    /// engraved capitals, two little screw heads. Face on local +Z, origin
    /// at its centre (its back at z = -0.008).
    static func makeDepartmentPlaque(_ text: String, width w: CGFloat, height h: CGFloat,
                                     face plateColor: UIColor = UIColor(red: 0.74, green: 0.58, blue: 0.3, alpha: 1),
                                     ink: UIColor = UIColor(red: 0.16, green: 0.11, blue: 0.06, alpha: 1),
                                     backing: UIColor? = nil) -> SCNNode {
        let root = SCNNode()
        root.name = "administrationOfficePlaque"
        box(w + 0.02, h + 0.02, 0.008, material(backing ?? darkCherry, rough: 0.55), 0, 0, -0.004, in: root, chamfer: 0.003)
        let size = CGSize(width: 1000, height: 1000 * h / w)
        let engraved = UIGraphicsImageRenderer(size: size).image { _ in
            plateColor.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            // A fine engraved border.
            UIColor(red: 0.3, green: 0.22, blue: 0.1, alpha: 1).setStroke()
            let border = UIBezierPath(rect: CGRect(x: 22, y: 22, width: size.width - 44, height: size.height - 44))
            border.lineWidth = 4
            border.stroke()
            let style = NSMutableParagraphStyle(); style.alignment = .center
            var fontSize: CGFloat = 110
            var attributes: [NSAttributedString.Key: Any] = [:]
            repeat {
                attributes = [.font: UIFont.systemFont(ofSize: fontSize, weight: .semibold), .kern: fontSize * 0.16,
                              .foregroundColor: ink, .paragraphStyle: style]
                fontSize -= 4
            } while (text as NSString).size(withAttributes: attributes).width > size.width - 260 && fontSize > 30
            let textHeight = (text as NSString).size(withAttributes: attributes).height
            (text as NSString).draw(in: CGRect(x: 0, y: (size.height - textHeight) / 2, width: size.width, height: textHeight),
                                    withAttributes: attributes)
        }
        let face = SCNMaterial()
        face.lightingModel = .physicallyBased
        face.diffuse.contents = engraved
        face.metalness.contents = 0.6
        face.roughness.contents = 0.4
        // A touch of self-light so the lettering never sinks into a dim
        // reflection (it still reads as lit brass, not a glowing sign).
        face.emission.contents = engraved
        face.emission.intensity = 0.18
        let brassEdge = material(plateColor, metal: 0.7, rough: 0.35)
        let plate = SCNBox(width: w, height: h, length: 0.006, chamferRadius: 0.0015)
        // SCNBox material order: front (+Z), right, back, left, top, bottom.
        plate.materials = [face, brassEdge, brassEdge, brassEdge, brassEdge, brassEdge]
        let plateNode = SCNNode(geometry: plate)
        plateNode.position = SCNVector3(0, 0, 0.003)
        root.addChildNode(plateNode)
        for x in [-w / 2 + 0.02, w / 2 - 0.02] {
            let screw = SCNNode(geometry: SCNCylinder(radius: 0.006, height: 0.003))
            screw.geometry?.materials = [material(UIColor(red: 0.6, green: 0.47, blue: 0.25, alpha: 1), metal: 0.8, rough: 0.3)]
            screw.eulerAngles.x = .pi / 2
            screw.position = SCNVector3(Float(x), 0, 0.0075)
            root.addChildNode(screw)
        }
        return root
    }

    // MARK: Vestibule

    /// A tall brushed-steel planter with a leafy plant (the table plant,
    /// scaled up).
    private static func makePlanter() -> SCNNode {
        let root = SCNNode()
        root.name = "administrationPlanter"
        box(0.34, 0.62, 0.34, material(UIColor(white: 0.62, alpha: 1), metal: 0.85, rough: 0.35), 0, 0.31, 0, in: root)
        let plant = HallwayScene.makePottedPlantNode()
        plant.scale = SCNVector3(2.1, 2.3, 2.1)
        plant.position = SCNVector3(0, 0.5, 0)
        root.addChildNode(plant)
        return root
    }

    // MARK: The counter

    /// A tall reception counter in dark cherry with brass trim: a 1.15 m
    /// paneled customer face, brass kick, a transaction ledge, a lower
    /// work surface behind with a banker's lamp, a monitor and paperwork.
    /// Local +Z is the customer side.
    private static func makeCounter() -> SCNNode {
        let root = SCNNode()
        root.name = "administrationCounter"
        let wood = material(cherry, rough: 0.45)
        let woodDark = material(darkCherry, rough: 0.4)
        let brassM = material(brass, metal: 0.85, rough: 0.3)
        let length: CGFloat = 3.4
        let L = Float(length)
        box(length, 1.1, 0.12, woodDark, 0, 0.55, 0.3, in: root)                 // carcass face
        // Raised panels: 2 rows x 3 columns, brass reveals between them.
        let panelW = (length - 0.16) / 3, panelH: CGFloat = 0.42
        for col in 0..<3 {
            for row in 0..<2 {
                let x = -L / 2 + 0.08 + Float(panelW) * (Float(col) + 0.5)
                let y: Float = 0.2 + Float(panelH) * (Float(row) + 0.5) + Float(row) * 0.04
                box(panelW - 0.04, panelH - 0.03, 0.02, wood, x, y, 0.37, in: root)
            }
        }
        box(length, 0.012, 0.012, brassM, 0, 0.63, 0.382, in: root)             // brass reveal line
        box(length + 0.02, 0.14, 0.13, brassM, 0, 0.07, 0.31, in: root)         // brass kick
        box(length + 0.1, 0.05, 0.36, woodDark, 0, 1.125, 0.27, in: root)       // transaction ledge
        box(length + 0.1, 0.012, 0.012, brassM, 0, 1.098, 0.452, in: root)      // ledge nosing
        box(length, 0.04, 0.6, wood, 0, 0.78, -0.08, in: root)                   // work surface behind
        for side: Float in [-1, 1] {
            box(0.08, 0.78, 0.6, woodDark, side * (L / 2 - 0.04), 0.39, -0.08, in: root)
        }
        // Clutter on the work surface (behind the ledge, seen over it).
        let lamp = SCNNode()
        lamp.position = SCNVector3(-L / 2 + 0.45, 0.8, -0.15)
        box(0.16, 0.025, 0.12, brassM, 0, 0.012, 0, in: lamp)
        box(0.018, 0.3, 0.018, brassM, 0, 0.16, 0, in: lamp)
        let shade = SCNNode(geometry: SCNCylinder(radius: 0.09, height: 0.07))
        shade.geometry?.materials = [material(UIColor(red: 0.08, green: 0.32, blue: 0.18, alpha: 1), rough: 0.3,
                                              glow: UIColor(red: 0.08, green: 0.2, blue: 0.1, alpha: 1))]
        shade.position = SCNVector3(0, 0.33, 0.04)
        shade.eulerAngles.x = .pi / 2
        shade.scale = SCNVector3(1.4, 1, 0.75)
        lamp.addChildNode(shade)
        let glow = SCNLight()
        glow.type = .omni
        glow.color = UIColor(red: 1, green: 0.8, blue: 0.55, alpha: 1)
        glow.intensity = 120
        glow.attenuationStartDistance = 0.1
        glow.attenuationEndDistance = 1.6
        let glowNode = SCNNode()
        glowNode.light = glow
        glowNode.position = SCNVector3(0, 0.26, 0.05)
        lamp.addChildNode(glowNode)
        root.addChildNode(lamp)
        // Monitor (seen from behind-ish: its back faces the customer).
        let screen = material(UIColor(white: 0.08, alpha: 1), rough: 0.3)
        box(0.5, 0.33, 0.04, screen, L / 2 - 0.6, 1.08, -0.2, in: root)
        box(0.06, 0.2, 0.06, screen, L / 2 - 0.6, 0.9, -0.22, in: root)
        // Paper stacks and a small plant.
        let paper = material(UIColor(white: 0.9, alpha: 1), rough: 0.9)
        for (i, x) in [L / 2 - 0.2, L / 2 - 0.25, -0.2].enumerated() {
            box(0.3, 0.05 + CGFloat(i) * 0.03, 0.22, paper, x, 0.82 + Float(i) * 0.015, -0.05 - Float(i) * 0.04, in: root, chamfer: 0.002)
        }
        let plant = HallwayScene.makePottedPlantNode()
        plant.position = SCNVector3(-L / 2 + 1.0, 0.8, -0.2)
        root.addChildNode(plant)
        return root
    }

    // MARK: Back office

    static func makeCabinet() -> SCNNode {
        let root = SCNNode()
        let body = material(UIColor(red: 0.3, green: 0.31, blue: 0.3, alpha: 1), metal: 0.5, rough: 0.5)
        let pull = material(UIColor(white: 0.75, alpha: 1), metal: 0.9, rough: 0.3)
        box(0.46, 1.32, 0.6, body, 0, 0.66, 0, in: root)
        for i in 0..<4 {
            let y = 0.18 + Float(i) * 0.31
            box(0.42, 0.006, 0.006, pull, 0, y + 0.14, 0.302, in: root)
            box(0.12, 0.025, 0.02, pull, 0, y, 0.31, in: root)
        }
        return root
    }

    /// Oct 8: the back-wall clock is now the shared real-time WallClock
    /// (it used to fake time: a fixed hour hand and a minute hand creeping
    /// from 12 at launch). Same size and spot; real local time.
    private static func makeClock() -> SCNNode {
        WallClock.makeNode(radius: 0.2)
    }

    // MARK: The Administrator (stand-in)

    private static let standInName = "administratorStandIn"
    private static let idleTiltKey = "idleTilt"

    /// Temporary: a tall, narrow, faintly official being -- slate uniform,
    /// stiff brass collar, long neck, a broad flat head with two large
    /// bulging eyes and a single antenna, forearms resting forward on the
    /// counter. Breathes slowly, tilts its head now and then. Local +Z is
    /// the front; its right arm (local -X) is the pointing arm.
    private static func makeAdministratorStandIn() -> SCNNode {
        let root = SCNNode()
        root.name = standInName
        let uniform = material(UIColor(red: 0.26, green: 0.28, blue: 0.31, alpha: 1))
        let skin = material(UIColor(red: 0.55, green: 0.47, blue: 0.33, alpha: 1), rough: 0.7)
        let trim = material(brass, metal: 0.8, rough: 0.35)
        let white = material(UIColor(white: 0.95, alpha: 1), rough: 0.25)
        let pupil = material(.black, rough: 0.15)

        let body = SCNNode()
        body.name = "adminBody"
        root.addChildNode(body)
        func add(_ g: SCNGeometry, _ m: SCNMaterial, _ p: SCNVector3, to parent: SCNNode) -> SCNNode {
            g.materials = [m]
            let n = SCNNode(geometry: g)
            n.position = p
            parent.addChildNode(n)
            return n
        }
        _ = add(SCNCylinder(radius: 0.22, height: 1.45), uniform, SCNVector3(0, 0.725, 0), to: body)       // torso
        _ = add(SCNCylinder(radius: 0.28, height: 0.09), trim, SCNVector3(0, 1.47, 0), to: body)            // collar
        _ = add(SCNCylinder(radius: 0.06, height: 0.3), skin, SCNVector3(0, 1.64, 0.02), to: body)          // neck
        let head = SCNNode()
        head.name = "adminHead"
        head.position = SCNVector3(0, 1.86, 0.04)
        body.addChildNode(head)
        let skull = add(SCNSphere(radius: 0.16), skin, SCNVector3(0, 0, 0), to: head)
        skull.scale = SCNVector3(1.35, 0.85, 1.15)
        let snout = add(SCNSphere(radius: 0.07), skin, SCNVector3(0, -0.07, 0.15), to: head)
        snout.scale = SCNVector3(1.0, 0.8, 1.3)
        let eyes = SCNNode()
        eyes.name = "adminEyes"
        eyes.position = SCNVector3(0, 0.05, 0)
        head.addChildNode(eyes)
        let pupils = SCNNode()
        pupils.name = "adminPupils"
        eyes.addChildNode(pupils)
        for side: Float in [-1, 1] {
            _ = add(SCNSphere(radius: 0.065), white, SCNVector3(side * 0.12, 0, 0.12), to: eyes)            // big eyes
            _ = add(SCNSphere(radius: 0.03), pupil, SCNVector3(side * 0.12, 0, 0.178), to: pupils)
        }
        let antenna = SCNNode()
        antenna.name = "adminAntenna"
        antenna.position = SCNVector3(0, 0.12, -0.02)
        head.addChildNode(antenna)
        let stalk = add(SCNCylinder(radius: 0.008, height: 0.16), skin, SCNVector3(0, 0.08, 0), to: antenna)
        stalk.eulerAngles.x = -0.25
        _ = add(SCNSphere(radius: 0.018), trim, SCNVector3(0, 0.16, -0.02), to: antenna)
        // Arms: a shoulder pivot each; the arm hangs along the pivot's -Y and
        // is rotated forward onto the counter at rest.
        for side: Float in [-1, 1] {
            let shoulder = SCNNode()
            shoulder.name = side < 0 ? "adminArmPoint" : "adminArmRest"
            shoulder.position = SCNVector3(side * 0.24, 1.42, 0.04)
            shoulder.eulerAngles = armRest
            body.addChildNode(shoulder)
            _ = add(SCNCapsule(capRadius: 0.045, height: 0.6), uniform, SCNVector3(0, -0.3, 0), to: shoulder)
            _ = add(SCNSphere(radius: 0.05), skin, SCNVector3(0, -0.63, 0), to: shoulder)                    // hand
            let finger = add(SCNCapsule(capRadius: 0.014, height: 0.13), skin, SCNVector3(0, -0.72, 0.01), to: shoulder)
            finger.name = "adminFinger"
        }
        let breathe = SCNAction.sequence([.scale(to: 1.012, duration: 2.2), .scale(to: 1.0, duration: 2.4)])
        breathe.timingMode = .easeInEaseOut
        body.runAction(.repeatForever(breathe))
        head.runAction(idleTilt, forKey: idleTiltKey)
        return root
    }

    private static let armRest = SCNVector3(-1.1, 0, 0)          // forward and down onto the counter
    private static let armPoint = SCNVector3(0, 0, -1.75)        // straight out to its right (local -X), a touch up
    /// Oct 5 (post-ID): the OTHER arm (local +X, her left) out toward Fred's
    /// office door -- mirrored, a touch up, and swung a little forward (the
    /// door is ~66 degrees off her front, toward her left).
    private static let armPointOffice = SCNVector3(0, -0.4, 1.75)

    private static var idleTilt: SCNAction {
        .repeatForever(.sequence([.wait(duration: 5), .rotateTo(x: 0, y: 0, z: 0.12, duration: 0.9, usesShortestUnitArc: true),
                                  .wait(duration: 2.5), .rotateTo(x: 0, y: 0, z: 0, duration: 0.9, usesShortestUnitArc: true)]))
    }

    // MARK: The greeting (after the desk landing) and repeat requests

    /// The stand-in already greeted on THIS build of the floor (one
    /// encounter = one visit; a new visit builds a new scene and a new
    /// stand-in, so the Administrator greets again then).
    private static weak var greetedStandIn: SCNNode?
    /// Visit-local patience: how many times the visitor has deliberately
    /// asked again (tapped the Administrator) on this stand-in.
    private static weak var patienceStandIn: SCNNode?
    private static var repeatRequests = 0
    /// Oct 5 (post-ID): what her directions point at. Before the ID: the ID
    /// kiosk (north wall, her right). After the ID, until the prologue is
    /// complete: Fred's office door (south wall of (11,9), her left).
    enum DirectionsTarget: String { case kiosk, office }
    /// Oct 5 (Fred joined): nil once the prologue is complete -- no more
    /// routing gestures (her post-prologue life isn't designed yet).
    static var directionsTarget: DirectionsTarget? {
        if Admission.isPrologueCompleted { return nil }
        return Admission.isCompleted ? .office : .kiosk
    }
    /// The target her greeting this visit was about; a NEW target (the ID
    /// was just taken) earns a fresh automatic telling at the next landing.
    private static var greetedTarget: DirectionsTarget?
    /// One routine at a time -- taps during a routine are ignored.
    private static var busyUntil: CFTimeInterval = 0
    /// Set by a tap on the Administrator; consumed when the desk landing
    /// completes (or at once if already in the pose).
    static var directionsRequested = false

    static func isAdministrator(_ node: SCNNode) -> Bool {
        var n: SCNNode? = node
        while let current = n {
            if current.name == standInName { return true }
            n = current.parent
        }
        return false
    }

    /// The desk landing completed. First time this visit: the automatic
    /// greeting. Afterwards: only if the visitor asked (tapped her).
    static func landedAtDesk(in root: SCNNode) {
        let requested = directionsRequested
        directionsRequested = false
        // Oct 8 (Juanita diagnostics): observe only -- every path through the
        // counter landing is now visible in the report, including the silent ones.
        diag("juanita.landed", ["requested": requested, "admission": Admission.isCompleted,
                                "prologue": Admission.isPrologueCompleted,
                                "target": directionsTarget?.rawValue ?? "none"])
        guard let standIn = root.childNode(withName: standInName, recursively: true) else {
            diag("juanita.noResponse", ["reason": "standInMissing", "requested": requested])
            return
        }
        guard directionsTarget != nil else {                         // prologue complete: no routing
            diag("juanita.noResponse", ["reason": "prologueCompleted", "requested": requested])
            return
        }
        if greetedStandIn !== standIn || greetedTarget != directionsTarget {
            diag("juanita.greetRequested", ["target": directionsTarget?.rawValue ?? "none",
                                            "newTarget": greetedStandIn === standIn])
            greet(in: root)
        } else if requested {
            diag("juanita.repeatRequested", ["count": patienceCount])
            repeatDirections(in: root)
        } else {
            diag("juanita.noResponse", ["reason": "alreadyGreetedNotTapped", "count": patienceCount,
                                        "action": "patienceTimerRestarted"])
            // Oct 7: back at the counter after wandering off -- her patience
            // (the visit's count) is where it was; the clock starts afresh.
            schedulePatienceTimer(for: standIn)
        }
    }

    /// Oct 5: the visitor has just landed at the counter. The Administrator
    /// notices them with a two-thought Hallwegian greeting -- roughly
    /// "welcome to the Hallways Building; your ID, over there" -- then looks
    /// off to ITS right and points: the visitor's left, where the ID terminal
    /// hangs. No words, nothing forced: the camera is never touched.
    static func greet(in root: SCNNode) {
        guard let standIn = root.childNode(withName: standInName, recursively: true) else {
            diag("juanita.noResponse", ["reason": "standInMissing", "in": "greet"])
            return
        }
        guard let target = directionsTarget else {
            diag("juanita.noResponse", ["reason": "prologueCompleted", "in": "greet"])
            return
        }
        guard greetedStandIn !== standIn || greetedTarget != target else {
            diag("administration.greet.skipped", ["reason": "already greeted this visit"])
            return
        }
        if greetedStandIn === standIn { patienceStandIn = nil }   // new target: her patience starts over
        greetedStandIn = standIn
        greetedTarget = target
        diag("administration.greet", ["target": target.rawValue])
        perform(.welcome, on: standIn)
        schedulePatienceTimer(for: standIn)
    }

    /// A deliberate request (a tap) for the directions again. Her patience
    /// runs out over the visit: friendly, then less enthusiastic, then
    /// impatient, then -- on the fourth ask -- she loses it (and stays
    /// exasperated for any further asks this visit).
    static func repeatDirections(in root: SCNNode) {
        guard let standIn = root.childNode(withName: standInName, recursively: true) else {
            diag("juanita.noResponse", ["reason": "standInMissing", "in": "repeat"])
            return
        }
        advancePatience(on: standIn, source: "poke")
    }

    /// The one escalation step, shared by a poke and the patience timer:
    /// the same count, the same moods, the same busy guard.
    private static func advancePatience(on standIn: SCNNode, source: String) {
        guard directionsTarget != nil else {
            diag("juanita.noResponse", ["reason": "prologueCompleted", "in": "patience", "source": source])
            return
        }
        if patienceStandIn !== standIn {
            patienceStandIn = standIn
            repeatRequests = 0
        }
        guard CACurrentMediaTime() >= busyUntil else {
            diag("administration.repeat.skipped", ["reason": "still performing"])
            diag("juanita.ignored", ["reason": "stillPerforming", "source": source])
            return
        }
        repeatRequests += 1
        let mood: Mood
        switch repeatRequests {
        case 1: mood = .friendly
        case 2: mood = .lessEnthused
        case 3: mood = .impatient
        default: mood = .exasperated
        }
        diag("administration.repeat", ["count": repeatRequests, "mood": "\(mood)", "source": source,
                                       "target": directionsTarget?.rawValue ?? "none"])
        perform(mood, on: standIn)
        schedulePatienceTimer(for: standIn)
    }

    // MARK: Oct 7 -- her patience runs out on its own

    /// Seconds AFTER a routine ends before she tells you again, indexed by
    /// how many times she has already repeated herself this visit (0 = only
    /// the greeting so far). Once she has reached the scream, nothing more.
    /// (var only so tests can shorten it.)
    static var patienceIntervals: [TimeInterval] = [8, 7, 6, 5]
    /// The ask count at which she has hit her final mood (the scream).
    static let finalPatienceStage = 4
    /// Is the visitor still standing at the counter? (ContentView wires it;
    /// nil = nobody to be impatient with.)
    static var isVisitorAtDesk: (() -> Bool)?
    /// Bumped to cancel: a pending fire with an older number does nothing
    /// (it holds only a weak reference to the stand-in).
    private static var patienceGeneration = 0
    /// True while a fire is pending (tests / diagnostics).
    private(set) static var isPatienceTimerPending = false
    /// How many times she has repeated herself to THIS visit's stand-in.
    static var patienceCount: Int {
        guard let standIn = greetedStandIn, patienceStandIn === standIn else { return 0 }
        return repeatRequests
    }

    /// One pending timer at most: (re)started after every telling and on a
    /// return to the counter; never past the final stage.
    static func schedulePatienceTimer(for standIn: SCNNode) {
        cancelPatienceTimer()
        guard directionsTarget != nil else { return }
        let done = patienceStandIn === standIn ? repeatRequests : 0
        guard done < finalPatienceStage, done < patienceIntervals.count else { return }
        let remaining = max(0, busyUntil - CACurrentMediaTime())
        let delay = remaining + patienceIntervals[done]
        let generation = patienceGeneration
        isPatienceTimerPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak standIn] in
            guard generation == patienceGeneration else { return }    // cancelled or superseded
            patienceTimerFired(standIn: standIn)
        }
        diag("administration.patience.scheduled", ["after": done, "in": delay])
    }

    static func cancelPatienceTimer() {
        patienceGeneration += 1
        isPatienceTimerPending = false
    }

    /// Oct 8 (Start Over): drop any pending request/timer from the previous
    /// employee's visit. Her behavior is unchanged; the rebuilt floor's new
    /// stand-in greets as on a first visit.
    static func resetForNewPlayer() {
        cancelPatienceTimer()
        directionsRequested = false
    }

    private static func patienceTimerFired(standIn: SCNNode?) {
        isPatienceTimerPending = false
        guard let standIn, standIn.parent != nil else {                // the floor is gone
            diag("juanita.noResponse", ["reason": "floorGone", "in": "patienceTimer"])
            return
        }
        guard isVisitorAtDesk?() == true else {
            diag("administration.patience.cancelled", ["reason": "visitor walked away"])
            return                                                     // resumes when they land again
        }
        if CACurrentMediaTime() < busyUntil {                          // never overlap a routine
            schedulePatienceTimer(for: standIn)
            return
        }
        advancePatience(on: standIn, source: "timer")
    }

    enum Mood { case welcome, friendly, lessEnthused, impatient, exasperated }

    private enum Notice { case full, small, grumble, shriek }

    /// One telling of the directions: an opening "notice", the voice, a
    /// look off to its right, and the point with `jabs` little stabs.
    private struct Telling {
        let voice: SCNAudioSource?
        let notice: Notice
        let lookAt: Double, lookDuration: Double, lookYaw: CGFloat
        let raiseAt: Double, raiseDuration: Double
        let jabGap: Double, jabs: Int, jabAmount: CGFloat, jabDuration: Double
        let hold: Double
        var lowerAt: Double { raiseAt + raiseDuration + jabGap + Double(jabs) * jabDuration + hold }
        var total: Double { lowerAt + 0.55 }
    }

    private static func telling(_ mood: Mood) -> Telling {
        switch mood {
        case .welcome, .friendly:
            // As approved: the two jabs land on the two "dit"s (~1.86 / 2.10 s).
            return Telling(voice: AdministratorVoice.greeting, notice: .full,
                           lookAt: 1.02, lookDuration: 0.35, lookYaw: -0.75,
                           raiseAt: 1.25, raiseDuration: 0.45,
                           jabGap: 0.16, jabs: 2, jabAmount: 0.14, jabDuration: 0.26, hold: 1.5)
        case .lessEnthused:
            // Shorter, lower, one "dit" (~0.85 s), one jab.
            return Telling(voice: AdministratorVoice.lessEnthused, notice: .small,
                           lookAt: 0.35, lookDuration: 0.3, lookYaw: -0.7,
                           raiseAt: 0.5, raiseDuration: 0.35,
                           jabGap: 0, jabs: 1, jabAmount: 0.1, jabDuration: 0.24, hold: 1.0)
        case .impatient:
            // A grumble and a head shake, then three quick hard jabs on
            // "dit-dit-dit" (~0.42 / 0.56 / 0.70 s).
            return Telling(voice: AdministratorVoice.impatient, notice: .grumble,
                           lookAt: 0.36, lookDuration: 0.16, lookYaw: -0.8,
                           raiseAt: 0.3, raiseDuration: 0.12,
                           jabGap: 0, jabs: 3, jabAmount: 0.2, jabDuration: 0.14, hold: 0.8)
        case .exasperated:
            // THE SCREAM: eyes wide, head thrown back, whole body shaking,
            // antenna buzzing -- then four big stabs at the terminal
            // (~1.10 / 1.24 / 1.38 / 1.52 s, on the shrieked "DIT"s).
            return Telling(voice: AdministratorVoice.exasperated, notice: .shriek,
                           lookAt: 0.85, lookDuration: 0.12, lookYaw: -0.9,
                           raiseAt: 0.8, raiseDuration: 0.2,
                           jabGap: 0.1, jabs: 4, jabAmount: 0.32, jabDuration: 0.14, hold: 1.2)
        }
    }

    private static func perform(_ mood: Mood, on standIn: SCNNode) {
        guard let body = standIn.childNode(withName: "adminBody", recursively: true),
              let head = standIn.childNode(withName: "adminHead", recursively: true),
              let eyes = standIn.childNode(withName: "adminEyes", recursively: true),
              let pupils = standIn.childNode(withName: "adminPupils", recursively: true),
              let antenna = standIn.childNode(withName: "adminAntenna", recursively: true) else {
            diag("juanita.noResponse", ["reason": "rigMissing", "mood": "\(mood)"])
            return
        }
        // Oct 5 (post-ID): kiosk = her right arm and a look to her right;
        // Fred's office = her left arm and a wider look to her left.
        let toOffice = directionsTarget == .office
        guard let arm = standIn.childNode(withName: toOffice ? "adminArmRest" : "adminArmPoint", recursively: true) else {
            diag("juanita.noResponse", ["reason": "armMissing", "mood": "\(mood)"])
            return
        }
        let pointPose = toOffice ? armPointOffice : armPoint
        let mirror: CGFloat = toOffice ? -1 : 1
        let t = telling(mood)
        diag("juanita.gesture", ["mood": "\(mood)", "target": directionsTarget?.rawValue ?? "none",
                                 "voice": t.voice != nil, "jabs": t.jabs, "duration": t.total])
        busyUntil = CACurrentMediaTime() + t.total
        func rot(_ x: CGFloat = 0, _ y: CGFloat = 0, _ z: CGFloat = 0, _ d: Double) -> SCNAction {
            .rotateTo(x: x, y: y, z: z, duration: d, usesShortestUnitArc: true)
        }
        func blink(_ depth: Float, _ d: Double) -> SCNAction {
            .customAction(duration: d) { node, e in
                let u = Float(e / CGFloat(d))
                node.scale = SCNVector3(1, 1 - depth * sin(.pi * u), 1)
            }
        }

        // 1. The notice.
        head.removeAction(forKey: idleTiltKey)
        let headNotice: SCNAction
        switch t.notice {
        case .full:
            antenna.runAction(.sequence([rot(0, 0, 0.45, 0.08), rot(0, 0, -0.35, 0.1), rot(0, 0, 0.2, 0.1), rot(0, 0, 0, 0.12)]))
            eyes.runAction(.sequence([.scale(to: 1, duration: 0), blink(0.85, 0.18)]))
            headNotice = .sequence([rot(0.16, 0, 0, 0.14), rot(-0.05, 0, 0, 0.16), rot(0, 0, 0, 0.12)])
        case .small:
            eyes.runAction(.sequence([.scale(to: 1, duration: 0), blink(0.5, 0.3)]))
            headNotice = .sequence([rot(0.08, 0, 0, 0.14), rot(0, 0, 0, 0.14)])
        case .grumble:
            antenna.runAction(.sequence([rot(-0.6, 0, 0, 0.12), .wait(duration: t.total - 0.4), rot(0, 0, 0, 0.25)]))
            headNotice = .sequence([rot(0, 0.15, 0, 0.07), rot(0, -0.15, 0, 0.1), rot(0, 0.1, 0, 0.08), rot(0, 0, 0, 0.08)])
        case .shriek:
            eyes.runAction(.sequence([.scale(to: 1.35, duration: 0.1), .wait(duration: t.total - 0.5), .scale(to: 1, duration: 0.3)]))
            var buzz: [SCNAction] = []
            for i in 0..<12 { buzz.append(rot(0, 0, i % 2 == 0 ? 0.3 : -0.3, 0.04)) }
            buzz.append(rot(0, 0, 0, 0.06))
            antenna.runAction(.sequence(buzz))
            var shake: [SCNAction] = []
            for i in 0..<16 { shake.append(rot(0, 0, i % 2 == 0 ? 0.05 : -0.05, 0.025)) }
            shake.append(rot(0, 0, 0, 0.05))
            body.runAction(.sequence(shake))
            headNotice = .sequence([rot(-0.35, 0, 0, 0.15), .wait(duration: 0.5), rot(0, 0, 0, 0.12)])
        }
        if let voice = t.voice { CritterAudio.play(voice, on: standIn) }

        // 2. Look off to its right (the visitor's left) and point; then back
        // to the visitor as the arm comes down, and the idle tilt resumes.
        let lookAway = rot(0, toOffice ? -t.lookYaw * 1.4 : t.lookYaw, 0, t.lookDuration)
        lookAway.timingMode = .easeInEaseOut
        let lookBack = rot(0, 0, 0, 0.45)
        lookBack.timingMode = .easeInEaseOut
        let noticeTime = headNotice.duration
        let lookHold = max(0.4, t.lowerAt - (t.lookAt + t.lookDuration))
        head.runAction(.sequence([headNotice, .wait(duration: max(0, t.lookAt - noticeTime)), lookAway,
                                  .wait(duration: lookHold), lookBack, idleTilt]), forKey: idleTiltKey)
        pupils.runAction(.sequence([.wait(duration: t.lookAt), .move(to: SCNVector3(Float(-0.02 * mirror), 0, 0), duration: 0.2),
                                    .wait(duration: lookHold), .move(to: SCNVector3(0, 0, 0), duration: 0.25)]))
        let raise = rot(CGFloat(pointPose.x), CGFloat(pointPose.y), CGFloat(pointPose.z), t.raiseDuration)
        raise.timingMode = .easeOut
        let jab = SCNAction.sequence([.rotateBy(x: 0, y: 0, z: t.jabAmount * mirror, duration: t.jabDuration * 0.45),
                                      .rotateBy(x: 0, y: 0, z: -t.jabAmount * mirror, duration: t.jabDuration * 0.55)])
        let lower = rot(CGFloat(armRest.x), CGFloat(armRest.y), CGFloat(armRest.z), 0.55)
        lower.timingMode = .easeInEaseOut
        var armSteps: [SCNAction] = [.wait(duration: t.raiseAt), raise, .wait(duration: t.jabGap)]
        armSteps += Array(repeating: jab, count: t.jabs)
        armSteps += [.wait(duration: t.hold), lower]
        arm.removeAllActions()
        arm.runAction(.sequence(armSteps))
    }
}

// MARK: - The private office (south of reception)

/// Oct 5 -- OFFICE DRESSING (stage only; nobody lives here yet).
///
/// The office behind the four-panel door in the south wall of (11,9): a
/// sparse anteroom (12,9) with a coat rack, then the 2 x 2 room (rows 13-14,
/// cols 8-9). The player comes in heading SOUTH down column 9, so the far
/// (south) end is straight ahead: that is where the desk is, facing the
/// door, with the occupant's chair behind it -- dead ahead on the entrance
/// sightline. The desk bay cell (14,9) is not walkable for the player.
///
/// Around it, against the walls only: a bookcase (east wall, just inside),
/// archive boxes (north-west corner), two filing cabinets (west wall), a
/// visitor chair and a rug defining the space in front of the desk, a
/// wastebasket. The middle of the room is left open.
extension AdministrationReception {
    static func installOffice(into root: SCNNode, s: Float) {
        let office = SCNNode()
        office.name = "administrationOffice"
        office.position = SCNVector3(0, 0.05, 0)             // the floor's top surface
        root.addChildNode(office)
        let westX = (Float(8) - 0.5) * s + 0.05, eastX = (Float(9) + 0.5) * s - 0.05
        let northZ = (Float(13) - 0.5) * s, southZ = (Float(14) + 0.5) * s - 0.05

        // The desk: far end, facing the door; occupant's side toward the back wall.
        let deskX = Float(9) * s - 0.5                        // a touch right of the entrance axis
        let deskZ = southZ - 1.6                              // 1.15 m of room behind it
        let desk = makeOfficeDesk()
        desk.position = SCNVector3(deskX, 0, deskZ)
        desk.eulerAngles.y = Float(Direction.south.yaw)      // local +Z (front) toward the door (north)
        office.addChildNode(desk)

        let chair = makeDeskChair()
        chair.position = SCNVector3(deskX, 0, deskZ + 1.05)
        chair.eulerAngles.y = Float(Direction.south.yaw)     // seat faces the desk (north)
        office.addChildNode(chair)

        // In front of the desk: a rug and one visitor chair (west half, angled in).
        let rugBorder = material(UIColor(red: 0.42, green: 0.33, blue: 0.18, alpha: 1), rough: 0.95)
        let rugField = material(UIColor(red: 0.13, green: 0.19, blue: 0.16, alpha: 1), rough: 0.98)
        box(3.0, 0.008, 2.4, rugBorder, deskX, 0.004, deskZ - 0.75, in: office, chamfer: 0.002)
        box(2.8, 0.01, 2.2, rugField, deskX, 0.006, deskZ - 0.75, in: office, chamfer: 0.002)
        let visitor = makeVisitorChair()
        visitor.position = SCNVector3(deskX - 0.75, 0, deskZ - 1.15)
        visitor.eulerAngles.y = Float(Direction.north.yaw) + 0.25   // seat faces the desk (south), turned in
        office.addChildNode(visitor)

        // Wastebasket off the desk's west end.
        let basket = SCNNode(geometry: SCNCylinder(radius: 0.15, height: 0.32))
        basket.geometry?.materials = [material(UIColor(red: 0.2, green: 0.2, blue: 0.19, alpha: 1), metal: 0.5, rough: 0.55)]
        basket.position = SCNVector3(deskX - 1.25, 0.16, deskZ + 0.3)
        office.addChildNode(basket)

        // Two filing cabinets against the west wall, far half (fronts face east).
        for z in [deskZ - 0.05, deskZ + 0.47] {
            let cabinet = makeCabinet()
            cabinet.position = SCNVector3(westX + 0.32, 0, z)
            cabinet.eulerAngles.y = Float(Direction.west.yaw)
            office.addChildNode(cabinet)
        }

        // Archive boxes in the north-west corner (two on the floor, one on top).
        let cardboard = material(UIColor(red: 0.62, green: 0.48, blue: 0.3, alpha: 1), rough: 0.95)
        let lid = material(UIColor(red: 0.55, green: 0.42, blue: 0.26, alpha: 1), rough: 0.95)
        let boxesAt: [(Float, Float, Float, Float)] = [   // x, y, z, yaw
            (westX + 0.3, 0, northZ + 0.34, 0.05), (westX + 0.3, 0, northZ + 0.8, -0.04), (westX + 0.32, 0.31, northZ + 0.56, 0.2)
        ]
        for (x, y, z, yaw) in boxesAt {
            let archive = SCNNode()
            archive.position = SCNVector3(x, y, z)
            archive.eulerAngles.y = yaw
            box(0.34, 0.27, 0.44, cardboard, 0, 0.135, 0, in: archive, chamfer: 0.004)
            box(0.355, 0.04, 0.455, lid, 0, 0.27, 0, in: archive, chamfer: 0.004)
            office.addChildNode(archive)
        }

        // Bookcase on the east wall, just inside (front faces west).
        let shelves = makeBookcase()
        shelves.position = SCNVector3(eastX - 0.18, 0, northZ + 1.35)
        shelves.eulerAngles.y = Float(Direction.east.yaw)
        office.addChildNode(shelves)

        // Anteroom: only a coat rack, in its south-east corner.
        let rack = makeCoatRack()
        rack.position = SCNVector3((Float(9) + 0.5) * s - 0.38, 0, (Float(12) + 0.5) * s - 0.4)
        office.addChildNode(rack)

        officeNode = office
        officeChairSeat = SCNVector3(deskX, 0, deskZ + 1.05)
        officeDeskCenter = SCNVector3(deskX, 0, deskZ)
        officeCellSize = s
        diag("administration.officeInstalled", ["deskX": Double(deskX), "deskZ": Double(deskZ)])
        installOfficeOccupantIfDue()
        installVacatedPostIfDue()
        FredDoorGuard.installIfDue(in: office, s: s)                // Oct 6: before the ID, Jeff answers the door
    }

    /// Oct 5 (Fred joined): once the prologue is complete the office is the
    /// place he USED to work -- empty chair, his booster left behind with the
    /// top binder still askew from his exit, the banker's lamp off.
    static func installVacatedPostIfDue() {
        guard Admission.isCompleted, Admission.isPrologueCompleted, let office = officeNode,
              office.childNode(withName: "administrationOfficeBooster", recursively: false) == nil else { return }
        let stack = makeBoosterStack()
        stack.position = SCNVector3(officeChairSeat.x, officeSeatTop, officeChairSeat.z)
        stack.eulerAngles.y = 0.06
        if let top = stack.childNode(withName: boosterTopName, recursively: false) {
            top.eulerAngles.y += 0.3                                 // as his step onto the desk left it
            top.position.x += 0.025
            top.position.z += 0.03
        }
        office.addChildNode(stack)
        if let lamp = office.childNode(withName: "administrationOfficeLamp", recursively: true) {
            lamp.childNode(withName: "administrationOfficeLampLight", recursively: true)?.light?.intensity = 0
            lamp.childNode(withName: "administrationOfficeLampShade", recursively: true)?
                .geometry?.firstMaterial?.emission.contents = UIColor.black
        }
        diag("administration.officeVacated", [:])
    }

    // MARK: The occupant (Oct 5, post-ID: presence only)

    static weak var officeNode: SCNNode?
    static var officeChairSeat = SCNVector3(0, 0, 0)
    static var officeDeskCenter = SCNVector3(0, 0, 0)
    static var officeCellSize: Float = 3.52
    /// makeDeskChair's seat surface and the booster's height (office-local y).
    static let officeSeatTop: Float = 0.515
    static let officeOccupantName = "administrationOfficeFred"

    /// After the ID is taken and until the prologue is complete, Fred is at
    /// his desk: the ordinary Noodle model (TinCanRatModel), NOT the
    /// TinCanRat driver -- no camera rig, no walking, no posse -- standing on a
    /// stack of binders and phone books on his full-size chair so his eyes
    /// clear the grown-up desk. Called when the office is built (every
    /// Floor 2 build, including a relaunch) and live when the ID card is
    /// taken. Idempotent.
    static func installOfficeOccupantIfDue() {
        guard Cast.jeffPlacement(floor: floor) == .officeDesk, let office = officeNode,     // Oct 6: the cast authority decides
              office.childNode(withName: officeOccupantName, recursively: false) == nil else { return }
        // Oct 6 (Cast: one Jeff): if he was minding the door, the SAME Jeff
        // goes back to his desk (out of sight behind the closed door). If
        // he is still out showing someone the kiosk, he sits down once he's
        // home (FredDoorGuard calls this again then).
        let doorJeff = FredDoorGuard.surrenderBody()
        if doorJeff == nil, FredDoorGuard.isOut { return }
        let seatTop = officeSeatTop
        if office.childNode(withName: "administrationOfficeBooster", recursively: false) == nil {
            let stack = makeBoosterStack()
            stack.position = SCNVector3(officeChairSeat.x, seatTop, officeChairSeat.z)
            stack.eulerAngles.y = 0.06
            office.addChildNode(stack)
        }

        let fred = doorJeff ?? Cast.makeJeffBody()
        fred.name = officeOccupantName
        if fred.parent !== office { fred.removeFromParentNode(); office.addChildNode(fred) }
        fred.position = SCNVector3(officeChairSeat.x, seatTop + boosterHeight, officeChairSeat.z - 0.02)
        fred.eulerAngles = SCNVector3(0, 0, 0)                     // his front (-Z) faces the desk and the door
        // Working: now and then he looks down at the desk, then back up;
        // the tail flicks once in a while. Nothing else.
        if let body = fred.childNode(withName: "tinCanRatBody", recursively: true) {
            body.runAction(.repeatForever(.sequence([
                .wait(duration: 3.5),
                .rotateTo(x: -0.16, y: 0, z: 0, duration: 0.5, usesShortestUnitArc: true),   // nose down to the papers
                .wait(duration: 2.2),
                .rotateTo(x: 0, y: 0, z: 0, duration: 0.45, usesShortestUnitArc: true),
                .wait(duration: 1.6),
                .rotateTo(x: 0, y: 0.12, z: 0, duration: 0.35, usesShortestUnitArc: true),
                .wait(duration: 0.9),
                .rotateTo(x: 0, y: 0, z: 0, duration: 0.35, usesShortestUnitArc: true)
            ])), forKey: "officeFredWorking")
        }
        if let tail = fred.childNode(withName: "tinCanRatTail", recursively: true) {
            tail.runAction(.repeatForever(.sequence([
                .wait(duration: 6),
                .rotateBy(x: 0, y: 0.35, z: 0, duration: 0.15), .rotateBy(x: 0, y: -0.7, z: 0, duration: 0.25),
                .rotateBy(x: 0, y: 0.35, z: 0, duration: 0.15)
            ])), forKey: "officeFredTail")
        }
        diag("administration.officeOccupantInstalled", ["x": Double(officeChairSeat.x), "z": Double(officeChairSeat.z),
                                                        "standsAt": Double(seatTop + boosterHeight + 0.05)])
        Cast.setJeff(.officeDesk, body: fred, doorJeff != nil ? "same body, back from the door" : "installed at his desk")
    }

    /// The booster: two thick office binders and two old phone books, a
    /// little askew, ~0.24 m high. Origin at its base.
    static let boosterHeight: Float = 0.24
    static let boosterTopName = "administrationOfficeBoosterTop"
    private static func makeBoosterStack() -> SCNNode {
        let root = SCNNode()
        root.name = "administrationOfficeBooster"
        let pages = material(UIColor(red: 0.93, green: 0.9, blue: 0.82, alpha: 1), rough: 0.95)
        let volumes: [(UIColor, Float, Float, Float, Float, Float)] = [   // cover, w, h, d, yaw, dx
            (UIColor(red: 0.85, green: 0.7, blue: 0.2, alpha: 1), 0.36, 0.07, 0.28, 0.0, 0.0),     // phone book
            (UIColor(red: 0.15, green: 0.2, blue: 0.32, alpha: 1), 0.33, 0.065, 0.27, -0.12, 0.02), // binder
            (UIColor(red: 0.8, green: 0.66, blue: 0.22, alpha: 1), 0.34, 0.055, 0.26, 0.1, -0.015),// phone book
            (UIColor(red: 0.4, green: 0.12, blue: 0.1, alpha: 1), 0.31, 0.05, 0.25, -0.05, 0.01)   // binder
        ]
        var y: Float = 0
        for (index, (cover, w, h, d, yaw, dx)) in volumes.enumerated() {
            let volume = SCNNode()
            if index == volumes.count - 1 { volume.name = boosterTopName }
            volume.position = SCNVector3(dx, y, 0)
            volume.eulerAngles.y = yaw
            // Covers top and bottom, a spine on the -X side, the page block
            // showing on the other three edges.
            let coverM = material(cover, rough: 0.7)
            box(CGFloat(w), 0.006, CGFloat(d), coverM, 0, 0.003, 0, in: volume, chamfer: 0.002)
            box(CGFloat(w), 0.006, CGFloat(d), coverM, 0, h - 0.003, 0, in: volume, chamfer: 0.002)
            box(0.012, CGFloat(h), CGFloat(d), coverM, -w / 2 + 0.006, h / 2, 0, in: volume, chamfer: 0.003)
            box(CGFloat(w) - 0.02, CGFloat(h) - 0.012, CGFloat(d) - 0.012, pages, 0.004, h / 2, 0, in: volume, chamfer: 0.001)
            root.addChildNode(volume)
            y += h
        }
        return root
    }

    /// An executive desk in the reception's cherry and brass, 1.9 x 0.9 m:
    /// a paneled front to the visitor (local +Z), two drawer pedestals on the
    /// occupant's side, a green blotter, a banker's lamp, folders, a tray, a
    /// telephone.
    static func makeOfficeDesk() -> SCNNode {
        let root = SCNNode()
        root.name = "administrationOfficeDesk"
        let wood = material(cherry, rough: 0.45)
        let woodDark = material(darkCherry, rough: 0.4)
        let brassM = material(brass, metal: 0.85, rough: 0.3)
        let W: CGFloat = 1.9, D: CGFloat = 0.9, H: CGFloat = 0.77
        let w = Float(W), d = Float(D)
        box(W, 0.045, D, woodDark, 0, Float(H) - 0.022, 0, in: root)                     // top
        box(W + 0.01, 0.012, 0.012, brassM, 0, Float(H) - 0.04, d / 2 + 0.002, in: root) // brass edge, front
        // Visitor face: a paneled modesty front with a brass kick.
        box(W - 0.04, H - 0.05, 0.04, wood, 0, Float(H - 0.05) / 2, d / 2 - 0.04, in: root)
        let panelW = (W - 0.2) / 3
        for i in 0..<3 {
            let x = -w / 2 + 0.1 + Float(panelW) * (Float(i) + 0.5)
            box(panelW - 0.05, 0.4, 0.02, woodDark, x, 0.42, d / 2 - 0.01, in: root)
        }
        box(W - 0.02, 0.1, 0.05, brassM, 0, 0.05, d / 2 - 0.035, in: root)
        // Pedestals with drawers on the occupant's side (local -Z).
        let handle = material(brass, metal: 0.85, rough: 0.3)
        for side: Float in [-1, 1] {
            let x = side * (w / 2 - 0.24)
            box(0.44, H - 0.05, D - 0.08, wood, x, Float(H - 0.05) / 2, -0.02, in: root)
            for k in 0..<3 {
                let y = 0.16 + Float(k) * 0.2
                box(0.4, 0.17, 0.015, woodDark, x, y, -d / 2 + 0.01, in: root)
                box(0.1, 0.014, 0.02, handle, x, y + 0.03, -d / 2 - 0.003, in: root)
            }
        }
        let topY = Float(H) + 0.002
        // Blotter.
        box(0.72, 0.006, 0.46, material(UIColor(red: 0.1, green: 0.24, blue: 0.16, alpha: 1), rough: 0.7), 0, topY, -0.08, in: root, chamfer: 0.002)
        // Banker's lamp at the local -X end (seen from the door: the LEFT end).
        let lamp = SCNNode()
        lamp.name = "administrationOfficeLamp"
        lamp.position = SCNVector3(-w / 2 + 0.28, topY, -0.18)
        box(0.18, 0.025, 0.12, brassM, 0, 0.012, 0, in: lamp)
        box(0.018, 0.32, 0.018, brassM, 0, 0.17, 0, in: lamp)
        let shade = SCNNode(geometry: SCNCylinder(radius: 0.1, height: 0.08))
        shade.geometry?.materials = [material(UIColor(red: 0.08, green: 0.32, blue: 0.18, alpha: 1), rough: 0.3,
                                              glow: UIColor(red: 0.08, green: 0.2, blue: 0.1, alpha: 1))]
        shade.name = "administrationOfficeLampShade"
        shade.position = SCNVector3(0, 0.35, 0.05)
        shade.eulerAngles.x = .pi / 2
        shade.scale = SCNVector3(1.4, 1, 0.75)
        lamp.addChildNode(shade)
        let glow = SCNLight()
        glow.type = .omni
        glow.color = UIColor(red: 1, green: 0.8, blue: 0.55, alpha: 1)
        glow.intensity = 110
        glow.attenuationStartDistance = 0.1
        glow.attenuationEndDistance = 1.8
        let glowNode = SCNNode()
        glowNode.name = "administrationOfficeLampLight"
        glowNode.light = glow
        glowNode.position = SCNVector3(0, 0.28, 0.06)
        lamp.addChildNode(glowNode)
        root.addChildNode(lamp)
        // Folders and papers at the other end; an in/out tray; a telephone.
        let manila = material(UIColor(red: 0.85, green: 0.72, blue: 0.45, alpha: 1), rough: 0.9)
        let paper = material(UIColor(white: 0.92, alpha: 1), rough: 0.9)
        box(0.32, 0.05, 0.24, manila, w / 2 - 0.3, topY + 0.025, -0.12, in: root, chamfer: 0.002)
        box(0.3, 0.03, 0.22, paper, w / 2 - 0.29, topY + 0.065, -0.1, in: root, chamfer: 0.002)
        box(0.32, 0.02, 0.24, manila, w / 2 - 0.62, topY + 0.01, -0.2, in: root, chamfer: 0.002)
        let tray = SCNNode()
        tray.position = SCNVector3(w / 2 - 0.3, topY, 0.22)
        for level: Float in [0.0, 0.09] {
            box(0.3, 0.012, 0.24, brassM, 0, level + 0.01, 0, in: tray, chamfer: 0.002)
            box(0.012, 0.09, 0.24, brassM, -0.15, level + 0.05, 0, in: tray, chamfer: 0.002)
            box(0.012, 0.09, 0.24, brassM, 0.15, level + 0.05, 0, in: tray, chamfer: 0.002)
        }
        box(0.26, 0.012, 0.2, paper, 0, 0.03, 0, in: tray, chamfer: 0.002)
        root.addChildNode(tray)
        let phoneBlack = material(UIColor(white: 0.07, alpha: 1), rough: 0.35)
        box(0.2, 0.07, 0.22, phoneBlack, -w / 2 + 0.68, topY + 0.035, 0.12, in: root, chamfer: 0.02)
        box(0.24, 0.045, 0.06, phoneBlack, -w / 2 + 0.68, topY + 0.09, 0.12, in: root, chamfer: 0.02)
        return root
    }

    /// The occupant's swivel chair: full human size, dark leather, a five-arm
    /// base. Local +Z is the way the seat faces.
    static func makeDeskChair() -> SCNNode {
        let root = SCNNode()
        root.name = "administrationOfficeChair"
        let leather = material(UIColor(red: 0.16, green: 0.1, blue: 0.08, alpha: 1), rough: 0.55)
        let steel = material(UIColor(white: 0.25, alpha: 1), metal: 0.6, rough: 0.4)
        for k in 0..<5 {
            let arm = SCNNode()
            arm.eulerAngles.y = Float(k) * 2 * .pi / 5
            box(0.04, 0.035, 0.33, steel, 0, 0.06, 0.16, in: arm)
            let caster = SCNNode(geometry: SCNSphere(radius: 0.03))
            caster.geometry?.materials = [steel]
            caster.position = SCNVector3(0, 0.03, 0.31)
            arm.addChildNode(caster)
            root.addChildNode(arm)
        }
        box(0.05, 0.36, 0.05, steel, 0, 0.26, 0, in: root)                 // column
        box(0.52, 0.09, 0.5, leather, 0, 0.47, 0, in: root, chamfer: 0.03) // seat
        box(0.5, 0.62, 0.08, leather, 0, 0.86, -0.25, in: root, chamfer: 0.03) // back
        for side: Float in [-1, 1] {
            box(0.05, 0.03, 0.34, leather, side * 0.27, 0.66, -0.02, in: root, chamfer: 0.01)
            box(0.03, 0.17, 0.03, steel, side * 0.27, 0.57, 0.02, in: root)
        }
        return root
    }

    /// A plain wooden visitor's chair. Local +Z is the way the seat faces.
    static func makeVisitorChair() -> SCNNode {
        let root = SCNNode()
        root.name = "administrationVisitorChair"
        let wood = material(cherry, rough: 0.5)
        let seat = material(UIColor(red: 0.13, green: 0.2, blue: 0.16, alpha: 1), rough: 0.8)
        for x: Float in [-0.2, 0.2] {
            for z: Float in [-0.19, 0.19] {
                box(0.04, 0.45, 0.04, wood, x, 0.225, z, in: root, chamfer: 0.004)
            }
            box(0.04, 0.48, 0.04, wood, x, 0.69, -0.19, in: root, chamfer: 0.004)   // back posts
        }
        box(0.46, 0.06, 0.44, seat, 0, 0.47, 0, in: root, chamfer: 0.012)
        box(0.44, 0.12, 0.03, wood, 0, 0.86, -0.19, in: root, chamfer: 0.006)       // top rail
        box(0.44, 0.06, 0.025, wood, 0, 0.64, -0.19, in: root, chamfer: 0.004)      // mid rail
        return root
    }

    /// A 1.5 m wide, 2 m tall cherry bookcase: five shelves of books and
    /// binders in muted colours (a fixed pattern). Local +Z is its front.
    private static func makeBookcase() -> SCNNode {
        let root = SCNNode()
        root.name = "administrationBookcase"
        let wood = material(cherry, rough: 0.5)
        let back = material(darkCherry, rough: 0.6)
        let width: Float = 1.5, depth: Float = 0.34, height: Float = 2.0
        box(CGFloat(width), CGFloat(height), 0.02, back, 0, height / 2, -depth / 2 + 0.01, in: root)
        for side: Float in [-1, 1] {
            box(0.03, CGFloat(height), CGFloat(depth), wood, side * (width / 2 - 0.015), height / 2, 0, in: root)
        }
        let shelfYs: [Float] = [0.06, 0.45, 0.84, 1.23, 1.62, 1.985]
        for y in shelfYs {
            box(CGFloat(width), 0.03, CGFloat(depth), wood, 0, y, 0, in: root)
        }
        let palette: [UIColor] = [
            UIColor(red: 0.36, green: 0.12, blue: 0.1, alpha: 1), UIColor(red: 0.12, green: 0.2, blue: 0.3, alpha: 1),
            UIColor(red: 0.15, green: 0.25, blue: 0.17, alpha: 1), UIColor(red: 0.5, green: 0.42, blue: 0.3, alpha: 1),
            UIColor(red: 0.22, green: 0.2, blue: 0.19, alpha: 1), UIColor(red: 0.62, green: 0.55, blue: 0.42, alpha: 1)
        ]
        let mats = palette.map { material($0, rough: 0.8) }
        var seed: UInt32 = 7
        func next() -> Float { seed = seed &* 1103515245 &+ 12345; return Float((seed >> 16) & 0x7fff) / 32767 }
        for (row, y) in shelfYs.dropLast().enumerated() {
            var x = -width / 2 + 0.05
            let limit = row == 2 ? 0.25 as Float : width / 2 - 0.05    // one half-empty shelf
            while x < limit {
                let t = 0.03 + next() * 0.035
                let h = 0.22 + next() * 0.1
                box(CGFloat(t), CGFloat(h), CGFloat(0.2 + next() * 0.06), mats[Int(next() * Float(mats.count - 1))],
                    x + t / 2, y + 0.015 + h / 2, 0.02, in: root, chamfer: 0.002)
                x += t + 0.004
                if next() < 0.06 { x += 0.12 }                          // the odd gap
            }
        }
        return root
    }

    /// A bentwood-style coat rack: dark pole, round base, brass hooks.
    static func makeCoatRack() -> SCNNode {
        let root = SCNNode()
        root.name = "administrationCoatRack"
        let wood = material(darkCherry, rough: 0.5)
        let brassM = material(brass, metal: 0.85, rough: 0.3)
        let base = SCNNode(geometry: SCNCylinder(radius: 0.2, height: 0.04))
        base.geometry?.materials = [wood]
        base.position = SCNVector3(0, 0.02, 0)
        root.addChildNode(base)
        let pole = SCNNode(geometry: SCNCylinder(radius: 0.025, height: 1.75))
        pole.geometry?.materials = [wood]
        pole.position = SCNVector3(0, 0.9, 0)
        root.addChildNode(pole)
        let finial = SCNNode(geometry: SCNSphere(radius: 0.04))
        finial.geometry?.materials = [wood]
        finial.position = SCNVector3(0, 1.8, 0)
        root.addChildNode(finial)
        for k in 0..<4 {
            let hook = SCNNode()
            hook.eulerAngles.y = Float(k) * .pi / 2 + .pi / 4
            box(0.015, 0.015, 0.16, brassM, 0, 1.66, 0.08, in: hook, chamfer: 0.004)
            box(0.015, 0.06, 0.015, brassM, 0, 1.69, 0.155, in: hook, chamfer: 0.004)
            root.addChildNode(hook)
        }
        return root
    }
}


/// Oct 5: the Administrator's voice -- synthesised like the Menagerie's
/// (no assets), positional, played through CritterAudio. Hallways creatures
/// do not speak English: this is a creature sound, not pretend language.
nonisolated enum AdministratorVoice {
    /// Two short thoughts, in the same burbly voice as before:
    /// "Brr-up? oh! -- mm-hmm-hm" (roughly: welcome, welcome to the
    /// building), a small beat, then "brr-ru-ruh -- wheee? -- dit! dit!"
    /// (roughly: your ID -- over THERE), the two "dit"s landing on the two
    /// little jabs of the pointing arm. About 2.2 s.
    static let greeting: SCNAudioSource? = MenagerieSound.source("admin-greet-v2", volume: 0.9) {
        MenagerieSound.mix([
            // Thought 1: welcome.
            (at: 0.00, samples: MenagerieSound.sweep(240, 400, seconds: 0.13, wobble: 2.6), gain: 0.7),
            (at: 0.13, samples: MenagerieSound.sweep(420, 300, seconds: 0.09, wobble: 1.4), gain: 0.55),
            (at: 0.26, samples: MenagerieSound.sweep(520, 1020, seconds: 0.17, wobble: 0.4, curve: 0.7), gain: 0.95),
            (at: 0.46, samples: MenagerieSound.sweep(860, 640, seconds: 0.12, wobble: 0.6), gain: 0.6),
            (at: 0.60, samples: MenagerieSound.sweep(520, 700, seconds: 0.10, wobble: 1.8), gain: 0.55),
            (at: 0.72, samples: MenagerieSound.sweep(700, 560, seconds: 0.14, wobble: 0.4, curve: 1.3), gain: 0.6),
            // Thought 2: your ID -- over there!
            (at: 1.05, samples: MenagerieSound.sweep(300, 460, seconds: 0.11, wobble: 2.2), gain: 0.65),
            (at: 1.18, samples: MenagerieSound.sweep(480, 620, seconds: 0.10, wobble: 1.0), gain: 0.55),
            (at: 1.30, samples: MenagerieSound.sweep(640, 520, seconds: 0.12, wobble: 0.8), gain: 0.55),
            (at: 1.48, samples: MenagerieSound.sweep(560, 900, seconds: 0.16, wobble: 0.3, curve: 0.8), gain: 0.85),
            (at: 1.86, samples: MenagerieSound.sweep(980, 1150, seconds: 0.07), gain: 0.8),
            (at: 2.10, samples: MenagerieSound.sweep(980, 1200, seconds: 0.08), gain: 0.8)
        ])
    }

    /// Repeat #2 -- still helpful, less bubbly: lower, shorter, one "dit".
    static let lessEnthused: SCNAudioSource? = MenagerieSound.source("admin-dir-less-v1", volume: 0.75) {
        MenagerieSound.mix([
            (at: 0.00, samples: MenagerieSound.sweep(280, 380, seconds: 0.12, wobble: 2.0), gain: 0.6),
            (at: 0.14, samples: MenagerieSound.sweep(380, 330, seconds: 0.10, wobble: 1.0), gain: 0.5),
            (at: 0.40, samples: MenagerieSound.sweep(300, 420, seconds: 0.10, wobble: 1.8), gain: 0.55),
            (at: 0.55, samples: MenagerieSound.sweep(460, 720, seconds: 0.15, wobble: 0.3, curve: 0.8), gain: 0.7),
            (at: 0.85, samples: MenagerieSound.sweep(860, 980, seconds: 0.07), gain: 0.65)
        ])
    }

    /// Repeat #3 -- impatient: a low "hrrmph-hrm" grumble, then a clipped
    /// "dit-dit-dit!".
    static let impatient: SCNAudioSource? = MenagerieSound.source("admin-dir-impatient-v1", volume: 0.85) {
        MenagerieSound.mix([
            (at: 0.00, samples: MenagerieSound.sweep(220, 170, seconds: 0.14, wobble: 3.5), gain: 0.85),
            (at: 0.18, samples: MenagerieSound.sweep(200, 150, seconds: 0.12, wobble: 3.0), gain: 0.75),
            (at: 0.42, samples: MenagerieSound.sweep(900, 1000, seconds: 0.06), gain: 0.9),
            (at: 0.56, samples: MenagerieSound.sweep(900, 1000, seconds: 0.06), gain: 0.9),
            (at: 0.70, samples: MenagerieSound.sweep(900, 1050, seconds: 0.07), gain: 0.95)
        ])
    }

    /// Repeat #4+ -- she loses it: a wobbling shriek that climbs, warbles
    /// and collapses, then three shrieked "DIT!"s with the stabs. Funny,
    /// not frightening -- a kettle of a receptionist boiling over.
    static let exasperated: SCNAudioSource? = MenagerieSound.source("admin-dir-scream-v1", volume: 1.0) {
        MenagerieSound.mix([
            (at: 0.00, samples: MenagerieSound.sweep(300, 1400, seconds: 0.35, wobble: 4.0, curve: 0.6), gain: 1.0),
            (at: 0.33, samples: MenagerieSound.sweep(1400, 1250, seconds: 0.45, wobble: 6.0), gain: 1.0),
            (at: 0.80, samples: MenagerieSound.sweep(1250, 600, seconds: 0.25, wobble: 3.0), gain: 0.9),
            (at: 1.10, samples: MenagerieSound.sweep(980, 1200, seconds: 0.08), gain: 1.0),
            (at: 1.24, samples: MenagerieSound.sweep(980, 1200, seconds: 0.08), gain: 1.0),
            (at: 1.38, samples: MenagerieSound.sweep(980, 1250, seconds: 0.10), gain: 1.0)
        ])
    }
}
