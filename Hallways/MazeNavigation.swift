//
//  MazeNavigation.swift
//  Hallways
//
//  The new control model: no more hold-and-steer. You tap, the camera
//  auto-walks straight through the maze on dead-straight stretches only.
//  The instant the path would need to turn -- whether that's a real
//  fork (2-3 open ways forward) or a forced bend (exactly one way to
//  keep going, but it isn't straight ahead) -- the walk stops and waits
//  for another tap, same as a dead end or the target. (Sept 5: a forced
//  bend used to auto-turn and keep walking, same as a straight
//  pass-through; changed to a full stop because Eddie wants 100%
//  manual control over every turn while this area's still being
//  tuned.) Free left/right only exists as "which of these do I pick,"
//  never as something you steer by hand mid-corridor.
//

import Foundation

/// Lightweight console logging for diagnosing navigation input --
/// wrapped in #if DEBUG so it costs nothing and prints nothing in a
/// release build. Every line is tagged "[Nav]" so Xcode's console
/// search bar (type "Nav") isolates just these from everything else
/// Foundation/SceneKit prints. Added to track down reports of the
/// camera walking/turning "by itself": the working theory is that
/// this is usually ONE forward tap auto-continuing through several
/// dead-straight pass-through cells (by design -- see this file's
/// header), which LOOKS autonomous once the finger's already lifted.
/// (Sept 5: a forced turn no longer auto-continues at all -- see
/// walkToNextDecision below -- so this now only applies to genuinely
/// straight stretches.)
/// These logs are what makes that distinguishable from an actual
/// double-fired gesture (a stray two-finger touch, or the pan-rotate
/// and tap recognizers both reacting to what felt like one touch) --
/// by showing exactly which input event triggered which movement, and
/// how many steps a single advance() actually queued up.
func navLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[Nav] \(message())")
    #endif
}

enum Direction: String, CaseIterable, Hashable, Codable {
    case north, south, east, west

    var delta: (row: Int, col: Int) {
        switch self {
        case .north: return (-1, 0)
        case .south: return (1, 0)
        case .east: return (0, 1)
        case .west: return (0, -1)
        }
    }

    var opposite: Direction {
        switch self {
        case .north: return .south
        case .south: return .north
        case .east: return .west
        case .west: return .east
        }
    }

    var left: Direction {
        switch self {
        case .north: return .west
        case .west: return .south
        case .south: return .east
        case .east: return .north
        }
    }

    var right: Direction {
        switch self {
        case .north: return .east
        case .east: return .south
        case .south: return .west
        case .west: return .north
        }
    }

    /// Matches MovementController's convention: forward = (-sin(yaw), -cos(yaw)).
    var yaw: Double {
        atan2(-Double(delta.col), -Double(delta.row))
    }
}

enum NavigationOutcome {
    case intersection(choices: [Direction])
    case deadEnd
    case reachedEnd
    /// Not a topology outcome at all -- walkToNextDecision never
    /// produces this one (it doesn't know objects exist). Reserved for
    /// TapNavigationController to use when it deliberately stops a walk
    /// early because it crossed an uncollected object's cell, same
    /// "hand control back" category as a fork or forced turn.
    case pickedUpObject
    /// Same idea as pickedUpObject, but for the OTHER end of the
    /// mechanic -- TapNavigationController uses this when it stops a
    /// walk early because it crossed an unopened chute's cell. Used to
    /// require actually carrying something too (an empty-handed pass
    /// just walked right through, door and all) -- Eddie, Sept 5:
    /// "have it stop whether you have trash or not," so now it stops
    /// either way and depositIfPresent puts up a message instead if
    /// there's genuinely nothing to give it.
    case delivered
    /// Same "hand control back" category again, for a "You Are Here"
    /// floor map you haven't stood in front of yet. Eddie, Sept 5: "we
    /// need to stop when we hit a box with a map."
    case viewedMap
}

/// Same rule HallwayScene.build(fromMaze:) uses to orient the camera at
/// spawn — first open direction going south/east/north/west — factored
/// out here so TapNavigationController can start from the same heading.
func startingFacing(at start: GridCoordinate, cells: Set<GridCoordinate>) -> Direction {
    func isOpen(_ c: GridCoordinate) -> Bool { cells.contains(c) }
    let candidates: [Direction] = [.south, .east, .north, .west]
    for d in candidates {
        let n = GridCoordinate(row: start.row + d.delta.row, col: start.col + d.delta.col)
        if isOpen(n) { return d }
    }
    return .north
}

/// One cell to move into, and the heading used to get there (so the
/// animation knows when — and to what — it needs to turn).
struct NavigationStep {
    let cell: GridCoordinate
    let heading: Direction
}

/// Starting at `start`, heading `heading`, walks forward through every
/// cell that's a dead-straight pass-through (exactly one way to keep
/// going, and it's straight ahead -- no real choice, so no reason to
/// stop and ask), and returns the full run of steps plus whatever's
/// next: a real fork, a forced turn, a dead end, or the end marker. A
/// forced turn (exactly one way to keep going, but it requires turning)
/// stops the walk and is reported through the same `.intersection`
/// outcome a real fork uses, just with a single-direction choices list
/// -- that reuses the existing "stop, turn, tap forward again" flow
/// instead of inventing a new outcome case just for this.
func walkToNextDecision(from start: GridCoordinate, heading: Direction, cells: Set<GridCoordinate>, end: GridCoordinate) -> (steps: [NavigationStep], outcome: NavigationOutcome) {
    func isOpen(_ c: GridCoordinate) -> Bool { cells.contains(c) }
    func neighbor(_ c: GridCoordinate, _ d: Direction) -> GridCoordinate {
        GridCoordinate(row: c.row + d.delta.row, col: c.col + d.delta.col)
    }

    var current = start
    var facing = heading
    var steps: [NavigationStep] = []

    while true {
        let next = neighbor(current, facing)
        guard isOpen(next) else {
            // Shouldn't happen — we only ever step toward a direction we
            // already confirmed is open — but bail safely if it does.
            return (steps, .deadEnd)
        }
        current = next
        steps.append(NavigationStep(cell: current, heading: facing))

        if current == end {
            return (steps, .reachedEnd)
        }

        // Never counts backward — you don't get offered a U-turn at an
        // intersection, only the up-to-3 ways that continue onward.
        let forwardOptions = [facing.left, facing, facing.right].filter { isOpen(neighbor(current, $0)) }

        if forwardOptions.count == 1 && forwardOptions[0] == facing {
            // A dead-straight pass-through -- no real choice, so no
            // reason to stop and ask.
            continue
        } else if forwardOptions.isEmpty {
            return (steps, .deadEnd)
        } else {
            // Either a real fork (2-3 options) or a forced turn
            // (exactly one option, but it's not straight ahead) --
            // both stop here now and wait for a fresh tap, so a bend in
            // the corridor always reads as a deliberate turn-then-walk
            // rather than the camera swinging through it by itself.
            return (steps, .intersection(choices: forwardOptions))
        }
    }
}
