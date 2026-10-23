import SwiftUI
import ExerlyCore

/// Today's "Needs a look" row: shown while two devices' changes wait for a
/// decision. Opens the review.
struct ConflictBadgeRow: View {
    let workspace: TrainingWorkspace
    let unit: MassUnit
    let timeZone: TimeZone
    @Environment(\.dynamicTypeSize) private var typeSize

    private var count: Int { workspace.conflicts.unresolved.count }

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.conflicts.unresolved.isEmpty {
                NavigationLink {
                    ConflictReviewView(conflicts: workspace.conflicts, unit: unit, timeZone: timeZone)
                } label: {
                    HStack(spacing: ExSpacing.item) {
                        // At the largest sizes the count says it; the sentence took half the screen.
                        ExNavigationLabel(title: "Needs a look", icon: "arrow.triangle.2.circlepath",
                                          detail: typeSize.isAccessibilitySize ? nil : count == 1 ? "One change from your devices to check"
                                              : "\(count) changes from your devices to check", showChevron: false)
                        Text("\(count)").font(.exLabel.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, ExSpacing.small).frame(minWidth: 26, minHeight: 26)
                            .background(Color.exAccent, in: Capsule()).accessibilityHidden(true)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .foregroundStyle(Color.exTextMuted).accessibilityHidden(true)
                    }
                    .padding(.horizontal, ExSpacing.item)
                    .background(Color.exAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.exAccent.opacity(0.3), lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Needs a look")
                .accessibilityValue(count == 1 ? "One change to check" : "\(count) changes to check")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("today.conflicts")
            }
        }
        #if DEBUG
        .task { ConflictSeed.seedIfAsked(workspace, timeZone: timeZone) }
        #endif
    }
}

/// Every change two devices made at once, both versions side by side, with
/// one tap to keep either, or both where that means two records.
struct ConflictReviewView: View {
    let conflicts: SyncConflictStore
    let unit: MassUnit
    let timeZone: TimeZone
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var resolved: (title: String, detail: String)?
    @State private var error: String?

    var body: some View {
        let open = conflicts.unresolved
        ExScreen {
            if open.isEmpty {
                ExEmptyState(icon: "checkmark.icloud", title: "Nothing needs a look",
                             message: "Every change from your devices is in.", action: "Done", actionID: "conflicts.done") { dismiss() }
            } else {
                // At the largest sizes the cards explain themselves; the
                // paragraph filled the first screen before any conflict.
                ExCard(accent: true) {
                    if !typeSize.isAccessibilitySize { ExEyebrow("Sync review", color: .exPrimaryText) }
                    Text(open.count == 1 ? "1 change to check" : "\(open.count) changes to check").font(.exH1)
                        .foregroundStyle(Color.exTextPrimary).accessibilityAddTraits(.isHeader)
                    if !typeSize.isAccessibilitySize {
                        Text("Two of your devices changed the same thing before they synced. Both versions are kept until you pick one.")
                            .font(.exBody).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(open) { conflict in
                    ConflictCard(summary: summary(conflict)) { option in resolve(conflict, option) }
                }
            }
            let settled = conflicts.settledForYou
            if !settled.isEmpty {
                // Sync settled these: the record went on every device, so there was nothing to choose.
                ExCard {
                    Text("Settled for you").font(.exH3).foregroundStyle(Color.exTextPrimary).accessibilityAddTraits(.isHeader)
                    ForEach(settled) { conflict in
                        Text("\(summary(conflict).title): deleted on every device since, so there was nothing to choose.")
                            .font(.exBody).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("conflicts.settled")
            }
            if let error {
                Text(error).font(.exCaption).foregroundStyle(Color.exError).accessibilityIdentifier("conflicts.error")
            }
        }
        .navigationTitle("Needs a look").navigationBarTitleDisplayMode(.inline)
        // An inset, not an overlay: at the largest text the Undo bar is tall,
        // and the cards scroll clear of it instead of hiding behind it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let resolved, conflicts.undoable != nil {
                ConflictResolvedToast(title: resolved.title, detail: resolved.detail) {
                    do { try conflicts.undo() } catch { self.error = error.localizedDescription }
                    self.resolved = nil
                }
                .padding(.bottom, ExSpacing.small)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: resolved?.title)
        .sensoryFeedback(.success, trigger: conflicts.undoable) { _, new in new != nil }
    }

    private func summary(_ conflict: SyncConflict) -> SyncConflictSummary {
        conflicts.summary(of: conflict, unit: unit, timeZone: timeZone)
    }

    private func resolve(_ conflict: SyncConflict, _ option: SyncConflictSummary.Option) {
        let name = summary(conflict).title
        do {
            try conflicts.resolve(conflict.id, option.choice)
            error = nil
            resolved = (option.done, name)
            UIAccessibility.post(notification: .announcement, argument: "\(option.done), \(name)")
        } catch {
            self.error = "That couldn't be saved. \(error.localizedDescription)"
        }
    }
}

/// One conflict: the record, what each device has, and the choices.
private struct ConflictCard: View {
    let summary: SyncConflictSummary
    let choose: (SyncConflictSummary.Option) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ExCard {
            VStack(alignment: .leading, spacing: ExSpacing.tight) {
                Text(summary.title).font(.exH3).foregroundStyle(Color.exTextPrimary).accessibilityAddTraits(.isHeader)
                if let detail = summary.detail, !detail.isEmpty {
                    Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
            }
            Text(summary.explanation).font(.exBody).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.small))
                : AnyLayout(HStackLayout(alignment: .top, spacing: ExSpacing.small))
            layout {
                VersionTile(side: summary.local, local: true)
                VersionTile(side: summary.remote, local: false)
            }
            if let now = summary.now {
                // Changed again here since: neither version is what this device shows.
                Text("Showing now: \(now)").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("conflict.now")
            }
            if let note = summary.note {
                Label(note, systemImage: "icloud.slash")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("conflict.note")
            }
            VStack(spacing: ExSpacing.small) {
                ForEach(summary.options) { option in
                    Button(option.title) { choose(option) }
                        .buttonStyle(ExActionStyle(secondary: true))
                        .accessibilityIdentifier("conflict.choice.\(option.choice.rawValue)")
                }
            }
        }
        .accessibilityIdentifier("conflict.card")
    }
}

/// One device's version. The one this device has now is outlined.
private struct VersionTile: View {
    let side: SyncConflictSummary.Side
    /// The version of the device that found the conflict.
    let local: Bool
    private var showing: Bool { side.shown }

    var body: some View {
        VStack(alignment: .leading, spacing: ExSpacing.tight) {
            HStack(spacing: ExSpacing.tight) {
                Image(systemName: local ? (side.device.contains("iPad") ? "ipad" : "iphone") : "icloud").font(.caption).accessibilityHidden(true)
                Text(side.device).font(.exSmall.weight(.semibold))
            }
            .foregroundStyle(showing ? Color.exPrimaryText : Color.exTextSecondary)
            Text(side.value).font(.exStatSmall).foregroundStyle(Color.exTextPrimary).fixedSize(horizontal: false, vertical: true)
            if let time = side.time { Text(time).font(.exCaption).foregroundStyle(Color.exTextSecondary) }
            if showing { Text("Showing now").font(.exSmall).foregroundStyle(Color.exPrimaryText) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ExSpacing.item)
        .background(showing ? Color.exPrimary.opacity(0.1) : Color.exSurface2,
                    in: RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous)
                .strokeBorder(showing ? Color.exPrimary.opacity(0.45) : Color.exBorder.opacity(0.5), lineWidth: showing ? 1 : 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([side.device, side.value, side.time, showing ? "Showing now" : nil].compactMap { $0 }.joined(separator: ", "))
    }
}

/// "Kept the other device's · Undo", on the same opaque surface as the logging toast.
private struct ConflictResolvedToast: View {
    let title: String
    let detail: String
    let undo: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: ExSpacing.item))
        layout {
            HStack(spacing: ExSpacing.item) {
                Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Color.exSuccess).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.exLabel.weight(.semibold)).foregroundStyle(Color.exTextPrimary)
                    Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
                .lineLimit(typeSize.isAccessibilitySize ? 5 : 2)
                .accessibilityElement(children: .combine).accessibilityIdentifier("conflicts.resolved")
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: ExSpacing.small) }
            Button("Undo", action: undo).font(.exLabel.weight(.semibold)).foregroundStyle(Color.exPrimaryText).fixedSize()
                .padding(.horizontal, ExSpacing.item).frame(minHeight: 44).contentShape(Rectangle())
                .accessibilityIdentifier("conflicts.undo")
        }
        .padding(.leading, ExSpacing.content).padding(.trailing, ExSpacing.tight).padding(.vertical, 6)
        .exToastSurface(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, ExSpacing.page)
    }
}

#if DEBUG
/// UI tests and screenshots: with EXERLY_SYNC_CONFLICT_SEED=1, a synthetic
/// entry whose amount another device changed, and a weigh-in deleted here
/// that another device changed, as real conflicts in the account's store.
/// With "all", also a workout set and a plan's goal both devices changed.
/// With "removed", only a set clash whose set was removed here since, and a
/// workout's conflict too large to sync.
@MainActor
enum ConflictSeed {
    static func seedIfAsked(_ workspace: TrainingWorkspace, timeZone: TimeZone) {
        let asked = ProcessInfo.processInfo.environment["EXERLY_SYNC_CONFLICT_SEED"]
        guard asked == "1" || asked == "all" || asked == "removed", workspace.conflicts.conflicts.isEmpty else { return }
        do {
            if asked == "removed" {
                for conflict in try removedSetAndTooLarge(workspace, at: Date().addingTimeInterval(-180), device: workspace.conflicts.device) {
                    try workspace.conflicts.prepareWrite(kind: SyncConflictStore.kind, id: conflict.id.uuidString,
                                                         payload: ExerlyJSON.canonical(conflict))()
                }
                return
            }
            let today = LocalDate(Date(), in: timeZone)
            let food = Food(id: "seed-conflict-yogurt", name: "Synthetic Greek yogurt",
                            per100g: NutrientAmounts([.energy: 97, .protein: 9, .carbohydrate: 4, .fat: 5]), servings: [], createdAt: Date())
            var entry = try workspace.nutrition.log(food, grams: 40, on: today, meal: "Breakfast")
            let base = try ExerlyCore.JSONValue(encoding: entry)
            entry.grams = 90
            try workspace.nutrition.saveEntry(entry)
            // As saved, so marked as changed, the way both devices' versions are.
            entry = workspace.nutrition.entries.first { $0.id == entry.id } ?? entry
            let local = try ExerlyCore.JSONValue(encoding: entry)
            entry.grams = 60
            let remote = try ExerlyCore.JSONValue(encoding: entry)
            let at = Date().addingTimeInterval(-180)
            let device = workspace.conflicts.device
            let weight = WeightEntry(at: at.addingTimeInterval(-86_400), date: today.adding(days: -1), weight: .kg(80.4))
            var changed = weight
            changed.weight = .kg(80.9)
            let weightBase = try ExerlyCore.JSONValue(encoding: weight), weightRemote = try ExerlyCore.JSONValue(encoding: changed)
            let seeded = [
                SyncConflict(kind: "food_entry", documentID: entry.id.uuidString, device: device, detectedAt: at,
                             remoteAt: at.addingTimeInterval(-60), base: base, local: local, remote: remote, fields: ["grams"]),
                SyncConflict(kind: "weight_entry", documentID: weight.id.uuidString, device: device, detectedAt: at.addingTimeInterval(-5),
                             remoteAt: at.addingTimeInterval(-120), base: weightBase, local: nil,
                             remote: weightRemote, fields: []),
            ]
            for conflict in seeded + (asked == "all" ? try workoutAndGoal(workspace, today: today, timeZone: timeZone, at: at, device: device) : []) {
                try workspace.conflicts.prepareWrite(kind: SyncConflictStore.kind, id: conflict.id.uuidString,
                                                     payload: ExerlyJSON.canonical(conflict))()
            }
        } catch {
            assertionFailure("Couldn't seed conflicts: \(error)")
        }
    }

    /// Yesterday's workout, whose second set one device made heavier and
    /// the other gave a rep more, and a plan's goal changed on both.
    private static func workoutAndGoal(_ workspace: TrainingWorkspace, today: LocalDate, timeZone: TimeZone, at: Date, device: SyncDevice) throws
        -> [SyncConflict] {
        let sets = (0..<3).map { index in
            PerformedSet(efforts: [Effort(reps: 5, load: .kg(100))], completedAt: at.addingTimeInterval(-86_400 + Double(index) * 180))
        }
        let session = WorkoutSession(name: "Synthetic push day", startedAt: at.addingTimeInterval(-86_400 - 600),
                                     endedAt: at.addingTimeInterval(-86_400 + 1_800),
                                     exercises: [PerformedExercise(exerciseID: "barbell-bench-press", sets: sets)])
        try workspace.store.importSessions([session])
        var heavier = session, more = session
        heavier.exercises[0].sets[1].efforts[0].load = .kg(102.5)
        more.exercises[0].sets[1].efforts[0].reps = 6
        try workspace.store.saveSession(heavier)
        let path = "exercises[\(session.exercises[0].id.uuidString)].sets[\(sets[1].id.uuidString)].efforts"
        var plan = try NutritionPlan(startDate: today, goal: NutritionGoal(.lose, weeklyRate: 0.005))
            .computed(from: PlanBasis(expenditure: 2_500, expenditureError: 300, trendWeight: 80))
        let planBase = try ExerlyCore.JSONValue(encoding: plan)
        plan.goal = NutritionGoal(.lose, weeklyRate: 0.0075)
        try workspace.nutrition.savePlan(plan, timeZone: timeZone)
        var maintain = plan
        maintain.goal = NutritionGoal(.maintain)
        return [
            SyncConflict(kind: "workout_session", documentID: session.id.uuidString, device: device, detectedAt: at.addingTimeInterval(-10),
                         remoteAt: at.addingTimeInterval(-200), base: try ExerlyCore.JSONValue(encoding: session),
                         local: try ExerlyCore.JSONValue(encoding: heavier), remote: try ExerlyCore.JSONValue(encoding: more), fields: [path]),
            SyncConflict(kind: "nutrition_plan", documentID: plan.id.uuidString, device: device, detectedAt: at.addingTimeInterval(-15),
                         remoteAt: at.addingTimeInterval(-300), base: planBase,
                         local: try ExerlyCore.JSONValue(encoding: plan),
                         remote: try ExerlyCore.JSONValue(encoding: maintain), fields: ["goal"]),
        ]
    }

    /// Yesterday's workout whose second set clashed and was removed here
    /// since, and a long workout changed here, deleted elsewhere, whose
    /// conflict is too large to sync.
    private static func removedSetAndTooLarge(_ workspace: TrainingWorkspace, at: Date, device: SyncDevice) throws -> [SyncConflict] {
        let sets = (0..<3).map { index in
            PerformedSet(efforts: [Effort(reps: 5, load: .kg(100))], completedAt: at.addingTimeInterval(-86_400 + Double(index) * 180))
        }
        let session = WorkoutSession(name: "Synthetic push day", startedAt: at.addingTimeInterval(-86_400 - 600),
                                     endedAt: at.addingTimeInterval(-86_400 + 1_800),
                                     exercises: [PerformedExercise(exerciseID: "barbell-bench-press", sets: sets)])
        try workspace.store.importSessions([session])
        var heavier = session, more = session
        heavier.exercises[0].sets[1].efforts[0].load = .kg(102.5)
        more.exercises[0].sets[1].efforts[0].reps = 6
        var removed = heavier
        removed.exercises[0].sets.remove(at: 1)
        try workspace.store.saveSession(removed)
        let path = "exercises[\(session.exercises[0].id.uuidString)].sets[\(sets[1].id.uuidString)].efforts"
        let long = WorkoutSession(name: "Synthetic long session", startedAt: at.addingTimeInterval(-2 * 86_400),
                                  endedAt: at.addingTimeInterval(-2 * 86_400 + 5_400),
                                  exercises: [PerformedExercise(exerciseID: "barbell-row", sets: sets)])
        return [
            SyncConflict(kind: "workout_session", documentID: session.id.uuidString, device: device, detectedAt: at,
                         remoteAt: at.addingTimeInterval(-200), base: try ExerlyCore.JSONValue(encoding: session),
                         local: try ExerlyCore.JSONValue(encoding: heavier), remote: try ExerlyCore.JSONValue(encoding: more), fields: [path]),
            SyncConflict(kind: "workout_session", documentID: long.id.uuidString, device: device, detectedAt: at.addingTimeInterval(-10),
                         remoteAt: at.addingTimeInterval(-400), base: nil, local: try ExerlyCore.JSONValue(encoding: long), remote: nil,
                         fields: [], tooLarge: true),
        ]
    }
}
#endif
