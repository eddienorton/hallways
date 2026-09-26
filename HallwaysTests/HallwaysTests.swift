import Testing
import SceneKit
import AVFoundation
@testable import Hallways

@MainActor
struct HallwaysTests {
    private func finishMove(_ controller: TapNavigationController, renderer: SCNRenderer, time: inout Double) async {
        for _ in 0..<400 {
            time += 0.05
            controller.renderer(renderer, updateAtTime: time)
            await Task.yield()
            if !controller.isAnimating { return }
        }
        #expect(!controller.isAnimating)
    }

    @Test func mailMustReachItsAddressAndResetRestoresIt() async {
        let scene = SCNScene()
        let camera = SCNNode(); camera.position.y = 1.6
        scene.rootNode.addChildNode(camera)
        let cells = Set((0...4).map { GridCoordinate(row: 0, col: $0) })
        let first = GridCoordinate(row: 0, col: 1)
        let second = GridCoordinate(row: 0, col: 2)
        let room301 = GridCoordinate(row: 0, col: 3)
        let room302 = GridCoordinate(row: 0, col: 4)
        let controller = TapNavigationController(cameraNode: camera, scene: scene, cells: cells, cellSize: 3.2,
            startCell: GridCoordinate(row: 0, col: 0), startFacing: .east, endCell: room302,
            objects: [first: .envelope, second: .envelope],
            roomDoors: [room301: RoomDoorPlacement(coord: room301, direction: .north, roomNumber: 301),
                        room302: RoomDoorPlacement(coord: room302, direction: .north, roomNumber: 302)],
            itemRooms: [first: 301, second: 302], missionObjectKind: .envelope)
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 1.0
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == first)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.carriedMail.map(\.roomNumber) == [301, 302])
        #expect(!controller.isMissionComplete)
        // A remote door cannot accept delivery.
        controller.deliverMail(at: room301)
        #expect(controller.carriedMail.count == 2)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == room301)
        // Standing alongside the door without facing it cannot deliver.
        controller.deliverMail(at: room301)
        #expect(controller.carriedMail.count == 2)
        controller.rotate(toward: .north); await finishMove(controller, renderer: renderer, time: &time)
        controller.deliverMail(at: room301)
        #expect(controller.carriedMail.map(\.roomNumber) == [302])
        #expect(!controller.isMissionComplete)
        controller.deliverMail(at: room301)
        #expect(controller.carriedMail.map(\.roomNumber) == [302])
        controller.rotate(toward: .east); await finishMove(controller, renderer: renderer, time: &time)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        controller.rotate(toward: .north); await finishMove(controller, renderer: renderer, time: &time)
        controller.deliverMail(at: room302)
        #expect(controller.carriedMail.isEmpty)
        #expect(controller.isMissionComplete)
        controller.reset()
        #expect(!controller.isMissionComplete)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.carriedMail.map(\.roomNumber) == [301])
    }

    @Test func mapStopsOnReturnAndBackingUpKeepsFacing() async {
        let scene = SCNScene()
        let camera = SCNNode(); camera.position.y = 1.6
        scene.rootNode.addChildNode(camera)
        let start = GridCoordinate(row: 0, col: 0)
        let map = GridCoordinate(row: 0, col: 2)
        let end = GridCoordinate(row: 0, col: 4)
        let controller = TapNavigationController(cameraNode: camera, scene: scene,
            cells: Set((0...4).map { GridCoordinate(row: 0, col: $0) }), cellSize: 3.2,
            startCell: start, startFacing: .east, endCell: end, floorMaps: [map: .north])
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 1.0
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == map)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == end)
        controller.stepBackward(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == GridCoordinate(row: 0, col: 3))
        #expect(controller.facing == .east)
        controller.rotate(toward: .west); await finishMove(controller, renderer: renderer, time: &time)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == map)
    }

    @Test func elevatorPinchUsesMissionGate() {
        let scene = SCNScene()
        let camera = SCNNode()
        let left = SCNNode(), right = SCNNode()
        scene.rootNode.addChildNode(camera)
        let start = GridCoordinate(row: 0, col: 0)
        let letter = GridCoordinate(row: 1, col: 0)
        let controller = TapNavigationController(cameraNode: camera, scene: scene, cells: [start, letter], cellSize: 3.2,
            startCell: start, startFacing: .north, endCell: start, objects: [letter: .envelope],
            elevatorLeftDoor: left, elevatorRightDoor: right, elevatorMountDirection: .north,
            missionObjectKind: .envelope)
        controller.pinchForward()
        #expect(controller.elevatorRejected != nil)
        #expect(controller.currentCell == start)
    }
    @Test func recoveredFloorsKeepMailAddressesAndPlayableChuteAudio() throws {
        let store = MazeStore()
        #expect(store.floorCount == 4)
        store.switchTo(id: 2)
        #expect(store.nextMazeID == 3)
        store.switchTo(id: 3)
        #expect(store.missionObjectKind == .envelope)
        let rooms = Set(store.roomDoors.values.map(\.roomNumber))
        #expect(rooms == [301, 302, 303, 304])
        let letters = store.objects.filter { $0.value == .envelope }
        #expect(letters.count == 4)
        #expect(letters.keys.allSatisfy { coord in
            store.itemRooms[coord].map { rooms.contains($0) } ?? false
        })
        store.switchTo(id: 4)
        #expect(store.missionObjectKind == .paintBucket)
        #expect(store.objects.values.contains(.paintBucket))
        #expect(store.cells.count == 55)
        #expect(store.mirrors.count == 3)

    }


    @Test func separateChuteSoundsAreBundledPreparedAndPlayable() async throws {
        for name in ["trash-chute-open", "trash-chute-close"] {
            let url = try #require(
                Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "audio")
                    ?? Bundle.main.url(forResource: name, withExtension: "mp3")
            )
            let player = try AVAudioPlayer(contentsOf: url)
            #expect(player.duration > 0)
            #expect(player.prepareToPlay())
        }
        await SoundEffects.prepareForGameplay()
        #expect(SoundEffects.playTrashChuteOpen())
        #expect(SoundEffects.playTrashChuteClose())
        #expect(AVAudioSession.sharedInstance().category == .playback)
    }

    // Sept 24 (knock audio ladder): all three knock MP3s must be bundled
    // and decodable, and playKnock must climb soft -> medium -> hard
    // inside a five-second window, stay hard for further knocks in it,
    // and fall back to soft after a gap GREATER than five seconds. The
    // injected-time form makes the reset deterministic in a unit test
    // (the production call is the no-argument playKnock()).
    @Test func knockLadderEscalatesSoftMediumHardAndResetsAfterFiveSeconds() async throws {
        for name in ["knock-soft", "knock-medium", "knock-hard"] {
            let url = try #require(
                Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "audio")
                    ?? Bundle.main.url(forResource: name, withExtension: "mp3")
            )
            let player = try AVAudioPlayer(contentsOf: url)
            #expect(player.duration > 0)
            #expect(player.prepareToPlay())
        }
        // Every stage must resolve to its OWN file, never a substitute.
        #expect(SoundEffects.knockFilename(forStage: 0) == "knock-soft.mp3")
        #expect(SoundEffects.knockFilename(forStage: 1) == "knock-medium.mp3")
        #expect(SoundEffects.knockFilename(forStage: 2) == "knock-hard.mp3")
        #expect(SoundEffects.knockFilename(forStage: 3) == "knock-hard.mp3")

        SoundEffects.resetKnockLadder()
        await SoundEffects.prepareForGameplay()
        let start = Date()
        #expect(SoundEffects.playKnock(at: start))                                              // 1st: soft
        #expect(SoundEffects.lastKnockFilename == "knock-soft.mp3")
        #expect(SoundEffects.playKnock(at: start.addingTimeInterval(1)))                        // 2nd within 5s: medium
        #expect(SoundEffects.lastKnockFilename == "knock-medium.mp3")
        #expect(SoundEffects.playKnock(at: start.addingTimeInterval(2)))                        // 3rd within 5s: hard
        #expect(SoundEffects.lastKnockFilename == "knock-hard.mp3")
        #expect(SoundEffects.playKnock(at: start.addingTimeInterval(3)))                        // further within 5s: stays hard
        #expect(SoundEffects.lastKnockFilename == "knock-hard.mp3")
        // 3 + 5 = 8s is exactly five seconds since the last knock: still
        // hard (reset needs GREATER than five).
        #expect(SoundEffects.playKnock(at: start.addingTimeInterval(8)))
        #expect(SoundEffects.lastKnockFilename == "knock-hard.mp3")
        // 3 + 6 = 9s is a gap over five seconds: ladder resets to soft.
        #expect(SoundEffects.playKnock(at: start.addingTimeInterval(9)))
        #expect(SoundEffects.lastKnockFilename == "knock-soft.mp3")
        SoundEffects.resetKnockLadder()
    }

    @Test func everyObjectKindHasSceneGeometry() {
        let coords = ObjectKind.allCases.enumerated().map { GridCoordinate(row: 0, col: $0.offset) }
        let objects = Dictionary(uniqueKeysWithValues: zip(coords, ObjectKind.allCases))
        let result = HallwayScene.build(fromMaze: Set(coords), cellSize: 3.2, wallHeight: 3,
                                       objects: objects, playerStart: coords.first, playerEnd: coords.last)
        #expect(result.objectNodes.count == ObjectKind.allCases.count)
        #expect(result.objectNodes.values.allSatisfy { !$0.childNodes.isEmpty || $0.geometry != nil })
    }

    @Test func mailAudioAssetsDecodeAndPlay() throws {
        for name in ["mail-pick-up", "mail-letter-drop-in-door-slot"] {
            let url = try #require(
                Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "audio")
                    ?? Bundle.main.url(forResource: name, withExtension: "mp3")
            )
            let player = try AVAudioPlayer(contentsOf: url)
            #expect(player.duration > 0)
        }
        #expect(SoundEffects.playMailPickup())
        #expect(SoundEffects.playMailDelivery())
    }

    @Test func mirrorEditsSurviveFloorSwitchExportAndUndo() throws {
        let store = MazeStore()
        store.switchTo(id: 2)
        let coord = GridCoordinate(row: 5, col: 4)
        #expect(store.canPlaceMirror(.north, at: coord))
        store.placeMirror(.north, at: coord)
        #expect(store.mirrors[coord] == .north)
        store.placeMirror(.south, at: MazeStore.elevatorCoordinate) // Open neighbor, not a wall.
        #expect(store.mirrors[MazeStore.elevatorCoordinate] == nil)
        store.switchTo(id: 3)
        store.switchTo(id: 2)
        #expect(store.mirrors[coord] == .north)
        let json = try #require(store.exportLibraryJSON()?.data(using: .utf8))
        let floors = try #require(JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        let second = try #require(floors.first { $0["id"] as? Int == 2 })
        let mirrors = try #require(second["mirrors"] as? [[String: Any]])
        #expect(mirrors.contains { item in
            let placed = item["coord"] as? [String: Int]
            return placed?["row"] == 5 && placed?["col"] == 4 && item["direction"] as? String == "north"
        })
        store.snapshotForUndo()
        store.removeMirror(at: coord)
        #expect(store.mirrors[coord] == nil)
        store.undo()
        #expect(store.mirrors[coord] == .north)
    }

    // Sept 21 (Photo Booth Floor Editor placement): coord/direction (4,0)
    // facing west and coord/direction (4,1) facing north on Floor 2 are
    // both confirmed, directly from DefaultMazes.json, to be open cells
    // with a solid neighbor in that direction and no other placed content
    // -- deliberately NOT reusing mirrorEditsSurviveFloorSwitchExportAndUndo's
    // own (5,4)/.north coordinate above, so this test can never collide
    // with that one's own placeMirror call regardless of test run order.
    @Test func photoBoothPlacementSurvivesFloorSwitchAndSupportsMultipleBooths() throws {
        let store = MazeStore()
        store.switchTo(id: 2)
        let first = GridCoordinate(row: 4, col: 0)
        let second = GridCoordinate(row: 4, col: 1)
        #expect(store.canPlacePhotoBooth(.west, at: first))
        store.placePhotoBooth(.west, expression: .mouthOpen, at: first)
        #expect(store.photoBooths[first]?.direction == .west)
        #expect(store.photoBooths[first]?.expression == .mouthOpen)
        // A second, independent booth on the SAME floor -- "multiple
        // booths remain supported."
        #expect(store.canPlacePhotoBooth(.north, at: second))
        store.placePhotoBooth(.north, expression: .eyebrowsRaised, at: second)
        #expect(store.photoBooths.count == 2)
        // Rejected: an open neighbor is not a wall to mount a booth on.
        store.placePhotoBooth(.south, expression: .smile, at: MazeStore.elevatorCoordinate)
        #expect(store.photoBooths[MazeStore.elevatorCoordinate] == nil)
        // Coordinate, direction, AND expression all survive a floor
        // switch away and back.
        store.switchTo(id: 3)
        store.switchTo(id: 2)
        #expect(store.photoBooths[first]?.direction == .west)
        #expect(store.photoBooths[first]?.expression == .mouthOpen)
        #expect(store.photoBooths[second]?.direction == .north)
        #expect(store.photoBooths[second]?.expression == .eyebrowsRaised)
        let json = try #require(store.exportLibraryJSON()?.data(using: .utf8))
        let floors = try #require(JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        let exported = try #require(floors.first { $0["id"] as? Int == 2 })
        let booths = try #require(exported["photoBooths"] as? [[String: Any]])
        #expect(booths.contains { item in
            let placed = item["coord"] as? [String: Int]
            return placed?["row"] == 4 && placed?["col"] == 0 && item["direction"] as? String == "west" && item["expression"] as? String == "mouthOpen"
        })
        // Floor 6's pre-existing, hand-authored booth is completely
        // unaffected by any of the above -- still exactly one booth,
        // same expression and direction as DefaultMazes.json.
        store.switchTo(id: 6)
        #expect(store.photoBooths.count == 1)
        #expect(store.photoBooths.values.first?.expression == .smile)
        #expect(store.photoBooths.values.first?.direction == .east)
    }

    // Sept 21 (Picture Size): same shape as
    // mirrorEditsSurviveFloorSwitchExportAndUndo above, plus the
    // backward-compatibility guarantee -- a picture placed through the
    // plain 2-argument placePicture(_:at:) (every pre-existing call
    // site's exact form) gets Standard with no size argument at all,
    // the same outcome a genuinely legacy floor (no `size` key in its
    // saved JSON) produces via PictureSizePlacement's Optional `size`
    // field and MazeStore's own `?? .standard` at every load site.
    @Test func pictureSizeDefaultsToStandardAndSurvivesFloorSwitchAndExport() throws {
        let store = MazeStore()
        store.switchTo(id: 2)
        let coord = GridCoordinate(row: 4, col: 0)
        store.placePicture(.west, at: coord)
        #expect(store.pictureSize(direction: .west, at: coord) == .standard)
        #expect(PictureSize.standard.scale == 1.0)
        store.setPictureSize(.fullLength, direction: .west, at: coord)
        #expect(store.pictureSize(direction: .west, at: coord) == .fullLength)
        #expect(store.hasPicture(.west, at: coord)) // direction untouched by a size-only change
        store.switchTo(id: 3)
        store.switchTo(id: 2)
        #expect(store.pictureSize(direction: .west, at: coord) == .fullLength)
        let json = try #require(store.exportLibraryJSON()?.data(using: .utf8))
        let floors = try #require(JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        let exported = try #require(floors.first { $0["id"] as? Int == 2 })
        let pics = try #require(exported["pictures"] as? [[String: Any]])
        #expect(pics.contains { item in
            let placed = item["coord"] as? [String: Int]
            return placed?["row"] == 4 && placed?["col"] == 0 && item["direction"] as? String == "west" && item["size"] as? String == "fullLength"
        })
    }

    // Sept 21 (3D Decorator wall authoring, Pass 3): canPlacePicture is
    // the full occupancy check DecoratorState.canAddPicture relies on
    // for a live wall-tap ADD -- deliberately stricter than
    // placePicture's own looser guard (see both functions' own doc
    // comments). Same coordinate this file's own
    // pictureSizeDefaultsToStandardAndSurvivesFloorSwitchAndExport test
    // just above already relies on being a legal, ordinary ((row: 4,
    // col: 0), .west) an ordinary dead-end wall on floor 2.
    @Test func canPlacePictureAcceptsAnOrdinaryWallButRejectsOneAlreadyClaimedOrTheElevatorCell() {
        let store = MazeStore()
        store.switchTo(id: 2)
        let coord = GridCoordinate(row: 4, col: 0)
        #expect(store.canPlacePicture(.west, at: coord))
        store.placeMirror(.west, at: coord)
        // Already claimed by a Mirror -- Picture must be refused on
        // that same wall, matching canPlaceWallLight/canPlacePhotoBooth's
        // own mirrors[coord] exclusion.
        #expect(!store.canPlacePicture(.west, at: coord))
        // The REAL elevator cell on this floor is never a legal Picture
        // wall, regardless of direction -- floor 2's elevator is at
        // floor2ElevatorCoordinate (10,6) (floors 2+ moved off the
        // original fixed elevatorCoordinate in the shared arrival-area
        // design; .west is a genuine solid face there, not the floor-map
        // face). Matches canPlaceMirror/canPlaceWallLight/
        // canPlacePhotoBooth's own elevator-cell exclusion.
        #expect(!store.canPlacePicture(.west, at: MazeStore.floor2ElevatorCoordinate))
        // Sept 24 (Floor 2 Empty Wall repro): cell (10,7) is an ordinary
        // hallway cell on floor 2 -- the breathing/buffer cell one step
        // east of the real elevator at (10,6) -- NOT the elevator itself.
        // Its south wall is a genuine empty ordinary wall (the only wall
        // face that cell has), and Add Picture must be enabled there. The
        // old floor-blind `coord != Self.elevatorCoordinate` check froze
        // it with "Empty Wall" but Add Picture disabled.
        #expect(store.canPlacePicture(.south, at: MazeStore.elevatorCoordinate))
        // Floor 1 keeps the original fixed elevatorCoordinate: (10,7) is
        // still its real elevator cell, so its walls stay refused.
        store.switchTo(id: 1)
        #expect(!store.canPlacePicture(.north, at: MazeStore.elevatorCoordinate))
    }

    // Sept 24 (Empty Wall chooser, decorative room doors): RoomDoorPlacement
    // gained an isDecorative flag, hand-written into the Codable -- legacy
    // bundled/saved JSON authored before the flag (e.g. Floor 3's four
    // 301-304 doors) carries no key and must decode as the default
    // functional door it always was.
    @Test func roomDoorPlacementWithoutTheDecorativeFlagDecodesAsFunctional() throws {
        let data = Data(#"{"coord":{"row":3,"col":5},"direction":"north","roomNumber":301}"#.utf8)
        let decoded = try #require(JSONDecoder().decode(RoomDoorPlacement.self, from: data))
        #expect(decoded.roomNumber == 301)
        #expect(!decoded.isDecorative)
        // New-style JSON round-trips the flag both ways.
        let encoded = try #require(JSONEncoder().encode(decoded))
        let encodedDict = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(encodedDict["isDecorative"] as? Bool == false)
        let decorated = RoomDoorPlacement(coord: GridCoordinate(row: 4, col: 0), direction: .west,
                                          roomNumber: 201, isDecorative: true)
        let reencoded = try #require(JSONEncoder().encode(decorated))
        let roundTripped = try #require(JSONDecoder().decode(RoomDoorPlacement.self, from: reencoded))
        #expect(roundTripped.isDecorative)
    }

    // Sept 24: decorative doors are authored THROUGH the shared
    // placeRoomDoor numbering -- they get real room numbers from the same
    // floor sequence (Floor 2's first door is 201) and persist
    // coordinate/direction/isDecorative through export exactly like any
    // other authored fixture.
    @Test func decorativeRoomDoorsAutoNumberAndPersistThroughExport() throws {
        let store = MazeStore()
        store.switchTo(id: 2)
        let first = GridCoordinate(row: 4, col: 0)
        let second = GridCoordinate(row: 10, col: 8)
        store.placeRoomDoor(.west, at: first, decorative: true)
        let door = try #require(store.roomDoors[first])
        #expect(door.roomNumber == 201) // floor 2, no prior doors/rooms
        #expect(door.isDecorative)
        #expect(!store.canPlaceRoomDoor(.west, at: first)) // cell is occupied now
        store.placeRoomDoor(.south, at: second, decorative: true)
        #expect(store.roomDoors[second]?.roomNumber == door.roomNumber + 1)
        let json = try #require(store.exportLibraryJSON()?.data(using: .utf8))
        let floors = try #require(JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        let exported = try #require(floors.first { $0["id"] as? Int == 2 })
        let doors = try #require(exported["roomDoors"] as? [[String: Any]])
        #expect(doors.count == 2)
        #expect(doors.allSatisfy { item in
            let placed = item["coord"] as? [String: Int]
            let direction = item["direction"] as? String
            let isDecorative = item["isDecorative"] as? Bool
            return (placed?["row"] == 4 && placed?["col"] == 0 && direction == "west" && isDecorative == true)
                || (placed?["row"] == 10 && placed?["col"] == 8 && direction == "south" && isDecorative == true)
        })
    }

    // Sept 24: canPlaceRoomDoor is the occupancy check behind the new
    // Empty Wall -> ADD -> Door choice -- deliberately the same discipline
    // as canPlacePicture on the very next branch of that chooser. (10,7)
    // on Floor 2 is the ordinary breathing cell one east of the real
    // elevator -- a genuinely legal door wall, this time by the same
    // floor-aware endCoordinate logic the Sept 24 canPlacePicture fix
    // introduced -- while the floor's TRUE elevator cell (10,6), a wall
    // already holding a Mirror, and a wall whose neighbor is actually a
    // cell (open side) are all refused.
    @Test func canPlaceRoomDoorAcceptsGenuineEmptyWallsButRejectsClaimedElevatorAndOpenFaces() {
        let store = MazeStore()
        store.switchTo(id: 2)
        let ordinary = GridCoordinate(row: 4, col: 0)
        #expect(store.canPlaceRoomDoor(.west, at: ordinary))
        #expect(!store.canPlaceRoomDoor(.east, at: ordinary)) // (4,1) is a cell -- open side, not a wall
        store.placeMirror(.west, at: ordinary)
        #expect(!store.canPlaceRoomDoor(.west, at: ordinary)) // claimed by a Mirror on that same face
        #expect(!store.canPlaceRoomDoor(.west, at: MazeStore.floor2ElevatorCoordinate)) // real elevator cell
        #expect(store.canPlaceRoomDoor(.south, at: MazeStore.elevatorCoordinate)) // breathing cell (10,7), legal like its Picture
        #expect(!store.canPlaceRoomDoor(.north, at: GridCoordinate(row: 0, col: 7))) // Picture claims that wall
    }

    // Sept 24 (room-door knock interaction): ALL room doors are genuine
    // stops -- functional/mail doors and decorative/architectural doors
    // alike (Eddie closed the brief "decorative doors glide through"
    // behavior so there's always a real tap-the-door moment stopped
    // beside it). Functional vs decorative now differ only in what a tap
    // does once stopped (mail flow vs knock), never in locomotion.
    @Test func allRoomDoorsAreGenuineStopsWhetherFunctionalOrDecorative() async {
        let scene = SCNScene()
        let camera = SCNNode(); camera.position.y = 1.6
        scene.rootNode.addChildNode(camera)
        let start = GridCoordinate(row: 0, col: 0)
        let doorCell = GridCoordinate(row: 0, col: 2)
        let end = GridCoordinate(row: 0, col: 3)
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 1.0

        let decorative = TapNavigationController(cameraNode: camera, scene: scene,
            cells: Set((0...3).map { GridCoordinate(row: 0, col: $0) }), cellSize: 3.2,
            startCell: start, startFacing: .east, endCell: end,
            roomDoors: [doorCell: RoomDoorPlacement(coord: doorCell, direction: .north,
                                                    roomNumber: 202, isDecorative: true)])
        decorative.advance(); await finishMove(decorative, renderer: renderer, time: &time)
        #expect(decorative.currentCell == doorCell)

        let functional = TapNavigationController(cameraNode: camera, scene: scene,
            cells: Set((0...3).map { GridCoordinate(row: 0, col: $0) }), cellSize: 3.2,
            startCell: start, startFacing: .east, endCell: end,
            roomDoors: [doorCell: RoomDoorPlacement(coord: doorCell, direction: .north, roomNumber: 302)])
        time = 1.0
        functional.advance(); await finishMove(functional, renderer: renderer, time: &time)
        #expect(functional.currentCell == doorCell)
    }

    // Sept 24 (room-door knock interaction): the routing decision that
    // ContentView.handleTap delegates to -- a tap on a DECORATIVE door
    // plays the knock ladder (soft -> medium), while a tap on a
    // FUNCTIONAL door keeps the existing mail flow and never knocks. The
    // gesture layer is UI-level; this pins the controller-level routing
    // that sits behind it, plus the one-tap-route-one-sound guarantee by
    // asserting exactly one ladder step per interactWithRoomDoor call.
    @Test func roomDoorTapRoutesDecorativeToKnockAndFunctionalToMailFlow() async {
        let scene = SCNScene()
        let camera = SCNNode(); camera.position.y = 1.6
        scene.rootNode.addChildNode(camera)
        let cells = Set((0...3).map { GridCoordinate(row: 0, col: $0) })
        let decorativeCell = GridCoordinate(row: 0, col: 1)
        let functionalCell = GridCoordinate(row: 0, col: 2)

        // Decorative door: stopped at it, facing it, tap -> knock.
        let decorative = TapNavigationController(cameraNode: camera, scene: scene, cells: cells, cellSize: 3.2,
            startCell: decorativeCell, startFacing: .north, endCell: GridCoordinate(row: 0, col: 3),
            roomDoors: [decorativeCell: RoomDoorPlacement(coord: decorativeCell, direction: .north,
                                                          roomNumber: 201, isDecorative: true)])
        SoundEffects.resetKnockLadder()
        #expect(decorative.canRotate)
        decorative.interactWithRoomDoor(at: decorativeCell)
        #expect(SoundEffects.lastKnockFilename == "knock-soft.mp3")
        // Second tap inside the five-second window escalates to medium.
        decorative.interactWithRoomDoor(at: decorativeCell)
        #expect(SoundEffects.lastKnockFilename == "knock-medium.mp3")
        SoundEffects.resetKnockLadder()

        // Functional door: tap routes to the mail flow, never knocks.
        let functional = TapNavigationController(cameraNode: camera, scene: scene, cells: cells, cellSize: 3.2,
            startCell: functionalCell, startFacing: .north, endCell: GridCoordinate(row: 0, col: 3),
            roomDoors: [functionalCell: RoomDoorPlacement(coord: functionalCell, direction: .north, roomNumber: 302)])
        functional.interactWithRoomDoor(at: functionalCell)
        #expect(SoundEffects.lastKnockFilename == nil)
        #expect(functional.carriedMail.isEmpty)
        SoundEffects.resetKnockLadder()
    }

    // Sept 24: a decorative room's number can never be a mail address.
    // mailableRoomNumbers excludes it, setItemRoom refuses it (so no
    // envelope can be addressed to it), and assignUnassignedRoomItems
    // (which runs behind functional door placement) always follows the
    // mailable pool rather than handing an unaddressed letter to a
    // decorative number.
    @Test func decorativeRoomNumbersAreNeverMailableAddresses() {
        let store = MazeStore()
        store.switchTo(id: 2)
        store.placeRoomDoor(.west, at: GridCoordinate(row: 4, col: 0), decorative: true)   // 201 decorative
        store.placeRoomDoor(.south, at: GridCoordinate(row: 10, col: 8))                   // 202 functional
        #expect(store.mailableRoomNumbers == [202])
        #expect(store.roomNumbers == [201, 202])
        let letter = GridCoordinate(row: 4, col: 3)
        store.placeObject(.envelope, at: letter)
        store.setItemRoom(201, at: letter)
        #expect(store.itemRooms[letter] == nil)      // decorative numbers cannot be addressed
        store.setItemRoom(202, at: letter)
        #expect(store.itemRooms[letter] == 202)
        let unaddressed = GridCoordinate(row: 4, col: 5)
        store.placeObject(.envelope, at: unaddressed)
        store.removeRoomDoor(at: GridCoordinate(row: 10, col: 8))
        store.placeRoomDoor(.north, at: GridCoordinate(row: 0, col: 7))                    // 203 functional (editor path)
        // The unaddressed letter was assigned from the MAILABLE pool -- the
        // new functional 203 -- never the decorative 201. (Two functional
        // doors in the same floor's sequence also prove decorative numbers
        // occupy the numbering list without joining the mail pool.)
        #expect(store.itemRooms[unaddressed] == 203)
        #expect(store.mailableRoomNumbers == [203])
        #expect(store.roomNumbers == [201, 203])
    }

    @Test func mirrorsStopWalkingOnReturnTrips() async {
        let scene = SCNScene()
        let camera = SCNNode(); camera.position.y = 1.6
        scene.rootNode.addChildNode(camera)
        let start = GridCoordinate(row: 0, col: 0)
        let mirror = GridCoordinate(row: 0, col: 2)
        let end = GridCoordinate(row: 0, col: 4)
        let controller = TapNavigationController(cameraNode: camera, scene: scene,
            cells: Set((0...4).map { GridCoordinate(row: 0, col: $0) }), cellSize: 3.2,
            startCell: start, startFacing: .east, endCell: end, mirrors: [mirror: .north])
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 1.0
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == mirror)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == end)
        controller.rotate(toward: .west); await finishMove(controller, renderer: renderer, time: &time)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == mirror)
    }

    @Test func mirrorFacesIntoHallwayOnEveryWall() throws {
        let coord = GridCoordinate(row: 3, col: 4)
        let center = SCNVector3(12.8, 1.6, 9.6)
        for direction in Direction.allCases {
            let mirror = HallwayScene.makeMirrorNode(at: coord, direction: direction, cellSize: 3.2)
            let surface = try #require(mirror.childNode(withName: "mirrorSurface", recursively: true))
            let facing = mirror.convertVector(SCNVector3(0, 0, 1), to: nil)
            let toCenter = SCNVector3(center.x - mirror.position.x, 0, center.z - mirror.position.z)
            #expect(facing.x * toCenter.x + facing.z * toCenter.z > 0)
            #expect(surface.geometry?.firstMaterial?.diffuse.contents is UIImage)
        }
    }

    @Test func heldWalkingTurnsAtBothLCornersButTapsDoNot() async {
        for side in [Direction.east, .west] {
            let start = GridCoordinate(row: 2, col: 2)
            let corner = GridCoordinate(row: 1, col: 2)
            let exit = GridCoordinate(row: 1, col: 2 + side.delta.col)
            let scene = SCNScene(), camera = SCNNode()
            scene.rootNode.addChildNode(camera)
            let controller = TapNavigationController(cameraNode: camera, scene: scene,
                cells: [start, corner, exit], cellSize: 3.2,
                startCell: start, startFacing: .north, endCell: exit)
            let renderer = SCNRenderer(device: nil, options: nil)
            var time = 1.0
            controller.advanceWhileHeld()
            await finishMove(controller, renderer: renderer, time: &time)
            #expect(controller.currentCell == corner)
            controller.advance() // Ordinary taps still cannot turn for you.
            #expect(!controller.isAnimating)
            #expect(controller.facing == .north)
            controller.advanceWhileHeld()
            #expect(controller.isAnimating)
            controller.advanceWhileHeld() // Polling during the pivot queues nothing.
            await finishMove(controller, renderer: renderer, time: &time)
            #expect(controller.facing == side)
            #expect(controller.currentCell == corner)
            // No next tick means release: finishing the pivot does not start walking.
            #expect(!controller.isAnimating)
            controller.advanceWhileHeld()
            await finishMove(controller, renderer: renderer, time: &time)
            #expect(controller.currentCell == exit)
            controller.advanceWhileHeld() // No automatic U-turn at the dead end.
            #expect(!controller.isAnimating)
            #expect(controller.facing == side)
        }
    }

    @Test func heldWalkingWaitsAtBlockedTJunction() async {
        let start = GridCoordinate(row: 2, col: 2)
        let junction = GridCoordinate(row: 1, col: 2)
        let scene = SCNScene(), camera = SCNNode()
        scene.rootNode.addChildNode(camera)
        let controller = TapNavigationController(cameraNode: camera, scene: scene,
            cells: [start, junction, GridCoordinate(row: 1, col: 1), GridCoordinate(row: 1, col: 3)],
            cellSize: 3.2, startCell: start, startFacing: .north,
            endCell: GridCoordinate(row: 1, col: 3))
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 1.0
        controller.advanceWhileHeld()
        await finishMove(controller, renderer: renderer, time: &time)
        for _ in 0..<3 { controller.advanceWhileHeld() }
        #expect(controller.currentCell == junction)
        #expect(controller.facing == .north)
        #expect(!controller.isAnimating)
    }

    // Sept 24 (held-walk bypass): a continuously held walk must traverse an
    // overridable stop cell (tap-to-collect object, picture, wall map)
    // exactly like an empty cell -- one unbroken glide, no mid-run
    // segment split or present-once back-off -- while a tap still stops at
    // every one of them.
    @Test func heldWalkGlidesThroughOverridableStopsButTapsStillStop() async {
        let cells = Set((0...5).map { GridCoordinate(row: $0, col: 2) })
        let start = GridCoordinate(row: 5, col: 2)
        let end = GridCoordinate(row: 0, col: 2)
        let object = GridCoordinate(row: 4, col: 2)
        let picture = GridCoordinate(row: 3, col: 2)
        let map = GridCoordinate(row: 2, col: 2)

        let scene = SCNScene(), camera = SCNNode()
        scene.rootNode.addChildNode(camera)
        let controller = TapNavigationController(cameraNode: camera, scene: scene,
            cells: cells, cellSize: 3.2, startCell: start, startFacing: .north, endCell: end,
            objects: [object: .heart],
            pictures: [WallFace(coord: picture, direction: .east)],
            floorMaps: [map: .north])
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 1.0

        // Held: one glide straight to the end cell. The object/picture/map
        // cells must not split the segment, so a single advance() + finish
        // lands on the far end with nothing picked up.
        controller.setWalkingHeld(true)
        controller.advance()
        #expect(controller.isAnimating)
        await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == end)
        #expect(!controller.isAnimating)
        #expect(controller.collectedCoords.isEmpty)

        // Tap: first tap presents the object (back off, no movement), the
        // second lands ON its cell -- the object stop is intact.
        controller.setWalkingHeld(false)
        controller.reset()
        time = 1.0
        controller.advance()
        #expect(!controller.isAnimating)
        #expect(controller.currentCell == start)
        controller.advance()
        await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == object)
    }

    @Test func longPressFromWallChoosesOnlyUnambiguousSide() async {
        for sides in [[Direction.east], [.west], [.east, .west]] {
            let start = GridCoordinate(row: 1, col: 1)
            let neighbors = sides.map { GridCoordinate(row: 1, col: 1 + $0.delta.col) }
            let scene = SCNScene(), camera = SCNNode()
            scene.rootNode.addChildNode(camera)
            let controller = TapNavigationController(cameraNode: camera, scene: scene,
                cells: Set([start] + neighbors), cellSize: 3.2,
                startCell: start, startFacing: .north, endCell: neighbors[0])
            let renderer = SCNRenderer(device: nil, options: nil)
            var time = 1.0
            controller.advanceWhileHeld()
            if sides.count == 2 {
                for _ in 0..<3 { controller.advanceWhileHeld() }
                #expect(!controller.isAnimating)
                #expect(controller.currentCell == start)
                #expect(controller.facing == .north)
                // A swipe-selected direction unlocks continuation.
                controller.rotate(toward: .east)
            }
            await finishMove(controller, renderer: renderer, time: &time)
            #expect(controller.facing == sides[0])
            #expect(controller.currentCell == start)
            controller.advanceWhileHeld()
            await finishMove(controller, renderer: renderer, time: &time)
            #expect(controller.currentCell == neighbors[0])
        }
    }

    @Test func paintBucketPaintsEveryArrivalThenResetRestoresProgress() async {
        let start = GridCoordinate(row: 0, col: 0)
        let bucket = GridCoordinate(row: 0, col: 1)
        let far = GridCoordinate(row: 0, col: 2)
        let cells: Set = [start, bucket, far]
        let built = HallwayScene.build(fromMaze: cells, cellSize: 3.2, wallHeight: 3,
                                       objects: [bucket: .paintBucket],
                                       missionObjectKind: .paintBucket,
                                       playerStart: start, playerEnd: start)
        let left = SCNNode(), right = SCNNode()
        built.scene.rootNode.addChildNode(left)
        built.scene.rootNode.addChildNode(right)
        let controller = TapNavigationController(
            cameraNode: built.cameraNode, scene: built.scene, cells: cells, cellSize: 3.2,
            startCell: start, startFacing: .west, endCell: start,
            objects: [bucket: .paintBucket], objectNodes: built.objectNodes,
            elevatorLeftDoor: left, elevatorRightDoor: right, elevatorMountDirection: .west,
            missionObjectKind: .paintBucket)
        let renderer = SCNRenderer(device: nil, options: nil)
        var time = 1.0
        controller.pinchForward()
        #expect(controller.elevatorRejected != nil)
        #expect(controller.paintedCells.isEmpty)
        controller.rotate(toward: .east); await finishMove(controller, renderer: renderer, time: &time)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.hasPaintBucket)
        #expect(controller.paintedCells == [bucket])
        #expect(!controller.isMissionComplete)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.paintedCells == [bucket, far])
        controller.rotate(toward: .west); await finishMove(controller, renderer: renderer, time: &time)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.currentCell == start)
        #expect(controller.paintedCells == cells)
        #expect(controller.isMissionComplete)
        controller.reset()
        #expect(!controller.hasPaintBucket)
        #expect(controller.paintedCells.isEmpty)
        #expect(!controller.isMissionComplete)
        controller.rotate(toward: .east); await finishMove(controller, renderer: renderer, time: &time)
        controller.advance(); await finishMove(controller, renderer: renderer, time: &time)
        #expect(controller.hasPaintBucket)
        #expect(controller.paintedCells == [bucket])
    }

}
