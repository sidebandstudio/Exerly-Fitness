import ExerlyCore
import SwiftUI

/// Opens the targets screen for an account once its workspace is ready.
struct TargetsHostView: View {
    let accountID: String
    let unit: MassUnit
    let timeZone: TimeZone
    @EnvironmentObject private var account: AppAccountWorkspace
    @EnvironmentObject private var auth: AuthViewModel

    var body: some View {
        Group {
            if let workspace = account.training, workspace.accountID == accountID {
                TargetsView(workspace: workspace, unit: unit, timeZone: timeZone).id(workspace.identity)
            } else if account.openingError != nil {
                ContentUnavailableView {
                    Label("Targets could not open", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("Your saved data is still on this device. Keep Exerly installed and try again.")
                } actions: {
                    Button("Try again") { Task { await account.configure(auth.accountAPI, retrying: true) } }
                        .buttonStyle(.borderedProminent).tint(Color.exActionFill)
                }
            } else { ProgressView("Opening your targets…") }
        }
    }
}

/// Calorie and macro targets from the nutrition plan: today's, the week's,
/// the goal and the expenditure they rest on, and the weekly check-in, with
/// the plan editor one tap away. Everything comes from ExerlyCore.
struct TargetsView: View {
    @ObservedObject var workspace: TrainingWorkspace
    let unit: MassUnit
    let timeZone: TimeZone
    @EnvironmentObject private var auth: AuthViewModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var editor: TargetsEditorRequest?
    @State private var toast: Toast?
    @State private var error: String?
    @State private var showsGoals = false

    struct Toast: Equatable {
        let id = UUID()
        let message: String
        /// The check-in to undo.
        var undo: UUID?
        var failed = false
    }

    private var store: NutritionStore { workspace.nutrition }
    private var today: LocalDate { LocalDate(Date(), in: timeZone) }

    var body: some View {
        let today = today
        let plan = store.plan(on: today)
        let summary = WeightTrend.summary(BodyEstimates.shared.estimates(store, through: today), through: today)
        ScrollView {
            VStack(alignment: .leading, spacing: ExSpacing.content) {
                if let plan {
                    let state = checkInState(plan, today: today)
                    // A check-in waiting for a decision leads; otherwise today's targets do.
                    if state.needsDecision { checkIn(state, plan: plan, today: today, summary: summary) }
                    todayCard(plan, today: today)
                    if !state.needsDecision { checkIn(state, plan: plan, today: today, summary: summary) }
                    weekCard(plan, today: today)
                    goalCard(plan, today: today, summary: summary)
                    basisCard(plan, summary: summary)
                    settingsCard(plan)
                    historyCard(today: today)
                } else {
                    setupCard(summary: summary)
                }
            }
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ExSpacing.page)
            .padding(.top, ExSpacing.small)
            .padding(.bottom, ExSpacing.major)
        }
        .scrollIndicators(.hidden)
        .exScrollEdges()
        .background(Color.exBackground)
        .accessibilityIdentifier("targets.screen")
        .navigationTitle("Targets")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if plan != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { open(.edit) }.accessibilityIdentifier("targets.edit")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                TodayToast(message: toast.message, failed: toast.failed,
                           undo: toast.undo.map { id in { undo(id) } }, undoIdentifier: "targets.toastUndo")
                    .padding(.bottom, ExSpacing.small)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(UIAccessibility.isVoiceOverRunning ? 12 : 6))
                        withAnimation(.snappy) { if self.toast == toast { self.toast = nil } }
                    }
            }
        }
        .navigationDestination(isPresented: $showsGoals) { NutrientGoalsView(workspace: workspace, timeZone: timeZone) }
        .sheet(item: $editor) { request in
            TargetsPlanEditor(workspace: workspace, unit: unit, timeZone: timeZone, request: request) { message, checkIn in
                show(message, undo: checkIn)
            }
        }
        .refreshable { await workspace.synchronize() }
        .task { await workspace.synchronize() }
    }

    @ViewBuilder
    private func checkIn(_ state: TargetsCheckInCard.State, plan: NutritionPlan, today: LocalDate,
                         summary: WeightTrend.Summary?) -> some View {
        TargetsCheckInCard(state: state, plan: plan, unit: unit, today: today, summary: summary, actions: checkInActions)
        if let error {
            Label(error, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exError)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("targets.error")
        }
    }

    // MARK: Today

    private func todayCard(_ plan: NutritionPlan, today: LocalDate) -> some View {
        let day = plan.targets(on: today) ?? DailyTargets(energy: 0, protein: 0, fat: 0, carbohydrate: 0)
        return ExCard {
            let header = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.small))
                : AnyLayout(HStackLayout(alignment: .center, spacing: ExSpacing.small))
            header {
                ExEyebrow("Today · \(TargetsFormat.weekday(today.weekday))", color: .exPrimaryText)
                if !typeSize.isAccessibilitySize { Spacer(minLength: ExSpacing.small) }
                Text(TargetsFormat.mode(plan.mode)).font(.exCaption.weight(.semibold)).foregroundStyle(Color.exPrimaryText)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.exPrimary.opacity(0.12), in: Capsule())
                    .accessibilityLabel("\(TargetsFormat.mode(plan.mode)) plan")
            }
            if day.energy > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(TargetsFormat.kcal(day.energy)).font(.exStat).monospacedDigit().foregroundStyle(Color.exTextPrimary)
                        .contentTransition(.numericText(value: day.energy))
                    Text("kcal").font(.exBodyMedium).foregroundStyle(Color.exTextSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Today's calorie target")
                .accessibilityValue("\(TargetsFormat.kcal(day.energy)) kilocalories")
                .accessibilityIdentifier("targets.today.energy")
                TargetsMacroBar(day: day)
                TargetsMacroRow(day: day)
            } else {
                Text("Fasting day").font(.exH2).foregroundStyle(Color.exTextPrimary).accessibilityIdentifier("targets.today.energy")
                Text("Your plan gives today no budget.").font(.exCaption).foregroundStyle(Color.exTextSecondary)
            }
        }
        .animation(.snappy, value: day)
    }

    // MARK: Week

    private func weekCard(_ plan: NutritionPlan, today: LocalDate) -> some View {
        let even = WeekdayBudget.isEven(plan.weekdayWeights)
        return ExCard {
            ExSectionHeading("This week", detail: "\(TargetsFormat.kcal(plan.weeklyEnergy)) kcal")
            if even, let day = plan.targets.first {
                Text("Same budget every day: \(TargetsFormat.kcal(day.energy)) kcal")
                    .font(.exBody).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            } else {
                TargetsWeekChart(targets: plan.targets, today: today.weekday)
                Text("Higher and lower days share the same weekly budget. Protein stays the same every day.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("targets.week")
    }

    // MARK: Goal

    private func goalCard(_ plan: NutritionPlan, today: LocalDate, summary: WeightTrend.Summary?) -> some View {
        let goal = plan.goal
        let trend = summary?.trend ?? plan.basis?.trendWeight
        return ExCard {
            ExEyebrow("Goal", color: .exPrimaryText)
            VStack(alignment: .leading, spacing: 3) {
                Text(goalHeadline(goal, trend: trend)).font(.exH2).foregroundStyle(Color.exTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(goalDetail(goal, trend: trend)).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("targets.goal")
            if goal.direction != .maintain {
                TargetsDivider()
                goalWeight(goal, today: today, trend: trend)
            }
        }
    }

    private func goalHeadline(_ goal: NutritionGoal, trend: Double?) -> String {
        guard goal.direction != .maintain else { return "Maintain" }
        let verb = TargetsFormat.direction(goal.direction)
        if let trend { return "\(verb) \(TargetsFormat.weekly(goal.weeklyRate, trend: trend, unit: unit)) a week" }
        return "\(verb) \(TargetsFormat.percent(goal.weeklyRate)) a week"
    }

    private func goalDetail(_ goal: NutritionGoal, trend: Double?) -> String {
        guard goal.direction != .maintain else {
            return trend.map { "Hold your trend weight near \(BodyFormat.weight($0, unit))." } ?? "Hold your weight steady."
        }
        guard let trend else { return "Of your bodyweight. Weigh in to see it in \(BodyFormat.unitName(unit))." }
        return "\(TargetsFormat.percent(goal.weeklyRate)) of bodyweight a week, from a trend weight of \(BodyFormat.weight(trend, unit))"
    }

    @ViewBuilder
    private func goalWeight(_ goal: NutritionGoal, today: LocalDate, trend: Double?) -> some View {
        if let target = goal.goalWeight {
            // Stacked at the largest sizes, where side by side both wrapped ("190.0" over "lb").
            let row = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
            row {
                Text("Goal weight").font(.exBody).foregroundStyle(Color.exTextSecondary)
                if !typeSize.isAccessibilitySize { Spacer(minLength: ExSpacing.small) }
                Text(BodyFormat.reading(target, unit)).font(.exStatSmall).monospacedDigit().foregroundStyle(Color.exTextPrimary)
            }
            .accessibilityElement(children: .combine)
            if let trend {
                switch goal.projection(from: trend, on: today) {
                case .on(let date, let weeks):
                    Text("Around \(TargetsFormat.shortDate(date, today: today)), in \(weeks) \(weeks == 1 ? "week" : "weeks") at this rate. "
                        + "Check-ins keep the rate as your expenditure changes.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("targets.eta")
                    if weeks >= 2 {
                        TargetsGoalChart(points: [(today, trend)] + goal.checkpoints(from: trend, on: today, weeks: min(weeks, 104)),
                                         goal: target.kilograms, unit: unit)
                            .frame(height: 110)
                    }
                case .reached:
                    // As on Progress: reached, and what to do next, rather than a loss rate toward a weight already passed.
                    VStack(alignment: .leading, spacing: ExSpacing.small) {
                        Text("Goal reached").font(.exLabel.weight(.semibold)).foregroundStyle(Color.exSuccess).lineLimit(1).fixedSize()
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.exSuccess.opacity(0.14), in: Capsule())
                        Text("Your trend weight is at or past your goal weight. Edit the plan to maintain it or aim for a new one.")
                            .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("targets.eta")
                case .noGoalWeight, .maintaining:
                    EmptyView()
                }
            }
        } else {
            // Add under the sentence at the largest sizes, as on Progress.
            let row = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout(spacing: ExSpacing.small))
            row {
                Text("No goal weight. Add one to see when you'd reach it.").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Button("Add") { open(.edit, addsGoalWeight: true) }.font(.exLabel.weight(.semibold)).foregroundStyle(Color.exPrimaryText)
                    .frame(minWidth: 44, minHeight: 44).accessibilityLabel("Add a goal weight")
                    .accessibilityIdentifier("targets.addGoalWeight")
            }
        }
    }

    // MARK: Basis

    private func basisCard(_ plan: NutritionPlan, summary: WeightTrend.Summary?) -> some View {
        ExCard {
            ExEyebrow("What it's based on")
            if let basis = plan.basis {
                VStack(alignment: .leading, spacing: 2) {
                    ExFigure(value: BodyFormat.kcal(basis.expenditure), unit: "kcal a day", detail: "±\(BodyFormat.kcal(basis.expenditureError))",
                             valueFont: .exStatMedium)
                    Text("Expenditure when this version started, likely \(BodyFormat.kcal(basis.expenditure - basis.expenditureError)) "
                        + "to \(BodyFormat.kcal(basis.expenditure + basis.expenditureError)) kcal, at a trend weight of "
                        + "\(BodyFormat.weight(basis.trendWeight, unit)).")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Expenditure the plan rests on")
                .accessibilityValue("About \(BodyFormat.kcal(basis.expenditure)) kilocalories a day, give or take "
                    + "\(BodyFormat.kcal(basis.expenditureError)), at a trend weight of \(BodyFormat.spokenWeight(basis.trendWeight, unit))")
                .accessibilityIdentifier("targets.basis")
            } else {
                Text("Manual targets don't rest on an estimate.").font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                    .accessibilityIdentifier("targets.basis")
            }
            if let summary {
                TargetsDivider()
                currentExpenditure(summary.expenditure, plan: plan)
            }
            // Only beside a ± to explain.
            if plan.basis != nil || summary?.expenditure.isMeasured == true {
                Text("The ± is one standard deviation: about a 2 in 3 chance the true value is in the range.")
                    .font(.exSmall).foregroundStyle(Color.exTextMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func currentExpenditure(_ value: WeightTrend.Expenditure, plan: NutritionPlan) -> some View {
        if value.isMeasured {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Now").font(.exLabel).foregroundStyle(Color.exTextSecondary)
                Spacer(minLength: ExSpacing.small)
                Text(BodyFormat.kcal(value.kcal)).font(.exStatSmall).monospacedDigit().foregroundStyle(Color.exTextPrimary)
                    .lineLimit(1).fixedSize()
                Text("±\(BodyFormat.kcal(value.error)) kcal").font(.exCaption).foregroundStyle(Color.exTextMuted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Expenditure now, about \(BodyFormat.kcal(value.kcal)) kilocalories a day, give or take \(BodyFormat.kcal(value.error))")
            Text(plan.mode == .manual ? "Measured from your logged days and weigh-ins."
                 : "Measured from your logged days and weigh-ins. The next check-in uses it.")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
        } else {
            Text(BodyCopy.expenditureWaiting(value)).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Plan

    private func settingsCard(_ plan: NutritionPlan) -> some View {
        ExCard {
            ExEyebrow("Plan")
            VStack(spacing: 0) {
                TargetsDetailRow(title: "Coaching", value: TargetsFormat.mode(plan.mode)) { open(.edit) }
                TargetsDivider()
                if plan.mode != .manual {
                    TargetsDetailRow(title: "Diet", value: TargetsFormat.diet(plan.diet)) { open(.edit) }
                    TargetsDivider()
                    TargetsDetailRow(title: "Protein", value: TargetsFormat.protein(plan.protein),
                                     detail: TargetsFormat.proteinRate(plan.protein, unit: unit)) { open(.edit) }
                    TargetsDivider()
                    TargetsDetailRow(title: "Check-in day", value: TargetsFormat.weekday(plan.checkInDay)) { open(.edit) }
                    TargetsDivider()
                }
                TargetsDetailRow(title: "Weekdays", value: WeekdayBudget.isEven(plan.weekdayWeights) ? "Even" : "Custom") { open(.edit) }
                TargetsDivider()
                let custom = plan.nutrientGoals?.count ?? 0, pins = plan.pinnedNutrients?.count ?? 0
                TargetsDetailRow(title: "Nutrient goals", value: custom == 0 ? "Daily values" : "\(custom) of your own",
                                 detail: pins == 0 ? nil : "\(pins) on Today", hint: "Opens nutrient goals and pins") { showsGoals = true }
                    .accessibilityIdentifier("targets.nutrientGoals")
            }
        }
    }

    // MARK: History

    private func historyCard(today: LocalDate) -> some View {
        let all = store.versionsInForce
        let versions = Array(all.suffix(6).reversed())
        let inForce = store.plan(on: today)?.id
        let checkIns = Set(workspace.agent.proposals.filter { $0.author == NutritionCheckIn.author && $0.status == .accepted }
            .compactMap { NutritionCheckIn.proposedPlan($0)?.id })
        return ExCard {
            ExSectionHeading("Versions", detail: all.count > versions.count ? "Latest \(versions.count) of \(all.count)" : nil)
            VStack(spacing: 0) {
                ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                    if index > 0 { TargetsDivider() }
                    HStack(alignment: .firstTextBaseline, spacing: ExSpacing.small) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(TargetsFormat.shortDate(version.startDate, today: today)).font(.exBodyMedium)
                                .foregroundStyle(Color.exTextPrimary)
                            let earlier = all.firstIndex(of: version).flatMap { $0 > 0 ? all[$0 - 1] : nil }
                            Text(checkIns.contains(version.id) ? "Check-in" : earlier.map(version.sameTargets(as:)) == true ? "Nutrient goals"
                                 : version.mode == .manual ? "Manual targets" : "Plan change")
                                .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                        }
                        Spacer(minLength: ExSpacing.small)
                        if version.id == inForce {
                            Text("Now").font(.exSmall.weight(.semibold)).foregroundStyle(Color.exPrimaryText)
                                .padding(.horizontal, 8).padding(.vertical, 2).background(Color.exPrimary.opacity(0.12), in: Capsule())
                        }
                        Text("\(TargetsFormat.kcal((version.averageDay?.energy ?? 0))) kcal").font(.exStatSmall).monospacedDigit()
                            .foregroundStyle(version.id == inForce ? Color.exTextPrimary : Color.exTextSecondary)
                    }
                    .padding(.vertical, ExSpacing.small).frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                }
            }
            Text("A change starts a new version from that day. Earlier days keep the targets they had.")
                .font(.exSmall).foregroundStyle(Color.exTextMuted).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: First plan

    private func setupCard(summary: WeightTrend.Summary?) -> some View {
        let choice = basisChoice(summary: summary)
        return VStack(alignment: .leading, spacing: ExSpacing.content) {
            ExCard(accent: true) {
                if !typeSize.isAccessibilitySize {
                    Image(systemName: "target").font(.system(size: 26, weight: .medium)).foregroundStyle(Color.exPrimaryText)
                        .frame(width: 56, height: 56).background(Color.exPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityHidden(true)
                }
                Text("Set your calorie and macro targets").font(.exH2).foregroundStyle(Color.exTextPrimary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                if typeSize.isAccessibilitySize { setupButton }
                Text("Exerly starts from your profile, then checks in each week and adjusts your targets from what you log and weigh.")
                    .font(typeSize.isAccessibilitySize ? .exCaption : .exBody).foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let choice {
                    Text("Starting estimate: \(BodyFormat.kcal(choice.basis.expenditure)) ±\(BodyFormat.kcal(choice.basis.expenditureError)) kcal a day")
                        .font(.exCaption.weight(.medium)).foregroundStyle(Color.exTextSecondary)
                }
                if !typeSize.isAccessibilitySize { setupButton }
            }
            if let message = workspace.nutritionSetupError {
                Label(message, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exWarning)
            }
            ExCard {
                ExEyebrow("How it works")
                setupStep(1, "Start from an estimate",
                          "Your age, height, weight and activity give a first expenditure, deliberately wide at ±15 %.")
                setupStep(2, "Log and weigh in",
                          "Fully logged days and weigh-ins measure what you burn, in the calories you log, so steady under-counting is built in.")
                setupStep(3, "Check in weekly",
                          "Exerly proposes new targets with its evidence. You accept them, adjust them or keep yours, and can undo.")
            }
        }
    }

    private var setupButton: some View {
        Button("Set up targets") { open(.setup) }.buttonStyle(ExActionStyle()).accessibilityIdentifier("targets.setup")
    }

    private func setupStep(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ExSpacing.item) {
            Text("\(number)").font(.system(.subheadline, design: .rounded, weight: .bold)).foregroundStyle(Color.exPrimaryText)
                .frame(width: 28, height: 28).background(Color.exPrimary.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Check-in

    private func checkInState(_ plan: NutritionPlan, today: LocalDate) -> TargetsCheckInCard.State {
        .current(plan: plan, today: today, store: store, agent: workspace.agent, unit: unit)
    }

    private var checkInActions: TargetsCheckInCard.Actions {
        TargetsCheckInCard.Actions(
            accept: { accept($0) },
            keep: { keep($0) },
            adjust: { proposal, proposed in
                guard let current = store.plan(on: today) else { return }
                open(.adjust(proposal, proposed: proposed, current: current))
            },
            undo: { undo($0.id) },
            changeGoal: { open(.edit) },
            coach: { open(.coach) })
    }

    private func accept(_ proposal: Proposal) {
        let agent = workspace.agent
        error = nil
        do {
            if agent.proposal(proposal.id) == nil { try agent.file(proposal) }
            try agent.accept(proposal.id)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            let energy = NutritionCheckIn.proposedPlan(proposal)?.averageDay?.energy ?? 0
            show("Targets updated to \(TargetsFormat.kcal(energy)) kcal a day", undo: proposal.id)
        } catch {
            self.error = TargetsFormat.message(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        Task { await workspace.synchronize() }
    }

    private func keep(_ proposal: Proposal) {
        let agent = workspace.agent
        error = nil
        do {
            if agent.proposal(proposal.id) == nil { try agent.file(proposal) }
            try agent.reject(proposal.id)
            show("Kept your current targets")
        } catch { self.error = TargetsFormat.message(error) }
        Task { await workspace.synchronize() }
    }

    private func undo(_ id: UUID) {
        error = nil
        do {
            try workspace.agent.undo(id)
            withAnimation(.snappy) { toast = nil }
            let energy = store.plan(on: today)?.averageDay?.energy ?? 0
            show("Targets back to \(TargetsFormat.kcal(energy)) kcal a day")
        } catch AgentStore.AgentError.stale {
            show("Your targets changed after this check-in, so they were kept.", failed: true)
        } catch { show("Could not undo. Your targets are unchanged.", failed: true) }
        Task { await workspace.synchronize() }
    }

    private func show(_ message: String, undo: UUID? = nil, failed: Bool = false) {
        withAnimation(.snappy) { toast = Toast(message: message, undo: undo, failed: failed) }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    // MARK: Editor

    private func basisChoice(summary: WeightTrend.Summary?) -> PlanBasisChoice? {
        PlanBasisChoice.current(summary: summary, plans: store.plans, profile: TargetsProfile.body(auth.currentUser))
    }

    private func open(_ kind: TargetsEditorRequest.Kind, addsGoalWeight: Bool = false) {
        editor = .make(kind, store: store, user: auth.currentUser, unit: unit, today: today)
        editor?.addsGoalWeight = addsGoalWeight
    }
}

/// What the plan editor opens for, with the draft it starts from.
struct TargetsEditorRequest: Identifiable {
    enum Kind {
        /// The first plan.
        case setup
        case edit
        /// A manual plan moving to coached.
        case coach
        /// A collaborative check-in's proposal, changed before accepting.
        case adjust(Proposal, proposed: NutritionPlan, current: NutritionPlan)
    }

    let id = UUID()
    let kind: Kind
    var draft: NutritionPlanDraft
    /// What a new version would rest on.
    let choice: PlanBasisChoice?
    /// The version in force.
    let current: NutritionPlan?
    /// Opened from "Add a goal weight": the editor starts at its field.
    var addsGoalWeight = false

    /// The editor for `kind` on `today`: from the version in force, or toward
    /// setup's goal when there's none yet, resting on the latest estimate.
    @MainActor
    static func make(_ kind: Kind, store: NutritionStore, user: UserDTO?, unit: MassUnit, today: LocalDate) -> TargetsEditorRequest {
        let summary = WeightTrend.summary(BodyEstimates.shared.estimates(store, through: today), through: today)
        var draft = NutritionPlanDraft(store.plan(on: today), goal: TargetsProfile.goal(user, unit: unit))
        switch kind {
        case .coach: draft.mode = .coached
        case .adjust(_, let proposed, _): draft = NutritionPlanDraft(proposed)
        case .setup, .edit: break
        }
        let choice = PlanBasisChoice.current(summary: summary, plans: store.plans, profile: TargetsProfile.body(user))
        return TargetsEditorRequest(kind: kind, draft: draft, choice: choice, current: store.plan(on: today))
    }
}
