import SwiftUI
import Combine
import UIKit
import QuartzCore

// Oct 7 -- FRAGILE on the office computer: the bubble-wrap fidget toy.
//
// The whole game area is the open box: a sheet of bubble wrap on cardboard.
// Touch a bubble and it pops on touch-DOWN; keep your finger down and drag,
// and every bubble you run over pops in turn. Bubbles are ~30 pt on the
// phone and the sheet catches any touch within 0.6 of a bubble's centre, so
// thumb-hammering is the intended technique. All touches stay on the
// monitor's own surface (one drag gesture on the sheet), so nothing reaches
// the room.
//
// There is deliberately no score, no clock, no fail state and no New
// button: the only number is a running tally of bubbles popped. A cleared
// sheet is pulled away and a fresh one comes off the roll by itself.
// Session: the half-popped sheet and the tally are retained by
// OfficeComputer.games (nothing on disk). There are no gameplay timers to
// pause; only the short animations, which simply finish.

struct FragilePopMark {
    let time: Double
    let run: Int
    let stubborn: Bool
}

final class FragileSession: ObservableObject {
    @Published private(set) var game: FragileGame
    @Published private(set) var transitionStart: Double?
    private(set) var pops: [Int: FragilePopMark] = [:]
    private(set) var squishes: [Int: Double] = [:]

    private var rng = SystemRandomNumberGenerator()
    private let tapHaptic = UIImpactFeedbackGenerator(style: .light)
    private let bangHaptic = UIImpactFeedbackGenerator(style: .rigid)
    private let softHaptic = UIImpactFeedbackGenerator(style: .soft)

    static let peelDelay = 0.45          // a beat to admire the flat sheet
    static let slideOut = 0.35
    static let slideIn = 0.45

    static func now() -> Double { CACurrentMediaTime() }

    init() {
        var r = SystemRandomNumberGenerator()
        game = FragileGame(rng: &r)
        FragileSound.warmUp()
    }

    func appeared() {
        tapHaptic.prepare()
        bangHaptic.prepare()
        softHaptic.prepare()
    }

    func press(_ index: Int) {
        guard transitionStart == nil else { return }
        let t = Self.now()
        switch game.press(index, at: t) {
        case .nothing:
            break
        case .squished(let i):
            squishes[i] = t
            FragileSound.play(.squeak, pan: pan(i))
            softHaptic.impactOccurred(intensity: 0.6)
        case .popped(let i, let run, let stubborn, let cleared):
            pops[i] = FragilePopMark(time: t, run: run, stubborn: stubborn)
            squishes[i] = nil
            if stubborn {
                FragileSound.play(.bang, pan: pan(i), volume: 1)
                bangHaptic.impactOccurred(intensity: 1)
            } else {
                FragileSound.play(.pop(Int.random(in: 0..<FragileSound.variants), min(run - 1, FragileGame.maxRunStep)),
                                  pan: pan(i), volume: Float.random(in: 0.8...0.95))
                tapHaptic.impactOccurred(intensity: CGFloat.random(in: 0.55...0.8))
            }
            if cleared { pullNextSheet() }
        }
    }

    private func pan(_ i: Int) -> Float {
        Float(FragileGame.center(of: i).x / FragileGame.sheetWidth * 2 - 1) * 0.6
    }

    private func pullNextSheet() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.peelDelay) { [weak self] in
            guard let self else { return }
            self.transitionStart = Self.now()
            FragileSound.play(.peel)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideOut) { [weak self] in
                guard let self else { return }
                self.game.nextSheet(rng: &self.rng)
                self.pops = [:]
                self.squishes = [:]
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideIn) { [weak self] in
                    self?.transitionStart = nil
                }
            }
        }
    }
}

enum FragilePalette {
    static let accent = Color(red: 0.72, green: 0.55, blue: 0.36)          // kraft
    static let cardboardTop = Color(red: 0.80, green: 0.66, blue: 0.48)
    static let cardboardBottom = Color(red: 0.70, green: 0.55, blue: 0.38)

    static func bubble(_ wrap: FragileWrap) -> Color {
        switch wrap {
        case .clear: return Color(red: 0.80, green: 0.90, blue: 0.97)
        case .pink: return Color(red: 1.0, green: 0.68, blue: 0.80)
        case .blue: return Color(red: 0.6, green: 0.8, blue: 1.0)
        }
    }

    static func film(_ wrap: FragileWrap) -> Color {
        switch wrap {
        case .clear: return Color(red: 0.93, green: 0.96, blue: 0.99)
        case .pink: return Color(red: 1.0, green: 0.82, blue: 0.9)
        case .blue: return Color(red: 0.78, green: 0.89, blue: 1.0)
        }
    }
}

struct FragileComputerGame: View {
    @ObservedObject var session: FragileSession
    @State private var lastIndex: Int?

    init(session: FragileSession) {
        _session = ObservedObject(wrappedValue: session)
    }

    private var game: FragileGame { session.game }

    var body: some View {
        GeometryReader { geo in
            let footer: CGFloat = 16
            let area = CGSize(width: geo.size.width, height: max(1, geo.size.height - footer))
            let p = min((area.width - 10) / CGFloat(FragileGame.sheetWidth), (area.height - 10) / CGFloat(FragileGame.sheetHeight))
            let origin = CGPoint(x: (area.width - p * CGFloat(FragileGame.sheetWidth)) / 2,
                                 y: (area.height - p * CGFloat(FragileGame.sheetHeight)) / 2)
            VStack(spacing: 0) {
                TimelineView(.animation) { _ in
                    Canvas { ctx, size in draw(&ctx, size: size, p: p, origin: origin, now: FragileSession.now()) }
                }
                .frame(width: area.width, height: area.height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let i = FragileGame.index(atX: Double((v.location.x - origin.x) / p), y: Double((v.location.y - origin.y) / p))
                        guard i != lastIndex else { return }
                        lastIndex = i
                        if let i { session.press(i) }
                    }
                    .onEnded { _ in lastIndex = nil })
                footerLine.frame(height: footer)
            }
        }
        .onAppear { session.appeared() }
    }

    private var footerLine: some View {
        HStack {
            Text(game.totalPopped == 0 ? "Go on." : "\(game.totalPopped.formatted()) popped")
                .monospacedDigit()
            Spacer()
            Text(game.wrap == .pink ? "Sheet \(game.sheet) \u{00B7} anti-static" : "Sheet \(game.sheet)")
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .foregroundStyle(HallwaysOS.inkSoft)
        .padding(.horizontal, 6)
    }

    // MARK: Drawing

    private static func ease(_ u: Double) -> Double { let x = max(0, min(1, u)); return x * x * (3 - 2 * x) }
    private static func easeOut(_ u: Double) -> Double { let x = max(0, min(1, u)); return 1 - (1 - x) * (1 - x) }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, p: CGFloat, origin: CGPoint, now: Double) {
        // The open box.
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [FragilePalette.cardboardTop, FragilePalette.cardboardBottom]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

        // The sheet slides off to the left when it's done; the new one comes in from the right.
        var dx: CGFloat = 0
        if let ts = session.transitionStart {
            let t = now - ts
            if t < FragileSession.slideOut {
                dx = -CGFloat(Self.ease(t / FragileSession.slideOut)) * size.width
            } else {
                dx = CGFloat(1 - Self.ease((t - FragileSession.slideOut) / FragileSession.slideIn)) * size.width
            }
        }

        let wrap = game.wrap
        let tint = FragilePalette.bubble(wrap)
        let sheetRect = CGRect(x: origin.x + dx - 0.14 * p, y: origin.y - 0.14 * p,
                               width: p * CGFloat(FragileGame.sheetWidth) + 0.28 * p,
                               height: p * CGFloat(FragileGame.sheetHeight) + 0.28 * p)
        ctx.fill(Path(roundedRect: sheetRect.offsetBy(dx: 2, dy: 3), cornerRadius: 0.16 * p), with: .color(Color.black.opacity(0.12)))
        ctx.fill(Path(roundedRect: sheetRect, cornerRadius: 0.16 * p), with: .color(FragilePalette.film(wrap).opacity(0.55)))
        ctx.stroke(Path(roundedRect: sheetRect, cornerRadius: 0.16 * p), with: .color(Color.white.opacity(0.45)), lineWidth: 1)

        let R = 0.45 * p
        for i in 0..<FragileGame.count {
            let cp = FragileGame.center(of: i)
            let c = CGPoint(x: origin.x + dx + CGFloat(cp.x) * p, y: origin.y + CGFloat(cp.y) * p)
            let b = game.bubbles[i]
            if !b.popped {
                var sx: CGFloat = 1, sy: CGFloat = 1
                if b.stubborn && b.pressesLeft == 1 { sx = 0.95; sy = 0.93 }        // dented, still holding
                if let t0 = session.squishes[i], now - t0 < 0.6 {
                    let a = now - t0
                    let w = CGFloat(exp(-a * 9) * cos(a * 38))
                    sx += 0.10 * w
                    sy -= 0.14 * w
                }
                dome(&ctx, c, R, sx, sy, tint, alpha: 1, glow: 0)
                if b.stubborn && b.pressesLeft == 1 {
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 0.22 * R, y: c.y - 0.08 * R, width: 0.44 * R, height: 0.28 * R)),
                             with: .color(Color.black.opacity(0.08)))
                }
                continue
            }
            guard let mark = session.pops[i], now - mark.time < 0.32 else {
                crater(&ctx, c, R, i, tint, alpha: 1, scale: 1)
                continue
            }
            let a = now - mark.time
            // 1. squash: the dome flattens and brightens under the finger
            if a < 0.035 {
                let k = CGFloat(a / 0.035)
                dome(&ctx, c, R, 1 + 0.15 * k, 1 - 0.18 * k, tint, alpha: 1, glow: k)
            } else if a < 0.1 {
                // 2. snap: it collapses
                let s = CGFloat(1 - (a - 0.035) / 0.065)
                dome(&ctx, c, R, 1.15 * s, 0.82 * s, tint, alpha: Double(s), glow: s)
            }
            // 3. the flat crater appears with a small rebound
            if a >= 0.03 {
                let b2 = a - 0.03
                let alpha = min(1, b2 / 0.05)
                let bounce = CGFloat(1 + 0.1 * exp(-b2 * 16) * cos(b2 * 42))
                crater(&ctx, c, R, i, tint, alpha: alpha, scale: bounce)
            }
            // 4. a ring of air and a few glints
            if a >= 0.03, a < 0.27 {
                let u = (a - 0.03) / 0.24
                let reach: CGFloat = mark.stubborn ? 1.0 : 0.6
                let r = R * (1 + reach * CGFloat(Self.easeOut(u)))
                let bright = min(1, 0.7 + 0.04 * Double(mark.run))
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(Color.white.opacity(bright * (1 - u))),
                           lineWidth: 0.1 * R * CGFloat(1 - u) + 0.6)
            }
            if a >= 0.03, a < 0.3 {
                let u = (a - 0.03) / 0.27
                let n = mark.stubborn ? 9 : 5
                for k in 0..<n {
                    let ang = Double(i) * 2.39 + Double(k) * 2 * .pi / Double(n)
                    let dist = R * CGFloat(0.7 + (mark.stubborn ? 1.4 : 0.9) * Self.easeOut(u))
                    let gx = c.x + CGFloat(cos(ang)) * dist
                    let gy = c.y + CGFloat(sin(ang)) * dist + R * 0.6 * CGFloat(u * u)
                    let gs = 0.09 * R * CGFloat(1 - u) + 0.5
                    ctx.fill(Path(ellipseIn: CGRect(x: gx - gs, y: gy - gs, width: 2 * gs, height: 2 * gs)),
                             with: .color(Color.white.opacity(0.9 * (1 - u))))
                }
            }
        }
    }

    /// An unpopped bubble: a glassy dome with a highlight.
    private func dome(_ ctx: inout GraphicsContext, _ c: CGPoint, _ R: CGFloat, _ sx: CGFloat, _ sy: CGFloat, _ tint: Color, alpha: Double, glow: CGFloat) {
        let w = 2 * R * sx, h = 2 * R * sy
        let rect = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        ctx.fill(Path(ellipseIn: rect.offsetBy(dx: 0.05 * R, dy: 0.09 * R)), with: .color(Color.black.opacity(0.14 * alpha)))
        let hi = CGPoint(x: c.x - 0.3 * R * sx, y: c.y - 0.35 * R * sy)
        ctx.fill(Path(ellipseIn: rect),
                 with: .radialGradient(Gradient(colors: [Color.white.opacity(0.95 * alpha),
                                                         tint.opacity((0.75 + 0.2 * Double(glow)) * alpha),
                                                         tint.opacity((0.5 + 0.3 * Double(glow)) * alpha)]),
                                       center: hi, startRadius: 0, endRadius: R * 1.3))
        ctx.stroke(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.6 * alpha)), lineWidth: max(1, 0.06 * R))
        let spec = CGRect(x: c.x - 0.58 * R * sx, y: c.y - 0.58 * R * sy, width: 0.42 * R * sx, height: 0.26 * R * sy)
        ctx.fill(Path(ellipseIn: spec), with: .color(Color.white.opacity(0.9 * alpha)))
    }

    /// A popped bubble: a flat, creased circle of film.
    private func crater(_ ctx: inout GraphicsContext, _ c: CGPoint, _ R: CGFloat, _ i: Int, _ tint: Color, alpha: Double, scale: CGFloat) {
        let r = R * 0.92 * scale
        let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        ctx.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.3 * alpha)))
        ctx.stroke(Path(ellipseIn: rect), with: .color(Color.black.opacity(0.1 * alpha)), lineWidth: 1)
        for k in 0..<3 {
            let ang = Double((i * 73 + k * 151) % 360) * .pi / 180
            let len = r * CGFloat(0.45 + Double((i * 31 + k * 17) % 40) / 100)
            let ox = CGFloat(Double((i * 13 + k * 29) % 21 - 10) / 30) * r
            let oy = CGFloat(Double((i * 19 + k * 7) % 21 - 10) / 30) * r
            let d = CGPoint(x: CGFloat(cos(ang)) * len / 2, y: CGFloat(sin(ang)) * len / 2)
            var crease = Path()
            crease.move(to: CGPoint(x: c.x + ox - d.x, y: c.y + oy - d.y))
            crease.addLine(to: CGPoint(x: c.x + ox + d.x, y: c.y + oy + d.y))
            ctx.stroke(crease, with: .color(Color.black.opacity(0.12 * alpha)), lineWidth: 1.2)
            ctx.stroke(crease.offsetBy(dx: 0, dy: -0.8), with: .color(Color.white.opacity(0.5 * alpha)), lineWidth: 0.8)
        }
    }
}
