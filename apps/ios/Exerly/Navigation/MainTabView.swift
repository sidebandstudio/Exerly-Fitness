import SwiftUI
import ExerlyCore

enum MainTab: Hashable {
    case today, training, progress, profile, search
}

/// A link from a widget, control or intent, held until the signed-in tabs
/// follow it: after a launch for it, they appear a moment later.
@MainActor
final class ExerlyLinkRouter: ObservableObject {
    static let shared = ExerlyLinkRouter()
    @Published var pending: URL?

    /// Lets the controls' intents, run in the app's process, open their screen.
    static func install() {
        ExerlyLinkHandler.open = { shared.pending = $0 }
    }
}

struct MainTabView: View {
    @EnvironmentObject private var sync: SyncEngine
    @EnvironmentObject private var auth: AuthViewModel
    @EnvironmentObject private var account: AppAccountWorkspace
    @ObservedObject private var links = ExerlyLinkRouter.shared
    @State private var selectedTab: MainTab = .today
    /// Counts returns to the Profile tab, which then starts from its top.
    @State private var profileEntries = 0
    /// Counts taps on the Today tab while it shows, which take it back to today.
    @State private var todayReselections = 0
    /// Scan barcode or Weigh in, for Today to open.
    @State private var todayLink: URL?
    /// A recipe file someone shared, opened in Exerly, to review and save.
    @State private var sharedRecipe: SharedRecipe?
    @State private var sharedRecipeUnreadable = false

    private struct SharedRecipe: Identifiable {
        let id = UUID()
        let recipe: RecipeImport
    }

    private var unit: MassUnit { auth.currentUser?.unitSystem == "metric" ? .kilograms : .pounds }
    private var timeZone: TimeZone { TimeZone(identifier: auth.currentUser?.timezone ?? "UTC") ?? .gmt }

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("Today", systemImage: "house", value: .today) {
                NavigationStack {
                    if let id = auth.currentUser?.id {
                        TodayHostView(accountID: id, unit: unit, timeZone: timeZone, link: $todayLink,
                                      reselected: todayReselections) { selectedTab = .training }
                    }
                }
            }
            Tab("Train", systemImage: "dumbbell", value: .training) {
                NavigationStack {
                    if let id = auth.currentUser?.id {
                        TrainingHostView(accountID: id, unit: unit, timeZone: timeZone)
                    }
                }
            }
            Tab("Progress", systemImage: "chart.line.uptrend.xyaxis", value: .progress) {
                NavigationStack { ProgressView_(initialDate: sync.today) }
            }
            Tab("Profile", systemImage: "person.crop.circle", value: .profile) {
                NavigationStack { ProfileView(entered: profileEntries) }
            }
            Tab("Log food", systemImage: "magnifyingglass", value: .search, role: .search) {
                if let id = auth.currentUser?.id {
                    FoodSearchTab(accountID: id, unit: unit, timeZone: timeZone)
                }
            }
        }
        .modifier(LiveWorkoutAccessory(store: account.training?.store, hidden: selectedTab == .training) {
            selectedTab = .training
        })
        .onChange(of: selectedTab) { old, new in
            if new == .profile, old != .profile { profileEntries += 1 }
        }
        .tint(Color.exPrimaryText)
        .environment(\.accountTimeZone, timeZone)
        // Widgets, controls and the workout's Live Activity open their screen.
        .task(id: "\(links.pending?.absoluteString ?? "")-\(account.training?.identity.uuidString ?? "")") { follow() }
        .sheet(item: $sharedRecipe) { shared in
            if let workspace = account.training, let api = auth.accountAPI {
                RecipeEditor(workspace: workspace, api: api, timeZone: timeZone, unit: unit, imported: shared.recipe)
            }
        }
        .alert("This recipe file can't be read", isPresented: $sharedRecipeUnreadable) {
            Button("OK", role: .cancel) {}
        } message: { Text("It may be damaged, or from a newer version of Exerly.") }
    }

    /// The selected tab; a tap on the one already showing reaches here too.
    private var tabSelection: Binding<MainTab> {
        Binding(get: { selectedTab }, set: { tab in
            if tab == .today, selectedTab == .today { todayReselections += 1 }
            selectedTab = tab
        })
    }

    private func follow() {
        guard let url = links.pending else { return }
        switch url {
        case ExerlyLinks.today: selectedTab = .today
        case ExerlyLinks.train: selectedTab = .training
        case ExerlyLinks.search: selectedTab = .search
        case ExerlyLinks.scan, ExerlyLinks.weighIn:
            selectedTab = .today
            todayLink = url
        case ExerlyLinks.startWorkout:
            // Waits for the account's data, then does what Today's Start does.
            guard let workspace = account.training, workspace.accountID == auth.currentUser?.id else { return }
            if workspace.store.activeSession == nil, (try? workspace.startNextWorkout(timeZone: timeZone, unit: unit)) == true {
                Task { await workspace.synchronize() }
            }
            selectedTab = .training
        case _ where url.isFileURL && url.pathExtension.lowercased() == RecipeFile.fileExtension:
            // Waits for the account's data, so the copy is saved to it.
            guard let workspace = account.training, workspace.accountID == auth.currentUser?.id else { return }
            do { sharedRecipe = SharedRecipe(recipe: try RecipeShareItem.read(url)) } catch { sharedRecipeUnreadable = true }
        case _ where ExerlyLinks.foodID(in: url) != nil:
            selectedTab = .today
            todayLink = url
        default: break
        }
        links.pending = nil
    }
}

extension EnvironmentValues {
    /// The account's time zone, for screens deep in a stack that only need
    /// to compare against it.
    @Entry var accountTimeZone: TimeZone = .current
}

/// The workout in progress above the tab bar on every other tab, like a
/// now-playing bar. Tapping it returns to the workout.
private struct LiveWorkoutAccessory: ViewModifier {
    let store: TrainingStore?
    let hidden: Bool
    let open: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: store?.activeSession != nil && !hidden) {
                if let store {
                    Button(action: open) { ActiveWorkoutAccessory(store: store) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Returns to the workout")
                        .accessibilityIdentifier("workout.accessory")
                }
            }
        } else { content }
    }
}

/// Food search as a tab, so a food is two taps from anywhere.
private struct FoodSearchTab: View {
    let accountID: String
    let unit: MassUnit
    let timeZone: TimeZone
    @EnvironmentObject private var account: AppAccountWorkspace
    @EnvironmentObject private var auth: AuthViewModel

    var body: some View {
        if let workspace = account.training, workspace.accountID == accountID,
           let api = auth.accountAPI, api.accountID == accountID {
            FoodSearchTabContent(workspace: workspace, api: api, unit: unit, timeZone: timeZone)
                .id(workspace.identity)
        } else { ProgressView("Opening foods…") }
    }
}

private struct FoodSearchTabContent: View {
    let workspace: TrainingWorkspace
    let api: AccountAPI
    let unit: MassUnit
    let timeZone: TimeZone
    @StateObject private var actions: NutritionDiaryActions

    init(workspace: TrainingWorkspace, api: AccountAPI, unit: MassUnit, timeZone: TimeZone) {
        self.workspace = workspace
        self.api = api
        self.unit = unit
        self.timeZone = timeZone
        _actions = StateObject(wrappedValue: NutritionDiaryActions(store: workspace.nutrition))
    }

    var body: some View {
        NutritionFoodPicker(workspace: workspace, api: api, date: LocalDate(Date(), in: timeZone),
                            meal: workspace.nutrition.suggestedMeal(at: .now, timeZone: timeZone),
                            timeZone: timeZone, unit: unit, actions: actions, onLogged: {}, presentation: .tab)
    }
}
