import AVFoundation
import CoreImage
import SceneKit
import UIKit
import Vision

/// Oct 5 -- ADMINISTRATION: the ID-photo terminal.
///
/// A wall-mounted Hallways Building computer in Administration (Floor 2),
/// on the north wall beside the reception desk. NOT the old photo booth:
/// no expression prompts, no smile/mouth/eyebrow triggers, no live mirror
/// preview. The screen is a plain official form with one machine button,
/// TAKE ID PHOTO. Tapping it takes one still with the front camera (a
/// shutter click), runs it through the Hallways face rule (HallwaysFace),
/// and only THEN shows the result -- with ACCEPT PHOTO / RETAKE. ACCEPT
/// leaves the accepted photo on the screen (nothing further happens yet).
///
/// Approach: the terminal is an ordinary TapNavigationController landing
/// spot (see ContentView) -- walk up to it, or tap it from anywhere in the
/// room, and the existing wall-interaction landing squares you up to the
/// screen. Buttons respond only while you stand in that pose.
@MainActor
final class AdministrationIDTerminal {
    static let landingKind = "idTerminal"
    static let monitorName = "idTerminalMonitor"
    static let screenName = "idTerminalScreen"
    static let cardName = "idTerminalCard"
    static let ledName = "idTerminalLED"

    /// The terminal on the floor currently built (one Administration).
    static var current: AdministrationIDTerminal?
    /// The most recently accepted ID photo (in memory only, for the next beat).
    static var acceptedPhoto: UIImage?

    enum State {
        case form
        case capturing
        case result(UIImage)
        case accepted(UIImage)
        /// Oct 5 (kiosk): the card is being produced; progress 0...1.
        case printing(UIImage, Double)
        /// The card protrudes from the dispenser slot, waiting to be taken.
        case dispensed(UIImage)
        /// The player has taken the card (admission complete).
        case issued(UIImage)
        case unavailable
        /// Oct 10: the face was badly placed -- asks for another try.
        case reposition(HallwaysFace.Framing)
    }
    /// Oct 10 (face framing): badly framed captures in a row. After this many
    /// re-prompts the next capture is shown regardless, so an undetectable
    /// face (lighting, glasses, a mask) can never block the ID.
    static let maxFramingPrompts = 2
    private var framingPrompts = 0

    private(set) var state: State = .form
    private weak var screen: SCNNode?
    /// The exact UIImage HallwaysFace returned for the current result (diagnostics:
    /// proves the screen shows the transform output, not the raw capture).
    private var lastTransformOutput: UIImage?
    private let camera = IDPhotoCamera()
    /// Kiosk parts found by name under the monitor node.
    private weak var led: SCNNode?
    private weak var card: SCNNode?
    private var cardNumber: String?

    init(screen: SCNNode) {
        self.screen = screen
        led = screen.parent?.childNode(withName: Self.ledName, recursively: true)
        card = screen.parent?.childNode(withName: Self.cardName, recursively: true)
        render()
    }

    static func owns(_ node: SCNNode) -> Bool {
        var n: SCNNode? = node
        while let current = n {
            if current.name == monitorName { return true }
            n = current.parent
        }
        return false
    }

    // MARK: Screen layout (image pixels, origin top-left)
    //
    // A portrait form, top to bottom: header, EMPLOYEE IDENTIFICATION, a
    // large 3:4 mugshot, then ACCEPT PHOTO above RETAKE (or TAKE ID PHOTO).
    // Taps are mapped from the plane's LOCAL hit coordinates (+y up), so the
    // texture's vertical convention can't flip the stacked buttons.

    static let screenSize = CGSize(width: 800, height: 1200)
    private static let photoRect = CGRect(x: 130, y: 168, width: 540, height: 720)
    private static let takeRect = CGRect(x: 130, y: 920, width: 540, height: 150)
    private static let acceptRect = CGRect(x: 130, y: 914, width: 540, height: 118)
    private static let retakeRect = CGRect(x: 130, y: 1054, width: 540, height: 100)

    // MARK: Taps

    /// Oct 6 (polish): the finished card is out and waiting to be taken.
    var isCardWaiting: Bool {
        if case .dispensed = state { return true }
        return false
    }

    /// Oct 6 (polish): take the waiting card (any tap while it is presented).
    /// True only if there was a card to take.
    @discardableResult
    func takeWaitingCard() -> Bool {
        guard case .dispensed(let photo) = state else { return false }
        diag("idTerminal.cardTap", ["state": "dispensed", "via": "anywhere"])
        takeCard(photo)
        return true
    }

    func handleTap(on hit: SCNHitTestResult) {
        if hit.node.name == Self.cardName {
            diag("idTerminal.cardTap", ["state": "\(state)"])
            if case .dispensed(let photo) = state { takeCard(photo) }
            return
        }
        guard hit.node.name == Self.screenName, let plane = hit.node.geometry as? SCNPlane else { return }
        let local = hit.localCoordinates
        let point = CGPoint(x: (CGFloat(local.x) / plane.width + 0.5) * Self.screenSize.width,
                            y: (0.5 - CGFloat(local.y) / plane.height) * Self.screenSize.height)
        let uv = hit.textureCoordinates(withMappingChannel: 0)
        diag("idTerminal.tap", ["x": Double(point.x.rounded()), "y": Double(point.y.rounded()),
                                "u": Double(uv.x), "v": Double(uv.y), "state": "\(state)"])
        switch state {
        case .form, .unavailable, .reposition:
            if Self.takeRect.insetBy(dx: -20, dy: -20).contains(point) { takePhoto() }
        case .result(let photo):
            if Self.acceptRect.insetBy(dx: -16, dy: -10).contains(point) {
                state = .accepted(photo)
                Self.acceptedPhoto = photo
                diag("idTerminal.accepted", ["isTransformOutput": photo === lastTransformOutput])
                render()
                issueCard(photo)
                AdministrationExitGuard.photoAccepted()          // Oct 9: Juanita comes out to stand by the exit
            } else if Self.retakeRect.insetBy(dx: -16, dy: -10).contains(point) {
                state = .form
                lastTransformOutput = nil
                diag("idTerminal.retake", [:])
                render()
            }
        case .capturing, .accepted, .printing, .dispensed, .issued:
            break
        }
    }

    // MARK: Card production (Oct 5 kiosk)
    //
    // ACCEPT PHOTO -> "PHOTO ACCEPTED" (relay click, LED amber blinking)
    // -> ~1.2 s "PRINTING EMPLOYEE ID" progress (printer chatter)
    // -> the card slides out of the dispenser slot (roller whir, end clack,
    // LED green) -> tap the card: it lifts away, admission completes.

    private static let processingLeadIn: TimeInterval = 0.45
    private static let printSteps = 10
    private static let printStep: TimeInterval = 0.12

    private func issueCard(_ photo: UIImage) {
        let number = EmployeeID.number ?? EmployeeID.makeNumber()
        cardNumber = number
        card?.geometry?.firstMaterial?.diffuse.contents = Self.cardImage(portrait: photo, number: number, issued: Date())
        card?.geometry?.firstMaterial?.emission.contents = card?.geometry?.firstMaterial?.diffuse.contents
        diag("idTerminal.card.begin", ["number": number, "isTransformOutput": photo === lastTransformOutput])
        KioskSound.play(KioskSound.accept, on: screen)
        setLED(.amber, blinking: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.processingLeadIn) { [weak self] in
            guard let self, case .accepted = self.state else { return }
            self.state = .printing(photo, 0)
            self.render()
            KioskSound.play(KioskSound.printing, on: self.screen)
            for step in 1...Self.printSteps {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.printStep * Double(step)) { [weak self] in
                    guard let self, case .printing = self.state else { return }
                    self.state = .printing(photo, Double(step) / Double(Self.printSteps))
                    self.render()
                    if step == Self.printSteps { self.ejectCard(photo) }
                }
            }
        }
    }

    /// Card positions along the carrier's local +Z (its slide axis).
    static let cardHiddenZ: Float = -0.07
    static let cardOutZ: Float = 0.058

    private func ejectCard(_ photo: UIImage) {
        guard let card else {
            diag("idTerminal.card.noCardNode", [:])
            state = .dispensed(photo)
            render()
            return
        }
        card.removeAllActions()
        card.position = SCNVector3(0, 0.001, Self.cardHiddenZ)
        card.opacity = 1
        card.isHidden = false
        KioskSound.play(KioskSound.eject, on: screen)
        let slide = SCNAction.move(to: SCNVector3(0, 0.001, Self.cardOutZ), duration: 0.85)
        slide.timingMode = .easeOut
        card.runAction(slide) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.state = .dispensed(photo)
                self.setLED(.green, blinking: false)
                self.render()
                diag("idTerminal.card.dispensed", ["number": self.cardNumber ?? "?"])
            }
        }
    }

    private func takeCard(_ photo: UIImage) {
        let number = cardNumber ?? EmployeeID.number ?? EmployeeID.makeNumber()
        state = .issued(photo)
        render()
        KioskSound.play(KioskSound.take, on: screen)
        if let card {
            card.removeAllActions()
            let lift = SCNAction.group([.move(by: SCNVector3(0, 0.05, 0.12), duration: 0.24), .fadeOut(duration: 0.24)])
            lift.timingMode = .easeIn
            card.runAction(.sequence([lift, .hide()]))
        }
        Self.acceptedPhoto = photo
        EmployeeID.save(portrait: photo, number: number)
        Admission.isCompleted = true
        AdministrationReception.installOfficeOccupantIfDue()      // Oct 5: Fred is now at his desk
        AdministrationExitGuard.visitorAdmitted()                 // Oct 9: Juanita heads for the exit
        diag("idTerminal.card.taken", ["number": number, "admissionCompleted": Admission.isCompleted,
                                        "isTransformOutput": photo === lastTransformOutput])
    }

    private enum LEDColor { case green, amber }

    private func setLED(_ color: LEDColor, blinking: Bool) {
        guard let led, let m = led.geometry?.firstMaterial else { return }
        switch color {
        case .green:
            m.diffuse.contents = UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1)
            m.emission.contents = UIColor(red: 0.1, green: 0.5, blue: 0.2, alpha: 1)
        case .amber:
            m.diffuse.contents = UIColor(red: 1, green: 0.62, blue: 0.12, alpha: 1)
            m.emission.contents = UIColor(red: 0.8, green: 0.42, blue: 0.05, alpha: 1)
        }
        led.removeAllActions()
        led.opacity = 1
        if blinking {
            led.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.2, duration: 0.12), .fadeOpacity(to: 1, duration: 0.12)])))
        }
    }

    private func takePhoto() {
        state = .capturing
        render()
        diag("idTerminal.capture.begin", [:])
        camera.capture { [weak self] image in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let image else {
                    diag("idTerminal.capture.failed", [:])
                    self.state = .unavailable
                    self.render()
                    return
                }
                SoundEffects.playCameraClick()
                self.flash()
                diag("idTerminal.capture.image", ["w": Double(image.size.width), "h": Double(image.size.height),
                                                  "orientation": image.imageOrientation.rawValue])
                DispatchQueue.global(qos: .userInitiated).async {
                    let output = HallwaysFace.render(image)
                    let applied = output.applied, isRawCapture = output.image === image
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        diag("idTerminal.capture.done", ["w": Double(output.image.size.width), "h": Double(output.image.size.height),
                                                         "transformApplied": applied, "isRawCapture": isRawCapture])
                        // Oct 10: a badly placed face (cut off at the bottom,
                        // mostly eyes and forehead...) asks for a retake instead
                        // of being offered for acceptance -- a limited number of
                        // times, so it can never block the ID.
                        if output.framing != .ok, self.framingPrompts < Self.maxFramingPrompts {
                            self.framingPrompts += 1
                            diag("idTerminal.reposition", ["framing": output.framing.rawValue, "prompt": self.framingPrompts])
                            self.lastTransformOutput = nil
                            self.state = .reposition(output.framing)
                            self.render()
                            return
                        }
                        self.framingPrompts = 0
                        self.lastTransformOutput = output.image
                        self.state = .result(output.image)
                        self.render()
                    }
                }
            }
        }
    }

    private func flash() {
        let white = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { c in
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        screen?.geometry?.firstMaterial?.diffuse.contents = white
    }

    // MARK: Rendering

    private func render() {
        if case .result(let photo) = state {
            diag("idTerminal.display", ["isTransformOutput": photo === lastTransformOutput,
                                        "w": Double(photo.size.width), "h": Double(photo.size.height)])
        }
        screen?.geometry?.firstMaterial?.diffuse.contents = Self.screenImage(for: state)
    }

    private static let navy = UIColor(red: 0.05, green: 0.1, blue: 0.13, alpha: 1)
    private static let gold = UIColor(red: 0.93, green: 0.8, blue: 0.5, alpha: 1)
    private static let paper = UIColor(white: 0.9, alpha: 1)

    static func screenImage(for state: State) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: screenSize, format: format).image { context in
            let cg = context.cgContext
            navy.setFill()
            cg.fill(CGRect(origin: .zero, size: screenSize))
            gold.setStroke()
            cg.setLineWidth(4)
            cg.stroke(CGRect(x: 20, y: 20, width: screenSize.width - 40, height: screenSize.height - 40))
            fittedText("HALLWAYS BUILDING  \u{00B7}  ADMINISTRATION", in: CGRect(x: 50, y: 44, width: 700, height: 34),
                       size: 26, weight: .semibold, color: gold, kern: 4)
            fittedText("EMPLOYEE IDENTIFICATION", in: CGRect(x: 50, y: 84, width: 700, height: 60),
                       size: 50, weight: .bold, color: paper, kern: 2)
            cg.setFillColor(gold.cgColor)
            cg.fill(CGRect(x: 50, y: 148, width: 700, height: 3))

            // The mugshot frame.
            let frame = photoRect
            UIColor(white: 0.16, alpha: 1).setFill()
            cg.fill(frame)
            switch state {
            case .result(let photo), .accepted(let photo), .printing(let photo, _), .dispensed(let photo), .issued(let photo):
                cg.saveGState()
                cg.clip(to: frame)
                photo.draw(in: aspectFill(photo.size, into: frame))
                cg.restoreGState()
            default:
                // Empty: a pale head-and-shoulders outline.
                cg.setStrokeColor(UIColor(white: 0.55, alpha: 1).cgColor)
                cg.setLineWidth(7)
                cg.strokeEllipse(in: CGRect(x: frame.midX - 125, y: frame.minY + 160, width: 250, height: 310))
                let shoulders = UIBezierPath()
                shoulders.move(to: CGPoint(x: frame.minX + 70, y: frame.maxY - 24))
                shoulders.addCurve(to: CGPoint(x: frame.maxX - 70, y: frame.maxY - 24),
                                   controlPoint1: CGPoint(x: frame.minX + 100, y: frame.minY + 490),
                                   controlPoint2: CGPoint(x: frame.maxX - 100, y: frame.minY + 490))
                shoulders.lineWidth = 7
                shoulders.stroke()
            }
            cg.setStrokeColor(gold.cgColor)
            cg.setLineWidth(5)
            cg.stroke(frame)

            // The controls, stacked under the photograph.
            switch state {
            case .form:
                button("TAKE ID PHOTO", in: takeRect, filled: true)
            case .capturing:
                button("HOLD STILL", in: takeRect, filled: false)
            case .reposition(let framing):
                button("TAKE ID PHOTO", in: takeRect, filled: true)
                fittedText(framing.prompt.0, in: CGRect(x: 130, y: 1082, width: 540, height: 40),
                           size: 32, weight: .bold, color: gold, kern: 2)
                fittedText(framing.prompt.1, in: CGRect(x: 130, y: 1124, width: 540, height: 34),
                           size: 26, weight: .semibold, color: paper, kern: 2)
            case .unavailable:
                button("TAKE ID PHOTO", in: takeRect, filled: true)
                fittedText("CAMERA UNAVAILABLE", in: CGRect(x: 130, y: 1090, width: 540, height: 44),
                           size: 32, weight: .semibold, color: gold, kern: 2)
            case .result:
                button("ACCEPT PHOTO", in: acceptRect, filled: true)
                button("RETAKE", in: retakeRect, filled: false)
            case .accepted:
                fittedText("PHOTO ACCEPTED", in: CGRect(x: 130, y: 960, width: 540, height: 70),
                           size: 54, weight: .bold, color: gold, kern: 3)
            case .printing(_, let progress):
                fittedText("PRINTING EMPLOYEE ID", in: CGRect(x: 130, y: 936, width: 540, height: 56),
                           size: 44, weight: .bold, color: gold, kern: 3)
                let bar = CGRect(x: 130, y: 1022, width: 540, height: 44)
                let outline = UIBezierPath(roundedRect: bar, cornerRadius: 10)
                outline.lineWidth = 4
                gold.setStroke()
                outline.stroke()
                let fill = CGRect(x: bar.minX + 8, y: bar.minY + 8, width: (bar.width - 16) * CGFloat(min(1, max(0, progress))),
                                  height: bar.height - 16)
                if fill.width > 1 {
                    gold.setFill()
                    UIBezierPath(roundedRect: fill, cornerRadius: 5).fill()
                }
            case .dispensed:
                fittedText("PLEASE TAKE YOUR", in: CGRect(x: 130, y: 922, width: 540, height: 50),
                           size: 40, weight: .semibold, color: gold, kern: 3)
                fittedText("EMPLOYEE ID", in: CGRect(x: 130, y: 974, width: 540, height: 70),
                           size: 58, weight: .bold, color: paper, kern: 3)
                let arrow = UIBezierPath()
                arrow.move(to: CGPoint(x: 370, y: 1074))
                arrow.addLine(to: CGPoint(x: 430, y: 1074))
                arrow.addLine(to: CGPoint(x: 400, y: 1124))
                arrow.close()
                gold.setFill()
                arrow.fill()
            case .issued:
                fittedText("EMPLOYEE ID ISSUED", in: CGRect(x: 130, y: 960, width: 540, height: 70),
                           size: 50, weight: .bold, color: gold, kern: 3)
            }
        }
    }

    /// Single-line text, shrunk to fit the rect's width.
    private static func fittedText(_ string: String, in rect: CGRect, size: CGFloat, weight: UIFont.Weight, color: UIColor, kern: CGFloat) {
        var fitted = size
        while fitted > 12, (string as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: fitted, weight: weight), .kern: kern]).width > rect.width {
            fitted -= 1
        }
        text(string, in: rect, size: fitted, weight: weight, color: color, kern: kern)
    }

    private static func text(_ string: String, in rect: CGRect, size: CGFloat, weight: UIFont.Weight, color: UIColor,
                             kern: CGFloat, alignment: NSTextAlignment = .center) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        (string as NSString).draw(in: rect, withAttributes: [
            .font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
            .kern: kern, .paragraphStyle: style
        ])
    }

    private static func button(_ title: String, in rect: CGRect, filled: Bool) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 22)
        if filled {
            gold.setFill()
            path.fill()
        } else {
            gold.setStroke()
            path.lineWidth = 5
            path.stroke()
        }
        // Fit the title to the button.
        var size: CGFloat = rect.height >= 140 ? 54 : (rect.height >= 110 ? 46 : 40)
        var font = UIFont.systemFont(ofSize: size, weight: .bold)
        while (title as NSString).size(withAttributes: [.font: font, .kern: 2]).width > rect.width - 36 && size > 18 {
            size -= 2
            font = UIFont.systemFont(ofSize: size, weight: .bold)
        }
        text(title, in: CGRect(x: rect.minX, y: rect.midY - font.lineHeight / 2, width: rect.width, height: font.lineHeight + 4),
             size: size, weight: .bold, color: filled ? navy : gold, kern: 2)
    }

    private static func aspectFill(_ size: CGSize, into rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    // MARK: The physical terminal

    /// A wall-mounted bronze monitor at eye height: a portrait 0.52 x 0.78 m
    /// screen in a slim bezel (0.6 m wide overall, so it sits inside the
    /// iPhone view from the landing with margin on both sides), a small webcam lens centred in the top bezel, a small
    /// green status LED, and a gold "stand here" ring on the floor. No lamp,
    /// no ring light. Local +Z is its face; origin at the wall, floor level.
    static func makeNode() -> (root: SCNNode, screen: SCNNode) {
        let root = SCNNode()
        root.name = "administrationPhotoStation"
        func material(_ color: UIColor, metal: CGFloat = 0, rough: CGFloat = 0.6, glow: UIColor? = nil) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = color
            m.metalness.contents = metal
            m.roughness.contents = rough
            if let glow { m.emission.contents = glow }
            return m
        }
        let bronze = material(UIColor(red: 0.2, green: 0.18, blue: 0.16, alpha: 1), metal: 0.6, rough: 0.38)
        let brass = material(UIColor(red: 0.74, green: 0.58, blue: 0.3, alpha: 1), metal: 0.85, rough: 0.3)
        let monitor = SCNNode()
        monitor.name = monitorName
        root.addChildNode(monitor)
        let centerY: Float = 1.55
        let screenW: CGFloat = 0.52, screenH: CGFloat = 0.78           // 2:3, matches screenSize
        // Oct 5 (kiosk): the head is now a deeper bronze block (same front face).
        let housing = SCNNode(geometry: SCNBox(width: screenW + 0.08, height: screenH + 0.11, length: 0.13, chamferRadius: 0.02))
        housing.geometry?.materials = [bronze]
        housing.position = SCNVector3(0, centerY, 0.025)
        monitor.addChildNode(housing)
        // The screen (machine UI drawn by screenImage).
        let plane = SCNPlane(width: screenW, height: screenH)
        let screenMaterial = SCNMaterial()
        screenMaterial.lightingModel = .constant
        screenMaterial.diffuse.contents = screenImage(for: .form)
        plane.materials = [screenMaterial]
        let screen = SCNNode(geometry: plane)
        screen.name = screenName
        let screenY = centerY - 0.015                                    // deeper top bezel for the lens
        screen.position = SCNVector3(0, screenY, 0.0915)
        monitor.addChildNode(screen)
        // Webcam: a small dark lens in the top bezel.
        let ring = SCNNode(geometry: SCNCylinder(radius: 0.013, height: 0.006))
        ring.geometry?.materials = [material(UIColor(white: 0.05, alpha: 1), rough: 0.4)]
        ring.eulerAngles.x = .pi / 2
        let lensY = screenY + Float(screenH / 2) + 0.035
        ring.position = SCNVector3(0, lensY, 0.092)
        monitor.addChildNode(ring)
        let lens = SCNNode(geometry: SCNSphere(radius: 0.007))
        lens.geometry?.materials = [material(UIColor(red: 0.04, green: 0.08, blue: 0.12, alpha: 1), metal: 0.4, rough: 0.05,
                                             glow: UIColor(red: 0.02, green: 0.05, blue: 0.08, alpha: 1))]
        lens.position = SCNVector3(0, lensY, 0.095)
        monitor.addChildNode(lens)
        // Status LED, bottom-right of the bezel.
        let led = SCNNode(geometry: SCNSphere(radius: 0.006))
        led.geometry?.materials = [material(UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1), rough: 0.3,
                                            glow: UIColor(red: 0.1, green: 0.5, blue: 0.2, alpha: 1))]
        led.name = ledName
        led.position = SCNVector3(Float(screenW / 2) - 0.01, screenY - Float(screenH / 2) - 0.02, 0.092)
        monitor.addChildNode(led)
        addKioskBody(to: monitor, bronze: bronze, brass: brass,
                     black: material(UIColor(white: 0.045, alpha: 1), metal: 0.3, rough: 0.5),
                     slotBlack: material(UIColor(white: 0.01, alpha: 1), rough: 0.9))
        // "Stand here": a gold double ring on the floor in front.
        for (radius, pipe) in [(CGFloat(0.34), CGFloat(0.012)), (CGFloat(0.26), CGFloat(0.006))] {
            let mark = SCNNode(geometry: SCNTorus(ringRadius: radius, pipeRadius: pipe))
            mark.geometry?.materials = [brass]
            mark.position = SCNVector3(0, 0.058, 1.45)
            mark.scale = SCNVector3(1, 0.3, 1)
            root.addChildNode(mark)
        }
        return (root, screen)
    }

    /// Oct 5: the floor-standing body under the screen head -- a narrow
    /// bronze cabinet (sloped shoulder up to the screen), a black plinth with
    /// a brass kick strip, brass edge trims, and the employee-ID dispenser:
    /// a brass-bezelled horizontal slot with a small engraved plate, plus the
    /// (hidden) card that slides out of it. Local +Z is the kiosk's front.
    private static func addKioskBody(to monitor: SCNNode, bronze: SCNMaterial, brass: SCNMaterial,
                                     black: SCNMaterial, slotBlack: SCNMaterial) {
        let frontZ: Float = 0.2, cabinetWidth: CGFloat = 0.42
        // Cabinet side profile (x = depth toward the room, y = height), extruded across its width.
        let profile = UIBezierPath()
        profile.move(to: CGPoint(x: -0.04, y: 0.1))
        profile.addLine(to: CGPoint(x: CGFloat(frontZ), y: 0.1))
        profile.addLine(to: CGPoint(x: CGFloat(frontZ), y: 1.0))
        profile.addLine(to: CGPoint(x: 0.1, y: 1.11))
        profile.addLine(to: CGPoint(x: -0.04, y: 1.11))
        profile.close()
        let shape = SCNShape(path: profile, extrusionDepth: cabinetWidth)
        shape.chamferRadius = 0.004
        shape.materials = [bronze]
        let cabinet = SCNNode(geometry: shape)
        cabinet.eulerAngles.y = -.pi / 2                 // profile x -> world +Z, extrusion -> world X
        monitor.addChildNode(cabinet)

        func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ m: SCNMaterial, at p: SCNVector3, chamfer: CGFloat = 0) {
            let n = SCNNode(geometry: SCNBox(width: w, height: h, length: l, chamferRadius: chamfer))
            n.geometry?.materials = [m]
            n.position = p
            monitor.addChildNode(n)
        }
        // Plinth + brass kick strip.
        box(0.52, 0.1, 0.3, black, at: SCNVector3(0, 0.05, 0.11), chamfer: 0.006)
        box(0.5, 0.012, 0.004, brass, at: SCNVector3(0, 0.082, 0.261))
        // Brass trims: front vertical edges and the shoulder line.
        for x: Float in [-0.21, 0.21] { box(0.01, 0.9, 0.01, brass, at: SCNVector3(x, 0.55, frontZ)) }
        box(cabinetWidth, 0.008, 0.01, brass, at: SCNVector3(0, 1.0, frontZ))
        // A recessed black service panel below the dispenser.
        box(0.3, 0.6, 0.004, black, at: SCNVector3(0, 0.47, frontZ + 0.001))

        // The dispenser: brass bezel, black slot mouth, engraved plate.
        let slotY: Float = 0.94
        box(0.27, 0.06, 0.016, brass, at: SCNVector3(0, slotY, frontZ + 0.008), chamfer: 0.004)
        box(0.232, 0.014, 0.004, slotBlack, at: SCNVector3(0, slotY, frontZ + 0.0155))
        let plate = SCNNode(geometry: SCNPlane(width: 0.17, height: 0.032))
        let plateMaterial = SCNMaterial()
        plateMaterial.lightingModel = .lambert
        plateMaterial.diffuse.contents = plateImage()
        plate.geometry?.materials = [plateMaterial]
        plate.position = SCNVector3(0, slotY - 0.06, frontZ + 0.0025)
        monitor.addChildNode(plate)

        // The card: rides a carrier tilted slightly up toward the visitor;
        // it slides along the carrier's +Z from inside the cabinet to out.
        let carrier = SCNNode()
        carrier.name = "idTerminalCardCarrier"
        carrier.position = SCNVector3(0, slotY, frontZ + 0.017)
        carrier.eulerAngles.x = -0.3
        monitor.addChildNode(carrier)
        let cardPlane = SCNPlane(width: 0.2, height: 0.128)
        cardPlane.cornerRadius = 0.008
        let cardMaterial = SCNMaterial()
        cardMaterial.lightingModel = .lambert
        cardMaterial.isDoubleSided = true
        cardMaterial.diffuse.contents = UIColor(white: 0.9, alpha: 1)
        cardMaterial.emission.intensity = 0.35
        cardPlane.materials = [cardMaterial]
        let card = SCNNode(geometry: cardPlane)
        card.name = cardName
        card.eulerAngles.x = -.pi / 2                   // face up; image top points into the slot
        card.position = SCNVector3(0, 0.001, cardHiddenZ)
        card.isHidden = true
        carrier.addChildNode(card)
    }

    private static func plateImage() -> UIImage {
        let size = CGSize(width: 680, height: 128)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.06, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            gold.setStroke()
            let border = UIBezierPath(roundedRect: CGRect(x: 6, y: 6, width: size.width - 12, height: size.height - 12), cornerRadius: 10)
            border.lineWidth = 4
            border.stroke()
            fittedText("EMPLOYEE ID", in: CGRect(x: 30, y: 32, width: size.width - 60, height: 64),
                       size: 54, weight: .semibold, color: gold, kern: 8)
        }
    }

    // MARK: The employee ID card

    static let cardPixelSize = CGSize(width: 1000, height: 640)

    /// THE HALLWAYS BUILDING / EMPLOYEE IDENTIFICATION / the accepted
    /// Hallways mugshot (the star), plus an employee number, issue date,
    /// a small barcode and a gold seal. Navy and gold, like the terminal.
    static func cardImage(portrait: UIImage, number: String, issued: Date) -> UIImage {
        let size = cardPixelSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            navy.setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            // Faint guilloche rings behind the fields.
            cg.setStrokeColor(gold.withAlphaComponent(0.07).cgColor)
            cg.setLineWidth(2)
            for r in stride(from: CGFloat(60), through: 520, by: 22) {
                cg.strokeEllipse(in: CGRect(x: 880 - r, y: 560 - r, width: r * 2, height: r * 2))
            }
            // Header band.
            gold.setFill()
            cg.fill(CGRect(x: 0, y: 0, width: size.width, height: 118))
            fittedText("THE HALLWAYS BUILDING", in: CGRect(x: 40, y: 34, width: 920, height: 60),
                       size: 50, weight: .heavy, color: navy, kern: 7)
            // The portrait -- the star.
            let photo = CGRect(x: 44, y: 148, width: 330, height: 440)
            UIColor(white: 0.16, alpha: 1).setFill()
            cg.fill(photo)
            cg.saveGState()
            cg.clip(to: photo)
            portrait.draw(in: aspectFill(portrait.size, into: photo))
            cg.restoreGState()
            cg.setStrokeColor(gold.cgColor)
            cg.setLineWidth(5)
            cg.stroke(photo)
            // Title and fields.
            fittedText("EMPLOYEE IDENTIFICATION", in: CGRect(x: 410, y: 150, width: 550, height: 46),
                       size: 36, weight: .bold, color: gold, kern: 3)
            cg.setFillColor(gold.cgColor)
            cg.fill(CGRect(x: 410, y: 206, width: 550, height: 3))
            text("EMPLOYEE NO.", in: CGRect(x: 410, y: 232, width: 550, height: 30), size: 22, weight: .semibold,
                 color: gold, kern: 4, alignment: .left)
            text(number, in: CGRect(x: 410, y: 262, width: 550, height: 66), size: 54, weight: .bold,
                 color: paper, kern: 4, alignment: .left)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "dd MMM yyyy"
            text("ISSUED", in: CGRect(x: 410, y: 346, width: 550, height: 30), size: 22, weight: .semibold,
                 color: gold, kern: 4, alignment: .left)
            text(formatter.string(from: issued).uppercased(), in: CGRect(x: 410, y: 376, width: 550, height: 52), size: 40,
                 weight: .semibold, color: paper, kern: 3, alignment: .left)
            // A small barcode from the number.
            let digits = number.compactMap { $0.wholeNumberValue }
            var x: CGFloat = 410
            var k = 0
            paper.setFill()
            while x < 740, !digits.isEmpty {
                let d = digits[k % digits.count]
                let bar = CGFloat(2 + (d + k) % 4) * 2
                cg.fill(CGRect(x: x, y: 482, width: bar, height: 82))
                x += bar + CGFloat(2 + (d * 3 + k) % 3) * 2
                k += 1
            }
            // Gold seal.
            let seal = CGPoint(x: 868, y: 524)
            cg.setStrokeColor(gold.cgColor)
            cg.setLineWidth(5)
            cg.strokeEllipse(in: CGRect(x: seal.x - 64, y: seal.y - 64, width: 128, height: 128))
            cg.setLineWidth(2)
            cg.strokeEllipse(in: CGRect(x: seal.x - 52, y: seal.y - 52, width: 104, height: 104))
            fittedText("HB", in: CGRect(x: seal.x - 50, y: seal.y - 32, width: 100, height: 64),
                       size: 50, weight: .heavy, color: gold, kern: 2)
            // Card edge.
            cg.setStrokeColor(gold.withAlphaComponent(0.6).cgColor)
            cg.setLineWidth(6)
            cg.stroke(CGRect(x: 3, y: 3, width: size.width - 6, height: size.height - 6))
        }
    }
}

// MARK: - The employee identity (persisted)

/// Oct 5: the minimal persisted result of admission besides
/// `admission.completed` -- the employee number and the accepted Hallways
/// portrait (the TRANSFORMED image only; the raw capture is never stored).
nonisolated enum EmployeeID {
    static let numberKey = "admission.employeeNumber"

    static var number: String? { UserDefaults.standard.string(forKey: numberKey) }

    static func makeNumber() -> String {
        String(format: "HB-%03d-%03d", Int.random(in: 100...999), Int.random(in: 0...999))
    }

    static var portraitURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("EmployeeID", isDirectory: true)
            .appendingPathComponent("portrait.png")
    }

    static func save(portrait: UIImage, number: String) {
        UserDefaults.standard.set(number, forKey: numberKey)
        guard let url = portraitURL, let data = portrait.pngData() else {
            diag("employeeID.saveFailed", ["reason": "encode"])
            return
        }
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                diag("employeeID.saved", ["bytes": data.count, "number": number])
            } catch {
                diag("employeeID.saveFailed", ["reason": "\(error)"])
            }
        }
    }

    /// DEV (New Player reset): forget the number and delete the saved portrait.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: numberKey)
        if let url = portraitURL, FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) }
            catch { diag("employeeID.resetFailed", ["reason": "\(error)"]) }
        }
        diag("employeeID.reset", [:])
    }

    /// The player's Hallways portrait, if a card has been issued.
    static func loadPortrait() -> UIImage? {
        guard let url = portraitURL else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

// MARK: - Kiosk machine sounds (synthesised, like the critters)

nonisolated enum KioskSound {
    private static func make(_ name: String, volume: Float, _ render: () -> [Float]) -> SCNAudioSource? {
        let s = MenagerieSound.source("kiosk-v1-\(name)", volume: volume, render)
        s?.isPositional = false
        return s
    }

    /// Relay click: ACCEPT registered.
    static let accept: SCNAudioSource? = make("accept", volume: 0.5) {
        var rng = MenagerieSound.Rand(seed: 501)
        let a = MenagerieSound.strike([(2600, 0.012, 1), (1300, 0.03, 0.5), (420, 0.05, 0.35)], seconds: 0.14, noise: 0.5, rng: &rng)
        let b = MenagerieSound.strike([(2100, 0.01, 0.8), (980, 0.025, 0.4)], seconds: 0.12, noise: 0.4, rng: &rng)
        return MenagerieSound.mix([(at: 0, samples: a, gain: 1), (at: 0.075, samples: b, gain: 0.6)])
    }

    /// Printer chatter over a low motor, ~1.2 s.
    static let printing: SCNAudioSource? = make("printing", volume: 0.35) {
        var rng = MenagerieSound.Rand(seed: 502)
        var parts: [(at: Float, samples: [Float], gain: Float)] = [
            (at: 0, samples: MenagerieSound.sweep(150, 162, seconds: 1.2, wobble: 0.3), gain: 0.3)
        ]
        var t: Float = 0.04
        while t < 1.12 {
            let tick = MenagerieSound.strike([(3400, 0.004, 1), (1700, 0.008, 0.4)], seconds: 0.03, noise: 0.7, rng: &rng)
            parts.append((at: t, samples: tick, gain: 0.55 + rng.unit() * 0.3))
            t += 0.045 + rng.unit() * 0.012
        }
        return MenagerieSound.mix(parts)
    }

    /// Rollers feeding the card out, ending in a soft clack.
    static let eject: SCNAudioSource? = make("eject", volume: 0.45) {
        var rng = MenagerieSound.Rand(seed: 503)
        let whir = MenagerieSound.sweep(240, 190, seconds: 0.85, wobble: 0.6, curve: 0.7)
        let rub = MenagerieSound.rustle(grains: 30, seconds: 0.85, grainLength: 0.01, rng: &rng)
        let clack = MenagerieSound.strike([(1800, 0.01, 1), (700, 0.03, 0.5)], seconds: 0.1, noise: 0.6, rng: &rng)
        return MenagerieSound.mix([(at: 0, samples: whir, gain: 0.45), (at: 0, samples: rub, gain: 0.25),
                                   (at: 0.85, samples: clack, gain: 0.8)])
    }

    /// The card pulled free: a light plastic snick and a brush.
    static let take: SCNAudioSource? = make("take", volume: 0.55) {
        var rng = MenagerieSound.Rand(seed: 504)
        let snick = MenagerieSound.strike([(3800, 0.006, 1), (1900, 0.015, 0.4)], seconds: 0.08, noise: 0.8, rng: &rng)
        let brush = MenagerieSound.rustle(grains: 8, seconds: 0.14, grainLength: 0.008, rng: &rng)
        return MenagerieSound.mix([(at: 0, samples: snick, gain: 1), (at: 0.02, samples: brush, gain: 0.4)])
    }

    static func play(_ source: SCNAudioSource?, on node: SCNNode?) {
        guard let source, let node else { return }
        node.runAction(.playAudio(source, waitForCompletion: false))
    }
}

// MARK: - Camera: one still from the front camera, no preview

/// Starts the front camera only for the moment of the photo, lets exposure
/// settle briefly, takes ONE still, and stops. Nothing is shown live and
/// nothing is saved to the photo library.
nonisolated final class IDPhotoCamera: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "hallways.idphoto.camera")
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var configured = false
    private var completion: (@Sendable (UIImage?) -> Void)?

    func capture(completion: @escaping @Sendable (UIImage?) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run(completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted { self.run(completion) } else { completion(nil) }
            }
        default:
            completion(nil)
        }
    }

    private func run(_ completion: @escaping @Sendable (UIImage?) -> Void) {
        queue.async {
            if !self.configured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input), self.session.canAddOutput(self.output) else {
                    self.session.commitConfiguration()
                    completion(nil)
                    return
                }
                self.session.addInput(input)
                self.session.addOutput(self.output)
                self.session.commitConfiguration()
                self.configured = true
            }
            if let connection = self.output.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true          // you, as you know your own face
                }
            }
            self.completion = completion
            self.session.startRunning()
            self.queue.asyncAfter(deadline: .now() + 0.7) {   // let exposure/white balance settle
                self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        queue.async {
            self.session.stopRunning()
            let done = self.completion
            self.completion = nil
            done?(image)
        }
    }
}

// The Hallways face rule lives in HallwaysFace.swift (shared with the mirror later).
