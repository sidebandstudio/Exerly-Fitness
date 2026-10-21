const express = require('express');

const store = require('../data');
const { asyncHandler } = require('../lib/errors');
const { authenticate } = require('../lib/auth');
const v = require('../lib/validate');
const { requireUser, normalizeProfile } = require('../lib/users');

const router = express.Router();
router.use(authenticate);

// Accepts camelCase (web) and snake_case (iOS) for every field.
const FIELDS = [
  ['daily_calories', ['dailyCalories', 'daily_calories'], { min: 0, max: 20000 }],
  ['protein_g', ['proteinG', 'protein_g', 'protein'], { min: 0, max: 1000 }],
  ['carbs_g', ['carbsG', 'carbs_g', 'carbs'], { min: 0, max: 2000 }],
  ['fat_g', ['fatG', 'fat_g', 'fat'], { min: 0, max: 1000 }],
  ['fiber_g', ['fiberG', 'fiber_g', 'fiber'], { min: 0, max: 300 }],
  ['weekly_workouts', ['weeklyWorkouts', 'weekly_workouts'], { min: 0, max: 30 }],
  ['daily_steps', ['dailySteps', 'daily_steps'], { min: 0, max: 100000 }],
  ['weekly_weight', ['weeklyWeight', 'weekly_weight'], { min: -10, max: 10 }],
  ['sleep_hours', ['sleepHours', 'sleep_hours'], { min: 0, max: 24 }],
  ['water_ml', ['waterMl', 'water_ml'], { min: 0, max: 30000 }],
];

const ML_PER_GLASS = 250;

router.get(
  '/',
  asyncHandler(async (req, res) => {
    const goals = await store.findOne('goals', { email: req.user.email });
    if (!goals) return res.json({});
    // `water_intake` was the old glasses-based name. Kept in the response so
    // existing clients keep rendering.
    res.json({ ...goals, water_intake: goals.water_ml ? goals.water_ml / ML_PER_GLASS : null });
  })
);

router.post(
  '/',
  asyncHandler(async (req, res) => {
    const body = req.body || {};
    const patch = { updated_at: new Date() };

    for (const [column, aliases, bounds] of FIELDS) {
      const key = aliases.find((a) => body[a] != null);
      if (key === undefined) continue;
      // A stored 0 used to become null because the old code used `|| null`,
      // which meant "no calorie goal" and "a goal of zero" were the same value.
      patch[column] = v.num(body[key], column, { required: false, ...bounds });
    }

    if (patch.water_ml == null && body.water_intake != null) {
      patch.water_ml =
        v.num(body.water_intake, 'water_intake', { required: false, min: 0, max: 100 }) *
        ML_PER_GLASS;
    }

    const goals = await store.upsert('goals', { email: req.user.email }, patch);
    // Older clients can edit these goals directly. Keep the preference editor's
    // revision and values current so it cannot silently overwrite those edits.
    if ('weekly_workouts' in patch || 'sleep_hours' in patch) {
      const user = await requireUser(req.user.email);
      const profile = { ...normalizeProfile(user.profile) };
      const updates = {
        profile,
        preferences_revision: (user.preferences_revision ?? 0) + 1,
        preferences_updated_at: new Date(),
      };
      if ('weekly_workouts' in patch) updates.workoutDaysPerWeek = patch.weekly_workouts;
      if ('sleep_hours' in patch) profile.sleepGoalHours = patch.sleep_hours;
      await store.update('users', { id: user.id }, updates);
    }
    if (
      ['daily_calories', 'protein_g', 'carbs_g', 'fat_g', 'fiber_g', 'water_ml'].some(
        (key) => key in patch
      )
    ) {
      const user = await requireUser(req.user.email);
      const program = await require('../lib/expenditure').getOrCreateProgram(user.email);
      const targets = require('../lib/targets').snapshot(program, goals);
      for (const [field, target] of [
        ['daily_calories', 'calories'],
        ['protein_g', 'protein_g'],
        ['carbs_g', 'carbs_g'],
        ['fat_g', 'fat_g'],
      ]) {
        if (field in patch) targets[target] = patch[field];
      }
      if (['daily_calories', 'protein_g', 'carbs_g', 'fat_g'].some((key) => key in patch)) {
        await store.update('programs', { id: program.id }, { target_mode: 'manual' });
      }
      await require('../lib/targets').accept(user, targets, { reason: 'goals_changed' });
    }
    res.json({ message: 'Goals saved successfully', goals });
  })
);

module.exports = router;
module.exports.FIELDS = FIELDS;
