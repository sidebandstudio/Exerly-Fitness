import ExerlyCore
import SwiftUI
import UserNotifications

extension View {
    /// Keeps the workout's Live Activity, the widgets' snapshot, the watch and
    /// Spotlight in step with the open account, and clears them (and any
    /// delivered notifications) at sign-out.
    func liveSurfaces(_ account: AppAccountWorkspace, signedOut: Bool, unit: MassUnit, timeZone: TimeZone) -> some View {
        modifier(LiveSurfacesMount(account: account, workspace: account.training, signedOut: signedOut,
                                   unit: unit, timeZone: timeZone))
    }
}

private struct LiveSurfacesMount: ViewModifier {
    let account: AppAccountWorkspace
    let workspace: TrainingWorkspace?
    let signedOut: Bool
    let unit: MassUnit
    let timeZone: TimeZone
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { WorkoutActivityActions.account = account }
            .task(id: "\(workspace?.identity.uuidString ?? "")-\(unit)") {
                guard let workspace else { return }
                await WorkoutActivityCoordinator.shared.follow(workspace.store, unit: unit)
            }
            .task(id: "\(workspace?.identity.uuidString ?? "")-\(unit)-\(timeZone.identifier)") {
                guard let workspace else { return }
                await WatchCoordinator.shared.follow(workspace, unit: unit, timeZone: timeZone)
            }
            // Coming back to the app may be on a new day.
            .task(id: "\(workspace?.identity.uuidString ?? "")-\(unit)-\(timeZone.identifier)-\(scenePhase == .active)") {
                guard let workspace else { return }
                await WidgetSnapshotWriter(workspace: workspace, unit: unit, timeZone: timeZone).follow()
            }
            .task(id: "\(workspace?.identity.uuidString ?? "")-\(unit)") {
                guard let workspace else { return }
                await FoodSpotlight.follow(IntentAccess.Account(workspace: workspace, unit: unit, timeZone: timeZone))
            }
            .task(id: signedOut) {
                guard signedOut else { return }
                await WorkoutActivityCoordinator.shared.endAll()
                WidgetSnapshotWriter.clear()
                WatchCoordinator.shared.signOut()
                await FoodSpotlight.clear()
                // Log a food's phrases and Spotlight top hits name no food of theirs once they're out.
                ExerlyShortcuts.updateAppShortcutParameters()
                // Nor do Siri's suggestions, learnt from what they did through Exerly.
                await IntentDonations.clear()
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            }
            #if DEBUG
            .overlay(alignment: .topLeading) {
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") { LiveActivityReadout() }
            }
            #endif
    }
}

#if DEBUG
/// What ActivityKit holds, for UI tests: "active Upper A 1/15 resting".
private struct LiveActivityReadout: View {
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("debug.liveActivity")
            .accessibilityValue(WorkoutActivityCoordinator.shared.readout)
            .allowsHitTesting(false)
    }
}
#endif
