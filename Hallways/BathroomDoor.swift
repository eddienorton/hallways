import SceneKit
import UIKit

extension HallwayScene {
    /// A real, hinged, swinging bathroom door -- NOT a decorative
    /// fixture like the office/mail door (MailDelivery.makeRoomDoorNode,
    /// a static box that never opens, always mounted on a genuinely
    /// solid wall) and NOT a small wall-mounted panel like
    /// makeMirrorNode / the mini-game terminal nodes (those sit flush
    /// on an already-solid wall; addDoorFrame there just backfills the
    /// ordinary wall material around their own small footprint). This
    /// fills a real doorway between two open, walkable cells -- see the
    /// "bathroomDoors" loop in HallwayScene.build(fromMaze:...) for the
    /// addDoorFrame call that frames this door's own door-sized opening
    /// right before this function is called to fill it.
    ///
    /// The returned root node IS the hinge -- named
    /// "bathroomDoor_<row>_<col>" so ContentView's tap handling
    /// (bathroomDoorCoordinate) and TapNavigationController.openBathroomDoor
    /// / closeBathroomDoor can find and rotate it directly, same
    /// node-name/walk-the-parent-chain pattern as roomDoorCoordinate/
    /// deliverMail use for the mail door. The visible panel is a CHILD
    /// of the hinge, offset by half its own width so it fills the
    /// doorway when the hinge's rotation is zero (closed) and swings on
    /// that vertical edge once TapNavigationController rotates the
    /// hinge node open or closed. This mirrors makeMirrorNode's own
    /// "root positioned/rotated per direction, children built in
    /// pre-rotation local coordinates" idiom, just with the hinge doing
    /// double duty as both the per-direction placement root AND the
    /// actual rotating pivot. The doorknob and RESTROOM sign are both
    /// children of the PANEL (not the hinge directly), so they swing
    /// and translate with it exactly, through opening AND closing.
    ///
    /// Deliberately distinct from the office/mail door's look -- Eddie,
    /// Sept 14: "It should NOT have a mail slot." A lighter painted
    /// panel instead of MailDelivery's stained wood-grain, and (round
    /// 3) the SAME chrome hardware the office doors use
    /// (makeDoorKnobAssembly below) rather than a separate one-off
    /// handle, so there's one hardware implementation, not two.
    /// `hingeNamePrefix`/`includeSign` (Eddie, Sept 15 -- Window Room):
    /// this exact swinging-door panel is also the Window Room door,
    /// reusing the bathroom door's "proven interaction model exactly"
    /// per that request, minus the RESTROOM sign (a window room isn't
    /// a bathroom) and with its own hinge-node name so
    /// TapNavigationController's window-room open/close logic can find
    /// it the same way bathroomDoorCoordinate finds this one. Every
    /// existing bathroom-door call site is unaffected -- both
    /// parameters default to the exact behavior this function always
    /// had.
    static func makeBathroomDoorPanel(at coord: GridCoordinate, direction: Direction, wallCenterX: CGFloat, wallCenterZ: CGFloat, doorWidth: CGFloat, doorHeight: CGFloat, doorCenterY: CGFloat, hingeNamePrefix: String = "bathroomDoor", includeSign: Bool = true) -> SCNNode {
        let hinge = SCNNode()
        hinge.name = "\(hingeNamePrefix)_\(coord.row)_\(coord.col)"

        let panelMaterial = SCNMaterial()
        panelMaterial.diffuse.contents = UIColor(red: 0.86, green: 0.87, blue: 0.85, alpha: 1)
        panelMaterial.specular.contents = UIColor(white: 0.5, alpha: 1)
        panelMaterial.lightingModel = .physicallyBased
        panelMaterial.roughness.contents = 0.55

        // Slightly narrower/shorter than the doorway itself (a real
        // door always sits inside its frame with a small reveal gap
        // all around, not flush with the rough opening) -- same idea
        // as makeMirrorNode's frame sitting a hair inside its own
        // addDoorFrame backfill.
        let panelWidth = doorWidth * 0.94
        let panelHeight = doorHeight * 0.97
        let panelThickness: CGFloat = 0.06

        let panelGeo: SCNBox
        switch direction {
        case .north, .south:
            // Wall's own width axis is X here (matches addDoorFrame's
            // strip() swap just above in HallwayScene.build), so the
            // panel's wide face spans X, thin face spans Z.
            panelGeo = SCNBox(width: panelWidth, height: panelHeight, length: panelThickness, chamferRadius: 0.01)
        case .east, .west:
            // Wall's width axis is Z here -- swapped from north/south.
            panelGeo = SCNBox(width: panelThickness, height: panelHeight, length: panelWidth, chamferRadius: 0.01)
        }
        panelGeo.materials = [panelMaterial]
        let panel = SCNNode(geometry: panelGeo)

        // Which side of the panel's own thickness axis actually faces
        // the hallway (as opposed to the bathroom on the other side of
        // it) -- derived the same way the swing-angle sign in
        // TapNavigationController.bathroomDoorSwingAngle was: the
        // "along" axis and its offset formula are shared with
        // addDoorFrame/addWall's own hasWallNorth/.../hasWallWest
        // (north's hallway is +Z, south's is -Z, east's is -X, west's
        // is +X). Used to mount BOTH the knob and the RESTROOM sign on
        // the correct, hallway-visible face.
        let hallwayFacingSign: Float
        switch direction {
        case .north, .west: hallwayFacingSign = 1
        case .south, .east: hallwayFacingSign = -1
        }

        // Chrome hardware, shared with the office/mail doors (see
        // makeDoorKnobAssembly below) -- mounted near the panel's free
        // edge (away from the hinge, same as a real door), on the
        // hallway-facing surface. makeDoorKnobAssembly always builds
        // extending along its own local +Z; for the east/west case the
        // panel's thickness axis is X instead, so the whole assembly is
        // rotated 90 degrees before being positioned, same trick the
        // panel geometry itself uses one level up.
        let knob = HallwayScene.makeDoorKnobAssembly()
        let signMaterial = SCNMaterial()
        signMaterial.diffuse.contents = HallwayScene.restroomSignTexture
        signMaterial.lightingModel = .constant
        let signAspect: CGFloat = 340.0 / 240.0
        let signWidth: CGFloat = 0.22
        let signPlane = SCNPlane(width: signWidth, height: signWidth * signAspect)
        signPlane.materials = [signMaterial]
        let sign = SCNNode(geometry: signPlane)
        sign.name = "restroomSign"
        // A believable sign height -- comfortably within the door's
        // own vertical span (panelHeight is ~2.1, centered on the
        // panel's own local origin), well above the knob.
        let signLocalY: Float = 0.45

        // Hinge always sits at the LOWER-coordinate edge of the
        // doorway (lower X for a north/south wall, lower Z for an
        // east/west wall -- the same "along" axis addDoorFrame's own
        // strip() function offsets by +alongOffset from wallCenterX/Z),
        // and the panel is a child positioned at +halfPanelWidth along
        // that same local axis, so with zero hinge rotation the panel
        // spans outward from the hinge across the doorway, filling it.
        let halfW = Float(doorWidth / 2)
        switch direction {
        case .north, .south:
            hinge.position = SCNVector3(Float(wallCenterX) - halfW, Float(doorCenterY), Float(wallCenterZ))
            panel.position = SCNVector3(Float(panelWidth / 2), 0, 0)
            knob.eulerAngles.x = .pi / 2
            knob.position = SCNVector3(Float(panelWidth * 0.85), 0, hallwayFacingSign * Float(panelThickness / 2))
            if hallwayFacingSign < 0 { sign.eulerAngles.y = .pi }
            sign.position = SCNVector3(Float(panelWidth / 2), signLocalY, hallwayFacingSign * Float(panelThickness / 2 + 0.008))
        case .east, .west:
            hinge.position = SCNVector3(Float(wallCenterX), Float(doorCenterY), Float(wallCenterZ) - halfW)
            panel.position = SCNVector3(0, 0, Float(panelWidth / 2))
            knob.eulerAngles.z = .pi / 2
            knob.position = SCNVector3(hallwayFacingSign * Float(panelThickness / 2), 0, Float(panelWidth * 0.85))
            sign.eulerAngles.y = hallwayFacingSign > 0 ? .pi / 2 : -.pi / 2
            sign.position = SCNVector3(hallwayFacingSign * Float(panelThickness / 2 + 0.008), signLocalY, Float(panelWidth / 2))
        }
        panel.addChildNode(knob)
        if includeSign { panel.addChildNode(sign) }
        hinge.addChildNode(panel)

        return hinge
    }

    /// The familiar black-and-white RESTROOM sign -- white female
    /// figure, vertical divider, white male figure, horizontal divider,
    /// "RESTROOM" beneath -- generated the same way every other
    /// in-scene 2D texture here is (UIGraphicsImageRenderer, same
    /// pattern as mirrorPlaceholder/the envelope address label/the
    /// room-door plaque), not a bundled image asset. Eddie, Sept 14:
    /// "It does NOT have to be a pixel-for-pixel reproduction... but it
    /// should immediately read as the SAME familiar black-and-white
    /// RESTROOM sign... Do not creatively reinterpret it." Simple
    /// geometric pictograms deliberately, not custom icon art: a
    /// circle head + widening hem for the female figure, a circle head
    /// + rectangular torso split into two legs for the male figure --
    /// exactly the universal restroom-sign silhouette language, nothing
    /// original layered on top of it. A `static let` so every bathroom
    /// door this floor (or a future one) shares one rendered texture
    /// rather than redrawing it per door.
    static let restroomSignTexture: UIImage = {
        let size = CGSize(width: 240, height: 340)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            UIColor.black.setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()

            let figureBottom: CGFloat = 235
            let headRadius: CGFloat = 20

            // Female pictogram (left) -- circle head, then a silhouette
            // that widens from the shoulders down to the hem (the
            // universal "dress" shape), in contrast with the male
            // figure's straight-sided torso beside it.
            let femaleCX: CGFloat = 64
            let femaleHeadCenterY: CGFloat = 55
            cg.fillEllipse(in: CGRect(x: femaleCX - headRadius, y: femaleHeadCenterY - headRadius, width: headRadius * 2, height: headRadius * 2))
            let dressTop = femaleHeadCenterY + headRadius + 4
            cg.move(to: CGPoint(x: femaleCX - 16, y: dressTop))
            cg.addLine(to: CGPoint(x: femaleCX + 16, y: dressTop))
            cg.addLine(to: CGPoint(x: femaleCX + 34, y: figureBottom))
            cg.addLine(to: CGPoint(x: femaleCX - 34, y: figureBottom))
            cg.closePath()
            cg.fillPath()

            // Male pictogram (right) -- circle head, straight-sided
            // rectangular torso, then split into two leg rectangles
            // with a gap between them down to the same baseline.
            let maleCX: CGFloat = 176
            let maleHeadCenterY: CGFloat = 55
            cg.fillEllipse(in: CGRect(x: maleCX - headRadius, y: maleHeadCenterY - headRadius, width: headRadius * 2, height: headRadius * 2))
            let torsoTop = maleHeadCenterY + headRadius + 4
            let torsoBottom = torsoTop + 90
            cg.fill(CGRect(x: maleCX - 24, y: torsoTop, width: 48, height: torsoBottom - torsoTop))
            let legGap: CGFloat = 8
            let legWidth = (48 - legGap) / 2
            cg.fill(CGRect(x: maleCX - 24, y: torsoBottom, width: legWidth, height: figureBottom - torsoBottom))
            cg.fill(CGRect(x: maleCX - 24 + legWidth + legGap, y: torsoBottom, width: legWidth, height: figureBottom - torsoBottom))

            // Vertical divider between the two figures.
            cg.fill(CGRect(x: size.width / 2 - 2, y: 20, width: 4, height: figureBottom - 20))

            // Horizontal divider below both figures, above the label.
            cg.fill(CGRect(x: 16, y: figureBottom + 12, width: size.width - 32, height: 4))

            let style = NSMutableParagraphStyle()
            style.alignment = .center
            ("RESTROOM" as NSString).draw(in: CGRect(x: 0, y: figureBottom + 26, width: size.width, height: 50), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 30), .foregroundColor: UIColor.white, .paragraphStyle: style, .kern: 1.2
            ])
        }
    }()

    /// Chrome doorknob assembly -- circular rose/base, short stem,
    /// spherical knob -- extending outward along local +Z from its own
    /// origin. Factored out of MailDelivery.makeRoomDoorNode (round 3)
    /// so the office/mail doors and the bathroom door
    /// (makeBathroomDoorPanel above) share ONE hardware implementation
    /// instead of two competing ones, per Eddie's own instruction.
    ///
    /// Eddie, Sept 14 (round 3): the office-door knobs "appear visually
    /// to have regressed" on a later physical-iPhone build even though
    /// "the improved knob geometry/code is STILL present" -- confirmed
    /// true: MailDelivery's rose/stem/knob geometry, positions, and
    /// proportions were all untouched, and there was never a duplicate
    /// old knob anywhere in the codebase (grepped for it). What DID
    /// change in this same project, in an earlier round of THIS
    /// session, was the ceiling spotlight shape (HallwayScene's
    /// "make ceiling lighting read like hallway lighting" pass) --
    /// substantially wider, softer-edged, lower-peak-intensity fixtures
    /// replacing a narrower, brighter, more concentrated cone. The old
    /// knob material was `.blinn` with diffuse/specular/shininess plus
    /// a fake "reflective" gradient texture -- a look that depends on a
    /// sharp, concentrated specular hotspot from a nearby bright light
    /// to read as shiny chrome at all; softening/widening the ceiling
    /// lights removed exactly that hotspot, so the material didn't
    /// change but what it needed to look right did. The fix is on the
    /// material, not the lighting (Eddie: "change lighting... if
    /// absolutely necessary to correct the doorknob material itself" --
    /// the ceiling fixtures themselves are untouched here): switched to
    /// `.physicallyBased` with high metalness/low roughness, the same
    /// convention already used successfully throughout HallwayScene.swift
    /// for every other piece of metal hardware (the mini-game terminal
    /// housings, the picture frames, etc.) -- PBR metal reads as metal
    /// from the ambient/diffuse light it's actually sitting in, not
    /// only from a lucky specular hit, so it holds up under both the
    /// old tight spotlight and the new broad one.
    static func makeDoorKnobAssembly() -> SCNNode {
        let group = SCNNode()
        let chrome = SCNMaterial()
        chrome.lightingModel = .physicallyBased
        chrome.diffuse.contents = UIColor(white: 0.82, alpha: 1)
        chrome.metalness.contents = 1.0
        chrome.roughness.contents = 0.18
        func place(_ geometry: SCNGeometry, name: String, z: Float) -> SCNNode {
            geometry.materials = [chrome]
            let node = SCNNode(geometry: geometry)
            node.name = name
            node.position = SCNVector3(0, 0, z)
            group.addChildNode(node)
            return node
        }
        let rose = place(SCNCylinder(radius: 0.075, height: 0.018), name: "doorKnobRose", z: 0.1)
        rose.eulerAngles.x = .pi / 2
        let stem = place(SCNCylinder(radius: 0.025, height: 0.07), name: "doorKnobStem", z: 0.14)
        stem.eulerAngles.x = .pi / 2
        let knobGeo = SCNSphere(radius: 0.06)
        knobGeo.segmentCount = 32
        let knob = place(knobGeo, name: "doorKnob", z: 0.195)
        knob.scale.z = 0.8
        return group
    }
}
