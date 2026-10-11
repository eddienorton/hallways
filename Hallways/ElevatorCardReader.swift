import SceneKit
import UIKit

/// Oct 9 -- EMPLOYEE ID ACCESS CONTROL for the building's one elevator.
///
/// Hyperrealism: no messages, banners or alerts. A small black proximity
/// reader on the cab wall, just right of the floor buttons, reads the
/// employee ID the player carries (automatically -- nothing to present).
///
/// THE RULE (authorization, not mission progress):
///   - Lobby (1) and Administration (2) are open to everyone: a new arrival
///     must be able to reach the ID kiosk.
///   - Floor 3 and above need an employee ID. "Has an ID" is the existing
///     admission state (`Admission.isCompleted`, set when the card is taken
///     at the kiosk; cleared only by Start Over) -- no separate card state.
/// Mission progress is a separate rule and stays as it is today
/// (`TapNavigationController.missionGatesElevator == false`).
///
/// Only the PLAYER's own button presses are checked. The building's
/// automatic rides (Admission's first trip, the guided escort) and every
/// developer shortcut (Dev Map / floor jumps) never go through the reader.
enum ElevatorAccess {
    /// Highest floor a visitor without an ID may ride to.
    static let openFloorsMax = Admission.administrationFloor

    /// May the player send the car to `floor`?
    static func permits(_ floor: Int, hasEmployeeID: Bool) -> Bool {
        hasEmployeeID || floor <= openFloorsMax
    }

    static func permits(_ floor: Int) -> Bool {
        permits(floor, hasEmployeeID: Admission.isCompleted)
    }
}

/// The reader itself: geometry, its status lamp, and its denial beep.
enum ElevatorCardReader {
    static let nodeName = "elevatorCardReader"
    static let lampName = "elevatorCardReaderLamp"
    static let flashActionKey = "elevatorCardReaderFlash"
    /// Oct 9 (enlarged): the whole reader is built at this scale -- about
    /// 11 x 16.5 cm on the wall (was 7 x 11 cm).
    static let scale: Float = 1.5
    /// Built size before `scale`, metres.
    static let baseWidth: Float = 0.072, baseHeight: Float = 0.11, baseDepth: Float = 0.025
    /// How long a red (denied) answer stays lit before the lamp returns to standby.
    static let flashSeconds: TimeInterval = 0.9
    /// Oct 9 (green holds for the trip): after the arriving cab's doors start
    /// to open, the green stays this long, then standby.
    static let arrivalHoldSeconds: TimeInterval = 1.5
    /// The trip under way was authorized by the reader (an employee ID was
    /// read). Carried across the floor rebuild so the ARRIVING cab's reader
    /// is still green until its doors open. In memory only.
    static var tripAuthorized = false

    // Lamp states (emission): dim neutral standby, brief red, brief green.
    static let standbyGlow = UIColor(white: 0.10, alpha: 1)
    static let deniedGlow = UIColor(red: 0.95, green: 0.08, blue: 0.06, alpha: 1)
    static let grantedGlow = UIColor(red: 0.10, green: 0.85, blue: 0.25, alpha: 1)

    /// A black reader (7 x 11 x 2.5 cm before `scale`). Its front faces local -Z
    /// (the same way the floor-button plate's face points); origin at the
    /// reader's centre.
    static func make() -> SCNNode {
        let root = SCNNode()
        root.name = nodeName
        root.scale = SCNVector3(scale, scale, scale)
        let width = CGFloat(baseWidth), height = CGFloat(baseHeight), depth = CGFloat(baseDepth)

        let shell = SCNMaterial()
        shell.lightingModel = .physicallyBased
        shell.diffuse.contents = UIColor(white: 0.035, alpha: 1)
        shell.roughness.contents = 0.45
        shell.metalness.contents = 0.1
        let body = SCNNode(geometry: SCNBox(width: width, height: height, length: depth, chamferRadius: 0.006))
        body.geometry?.materials = [shell]
        root.addChildNode(body)

        // A slightly glossier inset face where the card is read.
        let faceMaterial = SCNMaterial()
        faceMaterial.lightingModel = .physicallyBased
        faceMaterial.diffuse.contents = UIColor(white: 0.06, alpha: 1)
        faceMaterial.roughness.contents = 0.2
        let face = SCNNode(geometry: SCNBox(width: width - 0.014, height: 0.062, length: 0.002, chamferRadius: 0.003))
        face.geometry?.materials = [faceMaterial]
        face.position = SCNVector3(0, -0.012, -Float(depth) / 2 - 0.0005)
        root.addChildNode(face)

        // The contactless mark: three faint arcs, printed in dark grey.
        let ink = SCNMaterial()
        ink.lightingModel = .constant
        ink.diffuse.contents = UIColor(white: 0.22, alpha: 1)
        for (i, r) in [CGFloat(0.007), 0.012, 0.017].enumerated() {
            let arc = SCNNode(geometry: SCNTorus(ringRadius: r, pipeRadius: 0.0009))
            arc.geometry?.materials = [ink]
            arc.eulerAngles.x = .pi / 2                       // ring in the face plane
            _ = i
            arc.position = SCNVector3(0, -0.012, -Float(depth) / 2 - 0.0016)
            root.addChildNode(arc)
        }

        // The status lamp near the top: its own material (one per build).
        let lampMaterial = SCNMaterial()
        lampMaterial.lightingModel = .physicallyBased
        lampMaterial.diffuse.contents = UIColor(white: 0.05, alpha: 1)
        lampMaterial.emission.contents = standbyGlow
        lampMaterial.roughness.contents = 0.25
        let lamp = SCNNode(geometry: SCNCylinder(radius: 0.0045, height: 0.003))
        lamp.name = lampName
        lamp.geometry?.materials = [lampMaterial]
        lamp.eulerAngles.x = .pi / 2                          // disc facing the rider
        lamp.position = SCNVector3(0, Float(height) / 2 - 0.016, -Float(depth) / 2 - 0.0015)
        root.addChildNode(lamp)
        return root
    }

    /// Oct 9: green, and it STAYS green -- the authorized trip. Nothing to
    /// swipe: the reader reads the ID the player carries the moment they
    /// choose the floor. Back to standby only via `returnToStandby`.
    static func showGranted(in root: SCNNode?) {
        guard let lamp = root?.childNode(withName: lampName, recursively: true),
              let material = lamp.geometry?.firstMaterial else { return }
        lamp.removeAction(forKey: flashActionKey)
        material.emission.contents = grantedGlow
    }

    /// The lamp goes back to its dim standby after `delay` seconds.
    static func returnToStandby(after delay: TimeInterval, in root: SCNNode?) {
        guard let lamp = root?.childNode(withName: lampName, recursively: true),
              let material = lamp.geometry?.firstMaterial else { return }
        lamp.removeAction(forKey: flashActionKey)
        lamp.runAction(.sequence([.wait(duration: delay),
                                  .run { _ in material.emission.contents = standbyGlow }]),
                       forKey: flashActionKey)
    }

    /// The arriving cab: still green if the trip was authorized.
    static func presentArrival(in root: SCNNode?) {
        if tripAuthorized { showGranted(in: root) }
    }

    /// The arriving cab's doors are opening: the trip is over.
    static func arrivalDoorsOpening(in root: SCNNode?) {
        guard tripAuthorized else { return }
        tripAuthorized = false
        returnToStandby(after: arrivalHoldSeconds, in: root)
    }

    /// A brief red (denied) or green (granted) answer, then standby again.
    /// Repeated presses restart the flash; nothing else in the cab changes.
    /// (Since Oct 9 an authorized trip uses `showGranted` -- green holds.)
    static func flash(granted: Bool, in root: SCNNode?) {
        guard let lamp = root?.childNode(withName: lampName, recursively: true),
              let material = lamp.geometry?.firstMaterial else { return }
        lamp.removeAction(forKey: flashActionKey)
        material.emission.contents = granted ? grantedGlow : deniedGlow
        lamp.runAction(.sequence([.wait(duration: flashSeconds),
                                  .run { _ in material.emission.contents = standbyGlow }]),
                       forKey: flashActionKey)
    }

    // MARK: The denial beep

    /// Two short, low, slightly buzzy beeps -- the sound a real reader makes
    /// when a badge isn't accepted. Non-positional (the reader is at the
    /// rider's hand); goes through SceneKit's audio, so Mute and the
    /// Settings silence both apply.
    private static let denySource: SCNAudioSource? = {
        let s = MenagerieSound.source("elevator-reader-deny", volume: 0.5) {
            let rate = MenagerieSound.rate
            func beep(_ seconds: Float) -> [Float] {
                let n = Int(seconds * rate)
                return (0..<n).map { i in
                    let t = Float(i) / rate
                    let tone = sin(2 * .pi * 740 * t) + 0.35 * sin(2 * .pi * 1480 * t) + 0.15 * sin(2 * .pi * 2220 * t)
                    let envelope = min(1, t / 0.004) * min(1, (seconds - t) / 0.01)
                    return tone * envelope * 0.6
                }
            }
            let gap = [Float](repeating: 0, count: Int(0.07 * rate))
            return beep(0.11) + gap + beep(0.11)
        }
        s?.isPositional = false
        return s
    }()

    static func playDenied(on node: SCNNode) {
        guard let denySource else { return }
        node.runAction(.playAudio(denySource, waitForCompletion: false))
    }
}
