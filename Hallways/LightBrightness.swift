import Foundation

/// Authoring levels are relative to the existing fixture, not universal lumens.
enum AuthoredLightKind: String, Codable {
    case ceiling, wall, fire, picture, fluorescent

    /// Sept 21 (0-10 brightness expansion): ceiling/fluorescent moved to an
    /// 11-step authored range -- 0 is a real, meaningful level (OFF: the
    /// fixture stays physically present/editable, its SCNLight just goes
    /// to zero intensity), not "no value stored." wall/fire/picture keep
    /// their original 5-step ranges and curves unchanged -- this is the
    /// one place either fact is expressed, so nothing else should
    /// hardcode a brightness bound for any kind.
    var levelRange: ClosedRange<Int> {
        switch self {
        case .ceiling, .fluorescent: return 0...10
        case .wall, .fire, .picture: return 1...5
        }
    }

    func intensity(level: Int) -> CGFloat {
        let values: [CGFloat]
        switch self {
        // Index 0 IS level 0 here (OFF) -- ceiling/fluorescent's range
        // starts at 0, so no "-1" offset is needed for them; wall/fire/
        // picture still start at 1 and use one below.
        case .fluorescent, .ceiling: values = [0, 5, 12, 22, 35, 52, 75, 100, 135, 180, 240]
        case .wall: values = [100, 175, 260, 350, 460]
        case .fire: values = [30, 55, 85, 115, 150]
        case .picture: values = [1, 3, 6, 10, 16]
        }
        let clamped = min(levelRange.upperBound, max(levelRange.lowerBound, level))
        return values[clamped - levelRange.lowerBound]
    }
}

/// Optional metadata for the existing light placements in a floor record.
/// No entry means level 3; this does not create or place a light itself.
struct LightBrightness: Codable, Equatable {
    let coord: GridCoordinate
    let kind: AuthoredLightKind
    let level: Int

    static func level(for kind: AuthoredLightKind, at coord: GridCoordinate,
                      in settings: [LightBrightness]) -> Int {
        let raw = settings.last { $0.coord == coord && $0.kind == kind }?.level ?? 3
        return min(kind.levelRange.upperBound, max(kind.levelRange.lowerBound, raw))
    }
}
