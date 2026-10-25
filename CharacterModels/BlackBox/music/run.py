import sys, time
from compose import compose, name, tick_time
from synth import render, write_wav

def show(p):
    print(f"seed {p.seed} style {p.style} bpm {p.bpm} tonic {name(p.tonic)} lead {p.lead} prog {p.prog}")
    for bar in sorted(p.melody):
        print(f"  bar {bar}: " + " ".join(f"{name(n.midi)}@{n.tick % p.ticks_per_bar}/{n.dur}" for n in p.notes
                                          if n.kind == 'lead' and n.tick // p.ticks_per_bar == bar))
    print("  bass:", " ".join(name(n.midi) for n in p.notes if n.kind == 'bass')[:200])

if __name__ == '__main__':
    prev = None
    for s in [int(a) for a in sys.argv[1:]]:
        p = compose(s, previous_style=prev)
        prev = p.style
        show(p)
        t = time.time()
        x = render(p)
        write_wav(f"out/bb-{s}-{p.style}.wav", x)
        print(f"  {len(x)/44100:.1f}s rendered in {time.time()-t:.1f}s")
