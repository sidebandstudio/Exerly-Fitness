const store = require('../data');
const v = require('./validate');
const { badRequest, conflict } = require('./errors');
const { normalizeProfile, serializeUser, requireUser } = require('./users');
const { isValidTimeZone } = require('./dates');
const { ACTIVITY_MULTIPLIERS } = require('./nutrition');

const days = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
const profileFields = [
  'dietaryStyle',
  'allergies',
  'mealsPerDay',
  'equipment',
  'activityTypes',
  'workoutDays',
  'sleepGoalHours',
  'bedtime',
  'wakeTime',
  'reminders',
  'reminderTimes',
  'nutritionDisplay',
  'waterGoalMl',
];
const accountFields = [
  'name',
  'age',
  'gender',
  'height',
  'experienceLevel',
  'workoutDaysPerWeek',
  'equipmentAccess',
  'timezone',
  'unitSystem',
];
const fields = [...accountFields, 'activityLevel', ...profileFields];
const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
const object = (value) => value && typeof value === 'object' && !Array.isArray(value);

function strings(value, key, max = 32) {
  if (!Array.isArray(value) || value.length > max)
    throw badRequest(`${key} must be a list of at most ${max} values`);
  return [...new Set(value.map((item) => v.str(item, key, { max: 80 })))];
}
function clock(value, key) {
  if (value === null) return null;
  if (typeof value !== 'string' || !/^([01]\d|2[0-3]):[0-5]\d$/.test(value))
    throw badRequest(`${key} must use HH:mm`);
  return value;
}
function validate(changes) {
  if (!object(changes) || !Object.keys(changes).length)
    throw badRequest('Provide the preferences to change');
  for (const key of Object.keys(changes))
    if (!fields.includes(key)) throw badRequest(`Unsupported preference: ${key}`);
  const result = {};
  for (const [key, value] of Object.entries(changes)) {
    if (['name', 'gender', 'equipmentAccess'].includes(key))
      result[key] = v.str(value, key, { max: key === 'gender' ? 32 : 80 });
    else if (key === 'age') result[key] = v.int(value, key, { min: 18, max: 120 });
    else if (key === 'height') result[key] = v.num(value, key, { min: 50, max: 280 });
    else if (key === 'unitSystem') result[key] = v.oneOf(value, key, ['metric', 'imperial']);
    else if (key === 'experienceLevel')
      result[key] = v.oneOf(value, key, ['beginner', 'intermediate', 'advanced']);
    else if (key === 'activityLevel')
      result[key] = v.oneOf(value, key, Object.keys(ACTIVITY_MULTIPLIERS));
    else if (key === 'timezone') {
      if (typeof value !== 'string' || !isValidTimeZone(value))
        throw badRequest('Choose a valid time zone');
      result[key] = value;
    } else if (key === 'dietaryStyle')
      result[key] = v.str(value, key, { max: 64, required: false });
    else if (['allergies', 'equipment', 'activityTypes', 'workoutDays'].includes(key)) {
      result[key] = strings(value, key, key === 'workoutDays' ? 7 : 32);
      if (key === 'workoutDays') result[key] = result[key].map((day) => v.oneOf(day, key, days));
    } else if (key === 'workoutDaysPerWeek') result[key] = v.int(value, key, { min: 0, max: 7 });
    else if (key === 'mealsPerDay')
      result[key] = v.int(value, key, { min: 1, max: 10, required: false });
    else if (key === 'sleepGoalHours')
      result[key] = v.num(value, key, { min: 1, max: 16, required: false });
    else if (['bedtime', 'wakeTime'].includes(key)) result[key] = clock(value, key);
    // Whether Today leads with what's left of each target or what's been eaten.
    else if (key === 'nutritionDisplay')
      result[key] = v.oneOf(value, key, ['remaining', 'consumed'], { required: false });
    else if (key === 'waterGoalMl')
      result[key] = v.int(value, key, { min: 250, max: 10000, required: false });
    else if (key === 'reminders') {
      if (
        !object(value) ||
        Object.keys(value).some((name) => !['meals', 'workouts', 'sleep', 'weighIn'].includes(name))
      )
        throw badRequest('Choose valid reminder preferences');
      result[key] = Object.fromEntries(
        Object.entries(value).map(([name, enabled]) => [
          name,
          v.bool(enabled, `reminders.${name}`, { required: true }),
        ])
      );
    } else if (key === 'reminderTimes') {
      if (
        !object(value) ||
        Object.keys(value).some((name) => !['meals', 'workout', 'sleep', 'weighIn'].includes(name))
      )
        throw badRequest('Choose valid reminder times');
      result[key] = {};
      for (const [name, times] of Object.entries(value)) {
        if (name === 'meals') {
          if (!Array.isArray(times) || times.length > 10)
            throw badRequest('Choose up to ten meal reminder times');
          result[key].meals = [
            ...new Set(
              times.map((time) => {
                if (time === null) throw badRequest('Choose a meal reminder time');
                return clock(time, 'Meal reminder');
              })
            ),
          ].sort();
        } else result[key][name] = clock(times, `${name} reminder`);
      }
    }
  }
  return result;
}

function revision(user) {
  return user.preferences_revision ?? 0;
}
function envelope(user) {
  const profile = normalizeProfile(user.profile);
  const serialized = serializeUser(user);
  const values = Object.fromEntries(accountFields.map((key) => [key, serialized[key] ?? null]));
  values.activityLevel = serialized.activityLevel;
  for (const key of profileFields) values[key] = profile[key] ?? null;
  for (const key of ['allergies', 'equipment', 'activityTypes', 'workoutDays']) values[key] ??= [];
  values.reminders ??= {};
  values.reminderTimes ??= {};
  return {
    schema_version: 1,
    account_id: String(user.id),
    revision: revision(user),
    updated_at: user.preferences_updated_at ?? null,
    values,
    user: serialized,
  };
}

async function apply(user, raw, { baseRevision, legacy = false } = {}) {
  if (!legacy && v.int(baseRevision, 'base_revision', { min: 0 }) !== revision(user))
    throw conflict(
      'Preferences changed on another device. Review the saved version before continuing.',
      { current: envelope(user) }
    );
  const changes = validate(raw);
  const profile = { ...normalizeProfile(user.profile) };
  const updates = { preferences_revision: revision(user) + 1, preferences_updated_at: new Date() };
  for (const [key, value] of Object.entries(changes)) {
    if (accountFields.includes(key)) updates[key] = value;
    else if (['reminders', 'reminderTimes'].includes(key))
      profile[key] = { ...profile[key], ...value };
    else profile[key] = value;
    if (['age', 'gender', 'height'].includes(key)) profile[key] = value;
  }
  if (own(changes, 'height')) profile.height_cm = changes.height;
  if (own(changes, 'activityLevel')) profile.activity_level = changes.activityLevel;
  updates.profile = profile;
  await store.update('users', { id: user.id }, updates);
  const goals = {};
  if (own(changes, 'workoutDaysPerWeek')) goals.weekly_workouts = changes.workoutDaysPerWeek;
  if (own(changes, 'sleepGoalHours')) goals.sleep_hours = changes.sleepGoalHours;
  if (own(changes, 'waterGoalMl')) goals.water_ml = changes.waterGoalMl;
  if (Object.keys(goals).length)
    await store.upsert('goals', { email: user.email }, { ...goals, updated_at: new Date() });
  return envelope(await requireUser(user.email));
}

// Installed clients keep their existing response shapes, but known values now
// use the same validation and increment the same revision as the new editors.
async function applyLegacy(user, body) {
  if (!object(body)) throw badRequest('Profile must be an object');
  const aliases = { height_cm: 'height', activity_level: 'activityLevel' };
  const changes = {};
  const profile = { ...normalizeProfile(user.profile) };
  const extra = {};
  for (const [raw, value] of Object.entries(body)) {
    const key = aliases[raw] ?? raw;
    if (fields.includes(key)) {
      changes[key] = value;
      continue;
    }
    if (['weight', 'weight_kg'].includes(key)) {
      const weight = v.num(value, key, { min: 20, max: 500 });
      extra.weight = weight;
      profile.weight = weight;
      profile.weight_kg = weight;
    } else if (['targetWeight', 'target_weight'].includes(key)) {
      const target = v.num(value, key, { min: 20, max: 500, required: false });
      profile.targetWeight = target;
      profile.target_weight = target;
    } else if (key === 'goal') {
      extra.goal = v.oneOf(value, key, [
        'lose',
        'lose_weight',
        'weight_loss',
        'maintain',
        'gain',
        'gain_muscle',
        'muscle_gain',
        'improve_endurance',
        'general_health',
      ]);
      profile.goal = extra.goal;
    } else if (key === 'sex')
      profile.sex = v.oneOf(value, key, ['male', 'female'], { required: false });
    else if (key === 'email_notifications') profile[key] = v.bool(value, key, { required: true });
    else if (key === 'privacy_settings')
      profile[key] = v.oneOf(value, key, ['private', 'friends', 'public']);
    else if (key === 'target_date') profile[key] = v.dateStr(value, key, { required: false });
    else throw badRequest(`Unsupported profile field: ${raw}`);
  }
  if (Object.keys(changes).length) {
    await store.update('users', { id: user.id }, { ...extra, profile });
    return apply(await requireUser(user.email), changes, { legacy: true });
  }
  if (!Object.keys(body).length) throw badRequest('Provide the profile fields to change');
  await store.update(
    'users',
    { id: user.id },
    {
      ...extra,
      profile,
      preferences_revision: revision(user) + 1,
      preferences_updated_at: new Date(),
    }
  );
  return envelope(await requireUser(user.email));
}

module.exports = { fields, validate, envelope, apply, applyLegacy };
