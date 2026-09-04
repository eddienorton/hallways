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
//  smooth quadratic, Z/z close path. Also handles SVG's "implicit
//  command repetition" — bare coordinate pairs/values after a command
//  letter reuse that same command, and bare pairs right after an
//  initial M/m become implicit L/l, per the SVG spec.
//
//  NOT supported: A/a elliptical arc. Deliberately left out — arcs are
//  rare in simple icon glyphs, and the math to convert an SVG arc's
//  (rx ry x-axis-rotation large-arc-flag sweep-flag x y) parameters
//  into Bezier-equivalent curves is easy to get subtly wrong, which
//  isn't worth risking unverified on a system nobody here can compile
//  or preview. If a chosen icon turns out to use arcs, this will need
//  extending (or that icon avoided) — parse(_:) does not throw or
//  warn on an unsupported command, it simply stops consuming further
//  commands, so an icon that hits this returns whatever was
//  successfully drawn up to that point.
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
