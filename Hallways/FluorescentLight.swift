import SceneKit
import UIKit

/// A rectangular fixture has two axes, not four wall-facing directions.
enum FluorescentOrientation: String, Codable, CaseIterable {
    case northSouth, eastWest

    var title: String { self == .northSouth ? "North–South" : "East–West" }
}

struct FluorescentPlacement: Codable {
    let coord: GridCoordinate
    let orientation: FluorescentOrientation
}

extension HallwayScene {
    /// Flush-mounted steel housing with a recessed prismatic diffuser.
    /// Local long axis is Z (north/south); all parts and the area light rotate together.
    // wallHeight defaults to MazeStore.wallHeight's own constant (3.0)
    // so the two other call sites that don't pass it explicitly
    // (DecoratorMode's Add-Light preview, ElevatorCabDecoration) keep
    // compiling unchanged and still get the real value -- added
    // Sept 22 for the far hidden-Spot diagnostic below, which needs to
    // know the real ceiling-to-floor distance.
    static func makeFluorescentLight(orientation: FluorescentOrientation, level: Int, cellSize: CGFloat, wallHeight: CGFloat = 3.0) -> SCNNode {
        let fixture = SCNNode()
        fixture.name = "authored_fluorescent"
        fixture.eulerAngles.y = orientation == .eastWest ? .pi / 2 : 0

        let housing = SCNMaterial()
        housing.lightingModel = .physicallyBased
        housing.diffuse.contents = UIColor(white: 0.72, alpha: 1)
        housing.metalness.contents = 0.2
        housing.roughness.contents = 0.65

        let diffuser = SCNMaterial()
        diffuser.lightingModel = .physicallyBased
        diffuser.diffuse.contents = UIColor(red: 0.88, green: 0.9, blue: 0.86, alpha: 1)
        diffuser.emission.contents = UIColor(red: 0.8, green: 0.84, blue: 0.78, alpha: 1)
        diffuser.roughness.contents = 0.85

        func box(_ width: CGFloat, _ height: CGFloat, _ length: CGFloat,
                 _ position: SCNVector3, _ material: SCNMaterial, radius: CGFloat = 0.003) {
            let geometry = SCNBox(width: width, height: height, length: length, chamferRadius: radius)
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.position = position
            fixture.addChildNode(node)
        }

        // Top touches the ceiling. The lower rim surrounds, rather than covers,
        // the glowing panel, making it read as a manufactured ceiling fixture.
        box(0.42, 0.06, 1.24, SCNVector3(0, -0.03, 0), housing)
        for x: Float in [-0.2, 0.2] {
            box(0.02, 0.045, 1.24, SCNVector3(x, -0.075, 0), housing)
        }
        for z: Float in [-0.605, 0.605] {
            box(0.38, 0.045, 0.03, SCNVector3(0, -0.075, z), housing)
        }
        box(0.376, 0.015, 1.174, SCNVector3(0, -0.08, 0), diffuser)
        // Small retaining clips, typical of older surface-mounted fixtures.
        for z: Float in [-0.42, 0.42] {
            for x: Float in [-0.19, 0.19] {
                box(0.025, 0.008, 0.035, SCNVector3(x, -0.101, z), housing, radius: 0.001)
            }
        }

        // Sept 22 (three-Area cross-section test, replacing the
        // three-Spot prototype): earlier rounds in this function tried
        // a single centered point light (dark bands between fixtures),
        // two omni points (fixed the bands, blew out the ceiling), two
        // downward spots (fixed the ceiling, but scalloped the walls),
        // a single downward `.area` rectangle (smooth, scallop-free,
        // insufficient reach), an Area+Spot 70/30 compound (still
        // scalloped), an Area+Directional diagnostic (no scallops but
        // walls too dark/uniform), and then a three-Spot cross-section
        // prototype (three independently aimed `.spot` lights, one per
        // surface: floor / left wall / right wall). On-device testing
        // of the three-Spot prototype confirmed the three-job
        // architecture works -- each spot clearly does its assigned
        // job -- but Spot's cone geometry produced obvious bright
        // oval/searchlight shapes on both walls.
        //
        // This round changes ONE variable: SPOT vs AREA. The three-job
        // architecture, the three fixture-local positions, and the two
        // wall-aim rotations are all kept exactly as they were in the
        // three-Spot prototype -- only the emitter type (and the
        // properties specific to that type) changes, so this round
        // isolates what a rectangular Area emitter's illumination
        // footprint looks like for the same three aims. Per Eddie:
        // do NOT move the sources closer to their surfaces this round
        // even though Area's reach was previously found wanting --
        // that is a separate, later experiment.
        //
        // Orientation for the two wall Areas: the fixture's local X
        // axis is already established, throughout this function's
        // history, as the corridor's CROSS-hallway (width) axis. Both
        // `.spot` and `.area` (`.rectangle`) lights emit along the
        // node's local -Z axis in SceneKit -- this was independently
        // confirmed on-device for EACH type earlier in this file's
        // history (the eulerAngles.x = -.pi/2 downward test was run
        // and verified separately for `.spot` and for `.area`, not
        // assumed to carry over from one to the other). Because the
        // emission-direction convention is identical between the two
        // types, the rotation that sends local -Z to a given target
        // direction does not depend on which light is attached to the
        // node -- so the exact same rotation representations already
        // derived and device-proven for the three-Spot prototype
        // (eulerAngles.x = -.pi/2 for the floor; the single axis-angle
        // SCNVector4(axis, .pi/2) for left/right, with
        // axis = (-cos(phi), -sign*sin(phi), 0), phi = aim angle off
        // vertical, sign = -1/+1 for left/right) carry over unchanged
        // to point each Area's local -Z along the identical target
        // vectors: Floor = (0,-1,0), Left = (-sin(phi),-cos(phi),0),
        // Right = (sin(phi),-cos(phi),0). See the three-Spot-era
        // derivation this file previously carried (Rodrigues'-formula
        // verified) for the full reasoning; only the emitter changed,
        // not the geometry.
        //
        // Position: all three sources remain at the fixture's existing
        // center point (0, -0.15, 0), unchanged from the three-Spot
        // prototype -- Eddie was explicit that moving an Area closer
        // to its surface is a later, separate experiment, and this
        // round should isolate the emitter-type variable only.
        //
        // Intensity: per Eddie, keeping the SAME diagnostic philosophy
        // as the three-Spot test -- each Area gets the FULL nominal
        // authored intensity (no 1/3 split, no compensation for Area
        // appearing weaker than Spot). DecoratorMode.changeBrightness's
        // existing flat `light.intensity = ...` assignment (via
        // enumerateHierarchy) already applies the full authored value
        // to every light it finds under the fixture, so it needed no
        // code change to cover all three Areas -- see its own comment.
        //
        // Area-specific configuration: `.rectangle` with the SAME
        // extents already proven in the earlier single-area-light
        // (Historical note: earlier rounds in this file used an
        // `.area` `.rectangle` emitter sized 0.376 x 1.174 to match
        // this diffuser panel. This round's single far Spot, below,
        // supersedes that -- see its own comment.)
        let nominalIntensity = AuthoredLightKind.fluorescent.intensity(level: level)
        let fluorescentColor = UIColor(red: 0.96, green: 1, blue: 0.94, alpha: 1)

        // Sept 22 (Eddie: far hidden Spot diagnostic). TEMPORARY --
        // latest round in this function's ongoing fluorescent-lighting
        // investigation (single point -> two omni -> two spot -> single
        // Area -> Area+Spot -> Area+Directional -> three-Spot ->
        // three-Area -> three LOCAL Spots -- see .claude_backups/ for
        // each prior recipe). This round REPLACES the three-source
        // (floor/left-wall/right-wall) recipe with exactly ONE hidden
        // `.spot` source per fixture, moved ~6m straight above the
        // ceiling and aimed straight down, testing whether the cone is
        // broad/soft enough by the time it reaches the hallway to lose
        // the oval/scalloped pool shape every close-range recipe has
        // produced so far. Visible fixture geometry (housing/diffuser
        // above) is completely unchanged -- only the invisible light
        // SOURCE moves. NO ambient light, NO directional light, NO
        // Area lights anywhere in this function -- this is the only
        // light-construction path fluorescent fixtures use. (Sept 22
        // update: a second hidden spot, farBelowSpot, was added below
        // this one to illuminate the ceiling -- see its own comment --
        // so this function now creates exactly TWO SCNLights per
        // fixture, not one. This block -- the above-spot -- is
        // otherwise completely unchanged from when it was the only
        // light here.)
        let verticalOffset: CGFloat = 6.0 // ~20 ft / 6 m above the ceiling, per Eddie
        // Straight-line reach needed: verticalOffset (source down to
        // ceiling level) + wallHeight (ceiling down to floor) + one
        // more cellSize of slack so the lit area continues "modestly
        // beyond" the floor rather than dying exactly at it. Still
        // finite/local -- nowhere near Area's unattenuated floor-wide
        // reach. wallHeight is now a parameter of this function
        // specifically so this distance can be computed exactly rather
        // than guessed.
        let farSpotAttenuationEndDistance = verticalOffset + wallHeight + cellSize
        let farSpotInnerAngle: CGFloat = 60
        let farSpotOuterAngle: CGFloat = 100
        // UNTESTED starting intensity -- the source is now much farther
        // from the hallway (verticalOffset+wallHeight instead of the
        // previous rounds' ~0.15) and spread over a much wider cone
        // (100 degrees instead of 60), both of which dilute how much
        // light actually lands on the hallway. x20 nominal is a
        // reasoned starting guess, not a measured value -- if this
        // reads too dim or too bright on device, only this multiplier
        // needs to change.
        let farSpotIntensity = nominalIntensity * 20

        let farSpot = SCNNode()
        farSpot.name = "fluorescentLightSourceFarAbove"
        farSpot.position = SCNVector3(0, Float(verticalOffset), 0)
        farSpot.eulerAngles.x = -.pi / 2 // straight down -- same proven downward rotation this function has used since its first downward light
        let farSpotLight = SCNLight()
        farSpotLight.type = .spot
        farSpotLight.color = fluorescentColor
        farSpotLight.intensity = farSpotIntensity
        farSpotLight.castsShadow = false
        farSpotLight.attenuationStartDistance = 0
        farSpotLight.attenuationEndDistance = farSpotAttenuationEndDistance
        farSpotLight.attenuationFalloffExponent = 2
        farSpotLight.spotInnerAngle = farSpotInnerAngle
        farSpotLight.spotOuterAngle = farSpotOuterAngle
        farSpot.light = farSpotLight
        fixture.addChildNode(farSpot)

        // Sept 22 (Eddie: two-Spot ceiling-illumination diagnostic).
        // ADDS a second hidden `.spot` per fixture -- the far-above
        // downward spot immediately above is UNCHANGED (position,
        // intensity, cone angles, attenuation, orientation, color: all
        // untouched, confirmed known-good on device for floor/wall
        // illumination). This second spot mirrors it: same fixture-
        // local X/Z, but ~6m BELOW THE FLOOR (not just below the
        // fixture) and aimed straight UP instead of down, so its light
        // travels back up through the floor (shadows are off for every
        // fluorescent light in this function, so nothing blocks it) to
        // illuminate the downward-facing ceiling surface, which
        // nothing else in this recipe reaches. Own clearly-named
        // intensity multiplier (x5, well below the above-spot's x20)
        // so ceiling brightness can be tuned independently later
        // without touching the proven above-spot. Not final tuning --
        // the only question this round asks is whether both spots can
        // coexist without degrading the above-spot's already-confirmed
        // floor/wall result.
        let belowFloorOffset: CGFloat = 6.0 // ~20 ft / 6 m below the FLOOR (i.e. below fixture by wallHeight + 6.0), mirroring verticalOffset above
        // Straight-line reach needed: belowFloorOffset (source up to
        // floor level) + wallHeight (floor up to ceiling) + one more
        // cellSize of slack -- same "modest extra reach" philosophy as
        // farSpotAttenuationEndDistance above, mirrored for the upward
        // direction. Still finite/local, not floor-wide.
        let farBelowAttenuationEndDistance = belowFloorOffset + wallHeight + cellSize
        let farBelowInnerAngle: CGFloat = 60
        let farBelowOuterAngle: CGFloat = 100
        // Deliberately conservative starting multiplier, well below
        // the above-spot's x20 -- per Eddie, the scene already washes
        // out when lighting runs too strong, and the two spots' cones
        // may overlap on some surfaces (e.g. near the fixture itself).
        // Tune this one multiplier after the physical test; nothing
        // else in this block should need to change for that.
        let farBelowIntensityMultiplier: CGFloat = 5
        let farBelowIntensity = nominalIntensity * farBelowIntensityMultiplier

        let farBelowSpot = SCNNode()
        farBelowSpot.name = "fluorescentLightSourceFarBelow"
        farBelowSpot.position = SCNVector3(0, Float(-(wallHeight + belowFloorOffset)), 0)
        // Straight UP -- the exact mirror of the above-spot's straight-
        // down eulerAngles.x = -.pi/2 (reversing the rotation angle
        // reverses which way local -Z, the emission axis, ends up
        // pointing: -pi/2 sends it to world -Y, confirmed on device for
        // the above-spot; +pi/2 sends it to world +Y by the same
        // rotation-matrix relationship, algebraically the mirror image,
        // not a new/unverified convention).
        farBelowSpot.eulerAngles.x = .pi / 2
        let farBelowLight = SCNLight()
        farBelowLight.type = .spot
        farBelowLight.color = fluorescentColor
        farBelowLight.intensity = farBelowIntensity
        farBelowLight.castsShadow = false
        farBelowLight.attenuationStartDistance = 0
        farBelowLight.attenuationEndDistance = farBelowAttenuationEndDistance
        farBelowLight.attenuationFalloffExponent = 2
        farBelowLight.spotInnerAngle = farBelowInnerAngle
        farBelowLight.spotOuterAngle = farBelowOuterAngle
        farBelowSpot.light = farBelowLight
        fixture.addChildNode(farBelowSpot)
        // Still NO ambient light, NO directional light, NO Area lights
        // anywhere in this function -- exactly two SCNLights per
        // fixture now (was one, was three before that).

        // NOTE: DecoratorMode.changeBrightness's live-brightness path
        // still applies a x100 multiplier for `.kind == .fluorescent`
        // (a leftover from the Area-light diagnostic, untouched here
        // per "no unrelated edits") -- a live Decorator brightness edit
        // on Floor 2 during this test would NOT match this
        // construction-time value. Avoid touching fluorescent
        // brightness in Decorator mode during this specific test.
        // Sept 21 (ceiling-selection trap fix): this housing's top face is
        // exactly coincident with the ceiling slab's bottom face (by design,
        // "top touches the ceiling") -- SCNHitTest can't reliably break that
        // tie, which was routing taps aimed at the fixture to the ceiling
        // slab's Add-Light target instead. See makeDecoratorHitProxy's own
        // doc comment (DecoratorMode.swift) for the full explanation; this
        // fixture just needs the same invisible, closer-to-camera hit
        // target as a child, no other change.
        fixture.addChildNode(HallwayScene.makeDecoratorHitProxy(cellSize: cellSize))
        return fixture
    }
}
