//
//  HallwaysianResidents.swift
//  Hallways
//
//  Oct 19 -- THE SIX HALLWAYSIANS move into the building: Feddy, Sister, Big
//  Fellow, Old Gent, Lanky and Tiny -- and (Oct 19, later) five more: Barrel,
//  Owl, Auntie, Pear and Mitts, then Stilts, Clunk, Topper, Scope and Lopsy:
//  sixteen PERSONAS of one species -- each a
//  HallwaysianGenome (HallwaysianSpecies.swift: body, face, features,
//  finishes), a resting posture, a pace, a few favourite gestures and a
//  one-syllable hello -- and ONE body class and ONE kind that serve them all.
//
//  They live the building's ordinary resident life (BuildingLife, Roam,
//  RoamPresentation): each comes in at the lobby entrance at its own time once
//  the building opens, rides to a floor it likes, wanders room to room and
//  floor to floor, and is saved and resumed like everyone else. Contacts meets
//  them by the usual nearness rule. Nothing scripted is touched; no missions,
//  no words, not informants.
//
//  THE BODY: HallwaysianResidentBody is the RoamerBody the resident life
//  drives. A walk's waypoints become the HallwaysianMotor's goals one by one
//  (it walks, turns and plants its feet itself); a display link (main thread,
//  one for all of them) steps the motor and poses the figure every frame.
//
//  DEBUG: `-HallwaysHallwaysiansNear YES` puts the six in the hallway near the
//  player on the first open floor reached in that run (once), then they go
//  about their lives from there. Without it they arrive and spread naturally.
//

import Foundation
import QuartzCore
import SceneKit
import UIKit
import simd
import SwiftUI     // (Color, for Contacts -- member import visibility is on)

// MARK: - A gesture (shared by everyone; a persona picks its favourites)

nonisolated struct HallwaysianGesture: Sendable {
    let name: String
    let duration: Double
    /// Held targets while it lasts.
    let set: [HallwaysianChannel: Float]
    /// One channel swinging (amplitude, Hz) on top -- a wave, a rock, a bounce.
    var swing: (channel: HallwaysianChannel, amplitude: Float, hz: Float)? = nil
    /// Where to look while it lasts, relative to him (x right, y up, z ahead -- metres).
    var look: SIMD3<Float>? = nil

    static let headTilt = HallwaysianGesture(name: "head tilt", duration: 2.2,
                                             set: [.headRoll: 0.26, .lidTilt: -0.12, .smile: 0.25, .neckPitch: -0.05])
    static let lookAtHand = HallwaysianGesture(name: "looks at his hand", duration: 2.6,
                                               set: [.shPitchR: 0.95, .elbowR: 1.7, .wrTwistR: 0.9, .curlR: 0.7, .headRoll: 0.2,
                                                     .pupil: 0.85, .neckPitch: -0.05],
                                               look: SIMD3(0.1, -0.35, 0.35))
    static let handsToChest = HallwaysianGesture(name: "hands to chest", duration: 2.6,
                                                 set: [.low: 0.6, .lid: 0.15, .smile: 1.0, .mouthW: 1.2, .shPitchL: 0.85, .shPitchR: 0.85,
                                                       .shYawL: 0.5, .shYawR: 0.5, .elbowL: 1.95, .elbowR: 1.95, .curlL: 0.7, .curlR: 0.7,
                                                       .headRoll: 0.18],
                                                 swing: (.sway, 0.07, 0.85))
    static let wave = HallwaysianGesture(name: "wave", duration: 2.2,
                                         set: [.shPitchR: 0.45, .shRollR: 1.3, .elbowR: 1.5, .wrTwistR: 0.3, .curlR: 0.08, .thumbR: 0.08,
                                               .smile: 0.9, .headRoll: 0.1, .low: 0.35],
                                         swing: (.elbowR, 0.38, 2.1))
    static let peer = HallwaysianGesture(name: "peers", duration: 2.5,
                                         set: [.lean: -0.12, .neckPitch: -0.16, .lid: 0, .lidTilt: -0.15, .mouthW: 0.6, .smile: 0.05],
                                         look: SIMD3(0, -0.5, 1.2))
    static let shrug = HallwaysianGesture(name: "shrug", duration: 1.6,
                                          set: [.shRollL: 0.45, .shRollR: 0.45, .elbowL: 1.2, .elbowR: 1.2, .headRoll: 0.15,
                                                .smile: -0.1, .mouthW: 0.7, .lidTilt: -0.2])
    static let stretch = HallwaysianGesture(name: "stretch", duration: 2.4,
                                            set: [.shPitchL: 2.6, .shPitchR: 2.6, .elbowL: 0.2, .elbowR: 0.2, .mouthO: 0.6, .lid: 0.6,
                                                  .headPitch: 0.2, .lean: 0.05])
    static let patBelly = HallwaysianGesture(name: "pats his belly", duration: 2.5,
                                             set: [.shPitchL: 0.6, .shPitchR: 0.6, .shYawL: 0.4, .shYawR: 0.4, .elbowL: 1.4, .elbowR: 1.4,
                                                   .smile: 0.9, .low: 0.4],
                                             swing: (.elbowR, 0.25, 2.4))
    static let bounce = HallwaysianGesture(name: "bounces", duration: 1.8,
                                           set: [.smile: 0.7, .mouthO: 0.25, .lid: -0.05],
                                           swing: (.bob, 0.025, 3.0))
    static let tidyHair = HallwaysianGesture(name: "tidies her hair", duration: 2.2,
                                             set: [.shPitchL: 2.2, .shRollL: 0.35, .elbowL: 2.0, .headRoll: -0.18, .smile: 0.3])
    static let sigh = HallwaysianGesture(name: "sighs", duration: 2.6,
                                         set: [.lid: 0.6, .headPitch: -0.15, .smile: -0.05, .shRollL: 0.02, .shRollR: 0.02],
                                         swing: (.breath, 0.02, 0.6))
    static let lookAround = HallwaysianGesture(name: "looks around", duration: 3.0, set: [:])
    // activity beats
    static let tinker = HallwaysianGesture(name: "tinkers", duration: 3.0,
                                           set: [.shPitchL: 0.85, .shPitchR: 0.85, .elbowL: 1.0, .elbowR: 1.0, .curlL: 0.6, .curlR: 0.6,
                                                 .lean: -0.1, .neckPitch: -0.12, .lidTilt: -0.12],
                                           swing: (.elbowL, 0.18, 3.2), look: SIMD3(0, -0.4, 0.7))
    static let rest = HallwaysianGesture(name: "rests", duration: 3.5,
                                         set: [.lid: 0.55, .low: 0.2, .smile: 0.3, .shRollL: 0.02, .shRollR: 0.02],
                                         swing: (.sway, 0.03, 0.4))
    static let push = HallwaysianGesture(name: "pushes", duration: 0.9,
                                         set: [.shPitchR: 1.4, .elbowR: 0.3, .wrPitchR: 0.3, .lean: -0.08])
    // Oct 20 (follow a critter) -- a come-hither when the player chooses to follow:
    // the hand held out, fingers curling "this way" ...
    static let beckon = HallwaysianGesture(name: "beckons", duration: 1.8,
                                           set: [.shPitchR: 1.0, .shYawR: 0.25, .elbowR: 1.25, .wrTwistR: 0.9, .curlR: 0.45,
                                                 .smile: 0.85, .headRoll: 0.14, .low: 0.3],
                                           swing: (.curlR, 0.45, 2.6))
    // ... a happy little jig, elbows out ...
    static let jig = HallwaysianGesture(name: "a little jig", duration: 1.8,
                                        set: [.shRollL: 0.7, .shRollR: 0.7, .elbowL: 1.0, .elbowR: 1.0, .smile: 1.0, .mouthO: 0.3,
                                              .headRoll: 0.12],
                                        swing: (.sway, 0.1, 2.4))
    // ... or a small courtly bow, hand to chest.
    static let bow = HallwaysianGesture(name: "a little bow", duration: 1.9,
                                        set: [.lean: -0.16, .neckPitch: -0.18, .shPitchR: 0.85, .shYawR: 0.5, .elbowR: 1.9, .curlR: 0.6,
                                              .smile: 0.7, .lid: 0.25])
}

// MARK: - A persona: one Hallwaysian

struct HallwaysianPersona {
    let id: String
    let name: String
    let blurb: String
    let symbol: String
    let genome: HallwaysianGenome
    /// His resting face and posture (held targets, always on; gestures override).
    let posture: [HallwaysianChannel: Float]
    /// How much of a look the head takes (the rest is the eyes).
    let gazeHead: Float
    let idles: [HallwaysianGesture]
    /// What he does with things in a room (ResidentActivities' tastes).
    let species: ResidentActivities.Species
    /// Seconds after the building opens that he walks in at the lobby entrance
    /// (a new game: the building opens when onboarding is over).
    let arrivalDelay: TimeInterval
    /// Oct 19 (later): joining a building that is ALREADY open (an existing
    /// save): seconds after the save is loaded -- the six come in at the front
    /// door one after another within the first couple of minutes.
    /// Oct 19 (the five newcomers): they join a save the same way, at 45, 75,
    /// 105, 135 and 165 s -- in between the six's own times (which are unchanged).
    /// Oct 19 (five more): the third group at 38, 68, 98, 128 and 158 s -- each
    /// group 30 s apart, the groups offset so nobody shares a moment at the door.
    var joinDelay: TimeInterval {
        let i = HallwaysianCast.all.firstIndex { $0.id == id } ?? 0
        let group = HallwaysianCast.groupStarts.lastIndex { $0 <= i } ?? 0
        let k = i - HallwaysianCast.groupStarts[group]
        let offsets: [TimeInterval] = [0, 15, 8]
        return 30 + 30 * TimeInterval(k) + offsets[min(group, offsets.count - 1)]
    }
    let floors: [Int: Double]
    let stay: ClosedRange<Double>
    let changeFloor: Double
    let taste: [String: Double]
    /// His hello: Hallenese syllables (vowel, seconds, Hz from, Hz to), and the voice's size and breath.
    let hello: [(v: Int, s: Float, a: Float, b: Float)]
    let formant: Float
    let breath: Float

    /// Walking pace (m/s): the motor's own stride x cadence.
    var pace: Float { genome.stride * genome.cadence }

    /// Oct 20 (follow a critter): its come-hither, by temperament -- the bouncy
    /// ones a little jig, the courtly and the warm-hearted (a sigh, hands to the
    /// chest) a small bow, everyone else a beckoning hand.
    var acknowledgment: HallwaysianGesture {
        let favourites = Set(idles.map { $0.name })
        if favourites.contains(HallwaysianGesture.bounce.name) { return .jig }
        if favourites.contains(HallwaysianGesture.sigh.name) || favourites.contains(HallwaysianGesture.handsToChest.name) { return .bow }
        return .beckon
    }
    var kind: String { "hallwaysian.\(id)" }
    var tint: Color { Color(uiColor: genome.enamel) }

    var style: RoamStyle {
        var s = RoamStyle(floors: floors, stay: stay, speed: pace, changeFloorChance: changeFloor)
        s.roomTaste = taste
        return s
    }
    var fastStyle: RoamStyle {
        var f = style
        f.stay = 8...15
        f.changeFloorChance = max(0.5, changeFloor)
        return f
    }
}

// MARK: - The six

enum HallwaysianCast {
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }

    /// The first six, then (Oct 19) the five newcomers -- always appended, never reordered.
    static let all: [HallwaysianPersona] = [feddy, sister, bigFellow, oldGent, lanky, tiny,
                                            barrel, owl, auntie, pear, mitts,
                                            stilts, clunk, topper, scope, lopsy]
    static let originalSix = 6
    /// Where each group that moved in together starts in `all` (the six, then two fives).
    static let groupStarts = [0, 6, 11]

    static var feddy: HallwaysianPersona {
        var g = HallwaysianGenome.feddy                                        // (the original proportions; no gauge)
        g.stride = 0.36; g.cadence = 1.9
        return HallwaysianPersona(
            id: "hw.feddy", name: "Feddy",
            blurb: "Big eyes, a head pushed forward to peer at things. Can't pass a blinking light without a look.",
            symbol: "eye.fill", genome: g,
            posture: [.headRoll: 0.1, .smile: 0.35],
            gazeHead: 0.7, idles: [.lookAtHand, .headTilt, .peer, .lookAround], species: .chair,
            arrivalDelay: 140, floors: [5: 1, 6: 1, 7: 1, 11: 1.5, 13: 1], stay: 60...180, changeFloor: 0.3,
            taste: ["Server": 3, "Copy": 2, "Lamp": 1.5, "Desks": 2],
            hello: [(2, 0.08, 230, 290), (4, 0.15, 290, 250)], formant: 1.1, breath: 0.1)
    }

    static var sister: HallwaysianPersona {
        var g = HallwaysianGenome(name: "Sister")
        g.headRadii = SIMD3(0.155, 0.158, 0.148); g.headForward = 0.01; g.neckLength = 0.15; g.neckLean = 0.12
        g.torsoRadii = SIMD3(0.105, 0.13, 0.095); g.torsoLean = -0.02; g.shoulderWidth = 0.098; g.shoulderDrop = 0.05
        g.thigh = 0.19; g.shin = 0.2; g.upperArm = 0.15; g.forearm = 0.14
        g.eyeRadius = 0.06; g.eyeSpacing = 0.062; g.eyeHeight = 0.03; g.eyeToe = 0.1; g.pupilSize = 0.52
        g.mouthWidth = 0.06; g.mouthHeight = -0.068
        g.enamel = rgb(0.86, 0.50, 0.44); g.enamelRoughness = 0.55
        g.trim = rgb(0.80, 0.50, 0.36); g.trimMetalness = 0.6
        g.rubber = rgb(0.30, 0.16, 0.22)
        g.hair = HallwaysianStyle.bobBun; g.hairColor = rgb(0.24, 0.12, 0.10); g.hairRoughness = 0.75
        g.skirt = HallwaysianSkirt(waist: 0.3, length: 0.15, flare: 1.75, pleats: 16)
        g.skirtColor = rgb(0.42, 0.25, 0.43); g.skirtRoughness = 0.8
        g.stride = 0.40; g.cadence = 1.8
        return HallwaysianPersona(
            id: "hw.sister", name: "Sister",
            blurb: "Coral, brisk and cheerful, her bun always just so. Says hello to everyone, twice.",
            symbol: "sparkle", genome: g,
            posture: [.headRoll: -0.12, .smile: 0.6, .mouthW: 0.9, .lid: 0.18, .low: 0.25, .shRollL: 0.18, .shRollR: 0.18],
            gazeHead: 0.75, idles: [.tidyHair, .handsToChest, .headTilt, .lookAround], species: .chair,
            arrivalDelay: 185, floors: [4: 1, 6: 1.5, 7: 1, 8: 1, 12: 1], stay: 45...150, changeFloor: 0.45,
            taste: ["Break": 2, "Seating": 2, "Water": 2, "Aquarium": 1.5],
            hello: [(1, 0.07, 320, 380), (2, 0.14, 380, 330)], formant: 1.22, breath: 0.12)
    }

    static var bigFellow: HallwaysianPersona {
        var g = HallwaysianGenome(name: "Big Fellow")
        g.headRadii = SIMD3(0.175, 0.125, 0.15); g.headForward = 0.03; g.neckLength = 0.035; g.neckRadius = 0.02; g.neckLean = 0.2
        g.torsoRadii = SIMD3(0.235, 0.215, 0.23); g.torsoLean = -0.06
        g.hipWidth = 0.085; g.thigh = 0.105; g.shin = 0.11; g.legRadius = 0.012; g.footLength = 0.15; g.footWidth = 0.065
        g.shoulderWidth = 0.17; g.shoulderDrop = 0.075; g.upperArm = 0.13; g.forearm = 0.125
        g.eyeRadius = 0.05; g.eyeSpacing = 0.064; g.eyeHeight = 0.05; g.eyeSink = 0.4; g.pupilSize = 0.5
        g.mouthWidth = 0.1; g.mouthHeight = -0.045
        g.enamel = rgb(0.86, 0.64, 0.20); g.enamelRoughness = 0.62
        g.trim = rgb(0.42, 0.30, 0.20); g.trimMetalness = 0.7; g.trimRoughness = 0.4
        g.rubber = rgb(0.22, 0.17, 0.14)
        g.hair = HallwaysianStyle.combover; g.hairColor = rgb(0.20, 0.15, 0.10)
        g.stride = 0.26; g.cadence = 2.1
        return HallwaysianPersona(
            id: "hw.bigfellow", name: "Big Fellow",
            blurb: "Round, mustard yellow and pleased about it. Knows where every break room is.",
            symbol: "circle.fill", genome: g,
            posture: [.smile: 1.0, .mouthW: 1.15, .low: 0.45, .lid: 0.15, .shRollL: 0.62, .shRollR: 0.62, .elbowL: 0.35, .elbowR: 0.35,
                      .headPitch: 0.06],
            gazeHead: 0.55, idles: [.patBelly, .lookAround, .headTilt, .rest], species: .critter,
            arrivalDelay: 230, floors: [4: 1.5, 5: 1, 8: 1.5, 12: 1, 14: 1], stay: 90...240, changeFloor: 0.25,
            taste: ["Break": 4, "Water": 3, "Seating": 2],
            hello: [(0, 0.12, 125, 150), (5, 0.2, 150, 120)], formant: 0.85, breath: 0.12)
    }

    static var oldGent: HallwaysianPersona {
        var g = HallwaysianGenome(name: "Old Gent")
        g.headRadii = SIMD3(0.168, 0.158, 0.155); g.headForward = 0.04; g.neckLength = 0.1; g.neckLean = 0.62
        g.torsoRadii = SIMD3(0.12, 0.15, 0.11); g.torsoLean = 0.3
        g.thigh = 0.165; g.shin = 0.17; g.legRadius = 0.0095
        g.eyeRadius = 0.05; g.eyeSpacing = 0.066; g.eyeHeight = 0.045; g.eyeSink = 0.45; g.pupilSize = 0.45
        g.mouthWidth = 0.07; g.mouthHeight = -0.062
        g.enamel = rgb(0.50, 0.56, 0.62); g.enamelRoughness = 0.78
        g.trim = rgb(0.68, 0.68, 0.66); g.trimMetalness = 0.8; g.trimRoughness = 0.35
        g.rubber = rgb(0.20, 0.18, 0.17)
        g.hair = HallwaysianStyle.fringe; g.hairColor = rgb(0.90, 0.89, 0.86); g.hairRoughness = 0.9
        g.moustache = HallwaysianStyle.walrus
        g.brows = HallwaysianBrows(length: 0.85, thickness: 0.28, lift: 1.08, shift: 0.1, tilt: 0.28)
        g.stride = 0.30; g.cadence = 1.5
        return HallwaysianPersona(
            id: "hw.oldgent", name: "Old Gent",
            blurb: "A stooped blue-grey gentleman with a walrus moustache. In no hurry, and never has been.",
            symbol: "mustache.fill", genome: g,
            posture: [.lid: 0.42, .low: 0.15, .smile: 0.2, .headRoll: 0.08, .shPitchL: 0.1, .shPitchR: 0.1, .elbowL: 0.45, .elbowR: 0.45,
                      .curlL: 0.7, .curlR: 0.7],
            gazeHead: 0.85, idles: [.sigh, .headTilt, .lookAround, .peer], species: .critter,
            arrivalDelay: 275, floors: [6: 1, 7: 1.5, 11: 1, 12: 1.5, 13: 1], stay: 150...330, changeFloor: 0.15,
            taste: ["Lamp": 3, "Seating": 3, "Aquarium": 2],
            hello: [(5, 0.14, 150, 135), (0, 0.18, 135, 115)], formant: 0.95, breath: 0.22)
    }

    static var lanky: HallwaysianPersona {
        var g = HallwaysianGenome(name: "Lanky")
        g.headRadii = SIMD3(0.135, 0.13, 0.13); g.headForward = 0.03; g.neckLength = 0.30; g.neckRadius = 0.011; g.neckLean = 0.22
        g.torsoRadii = SIMD3(0.085, 0.2, 0.08); g.torsoLean = 0; g.shoulderWidth = 0.088; g.shoulderDrop = 0.05
        g.hipWidth = 0.045; g.thigh = 0.29; g.shin = 0.3; g.legRadius = 0.0085; g.shinTip = 0.006; g.footLength = 0.14; g.footWidth = 0.042
        g.upperArm = 0.24; g.forearm = 0.23; g.armRadius = 0.0072; g.handRadius = 0.019; g.fingerLength = 0.05
        g.eyeRadius = 0.05; g.eyeSpacing = 0.05; g.eyeHeight = 0.03; g.eyeToe = 0.06; g.pupilSize = 0.42
        g.mouthWidth = 0.05; g.mouthHeight = -0.06
        g.enamel = rgb(0.45, 0.50, 0.28); g.enamelMetalness = 0.35; g.enamelRoughness = 0.5
        g.trim = rgb(0.18, 0.18, 0.18); g.trimMetalness = 0.5
        g.rubber = rgb(0.15, 0.15, 0.13)
        g.hair = HallwaysianStyle.slick; g.hairColor = rgb(0.11, 0.10, 0.09)
        g.stride = 0.62; g.cadence = 1.35
        return HallwaysianPersona(
            id: "hw.lanky", name: "Lanky",
            blurb: "Olive green and very tall, most of it neck. Shy; looks at you sideways.",
            symbol: "arrow.up.and.down", genome: g,
            posture: [.headRoll: -0.2, .smile: 0.05, .mouthW: 0.7, .lid: 0.25, .elbowL: 0.15, .elbowR: 0.15],
            gazeHead: 0.4, idles: [.stretch, .shrug, .lookAround, .peer], species: .chair,
            arrivalDelay: 320, floors: [5: 1, 7: 1, 8: 1, 14: 1.5, 15: 1, 16: 1], stay: 40...140, changeFloor: 0.5,
            taste: ["Copy": 2, "Desks": 2, "Water": 1.5],
            hello: [(3, 0.1, 200, 185), (1, 0.16, 185, 165)], formant: 1.0, breath: 0.08)
    }

    static var tiny: HallwaysianPersona {
        var g = HallwaysianGenome(name: "Tiny")
        g.headRadii = SIMD3(0.165, 0.15, 0.15); g.headForward = 0; g.neckLength = 0.035; g.neckLean = 0.05
        g.torsoRadii = SIMD3(0.075, 0.085, 0.07); g.torsoLean = 0; g.shoulderWidth = 0.07; g.shoulderDrop = 0.03
        g.hipWidth = 0.035; g.thigh = 0.08; g.shin = 0.085; g.legRadius = 0.008; g.shinTip = 0.0065
        g.footLength = 0.08; g.footWidth = 0.04; g.footHeight = 0.032
        g.upperArm = 0.085; g.forearm = 0.08; g.handRadius = 0.017; g.fingerLength = 0.03; g.jointRadius = 0.013
        g.eyeRadius = 0.074; g.eyeSpacing = 0.073; g.eyeHeight = 0.02; g.eyeToe = 0.16; g.pupilSize = 0.55
        g.mouthWidth = 0.05; g.mouthHeight = -0.075
        g.enamel = rgb(0.95, 0.47, 0.12); g.enamelRoughness = 0.4
        g.trim = rgb(0.85, 0.80, 0.70); g.trimMetalness = 0.3
        g.rubber = rgb(0.20, 0.30, 0.52)
        g.hair = HallwaysianStyle.sprout; g.hairColor = rgb(0.95, 0.47, 0.12)
        g.stride = 0.20; g.cadence = 3.0
        return HallwaysianPersona(
            id: "hw.tiny", name: "Tiny",
            blurb: "Small, orange and all eyes. Everything is new, and everything is amazing.",
            symbol: "star.fill", genome: g,
            posture: [.mouthO: 0.45, .mouthW: 0.7, .lid: -0.05, .headPitch: -0.1, .shRollL: 0.3, .shRollR: 0.3, .elbowL: 0.5, .elbowR: 0.5,
                      .curlL: 0.1, .curlR: 0.1],
            gazeHead: 0.8, idles: [.bounce, .lookAround, .headTilt, .bounce], species: .critter,
            arrivalDelay: 365, floors: [4: 1, 6: 1, 8: 1.5, 11: 1, 15: 1], stay: 30...100, changeFloor: 0.5,
            taste: ["Aquarium": 4, "Lamp": 2, "Break": 1.5],
            hello: [(2, 0.06, 430, 520), (2, 0.06, 520, 470), (4, 0.1, 470, 540)], formant: 1.4, breath: 0.06)
    }

    // MARK: Oct 19 -- the five newcomers (silhouettes first, then colour)

    /// Short and very wide: a hooped barrel on stumpy legs, a flat head sunk
    /// right into it, a handlebar moustache. Rust red, iron hoops.
    static var barrel: HallwaysianPersona {
        var g = HallwaysianGenome(name: "Barrel")
        g.headRadii = SIMD3(0.2, 0.11, 0.15); g.headForward = 0.02; g.neckLength = 0.012; g.neckRadius = 0.022; g.neckLean = 0.08
        g.torsoRadii = SIMD3(0.27, 0.16, 0.21); g.torsoLean = -0.03
        g.torsoPieces = [HallwaysianPiece(SIMD3(0, 0.52, 0), SIMD3(1.0, 0.1, 1.0)),          // iron hoops round the barrel
                         HallwaysianPiece(SIMD3(0, -0.52, 0), SIMD3(1.0, 0.1, 1.0))]
        g.torsoPieceColor = UIColor(red: 0.24, green: 0.21, blue: 0.19, alpha: 1)
        g.hipWidth = 0.11; g.thigh = 0.085; g.shin = 0.09; g.legRadius = 0.017; g.shinTip = 0.013
        g.footLength = 0.15; g.footWidth = 0.08; g.footHeight = 0.045
        g.shoulderWidth = 0.255; g.shoulderDrop = 0.1; g.upperArm = 0.1; g.forearm = 0.1; g.armRadius = 0.012
        g.handRadius = 0.026; g.jointRadius = 0.021
        g.eyeRadius = 0.046; g.eyeSpacing = 0.085; g.eyeHeight = 0.035; g.eyeSink = 0.45; g.eyeToe = 0.2; g.pupilSize = 0.5
        g.mouthWidth = 0.12; g.mouthHeight = -0.05
        g.enamel = rgb(0.62, 0.25, 0.16); g.enamelRoughness = 0.6
        g.trim = rgb(0.30, 0.27, 0.24); g.trimMetalness = 0.75; g.trimRoughness = 0.45
        g.rubber = rgb(0.16, 0.13, 0.12)
        g.moustache = HallwaysianStyle.handlebar; g.hairColor = rgb(0.16, 0.11, 0.08)
        g.brows = HallwaysianBrows(length: 0.95, thickness: 0.3, lift: 1.0, shift: 0.05, tilt: -0.1)
        g.stride = 0.22; g.cadence = 2.3
        return HallwaysianPersona(
            id: "hw.barrel", name: "Barrel",
            blurb: "Rust red, iron-hooped and nearly as wide as the hallway. Rolls along at his own steady pace.",
            symbol: "cylinder.fill", genome: g,
            posture: [.smile: 0.55, .mouthW: 1.2, .low: 0.3, .lid: 0.2, .shRollL: 0.5, .shRollR: 0.5, .elbowL: 0.4, .elbowR: 0.4],
            gazeHead: 0.45, idles: [.patBelly, .lookAround, .shrug, .rest], species: .critter,
            arrivalDelay: 410, floors: [4: 1, 5: 1.5, 9: 1, 12: 1, 14: 1], stay: 90...240, changeFloor: 0.25,
            taste: ["Break": 3, "Water": 2, "Seating": 2],
            hello: [(0, 0.1, 110, 125), (0, 0.1, 125, 105)], formant: 0.8, breath: 0.15)
    }

    /// Tall and thin, carrying an enormous round head with enormous eyes on a
    /// slim neck. Deep teal-navy with a brushed sheen, silver joints.
    static var owl: HallwaysianPersona {
        var g = HallwaysianGenome(name: "Owl")
        g.headRadii = SIMD3(0.25, 0.245, 0.235); g.headForward = 0.0; g.neckLength = 0.075; g.neckRadius = 0.014; g.neckLean = 0.1
        g.torsoRadii = SIMD3(0.09, 0.15, 0.085); g.torsoLean = 0; g.shoulderWidth = 0.085; g.shoulderDrop = 0.045
        g.hipWidth = 0.05; g.thigh = 0.25; g.shin = 0.26; g.legRadius = 0.009; g.footLength = 0.13; g.footWidth = 0.045
        g.upperArm = 0.19; g.forearm = 0.18; g.armRadius = 0.0075
        g.eyeRadius = 0.105; g.eyeSpacing = 0.112; g.eyeHeight = 0.04; g.eyeSink = 0.32; g.eyeToe = 0.12; g.pupilSize = 0.48
        g.mouthWidth = 0.05; g.mouthHeight = -0.12
        g.enamel = rgb(0.13, 0.29, 0.38); g.enamelMetalness = 0.35; g.enamelRoughness = 0.45
        g.trim = rgb(0.80, 0.82, 0.84); g.trimMetalness = 0.85; g.trimRoughness = 0.3
        g.rubber = rgb(0.10, 0.12, 0.16)
        g.brows = HallwaysianBrows(length: 0.7, thickness: 0.16, lift: 1.12, shift: 0.15, tilt: 0.12)
        g.browColor = rgb(0.80, 0.82, 0.84)
        g.stride = 0.5; g.cadence = 1.4
        return HallwaysianPersona(
            id: "hw.owl", name: "Owl",
            blurb: "A huge round head and the biggest eyes in the building, carried very carefully on a thin neck.",
            symbol: "eyes", genome: g,
            posture: [.lid: 0.1, .smile: 0.1, .mouthO: 0.15, .headRoll: 0.06, .elbowL: 0.1, .elbowR: 0.1],
            gazeHead: 0.9, idles: [.peer, .headTilt, .lookAround, .lookAtHand], species: .chair,
            arrivalDelay: 455, floors: [6: 1, 9: 1, 11: 1.5, 13: 1, 16: 1], stay: 50...160, changeFloor: 0.35,
            taste: ["Aquarium": 3, "Lamp": 2.5, "Server": 1.5],
            hello: [(4, 0.12, 300, 340), (4, 0.18, 340, 260)], formant: 1.15, breath: 0.1)
    }

    /// Tiny and stooped, leaning well forward from the hips, small half-closed
    /// eyes, a grey bun and a long skirt. Dusty rose.
    static var auntie: HallwaysianPersona {
        var g = HallwaysianGenome(name: "Auntie")
        g.headRadii = SIMD3(0.12, 0.115, 0.115); g.headForward = 0.03; g.neckLength = 0.05; g.neckLean = 0.6
        g.torsoRadii = SIMD3(0.085, 0.1, 0.08); g.torsoLean = 0.36; g.shoulderWidth = 0.075; g.shoulderDrop = 0.035
        g.hipWidth = 0.04; g.thigh = 0.11; g.shin = 0.115; g.legRadius = 0.0075; g.shinTip = 0.006
        g.footLength = 0.085; g.footWidth = 0.038; g.footHeight = 0.032
        g.upperArm = 0.1; g.forearm = 0.095; g.handRadius = 0.016; g.fingerLength = 0.032; g.jointRadius = 0.012
        g.eyeRadius = 0.04; g.eyeSpacing = 0.047; g.eyeHeight = 0.03; g.eyeSink = 0.45; g.eyeToe = 0.08; g.pupilSize = 0.5
        g.mouthWidth = 0.045; g.mouthHeight = -0.055
        g.enamel = rgb(0.74, 0.52, 0.56); g.enamelRoughness = 0.7
        g.trim = rgb(0.86, 0.80, 0.66); g.trimMetalness = 0.5
        g.rubber = rgb(0.30, 0.22, 0.24)
        g.hair = HallwaysianStyle.bobBun; g.hairColor = rgb(0.80, 0.80, 0.80); g.hairRoughness = 0.9
        g.skirt = HallwaysianSkirt(waist: 0.2, length: 0.17, flare: 1.45, pleats: 14)
        g.skirtColor = rgb(0.38, 0.30, 0.42)
        g.stride = 0.16; g.cadence = 2.2
        return HallwaysianPersona(
            id: "hw.auntie", name: "Auntie",
            blurb: "Very small and bent with years, dusty rose with a silver bun. Takes the long way, and enjoys it.",
            symbol: "cup.and.saucer.fill", genome: g,
            posture: [.lid: 0.45, .smile: 0.45, .low: 0.3, .headPitch: -0.2, .shPitchL: 0.2, .shPitchR: 0.2, .elbowL: 0.9, .elbowR: 0.9,
                      .curlL: 0.6, .curlR: 0.6],
            gazeHead: 0.85, idles: [.sigh, .tidyHair, .headTilt, .handsToChest], species: .critter,
            arrivalDelay: 500, floors: [4: 1.5, 6: 1, 7: 1, 12: 1.5], stay: 150...330, changeFloor: 0.15,
            taste: ["Seating": 3, "Aquarium": 2.5, "Break": 2],
            hello: [(1, 0.1, 280, 300), (5, 0.16, 300, 250)], formant: 1.2, breath: 0.2)
    }

    /// Pear-shaped: a small head on narrow shoulders over a big round bottom,
    /// with short little arms. Lavender, gold trim.
    static var pear: HallwaysianPersona {
        var g = HallwaysianGenome(name: "Pear")
        g.headRadii = SIMD3(0.115, 0.115, 0.11); g.headForward = 0.01; g.neckLength = 0.05; g.neckLean = 0.15
        g.torsoRadii = SIMD3(0.095, 0.17, 0.09); g.torsoLean = -0.04
        g.torsoPieces = [HallwaysianPiece(SIMD3(0, -0.5, 0.05), SIMD3(2.0, 0.78, 1.95))]      // the big round bottom
        g.hipWidth = 0.075; g.thigh = 0.13; g.shin = 0.135; g.legRadius = 0.011
        g.footLength = 0.12; g.footWidth = 0.055
        g.shoulderWidth = 0.088; g.shoulderDrop = 0.035; g.upperArm = 0.075; g.forearm = 0.07; g.handRadius = 0.019; g.fingerLength = 0.03
        g.eyeRadius = 0.05; g.eyeSpacing = 0.05; g.eyeHeight = 0.025; g.eyeToe = 0.1; g.pupilSize = 0.55
        g.mouthWidth = 0.05; g.mouthHeight = -0.06
        g.enamel = rgb(0.64, 0.54, 0.80); g.enamelRoughness = 0.5
        g.trim = rgb(0.84, 0.68, 0.32); g.trimMetalness = 0.6
        g.rubber = rgb(0.26, 0.20, 0.34)
        g.hair = HallwaysianStyle.sprout; g.hairColor = rgb(0.36, 0.56, 0.30)                  // (a stalk)
        g.stride = 0.26; g.cadence = 2.0
        return HallwaysianPersona(
            id: "hw.pear", name: "Pear",
            blurb: "Lavender, narrow on top and very round below, with short arms that never quite reach. Waddles happily.",
            symbol: "drop.fill", genome: g,
            posture: [.smile: 0.7, .mouthW: 0.85, .lid: 0.1, .shRollL: 0.7, .shRollR: 0.7, .elbowL: 0.3, .elbowR: 0.3],
            gazeHead: 0.7, idles: [.bounce, .patBelly, .headTilt, .lookAround], species: .critter,
            arrivalDelay: 545, floors: [5: 1, 8: 1.5, 10: 1, 13: 1, 15: 1], stay: 60...180, changeFloor: 0.35,
            taste: ["Break": 3, "Water": 2, "Copy": 1.5],
            hello: [(3, 0.08, 260, 300), (2, 0.12, 300, 270)], formant: 1.1, breath: 0.1)
    }

    /// Broad shoulders over a narrow waist, long arms, and enormous copper hands
    /// that dangle almost to his knees. Graphite, crew cut.
    static var mitts: HallwaysianPersona {
        var g = HallwaysianGenome(name: "Mitts")
        g.headRadii = SIMD3(0.13, 0.12, 0.125); g.headForward = 0.02; g.neckLength = 0.06; g.neckRadius = 0.017; g.neckLean = 0.18
        g.torsoRadii = SIMD3(0.08, 0.18, 0.075); g.torsoLean = 0.02
        g.torsoPieces = [HallwaysianPiece(SIMD3(0, 0.6, 0), SIMD3(2.5, 0.42, 1.35))]          // the shoulder yoke
        g.shoulderWidth = 0.205; g.shoulderDrop = 0.075
        g.hipWidth = 0.045; g.thigh = 0.22; g.shin = 0.22; g.legRadius = 0.0105
        g.upperArm = 0.24; g.forearm = 0.24; g.armRadius = 0.0095
        g.handRadius = 0.042; g.fingerLength = 0.075; g.fingerRadius = 0.0095; g.jointRadius = 0.02
        g.eyeRadius = 0.048; g.eyeSpacing = 0.055; g.eyeHeight = 0.03; g.eyeSink = 0.4; g.pupilSize = 0.42
        g.mouthWidth = 0.065; g.mouthHeight = -0.06
        g.enamel = rgb(0.27, 0.28, 0.31); g.enamelMetalness = 0.3; g.enamelRoughness = 0.5
        g.trim = rgb(0.80, 0.46, 0.26); g.trimMetalness = 0.8; g.trimRoughness = 0.3
        g.rubber = rgb(0.12, 0.12, 0.13)
        g.hair = HallwaysianStyle.crew; g.hairColor = rgb(0.12, 0.11, 0.10)
        g.stride = 0.46; g.cadence = 1.6
        return HallwaysianPersona(
            id: "hw.mitts", name: "Mitts",
            blurb: "Graphite, broad in the shoulder and narrow in the waist, with long arms and huge copper hands.",
            symbol: "hand.raised.fill", genome: g,
            posture: [.lid: 0.2, .smile: 0.25, .headPitch: 0.04, .shRollL: 0.08, .shRollR: 0.08, .elbowL: 0.12, .elbowR: 0.12,
                      .curlL: 0.45, .curlR: 0.45],
            gazeHead: 0.6, idles: [.shrug, .stretch, .lookAtHand, .lookAround], species: .chair,
            arrivalDelay: 590, floors: [5: 1, 7: 1, 10: 1.5, 14: 1, 16: 1], stay: 50...170, changeFloor: 0.4,
            taste: ["Server": 2, "Desks": 2.5, "Copy": 2],
            hello: [(0, 0.1, 170, 190), (3, 0.14, 190, 160)], formant: 0.92, breath: 0.12)
    }

    // MARK: Oct 19 -- five more (sixteen in all)

    /// Very tall and skinny on stilt legs, with a tiny head (no neck to speak of).
    /// Ivory with black joints; a long, slow, careful stride.
    static var stilts: HallwaysianPersona {
        var g = HallwaysianGenome(name: "Stilts")
        g.headRadii = SIMD3(0.085, 0.085, 0.082); g.headForward = 0.01; g.neckLength = 0.1; g.neckRadius = 0.01; g.neckLean = 0.12
        g.torsoRadii = SIMD3(0.075, 0.22, 0.068); g.torsoLean = 0.02; g.shoulderWidth = 0.08; g.shoulderDrop = 0.04
        g.hipWidth = 0.042; g.thigh = 0.45; g.shin = 0.46; g.legRadius = 0.008; g.shinTip = 0.005
        g.footLength = 0.12; g.footWidth = 0.036
        g.upperArm = 0.22; g.forearm = 0.21; g.armRadius = 0.0065; g.handRadius = 0.017; g.fingerLength = 0.045; g.jointRadius = 0.014
        g.eyeRadius = 0.033; g.eyeSpacing = 0.034; g.eyeHeight = 0.02; g.eyeSink = 0.3; g.eyeToe = 0.12; g.pupilSize = 0.5
        g.mouthWidth = 0.03; g.mouthHeight = -0.038; g.mouthWire = 0.003
        g.enamel = rgb(0.90, 0.86, 0.74); g.enamelRoughness = 0.35
        g.trim = rgb(0.10, 0.10, 0.11); g.trimMetalness = 0.6; g.trimRoughness = 0.3
        g.rubber = rgb(0.12, 0.12, 0.12)
        g.stride = 0.7; g.cadence = 1.25
        return HallwaysianPersona(
            id: "hw.stilts", name: "Stilts",
            blurb: "Ivory, the tallest in the building, and nearly all leg -- with a head no bigger than a doorknob.",
            symbol: "ruler.fill", genome: g,
            posture: [.headPitch: 0.12, .lid: 0.15, .smile: 0.2, .elbowL: 0.1, .elbowR: 0.1, .curlL: 0.3, .curlR: 0.3],
            gazeHead: 0.9, idles: [.peer, .stretch, .lookAround, .headTilt], species: .chair,
            arrivalDelay: 625, floors: [7: 1, 9: 1, 13: 1, 15: 1.5, 16: 1], stay: 50...160, changeFloor: 0.4,
            taste: ["Lamp": 2, "Desks": 2, "Copy": 1.5],
            hello: [(1, 0.06, 420, 470), (1, 0.12, 470, 410)], formant: 1.35, breath: 0.06)
    }

    /// Round as a ball on short legs, with enormous hands that hang almost to
    /// the floor. Kelly green, dark brass knuckles; a heavy, rolling walk.
    static var clunk: HallwaysianPersona {
        var g = HallwaysianGenome(name: "Clunk")
        g.headRadii = SIMD3(0.135, 0.115, 0.125); g.headForward = 0.02; g.neckLength = 0.02; g.neckRadius = 0.02; g.neckLean = 0.1
        g.torsoRadii = SIMD3(0.19, 0.18, 0.18); g.torsoLean = -0.02
        g.hipWidth = 0.075; g.thigh = 0.095; g.shin = 0.1; g.legRadius = 0.014; g.shinTip = 0.011
        g.footLength = 0.13; g.footWidth = 0.06; g.footHeight = 0.042
        g.shoulderWidth = 0.19; g.shoulderDrop = 0.06; g.upperArm = 0.13; g.forearm = 0.13; g.armRadius = 0.011
        g.handRadius = 0.058; g.fingerLength = 0.07; g.fingerRadius = 0.014; g.jointRadius = 0.022
        g.eyeRadius = 0.047; g.eyeSpacing = 0.06; g.eyeHeight = 0.035; g.eyeSink = 0.4; g.pupilSize = 0.52
        g.mouthWidth = 0.085; g.mouthHeight = -0.048
        g.enamel = rgb(0.30, 0.62, 0.30); g.enamelRoughness = 0.55
        g.trim = rgb(0.55, 0.42, 0.20); g.trimMetalness = 0.7; g.trimRoughness = 0.4
        g.rubber = rgb(0.18, 0.16, 0.12)
        g.brows = HallwaysianBrows(length: 0.9, thickness: 0.26, lift: 1.05, shift: 0.05, tilt: -0.15)
        g.browColor = rgb(0.16, 0.30, 0.16)
        g.stride = 0.25; g.cadence = 2.2
        return HallwaysianPersona(
            id: "hw.clunk", name: "Clunk",
            blurb: "Kelly green and round as a ball, with hands far too big for the rest of him. Gentle with everything he touches.",
            symbol: "hands.clap.fill", genome: g,
            posture: [.smile: 0.6, .mouthW: 1.1, .low: 0.3, .lid: 0.2, .shRollL: 0.35, .shRollR: 0.35, .curlL: 0.55, .curlR: 0.55],
            gazeHead: 0.5, idles: [.lookAtHand, .patBelly, .shrug, .lookAround], species: .critter,
            arrivalDelay: 660, floors: [4: 1, 8: 1, 10: 1.5, 12: 1, 14: 1], stay: 80...220, changeFloor: 0.25,
            taste: ["Copy": 2.5, "Break": 2, "Water": 2],
            hello: [(0, 0.12, 105, 120), (5, 0.12, 120, 95)], formant: 0.78, breath: 0.16)
    }

    /// Top-heavy: a great rounded chest over a narrow waist, thin legs and tiny
    /// feet -- always about to tip forward, never quite. Royal blue, gold trim.
    static var topper: HallwaysianPersona {
        var g = HallwaysianGenome(name: "Topper")
        g.headRadii = SIMD3(0.16, 0.14, 0.15); g.headForward = 0.03; g.neckLength = 0.12; g.neckRadius = 0.016; g.neckLean = 0.15
        g.torsoRadii = SIMD3(0.075, 0.12, 0.07); g.torsoLean = 0.06
        g.torsoPieces = [HallwaysianPiece(SIMD3(0, 0.55, 0.02), SIMD3(3.0, 1.1, 2.4))]           // the big chest
        g.shoulderWidth = 0.235; g.shoulderDrop = 0.05
        g.hipWidth = 0.04; g.thigh = 0.2; g.shin = 0.21; g.legRadius = 0.0075; g.shinTip = 0.005
        g.footLength = 0.05; g.footWidth = 0.028; g.footHeight = 0.03
        g.upperArm = 0.14; g.forearm = 0.13; g.armRadius = 0.0095; g.handRadius = 0.024
        g.eyeRadius = 0.058; g.eyeSpacing = 0.066; g.eyeHeight = 0.04; g.pupilSize = 0.46
        g.mouthWidth = 0.08; g.mouthHeight = -0.055
        g.enamel = rgb(0.20, 0.36, 0.78); g.enamelRoughness = 0.4; g.enamelMetalness = 0.15
        g.trim = rgb(0.92, 0.82, 0.52); g.trimMetalness = 0.7; g.trimRoughness = 0.3
        g.rubber = rgb(0.10, 0.12, 0.25)
        g.hair = HallwaysianStyle.slick; g.hairColor = rgb(0.10, 0.10, 0.16)
        g.stride = 0.34; g.cadence = 1.9
        return HallwaysianPersona(
            id: "hw.topper", name: "Topper",
            blurb: "Royal blue, chest out, on thin legs and the smallest feet in the building. Walks as if leading a parade.",
            symbol: "triangle.fill", genome: g,
            posture: [.headPitch: -0.08, .smile: 0.45, .lid: 0.1, .shRollL: 0.25, .shRollR: 0.25, .elbowL: 0.5, .elbowR: 0.5,
                      .curlL: 0.6, .curlR: 0.6],
            gazeHead: 0.65, idles: [.handsToChest, .lookAround, .wave, .headTilt], species: .chair,
            arrivalDelay: 695, floors: [5: 1, 6: 1, 9: 1.5, 11: 1, 15: 1], stay: 60...180, changeFloor: 0.35,
            taste: ["Seating": 2, "Desks": 2, "Server": 1.5],
            hello: [(2, 0.08, 210, 260), (0, 0.16, 260, 220)], formant: 1.0, breath: 0.1)
    }

    /// A compact little body on short legs under a very long, forward-reaching
    /// neck; a wide flat head with its eyes set far apart, looking both ways at
    /// once. Fuchsia, silver trim.
    static var scope: HallwaysianPersona {
        var g = HallwaysianGenome(name: "Scope")
        g.headRadii = SIMD3(0.15, 0.1, 0.12); g.headForward = 0.04; g.neckLength = 0.34; g.neckRadius = 0.012; g.neckLean = 0.35
        g.torsoRadii = SIMD3(0.09, 0.09, 0.085); g.torsoLean = 0.02; g.shoulderWidth = 0.08; g.shoulderDrop = 0.03
        g.hipWidth = 0.045; g.thigh = 0.1; g.shin = 0.1; g.legRadius = 0.009; g.footLength = 0.09; g.footWidth = 0.04
        g.upperArm = 0.09; g.forearm = 0.085; g.handRadius = 0.017; g.fingerLength = 0.032; g.jointRadius = 0.013
        g.eyeRadius = 0.045; g.eyeSpacing = 0.13; g.eyeHeight = 0.02; g.eyeSink = 0.4; g.eyeToe = 0.45; g.pupilSize = 0.5
        g.mouthWidth = 0.09; g.mouthHeight = -0.045
        g.enamel = rgb(0.78, 0.25, 0.55); g.enamelRoughness = 0.45
        g.trim = rgb(0.80, 0.80, 0.82); g.trimMetalness = 0.8; g.trimRoughness = 0.3
        g.rubber = rgb(0.25, 0.10, 0.20)
        g.stride = 0.32; g.cadence = 1.95
        return HallwaysianPersona(
            id: "hw.scope", name: "Scope",
            blurb: "Fuchsia, mostly neck, with eyes so far apart she sees round corners. Gets there head first.",
            symbol: "binoculars.fill", genome: g,
            posture: [.neckPitch: -0.08, .smile: 0.3, .mouthW: 1.1, .lid: 0.12, .elbowL: 0.4, .elbowR: 0.4],
            gazeHead: 0.95, idles: [.lookAround, .peer, .headTilt, .lookAround], species: .critter,
            arrivalDelay: 730, floors: [4: 1, 6: 1, 8: 1, 11: 1.5, 13: 1], stay: 40...130, changeFloor: 0.45,
            taste: ["Aquarium": 3, "Water": 2, "Lamp": 1.5],
            hello: [(3, 0.1, 330, 280), (3, 0.1, 280, 340)], formant: 1.18, breath: 0.08)
    }

    /// Small and lopsided: one shoulder well above the other, one eye bigger,
    /// a tuft of hair off to the side and a permanent tilt of the head. Sky blue.
    static var lopsy: HallwaysianPersona {
        var g = HallwaysianGenome(name: "Lopsy")
        g.headRadii = SIMD3(0.13, 0.12, 0.125); g.headForward = 0.02; g.neckLength = 0.06; g.neckLean = 0.3
        g.torsoRadii = SIMD3(0.09, 0.11, 0.085); g.torsoLean = 0.08; g.shoulderWidth = 0.088; g.shoulderDrop = 0.035
        g.shoulderTilt = 0.04
        g.hipWidth = 0.045; g.thigh = 0.12; g.shin = 0.125; g.footLength = 0.1; g.footWidth = 0.045
        g.upperArm = 0.1; g.forearm = 0.095; g.handRadius = 0.019; g.fingerLength = 0.034
        g.eyeRadius = 0.052; g.eyeSpacing = 0.058; g.eyeHeight = 0.03; g.eyeSkew = 0.28; g.eyeToe = 0.12; g.pupilSize = 0.5
        g.mouthWidth = 0.06; g.mouthHeight = -0.06
        g.enamel = rgb(0.50, 0.74, 0.90); g.enamelRoughness = 0.5
        g.trim = rgb(0.62, 0.62, 0.64); g.trimMetalness = 0.6
        g.rubber = rgb(0.32, 0.20, 0.16)
        g.hair = [HallwaysianPiece(SIMD3(0.42, 0.95, 0.1), SIMD3(0.32, 0.36, 0.3), SIMD3(0, 0, -0.55)),     // one tuft, to the side
                  HallwaysianPiece(SIMD3(0.62, 1.18, 0.1), SIMD3(0.15, 0.15, 0.15))]
        g.hairColor = rgb(0.85, 0.55, 0.22)
        g.stride = 0.19; g.cadence = 2.7
        return HallwaysianPersona(
            id: "hw.lopsy", name: "Lopsy",
            blurb: "Small, sky blue and gloriously lopsided -- one shoulder up, one eye bigger, head always cocked. Hurries everywhere.",
            symbol: "scribble", genome: g,
            posture: [.headRoll: 0.24, .lidL: -0.05, .lidR: 0.25, .smile: 0.4, .mouthW: 0.8, .shRollL: 0.3, .shRollR: 0.05,
                      .elbowL: 0.6, .elbowR: 0.15, .sway: 0.05],
            gazeHead: 0.75, idles: [.headTilt, .bounce, .shrug, .lookAround], species: .critter,
            arrivalDelay: 765, floors: [5: 1, 7: 1.5, 10: 1, 12: 1, 16: 1], stay: 30...110, changeFloor: 0.5,
            taste: ["Break": 2, "Aquarium": 2, "Copy": 2],
            hello: [(2, 0.06, 360, 420), (5, 0.08, 300, 330), (2, 0.1, 420, 380)], formant: 1.28, breath: 0.07)
    }

    static func persona(_ id: String) -> HallwaysianPersona? { all.first { $0.id == id } }
    static var ids: [String] { all.map(\.id) }

    /// One kind per persona, registered with BuildingLife.
    static var kinds: [ResidentKind] { all.map { HallwaysianResidentKind($0) } }

    /// Their Contacts entries (met the usual way: near the player).
    static var identities: [CharacterIdentity] {
        all.map { p in
            // Oct 22 (musical identities): the six's song names and signatures while the experiment is on
            // (both sounds are always prepared, so a preview is never silent whichever is chosen).
            CharacterIdentity(id: p.id, name: HallwaysianMusic.displayName(p.id, original: p.name), blurb: p.blurb, symbol: p.symbol, tint: p.tint,
                              preview: [(HallwaysianMusic.isOn && HallwaysianMusic.signature(p.id) != nil
                                         ? HallwaysianMusic.soundName(p.id) : HallwaysianVoice.soundName(p.id), 0)],
                              prepareSounds: { _ = HallwaysianVoice.original(p); _ = HallwaysianMusic.source(p.id) },
                              body: { BuildingLife.shared.presentations.first { $0.residentID == p.id }?.bodyNode })
        }
    }

    // MARK: Oct 19 (later): their front-door arrival, once more, on a save that already had them

    /// Set once the six have been given their (quick) front-door arrival on this save.
    static let frontDoorArrivalKey = "hallwaysians.frontDoorArrival.v2"

    /// The first build of the six scheduled an existing save's arrivals 2-6 minutes
    /// after launch and then scattered them to rooms on floors 4-16 -- easy to miss
    /// entirely. Once per save: any of their records already there go back to the
    /// street, to come in at the front door `joinDelay` from now (as a save that
    /// never had them does). Never again after that; never under tests' own storage
    /// unless that storage is persisted (then once, like a real save).
    @discardableResult
    static func rearriveIfNeeded(_ list: inout [Resident], defaults: UserDefaults, persists: Bool, now: Date) -> [String] {
        guard persists, !defaults.bool(forKey: frontDoorArrivalKey) else { return [] }
        defaults.set(true, forKey: frontDoorArrivalKey)
        var reset: [String] = []
        for i in list.indices {
            guard let p = persona(list[i].id) else { continue }
            var r = Resident(id: p.id, kind: p.kind, floor: ResidentPolicy.lobbyFloor, cell: nil,
                             since: now.addingTimeInterval(p.joinDelay), dwell: 0)
            r.moves = list[i].moves
            list[i] = r
            reset.append(p.id)
        }
        return reset
    }

    // MARK: Debug: all six near the player (once a run)

    /// `-HallwaysHallwaysiansNear YES` (DEBUG runs only).
    static var nearRequested: Bool {
        #if DEBUG
        return !ResumeState.runningUnderTests && UserDefaults.standard.bool(forKey: "HallwaysHallwaysiansNear")
        #else
        return false
        #endif
    }
    private static var gathered = false

    /// On the first open floor built this run (the building open, not Floor 2):
    /// the six set down in hallway cells 2-6 steps from the player, a little
    /// apart, each to stand a few seconds and then go about his life.
    static func gatherIfAsked(life: BuildingLife, floor: Int, playerCell given: GridCoordinate, plan: FloorPlan) {
        guard nearRequested, !gathered, ResidentPolicy.buildingOpen, !ResidentPolicy.closedFloors.contains(floor) else { return }
        gathered = true
        let playerCell = plan.cells.contains(given) ? given : (plan.elevator ?? given)
        let roomCells = plan.rooms.reduce(into: Set<GridCoordinate>()) { $0.formUnion($1.cells) }
        let near = plan.cells.subtracting(roomCells)
            .filter { $0 != plan.elevator && $0 != playerCell && !plan.furnished.contains($0) }
            .compactMap { c -> (GridCoordinate, Int)? in
                guard let route = plan.route(from: playerCell, to: c) else { return nil }
                return (c, route.count - 1)
            }
            .sorted { ($0.1, $0.0.row, $0.0.col) < ($1.1, $1.0.row, $1.0.col) }
        let now = BuildingClock.now()
        var taken: [GridCoordinate] = []
        for (i, p) in all.enumerated() {
            guard var r = life.resident(p.id) else { continue }
            let pick = near.first { c, d in d >= 2 && d <= 6 && !taken.contains(c) && !taken.contains { abs($0.row - c.row) + abs($0.col - c.col) < 2 } }?.0
                ?? near.first { c, _ in !taken.contains(c) }?.0
            guard let cell = pick else {
                LifeLog.warn(p.id, "hallwaysians.notPlaced", floor: floor, ["why": "no open hallway cell near the player"])
                continue
            }
            taken.append(cell)
            r.floor = floor
            r.cell = cell
            r.leg = nil
            r.shown = nil
            r.room = nil
            r.roomName = nil
            r.since = now
            r.dwell = 8 + Double(i) * 3
            r.why = "debug: placed near you (-HallwaysHallwaysiansNear)"
            life.store(r)
            LifeLog.event(p.id, "hallwaysians.placedNear", floor: floor, ["cell": LifeLog.cell(cell), "player": LifeLog.cell(playerCell)])
        }
    }
}

// MARK: - The kind (one per persona; all the same code)

final class HallwaysianResidentKind: ResidentKind {
    let persona: HallwaysianPersona
    let kind: String
    let abilities: Set<ResidentAbility> = [.walk, .rideElevator]

    init(_ persona: HallwaysianPersona) {
        self.persona = persona
        kind = persona.kind
    }

    var style: RoamStyle { BuildingLife.pacing(normal: persona.style, fast: persona.fastStyle) }

    /// Not in the building yet: in at the lobby entrance at its time. (Building
    /// already open -- an existing save: soon, `joinDelay` from now. Not open yet --
    /// a new game: held, then `arrivalDelay` after the opening; see advance.)
    func newcomers(now: Date) -> [Resident] {
        [Resident(id: persona.id, kind: kind, floor: ResidentPolicy.lobbyFloor, cell: nil,
                  since: now.addingTimeInterval(persona.joinDelay), dwell: 0)]
    }

    func advance(_ r: inout Resident, to now: Date, plans: (Int) -> FloorPlan?) {
        if ResidentRoster.holdArrival(&r, delay: persona.arrivalDelay, open: ResidentPolicy.buildingOpen, now: now) { return }
        let outside = r.cell == nil && r.floor == ResidentPolicy.lobbyFloor
        Roam.advance(&r, style: style, abilities: abilities, plans: plans, to: now)
        if outside, let leg = r.leg, leg.from.floor == ResidentPolicy.lobbyFloor {
            LifeLog.pop(r.id, "lobby.entry", floor: leg.from.floor,
                        ["entrance": LifeLog.cell(leg.from.cell), "destination": "F\(r.floor) \(r.roomName ?? "?") \(LifeLog.cell(r.cell))",
                         "why": r.why])
        }
    }

    func present(_ id: String, on stage: FloorStage) -> ResidentPresentation? {
        guard Admission.isCompleted, !Admission.isQuietOnboarding(floor: stage.floor), let context = stage.context,
              let root = stage.root, let controller = stage.controller else { return nil }
        let p = persona
        return RoamPresentation(residentID: id, floor: stage.floor, root: root, controller: controller, context: context,
                                style: style, abilities: abilities) {
            HallwaysianResidentBody(persona: p, context: context)
        }
    }
}

// MARK: - The body

final class HallwaysianResidentBody: RoamerBody {
    /// Oct 20: the roaming Hallwaysians are a fifth bigger than as designed (the whole figure, proportions kept).
    static let sizeScale: Float = 1.2
    let persona: HallwaysianPersona
    let figure: HallwaysianBody
    var root: SCNNode { figure.root }
    /// Its walking pace now (m/s): its own -- or, guiding the player, the guide's.
    var speed: Float { guidePace ?? persona.pace }
    private var guidePace: Float?
    var diagnosticID = "hallwaysian"
    var activitySpecies: ResidentActivities.Species { persona.species }

    private var motor: HallwaysianMotor
    private let context: CharacterLead.Context
    private var path: [SIMD2<Float>] = []
    private var walkingTo: SIMD2<Float>?
    private var arrival: (() -> Void)?
    private var gesture: (g: HallwaysianGesture, start: Double, look: SIMD3<Float>?)?
    private var glance: (point: SIMD3<Float>, until: Double)?
    private var gesturing = false
    private var touchToken = 0
    private var lastFrame: CFTimeInterval?
    private var clock: Double = 0
    private var greetedAt: Double = -999
    /// Oct 20: acknowledging a follower until then (its idles and activity beats wait).
    private var acknowledgingUntil: Double = -1
    private var nextSightCheck: Double = 0
    private var playerSeen = false

    init(persona: HallwaysianPersona, context: CharacterLead.Context) {
        self.persona = persona
        self.context = context
        let body = HallwaysianBody(genome: persona.genome)
        body.root.name = "resident.\(persona.id)"
        body.root.scale = SCNVector3(Self.sizeScale, Self.sizeScale, Self.sizeScale)   // (Oct 20: 1.2x -- the pose sets only position and yaw)
        figure = body
        motor = HallwaysianMotor(genome: persona.genome, seed: persona.id.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) })
        HallwaysianDriver.shared.add(self)
    }

    // MARK: Where

    var groundPosition: SIMD2<Float>? { root.parent != nil ? here : nil }
    private var here: SIMD2<Float> { SIMD2(motor.pose[.x], motor.pose[.z]) }
    var heading: Float { motor.pose[.yaw] }
    var isGesturing: Bool { gesturing }
    var isMoving: Bool { !path.isEmpty }
    var isStepping: Bool { false }                  // (no footstep loop: his steps are silent for now)

    func place(at p: SIMD2<Float>, heading: Float) {
        path = []
        walkingTo = nil
        arrival = nil
        motor.place(x: p.x, z: p.y, yaw: heading)
        figure.apply(motor.pose)
    }

    /// Oct 20 (night): brisk while guiding (GuidePace), its legs matched; nil: its own gait.
    func setGuidePace(_ mps: Float?) {
        guidePace = mps.map { max($0, persona.pace) }
        let g = mps == nil ? (stride: Float(1), cadence: Float(1)) : GuidePace.gait(normalPace: persona.pace)
        motor.setGait(stride: g.stride, cadence: g.cadence)
    }

    func halt() {
        path = []
        walkingTo = nil
        arrival = nil
        motor.stop()
        gesture = nil
        gesturing = false
        touchToken += 1
    }

    // MARK: Walking: the waypoints become the motor's goals, one by one

    func travel(_ points: [SIMD2<Float>], then: @escaping () -> Void) {
        var list: [SIMD2<Float>] = []
        var last = here
        for p in points where simd_distance(p, last) > 0.05 { list.append(p); last = p }
        guard !list.isEmpty else { DispatchQueue.main.async { then() }; return }
        path = list
        walkingTo = nil
        arrival = then
        gesture = nil
    }

    private func followPath() {
        guard let target = path.first else { return }
        // Through a waypoint without stopping when there's another after it (a gentle turn).
        if path.count > 1, simd_distance(here, target) < 0.3 {
            path.removeFirst()
            walkingTo = path[0]
            motor.walk(to: path[0])
            return
        }
        if walkingTo != target {
            walkingTo = target
            motor.walk(to: target)
        } else if motor.goal == nil {                    // (the motor is on the mark)
            path.removeFirst()
            walkingTo = nil
            if path.isEmpty, let done = arrival {
                arrival = nil
                DispatchQueue.main.async { done() }
            }
        }
    }

    // MARK: The frame (HallwaysianDriver, main thread)

    func frame(at t: CFTimeInterval) {
        guard root.parent != nil else { lastFrame = nil; return }
        let dt = lastFrame.map { min(0.1, t - $0) } ?? 0
        lastFrame = t
        clock += dt
        followPath()
        let player = context.playerPose()
        let playerHead = player.map { SIMD3<Float>($0.position.x, 1.55, $0.position.y) }
        if clock >= nextSightCheck {
            nextSightCheck = clock + 0.5
            playerSeen = player.map { sees($0.position) && simd_distance($0.position, here) < 4.5 } ?? false
        }
        // A hello: standing, you close and in view, not lately.
        // Oct 22 (musical building): with the musical identities on, only when the building's
        // conductor allows (one signature at a time, never during a story); it tries again later.
        if playerSeen, path.isEmpty, gesture == nil, !gesturing, let p = player, simd_distance(p.position, here) < 3.2,
           clock - greetedAt > 75, !HallwaysianMusic.isOn || ResidentMusicConductor.shared.mayGreet(persona.id) {
            greetedAt = clock
            begin(.wave)
            if !ResidentMusic.greet(persona.id, on: root), let source = HallwaysianVoice.original(persona) {
                CritterAudio.play(source, on: root)
            }
            LifeLog.event(persona.id, "hallwaysian.hello", ["distance": simd_distance(p.position, here)])
        }
        var o = HallwaysianOverlay()
        o.targets = persona.posture
        o.gazeHead = persona.gazeHead
        o.gaze = .ahead
        if let gs = gesture {
            let u = clock - gs.start
            if u > gs.g.duration {
                gesture = nil
            } else {
                for (c, v) in gs.g.set { o.targets[c] = v }
                if let sw = gs.g.swing {
                    o.targets[sw.channel] = (o.targets[sw.channel] ?? sw.channel.rest) + sw.amplitude * sin(2 * .pi * sw.hz * Float(u))
                }
                if let look = gs.look { o.gaze = .point(look) }
            }
        }
        if path.isEmpty {
            if let g = glance, clock < g.until { o.gaze = .point(g.point) }
            else if gesture?.look == nil, playerSeen, let h = playerHead { o.gaze = .point(h) }
        } else if playerSeen, let h = playerHead, let p = player, simd_distance(p.position, here) < 2.5 {
            o.gaze = .point(h)                                       // (a look at you in passing)
            o.gazeHead = persona.gazeHead * 0.5
        }
        _ = motor.update(dt: dt, overlay: o, camera: playerHead ?? SIMD3(here.x, 1.5, here.y - 3))
        figure.apply(motor.pose)
    }

    private func sees(_ p: SIMD2<Float>) -> Bool {
        let s = context.cellSize
        func cell(_ q: SIMD2<Float>) -> GridCoordinate { GridCoordinate(row: Int((q.y / s).rounded()), col: Int((q.x / s).rounded())) }
        return CritterSight.connected(cell(here), cell(p), cells: context.cells, doors: context.doors, isOpen: context.isDoorOpen)
    }

    private func begin(_ g: HallwaysianGesture, lookAt world: SIMD3<Float>? = nil) {
        var look = world
        if look == nil, let rel = g.look {
            let yaw = heading
            let fwd = SIMD2<Float>(-sin(yaw), -cos(yaw)), right = SIMD2<Float>(cos(yaw), -sin(yaw))
            let at = here + fwd * rel.z + right * rel.x
            look = SIMD3(at.x, motor.headHeight + rel.y, at.y)
        }
        if g.name == HallwaysianGesture.lookAround.name {
            let a = Float.random(in: 0..<(2 * .pi))
            look = SIMD3(here.x + cos(a) * 2.5, motor.headHeight + Float.random(in: -0.4...0.5), here.y + sin(a) * 2.5)
        }
        gesture = (g, clock, look)
    }

    // MARK: Gestures and attention

    func idle() {
        guard path.isEmpty, !gesturing, clock >= acknowledgingUntil, let g = persona.idles.randomElement() else { return }
        begin(g)
    }

    /// Oct 20 (follow a critter): its come-hither (persona.acknowledgment), looking
    /// at the player, its hello with it; standing, it turns to them first. A walk
    /// isn't stopped -- it beckons on the way.
    func acknowledge(player: SIMD2<Float>?) {
        let g = persona.acknowledgment
        var look: SIMD3<Float>?
        if let p = player {
            look = SIMD3<Float>(p.x, 1.55, p.y)
            if path.isEmpty, !gesturing { motor.turn(to: ResidentActivities.heading(from: here, to: p)) }
        }
        if !gesturing {                                          // (a hand on a door finishes first)
            begin(g, lookAt: look)
            acknowledgingUntil = clock + g.duration
        }
        greetedAt = clock                                        // (no ordinary hello straight after)
        if !ResidentMusic.greet(persona.id, on: root), let source = HallwaysianVoice.original(persona) {   // Oct 22 (musical building)
            CritterAudio.play(source, on: root)
        }
        LifeLog.event(persona.id, "hallwaysian.acknowledged", ["gesture": g.name, "walking": !path.isEmpty])
    }

    func activityBeat(_ kind: ResidentActivities.Kind, toward thing: SIMD2<Float>?) {
        guard path.isEmpty, !gesturing, clock >= acknowledgingUntil else { return }
        let at = thing.map { SIMD3<Float>($0.x, 0.75, $0.y) }
        switch kind {
        case .working: begin(.tinker, lookAt: at)
        case .inspecting, .investigating: begin(.peer, lookAt: at)
        case .resting: begin(.rest)
        case .visiting: begin(.headTilt, lookAt: at)
        case .circling, .lookingAround:
            begin(Bool.random() ? HallwaysianGesture.lookAround : (persona.idles.randomElement() ?? HallwaysianGesture.lookAround))
        }
    }

    func turn(toward p: SIMD2<Float>, duration: Double) {
        guard path.isEmpty else { return }
        motor.turn(to: ResidentActivities.heading(from: here, to: p))
    }

    func touch(_ point: SIMD2<Float>, contact: @escaping () -> Void, then: @escaping () -> Void) {
        touchToken += 1
        let token = touchToken
        gesturing = true
        motor.turn(to: ResidentActivities.heading(from: here, to: point))
        begin(.push)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.touchToken == token else { return }
            contact()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.touchToken == token else { return }
                self.gesturing = false
                then()
            }
        }
    }

    func watch(_ player: SIMD2<Float>) {
        glance = (SIMD3(player.x, 1.55, player.y), clock + 3)
    }
    func pointOnward(_ onward: SIMD2<Float>, player: SIMD2<Float>) {}
    func call() {}
    func urge(player: SIMD2<Float>, onward: SIMD2<Float>?, then: @escaping () -> Void) { DispatchQueue.main.async { then() } }
    func arrive(player: SIMD2<Float>) {}
    func depart() {}
    func settle(facing heading: Float?) {
        if let heading { motor.turn(to: heading) }
    }
}

// MARK: - One display link for all of them (main thread)

final class HallwaysianDriver: NSObject {
    static let shared = HallwaysianDriver()
    private final class Weak { weak var body: HallwaysianResidentBody?; init(_ b: HallwaysianResidentBody) { body = b } }
    private var bodies: [Weak] = []
    private var link: CADisplayLink?

    func add(_ body: HallwaysianResidentBody) {
        bodies.removeAll { $0.body == nil }
        bodies.append(Weak(body))
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        let perf = PerfMonitor.begin("hallwaysian.frame"); defer { PerfMonitor.end(perf) }   // Oct 21: measurement only (PerfMonitor)
        bodies.removeAll { $0.body == nil }
        if bodies.isEmpty {
            l.invalidate()
            link = nil
            return
        }
        let t = l.timestamp
        for w in bodies { w.body?.frame(at: t) }
    }
}

// MARK: - Their hellos (Hallenese; synthesised once, cached like every critter sound)

enum HallwaysianVoice {
    private static var cache: [String: SCNAudioSource] = [:]

    static func soundName(_ id: String) -> String { "hw-hello-\(id.replacingOccurrences(of: ".", with: "-"))" }

    /// Its greeting: Oct 22 (musical identities) -- for the six with a musical
    /// signature, while the experiment is on, the signature instead (HallwaysianMusic).
    static func hello(_ p: HallwaysianPersona) -> SCNAudioSource? {
        if HallwaysianMusic.isOn, HallwaysianMusic.signature(p.id) != nil, let music = HallwaysianMusic.source(p.id) { return music }
        return original(p)
    }

    /// Its Hallenese hello (the original voice).
    static func original(_ p: HallwaysianPersona) -> SCNAudioSource? {
        let name = soundName(p.id)
        if let s = cache[name] { return s }
        let syllables = p.hello.map { MeetingVoices.Syl(v: $0.v, s: $0.s, a: $0.a, b: $0.b) }
        let seed = name.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
        let s = MenagerieSound.source(name, volume: 0.55) {
            MeetingVoices.speak(syllables, seed: seed, formantScale: p.formant, breath: p.breath)
        }
        cache[name] = s
        return s
    }
}
