import SwiftUI
import ExerlyCore

/// The Train tab's hero: what to do today, with Start one tap away.
struct TodayWorkoutCard: View {
    let plan: WorkoutPlan
    let position: ProgramSchedule.Position
    let program: Program
    let library: ExerlyCore.ExerciseLibrary
    let restPolicy: RestPolicy
    let unit: MassUnit
    let start: () -> Void
    let preview: () -> Void
    let empty: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Four, so Preview and Empty workout stay above an SE's tab bar (run 6).
    private let shown = 4

    var body: some View {
        TrainingHeroSurface {
            let header = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.small))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
            header {
                ExEyebrow(position.isDeload ? "Today · Deload" : "Today's workout", color: .exPrimaryText)
                if !typeSize.isAccessibilitySize { Spacer(minLength: ExSpacing.small) }
                Text("Cycle \(position.cycle + 1) of \(program.cycles)")
                    .font(.exCaption.weight(.medium)).foregroundStyle(Color.exTextSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.exPrimary.opacity(0.12), in: Capsule())
            }
            VStack(alignment: .leading, spacing: ExSpacing.tight) {
                Text(position.day.name).font(.exH1).foregroundStyle(Color.exTextPrimary)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("training.todayName")
                Text("\(program.name) · \(details)")
                    .font(.exLabel).foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(Array(plan.exercises.prefix(shown).enumerated()), id: \.offset) { index, planned in
                    if index > 0 { Divider().overlay(Color.exBorder.opacity(0.35)) }
                    exerciseRow(planned)
                }
                if plan.exercises.count > shown {
                    Divider().overlay(Color.exBorder.opacity(0.35))
                    Text("+\(plan.exercises.count - shown) more").font(.exLabel).foregroundStyle(Color.exTextSecondary)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                }
            }
            Button(action: start) {
                Label("Start workout", systemImage: "play.fill").font(.exBodyMedium.weight(.semibold))
            }
            .buttonStyle(ExActionStyle())
            .accessibilityIdentifier("training.startToday")
            .accessibilityHint("Starts \(position.day.name) with your planned weights")
            secondaryActions
        }
    }

    private var details: String {
        let minutes = TrainingFormat.minutes(plan.estimatedDuration(library: library, policy: restPolicy))
        let count = plan.exercises.count == 1 ? "1 exercise" : "\(plan.exercises.count) exercises"
        return "\(count) · about \(minutes)"
    }

    private func exerciseRow(_ planned: ExerlyCore.PlannedExercise) -> some View {
        let exercise = library.exercise(planned.exerciseID)
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: ExSpacing.small))
        let load = planned.recommendation.sets.first?.effort.load
        return layout {
            Text(exercise?.name ?? TrainingFormat.words(planned.exerciseID.rawValue))
                .font(.exBody).foregroundStyle(Color.exTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !typeSize.isAccessibilitySize { Spacer(minLength: ExSpacing.small) }
            HStack(spacing: ExSpacing.small) {
                Text(setsAndReps(planned, exercise: exercise)).foregroundStyle(Color.exTextSecondary)
                if let load {
                    let sign = exercise?.metric == .bodyweightReps ? "+" : exercise?.metric == .assistedReps ? "−" : ""
                    Text(sign + TrainingFormat.mass(load, unit: unit)).foregroundStyle(Color.exPrimaryText)
                }
            }
            .font(.system(.subheadline, design: .rounded, weight: .medium))
            .fixedSize()
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func setsAndReps(_ planned: ExerlyCore.PlannedExercise, exercise: ExerlyCore.Exercise?) -> String {
        let target = planned.target
        guard exercise?.metric.tracksReps == true else { return target.sets == 1 ? "1 set" : "\(target.sets) sets" }
        return target.minReps == target.maxReps ? "\(target.sets) × \(target.minReps)" : "\(target.sets) × \(target.minReps)–\(target.maxReps)"
    }

    private var secondaryActions: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: ExSpacing.content))
        return layout {
            Button(action: preview) { Label("Preview", systemImage: "list.bullet.rectangle") }
                .accessibilityIdentifier("program.nextWorkout")
                .accessibilityHint("Shows the targets and how they were chosen")
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Button(action: empty) { Label("Empty workout", systemImage: "plus") }
                .accessibilityIdentifier("training.start")
        }
        .buttonStyle(TrainingTextButtonStyle())
    }
}

/// The Train tab's hero once a workout is saved today, as Today shows it:
/// what was done, with the program's next workout one step behind.
struct TrainingDoneCard: View {
    let session: WorkoutSession
    let summary: WorkoutSummary
    let unit: MassUnit
    /// The program's next day, if there is one.
    let next: String?
    let start: () -> Void
    let preview: () -> Void
    let empty: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let title = TrainingFormat.title(of: session)
        TrainingHeroSurface {
            HStack(spacing: ExSpacing.small) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.exSuccess).accessibilityHidden(true)
                ExEyebrow("Workout done", color: .exPrimaryText)
            }
            VStack(alignment: .leading, spacing: ExSpacing.tight) {
                Text(title.name).font(.exH1).foregroundStyle(Color.exTextPrimary)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("training.doneName")
                if let program = title.program { Text(program).font(.exLabel).foregroundStyle(Color.exTextSecondary) }
                Text(details).font(.exLabel).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if let next {
                Button(action: start) { Label("Start next: \(next)", systemImage: "play.fill").font(.exBodyMedium.weight(.semibold)) }
                    .buttonStyle(ExActionStyle(secondary: true))
                    .accessibilityIdentifier("training.startNext")
                    .accessibilityHint("Starts the next workout in your program")
            }
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout(spacing: ExSpacing.content))
            layout {
                if next != nil {
                    Button(action: preview) { Label("Preview", systemImage: "list.bullet.rectangle") }
                        .accessibilityIdentifier("program.nextWorkout")
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                }
                Button(action: empty) { Label("Empty workout", systemImage: "plus") }
                    .accessibilityIdentifier("training.start")
            }
            .buttonStyle(TrainingTextButtonStyle())
        }
    }

    private var details: String {
        let sets = summary.workingSets == 1 ? "1 working set" : "\(summary.workingSets) working sets"
        return "\(sets) · \(TrainingFormat.volume(summary.tonnage, unit: unit)) · \(TrainingFormat.minutes(summary.duration))"
    }
}

/// The hero when there's no plan to follow, or the plan is finished.
struct TrainingPromptCard<Primary: View>: View {
    let eyebrow: String
    let title: String
    let message: String
    @ViewBuilder let primary: Primary
    let empty: () -> Void

    var body: some View {
        TrainingHeroSurface {
            ExEyebrow(eyebrow, color: .exPrimaryText)
            Text(title).font(.exH1).foregroundStyle(Color.exTextPrimary).accessibilityAddTraits(.isHeader)
            Text(message).font(.exBody).foregroundStyle(Color.exTextSecondary)
            primary
            Button(action: empty) { Label("Start an empty workout", systemImage: "plus") }
                .buttonStyle(TrainingTextButtonStyle())
                .accessibilityIdentifier("training.start")
        }
    }
}

/// A content surface with a purple-to-pink wash. Content, so no glass.
struct TrainingHeroSurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: ExSpacing.content) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background {
                ZStack {
                    Color.exSurface1
                    LinearGradient(colors: [Color.exPrimary.opacity(0.26), Color.exAccent.opacity(0.08), Color.exPrimary.opacity(0.02)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.exPrimary.opacity(0.3), lineWidth: 0.75)
            }
    }
}

struct TrainingTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.exLabel.weight(.semibold))
            .foregroundStyle(Color.exPrimaryText)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
