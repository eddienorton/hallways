"""A minimal SoundFont 2 writer (one preset, one instrument, mono 16-bit samples).

zones: list of dict(sample=np.int16 array, root=int, lo=int, hi=int, vlo=0, vhi=127, rate=44100,
                    loop=(start, end) or None, attack=s, hold=s, decay=s, sustain_db=0, release=s,
                    atten_db=0, tune_cents=0)
Generators written per zone, in the order the spec requires (keyRange, velRange first; sampleID last).
"""
import struct
import numpy as np


def _tc(seconds):
    return int(round(1200 * np.log2(max(seconds, 0.001))))


def _chunk(cid, data):
    if len(data) % 2:
        data += b"\0"
    return cid + struct.pack("<I", len(data)) + data


def _list(lid, payload):
    return _chunk(b"LIST", lid + payload)


def _name(s, n=20):
    b = s.encode("ascii", "replace")[: n - 1]
    return b + b"\0" * (n - len(b))


def write_sf2(path, preset_name, zones, program=0, bank=0):
    # ---- sample data: each sample followed by 46 zero points
    smpl = bytearray()
    shdr = bytearray()
    starts = []
    for i, z in enumerate(zones):
        s = np.asarray(z["sample"], dtype=np.int16)
        start = len(smpl) // 2
        smpl += s.tobytes() + b"\0\0" * 46
        end = start + len(s)
        if z.get("loop"):
            ls, le = z["loop"]
            ls, le = start + int(ls), start + int(le)
        else:
            ls, le = start + max(0, len(s) - 40), start + len(s) - 8
        starts.append(start)
        shdr += struct.pack("<20sIIIIIBbHH", _name(f"{preset_name[:12]}{i}"), start, end, ls, le,
                            int(z.get("rate", 44100)), int(z["root"]), 0, 0, 1)
    shdr += struct.pack("<20sIIIIIBbHH", _name("EOS"), 0, 0, 0, 0, 0, 0, 0, 0, 0)

    # ---- instrument zones
    igen = bytearray()
    ibag = bytearray()
    gi = 0
    for i, z in enumerate(zones):
        ibag += struct.pack("<HH", gi, 0)
        gens = [(43, struct.pack("<BB", z["lo"], z["hi"])),
                (44, struct.pack("<BB", z.get("vlo", 0), z.get("vhi", 127)))]
        def g(op, val):
            gens.append((op, struct.pack("<h", int(val))))
        g(34, _tc(z.get("attack", 0.002)))
        if z.get("hold"):
            g(35, _tc(z["hold"]))
        if z.get("decay"):
            g(36, _tc(z["decay"]))
        g(37, int(round(z.get("sustain_db", 0) * 10)))
        g(38, _tc(z.get("release", 0.2)))
        if z.get("atten_db"):
            g(48, int(round(z["atten_db"] * 10)))
        if z.get("tune_cents"):
            g(52, int(round(z["tune_cents"])))
        g(54, 1 if z.get("loop") else 0)
        g(58, int(z["root"]))
        g(53, i)                                   # sampleID last
        for op, amt in gens:
            igen += struct.pack("<H", op) + amt
        gi += len(gens)
    ibag += struct.pack("<HH", gi, 0)
    igen += struct.pack("<HH", 0, 0)
    imod = b"\0" * 10
    inst = struct.pack("<20sH", _name(preset_name), 0) + struct.pack("<20sH", _name("EOI"), len(zones))

    # ---- preset: one zone pointing at instrument 0
    pgen = struct.pack("<Hh", 41, 0) + struct.pack("<HH", 0, 0)
    pbag = struct.pack("<HH", 0, 0) + struct.pack("<HH", 1, 0)
    pmod = b"\0" * 10
    phdr = struct.pack("<20sHHHIII", _name(preset_name), program, bank, 0, 0, 0, 0) + \
        struct.pack("<20sHHHIII", _name("EOP"), 0, 0, 1, 0, 0, 0)

    info = _chunk(b"ifil", struct.pack("<HH", 2, 1)) + _chunk(b"isng", b"EMU8000\0") + \
        _chunk(b"INAM", _name(preset_name, 32)) + _chunk(b"ICOP", b"Hallways Music Lab; see BAND-CREDITS\0")
    sdta = _chunk(b"smpl", bytes(smpl))
    pdta = (_chunk(b"phdr", phdr) + _chunk(b"pbag", pbag) + _chunk(b"pmod", pmod) + _chunk(b"pgen", pgen) +
            _chunk(b"inst", inst) + _chunk(b"ibag", bytes(ibag)) + _chunk(b"imod", imod) + _chunk(b"igen", bytes(igen)) +
            _chunk(b"shdr", bytes(shdr)))
    body = b"sfbk" + _list(b"INFO", info) + _list(b"sdta", sdta) + _list(b"pdta", pdta)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", len(body)) + body)
