import Foundation

// MARK: - Endpoint Definitions

extension APIClient {
    private struct GoalsSaveResponse: Decodable {
        let goals: GoalsDTO
    }

    private struct DashboardCardResponse: Decodable {
        let label: String
        let value: String
        let route: String?

        enum CodingKeys: String, CodingKey {
            case label, value, route
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.label = (try? container.decode(String.self, forKey: .label)) ?? ""
            if let stringValue = try? container.decode(String.self, forKey: .value) {
                self.value = stringValue
            } else if let intValue = try? container.decode(Int.self, forKey: .value) {
                self.value = String(intValue)
            } else if let doubleValue = try? container.decode(Double.self, forKey: .value) {
                self.value = String(doubleValue)
            } else {
                self.value = ""
            }
            self.route = try? container.decode(String.self, forKey: .route)
        }
    }

    private struct RecentLogResponse: Decodable {
        let type: String
        let activity: ActivityDTO?
        let food: FoodDTO?
        let sleep: SleepDTO?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let activity = try? container.decode(ActivityDTO.self), activity.type.lowercased() == "activity" {
                self.type = "activity"
                self.activity = activity
                self.food = nil
                self.sleep = nil
                return
            }

            let raw = try container.decode([String: StringDecodableValue].self)
            let logType = (raw["type"]?.stringValue ?? "").lowercased()
            self.type = logType

            switch logType {
            case "activity":
                self.activity = ActivityDTO(
                    id: raw["_id"]?.stringValue ?? raw["id"]?.stringValue,
                    type: raw["activity"]?.stringValue ?? "Activity",
                    duration: raw["duration_min"]?.doubleValue ?? 0,
                    calories: raw["calories"]?.doubleValue,
                    intensity: raw["intensity"]?.stringValue,
                    date: raw["entry_date"]?.stringValue
                )
                self.food = nil
                self.sleep = nil
            case "food":
                self.activity = nil
                self.food = FoodDTO(
                    id: raw["_id"]?.stringValue ?? raw["id"]?.stringValue,
                    name: raw["name"]?.stringValue ?? "Food",
                    calories: raw["calories"]?.intValue ?? 0,
                    protein: raw["protein"]?.doubleValue,
                    carbs: raw["carbs"]?.doubleValue,
                    fat: raw["fat"]?.doubleValue,
                    sugar: raw["sugar"]?.doubleValue,
                    servingSize: raw["serving_size"]?.stringValue,
                    date: raw["entry_date"]?.stringValue
                )
                self.sleep = nil
            case "sleep":
                self.activity = nil
                self.food = nil
                self.sleep = SleepDTO(
                    id: raw["_id"]?.stringValue ?? raw["id"]?.stringValue,
                    hours: raw["hours"]?.doubleValue ?? 0,
                    quality: SleepRequest.score(for: raw["quality"]?.stringValue) ?? raw["quality"]?.intValue,
                    bedtime: raw["bedtime"]?.stringValue,
                    wakeTime: raw["wake_time"]?.stringValue,
                    date: raw["entry_date"]?.stringValue
                )
            default:
                self.activity = nil
                self.food = nil
                self.sleep = nil
            }
        }
    }

    private struct StringDecodableValue: Decodable {
        let stringValue: String?
        let intValue: Int?
        let doubleValue: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self.stringValue = string
                self.intValue = Int(string)
                self.doubleValue = Double(string)
            } else if let int = try? container.decode(Int.self) {
                self.stringValue = String(int)
                self.intValue = int
                self.doubleValue = Double(int)
            } else if let double = try? container.decode(Double.self) {
                self.stringValue = String(double)
                self.intValue = Int(double)
                self.doubleValue = double
            } else if let bool = try? container.decode(Bool.self) {
                self.stringValue = String(bool)
                self.intValue = bool ? 1 : 0
                self.doubleValue = bool ? 1 : 0
            } else {
                self.stringValue = nil
                self.intValue = nil
                self.doubleValue = nil
            }
        }
    }

    // MARK: Auth

    func login(email: String, password: String) async throws -> AuthResponse {
        try await post(
            "/login",
            body: AuthRequest(email: email, password: password),
            authenticated: false
        )
    }

    func signup(email: String, password: String, name: String) async throws -> AuthResponse {
        try await post(
            "/signup",
            body: AuthRequest(email: email, password: password, name: name),
            authenticated: false
        )
    }

    func signInWithApple(_ body: AppleSignInRequest) async throws -> AuthResponse {
        try await post("/auth/apple", body: body, authenticated: false)
    }

    /// Asks the server to email a reset code. The answer is the same whether
    /// or not an account uses the address.
    func requestPasswordReset(email: String) async throws -> APIMessageResponse {
        try await post("/auth/password/forgot", body: ["email": email], authenticated: false)
    }

    /// Sets a new password with a mailed code. The server then ends every
    /// session, so the person signs in again.
    func resetPassword(email: String, code: String, newPassword: String) async throws {
        let _: APIMessageResponse = try await post(
            "/auth/password/reset", body: ["email": email, "code": code, "newPassword": newPassword],
            authenticated: false
        )
    }

    // MARK: Onboarding

    func completeOnboarding(_ data: OnboardingRequest, operationID: String) async throws -> OnboardingResponse {
        try await post("/api/onboarding/complete", body: data, operationID: operationID)
    }

    // MARK: Profile

    func getProfile() async throws -> UserDTO {
        try await get("/api/me")
    }

    func updateProfile(_ data: ProfileUpdateRequest) async throws -> UserDTO {
        let _: APIMessageResponse = try await put("/api/profile", body: data)
        return try await getProfile()
    }

    func updateSettings(_ data: SettingsRequest) async throws -> SettingsResponseDTO {
        try await put("/api/settings", body: data)
    }

    // MARK: Activities

    func getActivities() async throws -> [ActivityDTO] {
        try await get("/api/activities")
    }

    func createActivity(_ data: ActivityRequest) async throws -> ActivityDTO {
        try await post("/api/activities", body: data)
    }

    func deleteActivity(id: String) async throws {
        try await deleteVoid("/api/activities/\(id)")
    }

    // MARK: Food

    func getFoodLogs() async throws -> [FoodDTO] {
        try await get("/api/food")
    }

    func createFoodLog(_ data: FoodRequest) async throws -> FoodDTO {
        try await post("/api/food", body: data)
    }

    func deleteFoodLog(id: String) async throws {
        try await deleteVoid("/api/food/\(id)")
    }

    func barcodeLookup(barcode: String, symbology: String? = nil) async throws -> BarcodeLookupResponse {
        try await post("/api/food/barcode-lookup", body: BarcodeLookupRequest(barcode: barcode, symbology: symbology))
    }

    // MARK: Sleep

    func getSleepLogs() async throws -> [SleepDTO] {
        try await get("/api/sleep")
    }

    func createSleepLog(_ data: SleepRequest) async throws -> SleepDTO {
        try await post("/api/sleep", body: data)
    }

    func deleteSleepLog(id: String) async throws {
        try await deleteVoid("/api/sleep/\(id)")
    }

    // MARK: Goals

    func getGoals() async throws -> GoalsDTO {
        try await get("/api/goals")
    }

    func updateGoals(_ data: GoalsDTO) async throws -> GoalsDTO {
        let response: GoalsSaveResponse = try await post("/api/goals", body: data)
        return response.goals
    }

    // MARK: Dashboard

    func getDashboardData() async throws -> DashboardData {
        let cards: [DashboardCardResponse] = try await get("/api/dashboard-data")

        let consumed = cards.first { $0.label == "Calories Consumed" }
            .flatMap { Int($0.value.replacingOccurrences(of: " kcal", with: "")) } ?? 0
        let workouts = cards.first { $0.label == "Total Workouts" }
            .flatMap { Int($0.value) } ?? 0
        let sleepHours = cards.first { $0.label == "Sleep (hrs)" }
            .flatMap { Double($0.value) } ?? 0
        let maintenance = cards.first { $0.label == "Maintenance (est.)" }
            .flatMap { Double($0.value.replacingOccurrences(of: " kcal", with: "")) }

        return DashboardData(
            calories: DashboardCalories(consumed: consumed, target: Int(maintenance ?? 2000)),
            workouts: DashboardWorkouts(completed: workouts, target: 5),
            sleep: DashboardSleep(hours: sleepHours, target: 8),
            maintenance: maintenance
        )
    }

    func getRecentData() async throws -> RecentData {
        let logs: [RecentLogResponse] = try await get("/api/recent")
        return RecentData(
            activities: logs.compactMap(\.activity),
            food: logs.compactMap(\.food),
            sleep: logs.compactMap(\.sleep)
        )
    }

    // MARK: AI

    func getAIPlans() async throws -> [AIPlanDTO] {
        try await get("/api/ai/plans")
    }

    func getAICredits() async throws -> AICreditsDTO {
        try await get("/api/ai/credits")
    }

    func sendAICoach(
        type: String = "custom_question",
        question: String?,
        includeContext: Bool = true
    ) async throws -> AICoachResponseDTO {
        try await post(
            "/api/ai/coach",
            body: AICoachRequest(type: type, question: question, includeContext: includeContext)
        )
    }

    // MARK: Weekly + Water

    func getWeeklyDashboard() async throws -> [WeeklyDayDTO] {
        try await get("/api/dashboard/weekly")
    }

    func getWater() async throws -> WaterDTO {
        try await get("/api/water")
    }

    @discardableResult
    func addWater(delta: Int) async throws -> WaterDTO {
        try await post("/api/water", body: WaterUpdateRequest(glasses: nil, delta: delta))
    }
}

// MARK: - Weight

extension APIClient {
    func getWeights(from: String? = nil, to: String? = nil) async throws -> [WeightDTO] {
        var query: [String] = []
        if let from { query.append("from=\(from)") }
        if let to { query.append("to=\(to)") }
        let suffix = query.isEmpty ? "" : "?" + query.joined(separator: "&")
        return try await get("/api/weight" + suffix)
    }

    /// The smoothed series the weight screen plots. `days` is capped at 730 by
    /// the server.
    func getWeightTrend(days: Int = 90) async throws -> TrendResponseDTO {
        try await get("/api/weight/trend?days=\(days)")
    }

    /// One weigh-in per calendar day; logging twice replaces the earlier value
    /// rather than double-counting it in the trend.
    @discardableResult
    func logWeight(kg: Double, on date: CalendarDay? = nil, bodyFatPct: Double? = nil) async throws -> WeightDTO {
        try await post(
            "/api/weight",
            body: WeightRequest(
                weightKg: kg,
                bodyFatPct: bodyFatPct,
                entryDate: date?.rawValue
            )
        )
    }

    func deleteWeight(id: String) async throws {
        try await deleteVoid("/api/weight/\(id)")
    }
}


// MARK: - Daily summary

extension APIClient {
    /// Everything the diary needs for one day in a single round trip.
    func getDaySummary(for date: CalendarDay? = nil) async throws -> DaySummaryDTO {
        try await get("/api/summary" + (date.map { "?entry_date=\($0.rawValue)" } ?? ""))
    }
}

// MARK: - Food library

extension APIClient {
    /// The user's own foods, most recently used first. This is what a food
    /// picker should open to.
    func getLibraryFoods(limit: Int = 50, favoritesOnly: Bool = false) async throws -> [LibraryFoodDTO] {
        let favorites = favoritesOnly ? "&favorites=true" : ""
        return try await get("/api/library/foods?limit=\(limit)\(favorites)")
    }

    func searchFoods(_ query: String) async throws -> FoodSearchResponseDTO {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return try await get("/api/food/search?q=\(encoded)")
    }

    @discardableResult
    func toggleFavorite(foodId: String) async throws -> LibraryFoodDTO {
        try await post("/api/library/foods/\(foodId)/favorite")
    }

    func createLibraryFood(_ food: LibraryFoodRequest) async throws -> LibraryFoodDTO {
        try await post("/api/library/foods", body: food)
    }
}
