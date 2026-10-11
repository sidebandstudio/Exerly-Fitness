import ExerlyCore
import SwiftUI

struct TrainingPlanSetupView: View {
    let workspace: TrainingWorkspace
    let unit: MassUnit
    @EnvironmentObject private var auth: AuthViewModel

    var body: some View {
        NavigationStack {
            TrainingPlanSetupContent(workspace: workspace, unit: unit, auth: auth)
                .id("\(auth.sessionID):\(workspace.accountID)")
        }
    }
}

private struct TrainingPlanSetupContent: View {
    let workspace: TrainingWorkspace
    let unit: MassUnit
    @StateObject private var model: TrainingPlanSetupModel
    @StateObject private var preferences: PreferencesStore
    @State private var page = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(workspace: TrainingWorkspace, unit: MassUnit, auth: AuthViewModel) {
        self.workspace = workspace
        self.unit = unit
        let accountID = workspace.accountID, sessionID = auth.sessionID
        let owns: () -> Bool = { [weak auth] in auth?.currentUser?.id == accountID && auth?.sessionID == sessionID }
        _preferences = StateObject(wrappedValue: PreferencesStore(accountID: accountID, ownerIsActive: owns))
        _model = StateObject(wrappedValue: TrainingPlanSetupModel(workspace: workspace, unit: unit, ownerIsActive: owns))
    }

    var body: some View {
        Group {
            if let candidate = model.candidate {
                TrainingPlanPreview(workspace: workspace, unit: unit, model: model, candidate: candidate)
            } else {
                ExScreen {
                    VStack(alignment: .leading, spacing: ExSpacing.small) {
                        ExEyebrow("Question \(page + 1) of 3", color: .exPrimaryText)
                        ExProgressBar(value: Double(page + 1), total: 3)
                    }
                    if page == 0 { goals } else if page == 1 { experienceAndTime } else { equipment }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.exBody).foregroundStyle(Color.exError).accessibilityIdentifier("planSetup.error")
                    }
                }
                .id(page)
                .exFooter {
                    Button(page == 2 ? "Build plan" : "Continue") {
                        if page == 2 { model.prepare() } else { page += 1 }
                    }.buttonStyle(ExActionStyle()).accessibilityIdentifier("planSetup.continue")
                        .disabled(page == 0 && model.answers.days == nil)
                        .padding(ExSpacing.page).background(Color.exBackground)
                }
            }
        }
        .navigationTitle(model.candidate == nil ? "Your workout plan" : model.accepted ? "Plan saved" : "Review your plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(model.accepted ? "Done" : "Cancel") { dismiss() }.accessibilityIdentifier("planSetup.close")
            }
            ToolbarItem(placement: .primaryAction) {
                if model.candidate != nil, model.canRevise {
                    Button("Edit") { model.revise() }.accessibilityLabel("Edit plan answers")
                        .accessibilityIdentifier("planSetup.revise")
                } else if model.candidate == nil, page > 0 {
                    Button("Back") { page -= 1 }.accessibilityIdentifier("planSetup.back")
                }
            }
        }
        .task { await model.loadPreferences(preferences) }
        .onDisappear { preferences.stop() }
    }

    private var goals: some View {
        VStack(alignment: .leading, spacing: ExSpacing.section) {
            heading("What do you want from training?", detail: "Choose a focus for your workouts. Your nutrition goal can be different.")
            Text(model.preferenceMessage).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                .accessibilityIdentifier("planSetup.preferenceStatus")
            if model.loadingPreferences { ProgressView("Loading your setup…") }
            VStack(spacing: ExSpacing.item) {
                ForEach(ProgramGeneration.Goal.allCases, id: \.self) { goal in
                    SelectionCard(title: TrainingPlanFormat.goal(goal), subtitle: goalDetail(goal),
                                  isSelected: model.answers.goal == goal) { model.answers.goal = goal }
                        .accessibilityIdentifier("planSetup.goal.\(goal.rawValue)")
                }
            }
            ExCard {
                ExSectionHeading("Strength workouts per week")
                ExChoiceChips(values: Array(2...6).map(Optional.some), selection: $model.answers.days) { "\($0 ?? 0)" }
                if let saved = model.answers.savedDaysOutsideBuilder {
                    Text(saved == 0 ? "Your setup is nutrition-only. Choose 2–6 strength days if you want to add a plan." :
                         "Your saved weekly goal is \(saved). This builder supports 2–6 strength days; choose how many to use for this plan.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                } else {
                    Text("Choose days you can keep. The plan rotates through workouts; you decide which calendar days to train.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
            }.accessibilityIdentifier("planSetup.days")
        }
    }

    private var experienceAndTime: some View {
        VStack(alignment: .leading, spacing: ExSpacing.section) {
            heading("Make it fit your week", detail: "Experience shapes the starting workload. Session length limits how many sets are planned.")
            VStack(spacing: ExSpacing.item) {
                ForEach(ProgramGeneration.Experience.allCases, id: \.self) { value in
                    SelectionCard(title: TrainingPlanFormat.experience(value), isSelected: model.answers.experience == value) {
                        model.answers.experience = value
                    }.accessibilityIdentifier("planSetup.experience.\(value.rawValue)")
                }
            }
            ExCard {
                ExSectionHeading("Time for each workout")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ExSpacing.small), count: typeSize.isAccessibilitySize ? 1 : 3), spacing: ExSpacing.small) {
                    ForEach([30, 45, 60, 75, 90, 120], id: \.self) { minutes in
                        Button { model.answers.minutes = minutes } label: {
                            Text("\(minutes) min").font(.exLabel).frame(maxWidth: .infinity, minHeight: 48)
                                .foregroundStyle(model.answers.minutes == minutes ? Color.white : Color.exTextPrimary)
                                .background(model.answers.minutes == minutes ? Color.exActionFill : Color.exSurface2,
                                            in: RoundedRectangle(cornerRadius: ExRadius.control))
                        }.buttonStyle(.plain).accessibilityAddTraits(model.answers.minutes == minutes ? .isSelected : [])
                            .accessibilityIdentifier("planSetup.minutes.\(minutes)")
                    }
                }
                Text("A planning budget. Actual time depends on your pace and rest between sets.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary)
            }
        }
    }

    private var equipment: some View {
        VStack(alignment: .leading, spacing: ExSpacing.section) {
            heading("Use the equipment you have", detail: "We'll choose exercises from the library using these choices. Review every movement before you save.")
            SelectionCard(title: "Full gym", subtitle: "Barbells, benches, racks, dumbbells, cables and machines.",
                          icon: "building.2", isSelected: model.answers.fullGym) { model.answers.fullGym = true }
                .accessibilityIdentifier("planSetup.fullGym")
            SelectionCard(title: "Choose my equipment", subtitle: "Home, a smaller gym, or bodyweight only.",
                          icon: "house", isSelected: !model.answers.fullGym) { model.answers.fullGym = false }
                .accessibilityIdentifier("planSetup.chooseEquipment")
            if !model.answers.fullGym {
                ExCard {
                    ForEach([ExerlyCore.Equipment.dumbbell, .flatBench, .inclineBench, .barbell, .rack,
                             .pullUpBar, .kettlebell, .resistanceBand, .cable, .machine], id: \.self) { value in
                        equipmentChoice(value)
                    }
                    DisclosureGroup("More equipment") {
                        ForEach(ExerlyCore.Equipment.allCases.filter { ![.bodyweight, .dumbbell, .flatBench, .inclineBench, .barbell, .rack, .pullUpBar, .kettlebell, .resistanceBand, .cable, .machine].contains($0) }, id: \.self) { equipmentChoice($0) }
                    }.font(.exLabel)
                    Text("Bodyweight movements are always available. Select a rack or bench only if you have one.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
            }
            DisclosureGroup("Muscle focus, optional") {
                VStack(alignment: .leading, spacing: ExSpacing.item) {
                    Text("Give selected muscles more of the planned work. Limited time or equipment may leave gaps, which the review will explain.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    ForEach([Muscle.chest, .lats, .midBack, .quads, .hamstrings, .glutes, .sideDelts, .rearDelts, .biceps, .triceps, .calves, .abs], id: \.self) { muscle in
                        Button {
                            if model.answers.emphasis.contains(muscle) { model.answers.emphasis.remove(muscle) } else { model.answers.emphasis.insert(muscle) }
                        } label: { choiceLabel(muscle.name, selected: model.answers.emphasis.contains(muscle)) }
                            .buttonStyle(.plain).accessibilityAddTraits(model.answers.emphasis.contains(muscle) ? .isSelected : [])
                    }
                }.padding(.top, ExSpacing.item)
            }.font(.exLabel)
        }
    }

    private func equipmentChoice(_ value: ExerlyCore.Equipment) -> some View {
        Button {
            if model.answers.equipment.contains(value) { model.answers.equipment.remove(value) } else { model.answers.equipment.insert(value) }
        } label: { choiceLabel(TrainingPlanFormat.equipment(value), selected: model.answers.equipment.contains(value)) }
            .buttonStyle(.plain).accessibilityAddTraits(model.answers.equipment.contains(value) ? .isSelected : [])
            .accessibilityIdentifier("planSetup.equipment.\(value.rawValue)")
    }
    private func choiceLabel(_ title: String, selected: Bool) -> some View {
        HStack(spacing: ExSpacing.item) {
            Text(title).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
            Spacer(minLength: ExSpacing.small)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.exPrimaryText).accessibilityHidden(true)
        }.frame(minHeight: 44).contentShape(Rectangle())
    }
    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: ExSpacing.item) {
            Text(title).font(.exH2).accessibilityAddTraits(.isHeader)
            Text(detail).font(.exBody).foregroundStyle(Color.exTextSecondary)
        }
    }
    private func goalDetail(_ goal: ProgramGeneration.Goal) -> String {
        switch goal {
        case .hypertrophy: "Focus on muscle growth across the week."
        case .strength: "Practice heavier main lifts with lower rep ranges."
        case .general: "Train the main muscle groups and build a routine."
        }
    }
}

private struct TrainingPlanPreview: View {
    let workspace: TrainingWorkspace
    let unit: MassUnit
    @ObservedObject var model: TrainingPlanSetupModel
    let candidate: TrainingPlanCandidate

    var body: some View {
        ScrollViewReader { scroll in
        ExList {
            Section {
                ExCard(accent: true) {
                    Text(candidate.program.name).font(.exH1)
                    Text("\(candidate.program.trainingDays.count) workouts per cycle · \(candidate.answers.minutes) min budget")
                        .font(.exBodyMedium).accessibilityIdentifier("planSetup.summary")
                    Text(TrainingPlanFormat.goal(candidate.answers.goal)).font(.exBody)
                    Text("\(TrainingPlanFormat.experience(candidate.answers.experience)) · \(candidate.equipmentSummary)")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    if model.accepted {
                        Label("Saved to your programs", systemImage: "checkmark.circle.fill").font(.exBodyMedium)
                            .accessibilityIdentifier("planSetup.saved")
                        NavigationLink {
                            TrainingProgramDetailView(workspace: workspace, programID: candidate.program.id)
                        } label: { Text("Open your program") }.buttonStyle(ExActionStyle())
                            .accessibilityIdentifier("planSetup.openProgram")
                        Text("Choose Follow program when you're ready to use its schedule.")
                            .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    }
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets()).id("plan-top")
            }
            Section("How to use this plan") {
                Text("Work through these days in order, with rest days when you need them. The first workout helps establish your starting weights.")
                Text("Reps are repetitions. Reps in reserve means how many more you think you could do before you have to stop.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary)
            }
            Section("Your workouts") {
                ForEach(Array(candidate.program.trainingDays.enumerated()), id: \.element.id) { index, day in
                    NavigationLink {
                        ExList {
                            TrainingProgramDays(program: candidate.program, library: workspace.store.library, onlyDay: day.id)
                        }.exListStyle().navigationTitle(day.name).navigationBarTitleDisplayMode(.inline)
                    } label: {
                        VStack(alignment: .leading, spacing: ExSpacing.small) {
                            Text("\(index + 1). \(day.name)").font(.exH3)
                            Text("\(day.slots.count) exercises").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                            Text(day.slots.prefix(3).map { workspace.store.library.exercise($0.exerciseID)?.name ?? $0.exerciseID.rawValue }.joined(separator: " · "))
                                .font(.exBody).foregroundStyle(Color.exTextSecondary)
                        }.padding(.vertical, ExSpacing.small)
                    }.accessibilityIdentifier("planSetup.day.\(index)")
                }
            }
            Section("Why this plan") {
                Text(candidate.proposal.summary).accessibilityIdentifier("planSetup.explanation")
                ForEach(Array(candidate.proposal.evidence.enumerated()), id: \.offset) { _, evidence in
                    VStack(alignment: .leading, spacing: ExSpacing.small) {
                        Text(evidence.claim).font(.exBodyMedium)
                        if let source = evidence.source { Text(source).font(.exCaption).foregroundStyle(Color.exTextSecondary) }
                        ForEach(evidence.caveats, id: \.self) { Text($0).font(.exCaption).foregroundStyle(Color.exTextSecondary) }
                    }.padding(.vertical, ExSpacing.small)
                }
                Text("Confidence: \(candidate.proposal.confidence.rawValue). Review how it fits you after training.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary)
            }
            Section("When to reconsider") { Text(candidate.proposal.falsifier) }
            Section {
                if let error = model.error {
                    Text(error).foregroundStyle(Color.exError).accessibilityIdentifier("planSetup.error")
                }
                if model.canSave {
                    Text("Saving accepts this suggestion. You can review or undo the decision in Suggestions. Following its schedule is a separate choice.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                } else {
                    Text(model.accepted ? "This plan is saved." : "Decision: \(AgentFormat.status(model.decisionStatus ?? .pending))")
                        .font(.exBodyMedium)
                    NavigationLink("Review or undo this decision") {
                        ProposalDetailView(workspace: workspace, proposalID: candidate.proposal.id, unit: unit)
                    }.accessibilityIdentifier("planSetup.decision")
                }
            }
        }.exListStyle()
        .exFooter {
            if model.canSave {
                VStack(alignment: .leading, spacing: ExSpacing.small) {
                    if let error = model.error {
                        Text(error).font(.exCaption).foregroundStyle(Color.exError)
                            .accessibilityIdentifier("planSetup.saveError")
                    }
                    Button("Save plan", systemImage: "checkmark") {
                        model.accept()
                        if model.accepted {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            Task { await workspace.synchronize() }
                        }
                    }.buttonStyle(ExActionStyle()).accessibilityIdentifier("planSetup.accept")
                }.padding(ExSpacing.page).background(Color.exBackground)
            }
        }
        .onChange(of: model.accepted) { _, _ in scroll.scrollTo("plan-top", anchor: .top) }
        }
    }
}
