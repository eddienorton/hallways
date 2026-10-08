import SceneKit
import UIKit
import simd

/// Oct 6 -- THE PLAYER'S OFFICE (Floor 3): the end of onboarding and the
/// player's home base. A believable office prepared for a new hire: a door
/// with their employee number on it, a desk facing the door with a dark
/// banker's lamp (Candy turns it on), a computer, their Hallways ID
/// portrait already in a frame, a chair, a visitor's chair, a filing
/// cabinet, a mostly empty shelf, a coat rack with one bare hanger, one
/// photo already on the wall (authored picture data) and one bare nail.
///
/// Layout (DefaultMazes Floor 3): a 2 x 2 room, rows 8-9 x cols 12-13,
/// entered from the east corridor through the four-panel door in the south
/// wall of (7,12). The player walks in heading south; the desk is straight
/// ahead in (9,12) -- the desk bay, seen but not walked (like Candy's own).
///
/// Built into the floor's scene on every Floor 3 build (staged or not),
/// office-local == world x/z, y = 0 at the floor's top surface.
enum PlayerOffice {
    static let floor = 3
    static let doorCell = GridCoordinate(row: 7, col: 12)               // door in its south wall
    static let entryCell = GridCoordinate(row: 8, col: 12)
    static let officeCells: Set<GridCoordinate> = [
        GridCoordinate(row: 8, col: 12), GridCoordinate(row: 8, col: 13),
        GridCoordinate(row: 9, col: 12), GridCoordinate(row: 9, col: 13)
    ]
    /// The desk, its chair and the space behind it: seen, not walked.
    static let deskBayCells: Set<GridCoordinate> = [GridCoordinate(row: 9, col: 12)]
    static let floorTopY: Float = 0.05
    static let deskTopHeight: Float = 0.772

    // Live references for this build (Candy's goodbye, the computer later).
    static weak var officeNode: SCNNode?
    static weak var lamp: SCNNode?
    static weak var computer: SCNNode?
    /// World x/z of the desk's centre, and its far (occupant) side sign.
    private(set) static var deskCenter = SIMD2<Float>(0, 0)
    private(set) static var cellSize: Float = 3.52

    /// Where Candy waits just inside, beside the door, for the player to come in.
    static var welcomeSpot: SIMD2<Float> {
        SIMD2<Float>(Float(doorCell.col) * cellSize + 0.95, (Float(doorCell.row) + 0.5) * cellSize + 1.1)
    }
    /// The door plane's centre (world x/z).
    static var doorCenter: SIMD2<Float> {
        SIMD2<Float>(Float(doorCell.col) * cellSize, (Float(doorCell.row) + 0.5) * cellSize)
    }
    static var deskTopWorldY: Float { floorTopY + deskTopHeight }
    /// The desk's front edge (the side facing the door), world z.
    static var deskFrontZ: Float { deskCenter.y - 0.45 }

    static func install(into root: SCNNode, cellSize: CGFloat, cells: Set<GridCoordinate>) {
        guard officeCells.isSubset(of: cells), cells.contains(doorCell) else {
            diag("playerOffice.layoutMismatch", ["cells": cells.count])
            return
        }
        let s = Float(cellSize)
        self.cellSize = s
        let office = SCNNode()
        office.name = "playerOffice"
        office.position = SCNVector3(0, floorTopY, 0)
        root.addChildNode(office)
        officeNode = office

        let eastX = (Float(13) + 0.5) * s - 0.05
        let northZ = (Float(8) - 0.5) * s + 0.05, southZ = (Float(9) + 0.5) * s - 0.05

        // The desk: far end, facing the door, a touch right of the entry axis.
        let deskX = Float(doorCell.col) * s + 0.25
        let deskZ = southZ - 1.6
        let desk = makeNewHireDesk()
        desk.position = SCNVector3(deskX, 0, deskZ)
        desk.eulerAngles.y = Float(Direction.south.yaw)                  // local +Z (front) toward the door
        office.addChildNode(desk)
        deskCenter = SIMD2<Float>(deskX, deskZ)

        let chair = AdministrationReception.makeDeskChair()
        chair.name = "playerOfficeChair"
        chair.position = SCNVector3(deskX, 0, deskZ + 1.05)
        chair.eulerAngles.y = Float(Direction.south.yaw)
        office.addChildNode(chair)

        let visitor = AdministrationReception.makeVisitorChair()
        visitor.position = SCNVector3(deskX - 0.8, 0, deskZ - 1.15)
        visitor.eulerAngles.y = Float(Direction.north.yaw) + 0.25
        office.addChildNode(visitor)

        // A filing cabinet against the east wall, far half (front faces west).
        let cabinet = AdministrationReception.makeCabinet()
        cabinet.name = "playerOfficeCabinet"
        cabinet.position = SCNVector3(eastX - 0.32, 0, southZ - 0.9)
        cabinet.eulerAngles.y = Float(Direction.east.yaw)
        office.addChildNode(cabinet)

        // A mostly empty shelf on the east wall, near half (front faces west).
        let shelf = makeEmptyShelf()
        shelf.position = SCNVector3(eastX - 0.18, 0, northZ + 1.6)
        shelf.eulerAngles.y = Float(Direction.east.yaw)
        office.addChildNode(shelf)

        // A coat rack in the corner by the door wall (clear of the door's
        // swing), with one bare wire hanger.
        let rack = AdministrationReception.makeCoatRack()
        rack.name = "playerOfficeCoatRack"
        rack.position = SCNVector3(eastX - 0.45, 0, northZ + 0.45)
        rack.addChildNode(makeBareHanger())
        office.addChildNode(rack)

        // One bare nail on the inside of the door wall (east of the door),
        // with the faintly paler patch where a frame used to be.
        let nail = makeBareNail()
        nail.position = SCNVector3(Float(13) * s, 1.6, northZ + 0.001)
        office.addChildNode(nail)

        dressDoor(in: root)
        diag("playerOffice.installed", ["deskX": Double(deskX), "deskZ": Double(deskZ)])
    }

    // MARK: The lamp (Candy's handoff)

    /// Off when the office is first built; Candy switches it on.
    static func setLamp(on: Bool) {
        guard let lamp else { return }
        lamp.childNode(withName: "playerOfficeLampLight", recursively: true)?.light?.intensity = on ? 120 : 0
        if let shade = lamp.childNode(withName: "playerOfficeLampShade", recursively: true) {
            shade.geometry?.firstMaterial?.emission.contents = on ? UIColor(red: 0.1, green: 0.32, blue: 0.16, alpha: 1) : UIColor.black
        }
        lamp.runAction(.sequence([.rotateBy(x: 0, y: 0, z: 0.05, duration: 0.05), .rotateBy(x: 0, y: 0, z: -0.08, duration: 0.09),
                                  .rotateBy(x: 0, y: 0, z: 0.03, duration: 0.08)]))
        diag("playerOffice.lamp", ["on": on])
    }

    /// The lamp's world position (for Candy to reach it).
    static var lampWorld: SCNVector3? { lamp?.presentation.worldPosition }

    // MARK: The workstation (Oct 7 -- F)

    /// True for the computer, the desk it stands on and the desk chair: a tap
    /// on any of them (from inside the office) sits the player down.
    static func isWorkstation(_ node: SCNNode) -> Bool {
        var n: SCNNode? = node
        while let current = n {
            if let name = current.name, name == "playerOfficeComputer" || name == "playerOfficeDesk" || name == "playerOfficeChair" {
                return true
            }
            if current === officeNode { return false }
            n = current.parent
        }
        return false
    }

    /// True for the computer itself (display, stand, keyboard, mouse): while
    /// seated, a tap on the hardware around the screen belongs to the
    /// computer -- it is not the room, so it never means "get up".
    static func isComputerHardware(_ node: SCNNode) -> Bool {
        var n: SCNNode? = node
        while let current = n {
            if current.name == "playerOfficeComputer" { return true }
            if current === officeNode { return false }
            n = current.parent
        }
        return false
    }

    /// The physical display's outer size (body incl. bezel), metres.
    static let monitorSize = SIMD2<Float>(0.6, 0.37)
    /// The screen plane's size (playerOfficeComputerScreen), metres.
    static let screenSize = SIMD2<Float>(0.55, 0.32)

    /// The seated view: the eye in the chair, square to the monitor and level
    /// with the screen's centre (so the screen projects as an exact
    /// rectangle), backed off just far enough that the WHOLE physical monitor
    /// fits with breathing room: at most 95% of the view's width and 60% of
    /// its height, from the live camera's actual field of view and the
    /// view's aspect -- any phone or iPad, either orientation. Clamped to the
    /// chair/back-wall range. `tanHalfH/V` = tan of half the horizontal and
    /// vertical field of view.
    static func seatedView(tanHalfH: Float, tanHalfV: Float) -> (position: SCNVector3, yaw: Double, pitch: Double)? {
        guard let screen = computer?.childNode(withName: "playerOfficeComputerScreen", recursively: true),
              tanHalfH > 0.01, tanHalfV > 0.01 else { return nil }
        let p = screen.presentation.worldPosition
        let front = screen.presentation.worldFront                    // the node's -Z; the screen faces +Z
        var n = SIMD2<Float>(-front.x, -front.z)
        let len = simd_length(n)
        guard len > 0.01 else { return nil }
        n /= len
        // Oct 7 (phone test): the side cushion was more than needed -- the
        // monitor may now fill 95% of the view's width (2.5% room each side,
        // a quarter of the old 10%). Height rule unchanged.
        let byWidth = monitorSize.x / (2 * 0.95 * tanHalfH)
        let byHeight = monitorSize.y / (2 * 0.60 * tanHalfV)
        let distance = min(max(max(byWidth, byHeight), 0.42), 1.3)
        let eye = SCNVector3(p.x + n.x * distance, p.y, p.z + n.y * distance)
        return (eye, Double(atan2(n.x, n.y)), 0)
    }

    /// Where the player ends up after getting up from the desk: out in the
    /// open part of the office (the cell beside the entry, (8,13)), facing
    /// the door -- out into the room, not back at the computer.
    static var standUpSpot: (position: SIMD2<Float>, yaw: Double) {
        let s = cellSize
        let spot = SIMD2<Float>(13 * s - 0.6, 8 * s + 0.9)
        let toDoor = doorCenter - spot
        return (spot, Double(atan2(-toDoor.x, -toDoor.y)))
    }

    /// If the straight glide from `start` to the seat would cut through the
    /// desk, a point beside the desk's open (east) end to go round by.
    static func seatWaypoint(from start: SCNVector3, to seat: SCNVector3) -> SCNVector3? {
        let half = SIMD2<Float>(0.98, 0.52)                             // desk footprint (+ a margin), any yaw of 0/pi
        func insideDesk(_ x: Float, _ z: Float) -> Bool {
            abs(x - deskCenter.x) < half.x && abs(z - deskCenter.y) < half.y
        }
        var crosses = false
        for i in 1..<24 {
            let t = Float(i) / 24
            if insideDesk(start.x + (seat.x - start.x) * t, start.z + (seat.z - start.z) * t) { crosses = true; break }
        }
        guard crosses else { return nil }
        return SCNVector3(deskCenter.x + 1.55, start.y, seat.z)
    }

    // MARK: Door

    /// The office door: the same four-panel leaf, refinished as an ordinary
    /// office door in this building (painted, steel hardware and kick plate)
    /// with the player's employee number on a steel nameplate at eye height.
    /// Everything is a child of the leaf, so it swings with the door.
    private static func dressDoor(in root: SCNNode) {
        guard let hinge = root.childNode(withName: "roomEntranceDoor_\(doorCell.row)_\(doorCell.col)", recursively: true),
              let leaf = hinge.childNodes.first else {
            diag("playerOffice.door.missing", [:])
            return
        }
        let frameM = AdministrationReception.material(UIColor(red: 0.5, green: 0.48, blue: 0.44, alpha: 1), rough: 0.55)
        let panelM = AdministrationReception.material(UIColor(red: 0.62, green: 0.6, blue: 0.55, alpha: 1), rough: 0.6)
        var leafBoxes: [SCNNode] = []
        for piece in leaf.childNodes {
            guard let box = piece.geometry as? SCNBox, let m = box.firstMaterial else { continue }
            box.materials = [m.multiply.contents != nil ? frameM : panelM]
            leafBoxes.append(piece)
        }
        let steel = AdministrationReception.material(UIColor(white: 0.72, alpha: 1), metal: 0.85, rough: 0.3)
        for child in leaf.childNodes where !leafBoxes.contains(where: { $0 === child }) {
            child.enumerateHierarchy { n, _ in
                if let g = n.geometry { g.materials = g.materials.map { _ in steel } }
            }
        }
        guard let frameDepth = leafBoxes.compactMap({ ($0.geometry as? SCNBox)?.length }).max() else { return }
        let faceZ = -Float(frameDepth / 2)                             // the corridor (north) face
        let doorCenterY = hinge.position.y
        let kick = SCNNode(geometry: SCNBox(width: 0.86, height: 0.2, length: 0.004, chamferRadius: 0.001))
        kick.geometry?.materials = [AdministrationReception.material(UIColor(white: 0.66, alpha: 1), metal: 0.75, rough: 0.45)]
        kick.position = SCNVector3(0, -doorCenterY + 0.02 + 0.12, faceZ - 0.002)
        leaf.addChildNode(kick)
        let number = EmployeeID.number ?? "UNASSIGNED"
        let plate = AdministrationReception.makeDepartmentPlaque(number, width: 0.42, height: 0.11,
                                                                 face: UIColor(white: 0.78, alpha: 1),
                                                                 ink: UIColor(white: 0.1, alpha: 1),
                                                                 backing: UIColor(white: 0.18, alpha: 1))
        plate.name = "playerOfficeNameplate"
        plate.position = SCNVector3(0, 1.5 - doorCenterY, faceZ - 0.001)
        plate.eulerAngles.y = .pi
        leaf.addChildNode(plate)
        diag("playerOffice.door.dressed", ["number": number])
    }

    // MARK: Furniture

    /// A plain standard-issue desk (light oak, steel pulls) prepared for a
    /// new hire: a blotter, a dark banker's lamp, an empty in-tray, a phone,
    /// the computer, and the employee's ID portrait in a small frame.
    /// Local +Z is the visitor's side; the occupant sits at -Z.
    private static func makeNewHireDesk() -> SCNNode {
        let root = SCNNode()
        root.name = "playerOfficeDesk"
        let m = AdministrationReception.material
        let box = AdministrationReception.box
        let oak = m(UIColor(red: 0.56, green: 0.42, blue: 0.27, alpha: 1), 0, 0.5, nil)
        let oakDark = m(UIColor(red: 0.42, green: 0.3, blue: 0.19, alpha: 1), 0, 0.45, nil)
        let steel = m(UIColor(white: 0.7, alpha: 1), 0.8, 0.3, nil)
        let W: CGFloat = 1.8, D: CGFloat = 0.85, H = CGFloat(deskTopHeight)
        let w = Float(W), d = Float(D)
        box(W, 0.04, D, oakDark, 0, Float(H) - 0.02, 0, root, 0.006)                          // top
        box(W - 0.04, H - 0.06, 0.03, oak, 0, Float(H - 0.06) / 2 + 0.02, d / 2 - 0.05, root, 0.006) // modesty panel
        for side: Float in [-1, 1] {                                                          // pedestals
            let x = side * (w / 2 - 0.23)
            box(0.42, H - 0.04, D - 0.1, oak, x, Float(H - 0.04) / 2, -0.02, root, 0.006)
            for k in 0..<3 {
                let y = 0.15 + Float(k) * 0.2
                box(0.38, 0.17, 0.012, oakDark, x, y, -d / 2 + 0.04, root, 0.004)
                box(0.12, 0.012, 0.02, steel, x, y + 0.04, -d / 2 + 0.025, root, 0.003)
            }
        }
        let topY = Float(H) + 0.002
        box(0.7, 0.006, 0.44, m(UIColor(red: 0.16, green: 0.2, blue: 0.24, alpha: 1), 0, 0.7, nil), 0, topY, -0.1, root, 0.002) // blotter

        // The banker's lamp at the local -X end (from the door: the LEFT end). OFF.
        let lamp = SCNNode()
        lamp.name = "playerOfficeLamp"
        lamp.position = SCNVector3(-w / 2 + 0.26, topY, -0.2)
        let brassM = m(AdministrationReception.brass, 0.85, 0.3, nil)
        box(0.18, 0.025, 0.12, brassM, 0, 0.012, 0, lamp, 0.006)
        box(0.018, 0.32, 0.018, brassM, 0, 0.17, 0, lamp, 0.006)
        let shade = SCNNode(geometry: SCNCylinder(radius: 0.1, height: 0.08))
        shade.geometry?.materials = [m(UIColor(red: 0.08, green: 0.32, blue: 0.18, alpha: 1), 0, 0.3, UIColor.black)]
        shade.name = "playerOfficeLampShade"
        shade.position = SCNVector3(0, 0.35, 0.05)
        shade.eulerAngles.x = .pi / 2
        shade.scale = SCNVector3(1.4, 1, 0.75)
        lamp.addChildNode(shade)
        let glow = SCNLight()
        glow.type = .omni
        glow.color = UIColor(red: 1, green: 0.8, blue: 0.55, alpha: 1)
        glow.intensity = 0                                                // off until Candy turns it on
        glow.attenuationStartDistance = 0.1
        glow.attenuationEndDistance = 1.9
        let glowNode = SCNNode()
        glowNode.name = "playerOfficeLampLight"
        glowNode.light = glow
        glowNode.position = SCNVector3(0, 0.28, 0.06)
        lamp.addChildNode(glowNode)
        root.addChildNode(lamp)
        self.lamp = lamp

        // An empty steel in-tray and a telephone at the other end.
        let tray = SCNNode()
        tray.position = SCNVector3(w / 2 - 0.28, topY, 0.2)
        for level: Float in [0.0, 0.08] {
            box(0.3, 0.01, 0.24, steel, 0, level + 0.01, 0, tray, 0.002)
            box(0.01, 0.08, 0.24, steel, -0.15, level + 0.045, 0, tray, 0.002)
            box(0.01, 0.08, 0.24, steel, 0.15, level + 0.045, 0, tray, 0.002)
        }
        root.addChildNode(tray)
        let phone = m(UIColor(white: 0.12, alpha: 1), 0, 0.4, nil)
        box(0.2, 0.06, 0.2, phone, w / 2 - 0.3, topY + 0.03, -0.18, root, 0.02)
        box(0.22, 0.04, 0.06, phone, w / 2 - 0.3, topY + 0.08, -0.18, root, 0.02)

        // The computer, facing the occupant (its screen on local -Z).
        let pc = makeComputer()
        pc.position = SCNVector3(0.08, topY, -0.08)
        pc.eulerAngles.y = .pi
        root.addChildNode(pc)
        self.computer = pc

        // The framed desk photo, at the occupant's left as they sit at the
        // computer. Oct 7 (phone test): it used to stand at keyboard depth
        // (local z -0.24) and crowded the keyboard in the seated view; it now
        // stands deeper on the desk, just behind the monitor's plane and
        // beside its stand (same left/right place, nudged 2 cm outward), its
        // top tucked a little behind the monitor's lower bezel, turned to
        // face the seated occupant. Was: (w/2 - 0.62, -0.24), yaw -2.35.
        let frame = makePortraitFrame()
        frame.position = SCNVector3(w / 2 - 0.60, topY, 0.02)
        frame.eulerAngles.y = -2.93
        root.addChildNode(frame)
        return root
    }

    /// Generic, unbranded workstation: a slim aluminium display on a stand,
    /// a dark screen showing a quiet standby wallpaper, a keyboard, a mouse.
    /// Local +Z is the screen's face. Named for the computer pass to come.
    private static func makeComputer() -> SCNNode {
        let m = AdministrationReception.material
        let box = AdministrationReception.box
        let root = SCNNode()
        root.name = "playerOfficeComputer"
        let alu = m(UIColor(white: 0.78, alpha: 1), 0.85, 0.32, nil)
        let dark = m(UIColor(white: 0.08, alpha: 1), 0.2, 0.35, nil)
        box(0.22, 0.012, 0.17, alu, 0, 0.006, -0.04, root, 0.004)            // stand foot
        box(0.05, 0.2, 0.02, alu, 0, 0.11, -0.07, root, 0.004)               // neck
        let display = SCNNode()
        display.position = SCNVector3(0, 0.37, -0.05)
        box(0.6, 0.37, 0.022, alu, 0, 0, -0.012, display, 0.01)             // body
        box(0.58, 0.35, 0.004, dark, 0, 0, 0.0, display, 0.006)             // bezel/glass
        let screenPlane = SCNPlane(width: 0.55, height: 0.32)
        let screenM = SCNMaterial()
        screenM.lightingModel = .constant
        let wallpaper = standbyWallpaper()
        screenM.diffuse.contents = wallpaper
        screenM.emission.contents = wallpaper
        screenPlane.materials = [screenM]
        let screen = SCNNode(geometry: screenPlane)
        screen.name = "playerOfficeComputerScreen"
        screen.position = SCNVector3(0, 0, 0.003)
        display.addChildNode(screen)
        root.addChildNode(display)
        // Keyboard and mouse in front of it.
        box(0.42, 0.012, 0.13, alu, 0, 0.006, 0.2, root, 0.004)
        box(0.39, 0.004, 0.105, m(UIColor(white: 0.9, alpha: 1), 0, 0.5, nil), 0, 0.014, 0.2, root, 0.002)
        let mouse = SCNNode(geometry: SCNCapsule(capRadius: 0.025, height: 0.1))
        mouse.geometry?.materials = [m(UIColor(white: 0.92, alpha: 1), 0, 0.4, nil)]
        mouse.eulerAngles.x = .pi / 2
        mouse.scale = SCNVector3(1, 1, 0.45)
        mouse.position = SCNVector3(0.3, 0.012, 0.2)
        root.addChildNode(mouse)
        return root
    }

    /// The display's quiet standby picture: a deep blue-grey gradient with a
    /// soft lighter horizon. No marks, no text.
    private static func standbyWallpaper() -> UIImage {
        let size = CGSize(width: 550, height: 320)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(red: 0.1, green: 0.14, blue: 0.22, alpha: 1).cgColor,
                          UIColor(red: 0.22, green: 0.3, blue: 0.38, alpha: 1).cgColor,
                          UIColor(red: 0.12, green: 0.16, blue: 0.22, alpha: 1).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]) else { return }
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
    }

    /// A small dark-wood easel frame with the player's Hallways ID portrait
    /// (as saved when the card was issued). Face on local +Z.
    private static func makePortraitFrame() -> SCNNode {
        let m = AdministrationReception.material
        let box = AdministrationReception.box
        let root = SCNNode()
        root.name = "playerOfficePortrait"
        let wood = m(UIColor(red: 0.2, green: 0.12, blue: 0.08, alpha: 1), 0, 0.5, nil)
        let holder = SCNNode()
        holder.position = SCNVector3(0, 0.11, 0)
        holder.eulerAngles.x = -0.18                                          // leaning back on its easel
        box(0.16, 0.21, 0.014, wood, 0, 0, 0, holder, 0.003)
        let photoPlane = SCNPlane(width: 0.12, height: 0.16)
        let photoM = SCNMaterial()
        // Oct 7 (digital photo frame): the PICTURE ONLY is self-lit -- the
        // .constant lighting model shows the image at its own colours
        // whatever the room's lights are doing (like a small backlit
        // display; materials never cast light, so the room is unchanged),
        // held a touch under full white by `multiply` so it reads as a
        // pleasant screen, not a glowing sign. Frame/easel untouched.
        // The picture rides in `emission` (diffuse black), so the room's
        // ambient level can't add to or dim it -- exactly its own pixels,
        // times deskPhotoLevel.
        photoM.lightingModel = .constant
        photoM.diffuse.contents = UIColor.black
        photoM.multiply.contents = UIColor(white: deskPhotoLevel, alpha: 1)
        photoM.emission.contents = portraitImage() ?? UIColor(white: 0.85, alpha: 1)   // shown until the camera-roll photo arrives
        photoPlane.materials = [photoM]
        deskPhotoMaterial = photoM
        loadDeskPhoto(into: photoM)
        startDeskPhotoSlideshow()
        let photo = SCNNode(geometry: photoPlane)
        photo.position = SCNVector3(0, 0, 0.008)
        holder.addChildNode(photo)
        root.addChildNode(holder)
        box(0.02, 0.17, 0.012, wood, 0, 0.08, -0.06, root, 0.002)         // easel leg
        return root
    }

    // MARK: The desk photo (Oct 7)

    /// The desk photo is one RANDOM photo from the player's camera roll,
    /// picked once and kept (its PHAsset identifier is saved) so a visit
    /// starts on the photo last shown. Since Oct 7 the frame is a digital
    /// photo frame: it advances every 20 s (see Digital photo frame below). Uses the existing PhotoRollProvider (same authorization,
    /// same random picker the hallway pictures use). If that photo has since
    /// gone from the library, a new random one is picked and kept. No access
    /// or an empty library: the frame keeps the existing fallback (the
    /// player's Hallways ID portrait, else plain card). No selection UI yet.
    static let deskPhotoKey = "playerOffice.deskPhotoIdentifier"

    private static func loadDeskPhoto(into material: SCNMaterial) {
        let apply: (UIImage?) -> Void = { [weak material] image in
            guard let material, let image else { return }
            material.emission.contents = croppedToFrame(image)
        }
        if let saved = UserDefaults.standard.string(forKey: deskPhotoKey) {
            PhotoRollProvider.shared.image(forIdentifier: saved, caller: "office desk photo (kept)") { image in
                if let image {
                    apply(image)
                } else {
                    pickNewDeskPhoto(apply)
                }
            }
        } else {
            pickNewDeskPhoto(apply)
        }
    }

    /// The picture's brightness as a fraction of full self-lit white (see makePortraitFrame).
    static let deskPhotoLevel: CGFloat = 0.86
    /// Digital-frame advance interval.
    static let deskPhotoInterval: TimeInterval = 20

    /// Picks a random camera-roll photo, preferring one other than the photo
    /// currently on the desk (a couple of retries if the picker lands on it),
    /// keeps it as THE desk photo and shows it. `isCurrent` lets a stale
    /// request (superseded by a tap, or the office gone) drop its result.
    private static func pickNewDeskPhoto(attemptsLeft: Int = 3, isCurrent: @escaping () -> Bool = { true },
                                         _ apply: @escaping (UIImage?) -> Void) {
        let current = UserDefaults.standard.string(forKey: deskPhotoKey)
        PhotoRollProvider.shared.randomImageWithIdentifier(caller: "office desk photo (new)") { identifier, image in
            guard isCurrent() else { return }
            if let identifier, identifier == current, attemptsLeft > 1 {
                pickNewDeskPhoto(attemptsLeft: attemptsLeft - 1, isCurrent: isCurrent, apply)
                return
            }
            if let identifier, image != nil {
                UserDefaults.standard.set(identifier, forKey: deskPhotoKey)
            }
            diag("playerOffice.deskPhoto", ["picked": identifier != nil && image != nil, "sameAsBefore": identifier == current])
            apply(image)
        }
    }

    /// The live frame's photo material (this build).
    private static weak var deskPhotoMaterial: SCNMaterial?

    /// True for the desk photo frame (frame, photo, easel).
    static func isDeskPhoto(_ node: SCNNode) -> Bool {
        var n: SCNNode? = node
        while let current = n {
            if current.name == "playerOfficePortrait" { return true }
            if current === officeNode { return false }
            n = current.parent
        }
        return false
    }

    // MARK: Digital photo frame (Oct 7)
    //
    // One one-shot timer at a time, always 20 s after the photo now showing
    // (or after a failed attempt). Lifecycle: started by each Floor 3 build
    // (makePortraitFrame), which also cancels any previous one; each tick
    // first checks the frame still exists in a live scene (the material is
    // weak, the office node must still be attached) and stops for good if
    // not -- so leaving the floor ends it. While the app isn't active the
    // tick does no photo work and just waits for the next interval. A
    // generation counter makes any in-flight request from before a tap or
    // a rebuild drop its result. Nothing here touches the player, the
    // computer, navigation or Player History.

    private static var slideshowTimer: Timer?
    private static var slideshowGeneration = 0

    private static func startDeskPhotoSlideshow() {
        slideshowGeneration += 1
        scheduleNextDeskPhoto()
    }

    private static var deskPhotoAlive: Bool {
        deskPhotoMaterial != nil && officeNode?.parent != nil
    }

    private static func scheduleNextDeskPhoto() {
        slideshowTimer?.invalidate()
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: deskPhotoInterval, repeats: false) { _ in
            MainActor.assumeIsolated { advanceDeskPhoto(reason: "timer") }
        }
    }

    private static func stopDeskPhotoSlideshow() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
        slideshowGeneration += 1
    }

    /// Next photo now (timer tick or a tap). Restarts the 20 s from the new photo.
    private static func advanceDeskPhoto(reason: String) {
        guard deskPhotoAlive, let material = deskPhotoMaterial else {
            stopDeskPhotoSlideshow()
            diag("playerOffice.deskPhoto.slideshowStopped", ["reason": "frame gone"])
            return
        }
        slideshowTimer?.invalidate()
        slideshowGeneration += 1
        let generation = slideshowGeneration
        if reason == "timer", UIApplication.shared.applicationState != .active {
            scheduleNextDeskPhoto()                      // no photo work while backgrounded
            return
        }
        pickNewDeskPhoto(isCurrent: { generation == slideshowGeneration && deskPhotoAlive }) { [weak material] image in
            if let material, let image { material.emission.contents = croppedToFrame(image) }
            if generation == slideshowGeneration, deskPhotoAlive { scheduleNextDeskPhoto() }   // failure keeps the current image
        }
    }

    /// Oct 7: while seated at the computer, a tap on the frame advances it at
    /// once (and restarts the 20 s). No UI. If no new photo can be had, the
    /// frame stays as it is.
    static func changeDeskPhoto() {
        advanceDeskPhoto(reason: "tap")
    }

    /// Centre-crops any photo to the frame's 3:4 portrait opening (no stretching).
    private static func croppedToFrame(_ image: UIImage) -> UIImage {
        let target: CGFloat = 0.12 / 0.16
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        var crop = CGRect(origin: .zero, size: size)
        if size.width / size.height > target {
            crop.size.width = size.height * target
            crop.origin.x = (size.width - crop.width) / 2
        } else {
            crop.size.height = size.width / target
            crop.origin.y = (size.height - crop.height) / 2
        }
        return UIGraphicsImageRenderer(size: crop.size).image { _ in
            image.draw(at: CGPoint(x: -crop.origin.x, y: -crop.origin.y))
        }
    }

    private static func portraitImage() -> UIImage? {
        if let url = EmployeeID.portraitURL, let image = UIImage(contentsOfFile: url.path) { return image }
        return AdministrationIDTerminal.acceptedPhoto
    }

    /// A 1.2 m oak shelf unit, nearly empty: one binder, one archive box.
    private static func makeEmptyShelf() -> SCNNode {
        let m = AdministrationReception.material
        let box = AdministrationReception.box
        let root = SCNNode()
        root.name = "playerOfficeShelf"
        let oak = m(UIColor(red: 0.56, green: 0.42, blue: 0.27, alpha: 1), 0, 0.5, nil)
        let back = m(UIColor(red: 0.42, green: 0.3, blue: 0.19, alpha: 1), 0, 0.6, nil)
        let width: Float = 1.2, depth: Float = 0.32, height: Float = 1.8
        box(CGFloat(width), CGFloat(height), 0.02, back, 0, height / 2, -depth / 2 + 0.01, root, 0)
        for side: Float in [-1, 1] {
            box(0.03, CGFloat(height), CGFloat(depth), oak, side * (width / 2 - 0.015), height / 2, 0, root, 0)
        }
        for y: Float in [0.06, 0.48, 0.9, 1.32, 1.785] {
            box(CGFloat(width), 0.03, CGFloat(depth), oak, 0, y, 0, root, 0)
        }
        box(0.06, 0.3, 0.25, m(UIColor(red: 0.12, green: 0.2, blue: 0.3, alpha: 1), 0, 0.8, nil), -0.4, 0.915 + 0.15, 0.02, root, 0.003)
        box(0.34, 0.25, 0.28, m(UIColor(red: 0.62, green: 0.48, blue: 0.3, alpha: 1), 0, 0.95, nil), 0.25, 0.075 + 0.125, 0.0, root, 0.004)
        return root
    }

    /// One bare wire hanger on the coat rack's first hook.
    private static func makeBareHanger() -> SCNNode {
        let wire = AdministrationReception.material(UIColor(white: 0.62, alpha: 1), metal: 0.9, rough: 0.35)
        let hanger = SCNNode()
        hanger.name = "playerOfficeHanger"
        hanger.eulerAngles.y = .pi / 4
        hanger.position = SCNVector3(0, 1.48, 0.15)
        func rod(_ length: CGFloat, _ x: Float, _ y: Float, _ angle: Float) {
            let n = SCNNode(geometry: SCNCylinder(radius: 0.0025, height: length))
            n.geometry?.materials = [wire]
            n.position = SCNVector3(x, y, 0)
            n.eulerAngles.z = angle
            hanger.addChildNode(n)
        }
        rod(0.4, 0, -0.14, .pi / 2)                     // bottom bar
        rod(0.24, -0.1, -0.075, -1.0)                   // shoulders
        rod(0.24, 0.1, -0.075, 1.0)
        rod(0.06, 0, 0.0, 0)                            // neck to the hook
        return hanger
    }

    /// A small nail and the paler rectangle where a frame once hung. Face on +Z.
    private static func makeBareNail() -> SCNNode {
        let root = SCNNode()
        root.name = "playerOfficeBareNail"
        let patch = SCNNode(geometry: SCNPlane(width: 0.46, height: 0.36))
        let patchM = SCNMaterial()
        patchM.lightingModel = .physicallyBased
        patchM.diffuse.contents = UIColor(white: 1, alpha: 0.06)
        patchM.roughness.contents = 0.9
        patchM.writesToDepthBuffer = false
        patch.geometry?.materials = [patchM]
        patch.position = SCNVector3(0, -0.2, 0.0005)
        root.addChildNode(patch)
        let nail = SCNNode(geometry: SCNCylinder(radius: 0.0035, height: 0.03))
        nail.geometry?.materials = [AdministrationReception.material(UIColor(white: 0.5, alpha: 1), metal: 0.9, rough: 0.4)]
        nail.eulerAngles.x = .pi / 2
        nail.position = SCNVector3(0, 0, 0.015)
        root.addChildNode(nail)
        return root
    }
}
