import ExerlyCore
import SwiftUI

/// The meal being eaten now, as it was logged last time: the first chip on
/// Log again, one tap for all of it. Once logged it shows a check, and a
/// second tap takes it back, as a food chip does.
struct TodayRepeatChip: View {
    /// "Yesterday's breakfast".
    let title: String
    let repeated: MealRepeat
    var logged = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ExSpacing.small) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.exLabel).foregroundStyle(Color.exTextPrimary).lineLimit(2)
                    Text(detail).font(.exSmall).foregroundStyle(Color.exTextSecondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                Image(systemName: logged ? "checkmark" : "arrow.counterclockwise").font(.system(size: 15, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(logged ? Color.exSuccess : .white)
                    .frame(width: 32, height: 32)
                    .background(logged ? Color.exSuccess.opacity(0.16) : Color.exActionFill, in: Circle())
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
            .padding(.leading, ExSpacing.item).padding(.trailing, 2).padding(.vertical, 2)
            .frame(maxHeight: .infinity)
            .background(Color.exPrimary.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.exPrimary.opacity(0.35), lineWidth: 0.5) }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(TodayPressStyle())
        .accessibilityLabel(logged ? "Repeated \(title). Undo"
            : "Repeat \(title), \(Self.foods(repeated.entries.count)), \(TodayNutritionCard.number(repeated.energy)) calories")
        .accessibilityIdentifier("today.repeatMeal")
    }

    private var detail: String {
        "\(Self.foods(repeated.entries.count)) · \(TodayNutritionCard.number(repeated.energy)) kcal"
    }

    static func foods(_ count: Int) -> String { "\(count) \(count == 1 ? "food" : "foods")" }
}

/// All of an earlier day, or the meals of it today hasn't logged yet, in one
/// tap: beside Log again's title when there are chips, else a row of its own.
struct TodayRepeatDayButton: View {
    /// "yesterday", or a weekday.
    let source: String
    let repeated: MealRepeat
    /// True once today has food: what's repeated is the rest of the day.
    let rest: Bool
    var row = false
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            if row {
                HStack(spacing: ExSpacing.item) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 32, height: 32).background(Color.exActionFill, in: Circle()).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.exLabel).foregroundStyle(Color.exTextPrimary)
                        Text(detail).font(.exSmall).foregroundStyle(Color.exTextSecondary)
                            .lineLimit(typeSize.isAccessibilitySize ? 4 : 1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, ExSpacing.item).padding(.vertical, ExSpacing.small).frame(minHeight: 56)
                .background(Color.exPrimary.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(Rectangle())
            } else {
                Label(title, systemImage: "arrow.counterclockwise").font(.exLabel.weight(.semibold))
                    .foregroundStyle(Color.exPrimaryText).multilineTextAlignment(.leading)
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
        }
        .buttonStyle(TodayPressStyle())
        .accessibilityLabel("\(rest ? "Repeat the rest of \(source)" : "Repeat all of \(source)"), \(meals), "
            + "\(TodayRepeatChip.foods(repeated.entries.count)), \(TodayNutritionCard.number(repeated.energy)) calories")
        .accessibilityIdentifier("today.repeatDay")
    }

    private var title: String { rest ? "Rest of \(source)" : "Repeat \(source)" }

    /// The meals it logs, in diary order, lowercased: "lunch, dinner and snacks".
    private var meals: String {
        let present = Set(repeated.entries.map(\.meal))
        let names = (NutritionStore.defaultMeals.filter(present.contains) + present.subtracting(NutritionStore.defaultMeals).sorted())
            .map { $0.lowercased() }
        return names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    private var detail: String {
        let meals = self.meals
        return meals.prefix(1).uppercased() + meals.dropFirst()
            + " · \(TodayRepeatChip.foods(repeated.entries.count)) · \(TodayNutritionCard.number(repeated.energy)) kcal"
    }
}
