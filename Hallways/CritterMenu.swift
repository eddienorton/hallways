//
//  CritterMenu.swift
//  Hallways
//
//  Oct 23 -- TAP A CRITTER: A SMALL MENU, AND "FOLLOW ME".
//
//  An exploratory experiment (no missions, no refusals, no personalities):
//  tapping a roaming resident now opens a compact card with its name and
//
//    FOLLOW         the player follows it -- CritterFollow, exactly as before
//                   (STOP FOLLOWING while the player is following it)
//    FOLLOW ME      it follows the player -- RoamPresentation's own walk (the
//                   resident lead engine: routes, doors, corners), re-aimed a
//                   couple of times a second at a place behind the player
//    LISTEN         its signature (identities on) or its original voice
//    DISMISS        (only while it follows the player) back to its own life -- Oct 25: labelled
//                   STOP FOLLOWING ME; and the card offers only what fits: following it, STOP
//                   FOLLOWING (no FOLLOW ME); it following you, STOP FOLLOWING ME (no FOLLOW)
//
//  Any number may follow the player at once (each its own place behind: two
//  abreast, a metre a row). Tap elsewhere, or the card's x, to close it.
//
//  Oct 23 (menu pause): while its menu is open the critter tapped stands still
//  where it is (RoamPresentation.setHeld -- only it; the building carries on),
//  its walking music fading. The menu stays until an action, a tap elsewhere or
//  its x (no timeout); a story starting, the elevator, or the critter leaving
//  the scene closes it too. Every close lets it go: the walk it was on carries
//  on from where it stands, or its stay / activity / following simply resumes.
//
//  FOLLOWERS AND THE ELEVATOR: when the player is accepted into the car, the
//  followers within reach of it (FollowMe.boardingReach) come too; when the
//  next floor is built they are there with the player, just outside the car,
//  and carry on following. Anyone too far away is left behind and goes back
//  to its own life. (They don't walk into the cab on screen in this first pass.)
//
//  Their records: "following the player", renewed while they follow (a stay
//  that never runs out); dismissed, or left behind, or after a relaunch (the
//  list isn't saved), they decide afresh -- the building's own life again.
//
//  Never during a scripted scene (CritterFollow.followingAllowed) -- the same
//  rule as following; the butterfly guiding is never offered; Tinky and
//  Juanita have no roaming bodies.
//

import SceneKit
import SwiftUI
import UIKit
import Combine

// MARK: - Who follows the player

@MainActor
enum FollowMe {
    /// In the order they were asked (their places behind the player follow it).
    private(set) static var ids: [String] = []
    /// Who came along into the car (decided as the player boards), from which floor.
    private static var aboard: (from: Int, ids: Set<String>)?
    private static var lastFloor: Int?

    /// Followers this near the player (metres) when the car takes them come along.
    static let boardingReach: Float = 12
    static let why = "following the player"
    /// The stay a follower's record carries, renewed while it follows (seconds).
    static let leash: Double = 120

    static func contains(_ id: String) -> Bool { ids.contains(id) }
    static func rank(_ id: String) -> Int { ids.firstIndex(of: id) ?? 0 }

    private static func presentation(_ id: String) -> ResidentPresentation? {
        BuildingLife.shared.presentations.first { $0.residentID == id }
    }

    static func canRecruit(_ id: String) -> Bool { presentation(id)?.canFollowPlayer ?? false }

    /// FOLLOW ME. True: it's following now.
    @discardableResult
    static func recruit(_ id: String) -> Bool {
        guard !contains(id), let p = presentation(id), p.canFollowPlayer else { return contains(id) }
        ids.append(id)
        guard p.setFollowingPlayer(true) else {
            ids.removeAll { $0 == id }
            LifeLog.event(id, "followMe.refused", ["why": "busy (in or at the car)"])
            return false
        }
        LifeLog.event(id, "followMe.started", ["followers": ids.count])
        return true
    }

    /// DISMISS (or left behind): back to its own life.
    static func dismiss(_ id: String, why: String) {
        guard contains(id) else { return }
        ids.removeAll { $0 == id }
        if let p = presentation(id), p.isRendered {
            _ = p.setFollowingPlayer(false)
        } else {
            release(record: id)
        }
        LifeLog.event(id, "followMe.ended", ["why": why, "followers": ids.count])
    }

    /// A follower's record while it follows: here, staying (renewed), why.
    static func hold(_ r: inout Resident, now: Date) {
        r.leg = nil
        r.since = now
        r.dwell = leash
        r.why = why
        r.room = nil
        r.roomName = nil
    }

    /// Not shown anywhere (left behind): its record decides afresh on the next tick.
    private static func release(record id: String) {
        guard var r = BuildingLife.shared.resident(id), r.why == why else { return }
        r.since = BuildingClock.now()
        r.dwell = 0
        r.why = "no longer following the player"
        BuildingLife.shared.store(r)
    }

    // MARK: The elevator

    /// The player was accepted into this floor's car: who's close enough to come.
    static func playerBoarding() {
        guard !ids.isEmpty, let floor = BuildingLife.shared.currentFloor,
              let player = BuildingLife.shared.playerPosition() else { return }
        var coming: Set<String> = []
        for id in ids {
            if let at = presentation(id)?.bodyPosition, simd_distance(at, player) <= boardingReach { coming.insert(id) }
        }
        aboard = (floor, coming)
        LifeLog.event("player", "followMe.boarding", ["coming": coming.sorted().joined(separator: ","),
                                                      "leftBehind": ids.filter { !coming.contains($0) }.joined(separator: ",")])
    }

    /// A floor was built (before anyone is shown on it). A new floor: those who
    /// came along are put here, by the car; the rest go back to their own lives.
    static func floorBuilt(floor: Int, plan: FloorPlan?) {
        defer { lastFloor = floor; aboard = nil }
        guard !ids.isEmpty, let last = lastFloor, last != floor else { return }       // (a rebuild of the same floor: as they are)
        let came = (aboard?.from == last) ? (aboard?.ids ?? []) : []
        let now = BuildingClock.now()
        for id in ids {
            guard came.contains(id), let cell = plan?.elevator, var r = BuildingLife.shared.resident(id) else {
                ids.removeAll { $0 == id }
                release(record: id)
                LifeLog.event(id, "followMe.ended", ["why": "left behind on F\(last)", "followers": ids.count])
                continue
            }
            BuildingLife.shared.car.cancelCall(id)
            r.floor = floor
            r.cell = cell
            r.shown = nil                                                     // (not back where it was once seen here)
            hold(&r, now: now)
            BuildingLife.shared.store(r)
            LifeLog.event(id, "followMe.cameAlong", floor: floor, ["from": "F\(last)"])
        }
    }
}

// MARK: - The menu

@MainActor
final class CritterMenuModel: ObservableObject {
    static let shared = CritterMenuModel()

    struct Target: Equatable {
        let id: String
        let name: String
    }
    @Published private(set) var target: Target?
    /// (Refreshed with each open and action: who follows whom.)
    @Published private(set) var revision = 0
    private weak var controller: TapNavigationController?
    /// Oct 23 (menu pause): the one held still while its menu is open.
    private var heldID: String?
    /// Oct 23 (menu pause): while open, once a second -- is it still right to be open?
    private var watch: Timer?

    func open(_ id: String, controller c: TapNavigationController) {
        if let t = target, t.id != id { release() }                         // (another's menu: that one goes on)
        controller = c
        target = Target(id: id, name: CharacterRegistry.identity(id)?.name ?? id)
        revision += 1
        // Oct 23 (menu pause): it stops where it is while its menu is open (only it).
        if heldID != id, let p = Self.presentation(id), p.setHeld(true) { heldID = id }
        startWatch()
        LifeLog.event(id, "menu.opened", ["held": heldID == id])
    }

    /// Put away (tapped elsewhere, its x, an action, a scene or floor change): it carries on.
    func close() {
        release()
        stopWatch()
        guard target != nil else { return }
        target = nil
    }

    private static func presentation(_ id: String) -> ResidentPresentation? {
        BuildingLife.shared.presentations.first { $0.residentID == id }
    }

    /// The held one goes on with what it was doing (if it's still here to).
    private func release() {
        guard let id = heldID else { return }
        heldID = nil
        if let p = Self.presentation(id) { _ = p.setHeld(false) }
    }

    /// Oct 23 (menu pause): no timeout -- open until an action, a tap elsewhere or its x.
    /// But never open over a story, the elevator, or a floor it isn't on any more.
    private func startWatch() {
        guard watch == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { CritterMenuModel.shared.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        watch = t
    }

    private func stopWatch() {
        watch?.invalidate()
        watch = nil
    }

    private func check() {
        guard let t = target else { return stopWatch() }
        let why: String?
        if !CritterFollow.allowed(for: t.id) {                                // (Oct 24: Tinky on his escort is allowed)
            why = "a scripted scene"
        } else if controller == nil || controller?.isElevatorRideInProgress == true {
            why = "the elevator / a new floor"
        } else if Self.presentation(t.id)?.bodyNode == nil {
            why = "it isn't here any more"
        } else {
            why = nil
        }
        guard let why else { return }
        LifeLog.event(t.id, "menu.closed", ["why": why])
        close()
    }

    var playerFollowsIt: Bool { target.map { CritterFollow.targetID == $0.id } ?? false }
    /// Oct 24: the card is Tinky's on his escort -- FOLLOW only (his first lesson).
    var isEscortGuide: Bool { target.map { GuidedJourney.isGuideID($0.id) } ?? false }
    var followsPlayer: Bool { target.map { FollowMe.contains($0.id) } ?? false }
    var canFollowMe: Bool { target.map { FollowMe.canRecruit($0.id) } ?? false }
    /// Oct 23 (RELEASE ALL): anyone following anybody -- the player following a
    /// critter, or any critter following the player (seen or not, any floor).
    var anyFollowing: Bool { CritterFollow.targetID != nil || !FollowMe.ids.isEmpty }

    // MARK: Actions

    func follow() {
        guard let t = target, let c = controller else { return close() }
        close()                                                             // (Oct 23: let go first, then the command)
        if FollowMe.contains(t.id) { FollowMe.dismiss(t.id, why: "the player chose to follow it instead") }
        CritterFollow.tapped(t.id, controller: c)                           // (follow / stop / switch, as a tap always did)
    }

    func followMe() {
        guard let t = target, let c = controller else { return close() }
        close()                                                             // (Oct 23: let go first, then the command)
        if CritterFollow.targetID == t.id {                                  // (not both ways at once)
            CritterFollow.stop(reason: "it was asked to follow the player")
            c.stopContinuousWalk(reason: "follow me")
        }
        if FollowMe.recruit(t.id) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            c.showBrief("\(t.name) is following you", seconds: 1.6)
            CritterFollow.acknowledge(t.id)                                   // (its come-hither, and its greeting)
        } else {
            c.showBrief("\(t.name) can't come just now", seconds: 1.6)
        }
    }

    func listen() {
        guard let t = target else { return close() }
        let c = controller
        close()                                                             // (Oct 23: LISTEN closes the menu too; it carries on)
        // Oct 25 (the walking band): a resident with a Music Lab instrument -- a short audition of it (the Lab's
        // own audition: its SoundFont, its sampler). Nobody is recruited, no piece starts.
        let lab = MusicLab.shared
        if WalkingBand.isEnabled, lab.isAvailable, let m = lab.members.first(where: { $0.id == t.id }), lab.canAudition(m) {
            lab.audition(m)
            c?.showBrief("\(t.name): \(m.label.lowercased())", seconds: 2.4)
            return
        }
        // Oct 24 (a temporary diagnostic): with the living orchestra playing, LISTEN is
        // this critter's part of it, alone for a few seconds, in time with the rest.
        if let solo = LivingOrchestra.shared.listen(to: t.id, name: t.name) {
            let part = solo.part == .ensemble ? "horn" : solo.part.rawValue
            c?.showBrief(solo.shared ? "\(t.name): \(part) (shared with others on this floor)" : "\(t.name): \(part)",
                         seconds: 2.4)
            return
        }
        if let node = BuildingLife.shared.presentations.first(where: { $0.residentID == t.id })?.bodyNode,
           ResidentMusic.greet(t.id, on: node) {
            // (its signature, from where it is)
        } else {
            ContactsStore.shared.preview(t.id)                                // (its original voice)
        }
    }

    /// Oct 23 -- RELEASE ALL: the player stops following, and every critter
    /// following the player goes back to its own life from where it is -- the
    /// same stops as STOP FOLLOWING (CritterFollow.stop) and DISMISS
    /// (FollowMe.dismiss, which also lets go of one that isn't in view). Nobody
    /// is moved; tasks, missions and progress are untouched.
    func releaseAll() {
        let c = controller
        close()
        let followed = CritterFollow.targetID
        if let id = followed {
            CritterFollow.stop(reason: "release all")
            c?.stopContinuousWalk(reason: "release all")
            LifeLog.event(id, "follow.releasedAll", [:])
        }
        let followers = FollowMe.ids
        for id in followers { FollowMe.dismiss(id, why: "release all") }
        guard followed != nil || !followers.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
        c?.showBrief("Everyone released", seconds: 1.6)
        diag("menu.releaseAll", ["followed": followed ?? "none", "followers": followers.joined(separator: ",")])
    }

    func dismissFollower() {
        guard let t = target, let c = controller else { return close() }
        close()                                                             // (Oct 23: let go first, then the command)
        FollowMe.dismiss(t.id, why: "dismissed")
        let soft = UIImpactFeedbackGenerator(style: .soft)
        soft.impactOccurred(intensity: 0.7)
        c.showBrief("\(t.name) goes back to its day", seconds: 1.6)
        ResidentMusic.farewell(t.id)                                        // (its goodbye, an octave down)
    }
}

/// The card: the critter's name and its actions, low on the screen above the
/// controls, small enough to leave the corridor in view.
struct CritterMenuOverlay: View {
    @ObservedObject private var model = CritterMenuModel.shared

    var body: some View {
        VStack {
            Spacer()
            if let t = model.target {
                VStack(spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.name).font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            // Oct 25: its Music Lab instrument (MusicLab.swift BandInstruments) -- none assigned, none shown
                            if let instrument = BandInstruments.byResident[t.id], let label = BandInstruments.labels[instrument] {
                                Text(label).font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.78)).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Button { model.close() } label: {
                            Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                                .frame(width: 28, height: 28).background(Color.white.opacity(0.15), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    if model.isEscortGuide {
                        // Oct 24: the first FOLLOW lesson -- one clear action, and why.
                        Text(model.playerFollowsIt ? "You're following Tinky." : "Tinky will take you to your office.")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 8) {
                        // Oct 25: only what fits how the two of you are -- following it: STOP FOLLOWING;
                        // it following you: STOP FOLLOWING ME; neither: FOLLOW and FOLLOW ME. (The state is the
                        // game's own -- CritterFollow.targetID, FollowMe.ids -- read as the card opens.)
                        if model.isEscortGuide {
                            action(model.playerFollowsIt ? "STOP FOLLOWING" : "FOLLOW", "figure.walk") { model.follow() }   // (nothing else on his card)
                        } else if model.followsPlayer {
                            action("STOP FOLLOWING ME", "hand.wave") { model.dismissFollower() }
                        } else if model.playerFollowsIt {
                            action("STOP FOLLOWING", "figure.walk") { model.follow() }
                        } else {
                            action("FOLLOW", "figure.walk") { model.follow() }
                            if model.canFollowMe {
                                action("FOLLOW ME", "person.2.fill") { model.followMe() }
                            }
                        }
                        if !model.isEscortGuide {
                            action("LISTEN", "music.note") { model.listen() }
                            if model.anyFollowing {
                                action("RELEASE ALL", "person.2.slash") { model.releaseAll() }
                            }
                        }
                    }
                }
                .padding(14)
                .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, ContinuousWalkControls.bottomPadding + ContinuousWalkControls.rowHeight + 70)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.target)
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 16, weight: .bold))
                Text(title).font(.system(size: 11, weight: .heavy, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
