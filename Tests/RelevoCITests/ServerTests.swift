import Foundation
import Testing
@testable import RelevoCI

@Suite struct ServerTests {
    func makeServer(_ source: FakeSource, outbox: Outbox, started: Counter = Counter()) -> Server {
        Server(source: source, send: { outbox.append($0) }, startWatching: { _ in started.increment() })
    }

    @Test func negotiatesAProtocolThatStillAllowsPushedNotifications() throws {
        let outbox = Outbox()
        let server = makeServer(FakeSource(nil), outbox: outbox)

        server.receive(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#)
        server.receive(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2026-07-28"}}"#)

        let first = try #require(outbox.reply(to: 1)?["result"] as? [String: Any])
        let second = try #require(outbox.reply(to: 2)?["result"] as? [String: Any])
        #expect(first["protocolVersion"] as? String == "2025-11-25")
        #expect(second["protocolVersion"] as? String == "2025-06-18")
        let capabilities = try #require(first["capabilities"] as? [String: Any])
        #expect((capabilities["experimental"] as? [String: Any])?["claude/channel"] != nil)
    }

    @Test func rejectsUnknownMethodsSoClientsFallBack() throws {
        let outbox = Outbox()
        makeServer(FakeSource(nil), outbox: outbox).receive(#"{"jsonrpc":"2.0","id":"probe","method":"server/discover"}"#)

        let error = try #require(outbox.messages.first?["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601)
    }

    @Test func listsItsTools() throws {
        let outbox = Outbox()
        makeServer(FakeSource(nil), outbox: outbox).receive(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)

        let tools = try #require((outbox.reply(to: 3)?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["pr_context", "pr_watch"])
    }

    @Test func startsWatchingOnceAfterInitialization() {
        let started = Counter()
        let server = makeServer(FakeSource(nil), outbox: Outbox(), started: started)

        server.receive(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        server.receive(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

        #expect(started.value == 1)
    }

    @Test func pushesAChannelNotificationWhenCIFails() throws {
        let outbox = Outbox()
        let source = FakeSource(makePullRequest(checks: [pendingE2E]), logs: ["test": "boom"])
        let server = makeServer(source, outbox: outbox)

        server.poll()
        source.set(makePullRequest(checks: [failingTest]))
        server.poll()
        server.poll()

        #expect(outbox.notifications.count == 1)
        let params = try #require(outbox.notifications.first?["params"] as? [String: Any])
        #expect((params["content"] as? String)?.contains("boom") == true)
        #expect((params["meta"] as? [String: String])?["kind"] == "ci_failure")
        #expect(source.viewerCalls == 1)
    }

    @Test func pausingStopsTheNotificationsUntilResumed() {
        let outbox = Outbox()
        let source = FakeSource(makePullRequest(checks: [failingTest]))
        let server = makeServer(source, outbox: outbox)

        server.receive(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"pr_watch","arguments":{"enabled":false}}}"#)
        server.poll()
        #expect(outbox.notifications.isEmpty)

        server.receive(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"pr_watch","arguments":{"enabled":true}}}"#)
        server.poll()
        #expect(outbox.notifications.count == 1)
    }

    @Test func prContextDescribesThePullRequest() throws {
        let outbox = Outbox()
        let server = makeServer(FakeSource(makePullRequest(checks: [failingTest]), logs: ["test": "boom"]), outbox: outbox)

        server.receive(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"pr_context","arguments":{"include_logs":true}}}"#)

        let result = try #require(outbox.reply(to: 6)?["result"] as? [String: Any])
        let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(text.contains("- test: failed"))
        #expect(text.contains("boom"))
        #expect(text.hasSuffix("Messages are on."))
    }

    @Test func prContextSaysWhenThereIsNoPullRequest() throws {
        let outbox = Outbox()
        makeServer(FakeSource(nil), outbox: outbox)
            .receive(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"pr_context","arguments":{}}}"#)

        let result = try #require(outbox.reply(to: 7)?["result"] as? [String: Any])
        #expect((result["content"] as? [[String: Any]])?.first?["text"] as? String == "The current branch has no pull request.")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int { lock.withLock { count } }
}
