"""Hallenese vocal proof of concept -- Sinsy (HMM singing synthesis, nitech_jp_song070_f001, CC BY 3.0).

score -> MusicXML (Japanese kana as Hallenese syllables) -> sinsy -> WAV,
then a WORLD vocoder pass for character and expression:
  soul      the voice at its own register; scoops into long notes, a little extra vibrato, a fall at phrase ends
  crooner   an octave down, the vocal tract lengthened (formants lowered), breathier
  harmony   a second part (a third below), same treatment as the soul voice but plainer
"""
import os, subprocess, sys, json
import numpy as np
import soundfile as sf
import pyworld as pw

SINSY = "/home/claude/src/sinsy/src/build/bin/sinsy"
DIC = "/home/claude/src/sinsy/src/dic"
VOICE = "/home/claude/src/pysinsy/pysinsy/htsvoice/nitech_jp_song070_f001.htsvoice"
OUT = os.path.dirname(os.path.abspath(__file__))

STEP = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def midi(name):
    if not isinstance(name, str):
        return int(name)
    acc = 1 if "#" in name else (-1 if name[1:2] == "b" else 0)
    return 12 * (int(name[-1]) + 1) + STEP[name[0]] + acc


def musicxml(notes, bpm, path, beats=4, divisions=4):
    """notes: [(pitch name or None for rest, beats, kana)]"""
    def pitch_xml(p):
        m = midi(p)
        names = ["C", "C", "D", "E", "E", "F", "F", "G", "A", "A", "B", "B"]
        alters = [0, 1, 0, -1, 0, 0, 1, 0, -1, 0, -1, 0]
        s, a = names[m % 12], alters[m % 12]
        return f"<pitch><step>{s}</step>{f'<alter>{a}</alter>' if a else ''}<octave>{m // 12 - 1}</octave></pitch>"
    # Oct 24 fix: every event is split at the barlines (rests simply; a note that crosses one is tied).
    # A long rest written as one oversized bar made Sinsy misread the timing of everything after it.
    bar_div = beats * divisions
    measures, cur, pos = [], [], 0
    for p, b, k in notes:
        d = int(round(b * divisions))
        first = True
        while d > 0:
            room = bar_div - pos
            seg = min(d, room)
            if p is None:
                cur.append(f"<note><rest/><duration>{seg}</duration></note>")
            else:
                tie = ""
                if seg < d:
                    tie += '<tie type="start"/>'
                if not first:
                    tie = '<tie type="stop"/>' + tie
                ties = tie.replace("<tie", "<tied") if tie else ""
                lyric = f"<lyric><text>{k}</text></lyric>" if first else ""
                cur.append(f"<note>{pitch_xml(p)}<duration>{seg}</duration>{tie}"
                           + (f"<notations>{ties}</notations>" if ties else "") + f"{lyric}</note>")
            d -= seg; pos += seg; first = False
            if pos >= bar_div:
                measures.append(cur); cur, pos = [], 0
    if cur:
        if pos < bar_div:
            cur.append(f"<note><rest/><duration>{bar_div - pos}</duration></note>")
        measures.append(cur)
    body = []
    for i, m in enumerate(measures, 1):
        attr = ""
        if i == 1:
            attr = (f"<attributes><divisions>{divisions}</divisions><key><fifths>0</fifths></key>"
                    f"<time><beats>{beats}</beats><beat-type>4</beat-type></time></attributes>"
                    f"<direction><sound tempo=\"{bpm}\"/></direction>")
        body.append(f"<measure number=\"{i}\">{attr}{''.join(m)}</measure>")
    xml = ('<?xml version="1.0" encoding="UTF-8"?><score-partwise version="3.0"><part-list><score-part id="P1">'
           '<part-name>V</part-name></score-part></part-list><part id="P1">' + "".join(body) + "</part></score-partwise>")
    open(path, "w", encoding="utf-8").write(xml)


def sinsy(xml, wav):
    r = subprocess.run([SINSY, "-x", DIC, "-m", VOICE, "-o", wav, xml], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(wav):
        raise RuntimeError(r.stdout + r.stderr)
    x, sr = sf.read(wav)
    return x.astype(np.float64), sr


def onsets(notes, bpm):
    t, out = 0.0, []
    for p, b, k in notes:
        d = b * 60 / bpm
        if p is not None:
            out.append((t, d, midi(p)))
        t += d
    return out


def dewhistle(sp, sr, frame=5.0, lo=2800.0, hi=6500.0, trigger=-6.0, target=-9.0, width=350.0, report=None):
    """The Sinsy voice's whistle (found Oct 24): now and then its HMM spectral envelope grows one
    ultra-sharp resonance between ~3 and ~4 kHz, and the harmonic that lands in it becomes as loud as
    the voice's whole body -- a pure, piercing tone. It isn't one phoneme or note (pitch- and
    context-dependent), and it's in Sinsy's raw output.
    The fix: per frame, if the envelope's loudest point in lo..hi comes within `trigger` dB of the
    loudest point of the voice's body (below lo) -- or towers above it -- a narrow dip (Gaussian,
    +-width Hz) lowers just that peak to `target` dB below the body; the dip is smoothed over 30 ms. Frames below the trigger are untouched -- the vowels'
    own brightness (the 'i' and 'e' resonances, mostly below 2.8 kHz) is kept."""
    n = sp.shape[1]
    fr = np.linspace(0, sr / 2, n)
    db = 10 * np.log10(sp + 1e-20)
    band = (fr > lo) & (fr < hi)
    idx = np.flatnonzero(band)
    body = (fr > 80) & (fr <= lo)
    rel = db[:, band].max(1) - db[:, body].max(1)                # the peak vs the voice's body below lo
    peak = fr[idx[np.argmax(db[:, band], axis=1)]]
    depth = np.clip(rel - target, 0, None) * (rel > trigger)
    w = max(1, int(30 / frame))
    depth = np.convolve(depth, np.ones(2 * w + 1) / (2 * w + 1), mode="same")
    peak_s = np.copy(peak)
    for i in range(len(peak)):                                    # hold the dip's centre steady while it acts
        if depth[i] > 0 and i > 0 and depth[i - 1] > 0 and abs(peak[i] - peak_s[i - 1]) < 400:
            peak_s[i] = 0.7 * peak_s[i - 1] + 0.3 * peak[i]
    dip = depth[:, None] * np.exp(-0.5 * ((fr[None, :] - peak_s[:, None]) / width) ** 2)
    if report is not None:
        report["frames_touched_pct"] = float(100 * np.mean(depth > 0.5))
        report["max_cut_db"] = float(depth.max())
    return sp * 10 ** (-dip / 10)


def express(x, sr, notes, bpm, shift=0.0, formant=1.0, breath=0.0, scoop=True, vib=0.0, fall=True, frame=5.0, fix_whistle=True):
    """WORLD: f0 shifted (semitones), the spectral envelope warped (formant <1: a longer, lower tract),
    breathier (aperiodicity up), with scoops / extra vibrato / phrase-end falls on the score's notes."""
    f0, t = pw.harvest(x, sr, f0_floor=70, f0_ceil=900, frame_period=frame)
    sp = pw.cheaptrick(x, f0, t, sr)
    if fix_whistle:
        sp = dewhistle(sp, sr, frame)
    ap = pw.d4c(x, f0, t, sr)
    f0 = f0.copy()
    voiced = f0 > 0
    cents = np.zeros_like(f0)
    ns = onsets(notes, bpm)
    # 1. every note to its written pitch (+shift): the singer's own glides and vibrato kept, only the
    #    note's centre moved -- Sinsy sang it transposed into its comfortable range, and flattens its top.
    corr = np.full_like(f0, np.nan)
    for i, (s, d, m) in enumerate(ns):
        k = (t >= s + d * 0.3) & (t < s + d * 0.85) & voiced
        if k.sum() < 3:
            continue
        sung = 1200 * np.log2(np.median(f0[k]) / 440) + 6900
        end = ns[i + 1][0] if i + 1 < len(ns) else s + d + 1.0
        corr[(t >= s - 0.05) & (t < end - 0.05)] = 100 * (m + shift) - sung
    good = ~np.isnan(corr)
    corr = np.interp(np.arange(len(t)), np.flatnonzero(good), corr[good]) if good.any() else np.zeros_like(f0)
    w = max(1, int(0.04 / (frame / 1000)))
    corr = np.convolve(np.pad(corr, w, mode="edge"), np.ones(2 * w + 1) / (2 * w + 1), mode="same")[w:-w]
    cents += corr
    # 2. a quicker arrival: Sinsy approaches its top notes slowly -- after the first 70 ms of each
    #    note, the remaining distance to the note's centre is cut by 85% (the scoop's start kept)
    for i, (s, d, m) in enumerate(ns):
        k = (t >= s + d * 0.3) & (t < s + d * 0.85) & voiced
        if k.sum() < 3:
            continue
        plateau = np.median(1200 * np.log2(f0[k] / 440) + cents[k])
        a = (t >= s + 0.07) & (t < s + min(0.6, d * 0.4)) & voiced
        dev = (1200 * np.log2(np.maximum(f0[a], 1) / 440) + cents[a]) - plateau
        ramp = np.clip((t[a] - s - 0.07) / 0.05, 0, 1)
        cents[a] -= 0.85 * dev * ramp
    # 3. no pitch outside the sung notes (a release read as a pitch would squeak)
    inside = np.zeros_like(f0, dtype=bool)
    for s, d, m in ns:
        inside |= (t >= s - 0.15) & (t < s + d + 0.06)
    f0[~inside] = 0
    voiced = f0 > 0
    for i, (s, d, m) in enumerate(ns):
        idx = (t >= s) & (t < s + d)
        if scoop and d >= 0.45:                          # a scoop: from ~70 cents under, into the note
            k = (t >= s) & (t < s + 0.11)
            cents[k] += -70 * (1 - (t[k] - s) / 0.11) ** 2
        if vib and d >= 0.6:                             # vibrato grows in over the held note
            k = idx & (t >= s + 0.25)
            ph = 2 * np.pi * 5.4 * (t[k] - s)
            depth = vib * np.clip((t[k] - s - 0.25) / 0.4, 0, 1)
            cents[k] += depth * np.sin(ph)
        nxt = ns[i + 1][0] if i + 1 < len(ns) else 1e9
        if fall and d >= 1.2 and nxt - (s + d) > 0.2:     # a phrase-end fall
            k = (t >= s + d - 0.18) & (t < s + d + 0.05)
            cents[k] += -180 * np.clip((t[k] - (s + d - 0.18)) / 0.23, 0, 1) ** 2
    f0[voiced] = f0[voiced] * 2 ** (cents[voiced] / 1200)
    if formant != 1.0:
        n = sp.shape[1]
        src = np.arange(n) / formant                        # read the envelope at f/formant: peaks move to f*formant
        sp = np.array([np.interp(np.minimum(src, n - 1), np.arange(n), row) for row in sp])
    if breath:
        ap = np.clip(ap + breath * (1 - ap) * np.linspace(0.3, 1, ap.shape[1])[None, :], 0, 0.999)
    y = pw.synthesize(f0, sp, ap, sr, frame_period=frame)
    return y[: len(x)] if len(y) >= len(x) else np.pad(y, (0, len(x) - len(y)))


BPM = 80
# "Lunamore" -- the hook. Kana as Hallenese syllables: ru-na-mo-re-ro / so-be-ra-ma-i ...
LEAD = [(None, 1, ""), ("A4", .5, "る"), ("C5", .5, "な"), ("D5", 1, "も"), ("C5", 1, "れ"),
        ("F5", 3, "ろ"), (None, 1, ""),
        (None, 1, ""), ("D5", .5, "そ"), ("C5", .5, "べ"), ("A4", 1, "ら"), ("G4", 1, "ま"),
        ("A4", 3, "い"), (None, 1, ""),
        (None, 1, ""), ("A4", .5, "る"), ("C5", .5, "な"), ("D5", 1, "も"), ("F5", 1, "れ"),
        ("G5", 2, "ろ"), ("F5", 1, "な"), ("D5", 1, "や"),
        ("C5", 1, "そ"), ("A4", 1, "べ"), ("G4", 1, "ら"), ("A4", .5, "ま"), ("G4", .5, "ぬ"),
        ("F4", 4, "え")]
# the harmony: a third (or sixth) below in F major, same syllables
HARM = [(None, 1, ""), ("F4", .5, "る"), ("A4", .5, "な"), ("Bb4", 1, "も"), ("A4", 1, "れ"),
        ("D5", 3, "ろ"), (None, 1, ""),
        (None, 1, ""), ("Bb4", .5, "そ"), ("A4", .5, "べ"), ("F4", 1, "ら"), ("D4", 1, "ま"),
        ("E4", 3, "い"), (None, 1, ""),
        (None, 1, ""), ("F4", .5, "る"), ("A4", .5, "な"), ("Bb4", 1, "も"), ("D5", 1, "れ"),
        ("Bb4", 2, "ろ"), ("A4", 1, "な"), ("F4", 1, "や"),
        ("E4", 1, "そ"), ("E4", 1, "べ"), ("Bb3", 1, "ら"), ("C4", .5, "ま"), ("Bb3", .5, "ぬ"),
        ("C4", 4, "え")]

if __name__ == "__main__":
    os.makedirs(f"{OUT}/raw", exist_ok=True)
    out = {}
    for name, notes in [("lead", LEAD), ("harm", HARM)]:
        ps = [midi(p) for p, _, _ in notes if p is not None]
        off = int(round(69 - (min(ps) + max(ps)) / 2))           # sung centred on A4 (the voice's middle)
        print(name, "rendered transposed", off)
        musicxml([(None if p is None else midi(p) + off, b, k) for p, b, k in notes], BPM, f"{OUT}/raw/{name}.xml")
        x, sr = sinsy(f"{OUT}/raw/{name}.xml", f"{OUT}/raw/{name}.wav")
        out[name] = (x, sr)
        print(name, sr, len(x) / sr)
    x, sr = out["lead"]
    sf.write(f"{OUT}/raw/soul.wav", express(x, sr, LEAD, BPM, shift=0, vib=28, breath=0.08), sr)
    sf.write(f"{OUT}/raw/crooner.wav", express(x, sr, LEAD, BPM, shift=-12, formant=0.80, breath=0.22, vib=22), sr)
    h, sr = out["harm"]
    sf.write(f"{OUT}/raw/harmony.wav", express(h, sr, HARM, BPM, shift=0, vib=18, breath=0.1, fall=False), sr)
    sf.write(f"{OUT}/raw/harmony-low.wav", express(h, sr, HARM, BPM, shift=-12, formant=0.80, breath=0.2, vib=16, fall=False), sr)
    json.dump({"bpm": BPM, "sr": sr}, open(f"{OUT}/raw/info.json", "w"))
