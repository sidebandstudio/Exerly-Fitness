import ExerlyCore
import SwiftUI

/// The goal editor's choices as typed: one amount with a preset, or a
/// range of up to three. Switching presets keeps what's typed.
struct NutrientGoalDraft: Equatable {
    enum Kind: String, CaseIterable {
        case atLeast, about, atMost, range

        var title: String {
            switch self {
            case .atLeast: "At least"
            case .about: "About"
            case .atMost: "At most"
            case .range: "Range"
            }
        }

        /// The one part a preset sets; nil for a range.
        var part: NutrientGoal.Part? {
            switch self {
            case .atLeast: .floor
            case .about: .target
            case .atMost: .ceiling
            case .range: nil
            }
        }
    }

    var kind: Kind
    var floor: String
    var target: String
    var ceiling: String

    init(_ goal: NutrientGoal?) {
        floor = Self.text(goal?.floor)
        target = Self.text(goal?.target)
        ceiling = Self.text(goal?.ceiling)
        switch (goal?.floor != nil, goal?.target != nil, goal?.ceiling != nil) {
        case (false, true, false): kind = .about
        case (false, false, true): kind = .atMost
        case (true, false, false), (false, false, false): kind = .atLeast
        default: kind = .range
        }
    }

    subscript(part: NutrientGoal.Part) -> String {
        get {
            switch part {
            case .floor: floor
            case .target: target
            case .ceiling: ceiling
            }
        }
        set {
            switch part {
            case .floor: floor = newValue
            case .target: target = newValue
            case .ceiling: ceiling = newValue
            }
        }
    }

    /// Changes preset, carrying the amount on show across: At least 28 becomes About 28.
    mutating func choose(_ kind: Kind) {
        guard kind != self.kind else { return }
        if let part = kind.part {
            let shown = self.kind.part.map { self[$0] } ?? [floor, target, ceiling].first { !$0.isEmpty } ?? ""
            if self.kind != .range || self[part].isEmpty { self[part] = shown }
        }
        self.kind = kind
    }

    /// The goal typed, or why it can't be saved; both nil while nothing is typed.
    func goal(_ nutrient: Nutrient) -> (goal: NutrientGoal?, problem: String?) {
        let parts = kind.part.map { [$0] } ?? NutrientGoal.Part.allCases
        var values: [NutrientGoal.Part: Double] = [:]
        for part in parts where !self[part].trimmingCharacters(in: .whitespaces).isEmpty {
            guard let value = TrainingInput.number(self[part]) else { return (nil, "Enter amounts as numbers.") }
            values[part] = value
        }
        guard !values.isEmpty else { return (nil, nil) }
        let goal = NutrientGoal(floor: values[.floor], target: values[.target], ceiling: values[.ceiling])
        if let order = goal.misordered, let low = values[order.lower], let high = values[order.upper] {
            return (nil, "The \(order.lower.rawValue), \(IntakeFormat.amount(low, nutrient)), can't be above the "
                + "\(order.upper.rawValue), \(IntakeFormat.amount(high, nutrient)).")
        }
        return (goal, nil)
    }

    static func text(_ value: Double?) -> String {
        value.map { $0.formatted(.number.grouping(.never).precision(.fractionLength(0...2))) } ?? ""
    }
}

/// One nutrient's goal from today: a preset with one amount or a range,
/// in the nutrient's unit, prefilled with the goal in force, with the
/// daily value one tap away. Earlier days keep the goal they had.
struct NutrientGoalEditor: View {
    @ObservedObject var workspace: TrainingWorkspace
    let nutrient: Nutrient
    let timeZone: TimeZone
    private let current: NutrientGoal?
    private let isCustom: Bool
    private let start: NutrientGoalDraft
    @State private var draft: NutrientGoalDraft
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(workspace: TrainingWorkspace, nutrient: Nutrient, timeZone: TimeZone) {
        self.workspace = workspace
        self.nutrient = nutrient
        self.timeZone = timeZone
        let today = LocalDate(Date(), in: timeZone)
        let plan = workspace.nutrition.plan(on: today)
        current = plan?.goal(for: nutrient, on: today)
        isCustom = plan?.nutrientGoals?[nutrient] != nil
        start = NutrientGoalDraft(current)
        _draft = State(initialValue: start)
    }

    private var unit: String { nutrient.unit.rawValue }
    private var reference: NutrientGoal? { NutrientGoal(reference: nutrient) }

    var body: some View {
        let typed = draft.goal(nutrient)
        NavigationStack {
            ExScreen {
                ExCard {
                    ExSegmentedControl(values: NutrientGoalDraft.Kind.allCases,
                                       selection: Binding(get: { draft.kind }, set: { draft.choose($0) })) { $0.title }
                        .accessibilityIdentifier("goalEditor.kind")
                    if let part = draft.kind.part {
                        field(part, title: draft.kind.title, large: true)
                    } else {
                        VStack(spacing: ExSpacing.small) {
                            field(.floor, title: "Floor", hint: "at least")
                            field(.target, title: "Target", hint: "about")
                            field(.ceiling, title: "Ceiling", hint: "at most")
                        }
                        .exFieldOrder(NutrientGoal.Part.allCases.map { "goalEditor.\($0.rawValue)" })
                    }
                    Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                    if let problem = typed.problem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.exCaption.weight(.medium))
                            .foregroundStyle(Color.exWarning).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("goalEditor.problem")
                    }
                }
                .sensoryFeedback(.selection, trigger: draft.kind)
                .onChange(of: typed.problem) { _, problem in
                    if let problem { UIAccessibility.post(notification: .announcement, argument: problem) }
                }
                referenceCard(typed.goal)
                if let error {
                    Text(error).font(.exCaption).foregroundStyle(Color.exError).fixedSize(horizontal: false, vertical: true)
                }
                Text("Applies from today. Earlier days keep the goal they had, in charts and averages too.")
                    .font(.exSmall).foregroundStyle(Color.exTextMuted).fixedSize(horizontal: false, vertical: true)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(IntakeFormat.name(nutrient))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("goalEditor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(typed.goal) }
                        .disabled(typed.goal == nil || typed.goal == current)
                        .accessibilityIdentifier("goalEditor.save")
                }
            }
        }
        .interactiveDismissDisabled(draft != start)
    }

    private var detail: String {
        switch draft.kind {
        case .atLeast: "Met once you reach it. More is fine."
        case .about: "Met within 10 % either side."
        case .atMost: "Met while you stay at or under it."
        case .range: "Fill in any of the three; leave the rest empty."
        }
    }

    private func field(_ part: NutrientGoal.Part, title: String, hint: String? = nil, large: Bool = false) -> some View {
        let layout = typeSize.isAccessibilitySize || large
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .center, spacing: ExSpacing.small))
        return layout {
            // A preset's one amount goes without a label: the chosen preset names it.
            if !large {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.exLabel).foregroundStyle(Color.exTextSecondary)
                    if let hint { Text(hint).font(.exSmall).foregroundStyle(Color.exTextMuted) }
                }
                .frame(minWidth: 76, alignment: .leading)
            }
            HStack(alignment: .center, spacing: 4) {
                ExNumericTextField(title: "\(title) (\(unit))", text: Binding(get: { draft[part] }, set: { draft[part] = $0 }),
                                   placeholder: large ? "0" : "None", centered: large, identifier: "goalEditor.\(part.rawValue)",
                                   focusOnAppear: large)
                Text(unit).font(.exLabel).foregroundStyle(Color.exTextMuted)
            }
        }
        .padding(.horizontal, ExSpacing.item).padding(.vertical, ExSpacing.small)
        .background(Color.exSurface2, in: RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous))
    }

    private func referenceCard(_ typed: NutrientGoal?) -> some View {
        ExCard {
            if let reference {
                ExEyebrow("US FDA daily value")
                Text(IntakeFormat.goalSummary(reference, nutrient)).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                if typed != reference {
                    Button("Reset to the daily value") { draft = NutrientGoalDraft(reference) }
                        .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("goalEditor.reset")
                } else {
                    Text(isCustom ? "Save to go back to it." : "Your goal is the daily value until you change it.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("There's no daily value for \(IntakeFormat.name(nutrient).lowercased()), so it has no goal until you set one.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                if isCustom {
                    Button("Remove goal", role: .destructive) { save(nil) }
                        .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("goalEditor.remove")
                }
            }
        }
    }

    private func save(_ goal: NutrientGoal?) {
        error = nil
        do {
            try workspace.nutrition.setGoal(goal, for: nutrient, timeZone: timeZone)
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
