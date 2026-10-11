import ExerlyCore
import SwiftUI

extension EnvironmentValues {
    /// Why the page can't move on yet, shown beside its button.
    @Entry var setupError: String?
    /// Scrolls the page to a field by its ID, to keep it above the keyboard.
    @Entry var setupReveal: (String) -> Void = { _ in }
}

/// A setup page: a title, one line on why it's asked, the questions, and a
/// pinned button that moves on.
struct SetupPage<Content: View>: View {
    let title: String
    let detail: String
    let action: String
    var identifier = "setup.continueWeek"
    var actionDisabled = false
    /// Hides the button until the page has something to act on.
    var showsAction = true
    var busy: String?
    let perform: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.setupError) private var error

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: ExSpacing.content) {
                VStack(alignment: .leading, spacing: ExSpacing.small) {
                    Text(title).font(.exH1).foregroundStyle(Color.exTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(detail).font(.exBody).foregroundStyle(Color.exTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, ExSpacing.small)
                content
            }
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ExSpacing.page)
            .padding(.top, ExSpacing.small)
            .padding(.bottom, ExSpacing.section)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
        .exScrollEdges()
        .environment(\.setupReveal) { id in
            // After the keyboard has changed the safe area.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .exFooter {
            VStack(spacing: ExSpacing.small) {
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.exLabel).foregroundStyle(Color.exError)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("setup.error")
                        .transition(.opacity)
                }
                if let busy { ProgressView(busy).font(.exCaption) }
                if showsAction {
                    Button(action: perform) { Text(action) }
                        .buttonStyle(ExActionStyle())
                        .disabled(actionDisabled)
                        .accessibilityIdentifier(identifier)
                }
            }
            .frame(maxWidth: 600)
            .padding(.horizontal, ExSpacing.page)
            .padding(.top, ExSpacing.item)
            .padding(.bottom, ExSpacing.small)
            .frame(maxWidth: .infinity)
            .background(Color.exBackground)
            .animation(.snappy, value: error)
        }
        }
    }
}

/// A small label above a group of questions.
struct SetupLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.exLabel.weight(.semibold)).foregroundStyle(Color.exTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, ExSpacing.small)
    }
}

/// One choice of several: an optional symbol, a title, a line of detail and
/// a check. The whole row is one button.
struct SetupChoiceRow<Leading: View>: View {
    let title: String
    var detail: String?
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var leading: Leading
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            HStack(spacing: ExSpacing.item) {
                if !typeSize.isAccessibilitySize { leading }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                    if let detail {
                        Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                Spacer(minLength: ExSpacing.small)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.exPrimaryText : Color.exTextMuted.opacity(0.6))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, ExSpacing.content).padding(.vertical, ExSpacing.item)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(selected ? Color.exPrimary.opacity(0.12) : Color.exSurface1,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? Color.exPrimary.opacity(0.7) : Color.exBorder.opacity(0.5),
                                  lineWidth: selected ? 1.5 : 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(TodayPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: selected) { _, new in new }
    }
}

extension SetupChoiceRow where Leading == EmptyView {
    init(title: String, detail: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.init(title: title, detail: detail, selected: selected, action: action) { EmptyView() }
    }
}

/// A symbol on a tinted tile, for choice rows.
struct SetupSymbol: View {
    let name: String
    var selected = false

    var body: some View {
        Image(systemName: name).font(.system(size: 17, weight: .semibold))
            .foregroundStyle(selected ? Color.white : Color.exPrimaryText)
            .frame(width: 40, height: 40)
            .background(selected ? Color.exActionFill : Color.exPrimary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A grouped card of rows separated by hairlines.
struct SetupRows<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 {
                        Rectangle().fill(Color.exBorder.opacity(0.5)).frame(height: 0.5)
                            .padding(.leading, ExSpacing.content).accessibilityHidden(true)
                    }
                    row
                }
            }
        }
        .background(Color.exSurface1, in: RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous)
                .strokeBorder(Color.exBorder.opacity(0.5), lineWidth: 0.5)
        }
    }
}

/// A question on one row: its name on the left and its control on the
/// right, or stacked at accessibility sizes.
struct SetupRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.small))
            : AnyLayout(HStackLayout(alignment: .center, spacing: ExSpacing.item))
        layout {
            Text(title).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            if !typeSize.isAccessibilitySize { Spacer(minLength: ExSpacing.small) }
            control
        }
        .padding(.horizontal, ExSpacing.content).padding(.vertical, ExSpacing.small)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    }
}

/// A number typed in the person's unit. The text is theirs while they type;
/// a valid number is passed on at each change, and an empty or unreadable
/// field passes nil so the page can say what's missing.
struct SetupNumberField: View {
    let label: String
    let unit: String
    let value: Double
    var digits = 1
    var integer = false
    var width: CGFloat = 96
    let commit: (Double?) -> Void
    @State private var text = ""
    /// The value shown while the field is empty: the number before editing.
    @State private var prompt = "0"
    @State private var clearing = false
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .title2) private var scaledWidth: CGFloat = 96
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.setupReveal) private var reveal

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ExSpacing.tight) {
            TextField(label, text: $text, prompt: Text(prompt).foregroundColor(.exTextMuted))
                .keyboardType(integer ? .numberPad : .decimalPad)
                .font(.exStatMedium).monospacedDigit()
                .foregroundStyle(Color.exTextPrimary)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .accessibilityLabel(label)
                .frame(minWidth: 44)
            if !unit.isEmpty {
                Text(unit).font(.exBodyMedium).foregroundStyle(Color.exTextSecondary)
                    .fixedSize().accessibilityHidden(true)
            }
        }
        .padding(.horizontal, ExSpacing.item)
        .frame(width: typeSize.isAccessibilitySize ? nil : max(width, scaledWidth * width / 96))
        .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
        .frame(minHeight: 48)
        .background(Color.exSurface2, in: RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous)
                .strokeBorder(focused ? Color.exPrimary : .clear, lineWidth: 1.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .id(label)
        .onAppear { text = Self.format(value, digits: integer ? 0 : digits) }
        .onChange(of: value) { _, new in
            if !focused { text = Self.format(new, digits: integer ? 0 : digits) }
            else if text.isEmpty { prompt = Self.format(new, digits: integer ? 0 : digits) }
        }
        .onChange(of: text) { _, new in
            if clearing { clearing = false; return }
            guard focused else { return }
            commit(UserEnteredNumber.parse(new))
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                // Typing replaces the number, as in a picker; the old one
                // stays visible as the prompt and returns if nothing is typed.
                prompt = text.isEmpty ? "0" : text
                if !text.isEmpty { clearing = true; text = "" }
                reveal(label)
            } else {
                prompt = "0"
                text = Self.format(value, digits: integer ? 0 : digits)
            }
        }
    }

    static func format(_ value: Double, digits: Int) -> String {
        guard value > 0 else { return "" }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(0...digits)))
    }
}

/// Minus and plus around a whole number, for age.
struct SetupStepper: View {
    let label: String
    let value: Int
    let range: ClosedRange<Int>
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: ExSpacing.small) {
            step(-1, symbol: "minus", label: "Decrease \(label.lowercased())")
            SetupNumberField(label: label, unit: "", value: Double(value), integer: true, width: 64) { number in
                set(number.map { Int($0) } ?? 0)
            }
            step(1, symbol: "plus", label: "Increase \(label.lowercased())")
        }
    }

    private func step(_ amount: Int, symbol: String, label: String) -> some View {
        Button {
            set(min(max(value + amount, range.lowerBound), range.upperBound))
        } label: {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(Color.exPrimaryText)
                .frame(width: 44, height: 44)
                .background(Color.exSurface2, in: Circle())
        }
        .buttonStyle(TodayPressStyle())
        .accessibilityLabel(label)
        .disabled(!range.contains(value + amount))
    }
}

/// Chips that each switch on or off, wrapping onto new lines.
struct SetupToggleChips<Item: Hashable>: View {
    let items: [Item]
    let isOn: (Item) -> Bool
    let title: (Item) -> String
    let toggle: (Item) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let columns = typeSize.isAccessibilitySize ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 140), spacing: ExSpacing.small)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: ExSpacing.small) {
            ForEach(items, id: \.self) { item in
                let on = isOn(item)
                Button { toggle(item) } label: {
                    HStack(spacing: ExSpacing.small) {
                        Image(systemName: on ? "checkmark" : "plus").font(.caption.weight(.bold))
                            .accessibilityHidden(true)
                        Text(title(item)).font(.exLabel).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(on ? Color.white : Color.exTextPrimary)
                    .padding(.horizontal, ExSpacing.item)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(on ? Color.exActionFill : Color.exSurface2,
                                in: RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(TodayPressStyle())
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
