import Foundation
import MeroKit
import MeroKitUI
@testable import MeroTag

/// Records every call and answers reads from a canned table — the relay,
/// without a network.
final class FakeTransport: ContextTransport, @unchecked Sendable {
    struct Call: Equatable {
        let kind: String
        let contextId: String
        let method: String
        let args: JSONValue
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var responses: [String: JSONValue] = [:]
    var failures: [String: Error] = [:]
    var frames: AsyncThrowingStream<JSONValue, Error>?

    var calls: [Call] { lock.withLock { _calls } }
    var writes: [Call] { calls.filter { $0.kind == "execute" } }

    func query(contextId: String, method: String, args: JSONValue) async throws -> JSONValue? {
        try record("query", contextId, method, args)
    }

    func execute(contextId: String, method: String, args: JSONValue) async throws -> JSONValue? {
        try record("execute", contextId, method, args)
    }

    func events(contextId: String) -> AsyncThrowingStream<JSONValue, Error>? { frames }

    private func record(_ kind: String, _ ctx: String, _ method: String, _ args: JSONValue) throws -> JSONValue? {
        lock.withLock { _calls.append(Call(kind: kind, contextId: ctx, method: method, args: args)) }
        if let error = failures[method] { throw error }
        return responses[method]
    }
}

/// Never opens a browser.
struct NoWallet: WebAuthenticating {
    func authenticate(url: URL, callback: CloudCallback) async throws -> URL {
        throw WebAuthenticationCancelled()
    }
}

@MainActor
func makeClient() -> MeroClient {
    MeroClient(
        cloud: CloudSignIn(keyStore: .memory(), sessionStore: .memory(), nonces: MemoryWarrantNonceStore()),
        webAuthenticator: NoWallet())
}

func isolatedDefaults() -> UserDefaults {
    let name = "merotag.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

enum Fixtures {
    static let account = String(repeating: "ab", count: 32)
    static let context = "ctx-1"

    static let trackers: JSONValue = [
        [
            "id": "t2", "name": "Bike", "ownerId": .string(account), "viewers": [],
            "latest": nil, "createdAt": 1, "updatedAt": 1,
        ],
        [
            "id": "t1", "name": "Alpha", "ownerId": "someone", "viewers": [.string(account)],
            "latest": [
                "latitude": 45.8, "longitude": 15.97, "altitude": 120, "speed": 1.5, "heading": 90,
                "battery": 76, "timestamp": 1_700_000_000_000,
            ],
            "createdAt": 1, "updatedAt": 2,
        ],
    ]
    static let space: JSONValue = ["name": "Family", "trackerCount": 2, "memberCount": 1, "groupCount": 0]
    static let members: JSONValue = [["id": "someone", "username": "Ana", "joinedAt": 1]]
    static let presence: JSONValue = [["userId": "someone", "online": true, "lastSeen": 5]]

    static func transport() -> FakeTransport {
        let t = FakeTransport()
        t.responses = [
            "get_trackers": trackers, "get_space": space, "get_members": members, "get_presence": presence,
        ]
        return t
    }
}
