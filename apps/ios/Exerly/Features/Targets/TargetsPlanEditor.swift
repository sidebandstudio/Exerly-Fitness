import ExerlyCore
import SwiftUI

/// The plan editor: goal, rate, goal weight, coaching, macros, weekdays and
/// check-in day, with the targets they make shown live. Saving starts a new
/// version today and never rewrites past days. Adjusting a collaborative
/// check-in accepts the check-in with the changes.
struct TargetsPlanEditor: View {
    @ObservedObject var workspace: TrainingWorkspace
    let unit: MassUnit
    let timeZone: TimeZone
    let request: TargetsEditorRequest
    let onSaved: (String, UUID?) -> Void
    @State private var draft: NutritionPlanDraft
    @State private var hasGoalWeight: Bool
    @State private var goalWeightText: String
    /// Set when Add a goal weight opens an empty field, which then takes the keypad.
    @State private var addedGoalWeight = false
    @State private var manualText: ManualText
    @State private var customDays: Bool
    @State private var error: String?
    @State private var versionID = UUID()
    @State private var createdAt = Date()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    struct ManualText: Equatable {
        var energy: String
        var protein: String
        var carbohydrate: String
        var fat: String

        init(_ day: DailyTargets) {
            energy = Self.text(day.energy)
            protein = Self.text(day.protein)
            carbohydrate = Self.text(day.carbohydrate)
            fat = Self.text(day.fat)
        }

        static func text(_ value: Double) -> String { value.formatted(.number.grouping(.never).precision(.fractionLength(0))) }
    }

    init(workspace: TrainingWorkspace, unit: MassUnit, timeZone: TimeZone, request: TargetsEditorRequest,
         onSaved: @escaping (String, UUID?) -> Void) {
        self.workspace = workspace
        self.unit = unit
        self.timeZone = timeZone
        self.request = request
        self.onSaved = onSaved
        _draft = State(initialValue: request.draft)
        // From "Add a goal weight", the field is ready rather than behind a second Add (run 7 tapped it twice).
        let adding = request.addsGoalWeight && request.draft.goal.goalWeight == nil && request.draft.goal.direction != .maintain
        _hasGoalWeight = State(initialValue: request.draft.goal.goalWeight != nil || adding)
        _addedGoalWeight = State(initialValue: adding)
        _goalWeightText = State(initialValue: request.draft.goal.goalWeight.map { Self.weightText($0, unit: unit) } ?? "")
        _manualText = State(initialValue: ManualText(request.draft.manual))
        _customDays = State(initialValue: !WeekdayBudget.isEven(request.draft.weekdayWeights))
    }

    // MARK: What the draft rests on

    private var today: LocalDate { LocalDate(Date(), in: timeZone) }

    private var adjusting: (proposal: Proposal, proposed: NutritionPlan, current: NutritionPlan)? {
        if case .adjust(let proposal, let proposed, let current) = request.kind { return (proposal, proposed, current) }
        return nil
    }

    private var basis: PlanBasis? { adjusting?.proposed.basis ?? request.choice?.basis }
    private var startDate: LocalDate { adjusting?.proposed.startDate ?? today }
    /// Trend weight in kilograms, for rates in the person's unit.
    private var trend: Double? { basis?.trendWeight }

    private var preview: NutritionPlanDraft.Preview {
        draft.preview(startingOn: startDate, basis: basis, id: adjusting?.proposed.id ?? versionID, now: createdAt)
    }

    private var title: String {
        switch request.kind {
        case .setup: "Set up targets"
        case .edit, .coach: "Edit plan"
        case .adjust: "Adjust check-in"
        }
    }

    private var saveTitle: String {
        switch request.kind {
        case .setup: "Start these targets"
        case .edit, .coach: "Save new targets"
        case .adjust: "Accept adjusted targets"
        }
    }

    // MARK: Body

    var body: some View {
        let preview = preview
        NavigationStack {
            ExScreen {
                if adjusting != nil {
                    Text("Change anything before accepting. The check-in's calories come from your measured expenditure; "
                        + "diet, protein and weekdays reshape them.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                }
                goalCard
                if adjusting == nil { coachingCard }
                if draft.mode == .manual { manualCard } else { macrosCard(preview) }
                weekdaysCard(preview)
                if draft.mode != .manual && adjusting == nil { checkInCard }
                basisNote
                problems(preview)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("planEditor.screen")
            .exFooter { saveBar(preview) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("planEditor.cancel")
                }
            }
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(draft != request.draft)
        .onChange(of: goalWeightText) { _, text in
            guard hasGoalWeight else { return }
            draft.goal.goalWeight = TrainingInput.number(text).flatMap { $0 > 0 ? Mass($0, unit) : nil }
        }
        .onChange(of: manualText) { _, text in
            draft.manual = DailyTargets(energy: TrainingInput.number(text.energy) ?? 0, protein: TrainingInput.number(text.protein) ?? 0,
                                        fat: TrainingInput.number(text.fat) ?? 0,
                                        carbohydrate: TrainingInput.number(text.carbohydrate) ?? 0)
        }
    }

    // MARK: Goal

    private var goalCard: some View {
        ExCard {
            ExEyebrow("Goal", color: .exPrimaryText)
            ExSegmentedControl(values: NutritionGoal.Direction.allCases, selection: Binding(get: { draft.goal.direction }, set: { direction in
                guard direction != draft.goal.direction else { return }
                draft.goal.direction = direction
                draft.goal.weeklyRate = NutritionRate.standard(for: direction, trend: trend, unit: unit)
            })) { TargetsFormat.direction($0) }
                .accessibilityIdentifier("planEditor.direction")
            if draft.goal.direction == .maintain {
                Text("Your targets match your expenditure, so your trend weight holds steady.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            } else {
                rateTiles
                rateStepper
                Text(draft.goal.direction == .lose
                     ? "Up to 1 % of bodyweight a week. Slower losses keep more muscle and are easier to sustain."
                     : "Up to 0.5 % of bodyweight a week. Faster gains add more fat than muscle.")
                    .font(.exSmall).foregroundStyle(Color.exTextMuted).fixedSize(horizontal: false, vertical: true)
                TargetsDivider()
                goalWeightControl
            }
        }
    }

    private var rateTiles: some View {
        let presets = NutritionRate.presets(for: draft.goal.direction, trend: trend, unit: unit)
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: ExSpacing.small)) : AnyLayout(HStackLayout(spacing: ExSpacing.small))
        return layout {
            ForEach(Array(presets.enumerated()), id: \.offset) { index, share in
                let selected = abs(draft.goal.weeklyRate - share) < 1e-7
                Button {
                    draft.goal.weeklyRate = share
                } label: {
                    VStack(spacing: 2) {
                        Text(trend.map { TargetsFormat.weekly(share, trend: $0, unit: unit) } ?? TargetsFormat.percent(share))
                            .font(.exBodyMedium).monospacedDigit()
                        Text(trend == nil ? "a week" : TargetsFormat.percent(share)).font(.exSmall)
                            .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.exTextSecondary)
                    }
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(selected ? Color.white : Color.exTextPrimary)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(selected ? Color.exActionFill : Color.exSurface2,
                                in: RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(TodayPressStyle())
                .accessibilityLabel(trend.map { TargetsFormat.spokenWeekly(share, trend: $0, unit: unit) }
                    ?? "\(TargetsFormat.percent(share)) of bodyweight a week")
                .accessibilityValue(trend == nil ? "" : "\(TargetsFormat.percent(share)) of bodyweight")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("planEditor.rate.\(index)")
            }
        }
        .sensoryFeedback(.selection, trigger: draft.goal.weeklyRate)
    }

    private var rateStepper: some View {
        let rate = draft.goal.weeklyRate
        let amount = trend.map { TargetsFormat.weekly(rate, trend: $0, unit: unit) } ?? TargetsFormat.percent(rate)
        return HStack(spacing: ExSpacing.small) {
            stepButton("minus", label: "Slower") { nudgeRate(-1) }
            VStack(spacing: 1) {
                Text("\(amount) a week").font(.exStatMedium).monospacedDigit().foregroundStyle(Color.exTextPrimary)
                    .contentTransition(.numericText(value: rate)).lineLimit(1).minimumScaleFactor(0.7)
                if trend != nil {
                    Text("\(TargetsFormat.percent(rate)) of bodyweight").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rate")
            .accessibilityValue(trend.map { "\(TargetsFormat.spokenWeekly(rate, trend: $0, unit: unit)), \(TargetsFormat.percent(rate)) of bodyweight" }
                ?? "\(TargetsFormat.percent(rate)) of bodyweight a week")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: nudgeRate(1)
                case .decrement: nudgeRate(-1)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("planEditor.rate")
            stepButton("plus", label: "Faster") { nudgeRate(1) }
        }
        .animation(.snappy(duration: 0.2), value: rate)
    }

    private func nudgeRate(_ steps: Int) {
        draft.goal.weeklyRate = NutritionRate.nudged(draft.goal.weeklyRate, by: steps, direction: draft.goal.direction,
                                                     trend: trend, unit: unit)
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.exPrimaryText)
                .frame(width: 44, height: 44).background(Color.exSurface2, in: Circle())
        }
        .buttonStyle(.plain).buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier("planEditor.rate.\(symbol == "plus" ? "faster" : "slower")")
    }

    @ViewBuilder
    private var goalWeightControl: some View {
        if hasGoalWeight {
            // Empty until typed, with the trend weight as its placeholder: a suggested
            // figure read as if the person had chosen it.
            ExQuantityControl(title: "Goal weight (\(unit.rawValue))", text: $goalWeightText, step: unit == .pounds ? 1 : 0.5,
                              unit: unit.rawValue, identifier: "planEditor.goalWeight", focusOnAppear: addedGoalWeight,
                              placeholder: trend.map { Self.weightText(Mass(Mass.kg($0).value(in: unit).rounded(), unit), unit: unit) } ?? "0",
                              // The trend weight and when the goal is reached stay readable while typing.
                              noteBelow: typeSize.isAccessibilitySize ? 220 : 64)
            if let trend, let redirection = draft.goal.redirection(trend: trend) {
                redirect(redirection, trend: trend)
            } else if let trend {
                Group {
                    switch draft.goal.projection(from: trend, on: today) {
                    case .on(let date, let weeks):
                        Text("Around \(TargetsFormat.shortDate(date, today: today)), in \(weeks) \(weeks == 1 ? "week" : "weeks") at this rate.")
                    case .reached:
                        Text("Your trend weight, \(BodyFormat.weight(trend, unit)), is already at or past this.")
                    case .noGoalWeight, .maintaining:
                        Text("Your trend weight is \(BodyFormat.weight(trend, unit)). Enter the weight you're aiming for.")
                    }
                }
                .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("planEditor.eta")
            }
            Button("Remove goal weight") {
                hasGoalWeight = false
                addedGoalWeight = false
                goalWeightText = ""
                draft.goal.goalWeight = nil
            }
            .font(.exLabel).foregroundStyle(Color.exPrimaryText).frame(minHeight: 44)
        } else {
            Button {
                addedGoalWeight = true
                hasGoalWeight = true
            } label: { Label("Add a goal weight", systemImage: "flag.checkered") }
                .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("planEditor.addGoalWeight")
        }
    }

    private var goalText: String { draft.goal.goalWeight.map { "\(Self.weightText($0, unit: unit)) \(unit.rawValue)" } ?? "" }

    /// Why a goal weight the trend has already reached can't be saved as it is.
    private func redirect(_ direction: NutritionGoal.Direction, trend: Double) -> some View {
        let text = switch direction {
        case .gain: "\(goalText) is above your trend weight of \(BodyFormat.weight(trend, unit)), so losing won't get you there."
        case .lose: "\(goalText) is below your trend weight of \(BodyFormat.weight(trend, unit)), so gaining won't get you there."
        case .maintain: "Your trend weight, \(BodyFormat.weight(trend, unit)), is already at \(goalText)."
        }
        return Label(text, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exWarning)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("planEditor.eta")
    }

    /// In Save's place, what the goal weight takes instead, in one tap, or
    /// maintaining: a loss toward a weight above the trend could only cut
    /// calories for nothing. In the bar, it stays above the keypad.
    private func redirectChoices(_ direction: NutritionGoal.Direction, trend: Double) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: ExSpacing.small))
            : AnyLayout(HStackLayout(spacing: ExSpacing.small))
        return layout {
            if direction != .maintain {
                Button("\(TargetsFormat.direction(direction)) to \(goalText)") {
                    draft.goal.direction = direction
                    draft.goal.weeklyRate = NutritionRate.standard(for: direction, trend: trend, unit: unit)
                }
                .buttonStyle(ExActionStyle()).accessibilityIdentifier("planEditor.redirect")
            }
            Button("Maintain") {
                draft.goal.direction = .maintain
                draft.goal.weeklyRate = 0
            }
            .buttonStyle(ExActionStyle(secondary: direction != .maintain)).accessibilityIdentifier("planEditor.redirect.maintain")
        }
        .lineLimit(1).minimumScaleFactor(0.7)
    }

    private static func weightText(_ mass: Mass, unit: MassUnit) -> String {
        mass.value(in: unit).formatted(.number.grouping(.never).precision(.fractionLength(0...1)))
    }

    // MARK: Coaching

    private var coachingCard: some View {
        ExCard {
            ExEyebrow("Coaching")
            VStack(spacing: ExSpacing.small) {
                ForEach(PlanMode.allCases, id: \.self) { mode in modeRow(mode) }
            }
        }
    }

    private func modeRow(_ mode: PlanMode) -> some View {
        let selected = draft.mode == mode
        return Button {
            guard mode != draft.mode else { return }
            if mode == .manual, let day = preview.plan?.averageDay {
                // Start typing from the targets the plan would have had.
                draft.manual = NutritionPlanDraft.whole(day)
                manualText = ManualText(draft.manual)
            }
            draft.mode = mode
        } label: {
            HStack(alignment: .top, spacing: ExSpacing.item) {
                if !typeSize.isAccessibilitySize {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3)
                        .foregroundStyle(selected ? Color.exPrimaryText : Color.exTextMuted).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(TargetsFormat.mode(mode)).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                    Text(TargetsFormat.modeDetail(mode)).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .padding(ExSpacing.item)
            .background(selected ? Color.exPrimary.opacity(0.1) : Color.exSurface2,
                        in: RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous)
                    .strokeBorder(selected ? Color.exPrimary.opacity(0.5) : .clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("planEditor.mode.\(mode.rawValue)")
    }

    // MARK: Manual targets

    private var manualCard: some View {
        ExCard {
            ExEyebrow("Your targets")
            Text(customDays ? "For an average day. Custom weekdays share the week out from it." : "For every day.")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            let columns = typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, alignment: .leading, spacing: ExSpacing.small) {
                manualField("Calories", unit: "kcal", text: $manualText.energy, id: "energy")
                manualField("Protein", unit: "g", text: $manualText.protein, id: "protein")
                manualField("Carbs", unit: "g", text: $manualText.carbohydrate, id: "carbohydrate")
                manualField("Fat", unit: "g", text: $manualText.fat, id: "fat")
            }
            .exFieldOrder(["energy", "protein", "carbohydrate", "fat"].map { "planEditor.manual.\($0)" })
            let supplied = draft.manual.macroEnergy
            let off = draft.manual.energy > 0 && abs(supplied - draft.manual.energy) > 0.05 * draft.manual.energy
            Label("Protein, carbs and fat supply \(TargetsFormat.kcal(supplied)) kcal", systemImage: off ? "exclamationmark.triangle" : "equal.circle")
                .font(.exCaption).foregroundStyle(off ? Color.exWarning : Color.exTextSecondary)
                .accessibilityIdentifier("planEditor.manual.supplied")
        }
    }

    private func manualField(_ title: String, unit: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.exCaption).foregroundStyle(Color.exTextSecondary)
            HStack(alignment: .center, spacing: 4) {
                ExNumericTextField(title: "\(title) (\(unit))", text: text, placeholder: "0", integer: true,
                                   identifier: "planEditor.manual.\(id)")
                Text(unit).font(.exLabel).foregroundStyle(Color.exTextMuted)
            }
        }
        .padding(.horizontal, ExSpacing.item).padding(.vertical, ExSpacing.small)
        .background(Color.exSurface2, in: RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous))
    }

    // MARK: Macros

    private func macrosCard(_ preview: NutritionPlanDraft.Preview) -> some View {
        ExCard {
            ExEyebrow("Macros")
            Text("Diet").font(.exLabel).foregroundStyle(Color.exTextSecondary)
            ExChoiceChips(values: DietType.allCases, selection: $draft.diet) { TargetsFormat.diet($0) }
                .accessibilityIdentifier("planEditor.diet")
            Text(TargetsFormat.dietDetail(draft.diet)).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TargetsDivider()
            Text("Protein").font(.exLabel).foregroundStyle(Color.exTextSecondary)
            ExSegmentedControl(values: ProteinLevel.allCases, selection: $draft.protein) {
                "\(TargetsFormat.protein($0))\n\(TargetsFormat.proteinRate($0, unit: unit))"
            }
            .accessibilityIdentifier("planEditor.protein")
            if let day = preview.plan?.targets.first(where: { $0.energy > 0 }) {
                Text(proteinNote(day))
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func proteinNote(_ day: DailyTargets) -> String {
        var note = "\(TargetsFormat.grams(day.protein)) of protein a day"
        if draft.goal.direction == .lose, let goal = draft.goal.goalWeight?.kilograms, let trend, goal < trend {
            note += ", set from your goal weight while you lose"
        }
        return note + ". 1.6 to 2.2 g/kg covers what most people can use."
    }

    // MARK: Weekdays

    private var weekdayOrder: [Weekday] {
        let first = Calendar.current.firstWeekday
        return (0..<7).compactMap { Weekday(rawValue: (first - 1 + $0) % 7 + 1) }
    }

    private func weekdaysCard(_ preview: NutritionPlanDraft.Preview) -> some View {
        let targets = preview.plan?.targets ?? []
        let highest = targets.map(\.energy).max() ?? 1
        return ExCard {
            ExEyebrow("Weekdays")
            ExSegmentedControl(values: [false, true], selection: Binding(get: { customDays }, set: { custom in
                customDays = custom
                if !custom { draft.weekdayWeights = WeekdayBudget.even }
            })) { $0 ? "Custom" : "Same every day" }
                .accessibilityIdentifier("planEditor.weekdays")
            if customDays {
                VStack(spacing: 2) {
                    ForEach(weekdayOrder, id: \.self) { day in
                        weekdayRow(day, energy: targets.indices.contains(day.rawValue - 1) ? targets[day.rawValue - 1].energy : nil,
                                   highest: highest)
                    }
                }
                if let plan = preview.plan {
                    Text("The week stays \(TargetsFormat.kcal(plan.weeklyEnergy)) kcal: raising a day lowers the others.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if let day = targets.first {
                Text("Every day gets \(TargetsFormat.kcal(day.energy)) kcal.").font(.exCaption).foregroundStyle(Color.exTextSecondary)
            }
        }
    }

    private func weekdayRow(_ day: Weekday, energy: Double?, highest: Double) -> some View {
        let value = energy.map { "\(TargetsFormat.kcal($0)) kcal" } ?? "–"
        let minus = dayButton("minus", day: day, steps: -1)
        let plus = dayButton("plus", day: day, steps: 1)
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(TargetsFormat.weekday(day)).font(.exBodyMedium)
                        Spacer(minLength: ExSpacing.small)
                        Text(value).font(.exStatSmall).monospacedDigit()
                    }
                    HStack { minus; Spacer(); plus }
                }
                .padding(.vertical, 4)
            } else {
                HStack(spacing: ExSpacing.small) {
                    Text(TargetsFormat.weekday(day, style: .short)).font(.exLabel).foregroundStyle(Color.exTextSecondary)
                        .frame(width: 40, alignment: .leading)
                    GeometryReader { geometry in
                        Capsule().fill(Color.exPrimary.opacity(0.14))
                            .overlay(alignment: .leading) {
                                Capsule().fill(LinearGradient(colors: [.exPrimary, .exAccent], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: geometry.size.width * min(1, max(0, (energy ?? 0) / max(highest, 1))))
                            }
                    }
                    .frame(height: 6)
                    Text(value).font(.exLabel).monospacedDigit().foregroundStyle(Color.exTextPrimary)
                        .frame(minWidth: 76, alignment: .trailing)
                    minus
                    plus
                }
            }
        }
        .foregroundStyle(Color.exTextPrimary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TargetsFormat.weekday(day))
        .accessibilityValue(value)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: draft.weekdayWeights = WeekdayBudget.nudged(draft.weekdayWeights, day: day, by: 1)
            case .decrement: draft.weekdayWeights = WeekdayBudget.nudged(draft.weekdayWeights, day: day, by: -1)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("planEditor.weekday.\(day.rawValue)")
    }

    private func dayButton(_ symbol: String, day: Weekday, steps: Int) -> some View {
        Button {
            draft.weekdayWeights = WeekdayBudget.nudged(draft.weekdayWeights, day: day, by: steps)
        } label: {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.exPrimaryText)
                .frame(width: 32, height: 32).background(Color.exSurface2, in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).buttonRepeatBehavior(.enabled)
        .accessibilityLabel("\(steps > 0 ? "More" : "Less") on \(TargetsFormat.weekday(day))")
        .accessibilityIdentifier("planEditor.weekday.\(day.rawValue).\(steps > 0 ? "more" : "less")")
    }

    // MARK: Check-in day

    private var checkInCard: some View {
        ExCard {
            ExEyebrow("Check-in day")
            if typeSize.isAccessibilitySize {
                ExChoiceChips(values: weekdayOrder, selection: $draft.checkInDay) { TargetsFormat.weekday($0) }
            } else {
                HStack(spacing: 4) {
                    ForEach(weekdayOrder, id: \.self) { day in
                        let selected = draft.checkInDay == day
                        Button { draft.checkInDay = day } label: {
                            Text(TargetsFormat.weekday(day, style: .narrow)).font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundStyle(selected ? Color.white : Color.exTextSecondary)
                                .frame(width: 40, height: 40)
                                .background(selected ? Color.exActionFill : Color.exSurface2, in: Circle())
                                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(TargetsFormat.weekday(day))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("planEditor.checkInDay.\(day.rawValue)")
                    }
                }
                .sensoryFeedback(.selection, trigger: draft.checkInDay)
            }
            Text("Each \(TargetsFormat.weekday(draft.checkInDay)), Exerly reviews the week before and proposes new targets.")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Basis and problems

    @ViewBuilder
    private var basisNote: some View {
        if draft.mode != .manual {
            if let basis {
                Text("Worked out from an expenditure of \(BodyFormat.kcal(basis.expenditure)) ±\(BodyFormat.kcal(basis.expenditureError)) "
                    + "kcal a day \(sourceText) and a trend weight of \(BodyFormat.weight(basis.trendWeight, unit)).")
                    .font(.exCaption).foregroundStyle(Color.exTextMuted).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("planEditor.basis")
            } else {
                Label("Exerly needs your expenditure or your profile to work out targets. Add your age, height and activity in "
                    + "Profile, or choose Manual and type your own.", systemImage: "info.circle")
                    .font(.exCaption).foregroundStyle(Color.exWarning).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sourceText: String {
        if adjusting != nil { return "from this week's check-in" }
        switch request.choice?.source {
        case .measured: return "measured from your logs"
        case .previous: return "from your current plan, until your logs give a measured one"
        case .formula: return "estimated from your age, height, weight and activity (your logs take over within a few weeks)"
        case nil: return ""
        }
    }

    @ViewBuilder
    private func problems(_ preview: NutritionPlanDraft.Preview) -> some View {
        // A reached goal weight is explained beside it, with its choices.
        let redirecting = trend.map { draft.goal.redirection(trend: $0) != nil } ?? false
        let shown = (basis == nil && draft.mode != .manual) || redirecting ? [] : preview.problems
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: ExSpacing.small) {
                ForEach(shown, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("planEditor.problems")
        }
    }

    // MARK: Saving

    private func saveBar(_ preview: NutritionPlanDraft.Preview) -> some View {
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            if let plan = preview.plan, let day = plan.averageDay, typeSize.isAccessibilitySize {
                Text("\(TargetsFormat.kcal(day.energy)) kcal a day").font(.exH3).monospacedDigit()
                    .foregroundStyle(Color.exTextPrimary).lineLimit(1).minimumScaleFactor(0.6)
                    .accessibilityLabel("New targets")
                    .accessibilityValue("\(TargetsFormat.kcal(day.energy)) kilocalories a day")
                    .accessibilityIdentifier("planEditor.preview")
            } else if let plan = preview.plan, let day = plan.averageDay {
                let even = WeekdayBudget.isEven(plan.weekdayWeights)
                HStack(alignment: .firstTextBaseline, spacing: ExSpacing.small) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(TargetsFormat.kcal(day.energy)).font(.exStatMedium).monospacedDigit().foregroundStyle(Color.exTextPrimary)
                                .contentTransition(.numericText(value: day.energy))
                            Text(even ? "kcal a day" : "kcal a day, on average").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                        }
                        if !typeSize.isAccessibilitySize {
                            Text("Protein \(TargetsFormat.grams(day.protein)) · Carbs \(TargetsFormat.grams(day.carbohydrate)) · Fat \(TargetsFormat.grams(day.fat))")
                                .font(.exCaption).monospacedDigit().foregroundStyle(Color.exTextSecondary).lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                    Spacer(minLength: 0)
                    if let current = request.current?.averageDay, request.current?.id != adjusting?.proposed.id {
                        Text("\(TargetsFormat.signedKcal(day.energy - current.energy)) vs now").font(.exCaption.weight(.semibold))
                            .monospacedDigit().foregroundStyle(Color.exTextSecondary)
                    }
                }
                .animation(.snappy(duration: 0.2), value: day)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("New targets")
                .accessibilityValue("\(TargetsFormat.kcal(day.energy)) kilocalories a day\(even ? "" : " on average"), "
                    + "protein \(TargetsFormat.kcal(day.protein)) grams, carbs \(TargetsFormat.kcal(day.carbohydrate)) grams, "
                    + "fat \(TargetsFormat.kcal(day.fat)) grams")
                .accessibilityIdentifier("planEditor.preview")
            } else if let problem = preview.problems.first {
                Text(problem).font(.exCaption).foregroundStyle(Color.exWarning).lineLimit(3)
                    .accessibilityIdentifier("planEditor.preview")
            }
            if let error {
                Text(error).font(.exCaption).foregroundStyle(Color.exError).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("planEditor.error")
            }
            if let trend, let redirection = draft.goal.redirection(trend: trend) {
                redirectChoices(redirection, trend: trend)
            } else {
                Button(saveTitle) { save(preview) }
                    .buttonStyle(ExActionStyle()).disabled(preview.plan == nil)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityIdentifier("planEditor.save")
            }
        }
        // A bar that stays on screen; the editor above carries the full text sizes.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.horizontal, ExSpacing.page).padding(.top, ExSpacing.item).padding(.bottom, ExSpacing.small)
        .frame(maxWidth: 700).frame(maxWidth: .infinity)
        .background(alignment: .top) {
            Color.exSurface1.overlay(alignment: .top) { TargetsDivider() }.ignoresSafeArea(edges: .bottom)
        }
    }

    private func save(_ preview: NutritionPlanDraft.Preview) {
        guard let plan = preview.plan else { return }
        error = nil
        let kcal = TargetsFormat.kcal(plan.averageDay?.energy ?? 0)
        do {
            if let adjusting {
                let adjusted = try NutritionCheckIn.adjusted(adjusting.proposal, to: plan, from: adjusting.current)
                let agent = workspace.agent
                guard agent.proposal(adjusted.id) == nil else {
                    error = "This check-in was already decided on another device. Your targets are unchanged."
                    return
                }
                try agent.file(adjusted)
                try agent.accept(adjusted.id)
                onSaved("Targets updated to \(kcal) kcal a day", adjusted.id)
            } else {
                try workspace.nutrition.savePlan(plan, timeZone: timeZone)
                onSaved(request.current == nil ? "Targets set: \(kcal) kcal a day" : "New targets from today: \(kcal) kcal a day", nil)
            }
        } catch {
            self.error = TargetsFormat.message(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let workspace = workspace
        Task { await workspace.synchronize() }
        dismiss()
    }
}
