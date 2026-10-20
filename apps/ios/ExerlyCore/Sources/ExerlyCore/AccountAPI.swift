import Foundation

/// Sends requests with the signed-in session. An app has exactly one owner of
/// its session, which refreshes it and stores it; in the Exerly app that is
/// the legacy `APIClient`. `ExerlyAPI` is a standalone owner for tests,
/// scripts and future targets.
public protocol SessionTransport: Sendable {
    /// Sends one request as `accountID`, refreshing the session once after a 401.
    ///
    /// Throws `APIError.accountChanged` when the session doesn't belong to
    /// `accountID`, or is replaced or removed while the request is in flight,
    /// so nothing from such a response is applied. Throws `.sessionExpired` or
    /// `.notSignedIn` when there is no usable session. Network failures are
    /// thrown as they come from the transport.
    func send(_ method: String, path: String, body: Data?, headers: [String: String],
              as accountID: String) async throws -> (status: Int, data: Data)
}

/// How the person shows it's them, not just someone holding the session,
/// before the account is deleted, Apple is connected or disconnected, or an
/// agent token is created. A password account always uses `.password`, even
/// with Apple connected; an account without one uses `.apple`.
public enum AccountConfirmation: Sendable, Equatable {
    /// The account's password.
    case password(String)
    /// A Sign in with Apple authorization from moments ago, as an Apple ID the
    /// account already has: its identity token and raw nonce, and its
    /// authorization code, with which the server revokes Apple's authorization
    /// when the account is deleted.
    case apple(identityToken: String, rawNonce: String, authorizationCode: String?)

    var fields: [String: Any] {
        switch self {
        case .password(let password): ["password": password]
        case let .apple(identityToken, rawNonce, _): ["identityToken": identityToken, "nonce": rawNonce]
        }
    }

    var body: [String: Any] {
        var body = fields.merging(["confirm": true]) { current, _ in current }
        if case .apple(_, _, let authorizationCode?) = self { body["appleAuthorizationCode"] = authorizationCode }
        return body
    }

    /// Connecting Apple sends the new Apple ID as `identityToken`, so an Apple
    /// confirmation travels as `currentIdentityToken`.
    var linkFields: [String: Any] {
        switch self {
        case .password(let password): ["password": password]
        case let .apple(identityToken, rawNonce, _): ["currentIdentityToken": identityToken, "currentNonce": rawNonce]
        }
    }
}

/// One account's endpoints: documents and the account lifecycle. Every request
/// is bound to `accountID`, so work started for one account can never read or
/// write as another.
public struct AccountAPI: DocumentAPI {
    public let accountID: String
    private let transport: SessionTransport

    public init(accountID: String, transport: SessionTransport) {
        self.accountID = accountID
        self.transport = transport
    }

    // MARK: Documents

    public func putDocument(kind: String, id: String, payload: Data, baseRevision: Int,
                            idempotencyKey: String) async throws -> DocumentWriteResult {
        var body = Data(#"{"base_revision":\#(baseRevision),"payload":"#.utf8)
        body.append(payload)
        body.append(Data("}".utf8))
        let (status, data) = try await send("PUT", "/v1/documents/\(kind)/\(id)", body: body,
                                            headers: ["Idempotency-Key": idempotencyKey])
        return try Wire.writeResult(status, data)
    }

    public func deleteDocument(kind: String, id: String, baseRevision: Int,
                               idempotencyKey: String) async throws -> DocumentWriteResult {
        let (status, data) = try await send("DELETE", "/v1/documents/\(kind)/\(id)?base_revision=\(baseRevision)",
                                            headers: ["Idempotency-Key": idempotencyKey])
        return try Wire.writeResult(status, data)
    }

    public func changes(after cursor: Int, limit: Int = 500) async throws -> ChangePage {
        let (status, data) = try await send("GET", "/v1/changes?after=\(cursor)&limit=\(limit)")
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let changes = json["changes"] as? [[String: Any]], let next = json["cursor"] as? Int
        else { throw Wire.failure(status, try? JSONSerialization.jsonObject(with: data)) }
        return ChangePage(changes: try changes.map(Wire.document), cursor: next, hasMore: json["has_more"] as? Bool ?? false)
    }

    // MARK: Account lifecycle

    /// Connects Sign in with Apple to this account, once `confirmation` shows
    /// it's the account's owner. Throws `linkConflict` when that Apple ID
    /// belongs to another Exerly account, and the confirmation errors
    /// `deleteAccount(confirmation:)` describes.
    public func connectApple(identityToken: String, rawNonce: String,
                             confirmation: AccountConfirmation) async throws {
        let body = confirmation.linkFields.merging(["identityToken": identityToken, "nonce": rawNonce]) { _, new in new }
        let (status, json) = try await sendJSON("POST", "/api/account/identities/apple", body: body)
        if status == 409 { throw APIError.linkConflict }
        guard status == 200 || status == 201 else { throw Self.confirmationFailure(status, json) }
    }

    /// Disconnects Sign in with Apple, given the account's password. Refused
    /// for an account with no password, which could not sign in again.
    public func disconnectApple(password: String) async throws {
        let (status, json) = try await sendJSON("DELETE", "/api/account/identities/apple", body: ["password": password])
        guard status == 200 else { throw Self.confirmationFailure(status, json) }
    }

    /// The full JSON export.
    public func exportAccount() async throws -> Data {
        let (status, data) = try await send("GET", "/api/export")
        guard status == 200 else { throw Wire.failure(status, try? JSONSerialization.jsonObject(with: data)) }
        return data
    }

    /// One kind of data as a CSV file for spreadsheets, such as
    /// `.foodEntries`. Unknown nutrients are empty cells, not zeros.
    public func exportCSV(_ file: CSVExport) async throws -> Data {
        let (status, data) = try await send("GET", "/v1/export/\(file.rawValue).csv")
        guard status == 200 else { throw Wire.failure(status, try? JSONSerialization.jsonObject(with: data)) }
        return data
    }

    /// Restores an Exerly JSON export, as `exportAccount()` returns it, into
    /// this account. Documents the account already has are kept; importing
    /// twice changes nothing.
    public func importExport(_ export: Data) async throws -> ImportResult {
        let (status, data) = try await send("POST", "/v1/import", body: export, headers: ["Content-Type": "application/json"])
        let json = try? JSONSerialization.jsonObject(with: data)
        guard status == 200, let result = json as? [String: Any], let imported = result["imported"] as? Int,
              let kept = result["kept"] as? Int else { throw Wire.failure(status, json) }
        let skipped = (result["skipped"] as? [[String: Any]] ?? []).compactMap { $0["reason"] as? String }
        return ImportResult(imported: imported, kept: kept, skipped: skipped,
                            ignoredTables: result["ignored_tables"] as? [String] ?? [])
    }

    /// Deletes the account and everything in it on the server, once
    /// `confirmation` shows it's the account's owner. Throws `wrongPassword`
    /// for a wrong password, `passwordRequired` when the account needs its
    /// password, and `appleReauthorizationRequired` when it needs a fresh Sign
    /// in with Apple. Nothing is deleted then, and the session stays. After a
    /// deletion the session owner forgets the session.
    public func deleteAccount(confirmation: AccountConfirmation) async throws {
        let (status, json) = try await sendJSON("DELETE", "/api/account", body: confirmation.body)
        guard status == 200 else { throw Self.confirmationFailure(status, json) }
    }

    private static func confirmationFailure(_ status: Int, _ json: Any?) -> Error {
        switch (status, Wire.code(json)) {
        case (400, "apple_reauthorization_required"): APIError.appleReauthorizationRequired
        case (400, "password_required"): APIError.passwordRequired
        case (403, "wrong_password"): APIError.wrongPassword
        default: Wire.failure(status, json)
        }
    }

    // MARK: Personal access tokens

    /// The account's active tokens, for a "Connected agents" screen.
    public func accessTokens() async throws -> [AccessToken] {
        let (status, data) = try await send("GET", "/v1/tokens")
        guard status == 200, let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Wire.failure(status, try? JSONSerialization.jsonObject(with: data))
        }
        return try rows.map(AccessToken.init(json:))
    }

    /// Creates a token for the person's own agent, once `confirmation` shows
    /// it's the account's owner: a token outlives the session. Every token can
    /// read; `propose` lets it file proposals and `write` lets it change data.
    /// The secret is returned here once and never again. Throws the
    /// confirmation errors `deleteAccount(confirmation:)` describes.
    public func createAccessToken(name: String, scopes: Set<AccessToken.Scope>, expiresInDays: Int? = nil,
                                  confirmation: AccountConfirmation) async throws -> CreatedAccessToken {
        let all = scopes.union([.read])
        var body: [String: Any] = ["name": name, "scopes": AccessToken.Scope.allCases.filter(all.contains).map(\.rawValue)]
        if let expiresInDays { body["expires_in_days"] = expiresInDays }
        body.merge(confirmation.fields) { current, _ in current }
        let (status, json) = try await sendJSON("POST", "/v1/tokens", body: body)
        guard status == 201, let row = json as? [String: Any] else { throw Self.confirmationFailure(status, json) }
        guard let secret = row["token"] as? String else {
            throw APIError.server(status: 409, message: "The token was created, but its secret can only be shown once. Revoke it and create another.")
        }
        return CreatedAccessToken(token: try AccessToken(json: row), secret: secret)
    }

    public func revokeAccessToken(id: String) async throws {
        let (status, json) = try await sendJSON("DELETE", "/v1/tokens/\(id)", body: nil)
        guard status == 200 else { throw Wire.failure(status, json) }
    }

    /// The account's webhooks, including those its agents' tokens created, so
    /// the person can see and stop them. They carry no data; see design 019.
    public func webhooks() async throws -> [Webhook] {
        let (status, data) = try await send("GET", "/v1/webhooks")
        guard status == 200, let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Wire.failure(status, try? JSONSerialization.jsonObject(with: data))
        }
        return try rows.map(Webhook.init(json:))
    }

    public func deleteWebhook(id: String) async throws {
        let (status, json) = try await sendJSON("DELETE", "/v1/webhooks/\(id)", body: nil)
        guard status == 204 else { throw Wire.failure(status, json) }
    }

    /// Resumes a disabled webhook from where it left off.
    public func enableWebhook(id: String) async throws -> Webhook {
        let (status, json) = try await sendJSON("POST", "/v1/webhooks/\(id)/enable", body: [:])
        guard status == 200, let row = json as? [String: Any] else { throw Wire.failure(status, json) }
        return try Webhook(json: row)
    }

    // MARK: Nutrition plans

    /// For an account set up before nutrition plans existed: the server turns
    /// its saved targets into manual plans with the same numbers, unless the
    /// account already has a plan. Returns how many it created; sync then
    /// brings them to `NutritionStore`. Safe to call again.
    public func adoptLegacyTargets() async throws -> Int {
        let (status, json) = try await sendJSON("POST", "/v1/nutrition/plans/from-legacy", body: [:])
        guard status == 200 || status == 201, let created = (json as? [String: Any])?["created"] as? Int else {
            throw Wire.failure(status, json)
        }
        return created
    }

    // MARK: Food database

    /// Foods matching a search, from a public food database (Open Food Facts),
    /// as unsaved `Food`s ready for `NutritionStore.saveFood` or `log`. Show the
    /// attribution with them.
    public func searchFoods(_ query: String, limit: Int = 20) async throws -> DatabaseFoods {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))]
        let encoded = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        let (status, data) = try await send("GET", "/v1/foods/search?\(encoded)")
        guard status == 200 else { throw Wire.failure(status, try? JSONSerialization.jsonObject(with: data)) }
        return try ExerlyJSON.decoder.decode(DatabaseFoods.self, from: data)
    }

    /// The food with this barcode, or nil when the database doesn't have it.
    /// Pass the camera's `symbology`: an eight-digit code is refused without
    /// one, because EAN-8 and UPC-E codes can't be told apart. Never expand a
    /// UPC-E code yourself; the server does.
    public func food(barcode: String, symbology: BarcodeSymbology? = nil) async throws -> DatabaseFoods? {
        let digits = barcode.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let query = symbology.map { "?symbology=\($0.rawValue)" } ?? ""
        let (status, data) = try await send("GET", "/v1/foods/barcode/\(digits)\(query)")
        if status == 404 { return nil }
        guard status == 200 else { throw Wire.failure(status, try? JSONSerialization.jsonObject(with: data)) }
        let found = try ExerlyJSON.decoder.decode(BarcodeFood.self, from: data)
        return DatabaseFoods(foods: [found.food], attribution: found.attribution)
    }

    /// The recipe a web page's structured data describes, read by the server.
    /// Match its lines with `matchFoods` and review it as a `RecipeImport`.
    public func importRecipe(from link: String) async throws -> WebRecipe {
        let (status, data) = try await send("POST", "/v1/recipes/import", body: try JSONSerialization.data(withJSONObject: ["url": link]))
        guard status == 200 else { throw Wire.failure(status, try? JSONSerialization.jsonObject(with: data)) }
        return try ExerlyJSON.decoder.decode(ImportedPage.self, from: data).recipe
    }

    /// The generic food each name matches, or nil, in the same order. It
    /// spends none of the server's Open Food Facts budget.
    public func matchFoods(_ names: [String]) async throws -> [Food?] {
        let (status, data) = try await send("POST", "/v1/foods/match", body: try JSONSerialization.data(withJSONObject: ["queries": names]))
        guard status == 200 else { throw Wire.failure(status, try? JSONSerialization.jsonObject(with: data)) }
        return try ExerlyJSON.decoder.decode(MatchedFoods.self, from: data).foods
    }

    private struct ImportedPage: Decodable { var recipe: WebRecipe }
    private struct MatchedFoods: Decodable { var foods: [Food?] }

    /// Product barcode formats, as cameras report them.
    public enum BarcodeSymbology: String, Sendable, Hashable, CaseIterable {
        case upcA = "upca", upcE = "upce", ean8, ean13, gtin14, itf14
    }

    private struct BarcodeFood: Decodable {
        var food: Food
        var attribution: String
    }

    // MARK: Requests

    private func send(_ method: String, _ path: String, body: Data? = nil,
                      headers: [String: String] = [:]) async throws -> (Int, Data) {
        let (status, data) = try await transport.send(method, path: path, body: body, headers: headers, as: accountID)
        return (status, data)
    }

    private func sendJSON(_ method: String, _ path: String, body: [String: Any]?) async throws -> (Int, Any?) {
        let (status, data) = try await send(method, path, body: try body.map { try JSONSerialization.data(withJSONObject: $0) })
        return (status, try? JSONSerialization.jsonObject(with: data))
    }
}

/// The CSV files the server can export.
public enum CSVExport: String, Sendable, Hashable, CaseIterable {
    case foodEntries = "food_entries", savedFoods = "saved_foods", weighIns = "weigh_ins", days, sets
    case metricValues = "metric_values", metrics
}

/// What an import did.
public struct ImportResult: Sendable, Hashable {
    public var imported: Int
    /// Already in the account, so left as they were.
    public var kept: Int
    /// Documents that failed the server's checks, with the reasons (at most 50).
    public var skipped: [String]
    /// Legacy tables in the export, which aren't imported.
    public var ignoredTables: [String]
}

/// A personal access token for the person's own agent, without its secret.
public struct AccessToken: Sendable, Hashable, Identifiable {
    public enum Scope: String, Sendable, Hashable, CaseIterable {
        case read, propose, write
    }

    public var id: String
    public var name: String
    /// The first characters of the secret, to tell tokens apart.
    public var prefix: String
    public var scopes: [Scope]
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var expiresAt: Date?

    init(json: [String: Any]) throws {
        func date(_ key: String) -> Date? {
            (json[key] as? String).flatMap(ISOMilliseconds.parse).map(Date.milliseconds)
        }
        guard let id = json["id"] as? String, let name = json["name"] as? String, let prefix = json["prefix"] as? String,
              let scopes = json["scopes"] as? [String], let created = date("created_at")
        else { throw APIError.invalidResponse }
        self.id = id
        self.name = name
        self.prefix = prefix
        self.scopes = scopes.compactMap(Scope.init(rawValue:))
        createdAt = created
        lastUsedAt = date("last_used_at")
        expiresAt = date("expires_at")
    }
}

/// An endpoint told when the account's change feed moves on.
public struct Webhook: Sendable, Hashable, Identifiable {
    public var id: String
    public var url: String
    public var createdAt: Date
    /// The token that created it, if one did; it stops when that token is revoked.
    public var createdByToken: String?
    public var lastDeliveryAt: Date?
    /// Failed deliveries in a row, and the last reason.
    public var failures: Int
    public var lastError: String?
    /// Set after 15 failures in a row, or when its token was revoked.
    public var disabledAt: Date?

    init(json: [String: Any]) throws {
        func date(_ key: String) -> Date? {
            (json[key] as? String).flatMap(ISOMilliseconds.parse).map(Date.milliseconds)
        }
        guard let id = json["id"] as? String, let url = json["url"] as? String, let created = date("created_at")
        else { throw APIError.invalidResponse }
        self.id = id
        self.url = url
        createdAt = created
        createdByToken = json["created_by_token"] as? String
        lastDeliveryAt = date("last_delivery_at")
        failures = json["failures"] as? Int ?? 0
        lastError = json["last_error"] as? String
        disabledAt = date("disabled_at")
    }
}

/// A token just created, with the secret to give the agent. Shown once.
public struct CreatedAccessToken: Sendable, Hashable {
    public var token: AccessToken
    public var secret: String
}

/// Parsing shared by the API types.
enum Wire {
    static func document(_ json: [String: Any]) throws -> RemoteDocument {
        guard let kind = json["kind"] as? String, let id = json["id"] as? String,
              let revision = json["revision"] as? Int, let deleted = json["deleted"] as? Bool
        else { throw APIError.invalidResponse }
        let payload = try (json["payload"] as? [String: Any]).map { try JSONSerialization.data(withJSONObject: $0) }
        return RemoteDocument(kind: kind, id: id, revision: revision, deleted: deleted, payload: payload,
                              sequence: json["sequence"] as? Int)
    }

    static func writeResult(_ status: Int, _ data: Data) throws -> DocumentWriteResult {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch status {
        case 200, 201:
            guard let revision = json?["revision"] as? Int else { throw APIError.invalidResponse }
            return .applied(revision: revision)
        case 409:
            let current = (json?["details"] as? [String: Any])?["document"] as? [String: Any]
            return .conflict(try current.map(document))
        default:
            throw failure(status, json)
        }
    }

    static func code(_ json: Any?) -> String? {
        ((json as? [String: Any])?["details"] as? [String: Any])?["code"] as? String
    }

    static func failure(_ status: Int, _ json: Any?) -> APIError {
        .server(status: status, message: (json as? [String: Any])?["message"] as? String ?? "HTTP \(status)")
    }
}

/// Foods from a public database, with the attribution its licence asks for.
public struct DatabaseFoods: Sendable, Hashable, Decodable {
    public var foods: [Food]
    public var attribution: String
}
