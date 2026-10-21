const express = require('express');
const store = require('../data');
const { authenticate } = require('../lib/auth');
const { asyncHandler, badRequest, conflict, notFound } = require('../lib/errors');
const { entryDateFor, rangeFor, timezoneFor } = require('../lib/users');
const v = require('../lib/validate');
const sync = require('../lib/sync');

const router = express.Router();
router.use(authenticate);
// Sites measured once, then each limb on both sides. `arms`, `thighs` and
// `calves` are older sides-unknown sites, still accepted so their history stays editable.
const sides = ['ankle', 'bicep', 'calf', 'forearm', 'thigh', 'wrist'].flatMap((site) => [
  `left_${site}`,
  `right_${site}`,
]);
const types = [
  'bust',
  'chest',
  'hips',
  'neck',
  'shoulders',
  'waist',
  ...sides,
  'arms',
  'thighs',
  'calves',
  'body_fat',
];

function readMeasurement(req) {
  const type = v.oneOf(req.body.type, 'type', types);
  const unit = v.oneOf(req.body.unit, 'unit', type === 'body_fat' ? ['%'] : ['cm', 'in']);
  const entered = v.num(req.body.value, 'value', { min: 0.01, max: 1000 });
  const value = unit === 'in' ? entered * 2.54 : entered;
  if (value > (type === 'body_fat' ? 100 : 1000)) throw badRequest('Measurement is out of range');
  return {
    type,
    value: Number(value.toFixed(4)),
    unit: type === 'body_fat' ? '%' : 'cm',
    entered_value: entered,
    entered_unit: unit,
    entry_date: entryDateFor(req, req.account),
    timezone: timezoneFor(req.account, req),
    note: v.str(req.body.note, 'note', { required: false, max: 1000 }),
    // `imported`: from another app's export, named in the note.
    source: v.oneOf(req.body.source ?? 'manual', 'source', [
      'manual',
      'legacy_device_import',
      'imported',
    ]),
  };
}
async function owned(req, includeDeleted = false) {
  const row = await store.findOne(
    'measurements',
    {
      id: String(req.params.id),
      account_id: req.account.id,
    },
    { includeDeleted }
  );
  if (!row) throw notFound('Measurement not found');
  return row;
}
function revision(req, row) {
  if (req.get('If-Match') == null && req.body?.base_revision == null)
    throw badRequest('base_revision is required');
  sync.checkRevision(req, row);
}

router.get(
  '/',
  asyncHandler(async (req, res) => {
    const { from, to } = rangeFor(req, req.account, { defaultDays: 365, maxDays: 3650 });
    const filter = { account_id: req.account.id, entry_date: { gte: from, lte: to } };
    if (req.query.type != null) filter.type = v.oneOf(req.query.type, 'type', types);
    const limit = v.int(req.query.limit ?? 200, 'limit', { min: 1, max: 500 });
    const offset = v.int(req.query.offset ?? 0, 'offset', { min: 0 });
    res.json({
      entries: await store.find('measurements', filter, {
        sort: { entry_date: -1, id: -1 },
        limit,
        skip: offset,
      }),
      total: await store.count('measurements', filter),
      limit,
      offset,
    });
  })
);

router.get(
  '/:id',
  asyncHandler(async (req, res) => {
    res.json(await owned(req, req.query.include_deleted === 'true'));
  })
);

router.post(
  '/',
  asyncHandler(async (req, res) => {
    const clientID = sync.entityID(req.body.client_id);
    const existing = await store.findOne(
      'measurements',
      {
        account_id: req.account.id,
        client_id: clientID,
      },
      { includeDeleted: true }
    );
    if (existing) throw conflict('This measurement already exists', { current: existing });
    const now = new Date();
    const row = await store.insert('measurements', {
      ...readMeasurement(req),
      account_id: req.account.id,
      client_id: clientID,
      revision: 1,
      created_at: now,
      updated_at: now,
    });
    await sync.change(req.account, 'measurement', row);
    res.status(201).json(row);
  })
);

router.put(
  '/:id',
  asyncHandler(async (req, res) => {
    const current = await owned(req);
    revision(req, current);
    const row = await store.update(
      'measurements',
      { id: current.id, account_id: req.account.id },
      {
        ...readMeasurement(req),
        revision: current.revision + 1,
        updated_at: new Date(),
      }
    );
    await sync.change(req.account, 'measurement', row);
    res.json(row);
  })
);

router.delete(
  '/:id',
  asyncHandler(async (req, res) => {
    const current = await owned(req);
    revision(req, current);
    const row = await store.update(
      'measurements',
      { id: current.id, account_id: req.account.id },
      {
        deleted_at: new Date(),
        updated_at: new Date(),
        revision: current.revision + 1,
      }
    );
    await sync.change(req.account, 'measurement', row);
    res.json(row);
  })
);

router.post(
  '/:id/restore',
  asyncHandler(async (req, res) => {
    const current = await owned(req, true);
    revision(req, current);
    if (!current.deleted_at) return res.json(current);
    const row = await store.update(
      'measurements',
      { id: current.id, account_id: req.account.id },
      {
        deleted_at: null,
        updated_at: new Date(),
        revision: current.revision + 1,
      }
    );
    await sync.change(req.account, 'measurement', row);
    res.json(row);
  })
);

module.exports = router;
