import ExerlyCore
import SwiftUI

/// The weekly check-in: a proposed change with its evidence and a one-tap
/// decision when one is due, and otherwise what happened, what's missing or
/// when the next one is.
struct TargetsCheckInCard: View {
    enum State {
        /// A proposal to decide.
        case due(NutritionCheckIn.Review, Proposal, proposed: NutritionPlan)
        /// This week's check-in, decided.
        case decided(Proposal, proposed: NutritionPlan, before: NutritionPlan?, canUndo: Bool, next: LocalDate)
        /// Too few complete days or weigh-ins for a confident estimate.
        case waiting(NutritionCheckIn.Review)
        case unchanged(NutritionCheckIn.Review, next: LocalDate)
        case cannotKeepGoal(NutritionCheckIn.Review)
        case scheduled(LocalDate)
        case manual

        /// A proposal to accept, or a goal that no longer fits.
        var needsDecision: Bool {
            switch self {
            case .due, .cannotKeepGoal: true
            default: false
            }
        }
    }

    struct Actions {
        let accept: (Proposal) -> Void
        let keep: (Proposal) -> Void
        let adjust: (Proposal, NutritionPlan) -> Void
        let undo: (Proposal) -> Void
        let changeGoal: () -> Void
        let coach: () -> Void
    }

    let state: State
    /// The version in force.
    let plan: NutritionPlan
    let unit: MassUnit
    let today: LocalDate
    let summary: WeightTrend.Summary?
    let actions: Actions
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            switch state {
            case .due(let review, let proposal, let proposed): due(review, proposal, proposed: proposed)
            case .decided(let proposal, let proposed, let before, let canUndo, let next):
                decided(proposal, proposed: proposed, before: before, canUndo: canUndo, next: next)
            case .waiting(let review): waiting(review)
            case .unchanged(let review, let next): unchanged(review, next: next)
            case .cannotKeepGoal(let review): cannotKeepGoal(review)
            case .scheduled(let date): scheduled(date)
            case .manual: manual
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("targets.checkIn")
    }

    // MARK: Due

    private func due(_ review: NutritionCheckIn.Review, _ proposal: Proposal, proposed: NutritionPlan) -> some View {
        let before = plan.averageDay ?? DailyTargets(energy: 0, protein: 0, fat: 0, carbohydrate: 0)
        let after = proposed.averageDay ?? before
        let even = WeekdayBudget.isEven(proposed.weekdayWeights)
        return ExCard(accent: true) {
            HStack(alignment: .center, spacing: ExSpacing.small) {
                ExEyebrow("Check-in · \(TargetsFormat.shortDate(review.date, today: today))", color: .exPrimaryText)
                Spacer(minLength: ExSpacing.small)
                if !typeSize.isAccessibilitySize { confidence(proposal.confidence) }
            }
            Text("New targets for this week").font(.exH2).foregroundStyle(Color.exTextPrimary)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("targets.checkIn.title")
            if typeSize.isAccessibilitySize { confidence(proposal.confidence) }
            energyChange(from: before.energy, to: after.energy, even: even)
            macroChanges(from: before, to: after)
            TargetsDivider()
            evidence(review)
            Text(falsifier(review))
                .font(.exCaption).foregroundStyle(Color.exTextMuted).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("targets.checkIn.falsifier")
            decisionButtons(proposal, proposed: proposed)
        }
    }

    private func confidence(_ level: Confidence) -> some View {
        let text = switch level {
        case .high: "High confidence"
        case .medium: "Medium confidence"
        case .low: "Low confidence"
        }
        return Text(text).font(.exSmall.weight(.semibold))
            .foregroundStyle(level == .low ? Color.exWarning : Color.exTextSecondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.exSurface2, in: Capsule())
    }

    private func energyChange(from before: Double, to after: Double, even: Bool) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: ExSpacing.small))
        return VStack(alignment: .leading, spacing: 2) {
            layout {
                Text(TargetsFormat.kcal(before)).font(.exStatMedium).monospacedDigit().foregroundStyle(Color.exTextMuted)
                    .strikethrough(true, color: Color.exTextMuted.opacity(0.6))
                Image(systemName: typeSize.isAccessibilitySize ? "arrow.down" : "arrow.right").font(.exLabel.weight(.semibold))
                    .foregroundStyle(Color.exTextSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(TargetsFormat.kcal(after)).font(.exStat).monospacedDigit().foregroundStyle(Color.exTextPrimary)
                    Text("kcal").font(.exBodyMedium).foregroundStyle(Color.exTextSecondary)
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Text(TargetsFormat.signedKcal(after - before)).font(.exLabel.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(Color.exPrimaryText)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Color.exPrimary.opacity(0.14), in: Capsule())
            }
            Text(even ? "A day, every day of the week" : "A day on average. Your weekdays keep their shape.")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calories")
        .accessibilityValue("From \(TargetsFormat.kcal(before)) to \(TargetsFormat.kcal(after)) a day\(even ? "" : " on average"), "
            + "\(after < before ? "down" : "up") \(TargetsFormat.kcal(abs(after - before)))")
        .accessibilityIdentifier("targets.checkIn.energy")
    }

    private func macroChanges(from before: DailyTargets, to after: DailyTargets) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            macroChange("Protein", before.protein, after.protein, color: .exPrimaryText)
            macroChange("Carbs", before.carbohydrate, after.carbohydrate, color: .exAccent)
            macroChange("Fat", before.fat, after.fat, color: .exSecondary)
        }
    }

    private func macroChange(_ title: String, _ before: Double, _ after: Double, color: Color) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: ExSpacing.small))
        return layout {
            HStack(alignment: .firstTextBaseline, spacing: ExSpacing.small) {
                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(title).font(.exLabel).foregroundStyle(Color.exTextSecondary)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: ExSpacing.small) }
            HStack(alignment: .firstTextBaseline, spacing: ExSpacing.small) {
                if before.rounded() != after.rounded() {
                    Text(TargetsFormat.grams(before)).font(.exLabel).monospacedDigit().foregroundStyle(Color.exTextMuted)
                    Image(systemName: "arrow.right").font(.exSmall).foregroundStyle(Color.exTextMuted).accessibilityHidden(true)
                }
                Text(TargetsFormat.grams(after)).font(.exStatSmall).monospacedDigit().foregroundStyle(Color.exTextPrimary)
            }
            .lineLimit(1).minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(before.rounded() == after.rounded() ? "\(TargetsFormat.kcal(after)) grams, unchanged"
            : "From \(TargetsFormat.kcal(before)) to \(TargetsFormat.kcal(after)) grams")
    }

    /// The check-in's numbers, dated: they stop the day before the check-in,
    /// so they can differ from today's estimate on Today.
    private func evidence(_ review: NutritionCheckIn.Review) -> some View {
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            ExEyebrow("Why")
            if let estimate = review.estimate {
                let day = TargetsFormat.shortDate(estimate.date, today: today)
                evidenceRow("flame", "As of \(day), your expenditure was about \(BodyFormat.kcal(estimate.expenditure)) kcal a day, likely "
                    + "\(BodyFormat.kcal(estimate.expenditure - estimate.expenditureError)) to "
                    + "\(BodyFormat.kcal(estimate.expenditure + estimate.expenditureError)).")
                    .accessibilityIdentifier("targets.checkIn.expenditure")
                if let change = review.weekChange {
                    evidenceRow("chart.line.downtrend.xyaxis", "Trend weight \(movement(change)) in the week to \(day). "
                        + "The goal is \(goalMovement(trend: estimate.trend)) a week.")
                }
            }
            evidenceRow("checklist", Self.coverage(complete: review.completeDays, fasting: review.fastingDays,
                                                   partial: review.partialDays, weighIns: review.weighInDays))
        }
        .accessibilityElement(children: .contain)
    }

    /// "6 of the last 7 days fully logged, 1 of them a fast; 1 partial day left out. 5 with a weigh-in."
    static func coverage(complete: Int, fasting: Int, partial: Int, weighIns: Int) -> String {
        var text = "\(complete) of the last 7 days fully logged"
        if fasting > 0 { text += fasting == 1 ? ", 1 of them a fast" : ", \(fasting) of them fasts" }
        if partial > 0 { text += "; \(partial) partial \(partial == 1 ? "day" : "days") left out" }
        return text + ". \(weighIns) with a weigh-in."
    }

    private func evidenceRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ExSpacing.small) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: icon).font(.exCaption.weight(.semibold)).foregroundStyle(Color.exPrimaryText)
                    .frame(width: 18).accessibilityHidden(true)
            }
            Text(text).font(.exCaption).foregroundStyle(Color.exTextPrimary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "down 0.9 lb", "up 0.2 kg", "steady".
    private func movement(_ kilograms: Double) -> String {
        let shown = (Mass.kg(abs(kilograms)).value(in: unit) * 10).rounded() / 10
        guard shown > 0 else { return "held steady" }
        return "\(kilograms < 0 ? "down" : "up") \(BodyFormat.number(shown)) \(unit.rawValue)"
    }

    private func goalMovement(trend: Double) -> String {
        plan.goal.direction == .maintain ? "to hold steady"
            : "\(plan.goal.direction == .lose ? "down" : "up") \(TargetsFormat.weekly(plan.goal.weeklyRate, trend: trend, unit: unit))"
    }

    private func falsifier(_ review: NutritionCheckIn.Review) -> String {
        guard let trend = review.estimate?.trend, plan.goal.direction != .maintain else {
            return "This would be wrong if your trend weight held steady on your current targets."
        }
        return "This would be wrong if your trend weight kept moving \(goalMovement(trend: trend)) a week on your current targets."
    }

    @ViewBuilder
    private func decisionButtons(_ proposal: Proposal, proposed: NutritionPlan) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: ExSpacing.small)) : AnyLayout(HStackLayout(spacing: ExSpacing.small))
        layout {
            Button { actions.accept(proposal) } label: { Label("Accept", systemImage: "checkmark") }
                .buttonStyle(ExActionStyle()).accessibilityIdentifier("targets.checkIn.accept")
                .accessibilityHint("Starts these targets today. You can undo.")
            if plan.mode == .collaborative {
                Button("Adjust") { actions.adjust(proposal, proposed) }
                    .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("targets.checkIn.adjust")
                    .accessibilityHint("Change the proposed plan before accepting it")
            }
            Button("Keep current") { actions.keep(proposal) }
                .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("targets.checkIn.keep")
        }
    }

    // MARK: Decided

    private func decided(_ proposal: Proposal, proposed: NutritionPlan, before: NutritionPlan?, canUndo: Bool,
                         next: LocalDate) -> some View {
        let after = proposed.averageDay?.energy ?? 0
        let earlier = before?.averageDay?.energy
        let (title, detail): (String, String) = switch proposal.status {
        case .accepted: ("Targets updated", earlier.map { "From \(TargetsFormat.kcal($0)) to \(TargetsFormat.kcal(after)) kcal a day, starting "
            + "\(TargetsFormat.onDay(proposed.startDate, today: today))." } ?? "Now \(TargetsFormat.kcal(after)) kcal a day.")
        case .rejected: ("You kept your targets", "This week's check-in proposed \(TargetsFormat.kcal(after)) kcal a day.")
        case .undone: ("Check-in undone", "Your targets are back to what they were.")
        case .stale: ("Check-in out of date", "Your targets changed after it was made, so it wasn't applied.")
        case .pending: ("Waiting for your decision", "")
        }
        return ExCard {
            HStack(alignment: .top, spacing: ExSpacing.item) {
                if !typeSize.isAccessibilitySize {
                    Image(systemName: proposal.status == .accepted ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(proposal.status == .accepted ? Color.exSuccess : Color.exTextMuted)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ExEyebrow("Weekly check-in")
                    Text(title).font(.exH3).foregroundStyle(Color.exTextPrimary).accessibilityIdentifier("targets.checkIn.title")
                    if !detail.isEmpty {
                        Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Next check-in \(TargetsFormat.onDay(next, today: today)).")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
                Spacer(minLength: 0)
            }
            if canUndo {
                Button { actions.undo(proposal) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("targets.checkIn.undo")
                    .accessibilityHint("Goes back to your previous targets")
            }
        }
    }

    // MARK: Not proposed

    private func waiting(_ review: NutritionCheckIn.Review) -> some View {
        ExCard {
            ExEyebrow("Check-in · \(TargetsFormat.shortDate(review.date, today: today))", color: .exWarning)
            Text("Waiting for more data").font(.exH3).foregroundStyle(Color.exTextPrimary)
                .accessibilityIdentifier("targets.checkIn.title")
            Group {
                if let estimate = review.estimate {
                    Text("Your expenditure is known to ±\(BodyFormat.kcal(estimate.expenditureError)) kcal. A check-in needs "
                        + "±\(BodyFormat.kcal(NutritionCheckIn.maximumError)) or better before it changes your targets.")
                } else {
                    Text("Check-ins need weigh-ins and fully logged days. Weigh in to start your trend.")
                }
            }
            .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.small))
                : AnyLayout(HStackLayout(spacing: ExSpacing.item))
            layout {
                coverage(review.fastingDays > 0 ? "Fully logged or fasted" : "Fully logged", count: review.completeDays)
                coverage("Weigh-ins", count: review.weighInDays)
            }
            Text((review.partialDays > 0 ? "Partial days are left out. " : "")
                + "Log whole days and mark them complete, and weigh in most mornings. Your targets stay as they are until the check-in can run.")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func coverage(_ title: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                Spacer(minLength: 4)
                Text("\(count) of 7").font(.exCaption.weight(.semibold)).monospacedDigit().foregroundStyle(Color.exTextPrimary)
            }
            ExProgressBar(value: Double(count), total: 7, color: count >= 5 ? .exPrimary : .exWarning)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(count) of the last 7 days")
    }

    private func unchanged(_ review: NutritionCheckIn.Review, next: LocalDate) -> some View {
        ExCard {
            ExEyebrow("Check-in · \(TargetsFormat.shortDate(review.date, today: today))")
            Text("Your targets stay").font(.exH3).foregroundStyle(Color.exTextPrimary).accessibilityIdentifier("targets.checkIn.title")
            Group {
                if let estimate = review.estimate {
                    Text("Your expenditure is about \(BodyFormat.kcal(estimate.expenditure)) ±\(BodyFormat.kcal(estimate.expenditureError)) "
                        + "kcal a day. New targets would move by less than \(Int(NutritionCheckIn.minimumChange)) kcal, so nothing changes.")
                } else {
                    Text("New targets would move by less than \(Int(NutritionCheckIn.minimumChange)) kcal, so nothing changes.")
                }
            }
            .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            Text("Next check-in \(TargetsFormat.onDay(next, today: today)).").font(.exCaption)
                .foregroundStyle(Color.exTextSecondary)
        }
    }

    private func cannotKeepGoal(_ review: NutritionCheckIn.Review) -> some View {
        ExCard {
            ExEyebrow("Check-in · \(TargetsFormat.shortDate(review.date, today: today))", color: .exWarning)
            Text("Your goal no longer fits").font(.exH3).foregroundStyle(Color.exTextPrimary)
                .accessibilityIdentifier("targets.checkIn.title")
            Text("At your measured expenditure, this goal would break a floor:").font(.exCaption)
                .foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            ForEach(review.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Exerly won't quietly slow your rate. Choose a slower rate or a new goal.").font(.exCaption)
                .foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            Button("Change goal", action: actions.changeGoal).buttonStyle(ExActionStyle()).accessibilityIdentifier("targets.checkIn.changeGoal")
        }
    }

    private func scheduled(_ date: LocalDate) -> some View {
        ExCard {
            HStack(alignment: .top, spacing: ExSpacing.item) {
                if !typeSize.isAccessibilitySize {
                    Image(systemName: "calendar.badge.clock").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.exPrimaryText)
                        .frame(width: 40, height: 40).background(Color.exPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ExEyebrow("Next check-in")
                    Text(TargetsFormat.day(date, today: today)).font(.exH3).foregroundStyle(Color.exTextPrimary)
                        .accessibilityIdentifier("targets.checkIn.title")
                    Text("Exerly reviews your expenditure and trend weight and proposes new targets. You accept them or keep yours.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                    if let expenditure = summary?.expenditure, !expenditure.isMeasured {
                        Text(BodyCopy.expenditureWaiting(expenditure)).font(.exCaption).foregroundStyle(Color.exWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var manual: some View {
        ExCard {
            ExEyebrow("Weekly check-in")
            Text("Off for manual targets").font(.exH3).foregroundStyle(Color.exTextPrimary).accessibilityIdentifier("targets.checkIn.title")
            Group {
                if let expenditure = summary?.expenditure, expenditure.isMeasured {
                    Text("Your numbers stay as you set them. Your measured expenditure is about \(BodyFormat.kcal(expenditure.kcal)) "
                        + "±\(BodyFormat.kcal(expenditure.error)) kcal a day.")
                } else {
                    Text("Your numbers stay as you set them. With coaching, Exerly adjusts them weekly from what you log and weigh.")
                }
            }
            .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            Button("Let Exerly coach my targets", action: actions.coach).buttonStyle(ExActionStyle(secondary: true))
                .accessibilityIdentifier("targets.checkIn.coach")
        }
    }
}

extension TargetsCheckInCard.State {
    /// This week's check-in for `plan`: due, decided, waiting for data or
    /// scheduled. Today shows it when it needs a decision, Targets always.
    @MainActor static func current(plan: NutritionPlan, today: LocalDate, store: NutritionStore, agent: AgentStore,
                                   unit: MassUnit) -> Self {
        guard plan.mode != .manual else { return .manual }
        let proposals = agent.proposals
        let weekStart = today.startOfWeek(firstWeekday: plan.checkInDay)
        var excluded: UUID?
        // This week's check-in, once filed: decided, or pending from another device.
        if let latest = NutritionCheckIn.latest(in: proposals), let proposed = NutritionCheckIn.proposedPlan(latest),
           proposed.startDate >= weekStart {
            if latest.status == .pending {
                excluded = latest.id
            } else if latest.status != .accepted || plan.id == proposed.id {
                let review = try? store.checkIn(today: today, existing: proposals, unit: unit)
                return .decided(latest, proposed: proposed, before: store.plan(before: proposed),
                                canUndo: latest.status == .accepted,
                                next: review.map { NutritionCheckIn.nextDate(plan: store.checkInPlan(on: today) ?? plan, review: $0) }
                                    ?? weekStart.adding(days: 7))
            }
        }
        guard let review = try? store.checkIn(today: today, existing: proposals.filter { $0.id != excluded }, unit: unit) else {
            return .scheduled(weekStart.adding(days: 7))
        }
        let next = NutritionCheckIn.nextDate(plan: store.checkInPlan(on: today) ?? plan, review: review)
        switch review.outcome {
        case .proposed:
            guard let proposal = review.proposal, let proposed = NutritionCheckIn.proposedPlan(proposal) else { return .scheduled(next) }
            return .due(review, agent.proposal(proposal.id) ?? proposal, proposed: proposed)
        case .notEnoughData: return .waiting(review)
        case .unchanged: return .unchanged(review, next: next.adding(days: 7))
        case .cannotKeepGoal: return .cannotKeepGoal(review)
        case .notDue, .manual: return .scheduled(next)
        }
    }
}
