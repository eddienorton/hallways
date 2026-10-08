import Testing
@testable import Hallways

/// Oct 8 (Developer/Release separation). Tests run against the Debug
/// configuration, so these pin the workshop side; the Release side is
/// the same flag compiled false, verified on a TestFlight build.
@MainActor
struct BuildModeTests {
    @Test func debugBuildsExposeDeveloperTools() {
        #if DEBUG
        #expect(BuildMode.developerTools)
        #else
        #expect(!BuildMode.developerTools)
        #endif
    }

    @Test func decoratorCanOnlyEnableWhenDeveloperToolsAreAvailable() {
        let state = DecoratorState()
        state.enabled = true
        #expect(state.enabled == BuildMode.developerTools)
        state.enabled = false
        #expect(!state.enabled)
    }
}
