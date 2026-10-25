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
    case plain, twoPanel, fourPanel, window, narrowGlass, doubleGlass

    var displayName: String {
        switch self {
        case .plain: return "Plain"
        case .twoPanel: return "Two Panel"
        case .fourPanel: return "Four Panel"
        case .window: return "Window"
        case .narrowGlass: return "Narrow Glass"
        case .doubleGlass: return "Double Glass"
        }
    }

    /// Window/Narrow Glass have a real see-through opening -- used by
    /// makeRoomEntranceDoorPanel to decide whether resolveThemeImage
    /// needs to run at all when there's otherwise no textured area
    /// (there always is here, both glass styles still have textured
    /// side/lower panels, but this stays available for anything later
    /// that needs to know "does this style have glass" without
    /// re-deriving it from the case list).
    var hasGlass: Bool { self == .window || self == .narrowGlass || self == .doubleGlass }

    /// Oct 5 (Administration): the doorway opening each style needs.
    /// Every single-leaf style keeps the original 1.0 x 2.2 m opening;
    /// Double Glass is a contemporary pair of full-height glass leaves.
    var doorWidth: CGFloat { self == .doubleGlass ? 1.9 : 1.0 }
    var doorHeight: CGFloat { self == .doubleGlass ? 2.35 : 2.2 }
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
    /// Oct 5 (Administration): an optional department name, lettered on a
    /// sign above the entrance on its approach side. Absent on older floors.
    var label: String? = nil

    enum CodingKeys: String, CodingKey {
        case coord, direction, style, textureName, label
    }

    init(coord: GridCoordinate, direction: Direction, style: RoomEntranceDoorStyle = .plain, textureName: String? = nil,
         label: String? = nil) {
        self.coord = coord
        self.direction = direction
        self.style = style
        self.textureName = textureName
        self.label = label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        coord = try container.decode(GridCoordinate.self, forKey: .coord)
        direction = try container.decode(Direction.self, forKey: .direction)
        style = try container.decodeIfPresent(RoomEntranceDoorStyle.self, forKey: .style) ?? .plain
        textureName = try container.decodeIfPresent(String.self, forKey: .textureName)
        label = try container.decodeIfPresent(String.self, forKey: .label)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(coord, forKey: .coord)
        try container.encode(direction, forKey: .direction)
        try container.encode(style, forKey: .style)
        try container.encodeIfPresent(textureName, forKey: .textureName)
        try container.encodeIfPresent(label, forKey: .label)
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

    case .twoPanel, .window, .doubleGlass:   // doubleGlass never reaches here (own builder)
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
    static func makeRoomEntranceDoorPanel(at coord: GridCoordinate, direction: Direction, wallCenterX: CGFloat, wallCenterZ: CGFloat, doorWidth: CGFloat, doorHeight: CGFloat, doorCenterY: CGFloat, style: RoomEntranceDoorStyle, textureName: String?, label: String? = nil) -> SCNNode {
        if style == .doubleGlass {
            return makeDoubleGlassEntrance(at: coord, direction: direction, wallCenterX: wallCenterX, wallCenterZ: wallCenterZ,
                                           doorWidth: doorWidth, doorHeight: doorHeight, doorCenterY: doorCenterY, label: label)
        }
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
            // Oct 18 (knob orientation): the assembly is built along its own +Z with
            // its rose 0.09 m out from its origin (it was made for the mail door). Face
            // it out of the hallway-side face -- +Z already, or turned round -- and set
            // it back 0.09 so the rose sits on that face. (Rotating about X had it
            // pointing down the face; about Z, lying along the door's width.)
            knob.eulerAngles.y = hallwayFacingSign > 0 ? 0 : .pi
            // Oct 18 (wandering knob): the panel's own origin is its CENTRE (it hangs
            // at +panelWidth/2 from the hinge), so 85% of the way from the hinge is
            // +0.35 x panelWidth here -- 0.85 put the knob 0.35 of a door past the
            // free edge, on the wall.
            knob.position = SCNVector3(Float(panelWidth * 0.35), 0, hallwayFacingSign * (Float(panelThickness / 2) - HallwayScene.knobRoseSetback))
        case .east, .west:
            hinge.position = SCNVector3(Float(wallCenterX), Float(doorCenterY), Float(wallCenterZ) - halfW)
            panel.position = SCNVector3(0, 0, Float(panelWidth / 2))
            knob.eulerAngles.y = hallwayFacingSign > 0 ? .pi / 2 : -.pi / 2        // (+Z turned to +X / -X)
            knob.position = SCNVector3(hallwayFacingSign * (Float(panelThickness / 2) - HallwayScene.knobRoseSetback), 0, Float(panelWidth * 0.35))   // (Oct 18: see above)
        }
        panel.addChildNode(knob)
        hinge.addChildNode(panel)

        return hinge
    }
}

extension HallwayScene {
    /// Oct 5 (Administration): a dark wall sign with light lettering (e.g.
    /// ADMINISTRATION), 1.75 m x 0.3 m, its readable face on local +Z.
    static func makeLetteredSignNode(_ text: String) -> SCNNode {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1400, height: 240)).image { _ in
            UIColor(red: 0.12, green: 0.10, blue: 0.08, alpha: 1).setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 1400, height: 240))
            UIColor(red: 0.78, green: 0.66, blue: 0.42, alpha: 1).setStroke()
            UIBezierPath(rect: CGRect(x: 14, y: 14, width: 1372, height: 212)).stroke()
            let style = NSMutableParagraphStyle(); style.alignment = .center
            var size: CGFloat = 150
            var attributes: [NSAttributedString.Key: Any] = [:]
            repeat {
                attributes = [.font: UIFont.systemFont(ofSize: size, weight: .semibold), .kern: size * 0.08,
                              .foregroundColor: UIColor(red: 0.93, green: 0.86, blue: 0.68, alpha: 1), .paragraphStyle: style]
                size -= 6
            } while (text as NSString).size(withAttributes: attributes).width > 1300 && size > 40
            let height = (text as NSString).size(withAttributes: attributes).height
            (text as NSString).draw(in: CGRect(x: 0, y: (240 - height) / 2, width: 1400, height: height), withAttributes: attributes)
        }
        let face = SCNMaterial()
        face.diffuse.contents = image
        face.lightingModel = .constant
        let edge = SCNMaterial()
        edge.diffuse.contents = UIColor(red: 0.12, green: 0.10, blue: 0.08, alpha: 1)
        edge.lightingModel = .constant
        let box = SCNBox(width: 1.75, height: 0.3, length: 0.03, chamferRadius: 0.004)
        // SCNBox material order: front (+Z), right, back, left, top, bottom.
        box.materials = [face, edge, edge, edge, edge, edge]
        let node = SCNNode(geometry: box)
        node.name = "letteredSign"
        return node
    }
}

extension HallwayScene {
    /// Oct 5 (Administration): the Double Glass Room Entrance -- a
    /// contemporary pair of glass leaves in slim dark-bronze aluminium
    /// frames, vertical bar pulls at the meeting stiles, and an optional
    /// name (`label`) lettered on the glass at eye height, split across the
    /// two leaves at the meeting stiles the way office glass doors are.
    ///
    /// Same contract as the single-leaf styles: the node named
    /// "roomEntranceDoor_<row>_<col>" is the (viewer-independent) low-side
    /// leaf's hinge and swings exactly like every Room Entrance; its mirror
    /// leaf is "roomEntranceDoorPair_<row>_<col>", which
    /// TapNavigationController swings by the opposite angle alongside it.
    /// Glass is a literal opening (no geometry), as in the other styles.
    static func makeDoubleGlassEntrance(at coord: GridCoordinate, direction: Direction, wallCenterX: CGFloat, wallCenterZ: CGFloat,
                                        doorWidth: CGFloat, doorHeight: CGFloat, doorCenterY: CGFloat, label: String?) -> SCNNode {
        let container = SCNNode()
        container.name = "roomEntranceDoorLeaves_\(coord.row)_\(coord.col)"
        let reveal: CGFloat = 0.02
        let meetingGap: CGFloat = 0.012
        let halfW = doorWidth / 2
        let leafW = halfW - reveal / 2 - meetingGap / 2
        let leafH = doorHeight - 2 * reveal
        let thickness: CGFloat = 0.05
        let stile: CGFloat = 0.055
        let topRail: CGFloat = 0.075
        let kickRail: CGFloat = 0.2
        let alongX = direction == .north || direction == .south

        let frameMaterial = SCNMaterial()
        frameMaterial.lightingModel = .physicallyBased
        frameMaterial.diffuse.contents = UIColor(red: 0.2, green: 0.18, blue: 0.16, alpha: 1)
        frameMaterial.metalness.contents = 0.65
        frameMaterial.roughness.contents = 0.38
        let glassMaterial = SCNMaterial()
        glassMaterial.lightingModel = .blinn
        glassMaterial.diffuse.contents = UIColor(red: 0.42, green: 0.46, blue: 0.44, alpha: 1)
        glassMaterial.specular.contents = UIColor(white: 0.9, alpha: 1)
        glassMaterial.shininess = 0.85
        glassMaterial.fresnelExponent = 1.6
        glassMaterial.transparency = 0.32
        glassMaterial.isDoubleSided = true
        glassMaterial.writesToDepthBuffer = false
        let pullMaterial = SCNMaterial()
        pullMaterial.lightingModel = .physicallyBased
        pullMaterial.diffuse.contents = UIColor(white: 0.78, alpha: 1)
        pullMaterial.metalness.contents = 0.9
        pullMaterial.roughness.contents = 0.25

        /// A box in leaf space (u along the wall from the hinge, v up from
        /// the doorway centre line, w through the wall).
        func box(_ u: CGFloat, _ v: CGFloat, _ w: CGFloat, _ su: CGFloat, _ sv: CGFloat, _ sw: CGFloat,
                 _ material: SCNMaterial, into parent: SCNNode) {
            let geometry = alongX ? SCNBox(width: su, height: sv, length: sw, chamferRadius: 0.003)
                                  : SCNBox(width: sw, height: sv, length: su, chamferRadius: 0.003)
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.position = alongX ? SCNVector3(Float(u), Float(v), Float(w)) : SCNVector3(Float(w), Float(v), Float(u))
            parent.addChildNode(node)
        }

        // The approaching viewer stands in `coord`, facing `direction`;
        // their side of the glass is viewerFaceSign along the wall normal.
        let yaw = direction.yaw
        let viewerFaceSign: CGFloat = -CGFloat(alongX ? direction.delta.row : direction.delta.col)
        let text = (label ?? "").trimmingCharacters(in: .whitespaces)
        // One gold seal image, drawn once and applied whole to each pane.
        let emblem = emblemImage(width: leafW - 2 * stile - 0.03, height: 0.34)

        for (low, hingeSign) in [(true, CGFloat(-1)), (false, CGFloat(1))] {
            let hinge = SCNNode()
            hinge.name = low ? "roomEntranceDoor_\(coord.row)_\(coord.col)" : "roomEntranceDoorPair_\(coord.row)_\(coord.col)"
            let hingeU = hingeSign * (halfW - reveal / 2)
            hinge.position = alongX ? SCNVector3(Float(wallCenterX + hingeU), Float(doorCenterY), Float(wallCenterZ))
                                    : SCNVector3(Float(wallCenterX), Float(doorCenterY), Float(wallCenterZ + hingeU))
            let leaf = SCNNode()
            let leafCenterU = -hingeSign * leafW / 2       // the leaf extends from its hinge toward the middle
            leaf.position = alongX ? SCNVector3(Float(leafCenterU), 0, 0) : SCNVector3(0, 0, Float(leafCenterU))
            // Frame: two stiles, top rail, tall kick rail; glass = opening.
            box(-leafW / 2 + stile / 2, 0, 0, stile, leafH, thickness, frameMaterial, into: leaf)
            box(leafW / 2 - stile / 2, 0, 0, stile, leafH, thickness, frameMaterial, into: leaf)
            box(0, leafH / 2 - topRail / 2, 0, leafW - 2 * stile, topRail, thickness, frameMaterial, into: leaf)
            box(0, -leafH / 2 + kickRail / 2, 0, leafW - 2 * stile, kickRail, thickness, frameMaterial, into: leaf)
            // Oct 5 (glass with presence): a real pane in the opening --
            // smoky bronze tint, a specular sheen that catches the ceiling
            // lights, about a third opaque. Blinn + `transparency` is the
            // combination this codebase has proven renders as see-through
            // on device (the PBR attempt rendered opaque white; see place()).
            let glassH = leafH - topRail - kickRail
            let pane = SCNNode(geometry: alongX ? SCNBox(width: leafW - 2 * stile, height: glassH, length: 0.012, chamferRadius: 0)
                                                : SCNBox(width: 0.012, height: glassH, length: leafW - 2 * stile, chamferRadius: 0))
            pane.geometry?.materials = [glassMaterial]
            pane.position = SCNVector3(0, Float((kickRail - topRail) / 2), 0)
            pane.name = "roomEntranceDoorGlass"
            pane.renderingOrder = 10
            leaf.addChildNode(pane)
            // Vertical bar pulls near the meeting stile, both faces.
            let meetingU = -hingeSign * (leafW / 2 - stile - 0.07)
            for face in [CGFloat(1), -1] {
                box(meetingU, 0.05, face * (thickness / 2 + 0.045), 0.028, 0.75, 0.028, pullMaterial, into: leaf)
                for end in [CGFloat(-0.3), 0.3] {
                    box(meetingU, 0.05 + end, face * (thickness / 2 + 0.022), 0.018, 0.018, 0.045, pullMaterial, into: leaf)
                }
            }
            // Oct 5: each pane carries its own complete gold seal -- nothing
            // crosses the meeting stiles; the department name lives on the
            // fascia above the opening (makeEntranceFascia).
            let glassW = leafW - 2 * stile
            let emblemH: CGFloat = 0.34
            let plane = SCNPlane(width: glassW - 0.03, height: emblemH)
            plane.materials = [letteringMaterial(emblem, uScale: 1, uOffset: 0)]
            let decal = SCNNode(geometry: plane)
            decal.name = "roomEntranceDoorEmblem"
            decal.renderingOrder = 11                    // drawn after (over) the glass pane
            decal.eulerAngles.y = Float(yaw)            // its face toward the approach side (mirrored from inside, as real gilt is)
            let w = viewerFaceSign * 0.008               // just on the approach face of the pane, inside the frame depth
            let v: CGFloat = 1.45 - doorCenterY
            decal.position = alongX ? SCNVector3(0, Float(v), Float(w)) : SCNVector3(Float(w), Float(v), 0)
            leaf.addChildNode(decal)
            hinge.addChildNode(leaf)
            container.addChildNode(hinge)
        }
        diag("roomEntrance.doubleGlassBuilt", ["coord": "\(coord.row),\(coord.col)", "direction": "\(direction)",
                                                "width": Double(doorWidth), "label": text])
        return container
    }

    /// The pane graphic: a small gilt seal -- double ring around a
    /// pedimented-portico glyph (the building's institutional mark) --
    /// with a thin gold rule running from each side of the seal to just
    /// short of the pane's edges. Transparent background.
    private static func emblemImage(width: CGFloat, height: CGFloat) -> UIImage {
        let ppm: CGFloat = 800
        let size = CGSize(width: width * ppm, height: height * ppm)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let gold = UIColor(red: 0.93, green: 0.8, blue: 0.5, alpha: 1)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.setShadow(offset: .zero, blur: 2, color: UIColor(white: 0, alpha: 0.45).cgColor)
            gold.setStroke()
            gold.setFill()
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.height * 0.42, 0.115 * ppm)
            // Double ring.
            cg.setLineWidth(r * 0.06)
            cg.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            let r2 = r * 0.84
            cg.setLineWidth(r * 0.025)
            cg.strokeEllipse(in: CGRect(x: c.x - r2, y: c.y - r2, width: 2 * r2, height: 2 * r2))
            // Portico: pediment, architrave, three columns, two steps.
            let u = r * 0.12
            cg.move(to: CGPoint(x: c.x - 4.6 * u, y: c.y - 1.6 * u))
            cg.addLine(to: CGPoint(x: c.x, y: c.y - 4.0 * u))
            cg.addLine(to: CGPoint(x: c.x + 4.6 * u, y: c.y - 1.6 * u))
            cg.closePath()
            cg.fillPath()
            cg.fill(CGRect(x: c.x - 4.2 * u, y: c.y - 1.3 * u, width: 8.4 * u, height: 0.6 * u))
            for i in -1...1 {
                cg.fill(CGRect(x: c.x + CGFloat(i) * 2.8 * u - 0.45 * u, y: c.y - 0.5 * u, width: 0.9 * u, height: 3.6 * u))
            }
            cg.fill(CGRect(x: c.x - 4.2 * u, y: c.y + 3.2 * u, width: 8.4 * u, height: 0.55 * u))
            cg.fill(CGRect(x: c.x - 4.8 * u, y: c.y + 3.9 * u, width: 9.6 * u, height: 0.55 * u))
            // A thin rule either side of the seal, ending short of the pane edge.
            let ruleH = max(2, r * 0.04)
            let gap = r * 0.35
            let margin = size.width * 0.06
            cg.fill(CGRect(x: margin, y: c.y - ruleH / 2, width: max(0, c.x - r - gap - margin), height: ruleH))
            cg.fill(CGRect(x: c.x + r + gap, y: c.y - ruleH / 2, width: max(0, size.width - margin - (c.x + r + gap)), height: ruleH))
        }
    }

    /// Oct 5 (Administration): the department name as permanent signage on
    /// a bronze fascia directly above a Double Glass opening -- gold capitals
    /// between two thin gold rules. Local +Z is its face; `width` x 0.42 m.
    static func makeEntranceFascia(_ text: String, width: CGFloat) -> SCNNode {
        let height: CGFloat = 0.42
        let ppm: CGFloat = 600
        let size = CGSize(width: width * ppm, height: height * ppm)
        let bronze = UIColor(red: 0.2, green: 0.18, blue: 0.16, alpha: 1)
        let gold = UIColor(red: 0.93, green: 0.8, blue: 0.5, alpha: 1)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            bronze.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let maxTextWidth = size.width * 0.8
            var fontSize = size.height * 0.42
            var attributes: [NSAttributedString.Key: Any] = [:]
            repeat {
                attributes = [.font: UIFont.systemFont(ofSize: fontSize, weight: .semibold), .kern: fontSize * 0.12,
                              .foregroundColor: gold, .paragraphStyle: style]
                fontSize -= 2
            } while (text as NSString).size(withAttributes: attributes).width > maxTextWidth && fontSize > 12
            let textSize = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(in: CGRect(x: 0, y: (size.height - textSize.height) / 2, width: size.width, height: textSize.height),
                                    withAttributes: attributes)
            gold.setFill()
            let ruleW = textSize.width * 1.08, ruleH = max(2, size.height * 0.018)
            let ruleX = (size.width - ruleW) / 2
            context.fill(CGRect(x: ruleX, y: size.height * 0.14, width: ruleW, height: ruleH))
            context.fill(CGRect(x: ruleX, y: size.height * 0.86 - ruleH, width: ruleW, height: ruleH))
        }
        let face = SCNMaterial()
        face.lightingModel = .physicallyBased
        face.diffuse.contents = image
        face.metalness.contents = 0.45
        face.roughness.contents = 0.4
        let edge = SCNMaterial()
        edge.lightingModel = .physicallyBased
        edge.diffuse.contents = bronze
        edge.metalness.contents = 0.65
        edge.roughness.contents = 0.38
        let box = SCNBox(width: width, height: height, length: 0.04, chamferRadius: 0.004)
        // SCNBox material order: front (+Z), right, back, left, top, bottom.
        box.materials = [face, edge, edge, edge, edge, edge]
        let node = SCNNode(geometry: box)
        node.name = "roomEntranceFascia"
        return node
    }

    /// The lettering image shown on one leaf: the horizontal slice
    /// [uOffset, uOffset + uScale] of the whole word.
    private static func letteringMaterial(_ image: UIImage, uScale: Float, uOffset: Float) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = image
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.diffuse.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(uScale, 1, 1),
                                                            SCNMatrix4MakeTranslation(uOffset, 0, 0))
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.transparencyMode = .aOne
        material.blendMode = .alpha
        material.writesToDepthBuffer = false
        return material
    }
}
