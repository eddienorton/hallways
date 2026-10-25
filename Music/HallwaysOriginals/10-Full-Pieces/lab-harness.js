// node lab-harness.js <scenario.json> <out.json>
// scenario: { template?, bars, roster: {who: instrument}, timeline: [{bar, on: who} | {bar, off: who}] }  (changes at bar starts)
// Layers are given exactly as MusicLab.swift gives them: the next musician switched on takes the lowest vacant
// layer and keeps it; when every layer is taken they wait, and the first waiting gets the next layer freed.
const fs = require("fs");
const Lab = require("./lab-arranger.js");
const sc = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const inst = JSON.parse(fs.readFileSync(__dirname + "/out/instruments.json", "utf8"));
let voices = {};
try { voices = JSON.parse(fs.readFileSync(__dirname + "/out/voices-np/band-voices.json", "utf8")).parts; } catch (e) {}
Lab.configure({ instruments: inst, voices: voices });
const meta = Lab.load(JSON.parse(fs.readFileSync(sc.template || __dirname + "/out/templates/comp-night-porter.json", "utf8")));
const slots = meta.layers.map(() => null), waiting = [];
function on(w) {
  const i = slots.indexOf(null);
  if (i >= 0) slots[i] = w; else waiting.push(w);
}
function off(w) {
  const i = slots.indexOf(w);
  if (i >= 0) { slots[i] = waiting.length ? waiting.shift() : null; }
  else waiting.splice(waiting.indexOf(w), 1);
}
const out = { meta, bars: [] };
for (let n = 0; n < sc.bars; n++) {
  const ch = (sc.timeline || []).filter(c => c.bar === n);
  if (ch.length) {
    ch.forEach(c => c.on ? on(c.on) : off(c.off));
    const lineup = slots.map((w, i) => w && { who: w, instrument: sc.roster[w], layer: i }).filter(Boolean)
      .concat(waiting.map(w => ({ who: w, instrument: sc.roster[w], layer: null })));
    const a = Lab.setLineup(lineup);
    console.log("bar " + (n + 1) + ":\n  " + a.map(x => `${x.who} (${sc.roster[x.who]}): ${x.label}`).join("\n  "));
  }
  out.bars.push(Lab.planBar(n));
}
if (process.argv[3]) fs.writeFileSync(process.argv[3], JSON.stringify(out));
console.log("events", out.bars.reduce((s, b) => s + b.events.length, 0));
