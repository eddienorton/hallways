//
//  SVGPathParser.swift
//  Hallways
//
//  Turns an SVG path "d" attribute string (the same little drawing
//  language most vector icon libraries — Material Symbols, Font
//  Awesome, etc. — export their glyphs as) into a UIBezierPath, so a
//  real, professionally-drawn icon can be dropped into
//  HallwayScene's extrusion pipeline (SCNShape) the same way the
//  hand-built heart path is, instead of every new object needing its
//  control points guessed and hand-typed one at a time.
//
//  Supported commands, both absolute (uppercase) and relative
//  (lowercase): M/m moveto, L/l lineto, H/h horizontal lineto, V/v
//  vertical lineto, C/c cubic Bezier, S/s smooth cubic (reflects the
//  previous curve's second control point), Q/q quadratic Bezier, T/t
//  smooth quadratic, A/a elliptical arc, Z/z close path. Also handles
//  SVG's "implicit command repetition" — bare coordinate pairs/values
//  after a command letter reuse that same command, and bare pairs
//  right after an initial M/m become implicit L/l, per the SVG spec.
//
//  A/a support added Sept 4 once real icon libraries (Font Awesome)
//  turned out to lean on arcs constantly for anything circular — heads,
//  wheels, buttons, dots. Converts the arc's (rx ry x-axis-rotation
//  large-arc-flag sweep-flag x y) parameters to a center/angle form via
//  the W3C SVG spec's own endpoint-to-center formulas (Appendix F.6),
//  then walks the sweep in <=90-degree slices, each approximated as one
//  cubic Bezier via the standard 4/3*tan(angle/4) control-point
//  construction for a circular arc. This is mechanical, well-defined
//  math (not a guess the way the heart/star upside-down flip was) —
//  still its first real run on-device, so a mistyped sign or transposed
//  term in the transcription is the realistic risk, not conceptual
//  ambiguity. If an arc-using icon renders with a visibly wrong bulge
//  or a gap where a curve should close, this function is where to look.
//
//  On any command still not handled (nothing currently — this list is
//  now the full set the SVG path grammar defines, aside from
//  deprecated/rare variants), or on malformed data, parse(_:) does not
//  throw or warn: it simply stops consuming further commands and
//  returns whatever was successfully drawn up to that point.
//

import UIKit

enum SVGPathParser {

    /// Parses an SVG path `d` string into a UIBezierPath, in whatever
    /// coordinate units the path data itself uses (e.g. the 0...100
    /// box a lot of hand-authored icons use, or Material Symbols' own
    /// 0...24 grid) — no scaling is applied here, that's left to the
    /// caller, same as heartPath(size:) leaves final placement/scale
    /// to its caller.
    static func parse(_ d: String) -> UIBezierPath {
        let path = UIBezierPath()
        var scanner = TokenScanner(d)

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCommand: Character?
        // Previous curve's second control point, in ABSOLUTE
        // coordinates — needed for S/s and T/t's "reflect the last
        // control point" rule. Reset to the current point whenever the
        // previous command wasn't a curve of the matching family, per
        // spec.
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?

        while let command = scanner.nextCommandLetter() {
            let isRelative = command.isLowercase
            let upper = Character(command.uppercased())

            func resolvedPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                isRelative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch upper {
            case "M":
                guard let x = scanner.nextNumber(), let y = scanner.nextNumber() else { return path }
                current = resolvedPoint(x, y)
                subpathStart = current
                path.move(to: current)
                // Per spec, extra coordinate pairs right after an
                // initial moveto are treated as implicit lineto.
                while let (x2, y2) = scanner.peekNumberPair() {
                    _ = scanner.nextNumber(); _ = scanner.nextNumber()
                    current = resolvedPoint(x2, y2)
                    path.addLine(to: current)
                }

            case "L":
                guard let x = scanner.nextNumber(), let y = scanner.nextNumber() else { return path }
                current = resolvedPoint(x, y)
                path.addLine(to: current)
                while let (x2, y2) = scanner.peekNumberPair() {
                    _ = scanner.nextNumber(); _ = scanner.nextNumber()
                    current = resolvedPoint(x2, y2)
                    path.addLine(to: current)
                }

            case "H":
                guard let x = scanner.nextNumber() else { return path }
                current = CGPoint(x: isRelative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                while let x2 = scanner.peekNumber() {
                    _ = scanner.nextNumber()
                    current = CGPoint(x: isRelative ? current.x + x2 : x2, y: current.y)
                    path.addLine(to: current)
                }

            case "V":
                guard let y = scanner.nextNumber() else { return path }
                current = CGPoint(x: current.x, y: isRelative ? current.y + y : y)
                path.addLine(to: current)
                while let y2 = scanner.peekNumber() {
                    _ = scanner.nextNumber()
                    current = CGPoint(x: current.x, y: isRelative ? current.y + y2 : y2)
                    path.addLine(to: current)
                }

            case "C":
                repeat {
                    guard let x1 = scanner.nextNumber(), let y1 = scanner.nextNumber(),
                          let x2 = scanner.nextNumber(), let y2 = scanner.nextNumber(),
                          let x = scanner.nextNumber(), let y = scanner.nextNumber() else { return path }
                    let c1 = resolvedPoint(x1, y1)
                    let c2 = resolvedPoint(x2, y2)
                    let end = resolvedPoint(x, y)
                    path.addCurve(to: end, controlPoint1: c1, controlPoint2: c2)
                    lastCubicControl = c2
                    current = end
                } while scanner.peekNumberPair() != nil

            case "S":
                repeat {
                    guard let x2 = scanner.nextNumber(), let y2 = scanner.nextNumber(),
                          let x = scanner.nextNumber(), let y = scanner.nextNumber() else { return path }
                    let reflectedC1: CGPoint
                    if let last = lastCubicControl, let prev = lastCommand, "CcSs".contains(prev) {
                        reflectedC1 = CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
                    } else {
                        reflectedC1 = current
                    }
                    let c2 = resolvedPoint(x2, y2)
                    let end = resolvedPoint(x, y)
                    path.addCurve(to: end, controlPoint1: reflectedC1, controlPoint2: c2)
                    lastCubicControl = c2
                    lastCommand = command
                    current = end
                } while scanner.peekNumberPair() != nil

            case "Q":
                repeat {
                    guard let x1 = scanner.nextNumber(), let y1 = scanner.nextNumber(),
                          let x = scanner.nextNumber(), let y = scanner.nextNumber() else { return path }
                    let c1 = resolvedPoint(x1, y1)
                    let end = resolvedPoint(x, y)
                    path.addQuadCurve(to: end, controlPoint: c1)
                    lastQuadControl = c1
                    current = end
                } while scanner.peekNumberPair() != nil

            case "T":
                repeat {
                    guard let x = scanner.nextNumber(), let y = scanner.nextNumber() else { return path }
                    let reflectedC: CGPoint
                    if let last = lastQuadControl, let prev = lastCommand, "QqTt".contains(prev) {
                        reflectedC = CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
                    } else {
                        reflectedC = current
                    }
                    let end = resolvedPoint(x, y)
                    path.addQuadCurve(to: end, controlPoint: reflectedC)
                    lastQuadControl = reflectedC
                    lastCommand = command
                    current = end
                } while scanner.peekNumberPair() != nil

            case "Z":
                path.close()
                current = subpathStart

            case "A":
                repeat {
                    guard let rx = scanner.nextNumber(), let ry = scanner.nextNumber(),
                          let rotation = scanner.nextNumber(),
                          let largeArc = scanner.nextFlag(), let sweep = scanner.nextFlag(),
                          let x = scanner.nextNumber(), let y = scanner.nextNumber() else { return path }
                    let end = resolvedPoint(x, y)
                    appendArc(to: path, from: current, rx: rx, ry: ry, xAxisRotationDegrees: rotation, largeArcFlag: largeArc, sweepFlag: sweep, end: end)
                    current = end
                } while scanner.peekNumberPair() != nil

            default:
                // Unsupported command (arcs, or anything malformed) —
                // stop here rather than guess; see the file header.
                return path
            }

            if upper != "S" && upper != "T" {
                lastCommand = command
            }
            if upper != "C" && upper != "S" { lastCubicControl = nil }
            if upper != "Q" && upper != "T" { lastQuadControl = nil }
        }

        return path
    }

    /// Converts one SVG elliptical-arc segment into a sequence of cubic
    /// Beziers appended directly to `path` (mutated in place — a
    /// UIBezierPath is a reference type). `start` is wherever the path
    /// currently is; this function only appends curves, it never
    /// issues a moveto. See the file header for the algorithm and its
    /// honesty caveat.
    private static func appendArc(to path: UIBezierPath, from start: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat, xAxisRotationDegrees: CGFloat, largeArcFlag: Bool, sweepFlag: Bool, end: CGPoint) {
        // Degenerate per spec: coincident endpoints draw nothing; a
        // zero radius in either axis collapses the arc to a straight
        // line.
        if start.x == end.x, start.y == end.y { return }
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        if rx == 0 || ry == 0 {
            path.addLine(to: end)
            return
        }

        let phi = xAxisRotationDegrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        // W3C SVG Appendix F.6.5: endpoint -> center parameterization.
        let dx2 = (start.x - end.x) / 2
        let dy2 = (start.y - end.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let scale = lambda.squareRoot()
            rx *= scale
            ry *= scale
        }

        let rxSq = rx * rx, rySq = ry * ry
        let x1pSq = x1p * x1p, y1pSq = y1p * y1p
        let sign: CGFloat = (largeArcFlag == sweepFlag) ? -1 : 1
        let numerator = max(0, rxSq * rySq - rxSq * y1pSq - rySq * x1pSq)
        let denominator = rxSq * y1pSq + rySq * x1pSq
        let co = denominator == 0 ? 0 : sign * (numerator / denominator).squareRoot()
        let cxp = co * (rx * y1p / ry)
        let cyp = co * (-ry * x1p / rx)

        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        // Signed angle from vector (ux,uy) to (vx,vy), via atan2 of the
        // 2D cross/dot product -- more numerically stable near +-1 than
        // an acos-based version.
        func signedAngle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }

        let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
        let theta1 = signedAngle(1, 0, ux, uy)
        var deltaTheta = signedAngle(ux, uy, vx, vy)
        if !sweepFlag, deltaTheta > 0 { deltaTheta -= 2 * .pi }
        if sweepFlag, deltaTheta < 0 { deltaTheta += 2 * .pi }

        // Maps a point on the UNIT circle through the ellipse's own
        // radii, rotation, and center -- shared by every segment below.
        func mapUnit(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let ex = rx * x
            let ey = ry * y
            return CGPoint(x: cosPhi * ex - sinPhi * ey + cx, y: sinPhi * ex + cosPhi * ey + cy)
        }

        // Walk the sweep in <=90-degree slices -- the standard
        // 4/3*tan(angle/4) cubic construction only stays visually
        // accurate for a circular arc up to about a quarter-turn per
        // segment.
        let segmentCount = max(1, Int(ceil(abs(deltaTheta) / (.pi / 2))))
        let segmentSweep = deltaTheta / CGFloat(segmentCount)

        var theta = theta1
        for i in 0..<segmentCount {
            let nextTheta = theta + segmentSweep
            let t = (4.0 / 3.0) * tan(segmentSweep / 4)
            let c1 = mapUnit(cos(theta) - t * sin(theta), sin(theta) + t * cos(theta))
            let c2 = mapUnit(cos(nextTheta) + t * sin(nextTheta), sin(nextTheta) - t * cos(nextTheta))
            // The very last segment snaps to the caller's own `end`
            // rather than the parametric point, so floating-point
            // drift across segments can never leave the path short of
            // (or past) where the SVG data actually said it should
            // land -- matters for whatever command comes right after.
            let segEnd = (i == segmentCount - 1) ? end : mapUnit(cos(nextTheta), sin(nextTheta))
            path.addCurve(to: segEnd, controlPoint1: c1, controlPoint2: c2)
            theta = nextTheta
        }
    }

    /// Minimal hand-rolled scanner over an SVG path string: pulls off
    /// command letters and numbers, tolerant of the loose whitespace/
    /// comma rules SVG path data allows (numbers can run together with
    /// no separator when a sign or decimal point makes the boundary
    /// unambiguous, e.g. "1.5.5" is two numbers, "1.5" then ".5").
    private struct TokenScanner {
        private let chars: [Character]
        private var index = 0

        init(_ string: String) {
            chars = Array(string)
        }

        private mutating func skipSeparators() {
            while index < chars.count, chars[index] == " " || chars[index] == "," || chars[index] == "\n" || chars[index] == "\t" || chars[index] == "\r" {
                index += 1
            }
        }

        mutating func nextCommandLetter() -> Character? {
            skipSeparators()
            guard index < chars.count, chars[index].isLetter else { return nil }
            let c = chars[index]
            index += 1
            return c
        }

        mutating func nextNumber() -> CGFloat? {
            skipSeparators()
            let start = index
            var i = index
            if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
            var sawDigitOrDot = false
            while i < chars.count, chars[i].isNumber {
                i += 1
                sawDigitOrDot = true
            }
            if i < chars.count, chars[i] == "." {
                i += 1
                while i < chars.count, chars[i].isNumber {
                    i += 1
                    sawDigitOrDot = true
                }
            }
            guard sawDigitOrDot else { return nil }
            // Scientific notation (1e-5 etc.) — uncommon in icon data
            // but cheap to support.
            if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                var j = i + 1
                if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                var sawExpDigit = false
                while j < chars.count, chars[j].isNumber {
                    j += 1
                    sawExpDigit = true
                }
                if sawExpDigit { i = j }
            }
            let substring = String(chars[start..<i])
            guard let value = Double(substring) else { return nil }
            index = i
            return CGFloat(value)
        }

        /// A/a's large-arc-flag and sweep-flag are always exactly one
        /// character, '0' or '1' — unlike an ordinary number, a flag
        /// must NOT swallow digits that immediately follow it with no
        /// separator, since minified arc data commonly packs adjacent
        /// flags together (e.g. "1 1 0 0" written as "1100", or two
        /// flags as "10" with no space at all). Reading exactly one
        /// digit here, instead of reusing nextNumber(), is what makes
        /// that packed form parse correctly.
        mutating func nextFlag() -> Bool? {
            skipSeparators()
            guard index < chars.count, chars[index] == "0" || chars[index] == "1" else { return nil }
            let value = chars[index] == "1"
            index += 1
            return value
        }

        /// Non-consuming lookahead used by every command's "implicit
        /// repeat" loop: is there another number pair here, or has the
        /// next command letter (or end of string) arrived instead?
        mutating func peekNumberPair() -> (CGFloat, CGFloat)? {
            let savedIndex = index
            skipSeparators()
            guard index < chars.count, !chars[index].isLetter else {
                index = savedIndex
                return nil
            }
            let x = nextNumber()
            let y = x != nil ? nextNumber() : nil
            let result: (CGFloat, CGFloat)? = (x != nil && y != nil) ? (x!, y!) : nil
            index = savedIndex
            return result
        }

        /// Same idea as peekNumberPair, for H/V's single-value repeats.
        mutating func peekNumber() -> CGFloat? {
            let savedIndex = index
            skipSeparators()
            guard index < chars.count, !chars[index].isLetter else {
                index = savedIndex
                return nil
            }
            let x = nextNumber()
            index = savedIndex
            return x
        }
    }
}
