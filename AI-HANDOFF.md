# Hallways — AI handoff (September 10, 2026)

## Start here
The project is `/Users/edwardbrayman/Development/Active/Hallways`. It is a native iOS app (SwiftUI + SceneKit), NOT React Native. Open `Hallways.xcodeproj`, scheme `Hallways`. Bundle ID: `maxsdad.Hallways`. Git remote: https://github.com/eddienorton/hallways.git, branch `main`. Latest known good commit before the work below: `2136fce`. Always inspect `git status` and recent commits first; this handoff is being written BEFORE implementation, and may outlive a usage-limit interruption. Do not assume pending work has been completed. Preserve uncommitted changes and all older sibling backups.

Eddie wants a simple, immersive, first-person hallway game controlled by gestures. He is an experienced developer; be direct, work autonomously, test, and commit/push completed work. He dislikes unnecessarily complex missions, repeated permission requests, and losing working features. Make focused edits, not broad rewrites. Earlier recovery fixed a missing enum switch case: adding an ObjectKind requires handling EVERY exhaustive switch, especially rendering and editor labels.

## Current request and interruption risk
Codex is attempting to begin floor 4 now, with only about 13% usage remaining according to Eddie. It may hit its limit before finishing. Finish the following if pending:
1. Sprinkle 1–3 mirrors each on floors 2 and 3. Decorate otherwise empty dead-end facing walls with a picture or mirror without covering existing doors, mission signs, elevators, chutes, or maps.
2. Replace floor 4's tiny mirror preview with a larger, slightly more complex maze. Mission: collect a colored paint bucket, then paint the walls of every hallway cell by walking through it with the bucket. Elevator must reject departure until all hallway cells are painted. Include the elevator cell on the return trip; no paint before bucket pickup. Reset must restore walls, bucket and progress. Use a visible colored bucket and clear progress/remaining-cell feedback. First pass can use one fixed color; no color-mixing puzzle requested.
3. Tastefully place pictures, mirrors and maps on floor 4. Floor difficulty should grow gradually into dense intersecting mazes on later floors; do not generate an overwhelming final-floor maze now. Floors 2/3 currently have 42/29 cells, respectively, so existing cell counts are not monotonic; preserve their working missions rather than redesigning them without cause.
4. Verify build, regression tests, new paint completion/reset behavior, reachable map cells and fixture placement. Update this handoff with actual outcomes and outstanding work, then commit/push. Never claim device camera verification from a simulator.

## Architecture
- `Hallways/DefaultMazes.json`: bundled floor library, array of records with stable `id`, `cells` ({row,col}), `nextMazeID`, objects/destinations, wall fixtures and mission configuration.
- `Hallways/MazeStore.swift`: `GridCoordinate`, `ObjectKind`, floor library and editor state. `MazeRecord` has MANUAL CodingKeys, decode and encode: update all three for new persisted fields, plus initial load, save, switch, undo, clear and export. Wall fixtures typically use coord/direction pairs. `MazeStore` owns only the selected live floor and an in-memory multi-floor library.
- IMPORTANT STORAGE: startup currently reads bundled JSON, NOT the local backup. Editor saves write Documents/mazes.json as backup/export, but do not load it at startup. Do not silently change this policy or assume AsyncStorage exists.
- `Hallways/GridEditorView.swift`: developer-only grid editor, four orientation controls for pictures, mirrors, maps and doors; floor navigation, erase, undo and JSON export. Editor accessible from gameplay HUD. New fixture modes must be mutually exclusive.
- `Hallways/HallwayScene.swift`: constructs SceneKit walls, lighting, floors, elevators, framed pictures/maps, chutes and objects. World x=col*cellSize, z=row*cellSize. Camera eye height1.6. Be careful with shared SCNMaterial instances: painting one cell must not repaint every wall or frame. Preserve fixture textures, camera feeds, floor and ceiling.
- `Hallways/TapNavigationController.swift`: actual movement/rotation, per-cell arrivals (including mid-run), collection, deliveries, elevator gate and in-world warnings, reset. Add paint on EVERY arrival, not just the final step of a multi-cell glide. `isMissionComplete` gates `openElevator` and pinch-forward elevator access.
- `Hallways/MazeNavigation.swift`: pure maze walking to next decision. Normal taps do not turn at L bends. Long-press calls `advanceWhileHeld()` on a timer: forward when possible, otherwise exactly one left/right exit rotates; two exits wait for swipe, no automatic U-turn. A new tick after the pivot walks; releasing cancels future ticks. Do not break this behavior.
- `Hallways/ContentView.swift`: representable/coordinator, gestures, HUD, scene rebuild/floor transitions, collection effects and theme changes.
- `Hallways/MailDelivery.swift`: addressed mail and room doors; doors have numbered plaques, mail slots, and shiny chrome knobs.
- `Hallways/Mirror.swift`: framed live front-camera feed, mirrored/center cropped. Camera lifecycle is foreground gameplay only on floors with mirrors; stops in editor/background/teardown. Permission/no-camera placeholder. No capture/recording/microphone; no facial-expression detection yet.
- `Hallways/SoundEffects.swift` and Audio assets: mail pickup/delivery MP3s, trash-chute opening/closing, elevator ding etc. Preserve working audio.
- `HallwaysTests/HallwaysTests.swift`: 12 passing Swift Testing regressions before this request (mail routing/reset, elevator gate, repeated map/mirror stops, geometry, sound, mirror export/undo/orientation, held walking left/right/L/T and stationary starts).
- `CLAUDE.md`: current implementation section is useful; older chronological text is stale (including claims no compiler/Git access). Update the current section, do not follow stale environment limitations.

## Existing floor/gameplay behavior to preserve
1. Building tap → hallway → elevator sequence, synchronized ding/door opening.
2. Trash collection and disposal mission; bottomless chute with correctly tiled bricks, waits2.5sec then closes with sound. Cannot leave with trash uncollected/undisposed. In-world warning.
3. Addressed mail, rooms301–304, four letters. Pick up letters with mail-pick-up.mp3; deliver ONLY to matching door while standing/facing it, using mail-letter-drop-in-door-slot.mp3. Incorrect/remote doors cannot consume mail. Floor3 links to4.
4. Before this request, ONLY a two-cell mirror preview (row10,col7 elevator; row11,col7 mirror facing south), no mission and no next floor. This is the floor to replace.
Pictures use aspect-preserving cover cropping, from bundled Pictures or the entire authorized photo library. Pictures and mirrors stop walking on every pass. Mirrors use separate `mirrors` records. Doors are tall near-floor wooden panels with room numbers. Editor assigns sequential room numbers by floor.

## Build/test environment
Xcode26.6, iOS26.5 simulator runtime; Swift5 language mode with MainActor default isolation. SceneKit code has existing deprecation/concurrency warnings; do not turn this task into a platform migration.
Dedicated simulator: `Hallways Recovery` (iPhone17Pro), UUID `FF00AC39-680E-45CC-ABBA-F49E23822FA4`. Do not disturb Eddie's other iPad simulator.
Example:
```
xcodebuild -project Hallways.xcodeproj -scheme Hallways -configuration Debug -destination 'platform=iOS Simulator,id=FF00AC39-680E-45CC-ABBA-F49E23822FA4' -derivedDataPath /private/tmp/HallwaysRecovery-complete -parallel-testing-enabled NO -only-testing:HallwaysTests CODE_SIGNING_ALLOWED=NO test
```
Simulator commands/builds and Git network writes may need tool sandbox escalation. Available filesystem permissions vary by session. Local tests use SCNRenderer and repeatedly call controller.renderer(updateAtTime:) while awaiting Task.yield to flush main-thread arrival callbacks. A successful simulator build does not verify front camera; Eddie must check a real iPhone.

## Implementation status
Completed in Cursor on September 10, 2026 (after Codex hit its limit mid-attempt):
- Floors 2 and 3 already had 3 mirrors each in `DefaultMazes.json`; dead-end facing walls were already decorated except elevator door walls (left alone on purpose).
- Floor 4 is a 55-cell maze, `missionObjectKind: paintBucket`, bucket at (11,8) next to the elevator hall, maps/pictures/mirrors placed. All cells reachable from the elevator.
- Added `WallPainter.swift` + `PaintPalette.blue` + a 3D paint-bucket node (these were referenced but missing, which is why the unfinished Codex pass would not compile).
- Paint applies on every cell arrival after pickup, including the elevator cell on return. Reset restores walls and the bucket. HUD shows `Painted x/y` on paint floors. Wall maps tint painted cells blue.
- Tests updated for the real floor 4; added a paint completion/reset test.

Outstanding: live selfie-camera mirrors on a physical iPhone; later floors can get denser; no color-mixing puzzle.
