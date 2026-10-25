"""Before/after for the whistle: per-note 'high-band peak vs the note's loudest' on the actual output audio."""
import sys, numpy as np, soundfile as sf, pyworld as pw, json
sys.path.insert(0, '/home/claude/lab/voice'); import sing as S
kana = {"る":"ru","な":"na","も":"mo","れ":"re","ろ":"ro","そ":"so","べ":"be","ら":"ra","ま":"ma","い":"i","や":"ya","ぬ":"nu","え":"e"}
def per_note(y, sr, notes):
    t = 0; out = []
    for p, b, k in notes:
        d = b * 60 / S.BPM
        if p is not None:
            seg = y[int((t + min(.12, d * .3)) * sr):int((t + d * .85) * sr)]
            F = 20 * np.log10(np.abs(np.fft.rfft(seg * np.hanning(len(seg)), 4 * len(seg))) + 1e-9); fr = np.fft.rfftfreq(4 * len(seg), 1 / sr)
            out.append((kana[k], round(t, 1), round(float(F[(fr > 2800) & (fr < 6500)].max() - F.max()), 1)))
        t += d
    return out
def raw_world(x, sr, fix):
    f0, t = pw.harvest(x, sr, f0_floor=70, f0_ceil=900, frame_period=5)
    sp = pw.cheaptrick(x, f0, t, sr); rep = {}
    if fix: sp = S.dewhistle(sp, sr, 5.0, report=rep)
    ap = pw.d4c(x, f0, t, sr)
    y = pw.synthesize(f0, sp, ap, sr, frame_period=5)[:len(x)]
    return y, rep
res = {}
import os; os.makedirs('fixed', exist_ok=True)
lead, sr = sf.read('raw/lead.wav'); harm, _ = sf.read('raw/harm.wav')
for name, x, notes, kw in [("soul", lead, S.LEAD, dict(shift=0, vib=28, breath=0.08)),
                           ("crooner", lead, S.LEAD, dict(shift=-12, formant=0.80, breath=0.22, vib=22)),
                           ("harmony", harm, S.HARM, dict(shift=0, vib=18, breath=0.1, fall=False)),
                           ("harmony-low", harm, S.HARM, dict(shift=-12, formant=0.80, breath=0.2, vib=16, fall=False))]:
    before = S.express(x, sr, notes, S.BPM, fix_whistle=False, **kw)
    after = S.express(x, sr, notes, S.BPM, fix_whistle=True, **kw)
    sf.write(f'fixed/{name}.wav', after, sr)
    b, a = per_note(before, sr, notes), per_note(after, sr, notes)
    worst_b = sorted(b, key=lambda z: -z[2])[:4]; worst_a = sorted(a, key=lambda z: -z[2])[:4]
    print(f"{name:12s} worst BEFORE {worst_b}\n{'':12s} worst AFTER  {worst_a}")
    print(f"{'':12s} notes changed by >1 dB: {sum(abs(p[2]-q[2])>1 for p,q in zip(b,a))} of {len(a)}")
for name, x, notes in [("lead-raw", lead, S.LEAD), ("harm-raw", harm, S.HARM)]:
    y0, _ = raw_world(x, sr, False); y1, rep = raw_world(x, sr, True)
    sf.write(f'fixed/{name}-world-nofix.wav', y0, sr); sf.write(f'fixed/{name}-world-fixed.wav', y1, sr)
    print(name, 'frames touched %.1f%%, deepest cut %.1f dB' % (rep['frames_touched_pct'], rep['max_cut_db']),
          ' worst before', sorted(per_note(x, sr, notes), key=lambda z: -z[2])[:3], ' after', sorted(per_note(y1, sr, notes), key=lambda z: -z[2])[:3])
