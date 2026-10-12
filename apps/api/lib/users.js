// User lookup, serialization, and per-user date resolution.

const store = require('../data');
const { notFound, badRequest } = require('./errors');
const dates = require('./dates');

function normalizeProfile(profile) {
  return profile && typeof profile === 'object' && !Array.isArray(profile) ? profile : {};
}

// The shape both clients expect. iOS decodes `_id`, so it stays.
function serializeUser(user) {
  if (!user) return null;
  const profile = normalizeProfile(user.profile);
  const remainingCredits = user.aiCreditsRemaining ?? null;

  return {
    _id: user.id ? String(user.id) : undefined,
    email: user.email,
    name: user.name ?? null,
    isAdmin: !!user.is_admin,
    onboardingCompleted: !!user.onboardingCompleted,
    age: user.age ?? profile.age ?? null,
    gender: user.gender ?? profile.gender ?? profile.sex ?? null,
    height: user.height ?? profile.height ?? profile.height_cm ?? null,
    weight: user.weight ?? profile.weight ?? profile.weight_kg ?? null,
    activityLevel: profile.activityLevel ?? profile.activity_level ?? null,
    goal: user.goal ?? profile.goal ?? null,
    targetWeight: profile.targetWeight ?? profile.target_weight ?? null,
    experienceLevel: user.experienceLevel ?? null,
    workoutDaysPerWeek: user.workoutDaysPerWeek ?? null,
    equipmentAccess: user.equipmentAccess ?? null,
    timezone: user.timezone ?? 'UTC',
    unitSystem: user.unitSystem ?? 'imperial',
    preferencesRevision: user.preferences_revision ?? 0,
    nutritionDisplay: profile.nutritionDisplay ?? 'remaining',
    waterGoalMl: profile.waterGoalMl ?? null,
    aiCreditsRemaining: remainingCredits,
    dailyAiCreditsUsed: user.aiDailyCreditsUsed ?? 0,
    hourlyAiCreditsUsed:
      remainingCredits == null ? null : Math.max(0, 5 - Number(remainingCredits)),
  };
}

// Fields every new account starts with, whichever way it signs up.
function newUserFields({ name, email, hash = null, isAdmin = false, timezone, unitSystem }) {
  const now = new Date();
  return {
    name,
    email,
    hash,
    is_admin: isAdmin,
    timezone,
    unitSystem: unitSystem === 'metric' ? 'metric' : 'imperial',
    profile: {},
    created_at: now,
    onboardingCompleted: false,
    aiCreditsRemaining: 5,
    aiDailyCreditsUsed: 0,
    aiLastCreditReset: now,
    aiDailyResetDate: now,
  };
}

async function requireUser(email) {
  const user = await store.findOne('users', { email });
  if (!user) throw notFound('User not found');
  return user;
}

// Which timezone this request's "today" should be computed in. The stored
// preference wins; the header is a fallback so a client can work correctly
// before the user has ever saved a setting.
function timezoneFor(user, req) {
  const header = req?.get?.('X-Timezone');
  return dates.normalizeTimeZone(user?.timezone || header || 'UTC');
}

/**
 * The calendar day a log belongs to.
 *
 * A client may send `entry_date` to log to any day. When it doesn't, we fall
 * back to today *in the user's timezone*, which is the fix for the old
 * behaviour of stamping everything with UTC today.
 */
function entryDateFor(req, user, { field = 'entry_date', allowFuture = false } = {}) {
  const supplied = req.body?.[field] ?? req.query?.[field];
  const tz = timezoneFor(user, req);
  const todayLocal = dates.today(tz);

  if (supplied == null || supplied === '') return todayLocal;
  if (!dates.isValidDateStr(supplied)) throw badRequest(`${field} must be a YYYY-MM-DD date`);

  if (!allowFuture && supplied > todayLocal) {
    throw badRequest('Cannot log to a future date');
  }
  // Ten years back is generous for an import and still stops a typo like
  // "0226-08-29" from landing in the database.
  if (dates.daysBetween(supplied, todayLocal) > 3650) {
    throw badRequest('Date is too far in the past');
  }
  return supplied;
}

/**
 * Resolve a ?from=&to= pair for list endpoints, defaulting to a recent window
 * rather than the user's entire history.
 */
function rangeFor(req, user, { defaultDays = 30, maxDays = 400 } = {}) {
  const tz = timezoneFor(user, req);
  const todayLocal = dates.today(tz);

  const to = req.query.to ? String(req.query.to) : todayLocal;
  if (!dates.isValidDateStr(to)) throw badRequest('to must be a YYYY-MM-DD date');

  const from = req.query.from ? String(req.query.from) : dates.addDays(to, -(defaultDays - 1));
  if (!dates.isValidDateStr(from)) throw badRequest('from must be a YYYY-MM-DD date');

  if (from > to) throw badRequest('from must be on or before to');
  if (dates.daysBetween(from, to) > maxDays) {
    throw badRequest(`Range cannot exceed ${maxDays} days`);
  }
  return { from, to, timezone: tz, today: todayLocal };
}

function paginationFor(req, { defaultLimit = 200, maxLimit = 1000 } = {}) {
  const limit = Math.min(maxLimit, Math.max(1, parseInt(req.query.limit, 10) || defaultLimit));
  const page = Math.max(1, parseInt(req.query.page, 10) || 1);
  return { limit, skip: (page - 1) * limit, page };
}

module.exports = {
  newUserFields,
  normalizeProfile,
  serializeUser,
  requireUser,
  timezoneFor,
  entryDateFor,
  rangeFor,
  paginationFor,
};
