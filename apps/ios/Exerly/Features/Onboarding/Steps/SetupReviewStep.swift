import ExerlyCore
import SwiftUI

/// The targets the answers produce, with the macro split and the person's
/// own numbers as the only choices left, then Finish.
struct SetupReviewStep: View {
    @ObservedObject var state: OnboardingState
    let onComplete: () -> Void
    /// The last targets shown, kept on screen while a changed answer reloads.
    @State private var shown: SetupPreview?
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var authVM: AuthViewModel
    @State private var bringHistory = false

    private var current: SetupPreview? { state.serverPreview ?? shown }
    private var unit: MassUnit { state.useMetric ? .kilograms : .pounds }

    var body: some View {
        SetupPage(title: "Review your targets",
                  detail: state.manualTargetMode ? "Your own numbers, ready for your diary."
                    : "Your starting point. Fine-tune it any time in Targets.",
                  action: "Finish setup", identifier: "setup.finish",
                  actionDisabled: state.isSubmitting, showsAction: current != nil,
                  busy: state.isSubmitting ? "Saving your setup…" : nil, perform: onComplete) {
            if let preview = current {
                targets(preview)
                if let error = state.previewError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exError)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("setup.previewError")
                }
            } else if let error = state.previewError {
                ExCard {
                    Text("Your answers are saved").font(.exH3)
                    Text(error).font(.exBody).foregroundStyle(Color.exError)
                    Button("Try loading targets again") { Task { await state.loadPreview() } }
                        .buttonStyle(ExActionStyle(secondary: true))
                }
            } else {
                ProgressView("Working out your targets…").frame(maxWidth: .infinity, minHeight: 160)
            }
            if !state.manualTargetMode { macroSplit }
            ownTargets
            if let preview = current { basis(preview) }
            if state.repairSteps == nil {
                training
                history
            }
        }
        .task(id: state.previewIdentity) {
            // Typing a number changes the answers at every key. Wait for a pause.
            if state.serverPreview == nil, shown != nil {
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            }
            await state.loadPreview()
        }
        .onChange(of: state.serverPreview?.targets) { _, _ in
            if let preview = state.serverPreview { shown = preview }
        }
    }

    // MARK: Targets

    private func targets(_ preview: SetupPreview) -> some View {
        let day = DailyTargets(energy: preview.targets.calories, protein: preview.targets.protein_g,
                               fat: preview.targets.fat_g, carbohydrate: preview.targets.carbs_g)
        return ExCard(accent: true) {
            HStack {
                ExEyebrow("Every day", color: .exPrimaryText)
                Spacer(minLength: 0)
                if state.serverPreview == nil { ProgressView().controlSize(.small) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TargetsFormat.kcal(day.energy)).font(.exStat).monospacedDigit().foregroundStyle(Color.exTextPrimary)
                    .contentTransition(.numericText(value: day.energy))
                Text("kcal").font(.exBodyMedium).foregroundStyle(Color.exTextSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Daily calorie target")
            .accessibilityValue("\(TargetsFormat.kcal(day.energy)) kilocalories")
            .accessibilityIdentifier("setup.calories")
            TargetsMacroBar(day: day)
            TargetsMacroRow(day: day)
        }
        .opacity(state.serverPreview == nil ? 0.6 : 1)
        .animation(.snappy, value: day)
    }

    private var macroSplit: some View {
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            SetupLabel("Macro split")
            ExChoiceChips(values: ["balanced", "low_fat", "low_carb", "keto", "high_protein"], selection: Binding(
                get: { state.dietType ?? (state.dietaryStyle == .keto ? "keto" : "balanced") },
                set: { state.dietType = $0 }
            )) { Self.split($0) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Macro split")
            .accessibilityIdentifier("setup.macroSplit")
            Text(Self.splitDetail(state.dietType ?? "balanced"))
                .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ownTargets: some View {
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            SetupRows {
                Toggle(isOn: $state.manualTargetMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use my own targets").font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                        Text("For numbers from a coach or another app").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    }
                }
                .tint(Color.exActionFill)
                .padding(.horizontal, ExSpacing.content).padding(.vertical, ExSpacing.small)
                .frame(minHeight: 60)
                .accessibilityIdentifier("setup.manualTargets")
                if state.manualTargetMode {
                    manualRow("Calories", unit: "kcal", value: state.manualTargets.calories) { state.manualTargets.calories = $0 }
                    manualRow("Protein", unit: "g", value: state.manualTargets.protein_g) { state.manualTargets.protein_g = $0 }
                    manualRow("Carbs", unit: "g", value: state.manualTargets.carbs_g) { state.manualTargets.carbs_g = $0 }
                    manualRow("Fat", unit: "g", value: state.manualTargets.fat_g) { state.manualTargets.fat_g = $0 }
                }
            }
        }
    }

    private func manualRow(_ title: String, unit: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        SetupRow(title: title) {
            SetupNumberField(label: title, unit: unit, value: value, digits: 0, width: 130) { set($0 ?? 0) }
        }
    }

    // MARK: Why

    private func basis(_ preview: SetupPreview) -> some View {
        SetupRows {
            if !state.manualTargetMode, let maintenance = preview.maintenance {
                line("Estimated maintenance", value: "\(TargetsFormat.kcal(maintenance)) kcal")
            }
            line("Goal", value: goal)
            line("Activity", value: state.activityLevel.label)
            line("First weigh-in", value: BodyFormat.weight(state.weightKg, unit))
        }
        .accessibilityElement(children: .contain)
    }

    private var training: some View {
        SetupRows {
            line("Training", value: state.workoutDaysPerWeek == 0 ? "Nutrition only"
                 : "\(state.workoutDaysPerWeek) \(state.workoutDaysPerWeek == 1 ? "workout" : "workouts") a week")
            if state.workoutDaysPerWeek > 0 {
                line("Where", value: state.hasGymAccess ? "Full gym" : state.equipment.isEmpty ? "No equipment"
                     : state.equipment.map(\.label).sorted().joined(separator: ", "))
            }
        }
    }

    /// Coming from another app: the Import & export hub opens once setup is done.
    private var history: some View {
        SetupRows {
            Toggle(isOn: Binding(get: { bringHistory }, set: { on in
                bringHistory = on
                if let id = authVM.currentUser?.id { BringHistory.remember(accountID: id, on) }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bring your history").font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                    Text("Import from MacroFactor, Hevy or Strong next. You'll see everything before it's saved.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Color.exActionFill)
            .padding(.horizontal, ExSpacing.content).padding(.vertical, ExSpacing.small)
            .frame(minHeight: 60)
            .accessibilityIdentifier("setup.bringHistory")
        }
        .onAppear { bringHistory = authVM.currentUser?.id.map(BringHistory.isOn(accountID:)) ?? false }
    }

    private func line(_ title: String, value: String) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.tight))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: ExSpacing.item))
        return layout {
            Text(title).font(.exBody).foregroundStyle(Color.exTextSecondary)
            if !typeSize.isAccessibilitySize { Spacer(minLength: ExSpacing.small) }
            Text(value).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, ExSpacing.content).padding(.vertical, ExSpacing.item)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var goal: String {
        switch state.nutritionGoal {
        case "lose": "Lose weight, to \(BodyFormat.weight(state.targetWeightKg, unit))"
        case "gain": "Gain weight, to \(BodyFormat.weight(state.targetWeightKg, unit))"
        default: "Maintain weight"
        }
    }

    static func split(_ value: String) -> String {
        switch value {
        case "low_fat": "More carbs"
        case "low_carb": "Fewer carbs"
        case "keto": "Keto"
        case "high_protein": "Higher protein"
        default: "Balanced"
        }
    }

    static func splitDetail(_ value: String) -> String {
        switch value {
        case "low_fat": "More of your calories from carbs, less from fat."
        case "low_carb": "More of your calories from fat, less from carbs."
        case "keto": "Very few carbs, most calories from fat."
        case "high_protein": "A larger share of calories from protein."
        default: "A flexible start with room for carbs and fat."
        }
    }
}
