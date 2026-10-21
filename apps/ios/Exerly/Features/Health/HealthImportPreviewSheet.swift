import ExerlyCore
import SwiftUI

/// What importing from Health would add, before anything is saved.
struct HealthImportPreviewSheet: View {
    let pending: HealthHistoryModel.Pending
    let onImport: () -> Void
    let onCancel: () -> Void

    private var preview: HealthHistoryPreview { pending.preview }

    var body: some View {
        NavigationStack {
            ExScreen {
                ExCard(accent: true) {
                    Text(preview.isEmpty ? "Nothing new to add" : pending.kind.count(preview.adding))
                        .font(.exH2).foregroundStyle(Color.exTextPrimary).accessibilityIdentifier("health.preview.adding")
                    if let first = preview.first, let last = preview.last {
                        Text(first == last ? "On \(Self.date(first))" : "From \(Self.date(first)) to \(Self.date(last))")
                            .font(.exBody).foregroundStyle(Color.exTextSecondary)
                    }
                    if preview.alreadyIn > 0 {
                        Text("\(pending.kind.count(preview.alreadyIn)) already in Exerly stay as they are.")
                            .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    }
                    if preview.leftOut > 0 {
                        Text("\(pending.kind.count(preview.leftOut)) set aside, because a source higher in the list below recorded the same "
                            + (pending.kind == .workouts ? "time." : "day."))
                            .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !preview.sources.isEmpty {
                    VStack(alignment: .leading, spacing: ExSpacing.small) {
                        ExEyebrow("Sources, first counts first").accessibilityAddTraits(.isHeader)
                        ExCard {
                            ForEach(Array(preview.sources.enumerated()), id: \.offset) { index, source in
                                if index > 0 { Divider().overlay(Color.exBorder.opacity(0.6)) }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.name).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                                    Text(sourceLine(source)).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                Text(pending.kind == .foods
                    ? "Foods are added to the meal for their time of day and are never written back to Health. Deleting one in Health removes it here."
                    : "Nothing is saved until you import. New ones are read when you open this screen.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                Button(action: onImport) { Text(preview.isEmpty ? "Turn on" : "Import \(pending.kind.count(preview.adding))") }
                    .buttonStyle(ExActionStyle()).accessibilityIdentifier("health.preview.import")
            }
            .navigationTitle("Import from Health").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).accessibilityIdentifier("health.preview.cancel")
                }
            }
        }
    }

    private func sourceLine(_ source: HealthHistoryPreview.Source) -> String {
        var parts: [String] = []
        if source.adding > 0 { parts.append("Adds \(pending.kind.count(source.adding))") }
        if source.leftOut > 0 { parts.append("\(source.leftOut.formatted()) set aside") }
        return parts.isEmpty ? "Already in Exerly" : parts.joined(separator: " · ")
    }

    private static func date(_ date: LocalDate) -> String {
        NutritionFormat.pickerDate(date, timeZone: .current).formatted(.dateTime.day().month(.abbreviated).year())
    }
}
