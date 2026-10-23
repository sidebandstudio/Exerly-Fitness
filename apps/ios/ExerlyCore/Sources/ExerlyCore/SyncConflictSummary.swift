import Foundation

/// A conflict in plain words: the record, what each device has for what
/// both changed ("This iPhone: 60 g", "Another device: 90 g, 2:14 PM"),
/// and what each choice does.
public struct SyncConflictSummary: Sendable, Hashable {
    public struct Side: Sendable, Hashable {
        /// "This iPhone", "iPad" or "Another device".
        public var device: String
        /// "60 g", or "Deleted".
        public var value: String
        /// When the server took that version, when known.
        public var time: String?
        /// This device has this version now.
        public var shown: Bool
    }

    public struct Option: Sendable, Hashable, Identifiable {
        public var id: SyncConflict.Choice { choice }
        public var choice: SyncConflict.Choice
        public var title: String
        /// What was done, once chosen: "Kept the other device's".
        public var done: String
    }

    public var title: String
    /// "Lunch · Tue 20 Oct", when there's more to say.
    public var detail: String?
    /// "Both devices changed the amount."
    public var explanation: String
    public var local: Side
    public var remote: Side
    /// What this device has now, when it's neither version: "45 g".
    public var now: String?
    /// "Too large to sync, so it's only on this iPhone."
    public var note: String?
    public var options: [Option]
}

extension SyncConflict {
    /// Words for this conflict as seen on `viewer`, with masses in `unit`
    /// and times in `timeZone`. With `replaced`, the record was logged again
    /// from the same scan, so bringing it back changes that entry instead.
    /// `current` is the record on `viewer` now, nil when deleted; without
    /// it, the version of the device that found the conflict is shown.
    public func summary(on viewer: SyncDevice, unit: MassUnit, timeZone: TimeZone, locale: Locale = .current,
                        replaced: Bool = false, current: JSONValue?? = .none) -> SyncConflictSummary {
        let words = ConflictWords(kind: kind, unit: unit, timeZone: timeZone, locale: locale)
        let here = device.id == viewer.id
        let localName = here ? "This \(device.name)" : device.name
        let localOwner = here ? "this \(device.name)'s" : "the \(device.name)'s"
        let shown = remote ?? local ?? base
        let (title, detail) = words.title(shown)
        func value(_ version: JSONValue?) -> String {
            guard let version else { return "Deleted" }
            let parts = (fields.isEmpty ? words.headline : fields).map { words.value($0, in: version) }
            return Array(NSOrderedSet(array: parts)).compactMap { $0 as? String }.joined(separator: ", ")
        }
        let now = current ?? local
        /// Whether `now` has this version: deleted or not, and each clashing
        /// field there and as in it. A list's order compares as it applies.
        func shows(_ version: JSONValue?) -> Bool {
            guard let version, let now else { return version == nil && now == nil }
            if isDeletion { return true }
            let paths = fields.flatMap { field in Self.groups(kind).first { $0.first == field } ?? [field] }
            return paths.allSatisfy { path in
                path == "*" || path.hasSuffix("[]")
                    ? Merge.apply([path], from: version, to: now) == now
                    : Merge.value(at: path, in: version) == Merge.value(at: path, in: now)
            }
        }
        /// What the clash was about and this device has removed since, a set
        /// or an exercise, while a version still has it.
        let removed: String? = isDeletion ? nil : now.flatMap { now in
            fields.first { path in
                Merge.lacksItem(at: path, in: now) && [local, remote].contains { $0.map { !Merge.lacksItem(at: path, in: $0) } ?? false }
            }.map { path in
                let exercise = String(path.split(separator: ".")[0])
                return Merge.lacksItem(at: exercise, in: now) ? (exercise.hasPrefix("exercises[") ? "exercise" : "item")
                    : path.contains("sets[") ? "set" : "item"
            }
        }
        let explanation: String
        let options: [SyncConflictSummary.Option]
        if isDeletion {
            let deletedHere = local == nil
            explanation = deletedHere
                ? "Deleted on \(localName.lowercasedFirst), changed on another device."
                : "Changed on \(localName.lowercasedFirst), deleted on another device."
            let bringBack = deletedHere
                ? (replaced ? "Use the other device's version for the one you logged again" : "Bring back the other device's version")
                : "Bring back \(localOwner) version"
            let broughtBack = deletedHere ? (replaced ? "Used the other device's version" : "Brought back the other device's version")
                : "Brought back \(localOwner) version"
            options = choices.map { choice in
                let keepsDeleted = (choice == .local) == deletedHere
                return keepsDeleted ? .init(choice: choice, title: "Keep it deleted", done: "Kept it deleted")
                    : .init(choice: choice, title: bringBack, done: broughtBack)
            }
        } else {
            explanation = "Both devices changed the \(words.list(fields.map(words.name)))."
                + (removed.map { " This \(viewer.name) removed the \($0) since." } ?? "")
            options = removed.map { noun in
                choices.map { choice in
                    let owner = choice == .local ? localOwner : "the other device's"
                    return .init(choice: choice, title: "Bring the \(noun) back as \(owner)", done: "Brought the \(noun) back")
                } + [.init(choice: .current, title: "Leave it removed", done: "Left it removed")]
            } ?? choices.map { choice in
                switch choice {
                case .local: .init(choice: choice, title: "Keep \(localOwner)", done: "Kept \(localOwner)")
                case .remote: .init(choice: choice, title: "Keep the other device's", done: "Kept the other device's")
                case .both: .init(choice: choice, title: "Keep both", done: "Kept both")
                case .current: .init(choice: choice, title: "Keep it as it is", done: "Kept it as it is")
                }
            }
        }
        let (localShown, remoteShown) = (shows(local), shows(remote))
        return SyncConflictSummary(
            title: title, detail: detail, explanation: explanation,
            local: .init(device: localName, value: value(local), time: nil, shown: localShown),
            remote: .init(device: "Another device", value: value(remote), time: remoteAt.map(words.time), shown: remoteShown && !localShown),
            now: localShown || remoteShown ? nil : value(now),
            note: tooLarge == true ? "Too large to sync, so it's only on \(here ? "this \(device.name)" : "the \(device.name)")." : nil,
            options: options
        )
    }
}

extension SyncConflict {
    /// Fields that clash together, as the record's host merges them.
    static func groups(_ kind: String) -> [[String]] { NutritionStore.fieldGroups(of: kind) }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

/// How each kind's fields read.
private struct ConflictWords {
    let kind: String
    let unit: MassUnit
    let timeZone: TimeZone
    let locale: Locale

    /// What a deletion conflict shows of each version.
    var headline: [String] {
        switch kind {
        case "food_entry": ["grams"]
        case "weight_entry": ["weight"]
        case "nutrition_day": ["status"]
        default: ["*"]
        }
    }

    func name(_ field: String) -> String {
        switch (kind, field) {
        case ("food_entry", "grams"): "amount"
        case ("food_entry", "loggedAt"), ("weight_entry", "at"): "time"
        case ("food_entry", "date"): "day"
        case ("nutrition_day", "notes"): "note"
        case (_, "per100g"): "nutrients"
        case (_, "*"): "details"
        case (_, "exercises[]"): "order of the exercises"
        default:
            // A workout's sets and exercises read by what they are.
            field.hasSuffix("sets[]") ? "order of the sets" : field.contains("sets[") ? "sets" : field.hasPrefix("exercises") ? "exercises"
                : field.reduce(into: "") { text, character in
                    text += character.isUppercase ? " \(character.lowercased())" : String(character)
                }
        }
    }

    func list(_ names: [String]) -> String {
        let unique = Array(NSOrderedSet(array: names)).compactMap { $0 as? String }
        guard unique.count > 1 else { return unique.first ?? "details" }
        return unique.dropLast().joined(separator: ", ") + " and " + unique.last!
    }

    func title(_ version: JSONValue?) -> (String, String?) {
        let fields = version?.objectValue ?? [:]
        let name = fields["name"]?.stringValue
        let day = fields["date"]?.stringValue.flatMap(LocalDate.init).map(self.day)
        switch kind {
        case "food_entry":
            let food = fields["food"]?.objectValue?["name"]?.stringValue ?? "A food"
            return (food, [fields["meal"]?.stringValue, day].compactMap { $0 }.joined(separator: " · "))
        case "weight_entry": return ("Weigh-in", day)
        case "nutrition_day": return (day ?? "A day", "Day status and note")
        case "saved_food": return (name ?? "A food", "Saved food")
        case "nutrition_plan": return ("Nutrition plan", nil)
        case "workout_session": return (name ?? "Workout", fields["startedAt"]?.stringValue.flatMap(date).map(self.dayOf))
        case "program": return (name ?? "Program", "Program")
        case "custom_exercise": return (name ?? "Exercise", "Custom exercise")
        case "gym_profile": return (name ?? "Gym", "Gym")
        default: return (name ?? "A record", nil)
        }
    }

    func value(_ field: String, in version: JSONValue) -> String {
        let fields = version.objectValue ?? [:]
        if field.contains("[") { return workout(field, in: fields) }
        switch (kind, field) {
        case ("food_entry", "grams"):
            let grams = fields["grams"]?.numberValue ?? 0
            let amount = "\(number(grams)) g"
            if let serving = fields["serving"]?.objectValue?["name"]?.stringValue, let quantity = fields["quantity"]?.numberValue {
                return "\(number(quantity)) × \(serving), \(amount)"
            }
            return amount
        case ("food_entry", "food"): return fields["food"]?.objectValue?["name"]?.stringValue ?? "Another food"
        case ("weight_entry", "weight"):
            guard let weight = fields["weight"].flatMap({ try? $0.decode(Mass.self) }) else { return "A weight" }
            return mass(weight)
        case ("nutrition_day", "status"):
            switch fields["status"]?.stringValue {
            case "complete": return "Complete"
            case "partial": return "Partly logged"
            case "fasting": return "Fasting"
            default: return "Not logged"
            }
        case ("nutrition_day", "notes"):
            let note = fields["notes"]?.stringValue ?? ""
            return note.isEmpty ? "No note" : "“\(note)”"
        case (_, "date"):
            return fields["date"]?.stringValue.flatMap(LocalDate.init).map(day) ?? "Another day"
        case (_, "loggedAt"), (_, "at"):
            return fields[field]?.stringValue.flatMap(date).map(time) ?? "Another time"
        case ("nutrition_plan", "goal"):
            guard let goal = fields["goal"].flatMap({ try? $0.decode(NutritionGoal.self) }) else { return "No goal" }
            let rate = (goal.weeklyRate * 100).formatted(.number.precision(.fractionLength(0...2)).locale(locale))
            let target = goal.goalWeight.map { " to \(mass($0))" } ?? ""
            switch goal.direction {
            case .maintain: return "Maintain" + target
            case .lose: return "Lose \(rate)% a week" + target
            case .gain: return "Gain \(rate)% a week" + target
            }
        default:
            return plain(fields[field])
        }
    }

    /// Any other value as it reads: text, a number, on or off, a mass, or
    /// the first few named values of a group.
    private func plain(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text)?: return text.isEmpty ? "Empty" : text
        case .number(let value)?: return number(value)
        case .bool(let value)?: return value ? "On" : "Off"
        case nil, .null?: return "None"
        case .array(let items)?: return items.isEmpty ? "None" : items.count == 1 ? "1 item" : "\(items.count) items"
        case .object(let fields)?:
            if let weight = try? value?.decode(Mass.self) { return mass(weight) }
            let parts = fields.sorted { $0.key < $1.key }.compactMap { key, value -> String? in
                switch value {
                case .string, .number, .bool: "\(name(key).prefix(1).uppercased() + name(key).dropFirst()) \(plain(value))"
                default: nil
                }
            }
            return parts.isEmpty ? "\(fields.count) details" : parts.prefix(4).joined(separator: ", ")
        }
    }

    // MARK: Workouts

    /// A path into a workout, `exercises[ID].sets[ID].efforts` and the like,
    /// as the exercise and set it names: "Barbell Bench Press: 100 kg × 5".
    private func workout(_ path: String, in session: [String: JSONValue]) -> String {
        let steps = path.split(separator: ".").map(String.init)
        func item(_ step: String, in list: JSONValue?) -> [String: JSONValue]? {
            guard let open = step.firstIndex(of: "["), case .array(let items)? = list else { return nil }
            let id = String(step[step.index(after: open)..<step.index(before: step.endIndex)])
            return items.lazy.compactMap(\.objectValue).first { $0["id"]?.stringValue == id }
        }
        func items(_ list: JSONValue?) -> [[String: JSONValue]] {
            if case .array(let items)? = list { items.compactMap(\.objectValue) } else { [] }
        }
        if steps[0] == "exercises[]" { return items(session["exercises"]).map(exerciseName).joined(separator: ", ") }
        guard let exercise = item(steps[0], in: session["exercises"]) else { return "Removed" }
        let name = exerciseName(exercise)
        guard steps.count > 1 else {
            let count = items(exercise["sets"]).count
            return "\(name): \(count == 1 ? "1 set" : "\(count) sets")"
        }
        if steps[1] == "sets[]" { return "\(name): " + items(exercise["sets"]).map(set).joined(separator: ", ") }
        guard steps[1].hasPrefix("sets[") else { return "\(name): \(plain(exercise[steps[1]]))" }
        guard let performed = item(steps[1], in: exercise["sets"]) else { return "\(name): set removed" }
        return "\(name): \(set(performed))"
    }

    private func exerciseName(_ exercise: [String: JSONValue]) -> String {
        guard let id = exercise["exerciseID"]?.stringValue else { return "An exercise" }
        if let known = ExerciseLibrary.bundled.exercise(ExerciseID(id)) { return known.name }
        let words = id.replacingOccurrences(of: "custom-", with: "").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// "100 kg × 5", each effort of a drop set in turn, then RIR and kind.
    private func set(_ set: [String: JSONValue]) -> String {
        let all = set["efforts"].flatMap { try? $0.decode([Effort].self) } ?? []
        let efforts: [String] = all.compactMap { effort in
            var parts: [String] = []
            if let load = effort.load { parts.append(mass(load)) }
            if let reps = effort.reps { parts.append(parts.isEmpty ? (reps == 1 ? "1 rep" : "\(reps) reps") : "\(reps)") }
            if let duration = effort.duration { parts.append("\(number(duration)) s") }
            if let distance = effort.distance { parts.append("\(number(distance)) m") }
            return parts.isEmpty ? nil : parts.joined(separator: " × ")
        }
        var text = efforts.isEmpty ? "Empty set" : efforts.joined(separator: ", ")
        if case .number(let rir)? = set["rir"] { text += ", RIR \(number(rir))" }
        if let kind = set["kind"]?.stringValue, kind != SetKind.standard.rawValue {
            text += ", " + (SetKind(rawValue: kind) == .warmUp ? "warm-up" : kind)
        }
        if set["completedAt"] == nil || set["completedAt"] == .null { text += ", not done" }
        return text
    }

    private func mass(_ mass: Mass) -> String {
        "\(mass.converted(to: unit).value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) \(unit.rawValue)"
    }

    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1)).locale(locale)) }

    private func date(_ text: String) -> Date? { ISOMilliseconds.parse(text).map(Date.milliseconds) }

    func time(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    private func dayOf(_ date: Date) -> String { day(LocalDate(date, in: timeZone)) }

    private func day(_ date: LocalDate) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let at = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day)) ?? Date()
        var style = Date.FormatStyle(locale: locale).weekday(.abbreviated).day().month(.abbreviated)
        style.timeZone = calendar.timeZone
        return at.formatted(style)
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var numberValue: Double? { if case .number(let value) = self { value } else { nil } }
}
