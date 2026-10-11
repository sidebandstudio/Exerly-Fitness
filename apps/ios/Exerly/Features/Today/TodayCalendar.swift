import ExerlyCore
import SwiftUI

/// Today's date picker, and the food log's habits at a glance: a month of
/// days, each marked with what it recorded (food logged, marked complete, a
/// fast, a partial log, nothing) and a dot for a weigh-in. A tap opens the
/// day on Today. No streaks or confetti; just what happened.
struct NutritionDateView: View {
    @Binding var date: LocalDate
    let store: NutritionStore
    let timeZone: TimeZone
    /// The first of the month shown.
    @State private var month: LocalDate
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(date: Binding<LocalDate>, store: NutritionStore, timeZone: TimeZone) {
        _date = date
        self.store = store
        self.timeZone = timeZone
        _month = State(initialValue: Self.first(of: date.wrappedValue))
    }

    private var today: LocalDate { LocalDate(Date(), in: timeZone) }
    private var firstWeekday: Weekday { Weekday(rawValue: Calendar.current.firstWeekday) ?? .sunday }

    var body: some View {
        let days = store.habits(from: month, through: Self.last(of: month), today: today)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ExSpacing.content) {
                    header
                    grid(days)
                        .gesture(DragGesture(minimumDistance: 24).onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            show(value.translation.width < 0 ? 1 : -1)
                        })
                    summary(days)
                    legend
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, ExSpacing.page).padding(.vertical, ExSpacing.small)
            }
            .background(Color.exBackground)
            .navigationTitle("Choose a date").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if date != today {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Today") { choose(today) }.accessibilityIdentifier("calendar.today")
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
        }
        .accessibilityIdentifier("calendar.screen")
    }

    // MARK: Month

    private var header: some View {
        var style = Date.FormatStyle.dateTime.month(.wide).year()
        style.timeZone = .gmt
        let title = NutritionFormat.pickerDate(month, timeZone: .gmt).formatted(style)
        return HStack {
            monthButton(-1, icon: "chevron.left", label: "Previous month")
            Spacer(minLength: ExSpacing.small)
            Text(title).font(.exH3).foregroundStyle(Color.exTextPrimary).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("calendar.month")
            Spacer(minLength: ExSpacing.small)
            monthButton(1, icon: "chevron.right", label: "Next month")
        }
    }

    private func monthButton(_ offset: Int, icon: String, label: String) -> some View {
        Button { show(offset) } label: {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.exPrimaryText)
                .frame(width: 44, height: 44).background(Color.exSurface2, in: Circle())
        }
        .buttonStyle(TodayPressStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(offset < 0 ? "calendar.previous" : "calendar.next")
    }

    private func grid(_ days: [HabitDay]) -> some View {
        let lead = month.startOfWeek(firstWeekday: firstWeekday).days(until: month)
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        let names = (0..<7).map { symbols[(firstWeekday.rawValue - 1 + $0) % 7] }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(0..<7, id: \.self) { index in
                Text(names[index]).font(.exSmall.weight(.semibold)).foregroundStyle(Color.exTextMuted)
                    .frame(maxWidth: .infinity, minHeight: 20).accessibilityHidden(true)
            }
            ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 1).accessibilityHidden(true) }
            ForEach(days) { cell($0) }
        }
        // Seven columns can't grow without end; each day says everything to VoiceOver.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Days")
    }

    private func cell(_ day: HabitDay) -> some View {
        let selected = day.date == date, isToday = day.date == today
        let filled = day.food == .complete
        return Button { choose(day.date) } label: {
            VStack(spacing: 3) {
                ZStack {
                    Self.mark(day.food)
                    if selected { Circle().strokeBorder(Color.exTextPrimary, lineWidth: 2).padding(-4) }
                    Text("\(day.date.day)")
                        .font(.system(.callout, design: .rounded, weight: isToday || selected ? .bold : .medium)).monospacedDigit()
                        .foregroundStyle(filled ? Color.white : day.food == .upcoming && !isToday ? Color.exTextMuted : Color.exTextPrimary)
                        .minimumScaleFactor(0.6).lineLimit(1)
                }
                .frame(width: 36, height: 36)
                Circle().fill(day.weighedIn ? Color.exSecondary : .clear).frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.spokenDate(day.date, isToday: isToday))
        .accessibilityValue(Self.spoken(day))
        .accessibilityHint("Opens this day on Today")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("calendar.day.\(day.date)")
    }

    /// Each kind of day has its own shape, so none relies on colour alone.
    @ViewBuilder static func mark(_ food: HabitDay.Food) -> some View {
        switch food {
        case .complete: Circle().fill(Color.exActionFill)
        case .recorded: Circle().fill(Color.exPrimary.opacity(0.26))
        case .partial:
            Circle().fill(LinearGradient(stops: [.init(color: .clear, location: 0.5), .init(color: Color.exPrimary.opacity(0.4), location: 0.5)],
                                         startPoint: .top, endPoint: .bottom))
                .overlay { Circle().strokeBorder(Color.exPrimary.opacity(0.6), lineWidth: 1.5) }
        case .fasted: Circle().strokeBorder(Color.exAccent, lineWidth: 2.5)
        case .missing: Circle().strokeBorder(Color.exTextMuted.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [2, 3]))
        case .upcoming: Color.clear
        }
    }

    // MARK: Words

    /// The month in numbers: what was logged, fasted, partial and missed, and weigh-ins.
    private func summary(_ days: [HabitDay]) -> some View {
        let count = { (kinds: [HabitDay.Food]) in days.filter { kinds.contains($0.food) }.count }
        var parts = ["\(count([.complete, .recorded])) logged"]
        if count([.complete]) > 0 { parts[0] += " (\(count([.complete])) complete)" }
        for (kinds, words) in [([HabitDay.Food.fasted], "fasted"), ([.partial], "partial"), ([.missing], "not logged")] where count(kinds) > 0 {
            parts.append("\(count(kinds)) \(words)")
        }
        let weighIns = days.filter(\.weighedIn).count
        parts.append(weighIns == 1 ? "1 weigh-in" : "\(weighIns) weigh-ins")
        return Text(parts.joined(separator: " · ")).font(.exCaption).monospacedDigit().foregroundStyle(Color.exTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("This month: " + parts.joined(separator: ", "))
            .accessibilityIdentifier("calendar.summary")
    }

    private var legend: some View {
        let items: [(HabitDay.Food?, String)] = [(.complete, "Complete"), (.recorded, "Food logged"), (.partial, "Partial"),
                                                 (.fasted, "Fasted"), (.missing, "Not logged"), (nil, "Weigh-in")]
        let columns = [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 220 : 130), alignment: .leading)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: ExSpacing.small) {
            ForEach(items, id: \.1) { kind, words in
                HStack(spacing: ExSpacing.small) {
                    Group {
                        if let kind { Self.mark(kind) } else { Circle().fill(Color.exSecondary).padding(5) }
                    }
                    .frame(width: 16, height: 16)
                    Text(words).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
            }
        }
        .padding(ExSpacing.item)
        .background(Color.exSurface1, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }

    static func spoken(_ day: HabitDay) -> String {
        let food = switch day.food {
        case .complete: "Complete"
        case .recorded: "Food logged"
        case .partial: "Partial log"
        case .fasted: "Fasted"
        case .missing: "Not logged"
        case .upcoming: "Nothing logged yet"
        }
        return day.weighedIn ? "\(food), weighed in" : food
    }

    private static func spokenDate(_ date: LocalDate, isToday: Bool) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
        style.timeZone = .gmt
        let text = NutritionFormat.pickerDate(date, timeZone: .gmt).formatted(style)
        return isToday ? "Today, \(text)" : text
    }

    // MARK: Moving

    private func choose(_ day: LocalDate) {
        date = day
        UISelectionFeedbackGenerator().selectionChanged()
        dismiss()
    }

    private func show(_ offset: Int) {
        let next = offset < 0 ? Self.first(of: month.adding(days: -1)) : Self.last(of: month).adding(days: 1)
        withAnimation(.snappy) { month = next }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func first(of date: LocalDate) -> LocalDate { LocalDate(year: date.year, month: date.month, day: 1)! }

    static func last(of month: LocalDate) -> LocalDate {
        var day = month
        while day.adding(days: 1).month == month.month { day = day.adding(days: 1) }
        return day
    }
}
