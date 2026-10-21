import Foundation

/// Sends one HTTP request. `URLSessionTransport` in the app; scripted in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, http)
    }
}

public enum APIError: Error, Equatable {
    case notSignedIn
    /// The session can't be refreshed; sign in again.
    case sessionExpired
    /// An Exerly password account already uses this Apple ID's email.
    case linkRequired
    /// This Apple ID is already connected to another Exerly account.
    case linkConflict
    /// Account deletion needs a fresh Sign in with Apple authorization code.
    case appleReauthorizationRequired
    /// Account deletion needs the account's password.
    case passwordRequired
    /// The password given to confirm account deletion is wrong.
    case wrongPassword
    /// The account no longer exists: it was deleted, perhaps by a request whose
    /// response was lost, or on another device. Remove its local data.
    case accountDeleted
    /// The session was replaced or removed while the request was in flight,
    /// or it belongs to another account. Nothing from the response was applied.
    case accountChanged
    case invalidResponse
    case server(status: Int, message: String)
}

extension APIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notSignedIn, .sessionExpired: "Your session ended. Sign in again; your data on this device is safe."
        case .linkRequired: "An Exerly account already uses this email. Sign in with your password, then connect Apple in Settings."
        case .linkConflict: "This Apple ID is already connected to another Exerly account."
        case .appleReauthorizationRequired: "Sign in with Apple again to confirm."
        case .passwordRequired: "Enter your password to confirm."
        case .wrongPassword: "That password is incorrect."
        case .accountDeleted: "This Exerly account was deleted."
        case .accountChanged: "The signed-in account changed, so this request was stopped."
        case .invalidResponse: "The server sent an unexpected response. Try again."
        case .server(_, let message): message
        }
    }
}

public struct AccountSummary: Sendable, Hashable {
    public var id: String
    public var email: String
    public var name: String?
}

public struct SignInResult: Sendable, Hashable {
    public var created: Bool
    public var account: AccountSummary
}

/// A document as the server holds it. `payload` is nil for a tombstone.
public struct RemoteDocument: Sendable, Hashable {
    public var kind: String
    public var id: String
    public var revision: Int
    public var deleted: Bool
    public var payload: Data?
    public var sequence: Int?
    /// When the server took this version.
    public var updatedAt: Date?
}

public enum DocumentWriteResult: Sendable, Hashable {
    case applied(revision: Int)
    /// The base revision was stale. The current document, or nil if it no longer exists.
    case conflict(RemoteDocument?)
}

public struct ChangePage: Sendable, Hashable {
    public var changes: [RemoteDocument]
    public var cursor: Int
    public var hasMore: Bool
}

/// The Exerly API client and a standalone owner of the session. Keeps the
/// session fresh: refreshes shortly before the access token expires and once
/// after a 401. A refresh keeps its idempotency key in the credential store
/// until the rotated credential is saved, so a lost response is retried rather
/// than burning the session.
///
/// Signing in or out starts a new session generation. Work begun under an
/// older generation never saves credentials or returns a response, so a slow
/// refresh can't resurrect a signed-out session or replace a newer sign-in.
public actor ExerlyAPI: SessionTransport {
    private let baseURL: URL
    private let transport: HTTPTransport
    private let credentials: CredentialStore
    private let now: @Sendable () -> Date
    private var generation = 0
    private var refreshing: (generation: Int, task: Task<Credentials, Error>)?

    public init(baseURL: URL, transport: HTTPTransport = URLSessionTransport(), credentials: CredentialStore,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.baseURL = baseURL
        self.transport = transport
        self.credentials = credentials
        self.now = now
    }

    public var isSignedIn: Bool { (try? credentials.load()) != nil }

    public var accountID: String? { (try? credentials.load())?.accountID }

    /// The signed-in account's endpoints, bound to that account.
    public func account() throws -> AccountAPI {
        guard let id = try credentials.load()?.accountID else { throw APIError.notSignedIn }
        return AccountAPI(accountID: id, transport: self)
    }

    // MARK: Signing in and out

    public func signInWithApple(identityToken: String, rawNonce: String, name: String?, timeZone: TimeZone,
                                unitSystem: String?) async throws -> SignInResult {
        var body: [String: Any] = ["identityToken": identityToken, "nonce": rawNonce, "timezone": timeZone.identifier]
        if let name, !name.isEmpty { body["name"] = name }
        if let unitSystem { body["unitSystem"] = unitSystem }
        return try await startSession(path: "/auth/apple", body: body)
    }

    public func signIn(email: String, password: String) async throws -> SignInResult {
        try await startSession(path: "/login", body: ["email": email, "password": password])
    }

    /// Forgets the session at once, then revokes it on the server when reachable.
    public func signOut() async throws {
        let current = try credentials.load()
        endGeneration()
        try credentials.save(nil)
        try credentials.savePendingRefreshKey(nil)
        guard let current else { return }
        var token = current.accessToken
        if current.accessExpiresAt.timeIntervalSince(now()) <= 30 {
            // Exchange the refresh token for an access token that only revokes;
            // its rotated credentials are never stored.
            let body = try JSONSerialization.data(withJSONObject: ["refreshToken": current.refreshToken])
            guard let (status, data) = try? await send("POST", "/auth/token", body: body,
                                                       headers: ["Idempotency-Key": UUID().uuidString], token: nil),
                  status == 200, let fresh = try? Self.session(from: JSONSerialization.jsonObject(with: data), issuedAt: now())
            else { return }
            token = fresh.0.accessToken
        }
        _ = try? await send("POST", "/auth/logout", body: Data("{}".utf8), headers: [:], token: token)
    }

    /// Deletes the account and everything in it, then forgets the session. A
    /// retry after a lost response finds the account already gone and succeeds.
    public func deleteAccount(confirmation: AccountConfirmation) async throws {
        let account = try account()
        do {
            try await account.deleteAccount(confirmation: confirmation)
        } catch APIError.accountDeleted {
            return
        }
        guard accountID == account.accountID else { return }
        endGeneration()
        try credentials.save(nil)
        try credentials.savePendingRefreshKey(nil)
    }

    // MARK: Session transport

    public func send(_ method: String, path: String, body: Data?, headers: [String: String],
                     as accountID: String) async throws -> (status: Int, data: Data) {
        let started = generation
        var current = try await freshCredentials(forceRefresh: false)
        for attempt in 0..<2 {
            guard current.accountID == accountID else { throw APIError.accountChanged }
            let (status, data) = try await send(method, path, body: body, headers: headers, token: current.accessToken)
            // Nothing from an old session's response may reach the caller.
            guard generation == started else { throw APIError.accountChanged }
            if status != 401 { return (status, data) }
            if Wire.code(try? JSONSerialization.jsonObject(with: data)) == "account_deleted" {
                endGeneration()
                try credentials.save(nil)
                try credentials.savePendingRefreshKey(nil)
                throw APIError.accountDeleted
            }
            if attempt == 1 { break }
            current = try await freshCredentials(forceRefresh: true)
        }
        throw APIError.sessionExpired
    }

    // MARK: Sessions

    private func endGeneration() {
        generation += 1
        refreshing?.task.cancel()
        refreshing = nil
    }

    private func startSession(path: String, body: [String: Any]) async throws -> SignInResult {
        endGeneration()
        let started = generation
        let (status, data) = try await send("POST", path, body: try JSONSerialization.data(withJSONObject: body),
                                            headers: ["X-Session-Protocol": "2"], token: nil)
        let json = try? JSONSerialization.jsonObject(with: data)
        guard status == 200 || status == 201 else {
            if status == 409, Wire.code(json) == "link_required" { throw APIError.linkRequired }
            throw Wire.failure(status, json)
        }
        let (saved, account) = try Self.session(from: json, issuedAt: now())
        // A sign-out or a newer sign-in during the request wins.
        guard generation == started else { throw APIError.accountChanged }
        try credentials.save(saved)
        try credentials.savePendingRefreshKey(nil)
        return SignInResult(created: (json as? [String: Any])?["created"] as? Bool ?? (status == 201), account: account)
    }

    private func freshCredentials(forceRefresh: Bool) async throws -> Credentials {
        guard let current = try credentials.load() else { throw APIError.notSignedIn }
        if !forceRefresh && current.accessExpiresAt.timeIntervalSince(now()) > 30 { return current }
        if let refreshing, refreshing.generation == generation { return try await refreshing.task.value }
        let started = generation
        let task = Task { try await self.refresh(current, generation: started) }
        refreshing = (started, task)
        defer { if refreshing?.generation == started { refreshing = nil } }
        return try await task.value
    }

    private func refresh(_ current: Credentials, generation started: Int) async throws -> Credentials {
        let key = try credentials.loadPendingRefreshKey() ?? UUID().uuidString
        try credentials.savePendingRefreshKey(key)
        let body = try JSONSerialization.data(withJSONObject: ["refreshToken": current.refreshToken])
        let (status, data) = try await send("POST", "/auth/token", body: body, headers: ["Idempotency-Key": key], token: nil)
        // Save nothing unless this is still the session the refresh began from.
        guard generation == started, try credentials.load() == current else { throw APIError.accountChanged }
        let json = try? JSONSerialization.jsonObject(with: data)
        if status == 401 {
            endGeneration()
            try credentials.save(nil)
            try credentials.savePendingRefreshKey(nil)
            throw APIError.sessionExpired
        }
        guard status == 200 else { throw Wire.failure(status, json) }
        var (rotated, _) = try Self.session(from: json, issuedAt: now())
        rotated.accountID = current.accountID
        try credentials.save(rotated)
        try credentials.savePendingRefreshKey(nil)
        return rotated
    }

    // MARK: Requests

    private func send(_ method: String, _ path: String, body: Data?, headers: [String: String],
                      token: String?) async throws -> (Int, Data) {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Timezone")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await transport.send(request)
        return (response.statusCode, data)
    }

    // MARK: Parsing

    private static func session(from json: Any?, issuedAt: Date) throws -> (Credentials, AccountSummary) {
        guard let json = json as? [String: Any], let token = json["token"] as? String,
              let refresh = json["refreshToken"] as? String, let expiresIn = json["expiresIn"] as? Int,
              let sessionID = json["sessionId"] as? String, let user = json["user"] as? [String: Any],
              let id = user["_id"] as? String, let email = user["email"] as? String
        else { throw APIError.invalidResponse }
        let credentials = Credentials(accessToken: token, refreshToken: refresh,
                                      accessExpiresAt: issuedAt.addingTimeInterval(Double(expiresIn)),
                                      sessionID: sessionID, accountID: id)
        return (credentials, AccountSummary(id: id, email: email, name: user["name"] as? String))
    }
}
