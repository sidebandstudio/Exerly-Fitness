import ExerlyCore
import SwiftUI

/// The day's food along the hours it was eaten: Today's alternative to its
/// meals. Each entry shows its time and meal. Food whose time on this day
/// isn't known (logged on another day, or moved here) comes last.
struct TodayTimelineView: View {
    let timeline: FoodTimeline
    let timeZone: TimeZone
    let unit: MassUnit
    /// The foods chosen while choosing; nil otherwise. A tap then chooses.
    var selection: Set<UUID>?
    let edit: (FoodEntry) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            if timeline.hours.isEmpty && timeline.untimed.isEmpty {
                Text("Nothing logged yet. Food you log shows here at the hour you ate it.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                    .padding(ExSpacing.content).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.exSurface1, in: RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous))
                    .accessibilityIdentifier("today.byTime.empty")
            }
            ForEach(timeline.hours) { hour in
                group(title: title(hour), entries: hour.entries, energy: hour.energy,
                      id: "today.byTime.hour.\(hour.hour)\(hour.repeated ? ".again" : "")")
            }
            if !timeline.untimed.isEmpty {
                group(title: "Time not known", entries: timeline.untimed,
                      energy: timeline.untimed.reduce(0) { $0 + $1.nutrients.energy }, id: "today.byTime.untimed",
                      note: "Logged on another day, or moved here")
            }
        }
        // No container of its own: with a single hour, one would take over
        // that hour's label and identifier, and the hour would vanish as an element.
    }

    /// "8 AM"; with the zone ("1 AM EST") when clocks go back and the hour comes twice.
    private func title(_ hour: FoodTimeline.Hour) -> String {
        var style = Date.FormatStyle.dateTime.hour()
        style.timeZone = timeZone
        let text = hour.start.formatted(style)
        let twice = timeline.hours.filter { $0.hour == hour.hour }.count > 1
        return twice ? "\(text) \(timeZone.abbreviation(for: hour.start) ?? "")" : text
    }

    private func group(title: String, entries: [FoodEntry], energy: Double, id: String, note: String? = nil) -> some View {
        let kcal = "\(TodayNutritionCard.number(energy)) kcal"
        let card = VStack(alignment: .leading, spacing: 0) {
            // At the largest sizes the hour heads its card; otherwise it sits in the gutter.
            if typeSize.isAccessibilitySize {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.exLabel.weight(.semibold)).foregroundStyle(Color.exPrimaryText)
                    Spacer(minLength: ExSpacing.small)
                    Text(kcal).font(.exLabel).monospacedDigit().foregroundStyle(Color.exTextSecondary)
                }
                .padding(.horizontal, ExSpacing.content).padding(.top, 10)
            }
            if let note {
                Text(note).font(.exSmall).foregroundStyle(Color.exTextMuted).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, ExSpacing.content).padding(.top, 10)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().overlay(Color.exBorder.opacity(0.35)).padding(.leading, ExSpacing.content) }
                Button { edit(entry) } label: { row(entry) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection?.contains(entry.id) == true ? .isSelected : [])
                    .accessibilityHint(selection == nil ? "Opens the entry to change or delete it" : "Chooses it to copy or move")
                    .accessibilityIdentifier("nutrition.entry.\(entry.id.uuidString)")
            }
        }
        .background(Color.exSurface1, in: RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous).strokeBorder(Color.exBorder.opacity(0.5), lineWidth: 0.5) }
        return Group {
            if typeSize.isAccessibilitySize {
                card
            } else {
                // The hour and its calories in a gutter, joined to the next hour by a line.
                HStack(alignment: .top, spacing: ExSpacing.small) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(title).font(.exLabel.weight(.semibold)).foregroundStyle(Color.exPrimaryText).monospacedDigit()
                            .multilineTextAlignment(.trailing).minimumScaleFactor(0.7).lineLimit(2)
                        Text(kcal).font(.exSmall).monospacedDigit().foregroundStyle(Color.exTextMuted)
                            .minimumScaleFactor(0.8).lineLimit(1)
                        Capsule().fill(Color.exPrimary.opacity(0.22)).frame(width: 2).frame(maxHeight: .infinity)
                            .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 4)
                    }
                    .frame(width: 66).padding(.top, 14)
                    .accessibilityHidden(true)
                    card
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(kcal)")
        .accessibilityIdentifier(id)
    }

    private func row(_ entry: FoodEntry) -> some View {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = timeZone
        let known = LocalDate(entry.loggedAt, in: timeZone) == entry.date
        let detail = [NutritionFormat.portion(entry, unit: unit), entry.meal] + (known ? [entry.loggedAt.formatted(style)] : [])
        let kcal = TodayNutritionCard.number(entry.nutrients.energy)
        return HStack(spacing: ExSpacing.item) {
            if let selection {
                let chosen = selection.contains(entry.id)
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(chosen ? Color.exActionFill : Color.exTextMuted).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.food.name).font(.exBody).foregroundStyle(Color.exTextPrimary).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                Text(detail.joined(separator: " · ")).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(kcal).font(.exStatSmall).monospacedDigit().foregroundStyle(Color.exTextPrimary)
        }
        .padding(.horizontal, ExSpacing.content).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.food.name), \(detail.joined(separator: ", ")), \(kcal) calories")
    }
}
