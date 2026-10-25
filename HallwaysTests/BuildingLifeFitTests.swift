import SwiftUI
import Testing
import UIKit
@testable import Hallways

/// Oct 20 -- BUILDING LIFE FITS THE SCREEN. The Ant Farm used to lay every
/// resident on a floor (and everyone still arriving) out in ONE row of fixed-size
/// emblems: with the building's cast that row was far wider than an iPhone, and
/// the whole panel grew with it -- centred, it ran off both sides (the title cut
/// off on the left, Done out of reach on the right). Rows now wrap.
@MainActor
struct BuildingLifeFitTests {
    /// An iPhone's width (points): 393 (iPhone 15 / 16); the narrowest current, 375.
    static let widths: [CGFloat] = [375, 393, 430]

    private func entry(_ i: Int, _ w: ResidentWhereabouts) -> BuildingLifeModel.Entry {
        BuildingLifeModel.Entry(id: "r.\(i)", name: "Resident \(i)", symbol: "circle.fill", tint: .orange,
                                whereabouts: w, metres: nil, why: nil)
    }

    private func size<V: View>(_ view: V, width: CGFloat) -> CGSize {
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: width, height: 10_000))
    }

    @Test func emblemRowsWrapInsteadOfWidening() {
        let flow = BuildingLifeFlow(spacing: 5, lineSpacing: 4) {
            ForEach(0..<30, id: \.self) { _ in Color.orange.frame(width: 24, height: 24) }
        }
        let s = size(flow, width: 200)
        #expect(s.width <= 200)
        #expect(s.height > 24 * 4)                                        // (several rows)
        // Room for all of them: one row, as before.
        let wide = size(flow, width: 2000)
        #expect(abs(wide.height - 24) < 0.5)
    }

    @Test func theAntFarmFitsWithNobodyAndWithEveryone() {
        let floors = Array(1...16)
        let nobody = BuildingLifeModel()
        nobody.show(entries: [], floors: floors)
        // Everyone on one floor, and everyone still arriving (before they come in).
        let crowd = BuildingLifeModel()
        var list: [BuildingLifeModel.Entry] = []
        for i in 0..<30 { list.append(entry(i, .at(floor: 1, cell: GridCoordinate(row: 2, col: 2), point: nil, moving: i % 2 == 0))) }
        for i in 30..<60 { list.append(entry(i, .outside)) }
        crowd.show(entries: list, floors: floors, car: .init(floor: 1, direction: 1, occupants: (30..<40).map { "r.\($0)" },
                                                               players: true, doorsOpen: true, calls: [3, 9]),
                   player: PlayerPlace(floor: 1, cell: GridCoordinate(row: 2, col: 2)))
        for w in Self.widths {
            for model in [nobody, crowd] {
                let s = size(BuildingLifeAntFarmRows(model: model, open: { _ in }), width: w)
                #expect(s.width <= w + 0.5, "Ant Farm \(s.width) wide on a \(w)-point screen")
            }
        }
    }
}
