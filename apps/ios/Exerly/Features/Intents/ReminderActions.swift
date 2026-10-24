import ExerlyCore
import Foundation
import UserNotifications

/// What a reminder's buttons do. Logging buttons run in the background
/// through the intents' actions (see IntentAccess), then a quiet notification
/// says what was saved, or why nothing was. The others open the app on a
/// link, as the controls do.
@MainActor
enum ReminderActions {
    enum Action: Equatable {
        /// Today's first Log again chip at the reminder's "HH:mm", into the meal.
        case logUsual(meal: String, time: String)
        /// Yesterday's meal, copied to today.
        case repeatMeal(String)
        /// A weight typed into the notification.
        case logWeight(String)
        /// The same reminder again in `minutes`, without opening anything.
        case remindAgain(minutes: Int)
        case open(URL)
    }

    /// What to show after a logging button: no title when it went through.
    struct Notice: Equatable {
        var title = ""
        var body: String
    }

    static let workoutCategory = "exerly.workout", weighInCategory = "exerly.weighIn", sleepCategory = "exerly.sleep"
    /// A reminder shown again later. Outside "exerly.reminder.", so
    /// rescheduling the reminders leaves it while its reminder stays.
    static let againPrefix = "exerly.again."
    #if DEBUG
    /// A UI test's reminder delay, in seconds, carried by the reminder.
    static let testDelayKey = "testDelay"
    #endif
    static func mealCategory(_ meal: String) -> String { "exerly.meal.\(meal)" }

    /// The buttons of each kind of reminder. Logging asks for an unlocked
    /// phone, as the intents do; Remind me again changes nothing, so it
    /// works from the Lock Screen as it is.
    static var categories: Set<UNNotificationCategory> {
        func button(_ id: String, _ title: String, _ icon: String, opens: Bool = false) -> UNNotificationAction {
            UNNotificationAction(identifier: id, title: title, options: opens ? .foreground : .authenticationRequired,
                                 icon: UNNotificationActionIcon(systemImageName: icon))
        }
        let meals = ["Breakfast", "Lunch", "Dinner", "Snacks"].map { meal in
            UNNotificationCategory(identifier: mealCategory(meal), actions: [
                button("logUsual", "Log usual \(meal == "Snacks" ? "snack" : meal.lowercased())", "checkmark.circle"),
                button("repeat", "Repeat yesterday's \(meal.lowercased())", "arrow.counterclockwise"),
                button("search", "Search", "magnifyingglass", opens: true),
            ], intentIdentifiers: [])
        }
        let weight = UNTextInputNotificationAction(identifier: "logWeight", title: "Log weight", options: .authenticationRequired,
                                                   icon: UNNotificationActionIcon(systemImageName: "scalemass"),
                                                   textInputButtonTitle: "Log", textInputPlaceholder: "Weight")
        return Set(meals + [
            UNNotificationCategory(identifier: workoutCategory, actions: [
                button("startWorkout", "Start workout", "figure.strengthtraining.traditional", opens: true),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: weighInCategory, actions: [weight], intentIdentifiers: []),
            UNNotificationCategory(identifier: sleepCategory, actions: [
                UNNotificationAction(identifier: "remindAgain", title: "Remind me in 15 minutes", options: [],
                                     icon: UNNotificationActionIcon(systemImageName: "moon.zzz")),
            ], intentIdentifiers: []),
        ])
    }

    /// The action a response asks for; nil for a dismissal, or a tap that
    /// just opens the app.
    static func action(_ identifier: String, category: String, info: [String: String], text: String?) -> Action? {
        switch identifier {
        case "logUsual": info["meal"].map { .logUsual(meal: $0, time: info["time"] ?? "") }
        case "repeat": info["meal"].map(Action.repeatMeal)
        case "logWeight": .logWeight(text ?? "")
        case "remindAgain": .remindAgain(minutes: 15)
        case "search": .open(ExerlyLinks.search)
        // The Start workout intent's path: today's workout, started on Train.
        case "startWorkout": .open(ExerlyLinks.startWorkout)
        case UNNotificationDefaultActionIdentifier where category == weighInCategory: .open(ExerlyLinks.weighIn)
        default: nil
        }
    }

    /// Runs an action from the reminder `id`. Opening ones hand the app their
    /// link; logging ones say how it went.
    static func perform(_ action: Action, reminder id: String, content: UNNotificationContent? = nil, access: IntentAccess? = nil,
                        namespace: String = APIClient.shared.storageNamespace, now: Date = .now,
                        add: (UNNotificationRequest) async throws -> Void = { try await UNUserNotificationCenter.current().add($0) },
                        remindsAgain: (String) -> Bool = { NotificationService.remindsAgain(accountID: $0) },
                        remove: ([String]) -> Void = { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: $0) })
        async -> Notice? {
        if case .open(let url) = action {
            ExerlyLinkHandler.open?(url)
            return nil
        }
        let access = access ?? IntentAccess()
        let accountID = APIClient.accountID(in: access.token)
        let original = id.hasPrefix(againPrefix) ? String(id.dropFirst(againPrefix.count)) : id
        let theirs = accountID.map { original.hasPrefix(ReminderPlan.prefix(namespace: namespace, accountID: $0)) } ?? false
        if case .remindAgain(let minutes) = action {
            // Only the signed-in account's reminders come back, while its reminders are on.
            guard theirs, let accountID, remindsAgain(accountID),
                  let copy = content?.mutableCopy() as? UNMutableNotificationContent else { return nil }
            var seconds = TimeInterval(minutes * 60)
            #if DEBUG
            if let delay = (copy.userInfo[testDelayKey] as? String).flatMap(TimeInterval.init) { seconds = delay }
            #endif
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
            try? await add(UNNotificationRequest(identifier: againPrefix + original, content: copy, trigger: trigger))
            // Signing out or turning reminders off while it was added doesn't keep it.
            if !remindsAgain(accountID) { remove([againPrefix + original]) }
            return nil
        }
        // A reminder left on this phone by another account logs nothing.
        if accountID != nil, !theirs {
            return Notice(title: "Nothing was logged", body: "That reminder was for another account. Open Exerly to log.")
        }
        do {
            return Notice(body: try await access.perform { account in
                switch action {
                case .logUsual(let meal, let time):
                    try LoggingActions.logUsual(meal, at: today(at: time, now: now, timeZone: account.timeZone), in: account)
                case .repeatMeal(let meal): try LoggingActions.repeatMeal(meal, within: 1, in: account, now: now)
                case .logWeight(let text): try LoggingActions.logWeight(try weight(text, unit: account.unit), in: account, now: now)
                case .open, .remindAgain: ""
                }
            })
        } catch {
            return Notice(title: "Nothing was logged", body: String(localized: LoggingIntentError(error).localizedStringResource))
        }
    }

    /// A weight typed in a notification, in the person's unit: "182.4",
    /// "82,5" or "182.4 lb". Its range is checked where it's logged, as on
    /// the weigh-in sheet.
    static func weight(_ text: String, unit: MassUnit) throws -> Double {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let suffix = [unit.rawValue + "s", unit.rawValue].first(where: { text.hasSuffix($0) }) {
            text = text.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
        }
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite else {
            throw LoggingIntentError.invalid("Enter a number.")
        }
        return value
    }

    /// Today at a reminder's "HH:mm" in the account's time zone; now without one.
    static func today(at time: String, now: Date, timeZone: TimeZone) -> Date {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard parts.count == 2 else { return now }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now) ?? now
    }

    /// Posts a notice without a sound, replacing the last one.
    static func post(_ notice: Notice) async {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "exerly.logged", content: content, trigger: nil))
    }
}

/// Receives reminder buttons, including after a launch in the background for one.
final class ReminderResponder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderResponder()

    @MainActor static func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        center.setNotificationCategories(ReminderActions.categories)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request, content = request.content
        let info = content.userInfo.reduce(into: [String: String]()) { info, item in
            if let key = item.key as? String, let value = item.value as? String { info[key] = value }
        }
        let identifier = response.actionIdentifier, text = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            if let action = ReminderActions.action(identifier, category: content.categoryIdentifier, info: info, text: text),
               let notice = await ReminderActions.perform(action, reminder: request.identifier, content: content) {
                await ReminderActions.post(notice)
            }
            completionHandler()
        }
    }
}
