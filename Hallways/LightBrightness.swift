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
        case .ceiling, .fluorescent: return 0...12
        case .wall, .fire, .picture: return 1...5
        }
    }

    func intensity(level: Int) -> CGFloat {
        let values: [CGFloat]
        switch self {
        // Index 0 IS level 0 here (OFF) -- ceiling/fluorescent's range
        // starts at 0, so no "-1" offset is needed for them; wall/fire/
        // picture still start at 1 and use one below. This authored
        // curve itself is UNCHANGED by the Sept 22 range-halving below
        // -- same numbers, same shape -- only how far along it each UI
        // level reaches has changed.
        case .fluorescent, .ceiling: values = [0, 5, 12, 22, 35, 52, 75, 100, 135, 180, 240]
        case .wall: values = [100, 175, 260, 350, 460]
        case .fire: values = [30, 55, 85, 115, 150]
        case .picture: values = [1, 3, 6, 10, 16]
        }
        let clampedLevel = min(levelRange.upperBound, max(levelRange.lowerBound, level))
        // Sept 22 (Eddie: brightness-range halving cleanup). The UI
        // keeps the exact same discrete step count it always had for
        // every kind (0...10 for ceiling/fluorescent, 1...5 for wall/
        // fire/picture -- levelRange itself is untouched, on purpose:
        // "KEEP the UI as 10 discrete graduations," and per-kind range
        // redesign is explicitly deferred). What changed is that each
        // UI level now QUERIES the same authored curve at HALF its own
        // level instead of at its own level, so the new top step
        // reproduces what the OLD curve's midpoint step used to
        // produce (new level 10 == old level 5's actual output, new
        // level 2 == old level 1's, etc. -- Eddie's own worked
        // example). A query that lands between two authored integer
        // steps (every odd new level) is linearly interpolated between
        // them rather than rounded, so the halved curve stays smooth.
        // The query is clamped to never go BELOW levelRange.lowerBound
        // -- the authored table's own floor -- so OFF (0, for ceiling/
        // fluorescent) stays OFF, and wall/fire/picture's lowest UI
        // step (which has no level below it to compress toward) keeps
        // its full original intensity rather than being extrapolated
        // past the authored table's start.
        let queryLevel = max(Double(levelRange.lowerBound), Double(clampedLevel) / 2.0)
        let lowerIndex = Int(queryLevel.rounded(.down)) - levelRange.lowerBound
        let upperIndex = min(lowerIndex + 1, values.count - 1)
        let fraction = queryLevel - queryLevel.rounded(.down)
        let lowerValue = values[max(0, lowerIndex)]
        let upperValue = values[upperIndex]
        return lowerValue + (upperValue - lowerValue) * CGFloat(fraction)
    }
}

/// Optional metadata for the existing light placements in a floor record.
/// No entry means level 3; this does not create or place a light itself.
struct LightBrightness: Codable, Equatable {
    let coord: GridCoordinate
    let kind: AuthoredLightKind
    let level: Int
    /// Sept 22 (wall-face authoring expansion): only meaningful for
    /// `.picture` kind, where a single cell can now have more than one
    /// Picture Light on different walls -- nil for every other kind,
    /// and nil for a legacy `.picture` record saved before this field
    /// existed (Swift's synthesized Codable decodes a missing key on
    /// an Optional property as nil, same trick used elsewhere in this
    /// app -- see PictureSizePlacement.size). `level(for:at:direction:in:)`
    /// below still matches a nil-direction `.picture` record against
    /// ANY queried direction, so an old single-picture floor's Picture
    /// Light brightness keeps applying unchanged.
    var direction: Direction? = nil

    static func level(for kind: AuthoredLightKind, at coord: GridCoordinate, direction: Direction? = nil,
                      in settings: [LightBrightness]) -> Int {
        let candidates = settings.filter { $0.coord == coord && $0.kind == kind }
        let match: LightBrightness?
        if kind == .picture, let direction {
            match = candidates.last { $0.direction == direction } ?? candidates.last { $0.direction == nil }
        } else {
            match = candidates.last
        }
        let raw = match?.level ?? 3
        return min(kind.levelRange.upperBound, max(kind.levelRange.lowerBound, raw))
    }
}
