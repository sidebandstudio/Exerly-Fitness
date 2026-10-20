import Foundation
import Testing
@testable import ExerlyCore

/// The Swift client and sync engine against the real API. Runs only when
/// EXERLY_LIVE_API is set: `scripts/live-sync.sh` starts the API on a
/// throwaway PostgreSQL database and sets it.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["EXERLY_LIVE_API"] != nil))
struct LiveSyncTests {
    let base = URL(string: ProcessInfo.processInfo.environment["EXERLY_LIVE_API"] ?? "http://127.0.0.1:39102")!

    /// Creates a synthetic account and returns its email and password.
    func signUp() async throws -> (String, String) {
        let email = "live-\(UUID().uuidString.prefix(8).lowercased())@exerly.test"
        let password = "synthetic-password-\(UUID().uuidString.prefix(6))"
        var request = URLRequest(url: base.appendingPathComponent("signup"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": "Live Test", "email": email, "password": password])
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 201)
        return (email, password)
    }

    /// A JSON request to the API with the device's session or a token.
    func call(_ method: String, _ path: String, bearer: String, body: Any? = nil,
              headers: [String: String] = [:]) async throws -> (Int, Any?) {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, try? JSONSerialization.jsonObject(with: data))
    }

    /// Calls an MCP tool the way an agent's client does, and returns its JSON result.
    func tool(_ name: String, _ arguments: [String: Any], token: String) async throws -> [String: Any] {
        let (status, json) = try await call(
            "POST", "/mcp", bearer: token,
            body: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]],
            headers: ["Accept": "application/json, text/event-stream"])
        #expect(status == 200)
        let result = try #require((json as? [String: Any])?["result"] as? [String: Any])
        let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(result["isError"] as? Bool != true, "\(name): \(text)")
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @MainActor
    final class LiveDevice {
        let api: ExerlyAPI
        let credentials = InMemoryCredentialStore()
        let persistence: InMemoryTrainingPersistence
        let store: TrainingStore
        let programs: ProgramStore
        let nutrition: NutritionStore
        let agent: AgentStore
        private(set) var engine: SyncEngine!

        init(base: URL) throws {
            let persistence = InMemoryTrainingPersistence()
            self.persistence = persistence
            api = ExerlyAPI(baseURL: base, credentials: credentials)
            store = try TrainingStore(persistence: persistence)
            programs = try ProgramStore(persistence: persistence, training: store)
            nutrition = try NutritionStore(persistence: persistence)
            agent = try AgentStore(persistence: persistence, hosts: [store, programs, nutrition])
        }

        /// Signs in, then binds sync to the signed-in account.
        func signIn(email: String, password: String) async throws -> SignInResult {
            let result = try await api.signIn(email: email, password: password)
            engine = SyncEngine(hosts: [store, programs, nutrition, agent], state: persistence, api: try await api.account())
            return result
        }

        func logSet(reps: Int, kg: Double) throws {
            let performed = store.activeSession!.exercises[0]
            let id = try store.addSet(to: performed.id)
            var set = store.activeSession!.set(id)!.set
            set.primary = Effort(reps: reps, load: .kg(kg))
            try store.updateSet(set, in: performed.id)
            try store.completeSet(id)
        }
    }

    @Test func anExportImportsIntoAnotherAccountAndSyncsToItsPhone() async throws {
        let (fromEmail, fromPassword) = try await signUp()
        let (toEmail, toPassword) = try await signUp()
        let from = try LiveDevice(base: base)
        _ = try await from.signIn(email: fromEmail, password: fromPassword)
        let day = LocalDate("2026-10-06")!
        try from.nutrition.log(Food(name: "Synthetic oats, rolled", per100g: NutrientAmounts([.energy: 380, .protein: 13])),
                               grams: 80, on: day, meal: "Breakfast")
        try from.nutrition.logWeight(.lb(180.4), timeZone: .gmt)
        try from.store.startSession(name: "Live export", bodyweight: .kg(80), timeZone: .gmt)
        try from.store.addExercise("barbell-bench-press")
        try from.logSet(reps: 5, kg: 100)
        try from.store.finishSession()
        try await from.engine.sync()
        let account = try await from.api.account()
        let csv = String(bytes: try await account.exportCSV(.foodEntries), encoding: .utf8) ?? ""
        #expect(csv.contains("\"Synthetic oats, rolled\"") && csv.contains("energy_kcal"))

        let to = try LiveDevice(base: base)
        _ = try await to.signIn(email: toEmail, password: toPassword)
        let result = try await to.api.account().importExport(try await account.exportAccount())
        #expect(result.imported >= 3 && result.skipped.isEmpty)
        try await to.engine.sync()
        #expect(to.nutrition.entries == from.nutrition.entries && to.nutrition.weights == from.nutrition.weights)
        #expect(to.store.history.sessions == from.store.history.sessions)
        #expect(try await to.api.account().importExport(try await account.exportAccount()).imported == 0)
    }

    @Test func twoDevicesSyncMergeAndDeleteThroughTheRealAPI() async throws {
        let (email, password) = try await signUp()
        let phone = try LiveDevice(base: base)
        let watch = try LiveDevice(base: base)
        let signedIn = try await phone.signIn(email: email, password: password)
        _ = try await watch.signIn(email: email, password: password)
        #expect(signedIn.account.email == email)

        // A custom exercise and a session, logged on the phone.
        let custom = Exercise(id: .custom(), name: "Synthetic Zercher Squat", metric: .weightReps, mechanics: .compound,
                              region: .lower, muscles: [.quads: 1, .glutes: 1], equipment: [.barbell])
        try phone.store.addCustomExercise(custom)
        try phone.store.startSession(name: "Live session", bodyweight: .kg(80), timeZone: TimeZone(identifier: "America/New_York")!)
        try phone.store.addExercise(custom.id)
        try phone.logSet(reps: 5, kg: 90)
        try await phone.engine.sync()

        try await watch.engine.sync()
        #expect(watch.store.library.exercise(custom.id) == custom)
        #expect(watch.store.activeSession == phone.store.activeSession)

        // Both log offline, then converge.
        try phone.logSet(reps: 5, kg: 95)
        try watch.logSet(reps: 8, kg: 70)
        try watch.store.updateActiveSession { $0.notes = "Logged on the watch" }
        try await phone.engine.sync()
        try await watch.engine.sync()
        try await phone.engine.sync()
        #expect(phone.store.activeSession == watch.store.activeSession)
        let loads = Set(phone.store.activeSession!.exercises[0].sets.filter(\.isCompleted).compactMap(\.primary.load))
        #expect(loads == [.kg(90), .kg(95), .kg(70)])

        // A forced refresh rotates the credential on the real server.
        var expired = try #require(try phone.credentials.load())
        expired.accessExpiresAt = Date(timeIntervalSince1970: 0)
        try phone.credentials.save(expired)
        try phone.store.finishSession()
        try await phone.engine.sync()
        #expect(try phone.credentials.load()?.refreshToken != expired.refreshToken)

        try await watch.engine.sync()
        #expect(watch.store.activeSession == nil)
        #expect(watch.store.history.sessions == phone.store.history.sessions)

        // Deletion reaches the other device.
        try phone.store.deleteSession(phone.store.history.sessions[0].id)
        try await phone.engine.sync()
        try await watch.engine.sync()
        #expect(watch.store.history.sessions.isEmpty)

        // The export holds the synced documents; deleting the account ends both sessions.
        let exported: Data = try await phone.api.account().exportAccount()
        let export = try JSONSerialization.jsonObject(with: exported) as? [String: Any]
        let documents = export?["documents"] as? [[String: Any]]
        #expect(documents?.contains { $0["document_id"] as? String == custom.id.rawValue } == true)
        try await phone.api.deleteAccount(confirmation: .password(password))
        #expect(await !phone.api.isSignedIn)
        // The other device learns the account is gone, not merely that its session ended.
        await #expect(throws: APIError.accountDeleted) { _ = try await watch.api.account().changes(after: 0, limit: 10) }
        #expect(await !watch.api.isSignedIn)
    }

    @Test func anAgentsProposalThroughMCPIsReviewedAndAcceptedOnThePhone() async throws {
        let (email, password) = try await signUp()
        let phone = try LiveDevice(base: base)
        _ = try await phone.signIn(email: email, password: password)
        try phone.store.startSession(name: "Heavy day", bodyweight: .kg(80), timeZone: TimeZone(identifier: "America/New_York")!)
        try phone.store.addExercise("barbell-bench-press")
        try phone.logSet(reps: 5, kg: 100)
        try phone.logSet(reps: 5, kg: 1000) // A stray zero.
        try phone.store.finishSession()
        try await phone.engine.sync()
        let session = try #require(phone.store.history.sessions.first)

        // The person gives their agent a propose-only token.
        let access = try #require(try phone.credentials.load()).accessToken
        let account = try await phone.api.account()
        let created = try await account.createAccessToken(name: "Synthetic agent", scopes: [.propose], expiresInDays: 30)
        #expect(created.token.scopes == [.read, .propose] && created.token.expiresAt != nil)
        #expect(try await account.accessTokens().map(\.id) == [created.token.id])
        let token = created.secret

        // The agent reads the session and the e1RM through MCP, then proposes the fix.
        let stored = try await tool("get_document", ["kind": "workout_session", "id": session.id.uuidString], token: token)
        var payload = try #require(stored["payload"] as? [String: Any])
        var exercises = try #require(payload["exercises"] as? [[String: Any]])
        var sets = try #require(exercises[0]["sets"] as? [[String: Any]])
        let wrong = try #require(sets.firstIndex { set in
            let load = (set["efforts"] as? [[String: Any]])?.first?["load"] as? [String: Any]
            return load?["value"] as? Double == 1000
        })
        var efforts = try #require(sets[wrong]["efforts"] as? [[String: Any]])
        efforts[0]["load"] = ["unit": "kg", "value": 100]
        sets[wrong]["efforts"] = efforts
        exercises[0]["sets"] = sets
        payload["exercises"] = exercises

        let day = session.localDate.description
        let history = try await tool("exercise_history", ["exercise": "barbell-bench-press", "from": day, "through": day],
                                     token: token)
        let claimed = try #require((history["statistics"] as? [String: Any])?["e1rm_kg"] as? Double)
        let filed = try await tool("propose", [
            "title": "Was that set 100 kg?",
            "summary": "1000 kg is ten times your other working set.",
            "confidence": "high",
            "falsifier": "You confirm you benched 1000 kg.",
            "evidence": [["claim": "The logged set implies this e1RM", "level": "personalData", "caveats": ["n=1"],
                          "metric": ["name": "exercise.e1rm.best",
                                     "parameters": ["exercise": "barbell-bench-press", "from": day, "through": day],
                                     "claimed": claimed]]],
            "changes": [["kind": "workout_session", "id": session.id.uuidString, "after": payload]],
        ], token: token)
        let filedID = try #require(filed["proposal_id"] as? String)
        let proposalID = try #require(UUID(uuidString: filedID))

        // The phone receives it, checks the agent's number and shows a one-field diff.
        try await phone.engine.sync()
        let proposal = try #require(phone.agent.proposal(proposalID))
        #expect(proposal.status == .pending && proposal.author.kind == .mcp && proposal.author.name == "Synthetic agent")
        guard case .verified = try #require(proposal.evidence.first?.metric).verify(against: phone.store.history) else {
            Issue.record("The agent's e1RM should verify against ExerlyCore's")
            return
        }
        #expect(phone.agent.diff(proposalID).flatMap(\.fields).map(\.path) == ["exercises[0].sets[\(wrong)].efforts[0].load.value"])

        // One tap applies it, and the correction and decision reach the server.
        try phone.agent.accept(proposalID)
        #expect(phone.store.history.sessions[0].exercises[0].sets[wrong].primary.load == .kg(100))
        try await phone.engine.sync()
        let (_, sessionJSON) = try await call("GET", "/v1/documents/workout_session/\(session.id.uuidString)", bearer: access)
        let serverSets = ((((sessionJSON as? [String: Any])?["payload"] as? [String: Any])?["exercises"] as? [[String: Any]])?[0]["sets"]
            as? [[String: Any]])
        let serverLoad = ((serverSets?[wrong]["efforts"] as? [[String: Any]])?[0]["load"] as? [String: Any])?["value"] as? Double
        #expect(serverLoad == 100)
        let (_, proposalJSON) = try await call("GET", "/v1/documents/proposal/\(proposalID.uuidString)", bearer: access)
        #expect(((proposalJSON as? [String: Any])?["payload"] as? [String: Any])?["status"] as? String == "accepted")
        #expect(phone.agent.auditLog.map(\.action) == [.tokenCreated, .proposalFiled, .proposalAccepted])

        // Revoking the token cuts the agent off.
        try await account.revokeAccessToken(id: created.token.id)
        #expect(try await account.accessTokens().isEmpty)
        let (refused, _) = try await call("POST", "/mcp", bearer: token,
                                          body: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
                                          headers: ["Accept": "application/json, text/event-stream"])
        #expect(refused == 401)
    }

    @Test func theServerPlansTheSameNextWorkoutAsThePhone() async throws {
        let (email, password) = try await signUp()
        let phone = try LiveDevice(base: base)
        _ = try await phone.signIn(email: email, password: password)
        let program = Program(name: "Live program", days: [
            ProgramDay(name: "A", slots: [
                ProgramSlot(exerciseID: "barbell-bench-press", target: SlotTarget(sets: 3, minReps: 6, maxReps: 8, rir: 2, rest: 120)),
                ProgramSlot(exerciseID: "pull-up", target: SlotTarget(sets: 3, minReps: 6, maxReps: 10, rir: 1)),
            ]),
            ProgramDay(name: "B", slots: [ProgramSlot(exerciseID: "back-squat", target: SlotTarget(sets: 2, minReps: 3, maxReps: 5, rir: 2))]),
        ], cycles: 3, deload: .last)
        try phone.programs.save(program)
        try phone.programs.activate(program.id)

        // Follow it for three workouts.
        let loads: [ExerciseID: (Double, Int)] = ["barbell-bench-press": (90, 8), "pull-up": (10, 9), "back-squat": (140, 5)]
        for _ in 0..<3 {
            let plan = try #require(phone.programs.nextWorkout(bodyweight: .kg(80)))
            let session = try phone.store.startSession(from: plan, bodyweight: .kg(80))
            for performed in session.exercises {
                for set in performed.sets {
                    var done = set
                    let (load, reps) = loads[performed.exerciseID]!
                    done.primary = Effort(reps: set.primary.reps ?? reps, load: set.primary.load ?? .kg(load))
                    try phone.store.updateSet(done, in: performed.id)
                    try phone.store.completeSet(set.id)
                }
            }
            try phone.store.finishSession()
            // Workouts that start in the same millisecond are ordered by ID, which is random.
            try await Task.sleep(for: .milliseconds(5))
        }
        try await phone.engine.sync()

        let swiftPlan = try #require(phone.programs.nextWorkout(bodyweight: .kg(80)))
        let account = try await phone.api.account()
        let token = try await account.createAccessToken(name: "Synthetic agent", scopes: []).secret
        let server = try await tool("next_workout", [:], token: token)
        #expect(server["day"] as? String == "B")
        #expect(server["cycle"] as? Int == 2)
        let exercises = try #require(server["exercises"] as? [[String: Any]])
        #expect(exercises.count == swiftPlan.exercises.count)
        for (planned, json) in zip(swiftPlan.exercises, exercises) {
            #expect(json["exercise_id"] as? String == planned.exerciseID.rawValue)
            let recommendation = try #require(json["recommendation"] as? [String: Any])
            #expect(recommendation["reason"] as? String == planned.recommendation.reason.rawValue)
            let sets = try #require(recommendation["sets"] as? [[String: Any]])
            #expect(sets.count == planned.recommendation.sets.count)
            for (set, json) in zip(planned.recommendation.sets, sets) {
                #expect(json["reps"] as? Int == set.effort.reps)
                let load = json["load"] as? [String: Any]
                #expect(load?["value"] as? Double == set.effort.load?.value)
                #expect(load?["unit"] as? String == set.effort.load?.unit.rawValue)
            }
        }
    }

    @Test func aNutritionPlanAndAnAcceptedCheckInSyncThroughTheRealAPI() async throws {
        let (email, password) = try await signUp()
        let phone = try LiveDevice(base: base)
        _ = try await phone.signIn(email: email, password: password)
        let today = LocalDate(Date(), in: .gmt)
        let plan = try NutritionPlan(startDate: today.adding(days: -21), goal: NutritionGoal(.lose, weeklyRate: 0.005))
            .computed(from: PlanBasis(expenditure: 2500, expenditureError: 400, trendWeight: 80))
        try phone.nutrition.prepareWrite(kind: "nutrition_plan", id: plan.id.uuidString, payload: ExerlyJSON.canonical(plan))()
        let days = (1...21).map { EnergyBalance.Day(date: today.adding(days: -$0), intake: 2300, weights: [80]) }
        let review = try NutritionCheckIn.review(plan: plan, days: days, prior: (2500, 400), today: today, existing: [], now: Date())
        let proposal = try #require(review.proposal, "\(review.outcome)")
        try phone.agent.file(proposal)
        try phone.agent.accept(proposal.id)
        try await phone.engine.sync()

        let tablet = try LiveDevice(base: base)
        _ = try await tablet.signIn(email: email, password: password)
        try await tablet.engine.sync()
        #expect(tablet.nutrition.plans == phone.nutrition.plans && tablet.nutrition.plans.count == 2)
        #expect(tablet.agent.proposal(proposal.id)?.status == .accepted)
        #expect(tablet.engine.rejected.isEmpty)
    }

    @Test func theServerReportsTheSameTrendAndExpenditureAsThePhone() async throws {
        let (email, password) = try await signUp()
        let phone = try LiveDevice(base: base)
        _ = try await phone.signIn(email: email, password: password)
        let today = LocalDate(Date(), in: .gmt)
        let start = today.adding(days: -13), end = today.adding(days: -1)
        let plan = try NutritionPlan(startDate: start, goal: NutritionGoal(.lose, weeklyRate: 0.005))
            .computed(from: PlanBasis(expenditure: 2500, expenditureError: 400, trendWeight: 80))
        try phone.nutrition.prepareWrite(kind: "nutrition_plan", id: plan.id.uuidString, payload: ExerlyJSON.canonical(plan))()
        let oats = Food(name: "Synthetic oats", per100g: NutrientAmounts([.energy: 380, .protein: 13]))
        for offset in 0..<13 {
            let date = start.adding(days: offset)
            try phone.nutrition.log(oats, grams: 450 + Double(offset % 3) * 40, on: date, meal: "Breakfast")
            try phone.nutrition.setStatus(offset == 4 ? .partial : .complete, on: date)
            let morning = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .gmt, year: date.year,
                                                                                  month: date.month, day: date.day, hour: 7))!
            if offset % 4 != 1 { try phone.nutrition.logWeight(.kg(80 - Double(offset) * 0.06), at: morning, timeZone: .gmt) }
        }
        try await phone.engine.sync()

        let expected = EnergyBalance.estimate(phone.nutrition.energyBalanceDays(from: start, through: end), prior: (2500, 400))
        let account = try await phone.api.account()
        let token = try await account.createAccessToken(name: "Synthetic agent", scopes: []).secret
        let summary = try await tool("get_nutrition_summary", ["from": start.description, "through": end.description], token: token)
        let days = try #require(summary["days"] as? [[String: Any]])
        #expect(days.count == expected.count)
        for (day, estimate) in zip(days, expected) {
            #expect(day["date"] as? String == estimate.date.description)
            #expect(abs((day["trend"] as? Double ?? .nan) - estimate.trend) <= 0.005, "\(estimate.date)")
            #expect(abs((day["expenditure"] as? Double ?? .nan) - estimate.expenditure) <= 0.5, "\(estimate.date)")
        }
    }

    @Test func anAgentsMealProposalIsAcceptedIntoThePhonesFoodLog() async throws {
        let (email, password) = try await signUp()
        let phone = try LiveDevice(base: base)
        _ = try await phone.signIn(email: email, password: password)
        let account = try await phone.api.account()
        let token = try await account.createAccessToken(name: "Synthetic agent", scopes: [.propose]).secret
        let entryID = UUID()
        let filed = try await tool("propose", [
            "title": "Log lunch: chicken and rice", "confidence": "medium",
            "falsifier": "The plate held a different amount or food.",
            "evidence": [["claim": "Estimated from the photo you sent", "level": "anecdote"]],
            "changes": [["kind": "food_entry", "id": entryID.uuidString.lowercased(), "after": [
                "id": entryID.uuidString.lowercased(), "date": "2026-10-06", "meal": "Lunch",
                "loggedAt": "2026-10-06T12:30:00.000Z", "grams": 180,
                "food": ["foodID": "agent:chicken-rice", "name": "Chicken and rice", "source": "custom",
                         "per100g": ["energy": 160, "protein": 12.5]],
            ]]],
        ], token: token)
        let proposalID = try #require(UUID(uuidString: filed["proposal_id"] as? String ?? ""))
        try await phone.engine.sync()
        #expect(phone.agent.proposal(proposalID)?.status == .pending)
        try phone.agent.accept(proposalID)
        let logged = try #require(phone.nutrition.entries.first)
        #expect(logged.id == entryID && logged.grams == 180 && logged.nutrients.energy == 288)
        try await phone.engine.sync()

        let tablet = try LiveDevice(base: base)
        _ = try await tablet.signIn(email: email, password: password)
        try await tablet.engine.sync()
        #expect(tablet.nutrition.entries == phone.nutrition.entries)
        #expect(tablet.agent.proposal(proposalID)?.status == .accepted)
    }
}
