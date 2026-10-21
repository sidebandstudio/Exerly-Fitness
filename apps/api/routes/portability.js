// /v1/export/<name>.csv: one kind of data as a CSV file. /v1/import: restore an
// Exerly JSON export, and /v1/import/undo its older tables. See lib/portability.js.

const express = require('express');
const { asyncHandler, badRequest, forbidden, notFound } = require('../lib/errors');
const { authenticate } = require('../lib/auth');
const { rateLimit } = require('../lib/ratelimit');
const { FILES, exportCSV, importExport, undoRestore } = require('../lib/portability');

const router = express.Router();

router.get(
  '/export/:file',
  authenticate,
  asyncHandler(async (req, res) => {
    const name = req.params.file.replace(/\.csv$/, '');
    const text = await exportCSV(req.account, name);
    if (text == null) {
      throw notFound(
        `Exports are ${Object.keys(FILES)
          .map((f) => `${f}.csv`)
          .join(', ')}`
      );
    }
    res.set('Content-Type', 'text/csv; charset=utf-8');
    res.set('Content-Disposition', `attachment; filename="exerly-${name}.csv"`);
    res.send(text);
  })
);

// Import and Undo are limited per account, each on its own: per address, every
// account behind DigitalOcean's shared ingress would share one limit.
const perAccount = (name) =>
  rateLimit({ name, max: 10, windowMs: 60 * 1000, key: (req) => String(req.account.id) });

// Only the person's own app may import into the account. The body, up to
// 25 MB, is read only after that is checked.
router.post(
  '/import',
  authenticate,
  perAccount('import'),
  (req, _res, next) =>
    next(req.pat ? forbidden('Only the Exerly app can import an export.') : null),
  express.json({ limit: '25mb' }),
  asyncHandler(async (req, res) => {
    const result = await importExport(req.account, req.body);
    if (result.error) throw badRequest(result.error);
    res.json(result);
  })
);

// Undoes a restore of the server's older tables, by the restore_id the import
// returned. Rows changed since are kept.
router.post(
  '/import/undo',
  authenticate,
  perAccount('import-undo'),
  (req, _res, next) => next(req.pat ? forbidden('Only the Exerly app can undo an import.') : null),
  express.json({ limit: '5mb' }),
  asyncHandler(async (req, res) => {
    const result = await undoRestore(req.account, req.body);
    if (result.error) throw badRequest(result.error);
    res.json(result);
  })
);

module.exports = router;
