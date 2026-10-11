import ExerlyCore
import SwiftUI

// Purpose-built pieces for finding and logging food. Numbers come from
// ExerlyCore; these views only format and lay them out.

enum FoodFormat {
    /// Whole kilocalories, or a dash when the label doesn't report energy.
    static func kcal(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "–"
    }

    /// Grams of a macro: one decimal under 10 g, whole grams above.
    static func grams(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...(value < 10 ? 1 : 0))))
    }

    /// Any nutrient with its unit, rounded as the portion summary rounds:
    /// whole kilocalories, one decimal under 10, whole numbers above, and
    /// "<0.1" for a trace that would otherwise read as none.
    static func nutrient(_ value: Double, _ nutrient: Nutrient) -> String {
        let number = nutrient == .energy ? kcal(value) : value > 0 && value < 0.05 ? "<0.1" : grams(value)
        return "\(number) \(nutrient.unit.rawValue)"
    }

    /// What a quick portion logs, as a person would say it: "2 × Scoop · 84 g",
    /// "1 bar (40 g)", "2.5 oz" or "150 g".
    static func portion(_ portion: QuickPortion, unit: MassUnit) -> String {
        amount(grams: portion.grams, serving: portion.serving, quantity: portion.quantity,
               food: portion.food.foodForLogging(), unit: unit)
    }

    static func amount(grams: Double, serving: Serving?, quantity: Double?, food: ExerlyCore.Food, unit: MassUnit) -> String {
        guard let serving else { return "\(grams.formatted(.number.precision(.fractionLength(0...1)))) g" }
        let count = quantity ?? serving.quantity(grams: grams)
        let measure = NutritionPortionMeasure.saved(serving, food: food)
        let shown = count.formatted(.number.precision(.fractionLength(0...2)))
        if !measure.symbol.isEmpty { return "\(shown) \(measure.symbol)" }
        if statesWeight(serving.name) { return count == 1 ? serving.name : "\(shown) × \(serving.name)" }
        // Half of "1 serving" reads "0.5 serving", and two "2 servings"; two of
        // "1 banana" stay "2 × 1 banana" rather than guess at a plural.
        var name = count == 1 ? serving.name : "\(shown) × \(serving.name)"
        if count != 1, serving.name.hasPrefix("1 "), serving.name.dropFirst(2).first?.isLetter == true {
            let noun = String(serving.name.dropFirst(2))
            if count < 1 { name = "\(shown) \(noun)" } else if noun == "serving" { name = "\(shown) servings" }
        }
        return "\(name) · \(weight(grams, unit: unit))"
    }

    /// A weight in the person's units.
    static func weight(_ grams: Double, unit: MassUnit) -> String {
        if unit == .pounds {
            return "\(USUnits.ounces(grams: grams).formatted(.number.precision(.fractionLength(0...1)))) oz"
        }
        return "\(grams.formatted(.number.precision(.fractionLength(0...(grams < 10 ? 1 : 0))))) g"
    }

    /// A serving name such as "1 bar (40 g)" already says what it weighs.
    static func statesWeight(_ name: String) -> Bool {
        name.range(of: #"\d\s*(g|ml|oz)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The brand, or where a database food comes from. Nothing for a
    /// person's own unbranded food: they know where it came from.
    static func origin(of food: FoodSnapshot) -> String? {
        if let brand = food.brand, !brand.isEmpty { return brand }
        switch food.source {
        case .custom, .imported: return nil
        default: return NutritionFormat.source(food.source)
        }
    }
}

/// Protein, carbs and fat with the colours the diary uses for them.
struct FoodMacroLine: View {
    let amounts: NutrientAmounts
    var font: Font = .exCaption

    var body: some View {
        HStack(spacing: ExSpacing.item) {
            macro(.protein, "P", .exPrimaryText)
            macro(.carbohydrate, "C", .exAccent)
            macro(.fat, "F", .exSecondary)
        }.font(font).monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(FoodMacroLine.spoken(amounts))
    }

    private func macro(_ nutrient: Nutrient, _ letter: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(amounts[nutrient].map { "\(FoodFormat.grams($0))\(letter)" } ?? "–\(letter)")
                .foregroundStyle(Color.exTextSecondary)
        }
    }

    static func spoken(_ amounts: NutrientAmounts) -> String {
        [(Nutrient.protein, "protein"), (.carbohydrate, "carbs"), (.fat, "fat")].map { nutrient, name in
            amounts[nutrient].map { "\(name) \(FoodFormat.grams($0)) grams" } ?? "\(name) not reported"
        }.joined(separator: ", ")
    }
}

/// The trailing round button that logs a row's portion in one tap.
struct FoodAddButton: View {
    let done: Bool
    let label: String
    var identifier = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: done ? "checkmark" : "plus")
                .font(.system(size: 17, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(done ? Color.exSuccess : Color.exPrimaryText)
                .frame(width: 38, height: 38)
                .background(done ? Color.exSuccess.opacity(0.16) : Color.exPrimary.opacity(0.16), in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(FoodPressStyle())
            .accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}

/// One food: name, what one tap logs, its energy and macros, and a "+".
struct FoodQuickRow: View {
    let name: String
    let detail: String
    /// Nil when there's no amount yet, as for a typed amount a food can't take.
    let amounts: NutrientAmounts?
    var openHint = ""
    var openIdentifier = ""
    let open: () -> Void
    let add: FoodAddButton
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: ExSpacing.small) {
            Button(action: open) {
                Group {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: ExSpacing.tight) {
                            title
                            subtitle
                            if let amounts {
                                Text("\(FoodFormat.kcal(amounts[.energy])) kcal").font(.exStatSmall).foregroundStyle(Color.exTextPrimary)
                                FoodMacroLine(amounts: amounts)
                            }
                        }
                    } else {
                        HStack(alignment: .center, spacing: ExSpacing.item) {
                            VStack(alignment: .leading, spacing: 3) {
                                title
                                subtitle
                                if let amounts { FoodMacroLine(amounts: amounts, font: .exSmall) }
                            }
                            Spacer(minLength: 0)
                            if let amounts {
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text(FoodFormat.kcal(amounts[.energy])).font(.exStatSmall).foregroundStyle(Color.exTextPrimary)
                                    Text("kcal").font(.exSmall).foregroundStyle(Color.exTextSecondary)
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(amounts.map { "\(name), \(detail), \(FoodFormat.kcal($0[.energy])) kilocalories, \(FoodMacroLine.spoken($0))" }
                    ?? "\(name), \(detail)")
                .accessibilityHint(openHint)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier(openIdentifier)
            add
        }.padding(.vertical, 6)
    }

    private var title: some View {
        Text(name).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 2).multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var subtitle: some View {
        Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
    }
}

/// Breakfast, Lunch, Dinner and Snacks as one-tap choices; a menu at the
/// largest text sizes so the choice doesn't push the foods off screen.
struct FoodMealSelector: View {
    let meals: [String]
    @Binding var selection: String
    var identifier = "nutrition.pickerMeal"
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            Menu {
                Picker("Meal", selection: $selection) { ForEach(meals, id: \.self) { Text($0).tag($0) } }
            } label: {
                HStack {
                    Text("Log to \(selection)").font(.exBodyMedium).multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.exCaption)
                }.foregroundStyle(Color.exPrimaryText).frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityIdentifier(identifier)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: ExSpacing.small) {
                    ForEach(meals, id: \.self) { meal in
                        let selected = meal == selection
                        Button { selection = meal } label: {
                            Text(meal).font(.exLabel.weight(selected ? .semibold : .medium))
                                .padding(.horizontal, 14).frame(minHeight: 34)
                                .foregroundStyle(selected ? Color.white : Color.exTextSecondary)
                                .background(selected ? Color.exActionFill : Color.exSurface2, in: Capsule())
                                .frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel("Log to \(meal)").accessibilityInputLabels([meal, "Log to \(meal)"])
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityIdentifier("\(identifier).\(meal)")
                    }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
                .sensoryFeedback(.selection, trigger: selection)
        }
    }
}

/// A logging tool: scan a barcode, read a label, quick add, create a food.
struct FoodToolButton: View {
    let title: String
    let icon: String
    var identifier = ""
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            Group {
                if typeSize.isAccessibilitySize {
                    Label(title, systemImage: icon).font(.exBodyMedium)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).padding(.horizontal, ExSpacing.content)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: icon).font(.system(size: 20, weight: .semibold)).frame(height: 24)
                        Text(title).font(.exSmall.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }.frame(maxWidth: .infinity, minHeight: 62)
                }
            }
            .foregroundStyle(Color.exPrimaryText)
            .background(Color.exPrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(FoodPressStyle()).accessibilityIdentifier(identifier)
    }
}

struct FoodPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// The floating "Logged · Undo" confirmation, on an opaque surface: as
/// glass, the rows under it read through (run 6).
struct FoodLoggedToast: View {
    /// How far above the keyboard the search tab's floating search field
    /// reaches, plus a gap.
    static let searchFieldClearance: CGFloat = 64

    let title: String
    let detail: String
    let undo: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At the largest sizes Undo goes under the message, so neither breaks mid-word.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: ExSpacing.item))
        layout {
            HStack(spacing: ExSpacing.item) {
                Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Color.exSuccess)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.exLabel.weight(.semibold)).foregroundStyle(Color.exTextPrimary)
                    Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }.lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("nutrition.loggedConfirmation")
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: ExSpacing.small) }
            Button("Undo", action: undo).font(.exLabel.weight(.semibold)).foregroundStyle(Color.exPrimaryText).fixedSize()
                .padding(.horizontal, ExSpacing.item).frame(minHeight: 44).contentShape(Rectangle())
                .accessibilityIdentifier("nutrition.undoLog")
        }
        .padding(.leading, ExSpacing.content).padding(.trailing, ExSpacing.tight).padding(.vertical, 6)
        .exToastSurface(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, ExSpacing.page)
    }
}

/// A portion's energy as the hero number, with its macros beside it and a
/// bar of where the energy comes from.
struct FoodPortionSummary: View {
    let amounts: NutrientAmounts?
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: ExSpacing.item) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: ExSpacing.small) { hero; macros }
            } else {
                // Macros sit beside the energy when they fit, under it on a narrow phone.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .lastTextBaseline, spacing: ExSpacing.content) { hero; Spacer(minLength: 0); macros }
                    VStack(alignment: .leading, spacing: ExSpacing.small) { hero; macros }
                }
            }
            shareBar
        }
        .animation(.snappy, value: amounts)
    }

    private var hero: some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(FoodFormat.kcal(amounts?[.energy]))
                .font(.system(size: heroSize, weight: .bold, design: .rounded))
                .foregroundStyle(amounts?[.energy] == nil ? Color.exTextSecondary : Color.exTextPrimary)
                .contentTransition(.numericText()).lineLimit(1)
            Text("kcal").font(.exBodyMedium).foregroundStyle(Color.exTextSecondary)
        }.fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(FoodFormat.kcal(amounts?[.energy])) kilocalories")
            .accessibilityIdentifier("nutrition.portionEnergy")
    }

    private var macros: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: ExSpacing.content) { macroValues }
            VStack(alignment: .leading, spacing: ExSpacing.small) { macroValues }
        }
    }

    @ViewBuilder private var macroValues: some View {
        macro(.protein, "Protein", .exPrimaryText)
        macro(.carbohydrate, "Carbs", .exAccent)
        macro(.fat, "Fat", .exSecondary)
    }

    private func macro(_ nutrient: Nutrient, _ label: String, _ color: Color) -> some View {
        VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
            Text(amounts?[nutrient].map { "\(FoodFormat.grams($0)) g" } ?? "–")
                .font(.exStatSmall).foregroundStyle(Color.exTextPrimary).contentTransition(.numericText())
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(.exSmall).foregroundStyle(Color.exTextSecondary)
            }
        }.fixedSize().accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(amounts?[nutrient].map { "\(FoodFormat.grams($0)) grams" } ?? "Not reported")
    }

    @ViewBuilder private var shareBar: some View {
        let shares = amounts?.macroEnergyShares ?? [:]
        let parts = [(Nutrient.protein, Color.exPrimaryText), (.carbohydrate, .exAccent), (.fat, .exSecondary), (.alcohol, .exTextMuted)]
            .compactMap { nutrient, color in shares[nutrient].flatMap { $0 > 0 ? (nutrient, color, $0) : nil } }
        if !parts.isEmpty {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { _, color, share in
                        Capsule().fill(color)
                            .frame(width: max(3, (geometry.size.width - CGFloat(parts.count - 1) * 2) * share))
                    }
                }
            }.frame(height: 6).accessibilityHidden(true)
        }
    }
}

/// A compact sheet that still shows the primary action without scrolling,
/// on a small phone as on a large one.
struct FoodSheetDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? { min(context.maxDetentValue, 640) }
}

/// Puts the cursor in a UIKit text field, found by its accessibility
/// identifier, once the screen has settled: the first thing to type is ready.
struct FirstResponderOnAppear: UIViewRepresentable {
    let identifier: String

    func makeUIView(context: Context) -> Probe { Probe(identifier: identifier) }
    func updateUIView(_ uiView: Probe, context: Context) {}

    final class Probe: UIView {
        let identifier: String
        private var didFocus = false

        init(identifier: String) {
            self.identifier = identifier
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, !didFocus else { return }
            didFocus = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, let window = self.window else { return }
                Self.field(self.identifier, in: window)?.becomeFirstResponder()
            }
        }

        private static func field(_ identifier: String, in view: UIView) -> UITextField? {
            if let field = view as? UITextField, field.accessibilityIdentifier == identifier { return field }
            for child in view.subviews { if let found = field(identifier, in: child) { return found } }
            return nil
        }
    }
}
