import SceneKit
import UIKit

// Sept 27 (door cosmetics pass, Eddie: "Make these bastards
// magnificent"). This file adds the persisted style/texture data for
// Room Entrance doors (RoomEntranceDoorStyle, RoomEntranceDoorPlacement)
// and the new architectural leaf geometry that replaces the old plain
// flat-slab look for Room Entrance doors ONLY -- bathroom doors and
// Window Room doors keep calling HallwayScene.makeBathroomDoorPanel
// directly, completely untouched by this pass, so their exact existing
// flat-panel appearance is preserved on purpose.
//
// Deliberately its OWN file rather than folding into BathroomDoor.swift
// or HallwayScene.swift, matching this codebase's own convention of
// giving each door/fixture family its own file (BathroomDoor.swift,
// WindowRoom.swift, MailDelivery.swift).

/// The five programmatic Room Entrance door styles Eddie asked for --
/// "Five is plenty... do NOT go nuts adding twenty styles." String-
/// backed so it round-trips through Codable and a Picker's `tag`
/// unchanged; CaseIterable so the Decorator style chooser never needs
/// its own separate list to keep in sync with this one.
enum RoomEntranceDoorStyle: String, Codable, CaseIterable, Equatable {
    case plain, twoPanel, fourPanel, window, narrowGlass

    var displayName: String {
        switch self {
        case .plain: return "Plain"
        case .twoPanel: return "Two Panel"
        case .fourPanel: return "Four Panel"
        case .window: return "Window"
        case .narrowGlass: return "Narrow Glass"
        }
    }

    /// Window/Narrow Glass have a real see-through opening -- used by
    /// makeRoomEntranceDoorPanel to decide whether resolveThemeImage
    /// needs to run at all when there's otherwise no textured area
    /// (there always is here, both glass styles still have textured
    /// side/lower panels, but this stays available for anything later
    /// that needs to know "does this style have glass" without
    /// re-deriving it from the case list).
    var hasGlass: Bool { self == .window || self == .narrowGlass }
}

/// Persisted cosmetic + placement data for one Room Entrance door.
/// coord/direction are the SAME two values roomEntranceDoors has always
/// kept (a plain Direction, pre-cosmetics); style/textureName are new,
/// both defaulted so an old floor's Room Entrances (saved by either the
/// 2D Editor or the 3D Decorator before this pass existed) decode
/// safely with the default appearance -- "Do not break existing saved
/// floors." Hand-written Codable rather than synthesized, the SAME
/// reason RoomDoorPlacement.isDecorative is (MailDelivery.swift): a
/// non-optional-with-default property (style) is NOT auto-decoded as
/// optional by Swift's synthesized Decodable, only a true Optional
/// (textureName) is -- so both need an explicit decodeIfPresent(...)
/// ?? default to read an old floor whose JSON is missing these keys
/// entirely.
struct RoomEntranceDoorPlacement: Codable, Equatable {
    var coord: GridCoordinate
    var direction: Direction
    var style: RoomEntranceDoorStyle = .plain
    var textureName: String? = nil

    enum CodingKeys: String, CodingKey {
        case coord, direction, style, textureName
    }

    init(coord: GridCoordinate, direction: Direction, style: RoomEntranceDoorStyle = .plain, textureName: String? = nil) {
        self.coord = coord
        self.direction = direction
        self.style = style
        self.textureName = textureName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        coord = try container.decode(GridCoordinate.self, forKey: .coord)
        direction = try container.decode(Direction.self, forKey: .direction)
        style = try container.decodeIfPresent(RoomEntranceDoorStyle.self, forKey: .style) ?? .plain
        textureName = try container.decodeIfPresent(String.self, forKey: .textureName)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(coord, forKey: .coord)
        try container.encode(direction, forKey: .direction)
        try container.encode(style, forKey: .style)
        try container.encodeIfPresent(textureName, forKey: .textureName)
    }
}

/// One box in a Room Entrance leaf's decorative assembly, expressed in
/// the leaf's own canonical (u = wide axis, v = height axis, w =
/// thickness axis) space -- makeRoomEntranceDoorPanel maps u/w onto the
/// real X/Z world axes per direction (u->X,w->Z for north/south;
/// u->Z,w->X for east/west), the same swap addDoorFrame/panelGeo
/// already use, so the per-style layout functions below never need a
/// north/south vs east/west branch of their own.
private struct LeafBoxSpec {
    var centerU: CGFloat
    var centerV: CGFloat
    var centerW: CGFloat
    var sizeU: CGFloat
    var sizeV: CGFloat
    var sizeW: CGFloat
    var kind: Kind
    enum Kind { case frame, backing, glass }
}

/// Builds the fixed perimeter frame (top/bottom rail, left/right
/// stile) every style shares, always at the leaf's FULL thickness so
/// its outer silhouette exactly matches the door's original flat-slab
/// bounding box (never protrudes past the doorway opening) -- only the
/// interior fill (recessed backing/glass, proud interior dividers)
/// differs per style.
private func leafPerimeterFrame(width: CGFloat, height: CGFloat, thickness: CGFloat, stileW: CGFloat, railH: CGFloat) -> [LeafBoxSpec] {
    [
        LeafBoxSpec(centerU: 0, centerV: height / 2 - railH / 2, centerW: 0, sizeU: width, sizeV: railH, sizeW: thickness, kind: .frame),
        LeafBoxSpec(centerU: 0, centerV: -height / 2 + railH / 2, centerW: 0, sizeU: width, sizeV: railH, sizeW: thickness, kind: .frame),
        LeafBoxSpec(centerU: -width / 2 + stileW / 2, centerV: 0, centerW: 0, sizeU: stileW, sizeV: height - 2 * railH, sizeW: thickness, kind: .frame),
        LeafBoxSpec(centerU: width / 2 - stileW / 2, centerV: 0, centerW: 0, sizeU: stileW, sizeV: height - 2 * railH, sizeW: thickness, kind: .frame),
    ]
}

/// Derives the full box list for one door leaf, given its style. All
/// five styles share the same perimeter (leafPerimeterFrame) and the
/// same "recessed interior fill sits `reveal` behind the frame's own
/// front face" depth convention -- Eddie: "keep depth SUBTLE...
/// architectural detail, not a medieval castle door." Interior
/// dividers (mid rail / mid stile / mullions) are proud, full
/// thickness, same as the perimeter; backing/glass fills are recessed.
private func leafBoxes(width: CGFloat, height: CGFloat, thickness: CGFloat, style: RoomEntranceDoorStyle) -> [LeafBoxSpec] {
    let stileW = width * 0.10
    let railH = height * 0.09
    var boxes = leafPerimeterFrame(width: width, height: height, thickness: thickness, stileW: stileW, railH: railH)

    let reveal = thickness * 0.3
    let backingDepth = thickness - reveal
    let backingW: CGFloat = -reveal / 2

    let iw = width - 2 * stileW
    let ih = height - 2 * railH

    switch style {
    case .plain:
        boxes.append(LeafBoxSpec(centerU: 0, centerV: 0, centerW: backingW, sizeU: iw, sizeV: ih, sizeW: backingDepth, kind: .backing))

    case .twoPanel, .window:
        let dh = height * 0.05
        boxes.append(LeafBoxSpec(centerU: 0, centerV: 0, centerW: 0, sizeU: width, sizeV: dh, sizeW: thickness, kind: .frame))
        let cellV = (ih + dh) / 4
        let cellH = (ih - dh) / 2
        let upperKind: LeafBoxSpec.Kind = style == .window ? .glass : .backing
        boxes.append(LeafBoxSpec(centerU: 0, centerV: cellV, centerW: backingW, sizeU: iw, sizeV: cellH, sizeW: backingDepth, kind: upperKind))
        boxes.append(LeafBoxSpec(centerU: 0, centerV: -cellV, centerW: backingW, sizeU: iw, sizeV: cellH, sizeW: backingDepth, kind: .backing))

    case .fourPanel:
        let dh = height * 0.05
        let dw = width * 0.05
        boxes.append(LeafBoxSpec(centerU: 0, centerV: 0, centerW: 0, sizeU: width, sizeV: dh, sizeW: thickness, kind: .frame))
        boxes.append(LeafBoxSpec(centerU: 0, centerV: 0, centerW: 0, sizeU: dw, sizeV: ih, sizeW: thickness, kind: .frame))
        let cellU = (iw + dw) / 4
        let cellV = (ih + dh) / 4
        let sizeU = (iw - dw) / 2
        let sizeV = (ih - dh) / 2
        for signU: CGFloat in [-1, 1] {
            for signV: CGFloat in [-1, 1] {
                boxes.append(LeafBoxSpec(centerU: signU * cellU, centerV: signV * cellV, centerW: backingW, sizeU: sizeU, sizeV: sizeV, sizeW: backingDepth, kind: .backing))
            }
        }

    case .narrowGlass:
        let glassW = iw * 0.22
        let mullionW = width * 0.05
        let sideW = (iw - glassW - 2 * mullionW) / 2
        let mullionU = glassW / 2 + mullionW / 2
        let sideU = glassW / 2 + mullionW + sideW / 2
        boxes.append(LeafBoxSpec(centerU: -mullionU, centerV: 0, centerW: 0, sizeU: mullionW, sizeV: ih, sizeW: thickness, kind: .frame))
        boxes.append(LeafBoxSpec(centerU: mullionU, centerV: 0, centerW: 0, sizeU: mullionW, sizeV: ih, sizeW: thickness, kind: .frame))
        boxes.append(LeafBoxSpec(centerU: -sideU, centerV: 0, centerW: backingW, sizeU: sideW, sizeV: ih, sizeW: backingDepth, kind: .backing))
        boxes.append(LeafBoxSpec(centerU: sideU, centerV: 0, centerW: backingW, sizeU: sideW, sizeV: ih, sizeW: backingDepth, kind: .backing))
        boxes.append(LeafBoxSpec(centerU: 0, centerV: 0, centerW: backingW, sizeU: glassW, sizeV: ih, sizeW: backingDepth, kind: .glass))
    }
    return boxes
}

extension HallwayScene {
    /// Fallback tint when a door has no texture (Default) or its saved
    /// textureName no longer resolves to a bundle image -- a warm
    /// neutral wood tone, deliberately not the old flat off-white
    /// "sheetrock" color this pass replaces. Still used as the
    /// fallback for OLD saved Room Entrances (no cosmetic fields at
    /// all) so they display safely without ever touching the
    /// resolveThemeImage/nil path.
    static let roomEntranceDoorFallbackColor = UIColor(red: 0.5, green: 0.37, blue: 0.26, alpha: 1)

    /// One material referencing an ALREADY-decoded, shared UIImage.
    /// Callers decode via resolveThemeImage(textureName) exactly ONCE
    /// per door (see makeRoomEntranceDoorPanel below) and pass that
    /// same UIImage instance into every call here for that door's
    /// panels/frame pieces, so a single door with many small geometry
    /// pieces never re-decodes its texture file per piece -- Eddie,
    /// Sept 27: "share the decoded UIImage... rather than repeatedly
    /// decoding the same source asset," the exact repeated-decode
    /// mistake this sidesteps. Mirrors makeSurfaceMaterial's own
    /// wrap/roughness/lighting conventions (physicallyBased, metalness
    /// 0, tiled) WITHOUT touching that private function at all --
    /// doors simply have their own tiny material path.
    static func makeDoorPanelMaterial(image: UIImage?, darken: Bool = false, roughness: CGFloat = 0.82) -> SCNMaterial {
        let m = SCNMaterial()
        if let image {
            m.diffuse.contents = image
            m.diffuse.wrapS = .repeat
            m.diffuse.wrapT = .repeat
            m.diffuse.contentsTransform = SCNMatrix4MakeScale(1.6, 1.6, 1)
        } else {
            m.diffuse.contents = roomEntranceDoorFallbackColor
        }
        if darken {
            // Subtle contrast between the proud frame/molding and the
            // recessed panel fill -- Eddie: "slight material contrast."
            // A cheap multiply tint, no second image/decode involved.
            m.multiply.contents = UIColor(white: 0.78, alpha: 1)
        }
        m.lightingModel = .physicallyBased
        m.roughness.contents = roughness
        m.metalness.contents = 0.0
        m.specular.contents = UIColor(white: 0.3, alpha: 1)
        return m
    }

    /// Real, plain SceneKit transparency -- no refraction, no blur, no
    /// environment reflection map, exactly what Eddie asked for
    /// ("convincing architectural glass, not Pixar"). Because the
    /// space on the other side of the door is genuinely already built
    /// (both cells either side of a Room Entrance are always ordinary,
    /// fully-built open cells), a plain transparent material here is
    /// enough to see the ACTUAL scene beyond -- nothing needs to be
    /// faked.
    static func makeDoorGlassMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(red: 0.86, green: 0.93, blue: 0.97, alpha: 1)
        // Sept 27 (glass transparency fix): `transparency` is the
        // scalar this codebase has ALREADY confirmed reliably drives
        // real SceneKit transparency -- see HallwayScene.
        // makeDecoratorHitProxy (DecoratorMode.swift), whose own
        // comment reads "transparency = 0 is the actual mechanism that
        // makes this invisible... diffuse alpha alone is not reliably
        // respected." The earlier version of this material set this
        // same scalar (0.32) but left writesToDepthBuffer at its
        // default (true) -- the missing piece, matching the hit
        // proxy's own working recipe of pairing `transparency` with an
        // explicit depth-buffer setting. isDoubleSided so the pane
        // reads correctly from either side of the door. No frosting,
        // no blur, no refraction, no reflection map -- just a mostly-
        // clear, faintly cool-tinted pane with a touch of specular
        // sheen; visibility THROUGH it matters far more than the pane
        // itself.
        m.transparency = 0.15
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        m.roughness.contents = 0.08
        m.metalness.contents = 0.0
        m.specular.contents = UIColor(white: 0.95, alpha: 1)
        return m
    }

    /// The Room Entrance's own visual construction -- Sept 27 cosmetics
    /// pass. Same hinge/panel/knob contract as makeBathroomDoorPanel
    /// (hinge named "roomEntranceDoor_<row>_<col>", same hinge/panel
    /// position formulas so TapNavigationController's swing/gating
    /// logic -- which only ever looks the hinge up by name and rotates
    /// it -- needs no changes at all and has no idea the panel it's
    /// rotating is now a compound assembly instead of one flat box; the
    /// knob is a child of the panel exactly as before so it swings and
    /// translates with it). Deliberately a SEPARATE function from
    /// makeBathroomDoorPanel (not a modification of it) so bathroom
    /// doors and Window Room doors, which still call
    /// makeBathroomDoorPanel directly, keep their exact existing
    /// flat-panel look, completely untouched by this pass.
    static func makeRoomEntranceDoorPanel(at coord: GridCoordinate, direction: Direction, wallCenterX: CGFloat, wallCenterZ: CGFloat, doorWidth: CGFloat, doorHeight: CGFloat, doorCenterY: CGFloat, style: RoomEntranceDoorStyle, textureName: String?) -> SCNNode {
        let hinge = SCNNode()
        hinge.name = "roomEntranceDoor_\(coord.row)_\(coord.col)"

        // Sept 27 (forensic leak fix): the previous 0.94/0.97
        // FRACTIONAL reveal was borrowed unmodified from
        // makeBathroomDoorPanel, where -- at this door's actual
        // dimensions (doorWidth=1.0, doorHeight=2.2, identical to
        // bathroomDoorWidth/Height) -- it has always produced a real,
        // unobstructed 0.06m gap on the latch side (doorWidth minus
        // panelWidth, entirely un-split by the hinge/panel position
        // formulas below) and a 0.033m gap top AND bottom ((doorHeight
        // minus panelHeight)/2 each). Traced buildDoorFrame's own
        // strip() offsets (HallwayScene.swift): its side/top/bottom
        // wall strips abut the doorway bounds EXACTLY (+-doorWidth/2,
        // +-doorHeight/2 from doorCenterY) with no overlap onto the
        // leaf, and addDoorFrame never builds any perpendicular
        // jamb-return surface bridging a reveal gap back to solid
        // geometry -- so that gap has always been a real hole clean
        // through the wall's own thickness, on every Room Entrance
        // door (and every bathroom/window-room door, which share this
        // exact formula), just visually easy to miss at the old flat
        // door's off-white color. A small FIXED absolute reveal
        // (independent of doorWidth/doorHeight, unlike a percentage)
        // closes it down to a believable sliver on all four sides
        // instead of an obvious architectural leak -- the hinge/pivot
        // formulas just below are untouched, so swing behavior is
        // identical.
        let reveal: CGFloat = 0.02
        let panelWidth = doorWidth - reveal
        let panelHeight = doorHeight - 2 * reveal
        let panelThickness: CGFloat = 0.06

        // Decoded ONCE for this whole door, shared across every piece
        // below -- see makeDoorPanelMaterial's doc comment.
        let sharedImage = HallwayScene.resolveThemeImage(textureName)
        let backingMaterial = HallwayScene.makeDoorPanelMaterial(image: sharedImage, darken: false)
        let frameMaterial = HallwayScene.makeDoorPanelMaterial(image: sharedImage, darken: true)

        let panel = SCNNode()

        func place(_ spec: LeafBoxSpec) {
            // Sept 27 (forensic glass fix): a `.glass` spec now builds
            // NO geometry at all -- a genuine, literal opening, not a
            // material trick. The previous attempt (transparency=0.15
            // + writesToDepthBuffer=false, reasoned from
            // HallwayScene.makeDecoratorHitProxy's own working
            // invisibility recipe) still rendered as a near-opaque
            // white pane on-device. Re-tracing that precedent found
            // the mismatch: the hit proxy never sets lightingModel at
            // all, so it runs under SceneKit's default `.blinn`, where
            // `transparency` is a simple, reliable alpha multiplier --
            // our glass material instead sets `.physicallyBased`
            // (needed for its roughness/metalness/specular sheen), a
            // completely different shading pipeline this codebase has
            // no other proven transparency precedent for (the Window
            // Room's own "glass," in WindowRoom.swift, isn't real
            // transparency either -- it's an opaque SCNPlane textured
            // with a static photo under `.constant` lighting, not a
            // see-through view of real geometry). Rather than a third
            // unverifiable numeric guess at PBR transparency tuning,
            // this leaves an actual hole: Eddie's own explicitly
            // preferred outcome ("an actual open hole is preferable to
            // an opaque white fake window... we can add beautiful
            // glass later"). The real 3D room beyond is always
            // genuinely built (a Room Entrance only ever connects two
            // already-open cells), so the opening shows the real scene
            // with total certainty -- there is nothing there to
            // misconfigure. makeDoorGlassMaterial() is left defined,
            // just unused, for whenever real glass gets revisited.
            if case .glass = spec.kind { return }
            let box: SCNBox
            let position: SCNVector3
            switch direction {
            case .north, .south:
                // Wall's own width axis is X here, thin axis Z --
                // matches panelGeo's own switch in makeBathroomDoorPanel.
                box = SCNBox(width: spec.sizeU, height: spec.sizeV, length: spec.sizeW, chamferRadius: 0)
                position = SCNVector3(Float(spec.centerU), Float(spec.centerV), Float(spec.centerW))
            case .east, .west:
                // Wall's width axis is Z here, thin axis X -- swapped.
                box = SCNBox(width: spec.sizeW, height: spec.sizeV, length: spec.sizeU, chamferRadius: 0)
                position = SCNVector3(Float(spec.centerW), Float(spec.centerV), Float(spec.centerU))
            }
            let material: SCNMaterial
            switch spec.kind {
            case .frame: material = frameMaterial
            case .backing: material = backingMaterial
            case .glass: material = backingMaterial // unreachable -- .glass already returned above
            }
            box.materials = [material]
            let node = SCNNode(geometry: box)
            node.position = position
            panel.addChildNode(node)
        }
        for spec in leafBoxes(width: panelWidth, height: panelHeight, thickness: panelThickness, style: style) {
            place(spec)
        }

        // Hardware -- same shared chrome assembly the bathroom/office
        // doors use, mounted the identical way makeBathroomDoorPanel
        // does (hallway-facing side, near the panel's free edge).
        let hallwayFacingSign: Float
        switch direction {
        case .north, .west: hallwayFacingSign = 1
        case .south, .east: hallwayFacingSign = -1
        }
        let knob = HallwayScene.makeDoorKnobAssembly()

        // Hinge always sits at the lower-coordinate edge of the
        // doorway, panel is a child offset by +halfPanelWidth along
        // that same local axis -- identical formula to
        // makeBathroomDoorPanel so the doorway-filling/swing behavior
        // is pixel-identical.
        let halfW = Float(doorWidth / 2)
        switch direction {
        case .north, .south:
            hinge.position = SCNVector3(Float(wallCenterX) - halfW, Float(doorCenterY), Float(wallCenterZ))
            panel.position = SCNVector3(Float(panelWidth / 2), 0, 0)
            knob.eulerAngles.x = .pi / 2
            knob.position = SCNVector3(Float(panelWidth * 0.85), 0, hallwayFacingSign * Float(panelThickness / 2))
        case .east, .west:
            hinge.position = SCNVector3(Float(wallCenterX), Float(doorCenterY), Float(wallCenterZ) - halfW)
            panel.position = SCNVector3(0, 0, Float(panelWidth / 2))
            knob.eulerAngles.z = .pi / 2
            knob.position = SCNVector3(hallwayFacingSign * Float(panelThickness / 2), 0, Float(panelWidth * 0.85))
        }
        panel.addChildNode(knob)
        hinge.addChildNode(panel)

        return hinge
    }
}
