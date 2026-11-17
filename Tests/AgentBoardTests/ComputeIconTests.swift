@testable import AgentBoard
import Testing

@Test func aComputerWithRoomToSpareShowsACleanPicture() {
    #expect(ComputeIcon.noise(strain: 0) == 0)
    #expect(ComputeIcon.noise(strain: 0.5) == 0)
    #expect(ComputeIcon.noise(strain: 0.75) == 0.5)
    #expect(ComputeIcon.noise(strain: 1.4) == 1)
}

@Test func aHostsPlatformSaysWhichHomeScreenItShows() {
    #expect(HostSystem(platform: "linux-x86_64") == .linux)
    #expect(HostSystem(platform: "windows-x86_64") == .windows)
    #expect(HostSystem(platform: "macos-aarch64") == .mac)
}
