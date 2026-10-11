import CoreImage
import UIKit
import Vision

/// Oct 5 -- THE HALLWAYS FACE RULE (shared).
///
/// Turns a real photo of a person into their Hallways-world face: still
/// recognisably them (their own skin, hair, nose, mouth, iris colour), but
/// with the building's critter eyes -- big, round, bulging eyeballs that sit
/// in the face -- supported by a domed crown, a softer narrower jaw and a
/// small pinched mouth, in the building's warm palette.
///
/// Why the eyes are DRAWN, not just magnified: a plain bump-magnify of the
/// real eye reads as "a person making a wide-eyed face" (device report,
/// Oct 5). Here the real eye region is first pushed outward (brows and lids
/// move as if the eye grew), then a round eyeball is painted over it --
/// shaded sclera, the person's own sampled iris colour, pupil, catchlight,
/// a skin-toned upper lid and lash line, a dark rim and a lower-lid bag --
/// softened so it sits in the photo. Then the head/jaw/mouth warps are
/// applied over everything, so the eyes deform WITH the face.
///
/// Used today by the Administration ID terminal (a still); meant for the
/// Hallways mirror later (call `transform` per frame on a smaller image).
/// Every run logs `hallwaysFace.begin / .variant / .landmarks / .done` diagnostics.
///
/// Oct 5 -- VARIANTS: the rule now has a small curated family of presets
/// (one Hallways species, six mutations). Each render picks one at random,
/// never the same one twice in a row; RETAKE is a fresh roll. `.googly` is
/// the original, device-proven face, parameter for parameter.
nonisolated enum HallwaysFace {
    nonisolated struct Output {
        let image: UIImage
        /// False when the rule could not run and `image` is the input as-is.
        let applied: Bool
        /// The preset used (internal; diagnostics only, never shown).
        let variant: Variant
        /// Oct 10 (ID kiosk): where the face sat in the capture.
        var framing: Framing = .ok
    }

    /// Oct 10 (ID kiosk face framing): is the face placed well enough for an
    /// ID photo? Checked on Vision's (normalized, origin bottom-left) box.
    /// Tuning lives in `framing(of:mouthFound:)`.
    nonisolated enum Framing: String {
        case ok, noFace, tooLow, tooHigh, tooFar, offCenter
        /// The kiosk's on-screen prompt (two short lines).
        var prompt: (String, String) {
            switch self {
            case .ok: return ("", "")
            case .noFace: return ("NO FACE DETECTED", "LOOK INTO THE CAMERA")
            case .tooLow: return ("FACE TOO LOW", "RAISE THE CAMERA A LITTLE")
            case .tooHigh: return ("FACE TOO HIGH", "LOWER THE CAMERA A LITTLE")
            case .tooFar: return ("TOO FAR AWAY", "MOVE A LITTLE CLOSER")
            case .offCenter: return ("FACE OFF CENTER", "CENTER YOUR FACE")
            }
        }
    }

    nonisolated static func framing(of box: CGRect?, mouthFound: Bool) -> Framing {
        guard let b = box else { return .noFace }
        if b.minY < 0.03 || b.midY < 0.33 || (!mouthFound && b.midY < 0.45) { return .tooLow }
        if b.maxY > 0.97 || b.midY > 0.8 { return .tooHigh }
        if b.width < 0.15 { return .tooFar }
        if b.midX < 0.2 || b.midX > 0.8 { return .offCenter }
        return .ok
    }

    /// The curated family. Internal names -- never on screen.
    nonisolated enum Variant: String, CaseIterable {
        case googly        // the original: big round bulging eyes, small dome, pinched mouth
        case suspicious    // tiny beady heavy-lidded eyes, narrowed mid-face, big egg forehead
        case lopsided      // one huge eye, one small squinty one
        case longFace      // long narrow face, tall crown
        case squashed      // short wide face, puffed cheeks, tiny mouth
        case dome          // towering alien cranium, big eyes, small tucked-in lower face
    }

    /// One eye's treatment (image order: `left` = the eye with the smaller x).
    nonisolated struct EyeStyle {
        var size: CGFloat = 1                       // eyeball radius = 0.31 x eyeSpan x size
        var irisRatio: CGFloat = 0.15 / 0.31        // iris radius / eyeball radius
        var lidSide: CGFloat = -0.42                // upper-lid edge at the sides (x eyeball radius; more negative = more open)
        var lidPeak: CGFloat = -1.02                // upper-lid curve control at the middle
        var growScale: CGFloat = 0.45               // bump on the real eye first (+ grows it, - shrinks it)
        var growRadius: CGFloat = 0.6               // x eyeSpan
    }

    /// Every number the rule uses. Defaults = the original face (`.googly`).
    nonisolated struct Preset {
        var left = EyeStyle()
        var right = EyeStyle()
        var mouthScale: CGFloat = -0.6
        var mouthRadius: CGFloat = 0.85             // x mouth width (at least 0.38 x eyeSpan)
        var jawScale: CGFloat = -0.32
        var jawRadius: CGFloat = 0.62               // x face width
        var crownScale: CGFloat = 0.32
        var crownRadius: CGFloat = 0.78             // x face width
        var crownLift: CGFloat = 0.55               // crown centre above the eye line, x face height
        var cheeks: CGFloat = 0                     // puffed cheeks (bump scale; 0 = none)
        var widen: CGFloat = 0                      // linear bump across the face: + wider, - narrower
        var lengthen: CGFloat = 0                   // linear bump along the face: + longer, - shorter
        var cropHeight: CGFloat = 2.4               // portrait height, x face height
        var cropLift: CGFloat = 0.14                // portrait centre above face centre, x face height
        /// Diagnostics: what was chosen beyond the name (e.g. which eye is big).
        var note = ""
    }

    static func preset(_ variant: Variant) -> Preset {
        var p = Preset()
        switch variant {
        case .googly:
            break
        case .suspicious:
            // Small beady eyes (real eye pinched smaller first so the little
            // eyeball still covers it), heavy upper lids, the mid-face
            // narrowed (eyes drawn together) and a big egg forehead.
            let beady = EyeStyle(size: 0.7, irisRatio: 0.55, lidSide: -0.05, lidPeak: -0.5,
                                 growScale: -0.65, growRadius: 0.45)
            p.left = beady
            p.right = beady
            p.widen = -0.25
            p.crownScale = 0.55
            p.crownRadius = 0.9
            p.crownLift = 0.62
            p.jawScale = -0.25
            p.mouthScale = -0.5
            p.cropHeight = 2.6
            p.cropLift = 0.2
        case .lopsided:
            // One eye grown huge, the other shrunk and half-lidded; which is
            // which is a coin toss.
            let big = EyeStyle(size: 1.28, growScale: 0.55, growRadius: 0.65)
            let small = EyeStyle(size: 0.75, lidSide: -0.2, lidPeak: -0.85, growScale: -0.45, growRadius: 0.45)
            if Bool.random() { p.left = big; p.right = small; p.note = "bigEye=imageLeft" }
            else { p.left = small; p.right = big; p.note = "bigEye=imageRight" }
        case .longFace:
            p.left.size = 0.95
            p.right.size = 0.95
            p.widen = -0.4
            p.lengthen = 0.45
            p.crownScale = 0.42
            p.crownRadius = 0.8
            p.jawScale = -0.2
            p.mouthScale = -0.55
            p.cropHeight = 2.6
            p.cropLift = 0.18
        case .squashed:
            p.widen = 0.45
            p.lengthen = -0.35
            p.cheeks = 0.45
            p.crownScale = 0.12
            p.jawScale = 0
            p.mouthScale = -0.45
        case .dome:
            p.left.size = 1.12
            p.right.size = 1.12
            p.crownScale = 0.62
            p.crownRadius = 0.95
            p.crownLift = 0.6
            p.jawScale = -0.55
            p.jawRadius = 0.7
            p.mouthScale = -0.75
            p.cropHeight = 2.7
            p.cropLift = 0.22
        }
        return p
    }

    /// Random, but never the same variant twice in a row.
    private static let pickLock = NSLock()
    nonisolated(unsafe) private static var lastVariant: Variant?
    static func nextVariant() -> Variant {
        pickLock.lock()
        defer { pickLock.unlock() }
        let choices = Variant.allCases.filter { $0 != lastVariant }
        let pick = choices.randomElement() ?? .googly
        lastVariant = pick
        return pick
    }

    static func transform(_ input: UIImage) -> UIImage { render(input).image }

    /// `variant` nil = Hallways decides (random, no immediate repeat).
    static func render(_ input: UIImage, variant chosen: Variant? = nil) -> Output {
        let started = CFAbsoluteTimeGetCurrent()
        let variant = chosen ?? nextVariant()
        let p = preset(variant)
        diag("hallwaysFace.begin", ["w": Double(input.size.width), "h": Double(input.size.height),
                                    "orientation": input.imageOrientation.rawValue, "hasCG": input.cgImage != nil])
        diag("hallwaysFace.variant", ["variant": variant.rawValue, "note": p.note.isEmpty ? "none" : p.note])

        // Upright pixels, at most 1280 on the long side.
        let maxSide: CGFloat = 1280
        let scale = min(1, maxSide / max(input.size.width, input.size.height))
        let size = CGSize(width: (input.size.width * scale).rounded(), height: (input.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            input.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cg = upright.cgImage, cg.width > 16, cg.height > 16 else {
            diag("hallwaysFace.failed", ["reason": "noPixels"])
            return Output(image: input, applied: false, variant: variant)
        }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let pixels = FacePixels(cg)

        // ---- Landmarks (Vision: origin bottom-left, same as Core Image) ----
        var fallbacks: [String] = []
        var faceBox = CGRect(x: w * 0.2, y: h * 0.25, width: w * 0.6, height: h * 0.5)
        var leftEye = CGPoint(x: w * 0.38, y: h * 0.58)
        var rightEye = CGPoint(x: w * 0.62, y: h * 0.58)
        var leftPupil: CGPoint?
        var rightPupil: CGPoint?
        var mouth = CGPoint(x: w * 0.5, y: h * 0.38)
        var mouthWidth = w * 0.18
        let request = VNDetectFaceLandmarksRequest()
        var visionError = ""
        do { try VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:]).perform([request]) }
        catch { visionError = "\(error)" }
        let faces = request.results ?? []
        let biggest = faces.max(by: { $0.boundingBox.width < $1.boundingBox.width })
        let framing = Self.framing(of: biggest?.boundingBox, mouthFound: (biggest?.landmarks?.outerLips?.pointCount ?? 0) > 0)
        diag("hallwaysFace.framing", ["framing": framing.rawValue,
                                      "box": biggest.map { String(format: "%.2f,%.2f %.2fx%.2f", $0.boundingBox.minX, $0.boundingBox.minY,
                                                                  $0.boundingBox.width, $0.boundingBox.height) } ?? "none"])
        if let face = biggest {
            let b = face.boundingBox
            faceBox = CGRect(x: b.minX * w, y: b.minY * h, width: b.width * w, height: b.height * h)
            let imageSize = CGSize(width: w, height: h)
            func center(_ region: VNFaceLandmarkRegion2D?, _ name: String) -> CGPoint? {
                guard let region, region.pointCount > 0 else { fallbacks.append(name); return nil }
                let points = region.pointsInImage(imageSize: imageSize)
                let sx = points.reduce(0) { $0 + $1.x }, sy = points.reduce(0) { $0 + $1.y }
                return CGPoint(x: sx / CGFloat(points.count), y: sy / CGFloat(points.count))
            }
            leftEye = center(face.landmarks?.leftEye, "leftEye")
                ?? CGPoint(x: faceBox.minX + faceBox.width * 0.32, y: faceBox.minY + faceBox.height * 0.62)
            rightEye = center(face.landmarks?.rightEye, "rightEye")
                ?? CGPoint(x: faceBox.minX + faceBox.width * 0.68, y: faceBox.minY + faceBox.height * 0.62)
            leftPupil = center(face.landmarks?.leftPupil, "leftPupil")
            rightPupil = center(face.landmarks?.rightPupil, "rightPupil")
            mouth = center(face.landmarks?.outerLips, "mouth")
                ?? CGPoint(x: faceBox.midX, y: faceBox.minY + faceBox.height * 0.22)
            if let lips = face.landmarks?.outerLips, lips.pointCount > 1 {
                let xs = lips.pointsInImage(imageSize: imageSize).map(\.x)
                mouthWidth = (xs.max() ?? 0) - (xs.min() ?? 0)
            } else {
                mouthWidth = faceBox.width * 0.4
            }
        } else {
            fallbacks.append("face")
        }
        let eyeSpan = max(hypot(rightEye.x - leftEye.x, rightEye.y - leftEye.y), w * 0.05)
        diag("hallwaysFace.landmarks", [
            "image": "\(Int(w))x\(Int(h))", "faces": faces.count, "faceDetected": !faces.isEmpty,
            "fallbacks": fallbacks.isEmpty ? "none" : fallbacks.joined(separator: ","),
            "faceBox": Self.describe(faceBox), "leftEye": Self.describe(leftEye), "rightEye": Self.describe(rightEye),
            "eyeSpan": Double(eyeSpan.rounded()), "eyeSpanOfFace": Double(eyeSpan / max(faceBox.width, 1)),
            "mouth": Self.describe(mouth), "mouthWidth": Double(mouthWidth.rounded()),
            "visionError": visionError.isEmpty ? "none" : visionError
        ])

        // Colours sampled from the person (identity lives here).
        let iris = pixels?.average(around: leftPupil ?? leftEye, radius: eyeSpan * 0.06, keep: 0.25...0.8)
            ?? RGB(r: 0.35, g: 0.25, b: 0.18)
        let skin = pixels?.average(around: CGPoint(x: (leftEye.x + rightEye.x) / 2, y: (leftEye.y + rightEye.y) / 2 - eyeSpan * 0.55),
                                   radius: eyeSpan * 0.12, keep: 0.2...0.8)
            ?? RGB(r: 0.78, g: 0.6, b: 0.5)

        var image = CIImage(cgImage: cg)
        func bump(_ at: CGPoint, radius: CGFloat, scale: CGFloat) {
            guard let filter = CIFilter(name: "CIBumpDistortion") else { return }
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: at.x, y: at.y), forKey: kCIInputCenterKey)
            filter.setValue(radius, forKey: kCIInputRadiusKey)
            filter.setValue(scale, forKey: kCIInputScaleKey)
            if let out = filter.outputImage?.cropped(to: image.extent) { image = out }
        }

        // The preset's per-eye styles are in IMAGE order; map them to Vision's eyes.
        let leftEyeIsImageLeft = leftEye.x <= rightEye.x
        let leftStyle = leftEyeIsImageLeft ? p.left : p.right       // style for Vision's leftEye
        let rightStyle = leftEyeIsImageLeft ? p.right : p.left      // style for Vision's rightEye

        // 1. The eyes grow (or shrink): push brows, lids and upper cheek.
        bump(leftEye, radius: eyeSpan * leftStyle.growRadius, scale: leftStyle.growScale)
        bump(rightEye, radius: eyeSpan * rightStyle.growRadius, scale: rightStyle.growScale)

        // 2. Paint the critter eyeballs over them (own layer, softened).
        let eyeLayer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false; return f
        }()).image { ctx in
            let flip = { (p: CGPoint) in CGPoint(x: p.x, y: h - p.y) }   // CI (bottom-left) -> UIKit (top-left)
            // Vision's left/right are the subject's; take them in image order so the lids stay on top.
            let (a, b) = leftEye.x <= rightEye.x ? (leftEye, rightEye) : (rightEye, leftEye)
            let roll = atan2(-(b.y - a.y), b.x - a.x)
            for (eye, pupil, style) in [(leftEye, leftPupil, leftStyle), (rightEye, rightPupil, rightStyle)] {
                Self.drawEyeball(in: ctx.cgContext, center: flip(eye), pupil: flip(pupil ?? eye), roll: roll,
                                 span: eyeSpan, iris: iris, skin: skin, style: style)
            }
        }
        if let layerCG = eyeLayer.cgImage {
            var eyes = CIImage(cgImage: layerCG)
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(eyes, forKey: kCIInputImageKey)
                blur.setValue(max(0.7, eyeSpan * 0.005), forKey: kCIInputRadiusKey)
                if let out = blur.outputImage?.cropped(to: eyes.extent) { eyes = out }
            }
            image = eyes.composited(over: image)
        }

        // 3. Small pinched mouth, softer narrower jaw, domed crown.
        func bumpIf(_ at: CGPoint, radius: CGFloat, scale: CGFloat) { if scale != 0 { bump(at, radius: radius, scale: scale) } }
        bumpIf(mouth, radius: max(mouthWidth * p.mouthRadius, eyeSpan * 0.38), scale: p.mouthScale)
        let eyeLine = (leftEye.y + rightEye.y) / 2
        bumpIf(CGPoint(x: faceBox.midX, y: faceBox.minY + faceBox.height * 0.08), radius: faceBox.width * p.jawRadius, scale: p.jawScale)
        bumpIf(CGPoint(x: faceBox.midX, y: eyeLine + faceBox.height * p.crownLift), radius: faceBox.width * p.crownRadius, scale: p.crownScale)

        // 3b. Variant-only proportions (all zero for the original face).
        if p.cheeks != 0 {
            // Below and a little outside each eye.
            for eye in [leftEye, rightEye] {
                let outward: CGFloat = eye.x < faceBox.midX ? -1 : 1
                bump(CGPoint(x: eye.x + outward * eyeSpan * 0.1, y: eye.y - eyeSpan * 0.6), radius: eyeSpan * 0.42, scale: p.cheeks)
            }
        }
        func linearBump(_ at: CGPoint, radius: CGFloat, angle: CGFloat, scale: CGFloat) {
            guard scale != 0, let filter = CIFilter(name: "CIBumpDistortionLinear") else { return }
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: at.x, y: at.y), forKey: kCIInputCenterKey)
            filter.setValue(radius, forKey: kCIInputRadiusKey)
            filter.setValue(angle, forKey: kCIInputAngleKey)
            filter.setValue(scale, forKey: kCIInputScaleKey)
            if let out = filter.outputImage?.cropped(to: image.extent) { image = out }
        }
        let midFace = CGPoint(x: faceBox.midX, y: (eyeLine + mouth.y) / 2)
        // Distortion acts across the line: a vertical line changes the face's width...
        linearBump(midFace, radius: faceBox.width * 0.8, angle: .pi / 2, scale: p.widen)
        // ...a horizontal line its length.
        linearBump(midFace, radius: faceBox.height * 0.6, angle: 0, scale: p.lengthen)

        // 4. The building's palette: a touch richer, warmer, vignetted.
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(image, forKey: kCIInputImageKey)
            controls.setValue(1.15, forKey: kCIInputSaturationKey)
            controls.setValue(1.08, forKey: kCIInputContrastKey)
            if let out = controls.outputImage { image = out }
        }
        if let warm = CIFilter(name: "CITemperatureAndTint") {
            warm.setValue(image, forKey: kCIInputImageKey)
            warm.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            warm.setValue(CIVector(x: 5600, y: 0), forKey: "inputTargetNeutral")
            if let out = warm.outputImage { image = out }
        }
        if let vignette = CIFilter(name: "CIVignette") {
            vignette.setValue(image, forKey: kCIInputImageKey)
            vignette.setValue(0.9, forKey: kCIInputIntensityKey)
            vignette.setValue(1.6, forKey: kCIInputRadiusKey)
            if let out = vignette.outputImage { image = out }
        }

        // 5. ID portrait: 3:4 around the face, headroom for the crown.
        let cropH = min(h, faceBox.height * p.cropHeight)
        let cropW = min(w, cropH * 0.75)
        var crop = CGRect(x: faceBox.midX - cropW / 2, y: faceBox.midY + faceBox.height * p.cropLift - cropH / 2, width: cropW, height: cropH)
        crop.origin.x = min(max(0, crop.origin.x), w - cropW)
        crop.origin.y = min(max(0, crop.origin.y), h - cropH)
        crop = crop.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = CIContext().createCGImage(image.cropped(to: crop), from: crop) else {
            diag("hallwaysFace.failed", ["reason": "render"])
            var failed = Output(image: upright, applied: false, variant: variant)
            failed.framing = framing
            return failed
        }
        // How much the rule actually changed the portrait (0 = identical, 1 = inverted).
        let before = cg.cropping(to: CGRect(x: crop.minX, y: h - crop.maxY, width: crop.width, height: crop.height))
        let delta = before.map { Self.meanDifference($0, out) } ?? -1
        diag("hallwaysFace.done", ["applied": true, "variant": variant.rawValue, "out": "\(out.width)x\(out.height)", "crop": Self.describe(crop),
                                   "meanDelta": delta, "ms": ((CFAbsoluteTimeGetCurrent() - started) * 1000).rounded()])
        var output = Output(image: UIImage(cgImage: out), applied: true, variant: variant)
        output.framing = framing
        return output
    }

    // MARK: The critter eyeball

    nonisolated struct RGB {
        var r: CGFloat, g: CGFloat, b: CGFloat
        func scaled(_ k: CGFloat) -> RGB { RGB(r: min(1, r * k), g: min(1, g * k), b: min(1, b * k)) }
        func mixed(_ o: RGB, _ t: CGFloat) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
        func color(_ a: CGFloat = 1) -> CGColor { UIColor(red: r, green: g, blue: b, alpha: a).cgColor }
    }

    /// One round, bulging eyeball in UIKit coordinates (origin top-left).
    private static func drawEyeball(in cg: CGContext, center c: CGPoint, pupil: CGPoint, roll: CGFloat,
                                    span e: CGFloat, iris irisRGB: RGB, skin: RGB, style: EyeStyle = EyeStyle()) {
        let rs = e * 0.31 * style.size          // eyeball radius (the real eye is ~0.24 x span wide, ~0.08 tall)
        let ir = rs * style.irisRatio           // iris radius (0.15 x span for the original eye)
        let space = CGColorSpaceCreateDeviceRGB()
        func radial(_ colors: [CGColor], _ locations: [CGFloat], from p0: CGPoint, _ r0: CGFloat, to p1: CGPoint, _ r1: CGFloat,
                    options: CGGradientDrawingOptions = []) {
            guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else { return }
            cg.drawRadialGradient(g, startCenter: p0, startRadius: r0, endCenter: p1, endRadius: r1, options: options)
        }
        cg.saveGState()
        cg.translateBy(x: c.x, y: c.y)
        cg.rotate(by: roll)
        let circle = CGRect(x: -rs, y: -rs, width: rs * 2, height: rs * 2)
        let dark = skin.scaled(0.28)

        // Contact shadow on the face, below the ball.
        radial([UIColor(white: 0, alpha: 0.38).cgColor, UIColor(white: 0, alpha: 0.22).cgColor, UIColor(white: 0, alpha: 0).cgColor],
               [0, 0.72, 1], from: CGPoint(x: 0, y: e * 0.05), 0, to: CGPoint(x: 0, y: e * 0.05), rs * 1.28)

        // Sclera: a lit sphere.
        cg.saveGState()
        cg.addEllipse(in: circle)
        cg.clip()
        radial([RGB(r: 1, g: 0.98, b: 0.94).color(), RGB(r: 0.93, g: 0.9, b: 0.85).color(), RGB(r: 0.66, g: 0.6, b: 0.56).color()],
               [0, 0.55, 1], from: CGPoint(x: -rs * 0.3, y: -rs * 0.35), 0, to: CGPoint(x: -rs * 0.1, y: -rs * 0.1), rs * 1.35,
               options: [.drawsAfterEndLocation])

        // Iris: the person's own colour, centred on their gaze.
        var offset = CGPoint(x: (pupil.x - c.x) * 1.4, y: (pupil.y - c.y) * 1.4)
        let maxOff = rs - ir - e * 0.03
        let len = hypot(offset.x, offset.y)
        if len > maxOff, len > 0 { offset = CGPoint(x: offset.x / len * maxOff, y: offset.y / len * maxOff) }
        let ic = CGPoint(x: offset.x, y: offset.y + e * 0.01)
        let irisSat = irisRGB.mixed(RGB(r: 0.45, g: 0.32, b: 0.2), 0.15)
        radial([irisSat.scaled(1.35).color(), irisSat.color(), irisSat.scaled(0.45).color()], [0, 0.6, 1],
               from: ic, ir * 0.25, to: ic, ir, options: [.drawsBeforeStartLocation])
        cg.setStrokeColor(irisSat.scaled(0.4).color(0.35))
        cg.setLineWidth(max(1, e * 0.006))
        for k in 0..<18 {
            let a = CGFloat(k) / 18 * 2 * .pi
            cg.move(to: CGPoint(x: ic.x + cos(a) * ir * 0.42, y: ic.y + sin(a) * ir * 0.42))
            cg.addLine(to: CGPoint(x: ic.x + cos(a) * ir * 0.92, y: ic.y + sin(a) * ir * 0.92))
        }
        cg.strokePath()
        cg.setStrokeColor(irisSat.scaled(0.25).color(0.9))
        cg.setLineWidth(max(1, e * 0.014))
        cg.strokeEllipse(in: CGRect(x: ic.x - ir, y: ic.y - ir, width: ir * 2, height: ir * 2))
        cg.setFillColor(UIColor(red: 0.03, green: 0.02, blue: 0.02, alpha: 1).cgColor)
        let pr = ir * (0.065 / 0.15)            // pupil (0.065 x span for the original eye)
        cg.fillEllipse(in: CGRect(x: ic.x - pr, y: ic.y - pr, width: pr * 2, height: pr * 2))
        // Catchlights.
        cg.setFillColor(UIColor(white: 1, alpha: 0.95).cgColor)
        let h1 = ir * 0.32
        cg.fillEllipse(in: CGRect(x: ic.x - ir * 0.42 - h1, y: ic.y - ir * 0.42 - h1, width: h1 * 2, height: h1 * 2))
        cg.setFillColor(UIColor(white: 1, alpha: 0.6).cgColor)
        let h2 = ir * 0.12
        cg.fillEllipse(in: CGRect(x: ic.x + ir * 0.38 - h2, y: ic.y + ir * 0.4 - h2, width: h2 * 2, height: h2 * 2))

        // Upper lid in the person's skin tone, with a lash line (keeps it wide open).
        let lid = CGMutablePath()
        let sideY = rs * style.lidSide, peakY = rs * style.lidPeak
        lid.move(to: CGPoint(x: -rs * 1.1, y: -rs * 1.1))
        lid.addLine(to: CGPoint(x: rs * 1.1, y: -rs * 1.1))
        lid.addLine(to: CGPoint(x: rs * 1.1, y: sideY))
        lid.addQuadCurve(to: CGPoint(x: -rs * 1.1, y: sideY), control: CGPoint(x: 0, y: peakY))
        lid.closeSubpath()
        cg.addPath(lid)
        cg.saveGState()
        cg.clip()
        if let lidShade = CGGradient(colorsSpace: space, colors: [skin.scaled(1.05).color(), skin.scaled(0.8).color()] as CFArray,
                                     locations: [0, 1]) {
            cg.drawLinearGradient(lidShade, start: CGPoint(x: 0, y: -rs), end: CGPoint(x: 0, y: -rs * 0.5),
                                  options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        cg.restoreGState()
        let lash = CGMutablePath()
        lash.move(to: CGPoint(x: rs * 1.1, y: sideY))
        lash.addQuadCurve(to: CGPoint(x: -rs * 1.1, y: sideY), control: CGPoint(x: 0, y: peakY))
        cg.addPath(lash)
        cg.setStrokeColor(dark.scaled(0.6).color(0.95))
        cg.setLineWidth(e * 0.03)
        cg.strokePath()
        cg.restoreGState()   // end sclera clip

        // Rim (the bulge's edge) and a lower-lid bag.
        cg.setStrokeColor(dark.color(0.8))
        cg.setLineWidth(e * 0.022)
        cg.strokeEllipse(in: circle)
        cg.setStrokeColor(dark.color(0.3))
        cg.setLineWidth(e * 0.03)
        cg.addArc(center: .zero, radius: rs + e * 0.035, startAngle: .pi * 0.2, endAngle: .pi * 0.8, clockwise: false)
        cg.strokePath()
        cg.restoreGState()
    }

    // MARK: Helpers

    private static func describe(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))" }
    private static func describe(_ p: CGPoint) -> String { "\(Int(p.x)),\(Int(p.y))" }

    /// Mean absolute per-channel difference of two images at 48x64 (0...1).
    private static func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
        func bytes(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: 48 * 64 * 4)
            data.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: 48, height: 64, bitsPerComponent: 8, bytesPerRow: 48 * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: 48, height: 64))
            }
            return data
        }
        let x = bytes(a), y = bytes(b)
        var sum = 0.0, n = 0.0
        for i in stride(from: 0, to: x.count, by: 4) {
            for k in 0..<3 { sum += abs(Double(x[i + k]) - Double(y[i + k])); n += 1 }
        }
        return n > 0 ? ((sum / n / 255) * 1000).rounded() / 1000 : -1
    }
}

/// Read-only RGBA8 copy of an image, for sampling skin and iris colour.
nonisolated private struct FacePixels {
    let width: Int
    let height: Int
    let data: [UInt8]

    init?(_ cg: CGImage) {
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        width = w
        height = h
        data = bytes
    }

    /// Average colour within `radius` of `center` (bottom-left coordinates),
    /// keeping only the given luminance percentile band (drops pupil, lashes, glare).
    func average(around center: CGPoint, radius: CGFloat, keep: ClosedRange<Double>) -> HallwaysFace.RGB? {
        let r = max(2, radius)
        let topY = CGFloat(height) - center.y          // memory rows run top-down
        let x0 = max(0, Int(center.x - r)), x1 = min(width - 1, Int(center.x + r))
        let y0 = max(0, Int(topY - r)), y1 = min(height - 1, Int(topY + r))
        guard x0 <= x1, y0 <= y1 else { return nil }
        let step = max(1, Int(r / 10))
        var samples: [(l: Double, r: Double, g: Double, b: Double)] = []
        for y in stride(from: y0, through: y1, by: step) {
            for x in stride(from: x0, through: x1, by: step) {
                let dx = CGFloat(x) - center.x, dy = CGFloat(y) - topY
                guard dx * dx + dy * dy <= r * r else { continue }
                let i = (y * width + x) * 4
                let R = Double(data[i]) / 255, G = Double(data[i + 1]) / 255, B = Double(data[i + 2]) / 255
                samples.append((0.299 * R + 0.587 * G + 0.114 * B, R, G, B))
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort { $0.l < $1.l }
        let lo = min(samples.count - 1, Int(Double(samples.count) * keep.lowerBound))
        let hi = max(lo + 1, min(samples.count, Int(Double(samples.count) * keep.upperBound)))
        let band = samples[lo..<hi]
        let n = Double(band.count)
        return HallwaysFace.RGB(r: CGFloat(band.reduce(0) { $0 + $1.r } / n),
                                g: CGFloat(band.reduce(0) { $0 + $1.g } / n),
                                b: CGFloat(band.reduce(0) { $0 + $1.b } / n))
    }
}
