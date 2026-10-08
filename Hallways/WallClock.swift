import SceneKit
import UIKit

/// Oct 8 -- HALLWAYS RUNS ON REAL LOCAL TIME.
///
/// The one analog wall clock: a round office clock (dial with numerals and
/// minute ticks, dark rim, black hour/minute hands, thin red second hand)
/// whose hands are SET from the device's current local time -- never
/// accumulated, never simulated. Grown from the Administration back-wall
/// clock (which used to fake it: a fixed hour hand and a minute hand
/// creeping from 12 at launch); that clock is now built here too.
///
/// Updating: one shared 1 Hz timer for every clock in the building (only
/// while at least one exists), plus an immediate refresh on returning to
/// the foreground and on a clock / time-zone change. A handful of node
/// rotations a second -- no render loop, no SCNActions.
@MainActor
enum WallClock {
    static let nodeName = "wallClock"
    /// Mounted above everything else on an office wall (centre height, m).
    static let mountHeight: Float = 2.25
    static let defaultRadius: CGFloat = 0.17
    static let depth: CGFloat = 0.045

    // MARK: Time -> hands (radians clockwise from 12)

    struct HandAngles: Equatable {
        let hour: Double
        let minute: Double
        let second: Double
    }

    /// Hour hand moves with the minutes (and seconds); minute hand with the
    /// seconds; second hand ticks whole seconds.
    nonisolated static func handAngles(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> HandAngles {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        let h = Double((c.hour ?? 0) % 12), m = Double(c.minute ?? 0), s = Double(c.second ?? 0)
        let turn = 2 * Double.pi
        return HandAngles(hour: (h + m / 60 + s / 3600) / 12 * turn,
                          minute: (m + s / 60) / 60 * turn,
                          second: s / 60 * turn)
    }

    // MARK: The clock

    /// A clock facing local +Z (its back at z = -depth/2), centred on the
    /// origin. Registers with the shared ticker and shows the time at once.
    static func makeNode(radius r: CGFloat = defaultRadius) -> SCNNode {
        let root = SCNNode()
        root.name = nodeName
        let body = SCNNode(geometry: SCNCylinder(radius: r, height: depth))
        body.geometry?.materials = [Materials.body]
        body.eulerAngles.x = .pi / 2
        root.addChildNode(body)
        let rim = SCNNode(geometry: SCNTorus(ringRadius: r, pipeRadius: r * 0.085))
        rim.geometry?.materials = [Materials.rim]
        rim.eulerAngles.x = .pi / 2
        rim.position.z = Float(depth) / 2 - Float(r) * 0.03
        root.addChildNode(rim)
        let dial = SCNNode(geometry: SCNPlane(width: r * 1.84, height: r * 1.84))
        dial.geometry?.materials = [Materials.dial]
        dial.position.z = Float(depth) / 2 + 0.001
        root.addChildNode(dial)

        func hand(_ name: String, length: CGFloat, width: CGFloat, tail: CGFloat, z: Float, _ m: SCNMaterial) -> SCNNode {
            let pivot = SCNNode()
            pivot.name = name
            pivot.position.z = Float(depth) / 2 + z
            let bar = SCNNode(geometry: SCNBox(width: width, height: length + tail, length: 0.004, chamferRadius: width * 0.3))
            bar.geometry?.materials = [m]
            bar.position.y = Float(length - tail) / 2
            pivot.addChildNode(bar)
            root.addChildNode(pivot)
            return pivot
        }
        let hour = hand("wallClockHour", length: r * 0.52, width: r * 0.075, tail: r * 0.12, z: 0.006, Materials.ink)
        let minute = hand("wallClockMinute", length: r * 0.8, width: r * 0.05, tail: r * 0.14, z: 0.011, Materials.ink)
        let second = hand("wallClockSecond", length: r * 0.86, width: r * 0.016, tail: r * 0.22, z: 0.016, Materials.second)
        let cap = SCNNode(geometry: SCNCylinder(radius: r * 0.06, height: 0.006))
        cap.geometry?.materials = [Materials.second]
        cap.eulerAngles.x = .pi / 2
        cap.position.z = Float(depth) / 2 + 0.02
        root.addChildNode(cap)

        let clock = Hands(hour: hour, minute: minute, second: second)
        clock.show(handAngles(for: Date()))
        Ticker.shared.register(clock)
        return root
    }

    /// A clock on a cell's wall face, in the build's world space: flush
    /// against the wall's inner face, facing into the cell.
    static func makeWallNode(at face: WallFace, cellSize: CGFloat) -> SCNNode {
        let node = makeNode()
        let d = face.direction.delta
        let inset = Float(cellSize / 2) - 0.05 - Float(depth) / 2 - 0.004   // wall panels are 0.1 m thick
        node.position = SCNVector3(Float(CGFloat(face.coord.col) * cellSize) + Float(d.col) * inset,
                                   mountHeight,
                                   Float(CGFloat(face.coord.row) * cellSize) + Float(d.row) * inset)
        switch face.direction {
        case .north: break
        case .south: node.eulerAngles.y = .pi
        case .east: node.eulerAngles.y = -.pi / 2
        case .west: node.eulerAngles.y = .pi / 2
        }
        return node
    }

    /// Reads a clock's hands back (tests / diagnostics).
    static func shownAngles(of clock: SCNNode) -> HandAngles? {
        guard let h = clock.childNode(withName: "wallClockHour", recursively: true),
              let m = clock.childNode(withName: "wallClockMinute", recursively: true),
              let s = clock.childNode(withName: "wallClockSecond", recursively: true) else { return nil }
        return HandAngles(hour: Double(-h.eulerAngles.z), minute: Double(-m.eulerAngles.z), second: Double(-s.eulerAngles.z))
    }

    /// Every live clock to `date` now (tests; the ticker uses the clock).
    static func refreshAll(at date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        Ticker.shared.refresh(at: date, calendar: calendar)
    }

    static var liveClockCount: Int { Ticker.shared.liveCount }

    // MARK: Internals

    final class Hands {
        weak var hour: SCNNode?
        weak var minute: SCNNode?
        weak var second: SCNNode?
        init(hour: SCNNode, minute: SCNNode, second: SCNNode) { self.hour = hour; self.minute = minute; self.second = second }
        var isAlive: Bool { hour != nil }
        func show(_ a: HandAngles) {
            // Clockwise as seen from the front (+Z).
            hour?.eulerAngles = SCNVector3(0, 0, Float(-a.hour))
            minute?.eulerAngles = SCNVector3(0, 0, Float(-a.minute))
            second?.eulerAngles = SCNVector3(0, 0, Float(-a.second))
        }
    }

    final class Ticker {
        static let shared = Ticker()
        private var clocks: [Hands] = []
        private var timer: Timer?
        private var observers: [NSObjectProtocol] = []

        var liveCount: Int { clocks.filter(\.isAlive).count }

        func register(_ clock: Hands) {
            clocks.removeAll { !$0.isAlive }
            clocks.append(clock)
            start()
        }

        func refresh(at date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
            clocks.removeAll { !$0.isAlive }
            if clocks.isEmpty { stop(); return }
            let angles = WallClock.handAngles(for: date, calendar: calendar)
            for clock in clocks { clock.show(angles) }
        }

        private func start() {
            guard timer == nil else { return }
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            t.tolerance = 0.05
            RunLoop.main.add(t, forMode: .common)
            timer = t
            // Back from suspension, or the device's clock / zone changed:
            // show the right time at once, not on the next tick.
            let center = NotificationCenter.default
            for name in [UIApplication.didBecomeActiveNotification,
                         UIApplication.significantTimeChangeNotification,
                         Notification.Name.NSSystemTimeZoneDidChange,
                         Notification.Name.NSSystemClockDidChange] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
        }

        private func stop() {
            timer?.invalidate()
            timer = nil
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
        }
    }

    private enum Materials {
        static let body: SCNMaterial = {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor(white: 0.16, alpha: 1)
            m.metalness.contents = 0.3
            m.roughness.contents = 0.5
            return m
        }()
        static let rim: SCNMaterial = {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor(white: 0.1, alpha: 1)
            m.metalness.contents = 0.5
            m.roughness.contents = 0.35
            return m
        }()
        static let ink: SCNMaterial = {
            let m = SCNMaterial()
            m.lightingModel = .lambert
            m.diffuse.contents = UIColor(white: 0.06, alpha: 1)
            return m
        }()
        static let second: SCNMaterial = {
            let m = SCNMaterial()
            m.lightingModel = .lambert
            m.diffuse.contents = UIColor(red: 0.78, green: 0.1, blue: 0.08, alpha: 1)
            return m
        }()
        /// The face: numerals 1-12 and minute ticks, drawn once and shared.
        /// A little self-light keeps it readable in dimmer corridors.
        static let dial: SCNMaterial = {
            let m = SCNMaterial()
            m.lightingModel = .lambert
            let image = dialImage()
            m.diffuse.contents = image
            m.emission.contents = image
            m.emission.intensity = 0.25
            m.diffuse.mipFilter = .linear          // corners outside the round face are transparent
            return m
        }()
    }

    nonisolated static func dialImage(size: CGFloat = 512) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let g = ctx.cgContext
            let c = CGPoint(x: size / 2, y: size / 2)
            let R = size / 2
            g.setFillColor(UIColor(white: 0.97, alpha: 1).cgColor)
            g.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
            g.setStrokeColor(UIColor(white: 0.12, alpha: 1).cgColor)
            g.setLineCap(.butt)
            for i in 0..<60 {
                let a = Double(i) / 60 * 2 * .pi
                let major = i % 5 == 0
                let outer = R * 0.96, inner = R * (major ? 0.84 : 0.91)
                g.setLineWidth(major ? R * 0.035 : R * 0.012)
                g.move(to: CGPoint(x: c.x + CGFloat(sin(a)) * inner, y: c.y - CGFloat(cos(a)) * inner))
                g.addLine(to: CGPoint(x: c.x + CGFloat(sin(a)) * outer, y: c.y - CGFloat(cos(a)) * outer))
                g.strokePath()
            }
            let font = UIFont.systemFont(ofSize: R * 0.2, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(white: 0.1, alpha: 1)]
            for n in 1...12 {
                let a = Double(n) / 12 * 2 * .pi
                let text = "\(n)" as NSString
                let s = text.size(withAttributes: attributes)
                let p = CGPoint(x: c.x + CGFloat(sin(a)) * R * 0.68 - s.width / 2,
                                y: c.y - CGFloat(cos(a)) * R * 0.68 - s.height / 2)
                text.draw(at: p, withAttributes: attributes)
            }
        }
    }
}
