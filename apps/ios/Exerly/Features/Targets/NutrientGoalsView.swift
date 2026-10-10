import ExerlyCore
import SwiftUI

/// Every nutrient's goal from today, yours or the daily value, with up to
/// three pinned to Today. A row opens its editor; a pin changes at once.
struct NutrientGoalsView: View {
    @ObservedObject var workspace: TrainingWorkspace
    let timeZone: TimeZone
    /// Shown as a sheet, a Done button.
    var done: (() -> Void)?
    @State private var editing: Nutrient?
    @State private var error: String?
    @State private var query = ""
    @Environment(\.dynamicTypeSize) private var typeSize

    private static let groups: [Nutrient.Group] = [.carbohydrates, .fats, .vitamins, .minerals, .aminoAcids, .other]

    var body: some View {
        let today = LocalDate(Date(), in: timeZone)
        let plan = workspace.nutrition.plan(on: today)
        let pinned = plan?.pinnedNutrients ?? []
        let custom = plan?.nutrientGoals ?? [:]
        ExScreen {
            if let plan {
                Text("Pin up to \(NutritionPlan.maximumPins) to show on Today. Changes apply from today; earlier days keep their goals.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exError)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Sodium sat several screens down; a name or part of one finds it.
                ExSearchField(text: $query, label: "Search nutrients").accessibilityIdentifier("goals.search")
                let search = query.trimmingCharacters(in: .whitespaces)
                if !search.isEmpty {
                    let matches = Nutrient.allCases.filter { Self.groups.contains($0.group) && IntakeFormat.name($0).localizedStandardContains(search) }
                    if matches.isEmpty {
                        Text("No nutrient is called “\(search)”.").font(.exBody).foregroundStyle(Color.exTextSecondary)
                    } else {
                        section("Matches", matches, plan: plan, today: today)
                    }
                } else if !pinned.isEmpty {
                    section("On Today", note: pinned.count >= NutritionPlan.maximumPins ? "Unpin one to pin another." : nil,
                            pinned, plan: plan, today: today)
                }
                if search.isEmpty {
                    let yours = Nutrient.allCases.filter { custom[$0] != nil && !pinned.contains($0) }
                    if !yours.isEmpty { section("Your goals", yours, plan: plan, today: today) }
                    ForEach(Self.groups, id: \.self) { group in
                        let rest = Nutrient.allCases.filter { $0.group == group && custom[$0] == nil && !pinned.contains($0) }
                        if !rest.isEmpty { section(IntakeFormat.group(group), rest, plan: plan, today: today) }
                    }
                }
            } else {
                Text("Set up your targets first; nutrient goals and pins are part of your plan.")
                    .font(.exBody).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.snappy, value: pinned)
        .sensoryFeedback(.selection, trigger: pinned)
        .accessibilityIdentifier("goals.screen")
        .navigationTitle("Nutrient goals")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let done {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: done).accessibilityIdentifier("goals.done") }
            }
        }
        .sheet(item: $editing) { NutrientGoalEditor(workspace: workspace, nutrient: $0, timeZone: timeZone) }
    }

    private func section(_ title: String, note: String? = nil, _ nutrients: [Nutrient], plan: NutritionPlan,
                         today: LocalDate) -> some View {
        let pinned = plan.pinnedNutrients ?? []
        return VStack(alignment: .leading, spacing: 0) {
            let heading = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
            heading {
                ExEyebrow(title, color: .exPrimaryText)
                if !typeSize.isAccessibilitySize { Spacer(minLength: ExSpacing.small) }
                if let note { Text(note).font(.exSmall).foregroundStyle(Color.exTextMuted).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(.horizontal, ExSpacing.content).padding(.top, ExSpacing.content).padding(.bottom, ExSpacing.tight)
            ForEach(Array(nutrients.enumerated()), id: \.element) { index, nutrient in
                if index > 0 { Rectangle().fill(Color.exBorder.opacity(0.45)).frame(height: 0.5).padding(.leading, ExSpacing.content) }
                row(nutrient, goal: plan.goal(for: nutrient, on: today), mine: plan.nutrientGoals?[nutrient] != nil,
                    pinned: pinned.contains(nutrient), full: pinned.count >= NutritionPlan.maximumPins)
            }
        }
        .padding(.bottom, ExSpacing.tight)
        .background(Color.exSurface1, in: RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous).strokeBorder(Color.exBorder.opacity(0.5), lineWidth: 0.5)
        }
    }

    private func row(_ nutrient: Nutrient, goal: NutrientGoal?, mine: Bool, pinned: Bool, full: Bool) -> some View {
        let name = IntakeFormat.name(nutrient)
        let source = goal == nil ? "" : mine ? " · Yours" : " · Daily value"
        return HStack(spacing: ExSpacing.tight) {
            Button { editing = nutrient } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                    Text((goal.map { IntakeFormat.goalSummary($0, nutrient) } ?? "No goal") + source)
                        .font(.exCaption).foregroundStyle(mine ? Color.exPrimaryText : Color.exTextSecondary).monospacedDigit()
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityValue((goal.map { IntakeFormat.goalSummary($0, nutrient, spoken: true) } ?? "No goal")
                + (goal == nil ? "" : mine ? ", your goal" : ", daily value"))
            .accessibilityHint("Edits the goal")
            .accessibilityIdentifier("goals.nutrient.\(nutrient.rawValue)")
            Button { toggle(nutrient, pinned: pinned) } label: {
                Image(systemName: pinned ? "pin.fill" : "pin").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(pinned ? Color.exPrimaryText : Color.exTextMuted)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(full && !pinned)
            .opacity(full && !pinned ? 0.35 : 1)
            .accessibilityLabel(pinned ? "Unpin \(name) from Today" : "Pin \(name) to Today")
            .accessibilityIdentifier("goals.pin.\(nutrient.rawValue)")
        }
        .padding(.leading, ExSpacing.content).padding(.trailing, ExSpacing.small)
    }

    private func toggle(_ nutrient: Nutrient, pinned: Bool) {
        error = nil
        do {
            try workspace.nutrition.setPinned(nutrient, !pinned, timeZone: timeZone)
        } catch {
            self.error = TargetsFormat.message(error)
            return
        }
        let workspace = workspace
        Task { await workspace.synchronize() }
    }
}
