const express = require('express');
const store = require('../data');
const { authenticate } = require('./auth');
const { asyncHandler, conflict, notFound } = require('./errors');
const { entryDateFor, rangeFor, paginationFor } = require('./users');
const v = require('./validate');
const sync = require('./sync');

// Activity and manual sleep retain their existing list and mutation contracts.
// New clients add immutable identities and adopt revision checks for old rows.
module.exports = function versionedLogs({ collection, kind, label, read }) {
  const router = express.Router();
  router.use(authenticate);
  function record(row, user) {
    const { identity_key: _identityKey, ...value } = row;
    return {
      ...value,
      account_id: row.account_id ?? user.id,
      // Reserved aliases let old rows retain their identity before adoption.
      // New creations require UUIDs and cannot reuse this legacy namespace.
      client_id: row.client_id ?? `legacy-${row.id}`,
      revision: row.revision ?? 1,
    };
  }
  async function owned(req) {
    const row = await store.findOne(
      collection,
      { id: String(req.params.id), email: req.account.email },
      { includeDeleted: true }
    );
    if (!row) throw notFound(`${label} not found`);
    return record(row, req.account);
  }
  function checked(req, row, required = false) {
    if (
      (required || row.revision_locked) &&
      req.body?.base_revision == null &&
      req.get('If-Match') == null
    ) {
      throw conflict(
        `Read the current ${label.toLowerCase()} and include its base_revision before changing it.`,
        { current: row }
      );
    }
    sync.checkRevision(req, row);
  }
  function metadata(req, row) {
    return {
      account_id: req.account.id,
      client_id: row.client_id,
      identity_key: `${req.account.id}:${row.client_id}`,
      revision: row.revision + 1,
      revision_locked:
        !!row.revision_locked || req.body?.base_revision != null || req.get('If-Match') != null,
      updated_at: new Date(),
    };
  }
  async function change(req, row) {
    const value = record(row, req.account);
    await sync.change(req.account, kind, value);
    return value;
  }
  router.get(
    '/',
    asyncHandler(async (req, res) => {
      const filter = { email: req.account.email };
      if (req.query.date) filter.entry_date = v.dateStr(req.query.date, 'date');
      else {
        const { from, to } = rangeFor(req, req.account, { defaultDays: 90 });
        filter.entry_date = { gte: from, lte: to };
      }
      const { limit, skip } = paginationFor(req, { defaultLimit: 300 });
      const rows = await store.find(collection, filter, {
        sort: { entry_date: -1, id: -1 },
        limit,
        skip,
        includeDeleted: req.query.include_deleted === 'true',
      });
      res.json(rows.map((row) => record(row, req.account)));
    })
  );
  router.get(
    '/:id',
    asyncHandler(async (req, res) => {
      const row = await owned(req);
      if (row.deleted_at && req.query.include_deleted !== 'true')
        throw notFound(`${label} not found`);
      res.json(row);
    })
  );
  router.post(
    '/',
    asyncHandler(async (req, res) => {
      const clientID = sync.entityID(req.body?.client_id);
      const identityKey = `${req.account.id}:${clientID}`;
      const existing = await store.findOne(
        collection,
        { identity_key: identityKey },
        { includeDeleted: true }
      );
      if (existing)
        throw conflict(`This ${label.toLowerCase()} already exists.`, {
          current: record(existing, req.account),
        });
      const now = new Date();
      const row = await store.insert(collection, {
        ...read(req.body || {}),
        email: req.account.email,
        account_id: req.account.id,
        client_id: clientID,
        identity_key: identityKey,
        entry_date: entryDateFor(req, req.account),
        revision: 1,
        revision_locked: req.body?.client_id != null,
        created_at: now,
        updated_at: now,
      });
      res.status(201).json(await change(req, row));
    })
  );
  router.put(
    '/:id',
    asyncHandler(async (req, res) => {
      const current = await owned(req);
      checked(req, current);
      if (current.deleted_at)
        throw conflict(`This ${label.toLowerCase()} was deleted. Review it before restoring.`, {
          current,
        });
      const row = await store.update(
        collection,
        { id: current.id, email: req.account.email },
        {
          ...read(req.body || {}),
          ...metadata(req, current),
          entry_date:
            req.body?.entry_date == null ? current.entry_date : entryDateFor(req, req.account),
        }
      );
      res.json(await change(req, row));
    })
  );
  router.delete(
    '/:id',
    asyncHandler(async (req, res) => {
      const current = await owned(req);
      checked(req, current);
      if (current.deleted_at) return res.json({ message: `${label} deleted`, [kind]: current });
      const row = await store.update(
        collection,
        { id: current.id, email: req.account.email },
        {
          ...metadata(req, current),
          deleted_at: new Date(),
          revision_locked: true,
        }
      );
      res.json({ message: `${label} deleted`, [kind]: await change(req, row) });
    })
  );
  router.post(
    '/:id/restore',
    asyncHandler(async (req, res) => {
      const current = await owned(req);
      checked(req, current, true);
      if (!current.deleted_at) return res.json(current);
      const row = await store.update(
        collection,
        { id: current.id, email: req.account.email },
        {
          ...metadata(req, current),
          deleted_at: null,
          revision_locked: true,
        }
      );
      res.json(await change(req, row));
    })
  );
  // Restoring an export checks rows as a write here would.
  router.read = read;
  return router;
};
