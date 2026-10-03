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
    /// Sept 26 (Decorate-mode elevator pictures): the authored image
    /// choice for each of the cab's 3 built-in posters -- back wall
    /// and side wall, same building-wide "one slot, no floor ID or
    /// maze coordinate" semantics as ceilingFixture above. nil means
    /// "no explicit choice yet", which preserves every existing
    /// poster's current behavior (ride-handoff artwork if this is an
    /// arrival, otherwise the random/camera-roll fallback --
    /// HallwayScene.addElevatorDoor's own resolution order) exactly
    /// the way an unset PictureImageSelection already does for an
    /// ordinary wall Picture. Only ever .builtIn/.cameraRoll in
    /// practice (Decorate-mode's own UI never offers .lobbyDefault),
    /// but left as the full PictureImageSelection type rather than a
    /// narrower one so it stays a drop-in match for
    /// applyLivePictureSelection/setPictureImageSelection's existing
    /// resolution logic.
    var backArtwork: PictureImageSelection? = nil
    var sideArtwork: PictureImageSelection? = nil
    /// Sept 26 (third elevator poster, right wall): same building-wide,
    /// "no explicit choice yet falls back to ride-handoff/random" shape
    /// as backArtwork/sideArtwork above -- added as a third field on
    /// the SAME struct rather than a parallel type, per Eddie's
    /// "extend ElevatorCabDecoration rather than introducing separate
    /// persistence" instruction.
    var sideRightArtwork: PictureImageSelection? = nil
    static let storageKey = "Hallways.elevatorCabDecoration.v1"

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        // Sept 26: resolve each field independently -- the previous
        // "guard let fixture = decoded.ceilingFixture else { return
        // Self() }" was an all-or-nothing gate that would silently
        // wipe backArtwork/sideArtwork on load whenever no ceiling
        // fixture happened to be saved (the common case before this
        // pass existed at all, and still common for anyone who never
        // added one).
        let fixture: Fixture? = decoded.ceilingFixture.map {
            Fixture(kind: $0.kind, brightness: $0.brightness, orientation: $0.orientation)
        }
        return Self(ceilingFixture: fixture, backArtwork: decoded.backArtwork, sideArtwork: decoded.sideArtwork, sideRightArtwork: decoded.sideRightArtwork)
    }

    /// Whether this device has EVER saved its own cab decoration. A device
    /// with no saved value is seeded from the bundled building default.
    static func hasSavedValue(in defaults: UserDefaults) -> Bool {
        defaults.data(forKey: storageKey) != nil
    }

    /// The part of the cab decoration that means the same thing on any
    /// device, for the building-default JSON: the ceiling fixture (kind,
    /// brightness, orientation) and built-in / bundled poster images.
    /// Camera-roll poster choices are PHAsset identifiers that only exist
    /// in THIS device's photo library, so they are left out (nil) -- a
    /// device loading the default then shows its ordinary fallback poster
    /// for that wall, exactly as with no choice made. The exporting
    /// device's own local choice is untouched.
    var portable: ElevatorCabDecoration {
        func portable(_ selection: PictureImageSelection?) -> PictureImageSelection? {
            switch selection {
            case .builtIn?, .lobbyDefault?: return selection
            case .cameraRoll?, nil: return nil
            }
        }
        return ElevatorCabDecoration(
            ceilingFixture: ceilingFixture.map { Fixture(kind: $0.kind, brightness: $0.brightness, orientation: $0.orientation) },
            backArtwork: portable(backArtwork), sideArtwork: portable(sideArtwork),
            sideRightArtwork: portable(sideRightArtwork))
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
