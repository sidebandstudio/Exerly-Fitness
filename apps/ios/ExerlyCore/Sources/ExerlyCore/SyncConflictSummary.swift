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
    public var options: [Option]
}

extension SyncConflict {
    /// Words for this conflict as seen on `viewer`, with masses in `unit`
    /// and times in `timeZone`. With `replaced`, the record was logged again
    /// from the same scan, so bringing it back changes that entry instead.
    public func summary(on viewer: SyncDevice, unit: MassUnit, timeZone: TimeZone, locale: Locale = .current,
                        replaced: Bool = false) -> SyncConflictSummary {
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
            options = choices.map { choice in
                switch choice {
                case .local: .init(choice: choice, title: "Keep \(localOwner)", done: "Kept \(localOwner)")
                case .remote: .init(choice: choice, title: "Keep the other device's", done: "Kept the other device's")
                case .both: .init(choice: choice, title: "Keep both", done: "Kept both")
                }
            }
        }
        return SyncConflictSummary(
            title: title, detail: detail, explanation: explanation,
            local: .init(device: localName, value: value(local), time: nil),
            remote: .init(device: "Another device", value: value(remote), time: remoteAt.map(words.time)),
            options: options
        )
    }
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
        default:
            // A workout's sets and exercises read by what they are.
            field.contains("sets[") ? "sets" : field.hasPrefix("exercises") ? "exercises"
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
            let converted = weight.converted(to: unit)
            return "\(converted.value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) \(unit.rawValue)"
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
        default:
            switch fields[field] {
            case .string(let text)?: return text.isEmpty ? "Empty" : text
            case .number(let value)?: return number(value)
            case .bool(let value)?: return value ? "On" : "Off"
            case nil, .null?: return "None"
            default: return "Its own \(name(field))"
            }
        }
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
