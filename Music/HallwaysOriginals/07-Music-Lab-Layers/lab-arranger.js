// HALLWAYS MUSIC LAB -- the performer. Oct 24 2026 (ordered musical layers).
//
// A composition (hallways-composition/1 JSON) owns three things, kept apart:
//   its PARTS     the music: notes [beat, beats, midi, velocity, articulation?] or, for a groove,
//                 rhythmic hits [beat, piece, velocity]. No instruments, no residents.
//   its TIMELINE  when each part sounds: simply its notes' own beats, on one shared clock. The composition
//                 loops (bar n plays its bar n mod length).
//   its LAYERS    an ordered stack of parts (Night Porter: bass line, groove, chords, held chords, melody,
//                 answers, harmony, low harmony): the order the player's musicians are given them.
// Which musician has which layer is decided OUTSIDE this file, by the order the player switches them on
// (MusicLab.swift: the next one takes the lowest vacant layer and keeps it). No layer prefers an
// instrument; nothing here moves anybody to another layer.
//
// What this file does decide is HOW an instrument performs the layer it was handed, without changing it:
//   octave     the part moved by whole octaves into the instrument's range (one shift for the whole part,
//              so its shape is kept); a stray note far out of reach moves by itself
//   chords     an instrument sounds at most its polyphony of each chord: the top notes (one, for a horn)
//   sustain    bowed / blown / sung: legato through a phrase, swells on long notes; struck and plucked
//              ring as written; the marimba rolls a long note
//   percussion a drum or the congas on a pitched layer play that layer's RHYTHM (its onsets and accents --
//              low, middle or high drum by where each note sits in the part); a pitched instrument on the
//              groove plays the groove's kick and snare on the current chord's root and fifth. Both are
//              shown as such ("rhythm only", "on chord roots"); neither invents a line.
//   voices     a singer sings a layer only if that layer has been prerendered in Hallenese for its voice
//              (band-voices.json); otherwise it holds the layer silently and says so.
//
// The same JavaScript runs on the iPhone (JavaScriptCore, no network) and in Node (offline tests).
//   Lab.configure({ instruments, voices })        once
//   Lab.load(template) -> info (incl. layers)      choose the composition
//   Lab.setLineup([{who, instrument, layer}])      layer: index into the stack, or null (waiting: all taken)
//   Lab.planBar(n) -> { bar, loopBar, section, chord, roles: {who: label}, levels: {who: dB}, events }
//       note { who, type: "note", t, dur, pitch, vel } / cc { ..., cc, value } / sing { who, type: "sing", part, loopBar }

var Lab = (function () {
  "use strict";

  // fam: how it sounds a note; poly: notes at once; sustain: holds a note at full voice
  var KIND = {
    drums: { fam: "kit" }, percussion: { fam: "perc" },
    upright_bass: { fam: "pluck", poly: 1, bass: true }, electric_bass: { fam: "pluck", poly: 1, bass: true },
    tuba: { fam: "brass", poly: 1, sustain: true, bass: true },
    piano: { fam: "keys", poly: 4 }, electric_piano: { fam: "keys", poly: 4 }, organ: { fam: "organ", poly: 4, sustain: true },
    nylon_guitar: { fam: "pluck", poly: 3 }, electric_guitar: { fam: "pluck", poly: 3 },
    marimba: { fam: "mallet", poly: 2, roll: true }, vibraphone: { fam: "mallet", poly: 3 }, glockenspiel: { fam: "mallet", poly: 2 },
    harp: { fam: "pluck", poly: 3 },
    violin: { fam: "string", poly: 2, sustain: true }, cello: { fam: "string", poly: 2, sustain: true },
    flute: { fam: "wind", poly: 1, sustain: true }, clarinet: { fam: "wind", poly: 1, sustain: true },
    harmonica: { fam: "wind", poly: 2, sustain: true }, tenor_sax: { fam: "wind", poly: 1, sustain: true },
    french_horn: { fam: "brass", poly: 1, sustain: true }, trumpet: { fam: "brass", poly: 1, sustain: true },
    trombone: { fam: "brass", poly: 1, sustain: true },
    soprano: { fam: "voice", voice: "soprano" }, alto: { fam: "voice", voice: "alto" },
    tenor: { fam: "voice", voice: "tenor" }, bass_voice: { fam: "voice", voice: "bass" }
  };
  var VOICE_RANGE = { soprano: [60, 81], alto: [55, 76], tenor: [48, 69], bass: [40, 62] };

  var VOICE_RANGE = { soprano: [60, 81], alto: [55, 76], tenor: [48, 69], bass: [40, 62] };
  // levels by the part's role, dB under the melody
  var ROLE_DB = { melody: 0, answer: -3, harmony: -5, bass: -3, comp: -7, pad: -9, rhythm: -5 };
  // the groove's pieces on a GM drum kit, and on the congas & percussion (percussion.sf2's keys)
  var KIT = { kick: 36, snare: 38, ghost: 38, hat: 42, openhat: 46, crash: 49, tomhi: 50, tomlo: 45 };
  var PERC = { kick: 64, snare: 62, ghost: 60, hat: 70, openhat: 66, crash: 56, tomhi: 63, tomlo: 64 };
  var KIT_RHYTHM = [36, 45, 50], PERC_RHYTHM = [64, 63, 62];       // low / middle / high drum for a pitched layer's rhythm
  var PC = { C: 0, Db: 1, "C#": 1, D: 2, Eb: 3, "D#": 3, E: 4, F: 5, Gb: 6, "F#": 6, G: 7, Ab: 8, "G#": 8, A: 9, Bb: 10, "A#": 10, B: 11 };

  var cfg = { instruments: {}, voices: {} };
  var T = null;
  var parts = {};              // id -> {id, name, role, poly, notesByBar, lo, hi, all}
  var groove = null;           // the rhythm part {id, name, hitsByBar}
  var layers = [];             // [{part, name}]
  var lineup = [];             // [{who, instrument, layer}]
  var plan = {};               // who -> {layer, part, how, shift, label}

  function inst(id) {
    var k = KIND[id] || { fam: "keys", poly: 3 };
    var r = cfg.instruments[id] || {};
    var range = k.voice ? VOICE_RANGE[k.voice] : [r.low || 36, r.high || 96];
    // play inside the comfortable middle of the sampled range (a few notes in from each end)
    var lo = range[0] + (k.voice ? 0 : 1), hi = range[1] - (k.voice ? 0 : 1);
    return { id: id, fam: k.fam, poly: k.poly || 1, sustain: !!k.sustain, roll: !!k.roll, bass: !!k.bass, voice: k.voice,
             lo: lo, hi: hi };
  }

  function hash(s) { var h = 2166136261; for (var i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; }
  function jitter(who, n, ms) {        // a steady, personal timing wobble (beats), the same every performance
    var h = hash(who + ":" + n);
    return ((h % 1000) / 1000 - 0.5) * 2 * ms / 1000 * T.bpm / 60;
  }

  function hash(s) { var h = 2166136261; for (var i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; }
  function jitter(who, n, ms) {        // a steady, personal timing wobble (beats), the same every performance
    var h = hash(who + ":" + n);
    return ((h % 1000) / 1000 - 0.5) * 2 * ms / 1000 * T.bpm / 60;
  }

  // ------------------------------------------------------------------ the composition
  function load(t) {
    T = t;
    var bpb = t.meter[0];
    parts = {}; groove = null;
    t.parts.forEach(function (p) {
      if (p.kind === "percussion") {
        var hb = [];
        for (var b = 0; b < t.bars; b++) hb.push([]);
        p.hits.forEach(function (h) { var b = Math.floor(h[0] / bpb + 1e-9); hb[b].push({ t: h[0] - b * bpb, piece: h[1], vel: h[2] }); });
        groove = { id: p.id, name: p.name, hitsByBar: hb };
        return;
      }
      var nb = [], ps = [];
      for (var b = 0; b < t.bars; b++) nb.push([]);
      p.notes.forEach(function (n) {
        var b = Math.floor(n[0] / bpb + 1e-9);
        nb[b].push({ t: n[0] - b * bpb, d: n[1], p: n[2], v: n[3], art: n[4] || "" });
        ps.push(n[2]);
      });
      nb.forEach(function (bar) { bar.sort(function (a, b) { return a.t - b.t || b.p - a.p; }); });
      ps.sort(function (a, b) { return a - b; });
      parts[p.id] = { id: p.id, name: p.name, role: p.role, poly: p.polyphony || 1, notesByBar: nb, lo: ps[0], hi: ps[ps.length - 1], all: ps };
    });
    layers = (t.layers || []).slice();
    plan = {};
    if (lineup.length) prepare();
    return info();
  }

  function info() {
    return { id: T.id, title: T.title, genre: T.genre, bpm: T.bpm, beatsPerBar: T.meter[0], bars: T.bars, layers: layers };
  }

  // The octave shift that best fits a part into an instrument's range (fewest notes out of reach; then the smallest move).
  function fit(part, ins) {
    var best = null;
    [0, -12, 12, -24, 24, -36, 36].forEach(function (k) {
      var out = 0, soft = 0;
      part.all.forEach(function (p) {
        var q = p + k;
        if (q < ins.lo - 3 || q > ins.hi + 3) out++;
        else if (q < ins.lo || q > ins.hi) soft++;
      });
      var cost = (out + soft * 0.3) / part.all.length * 6 + Math.abs(k) / 12 * 0.6;
      if (!best || cost < best.cost - 1e-9) best = { shift: k, cost: cost, out: out / part.all.length };
    });
    return best;
  }

  function octaves(k) { return k === 0 ? "" : " · " + (k > 0 ? "+" : "\u2212") + Math.abs(k / 12) + (Math.abs(k) === 12 ? " octave" : " octaves"); }

  // ------------------------------------------------------------------ how each musician performs its layer
  function prepare() {
    plan = {};
    lineup.forEach(function (m) {
      var ins = inst(m.instrument);
      if (m.layer === null || m.layer === undefined || !layers[m.layer]) {
        plan[m.who] = { how: "none", label: "waiting \u2014 all " + layers.length + " layers taken" };
        return;
      }
      var L = layers[m.layer], tag = "Layer " + (m.layer + 1) + " \u00b7 " + L.name;
      var drum = ins.fam === "kit" || ins.fam === "perc";
      if (groove && L.part === groove.id) {
        if (drum) plan[m.who] = { layer: m.layer, how: "groove", kit: ins.fam === "kit" ? KIT : PERC, perc: ins.fam === "perc", label: tag };
        else if (ins.voice) plan[m.who] = { layer: m.layer, how: "none", label: tag + " \u00b7 can\u2019t be sung yet" };
        else plan[m.who] = { layer: m.layer, how: "roots", label: tag + " \u00b7 on chord roots" };
        return;
      }
      var part = parts[L.part];
      if (!part) { plan[m.who] = { layer: m.layer, how: "none", label: tag + " \u00b7 (missing)" }; return; }
      if (drum) { plan[m.who] = { layer: m.layer, part: part, how: "rhythm", drums: ins.fam === "kit" ? KIT_RHYTHM : PERC_RHYTHM, label: tag + " \u00b7 rhythm only" }; return; }
      if (ins.voice) {
        var v = cfg.voices[T.id] && cfg.voices[T.id][ins.voice] && cfg.voices[T.id][ins.voice][part.id];
        if (v) plan[m.who] = { layer: m.layer, part: part, how: "sing", shift: v.shift, label: tag + octaves(v.shift) + " \u00b7 sung (prerendered)" };
        else plan[m.who] = { layer: m.layer, how: "none", label: tag + " \u00b7 can\u2019t be sung yet" };
        return;
      }
      var f = fit(part, ins);
      var thin = part.poly > 1 && ins.poly < part.poly ? (ins.poly === 1 ? " \u00b7 top note" : " \u00b7 top " + ins.poly + " notes") : "";
      plan[m.who] = { layer: m.layer, part: part, how: "play", shift: f.shift, label: tag + octaves(f.shift) + thin };
    });
  }

  function setLineup(l) {
    lineup = l.map(function (m) { return { who: m.who, instrument: m.instrument, layer: (m.layer === undefined ? null : m.layer) }; });
    if (T) prepare();
    return lineup.map(function (m) { var p = plan[m.who] || {}; return { who: m.who, layer: m.layer, label: p.label, how: p.how, shift: p.shift || 0 }; });
  }

  function chordsIn(bar, notes) {
    // group notes that start together (within 1/40 beat) -- a chord
    var groups = [];
    notes.forEach(function (n) {
      var g = groups.length ? groups[groups.length - 1] : null;
      if (g && Math.abs(g[0].t - n.t) < 0.025) g.push(n); else groups.push([n]);
    });
    return groups;
  }

  function perform(m, a, part, loopBar, n) {
    var ins = m.ins;
    var ev = [];
    var bpb = T.meter[0];
    var notes = part.notesByBar[loopBar];
    if (!notes.length) return ev;
    var groups = chordsIn(loopBar, notes);
    var poly = Math.min(ins.poly, part.poly);
    var lay = ins.fam === "voice" ? 0 : (part.role === "melody" ? 8 : part.role === "bass" ? -3 : 2);   // ms: a lead sits back a hair
    var velScale = 1;
    // the part's following onset (for legato), looking into the next bar
    var nextBar = part.notesByBar[(loopBar + 1) % T.bars];
    var nextOnset = function (gi) {
      if (gi + 1 < groups.length) return groups[gi + 1][0].t;
      return nextBar.length ? bpb + nextBar[0].t : Infinity;
    };
    groups.forEach(function (g, gi) {
      // a chord: the top `poly` notes (a melody instrument takes the top one -- the line)
      var chosen = g.slice(0, poly);
      chosen.forEach(function (x, ci) {
        var p = x.p + (a.shift || 0);
        // a note a little out of reach is played anyway (the sampler stretches its nearest sample);
        // further out, that one note moves an octave
        while (p < ins.lo - 3) p += 12;
        while (p > ins.hi + 3) p -= 12;
        var t = Math.max(0, x.t + jitter(m.who, n * 64 + gi * 4 + ci, 6) + lay / 1000 * T.bpm / 60);
        var d = x.d, gap = nextOnset(gi) - x.t;
        var v = Math.round(Math.max(1, Math.min(127, x.v * velScale)));
        if (ins.sustain) {
          if (x.art === "legato" || part.role === "melody") {
            d = gap <= d + 0.3 ? Math.max(0.08, gap - 0.03) : d;       // join the notes of a phrase
          } else if (x.art === "staccato") {
            d = Math.max(0.08, Math.min(d, 0.22));
          }
          ev.push({ who: m.who, type: "note", t: t, dur: d, pitch: p, vel: v });
          if (d >= 1.2 && ci === 0) {                                 // a long note swells, then eases
            ev.push({ who: m.who, type: "cc", t: t, cc: 11, value: 96 });
            ev.push({ who: m.who, type: "cc", t: t + d * 0.55, cc: 11, value: 124 });
            ev.push({ who: m.who, type: "cc", t: t + d * 0.92, cc: 11, value: 108 });
          }
        } else if (ins.roll && d >= 0.9) {                           // marimba: a long note is a roll
          for (var r = 0; r < d - 0.1; r += 1 / 6) ev.push({ who: m.who, type: "note", t: t + r, dur: 0.16, pitch: p, vel: Math.max(1, v - 10 + (hash(m.who + r) % 7)) });
        } else {                                                     // struck / plucked: rings as written
          var ring = part.role === "bass" ? Math.min(d, 1.5) : Math.min(d * 1.05, 2.5);
          if (ins.fam === "pluck" && ci > 0) t += 0.012 * ci;          // a strum
          ev.push({ who: m.who, type: "note", t: t, dur: Math.max(0.06, ring), pitch: p, vel: v });
        }
      });
    });
    // ensure every pitch's note-offs come before the same pitch's next note-on (no hung or cut notes)
    ev.sort(function (x, y) { return x.t - y.t; });
    var lastEnd = {};
    ev.forEach(function (e) {
      if (e.type !== "note") return;
      var k = e.pitch, prev = lastEnd[k];
      if (prev && prev.t + prev.dur > e.t - 0.01) prev.dur = Math.max(0.04, e.t - prev.t - 0.02);
      lastEnd[k] = e;
    });
    return ev;
  }

  function performGroove(m, a, loopBar, n) {
    var ev = [];
    if (!groove) return ev;
    groove.hitsByBar[loopBar].forEach(function (h, i) {
      var key = a.kit[h.piece];
      if (key === undefined) return;
      var v = h.vel;
      if (a.perc) {
        if (h.piece === "hat") key = (i % 2) ? 71 : 70;                // shaker: alternating strokes
        if (h.piece === "crash") v = Math.round(v * 0.7);
      }
      ev.push({ who: m.who, type: "note", t: Math.max(0, h.t + jitter(m.who, n * 128 + i, 3)), dur: h.piece === "crash" ? 1.5 : 0.2,
                pitch: key, vel: Math.max(1, Math.min(127, v)) });
    });
    return ev;
  }

  // A drum on a pitched layer: that layer's rhythm. One stroke per onset (a chord is one stroke), its
  // velocity; low / middle / high drum by where the note sits in the part's range.
  function performRhythm(m, a, loopBar, n) {
    var ev = [], part = a.part, notes = part.notesByBar[loopBar];
    if (!notes.length) return ev;
    var span = Math.max(1, part.hi - part.lo);
    chordsIn(loopBar, notes).forEach(function (g, gi) {
      var x = g[0], r = (x.p - part.lo) / span;
      var key = a.drums[r < 0.34 ? 0 : r < 0.67 ? 1 : 2];
      ev.push({ who: m.who, type: "note", t: Math.max(0, x.t + jitter(m.who, n * 64 + gi, 3)), dur: 0.2, pitch: key,
                vel: Math.max(1, Math.min(127, Math.round(x.v * (g.length > 1 ? 1.05 : 1)))) });
    });
    return ev;
  }

  // A pitched instrument on the groove: the groove's kick and snare, short, on the chord's root (kick) and fifth (snare).
  function performRoots(m, loopBar, n) {
    var ev = [];
    if (!groove) return ev;
    var ins = m.ins;
    var ch = T.chords[loopBar];
    groove.hitsByBar[loopBar].forEach(function (h, i) {
      if (h.piece !== "kick" && h.piece !== "snare") return;
      var sym = ch[0][1];
      ch.forEach(function (c) { if (c[0] <= h.t + 1e-6) sym = c[1]; });
      var root = PC[sym.length > 1 && (sym[1] === "b" || sym[1] === "#") ? sym.slice(0, 2) : sym[0]];
      var base = ins.lo + ((root - ins.lo) % 12 + 12) % 12;
      if (base < ins.lo + 4) base += 12;                               // a little clear of the bottom
      var p = h.piece === "kick" ? base : base + 7;
      ev.push({ who: m.who, type: "note", t: Math.max(0, h.t + jitter(m.who, n * 128 + i, 3)), dur: ins.sustain ? 0.2 : 0.3, pitch: p,
                vel: Math.max(1, Math.min(127, Math.round(h.vel * 0.9))) });
    });
    return ev;
  }

  function planBar(n) {
    var loopBar = ((n % T.bars) + T.bars) % T.bars;
    var section = "";
    T.sections.forEach(function (s) { if (loopBar >= s.start && loopBar < s.start + s.bars) section = s.name; });
    var out = { bar: n, loopBar: loopBar, section: section, chord: T.chords[loopBar].map(function (c) { return c[1]; }).join(" "),
                roles: {}, levels: {}, events: [] };
    lineup.forEach(function (l) {
      var m = { who: l.who, instrument: l.instrument, ins: inst(l.instrument) };
      var a = plan[l.who] || { how: "none", label: "" };
      out.roles[l.who] = a.label;
      switch (a.how) {
        case "groove":
          out.levels[l.who] = a.perc ? -7 : ROLE_DB.rhythm;
          out.events = out.events.concat(performGroove(m, a, loopBar, n));
          break;
        case "roots":
          out.levels[l.who] = -6;
          out.events = out.events.concat(performRoots(m, loopBar, n));
          break;
        case "rhythm":
          out.levels[l.who] = -7;
          out.events = out.events.concat(performRhythm(m, a, loopBar, n));
          break;
        case "sing":
          out.levels[l.who] = ROLE_DB[a.part.role] || -6;
          out.events.push({ who: l.who, type: "sing", part: a.part.id, loopBar: loopBar, t: 0 });
          break;
        case "play":
          var db = ROLE_DB[a.part.role] || -6;
          if (a.part.poly > 1 && m.ins.poly < 2) db += 2;           // a single line from the chords: a bit more present
          out.levels[l.who] = db;
          out.events = out.events.concat(perform(m, a, a.part, loopBar, n));
          break;
        default:
          out.levels[l.who] = -60;
      }
    });
    return out;
  }

  return {
    configure: function (c) { cfg.instruments = (c && c.instruments) || cfg.instruments; cfg.voices = (c && c.voices) || cfg.voices; return Object.keys(KIND); },
    load: load, info: info, setLineup: setLineup, planBar: planBar,
    kinds: function () { return KIND; }, voiceRanges: function () { return VOICE_RANGE; },
    fitFor: function (instrument, partId) { var p = parts[partId]; return p ? fit(p, inst(instrument)) : null; }
  };
})();

if (typeof module !== "undefined") module.exports = Lab;
