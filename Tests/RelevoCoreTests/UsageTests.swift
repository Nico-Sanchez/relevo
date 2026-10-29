import Foundation
import Testing
@testable import RelevoCore

@Suite struct SafeStorageTests {
    @Test func derivesTheSameKeyAsChromium() {
        let hex = { (data: Data) in data.map { String(format: "%02x", $0) }.joined() }

        #expect(hex(SafeStorage.deriveKey(password: Data("peanuts".utf8), iterations: 1)) == "fd621fe5a2b402539dfa147ca9272778")
        #expect(hex(SafeStorage.deriveKey(password: Data("secret".utf8), iterations: 1003)) == "1a7404704ee35b4506624ed49171a534")
    }

    @Test func decryptsWhatItEncrypts() throws {
        let key = SafeStorage.deriveKey(password: Data("secret".utf8), iterations: 1003)
        let encrypted = try SafeStorage.encrypt(Data("sk-ant-sid01-example".utf8), key: key)

        #expect(encrypted.starts(with: Data("v10".utf8)))
        #expect(try SafeStorage.decrypt(encrypted, key: key) == Data("sk-ant-sid01-example".utf8))
        #expect(throws: UsageError.unreadable) { try SafeStorage.decrypt(Data("v11whatever".utf8), key: key) }
    }

    @Test func readsTheSessionKeyOfTheCurrentAndSavedAccounts() throws {
        let fixture = try Fixture()
        let key = SafeStorage.deriveKey(password: Data("secret".utf8), iterations: 1003)
        try fixture.signIn(accountA, session: "A")
        try fixture.writeCookies(session: "sk-account-a", encryptedWith: key)
        let store = fixture.store()
        try store.switchToNewAccount(named: "C")
        try fixture.signIn(accountC, session: "C")
        try fixture.writeCookies(session: "sk-account-c", encryptedWith: key)

        #expect(try store.sessionKey(for: accountC, decryptingWith: key) == "sk-account-c")
        #expect(try store.sessionKey(for: accountA, decryptingWith: key) == "sk-account-a")
        #expect(throws: UsageError.noSession) { try store.sessionKey(for: accountB, decryptingWith: key) }
    }

    @Test func aWrongKeyCannotReadTheSessionKey() throws {
        let fixture = try Fixture()
        try fixture.signIn(accountA, session: "A")
        try fixture.writeCookies(session: "sk-account-a", encryptedWith: SafeStorage.deriveKey(password: Data("secret".utf8), iterations: 1003))
        let wrongKey = SafeStorage.deriveKey(password: Data("other".utf8), iterations: 1003)

        #expect(throws: UsageError.self) { try fixture.store().sessionKey(for: accountA, decryptingWith: wrongKey) }
    }
}

let usageResponse = Data("""
    {
      "five_hour": {"utilization": 23.0, "resets_at": "2026-10-29T03:00:00.512345+00:00"},
      "seven_day": {"utilization": 61.5, "resets_at": "2026-11-01T12:00:00+00:00"},
      "seven_day_opus": null,
      "seven_day_sonnet": {"utilization": 12, "resets_at": null},
      "extra_usage": {"is_enabled": false}
    }
    """.utf8)

@Suite struct UsageParsingTests {
    @Test func readsEveryWindowWithItsReset() throws {
        let usage = try UsageClient.parse(usageResponse, fetchedAt: .distantPast)

        #expect(usage.windows.map(\.id) == ["five_hour", "seven_day", "seven_day_sonnet"])
        #expect(usage.window("five_hour")?.utilization == 23)
        #expect(usage.window("seven_day")?.utilization == 61.5)
        #expect(usage.window("five_hour")?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-29T03:00:00Z"))
        #expect(usage.window("seven_day_sonnet")?.resetsAt == nil)
    }

    @Test func rejectsAnswersWithoutUsage() {
        #expect(throws: UsageError.unreadable) { try UsageClient.parse(Data("[]".utf8), fetchedAt: .now) }
        #expect(throws: UsageError.unreadable) { try UsageClient.parse(Data(#"{"extra_usage": {}}"#.utf8), fetchedAt: .now) }
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: usageResponse)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct UsageClientTests {
    let client: UsageClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return UsageClient(session: URLSession(configuration: configuration))
    }()

    @Test func asksClaudeForTheOrganizationsUsageWithOnlyTheSessionKey() async throws {
        StubProtocol.status = 200

        let usage = try await client.usage(at: location(accountA, orgA), sessionKey: "sk-test")

        let request = try #require(StubProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://claude.ai/api/organizations/\(orgA)/usage")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "sessionKey=sk-test")
        #expect(usage.window("seven_day")?.utilization == 61.5)
    }

    @Test func reportsTheStatusOfARejectedRequest() async {
        StubProtocol.status = 403

        await #expect(throws: UsageError.http(403)) {
            try await client.usage(at: location(accountA, orgA), sessionKey: "sk-test")
        }
    }
}
