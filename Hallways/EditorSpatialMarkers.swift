import SwiftUI

/// Editor-only marker layout; directions are wall mounts except for EXIT.
struct EditorSpatialMarkers: View {
    @ObservedObject var store: MazeStore
    let coord: GridCoordinate
    let cellSize: CGFloat
    private struct Mark: Identifiable {
        let id: String
        let symbol: String
        let color: Color
        var wall: Direction? = nil
        var text: String? = nil
        var yaw: Double = 0
    }
    private var marks: [Mark] {
        var result: [Mark] = []
        if let entry = store.pictures[coord] { result.append(Mark(id: "pictures", symbol: "photo.fill", color: .pink, wall: entry.direction)) }
        if let d = store.pictureLights[coord] { result.append(Mark(id: "pictureLights", symbol: "lightbulb.fill", color: .orange, wall: d)) }
        if let d = store.wallLights[coord] { result.append(Mark(id: "wallLights", symbol: "lamp.table.fill", color: .orange, wall: d)) }
        if let d = store.mirrors[coord] { result.append(Mark(id: "mirrors", symbol: "person.crop.rectangle", color: .cyan, wall: d)) }
        if let d = store.floorMaps[coord] { result.append(Mark(id: "floorMaps", symbol: "map.fill", color: .blue, wall: d)) }
        if let d = store.missionSigns[coord] { result.append(Mark(id: "missionSigns", symbol: "signpost.right.fill", color: .purple, wall: d)) }
        if let d = store.bathroomDoors[coord] { result.append(Mark(id: "bathroomDoors", symbol: "door.left.hand.closed", color: .brown, wall: d)) }
        if let d = store.extinguishers[coord] { result.append(Mark(id: "extinguishers", symbol: "flame.fill", color: .red, wall: d)) }
        if let d = store.ticTacToeTerminals[coord] { result.append(Mark(id: "ticTacToeTerminals", symbol: "square.grid.3x3", color: .blue, wall: d)) }
        if let d = store.shellGameStations[coord] { result.append(Mark(id: "shellGameStations", symbol: "cup.and.saucer.fill", color: .blue, wall: d)) }
        if let d = store.rockPaperScissorsTerminals[coord] { result.append(Mark(id: "rockPaperScissorsTerminals", symbol: "hand.raised.fill", color: .blue, wall: d)) }
        if let d = store.higherLowerTerminals[coord] { result.append(Mark(id: "higherLowerTerminals", symbol: "arrow.up.arrow.down", color: .blue, wall: d)) }
        if let d = store.fiveCardDrawTerminals[coord] { result.append(Mark(id: "fiveCardDrawTerminals", symbol: "suit.spade.fill", color: .blue, wall: d)) }
        if let d = store.simonTerminals[coord] { result.append(Mark(id: "simonTerminals", symbol: "circle.grid.2x2.fill", color: .blue, wall: d)) }
        if let d = store.hangmanTerminals[coord] { result.append(Mark(id: "hangmanTerminals", symbol: "textformat", color: .blue, wall: d)) }
        if let d = store.connectFourTerminals[coord] { result.append(Mark(id: "connectFourTerminals", symbol: "circle.grid.3x3.fill", color: .blue, wall: d)) }
        if let d = store.checkersTerminals[coord] { result.append(Mark(id: "checkersTerminals", symbol: "checkerboard.rectangle", color: .blue, wall: d)) }
        if let d = store.woidleTerminals[coord] { result.append(Mark(id: "woidleTerminals", symbol: "character.book.closed.fill", color: .blue, wall: d)) }
        if let door = store.roomDoors[coord] {
            result.append(Mark(id: "door", symbol: "door.left.hand.closed", color: .brown, wall: door.direction, text: "\(door.roomNumber)"))
        }
        if let room = store.windowRooms[coord] { result.append(Mark(id: "window", symbol: "macwindow", color: .blue, wall: room.direction)) }
        if let booth = store.photoBooths[coord] { result.append(Mark(id: "booth", symbol: "camera.fill", color: .cyan, wall: booth.direction)) }
        if let kind = store.object(at: coord) {
            let room = store.itemRooms[coord].map { " \($0)" } ?? ""
            result.append(Mark(id: "pickup", symbol: "", color: .black, text: kind.displayEmoji + room))
        }
        if store.destination(at: coord) != nil {
            let directions: [Direction] = [.north, .south, .east, .west]
            let open = directions.filter { d in store.isOpen(GridCoordinate(row: coord.row + d.delta.row, col: coord.col + d.delta.col)) }
            let wall = open.count == 1 ? open[0].opposite : directions.first { !open.contains($0) }
            result.append(Mark(id: "destination", symbol: "arrow.down.square.fill", color: .green, wall: wall))
        }
        if let orientation = store.fluorescentLights[coord] {
            result.append(Mark(id: "fluorescent", symbol: "rectangle.portrait.fill", color: .orange,
                               yaw: orientation == .eastWest ? 90 : 0))
        }
        if store.hasSpotlight(coord) { result.append(Mark(id: "ceiling", symbol: "lightbulb.fill", color: .orange)) }
        if store.hasFire(coord) { result.append(Mark(id: "fire", symbol: "flame.fill", color: .orange)) }
        if let d = store.exitSignDirection(at: coord) {
            let yaw: Double = d == .north ? 0 : d == .east ? 90 : d == .south ? 180 : 270
            result.append(Mark(id: "exit", symbol: "location.north.fill", color: .red, yaw: yaw))
        }
        return result
    }
    var body: some View {
        let all = marks
        ZStack {
            ForEach(all) { mark in
                let group = all.filter { $0.wall == mark.wall }
                let index = group.firstIndex { $0.id == mark.id } ?? 0
                let size = cellSize * (mark.wall == nil ? 0.25 : min(0.25, 0.72 / CGFloat(max(1, group.count))))
                VStack(spacing: 0) {
                    if !mark.symbol.isEmpty { Image(systemName: mark.symbol).rotationEffect(.degrees(mark.yaw)) }
                    if let text = mark.text { Text(text).lineLimit(1).minimumScaleFactor(0.4) }
                }
                .font(.system(size: size * 0.72, weight: .bold))
                .foregroundStyle(mark.color)
                .frame(width: size, height: size)
                .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 2))
                .offset(offset(mark.wall, index: index, count: group.count))
            }
        }
        .allowsHitTesting(false)
    }
    private func offset(_ wall: Direction?, index: Int, count: Int) -> CGSize {
        guard let wall else {
            if count == 1 { return .zero }
            return CGSize(width: (CGFloat(index % 2) - 0.5) * cellSize * 0.28,
                          height: (CGFloat(index / 2) - CGFloat((count - 1) / 2) / 2) * cellSize * 0.28)
        }
        let along = (CGFloat(index) - CGFloat(count - 1) / 2) * cellSize * min(0.29, 0.72 / CGFloat(count))
        switch wall {
        case .north: return CGSize(width: along, height: -cellSize * 0.36)
        case .south: return CGSize(width: along, height: cellSize * 0.36)
        case .east: return CGSize(width: cellSize * 0.36, height: along)
        case .west: return CGSize(width: -cellSize * 0.36, height: along)
        }
    }
}
