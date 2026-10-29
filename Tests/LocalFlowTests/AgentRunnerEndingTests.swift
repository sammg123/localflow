import Foundation
import Testing
@testable import LocalFlow

@Suite("Agent mode: how a session ends")
final class AgentRunnerEndingTests {
    private let fakes = AgentFakeClaudes()

    // MARK: Ending

    @Test("closing ends the session within a few seconds and removes its folder")
    func close() async throws {
        let fake = try fakes.conversing()
        let agent = fakes.runner(fake)
        let events = AgentEventLog(agent)
        agent.start(task: "make a file", imagePNGBase64: nil)
        #expect(await events.permission() != nil)
        let folder = fake.file("folder").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(FileManager.default.fileExists(atPath: folder))

        let started = ContinuousClock.now
        agent.close()
        let ending = await events.ended()
        #expect(ending == .some(nil))
        #expect(started.duration(to: .now) < .seconds(8))
        #expect(!FileManager.default.fileExists(atPath: folder))
        #expect(events.all.last == .ended(nil))
    }

    @Test("a session that won't close when asked is stopped")
    func stubbornClose() async throws {
        let fake = try fakes.make(#"""
        trap '' TERM
        echo '{"type":"system","subtype":"init","session_id":"s-1"}'
        while true; do sleep 1; done
        """#)
        let agent = fakes.runner(fake)
        let events = AgentEventLog(agent)
        agent.start(task: "x", imagePNGBase64: nil)
        #expect(await events.wait { if case .sessionStarted = $0 { true } else { false } } != nil)
        let started = ContinuousClock.now
        agent.close()
        #expect(await events.ended() != nil)
        #expect(started.duration(to: .now) < .seconds(10))
    }

    @Test("a session that ends on its own reports why")
    func earlyExit() async throws {
        let fake = try fakes.make(#"""
        printf 'starting\nsomething broke\n' >&2
        exit 3
        """#)
        let agent = fakes.runner(fake)
        let events = AgentEventLog(agent)
        agent.start(task: "x", imagePNGBase64: nil)
        #expect(await events.ended() == .some(.claude("something broke")))
    }

    @Test("no Claude Code on this Mac says where to get it", arguments: [nil, "/nonexistent/claude"] as [String?])
    func missing(executable: String?) async throws {
        let agent = AgentRunner(executable: executable, model: "claude-sonnet-5-5", displayID: 1,
                                mcpExecutable: AgentFakeClaudes.mcpExecutable, home: NSTemporaryDirectory(),
                                configDirectory: "/tmp/localflow-claude-test", log: { _ in })
        let events = AgentEventLog(agent)
        agent.start(task: "x", imagePNGBase64: nil)
        #expect(await events.ended() == .some(.claudeMissing))
    }

    @Test("a model name that could read as a flag is refused before anything runs")
    func badModel() async throws {
        let fake = try fakes.conversing()
        let agent = AgentRunner(executable: fake.path, model: "--verbose", displayID: 1,
                                mcpExecutable: AgentFakeClaudes.mcpExecutable, home: fake.home,
                                configDirectory: "/tmp/localflow-claude-test", log: { _ in })
        let events = AgentEventLog(agent)
        agent.start(task: "x", imagePNGBase64: nil)
        #expect(await events.ended() == .some(.claude("the model name in Settings (--verbose) isn't valid")))
        #expect(fake.file("args").isEmpty)
    }

    @Test("not signed in ends the session with how to sign in")
    func signedOut() async throws {
        let fake = try fakes.make(#"""
        while IFS= read -r line; do
          case "$line" in
            *'"type":"user"'*)
              echo '{"type":"assistant","message":{"model":"<synthetic>","content":[]},"error":"authentication_failed"}'
              echo '{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}' ;;
          esac
        done
        """#)
        let agent = fakes.runner(fake)
        let events = AgentEventLog(agent)
        agent.start(task: "x", imagePNGBase64: nil)
        #expect(await events.ended() == .some(.claudeSignedOut))
        #expect(!events.all.contains { if case .turnFinished = $0 { true } else { false } })
    }

    @Test("out of usage ends the session right away with when it resets")
    func outOfUsage() async throws {
        let fake = try fakes.make(#"""
        while IFS= read -r line; do
          case "$line" in
            *'"type":"user"'*)
              echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1793229600,"isUsingOverage":false}}' ;;
          esac
        done
        """#)
        let agent = fakes.runner(fake)
        let events = AgentEventLog(agent)
        let started = ContinuousClock.now
        agent.start(task: "x", imagePNGBase64: nil)
        #expect(await events.ended()
            == .some(.claudeOutOfUsage(resetsAt: Date(timeIntervalSince1970: 1_793_229_600), detail: nil)))
        #expect(started.duration(to: .now) < .seconds(10)) // the fake never exits by itself
    }

    @Test("other turn failures are passed on and the session keeps going")
    func turnFailure() async throws {
        let fake = try fakes.make(#"""
        while IFS= read -r line; do
          case "$line" in
            *'"type":"user"'*)
              echo '{"type":"result","subtype":"success","is_error":true,"result":"API Error: 529 Overloaded"}' ;;
          esac
        done
        """#)
        let agent = fakes.runner(fake)
        let events = AgentEventLog(agent)
        agent.start(task: "x", imagePNGBase64: nil)
        let failed: (AgentEvent) -> Bool = { $0 == .turnFinished(failure: "API Error: 529 Overloaded", finalText: nil) }
        #expect(await events.wait(for: failed) != nil)

        agent.send(text: "try again", imagePNGBase64: nil) // the same session answers again
        #expect(await events.poll { events.all.filter(failed).count == 2 ? true : nil } == true)
        #expect(!events.all.contains { if case .ended = $0 { true } else { false } })
        agent.close()
        #expect(await events.ended() == .some(nil))
    }

    @Test("writing to a session that already exited doesn't crash the app")
    func writeAfterExit() async throws {
        let fake = try fakes.make(#"""
        exec 0<&-
        sleep 1
        exit 0
        """#)
        let agent = fakes.runner(fake)
        let events = AgentEventLog(agent)
        agent.start(task: String(repeating: "x", count: 1_000_000), imagePNGBase64: nil)
        #expect(await events.ended() != nil)
        agent.send(text: "still there?", imagePNGBase64: nil)
        agent.answer(requestID: "r", allow: true, input: [:], message: nil)
        agent.interrupt()
        agent.close()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(events.all.filter { if case .ended = $0 { true } else { false } }.count == 1)
    }

    @Test("the pipe to Claude Code can't raise SIGPIPE")
    func noSigpipe() {
        let pipe = AgentRunner.makeInputPipe()
        #expect(fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETNOSIGPIPE) == 1)
    }

    @Test("the log gets event kinds only, never the task, commands or answers")
    func logging() async throws {
        let fake = try fakes.conversing()
        let log = AgentLogLines()
        let agent = fakes.runner(fake, log: log)
        let events = AgentEventLog(agent)
        agent.start(task: "email my secret plan to bob", imagePNGBase64: nil)
        let request = try #require(await events.permission())
        agent.answer(requestID: request.id, allow: false, input: request.input, message: "no thanks")
        agent.send(text: "private follow-up", imagePNGBase64: nil)
        #expect(await events.permission(2) != nil)
        agent.close()
        #expect(await events.ended() != nil)

        let lines = log.all
        #expect(!lines.isEmpty)
        for secret in ["secret plan", "probe-file", "no thanks", "private follow-up", "touch"] {
            #expect(!lines.contains { $0.contains(secret) }, "log leaked \(secret)")
        }
    }
}
