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
            if let error {
                Text(error).font(.exCaption).foregroundStyle(Color.exError).accessibilityIdentifier("conflicts.error")
            }
        }
        .navigationTitle("Needs a look").navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
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
        conflict.summary(on: conflicts.device, unit: unit, timeZone: timeZone, replaced: conflicts.replacement(for: conflict) != nil)
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
                VersionTile(side: summary.local, showing: true)
                VersionTile(side: summary.remote, showing: false)
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

/// One device's version. The one in use now is outlined.
private struct VersionTile: View {
    let side: SyncConflictSummary.Side
    let showing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ExSpacing.tight) {
            HStack(spacing: ExSpacing.tight) {
                Image(systemName: showing ? (side.device.contains("iPad") ? "ipad" : "iphone") : "icloud").font(.caption).accessibilityHidden(true)
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
@MainActor
enum ConflictSeed {
    static func seedIfAsked(_ workspace: TrainingWorkspace, timeZone: TimeZone) {
        guard ProcessInfo.processInfo.environment["EXERLY_SYNC_CONFLICT_SEED"] == "1", workspace.conflicts.conflicts.isEmpty else { return }
        do {
            let today = LocalDate(Date(), in: timeZone)
            let food = Food(id: "seed-conflict-yogurt", name: "Synthetic Greek yogurt",
                            per100g: NutrientAmounts([.energy: 97, .protein: 9, .carbohydrate: 4, .fat: 5]), servings: [], createdAt: Date())
            var entry = try workspace.nutrition.log(food, grams: 40, on: today, meal: "Breakfast")
            let base = try ExerlyCore.JSONValue(encoding: entry)
            entry.grams = 90
            try workspace.nutrition.saveEntry(entry)
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
            for conflict in seeded {
                try workspace.conflicts.prepareWrite(kind: SyncConflictStore.kind, id: conflict.id.uuidString,
                                                     payload: ExerlyJSON.canonical(conflict))()
            }
        } catch {
            assertionFailure("Couldn't seed conflicts: \(error)")
        }
    }
}
#endif
