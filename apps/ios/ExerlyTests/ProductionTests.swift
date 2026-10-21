import XCTest
import SwiftData
import UserNotifications
@testable import Exerly

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var responseDelay: ((URLRequest) -> TimeInterval)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            let deliver = {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
            if let delay = Self.responseDelay?(request), delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver)
            } else { deliver() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class MemoryCredentials: SessionCredentials {
    private let lock = NSLock()
    private var token: String?
    private var refresh: String?
    var rejectWrites = false
    @discardableResult func saveToken(_ token: String) -> Bool {
        saveSession(token: token, refreshToken: nil)
    }
    @discardableResult func saveSession(token: String, refreshToken: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !rejectWrites else { return false }
        self.token = token; refresh = refreshToken; return true
    }
    @discardableResult func replaceSession(expectedToken: String, expectedRefreshToken: String?, token: String, refreshToken: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !rejectWrites, self.token == expectedToken, refresh == expectedRefreshToken else { return false }
        self.token = token; refresh = refreshToken; return true
    }
    func getRefreshToken() -> String? { lock.lock(); defer { lock.unlock() }; return refresh }
    func getToken() -> String? { lock.lock(); defer { lock.unlock() }; return token }
    func sessionSnapshot() -> SessionCredentialSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return token.map { SessionCredentialSnapshot(token: $0, refreshToken: refresh) }
    }
    func deleteToken() { lock.lock(); defer { lock.unlock() }; token = nil; refresh = nil }
}

final class RefusingSessionDefaults: UserDefaults {
    var refuseOperations = true
    override func set(_ value: Any?, forKey defaultName: String) {
        if refuseOperations && defaultName.hasPrefix("session.operation.") { return }
        super.set(value, forKey: defaultName)
    }
}

@MainActor
final class ProductionTests: XCTestCase {
    var defaults: UserDefaults!
    var keychain: MemoryCredentials!
    var api: APIClient!
    var testToday: CalendarDay!

    override func setUp() async throws {
        testToday = AccountCalendar(timeZoneIdentifier: "UTC").today()
        defaults = UserDefaults(suiteName: "exerly.tests.\(UUID().uuidString)")!
        keychain = MemoryCredentials()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        api = APIClient(baseURL: "https://fixture.exerly.test", session: URLSession(configuration: config), keychain: keychain, defaults: defaults)
    }
    override func tearDown() async throws { keychain.deleteToken(); StubURLProtocol.handler = nil; StubURLProtocol.responseDelay = nil }

    func testFoodPortionEditingPreservesFractionalNutritionSnapshot() throws {
        let data = Data(#"{"id":"food-precision","name":"Precise oats","calories":149,"servings":1.5,"entry_date":"2026-09-22","protein":5,"carbs":null,"sodium":185.19,"nutrition_basis":{"amount":100,"unit":"g"},"nutrition_snapshot":{"calories":99.5,"protein":3.3333,"carbs":null,"sodium":123.4567}}"#.utf8)
        let food = try JSONDecoder().decode(FoodDTO.self, from: data)
        let basis = food.perServingItem
        XCTAssertEqual(basis.preciseCalories, 99.5)
        XCTAssertEqual(basis.protein, 3.3333)
        XCTAssertTrue(basis.missingNutrients.contains("carbs"))
        XCTAssertEqual(basis.scaled(by: 0.75).calories, 75)
        XCTAssertEqual(try XCTUnwrap(basis.scaled(by: 0.75).sodium), 92.592525, accuracy: 0.000001)
        var edit = FoodRequest(name: basis.name, calories: try XCTUnwrap(basis.preciseCalories), protein: basis.protein, carbs: nil, fat: nil, sugar: nil, mealType: "breakfast", barcode: nil, brand: nil, fiber: nil, servingSize: "100 g")
        edit.servings = 0.75
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(edit)) as? [String: Any])
        XCTAssertEqual(body["calories"] as? Double, 99.5)
        XCTAssertEqual(body["servings"] as? Double, 0.75)
        let library = try JSONDecoder().decode(LibraryFoodDTO.self, from: Data(#"{"id":"library-precision","name":"Precise oats","calories":99.5,"protein":3.3333}"#.utf8))
        XCTAssertEqual(library.openFoodItem.preciseCalories, 99.5)
        XCTAssertEqual(library.openFoodItem.scaled(by: 0.75).calories, 75)
        let barcode = try JSONDecoder().decode(BarcodeFoodDTO.self, from: Data(#"{"name":"Precise oats","calories":99.5}"#.utf8))
        XCTAssertEqual(barcode.toOpenFoodItem().scaled(by: 0.75).calories, 75)
    }

    func testCalendarDayValidationArithmeticAndEncodingIgnoreDeviceTimeZone() throws {
        let leap = try XCTUnwrap(CalendarDay(rawValue: "2024-02-29"))
        XCTAssertEqual(leap.adding(days: 1)?.rawValue, "2024-03-01")
        XCTAssertEqual(CalendarDay(rawValue: "2025-12-31")?.adding(days: 1)?.rawValue, "2026-01-01")
        for value in ["2025-02-29", "2026-02-30", "2026-13-01", "2026-00-01", "2026-01-00", "2026-01-01T00:00:00Z", "٢٠٢٦-٠١-٠١"] {
            XCTAssertNil(CalendarDay(rawValue: value), value)
        }
        for zone in ["Pacific/Kiritimati", "Etc/GMT+12", "America/New_York"] {
            let account = AccountCalendar(timeZoneIdentifier: zone)
            let day = try XCTUnwrap(CalendarDay(rawValue: "2026-09-22"))
            XCTAssertEqual(CalendarDay(pickerDate: day.pickerDate), day)
            let decoded = try JSONDecoder().decode(CalendarDay.self, from: JSONEncoder().encode(day))
            XCTAssertEqual(decoded, day)
            XCTAssertEqual(day.formatted(locale: Locale(identifier: "en_US")), "Sep 22, 2026")
            XCTAssertNotNil(account.day(containing: day.pickerDate))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(CalendarDay.self, from: Data("\"2026-02-30\"".utf8)))
    }

    func testAccountCalendarUpdatesTodayWithoutMovingQueuedEntriesOrLeakingAccounts() async throws {
        var now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-22T09:59:59Z"))
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false, observeClock: false, now: { now })
        engine.configure(container: container, accountID: "a", timeZone: "Pacific/Kiritimati")
        let selected = engine.today
        XCTAssertEqual(selected.rawValue, "2026-09-22")
        now += 2
        engine.refreshCalendarDay()
        XCTAssertEqual(engine.today.rawValue, "2026-09-23")
        XCTAssertEqual(selected.rawValue, "2026-09-22", "An open form's selection is not a timestamp")
        let day = engine.today
        let summary = try await engine.diary(for: day, cachedOnly: true)
        XCTAssertEqual(summary.timezone, "Pacific/Kiritimati")
        try engine.addWater(XCTUnwrap(summary.water), milliliters: 250)
        try engine.saveWeight(.initial(day.rawValue), kilograms: 72, note: "Account day")
        try engine.saveActivity(ActivityRequest(type: "Walk", duration: 20, calories: nil, intensity: nil, entryDate: day.rawValue))
        try engine.saveSleep(SleepRequest(hours: 7, quality: nil, bedtime: nil, wakeTime: nil, entryDate: day.rawValue))
        try engine.saveMeasurement(BodyMeasurementRequest(type: "waist", value: 80, unit: "cm", entry_date: day.rawValue))
        var food = FoodRequest(name: "Apple", calories: 100, protein: 0, carbs: 25, fat: 0, sugar: nil, mealType: "snack", barcode: nil, brand: nil, fiber: nil, servingSize: nil)
        food.entryDate = day.rawValue
        try engine.saveFood(food)
        try engine.saveDiaryDay(.initial(day.rawValue), status: .complete, note: "Keep the chosen date")
        func payloads() throws -> [String: Data] {
            Dictionary(uniqueKeysWithValues: try ModelContext(container).fetch(FetchDescriptor<PendingMutation>()).map { ($0.operationID, $0.payload) })
        }
        let original = try payloads()
        XCTAssertEqual(original.count, 7)
        engine.configure(container: container, accountID: "a", timeZone: "Etc/GMT+12")
        XCTAssertEqual(engine.today.rawValue, "2026-09-21")
        XCTAssertEqual(try payloads(), original)
        let saved = try await engine.diary(for: day, cachedOnly: true)
        XCTAssertEqual(saved.date, day.rawValue)
        XCTAssertEqual(saved.waterMl, 250)
        XCTAssertEqual(saved.weight?.weightKg, 72)
        XCTAssertEqual(saved.activities.count, 1)
        XCTAssertEqual(saved.entryCount, 3)
        let reopened = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false, observeClock: false, now: { now })
        reopened.configure(container: container, accountID: "a", timeZone: "Etc/GMT+12")
        XCTAssertEqual(reopened.pendingCount, 7)
        XCTAssertEqual(try payloads(), original)
        let reopenedDay = try await reopened.diary(for: day, cachedOnly: true)
        XCTAssertEqual(reopenedDay.waterMl, 250)
        reopened.configure(container: container, accountID: "b", timeZone: "America/New_York")
        let other = try await reopened.diary(for: day, cachedOnly: true)
        XCTAssertEqual(other.waterMl, 0)
        XCTAssertEqual(other.entryCount, 0)
        XCTAssertEqual(reopened.pendingCount, 0)
    }

    func testLegacyMeasurementKeepsReviewedDayAcrossTimezoneChangesAndRejectsChangedOriginal() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-22T18:00:00Z"))
        let timestamp = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-20T18:00:00Z"))
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let record = Measurement(type: "waist", value: 80, unit: "cm", date: timestamp)
        context.insert(record); try context.save()
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false, observeClock: false, now: { now })
        engine.configure(container: container, accountID: "a", timeZone: "Pacific/Kiritimati")
        let review = LegacyMeasurementImport(record, day: try XCTUnwrap(engine.calendar.day(containing: timestamp)))
        XCTAssertEqual(review.day.rawValue, "2026-09-21")
        engine.configure(container: container, accountID: "a", timeZone: "Etc/GMT+12")
        XCTAssertEqual(engine.calendar.day(containing: timestamp)?.rawValue, "2026-09-20")
        record.value = 81; try context.save()
        XCTAssertThrowsError(try engine.importLegacyMeasurements([review]))
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Exerly.Measurement>()).count, 1)
        XCTAssertEqual(engine.pendingCount, 0)
        let updatedReview = LegacyMeasurementImport(record, day: review.day)
        try engine.importLegacyMeasurements([updatedReview])
        let imported = try await engine.measurements(from: "2026-09-20", to: "2026-09-21", cachedOnly: true)
        XCTAssertEqual(imported.first?.entry_date, "2026-09-21")
        XCTAssertEqual(imported.first?.value, 81)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Exerly.Measurement>()).count, 0)
    }

    func testAccountCalendarSeparatesTodayFromDateOnlyValuesAcrossDSTAndDateLine() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-22T18:00:00Z"))
        let east = AccountCalendar(timeZoneIdentifier: "Pacific/Kiritimati")
        let west = AccountCalendar(timeZoneIdentifier: "Etc/GMT+12")
        XCTAssertEqual(east.today(now: instant).rawValue, "2026-09-23")
        XCTAssertEqual(west.today(now: instant).rawValue, "2026-09-22")
        let newYork = AccountCalendar(timeZoneIdentifier: "America/New_York")
        for (stamp, expected) in [
            ("2026-03-08T06:59:59Z", "2026-03-08"), ("2026-03-08T07:00:00Z", "2026-03-08"),
            ("2026-11-01T05:59:59Z", "2026-11-01"), ("2026-11-01T06:00:00Z", "2026-11-01")
        ] {
            XCTAssertEqual(newYork.today(now: try XCTUnwrap(ISO8601DateFormatter().date(from: stamp))).rawValue, expected)
        }
        XCTAssertEqual(CalendarDay(rawValue: "2026-03-07")?.adding(days: 2)?.rawValue, "2026-03-09")
        XCTAssertEqual(CalendarDay(rawValue: "2026-10-31")?.adding(days: 2)?.rawValue, "2026-11-02")
        let apia = AccountCalendar(timeZoneIdentifier: "Pacific/Apia")
        XCTAssertEqual(apia.today(now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2011-12-30T09:59:59Z"))).rawValue, "2011-12-29")
        XCTAssertEqual(apia.today(now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2011-12-30T10:00:00Z"))).rawValue, "2011-12-31")
        XCTAssertEqual(CalendarDay(rawValue: "2011-12-29")?.adding(days: 1)?.rawValue, "2011-12-30")
        XCTAssertEqual(AccountCalendar(timeZoneIdentifier: "not-a-zone").timeZoneIdentifier, "UTC")
    }

    func testDraftSurvivesEveryStepAndBackwardNavigation() throws {
        for step in 0..<5 {
            let owner = "account-\(step)"
            let state = OnboardingState(defaults: defaults)
            state.restoreCheckpoint(accountID: owner)
            state.name = "Taylor"
            state.age = 31
            state.physiologicalSex = "female"
            state.heightCm = 167.3
            state.weightKg = 71.25
            state.goal = .loseWeight
            state.targetWeightKg = 68
            state.allergies = [.nuts, .soy]
            state.notifyMeals = true
            state.step = step
            let restored = OnboardingState(defaults: defaults)
            restored.restoreCheckpoint(accountID: owner)
            XCTAssertEqual(restored.step, step)
            XCTAssertEqual(restored.heightCm, 167.3)
            XCTAssertEqual(restored.weightKg, 71.25)
            XCTAssertEqual(restored.allergies, [.nuts, .soy])
            XCTAssertTrue(restored.notifyMeals)
            if step > 0 {
                restored.prevStep()
                let again = OnboardingState(defaults: defaults)
                again.restoreCheckpoint(accountID: owner)
                XCTAssertEqual(again.step, step - 1)
            }
        }
    }

    func testBarcodeFixturePreservesUnknownNutrientsAndVolume() throws {
        let data = Data(#"{"status":"found","found":true,"food":{"name":"Milk","barcode":"0036000291452","calories":52,"protein":3.4,"carbs":null,"fat":1.2,"fiber":null,"sugar":0,"sodium":40,"saturated_fat":0.6,"serving_size":"100 ml","source":"openfoodfacts","nutrition_basis":{"amount":100,"unit":"ml"}}}"#.utf8)
        let response = try JSONDecoder().decode(BarcodeLookupResponse.self, from: data)
        let item = try XCTUnwrap(response.food).toOpenFoodItem()
        XCTAssertEqual(item.nutritionBasis?.unit, "ml")
        XCTAssertTrue(item.missingNutrients.contains("fiber"))
        XCTAssertFalse(item.missingNutrients.contains("sugar"))
        XCTAssertEqual(item.scaled(by: 2.5).sodium, 100)
    }

    func testLostSetupAcknowledgementResolvesUsingStatus() async {
        keychain.saveSession(token: Self.sessionToken(), refreshToken: "fixture-refresh")
        var completionRequests = 0
        StubURLProtocol.handler = { request in
            if request.url?.path == "/api/onboarding/complete" {
                completionRequests += 1
                throw URLError(.networkConnectionLost)
            }
            return (200, Data(#"{"complete":true,"needs_repair":false,"user":{"_id":"a","email":"a@example.test","onboardingCompleted":true},"targets":{"calories":2300,"protein_g":140,"carbs_g":270,"fat_g":70,"fiber_g":30}}"#.utf8))
        }
        let auth = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        let request = OnboardingRequest(age: 30, gender: "male", height: 180, weight: 80, activityLevel: "moderate", goal: "maintain", targetWeight: nil)
        let complete = await auth.completeOnboarding(request, operationID: "saved-operation-1")
        XCTAssertTrue(complete)
        XCTAssertEqual(completionRequests, 1)
        XCTAssertEqual(auth.authState, .authenticated)
    }

    func testUnitsPreserveCanonicalMeasurements() {
        let state = OnboardingState(defaults: defaults)
        state.heightCm = 173.72
        state.weightKg = 83.18
        for _ in 0..<100 { state.useMetric.toggle() }
        XCTAssertEqual(state.heightDisplay, 173.72)
        XCTAssertEqual(state.weightDisplay, 83.18)
        state.weightLbs = 200
        XCTAssertEqual(state.weightKg, 90.718474, accuracy: 0.000001)
        XCTAssertEqual(state.weightLbs, 200, accuracy: 0.000001)
    }

    func testFreshSetupDefaultsToUSUnitsAndPreservesMeasurementsWhenChoosingMetric() throws {
        let state = OnboardingState(defaults: defaults)
        XCTAssertFalse(state.useMetric)
        XCTAssertEqual(state.request().unitSystem, "imperial")
        state.weightLbs = 200
        state.heightFeet = 6
        state.heightInches = 2
        XCTAssertEqual(state.request().weight, 90.718474, accuracy: 0.000001)
        XCTAssertEqual(state.request().height, 187.96, accuracy: 0.000001)
        state.useMetric = true
        XCTAssertEqual(state.request().unitSystem, "metric")
        XCTAssertEqual(state.request().weight, 90.718474, accuracy: 0.000001)
        XCTAssertEqual(state.request().height, 187.96, accuracy: 0.000001)
    }

    func testGuidedSetupKeepsTheExactQuestionAndTrainingAnswersAfterRelaunch() {
        let state = OnboardingState(defaults: defaults)
        state.restoreCheckpoint(accountID: "guided-setup")
        state.name = "Taylor"
        state.physiologicalSex = "female"
        state.experienceLevel = "intermediate"
        state.workoutDaysPerWeek = 4
        state.workoutDays = ["monday", "tuesday", "thursday", "friday"]
        state.equipment = [.dumbbells, .bench]
        state.dietType = "low_fat"
        state.step = 3
        for page in 0...1 {
            XCTAssertEqual(state.planningPage, page)
            let restored = OnboardingState(defaults: defaults)
            restored.restoreCheckpoint(accountID: "guided-setup")
            XCTAssertEqual(restored.step, 3)
            XCTAssertEqual(restored.planningPage, page)
            XCTAssertEqual(restored.questionNumber, 3 + page)
            XCTAssertEqual(restored.request().experienceLevel, "intermediate")
            XCTAssertEqual(restored.request().workoutDaysPerWeek, 4)
            XCTAssertEqual(restored.request().workoutDays, state.workoutDays)
            XCTAssertEqual(Set(restored.request().equipment), ["dumbbells", "bench"])
            XCTAssertEqual(restored.request().dietType, "low_fat")
            if page < 1 { state.nextStep() }
        }
        state.nextStep()
        XCTAssertEqual(state.step, 4)
        XCTAssertEqual(state.questionNumber, 5)
        XCTAssertEqual(state.questionCount, 5)
        state.prevStep()
        XCTAssertEqual(state.step, 3)
        XCTAssertEqual(state.planningPage, 1)
        state.prevStep()
        XCTAssertEqual(state.step, 3)
        XCTAssertEqual(state.planningPage, 0)
    }

    func testFirstPageAsksNameAndMeasurementsTogetherAndChecksBoth() {
        let state = OnboardingState(defaults: defaults)
        state.restoreCheckpoint(accountID: "about-you")
        XCTAssertTrue(state.isFirstPage)
        state.name = "Taylor"
        state.continueFromAboutYou()
        XCTAssertEqual(state.step, 0, "Missing sex keeps the person on the first page")
        XCTAssertNotNil(state.validationError)
        state.physiologicalSex = "female"
        state.continueFromAboutYou()
        XCTAssertEqual(state.step, 2)
        XCTAssertNil(state.validationError)
        XCTAssertEqual(state.questionNumber, 2)
        state.prevStep()
        XCTAssertEqual(state.step, 1)
        XCTAssertTrue(state.isFirstPage, "Steps 0 and 1 are one page, so it has no back button")
        state.name = " "
        state.continueFromAboutYou()
        XCTAssertEqual(state.step, 1)
        XCTAssertEqual(state.validationError, "Enter your name.")
    }

    func testManualTargetsAreCheckedOnTheReview() {
        let state = OnboardingState(defaults: defaults)
        state.restoreCheckpoint(accountID: "manual-review")
        state.manualTargetMode = true
        state.manualTargets.calories = 500
        XCTAssertNil(state.errorForStep(1), "Own targets don't need the estimate's sex")
        XCTAssertNotNil(state.errorForStep(4))
        state.manualTargets.calories = 2100
        XCTAssertNil(state.errorForStep(4))
    }

    func testChoosingAGoalSuggestsATargetWeightOnTheRightSide() {
        let state = OnboardingState(defaults: defaults)
        state.weightKg = 90
        state.targetWeightKg = 95
        state.goal = .loseWeight
        state.suggestTargetWeight()
        XCTAssertLessThan(state.targetWeightKg, 90)
        state.targetWeightKg = 85
        state.suggestTargetWeight()
        XCTAssertEqual(state.targetWeightKg, 85, "A target already on the right side is kept")
        state.goal = .gainMuscle
        state.suggestTargetWeight()
        XCTAssertGreaterThan(state.targetWeightKg, 90)
    }

    func testOptionalProfilePreferencesDoNotReplaceExplicitManualTargets() {
        let state = OnboardingState(defaults: defaults)
        state.restoreCheckpoint(accountID: "manual-setup")
        state.name = "Taylor"
        state.manualTargetMode = true
        state.manualTargets = SetupTargets(calories: 2345.5, protein_g: 143.25, carbs_g: 220, fat_g: 71.5)
        state.workoutDaysPerWeek = 0
        state.dietaryStyle = .vegetarian
        state.dietType = "low_fat"
        let restored = OnboardingState(defaults: defaults)
        restored.restoreCheckpoint(accountID: "manual-setup")
        XCTAssertEqual(restored.request().targetMode, "manual")
        XCTAssertEqual(restored.request().manualTargets, state.manualTargets)
        XCTAssertEqual(restored.request().workoutDaysPerWeek, 0)
        XCTAssertEqual(restored.request().dietaryStyle, "vegetarian")
        XCTAssertEqual(restored.request().unitSystem, "imperial")
        XCTAssertEqual(restored.request().gender, "other", "A new profile must not invent a gender identity")
    }

    func testLegacySetupDraftMigratesWithoutLosingPersonalization() throws {
        let productionAPI = APIClient(baseURL: "https://exerly-fitness-93dyl.ondigitalocean.app", keychain: keychain, defaults: defaults)
        let state = OnboardingState(defaults: defaults, api: productionAPI)
        state.name = "Taylor"
        state.physiologicalSex = "female"
        state.allergies = [.nuts, .soy]
        state.notifyMeals = true
        var draft = OnboardingDraft(accountID: "legacy", step: 9, answers: state.request(), operationID: "legacy-submit")
        draft.schemaVersion = 1
        defaults.set(try JSONEncoder().encode(draft), forKey: "onboarding.draft.v1.legacy")
        let migrated = OnboardingState(defaults: defaults, api: productionAPI)
        migrated.restoreCheckpoint(accountID: "legacy")
        XCTAssertEqual(migrated.step, 3)
        XCTAssertEqual(migrated.allergies, [.nuts, .soy])
        XCTAssertTrue(migrated.notifyMeals)
        XCTAssertEqual(migrated.operationID, "legacy-submit")
    }

    func testRefreshRetainsItsOperationAfterLostAcknowledgement() async throws {
        let original = Self.sessionToken(sessionID: "old-session")
        let renewed = Self.sessionToken()
        keychain.saveSession(token: original, refreshToken: "old-refresh")
        var operations: [String] = []
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/auth/token")
            operations.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
            if operations.count == 1 { throw URLError(.networkConnectionLost) }
            return (200, Data("{\"token\":\"\(renewed)\",\"refreshToken\":\"new-refresh\",\"user\":{\"_id\":\"a\",\"email\":\"a@example.test\"}}".utf8))
        }
        do { _ = try await api.refreshSession(); XCTFail("Expected lost acknowledgement") } catch {}
        XCTAssertEqual(keychain.getRefreshToken(), "old-refresh")
        _ = try await api.refreshSession()
        XCTAssertEqual(operations.count, 2)
        XCTAssertEqual(operations[0], operations[1])
        XCTAssertEqual(keychain.getToken(), renewed)
        XCTAssertEqual(keychain.getRefreshToken(), "new-refresh")
    }

    nonisolated private static func sessionToken(accountID: String? = "a", email: String = "a@example.test", sessionID: String? = "test-session") -> String {
        var claims = ["email": email]
        claims["sub"] = accountID
        claims["sid"] = sessionID
        let data = try! JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).fixture"
    }

    func testLegacyStartupUpgradesBeforeAccountOwnedRequestsAndKeepsOneSession() async throws {
        let legacy = Self.sessionToken(accountID: nil, sessionID: nil)
        let modern = Self.sessionToken()
        keychain.saveToken(legacy)
        let user = UserDTO(id: "a", email: "a@example.test", onboardingCompleted: true)
        let userJSON = String(data: try JSONEncoder().encode(user), encoding: .utf8)!
        var paths: [String] = []
        StubURLProtocol.handler = { request in
            paths.append(request.url!.path)
            if request.url?.path == "/auth/refresh" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(legacy)")
                return (200, Data("{\"token\":\"\(modern)\",\"refreshToken\":\"upgrade-refresh\",\"user\":\(userJSON)}".utf8))
            }
            if request.url?.path == "/api/bootstrap" {
                return (200, Data("{\"account\":\(userJSON),\"account_id\":\"a\",\"onboarding\":{\"complete\":true,\"needs_repair\":false,\"user\":\(userJSON)}}".utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(modern)")
            return (200, Data(#"{"message":"Saved"}"#.utf8))
        }
        let auth = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        await auth.checkAuth()
        XCTAssertEqual(auth.authState, .authenticated)
        XCTAssertEqual(keychain.getRefreshToken(), "upgrade-refresh")
        let _: APIMessageResponse = try await api.request("POST", path: "/api/food", operationID: "legacy-food-recovery", expectedAccountID: "a")
        await auth.checkAuth()
        XCTAssertEqual(paths.first, "/auth/refresh")
        XCTAssertEqual(paths.filter { $0 == "/auth/refresh" }.count, 1)
    }

    func testLegacyRefreshReplaysTheSameOperationAfterRelaunch() async throws {
        let legacy = Self.sessionToken(accountID: nil, sessionID: nil)
        let modern = Self.sessionToken()
        keychain.saveToken(legacy)
        var operations: [String] = []
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/auth/refresh")
            operations.append(request.value(forHTTPHeaderField: "Idempotency-Key") ?? "")
            if operations.count == 1 { throw URLError(.networkConnectionLost) }
            return (200, Data("{\"token\":\"\(modern)\",\"refreshToken\":\"upgrade-refresh\",\"user\":{\"_id\":\"a\",\"email\":\"a@example.test\"}}".utf8))
        }
        do { _ = try await api.refreshSession(); XCTFail("Expected lost response") } catch {}
        XCTAssertEqual(keychain.getToken(), legacy)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let reopened = APIClient(baseURL: "https://fixture.exerly.test", session: URLSession(configuration: config), keychain: keychain, defaults: defaults)
        _ = try await reopened.refreshSession()
        XCTAssertEqual(operations.count, 2)
        XCTAssertFalse(operations[0].isEmpty)
        XCTAssertEqual(operations[0], operations[1])
    }

    func testRefreshFollowedByOutageKeepsCachedAccountAcrossRelaunch() async {
        let original = Self.sessionToken(sessionID: "old-session")
        let renewed = Self.sessionToken()
        keychain.saveSession(token: original, refreshToken: "old-refresh")
        let account = #"{"_id":"a","email":"a@example.test","name":"Taylor","onboardingCompleted":true}"#
        StubURLProtocol.handler = { _ in
            (200, Data("{\"account\":\(account),\"account_id\":\"a\",\"onboarding\":{\"complete\":true,\"needs_repair\":false,\"user\":\(account)}}".utf8))
        }
        let auth = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        await auth.checkAuth()
        StubURLProtocol.handler = { request in
            if request.url?.path == "/auth/token" {
                return (200, Data("{\"token\":\"\(renewed)\",\"refreshToken\":\"new-refresh\",\"user\":\(account)}".utf8))
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer \(original)" { return (401, Data("{}".utf8)) }
            throw URLError(.notConnectedToInternet)
        }
        await auth.checkAuth()
        XCTAssertTrue(auth.isOffline)
        XCTAssertEqual(auth.authState, .authenticated)
        let relaunched = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        await relaunched.checkAuth()
        XCTAssertEqual(relaunched.currentUser?.id, "a")
        XCTAssertEqual(relaunched.authState, .authenticated)
        XCTAssertEqual(keychain.getToken(), renewed)
    }

    func testLegacyUpgradeOutagePreservesCachedAccountAndCopiesItAfterRotation() async throws {
        let legacy = Self.sessionToken(accountID: nil, sessionID: nil)
        let modern = Self.sessionToken()
        keychain.saveToken(legacy)
        let user = UserDTO(id: "a", email: "a@example.test", name: "Cached Taylor", onboardingCompleted: true)
        let encoded = try JSONEncoder().encode(user)
        defaults.set(encoded, forKey: APIClient.accountCacheKey(legacy))
        defaults.set(true, forKey: APIClient.accountCacheKey(legacy) + ".complete")
        var operations: [String] = []
        var offline = true
        StubURLProtocol.handler = { request in
            if request.url?.path == "/auth/refresh" {
                operations.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
                if !offline {
                    return (200, Data("{\"token\":\"\(modern)\",\"refreshToken\":\"upgraded-refresh\",\"user\":\(String(data: encoded, encoding: .utf8)!)}".utf8))
                }
            }
            throw URLError(.notConnectedToInternet)
        }
        let first = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        await first.checkAuth()
        XCTAssertTrue(first.isOffline)
        XCTAssertEqual(first.authState, .authenticated)
        XCTAssertEqual(first.currentUser?.id, "a")
        XCTAssertEqual(keychain.getToken(), legacy)
        offline = false
        await first.checkAuth()
        XCTAssertTrue(first.isOffline, "A failed bootstrap still leaves the verified cached account available")
        XCTAssertEqual(keychain.getToken(), modern)
        XCTAssertEqual(operations.count, 2)
        XCTAssertEqual(operations[0], operations[1])
        let reopened = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        await reopened.checkAuth()
        XCTAssertEqual(reopened.authState, .authenticated)
        XCTAssertEqual(reopened.currentUser?.name, "Cached Taylor")
        XCTAssertTrue(reopened.isOffline)
    }

    func testRefreshRejectsUnverifiedResponsesAndPreservesOperationUntilKeychainSave() async throws {
        for legacy in [false, true] {
            let original = Self.sessionToken(accountID: legacy ? nil : "a", sessionID: legacy ? nil : "original")
            let modern = Self.sessionToken()
            keychain.saveSession(token: original, refreshToken: legacy ? nil : "original-refresh")
            var operations: [String] = []
            var responseIndex = 0
            let responses = [
                "{\"token\":\"\(modern)\",\"user\":{\"_id\":\"a\",\"email\":\"a@example.test\"}}",
                "{\"token\":\"\(Self.sessionToken(accountID: "b", email: "b@example.test"))\",\"refreshToken\":\"wrong-owner\",\"user\":{\"_id\":\"b\",\"email\":\"b@example.test\"}}",
                "{\"token\":\"\(modern)\",\"refreshToken\":\"new-refresh\",\"user\":{\"_id\":\"a\",\"email\":\"a@example.test\"}}"
            ]
            StubURLProtocol.handler = { request in
                operations.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
                return (200, Data(responses[responseIndex].utf8))
            }
            for index in 0..<3 {
                responseIndex = index
                keychain.rejectWrites = index == 2
                do { _ = try await api.refreshSession(); XCTFail("Expected response or storage rejection") } catch {}
                XCTAssertEqual(keychain.getToken(), original)
                XCTAssertEqual(keychain.getRefreshToken(), legacy ? nil : "original-refresh")
            }
            keychain.rejectWrites = false
            _ = try await api.refreshSession()
            XCTAssertEqual(keychain.getToken(), modern)
            XCTAssertEqual(keychain.getRefreshToken(), "new-refresh")
            XCTAssertEqual(operations.count, 4)
            XCTAssertTrue(operations.allSatisfy { $0 == operations.first })
        }
    }

    func testConcurrentUpgradeAndLateResponseStayWithTheirOriginalAccount() async throws {
        let original = Self.sessionToken(accountID: nil, sessionID: nil)
        let ownerB = Self.sessionToken(accountID: "b", email: "b@example.test", sessionID: "b-original")
        let renewedB = Self.sessionToken(accountID: "b", email: "b@example.test", sessionID: "b-renewed")
        keychain.saveToken(original)
        let received = expectation(description: "Legacy upgrade started")
        var upgrades = 0
        StubURLProtocol.handler = { request in
            if request.url?.path == "/auth/refresh" {
                upgrades += 1
                received.fulfill()
                return (200, Data("{\"token\":\"\(Self.sessionToken())\",\"refreshToken\":\"a-refresh\",\"user\":{\"_id\":\"a\",\"email\":\"a@example.test\"}}".utf8))
            }
            return (200, Data("{\"token\":\"\(renewedB)\",\"refreshToken\":\"b-renewed-refresh\",\"user\":{\"_id\":\"b\",\"email\":\"b@example.test\"}}".utf8))
        }
        StubURLProtocol.responseDelay = { $0.url?.path == "/auth/refresh" ? 0.5 : 0 }
        let first = Task { try await api.refreshSession() }
        let second = Task { try await api.refreshSession() }
        await fulfillment(of: [received], timeout: 2)
        // Both consumers have had a chance to join the shared request.
        try await Task.sleep(for: .milliseconds(50))
        keychain.deleteToken()
        keychain.saveSession(token: ownerB, refreshToken: "b-original-refresh")
        _ = try await api.refreshSession()
        for pending in [first, second] {
            do { _ = try await pending.value; XCTFail("Old response must be ignored") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(upgrades, 1)
        XCTAssertEqual(keychain.getToken(), renewedB)
        XCTAssertEqual(keychain.getRefreshToken(), "b-renewed-refresh")
    }

    func testDelayedLoginCannotRestoreASignedOutAccount() async throws {
        let received = expectation(description: "Login started")
        StubURLProtocol.handler = { _ in
            received.fulfill()
            return (200, Data("{\"token\":\"\(Self.sessionToken())\",\"refreshToken\":\"login-refresh\",\"user\":{\"_id\":\"a\",\"email\":\"a@example.test\"}}".utf8))
        }
        StubURLProtocol.responseDelay = { _ in 0.25 }
        let auth = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        let pending = Task { await auth.login(email: "a@example.test", password: "fixture-password") }
        await fulfillment(of: [received], timeout: 2)
        auth.logout()
        await pending.value
        XCTAssertNil(keychain.getToken())
        XCTAssertNil(auth.currentUser)
        XCTAssertEqual(auth.authState, .unauthenticated)
    }

    func testRefreshDoesNotSendUntilItsOperationCanBeStored() async throws {
        let blocked = RefusingSessionDefaults(suiteName: "exerly.tests.storage.\(UUID().uuidString)")!
        let token = Self.sessionToken(accountID: nil, sessionID: nil)
        keychain.saveToken(token)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let isolated = APIClient(baseURL: "https://fixture.exerly.test", session: URLSession(configuration: config), keychain: keychain, defaults: blocked)
        var requests = 0
        StubURLProtocol.handler = { _ in
            requests += 1
            return (200, Data("{\"token\":\"\(Self.sessionToken())\",\"refreshToken\":\"recovered-refresh\",\"user\":{\"_id\":\"a\",\"email\":\"a@example.test\"}}".utf8))
        }
        do { _ = try await isolated.refreshSession(); XCTFail("Expected storage failure") }
        catch APIError.sessionStorage {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(keychain.getToken(), token)
        blocked.refuseOperations = false
        _ = try await isolated.refreshSession()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(keychain.getRefreshToken(), "recovered-refresh")
    }

    func testBootstrapCannotCacheADifferentAccountOrSetupOwner() async throws {
        let token = Self.sessionToken()
        keychain.saveSession(token: token, refreshToken: "owner-refresh")
        for mismatch in ["account", "setup", "envelope"] {
            let accountID = mismatch == "account" ? "b" : "a"
            let setupID = mismatch == "setup" ? "b" : "a"
            let envelopeID = mismatch == "envelope" ? "b" : "a"
            StubURLProtocol.handler = { _ in
                (200, Data("{\"account_id\":\"\(envelopeID)\",\"account\":{\"_id\":\"\(accountID)\",\"email\":\"a@example.test\"},\"onboarding\":{\"complete\":true,\"needs_repair\":false,\"user\":{\"_id\":\"\(setupID)\",\"email\":\"a@example.test\"}}}".utf8))
            }
            let auth = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
            await auth.checkAuth()
            XCTAssertEqual(auth.authState, .connectionFailed)
            XCTAssertNil(auth.currentUser)
            XCTAssertNil(defaults.data(forKey: APIClient.accountCacheKey(token)))
            XCTAssertEqual(keychain.getToken(), token)
        }
    }

    func testSetupAcknowledgementAndRecoveryStatusCannotAcceptADifferentOwner() async {
        keychain.saveSession(token: Self.sessionToken(), refreshToken: "owner-refresh")
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"complete":true,"needs_repair":false,"user":{"_id":"b","email":"b@example.test","onboardingCompleted":true},"targets":{"calories":2300,"protein_g":140,"carbs_g":270,"fat_g":70,"fiber_g":30}}"#.utf8))
        }
        let auth = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        let payload = OnboardingRequest(age: 30, gender: "male", height: 180, weight: 80, activityLevel: "moderate", goal: "maintain", targetWeight: nil)
        let accepted = await auth.completeOnboarding(payload, operationID: "wrong-owner-setup-response")
        XCTAssertFalse(accepted)
        XCTAssertNil(auth.currentUser)
        XCTAssertNil(defaults.data(forKey: APIClient.accountCacheKey(Self.sessionToken())))
    }

    func testDraftOwnershipAndInvalidStepRecovery() {
        let a = OnboardingState(defaults: defaults)
        a.restoreCheckpoint(accountID: "a")
        a.name = "Private name"
        a.step = 4
        let b = OnboardingState(defaults: defaults)
        b.restoreCheckpoint(accountID: "b")
        XCTAssertEqual(b.name, "")
        let resumed = OnboardingState(defaults: defaults)
        resumed.restoreCheckpoint(accountID: "a")
        XCTAssertEqual(resumed.step, 1, "Missing physiology must return to the required question")
    }

    func testSubmissionIdentitySurvivesRelaunchAndChangesOnlyWithPayload() {
        let first = OnboardingState(defaults: defaults)
        first.restoreCheckpoint(accountID: "a")
        first.name = "Taylor"
        _ = first.prepareSubmission()
        let operation = first.operationID
        let next = OnboardingState(defaults: defaults)
        next.restoreCheckpoint(accountID: "a")
        _ = next.prepareSubmission()
        XCTAssertEqual(next.operationID, operation)
        next.weightKg += 1
        _ = next.prepareSubmission()
        XCTAssertNotEqual(next.operationID, operation)
    }

    func testFreshDraftStillSuggestsNutritionGoalAfterRelaunchUntilExplicitlyChosen() {
        let first = OnboardingState(defaults: defaults)
        first.restoreCheckpoint(accountID: "a")
        first.name = "Taylor"
        first.physiologicalSex = "female"
        let resumed = OnboardingState(defaults: defaults)
        resumed.restoreCheckpoint(accountID: "a")
        resumed.goal = .loseWeight
        XCTAssertEqual(resumed.nutritionGoal, "lose")
        resumed.nutritionGoalChoice = "maintain"
        let again = OnboardingState(defaults: defaults)
        again.restoreCheckpoint(accountID: "a")
        again.goal = .gainMuscle
        XCTAssertEqual(again.nutritionGoal, "maintain")
        XCTAssertEqual(again.request().nutritionGoalFollowsFitness, false)
    }

    func testDraftUploadSurvivesLostAcknowledgementAndLaterLocalEdit() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let first = OnboardingState(defaults: defaults, api: api)
        first.restoreCheckpoint(accountID: "a")
        first.name = "Taylor"
        var remote: [String: Any]?
        var keys: [String] = []
        var bodies: [Data] = []
        StubURLProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                let data = Self.requestBody(request)
                bodies.append(data)
                keys.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
                if keys.count != 2 {
                    var row = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    row["account_id"] = "a"
                    row["revision"] = (row["revision"] as! Int) + 1
                    remote = row
                }
                if keys.count == 1 { throw URLError(.networkConnectionLost) }
            }
            return (200, try JSONSerialization.data(withJSONObject: ["draft": remote as Any? ?? NSNull()]))
        }
        let firstResult = await first.syncCloud()
        XCTAssertFalse(firstResult)
        let resumed = OnboardingState(defaults: defaults, api: api)
        resumed.restoreCheckpoint(accountID: "a")
        resumed.weightKg = 83.75
        let recovered = await resumed.syncCloud()
        XCTAssertTrue(recovered)
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(keys[0], keys[1])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: bodies[0]) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: bodies[1]) as? NSDictionary)
        XCTAssertNotEqual(keys[1], keys[2])
        XCTAssertEqual(resumed.prepareSubmission().draftRevision, 2)
        XCTAssertEqual((remote?["answers"] as? [String: Any])?["weight"] as? Double, 83.75)
    }

    func testCloudDraftRecoveryAndConflictingDeviceEditsRequireChoice() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let first = OnboardingState(defaults: defaults, api: api)
        first.restoreCheckpoint(accountID: "a")
        first.name = "Taylor"
        first.physiologicalSex = "female"
        var remote: [String: Any]?
        var writes = 0
        StubURLProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                writes += 1
                var row = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: Any])
                XCTAssertEqual(row["revision"] as? Int, remote?["revision"] as? Int ?? 0)
                row["revision"] = (row["revision"] as! Int) + 1
                row["account_id"] = "a"
                remote = row
            }
            return (200, try JSONSerialization.data(withJSONObject: ["draft": remote as Any? ?? NSNull()]))
        }
        let uploaded = await first.syncCloud()
        XCTAssertTrue(uploaded)
        var answers = try XCTUnwrap(remote?["answers"] as? [String: Any])
        answers["weight"] = 91.25
        remote?["answers"] = answers
        remote?["revision"] = 2
        first.weightKg = 80.5
        let conflict = await first.syncCloud()
        XCTAssertFalse(conflict)
        XCTAssertNotNil(first.cloudConflict)
        XCTAssertEqual(writes, 1, "Both edited copies must survive until the user chooses")
        let otherDefaults = UserDefaults(suiteName: "exerly.tests.\(UUID().uuidString)")!
        let second = OnboardingState(defaults: otherDefaults, api: api)
        second.restoreCheckpoint(accountID: "a")
        let recovered = await second.syncCloud()
        XCTAssertTrue(recovered)
        XCTAssertEqual(second.weightKg, 91.25)
        XCTAssertEqual(second.name, "Taylor")
        XCTAssertEqual(writes, 1, "A new device adopts the server draft without rewriting it")
        await first.resolveCloudConflict(useServer: false)
        XCTAssertNil(first.cloudConflict)
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(first.prepareSubmission().draftRevision, 3)
        XCTAssertEqual((remote?["answers"] as? [String: Any])?["weight"] as? Double, 80.5)
        let refreshed = await second.syncCloud()
        XCTAssertTrue(refreshed)
        XCTAssertEqual(second.weightKg, 80.5)
    }

    func testLegacyTargetWithoutFiberKeepsUnknownValue() throws {
        let data = Data(#"{"calories":2200,"protein_g":120,"carbs_g":260,"fat_g":70}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SetupTargets.self, from: data).fiber_g)
    }

    func testBrowserDraftPreservesIndependentGoalsUnknownPreferencesAndSleepTimes() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let payload = Data(#"{"account_id":"a","schema_version":2,"last_valid_step":4,"revision":1,"answers":{"name":"Browser Taylor","age":34,"gender":"nonbinary","sex":null,"height":167.5,"weight":72.25,"goal":"gain_muscle","nutritionGoal":"lose","targetWeight":68.5,"activityLevel":"light","targetMode":"manual","manualTargets":{"calories":2180,"protein_g":133,"carbs_g":246,"fat_g":66,"fiber_g":27},"timezone":"America/New_York","unitSystem":"metric","experienceLevel":"intermediate","workoutDaysPerWeek":4,"equipmentAccess":"bodyweight","equipment":["bodyweight","rings"],"activityTypes":["hiking","rowing"],"dietaryStyle":"mediterranean","allergies":["sesame","nuts"],"mealsPerDay":4,"sleepGoalHours":7.25,"bedtime":"22:45","wakeTime":"06:15","workoutDays":["monday","wednesday","friday","sunday"],"timelineWeeks":16,"reminders":{"meals":true,"workouts":false,"sleep":true},"rateKgPerWeek":-0.2,"dietType":"balanced"}}"#.utf8)
        let remote = try JSONSerialization.jsonObject(with: payload)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET", "Adopting a cloud draft must not rewrite its answers")
            return (200, try JSONSerialization.data(withJSONObject: ["draft": remote]))
        }
        let state = OnboardingState(defaults: defaults, api: api)
        state.restoreCheckpoint(accountID: "a")
        let synced = await state.syncCloud()
        XCTAssertTrue(synced)
        XCTAssertEqual(state.step, 4)
        let expected = try JSONDecoder().decode(SetupCloudDraft.self, from: payload).answers
        func assertPreferences(_ answer: OnboardingRequest) {
            XCTAssertEqual(answer.nutritionGoal, "lose")
            XCTAssertEqual(answer.goal, "gain_muscle")
            XCTAssertEqual(answer.gender, "nonbinary")
            XCTAssertEqual(answer.equipmentAccess, "bodyweight")
            XCTAssertEqual(answer.equipment, expected.equipment)
            XCTAssertEqual(answer.activityTypes, expected.activityTypes)
            XCTAssertEqual(answer.allergies, expected.allergies)
            XCTAssertEqual(answer.dietaryStyle, "mediterranean")
            XCTAssertEqual(answer.bedtime, "22:45")
            XCTAssertEqual(answer.wakeTime, "06:15")
            XCTAssertEqual(answer.manualTargets, expected.manualTargets)
        }
        assertPreferences(state.request())
        state.name = "Native Taylor"
        let reopened = OnboardingState(defaults: defaults, api: api)
        reopened.restoreCheckpoint(accountID: "a")
        assertPreferences(reopened.request())
        reopened.allergies.remove(.nuts)
        XCTAssertEqual(reopened.request().allergies, ["sesame"])
        reopened.wakeMinute = 30
        XCTAssertEqual(reopened.request().bedtime, "23:15")
        XCTAssertEqual(reopened.request().wakeTime, "06:30")
        reopened.dietaryStyle = .standard
        XCTAssertEqual(reopened.request().dietaryStyle, "standard")
        reopened.nutritionGoalChoice = "maintain"
        XCTAssertEqual(reopened.request().nutritionGoal, "maintain")
        XCTAssertNil(reopened.request().targetWeight)
    }

    func testLegacyRepairAsksOnlyForMissingStepsAndPreservesSavedPreferences() throws {
        let data = Data(#"{"complete":false,"needs_repair":true,"user":{"_id":"a","email":"a@example.test"},"repair_answers":{"name":"Taylor","age":34,"gender":"female","sex":"female","height":167.5,"weight":72.25,"goal":"maintain","timezone":"Europe/London","experienceLevel":"advanced","workoutDaysPerWeek":4,"workoutDays":["monday","wednesday"],"allergies":["nuts"]}}"#.utf8)
        let status = try JSONDecoder().decode(SetupStatus.self, from: data)
        let state = OnboardingState(defaults: defaults)
        state.restoreCheckpoint(accountID: "a", repair: status)
        XCTAssertEqual(state.visibleSteps, [3, 4])
        XCTAssertEqual(state.step, 3)
        XCTAssertNotNil(state.errorForStep(3))
        XCTAssertEqual(state.request().activityLevel, "", "An unknown activity level must not become a moderate default")
        state.activityLevel = .light
        state.nextStep()
        XCTAssertEqual(state.step, 4)
        let restored = OnboardingState(defaults: defaults)
        restored.restoreCheckpoint(accountID: "a", repair: status)
        XCTAssertEqual(restored.visibleSteps, [3, 4])
        XCTAssertEqual(restored.step, 4)
        XCTAssertEqual(restored.weightKg, 72.25)
        XCTAssertEqual(restored.activityLevel, .light)
        XCTAssertEqual(restored.request().timezone, "Europe/London")
        XCTAssertEqual(restored.request().experienceLevel, "advanced")
        XCTAssertEqual(restored.request().workoutDays, ["monday", "wednesday"])
        XCTAssertEqual(restored.allergies, [.nuts])
    }

    func testLegacyRepairDoesNotInventMissingMeasurements() throws {
        let data = Data(#"{"complete":false,"needs_repair":true,"user":{"_id":"a","email":"a@example.test"},"repair_answers":{"name":"Taylor","gender":"other","goal":"maintain","activityLevel":"light"}}"#.utf8)
        let status = try JSONDecoder().decode(SetupStatus.self, from: data)
        let state = OnboardingState(defaults: defaults)
        state.restoreCheckpoint(accountID: "a", repair: status)
        XCTAssertEqual(state.visibleSteps, [1, 4])
        XCTAssertEqual(state.age, 0)
        XCTAssertEqual(state.heightCm, 0)
        XCTAssertEqual(state.weightKg, 0)
        XCTAssertEqual(state.physiologicalSex, "")
        XCTAssertNotNil(state.errorForStep(1))
    }

    func testFreshLoginWaitsForBootstrapBeforeOpeningAnUnverifiedLegacyAccount() async {
        let token = Self.sessionToken()
        StubURLProtocol.handler = { request in
            if request.url?.path == "/login" {
                return (200, Data("{\"token\":\"\(token)\",\"refreshToken\":\"login-refresh\",\"user\":{\"_id\":\"a\",\"email\":\"a@example.test\",\"onboardingCompleted\":true}}".utf8))
            }
            throw URLError(.notConnectedToInternet)
        }
        let auth = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        await auth.login(email: "a@example.test", password: "password")
        XCTAssertEqual(auth.authState, .connectionFailed)
        XCTAssertEqual(keychain.getToken(), token)
        XCTAssertNil(defaults.data(forKey: APIClient.accountCacheKey(token)), "An unverified bootstrap must not become a completed cached account")
    }

    func testSetupDraftsAreIsolatedByAPIEnvironmentEvenWhenAccountIDsMatch() throws {
        let productionAPI = APIClient(baseURL: "https://exerly-fitness-93dyl.ondigitalocean.app", keychain: keychain, defaults: defaults)
        let production = OnboardingState(defaults: defaults, api: productionAPI)
        production.restoreCheckpoint(accountID: "same-id")
        production.name = "Production person"
        let staging = OnboardingState(defaults: defaults, api: api)
        staging.restoreCheckpoint(accountID: "same-id")
        XCTAssertEqual(staging.name, "")
        staging.name = "Staging person"
        let reopened = OnboardingState(defaults: defaults, api: productionAPI)
        reopened.restoreCheckpoint(accountID: "same-id")
        XCTAssertEqual(reopened.name, "Production person")
        var legacy = OnboardingDraft(accountID: "legacy-id", step: 0, answers: production.request(), operationID: "old")
        legacy.answers.name = "Legacy production person"
        defaults.set(try JSONEncoder().encode(legacy), forKey: "onboarding.draft.v1.legacy-id")
        let stagingLegacy = OnboardingState(defaults: defaults, api: api)
        stagingLegacy.restoreCheckpoint(accountID: "legacy-id")
        XCTAssertEqual(stagingLegacy.name, "")
        XCTAssertNotNil(defaults.data(forKey: "onboarding.draft.v1.legacy-id"), "Staging must preserve unknown legacy records without adopting them")
    }

    nonisolated private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    func testMutationsAreNotAutomaticallyRetriedAfterAnUnreadableAcknowledgement() async {
        keychain.saveSession(token: "current-token", refreshToken: "fixture-refresh")
        var attempts = 0
        StubURLProtocol.handler = { request in
            attempts += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "persistent-operation-1")
            return (200, Data("unreadable".utf8))
        }
        do {
            let _: APIMessageResponse = try await api.post("/api/food", operationID: "persistent-operation-1")
            XCTFail("Expected decoding failure")
        } catch { XCTAssertEqual(attempts, 1) }
    }

    func testStartupNetworkFailureKeepsTokenAndCachedAccount() async {
        keychain.saveSession(token: Self.sessionToken(), refreshToken: "fixture-refresh")
        let account = #"{"_id":"a","email":"a@example.test","name":"Taylor","onboardingCompleted":true}"#
        StubURLProtocol.handler = { _ in
            (200, Data("{\"account\":\(account),\"account_id\":\"a\",\"onboarding\":{\"complete\":true,\"needs_repair\":false,\"user\":\(account)}}".utf8))
        }
        let first = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        await first.checkAuth()
        XCTAssertEqual(first.authState, .authenticated)
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let next = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        await next.checkAuth()
        XCTAssertEqual(next.authState, .authenticated)
        XCTAssertTrue(next.isOffline)
        XCTAssertEqual(next.currentUser?.id, "a")
        XCTAssertEqual(keychain.getToken(), Self.sessionToken())
    }

    func testNoCacheOfflineStartupOffersRetryWithoutDeletingSession() async {
        keychain.saveSession(token: "saved-token", refreshToken: "fixture-refresh")
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let auth = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        await auth.checkAuth()
        XCTAssertEqual(auth.authState, .connectionFailed)
        XCTAssertEqual(keychain.getToken(), "saved-token")
    }

    func testLateUnauthorizedResponseCannotEraseNewCredentials() async {
        keychain.saveSession(token: "old-token", refreshToken: "fixture-refresh")
        let credentials = keychain!
        StubURLProtocol.handler = { _ in
            credentials.saveSession(token: "new-token", refreshToken: "fixture-refresh")
            return (401, Data("{}".utf8))
        }
        do {
            let _: APIMessageResponse = try await api.get("/api/me")
            XCTFail("Old response should be cancelled")
        } catch is CancellationError {
            XCTAssertEqual(keychain.getToken(), "new-token")
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testOfflineEntriesSurviveStoreReopeningAndStayAccountScoped() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        engine.configure(container: container, accountID: "a")
        let day = testToday.rawValue
        StubURLProtocol.handler = { _ in (200, self.emptyDiary(day)) }
        _ = try await engine.diary(for: testToday)
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        var entry = FoodRequest(name: "First food", calories: 60, protein: 2, carbs: 8, fat: 2, sugar: nil, mealType: "dinner", barcode: nil, brand: nil, fiber: nil, servingSize: "100 ml")
        entry.servings = 1.5
        entry.entryDate = day
        try engine.saveFood(entry)
        try engine.saveFood(entry)
        XCTAssertEqual(engine.pendingCount, 2)
        await engine.synchronize()
        let reopened = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        reopened.configure(container: container, accountID: "a")
        let local = try await reopened.diary(for: testToday)
        XCTAssertEqual(local.meals["dinner"]?.entries.count, 2)
        XCTAssertEqual(local.consumed.calories, 180)
        XCTAssertEqual(reopened.pendingCount, 2)
        reopened.configure(container: container, accountID: "b")
        XCTAssertEqual(reopened.pendingCount, 0)
        do { _ = try await reopened.diary(for: testToday); XCTFail("Another account must not see this cache") } catch {}
    }

    func testLostFoodAcknowledgementReplaysBeforeDependentEdit() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        engine.configure(container: container, accountID: "a")
        let day = testToday.rawValue
        StubURLProtocol.handler = { _ in (200, self.emptyDiary(day)) }
        _ = try await engine.diary(for: testToday)
        var entry = FoodRequest(name: "Drink", calories: 60, protein: 2, carbs: 8, fat: 2, sugar: nil, mealType: "dinner", barcode: nil, brand: nil, fiber: nil, servingSize: "100 ml")
        entry.servings = 1.5
        entry.entryDate = day
        let entityID = try engine.saveFood(entry)
        var operationKeys: [String] = []
        StubURLProtocol.handler = { request in
            if request.url?.path == "/api/food" {
                operationKeys.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
                if operationKeys.count == 1 { throw URLError(.networkConnectionLost) }
                return (200, Data("{\"id\":\"10\",\"client_id\":\"\(entityID)\",\"revision\":1,\"name\":\"Drink\",\"calories\":90,\"servings\":1.5,\"entry_date\":\"\(day)\",\"meal_type\":\"dinner\"}".utf8))
            }
            if request.url?.path == "/api/food/10" {
                XCTAssertEqual(request.httpMethod, "PUT")
                return (200, Data("{\"id\":\"10\",\"client_id\":\"\(entityID)\",\"revision\":2,\"name\":\"Drink\",\"calories\":45,\"servings\":0.75,\"entry_date\":\"\(day)\",\"meal_type\":\"dinner\"}".utf8))
            }
            if request.url?.path == "/api/sync" { return (200, Data(#"{"changes":[],"cursor":0,"has_more":false}"#.utf8)) }
            return (200, self.emptyDiary(day))
        }
        await engine.synchronize()
        let local = try await engine.diary(for: testToday)
        let original = try XCTUnwrap(local.meals["dinner"]?.entries.first)
        entry.servings = 0.75
        try engine.saveFood(entry, editing: original)
        await engine.synchronize(force: true)
        XCTAssertEqual(operationKeys.count, 2)
        XCTAssertEqual(operationKeys[0], operationKeys[1])
        XCTAssertEqual(engine.pendingCount, 0)
        let updated = try await engine.diary(for: testToday)
        XCTAssertEqual(updated.meals["dinner"]?.entries.count, 1)
        XCTAssertEqual(updated.consumed.calories, 45)
    }

    func testVersionedMigrationPreservesExistingStore() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "migration-\(UUID().uuidString).store")
        func createLegacyStore() throws {
            let schema = Schema(versionedSchema: ExerlySchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(Measurement(type: "waist", value: 81.5, unit: "cm"))
            try context.save()
        }
        try createLegacyStore()
        let schema = Schema(versionedSchema: ExerlySchemaV3.self)
        let upgraded = try ModelContainer(for: schema, migrationPlan: ExerlyMigrationPlan.self, configurations: ModelConfiguration(schema: schema, url: url))
        let measurements = try ModelContext(upgraded).fetch(FetchDescriptor<Exerly.Measurement>())
        XCTAssertEqual(measurements.count, 1)
        XCTAssertEqual(measurements.first?.value, 81.5)
    }

    func testWeightWriteReplaysAfterReopeningBeforeSendingALaterEdit() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let date = testToday.adding(days: -1)!
        let day = date.rawValue
        let url = FileManager.default.temporaryDirectory.appending(path: "weights-\(UUID().uuidString).store")
        let schema = Schema(versionedSchema: ExerlySchemaV3.self)
        var row = WeightDayDTO(entry_date: day, weight_kg: 72.25, revision: 1, id: "weight-1", source: "manual")
        var receipts: [String: Data] = [:]
        var writes: [(String, Data)] = []
        StubURLProtocol.handler = { request in
            if request.url?.path == "/api/sync" { return (200, Data(#"{"changes":[],"cursor":0,"has_more":false}"#.utf8)) }
            if request.url?.path == "/api/summary" { return (200, self.emptyDiary(day)) }
            if request.httpMethod == "PUT" {
                XCTAssertEqual(request.url?.path, "/api/weight/day")
                let key = try XCTUnwrap(request.value(forHTTPHeaderField: "Idempotency-Key"))
                let data = Self.requestBody(request)
                writes.append((key, data))
                if let receipt = receipts[key] { return (200, receipt) }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(body["base_revision"] as? Int, row.revision)
                row = WeightDayDTO(entry_date: day, weight_kg: body["weight_kg"] as? Double, revision: row.revision + 1, id: "weight-1", source: "manual", note: body["note"] as? String)
                let reply = try JSONEncoder().encode(row)
                receipts[key] = reply
                if writes.count == 1 { throw URLError(.networkConnectionLost) }
                return (200, reply)
            }
            return (200, try JSONEncoder().encode(row))
        }
        func save() async throws {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
            engine.configure(container: container, accountID: "a")
            let original = try await engine.weightDay(for: date)
            try engine.saveWeight(original, kilograms: 73.25, note: "First")
            await engine.synchronize()
            let pending = try await engine.weightDay(for: date, cachedOnly: true)
            try engine.saveWeight(pending, kilograms: 73.5, note: "Corrected")
        }
        try await save()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        engine.configure(container: container, accountID: "a")
        XCTAssertEqual(engine.pendingCount, 2)
        let pending = try await engine.weightDay(for: date)
        XCTAssertEqual(pending.weight_kg, 73.5)
        XCTAssertEqual(pending.sync_state, "pending")
        await engine.synchronize(force: true)
        XCTAssertEqual(writes.count, 3)
        XCTAssertEqual(writes[0].0, writes[1].0)
        XCTAssertEqual(writes[0].1, writes[1].1)
        XCTAssertNotEqual(writes[1].0, writes[2].0)
        XCTAssertEqual(row.revision, 3)
        let saved = try await engine.weightDay(for: date, cachedOnly: true)
        XCTAssertEqual(saved.weight_kg, 73.5)
        XCTAssertEqual(saved.note, "Corrected")
        let diary = try await engine.diary(for: date)
        XCTAssertEqual(diary.weight?.weightKg, 73.5)
        engine.configure(container: container, accountID: "b")
        let other = try await engine.weightDay(for: date, cachedOnly: true)
        XCTAssertFalse(other.exists)
        XCTAssertEqual(other.revision, 0)
    }

    func testVersionTwoMigrationRecoversDeletionsWithoutChangingQueuedOperations() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "tombstones-\(UUID().uuidString).store")
        let body = Data(#"{"base_revision":3}"#.utf8)
        var operationIDs: [String] = []
        func seed() throws {
            let schema = Schema(versionedSchema: ExerlySchemaV2.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            for (account, entity, method, serverDeleted) in [
                ("a", "pending-delete", "DELETE", false),
                ("a", "pending-restore", "POST", true),
                ("a", "server-deleted", "", true),
                ("b", "pending-delete", "", false),
            ] {
                let payload = serverDeleted ? Data(#"{"deleted_at":"2026-09-22T00:00:00Z"}"#.utf8) : Data("{}".utf8)
                let resource = ExerlySchemaV2.SyncedResource(accountID: account, kind: "weight", entityID: entity, payload: payload)
                resource.serverID = "server-\(entity)"; resource.revision = 3
                resource.syncedPayload = payload; resource.syncState = method.isEmpty ? "synced" : "pending"
                context.insert(resource)
                if !method.isEmpty {
                    let operation = PendingMutation(accountID: account, entityID: entity, kind: "weight", method: method, endpoint: "/api/weight/server-\(entity)", payload: body, baseRevision: 3)
                    operation.attempts = 1
                    operationIDs.append(operation.operationID)
                    context.insert(operation)
                }
            }
            try context.save()
        }
        try seed()
        let schema = Schema(versionedSchema: ExerlySchemaV3.self)
        func verify() throws {
            let container = try ModelContainer(for: schema, migrationPlan: ExerlyMigrationPlan.self, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<SyncedResource>())
            XCTAssertEqual(rows.count, 4)
            XCTAssertTrue(try XCTUnwrap(rows.first { $0.accountID == "a" && $0.entityID == "pending-delete" }).tombstoned)
            XCTAssertTrue(try XCTUnwrap(rows.first { $0.entityID == "server-deleted" }).tombstoned)
            XCTAssertFalse(try XCTUnwrap(rows.first { $0.entityID == "pending-restore" }).tombstoned)
            XCTAssertFalse(try XCTUnwrap(rows.first { $0.accountID == "b" }).tombstoned)
            XCTAssertTrue(rows.allSatisfy { $0.revision == 3 && $0.serverID == "server-\($0.entityID)" })
            let queue = try context.fetch(FetchDescriptor<PendingMutation>())
            XCTAssertEqual(Set(queue.map(\.operationID)), Set(operationIDs))
            XCTAssertTrue(queue.allSatisfy { $0.payload == body && $0.baseRevision == 3 && $0.attempts == 1 })
        }
        try verify()
        try verify() // Reopening must retain the repaired Boolean values.
    }

    func testWeightConflictIsReviewedThenDeletionAndUndoKeepTheSameDay() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        engine.configure(container: container, accountID: "a")
        let day = testToday.rawValue
        var row = WeightDayDTO(entry_date: day, weight_kg: 75, revision: 2, id: "weight-1", source: "manual", note: "Other device")
        var writes: [String] = []
        StubURLProtocol.handler = { request in
            if request.url?.path == "/api/sync" { return (200, Data(#"{"changes":[],"cursor":0,"has_more":false}"#.utf8)) }
            if request.httpMethod != "GET" {
                writes.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: Any])
                if writes.count == 1 { return (409, Data(#"{"message":"A competing reading exists"}"#.utf8)) }
                XCTAssertEqual(body["base_revision"] as? Int, row.revision)
                let deleted = request.httpMethod == "DELETE"
                row = WeightDayDTO(entry_date: day, weight_kg: 73.5, revision: row.revision + 1, id: "weight-1", source: "manual", deleted_at: deleted ? "2026-09-22T00:00:00Z" : nil)
                let response = try JSONEncoder().encode(row)
                if deleted { return (200, try JSONSerialization.data(withJSONObject: ["weight": JSONSerialization.jsonObject(with: response)])) }
                return (200, response)
            }
            return (200, try JSONEncoder().encode(row))
        }
        try engine.saveWeight(.initial(day), kilograms: 73.5, note: "My reading")
        await engine.synchronize()
        await engine.synchronize(force: true)
        XCTAssertEqual(writes.count, 1)
        let issue = try XCTUnwrap(engine.issues().first)
        XCTAssertEqual(issue.weight?.weight_kg, 73.5)
        let (server, _) = try await engine.serverWeightVersion(for: issue)
        XCTAssertEqual(server?.weight_kg, 75)
        try await engine.resolveIssue(issue.id, useServer: false, reviewedRevision: server?.revision)
        await engine.synchronize(force: true)
        XCTAssertNotEqual(writes[0], writes[1])
        let saved = try await engine.weightDay(for: testToday, cachedOnly: true)
        XCTAssertEqual(saved.revision, 3)
        try engine.deleteWeight(saved)
        await engine.synchronize(force: true)
        XCTAssertNotNil(row.deleted_at, "The server reply should represent a deletion")
        let storedDeletion = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<SyncedResource>()).first { $0.kind == "weight" })
        XCTAssertNotNil(try JSONDecoder().decode(WeightDayDTO.self, from: storedDeletion.payload).deleted_at, "The persisted response should retain deleted_at")
        XCTAssertTrue(storedDeletion.tombstoned, "The durable resource should retain the tombstone")
        let removed = try await engine.weightDay(for: testToday, cachedOnly: true)
        XCTAssertFalse(removed.exists)
        XCTAssertEqual(removed.revision, 4)
        try engine.undoWeightDeletion(entityID: day)
        await engine.synchronize(force: true)
        let restored = try await engine.weightDay(for: testToday, cachedOnly: true)
        XCTAssertTrue(restored.exists)
        XCTAssertEqual(restored.id, "weight-1")
        XCTAssertEqual(restored.revision, 5)
        XCTAssertEqual(engine.pendingCount, 0)
    }

    func testReviewedWeightRestoreKeepsItsRestoreEndpointAfterAnotherDeletion() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        engine.configure(container: container, accountID: "a")
        let day = testToday.rawValue
        var row = WeightDayDTO(entry_date: day, weight_kg: 73.25, revision: 1, id: "weight-1", source: "manual")
        var restoreKeys: [String] = []
        StubURLProtocol.handler = { request in
            if request.url?.path == "/api/sync" { return (200, Data(#"{"changes":[],"cursor":0,"has_more":false}"#.utf8)) }
            if request.httpMethod == "DELETE" {
                row = WeightDayDTO(entry_date: day, weight_kg: 73.25, revision: 2, id: "weight-1", source: "manual", deleted_at: "deleted")
            } else if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/api/weight/weight-1/restore")
                restoreKeys.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: Any])
                if body["base_revision"] as? Int != row.revision { return (409, Data(#"{"message":"Another device changed this reading"}"#.utf8)) }
                row = WeightDayDTO(entry_date: day, weight_kg: 73.25, revision: 5, id: "weight-1", source: "manual")
            }
            return (200, try JSONEncoder().encode(row))
        }
        let initial = try await engine.weightDay(for: testToday)
        try engine.deleteWeight(initial)
        await engine.synchronize()
        try engine.undoWeightDeletion(entityID: day)
        // Another device restores and deletes again before this undo reaches it.
        row = WeightDayDTO(entry_date: day, weight_kg: 73.25, revision: 4, id: "weight-1", source: "manual", deleted_at: "deleted again")
        await engine.synchronize()
        let issue = try XCTUnwrap(engine.issues().first)
        XCTAssertTrue(issue.intent == .restore)
        let (server, deleted) = try await engine.serverWeightVersion(for: issue)
        XCTAssertTrue(deleted)
        try await engine.resolveIssue(issue.id, useServer: false, reviewedRevision: server?.revision)
        await engine.synchronize(force: true)
        XCTAssertEqual(restoreKeys.count, 2)
        XCTAssertNotEqual(restoreKeys[0], restoreKeys[1])
        let restored = try await engine.weightDay(for: testToday, cachedOnly: true)
        XCTAssertEqual(restored.revision, 5)
        XCTAssertTrue(restored.exists)
        XCTAssertEqual(engine.pendingCount, 0)
    }

    func testLocalWeightTrendPreservesGapsAndCountsOnlyActualReadings() {
        let records = [
            WeightDayDTO(entry_date: "2026-08-01", weight_kg: 72.25, revision: 1),
            WeightDayDTO(entry_date: "2026-08-04", weight_kg: 71.25, revision: 1),
            WeightDayDTO(entry_date: "2026-08-03", weight_kg: 100, revision: 2, deleted_at: "deleted"),
        ]
        let trend = TrendResponseDTO.savedWeights(records, from: "2026-07-30", to: "2026-08-07")
        XCTAssertEqual(trend.series.count, 7)
        XCTAssertNil(trend.series[1].weight)
        XCTAssertEqual(trend.series[1].trend, 72.25)
        XCTAssertEqual(trend.series.last?.trend, 72.15)
        XCTAssertEqual(trend.summary?.weighIns, 2)
        XCTAssertEqual(trend.summary?.currentWeightKg, 71.25)
        XCTAssertNil(TrendResponseDTO.savedWeights([], from: "2026-08-01", to: "2026-08-07").summary)
    }

    func testWaterComesOffDownToZeroAndTheLogWaterShortcutUsesTheSameQueue() async throws {
        let token = "e30.eyJzdWIiOiJhIn0.fixture"
        keychain.saveSession(token: token, refreshToken: "fixture-refresh")
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false, observeClock: false)
        let user = UserDTO(id: "a", email: "a@exerly.test", timezone: "UTC", unitSystem: "metric", waterGoalMl: 2000)
        defaults.set(try JSONEncoder().encode(user), forKey: APIClient.accountCacheKey(token))
        func log(_ amount: Double?, token: String? = token) async throws -> String {
            try await LoggingActions.logWater(amount, sync: engine, container: container, token: token, defaults: defaults)
        }
        // With no screen open, the shortcut opens the signed-in account's queue.
        XCTAssertFalse(engine.isConfigured(for: "a"))
        let glass = try await log(nil)
        XCTAssertEqual(glass, "Logged 250 ml of water. 250 ml today, 1,750 ml to go.")
        XCTAssertTrue(engine.isConfigured(for: "a"))
        let bottle = try await log(500)
        XCTAssertEqual(bottle, "Logged 500 ml of water. 750 ml today, 1,250 ml to go.")
        // Taking off more than the day has stops at zero and queues only what was there.
        let day = try await engine.diary(for: engine.today, cachedOnly: true)
        XCTAssertEqual(try engine.addWater(XCTUnwrap(day.water), milliliters: -1000), -750)
        let emptied = try await engine.diary(for: engine.today, cachedOnly: true)
        XCTAssertEqual(emptied.waterMl, 0)
        XCTAssertThrowsError(try engine.addWater(XCTUnwrap(emptied.water), milliliters: -250), "Nothing left to take off")
        let deltas = try ModelContext(container).fetch(FetchDescriptor<PendingMutation>())
            .compactMap { try JSONSerialization.jsonObject(with: $0.payload) as? [String: Any] }.compactMap { $0["deltaMl"] as? Int }
        XCTAssertEqual(deltas.sorted(), [-750, 250, 500])
        do { _ = try await log(9000); XCTFail("Too much at once") } catch {
            XCTAssertEqual(error as? LoggingIntentError, .invalid("Enter a whole number from 1 to 5,000 ml."))
        }
        do { _ = try await log(nil, token: nil); XCTFail("Signed out") } catch { XCTAssertEqual(error as? LoggingIntentError, .signedOut) }
    }

    func testWaterAdditionsSurviveLostAcknowledgementRelaunchAndAnotherDevice() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let url = FileManager.default.temporaryDirectory.appending(path: "water-\(UUID().uuidString).store")
        let schema = Schema(versionedSchema: ExerlySchemaV3.self)
        let date = testToday!
        let day = date.rawValue
        var writes: [(String, Data)] = []
        var total = 0
        var revision = 0
        var receipts: [String: Data] = [:]
        var disconnected = false
        StubURLProtocol.handler = { request in
            if disconnected { throw URLError(.notConnectedToInternet) }
            if request.url?.path == "/api/water", request.httpMethod == "POST" {
                let id = request.value(forHTTPHeaderField: "Idempotency-Key")!
                let data = Self.requestBody(request)
                writes.append((id, data))
                if let receipt = receipts[id] { return (200, receipt) }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(body["entry_date"] as? String, day)
                XCTAssertNil(body["base_revision"])
                total += try XCTUnwrap(body["deltaMl"] as? Int)
                revision += 1
                let receipt = try JSONEncoder().encode(WaterDayDTO(entry_date: day, ml: total, revision: revision))
                receipts[id] = receipt
                if writes.count == 1 { throw URLError(.networkConnectionLost) }
                return (200, receipt)
            }
            if request.url?.path == "/api/sync" { return (200, Data(#"{"changes":[],"cursor":0,"has_more":false}"#.utf8)) }
            var summary = try XCTUnwrap(JSONSerialization.jsonObject(with: self.emptyDiary(day)) as? [String: Any])
            summary["water_ml"] = total
            summary["water"] = ["entry_date": day, "ml": total, "revision": revision]
            return (200, try JSONSerialization.data(withJSONObject: summary))
        }
        func saveOffline() async throws {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
            engine.configure(container: container, accountID: "a")
            let initial = try await engine.diary(for: date)
            try engine.addWater(XCTUnwrap(initial.water), milliliters: 250)
            await engine.synchronize()
            XCTAssertEqual(total, 250)
            disconnected = true
            let pending = try await engine.diary(for: date)
            try engine.addWater(XCTUnwrap(pending.water), milliliters: 500)
            let local = try await engine.diary(for: date, cachedOnly: true)
            XCTAssertEqual(local.waterMl, 750)
            XCTAssertEqual(local.water?.sync_state, "pending")
        }
        try await saveOffline()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let reopened = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        reopened.configure(container: container, accountID: "a")
        XCTAssertEqual(reopened.pendingCount, 2)
        let restored = try await reopened.diary(for: date, cachedOnly: true)
        XCTAssertEqual(restored.waterMl, 750)
        total += 300; revision += 1 // A separate device logs water before reconnecting.
        disconnected = false
        // Reading a newer server total before the old acknowledgement must not double-add it.
        let waiting = try await reopened.diary(for: date)
        XCTAssertEqual(waiting.waterMl, 750)
        await reopened.synchronize(force: true)
        XCTAssertEqual(writes.count, 3)
        XCTAssertEqual(writes[0].0, writes[1].0)
        XCTAssertEqual(writes[0].1, writes[1].1)
        XCTAssertNotEqual(writes[1].0, writes[2].0)
        XCTAssertEqual(total, 1050)
        let synchronized = try await reopened.diary(for: date, cachedOnly: true)
        XCTAssertEqual(synchronized.waterMl, 1050)
        XCTAssertEqual(synchronized.water?.revision, 3)
        XCTAssertEqual(reopened.pendingCount, 0)
        reopened.configure(container: container, accountID: "b")
        XCTAssertEqual(reopened.pendingCount, 0)
        let otherAccount = try await reopened.diary(for: date, cachedOnly: true)
        XCTAssertEqual(otherAccount.waterMl, 0, "Water from another account must stay private")
        XCTAssertEqual(otherAccount.water?.revision, 0)
        XCTAssertNil(otherAccount.targets.calories)
    }

    func testHealthReadPreferenceIsScopedAndDoesNotInferGrantedReadAccess() async {
        defaults.set(true, forKey: "healthKitSync")
        var sampledSteps: Int?
        let model = HealthReadModel(accountID: "a", namespace: "fixture", defaults: defaults,
                                    available: { true }, request: {}, load: { (sampledSteps, 210) })
        XCTAssertFalse(model.isEnabled, "A global preference must not opt another account into Health reads")
        await model.setEnabled(true)
        XCTAssertTrue(model.isEnabled)
        XCTAssertNil(model.steps, "A missing or denied read must not be presented as zero recorded steps")
        XCTAssertEqual(model.calories, 210)
        sampledSteps = 0
        await model.refresh()
        XCTAssertEqual(model.steps, 0, "A measured zero remains distinct from no visible samples")
        XCTAssertTrue(HealthReadModel(accountID: "a", namespace: "fixture", defaults: defaults).isEnabled)
        XCTAssertFalse(HealthReadModel(accountID: "b", namespace: "fixture", defaults: defaults).isEnabled)
        XCTAssertFalse(HealthReadModel(accountID: "a", namespace: "another-server", defaults: defaults).isEnabled)
        await model.setEnabled(false)
        XCTAssertNil(model.calories)
        XCTAssertFalse(HealthReadModel(accountID: "a", namespace: "fixture", defaults: defaults).isEnabled)
    }

    func testHealthPermissionFailureRemainsOffAndUnavailableDevicesDoNotRequestAccess() async {
        let failed = HealthReadModel(accountID: "a", namespace: "fixture", defaults: defaults,
                                     available: { true }, request: { throw URLError(.cancelled) }, load: { (0, 0) })
        await failed.setEnabled(true)
        XCTAssertFalse(failed.isEnabled)
        XCTAssertNotNil(failed.message)
        XCTAssertFalse(failed.isRequesting)
        var requested = false
        let unavailable = HealthReadModel(accountID: "a", namespace: "fixture", defaults: defaults,
                                          available: { false }, request: { requested = true }, load: { (0, 0) })
        await unavailable.setEnabled(true)
        XCTAssertFalse(requested)
        XCTAssertFalse(unavailable.isEnabled)
        XCTAssertNotNil(unavailable.message)
    }

    func testDismissedHealthPermissionRequestCannotEnableReadingLater() async {
        var continuation: CheckedContinuation<Void, Never>?
        let model = HealthReadModel(accountID: "a", namespace: "fixture", defaults: defaults,
                                    available: { true }, request: {
                                        await withCheckedContinuation { continuation = $0 }
                                    }, load: { (1200, 150) })
        let operation = Task { await model.setEnabled(true) }
        while continuation == nil { await Task.yield() }
        model.close()
        continuation?.resume()
        await operation.value
        XCTAssertFalse(model.isEnabled)
        XCTAssertNil(model.steps)
        XCTAssertFalse(model.isRequesting)
        XCTAssertFalse(HealthReadModel(accountID: "a", namespace: "fixture", defaults: defaults).isEnabled)
    }

    func testLegacySyncStatusIsNotInheritedByAnotherAccountOrKeptAfterPurge() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false, observeClock: false)
        let synced = { (_: URLRequest) in (200, Data(#"{"changes":[],"cursor":0,"has_more":false}"#.utf8)) }
        engine.configure(container: container, accountID: "a")
        StubURLProtocol.handler = synced
        await engine.synchronize(force: true)
        XCTAssertNotNil(engine.lastSyncedAt)
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await engine.synchronize(force: true)
        XCTAssertTrue(engine.isOffline)
        XCTAssertNotNil(engine.error)
        XCTAssertNotNil(engine.lastSyncedAt, "the last success is still the last success")

        engine.configure(container: container, accountID: "b")
        XCTAssertNil(engine.lastSyncedAt)
        XCTAssertFalse(engine.isOffline)
        XCTAssertNil(engine.error)

        engine.configure(container: container, accountID: "a")
        StubURLProtocol.handler = synced
        await engine.synchronize(force: true)
        XCTAssertNotNil(engine.lastSyncedAt)
        try engine.purge(accountID: "a")
        XCTAssertNil(engine.lastSyncedAt)
        XCTAssertFalse(engine.isOffline)
        XCTAssertNil(engine.error)
    }

    func testLegacySyncClearsOfflineFailureAfterSuccessfulPullWithNoPendingWrites() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false, observeClock: false)
        engine.configure(container: container, accountID: "a")
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await engine.read("/api/profile") } catch {}
        await engine.synchronize(force: true)
        XCTAssertNotNil(engine.error)
        XCTAssertTrue(engine.isOffline)
        XCTAssertEqual(engine.pendingCount, 0)

        var pulls = 0
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/sync")
            pulls += 1
            return (200, Data(#"{"changes":[],"cursor":0,"has_more":false}"#.utf8))
        }
        await engine.synchronize(force: true)
        XCTAssertEqual(pulls, 1)
        XCTAssertNil(engine.error, "A successful account-owned pull must clear the previous failure")
        XCTAssertFalse(engine.isOffline, "An empty queue must be able to reconnect")
        XCTAssertEqual(engine.pendingCount, 0)
    }

    func testDiaryStatusReplaysLostAcknowledgementBeforeLaterOfflineChange() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        engine.configure(container: container, accountID: "a")
        let date = testToday!
        let day = date.rawValue
        var writes: [(String, Data)] = []
        StubURLProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                let data = Self.requestBody(request)
                writes.append((request.value(forHTTPHeaderField: "Idempotency-Key")!, data))
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                if writes.count == 1 { throw URLError(.networkConnectionLost) }
                let revision = writes.count == 2 ? 1 : 2
                XCTAssertEqual(body["base_revision"] as? Int, revision - 1)
                var result = body; result["revision"] = revision; result["id"] = "10"
                return (200, try JSONSerialization.data(withJSONObject: result))
            }
            if request.url?.path == "/api/sync" { return (200, Data(#"{"changes":[],"cursor":0,"has_more":false}"#.utf8)) }
            return (200, self.emptyDiary(day))
        }
        let first = try await engine.diary(for: date)
        try engine.saveDiaryDay(XCTUnwrap(first.diaryDay), status: .complete, note: "All meals")
        await engine.synchronize()
        let pending = try await engine.diary(for: date, cachedOnly: true)
        XCTAssertEqual(pending.diaryDay?.status, .complete)
        XCTAssertEqual(pending.diaryDay?.sync_state, "pending")
        try engine.saveDiaryDay(XCTUnwrap(pending.diaryDay), status: .estimated, note: "Lunch was estimated")
        let reopened = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        reopened.configure(container: container, accountID: "a")
        let local = try await reopened.diary(for: date, cachedOnly: true)
        XCTAssertEqual(local.diaryDay?.status, .estimated)
        XCTAssertEqual(reopened.pendingCount, 2)
        await reopened.synchronize(force: true)
        XCTAssertEqual(writes.count, 3)
        XCTAssertEqual(writes[0].0, writes[1].0)
        XCTAssertEqual(writes[0].1, writes[1].1)
        XCTAssertNotEqual(writes[1].0, writes[2].0)
        let updated = try await reopened.diary(for: date)
        XCTAssertEqual(updated.diaryDay?.status, .estimated)
        XCTAssertEqual(updated.diaryDay?.revision, 2)
        XCTAssertEqual(updated.diaryDay?.note, "Lunch was estimated")
        XCTAssertEqual(reopened.pendingCount, 0)
        reopened.configure(container: container, accountID: "b")
        let otherAccount = try await reopened.diary(for: date, cachedOnly: true)
        XCTAssertEqual(otherAccount.diaryDay?.status, .inProgress)
        XCTAssertEqual(otherAccount.diaryDay?.revision, 0)
        XCTAssertNil(otherAccount.diaryDay?.note, "A different account must not see the saved status")
    }

    func testDiaryStatusConflictRequiresReviewedStatusAndRevision() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        engine.configure(container: container, accountID: "a")
        let day = testToday.rawValue
        var writes: [String] = []
        let remote = DiaryDayDTO(entry_date: day, status: .excluded, note: "Missing dinner", revision: 1)
        StubURLProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                writes.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
                if writes.count == 1 { return (409, Data(#"{"message":"This day changed"}"#.utf8)) }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: Any])
                XCTAssertEqual(body["base_revision"] as? Int, 1)
                XCTAssertEqual(body["status"] as? String, "complete")
                return (200, try JSONEncoder().encode(DiaryDayDTO(entry_date: day, status: .complete, note: "All meals", revision: 2)))
            }
            if request.url?.path == "/api/diary/day" { return (200, try JSONEncoder().encode(remote)) }
            if request.url?.path == "/api/sync" { return (200, Data(#"{"changes":[],"cursor":0,"has_more":false}"#.utf8)) }
            return (200, self.emptyDiary(day))
        }
        _ = try await engine.diary(for: testToday)
        try engine.saveDiaryDay(.initial(day), status: .complete, note: "All meals")
        await engine.synchronize()
        await engine.synchronize(force: true)
        XCTAssertEqual(writes.count, 1)
        let issue = try XCTUnwrap(engine.issues().first)
        XCTAssertNil(issue.local)
        XCTAssertEqual(issue.diaryDay?.status, .complete)
        let (server, _) = try await engine.serverDiaryDayVersion(for: issue)
        XCTAssertEqual(server?.status, .excluded)
        XCTAssertEqual(server?.note, "Missing dinner")
        try await engine.resolveIssue(issue.id, useServer: false, reviewedRevision: server?.revision)
        await engine.synchronize(force: true)
        XCTAssertEqual(writes.count, 2)
        XCTAssertNotEqual(writes[0], writes[1])
        XCTAssertEqual(engine.attentionCount, 0)
        let saved = try await engine.diary(for: testToday, cachedOnly: true)
        XCTAssertEqual(saved.diaryDay?.status, .complete)
        XCTAssertEqual(saved.diaryDay?.revision, 2)
    }

    func testOwnedMeasurementsSurviveReopeningAndDoNotAdoptLegacyRecords() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let url = FileManager.default.temporaryDirectory.appending(path: "measurements-\(UUID().uuidString).store")
        let day = testToday.rawValue
        let schema = Schema(versionedSchema: ExerlySchemaV3.self)
        func persist() throws {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let legacy = ModelContext(container)
            legacy.insert(Measurement(type: "waist", value: 123.4, unit: "cm"))
            try legacy.save()
            let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
            engine.configure(container: container, accountID: "a")
            try engine.saveMeasurement(BodyMeasurementRequest(type: "waist", value: 82.55, unit: "cm", entry_date: day))
        }
        try persist()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        engine.configure(container: container, accountID: "a")
        let local = try await engine.measurements(from: day, to: day, cachedOnly: true)
        XCTAssertEqual(local.count, 1)
        XCTAssertEqual(local.first?.value, 82.55)
        XCTAssertEqual(engine.pendingCount, 1)
        keychain.saveSession(token: "e30.eyJzdWIiOiJiIn0.fixture", refreshToken: "fixture-refresh")
        engine.configure(container: container, accountID: "b")
        StubURLProtocol.handler = { _ in (200, Data(#"{"entries":[],"total":0}"#.utf8)) }
        let other = try await engine.measurements(from: day, to: day)
        XCTAssertTrue(other.isEmpty)
        XCTAssertEqual(engine.pendingCount, 0)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Exerly.Measurement>()).first?.value, 123.4)
    }

    func testMeasurementLostAcknowledgementKeepsLaterEditAndUsesAcknowledgedRevision() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        engine.configure(container: container, accountID: "a")
        let day = testToday.rawValue
        let entityID = try engine.saveMeasurement(BodyMeasurementRequest(type: "waist", value: 82.55, unit: "cm", entry_date: day))
        var keys: [String] = []
        var row: [String: Any] = ["id": "10", "client_id": entityID, "type": "waist", "value": 82.55, "unit": "cm", "entry_date": day, "revision": 1]
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                keys.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
                if keys.count == 1 { throw URLError(.networkConnectionLost) }
                return (201, try JSONSerialization.data(withJSONObject: row))
            }
            if request.httpMethod == "PUT" {
                XCTAssertEqual(request.url?.path, "/api/measurements/10")
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: Any])
                XCTAssertEqual(body["base_revision"] as? Int, 1)
                XCTAssertEqual(body["value"] as? Double, 81.25)
                row["revision"] = 2; row["value"] = 81.25
                return (200, try JSONSerialization.data(withJSONObject: row))
            }
            if request.url?.path == "/api/sync" { return (200, Data(#"{"changes":[],"cursor":0,"has_more":false}"#.utf8)) }
            return (200, try JSONSerialization.data(withJSONObject: ["entries": [row], "total": 1]))
        }
        await engine.synchronize()
        let pending = try await engine.measurements(from: day, to: day, cachedOnly: true)
        try engine.saveMeasurement(BodyMeasurementRequest(type: "waist", value: 81.25, unit: "cm", entry_date: day), editing: XCTUnwrap(pending.first))
        let reopened = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        reopened.configure(container: container, accountID: "a")
        await reopened.synchronize(force: true)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], keys[1])
        XCTAssertEqual(reopened.pendingCount, 0)
        let result = try await reopened.measurements(from: day, to: day)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.value, 81.25)
        XCTAssertEqual(result.first?.revision, 2)
    }

    func testLegacyMeasurementImportIsExplicitAtomicAndCannotReplay() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let waist = Measurement(type: "waist", value: 32.5, unit: "in")
        let unsupported = Measurement(type: "arms", value: 1, unit: "yards")
        context.insert(waist); context.insert(unsupported)
        try context.save()
        let waistReview = LegacyMeasurementImport(waist, day: testToday)
        let unsupportedReview = LegacyMeasurementImport(unsupported, day: testToday)
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        engine.configure(container: container, accountID: "a")
        XCTAssertThrowsError(try engine.importLegacyMeasurements([waistReview, unsupportedReview]))
        let afterFailure = ModelContext(container)
        XCTAssertEqual(try afterFailure.fetch(FetchDescriptor<Exerly.Measurement>()).count, 2)
        XCTAssertTrue(try afterFailure.fetch(FetchDescriptor<PendingMutation>()).isEmpty)
        try engine.importLegacyMeasurements([waistReview])
        XCTAssertEqual(engine.pendingCount, 1)
        XCTAssertThrowsError(try engine.importLegacyMeasurements([waistReview]))
        let day = testToday.rawValue
        let local = try await engine.measurements(from: day, to: day, cachedOnly: true)
        XCTAssertEqual(local.count, 1)
        XCTAssertEqual(try XCTUnwrap(local.first).value, 82.55, accuracy: 0.00001)
        XCTAssertEqual(local.first?.source, "legacy_device_import")
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Exerly.Measurement>()).count, 1)
    }

    func testMeasurementConflictUsesMeasurementValuesAndReviewedRevision() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        engine.configure(container: container, accountID: "a")
        let day = testToday.rawValue
        let row: [String: Any] = ["id": "10", "client_id": UUID().uuidString.lowercased(), "type": "waist", "value": 82.55, "unit": "cm", "entry_date": day, "revision": 1]
        var operations: [String] = []
        StubURLProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                operations.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
                if operations.count == 1 { return (409, Data(#"{"message":"Measurement changed on another device"}"#.utf8)) }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: Any])
                XCTAssertEqual(body["base_revision"] as? Int, 2)
                var updated = row; updated["revision"] = 3; updated["value"] = 81.25
                return (200, try JSONSerialization.data(withJSONObject: updated))
            }
            if request.url?.path == "/api/measurements/10" {
                var changed = row; changed["revision"] = 2; changed["value"] = 83
                return (200, try JSONSerialization.data(withJSONObject: changed))
            }
            if request.url?.path == "/api/sync" { return (200, Data(#"{"changes":[],"cursor":0,"has_more":false}"#.utf8)) }
            return (200, try JSONSerialization.data(withJSONObject: ["entries": [row], "total": 1]))
        }
        let initial = try await engine.measurements(from: day, to: day)
        try engine.saveMeasurement(BodyMeasurementRequest(type: "waist", value: 81.25, unit: "cm", entry_date: day), editing: XCTUnwrap(initial.first))
        await engine.synchronize()
        await engine.synchronize(force: true)
        XCTAssertEqual(operations.count, 1)
        let issue = try XCTUnwrap(engine.issues().first)
        XCTAssertEqual(issue.name, "Waist")
        XCTAssertNil(issue.local)
        XCTAssertEqual(issue.measurement?.value, 81.25)
        let (server, _) = try await engine.serverMeasurementVersion(for: issue)
        XCTAssertEqual(server?.value, 83)
        try await engine.resolveIssue(issue.id, useServer: false, reviewedRevision: server?.revision)
        await engine.synchronize(force: true)
        XCTAssertEqual(operations.count, 2)
        XCTAssertNotEqual(operations[0], operations[1])
        XCTAssertEqual(engine.attentionCount, 0)
        let result = try await engine.measurements(from: day, to: day)
        XCTAssertEqual(result.first?.value, 81.25)
        XCTAssertEqual(result.first?.revision, 3)
    }

    func testConflictRemainsVisibleUntilUserReviewsCurrentRevision() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        engine.configure(container: container, accountID: "a")
        let day = testToday.rawValue
        let entityID = UUID().uuidString.lowercased()
        let serverRow: [String: Any] = ["id": "10", "client_id": entityID, "revision": 1, "name": "Drink", "calories": 60, "servings": 1, "entry_date": day, "meal_type": "dinner"]
        var summary = try XCTUnwrap(JSONSerialization.jsonObject(with: emptyDiary(day)) as? [String: Any])
        summary["meals"] = ["dinner": ["entries": [serverRow]]]
        let summaryData = try JSONSerialization.data(withJSONObject: summary)
        var keys: [String] = []
        StubURLProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                keys.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
                if keys.count == 1 { return (409, Data(#"{"message":"Entry changed on another device"}"#.utf8)) }
                var updated = serverRow; updated["revision"] = 3; updated["calories"] = 90; updated["servings"] = 1.5
                return (200, try JSONSerialization.data(withJSONObject: updated))
            }
            if request.url?.path == "/api/food/10" {
                var current = serverRow; current["revision"] = 2; current["calories"] = 80
                return (200, try JSONSerialization.data(withJSONObject: current))
            }
            if request.url?.path == "/api/sync" { return (200, Data(#"{"changes":[],"cursor":0,"has_more":false}"#.utf8)) }
            return (200, summaryData)
        }
        let diary = try await engine.diary(for: testToday)
        let food = try XCTUnwrap(diary.meals["dinner"]?.entries.first)
        var request = FoodRequest(name: "Drink", calories: 60, protein: nil, carbs: nil, fat: nil, sugar: nil, mealType: "dinner", barcode: nil, brand: nil, fiber: nil, servingSize: "100 ml")
        request.servings = 1.5; request.entryDate = day
        try engine.saveFood(request, editing: food)
        await engine.synchronize()
        XCTAssertEqual(engine.attentionCount, 1)
        await engine.synchronize(force: true)
        XCTAssertEqual(keys.count, 1, "A conflict must not retry without review")
        let issue = try XCTUnwrap(engine.issues().first)
        let (server, deleted) = try await engine.serverVersion(for: issue)
        XCTAssertFalse(deleted)
        XCTAssertEqual(server?.calories, 80)
        try await engine.resolveIssue(issue.id, useServer: false, reviewedRevision: server?.revision)
        await engine.synchronize(force: true)
        XCTAssertEqual(keys.count, 2)
        XCTAssertNotEqual(keys[0], keys[1])
        XCTAssertEqual(engine.attentionCount, 0)
        XCTAssertEqual(engine.pendingCount, 0)
        let result = try await engine.diary(for: testToday)
        XCTAssertEqual(result.consumed.calories, 90, "Stale cached revision must not undo the accepted edit")
        let edited = try XCTUnwrap(result.meals["dinner"]?.entries.first)
        let deletedID = try engine.deleteFood(edited)
        try engine.undoFoodDeletion(entityID: deletedID)
        XCTAssertEqual(engine.pendingCount, 0, "Undo cancels a deletion that has never been sent")
        let restored = try await engine.diary(for: testToday)
        XCTAssertEqual(restored.meals["dinner"]?.entries.count, 1)
    }

    func testQueuedWriteCannotUseNewAccountCredentialsBeforeViewReconfiguration() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        engine.configure(container: container, accountID: "a")
        var entry = FoodRequest(name: "Private food", calories: 100, protein: nil, carbs: nil, fat: nil, sugar: nil, mealType: "dinner", barcode: nil, brand: nil, fiber: nil, servingSize: "1 serving")
        entry.entryDate = testToday.rawValue
        try engine.saveFood(entry)
        keychain.saveSession(token: "e30.eyJzdWIiOiJiIn0.fixture", refreshToken: "fixture-refresh")
        var requests = 0
        StubURLProtocol.handler = { _ in requests += 1; return (200, Data("{}".utf8)) }
        await engine.synchronize(force: true)
        XCTAssertEqual(requests, 0, "The transport must reject an old account's queued write before sending")
        XCTAssertEqual(engine.pendingCount, 1)
        engine.configure(container: container, accountID: "b")
        XCTAssertEqual(engine.pendingCount, 0)
    }

    func testManualLogNumbersPreserveLocaleDecimalsAndRejectPartiallyParsedInput() {
        XCTAssertEqual(UserEnteredNumber.parse("30.25", locale: Locale(identifier: "en_US")), 30.25)
        XCTAssertEqual(UserEnteredNumber.parse(" 7,25 ", locale: Locale(identifier: "fr_FR")), 7.25)
        XCTAssertEqual(UserEnteredNumber.parse("٧٫٢٥", locale: Locale(identifier: "ar_EG")), 7.25)
        XCTAssertEqual(UserEnteredNumber.parse("0", locale: Locale(identifier: "en_US")), 0)
        for value in ["", "45.530.25", "7 hours", "1,000", "NaN", "1e309"] {
            XCTAssertNil(UserEnteredNumber.parse(value, locale: Locale(identifier: "en_US")), value)
        }
    }

    func testActivityAndSleepSurviveLostResponseReopenAndAnUncachedDiaryDay() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let url = FileManager.default.temporaryDirectory.appending(path: "daily-logs-\(UUID().uuidString).store")
        let schema = Schema(versionedSchema: ExerlySchemaV3.self)
        let date = testToday.adding(days: -3)!
        let day = date.rawValue
        var rows: [String: [String: Any]] = [:]
        var receipts: [String: Data] = [:]
        var writes: [(String, Data)] = []
        var offline = false
        StubURLProtocol.handler = { request in
            if offline { throw URLError(.notConnectedToInternet) }
            if request.url?.path == "/api/sync" {
                let changes = rows.values.map { row in
                    ["kind": row["hours"] == nil ? "activity" : "sleep", "entity_id": row["client_id"]!, "server_id": row["id"]!, "revision": row["revision"]!, "payload": row] as [String: Any]
                }
                return (200, try JSONSerialization.data(withJSONObject: ["changes": changes, "cursor": changes.count, "has_more": false]))
            }
            if request.httpMethod == "GET" { return (200, self.emptyDiary(day)) }
            let key = request.value(forHTTPHeaderField: "Idempotency-Key")!
            let data = Self.requestBody(request)
            writes.append((key, data))
            if let receipt = receipts[key] { return (200, receipt) }
            var body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let entity = try XCTUnwrap(body["client_id"] as? String).lowercased()
            body["client_id"] = entity
            if let old = rows[entity] { XCTAssertEqual(body["base_revision"] as? Int, old["revision"] as? Int) }
            body["id"] = "server-\(entity)"; body["revision"] = (rows[entity]?["revision"] as? Int ?? 0) + 1
            rows[entity] = body
            let result = try JSONSerialization.data(withJSONObject: body)
            receipts[key] = result
            if writes.count == 1 { offline = true; throw URLError(.networkConnectionLost) }
            return (200, result)
        }
        func saveOffline() async throws {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
            engine.configure(container: container, accountID: "a")
            try engine.saveActivity(ActivityRequest(type: "Walk", duration: 30.25, calories: nil, intensity: nil, entryDate: day))
            await engine.synchronize()
            try engine.saveSleep(SleepRequest(hours: 7.25, quality: nil, bedtime: "23:00", wakeTime: "06:15", entryDate: day))
            try engine.saveSleep(SleepRequest(hours: 0.5, quality: "good", bedtime: nil, wakeTime: nil, entryDate: day))
            let local = try await engine.diary(for: date)
            XCTAssertEqual(local.activities.first?.duration, 30.25)
            XCTAssertNil(local.activities.first?.calories)
            XCTAssertEqual(local.sleepEntries?.count, 2)
            XCTAssertEqual(local.sleepHours, 7.75)
            XCTAssertNil(local.targets.calories, "An uncached date cannot invent nutrition targets")
            try engine.saveActivity(ActivityRequest(type: "Walk", duration: 45.5, calories: 0, intensity: "light", entryDate: day), editing: XCTUnwrap(local.activities.first))
        }
        try await saveOffline()
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        engine.configure(container: container, accountID: "a")
        XCTAssertEqual(engine.pendingCount, 4)
        let reopened = try await engine.diary(for: date, cachedOnly: true)
        XCTAssertEqual(reopened.activities.first?.duration, 45.5)
        XCTAssertEqual(reopened.activities.first?.calories, 0)
        XCTAssertEqual(reopened.sleepHours, 7.75)
        XCTAssertEqual(reopened.entryCount, 3)
        offline = false
        await engine.synchronize(force: true)
        XCTAssertEqual(writes.count, 5)
        XCTAssertEqual(writes[0].0, writes[1].0)
        XCTAssertEqual(writes[0].1, writes[1].1)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(engine.pendingCount, 0)
        let saved = try await engine.diary(for: date)
        XCTAssertEqual(saved.activities.count, 1, "The normalized server identity and local row must remain one entry")
        XCTAssertEqual(saved.sleepEntries?.count, 2)
        XCTAssertEqual(saved.activities.first?.duration, 45.5)
        XCTAssertEqual(saved.activities.first?.revision, 2)
        XCTAssertEqual(saved.sleepHours, 7.75)
        engine.configure(container: container, accountID: "b")
        let other = try await engine.diary(for: date, cachedOnly: true)
        XCTAssertEqual(other.entryCount, 0)
        XCTAssertTrue(other.activities.isEmpty)
        XCTAssertTrue(other.sleepEntries?.isEmpty == true)
    }

    func testActivityAndSleepReviewConflictsThenDeleteAndUndoTheSameRecord() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let day = testToday.rawValue
        for kind in ["activity", "sleep"] {
            let path = kind == "activity" ? "/api/activities" : "/api/sleep"
            let entity = UUID().uuidString
            var row: [String: Any] = ["id": "entry-1", "client_id": entity, "revision": 1, "entry_date": day]
            if kind == "activity" { row.merge(["activity": "Walk", "duration_min": 30.25, "calories": 100.0]) { _, value in value } }
            else { row.merge(["hours": 7.25, "quality": "good"]) { _, value in value } }
            var writes: [String] = []
            StubURLProtocol.handler = { request in
                if request.url?.path == "/api/sync" { return (200, Data(#"{"changes":[],"cursor":0,"has_more":false}"#.utf8)) }
                if request.httpMethod == "GET" {
                    return (200, try JSONSerialization.data(withJSONObject: request.url?.path == path ? [row] : row as Any))
                }
                writes.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: Any])
                if body["base_revision"] as? Int != row["revision"] as? Int { return (409, Data(#"{"message":"Entry changed on another device"}"#.utf8)) }
                let next = (row["revision"] as! Int) + 1
                if request.httpMethod == "DELETE" { row["deleted_at"] = "deleted" }
                else if request.url?.path.hasSuffix("/restore") == true { row.removeValue(forKey: "deleted_at") }
                else { row.merge(body) { _, value in value } }
                row["revision"] = next
                return (200, try JSONSerialization.data(withJSONObject: request.httpMethod == "DELETE" ? [kind: row] : row as Any))
            }
            let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
            engine.configure(container: container, accountID: "a")
            if kind == "activity" {
                let entries = try await engine.activityEntries(from: day, to: day)
                let original = try XCTUnwrap(entries.first)
                try engine.saveActivity(ActivityRequest(type: "Walk", duration: 45.5, calories: nil, intensity: nil, entryDate: day), editing: original)
            } else {
                let entries = try await engine.sleepEntries(from: day, to: day)
                let original = try XCTUnwrap(entries.first)
                try engine.saveSleep(SleepRequest(hours: 8.25, quality: "great", bedtime: nil, wakeTime: nil, entryDate: day), editing: original)
            }
            row["revision"] = 2
            await engine.synchronize()
            let issue = try XCTUnwrap(engine.issues().first)
            XCTAssertEqual(engine.attentionCount, 1)
            if kind == "activity" {
                let server = try await engine.serverActivityVersion(for: issue)
                XCTAssertEqual(server.0?.revision, 2)
            } else {
                let server = try await engine.serverSleepVersion(for: issue)
                XCTAssertEqual(server.0?.revision, 2)
            }
            try await engine.resolveIssue(issue.id, useServer: false, reviewedRevision: 2)
            await engine.synchronize(force: true)
            XCTAssertNotEqual(writes[0], writes[1])
            if kind == "activity" {
                let entries = try await engine.activityEntries(from: day, to: day, cachedOnly: true)
                let saved = try XCTUnwrap(entries.first)
                XCTAssertEqual(saved.duration, 45.5)
                try engine.deleteActivity(saved)
            } else {
                let entries = try await engine.sleepEntries(from: day, to: day, cachedOnly: true)
                let saved = try XCTUnwrap(entries.first)
                XCTAssertEqual(saved.hours, 8.25)
                try engine.deleteSleep(saved)
            }
            await engine.synchronize(force: true)
            XCTAssertEqual(row["revision"] as? Int, 4)
            XCTAssertNotNil(row["deleted_at"])
            if kind == "activity" { try engine.undoActivityDeletion(entityID: entity) }
            else { try engine.undoSleepDeletion(entityID: entity) }
            await engine.synchronize(force: true)
            XCTAssertEqual(row["id"] as? String, "entry-1")
            XCTAssertEqual(row["revision"] as? Int, 5)
            XCTAssertNil(row["deleted_at"])
            XCTAssertEqual(engine.pendingCount, 0)
        }
    }

    func testActivityAndSleepFeedMovesAndDeletesEntriesWithoutResurrectingCachedDays() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        engine.configure(container: container, accountID: "a")
        let date = testToday!
        let day = date.rawValue
        let previous = date.adding(days: -1)!
        let previousDay = previous.rawValue
        let activity: [String: Any] = ["id": "activity-1", "client_id": UUID().uuidString, "revision": 1, "entry_date": day, "activity": "Walk", "duration_min": 30.25]
        let sleep: [String: Any] = ["id": "sleep-1", "client_id": UUID().uuidString, "revision": 1, "entry_date": day, "hours": 7.25]
        var stale = try XCTUnwrap(JSONSerialization.jsonObject(with: emptyDiary(day)) as? [String: Any])
        stale["activities"] = [activity]; stale["sleep_entries"] = [sleep]
        var revision = 2
        var cursor = 0
        StubURLProtocol.handler = { request in
            if request.url?.path == "/api/sync" {
                let changes: [[String: Any]] = [("activity", activity), ("sleep", sleep)].map { kind, original in
                    var row = original; row["entry_date"] = previousDay; row["revision"] = revision
                    if revision == 3 { row["deleted_at"] = "deleted" }
                    return ["kind": kind, "entity_id": row["client_id"]!, "server_id": row["id"]!, "revision": revision, "deleted": revision == 3, "payload": row]
                }
                cursor += 2
                return (200, try JSONSerialization.data(withJSONObject: ["changes": changes, "cursor": cursor, "has_more": false]))
            }
            return (200, try JSONSerialization.data(withJSONObject: stale))
        }
        let initial = try await engine.diary(for: date)
        XCTAssertEqual(initial.entryCount, 2)
        let before = engine.changeToken
        await engine.synchronize()
        XCTAssertGreaterThan(engine.changeToken, before, "Remote changes must notify the displayed diary")
        let oldDay = try await engine.diary(for: date)
        XCTAssertEqual(oldDay.entryCount, 0, "An older summary cannot undo a move from the change feed")
        let moved = try await engine.diary(for: previous, cachedOnly: true)
        XCTAssertEqual(moved.activities.first?.duration, 30.25)
        XCTAssertEqual(moved.sleepHours, 7.25)
        XCTAssertNil(moved.targets.calories)
        revision = 3
        await engine.synchronize()
        let deleted = try await engine.diary(for: previous, cachedOnly: true)
        XCTAssertEqual(deleted.entryCount, 0)
        revision = 4
        await engine.synchronize()
        let restored = try await engine.diary(for: previous, cachedOnly: true)
        XCTAssertEqual(restored.entryCount, 2)
        XCTAssertEqual(restored.activities.first?.revision, 4)
    }

    func testDuplicateActivityCreateLearnsServerIdentityAndRequiresReviewedReplacement() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let container = try ModelContainer(for: Schema(versionedSchema: ExerlySchemaV3.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(api: api, monitorNetwork: false, automaticallySync: false)
        engine.configure(container: container, accountID: "a")
        let day = testToday.rawValue
        let entity = try engine.saveActivity(ActivityRequest(type: "Walk", duration: 45.5, calories: nil, intensity: nil, entryDate: day))
        var row: [String: Any] = ["id": "known-activity", "client_id": entity, "revision": 2, "entry_date": day, "activity": "Walk", "duration_min": 30.25]
        var writes: [(String, String, Data)] = []
        StubURLProtocol.handler = { request in
            if request.url?.path == "/api/sync" {
                return (200, try JSONSerialization.data(withJSONObject: ["changes": [["kind": "activity", "entity_id": entity, "server_id": "known-activity", "revision": 2, "payload": row]], "cursor": 1, "has_more": false]))
            }
            if request.httpMethod == "GET" { return (200, try JSONSerialization.data(withJSONObject: row)) }
            writes.append((request.httpMethod!, request.value(forHTTPHeaderField: "Idempotency-Key")!, Self.requestBody(request)))
            if request.httpMethod == "POST" { return (409, Data(#"{"message":"This activity already exists"}"#.utf8)) }
            XCTAssertEqual(request.url?.path, "/api/activities/known-activity")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: Any])
            XCTAssertEqual(body["base_revision"] as? Int, 2)
            row.merge(body) { _, value in value }; row["revision"] = 3
            return (200, try JSONSerialization.data(withJSONObject: row))
        }
        await engine.synchronize()
        let issue = try XCTUnwrap(engine.issues().first)
        XCTAssertEqual(issue.serverID, "known-activity")
        let server = try await engine.serverActivityVersion(for: issue)
        XCTAssertEqual(server.0?.duration, 30.25)
        XCTAssertEqual(issue.activity?.duration, 45.5)
        try await engine.resolveIssue(issue.id, useServer: false, reviewedRevision: 2)
        await engine.synchronize(force: true)
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[1].0, "PUT")
        XCTAssertNotEqual(writes[0].1, writes[1].1)
        XCTAssertEqual(engine.pendingCount, 0)
        XCTAssertEqual(row["duration_min"] as? Double, 45.5)
    }

    private func preferencesDocument(revision: Int = 1, values: [String: JSONValue] = [:]) -> PreferencesSnapshot {
        var saved: [String: JSONValue] = [
            "name": .string("Taylor"), "age": .number(34), "gender": .string("nonbinary"),
            "height": .number(167.75), "unitSystem": .string("metric"), "timezone": .string("America/New_York"),
            "activityLevel": .string("light"), "dietaryStyle": .string("mediterranean"),
            "allergies": .array([.string("sesame")]), "mealsPerDay": .number(4),
            "workoutDaysPerWeek": .number(3), "sleepGoalHours": .number(7.25),
            "equipment": .array([.string("rings")]), "bedtime": .string("22:45"), "wakeTime": .string("06:15"),
            "reminders": .object(["meals": .bool(false), "workouts": .bool(true), "legacy": .bool(true)])
        ]
        saved.merge(values) { _, new in new }
        let user = UserDTO(id: "a", email: "preferences@exerly.test", name: PreferenceFields.text(saved["name"]!),
                           onboardingCompleted: true, height: 167.75, weight: 72.25,
                           unitSystem: PreferenceFields.text(saved["unitSystem"]!), preferencesRevision: revision)
        return PreferencesSnapshot(schemaVersion: 1, accountID: "a", revision: revision, values: saved, user: user)
    }

    func testPreferencesDraftSurvivesRelaunchAndUnitChangesWithoutRoundingOrCrossingAccounts() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let original = preferencesDocument()
        StubURLProtocol.handler = { _ in (200, try JSONEncoder().encode(original)) }
        let store = PreferencesStore(accountID: "a", api: api, defaults: defaults, ownerIsActive: { true })
        await store.load()
        for _ in 0..<10 {
            store.edit("unitSystem", value: "imperial")
            store.edit("unitSystem", value: "metric")
        }
        XCTAssertEqual(store.draft?.heightCM, 167.75)
        XCTAssertTrue(try PreferenceFields.changes(XCTUnwrap(store.draft)).isEmpty)
        store.edit("name", value: "Draft Taylor")
        let changes = try PreferenceFields.changes(XCTUnwrap(store.draft))
        XCTAssertEqual(changes, ["name": .string("Draft Taylor")], "Saving a name must not resend rounded body measurements or unknown preferences")
        store.edit("height", value: "167..75")
        let reopened = PreferencesStore(accountID: "a", api: api, defaults: defaults, ownerIsActive: { true })
        XCTAssertEqual(reopened.draft?.fields["height"], "167..75")
        XCTAssertEqual(reopened.draft?.fields["name"], "Draft Taylor")
        await reopened.save()
        XCTAssertEqual(reopened.error, "Enter a valid height.")
        XCTAssertNil(reopened.draft?.pending)
        let other = PreferencesStore(accountID: "b", api: api, defaults: defaults, ownerIsActive: { true })
        XCTAssertNil(other.draft)
        let otherAPI = APIClient(baseURL: "https://other.exerly.test", keychain: keychain, defaults: defaults)
        let otherEnvironment = PreferencesStore(accountID: "a", api: otherAPI, defaults: defaults, ownerIsActive: { true })
        XCTAssertNil(otherEnvironment.draft)
        XCTAssertNotEqual(otherEnvironment.storageKey, reopened.storageKey)
    }

    /// Done tapped while a reopened screen still refreshes used to close it
    /// with the change unsent; the save now waits for the refresh.
    func testAPreferenceSavedWhileTheScreenIsStillLoadingIsSent() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        var remote = preferencesDocument()
        var patches = 0
        StubURLProtocol.handler = { request in
            if request.httpMethod == "GET" { return (200, try JSONEncoder().encode(remote)) }
            patches += 1
            let body = try JSONDecoder().decode(PreferenceMutation.self, from: Self.requestBody(request))
            remote = self.preferencesDocument(revision: 2, values: body.changes)
            return (200, try JSONEncoder().encode(remote))
        }
        await PreferencesStore(accountID: "a", api: api, defaults: defaults, ownerIsActive: { true }).load()
        // Reopened as a screen is: the saved draft shows while it refreshes.
        let store = PreferencesStore(accountID: "a", api: api, defaults: defaults, ownerIsActive: { true })
        let loading = Task { await store.load() }
        for _ in 0..<50 where !store.isLoading { await Task.yield() }
        XCTAssertTrue(store.isLoading)
        store.edit("name", value: "Quick Taylor")
        await store.save()
        await loading.value
        XCTAssertEqual(patches, 1, "Sent once the refresh finished, not dropped")
        XCTAssertFalse(store.hasEdits)
        XCTAssertEqual(store.draft?.base.revision, 2)
    }

    /// Review round 1: offline, a choice made in Customize Today or the water
    /// sheet did nothing. It's kept at once, survives a relaunch, and is sent
    /// once a request gets through, with only its own fields.
    func testQuickPreferencesMadeOfflineAreKeptAndSentAloneOnceOnline() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        var remote = preferencesDocument()
        var offline = true
        var bodies: [PreferenceMutation] = []
        StubURLProtocol.handler = { request in
            if offline { throw URLError(.notConnectedToInternet) }
            if request.httpMethod == "GET" { return (200, try JSONEncoder().encode(remote)) }
            let body = try JSONDecoder().decode(PreferenceMutation.self, from: Self.requestBody(request))
            bodies.append(body)
            XCTAssertEqual(body.baseRevision, remote.revision)
            remote = self.preferencesDocument(revision: remote.revision + 1, values: remote.values.merging(body.changes) { $1 })
            return (200, try JSONEncoder().encode(remote))
        }
        let later: [Duration] = [.seconds(3600)]
        let quick = QuickPreferences(accountID: "a", api: api, defaults: defaults, retryDelays: later)
        quick.set("nutritionDisplay", .string("consumed"))
        await quick.waitForSend()
        quick.set("waterGoalMl", .number(2662))
        await quick.waitForSend()
        XCTAssertTrue(quick.isWaitingForConnection)
        XCTAssertTrue(quick.leadsWithEaten(nil), "Shown at once")
        XCTAssertEqual(quick.waterGoal(nil), 2662)

        var accepted: [PreferencesSnapshot] = []
        let reopened = QuickPreferences(accountID: "a", api: api, defaults: defaults, retryDelays: later) { accepted.append($0) }
        await reopened.waitForSend()
        XCTAssertTrue(reopened.leadsWithEaten(nil), "Kept across a relaunch")
        XCTAssertEqual(reopened.waterGoal(nil), 2662)
        XCTAssertTrue(bodies.isEmpty)

        offline = false
        reopened.flush()
        await reopened.waitForSend()
        XCTAssertFalse(reopened.hasUnsent)
        XCTAssertFalse(reopened.isWaitingForConnection)
        XCTAssertEqual(Set(bodies.flatMap(\.changes.keys)), ["nutritionDisplay", "waterGoalMl"], "Only the two fields")
        XCTAssertEqual(remote.values["nutritionDisplay"], .string("consumed"))
        XCTAssertEqual(remote.values["waterGoalMl"], .number(2662))
        XCTAssertEqual(remote.values["name"], .string("Taylor"))
        XCTAssertEqual(accepted.last?.revision, remote.revision)
        let other = QuickPreferences(accountID: "b", api: api, defaults: defaults, retryDelays: later)
        XCTAssertFalse(other.hasUnsent, "Each account keeps its own")
    }

    /// Review round 1: the water goal saved the whole Your details draft, an
    /// unfinished name with it, and settled a conflict with that draft. It
    /// sends only itself, over another device's save, and the draft and its
    /// base stay as they were.
    func testAQuickPreferenceSendsOnlyItselfAndLeavesTheDetailsDraftAlone() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        var remote = preferencesDocument()
        var bodies: [(key: String, body: PreferenceMutation)] = []
        StubURLProtocol.handler = { request in
            if request.httpMethod == "GET" { return (200, try JSONEncoder().encode(remote)) }
            let body = try JSONDecoder().decode(PreferenceMutation.self, from: Self.requestBody(request))
            bodies.append((request.value(forHTTPHeaderField: "Idempotency-Key") ?? "", body))
            if bodies.count == 1 {
                // Another device saves between the read and this write.
                remote = self.preferencesDocument(revision: remote.revision + 1, values: ["name": .string("Other Device Taylor")])
                return (409, Data(#"{"message":"Preferences changed"}"#.utf8))
            }
            guard body.baseRevision == remote.revision else { return (409, Data(#"{"message":"Preferences changed"}"#.utf8)) }
            remote = self.preferencesDocument(revision: remote.revision + 1, values: remote.values.merging(body.changes) { $1 })
            return (200, try JSONEncoder().encode(remote))
        }
        let details = PreferencesStore(accountID: "a", api: api, defaults: defaults, ownerIsActive: { true })
        await details.load()
        details.edit("name", value: "Unfinished Taylor")
        let savedDraft = defaults.data(forKey: details.storageKey)

        let quick = QuickPreferences(accountID: "a", api: api, defaults: defaults)
        quick.set("waterGoalMl", .number(2662))
        await quick.waitForSend()
        XCTAssertEqual(bodies.count, 2, "Sent again over the other device's save")
        XCTAssertTrue(bodies.allSatisfy { $0.body.changes == ["waterGoalMl": .number(2662)] }, "Only the goal, never the draft's name")
        XCTAssertNotEqual(bodies[0].key, bodies[1].key, "A new write, not a replay of the refused one")
        XCTAssertEqual(remote.values["name"], .string("Other Device Taylor"))
        XCTAssertEqual(remote.values["waterGoalMl"], .number(2662))
        XCTAssertEqual(defaults.data(forKey: details.storageKey), savedDraft, "The unfinished draft is untouched")
        let reopened = PreferencesStore(accountID: "a", api: api, defaults: defaults, ownerIsActive: { true })
        XCTAssertEqual(reopened.draft?.fields["name"], "Unfinished Taylor")
        XCTAssertEqual(reopened.draft?.base.revision, 1, "Its review still compares with what it started from")
    }

    /// A change made while one is sending waits for it and goes next, newest value only.
    func testAQuickPreferenceChangedWhileSendingGoesNext() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        var remote = preferencesDocument()
        var sent: [JSONValue?] = []
        StubURLProtocol.responseDelay = { $0.httpMethod == "PATCH" ? 0.3 : 0 }
        StubURLProtocol.handler = { request in
            if request.httpMethod == "GET" { return (200, try JSONEncoder().encode(remote)) }
            let body = try JSONDecoder().decode(PreferenceMutation.self, from: Self.requestBody(request))
            sent.append(body.changes["waterGoalMl"])
            remote = self.preferencesDocument(revision: remote.revision + 1, values: remote.values.merging(body.changes) { $1 })
            return (200, try JSONEncoder().encode(remote))
        }
        let quick = QuickPreferences(accountID: "a", api: api, defaults: defaults)
        quick.set("waterGoalMl", .number(2000))
        for _ in 0..<200 where sent.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        quick.set("waterGoalMl", .number(2500))
        quick.set("waterGoalMl", .number(3000))
        await quick.waitForSend()
        XCTAssertEqual(sent, [.number(2000), .number(3000)])
        XCTAssertEqual(quick.waterGoal(nil), nil, "Nothing left unsent: the account's own value shows")
        XCTAssertEqual(remote.values["waterGoalMl"], .number(3000))
    }

    func testPreferencesLostAcknowledgementReplaysAfterReopeningAndDoesNotUndoLaterDeviceChanges() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        var remote = preferencesDocument()
        var receipt: PreferencesSnapshot?
        var writes: [(String, Data)] = []
        StubURLProtocol.handler = { request in
            if request.httpMethod == "GET" { return (200, try JSONEncoder().encode(remote)) }
            writes.append((request.value(forHTTPHeaderField: "Idempotency-Key")!, Self.requestBody(request)))
            if writes.count == 1 {
                let body = try JSONDecoder().decode(PreferenceMutation.self, from: Self.requestBody(request))
                XCTAssertEqual(body.changes, ["name": .string("Saved Taylor")])
                XCTAssertEqual(body.baseRevision, 1)
                receipt = self.preferencesDocument(revision: 2, values: body.changes)
                remote = self.preferencesDocument(revision: 3, values: ["name": .string("Saved Taylor"), "dietaryStyle": .string("Other device choice")])
                throw URLError(.networkConnectionLost)
            }
            return (200, try JSONEncoder().encode(XCTUnwrap(receipt)))
        }
        let first = PreferencesStore(accountID: "a", api: api, defaults: defaults, ownerIsActive: { true })
        await first.load()
        first.edit("name", value: "Saved Taylor")
        await first.save()
        XCTAssertNotNil(first.draft?.pending)
        first.edit("name", value: "Cannot edit an unconfirmed operation")
        XCTAssertEqual(first.draft?.fields["name"], "Saved Taylor")
        let reopened = PreferencesStore(accountID: "a", api: api, defaults: defaults, ownerIsActive: { true })
        await reopened.load()
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0].0, writes[1].0)
        XCTAssertEqual(writes[0].1, writes[1].1)
        XCTAssertNil(reopened.draft?.pending)
        XCTAssertEqual(reopened.draft?.base.revision, 3)
        XCTAssertEqual(reopened.draft?.fields["dietaryStyle"], "Other device choice")
        XCTAssertEqual(reopened.draft?.fields["name"], "Saved Taylor")
        XCTAssertNil(reopened.error)
    }

    func testPreferencesConflictRequiresReviewAndRebasesOnlyEditedFieldsIncludingNestedReminders() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        var remote = preferencesDocument()
        var writes: [PreferenceMutation] = []
        StubURLProtocol.handler = { request in
            if request.httpMethod == "GET" { return (200, try JSONEncoder().encode(remote)) }
            let body = try JSONDecoder().decode(PreferenceMutation.self, from: Self.requestBody(request))
            writes.append(body)
            guard body.baseRevision == remote.revision else { return (409, Data(#"{"message":"Preferences changed"}"#.utf8)) }
            var values = remote.values
            for (key, value) in body.changes {
                if case .object(let patch) = value, case .object(var existing) = values[key] {
                    existing.merge(patch) { _, new in new }; values[key] = .object(existing)
                } else { values[key] = value }
            }
            remote = self.preferencesDocument(revision: remote.revision + 1, values: values)
            return (200, try JSONEncoder().encode(remote))
        }
        let store = PreferencesStore(accountID: "a", api: api, defaults: defaults, ownerIsActive: { true })
        await store.load()
        store.edit("name", value: "My edit")
        store.edit("reminders.meals", value: "true")
        remote = preferencesDocument(revision: 2, values: ["name": .string("Other edit"), "workoutDaysPerWeek": .number(5)])
        await store.save()
        XCTAssertEqual(store.conflict?.revision, 2)
        XCTAssertNil(store.draft?.pending)
        XCTAssertEqual(remote.value("name"), .string("Other edit"))
        await store.save()
        XCTAssertEqual(writes.count, 1, "A second Save cannot bypass conflict review")
        // If the account changes again while the user reviews, another review is required.
        remote = preferencesDocument(revision: 3, values: ["name": .string("Another edit"), "workoutDaysPerWeek": .number(5)])
        await store.resolve(useServer: false)
        XCTAssertEqual(store.conflict?.revision, 3)
        await store.resolve(useServer: false)
        XCTAssertNil(store.conflict)
        XCTAssertEqual(remote.value("name"), .string("My edit"))
        XCTAssertEqual(remote.value("workoutDaysPerWeek"), .number(5))
        XCTAssertEqual(remote.value("reminders.workouts"), .bool(true))
        XCTAssertEqual(remote.value("reminders.legacy"), .bool(true))
        XCTAssertEqual(remote.value("reminders.meals"), .bool(true))
        XCTAssertEqual(writes.last?.changes, ["name": .string("My edit"), "reminders": .object(["meals": .bool(true)])])
    }

    func testPreferencesStorageFailuresKeepAnswersAndBlockNetworkWrites() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let memory = TestPreferencesStorage()
        let original = preferencesDocument()
        var writes = 0
        StubURLProtocol.handler = { request in
            if request.httpMethod != "GET" { writes += 1 }
            return (200, try JSONEncoder().encode(original))
        }
        let store = PreferencesStore(accountID: "a", api: api, storage: memory, ownerIsActive: { true })
        await store.load()
        memory.rejectWrites = true
        store.edit("name", value: "Keep this answer")
        await store.save()
        XCTAssertEqual(store.draft?.fields["name"], "Keep this answer")
        XCTAssertNotNil(store.error)
        XCTAssertEqual(writes, 0)
        memory.rejectWrites = false
        memory.data = Data("{unreadable".utf8)
        let corrupt = PreferencesStore(accountID: "a", api: api, storage: memory, ownerIsActive: { true })
        XCTAssertFalse(corrupt.isReadable)
        await corrupt.load()
        await corrupt.save()
        XCTAssertEqual(memory.data, Data("{unreadable".utf8))
        XCTAssertEqual(writes, 0)
    }

    func testPreferencesLateSaveCannotAdoptNewAccountOrEraseTheOldPendingOperation() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        var owned = true
        let original = preferencesDocument()
        StubURLProtocol.handler = { request in
            if request.httpMethod == "GET" { return (200, try JSONEncoder().encode(original)) }
            owned = false
            self.keychain.saveSession(token: "e30.eyJzdWIiOiJiIn0.fixture", refreshToken: "fixture-refresh")
            return (200, try JSONEncoder().encode(self.preferencesDocument(revision: 2, values: ["name": .string("Late Taylor")])))
        }
        var accepted: [Int] = []
        let store = PreferencesStore(accountID: "a", api: api, defaults: defaults, ownerIsActive: { owned }, onAccepted: { accepted.append($0.revision) })
        await store.load()
        store.edit("name", value: "Late Taylor")
        await store.save()
        XCTAssertEqual(accepted, [1])
        XCTAssertNotNil(store.draft?.pending)
        let reopened = PreferencesStore(accountID: "a", api: api, defaults: defaults, ownerIsActive: { true })
        XCTAssertNotNil(reopened.draft?.pending)
        XCTAssertEqual(reopened.draft?.fields["name"], "Late Taylor")
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let auth = AuthViewModel(api: api, keychain: keychain, defaults: defaults, automaticallyCheck: false, onSessionInvalidated: {})
        auth.currentUser = original.user
        let session = auth.sessionID
        auth.acceptPreferences(preferencesDocument(revision: 3, values: ["name": .string("Newest")]).user, accountID: "a", sessionID: session)
        auth.acceptPreferences(original.user, accountID: "a", sessionID: session)
        XCTAssertEqual(auth.currentUser?.name, "Newest")
        // This check exercises local invalidation. Revocation has separate API
        // coverage; do not leave a background request beyond test teardown.
        keychain.deleteToken()
        auth.logout()
        auth.acceptPreferences(original.user, accountID: "a", sessionID: session)
        XCTAssertNil(auth.currentUser)
    }

    func testReminderPlansUseSavedTimeZoneDaysAndTimesWithoutInventingSchedules() throws {
        let values: [String: JSONValue] = [
            "timezone": .string("America/New_York"),
            "reminders": .object(["meals": .bool(true), "workouts": .bool(true), "sleep": .bool(true)]),
            "reminderTimes": .object(["meals": .array([.string("08:30"), .string("12:45"), .string("08:30")]), "workout": .string("17:30"), "sleep": .string("22:00")]),
            "workoutDays": .array([.string("monday"), .string("wednesday"), .string("sunday")])
        ]
        let snapshot = preferencesDocument(values: values)
        let plan = try ReminderPlan.make(snapshot, namespace: "fixture")
        XCTAssertEqual(plan.reminders.count, 6)
        XCTAssertTrue(plan.missing.isEmpty)
        XCTAssertEqual(Set(plan.reminders.map(\.id)).count, 6)
        XCTAssertTrue(plan.reminders.allSatisfy { $0.components.timeZone?.identifier == "America/New_York" })
        XCTAssertEqual(Set(plan.reminders.compactMap { $0.components.weekday }), [1, 2, 4])
        let sleep = try XCTUnwrap(plan.reminders.first { $0.id.hasSuffix(".sleep") })
        XCTAssertEqual(sleep.components.hour, 22)
        XCTAssertEqual(sleep.components.minute, 0)
        XCTAssertNotNil(UNCalendarNotificationTrigger(dateMatching: sleep.components, repeats: true).nextTriggerDate())
        var changed = snapshot
        changed.values["timezone"] = .string("Europe/London")
        let travel = try ReminderPlan.make(changed, namespace: "fixture")
        XCTAssertEqual(plan.reminders.map(\.id), travel.reminders.map(\.id), "Changing zones replaces the same reminder identities")
        XCTAssertTrue(travel.reminders.allSatisfy { $0.components.timeZone?.identifier == "Europe/London" })
        let otherAPI = try ReminderPlan.make(snapshot, namespace: "other-api")
        XCTAssertTrue(Set(plan.reminders.map(\.id)).isDisjoint(with: otherAPI.reminders.map(\.id)))
        changed.values["reminderTimes"] = .object([:])
        let incomplete = try ReminderPlan.make(changed, namespace: "fixture")
        XCTAssertTrue(incomplete.reminders.isEmpty)
        XCTAssertEqual(incomplete.missing.count, 3)
        changed.values["timezone"] = .string("Not/AZone")
        XCTAssertThrowsError(try ReminderPlan.make(changed, namespace: "fixture"))
    }

    func testReminderIntentSurvivesDeniedPermissionAndChangesOnlyThisDeviceDelivery() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let scheduler = TestReminderScheduler()
        scheduler.status = .notDetermined
        scheduler.permissionResult = .denied
        scheduler.pending["unrelated-app-reminder"] = nil
        scheduler.unrelated = ["unrelated-app-reminder"]
        let service = NotificationService(api: api, defaults: defaults, keychain: keychain, scheduler: scheduler)
        service.configure(accountID: "a")
        let saved = preferencesDocument(values: ["reminders": .object(["sleep": .bool(true)]), "reminderTimes": .object(["sleep": .string("22:00")])])
        service.accept(saved)
        await service.waitForSchedule()
        XCTAssertEqual(scheduler.permissionRequests, 0, "Opening preferences must not ask for notification permission")
        XCTAssertFalse(service.isDeviceEnabled)
        await service.setDeviceEnabled(true)
        XCTAssertTrue(service.isDeviceEnabled, "The user's intent is distinct from OS permission")
        XCTAssertEqual(service.authorization, .denied)
        XCTAssertEqual(service.scheduledCount, 0)
        XCTAssertEqual(scheduler.permissionRequests, 1)
        await service.setDeviceEnabled(true)
        XCTAssertEqual(scheduler.permissionRequests, 1, "Denied permission needs Settings, not a repeated prompt")
        scheduler.status = .authorized
        service.accept(saved)
        await service.waitForSchedule()
        XCTAssertEqual(service.scheduledCount, 1)
        XCTAssertEqual(service.scheduled.map(\.title), ["Sleep reminder"], "What iOS holds, for Reminders to list")
        await service.setDeviceEnabled(false)
        XCTAssertEqual(service.scheduledCount, 0)
        let retained = await scheduler.pendingIDs()
        XCTAssertEqual(retained, ["unrelated-app-reminder"])
        XCTAssertEqual(saved.value("reminders.sleep"), .bool(true))
        let reopened = NotificationService(api: api, defaults: defaults, keychain: keychain, scheduler: scheduler)
        reopened.configure(accountID: "a")
        await reopened.waitForSchedule()
        XCTAssertFalse(reopened.isDeviceEnabled)
        await reopened.setDeviceEnabled(true)
        XCTAssertEqual(reopened.scheduledCount, 1, "Saved intent and times remain available after relaunch")
    }

    func testReminderAccountChangeWaitsForInFlightAddThenRemovesOldAccountRequests() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let scheduler = TestReminderScheduler()
        scheduler.holdFirstAdd = true
        let service = NotificationService(api: api, defaults: defaults, keychain: keychain, scheduler: scheduler)
        service.configure(accountID: "a")
        service.accept(preferencesDocument(values: ["reminders": .object(["sleep": .bool(true)]), "reminderTimes": .object(["sleep": .string("22:00")])]))
        let enabling = Task { await service.setDeviceEnabled(true) }
        for _ in 0..<100 where scheduler.releaseAdd == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(scheduler.releaseAdd)
        keychain.saveSession(token: "e30.eyJzdWIiOiJiIn0.fixture", refreshToken: "fixture-refresh")
        service.configure(accountID: "b")
        scheduler.releaseAdd?()
        await enabling.value
        await service.waitForSchedule()
        XCTAssertEqual(service.accountID, "b")
        XCTAssertFalse(service.isDeviceEnabled)
        XCTAssertTrue(scheduler.pending.isEmpty, "The old add must not resurrect a notification after account change")
        await service.refresh(accountID: "a")
        XCTAssertEqual(service.accountID, "b", "A task from the dismissed editor cannot reconfigure the old account")
        // A fresh launch with no signed-in account must also clean up surviving requests.
        scheduler.pending["exerly.reminder.old-account.sleep"] = ReminderSpec(id: "exerly.reminder.old-account.sleep", title: "Old", body: "Old", components: DateComponents())
        let signedOut = NotificationService(api: api, defaults: defaults, keychain: keychain, scheduler: scheduler)
        signedOut.configure(accountID: nil)
        await signedOut.waitForSchedule()
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    func testReminderSchedulingFailureIsVisibleAndDoesNotEraseSavedPreferences() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        let scheduler = TestReminderScheduler()
        scheduler.rejectAdds = true
        let service = NotificationService(api: api, defaults: defaults, keychain: keychain, scheduler: scheduler)
        service.configure(accountID: "a")
        let saved = preferencesDocument(values: ["reminders": .object(["sleep": .bool(true)]), "reminderTimes": .object(["sleep": .string("22:00")])])
        service.accept(saved)
        await service.setDeviceEnabled(true)
        XCTAssertEqual(service.scheduledCount, 0)
        XCTAssertNotNil(service.error)
        XCTAssertTrue(service.isDeviceEnabled)
        scheduler.rejectAdds = false
        service.accept(saved)
        await service.waitForSchedule()
        XCTAssertEqual(service.scheduledCount, 1)
        XCTAssertNil(service.error)
    }

    func testClosedPreferenceEditorCannotOverwriteTheReopenedEditorsNewerDraft() async throws {
        keychain.saveSession(token: "e30.eyJzdWIiOiJhIn0.fixture", refreshToken: "fixture-refresh")
        var remote = preferencesDocument()
        var receipt: PreferencesSnapshot?
        var writes = 0
        StubURLProtocol.handler = { request in
            if request.httpMethod == "GET" { return (200, try JSONEncoder().encode(remote)) }
            writes += 1
            if receipt == nil {
                remote = self.preferencesDocument(revision: 2, values: ["name": .string("First save")])
                receipt = remote
            }
            return (200, try JSONEncoder().encode(XCTUnwrap(receipt)))
        }
        StubURLProtocol.responseDelay = { request in request.httpMethod == "PATCH" && writes == 1 ? 1 : 0 }
        let first = PreferencesStore(accountID: "a", api: api, defaults: defaults, ownerIsActive: { true })
        await first.load()
        first.edit("name", value: "First save")
        let inFlight = Task { await first.save() }
        for _ in 0..<100 where writes == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(writes, 1)
        first.stop()
        let reopened = PreferencesStore(accountID: "a", api: api, defaults: defaults, ownerIsActive: { true })
        await reopened.load()
        XCTAssertNil(reopened.draft?.pending)
        reopened.edit("name", value: "Later unsent draft")
        await inFlight.value
        let latest = PreferencesStore(accountID: "a", api: api, defaults: defaults, ownerIsActive: { true })
        XCTAssertEqual(latest.draft?.fields["name"], "Later unsent draft")
        XCTAssertEqual(latest.draft?.base.revision, 2)
        XCTAssertEqual(writes, 2)
    }

    private func emptyDiary(_ day: String) -> Data {
        Data("{\"date\":\"\(day)\",\"timezone\":\"UTC\",\"consumed\":{\"calories\":0,\"protein\":0,\"carbs\":0,\"fat\":0,\"fiber\":0,\"sugar\":0},\"burned\":0,\"targets\":{\"calories\":2200},\"remaining\":{\"calories\":2200},\"meals\":{},\"activities\":[],\"water_ml\":0,\"entry_count\":0}".utf8)
    }
}

private final class TestPreferencesStorage: PreferencesDraftStorage {
    var data: Data?
    var rejectWrites = false
    func read(_ key: String) throws -> Data? { data }
    func write(_ data: Data, key: String) throws {
        if rejectWrites { throw URLError(.cannotWriteToFile) }
        self.data = data
    }
}

@MainActor
private final class TestReminderScheduler: ReminderScheduling {
    var status: UNAuthorizationStatus = .authorized
    var permissionResult: UNAuthorizationStatus = .authorized
    var permissionRequests = 0
    var pending: [String: ReminderSpec] = [:]
    var unrelated: [String] = []
    var rejectAdds = false
    var holdFirstAdd = false
    var releaseAdd: (() -> Void)?
    func authorization() async -> UNAuthorizationStatus { status }
    func requestPermission() async throws { permissionRequests += 1; status = permissionResult }
    func pendingIDs() async -> [String] { Array(pending.keys) + unrelated }
    func remove(_ ids: [String]) {
        for id in ids { pending[id] = nil }
        unrelated.removeAll { ids.contains($0) }
    }
    func add(_ reminder: ReminderSpec) async throws {
        if holdFirstAdd {
            holdFirstAdd = false
            await withCheckedContinuation { continuation in releaseAdd = { continuation.resume() } }
            releaseAdd = nil
        }
        if rejectAdds { throw URLError(.cannotCreateFile) }
        pending[reminder.id] = reminder
    }
}
