import ExerlyCore
import SwiftUI

/// What one tap on Today's water row adds, in the person's units.
enum WaterServing: String, CaseIterable, Identifiable {
    case glass, bottle

    var id: String { rawValue }
    var title: String { self == .glass ? "Glass" : "Bottle" }

    func milliliters(imperial: Bool) -> Int {
        switch self {
        case .glass: imperial ? USUnits.wholeMilliliters(fluidOunces: 8) : 250
        case .bottle: imperial ? USUnits.wholeMilliliters(fluidOunces: 16.9) : 500
        }
    }
}

/// Water on Today: the day's drinks against the daily goal, a glass or a
/// bottle in one tap, and any other amount, added or removed, from the
/// sheet. Water in the day's food shows beside it and is never added to it.
struct TodayWaterCard: View {
    let date: LocalDate
    let store: NutritionStore
    let imperial: Bool
    /// Millilitres a day, from Your details.
    let goal: Int?
    /// Today's confirmation of a change, with Undo. It sits on the header,
    /// growing upward when it's taller, so the chips stay uncovered.
    var confirmation: AnyView?
    /// A change queued, in millilitres, for Today's toast and Undo.
    let changed: (Int) -> Void
    let failed: (String) -> Void
    @EnvironmentObject private var sync: SyncEngine
    @State private var water: WaterDayDTO?
    @State private var editing = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var current: WaterDayDTO { water ?? WaterDayDTO(entry_date: date.description, ml: 0, revision: 0) }

    var body: some View {
        let day = store.water(on: date, drinks: Double(current.ml), goal: goal.map(Double.init))
        ExCard {
            Button { editing = true } label: {
                header(day)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Water")
                    .accessibilityValue(Self.spoken(day, imperial: imperial))
            }
            .buttonStyle(TodayPressStyle())
            .accessibilityHint("Opens water, to add another amount or remove some")
            .accessibilityIdentifier("today.water")
            .frame(maxWidth: .infinity, alignment: .leading)
            .anchorPreference(key: HeaderBounds.self, value: .bounds) { $0 }
            if let goal = day.goal { ExProgressBar(value: day.drinks, total: goal, color: .exSecondary) }
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: ExSpacing.small))
                : AnyLayout(HStackLayout(spacing: ExSpacing.small))
            layout {
                ForEach(WaterServing.allCases) { serving in
                    let ml = serving.milliliters(imperial: imperial)
                    chip("+ \(serving.title)", detail: WaterDisplay.amount(ml, imperial: imperial)) { add(ml) }
                        .accessibilityLabel("Add a \(serving.title.lowercased()) of water, \(WaterDisplay.amount(ml, imperial: imperial))")
                        .accessibilityIdentifier("today.water.\(serving.rawValue)")
                }
                chip("Other", detail: "Add or remove") { editing = true }
                    .accessibilityLabel("Add or remove another amount of water")
                    .accessibilityIdentifier("today.water.other")
            }
            if day.food >= 1 {
                Text("Plus \(Self.amount(day.food, imperial: imperial)) in logged food and drinks, not counted toward your goal")
                    .font(.exSmall).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("today.water.food")
            }
            if current.sync_state == "pending", sync.isOffline {
                Label("Saved on this iPhone. It syncs when you're online.", systemImage: "icloud.and.arrow.up")
                    .font(.exSmall).foregroundStyle(Color.exTextMuted)
            }
        }
        // Outside the card, which clips: the confirmation's bottom meets the
        // header's, and a taller one grows up over the card above.
        .overlayPreferenceValue(HeaderBounds.self) { header in
            if let header, let confirmation {
                GeometryReader { proxy in
                    let frame = proxy[header]
                    confirmation.fixedSize(horizontal: false, vertical: true)
                        .frame(width: frame.width, height: frame.maxY, alignment: .bottom)
                        .offset(x: frame.minX)
                }
            }
        }
        .task(id: "\(date)-\(sync.changeToken)") { await load() }
        .sheet(isPresented: $editing) {
            TodayWaterSheet(date: date, water: current, store: store, imperial: imperial, goal: goal) { change in
                apply(change)
            }
        }
    }

    private struct HeaderBounds: PreferenceKey {
        static var defaultValue: Anchor<CGRect>?
        static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
    }

    private func header(_ day: WaterDay) -> some View {
        let figure = Text(Self.amount(day.drinks, imperial: imperial, unit: false)).font(.exStatSmall).foregroundStyle(Color.exTextPrimary)
        let rest = Text(day.goal.map { " / \(Self.amount($0, imperial: imperial))" } ?? " \(WaterDisplay.unit(imperial: imperial))")
            .font(.exCaption).foregroundStyle(Color.exTextSecondary)
        return HStack(spacing: ExSpacing.item) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: "drop.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.exSecondary)
                    .frame(width: 36, height: 36).background(Color.exSecondary.opacity(0.14), in: Circle()).accessibilityHidden(true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Water").font(.exH3).foregroundStyle(Color.exTextPrimary)
                    Spacer(minLength: ExSpacing.small)
                    Text("\(figure)\(rest)").monospacedDigit().lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Water").font(.exH3).foregroundStyle(Color.exTextPrimary)
                    Text("\(figure)\(rest)").monospacedDigit()
                }
            }
            Image(systemName: "chevron.right").font(.exCaption.weight(.semibold)).foregroundStyle(Color.exTextMuted).accessibilityHidden(true)
        }
        .frame(minHeight: 44).contentShape(Rectangle())
    }

    private func chip(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title).font(.exLabel.weight(.semibold)).foregroundStyle(Color.exPrimaryText)
                Text(detail).font(.exSmall).foregroundStyle(Color.exTextSecondary).monospacedDigit()
            }
            .lineLimit(typeSize.isAccessibilitySize ? 2 : 1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 48).padding(.horizontal, 4)
            .background(Color.exPrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(TodayPressStyle())
    }

    private func load() async {
        guard let day = CalendarDay(rawValue: date.description) else { return }
        if let cached = try? await sync.diary(for: day, cachedOnly: true).water, cached.entry_date == date.description { water = cached }
        if let fresh = try? await sync.diary(for: day).water, fresh.entry_date == date.description { water = fresh }
    }

    private func add(_ milliliters: Int) {
        do {
            apply(try sync.addWater(current, milliliters: milliliters))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch { failed(error.localizedDescription) }
    }

    /// Shows a change at once; the next load confirms it.
    private func apply(_ change: Int) {
        withAnimation(.snappy) {
            water = WaterDayDTO(entry_date: date.description, ml: max(0, current.ml + change), revision: current.revision, sync_state: "pending")
        }
        changed(change)
    }

    /// "1,250 ml", or "42.3 fl oz"; the number alone without `unit`.
    static func amount(_ milliliters: Double, imperial: Bool, unit: Bool = true) -> String {
        let value = imperial ? USUnits.fluidOunces(milliliters: milliliters) : milliliters
        let number = value.formatted(.number.precision(.fractionLength(0...(imperial ? 1 : 0))))
        return unit ? "\(number) \(WaterDisplay.unit(imperial: imperial))" : number
    }

    static func spoken(_ day: WaterDay, imperial: Bool) -> String {
        var parts = ["\(amount(day.drinks, imperial: imperial)) logged"]
        if let goal = day.goal, let remaining = day.remaining {
            parts.append(remaining > 0 ? "\(amount(remaining, imperial: imperial)) to go of \(amount(goal, imperial: imperial))"
                : "goal of \(amount(goal, imperial: imperial)) reached")
        }
        if day.food >= 1 { parts.append("plus \(amount(day.food, imperial: imperial)) in food, not counted toward the goal") }
        return parts.joined(separator: ", ")
    }
}

/// Another amount of water, added or removed, the daily goal, and the day's
/// totals: water logged, water in food and other drinks, and both together.
struct TodayWaterSheet: View {
    let date: LocalDate
    let water: WaterDayDTO
    let store: NutritionStore
    let imperial: Bool
    let goal: Int?
    let changed: (Int) -> Void
    @EnvironmentObject private var sync: SyncEngine
    @EnvironmentObject private var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var removing = false
    @State private var amount: String
    @State private var error: String?
    /// The goal saves as it changes, so leaving is Done rather than Cancel.
    @State private var goalChanged = false

    init(date: LocalDate, water: WaterDayDTO, store: NutritionStore, imperial: Bool, goal: Int?, changed: @escaping (Int) -> Void) {
        self.date = date
        self.water = water
        self.store = store
        self.imperial = imperial
        self.goal = goal
        self.changed = changed
        _amount = State(initialValue: imperial ? "8" : "250")
    }

    var body: some View {
        let day = store.water(on: date, drinks: Double(water.ml), goal: goal.map(Double.init))
        let unit = WaterDisplay.unit(imperial: imperial)
        NavigationStack {
            ExScreen {
                ExCard(accent: true) {
                    ExSegmentedControl(values: [false, true], selection: $removing) { $0 ? "Remove" : "Add" }
                        .accessibilityIdentifier("water.mode")
                    ExQuantityControl(title: "Amount (\(unit))", text: $amount, step: imperial ? 1 : 50,
                                      presets: imperial ? [8, 16.9, 24] : [250, 500, 750], unit: unit,
                                      identifier: "water.amount", integer: !imperial)
                        .onChange(of: amount) { _, _ in error = nil }
                }
                if let error { Text(error).font(.exCaption).foregroundStyle(Color.exError).accessibilityIdentifier("water.error") }
                if let accountID = auth.currentUser?.id {
                    TodayWaterGoal(goal: goal, imperial: imperial, changed: $goalChanged, accountID: accountID, auth: auth)
                        .id("\(auth.sessionID):\(accountID)")
                }
                ExCard {
                    ExEyebrow("Totals", color: .exPrimaryText)
                    total("Water you logged", TodayWaterCard.amount(day.drinks, imperial: imperial), id: "drinks")
                    total("In logged food and drinks", TodayWaterCard.amount(day.food, imperial: imperial), id: "food",
                          detail: day.entries == 0 ? "Nothing logged yet"
                            : "Reported by \(day.reporting) of \(day.entries) \(day.entries == 1 ? "entry" : "entries")")
                    TargetsDivider()
                    total("Total", TodayWaterCard.amount(day.total, imperial: imperial), id: "total", strong: true)
                    Text("Few foods report their water, so your goal counts the water you log here. Water in food is added to the total only.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle("Water").navigationSubtitle(NutritionFormat.day(date, timeZone: .gmt))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(goalChanged ? "Done" : "Cancel") { dismiss() }.accessibilityIdentifier("water.close")
                }
                // "Log", not a second "Add" beside the Add and Remove choice.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log") { save() }.fontWeight(.semibold)
                        .accessibilityLabel(removing ? "Log the amount removed" : "Log the amount added")
                        .accessibilityIdentifier("water.save")
                }
            }
        }
        // Whole, so the goal is in view without expanding the sheet.
        .presentationDetents([.large])
    }

    private func total(_ title: String, _ value: String, id: String, detail: String? = nil, strong: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(strong ? .exBodyMedium : .exBody).foregroundStyle(Color.exTextPrimary)
                if let detail { Text(detail).font(.exSmall).foregroundStyle(Color.exTextMuted) }
            }
            Spacer(minLength: ExSpacing.small)
            Text(value).font(strong ? .exStatSmall : .exBody).monospacedDigit().foregroundStyle(Color.exTextPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("water.total.\(id)")
    }

    private func save() {
        guard let milliliters = WaterDisplay.milliliters(amount, imperial: imperial) else {
            error = imperial ? "Enter an amount from 0.1 to 169 fl oz." : "Enter a whole number from 1 to 5,000 ml."
            return
        }
        do {
            changed(try sync.addWater(water, milliliters: removing ? -milliliters : milliliters))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// The daily water goal, set in the water sheet and saved as it changes: the
/// account's preference, which Your details shows too. Any amount from 250 ml
/// (about 8.5 fl oz) to 10 l; − and + move by a glass.
private struct TodayWaterGoal: View {
    let imperial: Bool
    @Binding var changed: Bool
    @ObservedObject private var quick: QuickPreferences
    @State private var text: String
    @State private var invalid = false

    init(goal: Int?, imperial: Bool, changed: Binding<Bool>, accountID: String, auth: AuthViewModel) {
        self.imperial = imperial
        _changed = changed
        quick = .signedIn(accountID: accountID, auth: auth)
        _text = State(initialValue: goal.map { Self.text($0, imperial: imperial) } ?? "")
    }

    private var unit: String { WaterDisplay.unit(imperial: imperial) }
    private var start: String { imperial ? "64" : "2000" }

    var body: some View {
        ExCard {
            ExQuantityControl(title: "Daily goal (\(unit))", text: $text, step: imperial ? 8 : 250,
                              presets: imperial ? [64, 80, 100] : [2000, 2500, 3000], unit: unit, identifier: "water.goal",
                              integer: !imperial, placeholder: start)
            Group {
                if invalid {
                    Text(imperial ? "Enter a goal from 9 to 338 fl oz." : "Enter a goal from 250 to 10,000 ml.").foregroundStyle(Color.exError)
                } else if let error = quick.error {
                    Text(error).foregroundStyle(Color.exError)
                } else if quick.isWaitingForConnection && quick.isUnsent("waterGoalMl") {
                    Text(QuickPreferences.waitingNote).foregroundStyle(Color.exTextSecondary)
                } else if text.isEmpty {
                    Text("No daily goal. Type one, or tap + to start from \(start) \(unit).").foregroundStyle(Color.exTextSecondary)
                } else {
                    Text("Saved as you change it. Your details shows it too.").foregroundStyle(Color.exTextSecondary)
                }
            }
            .font(.exCaption).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("water.goal.note")
            if !text.isEmpty {
                Button("No goal") { text = "" }
                    .font(.exLabel).foregroundStyle(Color.exPrimaryText).frame(minHeight: 44)
                    .accessibilityIdentifier("water.goal.clear")
            }
        }
        .onChange(of: text) { _, text in schedule(text) }
    }

    /// Kept on this iPhone at each valid change; while one is sending, only
    /// the newest waits behind it.
    private func schedule(_ text: String) {
        let typed = text.trimmingCharacters(in: .whitespaces)
        let milliliters = typed.isEmpty ? nil : Self.milliliters(typed, imperial: imperial)
        invalid = !typed.isEmpty && milliliters == nil
        guard !invalid else { return }
        changed = true
        quick.set("waterGoalMl", milliliters.map { .number(Double($0)) } ?? .null)
    }

    static func text(_ milliliters: Int, imperial: Bool) -> String {
        let value = imperial ? USUnits.fluidOunces(milliliters: Double(milliliters)) : Double(milliliters)
        return value.formatted(.number.grouping(.never).precision(.fractionLength(0...1)))
    }

    /// A goal the account accepts, 250 to 10,000 ml, in whole millilitres.
    static func milliliters(_ text: String, imperial: Bool) -> Int? {
        guard let value = TrainingInput.number(text), value > 0 else { return nil }
        let milliliters = imperial ? USUnits.wholeMilliliters(fluidOunces: value) : Int(value.rounded())
        return (250...10_000).contains(milliliters) ? milliliters : nil
    }
}
