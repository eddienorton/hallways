import Testing
@testable import Hallways

@MainActor
struct PhotoSamplingTests {
    @Test func entireUniverseIsEligibleWithoutDuplicates() {
        let indices = PhotoRollProvider.sampleIndices(total: 2000, count: 2000)
        #expect(Set(indices) == Set(0..<2000))
        #expect(indices.count == 2000)
    }
    @Test func recentChoicesAreDeferredWithoutRestrictingTheUniverse() {
        let recent = Set(0..<20)
        let indices = PhotoRollProvider.sampleIndices(total: 100, count: 100, avoiding: recent)
        #expect(Set(indices.prefix(80)).isDisjoint(with: recent))
        #expect(Set(indices) == Set(0..<100))
    }
    @Test func smallLibrariesRepeatOnlyAfterExhaustionAndEmptyIsSafe() {
        let indices = PhotoRollProvider.sampleIndices(total: 3, count: 8)
        #expect(indices.count == 8)
        #expect(Set(indices.prefix(3)).count == 3)
        #expect(PhotoRollProvider.sampleIndices(total: 0, count: 5).isEmpty)
        #expect(PhotoRollProvider.sampleIndices(total: 3, count: 0).isEmpty)
    }
}
