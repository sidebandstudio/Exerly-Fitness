const express = require('express');

const store = require('../data');
const { asyncHandler, badRequest } = require('../lib/errors');
const { authenticate } = require('../lib/auth');
const v = require('../lib/validate');
const { requireUser, timezoneFor } = require('../lib/users');
const dates = require('../lib/dates');
const { DIET_TYPES } = require('../lib/nutrition');
const expenditureLib = require('../lib/expenditure');

const router = express.Router();
router.use(authenticate);

const GOAL_TYPES = ['lose', 'maintain', 'gain'];
const PROTEIN_STRATEGIES = ['low', 'moderate', 'high'];

// Rates beyond this are not achievable as tissue change; anything faster is
// water or muscle. Capping here rather than in the client keeps every caller honest.
const MAX_RATE_KG_PER_WEEK = 1.5;

function serializeProgram(program, expenditure) {
  return {
    goal_type: program.goal_type,
    target_mode: program.target_mode || 'estimated',
    rate_kg_per_week: program.rate_kg_per_week,
    target_weight_kg: program.target_weight_kg ?? null,
    diet_type: program.diet_type,
    protein_strategy: program.protein_strategy,
    last_checkin_date: program.last_checkin_date ?? null,
    targets: {
      calories: program.calories ?? null,
      protein_g: program.protein_g ?? null,
      carbs_g: program.carbs_g ?? null,
      fat_g: program.fat_g ?? null,
    },
    expenditure: {
      value: program.expenditure ?? null,
      confidence: program.expenditure_confidence ?? 'estimated',
      ...(expenditure
        ? {
            live: expenditure.expenditure,
            live_confidence: expenditure.confidence,
            measured: expenditure.measured,
            formula: expenditure.formula,
            mean_intake: expenditure.meanIntake,
            trend_change_kg: expenditure.trendChangeKg,
            days_logged: expenditure.daysLogged,
            window_days: expenditure.windowDays,
            reason: expenditure.reason,
          }
        : {}),
    },
  };
}

router.get(
  '/',
  asyncHandler(async (req, res) => {
    const user = await requireUser(req.user.email);
    const program = await expenditureLib.getOrCreateProgram(user.email);
    const today = dates.today(timezoneFor(user, req));

    const { expenditure, targets } = await expenditureLib.refreshTargets(user, program, { today });

    // The stored targets only move at check-in, so the numbers a user plans
    // meals around stay put. `suggested` is what the next check-in would set.
    res.json({
      ...serializeProgram(program, expenditure),
      suggested_targets: targets,
      needs_checkin: needsCheckin(program, today),
    });
  })
);

router.put(
  '/',
  asyncHandler(async (req, res) => {
    const user = await requireUser(req.user.email);
    const program = await expenditureLib.getOrCreateProgram(user.email);
    const body = req.body || {};
    const patch = { updated_at: new Date() };

    if (body.goal_type != null || body.goalType != null) {
      patch.goal_type = v.oneOf(body.goal_type ?? body.goalType, 'goal_type', GOAL_TYPES);
    }
    if (body.diet_type != null || body.dietType != null) {
      patch.diet_type = v.oneOf(body.diet_type ?? body.dietType, 'diet_type', DIET_TYPES);
    }
    if (body.protein_strategy != null || body.proteinStrategy != null) {
      patch.protein_strategy = v.oneOf(
        body.protein_strategy ?? body.proteinStrategy,
        'protein_strategy',
        PROTEIN_STRATEGIES
      );
    }
    if (body.target_weight_kg != null || body.targetWeightKg != null) {
      patch.target_weight_kg = v.num(
        body.target_weight_kg ?? body.targetWeightKg,
        'target_weight_kg',
        { min: 20, max: 500 }
      );
    }

    const rawRate = body.rate_kg_per_week ?? body.rateKgPerWeek;
    if (rawRate != null) {
      patch.rate_kg_per_week = v.num(rawRate, 'rate_kg_per_week', {
        min: -MAX_RATE_KG_PER_WEEK,
        max: MAX_RATE_KG_PER_WEEK,
      });
    }

    // A goal of "lose" with a positive rate is a contradiction the UI shouldn't
    // be able to produce, but the sign gets normalized rather than rejected.
    const goal = patch.goal_type ?? program.goal_type;
    if (patch.rate_kg_per_week != null) {
      if (goal === 'lose') patch.rate_kg_per_week = -Math.abs(patch.rate_kg_per_week);
      if (goal === 'gain') patch.rate_kg_per_week = Math.abs(patch.rate_kg_per_week);
      if (goal === 'maintain') patch.rate_kg_per_week = 0;
    } else if (patch.goal_type === 'maintain') {
      patch.rate_kg_per_week = 0;
    }

    const updatedProgram = await store.update('programs', { id: program.id }, patch);
    const today = dates.today(timezoneFor(user, req));
    const { expenditure, targets } = await expenditureLib.refreshTargets(user, updatedProgram, {
      today,
    });

    // Changing the plan applies immediately. Waiting for the next check-in to
    // honour a deliberate settings change would just be confusing.
    const saved = await store.update(
      'programs',
      { id: program.id },
      {
        calories: targets?.calories ?? null,
        protein_g: targets?.protein_g ?? null,
        carbs_g: targets?.carbs_g ?? null,
        fat_g: targets?.fat_g ?? null,
        expenditure: expenditure.expenditure,
        expenditure_confidence: expenditure.confidence,
      }
    );

    if (targets)
      await require('../lib/targets').accept(user, targets, {
        date: today,
        reason: 'program_changed',
      });
    res.json(serializeProgram(saved, expenditure));
  })
);

/**
 * Weekly check-in: re-measure expenditure, move the targets, and record what
 * the numbers looked like at the time so the history is auditable.
 */
router.post(
  '/checkin',
  asyncHandler(async (req, res) => {
    const user = await requireUser(req.user.email);
    const program = await expenditureLib.getOrCreateProgram(user.email);
    const today = dates.today(timezoneFor(user, req));

    const { expenditure, targets, weightKg } = await expenditureLib.refreshTargets(user, program, {
      today,
    });
    if (!targets) {
      throw badRequest(
        'Not enough profile data to set targets. Add your height, age, and a weigh-in first.'
      );
    }

    const checkin = await store.upsert(
      'checkins',
      { email: user.email, entry_date: today },
      {
        expenditure: expenditure.expenditure,
        expenditure_confidence: expenditure.confidence,
        mean_intake: expenditure.meanIntake,
        trend_weight_kg: weightKg ?? null,
        trend_change_kg: expenditure.trendChangeKg,
        days_logged: expenditure.daysLogged,
        window_days: expenditure.windowDays,
        calories: targets.calories,
        protein_g: targets.protein_g,
        carbs_g: targets.carbs_g,
        fat_g: targets.fat_g,
        previous_calories: program.calories ?? null,
        note: v.str(req.body?.note, 'note', { required: false, max: 500 }),
        created_at: new Date(),
      }
    );

    const saved = await store.update(
      'programs',
      { id: program.id },
      {
        calories: targets.calories,
        protein_g: targets.protein_g,
        carbs_g: targets.carbs_g,
        fat_g: targets.fat_g,
        expenditure: expenditure.expenditure,
        expenditure_confidence: expenditure.confidence,
        last_checkin_date: today,
        updated_at: new Date(),
      }
    );

    // Goals stay in sync so the dashboard rings and anything reading /api/goals
    // show the same numbers as the program.
    await store.upsert(
      'goals',
      { email: user.email },
      {
        daily_calories: targets.calories,
        protein_g: targets.protein_g,
        carbs_g: targets.carbs_g,
        fat_g: targets.fat_g,
        fiber_g: targets.fiber_g,
        updated_at: new Date(),
      }
    );

    await require('../lib/targets').accept(user, targets, {
      date: today,
      reason: 'checkin',
      checkinID: checkin.id,
    });

    res.json({
      message: 'Check-in complete',
      checkin,
      program: serializeProgram(saved, expenditure),
      change: {
        calories: targets.calories - (program.calories ?? targets.calories),
      },
    });
  })
);

router.get(
  '/targets/history',
  asyncHandler(async (req, res) => {
    res.json(
      await store.find(
        'target_versions',
        { account_id: req.account.id },
        { sort: { effective_date: -1, created_at: -1 }, limit: 500 }
      )
    );
  })
);

router.get(
  '/checkins',
  asyncHandler(async (req, res) => {
    const limit = Math.min(104, Math.max(1, parseInt(req.query.limit, 10) || 26));
    res.json(
      await store.find('checkins', { email: req.user.email }, { sort: { entry_date: -1 }, limit })
    );
  })
);

router.get(
  '/expenditure',
  asyncHandler(async (req, res) => {
    const user = await requireUser(req.user.email);
    const windowDays = Math.min(90, Math.max(14, parseInt(req.query.days, 10) || 28));
    const result = await expenditureLib.currentExpenditure(user, {
      today: dates.today(timezoneFor(user, req)),
      windowDays,
    });

    // The full trend array is large and the caller here only wants the number.
    const { trend, ...summary } = result;
    res.json({ ...summary, trend_points: trend.length });
  })
);

// A check-in is due a week after the last one. Before the first, it's due as
// soon as there's enough data to measure anything.
function needsCheckin(program, today) {
  if (!program.last_checkin_date) return true;
  return dates.daysBetween(program.last_checkin_date, today) >= 7;
}

module.exports = router;
Object.assign(module.exports, { GOAL_TYPES, PROTEIN_STRATEGIES, MAX_RATE_KG_PER_WEEK });
