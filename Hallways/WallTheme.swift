//
//  WallTheme.swift
//  Hallways
//
//  The texture "arsenal" — real photos tiled across walls, floor, and/or
//  ceiling. Each case picks which bundled square jpg (if any) goes on
//  each of the three surfaces; nil for a surface means "leave it the
//  plain flat color HallwayScene falls back to," so one theme can
//  texture just the walls, or walls-and-ceiling, or (once we have floor
//  photos) all three — add a new case here the moment a new photo lands
//  in the project folder and it's immediately in the cycle button's
//  rotation.
//
//  myPhotos is different from the rest: there's no bundled image for
//  it (wallImageName/ceilingImageName are both nil here on purpose) —
//  ContentView's Coordinator special-cases it and pulls live images
//  from the camera roll instead, via PhotoRollProvider. It still
//  participates in the normal cycle/label/allCases machinery below like
//  any other theme.
//

import Foundation

enum HallwayTheme: String, CaseIterable {
    case brick
    case cave
    case fishTank
    case paisley
    case fire
    case chainLink
    case myPhotos

    /// Bundled file name (no extension — HallwayScene loads
    /// "<name>.jpg" from the app bundle), or nil to keep that surface's
    /// plain flat color instead of a texture.
    var wallImageName: String? {
        switch self {
        case .brick: return "BrickWall"
        case .cave: return "CaveWall"
        case .fishTank: return "FishTankWall"
        case .paisley: return "Paisley"
        case .fire: return "Fire"
        case .chainLink: return "ChainLink"
        case .myPhotos: return nil // live from the camera roll, see PhotoRollProvider
        }
    }

    var floorImageName: String? {
        nil // no floor photos yet — every theme keeps the plain dark floor for now
    }

    var ceilingImageName: String? {
        switch self {
        case .paisley: return "Paisley" // Eddie's ask: try it on walls AND ceiling
        default: return nil // myPhotos included — its ceiling photo is also live, not bundled
        }
    }

    var label: String {
        switch self {
        case .brick: return "Brick"
        case .cave: return "Cave"
        case .fishTank: return "Fish Tank"
        case .paisley: return "Paisley"
        case .fire: return "Fire"
        case .chainLink: return "Chain-Link"
        case .myPhotos: return "My Photos"
        }
    }

    var next: HallwayTheme {
        let all = HallwayTheme.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }
}
