import Foundation
import Testing
@testable import Hallways

/// Oct 24 -- the living orchestra's mixing rules (pure): distance to gain, a
/// shared part's gain, who plays what.
@MainActor
struct LivingOrchestraTests {
    private let t = OrchestraConfig.Tuning()

    /// Full near, falling smoothly (never rising) to the floor's minimum far away.
    @Test func gainFallsSmoothlyWithDistance() {
        #expect(OrchestraConfig.gain(distance: 0, tuning: t) == t.maxGain)
        #expect(OrchestraConfig.gain(distance: t.nearRadius, tuning: t) == t.maxGain)
        #expect(abs(OrchestraConfig.gain(distance: t.farRadius, tuning: t) - t.minGain) < 1e-6)
        #expect(abs(OrchestraConfig.gain(distance: 200, tuning: t) - t.minGain) < 1e-6)
        var last = OrchestraConfig.gain(distance: 0, tuning: t)
        for i in 1...400 {
            let g = OrchestraConfig.gain(distance: Float(i) * 0.05, tuning: t)
            #expect(g <= last + 1e-6)                                   // (never louder further away)
            #expect(last - g < 0.02)                                    // (no steps: 5 cm never jumps)
            last = g
        }
    }

    /// A shared part: the loudest member, a little more for company, never above max; nobody: silent.
    @Test func aCrowdIsRicherNotLouder() {
        #expect(OrchestraConfig.partGain([], tuning: t) == 0)
        #expect(OrchestraConfig.partGain([0.4], tuning: t) == 0.4)
        let three = OrchestraConfig.partGain([0.4, 0.2, 0.3], tuning: t)
        #expect(three > 0.4 && three < 0.6)
        #expect(OrchestraConfig.partGain(Array(repeating: 1, count: 12), tuning: t) == t.maxGain)
    }

    /// The three named critters have their own parts; everyone else shares the ensemble.
    @Test func whoPlaysWhat() {
        #expect(OrchestraConfig.part(for: "hw.feddy") == .flute)
        #expect(OrchestraConfig.part(for: "cast.mailbox") == .clarinet)
        #expect(OrchestraConfig.part(for: "chair.1") == .bassoon)
        #expect(OrchestraConfig.part(for: "hw.lopsy") == .ensemble)
        #expect(OrchestraConfig.part(for: "pottle.1") == .ensemble)
        #expect(OrchestraConfig.part(for: "butterfly") == .ensemble)
    }
}
