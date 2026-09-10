# Hallways — Project Context for Claude

*(Working name — no final title chosen yet.)*

## About the Developer
Eddie Brayman, 72, independent iOS developer, East Village NYC. 55+ years coding experience. Works solo with Claude as primary coding partner. Philosophy: ship production-quality code, no ads, direct personal hooks for app concepts, gesture-first UI design. Cannot compile or run code himself in an AI session — always builds/tests in Xcode on his own Mac and reports back with screenshots and plain-language descriptions of what he sees.

---

## What This App Is

**Hallways** is a one-finger, first-person, 3D corridor-navigation game. Tap to walk forward through a maze (auto-continuing through pass-throughs, stopping only at real decisions — forks, dead ends, pickups, and destinations); a brief overhead view lets you memorize the layout before a run. Tech: SwiftUI + SceneKit. Bundle ID `maxsdad.Hallways`.

**Origin, Sept 2, 2026.** Landed the same day the "next app" search (see `documents/New-App-Strategy.md`) hit "nothing is grabbing me" for the umpteenth candidate. Direct inspiration: Royal Smash — tap, instant visceral payoff, unpredictability, repeat, no waiting. Deliberately started from an interaction/feel test rather than a technology looking for a reason to exist, which is Eddie's own diagnosis of why earlier candidates kept stalling. Dev philosophy, followed throughout: build a tiny thing, Eddie plays it, does it feel good, adjust, repeat — only then add one more thing.

**The core mechanic** (landed Sept 4, after real design discussion — Eddie's own reasoning, not Claude-driven): the puzzle lives in the 2D maze graph; the first-person 3D view is presentation on top of it, not where the challenge should live. Hand-authored mazes (5-10 planned) carry manually-placed 3D objects (currently: heart, star, ice-cream, apple, baby-carriage, snowman, biking-person, cake — Font Awesome Free Solid icons rendered as real 3D SceneKit geometry via a hand-built SVG path parser, not flat images). Walking into an object picks it up into a capacity-limited carry list; a matching destination elsewhere in the maze delivers it, revealed behind a steel shutter you tap open. An explicit elevator/kill/fight framing was considered and rejected early as off-tone and too complex for a solo dev.

---

## Current implementation — Sept 10, 2026 (Codex)

This section supersedes older status and environment notes below. Xcode 26.6 and iOS 26.5 simulators are available here; Codex can compile, run focused tests, launch the app, and inspect simulator screenshots.

- Mirrors are separate wall fixtures (`mirrors`, coordinate + direction) with four editor orientation buttons, cyan placement hints, erase/undo, floor switching, and explicit JSON coding/export. Like pictures, they stop navigation on every pass. Floor 4 has a south-facing mirror at row 11, column 7.
- `Mirror.swift` provides a framed, mirrored front-camera preview with an aspect-preserving center crop. Camera permission is requested on a mirror floor; capture stops in the editor, during the intro, on inactive/background scenes, and on scene teardown. It saves no images/video and uses no microphone. Simulator/no-camera and denied permission show a placeholder; real camera orientation/appearance still needs device verification. No expression detection or fourth-floor mission is implemented.
- Room doors have rounded chrome knobs, stems, and circular roses with specular highlights and a reflection texture. Mail slots and delivery behavior are unchanged.
- Held walking now pivots and continues at an L corner when forward is blocked and exactly one side is open, including starting from a standstill against a wall. The passage behind the player does not affect the choice. Blocked T junctions and dead ends wait. Ordinary tap behavior is unchanged; releasing during a pivot does not queue a subsequent walk.
- Navigation is gesture-based: tap to walk, drag to turn, swipe down/two-finger tap to turn around. Pinch-out walks forward or opens the elevator when facing its doors; pinch-in backs up one cell without turning. Wall maps and pictures stop movement on every pass. Wall-map taps no longer open the full-screen map; the editor remains reachable from the HUD.
- Mission posters are 25% taller with larger type and a centered heading. Wall maps/frames are 40% larger; legend plaque size is unchanged.
- Floor 3 is a bundled mail-delivery loop with rooms 301–304 and four addressed envelopes. Floor 2 links to floor 3. Floor 4 is a 55-cell paint mission (blue bucket, walk every cell including the elevator on the way back). Floors 2 and 3 each have three wall mirrors. Startup reads the bundled library; editor saves also write a local mazes.json backup that is not loaded at launch.
- `MailDelivery.swift` contains room/mail models and SceneKit artwork: floor-standing wooden doors with numbered plaques and mail slots, plus flat spinning envelopes with readable addresses on both faces.
- Door numbers and per-envelope addresses persist through explicit `MazeRecord` coding, saves, floor switches, export and undo. Editor Door controls choose the wall; numbers are assigned automatically. Mail placement has an optional destination-room selector. Doors should be placed before letters; unaddressed letters are assigned when a door is added. Deleting a door leaves its mail address intact for explicit reassignment; invalid mail cannot be picked up.
- Carried mail is separate from ordinary carried objects, shown with room numbers. Tap the matching door while standing in its cell and facing it to deliver only that room's mail. Trash chutes cannot discard mail. Mission completion requires actual delivery of every placed letter.
- Focused simulator tests cover addressed delivery, wrong/remote door rejection, reset, repeated map stops, backward facing preservation, and elevator pinch mission gating. All nine tests passed on Sept 10, including mirror JSON export/undo/floor switching, wall orientations, and return-trip stops. Simulator render previews also checked the editor, mirror, and chrome knobs. Visual feel still benefits from Eddie's playtesting.

## Recovery — Sept 9, 2026 (evening)

Recovered from `Hallways-3-floors-complete`. The two-floor `Hallways` snapshot is older; the Cursor snapshot differs only in map data, storage code, and this document. Its storage rewrite was not adopted.

Both three-floor snapshots failed to build because `ObjectKind.key` lacked a `makeObjectNode` switch case. The missing key geometry is now implemented. The existing `Audio/trash-chute.mp3` is retained, with explicit playback-session activation and decoding/playback error reporting. Floor 3's rooms 301–304, addressed mail, editor controls, and mission checks are retained.

Recovery tests cover mail routing/reset, repeated map stops/backward movement, elevator mission gating, all object renderers, all three bundled floors, and bundled chute-audio playback.

## Status / build log

**Sept 2-3, 2026 — foundation.** Tap-to-advance navigation (replacing an earlier steer-by-drag prototype); shared brick/dark floor/ceiling look; amber intersection markers; 2D grid editor with position+facing marker; a swappable photo-theme system (6 bundled themes + a 7th pulling the camera roll). Portrait/landscape light falloff fixed (headlamp attenuation + fog scaled to live aspect ratio); dead ends got their own light-immune cap material; nav redesigned to an always-visible D-pad (forward walks, left/right/back pure rotation).

**Sept 3-4 — multi-floor structure.** No server/backend/sign-in yet (Eddie's call), but storage shaped server-ready: stable maze id = floor number, runs recorded as `{mazeID, time, date}`. `MazeStore` holds one floor live plus current/next maze IDs, persisted to `mazes.json`. A real bug found and fixed: `MazeRecord` silently failed to conform to `Encodable` (a stale `objectCells` CodingKeys case with no matching stored property broke Swift's synthesized `Codable`) — fixed with hand-written `encode(to:)`/`init(from:)`. **Standing rule that came out of this: any new `MazeRecord` field needs its own line in both, by hand, or it silently fails to persist.**

**Sept 4 — washout bug, fully root-caused.** "Near-white walls" traced through 4 rounds to headlamp intensity being too high at point-blank/head-on angles. Fixed: headlamp 170→30, ambient 70→110 (ambient carries baseline visibility since it can't spike the way a camera-mounted light does). Confirmed fixed by Eddie on-device.

**Sept 4 — pickup mechanic, first slice.** Object placement + visuals only at first (a spinning heart), then generalized to an `ObjectKind` enum backed by real Font Awesome icons via a hand-built `SVGPathParser.swift` (M/L/H/V/C/S/Q/T/Z plus arc support). `GridEditorView` redesigned around this: all controls off the grid into a bottom bar, fixed 15×20 grid (this also killed a "diagonal trail of tiny rooms" drag bug that came from dynamically resizing the grid near its edges).

**Sept 5 — real control over auto-walking.** Eddie pushed back hard on unexplained multi-step auto-turning; root cause found (a queued walk silently auto-turned through any single-option cell) and fixed per his explicit spec: any required turn, forced or at a real fork, now stops the walk. His words: "that was a bigger step than you know." Same day: the whole run became one continuous eased glide instead of pausing at each cell boundary ("this feels better," confirmed via before/after screenshots); pickup was changed to also stop the walk, since two critters had gotten silently eaten mid-glide.

**Sept 5 — destination/deliver mechanic, the big feature of this week.** Spec: destination walls are a blank steel shutter until you arrive with a real match, then a tap slides it open to reveal the object behind it; wrong or empty-handed arrival does nothing. Confirmed working end-to-end on-device, then iterated hard on the reveal's presentation:
- Raised the mount height (was hidden under the D-pad).
- Built a real recessed "cubby" behind the shutter instead of a flat icon — deepened over two rounds into a proper short dark passage (destinationCubbyDepth 0.5 → 1.1) with a faint warm emissive tint on the interior walls, chasing Eddie's "like an oven... looking down another very short hallway" description.
- Delivery changed from automatic-on-arrival to tap-to-open (SCNView hit-testing reused inside the existing whole-screen tap gesture, no new gesture recognizer) — Eddie: "i think it should wait for you to tap the steel door before it slides up."
- A separate, unrelated wall decoration experiment (random OFFICE-door photo decals on solid walls) was built, briefly liked ("we can put shit on the walls"), then fully reversed and removed project-wide, including deleting the source image — Eddie: "why are there still doors in here?!?!? ... get rid of the doors."
- **A real, confirmed-root-caused bug, fixed same day:** the cubby's interior kept showing plain brick instead of a dark recess ("as if its clear glass"), across several rounds of guessing (light bleed → categoryBitMask → emission-based icon fix) that didn't touch the actual problem. Root cause, confirmed via a deliberate hot-pink diagnostic material swap before touching real code again: the ordinary solid wall panel was still being built at full size directly behind the cubby (destinations never skipped it), so there was never an actual gap for the recess to be seen through — only the cubby's paper-thin front rim poked past the wall's face. Fix: compute which wall a destination will mount on *before* any wall gets built for that cell, and skip building the ordinary panel on that one side — the recess's own five panels form the wall there instead, the way a real cubby cut into drywall doesn't have drywall floating in front of the hole. **Not yet re-confirmed on-device as of this write** — this was the last code change made before this doc was created.

---

## Open threads / not yet acted on

- **Eddie's "another way to do the svgs" comment (Sept 5, unelaborated).** He mentioned it once, in passing, then moved on to other feedback without ever explaining what he meant. Asked him to say more; never got a follow-up. Worth raising again rather than assuming what it means.
- **The wall-skip fix above needs an on-device confirmation pass** before it's safe to call this feature actually done. Checklist: does the recess now show real depth and the glowing critter instead of brick; does the shutter's new resting position (floating above the opening, not hidden) read OK now that Eddie's explicitly said that's fine; does anything look different on a destination that sits on a *non*-dead-end wall (between two occupied cells) vs. a dead-end cap wall, since skipping the wall there is a slightly bigger structural change.
- Only 8 object kinds exist so far against a stated goal of 5-10 hand-authored mazes; more icon kinds and actual maze layouts are still ahead once the mechanic itself is solid.
- No elevators yet — floor-to-floor progression exists structurally (`nextMazeID`) but "elevators" as their own feature/moment were explicitly deferred behind start/stop control, pickup, and destinations, per Eddie's own roadmap ("that feeling... thats where u spend all your time").

---

## Standing rules worth knowing before doing anything

- **This environment can't compile or run Swift/Xcode/SceneKit, and can't see the running app.** Every code change is "not yet confirmed on device" until Eddie actually builds and tests it — always leave him a concrete, specific thing to check, not just "let me know how it looks."
- **Don't diagnose a visual bug by guessing from the code alone if a cheap, unambiguous visual test is available.** The brick-vs-cubby bug above burned several rounds on plausible-sounding SceneKit theories before a single deliberate hot-pink material swap proved which part of the geometry was actually reaching the screen. Prefer confirm-before-fix over fix-and-hope for anything Eddie reports as "still looks the same."
- **Any new `MazeRecord` field needs a hand-written line in both `encode(to:)` and `init(from:)`** — Swift's synthesized `Codable` is broken for this type (see Sept 3-4 above) and won't warn you.
- **Balance-check every edited file before reporting a change as done** (bracket/brace/paren balance, comment-aware) — this project's edit workflow applies string-replacement scripts blind to the file over a device bridge, with no compiler in the loop until Eddie's next build.
- **Git set up; Eddie pushes it himself from his own Terminal** — no GitHub credentials in the sandbox. Give him exact commands rather than attempting to push directly.

---

*Keep this file current at natural stopping points, same as the top-level `README.md` — update the "Status / build log" and "Open threads" sections before a session ends rather than leaving it for next time to reconstruct.*
