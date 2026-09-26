//
//  PropLibrary.swift
//  Hallways
//
//  A small reusable seam for STATIC scene props -- objects whose whole
//  job is to occupy a cell and look like something, with no pickup,
//  delivery, navigation-stop, or mission behavior. Each prop is a
//  `PropDefinition`: a flat SVG silhouette extruded into a real 3D
//  shape, sized in meters, plus a per-prop material and yaw.
//
//  The fill geometry comes from SVGPathParser, the SAME parser the
//  pick-up/delivery icons use (HallwayScene.makeIconNode) -- one path
//  format, one extrude path. Definitions carry the path data directly
//  (embedded as a string constant), so nothing in the app target has to
//  load or parse a .svg at runtime.
//
//  Compare with FloorObjectPlacement in MazeStore.swift, which tweaks
//  the POSITION and orientation of a *real* floor object (trash cans).
//  Props deliberately don't have that: no editor tooling, no JSON, no
//  persistence. If a prop graduates into a real mechanic it gets a real
//  model (like trashCan did); until then it's here and only here.
//
//  TEMPORARY: this proves the extruded-silhouette pipeline for the
//  watering-can prop, with a single debug placement on Floor 2 in
//  HallwayScene.build. Delete the placement block (and this file too,
//  if the prop dies) when the experiment is over.

import Foundation
import SceneKit
import UIKit

/// What a prop is, before it's a node.
struct PropDefinition {
    /// Stable id, used by the registry and by the (temporary) build-time
    /// placement hook in HallwayScene.build.
    let id: String
    /// SVG `d` path data in the same dialect SVGPathParser already eats
    /// (M/L/H/V/C/S/Q/T/arcs). Normalized so the silhouette is ~100
    /// units tall with its base at y = 0 -- that keeps `heightMeters` a
    /// clean divisor for the exact same scale math makeIconNode uses.
    let pathData: String
    /// Finished height on the floor, in meters.
    let heightMeters: CGFloat
    /// Finished front-back thickness, in meters. The path is 100 units
    /// tall; extrusion depth is derived in path units from this and the
    /// scale, exactly the way makeIconNode derives it from nativeHeight.
    let extrusionDepthMeters: CGFloat
    /// Rotation about the world Y axis (radians), applied AFTER the
    /// base/centering pivot. Lets a profile that was authored face +Y be
    /// turned to face any corridor direction without re-authoring data.
    let yaw: CGFloat
    /// Diffuse color the prop wears (flat grays/tones read best under
    /// Hallways' headlamp + ambient).
    let diffuseColor: UIColor
    /// PBR metalness/roughness. Keep metalness LOW -- a PBR metal near
    /// 1.0 blackens under no-environment scenes (same trap the movable
    /// destination shutter fell into, Sept 23).
    let metalness: CGFloat
    let roughness: CGFloat

    /// Shared scale from the normalized ~100-unit path to meters.
    var pathUnitsPerMeter: CGFloat { 100.0 / heightMeters }
}

/// The whole catalog of static props, keyed by id so nothing outside
/// this file hard-codes geometry or look.
enum PropLibrary {
    // ====================== WATERING CAN ======================
    // Extracted + verified Sept 24 from watering-can-fixed.svg (the
    // flat-gray Inkscape-built version, chosen over the layered
    // original). Silhouette is a single CG path: one outer loop
    // (70 points) wound CW around the body, PLUS two interior holes each
    // wound CCW so they cut clean through the extrusion under either
    // fill rule:
    //   - the handle loop gap       (15 points, top-right)
    //   - the gap under the spout   (16 points, upper-left)
    // Equivalent minus a few rounding-scale digits, byte-checked against
    // CoreGraphics even-odd fills of the original render. Path is
    // centered on x (-53.3..53.3), base y = 0, height exactly 100.
    static let wateringCanPathData = "M -6.2 100.0 L 2.2 99.5 L 3.5 98.8 L 4.4 98.0 L 5.6 95.0 L 6.7 89.0 L 6.8 84.6 L 6.5 79.8 L 16.0 78.5 L 19.0 77.8 L 21.4 76.7 L 22.3 75.7 L 23.5 66.6 L 25.4 65.3 L 28.4 62.3 L 31.4 61.1 L 36.0 60.4 L 43.8 60.3 L 47.3 60.5 L 50.9 61.0 L 53.3 64.6 L 53.3 53.2 L 52.4 54.1 L 48.8 53.9 L 43.4 53.0 L 33.8 50.4 L 25.8 49.3 L 31.1 9.3 L 30.2 7.6 L 28.2 5.9 L 25.7 4.6 L 20.5 2.8 L 12.2 1.1 L 3.9 0.2 L -8.2 0.0 L -17.9 0.6 L -26.9 2.1 L -32.8 3.9 L -35.2 4.8 L -37.6 6.2 L -39.4 7.8 L -40.0 9.1 L -40.1 10.1 L -38.3 23.0 L -38.8 26.6 L -40.8 33.2 L -42.4 37.2 L -50.8 52.6 L -52.5 56.5 L -53.3 60.0 L -53.3 62.7 L -52.8 64.8 L -52.0 66.4 L -50.4 68.6 L -49.4 69.8 L -47.0 71.2 L -41.9 72.9 L -35.2 74.7 L -31.5 74.1 L -31.2 75.9 L -30.8 76.5 L -29.5 77.2 L -25.9 78.3 L -19.7 79.3 L -18.4 87.8 L -17.3 92.6 L -16.1 96.3 L -14.8 98.5 L -14.1 99.4 L -6.4 99.9 Z M -7.0 99.2 L -8.1 98.6 L -8.5 97.7 L -9.7 91.5 L -10.0 87.5 L -10.2 80.0 L 1.9 80.0 L 2.4 84.3 L 2.6 91.2 L 2.5 94.1 L 1.9 96.7 L 1.2 97.9 L 0.5 98.6 L -0.5 99.0 L -6.8 99.4 Z M -43.8 70.8 L -46.0 69.2 L -46.8 68.2 L -47.4 66.7 L -47.6 62.8 L -47.1 60.2 L -45.8 56.5 L -43.9 52.5 L -41.0 48.1 L -37.4 43.6 L -36.0 41.1 L -32.8 65.2 L -35.2 67.9 L -37.2 69.4 L -40.3 70.7 L -43.6 70.9 Z"

    private static let wateringCan = PropDefinition(
        id: "wateringCan",
        pathData: wateringCanPathData,
        heightMeters: 0.32,
        extrusionDepthMeters: 0.14,
        yaw: -.pi / 2,
        diffuseColor: UIColor(red: 0.55, green: 0.57, blue: 0.60, alpha: 1),
        metalness: 0.15,
        roughness: 0.78
    )

    static let all: [PropDefinition] = [
        wateringCan
    ]

    static func prop(forID id: String) -> PropDefinition? {
        all.first { $0.id == id }
    }

    /// The ONE builder every prop goes through: parse the silhouette,
    /// extrude it, anchor it on the floor and to the cell center. The
    /// returned node is ready to be positioned -- callers just set
    /// `.position` and parent it under the scene root.
    static func makePropNode(for definition: PropDefinition) -> SCNNode {
        let path = SVGPathParser.parse(definition.pathData)
        // Even-odd (not default non-zero) so the two CCW interior loops
        // cut real holes through the slab rather than being ignored.
        // Windings are ALSO reversed relative to the outer loop, so the
        // holes survive even if a consumer ignores the fill rule.
        path.usesEvenOddFillRule = true

        let unitsPerMeter = definition.pathUnitsPerMeter
        let metersPerUnit = 1.0 / unitsPerMeter
        let extrusionDepth = definition.extrusionDepthMeters * unitsPerMeter

        let shape = SCNShape(path: path, extrusionDepth: extrusionDepth)
        let material = SCNMaterial()
        material.diffuse.contents = definition.diffuseColor
        material.lightingModel = .physicallyBased
        material.metalness.contents = definition.metalness
        material.roughness.contents = definition.roughness
        shape.materials = [material]

        let node = SCNNode(geometry: shape)
        // Path base is already y = 0 and x is already centered, so the
        // pivot only needs to center the extrusion depth -- same recipe
        // makeIconNode uses, minus the icon's (width/2, height/2) shift.
        node.pivot = SCNMatrix4MakeTranslation(0, 0, Float(extrusionDepth / 2))
        if definition.yaw != 0 {
            node.eulerAngles.y = Float(definition.yaw)
        }
        let scale = Float(metersPerUnit)
        node.scale = SCNVector3(scale, scale, scale)
        return node
    }
}