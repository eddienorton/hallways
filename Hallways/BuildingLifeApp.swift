//
//  BuildingLifeApp.swift
//  Hallways
//
//  Oct 19 -- BUILDING LIFE, the phone's resident-watching app (steps 2 and 3).
//
//  Oct 21: the phone is retired; Building Life lives in the bottom tray
//  (BuildingLifeTray.swift), over the live world, at whatever height the
//  player leaves it. (It used to be a phone app that opened full-screen.)
//
//    ACTIVITY       (was "The Ant Farm") every floor, top to bottom, with who is on it right now
//                   (a dot each -- WHO, not where along the floor), the player,
//                   and the elevator shaft: the car and anyone riding it.
//                   Tap a floor: its overhead plan (the floor's CURRENT
//                   cells, doors and elevator) with each resident at its real
//                   place -- moving as the building's records move it.
//    DIRECTORY      every inhabitant (met or not), nearest first, with its
//                   portrait (once met) or emblem, where it is (a floor, the
//                   elevator, not in yet) and a hot-and-cold meter: its
//                   distance THROUGH the building (BuildingDistance), never
//                   a direction or a route. Its sound plays on request.
//
//  Everything shown is the real resident model (BuildingLife records, bodies
//  on the player's floor, the elevator's timetable); nothing is spawned,
//  moved or simulated for the app. Refreshed twice a second while open (the
//  walks are cached per layout revision), not every frame; closed, it costs
//  nothing.
//

import Combine
import SwiftUI
import SceneKit
import UIKit
import simd

// MARK: - The model (refreshed while the app is open)

final class BuildingLifeModel: ObservableObject {
    static let shared = BuildingLifeModel()

    struct Entry: Identifiable {
        let id: String
        let name: String
        let symbol: String
        let tint: Color
        let whereabouts: ResidentWhereabouts
        let metres: Double?
        let why: String?
        var meter: Double { BuildingDistance.meter(metres) }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var player: PlayerPlace?
    @Published private(set) var playerPoint: SIMD2<Float>?
    /// Oct 19 (later): THE car -- one, at the floor the elevator's timetable puts it,
    /// with its way and everyone the records have riding it (see carDisplay).
    @Published private(set) var car: CarDisplay?
    @Published private(set) var floors: [Int] = []

    /// Tests (layout): the model showing exactly these, without a building.
    func show(entries: [Entry], floors: [Int], car: CarDisplay? = nil, player: PlayerPlace? = nil) {
        self.entries = entries
        self.floors = floors
        self.car = car
        self.player = player
    }

    private weak var store: MazeStore?
    private weak var bridge: NavigationBridge?
    private(set) var router: BuildingRouter?
    private var timer: Timer?

    /// The building it reads (the app's MazeStore and the live controller).
    func attach(mazeStore: MazeStore, navBridge: NavigationBridge) {
        if store !== mazeStore {
            store = mazeStore
            router = BuildingRouter(plans: { [weak mazeStore] in mazeStore?.floorPlan(for: $0) },
                                    revision: { [weak mazeStore] in mazeStore?.version ?? 0 })
        }
        bridge = navBridge
    }

    func start() {
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        diag("buildingLife.opened", ["residents": entries.count])
        StickyProbe.note("Building Life opened")                    // Oct 22 (evening): measurement only
    }

    func stop() {
        if timer != nil { StickyProbe.note("Building Life closed") }  // Oct 22 (evening): measurement only
        timer?.invalidate()
        timer = nil
    }

    func refresh(now: Date = BuildingClock.now()) {
        let perf = PerfMonitor.begin("buildingLife.refresh"); defer { PerfMonitor.end(perf) }   // Oct 22 (evening): measurement only
        guard let store, let router else { return }
        let here = store.currentMazeID
        floors = Array(Set(store.buildingFloorIDs).union([here])).sorted()
        let controller = bridge?.controller
        if let c = controller {
            player = PlayerPlace(floor: here, cell: c.currentCell)
            let p = c.cameraNode.presentation.worldPosition
            playerPoint = SIMD2(p.x, p.z)
        } else {
            player = nil
            playerPoint = nil
        }
        let reachable: Set<Int>? = controller.flatMap { $0.elevatorReachableFloors.isEmpty ? nil : $0.elevatorReachableFloors }
        let position = BuildingLife.shared.car.position(now: now)
        let list = Self.entries(life: BuildingLife.shared, router: router, player: player, reachable: reachable,
                                bodyFloor: BuildingLife.shared.currentFloor ?? here, now: now, carFloor: position?.floor)
        entries = list
        car = Self.carDisplay(position)
    }

    /// THE car, drawn once, exactly as the elevator's one state has it
    /// (BuildingElevator.position): the floor it is at -- running, the floor its
    /// count has reached --, its way, its doors, who is in it (the player too),
    /// and the floors where someone is waiting for it.
    struct CarDisplay: Equatable {
        let floor: Int
        let direction: Int
        let occupants: [String]
        /// The player is in it (or has its doors).
        let players: Bool
        /// Its doors are open (or opening) at that floor.
        let doorsOpen: Bool
        /// Floors where someone is waiting for it.
        let calls: Set<Int>
    }

    static func carDisplay(_ p: BuildingElevator.Position?) -> CarDisplay? {
        guard let p else { return nil }
        return CarDisplay(floor: p.floor, direction: p.direction,
                          occupants: p.riders.map(\.who).filter { $0 != "player" },
                          players: p.owner == .player || p.riders.contains { $0.who == "player" },
                          doorsOpen: p.target == nil && (p.doors == .opening || p.doors == .open),
                          calls: Set(p.calls.map(\.floor)))
    }

    /// Every resident: where, how far, nearest first. (Pure but for reading the
    /// records and bodies -- the tests drive it with their own building.)
    static func entries(life: BuildingLife, router: BuildingRouter, player: PlayerPlace?, reachable: Set<Int>?,
                        bodyFloor: Int, now: Date, carFloor: Int? = nil) -> [Entry] {
        var list: [Entry] = []
        for id in life.residentIDs {
            guard let r = life.resident(id) else { continue }
            let p = life.presentations.first { $0.residentID == id }
            var body: (floor: Int, point: SIMD2<Float>)?
            if let p, p.isRendered, let at = p.bodyPosition { body = (floor: bodyFloor, point: at) }
            var w = router.whereabouts(r, now: now, body: body, carFloor: carFloor)
            // (Oct 19, later: a rider is where THE car is -- the one the Ant Farm draws.)
            if case .riding(let from, let to, _) = w, let carFloor { w = .riding(from: from, to: to, floor: carFloor) }
            let d = player.map { router.distance(from: $0, to: w, reachable: reachable) } ?? (metres: nil, why: "you aren't anywhere yet")
            let identity = CharacterRegistry.identity(id)
            list.append(Entry(id: id, name: identity?.name ?? id, symbol: identity?.symbol ?? "circle.fill",
                              tint: identity?.tint ?? .gray, whereabouts: w, metres: d.metres, why: d.why))
        }
        return list.sorted { a, b in
            switch (a.metres, b.metres) {
            case let (x?, y?): return x != y ? x < y : a.name < b.name
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.name < b.name
            }
        }
    }

    /// Who is on a floor (riders not included).
    func onFloor(_ floor: Int) -> [Entry] { entries.filter { if case .at(let f, _, _, _) = $0.whereabouts { return f == floor }; return false } }

    static func place(_ w: ResidentWhereabouts) -> String {
        switch w {
        case .at(let f, _, _, let moving): return BuildingFloors.name(f) + (moving ? " \u{00B7} on the move" : "")
        case .riding(let from, let to, _): return "In the elevator \u{00B7} going " + (to > from ? "up" : (to < from ? "down" : "nowhere"))
        case .outside: return "Not in the building yet"
        case .unknown: return "Whereabouts unknown"
        }
    }
}

// MARK: - In the tray

struct BuildingLifePanel<Accessory: View>: View {
    // Oct 20 (fit): its content can never be wider than the screen (the rows
    // wrap: BuildingLifeFlow).
    // Oct 21: no longer a full-screen cover opened from the phone -- it is the
    // content of the Building Life tray (BuildingLifeTray.swift), over the live
    // world. No Done: lowering the tray puts it away. `accessory` sits where
    // Done was (the tray's Messages button).
    let navBridge: NavigationBridge
    let mazeStore: MazeStore
    let accessory: Accessory
    @ObservedObject private var apps = PhoneApps.shared
    @ObservedObject private var model = BuildingLifeModel.shared

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack {
                    Text("Building Life").font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundStyle(PhoneStyle.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 8)
                    accessory
                }
                .padding(.horizontal, 18).padding(.top, 2)
                Picker("", selection: $apps.buildingLifeTab) {
                    Text("Activity").tag(0)                       // (Oct 21: was "Ant Farm")
                    Text("Directory").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 18).padding(.vertical, 10)
                Group {
                    if apps.buildingLifeTab == 0 {
                        if let floor = apps.buildingLifeFloor {
                            BuildingLifeFloorView(floor: floor, model: model) { apps.buildingLifeFloor = nil }
                        } else {
                            BuildingLifeAntFarm(model: model) { apps.buildingLifeFloor = $0 }
                        }
                    } else {
                        BuildingLifeDirectory(model: model)
                    }
                }
                .frame(width: geo.size.width)                       // (whatever is inside: never wider than the screen)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
        }
        .onAppear {
            model.attach(mazeStore: mazeStore, navBridge: navBridge)
            model.start()                                       // (idempotent: one 2 Hz refresh, however often it appears)
        }
        .onDisappear { model.stop() }
    }
}

/// Oct 20 (fit): emblems in rows that wrap at the width they are given -- a
/// floor with everyone on it, or everyone still arriving, makes more rows,
/// never a row wider than the screen.
struct BuildingLifeFlow: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 4

    private func lines(_ sizes: [CGSize], width: CGFloat) -> [[Int]] {
        var out: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, s) in sizes.enumerated() {
            if !out[out.count - 1].isEmpty, x + spacing + s.width > width + 0.5 {
                out.append([])
                x = 0
            }
            x += (out[out.count - 1].isEmpty ? 0 : spacing) + s.width
            out[out.count - 1].append(i)
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? .infinity
        var widest: CGFloat = 0, height: CGFloat = 0
        for (n, line) in lines(sizes, width: width).enumerated() where !line.isEmpty {
            let w = line.map { sizes[$0].width }.reduce(0, +) + spacing * CGFloat(line.count - 1)
            widest = max(widest, w)
            height += (n > 0 ? lineSpacing : 0) + (line.map { sizes[$0].height }.max() ?? 0)
        }
        return CGSize(width: proposal.width.map { min($0, widest) } ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for line in lines(sizes, width: bounds.width) where !line.isEmpty {
            let h = line.map { sizes[$0].height }.max() ?? 0
            var x = bounds.minX
            for i in line {
                subviews[i].place(at: CGPoint(x: x, y: y + (h - sizes[i].height) / 2), proposal: ProposedViewSize(sizes[i]))
                x += sizes[i].width + spacing
            }
            y += h + lineSpacing
        }
    }
}

/// A resident's emblem: its portrait once met, else its symbol on its colour.
struct BuildingLifeEmblem: View {
    let entry: BuildingLifeModel.Entry
    let size: CGFloat
    @ObservedObject private var contacts = ContactsStore.shared

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [entry.tint.opacity(0.55), entry.tint], startPoint: .top, endPoint: .bottom))
            if let image = contacts.hasMet(entry.id) ? contacts.portrait(entry.id) : nil {
                Image(uiImage: image).resizable().scaledToFit().padding(size * 0.04)
            } else {
                Image(systemName: entry.symbol).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1))
    }
}

// MARK: The Ant Farm

struct BuildingLifeAntFarm: View {
    @ObservedObject var model: BuildingLifeModel
    let open: (Int) -> Void

    var body: some View {
        ScrollView {
            BuildingLifeAntFarmRows(model: model, open: open)
        }
    }
}

/// The Ant Farm's floors (its scrolling aside -- the layout tests measure this).
struct BuildingLifeAntFarmRows: View {
    @ObservedObject var model: BuildingLifeModel
    let open: (Int) -> Void

    /// The shaft column's width (the car box, at most a few riders and a count, fits in it).
    static let shaftWidth: CGFloat = 84
    /// Riders drawn in the car box; the rest as "+n".
    static let ridersShown = 3

    var body: some View {
            VStack(spacing: 0) {
                Text("Who is on each floor right now -- not where on it. Tap a floor to look closer.")
                    .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 8)
                ForEach(model.floors.reversed(), id: \.self) { floor in
                    row(floor)
                }
                let outside = model.entries.filter { $0.whereabouts == .outside }
                if !outside.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Text("Arriving").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                            .frame(width: 72, alignment: .leading).padding(.top, 3)
                        BuildingLifeFlow {                              // (Oct 20: everyone arriving, in rows that wrap)
                            ForEach(outside) { BuildingLifeEmblem(entry: $0, size: 22).opacity(0.6) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 8)
                }
            }
            .padding(.bottom, 30)
    }

    private func row(_ floor: Int) -> some View {
        let here = model.player?.floor == floor
        let people = model.onFloor(floor)
        let car = model.car?.floor == floor ? model.car : nil
        let aboard = car.map { c in c.occupants.compactMap { id in model.entries.first { $0.id == id } } } ?? []
        let riders = Array(aboard.prefix(Self.ridersShown))
        let more = aboard.count - riders.count
        return HStack(spacing: 8) {
            Text(floor == 1 ? "Lobby" : "\(floor)")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(here ? PhoneStyle.buildingLife : PhoneStyle.ink)
                .frame(width: 52, alignment: .leading)
            BuildingLifeFlow {                                      // (Oct 20: wraps -- a full floor is taller, never wider)
                if here {
                    Text("YOU").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(PhoneStyle.buildingLife, in: Capsule())
                        .fixedSize()
                }
                ForEach(people) { e in
                    BuildingLifeEmblem(entry: e, size: 24)
                        .overlay(alignment: .bottomTrailing) {
                            if case .at(_, _, _, true) = e.whereabouts {
                                Circle().fill(Color.white).frame(width: 7, height: 7).overlay(Circle().stroke(e.tint, lineWidth: 1.5))
                            }
                        }
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .animation(.easeInOut(duration: 0.35), value: people.map(\.id))
            // The shaft: the car (and anyone riding it) at the floor it has reached.
            ZStack {
                Rectangle().fill(PhoneStyle.rule.opacity(0.7)).frame(width: 3)
                if let car {
                    // THE car: its way, and whoever is in it, together.
                    RoundedRectangle(cornerRadius: 4)
                        .fill(PhoneStyle.ink.opacity(0.85))
                        .frame(width: min(Self.shaftWidth - 4, max(34, CGFloat(riders.count) * 13 + (more > 0 ? 18 : 0)
                                                                  + (car.direction != 0 ? 14 : 4) + (car.players ? 14 : 0))), height: 26)
                        .overlay {
                            HStack(spacing: 1) {
                                if car.direction != 0 {
                                    Image(systemName: car.direction > 0 ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                                }
                                if car.players {
                                    Circle().fill(PhoneStyle.buildingLife).frame(width: 11, height: 11)
                                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                                }
                                ForEach(riders) { BuildingLifeEmblem(entry: $0, size: 12) }
                                if more > 0 {
                                    Text("+\(more)").font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                                }
                            }
                        }
                        .overlay {
                            // Its doors open here: the box opens at its sides.
                            if car.doorsOpen {
                                RoundedRectangle(cornerRadius: 4).stroke(PhoneStyle.buildingLife, lineWidth: 2.5)
                            }
                        }
                        .transition(.opacity)
                } else if model.car?.calls.contains(floor) == true {
                    // Someone waiting for it here.
                    Circle().stroke(PhoneStyle.ink.opacity(0.7), lineWidth: 2).frame(width: 12, height: 12)
                        .background(Circle().fill(Color.white))
                }
            }
            .frame(width: Self.shaftWidth)
            .frame(minHeight: 34)
            .animation(.easeInOut(duration: 0.3), value: car)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 3)
        .background(here ? PhoneStyle.buildingLife.opacity(0.08) : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(PhoneStyle.rule).frame(height: 1).padding(.leading, 18) }
        .contentShape(Rectangle())
        .onTapGesture { open(floor) }
    }
}

// MARK: A floor, overhead

struct BuildingLifeFloorView: View {
    let floor: Int
    @ObservedObject var model: BuildingLifeModel
    let back: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: back) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold))
                        Text("Building").font(.system(size: 15, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(PhoneStyle.buildingLife)
                }
                Spacer()
                Text(BuildingFloors.name(floor)).font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(PhoneStyle.ink)
                Spacer()
                Text("\(model.onFloor(floor).count) here").font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(PhoneStyle.inkSoft).frame(width: 70, alignment: .trailing)
            }
            .padding(.horizontal, 18)
            if let plan = model.router?.plan(floor) {
                GeometryReader { geo in
                    plot(plan, in: geo.size)
                }
                .padding(.horizontal, 12)
            } else {
                Text("No plan for this floor.").font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(PhoneStyle.inkSoft).padding(.top, 40)
            }
            Spacer(minLength: 0)
        }
    }

    private func plot(_ plan: FloorPlan, in size: CGSize) -> some View {
        let rows = plan.cells.map(\.row), cols = plan.cells.map(\.col)
        let r0 = (rows.min() ?? 0) - 1, r1 = (rows.max() ?? 0) + 1
        let c0 = (cols.min() ?? 0) - 1, c1 = (cols.max() ?? 0) + 1
        let unit = min(size.width / CGFloat(c1 - c0 + 1), size.height / CGFloat(r1 - r0 + 1))
        let ox = (size.width - unit * CGFloat(c1 - c0 + 1)) / 2, oy = CGFloat(0)
        func pt(_ x: Float, _ z: Float) -> CGPoint {         // world (x, z) -> the plot
            let s = plan.cellSize
            return CGPoint(x: ox + (CGFloat(x / s) - CGFloat(c0) + 0.5) * unit, y: oy + (CGFloat(z / s) - CGFloat(r0) + 0.5) * unit)
        }
        func centre(_ c: GridCoordinate) -> CGPoint { pt(Float(c.col) * plan.cellSize, Float(c.row) * plan.cellSize) }
        let people = model.onFloor(floor)
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                // The floor: its walkable cells (walls are wherever they aren't).
                for c in plan.cells {
                    let p = centre(c)
                    ctx.fill(Path(CGRect(x: p.x - unit / 2, y: p.y - unit / 2, width: unit + 0.5, height: unit + 0.5)),
                             with: .color(Color(white: 0.9)))
                }
                // Doors: room entrances (open-able) and the shut kinds.
                func door(_ c: GridCoordinate, _ d: Direction, _ color: Color) {
                    let p = centre(c)
                    let e = CGPoint(x: p.x + CGFloat(d.delta.col) * unit / 2, y: p.y + CGFloat(d.delta.row) * unit / 2)
                    let along = CGSize(width: CGFloat(abs(d.delta.row)) * unit * 0.32, height: CGFloat(abs(d.delta.col)) * unit * 0.32)
                    var path = Path()
                    path.move(to: CGPoint(x: e.x - along.width, y: e.y - along.height))
                    path.addLine(to: CGPoint(x: e.x + along.width, y: e.y + along.height))
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: max(2, unit * 0.12), lineCap: .round))
                }
                for (c, d) in plan.doors { door(c, d, Color(red: 0.55, green: 0.42, blue: 0.3)) }
                for (c, d) in plan.bathroomDoors { door(c, d, Color(white: 0.45)) }
                for (c, d) in plan.windowDoors { door(c, d, Color(white: 0.45)) }
                if let e = plan.elevator {
                    let p = centre(e)
                    let box = CGRect(x: p.x - unit * 0.3, y: p.y - unit * 0.3, width: unit * 0.6, height: unit * 0.6)
                    ctx.stroke(Path(roundedRect: box, cornerRadius: unit * 0.08), with: .color(PhoneStyle.ink.opacity(0.7)), lineWidth: 1.5)
                    ctx.draw(Text("E").font(.system(size: max(8, unit * 0.32), weight: .heavy, design: .rounded))
                                .foregroundColor(PhoneStyle.ink.opacity(0.7)), at: p)
                }
            }
            // You (a dot -- no facing, no route).
            if model.player?.floor == floor, let p = model.playerPoint {
                let at = pt(p.x, p.y)
                Circle().fill(PhoneStyle.buildingLife).frame(width: max(10, unit * 0.4), height: max(10, unit * 0.4))
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .position(at)
                    .animation(.linear(duration: 0.5), value: at.x)
                    .animation(.linear(duration: 0.5), value: at.y)
            }
            // Everyone on this floor, where the building has them.
            ForEach(people) { e in
                if case .at(_, let cell, let point, _) = e.whereabouts {
                    let at = point.map { pt($0.x, $0.y) } ?? centre(cell)
                    BuildingLifeEmblem(entry: e, size: max(16, min(30, unit * 0.62)))
                        .position(at)
                        .animation(.linear(duration: 0.5), value: at.x)
                        .animation(.linear(duration: 0.5), value: at.y)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: The Company Directory

struct BuildingLifeDirectory: View {
    @ObservedObject var model: BuildingLifeModel
    /// Oct 25 (PP 5 recovery): which Music Lab -- TRACKS (the default: the Hallways Originals' own audio stems,
    /// StemLab -- choose a piece, play it whole, switch its tracks on and off) or ARRANGER (MusicLab: the
    /// SoundFont band arranging a composition by layers).
    @State private var arranger = false

    var body: some View {
        // Oct 24 (Music Lab): the band's selector and controls, fixed above the list (the list
        // below re-sorts by nearness; the lab never moves). Level 2: the musicians' tiles head
        // the scrolling list (eight of them scroll rather than crowd). Leaving the Directory stops it.
        VStack(spacing: 0) {
        labPicker
        if arranger {
            MusicLabControls()
                .padding(.bottom, 10)
        } else {
            StemLabControls()
                .padding(.bottom, 10)
        }
        ScrollView {
            LazyVStack(spacing: 0) {
                if arranger {
                    MusicLabMusicians()
                        .padding(.bottom, 14)
                } else {
                    StemLabMusicians()
                        .padding(.bottom, 14)
                }
                Text("Everyone in the building, nearest first. The meter is how near they are through the building -- warmer is nearer. Listen for them too.")
                    .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 8)
                ForEach(model.entries) { e in
                    HStack(spacing: 12) {
                        BuildingLifeEmblem(entry: e, size: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.name).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(PhoneStyle.ink)
                            Text(BuildingLifeModel.place(e.whereabouts))
                                .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(PhoneStyle.inkSoft).lineLimit(1)
                            BuildingLifeMeter(value: e.meter, known: e.metres != nil)
                                .frame(height: 12)
                        }
                        if HallwaysianMusic.signature(e.id) != nil {
                            // Oct 22 (musical identities): the six -- Music and Original, side by side.
                            DirectoryAuditionButtons(id: e.id, tint: e.tint)
                        } else {
                            Button {
                                ContactsStore.shared.preview(e.id)
                            } label: {
                                Image(systemName: "speaker.wave.2.fill").font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white).frame(width: 38, height: 38)
                                    .background(e.tint, in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    Rectangle().fill(PhoneStyle.rule).frame(height: 1).padding(.leading, 78)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: model.entries.map(\.id))
            .padding(.bottom, 30)
        }
        }
        .onAppear {                                                  // Oct 24: the lab has the audio focus
            MusicLab.shared.directoryOpened()
            StemLab.shared.directoryOpened()
        }
        .onDisappear {
            StemLab.shared.directoryClosed()
            MusicLab.shared.directoryClosed()
        }
    }

    /// TRACKS / ARRANGER: switching stops whatever is playing (one lab at a time).
    private var labPicker: some View {
        Picker("Music Lab", selection: Binding(get: { arranger }, set: { on in
            StemLab.shared.stop()
            MusicLab.shared.stop()
            arranger = on
        })) {
            Text("TRACKS").tag(false)
            Text("ARRANGER").tag(true)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

/// Oct 22 (musical identities): two small buttons in place of the speaker -- the
/// musical signature, and the original Hallenese hello -- for comparing at once.
struct DirectoryAuditionButtons: View {
    let id: String
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            Button { ContactsStore.shared.previewMusic(id) } label: {
                Label("Music", systemImage: "music.note")
                    .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .frame(width: 84, height: 28).background(tint, in: Capsule())
            }
            .buttonStyle(.plain)
            Button { ContactsStore.shared.previewOriginal(id) } label: {
                Label("Original", systemImage: "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(tint)
                    .frame(width: 84, height: 28).overlay(Capsule().stroke(tint, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
        }
        .labelStyle(.titleAndIcon)
    }
}

/// Hot and cold: warm and full when near, cool and short when far; grey when there's no way there.
struct BuildingLifeMeter: View {
    let value: Double
    let known: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PhoneStyle.rule)
                if known {
                    Capsule()
                        .fill(LinearGradient(colors: [Color(red: 0.3, green: 0.55, blue: 0.95), Color(red: 0.98, green: 0.62, blue: 0.2),
                                                      Color(red: 0.93, green: 0.25, blue: 0.2)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(geo.size.height, geo.size.width * value))
                        .mask(Capsule().frame(width: max(geo.size.height, geo.size.width * value)))
                }
            }
        }
        .animation(.easeOut(duration: 0.45), value: value)
    }
}
