import Foundation
import Testing
@testable import ExerlyCore

/// The document contract of the real API, in memory: revisions, stale-base
/// conflicts, idempotent replays, tombstones, an ordered change feed, and one
/// document per UUID whatever its letter case.
final class FakeDocumentServer: DocumentAPI, @unchecked Sendable {
    struct Stored { var revision: Int; var payload: Data? }
    private let lock = NSLock()
    private var documents: [String: Stored] = [:]
    private var feed: [RemoteDocument] = []
    private var receipts: [String: DocumentWriteResult] = [:]
    /// When set, the next write is applied but its response is lost.
    var loseNextResponse = false
    var offline = false
    /// Refuses larger payloads with 413, as the API's 256 KB body limit does.
    var maxPayloadBytes: Int?
    private(set) var writes = 0
    /// Every write the server received, including ones refused as conflicts.
    private(set) var attempts: [(id: String, baseRevision: Int)] = []

    private func key(_ kind: String, _ id: String) -> String { "\(kind)/\(DocumentWrite.canonicalID(id))" }

    func revision(_ kind: String, _ id: String) -> Int? { lock.withLock { documents[key(kind, id)]?.revision } }
    func stored(_ kind: String, _ id: String) -> Stored? { lock.withLock { documents[key(kind, id)] } }
    /// Every version written, oldest first.
    func history(_ kind: String, _ id: String) -> [Stored] {
        lock.withLock { feed.filter { key($0.kind, $0.id) == key(kind, id) }.map { Stored(revision: $0.revision, payload: $0.payload) } }
    }

    func putDocument(kind: String, id: String, payload: Data, baseRevision: Int, idempotencyKey: String) async throws -> DocumentWriteResult {
        try write(kind, id, payload, baseRevision, idempotencyKey)
    }

    func deleteDocument(kind: String, id: String, baseRevision: Int, idempotencyKey: String) async throws -> DocumentWriteResult {
        try write(kind, id, nil, baseRevision, idempotencyKey)
    }

    private func write(_ kind: String, _ id: String, _ payload: Data?, _ base: Int, _ idempotency: String) throws -> DocumentWriteResult {
        try lock.withLock {
            if offline { throw Offline() }
            if let maxPayloadBytes, (payload?.count ?? 0) > maxPayloadBytes {
                throw APIError.server(status: 413, message: "request entity too large")
            }
            if let receipt = receipts[idempotency] { return receipt }
            attempts.append((id, base))
            let current = documents[key(kind, id)]
            if payload == nil && current == nil { throw APIError.server(status: 404, message: "Document not found") }
            guard base == (current?.revision ?? 0) else {
                return .conflict(current.map {
                    RemoteDocument(kind: kind, id: id, revision: $0.revision, deleted: $0.payload == nil, payload: $0.payload)
                })
            }
            let revision = base + 1
            documents[key(kind, id)] = Stored(revision: revision, payload: payload)
            feed.append(RemoteDocument(kind: kind, id: id, revision: revision, deleted: payload == nil, payload: payload,
                                       sequence: feed.count + 1))
            writes += 1
            let result = DocumentWriteResult.applied(revision: revision)
            receipts[idempotency] = result
            if loseNextResponse {
                loseNextResponse = false
                throw Offline()
            }
            return result
        }
    }

    /// Puts a document straight into the feed, as another client could, even one
    /// this device can't read.
    func inject(kind: String, id: String, payload: Data?) {
        lock.withLock {
            let revision = (documents[key(kind, id)]?.revision ?? 0) + 1
            documents[key(kind, id)] = Stored(revision: revision, payload: payload)
            feed.append(RemoteDocument(kind: kind, id: id, revision: revision, deleted: payload == nil, payload: payload,
                                       sequence: feed.count + 1))
        }
    }

    func changes(after cursor: Int, limit: Int) async throws -> ChangePage {
        try lock.withLock {
            if offline { throw Offline() }
            let page = Array(feed.dropFirst(cursor).prefix(limit))
            return ChangePage(changes: page, cursor: cursor + page.count, hasMore: cursor + page.count < feed.count)
        }
    }
}

@MainActor
final class Device {
    let persistence: InMemoryTrainingPersistence
    let store: TrainingStore
    let engine: SyncEngine
    private let clockBox: ClockBox

    init(server: FakeDocumentServer) throws {
        let box = ClockBox()
        let persistence = InMemoryTrainingPersistence()
        clockBox = box
        self.persistence = persistence
        store = try TrainingStore(persistence: persistence, now: { box.now })
        engine = SyncEngine(store: store, state: persistence, api: server)
    }

    func advance(minutes: Double) { clockBox.now = clockBox.now.addingTimeInterval(minutes * 60) }

    final class ClockBox: @unchecked Sendable { var now = Fixture.instant() }

    /// Logs a completed set of the first exercise in the active session.
    func logSet(reps: Int, kg: Double) throws {
        let performed = try #require(store.activeSession?.exercises.first)
        let id = try store.addSet(to: performed.id)
        var set = store.activeSession!.set(id)!.set
        set.primary = Effort(reps: reps, load: .kg(kg))
        try store.updateSet(set, in: performed.id)
        try store.completeSet(id)
    }
}

@MainActor
@Suite struct SyncEngineTests {
    @Test func aSessionLoggedOnOneDeviceArrivesOnAnother() async throws {
        let server = FakeDocumentServer()
        let phone = try Device(server: server)
        let tablet = try Device(server: server)
        try phone.store.startSession(name: "Legs", bodyweight: .kg(80))
        try phone.store.addExercise("back-squat")
        try phone.logSet(reps: 5, kg: 100)
        try phone.store.finishSession()
        try await phone.engine.sync()

        try await tablet.engine.sync()
        #expect(tablet.store.history.sessions == phone.store.history.sessions)
        #expect(tablet.store.history.statistics(of: "back-squat")?.totalVolume == 500)
        #expect(phone.engine.state == .idle && tablet.engine.state == .idle)
        #expect(phone.engine.lastSyncedAt != nil)
    }

    @Test func concurrentEditsMergeAndConverge() async throws {
        let server = FakeDocumentServer()
        let phone = try Device(server: server)
        let watch = try Device(server: server)
        try phone.store.startSession(name: "Upper", bodyweight: .kg(80))
        try phone.store.addExercise("barbell-bench-press")
        try await phone.engine.sync()
        try await watch.engine.sync()
        #expect(watch.store.activeSession?.id == phone.store.activeSession?.id)

        // Both log offline.
        try phone.logSet(reps: 5, kg: 100)
        try watch.logSet(reps: 8, kg: 80)
        try watch.store.updateActiveSession { $0.notes = "From the watch" }

        try await phone.engine.sync()
        try await watch.engine.sync()
        try await phone.engine.sync()

        let phoneSession = try #require(phone.store.activeSession)
        let watchSession = try #require(watch.store.activeSession)
        #expect(phoneSession == watchSession)
        #expect(phoneSession.notes == "From the watch")
        let loads = phoneSession.exercises[0].sets.filter(\.isCompleted).map(\.primary.load)
        #expect(Set(loads) == [.kg(100), .kg(80)])
    }

    @Test func aLostAcknowledgementReplaysInsteadOfConflicting() async throws {
        let server = FakeDocumentServer()
        let phone = try Device(server: server)
        try phone.store.startSession(name: "Pull", bodyweight: nil)
        try phone.store.addExercise("lat-pulldown")
        server.loseNextResponse = true
        await #expect(throws: Offline.self) { try await phone.engine.sync() }
        #expect(phone.engine.state == .offline)
        let id = try #require(phone.store.activeSession?.id.uuidString)
        #expect(server.revision("workout_session", id) == 1)

        try await phone.engine.sync()
        #expect(server.revision("workout_session", id) == 1, "the retry replayed the first write")
        #expect(server.writes == 1)
    }

    @Test func offlineChangesWaitAndThenPush() async throws {
        let server = FakeDocumentServer()
        let phone = try Device(server: server)
        server.offline = true
        try phone.store.startSession(name: "Offline", bodyweight: nil)
        try phone.store.addExercise("deadlift")
        try phone.logSet(reps: 3, kg: 180)
        try phone.store.finishSession()
        await #expect(throws: Offline.self) { try await phone.engine.sync() }
        #expect(phone.store.history.sessions.count == 1, "local data is untouched")

        server.offline = false
        try await phone.engine.sync()
        let tablet = try Device(server: server)
        try await tablet.engine.sync()
        #expect(tablet.store.history.sessions.count == 1)
    }

    @Test func deletionsPropagate() async throws {
        let server = FakeDocumentServer()
        let phone = try Device(server: server)
        let tablet = try Device(server: server)
        try phone.store.startSession(name: "Doomed", bodyweight: nil)
        try phone.store.addExercise("deadlift")
        try phone.logSet(reps: 3, kg: 150)
        let finished = try phone.store.finishSession().session
        try await phone.engine.sync()
        try await tablet.engine.sync()
        #expect(tablet.store.history.sessions.count == 1)

        try phone.store.deleteSession(finished.id)
        try await phone.engine.sync()
        try await tablet.engine.sync()
        #expect(tablet.store.history.sessions.isEmpty)
        #expect(tablet.persistence.sessions.isEmpty)
    }

    @Test func aChangeSurvivesADeletionOnAnotherDevice() async throws {
        let server = FakeDocumentServer()
        let phone = try Device(server: server)
        let tablet = try Device(server: server)
        try phone.store.startSession(name: "Contested", bodyweight: nil)
        try phone.store.addExercise("deadlift")
        try await phone.engine.sync()
        try await tablet.engine.sync()

        try phone.store.discardSession()
        try tablet.logSet(reps: 5, kg: 140)
        try await phone.engine.sync()
        try await tablet.engine.sync()
        try await phone.engine.sync()

        #expect(phone.store.activeSession?.exercises[0].sets.contains { $0.isCompleted } == true)
        #expect(phone.store.activeSession == tablet.store.activeSession)
    }

    @Test func customExercisesArriveBeforeTheSessionsThatUseThem() async throws {
        let server = FakeDocumentServer()
        let phone = try Device(server: server)
        let tablet = try Device(server: server)
        let custom = Exercise(id: .custom(), name: "Zercher Squat", metric: .weightReps, mechanics: .compound,
                              region: .lower, muscles: [.quads: 1, .glutes: 1], equipment: [.barbell])
        try phone.store.addCustomExercise(custom)
        try phone.store.startSession(name: "Custom", bodyweight: nil)
        try phone.store.addExercise(custom.id)
        try phone.logSet(reps: 5, kg: 90)
        try phone.store.finishSession()
        try await phone.engine.sync()

        try await tablet.engine.sync()
        #expect(tablet.store.library.exercise(custom.id) == custom)
        #expect(tablet.store.history.statistics(of: custom.id)?.totalVolume == 450)
    }

    @Test func syncingTwiceChangesNothing() async throws {
        let server = FakeDocumentServer()
        let phone = try Device(server: server)
        try phone.store.startSession(name: "Stable", bodyweight: nil)
        try phone.store.addExercise("deadlift")
        try await phone.engine.sync()
        let writes = server.writes
        try await phone.engine.sync()
        try await phone.engine.sync()
        #expect(server.writes == writes)
    }

    @Test func syncStateSurvivesARelaunchWithSQLite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("exerly-sync-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("exerly.sqlite")
        let server = FakeDocumentServer()
        do {
            let persistence = try SQLiteTrainingPersistence(url: url)
            let store = try TrainingStore(persistence: persistence, now: { Fixture.instant() })
            try store.startSession(name: "Persisted sync", bodyweight: nil)
            try store.addExercise("deadlift")
            try await SyncEngine(store: store, state: persistence, api: server).sync()
        }
        let persistence = try SQLiteTrainingPersistence(url: url)
        let store = try TrainingStore(persistence: persistence)
        let writes = server.writes
        try await SyncEngine(store: store, state: persistence, api: server).sync()
        #expect(server.writes == writes, "bases and the cursor were remembered")
        #expect(try persistence.syncCursor() > 0)
    }
}

@MainActor
@Suite struct ProposalSyncTests {
    @MainActor
    final class AgentDevice {
        let persistence = InMemoryTrainingPersistence()
        let training: TrainingStore
        let agent: AgentStore
        let engine: SyncEngine

        init(server: FakeDocumentServer) throws {
            training = try TrainingStore(persistence: persistence, now: { Fixture.instant() })
            agent = try AgentStore(persistence: persistence, hosts: [training], now: { Fixture.instant(minutes: 5) })
            engine = SyncEngine(hosts: [training, agent], state: persistence, api: server)
        }
    }

    @Test func aProposalFiledOnOneDeviceCanBeAcceptedOnAnother() async throws {
        let server = FakeDocumentServer()
        let phone = try AgentDevice(server: server)
        let tablet = try AgentDevice(server: server)

        try phone.training.startSession(name: "Typo", bodyweight: nil)
        let deadlift = try phone.training.addExercise("deadlift")
        var set = phone.training.activeSession!.exercises[0].sets[0]
        set.primary = Effort(reps: 3, load: .kg(1500))
        try phone.training.updateSet(set, in: deadlift)
        try phone.training.completeSet(set.id)
        let session = try phone.training.finishSession().session
        var fixed = session
        fixed.exercises[0].sets[0].primary.load = .kg(150)
        let proposal = Proposal(author: AgentIdentity(kind: .mcp, name: "Synthetic agent", tokenID: "t1"),
                                title: "Did you mean 150 kg?", summary: "Ten times your history.",
                                changes: [try ProposedChange(kind: "workout_session", id: session.id.uuidString, before: session, after: fixed)],
                                evidence: [], confidence: .high, falsifier: "You lifted 1500 kg.")
        try phone.agent.file(proposal)
        try await phone.engine.sync()

        try await tablet.engine.sync()
        #expect(tablet.agent.proposal(proposal.id)?.status == .pending)
        try tablet.agent.accept(proposal.id)
        try await tablet.engine.sync()

        try await phone.engine.sync()
        #expect(phone.agent.proposal(proposal.id)?.status == .accepted)
        #expect(phone.training.history.sessions[0].exercises[0].sets[0].primary.load == .kg(150))
        #expect(phone.agent.auditLog.map(\.action) == [.proposalFiled, .proposalAccepted])
        #expect(phone.agent.auditLog == tablet.agent.auditLog)
    }

    @Test func anUnreadableRemoteDocumentIsSetAsideAndSyncCarriesOn() async throws {
        let server = FakeDocumentServer()
        let phone = try Device(server: server)
        let tablet = try Device(server: server)
        let badID = UUID().uuidString
        server.inject(kind: "workout_session", id: badID,
                      payload: Data(#"{"id":"\#(badID)","startedAt":"yesterday","exercises":[]}"#.utf8))
        try tablet.store.startSession(name: "Legs", bodyweight: .kg(80))
        try tablet.store.addExercise("back-squat")
        try tablet.logSet(reps: 5, kg: 100)
        try tablet.store.finishSession()
        try await tablet.engine.sync()

        try await phone.engine.sync()
        #expect(phone.engine.state == .idle)
        #expect(phone.store.history.sessions.map(\.name) == ["Legs"])
        #expect(phone.engine.rejected.map(\.id) == [badID])
        #expect(phone.engine.rejected.first?.revision == 1)
        #expect(phone.store.history.session(UUID(uuidString: badID)!) == nil)

        // It is remembered across launches, and a later readable version replaces it.
        let relaunched = SyncEngine(store: phone.store, state: phone.persistence, api: server)
        try await relaunched.sync()
        #expect(relaunched.rejected.map(\.id) == [badID])
        let fixed = WorkoutSession(id: UUID(uuidString: badID)!, name: "Fixed", startedAt: Fixture.instant(days: -1),
                                   endedAt: Fixture.instant(days: -1, minutes: 30), timeZone: Fixture.utc)
        server.inject(kind: "workout_session", id: badID, payload: try ExerlyJSON.canonical(fixed))
        try await relaunched.sync()
        #expect(relaunched.rejected.isEmpty)
        #expect(Set(phone.store.history.sessions.map(\.name)) == ["Legs", "Fixed"])
    }

    /// The app agent's reproduction: a lowercase UUID on the server must not
    /// become a second document when a device syncs it.
    @Test func aLowercaseDocumentIDIsTheSameDocument() async throws {
        let server = FakeDocumentServer()
        let upper = UUID()
        let lower = upper.uuidString.lowercased()
        let session = WorkoutSession(id: upper, name: "Lowercase", startedAt: Fixture.instant(), endedAt: Fixture.instant(minutes: 30),
                                     timeZone: Fixture.utc)
        let json = try #require(String(bytes: try ExerlyJSON.canonical(session), encoding: .utf8))
        let payload = Data(json.replacingOccurrences(of: upper.uuidString, with: lower).utf8)
        server.inject(kind: "workout_session", id: lower, payload: payload)
        let device = try Device(server: server)
        try await device.engine.sync()
        #expect(device.store.history.sessions == [session])
        #expect(server.attempts.isEmpty, "Nothing to push: the device's copy is the server's document")

        // An edit goes back under the canonical ID, with the server's revision as its base.
        var edited = session
        edited.notes = "Edited"
        try device.store.saveSession(edited)
        try await device.engine.sync()
        #expect(server.attempts.count == 1)
        #expect(server.attempts.first?.id == upper.uuidString && server.attempts.first?.baseRevision == 1)
    }

    /// A device that synced before the fix holds its base under the lowercase
    /// ID; the base must still count for the uppercase document.
    @Test func aLowercaseSyncBaseIsFoldedIntoTheCanonicalOne() async throws {
        let server = FakeDocumentServer()
        let phone = try Device(server: server)
        try phone.store.startSession(name: "Legs", bodyweight: .kg(80))
        try phone.store.finishSession()
        try await phone.engine.sync()
        let id = try #require(phone.store.history.sessions.first).id.uuidString
        var base = try #require(try phone.persistence.syncBases().first { $0.id == id })
        try phone.persistence.removeSyncBase(kind: base.kind, id: id)
        base.id = id.lowercased()
        try phone.persistence.saveSyncBase(base)
        let attempts = server.attempts.count

        try await phone.engine.sync()
        #expect(server.attempts.count == attempts, "The folded base matches the local copy, so nothing is pushed")
        #expect(try phone.persistence.syncBases().map(\.id) == [id])
    }

    /// A proposal an older server stored with lowercase IDs can still be
    /// accepted and undone on the phone.
    @Test func aProposalWithLowercaseIDsCanBeAcceptedAndUndone() async throws {
        let server = FakeDocumentServer()
        let phone = try AgentDevice(server: server)
        try phone.training.startSession(name: "Typo", bodyweight: nil)
        let deadlift = try phone.training.addExercise("deadlift")
        var set = phone.training.activeSession!.exercises[0].sets[0]
        set.primary = Effort(reps: 3, load: .kg(1500))
        try phone.training.updateSet(set, in: deadlift)
        try phone.training.completeSet(set.id)
        let session = try phone.training.finishSession().session
        try await phone.engine.sync()

        var fixed = session
        fixed.exercises[0].sets[0].primary.load = .kg(150)
        let sessionID = session.id.uuidString
        let proposal = Proposal(author: AgentIdentity(kind: .mcp, name: "Synthetic agent", tokenID: "t1"),
                                title: "Did you mean 150 kg?", summary: "",
                                changes: [try ProposedChange(kind: "workout_session", id: sessionID, before: session, after: fixed)],
                                evidence: [Evidence(claim: "Ten times your history", level: .personalData,
                                                    dataRefs: [DataRef(kind: "workout_session", id: sessionID)])],
                                confidence: .high, falsifier: "You lifted 1500 kg.")
        let json = try #require(String(bytes: try ExerlyJSON.canonical(proposal), encoding: .utf8))
            .replacingOccurrences(of: sessionID, with: sessionID.lowercased())
            .replacingOccurrences(of: proposal.id.uuidString, with: proposal.id.uuidString.lowercased())
        server.inject(kind: "proposal", id: proposal.id.uuidString.lowercased(), payload: Data(json.utf8))
        try await phone.engine.sync()

        let received = try #require(phone.agent.proposal(proposal.id))
        #expect(received.changes.map(\.id) == [sessionID])
        #expect(received.evidence[0].dataRefs[0].id == sessionID)
        try phone.agent.accept(proposal.id)
        #expect(phone.training.history.sessions[0].exercises[0].sets[0].primary.load == .kg(150))
        try phone.agent.undo(proposal.id)
        #expect(phone.training.history.sessions == [session])
        #expect(phone.agent.auditLog.last?.targets == [DataRef(kind: "workout_session", id: sessionID)])
    }

    /// Logs a finished first bench workout and syncs it.
    func logTypo(on device: AgentDevice) async throws {
        try device.training.startSession(name: "First", bodyweight: nil)
        let bench = try device.training.addExercise("barbell-bench-press")
        for (index, kilograms) in [100.0, 100, 1000].enumerated() {
            let id = try index == 0 ? device.training.activeSession!.exercises[0].sets[0].id : device.training.addSet(to: bench)
            var set = device.training.activeSession!.set(id)!.set
            set.primary = Effort(reps: 5, load: .kg(kilograms))
            try device.training.updateSet(set, in: bench)
            try device.training.completeSet(id)
        }
        try device.training.finishSession()
        try await device.engine.sync()
    }

    /// Runs the entry check on the device's only workout and files what it finds.
    func fileEntryCheck(on device: AgentDevice, minutes: Double) throws {
        let session = try #require(device.training.history.sessions.first)
        let proposal = try #require(try EntryErrorDetector.proposal(for: session, history: device.training.history,
                                                                   existing: device.agent.proposals,
                                                                   now: Fixture.instant(minutes: minutes)))
        try device.agent.file(proposal)
    }

    @Test func anEntryCheckFiledOnTwoDevicesBeforeSyncingIsOneProposal() async throws {
        let server = FakeDocumentServer()
        let phone = try AgentDevice(server: server)
        let tablet = try AgentDevice(server: server)
        try await logTypo(on: phone)
        try await tablet.engine.sync()

        try fileEntryCheck(on: phone, minutes: 40)
        try fileEntryCheck(on: tablet, minutes: 41)
        try await phone.engine.sync()
        try await tablet.engine.sync()
        try await phone.engine.sync()
        #expect(phone.agent.proposals.count == 1)
        #expect(phone.agent.proposals == tablet.agent.proposals)
    }

    @Test func aRejectedEntryCheckStaysRejectedWhenAnotherDeviceFilesIt() async throws {
        let server = FakeDocumentServer()
        let phone = try AgentDevice(server: server)
        let tablet = try AgentDevice(server: server)
        try await logTypo(on: phone)
        try await tablet.engine.sync()

        try fileEntryCheck(on: phone, minutes: 40)
        let id = try #require(phone.agent.proposals.first).id
        try phone.agent.reject(id)
        try await phone.engine.sync()
        // The tablet hasn't seen the proposal, so it files the same check.
        try fileEntryCheck(on: tablet, minutes: 41)
        try await tablet.engine.sync()
        try await phone.engine.sync()
        #expect(tablet.agent.proposals.map(\.status) == [.rejected])
        #expect(phone.agent.proposals.map(\.status) == [.rejected])
        #expect(phone.training.history.sessions[0].exercises[0].sets[2].primary.load == .kg(1000))
    }
}

/// A nutrition store that counts how often sync encodes one of its documents.
@MainActor
final class CountingHost: DocumentHost {
    let store: NutritionStore
    private(set) var encoded = 0

    init(_ store: NutritionStore) { self.store = store }

    var documentKinds: [String] { store.documentKinds }
    func documentIDs(kind: String) -> [String] { store.documentIDs(kind: kind) }
    func payload(kind: String, id: String) throws -> Data? {
        encoded += 1
        return try store.payload(kind: kind, id: id)
    }
    /// As a build that can't read the store's documents would be.
    var unreadable = false
    func canonicalize(kind: String, payload: Data) throws -> Data {
        if unreadable { throw DocumentError(message: "Not readable by this build") }
        return try store.canonicalize(kind: kind, payload: payload)
    }
    func validate(kind: String, id: String, payload: Data) throws { try store.validate(kind: kind, id: id, payload: payload) }
    func merge(kind: String, base: Data?, local: Data, remote: Data) throws -> Data {
        try store.merge(kind: kind, base: base, local: local, remote: remote)
    }
    func prepareWrite(kind: String, id: String, payload: Data?) throws -> () -> Void {
        try store.prepareWrite(kind: kind, id: id, payload: payload)
    }
}

/// Review round 2, item 6: a launch's sync encodes only documents written
/// since they last matched the server, so three years of food cost nothing.
@MainActor
@Suite struct ChangedDocumentPushTests {
    let monday = LocalDate("2026-10-05")!

    @Test(arguments: [false, true])
    func aPushWithNothingChangedEncodesNoDocument(sqlite: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk: TrainingPersistence & DocumentPersistence & SyncStateStore = sqlite
            ? try SQLiteTrainingPersistence(url: directory.appendingPathComponent("exerly.sqlite")) : InMemoryTrainingPersistence()
        let server = FakeDocumentServer()
        let store = try NutritionStore(persistence: disk)
        let entries = try (0..<50).map { try store.log(Foods.oats, grams: Double(10 + $0), on: monday, meal: "Breakfast") }
        try await SyncEngine(hosts: [CountingHost(store)], state: disk, api: server, appVersion: "1").sync()

        // A relaunch: a new engine over the same store.
        let host = CountingHost(store)
        try await SyncEngine(hosts: [host], state: disk, api: server, appVersion: "1").sync()
        #expect(host.encoded == 0, "Sync encoded \(host.encoded) unchanged documents")

        var edited = entries[7]
        edited.grams = 99
        try store.saveEntry(edited)
        let after = CountingHost(store)
        try await SyncEngine(hosts: [after], state: disk, api: server, appVersion: "1").sync()
        #expect(after.encoded <= 2, "Only the edited entry is encoded")
        #expect(server.revision(NutritionStore.entryKind, edited.id.uuidString) == 2)

        // A new app version compares everything once, as it may encode differently.
        let upgraded = CountingHost(store)
        try await SyncEngine(hosts: [upgraded], state: disk, api: server, appVersion: "2").sync()
        #expect(upgraded.encoded >= entries.count)
        #expect(server.writes == entries.count + 1, "Nothing else was pushed")
    }
}

/// Review round 3, finding 3: a workout a newer app saved with a value this
/// build doesn't know can't be read here. A full comparison leaves it, here
/// and on the server, rather than pushing its deletion, and sets it aside.
@MainActor
@Suite struct UnreadableRowTests {
    /// `loaded`: opened as the app does, history read off the main actor
    /// (`StoredAccount`) and the stores started from it (review round 4).
    @Test(arguments: [false, true])
    func aRowThisBuildCantReadIsNeverPushedAsADeletion(loaded: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("exerly.sqlite")
        let server = FakeDocumentServer()
        let session = Fixture.session([("barbell-bench-press", [Fixture.set(5, 100)])])
        do {
            let disk = try SQLiteTrainingPersistence(url: url)
            let store = try TrainingStore(persistence: disk)
            _ = try store.importSessions([session])
            try await SyncEngine(hosts: [store], state: disk, api: server, appVersion: "1").sync()
            disk.close()
        }
        // A newer app's set kind, written as that app would.
        let database = try SQLiteDatabase(url: url)
        let newer = String(decoding: try #require(server.stored(TrainingStore.sessionKind, session.id.uuidString)?.payload), as: UTF8.self)
            .replacingOccurrences(of: "\"standard\"", with: "\"cluster\"")
        try database.execute("UPDATE sessions SET payload = ? WHERE id = ?", Data(newer.utf8), session.id.uuidString)
        database.close()

        let stored = loaded ? try #require(try StoredAccount.read(url: url)) : nil
        let disk = try SQLiteTrainingPersistence(url: url)
        let store = try stored.map { try TrainingStore(persistence: disk, loaded: $0.training) } ?? TrainingStore(persistence: disk)
        #expect(store.history.session(session.id) == nil && disk.unreadableRows.count == 1)
        let sync = SyncEngine(hosts: [store], state: disk, api: server, appVersion: "2")
        try await sync.sync()
        #expect(server.history(TrainingStore.sessionKind, session.id.uuidString).allSatisfy { $0.payload != nil }, "No deletion was pushed")
        #expect(sync.rejected.map(\.id) == [session.id.uuidString])
        let row = try database.reopen(url).query("SELECT payload FROM sessions WHERE id = ?", session.id.uuidString)
        #expect(row.count == 1, "The row stays for a newer build")
    }
}

/// Review round 4, finding 3: an older build can't read a workout (rev 1)
/// and sets aside the tablet's rev 2 as it pulls it; its push mustn't
/// replace that record of where rev 2 is, so after upgrading it fetches rev 2.
@MainActor
@Suite struct SetAsideRecoveryTests {
    @Test func aNewerVersionSetAsideWhileTheRowIsUnreadableIsFetchedAfterTheUpgrade() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("exerly.sqlite")
        let server = FakeDocumentServer()
        let session = Fixture.session([("barbell-bench-press", [Fixture.set(5, 100)])])
        do {
            let disk = try SQLiteTrainingPersistence(url: url)
            _ = try TrainingStore(persistence: disk).importSessions([session])
            try await SyncEngine(hosts: [try TrainingStore(persistence: disk)], state: disk, api: server, appVersion: "2").sync()
            disk.close()
        }
        // The row as this table stores it, which a newer build would read.
        let original = try SQLiteDatabase(url: url)
        guard case .blob(let readable)? = try original.query("SELECT payload FROM sessions WHERE id = ?", session.id.uuidString).first?.first
        else { Issue.record("No row"); return }
        original.close()
        func store(_ payload: Data) throws {
            let database = try SQLiteDatabase(url: url)
            try database.execute("UPDATE sessions SET payload = ? WHERE id = ?", payload, session.id.uuidString)
            database.close()
        }
        // Rolled back to an older build, which can't read rev 1.
        try store(Data(String(decoding: readable, as: UTF8.self).replacingOccurrences(of: "\"standard\"", with: "\"cluster\"").utf8))
        var renamed = session
        renamed.name = "Synthetic heavy day"
        server.inject(kind: TrainingStore.sessionKind, id: session.id.uuidString, payload: try ExerlyJSON.canonical(renamed))
        do {
            let disk = try SQLiteTrainingPersistence(url: url)
            let sync = SyncEngine(hosts: [try TrainingStore(persistence: disk)], state: disk, api: server, appVersion: "1")
            try await sync.sync()
            #expect(sync.rejected.first?.revision == 2 && sync.rejected.first?.sequence != nil, "Where rev 2 is stays recorded")
            disk.close()
        }
        // Upgraded again: this build reads the row, and fetches rev 2.
        try store(readable)
        let disk = try SQLiteTrainingPersistence(url: url)
        let training = try TrainingStore(persistence: disk)
        let sync = SyncEngine(hosts: [training], state: disk, api: server, appVersion: "3")
        try await sync.sync()
        #expect(training.history.session(session.id)?.name == "Synthetic heavy day", "Rev 2 was fetched after the upgrade")
        #expect(server.revision(TrainingStore.sessionKind, session.id.uuidString) == 2)
    }
}

extension SQLiteDatabase {
    func reopen(_ url: URL) throws -> SQLiteDatabase { try SQLiteDatabase(url: url) }
}

/// Review round 3, finding 7: a pulled change the store declines to apply,
/// such as another device deleting a custom exercise sessions still use,
/// leaves this device's copy recorded to push, as comparing every document
/// would, so the devices end up agreeing.
@MainActor
@Suite struct DeclinedWriteTests {
    @Test func aDeletionTheStoreKeepsFromIsPushedBack() async throws {
        let server = FakeDocumentServer()
        let disk = InMemoryTrainingPersistence()
        let store = try TrainingStore(persistence: disk)
        let exercise = Exercise(id: "custom-synthetic-sled-push", name: "Synthetic Sled Push", aliases: [], metric: .weightReps,
                                mechanics: .compound, region: .lower, muscles: [.quads: 1], equipment: [.sled], support: [])
        try store.addCustomExercise(exercise)
        let sync = SyncEngine(hosts: [store], state: disk, api: server, appVersion: "1")
        try await sync.sync()
        server.inject(kind: TrainingStore.exerciseKind, id: exercise.id.rawValue, payload: nil)
        try await sync.sync()
        #expect(store.library.exercise(exercise.id) != nil, "Kept here, as sessions may use it")
        #expect(server.stored(TrainingStore.exerciseKind, exercise.id.rawValue)?.payload != nil, "Pushed back, so both devices agree")
    }
}


/// Review round 3, compatibility: a document one build sets aside is fetched
/// again by the next build, which may read it; and a conflict a newer app
/// settled with a choice this build doesn't know is kept, settled, as it came.
@MainActor
@Suite struct NewerDocumentTests {
    let monday = LocalDate("2026-10-05")!

    @Test func aDocumentSetAsideIsFetchedAgainAfterAnUpgrade() async throws {
        let server = FakeDocumentServer()
        let tabletDisk = InMemoryTrainingPersistence()
        let tablet = try NutritionStore(persistence: tabletDisk)
        let logged = try tablet.log(Foods.oats, grams: 40, on: monday, meal: "Breakfast")
        try await SyncEngine(hosts: [tablet], state: tabletDisk, api: server).sync()

        let disk = InMemoryTrainingPersistence()
        let host = CountingHost(try NutritionStore(persistence: disk))
        host.unreadable = true
        let older = SyncEngine(hosts: [host], state: disk, api: server, appVersion: "1")
        try await older.sync()
        #expect(older.rejected.map(\.id) == [logged.id.uuidString] && host.store.entries.isEmpty)
        host.unreadable = false
        try await SyncEngine(hosts: [host], state: disk, api: server, appVersion: "1").sync()
        #expect(host.store.entries.isEmpty, "The same build doesn't fetch it again")
        let upgraded = SyncEngine(hosts: [host], state: disk, api: server, appVersion: "2")
        try await upgraded.sync()
        #expect(host.store.entries.map(\.id) == [logged.id] && upgraded.rejected.isEmpty, "The new build reads it")
    }

    @Test func aChoiceANewerAppMadeKeepsTheConflictSettledAsItCame() async throws {
        let server = FakeDocumentServer(), clock = TickingClock()
        let phone = try AccountDevice("iPhone", server: server, clock: clock)
        let id = UUID()
        let newer = """
            {"id":"\(id.uuidString)","kind":"food_entry","documentID":"\(UUID().uuidString)",\
            "device":{"id":"\(UUID().uuidString)","name":"iPad"},"detectedAt":"2026-10-21T14:14:00.000Z",\
            "changedAt":"2026-10-21T14:15:00.000Z","local":{"grams":60},"remote":{"grams":90},"fields":["grams"],\
            "resolution":{"choice":"average","at":"2026-10-21T14:15:00.000Z","device":{"id":"\(UUID().uuidString)","name":"iPad"}}}
            """
        server.inject(kind: SyncConflictStore.kind, id: id.uuidString, payload: Data(newer.utf8))
        try await phone.sync.sync()
        let conflict = try #require(phone.conflicts.conflict(id), "Not set aside")
        #expect(phone.sync.rejected.isEmpty && conflict.isResolved && phone.conflicts.unresolved.isEmpty)
        #expect(conflict.resolution?.choice.rawValue == "average")
        let payload = try #require(try phone.conflicts.payload(kind: SyncConflictStore.kind, id: id.uuidString))
        #expect(String(decoding: payload, as: UTF8.self).contains(#""choice":"average""#), "Kept as it came")
    }
}
