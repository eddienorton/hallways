//
//  ElevatorRideSound.swift
//  Hallways
//
//  Oct 4 (interactive elevator): the audible difference between a cab that
//  is STANDING (elevator music only, from SoundEffects) and one that is
//  MOVING (this: a start thunk + a low motor hum loop, stopped on arrival),
//  plus the floor-button click. Small synthesised placeholders (same cached
//  WAV path the creatures use) until a real recorded elevator-motor loop
//  replaces startTravel's source.
//

import SceneKit

enum ElevatorRideSound {
    private static let clickSource: SCNAudioSource? = {
        let s = MenagerieSound.source("elevator-button-click", volume: 0.55) {
            var rng = MenagerieSound.Rand(seed: 21)
            return MenagerieSound.strike([(2350, 0.012, 1), (5200, 0.006, 0.4), (900, 0.02, 0.3)],
                                         seconds: 0.08, noise: 0.5, noiseDecay: 0.002, rng: &rng)
        }
        s?.isPositional = false
        return s
    }()

    private static let startSource: SCNAudioSource? = {
        let s = MenagerieSound.source("elevator-start-thunk", volume: 0.5) {
            var rng = MenagerieSound.Rand(seed: 33)
            return MenagerieSound.strike([(62, 0.25, 1), (124, 0.12, 0.4), (410, 0.05, 0.15)],
                                         seconds: 0.7, noise: 0.35, noiseDecay: 0.03, rng: &rng)
        }
        s?.isPositional = false
        return s
    }()

    /// A seamless 2 s motor hum (whole cycles of 55/110/165 Hz) with a
    /// faint rumble -- the "we are moving" layer.
    private static let humSource: SCNAudioSource? = {
        let s = MenagerieSound.source("elevator-travel-hum", volume: 0.32) {
            let rate = MenagerieSound.rate
            let n = Int(2 * rate)
            var rng = MenagerieSound.Rand(seed: 44)
            var lp: Float = 0
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = Float(i) / rate
                lp += ((rng.unit() * 2 - 1) - lp) * 0.02
                out[i] = sin(2 * .pi * 55 * t) * 0.6 + sin(2 * .pi * 110 * t) * 0.3 + sin(2 * .pi * 165 * t) * 0.08 + lp * 0.9
            }
            return out
        }
        s?.isPositional = false
        s?.loops = true
        return s
    }()

    private static weak var humPlayerNode: SCNNode?
    private static var humPlayer: SCNAudioPlayer?

    static func click(on node: SCNNode) {
        guard let clickSource else { return }
        node.runAction(.playAudio(clickSource, waitForCompletion: false))
    }

    static func startTravel(on node: SCNNode) {
        if let startSource { node.runAction(.playAudio(startSource, waitForCompletion: false)) }
        stopTravel(on: node)
        guard let humSource else { return }
        let player = SCNAudioPlayer(source: humSource)
        node.addAudioPlayer(player)
        humPlayer = player
        humPlayerNode = node
    }

    static func stopTravel(on node: SCNNode) {
        if let player = humPlayer { (humPlayerNode ?? node).removeAudioPlayer(player) }
        humPlayer = nil
        humPlayerNode = nil
    }
}
