import ExerlyCore
import SwiftUI

/// Seven days ending today, each with a ring for its calories against
/// target, so yesterday is always one tap away. Swipe for earlier weeks.
struct TodayWeekStrip: View {
    @Binding var date: LocalDate
    let today: LocalDate
    let timeZone: TimeZone
    /// Calories eaten over target for a day; nil when nothing is logged, and
    /// negative when food is logged but the day has no target.
    let fraction: (LocalDate) -> Double?
    /// The window's last day. It moves only when the date leaves the window.
    @State private var end: LocalDate?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let last = window(for: date)
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { offset in
                day(last.adding(days: offset - 6))
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 24).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            shift(by: value.translation.width < 0 ? 7 : -7)
        })
        .onChange(of: date) { _, new in end = window(for: new) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Days")
        .accessibilityIdentifier("diary.selected-day")
        .accessibilityValue(date.description)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: date = date.adding(days: 1)
            case .decrement: date = date.adding(days: -1)
            @unknown default: break
            }
        }
    }

    /// The window's last day: today until the date leaves the window.
    /// Future days are reachable for planning by swiping on.
    private func window(for date: LocalDate) -> LocalDate {
        let current = end ?? today
        if date <= current && date > current.adding(days: -7) { return current }
        return date > current ? date : max(date.adding(days: 3), min(today, date.adding(days: 6)))
    }

    private func shift(by days: Int) {
        let target = date.adding(days: days)
        withAnimation(.snappy) {
            end = window(for: date).adding(days: days)
            date = target
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func day(_ day: LocalDate) -> some View {
        let selected = day == date, isToday = day == today, future = day > today
        let parts = Self.parts(of: day, timeZone: timeZone)
        return Button {
            withAnimation(.snappy) { date = day }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(spacing: 6) {
                Text(parts.weekday).font(.exSmall.weight(.semibold))
                    .foregroundStyle(selected ? Color.exPrimaryText : Color.exTextMuted)
                ZStack {
                    Circle().stroke(Color.exPrimary.opacity(future ? 0.06 : 0.16), lineWidth: 3)
                    if let value = fraction(day), value < 0 {
                        Circle().stroke(Color.exTextMuted.opacity(0.55), lineWidth: 3)
                    } else if let value = fraction(day) {
                        Circle().trim(from: 0, to: min(max(value, 0.02), 1))
                            .stroke(value > 1.05 ? Color.exAccent : Color.exPrimary,
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    if selected { Circle().fill(Color.exActionFill).padding(5) }
                    Text(parts.day).font(.system(.subheadline, design: .rounded, weight: selected || isToday ? .bold : .medium))
                        .foregroundStyle(selected ? Color.white : future ? Color.exTextMuted : Color.exTextPrimary)
                        .minimumScaleFactor(0.6).lineLimit(1)
                }
                .frame(width: typeSize.isAccessibilitySize ? 44 : 38, height: typeSize.isAccessibilitySize ? 44 : 38)
                Circle().fill(isToday ? Color.exAccent : .clear).frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isToday ? "Today, " : "")\(parts.full)")
        .accessibilityValue(fraction(day).map { $0 < 0 ? "Food logged" : "\(Int(($0 * 100).rounded())) percent of calorie target" } ?? "Nothing logged")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("today.day.\(day)")
    }


    private static func parts(of date: LocalDate, timeZone: TimeZone) -> (weekday: String, day: String, full: String) {
        let noon = NutritionFormat.pickerDate(date, timeZone: timeZone)
        var style = Date.FormatStyle.dateTime.weekday(.narrow)
        style.timeZone = timeZone
        var full = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
        full.timeZone = timeZone
        return (noon.formatted(style), String(date.day), noon.formatted(full))
    }
}

/// The day's calories as a ring, with the three macros beside it and any
/// pinned nutrients under them. Each leads with what's left, or with what's
/// eaten when the person prefers that, and an overage reads "+12 over".
struct TodayNutritionCard: View {
    let progress: DayProgress
    /// Lead with what's eaten rather than what's left (Your details).
    var leadsWithEaten = false
    /// Opens targets for a day without them; nil for a past day, which
    /// only shows what was eaten.
    let onSetTargets: (() -> Void)?
    /// The pinned nutrients' day, under the macros.
    var pinned: [NutrientDay] = []
    var onPinned: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title) private var ringSize: CGFloat = 116

    var body: some View {
        ExCard {
            if progress.hasTargets {
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.content))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: ExSpacing.page))
                layout {
                    ringButton
                    VStack(spacing: ExSpacing.item) {
                        TodayMacroLine(title: "Protein", progress: progress.protein, color: .exPrimaryText, eaten: leadsWithEaten)
                        TodayMacroLine(title: "Carbs", progress: progress.carbohydrate, color: .exAccent, eaten: leadsWithEaten)
                        TodayMacroLine(title: "Fat", progress: progress.fat, color: .exSecondary, eaten: leadsWithEaten)
                    }
                }
                if !pinned.isEmpty {
                    TargetsDivider()
                    TodayPinnedNutrients(days: pinned, open: onPinned)
                }
                if [progress.energy, progress.protein, progress.carbohydrate, progress.fat].contains(where: { $0.unreported > 0 }) {
                    Text("Some labels omit nutrients, so totals may be low.")
                        .font(.exSmall).foregroundStyle(Color.exTextSecondary)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.number(progress.energy.consumed)).font(.exStat).foregroundStyle(Color.exTextPrimary)
                        .contentTransition(.numericText())
                    Text("kcal eaten").font(.exBody).foregroundStyle(Color.exTextSecondary)
                }
                if let onSetTargets {
                    Button("Set calorie and macro targets", systemImage: "target", action: onSetTargets)
                        .font(.exLabel).foregroundStyle(Color.exPrimaryText).frame(minHeight: 44)
                        .accessibilityIdentifier("today.setTargets")
                } else {
                    Text("No targets on this day").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                        .accessibilityIdentifier("today.noTargets")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if progress.hasTargets { onSetTargets?() } }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open targets") { onSetTargets?() }
    }

    /// The ring opens targets, so it is a real button: it says so to
    /// VoiceOver and gives under a finger.
    @ViewBuilder private var ringButton: some View {
        let energy = progress.energy, left = Self.left(energy)
        let eaten = "\(Self.number(energy.consumed)) eaten of \(Self.number(energy.target ?? 0))."
        let spoken = leadsWithEaten ? "\(eaten) \(left.amount) \(left.words)." : "\(left.amount) \(left.words). \(eaten)"
        if let onSetTargets {
            Button(action: onSetTargets) { ring }
                .buttonStyle(TodayPressStyle())
                .accessibilityLabel("Calories")
                .accessibilityValue(spoken)
                .accessibilityHint("Opens targets")
                .accessibilityIdentifier("nutrition.targetEnergy")
        } else {
            ring
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Calories")
                .accessibilityValue(spoken)
                .accessibilityIdentifier("nutrition.targetEnergy")
        }
    }

    private var ring: some View {
        let energy = progress.energy, left = Self.left(energy)
        let target = Self.number(energy.target ?? 0)
        // The leading figure, its words, and the line under them.
        let (figure, words, detail) = leadsWithEaten
            ? (Self.number(energy.consumed), "kcal eaten", left.over ? "\(left.amount) over" : "of \(target)")
            : (left.amount, "kcal \(left.words)", "\(Self.number(energy.consumed)) / \(target)")
        return ZStack {
            Circle().stroke(Color.exPrimary.opacity(0.14), lineWidth: 11)
            Circle().trim(from: 0, to: min(energy.fraction ?? 0, 1))
                .stroke(AngularGradient(colors: [.exPrimary, .exSecondary, .exAccent, .exPrimary], center: .center),
                        style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.snappy, value: energy.fraction)
            VStack(spacing: 0) {
                Text(figure)
                    .font(.system(.title, design: .rounded, weight: .bold)).monospacedDigit()
                    .foregroundStyle(left.over && !leadsWithEaten ? Color.exAccent : Color.exTextPrimary)
                    .contentTransition(.numericText()).minimumScaleFactor(0.6).lineLimit(1)
                    .accessibilityIdentifier("today.ring.figure")
                Text(words).font(.exSmall.weight(.medium)).foregroundStyle(Color.exTextSecondary)
                Text(detail).font(.exSmall).monospacedDigit().minimumScaleFactor(0.8).lineLimit(1)
                    .foregroundStyle(left.over && leadsWithEaten ? Color.exAccent : Color.exTextMuted).padding(.top, 2)
            }.padding(14)
        }
        .frame(width: ringSize, height: ringSize)
        .contentShape(Circle())
    }

    static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) }

    /// What's left of a target, or how far past it, signed, as the ring
    /// says it: ("57", "left") until a whole unit over, then ("+12", "over").
    static func left(_ progress: NutrientProgress) -> (amount: String, words: String, over: Bool) {
        let over = (progress.over ?? 0).rounded() > 0
        return (over ? "+" + number(progress.over ?? 0) : number(progress.remaining ?? 0), over ? "over" : "left", over)
    }
}

/// A macro as the ring reads calories: what's left first, or how far over,
/// then what's eaten of the target; or the other way round with `eaten`.
struct TodayMacroLine: View {
    let title: String
    let progress: NutrientProgress
    let color: Color
    var eaten = false

    var body: some View {
        let left = TodayNutritionCard.left(progress)
        let consumed = TodayNutritionCard.number(progress.consumed), target = TodayNutritionCard.number(progress.target ?? 0)
        let name = Text(title).font(.exLabel).foregroundStyle(Color.exTextSecondary)
        let amount = Text(eaten ? consumed : left.amount).font(.exStatSmall)
            .foregroundStyle(left.over && !eaten ? Color.exAccent : Color.exTextPrimary)
        let words = Text(eaten ? " of \(target) g" : " g \(left.words)").font(.exCaption).foregroundStyle(Color.exTextSecondary)
        let leftText = "\(left.amount) grams \(left.words)", eatenText = "\(consumed) of \(target) grams eaten"
        VStack(alignment: .leading, spacing: 4) {
            // One line where it fits; at the largest sizes on a small phone, one under the other.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { name; Spacer(minLength: ExSpacing.small); Text("\(amount)\(words)").monospacedDigit() }
                VStack(alignment: .leading, spacing: 2) { name; Text("\(amount)\(words)").monospacedDigit() }
            }
            ExProgressBar(value: progress.consumed, total: progress.target ?? 0, color: color)
            Text(eaten ? "\(left.amount) g \(left.words)" : "\(consumed) / \(target) g").font(.exSmall).monospacedDigit()
                .foregroundStyle(left.over && eaten ? Color.exAccent : Color.exTextMuted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(eaten ? "\(eatenText), \(leftText)" : "\(leftText), \(eatenText)")
        .accessibilityIdentifier("today.macro.\(title.lowercased())")
    }
}

/// A square shortcut: an icon over a short label.
struct TodayQuickAction: View {
    let title: String
    let icon: String
    let identifier: String
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if !typeSize.isAccessibilitySize {
                    Image(systemName: icon).font(.system(size: 20, weight: .semibold)).frame(height: 24)
                        .accessibilityHidden(true)
                }
                Text(title).font(.exCaption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Color.exPrimaryText)
            // Fills its row of the shortcuts' grid at the largest sizes.
            .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 52 : 68, maxHeight: .infinity)
            .padding(.horizontal, 4)
            .background(Color.exSurface1, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.exBorder.opacity(0.5), lineWidth: 0.5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(TodayPressStyle())
        .accessibilityIdentifier(identifier)
    }
}

struct TodayPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// A food logged around this time on other days. The plus logs it again;
/// once logged it shows a check, and tapping that removes it. When the meal
/// already has it from somewhere else (a repeated meal or day), a softer
/// check says so and a tap logs nothing. VoiceOver reaches all of it from the
/// chip itself, even when its plus is off screen.
struct TodaySuggestionChip: View {
    let suggestion: FoodSuggestion
    let unit: MassUnit
    var logged = false
    /// The meal it fills, lowercased, when that meal has it already and not from this chip.
    var alreadyIn: String?
    let open: () -> Void
    let log: () -> Void
    /// "Don't suggest this", from a long press, VoiceOver's actions or the
    /// portion sheet's menu.
    let hide: () -> Void

    var body: some View {
        HStack(spacing: ExSpacing.small) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.food.name).font(.exLabel).foregroundStyle(Color.exTextPrimary).lineLimit(2)
                    Text("\(portion) · \(energy) kcal").font(.exSmall).foregroundStyle(Color.exTextSecondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(suggestion.food.name), \(portion), \(energy) calories")
            .accessibilityHint("Opens the portion before logging")
            .accessibilityAction(named: logged ? "Undo" : alreadyIn.map { "Already in \($0)" } ?? "Log \(portion)", log)
            .accessibilityAction(named: "Don't suggest this", hide)
            Button(action: log) {
                Image(systemName: logged || alreadyIn != nil ? "checkmark" : "plus").font(.system(size: 15, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(logged ? Color.exSuccess : alreadyIn != nil ? Color.exTextSecondary : .white)
                    .frame(width: 32, height: 32)
                    .background(logged ? Color.exSuccess.opacity(0.16) : alreadyIn != nil ? Color.exSurface2 : Color.exActionFill, in: Circle())
                    .frame(width: 44, height: 44).contentShape(Circle())
            }
            .buttonStyle(TodayPressStyle())
            .accessibilityLabel(logged ? "Logged \(suggestion.food.name). Undo"
                : alreadyIn.map { "\(suggestion.food.name), already in \($0)" } ?? "Log \(suggestion.food.name), \(portion)")
            .accessibilityIdentifier("today.suggestion.log.\(suggestion.food.foodID)")
        }
        .padding(.leading, ExSpacing.item).padding(.trailing, 2).padding(.vertical, 2)
        .frame(maxHeight: .infinity)
        .background(Color.exSurface1, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.exBorder.opacity(0.5), lineWidth: 0.5) }
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
        // As on Add food's usual and recent foods: what the chip does, then Don't suggest this.
        .contextMenu {
            if alreadyIn == nil {
                Button(logged ? "Undo" : "Log \(portion)", systemImage: logged ? "arrow.uturn.backward" : "plus", action: log)
            }
            Button("Details", systemImage: "info.circle", action: open)
            Button("Don't suggest this", systemImage: "eye.slash", action: hide).accessibilityIdentifier("today.suggestion.hide")
        }
    }

    private var energy: String {
        TodayNutritionCard.number(suggestion.food.per100g.energy * suggestion.grams / 100)
    }

    /// The amount, written as food search and the diary write it.
    private var portion: String {
        FoodFormat.amount(grams: suggestion.grams, serving: suggestion.serving, quantity: suggestion.quantity,
                          food: suggestion.food.foodForLogging(), unit: unit)
    }
}

/// A short confirmation above the tab bar, with an undo.
struct TodayToast: View {
    let message: String
    var failed = false
    let undo: (() -> Void)?
    var undoIdentifier = "today.undo"
    /// A row in a card, flat and edge to edge, rather than floating over the screen.
    var inline = false
    /// What the button says: Undo, or Try again on an Undo that failed.
    var action = "Undo"
    @Environment(\.dynamicTypeSize) private var typeSize

    /// "Repeated yesterday's breakfast" of "Repeated yesterday's breakfast: 2 foods, 170 kcal".
    static func headline(_ message: String) -> String { String(message.split(separator: ":", maxSplits: 1).first ?? Substring(message)) }
    private var headline: String { Self.headline(message) }

    var body: some View {
        // At the largest sizes Undo goes under the message, as in Add food's toast.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: ExSpacing.item))
        layout {
            HStack(spacing: ExSpacing.item) {
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(failed ? Color.exWarning : Color.exSuccess).accessibilityHidden(true)
                // At the largest sizes only the headline, two lines at most, so
                // the confirmation doesn't cover the controls under it; the whole
                // sentence is announced to VoiceOver and kept as its label.
                Text(typeSize.isAccessibilitySize ? headline : message).font(.exLabel).foregroundStyle(Color.exTextPrimary)
                    .lineLimit(2).minimumScaleFactor(typeSize.isAccessibilitySize ? 0.7 : 1)
                    .accessibilityLabel(message)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            if let undo {
                // Padded as Add food's toast pads it, clear of the rounded edge.
                Button(action, action: undo).font(.exLabel.weight(.semibold)).foregroundStyle(Color.exPrimaryText).fixedSize()
                    .padding(.horizontal, ExSpacing.item).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    .accessibilityIdentifier(undoIdentifier)
            }
        }
        .padding(.leading, ExSpacing.content).padding(.trailing, ExSpacing.tight).padding(.vertical, 4)
        .frame(maxWidth: inline ? .infinity : nil, minHeight: 52, alignment: .leading)
        .exToastSurface(RoundedRectangle(cornerRadius: 26, style: .continuous), shadow: !inline)
        .padding(.horizontal, inline ? 0 : ExSpacing.page)
        .accessibilityElement(children: .contain)
    }
}
