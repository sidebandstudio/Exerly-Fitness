import SwiftUI

extension EnvironmentValues {
    /// Scrolls a sign-in page to a field by its title, to keep it above the keyboard.
    @Entry var authReveal: (String) -> Void = { _ in }
}

/// The Exerly mark on its tile, lifted by a soft purple glow.
struct ExerlyMarkTile: View {
    var size: CGFloat = 72

    var body: some View {
        Image("ExerlyMark").resizable().scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .shadow(color: Color.exPrimary.opacity(0.35), radius: size * 0.28, y: size * 0.1)
            .accessibilityHidden(true)
    }
}

/// First-run backdrop: Exerly's purple and pink glowing out of the dark.
struct AuthBackdrop: View {
    var intensity: Double = 1

    var body: some View {
        ZStack {
            Color.exBackground
            RadialGradient(colors: [Color.exPrimary.opacity(0.32 * intensity), .clear],
                           center: UnitPoint(x: 0.15, y: -0.05), startRadius: 0, endRadius: 460)
            RadialGradient(colors: [Color.exAccent.opacity(0.2 * intensity), .clear],
                           center: UnitPoint(x: 1.0, y: 0.12), startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The brand pulse, drawn once in purple to pink.
struct AuthPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        PulseLineShape()
            .trim(from: 0, to: drawn || reduceMotion ? 1 : 0)
            .stroke(LinearGradient(colors: [Color.exPrimary.opacity(0), Color.exPrimary, Color.exAccent, Color.exAccent.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.4).delay(0.2)) { drawn = true }
            }
    }
}

/// A sign-in field: a symbol, the field, and for passwords a show button.
/// The field's accessibility label is its title.
/// Whether sign-in fields offer password autofill. UI tests sign in without
/// it: the system's offer to save the synthetic password can arrive late,
/// from outside the app, and cover whatever the test taps next.
private let offersAutofill: Bool = {
    #if DEBUG
    !ProcessInfo.processInfo.arguments.contains("--ui-testing")
    #else
    true
    #endif
}()

struct AuthField<Field: Hashable>: View {
    enum Kind { case name, email, code, password, newPassword }

    let title: String
    let kind: Kind
    @Binding var text: String
    let field: Field
    var focus: FocusState<Field?>.Binding
    var submitLabel: SubmitLabel = .next
    var onSubmit: () -> Void = {}
    @State private var revealed = false
    @Environment(\.authReveal) private var reveal

    private var icon: String {
        switch kind {
        case .name: "person"
        case .email: "envelope"
        case .code: "number"
        case .password, .newPassword: "lock"
        }
    }

    var body: some View {
        HStack(spacing: ExSpacing.item) {
            Image(systemName: icon).font(.body.weight(.medium))
                .foregroundStyle(focus.wrappedValue == field ? Color.exPrimaryText : Color.exTextSecondary)
                .frame(width: 22).accessibilityHidden(true)
            input
                .font(.exBody).foregroundStyle(Color.exTextPrimary)
                .focused(focus, equals: field)
                .submitLabel(submitLabel)
                .onSubmit(onSubmit)
                .frame(maxWidth: .infinity, minHeight: 52)
            if kind == .password || kind == .newPassword {
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye").font(.body)
                        .foregroundStyle(Color.exTextSecondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(revealed ? "Hide password" : "Show password")
            }
        }
        .padding(.leading, ExSpacing.content).padding(.trailing, ExSpacing.tight)
        .background(Color.exSurface1, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(focus.wrappedValue == field ? Color.exPrimary : Color.exBorder.opacity(0.7),
                              lineWidth: focus.wrappedValue == field ? 1.5 : 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = field }
        .id(title)
        .onChange(of: focus.wrappedValue == field) { _, focused in
            if focused { reveal(title) }
        }
        .animation(.snappy(duration: 0.2), value: focus.wrappedValue == field)
    }

    @ViewBuilder private var input: some View {
        let prompt = Text(title).foregroundColor(.exTextMuted)
        switch kind {
        case .name:
            TextField(title, text: $text, prompt: prompt)
                .textContentType(.name).textInputAutocapitalization(.words).autocorrectionDisabled()
        case .email:
            TextField(title, text: $text, prompt: prompt)
                .textContentType(offersAutofill ? .username : nil).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        case .code:
            TextField(title, text: $text, prompt: Text("ABCD-EFGH").foregroundColor(.exTextMuted))
                .textContentType(.oneTimeCode).keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .monospaced()
                // The prompt shows the code's shape; the label says what it is.
                .accessibilityLabel(title)
        case .password, .newPassword:
            Group {
                if revealed { TextField(title, text: $text, prompt: prompt) }
                else { SecureField(title, text: $text, prompt: prompt) }
            }
            // A new password gets no content type: the system's strong-password
            // sheet replaces what the person typed and can't be dismissed in tests.
            .textContentType(kind == .newPassword || !offersAutofill ? nil : .password)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }
}

/// The back button over a first-run page.
struct AuthBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.exTextPrimary)
                .frame(width: 44, height: 44)
                .background(Color.exSurface1.opacity(0.9), in: Circle())
                .overlay { Circle().strokeBorder(Color.exBorder.opacity(0.5), lineWidth: 0.5) }
                .contentShape(Circle())
        }
        .buttonStyle(TodayPressStyle())
        .accessibilityLabel("Back")
        .padding(.leading, ExSpacing.page)
        .padding(.top, ExSpacing.tight)
    }
}

/// "or" between the email form and Sign in with Apple.
struct AuthDivider: View {
    var body: some View {
        HStack(spacing: ExSpacing.item) {
            Rectangle().fill(Color.exBorder.opacity(0.7)).frame(height: 0.5)
            Text("or").font(.exCaption).foregroundStyle(Color.exTextSecondary)
            Rectangle().fill(Color.exBorder.opacity(0.7)).frame(height: 0.5)
        }
        .accessibilityHidden(true)
    }
}

/// A first-run page: the mark, a title and a line, then the form.
struct AuthPage<Content: View>: View {
    let title: String
    let detail: String
    let onBack: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            AuthBackdrop(intensity: 0.6)
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: ExSpacing.content) {
                    ExerlyMarkTile(size: 56).padding(.bottom, ExSpacing.small)
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
                .frame(maxWidth: 480, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, ExSpacing.section)
                .padding(.top, ExSpacing.small)
                .padding(.bottom, ExSpacing.major)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .safeAreaBar(edge: .top, alignment: .leading) {
                AuthBackButton(action: onBack)
            }
            .environment(\.authReveal) { id in
                // After the keyboard has changed the safe area.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            }
        }
    }
}

/// "New to Exerly? Create an account": a question with a link-styled answer.
struct AuthSwitchLink: View {
    let question: String
    let action: String
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            let answer = Text(action).foregroundStyle(Color.exPrimaryText).fontWeight(.semibold)
            Text("\(Text(question).foregroundStyle(Color.exTextSecondary)) \(answer)")
                .font(.exLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(question) \(action)")
    }
}
