import SwiftUI

/// Today's cards in the order the person chose, and which they hid. Saved on
/// this device for each account, as "quickActions,-water,…" with a hidden
/// card marked "-".
struct TodayLayout: Equatable {
    enum Card: String, CaseIterable, Identifiable {
        case quickActions, nutrition, training, weight, water, meals

        var id: String { rawValue }

        var title: String {
            switch self {
            case .quickActions: "Quick actions"
            case .nutrition: "Calories and macros"
            case .training: "Training"
            case .weight: "Weight trend"
            case .water: "Water"
            case .meals: "Meals"
            }
        }

        var icon: String {
            switch self {
            case .quickActions: "square.grid.2x2"
            case .nutrition: "chart.pie"
            case .training: "dumbbell"
            case .weight: "scalemass"
            case .water: "drop"
            case .meals: "fork.knife"
            }
        }
    }

    var order: [Card]
    var hidden: Set<Card>

    static let standard = TodayLayout(order: Card.allCases, hidden: [])

    init(order: [Card], hidden: Set<Card>) {
        self.order = order
        self.hidden = hidden
    }

    /// Unknown names are dropped, and a card the text doesn't name goes where
    /// the standard order puts it: after the card before it there.
    init(_ text: String) {
        var order: [Card] = [], hidden: Set<Card> = []
        for part in text.split(separator: ",") {
            let hide = part.hasPrefix("-")
            guard let card = Card(rawValue: String(hide ? part.dropFirst() : part)), !order.contains(card) else { continue }
            order.append(card)
            if hide { hidden.insert(card) }
        }
        for (index, card) in Card.allCases.enumerated() where !order.contains(card) {
            let before = Card.allCases[..<index].last { order.contains($0) }
            order.insert(card, at: before.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        }
        self.init(order: order, hidden: hidden)
    }

    var text: String { order.map { hidden.contains($0) ? "-\($0.rawValue)" : $0.rawValue }.joined(separator: ",") }
    var visible: [Card] { order.filter { !hidden.contains($0) } }

    /// The layout with `card` moved one place up (negative) or down.
    func moving(_ card: Card, by offset: Int) -> TodayLayout {
        guard let index = order.firstIndex(of: card), order.indices.contains(index + offset) else { return self }
        var layout = self
        layout.order.swapAt(index, index + offset)
        return layout
    }

    /// The per-account key the layout is saved under.
    static func key(accountID: String) -> String { "today.layout.v1.\(accountID)" }
}

/// Show, hide and reorder Today's cards, and choose whether calories and
/// macros lead with what's left or what's eaten. The day's status, note and
/// links stay at the bottom, and the day strip at the top.
struct TodayCustomizeView: View {
    @Binding var layout: TodayLayout
    @EnvironmentObject private var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The move arrows grow with the text, so at the largest sizes they don't sit tiny under it.
    @ScaledMetric(relativeTo: .body) private var scaledArrow: CGFloat = 14
    private var arrowSize: CGFloat { min(scaledArrow, 28) }

    var body: some View {
        NavigationStack {
            List {
                // Where run 7 looked for it first, rather than only in Your details.
                if let accountID = auth.currentUser?.id {
                    TodayDisplayChoice(accountID: accountID, auth: auth).id("\(auth.sessionID):\(accountID)")
                }
                Section {
                    ForEach(layout.order) { card in row(card) }
                } footer: {
                    Text("Hidden cards come back here. The day strip stays at the top, and the day's status and note at the bottom.")
                }
                if layout != .standard {
                    Section {
                        Button("Reset to the standard layout") { withAnimation(.snappy) { layout = .standard } }
                            .foregroundStyle(Color.exPrimaryText).frame(minHeight: 44)
                            .accessibilityIdentifier("today.customize.reset")
                    }
                }
            }
            .exListStyle()
            .navigationTitle("Customize Today").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold).accessibilityIdentifier("today.customize.done")
                }
            }
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }

    private func row(_ card: Card) -> some View {
        let index = layout.order.firstIndex(of: card) ?? 0
        let shown = Binding(get: { !layout.hidden.contains(card) }, set: { show in
            withAnimation(.snappy) { if show { layout.hidden.remove(card) } else { layout.hidden.insert(card) } }
        })
        let moves = HStack(spacing: 0) {
            move(card, by: -1, icon: "arrow.up", label: "Move \(card.title) up", disabled: index == 0)
            move(card, by: 1, icon: "arrow.down", label: "Move \(card.title) down", disabled: index == layout.order.count - 1)
        }
        let toggle = Toggle(isOn: shown) {
            Label(card.title, systemImage: card.icon).font(.exBody)
                .foregroundStyle(shown.wrappedValue ? Color.exTextPrimary : Color.exTextMuted)
        }
        .toggleStyle(ExRowToggleStyle())
        .tint(Color.exActionFill)
        .accessibilityLabel("Show \(card.title)")
        .accessibilityIdentifier("today.customize.show.\(card.rawValue)")
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: ExSpacing.small) { toggle; moves }
            } else {
                HStack(spacing: ExSpacing.small) { moves; toggle }
            }
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .contain)
    }

    private typealias Card = TodayLayout.Card

    private func move(_ card: Card, by offset: Int, icon: String, label: String, disabled: Bool) -> some View {
        Button {
            withAnimation(.snappy) { layout = layout.moving(card, by: offset) }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Image(systemName: icon).font(.system(size: arrowSize, weight: .semibold))
                .foregroundStyle(disabled ? Color.exTextMuted.opacity(0.4) : Color.exPrimaryText)
                .frame(width: max(44, arrowSize * 2), height: max(44, arrowSize * 2)).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier("today.customize.\(offset < 0 ? "up" : "down").\(card.rawValue)")
    }
}

/// Whether Today's calories and macros lead with what's left or what's
/// eaten: the account's preference, which Your details also shows, kept on
/// this iPhone the moment it's chosen and sent on its own.
private struct TodayDisplayChoice: View {
    @ObservedObject private var quick: QuickPreferences
    @State private var eaten: Bool

    init(accountID: String, auth: AuthViewModel) {
        let quick = QuickPreferences.signedIn(accountID: accountID, auth: auth)
        self.quick = quick
        _eaten = State(initialValue: quick.leadsWithEaten(auth.currentUser))
    }

    var body: some View {
        Section {
            ExSegmentedControl(values: [false, true], selection: Binding(get: { eaten }, set: choose)) {
                $0 ? "What you've eaten" : "What's left"
            }
            .accessibilityIdentifier("today.customize.display")
            if let error = quick.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exError)
                    .accessibilityIdentifier("today.customize.displayError")
            } else if quick.isWaitingForConnection && quick.isUnsent("nutritionDisplay") {
                Text(QuickPreferences.waitingNote).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    .accessibilityIdentifier("today.customize.displayNote")
            }
        } header: {
            Text("Calories and macros show")
        }
    }

    private func choose(_ value: Bool) {
        guard value != eaten else { return }
        eaten = value
        quick.set("nutritionDisplay", .string(value ? "consumed" : "remaining"))
    }
}
