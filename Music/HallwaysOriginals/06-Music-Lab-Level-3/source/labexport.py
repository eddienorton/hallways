"""A genre piece -> Music Lab assets: python3 labexport.py <module> [--aac-loop]

  loop          every part rendered once with an 8 s tail, room added, and everything sounding past the loop's
                end folded back onto its start -- exactly what a repeating loop sounds like: seamless by construction.
  performance   the finished arrangement, every part, same balance.
  balance       each part to its LEVELS (active loudness) -> pan -> room; then ONE scale for every stem of
                the piece (the full loop at ~-19 dB RMS, nothing over -1 dBFS in loop or performance).
  files         loop: ALAC .caf (lossless) -- or, with --aac-loop (the compression experiment), AAC .m4a with
                PAD frames of the loop's own end before it and its start after it, and "loopStartFrame": PAD
                in the manifest; performance: AAC 160k .m4a. Plus lab-<key>.json, listening files, npy stems.
"""
import sys, os, json, importlib, subprocess, wave
import numpy as np
sys.path.insert(0, "/home/claude/lab"); sys.path.insert(0, "/home/claude/lab/genres")
import studio as S
from labkit import SR

PAD = 4096


def wav16(path, x):
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(np.clip(x * 32767, -32768, 32767).astype(np.int16).tobytes())


def voice_sync(p, x, tempo, beat0=0.0, label=""):
    """Singers: (1) each written note's pitch, read from the audio at the note's own time; (2) the offset
    (ms) that best aligns the audio's voicing with the score's notes. Wrong timing shows in both."""
    import pyworld as pw
    sec = S.beats_to_sec(tempo)
    m = x.mean(1).astype(np.float64)
    f0, t = pw.harvest(m, SR, f0_floor=70, f0_ceil=900, frame_period=10)
    ok = bad = 0
    gate = np.zeros_like(t)
    for b, d, note, k in p.score:
        if b < beat0 - 1e-6:
            continue
        s0, s1 = sec(b) - sec(beat0), sec(b + d) - sec(beat0)
        gate[(t >= s0) & (t < s1)] = 1
        w = (t >= s0 + (s1 - s0) * .35) & (t < s0 + (s1 - s0) * .8) & (f0 > 0)
        if w.sum() >= 2:
            want = 440 * 2 ** ((note + p.engine[1].get("shift", 0) - 69) / 12)
            ok += abs(1200 * np.log2(np.median(f0[w]) / want)) < 50
            bad += abs(1200 * np.log2(np.median(f0[w]) / want)) >= 50
    v = (f0 > 0).astype(float)
    lags = range(-30, 31)
    best = max(lags, key=lambda L: np.dot(np.roll(v, L), gate))
    print(f"SYNC {label} {p.who}: notes on pitch at their score times {ok}/{ok + bad};  best voicing alignment offset {best * 10:+d} ms")
    return ok, bad, best * 10


LAID_BACK_MS = 40


def align_voice(x, offset_ms):
    """Every singer to the same feel: voicing LAID_BACK_MS behind the written note (Sinsy puts the consonant
    on the beat, the vowel after it; left alone the two singers sat 50 and 90-110 ms behind -- loose together)."""
    shift = int(round((-offset_ms - LAID_BACK_MS) / 1000 * SR))
    if shift <= 0:
        return x
    return np.concatenate([x[shift:], np.zeros((shift, x.shape[1]))])


def main():
    mod = importlib.import_module(sys.argv[1])
    aac_loop = "--aac-loop" in sys.argv
    lab = mod.LAB
    key = lab["id"].replace("-", "")
    out = f"/home/claude/lab/labassets/{lab['id']}"
    os.makedirs(f"{out}/bundle", exist_ok=True)
    os.makedirs(f"{out}/listen", exist_ok=True)
    irs = S.room_ir(rt=getattr(mod, "RT", 1.6))
    # ---- loop
    LP, lt, lb = mod.build_loop()
    Lf = int(round(S.beats_to_sec(lt)(lb) * SR))
    T2 = 2 * Lf + int(1.0 * SR)
    loop, gain = {}, {}
    TAIL = int(8.0 * SR)
    for w in mod.WHO:
        # Oct 24: ONE pass with a long tail, the tail folded back onto the loop's start (= what you hear when it
        # repeats). Seamless by construction -- unlike two rendered passes, which can differ where an instrument
        # picks its samples at random (the cellos' release crossing the loop point did).
        x = S.render_part(LP[w], lt, lb, Lf + TAIL).astype(np.float64)
        if LP[w].engine[0] == "voice":
            voice_sync(LP[w], x[:Lf], lt, label="loop")
        folded = x[:Lf].copy(); folded[:TAIL] += x[Lf:Lf + TAIL]
        act = S.active_rms(folded)
        gain[w] = 10 ** ((mod.LEVELS[w] - act) / 20) if act > -100 else 1.0
        y = S.add_room(S.place(x * gain[w], mod.PAN.get(w, 0)), irs, mod.ROOM.get(w, .2))
        lp = y[:Lf].copy(); lp[:TAIL] += y[Lf:Lf + TAIL]
        loop[w] = lp
        print("loop", w, round(act, 1), flush=True)
    # ---- performance
    PP, pt, pb = mod.build_performance()
    Tp = int((S.beats_to_sec(pt)(pb) + 3.0) * SR)
    perf = {}
    for w in mod.WHO:
        x = S.render_part(PP[w], pt, pb, Tp).astype(np.float64)
        if PP[w].engine[0] == "voice":
            _, _, off = voice_sync(PP[w], x, pt, label="performance")

        perf[w] = S.add_room(S.place(x * gain[w], mod.PAN.get(w, 0)), irs, mod.ROOM.get(w, .2))
        print("perf", w, flush=True)
    # ---- one scale
    aL, aP = sum(loop.values()), sum(perf.values())
    s = 10 ** ((-19 - S.rms(aL)) / 20)
    s = min(s, 10 ** (-1 / 20) / np.abs(aL).max(), 10 ** (-1 / 20) / np.abs(aP).max())
    print("scale dB", round(20 * np.log10(s), 2), "loop rms", round(S.rms(aL * s), 1), "perf rms", round(S.rms(aP * s), 1),
          "loop peak", round(20 * np.log10(np.abs(aL * s).max()), 2), "perf peak", round(20 * np.log10(np.abs(aP * s).max()), 2))
    parts = []
    for w in mod.WHO:
        lname = f"lab-{key}-loop-{w}" + (".m4a" if aac_loop else ".caf")
        pname = f"lab-{key}-perf-{w}.m4a"
        x = loop[w] * s
        if aac_loop:
            wav16("/tmp/_l.wav", np.concatenate([x[-PAD:], x, x[:PAD]]))
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", "/tmp/_l.wav", "-c:a", "aac", "-b:a", "160k", f"{out}/bundle/{lname}"], check=True)
        else:
            wav16("/tmp/_l.wav", x)
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", "/tmp/_l.wav", "-c:a", "alac", f"{out}/bundle/{lname}"], check=True)
        wav16("/tmp/_p.wav", perf[w] * s)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", "/tmp/_p.wav", "-c:a", "aac", "-b:a", "160k", f"{out}/bundle/{pname}"], check=True)
        mus, ins, col = lab["parts"][w]
        parts.append({"id": w, "musician": mus, "instrument": ins, "color": col, "loop": lname, "performance": pname})
    manifest = {k: lab[k] for k in ("id", "title", "subtitle", "genre", "order", "bpm", "beatsPerBar")}
    manifest.update({"loopFrames": Lf, "sampleRate": SR, "parts": parts})
    if aac_loop:
        manifest["loopStartFrame"] = PAD
    json.dump(manifest, open(f"{out}/bundle/lab-{key}.json", "w"), indent=1, ensure_ascii=False)
    np.save(f"{out}/loop.npy", np.stack([loop[w] * s for w in mod.WHO]).astype(np.float32))
    np.save(f"{out}/perf.npy", np.stack([perf[w] * s for w in mod.WHO]).astype(np.float32))
    json.dump({"who": mod.WHO, "Lf": Lf, "perfFrames": Tp, "scale": s, "gain": gain}, open(f"{out}/info.json", "w"))
    # ---- listening files
    full = aL * s
    S.write_m4a(f"{out}/listen/00-loop, everyone (twice through - hear the loop point).m4a", S.finish(np.concatenate([full, full]), -18, fout=2))
    S.write_m4a(f"{out}/listen/00-finished performance.m4a", S.finish(aP * s, -17.5))
    for i, (ws, label) in enumerate(getattr(mod, "LAB_COMBOS", []), 1):
        S.write_m4a(f"{out}/listen/{i:02d}-loop - {label}.m4a", S.finish(sum(loop[w] for w in ws) * s, -18.5, fout=2))
    # ---- seam check (each stem: the step across the loop point vs its ordinary sample-to-sample steps)
    for w in mod.WHO:
        x = loop[w] * s
        print("seam", w, round(float(np.abs(x[0] - x[-1]).max()), 4), "typical", round(float(np.percentile(np.abs(np.diff(x[:, 0])), 99.9)), 4))
    print("done", out, "loop", round(Lf / SR, 2), "s  perf", round(Tp / SR, 1), "s")


if __name__ == "__main__":
    main()
