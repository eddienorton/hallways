import SwiftUI
import Combine

// Oct 7 -- LETTERHEAD on the office computer: a timed word-building game.
// Six letters (always the letters of a real six-letter word), 75 seconds,
// make as many 3-6 letter words as you can. Scoring 1/2/4/8 by length
// (3/4/5/6 letters) -- this little game's own score, nothing else.
//
// Layout for the ~482 x 204 game area:
//   left:  [clock bar . 0:42 . score]
//          [the word being built -- or the last result, briefly]
//          [the six rack tiles, big]
//          [Shuffle] [delete] [Clear] [   Enter   ]
//   right: the words found so far (after the round: found + missed).
// Session: the round (rack, found words, the word being built, the deadline)
// lives in LetterheadSession, retained by OfficeComputer.games. The clock is
// a real deadline -- it keeps running while the game is closed.

final class LetterheadSession: ObservableObject {
    struct Feedback: Equatable {
        enum Tone { case good, great, bad }
        let id = UUID()
        let text: String
        let tone: Tone
    }

    @Published var round: LetterheadRound
    @Published var feedback: Feedback?
    @Published private(set) var finished = false
    private var rng = SystemRandomNumberGenerator()
    private var lastTick: Int?

    init() {
        var r = SystemRandomNumberGenerator()
        round = LetterheadRound.random(rng: &r)
        LetterheadSound.prepare(.word(6))                       // the big one is ready when it's earned
    }

    /// Called a few times a second while the game is on screen. `live` is
    /// false for the first check after (re)opening, so a round that ran out
    /// while the player was away just shows its end, without the alarm.
    func checkClock(live: Bool, now: Date = Date()) {
        guard !finished else { return }
        if round.isOver(at: now) {
            finished = true
            feedback = nil
            guard live else { return }
            LetterheadSound.play(.timeUp)
            let tier = resultTier
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { LetterheadSound.play(.result(tier)) }
            return
        }
        let secs = Int(ceil(round.remaining(at: now)))
        if live, secs <= 5, secs != lastTick {
            lastTick = secs
            LetterheadSound.play(.tick(secs))
        }
    }

    var resultTier: Int {
        if round.foundSixLetter { return 3 }
        switch round.score {
        case 16...: return 2
        case 8...: return 1
        default: return 0
        }
    }

    // MARK: Play

    func tap(_ id: Int) {
        guard !finished, round.tap(id) else { return }
        feedback = nil
        LetterheadSound.play(.tap(round.current.count))
    }

    func backspace() {
        guard !finished, round.backspace() else { return }
        LetterheadSound.play(.remove)
    }

    func clear() {
        guard !finished, round.clear() else { return }
        LetterheadSound.play(.clear)
    }

    func shuffle() {
        guard !finished else { return }
        round.shuffle(using: &rng)
        LetterheadSound.play(.shuffle)
    }

    func submit() {
        guard !finished else { return }
        switch round.submit(isValid: { WoidleSystemDictionary.isValidWord($0) }) {
        case .accepted(let word, let points):
            LetterheadSound.play(.word(word.count))
            show(word.count == 6 ? "\(word)!  +\(points)" : "\(word)  +\(points)", word.count == 6 ? .great : .good)
        case .duplicate(let word):
            LetterheadSound.play(.nope)
            show("\(word): already found", .bad)
        case .notAWord(let word):
            LetterheadSound.play(.nope)
            show("\(word): not a word", .bad)
        case .tooShort:
            LetterheadSound.play(.nope)
            show("Three letters or more", .bad)
        case .timeUp:
            checkClock(live: true)
        }
    }

    private func show(_ text: String, _ tone: Feedback.Tone) {
        let f = Feedback(text: text, tone: tone)
        withAnimation(.easeOut(duration: 0.12)) { feedback = f }
        DispatchQueue.main.asyncAfter(deadline: .now() + (tone == .great ? 2.2 : 1.3)) { [weak self] in
            guard let self, self.feedback?.id == f.id else { return }
            withAnimation(.easeIn(duration: 0.2)) { self.feedback = nil }
        }
    }
}

enum LetterheadPalette {
    static let ink = Color(red: 0.16, green: 0.3, blue: 0.56)
    static let tile = Color(red: 0.99, green: 0.97, blue: 0.9)          // cream card stock
    static let tileEdge = Color(red: 0.72, green: 0.64, blue: 0.48)
    static let slot = Color.white.opacity(0.7)
    static let good = Color(red: 0.12, green: 0.6, blue: 0.4)
    static let great = Color(red: 0.86, green: 0.6, blue: 0.08)
    static let bad = Color(red: 0.82, green: 0.3, blue: 0.3)
}

struct LetterheadComputerGame: View {
    let restart: () -> Void
    @ObservedObject var session: LetterheadSession

    init(restart: @escaping () -> Void, session: LetterheadSession) {
        self.restart = restart
        _session = ObservedObject(wrappedValue: session)
    }

    private var round: LetterheadRound { session.round }

    var body: some View {
        GeometryReader { geo in
            let leftW = (geo.size.width * 0.64).rounded()
            let rightW = geo.size.width - leftW - 10
            let gap: CGFloat = 5
            let tileW = (leftW - 5 * gap) / 6
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if session.finished { endPanel } else { playPanel(tileW: tileW, gap: gap) }
                }
                .frame(width: leftW, height: geo.size.height)
                wordBoard
                    .frame(width: rightW, height: geo.size.height)
            }
        }
        .task {
            // The clock: first look without fanfare (it may have run out while
            // the game was closed), then a few looks a second until it ends.
            session.checkClock(live: false)
            while !Task.isCancelled && !session.finished {
                try? await Task.sleep(nanoseconds: 200_000_000)
                session.checkClock(live: true)
            }
        }
    }

    // MARK: Playing

    private func playPanel(tileW: CGFloat, gap: CGFloat) -> some View {
        VStack(spacing: 7) {
            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in clockRow(now: ctx.date) }
                .frame(height: 24)
            builtWord(tileW: tileW, gap: gap)
                .frame(height: 44)
            HStack(spacing: gap) {
                ForEach(round.order, id: \.self) { id in rackTile(id, width: tileW) }
            }
            .frame(height: 54)
            HStack(spacing: 6) {
                control(icon: "shuffle", label: nil, width: 54) { session.shuffle() }
                control(icon: "delete.left", label: nil, width: 54) { session.backspace() }
                control(icon: nil, label: "Clear", width: 66) { session.clear() }
                Button { session.submit() } label: {
                    Text("Enter").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(round.currentWord.count >= 3 ? LetterheadPalette.ink : LetterheadPalette.ink.opacity(0.4),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: 40)
        }
    }

    private func clockRow(now: Date) -> some View {
        let left = round.remaining(at: now)
        let fraction = CGFloat(left / LetterheadRound.duration)
        let color: Color = left <= 10 ? LetterheadPalette.bad : (left <= 25 ? LetterheadPalette.great : LetterheadPalette.good)
        return HStack(spacing: 8) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.1))
                    Capsule().fill(color).frame(width: max(8, g.size.width * fraction))
                }
            }
            .frame(height: 10)
            Text(String(format: "%d:%02d", Int(ceil(left)) / 60, Int(ceil(left)) % 60))
                .font(.system(size: 16, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(left <= 10 ? LetterheadPalette.bad : HallwaysOS.ink)
            Text("\(round.score)")
                .font(.system(size: 16, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 9).frame(height: 24)
                .background(LetterheadPalette.ink, in: Capsule())
        }
    }

    private func builtWord(tileW: CGFloat, gap: CGFloat) -> some View {
        ZStack {
            HStack(spacing: gap) {
                let letters = Array(round.currentWord)
                ForEach(0..<6, id: \.self) { i in
                    Text(i < letters.count ? String(letters[i]) : "")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(HallwaysOS.ink)
                        .frame(width: tileW, height: 40)
                        .background(LetterheadPalette.slot, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(Rectangle().fill(LetterheadPalette.ink.opacity(i < letters.count ? 0.9 : 0.25)).frame(height: 2.5),
                                 alignment: .bottom)
                }
            }
            .opacity(session.feedback == nil ? 1 : 0)
            if let f = session.feedback {
                Text(f.text)
                    .font(.system(size: f.tone == .great ? 24 : 19, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(color(f.tone), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
    }

    private func rackTile(_ id: Int, width: CGFloat) -> some View {
        let used = round.isUsed(id)
        let letter = round.tiles.first { $0.id == id }.map { String($0.letter) } ?? ""
        return Button { session.tap(id) } label: {
            Text(letter)
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundStyle(LetterheadPalette.ink)
                .frame(width: width, height: 54)
                .background(LetterheadPalette.tile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(LetterheadPalette.tileEdge, lineWidth: 1.5))
                .shadow(color: .black.opacity(used ? 0 : 0.18), radius: 2, y: 2)
                .opacity(used ? 0.22 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!used)
    }

    private func control(icon: String?, label: String?, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let icon { Image(systemName: icon).font(.system(size: 17, weight: .bold)) }
                else { Text(label ?? "").font(.system(size: 15, weight: .bold, design: .rounded)) }
            }
            .foregroundStyle(LetterheadPalette.ink)
            .frame(width: width, height: 40)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LetterheadPalette.ink.opacity(0.25), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Round over

    private var endPanel: some View {
        VStack(spacing: 10) {
            Text("Time!").font(.system(size: 30, weight: .black, design: .rounded)).foregroundStyle(LetterheadPalette.ink)
            Text("Score \(round.score)  \u{00B7}  \(round.found.count) word\(round.found.count == 1 ? "" : "s")")
                .font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(HallwaysOS.ink)
            if round.foundSixLetter {
                Text("\u{2605} \(round.found.first { $0.count == 6 } ?? "")")
                    .font(.system(size: 20, weight: .black, design: .rounded)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(LetterheadPalette.great, in: Capsule())
            } else {
                Text("The six: \(round.sixLetterWords.first ?? round.base)")
                    .font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(HallwaysOS.inkSoft)
            }
            BigButton(title: "New rack", color: LetterheadPalette.ink, action: restart)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Word board

    private var wordBoard: some View {
        let knownCount = Set(round.known).union(round.found).count
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(round.found.count) / \(knownCount) words")
                .font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(LetterheadPalette.ink)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], alignment: .leading, spacing: 3) {
                    ForEach(round.found.reversed(), id: \.self) { word in wordChip(word, missed: false) }
                    if session.finished {
                        ForEach(round.missed, id: \.self) { word in wordChip(word, missed: true) }
                    }
                }
            }
        }
        .padding(6)
        .background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func wordChip(_ word: String, missed: Bool) -> some View {
        Text(word)
            .font(.system(size: 14, weight: missed ? .semibold : .heavy, design: .rounded))
            .foregroundStyle(missed ? HallwaysOS.inkSoft.opacity(0.7) : (word.count == 6 ? LetterheadPalette.great : HallwaysOS.ink))
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(_ tone: LetterheadSession.Feedback.Tone) -> Color {
        switch tone {
        case .good: return LetterheadPalette.good
        case .great: return LetterheadPalette.great
        case .bad: return LetterheadPalette.bad
        }
    }
}
