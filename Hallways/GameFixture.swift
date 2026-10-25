import SceneKit
import Metal
import UIKit
import SwiftUI
import Combine   // (ObservableObject / @Published -- ToolTray; member import visibility is on)
import simd

/// Oct 1 (Decorator Games): the ten existing wall-mounted game fixtures,
/// as ONE identity so the Decorator can place/select/delete any of them.
/// Deliberately not a new game architecture: each case just names the
/// game's EXISTING per-floor dictionary (MazeStore / DefaultMazes.json key
/// `<rawValue>`), its EXISTING scene factory, and its EXISTING
/// TapNavigationController bookkeeping. The building data says which game
/// is where; the app still knows how each game works.
enum GameFixtureKind: String, CaseIterable, Identifiable {
    case ticTacToeTerminals
    case shellGameStations
    case rockPaperScissorsTerminals
    case higherLowerTerminals
    case fiveCardDrawTerminals
    case hangmanTerminals
    case simonTerminals
    case connectFourTerminals
    case checkersTerminals
    case woidleTerminals

    var id: String { rawValue }

    /// Human-readable Decorator name.
    var title: String {
        switch self {
        case .ticTacToeTerminals: return "Tic-Tac-Toe"
        case .shellGameStations: return "Shell Game"
        case .rockPaperScissorsTerminals: return "Rock Paper Scissors"
        case .higherLowerTerminals: return "Hi/Lo"
        case .fiveCardDrawTerminals: return "Five-Card Draw"
        case .hangmanTerminals: return "Hangman"
        case .simonTerminals: return "Simon"
        case .connectFourTerminals: return "Connect Four"
        case .checkersTerminals: return "Checkers"
        case .woidleTerminals: return "Wordle"
        }
    }

    /// The existing generic-removal identity (MazeStore.deleteContent).
    var editorContentKind: EditorContentKind {
        switch self {
        case .ticTacToeTerminals: return .ticTacToeTerminals
        case .shellGameStations: return .shellGameStations
        case .rockPaperScissorsTerminals: return .rockPaperScissorsTerminals
        case .higherLowerTerminals: return .higherLowerTerminals
        case .fiveCardDrawTerminals: return .fiveCardDrawTerminals
        case .hangmanTerminals: return .hangmanTerminals
        case .simonTerminals: return .simonTerminals
        case .connectFourTerminals: return .connectFourTerminals
        case .checkersTerminals: return .checkersTerminals
        case .woidleTerminals: return .woidleTerminals
        }
    }

    /// The SAME node the floor build loop makes for this game.
    func makeNode(at coord: GridCoordinate, direction: Direction, cellSize: CGFloat) -> SCNNode {
        switch self {
        case .ticTacToeTerminals: return HallwayScene.makeTicTacToeTerminalNode(at: coord, direction: direction, cellSize: cellSize)
        case .shellGameStations: return HallwayScene.makeShellGameStationNode(at: coord, direction: direction, cellSize: cellSize)
        case .rockPaperScissorsTerminals: return HallwayScene.makeRockPaperScissorsTerminalNode(at: coord, direction: direction, cellSize: cellSize)
        case .higherLowerTerminals: return HallwayScene.makeHigherLowerTerminalNode(at: coord, direction: direction, cellSize: cellSize)
        case .fiveCardDrawTerminals: return HallwayScene.makeFiveCardDrawTerminalNode(at: coord, direction: direction, cellSize: cellSize)
        case .hangmanTerminals: return HallwayScene.makeHangmanTerminalNode(at: coord, direction: direction, cellSize: cellSize)
        case .simonTerminals: return HallwayScene.makeSimonTerminalNode(at: coord, direction: direction, cellSize: cellSize)
        case .connectFourTerminals: return HallwayScene.makeConnectFourTerminalNode(at: coord, direction: direction, cellSize: cellSize)
        case .checkersTerminals: return HallwayScene.makeCheckersTerminalNode(at: coord, direction: direction, cellSize: cellSize)
        case .woidleTerminals: return HallwayScene.makeWoidleTerminalNode(at: coord, direction: direction, cellSize: cellSize)
        }
    }
}

// MARK: - Oct 16 (II) -- FLOOR 4: THE SUPPLY ROOM, and tools carried in the hands
//
// TOOLS are the first reusable gameplay system. They live on Floor 4, in a
// working maintenance supply room: hung on a pegboard and a garden board,
// lying on the workbench, sitting on steel shelves, parked on the floor --
// each in its own marked place (a painted outline on the board, a label on
// the shelf edge, a stencilled bay on the floor), so the player remembers
// where everything lives and sees at a glance what is out.
//
//   pick up    tap a tool (or its marked place): the player steps up to it,
//              and it comes away from the wall / shelf / floor
//   carry      TWO at most (an audition -- ToolBelt.capacity). Small tools are
//              held, one in each hand, low in the corners of the view, with a
//              little walk sway. Big awkward ones (stepladder, lawn mower,
//              rake, shovel, broom) FOLLOW the player through the building
//              instead, a couple of paces behind, on the floor. Held and
//              following count the same and work the same.
//              A wall fire extinguisher taken in a hallway takes a hand too.
//   the limit  a third: the tool shakes on its hook, the hands give a small
//              shake, a soft buzz, "Your hands are full." for two seconds.
//   release    SWIPE UP starting on the tool (held: in its corner of the
//              screen; following: turn round and swipe it). Fallback: press
//              and hold it (half a second). Or tap its empty place in Supplies.
//              Supplies tools go back to their own place (on Floor 4 you watch
//              them fly home; elsewhere they are back there when you next
//              look); a wall extinguisher goes back on its bracket.
//   use        only the fire extinguisher does anything yet (Floor 5's fires,
//              TapNavigationController.extinguishFire). Tool-to-target
//              interactions come later; nothing else pretends to work.
// Persistence: the carried list (SupplyTool raw values, in order) is saved at
// every change (supplies.carried.v1; cleared by Start Over). The room shows
// whatever is not carried, so nothing can be duplicated or lost.

enum SupplyTool: String, CaseIterable, Codable {
    case extinguisher, flashlight, stepladder, hammer, bucket, lighter
    case screwdriver, wrench, pliers, scissors, tape, rope
    case rake, shovel, broom, wateringCan, chainsaw, lawnMower

    /// Held in a hand, or following the player.
    enum Carry { case held, follows }
    /// Oct 16 (IV): ONE carrying system -- every tool is held, one per hand.
    /// Following tools are retired from play; FollowTrail and the follower
    /// code in ToolBelt are kept (switch this on to bring them back for the
    /// big tools). Living critters' own following (Posse, FollowLeash) is unrelated.
    static let bigToolsFollow = false
    var carry: Carry {
        switch self {
        case .stepladder, .rake, .shovel, .broom, .lawnMower: return Self.bigToolsFollow ? .follows : .held
        default: return .held
        }
    }

    /// Oct 17: a tool with an ON/OFF state. Its tray slot taps switch it (the
    /// first tap selects it, switched on); the state lives in
    /// ToolTray.switchedOn and anything it drives (FlashlightBeam) reads that.
    /// Add a case here to make another tool switchable -- no tray UI changes.
    var isToggleable: Bool {
        switch self {
        case .flashlight: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .extinguisher: return "FIRE EXTINGUISHER"
        case .wateringCan: return "WATERING CAN"
        case .lawnMower: return "MOWER"
        case .stepladder: return "LADDER"
        case .tape: return "TAPE"
        default: return rawValue.uppercased()
        }
    }

    /// The object, at real size (metres): upright, standing on y = 0, centred.
    func makeModel() -> SCNNode {
        let m: SCNNode
        switch self {
        case .extinguisher: m = SupplyModels.extinguisher()
        case .flashlight: m = SupplyModels.flashlight()
        case .stepladder: m = SupplyModels.scaled(SupplyModels.stepladder(), 1.25)
        case .hammer: m = SupplyModels.hammer()
        case .bucket: m = SupplyModels.scaled(SupplyModels.bucket(), 1.3)
        case .lighter: m = SupplyModels.lighter()
        case .screwdriver: m = SupplyModels.screwdriver()
        case .wrench: m = SupplyModels.wrench()
        case .pliers: m = SupplyModels.pliers()
        case .scissors: m = SupplyModels.scissors()
        case .tape: m = SupplyModels.tape()
        case .rope: m = SupplyModels.rope()
        case .rake: m = SupplyModels.rake()
        case .shovel: m = SupplyModels.shovel()
        case .broom: m = SupplyModels.broom()
        case .wateringCan: m = SupplyModels.wateringCan()
        case .chainsaw: m = SupplyModels.chainsaw()
        case .lawnMower: m = SupplyModels.lawnMower()
        }
        m.name = "supplyModel_\(rawValue)"
        return m
    }

    /// How it sits in a hand (right hand; the left mirrors it).
    /// scale: of the real-size model. euler: turned from upright (x pitch,
    /// y yaw). lean: the top tipped in toward the middle of the view.
    /// top: where its top edge sits, as a fraction of the view height up
    /// from the bottom. inset: its middle, as a fraction of the half-width
    /// out from the centre line.
    struct HeldPose { let scale: Float; let euler: SCNVector3; let lean: Float; let top: Float; let inset: Float }
    var heldPose: HeldPose {
        switch self {
        case .extinguisher: return HeldPose(scale: 0.42, euler: SCNVector3(0.08, 0.55, 0), lean: 0.1, top: 0.36, inset: 0.6)
        case .flashlight: return HeldPose(scale: 1, euler: SCNVector3(-Float.pi / 2 + 0.22, 0.3, 0), lean: 0, top: 0.24, inset: 0.52)
        case .hammer: return HeldPose(scale: 1, euler: SCNVector3(-0.22, Float.pi / 2, 0), lean: 0.22, top: 0.4, inset: 0.58)
        case .screwdriver: return HeldPose(scale: 1, euler: SCNVector3(Float.pi / 2 - 0.2, 0.3, 0), lean: 0, top: 0.22, inset: 0.52)
        case .wrench: return HeldPose(scale: 1, euler: SCNVector3(-0.3, 0.2, 0), lean: 0.3, top: 0.36, inset: 0.6)
        case .pliers: return HeldPose(scale: 1, euler: SCNVector3(-0.3, 0.25, 0), lean: 0.28, top: 0.35, inset: 0.6)
        case .scissors: return HeldPose(scale: 1.05, euler: SCNVector3(Float.pi / 2 - 0.15, 0.25, 0), lean: 0, top: 0.22, inset: 0.52)
        case .tape: return HeldPose(scale: 1, euler: SCNVector3(0.2, 0.6, 0), lean: 0.1, top: 0.28, inset: 0.58)
        case .rope: return HeldPose(scale: 0.6, euler: SCNVector3(-1.15, 0.3, 0), lean: 0.1, top: 0.33, inset: 0.6)
        case .bucket: return HeldPose(scale: 0.55, euler: SCNVector3(0.35, 0, 0), lean: 0.05, top: 0.22, inset: 0.56)
        case .lighter: return HeldPose(scale: 1.05, euler: SCNVector3(-0.1, 0.45, 0), lean: 0.1, top: 0.34, inset: 0.58)
        case .wateringCan: return HeldPose(scale: 0.7, euler: SCNVector3(0.12, Float.pi / 2 + 0.35, 0), lean: 0, top: 0.3, inset: 0.6)
        case .chainsaw: return HeldPose(scale: 0.7, euler: SCNVector3(-0.08, Float.pi / 2 + 0.18, 0), lean: 0.05, top: 0.3, inset: 0.6)
        // Oct 16 (IV): the big ones, held too -- carried small (a toy-scale hold,
        // like the extinguisher), angled so the part you know them by shows:
        // heads up for the long-handled tools, the ladder's steps, the mower's deck.
        case .stepladder: return HeldPose(scale: 0.27, euler: SCNVector3(-0.18, 0.55, 0), lean: 0.14, top: 0.38, inset: 0.6)
        case .rake: return HeldPose(scale: 0.23, euler: SCNVector3(-0.3, 0.25, Float.pi), lean: 0.32, top: 0.42, inset: 0.56)
        case .shovel: return HeldPose(scale: 0.25, euler: SCNVector3(-0.3, 0.6, Float.pi), lean: 0.3, top: 0.42, inset: 0.56)
        case .broom: return HeldPose(scale: 0.23, euler: SCNVector3(-0.3, 0.2, Float.pi), lean: 0.32, top: 0.42, inset: 0.56)
        case .lawnMower: return HeldPose(scale: 0.29, euler: SCNVector3(0.3, 0.35, 0), lean: 0.05, top: 0.3, inset: 0.6)
        }
    }

    /// How a follower moves: rolls on its wheels, waddles on its legs, or hops on its head.
    enum Gait: Int { case roll = 0, waddle = 1, hop = 2 }
    var gait: Gait {
        switch self {
        case .lawnMower: return .roll
        case .stepladder: return .waddle
        default: return .hop
        }
    }
}

/// Real-looking objects from SceneKit primitives, at real size.
enum SupplyModels {
    static func mat(_ color: UIColor, metal: CGFloat = 0, rough: CGFloat = 0.5, glow: UIColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metal
        m.roughness.contents = rough
        if let glow { m.emission.contents = glow }
        return m
    }

    static let chrome = mat(UIColor(white: 0.86, alpha: 1), metal: 1, rough: 0.16)
    static let aluminium = mat(UIColor(white: 0.78, alpha: 1), metal: 0.9, rough: 0.35)
    static let black = mat(UIColor(white: 0.04, alpha: 1), rough: 0.45)
    static let rubber = mat(UIColor(white: 0.07, alpha: 1), rough: 0.85)
    static let wood = mat(UIColor(red: 0.58, green: 0.36, blue: 0.18, alpha: 1), rough: 0.6)
    static let paleWood = mat(UIColor(red: 0.78, green: 0.62, blue: 0.4, alpha: 1), rough: 0.7)
    static let steel = mat(UIColor(white: 0.55, alpha: 1), metal: 0.95, rough: 0.28)
    static let darkSteel = mat(UIColor(white: 0.3, alpha: 1), metal: 0.9, rough: 0.4)
    static let orange = mat(UIColor(red: 0.95, green: 0.45, blue: 0.08, alpha: 1), rough: 0.5)
    static let red = mat(UIColor(red: 0.75, green: 0.08, blue: 0.06, alpha: 1), rough: 0.45)
    static let yellow = mat(UIColor(red: 0.98, green: 0.78, blue: 0.1, alpha: 1), rough: 0.5)
    static let green = mat(UIColor(red: 0.12, green: 0.42, blue: 0.2, alpha: 1), metal: 0.2, rough: 0.4)
    static let galvanized = mat(UIColor(red: 0.70, green: 0.72, blue: 0.74, alpha: 1), metal: 0.85, rough: 0.42)

    @discardableResult
    static func part(_ g: SCNGeometry, _ m: SCNMaterial, in parent: SCNNode, at p: SCNVector3 = SCNVector3Zero,
                     euler: SCNVector3 = SCNVector3Zero) -> SCNNode {
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.position = p
        n.eulerAngles = euler
        parent.addChildNode(n)
        return n
    }

    @discardableResult
    static func box(_ w: Float, _ h: Float, _ l: Float, _ m: SCNMaterial, in parent: SCNNode, at p: SCNVector3,
                    euler: SCNVector3 = SCNVector3Zero, chamfer: Float = 0.003) -> SCNNode {
        part(SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(l), chamferRadius: CGFloat(chamfer)), m,
             in: parent, at: p, euler: euler)
    }

    @discardableResult
    static func rod(_ r: Float, _ h: Float, _ m: SCNMaterial, in parent: SCNNode, at p: SCNVector3,
                    euler: SCNVector3 = SCNVector3Zero) -> SCNNode {
        part(SCNCylinder(radius: CGFloat(r), height: CGFloat(h)), m, in: parent, at: p, euler: euler)
    }

    /// A cylinder from `a` to `b`.
    @discardableResult
    static func strut(from a: SCNVector3, to b: SCNVector3, radius r: Float, _ m: SCNMaterial, in parent: SCNNode) -> SCNNode {
        let d = SIMD3<Float>(b.x - a.x, b.y - a.y, b.z - a.z)
        let len = simd_length(d)
        let n = rod(r, max(0.001, len), m, in: parent, at: SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2))
        if len > 1e-5 {
            let dir = d / len
            let up = SIMD3<Float>(0, 1, 0)
            let axis = simd_cross(up, dir)
            let s = simd_length(axis)
            if s > 1e-5 {
                n.simdOrientation = simd_quatf(angle: atan2(s, simd_dot(up, dir)), axis: axis / s)
            } else if dir.y < 0 {
                n.simdOrientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
            }
        }
        return n
    }

    static func scaled(_ model: SCNNode, _ k: Float) -> SCNNode {
        let holder = SCNNode()
        model.scale = SCNVector3(k, k, k)
        holder.addChildNode(model)
        return holder
    }

    /// The building's own wall extinguisher (HallwayScene), without its wall
    /// bracket, standing on y = 0.
    static func extinguisher() -> SCNNode {
        let node = HallwayScene.makeFireExtinguisherNode(at: GridCoordinate(row: 0, col: 0), direction: .north, cellSize: 0)
        for child in node.childNodes where child.geometry is SCNBox { child.removeFromParentNode() }   // (the bracket)
        node.name = "supplyExtinguisherModel"                 // (never mistaken for a wall extinguisher)
        node.position = SCNVector3Zero
        node.eulerAngles = SCNVector3Zero
        let (lo, hi) = node.boundingBox
        node.position = SCNVector3(-(lo.x + hi.x) / 2, -lo.y, -(lo.z + hi.z) / 2)
        let holder = SCNNode()
        holder.addChildNode(node)
        return holder
    }

    static func flashlight() -> SCNNode {
        let root = SCNNode()
        let lens = mat(UIColor(red: 0.85, green: 0.92, blue: 1, alpha: 1), metal: 0.2, rough: 0.05)
        let yellowBody = mat(UIColor(red: 0.95, green: 0.72, blue: 0.08, alpha: 1), rough: 0.4)
        rod(0.032, 0.24, yellowBody, in: root, at: SCNVector3(0, 0.145, 0))
        rod(0.035, 0.025, rubber, in: root, at: SCNVector3(0, 0.0125, 0))                                       // tail cap
        part(SCNCone(topRadius: 0.052, bottomRadius: 0.034, height: 0.075), black, in: root, at: SCNVector3(0, 0.3025, 0))
        rod(0.047, 0.006, lens, in: root, at: SCNVector3(0, 0.343, 0))
        box(0.018, 0.034, 0.012, rubber, in: root, at: SCNVector3(0, 0.22, 0.033))                                // the switch
        for y: Float in [0.05, 0.07, 0.09] {
            part(SCNTorus(ringRadius: 0.032, pipeRadius: 0.0035), rubber, in: root, at: SCNVector3(0, y, 0))      // grip
        }
        return root
    }

    static func stepladder() -> SCNNode {
        let root = SCNNode()
        let lean: Float = atan(0.14 / 0.95)
        for x: Float in [-0.17, 0.17] {
            box(0.035, 0.96, 0.022, aluminium, in: root, at: SCNVector3(x, 0.48, 0.09), euler: SCNVector3(-lean, 0, 0))
            box(0.03, 0.96, 0.02, aluminium, in: root, at: SCNVector3(x, 0.48, -0.09), euler: SCNVector3(lean, 0, 0))
            box(0.04, 0.03, 0.05, rubber, in: root, at: SCNVector3(x, 0.015, 0.16), chamfer: 0.008)
            box(0.04, 0.03, 0.05, rubber, in: root, at: SCNVector3(x, 0.015, -0.16), chamfer: 0.008)
        }
        for (i, y) in [Float(0.26), 0.5, 0.74].enumerated() {
            let z = 0.16 - y / 0.95 * 0.14 - 0.025
            box(0.34, 0.022, 0.085 - Float(i) * 0.008, aluminium, in: root, at: SCNVector3(0, y, z), chamfer: 0.005)
        }
        box(0.4, 0.035, 0.17, orange, in: root, at: SCNVector3(0, 0.965, 0), chamfer: 0.01)                    // top cap
        rod(0.006, 0.26, steel, in: root, at: SCNVector3(-0.19, 0.4, 0), euler: SCNVector3(Float.pi / 2, 0, 0))   // spreaders
        rod(0.006, 0.26, steel, in: root, at: SCNVector3(0.19, 0.4, 0), euler: SCNVector3(Float.pi / 2, 0, 0))
        return root
    }

    static func hammer() -> SCNNode {
        let root = SCNNode()
        rod(0.016, 0.31, wood, in: root, at: SCNVector3(0, 0.155, 0))
        rod(0.02, 0.11, rubber, in: root, at: SCNVector3(0, 0.06, 0))                                           // grip
        box(0.15, 0.036, 0.036, steel, in: root, at: SCNVector3(0.01, 0.325, 0), chamfer: 0.006)
        rod(0.021, 0.03, steel, in: root, at: SCNVector3(0.095, 0.325, 0), euler: SCNVector3(0, 0, Float.pi / 2))  // face
        for dz: Float in [-0.009, 0.009] {                                                                       // claw
            box(0.075, 0.012, 0.012, steel, in: root, at: SCNVector3(-0.09, 0.31, dz), euler: SCNVector3(0, 0, -0.45))
        }
        return root
    }

    static func bucket() -> SCNNode {
        let root = SCNNode()
        let pail = SCNCone(topRadius: 0.13, bottomRadius: 0.105, height: 0.22)
        pail.radialSegmentCount = 36
        part(pail, galvanized, in: root, at: SCNVector3(0, 0.11, 0))
        rod(0.122, 0.004, mat(UIColor(white: 0.18, alpha: 1), metal: 0.6, rough: 0.6), in: root, at: SCNVector3(0, 0.205, 0))
        part(SCNTorus(ringRadius: 0.13, pipeRadius: 0.0065), galvanized, in: root, at: SCNVector3(0, 0.22, 0))   // rim
        part(SCNTorus(ringRadius: 0.118, pipeRadius: 0.004), galvanized, in: root, at: SCNVector3(0, 0.08, 0))   // rib
        part(SCNTorus(ringRadius: 0.135, pipeRadius: 0.0035), steel, in: root, at: SCNVector3(0, 0.215, 0),
             euler: SCNVector3(Float.pi / 2, 0, 0.35))                                                           // the bail
        for x: Float in [-0.13, 0.13] { part(SCNSphere(radius: 0.012), galvanized, in: root, at: SCNVector3(x, 0.2, 0)) }
        return root
    }

    static func lighter() -> SCNNode {
        let root = SCNNode()
        let brushed = mat(UIColor(white: 0.8, alpha: 1), metal: 1, rough: 0.28)
        box(0.11, 0.15, 0.045, brushed, in: root, at: SCNVector3(0, 0.075, 0), chamfer: 0.012)
        box(0.056, 0.05, 0.036, chrome, in: root, at: SCNVector3(-0.012, 0.175, 0), chamfer: 0.004)            // chimney
        for col in 0..<3 { for row in 0..<2 {
            box(0.007, 0.007, 0.004, black, in: root, at: SCNVector3(-0.03 + Float(col) * 0.018, 0.168 + Float(row) * 0.016, 0.0185), chamfer: 0.001)
        } }
        rod(0.012, 0.03, mat(UIColor(white: 0.25, alpha: 1), metal: 0.9, rough: 0.5), in: root, at: SCNVector3(0.03, 0.19, 0),
            euler: SCNVector3(Float.pi / 2, 0, 0))                                                               // flint wheel
        box(0.006, 0.014, 0.006, mat(UIColor(white: 0.92, alpha: 1)), in: root, at: SCNVector3(-0.012, 0.205, 0), chamfer: 0.002)
        let hinge = SCNNode()                                                                                    // lid, swung open
        hinge.position = SCNVector3(0.055, 0.15, 0)
        hinge.eulerAngles.z = -1.95
        root.addChildNode(hinge)
        box(0.11, 0.055, 0.045, brushed, in: hinge, at: SCNVector3(-0.055, 0.0275, 0), chamfer: 0.012)
        return root
    }

    static func screwdriver() -> SCNNode {
        let root = SCNNode()
        let handle = mat(UIColor(red: 0.85, green: 0.1, blue: 0.08, alpha: 1), metal: 0.05, rough: 0.25)
        let stripe = mat(UIColor(red: 0.98, green: 0.82, blue: 0.1, alpha: 1), rough: 0.3)
        box(0.007, 0.022, 0.0022, steel, in: root, at: SCNVector3(0, 0.011, 0), chamfer: 0.0005)                // the blade tip
        rod(0.0038, 0.14, chrome, in: root, at: SCNVector3(0, 0.09, 0))
        rod(0.009, 0.012, chrome, in: root, at: SCNVector3(0, 0.166, 0))                                        // ferrule
        rod(0.016, 0.105, handle, in: root, at: SCNVector3(0, 0.2245, 0))
        for y: Float in [0.19, 0.212, 0.234, 0.256] {
            part(SCNTorus(ringRadius: 0.016, pipeRadius: 0.0022), stripe, in: root, at: SCNVector3(0, y, 0))
        }
        let cap = part(SCNSphere(radius: 0.016), handle, in: root, at: SCNVector3(0, 0.277, 0))
        cap.scale = SCNVector3(1, 0.5, 1)
        return root
    }

    static func wrench() -> SCNNode {
        let root = SCNNode()
        box(0.022, 0.2, 0.007, chrome, in: root, at: SCNVector3(0, 0.145, 0), chamfer: 0.003)                   // shaft
        part(SCNTorus(ringRadius: 0.019, pipeRadius: 0.0065), chrome, in: root, at: SCNVector3(0, 0.03, 0),
             euler: SCNVector3(Float.pi / 2, 0, 0))                                                              // ring end
        box(0.05, 0.02, 0.008, chrome, in: root, at: SCNVector3(0, 0.25, 0), chamfer: 0.004)                    // open end
        for side: Float in [-1, 1] {
            box(0.013, 0.038, 0.008, chrome, in: root, at: SCNVector3(side * 0.018, 0.272, 0), euler: SCNVector3(0, 0, -side * 0.22), chamfer: 0.003)
        }
        return root
    }

    static func pliers() -> SCNNode {
        let root = SCNNode()
        let grip = mat(UIColor(red: 0.12, green: 0.32, blue: 0.75, alpha: 1), rough: 0.6)
        for side: Float in [-1, 1] {
            box(0.016, 0.15, 0.01, grip, in: root, at: SCNVector3(side * 0.02, 0.085, 0), euler: SCNVector3(0, 0, side * 0.13), chamfer: 0.005)
            box(0.011, 0.065, 0.009, steel, in: root, at: SCNVector3(side * 0.005, 0.2, 0), euler: SCNVector3(0, 0, -side * 0.06), chamfer: 0.003)
        }
        rod(0.011, 0.016, darkSteel, in: root, at: SCNVector3(0, 0.162, 0), euler: SCNVector3(Float.pi / 2, 0, 0))   // pivot
        return root
    }

    static func scissors() -> SCNNode {
        let root = SCNNode()
        let plastic = mat(UIColor(red: 0.98, green: 0.45, blue: 0.08, alpha: 1), rough: 0.35)
        for side: Float in [-1, 1] {
            part(SCNTorus(ringRadius: 0.024, pipeRadius: 0.0065), plastic, in: root, at: SCNVector3(side * 0.024, 0.205, 0),
                 euler: SCNVector3(Float.pi / 2, 0, 0))
            box(0.011, 0.05, 0.006, plastic, in: root, at: SCNVector3(side * 0.012, 0.162, 0), euler: SCNVector3(0, 0, -side * 0.35), chamfer: 0.003)
            box(0.012, 0.13, 0.003, chrome, in: root, at: SCNVector3(side * 0.004, 0.075, side * 0.002), euler: SCNVector3(0, 0, side * 0.06), chamfer: 0.001)
        }
        rod(0.005, 0.012, darkSteel, in: root, at: SCNVector3(0, 0.138, 0), euler: SCNVector3(Float.pi / 2, 0, 0))   // pivot screw
        return root
    }

    static func tape() -> SCNNode {
        let root = SCNNode()
        let duct = mat(UIColor(white: 0.62, alpha: 1), metal: 0.35, rough: 0.55)
        let core = mat(UIColor(red: 0.62, green: 0.47, blue: 0.3, alpha: 1), rough: 0.9)
        part(SCNTube(innerRadius: 0.039, outerRadius: 0.065, height: 0.05), duct, in: root, at: SCNVector3(0, 0.065, 0),
             euler: SCNVector3(Float.pi / 2, 0, 0))
        part(SCNTube(innerRadius: 0.035, outerRadius: 0.039, height: 0.05), core, in: root, at: SCNVector3(0, 0.065, 0),
             euler: SCNVector3(Float.pi / 2, 0, 0))
        box(0.03, 0.002, 0.05, duct, in: root, at: SCNVector3(0.07, 0.03, 0), euler: SCNVector3(0, 0, 1.1), chamfer: 0)   // the loose end
        return root
    }

    static func rope() -> SCNNode {
        let root = SCNNode()
        let hemp = mat(UIColor(red: 0.8, green: 0.68, blue: 0.45, alpha: 1), rough: 0.95)
        for i in 0..<5 {
            let t = part(SCNTorus(ringRadius: CGFloat(0.12 - Float(i % 2) * 0.008), pipeRadius: 0.011), hemp, in: root,
                         at: SCNVector3(Float(i % 3) * 0.006 - 0.006, 0.011 + Float(i) * 0.019, Float(i % 2) * 0.006),
                         euler: SCNVector3(Float(i % 2) * 0.05 - 0.025, 0, Float(i % 3) * 0.03 - 0.03))
            t.name = nil
        }
        strut(from: SCNVector3(0.11, 0.09, 0.02), to: SCNVector3(0.2, 0.012, 0.09), radius: 0.011, hemp, in: root)  // the end
        return root
    }

    static func rake() -> SCNNode {
        let root = SCNNode()
        let head = mat(UIColor(red: 0.16, green: 0.4, blue: 0.22, alpha: 1), metal: 0.6, rough: 0.4)
        rod(0.016, 1.42, paleWood, in: root, at: SCNVector3(0, 0.33 + 0.71, 0))
        rod(0.02, 0.06, steel, in: root, at: SCNVector3(0, 0.33, 0))                                             // ferrule
        box(0.4, 0.025, 0.03, head, in: root, at: SCNVector3(0, 0.09, 0), chamfer: 0.004)                        // crossbar
        for i in 0..<13 {
            let x = -0.18 + Float(i) * 0.03
            rod(0.004, 0.085, head, in: root, at: SCNVector3(x, 0.043, 0.006), euler: SCNVector3(0.12, 0, 0))     // tines
        }
        for side: Float in [-1, 1] {                                                                             // the bows
            strut(from: SCNVector3(side * 0.19, 0.1, 0), to: SCNVector3(side * 0.02, 0.31, 0), radius: 0.006, head, in: root)
        }
        return root
    }

    static func shovel() -> SCNNode {
        let root = SCNNode()
        let blade = mat(UIColor(red: 0.2, green: 0.22, blue: 0.24, alpha: 1), metal: 0.8, rough: 0.45)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: -0.115, y: 0.31)); path.addLine(to: CGPoint(x: 0.115, y: 0.31))
        path.addLine(to: CGPoint(x: 0.115, y: 0.09)); path.addQuadCurve(to: CGPoint(x: 0, y: 0), controlPoint: CGPoint(x: 0.1, y: 0.02))
        path.addQuadCurve(to: CGPoint(x: -0.115, y: 0.09), controlPoint: CGPoint(x: -0.1, y: 0.02)); path.close()
        let shape = SCNShape(path: path, extrusionDepth: 0.008)
        shape.chamferRadius = 0
        part(shape, blade, in: root, at: SCNVector3(0, 0, 0), euler: SCNVector3(0.08, 0, 0))
        part(SCNCone(topRadius: 0.019, bottomRadius: 0.034, height: 0.1), blade, in: root, at: SCNVector3(0, 0.355, 0))  // socket
        rod(0.017, 0.95, paleWood, in: root, at: SCNVector3(0, 0.4 + 0.475, 0))
        part(SCNTorus(ringRadius: 0.055, pipeRadius: 0.012), black, in: root, at: SCNVector3(0, 1.38, 0),
             euler: SCNVector3(Float.pi / 2, 0, 0))                                                              // D-grip
        rod(0.014, 0.1, paleWood, in: root, at: SCNVector3(0, 1.405, 0), euler: SCNVector3(0, 0, Float.pi / 2))
        return root
    }

    static func broom() -> SCNNode {
        let root = SCNNode()
        let straw = mat(UIColor(red: 0.86, green: 0.72, blue: 0.38, alpha: 1), rough: 0.95)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: -0.17, y: 0)); path.addLine(to: CGPoint(x: 0.17, y: 0))
        path.addQuadCurve(to: CGPoint(x: 0.06, y: 0.42), controlPoint: CGPoint(x: 0.15, y: 0.25))
        path.addLine(to: CGPoint(x: -0.06, y: 0.42))
        path.addQuadCurve(to: CGPoint(x: -0.17, y: 0), controlPoint: CGPoint(x: -0.15, y: 0.25)); path.close()
        let head = SCNShape(path: path, extrusionDepth: 0.07)
        head.chamferRadius = 0
        part(head, straw, in: root)
        for y: Float in [0.28, 0.32, 0.36] {
            let w = 0.12 + (0.34 - 0.12) * (1 - y / 0.42) * 0.6
            box(w, 0.011, 0.074, red, in: root, at: SCNVector3(0, y, 0), chamfer: 0.002)                          // stitching
        }
        box(0.11, 0.04, 0.06, steel, in: root, at: SCNVector3(0, 0.43, 0), chamfer: 0.006)                         // wire cap
        rod(0.014, 1.08, red, in: root, at: SCNVector3(0, 0.45 + 0.54, 0))
        part(SCNSphere(radius: 0.016), red, in: root, at: SCNVector3(0, 1.53, 0))
        return root
    }

    static func wateringCan() -> SCNNode {
        let root = SCNNode()
        let enamel = mat(UIColor(red: 0.18, green: 0.5, blue: 0.3, alpha: 1), metal: 0.3, rough: 0.35)
        let body = SCNCylinder(radius: 0.09, height: 0.19)
        body.radialSegmentCount = 32
        part(body, enamel, in: root, at: SCNVector3(0, 0.095, 0))
        part(SCNTorus(ringRadius: 0.088, pipeRadius: 0.006), enamel, in: root, at: SCNVector3(0, 0.19, 0))         // rolled rim
        rod(0.084, 0.004, mat(UIColor(white: 0.12, alpha: 1), rough: 0.7), in: root, at: SCNVector3(0, 0.187, 0))  // opening
        part(SCNTorus(ringRadius: 0.08, pipeRadius: 0.009), enamel, in: root, at: SCNVector3(-0.01, 0.19, 0),
             euler: SCNVector3(Float.pi / 2, 0, 0))                                                              // top handle
        let start = SCNVector3(0.075, 0.05, 0), end = SCNVector3(0.27, 0.285, 0)
        strut(from: start, to: end, radius: 0.012, enamel, in: root)                                             // spout
        let rose = part(SCNCone(topRadius: 0.03, bottomRadius: 0.013, height: 0.045), enamel, in: root,
                        at: SCNVector3(0.285, 0.302, 0))
        rose.eulerAngles.z = -0.69
        return root
    }

    static func chainsaw() -> SCNNode {
        let root = SCNNode()
        let housing = mat(UIColor(red: 0.96, green: 0.42, blue: 0.06, alpha: 1), rough: 0.4)
        let charcoal = mat(UIColor(white: 0.16, alpha: 1), rough: 0.6)
        box(0.3, 0.19, 0.12, housing, in: root, at: SCNVector3(0, 0.115, 0), chamfer: 0.03)
        box(0.13, 0.1, 0.126, charcoal, in: root, at: SCNVector3(-0.04, 0.13, 0), chamfer: 0.02)                  // engine cover
        part(SCNTorus(ringRadius: 0.058, pipeRadius: 0.012), black, in: root, at: SCNVector3(-0.2, 0.14, 0),
             euler: SCNVector3(Float.pi / 2, 0, 0))                                                              // rear handle
        part(SCNTorus(ringRadius: 0.1, pipeRadius: 0.012), black, in: root, at: SCNVector3(0.06, 0.13, 0),
             euler: SCNVector3(0, 0, Float.pi / 2))                                                              // wrap handle
        box(0.43, 0.075, 0.008, charcoal, in: root, at: SCNVector3(0.36, 0.11, 0), chamfer: 0.003)                // chain
        box(0.42, 0.06, 0.012, steel, in: root, at: SCNVector3(0.36, 0.11, 0), chamfer: 0.003)                    // bar
        rod(0.031, 0.012, steel, in: root, at: SCNVector3(0.57, 0.11, 0), euler: SCNVector3(Float.pi / 2, 0, 0))   // bar nose
        box(0.015, 0.11, 0.13, black, in: root, at: SCNVector3(0.17, 0.2, 0), chamfer: 0.004)                     // hand guard
        box(0.04, 0.02, 0.02, black, in: root, at: SCNVector3(-0.1, 0.22, 0.055), chamfer: 0.006)                 // pull cord
        return root
    }

    static func lawnMower() -> SCNNode {
        let root = SCNNode()
        let deck = mat(UIColor(red: 0.78, green: 0.1, blue: 0.08, alpha: 1), metal: 0.3, rough: 0.35)
        box(0.52, 0.12, 0.56, deck, in: root, at: SCNVector3(0, 0.16, 0), chamfer: 0.04)
        box(0.54, 0.05, 0.58, mat(UIColor(white: 0.18, alpha: 1), metal: 0.5, rough: 0.5), in: root, at: SCNVector3(0, 0.105, 0), chamfer: 0.01)
        for x: Float in [-0.29, 0.29] { for z: Float in [-0.22, 0.22] {
            rod(0.09, 0.045, rubber, in: root, at: SCNVector3(x, 0.09, z), euler: SCNVector3(0, 0, Float.pi / 2))
            rod(0.045, 0.05, steel, in: root, at: SCNVector3(x, 0.09, z), euler: SCNVector3(0, 0, Float.pi / 2))
        } }
        rod(0.13, 0.17, black, in: root, at: SCNVector3(0, 0.305, -0.03))                                         // engine
        rod(0.145, 0.03, deck, in: root, at: SCNVector3(0, 0.4, -0.03))                                           // shroud
        rod(0.022, 0.03, yellow, in: root, at: SCNVector3(0.08, 0.43, -0.03))                                     // fuel cap
        box(0.12, 0.07, 0.07, black, in: root, at: SCNVector3(-0.06, 0.37, -0.15), chamfer: 0.01)                 // air filter
        box(0.4, 0.22, 0.26, mat(UIColor(red: 0.12, green: 0.2, blue: 0.13, alpha: 1), rough: 0.95), in: root,
            at: SCNVector3(0, 0.26, 0.42), chamfer: 0.04)                                                        // grass bag
        for x: Float in [-0.21, 0.21] {
            strut(from: SCNVector3(x, 0.2, 0.26), to: SCNVector3(x, 0.96, 0.62), radius: 0.012, black, in: root)   // handles
        }
        rod(0.014, 0.44, black, in: root, at: SCNVector3(0, 0.96, 0.62), euler: SCNVector3(0, 0, Float.pi / 2))     // the bar
        rod(0.019, 0.3, rubber, in: root, at: SCNVector3(0, 0.96, 0.62), euler: SCNVector3(0, 0, Float.pi / 2))    // foam grip
        return root
    }
}

/// Floor 4: the maintenance supply room -- architecture, clutter, and where each tool lives.
enum SuppliesShowroom {
    static let floor = 4
    /// Oct 25 (PP 3, the musical redesign): the supply room is RETIRED as a mission --
    /// its tools can't be taken (Supplies.toolTapped), nothing is awarded, nobody
    /// guides the player here. The room, its fixtures and its registration as a
    /// residents' room stay until Floor 4 is rebuilt as Recording A. (false: as before.)
    static let retired = true
    /// The room (3 x 3 cells) and the short way in from the elevator.
    static let roomCells: Set<GridCoordinate> = Set((9...11).flatMap { r in (8...10).map { GridCoordinate(row: r, col: $0) } })
    static let foyerCell = GridCoordinate(row: 10, col: 7)
    static let floorY: Float = 0                          // (the floor slabs' top)
    /// How far from a wall the player stands to take from it (just outside the walk's 1.4 m wall clearance).
    static let standOff: Float = 1.5

    enum Wall { case north, south, east, west }

    /// A tool's home: on which wall, how far along it (metres from the room's
    /// centre line, to the right as you face the wall), and how it sits.
    struct Place {
        enum Mount {
            case hang(y: Float)                 // centred at height y, its back against the board
            case stand(y: Float, out: Float)    // standing on a surface at height y, its middle `out` from the wall
            case native(out: Float)             // the model's own frame (the wall extinguisher: its bracket height)
        }
        let wall: Wall
        let along: Float
        let mount: Mount
        let euler: SCNVector3
        var marker: Marker = .none
        enum Marker { case none, outline, shelfLabel(y: Float, out: Float), floorBay }
    }

    static func place(_ tool: SupplyTool) -> Place {
        let up = SCNVector3Zero, headUp = SCNVector3(0, 0, Float.pi)
        switch tool {
        // The pegboard over the workbench (east wall, facing the door).
        case .hammer: return Place(wall: .east, along: -1.5, mount: .hang(y: 1.82), euler: up, marker: .outline)
        case .wrench: return Place(wall: .east, along: -0.9, mount: .hang(y: 1.82), euler: up, marker: .outline)
        case .screwdriver: return Place(wall: .east, along: -0.3, mount: .hang(y: 1.82), euler: up, marker: .outline)
        case .pliers: return Place(wall: .east, along: 0.3, mount: .hang(y: 1.82), euler: up, marker: .outline)
        case .scissors: return Place(wall: .east, along: 0.9, mount: .hang(y: 1.82), euler: up, marker: .outline)
        case .tape: return Place(wall: .east, along: 1.5, mount: .hang(y: 1.86), euler: up, marker: .outline)
        // On the workbench.
        case .flashlight: return Place(wall: .east, along: -1.25, mount: .stand(y: 0.925, out: 0.36),
                                       euler: SCNVector3(0, 0.25, -Float.pi / 2), marker: .shelfLabel(y: 0.9, out: 0.725))
        case .lighter: return Place(wall: .east, along: -0.5, mount: .stand(y: 0.925, out: 0.34), euler: SCNVector3(0, -0.5, 0),
                                    marker: .shelfLabel(y: 0.9, out: 0.725))
        case .rope: return Place(wall: .east, along: 1.3, mount: .stand(y: 0.925, out: 0.36), euler: up,
                                 marker: .shelfLabel(y: 0.9, out: 0.725))
        // The garden board (north wall, left as you come in): long handles, heads up.
        case .rake: return Place(wall: .north, along: -4.3, mount: .hang(y: 1.42), euler: headUp, marker: .outline)
        case .shovel: return Place(wall: .north, along: -3.55, mount: .hang(y: 1.42), euler: headUp, marker: .outline)
        case .broom: return Place(wall: .north, along: -2.8, mount: .hang(y: 1.42), euler: headUp, marker: .outline)
        // The steel shelving (north wall, right of the garden board).
        case .bucket: return Place(wall: .north, along: -1.05, mount: .stand(y: 0.645, out: 0.3), euler: up,
                                   marker: .shelfLabel(y: 0.62, out: 0.575))
        case .wateringCan: return Place(wall: .north, along: -0.35, mount: .stand(y: 0.645, out: 0.3), euler: SCNVector3(0, 0.3, 0),
                                        marker: .shelfLabel(y: 0.62, out: 0.575))
        case .chainsaw: return Place(wall: .north, along: 1.0, mount: .stand(y: 1.145, out: 0.3), euler: SCNVector3(0, -0.15, 0),
                                     marker: .shelfLabel(y: 1.12, out: 0.575))
        // Parked against the south wall, each in a stencilled floor bay.
        case .stepladder: return Place(wall: .south, along: 3.75, mount: .stand(y: 0, out: 0.42), euler: up, marker: .floorBay)
        case .lawnMower: return Place(wall: .south, along: 1.75, mount: .stand(y: 0, out: 0.66), euler: SCNVector3(0, Float.pi, 0),
                                      marker: .floorBay)
        // By the door, on its bracket, where an extinguisher belongs.
        case .extinguisher: return Place(wall: .west, along: -2.55, mount: .native(out: 0.022), euler: up)
        }
    }

    // MARK: Live state

    private final class Slot {
        weak var node: SCNNode?            // the slot (wall-local frame)
        weak var display: SCNNode?         // the tool itself, at home
        init(node: SCNNode, display: SCNNode) { self.node = node; self.display = display }
    }
    private static var slots: [SupplyTool: Slot] = [:]
    private static weak var sceneRoot: SCNNode?
    private static var s: Float = 3.52

    /// The scene root `node` lives under (the camera may be parented to a cab mid-ride).
    static func rootOf(_ node: SCNNode) -> SCNNode {
        var n = node
        while let p = n.parent { n = p }
        return n
    }

    /// Is the room in this (live) scene?
    static func isInstalled(in root: SCNNode?) -> Bool { root != nil && sceneRoot === root }

    // Room geometry (world).
    private static var cx: Float { 9 * s }
    private static var cz: Float { 10 * s }
    private static var half: Float { 1.5 * s }
    private static let face: Float = 0.05                // wall panels are 0.1 thick, centred on the cell boundary

    /// A wall's frame: the point on its face at the room's centre line, its
    /// "right" (as you face it) and its normal (into the room), and the yaw
    /// that turns local +X/+Z onto them.
    private static func frame(_ wall: Wall) -> (origin: SIMD3<Float>, right: SIMD3<Float>, normal: SIMD3<Float>, yaw: Float) {
        let h = half - face
        switch wall {
        case .north: return (SIMD3(cx, floorY, cz - h), SIMD3(1, 0, 0), SIMD3(0, 0, 1), 0)
        case .south: return (SIMD3(cx, floorY, cz + h), SIMD3(-1, 0, 0), SIMD3(0, 0, -1), .pi)
        case .east: return (SIMD3(cx + h, floorY, cz), SIMD3(0, 0, 1), SIMD3(-1, 0, 0), -.pi / 2)
        case .west: return (SIMD3(cx - h, floorY, cz), SIMD3(0, 0, -1), SIMD3(1, 0, 0), .pi / 2)
        }
    }

    /// A node in `wall`'s frame, `along` it, at height y, `out` from its face.
    private static func onWall(_ wall: Wall, along: Float, y: Float = 0, out: Float = 0, in parent: SCNNode) -> SCNNode {
        let f = frame(wall)
        let p = f.origin + f.right * along + f.normal * out
        let n = SCNNode()
        n.position = SCNVector3(p.x, floorY + y, p.z)
        n.eulerAngles.y = f.yaw
        parent.addChildNode(n)
        return n
    }

    // MARK: Build

    static func install(into root: SCNNode, cellSize: CGFloat, cells: Set<GridCoordinate>) {
        guard roomCells.isSubset(of: cells), cells.contains(foyerCell) else {
            diag("supplies.layoutMismatch", ["cells": cells.count]); return
        }
        s = Float(cellSize)
        slots = [:]
        sceneRoot = root
        let room = SCNNode()
        room.name = "supplyRoom"
        root.addChildNode(room)

        // The tools first: their homes decide where the outlines and labels go.
        var outlines: [Wall: [(tool: SupplyTool, minA: Float, maxA: Float, minY: Float, maxY: Float)]] = [:]
        var labels: [(tool: SupplyTool, wall: Wall, along: Float, y: Float, out: Float)] = []
        var bays: [(tool: SupplyTool, minA: Float, maxA: Float, depth: Float)] = []
        for tool in SupplyTool.allCases {
            let spot = Self.place(tool)
            let built = buildSlot(tool, place: spot, in: room)
            slots[tool] = Slot(node: built.node, display: built.display)
            built.display.isHidden = ToolBelt.carries(tool)
            let b = built.bounds                               // (slot-local: x along the wall, y up, z out)
            switch spot.marker {
            case .outline:
                outlines[spot.wall, default: []].append((tool, spot.along + b.min.x, spot.along + b.max.x,
                                                          built.node.position.y + b.min.y, built.node.position.y + b.max.y))
            case .shelfLabel(let y, let out):
                labels.append((tool, spot.wall, spot.along, y, out))
            case .floorBay:
                if case .stand(_, let out) = spot.mount { bays.append((tool, spot.along + b.min.x, spot.along + b.max.x, out + b.max.z)) }
            case .none: break
            }
        }

        buildFloorMarkings(in: room, bays: bays)
        buildWorkshopWall(in: room, outlines: outlines[.east] ?? [])
        buildNorthWall(in: room, outlines: outlines[.north] ?? [])
        buildSouthWall(in: room)
        buildWestWall(in: room)
        buildCeiling(in: room)
        buildEntrance(in: root)
        for l in labels { shelfLabel(l.tool.title, wall: l.wall, along: l.along, y: l.y, out: l.out, in: room) }
        diag("supplies.installed", ["tools": slots.count, "carried": ToolBelt.carried.map(\.rawValue).joined(separator: ",")])
    }

    /// One tool's home: the slot node (wall frame), the tool at rest in it,
    /// and an invisible, finger-sized volume around it for taps.
    private static func buildSlot(_ tool: SupplyTool, place: Place, in room: SCNNode)
        -> (node: SCNNode, display: SCNNode, bounds: (min: SCNVector3, max: SCNVector3)) {
        let slot: SCNNode
        let display = SCNNode()
        display.name = "supplyDisplay_\(tool.rawValue)"
        let model = tool.makeModel()
        model.eulerAngles = place.euler
        display.addChildNode(model)
        switch place.mount {
        case .native(let out):
            slot = onWall(place.wall, along: place.along, y: 0, out: out, in: room)
            // (the model's own wall frame: re-centre on x/z only, keep its heights)
            let raw = HallwayScene.makeFireExtinguisherNode(at: GridCoordinate(row: 0, col: 0), direction: .north, cellSize: 0)
            raw.position = SCNVector3Zero
            let bracket = SCNNode()
            for child in raw.childNodes where child.geometry is SCNBox { bracket.addChildNode(child) }
            bracket.position = SCNVector3(0, 0, 0.045)          // (its wall plate flat on the wall face)
            slot.addChildNode(bracket)
            // The tool exactly where a hallway's own hangs on its bracket: undo the
            // model's re-centring (its inner offset) so it is in the bracket's frame.
            let inner = model.childNodes.first?.position ?? SCNVector3Zero
            model.position = SCNVector3(-inner.x, -inner.y, -inner.z + 0.045)
        case .hang(let y):
            slot = onWall(place.wall, along: place.along, y: y, out: 0, in: room)
            let (lo, hi) = display.boundingBox
            model.position = SCNVector3(-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, 0.045 - lo.z)   // back on the board (0.03 out)
        case .stand(let y, let out):
            slot = onWall(place.wall, along: place.along, y: y, out: out, in: room)
            let (lo, hi) = display.boundingBox
            model.position = SCNVector3(-(lo.x + hi.x) / 2, -lo.y, -(lo.z + hi.z) / 2)
        }
        slot.name = "supplySlot_\(tool.rawValue)"
        slot.addChildNode(display)
        // The tap volume: the tool's bounds, grown to at least a finger's worth at a few metres.
        let (lo, hi) = display.boundingBox
        let pad: Float = 0.06
        let w = max(0.3, hi.x - lo.x + pad * 2), h = max(0.3, hi.y - lo.y + pad * 2), d = max(0.16, hi.z - lo.z + pad)
        let hitMat = SCNMaterial()
        hitMat.diffuse.contents = UIColor.clear
        hitMat.transparency = 0.001
        hitMat.writesToDepthBuffer = false
        let proxy = SupplyModels.box(w, h, d, hitMat, in: slot, at: SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2), chamfer: 0)
        proxy.name = "supplySlotHit"
        return (slot, display, (lo, hi))
    }

    // MARK: Materials and painted surfaces

    private static func flat(_ image: UIImage, rough: CGFloat = 0.8, metal: CGFloat = 0, transparent: Bool = false) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = image
        m.roughness.contents = rough
        m.metalness.contents = metal
        if transparent {
            m.transparencyMode = .aOne
            m.writesToDepthBuffer = false
        }
        return m
    }

    /// A rectangle of the wall (or floor) painted from an image: a thin box
    /// (or plane) facing out of `wall` at `along`, its bottom at `y`.
    @discardableResult
    private static func panel(_ wall: Wall, along: Float, y: Float, out: Float, width: Float, height: Float,
                              material: SCNMaterial, thickness: Float = 0, in parent: SCNNode) -> SCNNode {
        let n = onWall(wall, along: along, y: y + height / 2, out: out, in: parent)
        if thickness > 0 {
            let edge = SupplyModels.mat(UIColor(white: 0.25, alpha: 1), rough: 0.7)
            let g = SCNBox(width: CGFloat(width), height: CGFloat(height), length: CGFloat(thickness), chamferRadius: 0.002)
            g.materials = [material, edge, edge, edge, edge, edge]          // (front face painted)
            let b = SCNNode(geometry: g)
            b.position.z = -thickness / 2
            n.addChildNode(b)
        } else {
            let g = SCNPlane(width: CGFloat(width), height: CGFloat(height))
            g.materials = [material]
            n.addChildNode(SCNNode(geometry: g))
        }
        return n
    }

    private static let stencilFontName = "DINCondensed-Bold"
    private static func font(_ size: CGFloat) -> UIFont {
        UIFont(name: stencilFontName, size: size) ?? UIFont.systemFont(ofSize: size, weight: .heavy)
    }

    private static func draw(_ text: String, in rect: CGRect, size: CGFloat, color: UIColor, kern: CGFloat = 0,
                             align: NSTextAlignment = .center, font f: UIFont? = nil) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        let ft = f ?? font(size)
        let attrs: [NSAttributedString.Key: Any] = [.font: ft, .paragraphStyle: style, .foregroundColor: color, .kern: kern]
        let h = ft.lineHeight
        (text as NSString).draw(in: CGRect(x: rect.minX, y: rect.midY - h / 2 + size * 0.08, width: rect.width, height: h), withAttributes: attrs)
    }

    /// Hazard stripes (yellow and black) across `rect`.
    private static func hazard(_ g: CGContext, _ rect: CGRect, stripe: CGFloat) {
        g.saveGState()
        g.clip(to: rect)
        UIColor(red: 0.98, green: 0.78, blue: 0.1, alpha: 1).setFill()
        g.fill(rect)
        UIColor(white: 0.06, alpha: 1).setFill()
        var x = rect.minX - rect.height
        while x < rect.maxX + rect.height {
            let p = UIBezierPath()
            p.move(to: CGPoint(x: x, y: rect.maxY)); p.addLine(to: CGPoint(x: x + stripe, y: rect.maxY))
            p.addLine(to: CGPoint(x: x + stripe + rect.height, y: rect.minY)); p.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            p.close(); p.fill()
            x += stripe * 2
        }
        g.restoreGState()
    }

    /// Grime: a few soft dark smudges.
    private static func grime(_ g: CGContext, in size: CGSize, count: Int, alpha: CGFloat, seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        for _ in 0..<count {
            let c = CGPoint(x: CGFloat(rng.unit()) * size.width, y: CGFloat(rng.unit()) * size.height)
            let r = CGFloat(0.02 + rng.unit() * 0.08) * max(size.width, size.height)
            let colors = [UIColor(white: 0.1, alpha: alpha * CGFloat(0.4 + rng.unit() * 0.6)).cgColor, UIColor(white: 0.1, alpha: 0).cgColor]
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                g.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
            }
        }
    }

    /// A sign: background, optional hazard border, lines of text (fraction of the height each).
    private static func sign(_ lines: [(String, CGFloat, UIColor)], background: UIColor, size: CGSize, hazardBorder: Bool = false,
                             border: UIColor? = nil, worn: Bool = true) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            let g = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)
            background.setFill(); g.fill(rect)
            var inner = rect
            if hazardBorder {
                let b = size.height * 0.12
                hazard(g, rect, stripe: b * 0.9)
                inner = rect.insetBy(dx: b, dy: b)
                background.setFill(); g.fill(inner)
            }
            if let border {
                border.setStroke()
                let p = UIBezierPath(rect: inner.insetBy(dx: size.height * 0.03, dy: size.height * 0.03))
                p.lineWidth = size.height * 0.025; p.stroke()
            }
            let total = lines.reduce(CGFloat(0)) { $0 + $1.1 }
            var y = inner.minY + (inner.height - total * inner.height) / 2
            for (text, frac, color) in lines {
                let h = frac * inner.height
                draw(text, in: CGRect(x: inner.minX, y: y, width: inner.width, height: h), size: h * 0.82, color: color, kern: h * 0.04)
                y += h
            }
            if worn { grime(g, in: size, count: 6, alpha: 0.18, seed: UInt64(size.width) &* 31 &+ UInt64(lines.count)) }
        }
    }

    // MARK: The floor

    /// Painted on the concrete: the aisle lines, a hazard band at the door,
    /// a stencilled bay for each parked tool, a drain, an old oil stain.
    private static func buildFloorMarkings(in room: SCNNode, bays: [(tool: SupplyTool, minA: Float, maxA: Float, depth: Float)]) {
        let w = 2 * half, ppm: CGFloat = 100                                   // pixels per metre
        let size = CGSize(width: CGFloat(w) * ppm, height: CGFloat(w) * ppm)
        // Image x = world +X (east), image y = world +Z (south); origin at the room's NW corner.
        func px(_ x: Float) -> CGFloat { CGFloat(x - (cx - half)) * ppm }
        func pz(_ z: Float) -> CGFloat { CGFloat(z - (cz - half)) * ppm }
        let yellowPaint = UIColor(red: 0.95, green: 0.76, blue: 0.12, alpha: 0.85)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let g = ctx.cgContext
            g.clear(CGRect(origin: .zero, size: size))
            grime(g, in: size, count: 40, alpha: 0.16, seed: 4)
            // The aisle: a yellow line 1.2 m in from every wall, open at the door.
            let inset: Float = 1.32 + face
            let r = CGRect(x: px(cx - half + inset), y: pz(cz - half + inset),
                           width: CGFloat(2 * (half - inset)) * ppm, height: CGFloat(2 * (half - inset)) * ppm)
            yellowPaint.setStroke()
            let aisle = UIBezierPath(rect: r)
            aisle.lineWidth = 0.08 * ppm
            g.saveGState()
            g.clip(to: CGRect(origin: .zero, size: size))
            let door = CGRect(x: 0, y: pz(cz - 1.4), width: r.minX + 0.1 * ppm, height: 2.8 * ppm)
            g.addRect(CGRect(origin: .zero, size: size)); g.addRect(door)
            g.clip(using: .evenOdd)
            aisle.stroke()
            g.restoreGState()
            // The threshold: hazard stripes across the doorway.
            g.setAlpha(0.85)
            hazard(g, CGRect(x: 0.06 * ppm, y: pz(cz - 1.5), width: 0.32 * ppm, height: 3.0 * ppm), stripe: 0.12 * ppm)
            g.setAlpha(1)
            // KEEP AISLE CLEAR, readable walking in (facing east: its top toward +X).
            g.saveGState()
            g.translateBy(x: px(cx - half + 0.75), y: pz(cz))
            g.rotate(by: .pi / 2)
            draw("KEEP AISLE CLEAR", in: CGRect(x: -1.4 * ppm, y: -0.16 * ppm, width: 2.8 * ppm, height: 0.32 * ppm),
                 size: 0.26 * ppm, color: yellowPaint, kern: 0.03 * ppm)
            g.restoreGState()
            // The parking bays on the south wall (readable from the room: facing south, top toward +Z).
            for bay in bays {
                // South wall: "along" runs toward -X (to the right as you face it).
                let x0 = cx - bay.maxA - 0.08, x1 = cx - bay.minA + 0.08
                let z1 = cz + half - face, z0 = z1 - bay.depth - 0.12
                let rect = CGRect(x: px(x0), y: pz(z0), width: CGFloat(x1 - x0) * ppm, height: CGFloat(z1 - z0) * ppm)
                let p = UIBezierPath(rect: rect)
                p.lineWidth = 0.06 * ppm
                yellowPaint.setStroke(); p.stroke()
                g.saveGState()
                g.translateBy(x: rect.midX, y: rect.minY + 0.17 * ppm)
                g.rotate(by: .pi)
                draw(bay.tool.title, in: CGRect(x: -rect.width / 2, y: -0.12 * ppm, width: rect.width, height: 0.24 * ppm),
                     size: 0.2 * ppm, color: yellowPaint, kern: 0.02 * ppm)
                g.restoreGState()
            }
            // An old oil stain by the mower, and the floor drain in the middle.
            let stain = CGPoint(x: px(cx - 1.4), y: pz(cz + half - 1.55))
            let oil = [UIColor(red: 0.08, green: 0.07, blue: 0.05, alpha: 0.55).cgColor, UIColor(red: 0.08, green: 0.07, blue: 0.05, alpha: 0).cgColor]
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: oil as CFArray, locations: [0, 1]) {
                g.drawRadialGradient(grad, startCenter: stain, startRadius: 0, endCenter: stain, endRadius: 0.38 * ppm, options: [])
                let s2 = CGPoint(x: stain.x + 0.3 * ppm, y: stain.y - 0.12 * ppm)
                g.drawRadialGradient(grad, startCenter: s2, startRadius: 0, endCenter: s2, endRadius: 0.18 * ppm, options: [])
            }
            let drain = CGPoint(x: px(cx + 0.6), y: pz(cz + 0.4))
            UIColor(white: 0.32, alpha: 0.95).setFill()
            UIBezierPath(arcCenter: drain, radius: 0.13 * ppm, startAngle: 0, endAngle: 2 * .pi, clockwise: true).fill()
            UIColor(white: 0.08, alpha: 0.95).setFill()
            for i in -3...3 {
                g.fill(CGRect(x: drain.x - 0.09 * ppm, y: drain.y + CGFloat(i) * 0.03 * ppm - 0.008 * ppm, width: 0.18 * ppm, height: 0.016 * ppm))
            }
        }
        let plane = SCNPlane(width: CGFloat(w), height: CGFloat(w))
        plane.materials = [flat(image, rough: 0.75, transparent: true)]
        let n = SCNNode(geometry: plane)
        n.name = "supplyFloorPaint"
        n.eulerAngles.x = -.pi / 2                                               // (image top = north)
        n.position = SCNVector3(cx, floorY + 0.004, cz)
        n.renderingOrder = 1
        room.addChildNode(n)
    }

    // MARK: The walls

    /// A group in `wall`'s frame (x along it, y up, z out into the room).
    private static func group(_ wall: Wall, in room: SCNNode) -> SCNNode { onWall(wall, along: 0, in: room) }

    private static let steelBlue = SupplyModels.mat(UIColor(red: 0.26, green: 0.36, blue: 0.48, alpha: 1), metal: 0.6, rough: 0.45)
    private static let particle = SupplyModels.mat(UIColor(red: 0.62, green: 0.52, blue: 0.38, alpha: 1), rough: 0.9)
    private static let cardboard = SupplyModels.mat(UIColor(red: 0.66, green: 0.5, blue: 0.32, alpha: 1), rough: 0.95)
    private static let enamelWhite = SupplyModels.mat(UIColor(red: 0.9, green: 0.88, blue: 0.82, alpha: 1), metal: 0.1, rough: 0.35)
    private static let cabinetGrey = SupplyModels.mat(UIColor(red: 0.55, green: 0.58, blue: 0.56, alpha: 1), metal: 0.5, rough: 0.45)
    private static let chestRed = SupplyModels.mat(UIColor(red: 0.72, green: 0.06, blue: 0.05, alpha: 1), metal: 0.4, rough: 0.25)
    private static let copper = SupplyModels.mat(UIColor(red: 0.78, green: 0.45, blue: 0.28, alpha: 1), metal: 1, rough: 0.35)
    private static let pipeGreen = SupplyModels.mat(UIColor(red: 0.2, green: 0.36, blue: 0.27, alpha: 1), metal: 0.3, rough: 0.5)

    /// A shelf-edge label (white tag, black stencil) under a tool's place.
    private static func shelfLabel(_ text: String, wall: Wall, along: Float, y: Float, out: Float, in room: SCNNode) {
        let img = sign([(text, 0.8, UIColor(white: 0.08, alpha: 1))], background: UIColor(white: 0.96, alpha: 1),
                       size: CGSize(width: 480, height: 70), worn: false)
        panel(wall, along: along, y: y - 0.034, out: out + 0.003, width: 0.26, height: 0.038, material: flat(img, rough: 0.6), in: room)
    }

    /// A painted board (pegboard or plywood) with an outline and a name for each tool that hangs on it.
    private static func toolBoard(_ wall: Wall, along a0: Float, _ a1: Float, y y0: Float, _ y1: Float, pegboard: Bool,
                                  outlines: [(tool: SupplyTool, minA: Float, maxA: Float, minY: Float, maxY: Float)],
                                  header: String?, in room: SCNNode) {
        let ppm: CGFloat = 300
        let size = CGSize(width: CGFloat(a1 - a0) * ppm, height: CGFloat(y1 - y0) * ppm)
        func pa(_ a: Float) -> CGFloat { CGFloat(a - a0) * ppm }
        func py(_ y: Float) -> CGFloat { CGFloat(y1 - y) * ppm }
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let g = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)
            if pegboard {
                UIColor(red: 0.55, green: 0.41, blue: 0.26, alpha: 1).setFill(); g.fill(rect)
                UIColor(red: 0.22, green: 0.15, blue: 0.09, alpha: 1).setFill()
                let step = 0.0254 * ppm
                var y = step / 2
                while y < size.height {
                    var x = step / 2
                    while x < size.width {
                        g.fillEllipse(in: CGRect(x: x - 2.2, y: y - 2.2, width: 4.4, height: 4.4))
                        x += step
                    }
                    y += step
                }
            } else {
                UIColor(red: 0.8, green: 0.66, blue: 0.46, alpha: 1).setFill(); g.fill(rect)
                var rng = SeededRandom(seed: 77)
                for _ in 0..<160 {                                    // plywood grain
                    let y = CGFloat(rng.unit()) * size.height
                    let p = UIBezierPath()
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addCurve(to: CGPoint(x: size.width, y: y + CGFloat(rng.unit() - 0.5) * 30),
                               controlPoint1: CGPoint(x: size.width * 0.3, y: y + CGFloat(rng.unit() - 0.5) * 40),
                               controlPoint2: CGPoint(x: size.width * 0.7, y: y + CGFloat(rng.unit() - 0.5) * 40))
                    UIColor(red: 0.55, green: 0.4, blue: 0.24, alpha: CGFloat(0.05 + rng.unit() * 0.12)).setStroke()
                    p.lineWidth = CGFloat(1 + rng.unit() * 3)
                    p.stroke()
                }
            }
            // Each tool's place: its painted shape and its name.
            for o in outlines {
                let m: Float = 0.03
                let r = CGRect(x: pa(o.minA - m), y: py(o.maxY + m), width: CGFloat(o.maxA - o.minA + 2 * m) * ppm,
                               height: CGFloat(o.maxY - o.minY + 2 * m) * ppm)
                let shape = UIBezierPath(roundedRect: r, cornerRadius: 0.035 * ppm)
                UIColor(white: 0.1, alpha: 0.78).setFill(); shape.fill()
                UIColor(white: 0.96, alpha: 0.9).setStroke(); shape.lineWidth = 0.006 * ppm; shape.stroke()
                let labelH = 0.05 * ppm
                draw(o.tool.title, in: CGRect(x: r.midX - 0.3 * ppm, y: r.maxY + 0.008 * ppm, width: 0.6 * ppm, height: labelH),
                     size: labelH * 0.9, color: UIColor(white: 0.97, alpha: 0.95), kern: 0.004 * ppm)
            }
            if let header {
                let h = 0.11 * ppm
                draw(header, in: CGRect(x: 0, y: 0.04 * ppm, width: size.width, height: h), size: h * 0.9,
                     color: UIColor(white: 0.1, alpha: 0.85), kern: 0.02 * ppm)
            }
            grime(g, in: size, count: 14, alpha: 0.14, seed: UInt64(size.width))
        }
        panel(wall, along: (a0 + a1) / 2, y: y0, out: 0.03, width: a1 - a0, height: y1 - y0,
              material: flat(image, rough: pegboard ? 0.8 : 0.85), thickness: 0.018, in: room)
        // A wooden frame round the board.
        let gr = group(wall, in: room)
        let trim = SupplyModels.mat(UIColor(red: 0.42, green: 0.28, blue: 0.16, alpha: 1), rough: 0.7)
        SupplyModels.box(a1 - a0 + 0.06, 0.03, 0.035, trim, in: gr, at: SCNVector3((a0 + a1) / 2, y1 + 0.015, 0.022))
        SupplyModels.box(a1 - a0 + 0.06, 0.03, 0.035, trim, in: gr, at: SCNVector3((a0 + a1) / 2, y0 - 0.015, 0.022))
        SupplyModels.box(0.03, y1 - y0, 0.035, trim, in: gr, at: SCNVector3(a0 - 0.015, (y0 + y1) / 2, 0.022))
        SupplyModels.box(0.03, y1 - y0, 0.035, trim, in: gr, at: SCNVector3(a1 + 0.015, (y0 + y1) / 2, 0.022))
    }

    /// The east wall, facing you as you come in: the workbench, its pegboard,
    /// the big red tool chest, and the water heater in the corner.
    private static func buildWorkshopWall(in room: SCNNode, outlines: [(tool: SupplyTool, minA: Float, maxA: Float, minY: Float, maxY: Float)]) {
        toolBoard(.east, along: -1.95, 1.95, y: 1.04, 2.46, pegboard: true, outlines: outlines, header: nil, in: room)
        let g = group(.east, in: room)
        let B = SupplyModels.self
        // The bench: a thick maple top on steel legs, a shelf below.
        let maple = SupplyModels.mat(UIColor(red: 0.76, green: 0.6, blue: 0.4, alpha: 1), rough: 0.55)
        B.box(3.8, 0.05, 0.7, maple, in: g, at: SCNVector3(0, 0.9, 0.36), chamfer: 0.006)
        B.box(3.8, 0.1, 0.03, B.darkSteel, in: g, at: SCNVector3(0, 0.82, 0.7))
        for a: Float in [-1.84, 1.84] { for z: Float in [0.06, 0.66] {
            B.box(0.055, 0.85, 0.055, steelBlue, in: g, at: SCNVector3(a, 0.425, z))
        } }
        B.box(3.7, 0.03, 0.62, particle, in: g, at: SCNVector3(0, 0.2, 0.37))
        // Under it: bins and a crate.
        let binBlue = SupplyModels.mat(UIColor(red: 0.15, green: 0.35, blue: 0.7, alpha: 1), rough: 0.5)
        for a: Float in [-1.3, -0.8, 0.9] { B.box(0.4, 0.2, 0.45, binBlue, in: g, at: SCNVector3(a, 0.315, 0.32), chamfer: 0.02) }
        B.box(0.55, 0.28, 0.45, cardboard, in: g, at: SCNVector3(0.2, 0.355, 0.32))
        // The vice, bolted at the front edge.
        let viceBlue = SupplyModels.mat(UIColor(red: 0.15, green: 0.27, blue: 0.55, alpha: 1), metal: 0.5, rough: 0.4)
        B.box(0.16, 0.07, 0.16, viceBlue, in: g, at: SCNVector3(0.55, 0.96, 0.58), chamfer: 0.01)
        B.box(0.16, 0.08, 0.035, viceBlue, in: g, at: SCNVector3(0.55, 1.03, 0.55), chamfer: 0.006)
        B.box(0.16, 0.08, 0.035, viceBlue, in: g, at: SCNVector3(0.55, 1.03, 0.66), chamfer: 0.006)
        B.rod(0.008, 0.26, B.chrome, in: g, at: SCNVector3(0.55, 1.0, 0.72), euler: SCNVector3(0, 0, Float.pi / 2))
        // A mug of cold coffee.
        let mug = B.rod(0.042, 0.1, enamelWhite, in: g, at: SCNVector3(-0.02, 0.975, 0.22))
        B.part(SCNTorus(ringRadius: 0.026, pipeRadius: 0.007), enamelWhite, in: mug, at: SCNVector3(0.045, 0, 0),
               euler: SCNVector3(Float.pi / 2, 0, 0))
        B.rod(0.037, 0.002, SupplyModels.mat(UIColor(red: 0.18, green: 0.1, blue: 0.05, alpha: 1), rough: 0.1), in: mug, at: SCNVector3(0, 0.04, 0))
        // The tool chest (north end), with a radio on top.
        let chest = SCNNode()
        chest.position = SCNVector3(-2.9, 0, 0)
        g.addChildNode(chest)
        B.box(0.8, 0.95, 0.5, chestRed, in: chest, at: SCNVector3(0, 0.555, 0.3), chamfer: 0.015)
        for (i, y) in [Float(0.38), 0.52, 0.66, 0.78, 0.9, 0.98].enumerated() {
            B.box(0.78, 0.005, 0.004, B.black, in: chest, at: SCNVector3(0, y, 0.551), chamfer: 0)
            if i < 5 { B.rod(0.008, 0.46, B.chrome, in: chest, at: SCNVector3(0, y + 0.05, 0.565), euler: SCNVector3(0, 0, Float.pi / 2)) }
        }
        for a: Float in [-0.33, 0.33] { for z: Float in [0.1, 0.5] {
            B.rod(0.04, 0.03, B.rubber, in: chest, at: SCNVector3(a, 0.04, z), euler: SCNVector3(0, 0, Float.pi / 2))
        } }
        B.box(0.3, 0.17, 0.11, SupplyModels.mat(UIColor(red: 0.3, green: 0.24, blue: 0.18, alpha: 1), rough: 0.5), in: chest,
              at: SCNVector3(0.1, 1.115, 0.3), chamfer: 0.015)                                             // radio
        B.rod(0.04, 0.005, B.chrome, in: chest, at: SCNVector3(0.04, 1.12, 0.358), euler: SCNVector3(Float.pi / 2, 0, 0))
        B.rod(0.003, 0.35, B.chrome, in: chest, at: SCNVector3(0.2, 1.36, 0.28), euler: SCNVector3(0, 0, -0.4))   // aerial
        // The water heater in the corner, piped into the ceiling.
        let heater = SCNNode()
        heater.position = SCNVector3(half - face - 0.42, 0, 0.42)
        g.addChildNode(heater)
        B.rod(0.31, 1.5, enamelWhite, in: heater, at: SCNVector3(0, 0.79, 0))
        let dome = B.part(SCNSphere(radius: 0.31), enamelWhite, in: heater, at: SCNVector3(0, 1.54, 0))
        dome.scale = SCNVector3(1, 0.22, 1)
        B.rod(0.315, 0.06, B.darkSteel, in: heater, at: SCNVector3(0, 0.03, 0))
        for d: Float in [-0.12, 0.12] { B.rod(0.022, 1.42, copper, in: heater, at: SCNVector3(d, 2.29, 0)) }
        B.strut(from: SCNVector3(0, 1.3, 0.3), to: SCNVector3(0, 0.15, 0.33), radius: 0.011, copper, in: heater)   // relief pipe
        let tag = sign([("HOT WATER", 0.5, UIColor(white: 0.1, alpha: 1)), ("50 GAL", 0.35, UIColor(white: 0.3, alpha: 1))],
                       background: UIColor(red: 0.95, green: 0.9, blue: 0.75, alpha: 1), size: CGSize(width: 300, height: 180))
        let plate = B.part(SCNPlane(width: 0.2, height: 0.12), flat(tag), in: heater, at: SCNVector3(0, 1.1, 0.312))
        plate.name = nil
    }

    /// The north wall (on your left as you come in): the garden board, the
    /// steel shelving, a pallet of boxes.
    private static func buildNorthWall(in room: SCNNode, outlines: [(tool: SupplyTool, minA: Float, maxA: Float, minY: Float, maxY: Float)]) {
        toolBoard(.north, along: -4.95, -2.2, y: 0.3, 2.42, pegboard: false, outlines: outlines, header: "GROUNDS", in: room)
        let g = group(.north, in: room)
        let B = SupplyModels.self
        // Two bays of steel shelving.
        let shelves: [Float] = [0.12, 0.62, 1.12, 1.62, 2.1]
        for a: Float in [-1.7, 0, 1.7] { for z: Float in [0.04, 0.55] {
            B.box(0.035, 2.16, 0.035, steelBlue, in: g, at: SCNVector3(a, 1.08, z), chamfer: 0.002)
        } }
        for y in shelves {
            B.box(3.44, 0.025, 0.54, particle, in: g, at: SCNVector3(0, y + 0.0125, 0.295), chamfer: 0.002)
            B.box(3.44, 0.04, 0.012, steelBlue, in: g, at: SCNVector3(0, y + 0.005, 0.56), chamfer: 0.002)   // front lip
        }
        // What's on them (none of it is a tool).
        func pail(_ a: Float, _ y: Float, label: String) {
            let p = B.rod(0.15, 0.36, enamelWhite, in: g, at: SCNVector3(a, y + 0.025 + 0.18, 0.3))
            B.rod(0.155, 0.03, SupplyModels.mat(UIColor(white: 0.85, alpha: 1), rough: 0.5), in: p, at: SCNVector3(0, 0.17, 0))
            let img = sign([(label, 0.6, UIColor(red: 0.1, green: 0.25, blue: 0.6, alpha: 1))], background: UIColor(white: 0.97, alpha: 1),
                           size: CGSize(width: 260, height: 120))
            B.part(SCNPlane(width: 0.16, height: 0.075), flat(img, rough: 0.5), in: p, at: SCNVector3(0, 0.0, 0.151))
        }
        pail(-1.35, 0.12, label: "FLOOR WAX")
        pail(-0.85, 0.12, label: "FLOOR WAX")
        func carton(_ a: Float, _ y: Float, w: Float, h: Float, d: Float, label: String?) {
            let c = B.box(w, h, d, cardboard, in: g, at: SCNVector3(a, y + 0.025 + h / 2, 0.29), chamfer: 0.004)
            B.box(w + 0.002, 0.04, d * 0.3, SupplyModels.mat(UIColor(red: 0.75, green: 0.62, blue: 0.4, alpha: 1), rough: 0.4), in: c,
                  at: SCNVector3(0, h / 2 - 0.018, 0), chamfer: 0)                                       // tape
            if let label {
                let img = sign([(label, 0.7, UIColor(white: 0.12, alpha: 0.9))], background: UIColor(red: 0.66, green: 0.5, blue: 0.32, alpha: 1),
                               size: CGSize(width: 400, height: 90), worn: false)
                B.part(SCNPlane(width: CGFloat(w * 0.85), height: CGFloat(w * 0.85 * 0.225)), flat(img, rough: 0.95), in: c,
                       at: SCNVector3(0, 0, d / 2 + 0.002))
            }
        }
        carton(0.55, 0.12, w: 0.6, h: 0.32, d: 0.45, label: "ICE MELT")
        carton(1.25, 0.12, w: 0.55, h: 0.28, d: 0.45, label: nil)
        carton(-1.25, 1.62, w: 0.6, h: 0.3, d: 0.45, label: "BULBS - FRAGILE")
        carton(-0.5, 1.62, w: 0.55, h: 0.26, d: 0.42, label: "FUSES")
        carton(0.5, 1.62, w: 0.75, h: 0.35, d: 0.45, label: "TOILET PAPER (EMERGENCY)")
        carton(1.3, 1.62, w: 0.5, h: 0.3, d: 0.42, label: "MISC.")
        carton(-0.9, 2.1, w: 0.7, h: 0.3, d: 0.45, label: nil)
        carton(0.8, 2.1, w: 0.6, h: 0.25, d: 0.45, label: "XMAS LIGHTS")
        // Paint tins, spray bottles, a parts bin.
        let lids: [UIColor] = [UIColor(red: 0.85, green: 0.2, blue: 0.15, alpha: 1), UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1),
                               UIColor(white: 0.95, alpha: 1), UIColor(red: 0.95, green: 0.8, blue: 0.2, alpha: 1)]
        for (i, a) in [Float(0.25), 0.5, 0.75, 1.0].enumerated() {
            let tin = B.rod(0.085, 0.19, B.galvanized, in: g, at: SCNVector3(a + 0.05, 0.645 + 0.095, 0.28))
            B.rod(0.086, 0.06, SupplyModels.mat(lids[i], rough: 0.5), in: tin, at: SCNVector3(0, -0.01, 0))   // label band
            B.rod(0.08, 0.008, SupplyModels.mat(lids[i], rough: 0.3), in: tin, at: SCNVector3(0, 0.097, 0))
        }
        B.rod(0.085, 0.19, B.galvanized, in: g, at: SCNVector3(1.45, 0.645 + 0.095, 0.28))
        for (i, a) in [Float(-1.45), -1.3, -1.15].enumerated() {
            let bottle = B.rod(0.035, 0.2, SupplyModels.mat(i == 1 ? UIColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
                                                                    : UIColor(red: 0.95, green: 0.95, blue: 0.3, alpha: 1), rough: 0.3),
                               in: g, at: SCNVector3(a, 1.145 + 0.1, 0.3))
            B.box(0.03, 0.05, 0.06, B.black, in: bottle, at: SCNVector3(0, 0.12, 0.015), chamfer: 0.006)
        }
        let bin = SupplyModels.mat(UIColor(red: 0.12, green: 0.32, blue: 0.68, alpha: 1), rough: 0.5)
        B.box(0.32, 0.16, 0.42, bin, in: g, at: SCNVector3(0.3, 1.145 + 0.08, 0.3), chamfer: 0.015)
        B.box(0.32, 0.16, 0.42, bin, in: g, at: SCNVector3(-0.6, 1.145 + 0.08, 0.3), chamfer: 0.015)
        for a: Float in [-1.45, -1.2, -0.95] { B.rod(0.06, 0.24, enamelWhite, in: g, at: SCNVector3(a + 2.6, 2.1 + 0.025 + 0.12, 0.3)) }  // paper towels
        // A pallet of boxes in the corner.
        let pal = SCNNode()
        pal.position = SCNVector3(2.95, 0, 0.58)
        g.addChildNode(pal)
        let palletWood = SupplyModels.mat(UIColor(red: 0.7, green: 0.58, blue: 0.4, alpha: 1), rough: 0.9)
        for i in 0..<7 { B.box(0.13, 0.022, 1.0, palletWood, in: pal, at: SCNVector3(-0.54 + Float(i) * 0.18, 0.13, 0), chamfer: 0.002) }
        for z: Float in [-0.42, 0, 0.42] { B.box(1.2, 0.1, 0.1, palletWood, in: pal, at: SCNVector3(0, 0.06, z), chamfer: 0.003) }
        B.box(0.55, 0.45, 0.45, cardboard, in: pal, at: SCNVector3(-0.27, 0.367, -0.22), chamfer: 0.005)
        B.box(0.55, 0.45, 0.45, cardboard, in: pal, at: SCNVector3(0.28, 0.367, -0.22), chamfer: 0.005)
        B.box(0.55, 0.4, 0.45, cardboard, in: pal, at: SCNVector3(-0.25, 0.342, 0.25), chamfer: 0.005)
        B.box(0.5, 0.38, 0.42, cardboard, in: pal, at: SCNVector3(0.05, 0.78, -0.15), euler: SCNVector3(0, 0.2, 0), chamfer: 0.005)
    }

    /// The south wall (your right): a tall cabinet, a hard hat and vest on
    /// hooks, the time clock. (The ladder and mower park here too.)
    private static func buildSouthWall(in room: SCNNode) {
        let g = group(.south, in: room)
        let B = SupplyModels.self
        // The cabinet.
        let cab = SCNNode()
        cab.position = SCNVector3(-0.85, 0, 0)
        g.addChildNode(cab)
        B.box(1.0, 1.95, 0.48, cabinetGrey, in: cab, at: SCNVector3(0, 0.975, 0.25), chamfer: 0.01)
        B.box(0.004, 1.85, 0.004, B.black, in: cab, at: SCNVector3(0, 0.975, 0.491), chamfer: 0)
        for a: Float in [-0.05, 0.05] { B.rod(0.009, 0.2, B.chrome, in: cab, at: SCNVector3(a, 1.05, 0.505)) }
        for y: Float in [0.15, 0.19, 0.23, 1.72, 1.76, 1.8] { for a: Float in [-0.25, 0.25] {
            B.box(0.3, 0.008, 0.004, B.black, in: cab, at: SCNVector3(a, y, 0.491), chamfer: 0)
        } }
        let stencil = sign([("No. 4", 1, UIColor(white: 0.12, alpha: 0.85))], background: UIColor(red: 0.55, green: 0.58, blue: 0.56, alpha: 1),
                           size: CGSize(width: 300, height: 120))
        B.part(SCNPlane(width: 0.3, height: 0.12), flat(stencil, rough: 0.5, metal: 0.4), in: cab, at: SCNVector3(-0.25, 1.45, 0.492))
        let sticker = sign([("AUTHORIZED PERSONNEL ONLY", 0.45, UIColor(white: 0.08, alpha: 1)),
                            ("(THAT MEANS YOU)", 0.3, UIColor(red: 0.7, green: 0.08, blue: 0.05, alpha: 1))],
                           background: UIColor(red: 0.98, green: 0.84, blue: 0.2, alpha: 1), size: CGSize(width: 420, height: 160))
        B.part(SCNPlane(width: 0.26, height: 0.1), flat(sticker, rough: 0.5), in: cab, at: SCNVector3(0.25, 1.4, 0.492))
        // Hooks: a hard hat and a high-vis vest.
        let rail = SCNNode()
        rail.position = SCNVector3(-2.3, 0, 0)
        g.addChildNode(rail)
        B.box(0.9, 0.1, 0.025, SupplyModels.mat(UIColor(red: 0.42, green: 0.28, blue: 0.16, alpha: 1), rough: 0.7), in: rail,
              at: SCNVector3(0, 1.75, 0.0125))
        for a: Float in [-0.28, 0.28] { B.rod(0.008, 0.08, B.chrome, in: rail, at: SCNVector3(a, 1.74, 0.06), euler: SCNVector3(Float.pi / 2 - 0.4, 0, 0)) }
        let hat = SCNNode()
        hat.position = SCNVector3(-0.28, 1.6, 0.12)
        hat.eulerAngles.x = -0.25
        rail.addChildNode(hat)
        let shell = B.part(SCNSphere(radius: 0.13), B.yellow, in: hat, at: SCNVector3(0, 0, 0))
        shell.scale = SCNVector3(1, 0.78, 1.12)
        B.rod(0.16, 0.012, B.yellow, in: hat, at: SCNVector3(0, -0.04, 0.02))
        let vest = SCNNode()
        vest.position = SCNVector3(0.28, 1.38, 0.05)
        rail.addChildNode(vest)
        let hiVis = SupplyModels.mat(UIColor(red: 1.0, green: 0.45, blue: 0.05, alpha: 1), rough: 0.7)
        B.box(0.46, 0.56, 0.03, hiVis, in: vest, at: SCNVector3(0, 0, 0), chamfer: 0.02)
        for y: Float in [-0.12, 0.05] { B.box(0.47, 0.035, 0.032, B.chrome, in: vest, at: SCNVector3(0, y, 0), chamfer: 0.003) }
        // The time clock and its card rack.
        let clock = SCNNode()
        clock.position = SCNVector3(-3.35, 0, 0)
        g.addChildNode(clock)
        B.box(0.26, 0.34, 0.14, SupplyModels.mat(UIColor(red: 0.8, green: 0.75, blue: 0.62, alpha: 1), metal: 0.2, rough: 0.5), in: clock,
              at: SCNVector3(0, 1.5, 0.07), chamfer: 0.02)
        let faceImg = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { ctx in
            UIColor(white: 0.97, alpha: 1).setFill(); ctx.cgContext.fillEllipse(in: CGRect(x: 4, y: 4, width: 192, height: 192))
            UIColor(white: 0.1, alpha: 1).setFill()
            for i in 0..<12 {
                let a = CGFloat(i) * .pi / 6
                ctx.cgContext.fill(CGRect(x: 100 + cos(a) * 80 - 4, y: 100 + sin(a) * 80 - 4, width: 8, height: 8))
            }
            UIColor(white: 0.1, alpha: 1).setStroke()
            let hands = UIBezierPath(); hands.move(to: CGPoint(x: 100, y: 40)); hands.addLine(to: CGPoint(x: 100, y: 100))
            hands.addLine(to: CGPoint(x: 140, y: 120)); hands.lineWidth = 7; hands.stroke()
        }
        let faceMat = flat(faceImg, rough: 0.3, transparent: true)
        B.part(SCNPlane(width: 0.17, height: 0.17), faceMat, in: clock, at: SCNVector3(0, 1.55, 0.142))
        B.box(0.2, 0.42, 0.04, SupplyModels.mat(UIColor(white: 0.35, alpha: 1), metal: 0.6, rough: 0.4), in: clock, at: SCNVector3(0.3, 1.45, 0.02))
        for i in 0..<5 {
            B.box(0.08, 0.13, 0.004, SupplyModels.mat(UIColor(red: 0.92, green: 0.88, blue: 0.74, alpha: 1), rough: 0.9), in: clock,
                  at: SCNVector3(0.27 + Float(i % 2) * 0.05, 1.3 + Float(i) * 0.065, 0.045), chamfer: 0)
        }
    }

    /// The west wall (behind you as you come in): the electrical panel, the
    /// sign-out clipboard, the first-aid box, and the room's own extinguisher
    /// sign over its bracket.
    private static func buildWestWall(in room: SCNNode) {
        let g = group(.west, in: room)
        let B = SupplyModels.self
        // The panel and its conduit.
        B.box(0.55, 0.8, 0.14, cabinetGrey, in: g, at: SCNVector3(3.1, 1.65, 0.07), chamfer: 0.01)
        B.rod(0.025, 0.95, B.galvanized, in: g, at: SCNVector3(3.1, 2.525, 0.05))
        let label = sign([("PANEL 4B", 0.45, UIColor(white: 0.1, alpha: 1)), ("DO NOT FEED", 0.3, UIColor(red: 0.7, green: 0.05, blue: 0.05, alpha: 1))],
                         background: UIColor(white: 0.92, alpha: 1), size: CGSize(width: 300, height: 150))
        B.part(SCNPlane(width: 0.22, height: 0.11), flat(label, rough: 0.5), in: g, at: SCNVector3(3.1, 1.85, 0.142))
        B.box(0.02, 0.06, 0.03, B.chrome, in: g, at: SCNVector3(2.88, 1.6, 0.15), chamfer: 0.004)                 // latch
        // The sign-out sheet.
        let sheet = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 330)).image { ctx in
            let g2 = ctx.cgContext
            UIColor(red: 0.55, green: 0.38, blue: 0.2, alpha: 1).setFill(); g2.fill(CGRect(x: 0, y: 0, width: 240, height: 330))
            UIColor(white: 0.97, alpha: 1).setFill(); g2.fill(CGRect(x: 14, y: 40, width: 212, height: 278))
            draw("TOOL SIGN-OUT", in: CGRect(x: 14, y: 48, width: 212, height: 30), size: 26, color: UIColor(white: 0.1, alpha: 1))
            UIColor(red: 0.5, green: 0.6, blue: 0.85, alpha: 1).setFill()
            for i in 0..<9 { g2.fill(CGRect(x: 22, y: 92 + CGFloat(i) * 24, width: 196, height: 1.5)) }
            var rng = SeededRandom(seed: 9)
            UIColor(red: 0.1, green: 0.12, blue: 0.35, alpha: 0.85).setStroke()
            for i in 0..<6 {                                              // somebody's handwriting
                let p = UIBezierPath()
                var x: CGFloat = 26
                let y = 86 + CGFloat(i) * 24
                p.move(to: CGPoint(x: x, y: y))
                while x < 26 + CGFloat(80 + rng.unit() * 100) {
                    x += CGFloat(4 + rng.unit() * 6)
                    p.addLine(to: CGPoint(x: x, y: y - CGFloat(rng.unit() * 9)))
                }
                p.lineWidth = 1.6; p.stroke()
            }
        }
        B.part(SCNPlane(width: 0.24, height: 0.33), flat(sheet, rough: 0.8), in: g, at: SCNVector3(2.25, 1.42, 0.012))
        B.box(0.1, 0.03, 0.02, B.chrome, in: g, at: SCNVector3(2.25, 1.57, 0.02), chamfer: 0.005)                // the clip
        // First aid.
        let aid = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240)).image { ctx in
            UIColor(white: 0.96, alpha: 1).setFill(); ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
            UIColor(red: 0.1, green: 0.55, blue: 0.3, alpha: 1).setFill()
            ctx.cgContext.fill(CGRect(x: 95, y: 40, width: 50, height: 130)); ctx.cgContext.fill(CGRect(x: 55, y: 80, width: 130, height: 50))
            draw("FIRST AID", in: CGRect(x: 0, y: 185, width: 240, height: 40), size: 34, color: UIColor(red: 0.1, green: 0.4, blue: 0.22, alpha: 1))
        }
        let aidBox = B.box(0.3, 0.3, 0.12, enamelWhite, in: g, at: SCNVector3(-3.75, 1.45, 0.06), chamfer: 0.012)
        B.part(SCNPlane(width: 0.28, height: 0.28), flat(aid, rough: 0.4), in: aidBox, at: SCNVector3(0, 0, 0.061))
        // The extinguisher's own sign, over its bracket.
        let fire = sign([("FIRE", 0.45, .white), ("EXTINGUISHER", 0.35, .white)], background: UIColor(red: 0.78, green: 0.06, blue: 0.05, alpha: 1),
                        size: CGSize(width: 300, height: 170), worn: false)
        B.part(SCNPlane(width: 0.32, height: 0.18), flat(fire, rough: 0.5), in: g, at: SCNVector3(-2.55, 2.0, 0.012))
    }

    // MARK: Overhead

    /// Pipes and a duct under the corrugated ceiling, and two enamel pendants over the bench.
    private static func buildCeiling(in room: SCNNode) {
        let B = SupplyModels.self
        let x0 = cx - half + face, x1 = cx + half - face
        let n = cz - half + face, sZ = cz + half - face
        let len = x1 - x0
        // Along the north wall: a copper line and a fat green one, on hangers.
        B.rod(0.028, len, copper, in: room, at: SCNVector3(cx, 2.72, n + 0.25), euler: SCNVector3(0, 0, Float.pi / 2))
        B.rod(0.05, len, pipeGreen, in: room, at: SCNVector3(cx, 2.82, n + 0.45), euler: SCNVector3(0, 0, Float.pi / 2))
        var x = x0 + 0.6
        while x < x1 {
            B.rod(0.006, 0.3, B.darkSteel, in: room, at: SCNVector3(x, 2.86, n + 0.25))
            B.rod(0.006, 0.14, B.darkSteel, in: room, at: SCNVector3(x, 2.93, n + 0.45))
            x += 1.5
        }
        // Along the south wall: a ventilation duct.
        B.box(len, 0.32, 0.5, B.galvanized, in: room, at: SCNVector3(cx, 2.82, sZ - 0.45), chamfer: 0.01)
        var sx = x0 + 1.2
        while sx < x1 { B.box(0.03, 0.34, 0.52, B.darkSteel, in: room, at: SCNVector3(sx, 2.82, sZ - 0.45), chamfer: 0.004); sx += 1.2 }
        B.box(0.5, 0.01, 0.3, B.darkSteel, in: room, at: SCNVector3(cx - 1.0, 2.655, sZ - 0.45), chamfer: 0)    // a grille
        // Two pendants over the bench (east wall).
        let ex = cx + half - face - 0.42
        let warm = UIColor(red: 1.0, green: 0.84, blue: 0.58, alpha: 1)
        let shadeOut = SupplyModels.mat(UIColor(red: 0.13, green: 0.3, blue: 0.22, alpha: 1), metal: 0.3, rough: 0.35)
        let shadeIn = SupplyModels.mat(UIColor(white: 0.95, alpha: 1), rough: 0.5, glow: warm.withAlphaComponent(0.35))
        shadeIn.isDoubleSided = true
        let bulb = SupplyModels.mat(warm, glow: warm)
        bulb.lightingModel = .constant
        for z in [cz - 0.95, cz + 0.95] {
            B.rod(0.004, 0.52, B.black, in: room, at: SCNVector3(ex, 2.74, z))
            B.part(SCNCone(topRadius: 0.05, bottomRadius: 0.2, height: 0.16), shadeOut, in: room, at: SCNVector3(ex, 2.4, z))
            B.part(SCNCone(topRadius: 0.045, bottomRadius: 0.19, height: 0.15), shadeIn, in: room, at: SCNVector3(ex, 2.398, z))
            B.part(SCNSphere(radius: 0.045), bulb, in: room, at: SCNVector3(ex, 2.36, z))
        }
    }

    /// The way in: a steel door frame with a SUPPLIES sign over it (seen from
    /// the elevator), the inside of it lettered with the safety record, and
    /// the storeroom's chain-link gate swung back against the foyer wall.
    private static func buildEntrance(in root: SCNNode) {
        let B = SupplyModels.self
        let xw = cx - half
        let entrance = SCNNode()
        entrance.name = "supplyEntrance"
        root.addChildNode(entrance)
        let jamb = SupplyModels.mat(UIColor(red: 0.95, green: 0.74, blue: 0.1, alpha: 1), metal: 0.2, rough: 0.45)
        for side: Float in [-1, 1] {
            let z = cz + side * (0.5 * s - 0.14)
            B.box(0.24, 2.45, 0.28, jamb, in: entrance, at: SCNVector3(xw, floorY + 1.225, z), chamfer: 0.01)
            B.box(0.25, 0.3, 0.29, B.black, in: entrance, at: SCNVector3(xw, floorY + 0.15, z), chamfer: 0.01)
        }
        B.box(0.24, 0.55, s, B.darkSteel, in: entrance, at: SCNVector3(xw, floorY + 2.725, cz), chamfer: 0.01)
        // From the elevator side: SUPPLIES.
        let supplies = sign([("SUPPLIES", 0.62, UIColor(white: 0.06, alpha: 1)), ("MAINTENANCE  ·  FLOOR 4", 0.2, UIColor(white: 0.15, alpha: 1))],
                            background: UIColor(red: 0.98, green: 0.8, blue: 0.12, alpha: 1), size: CGSize(width: 1100, height: 240), hazardBorder: true)
        let front = B.part(SCNPlane(width: 2.3, height: 0.5), flat(supplies, rough: 0.5), in: entrance, at: SCNVector3(xw - 0.125, floorY + 2.725, cz))
        front.eulerAngles.y = -.pi / 2
        // From inside: the safety record.
        let record = sign([("THIS DEPARTMENT HAS WORKED", 0.22, UIColor(white: 0.1, alpha: 1)), ("0", 0.5, UIColor(red: 0.8, green: 0.06, blue: 0.05, alpha: 1)),
                           ("DAYS WITHOUT AN INCIDENT", 0.22, UIColor(white: 0.1, alpha: 1))],
                          background: UIColor(white: 0.95, alpha: 1), size: CGSize(width: 800, height: 260), border: UIColor(red: 0.1, green: 0.4, blue: 0.2, alpha: 1))
        let back = B.part(SCNPlane(width: 1.5, height: 0.48), flat(record, rough: 0.5), in: entrance, at: SCNVector3(xw + 0.125, floorY + 2.725, cz))
        back.eulerAngles.y = .pi / 2
        // The gate, open, flat against the foyer's north wall.
        let gate = SCNNode()
        gate.position = SCNVector3(xw - 0.2 - 0.7, floorY, cz - 0.5 * s + face + 0.05)
        entrance.addChildNode(gate)
        let mesh = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512)).image { ctx in
            ctx.cgContext.clear(CGRect(x: 0, y: 0, width: 512, height: 512))
            UIColor(white: 0.7, alpha: 1).setStroke()
            let step: CGFloat = 32
            var k: CGFloat = -512
            while k < 1024 {
                let a = UIBezierPath(); a.move(to: CGPoint(x: k, y: 0)); a.addLine(to: CGPoint(x: k + 512, y: 512)); a.lineWidth = 3; a.stroke()
                let b = UIBezierPath(); b.move(to: CGPoint(x: k, y: 512)); b.addLine(to: CGPoint(x: k + 512, y: 0)); b.lineWidth = 3; b.stroke()
                k += step
            }
        }
        let meshMat = flat(mesh, rough: 0.4, metal: 0.8, transparent: true)
        meshMat.isDoubleSided = true
        meshMat.diffuse.wrapS = .repeat; meshMat.diffuse.wrapT = .repeat
        meshMat.diffuse.contentsTransform = SCNMatrix4MakeScale(3, 4.5, 1)
        B.part(SCNPlane(width: 1.36, height: 2.1), meshMat, in: gate, at: SCNVector3(0, 1.12, 0))
        let tube = B.galvanized
        B.rod(0.02, 2.16, tube, in: gate, at: SCNVector3(-0.69, 1.12, 0))
        B.rod(0.02, 2.16, tube, in: gate, at: SCNVector3(0.69, 1.12, 0))
        B.rod(0.02, 1.4, tube, in: gate, at: SCNVector3(0, 2.19, 0), euler: SCNVector3(0, 0, Float.pi / 2))
        B.rod(0.02, 1.4, tube, in: gate, at: SCNVector3(0, 0.07, 0), euler: SCNVector3(0, 0, Float.pi / 2))
    }

    // MARK: The player and the tools' places

    /// The tool whose place `node` belongs to (the tool, its tap volume, its slot).
    static func tool(for node: SCNNode) -> SupplyTool? {
        var n: SCNNode? = node
        while let current = n {
            if let name = current.name, name.hasPrefix("supplySlot_") { return SupplyTool(rawValue: String(name.dropFirst(11))) }
            n = current.parent
        }
        return nil
    }

    /// The middle of `tool` in its place (world), if its place is in this scene.
    static func toolCentre(_ tool: SupplyTool) -> SCNVector3? {
        guard let display = slots[tool]?.display, display.parent != nil else { return nil }
        let (lo, hi) = display.boundingBox
        return display.convertPosition(SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2), to: nil)
    }

    /// Oct 16 (IV): which tool a tap in the room means. The nearest surface
    /// under the finger is often not the tool's own tap volume -- the shelf
    /// above a bucket, a shelf label, the painted outline on the pegboard --
    /// so: (1) any tool place along the tap ray within 0.9 m behind the first
    /// thing it hits; else (2) the tool whose middle is drawn within 46 points
    /// of the finger and is not hidden behind that first surface.
    static func toolTarget(hits: [SCNHitTestResult], point: CGPoint, view: SCNView, eye: SCNVector3) -> SupplyTool? {
        func dist(_ p: SCNVector3) -> Float { simd_distance(SIMD3(p.x, p.y, p.z), SIMD3(eye.x, eye.y, eye.z)) }
        let firstDist = hits.first.map { dist($0.worldCoordinates) } ?? .greatestFiniteMagnitude
        for h in hits {
            if dist(h.worldCoordinates) > firstDist + 0.9 { break }
            if let t = tool(for: h.node) { return t }
        }
        // (only when the finger landed on something in the room itself -- never through a foyer wall)
        if let first = hits.first, abs(first.worldCoordinates.x - cx) > half + 0.2 || abs(first.worldCoordinates.z - cz) > half + 0.2 {
            return nil
        }
        var best: (tool: SupplyTool, d: CGFloat)?
        for t in SupplyTool.allCases where !ToolBelt.carries(t) {        // (an empty place is only ever returned to deliberately)
            guard let c = toolCentre(t), dist(c) <= firstDist + 0.9 else { continue }
            let p = view.projectPoint(c)
            guard p.z > 0, p.z < 1 else { continue }
            let d = hypot(CGFloat(p.x) - point.x, CGFloat(p.y) - point.y)
            if d < 46, d < (best?.d ?? .greatestFiniteMagnitude) { best = (t, d) }
        }
        return best?.tool
    }

    /// Is the world point `p` inside the room or its foyer (x/z)?
    static func containsXZ(_ p: SCNVector3, margin: Float = 0.15) -> Bool {
        let inRoom = abs(p.x - cx) <= half + margin && abs(p.z - cz) <= half + margin
        let foyerX0 = (Float(foyerCell.col) - 0.5) * s, foyerX1 = cx - half
        let inFoyer = p.x >= foyerX0 - margin && p.x <= foyerX1 + margin && abs(p.z - cz) <= 0.5 * s + margin
        return inRoom || inFoyer
    }

    /// Where to stand to take `tool` (eye height `eyeY`), and the yaw facing it.
    static func standPose(_ tool: SupplyTool, eyeY: Float) -> (position: SCNVector3, yaw: Double) {
        let p = place(tool)
        let f = frame(p.wall)
        var spot = f.origin + f.right * p.along + f.normal * standOff
        // (inside the walkable middle of the room)
        let lim = half - face - 1.42
        spot.x = min(max(spot.x, cx - lim), cx + lim)
        spot.z = min(max(spot.z, cz - lim), cz + lim)
        let yaw = Double(atan2(f.normal.x, f.normal.z))                 // facing the wall (-normal)
        return (SCNVector3(spot.x, eyeY, spot.z), yaw)
    }

    /// The tool's model as it sits in its place (world transform: what a carried copy flies from and back to).
    private static func restingModel(_ tool: SupplyTool) -> (display: SCNNode, model: SCNNode)? {
        guard let display = slots[tool]?.display, display.parent != nil else { return nil }
        let model = display.childNode(withName: "supplyModel_\(tool.rawValue)", recursively: true) ?? display
        return (display, model)
    }

    /// The tool leaves its place: hidden there, and where it was (world).
    static func takeDisplay(_ tool: SupplyTool, in root: SCNNode?) -> SCNMatrix4? {
        guard isInstalled(in: root), let rest = restingModel(tool) else { return nil }
        rest.display.removeAllActions()
        rest.display.transform = SCNMatrix4Identity              // (a refusal's shake, cut short)
        let world = rest.model.worldTransform
        rest.display.isHidden = true
        return world
    }

    /// Where `tool` goes back to (world), if its place is in `root`.
    static func homeTarget(_ tool: SupplyTool, in root: SCNNode?) -> SCNMatrix4? {
        guard isInstalled(in: root), let rest = restingModel(tool) else { return nil }
        return rest.model.worldTransform
    }

    /// The tool is home: shown in its place again (unless it was taken again meanwhile).
    static func showDisplay(_ tool: SupplyTool, in root: SCNNode?, animated: Bool) {
        guard isInstalled(in: root), !ToolBelt.carries(tool), let display = slots[tool]?.display else { return }
        display.isHidden = false
        if animated {
            display.opacity = 0
            display.runAction(.fadeIn(duration: 0.15))
        }
    }

    /// Not carried any more: shown in its place in the room last built, whichever scene that is.
    static func restore(_ tool: SupplyTool) {
        guard !ToolBelt.carries(tool), let display = slots[tool]?.display else { return }
        display.isHidden = false
        display.opacity = 1
    }

    /// "Your hands are full": the tool gives a small shake on its hook.
    static func refuse(_ tool: SupplyTool) {
        guard let display = slots[tool]?.display else { return }
        let a = SCNAction.rotateBy(x: 0, y: 0, z: 0.06, duration: 0.06)
        display.removeAction(forKey: "refuse")
        display.runAction(.sequence([a, a.reversed(), a.reversed(), a, a, a.reversed()]), forKey: "refuse")
    }
}

/// A small deterministic random source (the room looks the same every visit).
nonisolated struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

// MARK: - Tools in hand and at heel (render-thread helpers)

/// The hands' small life: a bob and a weight shift per step while walking,
/// a slow breath at rest, and a slight lag when the view turns. Runs on the
/// render thread (an SCNAction on the hands' root, a camera child); it only
/// reads the camera's presentation and writes the root's own transform.
nonisolated final class HandSway {
    private var last: SIMD3<Float>?
    private var lastYaw: Float = 0
    private var lastTime: CFTimeInterval = 0
    private var phase: Float = 0, amp: Float = 0, lag: Float = 0, breath: Float = 0

    static func action(_ sway: HandSway) -> SCNAction {
        .repeatForever(.customAction(duration: 1) { node, _ in sway.step(node) })
    }

    func step(_ node: SCNNode) {
        guard let cam = node.parent else { return }
        let now = CACurrentMediaTime()
        let dt = lastTime == 0 ? 0 : Float(min(0.1, now - lastTime))
        lastTime = now
        let p = cam.presentation.worldPosition
        let pos = SIMD3<Float>(p.x, p.y, p.z)
        let yaw = cam.presentation.eulerAngles.y
        var speed: Float = 0, yawRate: Float = 0
        if let last, dt > 0 {
            speed = simd_length(SIMD2<Float>(pos.x - last.x, pos.z - last.z)) / dt
            var d = yaw - lastYaw
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            yawRate = d / dt
        }
        if speed > 8 { speed = 0 }                                    // (a jump -- a new floor, a resume -- not a walk)
        last = pos
        lastYaw = yaw
        guard dt > 0 else { return }
        amp += (min(1, speed / 1.1) - amp) * min(1, dt * 4)
        phase += speed * dt / 0.75 * .pi                              // a bob per 0.75 m step
        breath += dt * 1.6
        lag += (max(-0.06, min(0.06, -yawRate * 0.03)) - lag) * min(1, dt * 8)
        let bob = -0.007 * abs(sin(phase)) * amp + 0.0016 * sin(breath)
        node.position = SCNVector3(0.0045 * sin(phase) * amp, bob, 0)
        node.eulerAngles = SCNVector3(0, lag, 0.012 * sin(phase) * amp)
    }
}

/// The big tools that follow -- Oct 16 (II), a hybrid. Out in the open each
/// one ESCORTS the player: it walks a few paces AHEAD and a little to one side
/// (the first right, the second left), down on the floor where a portrait view
/// sees it, keeping pace as the player walks and swinging round (walking, never
/// jumping) when the player turns. Where that spot isn't open floor in plain
/// reach -- a corner, a doorway, a short room -- it falls back to the player's
/// own recent path a few paces BEHIND, as before, so it still only goes where
/// the player went and never through a wall. Rolling, waddling or hopping.
/// Render thread; members are added/removed under a lock.
nonisolated final class FollowTrail {
    final class Member {
        let node: SCNNode
        let gait: Int                      // SupplyTool.Gait raw value
        var gap: Float
        var slot: Int = 0                  // 0: escorts on the right, 1: on the left
        var pos: SIMD2<Float>
        var yaw: Float
        var phase: Float = 0
        var moving: Float = 0
        init(node: SCNNode, gait: Int, gap: Float, pos: SIMD2<Float>, yaw: Float) {
            self.node = node; self.gait = gait; self.gap = gap; self.pos = pos; self.yaw = yaw
        }
    }
    private let lock = NSLock()
    private var members: [Member] = []
    private var trail: [SIMD2<Float>] = []                            // newest first
    private var lastTime: CFTimeInterval = 0
    weak var camera: SCNNode?
    var floorY: Float = 0
    /// The floor's open cells (row * 4096 + col) and their size: what "open floor" means.
    var openCells: Set<Int> = []
    var cellSize: Float = 3.52
    /// Cells with a door (room, bathroom, window room): a follower never takes
    /// its own way through one -- only along the player's path (open when they went).
    var doorCells: Set<Int> = []

    /// Escort spot: this far ahead of the eye, this far to the side.
    static let ahead: Float = 3.3
    static let aside: Float = 0.6
    /// Never faster than this (m/s): followers walk into view, they don't pop.
    static let maxSpeed: Float = 7.0                                  // (a tap-walk glides at 6 m/s)

    static func action(_ t: FollowTrail) -> SCNAction {
        .repeatForever(.customAction(duration: 1) { _, _ in t.step() })
    }

    func add(_ node: SCNNode, gait: Int, gap: Float, at pos: SIMD2<Float>, yaw: Float) {
        lock.lock(); defer { lock.unlock() }
        members.append(Member(node: node, gait: gait, gap: gap, pos: pos, yaw: yaw))
        for (i, m) in members.enumerated() { m.slot = i % 2 }
    }

    func remove(_ node: SCNNode) {
        lock.lock(); defer { lock.unlock() }
        members.removeAll { $0.node === node }
        for (i, m) in members.enumerated() { m.slot = i % 2 }
    }

    func setGap(_ node: SCNNode, _ gap: Float) {
        lock.lock(); defer { lock.unlock() }
        members.first { $0.node === node }?.gap = gap
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        members.removeAll()
    }

    // MARK: Open floor

    private func isOpen(_ p: SIMD2<Float>) -> Bool {
        guard !openCells.isEmpty else { return true }                 // (no map: trust the trail)
        let col = Int((p.x / cellSize).rounded()), row = Int((p.y / cellSize).rounded())
        return openCells.contains(row * 4096 + col)
    }

    /// Open floor at `p` with `margin` of room all round.
    private func roomy(_ p: SIMD2<Float>, _ margin: Float) -> Bool {
        isOpen(p) && isOpen(p + SIMD2(margin, 0)) && isOpen(p - SIMD2(margin, 0))
            && isOpen(p + SIMD2(0, margin)) && isOpen(p - SIMD2(0, margin))
    }

    private func cellKey(_ p: SIMD2<Float>) -> Int {
        Int((p.y / cellSize).rounded()) * 4096 + Int((p.x / cellSize).rounded())
    }

    /// A straight walk from a to b stays on open floor with `margin` to spare
    /// (and, unless `doors` is allowed, never crosses into or out of a door's cell).
    private func clear(_ a: SIMD2<Float>, _ b: SIMD2<Float>, margin: Float, doors: Bool = true) -> Bool {
        let d = simd_distance(a, b)
        let n = max(1, Int(d / 0.25))
        var last = cellKey(a)
        for i in 0...n {
            let p = a + (b - a) * (Float(i) / Float(n))
            if !roomy(p, margin) { return false }
            let k = cellKey(p)
            if !doors, k != last, doorCells.contains(k) || doorCells.contains(last) { return false }
            last = k
        }
        return true
    }

    // MARK: Each frame

    func step() {
        guard let cam = camera else { return }
        let now = CACurrentMediaTime()
        let dt = lastTime == 0 ? 0 : Float(min(0.1, now - lastTime))
        lastTime = now
        let pres = cam.presentation
        let p = pres.worldPosition
        let here = SIMD2<Float>(p.x, p.z)
        let f = pres.worldFront
        var fwd = SIMD2<Float>(f.x, f.z)
        fwd = simd_length(fwd) > 1e-4 ? simd_normalize(fwd) : SIMD2<Float>(0, -1)
        let right = SIMD2<Float>(-fwd.y, fwd.x)
        lock.lock(); defer { lock.unlock() }
        if let first = trail.first {
            let d = simd_distance(first, here)
            if d > 3 {                                                // a jump (new floor, resume): start again here
                trail = [here]
                for m in members { m.pos = here }
            } else if d > 0.05 {
                trail.insert(here, at: 0)
            }
        } else {
            trail = [here]
            for m in members where m.node.childNodes.first?.childNodes.first?.action(forKey: "fly") == nil { m.pos = here }
        }
        if trail.count > 180 { trail.removeLast(trail.count - 180) }
        guard dt > 0 else { return }
        for m in members {
            // Where to be: escorting ahead if that's open floor reachable in a
            // straight line from both the player and the follower; otherwise
            // straight to the player (if that's clear), else the path behind.
            let side: Float = m.slot == 0 ? 1 : -1
            let escort = here + fwd * (Self.ahead + Float(m.slot) * 0.35) + right * side * Self.aside
            var target: SIMD2<Float>
            let ahead = simd_dot(m.pos - here, fwd)
            let besideSpot = here + right * side * 1.0 + fwd * 0.4
            if roomy(escort, 1.0), clear(here, escort, margin: 0.4, doors: false),
               clear(m.pos, escort, margin: 0.25, doors: false) {        // (clear of walls, doors and what stands along them)
                target = escort
            } else if ahead > 1.0, ahead < 4.5, roomy(besideSpot, 0.45), clear(m.pos, besideSpot, margin: 0.2, doors: false) {
                target = besideSpot                                   // (in the way: step aside and let the player by)
            } else if ahead <= 1.0, simd_distance(m.pos, here) < 4.2, roomy(m.pos, 0.45), clear(here, m.pos, margin: 0.3, doors: false) {
                target = m.pos                                        // (beside or behind, in the open: wait for the way to open)
            } else {
                target = point(behind: m.gap, from: here)
                if !clear(m.pos, target, margin: 0.15) {
                    if clear(m.pos, here, margin: 0.15) { target = here }
                    else if simd_dot(target - here, fwd) < 0, simd_dot(m.pos - here, fwd) < 0 {
                        m.pos = target                                // (behind the player, out of view: catch up)
                    }                                                 // (else glide on -- never a pop in view)
                }
            }
            let toT = target - m.pos
            let dist = simd_length(toT)
            let stepLen = min(dist * min(1, dt * 3.2), Self.maxSpeed * dt)
            let move = dist > 1e-5 ? toT / dist * stepLen : SIMD2<Float>(0, 0)
            m.pos += move
            let moved = simd_length(move)
            // Facing: the way it goes; standing, it turns to look at the player.
            var want = m.yaw
            if moved / dt > 0.15 {
                want = atan2(-move.x, -move.y)
            } else {
                let look = here - m.pos
                if simd_length(look) > 0.3 { want = atan2(-look.x, -look.y) }
            }
            var dy = want - m.yaw
            while dy > .pi { dy -= 2 * .pi }
            while dy < -.pi { dy += 2 * .pi }
            m.yaw += dy * min(1, dt * 5)
            m.moving += ((moved / dt > 0.12 ? 1 : 0) - m.moving) * min(1, dt * 6)
            let stride: Float = m.gait == 0 ? 0.6 : (m.gait == 1 ? 0.35 : 0.5)
            m.phase += moved / stride
            m.node.position = SCNVector3(m.pos.x, floorY, m.pos.y)
            m.node.eulerAngles = SCNVector3(0, m.yaw, 0)
            guard let gaitNode = m.node.childNodes.first else { continue }
            let s = sin(m.phase * .pi)
            switch m.gait {
            case 1:                                                   // waddle: rock from leg to leg
                gaitNode.position = SCNVector3(0, 0.03 * abs(s) * m.moving, 0)
                gaitNode.eulerAngles = SCNVector3(0, 0, 0.09 * sin(m.phase * .pi) * m.moving)
            case 2:                                                   // hop along on its head
                gaitNode.position = SCNVector3(0, 0.11 * abs(s) * m.moving, 0)
                gaitNode.eulerAngles = SCNVector3(-0.1 * m.moving, 0, 0.04 * s * m.moving)
            default:                                                  // roll: a little judder
                gaitNode.position = SCNVector3(0, 0.003 * abs(sin(m.phase * 9)) * m.moving, 0)
            }
        }
    }

    /// The point `gap` metres back along the trail from `here`.
    private func point(behind gap: Float, from here: SIMD2<Float>) -> SIMD2<Float> {
        var remaining = gap
        var prev = here
        for p in trail {
            let d = simd_distance(prev, p)
            if d >= remaining, d > 1e-5 { return prev + (p - prev) * (remaining / d) }
            remaining -= d
            prev = p
        }
        return prev
    }
}

/// A node's flight from one transform to another (its parent's space), with a little lift.
nonisolated enum ToolFlight {
    static func parts(_ m: SCNMatrix4) -> (p: SIMD3<Float>, q: simd_quatf, s: SIMD3<Float>) {
        let n = SCNNode()
        n.transform = m
        return (n.simdPosition, n.simdOrientation, n.simdScale)
    }

    static func action(from a: SCNMatrix4, to b: SCNMatrix4, duration: Double, lift: Float) -> SCNAction {
        let (p0, q0, s0) = parts(a), (p1, q1, s1) = parts(b)
        let fly = SCNAction.customAction(duration: duration) { node, elapsed in
            let raw = Float(min(1, max(0, Double(elapsed) / duration)))
            let t = raw * raw * (3 - 2 * raw)
            node.simdPosition = p0 + (p1 - p0) * t + SIMD3<Float>(0, lift * sin(raw * .pi), 0)
            node.simdOrientation = simd_slerp(q0, q1, t)
            node.simdScale = s0 + (s1 - s0) * t
        }
        return fly
    }
}

/// The tools the player carries: the list (saved), the hands, the followers.
enum ToolBelt {
    /// Oct 16 (V): how carried tools are SHOWN -- a developer setting (Settings,
    /// developer tools: "Tool Presentation"), saved under presentationKey.
    ///   .tray  (default, the audition) -- a compact tray of up to four slots
    ///          along the bottom; nothing rides on the camera; the selected
    ///          tool appears in the world only while it is being used.
    ///   .hands -- the two-hand presentation (Oct 16 IV), unchanged: two tools.
    /// Inventory, ownership, saving, pickup, release and return-home are the
    /// same code either way; only the presentation and the limit differ.
    enum Presentation: String { case tray, hands }
    nonisolated static let presentationKey = "supplies.presentation.v1"
    static var presentation: Presentation { ToolTray.shared.mode }
    static let maxCapacity = 4
    static var capacity: Int { presentation == .tray ? 4 : 2 }
    nonisolated static let carriedKey = "supplies.carried.v1"   // (also in ResumeState.allKeys: Start Over clears it)
    /// How far in front of the eye the hands hold things (zNear is 0.05).
    static let handDepth: Float = 0.55

    private(set) static var carried: [SupplyTool] = loadCarried()
    private static weak var camera: SCNNode?
    private static weak var view: SCNView?
    private static weak var controller: TapNavigationController?
    private static var handsRoot: SCNNode?
    private static var followRig: SCNNode?
    private static var trail: FollowTrail?
    private static var held: [SupplyTool: SCNNode] = [:]          // the model, in its hand
    private static var followers: [SupplyTool: SCNNode] = [:]     // the follower's root
    private static var sides: [SupplyTool: Float] = [:]          // +1 right hand, -1 left
    /// A hallway wall extinguisher, taken from its bracket: held in a hand like
    /// any tool (never saved -- it belongs to its floor; leaving the floor puts
    /// it back, as it always did). Oct 16 (II): this REPLACES the old separate
    /// camera-attached extinguisher (TapNavigationController.carriedExtinguisherNode,
    /// HallwayScene.makeCarriedFireExtinguisherNode -- both gone).
    private static var hallwayExtinguisher: SCNNode?
    private static var hallwaySide: Float = 1
    /// One-time repair of saves from the first Supplies build (see loadCarried).
    nonisolated static let legacyExtinguisherRepairKey = "supplies.legacyExtinguisherCleared.v1"
    private static var watch: Timer?
    private static var laidOutFor: CGSize = .zero

    private static func loadCarried() -> [SupplyTool] {
        var seen = Set<SupplyTool>()
        var saved = (UserDefaults.standard.array(forKey: carriedKey) as? [String] ?? []).compactMap(SupplyTool.init(rawValue:))
        // Oct 16 (II) -- SAVE REPAIR, once per install: an extinguisher saved as
        // carried by the earlier Supplies builds comes back as the one stuck to
        // the player. It is put back on its bracket in Supplies (nothing else
        // changes: floor, spot, ID, progress and every other tool are untouched).
        // Not one of ResumeState.allKeys on purpose: Start Over must not re-arm it.
        let d = UserDefaults.standard
        if !d.bool(forKey: legacyExtinguisherRepairKey) {
            d.set(true, forKey: legacyExtinguisherRepairKey)
            if saved.contains(.extinguisher) {
                saved.removeAll { $0 == .extinguisher }
                d.set(saved.map(\.rawValue), forKey: carriedKey)
                diag("supplies.legacyExtinguisherCleared", ["kept": saved.map(\.rawValue).joined(separator: ",")])
            }
        }
        let unique = saved.filter { seen.insert($0).inserted }
        if unique.count > maxCapacity {
            // (more than any presentation holds: the rest are simply back in their places in Supplies)
            diag("supplies.overCapacityReturned", ["kept": unique.prefix(maxCapacity).map(\.rawValue).joined(separator: ","),
                                                   "returned": unique.dropFirst(maxCapacity).map(\.rawValue).joined(separator: ",")])
            UserDefaults.standard.set(unique.prefix(maxCapacity).map(\.rawValue), forKey: carriedKey)
        }
        let kept = Array(unique.prefix(maxCapacity))
        // (two hands can't hold more than two: such a save opens in the tray -- nothing is put back)
        if kept.count > 2, ToolTray.shared.mode == .hands {
            ToolTray.shared.mode = .tray
            d.set(Presentation.tray.rawValue, forKey: presentationKey)
            diag("supplies.presentationForcedToTray", ["carried": kept.count])
        }
        return kept
    }

    private static func save() { UserDefaults.standard.set(carried.map(\.rawValue), forKey: carriedKey) }

    static func carries(_ tool: SupplyTool) -> Bool { carried.contains(tool) }
    /// A wall extinguisher from a hallway, carried (it takes a hand / a slot too).
    static var wallExtinguisherHeld: Bool { hallwayHeld }
    private static var hallwayHeld = false
    static var isFull: Bool { carried.count + (wallExtinguisherHeld ? 1 : 0) >= capacity }

    /// Is `node` something the player is carrying (in hand or following)?
    static func owns(_ node: SCNNode) -> Bool {
        var n: SCNNode? = node
        while let current = n {
            if current === handsRoot || current === followRig { return true }
            n = current.parent
        }
        return false
    }

    // MARK: Each floor

    /// Every floor build, once the player is placed: the hands on this
    /// floor's camera, the followers at the player's feet.
    static func attach(camera: SCNNode, view: SCNView, controller: TapNavigationController?,
                       cells: Set<GridCoordinate> = [], cellSize: CGFloat = 3.52, doorCells: Set<GridCoordinate> = []) {
        handsRoot?.removeFromParentNode()
        followRig?.removeFromParentNode()
        trail?.removeAll()
        held = [:]; followers = [:]; sides = [:]
        hallwayExtinguisher = nil                     // (it belonged to the floor just left)
        self.camera = camera
        self.view = view
        self.controller = controller
        let hands = SCNNode()
        hands.name = "toolHands"
        camera.addChildNode(hands)
        hands.runAction(HandSway.action(HandSway()), forKey: "sway")
        handsRoot = hands
        let rig = SCNNode()
        rig.name = "toolFollowers"
        SuppliesShowroom.rootOf(camera).addChildNode(rig)
        let t = FollowTrail()
        t.camera = camera
        t.openCells = Set(cells.map { $0.row * 4096 + $0.col })
        t.cellSize = Float(cellSize)
        t.doorCells = Set(doorCells.map { $0.row * 4096 + $0.col })
        t.floorY = SuppliesShowroom.floorY
        rig.runAction(FollowTrail.action(t), forKey: "follow")
        followRig = rig
        trail = t
        laidOutFor = view.bounds.size
        hallwayHeld = false                            // (it belonged to the floor just left)
        for tool in carried { bring(tool, from: nil) }
        FlashlightBeam.attach(to: camera)              // Oct 16 (VIII): this floor's camera gets the beam
        syncTray()
        diag("supplies.attached", ["carried": carried.map(\.rawValue).joined(separator: ","), "presentation": presentation.rawValue])
        if watch == nil {
            // While seated (the office computer, the meeting) the hands are put down out of view.
            watch = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let seated = OfficeComputer.shared.isActive || ConferenceMeeting.isActive || BoxReveal.isRunning
                        || ToolBelt.controller?.isSeatedAtComputer == true || ToolBelt.controller?.isSeatedInMeeting == true
                    handsRoot?.isHidden = seated
                    // The tray steps aside only while seated (the computer, the meeting).
                    // Oct 16 (VI): it used to vanish for the whole elevator stay -- the
                    // "tray disappears in the elevator" report. Now it stays on screen;
                    // while the panel is in use it is see-through to touches (and dimmed),
                    // so it can never stand between a finger and a floor button.
                    let c = ToolBelt.controller
                    let elevator = c?.isElevatorWaitingForFloor == true || c?.isElevatorRideInProgress == true || c?.elevatorDoorsOpenIdle == true
                    if ToolTray.shared.hidden != seated { ToolTray.shared.hidden = seated }
                    if ToolTray.shared.passThrough != elevator { ToolTray.shared.passThrough = elevator }
                    FlashlightBeam.refresh()           // (off while seated; back on when standing)
                    // The hand and the controller always agree about a hallway extinguisher:
                    // one carried is one seen (and so one that can be put back), never one
                    // without the other.
                    if let c = ToolBelt.controller, ToolBelt.camera != nil {
                        if c.carryingExtinguisher, !wallExtinguisherHeld { holdHallwayExtinguisher() }
                        else if !c.carryingExtinguisher, wallExtinguisherHeld { dropHallwayExtinguisher(animated: false) }
                    }
                    if presentation == .hands, let size = ToolBelt.view?.bounds.size, size.width > 10, size != laidOutFor { relayoutHands() }
                }
            }
        }
    }

    /// The visible half-width and half-height of the view at `distance`.
    private static func frustum(at distance: Float) -> (halfW: Float, halfH: Float) {
        let lens = camera?.camera
        let fov = Float(lens?.fieldOfView ?? 75) * .pi / 180
        let t = tan(fov / 2) * distance
        var bounds = view?.bounds.size ?? .zero
        if bounds.width < 10 || bounds.height < 10 { bounds = CGSize(width: 390, height: 844) }   // (not laid out yet: a portrait phone)
        let aspect = Float(bounds.width / bounds.height)
        if lens?.projectionDirection == .horizontal { return (t, t / aspect) }
        return (t * aspect, t)
    }

    /// The hand on `side`, low in that corner of the view.
    private static func hand(_ side: Float) -> SCNNode? {
        guard let handsRoot else { return nil }
        let name = side > 0 ? "rightHand" : "leftHand"
        if let h = handsRoot.childNode(withName: name, recursively: false) { return h }
        let h = SCNNode()
        h.name = name
        handsRoot.addChildNode(h)
        return h
    }

    /// A model's place in a hand: its transform (hand space) for `pose` on `side`.
    private static func holdTransform(_ model: SCNNode, pose: SupplyTool.HeldPose, side: Float) -> (hand: SCNVector3, model: SCNMatrix4) {
        let (halfW, halfH) = frustum(at: handDepth)
        let probe = SCNNode()
        let saved = model.transform
        let parent = model.parent
        model.removeFromParentNode()
        probe.addChildNode(model)
        model.transform = SCNMatrix4Identity
        model.eulerAngles = SCNVector3(pose.euler.x, side * pose.euler.y, side * (pose.euler.z + pose.lean))
        model.scale = SCNVector3(pose.scale, pose.scale, pose.scale)
        let (lo, hi) = probe.boundingBox
        model.position = SCNVector3(-(lo.x + hi.x) / 2, -hi.y, -(lo.z + hi.z) / 2)    // (its top on the hand's line)
        let target = model.transform
        model.removeFromParentNode()
        model.transform = saved
        parent?.addChildNode(model)
        let handAt = SCNVector3(side * halfW * pose.inset, -halfH + pose.top * 2 * halfH, -handDepth)
        return (handAt, target)
    }

    private static func freeSide() -> Float {
        var taken = Set(sides.values)
        if hallwayExtinguisher?.parent != nil { taken.insert(hallwaySide) }   // (drawn in a hand)
        return taken.contains(1) ? -1 : 1
    }

    /// Re-fit the hands (the view's size settled, or changed).
    private static func relayoutHands() {
        laidOutFor = view?.bounds.size ?? .zero
        for (tool, model) in held {
            guard let side = sides[tool], let h = hand(side) else { continue }
            let (at, m) = holdTransform(model, pose: tool.heldPose, side: side)
            h.removeAllActions()
            h.position = at
            h.eulerAngles = SCNVector3Zero                      // (a poke cut short)
            model.removeAllActions()
            model.transform = m
        }
        if let node = hallwayExtinguisher, node.parent != nil, let h = hand(hallwaySide) {
            let (at, m) = holdTransform(node, pose: SupplyTool.extinguisher.heldPose, side: hallwaySide)
            h.removeAllActions()
            h.position = at
            h.eulerAngles = SCNVector3Zero
            node.transform = m
        }
    }

    /// Into a hand, or to heel: flying from `from` (world) when given.
    private static func bring(_ tool: SupplyTool, from: SCNMatrix4?) {
        let model = tool.makeModel()
        if presentation == .tray {
            // Into the tray: nothing stays on the camera. Picked up in the room, it
            // flies from its place down into the tray and is gone from the view.
            if let from, let handsRoot {
                let (halfW, halfH) = frustum(at: 0.5)
                _ = halfW
                let start = handsRoot.convertTransform(from, from: nil)
                let end = SCNNode()
                end.position = SCNVector3(0, -halfH * 0.95, -0.5)
                end.scale = SCNVector3(0.12, 0.12, 0.12)
                model.name = "toolIntoTray"
                handsRoot.addChildNode(model)
                model.transform = start
                model.runAction(.sequence([ToolFlight.action(from: start, to: end.transform, duration: 0.5, lift: 0.05),
                                           .removeFromParentNode()]))
            }
            return
        }
        switch tool.carry {
        case .held:
            let side = freeSide()
            sides[tool] = side
            guard let h = hand(side) else { return }
            let (at, target) = holdTransform(model, pose: tool.heldPose, side: side)
            h.position = at
            h.addChildNode(model)
            model.enumerateHierarchy { n, _ in n.categoryBitMask = Menagerie.categoryBit }   // (never in a creature's line of sight)
            held[tool] = model
            if let from {
                let start = h.convertTransform(from, from: nil)
                model.transform = start
                model.runAction(ToolFlight.action(from: start, to: target, duration: 0.55, lift: 0.05), forKey: "fly")
            } else {
                model.transform = target
            }
        case .follows:
            guard let rig = followRig, let trail else { return }
            let root = SCNNode()
            root.name = "follower_\(tool.rawValue)"
            let gaitNode = SCNNode()
            root.addChildNode(gaitNode)
            gaitNode.addChildNode(model)
            rig.addChildNode(root)
            // (the camera was only just placed for this floor: its model position, not a lagging presentation)
            let cam = camera?.worldPosition ?? SCNVector3Zero
            var startXZ = SIMD2<Float>(cam.x, cam.z)
            if let from { startXZ = SIMD2<Float>(from.m41, from.m43) }
            root.position = SCNVector3(startXZ.x, SuppliesShowroom.floorY, startXZ.y)
            let front = camera?.worldFront ?? SCNVector3(0, 0, -1)
            let yaw = atan2(-front.x, -front.z)
            root.eulerAngles.y = yaw
            followers[tool] = root
            trail.add(root, gait: tool.gait.rawValue, gap: gap(for: tool), at: startXZ, yaw: yaw)
            if let from {
                let start = gaitNode.convertTransform(from, from: nil)
                model.transform = start
                model.runAction(ToolFlight.action(from: start, to: SCNMatrix4Identity, duration: 0.7, lift: 0.25), forKey: "fly")
            }
        }
    }

    /// How far behind a follower walks (the first close, the next a pace further).
    private static func gap(for tool: SupplyTool) -> Float {
        let order = carried.filter { $0.carry == .follows }
        return 1.7 + Float(order.firstIndex(of: tool) ?? 0) * 1.25
    }

    // MARK: Picking up and sending back

    /// Picked up (from its place, world transform `from` when it is in this scene).
    static func add(_ tool: SupplyTool, from: SCNMatrix4?) {
        guard !carries(tool), !isFull else { return }
        carried.append(tool)
        save()
        bring(tool, from: from)
        ToolTray.shared.selected = .tool(tool)                       // (the one just taken is the one in use)
        ToolTray.shared.setOn(tool, true)                            // Oct 17: (a switchable one, switched on)
        syncTray()
        diag("supplies.pickedUp", ["tool": tool.rawValue, "carried": carried.count, "how": tool.carry == .held ? "held" : "follows"])
    }

    /// Back to Supplies: into its place when that place is in `root` (watch it fly home), else away.
    static func remove(_ tool: SupplyTool, root: SCNNode?) {
        guard let i = carried.firstIndex(of: tool) else { return }
        carried.remove(at: i)
        save()
        sides[tool] = nil
        var model: SCNNode?
        var leaving: SCNNode?                                       // what disappears if it can't fly home
        if let m = held.removeValue(forKey: tool) {
            model = m
            leaving = m
        } else if let f = followers.removeValue(forKey: tool) {
            trail?.remove(f)
            model = f.childNodes.first?.childNodes.first
            leaving = f
        }
        for (other, follower) in followers { trail?.setGap(follower, gap(for: other)) }
        if ToolTray.shared.selected == .tool(tool) { ToolTray.shared.selected = nil }
        syncTray()
        // (in the tray it has no model on screen: it rises out of the tray to fly home)
        if model == nil, presentation == .tray, let handsRoot, root != nil, SuppliesShowroom.homeTarget(tool, in: root) != nil {
            let m = tool.makeModel()
            let (_, halfH) = frustum(at: 0.5)
            m.position = SCNVector3(0, -halfH * 0.95, -0.5)
            m.scale = SCNVector3(0.12, 0.12, 0.12)
            handsRoot.addChildNode(m)
            model = m
            leaving = m
        }
        if let model, let root, let home = SuppliesShowroom.homeTarget(tool, in: root) {
            let world = model.presentation.worldTransform
            model.removeAllActions()
            model.removeFromParentNode()
            if leaving !== model { leaving?.removeFromParentNode() }
            let flyer = SCNNode()
            root.addChildNode(flyer)
            flyer.transform = world
            model.transform = SCNMatrix4Identity
            flyer.addChildNode(model)
            flyer.runAction(.sequence([ToolFlight.action(from: world, to: home, duration: 0.7, lift: 0.3), .removeFromParentNode()])) {
                DispatchQueue.main.async { MainActor.assumeIsolated { SuppliesShowroom.showDisplay(tool, in: root, animated: true) } }
            }
        } else if let leaving {
            leaving.removeAllActions()
            let away = SCNAction.group([.moveBy(x: 0, y: 0.25, z: 0, duration: 0.35), .fadeOut(duration: 0.35)])
            away.timingMode = .easeIn
            leaving.runAction(.sequence([away, .removeFromParentNode()]))
            SuppliesShowroom.restore(tool)              // (a Floor 4 room already built -- e.g. staged mid-ride -- shows it home)
        } else {
            SuppliesShowroom.restore(tool)              // (tray, away from the room: likewise)
        }
        diag("supplies.returned", ["tool": tool.rawValue, "carried": carried.count, "home": SuppliesShowroom.isInstalled(in: root)])
    }

    /// Start Over: nothing carried; every tool back in its place.
    static func resetForNewPlayer() {
        carried = []
        save()
        for m in held.values { m.removeFromParentNode() }
        for f in followers.values { trail?.remove(f); f.removeFromParentNode() }
        held = [:]; followers = [:]; sides = [:]
        dropHallwayExtinguisher(animated: false)
        ToolTray.shared.selected = nil
        syncTray()
    }

    // MARK: Oct 16 (V) -- presentation

    /// Switch how tools are shown. Refused (with the reason) when two hands
    /// couldn't hold what is carried -- nothing is ever put back to make room.
    @discardableResult
    static func setPresentation(_ p: Presentation) -> String? {
        guard p != presentation else { return nil }
        if p == .hands, let message = handsBlockedMessage { return message }
        ToolTray.shared.mode = p
        UserDefaults.standard.set(p.rawValue, forKey: presentationKey)
        rebuildPresentation()
        diag("supplies.presentation", ["mode": p.rawValue, "carried": carried.count])
        return nil
    }

    /// Why Two Hands can't be chosen right now (nil: it can).
    static var handsBlockedMessage: String? {
        let extra = carried.count + (hallwayHeld ? 1 : 0) - 2
        guard extra > 0 else { return nil }
        return "Return \(extra == 1 ? "one tool" : "\(extra) tools") before switching to Two Hands."
    }

    /// Settings: send a carried item home (as the tray's RETURN does).
    @discardableResult
    static func returnFromMenu(_ item: ToolTray.Item) -> Bool {
        guard let c = controller else { return false }
        switch item {
        case .tool(let t): return Supplies.release(t, controller: c)
        case .hallwayExtinguisher: return c.putAwayExtinguisher()
        }
    }

    /// Re-show what is carried in the current presentation (nothing gained or lost).
    private static func rebuildPresentation() {
        for m in held.values { m.removeFromParentNode() }
        for f in followers.values { trail?.remove(f); f.removeFromParentNode() }
        held = [:]; sides = [:]; followers = [:]
        hallwayExtinguisher?.removeFromParentNode()
        hallwayExtinguisher = nil
        if presentation == .hands, handsRoot != nil {
            for tool in carried { bring(tool, from: nil) }
            if hallwayHeld { showHallwayExtinguisherInHand() }
        }
        syncTray()
    }

    /// The tray's contents, from the inventory (the one source of truth).
    static func syncTray() {
        var items = carried.map { ToolTray.Item.tool($0) }
        if hallwayHeld { items.append(.hallwayExtinguisher) }
        let t = ToolTray.shared
        if t.items != items { t.items = items }
        if let sel = t.selected, !items.contains(sel) { t.selected = nil }
        if t.offerReturn.map({ !items.contains($0) }) == true { t.offerReturn = nil }
        // Oct 17: only a carried tool can be ON (returning it switches it off);
        // in the tray, only the selected one.
        let on = t.switchedOn.filter { carried.contains($0) && (presentation == .hands || t.selected == .tool($0)) }
        if on != t.switchedOn { t.switchedOn = on }
        FlashlightBeam.refresh()                     // Oct 16 (VIII): the beam follows what is carried/selected
    }

    /// A tool briefly shown in use (tray presentation): it appears in the right
    /// hand's place, does its small motion, and goes back into the tray.
    /// `poke`: reach toward that world point (an elevator button). Otherwise it
    /// is simply held up for `seconds` (the extinguisher, while it sprays).
    static func showInUse(_ tool: SupplyTool, poke: SCNVector3? = nil, seconds: Double = 0.45) {
        guard presentation == .tray, let handsRoot, !handsRoot.isHidden, let h = hand(1) else { return }
        h.childNode(withName: "toolInUse", recursively: false)?.removeFromParentNode()
        h.removeAllActions()
        h.eulerAngles = SCNVector3Zero
        let model = tool.makeModel()
        model.name = "toolInUse"
        let (at, target) = holdTransform(model, pose: tool.heldPose, side: 1)
        h.position = at
        h.addChildNode(model)
        model.enumerateHierarchy { n, _ in n.categoryBitMask = Menagerie.categoryBit }
        model.transform = target
        let k = tool.heldPose.scale
        model.scale = SCNVector3(k * 0.05, k * 0.05, k * 0.05)
        let grow = SCNAction.scale(to: CGFloat(k), duration: 0.12)
        grow.timingMode = .easeOut
        let hold = SCNAction.wait(duration: max(0.1, seconds - 0.3))
        let shrink = SCNAction.group([.scale(to: CGFloat(k * 0.05), duration: 0.16), .fadeOut(duration: 0.16)])
        model.runAction(.sequence([grow, hold, shrink, .removeFromParentNode()]), forKey: "inUse")
        if let poke {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { pokeRightHand(toward: poke, force: true) }
        }
    }

    /// An elevator button was pressed: a tool ALREADY in the right hand (Two
    /// Hands presentation) reaches for it -- visual only.
    /// Oct 18: in the Tool Tray presentation nothing happens. A selected tool
    /// is only selected, not held: pressing a button never brings it out into
    /// the hand or swings it (that is for real use -- the extinguisher on a
    /// fire, extinguisherInUse below).
    static func elevatorButtonPressed(at world: SCNVector3) {
        guard presentation == .hands else {
            diag("supplies.elevatorPokeSkipped", ["why": "tray: selection is not holding"])
            return
        }
        pokeRightHand(toward: world)
    }

    /// An extinguisher is spraying a fire (tray presentation: it is seen, in hand, while it does).
    static func extinguisherInUse(seconds: Double) {
        guard presentation == .tray else { return }
        if hallwayHeld { ToolTray.shared.selected = .hallwayExtinguisher }
        else if carries(.extinguisher) { ToolTray.shared.selected = .tool(.extinguisher) }
        showInUse(.extinguisher, seconds: seconds)
    }

    // MARK: Touch

    /// A node's area on screen: its projected bounds, clipped to the view, grown
    /// for a finger (and to a comfortable minimum for something in a hand).
    static func screenRect(of node: SCNNode, in view: SCNView, minimum: CGFloat) -> CGRect? {
        let (lo, hi) = node.boundingBox
        var rect = CGRect.null
        for x in [lo.x, hi.x] { for y in [lo.y, hi.y] { for z in [lo.z, hi.z] {
            let p = view.projectPoint(node.convertPosition(SCNVector3(x, y, z), to: nil))
            guard p.z > 0, p.z < 1 else { continue }
            rect = rect.union(CGRect(x: CGFloat(p.x), y: CGFloat(p.y), width: 0, height: 0))
        } } }
        guard !rect.isNull else { return nil }
        let bounds = view.bounds
        var r = rect.intersection(bounds)
        guard !r.isNull, r.width > 0 || r.height > 0 else { return nil }
        r = r.insetBy(dx: -22, dy: -22)
        if r.width < minimum { r = r.insetBy(dx: -(minimum - r.width) / 2, dy: 0) }
        if r.height < minimum { r = r.insetBy(dx: 0, dy: -(minimum - r.height) / 2) }
        return r.intersection(bounds)
    }

    /// A hand's corner of the screen (the lower outside corner, above the
    /// phone and the Settings gear, which take their own touches): wherever a
    /// held thing is drawn there, a finger anywhere in its corner finds it --
    /// the drawn shape alone proved too small a target on a device.
    private static func cornerZone(_ side: Float, in view: SCNView) -> CGRect {
        let b = view.bounds
        let w = b.width * 0.36, h = b.height * 0.34
        return CGRect(x: side > 0 ? b.maxX - w : b.minX, y: b.maxY - h - b.height * 0.06, width: w, height: h)
    }

    /// A held thing's touch area: its drawn bounds (grown) and its hand's corner.
    /// (generous: false -- a TAP -- is the drawn shape only: a tap in that corner
    /// on something in the room, a tool low on a shelf say, must reach it.)
    private static func handArea(_ model: SCNNode, side: Float, in view: SCNView, generous: Bool = true) -> CGRect {
        guard generous else { return screenRect(of: model, in: view, minimum: 0) ?? .null }
        let zone = cornerZone(side, in: view)
        guard let r = screenRect(of: model, in: view, minimum: 110) else { return zone }
        return r.union(zone)
    }

    /// The carried tool at a screen point: one in a hand, or a follower in view.
    static func tool(at point: CGPoint, in view: SCNView, generous: Bool = true) -> SupplyTool? {
        if let handsRoot, !handsRoot.isHidden, view.pointOfView === camera {
            for (tool, model) in held where model.parent != nil {
                if handArea(model, side: sides[tool] ?? 1, in: view, generous: generous).contains(point) { return tool }
            }
        }
        // (a follower: its drawn shape only -- out in front it mustn't swallow taps meant for walking)
        for (tool, root) in followers where root.parent != nil {
            if let r = screenRect(of: root, in: view, minimum: 0), r.contains(point) { return tool }
        }
        return nil
    }

    // MARK: A hallway wall extinguisher in hand

    /// Taken from its bracket (TapNavigationController.collectExtinguisherIfPresent).
    static func holdHallwayExtinguisher() {
        dropHallwayExtinguisher(animated: false)
        hallwayHeld = true
        if presentation == .tray { ToolTray.shared.selected = .hallwayExtinguisher }
        syncTray()
        if presentation == .hands { showHallwayExtinguisherInHand() }
        diag("extinguisher.taken", ["presentation": presentation.rawValue])
    }

    /// (two hands: the extinguisher drawn in the free hand)
    private static func showHallwayExtinguisherInHand() {
        let side = freeSide()
        hallwaySide = side
        guard let h = hand(side) else { return }
        let model = SupplyTool.extinguisher.makeModel()
        model.name = "hallwayExtinguisherInHand"
        let (at, target) = holdTransform(model, pose: SupplyTool.extinguisher.heldPose, side: side)
        h.position = at
        h.addChildNode(model)
        model.enumerateHierarchy { n, _ in n.categoryBitMask = Menagerie.categoryBit }
        model.transform = target
        let k = SupplyTool.extinguisher.heldPose.scale
        model.scale = SCNVector3(k * 0.05, k * 0.05, k * 0.05)
        let grow = SCNAction.scale(to: CGFloat(k), duration: 0.25)
        grow.timingMode = .easeOut
        model.runAction(grow)
        hallwayExtinguisher = model
        diag("extinguisher.inHand", ["side": side > 0 ? "right" : "left"])
    }

    /// Back on its bracket (or the floor gone): out of the hand.
    static func dropHallwayExtinguisher(animated: Bool) {
        let wasHeld = hallwayHeld
        hallwayHeld = false
        if wasHeld { syncTray() }
        guard let model = hallwayExtinguisher else { return }
        hallwayExtinguisher = nil
        model.removeAllActions()
        if animated {
            let away = SCNAction.group([.moveBy(x: 0.05, y: 0.22, z: -0.2, duration: 0.22), .fadeOut(duration: 0.22)])
            away.timingMode = .easeIn
            model.runAction(.sequence([away, .removeFromParentNode()]))
        } else {
            model.removeFromParentNode()
        }
    }

    /// Its touch area on screen (TapNavigationController.heldExtinguisherScreenRect).
    static func hallwayExtinguisherRect(in view: SCNView, generous: Bool = true) -> CGRect? {
        guard let model = hallwayExtinguisher, model.parent != nil, handsRoot?.isHidden != true,
              view.pointOfView === camera else { return nil }
        let r = handArea(model, side: hallwaySide, in: view, generous: generous)
        return r.isNull ? nil : r
    }

    /// Oct 16 (IV): an elevator button pressed with a tool in the RIGHT hand:
    /// the hand reaches a little toward that button (the tool's tip leading,
    /// tipped forward) and comes back -- about a third of a second. A visual
    /// flourish only: the press itself has already happened. Restrained: it
    /// covers at most 16 cm, however far the button is. Nothing in the right
    /// hand (or the hands put away): nothing happens.
    static func pokeRightHand(toward world: SCNVector3, force: Bool = false) {
        guard let handsRoot, !handsRoot.isHidden,
              let h = handsRoot.childNode(withName: "rightHand", recursively: false) else { return }
        let toolInHand = force || held.contains { sides[$0.key] == 1 && $0.value.parent === h } || hallwayExtinguisher?.parent === h
        guard toolInHand, h.action(forKey: "poke") == nil else { return }
        let target = handsRoot.convertPosition(world, from: nil)
        let from = h.position
        let d = SIMD3<Float>(target.x - from.x, target.y - from.y, target.z - from.z)
        let len = simd_length(d)
        guard len > 0.02 else { return }
        let step = d / len * min(len * 0.55, 0.16)
        let out = SCNAction.group([.moveBy(x: CGFloat(step.x), y: CGFloat(step.y), z: CGFloat(step.z), duration: 0.13),
                                   .rotateBy(x: -0.28, y: 0, z: 0, duration: 0.13)])
        out.timingMode = .easeOut
        let back = SCNAction.group([.moveBy(x: CGFloat(-step.x), y: CGFloat(-step.y), z: CGFloat(-step.z), duration: 0.22),
                                    .rotateBy(x: 0.28, y: 0, z: 0, duration: 0.22)])
        back.timingMode = .easeInEaseOut
        h.runAction(.sequence([out, back]), forKey: "poke")
        diag("supplies.elevatorPoke", ["reach": Double(simd_length(step))])
    }

    /// A small "no": the hands give a little shake.
    static func shake() {
        guard let handsRoot else { return }
        for h in handsRoot.childNodes {
            let a = SCNAction.moveBy(x: 0.006, y: 0, z: 0, duration: 0.05)
            h.runAction(.sequence([a, a.reversed(), a.reversed(), a, a, a.reversed()]), forKey: "shake")
        }
    }

    /// "This one": a held tool lifts a little; a follower gives a hop.
    static func nudge(_ tool: SupplyTool) {
        if let model = held[tool], let h = model.parent {
            let lift = SCNAction.moveBy(x: 0, y: 0.018, z: 0, duration: 0.12)
            lift.timingMode = .easeOut
            h.runAction(.sequence([lift, lift.reversed()]), forKey: "nudge")
        } else if let model = followers[tool]?.childNodes.first?.childNodes.first {
            let hop = SCNAction.moveBy(x: 0, y: 0.15, z: 0, duration: 0.14)
            hop.timingMode = .easeOut
            model.runAction(.sequence([hop, hop.reversed()]), forKey: "nudge")
        }
    }
}

/// The player's side: taps on tools and their places, and sending tools back.
enum Supplies {
    /// A tap on a tool (or its marked place) in the supply room.
    /// Within this (metres, level) of a tool's middle, a tap takes it where the player stands.
    static let reach: Float = 2.4

    static func toolTapped(_ tool: SupplyTool, controller c: TapNavigationController) {
        if ToolBelt.carries(tool) {                     // its own empty place: back it goes
            release(tool, controller: c)
            return
        }
        // Oct 25 (PP 3): the supply room's purpose is retired -- nothing is taken from it (a tool
        // carried from an old save can still be put back, above). The room stays as it is.
        if SuppliesShowroom.retired {
            diag("supplies.toolTapped", ["tool": tool.rawValue, "how": "retired"])
            return
        }
        if ToolBelt.isFull { refuse(tool, controller: c); return }
        let p = c.cameraNode.position
        // Oct 16 (IV): in reach -- taken where the player stands, no walk at all.
        if let centre = SuppliesShowroom.toolCentre(tool), hypotf(p.x - centre.x, p.z - centre.z) <= reach {
            take(tool, controller: c)
            diag("supplies.toolTapped", ["tool": tool.rawValue, "how": "inReach"])
            return
        }
        // Out of reach: walk to the spot in front of it (in the open middle of
        // the room, 1.5 m off the wall), turn to it, take it -- one glide that
        // stops there; a tap on the way is a brake, and cancels the take.
        let pose = SuppliesShowroom.standPose(tool, eyeY: c.cameraNode.position.y)
        let approaching = c.approachPose(kind: "supplyTool", position: pose.position, yaw: pose.yaw) { [weak c] in
            guard let c else { return }
            take(tool, controller: c)
        }
        if !approaching { c.showBrief("Can't reach that from here.") }
        diag("supplies.toolTapped", ["tool": tool.rawValue, "how": approaching ? "approach" : "unreachable"])
    }

    /// "Your hands are full." -- the tool shakes in its place (if it's one), the hands shake, a soft buzz.
    static func refuse(_ tool: SupplyTool?, controller c: TapNavigationController) {
        if let tool { SuppliesShowroom.refuse(tool) }
        ToolBelt.shake()
        SoundEffects.playWarningBuzz()
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        c.showBrief(ToolBelt.presentation == .tray ? "The tray is full." : "Your hands are full.")
        diag("supplies.refused", ["tool": tool?.rawValue ?? "wallExtinguisher", "carried": ToolBelt.carried.count,
                                  "wallExtinguisher": ToolBelt.wallExtinguisherHeld])
    }

    private static func take(_ tool: SupplyTool, controller c: TapNavigationController) {
        guard !ToolBelt.carries(tool), c.currentFloorNumber == SuppliesShowroom.floor else { return }
        if ToolBelt.isFull { refuse(tool, controller: c); return }
        // (the glide can end short -- stopped by something: then say so, take nothing)
        let p = c.cameraNode.position
        guard let centre = SuppliesShowroom.toolCentre(tool), hypotf(p.x - centre.x, p.z - centre.z) <= reach + 0.3 else {
            c.showBrief("Can't reach that from here.")
            diag("supplies.takeTooFar", ["tool": tool.rawValue]); return
        }
        let from = SuppliesShowroom.takeDisplay(tool, in: SuppliesShowroom.rootOf(c.cameraNode))
        ToolBelt.add(tool, from: from)
        _ = SoundEffects.playExtinguisherGrab()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// A tap on something carried: it answers (a lift, a hop). No words.
    /// Oct 17: in Two Hands a switchable tool (the flashlight) is switched by
    /// a tap on it in hand -- there's no tray to tap.
    static func carriedTapped(_ tool: SupplyTool) {
        if tool.isToggleable, ToolBelt.presentation == .hands {
            let t = ToolTray.shared
            t.setOn(tool, !t.isOn(tool))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        ToolBelt.nudge(tool)
    }

    /// Back to its place. False = not now (not carried; mid-spray; in the Big Shot's grip).
    @discardableResult
    static func release(_ tool: SupplyTool, controller c: TapNavigationController) -> Bool {
        guard ToolBelt.carries(tool), !c.evictionLocked else { return false }
        if tool == .extinguisher, c.isExtinguishing { ToolBelt.nudge(tool); return false }
        ToolBelt.remove(tool, root: SuppliesShowroom.rootOf(c.cameraNode))
        _ = SoundEffects.playExtinguisherGrab()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }
}

// MARK: - Oct 16 (III) -- THE IMMORTAL EXTINGUISHER: census (temporary) and camera-orphan sweep

/// TEMPORARY DIAGNOSTICS (remove once the affected save is confirmed clean).
/// After every floor build (immediately, and again 3 s later, once followers
/// have placed themselves) every extinguisher-like node in the live scene is
/// listed in the flight recorder (Settings -> Share Diagnostics) and the Xcode
/// console, one "extinguisher.census" line each: name, identity, ancestor
/// chain, position relative to the camera, and what it is (wall bracket,
/// Supplies display, held tool, follower, or ORPHAN).
enum ExtinguisherCensus {
    /// Names of nodes that are, or carry, an extinguisher model.
    private static func isCandidate(_ n: SCNNode) -> Bool {
        guard let name = n.name else { return false }
        return name == "fireExtinguisher" || name.lowercased().contains("xtinguisher")
    }

    private static func chain(_ n: SCNNode, camera: SCNNode) -> (text: String, underCamera: Bool) {
        var parts: [String] = []
        var underCamera = false
        var p = n.parent
        while let a = p, parts.count < 10 {
            if a === camera { underCamera = true; parts.append("CAMERA"); }
            else { parts.append(a.name ?? "<unnamed \(String(UInt(bitPattern: ObjectIdentifier(a).hashValue), radix: 16).suffix(5))>") }
            p = a.parent
        }
        return (parts.joined(separator: " < "), underCamera)
    }

    private static func classify(_ n: SCNNode, underCamera: Bool, controller: TapNavigationController?) -> String {
        let name = n.name ?? ""
        if ToolBelt.owns(n) {
            return name == "hallwayExtinguisherInHand" ? "held: hallway extinguisher (ToolBelt)" : "held/follower: Supplies tool (ToolBelt, carried=\(ToolBelt.carries(.extinguisher)))"
        }
        if underCamera { return "ORPHAN on the camera (no owner)" }
        if SuppliesShowroom.tool(for: n) == .extinguisher {
            let display = n.childNode(withName: "supplyDisplay_extinguisher", recursively: true)
            return "Supplies display on its bracket (tool hidden=\(display?.isHidden == true))"
        }
        if let c = controller, let coord = c.extinguisherCoordinate(for: n) { return "wall extinguisher on its bracket at \(coord.row),\(coord.col)" }
        if name == "fireExtinguisher" { return "static wall prop (no pickup; e.g. HallwayScene's old Floor 4 prototype)" }
        return "UNKNOWN owner"
    }

    static func run(_ reason: String, root: SCNNode, camera: SCNNode, controller: TapNavigationController?, floor: Int) {
        var found = 0
        var orphans = 0
        let cam = camera.presentation
        root.enumerateHierarchy { n, _ in
            guard isCandidate(n) else { return }
            // (report the outermost candidate only)
            var a = n.parent
            while let x = a { if isCandidate(x) { return }; a = x.parent }
            found += 1
            let (text, underCamera) = chain(n, camera: camera)
            let what = classify(n, underCamera: underCamera, controller: controller)
            if what.hasPrefix("ORPHAN") || what.hasPrefix("UNKNOWN") { orphans += 1 }
            let rel = cam.convertPosition(n.presentation.worldPosition, from: nil)
            let line = String(format: "%@ floor %ld | %@ #%@ | %@ | camera-relative x %.2f y %.2f z %.2f | hidden %@ | %@",
                              reason, floor, n.name ?? "?", String(String(UInt(bitPattern: ObjectIdentifier(n).hashValue), radix: 16).suffix(6)),
                              what, rel.x, rel.y, rel.z, n.isHidden ? "yes" : "no", text)
            diag("extinguisher.census", ["line": line])
            if DevLog.verbose { print("[EXTCENSUS] \(line)") }        // (Oct 18: console only on request; the recorder keeps it)
        }
        let summary = "\(reason) floor \(floor): \(found) extinguisher node(s), \(orphans) orphan/unknown; " +
            "carried=\(ToolBelt.carried.map(\.rawValue).joined(separator: ",")); hallwayInHand=\(ToolBelt.wallExtinguisherHeld); " +
            "controllerCarrying=\(controller?.carryingExtinguisher == true); posse=\(Posse.diagSummary)"
        diag("extinguisher.censusSummary", ["summary": summary])
        if DevLog.verbose { print("[EXTCENSUS] \(summary)") }
    }

    /// Narrow safety sweep: an extinguisher model hanging on the CAMERA that
    /// no current owner (ToolBelt) claims is removed -- nothing else (wall
    /// brackets, the Supplies display and followers are never touched).
    static func sweepCameraOrphans(camera: SCNNode) {
        var doomed: [SCNNode] = []
        camera.enumerateHierarchy { n, _ in
            guard isCandidate(n), !ToolBelt.owns(n) else { return }
            var a = n.parent
            while let x = a, x !== camera { if isCandidate(x) || doomed.contains(where: { $0 === x }) { return }; a = x.parent }
            doomed.append(n)
        }
        for n in doomed {
            diag("extinguisher.orphanRemoved", ["name": n.name ?? "?"])
            print("[EXTCENSUS] removed camera orphan \(n.name ?? "?")")
            n.removeAllActions()
            n.removeFromParentNode()
        }
    }
}

// MARK: - Oct 16 (V) -- THE TOOL TRAY (audition)

/// What the tray shows (driven by ToolBelt.syncTray from the inventory).
final class ToolTray: ObservableObject {
    static let shared = ToolTray()
    enum Item: Hashable {
        case tool(SupplyTool)
        case hallwayExtinguisher            // a hallway wall extinguisher, off its bracket
        var tool: SupplyTool { if case .tool(let t) = self { return t }; return .extinguisher }
        var title: String {
            switch self {
            case .tool(let t): return t.title.capitalized
            case .hallwayExtinguisher: return "Extinguisher"
            }
        }
    }
    @Published var mode: ToolBelt.Presentation =
        ToolBelt.Presentation(rawValue: UserDefaults.standard.string(forKey: ToolBelt.presentationKey) ?? "") ?? .tray
    @Published var items: [Item] = []
    /// Oct 19: the strip shows only while something is carried (an empty tray is
    /// hidden; it appears with the first item). Limits and tools are unchanged.
    var isShowing: Bool { mode == .tray && !hidden && !items.isEmpty }
    /// The tool in use (Oct 16 VI: kept across floors and relaunches -- a
    /// Supplies tool only; a hallway extinguisher belongs to its floor).
    @Published var selected: Item? = ToolTray.loadSelected() {
        didSet {
            guard selected != oldValue else { return }
            if case .tool(let t)? = selected { UserDefaults.standard.set(t.rawValue, forKey: Self.selectedKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.selectedKey) }
            // Oct 17: selecting another tool switches the old one off (tray only --
            // in Two Hands every carried tool is in hand at once).
            if mode == .tray, case .tool(let old)? = oldValue, old.isToggleable, switchedOn.contains(old) { switchedOn.remove(old) }
            FlashlightBeam.refresh()                   // Oct 16 (VIII): selecting another tool puts the beam out
        }
    }
    /// Oct 17: the toggleable tools currently switched ON (see SupplyTool.isToggleable).
    /// Kept across floors and relaunches; pruned to what is carried (and, in
    /// the tray, to the selected tool) by ToolBelt.syncTray.
    @Published var switchedOn: Set<SupplyTool> = ToolTray.loadSwitchedOn() {
        didSet {
            guard switchedOn != oldValue else { return }
            UserDefaults.standard.set(switchedOn.map(\.rawValue).sorted(), forKey: Self.switchedOnKey)
            FlashlightBeam.refresh()
        }
    }
    func isOn(_ tool: SupplyTool) -> Bool { switchedOn.contains(tool) }
    func setOn(_ tool: SupplyTool, _ on: Bool) {
        guard tool.isToggleable, on != switchedOn.contains(tool) else { return }
        if on { switchedOn.insert(tool) } else { switchedOn.remove(tool) }
        diag("tool.switched", ["tool": tool.rawValue, "on": on])
    }
    nonisolated static let switchedOnKey = "supplies.switchedOn.v1"
    /// (first launch with this build: a carried flashlight starts ON, as the beam
    /// was before switching existed -- syncTray then drops whatever doesn't apply)
    private static func loadSwitchedOn() -> Set<SupplyTool> {
        guard let raw = UserDefaults.standard.array(forKey: switchedOnKey) as? [String] else {
            return Set(SupplyTool.allCases.filter(\.isToggleable))
        }
        return Set(raw.compactMap(SupplyTool.init(rawValue:)))
    }
    /// (which RETURN offer a delayed hide belongs to)
    var returnOfferSerial = 0
    /// The slot showing its RETURN button.
    @Published var offerReturn: Item?
    @Published var hidden = false
    /// At the elevator panel: shown (dimmed) but letting every touch through to the panel.
    @Published var passThrough = false
    nonisolated static let selectedKey = "supplies.selected.v1"
    private static func loadSelected() -> Item? {
        UserDefaults.standard.string(forKey: selectedKey).flatMap(SupplyTool.init(rawValue:)).map { .tool($0) }
    }
    static let slots = 4
}

/// Miniatures of the real tool models, rendered once each (offscreen SceneKit).
enum ToolIcons {
    private static var cache: [SupplyTool: UIImage] = [:]
    private static var renderer: SCNRenderer?

    static func image(_ tool: SupplyTool) -> UIImage? {
        if let c = cache[tool] { return c }
        if renderer == nil {
            guard let device = MTLCreateSystemDefaultDevice() else { return nil }
            renderer = SCNRenderer(device: device, options: nil)
        }
        guard let renderer else { return nil }
        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        let holder = SCNNode()
        let model = tool.makeModel()
        holder.addChildNode(model)
        // A three-quarter view, the long tools laid on a slant so they fill a square.
        let long: Set<SupplyTool> = [.rake, .shovel, .broom, .stepladder, .flashlight, .screwdriver, .hammer, .wrench, .pliers, .scissors]
        model.eulerAngles = long.contains(tool) ? SCNVector3(0.15, 0.5, -0.65) : SCNVector3(0.3, 0.6, 0)
        scene.rootNode.addChildNode(holder)
        let (lo, hi) = holder.boundingBox
        let c = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        let span = max(hi.x - lo.x, hi.y - lo.y, 0.01)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.usesOrthographicProjection = true
        cam.camera?.orthographicScale = Double(span * 0.56)
        cam.camera?.zNear = 0.01
        cam.camera?.zFar = 20
        cam.position = SCNVector3(c.x, c.y, c.z + 5)
        scene.rootNode.addChildNode(cam)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 1100
        key.eulerAngles = SCNVector3(-0.7, 0.5, 0)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 650
        scene.rootNode.addChildNode(fill)
        renderer.scene = scene
        renderer.pointOfView = cam
        let shot = renderer.snapshot(atTime: 0, with: CGSize(width: 256, height: 256), antialiasingMode: .multisampling4X)
        // Oct 16 (VIII, tray readability): cropped square to the tool's own
        // pixels (plus a thin margin), so every tool fills its slot the same
        // way -- whatever its shape -- without being clipped or stretched.
        let image = trimmed(shot) ?? shot
        cache[tool] = image
        return image
    }

    /// The square around what isn't background (transparent -- or, should the
    /// renderer have filled it, the corner colour), with a 6% margin.
    private static func trimmed(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard w > 8, h > 8 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let bg = (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))
        let clearBackground = bg.3 < 8
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let a = Int(px[i + 3])
                let solid: Bool
                if clearBackground { solid = a > 12 }
                else { solid = abs(Int(px[i]) - bg.0) + abs(Int(px[i + 1]) - bg.1) + abs(Int(px[i + 2]) - bg.2) > 24 }
                if solid { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let side = Double(max(maxX - minX + 1, maxY - minY + 1))
        let full = (side * 1.12).rounded(.up)                                    // (6% each side)
        let cx = Double(minX + maxX + 1) / 2, cy = Double(minY + maxY + 1) / 2
        let rect = CGRect(x: (cx - full / 2).rounded(), y: (cy - full / 2).rounded(), width: full, height: full)
        // (drawn into a fresh square, so a crop running past the snapshot's edge pads with clear)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let out = UIGraphicsImageRenderer(size: CGSize(width: full, height: full), format: format).image { _ in
            image.draw(in: CGRect(x: -rect.minX, y: -rect.minY, width: Double(w), height: Double(h)))
        }
        return out
    }
}

/// The tray itself: a slim strip of four slots, low and centred between the
/// Settings gear and the phone. Its own touches only -- everything outside it
/// reaches the world. Tap a tool: it becomes the selected one. Tap it again:
/// a small RETURN appears above it (tap that to send it home). Or swipe a
/// tool up out of the tray to send it home straight away.
struct ToolTrayView: View {
    @ObservedObject var tray = ToolTray.shared
    let controller: TapNavigationController
    static let slot: CGFloat = 46
    static let liftAboveHUD: CGFloat = ContinuousWalkControls.rowHeight + ContinuousWalkControls.bottomPadding + 12
    /// Oct 16 (VII): the strip's vertical middle on the Settings gear's middle.
    /// The gear (PlayerSettingsButton) is 56 pt tall, ContinuousWalkControls.bottomPadding
    /// above the safe area's bottom, in the same safe-area container as the tray;
    /// the strip is a slot plus 6 pt padding above and below.
    static let gearSize: CGFloat = 56
    static let alignedWithGear: CGFloat = ContinuousWalkControls.bottomPadding + (gearSize - (slot + 12)) / 2

    var body: some View {
        if tray.isShowing {                                                   // (Oct 19: never an empty tray)
            // (re-read a few times a second, as ContinuousWalkControls does: the HUD's centre button comes and goes)
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in strip }
        }
    }

    /// The HUD's centre button (TAKE, SPRAY, PHOTO...) sits in that same bottom-
    /// centre band while it shows (or the whole LEFT/WALK/RIGHT row, with classic
    /// controls): then the tray waits just above it, as it used to.
    private var hudButtonShowing: Bool {
        guard SmartTap.isOn else { return true }
        if case .action(let label) = controller.hudCenter, !SmartTap.hiddenActionLabels.contains(label) { return true }
        return false
    }

    private var strip: some View {
        let lifted = hudButtonShowing
        return VStack {
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<ToolTray.slots, id: \.self) { i in
                        slotView(i < tray.items.count ? tray.items[i] : nil)
                    }
                }
                .padding(6)
                // Oct 16 (VIII, readability): a solid dark charcoal strip -- the
                // tools read against it over any wall, floor or light.
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color(white: 0.11).opacity(0.94)))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 1))
                .padding(.bottom, lifted ? Self.liftAboveHUD : Self.alignedWithGear)
            }
            .frame(maxWidth: .infinity)
            .opacity(tray.passThrough ? 0.55 : 1)
            .allowsHitTesting(!tray.passThrough)                          // (elevator panel: every touch is the panel's)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.18), value: tray.items)
            .animation(.easeInOut(duration: 0.15), value: tray.selected)
            .animation(.easeInOut(duration: 0.15), value: tray.switchedOn)
            .animation(.easeInOut(duration: 0.15), value: lifted)
    }

    @ViewBuilder
    private func slotView(_ item: ToolTray.Item?) -> some View {
        let isSelected = item != nil && item == tray.selected
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: item == nil ? 0.18 : (isSelected ? 0.32 : 0.24)))         // (VIII: slots stand out from the strip)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color(red: 1, green: 0.8, blue: 0.3) : Color.white.opacity(item == nil ? 0.14 : 0.28),
                        lineWidth: isSelected ? 2 : 1)
            if let item, let image = ToolIcons.image(item.tool) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(3)                                           // (VIII: the cropped icon fills ~80% of the slot)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                if case .tool(let t) = item, t.isToggleable, tray.isOn(t) {
                    // Oct 17: switched ON -- a small warm lamp in the corner.
                    Circle()
                        .fill(Color(red: 1, green: 0.84, blue: 0.4))
                        .frame(width: 6, height: 6)
                        .shadow(color: Color(red: 1, green: 0.75, blue: 0.3).opacity(0.9), radius: 3)
                        .offset(x: 16, y: -16)
                        .transition(.opacity)
                }
                if item == .hallwayExtinguisher {
                    Image(systemName: "pin.fill")                         // (off a hallway bracket)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .offset(x: 15, y: -15)
                }
            }
        }
        .frame(width: Self.slot, height: Self.slot)
        .contentShape(Rectangle())                                        // (the slot only -- RETURN above hit-tests on its own)
        .scaleEffect(isSelected ? 1.06 : 1)
        .overlay(alignment: .top) {
            if let item, tray.offerReturn == item {
                Button { send(item) } label: {
                    Label("Return", systemImage: "arrow.uturn.up")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color(red: 1, green: 0.8, blue: 0.3), in: Capsule())
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .offset(y: -40)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .accessibilityLabel("Return \(item.title)")
            }
        }
        .onTapGesture { tapped(item) }
        .gesture(DragGesture(minimumDistance: 14).onEnded { v in
            if let item, v.translation.height < -28, abs(v.translation.height) > abs(v.translation.width) { send(item) }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.map { i in
            let power: String
            if case .tool(let t) = i, t.isToggleable { power = tray.isOn(t) ? ", on" : ", off" } else { power = "" }
            return "\(i.title)\(isSelected ? ", selected" : "")\(power)"
        } ?? "Empty slot")
        .accessibilityAddTraits(item == nil ? [] : .isButton)
    }

    private func tapped(_ item: ToolTray.Item?) {
        guard let item else { tray.offerReturn = nil; return }
        // Oct 17: a switchable tool (the flashlight): the first tap selects it,
        // switched ON (and offers RETURN, as any tool does); each tap after
        // that switches it OFF/ON, staying selected. Switching it OFF offers
        // RETURN again (a natural moment to put it away); ON hides it.
        if case .tool(let t) = item, t.isToggleable {
            if tray.selected != item {
                UISelectionFeedbackGenerator().selectionChanged()
                tray.selected = item
                tray.setOn(t, true)
                offerReturn(item)
            } else {
                let on = !tray.isOn(t)
                tray.setOn(t, on)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if on { tray.offerReturn = nil } else { offerReturn(item) }
            }
            diag("tray.tap", ["item": item.title, "on": tray.isOn(t)])
            return
        }
        // Oct 16 (VI): a tap selects the tool AND shows its RETURN button just
        // above it (for 4 s) -- nothing goes home until RETURN itself is tapped.
        // A tap on the selected tool while RETURN shows hides it again.
        if tray.selected == item, tray.offerReturn == item {
            tray.offerReturn = nil
        } else {
            if tray.selected != item { UISelectionFeedbackGenerator().selectionChanged() }
            tray.selected = item
            tray.offerReturn = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if tray.offerReturn == item { tray.offerReturn = nil } }
        }
        diag("tray.tap", ["item": item.title, "selected": tray.selected?.title ?? "none"])
    }

    /// RETURN above `item` for 4 s (a later offer's own timer replaces this one's).
    private func offerReturn(_ item: ToolTray.Item) {
        tray.offerReturn = item
        tray.returnOfferSerial += 1
        let serial = tray.returnOfferSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if tray.returnOfferSerial == serial, tray.offerReturn == item { tray.offerReturn = nil }
        }
    }

    private func send(_ item: ToolTray.Item) {
        tray.offerReturn = nil
        switch item {
        case .tool(let t): _ = Supplies.release(t, controller: controller)
        case .hallwayExtinguisher: if !controller.putAwayExtinguisher() { diag("tray.returnDeclined", ["item": "hallwayExtinguisher"]) }
        }
        diag("tray.return", ["item": item.title])
    }
}

// MARK: - Oct 17 -- FLOOR 5: EIGHT WORKING CIRCUITS
//
// Floor 5 arrives dark: only the elevator, its landing, the green EXIT signs,
// three battery emergency units and a faint emergency fill. The electrical
// closet at the top of the north hall holds Panel 5A: eight real breakers,
// two columns of four, each lettered with the area it feeds. UP = ON.
// Each breaker switches the actual fixtures of its area, independently,
// as often as the player likes; the states are saved.
//
//          cols 5.........19
//    row 4        P              P   the electrical closet (circuit 2)
//    row 6     2222222           1-4 the four halls, around a loop
//    row 8     1SSSS.3.BB        S   501 SERVER ROOM   (circuit 5)
//    row 10  ELL1.....3.BB       C   502 COPY CENTER   (circuit 6)
//    row 12    1..CCC3           B   503 BREAK ROOM    (circuit 7)
//    row 14    4444444           D   504 DARKROOM      (circuit 8)
//    row 16     DD               E/L the elevator and its landing (always lit)
//
//   isolation  SceneKit lights pass through walls, so each area's geometry
//              carries its own category bit (1 << 20 ... 1 << 27) and each
//              circuit's lights skip every OTHER area's bit: a room lights
//              only itself. (Creatures and carried things keep their own bits
//              and are lit by whatever is near them, as everywhere.)
//   saved      floor5.circuits.v1 -- bit n-1 = circuit n ON; absent = all
//              off. One of ResumeState.allKeys: Start Over = the blackout.
enum FloorFiveBlackout {
    static let floor = 5
    /// Oct 25 (PP 3, the musical redesign): THE BLACKOUT IS RETIRED. Floor 5 is
    /// always fully lit: every circuit counts as ON whatever was saved (old saves
    /// with circuits off, Start Over, a fresh game), nothing is ever written to
    /// floor5.circuits.v1 again, and Panel 5A is inert (a tap on it does nothing --
    /// no cover, no breakers). The rooms, their equipment and the per-area light
    /// isolation are still built by install (residents' rooms and the decorated
    /// lights depend on them); only the darkness is gone. The types and the saved
    /// key stay until Floor 5 is rebuilt as Recording B. (false: the old mission.)
    static let retired = true
    /// Oct 16's single-breaker save: no longer read (Start Over still clears it).
    nonisolated static let restoredKey = "floor5.powerRestored.v1"
    /// Oct 17: the eight circuits (bit n-1 = circuit n ON).
    nonisolated static let circuitsKey = "floor5.circuits.v1"
    static let panelCell = GridCoordinate(row: 4, col: 12)
    /// How close (level metres, eye to the panel) the panel can be worked from.
    static let reach: Float = 2.4

    struct Circuit {
        let number: Int
        let label: String
        let cells: Set<GridCoordinate>
        /// This area's geometry category bit.
        var bit: Int { 1 << (19 + number) }
    }
    private static func block(_ rows: ClosedRange<Int>, _ cols: ClosedRange<Int>) -> Set<GridCoordinate> {
        var out = Set<GridCoordinate>()
        for r in rows { for c in cols { out.insert(GridCoordinate(row: r, col: c)) } }
        return out
    }
    /// Must match DefaultMazes.json floor 5 (install checks it does).
    static let circuits: [Circuit] = [
        Circuit(number: 1, label: "WEST HALL", cells: block(7...13, 9...9)),
        Circuit(number: 2, label: "NORTH HALL", cells: block(6...6, 9...15).union(block(4...5, 12...12))),
        Circuit(number: 3, label: "EAST HALL", cells: block(7...13, 15...15)),
        Circuit(number: 4, label: "SOUTH HALL", cells: block(14...14, 9...15)),
        Circuit(number: 5, label: "SERVER ROOM", cells: block(8...9, 11...13).union(block(8...8, 10...10))),
        Circuit(number: 6, label: "COPY CENTER", cells: block(11...12, 12...13).union(block(12...12, 14...14))),
        Circuit(number: 7, label: "BREAK ROOM", cells: block(8...10, 17...18).union(block(9...9, 16...16))),
        Circuit(number: 8, label: "DARKROOM", cells: block(16...17, 10...11).union(block(15...15, 11...11))),
    ]
    private static func circuit(at cell: GridCoordinate) -> Circuit? { circuits.first { $0.cells.contains(cell) } }
    /// Oct 17 (informants): where Panel 5A hangs in this scene (nil off Floor 5 / not built).
    static var panelWorldPosition: SCNVector3? {
        guard let panel, panel.parent != nil else { return nil }
        return panel.worldPosition
    }
    private static var allAreaBits: Int { circuits.reduce(0) { $0 | $1.bit } }

    // MARK: State

    static var savedMask: Int { UserDefaults.standard.integer(forKey: circuitsKey) }
    /// Oct 25 (PP 3): what the floor actually shows -- all eight ON while the blackout is retired,
    /// whatever savedMask says. Everything that lights, darkens or reports the floor reads this.
    static var effectiveMask: Int { retired ? 0xFF : savedMask }
    /// All eight circuits on (the locator, the emergency fill, the butterfly's concern, task.01).
    static var allPowered: Bool { effectiveMask & 0xFF == 0xFF }
    static func isOn(_ n: Int) -> Bool { effectiveMask & (1 << (n - 1)) != 0 }
    /// Tests: the emergency fill's intensity on the floor now built (nil: none built).
    static var emergencyIntensity: CGFloat? { emergency?.light?.intensity }
    private static func store(_ n: Int, on: Bool) {
        guard !retired else { return }                                    // (Oct 25: never written while retired)
        var m = savedMask
        if on { m |= 1 << (n - 1) } else { m &= ~(1 << (n - 1)) }
        UserDefaults.standard.set(m, forKey: circuitsKey)
    }

    /// One light fitting: its light sources and its glowing surfaces, each with its full value.
    private final class Fixture {
        let position: SIMD3<Float>
        var lights: [(SCNNode, CGFloat)] = []
        var glows: [(SCNMaterialProperty, CGFloat)] = []
        init(position: SIMD3<Float>) { self.position = position }
    }
    private static var fixtures: [Int: [Fixture]] = [:]
    /// What else each circuit powers (screens, LEDs, the IN USE lamp): called with on/off.
    private static var equipment: [Int: [(Bool) -> Void]] = [:]
    /// Bumped by every switching of a circuit: a delayed flicker step from an
    /// earlier switching (or an earlier visit) never lands.
    private static var generation: [Int: Int] = [:]
    private static weak var panel: SCNNode?
    private static weak var door: SCNNode?
    private static weak var closedHit: SCNNode?
    private static var levers: [Int: SCNNode] = [:]
    private static var flags: [Int: SCNMaterial] = [:]
    private static weak var emergency: SCNNode?
    /// Oct 17: the panel's red locator lamp (lit -- steady since Oct 22 -- until all eight circuits are on).
    private static var locator: IndicatorLamp?
    private static var doorOpen = false
    private static var s: Float = 3.52

    // MARK: Build

    static func install(into root: SCNNode, cellSize: CGFloat, cells floorCells: Set<GridCoordinate>,
                        elevator: GridCoordinate = MazeStore.floor2ElevatorCoordinate) {
        let needed = circuits.reduce(Set<GridCoordinate>()) { $0.union($1.cells) }
        guard needed.isSubset(of: floorCells) else {
            diag("floor5.layoutMismatch", ["cells": floorCells.count, "missing": needed.subtracting(floorCells).count]); return
        }
        s = Float(cellSize)
        fixtures = [:]; equipment = [:]; levers = [:]; flags = [:]; locator = nil
        doorOpen = false
        let group = SCNNode()
        group.name = "floorFive"
        root.addChildNode(group)
        let landing = collectFixtures(root, elevator: elevator)
        buildCommon(in: group)
        buildServerRoom(in: group)
        buildCopyCenter(in: group)
        buildBreakRoom(in: group)
        buildDarkroom(in: group)
        buildPanel(in: group)
        let tagged = isolateAreas(root, landing: landing)
        let fill = SCNNode()
        fill.name = "floorFiveEmergencyFill"                 // (in the floor's group: never the root ambient a ride brightens)
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.color = UIColor(red: 0.55, green: 0.62, blue: 0.8, alpha: 1)
        fill.light?.intensity = 0
        group.addChildNode(fill)
        emergency = fill
        for c in circuits { setPowered(c.number, isOn(c.number), animated: false) }
        updateEmergency(animated: false)
        diag("floor5.installed", ["mask": savedMask, "retired": retired, "shown": effectiveMask, "fixtures": fixtures.values.reduce(0) { $0 + $1.count },
                                  "tagged": tagged, "landingLights": landing.count])
    }

    /// The building's own fittings, by circuit (from where they hang). The
    /// elevator's (cab and landing) are returned apart: always on.
    private static func collectFixtures(_ root: SCNNode, elevator: GridCoordinate) -> [SCNLight] {
        var landing: [SCNLight] = []
        var byOwner: [ObjectIdentifier: Fixture] = [:]
        root.enumerateHierarchy { n, _ in
            guard let light = n.light, light.type != .ambient else { return }
            var inCab = false
            var a: SCNNode? = n
            while let x = a {
                if x.camera != nil { return }                                     // (the flashlight)
                if (x.name ?? "").hasPrefix("elevatorCab") { inCab = true }
                a = x.parent
            }
            if inCab { landing.append(light); return }
            var found: SCNNode?
            var p: SCNNode? = n
            while let x = p {
                let name = x.name ?? ""
                // Oct 17: + picture lights and floor lamps -- every electric light the
                // decorator can place follows the breaker of the area it's in.
                if name == "authored_fluorescent" || name.hasPrefix("wallLight_")
                    || name == "pictureLight" || name == "furnitureFloorLamp" { found = x; break }
                if name.hasPrefix("authored_ceiling") { found = x.parent ?? x; break }
                p = x.parent
            }
            guard let owner = found else { return }                               // (never a critter's lamp)
            let w = owner.worldPosition
            let cell = GridCoordinate(row: Int((w.z / s).rounded()), col: Int((w.x / s).rounded()))
            if cell == elevator { landing.append(light); return }
            // Oct 17: outside all eight areas (the elevator vestibule): always on, like
            // the elevator's own -- and kept off the areas' surfaces, so it can't light
            // a hall whose breaker is off.
            guard let c = circuit(at: cell) else { landing.append(light); return }
            let key = ObjectIdentifier(owner)
            let fixture: Fixture
            if let f = byOwner[key] {
                fixture = f
            } else {
                fixture = Fixture(position: SIMD3(w.x, w.y, w.z))
                owner.enumerateHierarchy { g, _ in
                    for m in g.geometry?.materials ?? [] {
                        if m.emission.contents != nil { fixture.glows.append((m.emission, m.emission.intensity)) }
                        if m.lightingModel == .constant { fixture.glows.append((m.diffuse, m.diffuse.intensity)) }
                    }
                }
                byOwner[key] = fixture
                fixtures[c.number, default: []].append(fixture)
            }
            fixture.lights.append((n, light.intensity))
        }
        return landing
    }

    /// Each area's surfaces take its circuit's bit (and lose the default one);
    /// each circuit's lights skip the other areas'; the elevator's skip them all.
    /// Returns how many nodes were tagged.
    private static func isolateAreas(_ root: SCNNode, landing: [SCNLight]) -> Int {
        let all = allAreaBits
        var tagged = 0
        root.enumerateHierarchy { n, _ in
            guard n.geometry != nil, n.categoryBitMask == 1 else { return }       // (special nodes keep theirs)
            var a: SCNNode? = n
            while let x = a {
                if x.camera != nil || (x.name ?? "").hasPrefix("elevatorCab") { return }
                a = x.parent
            }
            let (lo, hi) = n.boundingBox
            let w0 = n.convertPosition(lo, to: nil), w1 = n.convertPosition(hi, to: nil)
            guard abs(w1.x - w0.x) < s * 1.5, abs(w1.z - w0.z) < s * 1.5 else { return }   // (anything bigger than a cell: left alone)
            let mx = (w0.x + w1.x) / 2, mz = (w0.z + w1.z) / 2
            var bits = 0
            let c0 = Int((mx / s - 0.6).rounded(.down)), c1 = Int((mx / s + 0.6).rounded(.up))
            let r0 = Int((mz / s - 0.6).rounded(.down)), r1 = Int((mz / s + 0.6).rounded(.up))
            for r in r0...r1 {
                for c in c0...c1 where abs(mx - Float(c) * s) <= s / 2 + 0.12 && abs(mz - Float(r) * s) <= s / 2 + 0.12 {
                    if let area = circuit(at: GridCoordinate(row: r, col: c)) { bits |= area.bit }
                }
            }
            guard bits != 0 else { return }
            n.categoryBitMask = bits
            tagged += 1
        }
        for c in circuits {
            let mask = ~(all & ~c.bit)
            for f in fixtures[c.number] ?? [] { for (l, _) in f.lights { l.light?.categoryBitMask = mask } }
        }
        for l in landing { l.categoryBitMask = ~all }
        return tagged
    }

    // MARK: Helpers

    private static func mat(_ c: UIColor, metal: CGFloat = 0, rough: CGFloat = 0.6) -> SCNMaterial { SupplyModels.mat(c, metal: metal, rough: rough) }
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }

    private static func textImage(_ text: String, size: CGSize, ground: UIColor, ink: UIColor, heavy: Bool = false) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            ground.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let style = NSMutableParagraphStyle(); style.alignment = .center
            func face(_ pt: CGFloat) -> UIFont {
                if heavy { return UIFont.systemFont(ofSize: pt, weight: .black) }      // (Oct 17: the panel's own cards -- big, bold, black)
                return UIFont(name: "DINCondensed-Bold", size: pt) ?? UIFont.systemFont(ofSize: pt, weight: .heavy)
            }
            // (as big as fits: 62% of the height -- 74% heavy -- or smaller if the words are wider than the label)
            var pt = size.height * (heavy ? 0.74 : 0.62)
            let wide = (text as NSString).size(withAttributes: [.font: face(pt), .kern: pt * 0.08]).width
            if wide > size.width * 0.92 { pt *= size.width * 0.92 / wide }
            let font = face(pt)
            let h = font.lineHeight
            (text as NSString).draw(in: CGRect(x: 0, y: (size.height - h) / 2 + size.height * 0.06, width: size.width, height: h),
                                    withAttributes: [.font: font, .foregroundColor: ink, .paragraphStyle: style, .kern: pt * 0.08])
        }
    }

    /// A small printed label.
    private static func label(_ text: String, size: CGSize, ground: UIColor, ink: UIColor, heavy: Bool = false) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = textImage(text, size: size, ground: ground, ink: ink, heavy: heavy)
        m.roughness.contents = heavy ? 0.95 : 0.6                   // (paper cards: matte, no glare under a torch)
        return m
    }

    /// A flat printed sign `w` x `h` m (text drawn at 2000 px per metre, at most 2048 px wide).
    @discardableResult
    private static func sign(_ text: String, _ w: Float, _ h: Float, ground: UIColor, ink: UIColor, heavy: Bool = false,
                             in parent: SCNNode, at p: SCNVector3) -> SCNNode {
        let density = min(2000, 2048 / CGFloat(max(w, h)))
        return SupplyModels.part(SCNPlane(width: CGFloat(w), height: CGFloat(h)),
                                 label(text, size: CGSize(width: CGFloat(w) * density, height: CGFloat(h) * density), ground: ground, ink: ink,
                                       heavy: heavy),
                                 in: parent, at: p)
    }

    private static func power(_ n: Int, _ apply: @escaping (Bool) -> Void) { equipment[n, default: []].append(apply) }

    /// A self-lit surface on circuit n: `lit` while it is powered, `dark` otherwise.
    private static func lamp(_ n: Int, _ lit: UIColor, dark: UIColor = UIColor(white: 0.05, alpha: 1)) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = dark
        power(n) { on in m.diffuse.contents = on ? lit : dark }
        return m
    }

    /// A display on circuit n showing `text` while powered (blinking, if asked); a dead dark glass otherwise.
    @discardableResult
    private static func screen(_ n: Int, _ text: String, _ w: Float, _ h: Float, ink: UIColor, blink: Bool = false,
                               in parent: SCNNode, at p: SCNVector3, euler: SCNVector3 = SCNVector3Zero) -> SCNNode {
        let m = SCNMaterial()
        m.lightingModel = .constant
        let dark = UIColor(white: 0.04, alpha: 1)
        let image = textImage(text, size: CGSize(width: CGFloat(w) * 1600, height: CGFloat(h) * 1600), ground: UIColor(white: 0.03, alpha: 1), ink: ink)
        m.diffuse.contents = dark
        let node = SupplyModels.part(SCNPlane(width: CGFloat(w), height: CGFloat(h)), m, in: parent, at: p, euler: euler)
        power(n) { on in
            m.diffuse.contents = on ? image : dark
            if on, blink {
                node.runAction(.repeatForever(.sequence([.wait(duration: 0.55), .hide(), .wait(duration: 0.45), .unhide()])), forKey: "blink")
            } else {
                node.removeAction(forKey: "blink")
                node.isHidden = false
            }
        }
        return node
    }

    /// A node on a cell's wall: `cell`'s `wall` face, `along` it (to the right
    /// as you face it), at height y, `out` from the face. Local +Z faces the room.
    private static func onWall(_ cell: GridCoordinate, _ wall: Direction, along: Float = 0, y: Float = 0, out: Float = 0, in parent: SCNNode) -> SCNNode {
        let cx = Float(cell.col) * s, cz = Float(cell.row) * s, h = s / 2 - 0.05
        let n = SCNNode()
        switch wall {
        case .north: n.position = SCNVector3(cx + along, y, cz - h + out); n.eulerAngles.y = 0
        case .south: n.position = SCNVector3(cx - along, y, cz + h - out); n.eulerAngles.y = .pi
        case .east: n.position = SCNVector3(cx + h - out, y, cz + along); n.eulerAngles.y = -.pi / 2
        case .west: n.position = SCNVector3(cx - h + out, y, cz - along); n.eulerAngles.y = .pi / 2
        }
        parent.addChildNode(n)
        return n
    }
    private static func g(_ r: Int, _ c: Int) -> GridCoordinate { GridCoordinate(row: r, col: c) }

    /// A room's name plate on the corridor side, beside its door.
    private static func placard(_ number: String, _ name: String, note: String? = nil, cell: GridCoordinate, wall: Direction, in parent: SCNNode) {
        let p = onWall(cell, wall, along: 0.9, y: 1.55, out: 0.015, in: parent)
        SupplyModels.box(0.36, 0.14, 0.012, mat(rgb(0.16, 0.18, 0.2), metal: 0.4, rough: 0.4), in: p, at: SCNVector3(0, 0, 0.006), chamfer: 0.004)
        sign(number, 0.1, 0.1, ground: rgb(0.16, 0.18, 0.2), ink: UIColor(white: 0.95, alpha: 1), in: p, at: SCNVector3(-0.12, 0, 0.0125))
        sign(name, 0.22, 0.07, ground: rgb(0.16, 0.18, 0.2), ink: UIColor(white: 0.95, alpha: 1), in: p, at: SCNVector3(0.06, 0, 0.0125))
        if let note {
            sign(note, 0.36, 0.045, ground: rgb(0.75, 0.1, 0.08), ink: .white, in: p, at: SCNVector3(0, -0.11, 0.004))
        }
    }

    // MARK: The halls and the closet

    private static func buildCommon(in group: SCNNode) {
        let B = SupplyModels.self
        // ELECTRICAL, over the closet's opening (facing the north hall).
        let over = SCNNode()
        over.position = SCNVector3(12 * s, 2.55, 5.5 * s)
        group.addChildNode(over)
        sign("\u{26A1} ELECTRICAL", 1.0, 0.22, ground: rgb(0.98, 0.8, 0.15), ink: UIColor(white: 0.08, alpha: 1), in: over, at: SCNVector3Zero)
        B.rod(0.004, 0.33, B.darkSteel, in: over, at: SCNVector3(-0.4, 0.275, 0))
        B.rod(0.004, 0.33, B.darkSteel, in: over, at: SCNVector3(0.4, 0.275, 0))
        // The closet: conduit up from the panel, a cable raceway, a stepladder hook, a mop sink's pipes.
        let conduit = onWall(panelCell, .north, out: 0.04, in: group)
        B.rod(0.022, 1.0, B.galvanized, in: conduit, at: SCNVector3(-0.25, 2.5, 0))
        B.rod(0.022, 1.0, B.galvanized, in: conduit, at: SCNVector3(0.25, 2.5, 0))
        B.rod(0.03, 1.4, B.galvanized, in: conduit, at: SCNVector3(0.75, 2.3, 0))
        let copper = mat(rgb(0.75, 0.45, 0.28), metal: 1, rough: 0.35)
        for (wall, along) in [(Direction.east, Float(-0.9)), (.west, Float(0.9))] {
            let p = onWall(g(5, 12), wall, along: along, out: 0.06, in: group)
            B.rod(0.03, 3.0, copper, in: p, at: SCNVector3(0, 1.5, 0))
            B.rod(0.045, 3.0, mat(rgb(0.25, 0.4, 0.3), metal: 0.3, rough: 0.5), in: p, at: SCNVector3(0.16, 1.5, 0.02))
        }
        // A yellow-and-black warning stripe on the closet floor.
        let stripe = onWall(panelCell, .north, out: 0.9, in: group)
        B.box(1.2, 0.004, 0.08, mat(rgb(0.95, 0.75, 0.1), rough: 0.7), in: stripe, at: SCNVector3(0, 0.002, 0), chamfer: 0)
        // Battery emergency units ("bug-eyes"): always lit, the faint light you navigate the dark by.
        let lampLit = SCNMaterial(); lampLit.lightingModel = .constant; lampLit.diffuse.contents = rgb(1, 0.93, 0.75)
        let red = SCNMaterial(); red.lightingModel = .constant; red.diffuse.contents = rgb(1, 0.1, 0.05)
        for (cell, wall) in [(g(10, 8), Direction.south), (g(6, 15), .east), (g(14, 9), .west), (g(13, 15), .east)] {
            let u = onWall(cell, wall, y: 2.55, out: 0.05, in: group)
            B.box(0.34, 0.12, 0.09, mat(rgb(0.9, 0.88, 0.82), rough: 0.5), in: u, at: SCNVector3Zero, chamfer: 0.01)
            for x in [Float(-0.12), 0.12] {
                _ = B.part(SCNSphere(radius: 0.045), lampLit, in: u, at: SCNVector3(x, -0.05, 0.07))
            }
            _ = B.part(SCNSphere(radius: 0.006), red, in: u, at: SCNVector3(0, 0, 0.047))
        }
        // The rooms' name plates (the break room's is lettered over its glass doors).
        placard("501", "SERVER ROOM", note: "AUTHORIZED PERSONNEL ONLY", cell: g(8, 9), wall: .east, in: group)
        placard("502", "COPY CENTER", cell: g(12, 15), wall: .west, in: group)
        placard("504", "DARKROOM", note: "DO NOT OPEN WHEN LIT", cell: g(14, 11), wall: .south, in: group)
        // ...and the darkroom's IN USE lamp, on its own circuit.
        let inUse = onWall(g(14, 11), .south, along: 0.9, y: 2.0, out: 0.015, in: group)
        B.box(0.32, 0.13, 0.08, mat(UIColor(white: 0.1, alpha: 1), metal: 0.4, rough: 0.4), in: inUse, at: SCNVector3(0, 0, 0.04), chamfer: 0.01)
        screen(8, "IN USE", 0.28, 0.1, ink: rgb(1, 0.15, 0.08), in: inUse, at: SCNVector3(0, 0, 0.081))
    }

    // MARK: 501 -- the server room (circuit 5)

    private static func buildServerRoom(in group: SCNNode) {
        let B = SupplyModels.self
        var rng = Rand(seed: 501)
        let black = mat(UIColor(white: 0.07, alpha: 1), metal: 0.4, rough: 0.45)
        let unitMats = [mat(UIColor(white: 0.18, alpha: 1), metal: 0.5, rough: 0.4), mat(UIColor(white: 0.26, alpha: 1), metal: 0.6, rough: 0.35),
                        mat(rgb(0.15, 0.17, 0.22), metal: 0.5, rough: 0.4)]
        let green = rgb(0.2, 1, 0.35), amber = rgb(1, 0.65, 0.1), blue = rgb(0.3, 0.6, 1)
        // Six racks along the north wall, humming with LEDs once the room has power.
        for col in 11...13 {
            for along in [Float(-0.45), 0.45] {
                let rack = onWall(g(8, col), .north, along: along, out: 0.55, in: group)
                B.box(0.6, 2.0, 1.0, black, in: rack, at: SCNVector3(0, 1.0, 0), chamfer: 0.01)
                let leds = SCNNode()
                rack.addChildNode(leds)
                power(5) { on in leds.isHidden = !on }
                for u in 0..<8 {
                    let y = 0.3 + Float(u) * 0.19
                    B.box(0.52, 0.15, 0.02, unitMats[(u + col) % unitMats.count], in: rack, at: SCNVector3(0, y, 0.505), chamfer: 0.003)
                    B.box(0.3, 0.01, 0.005, mat(UIColor(white: 0.05, alpha: 1)), in: rack, at: SCNVector3(-0.06, y - 0.03, 0.517), chamfer: 0)   // (a vent slot)
                    for (i, colour) in [green, u % 3 == 0 ? amber : green, blue].enumerated() {
                        let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = colour
                        let led = B.box(0.012, 0.012, 0.006, m, in: leds, at: SCNVector3(0.17 + Float(i) * 0.025, y + 0.035, 0.517), chamfer: 0)
                        if i != 2, rng.unit() < 0.6 {
                            let on = Double(rng.range(0.05, 0.4)), off = Double(rng.range(0.03, 0.25))
                            led.runAction(.repeatForever(.sequence([.wait(duration: on), .hide(), .wait(duration: off), .unhide()])))
                        }
                    }
                }
            }
            // Its share of the overhead cable tray, and cables dropping into the racks.
            let tray = onWall(g(8, col), .north, y: 2.6, out: 0.55, in: group)
            B.box(s - 0.02, 0.06, 0.4, mat(rgb(0.95, 0.78, 0.15), metal: 0.5, rough: 0.5), in: tray, at: SCNVector3Zero, chamfer: 0)
            for x in [Float(-0.55), -0.35, 0.35, 0.55] {
                B.rod(0.012, 0.6, mat(UIColor(white: 0.04, alpha: 1), rough: 0.7), in: tray, at: SCNVector3(x, -0.3, 0.1))
            }
        }
        // East wall: the clean-agent fire suppression cylinder (8,13) and the CRAC unit (9,13).
        let tank = onWall(g(8, 13), .east, along: -0.6, out: 0.3, in: group)
        B.rod(0.2, 1.3, mat(rgb(0.75, 0.08, 0.06), metal: 0.3, rough: 0.35), in: tank, at: SCNVector3(0, 0.65, 0))
        _ = B.part(SCNSphere(radius: 0.2), mat(rgb(0.75, 0.08, 0.06), metal: 0.3, rough: 0.35), in: tank, at: SCNVector3(0, 1.3, 0))
        B.rod(0.05, 0.12, B.chrome, in: tank, at: SCNVector3(0, 1.52, 0))
        _ = B.part(SCNCylinder(radius: 0.045, height: 0.02), mat(.white, rough: 0.3), in: tank, at: SCNVector3(0, 1.58, 0.06), euler: SCNVector3(Float.pi / 2, 0, 0))
        sign("CLEAN AGENT FIRE SUPPRESSION", 0.6, 0.12, ground: rgb(0.75, 0.08, 0.06), ink: .white, in: onWall(g(8, 13), .east, along: -0.6, y: 1.95, out: 0.01, in: group), at: SCNVector3Zero)
        let crac = onWall(g(9, 13), .east, along: 0.2, out: 0.45, in: group)
        B.box(1.5, 1.9, 0.85, mat(rgb(0.82, 0.8, 0.74), metal: 0.2, rough: 0.5), in: crac, at: SCNVector3(0, 0.95, 0), chamfer: 0.01)
        for i in 0..<9 { B.box(1.3, 0.03, 0.01, mat(UIColor(white: 0.3, alpha: 1), rough: 0.6), in: crac, at: SCNVector3(0, 0.25 + Float(i) * 0.08, 0.43), chamfer: 0) }
        sign("LIEBMANN  COOLING", 0.5, 0.06, ground: rgb(0.82, 0.8, 0.74), ink: rgb(0.1, 0.2, 0.45), in: crac, at: SCNVector3(-0.3, 1.75, 0.428))
        screen(5, "21.0\u{00B0}C   45% RH", 0.36, 0.1, ink: rgb(0.3, 1, 0.9), in: crac, at: SCNVector3(0.35, 1.45, 0.428))
        // The crash cart (south wall of (9,11)): a terminal waiting for a login.
        let cart = onWall(g(9, 11), .south, along: 0.3, out: 0.35, in: group)
        let cartMetal = mat(UIColor(white: 0.55, alpha: 1), metal: 0.8, rough: 0.35)
        B.box(0.75, 0.03, 0.55, cartMetal, in: cart, at: SCNVector3(0, 0.95, 0), chamfer: 0)
        B.box(0.75, 0.03, 0.55, cartMetal, in: cart, at: SCNVector3(0, 0.25, 0), chamfer: 0)
        for x in [Float(-0.35), 0.35] { for z in [Float(-0.25), 0.25] { B.rod(0.012, 0.9, cartMetal, in: cart, at: SCNVector3(x, 0.55, z)) } }
        B.box(0.45, 0.38, 0.4, mat(rgb(0.85, 0.83, 0.76), rough: 0.5), in: cart, at: SCNVector3(0, 1.16, -0.03), chamfer: 0.03)   // a CRT
        screen(5, "login: _", 0.34, 0.26, ink: rgb(0.3, 1, 0.4), blink: true, in: cart, at: SCNVector3(0, 1.17, 0.172))
        B.box(0.45, 0.025, 0.15, mat(rgb(0.85, 0.83, 0.76), rough: 0.5), in: cart, at: SCNVector3(0, 0.98, 0.2), chamfer: 0.005)   // keyboard
        // A lifted floor tile, leaning on the wall with its suction puller.
        let tile = onWall(g(9, 12), .south, along: -0.8, out: 0.12, in: group)
        B.box(0.6, 0.6, 0.035, mat(UIColor(white: 0.7, alpha: 1), rough: 0.6), in: tile, at: SCNVector3(0, 0.3, 0), euler: SCNVector3(-0.15, 0, 0), chamfer: 0.004)
        B.box(0.12, 0.05, 0.05, mat(rgb(0.9, 0.3, 0.1), rough: 0.4), in: tile, at: SCNVector3(0, 0.4, 0.06), chamfer: 0.01)
        // Inside the door: the house rules.
        sign("NO FOOD OR DRINK BEYOND THIS POINT", 0.7, 0.1, ground: .white, ink: rgb(0.7, 0.05, 0.05), in: onWall(g(8, 10), .north, y: 1.6, out: 0.01, in: group), at: SCNVector3Zero)
    }

    // MARK: 502 -- the copy center (circuit 6)

    private static func buildCopyCenter(in group: SCNNode) {
        let B = SupplyModels.self
        let shell = mat(rgb(0.86, 0.85, 0.82), metal: 0.1, rough: 0.45)
        let charcoal = mat(UIColor(white: 0.2, alpha: 1), rough: 0.45)
        let paper = mat(UIColor(white: 0.96, alpha: 1), rough: 0.8)
        // The big floor copier (north wall of (11,12)).
        let big = onWall(g(11, 12), .north, out: 0.42, in: group)
        B.box(1.4, 0.95, 0.75, shell, in: big, at: SCNVector3(0, 0.475, 0), chamfer: 0.02)
        for i in 0..<4 { B.box(1.3, 0.005, 0.01, charcoal, in: big, at: SCNVector3(0, 0.12 + Float(i) * 0.17, 0.376), chamfer: 0) }   // paper drawers
        let lidHinge = SCNNode()                                                                                                  // the lid, propped open
        lidHinge.position = SCNVector3(0, 0.95, -0.375)
        lidHinge.eulerAngles.x = -1.15
        big.addChildNode(lidHinge)
        B.box(1.4, 0.05, 0.75, charcoal, in: lidHinge, at: SCNVector3(0, 0.025, 0.375), chamfer: 0.01)
        let platen = SCNMaterial(); platen.lightingModel = .physicallyBased; platen.diffuse.contents = UIColor(white: 0.15, alpha: 0.35)
        platen.roughness.contents = 0.05
        B.box(1.2, 0.006, 0.6, platen, in: big, at: SCNVector3(0, 0.962, 0), chamfer: 0)                                          // the glass
        B.box(0.55, 0.8, 0.6, shell, in: big, at: SCNVector3(0.98, 0.4, 0), chamfer: 0.02)                                          // finisher
        for i in 0..<3 { B.box(0.3, 0.01, 0.35, paper, in: big, at: SCNVector3(1.35, 0.55 + Float(i) * 0.012, 0), euler: SCNVector3(0, 0, -0.12), chamfer: 0) }
        let panelNode = SCNNode()
        panelNode.position = SCNVector3(0.45, 1.05, 0.3)
        panelNode.eulerAngles.x = -0.6
        big.addChildNode(panelNode)
        B.box(0.42, 0.04, 0.2, charcoal, in: panelNode, at: SCNVector3Zero, chamfer: 0.01)
        screen(6, "READY", 0.2, 0.1, ink: rgb(0.4, 0.85, 1), in: panelNode, at: SCNVector3(-0.07, 0.021, 0), euler: SCNVector3(-Float.pi / 2, 0, 0))
        let start = SCNMaterial(); start.lightingModel = .constant; start.diffuse.contents = UIColor(white: 0.1, alpha: 1)
        power(6) { on in start.diffuse.contents = on ? rgb(0.2, 1, 0.3) : UIColor(white: 0.1, alpha: 1) }
        B.box(0.06, 0.02, 0.06, start, in: panelNode, at: SCNVector3(0.14, 0.025, 0), chamfer: 0.01)
        // The scanner lamp, sweeping under the glass while it has power.
        let scan = SCNMaterial(); scan.lightingModel = .constant; scan.diffuse.contents = rgb(0.75, 1, 0.85)
        let bar = B.box(0.03, 0.006, 0.58, scan, in: big, at: SCNVector3(-0.56, 0.955, 0), chamfer: 0)
        bar.runAction(.repeatForever(.sequence([.wait(duration: 2.5), .moveBy(x: 1.12, y: 0, z: 0, duration: 1.4),
                                                .moveBy(x: -1.12, y: 0, z: 0, duration: 0.6)])))
        power(6) { on in bar.isHidden = !on }
        // The little copier (north wall of (11,13)): jammed, and saying so.
        let small = onWall(g(11, 13), .north, along: 0.4, out: 0.38, in: group)
        B.box(0.8, 0.7, 0.6, charcoal, in: small, at: SCNVector3(0, 0.35, 0), chamfer: 0.01)
        B.box(0.75, 0.45, 0.6, shell, in: small, at: SCNVector3(0, 0.93, 0), chamfer: 0.02)
        screen(6, "JAM  E-073", 0.22, 0.07, ink: rgb(1, 0.7, 0.15), blink: true, in: small, at: SCNVector3(0.2, 1.08, 0.302))
        B.box(0.21, 0.004, 0.3, paper, in: small, at: SCNVector3(-0.25, 0.86, 0.35), euler: SCNVector3(0.35, 0, 0.1), chamfer: 0)   // the jam
        sign("OUT OF ORDER  \u{2014}  AGAIN", 0.3, 0.12, ground: rgb(1, 0.97, 0.6), ink: UIColor(white: 0.1, alpha: 1), in: small, at: SCNVector3(-0.15, 1.0, 0.302))
        // Shelving: reams and toner (south wall of (12,12)).
        let shelf = onWall(g(12, 12), .south, out: 0.25, in: group)
        let steel = mat(UIColor(white: 0.6, alpha: 1), metal: 0.7, rough: 0.4)
        for i in 0..<4 { B.box(1.6, 0.03, 0.45, steel, in: shelf, at: SCNVector3(0, 0.15 + Float(i) * 0.5, 0), chamfer: 0) }
        for x in [Float(-0.78), 0.78] { for z in [Float(-0.2), 0.2] { B.box(0.03, 1.8, 0.03, steel, in: shelf, at: SCNVector3(x, 0.9, z), chamfer: 0) } }
        let wraps = [rgb(0.95, 0.95, 0.92), rgb(0.6, 0.8, 1), rgb(1, 0.85, 0.5), rgb(0.95, 0.6, 0.7)]
        for level in 0..<3 {
            for k in 0..<5 {
                let h: Float = 0.06 * Float(1 + (k + level) % 3)
                B.box(0.3, h, 0.22, mat(wraps[(k + level) % wraps.count], rough: 0.8), in: shelf,
                      at: SCNVector3(-0.62 + Float(k) * 0.31, 0.165 + Float(level) * 0.5 + h / 2, 0), chamfer: 0.004)
            }
        }
        for k in 0..<3 { B.box(0.38, 0.2, 0.3, mat(rgb(0.15, 0.15, 0.17), rough: 0.6), in: shelf, at: SCNVector3(-0.45 + Float(k) * 0.45, 1.765, 0), chamfer: 0.005) }
        // A worktable with a paper cutter (west wall of (11,12), south end).
        let table = onWall(g(11, 12), .west, along: -0.75, out: 0.35, in: group)
        B.box(1.2, 0.04, 0.6, mat(rgb(0.7, 0.6, 0.45), rough: 0.6), in: table, at: SCNVector3(0, 0.76, 0), chamfer: 0.005)
        for x in [Float(-0.55), 0.55] { for z in [Float(-0.25), 0.25] { B.box(0.04, 0.74, 0.04, steel, in: table, at: SCNVector3(x, 0.37, z), chamfer: 0) } }
        B.box(0.45, 0.02, 0.4, mat(rgb(0.25, 0.45, 0.3), rough: 0.6), in: table, at: SCNVector3(-0.25, 0.79, 0), chamfer: 0)
        B.box(0.48, 0.015, 0.03, B.chrome, in: table, at: SCNVector3(-0.25, 0.86, 0.2), euler: SCNVector3(0, 0, 0.35), chamfer: 0)    // the blade
        for i in 0..<6 { B.box(0.21, 0.01, 0.29, paper, in: table, at: SCNVector3(0.3, 0.79 + Float(i) * 0.011, 0), euler: SCNVector3(0, Float(i) * 0.03, 0), chamfer: 0) }
        // Recycling, and the eternal request.
        let bin = onWall(g(12, 13), .south, along: 0.9, out: 0.3, in: group)
        _ = B.part(SCNCylinder(radius: 0.22, height: 0.62), mat(rgb(0.15, 0.35, 0.8), rough: 0.5), in: bin, at: SCNVector3(0, 0.31, 0))
        for k in 0..<4 { _ = B.part(SCNSphere(radius: 0.06), paper, in: bin, at: SCNVector3(-0.08 + Float(k % 2) * 0.14, 0.64 + Float(k / 2) * 0.04, -0.05 + Float(k % 3) * 0.05)) }
        sign("PLEASE REMOVE YOUR ORIGINALS", 0.6, 0.1, ground: .white, ink: UIColor(white: 0.1, alpha: 1), in: onWall(g(11, 13), .east, y: 1.6, out: 0.01, in: group), at: SCNVector3Zero)
    }

    // MARK: 503 -- the break room (circuit 7)

    private static func buildBreakRoom(in group: SCNNode) {
        let B = SupplyModels.self
        // Vending machine (north wall of (8,17)): its lit window and keypad come on with the room.
        let vend = onWall(g(8, 17), .north, along: -0.3, out: 0.45, in: group)
        // (the cabinet's back half, then the frame round the window: the window is recessed 0.25 m)
        let red = mat(rgb(0.62, 0.1, 0.1), metal: 0.3, rough: 0.35)
        B.box(1.0, 1.85, 0.55, red, in: vend, at: SCNVector3(0, 0.925, -0.125), chamfer: 0.02)
        B.box(1.0, 0.56, 0.25, red, in: vend, at: SCNVector3(0, 0.28, 0.275), chamfer: 0.01)          // below the window
        B.box(1.0, 0.11, 0.25, red, in: vend, at: SCNVector3(0, 1.795, 0.275), chamfer: 0.01)         // above it
        B.box(0.06, 1.18, 0.25, red, in: vend, at: SCNVector3(-0.47, 1.15, 0.275), chamfer: 0)        // its left post
        B.box(0.3, 1.18, 0.25, red, in: vend, at: SCNVector3(0.35, 1.15, 0.275), chamfer: 0)          // the keypad column
        B.box(0.64, 1.18, 0.01, lamp(7, rgb(0.85, 0.9, 1), dark: UIColor(white: 0.06, alpha: 1)), in: vend, at: SCNVector3(-0.12, 1.15, 0.156), chamfer: 0)
        let glass = SCNMaterial(); glass.lightingModel = .physicallyBased; glass.diffuse.contents = UIColor(white: 0.2, alpha: 0.18)
        glass.metalness.contents = 0.0; glass.roughness.contents = 0.05; glass.isDoubleSided = false
        B.box(0.66, 1.2, 0.01, glass, in: vend, at: SCNVector3(-0.12, 1.15, 0.405), chamfer: 0)
        let snackColours: [UIColor] = [.systemYellow, .systemBlue, .systemOrange, .systemGreen, .systemPurple]
        for i in 0..<4 {
            B.box(0.6, 0.015, 0.22, mat(UIColor(white: 0.5, alpha: 1), metal: 0.6, rough: 0.4), in: vend, at: SCNVector3(-0.12, 0.66 + Float(i) * 0.27, 0.27))
            for j in 0..<4 {
                B.box(0.1, 0.16, 0.05, mat(snackColours[(i * 2 + j) % snackColours.count], rough: 0.4), in: vend,
                      at: SCNVector3(-0.33 + Float(j) * 0.14, 0.75 + Float(i) * 0.27, 0.3))
            }
        }
        screen(7, "SELECT", 0.14, 0.05, ink: rgb(1, 0.3, 0.2), in: vend, at: SCNVector3(0.36, 1.5, 0.402))
        B.box(0.14, 0.24, 0.01, mat(UIColor(white: 0.2, alpha: 1), metal: 0.5, rough: 0.4), in: vend, at: SCNVector3(0.36, 1.25, 0.402))
        // Refrigerator (north wall of (8,18)), with the house notice.
        let fridge = onWall(g(8, 18), .north, along: 0.6, out: 0.37, in: group)
        let white = mat(UIColor(white: 0.93, alpha: 1), metal: 0.1, rough: 0.35)
        B.box(0.8, 1.8, 0.7, white, in: fridge, at: SCNVector3(0, 0.9, 0), chamfer: 0.03)
        B.box(0.78, 0.01, 0.01, mat(UIColor(white: 0.6, alpha: 1)), in: fridge, at: SCNVector3(0, 1.25, 0.352), chamfer: 0)
        for y in [Float(1.5), 0.85] { B.box(0.03, 0.3, 0.04, B.chrome, in: fridge, at: SCNVector3(0.32, y, 0.37), chamfer: 0.01) }
        sign("LABEL YOUR FOOD!!  \u{2014} MGMT", 0.24, 0.16, ground: rgb(1, 0.97, 0.6), ink: rgb(0.1, 0.1, 0.4), in: fridge, at: SCNVector3(-0.12, 1.45, 0.352))
        for (k, c) in [rgb(0.9, 0.2, 0.2), rgb(0.2, 0.6, 0.9), rgb(0.95, 0.75, 0.1)].enumerated() {
            B.box(0.04, 0.04, 0.012, mat(c, rough: 0.4), in: fridge, at: SCNVector3(-0.25 + Float(k) * 0.1, 1.05 - Float(k % 2) * 0.08, 0.356), chamfer: 0.006)
        }
        // The counter (east wall of (9,18)): sink, coffee maker, and a microwave forever at 12:00.
        let counter = onWall(g(9, 18), .east, out: 0.32, in: group)
        B.box(2.2, 0.9, 0.62, mat(rgb(0.55, 0.42, 0.3), rough: 0.6), in: counter, at: SCNVector3(0, 0.45, 0), chamfer: 0.01)
        B.box(2.26, 0.04, 0.66, mat(rgb(0.85, 0.83, 0.78), rough: 0.3), in: counter, at: SCNVector3(0, 0.92, 0))
        B.box(2.2, 0.7, 0.35, mat(rgb(0.55, 0.42, 0.3), rough: 0.6), in: counter, at: SCNVector3(0, 2.05, -0.13), chamfer: 0.01)       // cupboards
        B.box(0.5, 0.02, 0.36, mat(UIColor(white: 0.3, alpha: 1), metal: 0.9, rough: 0.3), in: counter, at: SCNVector3(-0.6, 0.935, 0), chamfer: 0)
        B.rod(0.015, 0.3, B.chrome, in: counter, at: SCNVector3(-0.6, 1.08, -0.22))
        let coffee = SCNNode(); coffee.position = SCNVector3(0.15, 0.94, -0.05); counter.addChildNode(coffee)
        B.box(0.24, 0.36, 0.26, mat(UIColor(white: 0.1, alpha: 1), metal: 0.3, rough: 0.4), in: coffee, at: SCNVector3(0, 0.18, 0), chamfer: 0.02)
        B.rod(0.07, 0.14, mat(UIColor(white: 0.8, alpha: 0.5), rough: 0.1), in: coffee, at: SCNVector3(0, 0.07, 0.08))
        B.rod(0.06, 0.05, mat(rgb(0.25, 0.12, 0.05), rough: 0.2), in: coffee, at: SCNVector3(0, 0.03, 0.08))
        B.box(0.014, 0.014, 0.006, lamp(7, rgb(1, 0.15, 0.1)), in: coffee, at: SCNVector3(0.08, 0.3, 0.131), chamfer: 0)
        let micro = SCNNode(); micro.position = SCNVector3(0.75, 0.94, -0.05); counter.addChildNode(micro)
        B.box(0.52, 0.3, 0.38, mat(UIColor(white: 0.85, alpha: 1), metal: 0.3, rough: 0.4), in: micro, at: SCNVector3(0, 0.15, 0), chamfer: 0.01)
        B.box(0.32, 0.22, 0.005, mat(UIColor(white: 0.08, alpha: 1), rough: 0.2), in: micro, at: SCNVector3(-0.08, 0.15, 0.19), chamfer: 0)
        screen(7, "12:00", 0.1, 0.04, ink: rgb(0.3, 1, 0.5), blink: true, in: micro, at: SCNVector3(0.18, 0.22, 0.191))
        // Round table and chairs (south-west corner of (10,17)).
        let tableNode = SCNNode()
        tableNode.position = SCNVector3(17 * s - 0.55, 0, 10 * s + 0.5)
        group.addChildNode(tableNode)
        let laminate = mat(rgb(0.9, 0.88, 0.82), rough: 0.4)
        _ = B.part(SCNCylinder(radius: 0.5, height: 0.04), laminate, in: tableNode, at: SCNVector3(0, 0.74, 0))
        B.rod(0.04, 0.72, B.darkSteel, in: tableNode, at: SCNVector3(0, 0.36, 0))
        _ = B.part(SCNCylinder(radius: 0.25, height: 0.02), B.darkSteel, in: tableNode, at: SCNVector3(0, 0.01, 0))
        _ = B.part(SCNCylinder(radius: 0.04, height: 0.1), mat(.white, rough: 0.3), in: tableNode, at: SCNVector3(0.15, 0.81, -0.1))   // a mug
        let chairMat = mat(rgb(0.2, 0.35, 0.55), rough: 0.5)
        for (angle, dist) in [(Float(0.4), Float(0.75)), (Float(2.6), Float(0.75))] {
            let chair = SCNNode()
            chair.position = SCNVector3(sin(angle) * dist, 0, cos(angle) * dist)
            chair.eulerAngles.y = angle
            tableNode.addChildNode(chair)
            B.box(0.42, 0.04, 0.42, chairMat, in: chair, at: SCNVector3(0, 0.46, 0), chamfer: 0.01)
            B.box(0.42, 0.4, 0.04, chairMat, in: chair, at: SCNVector3(0, 0.7, 0.2), chamfer: 0.01)
            for x in [Float(-0.18), 0.18] { for z in [Float(-0.18), 0.18] { B.rod(0.012, 0.45, B.darkSteel, in: chair, at: SCNVector3(x, 0.225, z)) } }
        }
        // The bulletin board (west wall of (8,17)).
        let board = onWall(g(8, 17), .west, y: 1.5, out: 0.02, in: group)
        _ = B.part(SCNPlane(width: 1.2, height: 0.8), corkboard(), in: board, at: SCNVector3(0, 0, 0.012))
        B.box(1.26, 0.86, 0.02, mat(rgb(0.5, 0.35, 0.2), rough: 0.6), in: board, at: SCNVector3(0, 0, 0), chamfer: 0.005)
        // A water cooler (south wall of (10,18)).
        let cooler = onWall(g(10, 18), .south, along: -0.5, out: 0.25, in: group)
        B.box(0.32, 1.0, 0.32, mat(UIColor(white: 0.92, alpha: 1), rough: 0.4), in: cooler, at: SCNVector3(0, 0.5, 0), chamfer: 0.02)
        B.rod(0.15, 0.42, mat(rgb(0.6, 0.8, 0.95), rough: 0.1), in: cooler, at: SCNVector3(0, 1.22, 0))
    }

    /// The break room's notices, drawn as one texture.
    private static func corkboard() -> SCNMaterial {
        let size = CGSize(width: 960, height: 640)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.72, green: 0.55, blue: 0.36, alpha: 1).setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let notes: [(String, UIColor, CGRect, CGFloat)] = [
                ("FIRE DRILL\nTHURSDAY 10:00\n(again)", UIColor(red: 1, green: 0.95, blue: 0.55, alpha: 1), CGRect(x: 40, y: 40, width: 250, height: 200), -0.05),
                ("LOST:\nRED STAPLER\nno questions asked", .white, CGRect(x: 340, y: 60, width: 260, height: 210), 0.04),
                ("YOGA AT LUNCH\nCONFERENCE RM\nBRING A MAT", UIColor(red: 0.7, green: 0.9, blue: 1, alpha: 1), CGRect(x: 650, y: 40, width: 260, height: 200), -0.03),
                ("WHO KEEPS\nRESETTING\nTHE BREAKERS?", UIColor(red: 1, green: 0.75, blue: 0.8, alpha: 1), CGRect(x: 120, y: 330, width: 280, height: 220), 0.06),
                ("CAKE FRIDAY\n(Gloria's 30 yrs)", UIColor(red: 0.75, green: 1, blue: 0.75, alpha: 1), CGRect(x: 520, y: 340, width: 300, height: 190), -0.04),
            ]
            let style = NSMutableParagraphStyle(); style.alignment = .center
            for (text, colour, rect, tilt) in notes {
                ctx.cgContext.saveGState()
                ctx.cgContext.translateBy(x: rect.midX, y: rect.midY)
                ctx.cgContext.rotate(by: tilt)
                let r = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
                colour.setFill(); ctx.fill(r)
                UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1).setFill()
                ctx.cgContext.fillEllipse(in: CGRect(x: -9, y: r.minY + 8, width: 18, height: 18))      // the pin
                (text as NSString).draw(in: r.insetBy(dx: 12, dy: 36),
                                        withAttributes: [.font: UIFont(name: "MarkerFelt-Wide", size: 34) ?? UIFont.systemFont(ofSize: 34, weight: .bold),
                                                         .foregroundColor: UIColor(white: 0.12, alpha: 1), .paragraphStyle: style])
                ctx.cgContext.restoreGState()
            }
        }
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = image
        m.roughness.contents = 0.85
        return m
    }

    // MARK: 504 -- the darkroom (circuit 8)

    private static func buildDarkroom(in group: SCNNode) {
        let B = SupplyModels.self
        let steel = mat(UIColor(white: 0.62, alpha: 1), metal: 0.85, rough: 0.3)
        let blackPaint = mat(UIColor(white: 0.06, alpha: 1), rough: 0.7)
        // The wet bench: a long stainless sink down the west wall, three trays.
        let chemistry: [(String, UIColor)] = [("DEV", rgb(0.85, 0.8, 0.55)), ("STOP", rgb(0.9, 0.85, 0.5)), ("FIX", rgb(0.75, 0.8, 0.85))]
        for row in 16...17 {
            let bench = onWall(g(row, 10), .west, out: 0.35, in: group)
            B.box(3.3, 0.06, 0.66, steel, in: bench, at: SCNVector3(0, 0.9, 0), chamfer: 0.005)
            B.box(3.3, 0.18, 0.04, steel, in: bench, at: SCNVector3(0, 0.99, 0.31), chamfer: 0.004)
            B.box(3.3, 0.86, 0.6, blackPaint, in: bench, at: SCNVector3(0, 0.43, -0.02), chamfer: 0.01)
            B.rod(0.012, 0.9, steel, in: bench, at: SCNVector3(-1.2, 1.35, -0.28))
            if row == 16 {
                for (k, chem) in chemistry.enumerated() {
                    let x = -0.9 + Float(k) * 0.75
                    B.box(0.42, 0.06, 0.34, mat(UIColor(white: 0.92, alpha: 1), rough: 0.4), in: bench, at: SCNVector3(x, 0.96, 0), chamfer: 0.01)
                    B.box(0.38, 0.004, 0.3, mat(chem.1, metal: 0, rough: 0.05), in: bench, at: SCNVector3(x, 0.993, 0), chamfer: 0)
                    sign(chem.0, 0.12, 0.05, ground: .white, ink: .black, in: bench, at: SCNVector3(x, 1.04, 0.333))
                }
                B.box(0.02, 0.01, 0.2, B.chrome, in: bench, at: SCNVector3(-0.5, 1.0, 0.12), euler: SCNVector3(0, 0.4, 0), chamfer: 0)   // tongs
            } else {
                for k in 0..<4 {
                    B.rod(0.05, 0.22, mat(rgb(0.35, 0.2, 0.08), rough: 0.15), in: bench, at: SCNVector3(-0.8 + Float(k) * 0.16, 1.04, -0.15))   // brown bottles
                }
                B.box(0.25, 0.22, 0.2, mat(UIColor(white: 0.85, alpha: 1), rough: 0.5), in: bench, at: SCNVector3(0.6, 1.04, -0.1), chamfer: 0.01)
            }
        }
        // The enlarger (east wall of (16,11)), its timer counting in red.
        let enl = onWall(g(16, 11), .east, out: 0.38, in: group)
        B.box(1.6, 0.05, 0.72, mat(rgb(0.25, 0.2, 0.15), rough: 0.6), in: enl, at: SCNVector3(0, 0.9, 0), chamfer: 0.005)
        B.box(1.6, 0.88, 0.7, blackPaint, in: enl, at: SCNVector3(0, 0.44, -0.01), chamfer: 0.01)
        let baseX: Float = -0.25
        B.box(0.5, 0.03, 0.45, mat(UIColor(white: 0.15, alpha: 1), rough: 0.6), in: enl, at: SCNVector3(baseX, 0.94, 0), chamfer: 0)
        B.box(0.3, 0.004, 0.24, mat(UIColor(white: 0.95, alpha: 1), rough: 0.8), in: enl, at: SCNVector3(baseX, 0.957, 0.02), chamfer: 0)   // the paper
        B.rod(0.03, 1.1, steel, in: enl, at: SCNVector3(baseX, 1.5, -0.2))
        B.box(0.22, 0.2, 0.24, blackPaint, in: enl, at: SCNVector3(baseX, 1.65, -0.05), chamfer: 0.02)
        B.box(0.16, 0.12, 0.16, mat(UIColor(white: 0.25, alpha: 1), rough: 0.5), in: enl, at: SCNVector3(baseX, 1.49, -0.03), chamfer: 0.01)
        B.rod(0.04, 0.08, mat(UIColor(white: 0.1, alpha: 1), metal: 0.5, rough: 0.3), in: enl, at: SCNVector3(baseX, 1.4, -0.03))
        let timer = SCNNode(); timer.position = SCNVector3(0.45, 0.93, 0.05); enl.addChildNode(timer)
        B.box(0.2, 0.1, 0.16, blackPaint, in: timer, at: SCNVector3(0, 0.05, 0), chamfer: 0.01)
        screen(8, "12.5", 0.12, 0.05, ink: rgb(1, 0.12, 0.05), in: timer, at: SCNVector3(0, 0.06, 0.081))
        // The drying line, prints and film clipped to it (one span per cell).
        let line = mat(UIColor(white: 0.85, alpha: 1), rough: 0.6)
        let clip = mat(rgb(0.9, 0.85, 0.2), rough: 0.5)
        var shot = 0
        for col in 10...11 {
            let span = SCNNode()
            span.position = SCNVector3(Float(col) * s, 2.3, 16 * s + 0.3)
            group.addChildNode(span)
            B.rod(0.004, s - 0.1, line, in: span, at: SCNVector3Zero, euler: SCNVector3(0, 0, Float.pi / 2))
            for k in 0..<4 {
                let x = -1.2 + Float(k) * 0.8
                B.box(0.02, 0.04, 0.012, clip, in: span, at: SCNVector3(x, -0.02, 0), chamfer: 0.003)
                if (k + col) % 3 == 0 {
                    B.box(0.035, 0.36, 0.002, mat(rgb(0.12, 0.08, 0.05), rough: 0.2), in: span, at: SCNVector3(x, -0.22, 0), chamfer: 0)   // film
                } else {
                    let m = SCNMaterial(); m.lightingModel = .physicallyBased; m.diffuse.contents = printImage(shot); m.roughness.contents = 0.4
                    m.isDoubleSided = true
                    _ = B.part(SCNPlane(width: 0.2, height: 0.25), m, in: span, at: SCNVector3(x, -0.165, 0))
                    shot += 1
                }
            }
        }
        // The light-trap curtain, drawn back inside the door.
        let curtain = onWall(g(15, 11), .east, along: 0.9, out: 0.12, in: group)
        for k in 0..<5 {
            B.box(0.16, 2.6, 0.03, mat(UIColor(white: 0.04, alpha: 1), rough: 0.95), in: curtain,
                  at: SCNVector3(-0.25 + Float(k) * 0.12, 1.4, Float(k % 2) * 0.06), euler: SCNVector3(0, Float(k % 2 == 0 ? 0.35 : -0.35), 0), chamfer: 0)
        }
        // The safelights: the darkroom's own fixtures -- red, and on circuit 8.
        for (cell, wall) in [(g(17, 11), Direction.south), (g(16, 10), .north)] {
            let unit = onWall(cell, wall, y: 2.2, out: 0.02, in: group)
            B.box(0.32, 0.24, 0.14, mat(rgb(0.2, 0.15, 0.12), metal: 0.3, rough: 0.5), in: unit, at: SCNVector3(0, 0, 0.07), chamfer: 0.015)
            let filter = SCNMaterial()
            filter.lightingModel = .constant
            filter.diffuse.contents = rgb(1, 0.12, 0.05)
            _ = B.part(SCNPlane(width: 0.26, height: 0.18), filter, in: unit, at: SCNVector3(0, 0, 0.142))
            let lightNode = SCNNode()
            lightNode.position = SCNVector3(0, -0.1, 0.4)
            let l = SCNLight()
            l.type = .omni
            l.color = rgb(1, 0.14, 0.05)
            l.intensity = 320
            l.attenuationStartDistance = 0.3
            l.attenuationEndDistance = 6.5
            l.attenuationFalloffExponent = 2
            l.castsShadow = false
            lightNode.light = l
            unit.addChildNode(lightNode)
            let w = lightNode.worldPosition
            let f = Fixture(position: SIMD3(w.x, w.y, w.z))
            f.lights.append((lightNode, l.intensity))
            f.glows.append((filter.diffuse, 1))
            fixtures[8, default: []].append(f)
        }
        sign("SAFELIGHT ONLY", 0.4, 0.09, ground: UIColor(white: 0.1, alpha: 1), ink: rgb(1, 0.3, 0.2), in: onWall(g(17, 11), .east, y: 1.6, out: 0.01, in: group), at: SCNVector3Zero)
    }

    /// A small black-and-white print: the building's halls, a door, a cat.
    private static func printImage(_ k: Int) -> UIImage {
        let size = CGSize(width: 200, height: 250)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            UIColor(white: 0.97, alpha: 1).setFill(); c.fill(CGRect(origin: .zero, size: size))
            let inner = CGRect(x: 12, y: 12, width: 176, height: 226)
            UIColor(white: 0.25 + 0.08 * CGFloat(k % 3), alpha: 1).setFill(); c.fill(inner)
            c.setStrokeColor(UIColor(white: 0.75, alpha: 1).cgColor)
            c.setLineWidth(2)
            let vp = CGPoint(x: inner.midX + CGFloat(k % 2 == 0 ? -10 : 14), y: inner.midY - 10)
            for p in [CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY),
                      CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY)] {
                c.move(to: p); c.addLine(to: vp)
            }
            c.strokePath()
            UIColor(white: 0.08, alpha: 1).setFill()
            c.fill(CGRect(x: vp.x - 14, y: vp.y - 20, width: 28, height: 40))                 // the far end
            switch k % 3 {
            case 0:
                UIColor(white: 0.6, alpha: 1).setFill(); c.fill(CGRect(x: inner.minX + 18, y: inner.midY - 40, width: 26, height: 90))   // a door
            case 1:
                UIColor(white: 0.05, alpha: 1).setFill()
                c.fillEllipse(in: CGRect(x: inner.midX - 18, y: inner.maxY - 60, width: 36, height: 30))   // a cat
                c.fillEllipse(in: CGRect(x: inner.midX - 10, y: inner.maxY - 78, width: 20, height: 20))
            default:
                UIColor(white: 0.9, alpha: 1).setFill(); c.fill(CGRect(x: inner.midX - 30, y: inner.minY + 8, width: 60, height: 8))   // a ceiling light
            }
        }
    }

    // MARK: The panel

    /// Panel 5A: a grey steel cabinet with a hinged cover; inside, the dead
    /// front with two columns of four breakers, each with its directory card.
    private static func buildPanel(in group: SCNNode) {
        let B = SupplyModels.self
        let root = onWall(panelCell, .north, y: 1.45, in: group)
        root.name = "breakerPanel"
        panel = root
        let steel = mat(rgb(0.58, 0.6, 0.6), metal: 0.6, rough: 0.4)
        let w: Float = 0.92, h: Float = 1.1, d: Float = 0.14
        B.box(w, h, 0.01, mat(UIColor(white: 0.2, alpha: 1), metal: 0.4, rough: 0.6), in: root, at: SCNVector3(0, 0, 0.01))
        for x in [-w / 2, w / 2] { B.box(0.012, h, d, steel, in: root, at: SCNVector3(x, 0, d / 2)) }
        for y in [-h / 2, h / 2] { B.box(w, 0.012, d, steel, in: root, at: SCNVector3(0, y, d / 2)) }
        // (Oct 17: the dead front darker, warmer, matte -- it was near-white and shiny under a torch)
        B.box(w - 0.04, h - 0.04, 0.008, mat(rgb(0.34, 0.32, 0.29), metal: 0.15, rough: 0.85), in: root, at: SCNVector3(0, 0, 0.03), chamfer: 0)   // the dead front
        for y in [Float(0.5), -0.5] { for x in [Float(-0.4), 0.4] { _ = B.part(SCNSphere(radius: 0.008), B.chrome, in: root, at: SCNVector3(x, y, 0.035)) } }
        sign("PANEL 5A  \u{2022}  LIGHTING  \u{2022}  120/208 V", 0.62, 0.055, ground: Self.agedPaper, ink: .black, heavy: true, in: root, at: SCNVector3(0, 0.47, 0.0345))
        sign("\u{25B2} ON          \u{25BC} OFF", 0.36, 0.05, ground: Self.agedPaper, ink: .black, heavy: true, in: root, at: SCNVector3(0, -0.47, 0.0345))
        // (Oct 17: near-black matte housings; ivory handles a touch less bright, so both read under the beam)
        let body = mat(UIColor(white: 0.05, alpha: 1), rough: 0.8)
        let handle = mat(rgb(0.86, 0.84, 0.78), rough: 0.6)
        let slot = mat(UIColor(white: 0.02, alpha: 1), rough: 0.8)
        let hidden = SCNMaterial(); hidden.colorBufferWriteMask = []; hidden.writesToDepthBuffer = false
        for c in circuits {
            let left = c.number <= 4
            let row = (c.number - 1) % 4
            let unit = SCNNode()
            unit.name = "breaker_\(c.number)"
            unit.position = SCNVector3(left ? -0.1 : 0.1, 0.3 - Float(row) * 0.2, 0)
            root.addChildNode(unit)
            B.box(0.08, 0.13, 0.05, body, in: unit, at: SCNVector3(0, 0, 0.06), chamfer: 0.005)
            B.box(0.034, 0.07, 0.004, slot, in: unit, at: SCNVector3(0, 0, 0.087), chamfer: 0)
            sign("\(c.number)", 0.03, 0.025, ground: UIColor(white: 0.05, alpha: 1), ink: UIColor(white: 0.95, alpha: 1), heavy: true, in: unit, at: SCNVector3(0, 0.05, 0.0855))
            // The trip window under the handle: green ON, red OFF.
            let flag = SCNMaterial(); flag.lightingModel = .physicallyBased; flag.roughness.contents = 0.5
            _ = B.part(SCNPlane(width: 0.022, height: 0.012), flag, in: unit, at: SCNVector3(0, -0.05, 0.0855))
            flags[c.number] = flag
            // The handle: a lever on a pivot across the slot; up = ON, down = OFF.
            let pivot = SCNNode()
            pivot.position = SCNVector3(0, 0, 0.087)
            unit.addChildNode(pivot)
            B.box(0.026, 0.016, 0.05, handle, in: pivot, at: SCNVector3(0, 0, 0.025), chamfer: 0.004)
            levers[c.number] = pivot
            setLever(c.number, on: isOn(c.number), animated: false)
            // Its directory card, outboard.
            // (Oct 17: aged paper, heavy black type, a little bigger -- same place)
            sign("\(c.number)  \(c.label)", 0.22, 0.068, ground: Self.agedPaper, ink: .black, heavy: true,
                 in: unit, at: SCNVector3(left ? -0.19 : 0.19, 0, 0.036))
            // A finger-sized tap volume over the breaker and its card.
            let proxy = B.box(0.38, 0.17, 0.1, hidden, in: unit, at: SCNVector3(left ? -0.09 : 0.09, 0, 0.06), chamfer: 0)
            proxy.name = "breakerHit"
        }
        // The cover, hinged on the left (as you face it).
        let hinge = SCNNode()
        hinge.name = "breakerDoor"
        hinge.position = SCNVector3(-w / 2, 0, d + 0.006)
        root.addChildNode(hinge)
        door = hinge
        let cover = B.box(w, h, 0.012, steel, in: hinge, at: SCNVector3(w / 2, 0, 0), chamfer: 0.004)
        sign("ELECTRICAL PANEL 5A", 0.5, 0.1, ground: UIColor(white: 0.12, alpha: 1), ink: UIColor(white: 0.95, alpha: 1), in: cover, at: SCNVector3(0, 0.36, 0.007))
        sign("LIGHTING CIRCUITS 1 \u{2013} 8", 0.42, 0.06, ground: UIColor(white: 0.95, alpha: 1), ink: UIColor(white: 0.1, alpha: 1), in: cover, at: SCNVector3(0, 0.25, 0.007))
        sign("\u{26A0} DANGER  \u{2014}  HIGH VOLTAGE", 0.42, 0.09, ground: rgb(1, 0.82, 0.1), ink: UIColor(white: 0.05, alpha: 1), in: cover, at: SCNVector3(0, 0.08, 0.007))
        B.box(0.03, 0.1, 0.025, B.chrome, in: cover, at: SCNVector3(w / 2 - 0.06, -0.05, 0.015), chamfer: 0.006)       // the latch
        let pilot = SCNMaterial(); pilot.lightingModel = .constant; pilot.diffuse.contents = rgb(0.2, 1, 0.35)
        _ = B.part(SCNSphere(radius: 0.014), pilot, in: cover, at: SCNVector3(0.3, -0.38, 0.01))                     // (mains present)
        sign("POWER", 0.08, 0.025, ground: steelColour, ink: UIColor(white: 0.1, alpha: 1), in: cover, at: SCNVector3(0.3, -0.42, 0.007))
        // Oct 17: a battery-backed red locator lamp in a little black housing on the
        // enclosure's top edge, right of centre -- lit (steady since Oct 22) until the
        // panel's work is done (updateLocator). Not on the cover, so it stays put
        // when the cover swings.
        let housing = B.box(0.07, 0.045, 0.05, mat(UIColor(white: 0.06, alpha: 1), rough: 0.7), in: root,
                            at: SCNVector3(w / 2 - 0.16, h / 2 + 0.03, 0.05), chamfer: 0.006)
        locator = IndicatorLamp(style: .init(color: rgb(1, 0.06, 0.04), radius: 0.016, glowIntensity: 70, glowRange: 1.3),
                                in: housing, at: SCNVector3(0, 0, 0.026))
        let proxy = B.box(w + 0.16, h + 0.16, 0.06, hidden, in: root, at: SCNVector3(0, 0, d + 0.04), chamfer: 0)
        proxy.name = "breakerPanelHit"
        closedHit = proxy
    }
    private static let steelColour = UIColor(red: 0.58, green: 0.6, blue: 0.6, alpha: 1)
    /// Oct 17: the panel's cards -- an aged, darker cream, so a torch can't bleach them.
    private static let agedPaper = UIColor(red: 0.74, green: 0.69, blue: 0.56, alpha: 1)

    private static func setLever(_ n: Int, on: Bool, animated: Bool) {
        if let lever = levers[n] {
            let x: CGFloat = on ? -0.55 : 0.55
            if animated {
                let flip = SCNAction.rotateTo(x: x, y: 0, z: 0, duration: 0.1, usesShortestUnitArc: true)
                flip.timingMode = .easeIn
                lever.runAction(flip, forKey: "flip")
            } else {
                lever.eulerAngles.x = Float(x)
            }
        }
        flags[n]?.diffuse.contents = on ? rgb(0.15, 0.75, 0.25) : rgb(0.85, 0.12, 0.08)
    }

    // MARK: The player

    /// Is `node` part of the panel -- and which breaker, or the cover?
    private static func classify(_ node: SCNNode) -> (onPanel: Bool, breaker: Int?, onDoor: Bool) {
        var n: SCNNode? = node
        var breaker: Int?
        var onDoor = false
        while let x = n {
            let name = x.name ?? ""
            if breaker == nil, name.hasPrefix("breaker_"), let k = Int(name.dropFirst("breaker_".count)) { breaker = k }
            if name == "breakerDoor" { onDoor = true }
            if x === panel { return (true, breaker, onDoor) }
            n = x.parent
        }
        return (false, nil, false)
    }

    /// A tap on Floor 5: is it about the panel? (true = handled)
    /// Oct 17: a walk-up under way for a tapped breaker (bumped by every panel
    /// tap, so only the latest walk-up may act when it arrives).
    private static var approachToken = 0

    /// Things a tap ray passes that are not the panel's surroundings: invisible
    /// selection plates and cords, and creatures (the butterfly perched by it).
    private static func isPassThrough(_ node: SCNNode) -> Bool {
        if node.name == "decoratorHitProxy" || node.name == "hangingPickupString" { return true }
        return node.categoryBitMask & (Menagerie.categoryBit | CritterCategory.storyCritters | Bobbin.categoryBit) != 0
    }

    static func handleTap(hits: [SCNHitTestResult], controller c: TapNavigationController) -> Bool {
        guard c.currentFloorNumber == floor, let panel, panel.parent != nil,
              let first = hits.first(where: { !isPassThrough($0.node) }) else { return false }
        let eye = c.cameraNode.worldPosition
        func dist(_ p: SCNVector3) -> Float { simd_distance(SIMD3(p.x, p.y, p.z), SIMD3(eye.x, eye.y, eye.z)) }
        let firstD = dist(first.worldCoordinates)
        var onPanel = false, onDoor = false
        var breaker: Int?
        // (the NEAREST part of the panel along the ray -- within 0.5 m of the first
        // surface hit -- decides: the open cover in front of a breaker is the cover)
        for h in hits where dist(h.worldCoordinates) <= firstD + 0.5 && !isPassThrough(h.node) {
            let k = classify(h.node)
            guard k.onPanel else { continue }
            onPanel = true
            breaker = k.breaker
            onDoor = k.onDoor
            break
        }
        guard onPanel else { return false }
        // Oct 25 (PP 3): the blackout is retired -- the panel is inert. The tap is the panel's
        // (nothing behind it is walked into), and nothing happens: no cover, no breaker, no walk-up.
        if retired {
            diag("floor5.panelTap", ["retired": true])
            return true
        }
        approachToken += 1                                       // (any earlier walk-up's errand is void)
        let p = panel.worldPosition
        let level = hypotf(eye.x - p.x, eye.z - p.z)
        if level <= reach {
            work(breaker: breaker, onDoor: onDoor, controller: c)
        } else if abs(eye.x - p.x) > 1.4 || eye.z < p.z || eye.z - p.z > 3 * s {
            // Not straight down the closet (or from across the floor): no reaching it
            // from here, and no walking into a wall trying.
            c.showBrief("Get closer to the panel.")
        } else {
            // Straight down the closet: walk up to it -- a comfortable 1.5 m in
            // front, facing it (north, -Z: yaw 0) -- then do what was tapped:
            // open the cover, or (Oct 17) throw THAT breaker. Only if the walk
            // really arrived, nothing has changed meanwhile (cover still as it
            // was, no newer panel tap, same floor) -- else the errand is dropped.
            // Never a breaker thrown from afar.
            let stand = SCNVector3(p.x, eye.y, p.z + 1.5)                                   // (the panel faces south, +Z)
            let token = approachToken
            let wantBreaker = doorOpen ? breaker : nil
            let coverWasOpen = doorOpen
            let approaching = c.approachPose(kind: "breakerPanel", position: stand, yaw: 0) { [weak c] in
                guard let c, token == approachToken, c.currentFloorNumber == floor,
                      let panel = FloorFiveBlackout.panel, panel.parent != nil, doorOpen == coverWasOpen else {
                    diag("floor5.walkUpDropped", ["reason": "superseded or changed"])
                    return
                }
                let e = c.cameraNode.worldPosition, q = panel.worldPosition
                guard hypotf(e.x - q.x, e.z - q.z) <= reach + 0.3 else {
                    diag("floor5.walkUpDropped", ["reason": "walk ended short"])
                    return
                }
                if !doorOpen { setDoor(open: true) }
                else if let b = wantBreaker { toggle(b) }
                diag("floor5.walkUpDone", ["breaker": wantBreaker ?? 0])
            }
            if !approaching { c.showBrief("Can't reach that from here.") }
        }
        diag("floor5.panelTap", ["distance": Double(level), "breaker": breaker ?? 0, "door": onDoor, "open": doorOpen])
        return true
    }

    private static func work(breaker: Int?, onDoor: Bool, controller c: TapNavigationController) {
        if !doorOpen { setDoor(open: true); return }
        if let b = breaker { toggle(b); return }
        if onDoor { setDoor(open: false) }                                              // (the open cover: tap it to close)
    }

    private static func setDoor(open: Bool) {
        guard let door else { return }
        doorOpen = open
        closedHit?.isHidden = open
        let swing = SCNAction.rotateTo(x: 0, y: open ? -1.9 : 0, z: 0, duration: open ? 0.55 : 0.4, usesShortestUnitArc: true)
        swing.timingMode = .easeInEaseOut
        door.runAction(swing, forKey: "swing")
        ElevatorRideSound.click(on: door)
        diag("floor5.panelDoor", ["open": open])
    }

    // MARK: Switching

    private static let clackOn = MenagerieSound.source("floor5-breaker-clack", volume: 1.0) {
        var rng = MenagerieSound.Rand(seed: 515)
        return MenagerieSound.strike([(180, 0.05, 0.9), (420, 0.03, 0.5), (1900, 0.012, 0.35)], seconds: 0.35, noise: 1, noiseDecay: 0.006, rng: &rng)
    }
    private static let clackOff = MenagerieSound.source("floor5-breaker-clack-off", volume: 0.9) {
        var rng = MenagerieSound.Rand(seed: 516)
        return MenagerieSound.strike([(140, 0.06, 0.9), (330, 0.03, 0.45), (1500, 0.01, 0.3)], seconds: 0.35, noise: 1, noiseDecay: 0.005, rng: &rng)
    }
    private static let hum = MenagerieSound.source("floor5-power-hum", volume: 0.3) {
        let a = MenagerieSound.sweep(55, 120, seconds: 1.8, wobble: 0.3, curve: 0.6)
        let b = MenagerieSound.sweep(110, 240, seconds: 1.8, wobble: 0.2, curve: 0.6)
        return MenagerieSound.mix([(0, a, 0.7), (0, b, 0.35)])
    }

    /// Throw breaker `n` the other way: saved at once, then its area follows.
    private static func toggle(_ n: Int) {
        guard !retired else { return }                                    // (Oct 25: the panel is inert)
        let on = !isOn(n)
        store(n, on: on)
        setLever(n, on: on, animated: true)
        if let panel, let sound = on ? clackOn : clackOff { panel.runAction(.playAudio(sound, waitForCompletion: false)) }
        if on, let hum, let panel {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { panel.runAction(.playAudio(hum, waitForCompletion: false)) }
        }
        UIImpactFeedbackGenerator(style: on ? .heavy : .medium).impactOccurred()
        setPowered(n, on, animated: true)
        updateEmergency(animated: true)
        diag("floor5.circuit", ["circuit": n, "on": on, "mask": savedMask])
    }

    /// Circuit n's fixtures (and equipment) on or off. Animated: ON, each
    /// fixture stutters alight in turn (nearest the panel first); OFF, a
    /// quick fade out.
    private static func setPowered(_ n: Int, _ on: Bool, animated: Bool) {
        let gen = (generation[n] ?? 0) + 1
        generation[n] = gen
        let list = fixtures[n] ?? []
        guard animated else {
            for f in list { apply(f, level: on ? 1 : 0) }
            for e in equipment[n] ?? [] { e(on) }
            return
        }
        if on {
            let q = panel?.worldPosition ?? SCNVector3Zero
            let o = SIMD3<Float>(q.x, q.y, q.z)
            let ordered = list.sorted { simd_distance($0.position, o) < simd_distance($1.position, o) }
            for (i, f) in ordered.enumerated() {
                let start = 0.15 + Double(i) * 0.14 + Double((i * 37) % 5) * 0.02
                for (t, level) in [(0.0, 0.55), (0.06, 0.0), (0.13, 0.8), (0.19, 0.12), (0.3, 1.0)] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + start + t) {
                        if generation[n] == gen { apply(f, level: CGFloat(level)) }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if generation[n] == gen { for e in equipment[n] ?? [] { e(true) } }
            }
        } else {
            for e in equipment[n] ?? [] { e(false) }
            for f in list {
                apply(f, level: 0.3)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    if generation[n] == gen { apply(f, level: 0) }
                }
            }
        }
    }

    private static func apply(_ f: Fixture, level: CGFloat) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        for (l, full) in f.lights { l.light?.intensity = full * level; l.isHidden = level <= 0 }   // (hidden: out of the per-object light budget)
        for (g, full) in f.glows { g.intensity = max(0.02, full * level) }
        SCNTransaction.commit()
    }

    /// Oct 17: the locator follows the saved circuits (the same test as the
    /// emergency fill and the butterfly's concern): red while any circuit is off
    /// (steady since Oct 22; it blinked); dark once all eight are on -- a trouble lamp that clears.
    private static func updateLocator() {
        guard let locator else { return }
        // Oct 22 (morning): steady red, no longer blinking (it was irritating) -- the same
        // meaning: lit while any circuit is off, dark once all eight are on.
        if allPowered { locator.off() } else { locator.steady() }       // (Oct 25: the floor as shown)
    }

    /// The emergency fill: on while any circuit is off.
    private static func updateEmergency(animated: Bool) {
        updateLocator()
        guard let fill = emergency?.light else { return }
        let target: CGFloat = allPowered ? 0 : 42                         // (Oct 25: the floor as shown)
        guard animated else { fill.intensity = target; return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 1.2
        fill.intensity = target
        SCNTransaction.commit()
    }
}

// MARK: - Oct 17 -- INDICATOR LAMP (reusable)

/// A small self-lit indicator lamp for any fixture: a lens that's always
/// there (dim when dark, so a torch still shows it), a lit lens + soft halo
/// that show when it's on, and an optional tiny glow light on what's around it.
/// Steady, blinking (SCNActions inside the scene: no rebuilds, no per-frame
/// code), or off. Attach it to the fixture's own node; it lives and dies with it.
/// The halo honours walls (depth-tested), so it's only seen in line of sight.
final class IndicatorLamp {
    struct Style {
        var color: UIColor
        /// Lens radius, metres.
        var radius: CGFloat = 0.014
        /// One blink cycle, seconds, and the share of it spent lit.
        var period: TimeInterval = 1.0
        var litFraction: Double = 0.35
        /// The glow light it casts while lit (0 = none) and how far, metres.
        var glowIntensity: CGFloat = 0
        var glowRange: CGFloat = 1.0
        /// Halo size, as a multiple of the lens radius.
        var haloScale: CGFloat = 6
    }

    let node = SCNNode()
    private let lit = SCNNode()
    private let style: Style
    private static let actionKey = "indicatorLampBlink"

    init(style: Style, in parent: SCNNode, at position: SCNVector3) {
        self.style = style
        node.name = "indicatorLamp"
        node.position = position
        parent.addChildNode(node)
        // The dark lens: coloured plastic, lit only by real light (the torch).
        let dark = SCNMaterial()
        dark.lightingModel = .physicallyBased
        dark.diffuse.contents = style.color.withAlphaComponent(1).darkened(0.25)
        dark.roughness.contents = 0.35
        let lens = SCNNode(geometry: SCNSphere(radius: style.radius))
        lens.geometry?.firstMaterial = dark
        lens.scale = SCNVector3(1, 1, 0.6)
        node.addChildNode(lens)
        // Lit: a glowing lens, a halo, and (if asked) a little light.
        let bright = SCNMaterial()
        bright.lightingModel = .constant
        bright.diffuse.contents = style.color
        let glowLens = SCNNode(geometry: SCNSphere(radius: style.radius * 1.04))
        glowLens.geometry?.firstMaterial = bright
        glowLens.scale = SCNVector3(1, 1, 0.6)
        lit.addChildNode(glowLens)
        let haloSide = style.radius * style.haloScale
        let halo = SCNNode(geometry: SCNPlane(width: haloSide, height: haloSide))
        let haloMat = SCNMaterial()
        haloMat.lightingModel = .constant
        haloMat.diffuse.contents = Self.haloImage(style.color)
        haloMat.blendMode = .add
        haloMat.writesToDepthBuffer = false
        haloMat.isDoubleSided = true
        halo.geometry?.firstMaterial = haloMat
        halo.constraints = [SCNBillboardConstraint()]
        halo.renderingOrder = 10
        lit.addChildNode(halo)
        if style.glowIntensity > 0 {
            let light = SCNLight()
            light.type = .omni
            light.color = style.color
            light.intensity = style.glowIntensity
            light.attenuationStartDistance = 0
            light.attenuationEndDistance = style.glowRange
            light.attenuationFalloffExponent = 2
            light.castsShadow = false
            let glow = SCNNode()
            glow.light = light
            glow.position = SCNVector3(0, 0, Float(style.radius * 3))
            lit.addChildNode(glow)
        }
        lit.isHidden = true
        node.addChildNode(lit)
    }

    /// Lit and staying lit.
    func steady() {
        lit.removeAction(forKey: Self.actionKey)
        lit.isHidden = false
    }

    /// Lit for litFraction of every period, dark the rest.
    func blink() {
        guard lit.action(forKey: Self.actionKey) == nil else { return }       // (already blinking: keep its rhythm)
        let on = style.period * style.litFraction, off = style.period - on
        lit.runAction(.repeatForever(.sequence([.unhide(), .wait(duration: on), .hide(), .wait(duration: off)])), forKey: Self.actionKey)
    }

    func off() {
        lit.removeAction(forKey: Self.actionKey)
        lit.isHidden = true
    }

    /// A soft round glow in `color`, fading to nothing at the edge (cached per colour).
    private static var halos: [UIColor: UIImage] = [:]
    private static func haloImage(_ color: UIColor) -> UIImage {
        if let image = halos[color] { return image }
        let side: CGFloat = 64
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let colors = [UIColor(red: r, green: g, blue: b, alpha: 0.85).cgColor,
                          UIColor(red: r, green: g, blue: b, alpha: 0.25).cgColor,
                          UIColor(red: r, green: g, blue: b, alpha: 0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.35, 1]) else { return }
            let c = CGPoint(x: side / 2, y: side / 2)
            ctx.cgContext.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: side / 2, options: [])
        }
        halos[color] = image
        return image
    }
}

private extension UIColor {
    /// The same hue, `k` as bright (0...1).
    func darkened(_ k: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * k, green: g * k, blue: b * k, alpha: a)
    }
}

// MARK: - Oct 16 (VIII) -- THE FLASHLIGHT, working

/// A real beam: a warm SceneKit spot light on the player's camera, pointing
/// where they look. On while the flashlight is the selected tool (Tool Tray)
/// or held (Two Hands); off otherwise -- selecting another tool, returning
/// it, sitting down. No batteries. One cheap light, no shadows.
enum FlashlightBeam {
    private static weak var node: SCNNode?
    /// Oct 17: the one number to tune on device (was 520).
    static let intensity: CGFloat = 140

    // Oct 17 (close-range washout): the beam dims as the surface it lands on
    // comes close -- measured along the beam's own centre line (one short
    // ray, ten times a second, only while it's on), eased, never stepped.
    /// At or nearer than this (m): `nearFactor` of full strength.
    static let nearDistance: Float = 0.3
    static let nearFactor: Float = 0.3
    /// At or beyond this (m): full strength, exactly as before.
    static let fullDistance: Float = 1.0
    private static var timer: Timer?
    private static var factor: Float = 1

    /// Full strength from `fullDistance` out; `nearFactor` at `nearDistance`
    /// and nearer; a smooth (smoothstep) blend between.
    static func strength(atDistance d: Float) -> Float {
        if d >= fullDistance { return 1 }
        if d <= nearDistance { return nearFactor }
        let u = (d - nearDistance) / (fullDistance - nearDistance)
        return nearFactor + (1 - nearFactor) * u * u * (3 - 2 * u)
    }

    /// How far along the beam (m) the first real surface is (nil: none within reach).
    private static func surfaceDistance(_ beam: SCNNode) -> Float? {
        var root = beam
        while let p = root.parent { root = p }
        let from = beam.presentation.worldPosition
        let front = beam.presentation.worldFront
        let reach = fullDistance + 0.25
        let to = SCNVector3(from.x + front.x * reach, from.y + front.y * reach, from.z + front.z * reach)
        let hits = root.hitTestWithSegment(from: from, to: to, options: [
            SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue,
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
            // (not creatures, nor what the player carries -- those all wear these bits)
            SCNHitTestOption.categoryBitMask.rawValue: ~(Menagerie.categoryBit | CritterCategory.storyCritters | Bobbin.categoryBit | Cage.panelBit)
        ])
        let origin = SIMD3<Float>(from.x, from.y, from.z)
        var nearest: Float?
        for h in hits {
            // Invisible tap volumes (drawn nowhere) are not surfaces.
            if let m = h.node.geometry?.firstMaterial, m.colorBufferWriteMask.isEmpty || m.transparency < 0.05 { continue }
            if h.node.presentation.opacity < 0.05 { continue }
            let p = h.worldCoordinates
            let d = simd_distance(origin, SIMD3<Float>(p.x, p.y, p.z))
            if d < (nearest ?? .greatestFiniteMagnitude) { nearest = d }
        }
        return nearest
    }

    private static func follow() {
        guard let node, !node.isHidden, let light = node.light else { stopFollowing(); return }
        let target = surfaceDistance(node).map { strength(atDistance: $0) } ?? 1
        factor += (target - factor) * 0.45                      // (eased: about a fifth of a second)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.1                  // (and glided between looks)
        light.intensity = Self.intensity * CGFloat(factor)
        SCNTransaction.commit()
    }

    private static func startFollowing() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { follow() }
        }
    }

    private static func stopFollowing() {
        timer?.invalidate()
        timer = nil
    }

    static func attach(to camera: SCNNode) {
        node?.removeFromParentNode()
        let n = SCNNode()
        n.name = "flashlightBeam"
        n.position = SCNVector3(0.1, -0.14, 0)                    // (held low and to the right)
        n.eulerAngles = SCNVector3(0.04, 0.02, 0)               // (aimed just above the centre of the view)
        let l = SCNLight()
        l.type = .spot
        // Oct 17 (was 520, near-white, a hard 16-40 deg cone out to 16 m: it
        // bleached what it touched). Now: about a quarter the strength, an
        // incandescent warm white, a small bright core inside a wide soft
        // edge, and a natural (squared) fall-off to nothing by 9 m.
        l.color = UIColor(red: 1.0, green: 0.85, blue: 0.64, alpha: 1)
        l.intensity = Self.intensity
        l.spotInnerAngle = 8
        l.spotOuterAngle = 42
        l.attenuationStartDistance = 0
        l.attenuationEndDistance = 9
        l.attenuationFalloffExponent = 2
        l.castsShadow = false
        n.light = l
        n.isHidden = true
        camera.addChildNode(n)
        node = n
        refresh()
    }

    static var shouldShine: Bool {
        let t = ToolTray.shared
        guard ToolBelt.carries(.flashlight), !t.hidden, t.isOn(.flashlight) else { return false }
        return ToolBelt.presentation == .hands || t.selected == .tool(.flashlight)
    }

    static func refresh() {
        guard let node else { stopFollowing(); return }
        let on = shouldShine
        if node.isHidden == on {
            node.isHidden = !on
            diag("flashlight.beam", ["on": on])
            if on {
                // (switched on: straight to the right strength for where it points, then follow)
                factor = surfaceDistance(node).map { strength(atDistance: $0) } ?? 1
                node.light?.intensity = Self.intensity * CGFloat(factor)
            }
        }
        if on { startFollowing() } else { stopFollowing() }
    }
}

// MARK: - Oct 17 -- INFORMANTS: a critter that needs the player's help leads them to it
//
// Any critter can be an informant for a while; it is a behaviour, not a kind
// of creature. Three parts, kept apart so a different critter (Tinky, say)
// could take on the same problem without touching the navigation:
//
//   InformantConcern  WHAT the critter wants done, read only from live game
//                     state (inventory, circuits): still a problem? how far
//                     along? where must the player go next (any floor)?
//   InformantBody     HOW this critter moves and emotes: the lead engine's
//                     LeadPerformer plus a few informant gestures.
//   InformantGuide    the behaviour itself, on the floor the critter is on:
//                     find the player, invite them, lead (the building's own
//                     lead engine, CharacterLead: it waits when they fall
//                     behind, opens doors, never runs through them), notice
//                     when it has lost their attention, try twice to win it
//                     back, then give up for a while; ride the elevator with
//                     them when they board together and re-plan wherever they
//                     arrive; react to progress; let go when it's solved.
//
// The player is always free. The guide never moves the player or the camera,
// never chooses an elevator floor, never blocks a way, and doesn't steer GO.
// Only one informant guides at a time (InformantGuide.current).

/// Where an informant wants the player next.
struct InformantWaypoint {
    var floor: Int
    /// The cell to bring the player into (derived from `stand` if nil).
    var cell: GridCoordinate?
    /// Where the guide waits for the player there (world x, z).
    var stand: SIMD2<Float>?
    /// Where the guide settles once the player has come (world x, y, z).
    var perch: SIMD3<Float>?
    /// What it keeps drawing attention to while it waits there.
    var focus: SIMD3<Float>?
    /// A stable name ("panel", "flashlight"): a new tag is a new plan.
    var tag: String
}

/// A problem an informant wants solved -- live state only, no assumptions.
protocol InformantConcern: AnyObject {
    var name: String { get }
    var isActive: Bool { get }
    /// How much of it is done (a rise is celebrated, a fall fretted over).
    var progress: Int { get }
    /// Where the player must go next, from where things stand now. `floor` is
    /// the floor the guide is on (details like perches only exist there).
    func nextWaypoint(onFloor floor: Int) -> InformantWaypoint?
}

/// What a critter's body must do to be an informant (beyond leading).
protocol InformantBody: LeadPerformer {
    /// Its root node while in a scene.
    var node: SCNNode? { get }
    /// "Hey! Over here!" -- in front of the player.
    func hail(player: SIMD2<Float>)
    /// Something got better (big: it's all done).
    func rejoice(big: Bool)
    /// It gives up for now.
    func sulk()
    /// Something got worse.
    func fret()
    /// Settle at a point (world x, y, z).
    func perch(at point: SIMD3<Float>, then: @escaping () -> Void)
    /// Draw attention to a point (world x, y, z).
    func indicate(_ target: SIMD3<Float>)
    /// Fly to (x, z) and hold there at `height`.
    func hover(at point: SIMD2<Float>, height: Float, then: @escaping () -> Void)
}

/// What an informant remembers about its attempts (saved with the critter).
struct InformantMemory: Codable {
    /// The player has been following (a journey is under way).
    var engaged = false
    /// It went into the elevator with the player.
    var riding = false
    /// Tries to win the player back since they last came close.
    var attempts = 0
    /// Times it has given up (each rest is longer).
    var lapses = 0
    /// Given up: not again before this.
    var restUntil: Date?
    /// The concern's progress when last looked at.
    var lastProgress: Int?
}

final class InformantGuide {
    enum Phase: String { case idle, approaching, hailing, leading, presenting, regaining, cab }

    /// The one informant guiding the player right now (if any).
    private(set) static weak var current: InformantGuide?

    struct Hooks {
        /// This floor's elevator doorway (centre, unit direction out of the cab).
        var doorway: () -> (center: SIMD2<Float>, outward: SIMD2<Float>)?
        /// The player is inside the elevator (waiting at the panel, or riding).
        var playerInElevator: () -> Bool
    }

    let name: String
    let body: InformantBody
    let concern: InformantConcern
    let floor: Int
    let context: CharacterLead.Context
    let hooks: Hooks
    var memory: InformantMemory { didSet { onMemoryChanged?(memory) } }
    var onMemoryChanged: ((InformantMemory) -> Void)?
    /// Guidance is over for now (solved, or given up): its own life resumes.
    var onReleased: (() -> Void)?

    private(set) var phase: Phase = .idle
    private var phaseSince: CFTimeInterval = 0
    private var lead: CharacterLead?
    private var plan: InformantWaypoint?
    private var timer: Timer?
    private var lastClose: CFTimeInterval = 0
    private var farSince: CFTimeInterval?
    private var lastFocus: CFTimeInterval = 0
    private var outsideCabSince: CFTimeInterval?
    private var leavingCab = false
    private var focusCount = 0
    private var generation = 0
    /// When guidance last ended (a new attempt waits a little after this).
    private(set) var releasedAt: CFTimeInterval = 0

    // Feel.
    static let closeDistance: Float = 4.5      // the player this near = with it
    static let lostDistance: Float = 11        // this far...
    static let lostAfter: Double = 7           // ...this long = attention lost
    static let stallAfter: Double = 26         // or not near it at all for this long
    static let regainTries = 2
    static let restBase: TimeInterval = 75     // after giving up (x times given up, at most restMax)
    static let restMax: TimeInterval = 300
    /// After this many give-ups she leaves the player be until something changes
    /// (a circuit switched, a new day of play).
    static let maxLapses = 3
    /// She waits by the thing she brought them to at most this long.
    static let presentFor: Double = 120

    init(name: String, body: InformantBody, concern: InformantConcern, floor: Int, context: CharacterLead.Context,
         hooks: Hooks, memory: InformantMemory) {
        self.name = name
        self.body = body
        self.concern = concern
        self.floor = floor
        self.context = context
        self.hooks = hooks
        self.memory = memory
    }

    var isGuiding: Bool { phase != .idle }
    var isResting: Bool { (memory.restUntil ?? .distantPast) > BuildingClock.now() }
    /// Oct 18 (diagnostics): where it's leading the player (nil: not leading anywhere yet).
    var target: InformantWaypoint? { plan }

    private func log(_ event: String, _ fields: KeyValuePairs<String, Any?> = [:]) {
        var line = "informant.\(event) name=\(name) floor=\(floor) phase=\(phase.rawValue)"
        for (k, v) in fields { line += " \(k)=\(v.map { "\($0)" } ?? "nil")" }
        diag("informant.\(event)", ["name": name, "floor": floor, "phase": phase.rawValue, "detail": line])
        navLog("[Informant] " + line)
    }

    /// Start watching (progress, the cab). Guidance itself starts with begin().
    func attach() {
        if memory.lastProgress == nil { memory.lastProgress = concern.progress }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                if let self { self.tick() } else { t.invalidate() }
            }
        }
    }

    /// The scene is going (a floor change): stop, keeping the memory.
    func detach() {
        timer?.invalidate()
        timer = nil
        lead?.cancel()
        lead = nil
        generation += 1
        phase = .idle
        if Self.current === self { Self.current = nil }
    }

    /// No other informant, escort or eviction is under way.
    static func mayGuide(_ g: InformantGuide) -> Bool {
        if let c = current, c !== g, c.isGuiding { return false }
        return GuidedJourney.trip == nil && CharacterLead.activeGuidedRoute == nil && !BonzoEviction.isActive
            && !ConferenceMeeting.isActive
    }

    /// Go and find the player (true = started).
    @discardableResult
    func begin(reason: String) -> Bool {
        guard phase == .idle, concern.isActive, !isResting, !hooks.playerInElevator(), Self.mayGuide(self),
              body.groundPosition != nil, context.playerPose() != nil else { return false }
        Self.current = self
        lastClose = CACurrentMediaTime()
        log("begin", ["reason": reason])
        goToPlayer(.approaching)
        return true
    }

    /// Arrived in the elevator WITH the player (the cab of this floor's scene).
    func ridingIn() {
        Self.current = self
        set(.cab)
        log("ridingIn")
    }

    /// Move about this floor on its own business (not guiding): the same
    /// legs, doors and all, with nobody to wait for.
    func wander(to point: SIMD2<Float>, then: @escaping () -> Void) {
        guard phase == .idle else { return }
        runLeg(to: point, waits: false, arrived: then)
    }

    private func set(_ p: Phase) {
        phase = p
        phaseSince = CACurrentMediaTime()
    }

    // MARK: Legs (the building's lead engine)

    private func cellOf(_ p: SIMD2<Float>) -> GridCoordinate {
        GridCoordinate(row: Int((p.y / context.cellSize).rounded()), col: Int((p.x / context.cellSize).rounded()))
    }
    private func center(_ c: GridCoordinate) -> SIMD2<Float> {
        SIMD2<Float>(Float(c.col) * context.cellSize, Float(c.row) * context.cellSize)
    }

    /// A leg to `point` (in `goal`, or the cell under it). `waits`: its last
    /// stop waits for the player (released as they come near); otherwise it
    /// just goes there (no stops on the way).
    private func runLeg(to point: SIMD2<Float>, goal: GridCoordinate? = nil, waits: Bool, release: Float = 2.8,
                        arrived: @escaping () -> Void) {
        lead?.cancel()
        lead = nil
        generation += 1
        let gen = generation
        guard let me = body.groundPosition else { return }
        let from = cellOf(me), to = goal ?? cellOf(point)
        var steps: [CharacterLead.Step]
        if let route = CharacterLead.route(from: from, to: to, cells: context.cells, doors: context.doors), route.count >= 2 {
            steps = CharacterLead.plan(route: route, context: context, finalPoint: point, decisionInset: -0.6,
                                       decisionRelease: 2.6, paceEvery: 3)
        } else {
            steps = [.travel([point]), .stop(CharacterLead.Stop(point: point, onward: nil, isFinal: true, cell: to))]
        }
        if !waits {
            steps = steps.filter { step in
                if case .stop(let s) = step { return s.isFinal }
                return true
            }
        }
        if case .some(.stop(var last)) = steps.last {
            last.waitsForPlayer = waits
            last.release = release
            steps[steps.count - 1] = .stop(last)
        }
        let lead = CharacterLead(performer: body, context: context, steps: steps)
        lead.name = "informant.\(name)"
        if waits {
            lead.onFinalRelease = { [weak self] in
                guard let self, self.generation == gen else { return }
                arrived()
            }
        } else {
            lead.onFinish = { [weak self] in
                guard let self, self.generation == gen else { return }
                self.lead?.cancel()                 // (a finished errand: no glancing back at the player)
                self.lead = nil
                arrived()
            }
        }
        lead.onLost = { [weak self] in
            guard let self, self.generation == gen else { return }
            self.release(reason: "body left the scene", celebrate: false)
        }
        self.lead = lead
        lead.start()
    }

    // MARK: Finding the player, inviting them

    /// A spot a little in front of the player, on open floor they can see.
    private func spotInFront(of pose: (position: SIMD2<Float>, yaw: Float), from me: SIMD2<Float>) -> SIMD2<Float> {
        let forward = SIMD2<Float>(-sin(pose.yaw), -cos(pose.yaw))
        let here = cellOf(pose.position)
        for d: Float in [2.3, 1.8, 1.4] {
            let p = pose.position + forward * d
            let c = cellOf(p)
            guard context.cells.contains(c) else { continue }
            if c == here { return p }
            if let r = CharacterLead.route(from: here, to: c, cells: context.cells, doors: context.doors, canCross: context.isDoorOpen),
               r.count <= 2 { return p }
        }
        let toward = me - pose.position
        let len = simd_length(toward)
        return len > 0.01 ? pose.position + toward / len * min(1.8, len) : pose.position
    }

    private func goToPlayer(_ p: Phase) {
        set(p)
        guard let me = body.groundPosition, let pose = context.playerPose() else { return }
        let spot = spotInFront(of: pose, from: me)
        runLeg(to: spot, waits: false) { [weak self] in self?.hail() }
    }

    private func hail() {
        guard let pose = context.playerPose() else { return }
        if phase != .regaining { set(.hailing) }
        body.hail(player: pose.position)
        log("hail", ["attempts": memory.attempts])
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self, self.generation == gen, self.phase == .hailing || self.phase == .regaining else { return }
            self.leadOn()
        }
    }

    // MARK: Leading

    /// Re-plan from live state and lead to the next place.
    private func leadOn() {
        guard concern.isActive else { celebrateAndRelease(); return }
        guard let target = concern.nextWaypoint(onFloor: floor) else {
            memory.restUntil = BuildingClock.now().addingTimeInterval(Self.restBase)
            release(reason: "nowhere to go", celebrate: false)
            return
        }
        plan = target
        memory.engaged = true
        lastClose = CACurrentMediaTime()
        set(.leading)
        if target.floor == floor {
            let point = target.stand ?? target.cell.map { center($0) } ?? body.groundPosition ?? .zero
            log("lead", ["to": target.tag])
            runLeg(to: point, goal: target.cell ?? cellOf(point), waits: true, release: 2.6) { [weak self] in self?.present() }
        } else if let door = hooks.doorway() {
            // Another floor: to the elevator first. (The player chooses the floor.)
            let landing = cellOf(door.center + door.outward * (context.cellSize * 0.5))
            log("lead", ["to": "elevator", "for": target.tag, "floor": target.floor])
            runLeg(to: door.center + door.outward * 1.4, goal: landing, waits: true, release: 2.8) { [weak self] in self?.present() }
        } else {
            memory.restUntil = BuildingClock.now().addingTimeInterval(Self.restBase)
            release(reason: "no elevator on this floor", celebrate: false)
        }
    }

    /// The player has come: show them.
    private func present() {
        set(.presenting)
        lastFocus = CACurrentMediaTime()          // (settle first; point after)
        focusCount = 0
        lastClose = CACurrentMediaTime()
        guard let target = plan else { return }
        if target.floor == floor {
            if let perch = target.perch { body.perch(at: perch) {} }
        } else if let door = hooks.doorway() {
            body.hover(at: door.center + door.outward * 1.0, height: 2.1) {}
        }
        log("present", ["at": target.floor == floor ? target.tag : "elevator"])
    }

    private func focusPoint(_ target: InformantWaypoint) -> SIMD3<Float>? {
        if target.floor == floor { return target.focus }
        guard let door = hooks.doorway() else { return nil }
        return SIMD3<Float>(door.center.x, 1.4, door.center.y)
    }

    // MARK: The elevator

    /// The player has just been accepted into this floor's elevator. If they
    /// are going with it, it goes with them (into the cab, beside them).
    func playerBoarding() {
        guard phase != .idle, phase != .cab, let me = body.groundPosition, let pose = context.playerPose(),
              simd_distance(me, pose.position) < 8, let door = hooks.doorway() else { return }
        lead?.cancel()
        lead = nil
        generation += 1
        let gen = generation
        set(.cab)
        memory.riding = true
        log("boarding")
        let side = SIMD2<Float>(-door.outward.y, door.outward.x)
        let spot = door.center - door.outward * 0.8 + side * 0.55
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.generation == gen, self.phase == .cab else { return }
            self.body.travel([door.center + door.outward * 0.5, door.center - door.outward * 0.3]) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.body.hover(at: spot, height: 2.05) {}
            }
        }
    }

    /// The doors of the cab it rode in are opening: out first, then on.
    func arrivalDoorsOpening() {
        guard phase == .cab, !leavingCab, let door = hooks.doorway() else { return }
        generation += 1
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.generation == gen, self.phase == .cab else { return }
            self.leaveCab(door: door, gen: gen)
        }
    }

    private func leaveCab(door: (center: SIMD2<Float>, outward: SIMD2<Float>), gen: Int) {
        guard !leavingCab else { return }
        leavingCab = true
        body.travel([door.center - door.outward * 0.2, door.center + door.outward * 1.3]) { [weak self] in
            guard let self else { return }
            self.leavingCab = false
            guard self.generation == gen else { return }
            self.memory.riding = false
            self.lastClose = CACurrentMediaTime()
            self.log("outOfCab")
            if self.concern.isActive { self.hail() } else { self.celebrateAndRelease() }
        }
    }

    // MARK: Watching (main thread, 4 x a second)

    private func tick() {
        let now = CACurrentMediaTime()
        // Progress, guiding or not: a rise is celebrated, a fall fretted over.
        let p = concern.progress
        if let last = memory.lastProgress, p != last {
            memory.lastProgress = p
            // Something changed: whatever she'd given up on, it's worth another try.
            if memory.lapses != 0 || memory.restUntil != nil { memory.lapses = 0; memory.restUntil = nil }
            if !concern.isActive {
                celebrateAndRelease()
                return
            }
            if p > last { body.rejoice(big: false) } else { body.fret() }
        } else if memory.lastProgress == nil {
            memory.lastProgress = p
        }
        guard phase != .idle else { return }
        guard let me = body.groundPosition, let pose = context.playerPose() else { return }
        let d = simd_distance(me, pose.position)
        if d < Self.closeDistance {
            lastClose = now
            if phase == .leading || phase == .presenting, memory.attempts != 0 { memory.attempts = 0 }
        }
        switch phase {
        case .cab:
            // The player stepped back out of the cab without riding: carry on here.
            guard !hooks.playerInElevator(), let door = hooks.doorway() else { outsideCabSince = nil; return }
            if simd_dot(pose.position - door.center, door.outward) > 1.1 {
                outsideCabSince = outsideCabSince ?? now
                if let t = outsideCabSince, now - t > 1.0 {
                    outsideCabSince = nil
                    log("playerLeftCab")
                    leaveCab(door: door, gen: generation)
                }
            } else {
                outsideCabSince = nil
            }
        case .leading, .presenting:
            if !concern.isActive { celebrateAndRelease(); return }
            if hooks.playerInElevator() { farSince = nil; return }        // (boarding is playerBoarding's business)
            if let target = plan {
                // A change of plan (the flashlight's been taken...): on to the next place.
                if let next = concern.nextWaypoint(onFloor: floor), next.tag != target.tag || next.floor != target.floor {
                    log("replan", ["from": target.tag, "to": next.tag])
                    lead?.cancel()
                    lead = nil
                    body.rejoice(big: false)
                    set(.hailing)
                    generation += 1
                    let gen = generation
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                        guard let self, self.generation == gen, self.phase == .hailing else { return }
                        self.leadOn()
                    }
                    return
                }
                // Pointing it out -- less and less often (never a nag).
                if phase == .presenting, let focus = focusPoint(target), !body.isGesturing,
                   now - lastFocus > 3.4 + min(10, Double(focusCount) * 1.5) {
                    lastFocus = now
                    focusCount += 1
                    body.indicate(focus)
                }
                if phase == .presenting, now - phaseSince > Self.presentFor {
                    memory.restUntil = BuildingClock.now().addingTimeInterval(Self.restBase)
                    release(reason: "waited long enough", celebrate: false)
                    return
                }
            }
            // Has it lost them?
            if d > Self.lostDistance { farSince = farSince ?? now } else { farSince = nil }
            let lost = farSince.map { now - $0 > Self.lostAfter } ?? false
            let stalled = now - lastClose > (phase == .presenting ? Self.stallAfter * 1.6 : Self.stallAfter)
            if lost || stalled { lapse(lost ? "far away" : "never came") }
        case .approaching, .hailing, .regaining:
            if !concern.isActive { celebrateAndRelease(); return }
            if hooks.playerInElevator() { return }
            if now - phaseSince > 30 { lapse("couldn't reach them") }
        case .idle:
            break
        }
    }

    // MARK: Losing them, giving up, letting go

    private func lapse(_ why: String) {
        farSince = nil
        memory.attempts += 1
        log("lapse", ["why": why, "attempts": memory.attempts])
        if memory.attempts > Self.regainTries {
            giveUp()
            return
        }
        lastClose = CACurrentMediaTime()
        goToPlayer(.regaining)
    }

    private func giveUp() {
        memory.attempts = 0
        memory.lapses += 1
        // Each rest longer; after maxLapses, not again until something changes (tick).
        memory.restUntil = memory.lapses >= Self.maxLapses
            ? BuildingClock.now().addingTimeInterval(6 * 3600)
            : BuildingClock.now().addingTimeInterval(min(Self.restMax, Self.restBase * Double(memory.lapses)))
        body.sulk()
        release(reason: "gave up for now", celebrate: false)
    }

    private func celebrateAndRelease() {
        memory = InformantMemory(lastProgress: concern.progress)
        body.rejoice(big: true)
        release(reason: "solved", celebrate: true)
    }

    private func release(reason: String, celebrate: Bool) {
        lead?.cancel()
        lead = nil
        generation += 1
        let was = phase
        phase = .idle
        plan = nil
        leavingCab = false
        releasedAt = CACurrentMediaTime()
        if Self.current === self { Self.current = nil }
        log("release", ["reason": reason, "was": was.rawValue])
        DispatchQueue.main.asyncAfter(deadline: .now() + (celebrate ? 3.2 : 1.8)) { [weak self] in
            guard let self, self.phase == .idle else { return }
            self.onReleased?()
        }
    }
}

// MARK: - The Floor 5 lights (the butterfly's concern)

/// All eight of Floor 5's circuits on. The way there depends on what the
/// player actually carries: no flashlight -> Floor 4's supply room, to the
/// flashlight on its bench; with one -> Floor 5's panel.
final class FloorFiveLightsConcern: InformantConcern {
    let name = "floor5Lights"
    /// Oct 25 (PP 3): never, while the blackout is retired -- so the butterfly never
    /// prompts, never guides to the panel or to Floor 4's flashlight, never makes a
    /// trip for it, and never celebrates it; she lives her own life.
    var isActive: Bool { !FloorFiveBlackout.retired && !FloorFiveBlackout.allPowered }
    var progress: Int { (FloorFiveBlackout.effectiveMask & 0xFF).nonzeroBitCount }

    func nextWaypoint(onFloor floor: Int) -> InformantWaypoint? {
        guard isActive else { return nil }
        if ToolBelt.carries(.flashlight) {
            var w = InformantWaypoint(floor: FloorFiveBlackout.floor, cell: FloorFiveBlackout.panelCell, tag: "panel")
            if floor == FloorFiveBlackout.floor, let p = FloorFiveBlackout.panelWorldPosition {
                // (the panel faces south, +Z: stand in front of it; settle up beside it, clear of the cover's swing)
                w.stand = SIMD2<Float>(p.x, p.z + 1.6)
                w.perch = SIMD3<Float>(p.x + 0.75, p.y + 0.5, p.z + 0.35)
                w.focus = SIMD3<Float>(p.x, p.y, p.z + 0.1)
            }
            return w
        }
        var w = InformantWaypoint(floor: SuppliesShowroom.floor, cell: GridCoordinate(row: 10, col: 9), tag: "flashlight")
        if floor == SuppliesShowroom.floor, let c = SuppliesShowroom.toolCentre(.flashlight) {
            let stand = SuppliesShowroom.standPose(.flashlight, eyeY: 1.6).position
            w.stand = SIMD2<Float>(stand.x, stand.z)
            w.cell = nil
            // On the bench beside it: a hand's breadth along the wall from the flashlight.
            var toward = SIMD2<Float>(stand.x - c.x, stand.z - c.z)
            toward = simd_length(toward) > 0.01 ? simd_normalize(toward) : SIMD2<Float>(0, 1)
            let along = SIMD2<Float>(-toward.y, toward.x)
            w.perch = SIMD3<Float>(c.x + along.x * 0.3 + toward.x * 0.05, c.y + 0.02, c.z + along.y * 0.3 + toward.y * 0.05)
            w.focus = SIMD3<Float>(c.x, c.y, c.z)
        }
        return w
    }
}

// MARK: - Oct 17 -- THE BUTTERFLY (the first informant)
//
// A small, bright-eyed butterfly who lives in the building. Her eyes glow, and
// her wings' spots and edges glow faintly, so she can be seen in the dark of
// Floor 5. She chirps (no words), loops the loop to get your attention,
// twirls when something goes right, droops when she gives up.
//
// Her life (Oct 18: rooms, via Roam and RoomRegistry -- formerly a handful of favourite haunts), visited in turn
// with some variation (ButterflyLife). Offscreen she is only a record --
// where she is, since when, for how long -- worked forward when someone
// looks; nothing simulates the building. On the player's floor she is real:
// she rests, potters about, investigates, and comes and goes by the elevator
// (a ding, the doors, and out she flutters).
//
// Her concern: Floor 5's lights. When the player is on Floor 5 with circuits
// off she makes reaching them her priority -- by the elevator if she's on
// another floor -- and becomes an informant (InformantGuide): to the panel if
// they carry the flashlight, otherwise to Floor 4's supply room for it first.
// All eight on: she celebrates and goes back to her own life.

/// Wing beat and height, shared with the render thread (flap action).
nonisolated final class ButterflyWings: @unchecked Sendable {
    var rate: Float = 9            // beats per second
    var amplitude: Float = 0.85    // radians either side of `rest`
    var rest: Float = 0.25         // the wings' middle angle (a raised V)
    var cruise: Float = 1.75       // the height she holds (m)
    var height: Float = 1.75
    var phase: Float = 0
    var last: CFTimeInterval = 0
    weak var camera: SCNNode?
}

enum ButterflySound {
    static let chirp = MenagerieSound.source("butterfly-chirp", volume: 0.5) {
        MenagerieSound.mix([(0, MenagerieSound.sweep(2300, 3400, seconds: 0.08, curve: 0.6), 0.8),
                            (0.085, MenagerieSound.sweep(3400, 2900, seconds: 0.05), 0.6)])
    }
    static let chirp2 = MenagerieSound.source("butterfly-chirp2", volume: 0.5) {
        MenagerieSound.mix([(0, MenagerieSound.sweep(2800, 3900, seconds: 0.06, curve: 0.7), 0.8),
                            (0.11, MenagerieSound.sweep(2800, 4200, seconds: 0.07, curve: 0.7), 0.8)])
    }
    static let trill = MenagerieSound.source("butterfly-trill", volume: 0.55) {
        MenagerieSound.mix((0..<7).map { i -> (at: Float, samples: [Float], gain: Float) in
            (Float(i) * 0.07, MenagerieSound.sweep(2400 + Float(i) * 220, 3300 + Float(i) * 260, seconds: 0.06, curve: 0.6), 0.75)
        })
    }
    static let sad = MenagerieSound.source("butterfly-sad", volume: 0.45) {
        MenagerieSound.sweep(2500, 1350, seconds: 0.45, wobble: 0.12, curve: 1.4)
    }
    static let worry = MenagerieSound.source("butterfly-worry", volume: 0.45) {
        MenagerieSound.mix([(0, MenagerieSound.sweep(2100, 2500, seconds: 0.07), 0.8),
                            (0.13, MenagerieSound.sweep(2100, 2450, seconds: 0.07), 0.8)])
    }
    static let flutter = MenagerieSound.source("butterfly-flutter", volume: 0.3) {
        var rng = MenagerieSound.Rand(seed: 77)
        return MenagerieSound.strike([(140, 0.02, 0.4)], seconds: 0.18, noise: 1, noiseDecay: 0.03, rng: &rng)
    }
}

final class ButterflyBody: InformantBody {
    let root = SCNNode()           // on the floor: x, z and heading
    private let lift = SCNNode()   // her height (and the beat's bob)
    private let tilt = SCNNode()   // gestures: loops, twirls, bows
    private let leftHinge = SCNNode(), rightHinge = SCNNode()
    private var halos: [SCNNode] = []
    let wings = ButterflyWings()
    /// Oct 18 (phase 2): her eyes (gold, with dark pupils that turn to look),
    /// her antennae (they follow her gaze), and what she attends to.
    private(set) var attention: CritterAttention?
    private var eyePivots: [SCNNode] = [], eyeLids: [SCNNode] = []
    private var antennae: [(node: SCNNode, base: SCNVector3)] = []
    private var antennaPerk: Float = 0
    private var gesturing = false
    private var perched = false
    /// Bumped by every flight: a step planned before a newer flight began is dropped.
    private(set) var motion = 0
    var isFlying: Bool { root.action(forKey: "move") != nil }
    static let speed: Float = 2.2
    static let cruise: Float = 1.75

    init(camera: SCNNode?) {
        wings.camera = camera
        root.name = "butterfly"
        root.addChildNode(lift)
        lift.addChildNode(tilt)
        build()
        root.enumerateHierarchy { n, _ in n.categoryBitMask = Menagerie.categoryBit }   // (probes and sight lines look through her)
        let w = wings, left = leftHinge, right = rightHinge, liftNode = self.lift
        let flap = SCNAction.customAction(duration: 1) { n, _ in
            let t = CACurrentMediaTime()
            let dt = Float(w.last == 0 ? 0 : min(0.1, t - w.last))
            w.last = t
            w.phase += dt * w.rate
            let a = w.rest + w.amplitude * sin(w.phase * 2 * .pi)
            left.eulerAngles.z = -a
            right.eulerAngles.z = a
            // Up and over the player's head rather than through it.
            var target = w.cruise
            if let cam = w.camera {
                let c = cam.presentation.worldPosition
                if hypotf(c.x - n.position.x, c.z - n.position.z) < 0.9 { target = max(target, 2.35) }
            }
            w.height += (target - w.height) * min(1, dt * 2.5)
            liftNode.position.y = w.height + 0.035 * sin(w.phase * 2 * .pi + 1.2)   // a lift on each downstroke
        }
        root.runAction(.repeatForever(flap), forKey: "flap")
        startAttention(camera: camera)
    }

    // MARK: Her eyes (Oct 18, phase 2)

    private func startAttention(camera: SCNNode?) {
        let a = CritterAttention(id: Butterfly.id, eyes: CritterEyes(pivots: eyePivots, lids: eyeLids, maxYaw: 1.0, maxPitch: 0.6),
                                 body: root)
        a.noticeRange = 7
        let head = tilt, r = root
        a.eyePoint = { [weak head] in
            guard let head, head.parent != nil else { return nil }
            let w = head.convertPosition(SCNVector3(0, 0.01, -0.07), to: nil)
            return SIMD3<Float>(w.x, w.y, w.z)
        }
        a.forward = { [weak r] in
            guard let f = r?.simdWorldFront else { return SIMD2<Float>(0, -1) }
            let v = SIMD2<Float>(f.x, f.z)
            return simd_length(v) > 0.001 ? simd_normalize(v) : SIMD2<Float>(0, -1)
        }
        a.player = { [weak camera] in
            guard let p = camera?.presentation.worldPosition else { return nil }
            return SIMD3<Float>(p.x, p.y, p.z)
        }
        a.isMoving = { [weak self] in self?.isFlying ?? false }
        a.isBusy = { [weak self] in self?.gesturing ?? false }
        a.turnBody = { [weak self] p in
            guard let self, !self.isFlying, !self.gesturing else { return }
            self.face(Self.heading(p - self.here), duration: 0.5)
        }
        // Her antennae lean the way her eyes look (and perk up or droop with her mood).
        a.onLook = { [weak self] yaw, pitch in
            guard let self else { return }
            for (node, base) in self.antennae {
                node.eulerAngles = SCNVector3(base.x - pitch * 0.5 + self.antennaPerk, base.y + yaw * 0.6, base.z)
            }
        }
        a.express = { [weak self] e in self?.express(e) }
        attention = a
        a.start()
    }

    private func perk(_ amount: Float, for seconds: Double) {
        antennaPerk = amount
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.antennaPerk == amount else { return }
            self.antennaPerk = 0
        }
    }

    /// Her part of an expression: antennae, glow, wings, a tilt of the head.
    private func express(_ e: CritterExpression) {
        switch e {
        case .surprised:
            perk(-0.45, for: 0.9)
            glowPulse(times: 1)
            flutterBurst(seconds: 0.4)
            if !gesturing { hop(0.05) }
        case .curious:
            perk(-0.15, for: 1.5)
            guard !gesturing else { return }
            let tip = SCNAction.rotateBy(x: 0, y: 0, z: 0.22, duration: 0.3)
            tip.timingMode = .easeInEaseOut
            tilt.runAction(.sequence([tip, .wait(duration: 0.9), tip.reversed()]))
        case .hesitant:
            perk(0.35, for: 1.3)
        case .recognizing:
            perk(-0.2, for: 1.0)
            glowPulse(times: 2)
        case .followMe:
            perk(-0.3, for: 3.0)
            glowPulse(times: 1)
        case .drowsy:
            perk(0.25, for: 3.0)
        case .calm:
            break
        }
    }

    /// Round and round something (a lamp, say): onto a circle about it, then
    /// `loops` times round at `height`, facing along the way.
    func circle(around c: SIMD2<Float>, radius: Float, height: Float, loops: Float, then: @escaping () -> Void) {
        let start = here
        let a0 = simd_length(start - c) > 0.01 ? atan2(start.y - c.y, start.x - c.x) : 0
        let entry = c + SIMD2<Float>(cos(a0), sin(a0)) * radius
        wings.cruise = height
        var token = 0
        travel([entry]) { [weak self] in
            guard let self else { then(); return }
            guard self.motion == token else { return }        // (a newer flight took over)
            let duration = Double(2 * Float.pi * radius * loops / Self.cruise) + 0.2
            let dir: Float = Bool.random() ? 1 : -1
            let move = SCNAction.customAction(duration: duration) { n, elapsed in
                let u = Float(min(1, elapsed / CGFloat(duration)))
                let a = a0 + dir * u * loops * 2 * .pi
                let p = c + SIMD2<Float>(cos(a), sin(a)) * radius
                n.position = SCNVector3(p.x, 0, p.y)
                let t = SIMD2<Float>(-sin(a), cos(a)) * dir
                n.eulerAngles = SCNVector3(0, atan2(-t.x, -t.y), 0)
            }
            self.root.runAction(move, forKey: "move") { DispatchQueue.main.async { then() } }
        }
        token = motion
    }

    var node: SCNNode? { root.parent != nil ? root : nil }
    /// Oct 18 (visible-life repair): her MODEL position. Her own flights write
    /// it every frame, so it's always where she is -- whereas the presentation
    /// copy of a body just added to the scene still reads the world origin
    /// until SceneKit commits a frame, and a flight planned at once from there
    /// (spawn, then rest/hover) started from the far corner of the map.
    var groundPosition: SIMD2<Float>? {
        guard root.parent != nil else { return nil }
        return SIMD2<Float>(root.position.x, root.position.z)
    }
    var isGesturing: Bool { gesturing }
    private var here: SIMD2<Float> { groundPosition ?? SIMD2<Float>(root.position.x, root.position.z) }
    static func heading(_ v: SIMD2<Float>) -> Float { atan2(-v.x, -v.y) }

    /// Put her somewhere (no flight): x, z on the floor, at `height`.
    func place(at p: SIMD2<Float>, height: Float, heading: Float) {
        root.position = SCNVector3(p.x, 0, p.y)
        root.eulerAngles.y = heading
        wings.cruise = height
        wings.height = height
    }

    // MARK: The model

    private func build() {
        let s: Float = 1.25
        tilt.scale = SCNVector3(s, s, s)
        let velvet = SupplyModels.mat(UIColor(red: 0.2, green: 0.1, blue: 0.3, alpha: 1), rough: 0.9)
        let thorax = SCNNode(geometry: SCNCapsule(capRadius: 0.02, height: 0.085))
        thorax.geometry?.materials = [velvet]
        thorax.eulerAngles.x = .pi / 2
        tilt.addChildNode(thorax)
        let abdomen = SCNNode(geometry: SCNCapsule(capRadius: 0.016, height: 0.11))
        abdomen.geometry?.materials = [velvet]
        abdomen.eulerAngles.x = .pi / 2 + 0.25
        abdomen.position = SCNVector3(0, -0.008, 0.075)
        tilt.addChildNode(abdomen)
        _ = SupplyModels.part(SCNSphere(radius: 0.025), velvet, in: tilt, at: SCNVector3(0, 0.004, -0.055))
        // The eyes: big, round, glowing gold, each with a glint and a soft halo.
        let eye = SCNMaterial(); eye.lightingModel = .constant
        eye.diffuse.contents = UIColor(red: 1, green: 0.82, blue: 0.3, alpha: 1)
        let glint = SCNMaterial(); glint.lightingModel = .constant; glint.diffuse.contents = UIColor.white
        let halo = SCNMaterial()
        halo.lightingModel = .constant
        halo.diffuse.contents = Self.haloImage()
        halo.blendMode = .add
        halo.writesToDepthBuffer = false
        // Oct 18 (phase 2): each eye a pivot (it turns to look) and a lid (it
        // blinks), with a dark pupil and its glint on the gold -- the same eyes, now looking.
        let pupil = SCNMaterial(); pupil.lightingModel = .constant
        pupil.diffuse.contents = UIColor(red: 0.06, green: 0.02, blue: 0.09, alpha: 1)
        for x in [Float(-0.016), 0.016] {
            let pivot = SCNNode()
            pivot.position = SCNVector3(x, 0.01, -0.07)
            tilt.addChildNode(pivot)
            let lid = SCNNode()
            pivot.addChildNode(lid)
            _ = SupplyModels.part(SCNSphere(radius: 0.0145), eye, in: lid)
            let dot = SupplyModels.part(SCNSphere(radius: 0.0068), pupil, in: lid, at: SCNVector3(0, 0, -0.0122))
            dot.scale = SCNVector3(1, 1, 0.45)
            _ = SupplyModels.part(SCNSphere(radius: 0.0032), glint, in: lid, at: SCNVector3(-0.0035, 0.0045, -0.0142))
            eyePivots.append(pivot)
            eyeLids.append(lid)
            let h = SupplyModels.part(SCNPlane(width: 0.07, height: 0.07), halo, in: tilt, at: SCNVector3(x, 0.01, -0.072))
            h.constraints = [SCNBillboardConstraint()]
            halos.append(h)
        }
        // Antennae with softly lit tips.
        let tip = SCNMaterial(); tip.lightingModel = .constant
        tip.diffuse.contents = UIColor(red: 0.55, green: 0.95, blue: 1, alpha: 1)
        for side in [Float(-1), 1] {
            let a = SCNNode()
            a.position = SCNVector3(side * 0.008, 0.024, -0.062)
            a.eulerAngles = SCNVector3(-0.7, 0, side * -0.35)
            tilt.addChildNode(a)
            antennae.append((a, a.eulerAngles))
            SupplyModels.rod(0.0018, 0.075, SupplyModels.mat(UIColor(white: 0.1, alpha: 1)), in: a, at: SCNVector3(0, 0.0375, 0))
            _ = SupplyModels.part(SCNSphere(radius: 0.0065), tip, in: a, at: SCNVector3(0, 0.077, 0))
        }
        // The wings: fore and hind on each side, hinged at the body.
        let fore = Self.wingMaterial(hind: false), hind = Self.wingMaterial(hind: true)
        for (hinge, side) in [(leftHinge, Float(-1)), (rightHinge, Float(1))] {
            hinge.position = SCNVector3(side * 0.012, 0.012, 0)
            tilt.addChildNode(hinge)
            for (m, w, h, z) in [(fore, Float(0.21), Float(0.164), Float(-0.035)), (hind, Float(0.15), Float(0.135), Float(0.055))] {
                let plane = SCNNode(geometry: SCNPlane(width: CGFloat(w), height: CGFloat(h)))
                plane.geometry?.materials = [m]
                plane.eulerAngles.x = -.pi / 2                         // flat; the image's top edge points forward
                plane.position = SCNVector3(side * w / 2, z == Float(0.055) ? -0.004 : 0, z)
                if side < 0 { plane.scale = SCNVector3(-1, 1, 1) }      // (the left wing: mirrored)
                hinge.addChildNode(plane)
            }
        }
    }

    private static func haloImage() -> UIImage {
        let size = CGSize(width: 64, height: 64)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(red: 1, green: 0.8, blue: 0.35, alpha: 0.85).cgColor, UIColor(red: 1, green: 0.7, blue: 0.2, alpha: 0).cgColor] as CFArray
            guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            ctx.cgContext.drawRadialGradient(g, startCenter: CGPoint(x: 32, y: 32), startRadius: 0, endCenter: CGPoint(x: 32, y: 32),
                                             endRadius: 32, options: [])
        }
    }

    /// A wing: violet at the root to teal at the tip, dark veins and edge,
    /// pale spots -- with a faint glow (spots and edge) for the dark.
    private static func wingMaterial(hind: Bool) -> SCNMaterial {
        let size = hind ? CGSize(width: 200, height: 180) : CGSize(width: 256, height: 200)
        func outline() -> UIBezierPath {
            let p = UIBezierPath()
            if hind {
                p.move(to: CGPoint(x: 0, y: 30))
                p.addCurve(to: CGPoint(x: 185, y: 95), controlPoint1: CGPoint(x: 90, y: 10), controlPoint2: CGPoint(x: 180, y: 40))
                p.addCurve(to: CGPoint(x: 95, y: 175), controlPoint1: CGPoint(x: 195, y: 150), controlPoint2: CGPoint(x: 150, y: 180))
                p.addCurve(to: CGPoint(x: 0, y: 80), controlPoint1: CGPoint(x: 45, y: 170), controlPoint2: CGPoint(x: 15, y: 120))
            } else {
                p.move(to: CGPoint(x: 0, y: 95))
                p.addCurve(to: CGPoint(x: 235, y: 18), controlPoint1: CGPoint(x: 60, y: 15), controlPoint2: CGPoint(x: 170, y: 2))
                p.addCurve(to: CGPoint(x: 220, y: 150), controlPoint1: CGPoint(x: 262, y: 50), controlPoint2: CGPoint(x: 258, y: 128))
                p.addCurve(to: CGPoint(x: 0, y: 128), controlPoint1: CGPoint(x: 150, y: 178), controlPoint2: CGPoint(x: 60, y: 155))
            }
            p.close()
            return p
        }
        let spots: [(CGFloat, CGFloat, CGFloat)] = hind ? [(120, 120, 13), (70, 135, 9)] : [(192, 58, 15), (212, 108, 11), (150, 92, 9)]
        let diffuse = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let shape = outline()
            c.saveGState()
            shape.addClip()
            let colors = (hind
                ? [UIColor(red: 0.42, green: 0.12, blue: 0.55, alpha: 1).cgColor, UIColor(red: 0.85, green: 0.3, blue: 0.75, alpha: 1).cgColor]
                : [UIColor(red: 0.3, green: 0.12, blue: 0.6, alpha: 1).cgColor, UIColor(red: 0.1, green: 0.75, blue: 0.85, alpha: 1).cgColor]) as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                c.drawRadialGradient(g, startCenter: CGPoint(x: 0, y: size.height / 2), startRadius: 0,
                                     endCenter: CGPoint(x: 0, y: size.height / 2), endRadius: size.width, options: [])
            }
            c.setStrokeColor(UIColor(red: 0.08, green: 0.04, blue: 0.12, alpha: 0.45).cgColor)
            c.setLineWidth(3)
            for k in 0..<5 {
                c.move(to: CGPoint(x: 0, y: size.height / 2))
                c.addLine(to: CGPoint(x: size.width, y: CGFloat(k) * size.height / 4))
            }
            c.strokePath()
            UIColor(red: 0.85, green: 1, blue: 1, alpha: 1).setFill()
            for (x, y, r) in spots { c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)) }
            c.restoreGState()
            c.setStrokeColor(UIColor(red: 0.08, green: 0.04, blue: 0.12, alpha: 1).cgColor)
            c.setLineWidth(9)
            c.addPath(shape.cgPath)
            c.strokePath()
        }
        let glow = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            UIColor.black.setFill(); c.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.5, green: 1, blue: 1, alpha: 1).setFill()
            for (x, y, r) in spots { c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)) }
            c.setStrokeColor(UIColor(red: 0.35, green: 0.8, blue: 1, alpha: 0.7).cgColor)
            c.setLineWidth(3)
            c.addPath(outline().cgPath)
            c.strokePath()
        }
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = diffuse
        m.emission.contents = glow
        m.emission.intensity = 0.75
        m.isDoubleSided = true
        return m
    }

    // MARK: Sound and small motions

    /// Oct 18 (resident audio): through CritterAudio -- the continuous distance
    /// fade, walls and doors, Mute -- from where she is. (Was a raw playAudio:
    /// the same loudness anywhere on the floor.)
    private func play(_ source: SCNAudioSource?) {
        guard let source, root.parent != nil else { return }
        CritterAudio.play(source, on: root)
    }

    /// Her wings, softly -- at most every few seconds (never a steady beat).
    private var lastWings: CFTimeInterval = 0
    private func wingsSound(chance: Float = 1) {
        let now = CACurrentMediaTime()
        guard now - lastWings > 3.5, Float.random(in: 0...1) < chance else { return }
        lastWings = now
        play(ResidentVoice.butterflyWings.randomElement())
    }

    private func face(_ h: Float, duration: Double = 0.35) {
        root.removeAction(forKey: "face")
        root.runAction(.rotateTo(x: 0, y: CGFloat(h), z: 0, duration: duration, usesShortestUnitArc: true), forKey: "face")
    }

    private func hop(_ dy: CGFloat = 0.12) {
        let up = SCNAction.moveBy(x: 0, y: dy, z: 0, duration: 0.12); up.timingMode = .easeOut
        let down = SCNAction.moveBy(x: 0, y: -dy, z: 0, duration: 0.2); down.timingMode = .easeIn
        tilt.runAction(.sequence([up, down]))
    }

    private func glowPulse(times: Int) {
        let pulse = SCNAction.sequence([.scale(to: 1.8, duration: 0.18), .scale(to: 1, duration: 0.3)])
        for h in halos { h.runAction(.repeat(pulse, count: times), forKey: "pulse") }
    }

    private func flutterBurst(seconds: Double) {
        let w = wings
        w.rate = 14
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            w.rate = self.perched ? 0.55 : 9
        }
    }

    private func unperch() {
        guard perched else { return }
        perched = false
        wings.rate = 9; wings.amplitude = 0.85; wings.rest = 0.25
        wings.cruise = Self.cruise
    }

    private func settleWings() {
        perched = true
        wings.rate = 0.55; wings.amplitude = 0.3; wings.rest = 1.05            // resting: wings up, slowly breathing
    }

    // MARK: LeadPerformer

    func travel(_ path: [SIMD2<Float>], then: @escaping () -> Void) {
        motion += 1
        unperch()
        root.removeAction(forKey: "face")
        root.removeAction(forKey: "move")
        var points = [here]
        for p in path where simd_distance(p, points[points.count - 1]) > 0.05 { points.append(p) }
        guard points.count > 1 else { DispatchQueue.main.async { then() }; return }
        var cumulative: [Float] = [0]
        for i in 1..<points.count { cumulative.append(cumulative[i - 1] + simd_distance(points[i], points[i - 1])) }
        let total = cumulative[cumulative.count - 1]
        let duration = Double(total / Self.speed) + 0.2
        if total > 1.5 { wingsSound(chance: 0.5) }        // (Oct 18: a soft flutter as she sets off, now and then)
        let pts = points, cum = cumulative
        func point(at s: Float) -> SIMD2<Float> {
            var i = 0
            while i < cum.count - 2 && cum[i + 1] < s { i += 1 }
            let span = max(0.0001, cum[i + 1] - cum[i])
            let t = min(1, max(0, (s - cum[i]) / span))
            return pts[i] + (pts[i + 1] - pts[i]) * t
        }
        var heading = root.eulerAngles.y
        var lastElapsed: CGFloat = 0
        let move = SCNAction.customAction(duration: duration) { n, elapsed in
            let u = Float(min(1, elapsed / CGFloat(duration)))
            let along = (0.3 * (u * u * (3 - 2 * u)) + 0.7 * u) * total
            var p = point(at: along)
            let ahead = point(at: min(total, along + 0.3)) - p
            if simd_length(ahead) > 0.01 {
                let dir = simd_normalize(ahead)
                // Never a rail: a soft weave either side, fading in and out.
                let fade = min(1, along / 0.6) * min(1, max(0, total - along) / 0.6)
                p += SIMD2<Float>(-dir.y, dir.x) * (sin(along * 2.6) * 0.14 * fade)
                let dt = Float(max(0, elapsed - lastElapsed))
                var turn = atan2(-dir.x, -dir.y) - heading
                while turn > .pi { turn -= 2 * .pi }
                while turn < -.pi { turn += 2 * .pi }
                heading += turn * min(1, dt * 9)
                n.eulerAngles.y = heading
            }
            lastElapsed = elapsed
            n.position = SCNVector3(p.x, 0, p.y)
        }
        root.runAction(move, forKey: "move") { DispatchQueue.main.async { then() } }
    }

    func touch(_ point: SIMD2<Float>, contact: @escaping () -> Void, then: @escaping () -> Void) {
        let start = here
        let d = point - start
        let len = simd_length(d)
        let stop = len > 0.3 ? start + d * ((len - 0.25) / len) : start
        gesturing = true
        travel([stop]) { [weak self] in
            self?.play(ButterflySound.chirp)
            self?.hop(0.06)
            contact()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard let self else { then(); return }
                self.travel([start]) { [weak self] in
                    self?.gesturing = false
                    then()
                }
            }
        }
    }

    func watch(_ player: SIMD2<Float>) {
        guard !gesturing, root.action(forKey: "move") == nil else { return }
        face(Self.heading(player - here))
    }

    func pointOnward(_ onward: SIMD2<Float>, player: SIMD2<Float>) {
        guard !gesturing else { return }
        // Oct 18 (phase 2): FOLLOW ME, with her eyes -- you, that way, you, that way.
        let way = here + (simd_length(onward) > 0.01 ? simd_normalize(onward) : onward) * 3
        attention?.followMe(onward: SIMD3<Float>(way.x, 1.3, way.y))
        gesturing = true
        let start = here
        travel([start + onward * 0.7]) { [weak self] in
            self?.play(ButterflySound.chirp)
            self?.travel([start]) { [weak self] in
                guard let self else { return }
                self.gesturing = false
                self.face(Self.heading(player - self.here))
            }
        }
    }

    func call() {
        play(ButterflySound.chirp2)
        hop()
        flutterBurst(seconds: 0.5)
    }

    /// Oct 20 (follow a critter): her come-hither when the player chooses to
    /// follow her -- a chirp, a bob, a glow and a flutter, a turn to them if
    /// she's still; then on she goes (nothing of her flight is changed).
    func acknowledgeFollower(player: SIMD2<Float>?) {
        if let p = player, !gesturing, root.action(forKey: "move") == nil { face(Self.heading(p - here)) }
        if !ResidentMusic.greet(Butterfly.id, on: root) { play(ButterflySound.chirp) }     // Oct 22 (musical building): her signature
        hop(0.08)
        glowPulse(times: 2)
        flutterBurst(seconds: 0.5)
        attention?.react(.recognizing, for: 1.2)
    }

    func urge(player: SIMD2<Float>, onward: SIMD2<Float>?, then: @escaping () -> Void) {
        gesturing = true
        face(Self.heading(player - here))
        play(ButterflySound.chirp2)
        hop(0.15)
        glowPulse(times: 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.play(ButterflySound.chirp2)
            self?.hop(0.15)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { then(); return }
            guard let onward else { self.gesturing = false; then(); return }
            let start = self.here
            self.travel([start + onward * 0.8]) { [weak self] in
                self?.travel([start]) { [weak self] in
                    self?.gesturing = false
                    then()
                }
            }
        }
    }

    func arrive(player: SIMD2<Float>) {
        face(Self.heading(player - here))
        wings.rate = 8
    }

    func depart() {
        wings.rate = 9
        wingsSound()                                     // (Oct 18: was ButterflySound.flutter, a 140 Hz thud)
    }

    func settle(facing heading: Float?) {
        if let heading { face(heading) }
    }

    // MARK: InformantBody

    func hail(player: SIMD2<Float>) {
        gesturing = true
        face(Self.heading(player - here))
        let loop = SCNAction.rotateBy(x: -2 * .pi, y: 0, z: 0, duration: 0.55)       // a loop-the-loop
        loop.timingMode = .easeInEaseOut
        tilt.runAction(.sequence([loop, .wait(duration: 0.35), loop]))
        play(ButterflySound.chirp2)
        glowPulse(times: 3)
        flutterBurst(seconds: 1.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.play(ButterflySound.chirp2) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.gesturing = false }
    }

    func rejoice(big: Bool) {
        let twirl = SCNAction.rotateBy(x: 0, y: big ? 4 * .pi : 2 * .pi, z: 0, duration: big ? 1.4 : 0.55)
        twirl.timingMode = .easeInEaseOut
        if big {
            let rise = SCNAction.moveBy(x: 0, y: 0.5, z: 0, duration: 0.7); rise.timingMode = .easeOut
            let fall = SCNAction.moveBy(x: 0, y: -0.5, z: 0, duration: 0.7); fall.timingMode = .easeIn
            tilt.runAction(.group([twirl, .sequence([rise, fall])]))
            glowPulse(times: 4)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.play(ButterflySound.trill) }
        } else {
            tilt.runAction(twirl)
            glowPulse(times: 1)
        }
        play(ButterflySound.trill)
        flutterBurst(seconds: big ? 1.6 : 0.6)
    }

    func sulk() {
        play(ButterflySound.sad)
        let w = wings
        let was = w.cruise
        w.cruise = max(1.1, was - 0.35)
        w.rate = 4
        let droop = SCNAction.rotateBy(x: 0.35, y: 0, z: 0, duration: 0.5)
        tilt.runAction(.sequence([droop, .wait(duration: 1.6), droop.reversed()]))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.perched else { return }
            w.cruise = was
            w.rate = 9
        }
    }

    func fret() {
        play(ButterflySound.worry)
        let shake = SCNAction.sequence([.rotateBy(x: 0, y: 0, z: 0.35, duration: 0.08), .rotateBy(x: 0, y: 0, z: -0.7, duration: 0.14),
                                        .rotateBy(x: 0, y: 0, z: 0.35, duration: 0.08)])
        tilt.runAction(.repeat(shake, count: 2))
    }

    func perch(at point: SIMD3<Float>, then: @escaping () -> Void) {
        travel([SIMD2<Float>(point.x, point.z)]) { [weak self] in
            guard let self else { return }
            self.wings.cruise = point.y
            self.settleWings()
            then()
        }
    }

    func indicate(_ target: SIMD3<Float>) {
        guard !gesturing, !isFlying else { return }
        let toward = SIMD2<Float>(target.x, target.z) - here
        face(Self.heading(toward), duration: 0.25)
        play(ButterflySound.chirp)
        if perched {
            // A bow toward it, a flick of the wings.
            let bow = SCNAction.rotateBy(x: 0.45, y: 0, z: 0, duration: 0.2)
            tilt.runAction(.sequence([bow, bow.reversed(), bow, bow.reversed()]))
            let w = wings
            w.rate = 3
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.perched else { return }
                w.rate = 0.55
            }
        } else {
            gesturing = true
            let start = here
            let len = simd_length(toward)
            let dart = len > 0.05 ? start + toward / len * min(0.45, len * 0.4) : start
            travel([dart]) { [weak self] in
                self?.travel([start]) { [weak self] in self?.gesturing = false }
            }
        }
    }

    func hover(at point: SIMD2<Float>, height: Float, then: @escaping () -> Void) {
        travel([point]) { [weak self] in
            self?.wings.cruise = height
            then()
        }
    }

    /// Resting on a wall (her own life): settle at a point and fold up.
    func rest(at point: SIMD3<Float>, facing heading: Float) {
        travel([SIMD2<Float>(point.x, point.z)]) { [weak self] in
            guard let self else { return }
            self.wings.cruise = point.y
            self.face(heading, duration: 0.6)
            self.settleWings()
        }
    }
}

// MARK: Her life

enum Butterfly {
    nonisolated static let lifeKey = "critter.butterfly.life.v1"

    /// What she does where she is: rest on a wall, hover looking at something, potter.
    enum Activity: String { case rest, investigate, wander }

    /// Oct 18 (room-based life): her ordinary life is the building's ROOMS on
    /// the floors she likes -- the same Roam every resident uses (RoomRegistry
    /// decides where the rooms are, from the map). Her old list of favourite
    /// cells is gone: destinations belong to rooms, not to critters.
    /// (Oct 18, open the building: Floor 5 her home; never Floor 3 now -- Tinky's office and the meeting.)
    static let normalStyle = RoamStyle(floors: [4: 1, 5: 2, 6: 0.5, 7: 0.5, 11: 0.5], stay: 25...60, speed: ButterflyBody.speed, changeFloorChance: 0.3)
    static let fastStyle = RoamStyle(floors: [4: 1, 5: 2, 6: 0.5, 7: 0.5, 11: 0.5], stay: 8...15, speed: ButterflyBody.speed, changeFloorChance: 0.5,
                                     elevatorRide: 12)
    static var style: RoamStyle { BuildingLife.pacing(normal: normalStyle, fast: fastStyle) }
    static let abilities: Set<ResidentAbility> = [.fly, .rideElevator]

    /// Her life worked forward to `now` (offscreen, or between her doings).
    static func live(_ r: inout Resident, to now: Date, plans: ((Int) -> FloorPlan?)? = nil) {
        Roam.advance(&r, style: style, abilities: abilities, plans: plans ?? BuildingLife.shared.plans, to: now)
    }

    /// Oct 18 (building life): her record is a Resident like any other (owned
    /// by BuildingLife, key building.residents.v1) -- same fields as her old
    /// Life: on `floor` (in `cell`, if she has a spot there) from `since`
    /// (later than now = still on her way), for `dwell` seconds; `haunt` her
    /// place in the list; her informant memory per problem.
    typealias Life = Resident
    static let id = "butterfly"

    /// Where she starts (a new building, Start Over): by the vending machine.
    static func newcomer(now: Date) -> Resident {
        Resident(id: id, kind: ButterflyKind.kindName, floor: 5, cell: GridCoordinate(row: 9, col: 17), since: now, dwell: 200)
    }

    /// Oct 18: her record as the Oct 17 build saved it (critter.butterfly.life.v1),
    /// read once to carry her over -- where she is, since when, her memory.
    private struct LegacyLife: Decodable {
        var floor: Int
        var cell: GridCoordinate?
        var haunt: Int
        var since: Date
        var dwell: Double
        var moves: Int
        var memory: InformantMemory
    }
    static func legacyLife(in defaults: UserDefaults) -> Resident? {
        guard let data = defaults.data(forKey: lifeKey), let old = try? JSONDecoder().decode(LegacyLife.self, from: data) else { return nil }
        var r = Resident(id: id, kind: ButterflyKind.kindName, floor: old.floor, cell: old.cell, since: old.since, dwell: old.dwell)
        r.haunt = old.haunt
        r.moves = old.moves
        r.memory = old.memory
        diag("butterfly.migrated", ["floor": old.floor, "haunt": old.haunt, "moves": old.moves, "lapses": old.memory.lapses])
        return r
    }

    static let concern = FloorFiveLightsConcern()
    /// She boarded with the player during this run of the app (so a
    /// destination floor's cab has her in it).
    static var boardedWithPlayer = false

    /// Start Over (her record itself is cleared with everyone's: BuildingLife.resetForNewPlayer).
    static func resetForNewPlayer() {
        boardedWithPlayer = false
    }
}

/// Oct 18 (building life): the butterfly as a resident kind -- room to room
/// (Roam, Butterfly.style) is her offscreen life; ButterflyFloor is her
/// presentation on the player's floor (unchanged in what she does).
final class ButterflyKind: ResidentKind {
    static let kindName = "butterfly"
    let kind = ButterflyKind.kindName
    var abilities: Set<ResidentAbility> { Butterfly.abilities }
    var legacyKeys: [String] { [Butterfly.lifeKey] }

    func newcomers(now: Date) -> [Resident] { [Butterfly.newcomer(now: now)] }

    func legacyResidents(in defaults: UserDefaults) -> [Resident] {
        Butterfly.legacyLife(in: defaults).map { [$0] } ?? []
    }

    func advance(_ r: inout Resident, to now: Date, plans: (Int) -> FloorPlan?) {
        Roam.advance(&r, style: Butterfly.style, abilities: Butterfly.abilities, plans: plans, to: now)
    }

    /// Oct 18 (inter-floor test): the Floor 5 lights come before her room round --
    /// said on the panel so a butterfly that won't leave F5 isn't a mystery.
    func priorityNote(_ r: Resident, now: Date) -> String? {
        let concern = Butterfly.concern
        guard concern.isActive else { return nil }
        let lit = "\(concern.progress)/8 circuits on"
        if let rest = r.memory.restUntil, rest > now {
            return "F5 lights mission (\(lit)): resting from guiding \(LifeLog.seconds(rest.timeIntervalSince(now))) more, rooms meanwhile"
        }
        return "F5 lights mission FIRST (\(lit)): on F5 she stays to guide you; you on F5 -> she comes"
    }

    /// (Oct 17's Butterfly.floorBuilt, moved: same gates, same start.)
    func present(_ id: String, on stage: FloorStage) -> ResidentPresentation? {
        let rodeHere = Butterfly.boardedWithPlayer
        Butterfly.boardedWithPlayer = false
        guard Admission.isCompleted, !Admission.isQuietOnboarding(floor: stage.floor), let context = stage.context,
              let root = stage.root, let camera = stage.camera, let controller = stage.controller,
              var life = BuildingLife.shared.resident(id) else {
            let why = !Admission.isCompleted ? "admission not completed"
                : Admission.isQuietOnboarding(floor: stage.floor) ? "quiet onboarding floor"
                : stage.context == nil ? "no floor context" : "scene not ready"
            LifeLog.event(id, "presenter.declined", floor: stage.floor, ["why": why])
            return nil
        }
        Butterfly.live(&life, to: BuildingClock.now())
        BuildingLife.shared.store(life)
        let f = ButterflyFloor(residentID: id, floor: stage.floor, root: root, camera: camera, controller: controller, context: context)
        f.start(arrivedRiding: rodeHere && life.memory.riding)
        return f
    }
}

/// Her informant memory is kept per problem; hers is the Floor 5 lights.
extension Resident {
    fileprivate var memory: InformantMemory {
        get { memories[Butterfly.concern.name] ?? InformantMemory() }
        set { memories[Butterfly.concern.name] = newValue }
    }
}

/// Her life on the floor the player is on (rebuilt with every scene).
/// Oct 18: her presentation in BuildingLife -- her record lives there (read
/// and written through `life`); this is her body and her doings on this floor.
final class ButterflyFloor: ResidentPresentation {
    let residentID: String
    let floor: Int
    private weak var root: SCNNode?
    private weak var camera: SCNNode?
    private weak var controller: TapNavigationController?
    private let context: CharacterLead.Context
    private var life: Resident {
        get { BuildingLife.shared.resident(residentID) ?? Butterfly.newcomer(now: BuildingClock.now()) }
        set { BuildingLife.shared.store(newValue) }
    }
    private var body: ButterflyBody?
    private var guide: InformantGuide?
    private var timer: Timer?
    private var nextAct: CFTimeInterval = 0
    private var arrivalDue: CFTimeInterval?
    private var busy = false                    // coming or going by the elevator
    private var leaveTries = 0
    private var nearSince: CFTimeInterval?
    private var busySince: CFTimeInterval = 0
    private var nearDoorsSince: CFTimeInterval?
    private var routineRetryAt: CFTimeInterval = 0
    private var rng: Rand

    init(residentID: String, floor: Int, root: SCNNode, camera: SCNNode, controller: TapNavigationController,
         context: CharacterLead.Context) {
        self.residentID = residentID
        self.floor = floor
        self.root = root
        self.camera = camera
        self.controller = controller
        self.context = context
        let moves = BuildingLife.shared.resident(residentID)?.moves ?? 0
        rng = Rand(seed: UInt64(max(0, moves)) &* 31 &+ UInt64(max(0, floor)) &* 7 &+ 1)
    }

    // MARK: ResidentPresentation (Oct 18)

    var holdsResident: Bool { body != nil || busy }
    var bodyNode: SCNNode? { body?.node }
    var isRendered: Bool { body?.node != nil }
    var bodyPosition: SIMD2<Float>? { body?.groundPosition }
    var isGuiding: Bool { guide?.isGuiding ?? false }
    /// Oct 20 (follow a critter): chosen to be followed -- her come-hither, once (never while she guides).
    func acknowledgeFollower(player: SIMD2<Float>?) {
        guard !isGuiding, let body else { return }
        body.acknowledgeFollower(player: player)
        LifeLog.event(residentID, "follow.acknowledged", floor: floor, [:])
    }
    /// Oct 18: what her mission has her doing (the panel says so instead of her room round).
    var missionNote: String? {
        guard let guide, guide.isGuiding else { return nil }
        let to = guide.target.map { t in t.floor == floor ? "the \(t.tag) (F\(t.floor))" : "the elevator, for the \(t.tag) on F\(t.floor)" }
        return "GUIDING (\(guide.phase.rawValue))" + (to.map { " -> " + $0 } ?? "") + " [\(Butterfly.concern.name)]"
    }
    /// (her own timer, twice a second, does her doings -- as before)
    func tick(now: Date) {}
    var debugState: String {
        guard let body else { return busy ? "in the elevator's door cycle" : "" }
        let at = body.groundPosition.map { LifeLog.cell(cellOf($0)) } ?? "-"
        return "at \(at), guide \(guide?.phase.rawValue ?? "none")" + (busy ? ", using the elevator" : "")
            + ((life.memory.restUntil ?? .distantPast) > BuildingClock.now() ? ", resting from guiding" : "")
    }
    /// How long after a rebuild she's put back where she was (not at home).
    static let keepPoseFor: TimeInterval = 180

    private var s: Float { context.cellSize }
    private func cellOf(_ p: SIMD2<Float>) -> GridCoordinate {
        GridCoordinate(row: Int((p.y / s).rounded()), col: Int((p.x / s).rounded()))
    }
    private func center(_ c: GridCoordinate) -> SIMD2<Float> { SIMD2<Float>(Float(c.col) * s, Float(c.row) * s) }
    private var playerInElevator: Bool {
        guard let c = controller else { return true }
        return c.isElevatorWaitingForFloor || c.isElevatorRideInProgress
    }
    /// On this floor by her record: there already, or on her way within the floor
    /// (Oct 18: a same-floor move between rooms has no leg -- she's here, flying).
    /// (Oct 18, inter-floor life: by the elevator, she's here from the moment her
    /// ride is booked to end -- out she comes then, and flies to her room.)
    private var present: Bool {
        let now = BuildingClock.now()
        return life.floor == floor && (now >= life.since || life.leg == nil
                                       || (life.leg?.changesFloor == true && now >= (life.leg?.alightAt ?? .distantFuture)))
    }
    private var concernHere: Bool {
        Butterfly.concern.isActive && (floor == FloorFiveBlackout.floor || life.memory.engaged)
    }

    private func log(_ event: String, _ fields: KeyValuePairs<String, Any?> = [:]) {
        var line = "butterfly.\(event) floor=\(floor) lifeFloor=\(life.floor)"
        for (k, v) in fields { line += " \(k)=\(v.map { "\($0)" } ?? "nil")" }
        diag("butterfly.\(event)", ["floor": floor, "detail": line])
        // Oct 18: on the residents' console with everyone else ([Life] ... butterfly ...).
        LifeLog.event(residentID, event, floor: floor, fields)
    }

    func start(arrivedRiding: Bool) {
        // Oct 25 (PP 3): the lights mission is retired -- a journey under way in an old save
        // (engaged, or riding with the player) is let go, so she never resumes guiding.
        if !Butterfly.concern.isActive, life.memory.engaged || life.memory.riding {
            var m = life.memory; m.engaged = false; m.riding = false; life.memory = m
            log("missionRetired")
        }
        if life.memory.riding {
            // She was with the player: in the cab with them, or (a relaunch) just behind them.
            life.floor = floor
            life.cell = nil
            life.since = BuildingClock.now()
            life.dwell = 240
            if arrivedRiding, let door = controller?.elevatorDoorwayFrame() {
                let side = SIMD2<Float>(-door.outward.y, door.outward.x)
                spawn(at: door.center - door.outward * 0.8 + side * 0.55, height: 2.05, heading: ButterflyBody.heading(door.outward))
                makeGuide()
                guide?.ridingIn()
                log("arrivedRiding")
            } else {
                var m = life.memory; m.riding = false; life.memory = m
                if let pose = context.playerPose() {
                    let back = SIMD2<Float>(sin(pose.yaw), cos(pose.yaw))
                    let p = pose.position + back * 1.4
                    spawn(at: context.cells.contains(cellOf(p)) ? p : pose.position, height: 2.3, heading: pose.yaw)
                    makeGuide()
                }
                log("resumedWithPlayer")
            }
        } else if present, let pose = life.recentPose(on: floor, now: BuildingClock.now(), within: Self.keepPoseFor),
                  pose.at >= life.since {
            // Oct 18: this floor rebuilt (Decorate, the editor): back exactly where she was.
            spawnWhereShown(pose)
            log("backWhereShown", ["x": pose.x, "z": pose.z])
        } else if present {
            spawnAtHome()
            log("home", ["cell": life.cell.map { "\($0.row),\($0.col)" } ?? "-"])
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                if let self { self.tick() } else { t.invalidate() }
            }
        }
    }

    func teardown() {
        timer?.invalidate()
        timer = nil
        // Oct 18: where her body was, for a rebuild of this floor (no teleport home).
        // (Not while she's coming or going through the elevator's doors: then she's in the cab.)
        if !busy, let body, let p = body.groundPosition {
            var l = life
            l.shown = ResidentPose(floor: floor, x: p.x, z: p.y, height: body.wings.height, heading: body.root.eulerAngles.y,
                                   at: BuildingClock.now())
            life = l
        }
        guide?.detach()
        guide = nil
        body?.attention?.stop()
        body?.root.removeAllAudioPlayers()                // (Oct 18: no sound left playing where she was)
        body?.root.removeFromParentNode()
        body = nil
    }

    /// Nobody else (an escort, Bonzo, the meeting) is using the building's attention or its elevator.
    private var elevatorFree: Bool {
        GuidedJourney.trip == nil && !BonzoEviction.isActive && !ConferenceMeeting.isActive
    }

    /// The doors' `done` -- exactly once, and at the latest after `seconds`
    /// (the doors must never be left open, nor the elevator held, by her).
    private func once(_ done: @escaping () -> Void, within seconds: Double = 5) -> () -> Void {
        var called = false
        let fire = { if !called { called = true; done() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { fire() }
        return fire
    }

    private func spawn(at p: SIMD2<Float>, height: Float, heading: Float) {
        guard let root else {
            LifeLog.warn(residentID, "body.notSpawned", floor: floor, ["why": "the scene's root is gone"])
            return
        }
        let b = ButterflyBody(camera: camera)
        b.place(at: p, height: height, heading: heading)
        // Oct 18 (phase 2): she notices the player only where she could see them.
        let ctx = context, size = s
        b.attention?.canSee = { [weak b] q in
            guard let at = b?.groundPosition else { return false }
            let cell = { (v: SIMD2<Float>) in GridCoordinate(row: Int((v.y / size).rounded()), col: Int((v.x / size).rounded())) }
            return CritterSight.connected(cell(at), cell(q), cells: ctx.cells, doors: ctx.doors, isOpen: ctx.isDoorOpen)
        }
        root.addChildNode(b.root)
        LifeMarker.attach(to: b.root, text: "BUTTERFLY", height: 2.75)          // (DEBUG test mode only)
        body = b
        notShownKey = nil
        let player = context.playerPose()?.position
        LifeLog.event(residentID, "body.spawned", floor: floor,
                      ["at": LifeLog.point(p), "cell": LifeLog.cell(cellOf(p)), "height": height,
                       "inScene": b.root.parent != nil, "hidden": b.root.isHidden,
                       "fromPlayer": player.map { simd_distance($0, p) }])
    }

    /// Oct 18: why she's logically here but has no body (said when the reason changes).
    private var notShownKey: String?
    private func noteNotShown(_ why: String) {
        guard why != notShownKey else { return }
        notShownKey = why
        LifeLog.event(residentID, "notShown", floor: floor, ["why": why, "record": "F\(life.floor) \(LifeLog.cell(life.cell))"])
    }

    private func makeGuide() {
        guard let body, let controller else { return }
        let g = InformantGuide(name: "butterfly", body: body, concern: Butterfly.concern, floor: floor, context: context,
                               hooks: .init(doorway: { [weak controller] in controller?.elevatorDoorwayFrame() },
                                            playerInElevator: { [weak controller] in
                                                guard let c = controller else { return true }
                                                return c.isElevatorWaitingForFloor || c.isElevatorRideInProgress
                                            }),
                               memory: life.memory)
        g.onMemoryChanged = { [weak self] m in self?.life.memory = m }
        g.onReleased = { [weak self] in self?.resumeOwnLife() }
        g.attach()
        guide = g
    }

    // MARK: Home and its small doings

    /// Her spot in `cell` for `activity`: up on a wall to rest, by a wall to
    /// look at something, mid-cell to potter.
    private func homePoint(_ cell: GridCoordinate, _ activity: Butterfly.Activity) -> (point: SIMD3<Float>, heading: Float) {
        let c = center(cell)
        let wall = Direction.allCases.first { d in !context.cells.contains(GridCoordinate(row: cell.row + d.delta.row, col: cell.col + d.delta.col)) }
        guard let wall else { return (SIMD3<Float>(c.x, 1.75, c.y), 0) }
        let v = SIMD2<Float>(Float(wall.delta.col), Float(wall.delta.row))
        switch activity {
        case .rest:
            let p = c + v * (s / 2 - 0.16)
            return (SIMD3<Float>(p.x, 2.05, p.y), ButterflyBody.heading(-v))     // (facing out from the wall)
        case .investigate:
            let p = c + v * (s / 2 - 0.6)
            return (SIMD3<Float>(p.x, 1.45, p.y), ButterflyBody.heading(v))      // (looking at it)
        case .wander:
            return (SIMD3<Float>(c.x, 1.75, c.y), 0)
        }
    }

    /// Oct 18 (room-based life): in a room she rests on a wall now and then, and
    /// otherwise hovers, looking about (wings beating fast); anywhere else she
    /// potters. (The controlled test keeps her hovering: easy to see.)
    private var activity: Butterfly.Activity {
        guard life.room != nil, life.cell != nil else { return .wander }
        if BuildingLife.testMode != nil { return .investigate }
        return life.moves % 3 == 0 ? .rest : .investigate
    }

    /// Her own cell here: her haunt's, else a quiet cell well away from the player.
    private func homeCell() -> GridCoordinate {
        if let c = life.cell, context.cells.contains(c) { return c }
        let player = context.playerPose().map { cellOf($0.position) }
        let quiet = context.cells.filter { c in
            guard let player else { return true }
            return abs(c.row - player.row) + abs(c.col - player.col) >= 4
        }.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        let pool = quiet.isEmpty ? context.cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) } : quiet
        let pick = pool[Int(rng.unit() * Float(pool.count)) % max(1, pool.count)]
        life.cell = pick
        return pick
    }

    /// Oct 18: back where she was seen (a rebuild), settling if that's her resting spot.
    private func spawnWhereShown(_ pose: ResidentPose) {
        let p = SIMD2<Float>(pose.x, pose.z)
        spawn(at: p, height: pose.height, heading: pose.heading)
        if let cell = life.cell, cellOf(p) == cell, activity == .rest {
            let home = homePoint(cell, activity)
            if simd_distance(p, SIMD2<Float>(home.point.x, home.point.z)) < 0.3 { body?.rest(at: home.point, facing: home.heading) }
        }
        makeGuide()
    }

    private func spawnAtHome() {
        let cell = homeCell()
        let home = homePoint(cell, activity)
        spawn(at: SIMD2<Float>(home.point.x, home.point.z), height: home.point.y, heading: home.heading)
        if activity == .rest { body?.rest(at: home.point, facing: home.heading) }
        makeGuide()
    }

    private func resumeOwnLife() {
        guard let body, let p = body.groundPosition else { return }
        // She stays where she has got to, for a while.
        life.floor = floor
        life.cell = cellOf(p)
        life.since = BuildingClock.now()
        life.dwell = Double(rng.range(4, 10))                  // (Oct 18: a moment, then on to a room)
        life.room = nil
        life.roomName = nil
        nextAct = CACurrentMediaTime() + 3
        log("ownLife")
    }

    // MARK: Room visits (Oct 18, phase 2)

    private struct Visit {
        let room: String
        let kind: ResidentActivities.Kind
        let thing: RoomThing?
        var beat = 0
    }
    private var visit: Visit?
    /// In words, what she's doing (the panel).
    private var visitDoing = "arriving"

    /// Oct 18 (phase 2): "Break Room / circling the floor lamp / looking at floor lamp".
    var activityNote: String? {
        guard let body else { return nil }
        let doing: String
        if busy { doing = "using the elevator" }
        else if guide?.isGuiding == true { doing = "guiding you (FOLLOW ME)" }
        else { doing = visitDoing }
        return ResidentActivities.note(room: life.roomName, doing: doing, attention: body.attention?.status)
    }

    /// A beat of her visit to this room (false: nothing in particular -- her old small doings).
    private func visitBeat(body: ButterflyBody, me: SIMD2<Float>) -> Bool {
        guard let roomID = life.room else { visit = nil; return false }
        if visit?.room != roomID {
            // New room: what's in it, and what she'll do about it.
            guard let root, let cells = BuildingLife.shared.plans(floor)?.rooms.first(where: { $0.id == roomID })?.cells else { return false }
            let things = RoomThings.find(in: root, cells: cells, cellSize: s)
            let choice = ResidentActivities.choose(for: .butterfly, things: things, seed: Roam.seed(residentID, life.moves) ^ 0xB077E5)
            visit = Visit(room: roomID, kind: choice.kind, thing: choice.thing)
            log("activity.chosen", ["room": life.roomName, "kind": choice.kind.rawValue, "thing": choice.thing?.label,
                                    "inRoom": things.isEmpty ? "nothing catalogued" : things.map { $0.label }.joined(separator: ", ")])
            if let t = choice.thing {
                body.attention?.setFocus(t.label, at: t.lookPoint, style: .watch)
                body.attention?.react(.curious, for: 1.5)
            } else {
                body.attention?.clearFocus()
            }
        }
        guard var v = visit, let thing = v.thing else {
            body.attention?.setResting(activity == .rest)
            visitDoing = activity == .rest ? "resting" : (activity == .investigate ? "looking around" : "pottering")
            return false
        }
        body.attention?.setResting(false)
        let now = CACurrentMediaTime()
        let cells = BuildingLife.shared.plans(floor)?.rooms.first(where: { $0.id == v.room })?.cells ?? []
        let inRoom: (SIMD2<Float>) -> Bool = { [weak self] p in self.map { cells.contains($0.cellOf(p)) } ?? false }
        let above = min(thing.top + 0.3, 2.3)
        // (circling: round it first; investigating: close up first, then a small loop)
        let step = (v.kind == .circling ? [0, 1, 2, 3] : [1, 0, 2, 3])[v.beat % 4]
        switch step {
        case 0:                                                            // round it
            visitDoing = "circling the \(thing.label)"
            body.circle(around: thing.center, radius: max(0.45, thing.radius + 0.35), height: above,
                        loops: v.kind == .circling ? 1.5 : 0.6) {}
            nextAct = now + Double(rng.range(6, 8))
        case 1, 3:                                                         // close up, looking
            visitDoing = "investigating the \(thing.label)"
            let near = ResidentActivities.standPoint(for: thing, from: me, standoff: 0.25, allowed: inRoom) ?? thing.center
            let heading = ButterflyBody.heading(thing.center - near)
            body.hover(at: near, height: max(1.0, min(thing.top + 0.15, 2.2))) { [weak body] in body?.settle(facing: heading) }
            nextAct = now + Double(rng.range(4, 6))
        default:                                                           // settles on it, briefly
            visitDoing = "settled on the \(thing.label)"
            let off = SIMD2<Float>(rng.range(-0.1, 0.1), rng.range(-0.1, 0.1)) * thing.radius
            let spot = thing.center + off
            body.rest(at: SIMD3<Float>(spot.x, min(thing.top + 0.04, 2.2), spot.y), facing: body.root.eulerAngles.y)
            nextAct = now + Double(rng.range(5, 8))
        }
        v.beat += 1
        visit = v
        return true
    }

    private func smallDoing() {
        guard let body, let guide, !guide.isGuiding, let me = body.groundPosition else { return }
        let cell = life.cell ?? homeCell()
        let home = homePoint(cell, activity)
        nextAct = CACurrentMediaTime() + Double(rng.range(4, 9))
        // Not home yet (another room, say): the way there first, doors and all.
        if cellOf(me) != cell {
            let act = activity
            visitDoing = "flying to \(life.roomName.map { "the " + $0 } ?? "her spot")"
            body.attention?.clearFocus()
            body.attention?.setResting(false)
            body.attention?.destination = home.point
            guide.wander(to: SIMD2<Float>(home.point.x, home.point.z)) { [weak body] in
                if act == .rest { body?.rest(at: home.point, facing: home.heading) } else { body?.settle(facing: home.heading) }
            }
            return
        }
        // Oct 18 (phase 2): in her room -- something there to circle, look into, settle on.
        if visitBeat(body: body, me: me) { return }
        let roll = rng.unit()
        switch activity {
        case .rest:
            if roll < 0.7 {
                body.rest(at: home.point, facing: home.heading)                    // (stay -- or settle back)
            } else {
                let c = center(cell)
                let off = SIMD2<Float>(rng.range(-0.9, 0.9), rng.range(-0.9, 0.9))
                body.hover(at: c + off, height: rng.range(1.5, 2.1)) { [weak body] in
                    guard let token = body?.motion else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        guard let body, body.motion == token else { return }       // (unless she's off somewhere since)
                        body.rest(at: home.point, facing: home.heading)
                    }
                }
            }
        case .investigate:
            let off = SIMD2<Float>(rng.range(-0.5, 0.5), rng.range(-0.5, 0.5))
            body.hover(at: SIMD2<Float>(home.point.x, home.point.z) + off, height: rng.range(1.25, 1.9)) { [weak body] in
                body?.settle(facing: home.heading)
            }
        case .wander:
            let near = context.cells.filter { abs($0.row - cell.row) + abs($0.col - cell.col) <= 2 }
                .sorted { ($0.row, $0.col) < ($1.row, $1.col) }
            if roll < 0.6, !near.isEmpty {
                guide.wander(to: center(near[Int(rng.unit() * Float(near.count)) % near.count])) {}
            } else {
                guide.wander(to: center(cell)) {}
            }
        }
    }

    // MARK: The elevator: coming and going

    private func doorPoints() -> (outside: SIMD2<Float>, threshold: SIMD2<Float>, inside: SIMD2<Float>)? {
        guard let d = controller?.elevatorDoorwayFrame() else { return nil }
        return (d.center + d.outward * 1.6, d.center + d.outward * 0.3, d.center - d.outward * 0.9)
    }

    /// Out of the elevator: the ding, the doors, and out she comes.
    private func arriveByElevator(why: String) {
        // Oct 18 (controlled test): she's already living on this floor -- no
        // elevator; she simply appears at her place here.
        if BuildingLife.testFloor == floor, body == nil, !busy, life.floor == floor {
            spawnAtHome()
            log("test.appearedWithoutElevator", ["why": why])
            return
        }
        guard !busy, body == nil, elevatorFree, let controller, let doors = doorPoints() else { return }
        busy = true
        busySince = CACurrentMediaTime()
        let cameFrom = life.leg.flatMap { $0.changesFloor && $0.from.floor != floor ? $0.from.floor : nil }
        let ok = controller.runCharacterElevatorDeparture(who: residentID, purpose: .arrival(from: cameFrom), boarding: { [weak self] doorsDone in
            let done = self?.once(doorsDone) ?? doorsDone
            guard let self else { done(); return }
            self.spawn(at: doors.inside, height: 1.9, heading: ButterflyBody.heading(doors.outside - doors.inside))
            guard let body = self.body else { done(); return }
            self.makeGuide()
            body.travel([doors.threshold, doors.outside]) { done() }
        }, completion: { [weak self] in
            guard let self else { return }
            self.busy = false
            // Oct 19 (one car): if THE car brought her, she's out of it now.
            if BuildingLife.shared.car.rider(self.residentID) != nil {
                BuildingLife.shared.alighted(self.residentID, now: BuildingClock.now())
            }
            self.life.floor = self.floor
            if why == "the lights" { self.life.cell = nil; self.life.dwell = 240 }   // (for the player: she stays near them)
            self.life.since = BuildingClock.now()
            self.life.leg = nil                                  // (Oct 18: her ride is over -- she's out)
            self.nextAct = CACurrentMediaTime() + 2
            self.log("arrivedByElevator", ["why": why])
        })
        if !ok { busy = false; arrivalDue = CACurrentMediaTime() + 3 }
    }

    /// Off to her next haunt: to the doors, in, gone.
    private func leaveByElevator() {
        guard !busy, let body, let guide, !guide.isGuiding, elevatorFree, let controller, let doors = doorPoints() else { return }
        // Oct 18: her next room (Roam's decision). On this same floor: she just flies there.
        var next = life
        let decidedAt = BuildingClock.now()
        Roam.decide(&next, style: Butterfly.style, abilities: Butterfly.abilities, plans: BuildingLife.shared.plans, at: decidedAt)
        BuildingLife.shared.logDecision(next, now: decidedAt, offscreen: false)
        if next.floor == floor {
            next.leg = nil                                 // (her stay counts from when she gets there: Roam's arrival time)
            life = next
            nextAct = 0
            log("movedOnHere", ["cell": life.cell.map { "\($0.row),\($0.col)" } ?? "-", "room": life.roomName])
            return
        }
        let chosen = next
        // (Oct 19, one car: her door cycle below needs the car standing here -- if it
        // isn't, the cycle calls it and she tries again in a moment.)
        busy = true
        busySince = CACurrentMediaTime()
        body.attention?.clearFocus()                         // (Oct 18: eyes on the way out now)
        body.attention?.setResting(false)
        body.attention?.destination = SIMD3<Float>(doors.outside.x, 1.4, doors.outside.y)
        guide.wander(to: doors.outside) { [weak self] in
            guard let self else { return }
            let ok = controller.runCharacterElevatorDeparture(who: residentID, purpose: .departure(to: chosen.floor),
                                                              boarding: { [weak self] doorsDone in
                let done = self?.once(doorsDone) ?? doorsDone
                guard let self, let body = self.body else { done(); return }
                body.travel([doors.threshold, doors.inside]) {
                    body.root.removeFromParentNode()
                    done()
                }
            }, completion: { [weak self] in
                guard let self else { return }
                self.guide?.detach()
                self.guide = nil
                self.body?.root.removeFromParentNode()          // (Oct 18: if the door cycle ended without her walking in)
                self.body = nil
                self.busy = false
                // Her journey to the room she chose, from now (however long the doors took).
                var l = chosen
                let late = max(0, BuildingClock.now().timeIntervalSince(decidedAt))
                l.since += late
                if var leg = l.leg {
                    leg.boardAt = leg.boardAt.map { $0 + late }
                    leg.alightAt = leg.alightAt.map { $0 + late }
                    l.leg = leg
                }
                self.life = l
                // Oct 19 (one car): aboard, doors shut -- she rides THE car to her floor.
                BuildingLife.shared.boarded(self.residentID, now: BuildingClock.now(), force: true)
                self.log("leftByElevator", ["to": l.floor, "room": l.roomName])
            })
            if !ok {
                self.busy = false
                if controller.carOnItsWay {
                    self.life.dwell += 4                                                  // (Oct 19: the car is coming: a moment more)
                    self.log("elevator.waitingForCar", ["car": BuildingLife.shared.car.position(now: BuildingClock.now())?.state])
                } else {
                    self.leaveTries += 1
                    self.life.dwell += 30                                                 // (another time)
                }
            }
        }
        _ = body
    }

    // MARK: Watching (twice a second)

    private func tick() {
        let now = CACurrentMediaTime()
        // Offscreen she simply lives on.
        if body == nil, !busy {
            var l = life
            Butterfly.live(&l, to: BuildingClock.now())
            if l.floor != life.floor || l.cell != life.cell || l.moves != life.moves || l.leg != life.leg { life = l }
        }
        let resting = (life.memory.restUntil ?? .distantPast) > BuildingClock.now()
        // The player arrived (or is) on Floor 5 with lights off: her priority is to reach them.
        if body == nil, !busy, floor == FloorFiveBlackout.floor, Butterfly.concern.isActive, !resting {
            if playerInElevator || nearDoors() {
                arrivalDue = nil
            } else if arrivalDue == nil {
                let away = max(0, life.since.timeIntervalSince(BuildingClock.now()))               // (she may be on her way already)
                arrivalDue = now + 7 + min(15, away)
            } else if let due = arrivalDue, now >= due {
                arrivalDue = nil
                arriveByElevator(why: "the lights")
            }
            return
        }
        // Her routine brings her to this floor while the player is here.
        // Oct 18 (visible-life repair): whenever she's here by her record and has
        // no body -- not only in the first minute after her arrival time. (A
        // missed minute -- the doors busy, the player at them -- used to leave
        // her here in the record and nowhere on screen until she moved on.)
        if body == nil, !busy, present {
            if playerInElevator { noteNotShown("waiting: the player is in the elevator"); return }
            // (Oct 18: the player at the doors holds her in the car only briefly)
            if nearDoors() {
                nearDoorsSince = nearDoorsSince ?? now
                if now - (nearDoorsSince ?? now) < 8 { noteNotShown("waiting: the player is at the elevator doors"); return }
            } else {
                nearDoorsSince = nil
            }
            if !elevatorFree { noteNotShown("waiting: an escort / eviction / meeting is using the building"); return }
            if now >= routineRetryAt {
                routineRetryAt = now + 4
                noteNotShown("arriving by the elevator")
                arriveByElevator(why: "her routine")
            }
            return
        }
        // (a coming or going that never finished -- something interrupted it -- is let go)
        if busy, now - busySince > 25 {
            busy = false
            log("busyWatchdog")
        }
        guard let body, let guide, !busy else { return }
        // A player who walks right up to her while she's sulking: she perks up.
        if resting, Butterfly.concern.isActive, let pose = context.playerPose(), let me = body.groundPosition {
            // (not just waiting for the lift beside her: walking up to her, away from the doors)
            let byDoors = doorPoints().map { simd_distance(me, $0.outside) < 3 } ?? false
            if simd_distance(me, pose.position) < 1.8, !byDoors, guide.memory.lapses < InformantGuide.maxLapses {
                nearSince = nearSince ?? now
                if let t = nearSince, now - t > 1.5 {
                    nearSince = nil
                    var m = guide.memory; m.restUntil = nil; guide.memory = m
                    log("reEngaged")
                }
            } else {
                nearSince = nil
            }
        }
        if guide.isGuiding { body.attention?.clearFocus(); return }
        // Something to help with, and the player here: go to them.
        if concernHere, !resting, !playerInElevator, now - guide.releasedAt > 6, guide.begin(reason: floor == 5 ? "lights out" : "unfinished journey") {
            return
        }
        // Otherwise, her own life: small doings, and moving on when it's time.
        if BuildingClock.now().timeIntervalSince(life.since) > life.dwell, leaveTries < 4, !playerInElevator,
           !(floor == FloorFiveBlackout.floor && Butterfly.concern.isActive && !resting) {
            leaveByElevator()
            return
        }
        if now >= nextAct { smallDoing() }
    }

    private func nearDoors() -> Bool {
        guard let doors = doorPoints(), let pose = context.playerPose() else { return false }
        return simd_distance(pose.position, doors.threshold) < 1.6
    }

    // MARK: Elevator hooks

    /// True: she's going into the cab with the player.
    func playerBoarding() -> Bool {
        guard let guide else { return false }
        guide.playerBoarding()
        let going = guide.phase == .cab
        if going { Butterfly.boardedWithPlayer = true }
        return going
    }

    func arrivalDoorsOpening() { guide?.arrivalDoorsOpening() }
}
