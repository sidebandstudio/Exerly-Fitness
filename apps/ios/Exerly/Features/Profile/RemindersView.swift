import ExerlyCore
import SwiftUI

/// Reminders: a switch for each kind, with its times. Each change is saved
/// to the account and scheduled on this iPhone as it's made; turning one on
/// asks for notification permission the first time. Below, what iOS holds,
/// in words.
struct RemindersView: View {
    @EnvironmentObject private var authVM: AuthViewModel

    var body: some View {
        if let accountID = authVM.currentUser?.id {
            RemindersEditor(accountID: accountID, auth: authVM).id("\(authVM.sessionID):\(accountID)")
        }
    }
}

/// The reminder kinds, in the order of a day.
enum ReminderKind: String, CaseIterable {
    case weighIn, meals, workouts, sleep

    var switchKey: String { "reminders.\(rawValue)" }
    /// The saved preferences call the workout time "workout".
    var timeKey: String { "reminderTimes.\(self == .workouts ? "workout" : rawValue)" }

    var title: String {
        switch self {
        case .weighIn: "Weigh-in"
        case .meals: "Meals"
        case .workouts: "Workouts"
        case .sleep: "Sleep"
        }
    }

    var detail: String {
        switch self {
        case .weighIn: "Type today's weight right from the reminder"
        case .meals: "Log your usual or repeat yesterday's from the reminder"
        case .workouts: "On your workout days, ready to start"
        case .sleep: "Time to start winding down"
        }
    }

    /// The time a reminder starts at when it's turned on without one.
    var defaultTime: String {
        switch self {
        case .weighIn: "07:00"
        case .meals: "08:00"
        case .workouts: "17:30"
        case .sleep: "22:00"
        }
    }
}

/// Reminder times are saved as "HH:mm" on the account's clock; pickers show
/// them as a time of day in the person's locale.
enum ReminderClock {
    static func parts(_ text: String) -> (hour: Int, minute: Int)? {
        guard text.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        return (parts[0], parts[1])
    }

    static func text(hour: Int, minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }

    /// The picker's value: the time on a fixed day, so no daylight saving change moves it.
    static func date(_ text: String, calendar: Calendar = .current) -> Date? {
        parts(text).flatMap { calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: $0.hour, minute: $0.minute)) }
    }

    static func text(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return text(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    /// "7:30 AM" in the US, "07:30" where clocks run to 24 hours.
    static func display(hour: Int, minute: Int, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute)) ?? .now
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: .gmt))
    }
}

/// What's scheduled, in plain words: "Weigh-in · every day at 7:30 AM".
enum ReminderWords {
    static func lines(_ reminders: [ReminderSpec], locale: Locale = .current) -> [String] {
        func minute(_ reminder: ReminderSpec) -> Int { (reminder.components.hour ?? 0) * 60 + (reminder.components.minute ?? 0) }
        func time(_ reminder: ReminderSpec) -> String {
            ReminderClock.display(hour: reminder.components.hour ?? 0, minute: reminder.components.minute ?? 0, locale: locale)
        }
        var lines: [(minute: Int, text: String)] = []
        let workouts = reminders.filter { $0.components.weekday != nil }
        for reminder in reminders where reminder.components.weekday == nil {
            let title = reminder.title.replacingOccurrences(of: " reminder", with: "")
            lines.append((minute(reminder), "\(title) · every day at \(time(reminder))"))
        }
        // Workout reminders share one time, on the workout days.
        for (_, group) in Dictionary(grouping: workouts, by: minute) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = locale
            let first = calendar.firstWeekday
            let days = group.compactMap(\.components.weekday).sorted { ($0 - first + 7) % 7 < ($1 - first + 7) % 7 }
            let when = days.count == 7 ? "every day"
                : days.map { calendar.shortWeekdaySymbols[$0 - 1] }.formatted(.list(type: .and).locale(locale))
            lines.append((minute(group[0]), "Workout · \(when) at \(time(group[0]))"))
        }
        return lines.sorted { $0.minute < $1.minute }.map(\.text)
    }
}

private struct RemindersEditor: View {
    @ObservedObject private var notifications = NotificationService.shared
    @StateObject private var store: PreferencesStore
    @EnvironmentObject private var account: AppAccountWorkspace
    @Environment(\.openURL) private var openURL
    /// Changes made while a save is in flight; they're sent when it ends.
    @State private var unsaved: [String: String] = [:]
    @State private var saving: Task<Void, Never>?

    init(accountID: String, auth: AuthViewModel) {
        let sessionID = auth.sessionID
        _store = StateObject(wrappedValue: PreferencesStore(
            accountID: accountID,
            ownerIsActive: { [weak auth] in auth?.currentUser?.id == accountID && auth?.sessionID == sessionID },
            onAccepted: { [weak auth] snapshot in
                auth?.acceptPreferences(snapshot.user, accountID: accountID, sessionID: sessionID)
                NotificationService.shared.accept(snapshot)
            }
        ))
    }

    var body: some View {
        ExForm {
            if let error = store.error ?? notifications.error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Color.exError) }
                    .accessibilityIdentifier("reminders.error")
            }
            if store.draft == nil {
                Section { HStack { ProgressView(); Text("Opening your reminders…") } }
            } else {
                ForEach(ReminderKind.allCases, id: \.self) { section($0) }
                scheduledSection
            }
            deviceSection
        }
        .navigationTitle("Reminders").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.isSaving || saving != nil {
                ToolbarItem(placement: .primaryAction) { ProgressView().accessibilityLabel("Saving") }
            }
        }
        .task { store.activate(); await store.load() }
        .onDisappear {
            // A change made just before leaving still reaches the account.
            let store = store
            if saving == nil, store.hasEdits { Task { await store.save(); store.stop() } } else if saving == nil { store.stop() }
        }
    }

    // MARK: Values

    private func value(_ key: String) -> String { unsaved[key] ?? store.draft?.fields[key] ?? "" }
    private func isOn(_ kind: ReminderKind) -> Bool { value(kind.switchKey) == "true" }
    private var timeZone: TimeZone { TimeZone(identifier: value("timezone")) ?? .current }
    private var mealTimes: [String] { value(ReminderKind.meals.timeKey).components(separatedBy: "\n").filter { !$0.isEmpty } }
    private var workoutDays: Set<String> { Set(value("workoutDays").components(separatedBy: "\n").filter { !$0.isEmpty }) }

    /// Saves changes as they're made: one save at a time, and what changed
    /// during it goes in the next.
    private func set(_ changes: [String: String]) {
        unsaved.merge(changes) { $1 }
        guard saving == nil else { return }
        saving = Task {
            await saveChanges()
            saving = nil
        }
    }

    private func saveChanges() async {
        while !unsaved.isEmpty {
            if store.draft?.pending != nil { await store.save() }
            let batch = unsaved
            for (key, value) in batch { store.edit(key, value: value) }
            let applied = batch.filter { store.draft?.fields[$0.key] == $0.value }
            for (key, value) in applied where unsaved[key] == value { unsaved[key] = nil }
            // A draft that can't take edits says why in its error.
            guard !applied.isEmpty else { return }
            await store.save()
            // Another device saved first: this person's change still wins for the fields it touched.
            if store.conflict != nil { await store.resolve(useServer: false) }
            guard store.error == nil else { return }
        }
    }

    private func turn(_ kind: ReminderKind, on: Bool) {
        var changes = [kind.switchKey: String(on)]
        if on {
            if kind == .meals, mealTimes.isEmpty {
                changes[kind.timeKey] = usualMealTimes.joined(separator: "\n")
            } else if kind != .meals, ReminderClock.parts(value(kind.timeKey)) == nil {
                changes[kind.timeKey] = kind.defaultTime
            }
            // No separate step: this iPhone delivers them, asking iOS the first time.
            if !notifications.isDeviceEnabled || notifications.authorization == .notDetermined {
                Task { await notifications.setDeviceEnabled(true) }
            }
        }
        set(changes)
    }

    /// Breakfast, lunch and dinner when the person usually eats them, to the
    /// nearest 5 minutes, or at typical times before there's a habit.
    private var usualMealTimes: [String] {
        guard let store = account.training?.nutrition else {
            return ["Breakfast", "Lunch", "Dinner"].map {
                let time = NutritionStore.typicalTime(of: $0)
                return ReminderClock.text(hour: time.hour, minute: time.minute)
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = LocalDate(Date(), in: timeZone)
        return ["Breakfast", "Lunch", "Dinner"].map { meal in
            let parts = calendar.dateComponents([.hour, .minute], from: store.usualTime(of: meal, on: today, timeZone: timeZone))
            let minutes = min(23 * 60 + 55, Int((Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / 5).rounded()) * 5)
            return ReminderClock.text(hour: minutes / 60, minute: minutes % 60)
        }
    }

    // MARK: Sections

    private func section(_ kind: ReminderKind) -> some View {
        Section {
            Toggle(isOn: Binding(get: { isOn(kind) }, set: { turn(kind, on: $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                    Text(kind.detail).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
            }
            .toggleStyle(ExRowToggleStyle())
            .disabled(store.isLocked && saving == nil)
            .accessibilityIdentifier("reminders.\(kind.rawValue)")
            if isOn(kind) {
                switch kind {
                case .meals: mealRows
                case .workouts:
                    timeRow("Time", key: kind.timeKey, identifier: "reminders.workouts.time")
                    dayPicker
                default:
                    timeRow("Time", key: kind.timeKey, identifier: "reminders.\(kind.rawValue).time")
                }
            }
        }
    }

    private func timeRow(_ title: String, key: String, identifier: String) -> some View {
        DatePicker(title, selection: Binding(
            get: { ReminderClock.date(value(key)) ?? .now },
            set: { set([key: ReminderClock.text($0)]) }
        ), displayedComponents: .hourAndMinute)
        .font(.exBody)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var mealRows: some View {
        let times = mealTimes
        ForEach(Array(times.enumerated()), id: \.offset) { index, time in
            HStack(spacing: ExSpacing.small) {
                DatePicker(mealName(time), selection: Binding(
                    get: { ReminderClock.date(time) ?? .now },
                    set: { date in
                        var next = times
                        next[index] = ReminderClock.text(date)
                        set([ReminderKind.meals.timeKey: next.joined(separator: "\n")])
                    }
                ), displayedComponents: .hourAndMinute)
                .font(.exBody)
                .accessibilityIdentifier("reminders.meals.time.\(index)")
                Button("Remove \(mealName(time)) reminder", systemImage: "minus.circle.fill") {
                    var next = times
                    next.remove(at: index)
                    var changes = [ReminderKind.meals.timeKey: next.joined(separator: "\n")]
                    // Without a time, meal reminders are off.
                    if next.isEmpty { changes[ReminderKind.meals.switchKey] = "false" }
                    set(changes)
                }
                .labelStyle(.iconOnly).font(.title3).foregroundStyle(Color.exError)
                .buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44)
            }
        }
        if times.count < 10 {
            Button("Add a meal time", systemImage: "plus.circle.fill") {
                set([ReminderKind.meals.timeKey: (times + [nextMealTime(after: times)]).joined(separator: "\n")])
            }
            .font(.exBody).foregroundStyle(Color.exPrimaryText)
            .accessibilityIdentifier("reminders.meals.add")
        }
    }

    /// The meal a time names, as the reminder will.
    private func mealName(_ time: String) -> String {
        guard let parts = ReminderClock.parts(time) else { return "Meal" }
        var components = DateComponents(hour: parts.hour, minute: parts.minute)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        components.calendar = calendar
        components.timeZone = timeZone
        return ReminderPlan.meal(at: components, store: account.training?.nutrition)
    }

    /// Three hours after the latest time, or a snack mid-afternoon to start.
    private func nextMealTime(after times: [String]) -> String {
        let minutes = times.compactMap(ReminderClock.parts).map { $0.hour * 60 + $0.minute }
        var next = (minutes.max() ?? 12 * 60) + 3 * 60
        if next > 22 * 60 { next = 15 * 60 }
        while minutes.contains(next) { next = (next + 30) % (24 * 60) }
        return ReminderClock.text(hour: next / 60, minute: next % 60)
    }

    private var dayPicker: some View {
        let first = Calendar.current.firstWeekday
        let days = Weekday.allCases.sorted { ($0.rawValue - first + 7) % 7 < ($1.rawValue - first + 7) % 7 }
        let chosen = workoutDays
        return VStack(alignment: .leading, spacing: ExSpacing.small) {
            HStack(spacing: 6) {
                ForEach(days, id: \.self) { day in
                    let name = String(describing: day), on = chosen.contains(name)
                    Button {
                        var next = chosen
                        if on { next.remove(name) } else { next.insert(name) }
                        set(["workoutDays": PreferenceFields.days.filter(next.contains).joined(separator: "\n")])
                    } label: {
                        Text(TargetsFormat.weekday(day, style: .narrow)).font(.exLabel.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundStyle(on ? Color.white : Color.exTextSecondary)
                            .background(on ? Color.exActionFill : Color.exSurface2, in: Circle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(TargetsFormat.weekday(day))
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("reminders.day.\(name)")
                }
            }
            Text(chosen.isEmpty ? "Choose the days you train." : "The days you train, also used by your plan.")
                .font(.exCaption).foregroundStyle(chosen.isEmpty ? Color.exError : Color.exTextSecondary)
        }
        .padding(.vertical, 4)
    }

    private var scheduledSection: some View {
        Section {
            let lines = ReminderWords.lines(notifications.scheduled)
            if lines.isEmpty {
                Text(ReminderKind.allCases.contains(where: isOn) ? "Nothing is scheduled on this iPhone yet." : "No reminders are on.")
                    .font(.exBody).foregroundStyle(Color.exTextSecondary)
                    .accessibilityIdentifier("reminders.scheduled.none")
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Label(line, systemImage: "bell").font(.exBody).foregroundStyle(Color.exTextPrimary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(line)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityIdentifier("reminders.scheduled.\(index)")
            }
            ForEach(notifications.missing, id: \.self) {
                Text($0).font(.exCaption).foregroundStyle(Color.exTextSecondary)
            }
        } header: {
            Text("Scheduled")
        } footer: {
            if timeZone.identifier != TimeZone.current.identifier {
                Text("Times follow your account's time zone, \(timeZone.identifier).")
            }
        }
    }

    private var deviceSection: some View {
        Section {
            Toggle(isOn: Binding(get: { notifications.isDeviceEnabled },
                                 set: { on in Task { await notifications.setDeviceEnabled(on) } })) {
                Text("Remind me on this iPhone").font(.exBody).foregroundStyle(Color.exTextPrimary)
            }
            .toggleStyle(ExRowToggleStyle())
            .disabled(notifications.isUpdating)
            .accessibilityIdentifier("reminders.device")
            if notifications.isDeviceEnabled, notifications.authorization == .denied {
                Text("Notifications are off for Exerly in Settings.").font(.exBody)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                .accessibilityIdentifier("reminders.openSettings")
            }
        } footer: {
            Text("Your choices are saved to your account. Each iPhone reminds you only while this is on.")
        }
    }
}
