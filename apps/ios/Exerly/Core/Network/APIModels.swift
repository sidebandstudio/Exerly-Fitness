import Foundation

enum UserEnteredNumber {
    static func parse(_ input: String, locale: Locale = .current) -> Double? {
        let decimal = locale.decimalSeparator ?? "."
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: decimal, with: ".")
        var normalized = ""
        for character in value {
            if let digit = character.wholeNumberValue, (0...9).contains(digit) { normalized += String(digit) }
            else if character == "." || character == "-" || character == "+" { normalized.append(character) }
            else { return nil }
        }
        guard let number = Double(normalized), number.isFinite else { return nil }
        return number
    }
}

private extension KeyedDecodingContainer {
    func decodeString(forKeys keys: [K]) -> String? {
        for key in keys {
            if let value = try? decodeIfPresent(String.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return String(value)
            }
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return String(value)
            }
        }
        return nil
    }

    func decodeInt(forKeys keys: [K]) -> Int? {
        for key in keys {
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return Int(value)
            }
            if let str = try? decodeIfPresent(String.self, forKey: key),
               let value = Int(str) {
                return value
            }
        }
        return nil
    }

    func decodeDouble(forKeys keys: [K]) -> Double? {
        for key in keys {
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return Double(value)
            }
            if let str = try? decodeIfPresent(String.self, forKey: key),
               let value = Double(str) {
                return value
            }
        }
        return nil
    }

    func decodeBool(forKeys keys: [K]) -> Bool? {
        for key in keys {
            if let value = try? decodeIfPresent(Bool.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return value != 0
            }
        }
        return nil
    }
}

// MARK: - Auth

struct AuthRequest: Encodable {
    let email: String
    let password: String
    var name: String?
}

struct AppleSignInRequest: Encodable {
    let identityToken: String
    /// The raw nonce; Apple was given its SHA-256.
    let nonce: String
    let name: String?
    let timezone: String
    let unitSystem: String?
}

struct AuthResponse: Decodable {
    let token: String
    let refreshToken: String?
    let user: UserDTO?
}

/// How the account can sign in, so Settings offers only actions that work:
/// disconnecting Apple needs a password.
struct SignInMethods: Decodable, Equatable {
    var password: Bool
    var apple: Bool
}

struct UserDTO: Codable, Identifiable {
    let id: String?
    let email: String
    let name: String?
    let isAdmin: Bool?
    let onboardingCompleted: Bool?
    let age: Int?
    let gender: String?
    let height: Double?
    let weight: Double?
    let activityLevel: String?
    let goal: String?
    let targetWeight: Double?
    let timezone: String?
    let unitSystem: String?
    let aiCreditsRemaining: Int?
    let dailyAiCreditsUsed: Int?
    let hourlyAiCreditsUsed: Int?
    let preferencesRevision: Int?
    /// "consumed" when Today leads with what's eaten; else it leads with what's left.
    let nutritionDisplay: String?
    /// The daily water goal, in millilitres.
    let waterGoalMl: Int?

    /// Today's calories and macros lead with what's eaten, not what's left.
    var leadsWithEaten: Bool { nutritionDisplay == "consumed" }

    init(
        id: String? = nil,
        email: String,
        name: String? = nil,
        isAdmin: Bool? = nil,
        onboardingCompleted: Bool? = nil,
        age: Int? = nil,
        gender: String? = nil,
        height: Double? = nil,
        weight: Double? = nil,
        activityLevel: String? = nil,
        goal: String? = nil,
        targetWeight: Double? = nil,
        timezone: String? = nil,
        unitSystem: String? = nil,
        aiCreditsRemaining: Int? = nil,
        dailyAiCreditsUsed: Int? = nil,
        hourlyAiCreditsUsed: Int? = nil,
        preferencesRevision: Int? = nil,
        nutritionDisplay: String? = nil,
        waterGoalMl: Int? = nil
    ) {
        self.id = id
        self.email = email
        self.name = name
        self.isAdmin = isAdmin
        self.onboardingCompleted = onboardingCompleted
        self.age = age
        self.gender = gender
        self.height = height
        self.weight = weight
        self.activityLevel = activityLevel
        self.goal = goal
        self.targetWeight = targetWeight
        self.timezone = timezone
        self.unitSystem = unitSystem
        self.aiCreditsRemaining = aiCreditsRemaining
        self.dailyAiCreditsUsed = dailyAiCreditsUsed
        self.hourlyAiCreditsUsed = hourlyAiCreditsUsed
        self.preferencesRevision = preferencesRevision
        self.nutritionDisplay = nutritionDisplay
        self.waterGoalMl = waterGoalMl
    }

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case legacyId = "id"
        case email, name
        case isAdmin
        case legacyIsAdmin = "is_admin"
        case onboardingCompleted
        case age, gender, height, weight, goal, timezone, unitSystem
        case activityLevel
        case legacyActivityLevel = "activity_level"
        case targetWeight
        case legacyTargetWeight = "target_weight"
        case aiCreditsRemaining
        case dailyAiCreditsUsed
        case legacyDailyAiCreditsUsed = "aiDailyCreditsUsed"
        case hourlyAiCreditsUsed
        case preferencesRevision
        case nutritionDisplay, waterGoalMl
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(email, forKey: .email)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(isAdmin, forKey: .isAdmin)
        try c.encodeIfPresent(onboardingCompleted, forKey: .onboardingCompleted)
        try c.encodeIfPresent(age, forKey: .age)
        try c.encodeIfPresent(gender, forKey: .gender)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(weight, forKey: .weight)
        try c.encodeIfPresent(activityLevel, forKey: .activityLevel)
        try c.encodeIfPresent(goal, forKey: .goal)
        try c.encodeIfPresent(targetWeight, forKey: .targetWeight)
        try c.encodeIfPresent(timezone, forKey: .timezone)
        try c.encodeIfPresent(unitSystem, forKey: .unitSystem)
        try c.encodeIfPresent(aiCreditsRemaining, forKey: .aiCreditsRemaining)
        try c.encodeIfPresent(dailyAiCreditsUsed, forKey: .dailyAiCreditsUsed)
        try c.encodeIfPresent(hourlyAiCreditsUsed, forKey: .hourlyAiCreditsUsed)
        try c.encodeIfPresent(preferencesRevision, forKey: .preferencesRevision)
        try c.encodeIfPresent(nutritionDisplay, forKey: .nutritionDisplay)
        try c.encodeIfPresent(waterGoalMl, forKey: .waterGoalMl)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: container.decodeString(forKeys: [.id, .legacyId]),
            email: container.decodeString(forKeys: [.email]) ?? "",
            name: container.decodeString(forKeys: [.name]),
            isAdmin: container.decodeBool(forKeys: [.isAdmin, .legacyIsAdmin]),
            onboardingCompleted: container.decodeBool(forKeys: [.onboardingCompleted]),
            age: container.decodeInt(forKeys: [.age]),
            gender: container.decodeString(forKeys: [.gender]),
            height: container.decodeDouble(forKeys: [.height]),
            weight: container.decodeDouble(forKeys: [.weight]),
            activityLevel: container.decodeString(forKeys: [.activityLevel, .legacyActivityLevel]),
            goal: container.decodeString(forKeys: [.goal]),
            targetWeight: container.decodeDouble(forKeys: [.targetWeight, .legacyTargetWeight]),
            timezone: container.decodeString(forKeys: [.timezone]),
            unitSystem: container.decodeString(forKeys: [.unitSystem]),
            aiCreditsRemaining: container.decodeInt(forKeys: [.aiCreditsRemaining]),
            dailyAiCreditsUsed: container.decodeInt(forKeys: [.dailyAiCreditsUsed, .legacyDailyAiCreditsUsed]),
            hourlyAiCreditsUsed: container.decodeInt(forKeys: [.hourlyAiCreditsUsed]),
            preferencesRevision: container.decodeInt(forKeys: [.preferencesRevision]),
            nutritionDisplay: container.decodeString(forKeys: [.nutritionDisplay]),
            waterGoalMl: container.decodeInt(forKeys: [.waterGoalMl])
        )
    }
}

// MARK: - Onboarding

struct OnboardingRequest: Codable {
    let age: Int
    let gender: String
    let height: Double
    let weight: Double
    let activityLevel: String
    let goal: String
    let targetWeight: Double?
    var name: String?
    var sex: String?
    var nutritionGoal: String?
    var nutritionGoalFollowsFitness: Bool?
    var targetMode: String = "estimated"
    var manualTargets: SetupTargets?
    var timezone: String = TimeZone.current.identifier
    var unitSystem: String = "metric"
    var experienceLevel: String = "beginner"
    var workoutDaysPerWeek: Int = 3
    var equipmentAccess: String = "bodyweight"
    var equipment: [String] = []
    var activityTypes: [String] = []
    var dietaryStyle: String = "standard"
    var allergies: [String] = []
    var mealsPerDay: Int = 3
    var sleepGoalHours: Double = 8
    var bedtime: String?
    var wakeTime: String?
    var workoutDays: [String] = []
    var timelineWeeks: Int = 12
    var reminders: [String: Bool] = [:]
    var draftRevision: Int?
    var rateKgPerWeek: Double?
    var dietType: String?
}

struct SetupTargets: Codable, Equatable {
    var calories: Double
    var protein_g: Double
    var carbs_g: Double
    var fat_g: Double
    var fiber_g: Double? = 30
}

struct OnboardingResponse: Decodable {
    let message: String
    let maintenance: Double?
    let user: UserDTO
    let complete: Bool
    let targets: SetupTargets?
}

struct SetupStatus: Decodable {
    let complete: Bool
    let needs_repair: Bool
    let user: UserDTO
    let targets: SetupTargets?
    let repair_reason: String?
    let repair_answers: [String: JSONValue]?
}

struct BootstrapResponse: Decodable {
    let account: UserDTO
    let account_id: String
    let sign_in_methods: SignInMethods?
    let onboarding: SetupStatus
    let targets: SetupTargets?
}

struct SetupPreview: Decodable {
    let maintenance: Double?
    let targets: SetupTargets
}

// MARK: - Activity

struct BodyMeasurementDTO: Codable, Identifiable {
    let id: String
    let client_id: String
    let type: String
    let value: Double
    let unit: String
    let entry_date: String
    let revision: Int
    var note: String?
    var sync_state: String?
    var source: String?
    var day: CalendarDay? { CalendarDay(rawValue: entry_date) }
}

struct BodyMeasurementRequest: Encodable {
    let type: String
    let value: Double
    let unit: String
    let entry_date: String
    var note: String?
    var source: String = "manual"
}

struct BodyMeasurementPage: Decodable {
    let entries: [BodyMeasurementDTO]
    let total: Int
}

struct ActivityDTO: Codable, Identifiable {
    let id: String?
    let type: String
    let duration: Double
    let calories: Double?
    let intensity: String?
    let date: String?
    let category: String?
    let clientID: String?
    let revision: Int
    let createdAt: String?
    let deletedAt: String?
    var syncState: String?

    init(id: String? = nil, type: String, duration: Double, calories: Double?, intensity: String? = nil, date: String? = nil,
         category: String? = nil, clientID: String? = nil, revision: Int = 1, createdAt: String? = nil,
         deletedAt: String? = nil, syncState: String? = nil) {
        self.id = id; self.type = type; self.duration = duration; self.calories = calories
        self.intensity = intensity; self.date = date; self.category = category
        self.clientID = clientID ?? id.map { "legacy-\($0)" }; self.revision = revision
        self.createdAt = createdAt; self.deletedAt = deletedAt; self.syncState = syncState
    }
    enum CodingKeys: String, CodingKey {
        case id = "_id", legacyId = "id", type, activity, duration, legacyDuration = "duration_min"
        case calories, intensity, date, legacyDate = "entry_date"
        case clientID = "client_id", revision, createdAt = "created_at", deletedAt = "deleted_at", syncState = "sync_state"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: c.decodeString(forKeys: [.id, .legacyId]), type: c.decodeString(forKeys: [.activity, .type]) ?? "Activity",
            duration: c.decodeDouble(forKeys: [.duration, .legacyDuration]) ?? 0, calories: c.decodeDouble(forKeys: [.calories]),
            intensity: c.decodeString(forKeys: [.intensity]), date: c.decodeString(forKeys: [.legacyDate, .date]),
            category: c.decodeString(forKeys: [.type]), clientID: c.decodeString(forKeys: [.clientID]),
            revision: c.decodeInt(forKeys: [.revision]) ?? 1, createdAt: c.decodeString(forKeys: [.createdAt]),
            deletedAt: c.decodeString(forKeys: [.deletedAt]), syncState: c.decodeString(forKeys: [.syncState]))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .legacyId); try c.encode(type, forKey: .activity)
        try c.encode(duration, forKey: .legacyDuration); try c.encodeIfPresent(calories, forKey: .calories)
        try c.encodeIfPresent(intensity, forKey: .intensity); try c.encodeIfPresent(date, forKey: .legacyDate)
        try c.encodeIfPresent(category, forKey: .type); try c.encodeIfPresent(clientID, forKey: .clientID)
        try c.encode(revision, forKey: .revision); try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt); try c.encodeIfPresent(syncState, forKey: .syncState)
    }
}

struct ActivityRequest: Encodable {
    let type: String
    let duration: Double
    let calories: Double?
    let intensity: String?
    var entryDate: String?
    var category: String?
    enum CodingKeys: String, CodingKey {
        case activity, durationMin = "duration_min", calories, intensity, type, entryDate = "entry_date"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .activity); try c.encode(duration, forKey: .durationMin)
        try c.encodeIfPresent(calories, forKey: .calories); try c.encodeIfPresent(intensity, forKey: .intensity)
        try c.encodeIfPresent(category, forKey: .type); try c.encodeIfPresent(entryDate, forKey: .entryDate)
    }
}

// MARK: - Food

struct FoodDTO: Decodable, Identifiable {
    let id: String?
    let name: String
    let calories: Int
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let sugar: Double?
    let fiber: Double?
    let barcode: String?
    let brand: String?
    let servingSize: String?
    let mealType: String?
    let date: String?
    let servings: Double
    var clientID: String?
    var revision: Int = 1
    var nutritionBasis: NutritionBasis?
    var nutritionSnapshot: FoodNutritionSnapshot?
    var sodium: Double?
    var saturatedFat: Double?
    var source: String?
    var syncState: String?

    init(
        id: String? = nil,
        name: String,
        calories: Int,
        protein: Double? = nil,
        carbs: Double? = nil,
        fat: Double? = nil,
        sugar: Double? = nil,
        fiber: Double? = nil,
        barcode: String? = nil,
        brand: String? = nil,
        servingSize: String? = nil,
        mealType: String? = nil,
        date: String? = nil,
        servings: Double = 1
    ) {
        self.id = id
        self.name = name
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.sugar = sugar
        self.fiber = fiber
        self.barcode = barcode
        self.brand = brand
        self.servingSize = servingSize
        self.mealType = mealType
        self.date = date
        self.servings = servings
    }

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case legacyId = "id"
        case name, calories, protein, carbs, fat, sugar, fiber, barcode, brand, servings
        case servingSize
        case servingSizeSnake = "serving_size"
        case mealType = "meal_type"
        case date
        case legacyDate = "entry_date"
        case clientID = "client_id"
        case revision, sodium, source
        case saturatedFat = "saturated_fat"
        case nutritionBasis = "nutrition_basis"
        case nutritionSnapshot = "nutrition_snapshot"
        case syncState = "sync_state"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: container.decodeString(forKeys: [.id, .legacyId]),
            name: container.decodeString(forKeys: [.name]) ?? "Food",
            calories: container.decodeInt(forKeys: [.calories]) ?? 0,
            protein: container.decodeDouble(forKeys: [.protein]),
            carbs: container.decodeDouble(forKeys: [.carbs]),
            fat: container.decodeDouble(forKeys: [.fat]),
            sugar: container.decodeDouble(forKeys: [.sugar]),
            fiber: container.decodeDouble(forKeys: [.fiber]),
            barcode: container.decodeString(forKeys: [.barcode]),
            brand: container.decodeString(forKeys: [.brand]),
            servingSize: container.decodeString(forKeys: [.servingSize, .servingSizeSnake]),
            mealType: container.decodeString(forKeys: [.mealType]),
            date: container.decodeString(forKeys: [.date, .legacyDate]),
            servings: container.decodeDouble(forKeys: [.servings]) ?? 1
        )
        clientID = container.decodeString(forKeys: [.clientID])
        revision = container.decodeInt(forKeys: [.revision]) ?? 1
        nutritionBasis = try container.decodeIfPresent(NutritionBasis.self, forKey: .nutritionBasis)
        nutritionSnapshot = try container.decodeIfPresent(FoodNutritionSnapshot.self, forKey: .nutritionSnapshot)
        sodium = container.decodeDouble(forKeys: [.sodium])
        saturatedFat = container.decodeDouble(forKeys: [.saturatedFat])
        source = container.decodeString(forKeys: [.source])
        syncState = container.decodeString(forKeys: [.syncState])
    }
}

struct FoodNutritionSnapshot: Decodable {
    let calories: Double
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let fiber: Double?
    let sugar: Double?
    let sodium: Double?
    let saturated_fat: Double?
}

struct FoodRequest: Encodable {
    let name: String
    let calories: Double
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let sugar: Double?
    let mealType: String?
    let barcode: String?
    let brand: String?
    let fiber: Double?
    let servingSize: String?
    /// How many of `servingSize` were eaten. The macros above are per serving;
    /// the server multiplies through. `var` with a default keeps the memberwise
    /// initializer compatible with existing call sites.
    var servings: Double?
    /// `YYYY-MM-DD`. Omit to log against today in the user's timezone.
    var entryDate: String?
    var nutritionBasis: NutritionBasis?
    var sodium: Double?
    var saturatedFat: Double?
    var source: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(calories, forKey: .calories)
        try container.encodeIfPresent(protein, forKey: .protein)
        try container.encodeIfPresent(carbs, forKey: .carbs)
        try container.encodeIfPresent(fat, forKey: .fat)
        try container.encodeIfPresent(sugar, forKey: .sugar)
        try container.encodeIfPresent(mealType, forKey: .mealType)
        try container.encodeIfPresent(barcode, forKey: .barcode)
        try container.encodeIfPresent(brand, forKey: .brand)
        try container.encodeIfPresent(fiber, forKey: .fiber)
        try container.encodeIfPresent(servingSize, forKey: .servingSize)
        try container.encodeIfPresent(servings, forKey: .servings)
        try container.encodeIfPresent(entryDate, forKey: .entryDate)
        try container.encodeIfPresent(nutritionBasis, forKey: .nutritionBasis)
        try container.encodeIfPresent(sodium, forKey: .sodium)
        try container.encodeIfPresent(saturatedFat, forKey: .saturatedFat)
        try container.encodeIfPresent(source, forKey: .source)
    }

    enum CodingKeys: String, CodingKey {
        case name, calories, protein, carbs, fat, sugar
        case mealType, barcode, brand, fiber, servingSize, servings
        case entryDate = "entry_date"
        case nutritionBasis = "nutrition_basis"
        case sodium, source
        case saturatedFat = "saturated_fat"
    }
}

// MARK: - Barcode Lookup

struct BarcodeLookupRequest: Encodable {
    let barcode: String
    var symbology: String?
}

struct BarcodeLookupResponse: Decodable {
    let found: Bool
    let food: BarcodeFoodDTO?
    let status: String?
    let message: String?
}

struct BarcodeFoodDTO: Decodable, Identifiable {
    let barcode: String?
    let name: String
    let brand: String?
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let fiber: Double?
    let sugar: Double?
    let sodium: Double?
    let saturatedFat: Double?
    let servingSize: String?
    let source: String?
    let missingNutrients: [String]?
    let nutritionBasis: NutritionBasis?
    var id: String { barcode ?? "\(source ?? "")|\(name)|\(brand ?? "")" }

    enum CodingKeys: String, CodingKey {
        case barcode, name, brand, calories, protein, carbs, fat, fiber, sugar, sodium, source
        case servingSize = "serving_size"
        case saturatedFat = "saturated_fat"
        case missingNutrients = "missing_nutrients"
        case nutritionBasis = "nutrition_basis"
    }

    func toOpenFoodItem() -> OpenFoodItem {
        let values: [(String, Double?)] = [("calories", calories), ("protein", protein), ("carbs", carbs), ("fat", fat), ("fiber", fiber), ("sugar", sugar)]
        return OpenFoodItem(barcode: barcode, name: name, brand: brand,
            calories: Int((calories ?? 0).rounded()), protein: protein ?? 0, carbs: carbs ?? 0,
            fat: fat ?? 0, fiber: fiber ?? 0, sugar: sugar ?? 0,
            servingSize: servingSize ?? "1 serving", source: source,
            missingNutrients: missingNutrients ?? values.filter { $0.1 == nil }.map(\.0),
            nutritionBasis: nutritionBasis, sodium: sodium, saturatedFat: saturatedFat, preciseCalories: calories)
    }
    var openFoodItem: OpenFoodItem { toOpenFoodItem() }
}

// MARK: - Sleep

struct SleepDTO: Codable, Identifiable {
    let id: String?
    let hours: Double
    let quality: Int?
    let qualityLabel: String?
    let bedtime: String?
    let wakeTime: String?
    let date: String?
    let clientID: String?
    let revision: Int
    let createdAt: String?
    let deletedAt: String?
    var syncState: String?

    init(id: String? = nil, hours: Double, quality: Int? = nil, bedtime: String? = nil, wakeTime: String? = nil, date: String? = nil,
         qualityLabel: String? = nil, clientID: String? = nil, revision: Int = 1, createdAt: String? = nil,
         deletedAt: String? = nil, syncState: String? = nil) {
        self.id = id; self.hours = hours; self.quality = quality; self.qualityLabel = qualityLabel ?? quality.map(SleepRequest.label)
        self.bedtime = bedtime; self.wakeTime = wakeTime; self.date = date
        self.clientID = clientID ?? id.map { "legacy-\($0)" }; self.revision = revision
        self.createdAt = createdAt; self.deletedAt = deletedAt; self.syncState = syncState
    }
    enum CodingKeys: String, CodingKey {
        case id = "_id", legacyId = "id", hours, quality, bedtime, wakeTime, date
        case legacyWakeTime = "wake_time", legacyDate = "entry_date"
        case clientID = "client_id", revision, createdAt = "created_at", deletedAt = "deleted_at", syncState = "sync_state"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let label = c.decodeString(forKeys: [.quality])
        self.init(id: c.decodeString(forKeys: [.id, .legacyId]), hours: c.decodeDouble(forKeys: [.hours]) ?? 0,
            quality: c.decodeInt(forKeys: [.quality]) ?? SleepRequest.score(for: label),
            bedtime: c.decodeString(forKeys: [.bedtime]), wakeTime: c.decodeString(forKeys: [.wakeTime, .legacyWakeTime]),
            date: c.decodeString(forKeys: [.legacyDate, .date]), qualityLabel: label,
            clientID: c.decodeString(forKeys: [.clientID]), revision: c.decodeInt(forKeys: [.revision]) ?? 1,
            createdAt: c.decodeString(forKeys: [.createdAt]), deletedAt: c.decodeString(forKeys: [.deletedAt]),
            syncState: c.decodeString(forKeys: [.syncState]))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .legacyId); try c.encode(hours, forKey: .hours)
        try c.encodeIfPresent(qualityLabel, forKey: .quality); try c.encodeIfPresent(bedtime, forKey: .bedtime)
        try c.encodeIfPresent(wakeTime, forKey: .legacyWakeTime); try c.encodeIfPresent(date, forKey: .legacyDate)
        try c.encodeIfPresent(clientID, forKey: .clientID); try c.encode(revision, forKey: .revision)
        try c.encodeIfPresent(createdAt, forKey: .createdAt); try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try c.encodeIfPresent(syncState, forKey: .syncState)
    }
}

struct SleepRequest: Encodable {
    let hours: Double
    let quality: String?
    let bedtime: String?
    let wakeTime: String?
    /// `YYYY-MM-DD`. Omit to log against today in the user's timezone.
    var entryDate: String?

    enum CodingKeys: String, CodingKey {
        case hours, quality, bedtime, wakeTime
        case entryDate = "entry_date"
    }

    static func label(for score: Int) -> String {
        switch score {
        case ..<2: return "poor"
        case 2: return "fair"
        case 3: return "good"
        case 4: return "great"
        default: return "excellent"
        }
    }

    static func score(for label: String?) -> Int? {
        switch label?.lowercased() {
        case "poor": return 1
        case "fair": return 2
        case "good": return 3
        case "great": return 4
        case "excellent": return 5
        default: return nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hours, forKey: .hours)
        try container.encodeIfPresent(quality, forKey: .quality)
        try container.encode(bedtime, forKey: .bedtime)
        try container.encode(wakeTime, forKey: .wakeTime)
        try container.encodeIfPresent(entryDate, forKey: .entryDate)
    }
}

// MARK: - Goals

struct GoalsDTO: Codable {
    let id: String?
    let dailyCalories: Int?
    let weeklyWorkouts: Int?
    let dailySteps: Int?
    let targetWeight: Double?
    let sleepHours: Double?
    let waterGlasses: Int?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case legacyId = "id"
        case dailyCalories
        case dailyCaloriesSnake = "daily_calories"
        case weeklyWorkouts
        case weeklyWorkoutsSnake = "weekly_workouts"
        case dailySteps
        case dailyStepsSnake = "daily_steps"
        case targetWeight
        case weeklyWeight = "weekly_weight"
        case sleepHours
        case sleepHoursSnake = "sleep_hours"
        case waterGlasses
        case waterIntake = "water_intake"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = container.decodeString(forKeys: [.id, .legacyId])
        self.dailyCalories = container.decodeInt(forKeys: [.dailyCalories, .dailyCaloriesSnake])
        self.weeklyWorkouts = container.decodeInt(forKeys: [.weeklyWorkouts, .weeklyWorkoutsSnake])
        self.dailySteps = container.decodeInt(forKeys: [.dailySteps, .dailyStepsSnake])
        self.targetWeight = container.decodeDouble(forKeys: [.targetWeight, .weeklyWeight])
        self.sleepHours = container.decodeDouble(forKeys: [.sleepHours, .sleepHoursSnake])
        self.waterGlasses = container.decodeInt(forKeys: [.waterGlasses, .waterIntake])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(dailyCalories, forKey: .dailyCalories)
        try container.encodeIfPresent(weeklyWorkouts, forKey: .weeklyWorkouts)
        try container.encodeIfPresent(dailySteps, forKey: .dailySteps)
        try container.encodeIfPresent(targetWeight, forKey: .weeklyWeight)
        try container.encodeIfPresent(sleepHours, forKey: .sleepHours)
        try container.encodeIfPresent(waterGlasses, forKey: .waterIntake)
    }
}

// MARK: - Dashboard

struct DashboardData: Decodable {
    let calories: DashboardCalories?
    let workouts: DashboardWorkouts?
    let sleep: DashboardSleep?
    let maintenance: Double?
}

struct DashboardCalories: Decodable {
    let consumed: Int
    let target: Int
}

struct DashboardWorkouts: Decodable {
    let completed: Int
    let target: Int
}

struct DashboardSleep: Decodable {
    let hours: Double
    let target: Double
}

// MARK: - Recent

struct RecentData: Decodable {
    let activities: [ActivityDTO]?
    let food: [FoodDTO]?
    let sleep: [SleepDTO]?
}

// MARK: - Profile

struct ProfileUpdateRequest: Encodable {
    var name: String?
    var age: Int?
    var gender: String?
    var height: Double?
    var weight: Double?
    var activityLevel: String?
    var goal: String?
    var targetWeight: Double?
}

struct SettingsRequest: Encodable {
    let timezone: String
    let unitSystem: String
}

struct SettingsResponseDTO: Decodable {
    let message: String
    let user: UserDTO
}

// MARK: - AI

struct AICoachRequest: Encodable {
    let type: String
    let question: String?
    let includeContext: Bool

    enum CodingKeys: String, CodingKey { case type, question, includeContext }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(question, forKey: .question)
        try c.encode(includeContext, forKey: .includeContext)
    }
}

struct AICoachResponseDTO: Decodable {
    let response: String
    let creditsRemaining: Int?
    let dailyUsed: Int?
    let planId: String?
}

struct WeeklyDayDTO: Decodable, Identifiable {
    let date: String
    let label: String
    let consumed: Int
    let burned: Int
    var id: String { date }
}

struct WaterDTO: Decodable {
    let glasses: Int
}

struct WaterUpdateRequest: Encodable {
    let glasses: Int?
    let delta: Int?
}

struct AIPlanDTO: Decodable, Identifiable {
    let id: String?
    let type: String
    let content: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case legacyId = "id"
        case type, content, response, plan, createdAt, created_at
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = container.decodeString(forKeys: [.id, .legacyId])
        self.type = container.decodeString(forKeys: [.type]) ?? "plan"
        self.content = container.decodeString(forKeys: [.content, .response, .plan]) ?? ""
        self.createdAt = container.decodeString(forKeys: [.createdAt, .created_at])
    }
}

struct AICreditsDTO: Decodable {
    let creditsRemaining: Int
    let hourlyCreditsUsed: Int
    let dailyCreditsUsed: Int
    let maxHourly: Int
    let maxDaily: Int
    let timeUntilHourlyReset: String?
    let hoursUntilMidnight: Int?

    enum CodingKeys: String, CodingKey {
        case creditsRemaining, hourlyCreditsUsed, dailyCreditsUsed
        case maxHourly, maxDaily, timeUntilHourlyReset, hoursUntilMidnight
        case hourly, daily
    }

    enum NestedCreditKeys: String, CodingKey {
        case remaining, used, limit, resetTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.hourly) || container.contains(.daily) {
            let hourly = try container.nestedContainer(keyedBy: NestedCreditKeys.self, forKey: .hourly)
            let daily = try container.nestedContainer(keyedBy: NestedCreditKeys.self, forKey: .daily)
            self.creditsRemaining = hourly.decodeInt(forKeys: [.remaining]) ?? 0
            self.hourlyCreditsUsed = max(0, (hourly.decodeInt(forKeys: [.limit]) ?? 0) - creditsRemaining)
            self.dailyCreditsUsed = daily.decodeInt(forKeys: [.used]) ?? 0
            self.maxHourly = hourly.decodeInt(forKeys: [.limit]) ?? 0
            self.maxDaily = daily.decodeInt(forKeys: [.limit]) ?? 0
            self.timeUntilHourlyReset = hourly.decodeString(forKeys: [.resetTime])
            let dailyReset = daily.decodeString(forKeys: [.resetTime])
            self.hoursUntilMidnight = dailyReset.flatMap { Int($0) }
        } else {
            self.creditsRemaining = container.decodeInt(forKeys: [.creditsRemaining]) ?? 0
            self.hourlyCreditsUsed = container.decodeInt(forKeys: [.hourlyCreditsUsed]) ?? 0
            self.dailyCreditsUsed = container.decodeInt(forKeys: [.dailyCreditsUsed]) ?? 0
            self.maxHourly = container.decodeInt(forKeys: [.maxHourly]) ?? 0
            self.maxDaily = container.decodeInt(forKeys: [.maxDaily]) ?? 0
            self.timeUntilHourlyReset = container.decodeString(forKeys: [.timeUntilHourlyReset])
            self.hoursUntilMidnight = container.decodeInt(forKeys: [.hoursUntilMidnight])
        }
    }
}

// MARK: - Weight

/// Weight is kilograms on the wire, always. Pounds are a display concern.
struct WeightRequest: Encodable {
    let weightKg: Double
    var bodyFatPct: Double?
    var note: String?
    var entryDate: String?

    enum CodingKeys: String, CodingKey {
        case weight
        case bodyFatPct
        case note
        case entryDate = "entry_date"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(weightKg, forKey: .weight)
        try container.encodeIfPresent(bodyFatPct, forKey: .bodyFatPct)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(entryDate, forKey: .entryDate)
    }
}

struct WeightDTO: Decodable, Identifiable {
    let id: String?
    let weightKg: Double
    let bodyFatPct: Double?
    let note: String?
    let entryDate: String?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case altId = "id"
        case weightKg = "weight_kg"
        case bodyFatPct = "body_fat_pct"
        case note
        case entryDate = "entry_date"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = container.decodeString(forKeys: [.id, .altId])
        self.weightKg = container.decodeDouble(forKeys: [.weightKg]) ?? 0
        self.bodyFatPct = container.decodeDouble(forKeys: [.bodyFatPct])
        self.note = container.decodeString(forKeys: [.note])
        self.entryDate = container.decodeString(forKeys: [.entryDate])
    }
}

struct WeightDayDTO: Codable, Identifiable {
    let entry_date: String
    let weight_kg: Double?
    let revision: Int
    var id: String? = nil
    var source: String? = nil
    var note: String? = nil
    var body_fat_pct: Double? = nil
    var deleted_at: String? = nil
    var sync_state: String? = nil
    var exists: Bool { weight_kg != nil && deleted_at == nil }
    static func initial(_ day: String) -> Self { Self(entry_date: day, weight_kg: nil, revision: 0) }
}

/// One calendar day of the trend series. `weight` is nil on days with no
/// weigh-in; `trend` is always present because it carries across gaps.
struct TrendPointDTO: Decodable, Identifiable {
    let date: String
    let weight: Double?
    let trend: Double

    var id: String { date }
}

struct TrendSummaryDTO: Decodable {
    let currentTrendKg: Double
    let currentWeightKg: Double?
    let changeKg: Double
    let weeklyRateKg: Double
    let weighIns: Int
    let days: Int

    enum CodingKeys: String, CodingKey {
        case currentTrendKg = "current_trend_kg"
        case currentWeightKg = "current_weight_kg"
        case changeKg = "change_kg"
        case weeklyRateKg = "weekly_rate_kg"
        case weighIns = "weigh_ins"
        case days
    }
}

struct TrendResponseDTO: Decodable {
    let from: String
    let to: String
    let series: [TrendPointDTO]
    let summary: TrendSummaryDTO?
}

extension TrendResponseDTO {
    static func savedWeights(_ readings: [WeightDayDTO], from: String, to: String) -> Self {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        var series: [TrendPointDTO] = []
        let byDay = Dictionary(readings.filter(\.exists).map { ($0.entry_date, $0.weight_kg!) }, uniquingKeysWith: { _, last in last })
        var trend: Double?
        var cursor = formatter.date(from: from)
        while let date = cursor, formatter.string(from: date) <= to {
            let day = formatter.string(from: date)
            let weight = byDay[day]
            if let weight { trend = trend.map { $0 + 0.1 * (weight - $0) } ?? weight }
            if let trend { series.append(TrendPointDTO(date: day, weight: weight, trend: (trend * 100).rounded() / 100)) }
            cursor = calendar.date(byAdding: .day, value: 1, to: date)
        }
        var summary: TrendSummaryDTO?
        if let first = series.first, let last = series.last {
            let change = last.trend - first.trend
            let rate = series.count > 1 ? change / Double(series.count - 1) * 7 : 0
            summary = TrendSummaryDTO(currentTrendKg: last.trend, currentWeightKg: series.last(where: { $0.weight != nil })?.weight,
                changeKg: (change * 100).rounded() / 100, weeklyRateKg: (rate * 1000).rounded() / 1000,
                weighIns: readings.filter { $0.exists && $0.entry_date >= from && $0.entry_date <= to }.count, days: series.count)
        }
        return Self(from: from, to: to, series: series, summary: summary)
    }
}

// MARK: - Daily Summary

struct MacroTotalsDTO: Decodable {
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let fiber: Double
    let sugar: Double
}

struct SummaryTargetsDTO: Decodable {
    let calories: Int?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let fiberG: Double?
    let waterMl: Int?

    enum CodingKeys: String, CodingKey {
        case calories
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case fiberG = "fiber_g"
        case waterMl = "water_ml"
    }
}

struct MealBucketDTO: Decodable {
    let entries: [FoodDTO]
    let totals: MacroTotalsDTO
}

/// Everything one diary day needs, in a single request.
enum DiaryLoggingStatus: String, Codable, CaseIterable, Identifiable {
    case inProgress = "in_progress", complete, estimated, excluded
    var id: String { rawValue }
    var title: String {
        switch self {
        case .inProgress: return "In progress"
        case .complete: return "Complete"
        case .estimated: return "Estimated"
        case .excluded: return "Excluded"
        }
    }
    var explanation: String {
        switch self {
        case .inProgress: return "Keep logging. This day does not count as a complete intake day."
        case .complete: return "All food and drinks are recorded. This day can inform your expenditure estimate when enough measurements are available."
        case .estimated: return "Some entries are estimates. This day stays out of the expenditure calculation."
        case .excluded: return "Keep these entries for your records without using this day in the expenditure calculation."
        }
    }
}

struct DiaryDayDTO: Codable {
    let entry_date: String
    let status: DiaryLoggingStatus
    let note: String?
    let revision: Int
    var sync_state: String? = nil
    static func initial(_ day: String) -> Self {
        Self(entry_date: day, status: .inProgress, note: nil, revision: 0)
    }
}

struct WaterDayDTO: Codable {
    let entry_date: String
    let ml: Int
    let revision: Int
    var sync_state: String? = nil
}

struct DaySummaryDTO: Decodable {
    let date: String
    let timezone: String
    let consumed: MacroTotalsDTO
    let burned: Int
    let targets: SummaryTargetsDTO
    let remaining: SummaryTargetsDTO
    let meals: [String: MealBucketDTO]
    let activities: [ActivityDTO]
    let sleep: SleepDTO?
    let sleepEntries: [SleepDTO]?
    let sleepHours: Double?
    let waterMl: Int
    let water: WaterDayDTO?
    let weight: WeightDTO?
    let entryCount: Int
    let diaryDay: DiaryDayDTO?

    enum CodingKeys: String, CodingKey {
        case date, timezone, consumed, burned, targets, remaining, meals, activities, sleep, weight, water
        case waterMl = "water_ml"
        case entryCount = "entry_count"
        case sleepEntries = "sleep_entries", sleepHours = "sleep_hours"
        case diaryDay = "diary_day"
    }
}

// MARK: - Food Library

/// An entry in the user's personal food library. Macros are per serving, so
/// logging it again with a different serving count scales correctly.
struct LibraryFoodDTO: Decodable, Identifiable {
    let id: String
    let name: String
    let brand: String?
    let barcode: String?
    let calories: Double
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let fiber: Double?
    let sugar: Double?
    let servingSize: String?
    let source: String?
    let isFavorite: Bool
    let useCount: Int
    let nutritionBasis: NutritionBasis?
    let sodium: Double?
    let saturatedFat: Double?

    enum CodingKeys: String, CodingKey {
        case id = "id"
        case underscoreId = "_id"
        case name, brand, barcode, calories, protein, carbs, fat, fiber, sugar, source
        case servingSize = "serving_size"
        case isFavorite = "is_favorite"
        case useCount = "use_count"
        case nutritionBasis = "nutrition_basis"
        case sodium
        case saturatedFat = "saturated_fat"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = container.decodeString(forKeys: [.id, .underscoreId]) ?? ""
        self.name = container.decodeString(forKeys: [.name]) ?? ""
        self.brand = container.decodeString(forKeys: [.brand])
        self.barcode = container.decodeString(forKeys: [.barcode])
        self.calories = container.decodeDouble(forKeys: [.calories]) ?? 0
        self.protein = container.decodeDouble(forKeys: [.protein])
        self.carbs = container.decodeDouble(forKeys: [.carbs])
        self.fat = container.decodeDouble(forKeys: [.fat])
        self.fiber = container.decodeDouble(forKeys: [.fiber])
        self.sugar = container.decodeDouble(forKeys: [.sugar])
        self.servingSize = container.decodeString(forKeys: [.servingSize])
        self.source = container.decodeString(forKeys: [.source])
        self.isFavorite = container.decodeBool(forKeys: [.isFavorite]) ?? false
        self.useCount = container.decodeInt(forKeys: [.useCount]) ?? 0
        self.nutritionBasis = try container.decodeIfPresent(NutritionBasis.self, forKey: .nutritionBasis)
        self.sodium = container.decodeDouble(forKeys: [.sodium])
        self.saturatedFat = container.decodeDouble(forKeys: [.saturatedFat])
    }
}

/// Search results, split so the user's own foods can be shown first.
struct FoodSearchResponseDTO: Decodable {
    let query: String
    let library: [LibraryFoodDTO]
    let results: [SearchFoodDTO]
}

struct LibraryFoodRequest: Encodable {
    let name: String
    let brand: String?
    let calories: Int
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let fiber: Double?
    let sugar: Double?
    let servingSize: String?
    var isFavorite = false
    var barcode: String?
}

typealias SearchFoodDTO = BarcodeFoodDTO

extension LibraryFoodDTO {
    var openFoodItem: OpenFoodItem {
        OpenFoodItem(
            barcode: barcode,
            name: name,
            brand: brand,
            calories: Int(calories.rounded()),
            protein: protein ?? 0,
            carbs: carbs ?? 0,
            fat: fat ?? 0,
            fiber: fiber ?? 0,
            sugar: sugar ?? 0,
            servingSize: servingSize ?? "1 serving",
            source: source,
            missingNutrients: [("protein", protein), ("carbs", carbs), ("fat", fat), ("fiber", fiber), ("sugar", sugar)].compactMap { $0.1 == nil ? $0.0 : nil },
            nutritionBasis: nutritionBasis, sodium: sodium, saturatedFat: saturatedFat, preciseCalories: calories
        )
    }
}
