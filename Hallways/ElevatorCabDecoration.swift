import Foundation
import SceneKit

/// One building-wide ceiling slot. No floor ID or maze coordinate is involved.
struct ElevatorCabDecoration: Codable, Equatable {
    struct Fixture: Codable, Equatable {
        enum Kind: String, Codable { case ceiling, fluorescent }
        let kind: Kind
        let brightness: Int
        let orientation: FluorescentOrientation

        init(kind: Kind, brightness: Int = 3, orientation: FluorescentOrientation = .northSouth) {
            self.kind = kind
            self.brightness = min(10, max(0, brightness))
            self.orientation = orientation
        }
    }

    var ceilingFixture: Fixture? = nil
    static let storageKey = "Hallways.elevatorCabDecoration.v1"

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        guard let fixture = decoded.ceilingFixture else { return Self() }
        return Self(ceilingFixture: Fixture(kind: fixture.kind, brightness: fixture.brightness,
                                           orientation: fixture.orientation))
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

extension HallwayScene {
    /// The mount lives at the actual inner ceiling face, in the cab's own axes.
    /// Both floor reconstruction and live ADD use this same fixture factory.
    static func makeElevatorCabFixture(_ fixture: ElevatorCabDecoration.Fixture,
                                      cellSize: CGFloat, floorNumber: Int) -> SCNNode {
        let node = fixture.kind == .fluorescent
            ? makeFluorescentLight(orientation: fixture.orientation, level: fixture.brightness, cellSize: cellSize)
            : makeAuthoredCeilingFixture(cellSize: cellSize, level: fixture.brightness)
        DecoratorTarget(floor: floorNumber, location: .elevatorCeiling,
                        kind: fixture.kind == .fluorescent ? .fluorescent : .ceiling).tag(node)
        return node
    }
}
