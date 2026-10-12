# M5c: nutrition targets and weekly check-ins

Owner: logic agent. Status: built and measured, 2026-10-06.

PARITY S01 to S06: coached, collaborative and manual targets; diet types; a
weekly budget split by weekday; adaptive or fixed expenditure; a weekly review
on a chosen day; and goals with a rate and a goal weight.

## Plans are versioned documents

A `NutritionPlan` is a synced document of kind `nutrition_plan`. A plan never
changes once in force. A new goal, or a check-in, adds a new version with its
own `startDate`, so the targets for any past day are the ones that held that
day (PARITY N29).

A version holds:

- the goal: lose, maintain or gain, a weekly rate as a share of bodyweight, and
  an optional goal weight;
- the mode:
  - coached: weekly check-ins propose new targets;
  - collaborative: the same proposals, which the person edits before accepting;
  - manual: targets are typed in and never proposed;
- the diet type (balanced, low fat, low carb or keto) and the protein level;
- relative weekday budgets and the check-in weekday;
- `allowBelowFloor`, false unless the person chooses it;
- the basis it was computed from: expenditure with its standard deviation, and
  trend weight;
- the seven daily targets, Sunday to Saturday: energy, protein, fat and
  carbohydrate.

Targets are stored, not recomputed on read, so a later change to the formula
never rewrites history.

## Targets (pure functions)

- **Energy.** The daily budget is expenditure plus the rate times trend weight
  times 7,700 kcal/kg, over 7 days.
  - Loss is capped at 1 % of bodyweight a week and gain at 0.5 %. These are
    the ranges recommended for physique athletes (Helms et al., 2014; expert
    and observational evidence, not an RCT).
  - No day goes under 1,200 kcal unless `allowBelowFloor` is set, apart from
    days given no budget at all (planned fasts).
  - A goal weight the trend is already at or past, in the goal's direction,
    takes no rate: the budget is expenditure. The editor won't save such a
    goal; it offers the other direction or maintaining.
- **Weekdays.** The weekly budget is shared out by relative weights, so the seven
  days sum to it exactly (S03). A weight of 0 is a fasting day.
- **Protein.** 1.4, 1.8 or 2.2 g/kg a day (Morton et al., 2018, a meta-analysis
  of RCTs: gains plateau near 1.6 g/kg, upper bound 2.2). Losing with a goal
  weight under the current trend uses the goal weight. Protein is the same on
  every day with a budget.
- **Fat.** The diet type's share of the day's energy (balanced 30 %, low fat
  20 %, low carb 40 %, keto 70 %), never under 0.6 g/kg.
- **Carbohydrate.** The rest, never negative. Keto caps it at 30 g a day, and fat
  takes what's left.
- **When the floors don't fit.** If protein and the fat floor need more energy
  than a day has, the plan reports it as invalid, with the reason, instead of
  quietly breaking a floor.

## The first plan, at onboarding

With no logs or weigh-ins yet, `PlanBasis.formula(BodyProfile)` estimates
expenditure as Mifflin–St Jeor resting energy times an activity factor (1.2
sedentary to 1.9 very active). Its trend weight is the weight entered at setup.

- **Uncertainty.** The standard deviation is 15 % of the estimate. In
  validation studies, Mifflin–St Jeor comes within 10 % of measured resting
  energy for most adults, and self-reported activity adds error on top. 15 %
  is a deliberately wide assumption, not a measurement.
- **Why it matters little.** The first plan's basis is the energy balance's
  prior, and its error is the prior's width. A wide prior lets logged intake
  and weigh-ins take over within the first weeks.
- **What the app does.** It saves
  `NutritionPlan(startDate:goal:...).computed(from: .formula(profile))`, so
  the screens do no calorie or macro arithmetic.

## Check-ins (built-in proposals)

`NutritionCheckIn.proposal(...)` runs on the plan's check-in day, once a week.

1. Estimate expenditure and trend with `EnergyBalance` from all data up to
   yesterday.
2. Compute new targets from the plan's goal and preferences.
3. If the daily budget moves by at least 20 kcal, propose a new plan version
   starting today.
   - The evidence is the expenditure estimate with its band, the trend's change
     over the week, and logging coverage (complete days and weigh-ins).
   - The falsifier: the trend moves at the goal rate on the old targets.
4. If the estimate's standard deviation is over 250 kcal, propose nothing and
   say why: too few complete days or weigh-ins.
5. If the new targets would break a floor (a day under 1,200 kcal, or protein
   and fat that don't fit), propose nothing and report the reasons, so the
   person changes the goal. A check-in never quietly slows the rate.

Manual plans get no proposals. The proposal ID is a name-based UUID from the
plan and the date, so two devices propose the same check-in once.

A check-in reviewed after its day (the app wasn't opened on it) still uses
the data up to the check-in day, but its version starts on the day it is
reviewed, so days already eaten keep their targets.

## The targets screen (2026-10-09)

`Features/Targets` shows the plan in force and its check-in, built only on
ExerlyCore (`NutritionPlanning.swift` holds the arithmetic: rates in the
person's unit, weekday shares, typed manual targets, the basis a new version
rests on, live previews and goal projections).

- The app files a check-in's proposal only when the person decides: Accept
  files and accepts it, Keep current files and rejects it, so nothing pending
  goes stale when the plan changes first. Undo is `AgentStore.undo`.
- Collaborative plans add Adjust: the proposed version opens in the editor,
  and the changed version is filed and accepted under the check-in's ID.
- A new version from the editor rests on the measured expenditure when
  there is one, else the last plan's, else the profile's formula, at today's
  trend weight.

## Checked against simulated people (closed loop)

The M5b simulator gains people who eat to their targets: true intake is the
logged target over their logging bias, plus day-to-day noise, with missed logs.
Each week they accept the check-in. Scores, over weeks 4 to 16:

- the achieved rate of weight change against the goal rate, in % of bodyweight
  a week;
- the same with no check-ins, from a starting expenditure estimate 15 % off,
  which shows what check-ins add.

### Measured (2026-10-06)

30 dieters per weigh-in frequency, each for 16 weeks:

- 60 to 105 kg, with expenditure of 28 to 38 kcal per kg;
- goals of 0.5 %, 0.75 % and 1 % weekly loss, 0.25 % gain, and maintenance;
- a starting guess of expenditure 15 % low to 15 % high, ±400 kcal;
- logging biased 0.85 to 1.0, with 120 kcal of logging noise and 15 % of days
  not complete;
- eating 200 kcal a day either side of the target at random;
- the M5b physiology: expenditure falling 22 kcal per kg lost, adaptive
  thermogenesis up to 5 %, a random drift and water swings.

| Weigh-ins              | Check-ins: error, mean (90th %) | Fixed targets: error, mean (90th %) |
| ---------------------- | ------------------------------- | ----------------------------------- |
| Daily (90 %)           | 0.067 % a week (0.123)          | 0.294 % a week (0.669)              |
| Every other day (50 %) | 0.085 % a week (0.176)          | 0.283 % a week (0.716)              |
| About weekly (20 %)    | 0.090 % a week (0.190)          | 0.315 % a week (0.763)              |

The error is the achieved rate of weight change, weeks 4 to 16, minus the goal,
in % of bodyweight a week. For an 80 kg person 0.07 % is 55 g a week.

- Check-ins cut the error to under a third of fixed targets from a starting
  guess.
- Most of the remaining error is in fast diets: at a 1 % weekly loss the
  achieved rate still falls short by 0.11 % a week, because adaptive
  thermogenesis outruns the weekly estimate.
- Before M5c the estimator treated expenditure as a pure random walk. It read
  171 kcal high at check-ins at a 1 % weekly loss, and the shortfall was
  0.19 % a week. Coupling expenditure to weight change (design 007) brought it
  to 0.11 %.
