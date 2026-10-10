import ExerlyCore
import SwiftUI

/// While choosing foods on Today: how many, Copy or Move for them, and a
/// way out wherever the meals have scrolled to.
struct TodaySelectionBar: View {
    let count: Int
    let copy: () -> Void
    let move: () -> Void
    let close: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ExSpacing.small) {
                closeButton
                status
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: ExSpacing.small) {
                HStack(spacing: ExSpacing.small) { closeButton; status }
                HStack(spacing: ExSpacing.small) { actions }
            }
            // The largest text: Copy and Move one above the other, whole.
            VStack(alignment: .leading, spacing: ExSpacing.small) {
                HStack(spacing: ExSpacing.small) { closeButton; status }
                actions
            }
        }
        .padding(.leading, ExSpacing.tight).padding(.trailing, ExSpacing.small).padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, ExSpacing.page).padding(.bottom, ExSpacing.small)
        .accessibilityElement(children: .contain)
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.exTextSecondary)
                .frame(width: 44, height: 44).contentShape(Circle())
        }
        .buttonStyle(.plain).accessibilityLabel("Stop choosing").accessibilityIdentifier("today.endSelection")
    }

    private var status: some View {
        Text(count < 1 ? "Choose foods" : "\(count) selected").font(.exLabel).foregroundStyle(Color.exTextPrimary)
            .accessibilityIdentifier("today.selectedCount")
    }

    @ViewBuilder private var actions: some View {
        Group {
            Button("Copy", systemImage: "doc.on.doc", action: copy).accessibilityIdentifier("today.copySelected")
                .accessibilityLabel(count == 1 ? "Copy 1 food" : "Copy \(count) foods")
            Button("Move", systemImage: "arrow.right", action: move).accessibilityIdentifier("today.moveSelected")
                .accessibilityLabel(count == 1 ? "Move 1 food" : "Move \(count) foods")
        }
        .buttonStyle(Style()).disabled(count < 1)
    }
}

extension TodaySelectionBar {
    /// Copy and Move as filled capsules, dimmed until a food is chosen.
    struct Style: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label.font(.exLabel.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(Color.exActionFill.opacity(isEnabled ? 1 : 0.4), in: Capsule())
                .opacity(configuration.isPressed ? 0.8 : 1)
        }
    }
}

/// Where foods chosen on Today go: a day, and a meal or each its own. A
/// copy keeps each food's portion and source; a move keeps the entry.
struct TodayEntriesDestination: View {
    enum Action { case copy, move }

    let action: Action
    let count: Int
    let source: LocalDate
    let today: LocalDate
    let meals: [String]
    let timeZone: TimeZone
    let onConfirm: (LocalDate, String?) -> Void
    @State private var date: LocalDate
    /// Nil keeps each food in its own meal.
    @State private var meal: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(action: Action, count: Int, source: LocalDate, today: LocalDate, meals: [String], timeZone: TimeZone,
         onConfirm: @escaping (LocalDate, String?) -> Void) {
        self.action = action
        self.count = count
        self.source = source
        self.today = today
        self.meals = meals
        self.timeZone = timeZone
        self.onConfirm = onConfirm
        // A copy usually goes to the next day; a move, usually to another meal the same day.
        _date = State(initialValue: action == .copy ? source.adding(days: 1) : source)
    }

    var body: some View {
        NavigationStack {
            ExScreen {
                VStack(alignment: .leading, spacing: ExSpacing.small) {
                    ExSectionHeading("Day")
                    ExChoiceChips(values: days, selection: $date) { TodayEntriesDestination.dayName($0, today: today, timeZone: timeZone) }
                        .accessibilityIdentifier("today.destinationDay")
                    // The label goes above the date when they don't fit side by side.
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text("Another day").accessibilityHidden(true)
                            Spacer(minLength: ExSpacing.small)
                            anotherDay
                        }
                        VStack(alignment: .leading, spacing: ExSpacing.tight) {
                            Text("Another day").accessibilityHidden(true)
                            anotherDay
                        }
                    }
                    .font(.exBody).frame(minHeight: 44)
                }
                VStack(alignment: .leading, spacing: ExSpacing.small) {
                    ExSectionHeading("Meal")
                    ExChoiceChips(values: [nil] + meals.map(Optional.some), selection: $meal) { $0 ?? "Same meals" }
                        .accessibilityIdentifier("today.destinationMeal")
                }
                Text(action == .copy ? "Copies keep each food's portion and nutrition. The originals stay."
                     : "The foods keep their portions and leave \(TodayEntriesDestination.dayName(source, today: today, timeZone: timeZone).lowercased()).")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action == .copy ? "Copy" : "Move") {
                        onConfirm(date, meal)
                        dismiss()
                    }
                    .fontWeight(.semibold).disabled(action == .move && date == source && meal == nil)
                    .accessibilityIdentifier("today.confirmDestination")
                }
            }
        }
        .environment(\.timeZone, timeZone)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }

    private var title: String { "\(action == .copy ? "Copy" : "Move") \(count) \(count == 1 ? "food" : "foods")" }

    private var anotherDay: some View {
        DatePicker("Another day", selection: Binding(
            get: { NutritionFormat.pickerDate(date, timeZone: timeZone) },
            set: { date = LocalDate($0, in: timeZone) }), displayedComponents: .date)
            .labelsHidden()
    }

    /// Yesterday, today and tomorrow, and a day chosen from the calendar.
    private var days: [LocalDate] {
        let near = [today.adding(days: -1), today, today.adding(days: 1)]
        return near.contains(date) ? near : near + [date]
    }

    /// "Today", "Tomorrow", "Yesterday", or the weekday and date.
    static func dayName(_ day: LocalDate, today: LocalDate, timeZone: TimeZone) -> String {
        switch day {
        case today: return "Today"
        case today.adding(days: 1): return "Tomorrow"
        case today.adding(days: -1): return "Yesterday"
        default:
            var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
            style.timeZone = timeZone
            return NutritionFormat.pickerDate(day, timeZone: timeZone).formatted(style)
        }
    }
}
