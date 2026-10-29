import Foundation
import Testing
@testable import LocalFlow

@Suite("Agent screen server: only LocalFlow can start it")
struct ComputerLaunchGuardTests {
    let own = "/Users/x/Applications/LocalFlow.app/Contents/MacOS/LocalFlow"

    @Test("started by Claude Code that LocalFlow started: allowed")
    func hostChain() {
        #expect(ComputerLaunchGuard.isStartedByHost(ancestors: ["/Users/x/.local/bin/claude", own], own: own))
    }

    @Test("through a shell wrapper Claude Code uses: still allowed, within reach")
    func wrapped() {
        #expect(ComputerLaunchGuard.isStartedByHost(ancestors: ["/bin/sh", "/usr/local/bin/node", "/bin/zsh", own],
                                                     own: own))
    }

    @Test("opened on its own (launchd), or by another program: refused")
    func refused() {
        #expect(!ComputerLaunchGuard.isStartedByHost(ancestors: ["/sbin/launchd"], own: own))
        #expect(!ComputerLaunchGuard.isStartedByHost(ancestors: ["/Users/x/.local/bin/claude", "/bin/zsh",
                                                                  "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
                                                                  "/sbin/launchd"], own: own))
        #expect(!ComputerLaunchGuard.isStartedByHost(ancestors: [], own: own))
    }

    @Test("a LocalFlow too far up the chain doesn't count")
    func tooFar() {
        let chain = ["/a", "/b", "/c", "/d", own]
        #expect(!ComputerLaunchGuard.isStartedByHost(ancestors: chain, own: own))
    }

    @Test("this test process's own ancestors are found, ending at launchd")
    func liveChain() {
        let chain = ComputerLaunchGuard.ancestorPaths(of: getpid(), limit: 20)
        #expect(!chain.isEmpty)
        #expect(chain.count <= 20)
    }
}
