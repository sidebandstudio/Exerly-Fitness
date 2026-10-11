import SwiftUI
import ExerlyCore

struct TrainingHostView: View {
    let accountID: String
    let unit: MassUnit
    let timeZone: TimeZone
    @EnvironmentObject private var account: AppAccountWorkspace
    @EnvironmentObject private var auth: AuthViewModel

    var body: some View {
        Group {
            if let workspace = account.training, workspace.accountID == accountID {
                TrainingView(store: workspace.store, unit: unit, timeZone: timeZone,
                             unreadableCount: workspace.unreadableCount, workspace: workspace)
                    .onChange(of: workspace.store.activeSession?.id) { _, _ in
                        Task { await workspace.synchronize() }
                    }
            } else if account.openingError != nil {
                ContentUnavailableView {
                    Label("Training could not open", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("Your saved data is still on this device. Keep Exerly installed and try again.")
                } actions: {
                    Button("Try again") { Task { await account.configure(auth.accountAPI) } }
                        .buttonStyle(.borderedProminent).tint(Color.exActionFill)
                }
            } else {
                ProgressView("Opening training…")
            }
        }
    }
}

struct TrainingView: View {
    let store: TrainingStore
    let unit: MassUnit
    let timeZone: TimeZone
    let unreadableCount: Int
    var workspace: TrainingWorkspace?
    @State private var browsing = false
    @State private var previewing = false
    @State private var buildingPlan = false
    @State private var finished: FinishedWorkout?
    @State private var error: String?

    var body: some View {
        content
            .animation(.snappy, value: store.activeSession?.id)
            .sensoryFeedback(.impact(weight: .medium), trigger: store.activeSession?.id) { old, new in old == nil && new != nil }
            .scrollContentBackground(.hidden)
            .background(Color.exBackground)
            .sheet(isPresented: $browsing) {
                ExercisePickerView(store: store, onSelect: nil, gym: workspace?.gyms.active, unit: unit)
            }
            .sheet(isPresented: $previewing) {
                if let workspace { PlannedWorkoutView(workspace: workspace, unit: unit, timeZone: timeZone) }
            }
            .sheet(isPresented: $buildingPlan) {
                if let workspace { TrainingPlanSetupView(workspace: workspace, unit: unit) }
            }
            .sheet(item: $finished) { done in
                WorkoutFinishSummary(result: done.result, library: store.library, unit: unit)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let session = store.activeSession {
            ActiveWorkoutView(store: store, session: session, unit: unit, gym: workspace?.gyms.active,
                              targets: workspace?.slotTargets(for: session) ?? [:],
                              program: session.program.flatMap { workspace?.programs.program($0.programID) },
                              onFinish: { finished = FinishedWorkout(result: $0) })
                .transition(.opacity)
        } else {
            home.transition(.opacity)
        }
    }

    private var home: some View {
        ExScreen {
            hero
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.exLabel).foregroundStyle(Color.exError)
                    .accessibilityIdentifier("training.startError")
            }
            recent
            tools
            if unreadableCount > 0 {
                Label("Some saved entries could not be read. They have been kept for recovery. Contact support before reinstalling.",
                      systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exWarning)
            }
        }
        .navigationTitle("Training").navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Today

    /// The latest workout saved today, if any.
    private var finishedToday: WorkoutSession? {
        let today = LocalDate(Date(), in: timeZone)
        return store.history.sessions.last { $0.endedAt != nil && $0.localDate == today }
    }

    /// The program's next day, when there is one to start.
    private var nextDayName: String? {
        guard let workspace, let program = workspace.programs.active,
              let position = ProgramSchedule.next(for: program, in: store.history),
              workspace.nextWorkout(bodyweight: workspace.latestBodyweight, unit: unit) != nil else { return nil }
        return position.day.name
    }

    @ViewBuilder
    private var hero: some View {
        if let done = finishedToday {
            // Like Today: what's done comes first, the next workout second.
            TrainingDoneCard(session: done, summary: store.summary(of: done), unit: unit, next: nextDayName,
                             start: startToday, preview: { previewing = true }, empty: startEmpty)
        } else if let workspace, let program = workspace.programs.active {
            if let position = ProgramSchedule.next(for: program, in: store.history),
               let plan = workspace.nextWorkout(bodyweight: workspace.latestBodyweight, unit: unit) {
                TodayWorkoutCard(plan: plan, position: position, program: program, library: store.library,
                                 restPolicy: store.restPolicy, unit: unit, start: startToday,
                                 preview: { previewing = true }, empty: startEmpty)
            } else {
                TrainingPromptCard(eyebrow: program.name, title: "Program complete",
                                   message: "Every cycle is done. Duplicate it in Programs to run it again with separate progress, or choose another.") {
                    NavigationLink {
                        TrainingProgramsView(workspace: workspace, unit: unit, timeZone: timeZone)
                    } label: { Text("Choose what's next") }
                        .buttonStyle(ExActionStyle())
                } empty: { startEmpty() }
            }
        } else if workspace != nil {
            TrainingPromptCard(eyebrow: "Your training", title: "Train with a plan",
                               message: "Tell us your goal, time and equipment. Get a program that picks your weights and progresses them for you.") {
                Button("Build my plan") { buildingPlan = true }
                    .buttonStyle(ExActionStyle()).accessibilityIdentifier("planSetup.open")
            } empty: { startEmpty() }
        } else {
            TrainingPromptCard(eyebrow: "Your training", title: "Ready when you are",
                               message: "Add exercises as you go. Your last sets are ready to log again.") {
                EmptyView()
            } empty: { startEmpty() }
        }
    }

    private func startToday() {
        guard let workspace else { return }
        do {
            if try !workspace.startNextWorkout(timeZone: timeZone, unit: unit) {
                error = "Your program has no workout left. Choose another in Programs."
            } else { error = nil }
        } catch { self.error = "The workout could not start. Your saved program is still here. Try again." }
    }

    private func startEmpty() {
        do {
            try store.startSession(name: TrainingFormat.emptyWorkoutName(at: Date(), timeZone: timeZone),
                                   bodyweight: workspace?.latestBodyweight, timeZone: timeZone)
            error = nil
        } catch { self.error = TrainingFormat.error(error) }
    }

    // MARK: Recent

    @ViewBuilder
    private var recent: some View {
        let sessions = Array(store.history.sessions.suffix(3).reversed())
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: ExSpacing.small) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Recent").font(.exH3).foregroundStyle(Color.exTextPrimary).accessibilityAddTraits(.isHeader)
                    Spacer()
                    NavigationLink("All workouts") { WorkoutHistoryView(store: store, unit: unit) }
                        .font(.exLabel.weight(.semibold)).foregroundStyle(Color.exPrimaryText)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("training.history")
                }
                Text(thisWeek).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    .accessibilityIdentifier("training.thisWeek")
                TrainingGroupedRows {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider().overlay(Color.exBorder.opacity(0.4)).padding(.leading, ExSpacing.content) }
                        NavigationLink {
                            WorkoutDetailView(store: store, sessionID: session.id, unit: unit)
                        } label: { RecentWorkoutRow(session: session, summary: store.summary(of: session), unit: unit) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// "This week: 2 workouts · 31 sets", counted as Progress counts its weeks.
    private var thisWeek: String {
        let today = LocalDate(Date(), in: timeZone)
        let week = TrainingInsights.weeks(store.history, from: today, through: today,
                                          firstWeekday: TrainingInsightsModel.firstWeekday).last
        guard let week, week.sessions > 0 else { return "This week: no workouts yet" }
        return "This week: \(InsightFormat.workouts(week.sessions)) · \(InsightFormat.sets(week.sets)) sets"
    }

    // MARK: Tools

    private var tools: some View {
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            Text("Plan and tools").font(.exH3).foregroundStyle(Color.exTextPrimary).accessibilityAddTraits(.isHeader)
            TrainingGroupedRows {
                if let workspace {
                    NavigationLink {
                        TrainingProgramsView(workspace: workspace, unit: unit, timeZone: timeZone)
                    } label: { TrainingToolLabel(title: "Programs", icon: "square.stack.3d.up", detail: workspace.programs.active?.name ?? "None yet") }
                        .accessibilityIdentifier("programs.open")
                    divider
                    NavigationLink {
                        TrainingGymsView(workspace: workspace, unit: unit)
                    } label: { TrainingToolLabel(title: "Gyms & equipment", icon: "building.2", detail: workspace.gyms.active?.name ?? "Any gym") }
                        .accessibilityIdentifier("gyms.open")
                    divider
                }
                Button { browsing = true } label: { TrainingToolLabel(title: "Exercise library", icon: "dumbbell") }
                    .accessibilityLabel("Exercise library")
                if let workspace {
                    divider
                    NavigationLink {
                        TrainingObservationsView(workspace: workspace, unit: unit, timeZone: timeZone)
                    } label: { TrainingToolLabel(title: "Checks & suggestions", icon: "checklist", detail: "Entries to double-check and coach ideas") }
                        .accessibilityIdentifier("observations.open")
                    divider
                    let pending = workspace.agent.proposals.filter { $0.status == .pending }.count
                    NavigationLink {
                        AgentReviewView(workspace: workspace, unit: unit)
                    } label: { TrainingToolLabel(title: "Suggestions", icon: "tray", detail: pending == 0 ? "Up to date" : "\(pending) to review") }
                        .accessibilityIdentifier("suggestions.open")
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var divider: some View {
        Divider().overlay(Color.exBorder.opacity(0.4)).padding(.leading, 56)
    }
}

/// Rows grouped on one surface, like a compact settings list.
struct TrainingGroupedRows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.exSurface1, in: RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous)
                    .strokeBorder(Color.exBorder.opacity(0.5), lineWidth: 0.5)
            }
    }
}

private struct RecentWorkoutRow: View {
    let session: WorkoutSession
    let summary: WorkoutSummary
    let unit: MassUnit
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.tight))
            : AnyLayout(HStackLayout(spacing: ExSpacing.item))
        HStack(spacing: ExSpacing.item) {
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(TrainingFormat.title(of: session).name).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    // Redrawn as time passes, so "3 minutes ago" stays true.
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        Text("\(session.startedAt.formatted(.relative(presentation: .named))) · \(TrainingFormat.minutes(summary.duration))")
                            .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    }
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: ExSpacing.small) }
                VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                    Text(summary.workingSets == 1 ? "1 set" : "\(summary.workingSets) sets")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(Color.exTextPrimary)
                    Text(TrainingFormat.volume(summary.tonnage, unit: unit))
                        .font(.system(.caption, design: .rounded)).foregroundStyle(Color.exTextSecondary)
                }
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.exTextMuted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, ExSpacing.content).padding(.vertical, 10)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct FinishedWorkout: Identifiable {
    let result: TrainingStore.FinishedSession
    var id: UUID { result.session.id }
}

struct ExercisePickerView: View {
    let store: TrainingStore
    let onSelect: ((ExerlyCore.Exercise) throws -> Void)?
    var gym: GymProfile?
    /// Browsing only: each exercise's page shows your history in this unit.
    var unit: MassUnit?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var muscle: Muscle?
    @State private var error: String?
    @State private var useGym = true

    var body: some View {
        NavigationStack {
            ExList {
                Section {
                    VStack(alignment: .leading, spacing: ExSpacing.small) {
                        ExEyebrow("Exercise library", color: .exPrimaryText)
                        Text(onSelect == nil ? "Know your movements" : "Choose your next exercise").font(.exH2)
                    }.padding(.vertical, ExSpacing.small)
                }.listRowBackground(Color.clear)
                Section {
                    if let gym {
                        VStack(alignment: .leading, spacing: ExSpacing.small) {
                            Text(gym.name).font(.exLabel).foregroundStyle(Color.exTextSecondary)
                            ExChoiceChips(values: [true, false], selection: $useGym) { $0 ? "At this gym" : "All exercises" }
                        }.padding(.vertical, ExSpacing.small)
                    }
                    Picker("Target muscle", selection: $muscle) {
                        Text("All muscles").tag(Muscle?.none)
                        ForEach(Muscle.allCases, id: \.self) { Text($0.name).tag(Optional($0)) }
                    }
                }
                let matches = store.library.search(query, muscle: muscle).filter { !useGym || gym?.allows($0) != false }
                if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(matches) { exercise in
                        if onSelect != nil {
                            Button {
                                do { try onSelect?(exercise); dismiss() } catch { self.error = TrainingFormat.error(error) }
                            } label: { ExerciseLibraryRow(exercise: exercise) }
                            .foregroundStyle(.primary)
                            .accessibilityLabel("Add \(exercise.name)")
                        } else if let unit {
                            NavigationLink {
                                ExerciseGuideView(exercise: exercise, store: store, unit: unit)
                            } label: { ExerciseLibraryRow(exercise: exercise) }
                        }
                    }
                }
            }
            .exListStyle()
            .searchable(text: $query, prompt: "Search exercises")
            .modifier(ExerciseSearchToolbar())
            .onSubmit(of: .search) {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            .navigationTitle(onSelect == nil ? "Exercises" : "Add exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.accessibilityIdentifier("training.exerciseClose")
                }
            }
            .alert("Could not add exercise", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}

private struct ExerciseSearchToolbar: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.1, *) {
            content.searchPresentationToolbarBehavior(.avoidHidingContent)
        } else {
            content
        }
    }
}

private struct ExerciseLibraryRow: View {
    let exercise: ExerlyCore.Exercise
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(exercise.name).font(.body.weight(.medium))
            Text(exercise.targetMuscles.map(\.name).joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary)
            Text(exercise.equipment.map { TrainingFormat.words($0.rawValue) }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 5).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}
