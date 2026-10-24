import ExerlyCore
import SwiftUI

/// One change from Health waiting for the person, and what applying it does.
struct HealthChangeRow: Identifiable, Hashable {
    var id: UUID
    var title: String
    var detail: String
}

/// Changes from Health: what Health deleted, and what it no longer has, each
/// saying what applying it does. Nothing in Exerly changes until they apply
/// them on this iPhone, or keep everything.
struct HealthChangesCard: View {
    @ObservedObject var history: HealthHistoryModel
    /// At most this many rows, then a count of the rest.
    private let shown = 5

    var body: some View {
        let rows = history.changeRows()
        if !rows.isEmpty || history.changesMessage != nil {
            VStack(alignment: .leading, spacing: ExSpacing.small) {
                ExEyebrow("Changes from Health").accessibilityAddTraits(.isHeader)
                ExCard {
                    if rows.isEmpty {
                        Text(history.changesMessage ?? "").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                            .accessibilityIdentifier("health.changes.message")
                    } else {
                        Text("Nothing here changes until you apply it.")
                            .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                        ForEach(rows.prefix(shown)) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                                Text(row.detail).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .combine)
                        }
                        if rows.count > shown {
                            Text("And \((rows.count - shown).formatted()) more.").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                        }
                        if let message = history.changesMessage {
                            Text(message).font(.exCaption).foregroundStyle(Color.exTextSecondary).accessibilityIdentifier("health.changes.message")
                        }
                        Button("Apply changes") { Task { await history.applyChanges() } }
                            .buttonStyle(ExActionStyle()).disabled(history.applying)
                            .accessibilityIdentifier("health.changes.apply")
                        Button("Keep everything") { history.keepEverything() }
                            .buttonStyle(ExActionStyle(secondary: true)).disabled(history.applying)
                            .accessibilityIdentifier("health.changes.keep")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("health.changes")
        }
    }
}

/// The card on its own, as Today's row opens it.
struct HealthChangesSheet: View {
    @StateObject private var history: HealthHistoryModel
    @Environment(\.dismiss) private var dismiss

    init(accountID: String) {
        _history = StateObject(wrappedValue: HealthHistoryModel(accountID: accountID))
    }

    var body: some View {
        NavigationStack {
            ExScreen { HealthChangesCard(history: history) }
                .navigationTitle("Apple Health").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("health.changes.done")
                    }
                }
        }
    }
}

/// A quiet row on Today while changes from Health wait, opening them.
struct TodayHealthChangesRow: View {
    let accountID: String
    let count: Int
    @State private var showsChanges = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button { showsChanges = true } label: {
            HStack(spacing: ExSpacing.item) {
                // At the largest sizes the words take the width.
                if !typeSize.isAccessibilitySize {
                    Image(systemName: "heart.text.square").foregroundStyle(Color.exTextSecondary).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Changes from Health").font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                    Text(count == 1 ? "1 to review" : "\(count.formatted()) to review").font(.exSmall).foregroundStyle(Color.exTextSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.exSmall).foregroundStyle(Color.exTextMuted).accessibilityHidden(true)
            }
            .padding(ExSpacing.item).frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("today.healthChanges")
        .sheet(isPresented: $showsChanges) { HealthChangesSheet(accountID: accountID) }
    }
}

/// Where an import came from in Health, and what else Health has for its day
/// or time, as its food entry or activity shows them: "From Health · Diary",
/// then "Also in Health from Tracker, not imported".
struct HealthSourceLines: View {
    let lines: [String]

    var body: some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            Text(line).foregroundStyle(index == 0 ? Color.exTextPrimary : Color.exTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(index == 0 ? "health.fromHealth" : "health.alsoInHealth")
        }
    }
}
