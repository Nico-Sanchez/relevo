import CommonCrypto
import Foundation
import Security

public enum SafeStorage {
    public static func key() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecAttrAccount as String: "Claude",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let password = item as? Data else {
            throw UsageError.keychainDenied
        }
        return deriveKey(password: password, iterations: 1003)
    }

    static func deriveKey(password: Data, iterations: UInt32) -> Data {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    _ = CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), iterations,
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128
                    )
                }
            }
        }
        return key
    }

    static func decrypt(_ value: Data, key: Data) throws -> Data {
        try crypt(value, key: key, operation: CCOperation(kCCDecrypt), prefix: "v10")
    }

    static func encrypt(_ value: Data, key: Data) throws -> Data {
        try Data("v10".utf8) + crypt(value, key: key, operation: CCOperation(kCCEncrypt), prefix: nil)
    }

    private static func crypt(_ value: Data, key: Data, operation: CCOperation, prefix: String?) throws -> Data {
        var input = value
        if let prefix {
            guard value.starts(with: Data(prefix.utf8)) else { throw UsageError.unreadable }
            input = value.dropFirst(prefix.utf8.count)
        }
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var length = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inputBytes.baseAddress, input.count,
                            outputBytes.baseAddress, capacity, &length
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw UsageError.unreadable }
        return output.prefix(length)
    }
}

public struct UsageClient: Sendable {
    let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func usage(at location: Location, sessionKey: String) async throws -> Usage {
        var request = URLRequest(url: URL(string: "https://claude.ai/api/organizations/\(location.org)/usage")!)
        request.httpShouldHandleCookies = false
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UsageError.http(status) }
        return try Self.parse(data, fetchedAt: .now)
    }

    static func parse(_ data: Data, fetchedAt: Date) throws -> Usage {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw UsageError.unreadable }
        let windows = object.compactMap { id, value -> UsageWindow? in
            guard let window = value as? [String: Any],
                  let utilization = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(id: id, utilization: utilization, resetsAt: (window["resets_at"] as? String).flatMap(date))
        }
        guard !windows.isEmpty else { throw UsageError.unreadable }
        return Usage(windows: windows.sorted { (rank($0.id), $0.id) < (rank($1.id), $1.id) }, fetchedAt: fetchedAt)
    }

    private static func rank(_ id: String) -> Int {
        switch id {
        case "five_hour": 0
        case "seven_day": 1
        default: 2
        }
    }

    private static func date(_ text: String) -> Date? {
        let withoutFraction = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: withoutFraction)
    }
}

public struct UsageSource: Sendable {
    public let prepare: @Sendable () async throws -> Void
    public let fetch: @Sendable (Account) async throws -> Usage

    public init(
        prepare: @escaping @Sendable () async throws -> Void,
        fetch: @escaping @Sendable (Account) async throws -> Usage
    ) {
        self.prepare = prepare
        self.fetch = fetch
    }

    public static func claudeAI(store: AccountStore, client: UsageClient = UsageClient()) -> UsageSource {
        let key = KeyCache()
        return UsageSource(
            prepare: { _ = try await key.value() },
            fetch: { account in
                guard let location = account.location else { throw UsageError.noSession }
                let sessionKey = try store.sessionKey(for: account.id, decryptingWith: try await key.value())
                return try await client.usage(at: location, sessionKey: sessionKey)
            }
        )
    }
}

actor KeyCache {
    private var key: Data?

    func value() throws -> Data {
        if let key {
            return key
        }
        let derived = try SafeStorage.key()
        key = derived
        return derived
    }
}
