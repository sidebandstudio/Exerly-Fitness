import ExerlyCore
import SwiftUI

/// The Profile tab: who you are and your body numbers, goals and reminders,
/// your plan, then everything else grouped by what you'd come here to do.
struct ProfileView: View {
    /// Changes each time the tab is entered from another one; the screen
    /// returns to its top, as tabs do.
    var entered = 0
    @EnvironmentObject private var authVM: AuthViewModel
    @EnvironmentObject private var account: AppAccountWorkspace
    @EnvironmentObject private var dailySync: SyncEngine
    @ObservedObject private var notifications = NotificationService.shared
    @AppStorage("exerlyAppearance") private var appearance = "dark"
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showEditProfile = false
    @State private var showChangePassword = false
    @State private var changingUnits = false
    @State private var unitsError: String?
    @State private var position = ScrollPosition(edge: .top)

    private var user: UserDTO? { authVM.currentUser }
    private var accountID: String { user?.id ?? "" }
    private var unit: MassUnit { user?.unitSystem == "metric" ? .kilograms : .pounds }
    private var timeZone: TimeZone { TimeZone(identifier: user?.timezone ?? "UTC") ?? .gmt }
    private var workspace: TrainingWorkspace? {
        guard let workspace = account.training, workspace.accountID == user?.id else { return nil }
        return workspace
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ExSpacing.section) {
                ProfileIdentityCard(name: user?.name?.isEmpty == false ? user?.name ?? "" : "Your profile",
                                    email: user?.email ?? "", workspace: workspace, user: user, unit: unit,
                                    timeZone: timeZone) { showEditProfile = true }
                goalsAndReminders
                NavigationLink {
                    TargetsHostView(accountID: accountID, unit: unit, timeZone: timeZone)
                } label: {
                    ProfilePlanCard(workspace: workspace, unit: unit, timeZone: timeZone)
                }
                .buttonStyle(TodayPressStyle())
                .accessibilityLabel("Your plan")
                .accessibilityValue(ProfilePlanCard.spoken(workspace: workspace, timeZone: timeZone))
                .accessibilityHint("Opens your calorie and macro targets")
                .accessibilityIdentifier("profile.targets")
                food
                connections
                preferences
                data
                signOut
                footer
            }
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ExSpacing.page)
            .padding(.top, ExSpacing.small)
            .padding(.bottom, ExSpacing.major)
        }
        .scrollPosition($position)
        // Animated, so the large title comes back as it does when scrolling up by hand.
        .onChange(of: entered) { _, _ in withAnimation(.snappy) { position.scrollTo(edge: .top) } }
        .scrollIndicators(.hidden)
        .exScrollEdges()
        .background(Color.exBackground)
        .accessibilityIdentifier("profile.screen")
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showEditProfile) {
            EditProfileView().environmentObject(authVM)
        }
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordView()
        }
    }

    // MARK: Groups

    /// Above the plan, so both are in reach without scrolling on an SE too;
    /// under it they sat behind the tab bar (run 6).
    private var goalsAndReminders: some View {
        ProfileSection(title: "Goals and reminders") {
            if let workspace {
                NavigationLink {
                    NutrientGoalsView(workspace: workspace, timeZone: timeZone)
                } label: {
                    ProfileRow(title: "Nutrient goals", icon: "chart.bar.doc.horizontal", subtitle: goalsSummary(workspace))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile.nutrientGoals")
            }
            NavigationLink { RemindersView() } label: {
                ProfileRow(title: "Reminders", icon: "bell.badge", subtitle: remindersSummary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("profile.reminders")
        }
    }

    private var food: some View {
        ProfileSection(title: "Food") {
            NavigationLink {
                NutritionLibraryHostView(accountID: accountID, timeZone: timeZone, unit: unit)
            } label: {
                ProfileRow(title: "Foods & recipes", icon: "fork.knife", subtitle: foodsSummary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("profile.foods")
        }
    }

    private var connections: some View {
        ProfileSection(title: "Connections") {
            NavigationLink(destination: HealthKitSettingsView(accountID: authVM.currentUser?.id ?? "")) {
                ProfileRow(title: "Apple Health", icon: "heart.fill", tint: .exAccent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Apple Health")
            if let api = authVM.accountAPI {
                NavigationLink {
                    AgentConnectionsView(api: api, hasPassword: authVM.signInMethods?.password != false).id(api.accountID)
                } label: {
                    ProfileRow(title: "Connected agents", icon: "key.fill", subtitle: "Let an AI assistant read and propose changes")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile.agents")
            }
        }
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            ProfileSection(title: "Preferences") {
                ProfileControlRow(title: "Units", icon: "ruler") {
                    HStack(spacing: ExSpacing.small) {
                        if changingUnits { ProgressView().controlSize(.small) }
                        ExSegmentedControl(values: ["imperial", "metric"], selection: Binding(
                            get: { user?.unitSystem == "metric" ? "metric" : "imperial" },
                            set: setUnits
                        )) { $0 == "metric" ? "Metric" : "U.S." }
                        .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 190)
                        .disabled(changingUnits || user == nil)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Units")
                    .accessibilityIdentifier("profile.units")
                }
                ProfileControlRow(title: "Appearance", icon: "circle.lefthalf.filled") {
                    ExSegmentedControl(values: ["dark", "light", "system"], selection: $appearance) { $0.capitalized }
                        .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 240)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Appearance")
                        .accessibilityIdentifier("profile.appearance")
                }
                Button { showEditProfile = true } label: {
                    ProfileRow(title: "Your details", icon: "person.text.rectangle",
                               subtitle: "Name, body, food, training and sleep")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile.details")
            }
            if let unitsError {
                Label(unitsError, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exError)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, ExSpacing.tight)
                    .accessibilityIdentifier("profile.unitsError")
            }
        }
    }

    private var data: some View {
        ProfileSection(title: "Account & data") {
            if let workspace {
                NavigationLink {
                    AccountSyncView(workspace: workspace)
                } label: {
                    ProfileRow(title: "Sync", icon: "arrow.triangle.2.circlepath", value: syncStatus(workspace))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile.sync")
            }
            if let workspace {
                NavigationLink {
                    MacroFactorImportView(workspace: workspace, unit: unit, timeZone: timeZone)
                } label: {
                    ProfileRow(title: "Import from MacroFactor", icon: "square.and.arrow.down",
                               subtitle: "Food log, weigh-ins and workouts")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile.macroFactorImport")
            }
            if let id = user?.id {
                NavigationLink {
                    AccountManagementView(accountID: id, email: user?.email ?? "",
                                          actions: account.actions(auth: authVM, accountID: id))
                } label: {
                    ProfileRow(title: "Account", icon: "person.crop.circle", subtitle: "Sign-in, export your data, delete account")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile.account")
            }
            if authVM.signInMethods?.password != false {
                Button { showChangePassword = true } label: {
                    ProfileRow(title: "Change password", icon: "lock.fill")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile.password")
            }
            if user?.isAdmin == true {
                NavigationLink(destination: AdminView().environmentObject(authVM)) {
                    ProfileRow(title: "Admin", icon: "shield.checkered", subtitle: "Accounts and usage")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var signOut: some View {
        Button(role: .destructive) { Task { await account.signOut(auth: authVM) } } label: {
            Text("Sign Out").font(.exBodyMedium).foregroundStyle(Color.exError)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.exSurface1, in: RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous)
                        .strokeBorder(Color.exBorder.opacity(0.5), lineWidth: 0.5)
                }
        }
        .buttonStyle(TodayPressStyle())
        .disabled(account.isChangingAccount)
        .accessibilityIdentifier("profile.logout")
    }

    private var footer: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        return Text("Exerly \(version) · © Sideband")
            .font(.exCaption).foregroundStyle(Color.exTextMuted)
            .frame(maxWidth: .infinity)
    }

    // MARK: Values

    private var foodsSummary: String {
        guard let foods = workspace?.nutrition.foods, !foods.isEmpty else { return "Save foods and recipes you eat often" }
        return foods.count == 1 ? "1 saved food" : "\(foods.count) saved foods"
    }

    /// Whose goals they are, and how many show on Today.
    private func goalsSummary(_ workspace: TrainingWorkspace) -> String {
        let plan = workspace.nutrition.plan(on: LocalDate(Date(), in: timeZone))
        let custom = plan?.nutrientGoals?.count ?? 0, pinned = plan?.pinnedNutrients?.count ?? 0
        let goals = custom == 0 ? "Daily values" : custom == 1 ? "1 of your own" : "\(custom) of your own"
        return pinned == 0 ? goals : "\(goals) · \(pinned) on Today"
    }

    /// The first reminder iOS holds, in words, and how many more.
    private var remindersSummary: String {
        let lines = ReminderWords.lines(notifications.scheduled)
        guard let first = lines.first else { return "Meals, workouts, sleep and weigh-ins" }
        return lines.count == 1 ? first : "\(first) and \(lines.count - 1) more"
    }

    private func syncStatus(_ workspace: TrainingWorkspace) -> String {
        if dailySync.attentionCount > 0 { return "Needs review" }
        if dailySync.isSyncing { return "Syncing…" }
        switch workspace.sync?.state {
        case .syncing: return "Syncing…"
        case .offline: return "Saved on this iPhone"
        case .failed: return "Needs attention"
        default: break
        }
        if dailySync.isOffline || dailySync.pendingCount > 0 { return "Saved on this iPhone" }
        return workspace.sync?.lastSyncedAt == nil ? "" : "Up to date"
    }

    private func setUnits(_ system: String) {
        guard system != user?.unitSystem, !changingUnits, let user else { return }
        changingUnits = true
        unitsError = nil
        Task {
            defer { changingUnits = false }
            do {
                try await authVM.updateSettings(timezone: user.timezone ?? TimeZone.current.identifier, unitSystem: system)
                UISelectionFeedbackGenerator().selectionChanged()
            } catch is CancellationError {
            } catch {
                unitsError = "Units didn't change. Connect to the internet and try again."
            }
        }
    }
}
