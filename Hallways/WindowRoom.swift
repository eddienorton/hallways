import SceneKit
import UIKit

/// A Window Room's own placement data -- same coord+direction shape as
/// every other door/fixture placement here (see PicturePlacement,
/// RoomDoorPlacement), plus the two facts unique to this fixture: which
/// wall of the room BEYOND the door is the exterior window wall, and
/// which view image it shows.
///
/// `coord`/`direction` describe the DOOR exactly the way bathroomDoors
/// does -- `coord` is the hallway-side cell the door is mounted in,
/// `direction` is which of its walls the door sits on (the room is
/// `coord` shifted one cell in `direction`). `windowDirection` is a
/// SEPARATE direction -- which wall of that ROOM cell is the building's
/// own exterior wall -- since a room's door wall and its window wall
/// are two different walls of two different cells; conflating them was
/// the one shape mistake worth calling out up front. `viewAssetID`
/// identifies the view image (HallwayScene.windowViewTexture(for:)
/// resolves it); "nycPlaceholder" is the only asset that exists today
/// -- see nycPlaceholderViewTexture's own doc comment.
struct WindowRoomPlacement: Codable, Equatable {
    var coord: GridCoordinate
    var direction: Direction
    var windowDirection: Direction
    var viewAssetID: String
}

extension HallwayScene {
    /// Eddie, Sept 15: "one static curated NYC-style image... if no
    /// suitable asset exists in the project, build with a
    /// clearly-labeled neutral placeholder... do not invent procedural
    /// art or use an unrelated image." A project-wide asset search
    /// (Assets.xcassets, every bundled image) found no NYC/skyline/
    /// cityscape art anywhere, so this is that placeholder: a flat,
    /// neutral sky/ground gradient with NO invented skyline, silhouette,
    /// or building shapes drawn on it (that would be exactly the
    /// "procedural art" pretending to be the real view this was told
    /// not to do) -- just a plainly labeled placeholder card, same
    /// UIGraphicsImageRenderer technique restroomSignTexture uses for
    /// its own generated texture. 1600x1200 (4:3) -- see
    /// windowOpeningWidth/windowOpeningHeight below for why 4:3 is the
    /// window's own exact aspect ratio; swap this `static let` for a
    /// bundled image at the same "nycPlaceholder" viewAssetID (or add a
    /// new viewAssetID case to windowViewTexture(for:) below) once a
    /// real curated image exists, no other code needs to change.
    ///
    /// Eddie, Sept 15 (2nd pass, visual test): this is now also the
    /// FALLBACK a Window Room's glass falls back to -- the initial
    /// texture every window is built with, and what it's put back to
    /// if the camera-roll photo below comes back unavailable (denied
    /// access, empty library). It stays exactly this placeholder, per
    /// Eddie's own instruction to retain it as the fallback.
    static let nycPlaceholderViewTexture: UIImage = {
        let size = CGSize(width: 1600, height: 1200)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let sky = UIColor(red: 0.63, green: 0.72, blue: 0.8, alpha: 1)
            let ground = UIColor(red: 0.55, green: 0.56, blue: 0.58, alpha: 1)
            let horizon = size.height * 0.62
            sky.setFill()
            cg.fill(CGRect(x: 0, y: 0, width: size.width, height: horizon))
            ground.setFill()
            cg.fill(CGRect(x: 0, y: horizon, width: size.width, height: size.height - horizon))
            UIColor.white.withAlphaComponent(0.9).setFill()
            cg.fill(CGRect(x: 0, y: horizon - 3, width: size.width, height: 6))

            let style = NSMutableParagraphStyle()
            style.alignment = .center
            ("WINDOW VIEW -- PLACEHOLDER" as NSString).draw(
                in: CGRect(x: 40, y: size.height * 0.34, width: size.width - 80, height: 90),
                withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 62), .foregroundColor: UIColor.white,
                    .paragraphStyle: style, .kern: 1.0
                ])
            ("Replace with a curated 4:3 exterior image" as NSString).draw(
                in: CGRect(x: 40, y: size.height * 0.34 + 100, width: size.width - 80, height: 50),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 34), .foregroundColor: UIColor.white.withAlphaComponent(0.92),
                    .paragraphStyle: style
                ])
            ("Recommended: 1600\u{00d7}1200px (4:3), or any 4:3 image" as NSString).draw(
                in: CGRect(x: 40, y: size.height * 0.34 + 150, width: size.width - 80, height: 44),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.white.withAlphaComponent(0.8),
                    .paragraphStyle: style
                ])
        }
    }()

    /// The one indirection point for turning a WindowRoomPlacement's
    /// `viewAssetID` into an actual texture -- everywhere else in
    /// HallwayScene.build(fromMaze:) just calls this rather than
    /// referencing nycPlaceholderViewTexture directly, so adding a real
    /// second view later is a new `case` here, not a hunt through the
    /// build function.
    static func windowViewTexture(for viewAssetID: String) -> UIImage {
        switch viewAssetID {
        default: return nycPlaceholderViewTexture
        }
    }

    /// CSS-cover equivalent for the window's own 4:3 opening -- scale a
    /// camera-roll photo (any aspect ratio) uniformly to fill the 4:3
    /// canvas and crop the overflow, so it always fills the glass
    /// edge-to-edge with no distortion and no letterboxing. Deliberately
    /// its own function rather than reusing HallwayScene's private
    /// framedPhoto(_:), which is hard-coded to the decorative pictures'
    /// 0.6x0.85 portrait opening and adds a dark mat border -- neither
    /// fits a landscape 4:3 window (a mat border around a "view" would
    /// look like a picture frame, not a window). The sky-tint fill
    /// behind the draw is only insurance against a hairline rounding
    /// gap at the very edge; the cover-fit scale above should always
    /// fill the whole canvas.
    private static func windowFramedPhoto(_ image: UIImage) -> UIImage {
        let size = CGSize(width: 1600, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.63, green: 0.72, blue: 0.8, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let scale = max(size.width / max(image.size.width, 1), size.height / max(image.size.height, 1))
            let width = image.size.width * scale
            let height = image.size.height * scale
            image.draw(in: CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height))
        }
    }

    /// Applies a camera-roll photo (already cover-cropped to the
    /// window's 4:3 opening) to a window's glass material, or restores
    /// the placeholder if PhotoRollProvider couldn't get one (denied
    /// access, empty library) -- the exact same "apply or fall back"
    /// shape as the hallway-picture / elevator-photo call sites in
    /// HallwayScene.build(fromMaze:) use for their own materials, kept
    /// here as its own named step so build(fromMaze:) can just call it
    /// once per window rather than repeat the ternary inline.
    static func applyWindowPhoto(_ image: UIImage?, to material: SCNMaterial, fallback: UIImage) {
        material.diffuse.contents = image.map { windowFramedPhoto($0) } ?? fallback
    }

    /// The window opening's own physical size, cut into the room's
    /// exterior wall -- narrower and set well off the floor compared to
    /// a doorway (a window, not another door), and deliberately exactly
    /// 4:3 so the placeholder/replacement image is never stretched.
    static let windowOpeningWidth: CGFloat = 1.2
    static let windowOpeningHeight: CGFloat = 0.9
    static let windowSillY: CGFloat = 1.0
    static let windowCenterY: CGFloat = windowSillY + windowOpeningHeight / 2

    /// The window itself: a real recessed casing (four separate bars
    /// forming an open ring around the opening, not a solid slab), a
    /// glass pane set back inside that ring, two crossing mullions
    /// splitting the glass into 4 panes, and a projecting sill --
    /// same "root positioned/rotated per direction, children built in
    /// pre-rotation local coordinates" idiom as makeMirrorNode, and the
    /// same restrained-fixture spirit (no curtains, blinds, reflections,
    /// or animated content -- Eddie, Sept 15, was explicit that this
    /// should read as architectural, not become a diorama).
    ///
    /// Eddie, Sept 15 (2nd pass): the FIRST version of this function
    /// built the casing as one solid SCNBox spanning the entire opening
    /// -- width/height covering the opening plus its border, with no
    /// hole cut through it -- and positioned the glass pane INSIDE that
    /// solid box's own depth. That box's opaque material sat directly
    /// in front of (and around) the glass, hiding it almost entirely --
    /// which is exactly why it read as "a large flat white rectangle"
    /// rather than a window. This version replaces that slab with an
    /// actual open ring (top/bottom rails + two jambs, each only
    /// frameBorder wide) that leaves the opening genuinely open, and
    /// gives that ring real depth (revealDepth, well beyond the 0.1
    /// wall thickness) so the jambs are visibly walking back away from
    /// the room into the glass -- the "recess" a flat decal can't have.
    ///
    /// Called from the windowRooms loop in build(fromMaze:) immediately
    /// after that same loop's addDoorFrame call has already cut this
    /// exact opening into the wall -- wallCenterX/wallCenterZ here MUST
    /// be the same values passed to that addDoorFrame call, or the
    /// frame won't sit in the hole it cut. Returns the glass node's own
    /// material alongside the node so build(fromMaze:) can swap in a
    /// camera-roll photo once PhotoRollProvider delivers one, the same
    /// way it already does for framed pictures and elevator photos.
    static func makeWindowNode(direction: Direction, wallCenterX: CGFloat, wallCenterZ: CGFloat, viewTexture: UIImage) -> (node: SCNNode, glassMaterial: SCNMaterial) {
        let root = SCNNode()
        root.name = "windowRoomWindow"

        let frameMaterial = SCNMaterial()
        frameMaterial.diffuse.contents = UIColor(white: 0.93, alpha: 1)
        frameMaterial.lightingModel = .physicallyBased
        frameMaterial.roughness.contents = 0.6

        let mullionMaterial = SCNMaterial()
        mullionMaterial.diffuse.contents = UIColor(white: 0.85, alpha: 1)
        mullionMaterial.lightingModel = .physicallyBased
        mullionMaterial.roughness.contents = 0.6

        let sillMaterial = SCNMaterial()
        sillMaterial.diffuse.contents = UIColor(white: 0.87, alpha: 1)
        sillMaterial.lightingModel = .physicallyBased
        sillMaterial.roughness.contents = 0.5

        let frameBorder: CGFloat = 0.08
        let frameWidth = windowOpeningWidth + frameBorder * 2
        let frameHeight = windowOpeningHeight + frameBorder * 2

        // Must match addDoorFrame's own local `thick` constant in
        // HallwayScene.build(fromMaze:) -- that's the wall thickness
        // this opening was actually cut through, and everything below
        // is positioned relative to it so the ring's outer (exterior)
        // face lands flush with the wall's own outer face rather than
        // floating in front of or buried inside it.
        let wallThickness: CGFloat = 0.1

        // The casing's own depth, deliberately much deeper than the
        // wall itself -- Eddie, Sept 15: "visible depth/recess so it
        // does not look like a picture pasted on the wall." Flush with
        // the exterior face at one end, it reaches well past the
        // interior wall face into the room at the other, so approaching
        // the window from inside the room you see the jambs recede
        // before you reach the glass -- a deep-set bay-window reveal,
        // not a literal (and here, visually unreadable) 0.1m return.
        let revealDepth: CGFloat = 0.28
        let ringCenterOffset = revealDepth / 2 - wallThickness / 2

        // Which way is INTO the room from this wall -- the mirror image
        // of addDoorFrame's own wallCenterX/Z offset (north's wall sits
        // at doorZ - half, i.e. the room is toward +Z from the wall;
        // south/east/west follow the same logic in the other 3
        // directions). Every "inward" offset below is a signed distance
        // along this axis: positive is further into the room, negative
        // is out past the exterior wall face.
        let inward: (x: Float, z: Float)
        switch direction {
        case .north: inward = (0, 1)
        case .south: inward = (0, -1)
        case .east: inward = (-1, 0)
        case .west: inward = (1, 0)
        }

        // Builds a box in this wall's own local frame: `alongWall` is
        // the horizontal extent running along the wall (maps to X for
        // a north/south wall, Z for an east/west one), `vertical` is
        // always world-Y, and `depth` is the extent along the inward
        // axis (the complementary one to alongWall). Exactly the same
        // width/length axis swap the original single frameGeo box
        // already used, just factored out since this version needs it
        // for five separate pieces instead of one.
        func wallBox(alongWall: CGFloat, vertical: CGFloat, depth: CGFloat) -> SCNBox {
            switch direction {
            case .north, .south:
                return SCNBox(width: alongWall, height: vertical, length: depth, chamferRadius: 0.004)
            case .east, .west:
                return SCNBox(width: depth, height: vertical, length: alongWall, chamferRadius: 0.004)
            }
        }

        // Positions a child already built with wallBox: `alongWall`
        // offset is signed but NOT scaled by `inward` (sideways is
        // sideways regardless of which way the wall faces -- the
        // window is symmetric left/right so the sign convention here
        // doesn't matter), `vertical` is world-Y as always, and
        // `inwardOffset` is the signed into-the-room distance, scaled
        // by `inward` the same way the original glass/sill offsets
        // already were.
        func place(_ node: SCNNode, alongWall: CGFloat, vertical: CGFloat, inwardOffset: CGFloat) {
            switch direction {
            case .north, .south:
                node.position = SCNVector3(Float(alongWall), Float(vertical), Float(inwardOffset) * inward.z)
            case .east, .west:
                node.position = SCNVector3(Float(inwardOffset) * inward.x, Float(vertical), Float(alongWall))
            }
        }

        // The casing ring -- top and bottom rails plus two jambs,
        // deliberately left OPEN in the middle (unlike the single slab
        // this replaced) so the glass shows through.
        let topBar = SCNNode(geometry: wallBox(alongWall: frameWidth, vertical: frameBorder, depth: revealDepth))
        topBar.geometry?.materials = [frameMaterial]
        place(topBar, alongWall: 0, vertical: windowOpeningHeight / 2 + frameBorder / 2, inwardOffset: ringCenterOffset)
        root.addChildNode(topBar)

        let bottomBar = SCNNode(geometry: wallBox(alongWall: frameWidth, vertical: frameBorder, depth: revealDepth))
        bottomBar.geometry?.materials = [frameMaterial]
        place(bottomBar, alongWall: 0, vertical: -(windowOpeningHeight / 2 + frameBorder / 2), inwardOffset: ringCenterOffset)
        root.addChildNode(bottomBar)

        let leftJamb = SCNNode(geometry: wallBox(alongWall: frameBorder, vertical: windowOpeningHeight, depth: revealDepth))
        leftJamb.geometry?.materials = [frameMaterial]
        place(leftJamb, alongWall: -(windowOpeningWidth / 2 + frameBorder / 2), vertical: 0, inwardOffset: ringCenterOffset)
        root.addChildNode(leftJamb)

        let rightJamb = SCNNode(geometry: wallBox(alongWall: frameBorder, vertical: windowOpeningHeight, depth: revealDepth))
        rightJamb.geometry?.materials = [frameMaterial]
        place(rightJamb, alongWall: windowOpeningWidth / 2 + frameBorder / 2, vertical: 0, inwardOffset: ringCenterOffset)
        root.addChildNode(rightJamb)

        // The glass, set back near the ring's exterior (outer) end --
        // Eddie, Sept 15: "glass/window surface positioned correctly
        // inside the frame." Textured with `viewTexture` to start
        // (the placeholder, or whatever windowViewTexture(for:)
        // resolved); build(fromMaze:) may swap this material's own
        // diffuse.contents to a camera-roll photo once one arrives,
        // which is why the material -- not just the node -- is
        // returned below.
        let glassMaterial = SCNMaterial()
        glassMaterial.lightingModel = .constant
        glassMaterial.diffuse.contents = viewTexture
        let glassGeo = SCNPlane(width: windowOpeningWidth, height: windowOpeningHeight)
        glassGeo.materials = [glassMaterial]
        let glass = SCNNode(geometry: glassGeo)
        glass.name = "windowRoomView"
        let glassInwardOffset: CGFloat = -0.02
        place(glass, alongWall: 0, vertical: 0, inwardOffset: glassInwardOffset)
        switch direction {
        case .north: break
        case .south: glass.eulerAngles.y = .pi
        case .east: glass.eulerAngles.y = -.pi / 2
        case .west: glass.eulerAngles.y = .pi / 2
        }
        root.addChildNode(glass)

        // Two crossing mullions, just room-ward of the glass -- Eddie,
        // Sept 15: "simple interior mullions/panes if appropriate --
        // something like a believable 4-pane office/building window is
        // fine." A plain centered cross is the simplest version of
        // that, and matches the same restrained-fixture spirit as
        // everything else here.
        let mullionThickness: CGFloat = 0.035
        let mullionInwardOffset = glassInwardOffset + 0.01
        let verticalMullion = SCNNode(geometry: wallBox(alongWall: mullionThickness, vertical: windowOpeningHeight, depth: 0.02))
        verticalMullion.geometry?.materials = [mullionMaterial]
        place(verticalMullion, alongWall: 0, vertical: 0, inwardOffset: mullionInwardOffset)
        root.addChildNode(verticalMullion)

        let horizontalMullion = SCNNode(geometry: wallBox(alongWall: windowOpeningWidth, vertical: mullionThickness, depth: 0.02))
        horizontalMullion.geometry?.materials = [mullionMaterial]
        place(horizontalMullion, alongWall: 0, vertical: 0, inwardOffset: mullionInwardOffset)
        root.addChildNode(horizontalMullion)

        // A projecting sill ledge, flush with the ring's own room-side
        // face and extending a bit further into the room -- Eddie,
        // Sept 15: "a proper sill." Deliberately thin and short rather
        // than a window-seat bench, same as the original.
        let sillThickness: CGFloat = 0.045
        let sillDepth: CGFloat = 0.16
        let sillWidth = frameWidth + 0.06
        let sill = SCNNode(geometry: wallBox(alongWall: sillWidth, vertical: sillThickness, depth: sillDepth))
        sill.geometry?.materials = [sillMaterial]
        let ringRoomFace = ringCenterOffset + revealDepth / 2
        let sillInwardOffset = ringRoomFace + sillDepth / 2
        let sillVertical = -(windowOpeningHeight / 2 + frameBorder) - sillThickness / 2
        place(sill, alongWall: 0, vertical: sillVertical, inwardOffset: sillInwardOffset)
        root.addChildNode(sill)

        root.position = SCNVector3(Float(wallCenterX), Float(windowCenterY), Float(wallCenterZ))
        return (root, glassMaterial)
    }
}
