import ExerlyCore
import SwiftUI

/// A one-time offer to read weigh-ins from a smart scale through Apple Health.
/// Mount it after onboarding or on the Body screen: it shows only for the open
/// account, while weigh-ins from Health are off and the offer is unanswered,
/// and never on a device without Health.
struct HealthWeighInPrompt: View {
    @ObservedObject private var sync = HealthSync.shared

    var body: some View {
        if sync.isAvailable, let accountID = sync.accountID, !sync.preferences.promptDismissed,
           !sync.preferences.isOn(.readWeights) {
            Offer(accountID: accountID).id(accountID)
        }
    }
}

/// The offer for one account, whose weigh-ins its preview reads.
private struct Offer: View {
    @ObservedObject private var sync = HealthSync.shared
    @StateObject private var history: HealthHistoryModel
    @Environment(\.dynamicTypeSize) private var typeSize

    init(accountID: String) {
        _history = StateObject(wrappedValue: HealthHistoryModel(accountID: accountID))
    }

    var body: some View {
        ExCard(accent: true) {
            HStack(alignment: .top, spacing: ExSpacing.item) {
                if !typeSize.isAccessibilitySize {
                    Image(systemName: "scalemass.fill").font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.exPrimaryText).frame(width: 44, height: 44)
                        .background(Color.exPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: ExRadius.control))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: ExSpacing.tight) {
                    Text("Use weigh-ins from your scale via Apple Health").font(.exBodyMedium)
                        .foregroundStyle(Color.exTextPrimary).accessibilityAddTraits(.isHeader)
                    Text("If your smart scale saves to Health, each reading arrives here on its own, with body fat when the scale measures it.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }.fixedSize(horizontal: false, vertical: true)
            }
            if let notice = sync.notices[.readWeights] {
                Label(notice, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: ExSpacing.small))
                : AnyLayout(HStackLayout(spacing: ExSpacing.small))
            layout {
                Button {
                    Task { await history.begin(.weights) }
                } label: {
                    if sync.requesting == .readWeights || history.requesting != nil { ProgressView().tint(.white) } else { Text("Turn on") }
                }
                .buttonStyle(ExActionStyle())
                .disabled(sync.requesting != nil || history.requesting != nil)
                .accessibilityIdentifier("health.prompt.turnOn")
                Button("Not now") { sync.dismissPrompt() }
                    .buttonStyle(ExActionStyle(secondary: true))
                    .accessibilityIdentifier("health.prompt.notNow")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("health.prompt")
        .sheet(item: $history.pending) { pending in
            HealthImportPreviewSheet(pending: pending, onImport: { _ in
                Task {
                    await history.confirm()
                    if sync.preferences.isOn(.readWeights) { sync.dismissPrompt() }
                }
            }, onCancel: history.cancel)
        }
    }
}

/// A day's steps and active Calories from Health, as one quiet line, for
/// context. Shows only with Read activity on and data for the day. It never
/// feeds expenditure, which comes from intake and weight.
struct HealthActivityLine: View {
    let date: LocalDate
    let timeZone: TimeZone
    @AppStorage private var enabled: Bool
    @State private var activity: HealthActivity?
    @Environment(\.scenePhase) private var scenePhase

    init(accountID: String, date: LocalDate, timeZone: TimeZone) {
        self.date = date
        self.timeZone = timeZone
        _enabled = AppStorage(wrappedValue: false, HealthReadModel.key(accountID: accountID))
    }

    var body: some View {
        if enabled {
            Group {
                if let activity, let text = Self.text(activity) {
                    Label {
                        Text(text)
                    } icon: {
                        Image(systemName: "figure.walk").accessibilityHidden(true)
                    }
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.spoken(activity))
                    .accessibilityIdentifier("health.activityLine")
                } else {
                    Color.clear.frame(height: 0).accessibilityHidden(true)
                }
            }
            .task(id: "\(date)-\(scenePhase == .active)") {
                activity = await HealthKitService.shared.activity(on: date, timeZone: timeZone)
            }
        }
    }

    static func text(_ activity: HealthActivity) -> String? {
        var parts: [String] = []
        if let steps = activity.steps { parts.append("\(steps.formatted()) steps") }
        if let kcal = activity.activeKilocalories { parts.append("\(kcal.formatted()) active kcal") }
        return parts.isEmpty ? nil : (parts + ["Apple Health"]).joined(separator: " · ")
    }

    static func spoken(_ activity: HealthActivity) -> String {
        var parts: [String] = []
        if let steps = activity.steps { parts.append("\(steps.formatted()) steps") }
        if let kcal = activity.activeKilocalories { parts.append("\(kcal.formatted()) active kilocalories") }
        return "From Apple Health: " + parts.joined(separator: ", ")
    }
}
