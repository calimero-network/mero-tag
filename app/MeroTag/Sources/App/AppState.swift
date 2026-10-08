import Combine
import Foundation
import MeroKit
import MeroKitUI

/// The space this device last opened, remembered across launches.
public struct SpaceSelection: Codable, Equatable {
    public var contextId: String
    public var displayName: String
}

/// Persists the last ``SpaceSelection`` and the tracker this device shares as.
public struct SpacePreferences {
    private let defaults: UserDefaults
    private let key = "merotag.space"
    private let sharingKey = "merotag.sharingTracker"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var space: SpaceSelection? {
        get { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SpaceSelection.self, from: $0) } }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    public var sharingTrackerId: String? {
        get { defaults.string(forKey: sharingKey) }
        nonmutating set { defaults.set(newValue, forKey: sharingKey) }
    }
}

/// Session-level state. Sign-in is Calimero Cloud only: the wallet approves
/// this device with the person's passkey, and every call then goes through
/// the hosted relay that serves their account — writes as warrant intents,
/// reads as queries, events over the relay's Bearer session.
@MainActor
public final class AppState: ObservableObject {
    public enum Phase: Equatable {
        /// Restoring a previous session at launch.
        case launching
        case signedOut
        /// Signed in; no space open yet.
        case choosingSpace
        case ready
    }

    /// The URL scheme the wallet returns to (`merotag://enrol`). Registered
    /// under `CFBundleURLTypes` in project.yml / Info.plist.
    public static let callbackScheme = "merotag"

    @Published public private(set) var phase: Phase = .launching
    /// Why the last session ended, when the user did not end it.
    @Published public var sessionNotice: String?
    @Published public private(set) var spaceError: String?
    @Published public private(set) var isOpeningSpace = false
    @Published public private(set) var store: TrackerStore?
    @Published public private(set) var space: SpaceSelection?

    public let client: MeroClient
    public let preferences: SpacePreferences
    private let makeTransport: (CloudConnection) -> (any ContextTransport)?
    private var forward: AnyCancellable?

    public init(
        client: MeroClient? = nil,
        preferences: SpacePreferences = SpacePreferences(),
        makeTransport: @escaping (CloudConnection) -> (any ContextTransport)? = { RelayTransport($0) }
    ) {
        self.client = client ?? MeroClient()
        self.preferences = preferences
        self.makeTransport = makeTransport
        self.space = preferences.space
        // Views observe AppState only; re-publish the client's changes.
        forward = self.client.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: Account

    /// The signed-in account (64 hex), or `nil`.
    public var account: String? { client.account }

    /// Reconnect a session from a previous launch.
    public func restore() async {
        guard phase == .launching else { return }
        if await client.restoreCloudSession(), client.isAuthenticated {
            await didSignIn()
        } else {
            phase = .signedOut
        }
    }

    /// "Continue with Calimero": the wallet in the system auth sheet.
    public func signIn() async {
        sessionNotice = nil
        await client.signInWithCloud(callbackScheme: Self.callbackScheme)
        if client.isAuthenticated { await didSignIn() }
    }

    /// A callback delivered to the app itself (`onOpenURL`) rather than to the
    /// auth sheet.
    public func handleOpenURL(_ url: URL) async {
        guard url.scheme == Self.callbackScheme else { return }
        if await client.handleEnrolmentCallback(url), client.isAuthenticated {
            await didSignIn()
        }
    }

    private func didSignIn() async {
        if let saved = preferences.space {
            await openSpace(contextId: saved.contextId, displayName: saved.displayName)
            if phase != .ready { phase = .choosingSpace }
        } else {
            phase = .choosingSpace
        }
    }

    // MARK: Space

    /// Open `contextId` as the signed-in account and join it under `displayName`.
    public func openSpace(contextId rawId: String, displayName rawName: String) async {
        let contextId = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        spaceError = nil
        guard !contextId.isEmpty else { spaceError = "Enter the space ID you were given."; return }
        guard !displayName.isEmpty else { spaceError = "Choose a name others will see."; return }
        guard let account = client.account, let connection = client.connection else {
            phase = .signedOut
            return
        }
        guard let transport = makeTransport(connection) else {
            spaceError = "No relay serves your account yet. Accept an invitation to a space from its owner to get one."
            return
        }

        isOpeningSpace = true
        defer { isOpeningSpace = false }

        let service = MeroService(transport: transport, contextId: contextId, memberId: account)
        // Reaching the space before switching screens: a mistyped ID should be
        // an inline error, not an empty map.
        do {
            _ = try await service.getSpace()
        } catch {
            if let reason = TrackerStore.sessionEndReason(error) { return sessionEnded(reason) }
            spaceError = "Couldn't open that space. Check the ID and that your account is a member. ("
                + TrackerStore.message(for: error) + ")"
            return
        }

        let store = TrackerStore(service: service)
        store.onSessionEnded = { [weak self] reason in self?.sessionEnded(reason) }
        let selection = SpaceSelection(contextId: contextId, displayName: displayName)
        preferences.space = selection
        self.space = selection
        self.store = store
        phase = .ready
        await store.bootstrap(displayName: displayName)
    }

    /// Leave the open space (stay signed in) to pick another.
    public func leaveSpace() async {
        if let store {
            store.stop()
            await store.goOffline()
        }
        store = nil
        preferences.space = nil
        preferences.sharingTrackerId = nil
        phase = .choosingSpace
    }

    // MARK: Sign out

    public func signOut() async {
        if let store {
            store.stop()
            await store.goOffline()
        }
        await tearDown()
    }

    /// The account session ended under the app (revoked, device removed).
    /// Unlike ``signOut()`` this leaves a reason on the sign-in screen.
    public func sessionEnded(_ reason: String) {
        guard phase != .signedOut else { return }
        sessionNotice = reason + " Please sign in again."
        store?.stop()
        store = nil
        phase = .signedOut
        Task { await client.logout() }
    }

    private func tearDown() async {
        store = nil
        preferences.sharingTrackerId = nil
        await client.logout()
        phase = .signedOut
    }

    // MARK: Test hooks

    /// Put the state machine in `phase` directly (unit tests only).
    func setPhaseForTesting(_ phase: Phase) { self.phase = phase }
}
