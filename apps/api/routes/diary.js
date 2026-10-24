const express = require('express');
const store = require('../data');
const { authenticate } = require('../lib/auth');
const { asyncHandler, badRequest } = require('../lib/errors');
const { requireUser, entryDateFor } = require('../lib/users');
const v = require('../lib/validate');
const sync = require('../lib/sync');

const STATUSES = ['in_progress', 'complete', 'estimated', 'excluded'];

const router = express.Router();
router.use(authenticate);
router.put(
  '/day',
  asyncHandler(async (req, res) => {
    const user = await requireUser(req.user.email);
    const filter = { email: user.email, entry_date: entryDateFor(req, user) };
    const old = await store.findOne('diary_days', filter);
    const current = old ?? {
      entry_date: filter.entry_date,
      status: 'in_progress',
      note: null,
      revision: 0,
    };
    // Accept the original field name while requiring every writer to review a version.
    req.body.base_revision ??= req.body.revision;
    if (req.body.base_revision == null && req.get('If-Match') == null)
      throw badRequest('base_revision is required');
    sync.checkRevision(req, current);
    const row = await store.upsert('diary_days', filter, {
      account_id: user.id,
      status: v.oneOf(req.body.status, 'status', STATUSES),
      note: v.str(req.body.note, 'note', { required: false, max: 500 }),
      revision: (old?.revision ?? 0) + 1,
      updated_at: new Date(),
    });
    await sync.change(user, 'diary_day', { ...row, client_id: row.entry_date });
    res.json(row);
  })
);
router.get(
  '/day',
  asyncHandler(async (req, res) => {
    const user = await requireUser(req.user.email);
    const date = entryDateFor(req, user);
    res.json(
      (await store.findOne('diary_days', { email: user.email, entry_date: date })) ?? {
        entry_date: date,
        status: 'in_progress',
        revision: 0,
      }
    );
  })
);
module.exports = router;
module.exports.STATUSES = STATUSES;
