import ExerlyCore
import SwiftUI

struct TodayHostView: View {
    let accountID: String
    let unit: MassUnit
    let timeZone: TimeZone
    @Binding var link: URL?
    /// Taps on the Today tab while it shows.
    var reselected = 0
    let showTraining: () -> Void
    @EnvironmentObject private var account: AppAccountWorkspace
    @EnvironmentObject private var auth: AuthViewModel

    var body: some View {
        Group {
            if let workspace = account.training, workspace.accountID == accountID,
               let api = auth.accountAPI, api.accountID == accountID {
                TodayView(workspace: workspace, api: api, unit: unit, timeZone: timeZone, link: $link, reselected: reselected,
                          showTraining: showTraining)
                    .id(workspace.identity)
            } else if account.openingError != nil {
                ContentUnavailableView {
                    Label("Today could not open", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("Your saved data is still on this device. Keep Exerly installed and try again.")
                } actions: {
                    Button("Try again") { Task { await account.configure(auth.accountAPI) } }
                        .buttonStyle(.borderedProminent).tint(Color.exActionFill)
                }
            } else { ProgressView("Opening today…") }
        }
    }
}

/// The home screen: the day's food against targets, today's workout and
/// the weigh-in, with every logging action one tap away.
struct TodayView: View {
    @ObservedObject var workspace: TrainingWorkspace
    let api: AccountAPI
    let unit: MassUnit
    let timeZone: TimeZone
    /// Scan barcode or Weigh in from a control or intent, opened once on today.
    @Binding var link: URL?
    /// Taps on the Today tab while it shows: each returns to today, at the top.
    let reselected: Int
    let showTraining: () -> Void
    @State private var date: LocalDate
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var openedOn: LocalDate
    @State private var destination: Destination?
    /// Targets push, as they do from Profile.
    @State private var showsTargets = false
    /// Nutrient goals and pins, from a pinned nutrient.
    @State private var showsGoals = false
    @State private var toast: Toast?
    @State private var plan: WorkoutPlan?
    /// "Log again" as it stood when the screen opened, so chips don't move
    /// under a finger as foods are logged. Refreshed on a new day, on
    /// returning to the app and on pull to refresh. Empty once the current
    /// meal has food.
    @State private var suggested: [FoodSuggestion]?
    /// Entries logged from those chips, by food.
    @State private var suggestionsLogged: [String: FoodEntry] = [:]
    /// This week's check-in when it waits for a decision, refreshed with "Log again".
    @State private var checkIn: TargetsCheckInCard.State?
    /// Foods chosen to copy or move together; nil when not choosing.
    @State private var selection: Set<UUID>?
    @State private var backgrounded = false
    @StateObject private var actions: NutritionDiaryActions
    @EnvironmentObject private var dailySync: SyncEngine
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase

    struct Toast: Equatable {
        enum Undo: Equatable {
            /// Removes entries just logged.
            case remove([UUID])
            /// Restores the entry the editor just deleted.
            case restoreDeleted
            /// Deletes the weigh-in just saved.
            case removeWeight(UUID)
            /// Puts moved entries back on their day and meal.
            case moveBack([FoodEntry])
            /// Suggests a hidden food again, where its chip was.
            case unhide(FoodSuggestion, Int)
        }
        let id = UUID()
        let message: String
        let undo: Undo?
        var failed = false
    }

    enum Destination: Identifiable {
        case date, add(String), scan(String), quick(String), edit(FoodEntry), log(FoodSuggestion),
             notes, copy(String?), recipe(String), nutrients, weighIn, entries(TodayEntriesDestination.Action)
        var id: String {
            switch self {
            case .date: "date"
            case .add(let meal): "add-\(meal)"
            case .scan(let meal): "scan-\(meal)"
            case .quick(let meal): "quick-\(meal)"
            case .edit(let entry): "edit-\(entry.id)"
            case .log(let suggestion): "log-\(suggestion.food.foodID)"
            case .notes: "notes"
            case .copy(let meal): "copy-\(meal ?? "day")"
            case .recipe(let meal): "recipe-\(meal)"
            case .nutrients: "nutrients"
            case .weighIn: "weighIn"
            case .entries(let action): "entries-\(action)"
            }
        }
    }

    init(workspace: TrainingWorkspace, api: AccountAPI, unit: MassUnit, timeZone: TimeZone, link: Binding<URL?>,
         reselected: Int = 0, showTraining: @escaping () -> Void) {
        self.workspace = workspace
        self.api = api
        self.unit = unit
        self.timeZone = timeZone
        _link = link
        self.reselected = reselected
        self.showTraining = showTraining
        _date = State(initialValue: LocalDate(Date(), in: timeZone))
        _openedOn = State(initialValue: LocalDate(Date(), in: timeZone))
        _actions = StateObject(wrappedValue: NutritionDiaryActions(store: workspace.nutrition))
    }

    private var store: NutritionStore { workspace.nutrition }
    private var today: LocalDate { LocalDate(Date(), in: timeZone) }
    private var isToday: Bool { date == today }
    private var currentMeal: String { store.suggestedMeal(at: .now, timeZone: timeZone) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ExSpacing.content) {
                TodayWeekStrip(date: $date, today: today, timeZone: timeZone) { day in
                    let progress = store.progress(on: day)
                    guard progress.energy.consumed > 0 else { return nil }
                    return progress.energy.fraction ?? -1
                }
                .padding(.horizontal, -ExSpacing.small)
                if dailySync.attentionCount > 0 {
                    NavigationLink { SavedChangesReviewView() } label: {
                        ExNavigationLabel(title: "Review changes", icon: "exclamationmark.arrow.triangle.2.circlepath",
                                          detail: "Something changed on another device")
                            .padding(.horizontal, ExSpacing.item)
                            .background(Color.exWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Review changes")
                }
                // The logging tools first: under the ring, a check-in or a pinned
                // nutrient put them behind an SE's tab bar (run 6).
                quickActions
                checkInBanner
                TodayNutritionCard(progress: store.progress(on: date), onSetTargets: date < today ? nil : { showsTargets = true },
                                   pinned: store.nutrientDays(store.pinnedNutrients(today: today), on: date)) { showsGoals = true }
                if isToday { suggestions }
                if let error = actions.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exError)
                }
                training
                if isToday {
                    WeightTrendCard(workspace: workspace, unit: unit, timeZone: timeZone) { destination = .weighIn }
                }
                meals
                dayFooter
            }
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ExSpacing.page)
            .padding(.top, ExSpacing.small)
            .padding(.bottom, ExSpacing.major)
        }
        .scrollPosition($scroll)
        .scrollIndicators(.hidden)
        .exScrollEdges()
        .background(Color.exBackground)
        .accessibilityIdentifier("today.screen")
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Choose a date", systemImage: "calendar") { destination = .date }
                    .accessibilityIdentifier("today.chooseDate")
            }
        }
        // Below the meals, not over them, so the last foods can be chosen too (run 6).
        .exFooter {
            if let selection {
                TodaySelectionBar(count: selection.count) { destination = .entries(.copy) } move: { destination = .entries(.move) } close: {
                    withAnimation(.snappy) { self.selection = nil }
                }
                    .background(Color.exBackground)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let toast, selection == nil {
                TodayToast(message: toast.message, failed: toast.failed, undo: toast.undo == nil ? nil : { undo(toast) },
                           undoIdentifier: undoIdentifier(toast.undo))
                    .padding(.bottom, ExSpacing.small)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        // Long enough to reach Undo, longer still with VoiceOver.
                        try? await Task.sleep(for: .seconds(UIAccessibility.isVoiceOverRunning ? 12 : 6))
                        withAnimation(.snappy) { if self.toast == toast { self.toast = nil } }
                    }
            }
        }
        .onChange(of: actions.deleted) { _, deleted in
            if let deleted { show("Removed \(deleted.food.name)", undo: .restoreDeleted) }
        }
        .refreshable {
            await workspace.synchronize()
            refreshSuggestions()
        }
        .sheet(item: $destination) { sheet($0) }
        .navigationDestination(isPresented: $showsTargets) {
            TargetsView(workspace: workspace, unit: unit, timeZone: timeZone)
        }
        .sheet(isPresented: $showsGoals) {
            NavigationStack { NutrientGoalsView(workspace: workspace, timeZone: timeZone) { showsGoals = false } }
                .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        }
        .onChange(of: showsTargets) { _, shown in if !shown { refreshCheckIn() } }
        .onAppear { if suggested == nil { refreshSuggestions() } else { refreshCheckIn() } }
        .task {
            await workspace.synchronize()
            // Synced history can change the chips; not once one was used.
            if suggestionsLogged.isEmpty { refreshSuggestions() } else { refreshCheckIn() }
        }
        .onChange(of: date) { _, _ in
            selection = nil
            refreshSuggestions()
        }
        .onChange(of: reselected) {
            date = today
            withAnimation(.snappy) { scroll.scrollTo(edge: .top) }
        }
        .task(id: link) { openLink() }
        .task(id: planKey) { plan = isToday ? workspace.nextWorkout(bodyweight: bodyweight, unit: unit) : nil }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { backgrounded = true }
            guard phase == .active else { return }
            // After midnight, a screen left on the old today moves to the new one.
            if openedOn != today {
                if date == openedOn { date = today }
                openedOn = today
            }
            if backgrounded {
                backgrounded = false
                refreshSuggestions()
            }
        }
    }

    private func openLink() {
        guard let link else { return }
        if link == ExerlyLinks.scan {
            date = today
            destination = .scan(currentMeal)
        } else if link == ExerlyLinks.weighIn {
            destination = .weighIn
        } else if let id = ExerlyLinks.foodID(in: link),
                  let portion = LoggingActions.portion(of: id, in: IntentAccess.Account(workspace: workspace, unit: unit, timeZone: timeZone)) {
            date = today
            destination = .log(FoodSuggestion(portion, meal: currentMeal))
        }
        self.link = nil
    }

    // MARK: Header

    private var title: String {
        if isToday { return "Today" }
        if date == today.adding(days: -1) { return "Yesterday" }
        var style = Date.FormatStyle.dateTime.weekday(.wide)
        style.timeZone = timeZone
        return NutritionFormat.pickerDate(date, timeZone: timeZone).formatted(style)
    }

    private var subtitle: String {
        var style = Date.FormatStyle.dateTime.month(.wide).day()
        style.timeZone = timeZone
        return NutritionFormat.pickerDate(date, timeZone: timeZone).formatted(style)
    }

    // MARK: Logging

    private var quickActions: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: ExSpacing.small)) : AnyLayout(HStackLayout(spacing: ExSpacing.small))
        return layout {
            TodayQuickAction(title: "Search", icon: "magnifyingglass", identifier: "nutrition.addFood") {
                destination = .add(defaultMeal)
            }
            TodayQuickAction(title: "Scan", icon: "barcode.viewfinder", identifier: "nutrition.scanBarcodeDirect") {
                destination = .scan(defaultMeal)
            }
            TodayQuickAction(title: "Quick add", icon: "bolt.fill", identifier: "today.quickAdd") {
                destination = .quick(defaultMeal)
            }
            TodayQuickAction(title: "Weigh in", icon: "scalemass.fill", identifier: "today.weighIn") {
                destination = .weighIn
            }
        }
    }

    /// The meal new food goes into: by habit and time today, Snacks on other days.
    private var defaultMeal: String { isToday ? currentMeal : "Snacks" }

    @ViewBuilder private var suggestions: some View {
        let items = suggested ?? []
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: ExSpacing.small) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Log again").font(.exH3).foregroundStyle(Color.exTextPrimary).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text("Usual for \(currentMeal.lowercased())").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
                ScrollView(.horizontal) {
                    HStack(spacing: ExSpacing.small) {
                        ForEach(items, id: \.food.foodID) { suggestion in
                            let logged = suggestionsLogged[suggestion.food.foodID]
                            TodaySuggestionChip(suggestion: suggestion, unit: unit, logged: logged != nil) {
                                destination = .log(suggestion)
                            } log: {
                                if let logged { unlog(logged) } else { log(suggestion) }
                            } hide: { hide(suggestion) }
                            // Two chips and a clear part of the next, so the row reads as one that scrolls.
                            .containerRelativeFrame(.horizontal, count: typeSize.isAccessibilitySize ? 5 : 7,
                                                    span: typeSize.isAccessibilitySize ? 4 : 3, spacing: ExSpacing.small)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, ExSpacing.page, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .padding(.horizontal, -ExSpacing.page)
            }
        }
    }

    private func log(_ suggestion: FoodSuggestion) {
        do {
            let meal = currentMeal
            let entry = try store.log(suggestion, on: date, meal: meal)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.snappy) { suggestionsLogged[suggestion.food.foodID] = entry }
            show("Logged \(suggestion.food.name) to \(meal)", undo: .remove([entry.id]))
            Task { await workspace.synchronize() }
        } catch { show("Could not log \(suggestion.food.name). Try again.", failed: true) }
    }

    /// A second tap on a logged chip removes what it logged.
    private func unlog(_ entry: FoodEntry) {
        do {
            // An entry edited since is left alone; its chip just resets.
            if store.entries.first(where: { $0.id == entry.id }) == entry { try store.deleteEntry(entry.id) }
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.snappy) {
                suggestionsLogged[entry.food.foodID] = nil
                if toast?.undo == .remove([entry.id]) { toast = nil }
            }
            UIAccessibility.post(notification: .announcement, argument: "Removed \(entry.food.name)")
            Task { await workspace.synchronize() }
        } catch { show("Could not remove \(entry.food.name). It is still logged.", failed: true) }
    }

    /// "Don't suggest this": the chip goes, and Undo brings it back.
    private func hide(_ suggestion: FoodSuggestion) {
        do {
            let index = suggested?.firstIndex { $0.food.foodID == suggestion.food.foodID } ?? 0
            try store.hideSuggestion(suggestion.food)
            withAnimation(.snappy) { suggested?.removeAll { $0.food.foodID == suggestion.food.foodID } }
            show("Won't suggest \(suggestion.food.name)", undo: .unhide(suggestion, index))
            Task { await workspace.synchronize() }
        } catch { show("Could not hide \(suggestion.food.name). Try again.", failed: true) }
    }

    private func refreshSuggestions() {
        // Once the meal the chips log into has food, its usual foods would log it twice.
        let mealLogged = store.entries(on: today).contains { $0.meal == currentMeal }
        suggested = mealLogged ? [] : store.suggestions(at: .now, timeZone: timeZone, limit: 10)
        suggestionsLogged = [:]
        refreshCheckIn()
    }

    private func refreshCheckIn() {
        let state = store.plan(on: today).map {
            TargetsCheckInCard.State.current(plan: $0, today: today, store: store, agent: workspace.agent, unit: unit)
        }
        checkIn = state?.needsDecision == true ? state : nil
    }

    /// A check-in waiting for a decision, one tap from Targets, where it comes first.
    @ViewBuilder private var checkInBanner: some View {
        if isToday, let checkIn {
            let (title, detail): (String, String) = switch checkIn {
            case .due(let review, _, let proposed):
                ("Weekly check-in · \(TargetsFormat.shortDate(review.date, today: today))",
                 "New targets to review: \(TargetsFormat.kcal(proposed.averageDay?.energy ?? 0)) kcal a day")
            case .cannotKeepGoal(let review):
                ("Weekly check-in · \(TargetsFormat.shortDate(review.date, today: today))", "Your goal no longer fits. Review it.")
            default: ("Weekly check-in", "Review it")
            }
            Button { showsTargets = true } label: {
                HStack(spacing: ExSpacing.item) {
                    Image(systemName: "calendar.badge.checkmark").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.exPrimaryText).frame(width: 36, height: 36)
                        .background(Color.exPrimary.opacity(0.14), in: Circle()).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                        Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.exCaption.weight(.semibold)).foregroundStyle(Color.exTextMuted)
                        .accessibilityHidden(true)
                }
                .padding(ExSpacing.item)
                .background(Color.exPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(TodayPressStyle())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the check-in")
            .accessibilityIdentifier("today.checkIn")
        }
    }

    private func show(_ message: String, undo: Toast.Undo? = nil, failed: Bool = false) {
        withAnimation(.snappy) { toast = Toast(message: message, undo: undo, failed: failed) }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func undo(_ toast: Toast) {
        switch toast.undo {
        case .remove(let ids):
            do {
                for id in ids where store.entries.contains(where: { $0.id == id }) { try store.deleteEntry(id) }
                withAnimation(.snappy) {
                    self.toast = nil
                    suggestionsLogged = suggestionsLogged.filter { !ids.contains($0.value.id) }
                }
                Task { await workspace.synchronize() }
            } catch { show("Could not undo. The entries are still logged.", failed: true) }
        case .restoreDeleted:
            withAnimation(.snappy) { self.toast = nil }
            if actions.undoDeletion() { Task { await workspace.synchronize() } }
        case .removeWeight(let id):
            do {
                if store.weights.contains(where: { $0.id == id }) { try store.deleteWeight(id) }
                withAnimation(.snappy) { self.toast = nil }
                UIAccessibility.post(notification: .announcement, argument: "Weigh-in removed")
                Task { await workspace.synchronize() }
            } catch { show("Could not undo. The weigh-in is still saved.", failed: true) }
        case .moveBack(let moved):
            do {
                // Each back to its own day and meal; one deleted since stays deleted.
                let current = moved.filter { entry in store.entries.contains { $0.id == entry.id } }
                for group in Dictionary(grouping: current, by: { "\($0.date) \($0.meal)" }).values {
                    try store.move(group.map(\.id), to: group[0].date, meal: group[0].meal)
                }
                withAnimation(.snappy) { self.toast = nil }
                Task { await workspace.synchronize() }
            } catch { show("Could not undo. The foods stay where they were moved.", failed: true) }
        case .unhide(let suggestion, let index):
            do {
                if store.isHiddenSuggestion(suggestion.food.foodID) { try store.restoreSuggestion(suggestion.food.foodID) }
                withAnimation(.snappy) {
                    self.toast = nil
                    if suggested?.contains(where: { $0.food.foodID == suggestion.food.foodID }) == false {
                        suggested?.insert(suggestion, at: min(index, suggested?.count ?? 0))
                    }
                }
                Task { await workspace.synchronize() }
            } catch { show("Could not undo. Find it in Food library to suggest it again.", failed: true) }
        case nil: break
        }
    }

    private func undoIdentifier(_ undo: Toast.Undo?) -> String {
        switch undo {
        case .restoreDeleted: "nutrition.undoDelete"
        case .removeWeight: "today.undoWeighIn"
        default: "today.undo"
        }
    }

    // MARK: Training

    private var bodyweight: Mass? { store.weights.last?.weight }

    private var planKey: String {
        "\(date)-\(workspace.programs.active?.id.uuidString ?? "")-\(workspace.store.history.sessions.count)-\(workspace.store.activeSession == nil)"
    }

    @ViewBuilder private var training: some View {
        let done = workspace.store.history.sessions.filter { $0.localDate == date && $0.endedAt != nil }
        if let session = workspace.store.activeSession, isToday {
            trainingCard(eyebrow: "Workout in progress", title: TrainingFormat.title(of: session).name,
                         detail: "\(session.exercises.flatMap(\.sets).filter(\.isCompleted).count) of \(session.exercises.flatMap(\.sets).count) sets done",
                         started: session.startedAt) {
                Button("Resume", action: showTraining).buttonStyle(ExActionStyle()).accessibilityIdentifier("today.resumeWorkout")
            }
        } else if !done.isEmpty {
            ForEach(done) { session in
                let summary = workspace.store.summary(of: session)
                trainingCard(eyebrow: "Workout done", title: TrainingFormat.title(of: session).name,
                             detail: "\(summary.workingSets) working \(summary.workingSets == 1 ? "set" : "sets") · \(TodayNutritionCard.number(summary.tonnage.total(in: unit))) \(unit == .kilograms ? "kg" : "lb") volume",
                             icon: "checkmark.circle.fill") { EmptyView() }
            }
        } else if isToday, let plan {
            trainingCard(eyebrow: plan.isDeload ? "Deload workout" : "Today's workout", title: TrainingFormat.title(plan.name, planned: true).name,
                         detail: planDetail(plan)) {
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: ExSpacing.small)) : AnyLayout(HStackLayout(spacing: ExSpacing.small))
                layout {
                    Button { start() } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(ExActionStyle()).accessibilityIdentifier("today.startWorkout")
                    Button("Preview", action: showTraining).buttonStyle(ExActionStyle(secondary: true))
                        .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 120)
                }
            }
        } else if isToday {
            trainingCard(eyebrow: "Training", title: "No workout planned", detail: "Start one now, or plan your week in Train.") {
                Button { startEmpty() } label: { Label("Start a workout", systemImage: "plus") }
                    .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("today.startEmptyWorkout")
            }
        }
    }

    private func planDetail(_ plan: WorkoutPlan) -> String {
        let names = plan.exercises.prefix(3).compactMap { workspace.store.library.exercise($0.exerciseID)?.name }
        let more = plan.exercises.count > 3 ? " +\(plan.exercises.count - 3)" : ""
        return names.joined(separator: " · ") + more
    }

    private func trainingCard<Actions: View>(eyebrow: String, title: String, detail: String, started: Date? = nil,
                                             icon: String = "dumbbell.fill", @ViewBuilder actions: () -> Actions) -> some View {
        ExCard {
            HStack(alignment: .top, spacing: ExSpacing.item) {
                if !typeSize.isAccessibilitySize {
                    Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.exPrimaryText)
                        .frame(width: 40, height: 40).background(Color.exPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        ExEyebrow(eyebrow, color: .exPrimaryText)
                        Spacer(minLength: 0)
                        if let started {
                            Text(started, style: .timer).font(.exCaption).monospacedDigit().foregroundStyle(Color.exTextSecondary)
                                .accessibilityLabel("Elapsed time")
                        }
                    }
                    Text(title).font(.exH3).foregroundStyle(Color.exTextPrimary)
                    if !detail.isEmpty {
                        Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            actions()
        }
        .accessibilityElement(children: .contain)
    }

    private func start() {
        do {
            guard try workspace.startNextWorkout(timeZone: timeZone, unit: unit) else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Task { await workspace.synchronize() }
            showTraining()
        } catch { show("The workout could not start. Your program is unchanged. Try again.", failed: true) }
    }

    private func startEmpty() {
        do {
            try workspace.store.startSession(name: "Workout", bodyweight: bodyweight, timeZone: timeZone)
            Task { await workspace.synchronize() }
            showTraining()
        } catch { show("The workout could not start. Try again.", failed: true) }
    }

    // MARK: Meals

    private var meals: some View {
        let entries = store.entries(on: date)
        let names = NutritionStore.defaultMeals + Set(entries.map(\.meal)).subtracting(NutritionStore.defaultMeals).sorted()
        let byMeal = store.summary(on: date).byMeal
        return VStack(alignment: .leading, spacing: ExSpacing.small) {
            let header = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
            header {
                Text("Meals").font(.exH3).foregroundStyle(Color.exTextPrimary).accessibilityAddTraits(.isHeader)
                if !typeSize.isAccessibilitySize { Spacer(minLength: ExSpacing.small) }
                if !entries.isEmpty {
                    Button(selection == nil ? "Select" : "Done") {
                        withAnimation(.snappy) { selection = selection == nil ? [] : nil }
                    }
                    .font(.exLabel).foregroundStyle(Color.exPrimaryText).frame(minHeight: 44)
                    .accessibilityHint(selection == nil ? "Choose foods to copy or move" : "")
                    .accessibilityIdentifier("today.select")
                } else if let day = store.repeatable(nil, for: date) {
                    Button { apply(day) } label: {
                        Label("Repeat \(dayName(day.source))", systemImage: "arrow.counterclockwise")
                            .font(.exLabel).foregroundStyle(Color.exPrimaryText).frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Repeat all of \(dayName(day.source))'s food, \(day.entries.count) foods, \(TodayNutritionCard.number(day.energy)) calories")
                    .accessibilityIdentifier("today.repeatDay")
                }
            }
            ForEach(names, id: \.self) { meal in
                let logged = entries.filter { $0.meal == meal }
                TodayMealCard(meal: meal, entries: logged, energy: byMeal[meal]?.energy ?? 0,
                              repeatable: logged.isEmpty ? store.repeatable(meal, for: date) : nil,
                              recipes: logged.isEmpty ? store.recipes(for: meal, through: date).prefix(2).compactMap {
                                  store.quickPortion(for: $0, unit: unit)
                              } : [],
                              timeZone: timeZone, unit: unit, selection: selection) {
                    actions.clearError()
                    destination = .add(meal)
                } edit: { entry in
                    if selection != nil {
                        selection?.formSymmetricDifference([entry.id])
                    } else {
                        actions.clearError()
                        destination = .edit(entry)
                    }
                } repeatMeal: { repeated in
                    apply(repeated)
                } logRecipe: { portion in
                    log(portion, to: meal)
                } copy: { destination = .copy(meal) } saveAsRecipe: { destination = .recipe(meal) } select: {
                    withAnimation(.snappy) { selection = Set(logged.map(\.id)) }
                }
            }
        }
    }

    private var mealNames: [String] {
        NutritionStore.defaultMeals + Set(store.entries(on: date).map(\.meal)).subtracting(NutritionStore.defaultMeals).sorted()
    }

    /// Copies or moves the chosen foods, with Undo. A copy keeps each food's
    /// portion and source, as copying a meal does; a move keeps the entries.
    private func perform(_ action: TodayEntriesDestination.Action, _ chosen: [FoodEntry], to target: LocalDate, meal: String?) {
        let what = "\(chosen.count) \(chosen.count == 1 ? "food" : "foods")"
        var place = TodayEntriesDestination.dayName(target, today: today, timeZone: timeZone)
        if ["Today", "Tomorrow", "Yesterday"].contains(place) { place = place.lowercased() }
        if let meal { place = target == date ? meal : "\(meal), \(place)" }
        do {
            switch action {
            case .copy:
                let copies = try store.copy(chosen.map(\.id), to: target, meal: meal)
                show("Copied \(what) to \(place)", undo: .remove(copies.map(\.id)))
            case .move:
                try store.move(chosen.map(\.id), to: target, meal: meal)
                show("Moved \(what) to \(place)", undo: .moveBack(chosen))
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.snappy) { selection = nil }
            Task { await workspace.synchronize() }
        } catch { show("Could not \(action == .copy ? "copy" : "move") those foods. Nothing changed.", failed: true) }
    }

    private func log(_ recipe: QuickPortion, to meal: String) {
        do {
            let entry = try store.log(recipe, on: date, meal: meal)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            show("Logged \(recipe.food.name) to \(meal)", undo: .remove([entry.id]))
            Task { await workspace.synchronize() }
        } catch { show("Could not log \(recipe.food.name). Try again.", failed: true) }
    }

    private func apply(_ repeated: MealRepeat) {
        do {
            let copied = try store.apply(repeated, to: date)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            let what = repeated.meal.map { "\($0.lowercased())" } ?? "the day"
            show("Repeated \(dayName(repeated.source))'s \(what)", undo: .remove(copied.map(\.id)))
            Task { await workspace.synchronize() }
        } catch { show("Could not repeat those foods. Nothing was logged.", failed: true) }
    }

    private func dayName(_ day: LocalDate) -> String {
        if day == date.adding(days: -1) { return day == today.adding(days: -1) ? "yesterday" : "the day before" }
        var style = Date.FormatStyle.dateTime.weekday(.wide)
        style.timeZone = timeZone
        return NutritionFormat.pickerDate(day, timeZone: timeZone).formatted(style)
    }

    // MARK: Day

    private var dayFooter: some View {
        let day = store.day(date)
        let complete = day.status == .complete
        return VStack(alignment: .leading, spacing: ExSpacing.small) {
            Menu {
                ForEach(DayStatus.allCases, id: \.self) { status in
                    Button {
                        setStatus(status)
                    } label: {
                        if day.status == status {
                            Label(NutritionFormat.status(status), systemImage: "checkmark")
                        } else { Text(NutritionFormat.status(status)) }
                    }.accessibilityIdentifier("nutrition.status.\(status.rawValue)")
                }
            } label: {
                HStack(spacing: ExSpacing.item) {
                    Image(systemName: complete ? "checkmark.circle.fill" : "circle").font(.title3)
                        .foregroundStyle(complete ? Color.exSuccess : Color.exTextMuted).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(day.status == .unlogged ? "Mark this day complete" : NutritionFormat.status(day.status))
                            .font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                        Text(Self.statusDetail(day.status)).font(.exSmall).foregroundStyle(Color.exTextSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(ExSpacing.item).frame(minHeight: 56)
                .background(Color.exSurface1, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(Rectangle())
            } primaryAction: {
                setStatus(complete ? .unlogged : .complete)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("nutrition.dayStatus")
            .accessibilityHint("Double tap to toggle. Use the actions menu for fasting or a partial log.")

            if !day.notes.isEmpty {
                Button { destination = .notes } label: {
                    Label(day.notes, systemImage: "text.alignleft").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain).accessibilityLabel("Edit note, \(day.notes)")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ExSpacing.small) { footerLinks }
                VStack(alignment: .leading, spacing: 0) { footerLinks }
            }
            HealthActivityLine(accountID: workspace.accountID, date: date, timeZone: timeZone)
            if let engine = workspace.sync, case .offline = engine.state {
                Label("Saved on this device · Offline", systemImage: "wifi.slash").font(.exCaption).foregroundStyle(Color.exTextSecondary)
            } else if let engine = workspace.sync, case .failed = engine.state {
                NavigationLink("Some changes could not sync") { AccountSyncView(workspace: workspace) }.font(.exCaption)
            }
        }
    }

    @ViewBuilder private var footerLinks: some View {
        footerLink("Nutrients", icon: "chart.bar.doc.horizontal", id: "today.nutrients") { destination = .nutrients }
        footerLink(store.day(date).notes.isEmpty ? "Add note" : "Note", icon: "square.and.pencil", id: "nutrition.editNote") { destination = .notes }
        if !store.entries(on: date).isEmpty {
            footerLink("Copy day", icon: "doc.on.doc", id: "nutrition.copyDay") { destination = .copy(nil) }
        }
        if let calendarDate = CalendarDay(rawValue: date.description) {
            NavigationLink {
                HomeView(refreshToken: 0, initialDate: calendarDate, healthOnly: true)
            } label: {
                Label("Activity & sleep", systemImage: "heart.text.clipboard").font(.exCaption.weight(.medium))
                    .foregroundStyle(Color.exPrimaryText).frame(minHeight: 44)
            }.accessibilityIdentifier("nutrition.dailyHealth")
        }
    }

    private func footerLink(_ title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.exCaption.weight(.medium)).foregroundStyle(Color.exPrimaryText)
                .frame(minHeight: 44).padding(.horizontal, 4)
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }

    private static func statusDetail(_ status: DayStatus) -> String {
        switch status {
        case .unlogged: "Complete days improve your expenditure estimate"
        case .complete: "Counts toward your expenditure estimate"
        case .partial: "Left out of your expenditure estimate"
        case .fasting: "Counts as a day with no intake"
        }
    }

    private func setStatus(_ status: DayStatus) {
        if actions.setStatus(status, reviewed: store.day(date), entries: store.entries(on: date)) {
            if status == .complete { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            Task { await workspace.synchronize() }
        }
    }

    // MARK: Sheets

    @ViewBuilder private func sheet(_ destination: Destination) -> some View {
        switch destination {
        case .date: NutritionDateView(date: $date, timeZone: timeZone)
        case .add(let meal):
            NutritionFoodPicker(workspace: workspace, api: api, date: date, meal: meal,
                                timeZone: timeZone, unit: unit, actions: actions) {}
        case .scan(let meal):
            NutritionFoodPicker(workspace: workspace, api: api, date: date, meal: meal,
                                timeZone: timeZone, unit: unit, actions: actions, onLogged: {}, startsWithBarcode: true)
        case .quick(let meal):
            NutritionQuickAddView(workspace: workspace, date: date, meal: meal, timeZone: timeZone) {}
        case .edit(let entry):
            NutritionEntryEditor(workspace: workspace, food: entry.food.foodForLogging(serving: entry.serving),
                                 date: entry.date, meal: entry.meal, timeZone: timeZone, unit: unit,
                                 actions: actions, editing: entry) { _ in }
        case .log(let suggestion):
            NutritionEntryEditor(workspace: workspace,
                                 food: store.food(suggestion.food.foodID) ?? suggestion.food.foodForLogging(serving: suggestion.serving),
                                 date: date, meal: currentMeal, timeZone: timeZone, unit: unit, actions: actions) { _ in }
        case .notes: NutritionDayNotesView(workspace: workspace, date: date, timeZone: timeZone)
        case .copy(let meal): NutritionCopyView(workspace: workspace, source: date, meal: meal, timeZone: timeZone)
        case .recipe(let meal):
            RecipeEditor(workspace: workspace, api: api, timeZone: timeZone, unit: unit,
                         start: ExerlyCore.Food.recipe(from: store.entries(on: date).filter { $0.meal == meal })) {
                show("Saved \($0.name) to your recipes")
            }
        case .nutrients:
            NavigationStack {
                ExScreen {
                    let summary = store.summary(on: date)
                    NutritionAmountsView(amounts: summary.totals) {
                        IntakeFormat.completeness(reporting: summary.reporting[$0] ?? 0, entries: summary.entries)
                    }
                    Text("Totals use reported nutrients. Missing values do not mean zero.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
                .navigationTitle("Nutrients").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.destination = nil } } }
            }
        case .weighIn:
            WeighInSheet(workspace: workspace, unit: unit, timeZone: timeZone) { entry in
                show("Weighed in at \(BodyFormat.reading(entry.weight, unit))", undo: .removeWeight(entry.id))
            }
        case .entries(let action):
            let chosen = store.entries(on: date).filter { selection?.contains($0.id) == true }
            TodayEntriesDestination(action: action, count: chosen.count, source: date, today: today, meals: mealNames,
                                    timeZone: timeZone) { perform(action, chosen, to: $0, meal: $1) }
        }
    }
}

/// One meal: its foods and calories, a plus to add, and when it's empty a
/// one-tap repeat of the last time it was logged and its recipes.
struct TodayMealCard: View {
    let meal: String
    let entries: [FoodEntry]
    let energy: Double
    let repeatable: MealRepeat?
    /// Recipes made from this meal (`NutritionStore.recipes(for:through:)`), each as one tap logs it.
    let recipes: [QuickPortion]
    let timeZone: TimeZone
    let unit: MassUnit
    /// The foods chosen on Today while choosing; nil otherwise. A tap on a food then chooses it.
    var selection: Set<UUID>?
    let add: () -> Void
    let edit: (FoodEntry) -> Void
    let repeatMeal: (MealRepeat) -> Void
    let logRecipe: (QuickPortion) -> Void
    let copy: () -> Void
    let saveAsRecipe: () -> Void
    let select: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ExSpacing.small) {
                Text(meal).font(.exH3).foregroundStyle(Color.exTextPrimary).accessibilityAddTraits(.isHeader)
                Spacer(minLength: ExSpacing.small)
                if !entries.isEmpty {
                    Text("\(TodayNutritionCard.number(energy)) kcal").font(.exLabel).monospacedDigit()
                        .foregroundStyle(Color.exTextSecondary)
                }
                if !entries.isEmpty && selection == nil {
                    Menu { mealActions } label: {
                        Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.exTextSecondary)
                            .frame(width: 32, height: 32).frame(width: 44, height: 44).contentShape(Circle())
                    }
                    .accessibilityLabel("\(meal) options")
                    .accessibilityIdentifier("today.mealMenu.\(meal.lowercased())")
                }
                if selection == nil {
                    Button(action: add) {
                        Image(systemName: "plus").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.exPrimaryText)
                            .frame(width: 32, height: 32).background(Color.exPrimary.opacity(0.14), in: Circle())
                            .frame(width: 44, height: 44).contentShape(Circle())
                    }
                    .buttonStyle(TodayPressStyle())
                    .accessibilityLabel("Add food to \(meal)")
                    .accessibilityIdentifier("nutrition.add.\(meal.lowercased())")
                }
            }
            .padding(.leading, ExSpacing.content).padding(.trailing, selection == nil ? ExSpacing.tight : ExSpacing.content)
            .frame(minHeight: 52)
            ForEach(entries) { entry in
                Divider().overlay(Color.exBorder.opacity(0.35)).padding(.leading, ExSpacing.content)
                Button { edit(entry) } label: { row(entry) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection?.contains(entry.id) == true ? .isSelected : [])
                    .accessibilityHint(selection == nil ? "Opens the entry to change or delete it" : "Chooses it to copy or move")
                    .accessibilityIdentifier("nutrition.entry.\(entry.id.uuidString)")
            }
            if let repeatable, selection == nil {
                Button { repeatMeal(repeatable) } label: {
                    HStack(spacing: ExSpacing.small) {
                        Image(systemName: "arrow.counterclockwise").font(.footnote.weight(.semibold)).accessibilityHidden(true)
                        Text("Repeat \(sourceName(repeatable.source)) · \(repeatable.entries.count) \(repeatable.entries.count == 1 ? "food" : "foods") · \(TodayNutritionCard.number(repeatable.energy)) kcal")
                            .font(.exCaption.weight(.semibold)).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.exPrimaryText)
                    .padding(.horizontal, ExSpacing.item).frame(minHeight: 40)
                    .background(Color.exPrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(TodayPressStyle())
                .padding(.horizontal, ExSpacing.item).padding(.bottom, ExSpacing.item)
                .accessibilityLabel("Repeat \(meal) from \(sourceName(repeatable.source)), \(repeatable.entries.count) foods, \(TodayNutritionCard.number(repeatable.energy)) calories")
                .accessibilityIdentifier("today.repeat.\(meal.lowercased())")
            }
            ForEach(selection == nil ? recipes : []) { recipe in
                let portion = FoodFormat.portion(recipe, unit: unit)
                let kcal = TodayNutritionCard.number(recipe.nutrients.energy)
                Button { logRecipe(recipe) } label: {
                    HStack(spacing: ExSpacing.small) {
                        Image(systemName: "frying.pan").font(.footnote.weight(.semibold)).accessibilityHidden(true)
                        Text("Log \(recipe.food.name) · \(portion) · \(kcal) kcal")
                            .font(.exCaption.weight(.semibold)).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.exPrimaryText)
                    .padding(.horizontal, ExSpacing.item).frame(minHeight: 40)
                    .background(Color.exPrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(TodayPressStyle())
                .padding(.horizontal, ExSpacing.item).padding(.bottom, ExSpacing.item)
                .accessibilityLabel("Log \(recipe.food.name) to \(meal), \(portion), \(kcal) calories")
                .accessibilityIdentifier("today.recipe.\(meal.lowercased())")
            }
        }
        .background(Color.exSurface1, in: RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous).strokeBorder(Color.exBorder.opacity(0.5), lineWidth: 0.5) }
        .contextMenu { if selection == nil { mealActions } }
    }

    /// In the meal's "…" menu, and on a long press.
    @ViewBuilder private var mealActions: some View {
        if !entries.isEmpty { Button("Copy \(meal)", systemImage: "doc.on.doc", action: copy) }
        if !entries.isEmpty {
            Button("Select foods", systemImage: "checklist", action: select).accessibilityIdentifier("today.selectMeal")
        }
        if entries.contains(where: { $0.food.unweighed != true }) {
            Button("Save as recipe", systemImage: "frying.pan", action: saveAsRecipe).accessibilityIdentifier("today.saveRecipe")
        }
    }

    private func row(_ entry: FoodEntry) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .center, spacing: ExSpacing.item))
        return layout {
            if let selection {
                let chosen = selection.contains(entry.id)
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(chosen ? Color.exActionFill : Color.exTextMuted)
                    .contentTransition(.symbolEffect(.replace)).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.food.name).font(.exBody).foregroundStyle(Color.exTextPrimary).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                Text(NutritionFormat.portion(entry, unit: unit)).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                if entry.food.edited == true {
                    Text("Edited nutrition").font(.exSmall).foregroundStyle(Color.exPrimaryText)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Text("\(TodayNutritionCard.number(entry.nutrients.energy))").font(.exStatSmall).monospacedDigit()
                .foregroundStyle(Color.exTextPrimary)
        }
        .padding(.horizontal, ExSpacing.content).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.food.name), \(NutritionFormat.portion(entry, unit: unit)), \(TodayNutritionCard.number(entry.nutrients.energy)) calories\(entry.food.edited == true ? ", edited nutrition" : "")")
    }

    private func sourceName(_ day: LocalDate) -> String {
        let today = LocalDate(Date(), in: timeZone)
        if day == today.adding(days: -1) { return "yesterday" }
        var style = Date.FormatStyle.dateTime.weekday(.wide)
        style.timeZone = timeZone
        return NutritionFormat.pickerDate(day, timeZone: timeZone).formatted(style)
    }
}
