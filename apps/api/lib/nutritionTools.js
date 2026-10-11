// Nutrition for agents: a day's log against the targets that held that day,
// and a range with trend weight and expenditure. Each rule mirrors
// ExerlyCore's NutritionStore so an agent reads what the phone shows:
// the plan in force is the latest to start on or before a date, an entry's
// nutrients are its food's per-100 g amounts scaled by its grams, and only
// complete and fasting days count as known intake for the energy balance.
// See docs/design/012-nutrition-agents.md.

const { badRequest } = require('./errors');
const dates = require('./dates');
const training = require('./training/history');
const energyBalance = require('./nutrition/energyBalance');

const KINDS = ['saved_food', 'food_entry', 'nutrition_day', 'weight_entry', 'nutrition_plan'];
const KG_PER_LB = 0.45359237;
const MACROS = ['energy', 'protein', 'carbohydrate', 'fat'];
const WEEKDAYS = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];

/** The account's nutrition documents, as NutritionStore holds them. */
function prepare(of) {
  const order = (a, b) =>
    a.startDate.localeCompare(b.startDate) ||
    a.createdAt.localeCompare(b.createdAt) ||
    a.id.localeCompare(b.id);
  return {
    entries: of('food_entry'),
    foods: of('saved_food'),
    days: new Map(of('nutrition_day').map((day) => [day.date, day])),
    weights: [...of('weight_entry')].sort((a, b) => Date.parse(a.at) - Date.parse(b.at)),
    plans: [...of('nutrition_plan')].sort(order),
  };
}

const kilograms = (mass) => mass.value * (mass.unit === 'lb' ? KG_PER_LB : 1);
const round = (value, places = 1) =>
  value == null ? null : Math.round(value * 10 ** places) / 10 ** places;

function addDays(date, days) {
  const day = new Date(`${date}T00:00:00Z`);
  day.setUTCDate(day.getUTCDate() + days);
  return day.toISOString().slice(0, 10);
}

/** 0 for Sunday, the index into a plan's targets. */
const weekday = (date) => new Date(`${date}T00:00:00Z`).getUTCDay();

function planOn(n, date) {
  return n.plans.filter((plan) => plan.startDate <= date).at(-1) ?? null;
}

function nutrients(entry) {
  const amounts = {};
  for (const [name, per100g] of Object.entries(entry.food?.per100g ?? {})) {
    amounts[name] = (per100g * entry.grams) / 100;
  }
  return amounts;
}

function totals(entries) {
  const sum = {};
  for (const entry of entries) {
    for (const [name, amount] of Object.entries(nutrients(entry)))
      sum[name] = (sum[name] ?? 0) + amount;
  }
  return sum;
}

/** The days EnergyBalance needs, as NutritionStore.energyBalanceDays builds them. */
function balanceDays(n, start, end) {
  const days = [];
  for (let date = start; date <= end; date = addDays(date, 1)) {
    const status = n.days.get(date)?.status ?? 'unlogged';
    const logged = n.entries.filter((entry) => entry.date === date);
    const energy = logged.reduce((sum, entry) => sum + (nutrients(entry).energy ?? 0), 0);
    days.push({
      date,
      // A day marked complete with nothing logged is unknown, not a zero.
      intake: status === 'fasting' || (status === 'complete' && logged.length) ? energy : null,
      weights: n.weights
        .filter((weight) => weight.date === date)
        .map((weight) => kilograms(weight.weight)),
    });
  }
  return days;
}

function readDate(value, name) {
  if (value == null || value === '') return null;
  const date = training.parseLocalDate(value);
  if (!date) throw badRequest(`${name} must be a date written YYYY-MM-DD`);
  return date;
}

function today(ws) {
  return training.localDate(new Date(), dates.normalizeTimeZone(ws.account.timezone));
}

/** One day: what was logged, its totals, and the targets that held that day. */
function nutritionDay(ws, { date } = {}) {
  const n = ws.nutrition;
  const day = readDate(date, 'date') ?? today(ws);
  const logged = n.entries
    .filter((entry) => entry.date === day)
    .sort((a, b) => Date.parse(a.loggedAt) - Date.parse(b.loggedAt));
  const sum = totals(logged);
  const plan = planOn(n, day);
  const targets = plan?.targets?.[weekday(day)] ?? null;
  const record = n.days.get(day);
  return {
    date: day,
    status: record?.status ?? 'unlogged',
    notes: record?.notes || null,
    totals: Object.fromEntries(
      Object.entries(sum).map(([name, amount]) => [name, round(amount, 2)])
    ),
    targets,
    remaining: targets
      ? Object.fromEntries(MACROS.map((name) => [name, round(targets[name] - (sum[name] ?? 0))]))
      : null,
    entries: logged.map((entry) => ({
      meal: entry.meal,
      food: entry.food?.name ?? null,
      brand: entry.food?.brand ?? null,
      grams: entry.grams,
      ...Object.fromEntries(MACROS.map((name) => [name, round(nutrients(entry)[name] ?? null)])),
    })),
    units:
      'Energy in kcal; protein, carbohydrate and fat in grams; other nutrients in ExerlyCore units (g, mg or µg).',
  };
}

/**
 * Days in a range with intake against targets, weigh-ins, and the smoothed
 * trend weight and expenditure, each with one standard deviation. The first
 * plan's expenditure basis is the prior, as for the phone's check-ins.
 */
function nutritionSummary(ws, { from, through } = {}) {
  const n = ws.nutrition;
  const end = readDate(through, 'through') ?? today(ws);
  const start = readDate(from, 'from') ?? addDays(end, -27);
  if (start > end) throw badRequest('from must be on or before through');
  if (addDays(start, 365) < end) throw badRequest('Ask for a year or less at a time');
  const first = [n.weights[0]?.date, n.plans[0]?.startDate].filter(Boolean).sort()[0];
  const basis = n.plans[0]?.basis;
  const estimates = first
    ? energyBalance.estimate(balanceDays(n, first < start ? first : start, end), {
        prior: basis ? { mean: basis.expenditure, error: basis.expenditureError } : null,
      })
    : [];
  const byDate = new Map(estimates.map((estimate) => [estimate.date, estimate]));
  const days = [];
  for (const day of balanceDays(n, start, end)) {
    const logged = totals(n.entries.filter((entry) => entry.date === day.date));
    const estimate = byDate.get(day.date);
    days.push({
      date: day.date,
      status: n.days.get(day.date)?.status ?? 'unlogged',
      energy: round(logged.energy ?? null),
      protein: round(logged.protein ?? null),
      target_energy: planOn(n, day.date)?.targets?.[weekday(day.date)]?.energy ?? null,
      weight: round(
        day.weights.length ? day.weights.reduce((a, b) => a + b, 0) / day.weights.length : null,
        2
      ),
      trend: round(estimate?.trend, 2),
      trend_error: round(estimate?.trendError, 2),
      expenditure: round(estimate?.expenditure, 0),
      expenditure_error: round(estimate?.expenditureError, 0),
    });
  }
  const plan = planOn(n, end);
  return {
    from: start,
    through: end,
    plan: plan
      ? {
          goal: plan.goal,
          mode: plan.mode,
          started: plan.startDate,
          check_in_day: WEEKDAYS[plan.checkInDay - 1] ?? null,
        }
      : null,
    days,
    units:
      'Energy and expenditure in kcal, protein in grams, weights in kilograms. Errors are one standard deviation; about 95 % of the time the truth is within two.',
  };
}

module.exports = { KINDS, prepare, nutritionDay, nutritionSummary, balanceDays };
