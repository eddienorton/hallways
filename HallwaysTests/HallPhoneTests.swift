import Foundation
import SwiftUI
import Testing
@testable import Hallways

/// Oct 8 -- the player's phone, Stage 1: the low-to-face path, the
/// finger-to-lift mapping (it must feel 1:1 under the finger) and where a
/// released phone rests.
struct HallPhoneTests {
    private let portrait = HallPhoneLayout(size: CGSize(width: 393, height: 852),
                                           insets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0))
    private let landscape = HallPhoneLayout(size: CGSize(width: 852, height: 393),
                                            insets: EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59))

    @Test func theRaisedPhoneIsBigAndHeldPastTheBottomEdge() {
        #expect(portrait.raisedWidth > 300)
        #expect(portrait.raisedCenter.y + portrait.raisedHeight / 2 > 852)        // bottom runs off the screen
        #expect(portrait.raisedCenter.y - portrait.raisedHeight / 2 > 100)        // the world is visible above it
    }

    @Test func upIsAboveLowInBothOrientations() {
        #expect(portrait.travel > 100)
        #expect(landscape.travel > 99)
        #expect(portrait.center(at: 0) == portrait.restCenter)
        #expect(portrait.center(at: 1) == portrait.raisedCenter)
    }

    @Test func thePhoneStaysUnderTheFinger() {
        for layout in [portrait, landscape] {
            for start in [CGFloat(0), 0.3, 1] {
                for target in [CGFloat(0.1), 0.5, 0.9] {
                    let dy = layout.center(at: target).y - layout.center(at: start).y
                    let lift = layout.lift(from: start, dy: dy)
                    #expect(abs(lift - target) < 0.001)
                }
            }
        }
    }

    @Test func pastEitherEndItResists() {
        let over = portrait.lift(from: 1, dy: -400)
        #expect(over > 1 && over <= 1.12)
        let under = portrait.lift(from: 0, dy: 400)
        #expect(under < 0 && under >= -0.12)
        #expect(portrait.lift(from: 0, dy: 0) == 0)
    }

    @MainActor
    @Test func releasedThePhoneStaysWhereTheHandLeftIt() {
        let phone = HallPhone.shared
        phone.forceLow(reason: "test")
        #expect(phone.beginGrab())
        phone.drag(to: 0.42)
        phone.release()
        #expect(phone.lift == 0.42 && phone.hold == .resting)    // no snapping up or down
        #expect(phone.screenInteractive)                         // high enough to read
        #expect(phone.beginGrab())
        phone.drag(to: 0.2)
        phone.release()
        #expect(phone.lift == 0.2 && !phone.screenInteractive)  // too low to read: all grip
        phone.forceLow(reason: "test")
    }

    @MainActor
    @Test func pulledPastAnEndItSpringsBackToThatEnd() {
        let phone = HallPhone.shared
        phone.forceLow(reason: "test")
        #expect(phone.beginGrab())
        phone.drag(to: 1.08)
        phone.release()
        #expect(phone.lift == 1 && phone.hold == .settling)
        #expect(phone.beginGrab())                               // can be taken hold of again at once
        phone.drag(to: -0.05)
        phone.release()
        #expect(phone.lift == 0)
        phone.forceLow(reason: "test")
        #expect(phone.hold == .resting && phone.lift == 0)
    }

    @Test func lowIsInTheRightHand() {
        #expect(portrait.restCenter.x > 393 * 0.8)
        #expect(portrait.restCenter.y > 852 * 0.75)
        #expect(landscape.restCenter.x > 852 * 0.8)
    }
}
