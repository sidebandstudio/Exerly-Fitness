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
                if let note = pending.note {
                    Label(note, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exWarning)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("health.preview.note")
                }
                ExCard(accent: true) {
                    Text(preview.adding == 0 ? "Nothing new to add" : pending.kind.count(preview.adding))
                        .font(.exH2).foregroundStyle(Color.exTextPrimary).accessibilityIdentifier("health.preview.adding")
                    if let first = preview.first, let last = preview.last {
                        Text(first == last ? "On \(Self.date(first))" : "From \(Self.date(first)) to \(Self.date(last))")
                            .font(.exBody).foregroundStyle(Color.exTextSecondary)
                    }
                    ForEach(notes, id: \.self) { note in
                        Text(note).font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !preview.sources.isEmpty {
                    VStack(alignment: .leading, spacing: ExSpacing.small) {
                        ExEyebrow("Sources, best first").accessibilityAddTraits(.isHeader)
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
                Text(pending.kind == .foods ? "Each goes in the meal for its time and isn't written back to Health."
                    : "Nothing is saved until you import.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                Button(action: onImport) { Text(preview.adding == 0 ? (preview.removing > 0 ? "Update" : "Turn on") : "Import \(pending.kind.count(preview.adding))") }
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

    /// What else importing does, a short line each.
    private var notes: [String] {
        var notes: [String] = []
        if preview.alreadyIn > 0 { notes.append("\(pending.kind.count(preview.alreadyIn)) already in Exerly.") }
        if preview.leftOut > 0 { notes.append("\(pending.kind.count(preview.leftOut)) set aside for a better source.") }
        if preview.removing > 0 {
            notes.append("\(pending.kind.count(preview.removing)) taken out: deleted in Health, or a better source has \(pending.kind == .workouts ? "them" : "that day").")
        }
        if preview.outside > 0 { notes.append("\(pending.kind.count(preview.outside)) left in Health: Exerly keeps the last ten years.") }
        return notes
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
