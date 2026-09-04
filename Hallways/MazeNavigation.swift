//
//  MazeNavigation.swift
//  Hallways
//
//  The new control model: no more hold-and-steer. You tap, the camera
//  auto-walks straight through the maze — turning by itself through any
//  cell that only has one sensible way to keep going — until it hits a
//  real decision (2 or 3 open ways forward) or a dead end/the target.
//  Free left/right only exists as "which of these do I pick," never as
//  something you steer by hand mid-corridor.
//

import Foundation

enum Direction: CaseIterable, Hashable {
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
/// cell that only has one viable way to keep going (a plain pass-through
/// — no real choice, so no reason to stop and ask), and returns the full
/// run of steps plus whatever's next: a real intersection, a dead end, or
/// the end marker.
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

        if forwardOptions.count == 1 {
            facing = forwardOptions[0]
            continue
        } else if forwardOptions.isEmpty {
            return (steps, .deadEnd)
        } else {
            return (steps, .intersection(choices: forwardOptions))
        }
    }
}
