import ExerlyCore
import SwiftUI

/// A part of Your details another screen can open it at.
enum PreferencesSection: String {
    case foodLog
}

struct EditProfileView: View {
    var section: PreferencesSection?
    @EnvironmentObject private var authVM: AuthViewModel
    var body: some View {
        NavigationStack {
            if let accountID = authVM.currentUser?.id {
                PreferencesEditor(accountID: accountID, auth: authVM, section: section)
                    .id("\(authVM.sessionID):\(accountID)")
            }
        }
    }
}

private struct PreferencesEditor: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: PreferencesStore
    @FocusState private var focusedField: String?
    @State private var showKeepConfirmation = false
    @State private var showReplaceConfirmation = false
    @State private var foodExpanded = false
    @State private var trainingExpanded = false
    @State private var editTask: Task<Void, Never>?
    @State private var feetText = ""
    @State private var inchesText = ""
    let section: PreferencesSection?

    init(accountID: String, auth: AuthViewModel, section: PreferencesSection? = nil) {
        self.section = section
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

    private var fields: [String: String] { store.draft?.fields ?? [:] }
    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { fields[key] ?? "" }, set: { store.edit(key, value: $0) })
    }
    private func enabled(_ key: String) -> Binding<Bool> {
        Binding(get: { fields[key] == "true" }, set: { store.edit(key, value: String($0)) })
    }
    private func perform(_ action: @escaping @MainActor () async -> Void) {
        editTask?.cancel()
        editTask = Task { await action() }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ExForm {
                Section {
                    ExCard(accent: true) {
                        statusSection.id("preferences-status")
                    }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                }
                if store.conflict != nil { conflictSection }
                if store.draft != nil {
                    basicSection.disabled(store.isLocked)
                    foodLogSection.disabled(store.isLocked)
                    foodSection.disabled(store.isLocked)
                    trainingSection.disabled(store.isLocked)
                    sleepSection.disabled(store.isLocked)
                }
            }
            .exListStyle()
            .onChange(of: store.error) { _, error in
                if error != nil { focusedField = nil; proxy.scrollTo("preferences-status", anchor: .top) }
            }
            .onChange(of: store.conflict?.revision) { _, revision in
                if revision != nil { focusedField = nil; proxy.scrollTo("preferences-status", anchor: .top) }
            }
            .onChange(of: store.draft != nil, initial: true) { _, ready in
                if ready, let section { proxy.scrollTo(section.rawValue, anchor: .top) }
            }
        }
        .tint(.exPrimaryText)
        .navigationTitle("Your details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // One action: Done saves any edits, then closes once the account has them.
            ToolbarItem(placement: .confirmationAction) {
                Button(store.draft?.pending == nil ? "Done" : "Retry save") {
                    focusedField = nil
                    perform { await saveAndClose() }
                }
                .fontWeight(.semibold)
                .accessibilityHint(store.hasEdits || store.draft?.pending != nil ? "Saves your changes and closes" : "Closes your details")
                .accessibilityIdentifier("preferences.save")
                .disabled(store.isSaving || store.isLoading)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Hide keyboard") { focusedField = nil }
            }
        }
        .confirmationDialog("Save these preference edits?", isPresented: $showKeepConfirmation, titleVisibility: .visible) {
            Button("Save reviewed edits") { perform { await store.resolve(useServer: false) } }
        } message: {
            Text("Only your edited fields replace the reviewed account values. Other preferences stay as they are.")
        }
        .confirmationDialog("Use the saved account preferences?", isPresented: $showReplaceConfirmation, titleVisibility: .visible) {
            Button("Use saved preferences", role: .destructive) { perform { await store.resolve(useServer: true) } }
        } message: {
            Text("This replaces the open draft with the account version shown here.")
        }
        .task { store.activate(); await store.load() }
        .onDisappear { editTask?.cancel(); store.stop() }
    }

    /// Saves edits the account can take, and closes unless the save needs
    /// attention: an error, a conflict to review, or a reply still owed. Edits
    /// that can't be sent now stay in the draft on this device.
    private func saveAndClose() async {
        let canSave = store.isReadable && store.conflict == nil && store.draft != nil
        if canSave, store.hasEdits || store.draft?.pending != nil {
            await store.save()
            guard store.error == nil, store.conflict == nil, store.draft?.pending == nil else { return }
        }
        dismiss()
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            HStack(spacing: ExSpacing.small) {
            if store.isLoading || store.isSaving {
                HStack {
                    ProgressView()
                    Text(store.isSaving ? "Saving preferences…" : "Refreshing preferences…")
                }
            } else if let message = store.message {
                let settled = message == "Preferences are up to date." || message == "Preferences saved."
                Image(systemName: settled ? "checkmark.icloud" : "icloud.and.arrow.up")
                    .font(.exCaption).foregroundStyle(Color.exPrimaryText).accessibilityHidden(true)
                Text(message == "Preferences are up to date." ? "Up to date with your account" : message)
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("preferences.status")
            }
            Spacer(minLength: 0)
            Button("Refresh preferences", systemImage: "arrow.clockwise") { focusedField = nil; perform { await store.load() } }
                .labelStyle(.iconOnly).frame(width: 44, height: 44)
                .disabled(store.isLoading || store.isSaving || !store.isReadable)
            }
            if let error = store.error {
                Text(error).foregroundStyle(Color.exError).accessibilityIdentifier("preferences.error")
            }
            if store.draft?.pending != nil {
                Text("Your last save has not been confirmed. Retry it before editing these preferences.")
                    .font(.subheadline)
            }
        }
    }

    private var conflictSection: some View {
        Section("Preferences changed on another device") {
            if let draft = store.draft, let remote = store.conflict {
                let changed = (try? PreferenceFields.changes(draft)) ?? [:]
                ForEach(PreferenceFields.definitions.filter { changed[$0.key] != nil }, id: \.key) { field in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(field.label).font(.headline)
                        Text("Your edit: \(PreferenceFields.describe(changed[field.key] ?? .null))")
                        Text("Saved on account: \(PreferenceFields.describe(remote.value(field.key)))")
                    }
                    .font(.subheadline)
                }
                ForEach(["reminders", "reminderTimes"].filter { changed[$0] != nil }, id: \.self) { key in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(key == "reminders" ? "Reminder choices" : "Reminder times").font(.headline)
                        Text("Your edit: \(PreferenceFields.describe(changed[key] ?? .null))")
                        Text("Saved on account: \(PreferenceFields.describe(remote.value(key)))")
                    }.font(.subheadline)
                }
            }
            Button("Save my edits") { showKeepConfirmation = true }
            Button("Use account preferences") { showReplaceConfirmation = true }
        }
        .accessibilityIdentifier("preferences.conflict")
    }

    private var basicSection: some View {
        Section("About you") {
            field("name")
            field("age", keyboard: .numberPad)
            picker("gender", choices: [("female", "Female"), ("male", "Male"), ("nonbinary", "Nonbinary"),
                                        ("other", "Other or prefer not to say")])
            picker("unitSystem", choices: [("metric", "Metric, kg and cm"), ("imperial", "U.S., lb and inches")])
            if fields["unitSystem"] == "imperial" { imperialHeight } else {
                field("height", label: "Height (cm)", keyboard: .decimalPad)
            }
            picker("activityLevel", choices: [
                ("sedentary", "Mostly seated"), ("light", "Lightly active"),
                ("moderate", "Moderately active"), ("active", "Very active"), ("very_active", "Extremely active")
            ])
            field("timezone")
            Button("Use device time zone") { store.edit("timezone", value: TimeZone.current.identifier) }
            Text("Weigh in from Today or Progress. Calorie and macro targets live in Profile, under Your plan.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
    /// How Today reads the day's food, and the water goal its water row counts toward.
    private var foodLogSection: some View {
        Section {
            Picker(PreferenceFields.label("nutritionDisplay"), selection: Binding(
                get: { fields["nutritionDisplay"] == "consumed" ? "consumed" : "remaining" },
                set: { store.edit("nutritionDisplay", value: $0) })) {
                Text("What's left").tag("remaining")
                Text("What you've eaten").tag("consumed")
            }
            .accessibilityIdentifier("preferences.nutritionDisplay")
            .frame(minHeight: 44)
            .id(PreferencesSection.foodLog.rawValue)
            Picker(PreferenceFields.label("waterGoalMl"), selection: binding("waterGoalMl")) {
                Text("No goal").tag("")
                ForEach(waterGoals, id: \.self) { ml in Text(WaterDisplay.amount(ml, imperial: imperial)).tag(String(ml)) }
                if let saved = Int(fields["waterGoalMl"] ?? ""), !waterGoals.contains(saved) {
                    Text(WaterDisplay.amount(saved, imperial: imperial)).tag(String(saved))
                }
            }
            .accessibilityIdentifier("preferences.waterGoalMl")
            .frame(minHeight: 44)
        } header: {
            Text("Food log")
        } footer: {
            Text("Today's calorie ring and macros lead with your choice. Going over always shows with a plus, as in +120 over. The water goal counts water you log on Today.")
        }
    }

    private var imperial: Bool { fields["unitSystem"] == "imperial" }

    /// Goals in steps of 250 ml, or of 8 fl oz in U.S. units.
    private var waterGoals: [Int] {
        imperial ? stride(from: 32, through: 160, by: 8).map { USUnits.wholeMilliliters(fluidOunces: Double($0)) }
            : Array(stride(from: 1000, through: 5000, by: 250))
    }

    private var foodSection: some View {
        Section {
            DisclosureGroup("Food preferences", isExpanded: $foodExpanded) {
                field("dietaryStyle", text: Binding(
                    // A saved choice from setup reads as its name, not its code.
                    get: { fields["dietaryStyle"].flatMap(DietaryStyle.init(rawValue:))?.label ?? fields["dietaryStyle"] ?? "" },
                    set: { store.edit("dietaryStyle", value: $0) }))
                field("allergies", multiline: true)
                Text("Enter one allergy per line. Check food labels when choosing products.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
    private var trainingSection: some View {
        Section {
            DisclosureGroup("Training preferences", isExpanded: $trainingExpanded) {
                picker("experienceLevel", choices: [("beginner", "Beginner"), ("intermediate", "Intermediate"), ("advanced", "Advanced")])
                picker("equipmentAccess", choices: [("bodyweight", "Bodyweight"), ("home", "Home"), ("full_gym", "Gym")])
                field("equipment", multiline: true)
                Text("Enter one item per line.").font(.subheadline).foregroundStyle(.secondary)
                field("workoutDaysPerWeek", keyboard: .numberPad)
                ForEach(PreferenceFields.days, id: \.self) { day in
                    Toggle(day.capitalized, isOn: Binding(get: {
                        (fields["workoutDays"] ?? "").components(separatedBy: "\n").contains(day)
                    }, set: { selected in
                        var days = Set((fields["workoutDays"] ?? "").components(separatedBy: "\n").filter { !$0.isEmpty })
                        if selected { days.insert(day) } else { days.remove(day) }
                        store.edit("workoutDays", value: PreferenceFields.days.filter { days.contains($0) }.joined(separator: "\n"))
                    }))
                    .toggleStyle(ExRowToggleStyle())
                    .accessibilityIdentifier("preferences.day.\(day)")
                    .tint(.exPrimaryText)
                }
            }
        }
    }
    private var sleepSection: some View {
        Section("Sleep") {
            field("sleepGoalHours", keyboard: .decimalPad)
        }
    }
    /// Height in feet and inches. The draft keeps total inches, as the store
    /// expects; an untouched height is never rewritten.
    private var imperialHeight: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Height").font(.subheadline.weight(.medium))
            HStack(spacing: ExSpacing.section) {
                heightPart("Feet", unit: "ft", text: $feetText, key: "heightFeet")
                heightPart("Inches", unit: "in", text: $inchesText, key: "heightInches")
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 6)
        .onAppear(perform: showHeight)
        .onChange(of: fields["height"]) { _, _ in
            if focusedField != "heightFeet" && focusedField != "heightInches" { showHeight() }
        }
    }

    private func heightPart(_ title: String, unit: String, text: Binding<String>, key: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            TextField(title, text: text)
                .keyboardType(key == "heightFeet" ? .numberPad : .decimalPad)
                .focused($focusedField, equals: key)
                .accessibilityLabel("Height, \(title.lowercased())")
                .accessibilityIdentifier("preferences.\(key)")
                .onChange(of: text.wrappedValue) { _, _ in
                    guard focusedField == key else { return }
                    let feet = UserEnteredNumber.parse(feetText) ?? 0
                    let inches = UserEnteredNumber.parse(inchesText) ?? 0
                    store.edit("height", value: feetText.isEmpty && inchesText.isEmpty ? "" : PreferenceFields.numberText(feet * 12 + inches))
                }
                .frame(minWidth: 44, maxWidth: 72)
                .fixedSize(horizontal: true, vertical: false)
            Text(unit).foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .frame(minHeight: 44)
    }

    private func showHeight() {
        guard let total = UserEnteredNumber.parse(fields["height"] ?? ""), total > 0 else {
            feetText = ""; inchesText = ""; return
        }
        // Whole inches, as Profile shows them; only a typed change is saved.
        let height = USUnits.feetAndInches(centimeters: USUnits.centimeters(feet: 0, inches: total))
        feetText = String(height.feet)
        inchesText = height.inches.formatted(.number.grouping(.never).precision(.fractionLength(0)))
    }

    private func field(_ key: String, label: String? = nil, keyboard: UIKeyboardType = .default, multiline: Bool = false,
                       text: Binding<String>? = nil) -> some View {
        let title = label ?? PreferenceFields.label(key)
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            if multiline {
                TextField(title, text: binding(key), axis: .vertical)
                    .lineLimit(3...6)
                    .focused($focusedField, equals: key)
                    .accessibilityIdentifier("preferences.\(key)")
            } else {
                TextField(title, text: text ?? binding(key))
                    .keyboardType(keyboard)
                    .focused($focusedField, equals: key)
                    .accessibilityIdentifier("preferences.\(key)")
                    .textContentType(key == "name" ? .name : nil)
            }
        }
        .autocorrectionDisabled()
        .textInputAutocapitalization(key == "name" ? .words : .never)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
    }
    private func picker(_ key: String, choices: [(String, String)]) -> some View {
        Picker(PreferenceFields.label(key), selection: binding(key)) {
            Text("Not set").tag("")
            ForEach(choices, id: \.0) { value, label in Text(label).tag(value) }
            if let value = fields[key], !value.isEmpty, !choices.contains(where: { $0.0 == value }) {
                Text(value).tag(value)
            }
        }
        .accessibilityIdentifier("preferences.\(key)")
        .frame(minHeight: 44)
    }
}
