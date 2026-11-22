import Foundation
import Testing
@testable import Orchestration

struct InProcessCoreSocketTests {
    /// A relay is pointed at the board's core by `AGENTBOARD_CORE_SOCKET`; the in-process core
    /// (a build without the core binary) must listen there too, and keep its own socket otherwise.
    @Test func theInProcessCoreHonorsTheSocketVariable() {
        #expect(InProcessCore.socketPath(["AGENTBOARD_CORE_SOCKET": "/tmp/x.sock"]) == "/tmp/x.sock")
        let own = InProcessCore.socketPath([:])
        #expect(own.hasSuffix("agentboard-local-\(getpid()).sock"))
        #expect(InProcessCore.socketPath(["AGENTBOARD_CORE_SOCKET": ""]) == own)
    }
}
