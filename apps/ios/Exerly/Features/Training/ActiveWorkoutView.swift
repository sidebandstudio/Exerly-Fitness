import SwiftUI
import ExerlyCore

private struct SetEditorTarget: Identifiable {
    let performedID: UUID
    let exercise: ExerlyCore.Exercise
    let set: PerformedSet
    let number: Int
    var id: UUID { self.set.id }
}

/// The workout in progress. Every set is a row of the exercise's grid:
/// prefilled from the plan or the last session, completed with one tap on ✓,
/// and edited in place with the training keypad.
struct ActiveWorkoutView: View {
    let store: TrainingStore
    let session: WorkoutSession
    let unit: MassUnit
    var gym: GymProfile?
    /// Program targets by slot ID, for the "3 × 5–8 · 2 RIR" line.
    var targets: [UUID: SlotTarget] = [:]
    /// The program the session is a day of, to say whether finishing does that day.
    var program: Program?
    var onFinish: (TrainingStore.FinishedSession) -> Void = { _ in }
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var focus: TrainingCell?
    @State private var adding = false
    @State private var replacing: UUID?
    @State private var removing: PerformedExercise?
    @State private var noting: UUID?
    @State private var noteDraft = ""
    @State private var editing: SetEditorTarget?
    @State private var guiding: ExerlyCore.Exercise?
    @State private var details = false
    @State private var finishing = false
    @State private var discarding = false
    @State private var error: String?
    @State private var nudge = 0

    var body: some View {
        let summary = store.summary(of: session)
        dialogs(sheets(chrome(workoutList(summary: summary), summary: summary)))
    }

    private func workoutList(summary: WorkoutSummary) -> some View {
        let next = session.nextSet(after: nil)?.setID
        return ScrollViewReader { proxy in
            List {
                if typeSize.isAccessibilitySize {
                    Section { WorkoutStatusStrip(session: session, summary: summary, unit: unit) }
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").font(.exLabel).foregroundStyle(Color.exError)
                            .accessibilityIdentifier("training.error")
                    }
                    .listRowBackground(Color.exSurface1)
                }
                ForEach(Array(session.exercises.enumerated()), id: \.element.id) { index, performed in
                    if let exercise = store.library.exercise(performed.exerciseID) {
                        exerciseSection(performed, exercise: exercise, index: index, next: next, proxy: proxy)
                    }
                }
                Section {
                    Button { adding = true } label: {
                        Label("Add exercise", systemImage: "plus").font(.exBodyMedium).foregroundStyle(Color.exPrimaryText)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier("training.addExercise")
                }
                .listRowBackground(Color.exPrimary.opacity(0.1))
            }
            .listStyle(.insetGrouped).listSectionSpacing(ExSpacing.content)
            .scrollContentBackground(.hidden).background(Color.exBackground)
            .environment(\.defaultMinListRowHeight, 40)
            .tint(Color.exPrimaryText)
            .exScrollEdges()
            .contentMargins(.top, ExSpacing.small, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !typeSize.isAccessibilitySize {
                WorkoutStatusStrip(session: session, summary: summary, unit: unit)
                    .background(Color.exBackground)
            }
        }
        // Below the sets, not over them: run 6 found the next exercise under it.
        .exFooter {
            if let timer = store.restTimer, focus == nil {
                RestTimerBar(timer: timer, adjust: { seconds in save { try store.extendRest(by: seconds) } },
                             skip: { withAnimation(.snappy) { save { try store.skipRest() } } })
                    .background(Color.exBackground)
            }
        }
    }

    private func chrome<Content: View>(_ content: Content, summary: WorkoutSummary) -> some View {
        content
        .animation(.snappy, value: store.restTimer)
        .sensoryFeedback(.success, trigger: summary.completedSets) { old, new in new > old }
        .sensoryFeedback(.warning, trigger: nudge)
        .navigationTitle(session.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Workout details", systemImage: "square.and.pencil") { details = true }
                    Button("Add exercise", systemImage: "plus") { adding = true }
                    Divider()
                    Button("Discard workout", systemImage: "trash", role: .destructive) { discarding = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Workout options")
                .accessibilityIdentifier("training.menu")
            }
            ToolbarItem(placement: .principal) {
                let title = TrainingFormat.title(of: session)
                VStack(spacing: 0) {
                    Text(title.name).font(.headline).foregroundStyle(Color.exTextPrimary)
                    if let program = title.program {
                        Text(program).font(.caption).foregroundStyle(Color.exTextSecondary)
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // A value still being typed is saved first, as completing a set does.
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    focus = nil
                    // With every set done there's nothing to warn about.
                    if store.activeSession?.isEverySetCompleted == true { finish() } else { finishing = true }
                } label: {
                    Text("Finish").fontWeight(.semibold).foregroundStyle(.white)
                }
                    .buttonStyle(.glassProminent).tint(Color.exActionFill)
                    .accessibilityIdentifier("training.finish")
                    // Attached to the button so its popover points at Finish.
                    .confirmationDialog("Finish this workout?", isPresented: $finishing, titleVisibility: .visible) {
                        Button("Save workout") { finish() }
                        // No cancel role: a popover leaves those out, and this one should show.
                        Button("Cancel") {}.accessibilityIdentifier("training.cancelFinish")
                    } message: {
                        Text(finishMessage(summary))
                    }
            }
        }
    }

    private func sheets<Content: View>(_ content: Content) -> some View {
        content
        .sheet(isPresented: $adding) {
            ExercisePickerView(store: store, onSelect: { exercise in try store.addExercise(exercise.id) }, gym: gym)
        }
        .sheet(item: Binding(get: { replacing.map(ReplaceTarget.init) }, set: { replacing = $0?.id })) { target in
            ExercisePickerView(store: store, onSelect: { exercise in try store.replaceExercise(target.id, with: exercise.id) }, gym: gym)
        }
        .sheet(item: $editing) { target in
            TrainingSetEditor(exercise: target.exercise, original: target.set, number: target.number, unit: unit) { updated, propagate in
                try store.updateSet(updated, in: target.performedID, propagate: propagate)
            }
        }
        .sheet(isPresented: $details) { WorkoutNotesView(store: store, session: session, unit: unit) }
        .sheet(item: $guiding) { exercise in
            NavigationStack {
                ExerciseGuideView(exercise: exercise, store: store, unit: unit)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { guiding = nil }
                                .accessibilityLabel("Back to workout")
                                .accessibilityIdentifier("training.guide.close")
                        }
                    }
            }
        }
    }

    private func dialogs<Content: View>(_ content: Content) -> some View {
        content
        .alert("Exercise note", isPresented: Binding(get: { noting != nil }, set: { if !$0 { noting = nil } })) {
            TextField("Note", text: $noteDraft)
            Button("Save") { if let id = noting { saveNote(noteDraft, for: id) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove \(removing.flatMap { store.library.exercise($0.exerciseID)?.name } ?? "this exercise")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove exercise", role: .destructive) {
                if let performed = removing { withAnimation { save { try store.removeExercise(performed.id) } } }
            }
        } message: { Text("Its sets in this workout are removed, including completed ones.") }
        .confirmationDialog("Discard this workout?", isPresented: $discarding, titleVisibility: .visible) {
            Button("Discard workout", role: .destructive) { save { try store.discardSession() } }
        } message: { Text("This removes the workout and all of its sets from this device.") }
    }

    // MARK: Exercise cards

    @ViewBuilder
    private func exerciseSection(_ performed: PerformedExercise, exercise: ExerlyCore.Exercise, index: Int, next: UUID?,
                                 proxy: ScrollViewProxy) -> some View {
        let previous = store.previousSets(for: performed.id)
        Section {
            exerciseHeader(performed, exercise: exercise, index: index)
                .listRowSeparator(.hidden)
            if !typeSize.isAccessibilitySize {
                SetGridHeader(metric: exercise.metric, unit: unit)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
            }
            ForEach(Array(performed.sets.enumerated()), id: \.element.id) { setIndex, set in
                TrainingSetRow(set: set, number: setIndex + 1, exercise: exercise, unit: unit,
                               previous: previous.indices.contains(setIndex) ? previous[setIndex] : nil,
                               isNext: set.id == next, focus: $focus,
                               actions: actions(for: set, number: setIndex + 1, performed: performed, exercise: exercise, proxy: proxy))
                    .id(set.id)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                    .listRowBackground(set.isCompleted ? Color.exPrimary.opacity(0.12) : Color.exSurface1)
                    .swipeActions(edge: .trailing) {
                        Button("Delete set", systemImage: "trash", role: .destructive) {
                            withAnimation { save { try store.removeSet(set.id) } }
                        }
                    }
            }
            Button {
                withAnimation(.snappy) { save { try store.addSet(to: performed.id) } }
            } label: {
                Label("Add set", systemImage: "plus").font(.exLabel).foregroundStyle(Color.exPrimaryText)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .listRowSeparator(.hidden)
            .accessibilityLabel("Add set to \(exercise.name)")
            .accessibilityIdentifier("training.addSet.\(exercise.id.rawValue)")
        }
        .listRowBackground(Color.exSurface1)
    }

    private func exerciseHeader(_ performed: PerformedExercise, exercise: ExerlyCore.Exercise, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ExSpacing.small) {
            VStack(alignment: .leading, spacing: 3) {
                Button { focus = nil; guiding = exercise } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(exercise.name).font(.exH3).foregroundStyle(Color.exTextPrimary).multilineTextAlignment(.leading)
                        Image(systemName: "info.circle").font(.footnote).foregroundStyle(Color.exTextMuted).accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Guide to \(exercise.name)")
                .accessibilityIdentifier("training.guide.\(exercise.id.rawValue)")
                let target = performed.slotID.flatMap { targets[$0] }
                Text(target.map { TrainingFormat.compactTarget($0, exercise: exercise) }
                     ?? exercise.targetMuscles.prefix(2).map(\.name).joined(separator: " · "))
                    .font(.exLabel).foregroundStyle(target == nil ? Color.exTextSecondary : Color.exPrimaryText)
                if !performed.notes.isEmpty {
                    Text(performed.notes).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("How to do it", systemImage: "book") { guiding = exercise }
                Button(performed.notes.isEmpty ? "Add note" : "Edit note", systemImage: "note.text") {
                    noteDraft = performed.notes; noting = performed.id
                }
                Button("Replace exercise", systemImage: "arrow.triangle.2.circlepath") { replacing = performed.id }
                    .disabled(performed.sets.contains(where: \.isCompleted))
                if index > 0 {
                    Button("Move up", systemImage: "arrow.up") { withAnimation { save { try store.moveExercise(performed.id, to: index - 1) } } }
                }
                if index < session.exercises.count - 1 {
                    Button("Move down", systemImage: "arrow.down") { withAnimation { save { try store.moveExercise(performed.id, to: index + 1) } } }
                }
                Divider()
                Button("Remove exercise", systemImage: "trash", role: .destructive) { removing = performed }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(Color.exPrimaryText)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Options for \(exercise.name)")
            .accessibilityIdentifier("training.exerciseMenu.\(exercise.id.rawValue)")
        }
        .padding(.top, ExSpacing.tight)
    }

    // MARK: Set actions

    private func actions(for set: PerformedSet, number: Int, performed: PerformedExercise, exercise: ExerlyCore.Exercise,
                         proxy: ScrollViewProxy) -> SetRowActions {
        let fields = SetGrid.fields(exercise.metric)
        return SetRowActions(
            commit: { field, text in commit(field, text: text, setID: set.id, performedID: performed.id, exercise: exercise) },
            step: { field, text, up in step(field, text: text, up: up, exercise: exercise) },
            stepLabel: { field in stepLabel(field, exercise: exercise) },
            next: { field in
                guard let target = nextCell(after: TrainingCell(setID: set.id, field: field), in: performed, fields: fields) else { return nil }
                return {
                    focus = target
                    withAnimation { proxy.scrollTo(target.setID, anchor: .center) }
                }
            },
            complete: { toggle(set.id, performedID: performed.id, exercise: exercise) },
            usePrevious: {
                let previous = store.previousSets(for: performed.id)
                guard let index = performed.sets.firstIndex(where: { $0.id == set.id }), previous.indices.contains(index),
                      var current = store.activeSession?.set(set.id)?.set, !current.isCompleted else { return }
                let source = previous[index]
                current.efforts = current.kind.allowsContinuations ? source.efforts : [source.primary]
                save { try store.updateSet(current, in: performed.id) }
            },
            changeKind: { kind in
                guard var current = store.activeSession?.set(set.id)?.set else { return }
                guard kind.allowsContinuations || current.efforts.count == 1 else {
                    error = "Remove this set's drops in More options before changing its type."
                    return
                }
                current.kind = kind
                save { try store.updateSet(current, in: performed.id) }
            },
            moreOptions: {
                focus = nil
                if let current = store.activeSession?.set(set.id)?.set {
                    editing = SetEditorTarget(performedID: performed.id, exercise: exercise, set: current, number: number)
                }
            },
            delete: { withAnimation { save { try store.removeSet(set.id) } } })
    }

    private func nextCell(after cell: TrainingCell, in performed: PerformedExercise, fields: [TrainingCell.Field]) -> TrainingCell? {
        let cells = performed.sets.flatMap { set in fields.map { TrainingCell(setID: set.id, field: $0) } }
        guard let index = cells.firstIndex(of: cell), index + 1 < cells.count else { return nil }
        return cells[index + 1]
    }

    /// Completes a set with the values shown, or reopens a completed one. A
    /// value still being typed is saved first. A set missing a required value
    /// opens that value instead.
    private func toggle(_ setID: UUID, performedID: UUID, exercise: ExerlyCore.Exercise) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        focus = nil
        guard let set = store.activeSession?.set(setID)?.set else { return }
        if set.isCompleted {
            withAnimation(.snappy) { save { try store.reopenSet(setID) } }
        } else if set.isLoggable(for: exercise) {
            withAnimation(.snappy) { save { try store.completeSet(setID) } }
        } else {
            nudge += 1
            focus = SetGrid.missing(set, exercise: exercise).map { TrainingCell(setID: setID, field: $0) }
        }
    }

    private func commit(_ field: TrainingCell.Field, text: String, setID: UUID, performedID: UUID, exercise: ExerlyCore.Exercise) {
        guard var set = store.activeSession?.set(setID)?.set else { return }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "+", with: "")
        var effort = set.primary
        switch field {
        case .load:
            guard input.isEmpty || TrainingInput.number(input) != nil else { return reject("Enter a weight, like 62.5.") }
            effort.load = TrainingInput.number(input).map { Mass($0, unit) }
        case .reps:
            guard input.isEmpty || TrainingInput.reps(input) != nil else { return reject("Enter a whole number of reps.") }
            effort.reps = TrainingInput.reps(input)
        case .rir:
            guard input.isEmpty || TrainingInput.number(input) != nil else { return reject("Enter reps in reserve from 0 to 6.") }
            // 6 means "6 or more", so a larger number is recorded as 6.
            set.rir = TrainingInput.number(input).map { min(6, $0) }
        case .duration:
            guard input.isEmpty || TrainingInput.number(input) != nil else { return reject("Enter a time in seconds.") }
            effort.duration = TrainingInput.number(input)
        case .distance:
            guard input.isEmpty || TrainingInput.number(input) != nil else { return reject("Enter a distance in metres.") }
            effort.distance = TrainingInput.number(input)
        }
        set.primary = effort
        if set.isCompleted && !set.isLoggable(for: exercise) {
            return reject("A completed set needs its values. Reopen it before clearing them.")
        }
        // Later sets still holding the old value follow the change.
        save { try store.updateSet(set, in: performedID, propagate: true) }
    }

    private func reject(_ message: String) {
        error = message
        nudge += 1
    }

    private func increments(for exercise: ExerlyCore.Exercise) -> LoadIncrements {
        gym?.increments(for: exercise) ?? .defaults(for: exercise)
    }

    private func step(_ field: TrainingCell.Field, text: String, up: Bool, exercise: ExerlyCore.Exercise) -> String? {
        let input = text.replacingOccurrences(of: "+", with: "")
        let delta: Double = up ? 1 : -1
        switch field {
        case .load:
            return TrainingFormat.load(increments(for: exercise).stepped(TrainingInput.number(input) ?? 0, up: up, in: unit))
        case .reps:
            return String(max(0, (TrainingInput.reps(input) ?? 0) + (up ? 1 : -1)))
        case .rir:
            let value = min(6, max(0, (TrainingInput.number(input)?.rounded() ?? 2) + delta))
            return value >= 6 ? "6" : TrainingFormat.number(value)
        case .duration:
            return TrainingFormat.number(max(0, ((TrainingInput.number(input) ?? 0) / 5).rounded() * 5 + 5 * delta))
        case .distance:
            return TrainingFormat.number(max(0, ((TrainingInput.number(input) ?? 0) / 10).rounded() * 10 + 10 * delta))
        }
    }

    private func stepLabel(_ field: TrainingCell.Field, exercise: ExerlyCore.Exercise) -> String {
        switch field {
        case .load:
            let increments = increments(for: exercise)
            if increments.available?.isEmpty == false { return "Gym weights" }
            return "\(TrainingFormat.number(increments.step(in: unit))) \(TrainingFormat.unitSymbol(unit))"
        case .reps: return "1 rep"
        case .rir: return "1 RIR"
        case .duration: return "5 s"
        case .distance: return "10 m"
        }
    }

    private func saveNote(_ note: String, for performedID: UUID) {
        save {
            try store.updateActiveSession { session in
                if let index = session.exercises.firstIndex(where: { $0.id == performedID }) {
                    session.exercises[index].notes = note.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
    }

    /// How many sets are done, and for a program day whether it counts as
    /// done (see `ProgramSchedule.completes`) or stays next.
    private func finishMessage(_ summary: WorkoutSummary) -> String {
        let sets = "\(summary.completedSets) of \(summary.totalSets) sets \(summary.completedSets == 1 ? "is" : "are") done"
        let removed = "Sets you didn't complete are removed."
        guard let program, let live = store.activeSession else { return "\(sets). \(removed)" }
        let day = TrainingFormat.title(of: live).name
        return ProgramSchedule.completes(live, of: program)
            ? "\(sets), so \(day) counts as done. \(removed)"
            : "\(sets), less than half, so \(day) stays your next workout. \(removed)"
    }

    private func finish() {
        do {
            let finished = try store.finishSession()
            error = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onFinish(finished)
        } catch { self.error = TrainingFormat.error(error) }
    }

    private func save<T>(_ action: () throws -> T) {
        do { _ = try action(); error = nil } catch {
            self.error = TrainingFormat.error(error)
            nudge += 1
        }
    }
}

private struct ReplaceTarget: Identifiable {
    let id: UUID
}

private struct WorkoutNotesView: View {
    let store: TrainingStore
    let session: WorkoutSession
    let unit: MassUnit
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var notes = ""
    @State private var weight = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ExScreen {
                ExCard(accent: true) {
                    ExEyebrow("This session", color: .exPrimaryText)
                    TextField("Workout name", text: $name).font(.exH2).accessibilityIdentifier("training.name")
                    NutritionNumberInput(title: "Bodyweight (\(unit == .kilograms ? "kg" : "lb"), optional)", text: $weight)
                    Text("Filled in from your latest weigh-in. Used for bodyweight exercise volume.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
                ExCard {
                    ExSectionHeading("Workout notes")
                    TextField("Workout notes", text: $notes, axis: .vertical).lineLimit(3...8)
                }
                if let error { Text(error).foregroundStyle(Color.exError) }
            }
            .navigationTitle("Workout details").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.accessibilityIdentifier("training.saveDetails")
                }
            }
            .onAppear {
                name = session.name; notes = session.notes
                weight = session.bodyweight.map { TrainingFormat.load($0.value(in: unit)) } ?? ""
            }
        }
    }

    private func save() {
        let mass: Mass?
        if weight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { mass = nil } else if let value = TrainingInput.number(weight), value > 0 { mass = Mass(value, unit) } else { error = "Enter a bodyweight greater than zero, or leave it empty."; return }
        do {
            try store.updateActiveSession {
                $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Workout" : name
                $0.notes = notes
                // Keep the exact saved weight unless the shown number was edited.
                if session.bodyweight.map({ TrainingFormat.load($0.value(in: unit)) }) != weight { $0.bodyweight = mass }
            }
            dismiss()
        } catch { self.error = TrainingFormat.error(error) }
    }
}
