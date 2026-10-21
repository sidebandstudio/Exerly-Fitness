import ExerlyCore
import SwiftUI
import SwiftData

struct RootView: View {
    @AppStorage("exerlyAppearance") private var appearance = "dark"
    @StateObject private var authVM = AuthViewModel()
    @StateObject private var sync = SyncEngine.shared
    @StateObject private var account = AppAccountWorkspace()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            #if DEBUG
            if let mode = ProcessInfo.processInfo.environment["EXERLY_TEST_ACCOUNT_CONTROLS"] {
                AccountControlsFixtureView(mode: mode)
            } else { accountContent }
            #else
            accountContent
            #endif
        }
        .tint(Color.exPrimaryText)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        // Kept until the signed-in tabs can follow it, so a link that launched the app isn't lost.
        .onOpenURL { ExerlyLinkRouter.shared.pending = $0 }
        .onAppear(perform: openFromCache)
    }

    /// A saved session starts opening what's on this device as the root view
    /// appears (PARITY B03): the cached account and its saved entries here,
    /// its history read off the main actor, instead of in the tasks below, a
    /// frame or more later. The tasks then find them open or opening, and the
    /// server is asked after.
    private func openFromCache() {
        authVM.restoreCachedSession()
        guard authVM.authState == .authenticated, let user = authVM.currentUser, let api = authVM.accountAPI else { return }
        sync.configure(container: modelContext.container, accountID: user.id, timeZone: user.timezone)
        // Opening the account itself reads its history off the main actor.
        Task { await account.configure(api) }
    }

    private var accountContent: some View {
        VStack(spacing: 0) {
            accountNotices
            Group {
                switch authVM.authState {
                case .loading:
                    LoadingStateView(message: "Starting Exerly...")
                case .connectionFailed:
                    VStack(spacing: 16) {
                        Text("Connection unavailable").font(.title2)
                        Text(authVM.error ?? "Your session is saved. Try connecting again.")
                            .multilineTextAlignment(.center)
                        Button("Try again") { Task { await authVM.checkAuth() } }
                            .buttonStyle(.borderedProminent).tint(Color.exActionFill)
                        Button("Sign out") { Task { await account.signOut(auth: authVM) } }
                    }.padding()
                case .unauthenticated:
                    AuthRouter()
                case .onboarding:
                    OnboardingWizard().id(authVM.currentUser?.id)
                case .authenticated:
                    if sync.isConfigured(for: authVM.currentUser?.id) {
                        MainTabView().id(authVM.currentUser?.id)
                    } else { LoadingStateView(message: "Opening saved entries…") }
                }
            }
        }
        .animation(.easeOut(duration: 0.3), value: authVM.authState == .authenticated)
        .environmentObject(authVM)
        .environmentObject(sync)
        .environmentObject(account)
        .healthSync(account.training, timeZone: authVM.currentUser?.timezone)
        .liveSurfaces(account, signedOut: authVM.authState == .unauthenticated,
                      unit: authVM.currentUser?.unitSystem == "metric" ? .kilograms : .pounds,
                      timeZone: TimeZone(identifier: authVM.currentUser?.timezone ?? "UTC") ?? .gmt)
        .disabled(account.isChangingAccount)
        .overlay {
            if account.isChangingAccount {
                ProgressView("Updating account…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task(id: "\(authVM.currentUser?.id ?? "")-\(authVM.currentUser?.timezone ?? "UTC")") {
            sync.configure(container: modelContext.container, accountID: authVM.currentUser?.id,
                           timeZone: authVM.currentUser?.timezone)
            await account.retryCleanup(auth: authVM)
        }
        .task(id: account.training?.identity) {
            guard let workspace = account.training else { return }
            // Phrases that name a usual food are built from the account's foods.
            ExerlyShortcuts.updateAppShortcutParameters()
            await SetupWeighIn.recordIfPending(workspace)
            // Meal reminders name the meal the account usually logs at their time.
            await NotificationService.shared.reschedule()
        }
        .task(id: authVM.accountsAwaitingLocalCleanup) {
            await account.retryCleanup(auth: authVM)
        }
        .task(id: "\(authVM.authState)-\(authVM.currentUser?.id ?? "")-\(authVM.sessionID)") {
            await account.configure(authVM.authState == .authenticated ? authVM.accountAPI : nil)
        }
        .task(id: "\(account.training?.identity.uuidString ?? "")-\(scenePhase)") {
            guard scenePhase == .active, let workspace = account.training else { return }
            while !Task.isCancelled {
                await workspace.synchronize()
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
            }
        }
        .task(id: "\(authVM.authState)-\(authVM.currentUser?.id ?? "")-\(authVM.currentUser?.preferencesRevision ?? 0)") {
            await NotificationService.shared.refresh(accountID: authVM.authState == .authenticated ? authVM.currentUser?.id : nil)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                sync.refreshCalendarDay()
                Task { await sync.synchronize(force: true) }
                Task { await NotificationService.shared.refresh(accountID: authVM.authState == .authenticated ? authVM.currentUser?.id : nil) }
            }
        }
    }

    @ViewBuilder
    private var accountNotices: some View {
        if let message = account.cleanupError {
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.callout)
                Button("Retry cleanup") { Task { await account.retryCleanup(auth: authVM) } }
            }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
        }
        if authVM.isOffline && authVM.currentUser != nil {
            HStack(spacing: ExSpacing.small) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "person.crop.circle")
                        .font(.exCaption)
                        .foregroundStyle(Color.exTextSecondary)
                        .accessibilityHidden(true)
                }
                Text("Saved account").font(.exCaption)
                    .foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Showing saved account details.")
                Spacer(minLength: ExSpacing.small)
                Button("Retry") { Task { await authVM.checkAuth() } }
                    .font(.exCaption.weight(.semibold)).frame(minWidth: 44, minHeight: 44)
            }.padding(.horizontal, ExSpacing.page).background(Color.exBackground)
        }
    }
}
