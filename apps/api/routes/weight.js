const express = require('express');

const store = require('../data');
const { asyncHandler, notFound, badRequest, conflict } = require('../lib/errors');
const sync = require('../lib/sync');
const { authenticate } = require('../lib/auth');
const v = require('../lib/validate');
const { requireUser, entryDateFor, rangeFor, timezoneFor } = require('../lib/users');
const dates = require('../lib/dates');
const { trendSeries, DEFAULT_ALPHA } = require('../lib/nutrition');

const router = express.Router();
router.use(authenticate);

// Everything is stored in kilograms. A client sending pounds converts first;
// mixing units at rest is how weight trackers end up with 180 kg users.
const LB_PER_KG = 2.20462262;

function toKilograms(body) {
  if (body.weight_kg != null) return v.num(body.weight_kg, 'weight_kg', { min: 20, max: 500 });
  if (body.weightKg != null) return v.num(body.weightKg, 'weightKg', { min: 20, max: 500 });
  if (body.weightLb != null) {
    return v.num(body.weightLb, 'weightLb', { min: 44, max: 1100 }) / LB_PER_KG;
  }
  if (body.weight != null && body.unit === 'lb') {
    return v.num(body.weight, 'weight', { min: 44, max: 1100 }) / LB_PER_KG;
  }
  return v.num(body.weight, 'weight', { min: 20, max: 500 });
}

router.get(
  '/',
  asyncHandler(async (req, res) => {
    const user = await requireUser(req.user.email);
    const { from, to } = rangeFor(req, user, { defaultDays: 90 });

    const entries = await store.find(
      'weights',
      { email: user.email, entry_date: { gte: from, lte: to } },
      { sort: { entry_date: -1 }, includeDeleted: req.query.include_deleted === 'true' }
    );
    res.json(entries.map((row) => record(row, row.entry_date)));
  })
);

function record(row, day) {
  return row
    ? { ...row, revision: row.revision ?? 1, source: row.source ?? 'manual' }
    : { entry_date: day, weight_kg: null, revision: 0, deleted_at: null };
}
async function dayRecord(user, day) {
  return record(
    await store.findOne(
      'weights',
      { email: user.email, entry_date: day },
      { includeDeleted: true }
    ),
    day
  );
}
function revision(req, current, required = false) {
  if (
    req.body?.base_revision == null &&
    req.get('If-Match') == null &&
    (required || current.revision_locked)
  ) {
    throw conflict('Read the current weigh-in and include its base_revision before changing it.', {
      current,
    });
  }
  sync.checkRevision(req, current);
}
async function refreshProfile(user) {
  const latest = await store.findOne(
    'weights',
    { email: user.email },
    { sort: { entry_date: -1 } }
  );
  await store.update('users', { id: user.id }, { weight: latest?.weight_kg ?? null });
}
async function owned(req) {
  const row = await store.findOne(
    'weights',
    { id: String(req.params.id), email: req.user.email },
    { includeDeleted: true }
  );
  if (!row) throw notFound('Weight entry not found');
  return record(row, row.entry_date);
}
router.get(
  '/day',
  asyncHandler(async (req, res) => {
    res.json(await dayRecord(req.account, entryDateFor(req, req.account, { allowFuture: true })));
  })
);

/**
 * The smoothed series the whole app reads from. Returns one point per calendar
 * day in the range, with `weight` null on days with no weigh-in and `trend`
 * carried forward, so a chart can plot both lines without client-side gap logic.
 */
router.get(
  '/trend',
  asyncHandler(async (req, res) => {
    const user = await requireUser(req.user.email);
    const tz = timezoneFor(user, req);
    const days = Math.min(730, Math.max(7, parseInt(req.query.days, 10) || 90));
    const to = dates.today(tz);
    const from = dates.addDays(to, -(days - 1));

    const entries = await store.find(
      'weights',
      { email: user.email, entry_date: { gte: from, lte: to } },
      { sort: { entry_date: 1 } }
    );

    const series = trendSeries(entries, {
      days: dates.rangeOfDays(from, to),
      alpha: DEFAULT_ALPHA,
    });
    const first = series[0];
    const last = series[series.length - 1];

    res.json({
      from,
      to,
      alpha: DEFAULT_ALPHA,
      series,
      // Rate of change is what a user actually acts on. Reported per week
      // because that's the unit goals are set in.
      summary: series.length
        ? {
            current_trend_kg: last.trend,
            current_weight_kg: [...series].reverse().find((d) => d.weight != null)?.weight ?? null,
            change_kg: Number((last.trend - first.trend).toFixed(2)),
            weekly_rate_kg:
              series.length > 1
                ? Number((((last.trend - first.trend) / (series.length - 1)) * 7).toFixed(3))
                : 0,
            weigh_ins: series.filter((d) => d.weight != null).length,
            days: series.length,
          }
        : null,
    });
  })
);

router.get(
  '/:id',
  asyncHandler(async (req, res) => {
    const row = await owned(req);
    if (row.deleted_at && req.query.include_deleted !== 'true')
      throw notFound('Weight entry not found');
    res.json(row);
  })
);

// One calendar-day identity survives edits, deletion and explicit restoration.
async function save(req, res, strict) {
  const user = req.account;
  const entryDate = entryDateFor(req, user);
  const current = await dayRecord(user, entryDate);
  revision(req, current, strict);
  if (current.deleted_at)
    throw conflict('This weigh-in was deleted. Review it before restoring.', { current });
  const weightKg = toKilograms(req.body || {});
  if (weightKg < 20 || weightKg > 500) throw badRequest('Weight must be between 20 and 500 kg');
  const source = v.oneOf(req.body.source ?? 'manual', 'source', ['manual', 'healthkit', 'import']);
  if (current.id && source !== 'manual' && ['manual', 'onboarding'].includes(current.source)) {
    throw conflict(
      'A manual reading already exists for this day. Imported readings cannot replace it.',
      { current }
    );
  }
  // Automatic imports also need a reviewed version when replacing another import.
  if (current.id && source !== 'manual') revision(req, current, true);
  const now = new Date();
  const saved = await store.upsert(
    'weights',
    { email: user.email, entry_date: entryDate },
    {
      account_id: user.id,
      weight_kg: Number(weightKg.toFixed(2)),
      body_fat_pct: v.num(req.body.bodyFatPct ?? req.body.body_fat_pct, 'bodyFatPct', {
        required: false,
        min: 1,
        max: 70,
      }),
      note: v.str(req.body.note, 'note', { required: false, max: 280 }),
      source,
      revision: current.revision + 1,
      revision_locked:
        !!current.revision_locked ||
        strict ||
        req.body.base_revision != null ||
        req.get('If-Match') != null,
      created_at: current.created_at ?? now,
      updated_at: now,
    }
  );
  await refreshProfile(user);
  await sync.change(user, 'weight', { ...saved, client_id: entryDate });
  res.status(strict ? 200 : 201).json(saved);
}
router.put(
  '/day',
  asyncHandler((req, res) => save(req, res, true))
);
router.post(
  '/',
  asyncHandler((req, res) => save(req, res, false))
);

router.delete(
  '/:id',
  asyncHandler(async (req, res) => {
    const current = await owned(req);
    revision(req, current);
    if (current.deleted_at) return res.json({ message: 'Weight entry deleted', weight: current });
    const row = await store.update(
      'weights',
      { id: current.id },
      {
        account_id: req.account.id,
        deleted_at: new Date(),
        updated_at: new Date(),
        revision: current.revision + 1,
        revision_locked: true,
      }
    );
    await refreshProfile(req.account);
    await sync.change(req.account, 'weight', { ...row, client_id: row.entry_date });
    res.json({ message: 'Weight entry deleted', weight: row });
  })
);
router.post(
  '/:id/restore',
  asyncHandler(async (req, res) => {
    const current = await owned(req);
    revision(req, current, true);
    if (!current.deleted_at) return res.json(current);
    const row = await store.update(
      'weights',
      { id: current.id },
      {
        account_id: req.account.id,
        deleted_at: null,
        updated_at: new Date(),
        revision: current.revision + 1,
        revision_locked: true,
      }
    );
    await refreshProfile(req.account);
    await sync.change(req.account, 'weight', { ...row, client_id: row.entry_date });
    res.json(row);
  })
);

module.exports = router;
module.exports.toKilograms = toKilograms;
