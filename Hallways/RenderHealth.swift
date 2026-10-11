import Foundation
import SceneKit

/// Oct 9 (iPhone heating investigation) -- MEASUREMENT ONLY, changes nothing.
///
/// The Oct 9 report showed five stationary minutes on Floor 2 with no
/// logged activity at all while the phone got hot: whatever was working
/// wasn't in the log. This puts the missing numbers into the existing
/// periodic `snapshot.state` line (every 30 s):
///   - fps ........ frames SceneKit actually rendered since the last snapshot
///   - thermal .... ProcessInfo.thermalState (nominal/fair/serious/critical)
///   - lowPower ... Low Power Mode
///   - nodes/lights/lightsByKind ... what the current floor asks the GPU to light
/// and logs `device.thermal` the moment iOS changes the thermal state.
nonisolated final class RenderHealth: @unchecked Sendable {
    static let shared = RenderHealth()

    private let lock = NSLock()
    private var frames = 0
    private var lastSampleUptime = ProcessInfo.processInfo.systemUptime
    private var watching = false

    /// From SceneKit's render thread, once per rendered frame: one counter.
    func frameRendered() {
        lock.lock(); frames += 1; lock.unlock()
    }

    /// Frames per second rendered since the previous call.
    func sampleFPS() -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let count = frames, elapsed = now - lastSampleUptime
        frames = 0
        lastSampleUptime = now
        lock.unlock()
        return elapsed > 0.5 ? Double(count) / elapsed : 0
    }

    /// Oct 9 (30 FPS experiment) -- a reversible TEST setting, not an
    /// adaptive system. Off by default: SceneKit's own default (60 on these
    /// phones). To compare, in Xcode: Product > Scheme > Edit Scheme > Run >
    /// Arguments > Arguments Passed On Launch, add `-HallwaysFPS 30` (tick it
    /// on/off to switch; `-HallwaysFPS 60` forces 60). Read once per floor
    /// install. Everything that moves is timed in seconds (SCNActions and
    /// dt-based updates), so 30 changes smoothness, not speed.
    static let fpsDefaultsKey = "HallwaysFPS"
    static var testFramesPerSecond: Int? {
        let v = UserDefaults.standard.integer(forKey: fpsDefaultsKey)
        return v > 0 ? v : nil
    }

    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Idempotent: logs every thermal-state change (and Low Power Mode
    /// changes) for the rest of the launch.
    func startWatching() {
        lock.lock()
        let first = !watching
        watching = true
        lock.unlock()
        guard first else { return }
        diag("device.thermal", ["state": Self.thermal, "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled, "why": "start"])
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
            diag("device.thermal", ["state": RenderHealth.thermal, "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled, "why": "changed"])
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { _ in
            diag("device.thermal", ["state": RenderHealth.thermal, "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled, "why": "powerState"])
        }
    }

    /// Node and light census of a scene (a walk of the graph -- call it
    /// at snapshot cadence, never per frame).
    static func census(_ root: SCNNode?) -> (nodes: Int, lights: Int, byKind: String) {
        guard let root else { return (0, 0, "") }
        var nodes = 0, lights = 0
        var kinds: [String: Int] = [:]
        root.enumerateHierarchy { node, _ in
            nodes += 1
            guard let light = node.light else { return }
            lights += 1
            kinds[light.type.rawValue, default: 0] += 1
        }
        return (nodes, lights, kinds.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    }
}
