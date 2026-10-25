//
//  LivingWorldDiagnostic.swift
//  Hallways
//
//  Oct 4 -- TEMPORARY PERFORMANCE DIAGNOSTIC (not production architecture).
//
//  An in-app control for how much of the living world exists on this floor:
//
//      LIVING WORLD   OFF | 1 | 2 | 4 | 8 | ALL     Noodle on/off     Stats
//      Alive: N   Visible: N
//
//  - Population caps how many autonomous actors are installed: menagerie
//    creatures (incl. dog, cat, frog, the audition resident) and Bobbins.
//    Changing it tears down every living actor on this floor (nodes removed,
//    their actions removed, so their brains, animation and sounds stop) and
//    reinstalls up to the cap with the floor's own install code. Navigation
//    and the scene itself are untouched; no floor rebuild.
//  - Noodle is separate (he owns the companion camera's placement): the
//    Noodle button only switches his creature work on/off. The companion
//    camera keeps updating either way. He is NOT in Alive/Visible.
//  - Alive = actors installed now (each has its own per-frame action).
//  - Visible = those whose node hierarchy's bounds are inside the current
//    camera's view frustum (SCNView.isNode(_:insideFrustumOf:)). Walls do NOT
//    occlude in this test: behind a wall but in front of you still counts.
//  - Stats = SceneKit's own statistics overlay (FPS, frame time, draw calls).
//
//  To remove: delete this file and the LivingWorld calls in ContentView,
//  Menagerie, Bobbin, RealAnimals, Audition and TinCanRat.
//

import SceneKit
import UIKit

enum LivingWorld {
    /// Population choices. Int.max = ALL (also restores the cage).
    static let choices: [(title: String, value: Int)] = [("OFF", 0), ("1", 1), ("2", 2), ("4", 4), ("8", 8), ("ALL", Int.max), ("32", crowdSize)]
    private static let populationKey = "livingWorld.population"
    private static let noodleKey = "livingWorld.noodle"

    /// Oct 4: the on-screen palette is OFF for normal testing. true brings it
    /// back (with its remembered population / Noodle choices). While off,
    /// the world runs in its normal state: ALL, Noodle on.
    nonisolated static let showsPanel = false

    static var population: Int = showsPanel ? ((UserDefaults.standard.object(forKey: populationKey) as? Int) ?? Int.max) : Int.max {
        didSet { UserDefaults.standard.set(population, forKey: populationKey) }
    }
    static var isAll: Bool { population == Int.max }

    /// Oct 4 "DOUBLE THE ZOO": the 32 setting = today's full ALL cast plus a
    /// crowd of extra lighter residents (see Menagerie/Audition/Bobbin installs).
    static let crowdSize = 32

    /// Oct 16 (Floor 4 PP): the little roaming inhabitants -- staplers,
    /// slinkies, chairs, ladders, the dog and cat, the Bobbins -- are OFF for
    /// now, so the building's architecture (and what's actually happening)
    /// reads. Nothing is deleted: models, behaviour, sounds all stay. The Big
    /// Shot (Floor 3), the meeting's cast, Jeff and every scripted character
    /// are not ambient and are unaffected. Bring them back:
    /// `-HallwaysAmbientCritters YES`.
    nonisolated static var ambientCritters: Bool { UserDefaults.standard.bool(forKey: "HallwaysAmbientCritters") }
    static var isCrowd: Bool { population == crowdSize }
    /// The full ALL cast (cage included) is present at ALL and at 32.
    static var fullCast: Bool { isAll || isCrowd }

    /// Read every frame by Noodle's tick (render thread).
    nonisolated(unsafe) static var noodleActive: Bool = showsPanel ? ((UserDefaults.standard.object(forKey: "livingWorld.noodle") as? Bool) ?? true) : true

    // This floor's living actors.
    private static var admitted = 0
    private static var installed: [SCNNode] = []          // every top-level node to tear down
    private static var visuals: [SCNNode] = []            // one per actor, for Visible
    private static var installer: (() -> Void)?
    private static weak var view: SCNView?

    /// May one more actor be installed under the current population cap?
    static func admit() -> Bool {
        guard admitted < population else { return false }
        admitted += 1
        return true
    }

    /// Registers an installed actor: `visual` is what Visible tests; `extra`
    /// is any other top-level node it owns (torn down with it).
    static func track(_ visual: SCNNode, extra: SCNNode? = nil) {
        installed.append(visual)
        if let extra { installed.append(extra) }
        visuals.append(visual)
    }

    /// Non-actor top-level nodes that belong to the living world (the cage).
    static func trackStructure(_ node: SCNNode) { installed.append(node) }

    /// Oct 5 (elevator staging): a destination floor's population, built
    /// into ITS scene during the elevator ride without touching the live
    /// floor's lists; activateStaged hands it over at arrival.
    struct StagedFloor {
        fileprivate let installed: [SCNNode]
        fileprivate let visuals: [SCNNode]
        fileprivate let admitted: Int
        fileprivate let installer: () -> Void
    }

    static func stageFloor(install: @escaping () -> Void) -> StagedFloor {
        let tracePhase = ElevatorArrivalTrace.shared.beginPhase("LivingWorld.stageFloor")
        defer { ElevatorArrivalTrace.shared.endPhase("LivingWorld.stageFloor", tracePhase) }
        let live = (installed: installed, visuals: visuals, admitted: admitted)
        installed = []
        visuals = []
        admitted = 0
        if population > 0 { install() }
        let staged = StagedFloor(installed: installed, visuals: visuals, admitted: admitted, installer: install)
        installed = live.installed
        visuals = live.visuals
        admitted = live.admitted
        return staged
    }

    /// Arrival: the staged population becomes this floor's (the previous
    /// floor's nodes leave with its scene, exactly as in beginFloor).
    static func activateStaged(_ staged: StagedFloor, view: SCNView) {
        self.view = view
        installed = staged.installed
        visuals = staged.visuals
        admitted = staged.admitted
        installer = staged.installer
        diag("livingWorld.population", ["population": isAll ? "ALL" : "\(population)", "alive": visuals.count, "staged": true])
        refreshPanel()
        attachPanelIfNeeded()
    }

    /// Called on every floor build with that floor's own install code.
    static func beginFloor(view: SCNView, install: @escaping () -> Void) {
        let tracePhase = ElevatorArrivalTrace.shared.beginPhase("LivingWorld.beginFloor")
        defer { ElevatorArrivalTrace.shared.endPhase("LivingWorld.beginFloor", tracePhase) }
        let traceRelease = ElevatorArrivalTrace.shared.beginPhase("LivingWorld.releasePreviousReferences")
        self.view = view
        installed = []
        visuals = []
        installer = install
        ElevatorArrivalTrace.shared.endPhase("LivingWorld.releasePreviousReferences", traceRelease)
        reinstall()
        attachPanelIfNeeded()
    }

    private static func reinstall() {
        let tracePhase = ElevatorArrivalTrace.shared.beginPhase("LivingWorld.reinstall")
        defer { ElevatorArrivalTrace.shared.endPhase("LivingWorld.reinstall", tracePhase) }
        let traceLock = ElevatorArrivalTrace.shared.beginPhase("LivingWorld.transactionLock")
        SCNTransaction.lock()                             // keep the render thread out while nodes go
        ElevatorArrivalTrace.shared.endPhase("LivingWorld.transactionLock", traceLock)
        let traceRemove = ElevatorArrivalTrace.shared.beginPhase("LivingWorld.removeNodesAndUnlock")
        for node in installed {
            node.removeAllActions()
            node.enumerateChildNodes { child, _ in child.removeAllActions() }
            node.removeFromParentNode()
        }
        SCNTransaction.unlock()
        ElevatorArrivalTrace.shared.endPhase("LivingWorld.removeNodesAndUnlock", traceRemove)
        installed = []
        visuals = []
        admitted = 0
        let tracePopulation = ElevatorArrivalTrace.shared.beginPhase("LivingWorld.populationInstaller")
        if population > 0 { installer?() }
        ElevatorArrivalTrace.shared.endPhase("LivingWorld.populationInstaller", tracePopulation)
        diag("livingWorld.population", ["population": isAll ? "ALL" : "\(population)", "alive": visuals.count])
        let tracePanel = ElevatorArrivalTrace.shared.beginPhase("LivingWorld.refreshPanel")
        refreshPanel()
        ElevatorArrivalTrace.shared.endPhase("LivingWorld.refreshPanel", tracePanel)
    }

    // MARK: Counts

    static var aliveCount: Int { visuals.filter { $0.parent != nil }.count }

    static var visibleCount: Int {
        guard let view, let pov = view.pointOfView else { return 0 }
        return visuals.filter { $0.parent != nil && !$0.isHidden && view.isNode($0, insideFrustumOf: pov) }.count
    }

    // MARK: Panel (window-level, so its touches never reach the SCNView's gestures)

    private static var panel: UIView?
    private static var body: UIStackView?
    private static var populationButtons: [UIButton] = []
    private static var noodleButton: UIButton?
    private static var readout: UILabel?
    private static var refreshTask: Task<Void, Never>?

    private static func attachPanelIfNeeded() {
        guard showsPanel, panel == nil else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard panel == nil, let window = view?.window else { return }
                buildPanel(in: window)
            }
        }
    }

    private static func button(_ title: String, _ action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        config.baseForegroundColor = .white
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            return outgoing
        }
        let b = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        b.layer.cornerRadius = 5
        return b
    }

    private static func buildPanel(in window: UIWindow) {
        let container = UIView()
        container.backgroundColor = UIColor(white: 0, alpha: 0.55)
        container.layer.cornerRadius = 8
        container.translatesAutoresizingMaskIntoConstraints = false

        let outer = UIStackView()
        outer.axis = .vertical
        outer.spacing = 4
        outer.alignment = .leading
        outer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(outer)

        let toggle = button("LW") {
            body?.isHidden.toggle()
        }
        outer.addArrangedSubview(toggle)

        let inner = UIStackView()
        inner.axis = .vertical
        inner.spacing = 4
        inner.alignment = .leading
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 2
        populationButtons = choices.map { choice in
            let b = button(choice.title) {
                guard population != choice.value else { return }
                population = choice.value
                reinstall()
            }
            row.addArrangedSubview(b)
            return b
        }
        inner.addArrangedSubview(row)

        let row2 = UIStackView()
        row2.axis = .horizontal
        row2.spacing = 2
        let noodle = button("Noodle") {
            noodleActive.toggle()
            UserDefaults.standard.set(noodleActive, forKey: noodleKey)
            refreshPanel()
        }
        noodleButton = noodle
        row2.addArrangedSubview(noodle)
        row2.addArrangedSubview(button("Stats") {
            if let view { view.showsStatistics.toggle() }
        })
        inner.addArrangedSubview(row2)

        let label = UILabel()
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .white
        label.numberOfLines = 1
        readout = label
        inner.addArrangedSubview(label)
        outer.addArrangedSubview(inner)
        body = inner

        window.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.leadingAnchor, constant: 6),
            container.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 60),
            outer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            outer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            outer.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            outer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])
        panel = container
        refreshPanel()
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                updateReadout()
            }
        }
    }

    private static func refreshPanel() {
        for (b, choice) in zip(populationButtons, choices) {
            b.backgroundColor = choice.value == population ? UIColor.systemOrange.withAlphaComponent(0.85) : UIColor(white: 1, alpha: 0.12)
        }
        noodleButton?.backgroundColor = noodleActive ? UIColor.systemOrange.withAlphaComponent(0.85) : UIColor(white: 1, alpha: 0.12)
        updateReadout()
    }

    private static func updateReadout() {
        readout?.text = "Alive: \(aliveCount)  Visible: \(visibleCount)"
    }
}
