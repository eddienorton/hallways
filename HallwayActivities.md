# Hallway Activities — Design Notes

*Compiled Sept 6, 2026 from a joint brainstorm: Eddie's own findings from actually playing the build, Claude's earlier list, and two full ChatGPT brainstorm passes Eddie ran in parallel. Also published as a Claude artifact the same day; this file is the version that lives with the project.*

## What Changed

The in-game map was a construction tool that snuck into the finished experience. Leaving the first-person view to study an overhead diagram, then coming back, turns the game into map-reading — and every time it happens, the spell breaks. (Eddie still wants the map reachable during actual play for his own dev/verification purposes — this is about the shipped player's mental model, not about pulling the screen entirely.)

Eddie's 10×10 open-room experiment is the real evidence here: a floor with essentially no maze to solve still got interesting the moment it filled up with trash cans and dollar amounts. That means the corridor geometry was never the game — it's the stage. Hallways can be corridors, a gymnasium, a cross, a long skinny run, anything that gives objects somewhere interesting to sit.

Landscape orientation isn't a controls cleanup item, it's a second way of playing: standing in one spot and seeing three hallway openings' worth of trash cans, cash, and fixtures at once is situational awareness the portrait view can't give you. Free rotation between the two, exactly as it already works, stays — clean up control placement for landscape later, not urgent.

## The Test

> Does encountering one thing change what I think about something I saw earlier, or what I'm hoping to find next?

(ChatGPT's line, and the sharpest one either brainstorm produced.) If yes, it's fertile ground. A dollar bill on its own doesn't pass this test — endorphins, sure, but no thought. The number "7" when you're still missing "4" passes it instantly. Judge every activity idea below against this, not against how clever it sounds on paper.

## Wayfinding — Eddie's Own Idea, Sept 6

The elevator is different from everything else on a floor: there's only one, it's usually the farthest point from the start, and losing track of it isn't a fun kind of lost. These three solve that without ever putting a map back in the player's hands.

1. **The Map, As a Wall Object.** A directory board mounted on a wall somewhere on the floor — pannable, zoomable, with a mall-directory "YOU ARE HERE" marker fixed to wherever that board actually sits. Still a map, but a physical thing you walk up to and read, not a UI layer over the game.
2. **Exit Signs.** Hallway objects, not wall-mounted — set higher than everything else, hospital-corridor style — sprinkled specifically along the route toward the elevator. Nothing else on the floor gets this treatment; the elevator is the one thing worth being led to on purpose.
3. **Clue Arrows.** A wayfinding box at a real fork: one arrow left, one arrow right, and the label under each arrow isn't a direction — it's a clue toward whatever the floor's active puzzle actually is.

## The Catalog

Deduplicated and grouped by what kind of thought each one is trying to produce. **HALL** = a floating object in the corridor. **WALL** = a fixed fixture. Timing is instant, carried-then-delivered, or a multi-step chain.

### Already Built
- **Trash & Chute** (Hall+Wall, Carry) — unwanted pickup, dumped at any chute, blocks boarding the elevator while carried.
- **Cash** (Hall, Instant) — absorbed on contact, feeding the running total that's shaping up to be the actual score.
- **Elevator** (Wall) — the one fixture that outranks every pickup: unique, usually far, and it's how you actually leave.

### Ordering & Memory
*The family built entirely from tonight's real find: what you can do depends on something you already found.*
- **Sequence** (Hall) — grab items in the order they imply (numbers, a color gradient, sizes, shapes); see the one you need before you're ready for it, remember where it was, go back.
- **Pairs & Opposites** (Hall, Carry) — find a matching twin, or its logical counterpart (a key and its lock, a plug and its socket); the payoff is remembering where the other half was.
- **Assemble the Set** (Hall+Wall, Carry) — several distinct pieces that only pay off once all of them reach one wall together; no order required, just completeness.
- **Pattern Recall** (Wall+Hall, Multi-step) — a wall flashes a sequence, or a trail lights up behind you, or a plaque shows a shape — then it's gone, and you act on the memory alone. (Simon / Breadcrumb / Copy, merged.)
- **Combination / Recipe** (Hall+Wall, Multi-step) — clues scattered through the floor add up to a code entered on a keypad, or a set of ingredients gathered in one run.

### Currency & Economy
*Gives the running total something to do besides go up.*
- **Spend or Save** (Wall, Instant) — a toll, a shortcut, a vault door, each costs cash to open; every use trades score for progress.
- **Exact Change** (Wall, Carry) — a machine wants a specific total; scattered bills of different values force choosing which to grab, not grabbing all of them.
- **Vending & Coin** (Hall+Wall, Carry) — a currency kept separate from cash on purpose, spent at a machine for a reward.
- **Elevator Toll** (Wall) — the elevator itself gets a condition before it opens: a dollar amount, no trash carried, a specific item in hand.

### Cause & Effect
*Get the tool here, use it there — the extinguisher idea, generalized.*
- **Fire & Extinguisher** (Hall+Wall, Carry) — see the obstacle first or the tool first, in either order; backtracking to use it is the whole point.
- **Key & Locked Door** (Hall+Wall, Carry) — unlike a trash chute, this delivery has to go to ONE specific place (misdelivered mail is the same idea with a mailbox instead of a lock).
- **Power & Switches** (Wall, Instant) — flip a switch or restore power here, and something changes at a location you already walked past.
- **Chain Reaction** (Hall+Wall, Multi-step) — A unlocks B, B enables C; each step only makes sense once you've already seen the one before it.
- **Trade / Convert** (Wall, Carry) — hand over what you're carrying, get back something different; what you needed wasn't what you found.

### Search & Senses
*How you find things without ever opening a map.*
- **Hot / Cold** (Hall) — audio or visual feedback strengthens as you approach a target; you search the space, not a screen.
- **Lights Out** (Wall) — ceiling lights spell a path, a pattern, or a clue, if you know to look up.
- **Window & Mirror** (Wall) — reveals something otherwise out of view: behind you, or in a space you haven't reached yet.

### Choice & Hazard
*The decisions that add real weight instead of "grab everything."*
- **Don't Touch** (Hall) — some objects are obviously bad news; the smart move is routing around, not collecting.
- **Wrong One** (Hall) — several near-identical objects, only one correct; an in-world clue, not a UI hint, tells you which.
- **Choice** (Hall) — two mutually exclusive pickups; whichever you take changes what happens later, and you don't find out which was "right" until then.
- **Mystery Box** (Hall) — effect unknown until you take it; the game teaches its own rules through consequence, not instruction.

### Atmosphere & Flavor
*No mechanical payoff — pure texture, and it still earns its keep.*
- **Intercom, Signs & Clocks** (Wall) — a joke, a clue, a story fragment, or occasionally a lie; information with no system attached.
- **Secret Passage** (Wall) — a suspicious-looking fixture that opens a hidden room when inspected.
- **Companion** (Hall) — a friendly floating thing that follows you rather than sitting in your pocket; you deliver IT somewhere, instead of using it.
- **Lost & Found** (Hall+Wall, Carry) — return something to its owner or the right window, using hints in the room rather than a label.

### Bigger Swings — Needs New Movement
*Genuinely interesting, but each one assumes the player can push, chase, or dodge things in real time — a different movement model than tap-to-advance. Someday, not next.*
- **Push & Redirect** — physical, Sokoban-style object manipulation.
- **Follow-Me / Avoid-Me** — a moving object you have to chase or dodge.
- **Grow / Shrink** — changes your size, and therefore which openings you can fit through.

## What's Next

Still can't answer "what is Hallways" in one sentence — but there's a working thesis now: it's not a maze-solving game, it's a spatial-relationship playground where the corridors are the stage, not the challenge. Three things worth actually building, in this order:

1. **The wayfinding trio.** The map-as-wall-object, exit signs, and clue arrows all came out of tonight directly, they're cheap relative to everything else here, and they solve the one problem Eddie actually hit while playing.
2. **One Currency & Economy activity.** Spend or Save is the natural next step — the running total already exists in code, this just gives it a wall to talk to.
3. **One full Ordering & Memory activity, end to end.** Assemble the Set or a short Sequence run is the real test of whether "remember what you saw" actually feels like a puzzle once it's playable, before building three more variations of it.
